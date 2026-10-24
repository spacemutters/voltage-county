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
--
-- Signal lamps (roast fixes, 2026-10-24) on every car, the local player's own included: Services/CarSignalService
-- writes Config/Controls carSignals.attributes on the car and this client lights its Lights parts from them.
--   headlights   carSignals.headlightLamps (the head and tail lamps) shine while Controls.headlightsLit says so: the
--                driver's "on" / "off", or automatic, which shines while Lighting.ClockTime is outside the day window
--                (Controls.isNight, re-checked only when ClockTime crosses it).
--   indicators   each side's carSignals.indicatorLamps flash amber (both sides for hazards) on the server clock
--                (Controls.blinkOn on workspace:GetServerTimeNow()), so every client flashes a car together. Only
--                cars with an indicator on are looked at each frame.
-- These lamps are written by this controller alone (never through DriveController.newLamps, whose Brake and Reverse
-- lamps are other parts): a lamp is written only when its look changes, and a car nothing has signalled is never
-- touched. While the car is in a light show (Config/LightShows attributes.showId) its signal lamps are left to the
-- show (only an amber flash's colour is put back), and when the show lets go every signal lamp is written again.
-- The pure part (signalLook) is exported for tests/CarSignal.spec.

local CollectionService = game:GetService("CollectionService")
local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Appearance = require(ReplicatedStorage.Shared.Vehicle.Appearance)
local Controls = require(ReplicatedStorage.Shared.Config.Controls)
local LightShows = require(ReplicatedStorage.Shared.Config.LightShows)
local Spawning = require(ReplicatedStorage.Shared.Config.Spawning)
local WheelVisuals = require(ReplicatedStorage.Shared.Vehicle.WheelVisuals)
local DriveController = require(script.Parent.DriveController)

local VEHICLE_TAG = "Vehicle"
local BRAKE_LAMP = "Brake"
local LIGHTS_FOLDER = "Lights" -- model contract: Lights/<name> is a part holding a Light named "Light"
local LIGHT_INSTANCE = "Light"
local carSignals = Controls.carSignals
local signalAttributes = carSignals.attributes
local SHOW_ATTRIBUTE = LightShows.attributes.showId

-- How a signal lamp looks: dark, shining (headlights), flashing amber, or both (an indicator over a lit lamp).
export type SignalLook = "off" | "lit" | "amber" | "litAmber"

-- One car's signals as this client last read them from its attributes.
type SignalState = {
	headlights: Controls.HeadlightMode?,
	indicator: Controls.Indicator?,
	inShow: boolean,
	driverSeat: Seat?, -- automatic headlights shine only while someone sits here
	written: { [string]: SignalLook }, -- per lamp name, what was last written ("off" when missing)
	connections: { RBXScriptConnection },
}

-- Every lamp a signal can light, once each (headlight lamps first, then any indicator-only lamp).
local SIGNAL_LAMPS: { string } = table.clone(carSignals.headlightLamps)
local HEADLIGHT_LAMP: { [string]: boolean } = {}
for _, name in carSignals.headlightLamps do
	HEADLIGHT_LAMP[name] = true
end
for _, side in { "left", "right" } do
	for _, name in carSignals.indicatorLamps[side] or {} do
		if table.find(SIGNAL_LAMPS, name) == nil then
			table.insert(SIGNAL_LAMPS, name)
		end
	end
end

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
	signal: SignalState,
}

local VehicleVisualsController = {}

local entries: { [Model]: Entry } = {}
local renderConnection: RBXScriptConnection? = nil
-- Cars with an indicator on: the only ones whose signal lamps are looked at each frame.
local blinking: { [Model]: boolean } = {}
-- Whether automatic headlights shine now (Controls.isNight on Lighting.ClockTime).
local night = false
-- Each lamp part's own colour, recorded the first time it flashes amber (weak keys: parts come and go).
local lampColors: { [BasePart]: Color3 } = setmetatable({}, { __mode = "k" }) :: any

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

-- Signal lamps (the pure part is signalLook; a spec covers it) ---------------------------------------------

-- How the signal lamp `name` looks right now. `headlightsLit`: the car's headlights shine (its driver's choice, or
-- automatic at night, and only while someone drives it); `indicator`: the car's indicator; `flashOn`: the flash is
-- in its lit half (Controls.blinkOn). Hazards flash both sides' lamps.
function VehicleVisualsController.signalLook(
	name: string,
	headlightsLit: boolean,
	indicator: Controls.Indicator?,
	flashOn: boolean
): SignalLook
	local lit = headlightsLit and HEADLIGHT_LAMP[name] == true
	local amber = false
	if flashOn and indicator ~= nil then
		local sides = if indicator == "hazards" then { "left", "right" } else { indicator }
		for _, side in sides do
			local lamps = carSignals.indicatorLamps[side]
			if lamps ~= nil and table.find(lamps, name) ~= nil then
				amber = true
			end
		end
	end
	if lit and amber then
		return "litAmber"
	elseif amber then
		return "amber"
	end
	return if lit then "lit" else "off"
end

-- Writes one signal lamp's look onto Lights/<name>. A shining or flashing lamp glows in the lit material (and an
-- art model's overlay shows); only a shining one turns its Light on (an indicator flash doesn't throw a beam); a
-- flash paints the part amber over its own colour, which comes back after. Returns false while the part hasn't
-- streamed in (the look is written again on the car's next change).
local function writeSignalLamp(model: Model, name: string, look: SignalLook): boolean
	local lights = model:FindFirstChild(LIGHTS_FOLDER)
	local found = if lights then lights:FindFirstChild(name) else nil
	if found == nil or not found:IsA("BasePart") then
		return false
	end
	local part = found :: BasePart
	local lit = look == "lit" or look == "litAmber"
	local amber = look == "amber" or look == "litAmber"
	local glowing = lit or amber
	local light = part:FindFirstChild(LIGHT_INSTANCE)
	if light and light:IsA("Light") then
		light.Enabled = lit
	end
	if glowing then
		DriveController.rememberLampMaterial(part)
		part.Material = Controls.lamps.onMaterial
	else
		local off = DriveController.lampOffMaterial(part)
		if off ~= nil then
			part.Material = off
		end
	end
	if amber then
		if lampColors[part] == nil then
			lampColors[part] = part.Color
		end
		part.Color = carSignals.amber
	else
		local own = lampColors[part]
		if own ~= nil then
			part.Color = own
		end
	end
	local transparency = Appearance.lampOverlayTransparency(part, if glowing then 1 else 0)
	if transparency ~= nil then
		part.Transparency = transparency
	end
	return true
end

-- Writes every signal lamp of a car whose look changed (all of them with `force`, after a light show let go).
local function applySignals(model: Model, signal: SignalState, flashOn: boolean, force: boolean?)
	if signal.inShow then
		return
	end
	local seat = signal.driverSeat
	local driven = seat ~= nil and seat.Occupant ~= nil
	local headlightsLit = driven and Controls.headlightsLit(signal.headlights, night)
	for _, name in SIGNAL_LAMPS do
		local look = VehicleVisualsController.signalLook(name, headlightsLit, signal.indicator, flashOn)
		if force or (signal.written[name] or "off") ~= look then
			if writeSignalLamp(model, name, look) then
				signal.written[name] = look
			end
		end
	end
end

local function flashNow(): boolean
	return Controls.blinkOn(Workspace:GetServerTimeNow())
end

-- Reads the car's signal attributes and lights its lamps to match.
local function readSignals(model: Model, signal: SignalState)
	signal.headlights = Controls.readHeadlights(model:GetAttribute(signalAttributes.headlights))
	signal.indicator = Controls.readIndicator(model:GetAttribute(signalAttributes.indicator))
	blinking[model] = if signal.indicator ~= nil then true else nil
	applySignals(model, signal, flashNow())
end

-- The car joined or left a light show: the show draws on these lamps while it runs.
local function onShowChanged(model: Model, signal: SignalState)
	local inShow = model:GetAttribute(SHOW_ATTRIBUTE) ~= nil
	if inShow == signal.inShow then
		return
	end
	if inShow then
		-- Hand the lamps over: put back an amber flash's colour (the show never paints lamps) and forget what was
		-- written, since the show writes over it.
		for name, look in signal.written do
			if look == "amber" or look == "litAmber" then
				writeSignalLamp(model, name, if look == "litAmber" then "lit" else "off")
			end
		end
		table.clear(signal.written)
		signal.inShow = true
		return
	end
	signal.inShow = false
	-- Deferred, so LightShowController (listening to the same attribute) has put the show's lamps back first.
	task.defer(function()
		local entry = entries[model]
		if entry ~= nil and entry.signal == signal then
			applySignals(model, signal, flashNow(), true)
		end
	end)
end

-- Watches the car's Driver seat (automatic headlights shine only while someone drives), found now or when it
-- streams in.
local function watchDriverSeat(model: Model, signal: SignalState)
	local function use(seat: Instance): boolean
		if not seat:IsA("Seat") or seat.Name ~= "Driver" or signal.driverSeat ~= nil then
			return false
		end
		local driverSeat = seat :: Seat
		signal.driverSeat = driverSeat
		table.insert(
			signal.connections,
			driverSeat:GetPropertyChangedSignal("Occupant"):Connect(function()
				applySignals(model, signal, flashNow())
			end)
		)
		return true
	end
	local seats = model:FindFirstChild("Seats")
	local seat = if seats then seats:FindFirstChild("Driver") else nil
	if seat ~= nil and use(seat) then
		return
	end
	local connection: RBXScriptConnection
	connection = model.DescendantAdded:Connect(function(descendant: Instance)
		if use(descendant) then
			connection:Disconnect()
			applySignals(model, signal, flashNow())
		end
	end)
	table.insert(signal.connections, connection)
end

local function newSignalState(model: Model): SignalState
	local signal: SignalState = {
		headlights = nil,
		indicator = nil,
		inShow = model:GetAttribute(SHOW_ATTRIBUTE) ~= nil,
		driverSeat = nil,
		written = {},
		connections = {},
	}
	watchDriverSeat(model, signal)
	for _, attribute in { signalAttributes.headlights, signalAttributes.indicator } do
		table.insert(
			signal.connections,
			model:GetAttributeChangedSignal(attribute):Connect(function()
				readSignals(model, signal)
			end)
		)
	end
	table.insert(
		signal.connections,
		model:GetAttributeChangedSignal(SHOW_ATTRIBUTE):Connect(function()
			onShowChanged(model, signal)
		end)
	)
	return signal
end

-- Puts every signal lamp the car has lit back the way it was built, and stops watching it.
local function dropSignals(model: Model, signal: SignalState)
	for _, connection in signal.connections do
		connection:Disconnect()
	end
	table.clear(signal.connections)
	blinking[model] = nil
	if not signal.inShow then
		for name, look in signal.written do
			if look ~= "off" then
				writeSignalLamp(model, name, "off")
			end
		end
	end
	table.clear(signal.written)
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
	-- Indicators flash on every car that has one on, the local player's own included.
	if next(blinking) ~= nil then
		local flashOn = flashNow()
		for model in blinking do
			local entry = entries[model]
			if entry ~= nil then
				applySignals(model, entry.signal, flashOn)
			end
		end
	end

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
		signal = newSignalState(instance),
	}
	hideForeignDrivePrompt(instance, promptConnections)
	readSignals(instance, entries[instance].signal) -- a car that streams in mid-signal shows it at once
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
	dropSignals(instance, entry.signal)
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
	-- Automatic headlights follow the time of day: every car is looked at again only when ClockTime crosses the
	-- day window's edge.
	night = Controls.isNight(Lighting.ClockTime)
	Lighting:GetPropertyChangedSignal("ClockTime"):Connect(function()
		local now = Controls.isNight(Lighting.ClockTime)
		if now == night then
			return
		end
		night = now
		local flashOn = flashNow()
		for model, entry in entries do
			applySignals(model, entry.signal, flashOn)
		end
	end)
	CollectionService:GetInstanceAddedSignal(VEHICLE_TAG):Connect(track)
	CollectionService:GetInstanceRemovedSignal(VEHICLE_TAG):Connect(untrack)
	for _, instance in CollectionService:GetTagged(VEHICLE_TAG) do
		track(instance)
	end
end

return VehicleVisualsController
