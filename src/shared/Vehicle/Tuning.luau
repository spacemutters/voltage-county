--!strict
-- Per-trim physics numbers, derived from the catalog (Config/Vehicles via Vehicle/Catalog) and Config/Driving.
-- Every number is mass-independent: accelerations in studs/s², speeds in studs/s, rates in 1/s, so a car
-- drives the same with or without passengers.
--
-- The headline is calibration: the peak drive acceleration is found by bisection on
-- Powertrain.simulateTimeToSpeed so that a flat, straight, full-throttle run in Standard mode hits 0-60 mph in
-- exactly the trim's zeroToSixtySec, using the same force curve, drag and rolling resistance the chassis
-- applies. Aero drag is set so the force curve alone would top out Config/Driving.powertrain.topSpeedHeadroom
-- above the catalog top speed; the powertrain's limiter then holds the catalog number exactly.
--
-- Results are cached per trim (and per gravity, which grip and rolling resistance depend on) and frozen.

local Workspace = game:GetService("Workspace")

local Shared = script.Parent.Parent
local Catalog = require(script.Parent.Catalog)
local Driving = require(Shared.Config.Driving)
local Powertrain = require(script.Parent.Powertrain)
local Units = require(Shared.Util.Units)

local SIXTY_MPH = 60

export type DriveLayout = "FWD" | "RWD" | "AWD"
-- "FL" | "FR" | "RL" | "RR" (kept a plain string so it can index tables from loops without casts)
export type WheelId = string

export type Tuning = {
	vehicleId: string,
	trimId: string,
	energy: "battery" | "fuel",
	drive: DriveLayout,

	-- Speeds, studs/s
	topSpeed: number,
	baseSpeed: number, -- full force below this, constant power above
	reverseTopSpeed: number,
	gearSpeeds: { number }, -- top of each gear (fuel); one entry for electric cars

	-- Accelerations, studs/s² (per unit mass)
	peakAccel: number, -- calibrated: full-pedal drive below baseSpeed in Standard
	reverseAccel: number,
	brakeDecel: number,
	rollingResistance: number,
	dragCoefficient: number, -- drag deceleration = dragCoefficient * speed², 1/stud
	tractionLimit: number, -- what the driven wheels can put down on flat ground at static load

	-- Tires and steering
	grip: number, -- friction coefficient relative to gravity
	rearGripScale: number,
	lateralGripRate: number, -- 1/s
	steerLock: number, -- radians, at walking pace
	minSteerLock: number, -- radians, the floor at any speed

	-- Suspension (Standard mode; drive modes scale these)
	suspensionFrequency: number, -- Hz
	dampingRatio: number,
	antiRollRatio: number,

	-- Geometry, studs
	wheelRadius: number,
	wheelbase: number,
	track: number,
	rideHeight: number,
	cgHeight: number, -- ground to the chassis center at rest
	hubs: { [WheelId]: Vector3 }, -- hub centers at ride height, chassis space (the WheelXX attachments)

	-- What it was calibrated to
	zeroToSixtySec: number,
	topSpeedMph: number,
	gravity: number,
}

local Tuning = {}

local cache: { [string]: Tuning } = {}
local cachedGravity: number? = nil

local function lerp(a: number, b: number, t: number): number
	return a + (b - a) * t
end

-- Sets a candidate peak acceleration and the drag that goes with it. Drag is chosen so the force curve would
-- just balance drag + rolling at topSpeed * headroom (vMax):
--   peak * baseSpeed / vMax = drag * vMax² + rolling   =>   drag = (peak * baseSpeed / vMax - rolling) / vMax²
-- A higher peak gives a higher drag, but the net acceleration at every speed below vMax still rises with peak,
-- so the 0-60 time falls monotonically and bisection works.
local function setPeak(tuning: Tuning, peak: number)
	local vMax = tuning.topSpeed * Driving.powertrain.topSpeedHeadroom
	tuning.peakAccel = peak
	local driveAtMax = Powertrain.tractiveAccel(tuning, vMax)
	tuning.dragCoefficient =
		math.max(Driving.resistance.minDragCoefficient, (driveAtMax - tuning.rollingResistance) / (vMax * vMax))
end

-- Bisects the peak acceleration until Standard mode reaches the target speed in the target time.
local function calibrate(tuning: Tuning)
	local settings = Driving.calibration
	local sixty = Units.mphToStuds(SIXTY_MPH)
	-- Cars that cannot reach 60 (the fleet Pod) keep the same average acceleration up to most of their top.
	local targetSpeed = math.min(sixty, tuning.topSpeed * settings.maxTargetFractionOfTop)
	local targetTime = tuning.zeroToSixtySec * targetSpeed / sixty
	local cutoff = targetTime * settings.searchTimeFactor

	local function timeWith(peak: number): number
		setPeak(tuning, peak)
		return Powertrain.simulateTimeToSpeed(tuning, "standard", targetSpeed, cutoff)
	end

	-- The peak can never be below the average acceleration the stat implies.
	local low = targetSpeed / targetTime
	local high = low * 2
	local expansions = 0
	while timeWith(high) > targetTime and expansions < settings.maxExpansions do
		low = high
		high *= 2
		expansions += 1
	end
	for _ = 1, settings.iterations do
		if high - low <= high * settings.tolerance then
			break
		end
		local middle = (low + high) / 2
		if timeWith(middle) > targetTime then
			low = middle
		else
			high = middle
		end
	end
	setPeak(tuning, (low + high) / 2)
end

local function build(vehicleId: string, trimId: string, gravity: number): Tuning?
	local vehicle = Catalog.getVehicle(vehicleId)
	local trim = Catalog.getTrim(vehicleId, trimId)
	local geometry = Catalog.geometry(vehicleId, trimId)
	if vehicle == nil or trim == nil or geometry == nil then
		return nil
	end

	local handling = math.clamp(trim.handling, 0, 1)
	local tires = Driving.tires
	local powertrain = Driving.powertrain

	-- Grip from handling, capped so the car can never tip itself over on flat ground. Tire forces act
	-- lateralForceRaise of the way up to the center of mass, so the tipping moment arm is the rest:
	--   tips when grip * gravity * arm > gravity * track / 2   =>   grip < (track / 2) / arm
	local cgHeight = geometry.rideHeight + geometry.chassisHeight / 2
	local tippingArm = cgHeight * (1 - tires.lateralForceRaise)
	local grip = math.min(
		lerp(tires.gripAtHandling0, tires.gripAtHandling1, handling),
		tires.rolloverSafety * (geometry.track / 2) / tippingArm
	)

	-- What the driven wheels can put down at static load (each axle carries half the weight at rest).
	local drivenGrip = if trim.drive == "AWD"
		then grip
		elseif trim.drive == "RWD" then grip * tires.rearGripScale / 2
		else grip / 2
	local tractionLimit = drivenGrip * gravity

	local topSpeed = Units.mphToStuds(trim.topSpeedMph)
	local unrestrictedTop = topSpeed * powertrain.topSpeedHeadroom
	local gearSpeeds: { number } = {}
	if vehicle.energy == "fuel" then
		for _, fraction in powertrain.fuel.gearSpeedFractions do
			table.insert(gearSpeeds, unrestrictedTop * fraction)
		end
	else
		table.insert(gearSpeeds, unrestrictedTop)
	end

	-- Hubs at ride height, chassis space (front is -Z, right is +X), matching the model contract.
	local hubY = geometry.wheelRadius - (geometry.rideHeight + geometry.chassisHeight / 2)
	local halfTrack = geometry.track / 2
	local halfBase = geometry.wheelbase / 2

	local tuning: Tuning = {
		vehicleId = vehicleId,
		trimId = trimId,
		energy = vehicle.energy,
		drive = trim.drive,

		topSpeed = topSpeed,
		baseSpeed = topSpeed * powertrain.baseSpeedFraction,
		reverseTopSpeed = math.min(Units.mphToStuds(powertrain.reverseTopSpeedMph), topSpeed),
		gearSpeeds = gearSpeeds,

		peakAccel = 0, -- set by calibrate
		reverseAccel = 0, -- set after calibrate
		brakeDecel = math.min(
			lerp(Driving.brakes.decelAtHandling0, Driving.brakes.decelAtHandling1, handling),
			grip * gravity * Driving.brakes.maxGripUse
		),
		rollingResistance = Driving.resistance.rollingCoefficient * gravity,
		dragCoefficient = Driving.resistance.minDragCoefficient, -- set by calibrate
		tractionLimit = tractionLimit,

		grip = grip,
		rearGripScale = tires.rearGripScale,
		lateralGripRate = lerp(tires.lateralRateAtHandling0, tires.lateralRateAtHandling1, handling),
		steerLock = math.rad(lerp(Driving.steering.lockAtHandling0Deg, Driving.steering.lockAtHandling1Deg, handling)),
		minSteerLock = math.rad(Driving.steering.minLockDeg),

		suspensionFrequency = lerp(
			Driving.suspension.frequencyAtHandling0,
			Driving.suspension.frequencyAtHandling1,
			handling
		),
		dampingRatio = Driving.suspension.dampingRatio,
		antiRollRatio = Driving.suspension.antiRollRatio,

		wheelRadius = geometry.wheelRadius,
		wheelbase = geometry.wheelbase,
		track = geometry.track,
		rideHeight = geometry.rideHeight,
		cgHeight = cgHeight,
		hubs = {
			FL = Vector3.new(-halfTrack, hubY, -halfBase),
			FR = Vector3.new(halfTrack, hubY, -halfBase),
			RL = Vector3.new(-halfTrack, hubY, halfBase),
			RR = Vector3.new(halfTrack, hubY, halfBase),
		},

		zeroToSixtySec = trim.zeroToSixtySec,
		topSpeedMph = trim.topSpeedMph,
		gravity = gravity,
	}

	calibrate(tuning)
	tuning.reverseAccel = tuning.peakAccel * powertrain.reverseForceFraction
	return tuning
end

-- The physics numbers for a trim, or nil if the vehicle or trim does not exist. The result is shared and
-- frozen; treat it as read-only.
function Tuning.forTrim(vehicleId: string, trimId: string): Tuning?
	local gravity = Workspace.Gravity
	if cachedGravity ~= gravity then
		table.clear(cache)
		cachedGravity = gravity
	end
	local key = `{vehicleId}/{trimId}`
	local cached = cache[key]
	if cached then
		return cached
	end
	local tuning = build(vehicleId, trimId, gravity)
	if tuning then
		table.freeze(tuning.gearSpeeds)
		table.freeze(tuning.hubs)
		table.freeze(tuning)
		cache[key] = tuning
	end
	return tuning
end

return Tuning
