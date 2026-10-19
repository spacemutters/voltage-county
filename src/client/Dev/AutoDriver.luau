--!strict
-- Studio-only test driver (PLAN.md Phase 1). Drives the car the local player sits in by feeding
-- InputController.setOverride every frame, so tests measure the real chassis and powertrain:
--   drive(points, opts)  follows a list of points: pure-pursuit steering toward a point a little way ahead on the
--                        path, PI speed control to `targetMph`, slowing for sharp turns and to stop at the end
--   zeroToSixty(opts)    full throttle in a straight line from a stop; seconds to 60 mph (nil on timeout)
--   holdStill(seconds)   brakes and holds the car where it is
--   stop()               cancels whatever is running and hands the controls back
-- Each call yields until it is done and returns plain tables and numbers.
--
-- Run from MCP execute_luau in the Client datamodel of a playtest, once the player sits in a Driver seat:
--   require(game.Players.LocalPlayer.PlayerScripts.Client.Dev.AutoDriver).zeroToSixty()
--
-- The bridge: execute_luau runs as plugin code, and Studio gives plugin code its own copy of each ModuleScript,
-- so an InputController required there may not be the one the game's DriveController reads. In Studio,
-- CameraController calls serve() from the game's own scripts; that copy puts a BindableFunction named "Bridge"
-- under this module, and calls made from any other copy are forwarded through it to run in the game. With no
-- bridge, calls run in the calling copy.
--
-- Does nothing outside Studio (CLAUDE.md hard rule 8). The client loader never boots it.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local Chassis = require(Shared.Vehicle.Chassis)
local Tuning = require(Shared.Vehicle.Tuning)
local Types = require(Shared.Types)
local Units = require(Shared.Util.Units)
local World = require(Shared.Config.World)

local ClientFolder = (script.Parent :: Instance).Parent :: Instance

export type DriveOptions = {
	targetMph: number?, -- cruise speed (default TUNING.targetMph)
	timeout: number?, -- seconds before giving up (default: scaled from the path length)
	arriveRadius: number?, -- studs from the last point that count as arrived (default TUNING.arriveRadius)
	stopAtEnd: boolean?, -- brake to a stop after arriving (default true)
}

export type Report = {
	completed: boolean, -- reached the last point
	elapsed: number, -- seconds from the start to arriving (or giving up)
	stuckEvents: number, -- times the car sat under TUNING.stuckMph for TUNING.stuckSeconds mid-route
	maxMph: number,
	reason: string, -- "arrived", "timeout", "stopped", "left the car", "not driving", "no points", "studio only"
	pointsReached: number, -- how many of the given points the car got to
}

-- Where the car is on its route: the points (flattened to the ground plane) and the distance along the route
-- at each point.
export type Path = { points: { Vector3 }, along: { number }, length: number }

-- Planning limits, all in studs and seconds.
export type Limits = {
	decel: number, -- studs/s² it plans to brake at
	lateralAccel: number, -- studs/s² of cornering it allows
	cornerSpan: number,
	previewMargin: number,
	minSpeed: number, -- studs/s
	arriveSpeed: number, -- studs/s
	arriveRadius: number,
}

export type SpeedGains = {
	speedKp: number,
	speedKi: number,
	integralLimit: number,
	brakeGain: number,
	brakeDeadbandMph: number,
	reverseSafeMph: number,
}

export type StuckState = { timer: number, counted: boolean }

type InputApi = { setOverride: (controls: Types.Controls?) -> () }
type DriveApi = {
	getCar: () -> Model?,
	getMode: () -> Types.DriveMode,
	setMode: (mode: Types.DriveMode) -> (),
}

-- One run (drive, 0-60, hold). A newer run cancels an older one.
type Run = { cancelled: boolean, car: Model, chassis: BasePart, input: InputApi, drive: DriveApi }

-- Test-driver tuning. A dev tool, so its numbers live here rather than in Shared/Config.
local TUNING = {
	-- drive()
	targetMph = 30, -- cruise speed when opts.targetMph is not given
	arriveRadius = 10, -- studs from the last point that count as arrived
	timeoutFactor = 3, -- default timeout: this many times the route's length at cruise speed...
	timeoutExtra = 20, -- ...plus this many seconds
	minMph = 6, -- never plans slower than this mid-route, so it can't stall before a corner
	arriveMph = 5, -- speed it aims to reach the last point at

	-- Steering (pure pursuit)
	lookaheadMin = 8, -- studs ahead on the route it steers toward at a standstill...
	lookaheadPerMph = 0.4, -- ...plus this much per mph...
	lookaheadMax = 60, -- ...up to this
	lookaheadWheelbases = 1.5, -- and never closer than this many wheelbases
	-- Full lock (steer = 1) is the chassis's own speed-sensitive lock (Chassis.steerLockAt); this is only the
	-- fallback for a car without a tuning.
	maxSteerDegrees = 32,
	steerStiffness = 12, -- smoothing on the steering output, per second

	-- Speed (PI control, in mph)
	speedKp = 0.12, -- throttle per mph under target
	speedKi = 0.04, -- throttle per mph-second of built-up error
	integralLimit = 10, -- mph-seconds; caps the built-up error
	brakeGain = 0.15, -- brake per mph of control output below zero
	brakeDeadbandMph = 2, -- coasts (no brake) until this far over target
	reverseSafeMph = 4, -- never brakes below this speed: brake held at a standstill engages reverse

	-- Planning, in real-world g (converted to studs/s² with Config/World's scale)
	lateralG = 0.6, -- corners: speed² / radius stays under this
	planDecelG = 0.5, -- how hard it plans to brake for corners and the finish
	cornerSpan = 40, -- studs a sharp corner is assumed to be driven over (sets its radius)
	previewMargin = 30, -- studs past braking distance it looks ahead for corners
	projectWindow = 4, -- route segments searched ahead when finding where the car is

	-- Stuck detection
	stuckMph = 2,
	stuckSeconds = 3,

	-- zeroToSixty, holdStill and stopping
	zeroToSixtyTimeout = 30,
	headingHoldGain = 2, -- steer per radian of drift from the starting heading
	headingHoldMax = 0.3, -- steer limit while holding the heading
	stoppedMph = 0.5, -- below this the car counts as stopped
	stillSeconds = 0.5, -- stays stopped this long before a 0-60 run starts
	settleTimeout = 15, -- gives up waiting for the car to stop after this many seconds
	fallbackWheelbaseFraction = 0.6, -- wheelbase guess from car length when the wheel attachments are missing
}

local SIXTY_MPH = 60
local STANDARD_GRAVITY = 9.80665 -- m/s², to turn the g figures above into studs/s²
local TWO_PI = 2 * math.pi
local EPSILON = 1e-6
local BRIDGE_NAME = "Bridge"

-- Pure route and control math, exposed as AutoDriver.Math so tests/AutoDriver.spec can check it.
local AutoMath = {}

function AutoMath.flat(v: Vector3): Vector3
	return Vector3.new(v.X, 0, v.Z)
end

function AutoMath.wrapAngle(angle: number): number
	return (angle + math.pi) % TWO_PI - math.pi
end

-- Yaw (radians) of a look direction on the ground plane; `fallback` when it points straight up or down.
function AutoMath.headingOf(look: Vector3, fallback: number): number
	if math.abs(look.X) + math.abs(look.Z) < EPSILON then
		return fallback
	end
	return math.atan2(-look.X, -look.Z)
end

function AutoMath.smoothing(stiffness: number, dt: number): number
	if dt <= 0 or stiffness <= 0 then
		return 0
	end
	return 1 - math.exp(-stiffness * dt)
end

function AutoMath.buildPath(points: { Vector3 }): Path
	local flatPoints: { Vector3 } = {}
	local along: { number } = {}
	local length = 0
	for i, point in points do
		local flatPoint = AutoMath.flat(point)
		if i > 1 then
			length += (flatPoint - flatPoints[i - 1]).Magnitude
		end
		flatPoints[i] = flatPoint
		along[i] = length
	end
	return { points = flatPoints, along = along, length = length }
end

-- The closest point on the route to `position`, searching `window` segments from `fromSegment` on (so the car
-- only ever moves forward along the route, even where it doubles back on itself).
-- Returns the segment (points[i] to points[i + 1]), how far along it (0..1), and the distance along the route.
function AutoMath.project(path: Path, position: Vector3, fromSegment: number, window: number): (number, number, number)
	local points = path.points
	if #points < 2 then
		return 1, 0, 0
	end
	local here = AutoMath.flat(position)
	local bestSegment, bestT, bestDistance = fromSegment, 0, math.huge
	for i = fromSegment, math.min(#points - 1, fromSegment + window - 1) do
		local a = points[i]
		local ab = points[i + 1] - a
		local lengthSquared = ab:Dot(ab)
		-- A zero-length segment counts as already passed.
		local t = if lengthSquared > 0 then math.clamp((here - a):Dot(ab) / lengthSquared, 0, 1) else 1
		local distance = (a + ab * t - here).Magnitude
		if distance < bestDistance then
			bestSegment, bestT, bestDistance = i, t, distance
		end
	end
	local segmentLength = path.along[bestSegment + 1] - path.along[bestSegment]
	return bestSegment, bestT, path.along[bestSegment] + segmentLength * bestT
end

-- The point `distance` studs along the route (clamped to its ends).
function AutoMath.pointAt(path: Path, distance: number): Vector3
	local points, along = path.points, path.along
	if distance <= 0 or #points < 2 then
		return points[1]
	end
	for i = 2, #points do
		if along[i] >= distance then
			local span = along[i] - along[i - 1]
			local t = if span > 0 then (distance - along[i - 1]) / span else 1
			return points[i - 1]:Lerp(points[i], t)
		end
	end
	return points[#points]
end

-- Pure pursuit: the steering that puts the rear axle on a circle through `target`. `rear` is the rear axle on
-- the ground plane, facing the car's heading. Returns steer in -1..1 (positive = right) and the circle's signed
-- curvature (1/studs). A target behind the car gets full lock toward its side.
function AutoMath.pursuit(rear: CFrame, target: Vector3, wheelbase: number, maxSteer: number): (number, number)
	local offset = rear:PointToObjectSpace(target)
	local right, forward = offset.X, -offset.Z
	local distanceSquared = right * right + forward * forward
	if distanceSquared < EPSILON then
		return 0, 0
	end
	if forward <= 0 then
		local side = if right < 0 then -1 else 1
		return side, side / math.max(wheelbase, EPSILON)
	end
	-- curvature = 2 sin(angle to target) / distance = 2 * right / distance²
	local curvature = 2 * right / distanceSquared
	local wheelAngle = math.atan(curvature * wheelbase)
	return math.clamp(wheelAngle / maxSteer, -1, 1), curvature
end

-- True once the car is within `arriveRadius` of the last point and that close to the end along the route, so
-- a route that ends where it starts (a closed loop) only finishes after the whole lap.
function AutoMath.arrived(path: Path, along: number, position: Vector3, arriveRadius: number): boolean
	local points = path.points
	if #points == 0 then
		return true
	end
	return along >= path.length - arriveRadius and (AutoMath.flat(position) - points[#points]).Magnitude <= arriveRadius
end

-- How sharply the route turns at `b` (radians, 0 = straight on).
function AutoMath.turnAngle(a: Vector3, b: Vector3, c: Vector3): number
	local incoming, outgoing = b - a, c - b
	if incoming.Magnitude < EPSILON or outgoing.Magnitude < EPSILON then
		return 0
	end
	return math.acos(math.clamp(incoming.Unit:Dot(outgoing.Unit), -1, 1))
end

-- Fastest speed (studs/s) through a turn of `angle` radians driven over `span` studs.
function AutoMath.cornerSpeed(angle: number, span: number, lateralAccel: number): number
	if angle < EPSILON then
		return math.huge
	end
	return math.sqrt(lateralAccel * span / angle)
end

-- Fastest speed (studs/s) that can still slow to `endSpeed` within `distance` studs braking at `decel`.
function AutoMath.brakingSpeed(endSpeed: number, distance: number, decel: number): number
	return math.sqrt(endSpeed * endSpeed + 2 * decel * math.max(distance, 0))
end

-- Speed (studs/s) to aim for at `along` studs into the route: cruise, less for corners coming up (soon enough to
-- brake for them) and for the finish.
function AutoMath.planSpeed(path: Path, along: number, cruise: number, limits: Limits): number
	local points, distances = path.points, path.along
	local allowed = cruise
	local preview = cruise * cruise / (2 * limits.decel) + limits.previewMargin
	for i = 2, #points - 1 do
		local ahead = distances[i] - along
		if ahead > preview then
			break
		end
		-- Corners just passed still count while the car is in them.
		if ahead > -limits.cornerSpan then
			local angle = AutoMath.turnAngle(points[i - 1], points[i], points[i + 1])
			local span = math.min(distances[i] - distances[i - 1], distances[i + 1] - distances[i], limits.cornerSpan)
			local corner = math.max(AutoMath.cornerSpeed(angle, span, limits.lateralAccel), limits.minSpeed)
			allowed = math.min(allowed, AutoMath.brakingSpeed(corner, ahead, limits.decel))
		end
	end
	local toFinish = path.length - along - limits.arriveRadius
	return math.min(allowed, AutoMath.brakingSpeed(limits.arriveSpeed, toFinish, limits.decel))
end

-- PI speed control. Returns throttle and brake (0..1). Coasts when only a little over target, and never brakes
-- at crawling speed, where a held brake would engage reverse.
function AutoMath.speedControl(
	state: { integral: number },
	targetMph: number,
	mph: number,
	dt: number,
	gains: SpeedGains
): (number, number)
	local err = targetMph - mph
	local output = gains.speedKp * err + gains.speedKi * state.integral
	-- Anti-windup: stop building up error while the output is already pinned in that direction.
	local pinned = (output >= 1 and err > 0) or (output <= -1 and err < 0)
	if not pinned then
		state.integral = math.clamp(state.integral + err * dt, -gains.integralLimit, gains.integralLimit)
		output = gains.speedKp * err + gains.speedKi * state.integral
	end
	if output >= 0 then
		return math.min(output, 1), 0
	end
	if -err > gains.brakeDeadbandMph and mph > gains.reverseSafeMph then
		return 0, math.min(-output * gains.brakeGain, 1)
	end
	return 0, 0
end

-- Counts one stuck event each time the car sits under `stuckMph` for `stuckSeconds`. Returns true on the frame
-- an event is counted.
function AutoMath.updateStuck(
	state: StuckState,
	mph: number,
	dt: number,
	stuckMph: number,
	stuckSeconds: number
): boolean
	if math.abs(mph) >= stuckMph then
		state.timer = 0
		state.counted = false
		return false
	end
	state.timer += dt
	if state.timer >= stuckSeconds and not state.counted then
		state.counted = true
		return true
	end
	return false
end

local AutoDriver = {}
AutoDriver.Math = AutoMath

local activeRun: Run? = nil
local isHost = false

local function gToStuds(g: number): number
	return g * STANDARD_GRAVITY / World.metersPerStud
end

local function requireController(name: string): any
	local folder = ClientFolder:FindFirstChild("Controllers")
	local moduleScript = if folder then folder:FindFirstChild(name) else nil
	if moduleScript == nil or not moduleScript:IsA("ModuleScript") then
		return nil
	end
	local ok, result = pcall(require :: any, moduleScript)
	if not ok then
		warn(`[AutoDriver] require {name} failed: {result}`)
		return nil
	end
	return result
end

local function sittingInDriverSeat(): boolean
	local character = Players.LocalPlayer and Players.LocalPlayer.Character
	local humanoid = if character then character:FindFirstChildOfClass("Humanoid") else nil
	local seat = if humanoid then humanoid.SeatPart else nil
	return seat ~= nil and seat.Name == "Driver"
end

-- Starts a run on the car the local player drives, cancelling any older run. nil (with a warning) if there
-- is no car to drive.
local function begin(): Run?
	local input: InputApi? = requireController("InputController")
	local drive: DriveApi? = requireController("DriveController")
	if input == nil or drive == nil then
		warn("[AutoDriver] InputController or DriveController is missing")
		return nil
	end
	local car = drive.getCar()
	local chassis = if car then car.PrimaryPart else nil
	if car == nil or chassis == nil then
		if sittingInDriverSeat() then
			warn("[AutoDriver] seated, but this copy can't see the game's DriveController and no bridge is up")
		else
			warn("[AutoDriver] sit in a car's Driver seat first")
		end
		return nil
	end
	if activeRun then
		activeRun.cancelled = true
	end
	local run: Run = { cancelled = false, car = car, chassis = chassis, input = input, drive = drive }
	activeRun = run
	return run
end

-- Ends a run: hands the controls back, unless a newer run has taken over.
local function finish(run: Run)
	if activeRun == run then
		activeRun = nil
		run.input.setOverride(nil)
	end
end

-- Calls `onFrame(dt)` every Heartbeat until it returns true (or errors), yielding the caller until then.
local function eachFrame(onFrame: (dt: number) -> boolean)
	local caller = coroutine.running()
	local done = false
	local connection: RBXScriptConnection? = nil
	connection = RunService.Heartbeat:Connect(function(dt: number)
		if done then
			return
		end
		local ok, result = pcall(onFrame, dt)
		if not ok then
			warn(`[AutoDriver] {result}`)
		end
		if not ok or result then
			done = true
			if connection then
				connection:Disconnect()
			end
			task.spawn(caller)
		end
	end)
	coroutine.yield()
end

-- Signed forward speed in studs/s, read straight from the chassis (telemetry is snapshotted before each frame's
-- physics, so it is a frame old by Heartbeat).
local function speedOf(run: Run): number
	return run.chassis.AssemblyLinearVelocity:Dot(run.chassis.CFrame.LookVector)
end

-- The car's tuning, or nil when its attributes don't name a trim.
local function tuningOf(car: Model): Tuning.Tuning?
	local vehicleId, trimId = car:GetAttribute("VehicleId"), car:GetAttribute("Trim")
	if type(vehicleId) ~= "string" or type(trimId) ~= "string" then
		return nil
	end
	return Tuning.forTrim(vehicleId, trimId)
end

local function stillGoing(run: Run): boolean
	return not run.cancelled and run.drive.getCar() == run.car and run.chassis.Parent ~= nil
end

-- Brake while rolling forward, handbrake always; never the brake at a crawl (it would engage reverse).
local function holdControls(mph: number): Types.Controls
	return { throttle = 0, brake = if mph > TUNING.reverseSafeMph then 1 else 0, steer = 0, handbrake = true }
end

-- Holds the car until it has stayed stopped for `stillSeconds` (true), or `timeout` passes (false).
local function waitUntilStopped(run: Run, stillSeconds: number, timeout: number): boolean
	local started = os.clock()
	local stillFor = 0
	local stopped = false
	eachFrame(function(dt: number): boolean
		if not stillGoing(run) or os.clock() - started > timeout then
			return true
		end
		local mph = Units.studsToMph(speedOf(run))
		stillFor = if math.abs(mph) < TUNING.stoppedMph then stillFor + dt else 0
		if stillFor >= stillSeconds and math.abs(mph) < TUNING.stoppedMph then
			stopped = true
			return true
		end
		run.input.setOverride(holdControls(mph))
		return false
	end)
	return stopped
end

-- Rear-axle pose on the ground plane, facing the car's heading (what pure pursuit steers from).
local function rearAxle(chassis: BasePart, rearOffset: number): CFrame
	local cframe = chassis.CFrame
	local position = AutoMath.flat(cframe:PointToWorldSpace(Vector3.new(0, 0, rearOffset)))
	local heading = AutoMath.headingOf(cframe.LookVector, 0)
	return CFrame.new(position) * CFrame.fromEulerAnglesYXZ(0, heading, 0)
end

-- Wheelbase and the rear axle's offset behind the chassis center (studs), from the wheel hub attachments.
local function axleGeometry(car: Model, chassis: BasePart): (number, number)
	local front = chassis:FindFirstChild("WheelFL")
	local rear = chassis:FindFirstChild("WheelRL")
	if front and rear and front:IsA("Attachment") and rear:IsA("Attachment") then
		-- Front is -Z in chassis space, so the rear axle sits at positive Z.
		return math.abs(rear.Position.Z - front.Position.Z), rear.Position.Z
	end
	local wheelbase = car:GetExtentsSize().Z * TUNING.fallbackWheelbaseFraction
	return wheelbase, wheelbase / 2
end

local function driveHere(points: { Vector3 }, opts: DriveOptions?): Report
	local options: DriveOptions = opts or {}
	local report: Report = {
		completed = false,
		elapsed = 0,
		stuckEvents = 0,
		maxMph = 0,
		reason = "",
		pointsReached = 0,
	}
	if type(points) ~= "table" or #points == 0 then
		report.reason = "no points"
		warn("[AutoDriver] drive needs a list of Vector3 points")
		return report
	end
	for _, point in points do
		if typeof(point) ~= "Vector3" then
			report.reason = "no points"
			warn("[AutoDriver] drive needs a list of Vector3 points")
			return report
		end
	end
	local run = begin()
	if run == nil then
		report.reason = "not driving"
		return report
	end

	local chassis = run.chassis
	local wheelbase, rearOffset = axleGeometry(run.car, chassis)
	-- The route starts where the car is, so the first leg is steered like any other.
	local route = { chassis.Position }
	table.move(points, 1, #points, 2, route)
	local path = AutoMath.buildPath(route)

	local cruise = Units.mphToStuds(options.targetMph or TUNING.targetMph)
	local arriveRadius = options.arriveRadius or TUNING.arriveRadius
	local timeout = options.timeout
		or path.length / math.max(cruise, EPSILON) * TUNING.timeoutFactor + TUNING.timeoutExtra
	local limits: Limits = {
		decel = gToStuds(TUNING.planDecelG),
		lateralAccel = gToStuds(TUNING.lateralG),
		cornerSpan = TUNING.cornerSpan,
		previewMargin = TUNING.previewMargin,
		minSpeed = Units.mphToStuds(TUNING.minMph),
		arriveSpeed = Units.mphToStuds(TUNING.arriveMph),
		arriveRadius = arriveRadius,
	}
	local fallbackLock = math.rad(TUNING.maxSteerDegrees)
	local tuning = tuningOf(run.car)
	local speedState = { integral = 0 }
	local stuck: StuckState = { timer = 0, counted = false }
	local segment, along, steer = 1, 0, 0
	local started = os.clock()

	eachFrame(function(dt: number): boolean
		if run.cancelled then
			report.reason = "stopped"
			return true
		elseif not stillGoing(run) then
			report.reason = "left the car"
			return true
		end
		report.elapsed = os.clock() - started
		local speed = speedOf(run)
		local mph = Units.studsToMph(speed)
		report.maxMph = math.max(report.maxMph, math.abs(mph))

		local position = chassis.Position
		local nextSegment, _, nextAlong = AutoMath.project(path, position, segment, TUNING.projectWindow)
		segment, along = nextSegment, nextAlong
		if AutoMath.arrived(path, along, position, arriveRadius) then
			report.completed = true
			report.reason = "arrived"
			return true
		elseif report.elapsed > timeout then
			report.reason = "timeout"
			return true
		end
		if AutoMath.updateStuck(stuck, mph, dt, TUNING.stuckMph, TUNING.stuckSeconds) then
			report.stuckEvents += 1
		end

		-- Steer toward a point further along the route; further the faster the car goes.
		local nearest =
			math.min(math.max(TUNING.lookaheadMin, wheelbase * TUNING.lookaheadWheelbases), TUNING.lookaheadMax)
		local lookahead =
			math.clamp(TUNING.lookaheadMin + TUNING.lookaheadPerMph * math.abs(mph), nearest, TUNING.lookaheadMax)
		local target = AutoMath.pointAt(path, along + lookahead)
		-- Full steer turns the wheels only as far as the chassis's speed-sensitive lock allows right now.
		local lock = if tuning
			then Chassis.steerLockAt(tuning, run.drive.getMode(), math.abs(speed), Workspace.Gravity)
			else fallbackLock
		local wantSteer, curvature = AutoMath.pursuit(rearAxle(chassis, rearOffset), target, wheelbase, lock)
		steer += (wantSteer - steer) * AutoMath.smoothing(TUNING.steerStiffness, dt)

		-- Speed: cruise, less for corners ahead, for the curve being driven now, and for the finish.
		local allowed = AutoMath.planSpeed(path, along, cruise, limits)
		if math.abs(curvature) > EPSILON then
			local curveSpeed = math.sqrt(limits.lateralAccel / math.abs(curvature))
			allowed = math.min(allowed, math.max(curveSpeed, limits.minSpeed))
		end
		local throttle, brake = AutoMath.speedControl(speedState, Units.studsToMph(allowed), mph, dt, TUNING)
		run.input.setOverride({ throttle = throttle, brake = brake, steer = steer, handbrake = false })
		return false
	end)

	-- Points count as reached once the car is past them along the route (route[1] is the start, not a point).
	for i = 2, #path.points do
		if path.along[i] <= along + arriveRadius or report.completed then
			report.pointsReached += 1
		end
	end
	if report.completed and options.stopAtEnd ~= false and stillGoing(run) then
		waitUntilStopped(run, 0, TUNING.settleTimeout)
	end
	finish(run)
	print(
		`[AutoDriver] drive: {report.reason} in {string.format("%.1f", report.elapsed)} s, `
			.. `{report.pointsReached}/{#points} points, max {string.format("%.1f", report.maxMph)} mph, `
			.. `{report.stuckEvents} stuck`
	)
	return report
end

-- Full throttle from a standstill until 60 mph. Seconds to 60, or nil on timeout or if the run ends early.
local function timeZeroToSixty(run: Run, timeout: number): number?
	local chassis = run.chassis
	local startHeading = AutoMath.headingOf(chassis.CFrame.LookVector, 0)
	local result: number? = nil
	run.input.setOverride({ throttle = 1, brake = 0, steer = 0, handbrake = false })
	-- The clock is the sum of frame times from the first frame simulated at full throttle (the next
	-- PreSimulation applies it, and this Heartbeat callback first runs after that frame's physics), and speed is
	-- read from the chassis after each frame's physics, so neither lags a frame.
	local elapsed, lastElapsed, lastMph = 0, 0, 0

	eachFrame(function(dt: number): boolean
		if not stillGoing(run) then
			return true
		end
		elapsed += dt
		local mph = Units.studsToMph(speedOf(run))
		if mph >= SIXTY_MPH then
			-- Interpolate the moment 60 was crossed between this frame and the last.
			local fraction = if mph > lastMph then (SIXTY_MPH - lastMph) / (mph - lastMph) else 1
			result = lastElapsed + (elapsed - lastElapsed) * fraction
			return true
		elseif elapsed > timeout then
			return true
		end
		lastElapsed, lastMph = elapsed, mph
		-- Hold the starting heading: drifting left (heading grew) steers right.
		local drift = AutoMath.wrapAngle(AutoMath.headingOf(chassis.CFrame.LookVector, startHeading) - startHeading)
		local steer = math.clamp(drift * TUNING.headingHoldGain, -TUNING.headingHoldMax, TUNING.headingHoldMax)
		run.input.setOverride({ throttle = 1, brake = 0, steer = steer, handbrake = false })
		return false
	end)
	return result
end

local function zeroToSixtyHere(opts: { timeout: number? }?): number?
	local timeout = (opts and opts.timeout) or TUNING.zeroToSixtyTimeout
	local run = begin()
	if run == nil then
		return nil
	end
	-- The catalog 0-60 is a Standard-mode figure: run in Standard, then put the player's mode back.
	local previousMode = run.drive.getMode()
	run.drive.setMode("standard")

	local ran = false
	local result: number? = nil
	if waitUntilStopped(run, TUNING.stillSeconds, TUNING.settleTimeout) then
		ran = true
		result = timeZeroToSixty(run, timeout)
		if stillGoing(run) then
			waitUntilStopped(run, 0, TUNING.settleTimeout)
		end
	else
		warn("[AutoDriver] the car would not come to a stop, so no 0-60 run")
	end

	run.drive.setMode(previousMode)
	finish(run)
	if result then
		print(`[AutoDriver] 0-60 mph: {string.format("%.2f", result)} s`)
	elseif ran and not run.cancelled then
		warn(`[AutoDriver] did not reach 60 mph within {timeout} s`)
	end
	return result
end

local function holdStillHere(seconds: number): number?
	if type(seconds) ~= "number" or seconds < 0 then
		warn("[AutoDriver] holdStill needs a number of seconds")
		return nil
	end
	local run = begin()
	if run == nil then
		return nil
	end
	local started = os.clock()
	eachFrame(function(): boolean
		if not stillGoing(run) or os.clock() - started >= seconds then
			return true
		end
		run.input.setOverride(holdControls(Units.studsToMph(speedOf(run))))
		return false
	end)
	local mph = Units.studsToMph(speedOf(run))
	finish(run)
	return mph
end

local function stopHere()
	local run = activeRun
	activeRun = nil
	if run then
		run.cancelled = true
		run.input.setOverride(nil)
	else
		local input: InputApi? = requireController("InputController")
		if input then
			input.setOverride(nil)
		end
	end
end

local COMMANDS: { [string]: (...any) -> ...any } = {
	drive = driveHere,
	zeroToSixty = zeroToSixtyHere,
	holdStill = holdStillHere,
	stop = stopHere,
}

-- The game-side bridge, when this copy is not the one that serves it.
local function bridge(): BindableFunction?
	if isHost then
		return nil
	end
	local found = script:FindFirstChild(BRIDGE_NAME)
	return if found ~= nil and found:IsA("BindableFunction") then found else nil
end

local function inStudio(): boolean
	if RunService:IsStudio() then
		return true
	end
	warn("[AutoDriver] runs only in Studio")
	return false
end

-- Runs `command` here, or in the game's copy when a bridge is up.
local function dispatch(command: string, ...: any): ...any
	local found = bridge()
	if found then
		return found:Invoke(command, ...)
	end
	return COMMANDS[command](...)
end

-- Called once by the game's own client scripts (CameraController, Studio only) so calls from MCP reach the
-- controllers that actually drive the car.
function AutoDriver.serve()
	if not RunService:IsStudio() or isHost then
		return
	end
	local old = script:FindFirstChild(BRIDGE_NAME)
	if old then
		old:Destroy()
	end
	local fn = Instance.new("BindableFunction")
	fn.Name = BRIDGE_NAME
	fn.OnInvoke = function(command: string, ...: any): ...any
		local handler = COMMANDS[command]
		if handler == nil then
			error(`AutoDriver: unknown command "{command}"`)
		end
		return handler(...)
	end
	fn.Parent = script
	isHost = true
end

function AutoDriver.drive(points: { Vector3 }, opts: DriveOptions?): Report
	if not inStudio() then
		return { completed = false, elapsed = 0, stuckEvents = 0, maxMph = 0, reason = "studio only", pointsReached = 0 }
	end
	return dispatch("drive", points, opts)
end

function AutoDriver.zeroToSixty(opts: { timeout: number? }?): number?
	if not inStudio() then
		return nil
	end
	return dispatch("zeroToSixty", opts)
end

function AutoDriver.holdStill(seconds: number): number?
	if not inStudio() then
		return nil
	end
	return dispatch("holdStill", seconds)
end

function AutoDriver.stop()
	if not inStudio() then
		return
	end
	dispatch("stop")
end

return AutoDriver
