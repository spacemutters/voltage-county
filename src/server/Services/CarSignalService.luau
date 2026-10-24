--!strict
-- The car's horn, headlights and indicators on the server (roast fixes, 2026-10-24; Net CarSignal).
--
-- Only the driver signals. The caller's character must sit in the Seat named "Driver" (vehicle model contract) of a
-- car tagged Config/Spawning.vehicleTag whose OwnerUserId is theirs (VehicleService lets only the owner drive and
-- stands anyone else straight back up), and that seat's Occupant must be the caller's living Humanoid. Anything else
-- is ignored. The server then writes Config/Controls carSignals.attributes on the car model, which every client
-- reads: Controllers/VehicleSoundController plays the horn (and the driver's indicator tick), and
-- Controllers/VehicleVisualsController lights the lamps. One attribute write per press, nothing per frame.
--
--   hornOn / hornOff   Horn = true / nil. Every hornOn also starts a carSignals.hornMaxSeconds timer tied to that
--                      press (a serial), so a hornOff lost on the way (a dropped finger, a lost packet) can't leave
--                      the horn stuck on: when the timer ends and that press is still the one sounding, it stops.
--   headlights         flips what the driver sees: Headlights = "on" or "off", or back to nil (automatic: on at
--                      night, Config/Controls.isNight on Lighting.ClockTime) whenever the flip agrees with what
--                      automatic would show anyway.
--   indicatorLeft / indicatorRight / hazards
--                      Indicator = "left" / "right" / "hazards"; pressing the one that is on turns it off (nil).
--
-- When the driver leaves the seat (gets out, dies, leaves the game) or the car leaves the world, every signal on it is
-- cleared and the car is forgotten; the next press after getting back in starts fresh. Event-driven (the seat's
-- Occupant and the car's AncestryChanged), no polling.
--
-- The pure rules (carOfDriverSeat, newSignals, apply, hornExpired, nextIndicator, nextHeadlights) are exported for
-- tests/CarSignal.spec.

local CollectionService = game:GetService("CollectionService")
local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Controls = require(ReplicatedStorage.Shared.Config.Controls)
local Net = require(ReplicatedStorage.Shared.Net)
local Spawning = require(ReplicatedStorage.Shared.Config.Spawning)

local DRIVER_SEAT = "Driver" -- vehicle model contract
local OWNER_ATTRIBUTE = "OwnerUserId" -- VehicleService marks every player car with its owner
local VEHICLE_ID_ATTRIBUTE = "VehicleId"

export type Action = "hornOn" | "hornOff" | "headlights" | "indicatorLeft" | "indicatorRight" | "hazards"

-- One car's signals as the server keeps them (written to the car's attributes by `write`).
export type Signals = {
	horn: boolean,
	hornSerial: number, -- bumped by every hornOn, so only the latest press's timer can stop the horn
	headlights: Controls.HeadlightMode?, -- nil: automatic
	indicator: Controls.Indicator?, -- nil: off
}

type Record = {
	signals: Signals,
	connections: { RBXScriptConnection },
}

local INDICATOR_FOR: { [string]: Controls.Indicator } = {
	indicatorLeft = "left",
	indicatorRight = "right",
	hazards = "hazards",
}

local CarSignalService = {}

local records: { [Model]: Record } = {}

-- Pure rules (tests/CarSignal.spec) ---------------------------------------------------------------------------

-- The car `seat` is the Driver seat of, when `userId` owns that car; else nil. The car is the nearest ancestor model
-- with a VehicleId attribute (DriveController finds it the same way), and it must carry the vehicle tag.
function CarSignalService.carOfDriverSeat(seat: Instance?, userId: number): Model?
	if seat == nil or not seat:IsA("Seat") or seat.Name ~= DRIVER_SEAT then
		return nil
	end
	local node = seat.Parent
	while node ~= nil and node ~= workspace and node ~= game do
		if node:IsA("Model") and node:GetAttribute(VEHICLE_ID_ATTRIBUTE) ~= nil then
			local car = node :: Model
			if not CollectionService:HasTag(car, Spawning.vehicleTag) then
				return nil
			end
			return if car:GetAttribute(OWNER_ATTRIBUTE) == userId then car else nil
		end
		node = node.Parent
	end
	return nil
end

function CarSignalService.newSignals(): Signals
	return { horn = false, hornSerial = 0, headlights = nil, indicator = nil }
end

-- The indicator after pressing `pressed` with `current` on: the same one again turns it off.
function CarSignalService.nextIndicator(current: Controls.Indicator?, pressed: Controls.Indicator): Controls.Indicator?
	return if current == pressed then nil else pressed
end

-- The headlight mode after a press: the opposite of what shows now (`night` decides what automatic shows), or nil
-- (automatic) when that opposite is what automatic would show anyway.
function CarSignalService.nextHeadlights(current: Controls.HeadlightMode?, night: boolean): Controls.HeadlightMode?
	local want = not Controls.headlightsLit(current, night)
	if want == night then
		return nil
	end
	return if want then "on" else "off"
end

-- Applies one press to `signals`. Returns true when anything the clients see changed. A hornOn always bumps the
-- serial (the caller starts a new auto-off timer for it), even while the horn already sounds.
function CarSignalService.apply(signals: Signals, action: Action, night: boolean): boolean
	if action == "hornOn" then
		signals.hornSerial += 1
		local changed = not signals.horn
		signals.horn = true
		return changed
	elseif action == "hornOff" then
		local changed = signals.horn
		signals.horn = false
		return changed
	elseif action == "headlights" then
		signals.headlights = CarSignalService.nextHeadlights(signals.headlights, night)
		return true -- what shows always flips
	end
	local pressed = INDICATOR_FOR[action]
	if pressed == nil then
		return false
	end
	signals.indicator = CarSignalService.nextIndicator(signals.indicator, pressed)
	return true
end

-- The auto-off for the hornOn whose serial was `serial`: stops the horn when that press is still the one sounding.
-- Returns true when it stopped it.
function CarSignalService.hornExpired(signals: Signals, serial: number): boolean
	if signals.horn and signals.hornSerial == serial then
		signals.horn = false
		return true
	end
	return false
end

-- Cars --------------------------------------------------------------------------------------------------------

local function write(car: Model, signals: Signals)
	local attributes = Controls.carSignals.attributes
	car:SetAttribute(attributes.horn, if signals.horn then true else nil)
	car:SetAttribute(attributes.headlights, signals.headlights)
	car:SetAttribute(attributes.indicator, signals.indicator)
end

-- Clears every signal on the car and stops watching it.
local function forget(car: Model)
	local record = records[car]
	if record == nil then
		return
	end
	records[car] = nil
	for _, connection in record.connections do
		connection:Disconnect()
	end
	if car.Parent ~= nil then
		write(car, CarSignalService.newSignals())
	end
end

-- The record for a car its driver just signalled, watching for the driver to leave the seat and the car to go.
local function recordFor(car: Model, seat: Seat, humanoid: Humanoid): Record
	local existing = records[car]
	if existing ~= nil then
		return existing
	end
	local record: Record = { signals = CarSignalService.newSignals(), connections = {} }
	records[car] = record
	table.insert(
		record.connections,
		seat:GetPropertyChangedSignal("Occupant"):Connect(function()
			if seat.Occupant ~= humanoid then
				forget(car)
			end
		end)
	)
	table.insert(
		record.connections,
		car.AncestryChanged:Connect(function()
			if not car:IsDescendantOf(game) then
				forget(car)
			end
		end)
	)
	return record
end

-- The car the player drives right now (see the header), with its Driver seat and the player's Humanoid.
local function drivenCar(player: Player): (Model?, Seat?, Humanoid?)
	local character = player.Character
	local found = if character then character:FindFirstChildOfClass("Humanoid") else nil
	if found == nil or found.Health <= 0 then
		return nil, nil, nil
	end
	local humanoid = found :: Humanoid
	local seatPart = humanoid.SeatPart
	local car = CarSignalService.carOfDriverSeat(seatPart, player.UserId)
	if car == nil or seatPart == nil then
		return nil, nil, nil
	end
	local seat = seatPart :: Seat
	if seat.Occupant ~= humanoid then
		return nil, nil, nil
	end
	return car, seat, humanoid
end

local function onCarSignal(player: Player, payload: any)
	local action = payload.action :: Action
	local car, seat, humanoid = drivenCar(player)
	if car == nil or seat == nil or humanoid == nil then
		return -- not the driver of a car: nothing to signal
	end
	local record = recordFor(car, seat, humanoid)
	local signals = record.signals
	if CarSignalService.apply(signals, action, Controls.isNight(Lighting.ClockTime)) then
		write(car, signals)
	end
	if action == "hornOn" then
		local serial = signals.hornSerial
		task.delay(Controls.carSignals.hornMaxSeconds, function()
			if records[car] == record and CarSignalService.hornExpired(signals, serial) then
				write(car, signals)
			end
		end)
	end
end

function CarSignalService:Start()
	Net.onServerEvent("CarSignal", onCarSignal)
end

return CarSignalService
