--!strict
-- Trailers and towed cars on this client (PLAN.md Phase 8, docs/phase-8-contracts.md "Trailers and towed cars").
--
-- The local rig. Services/HitchService couples a trailer or towed car to a tractor with a BallSocketConstraint,
-- hands both to the driver (network ownership) and marks the tractor: attribute TowingModel = the target's name
-- and an ObjectValue Towing pointing at it (Config/Trailers' names). While the local player drives
-- (DriveController.onDrivingChanged), this watches that car's attribute, its Towing child and the value's
-- Changed signal (no polling). Once the target has arrived (Vehicle/Trailer.isReady: the value can point at a
-- model a moment before it streams in), it builds a Vehicle/Trailer with the target's Config/Trailers spec and
-- steps it every RunService.PreSimulation:
--   * brake input from the driver's controls and the tractor's telemetry (Trailer.brakeInput: the slowing pedal,
--     the hold brake at a standstill, a coast brake off the throttle matching the tractor's lift-off at the
--     driver's regen level and drive mode), so the trailer brakes with its tractor, at Config/Trailers.brakeRatio
--     x the tractor's own full brake (Trailer.brakeDecelFor) so it never pushes;
--   * an overspeed cap at the tractor's top speed (Vehicle/Tuning), or its limp speed while the server has it
--     limping (the tractor's Limp attribute, cached from its changed signal), so a heavy trailer never pushes the
--     rig past what anti-exploit allows downhill;
--   * the trailer's own Brake and Reverse lamps lit with the tractor's (DriveController's lamp switching).
-- Uncoupling (the attribute or value cleared), leaving the seat, or the target leaving the world stops it.
--
-- Step order. The trailer's handler is connected after the tractor's (DriveController fires onDrivingChanged once
-- its chassis is stepping). Roblox doesn't promise an order between handlers of one event, and nothing here
-- depends on it: tractor and trailer are separate assemblies, both apply their impulses before the same physics
-- step, and the trailer reads nothing of the tractor but its spin (yaw damping) and pose (articulation).
--
-- Other trailers. Every model tagged Config/Trailers.tag or towedTag (a job's towed car) is tracked through
-- CollectionService signals (no polling). Each RenderStepped, unanchored ones within Controls.otherCars.maxDistance of the camera get their
-- wheels posed from raycasts and their landing legs cranked up (Trailer.newVisuals), like
-- VehicleVisualsController does for cars; parked ones settle for Controls.otherCars.parkedSettleTime and are then
-- left alone. The local rig's own trailer is skipped (its Trailer poses it). A towed car is not a player's car
-- (no Config/Spawning.vehicleTag), so VehicleVisualsController never sees it: its front wheels hang and its rear
-- wheels roll here (Trailer.newVisuals with Config/Trailers.towed).

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Chassis = require(ReplicatedStorage.Shared.Vehicle.Chassis)
local Controls = require(ReplicatedStorage.Shared.Config.Controls)
local Spawning = require(ReplicatedStorage.Shared.Config.Spawning)
local Trailer = require(ReplicatedStorage.Shared.Vehicle.Trailer)
local Trailers = require(ReplicatedStorage.Shared.Config.Trailers)
local Tuning = require(ReplicatedStorage.Shared.Vehicle.Tuning)
local DriveController = require(script.Parent.DriveController)
local InputController = require(script.Parent.InputController)

-- Car attribute the server (EnergyService) sets while the car has no energy left (docs/phase-5-contracts.md).
local LIMP_ATTRIBUTE = "Limp"
-- Model contract lamp names (Lights/<name>).
local BRAKE_LAMP = "Brake"
local REVERSE_LAMP = "Reverse"

-- The car the local player drives, watched for a coupling.
type Watch = {
	car: Model,
	topSpeed: number?, -- the tractor's top speed, studs/s (nil: no tuning, no overspeed cap)
	brakeDecel: number?, -- the tractor's full-brake deceleration, studs/s² (nil: no tuning)
	energy: string?, -- the tractor's "battery" or "fuel" (its lift-off: regen or engine braking)
	limp: boolean, -- the tractor's Limp attribute
	connections: { RBXScriptConnection },
	valueConnection: RBXScriptConnection?, -- the Towing value's Changed
	pending: Model?, -- a coupled target we are waiting on to finish arriving
	generation: number, -- bumped whenever the target changes, so an older wait gives up
}

-- The coupled target being stepped.
type Session = {
	target: Model,
	trailer: Trailer.Trailer,
	lamps: DriveController.Lamps?,
	stepConnection: RBXScriptConnection,
	ancestryConnection: RBXScriptConnection,
}

-- Another trailer, animated on this client.
type Remote = {
	visuals: Trailer.Visuals?,
	retryAt: number, -- os.clock() before which a failed set-up is not tried again
	parkedFor: number, -- seconds its wheels have been updated since it was parked (anchored)
}

local TrailerController = {}

local watch: Watch? = nil
local session: Session? = nil
local remotes: { [Model]: Remote } = {}
local renderConnection: RBXScriptConnection? = nil

-- The local rig --------------------------------------------------------------------------------------------

-- The model the server has coupled to `car` (its TowingModel attribute and Towing value), or nil.
function TrailerController.coupledTo(car: Model): Model?
	local name = car:GetAttribute(Trailers.towingAttribute)
	if type(name) ~= "string" or name == "" then
		return nil
	end
	local value = car:FindFirstChild(Trailers.towingValue)
	if value == nil or not value:IsA("ObjectValue") then
		return nil
	end
	local target = value.Value
	if target == nil or not target:IsA("Model") or not target:IsDescendantOf(Workspace) then
		return nil
	end
	return target
end

-- The trailer or towed car the local player's rig is pulling right now, or nil.
function TrailerController.getTarget(): Model?
	return if session then session.target else nil
end

-- The local rig's hitch articulation at the last step, in degrees (Vehicle/Trailer.articulation), or nil when
-- nothing is coupled. Compare with Config/Trailers.jackknifeAngle.
function TrailerController.getArticulationDegrees(): number?
	return if session then math.deg(session.trailer:getArticulation()) else nil
end

local function speedCapOf(current: Watch): number?
	return if current.limp then Chassis.limpSpeed() else current.topSpeed
end

local function stopSession()
	local current = session
	if current == nil then
		return
	end
	session = nil
	current.stepConnection:Disconnect()
	current.ancestryConnection:Disconnect()
	if current.lamps then
		current.lamps.clear()
	end
	local ok, err = pcall(function()
		current.trailer:destroy()
	end)
	if not ok then
		warn(`[TrailerController] trailer:destroy failed for {current.target.Name}: {err}`)
	end
end

local refresh: () -> ()

local function startSession(current: Watch, target: Model, spec: Trailer.Spec)
	local ok, result = pcall(Trailer.new, target, spec, current.car)
	if not ok then
		warn(`[TrailerController] could not set up {target.Name}: {result}`)
		return
	end
	local trailer: Trailer.Trailer = result
	trailer:setSpeedCap(speedCapOf(current))
	local brakeDecel = Trailer.brakeDecelFor(spec, current.brakeDecel)
	trailer:setBrakeDecel(brakeDecel)
	local energy = current.energy

	-- A towed car is a tagged car: VehicleVisualsController already draws its lamps (and its wheels).
	local lamps = if target:HasTag(Spawning.vehicleTag) then nil else DriveController.newLamps(target)
	local threshold = Controls.lamps.pedalThreshold
	local stepConnection = RunService.PreSimulation:Connect(function(dt: number)
		local controls = InputController.getControls()
		local telemetry = DriveController.getTelemetry()
		local liftOff = Trailer.liftOffDecel(energy, DriveController.getMode(), DriveController.getRegen())
		trailer:step(dt, Trailer.brakeInput(controls, telemetry, brakeDecel, liftOff))
		if lamps then
			-- The tractor's lamp rule (DriveController): in reverse the throttle is the pedal that slows it.
			local reversing = telemetry ~= nil and telemetry.reversing
			lamps.set(BRAKE_LAMP, if reversing then controls.throttle > threshold else controls.brake > threshold)
			lamps.set(REVERSE_LAMP, reversing)
		end
	end)
	local ancestryConnection = target.AncestryChanged:Connect(function()
		if not target:IsDescendantOf(Workspace) then
			refresh()
		end
	end)
	session = {
		target = target,
		trailer = trailer,
		lamps = lamps,
		stepConnection = stepConnection,
		ancestryConnection = ancestryConnection,
	}
end

-- Starts, swaps or stops the session to match what the watched car is coupled to.
refresh = function()
	local current = watch
	local target = if current then TrailerController.coupledTo(current.car) else nil
	if session and session.target == target then
		return
	end
	if current and target and current.pending == target then
		return -- already waiting for it to arrive
	end
	stopSession()
	if current == nil then
		return
	end
	current.generation += 1
	current.pending = nil
	if target == nil then
		return
	end
	local spec = Trailer.specFor(target)
	if spec == nil then
		warn(`[TrailerController] {target.Name} is neither a Config/Trailers trailer nor a towed car`)
		return
	end
	if Trailer.isReady(target, spec) then
		startSession(current, target, spec)
		return
	end

	-- Wait (event-driven) for the rest of the model, then start if the car is still coupled to it.
	local generation = current.generation
	current.pending = target
	local done = false
	local connection: RBXScriptConnection
	local function finish(ready: boolean)
		if done then
			return
		end
		done = true
		connection:Disconnect()
		if watch ~= current or current.generation ~= generation then
			return
		end
		current.pending = nil
		if ready and TrailerController.coupledTo(current.car) == target then
			startSession(current, target, spec)
		elseif not ready then
			warn(`[TrailerController] {target.Name} didn't finish arriving within {Controls.carReadyTimeout} s`)
		end
	end
	connection = target.DescendantAdded:Connect(function()
		if Trailer.isReady(target, spec) then
			finish(true)
		end
	end)
	task.delay(Controls.carReadyTimeout, function()
		finish(Trailer.isReady(target, spec))
	end)
end

-- Follows the Towing value under the watched car (it is replaced on every coupling).
local function watchValue(current: Watch)
	local previous = current.valueConnection
	if previous then
		previous:Disconnect()
		current.valueConnection = nil
	end
	local value = current.car:FindFirstChild(Trailers.towingValue)
	if value and value:IsA("ObjectValue") then
		current.valueConnection = value.Changed:Connect(function()
			refresh()
		end)
	end
end

local function stopWatching()
	local current = watch
	if current == nil then
		return
	end
	watch = nil
	for _, connection in current.connections do
		connection:Disconnect()
	end
	table.clear(current.connections)
	local valueConnection = current.valueConnection
	if valueConnection then
		valueConnection:Disconnect()
		current.valueConnection = nil
	end
	current.generation += 1
	current.pending = nil
	stopSession()
end

local function startWatching(car: Model)
	stopWatching()
	local vehicleId, trimId = car:GetAttribute("VehicleId"), car:GetAttribute("Trim")
	local tuning = if type(vehicleId) == "string" and type(trimId) == "string"
		then Tuning.forTrim(vehicleId, trimId)
		else nil
	local current: Watch = {
		car = car,
		topSpeed = if tuning then tuning.topSpeed else nil,
		brakeDecel = if tuning then tuning.brakeDecel else nil,
		energy = if tuning then tuning.energy else nil,
		limp = car:GetAttribute(LIMP_ATTRIBUTE) == true,
		connections = {},
		valueConnection = nil,
		pending = nil,
		generation = 0,
	}
	watch = current

	local function onChild(child: Instance)
		if child.Name == Trailers.towingValue then
			watchValue(current)
			refresh()
		end
	end
	local connections = current.connections
	table.insert(connections, car:GetAttributeChangedSignal(Trailers.towingAttribute):Connect(refresh))
	table.insert(connections, car.ChildAdded:Connect(onChild))
	table.insert(connections, car.ChildRemoved:Connect(onChild))
	table.insert(
		connections,
		car:GetAttributeChangedSignal(LIMP_ATTRIBUTE):Connect(function()
			current.limp = car:GetAttribute(LIMP_ATTRIBUTE) == true
			if session and watch == current then
				session.trailer:setSpeedCap(speedCapOf(current))
			end
		end)
	)
	watchValue(current)
	refresh()
end

-- Other trailers ---------------------------------------------------------------------------------------------

-- Wheel and leg posing for a trailer, made on its first frame in range. One still streaming in is tried again
-- after a short delay rather than every frame.
local function visualsFor(model: Model, entry: Remote, now: number): Trailer.Visuals?
	if entry.visuals or now < entry.retryAt then
		return entry.visuals
	end
	local spec = Trailer.specFor(model)
	if spec and Trailer.isReady(model, spec) then
		local ok, result = pcall(Trailer.newVisuals, model, spec)
		if ok then
			entry.visuals = result
			return result
		end
	end
	entry.retryAt = now + Controls.otherCars.retryDelay
	return nil
end

local function onRender(dt: number)
	local camera = Workspace.CurrentCamera
	if camera == nil then
		return
	end
	local origin = camera.CFrame.Position
	local maxDistance = Controls.otherCars.maxDistance
	local maxDistanceSquared = maxDistance * maxDistance
	local own = if session then session.target else nil
	local now = os.clock()

	for model, entry in remotes do
		local chassis = model.PrimaryPart
		if model == own then
			-- The local rig's Trailer poses it; a fresh set-up follows when it is someone else's again.
			entry.visuals = nil
			entry.parkedFor = 0
			continue
		end
		if chassis == nil then
			continue
		end
		local offset = chassis.Position - origin
		if offset:Dot(offset) > maxDistanceSquared then
			entry.parkedFor = 0
			continue
		end
		-- A parked trailer is anchored and still: let it settle briefly, then leave it until it moves.
		if chassis.Anchored then
			if entry.parkedFor >= Controls.otherCars.parkedSettleTime then
				continue
			end
		else
			entry.parkedFor = 0
		end
		local visuals = visualsFor(model, entry, now)
		if visuals then
			visuals:update(dt)
			if chassis.Anchored then
				entry.parkedFor += dt
			end
		end
	end
end

local function track(instance: Instance)
	if not instance:IsA("Model") or remotes[instance] then
		return
	end
	remotes[instance] = { visuals = nil, retryAt = 0, parkedFor = 0 }
	-- Only run per frame while there is at least one trailer to animate.
	if renderConnection == nil then
		renderConnection = RunService.RenderStepped:Connect(onRender)
	end
end

local function untrack(instance: Instance)
	if not instance:IsA("Model") then
		return
	end
	local entry = remotes[instance]
	if entry == nil then
		return
	end
	remotes[instance] = nil
	if entry.visuals then
		entry.visuals:destroy()
	end
	if next(remotes) == nil and renderConnection then
		renderConnection:Disconnect()
		renderConnection = nil
	end
end

function TrailerController:Start()
	DriveController.onDrivingChanged:Connect(function(driving: boolean, car: Model?)
		if driving and car then
			startWatching(car)
		else
			stopWatching()
		end
	end)
	local car = DriveController.getCar()
	if car then
		startWatching(car)
	end

	for _, tag in { Trailers.tag, Trailers.towedTag } do
		CollectionService:GetInstanceAddedSignal(tag):Connect(track)
		CollectionService:GetInstanceRemovedSignal(tag):Connect(untrack)
		for _, instance in CollectionService:GetTagged(tag) do
			track(instance)
		end
	end
end

return TrailerController
