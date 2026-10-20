--!strict
-- Studio-only drive-to-earn tests (PLAN.md Phase 3 acceptance: "AutoDriver drives 2 minutes -> payout lands in the
-- §4 band. Parked 3 minutes -> no payout. 2 minutes of circles in a lot -> no payout."). Each test drives the car
-- the local player sits in with Dev/AutoDriver and measures what Services/DriveEarnService actually paid:
--   drive(seconds, opts)    drives back and forth between two far-apart GPS destinations on the county roads
--                           (Road/Pathfind routes, right-hand lanes) at about 40 mph on average
--   park(seconds, opts)     brakes and holds the car still
--   circle(seconds, opts)   drives tight, slow circles (about SETTINGS.circleRadius studs) in the used lot, off
--                           the road, so the off-road and AFK rules stop the payout; opts.spot = "road" circles
--                           inside the intersection nearest the used lot instead, at SETTINGS.roadCircleRadius:
--                           on the road and wider than the AFK distance, so the loop-farming rule stops it
--   (drive at the default 45 mph checks the reference rate; drive(120, { cruiseMph = 70 }) shows what highway
--   drivers get, the per-minute cap)
--   start(name, seconds, opts)  runs "drive", "park" or "circle" in the background and returns at once;
--                           lastResult() returns its result once done (nil while it runs), status() what it's doing
--   stop()                  cancels a run and hands the controls back
-- Each returns { name, seconds, earned, perMinute } plus the cash before and after (the player's Cash attribute),
-- each payout decision the server made (amount, reason, distance, box size) and why the run ended.
--
-- Lining up with the pay intervals: DriveEarnService pays every Config/DriveEarn.payInterval of driving, counted
-- from when the player sat down, so a test window that starts at an arbitrary moment would catch a payout for
-- driving done before it. In Studio the service bumps the player attribute DriveEarnTick after every decision and
-- puts the decision in DriveEarnLast. A test starts its behaviour, lets `warmup` decisions go by (drive: 1, so
-- the first measured minute is all test driving; park and circle: enough to fill the AFK and loop windows), reads
-- the cash, then measures whole pay intervals: ceil(seconds / payInterval) of them. So drive(120) measures two
-- full minutes after up to one minute of warm-up; park(180) and circle(120) warm up for two minutes first.
--
-- Run from MCP execute_luau in the Client datamodel of a playtest, once the player sits in a car's Driver seat
-- (like Dev/AutoDriver and Dev/RouteTests). Runs take minutes, longer than an execute_luau call waits, so start
-- them in the background and read the result later:
--   require(game.Players.LocalPlayer.PlayerScripts.Client.Dev.EarnTests).start("drive", 120)
--   require(game.Players.LocalPlayer.PlayerScripts.Client.Dev.EarnTests).lastResult()
--
-- Driving goes through AutoDriver's Bridge (see its header), so calls from MCP's copy of this module drive the
-- game's controllers. State that every copy must see (running, cancel, the last result) lives in attributes on
-- this ModuleScript, as in Dev/RouteTests.
--
-- Does nothing outside Studio (CLAUDE.md hard rule 8). The client loader never boots it.

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage.Shared
local AutoDriver = require(script.Parent.AutoDriver)
local DriveEarn = require(Shared.Config.DriveEarn)
local Economy = require(Shared.Config.Economy)
local Graph = require(Shared.Road.Graph)
local MapLayout = require(Shared.Config.MapLayout)
local Pathfind = require(Shared.Road.Pathfind)
local RouteTests = require(script.Parent.RouteTests)
local World = require(Shared.Config.World)

export type TestName = "drive" | "park" | "circle"

export type Options = {
	cruiseMph: number?, -- drive(): cruise speed (default SETTINGS.cruiseMph)
	warmup: number?, -- pay decisions to let go by before measuring (default per test, see the header)
	spot: ("lot" | "road")?, -- circle(): where to circle (default "lot")
	radius: number?, -- circle(): circle radius in studs (default SETTINGS.circleRadius, or roadCircleRadius on a road)
}

-- One payout decision, as DriveEarnService published it (Studio only).
export type Payout = {
	amount: number,
	reason: string, -- "paid", "afk", "loop" or "noRoad"
	distance: number,
	boundingBox: number,
	moved: number,
	capped: boolean,
	multiplier: number,
}

export type Result = {
	name: string,
	seconds: number, -- measured seconds (whole pay intervals)
	earned: number, -- cash after - cash before
	perMinute: number, -- earned per minute measured
	cashBefore: number,
	cashAfter: number,
	payouts: { Payout },
	completed: boolean, -- measured every interval it meant to
	reason: string, -- "done", or why it ended early
}

-- A dev tool, so its numbers live here rather than in Shared/Config (like Dev/RouteTests' SETTINGS).
local SETTINGS = {
	-- drive(): cruise speed. AutoDriver slows for corners and junctions, so a 45 mph cruise averages about the
	-- 40 mph Config/DriveEarn is calibrated on.
	cruiseMph = 45,
	-- drive(): GPS destinations in these zones (paved roads only; the Mesa's trails are dirt); the two farthest
	-- apart are the ends of the route.
	driveZones = { "cedar_bend", "riverside", "the_plant", "lakefront" },
	-- circle(): radius (studs) and speed. The radius is above the Spark's tightest turn at this speed.
	circleRadius = 18,
	-- circle() with spot = "road": the streets' on-road reach at an intersection is about 19 studs from each
	-- centre line, so a 24-stud circle stays on the road (its 45° points are 17 studs from both), while it gets
	-- about 48 studs from where it started: past the 40-stud AFK distance, well inside the 250-stud loop box.
	roadCircleRadius = 24,
	circleMph = 10,
	circleLapPoints = 16, -- points per lap
	circleLapsPerDrive = 6, -- laps per AutoDriver.drive call (it slows a little at the end of each call)
	townMph = 25, -- circle(): getting to the spot
	usedLotId = "used_lot", -- MapLayout location the circles are next to
	minIntersectionEdges = 3, -- spot = "road": a node with at least this many roads is an intersection
	parkChunkSeconds = 30, -- park(): AutoDriver.holdStill calls this long, until the test ends
	settleSeconds = 3, -- after a test: brake and hold this long so the car ends stopped
	tickSlackSeconds = 15, -- a pay decision more than payInterval + this late means the service isn't running
	maxMiter = 2, -- right-hand lane offset at corners (as Dev/RouteTests)
}

local STATUS = "Status" -- attribute: "idle", "running", "done", "stopped" or "failed"
local CURRENT = "Current" -- attribute: what the running test is doing now
local RESULT = "Result" -- attribute: the last result, as JSON
local CANCEL = "Cancel" -- attribute: true asks a running test to stop
local RUN_ID = "RunId" -- attribute: the id of the newest test
local EPSILON = 1e-6
local TWO_PI = 2 * math.pi

type Context = {
	id: string,
	name: TestName,
	options: Options,
	done: boolean, -- the measurement is over: the behaviour should stop
	ready: boolean, -- the behaviour is in place (the car is at the circle, ...)
	readyEvent: BindableEvent,
	failure: string?, -- why the behaviour couldn't run
}

---------------------------------------------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------------------------------------------

local function flat(v: Vector3): Vector3
	return Vector3.new(v.X, 0, v.Z)
end

local function cancelRequested(ctx: Context): boolean
	return ctx.done or script:GetAttribute(CANCEL) == true or script:GetAttribute(RUN_ID) ~= ctx.id
end

-- The pose of the car the local player drives (its chassis), or nil when they aren't in a Driver seat.
local function carPose(): CFrame?
	local player = Players.LocalPlayer
	local character = if player then player.Character else nil
	local humanoid = if character then character:FindFirstChildOfClass("Humanoid") else nil
	local seat = if humanoid then humanoid.SeatPart else nil
	if seat == nil or seat.Name ~= "Driver" then
		return nil
	end
	local node: Instance? = seat.Parent
	while node do
		if node:IsA("Model") and node:GetAttribute("VehicleId") ~= nil then
			local chassis = (node :: Model).PrimaryPart
			return if chassis then chassis.CFrame else seat.CFrame
		end
		node = node.Parent
	end
	return seat.CFrame
end

local function cash(): number
	local value = Players.LocalPlayer:GetAttribute(Economy.cashAttribute)
	return if type(value) == "number" then value else 0
end

local function lastPayout(): Payout?
	local encoded = Players.LocalPlayer:GetAttribute(DriveEarn.debugDecisionAttribute)
	if type(encoded) ~= "string" then
		return nil
	end
	local ok, decoded = pcall(HttpService.JSONDecode, HttpService, encoded)
	return if ok then decoded else nil
end

-- Waits for the next pay decision (DriveEarnTick changing). True when it came, false on timeout, cancel or the
-- behaviour failing.
local function waitForTick(ctx: Context): boolean
	if cancelRequested(ctx) then
		return false
	end
	local thread = coroutine.running()
	local settled = false
	local connections: { RBXScriptConnection } = {}
	local timer: thread? = nil
	local function finish(result: boolean)
		if settled then
			return
		end
		settled = true
		for _, connection in connections do
			connection:Disconnect()
		end
		if timer ~= nil and coroutine.running() ~= timer then
			task.cancel(timer)
		end
		task.spawn(thread, result)
	end
	table.insert(
		connections,
		Players.LocalPlayer:GetAttributeChangedSignal(DriveEarn.debugTickAttribute):Connect(function()
			finish(true)
		end)
	)
	table.insert(
		connections,
		script:GetAttributeChangedSignal(CANCEL):Connect(function()
			if cancelRequested(ctx) then
				finish(false)
			end
		end)
	)
	-- The behaviour fires readyEvent again when it ends; ending early (left the car...) ends the wait too.
	table.insert(
		connections,
		ctx.readyEvent.Event:Connect(function()
			if ctx.failure ~= nil then
				finish(false)
			end
		end)
	)
	timer = task.delay(DriveEarn.payInterval + SETTINGS.tickSlackSeconds, finish, false)
	return coroutine.yield()
end

local function setCurrent(ctx: Context, text: string)
	if script:GetAttribute(RUN_ID) == ctx.id then
		script:SetAttribute(CURRENT, text)
	end
end

local function markReady(ctx: Context)
	if not ctx.ready then
		ctx.ready = true
		ctx.readyEvent:Fire()
	end
end

-- Right-hand lane offset for the stretch a-b, from the lanes of the road under its middle (as Dev/RouteTests).
local function laneOffsetFor(a: Vector3, b: Vector3): number
	local edgeIndex = Graph.nearestEdge((a + b) / 2)
	local edge = if edgeIndex then Graph.edges()[edgeIndex] else nil
	return if edge then RouteTests.Math.rightLaneOffset(edge.lanes, World.laneWidth) else 0
end

-- Drives Pathfind's route from the car to `to` (plus `extra` points after it) at `mph`, in the right-hand lanes.
-- Returns AutoDriver's reason ("arrived", "timeout", "stopped", ...) or "no route" / "not driving".
local function driveTo(to: Vector3, mph: number, extra: { Vector3 }?): string
	local pose = carPose()
	if pose == nil then
		return "not driving"
	end
	local route = Pathfind.route(pose.Position, to, pose.LookVector)
	if route == nil then
		return "no route"
	end
	local points = RouteTests.Math.keepRight(route.points, laneOffsetFor, SETTINGS.maxMiter)
	if extra then
		table.move(extra, 1, #extra, #points + 1, points)
	end
	if #points == 0 then
		return "arrived"
	end
	local length = RouteTests.Math.length(pose.Position, points)
	local report = AutoDriver.drive(points, {
		targetMph = mph,
		timeout = RouteTests.Math.timeoutFor(length, mph),
		stopAtEnd = false,
	})
	return report.reason
end

---------------------------------------------------------------------------------------------------------------
-- Behaviours: each runs until the measurement is over (ctx.done) or it is cancelled, and marks itself ready
-- once it is doing the thing being measured.
---------------------------------------------------------------------------------------------------------------

-- The two GPS destinations (in SETTINGS.driveZones) farthest apart.
local function routeEnds(): (Vector3?, Vector3?)
	local candidates: { Vector3 } = {}
	for _, location in MapLayout.locations do
		if location.gps and table.find(SETTINGS.driveZones, location.zone) ~= nil then
			table.insert(candidates, location.position)
		end
	end
	local bestA: Vector3?, bestB: Vector3? = nil, nil
	local best = -1
	for i = 1, #candidates do
		for j = i + 1, #candidates do
			local distance = (flat(candidates[i]) - flat(candidates[j])).Magnitude
			if distance > best then
				best, bestA, bestB = distance, candidates[i], candidates[j]
			end
		end
	end
	return bestA, bestB
end

local function driveBehaviour(ctx: Context)
	local a, b = routeEnds()
	if a == nil or b == nil then
		ctx.failure = "no two GPS destinations to drive between"
		return
	end
	local here = carPose()
	if here == nil then
		ctx.failure = "not driving"
		return
	end
	-- Head for the farther end first, then back and forth.
	local target: Vector3 = if (flat(a) - flat(here.Position)).Magnitude
			> (flat(b) - flat(here.Position)).Magnitude
		then a
		else b
	local cruise = ctx.options.cruiseMph or SETTINGS.cruiseMph
	markReady(ctx)
	while not cancelRequested(ctx) do
		setCurrent(ctx, "driving")
		local reason = driveTo(target, cruise)
		if reason == "not driving" or reason == "left the car" or reason == "no route" then
			ctx.failure = reason
			return
		end
		target = if target == a then b else a
		task.wait() -- never spin: a leg that ends at once still yields a frame
	end
end

local function parkBehaviour(ctx: Context)
	setCurrent(ctx, "parked")
	markReady(ctx)
	while not cancelRequested(ctx) do
		if AutoDriver.holdStill(SETTINGS.parkChunkSeconds) == nil then
			ctx.failure = "not driving"
			return
		end
	end
end

-- Where to circle: the middle of the used lot (off the road), or the intersection nearest it (on the road).
local function circleCentre(spot: "lot" | "road"): Vector3?
	local lot: Vector3? = nil
	for _, location in MapLayout.locations do
		if location.id == SETTINGS.usedLotId then
			lot = location.position
		end
	end
	if lot == nil then
		return nil
	end
	if spot == "lot" then
		return lot
	end
	local best: Vector3? = nil
	local bestDistance = math.huge
	for _, node in Graph.nodes() do
		if #Graph.neighbors(node.id) >= SETTINGS.minIntersectionEdges then
			local distance = (flat(node.position) - flat(lot)).Magnitude
			if distance < bestDistance then
				best, bestDistance = node.position, distance
			end
		end
	end
	return best
end

-- `laps` laps of a circle round `centre` (clockwise seen from above), starting at `startAngle`.
local function circlePoints(centre: Vector3, radius: number, startAngle: number, laps: number): { Vector3 }
	local points: { Vector3 } = {}
	local count = SETTINGS.circleLapPoints * laps
	for index = 1, count do
		local angle = startAngle + TWO_PI * index / SETTINGS.circleLapPoints
		table.insert(points, centre + Vector3.new(radius * math.cos(angle), 0, radius * math.sin(angle)))
	end
	return points
end

local function circleBehaviour(ctx: Context)
	local spot = ctx.options.spot or "lot"
	local radius = ctx.options.radius or (if spot == "road" then SETTINGS.roadCircleRadius else SETTINGS.circleRadius)
	local centre = circleCentre(spot)
	if centre == nil then
		ctx.failure = "no used lot in MapLayout"
		return
	end
	-- Get there by road, then onto the circle at the point nearest the road.
	local _, _, _, roadPoint = Graph.nearestEdge(centre)
	local toRoad = flat(roadPoint - centre)
	local entryAngle = if toRoad.Magnitude > EPSILON then math.atan2(toRoad.Z, toRoad.X) else 0
	local entry = centre + Vector3.new(radius * math.cos(entryAngle), 0, radius * math.sin(entryAngle))
	setCurrent(ctx, "driving to the circle")
	local reason = driveTo(centre, SETTINGS.townMph, { entry })
	if reason == "not driving" or reason == "left the car" or reason == "no route" or reason == "stopped" then
		ctx.failure = if cancelRequested(ctx) then nil else reason
		return
	end
	setCurrent(ctx, `circling ({spot})`)
	markReady(ctx)
	while not cancelRequested(ctx) do
		local pose = carPose()
		if pose == nil then
			ctx.failure = "not driving"
			return
		end
		local offset = flat(pose.Position - centre)
		local angle = if offset.Magnitude > EPSILON then math.atan2(offset.Z, offset.X) else entryAngle
		local points = circlePoints(centre, radius, angle, SETTINGS.circleLapsPerDrive)
		local report = AutoDriver.drive(points, { targetMph = SETTINGS.circleMph, stopAtEnd = false })
		if report.reason == "not driving" or report.reason == "left the car" then
			ctx.failure = report.reason
			return
		end
		task.wait() -- never spin: a drive that ends at once still yields a frame
	end
end

local BEHAVIOURS: { [TestName]: (ctx: Context) -> () } = {
	drive = driveBehaviour,
	park = parkBehaviour,
	circle = circleBehaviour,
}

-- Pay decisions to let go by before measuring: drive needs only to line up with a pay interval; park and circle
-- also fill the AFK and loop windows with nothing but the behaviour.
local function defaultWarmup(name: TestName): number
	if name == "drive" then
		return 1
	end
	return math.ceil(math.max(DriveEarn.afkWindow, DriveEarn.loopWindow) / DriveEarn.payInterval)
end

---------------------------------------------------------------------------------------------------------------
-- Running a test
---------------------------------------------------------------------------------------------------------------

local function emptyResult(name: string, reason: string): Result
	return {
		name = name,
		seconds = 0,
		earned = 0,
		perMinute = 0,
		cashBefore = 0,
		cashAfter = 0,
		payouts = {},
		completed = false,
		reason = reason,
	}
end

local function measure(ctx: Context, seconds: number): Result
	local name = ctx.name
	-- Wait for the behaviour to be in place (or to fail trying).
	if not ctx.ready and ctx.failure == nil then
		ctx.readyEvent.Event:Wait()
	end
	if ctx.failure ~= nil or cancelRequested(ctx) then
		return emptyResult(name, ctx.failure or "stopped")
	end

	local warmup = ctx.options.warmup or defaultWarmup(name)
	for index = 1, warmup do
		setCurrent(ctx, `{name}: warming up ({index}/{warmup})`)
		if not waitForTick(ctx) then
			return emptyResult(name, ctx.failure or (if cancelRequested(ctx) then "stopped" else "no pay decision"))
		end
	end

	local intervals = math.max(1, math.ceil(seconds / DriveEarn.payInterval - EPSILON))
	local result = emptyResult(name, "done")
	result.cashBefore = cash()
	local started = os.clock()
	for index = 1, intervals do
		setCurrent(ctx, `{name}: measuring ({index}/{intervals})`)
		if not waitForTick(ctx) then
			result.reason = ctx.failure or (if cancelRequested(ctx) then "stopped" else "no pay decision")
			break
		end
		local payout = lastPayout()
		if payout then
			table.insert(result.payouts, payout)
		end
	end
	result.completed = #result.payouts == intervals and result.reason == "done"
	result.cashAfter = cash()
	result.seconds = os.clock() - started
	result.earned = result.cashAfter - result.cashBefore
	result.perMinute = if result.seconds > EPSILON then result.earned * 60 / result.seconds else 0
	return result
end

local function runTest(name: TestName, seconds: number, opts: Options?): Result
	if not (RunService:IsStudio() and RunService:IsRunning()) then
		warn("[EarnTests] runs only in a Studio playtest (Client datamodel)")
		return emptyResult(name, "studio only")
	end
	if type(seconds) ~= "number" or seconds <= 0 then
		warn("[EarnTests] give the number of seconds to measure")
		return emptyResult(name, "bad seconds")
	end
	if script:GetAttribute(STATUS) == "running" then
		warn("[EarnTests] a test is already running; EarnTests.stop() cancels it")
		return emptyResult(name, "busy")
	end
	if carPose() == nil then
		warn("[EarnTests] sit in a car's Driver seat first (and run this in the Client datamodel)")
		return emptyResult(name, "not driving")
	end

	local ctx: Context = {
		id = HttpService:GenerateGUID(false),
		name = name,
		options = opts or {},
		done = false,
		ready = false,
		readyEvent = Instance.new("BindableEvent"),
		failure = nil,
	}
	script:SetAttribute(RUN_ID, ctx.id)
	script:SetAttribute(STATUS, "running")
	script:SetAttribute(CANCEL, false)
	script:SetAttribute(RESULT, nil)

	-- The behaviour runs alongside the measurement; when it ends early it says why and wakes the measurement.
	local behaviourDone = Instance.new("BindableEvent")
	local behaviourRunning = true
	task.spawn(function()
		local ok, err = pcall(BEHAVIOURS[name], ctx)
		if not ok then
			ctx.failure = `error: {tostring(err)}`
			warn(`[EarnTests] {name} failed: {err}`)
		end
		if not ctx.ready and ctx.failure == nil then
			ctx.failure = "stopped"
		end
		behaviourRunning = false
		ctx.readyEvent:Fire()
		behaviourDone:Fire()
	end)

	local ok, measured = pcall(measure, ctx, seconds)
	local result: Result = if ok then measured else emptyResult(name, `error: {tostring(measured)}`)

	-- Stop the behaviour, then bring the car to a stop.
	ctx.done = true
	AutoDriver.stop()
	if behaviourRunning then
		behaviourDone.Event:Wait()
	end
	AutoDriver.holdStill(SETTINGS.settleSeconds)
	ctx.readyEvent:Destroy()
	behaviourDone:Destroy()

	print(
		`[EarnTests] {name}: earned ${result.earned} over {string.format("%.0f", result.seconds)} s `
			.. `({string.format("%.0f", result.perMinute)}/min), {#result.payouts} payout decision(s), {result.reason}`
	)
	for index, payout in result.payouts do
		print(
			`[EarnTests]   minute {index}: ${payout.amount} ({payout.reason}), {payout.distance} studs on roads, `
				.. `box {payout.boundingBox} studs, moved {payout.moved} studs`
		)
	end
	if script:GetAttribute(RUN_ID) == ctx.id then
		local status = if not ok or ctx.failure ~= nil
			then "failed"
			elseif result.reason == "stopped" then "stopped"
			else "done"
		script:SetAttribute(RESULT, HttpService:JSONEncode(result))
		script:SetAttribute(CURRENT, nil)
		script:SetAttribute(STATUS, status)
	end
	return result
end

local EarnTests = {}
EarnTests.SETTINGS = SETTINGS

function EarnTests.drive(seconds: number, opts: Options?): Result
	return runTest("drive", seconds, opts)
end

function EarnTests.park(seconds: number, opts: Options?): Result
	return runTest("park", seconds, opts)
end

function EarnTests.circle(seconds: number, opts: Options?): Result
	return runTest("circle", seconds, opts)
end

-- Starts a test in the background and returns at once. Poll lastResult() (nil until it finishes) or watch the
-- console.
function EarnTests.start(name: TestName, seconds: number, opts: Options?)
	if BEHAVIOURS[name] == nil then
		warn(`[EarnTests] unknown test "{name}"; use "drive", "park" or "circle"`)
		return
	end
	task.spawn(runTest, name, seconds, opts)
end

-- The last finished result, or nil while a test runs (or before any has finished).
function EarnTests.lastResult(): Result?
	local encoded = script:GetAttribute(RESULT)
	if script:GetAttribute(STATUS) == "running" or type(encoded) ~= "string" then
		return nil
	end
	return HttpService:JSONDecode(encoded)
end

-- "idle", "running", "done", "stopped" or "failed", and what the running test is doing.
function EarnTests.status(): (string, string?)
	local status = script:GetAttribute(STATUS)
	local current = script:GetAttribute(CURRENT)
	return if type(status) == "string" then status else "idle", if type(current) == "string" then current else nil
end

-- Cancels a running test and hands the controls back; clears a "running" status left by a test whose thread died.
function EarnTests.stop()
	if not RunService:IsStudio() then
		return
	end
	script:SetAttribute(CANCEL, true)
	AutoDriver.stop()
	if script:GetAttribute(STATUS) == "running" then
		script:SetAttribute(STATUS, "stopped")
	end
end

return EarnTests
