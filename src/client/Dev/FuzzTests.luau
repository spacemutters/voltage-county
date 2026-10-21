--!strict
-- Studio-only fuzz test of every client -> server remote (PLAN.md Phase 14; docs/phase-14-contracts.md "Security"). It
-- uses only what a player's client can do: it fires and invokes the real remotes, through the real network, with
-- hostile payloads, and asks the server what it made of them (Net DevFuzz, Services/DevFuzzService).
--   all(opts)  DevFuzz begin (the server starts recording its errors and warnings, Net's rejections of your calls and
--              your economy). Then every client -> server remote except the Dev* ones (they change data on purpose;
--              DevFuzz and DevPerf among them), or only opts.remotes, minus opts.skip, all at once, each in its own
--              thread:
--                1. one call with nothing and an extra argument, and one with a valid payload (SAMPLES) and an extra
--                   argument: Net refuses any call carrying more than one value;
--                2. every hostile case from cases() that this copy of Net's validator refuses (a payload it takes is
--                   a real request and is never sent; one it takes that SAMPLES says must not fit is a problem), the
--                   most telling first, spaced to the remote's rate limit for SETTINGS.paceSeconds (opts.paceSeconds)
--                   so the server's validator sees them and not just its limiter, then the rest at once. The big
--                   values (a 100k-character string, 10k keys, 10k items) go to SETTINGS.bigRemotes only, as the
--                   whole payload (opts.bigEverywhere: to every remote); tests/NetFuzz.spec tries them everywhere;
--                3. a burst of (burst + SETTINGS.extraBurst) calls back to back.
--              Invokes run in their own threads with SETTINGS.invokeTimeout, so a server that never answers can't
--              hang the run. SETTINGS.settleSeconds after the last answer, DevFuzz finish.
--              Checks, one per remote: the server refused every call (its rejections for that remote add up to at
--              least the calls sent, and no invoke came back with an answer or an error), the rate limit held (the
--              burst got at least extraBurst - perSecond x burstWindow calls refused as too many) and every invoke
--              was answered. Then: no server errors or warnings while it ran, none of your economy changed (cash,
--              credits, cars and their looks, designs, fleet pods, licenses, house, codes, season claims, streak,
--              offers, cosmetics, club, receipts, pending grants, boosts; Services/DevFuzzService) and no errors on
--              this client.
--   start("all", opts)  runs it in the background and returns at once; lastResult() returns its result once done
--              (nil while it runs), status() what it's doing, stop() cancels it.
-- The result: { name = "all", passed, reason, checks = { { name, passed, detail } }, notes, elapsed, remotes =
-- { [remote] = RemoteReport }, serverErrors, changed, clientErrors }. Every check (one line per remote, with its
-- counts) and every note is printed as it comes, so get_console_output shows them even if execute_luau stops waiting.
--
-- Run from MCP execute_luau in the Client datamodel of a playtest, once the player's data has loaded (about 40 s):
--   require(game.Players.LocalPlayer.PlayerScripts.Client.Dev.FuzzTests).start("all")
--   require(game.Players.LocalPlayer.PlayerScripts.Client.Dev.FuzzTests).lastResult()
-- Stand still on foot while it runs and have no robotaxi pods out with the Fleet Manager pass: driving earnings and
-- the pass's auto-collect change your cash on their own, which the economy check would report.
--
-- The hostile corpus (hostile()), a valid sample payload for every client -> server remote with the hostile values
-- each field may still take (SAMPLES) and the cases built from them (cases(name)) are shared with tests/NetFuzz.spec,
-- which runs every case through every validator in Edit mode and fails for a remote declared in Net.luau without a
-- sample here. A new remote needs its SAMPLES entry.
--
-- Nothing is left behind: the server's recording is stopped (DevFuzz finish) even when the run fails, errors or is
-- stopped; whether it still needs stopping lives in an attribute on this ModuleScript (Studio gives execute_luau its
-- own copy of each module, but the ModuleScript is the same), so stop() from any copy, or the next run, sweeps up.
-- Net's rate limits for your player stay drained for a few seconds after a run. Fuzz calls go straight to the remote
-- instances (Net.fireServer and Net.invokeServer send exactly one value); DevFuzz goes through this copy's own Net.
--
-- Does nothing outside a Studio playtest (CLAUDE.md hard rule 8); the server refuses DevFuzz outside Studio too. The
-- client loader never boots it.

local HttpService = game:GetService("HttpService")
local LogService = game:GetService("LogService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ScriptContext = game:GetService("ScriptContext")
local Workspace = game:GetService("Workspace")

local Net = require(ReplicatedStorage.Shared.Net)

export type TestName = "all"

export type Check = { name: string, passed: boolean, detail: string }

-- One hostile value. `tag` names it in SAMPLES' fits lists and in case labels; a `big` one (100k characters, 10k keys
-- or items) goes through the network only to SETTINGS.bigRemotes.
export type Hostile = { tag: string, value: any, big: boolean }

-- A valid payload for a client -> server remote (nil for one that carries none) and, by field path ("" for the whole
-- payload, "changes.tint" for a nested field), the tags of the hostile values that are still valid there. Only
-- FITS_TAGS may be listed: NaN, infinities, huge numbers, bad or NUL-carrying or over-long strings and odd types fit
-- nowhere.
export type Sample = { payload: any?, fits: { [string]: { string } }? }

-- One payload to try on a remote's validator, and whether it must be taken (`fits`) or refused. `root`: the hostile
-- value is the whole payload (not one field of a valid one).
export type Case = { label: string, payload: any, fits: boolean, big: boolean, root: boolean }

export type RemoteReport = {
	kind: string, -- "event" or "function"
	sent: number, -- calls that left this client, every phase
	arity: number, -- of those, calls with an extra argument
	hostile: number, -- hostile payloads
	paced: number, -- of those, sent inside the rate limit
	burst: number, -- calls in the burst
	sendFailures: number, -- calls this client couldn't send (not counted as sent, not a failure)
	sendError: string?, -- the first of those, and why
	answered: number, -- invokes the server answered with something other than nil (it ran the handler)
	invokeErrors: number, -- invokes that came back with an error
	unanswered: number, -- invokes with no answer within SETTINGS.invokeTimeout
	rejects: { [string]: number }, -- the server's rejections of your calls to it, by reason (DevFuzz finish)
	problems: { string }, -- the first SETTINGS.maxProblems
	passed: boolean,
}

export type Result = {
	name: string, -- "all"
	passed: boolean, -- every check passed and the run went to the end
	reason: string, -- "done", or why it ended early
	checks: { Check },
	notes: { string },
	elapsed: number, -- seconds
	remotes: { [string]: RemoteReport },
	serverErrors: { any }, -- DevFuzzService entries: { kind, text, source?, count }
	changed: { [string]: any }, -- economy fields that changed: { before, after }
	clientErrors: { string },
}

export type Options = {
	remotes: { string }?, -- only these remotes (default: every client -> server remote but the Dev* ones)
	skip: { string }?, -- and not these
	paceSeconds: number?, -- instead of SETTINGS.paceSeconds
	bigEverywhere: boolean?, -- send the big values to every remote, not just SETTINGS.bigRemotes
}

-- A dev tool, so its numbers live here rather than in Shared/Config (like Dev/SocialTests' SETTINGS).
local SETTINGS = {
	-- The corpus
	deepLevels = 50, -- nesting of the deep table
	wideKeys = 10000, -- keys in the wide table, items in the long list
	longChars = 100000, -- characters in the long string
	-- Sending
	paceSeconds = 20, -- per remote: hostile calls are spaced to its rate limit for this long, then the rest go at once
	tokenMargin = 0.25, -- tokens kept in hand while pacing (the server's bucket may hold a little less than ours)
	extraBurst = 10, -- the burst is the remote's burst + this many calls, back to back
	burstWindow = 1, -- seconds of refill the burst is allowed (it takes far less)
	-- One remote of each validator form gets the big values: a string, none, an event's shape, a flat shape and the
	-- nested shape with a list.
	bigRemotes = { "RedeemCode", "GetStore", "SetFavorite", "BuyVehicle", "BuyCustomization" },
	-- Waiting (seconds)
	invokeTimeout = 10, -- an invoke with no answer by then counts as unanswered
	devFuzzTimeout = 15, -- DevFuzz begin and finish
	sendTimeout = 30, -- past the pacing, longest wait for every remote's calls to go out
	settleSeconds = 3, -- after the last answer, for events still on their way, before DevFuzz finish
	recheckSeconds = 0.25, -- waits look again this often
	stopGraceSeconds = 3, -- stop(): time a running test gets to clean up before the sweep
	-- Reporting
	maxProblems = 5, -- problems kept per remote (the rest are counted)
	maxTextChars = 300, -- an error or reply text is cut to this
	maxClientErrors = 50,
}

local STATUS = "Status" -- attribute: "idle", "running", "done", "stopped" or "failed"
local CURRENT = "Current" -- attribute: what the running test is doing now
local RESULT = "Result" -- attribute: the last result, as JSON
local CANCEL = "Cancel" -- attribute: true asks a running test to stop
local RUN_ID = "RunId" -- attribute: the id of the newest run
local RECORDING = "Recording" -- attribute: true while the server records for this run (DevFuzz finish in the cleanup)
local LOG = "[FuzzTests]"
local REMOTES_FOLDER = "Remotes" -- where Net puts the remotes, under ReplicatedStorage
local DEV_PREFIX = "Dev" -- Studio-only remotes: never fuzzed here (they change data on purpose)
local EXTRA_ARG = "fuzz-extra"
-- -0, made at run time: one the compiler folded into a constant could come out as plain 0.
local ZERO = { value = 0 }
local NEGATIVE_ZERO = -ZERO.value

-- The hostile tags SAMPLES may list as still valid somewhere.
local FITS_TAGS = { "nil", "-0", "fraction", "negative", "true", "false", "emptyString", "emptyTable" }

---------------------------------------------------------------------------------------------------------------
-- The corpus
---------------------------------------------------------------------------------------------------------------

local ID = "fuzz-id" -- any id a validator takes; nothing in the catalog, a garage or the map has it
local OPTIONAL = { "nil" }
local UNIT = { "-0", "fraction" } -- a number in 0..1 (or 0..24)
local OPTIONAL_UNIT = { "nil", "-0", "fraction" }

-- A valid payload for every client -> server remote in Net.luau (tests/NetFuzz.spec fails for one that is missing).
local SAMPLES: { [string]: Sample } = {
	DevSpawnVehicle = { payload = { vehicleId = ID, trim = ID } },
	RedeemCode = { payload = "FUZZ" },
	BuyVehicle = { payload = { vehicleId = ID, trim = ID } },
	UpgradeVehicle = { payload = { uid = ID, trim = ID } },
	StartTestDrive = { payload = { vehicleId = ID, trim = ID } },
	ClaimStarter = {},
	GetUsedLot = {},
	BuyUsed = { payload = { slot = 1, date = "2000-01-01", maxPrice = 1000 } },
	SpawnOwned = { payload = { uid = ID } },
	DespawnOwned = {},
	SellVehicle = { payload = { uid = ID } },
	SetFavorite = { payload = { uid = ID, favorite = true }, fits = { favorite = { "true", "false" } } },
	UpdateSettings = {
		payload = { units = "mph", camera = "chase", musicVolume = 0.5 },
		fits = { [""] = { "emptyTable" }, units = OPTIONAL, camera = OPTIONAL, musicVolume = OPTIONAL_UNIT },
	},
	JobAction = {
		payload = { action = "refresh", offerId = ID, jobId = ID },
		fits = { offerId = OPTIONAL, jobId = OPTIONAL },
	},
	BuyCustomization = {
		payload = {
			uid = ID,
			changes = {
				paint = ID,
				customColor = { h = 0.5, s = 0.5, v = 0.5 },
				finish = ID,
				wrap = ID,
				wheels = ID,
				rideHeight = 0.5,
				tint = 0.5,
				caliper = ID,
				extras = { ID },
				plateFormat = ID,
			},
		},
		fits = {
			changes = { "emptyTable" },
			["changes.paint"] = OPTIONAL,
			["changes.customColor"] = OPTIONAL,
			["changes.customColor.h"] = UNIT,
			["changes.customColor.s"] = UNIT,
			["changes.customColor.v"] = UNIT,
			["changes.finish"] = OPTIONAL,
			["changes.wrap"] = OPTIONAL,
			["changes.wheels"] = OPTIONAL,
			["changes.rideHeight"] = { "nil", "-0", "fraction", "negative" }, -- -1..1
			["changes.tint"] = OPTIONAL_UNIT,
			["changes.caliper"] = OPTIONAL,
			["changes.extras"] = { "nil", "emptyTable" },
			["changes.plateFormat"] = OPTIONAL,
		},
	},
	SetPlate = { payload = { uid = ID, text = "FUZZ" }, fits = { text = { "emptyString" } } }, -- "": standard plate
	JoinLightShow = { payload = { meetSpotId = ID } },
	LeaveLightShow = {},
	TrailerAction = { payload = { action = "decouple" } },
	BuyLicense = { payload = { license = "freight" } },
	BuyPod = { payload = { zone = ID } },
	AssignPod = { payload = { uid = ID, zone = ID } },
	CollectFleet = {},
	SellPod = { payload = { uid = ID } },
	HailPod = { payload = { destinationId = ID } },
	UseAbility = { payload = { ability = "boostHop" } },
	GetDragLeaderboard = {},
	DesignCar = { payload = { prompt = "a small blue hatchback", classId = ID }, fits = { classId = OPTIONAL } },
	ModCar = { payload = { uid = ID, prompt = "a red roof rack" } },
	DesignChoice = { payload = { requestId = ID, choice = "discard" } },
	ReportDesign = { payload = { uid = ID, reason = ID } },
	HideDesign = { payload = { designUid = ID } },
	DevCredits = { payload = { amount = 10 } },
	BuyProduct = { payload = { key = ID } },
	BuyPass = { payload = { key = ID } },
	JoinClub = {},
	GetStore = {},
	BuyLimited = { payload = { dropId = ID } },
	ClaimStreak = {},
	ClaimSeasonReward = { payload = { tier = 1, track = "free" } },
	WatchAdReward = {},
	AdminAction = {
		payload = { action = "logs", targetUserId = 1, ref = ID },
		fits = { targetUserId = OPTIONAL, ref = OPTIONAL },
	},
	DevPurchase = { payload = { key = ID, purchaseId = ID }, fits = { purchaseId = OPTIONAL } },
	ClaimHouse = { payload = { plotId = ID } },
	LeaveHouse = {},
	BuyHouseUpgrade = { payload = { upgrade = ID } },
	DevSocial = { payload = { action = "clearDummies", meetSpotId = ID }, fits = { meetSpotId = OPTIONAL } },
	DevAbility = { payload = { action = "resetCooldowns" } },
	DevFleet = { payload = { action = "simulateOffline", hours = 1 }, fits = { hours = UNIT } },
	DevJob = { payload = { action = "grantLicenseXp" } },
	DevSetEnergy = { payload = { level = 0.5 }, fits = { level = UNIT } },
	DevSetCash = { payload = { amount = 100 } },
	DevFuzz = { payload = { action = "finish" } },
	DevPerf = { payload = { action = "stop" } },
}

local hostileList: { Hostile }? = nil

-- Every hostile value, built once. The ones a wire could change come first: a paced remote may only get a few of
-- its cases past its rate limit to the validator.
local function hostile(): { Hostile }
	local cached = hostileList
	if cached ~= nil then
		return cached
	end
	local deep: any = { leaf = true }
	for _ = 2, SETTINGS.deepLevels do
		deep = { next = deep }
	end
	local wide: { [string]: boolean } = {}
	for index = 1, SETTINGS.wideKeys do
		wide[`k{index}`] = true
	end
	-- A list with a named key as well, on purpose (built in two steps so the linter knows it is meant).
	local mixed: { [any]: any } = { 1, 2 }
	mixed.fuzz = true
	local list: { Hostile } = {
		{ tag = "nan", value = 0 / 0, big = false },
		{ tag = "-0", value = NEGATIVE_ZERO, big = false },
		{ tag = "inf", value = math.huge, big = false },
		{ tag = "-inf", value = -math.huge, big = false },
		{ tag = "badUtf8", value = "\255\254fuzz", big = false },
		{ tag = "nulString", value = "fuzz\0id", big = false },
		{ tag = "instance", value = Workspace, big = false },
		{ tag = "mixedTable", value = mixed, big = false },
		{ tag = "vector3", value = Vector3.new(1, 2, 3), big = false },
		{ tag = "cframe", value = CFrame.new(1, 2, 3), big = false },
		{ tag = "color3", value = Color3.new(1, 0, 0), big = false },
		{ tag = "emptyString", value = "", big = false },
		{ tag = "emptyTable", value = {}, big = false },
		{ tag = "fraction", value = 0.5, big = false },
		{ tag = "negative", value = -1, big = false },
		{ tag = "huge", value = 1e300, big = false },
		{ tag = "bigInt", value = 2 ^ 63, big = false },
		{ tag = "true", value = true, big = false },
		{ tag = "false", value = false, big = false },
		{ tag = "nil", value = nil, big = false },
		{ tag = "array", value = { 1, 2, 3 }, big = false },
		{ tag = "deepTable", value = deep, big = false },
		{ tag = "longString", value = string.rep("a", SETTINGS.longChars), big = true },
		{ tag = "wideTable", value = wide, big = true },
		{ tag = "longArray", value = table.create(SETTINGS.wideKeys, "a"), big = true },
	}
	hostileList = list
	return list
end

-- A copy of a sample (hostile values are shared, never copied).
local function copy(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local result = {}
	for key, item in value do
		result[key] = copy(item)
	end
	return result
end

-- A table with string keys only (a payload shape, not a list).
local function isShape(value: any): boolean
	if type(value) ~= "table" or next(value) == nil then
		return false
	end
	for key in value do
		if type(key) ~= "string" then
			return false
		end
	end
	return true
end

local function valueAt(root: any, path: { string }): any
	local node = root
	for _, key in path do
		node = node[key]
	end
	return node
end

-- A copy of `root` with `value` at `path` (nil removes the field).
local function withValue(root: any, path: { string }, value: any): any
	local result = copy(root)
	local node = result
	for index = 1, #path - 1 do
		node = node[path[index]]
	end
	node[path[#path]] = value
	return result
end

-- A copy of `root` with one key the shape at `level` doesn't declare.
local function withExtra(root: any, level: { string }, key: any): any
	local result = copy(root)
	valueAt(result, level)[key] = true
	return result
end

-- Every field path in a shape, sorted, nested shapes included (a list is one field).
local function collectPaths(shape: any, prefix: { string }, into: { { string } })
	local keys: { string } = {}
	for key in shape do
		table.insert(keys, key)
	end
	table.sort(keys)
	for _, key in keys do
		local path = table.clone(prefix)
		table.insert(path, key)
		table.insert(into, path)
		if isShape(shape[key]) then
			collectPaths(shape[key], path, into)
		end
	end
end

-- The cases for one remote, or nil when it has no sample: its valid sample, every hostile value as the whole
-- payload, an undeclared key (a string and a number) in every shape level, and for a shape, the sample with each
-- field (nested ones too) swapped for each hostile value. Each says whether its validator must take it.
local function cases(name: string): { Case }?
	local sample = SAMPLES[name]
	if sample == nil then
		return nil
	end
	local fits = sample.fits or {}
	local function fitsAt(path: string, tag: string): boolean
		local list = fits[path]
		return list ~= nil and table.find(list, tag) ~= nil
	end
	local payload = sample.payload
	local list: { Case } = { { label = "valid", payload = copy(payload), fits = true, big = false, root = true } }
	for _, item in hostile() do
		local taken = fitsAt("", item.tag) or (payload == nil and item.tag == "nil")
		local case: Case =
			{ label = `payload {item.tag}`, payload = item.value, fits = taken, big = item.big, root = true }
		table.insert(list, case)
	end
	if not isShape(payload) then
		return list
	end
	local paths: { { string } } = {}
	collectPaths(payload, {}, paths)
	local levels: { { string } } = { {} }
	for _, path in paths do
		if isShape(valueAt(payload, path)) then
			table.insert(levels, path)
		end
	end
	for _, level in levels do
		local where = if #level == 0 then "payload" else table.concat(level, ".")
		local named: Case = {
			label = `{where} + key`,
			payload = withExtra(payload, level, "fuzzExtra"),
			fits = false,
			big = false,
			root = false,
		}
		local numbered: Case =
			{ label = `{where} + [1]`, payload = withExtra(payload, level, 1), fits = false, big = false, root = false }
		table.insert(list, named)
		table.insert(list, numbered)
	end
	for _, path in paths do
		local where = table.concat(path, ".")
		for _, item in hostile() do
			table.insert(list, {
				label = `{where} {item.tag}`,
				payload = withValue(payload, path, item.value),
				fits = fitsAt(where, item.tag),
				big = item.big,
				root = false,
			})
		end
	end
	return list
end

---------------------------------------------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------------------------------------------

type Context = { id: string, label: string, started: number, keepGoing: boolean }

type RemoteRun = {
	name: string,
	spec: Net.Spec,
	remote: Instance?,
	report: RemoteReport,
	pending: number, -- invokes still out
	moreProblems: number, -- problems past SETTINGS.maxProblems
}

-- Text that is safe to print and to JSON-encode: bytes above 127 become "?", and it is cut to maxTextChars.
local function clean(text: string): string
	local ascii = string.gsub(text, "[\128-\255]", "?")
	if #ascii > SETTINGS.maxTextChars then
		return string.sub(ascii, 1, SETTINGS.maxTextChars) .. "..."
	end
	return ascii
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
	return {
		name = name,
		passed = false,
		reason = "done",
		checks = {},
		notes = {},
		elapsed = 0,
		remotes = {},
		serverErrors = {},
		changed = {},
		clientErrors = {},
	}
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
	return result
end

-- Waiting ------------------------------------------------------------------------------------------------------

-- Waits until `test()` is true, looking again every SETTINGS.recheckSeconds, for at most `timeout` seconds; a cancel
-- ends the wait too. Returns whether `test()` came true.
local function waitUntil(ctx: Context, test: () -> boolean, timeout: number): boolean
	local deadline = os.clock() + timeout
	while not test() do
		if os.clock() >= deadline or cancelRequested(ctx) then
			return false
		end
		task.wait(math.min(SETTINGS.recheckSeconds, math.max(deadline - os.clock(), 0)))
	end
	return true
end

-- Waits `seconds`; false when the test was cancelled meanwhile.
local function pause(ctx: Context, seconds: number): boolean
	waitUntil(ctx, function(): boolean
		return false
	end, seconds)
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

-- Calls a function remote through Net with one value. Returns its reply (nil when Net refused it) and whether it
-- answered at all within `timeout`.
local function invoke(name: string, payload: any?, timeout: number): (any, boolean)
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
	task.delay(timeout, function()
		finish(nil, false)
	end)
	if not done then
		waiting = coroutine.running()
		coroutine.yield()
	end
	return reply, answered
end

local function describe(reply: any, answered: boolean): string
	if not answered then
		return "no answer"
	elseif type(reply) == "table" and type(reply.message) == "string" then
		return clean(reply.message)
	end
	return clean(tostring(reply))
end

-- Stops the server's recording if this run (or an earlier one whose thread died) left it on.
local function sweepLeftovers(): { string }
	local notes: { string } = {}
	if script:GetAttribute(RECORDING) == true then
		local _, answered = invoke("DevFuzz", { action = "finish" }, SETTINGS.devFuzzTimeout)
		script:SetAttribute(RECORDING, nil)
		table.insert(notes, if answered then "stopped the server's recording" else "DevFuzz finish got no answer")
	end
	return notes
end

---------------------------------------------------------------------------------------------------------------
-- The run
---------------------------------------------------------------------------------------------------------------

local function newReport(kind: string): RemoteReport
	return {
		kind = kind,
		sent = 0,
		arity = 0,
		hostile = 0,
		paced = 0,
		burst = 0,
		sendFailures = 0,
		answered = 0,
		invokeErrors = 0,
		unanswered = 0,
		rejects = {},
		problems = {},
		passed = false,
	}
end

local function addProblem(run: RemoteRun, text: string)
	if #run.report.problems >= SETTINGS.maxProblems then
		run.moreProblems += 1
		return
	end
	table.insert(run.report.problems, text)
end

-- The client -> server remotes this run fuzzes: every one but the Dev* ones, narrowed by the options. Sorted.
local function chosenRemotes(options: Options): { string }
	local names: { string } = {}
	for name, spec in Net.declared() do
		local wanted = options.remotes == nil or table.find(options.remotes, name) ~= nil
		local skipped = options.skip ~= nil and table.find(options.skip, name) ~= nil
		local dev = string.sub(name, 1, #DEV_PREFIX) == DEV_PREFIX
		if spec.direction == "toServer" and wanted and not skipped and not dev then
			table.insert(names, name)
		end
	end
	table.sort(names)
	return names
end

-- The cases to send to one remote: the ones its validator must refuse and this copy of it does refuse (a big value
-- only as the whole payload, and only when `big`). Also the labels of cases it wrongly takes (never sent).
local function sendable(name: string, spec: Net.Spec, big: boolean): ({ Case }?, { string })
	local all = cases(name)
	if all == nil then
		return nil, {}
	end
	local list: { Case } = {}
	local wrong: { string } = {}
	for _, case in all do
		if not case.fits and (not case.big or (big and case.root)) then
			local ok, taken = pcall(spec.validate, case.payload)
			if not ok then
				table.insert(wrong, `{case.label} (its validator threw)`)
			elseif taken then
				table.insert(wrong, case.label)
			else
				table.insert(list, case)
			end
		end
	end
	return list, wrong
end

-- Sends one call (one value, or two for `count` = 2) straight to the remote instance. An invoke runs in its own
-- thread and counts as unanswered after SETTINGS.invokeTimeout.
local function send(run: RemoteRun, label: string, count: number, first: any, second: any)
	local report = run.report
	if run.spec.kind == "event" then
		local event = run.remote :: any
		local ok, err = pcall(function()
			if count == 2 then
				event:FireServer(first, second)
			else
				event:FireServer(first)
			end
		end)
		if ok then
			report.sent += 1
		else
			-- This client's own refusal (a value the wire can't carry), not the server's: noted, not a failure.
			report.sendFailures += 1
			if report.sendError == nil then
				report.sendError = `{label}: {clean(tostring(err))}`
			end
		end
		return
	end
	local fn = run.remote :: any
	report.sent += 1
	run.pending += 1
	local settled = false
	task.delay(SETTINGS.invokeTimeout, function()
		if not settled then
			settled = true
			run.pending -= 1
			report.unanswered += 1
		end
	end)
	task.spawn(function()
		-- An error thrown before the call yields never left this client (a value the wire can't carry); the deferred
		-- function only runs once the call has yielded, on its way to the server.
		local beforeSending = true
		task.defer(function()
			beforeSending = false
		end)
		local ok, reply = pcall(function(): any
			if count == 2 then
				return fn:InvokeServer(first, second)
			end
			return fn:InvokeServer(first)
		end)
		if settled then
			return
		end
		settled = true
		run.pending -= 1
		if not ok and beforeSending then
			report.sent -= 1
			report.sendFailures += 1
			if report.sendError == nil then
				report.sendError = `{label}: {clean(tostring(reply))}`
			end
		elseif not ok then
			report.invokeErrors += 1
			addProblem(run, `{label} came back with an error: {clean(tostring(reply))}`)
		elseif reply ~= nil then
			report.answered += 1
			addProblem(run, `{label} was answered (the server ran its handler)`)
		end
	end)
end

-- Everything one remote gets: the extra-argument calls, the hostile cases (paced until `deadline`), the burst.
local function runRemote(ctx: Context, run: RemoteRun, list: { Case }, sample: any, deadline: number)
	local spec = run.spec
	local report = run.report
	-- 1. An extra argument (Net checks the count before the rate limit, so these cost no tokens).
	send(run, "nothing + an extra argument", 2, nil, EXTRA_ARG)
	report.arity += 1
	if sample ~= nil then
		send(run, "the valid sample + an extra argument", 2, copy(sample), EXTRA_ARG)
		report.arity += 1
	end
	-- 2. The hostile cases, spaced to the rate limit (a token bucket like the server's) until the deadline.
	local need = math.min(1 + SETTINGS.tokenMargin, spec.burst)
	local tokens = spec.burst
	local last = os.clock()
	for _, case in list do
		if cancelRequested(ctx) then
			return
		end
		local now = os.clock()
		if now < deadline and spec.perSecond > 0 then
			tokens = math.min(spec.burst, tokens + (now - last) * spec.perSecond)
			last = now
			local waitSeconds = (need - tokens) / spec.perSecond
			if tokens < need and now + waitSeconds <= deadline then
				if not pause(ctx, waitSeconds) then
					return
				end
				local after = os.clock()
				tokens = math.min(spec.burst, tokens + (after - last) * spec.perSecond)
				last = after
			end
			if tokens >= 1 then
				tokens -= 1
				report.paced += 1
			end
		end
		send(run, case.label, 1, case.payload, nil)
		report.hostile += 1
	end
	-- 3. A burst over the limit, all at once.
	local payload = if #list > 0 then list[1].payload else 0 / 0
	for _ = 1, spec.burst + SETTINGS.extraBurst do
		send(run, "the burst", 1, payload, nil)
		report.burst += 1
	end
end

-- One remote's check, from what was sent and the server's rejections for it.
local function judge(result: Result, run: RemoteRun, rejects: { [string]: number }?)
	local report = run.report
	local counts: { [string]: number } = rejects or {}
	report.rejects = counts
	local refused = 0
	for _, count in counts do
		refused += count
	end
	if report.sent > refused then
		addProblem(run, `{report.sent - refused} of {report.sent} calls weren't refused (or never reached the server)`)
	end
	local needed = math.max(1, SETTINGS.extraBurst - math.ceil(run.spec.perSecond * SETTINGS.burstWindow))
	local rate = counts.rate or 0
	if report.burst > 0 and rate < needed then
		addProblem(run, `only {rate} calls refused as too many (the burst should give at least {needed})`)
	end
	if report.unanswered > 0 then
		addProblem(run, `{report.unanswered} invokes got no answer in {SETTINGS.invokeTimeout} s`)
	end
	report.passed = #report.problems == 0 and run.moreProblems == 0
	local detail = `{report.kind}: sent {report.sent} ({report.arity} with an extra argument, {report.hostile} `
		.. `hostile of which {report.paced} paced, {report.burst} in the burst); refused {refused} (payload `
		.. `{counts.payload or 0}, rate {rate}, arity {counts.arity or 0})`
	if report.kind == "function" then
		detail ..= `; answered {report.answered}, errors {report.invokeErrors}, no answer {report.unanswered}`
	end
	if report.sendFailures > 0 then
		detail ..= `; {report.sendFailures} couldn't be sent from here (first: {report.sendError})`
	end
	if #report.problems > 0 then
		detail ..= ` - {table.concat(report.problems, "; ")}`
		if run.moreProblems > 0 then
			detail ..= ` (and {run.moreProblems} more)`
		end
	end
	result.remotes[run.name] = report
	check(result, run.name, report.passed, detail)
end

-- Starts watching this client's log for errors (LogService and ScriptContext), into `errors`.
local function watchClient(errors: { string }): { RBXScriptConnection }
	local seen: { [string]: boolean } = {}
	local function add(text: string)
		if seen[text] or #errors >= SETTINGS.maxClientErrors then
			return
		end
		seen[text] = true
		table.insert(errors, clean(text))
	end
	return {
		LogService.MessageOut:Connect(function(message: string, messageType: Enum.MessageType)
			if messageType == Enum.MessageType.MessageError then
				add(message)
			end
		end),
		ScriptContext.Error:Connect(function(message: string)
			add(message)
		end),
	}
end

local function fuzzSteps(ctx: Context, result: Result, options: Options, clientErrors: { string })
	ensureNet()
	local folder = ReplicatedStorage:FindFirstChild(REMOTES_FOLDER)
	local names = chosenRemotes(options)
	local asked: { string } = options.remotes or {}
	for _, name in asked do
		if string.sub(name, 1, #DEV_PREFIX) == DEV_PREFIX then
			note(result, `{name} isn't fuzzed: the Dev* remotes change data on purpose`)
		end
	end
	if #names == 0 then
		result.reason = "no remotes to fuzz"
		return
	end

	setCurrent(ctx, `DevFuzz begin ({#names} remotes)`)
	local began, beganAnswered = invoke("DevFuzz", { action = "begin" }, SETTINGS.devFuzzTimeout)
	local recording = beganAnswered and type(began) == "table" and began.ok == true
	check(result, "DevFuzz begin", recording, describe(began, beganAnswered))
	if not recording then
		result.reason = "the server didn't start recording"
		return
	end
	script:SetAttribute(RECORDING, true)

	local declared = Net.declared()
	local paceSeconds = options.paceSeconds or SETTINGS.paceSeconds
	local deadline = os.clock() + paceSeconds
	local runs: { RemoteRun } = {}
	local running = 0
	for _, name in names do
		local spec = declared[name]
		local remote = if folder ~= nil then folder:FindFirstChild(name) else nil
		local run: RemoteRun =
			{ name = name, spec = spec, remote = remote, report = newReport(spec.kind), pending = 0, moreProblems = 0 }
		table.insert(runs, run)
		local big = options.bigEverywhere == true or table.find(SETTINGS.bigRemotes, name) ~= nil
		local list, wrong = sendable(name, spec, big)
		for _, label in wrong do
			addProblem(run, `its validator takes {label} (not sent)`)
		end
		if remote == nil then
			addProblem(run, "no remote instance under ReplicatedStorage." .. REMOTES_FOLDER)
		elseif list == nil then
			addProblem(run, "no sample in FuzzTests.SAMPLES")
		else
			running += 1
			local sample = (SAMPLES[name] :: Sample).payload
			task.spawn(function()
				local ok, err = pcall(runRemote :: any, ctx, run, list, sample, deadline)
				if not ok then
					addProblem(run, `the run failed: {clean(tostring(err))}`)
				end
				running -= 1
			end)
		end
	end

	setCurrent(ctx, `fuzzing {running} remotes (about {paceSeconds} s)`)
	waitUntil(ctx, function(): boolean
		return running == 0
	end, paceSeconds + SETTINGS.sendTimeout)
	setCurrent(ctx, "waiting for the last answers")
	waitUntil(ctx, function(): boolean
		for _, run in runs do
			if run.pending > 0 then
				return false
			end
		end
		return true
	end, SETTINGS.invokeTimeout + SETTINGS.recheckSeconds * 4)
	if not cancelRequested(ctx) then
		pause(ctx, SETTINGS.settleSeconds)
	end

	setCurrent(ctx, "DevFuzz finish")
	local finished, finishAnswered = invoke("DevFuzz", { action = "finish" }, SETTINGS.devFuzzTimeout)
	script:SetAttribute(RECORDING, nil)
	local reply: any = if finishAnswered and type(finished) == "table" then finished else {}
	check(result, "DevFuzz finish", reply.ok == true, describe(finished, finishAnswered))

	local rejects: { [string]: any } = if type(reply.rejects) == "table" then reply.rejects else {}
	for _, run in runs do
		judge(result, run, rejects[run.name])
	end

	local errors: { any } = if type(reply.errors) == "table" then reply.errors else {}
	local dropped = if type(reply.dropped) == "number" then reply.dropped else 0
	result.serverErrors = errors
	for _, entry in errors do
		local count = if type(entry.count) == "number" and entry.count > 1 then ` x{entry.count}` else ""
		local source = if type(entry.source) == "string" then ` ({entry.source})` else ""
		note(result, `server {tostring(entry.kind)}{count}: {tostring(entry.text)}{source}`)
	end
	check(
		result,
		"no server errors or warnings",
		finishAnswered and #errors == 0 and dropped == 0,
		`{#errors} distinct lines{if dropped > 0 then `, {dropped} more not kept` else ""}`
	)

	local changed: { [string]: any } = if type(reply.changed) == "table" then reply.changed else {}
	result.changed = changed
	local fields: { string } = {}
	for field, change in changed do
		table.insert(fields, field)
		note(result, `{field} changed: {tostring(change.before)} -> {tostring(change.after)}`)
	end
	table.sort(fields)
	check(
		result,
		"your economy unchanged",
		reply.ok == true and #fields == 0,
		if #fields == 0 then "cash, credits, cars, designs and the rest as before" else table.concat(fields, ", ")
	)

	result.clientErrors = table.clone(clientErrors)
	for _, text in clientErrors do
		note(result, `client error: {text}`)
	end
	check(result, "no client errors", #clientErrors == 0, `{#clientErrors} errors`)
end

local function fuzzAll(ctx: Context, options: Options): Result
	local started = os.clock()
	local result = newResult("all")
	for _, text in sweepLeftovers() do
		note(result, `an earlier run: {text}`)
	end
	local clientErrors: { string } = {}
	local connections = watchClient(clientErrors)
	local ok, err = pcall(fuzzSteps :: any, ctx, result, options, clientErrors)
	if not ok then
		result.reason = `error: {clean(tostring(err))}`
		warn(`{LOG} all failed: {err}`)
	end
	for _, connection in connections do
		connection:Disconnect()
	end
	for _, text in sweepLeftovers() do
		note(result, text)
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
		then "a test is already running; FuzzTests.stop() cancels it"
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

local FuzzTests = {}
FuzzTests.SETTINGS = SETTINGS
FuzzTests.SAMPLES = SAMPLES
FuzzTests.FITS_TAGS = FITS_TAGS
FuzzTests.hostile = hostile
FuzzTests.cases = cases

-- The client -> server remotes a run with these options would fuzz.
function FuzzTests.remoteNames(opts: Options?): { string }
	return chosenRemotes(opts or {})
end

-- Fuzzes every client -> server remote but the Dev* ones (see the header).
function FuzzTests.all(opts: Options?): Result
	local refused = refusal()
	if refused ~= nil then
		return refusedResult("all", refused)
	end
	local ctx = openRun("all")
	local result = fuzzAll(ctx, opts or {})
	closeRun(ctx, result.passed, result)
	return result
end

local STARTERS: { [string]: (opts: Options?) -> any } = {
	all = FuzzTests.all,
}

-- Starts "all" in the background and returns at once. Poll lastResult() or watch the console.
function FuzzTests.start(name: TestName, opts: Options?)
	local starter = STARTERS[name]
	if starter == nil then
		warn(`{LOG} unknown test "{name}"; use "all"`)
		return
	end
	task.spawn(starter, opts)
end

-- The last finished Result, or nil while a test runs (or before any has finished).
function FuzzTests.lastResult(): any
	local encoded = script:GetAttribute(RESULT)
	if script:GetAttribute(STATUS) == "running" or type(encoded) ~= "string" then
		return nil
	end
	return HttpService:JSONDecode(encoded)
end

-- "idle", "running", "done", "stopped" or "failed", and what the running test is doing.
function FuzzTests.status(): (string, string?)
	local status = script:GetAttribute(STATUS)
	local current = script:GetAttribute(CURRENT)
	return if type(status) == "string" then status else "idle", if type(current) == "string" then current else nil
end

-- Cancels a running test (it stops the server's recording itself). A moment later it sweeps up anything still left
-- (a test whose thread died can't) and clears a "running" status that nothing will finish.
function FuzzTests.stop()
	if not (RunService:IsStudio() and RunService:IsClient()) then
		return
	end
	script:SetAttribute(CANCEL, true)
	task.delay(SETTINGS.stopGraceSeconds, function()
		local ctx = cleanupContext()
		if script:GetAttribute(STATUS) == "running" then
			-- Give the run's own cleanup a moment longer, then make sure the recording is off.
			waitUntil(ctx, function(): boolean
				return script:GetAttribute(STATUS) ~= "running"
			end, SETTINGS.stopGraceSeconds)
		end
		sweepLeftovers()
		if script:GetAttribute(STATUS) == "running" then
			script:SetAttribute(STATUS, "stopped")
		end
	end)
end

return FuzzTests
