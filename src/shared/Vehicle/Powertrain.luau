--!strict
-- Turns the driver's pedals into a drive acceleration and a brake deceleration for the chassis, per unit mass
-- (studs/s²), so the same numbers work for any car mass. Electric cars have one speed, instant torque and
-- adjustable lift-off regen; fuel cars have a simple automatic with short shift dips. Drive modes shape the
-- pedal (Config/Driving.modes). Holding the brake at a standstill engages reverse after a short delay.
--
-- The force curve, drag and rolling resistance live here (tractiveAccel, resistance) and are used both by
-- Vehicle/Chassis on the road and by the pure 1-D simulations below, which Vehicle/Tuning uses to calibrate
-- every trim to its catalog 0-60 and the specs use to check it. Traction control lives in the chassis (it
-- needs the tires); the simulation applies the same limit from static weight (tractionCap).
--
-- This module reads the trim's numbers through `Spec`, the part of Vehicle/Tuning's `Tuning` it needs, so
-- Tuning can require this module for calibration without a require cycle.
--
-- Speed cap (Phase 5 limp mode): setSpeedCap(studsPerSecond) holds the car under a lower top speed than the
-- trim's, forward and in reverse, through the same limiter and overspeed brake as the real top speed; nil lifts
-- it. Vehicle/Chassis sets it from the car's `Limp` attribute. The pure simulations below never use a cap, so
-- Tuning's 0-60 calibration is unchanged.

local Shared = script.Parent.Parent
local Driving = require(Shared.Config.Driving)
local Types = require(Shared.Types)
local Units = require(Shared.Util.Units)

local SIXTY_MPH = 60

-- The trim numbers the powertrain reads (a subset of Vehicle/Tuning's Tuning). Speeds in studs/s,
-- accelerations in studs/s².
export type Spec = {
	energy: "battery" | "fuel",
	topSpeed: number,
	baseSpeed: number, -- full force below this speed, constant power above
	reverseTopSpeed: number,
	gearSpeeds: { number }, -- top speed of each gear (one entry for electric cars)
	peakAccel: number, -- full-pedal drive acceleration below baseSpeed in Standard
	reverseAccel: number,
	brakeDecel: number, -- full-pedal brake deceleration
	rollingResistance: number,
	dragCoefficient: number, -- drag deceleration = dragCoefficient * speed², 1/stud
	tractionLimit: number, -- most the driven wheels can put down on flat ground at static load
}

export type PowertrainOutput = {
	driveAccel: number, -- signed along the car's forward axis, studs/s² per unit mass
	brakeAccel: number, -- >= 0, opposes the wheels' motion
	gear: string, -- "D" or "1".."5" forward, "R" in reverse
	reversing: boolean,
	shaping: number, -- the pedal driving the car (throttle, or the brake pedal in reverse) after mode shaping
}

type State = {
	spec: Spec,
	pedal: number, -- shaped, rate-limited drive pedal 0..1
	reversing: boolean,
	reverseTimer: number, -- how long the brake has been held at a standstill
	gear: number, -- fuel cars: current gear index
	shiftTimer: number, -- fuel cars: time left in the current shift dip
	speedCap: number?, -- studs/s; a lower top speed than the trim's while set (limp mode)
}

local Powertrain = {}
Powertrain.__index = Powertrain

export type Powertrain = typeof(setmetatable({} :: State, Powertrain))

local function approach(current: number, target: number, maxStep: number): number
	if current < target then
		return math.min(current + maxStep, target)
	end
	return math.max(current - maxStep, target)
end

local function modeSettings(mode: Types.DriveMode): Driving.ModeSettings
	return Driving.modes[mode] or Driving.modes.standard
end

-- Full-pedal drive acceleration the curve allows at `speed` (Standard mode, before gears, limiter and grip):
-- constant up to baseSpeed, then constant power, so acceleration = peak * baseSpeed / speed.
function Powertrain.tractiveAccel(spec: Spec, speed: number): number
	local s = math.abs(speed)
	if s <= spec.baseSpeed then
		return spec.peakAccel
	end
	return spec.peakAccel * spec.baseSpeed / s
end

-- Deceleration from aero drag and rolling resistance at `speed` (>= 0).
function Powertrain.resistance(spec: Spec, speed: number): number
	return spec.dragCoefficient * speed * speed + spec.rollingResistance
end

-- The most drive acceleration the tires accept on flat ground in `mode` (traction control's limit at
-- static load). The chassis computes the real limit per wheel each frame.
function Powertrain.tractionCap(spec: Spec, mode: Types.DriveMode): number
	return spec.tractionLimit * modeSettings(mode).tractionUse
end

-- Limiter: never ask for more than holds `limit`. Near the limit the request is the resistance plus a
-- proportional pull toward it, so speed settles exactly on `limit` (a P-controller with feed-forward).
local function limited(spec: Spec, available: number, speed: number, limit: number): number
	local hold = Powertrain.resistance(spec, math.abs(speed)) + Driving.powertrain.limiterGain * (limit - speed)
	return math.min(available, math.max(0, hold))
end

function Powertrain.new(spec: Spec): Powertrain
	local self: State = {
		spec = spec,
		pedal = 0,
		reversing = false,
		reverseTimer = 0,
		gear = 1,
		shiftTimer = 0,
		speedCap = nil,
	}
	return setmetatable(self, Powertrain)
end

-- Back to a standstill in drive (after the server moves the car). A speed cap stays: it belongs to the car's
-- energy, not to its motion.
function Powertrain.reset(self: Powertrain)
	self.pedal = 0
	self.reversing = false
	self.reverseTimer = 0
	self.gear = 1
	self.shiftTimer = 0
end

-- Holds the car under `studsPerSecond` (forward and reverse) until it is lifted with nil. A cap at or above the
-- trim's own top speed changes nothing. Non-positive or non-finite caps are ignored.
function Powertrain.setSpeedCap(self: Powertrain, studsPerSecond: number?)
	if studsPerSecond ~= nil and not (studsPerSecond > 0 and studsPerSecond < math.huge) then
		return
	end
	self.speedCap = studsPerSecond
end

-- The cap set with setSpeedCap, or nil.
function Powertrain.getSpeedCap(self: Powertrain): number?
	return self.speedCap
end

-- The top speed (studs/s) the car may reach going forward, or in reverse, right now: the trim's, or the speed
-- cap when that is lower.
function Powertrain.topSpeedNow(self: Powertrain, reversing: boolean): number
	local spec = self.spec
	local top = if reversing then spec.reverseTopSpeed else spec.topSpeed
	local cap = self.speedCap
	return if cap ~= nil then math.min(top, cap) else top
end

-- Decides between drive and reverse. Reverse engages after the brake is held at a standstill; drive comes
-- back as soon as the throttle is pressed at a standstill, or if the car is rolling forward.
local function updateDirection(self: Powertrain, dt: number, throttle: boolean, brake: boolean, forwardSpeed: number)
	local settings = Driving.powertrain
	local stopped = math.abs(forwardSpeed) < settings.reverseEngageSpeed
	if self.reversing then
		self.reverseTimer = 0
		if forwardSpeed > settings.reverseEngageSpeed or (throttle and not brake and stopped) then
			self.reversing = false
		end
	elseif brake and not throttle and stopped then
		self.reverseTimer += dt
		if self.reverseTimer >= settings.reverseEngageDelay then
			self.reversing = true
			self.reverseTimer = 0
			self.gear = 1
			self.shiftTimer = 0
		end
	else
		self.reverseTimer = 0
	end
end

-- Fuel cars: picks the gear and returns the share of the force curve it delivers right now.
local function gearbox(self: Powertrain, dt: number, speed: number): number
	local fuel = Driving.powertrain.fuel
	local gears = self.spec.gearSpeeds
	if self.shiftTimer > 0 then
		self.shiftTimer = math.max(0, self.shiftTimer - dt)
		return fuel.shiftDrive
	end
	if self.gear < #gears and speed >= gears[self.gear] * fuel.upshiftAt then
		self.gear += 1
		self.shiftTimer = fuel.shiftTime
		return fuel.shiftDrive
	end
	if self.gear > 1 and speed < gears[self.gear - 1] * fuel.downshiftAt then
		self.gear -= 1
	end
	local revs = math.clamp(speed / gears[self.gear], 0, 1)
	return fuel.lowRpmDrive + (1 - fuel.lowRpmDrive) * revs
end

function Powertrain.update(
	self: Powertrain,
	dt: number,
	controls: Types.Controls,
	forwardSpeed: number,
	mode: Types.DriveMode,
	regen: Types.RegenLevel
): PowertrainOutput
	local spec = self.spec
	local settings = Driving.powertrain
	local shaping = modeSettings(mode)

	local throttleIn = math.clamp(controls.throttle, 0, 1)
	local brakeIn = math.clamp(controls.brake, 0, 1)
	local throttlePressed = throttleIn > settings.pedalThreshold
	local brakePressed = brakeIn > settings.pedalThreshold
	updateDirection(self, dt, throttlePressed, brakePressed, forwardSpeed)

	-- In reverse the pedals swap: the brake pedal drives backwards and the throttle brakes.
	local drivePedal = if self.reversing then brakeIn else throttleIn
	local brakePedal = if self.reversing then throttleIn else brakeIn

	-- Mode shaping: a pedal curve, then a rate limit on opening (closing is always quick). Full pedal reaches 1
	-- in every mode.
	local target = drivePedal ^ shaping.throttleExponent
	local rate = if target > self.pedal then shaping.throttleRiseRate else settings.throttleFallRate
	self.pedal = approach(self.pedal, target, rate * dt)

	-- Speed in the direction the car is trying to go, and the most it may reach that way right now (the trim's
	-- top speed, or the limp cap).
	local travelSpeed = if self.reversing then -forwardSpeed else forwardSpeed
	local speedAbs = math.abs(forwardSpeed)
	local limit = self:topSpeedNow(self.reversing)

	local driveAccel: number
	if self.reversing then
		local available = spec.reverseAccel * shaping.forceScale * self.pedal
		driveAccel = -limited(spec, available, travelSpeed, limit)
	else
		local gearShare = if spec.energy == "fuel" then gearbox(self, dt, math.max(0, forwardSpeed)) else 1
		local available = Powertrain.tractiveAccel(spec, forwardSpeed) * gearShare * shaping.forceScale * self.pedal
		driveAccel = limited(spec, available, travelSpeed, limit)
	end

	local brakeAccel = brakePedal * spec.brakeDecel

	-- Lift-off: regen on electric cars, engine braking on fuel cars, fading out at low speed so the car rolls
	-- gently to a stop, and fading in smoothly as the drive pedal comes up (no step for a feathered pedal to
	-- hunt around). Only while moving the way the car is geared.
	local liftShare = math.clamp(1 - drivePedal / settings.regenFadePedal, 0, 1)
	if liftShare > 0 and brakePedal <= settings.pedalThreshold and travelSpeed > 0 then
		local liftOff = if spec.energy == "battery"
			then (settings.regenDecel[regen] or settings.regenDecel.standard) * shaping.regenScale
			else settings.engineBrakeDecel
		brakeAccel += liftOff * liftShare * math.clamp(travelSpeed / settings.liftOffFullSpeed, 0, 1)
	end

	-- Hold the car still when nothing is pressed (no creeping down hills).
	if not throttlePressed and not brakePressed and speedAbs < settings.holdSpeed then
		brakeAccel = math.max(brakeAccel, spec.brakeDecel * settings.holdBrakeFraction)
	end

	-- Going downhill past the limit (or above a new limp cap): brake back toward it, so no car outruns its top
	-- speed for long.
	if travelSpeed > limit then
		brakeAccel += (travelSpeed - limit) * settings.overspeedBrakeGain
	end

	local gear = if self.reversing then "R" elseif spec.energy == "fuel" then tostring(self.gear) else "D"
	return {
		driveAccel = driveAccel,
		brakeAccel = brakeAccel,
		gear = gear,
		reversing = self.reversing,
		shaping = self.pedal,
	}
end

-- Pure 1-D run from a standstill at full throttle on flat ground: same powertrain, force curve, drag, rolling
-- resistance and traction limit as the chassis. Returns seconds to reach `targetSpeed` (studs/s), or
-- math.huge if it never does within `maxSeconds` (default Config/Driving.simulation.maxSeconds).
function Powertrain.simulateTimeToSpeed(
	spec: Spec,
	mode: Types.DriveMode,
	targetSpeed: number,
	maxSeconds: number?
): number
	local dt = Driving.simulation.dt
	local limit = maxSeconds or Driving.simulation.maxSeconds
	local powertrain = Powertrain.new(spec)
	local controls: Types.Controls = { throttle = 1, brake = 0, steer = 0, handbrake = false }
	local cap = Powertrain.tractionCap(spec, mode)
	local speed, time = 0, 0
	while time < limit do
		local output = powertrain:update(dt, controls, speed, mode, "standard")
		local accel = math.min(output.driveAccel, cap) - Powertrain.resistance(spec, speed) - output.brakeAccel
		local nextSpeed = math.max(0, speed + accel * dt)
		if nextSpeed >= targetSpeed then
			-- Interpolate inside the step for a time that does not depend on dt.
			return time + dt * (targetSpeed - speed) / (nextSpeed - speed)
		end
		speed = nextSpeed
		time += dt
	end
	return math.huge
end

-- Seconds from 0 to 60 mph at full throttle in `mode` (math.huge if the car cannot reach 60).
function Powertrain.simulateZeroToSixty(spec: Spec, mode: Types.DriveMode): number
	return Powertrain.simulateTimeToSpeed(spec, mode, Units.mphToStuds(SIXTY_MPH))
end

-- Speed (studs/s) after Config/Driving.simulation.topSpeedSeconds of full throttle in `mode`: where the car
-- settles at the top of its range.
function Powertrain.simulateTopSpeed(spec: Spec, mode: Types.DriveMode): number
	local dt = Driving.simulation.dt
	local powertrain = Powertrain.new(spec)
	local controls: Types.Controls = { throttle = 1, brake = 0, steer = 0, handbrake = false }
	local cap = Powertrain.tractionCap(spec, mode)
	local speed = 0
	for _ = 1, math.ceil(Driving.simulation.topSpeedSeconds / dt) do
		local output = powertrain:update(dt, controls, speed, mode, "standard")
		local accel = math.min(output.driveAccel, cap) - Powertrain.resistance(spec, speed) - output.brakeAccel
		speed = math.max(0, speed + accel * dt)
	end
	return speed
end

return Powertrain
