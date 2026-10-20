--!strict
-- The Arc's thrusters (PLAN.md Phase 10; docs/phase-10-contracts.md "Abilities, client"): what the boost-hop,
-- flight and the controlled landing do to the car in one step. Pure maths, like Vehicle/Chassis's: no
-- instances and no services. Controllers/AbilityController reads the car it drives into a Body every
-- RunService.PreSimulation and adds the returned changes to the car's velocities (the client simulates its own
-- car); tests/Thrusters.spec runs them on a simulated car.
--
--   hopStep      the boost-hop over its window: a hard push up for Config/Thrusters hop.liftSeconds, then a share
--                of gravity held off (a long, low arc), and a push along the nose the whole window, up to
--                hop.maxForwardGain over the speed across the ground the hop started at. Keeps the car level.
--   flightStep   flight: a damped spring holds the car flight.hoverHeight above where it would stand on its
--                wheels (the ground under it comes in as a raycast distance), steer rolls it, throttle pitches the
--                nose down and brake pitches it up (front and back flips), with no input on an axis it drifts back
--                level on that axis, and its speed across the ground fades. With `landing` it is landingStep.
--   landingStep  after flight: descend at the landing rate, slowing over the last few studs, and turn the car
--                upright. After a hop that is still in the air when its window ends: fall no faster than
--                hop.landingDescentRate and turn upright.
--
-- Every change is a velocity (studs/s) or angular velocity (rad/s) change, so the car moves the same at any
-- mass: nothing here reads the car's mass. Pushes act over dt (capped at Config/Thrusters.maxStepDt) and every
-- response is an exponential approach, so the result is the same at any frame rate. The engine pulls the car
-- down by gravity * dt every step; the thrusters hold off all or part of that themselves, and only ever push up
-- (never pull the car down faster than it falls).
--
-- Clamps: the speeds (and the hover height) the thrusters aim for stay inside Config/Abilities.bounds times
-- Config/Thrusters boundsMargin (the limits the server checks during and after each ability), read by name in
-- limits(); the landing lets go within Config/Abilities' landingSeconds (landingTimeout).

local Shared = script.Parent.Parent
local Abilities = require(Shared.Config.Abilities)
local Config = require(Shared.Config.Thrusters)

local WORLD_UP = Vector3.yAxis
local TWO_PI = 2 * math.pi
local EPSILON = 1e-6

-- The car as the thrusters see it this step.
export type Body = {
	up: Vector3, -- the car's up (CFrame.UpVector)
	forward: Vector3, -- the car's nose (CFrame.LookVector)
	linear: Vector3, -- velocity, studs/s
	angular: Vector3, -- angular velocity about world axes, rad/s
	gravity: number, -- workspace.Gravity
	groundDistance: number?, -- studs straight down (world -Y) from the chassis centre to the ground; nil: none in reach
	restHeight: number, -- groundDistance when the car stands on its wheels
}

-- Flight input: steer -1..1 (right rolls right), throttle and brake 0..1 (throttle pitches the nose down).
export type Input = { steer: number, throttle: number, brake: number }

-- What to add to the car's velocities this step.
export type Change = { linear: Vector3, angular: Vector3 }

export type Ability = "boostHop" | "flight"

-- What the thrusters aim for at most (studs/s; hoverHeight in studs): the feel numbers in Config/Thrusters, cut
-- down to boundsMargin x Config/Abilities.bounds where those are lower.
export type Limits = {
	hopUp: number, -- upward speed during a hop
	hopSpeedGain: number, -- speed across the ground a hop may add over the speed it started at
	flightUp: number, -- climbing
	flightDown: number, -- descending, while hovering and landing
	flightHorizontal: number, -- across the ground: past this the air brake works harder (it never gains)
	hoverHeight: number, -- above where the car stands on its wheels
}

local Thrusters = {}

-- Limits -------------------------------------------------------------------------------------------------------

-- boundsMargin x Config/Abilities.bounds[ability][key], or math.huge when the bound isn't a positive number.
-- Read loosely: Config/Abilities is the ability-server helper's file and only these names are shared.
local function bound(ability: Ability, key: string): number
	local bounds = (Abilities :: any).bounds
	local group = if type(bounds) == "table" then bounds[ability] else nil
	local value = if type(group) == "table" then group[key] else nil
	if type(value) == "number" and value > 0 and value == value then
		return value * Config.boundsMargin
	end
	return math.huge
end

function Thrusters.limits(): Limits
	return {
		hopUp = math.min(Config.hop.maxUpSpeed, bound("boostHop", "maxUpSpeed")),
		hopSpeedGain = math.min(Config.hop.maxForwardGain, bound("boostHop", "maxSpeedGain")),
		flightUp = math.min(Config.flight.climbLimit, bound("flight", "maxUpSpeed")),
		flightDown = math.min(Config.flight.maxDescent, bound("flight", "maxDownSpeed")),
		flightHorizontal = bound("flight", "maxHorizontalSpeed"),
		hoverHeight = math.min(Config.flight.hoverHeight, bound("flight", "maxHeight")),
	}
end

local LIMITS = Thrusters.limits()

-- The controlled landing's descent rate after flight, studs/s: Config/Thrusters landing.descentRate, within the
-- flight descent limit.
function Thrusters.landingRate(): number
	return math.min(Config.landing.descentRate, LIMITS.flightDown)
end

-- Seconds after AbilityEndsAt the client keeps landing the car before it lets go: Config/Thrusters' own timeout
-- for that ability, never longer than Config/Abilities' landingSeconds (how long the server keeps its allowance).
function Thrusters.landingTimeout(ability: Ability): number
	local own = if ability == "boostHop" then Config.hop.landingTimeoutSeconds else Config.landing.timeoutSeconds
	local timing = (Abilities :: any)[ability]
	local server = if type(timing) == "table" then timing.landingSeconds else nil
	if type(server) == "number" and server >= 0 then
		return math.min(own, server)
	end
	return own
end

-- Helpers ------------------------------------------------------------------------------------------------------

local NO_CHANGE: Change = table.freeze({ linear = Vector3.zero, angular = Vector3.zero })

-- Share of the way an exponential approach at `rate` (1/s) covers in dt.
local function response(rate: number, dt: number): number
	return 1 - math.exp(-rate * dt)
end

local function stepDt(dt: number): number
	return math.clamp(dt, 0, Config.maxStepDt)
end

-- The car's nose flattened onto the ground plane (its right side when the nose points straight up or down).
local function flatNose(body: Body): Vector3
	local flat = Vector3.new(body.forward.X, 0, body.forward.Z)
	if flat.Magnitude > EPSILON then
		return flat.Unit
	end
	local side = body.forward:Cross(body.up)
	return Vector3.new(side.X, 0, side.Z).Unit
end

-- Height above where the car stands on its wheels, or nil with no ground in reach.
local function heightOf(body: Body): number?
	local distance = body.groundDistance
	return if distance ~= nil then distance - body.restHeight else nil
end

-- The angular velocity that turns the car upright: about the axis from its up to world up, at
-- Config/Thrusters level.gain rad/s per radian of tilt, at most `rate`. Upside down it rolls over its nose.
-- Horizontal, so it never turns the car about world up.
function Thrusters.levelTarget(up: Vector3, forward: Vector3, rate: number): Vector3
	local axis = up:Cross(WORLD_UP)
	local tilt = math.atan2(axis.Magnitude, up:Dot(WORLD_UP))
	if tilt < EPSILON then
		return Vector3.zero
	end
	if axis.Magnitude < EPSILON then
		axis = Vector3.new(forward.X, 0, forward.Z)
		if axis.Magnitude < EPSILON then
			axis = Vector3.xAxis
		end
	end
	return axis.Unit * math.min(tilt * Config.level.gain, rate)
end

-- The angular change that turns the car toward upright at most `rate`, leaving its turn about world up alone
-- (a car steering into a hop keeps turning).
local function levelChange(body: Body, rate: number, dt: number): Vector3
	local target = Thrusters.levelTarget(body.up, body.forward, rate)
	local spin = body.angular
	local tumble = spin - WORLD_UP * spin:Dot(WORLD_UP)
	return (target - tumble) * response(Config.level.spinResponse, dt)
end

-- The upward velocity change that holds `thrust` (studs/s², up) over dt, cut so the car ends the step no faster
-- than `upLimit` upward. The thrusters only push up: never below zero.
local function upChange(vertical: number, thrust: number, gravity: number, upLimit: number, dt: number): number
	local push = thrust
	if vertical + (thrust - gravity) * dt > upLimit then
		push = (upLimit - vertical) / dt + gravity
	end
	return math.max(0, push) * dt
end

-- The horizontal velocity change while flying or landing after flight: the air brake, so the car never gains
-- speed across the ground, braking harder while it is over the flight limit (it took off faster than flight
-- allows) without ever stopping it dead.
local function airBrake(linear: Vector3, dt: number): Vector3
	local horizontal = Vector3.new(linear.X, 0, linear.Z)
	local speed = horizontal.Magnitude
	if speed < EPSILON then
		return Vector3.zero
	end
	local flight = Config.flight
	local rate = if speed > LIMITS.flightHorizontal then flight.overspeedBrakeRate else flight.airBrakeRate
	return horizontal.Unit * (speed * math.exp(-rate * dt) - speed)
end

-- Boost-hop ----------------------------------------------------------------------------------------------------

-- One step of the hop. `elapsed` is seconds since the window started; `startSpeed` the car's speed across the
-- ground (studs/s) when it did. The push never takes that speed past startSpeed + the hop's speed gain.
function Thrusters.hopStep(rawDt: number, body: Body, elapsed: number, startSpeed: number): Change
	local dt = stepDt(rawDt)
	if dt <= 0 then
		return NO_CHANGE
	end
	local hop = Config.hop
	local gravity = body.gravity
	local linear = body.linear

	-- Up: the lift, then the glide, never past the up limit.
	local thrust = if elapsed < hop.liftSeconds then gravity + hop.liftAccel else gravity * hop.glideGravityShare
	local up = upChange(linear.Y, thrust, gravity, LIMITS.hopUp, dt)

	-- Forward: along the nose, only as far as the speed limit across the ground. Adding f along the nose raises
	-- that speed by at most f, so it never ends the step past the limit.
	local horizontalSpeed = Vector3.new(linear.X, 0, linear.Z).Magnitude
	local room = math.max(0, startSpeed + LIMITS.hopSpeedGain - horizontalSpeed)
	local forward = math.min(hop.forwardAccel * dt, room)

	return {
		linear = WORLD_UP * up + flatNose(body) * forward,
		angular = levelChange(body, hop.levelRate, dt),
	}
end

-- Flight -------------------------------------------------------------------------------------------------------

-- The roll and pitch flight aims for: the input's rate on each axis that has input, else the drift back level on
-- that axis; no turn about the car's up.
local function flightSpin(body: Body, input: Input): Vector3
	local flight = Config.flight
	local forward, up = body.forward, body.up
	local right = forward:Cross(up)
	local level = Thrusters.levelTarget(up, forward, flight.autoLevelRate)
	local roll = level:Dot(forward)
	local pitch = level:Dot(right)
	local steer = math.clamp(input.steer, -1, 1)
	if math.abs(steer) > flight.inputDeadzone then
		roll = steer * flight.rollRate -- about the nose: right side down for steer right
	end
	local nose = math.clamp(input.brake, 0, 1) - math.clamp(input.throttle, 0, 1)
	if math.abs(nose) > flight.inputDeadzone then
		pitch = nose * flight.flipRate -- about the right side: nose up for brake, down for throttle
	end
	return right * pitch + forward * roll
end

-- One step of the controlled landing (see the header). `ability` is the one that just ended (flight by default).
function Thrusters.landingStep(rawDt: number, body: Body, ability: Ability?): Change
	local dt = stepDt(rawDt)
	if dt <= 0 then
		return NO_CHANGE
	end
	local landing = Config.landing
	local gravity = body.gravity
	local linear = body.linear

	if ability == "boostHop" then
		-- Fall freely, but never faster than the hop's landing rate.
		local falling = linear.Y - gravity * dt
		local catch = math.max(0, -Config.hop.landingDescentRate - falling)
		return { linear = WORLD_UP * catch, angular = levelChange(body, landing.levelRate, dt) }
	end

	-- Descend at the landing rate, slowing in proportion over the last flareHeight studs.
	local rate = Thrusters.landingRate()
	local height = heightOf(body)
	if height ~= nil then
		rate = math.clamp(height * rate / landing.flareHeight, math.min(landing.touchdownSpeed, rate), rate)
	end
	local endVertical = linear.Y + (-rate - linear.Y) * response(landing.verticalResponse, dt)
	local up = math.max(0, endVertical - linear.Y + gravity * dt)

	-- Turn upright, and stop any turn about the car's own up.
	local spin = body.angular
	local target = Thrusters.levelTarget(body.up, body.forward, landing.levelRate)
	local angular = (target - spin) * response(Config.level.spinResponse, dt)

	return { linear = WORLD_UP * up + airBrake(linear, dt), angular = angular }
end

-- One step of flight (or, with `landing`, of the landing after it). See the header.
function Thrusters.flightStep(rawDt: number, body: Body, input: Input, landing: boolean?): Change
	if landing then
		return Thrusters.landingStep(rawDt, body, "flight")
	end
	local dt = stepDt(rawDt)
	if dt <= 0 then
		return NO_CHANGE
	end
	local flight = Config.flight
	local gravity = body.gravity
	local linear = body.linear

	-- The hover spring: acceleration = w² x height error - 2 zeta w x vertical speed, on top of holding off
	-- gravity, with the speed it ends the step at kept between the descent and climb limits.
	local omega = TWO_PI * flight.hoverFrequency
	local height = heightOf(body)
	local heightError = if height ~= nil then LIMITS.hoverHeight - height else -flight.maxHeightError
	heightError = math.clamp(heightError, -flight.maxHeightError, flight.maxHeightError)
	local accel = omega * omega * heightError - 2 * flight.hoverDamping * omega * linear.Y
	local endVertical = math.clamp(linear.Y + accel * dt, -LIMITS.flightDown, LIMITS.flightUp)
	local up = math.max(0, endVertical - linear.Y + gravity * dt)

	local angular = (flightSpin(body, input) - body.angular) * response(flight.spinResponse, dt)

	return { linear = WORLD_UP * up + airBrake(linear, dt), angular = angular }
end

return Thrusters
