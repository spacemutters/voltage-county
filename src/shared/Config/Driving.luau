--!strict
-- Every driving tunable (PLAN.md Phase 1): powertrain, drive modes, regen, tires, brakes, steering, suspension,
-- body damping and the chassis density, plus the settings of the 1-D simulation that calibrates each trim.
-- Vehicle/Tuning turns these and a trim's catalog stats into per-trim numbers; Vehicle/Powertrain,
-- Vehicle/Chassis and Vehicle/WheelVisuals read them.
--
-- Units are studs, seconds, studs/s and studs/s². Physics is mass-independent: every force is the assembly's
-- mass times an acceleration from here, so passengers and chassis density never change how a car drives.
-- Gravity is read from workspace.Gravity at run time (196.2 studs/s² by default) and never stored here.
-- With 1 stud = 0.28 m, 60 mph is 95.8 studs/s and Roblox gravity is about 5.6 real g, so the grip
-- coefficients below are relative to Roblox gravity and look small next to real-world tire numbers.

-- What a drive mode changes. Standard is the catalog car; comfort softens it; sport sharpens it without ever
-- beating Standard's 0-60 or top speed (both are full-pedal numbers, and full pedal is the same in every mode
-- except comfort's lower force and slower ramp).
export type ModeSettings = {
	forceScale: number, -- share of the trim's drive force (never above 1)
	throttleRiseRate: number, -- how fast the throttle may open, in full pedal travels per second
	throttleExponent: number, -- pedal curve: above 1 is gentle, 1 is linear, below 1 is sharp
	regenScale: number, -- multiplies an electric car's lift-off regen
	tractionUse: number, -- share of a tire's remaining grip drive may use before traction control trims it
	steerRate: number, -- how fast the wheels follow the stick, in full locks per second
	steerGripUse: number, -- speed-sensitive lock: how far past the tire's grip limit the wheels may turn
	suspensionFrequencyScale: number, -- multiplies the trim's suspension frequency
	dampingScale: number, -- multiplies the trim's damping ratio
}

local modes: { [string]: ModeSettings } = {
	comfort = {
		forceScale = 0.8,
		throttleRiseRate = 2.5,
		throttleExponent = 1.4,
		regenScale = 1.3,
		tractionUse = 0.85,
		steerRate = 4,
		steerGripUse = 1.1,
		suspensionFrequencyScale = 0.88,
		dampingScale = 0.92,
	},
	standard = {
		forceScale = 1,
		throttleRiseRate = 8,
		throttleExponent = 1,
		regenScale = 1,
		tractionUse = 0.92,
		steerRate = 6,
		steerGripUse = 1.25,
		suspensionFrequencyScale = 1,
		dampingScale = 1,
	},
	-- Sharper at part throttle (the exponent), but the ramp to full pedal matches Standard so a full-pedal
	-- launch is identical: sport may never be quicker than the catalog 0-60.
	sport = {
		forceScale = 1,
		throttleRiseRate = 8,
		throttleExponent = 0.75,
		regenScale = 0.8,
		tractionUse = 1,
		steerRate = 9,
		steerGripUse = 1.4,
		suspensionFrequencyScale = 1.1,
		dampingScale = 1.08,
	},
}

local Driving = {
	-- Density of the invisible Chassis box (the only physics body). Mass does not change handling (see above);
	-- it only sets how hard cars shove each other and loose props.
	chassisDensity = 1.5,

	-- Frame times. Gravity acts over the whole frame, so weight support, drive, brakes, drag and rolling
	-- resistance use the real frame time, up to maxFrameDt (so one hitch can never fire a giant impulse). The
	-- suspension's stiffness and damping use at most maxStepDt, and suspension.maxModeStep softens the springs
	-- on slow frames, so the car stays stable at any frame rate (the target range is 30 to 144 fps).
	maxFrameDt = 1 / 10,
	maxStepDt = 1 / 20,

	modes = modes,

	-- The pure 1-D straight-line simulation (Powertrain.simulate*), used to calibrate trims and by specs.
	simulation = {
		dt = 1 / 120,
		maxSeconds = 60, -- a 0-60 run that takes longer than this counts as "never"
		topSpeedSeconds = 60, -- every trim settles at its top speed well inside this
	},

	-- Tuning.forTrim bisects each trim's peak acceleration until the simulation hits the catalog 0-60.
	calibration = {
		-- Cars that cannot reach 60 mph (the fleet Pod) calibrate to the same average acceleration up to this
		-- share of their top speed instead.
		maxTargetFractionOfTop = 0.9,
		iterations = 40,
		tolerance = 1e-4, -- stop when the bracket is this narrow, relative
		maxExpansions = 12, -- doublings of the upper bracket before giving up
		searchTimeFactor = 3, -- a candidate run is cut off at this multiple of the target time
	},

	powertrain = {
		-- The force curve, shared by every car: full force up to baseSpeed (constant torque), then constant
		-- power (force falls as 1 / speed). baseSpeed = this fraction of top speed.
		baseSpeedFraction = 0.4,
		-- Aero drag is sized so the curve alone would top out this much above the catalog top speed; the
		-- limiter below holds the catalog number exactly.
		topSpeedHeadroom = 1.1,
		-- Limiter: near top speed the drive asks only for (drag + rolling) + limiterGain * (top - speed),
		-- so speed settles exactly at top speed. 1/s.
		limiterGain = 3,
		-- Above top speed (downhill), brake back toward it at this rate. 1/s. Strong enough that even a 30-degree
		-- downhill settles under 1.1x top speed (tests/Powertrain.spec), inside anti-exploit's 1.15x.
		overspeedBrakeGain = 10,

		pedalThreshold = 0.05, -- pedal travel below this counts as "not pressed"
		throttleFallRate = 10, -- the throttle closes this fast (full travels per second) in every mode

		-- Reverse: hold the brake below reverseEngageSpeed for reverseEngageDelay and the car shifts to R. In
		-- R the brake pedal drives backwards and the throttle brakes.
		reverseTopSpeedMph = 20,
		reverseForceFraction = 0.5, -- of the trim's peak acceleration
		reverseEngageSpeed = 1.5, -- studs/s
		reverseEngageDelay = 0.35, -- seconds

		-- With no pedal pressed below holdSpeed the brakes hold the car (no creeping down hills), at full brake
		-- strength (the tires still cap it at their grip).
		holdSpeed = 1, -- studs/s
		holdBrakeFraction = 1, -- of the trim's brake deceleration

		-- Lift-off braking fades out below this speed, so a car coasts gently to a stop. studs/s.
		liftOffFullSpeed = 20,
		-- Lift-off braking also fades out as the drive pedal goes from 0 to this much travel, so feathering the
		-- pedal never switches it on and off in a step.
		regenFadePedal = 0.15,
		-- Electric lift-off regen per level, studs/s² (about 0.07, 0.14 and 0.25 real g).
		regenDecel = { low = 2.5, standard = 5, high = 9 } :: { [string]: number },
		-- Fuel cars' engine braking on lift-off, studs/s².
		engineBrakeDecel = 2.5,

		-- Fuel cars: a simple automatic. Each gear tops out at this fraction of the curve's unrestricted top
		-- speed; it shifts up at upshiftAt of the gear's top (drive drops to shiftDrive for shiftTime) and down
		-- when speed falls below downshiftAt of the lower gear's top. Drive at low revs in a gear is
		-- lowRpmDrive of the curve, rising to the full curve at the gear's top.
		fuel = {
			gearSpeedFractions = { 0.22, 0.38, 0.55, 0.75, 1 },
			upshiftAt = 0.96,
			downshiftAt = 0.55,
			shiftTime = 0.22,
			shiftDrive = 0.25,
			lowRpmDrive = 0.8,
		},
	},

	resistance = {
		-- Rolling resistance = rollingCoefficient * gravity (about 1.2 studs/s² at default gravity).
		rollingCoefficient = 0.006,
		minDragCoefficient = 1e-6, -- floor so drag is never zero or negative, 1/stud
	},

	tires = {
		-- Friction coefficient (relative to gravity) from the trim's handling 0..1, front and rear alike.
		gripAtHandling0 = 0.45,
		gripAtHandling1 = 0.95,
		-- The rear tires grip a little more, so cars understeer gently at the limit instead of spinning.
		rearGripScale = 1.08,
		-- How quickly a tire kills sideways sliding below its grip limit, 1/s (the tire's cornering
		-- stiffness, mass-independent). From handling 0..1.
		lateralRateAtHandling0 = 14,
		lateralRateAtHandling1 = 30,
		-- One step cancels at most this share of a patch's sideways sliding. A turning car's front and rear
		-- tires add up to slightly more than their mass shares in yaw, so this stays a little under 1.
		maxLateralCancel = 0.9,
		-- Tire forces are applied this share of the way from the contact patch up to the center of mass. A
		-- higher point means less body roll and pitch; it is what keeps tall vehicles from tipping in turns.
		lateralForceRaise = 0.6,
		longitudinalForceRaise = 0.4,
		-- Grip is capped at this share of what would tip the car over (track / 2 over the effective center
		-- of mass height), so no trim can roll itself over on flat ground.
		rolloverSafety = 0.75,
		-- Handbrake: rear sideways grip falls to this share, and the rear tires drag at this share of grip.
		handbrakeLateralGrip = 0.35,
		handbrakeFriction = 0.6,
		-- All-wheel drive sends this share of drive force to the front axle.
		awdFrontSplit = 0.4,
	},

	brakes = {
		-- Full-pedal deceleration from handling 0..1, studs/s² (about 0.85 to 1.4 real g), capped at
		-- maxGripUse of what the tires can hold.
		decelAtHandling0 = 30,
		decelAtHandling1 = 50,
		maxGripUse = 0.9,
		frontBias = 0.6, -- share of braking on the front axle
	},

	steering = {
		-- Full lock at walking pace, from handling 0..1.
		lockAtHandling0Deg = 32,
		lockAtHandling1Deg = 38,
		-- At speed the lock shrinks to what the tires can turn (scaled by the mode's steerGripUse), never below
		-- this.
		minLockDeg = 2.5,
	},

	suspension = {
		-- Natural frequency of each corner in Hz, from handling 0..1. The spring is sized from the corner's
		-- share of the assembly mass, so it is the same for any mass. Roblox gravity is strong, so these are
		-- stiffer than a real road car's.
		frequencyAtHandling0 = 1.9,
		frequencyAtHandling1 = 2.6,
		dampingRatio = 0.6, -- of critical damping, averaged over bump and rebound
		-- Softer on bump (hitting a speed bump does not kick the car up) and firmer on rebound (it does not
		-- bounce after). Their mean is 1.
		bumpDampingScale = 0.6,
		reboundDampingScale = 1.4,
		-- Anti-roll bar stiffness as a share of the corner spring: resists left/right compression differences.
		antiRollRatio = 0.5,
		-- Past this share of the ride height the spring stiffens by bumpStopStiffness times (a bump stop).
		bumpStopFraction = 0.7,
		bumpStopStiffness = 3,
		-- No corner is ever treated as carrying less than this share of the car's weight.
		minLoadShare = 0.05,
		-- Stability limit: the stiffest way the body can spring (bounce, pitch or roll, anti-roll bars and bump
		-- stops included) may take at most this (omega * dt)² in one step. Explicit springs blow up above 2, so
		-- slow frames soften the springs to stay under it: the bump stops (the stiffest part) from about 55 fps
		-- down on the stiffest car, the springs themselves only below about 28 fps.
		maxModeStep = 1.6,
	},

	-- Modest damping of the body's pitch and roll rates, 1/s, so the car settles instead of rocking and can't
	-- be flipped by a bump. Yaw is left to the tires.
	body = {
		pitchDampingRate = 3,
		rollDampingRate = 3,
		airborneDampingRate = 0.6,
	},

	-- Visual-only wheel animation (Vehicle/WheelVisuals), for this client's car and everyone else's.
	wheelVisuals = {
		maxDroop = 0.6, -- studs the wheel may hang below its rest position
		maxSteerDeg = 38, -- clamp on the steering angle inferred for other players' cars
		steerSmoothing = 10, -- 1/s, smoothing of that inferred angle
		inferMinSpeed = 2, -- studs/s; below this the inferred steering holds still
	},
}

return Driving
