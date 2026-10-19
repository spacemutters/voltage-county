--!strict
-- The driving camera. While the local player sits in a car's Driver seat it takes the camera over (Scriptable)
-- and shows one of three views, cycled with the camera button (InputController.onCycleCamera):
--   chase  follows behind and above the car, swinging round smoothly in turns; the view widens with speed
--   orbit  drag with the mouse, a finger or the right stick to circle the car; drifts back behind it when idle
--   hood   rides the car's CameraHood attachment
-- On leaving the seat it hands the camera back to Roblox's default (Custom, following the character).
--
-- Every smoothed value closes 1 - exp(-stiffness * dt) of its gap each frame (tunables in Config/Camera), so it
-- feels the same at 30 and 144 fps. Chase and orbit keep the camera outside the car's bounding sphere and pull it
-- in front of walls. Runs right after Roblox's own camera scripts each frame (RenderPriority.Camera + 1).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local CameraConfig = require(Shared.Config.Camera)
local Types = require(Shared.Types)
local Units = require(Shared.Util.Units)

type Mode = CameraConfig.Mode
type FovRange = CameraConfig.FovRange

-- What this controller reads from DriveController (docs/phase-1-contracts.md, Client).
type DriveApi = {
	getCar: () -> Model?,
	getTelemetry: () -> Types.Telemetry?,
}

local ControllersFolder = script.Parent :: Instance
local ClientFolder = ControllersFolder.Parent :: Instance

local RENDER_STEP_NAME = "VoltageDriveCamera"
-- One after Roblox's camera scripts, so what we write is what this frame renders.
local RENDER_PRIORITY = Enum.RenderPriority.Camera.Value + 1
local TWO_PI = 2 * math.pi
local MIN_LENGTH = 1e-3 -- vectors shorter than this have no usable direction

-- Pure camera math, exposed as CameraController.Math so tests/CameraController.spec can check it.
local CameraMath = {}

-- Fraction of the gap a smoothed value closes this frame. Two half-frames close exactly as much as one whole
-- frame, which is what makes the smoothing independent of the frame rate.
function CameraMath.smoothing(stiffness: number, dt: number): number
	if dt <= 0 or stiffness <= 0 then
		return 0
	end
	return 1 - math.exp(-stiffness * dt)
end

-- Moves `current` toward `target` by `alpha` (0..1) of the gap.
function CameraMath.approach(current: number, target: number, alpha: number): number
	return current + (target - current) * alpha
end

-- An angle in radians, wrapped into [-pi, pi).
function CameraMath.wrapAngle(angle: number): number
	return (angle + math.pi) % TWO_PI - math.pi
end

-- Like approach, for angles: always turns the short way round.
function CameraMath.approachAngle(current: number, target: number, alpha: number): number
	return CameraMath.wrapAngle(current + CameraMath.wrapAngle(target - current) * alpha)
end

-- Yaw (radians) of a look direction on the ground plane, matching CFrame.fromEulerAnglesYXZ(0, yaw, 0).
-- Returns `fallback` when the direction is (nearly) straight up or down, e.g. a car standing on its nose.
function CameraMath.headingOf(look: Vector3, fallback: number): number
	if math.abs(look.X) + math.abs(look.Z) < MIN_LENGTH then
		return fallback
	end
	return math.atan2(-look.X, -look.Z)
end

-- Field of view for a speed: `min` at a standstill rising linearly to `max` at `fullAtMph`.
function CameraMath.fovForSpeed(mph: number, range: FovRange): number
	local t = math.clamp(math.abs(mph) / range.fullAtMph, 0, 1)
	return range.min + (range.max - range.min) * t
end

-- How much to scale chase and orbit distances for a car of this length.
function CameraMath.sizeScale(carLength: number): number
	return math.clamp(carLength / CameraConfig.referenceLength, CameraConfig.minSizeScale, CameraConfig.maxSizeScale)
end

-- Pushes `position` straight away from `center` until it is at least `clearance` studs out, so the camera never
-- ends up inside the car.
function CameraMath.keepClear(position: Vector3, center: Vector3, clearance: number): Vector3
	local away = position - center
	local distance = away.Magnitude
	if distance >= clearance then
		return position
	end
	local direction = if distance > MIN_LENGTH then away / distance else Vector3.yAxis
	return center + direction * clearance
end

-- Gamepad stick with a radial deadzone, rescaled so output still runs smoothly from 0 to 1.
function CameraMath.applyDeadzone(position: Vector2, deadzone: number): Vector2
	local magnitude = position.Magnitude
	if magnitude <= deadzone then
		return Vector2.zero
	end
	local scaled = math.min((magnitude - deadzone) / (1 - deadzone), 1)
	return position / magnitude * scaled
end

local CameraController = {}
CameraController.Math = CameraMath

local drive: DriveApi? = nil
local inputController: any = nil
local mode: Mode = CameraConfig.modes[1]

-- Driving state: the car whose Driver seat the local humanoid sits in. nil while on foot.
local seatCar: Model? = nil
local seatHumanoid: Humanoid? = nil
local seatConnection: RBXScriptConnection? = nil
local bound = false
local savedFieldOfView: number? = nil

-- Measurements of the car being followed, refreshed whenever the car changes.
local measuredCar: Model? = nil
local carLength = 0
local carHeight = 0
local sizeScale = 1
local clearance = 0

-- Smoothed values. `snap` makes the next frame jump straight to its targets (new car, teleport, reset);
-- `resetView` does the same for the camera boom and hood rotation only (view switched).
local snap = true
local resetView = true
local heading = 0
local followHeight = 0
local extraDistance = 0
local boomLength = 0
local fieldOfView = 0
local hoodRotation = CFrame.identity
local lastCenter: Vector3? = nil

-- Orbit state. Yaw is relative to the car's heading, so the view turns with the car.
local orbitYaw = 0
local orbitPitch = math.rad(CameraConfig.orbit.defaultPitch)
local lastOrbitInput = -math.huge
local stick = Vector2.zero
local mouseDragging = false
local savedMouseBehavior: Enum.MouseBehavior? = nil
local dragTouch: InputObject? = nil

local raycastParams = RaycastParams.new()
raycastParams.FilterType = Enum.RaycastFilterType.Exclude
raycastParams.RespectCanCollide = true -- invisible trigger volumes don't block the view

-- Requires a sibling controller without letting its failure take the camera down with it.
local function requireSibling(name: string): any
	local moduleScript = ControllersFolder:FindFirstChild(name)
	if moduleScript == nil or not moduleScript:IsA("ModuleScript") then
		warn(`[CameraController] {name} not found; the camera runs without it`)
		return nil
	end
	local ok, result = pcall(require :: any, moduleScript)
	if not ok then
		warn(`[CameraController] require {name} failed: {result}`)
		return nil
	end
	return result
end

-- Subscribes to a signal whichever way InputController exposes it: an RBXScriptSignal, a BindableEvent, an
-- object with :Connect, a registration function, or a plain list of callbacks (docs/phase-1-contracts.md).
local function subscribe(signal: any, callback: () -> ()): boolean
	local kind = typeof(signal)
	if kind == "RBXScriptSignal" then
		signal:Connect(callback)
	elseif kind == "Instance" and signal:IsA("BindableEvent") then
		signal.Event:Connect(callback)
	elseif kind == "function" then
		signal(callback)
	elseif kind == "table" then
		if type(signal.Connect) == "function" then
			signal:Connect(callback)
		else
			table.insert(signal, callback)
		end
	else
		return false
	end
	return true
end

-- The car whose Driver seat this is (same rule DriveController uses), or nil.
local function carOfDriverSeat(seat: BasePart?): Model?
	if seat == nil or not seat:IsA("Seat") or seat.Name ~= "Driver" then
		return nil
	end
	local node = seat.Parent
	while node ~= nil do
		if node:IsA("Model") and node:GetAttribute("VehicleId") ~= nil then
			return node
		end
		node = node.Parent
	end
	return nil
end

local function measure(car: Model)
	measuredCar = car
	-- Extents are measured in the PrimaryPart's (Chassis) frame, so Z is the car's length.
	local size = car:GetExtentsSize()
	carLength = size.Z
	carHeight = size.Y
	sizeScale = CameraMath.sizeScale(size.Z)
	clearance = size.Magnitude / 2 + CameraConfig.collision.carClearance
end

-- Speed in mph from the chassis telemetry, or straight from the physics while DriveController catches up.
local function currentMph(chassis: BasePart): number
	local telemetry = if drive then drive.getTelemetry() else nil
	if telemetry then
		return telemetry.mph
	end
	return Units.studsToMph(chassis.AssemblyLinearVelocity.Magnitude)
end

-- Where the camera can sit on the line from `pivot` toward `desired` with no wall in between. Pulls in at once
-- when something blocks the view, and eases back out when it clears.
local function boom(pivot: Vector3, desired: Vector3, dt: number): Vector3
	local offset = desired - pivot
	local wanted = offset.Magnitude
	if wanted < MIN_LENGTH then
		return desired
	end
	local allowed = wanted
	if CameraConfig.collision.enabled then
		local hit = Workspace:Raycast(pivot, offset, raycastParams)
		if hit then
			allowed = math.max(hit.Distance - CameraConfig.collision.margin, 0)
		end
	end
	if snap or resetView or allowed < boomLength then
		boomLength = allowed
	else
		local alpha = CameraMath.smoothing(CameraConfig.collision.returnStiffness, dt)
		boomLength = CameraMath.approach(boomLength, allowed, alpha)
	end
	resetView = false
	return pivot + offset / wanted * boomLength
end

local function chaseView(center: Vector3, mph: number, dt: number): (CFrame, Vector3)
	local chase = CameraConfig.chase
	local targetExtra = math.min(mph * chase.distancePerMph, chase.maxExtraDistance) * sizeScale
	extraDistance = if snap
		then targetExtra
		else CameraMath.approach(extraDistance, targetExtra, CameraMath.smoothing(chase.distanceStiffness, dt))

	local forward = CFrame.fromEulerAnglesYXZ(0, heading, 0).LookVector
	local follow = Vector3.new(center.X, followHeight, center.Z)
	local pivot = follow + Vector3.yAxis * (chase.lookHeight * sizeScale)
	local aim = pivot + forward * (chase.lookAhead * sizeScale)
	local desired = follow
		- forward * (chase.distance * sizeScale + extraDistance)
		+ Vector3.yAxis * (chase.height * sizeScale)
	local position = CameraMath.keepClear(boom(pivot, desired, dt), center, clearance)
	return CFrame.lookAt(position, aim), aim
end

local function orbitView(center: Vector3, dt: number): (CFrame, Vector3)
	local orbit = CameraConfig.orbit
	local now = os.clock()
	if stick.Magnitude > 0 then
		-- Right stick turns at a steady rate: right turns the view right, up looks up.
		local rate = math.rad(orbit.stickDegreesPerSecond) * dt
		orbitYaw -= stick.X * rate
		orbitPitch -= stick.Y * rate
		lastOrbitInput = now
	end
	if now - lastOrbitInput > orbit.returnDelay then
		local alpha = CameraMath.smoothing(orbit.returnStiffness, dt)
		orbitYaw = CameraMath.approachAngle(orbitYaw, 0, alpha)
		orbitPitch = CameraMath.approach(orbitPitch, math.rad(orbit.defaultPitch), alpha)
	end
	orbitYaw = CameraMath.wrapAngle(orbitYaw)
	orbitPitch = math.clamp(orbitPitch, math.rad(orbit.minPitch), math.rad(orbit.maxPitch))

	local follow = Vector3.new(center.X, followHeight, center.Z)
	local pivot = follow + Vector3.yAxis * (CameraConfig.chase.lookHeight * sizeScale)
	-- Negative X rotation tilts the look direction down, so a positive pitch looks down at the car.
	local look = CFrame.fromEulerAnglesYXZ(-orbitPitch, heading + orbitYaw, 0).LookVector
	local desired = pivot - look * (orbit.distance * sizeScale)
	local position = CameraMath.keepClear(boom(pivot, desired, dt), center, clearance)
	return CFrame.lookAt(position, pivot), pivot
end

local function hoodView(chassis: BasePart, dt: number): (CFrame, Vector3)
	local hood = CameraConfig.hood
	local mount: CFrame
	local attachment = chassis:FindFirstChild("CameraHood")
	if attachment ~= nil and attachment:IsA("Attachment") then
		mount = attachment.WorldCFrame
	else
		mount = chassis.CFrame * CFrame.new(0, carHeight * hood.fallbackHeight, -carLength * hood.fallbackForward)
	end
	mount = mount * CFrame.new(hood.offset) * CFrame.Angles(math.rad(hood.pitch), 0, 0)

	-- Position stays locked to the car (any lag would leave the camera inside the body at speed); only the
	-- rotation is lightly smoothed to take the edge off body shake.
	local rotation = mount.Rotation
	hoodRotation = if snap or resetView
		then rotation
		else hoodRotation:Lerp(rotation, CameraMath.smoothing(hood.rotationStiffness, dt))
	resetView = false
	local cframe = CFrame.new(mount.Position) * hoodRotation
	return cframe, cframe.Position + cframe.LookVector * hood.focusDistance
end

local function step(dt: number)
	local car = (if drive then drive.getCar() else nil) or seatCar
	if car == nil then
		return
	end
	local chassis = car.PrimaryPart
	local camera = Workspace.CurrentCamera
	if chassis == nil or camera == nil then
		return
	end
	if car ~= measuredCar then
		measure(car)
		snap = true
	end
	-- While driving this controller owns the camera; put it back if anything else switched it.
	if camera.CameraType ~= Enum.CameraType.Scriptable then
		camera.CameraType = Enum.CameraType.Scriptable
	end

	local center = chassis.Position
	if lastCenter ~= nil and (center - lastCenter).Magnitude > CameraConfig.snapDistance then
		snap = true
	end
	lastCenter = center

	-- Heading and height are smoothed in every mode, so switching views never jumps.
	local chase = CameraConfig.chase
	local targetHeading = CameraMath.headingOf(chassis.CFrame.LookVector, heading)
	if snap then
		heading = targetHeading
		followHeight = center.Y
	else
		heading = CameraMath.approachAngle(heading, targetHeading, CameraMath.smoothing(chase.headingStiffness, dt))
		followHeight = CameraMath.approach(followHeight, center.Y, CameraMath.smoothing(chase.heightStiffness, dt))
		local lag = chase.maxHeightLag * sizeScale
		followHeight = math.clamp(followHeight, center.Y - lag, center.Y + lag)
	end

	local mph = currentMph(chassis)
	local cframe: CFrame, focus: Vector3, targetFov: number
	if mode == "hood" then
		cframe, focus = hoodView(chassis, dt)
		targetFov = CameraMath.fovForSpeed(mph, CameraConfig.hood.fov)
	elseif mode == "orbit" then
		cframe, focus = orbitView(center, dt)
		targetFov = CameraConfig.orbit.fov
	else
		cframe, focus = chaseView(center, mph, dt)
		targetFov = CameraMath.fovForSpeed(mph, chase.fov)
	end
	fieldOfView = if snap
		then targetFov
		else CameraMath.approach(fieldOfView, targetFov, CameraMath.smoothing(CameraConfig.fovStiffness, dt))

	camera.CFrame = cframe
	camera.Focus = CFrame.new(focus)
	camera.FieldOfView = fieldOfView
	snap = false
end

local function beginMouseDrag()
	if mouseDragging then
		return
	end
	mouseDragging = true
	-- Like Roblox's own camera: hold the cursor still while dragging so it never leaves the window.
	savedMouseBehavior = UserInputService.MouseBehavior
	UserInputService.MouseBehavior = Enum.MouseBehavior.LockCurrentPosition
end

local function endMouseDrag()
	if not mouseDragging then
		return
	end
	mouseDragging = false
	UserInputService.MouseBehavior = savedMouseBehavior or Enum.MouseBehavior.Default
	savedMouseBehavior = nil
end

local function endOrbitInput()
	endMouseDrag()
	dragTouch = nil
	stick = Vector2.zero
end

-- Drag right turns the view right; drag down raises the camera to look down at the car.
local function orbitDrag(delta: Vector3, degreesPerPixel: number)
	local radians = math.rad(degreesPerPixel)
	orbitYaw -= delta.X * radians
	orbitPitch += delta.Y * radians
	lastOrbitInput = os.clock()
end

local function startDriving(car: Model, humanoid: Humanoid)
	if seatCar == car then
		return
	end
	local camera = Workspace.CurrentCamera
	if seatCar == nil then
		savedFieldOfView = camera.FieldOfView
	end
	seatCar = car
	seatHumanoid = humanoid
	measuredCar = nil
	lastCenter = nil
	snap = true
	resetView = true

	-- Walls block the view; cars (ours and everyone else's) and our own character don't.
	local ignore: { Instance } = { car }
	if humanoid.Parent then
		table.insert(ignore, humanoid.Parent)
	end
	local vehicles = Workspace:FindFirstChild("Vehicles")
	if vehicles then
		table.insert(ignore, vehicles)
	end
	raycastParams.FilterDescendantsInstances = ignore

	camera.CameraType = Enum.CameraType.Scriptable
	if not bound then
		RunService:BindToRenderStep(RENDER_STEP_NAME, RENDER_PRIORITY, step)
		bound = true
	end
end

local function stopDriving()
	if seatCar == nil then
		return
	end
	if bound then
		RunService:UnbindFromRenderStep(RENDER_STEP_NAME)
		bound = false
	end
	endOrbitInput()
	local humanoid = seatHumanoid
	seatCar = nil
	seatHumanoid = nil
	measuredCar = nil

	-- Back to Roblox's default camera, following the character (its new humanoid if it respawned).
	local camera = Workspace.CurrentCamera
	camera.CameraType = Enum.CameraType.Custom
	local character = Players.LocalPlayer.Character
	local subject = if character then character:FindFirstChildOfClass("Humanoid") else nil
	camera.CameraSubject = subject or humanoid
	if savedFieldOfView ~= nil then
		camera.FieldOfView = savedFieldOfView
		savedFieldOfView = nil
	end
end

local function watchHumanoid(humanoid: Humanoid)
	if seatConnection then
		seatConnection:Disconnect()
	end
	local function onSeatChanged()
		local car = carOfDriverSeat(humanoid.SeatPart)
		if car then
			startDriving(car, humanoid)
		else
			stopDriving()
		end
	end
	seatConnection = humanoid:GetPropertyChangedSignal("SeatPart"):Connect(onSeatChanged)
	onSeatChanged()
end

local function onCharacterAdded(character: Model)
	local humanoid = character:WaitForChild("Humanoid")
	if humanoid:IsA("Humanoid") and character.Parent ~= nil then
		watchHumanoid(humanoid)
	end
end

local function onCharacterRemoving()
	if seatConnection then
		seatConnection:Disconnect()
		seatConnection = nil
	end
	stopDriving()
end

local function connectOrbitInput()
	UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
		-- `processed` is true for touches and clicks on UI (pedals, buttons), which never orbit.
		if processed or seatCar == nil or mode ~= "orbit" then
			return
		end
		if table.find(CameraConfig.orbit.mouseButtons, input.UserInputType) then
			beginMouseDrag()
		elseif input.UserInputType == Enum.UserInputType.Touch and dragTouch == nil then
			dragTouch = input
		end
	end)

	UserInputService.InputChanged:Connect(function(input: InputObject)
		if seatCar == nil then
			return
		end
		if input.KeyCode == Enum.KeyCode.Thumbstick2 then
			-- Tracked in every mode so the stick is never stale when orbit starts.
			local position = Vector2.new(input.Position.X, input.Position.Y)
			stick = CameraMath.applyDeadzone(position, CameraConfig.orbit.stickDeadzone)
		elseif mode ~= "orbit" then
			return
		elseif input.UserInputType == Enum.UserInputType.MouseMovement and mouseDragging then
			orbitDrag(input.Delta, CameraConfig.orbit.mouseDegreesPerPixel)
		elseif input == dragTouch then
			orbitDrag(input.Delta, CameraConfig.orbit.touchDegreesPerPixel)
		end
	end)

	UserInputService.InputEnded:Connect(function(input: InputObject)
		if table.find(CameraConfig.orbit.mouseButtons, input.UserInputType) then
			endMouseDrag()
		elseif input == dragTouch then
			dragTouch = nil
		elseif input.KeyCode == Enum.KeyCode.Thumbstick2 then
			stick = Vector2.zero
		end
	end)
end

-- Studio only: lets Dev/AutoDriver forward calls made from MCP execute_luau into the game's own controllers
-- (see the header of Dev/AutoDriver). It lives here because this is the client code that runs at boot; live
-- servers never reach it.
local function serveAutoDriver()
	if not RunService:IsStudio() then
		return
	end
	local dev = ClientFolder:FindFirstChild("Dev")
	local autoDriver = if dev then dev:FindFirstChild("AutoDriver") else nil
	if autoDriver == nil or not autoDriver:IsA("ModuleScript") then
		return
	end
	local ok, err = pcall(function()
		(require :: any)(autoDriver).serve()
	end)
	if not ok then
		warn(`[CameraController] AutoDriver.serve failed: {err}`)
	end
end

function CameraController.getMode(): Mode
	return mode
end

function CameraController.setMode(newMode: Mode)
	if newMode == mode or table.find(CameraConfig.modes, newMode) == nil then
		return
	end
	if mode == "orbit" then
		endMouseDrag()
		dragTouch = nil
	end
	mode = newMode
	resetView = true
	if newMode == "orbit" then
		-- Start orbiting from right behind the car, as the chase view was.
		orbitYaw = 0
		orbitPitch = math.rad(CameraConfig.orbit.defaultPitch)
		lastOrbitInput = -math.huge
	end
end

function CameraController.cycleMode()
	local modes = CameraConfig.modes
	local index = table.find(modes, mode) or 0
	CameraController.setMode(modes[index % #modes + 1])
end

function CameraController:Init()
	drive = requireSibling("DriveController")
	inputController = requireSibling("InputController")
end

function CameraController:Start()
	if inputController ~= nil then
		local subscribed = subscribe(inputController.onCycleCamera, function()
			CameraController.cycleMode()
		end)
		if not subscribed then
			warn("[CameraController] InputController.onCycleCamera is missing; the camera button does nothing")
		end
	end

	connectOrbitInput()

	local player = Players.LocalPlayer
	player.CharacterAdded:Connect(onCharacterAdded)
	player.CharacterRemoving:Connect(onCharacterRemoving)
	if player.Character then
		task.spawn(onCharacterAdded, player.Character)
	end

	serveAutoDriver()
end

return CameraController
