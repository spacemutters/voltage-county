--!strict
-- Studio-only route driving tests (PLAN.md Phase 2 acceptance: "AutoDriver completes the full County Loop and
-- one route into each zone with zero 'stuck > 3 s' events"). Each test drives the car the local player sits in
-- with Dev/AutoDriver:
--   countyLoop(opts)   drives to the nearest County Loop node, then once round the whole loop
--                      (RoadGraph.loopNodeIds, closed) at about 55 mph, in whichever direction the car faces
--   zones(opts)        for each zone in MapLayout.zoneOrder, drives from the player spawn to one GPS destination
--                      in that zone (the first one a real drive away) at about 30 mph, driving back to the spawn
--                      between zones
--   all(opts)          zones, then the loop
--   start(name, opts)  runs "countyLoop", "zones" or "all" in the background and returns at once;
--                      lastResult() returns its result once done (nil while it runs), status() what it's doing
--   stop()             cancels a run and hands the controls back
-- Each run reports { name, completed, stuckEvents, elapsed, maxMph } (plus why it ended, its length and its
-- timeout), and each call returns { runs, total }. Runs and totals are printed as they finish, so
-- get_console_output shows them even if the execute_luau call stops waiting first.
--
-- Run from MCP execute_luau in the Client datamodel of a playtest, once the player sits in a car's Driver seat
-- (like Dev/AutoDriver):
--   require(game.Players.LocalPlayer.PlayerScripts.Client.Dev.RouteTests).zones()
-- The loop alone takes several minutes, which may be longer than an execute_luau call waits, so for the full
-- set start it in the background and read the result later:
--   require(game.Players.LocalPlayer.PlayerScripts.Client.Dev.RouteTests).start("all")
--   require(game.Players.LocalPlayer.PlayerScripts.Client.Dev.RouteTests).lastResult()
--
-- Driving goes through AutoDriver.drive, which forwards a call made from MCP's copy of the module to the game's
-- own copy over AutoDriver's Bridge (see its header). Routes come from Road/Pathfind on the shared road graph,
-- so streaming never hides a road, and are shifted into the right-hand lanes so the car never drives down a
-- median. State that every copy of this module must see (running, cancel, the last result) lives in attributes
-- on this ModuleScript.
--
-- Does nothing outside Studio (CLAUDE.md hard rule 8). The client loader never boots it.

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage.Shared
local AutoDriver = require(script.Parent.AutoDriver)
local Graph = require(Shared.Road.Graph)
local MapLayout = require(Shared.Config.MapLayout)
local Pathfind = require(Shared.Road.Pathfind)
local RoadGraph = require(Shared.Config.RoadGraph)
local Units = require(Shared.Util.Units)
local World = require(Shared.Config.World)

export type Options = {
	loopMph: number?, -- cruise on the County Loop (default SETTINGS.loopMph)
	townMph: number?, -- cruise everywhere else: to the loop, into zones, back to the spawn (default SETTINGS.townMph)
	keepRight: boolean?, -- drive in the right-hand lanes (default true); false follows the centre line
	zones: { string }?, -- zones() and all(): only these zone ids, instead of every zone in MapLayout.zoneOrder
	chain: boolean?, -- zones() and all(): drive on from each destination to the next instead of from the spawn
}

export type Run = {
	name: string,
	completed: boolean,
	stuckEvents: number,
	elapsed: number, -- seconds
	maxMph: number,
	reason: string, -- AutoDriver's reason ("arrived", "timeout", ...) or why the run couldn't start
	length: number, -- studs of route, from where the car started
	timeout: number, -- seconds allowed
}

export type Total = {
	runs: number,
	completed: number,
	stuckEvents: number,
	elapsed: number,
	maxMph: number,
	passed: boolean, -- every run completed with no stuck events
}

export type Result = { runs: { Run }, total: Total }

type TestName = "countyLoop" | "zones" | "all"

-- A dev tool, so its numbers live here rather than in Shared/Config (like Dev/AutoDriver's TUNING).
local SETTINGS = {
	loopMph = 55, -- County Loop cruise (its limit is 70; leaves margin for the corners)
	townMph = 30, -- cruise on avenues and streets
	timeoutSpeedFraction = 0.6, -- a run's timeout: its length at this fraction of the cruise speed...
	timeoutExtraSeconds = 30, -- ...plus this many seconds
	atSpawnRadius = 80, -- studs: the car counts as at the spawn this close to the road point nearest it
	atNodeRadius = 40, -- studs: close enough to a loop node to start the lap without driving to it first
	minTripStuds = 300, -- a zone's destination is the first GPS one at least this far from the spawn
	maxMiter = 2, -- at a corner the lane offset grows by 1 / cos(half the turn), up to this many times
}

local EPSILON = 1e-6
local STATUS = "Status" -- attribute: "idle", "running", "done", "stopped" or "failed"
local CURRENT = "Current" -- attribute: the run being driven now
local RESULT = "Result" -- attribute: the last result, as JSON
local CANCEL = "Cancel" -- attribute: true asks a running test to stop after the current run
local RUN_ID = "RunId" -- attribute: the id of the newest test

---------------------------------------------------------------------------------------------------------------
-- Route math (pure). Exposed as RouteTests.Math so a spec can check it.
---------------------------------------------------------------------------------------------------------------

local RouteMath = {}

local function flat(v: Vector3): Vector3
	return Vector3.new(v.X, 0, v.Z)
end

-- Distance from a road's centre line to the middle of the lanes heading one way (studs). A road with an odd
-- number of lanes shares its middle lane; a one-lane road has no sides to keep to.
function RouteMath.rightLaneOffset(lanes: number, laneWidth: number): number
	local eachWay = math.floor(lanes / 2)
	if eachWay < 1 then
		return 0
	end
	return (lanes - eachWay) * laneWidth / 2
end

-- Moves each point of a route sideways to the right of the direction of travel, by `offsetFor(a, b)` studs for
-- the stretch from a to b. Corners take the bisector between the stretches either side, stretched (mitred) so
-- the shifted route stays parallel to the original, up to `maxMiter`.
function RouteMath.keepRight(
	points: { Vector3 },
	offsetFor: (a: Vector3, b: Vector3) -> number,
	maxMiter: number
): { Vector3 }
	local count = #points
	if count < 2 then
		return table.clone(points)
	end
	local directions: { Vector3? } = {}
	local offsets: { number } = {}
	for i = 1, count - 1 do
		local step = flat(points[i + 1] - points[i])
		directions[i] = if step.Magnitude > EPSILON then step.Unit else nil
		offsets[i] = offsetFor(points[i], points[i + 1])
	end

	local shifted: { Vector3 } = {}
	for i, point in points do
		local before: Vector3? = if i > 1 then directions[i - 1] else nil
		local after: Vector3? = if i < count then directions[i] else nil
		local offset = if i == 1
			then offsets[1]
			elseif i == count then offsets[count - 1]
			else (offsets[i - 1] + offsets[i]) / 2
		local heading: Vector3? = nil
		local miter = 1
		if before and after then
			local sum = before + after
			if sum.Magnitude > EPSILON then
				local bisector = sum.Unit
				heading = bisector
				-- cos(half the turn) = bisector . after; dividing by it keeps both shifted stretches parallel.
				miter = math.min(1 / math.max(bisector:Dot(after), EPSILON), maxMiter)
			else
				heading = after -- a U-turn: shift as for the way out
			end
		else
			heading = before or after
		end
		if heading then
			local right = Vector3.new(-heading.Z, 0, heading.X)
			shifted[i] = point + right * offset * miter
		else
			shifted[i] = point
		end
	end
	return shifted
end

-- Length of a route on the ground, starting from `from`.
function RouteMath.length(from: Vector3, points: { Vector3 }): number
	local length, last = 0, flat(from)
	for _, point in points do
		local here = flat(point)
		length += (here - last).Magnitude
		last = here
	end
	return length
end

-- Seconds allowed for `length` studs at `targetMph`: the length at a fraction of the cruise speed, plus extra.
function RouteMath.timeoutFor(length: number, targetMph: number): number
	local speed = SETTINGS.timeoutSpeedFraction * Units.mphToStuds(targetMph)
	return length / math.max(speed, EPSILON) + SETTINGS.timeoutExtraSeconds
end

-- The loop's node indices for one lap from `startIndex` in `direction` (1 or -1): the next node first and the
-- start node last, so the lap is closed.
function RouteMath.lapOrder(count: number, startIndex: number, direction: number): { number }
	local order: { number } = {}
	for step = 1, count do
		table.insert(order, (startIndex - 1 + direction * step) % count + 1)
	end
	return order
end

function RouteMath.totalOf(runs: { Run }): Total
	local total: Total = { runs = #runs, completed = 0, stuckEvents = 0, elapsed = 0, maxMph = 0, passed = #runs > 0 }
	for _, run in runs do
		if run.completed then
			total.completed += 1
		else
			total.passed = false
		end
		total.stuckEvents += run.stuckEvents
		total.elapsed += run.elapsed
		total.maxMph = math.max(total.maxMph, run.maxMph)
	end
	if total.stuckEvents > 0 then
		total.passed = false
	end
	return total
end

---------------------------------------------------------------------------------------------------------------
-- Driving
---------------------------------------------------------------------------------------------------------------

type Context = { id: string, runs: { Run }, options: Options }

-- True once stop() was called, or a newer test has taken over (only the newest test may keep driving).
local function cancelRequested(ctx: Context): boolean
	return script:GetAttribute(CANCEL) == true or script:GetAttribute(RUN_ID) ~= ctx.id
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
	-- The car is the model above the seat that carries a VehicleId (the vehicle model contract).
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

local function carPosition(): Vector3?
	local pose = carPose()
	return if pose then pose.Position else nil
end

-- Right-hand lane offset for the stretch a-b, from the lanes of the road edge under its middle.
local function laneOffsetFor(a: Vector3, b: Vector3): number
	local edgeIndex = Graph.nearestEdge((a + b) / 2)
	if edgeIndex == nil then
		return 0
	end
	local edge = Graph.edges()[edgeIndex]
	return if edge then RouteMath.rightLaneOffset(edge.lanes, World.laneWidth) else 0
end

local function record(ctx: Context, run: Run)
	table.insert(ctx.runs, run)
	print(
		`[RouteTests] {run.name}: {run.reason} in {string.format("%.1f", run.elapsed)} s over `
			.. `{string.format("%.0f", run.length)} studs, max {string.format("%.1f", run.maxMph)} mph, `
			.. `{run.stuckEvents} stuck`
	)
end

-- A run that couldn't start (no route, no destination...): recorded as failed.
local function failRun(ctx: Context, name: string, reason: string)
	record(ctx, {
		name = name,
		completed = false,
		stuckEvents = 0,
		elapsed = 0,
		maxMph = 0,
		reason = reason,
		length = 0,
		timeout = 0,
	})
end

-- Drives `points` with AutoDriver at `targetMph` and records the run. True if the car got to the end.
local function driveRun(ctx: Context, name: string, points: { Vector3 }, targetMph: number): boolean
	if cancelRequested(ctx) then
		return false
	end
	local from = carPosition()
	if from == nil then
		failRun(ctx, name, "not driving")
		return false
	end
	local path = if ctx.options.keepRight == false
		then points
		else RouteMath.keepRight(points, laneOffsetFor, SETTINGS.maxMiter)
	local length = RouteMath.length(from, path)
	local timeout = RouteMath.timeoutFor(length, targetMph)
	script:SetAttribute(CURRENT, name)
	local report = AutoDriver.drive(path, { targetMph = targetMph, timeout = timeout })
	record(ctx, {
		name = name,
		completed = report.completed,
		stuckEvents = report.stuckEvents,
		elapsed = report.elapsed,
		maxMph = report.maxMph,
		reason = report.reason,
		length = length,
		timeout = timeout,
	})
	return report.completed
end

-- Drives along Pathfind's route from the car to `to`. True if the car got there (or already was).
local function driveTo(ctx: Context, name: string, to: Vector3, targetMph: number): boolean
	local pose = carPose()
	if pose == nil then
		failRun(ctx, name, "not driving")
		return false
	end
	-- Start the way the car faces: AutoDriver only drives forward, so a U-turn on a street would hit the kerb.
	local route = Pathfind.route(pose.Position, to, pose.LookVector)
	if route == nil then
		failRun(ctx, name, "no route")
		return false
	end
	if #route.points == 0 then
		return true -- already there
	end
	return driveRun(ctx, name, route.points, targetMph)
end

local function driveCountyLoop(ctx: Context)
	local loopMph = ctx.options.loopMph or SETTINGS.loopMph
	local townMph = ctx.options.townMph or SETTINGS.townMph
	local ids = RoadGraph.loopNodeIds
	local positions: { Vector3 } = {}
	for i, id in ids do
		local node = Graph.node(id)
		if node == nil then
			failRun(ctx, "County Loop", `unknown loop node {id}`)
			return
		end
		positions[i] = node.position
	end
	if #positions < 3 then
		failRun(ctx, "County Loop", "RoadGraph.loopNodeIds has fewer than 3 nodes")
		return
	end

	-- Join the loop at the node nearest the car.
	local here = carPosition()
	if here == nil then
		failRun(ctx, "County Loop", "not driving")
		return
	end
	local startIndex, nearest = 1, math.huge
	for i, position in positions do
		local distance = (flat(position) - flat(here)).Magnitude
		if distance < nearest then
			startIndex, nearest = i, distance
		end
	end
	if nearest > SETTINGS.atNodeRadius then
		if not driveTo(ctx, "to the County Loop", positions[startIndex], townMph) or cancelRequested(ctx) then
			return
		end
	end

	-- Lap in the direction the car already faces, so it never U-turns on the highway.
	local pose = carPose()
	if pose == nil then
		failRun(ctx, "County Loop", "not driving")
		return
	end
	local count = #positions
	local forward = flat(pose.LookVector)
	local nextPosition = positions[startIndex % count + 1]
	local previousPosition = positions[(startIndex - 2) % count + 1]
	local towardNext = flat(nextPosition - pose.Position)
	local towardPrevious = flat(previousPosition - pose.Position)
	local direction = if towardNext.Magnitude > EPSILON
			and towardPrevious.Magnitude > EPSILON
			and forward:Dot(towardPrevious.Unit) > forward:Dot(towardNext.Unit)
		then -1
		else 1

	local lap: { Vector3 } = {}
	for _, index in RouteMath.lapOrder(count, startIndex, direction) do
		table.insert(lap, positions[index])
	end
	driveRun(ctx, "County Loop", lap, loopMph)
end

-- The zone's first GPS destination (MapLayout order) at least SETTINGS.minTripStuds from `from`, so the spawn
-- zone's run is a real drive and not the used lot itself; failing that, its farthest one.
local function destinationIn(zoneId: string, from: Vector3): MapLayout.Location?
	local farthest: MapLayout.Location? = nil
	local farthestDistance = -1
	for _, location in MapLayout.locations do
		if location.zone == zoneId and location.gps then
			local distance = (flat(location.position) - flat(from)).Magnitude
			if distance >= SETTINGS.minTripStuds then
				return location
			elseif distance > farthestDistance then
				farthest, farthestDistance = location, distance
			end
		end
	end
	return farthest
end

-- Where players spawn: the first player spawn, else the used lot.
local function spawnPosition(): Vector3?
	local first = MapLayout.playerSpawns[1]
	if first then
		return first.Position
	end
	for _, location in MapLayout.locations do
		if location.tag == "UsedLot" then
			return location.position
		end
	end
	return nil
end

local function driveZones(ctx: Context)
	local townMph = ctx.options.townMph or SETTINGS.townMph
	local found = spawnPosition()
	if found == nil then
		failRun(ctx, "zones", "MapLayout has no player spawn or used lot")
		return
	end
	local spawnPoint: Vector3 = found
	-- The car is back at the spawn once it is near the spawn itself or the road point nearest it (where a route
	-- to the spawn ends).
	local _, _, _, spawnRoad = Graph.nearestEdge(spawnPoint)
	local function atSpawn(): boolean
		local here = carPosition()
		if here == nil then
			return false
		end
		local nearSpawn = (flat(here) - flat(spawnPoint)).Magnitude <= SETTINGS.atSpawnRadius
		local nearRoad = spawnRoad ~= nil and (flat(here) - flat(spawnRoad)).Magnitude <= SETTINGS.atSpawnRadius
		return nearSpawn or nearRoad
	end

	for _, zoneId in ctx.options.zones or MapLayout.zoneOrder do
		if cancelRequested(ctx) then
			return
		end
		local zone = MapLayout.zones[zoneId]
		local zoneName = if zone then zone.displayName else zoneId
		local destination = destinationIn(zoneId, spawnPoint)
		if destination == nil then
			failRun(ctx, zoneName, "no GPS destination in this zone")
			continue
		end
		if not ctx.options.chain and not atSpawn() then
			if not driveTo(ctx, "back to the spawn", spawnPoint, townMph) or cancelRequested(ctx) then
				return
			end
		end
		driveTo(ctx, `{zoneName}: {destination.displayName}`, destination.position, townMph)
	end
end

local TESTS: { [TestName]: (ctx: Context) -> () } = {
	countyLoop = driveCountyLoop,
	zones = driveZones,
	all = function(ctx: Context)
		driveZones(ctx)
		if not cancelRequested(ctx) then
			driveCountyLoop(ctx)
		end
	end,
}

local function emptyResult(): Result
	return { runs = {}, total = RouteMath.totalOf({}) }
end

-- Runs one test to the end and returns its result. Refuses outside a Studio playtest client, when the player
-- isn't driving, or while another test runs.
local function runTest(name: TestName, opts: Options?): Result
	if not (RunService:IsStudio() and RunService:IsRunning()) then
		warn("[RouteTests] runs only in a Studio playtest (Client datamodel)")
		return emptyResult()
	end
	if script:GetAttribute(STATUS) == "running" then
		warn("[RouteTests] a test is already running; RouteTests.stop() cancels it")
		return emptyResult()
	end
	if carPose() == nil then
		warn("[RouteTests] sit in a car's Driver seat first (and run this in the Client datamodel)")
		return emptyResult()
	end

	local ctx: Context = { id = HttpService:GenerateGUID(false), runs = {}, options = opts or {} }
	script:SetAttribute(RUN_ID, ctx.id)
	script:SetAttribute(STATUS, "running")
	script:SetAttribute(CANCEL, false)
	script:SetAttribute(RESULT, nil)
	local ok, err = pcall(TESTS[name], ctx)
	if not ok then
		warn(`[RouteTests] {name} failed: {err}`)
		failRun(ctx, name, `error: {tostring(err)}`)
	end

	local result: Result = { runs = ctx.runs, total = RouteMath.totalOf(ctx.runs) }
	local total = result.total
	print(
		`[RouteTests] {name} TOTAL: {total.completed}/{total.runs} completed, {total.stuckEvents} stuck, `
			.. `{string.format("%.1f", total.elapsed)} s, max {string.format("%.1f", total.maxMph)} mph -> `
			.. `{if total.passed then "PASS" else "FAIL"}`
	)
	-- A newer test owns the shared status now: leave it alone.
	if script:GetAttribute(RUN_ID) == ctx.id then
		local status = if not ok then "failed" elseif cancelRequested(ctx) then "stopped" else "done"
		script:SetAttribute(RESULT, HttpService:JSONEncode(result))
		script:SetAttribute(CURRENT, nil)
		script:SetAttribute(STATUS, status)
	end
	return result
end

local RouteTests = {}
RouteTests.Math = RouteMath
RouteTests.SETTINGS = SETTINGS

function RouteTests.countyLoop(opts: Options?): Result
	return runTest("countyLoop", opts)
end

function RouteTests.zones(opts: Options?): Result
	return runTest("zones", opts)
end

function RouteTests.all(opts: Options?): Result
	return runTest("all", opts)
end

-- Starts a test in the background and returns at once. Poll lastResult() (nil until it finishes) or watch the
-- console.
function RouteTests.start(name: TestName, opts: Options?)
	if TESTS[name] == nil then
		warn(`[RouteTests] unknown test "{name}"; use "countyLoop", "zones" or "all"`)
		return
	end
	task.spawn(runTest, name, opts)
end

-- The last finished result, or nil while a test runs (or before any has finished).
function RouteTests.lastResult(): Result?
	local encoded = script:GetAttribute(RESULT)
	if script:GetAttribute(STATUS) == "running" or type(encoded) ~= "string" then
		return nil
	end
	return HttpService:JSONDecode(encoded)
end

-- "idle", "running", "done", "stopped" or "failed", and the run being driven now.
function RouteTests.status(): (string, string?)
	local status = script:GetAttribute(STATUS)
	local current = script:GetAttribute(CURRENT)
	return if type(status) == "string" then status else "idle", if type(current) == "string" then current else nil
end

-- Cancels a running test after handing the controls back, and clears a "running" status left by a test whose
-- thread died.
function RouteTests.stop()
	if not RunService:IsStudio() then
		return
	end
	script:SetAttribute(CANCEL, true)
	AutoDriver.stop()
	if script:GetAttribute(STATUS) == "running" then
		script:SetAttribute(STATUS, "stopped")
	end
end

return RouteTests
