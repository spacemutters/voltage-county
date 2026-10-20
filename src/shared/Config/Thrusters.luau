--!strict
-- How the Arc's thrusters feel (PLAN.md Phase 10; docs/phase-10-contracts.md "Abilities, client"). Read by
-- Vehicle/Thrusters (the forces), Controllers/AbilityController (when they run, the plumes and the hiss) and
-- tests/Thrusters.spec.
--
-- The rules live in Config/Abilities: which trims have which ability, cooldowns, how long each window lasts and
-- the velocity bounds the server checks during and after it. So do the contract's tunables (the push sizes, the
-- hover height, the roll and flip rates and the landing descent rates), which this file reads from there; the
-- rest here is the finer feel. Vehicle/Thrusters never aims past boundsMargin x those bounds, whatever the
-- numbers below say, and tests/Thrusters.spec runs every ability on a simulated car to prove it stays inside them.
--
-- Every push is an acceleration (studs/s²) or a velocity (studs/s) applied as a velocity change, so the car
-- moves the same at any mass. Gravity is read from workspace.Gravity at run time (196.2 studs/s² by default);
-- at that gravity 20 mph is about 32 studs/s.

local Abilities = require(script.Parent.Abilities)

export type AbilityRates = { rear: number, down: number }

local Thrusters = {
	-- Share of each Config/Abilities velocity bound the thrusters ever aim for; the rest is headroom for network
	-- jitter and the car's own drive.
	boundsMargin = 0.9,
	-- Longest step one update may push for, in seconds, so a hitch never fires a giant push.
	maxStepDt = 1 / 10,
	-- Wheels on the ground (Chassis telemetry) that count as the car being back on its wheels.
	landedWheels = 3,
	-- How far straight down the height ray reaches from the chassis centre, in studs. Past this the car counts
	-- as having no ground under it.
	rayLength = 120,
	-- The server clearing a car's Ability attribute this close to AbilityEndsAt (seconds) counts as the window
	-- ending, so a flight still lands; any earlier it was cancelled (a reset) and the thrusters stop at once.
	cancelGraceSeconds = 0.25,
	-- Studs from the chassis centre down to the ground when the car stands on its wheels, used only when the car
	-- has no wheel attachment to measure it from (the model contract always has one).
	fallbackRestHeight = 1.5,

	-- Shared by the hop, flight and the landing: how the car is turned back upright.
	level = {
		gain = 4, -- 1/s: rad/s of turn per radian of tilt (a big tilt turns at the rate cap below)
		spinResponse = 6, -- 1/s: how quickly the car's spin follows the levelling turn
	},

	hop = {
		-- The first part of the window pushes up hard...
		liftSeconds = 0.25,
		liftAccel = Abilities.boostHop.upAccel, -- studs/s² on top of holding off gravity
		maxUpSpeed = 20, -- studs/s; the lift stops pushing here
		-- ...then this share of gravity is held off for the rest of the window: a long, low, floaty arc
		-- (about 9 studs high and 1.7 s long from flat ground, inside the 2 s window).
		glideGravityShare = 0.85,
		-- A push along the nose for the whole window, up to maxForwardGain over the speed the hop started at.
		forwardAccel = Abilities.boostHop.forwardAccel, -- studs/s²
		maxForwardGain = 40, -- studs/s, about 25 mph
		levelRate = 2, -- rad/s at most, keeping the car level in the air
		-- After the window, a car still in the air falls no faster than this until its wheels touch, for at most
		-- landingTimeoutSeconds (no longer than Config/Abilities boostHop.landingSeconds).
		landingDescentRate = Abilities.boostHop.landingDescentRate, -- studs/s
		landingTimeoutSeconds = 1.5,
	},

	flight = {
		hoverHeight = Abilities.flight.hoverHeight, -- studs above where the car stands on its wheels
		-- The hover is a damped spring to that height, measured by a ray down to the ground under the car.
		hoverFrequency = 0.5, -- Hz
		hoverDamping = 1, -- damping ratio (1 = rises without overshooting)
		maxHeightError = 30, -- studs; the spring never pulls harder than this far off the height
		climbLimit = 30, -- studs/s up
		maxDescent = 20, -- studs/s down while hovering
		airBrakeRate = 0.6, -- 1/s: the car's speed across the ground fades while it flies (it never gains)
		overspeedBrakeRate = 1.5, -- 1/s, instead, while it is faster than Config/Abilities' maxHorizontalSpeed
		-- Steer rolls the car, throttle pitches the nose down (a front flip) and brake pitches it up (a back flip).
		rollRate = Abilities.flight.rollRate, -- rad/s at full steer
		flipRate = Abilities.flight.flipRate, -- rad/s at full throttle or brake
		spinResponse = 8, -- 1/s: how quickly the spin follows the input
		inputDeadzone = 0.15, -- input below this counts as none
		autoLevelRate = 1.5, -- rad/s at most: with no input on an axis, the car drifts back level on it
	},

	-- The controlled landing after flight. The client keeps it going after AbilityEndsAt until landedWheels touch
	-- or timeoutSeconds pass (no longer than Config/Abilities flight.landingSeconds). From the hover height it
	-- takes about 2 s.
	landing = {
		descentRate = Abilities.flight.landingDescentRate, -- studs/s
		flareHeight = 6, -- studs above rest: below this the descent slows in proportion...
		touchdownSpeed = 5, -- ...down to this, studs/s
		verticalResponse = 10, -- 1/s: how quickly the descent follows that speed
		levelRate = 4, -- rad/s at most
		timeoutSeconds = 5,
	},

	-- Cold-gas plumes: ParticleEmitters at the Thruster_L, Thruster_R (rear, pointing back) and Thruster_Down
	-- (under the floor) attachments, on every client, while a car's Ability window is on. White and light grey
	-- only: cold gas, never flames or orange.
	plume = {
		emitterName = "ThrusterPlume",
		rearNozzles = { "Thruster_L", "Thruster_R" },
		downNozzles = { "Thruster_Down" },
		-- Roblox's own built-in smoke texture (engine content, no Creator Store asset).
		texture = "rbxasset://textures/particles/smoke_main.dds",
		colorStart = Color3.fromRGB(255, 255, 255),
		colorEnd = Color3.fromRGB(214, 218, 224),
		lightEmission = 0.05, -- barely brighter than its surroundings: gas, not fire
		transparencyStart = 0.25,
		transparencyEnd = 1,
		sizeStart = 0.6, -- studs
		sizeEnd = 2.4,
		lifetime = NumberRange.new(0.35, 0.6), -- seconds
		speed = NumberRange.new(26, 34), -- studs/s out of the nozzle
		spreadDegrees = 8,
		drag = 3,
		-- Particles a second per nozzle, by ability: the hop blasts out of the tail, flight holds the car up.
		rates = {
			boostHop = { rear = 90, down = 60 },
			flight = { rear = 25, down = 110 },
		} :: { [string]: AbilityRates },
	},

	-- The short hiss when an ability starts: a Config/Audio sfx id (asset 0 plays nothing).
	hissSound = "thrusterHiss",
}

return Thrusters
