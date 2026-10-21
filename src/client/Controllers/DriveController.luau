--!strict
-- Client side of driving the local player's own car (docs/phase-1-contracts.md "Client").
--
-- Watches the local Humanoid's SeatPart. When it becomes the Seat named "Driver" inside a model with a
-- VehicleId attribute, this builds the trim's Vehicle/Tuning and a Vehicle/Chassis, turns InputController on
-- and steps the chassis every RunService.PreSimulation with the current controls. (The server unanchors the
-- car and gives this client network ownership when the owner sits in the Driver seat; VehicleService.)
-- It also lights the car's own brake and reverse lamps on this client, keeps the drive mode and regen level
-- (cycled from InputController's signals, kept across cars for the session), and clears the chassis state
-- when the server moves the car back (Net "VehicleReset"). Leaving the seat stops all of it. While the
-- character sits in any seat (driver or passenger), this client hides every proximity prompt.

local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Appearance = require(ReplicatedStorage.Shared.Vehicle.Appearance)
local Chassis = require(ReplicatedStorage.Shared.Vehicle.Chassis)
local Controls = require(ReplicatedStorage.Shared.Config.Controls)
local Net = require(ReplicatedStorage.Shared.Net)
local Tuning = require(ReplicatedStorage.Shared.Vehicle.Tuning)
local Types = require(ReplicatedStorage.Shared.Types)
local InputController = require(script.Parent.InputController)

-- Model contract names (PLAN.md §6).
local DRIVER_SEAT = "Driver"
local LIGHTS_FOLDER = "Lights"
local LIGHT_INSTANCE = "Light"

-- A car's lamps, switched on this client only. set() writes properties only when a lamp actually changes,
-- so it is cheap to call every frame; clear() turns every lamp it lit back off; refresh() writes its state again
-- (after something else, like a light show, drew on the same lamps).
export type Lamps = {
	set: (name: string, on: boolean) -> (),
	clear: () -> (),
	refresh: () -> (),
}

type Session = {
	car: Model,
	chassis: Chassis.Chassis,
	lamps: Lamps,
	stepConnection: RBXScriptConnection,
}

local DriveController = {}

-- Fires (driving: boolean, car: Model?) when the local player starts or stops driving.
DriveController.onDrivingChanged = InputController.newSignal()

local session: Session? = nil
local mode: Types.DriveMode = Controls.defaultMode
local regen: Types.RegenLevel = Controls.defaultRegen

-- Pure helpers -----------------------------------------------------------------------------------------------

local function nextIn<T>(list: { T }, current: T): T
	local index = table.find(list, current) or 0
	return list[index % #list + 1]
end

-- The drive mode after `current` in Config/Controls.modeCycle (comfort -> standard -> sport -> comfort).
function DriveController.nextMode(current: Types.DriveMode): Types.DriveMode
	return nextIn(Controls.modeCycle, current)
end

-- The regen level after `current` in Config/Controls.regenCycle (low -> standard -> high -> low).
function DriveController.nextRegen(current: Types.RegenLevel): Types.RegenLevel
	return nextIn(Controls.regenCycle, current)
end

-- Lamps -----------------------------------------------------------------------------------------------------

-- Every lamp part's unlit material, recorded the first time anything lights it (weak keys: parts come and go).
-- Shared by every Lamps set and by LightShowController, so whoever turns a lamp off restores the real material.
local offMaterials: { [BasePart]: Enum.Material } = setmetatable({}, { __mode = "k" }) :: any
-- Live Lamps sets per car, so a light show that borrowed a car's lamps can hand them back (refreshLamps).
local liveLamps: { [Model]: { [Lamps]: boolean } } = setmetatable({}, { __mode = "k" }) :: any

-- Records a lamp part's unlit material if nothing has yet (call before lighting it).
function DriveController.rememberLampMaterial(part: BasePart)
	if offMaterials[part] == nil and part.Material ~= Controls.lamps.onMaterial then
		offMaterials[part] = part.Material
	end
end

-- The lamp part's unlit material, or nil if nothing has lit it.
function DriveController.lampOffMaterial(part: BasePart): Enum.Material?
	return offMaterials[part]
end

-- Re-applies the live lamp state of every Lamps set on `car` (after a light show put its lamps back).
function DriveController.refreshLamps(car: Model)
	local sets = liveLamps[car]
	if sets ~= nil then
		for lamps in sets do
			lamps.refresh()
		end
	end
end

-- Lamp switching for any car that follows the model contract: Lights/<name> is a part holding a Light named
-- "Light". A lit lamp turns that Light on and makes the part glow; turning it off restores the part's own
-- material (and hides an art model's overlay again). Also used by VehicleVisualsController for other players'
-- brake lamps.
function DriveController.newLamps(car: Model): Lamps
	local lit: { [string]: boolean } = {}

	local function write(name: string, on: boolean)
		local lights = car:FindFirstChild(LIGHTS_FOLDER)
		local part = if lights then lights:FindFirstChild(name) else nil
		if part == nil or not part:IsA("BasePart") then
			return
		end
		local light = part:FindFirstChild(LIGHT_INSTANCE)
		if light and light:IsA("Light") then
			light.Enabled = on
		end
		if on then
			DriveController.rememberLampMaterial(part)
			part.Material = Controls.lamps.onMaterial
		else
			local off = offMaterials[part]
			if off ~= nil then
				part.Material = off
			end
		end
		-- An art model's lamp is a glow overlay: it shows only while lit (Vehicle/Appearance).
		local transparency = Appearance.lampOverlayTransparency(part, if on then 1 else 0)
		if transparency ~= nil then
			part.Transparency = transparency
		end
	end

	local function set(name: string, on: boolean)
		if (lit[name] == true) == on then
			return
		end
		lit[name] = on
		write(name, on)
	end

	local function refresh()
		for name, on in lit do
			write(name, on)
		end
	end

	local lamps: Lamps
	local function clear()
		for name, on in lit do
			if on then
				set(name, false)
			end
		end
		local sets = liveLamps[car]
		if sets ~= nil then
			sets[lamps] = nil
		end
	end

	lamps = { set = set, clear = clear, refresh = refresh }
	local sets = liveLamps[car]
	if sets == nil then
		sets = {}
		liveLamps[car] = sets
	end
	(sets :: { [Lamps]: boolean })[lamps] = true
	return lamps
end

local function updateLamps(chassis: Chassis.Chassis, lamps: Lamps, controls: Types.Controls)
	local telemetry = chassis:getTelemetry()
	local threshold = Controls.lamps.pedalThreshold
	-- In reverse the pedals swap roles: the brake pedal drives backwards and the throttle slows the car
	-- (Vehicle/Powertrain), so the brake lamps follow whichever pedal is slowing it.
	local braking = if telemetry.reversing then controls.throttle > threshold else controls.brake > threshold
	lamps.set("Brake", braking)
	lamps.set("Reverse", telemetry.reversing)
end

-- Driving sessions ------------------------------------------------------------------------------------------

local function stopDriving()
	local current = session
	if current == nil then
		return
	end
	session = nil
	current.stepConnection:Disconnect()
	current.lamps.clear()
	InputController.setEnabled(false)
	local ok, err = pcall(function()
		current.chassis:destroy()
	end)
	if not ok then
		warn(`[DriveController] chassis:destroy failed for {current.car.Name}: {err}`)
	end
	DriveController.onDrivingChanged:Fire(false, nil)
end

local function startDriving(car: Model)
	local vehicleId = car:GetAttribute("VehicleId")
	local trimId = car:GetAttribute("Trim")
	if type(vehicleId) ~= "string" or type(trimId) ~= "string" then
		warn(`[DriveController] {car.Name} is missing its VehicleId or Trim attribute`)
		return
	end
	local tuning = Tuning.forTrim(vehicleId, trimId)
	if tuning == nil then
		warn(`[DriveController] no tuning for {vehicleId}/{trimId}`)
		return
	end
	local ok, result = pcall(Chassis.new, car, tuning)
	if not ok then
		warn(`[DriveController] could not set up the chassis for {car.Name}: {result}`)
		return
	end

	local chassis: Chassis.Chassis = result
	chassis:setMode(mode)
	chassis:setRegen(regen)

	local lamps = DriveController.newLamps(car)
	local stepConnection = RunService.PreSimulation:Connect(function(dt: number)
		local controls = InputController.getControls()
		chassis:step(dt, controls)
		updateLamps(chassis, lamps, controls)
	end)
	session = {
		car = car,
		chassis = chassis,
		lamps = lamps,
		stepConnection = stepConnection,
	}
	InputController.setEnabled(true)
	DriveController.onDrivingChanged:Fire(true, car)
end

-- The car whose Driver seat this is, or nil if the seat isn't a car's Driver seat.
local function carForSeat(seatPart: BasePart?): Model?
	if seatPart == nil or not seatPart:IsA("Seat") or seatPart.Name ~= DRIVER_SEAT then
		return nil
	end
	local node = seatPart.Parent
	while node ~= nil and node ~= workspace do
		if node:IsA("Model") and node:GetAttribute("VehicleId") ~= nil then
			return node
		end
		node = node.Parent
	end
	return nil
end

-- While the local character sits in any seat, this client shows no prompts: the server refuses every seat
-- prompt from a seated player anyway, and a passenger seat's Ride prompt would otherwise sit on the gamepad's
-- handbrake button (Config/Controls) and float over the touch controls.
local promptsHidden = false
local promptsWereEnabled = true

local function hidePrompts(hide: boolean)
	if hide == promptsHidden then
		return
	end
	promptsHidden = hide
	if hide then
		promptsWereEnabled = ProximityPromptService.Enabled
		ProximityPromptService.Enabled = false
	else
		ProximityPromptService.Enabled = promptsWereEnabled
	end
end

local WHEEL_NAMES = { "FL", "FR", "RL", "RR" }

-- True once every part the chassis needs has reached this client: the Chassis and the four wheels with their
-- motors (model contract). With streaming on, the Driver seat can arrive a moment before the rest of the car.
local function carIsReady(car: Model): boolean
	if car:FindFirstChild("Chassis") == nil then
		return false
	end
	local wheels = car:FindFirstChild("Wheels")
	if wheels == nil then
		return false
	end
	for _, name in WHEEL_NAMES do
		local wheel = wheels:FindFirstChild(name)
		if wheel == nil or wheel:FindFirstChild("Motor") == nil then
			return false
		end
	end
	return true
end

-- Bumped on every seat change, so a wait for an older seat gives up once the player has moved on.
local seatGeneration = 0

local function onSeatChanged(humanoid: Humanoid)
	hidePrompts(humanoid.SeatPart ~= nil)
	local car = carForSeat(humanoid.SeatPart)
	if session and session.car == car then
		return
	end
	seatGeneration += 1
	stopDriving()
	if car == nil then
		return
	end
	if carIsReady(car) then
		startDriving(car)
		return
	end
	-- Wait (event-driven) for the rest of the car, then start if the player is still in this seat.
	local generation = seatGeneration
	local seat = humanoid.SeatPart
	local done = false
	local connection: RBXScriptConnection
	local function finish(ready: boolean)
		if done then
			return
		end
		done = true
		connection:Disconnect()
		if generation ~= seatGeneration or humanoid.SeatPart ~= seat then
			return
		end
		if ready then
			startDriving(car)
		else
			warn(`[DriveController] {car.Name} didn't finish arriving within {Controls.carReadyTimeout} s`)
		end
	end
	connection = car.DescendantAdded:Connect(function()
		if carIsReady(car) then
			finish(true)
		end
	end)
	task.delay(Controls.carReadyTimeout, function()
		finish(carIsReady(car))
	end)
end

local seatConnection: RBXScriptConnection? = nil

local function unwatchCharacter()
	if seatConnection then
		seatConnection:Disconnect()
		seatConnection = nil
	end
	hidePrompts(false)
	stopDriving()
end

local function watchCharacter(character: Model)
	unwatchCharacter()
	local found = character:FindFirstChildOfClass("Humanoid") or character:WaitForChild("Humanoid")
	-- The character may have been replaced while we waited for its Humanoid.
	if Players.LocalPlayer.Character ~= character or not found:IsA("Humanoid") then
		return
	end
	local humanoid = found :: Humanoid
	seatConnection = humanoid:GetPropertyChangedSignal("SeatPart"):Connect(function()
		onSeatChanged(humanoid)
	end)
	onSeatChanged(humanoid)
end

-- Public API ------------------------------------------------------------------------------------------------

-- This frame's telemetry from the chassis, or nil when the local player isn't driving.
function DriveController.getTelemetry(): Types.Telemetry?
	return if session then session.chassis:getTelemetry() else nil
end

-- The car the local player is driving, or nil.
function DriveController.getCar(): Model?
	return if session then session.car else nil
end

function DriveController.getMode(): Types.DriveMode
	return mode
end

function DriveController.setMode(newMode: Types.DriveMode)
	if table.find(Controls.modeCycle, newMode) == nil then
		warn(`[DriveController] unknown drive mode "{newMode}"`)
		return
	end
	mode = newMode
	if session then
		session.chassis:setMode(newMode)
	end
end

function DriveController.getRegen(): Types.RegenLevel
	return regen
end

function DriveController.setRegen(level: Types.RegenLevel)
	if table.find(Controls.regenCycle, level) == nil then
		warn(`[DriveController] unknown regen level "{level}"`)
		return
	end
	regen = level
	if session then
		session.chassis:setRegen(level)
	end
end

function DriveController:Start()
	local player = Players.LocalPlayer

	InputController.onCycleMode:Connect(function()
		DriveController.setMode(DriveController.nextMode(mode))
	end)
	InputController.onCycleRegen:Connect(function()
		DriveController.setRegen(DriveController.nextRegen(regen))
	end)

	-- The server moved the car (anti-exploit reset or unstuck): forget the chassis's per-frame history.
	Net.onClientEvent("VehicleReset", function(_payload: any)
		if session then
			session.chassis:reset()
		end
	end)

	player.CharacterAdded:Connect(watchCharacter)
	player.CharacterRemoving:Connect(unwatchCharacter)
	if player.Character then
		watchCharacter(player.Character)
	end
end

return DriveController
