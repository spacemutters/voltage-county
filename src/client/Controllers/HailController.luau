--!strict
-- Hail a pod on this client (PLAN.md Phase 9; docs/phase-9-contracts.md "Hail a pod" and "Client: the ride").
--
--   fares      quotes(): an estimated fare for every GPS destination from where the character stands, worked out
--              with the shared Pathfind and Config/Hail fareFor exactly as Services/HailService charges it (the
--              server's charge is the truth). Cached, and worked out again only once the character has moved
--              Config/Hail quote.refreshStuds. Nil while the player isn't on foot (no living character, or sitting
--              in a seat), so the GPS app can say why there is no Hail button. A place with no road route, or
--              closer than Hail.minStuds, has no fare.
--   hail(id)   sends Net HailPod { destinationId }, one request at a time, and shows the server's answer as a
--              notice (NotifyController). onChanged fires when a request starts or ends and when a ride starts or
--              ends; getState() says which place is being hailed and whether a ride is playing (UI/Phone/GpsApp).
--   the ride   on Net HailRide { from, to, seconds, route } a short cutscene plays for the ride's seconds: a local
--              copy of the ambient pod (ReplicatedStorage.TrafficModels.ohm_pod, put there by TrafficService; a
--              plain box of the pod's size when it is missing) glides along the start of the route in the
--              right-hand lane with the camera easing in behind it, then the screen fades to black, stays black
--              until the server has stood the character at the destination (or a timeout), and fades back in on
--              the character. While it plays the LocalPlayer attribute Cutscene is true (the HUD, touch controls
--              and phone hide) and the character is hidden from its own camera. Everything goes back (camera type,
--              subject and field of view, the attribute, the character, the pod, the black screen) when it ends,
--              however it ends: arrival, the character dying, sitting down or being replaced, the timeout, an
--              error in a frame, or a new ride.
--
-- No polling: the cutscene's one render step exists only while a ride plays (it draws the ride), everything else
-- runs on events. The glide and pose math are pure (HailController.Math) for tests/Hail.spec.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local Catalog = require(Shared.Vehicle.Catalog)
local Hail = require(Shared.Config.Hail)
local MapLayout = require(Shared.Config.MapLayout)
local Net = require(Shared.Net)
local Pathfind = require(Shared.Road.Pathfind)
local InputController = require(script.Parent.InputController)
local NotifyController = require(script.Parent.NotifyController)

-- A route ready for distance lookups: cumulative[i] is the studs from the first point to points[i].
export type Path = {
	points: { Vector3 },
	cumulative: { number },
	length: number,
}

-- What the GPS app shows: the place being hailed right now (nil: no request with the server), and whether a ride
-- is playing.
export type State = { hailingId: string?, riding: boolean }

-- The HailRide payload, checked.
type Ride = { from: Vector3, to: Vector3, seconds: number, route: { Vector3 } }

-- The camera as it was before a ride, to put back after.
type SavedCamera = { cameraType: Enum.CameraType, subject: Instance?, fieldOfView: number }

-- A ride being played.
type Playing = {
	ride: Ride,
	path: Path,
	startedAt: number, -- os.clock()
	glideSeconds: number,
	speed: number, -- glide top speed, studs/s
	pod: Instance,
	podLift: number, -- studs from the road surface up to the pod's pivot
	gui: ScreenGui,
	curtain: Frame,
	fadingOut: boolean,
	cameraFrame: CFrame?, -- the eased camera, nil until the first frame
	saved: SavedCamera,
	hidden: { [Instance]: number }, -- the character's parts and decals hidden, with their old LocalTransparencyModifier
	connections: { RBXScriptConnection },
	safety: thread?, -- stops the ride if frames stop coming
}

local REMOTE = "HailPod"
local RIDE_EVENT = "HailRide"
local RENDER_STEP = "VoltageHailRide"
-- After Roblox's camera scripts, CameraController (+1) and CustomizationController's framing (+2).
local RENDER_PRIORITY = Enum.RenderPriority.Camera.Value + 3
local GUI_NAME = "HailRideFade"
local MIN_LENGTH = 1e-3 -- vectors shorter than this (studs) have no usable direction
-- Extra seconds past the cutscene's own timeout before the safety timer ends a ride whose frames stopped coming.
local SAFETY_SECONDS = 2

local cutscene = Hail.cutscene
local localPlayer = Players.LocalPlayer

local HailController = {}

-- Fires with no arguments whenever getState() would answer differently.
HailController.onChanged = InputController.newSignal()

-- Pure math --------------------------------------------------------------------------------------------------------

local Math = {}

-- A route with cumulative distances, for pointAt and poseAt.
function Math.newPath(points: { Vector3 }): Path
	local cumulative: { number } = table.create(#points)
	local total = 0
	for i, point in points do
		if i > 1 then
			total += (point - points[i - 1]).Magnitude
		end
		cumulative[i] = total
	end
	return { points = points, cumulative = cumulative, length = total }
end

-- The point `distance` studs along a path (clamped to its ends).
function Math.pointAt(path: Path, distance: number): Vector3
	local points, cumulative = path.points, path.cumulative
	local count = #points
	if count == 0 then
		return Vector3.zero
	elseif count == 1 or distance <= 0 then
		return points[1]
	elseif distance >= path.length then
		return points[count]
	end
	-- Binary search for the segment that holds `distance`: cumulative[low] <= distance < cumulative[high].
	local low, high = 1, count
	while high - low > 1 do
		local middle = (low + high) // 2
		if cumulative[middle] <= distance then
			low = middle
		else
			high = middle
		end
	end
	local span = cumulative[high] - cumulative[low]
	local alpha = if span > 0 then (distance - cumulative[low]) / span else 0
	return points[low]:Lerp(points[high], alpha)
end

-- Where a car `distance` studs along the path stands: `laneOffset` studs right of the line (positive = right,
-- looking the way it drives), facing along the path as it runs from `headingStuds` behind to `headingStuds` ahead,
-- so it turns smoothly through corners. The position is on the path's surface height.
function Math.poseAt(path: Path, distance: number, headingStuds: number, laneOffset: number): CFrame
	local here = Math.pointAt(path, distance)
	local delta = Math.pointAt(path, distance + headingStuds) - Math.pointAt(path, distance - headingStuds)
	local direction = Vector3.new(delta.X, 0, delta.Z)
	if direction.Magnitude < MIN_LENGTH then
		local points = path.points
		local whole = if #points >= 2 then points[#points] - points[1] else Vector3.zero
		direction = Vector3.new(whole.X, 0, whole.Z)
		if direction.Magnitude < MIN_LENGTH then
			direction = -Vector3.zAxis
		end
	end
	direction = direction.Unit
	local right = direction:Cross(Vector3.yAxis)
	local position = here + right * laneOffset
	return CFrame.lookAt(position, position + direction)
end

-- The glide's top speed: `maxSpeed`, or slower when the route is too short to glide that fast for `glideSeconds`
-- (with the first `accelSeconds` spent speeding up), so the pod reaches the route's end no sooner than the fade.
function Math.glideSpeed(routeLength: number, glideSeconds: number, maxSpeed: number, accelSeconds: number): number
	local cruise = glideSeconds - math.min(accelSeconds, glideSeconds) / 2
	if cruise <= 0 or routeLength <= 0 then
		return 0
	end
	return math.min(maxSpeed, routeLength / cruise)
end

-- Studs glided after `elapsed` seconds at top speed `speed`: speeding up evenly over `accelSeconds`, then steady,
-- never past `routeLength`.
function Math.glideDistance(elapsed: number, speed: number, accelSeconds: number, routeLength: number): number
	if elapsed <= 0 or speed <= 0 then
		return 0
	end
	local distance
	if accelSeconds > 0 and elapsed < accelSeconds then
		distance = speed * elapsed * elapsed / (2 * accelSeconds)
	else
		distance = speed * (elapsed - math.max(accelSeconds, 0) / 2)
	end
	return math.clamp(distance, 0, math.max(routeLength, 0))
end

-- How long the pod glides before the fade starts: the ride's seconds less the fade, but at least minGlideSeconds.
function Math.glideSeconds(rideSeconds: number, fadeOutSeconds: number, minGlideSeconds: number): number
	return math.max(rideSeconds - fadeOutSeconds, minGlideSeconds)
end

-- Fraction of the gap an eased value closes this frame (the same at any frame rate).
function Math.smoothing(stiffness: number, dt: number): number
	if dt <= 0 or stiffness <= 0 then
		return 0
	end
	return 1 - math.exp(-stiffness * dt)
end

HailController.Math = Math

-- State ------------------------------------------------------------------------------------------------------------

local hailingId: string? = nil
local playing: Playing? = nil
local quoteCache: { from: Vector3, fares: { [string]: number } }? = nil

-- Every GPS destination: its id and where its route ends (as GpsController routes to it).
local destinations: { { id: string, target: Vector3 } } = {}
for _, location in MapLayout.locations do
	if location.gps then
		table.insert(destinations, { id = location.id, target = location.gpsTarget or location.position })
	end
end

-- The local character's living Humanoid and root part while it stands on foot, or nils.
local function onFoot(): (Humanoid?, BasePart?)
	local character = localPlayer.Character
	if character == nil then
		return nil, nil
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local root = character:FindFirstChild("HumanoidRootPart")
	if humanoid == nil or humanoid.Health <= 0 or humanoid.SeatPart ~= nil then
		return nil, nil
	end
	if root == nil or not root:IsA("BasePart") then
		return nil, nil
	end
	return humanoid, root
end

local function changed()
	HailController.onChanged:Fire()
end

-- Fares ------------------------------------------------------------------------------------------------------------

-- The estimated fare to every GPS destination it can reach (id -> $), or nil while the player isn't on foot.
function HailController.quotes(): { [string]: number }?
	local _, root = onFoot()
	if root == nil then
		return nil
	end
	local here = root.Position
	local cache = quoteCache
	if cache ~= nil and (here - cache.from).Magnitude < Hail.quote.refreshStuds then
		return cache.fares
	end
	local fares: { [string]: number } = {}
	for _, destination in destinations do
		local ok, route = pcall(Pathfind.route, here, destination.target)
		if ok and route ~= nil and #route.points > 0 and route.length >= Hail.minStuds then
			fares[destination.id] = Hail.fareFor(route.length)
		end
	end
	quoteCache = { from = here, fares = fares }
	return fares
end

-- The estimated fare to one GPS destination, or nil (not on foot, no road there, or too close to ride).
function HailController.quote(destinationId: string): number?
	local fares = HailController.quotes()
	return if fares ~= nil then fares[destinationId] else nil
end

function HailController.getState(): State
	return { hailingId = hailingId, riding = playing ~= nil }
end

-- Asks the server for a pod to `destinationId` and shows its answer. Returns whether a ride was booked. Does
-- nothing (false) while another request is with the server or a ride is playing.
function HailController.hail(destinationId: string): boolean
	if hailingId ~= nil or playing ~= nil then
		return false
	end
	hailingId = destinationId
	changed()
	local ok, result = pcall(Net.invokeServer, REMOTE, { destinationId = destinationId })
	hailingId = nil
	changed()
	if not ok or type(result) ~= "table" then
		NotifyController.show(Hail.messages.failed, "error")
		return false
	end
	local booked = result.ok == true
	local message = result.message
	if type(message) == "string" and message ~= "" then
		NotifyController.show(message, if booked then "success" else "info")
	end
	return booked
end

-- True while a ride's cutscene plays.
function HailController.isRiding(): boolean
	return playing ~= nil
end

-- The cutscene -----------------------------------------------------------------------------------------------------

-- Makes every part of a model safe to fly around locally: anchored, and never colliding, queried or touched.
local function ghost(model: Instance)
	for _, item in model:GetDescendants() do
		if item:IsA("BasePart") then
			item.Anchored = true
			item.CanCollide = false
			item.CanQuery = false
			item.CanTouch = false
		end
	end
end

-- A local pod for the ride and how high its pivot sits above the road: a clone of the ambient pod template, or a
-- plain box of the pod's size.
local function makePod(folder: Instance): (Instance, number)
	local models = ReplicatedStorage:FindFirstChild(cutscene.templateFolder)
	local template = if models ~= nil then models:FindFirstChild(cutscene.templateName) else nil
	local copy: Model? = if template ~= nil and template:IsA("Model") then template:Clone() else nil -- nil: not Archivable
	if copy ~= nil then
		ghost(copy)
		copy:PivotTo(CFrame.identity)
		local box, size = copy:GetBoundingBox()
		copy.Parent = folder
		return copy, -(box.Position.Y - size.Y / 2)
	end
	local vehicle = Catalog.getVehicle(cutscene.vehicleId)
	local geometry = if vehicle ~= nil then vehicle.geometry else nil
	local size = if geometry ~= nil
		then Vector3.new(geometry.width, geometry.height, geometry.length)
		else cutscene.fallbackSize
	local box = Instance.new("Part")
	box.Name = cutscene.templateName
	box.Size = size
	box.Color = cutscene.fallbackColor
	box.Material = Enum.Material.SmoothPlastic
	box.Anchored = true
	box.CanCollide = false
	box.CanQuery = false
	box.CanTouch = false
	box.CastShadow = true
	box.Parent = folder
	return box, size.Y / 2
end

local function pivotPod(pod: Instance, pose: CFrame)
	if pod:IsA("Model") then
		pod:PivotTo(pose)
	elseif pod:IsA("BasePart") then
		pod.CFrame = pose
	end
end

-- Hides the local character from its own camera (it rides inside the pod). Returns what was changed.
local function hideCharacter(): { [Instance]: number }
	local hidden: { [Instance]: number } = {}
	local character = localPlayer.Character
	if character == nil then
		return hidden
	end
	for _, item in character:GetDescendants() do
		if item:IsA("BasePart") or item:IsA("Decal") then
			local seeThrough: any = item -- both classes have LocalTransparencyModifier
			hidden[item] = seeThrough.LocalTransparencyModifier
			seeThrough.LocalTransparencyModifier = 1
		end
	end
	return hidden
end

local function showCharacter(hidden: { [Instance]: number })
	for item, modifier in hidden do
		if item.Parent ~= nil then
			local seeThrough: any = item
			seeThrough.LocalTransparencyModifier = modifier
		end
	end
end

local function makeFade(): (ScreenGui, Frame)
	local gui = Instance.new("ScreenGui")
	gui.Name = GUI_NAME
	gui.DisplayOrder = cutscene.fadeDisplayOrder
	gui.IgnoreGuiInset = true
	gui.ResetOnSpawn = false
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	local curtain = Instance.new("Frame")
	curtain.Name = "Curtain"
	curtain.Size = UDim2.fromScale(1, 1)
	curtain.BackgroundColor3 = cutscene.fadeColor
	curtain.BackgroundTransparency = 1
	curtain.BorderSizePixel = 0
	curtain.Active = false
	curtain.Parent = gui
	gui.Parent = localPlayer:WaitForChild("PlayerGui")
	return gui, curtain
end

local function tweenCurtain(curtain: Frame, transparency: number, seconds: number): Tween
	local tween = TweenService:Create(
		curtain,
		TweenInfo.new(seconds, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut),
		{ BackgroundTransparency = transparency }
	)
	tween:Play()
	return tween
end

-- Ends the ride being played and puts everything back. Each step is guarded, so one failure can't leave the
-- camera, the attribute or the character stuck.
local function stop()
	local current = playing
	if current == nil then
		return
	end
	playing = nil
	pcall(RunService.UnbindFromRenderStep, RunService, RENDER_STEP)
	for _, connection in current.connections do
		connection:Disconnect()
	end
	local safety = current.safety
	if safety ~= nil and safety ~= coroutine.running() and coroutine.status(safety) == "suspended" then
		task.cancel(safety)
	end

	local restored, err = pcall(function()
		local camera = Workspace.CurrentCamera
		local saved = current.saved
		local character = localPlayer.Character
		local humanoid = if character ~= nil then character:FindFirstChildOfClass("Humanoid") else nil
		-- Sitting down in a car mid-ride: CameraController owns the camera now, so leave it be.
		if humanoid == nil or humanoid.SeatPart == nil then
			camera.CameraType = if saved.cameraType == Enum.CameraType.Scriptable
				then Enum.CameraType.Custom
				else saved.cameraType
			camera.CameraSubject = humanoid or saved.subject
			camera.FieldOfView = saved.fieldOfView
		end
	end)
	if not restored then
		warn(`[HailController] Couldn't put the camera back after the ride: {err}`)
	end
	pcall(showCharacter, current.hidden)
	pcall(function()
		current.pod:Destroy()
	end)
	localPlayer:SetAttribute(cutscene.attribute, nil)

	-- Fade back in from wherever the curtain is, then take the black screen away.
	local gui, curtain = current.gui, current.curtain
	pcall(tweenCurtain, curtain, 1, cutscene.fadeInSeconds)
	task.delay(cutscene.fadeInSeconds, function()
		gui:Destroy()
	end)
	changed()
end

-- True once the server has stood the character at the drop-off point and let go of it (it keeps the root anchored
-- there while the area around it is still streaming in: Services/HailService).
local function arrived(current: Playing): boolean
	local character = localPlayer.Character
	local root = if character ~= nil then character:FindFirstChild("HumanoidRootPart") else nil
	if root == nil or not root:IsA("BasePart") or root.Anchored then
		return false
	end
	return (root.Position - current.ride.to).Magnitude <= cutscene.arriveRadius
end

-- One frame of the ride: the pod along the route, the camera behind it, then the fade and the wait for arrival.
local function frame(current: Playing, dt: number)
	local elapsed = os.clock() - current.startedAt
	local distance = Math.glideDistance(elapsed, current.speed, cutscene.accelSeconds, current.path.length)
	local pose = Math.poseAt(current.path, distance, cutscene.headingStuds, cutscene.laneOffset)
	pivotPod(current.pod, pose + Vector3.yAxis * current.podLift)

	local camera = Workspace.CurrentCamera
	if camera.CameraType ~= Enum.CameraType.Scriptable then
		camera.CameraType = Enum.CameraType.Scriptable
	end
	local eye = pose:PointToWorldSpace(cutscene.cameraOffset)
	local focus = pose:PointToWorldSpace(Vector3.new(0, cutscene.lookHeight, -cutscene.lookAhead))
	local alpha = Math.smoothing(cutscene.cameraStiffness, dt)
	local target = CFrame.lookAt(eye, focus)
	local eased = (current.cameraFrame or camera.CFrame):Lerp(target, alpha)
	current.cameraFrame = eased
	camera.CFrame = eased
	camera.Focus = CFrame.new(focus)
	camera.FieldOfView += (cutscene.fov - camera.FieldOfView) * alpha

	if not current.fadingOut and elapsed >= current.glideSeconds then
		current.fadingOut = true
		tweenCurtain(current.curtain, 0, cutscene.fadeOutSeconds)
	end
	if current.fadingOut then
		local black = elapsed - current.glideSeconds - cutscene.fadeOutSeconds
		local timedOut = elapsed >= current.ride.seconds + cutscene.arriveTimeoutSeconds
		if black >= cutscene.minBlackSeconds and (timedOut or arrived(current)) then
			stop()
		end
	end
end

local function step(dt: number)
	local current = playing
	if current == nil then
		return
	end
	local ok, err = pcall(frame, current, dt)
	if not ok then
		warn(`[HailController] The ride cutscene stopped early: {err}`)
		stop()
	end
end

-- Starts the cutscene for a ride (ending any ride already playing).
local function play(ride: Ride)
	stop()
	local camera = Workspace.CurrentCamera
	local saved: SavedCamera = {
		cameraType = camera.CameraType,
		subject = camera.CameraSubject,
		fieldOfView = camera.FieldOfView,
	}
	local folder = Workspace:FindFirstChild(cutscene.folderName)
	if folder == nil then
		folder = Instance.new("Folder")
		folder.Name = cutscene.folderName
		folder.Parent = Workspace
	end
	local pods = folder :: Instance
	pods:ClearAllChildren() -- a pod left by a ride that failed to start
	local points = if #ride.route >= 2 then ride.route else { ride.from, ride.to }
	local path = Math.newPath(points)
	local glideSeconds = Math.glideSeconds(ride.seconds, cutscene.fadeOutSeconds, cutscene.minGlideSeconds)
	local pod, podLift = makePod(pods)
	local gui, curtain = makeFade()
	local current: Playing = {
		ride = ride,
		path = path,
		startedAt = os.clock(),
		glideSeconds = glideSeconds,
		speed = Math.glideSpeed(path.length, glideSeconds, cutscene.glideSpeed, cutscene.accelSeconds),
		pod = pod,
		podLift = podLift,
		gui = gui,
		curtain = curtain,
		fadingOut = false,
		cameraFrame = nil,
		saved = saved,
		hidden = {},
		connections = {},
		safety = nil,
	}
	playing = current
	localPlayer:SetAttribute(cutscene.attribute, true)
	current.hidden = hideCharacter()

	-- The ride ends early if the character goes or sits down (the server refunds those).
	table.insert(current.connections, localPlayer.CharacterRemoving:Connect(stop))
	local character = localPlayer.Character
	local humanoid = if character ~= nil then character:FindFirstChildOfClass("Humanoid") else nil
	if humanoid ~= nil then
		table.insert(current.connections, humanoid.Died:Connect(stop))
		table.insert(
			current.connections,
			humanoid.Seated:Connect(function(active: boolean)
				if active then
					stop()
				end
			end)
		)
	end
	local limit = math.max(glideSeconds + cutscene.fadeOutSeconds, ride.seconds + cutscene.arriveTimeoutSeconds)
	current.safety = task.delay(limit + cutscene.minBlackSeconds + SAFETY_SECONDS, function()
		if playing == current then
			stop()
		end
	end)
	RunService:BindToRenderStep(RENDER_STEP, RENDER_PRIORITY, step)
	changed()
end

-- The HailRide payload as this client uses it, or nil when it isn't one.
local function readRide(payload: any): Ride?
	if type(payload) ~= "table" then
		return nil
	end
	local from, to, seconds, route = payload.from, payload.to, payload.seconds, payload.route
	if typeof(from) ~= "Vector3" or typeof(to) ~= "Vector3" or type(seconds) ~= "number" or seconds ~= seconds then
		return nil
	end
	local points: { Vector3 } = {}
	if type(route) == "table" then
		for _, point in route do
			if typeof(point) == "Vector3" then
				table.insert(points, point)
			end
		end
	end
	return { from = from, to = to, seconds = math.max(seconds, 0), route = points }
end

local function onRide(payload: any)
	local ride = readRide(payload)
	if ride == nil then
		warn("[HailController] Ignored a HailRide message it couldn't read")
		return
	end
	local ok, err = pcall(play, ride)
	if not ok then
		warn(`[HailController] Couldn't play the ride: {err}`)
		stop()
	end
end

function HailController:Start()
	Net.onClientEvent(RIDE_EVENT, onRide)
	-- A new character starts in a new place: fares from the old one no longer apply.
	localPlayer.CharacterAdded:Connect(function()
		quoteCache = nil
	end)
end

return HailController
