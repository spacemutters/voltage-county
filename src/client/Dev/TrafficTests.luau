--!strict
-- Studio-only ambient traffic test (PLAN.md Phase 9 acceptance: "12 ambient pods run for 10 minutes with no stuck
-- pods, and client frame cost stays within budget"; docs/phase-9-contracts.md "Studio test"). It only watches:
-- Controllers/TrafficController draws the pods from the routes Services/TrafficService publishes, and its stats()
-- report what it did.
--   run(minutes, opts)    waits for every Config/Traffic pods.count pod to have a route, draws them all wherever the
--                         camera is (TrafficController.setRenderAll, the worst case for frame cost; opts.renderAll =
--                         false keeps the normal render distance), then for `minutes` (default SETTINGS.minutes)
--                         samples stats() every SETTINGS.sampleSeconds:
--                           * stuck: a pod that neither moves along its route (more than SETTINGS.moveEpsilon studs)
--                             nor starts a new one for over SETTINGS.stuckSeconds while not yielding to a car. Each
--                             stall counts once. A pod waiting at the end of its route for the next one is stuck.
--                           * frame cost: TrafficController's own step times (os.clock around its RenderStepped
--                             step, kept in a ring that this reads before it fills), mean and p95 in ms.
--                         Passes with every pod there, all of them drawn (with renderAll), zero stuck, mean within
--                         SETTINGS.meanBudgetMs and p95 within SETTINGS.p95BudgetMs.
--   start(name, ...)      runs it in the background and returns at once: start("run"), start("run", 2). lastResult()
--                         returns its result once done (nil while it runs), status() what it's doing, stop() cancels.
-- The result (see the type) carries the numbers: pods, the most drawn at once, frames measured, mean / p95 / max ms,
-- every stall, routes started and yields seen. Every check and the result are printed as they finish, so
-- get_console_output shows them even if execute_luau stops waiting.
--
-- Run from MCP execute_luau in the Client datamodel of a playtest (no character or car needed):
--   require(game.Players.LocalPlayer.PlayerScripts.Client.Dev.TrafficTests).start("run")
--   require(game.Players.LocalPlayer.PlayerScripts.Client.Dev.TrafficTests).lastResult()
--
-- MCP's copy of TrafficController reaches the running one through its Bridge (see its header). State every copy of
-- this module must see (running, cancel, the last result) lives in attributes on this ModuleScript.
--
-- Does nothing outside Studio (CLAUDE.md hard rule 8). The client loader never boots it.

local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Traffic = require(ReplicatedStorage.Shared.Config.Traffic)
local TrafficController = require(script.Parent.Parent.Controllers.TrafficController)

export type TestName = "run"

export type Options = {
	renderAll: boolean?, -- draw every pod wherever the camera is (default true)
}

export type Check = { name: string, passed: boolean, detail: string }

-- A pod that sat still for over SETTINGS.stuckSeconds while not yielding.
export type Stall = {
	pod: number,
	seq: number, -- its route then
	distance: number, -- studs along it
	at: number, -- seconds into the run it was noticed
	waiting: boolean, -- it was at the end of its route, waiting for the next
}

export type Result = {
	name: string,
	passed: boolean,
	skipped: boolean,
	reason: string,
	checks: { Check },
	elapsed: number,
	notes: { string },
	minutes: number,
	pods: number, -- pods with a route
	maxVisible: number, -- the most drawn at once
	frames: number, -- step times measured
	meanMs: number,
	p95Ms: number,
	maxMs: number,
	stuck: number, -- stalls counted
	stalls: { Stall }, -- the first SETTINGS.maxStallsListed of them
	routesStarted: number, -- route changes seen across all pods
	yields: number, -- times a pod began yielding to a car
}

type Track = {
	seq: number,
	distance: number,
	yielding: boolean,
	stillSince: number, -- os.clock() it last moved (or yielded)
	counted: boolean, -- this stall is already counted
}

type Context = {
	id: string,
	name: string,
	started: number,
	result: Result,
}

local SETTINGS = {
	minutes = 10, -- PLAN.md Phase 9 acceptance
	sampleSeconds = 0.25, -- between stats() samples (the step ring holds render.statRing frames, many more)
	stuckSeconds = 3, -- docs/phase-9-contracts.md
	moveEpsilon = 0.01, -- studs: moving less than this between samples is standing still
	meanBudgetMs = 0.5,
	p95BudgetMs = 1.5,
	percentile = 0.95,
	podWaitSeconds = 20, -- for every pod's first route to arrive
	reportSeconds = 60, -- between progress lines
	maxStallsListed = 50,
}

local STATUS = "Status" -- attribute: "idle", "running", "done", "skipped", "stopped" or "failed"
local CURRENT = "Current" -- attribute: what the running test is doing now
local RESULT = "Result" -- attribute: the last result, as JSON
local CANCEL = "Cancel" -- attribute: true asks a running test to stop
local RUN_ID = "RunId" -- attribute: the id of the newest test
local LOG = "[TrafficTests]"
local SECONDS_PER_MINUTE = 60

local function round(value: number, places: number): number
	local scale = 10 ^ places
	return math.floor(value * scale + 0.5) / scale
end

local function cancelRequested(ctx: Context): boolean
	return script:GetAttribute(CANCEL) == true or script:GetAttribute(RUN_ID) ~= ctx.id
end

local function setCurrent(ctx: Context, text: string)
	if script:GetAttribute(RUN_ID) == ctx.id then
		script:SetAttribute(CURRENT, text)
	end
	print(`{LOG} {ctx.name}: {text}`)
end

local function note(ctx: Context, text: string)
	table.insert(ctx.result.notes, text)
	print(`{LOG} {ctx.name}: {text}`)
end

local function check(ctx: Context, name: string, passed: boolean, detail: string)
	table.insert(ctx.result.checks, { name = name, passed = passed, detail = detail })
	print(`{LOG} {ctx.name}: {if passed then "PASS" else "FAIL"} {name} ({detail})`)
end

-- Mean, the given percentile and the largest of a list of numbers (all 0 for an empty list).
local function summarize(values: { number }, percentile: number): (number, number, number)
	local count = #values
	if count == 0 then
		return 0, 0, 0
	end
	local sorted = table.clone(values)
	table.sort(sorted)
	local total = 0
	for _, value in sorted do
		total += value
	end
	local rank = math.clamp(math.ceil(count * percentile), 1, count)
	return total / count, sorted[rank], sorted[count]
end

-- The test --------------------------------------------------------------------------------------------------------

local function runTraffic(ctx: Context, minutes: number, opts: Options): Result
	local result = ctx.result
	result.minutes = minutes
	local expected = Traffic.pods.count

	setCurrent(ctx, `waiting for {expected} pods`)
	local waitStarted = os.clock()
	local stats = TrafficController.stats()
	while stats.pods < expected and os.clock() - waitStarted < SETTINGS.podWaitSeconds do
		if cancelRequested(ctx) then
			result.reason = "stopped"
			return result
		end
		task.wait(SETTINGS.sampleSeconds)
		stats = TrafficController.stats()
	end
	result.pods = stats.pods
	check(ctx, "pods", stats.pods >= expected, `{stats.pods} of {expected} pods have a route`)
	if stats.pods == 0 then
		result.reason = "no pods"
		return result
	end

	local renderAll = opts.renderAll ~= false
	if renderAll then
		TrafficController.setRenderAll(true)
	end

	local tracks: { [number]: Track } = {}
	local frameTimes: { number } = {}
	local lastSteps = stats.steps
	local started = os.clock()
	local seconds = minutes * SECONDS_PER_MINUTE
	local nextReport = started + SETTINGS.reportSeconds
	setCurrent(ctx, `watching {stats.pods} pods for {minutes} min`)

	while os.clock() - started < seconds and not cancelRequested(ctx) do
		task.wait(SETTINGS.sampleSeconds)
		local clock = os.clock()
		stats = TrafficController.stats()

		-- Step times since the last sample (the ring is oldest first).
		local ring = stats.stepTimes
		local fresh = math.min(stats.steps - lastSteps, #ring)
		for i = #ring - fresh + 1, #ring do
			table.insert(frameTimes, ring[i])
		end
		lastSteps = stats.steps
		result.maxVisible = math.max(result.maxVisible, stats.visible)
		result.pods = math.max(result.pods, stats.pods)

		for _, pod in stats.podStats do
			local track = tracks[pod.index]
			if track == nil then
				tracks[pod.index] = {
					seq = pod.seq,
					distance = pod.distance,
					yielding = pod.yielding,
					stillSince = clock,
					counted = false,
				}
				continue
			end
			local newRoute = pod.seq ~= track.seq
			if newRoute then
				result.routesStarted += 1
			end
			if pod.yielding and not track.yielding then
				result.yields += 1
			end
			if newRoute or math.abs(pod.distance - track.distance) > SETTINGS.moveEpsilon or pod.yielding then
				track.stillSince = clock
				track.counted = false
			elseif not track.counted and clock - track.stillSince > SETTINGS.stuckSeconds then
				track.counted = true
				result.stuck += 1
				local at = round(clock - started, 1)
				if #result.stalls < SETTINGS.maxStallsListed then
					table.insert(result.stalls, {
						pod = pod.index,
						seq = pod.seq,
						distance = round(pod.distance, 1),
						at = at,
						waiting = pod.waiting,
					})
				end
				note(
					ctx,
					`pod {pod.index} stuck on route {pod.seq} at {round(pod.distance, 1)} of {round(pod.length, 1)} studs`
						.. (if pod.waiting then " (waiting for its next route)" else "")
						.. ` at {at} s`
				)
			end
			track.seq, track.distance, track.yielding = pod.seq, pod.distance, pod.yielding
		end

		if clock >= nextReport then
			nextReport += SETTINGS.reportSeconds
			local meanMs = summarize(frameTimes, SETTINGS.percentile)
			setCurrent(
				ctx,
				`{math.floor((clock - started) / SECONDS_PER_MINUTE)} of {minutes} min: {stats.visible} drawn, `
					.. `{result.stuck} stuck, mean {round(meanMs, 3)} ms`
			)
		end
	end
	if renderAll then
		TrafficController.setRenderAll(false)
	end

	local meanMs, p95Ms, maxMs = summarize(frameTimes, SETTINGS.percentile)
	result.frames = #frameTimes
	result.meanMs = round(meanMs, 4)
	result.p95Ms = round(p95Ms, 4)
	result.maxMs = round(maxMs, 4)

	if cancelRequested(ctx) then
		result.reason = "stopped"
		return result
	end
	if renderAll then
		check(ctx, "drawn", result.maxVisible >= result.pods, `at most {result.maxVisible} of {result.pods} pods drawn`)
	end
	check(ctx, "stuck", result.stuck == 0, `{result.stuck} stuck over {minutes} min`)
	check(
		ctx,
		"frame mean",
		#frameTimes > 0 and meanMs <= SETTINGS.meanBudgetMs,
		`{result.meanMs} ms over {#frameTimes} frames (budget {SETTINGS.meanBudgetMs})`
	)
	check(
		ctx,
		"frame p95",
		#frameTimes > 0 and p95Ms <= SETTINGS.p95BudgetMs,
		`{result.p95Ms} ms (budget {SETTINGS.p95BudgetMs}; max {result.maxMs})`
	)
	note(ctx, `{result.routesStarted} routes started, {result.yields} yields to cars`)
	return result
end

-- Running a test --------------------------------------------------------------------------------------------------

local function emptyResult(name: string, reason: string): Result
	return {
		name = name,
		passed = false,
		skipped = false,
		reason = reason,
		checks = {},
		elapsed = 0,
		notes = {},
		minutes = 0,
		pods = 0,
		maxVisible = 0,
		frames = 0,
		meanMs = 0,
		p95Ms = 0,
		maxMs = 0,
		stuck = 0,
		stalls = {},
		routesStarted = 0,
		yields = 0,
	}
end

local function printResult(result: Result)
	local verdict = if result.skipped then "SKIPPED" elseif result.passed then "PASSED" else "FAILED"
	print(`{LOG} {result.name}: {verdict} ({result.reason}) in {math.floor(result.elapsed)} s`)
	local ok, encoded = pcall(HttpService.JSONEncode, HttpService, result)
	if ok then
		print(`{LOG} {result.name}: {encoded}`)
	end
end

local function runTest(name: TestName, body: (ctx: Context) -> Result): Result
	if not (RunService:IsStudio() and RunService:IsRunning() and RunService:IsClient()) then
		warn(`{LOG} runs only in a Studio playtest (Client datamodel)`)
		return emptyResult(name, "studio only")
	end
	if script:GetAttribute(STATUS) == "running" then
		warn(`{LOG} a test is already running; TrafficTests.stop() cancels it`)
		return emptyResult(name, "busy")
	end

	local ctx: Context = {
		id = HttpService:GenerateGUID(false),
		name = name,
		started = os.clock(),
		result = emptyResult(name, "done"),
	}
	script:SetAttribute(RUN_ID, ctx.id)
	script:SetAttribute(STATUS, "running")
	script:SetAttribute(CANCEL, false)
	script:SetAttribute(RESULT, nil)

	local ok, outcome = pcall(body, ctx)
	local result: Result = if ok then outcome else ctx.result
	if not ok then
		result.reason = `error: {tostring(outcome)}`
		warn(`{LOG} {name} failed: {outcome}`)
		TrafficController.setRenderAll(false)
	end
	if cancelRequested(ctx) and result.reason == "done" then
		result.reason = "stopped"
	end
	result.passed = ok and not result.skipped and result.reason == "done" and #result.checks > 0
	for _, item in result.checks do
		if not item.passed then
			result.passed = false
		end
	end
	result.elapsed = round(os.clock() - ctx.started, 1)
	printResult(result)

	if script:GetAttribute(RUN_ID) == ctx.id then
		local status = if result.reason == "stopped"
			then "stopped"
			elseif result.skipped then "skipped"
			elseif result.passed then "done"
			else "failed"
		script:SetAttribute(RESULT, HttpService:JSONEncode(result))
		script:SetAttribute(CURRENT, nil)
		script:SetAttribute(STATUS, status)
	end
	return result
end

local TrafficTests = {}
TrafficTests.SETTINGS = SETTINGS

-- Watches every pod for `minutes` (default SETTINGS.minutes): no stuck pods, and TrafficController's frame cost
-- within budget.
function TrafficTests.run(minutes: number?, opts: Options?): Result
	local length = minutes or SETTINGS.minutes
	local options: Options = opts or {}
	if type(length) ~= "number" or length <= 0 then
		warn(`{LOG} run(minutes) needs a positive number of minutes`)
		return emptyResult("run", "bad arguments")
	end
	return runTest("run", function(ctx: Context): Result
		return runTraffic(ctx, length, options)
	end)
end

local STARTERS: { [string]: (...any) -> Result } = {
	run = TrafficTests.run,
}

-- Starts a test in the background and returns at once: start("run"), start("run", 2). Poll lastResult() or watch
-- the console.
function TrafficTests.start(name: TestName, ...: any)
	local starter = STARTERS[name]
	if starter == nil then
		warn(`{LOG} unknown test "{name}"; use "run"`)
		return
	end
	task.spawn(starter, ...)
end

-- The last finished result, or nil while a test runs (or before any has finished).
function TrafficTests.lastResult(): Result?
	local encoded = script:GetAttribute(RESULT)
	if script:GetAttribute(STATUS) == "running" or type(encoded) ~= "string" then
		return nil
	end
	return HttpService:JSONDecode(encoded)
end

-- "idle", "running", "done", "skipped", "stopped" or "failed", and what the running test is doing.
function TrafficTests.status(): (string, string?)
	local status = script:GetAttribute(STATUS)
	local current = script:GetAttribute(CURRENT)
	return if type(status) == "string" then status else "idle", if type(current) == "string" then current else nil
end

-- Cancels a running test and puts the render distance back; clears a "running" status left by a test whose thread
-- died.
function TrafficTests.stop()
	if not RunService:IsStudio() then
		return
	end
	script:SetAttribute(CANCEL, true)
	TrafficController.setRenderAll(false)
	if script:GetAttribute(STATUS) == "running" then
		script:SetAttribute(STATUS, "stopped")
	end
end

return TrafficTests
