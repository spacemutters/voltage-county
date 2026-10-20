--!strict
-- The driver's side of energy (docs/phase-5-contracts.md "Client"; PLAN.md Phase 5). The server owns every
-- car's level (Services/EnergyService) and publishes it as attributes on the car; this controller only shows
-- them and reacts to the server's alert:
--
--   energy row      while the local player drives, the car's attributes Energy (0..1), EnergyKind ("battery" |
--                   "fuel") and Limp become the HUD's energy row (HudController.setEnergy): the level, a battery
--                   or pump drawing, the estimated range in the player's units (Vehicle/Energy.rangeMiles, miles
--                   or kilometres per ProfileController), amber under Config/Energy.warningLevel, red under
--                   criticalLevel, and "Limp mode" once the car is empty (Vehicle/Chassis does the limiting).
--   charging card   while the car's Charging attribute is set: the level filling, the rate (ChargeRate, a fraction
--                   per second) and the cost per % (Vehicle/Energy.costPerFraction for the station the car stands
--                   at: the nearest compatible MapLayout station).
--   on empty        Net "EnergyAlert" { level, stationId? }: the GPS routes to the nearest compatible station
--                   (GpsController.setDestination) and a notice says so (NotifyController). The server sends its
--                   own "out of energy" notice too; this one names where the GPS is going.
--
-- Nothing polls: one AttributeChanged connection on the driven car (made when driving starts, dropped when it
-- stops), ProfileController.onChanged for the units, and the EnergyAlert remote. The pure helpers (alert level,
-- range, rate and cost texts, which station a car charges at, the whole view from a set of attributes) are on
-- the module so tests/EnergyClient.spec checks them in Edit mode.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Catalog = require(ReplicatedStorage.Shared.Vehicle.Catalog)
local Economy = require(ReplicatedStorage.Shared.Config.Economy)
local Energy = require(ReplicatedStorage.Shared.Vehicle.Energy)
local EnergyConfig = require(ReplicatedStorage.Shared.Config.Energy)
local MapLayout = require(ReplicatedStorage.Shared.Config.MapLayout)
local Net = require(ReplicatedStorage.Shared.Net)
local Units = require(ReplicatedStorage.Shared.Util.Units)
local DriveController = require(script.Parent.DriveController)
local GpsController = require(script.Parent.GpsController)
local HudController = require(script.Parent.HudController)
local InputController = require(script.Parent.InputController)
local NotifyController = require(script.Parent.NotifyController)
local ProfileController = require(script.Parent.ProfileController)

local Hud = require(script.Parent.Parent.UI.Hud)
local PhoneConfig = require(script.Parent.Parent.UI.Phone.PhoneConfig)

-- Car attributes (docs/phase-5-contracts.md "Server" and "Client"; the vehicle model contract for the ids).
local ATTRIBUTES = {
	energy = "Energy", -- 0..1, rounded to Config/Energy.sampling.attributeStep
	kind = "EnergyKind", -- "battery" | "fuel"
	limp = "Limp", -- true while the car is held to the limp speed
	charging = "Charging", -- true while the car charges or fuels at a station
	chargeRate = "ChargeRate", -- fraction per second while charging
	vehicleId = "VehicleId",
	trim = "Trim",
}

local PERCENT = 100
local TENTHS = 10
-- The HUD shows the level in steps of PhoneConfig.hud.energy.shownLevelStep, so it redraws when something
-- visible changes rather than on every server sample. Alerts use the exact level.
local SHOWN_LEVEL_STEP = PhoneConfig.hud.energy.shownLevelStep
-- Absorbs float noise when stepping the level down (0.7 / 0.005 is not exactly 140).
local STEP_EPSILON = 1e-6

-- What the driver reads (PhoneConfig.hud.energy.text).
local TEXT = PhoneConfig.hud.energy.text

export type EnergyKind = "battery" | "fuel"
export type StationKind = Energy.StationKind
export type AlertLevel = Hud.EnergyAlert

-- The car's energy attributes, as read (any of them may be missing before the server publishes them).
export type Attributes = {
	vehicleId: string?,
	trim: string?,
	energy: number?,
	kind: string?,
	limp: boolean,
	charging: boolean,
	chargeRate: number?,
}

-- What the HUD shows for the driven car right now.
export type State = { energy: Hud.Energy?, charging: Hud.Charging? }

local STATION_KINDS: { [string]: StationKind } = {
	ChargerStall = "ChargerStall" :: StationKind,
	TruckCharger = "TruckCharger" :: StationKind,
	FuelPump = "FuelPump" :: StationKind,
}

local EnergyController = {}
EnergyController.TEXT = TEXT
EnergyController.ATTRIBUTES = ATTRIBUTES

-- Fires (state: State) whenever what the HUD shows for the driven car changes.
EnergyController.onChanged = InputController.newSignal()

local state: State = { energy = nil, charging = nil }
local car: Model? = nil
local carConnection: RBXScriptConnection? = nil
local stationKind: StationKind? = nil -- where the car is charging, looked up once per charging stop
local locationsById: { [string]: MapLayout.Location } = {}
for _, location in MapLayout.locations do
	locationsById[location.id] = location
end

-- Pure helpers -------------------------------------------------------------------------------------------------

local function finiteNumber(value: any): number?
	if type(value) == "number" and value == value and value > -math.huge and value < math.huge then
		return value
	end
	return nil
end

-- How the energy row looks at `level`: "critical" under Config/Energy.criticalLevel, "low" under warningLevel,
-- "normal" otherwise (and while the level is unknown).
function EnergyController.alertFor(level: number?): AlertLevel
	if level == nil then
		return "normal"
	elseif level < EnergyConfig.criticalLevel then
		return "critical"
	elseif level < EnergyConfig.warningLevel then
		return "low"
	end
	return "normal"
end

-- "48 mi", "4.2 mi", or "77 km" for players whose speed units are km/h. Rounded down, so the HUD never
-- promises more than is left.
function EnergyController.rangeText(miles: number, units: string?): string
	local distance = math.max(0, finiteNumber(miles) or 0)
	local format = TEXT.rangeMiles
	if units == "kph" then
		-- x miles is as many km as x mph is km/h.
		distance = Units.studsToKph(Units.mphToStuds(distance))
		format = TEXT.rangeKilometers
	end
	local tenths = math.floor(distance * TENTHS)
	local shown = if distance < TEXT.decimalsBelow and tenths % TENTHS ~= 0
		then string.format("%.1f", tenths / TENTHS)
		else string.format("%d", math.floor(distance))
	return string.format(format, shown)
end

-- The level the HUD draws: `level` stepped down to SHOWN_LEVEL_STEP, so the bar and % never show more than is
-- left and the HUD redraws only when they visibly change.
function EnergyController.shownLevel(level: number): number
	local clamped = math.clamp(level, 0, 1)
	return math.min(1, math.floor(clamped / SHOWN_LEVEL_STEP + STEP_EPSILON) * SHOWN_LEVEL_STEP)
end

-- "+0.9% a sec" for a charge rate in fractions per second.
function EnergyController.rateText(ratePerSecond: number): string
	return string.format(TEXT.rate, math.max(0, finiteNumber(ratePerSecond) or 0) * PERCENT)
end

-- "$3 per %" for a station's cost per full charge (Vehicle/Energy.costPerFraction); nil when it's free.
function EnergyController.costText(costPerFraction: number): string?
	local perPercent = (finiteNumber(costPerFraction) or 0) / PERCENT
	if perPercent <= 0 then
		return nil
	end
	local price = if perPercent == math.floor(perPercent)
		then Economy.formatCash(perPercent)
		else Economy.display.symbol .. string.format("%.2f", perPercent)
	return string.format(TEXT.costPerPercent, price)
end

-- The kind of station a car at `position` is charging at: the nearest MapLayout station the vehicle may use (a
-- car can only charge inside a station's footprint, so the nearest compatible one is it). nil when the vehicle
-- is unknown or the map has none it may use.
function EnergyController.stationKindAt(position: Vector3, vehicleId: string): StationKind?
	local best: StationKind? = nil
	local bestDistance = math.huge
	for _, location in MapLayout.locations do
		local kind: StationKind? = STATION_KINDS[location.tag]
		if kind ~= nil and Energy.isCompatible(vehicleId, kind) then
			local offset = location.position - position
			local distance = Vector2.new(offset.X, offset.Z).Magnitude
			if distance < bestDistance then
				best, bestDistance = kind, distance
			end
		end
	end
	return best
end

-- The energy kind to show: the car's EnergyKind attribute, else the catalog's (nil for an unknown car).
local function kindOf(attributes: Attributes): EnergyKind?
	if attributes.kind == "battery" or attributes.kind == "fuel" then
		return attributes.kind :: EnergyKind
	end
	local vehicle = if attributes.vehicleId then Catalog.getVehicle(attributes.vehicleId) else nil
	return if vehicle then vehicle.energy else nil
end

-- What the HUD shows for a car with these attributes, in the player's `units` ("mph" | "kph"), charging at a
-- `station` kind (for the cost; nil: unknown). The energy is nil for a car the catalog doesn't know; the level
-- (and range) stay nil until the server publishes Energy; the charging card shows only while Charging is set
-- and the level is known.
function EnergyController.viewFor(attributes: Attributes, units: string, station: StationKind?): State
	local kind: EnergyKind? = kindOf(attributes)
	if kind == nil then
		return { energy = nil, charging = nil }
	end
	local raw = finiteNumber(attributes.energy)
	local level = if raw ~= nil then math.clamp(raw, 0, 1) else nil

	local rangeText: string? = nil
	if level ~= nil and attributes.vehicleId and attributes.trim then
		rangeText = EnergyController.rangeText(Energy.rangeMiles(attributes.vehicleId, attributes.trim, level), units)
	end
	local shown = if level ~= nil then EnergyController.shownLevel(level) else nil
	local energy: Hud.Energy = {
		kind = kind,
		level = shown,
		rangeText = rangeText,
		alert = EnergyController.alertFor(level),
		limp = attributes.limp,
	}

	local charging: Hud.Charging? = nil
	if attributes.charging and shown ~= nil then
		charging = {
			kind = kind,
			level = shown,
			rateText = EnergyController.rateText(finiteNumber(attributes.chargeRate) or 0),
			costText = if station then EnergyController.costText(Energy.costPerFraction(station)) else nil,
		}
	end
	return { energy = energy, charging = charging }
end

-- The driven car ---------------------------------------------------------------------------------------------------

local function readAttributes(model: Model): Attributes
	local vehicleId = model:GetAttribute(ATTRIBUTES.vehicleId)
	local trim = model:GetAttribute(ATTRIBUTES.trim)
	local kind = model:GetAttribute(ATTRIBUTES.kind)
	return {
		vehicleId = if type(vehicleId) == "string" then vehicleId else nil,
		trim = if type(trim) == "string" then trim else nil,
		energy = finiteNumber(model:GetAttribute(ATTRIBUTES.energy)),
		kind = if type(kind) == "string" then kind else nil,
		limp = model:GetAttribute(ATTRIBUTES.limp) == true,
		charging = model:GetAttribute(ATTRIBUTES.charging) == true,
		chargeRate = finiteNumber(model:GetAttribute(ATTRIBUTES.chargeRate)),
	}
end

-- True when two optional flat records hold the same fields.
local function sameRecord(a: { [string]: any }?, b: { [string]: any }?): boolean
	if a == nil or b == nil then
		return a == b
	end
	for key, value in a do
		if b[key] ~= value then
			return false
		end
	end
	for key in b do
		if a[key] == nil then
			return false
		end
	end
	return true
end

-- Hands a new view to the HUD and listeners, only when something shown changed (the level arrives several
-- times a second, but the HUD shows it in half-percent steps).
local function publish(shown: State)
	if
		sameRecord(state.energy :: any, shown.energy :: any)
		and sameRecord(state.charging :: any, shown.charging :: any)
	then
		return
	end
	state = shown
	HudController.setEnergy(shown.energy, shown.charging)
	EnergyController.onChanged:Fire(EnergyController.getState())
end

-- Works out the HUD's energy view from the driven car's attributes (none: nothing shows).
local function refresh()
	local model = car
	if model == nil then
		stationKind = nil
		publish({ energy = nil, charging = nil })
		return
	end
	local attributes = readAttributes(model)
	if attributes.charging then
		-- Which station this is decides the cost per %; look it up once per charging stop.
		if stationKind == nil and attributes.vehicleId then
			stationKind = EnergyController.stationKindAt(model:GetPivot().Position, attributes.vehicleId)
		end
	else
		stationKind = nil
	end
	publish(EnergyController.viewFor(attributes, ProfileController.settings().units, stationKind))
end

local function unwatch()
	if carConnection then
		carConnection:Disconnect()
		carConnection = nil
	end
	car = nil
	stationKind = nil
end

-- The attributes that change what the HUD shows.
local WATCHED: { [string]: boolean } = {}
for _, name: string in
	{
		ATTRIBUTES.energy,
		ATTRIBUTES.kind,
		ATTRIBUTES.limp,
		ATTRIBUTES.charging,
		ATTRIBUTES.chargeRate,
		ATTRIBUTES.vehicleId,
		ATTRIBUTES.trim,
	}
do
	WATCHED[name] = true
end

local function onDrivingChanged(driving: boolean, model: Model?)
	unwatch()
	if driving and model then
		car = model
		-- One connection for all the energy attributes; others (lamps, owner) are ignored.
		carConnection = model.AttributeChanged:Connect(function(name: string)
			if WATCHED[name] then
				refresh()
			end
		end)
	end
	refresh()
end

-- On empty: route the GPS to the station the server picked and say so.
local function onEnergyAlert(payload: any)
	local stationId = if type(payload) == "table" and type(payload.stationId) == "string"
		then payload.stationId
		else nil
	local location = if stationId then locationsById[stationId] else nil
	-- The alert can arrive before the HUD knows the car (a car brought out empty): the station the server picked
	-- says which kind it is, then the car's own attributes.
	local current = state.energy
	local driven = car or DriveController.getCar()
	local kind: EnergyKind = if location and location.tag == "FuelPump"
		then "fuel"
		elseif location then "battery"
		elseif current then current.kind
		elseif driven then kindOf(readAttributes(driven)) or "battery"
		else "battery"
	if stationId and location then
		GpsController.setDestination(stationId)
		NotifyController.show(string.format(TEXT.routed[kind], location.displayName), "warning")
	else
		NotifyController.show(TEXT.noStation[kind], "warning")
	end
end

-- Public API --------------------------------------------------------------------------------------------------------

-- What the HUD shows for the driven car (copies; both nil while not driving).
function EnergyController.getState(): State
	return {
		energy = if state.energy then table.clone(state.energy) else nil,
		charging = if state.charging then table.clone(state.charging) else nil,
	}
end

function EnergyController:Start()
	Net.onClientEvent("EnergyAlert", onEnergyAlert)
	-- Range follows the player's units.
	ProfileController.onChanged:Connect(function()
		if car ~= nil then
			refresh()
		end
	end)
	DriveController.onDrivingChanged:Connect(onDrivingChanged)
	local current = DriveController.getCar()
	if current then
		onDrivingChanged(true, current)
	end
end

return EnergyController
