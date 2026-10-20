--!strict
-- The energy model (docs/phase-5-contracts.md "Model"): a full charge or tank lasts the catalog's minutes at
-- cruise for every drivable trim, speeding up and climbing cost more, only batteries regen, the county's
-- stalls, pumps and truck chargers fill within the PLAN.md times, stations only take compatible cars, range
-- falls with the level, and charging stays a small sink. Pure logic: runs in Edit mode.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Catalog = require(ReplicatedStorage.Shared.Vehicle.Catalog)
local Economy = require(ReplicatedStorage.Shared.Config.Economy)
local Energy = require(ReplicatedStorage.Shared.Vehicle.Energy)
local EnergyConfig = require(ReplicatedStorage.Shared.Config.Energy)
local Harness = require(ReplicatedStorage.Shared.Testing.Harness)
local MapLayout = require(ReplicatedStorage.Shared.Config.MapLayout)
local Units = require(ReplicatedStorage.Shared.Util.Units)
local Vehicles = require(ReplicatedStorage.Shared.Config.Vehicles)

type StationKind = Energy.StationKind

local CRUISE_TOLERANCE = 0.01 -- cruise drain within 1 % of 1 / (energyMinutes × 60)
local DT = 0.05 -- seconds per step when timing a charge
local MAX_CHARGE_SECONDS = 600 -- a charge that takes longer than this never finishes
local PERCENT = 100
local KINDS: { StationKind } = { "ChargerStall", "TruckCharger", "FuelPump" }

-- PLAN.md Phase 5 times.
local STALL_MIN_SECONDS, STALL_MAX_SECONDS = 60, 90 -- 10→80 % at a stall
local PUMP_MIN_SECONDS, PUMP_MAX_SECONDS = 20, 30 -- 10→100 % at a pump
-- The fastest county stall (350 kW): about a minute, kept a few seconds inside the band so the server's
-- quarter-second sampling steps never push a real charge outside it.
local FASTEST_STALL_SECONDS = 65
-- Charge times summed in float steps land a hair either side of a bound.
local TIME_TOLERANCE = 0.01 -- seconds

local function within(seconds: number, min: number, max: number): boolean
	return seconds >= min - TIME_TOLERANCE and seconds <= max + TIME_TOLERANCE
end

type TrimRef = { name: string, vehicleId: string, trim: Vehicles.Trim, energy: "battery" | "fuel", class: string }

local function drivableTrims(): { TrimRef }
	local list: { TrimRef } = {}
	for _, vehicleId in Catalog.vehicleIds() do
		local vehicle = Catalog.getVehicle(vehicleId)
		if vehicle and vehicle.playerDrivable then
			for _, trim in vehicle.trims do
				table.insert(list, {
					name = `{vehicleId}/{trim.id}`,
					vehicleId = vehicleId,
					trim = trim,
					energy = vehicle.energy,
					class = vehicle.class,
				})
			end
		end
	end
	return list
end

-- The first drivable trim matching `predicate`.
local function findTrim(predicate: (ref: TrimRef) -> boolean): TrimRef
	for _, ref in drivableTrims() do
		if predicate(ref) then
			return ref
		end
	end
	error("no drivable trim matches")
end

-- The attribute tables of every station of `kind` in the county layout.
local function stations(kind: StationKind): { { [string]: any } }
	local list: { { [string]: any } } = {}
	for _, location in MapLayout.locations do
		if location.tag == kind then
			table.insert(list, location.attributes or {})
		end
	end
	return list
end

-- Seconds a station takes to fill a car from `from` to `to`, stepping like EnergyService does (math.huge if
-- it never gets there).
local function chargeSeconds(
	kind: StationKind,
	attributes: { [string]: any },
	ref: TrimRef,
	from: number,
	to: number
): number
	local level, time = from, 0
	while time < MAX_CHARGE_SECONDS do
		local rate = Energy.chargeRatePerSecond(kind, attributes, ref.vehicleId, ref.trim, level)
		if rate <= 0 then
			return math.huge
		end
		local nextLevel = level + rate * DT
		if nextLevel >= to then
			-- Interpolate inside the step for a time that does not depend on DT.
			return time + DT * (to - level) / (nextLevel - level)
		end
		level = nextLevel
		time += DT
	end
	return math.huge
end

local function round(value: number): number
	return math.floor(value * 10 + 0.5) / 10
end

return function(t: Harness.Api)
	local cruise = Units.mphToStuds(EnergyConfig.cruiseMph)

	t.describe("Energy", function()
		t.it("drains exactly a full charge over energyMinutes at cruise for every drivable trim", function()
			local problems: { string } = {}
			for _, ref in drivableTrims() do
				local minutes = ref.trim.energyMinutes
				if minutes == nil then
					table.insert(problems, `{ref.name}: no energyMinutes`)
					continue
				end
				local expected = 1 / (minutes * 60)
				-- By catalog trim and by trim id alike.
				for _, trim in { ref.trim, ref.trim.id } :: { any } do
					local drain = Energy.drainPerSecond(ref.vehicleId, trim, cruise, 0, 0)
					if math.abs(drain - expected) > expected * CRUISE_TOLERANCE then
						table.insert(problems, `{ref.name}: lasts {round(1 / drain / 60)} min, catalog {minutes}`)
					end
				end
			end
			t.expect(problems).toEqual({})
		end)

		t.it("costs more to speed up, climb or drive faster, and a little standing still", function()
			local problems: { string } = {}
			for _, ref in drivableTrims() do
				local function drain(speed: number, accel: number, climb: number): number
					return Energy.drainPerSecond(ref.vehicleId, ref.trim, speed, accel, climb)
				end
				local flat = drain(cruise, 0, 0)
				if drain(cruise, 10, 0) <= flat then
					table.insert(problems, `{ref.name}: speeding up costs no more`)
				end
				if drain(cruise, 0, 5) <= flat then
					table.insert(problems, `{ref.name}: climbing costs no more`)
				end
				if drain(cruise * 1.5, 0, 0) <= flat or drain(cruise * 0.5, 0, 0) >= flat then
					table.insert(problems, `{ref.name}: drain does not rise with speed`)
				end
				local idle = drain(0, 0, 0)
				if idle <= 0 or idle >= flat * 0.1 then
					table.insert(problems, `{ref.name}: idle drain {idle} is not tiny`)
				end
				-- Reversing drains like driving forward.
				if math.abs(drain(-cruise * 0.3, 0, 0) - drain(cruise * 0.3, 0, 0)) > 1e-12 then
					table.insert(problems, `{ref.name}: reverse drains differently`)
				end
			end
			t.expect(problems).toEqual({})
		end)

		t.it("gives energy back when braking or descending only on battery cars, never below zero", function()
			local problems: { string } = {}
			for _, ref in drivableTrims() do
				local function drain(speed: number, accel: number, climb: number): number
					return Energy.drainPerSecond(ref.vehicleId, ref.trim, speed, accel, climb)
				end
				local idle = drain(0, 0, 0)
				local braking = drain(cruise, -10, 0)
				local descending = drain(cruise, 0, -5)
				if ref.energy == "battery" then
					if braking >= idle or descending >= idle then
						table.insert(problems, `{ref.name}: battery car does not regen`)
					end
				elseif math.abs(braking - idle) > 1e-12 or math.abs(descending - idle) > 1e-12 then
					table.insert(problems, `{ref.name}: fuel car drains {braking} braking, not its idle {idle}`)
				end
				if drain(cruise, -60, -40) < 0 then
					table.insert(problems, `{ref.name}: hard braking downhill drains a negative amount`)
				end
			end
			t.expect(problems).toEqual({})
		end)

		t.it("doesn't bill coasting twice or count jitter as speeding up", function()
			local deadband = EnergyConfig.drain.accelDeadband
			local problems: { string } = {}
			for _, ref in drivableTrims() do
				local function drain(speed: number, accel: number, climb: number): number
					return Energy.drainPerSecond(ref.vehicleId, ref.trim, speed, accel, climb)
				end
				local flat = drain(cruise, 0, 0)
				-- Easing off and back on by the same amount costs what holding the speed does.
				local accel = deadband + 0.5
				local pulsed = (drain(cruise, -accel, 0) + drain(cruise, accel, 0)) / 2
				if math.abs(pulsed - flat) > flat * 1e-9 then
					table.insert(problems, `{ref.name}: easing off and on costs {pulsed / flat}x holding speed`)
				end
				if drain(cruise, deadband * 0.9, 0) ~= flat or drain(cruise, -deadband * 0.9, 0) ~= flat then
					table.insert(problems, `{ref.name}: a wobble inside the deadband changes the drain`)
				end
			end
			t.expect(problems).toEqual({})
		end)

		t.it("fills 10→80 % at every county stall in 60-90 s, slower above 80 %", function()
			local battery = findTrim(function(ref)
				return ref.energy == "battery" and ref.class ~= "heavy"
			end)
			local stalls = stations("ChargerStall")
			t.expect(#stalls).toBeGreaterThan(0)
			local problems: { string } = {}
			for _, attributes in stalls do
				local seconds = chargeSeconds("ChargerStall", attributes, battery, 0.1, 0.8)
				if not within(seconds, STALL_MIN_SECONDS, STALL_MAX_SECONDS) then
					table.insert(problems, `{attributes.kW} kW stall: 10→80 % in {round(seconds)} s`)
				end
				local below =
					Energy.chargeRatePerSecond("ChargerStall", attributes, battery.vehicleId, battery.trim, 0.5)
				local above =
					Energy.chargeRatePerSecond("ChargerStall", attributes, battery.vehicleId, battery.trim, 0.95)
				if not (above < below and above > 0) then
					table.insert(problems, `{attributes.kW} kW stall: no gentle taper above 80 %`)
				end
				if chargeSeconds("ChargerStall", attributes, battery, 0.8, 1) == math.huge then
					table.insert(problems, `{attributes.kW} kW stall: never reaches 100 %`)
				end
			end
			t.expect(problems).toEqual({})

			-- The fastest stall is about a minute, with room inside the band for the server's sampling steps; a
			-- stall with no kW attribute still charges within the band.
			local fastest = 0
			for _, attributes in stalls do
				fastest = math.max(fastest, attributes.kW or 0)
			end
			local fastestSeconds = chargeSeconds("ChargerStall", { kW = fastest }, battery, 0.1, 0.8)
			t.expect(fastestSeconds).toBeNear(FASTEST_STALL_SECONDS, 1)
			local fallback = chargeSeconds("ChargerStall", {}, battery, 0.1, 0.8)
			t.expect(within(fallback, STALL_MIN_SECONDS, STALL_MAX_SECONDS)).toBe(true)
		end)

		t.it("fills 10→100 % at every county pump in 20-30 s", function()
			local fuel = findTrim(function(ref)
				return ref.energy == "fuel"
			end)
			local pumps = stations("FuelPump")
			t.expect(#pumps).toBeGreaterThan(0)
			local problems: { string } = {}
			for _, attributes in pumps do
				local seconds = chargeSeconds("FuelPump", attributes, fuel, 0.1, 1)
				if not within(seconds, PUMP_MIN_SECONDS, PUMP_MAX_SECONDS) then
					table.insert(problems, `rate {attributes.rate} pump: 10→100 % in {round(seconds)} s`)
				end
			end
			t.expect(problems).toEqual({})
		end)

		t.it("charges faster at a truck charger than any stall, and only heavy battery vehicles", function()
			local heavy = findTrim(function(ref)
				return ref.energy == "battery" and ref.class == "heavy"
			end)
			local truckers = stations("TruckCharger")
			t.expect(#truckers).toBeGreaterThan(0)
			local slowestTruck = 0
			for _, attributes in truckers do
				slowestTruck = math.max(slowestTruck, chargeSeconds("TruckCharger", attributes, heavy, 0.1, 0.8))
			end
			local fastestStall = math.huge
			for _, attributes in stations("ChargerStall") do
				fastestStall = math.min(fastestStall, chargeSeconds("ChargerStall", attributes, heavy, 0.1, 0.8))
			end
			t.expect(slowestTruck).toBeLessThan(fastestStall)

			local problems: { string } = {}
			for _, ref in drivableTrims() do
				local battery = ref.energy == "battery"
				local function expected(kind: StationKind): boolean
					if kind == "FuelPump" then
						return not battery
					elseif kind == "TruckCharger" then
						return battery and ref.class == "heavy"
					end
					return battery
				end
				for _, kind: StationKind in KINDS do
					local allowed = expected(kind)
					if Energy.isCompatible(ref.vehicleId, kind) ~= allowed then
						table.insert(problems, `{ref.name} at {kind}: compatible should be {allowed}`)
					end
					local rate = Energy.chargeRatePerSecond(kind, {}, ref.vehicleId, ref.trim, 0.5)
					if (rate > 0) ~= allowed then
						table.insert(problems, `{ref.name} at {kind}: rate {rate}`)
					end
				end
				-- Nothing is added to a full car.
				for _, kind: StationKind in KINDS do
					if expected(kind) and Energy.chargeRatePerSecond(kind, {}, ref.vehicleId, ref.trim, 1) ~= 0 then
						table.insert(problems, `{ref.name} at {kind}: charges past full`)
					end
				end
			end
			t.expect(problems).toEqual({})
		end)

		t.it("has a range that falls with the level and matches the catalog minutes at cruise", function()
			local problems: { string } = {}
			for _, ref in drivableTrims() do
				local minutes = ref.trim.energyMinutes or 0
				local full = Energy.rangeMiles(ref.vehicleId, ref.trim, 1)
				local expected = minutes / 60 * EnergyConfig.cruiseMph
				if math.abs(full - expected) > expected * CRUISE_TOLERANCE then
					table.insert(problems, `{ref.name}: full range {round(full)} mi, expected {round(expected)}`)
				end
				if Energy.rangeMiles(ref.vehicleId, ref.trim, 0) ~= 0 then
					table.insert(problems, `{ref.name}: range at 0 is not 0`)
				end
				local previous = -1
				for step = 0, 20 do
					local range = Energy.rangeMiles(ref.vehicleId, ref.trim, step / 20)
					if range <= previous then
						table.insert(problems, `{ref.name}: range does not rise with the level at {step * 5} %`)
						break
					end
					previous = range
				end
			end
			t.expect(problems).toEqual({})
		end)

		t.it("costs whole dollars per % and a full charge less than a minute of any job", function()
			local problems: { string } = {}
			for _, kind: StationKind in KINDS do
				local full = Energy.costPerFraction(kind)
				local perPercent = full / PERCENT
				if perPercent <= 0 or perPercent % 1 ~= 0 then
					table.insert(problems, `{kind}: {perPercent} per %`)
				end
				if full >= Economy.activities.rideshare then
					table.insert(problems, `{kind}: a full charge costs {full}, a minute of rideshare pays less`)
				end
			end
			t.expect(problems).toEqual({})
		end)
	end)
end
