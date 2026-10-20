--!strict
-- Studio-only robotaxi fleet tests (PLAN.md Phase 9; docs/phase-9-contracts.md "Studio test FleetTests"). Like
-- Dev/ShopTests they need no bridge: they call the real remotes from the client (DevSetCash, BuyPod, CollectFleet,
-- SellPod and the Studio-only DevFleet), so they test the real server path (Net validation and rate limits,
-- FleetService and its Earnings, EconomyService, the save), and they read the fleet from the ProfileSnapshot the
-- server sends after every change (its `fleet` field, checked with ProfileController.normalizeFleet):
--   buy(opts)      sets the cash to the pod price plus SETTINGS.spareCash (DevSetCash), buys a pod in opts.zone
--                  (default: the busiest zone), and checks the pod count went up by one, the new pod drives in that
--                  zone, and the cash dropped by exactly the pod price. Keeps the pod; puts the cash back.
--   offline(opts)  makes sure there's a pod (buys one when there's none), collects whatever is waiting, then asks
--                  DevFleet simulateOffline for opts.hours (SETTINGS.offlineHours, 2 h) and collects again. That
--                  pay, less what was already waiting, must be about hours x the snapshot's offlineRate x the pods'
--                  online rate (each pod's zone's perHour), within opts.tolerance (SETTINGS.tolerance).
--   cap(opts)      the same for SETTINGS.capTestHours (20 h): pays about offlineCapHours (8 h) worth, never more.
--   sell(opts)     sells the newest pod: the cash rises by exactly the snapshot's sellBack, which is Config/Garage
--                  sellBackRate (60 %, like cars) of the pod price, and the pod is gone.
--   all(opts)      the four in that order.
--   start(name, ...)  runs any of them in the background and returns at once; lastResult() returns its result once
--                  done (nil while it runs), status() what it's doing, stop() cancels it (like Dev/FreightTests).
-- Each returns a Result: { name, passed, skipped, reason, checks, notes, elapsed } plus the test's numbers; all()
-- returns one whose checks are every test's. Every check is printed as it finishes, so get_console_output shows
-- them even if execute_luau stops waiting.
--
-- How the pay is measured: the seconds between the snapshot read before simulateOffline and the collect after it
-- also earn at the online rate, and the server varies each pod's hour (seeded), so the tolerance is generous. A
-- collect refused soon after the last one (FleetService's collection cooldown) is tried again every
-- SETTINGS.collectRetrySeconds until SETTINGS.collectTimeout. Every test puts the cash back to what it was
-- (opts.cleanup = false keeps the test's cash).
--
-- Run from MCP execute_luau in the Client datamodel of a playtest, once the player's data has loaded:
--   require(game.Players.LocalPlayer.PlayerScripts.Client.Dev.FleetTests).start("all")
--   require(game.Players.LocalPlayer.PlayerScripts.Client.Dev.FleetTests).start("offline")
--   require(game.Players.LocalPlayer.PlayerScripts.Client.Dev.FleetTests).status()
--   require(game.Players.LocalPlayer.PlayerScripts.Client.Dev.FleetTests).lastResult()
--
-- Remotes go through this copy's own Net (set up on first use, as Dev/ShopTests does), and this copy listens to
-- ProfileSnapshot itself. State every copy must see (running, cancel, the last result) lives in attributes on this
-- ModuleScript. Does nothing outside Studio (CLAUDE.md hard rule 8); the server refuses DevSetCash and DevFleet
-- outside Studio too. The client loader never boots it.

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage.Shared
local Economy = require(Shared.Config.Economy)
local Garage = require(Shared.Config.Garage)
local Net = require(Shared.Net)
local ProfileController = require(script.Parent.Parent.Controllers.ProfileController)

type Fleet = ProfileController.Fleet

export type TestName = "buy" | "offline" | "cap" | "sell" | "all"

export type Options = {
	zone: string?, -- buy: the zone to buy in (default: the busiest one in the snapshot)
	hours: number?, -- offline: hours away (default SETTINGS.offlineHours)
	tolerance: number?, -- offline, cap: share either side of the expected pay that passes (default SETTINGS.tolerance)
	cleanup: boolean?, -- put the cash back afterwards (default true)
}

export type Check = { name: string, passed: boolean, detail: string }

export type Result = {
	name: string,
	passed: boolean,
	skipped: boolean, -- the test couldn't run here (the reason says why); not a failure of the game
	reason: string, -- "done", or why it ended early
	checks: { Check },
	notes: { string },
	elapsed: number,
	-- buy, sell
	uid: string?, -- the pod bought or sold
	zone: string?, -- the zone it was bought in
	podPrice: number?,
	podsBefore: number?,
	podsAfter: number?,
	cashBefore: number?,
	cashAfter: number?,
	-- offline, cap
	pods: number?, -- pods earning
	hours: number?, -- hours away asked for
	offlineRate: number?,
	offlineCapHours: number?,
	perHour: number?, -- the pods' online rate together, $ an hour
	expected: number?, -- the offline pay the rule gives
	waiting: number?, -- uncollected just before simulateOffline
	collected: number?, -- what the collect after it paid
	offlinePay: number?, -- collected less waiting
	devAmount: number?, -- what DevFleet said it added, when it said
	ratio: number?, -- offlinePay / expected
	-- sell
	sellBack: number?,
	expectedSellBack: number?,
}

-- A dev tool, so its numbers live here rather than in Shared/Config (like Dev/ShopTests' SETTINGS).
local SETTINGS = {
	waitSeconds = 10, -- longest wait for a snapshot or the cash to show a change
	checkInterval = 0.1, -- seconds between looks while waiting
	-- Seconds between calls to one remote, inside Net's rate limits (BuyPod and SellPod allow one every 2 s after
	-- a small burst, CollectFleet the same, DevSetCash and DevFleet one a second).
	callGap = 2.2,
	spareCash = 1000, -- buy(): cash left after the pod, so "the cash dropped by the price" can't be a floor at $0
	offlineHours = 2, -- docs/phase-9-contracts.md: offline() simulates 2 h away
	capTestHours = 20, -- ...and cap() 20 h, well past the 8 h cap
	tolerance = 0.3, -- the pay may be this share either side of the expected (seeded variation, online seconds)
	collectRetrySeconds = 5, -- a refused collect is tried again this often...
	collectTimeout = 90, -- ...for this long (FleetService's collection cooldown)
}

local STATUS = "Status" -- attribute: "idle", "running", "done", "skipped", "stopped" or "failed"
local CURRENT = "Current" -- attribute: what the running test is doing now
local RESULT = "Result" -- attribute: the last result, as JSON
local CANCEL = "Cancel" -- attribute: true asks a running test to stop
local RUN_ID = "RunId" -- attribute: the id of the newest test
local LOG = "[FleetTests]"
local CASH_ATTRIBUTE = Economy.cashAttribute
local SIMULATE_OFFLINE = "simulateOffline" -- the DevFleet action (Shared/Net)

-- The latest ProfileSnapshot this copy saw, and how many it has seen (to wait for one sent after an action).
type Watch = { latest: { [string]: any }?, count: number, connection: RBXScriptConnection }

type Context = {
	id: string,
	name: string,
	started: number,
	result: Result,
	watch: Watch,
}

-- Helpers ---------------------------------------------------------------------------------------------------

local netReady = false

-- This copy of Net may be MCP's own (not the game's), so make sure it knows the remotes.
local function ensureNet()
	if not netReady then
		Net.setupClient()
		netReady = true
	end
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

-- Ends a test that can't run here: not a game failure.
local function skip(ctx: Context, reason: string): Result
	ctx.result.skipped = true
	ctx.result.reason = `skipped: {reason}`
	note(ctx, ctx.result.reason)
	return ctx.result
end

local function money(amount: number?): string
	return if amount ~= nil then Economy.formatCash(amount) else "?"
end

local function cash(): number
	local value = Players.LocalPlayer:GetAttribute(CASH_ATTRIBUTE)
	return if type(value) == "number" then value else -1
end

-- Waits until `test()` is true, SETTINGS.waitSeconds (or `timeout`) pass, or the test is stopped. Returns whether
-- it came true.
local function waitUntil(ctx: Context, test: () -> boolean, timeout: number?): boolean
	local deadline = os.clock() + (timeout or SETTINGS.waitSeconds)
	while os.clock() < deadline and not cancelRequested(ctx) do
		if test() then
			return true
		end
		task.wait(SETTINGS.checkInterval)
	end
	return test()
end

-- Waits out what's left of SETTINGS.callGap since the last call to `remote`, so Net never drops a call.
local lastCalls: { [string]: number } = {}
local function spaceCalls(remote: string)
	local last = lastCalls[remote]
	if last ~= nil then
		local wait = SETTINGS.callGap - (os.clock() - last)
		if wait > 0 then
			task.wait(wait)
		end
	end
	lastCalls[remote] = os.clock()
end

-- Calls a function remote; the reply table, or nil when the call failed or Net turned it away.
local function invoke(remote: string, payload: any?): { [string]: any }?
	ensureNet()
	spaceCalls(remote)
	local ok, reply = pcall(Net.invokeServer, remote, payload)
	if not ok then
		warn(`{LOG} {remote} failed: {reply}`)
		return nil
	end
	return if type(reply) == "table" then reply else nil
end

local function describe(reply: { [string]: any }?): string
	if reply == nil then
		return "no reply"
	end
	return `{if reply.ok == true then "ok" else "refused"}: {tostring(reply.message)}`
end

local function newWatch(): Watch
	ensureNet()
	local watch: Watch = { latest = nil, count = 0, connection = nil :: any }
	watch.connection = Net.onClientEvent("ProfileSnapshot", function(payload: any)
		if type(payload) == "table" then
			watch.latest = payload
			watch.count += 1
		end
	end)
	return watch
end

-- The fleet in the latest snapshot, checked (nil before one arrives, or when the server sends no fleet).
local function latestFleet(watch: Watch): Fleet?
	local latest = watch.latest
	return if latest then ProfileController.normalizeFleet(latest.fleet) else nil
end

-- Waits for a snapshot sent after `since` (a watch.count) whose fleet passes `test` (any fleet when nil).
local function fleetAfter(ctx: Context, since: number, test: ((fleet: Fleet) -> boolean)?): Fleet?
	local found: Fleet? = nil
	waitUntil(ctx, function()
		if ctx.watch.count <= since then
			return false
		end
		local fleet = latestFleet(ctx.watch)
		if fleet ~= nil and (test == nil or test(fleet)) then
			found = fleet
			return true
		end
		return false
	end)
	return found
end

-- Sets the cash to exactly `amount` (DevSetCash) and waits for the Cash attribute to show it.
local function setCash(ctx: Context, amount: number): boolean
	local reply = invoke("DevSetCash", { amount = math.floor(amount) })
	if reply == nil or reply.ok ~= true then
		return false
	end
	return waitUntil(ctx, function()
		return cash() == math.floor(amount)
	end)
end

-- The fleet as the server has it now. Nothing sends a snapshot until something changes, so this changes the cash
-- by $1 (runTest puts it back) and reads the snapshot that follows. nil when none comes or it has no fleet.
local function readFleet(ctx: Context): Fleet?
	setCurrent(ctx, "reading the fleet")
	local since = ctx.watch.count
	if not setCash(ctx, cash() + 1) then
		return nil
	end
	return fleetAfter(ctx, since)
end

local function podIds(fleet: Fleet): { [string]: string }
	local byUid: { [string]: string } = {}
	for _, pod in fleet.pods do
		byUid[pod.uid] = pod.zone
	end
	return byUid
end

-- The zone with the most demand (the first of equals), or nil with none.
local function busiestZone(fleet: Fleet): string?
	local best: string? = nil
	local bestDemand = -math.huge
	for _, zone in fleet.zones do
		if zone.demand > bestDemand then
			best = zone.id
			bestDemand = zone.demand
		end
	end
	return best
end

-- The pods' online rate together: each pod's zone's perHour.
local function perHourOf(fleet: Fleet): number
	local byId: { [string]: number } = {}
	for _, zone in fleet.zones do
		byId[zone.id] = zone.perHour
	end
	local total = 0
	for _, pod in fleet.pods do
		total += byId[pod.zone] or 0
	end
	return total
end

-- Buys one pod in `zone` with the cash set to cover it. The fleet after it (nil when it didn't work) and the uid.
local function buyPod(ctx: Context, fleet: Fleet, zone: string): (Fleet?, string?)
	local ok = setCash(ctx, fleet.podPrice + SETTINGS.spareCash)
	if not ok then
		check(ctx, "cash set for a pod", false, money(fleet.podPrice + SETTINGS.spareCash))
		return nil, nil
	end
	local since = ctx.watch.count
	local reply = invoke("BuyPod", { zone = zone })
	local uid = if reply and type(reply.uid) == "string" then reply.uid else nil
	if reply == nil or reply.ok ~= true then
		check(ctx, "a pod was bought", false, describe(reply))
		return nil, nil
	end
	local after = fleetAfter(ctx, since, function(updated: Fleet): boolean
		return #updated.pods > #fleet.pods
	end)
	if uid == nil and after ~= nil then
		-- The reply had no uid: the pod that's new in the snapshot.
		local before = podIds(fleet)
		for _, pod in after.pods do
			if before[pod.uid] == nil then
				uid = pod.uid
			end
		end
	end
	return after, uid
end

-- Makes sure the fleet has a pod, buying one in the busiest zone when it has none. The fleet as it is then.
local function ensurePod(ctx: Context, fleet: Fleet): Fleet?
	if #fleet.pods > 0 then
		return fleet
	end
	local zone = busiestZone(fleet)
	if zone == nil then
		return nil
	end
	note(ctx, `no pods yet: buying one in {zone}`)
	local after = buyPod(ctx, fleet, zone)
	return after
end

-- Collects the fleet's earnings, trying again while the server refuses (the collection cooldown) up to
-- SETTINGS.collectTimeout. The amount paid (nil when it never worked) and the last reply.
local function collect(ctx: Context): (number?, { [string]: any }?)
	local deadline = os.clock() + SETTINGS.collectTimeout
	local reply: { [string]: any }? = nil
	repeat
		local before = cash()
		reply = invoke("CollectFleet")
		if reply ~= nil and reply.ok == true then
			local amount = if type(reply.amount) == "number" then reply.amount else 0
			check(
				ctx,
				"the collect reached the cash",
				waitUntil(ctx, function()
					return cash() == before + amount
				end),
				`{money(before)} + {money(amount)} = {money(cash())}`
			)
			return amount, reply
		end
		setCurrent(ctx, `collect refused ({describe(reply)}); trying again`)
		task.wait(SETTINGS.collectRetrySeconds)
	until os.clock() >= deadline or cancelRequested(ctx)
	return nil, reply
end

-- Collects what's waiting (when anything is), so the next collect pays only what comes after. The fleet then.
local function emptyFleet(ctx: Context, fleet: Fleet): Fleet
	if fleet.uncollected < 1 then
		return fleet
	end
	setCurrent(ctx, `collecting the {money(fleet.uncollected)} waiting first`)
	local since = ctx.watch.count
	local amount = collect(ctx)
	if amount == nil then
		note(ctx, "couldn't collect what was waiting first; measuring on top of it")
		return fleet
	end
	return fleetAfter(ctx, since) or fleet
end

-- The tests ---------------------------------------------------------------------------------------------------

local function buyTest(ctx: Context, opts: Options): Result
	local result = ctx.result
	local original = cash()
	if original < 0 then
		return skip(ctx, "the player's data hasn't loaded")
	end
	result.cashBefore = original
	local fleet = readFleet(ctx)
	if fleet == nil then
		return skip(ctx, "no fleet in the profile snapshot (is FleetService running?)")
	end
	result.podPrice = fleet.podPrice
	result.podsBefore = #fleet.pods
	if #fleet.pods >= fleet.slots then
		return skip(ctx, `every slot has a pod ({#fleet.pods} of {fleet.slots}); run sell() first`)
	end
	local zone = opts.zone or busiestZone(fleet)
	if zone == nil then
		return skip(ctx, "the snapshot lists no zones")
	end
	result.zone = zone

	setCurrent(ctx, `buying a pod in {zone}`)
	local start = fleet.podPrice + SETTINGS.spareCash
	local after, uid = buyPod(ctx, fleet, zone)
	result.uid = uid
	check(ctx, "the purchase went through", after ~= nil and uid ~= nil, tostring(uid))
	if after ~= nil then
		result.podsAfter = #after.pods
		check(
			ctx,
			"the pod count went up by one",
			#after.pods == #fleet.pods + 1,
			`{#fleet.pods} -> {#after.pods} of {after.slots} slots`
		)
		local zoneNow = if uid then podIds(after)[uid] else nil
		check(ctx, "the pod drives in the zone it was bought for", zoneNow == zone, `{tostring(zoneNow)} vs {zone}`)
	end
	local expected = start - fleet.podPrice
	check(
		ctx,
		"the cash dropped by the pod price",
		waitUntil(ctx, function()
			return cash() == expected
		end),
		`{money(start)} - {money(fleet.podPrice)}: {money(cash())}, expected {money(expected)}`
	)
	result.cashAfter = cash()
	return result
end

-- offline() and cap(): `hours` away, then what the collect pays against the rule.
local function offlineTest(ctx: Context, opts: Options, hours: number, capped: boolean): Result
	local result = ctx.result
	local tolerance = opts.tolerance or SETTINGS.tolerance
	local original = cash()
	if original < 0 then
		return skip(ctx, "the player's data hasn't loaded")
	end
	result.cashBefore = original
	local read = readFleet(ctx)
	if read == nil then
		return skip(ctx, "no fleet in the profile snapshot (is FleetService running?)")
	end
	local fleet = ensurePod(ctx, read)
	if fleet == nil or #fleet.pods == 0 then
		return skip(ctx, "couldn't get a pod to earn")
	end
	fleet = emptyFleet(ctx, fleet)

	local perHour = perHourOf(fleet)
	local counted = math.min(hours, fleet.offlineCapHours) -- the rule never pays past the cap
	local expected = perHour * fleet.offlineRate * counted
	result.pods = #fleet.pods
	result.hours = hours
	result.offlineRate = fleet.offlineRate
	result.offlineCapHours = fleet.offlineCapHours
	result.perHour = perHour
	result.expected = math.floor(expected)
	result.waiting = fleet.uncollected
	check(ctx, "the pods earn online", perHour > 0, `{money(perHour)} an hour for {#fleet.pods} pods`)

	setCurrent(ctx, `simulating {hours} h away`)
	local reply = invoke("DevFleet", { action = SIMULATE_OFFLINE, hours = hours })
	check(ctx, "DevFleet simulateOffline worked", reply ~= nil and reply.ok == true, describe(reply))
	if reply == nil or reply.ok ~= true then
		return result
	end
	if type(reply.amount) == "number" then
		result.devAmount = reply.amount
		note(ctx, `DevFleet says it added {money(reply.amount)}`)
	end

	setCurrent(ctx, "collecting")
	local collected = collect(ctx)
	check(ctx, "the collect worked", collected ~= nil, money(collected))
	if collected == nil then
		return result
	end
	local offlinePay = collected - fleet.uncollected
	result.collected = collected
	result.offlinePay = offlinePay
	result.ratio = if expected > 0 then math.round(offlinePay / expected * 1000) / 1000 else nil
	local low, high = expected * (1 - tolerance), expected * (1 + tolerance)
	check(
		ctx,
		`paid about {counted} h x {math.round(fleet.offlineRate * 100)} % of the online rate`,
		expected > 0 and offlinePay >= low and offlinePay <= high,
		`{money(offlinePay)} vs {money(expected)} (±{math.round(tolerance * 100)} % passes)`
	)
	if capped then
		local uncapped = perHour * fleet.offlineRate * hours
		check(
			ctx,
			`no more than {fleet.offlineCapHours} h worth`,
			offlinePay <= high and offlinePay < uncapped * (1 - tolerance),
			`{money(offlinePay)}; {hours} h uncapped would be {money(uncapped)}`
		)
	end
	return result
end

local function sellTest(ctx: Context, _opts: Options): Result
	local result = ctx.result
	local original = cash()
	if original < 0 then
		return skip(ctx, "the player's data hasn't loaded")
	end
	result.cashBefore = original
	local read = readFleet(ctx)
	if read == nil then
		return skip(ctx, "no fleet in the profile snapshot (is FleetService running?)")
	end
	local fleet = ensurePod(ctx, read)
	if fleet == nil or #fleet.pods == 0 then
		return skip(ctx, "couldn't get a pod to sell")
	end
	local pod = fleet.pods[#fleet.pods]
	result.uid = pod.uid
	result.podsBefore = #fleet.pods
	result.podPrice = fleet.podPrice
	result.sellBack = fleet.sellBack
	local expectedBack = Garage.sellPrice(fleet.podPrice)
	result.expectedSellBack = expectedBack
	check(
		ctx,
		`sell-back is {math.round(Garage.sellBackRate * 100)} % of the pod price`,
		math.abs(fleet.sellBack - expectedBack) <= 1,
		`{money(fleet.sellBack)} of {money(fleet.podPrice)}, expected {money(expectedBack)}`
	)

	setCurrent(ctx, `selling pod {pod.uid}`)
	local before = cash()
	local since = ctx.watch.count
	local reply = invoke("SellPod", { uid = pod.uid })
	check(ctx, "the sale went through", reply ~= nil and reply.ok == true, describe(reply))
	if reply == nil or reply.ok ~= true then
		return result
	end
	if type(reply.amount) == "number" then
		check(ctx, "the reply pays the sell-back", reply.amount == fleet.sellBack, money(reply.amount))
	end
	check(
		ctx,
		"the cash rose by the sell-back",
		waitUntil(ctx, function()
			return cash() == before + fleet.sellBack
		end),
		`{money(before)} + {money(fleet.sellBack)} = {money(cash())}`
	)
	result.cashAfter = cash()
	local after = fleetAfter(ctx, since, function(updated: Fleet): boolean
		return podIds(updated)[pod.uid] == nil
	end)
	check(ctx, "the pod is gone", after ~= nil, if after then `{#after.pods} pods left` else "still in the snapshot")
	result.podsAfter = if after then #after.pods else nil
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
		notes = {},
		elapsed = 0,
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

local function runTest(name: TestName, body: (ctx: Context) -> Result, opts: Options): Result
	if not (RunService:IsStudio() and RunService:IsRunning()) then
		warn(`{LOG} runs only in a Studio playtest (Client datamodel)`)
		return emptyResult(name, "studio only")
	end
	if script:GetAttribute(STATUS) == "running" then
		warn(`{LOG} a test is already running; FleetTests.stop() cancels it`)
		return emptyResult(name, "busy")
	end

	local ctx: Context = {
		id = HttpService:GenerateGUID(false),
		name = name,
		started = os.clock(),
		result = emptyResult(name, "done"),
		watch = newWatch(),
	}
	script:SetAttribute(RUN_ID, ctx.id)
	script:SetAttribute(STATUS, "running")
	script:SetAttribute(CANCEL, false)
	script:SetAttribute(RESULT, nil)

	local original = cash()
	local ok, outcome = pcall(body, ctx)
	local result: Result = if ok then outcome else ctx.result
	if not ok then
		result.reason = `error: {tostring(outcome)}`
		warn(`{LOG} {name} failed: {outcome}`)
	end
	if opts.cleanup ~= false and original >= 0 and cash() ~= original then
		local restored = setCash(ctx, original)
		note(ctx, if restored then `cash put back to {money(original)}` else "couldn't put the cash back")
	end
	ctx.watch.connection:Disconnect()

	if cancelRequested(ctx) and result.reason == "done" then
		result.reason = "stopped"
	end
	result.passed = ok and not result.skipped and result.reason == "done" and #result.checks > 0
	for _, item in result.checks do
		if not item.passed then
			result.passed = false
		end
	end
	result.elapsed = math.round((os.clock() - ctx.started) * 10) / 10
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

local FleetTests = {}
FleetTests.SETTINGS = SETTINGS

-- Buys a pod: the slot count goes up and the cash drops by the pod price.
function FleetTests.buy(opts: Options?): Result
	local options: Options = opts or {}
	return runTest("buy", function(ctx: Context): Result
		return buyTest(ctx, options)
	end, options)
end

-- 2 h away pays about 2 h x the offline rate x the pods' online rate.
function FleetTests.offline(opts: Options?): Result
	local options: Options = opts or {}
	return runTest("offline", function(ctx: Context): Result
		return offlineTest(ctx, options, options.hours or SETTINGS.offlineHours, false)
	end, options)
end

-- 20 h away pays no more than the offline cap (8 h) worth.
function FleetTests.cap(opts: Options?): Result
	local options: Options = opts or {}
	return runTest("cap", function(ctx: Context): Result
		return offlineTest(ctx, options, SETTINGS.capTestHours, true)
	end, options)
end

-- Sells a pod for the sell-back (60 % of the pod price).
function FleetTests.sell(opts: Options?): Result
	local options: Options = opts or {}
	return runTest("sell", function(ctx: Context): Result
		return sellTest(ctx, options)
	end, options)
end

-- The four in order, as one result: buy, offline, cap, sell.
function FleetTests.all(opts: Options?): Result
	local options: Options = opts or {}
	return runTest("all", function(ctx: Context): Result
		local steps: { { name: string, run: (ctx: Context) -> Result } } = {
			{
				name = "buy",
				run = function(inner: Context): Result
					return buyTest(inner, options)
				end,
			},
			{
				name = "offline",
				run = function(inner: Context): Result
					return offlineTest(inner, options, options.hours or SETTINGS.offlineHours, false)
				end,
			},
			{
				name = "cap",
				run = function(inner: Context): Result
					return offlineTest(inner, options, SETTINGS.capTestHours, true)
				end,
			},
			{
				name = "sell",
				run = function(inner: Context): Result
					return sellTest(inner, options)
				end,
			},
		}
		for _, step in steps do
			if cancelRequested(ctx) then
				break
			end
			-- Each step fills its own result, sharing this run's id, watch and cancel; its checks and notes are
			-- copied into this one under the step's name.
			local inner: Context = {
				id = ctx.id,
				name = `all/{step.name}`,
				started = os.clock(),
				result = emptyResult(step.name, "done"),
				watch = ctx.watch,
			}
			local ok, outcome = pcall(step.run, inner)
			local stepResult: Result = if ok then outcome else inner.result
			if not ok then
				check(ctx, `{step.name} ran`, false, tostring(outcome))
			end
			for _, item in stepResult.checks do
				table.insert(
					ctx.result.checks,
					{ name = `{step.name}: {item.name}`, passed = item.passed, detail = item.detail }
				)
			end
			for _, text in stepResult.notes do
				table.insert(ctx.result.notes, `{step.name}: {text}`)
			end
			-- A step that couldn't run fails the whole: all() passes only when every step ran and passed.
			if stepResult.skipped then
				check(ctx, `{step.name} ran`, false, stepResult.reason)
			end
		end
		return ctx.result
	end, options)
end

local STARTERS: { [string]: (...any) -> Result } = {
	buy = FleetTests.buy,
	offline = FleetTests.offline,
	cap = FleetTests.cap,
	sell = FleetTests.sell,
	all = FleetTests.all,
}

-- Starts a test in the background and returns at once: start("buy"), start("offline"), start("cap"),
-- start("sell"), start("all"), each with an optional Options table. Poll status() / lastResult() or watch the
-- console.
function FleetTests.start(name: TestName, ...: any)
	local starter = STARTERS[name]
	if starter == nil then
		warn(`{LOG} unknown test "{name}"; use "buy", "offline", "cap", "sell" or "all"`)
		return
	end
	task.spawn(starter, ...)
end

-- The last finished result, or nil while a test runs (or before any has finished).
function FleetTests.lastResult(): Result?
	local encoded = script:GetAttribute(RESULT)
	if script:GetAttribute(STATUS) == "running" or type(encoded) ~= "string" then
		return nil
	end
	return HttpService:JSONDecode(encoded)
end

-- "idle", "running", "done", "skipped", "stopped" or "failed", and what the running test is doing.
function FleetTests.status(): (string, string?)
	local status = script:GetAttribute(STATUS)
	local current = script:GetAttribute(CURRENT)
	return if type(status) == "string" then status else "idle", if type(current) == "string" then current else nil
end

-- Cancels a running test; clears a "running" status left by a test whose thread died.
function FleetTests.stop()
	if not RunService:IsStudio() then
		return
	end
	script:SetAttribute(CANCEL, true)
	if script:GetAttribute(STATUS) == "running" then
		script:SetAttribute(STATUS, "stopped")
	end
end

return FleetTests
