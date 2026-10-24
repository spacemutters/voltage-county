--!strict
-- Car sounds on this client, and the driver's horn, headlight and indicator controls (roast fixes, 2026-10-24).
--
-- Sounds (Config/Audio loops, sfx and car). Every client makes every nearby car's sounds itself from that car's
-- replicated motion, so nothing goes over the network per frame:
--   engine   battery cars (Vehicle/Tuning energy "battery") whine: pitch and volume rise with the share of the trim's
--            top speed, and with the throttle (evSound). Fuel cars rev through the same automatic as the chassis
--            (Config/Driving powertrain.fuel: up at upshiftAt of a gear's top, down below downshiftAt of the gear
--            below's): the pitch climbs through each gear and drops on every upshift, and the volume dips while the
--            shift lasts (stepGearbox, engineSound). The local driver's own car follows its telemetry (gear,
--            throttle); every other car runs the gearbox rule on its speed, and its throttle is read from its
--            acceleration (loadFrom). A fuel car's loop: car.engineByVehicle, else car.engineByClass by its class,
--            else car.defaultEngine. An engine runs while someone sits in the Driver seat (or, on a car built
--            without one like the Pod, while it isn't parked).
--   tyres    a squeal while the chassis slides sideways faster than tyre.slipStartMph, on the ground (squealAmount;
--            the ground is checked with one short ray down, and only while the car slides).
--   wind     one flat loop for the car the local player sits in, driver or passenger, from wind.startMph up.
--   horn     a loop on each car while its Horn attribute is set (Services/CarSignalService decides who may honk).
--   tick     the driver's indicator relay: a click as the lamps come on and a lower one as they go off, on the same
--            server-clock flash as VehicleVisualsController's lamps (Controls.blinkOn).
-- Only cars within car.maxDistance of the camera make sounds, and only the car.maxEngines nearest of those with their
-- engine running get an engine and tyres (nearest, picked again every car.rankInterval seconds). Sounds are 3D on the
-- car's Chassis with the roll-off in Config/Audio loops; each is made once per car the first time it is needed
-- (never per frame), stopped while it isn't, and destroyed with the car. A loop whose assetId is 0 is never made.
-- One RenderStepped connection, alive only while a car is tracked; a Sound's Volume and PlaybackSpeed are written
-- only when they move by car.minChange. Cars are found through CollectionService's vehicle tag (no polling).
--
-- Controls (Config/Controls horn, headlights, indicatorLeft, indicatorRight, hazards): bound through
-- ContextActionService only while the local player drives (DriveController.onDrivingChanged), at the driving
-- priority. The touch Horn and Lights buttons (UI/TouchControls) call setHorn and signal. Each press sends Net
-- CarSignal; the server checks the caller drives the car and writes the car's attributes, which every client reads.
-- The horn is a hold, let go when the key or button is, when driving stops, and when the window loses focus or a
-- text box takes the keyboard. signalsChanged fires (DriverSignals) whenever the driven car's signals change, for
-- the touch Lights button.
--
-- The pure parts (newGearbox, stepGearbox, followGear, engineSound, evSound, loadFrom, squealAmount, windAmount,
-- engineFor, nearest) are exported for tests/VehicleSound.spec.

local CollectionService = game:GetService("CollectionService")
local ContextActionService = game:GetService("ContextActionService")
local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local Audio = require(Shared.Config.Audio)
local Catalog = require(Shared.Vehicle.Catalog)
local Controls = require(Shared.Config.Controls)
local Driving = require(Shared.Config.Driving)
local Net = require(Shared.Net)
local Spawning = require(Shared.Config.Spawning)
local Tuning = require(Shared.Vehicle.Tuning)
local Types = require(Shared.Types)
local Units = require(Shared.Util.Units)
local DriveController = require(script.Parent.DriveController)
local InputController = require(script.Parent.InputController)

local SOUND_PREFIX = "CarSound_"
local DRIVER_SEAT = "Driver" -- vehicle model contract (Seats/Driver)
local SEATS_FOLDER = "Seats"
local ACTION_PREFIX = "VoltageSignal_"
local HORN_ACTION = ACTION_PREFIX .. "Horn"

local car = Audio.car
local signalAttributes = Controls.carSignals.attributes

export type Gearbox = {
	gear: number, -- 1..#gearSpeeds
	shiftTimer: number, -- seconds left in an upshift's dip
}

-- What the touch Lights button (and anything else on the driver's screen) shows of the driven car.
export type DriverSignals = {
	horn: boolean,
	headlights: boolean, -- shining (the driver's choice, or automatic at night)
	indicator: Controls.Indicator?,
}

-- A press the driver can send (the horn goes through setHorn).
export type SignalAction = "headlights" | "indicatorLeft" | "indicatorRight" | "hazards"

type Sounds = {
	engine: Sound?,
	tyre: Sound?,
	horn: Sound?,
}

type Entry = {
	model: Model,
	resolved: boolean, -- energy and engine looked up (on first need)
	energy: ("battery" | "fuel")?, -- nil: no tuning for this car (it gets a horn, nothing else)
	tuning: Tuning.Tuning?,
	engine: Audio.EngineSound?, -- fuel cars
	gearbox: Gearbox,
	lastSpeed: number?, -- last forward speed sampled, studs/s (nil until the first sample while audible)
	accel: number, -- filtered change of speed, studs/s^2 (other players' throttle)
	squeal: number, -- filtered 0..1
	driverSeat: Seat?,
	sounds: Sounds,
	audible: boolean, -- picked this round for its engine and tyres
	inRange: boolean, -- within car.maxDistance of the camera this round
	horn: boolean, -- its Horn attribute
	connections: { RBXScriptConnection },
}

local VehicleSoundController = {}

-- Fires (signals: DriverSignals) when the driven car's horn, headlights or indicator change.
VehicleSoundController.signalsChanged = InputController.newSignal()

local entries: { [Model]: Entry } = {}
local renderConnection: RBXScriptConnection? = nil
local sinceRank = math.huge -- rank on the first frame

-- Flat sounds (made once, on Start, when their asset ids are set).
local windSound: Sound? = nil
local tickSound: Sound? = nil

-- The car the local character sits in (any seat), for the wind.
local ridingCar: Model? = nil

-- The local player's drive: the car, what holds the horn, and the last flash half the tick played.
local drivenCar: Model? = nil
local driveConnections: { RBXScriptConnection } = {}
local hornHolders: { [string]: boolean } = {}
local hornSent = false
local drivenIndicator: Controls.Indicator? = nil -- the driven car's Indicator attribute, kept by announce
local lastFlash: boolean? = nil
local boundActions: { string } = {}

local groundParams = RaycastParams.new()
groundParams.FilterType = Enum.RaycastFilterType.Exclude
groundParams.IgnoreWater = false

-- Pure helpers (tests/VehicleSound.spec) ------------------------------------------------------------------------

function VehicleSoundController.newGearbox(): Gearbox
	return { gear = 1, shiftTimer = 0 }
end

-- Runs the automatic's rule (Config/Driving powertrain.fuel) on another car's `speed` (studs/s, either direction)
-- for `dt` seconds. Returns the revs as a share of the current gear's top speed (0..1) and whether an upshift's dip
-- is running. A car first heard at speed settles straight into its gear.
function VehicleSoundController.stepGearbox(
	box: Gearbox,
	gearSpeeds: { number },
	speed: number,
	dt: number
): (number, boolean)
	local fuel = Driving.powertrain.fuel
	local count = #gearSpeeds
	if count == 0 then
		return 0, false
	end
	box.gear = math.clamp(box.gear, 1, count)
	box.shiftTimer = math.max(0, box.shiftTimer - dt)
	local s = math.abs(speed)
	while box.gear < count and s >= gearSpeeds[box.gear] * fuel.upshiftAt do
		box.gear += 1
		box.shiftTimer = fuel.shiftTime
	end
	while box.gear > 1 and s < gearSpeeds[box.gear - 1] * fuel.downshiftAt do
		box.gear -= 1
	end
	return math.clamp(s / gearSpeeds[box.gear], 0, 1), box.shiftTimer > 0
end

-- The local driver's car: the gear comes from its telemetry ("1".."5"; "R" counts as first). Same returns as
-- stepGearbox; a higher gear than last frame starts the dip.
function VehicleSoundController.followGear(
	box: Gearbox,
	gearSpeeds: { number },
	gear: string,
	speed: number,
	dt: number
): (number, boolean)
	local count = #gearSpeeds
	if count == 0 then
		return 0, false
	end
	local index = math.clamp(tonumber(gear) or 1, 1, count)
	box.shiftTimer = math.max(0, box.shiftTimer - dt)
	if index > box.gear then
		box.shiftTimer = Driving.powertrain.fuel.shiftTime
	end
	box.gear = index
	return math.clamp(math.abs(speed) / gearSpeeds[index], 0, 1), box.shiftTimer > 0
end

-- A fuel engine's PlaybackSpeed and its share of the loop's volume at `revs` (0..1 of the gear) and `load`
-- (throttle 0..1), dipped while `shifting`.
function VehicleSoundController.engineSound(
	engine: Audio.EngineSound,
	revs: number,
	load: number,
	shifting: boolean
): (number, number)
	local r = math.clamp(revs, 0, 1)
	local pitch = engine.idlePitch + (engine.redlinePitch - engine.idlePitch) * r
	local share = math.clamp(engine.idleVolume + engine.loadVolume * math.clamp(load, 0, 1), 0, 1)
	if shifting then
		share *= car.shiftDip
	end
	return pitch, share
end

-- A battery car's whine: PlaybackSpeed and share of the loop's volume at `speedShare` (0..1 of its top speed) and
-- `load` (throttle 0..1).
function VehicleSoundController.evSound(speedShare: number, load: number): (number, number)
	local ev = car.ev
	local s = math.clamp(speedShare, 0, 1)
	local pitch = ev.minPitch + (ev.maxPitch - ev.minPitch) * s
	local share = math.clamp(ev.idleVolume + ev.speedVolume * s + ev.loadVolume * math.clamp(load, 0, 1), 0, 1)
	return pitch, share
end

-- Another player's throttle, guessed from the car's filtered acceleration (studs/s^2) and its speed share (holding
-- a high speed takes throttle too).
function VehicleSoundController.loadFrom(accel: number, speedShare: number): number
	local load = car.load
	return math.clamp(accel / load.fullAccel + load.cruiseLoad * math.clamp(speedShare, 0, 1), 0, 1)
end

-- How hard the tyres squeal (0..1) for a chassis sliding sideways at `lateralMph` while moving at `speedMph`.
function VehicleSoundController.squealAmount(lateralMph: number, speedMph: number): number
	local tyre = car.tyre
	if speedMph < tyre.minSpeedMph then
		return 0
	end
	return math.clamp((lateralMph - tyre.slipStartMph) / (tyre.slipFullMph - tyre.slipStartMph), 0, 1)
end

-- How loud the wind is (0..1) in a car going `speedMph`.
function VehicleSoundController.windAmount(speedMph: number): number
	local wind = car.wind
	local share = math.clamp((speedMph - wind.startMph) / (wind.fullMph - wind.startMph), 0, 1)
	return share ^ wind.curve
end

-- The engine loop a fuel car of `vehicleId` and `class` gets (car.engineByVehicle, else engineByClass, else the
-- default), as its id into car.engines.
function VehicleSoundController.engineFor(vehicleId: string, class: string?): string
	return car.engineByVehicle[vehicleId] or (if class then car.engineByClass[class] else nil) or car.defaultEngine
end

-- The `count` nearest keys of `distances` (any key to a distance), as a set.
function VehicleSoundController.nearest<T>(distances: { [T]: number }, count: number): { [T]: boolean }
	local keys: { T } = {}
	for key in distances do
		table.insert(keys, key)
	end
	table.sort(keys, function(a: T, b: T): boolean
		return distances[a] < distances[b]
	end)
	local picked: { [T]: boolean } = {}
	for index = 1, math.min(count, #keys) do
		picked[keys[index]] = true
	end
	return picked
end

-- Sounds -------------------------------------------------------------------------------------------------------

local function loopSound(id: string, name: string, parent: Instance?, spatial: boolean): Sound?
	local loop = Audio.loops[id]
	if loop == nil or loop.assetId <= 0 or parent == nil then
		return nil -- a placeholder: nothing is made
	end
	local sound = Instance.new("Sound")
	sound.Name = SOUND_PREFIX .. name
	sound.SoundId = `rbxassetid://{loop.assetId}`
	sound.Looped = true
	sound.Volume = 0
	if spatial then
		sound.RollOffMode = Enum.RollOffMode.InverseTapered
		sound.RollOffMinDistance = loop.rollOffMinDistance
		sound.RollOffMaxDistance = loop.rollOffMaxDistance
	end
	sound.Parent = parent
	return sound
end

-- Plays `sound` at `volume` (0 stops it) and `pitch`, writing only what moved by car.minChange.
local function drive(sound: Sound?, volume: number, pitch: number)
	if sound == nil then
		return
	end
	local minChange = car.minChange
	if volume < minChange then
		if sound.Playing then
			sound:Stop()
		end
		return
	end
	if math.abs(sound.Volume - volume) >= minChange then
		sound.Volume = volume
	end
	if math.abs(sound.PlaybackSpeed - pitch) >= minChange then
		sound.PlaybackSpeed = pitch
	end
	if not sound.Playing then
		sound:Play()
	end
end

local function loopVolume(id: string): number
	local loop = Audio.loops[id]
	return if loop then loop.volume else 0
end

-- Looks the car's energy and engine loop up, once.
local function resolve(entry: Entry)
	if entry.resolved then
		return
	end
	entry.resolved = true
	local vehicleId = entry.model:GetAttribute("VehicleId")
	local trimId = entry.model:GetAttribute("Trim")
	if type(vehicleId) ~= "string" or type(trimId) ~= "string" then
		return
	end
	local tuning = Tuning.forTrim(vehicleId, trimId)
	if tuning == nil then
		return
	end
	entry.tuning = tuning
	entry.energy = tuning.energy
	if tuning.energy == "fuel" then
		local vehicle = Catalog.getVehicle(vehicleId)
		entry.engine = car.engines[VehicleSoundController.engineFor(vehicleId, if vehicle then vehicle.class else nil)]
			or car.engines[car.defaultEngine]
	end
end

-- Makes the car's engine and tyre sounds on its Chassis, the first time it is picked.
local function makeSounds(entry: Entry, chassis: BasePart)
	local sounds = entry.sounds
	if sounds.engine == nil then
		local engine = entry.engine
		local id = if entry.energy == "battery" then car.ev.loop elseif engine then engine.loop else nil
		if id ~= nil then
			sounds.engine = loopSound(id, "Engine", chassis, true)
		end
	end
	if sounds.tyre == nil then
		sounds.tyre = loopSound(car.tyre.loop, "Tyres", chassis, true)
	end
end

-- Stops the car's engine and tyres (they come back the next time it is picked) and forgets its motion.
local function stopEngine(entry: Entry)
	drive(entry.sounds.engine, 0, 1)
	drive(entry.sounds.tyre, 0, 1)
	entry.lastSpeed = nil
	entry.accel = 0
	entry.squeal = 0
end

-- Whether the car's engine runs: someone in its Driver seat, or (a car built without one) not parked.
local function engineRunning(entry: Entry, chassis: BasePart): boolean
	local seat = entry.driverSeat
	if seat == nil then
		local seats = entry.model:FindFirstChild(SEATS_FOLDER)
		local found = if seats then seats:FindFirstChild(DRIVER_SEAT) else nil
		if found ~= nil and found:IsA("Seat") then
			seat = found :: Seat
			entry.driverSeat = seat
		end
	end
	if seat ~= nil then
		return seat.Occupant ~= nil
	end
	return not chassis.Anchored
end

local function updateHorn(entry: Entry)
	local chassis = entry.model.PrimaryPart
	local on = entry.horn and entry.inRange and chassis ~= nil
	local sounds = entry.sounds
	if on and sounds.horn == nil then
		sounds.horn = loopSound(car.horn.loop, "Horn", chassis, true)
	end
	drive(sounds.horn, if on then loopVolume(car.horn.loop) else 0, 1)
end

-- Picks which cars are in range and which of them get engines (nearest first).
local function rank(origin: Vector3)
	local maxDistance = car.maxDistance
	local running: { [Entry]: number } = {}
	for model, entry in entries do
		local chassis = model.PrimaryPart
		local distance = if chassis then (chassis.Position - origin).Magnitude else math.huge
		local wasInRange = entry.inRange
		entry.inRange = distance <= maxDistance
		if entry.inRange ~= wasInRange then
			updateHorn(entry)
		end
		if entry.inRange and chassis ~= nil then
			resolve(entry)
			if entry.energy ~= nil and engineRunning(entry, chassis) then
				running[entry] = distance
			end
		end
	end
	local picked = VehicleSoundController.nearest(running, car.maxEngines)
	for model, entry in entries do
		local audible = picked[entry] == true
		if audible and not entry.audible then
			local chassis = model.PrimaryPart
			if chassis ~= nil then
				makeSounds(entry, chassis)
			end
		elseif entry.audible and not audible then
			stopEngine(entry)
		end
		entry.audible = audible
	end
end

-- A fuel car's revs (0..1 of its gear) and whether a shift dip runs: the local driver's from its telemetry, any
-- other car's from the gearbox rule on its speed.
local function revsOf(entry: Entry, gearSpeeds: { number }, telemetry: Types.Telemetry?, forward: number, dt: number)
	if telemetry ~= nil then
		return VehicleSoundController.followGear(entry.gearbox, gearSpeeds, telemetry.gear, telemetry.speed, dt)
	end
	return VehicleSoundController.stepGearbox(entry.gearbox, gearSpeeds, forward, dt)
end

-- One frame of one audible car's engine and tyres.
local function stepCar(entry: Entry, chassis: BasePart, dt: number)
	local tuning = entry.tuning
	if tuning == nil then
		return
	end
	local velocity = chassis.AssemblyLinearVelocity
	local frame = chassis.CFrame
	local forward = velocity:Dot(frame.LookVector)
	local speed = math.abs(forward)
	local speedShare = if tuning.topSpeed > 0 then speed / tuning.topSpeed else 0

	-- Throttle: the local driver's own, else read from the car's acceleration.
	local last = entry.lastSpeed
	entry.lastSpeed = forward
	if last ~= nil and dt > 0 then
		local raw = (speed - math.abs(last)) / dt
		local blend = 1 - math.exp(-dt / car.load.filterTime)
		entry.accel += (raw - entry.accel) * blend
	end
	local telemetry = if entry.model == drivenCar then DriveController.getTelemetry() else nil
	local load = if telemetry then telemetry.throttle else VehicleSoundController.loadFrom(entry.accel, speedShare)

	local engine = entry.engine
	if entry.energy == "battery" then
		local pitch, share = VehicleSoundController.evSound(speedShare, load)
		drive(entry.sounds.engine, share * loopVolume(car.ev.loop), pitch)
	elseif engine ~= nil then
		local revs, shifting = revsOf(entry, tuning.gearSpeeds, telemetry, forward, dt)
		local pitch, share = VehicleSoundController.engineSound(engine, revs, load, shifting)
		drive(entry.sounds.engine, share * loopVolume(engine.loop), pitch)
	end

	-- Tyres: sideways sliding, on the ground (one short ray, only while it slides).
	local tyre = car.tyre
	local lateralMph = Units.studsToMph(math.abs(velocity:Dot(frame.RightVector)))
	local target = VehicleSoundController.squealAmount(lateralMph, Units.studsToMph(velocity.Magnitude))
	if target > 0 then
		groundParams.FilterDescendantsInstances = { entry.model }
		local hit = Workspace:Raycast(chassis.Position, -frame.UpVector * tyre.groundProbe, groundParams)
		if hit == nil then
			target = 0
		end
	end
	local blend = if dt > 0 then 1 - math.exp(-dt / tyre.filterTime) else 1
	entry.squeal += (target - entry.squeal) * blend
	local tyrePitch = tyre.minPitch + (tyre.maxPitch - tyre.minPitch) * entry.squeal
	drive(entry.sounds.tyre, entry.squeal * loopVolume(tyre.loop), tyrePitch)
end

-- The wind in the car the local player sits in.
local function stepWind()
	local sound = windSound
	if sound == nil then
		return
	end
	local riding = ridingCar
	local chassis = if riding then riding.PrimaryPart else nil
	if chassis == nil then
		drive(sound, 0, 1)
		return
	end
	local wind = car.wind
	local amount = VehicleSoundController.windAmount(Units.studsToMph(chassis.AssemblyLinearVelocity.Magnitude))
	drive(sound, amount * loopVolume(wind.loop), wind.minPitch + (wind.maxPitch - wind.minPitch) * amount)
end

-- The driver's indicator tick, on the lamps' flash.
local function stepTick()
	local sound = tickSound
	if sound == nil or drivenCar == nil or drivenIndicator == nil then
		lastFlash = nil
		return
	end
	local flash = Controls.blinkOn(Workspace:GetServerTimeNow())
	if flash == lastFlash then
		return
	end
	local first = lastFlash == nil
	lastFlash = flash
	if first and not flash then
		return -- the indicator came on in the dark half: the first click comes with the light
	end
	local tick = car.indicatorTick
	sound.PlaybackSpeed = if flash then tick.onPlaybackSpeed else tick.offPlaybackSpeed
	sound:Play()
end

local function onRender(dt: number)
	local camera = Workspace.CurrentCamera
	if camera == nil then
		return
	end
	sinceRank += dt
	if sinceRank >= car.rankInterval then
		sinceRank = 0
		rank(camera.CFrame.Position)
	end
	for model, entry in entries do
		local chassis = model.PrimaryPart
		if entry.audible and chassis ~= nil then
			stepCar(entry, chassis, dt)
		end
	end
	stepWind()
	stepTick()
end

-- Tracking cars ----------------------------------------------------------------------------------------------

local function track(instance: Instance)
	if not instance:IsA("Model") or entries[instance] then
		return
	end
	local model = instance :: Model
	local entry: Entry = {
		model = model,
		resolved = false,
		energy = nil,
		tuning = nil,
		engine = nil,
		gearbox = VehicleSoundController.newGearbox(),
		lastSpeed = nil,
		accel = 0,
		squeal = 0,
		driverSeat = nil,
		sounds = {},
		audible = false,
		inRange = false,
		horn = model:GetAttribute(signalAttributes.horn) == true,
		connections = {},
	}
	entries[model] = entry
	table.insert(
		entry.connections,
		model:GetAttributeChangedSignal(signalAttributes.horn):Connect(function()
			entry.horn = model:GetAttribute(signalAttributes.horn) == true
			updateHorn(entry)
		end)
	)
	sinceRank = math.huge -- hear a car that just arrived straight away
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
	for _, connection in entry.connections do
		connection:Disconnect()
	end
	local sounds = entry.sounds
	for _, sound in { sounds.engine, sounds.tyre, sounds.horn } :: { Sound? } do
		if sound ~= nil then
			sound:Destroy()
		end
	end
	if ridingCar == instance then
		ridingCar = nil
	end
	if next(entries) == nil and renderConnection then
		renderConnection:Disconnect()
		renderConnection = nil
		stepWind() -- the wind stops with the last car
	end
end

-- The car whose seat this is (any seat), or nil.
local function carOfSeat(seat: Instance?): Model?
	local node = if seat then seat.Parent else nil
	while node ~= nil and node ~= Workspace do
		if node:IsA("Model") and node:GetAttribute("VehicleId") ~= nil then
			return node :: Model
		end
		node = node.Parent
	end
	return nil
end

local seatConnection: RBXScriptConnection? = nil

local function watchCharacter(character: Model?)
	if seatConnection then
		seatConnection:Disconnect()
		seatConnection = nil
	end
	ridingCar = nil
	if character == nil then
		return
	end
	local found = character:FindFirstChildOfClass("Humanoid") or character:WaitForChild("Humanoid", 10)
	if found == nil or not found:IsA("Humanoid") or Players.LocalPlayer.Character ~= character then
		return
	end
	local humanoid = found :: Humanoid
	local function update()
		ridingCar = carOfSeat(humanoid.SeatPart)
	end
	seatConnection = humanoid:GetPropertyChangedSignal("SeatPart"):Connect(update)
	update()
end

-- The driver's signals -------------------------------------------------------------------------------------------

function VehicleSoundController.getDriverSignals(): DriverSignals
	local driven = drivenCar
	if driven == nil then
		return { horn = false, headlights = false, indicator = nil }
	end
	local mode = Controls.readHeadlights(driven:GetAttribute(signalAttributes.headlights))
	return {
		horn = driven:GetAttribute(signalAttributes.horn) == true,
		headlights = Controls.headlightsLit(mode, Controls.isNight(Lighting.ClockTime)),
		indicator = Controls.readIndicator(driven:GetAttribute(signalAttributes.indicator)),
	}
end

local function announce()
	local signals = VehicleSoundController.getDriverSignals()
	drivenIndicator = signals.indicator
	VehicleSoundController.signalsChanged:Fire(signals)
end

-- Sends one press of the headlights or an indicator for the car the local player drives (the server decides).
function VehicleSoundController.signal(action: SignalAction)
	if drivenCar == nil then
		return
	end
	Net.fireServer("CarSignal", { action = action })
end

-- Holds or lets go of the horn. `source` names what holds it ("keys", "touch"), so the horn sounds while any of
-- them does.
function VehicleSoundController.setHorn(held: boolean, source: string?)
	hornHolders[source or "touch"] = if held then true else nil
	local on = drivenCar ~= nil and next(hornHolders) ~= nil
	if on == hornSent then
		return
	end
	hornSent = on
	if drivenCar ~= nil then
		Net.fireServer("CarSignal", { action = if on then "hornOn" else "hornOff" })
	end
end

local PRESS_ACTIONS: { [string]: SignalAction } = {
	[ACTION_PREFIX .. "Headlights"] = "headlights",
	[ACTION_PREFIX .. "IndicatorLeft"] = "indicatorLeft",
	[ACTION_PREFIX .. "IndicatorRight"] = "indicatorRight",
	[ACTION_PREFIX .. "Hazards"] = "hazards",
}

local function onSignalInput(
	actionName: string,
	state: Enum.UserInputState,
	_input: InputObject
): Enum.ContextActionResult
	if actionName == HORN_ACTION then
		if state == Enum.UserInputState.Begin then
			VehicleSoundController.setHorn(true, "keys")
		elseif state == Enum.UserInputState.End or state == Enum.UserInputState.Cancel then
			VehicleSoundController.setHorn(false, "keys")
		end
	elseif state == Enum.UserInputState.Begin then
		local action = PRESS_ACTIONS[actionName]
		if action ~= nil then
			VehicleSoundController.signal(action)
		end
	end
	return Enum.ContextActionResult.Sink
end

local function bindKeys()
	local keyboard, gamepad = Controls.keyboard, Controls.gamepad
	local bindings: { { name: string, keys: { { Enum.KeyCode } } } } = {
		{ name = HORN_ACTION, keys = { keyboard.horn, gamepad.horn } },
		{ name = ACTION_PREFIX .. "Headlights", keys = { keyboard.headlights, gamepad.headlights } },
		{ name = ACTION_PREFIX .. "IndicatorLeft", keys = { keyboard.indicatorLeft, gamepad.indicatorLeft } },
		{ name = ACTION_PREFIX .. "IndicatorRight", keys = { keyboard.indicatorRight, gamepad.indicatorRight } },
		{ name = ACTION_PREFIX .. "Hazards", keys = { keyboard.hazards, gamepad.hazards } },
	}
	for _, binding in bindings do
		local keys: { Enum.KeyCode } = {}
		for _, list in binding.keys do
			table.move(list, 1, #list, #keys + 1, keys)
		end
		if #keys > 0 then
			ContextActionService:BindActionAtPriority(
				binding.name,
				onSignalInput,
				false,
				Controls.actionPriority,
				table.unpack(keys)
			)
			table.insert(boundActions, binding.name)
		end
	end
end

local function unbindKeys()
	for _, name in boundActions do
		ContextActionService:UnbindAction(name)
	end
	table.clear(boundActions)
end

local function onDrivingChanged(driving: boolean, model: Model?)
	for _, connection in driveConnections do
		connection:Disconnect()
	end
	table.clear(driveConnections)
	unbindKeys()
	-- Whatever held the horn lets go (the server clears a car's signals when its driver leaves anyway).
	table.clear(hornHolders)
	hornSent = false
	lastFlash = nil
	drivenCar = if driving then model else nil
	local driven = drivenCar
	if driven ~= nil then
		bindKeys()
		for _, attribute in { signalAttributes.horn, signalAttributes.headlights, signalAttributes.indicator } do
			table.insert(driveConnections, driven:GetAttributeChangedSignal(attribute):Connect(announce))
		end
		-- The Lights button follows automatic headlights too: tell it when ClockTime crosses the day window.
		local night = Controls.isNight(Lighting.ClockTime)
		table.insert(
			driveConnections,
			Lighting:GetPropertyChangedSignal("ClockTime"):Connect(function()
				local now = Controls.isNight(Lighting.ClockTime)
				if now ~= night then
					night = now
					announce()
				end
			end)
		)
		-- A key held while the window loses focus (or chat opens) never reports its release.
		local function releaseKeys()
			VehicleSoundController.setHorn(false, "keys")
		end
		table.insert(driveConnections, UserInputService.WindowFocusReleased:Connect(releaseKeys))
		table.insert(driveConnections, UserInputService.TextBoxFocused:Connect(releaseKeys))
	end
	announce()
end

-- Boot -------------------------------------------------------------------------------------------------------

function VehicleSoundController:Start()
	windSound = loopSound(car.wind.loop, "Wind", SoundService, false)
	local tick = Audio.sfx[car.indicatorTick.sfx]
	if tick ~= nil and tick.assetId > 0 then
		local sound = Instance.new("Sound")
		sound.Name = SOUND_PREFIX .. "IndicatorTick"
		sound.SoundId = `rbxassetid://{tick.assetId}`
		sound.Volume = tick.volume
		sound.PlaybackSpeed = tick.playbackSpeed
		sound.Parent = SoundService
		tickSound = sound
	end

	local tag = Spawning.vehicleTag
	CollectionService:GetInstanceAddedSignal(tag):Connect(track)
	CollectionService:GetInstanceRemovedSignal(tag):Connect(untrack)
	for _, instance in CollectionService:GetTagged(tag) do
		track(instance)
	end

	local player = Players.LocalPlayer
	player.CharacterAdded:Connect(watchCharacter)
	player.CharacterRemoving:Connect(function()
		watchCharacter(nil)
	end)
	if player.Character then
		task.spawn(watchCharacter, player.Character)
	end

	DriveController.onDrivingChanged:Connect(onDrivingChanged)
	local current = DriveController.getCar()
	if current ~= nil then
		onDrivingChanged(true, current)
	end
end

return VehicleSoundController
