--!strict
-- The energy model (PLAN.md Phase 5; docs/phase-5-contracts.md "Model"): how fast a car's battery or tank
-- drains from its motion, how much range is left, how fast a station fills it and what that costs, and which
-- cars may use which stations. Pure: no state and no Roblox services, so the server (EnergyService), the HUD
-- (range readout) and tests/Energy.spec all use the same numbers. Every tunable lives in Config/Energy, which
-- explains the calibration.
--
-- Levels are fractions 0..1 of a full charge or tank. Motion uses Vehicle/Tuning's units: speed in studs/s,
-- accel in studs/s² (the rate of change of speed: positive speeding up, negative slowing down), climb in
-- studs/s (vertical speed, positive up).
--
-- `trim` may be the catalog trim (Config/Vehicles) or its id; vehicles players never drive (no energyMinutes)
-- never drain and have no range.

local Shared = script.Parent.Parent
local Catalog = require(script.Parent.Catalog)
local EnergyConfig = require(Shared.Config.Energy)
local Units = require(Shared.Util.Units)
local Vehicles = require(Shared.Config.Vehicles)

local SECONDS_PER_MINUTE = 60
local SECONDS_PER_HOUR = 3600
local PERCENT = 100
local LAUNCH_REFERENCE_MPH = 60 -- launchCruiseSeconds is the cost of one 0→60 mph launch
-- Charging measures its curve from 10 % to 80 % (PLAN.md Phase 5).
local CURVE_FROM = 0.1
local CURVE_TO = 0.8

export type StationKind = EnergyConfig.StationKind
export type TrimRef = Vehicles.Trim | string

local Energy = {}

-- Speeds the model compares against, in studs/s (worked out once; Config/World's scale never changes at
-- run time).
local cruiseSpeed = Units.mphToStuds(EnergyConfig.cruiseMph)
-- k in the launch load (k × speed × accel): a launch from 0 to v adds k × v² / 2 cruise-seconds, so a 0→60
-- launch costs exactly launchCruiseSeconds.
local launchReferenceSpeed = Units.mphToStuds(LAUNCH_REFERENCE_MPH)
local launchFactor = 2 * EnergyConfig.drain.launchCruiseSeconds / (launchReferenceSpeed * launchReferenceSpeed)

local truckChargerClasses: { [string]: boolean } = {}
for _, classId in EnergyConfig.truckChargerClasses do
	truckChargerClasses[classId] = true
end

local function resolveTrim(vehicleId: string, trim: TrimRef): Vehicles.Trim?
	if type(trim) == "string" then
		return Catalog.getTrim(vehicleId, trim)
	end
	return trim
end

-- Seconds a full charge or tank lasts at cruise on the flat (the catalog's energyMinutes), or nil for a
-- vehicle players never drive.
local function fullSeconds(vehicleId: string, trim: TrimRef): number?
	local resolved = resolveTrim(vehicleId, trim)
	if resolved == nil or resolved.energyMinutes == nil or resolved.energyMinutes <= 0 then
		return nil
	end
	return resolved.energyMinutes * SECONDS_PER_MINUTE
end

-- Load from speed alone, relative to cruising (1 at cruise speed, idle share included).
local function speedLoad(speed: number): number
	local drain = EnergyConfig.drain
	local x = speed / cruiseSpeed
	local moving = drain.linearShare * x + (1 - drain.linearShare) * x * x
	return drain.idleShare + (1 - drain.idleShare) * math.min(moving, drain.maxSpeedLoad)
end

-- Fraction of a full charge or tank used per second. At Config/Energy.cruiseMph on the flat this is exactly
-- 1 / (energyMinutes × 60). Speeding up and climbing add (an acceleration inside Config drain.accelDeadband
-- counts as holding speed). Slowing down and descending first pay for the speed load (coasting isn't billed
-- twice), down to the idle drain; past that, braking gives some back on a battery car (regen) and nothing on a
-- fuel car. Never negative.
function Energy.drainPerSecond(vehicleId: string, trim: TrimRef, speed: number, accel: number, climb: number): number
	local seconds = fullSeconds(vehicleId, trim)
	local vehicle = Catalog.getVehicle(vehicleId)
	if seconds == nil or vehicle == nil then
		return 0
	end
	local drain = EnergyConfig.drain
	local speedAbs = math.abs(speed)
	local steadyAccel = if math.abs(accel) < drain.accelDeadband then 0 else accel
	local steadyClimb = if math.abs(climb) < drain.climbDeadband then 0 else climb

	local launch = launchFactor * speedAbs * steadyAccel
	local ascent = drain.climbCruiseSecondsPerStud * steadyClimb
	local load = speedLoad(speedAbs) + launch + ascent
	if load < drain.idleShare then
		-- Losing speed or height faster than the speed load would: the engine or motor only idles. A battery
		-- car gets regenEfficiency of the rest back (regen); a fuel car gets nothing back.
		local braking = drain.idleShare - load
		load = if vehicle.energy == "battery"
			then drain.idleShare - braking * drain.regenEfficiency
			else drain.idleShare
	end
	return math.clamp(load, 0, drain.maxLoad) / seconds
end

-- Miles a car can still drive at cruise on the flat with `level` (0..1) left.
function Energy.rangeMiles(vehicleId: string, trim: TrimRef, level: number): number
	local perSecond = Energy.drainPerSecond(vehicleId, trim, cruiseSpeed, 0, 0)
	if perSecond <= 0 then
		return 0
	end
	local seconds = math.clamp(level, 0, 1) / perSecond
	return seconds / SECONDS_PER_HOUR * EnergyConfig.cruiseMph
end

-- Whether a vehicle may use a station kind: battery cars at chargers (the truck charger only for its
-- classes), fuel cars at pumps.
function Energy.isCompatible(vehicleId: string, kind: StationKind): boolean
	local vehicle = Catalog.getVehicle(vehicleId)
	if vehicle == nil or EnergyConfig.stationEnergy[kind] ~= vehicle.energy then
		return false
	end
	if kind == "TruckCharger" then
		return truckChargerClasses[vehicle.class] == true
	end
	return true
end

-- Seconds from 10 % to 80 % for a charger of `kW` (Config/Energy.charging.curve, linear between points).
local function tenToEightySeconds(kW: number): number
	local curve = EnergyConfig.charging.curve
	local first, last = curve[1], curve[#curve]
	if kW <= first.kW then
		return first.tenToEightySeconds
	end
	if kW >= last.kW then
		return last.tenToEightySeconds
	end
	for index = 2, #curve do
		local low, high = curve[index - 1], curve[index]
		if kW <= high.kW then
			local t = (kW - low.kW) / (high.kW - low.kW)
			return low.tenToEightySeconds + (high.tenToEightySeconds - low.tenToEightySeconds) * t
		end
	end
	return last.tenToEightySeconds
end

local function positiveNumber(value: any): number?
	if type(value) == "number" and value > 0 and value == value and value < math.huge then
		return value
	end
	return nil
end

-- Fraction of a full charge or tank a station adds per second at `level` (0..1). Chargers read the station's
-- `kW` attribute, pumps its `rate` attribute (percent per second); a missing or invalid attribute uses the
-- Config default. Batteries taper gently above Config/Energy.charging.taperStart. 0 for an incompatible car
-- or a full one.
function Energy.chargeRatePerSecond(
	kind: StationKind,
	attributes: { [string]: any }?,
	vehicleId: string,
	trim: TrimRef,
	level: number
): number
	if not Energy.isCompatible(vehicleId, kind) or fullSeconds(vehicleId, trim) == nil or level >= 1 then
		return 0
	end
	local given: { [string]: any } = attributes or {}

	if kind == "FuelPump" then
		local fueling = EnergyConfig.fueling
		local percentPerSecond = positiveNumber(given.rate) or fueling.defaultRate
		return percentPerSecond * fueling.rateScale / PERCENT
	end

	local charging = EnergyConfig.charging
	local kW = positiveNumber(given.kW) or charging.defaultKW[kind]
	local rate = (CURVE_TO - CURVE_FROM) / tenToEightySeconds(kW)
	if level > charging.taperStart then
		local past = math.min((level - charging.taperStart) / (1 - charging.taperStart), 1)
		rate *= 1 - (1 - charging.taperFloor) * past
	end
	return rate
end

-- $ for a full 0→1 charge or tank at a station kind (EnergyService bills the energy it adds at this price).
function Energy.costPerFraction(kind: StationKind): number
	return EnergyConfig.costPerFull[kind] or 0
end

return Energy
