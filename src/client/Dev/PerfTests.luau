--!strict
-- Studio-only performance drive (PLAN.md Phase 14 "Budgets" and acceptance "Performance targets are hit in Studio
-- device simulation"; docs/phase-14-contracts.md "Performance"). It uses only what a player's client can do
-- (DevSpawnVehicle, DevSetEnergy, DevPerf) and Dev/AutoDriver:
--   drive(opts)   spawns a fast catalog car (SETTINGS.car, or opts.vehicleId / opts.trim) in the right-hand lanes of the
--                 County Loop, SETTINGS.startAlong studs on from SETTINGS.startNode, tops its battery up, and has
--                 Dev/AutoDriver drive it round the loop at the highway's speed limit (the fastest highway edge in
--                 Config/RoadGraph; opts.targetMph for another) with the ambient traffic on, for SETTINGS.driveSeconds
--                 (opts.seconds). After SETTINGS.warmupSeconds (the spawn, the area streaming in, getting up to speed)
--                 it samples until the drive ends:
--                   * every frame (RenderStepped): the client's frame time, for its mean, p95 and worst
--                   * every SETTINGS.statEverySeconds: the client's memory (Stats:GetTotalMemoryUsageMb), the BaseParts
--                     streamed into Workspace (counted by Workspace.DescendantAdded / DescendantRemoving from one scan
--                     at the start, never a scan per tick), the car's distance, and the pods drawn
--                   * the server's heartbeat over the same window (Net DevPerf start / stop, Services/DevPerfService),
--                     with its Workspace instance and part counts at the end
--                   * TrafficController.stats(): pods with a route, and its own step time (p95) at the end
--                 Checks, against Config/Perf: Workspace.StreamingEnabled is as Config/Perf.streaming (the other four
--                 streaming properties aren't readable from scripts: set by hand, LAUNCH step 10); traffic is on; the
--                 car spawned, drove the whole window, reached SETTINGS.speedShare of the target and never got stuck;
--                 the client's frame time mean and p95 are within the device's budget (frame.desktop or frame.phone);
--                 the server's are within frame.server. Memory and part counts are reported, not judged: Studio's
--                 memory includes Studio itself.
--   start("drive", opts)  runs it in the background and returns at once; lastResult() returns its result once done
--                 (nil while it runs), status() what it's doing, stop() cancels it.
-- The Result: { name, passed, reason, checks = { { name, passed, detail } }, notes, elapsed } plus the numbers it
-- measured. Every check and the result are printed as they finish, so get_console_output shows them even if
-- execute_luau stops waiting.
--
-- Run from MCP execute_luau in the Client datamodel of a playtest, once the player's data has loaded:
--   require(game.Players.LocalPlayer.PlayerScripts.Client.Dev.PerfTests).start("drive")
--   require(game.Players.LocalPlayer.PlayerScripts.Client.Dev.PerfTests).lastResult()
-- Phone: run it again with Studio's device emulator on a mid-range phone (Test > Device, a 6-inch phone in landscape).
-- A touch-only device is judged against frame.phone; start("drive", { device = "phone" }) forces it. The emulator
-- changes the screen and the input, not this machine's CPU or GPU, so it checks the phone layout's cost here; the
-- real-phone check is Davis's, with Roblox's Performance Stats overlay on the phone against the same Config/Perf
-- numbers (frame.phone, memory.phoneMb).
--
-- Nothing is left behind: the server sampler is stopped and the controls handed back even when the test fails, errors
-- or is stopped. What still needs undoing lives in attributes on this ModuleScript (Studio gives execute_luau its own
-- copy of each module, but the ModuleScript is the same), so stop() from any copy, or the next run, sweeps up after a
-- test whose thread died. The car stays parked where the drive ended. Remotes go through this copy's own Net (set up
-- on first use); driving goes through AutoDriver's bridge and the traffic numbers through TrafficController's (see
-- their headers).
--
-- Does nothing outside a Studio playtest (CLAUDE.md hard rule 8); the server refuses DevSpawnVehicle, DevSetEnergy and
-- DevPerf outside Studio too. The client loader never boots it.

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Stats = game:GetService("Stats")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local AutoDriver = require(script.Parent.AutoDriver)
local Catalog = require(Shared.Vehicle.Catalog)
local Graph = require(Shared.Road.Graph)
local Net = require(Shared.Net)
local Perf = require(Shared.Config.Perf)
local RoadGraph = require(Shared.Config.RoadGraph)
local RouteTests = require(script.Parent.RouteTests)
local TrafficController = require(script.Parent.Parent.Controllers.TrafficController)
local Units = require(Shared.Util.Units)
local World = require(Shared.Config.World)

local RouteMath = RouteTests.Math

export type TestName = "drive"
export type Device = "desktop" | "phone"

export type Check = { name: string, passed: boolean, detail: string }

export type FrameNumbers = { samples: number, meanMs: number, p95Ms: number, maxMs: number, fps: number }

export type ServerNumbers = {
	samples: number,
	meanMs: number,
	p95Ms: number,
	maxMs: number,
	fps: number,
	instances: number?, -- everything in Workspace on the server at the end
	parts: number?, -- BaseParts among them
	capped: boolean?,
}

export type Result = {
	name: string,
	passed: boolean, -- every check passed and the test ran to the end
	reason: string, -- "done", or why it ended early
	checks: { Check },
	notes: { string },
	elapsed: number, -- seconds
	device: Device?, -- the frame budget the client was judged against
	vehicle: string?, -- "vehicleId/trim" driven
	targetMph: number?,
	sampledSeconds: number?,
	client: FrameNumbers?,
	server: ServerNumbers?,
	memoryMb: { start: number, peak: number, last: number }?,
	streamedParts: { min: number, max: number, last: number }?, -- BaseParts in Workspace on this client
	traffic: { pods: number, mostDrawn: number, stepP95Ms: number }?,
	maxMph: number?,
	averageMph: number?, -- over the sampled window
	stuckEvents: number?,
	streaming: { [string]: any }?, -- Workspace's streaming properties as read here
}

export type Options = {
	device: Device?, -- the frame budget to judge against (default: "phone" on a touch-only device, else "desktop")
	vehicleId: string?, -- the car to drive (default SETTINGS.car)
	trim: string?, -- with vehicleId (default: its first trim)
	targetMph: number?, -- cruise speed (default: the County Loop's speed limit)
	seconds: number?, -- the whole drive, warm-up included (default SETTINGS.driveSeconds)
}

-- A dev tool, so its numbers live here rather than in Shared/Config (like Dev/SocialTests' SETTINGS).
local SETTINGS = {
	car = { vehicleId = "montevale_valtero", trim = "standard" }, -- a dealership exotic: 190 mph, battery
	driveSeconds = 150, -- the whole drive, from pulling away
	warmupSeconds = 15, -- not sampled: the spawn, streaming the area in and getting up to speed
	minSampleSeconds = 10, -- a shorter opts.seconds still samples this long
	statEverySeconds = 5, -- memory, streamed parts, distance and pods drawn are read this often
	startNode = "loop_s_w", -- the County Loop node the car starts after (RoadGraph.loopNodeIds)...
	startAlong = 300, -- ...this many studs along the loop toward the next node (clear of the interchange ramps)
	standHeight = 3, -- studs above the road the character is put at
	speedShare = 0.9, -- the drive counts as at highway speed once it reaches this share of the target
	energyLevel = 1, -- the car's battery is set to this first (DevSetEnergy)
	extraLaps = 1, -- laps planned beyond what the drive covers at the target speed, so the route never runs out
	driveTimeoutExtra = 60, -- AutoDriver's own timeout: the drive's seconds plus this
	maxMiter = 2, -- lane offset at corners, as Dev/RouteTests
	holdSeconds = 8, -- brakes this long at the end (from highway speed to a stop)
	-- Waiting (seconds)
	invokeTimeout = 15, -- a function remote with no reply by then counts as unanswered (its service isn't running)
	spawnTimeout = 15,
	exitTimeout = 5,
	streamTimeout = 5,
	finishTimeout = 15, -- after the drive is stopped, the longest wait for AutoDriver to hand back
	settleSeconds = 1.5, -- after getting out, moving or sitting down, before the next step
	recheckSeconds = 0.5, -- waits also look again this often (for changes no signal reports)
	stopGraceSeconds = 3, -- stop(): time a running test gets to clean up before the sweep
}

local STATUS = "Status" -- attribute: "idle", "running", "done", "stopped" or "failed"
local CURRENT = "Current" -- attribute: what the running test is doing now
local RESULT = "Result" -- attribute: the last result, as JSON
local CANCEL = "Cancel" -- attribute: true asks a running test to stop
local RUN_ID = "RunId" -- attribute: the id of the newest run
local SERVER_SAMPLING = "ServerSampling" -- attribute: true while DevPerf may be sampling (stopped in the cleanup)
local DRIVING = "Driving" -- attribute: true while AutoDriver may be driving (stopped in the cleanup)
local LOG = "[PerfTests]"
local MS_PER_SECOND = 1000
local EPSILON = 1e-6

-- Car attributes and the vehicle model contract.
local VEHICLE_ID_ATTRIBUTE = "VehicleId"
local TRIM_ATTRIBUTE = "Trim"
local DRIVER_SEAT = "Driver"
local HIGHWAY: RoadGraph.Kind = "highway"
-- Workspace's streaming properties a script can read, by Config/Perf.streaming key. StreamingMinRadius,
-- StreamingTargetRadius, StreamOutBehavior and StreamingIntegrityMode are not scriptable: they are set by hand in
-- Studio's Properties panel (docs/LAUNCH.md step 10), and scripts/check (its "streaming settings" step) holds
-- default.project.json's copy to Config/Perf.streaming at build time.
local STREAMING_PROPERTIES: { { key: string, property: string, enum: boolean } } = {
	{ key = "enabled", property = "StreamingEnabled", enum = false },
}
local UNSCRIPTABLE_STREAMING = "StreamingMinRadius, StreamingTargetRadius, StreamOutBehavior and StreamingIntegrityMode"

type Context = { id: string, label: string, started: number, keepGoing: boolean }

-- BaseParts in Workspace, kept by its descendant signals from one scan.
type Counter = { parts: number, connections: { RBXScriptConnection } }

type Sampler = {
	car: Model,
	counter: Counter,
	frames: { number }, -- ms
	sampledSeconds: number,
	sinceStat: number,
	memory: { start: number, peak: number, last: number },
	parts: { min: number, max: number, last: number },
	mostDrawn: number,
	distance: number, -- studs the car covered (between stat ticks, on the ground)
	lastPosition: Vector3?,
	connection: RBXScriptConnection?,
}

type DriveState = {
	counter: Counter?,
	sampler: Sampler?,
	report: AutoDriver.Report?,
	driveDone: BindableEvent,
	driving: boolean, -- a drive thread is out
}

---------------------------------------------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------------------------------------------

local function flat(v: Vector3): Vector3
	return Vector3.new(v.X, 0, v.Z)
end

local function round(value: number, places: number): number
	local scale = 10 ^ places
	return math.round(value * scale) / scale
end

-- Run state ----------------------------------------------------------------------------------------------------

local function cancelRequested(ctx: Context): boolean
	if ctx.keepGoing then
		return false
	end
	return script:GetAttribute(CANCEL) == true or script:GetAttribute(RUN_ID) ~= ctx.id
end

local function setCurrent(ctx: Context, text: string)
	if script:GetAttribute(RUN_ID) == ctx.id then
		script:SetAttribute(CURRENT, text)
	end
	print(`{LOG} {ctx.label}: {text}`)
end

-- A context for cleaning up: never cancelled.
local function cleanupContext(): Context
	return { id = "cleanup", label = "cleanup", started = os.clock(), keepGoing = true }
end

-- Results ------------------------------------------------------------------------------------------------------

local function newResult(name: string): Result
	return { name = name, passed = false, reason = "done", checks = {}, notes = {}, elapsed = 0 }
end

local function check(result: Result, name: string, passed: boolean, detail: string?)
	local text = detail or ""
	table.insert(result.checks, { name = name, passed = passed, detail = text })
	print(`{LOG} {result.name}: {if passed then "PASS" else "FAIL"} {name}{if text ~= "" then ` ({text})` else ""}`)
end

local function note(result: Result, text: string)
	table.insert(result.notes, text)
	print(`{LOG} {result.name}: note: {text}`)
end

-- Passed only when the test ran to the end and every one of its checks passed.
local function finishResult(result: Result, started: number): Result
	result.elapsed = os.clock() - started
	local passed = result.reason == "done" and #result.checks > 0
	local failed = 0
	for _, item in result.checks do
		passed = passed and item.passed
		if not item.passed then
			failed += 1
		end
	end
	result.passed = passed
	print(
		`{LOG} {result.name}: {if passed then "PASSED" else "FAILED"} ({result.reason}; {#result.checks - failed} of `
			.. `{#result.checks} checks passed) in {math.floor(result.elapsed)} s`
	)
	local ok, encoded = pcall(HttpService.JSONEncode, HttpService, result)
	if ok then
		print(`{LOG} {result.name}: {encoded}`)
	end
	return result
end

-- Waiting ------------------------------------------------------------------------------------------------------

-- Waits until `test()` is true, looking again whenever one of `signals` fires and every SETTINGS.recheckSeconds,
-- for at most `timeout` seconds; a cancel ends the wait too. Returns whether `test()` came true.
local function waitFor(ctx: Context, test: () -> boolean, signals: { RBXScriptSignal }, timeout: number): boolean
	if test() then
		return true
	end
	if cancelRequested(ctx) then
		return false
	end
	local outcome: boolean? = nil
	local waiting: thread? = nil
	local connections: { RBXScriptConnection } = {}
	local function finish(value: boolean)
		if outcome ~= nil then
			return
		end
		outcome = value
		for _, connection in connections do
			connection:Disconnect()
		end
		local thread = waiting
		if thread ~= nil then
			task.defer(thread)
		end
	end
	local function recheck()
		if outcome == nil and test() then
			finish(true)
		end
	end
	for _, signal in signals do
		table.insert(connections, signal:Connect(recheck))
	end
	table.insert(
		connections,
		script:GetAttributeChangedSignal(CANCEL):Connect(function()
			if cancelRequested(ctx) then
				finish(false)
			end
		end)
	)
	local deadline = os.clock() + timeout
	task.spawn(function()
		while outcome == nil do
			task.wait(math.min(SETTINGS.recheckSeconds, math.max(deadline - os.clock(), 0)))
			if outcome ~= nil then
				break
			end
			if test() then
				finish(true)
			elseif os.clock() >= deadline or cancelRequested(ctx) then
				finish(false)
			end
		end
	end)
	if outcome == nil then
		waiting = coroutine.running()
		coroutine.yield()
	end
	return outcome == true
end

-- Waits `seconds`; false when the test was cancelled meanwhile.
local function pause(ctx: Context, seconds: number): boolean
	waitFor(ctx, function(): boolean
		return false
	end, {}, seconds)
	return not cancelRequested(ctx)
end

-- Remotes ------------------------------------------------------------------------------------------------------

local netReady = false

-- This copy of Net may be MCP's own (not the game's), so make sure it knows the remotes.
local function ensureNet()
	if not netReady then
		Net.setupClient()
		netReady = true
	end
end

-- Calls a function remote. Returns its reply (nil when Net refused it) and whether it answered at all within
-- SETTINGS.invokeTimeout (a remote nobody serves never answers).
local function invoke(name: string, payload: any?): (any, boolean)
	ensureNet()
	local done = false
	local reply: any = nil
	local answered = false
	local waiting: thread? = nil
	local function finish(value: any, didAnswer: boolean)
		if done then
			return
		end
		done = true
		reply, answered = value, didAnswer
		local thread = waiting
		if thread ~= nil then
			task.defer(thread)
		end
	end
	task.spawn(function()
		local ok, value = pcall(Net.invokeServer, name, payload)
		if not ok then
			warn(`{LOG} {name} failed: {value}`)
		end
		finish(if ok then value else nil, ok)
	end)
	task.delay(SETTINGS.invokeTimeout, function()
		finish(nil, false)
	end)
	if not done then
		waiting = coroutine.running()
		coroutine.yield()
	end
	return reply, answered
end

-- The dev function remotes answer { ok, message, ... }.
local function accepted(reply: any): boolean
	return type(reply) == "table" and reply.ok == true
end

local function describe(reply: any, answered: boolean): string
	if not answered then
		return `no reply in {SETTINGS.invokeTimeout} s (is the service behind it running?)`
	elseif reply == nil then
		return "refused by Net (rate limit or payload)"
	elseif type(reply) ~= "table" then
		return tostring(reply)
	end
	return `{if reply.ok == true then "ok" else "refused"}: {tostring(reply.message)}`
end

-- The character and the car -----------------------------------------------------------------------------------

local function humanoidOf(): Humanoid?
	local character = Players.LocalPlayer.Character
	return if character then character:FindFirstChildOfClass("Humanoid") else nil
end

-- The car whose Driver seat the local player sits in, or nil.
local function currentCar(): Model?
	local humanoid = humanoidOf()
	local seat = if humanoid then humanoid.SeatPart else nil
	if seat == nil or seat.Name ~= DRIVER_SEAT then
		return nil
	end
	local node: Instance? = seat.Parent
	while node do
		if node:IsA("Model") and node:GetAttribute(VEHICLE_ID_ATTRIBUTE) ~= nil then
			return node
		end
		node = node.Parent
	end
	return nil
end

local function carIdentity(car: Model): (string?, string?)
	local vehicleId, trim = car:GetAttribute(VEHICLE_ID_ATTRIBUTE), car:GetAttribute(TRIM_ATTRIBUTE)
	return if type(vehicleId) == "string" then vehicleId else nil, if type(trim) == "string" then trim else nil
end

-- Gets the character out of any car and puts it at `at` (streaming the world in around it). Returns whether it
-- moved, and why not.
local function moveTo(ctx: Context, at: CFrame): (boolean, string?)
	local character = Players.LocalPlayer.Character
	local found = humanoidOf()
	if character == nil or found == nil then
		return false, "no character"
	end
	local humanoid: Humanoid = found
	if humanoid.SeatPart ~= nil then
		humanoid.Sit = false
		humanoid.Jump = true
		local out = waitFor(ctx, function(): boolean
			return humanoid.SeatPart == nil
		end, { humanoid:GetPropertyChangedSignal("SeatPart") }, SETTINGS.exitTimeout)
		if not out then
			return false, "couldn't get out of the car"
		end
		-- The server stands the character beside the car it left; move only after that.
		task.wait(SETTINGS.settleSeconds)
	end
	character:PivotTo(at)
	pcall(function()
		Players.LocalPlayer:RequestStreamAroundAsync(at.Position, SETTINGS.streamTimeout)
	end)
	task.wait(SETTINGS.settleSeconds)
	return true, nil
end

-- Spawns a fresh `vehicleId`/`trim` with the player in it: the character stands at `stand` (DevSpawnVehicle puts
-- the car Config/Spawning spawnOffset + half its length in front of it, facing the way it faces). Returns the car,
-- or nil and why.
local function spawnAt(ctx: Context, vehicleId: string, trim: string, stand: CFrame): (Model?, string?)
	local moved, why = moveTo(ctx, stand)
	if not moved then
		return nil, why
	end
	local found = humanoidOf()
	if found == nil then
		return nil, "no character"
	end
	local humanoid: Humanoid = found
	ensureNet()
	Net.fireServer("DevSpawnVehicle", { vehicleId = vehicleId, trim = trim })
	local seated = waitFor(ctx, function(): boolean
		local car = currentCar()
		if car == nil then
			return false
		end
		local id, trimId = carIdentity(car)
		return id == vehicleId and trimId == trim
	end, { humanoid:GetPropertyChangedSignal("SeatPart") }, SETTINGS.spawnTimeout)
	if not seated then
		return nil, `{vehicleId}/{trim} didn't spawn with you in it (is its model in ServerStorage.VehicleModels?)`
	end
	task.wait(SETTINGS.settleSeconds)
	return currentCar(), nil
end

-- The County Loop ----------------------------------------------------------------------------------------------

-- The County Loop's speed limit: the fastest highway edge in Config/RoadGraph (0 when there is none).
local function highwayLimit(): number
	local limit = 0
	for _, edge in RoadGraph.edges do
		if edge.kind == HIGHWAY then
			limit = math.max(limit, edge.speedLimitMph)
		end
	end
	return limit
end

-- Right-hand lane offset for the stretch a-b, from the lanes of the road edge under its middle (as Dev/RouteTests).
local function laneOffsetFor(a: Vector3, b: Vector3): number
	local edgeIndex = Graph.nearestEdge((a + b) / 2)
	if edgeIndex == nil then
		return 0
	end
	local edge = Graph.edges()[edgeIndex]
	return if edge then RouteMath.rightLaneOffset(edge.lanes, World.laneWidth) else 0
end

local function loopPositions(): ({ Vector3 }?, string?)
	local positions: { Vector3 } = {}
	for index, id in RoadGraph.loopNodeIds do
		local node = Graph.node(id)
		if node == nil then
			return nil, `unknown County Loop node {id}`
		end
		positions[index] = node.position
	end
	if #positions < 3 then
		return nil, "RoadGraph.loopNodeIds has fewer than 3 nodes"
	end
	return positions, nil
end

-- Where the character stands to spawn the car: in the right-hand lanes, SETTINGS.startAlong studs on from
-- SETTINGS.startNode toward the next loop node, facing that way.
local function startFrame(): (CFrame?, string?)
	local positions, why = loopPositions()
	if positions == nil then
		return nil, why
	end
	local index = table.find(RoadGraph.loopNodeIds, SETTINGS.startNode)
	if index == nil then
		return nil, `{SETTINGS.startNode} is not a County Loop node`
	end
	local from = positions[index]
	local to = positions[index % #positions + 1]
	local along = flat(to - from)
	if along.Magnitude < EPSILON then
		return nil, `{SETTINGS.startNode} and the next loop node are in the same place`
	end
	local direction = along.Unit
	local right = Vector3.new(-direction.Z, 0, direction.X)
	local ground = from
		+ direction * math.min(SETTINGS.startAlong, along.Magnitude / 2)
		+ right * laneOffsetFor(from, to)
	local at = ground + Vector3.yAxis * SETTINGS.standHeight
	return CFrame.lookAt(at, at + direction), nil
end

-- Laps of the County Loop from the node nearest the car, the way it faces, in the right-hand lanes: enough to cover
-- `seconds` at `targetMph`, plus SETTINGS.extraLaps.
local function lapPath(car: Model, targetMph: number, seconds: number): ({ Vector3 }?, string?)
	local positions, why = loopPositions()
	if positions == nil then
		return nil, why
	end
	local chassis = car.PrimaryPart
	if chassis == nil then
		return nil, "the car has no Chassis"
	end
	local pose = chassis.CFrame
	local count = #positions
	local startIndex, nearest = 1, math.huge
	for index, position in positions do
		local distance = (flat(position) - flat(pose.Position)).Magnitude
		if distance < nearest then
			startIndex, nearest = index, distance
		end
	end
	local forward = flat(pose.LookVector)
	local towardNext = flat(positions[startIndex % count + 1] - pose.Position)
	local towardPrevious = flat(positions[(startIndex - 2) % count + 1] - pose.Position)
	local direction = if towardNext.Magnitude > EPSILON
			and towardPrevious.Magnitude > EPSILON
			and forward:Dot(towardPrevious.Unit) > forward:Dot(towardNext.Unit)
		then -1
		else 1
	local order = RouteMath.lapOrder(count, startIndex, direction)
	local lap: { Vector3 } = {}
	for _, index in order do
		table.insert(lap, positions[index])
	end
	local lapLength = RouteMath.length(lap[#lap], lap)
	local laps = math.ceil(seconds * Units.mphToStuds(targetMph) / math.max(lapLength, EPSILON)) + SETTINGS.extraLaps
	local points: { Vector3 } = {}
	for _ = 1, laps do
		for _, point in lap do
			table.insert(points, point)
		end
	end
	return RouteMath.keepRight(points, laneOffsetFor, SETTINGS.maxMiter), nil
end

-- Measuring ----------------------------------------------------------------------------------------------------

local function trafficStats(): TrafficController.Stats?
	local ok, stats = pcall(TrafficController.stats)
	return if ok and type(stats) == "table" then stats else nil
end

local function startCounter(): Counter
	local counter: Counter = { parts = 0, connections = {} }
	for _, descendant in Workspace:GetDescendants() do
		if descendant:IsA("BasePart") then
			counter.parts += 1
		end
	end
	table.insert(
		counter.connections,
		Workspace.DescendantAdded:Connect(function(descendant: Instance)
			if descendant:IsA("BasePart") then
				counter.parts += 1
			end
		end)
	)
	table.insert(
		counter.connections,
		Workspace.DescendantRemoving:Connect(function(descendant: Instance)
			if descendant:IsA("BasePart") then
				counter.parts -= 1
			end
		end)
	)
	return counter
end

local function stopCounter(counter: Counter)
	for _, connection in counter.connections do
		connection:Disconnect()
	end
	table.clear(counter.connections)
end

-- One stat tick: memory, streamed parts, the car's distance and the pods drawn.
local function readStats(sampler: Sampler)
	local memory = Stats:GetTotalMemoryUsageMb()
	sampler.memory.peak = math.max(sampler.memory.peak, memory)
	sampler.memory.last = memory
	local parts = sampler.counter.parts
	sampler.parts.min = math.min(sampler.parts.min, parts)
	sampler.parts.max = math.max(sampler.parts.max, parts)
	sampler.parts.last = parts
	local chassis = sampler.car.PrimaryPart
	if chassis ~= nil and chassis.Parent ~= nil then
		local position = chassis.Position
		local last = sampler.lastPosition
		if last ~= nil then
			sampler.distance += flat(position - last).Magnitude
		end
		sampler.lastPosition = position
	end
	local traffic = trafficStats()
	if traffic ~= nil then
		sampler.mostDrawn = math.max(sampler.mostDrawn, traffic.visible)
	end
end

-- Starts sampling every frame (and a stat tick every SETTINGS.statEverySeconds). The first stat tick runs before the
-- first frame is timed, so its own cost lands outside the window.
local function startSampler(car: Model, counter: Counter): Sampler
	local memory = Stats:GetTotalMemoryUsageMb()
	local sampler: Sampler = {
		car = car,
		counter = counter,
		frames = {},
		sampledSeconds = 0,
		sinceStat = 0,
		memory = { start = memory, peak = memory, last = memory },
		parts = { min = counter.parts, max = counter.parts, last = counter.parts },
		mostDrawn = 0,
		distance = 0,
		lastPosition = nil,
		connection = nil,
	}
	readStats(sampler)
	sampler.connection = RunService.RenderStepped:Connect(function(deltaTime: number)
		table.insert(sampler.frames, deltaTime * MS_PER_SECOND)
		sampler.sampledSeconds += deltaTime
		sampler.sinceStat += deltaTime
		if sampler.sinceStat >= SETTINGS.statEverySeconds then
			sampler.sinceStat = 0
			task.spawn(readStats, sampler)
		end
	end)
	return sampler
end

local function stopSampler(sampler: Sampler)
	local connection = sampler.connection
	sampler.connection = nil
	if connection ~= nil then
		connection:Disconnect()
		readStats(sampler)
	end
end

local function frameNumbers(summary: Perf.Summary): FrameNumbers
	return {
		samples = summary.samples,
		meanMs = round(summary.meanMs, 2),
		p95Ms = round(summary.p95Ms, 2),
		maxMs = round(summary.maxMs, 2),
		fps = if summary.meanMs > 0 then round(MS_PER_SECOND / summary.meanMs, 1) else 0,
	}
end

-- Judges a summary against a budget: one check for the mean, one for the p95.
local function judgeFrames(result: Result, who: string, summary: Perf.Summary, budget: Perf.FrameBudget)
	local numbers = frameNumbers(summary)
	local meanOk, p95Ok = Perf.meets(summary, budget)
	local any = summary.samples > 0
	check(
		result,
		`{who} frame time mean within budget`,
		any and meanOk,
		`{numbers.meanMs} ms ({numbers.fps} fps) over {numbers.samples} frames; budget {budget.meanMs} ms `
			.. `({budget.fps} fps)`
	)
	check(
		result,
		`{who} frame time p95 within budget`,
		any and p95Ok,
		`{numbers.p95Ms} ms, worst {numbers.maxMs} ms; budget {budget.p95Ms} ms`
	)
end

-- Workspace's readable streaming properties against Config/Perf.streaming. Fails only on a property that was read and
-- doesn't match; the unscriptable ones are checked at build time (STREAMING_PROPERTIES).
local function checkStreaming(result: Result)
	local live: { [string]: any } = {}
	local mismatched: { string } = {}
	local unreadable: { string } = {}
	local wanted: { [string]: any } = Perf.streaming :: any
	for _, entry in STREAMING_PROPERTIES do
		local ok, value = pcall(function(): any
			local raw = (Workspace :: any)[entry.property]
			return if entry.enum then raw.Name else raw
		end)
		if not ok then
			table.insert(unreadable, entry.property)
			continue
		end
		live[entry.key] = value
		if value ~= wanted[entry.key] then
			table.insert(mismatched, `{entry.property} is {tostring(value)}, want {tostring(wanted[entry.key])}`)
		end
	end
	result.streaming = live
	if #unreadable > 0 then
		note(result, `couldn't read {table.concat(unreadable, ", ")} on this client`)
	end
	note(
		result,
		`{UNSCRIPTABLE_STREAMING} are not readable from scripts: they are set by hand in Workspace's properties `
			.. "(Config/Perf.streaming; docs/LAUNCH.md step 10)"
	)
	check(
		result,
		"Workspace streaming is set as Config/Perf.streaming",
		#mismatched == 0,
		if #mismatched == 0
			then `StreamingEnabled {tostring(live.enabled)} (the rest are checked at build time)`
			else table.concat(mismatched, "; ")
	)
end

local function deviceOf(options: Options): Device
	if options.device == "phone" then
		return "phone"
	elseif options.device == "desktop" then
		return "desktop"
	end
	return if UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled then "phone" else "desktop"
end

---------------------------------------------------------------------------------------------------------------
-- Cleanup
---------------------------------------------------------------------------------------------------------------

-- Stops what a run (this one, or one whose thread died) may have left going: the server sampler and the drive.
-- Returns what it did.
local function sweepLeftovers(): { string }
	local swept: { string } = {}
	if script:GetAttribute(SERVER_SAMPLING) == true then
		local reply, answered = invoke("DevPerf", { action = "stop" })
		script:SetAttribute(SERVER_SAMPLING, nil)
		table.insert(swept, `stopped the server sampler ({describe(reply, answered)})`)
	end
	if script:GetAttribute(DRIVING) == true then
		pcall(AutoDriver.stop)
		script:SetAttribute(DRIVING, nil)
		table.insert(swept, "stopped the drive and handed the controls back")
	end
	return swept
end

---------------------------------------------------------------------------------------------------------------
-- The drive
---------------------------------------------------------------------------------------------------------------

-- Ends the drive (if it is still going) and brakes the car to a stop; hands the controls back.
local function endDrive(state: DriveState)
	if not state.driving then
		return
	end
	if state.report == nil then
		pcall(AutoDriver.stop)
		waitFor(cleanupContext(), function(): boolean
			return state.report ~= nil
		end, { state.driveDone.Event }, SETTINGS.finishTimeout)
	end
	pcall(AutoDriver.holdStill, SETTINGS.holdSeconds)
	if state.report ~= nil then
		state.driving = false
		script:SetAttribute(DRIVING, nil)
	end
end

local function driveSteps(ctx: Context, result: Result, options: Options, state: DriveState)
	local device: Device = deviceOf(options)
	result.device = device
	checkStreaming(result)

	local traffic = trafficStats()
	check(
		result,
		"ambient traffic is on (pods with a route)",
		traffic ~= nil and traffic.pods > 0,
		if traffic ~= nil
			then `{traffic.pods} pods with a route, {traffic.visible} drawn`
			else "TrafficController.stats() didn't answer (is the game's TrafficController running?)"
	)

	-- The car, on the County Loop.
	local targetMph = options.targetMph or highwayLimit()
	if targetMph <= 0 then
		result.reason = "Config/RoadGraph has no highway to take a speed limit from"
		return
	end
	result.targetMph = targetMph
	local stand, standWhy = startFrame()
	if stand == nil then
		result.reason = standWhy or "no place to start"
		return
	end
	local vehicleId = options.vehicleId or SETTINGS.car.vehicleId
	local trim = options.trim
	if trim == nil then
		local first = if options.vehicleId ~= nil then Catalog.defaultTrim(vehicleId) else nil
		trim = if first ~= nil then first.id else SETTINGS.car.trim
	end
	local trimId: string = trim :: string
	setCurrent(ctx, `spawning {vehicleId}/{trimId} on the County Loop`)
	local car, spawnWhy = spawnAt(ctx, vehicleId, trimId, stand)
	check(
		result,
		"the test car spawns on the County Loop with you in it",
		car ~= nil,
		spawnWhy or `{vehicleId}/{trimId}`
	)
	if car == nil then
		result.reason = spawnWhy or "no car"
		return
	end
	result.vehicle = `{vehicleId}/{trimId}`
	local energy, energyAnswered = invoke("DevSetEnergy", { level = SETTINGS.energyLevel })
	if not accepted(energy) then
		note(result, `couldn't top the battery up: {describe(energy, energyAnswered)}`)
	end

	local seconds =
		math.max(options.seconds or SETTINGS.driveSeconds, SETTINGS.warmupSeconds + SETTINGS.minSampleSeconds)
	local path, pathWhy = lapPath(car, targetMph, seconds)
	if path == nil then
		result.reason = pathWhy or "no route"
		return
	end

	-- Drive in the background; everything below measures around it.
	state.counter = startCounter()
	state.driving = true
	script:SetAttribute(DRIVING, true)
	setCurrent(ctx, `driving the County Loop at {targetMph} mph for {seconds} s`)
	task.spawn(function()
		local ok, value = pcall(
			AutoDriver.drive,
			path,
			{ targetMph = targetMph, timeout = seconds + SETTINGS.driveTimeoutExtra, stopAtEnd = true }
		)
		if ok then
			state.report = value
		else
			warn(`{LOG} AutoDriver.drive failed: {value}`)
			state.report = {
				completed = false,
				elapsed = 0,
				stuckEvents = 0,
				maxMph = 0,
				reason = `error: {tostring(value)}`,
				pointsReached = 0,
			}
		end
		state.driveDone:Fire()
	end)

	setCurrent(ctx, `warming up for {SETTINGS.warmupSeconds} s`)
	if not pause(ctx, SETTINGS.warmupSeconds) then
		return
	end
	local early = state.report
	if early ~= nil then
		check(result, "the drive keeps going through the warm-up", false, early.reason)
		return
	end

	-- The sampled window.
	local counter = state.counter :: Counter
	local sampler = startSampler(car, counter)
	state.sampler = sampler
	local begun, begunAnswered = invoke("DevPerf", { action = "start" })
	if accepted(begun) then
		script:SetAttribute(SERVER_SAMPLING, true)
	end
	check(result, "the server sampler starts (DevPerf)", accepted(begun), describe(begun, begunAnswered))
	local window = seconds - SETTINGS.warmupSeconds
	setCurrent(ctx, `sampling for {window} s`)
	local endedEarly = waitFor(ctx, function(): boolean
		return state.report ~= nil
	end, { state.driveDone.Event }, window)
	stopSampler(sampler)
	state.sampler = nil
	local serverReply: any, serverAnswered = nil, false
	if script:GetAttribute(SERVER_SAMPLING) == true then
		serverReply, serverAnswered = invoke("DevPerf", { action = "stop" })
		script:SetAttribute(SERVER_SAMPLING, nil)
	end
	if cancelRequested(ctx) then
		return
	end
	setCurrent(ctx, "stopping the car")
	endDrive(state)

	-- The drive itself.
	local report = state.report
	check(
		result,
		"the drive lasts the whole sampled window",
		not endedEarly,
		if endedEarly and report ~= nil then `ended early: {report.reason}` else `{window} s`
	)
	if report ~= nil then
		result.maxMph = round(report.maxMph, 1)
		result.stuckEvents = report.stuckEvents
		check(
			result,
			"the car reaches highway speed",
			report.maxMph >= SETTINGS.speedShare * targetMph,
			`max {round(report.maxMph, 1)} mph; target {targetMph} mph`
		)
		check(result, "the car never gets stuck", report.stuckEvents == 0, `{report.stuckEvents} stuck events`)
	end

	-- The client's frames.
	result.sampledSeconds = round(sampler.sampledSeconds, 1)
	if sampler.sampledSeconds > 0 then
		result.averageMph = round(Units.studsToMph(sampler.distance / sampler.sampledSeconds), 1)
	end
	local summary = Perf.summarize(sampler.frames)
	result.client = frameNumbers(summary)
	local budget: Perf.FrameBudget = if device == "phone" then Perf.frame.phone else Perf.frame.desktop
	judgeFrames(result, `client ({device})`, summary, budget)
	if device == "phone" then
		note(
			result,
			"phone budget judged on this machine: Studio's device emulator changes the screen and input, not the "
				.. "CPU or GPU; confirm on a real phone with Roblox's Performance Stats overlay"
		)
	end

	-- The server's heartbeat.
	if accepted(serverReply) then
		local serverSummary: Perf.Summary = {
			samples = tonumber(serverReply.samples) or 0,
			meanMs = tonumber(serverReply.meanMs) or 0,
			p95Ms = tonumber(serverReply.p95Ms) or 0,
			maxMs = tonumber(serverReply.maxMs) or 0,
		}
		local numbers = frameNumbers(serverSummary)
		result.server = {
			samples = numbers.samples,
			meanMs = numbers.meanMs,
			p95Ms = numbers.p95Ms,
			maxMs = numbers.maxMs,
			fps = numbers.fps,
			instances = tonumber(serverReply.instances),
			parts = tonumber(serverReply.parts),
			capped = serverReply.capped == true,
		}
		judgeFrames(result, "server", serverSummary, Perf.frame.server)
		note(
			result,
			`server Workspace at the end: {tostring(serverReply.instances)} instances, {tostring(serverReply.parts)} `
				.. "BaseParts"
		)
		if serverReply.capped == true then
			note(result, `the server sampler hit its cap (Config/Perf dev.maxSampleSeconds)`)
		end
	else
		check(result, "the server sampler reports (DevPerf)", false, describe(serverReply, serverAnswered))
	end

	-- Reported, not judged.
	local memory = {
		start = round(sampler.memory.start, 0),
		peak = round(sampler.memory.peak, 0),
		last = round(sampler.memory.last, 0),
	}
	result.memoryMb = memory
	result.streamedParts = { min = sampler.parts.min, max = sampler.parts.max, last = sampler.parts.last }
	note(
		result,
		`client memory {memory.start} -> {memory.last} MB (peak {memory.peak}); Studio's number includes Studio `
			.. `itself (phone target {Perf.memory.phoneMb} MB, on a real phone)`
	)
	note(
		result,
		`BaseParts streamed into Workspace: {sampler.parts.min} to {sampler.parts.max} (last {sampler.parts.last})`
	)
	local after = trafficStats()
	if after ~= nil then
		local step = Perf.summarize(after.stepTimes)
		result.traffic = { pods = after.pods, mostDrawn = sampler.mostDrawn, stepP95Ms = round(step.p95Ms, 3) }
		note(
			result,
			`traffic: {after.pods} pods with a route, at most {sampler.mostDrawn} drawn at a tick; its step p95 `
				.. `{round(step.p95Ms, 3)} ms`
		)
	end
	if result.averageMph ~= nil then
		note(result, `average {result.averageMph} mph over the sampled window`)
	end
end

local function driveTest(ctx: Context, options: Options): Result
	local result = newResult("drive")
	local started = os.clock()
	for _, text in sweepLeftovers() do
		note(result, `from an earlier run: {text}`)
	end
	ensureNet()
	local state: DriveState = {
		counter = nil,
		sampler = nil,
		report = nil,
		driveDone = Instance.new("BindableEvent"),
		driving = false,
	}
	local ok, err = pcall(driveSteps :: any, ctx, result, options, state)
	if not ok then
		result.reason = `error: {tostring(err)}`
		warn(`{LOG} drive failed: {err}`)
	end
	local sampler = state.sampler
	if sampler ~= nil then
		stopSampler(sampler)
		state.sampler = nil
	end
	local counter = state.counter
	if counter ~= nil then
		stopCounter(counter)
		state.counter = nil
	end
	endDrive(state)
	for _, text in sweepLeftovers() do
		note(result, text)
	end
	if not state.driving then
		state.driveDone:Destroy()
	end
	if cancelRequested(ctx) and result.reason == "done" then
		result.reason = "stopped"
	end
	return finishResult(result, started)
end

---------------------------------------------------------------------------------------------------------------
-- Running
---------------------------------------------------------------------------------------------------------------

-- Why a test can't start now, or nil.
local function refusal(): string?
	if not (RunService:IsStudio() and RunService:IsRunning() and RunService:IsClient()) then
		return "studio only"
	elseif script:GetAttribute(STATUS) == "running" then
		return "busy"
	end
	return nil
end

local function refusedResult(name: string, reason: string): Result
	local why = if reason == "busy"
		then "a test is already running; PerfTests.stop() cancels it"
		else "runs only in a Studio playtest (Client datamodel)"
	warn(`{LOG} {name}: {why}`)
	local result = newResult(name)
	result.reason = reason
	return result
end

local function openRun(label: string): Context
	local ctx: Context =
		{ id = HttpService:GenerateGUID(false), label = label, started = os.clock(), keepGoing = false }
	script:SetAttribute(RUN_ID, ctx.id)
	script:SetAttribute(STATUS, "running")
	script:SetAttribute(CANCEL, false)
	script:SetAttribute(RESULT, nil)
	return ctx
end

local function closeRun(ctx: Context, passed: boolean, payload: any)
	if script:GetAttribute(RUN_ID) ~= ctx.id then
		return
	end
	local status = if script:GetAttribute(CANCEL) == true then "stopped" elseif passed then "done" else "failed"
	local ok, encoded = pcall(HttpService.JSONEncode, HttpService, payload)
	script:SetAttribute(RESULT, if ok then encoded else nil)
	script:SetAttribute(CURRENT, nil)
	script:SetAttribute(STATUS, status)
end

local PerfTests = {}
PerfTests.SETTINGS = SETTINGS

-- Drives the County Loop at highway speed with traffic on and measures the frame time, memory and streamed parts
-- (see the header). Yields for the whole drive (SETTINGS.driveSeconds); start("drive") runs it in the background.
function PerfTests.drive(opts: Options?): Result
	local refused = refusal()
	if refused ~= nil then
		return refusedResult("drive", refused)
	end
	local ctx = openRun("drive")
	local result = driveTest(ctx, opts or {})
	closeRun(ctx, result.passed, result)
	return result
end

local STARTERS: { [string]: (opts: Options?) -> any } = {
	drive = PerfTests.drive,
}

-- Starts "drive" in the background and returns at once. Poll lastResult() or watch the console.
function PerfTests.start(name: TestName, opts: Options?)
	local starter = STARTERS[name]
	if starter == nil then
		warn(`{LOG} unknown test "{name}"; use "drive"`)
		return
	end
	task.spawn(starter, opts)
end

-- The last finished Result, or nil while a test runs (or before any has finished).
function PerfTests.lastResult(): any
	local encoded = script:GetAttribute(RESULT)
	if script:GetAttribute(STATUS) == "running" or type(encoded) ~= "string" then
		return nil
	end
	return HttpService:JSONDecode(encoded)
end

-- "idle", "running", "done", "stopped" or "failed", and what the running test is doing.
function PerfTests.status(): (string, string?)
	local status = script:GetAttribute(STATUS)
	local current = script:GetAttribute(CURRENT)
	return if type(status) == "string" then status else "idle", if type(current) == "string" then current else nil
end

-- Cancels a running test (it stops the car and the server sampler itself). A moment later it sweeps up anything still
-- left going (a test whose thread died can't) and clears a "running" status that nothing will finish.
function PerfTests.stop()
	if not (RunService:IsStudio() and RunService:IsClient()) then
		return
	end
	script:SetAttribute(CANCEL, true)
	task.delay(SETTINGS.stopGraceSeconds, function()
		sweepLeftovers()
		if script:GetAttribute(STATUS) == "running" then
			script:SetAttribute(STATUS, "stopped")
		end
	end)
end

return PerfTests
