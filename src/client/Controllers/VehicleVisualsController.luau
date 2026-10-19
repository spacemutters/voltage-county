--!strict
-- Animates other players' cars on this client (docs/phase-1-contracts.md "Client").
--
-- Every model tagged "Vehicle" is tracked through CollectionService's added and removed signals (no polling);
-- a car that streams out leaves the tag set and is dropped. Each RenderStepped, cars within
-- Controls.otherCars.maxDistance of the camera get their wheels moved by a Vehicle/WheelVisuals (it raycasts
-- for suspension and infers spin and steering from the replicated chassis motion), and their brake lamps
-- light while they slow down hard. Their drivers' pedals never reach this client, so the lamps follow the
-- replicated speed instead. The local player's own car is skipped while they drive it: its Chassis animates
-- it and DriveController lights its lamps. It also hides the Drive prompt on every car this player doesn't
-- own.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Controls = require(ReplicatedStorage.Shared.Config.Controls)
local Spawning = require(ReplicatedStorage.Shared.Config.Spawning)
local WheelVisuals = require(ReplicatedStorage.Shared.Vehicle.WheelVisuals)
local DriveController = require(script.Parent.DriveController)

local VEHICLE_TAG = "Vehicle"
local BRAKE_LAMP = "Brake"

-- Brake lamp inference for one car (see updateBrakeState).
export type BrakeState = {
	speed: number?, -- last forward speed seen, studs/s (nil until the first sample)
	decel: number, -- filtered deceleration, studs/s^2 (positive while slowing down in either direction)
	hardFor: number, -- seconds the filtered deceleration has stayed above onDecel
	on: boolean,
	onFor: number, -- seconds the lamp has been lit
}

-- Same fields as Config/Controls.otherCars.brakeLight (specs pass their own).
export type BrakeSettings = {
	onDecel: number,
	offDecel: number,
	filterTime: number,
	confirmTime: number,
	minOnTime: number,
	minSpeed: number,
}

type Entry = {
	visuals: WheelVisuals.WheelVisuals?,
	retryAt: number, -- os.clock() before which a failed WheelVisuals.new is not tried again
	warned: boolean,
	brake: BrakeState,
	lamps: DriveController.Lamps,
	parkedFor: number, -- seconds the car's wheels have been updated since it was parked (anchored)
	promptConnections: { RBXScriptConnection }, -- keep the Drive prompt hidden on a car this player doesn't own
}

local VehicleVisualsController = {}

local entries: { [Model]: Entry } = {}
local renderConnection: RBXScriptConnection? = nil

-- Brake lamp inference (pure; a spec covers it) -------------------------------------------------------------

function VehicleVisualsController.newBrakeState(): BrakeState
	return { speed = nil, decel = 0, hardFor = 0, on = false, onFor = 0 }
end

-- Forgets a car's history (it went out of range, parked, or became the local player's car).
function VehicleVisualsController.resetBrakeState(state: BrakeState)
	state.speed = nil
	state.decel = 0
	state.hardFor = 0
	state.on = false
	state.onFor = 0
end

-- Feeds one frame of a car's forward speed into its brake state and returns whether the lamp is lit.
-- Deceleration is the drop in speed (either direction) per second, low-pass filtered with a dt-based blend so
-- it behaves the same from 30 to 144 fps. The lamp lights once that stays above onDecel for confirmTime
-- while the car is actually moving (so a one-frame dip from network jitter is ignored), and goes out below
-- offDecel after at least minOnTime.
function VehicleVisualsController.updateBrakeState(
	state: BrakeState,
	forwardSpeed: number,
	dt: number,
	settings: BrakeSettings?
): boolean
	local config: BrakeSettings = settings or Controls.otherCars.brakeLight
	local previous = state.speed
	state.speed = forwardSpeed
	if previous == nil or dt <= 0 then
		return state.on
	end

	local rawDecel = (math.abs(previous) - math.abs(forwardSpeed)) / dt
	local blend = 1 - math.exp(-dt / config.filterTime)
	state.decel += (rawDecel - state.decel) * blend

	if state.on then
		state.onFor += dt
		if state.decel < config.offDecel and state.onFor >= config.minOnTime then
			state.on = false
			state.hardFor = 0
		end
	elseif state.decel > config.onDecel and math.abs(forwardSpeed) > config.minSpeed then
		state.hardFor += dt
		if state.hardFor >= config.confirmTime then
			state.on = true
			state.onFor = 0
		end
	else
		state.hardFor = 0
	end
	return state.on
end

-- Tracking --------------------------------------------------------------------------------------------------

local function lampOff(entry: Entry)
	VehicleVisualsController.resetBrakeState(entry.brake)
	entry.lamps.set(BRAKE_LAMP, false) -- writes nothing unless this controller had lit it
end

-- A car this controller isn't animating right now (out of range, or the local player is driving it).
-- Its wheels settle again when it comes back.
local function skip(entry: Entry)
	lampOff(entry)
	entry.parkedFor = 0
end

-- True when all four wheels of the model contract are present with their Motor (WheelVisuals.new would
-- quietly skip a missing one).
local function wheelsReady(model: Model): boolean
	local folder = model:FindFirstChild("Wheels")
	if folder == nil then
		return false
	end
	for _, id in WheelVisuals.WHEEL_IDS do
		local wheel = folder:FindFirstChild(id)
		local motor = if wheel then wheel:FindFirstChild("Motor") else nil
		if motor == nil or not motor:IsA("Motor6D") then
			return false
		end
	end
	return true
end

-- WheelVisuals for a car, made on its first frame in range. A car still streaming in may not have its wheels
-- yet, so it is tried again after a short delay rather than every frame.
local function visualsFor(model: Model, entry: Entry, now: number): WheelVisuals.WheelVisuals?
	if entry.visuals or now < entry.retryAt then
		return entry.visuals
	end
	local ok: boolean, result: any = false, "a wheel or its Motor is missing"
	if wheelsReady(model) then
		ok, result = pcall(WheelVisuals.new, model)
	end
	if ok then
		entry.visuals = result
	else
		entry.retryAt = now + Controls.otherCars.retryDelay
		if not entry.warned then
			entry.warned = true
			warn(`[VehicleVisualsController] wheels not ready on {model:GetFullName()}: {result}`)
		end
	end
	return entry.visuals
end

local function onRender(dt: number)
	local camera = workspace.CurrentCamera
	if camera == nil then
		return
	end
	local origin = camera.CFrame.Position
	local maxDistance = Controls.otherCars.maxDistance
	local maxDistanceSquared = maxDistance * maxDistance
	local ownCar = DriveController.getCar()
	local now = os.clock()

	for model, entry in entries do
		local chassis = model.PrimaryPart
		if chassis == nil or model == ownCar then
			skip(entry)
			continue
		end
		local offset = chassis.Position - origin
		if offset:Dot(offset) > maxDistanceSquared then
			skip(entry)
			continue
		end

		-- A parked car is anchored and still: let its wheels settle briefly, then leave it until it moves.
		local parked = chassis.Anchored
		if parked then
			if entry.parkedFor >= Controls.otherCars.parkedSettleTime then
				continue
			end
			lampOff(entry)
		else
			entry.parkedFor = 0
		end

		local visuals = visualsFor(model, entry, now)
		if visuals then
			visuals:update(dt)
			if parked then
				entry.parkedFor += dt
			end
		end
		if not parked then
			local forwardSpeed = chassis.AssemblyLinearVelocity:Dot(chassis.CFrame.LookVector)
			entry.lamps.set(BRAKE_LAMP, VehicleVisualsController.updateBrakeState(entry.brake, forwardSpeed, dt))
		end
	end
end

-- Only the owner can drive a car, so on anyone else's car this client hides the Drive prompt, and keeps it
-- hidden whenever the server switches it back on (the server switches it per seat occupancy for everyone).
local function hideForeignDrivePrompt(model: Model, connections: { RBXScriptConnection })
	if model:GetAttribute("OwnerUserId") == Players.LocalPlayer.UserId then
		return
	end
	local function keepHidden(instance: Instance)
		if not instance:IsA("ProximityPrompt") or instance.Name ~= Spawning.prompt.driveName then
			return
		end
		local prompt = instance :: ProximityPrompt
		prompt.Enabled = false
		table.insert(
			connections,
			prompt:GetPropertyChangedSignal("Enabled"):Connect(function()
				if prompt.Enabled then
					prompt.Enabled = false
				end
			end)
		)
	end
	for _, descendant in model:GetDescendants() do
		keepHidden(descendant)
	end
	-- The server adds the prompts after the car itself, and a car can stream in piece by piece.
	table.insert(connections, model.DescendantAdded:Connect(keepHidden))
end

local function track(instance: Instance)
	if not instance:IsA("Model") or entries[instance] then
		return
	end
	local promptConnections: { RBXScriptConnection } = {}
	entries[instance] = {
		visuals = nil,
		retryAt = 0,
		warned = false,
		brake = VehicleVisualsController.newBrakeState(),
		lamps = DriveController.newLamps(instance),
		parkedFor = 0,
		promptConnections = promptConnections,
	}
	hideForeignDrivePrompt(instance, promptConnections)
	-- Only run per frame while there is at least one car to animate.
	if renderConnection == nil then
		renderConnection = RunService.RenderStepped:Connect(onRender)
	end
end

local function untrack(instance: Instance)
	if not instance:IsA("Model") then
		return
	end
	local entry = entries[instance]
	if entry == nil then
		return
	end
	entries[instance] = nil
	for _, connection in entry.promptConnections do
		connection:Disconnect()
	end
	-- A car that is still around (tag removed) is left with its lamps off and its wheels at rest; either way
	-- the WheelVisuals stops listening to the car's seats.
	entry.lamps.clear()
	if entry.visuals then
		entry.visuals:destroy()
	end
	if next(entries) == nil and renderConnection then
		renderConnection:Disconnect()
		renderConnection = nil
	end
end

function VehicleVisualsController:Start()
	CollectionService:GetInstanceAddedSignal(VEHICLE_TAG):Connect(track)
	CollectionService:GetInstanceRemovedSignal(VEHICLE_TAG):Connect(untrack)
	for _, instance in CollectionService:GetTagged(VEHICLE_TAG) do
		track(instance)
	end
end

return VehicleVisualsController
