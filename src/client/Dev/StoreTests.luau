--!strict
-- Studio-only store tests (PLAN.md Phase 12 acceptance; docs/phase-12-contracts.md "Store UI"). Like Dev/ShopTests
-- they need no bridge: they call the real remotes from the client, so they test the real server path (Net
-- validation, rate limits, MonetizationService's ProcessReceipt, CreditsService, EconomyService, the save). No real
-- purchase is ever made: DevPurchase runs ProcessReceipt with a made-up PurchaseId, and MonetizationService refuses
-- it outside Studio.
--   comingSoon()       GetStore, then every pass, product and the club whose id in Config/Monetization is still 0
--                      (or "") must come back not available and without a price, so the Store app shows "Coming soon"
--                      and no buy button (UI/Store/StoreModel). Anything on sale must have a real id.
--   purchases(opts)    buys every product GetStore lists through DevPurchase { key, purchaseId } and checks the grant
--                      landed (credits with their bonus, cash, custom-car and garage spaces, from the product's own
--                      grants), then sends the same PurchaseId again and checks nothing more was granted. Limited
--                      looks are left out unless opts.cosmetics (each takes a serial), and so is a one-time pack
--                      already bought (an earlier run) or anything the store says this player can't buy now (custom
--                      slots full). Products whose id is still 0 are bought too: DevPurchase works by key. Credits
--                      and cash are put back
--                      afterwards (opts.cleanup = false keeps them); spaces and the Starter Pack stay bought.
--   streak()           ClaimStreak twice: the second claim the same day is refused and grants nothing.
--   season()           ClaimSeasonReward { tier = 1, track = "free" } twice: the second is refused and grants nothing.
--                      A first claim the server refuses (no season running, not enough XP) is noted, not failed.
--   all(opts)          the four in order
-- Each returns a plain table: { name, passed, checks = { { name, passed, detail } }, notes, elapsed }; all() returns
-- { results, passed }. Every check is printed as it finishes, so get_console_output shows them even if the
-- execute_luau call stops waiting first.
--
-- Run from MCP execute_luau in the Client datamodel of a playtest, once the player's data has loaded:
--   require(game.Players.LocalPlayer.PlayerScripts.Client.Dev.StoreTests).all()
--
-- Does nothing outside Studio (CLAUDE.md hard rule 8); DevPurchase, DevCredits and DevSetCash are refused by the
-- server outside Studio too. The client loader never boots it.

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage.Shared
local Economy = require(Shared.Config.Economy)
local Monetization = require(Shared.Config.Monetization)
local Net = require(Shared.Net)
local StoreModel = require(script.Parent.Parent.UI.Store.StoreModel)

export type Check = { name: string, passed: boolean, detail: string }
export type Result = { name: string, passed: boolean, checks: { Check }, notes: { string }, elapsed: number }
export type Options = {
	cleanup: boolean?, -- purchases: put the credits and cash back afterwards (default true)
	cosmetics: boolean?, -- purchases: buy the limited looks too (default false: each takes a serial)
}

type Context = { result: Result, started: number }

-- What the tests read from the player: cash (the attribute) and the latest ProfileSnapshot's numbers.
type Balances = { cash: number, credits: number, customSlots: number, garageSlots: number }

-- A dev tool, so its numbers live here rather than in Shared/Config (like Dev/ShopTests' SETTINGS).
local SETTINGS = {
	waitSeconds = 10, -- longest wait for a grant to show in the cash or a snapshot
	settleSeconds = 2, -- how long a repeated receipt gets to (wrongly) grant something
	checkInterval = 0.1, -- seconds between looks while waiting
	-- Seconds between calls to one remote, inside Net's rate limits (DevPurchase 2 a second, GetStore one every
	-- 2 s, ClaimStreak one every 5 s after a burst of 2, ClaimSeasonReward one a second, the dev grants one a second).
	purchaseGap = 0.6,
	storeGap = 2.2,
	claimGap = 5.2,
	devGap = 1.1,
	seasonTier = 1,
	seasonTrack = "free",
}

local LOG = "[StoreTests]"

local StoreTests = {}

local netReady = false

-- This copy of Net may be MCP's own (not the game's), so make sure it knows the remotes.
local function ensureNet()
	if not netReady then
		Net.setupClient()
		netReady = true
	end
end

-- Helpers ---------------------------------------------------------------------------------------------------

local function begin(name: string): Context
	print(`{LOG} {name}: started`)
	return { result = { name = name, passed = true, checks = {}, notes = {}, elapsed = 0 }, started = os.clock() }
end

local function check(ctx: Context, name: string, passed: boolean, detail: string?)
	local text = detail or ""
	table.insert(ctx.result.checks, { name = name, passed = passed, detail = text })
	if not passed then
		ctx.result.passed = false
	end
	print(`{LOG} {ctx.result.name}: {if passed then "PASS" else "FAIL"} {name}{if text ~= "" then ` ({text})` else ""}`)
end

local function note(ctx: Context, text: string)
	table.insert(ctx.result.notes, text)
	print(`{LOG} {ctx.result.name}: note: {text}`)
end

local function finish(ctx: Context): Result
	ctx.result.elapsed = os.clock() - ctx.started
	print(
		`{LOG} {ctx.result.name}: {if ctx.result.passed then "PASSED" else "FAILED"} in {math.floor(ctx.result.elapsed)} s`
	)
	return ctx.result
end

local function studioOnly(name: string): Result?
	if RunService:IsStudio() and RunService:IsRunning() then
		return nil
	end
	local ctx = begin(name)
	check(ctx, "running in a Studio playtest", false, "StoreTests only run in a Studio playtest")
	return finish(ctx)
end

-- Calls a function remote; the reply table, or nil when the call failed or was refused by Net.
local function invoke(name: string, payload: any?): { [string]: any }?
	ensureNet()
	local ok, reply = pcall(Net.invokeServer, name, payload)
	if not ok then
		warn(`{LOG} {name} failed: {reply}`)
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

local function numberOr(value: any, fallback: number): number
	return if type(value) == "number" and value == value then value else fallback
end

-- Waits until `test()` is true or `seconds` pass. Returns whether it came true.
local function waitUntil(test: () -> boolean, seconds: number?): boolean
	local deadline = os.clock() + (seconds or SETTINGS.waitSeconds)
	while os.clock() < deadline do
		if test() then
			return true
		end
		task.wait(SETTINGS.checkInterval)
	end
	return test()
end

-- The latest ProfileSnapshot this test saw (the server sends one after every change).
type SnapshotWatch = { latest: { [string]: any }?, connection: RBXScriptConnection }

local function watchSnapshots(): SnapshotWatch
	ensureNet()
	local watch: SnapshotWatch = { latest = nil, connection = nil :: any }
	watch.connection = Net.onClientEvent("ProfileSnapshot", function(payload: any)
		if type(payload) == "table" then
			watch.latest = payload
		end
	end)
	return watch
end

local function balances(watch: SnapshotWatch): Balances?
	local latest = watch.latest
	if latest == nil then
		return nil
	end
	local credits = if type(latest.credits) == "table" then latest.credits.balance else nil
	return {
		cash = numberOr(Players.LocalPlayer:GetAttribute(Economy.cashAttribute), numberOr(latest.cash, 0)),
		credits = numberOr(credits, 0),
		customSlots = numberOr(latest.customSlots, 0),
		garageSlots = numberOr(latest.garageSlots, 0),
	}
end

local function sameBalances(a: Balances, b: Balances): boolean
	return a.cash == b.cash
		and a.credits == b.credits
		and a.customSlots == b.customSlots
		and a.garageSlots == b.garageSlots
end

local function showBalances(value: Balances?): string
	if value == nil then
		return "no snapshot"
	end
	return `cash {value.cash}, credits {value.credits}, custom spaces {value.customSlots}, garage {value.garageSlots}`
end

-- A fresh snapshot to measure from. Setting the cash to what it already is changes nothing, so the server sends
-- no snapshot (seen in Studio 2026-10-21); nudge it by one dollar, then put it back: the second change's snapshot
-- carries the real balances.
local function primeSnapshot(watch: SnapshotWatch): Balances?
	if watch.latest == nil then
		local cash = Players.LocalPlayer:GetAttribute(Economy.cashAttribute)
		if type(cash) == "number" then
			task.wait(SETTINGS.devGap)
			invoke("DevSetCash", { amount = cash + 1 })
			waitUntil(function()
				return watch.latest ~= nil
			end)
			watch.latest = nil
			task.wait(SETTINGS.devGap)
			invoke("DevSetCash", { amount = cash })
			waitUntil(function()
				return watch.latest ~= nil
			end)
		end
	end
	return balances(watch)
end

local function fetchStore(): StoreModel.Store?
	local reply = invoke("GetStore")
	return StoreModel.normalize(reply)
end

-- What a product should add, from its own grants (StoreModel reads them the same way for the cards).
local function expectedGain(product: StoreModel.Product): Balances
	local grants = product.grants
	local function whole(value: any): number
		local number = numberOr(value, 0)
		return if number > 0 then math.floor(number) else 0
	end
	return {
		cash = whole(grants.cash),
		credits = whole(grants.credits) + whole(grants.bonus),
		customSlots = math.max(whole(grants.customSlots), whole(grants.customSlot)),
		garageSlots = whole(grants.garageSlots),
	}
end

local function gainOf(before: Balances, after: Balances): Balances
	return {
		cash = after.cash - before.cash,
		credits = after.credits - before.credits,
		customSlots = after.customSlots - before.customSlots,
		garageSlots = after.garageSlots - before.garageSlots,
	}
end

local function nothing(gain: Balances): boolean
	return gain.cash == 0 and gain.credits == 0 and gain.customSlots == 0 and gain.garageSlots == 0
end

-- Tests -----------------------------------------------------------------------------------------------------

-- Items whose id is still 0 come back not on sale and without a price: the Store app shows "Coming soon".
function StoreTests.comingSoon(): Result
	local name = "comingSoon"
	local refused = studioOnly(name)
	if refused then
		return refused
	end
	local ctx = begin(name)
	local store = fetchStore()
	check(ctx, "the server answers GetStore", store ~= nil)
	if store == nil then
		return finish(ctx)
	end

	local function checkItem(kind: string, key: string, id: any, item: any)
		check(ctx, `{kind} {key} is in the store`, item ~= nil, if item == nil then "missing from GetStore" else "")
		if item == nil then
			return
		end
		local state = StoreModel.itemState(item)
		if id == nil or id == 0 or id == "" then
			check(
				ctx,
				`{kind} {key} (id 0) shows Coming soon`,
				not item.available
					and item.price == nil
					and state ~= "buy"
					and StoreModel.buttonLabel(item, false) == nil,
				`available {tostring(item.available)}, price {tostring(item.price)}, shows {state}`
			)
		elseif not item.available then
			note(ctx, `{kind} {key} has id {tostring(id)} but isn't on sale (Marketplace lookup failed?)`)
		end
	end

	local products: { [string]: StoreModel.Product } = {}
	for _, product in store.products do
		products[product.key] = product
	end
	for key, id in Monetization.products do
		checkItem("product", key, id, products[key])
	end
	local passes: { [string]: StoreModel.Pass } = {}
	for _, pass in store.passes do
		passes[pass.key] = pass
	end
	for key, id in Monetization.passes do
		checkItem("pass", key, id, passes[key])
	end
	-- Nothing on sale without an id.
	for _, product in store.products do
		local id = Monetization.products[product.key]
		if product.available and (id == nil or id == 0) and product.kind ~= "cosmetic" then
			check(ctx, `product {product.key} on sale only with an id`, false, "on sale with id 0")
		end
	end
	local clubId = Monetization.subscriptions.club
	if clubId == nil or clubId == "" then
		check(
			ctx,
			"the Voltage Club (no id yet) shows Coming soon",
			not store.club.available and store.club.price == nil and StoreModel.clubButton(store.club, false) == nil,
			`available {tostring(store.club.available)}, price {tostring(store.club.price)}`
		)
	end
	return finish(ctx)
end

-- Every product through DevPurchase: the grant lands once, and the same PurchaseId again grants nothing.
function StoreTests.purchases(opts: Options?): Result
	local name = "purchases"
	local refused = studioOnly(name)
	if refused then
		return refused
	end
	local ctx = begin(name)
	local options: Options = opts or {}
	local store = fetchStore()
	check(ctx, "the server answers GetStore", store ~= nil)
	if store == nil then
		return finish(ctx)
	end
	local watch = watchSnapshots()
	local original = primeSnapshot(watch)
	check(ctx, "player data loaded", original ~= nil, showBalances(original))
	if original == nil then
		watch.connection:Disconnect()
		return finish(ctx)
	end

	for _, product in store.products do
		if product.kind == "cosmetic" and not options.cosmetics then
			note(ctx, `{product.key}: limited look left out (opts.cosmetics buys it)`)
			continue
		elseif product.owned then
			note(ctx, `{product.key}: one-time pack already bought on this profile, left out`)
			continue
		elseif product.available and not product.canBuy then
			note(ctx, `{product.key}: left out, the store says {StoreModel.noteText(product)}`)
			continue
		end
		local before = balances(watch)
		if before == nil then
			continue
		end
		local purchaseId = HttpService:GenerateGUID(false)
		task.wait(SETTINGS.purchaseGap)
		local reply = invoke("DevPurchase", { key = product.key, purchaseId = purchaseId })
		check(ctx, `{product.key}: DevPurchase answered`, reply ~= nil and reply.ok ~= false, describe(reply))
		local want = expectedGain(product)
		local measurable = not nothing(want)
		local landed = true
		if measurable then
			landed = waitUntil(function()
				local now = balances(watch)
				if now == nil then
					return false
				end
				local gain = gainOf(before, now)
				return gain.cash >= want.cash
					and gain.credits >= want.credits
					and gain.customSlots >= want.customSlots
					and gain.garageSlots >= want.garageSlots
			end)
		else
			task.wait(SETTINGS.settleSeconds)
		end
		local after = balances(watch) or before
		local gain = gainOf(before, after)
		if measurable then
			check(
				ctx,
				`{product.key}: the grant landed`,
				landed,
				`wanted +{want.credits} credits +{want.cash} cash +{want.customSlots} custom +{want.garageSlots} garage; `
					.. `got +{gain.credits} +{gain.cash} +{gain.customSlots} +{gain.garageSlots}`
			)
			if gain.credits > want.credits then
				note(ctx, `{product.key}: {gain.credits - want.credits} extra credits (a bonus-credit event?)`)
			end
		else
			note(ctx, `{product.key}: grants nothing countable here ({describe(reply)})`)
		end

		-- The same receipt again.
		task.wait(SETTINGS.purchaseGap)
		local again = invoke("DevPurchase", { key = product.key, purchaseId = purchaseId })
		task.wait(SETTINGS.settleSeconds)
		local final = balances(watch) or after
		check(
			ctx,
			`{product.key}: the same PurchaseId grants nothing`,
			sameBalances(after, final),
			`{describe(again)}; before {showBalances(after)}, after {showBalances(final)}`
		)
	end

	if options.cleanup ~= false then
		task.wait(SETTINGS.devGap)
		local credits = invoke("DevCredits", { amount = original.credits })
		check(ctx, "cleanup: credits put back", credits ~= nil and credits.ok == true, describe(credits))
		task.wait(SETTINGS.devGap)
		local cash = invoke("DevSetCash", { amount = original.cash })
		check(ctx, "cleanup: cash put back", cash ~= nil and cash.ok == true, describe(cash))
		note(ctx, "custom-car and garage spaces and the Starter Pack stay bought (no dev remote takes them back)")
	end
	watch.connection:Disconnect()
	return finish(ctx)
end

-- The daily reward: a second claim the same day is refused and grants nothing.
function StoreTests.streak(): Result
	local name = "streak"
	local refused = studioOnly(name)
	if refused then
		return refused
	end
	local ctx = begin(name)
	local watch = watchSnapshots()
	primeSnapshot(watch)
	local first = invoke("ClaimStreak")
	check(ctx, "the server answers ClaimStreak", first ~= nil, describe(first))
	if first ~= nil and first.ok ~= true then
		note(ctx, `the first claim was refused (already claimed today?): {tostring(first.message)}`)
	end
	task.wait(SETTINGS.settleSeconds)
	local before = balances(watch)
	task.wait(SETTINGS.claimGap)
	local second = invoke("ClaimStreak")
	check(ctx, "a second claim the same day is refused", second ~= nil and second.ok ~= true, describe(second))
	task.wait(SETTINGS.settleSeconds)
	local after = balances(watch)
	check(
		ctx,
		"the second claim granted nothing",
		before ~= nil and after ~= nil and sameBalances(before, after),
		`before {showBalances(before)}, after {showBalances(after)}`
	)
	watch.connection:Disconnect()
	return finish(ctx)
end

-- Season tier 1 on the free track: claimed once, never twice.
function StoreTests.season(): Result
	local name = "season"
	local refused = studioOnly(name)
	if refused then
		return refused
	end
	local ctx = begin(name)
	local watch = watchSnapshots()
	primeSnapshot(watch)
	local payload = { tier = SETTINGS.seasonTier, track = SETTINGS.seasonTrack }
	local first = invoke("ClaimSeasonReward", payload)
	check(ctx, "the server answers ClaimSeasonReward", first ~= nil, describe(first))
	if first ~= nil and first.ok ~= true then
		note(
			ctx,
			`tier 1 wasn't claimed (no season running, not enough XP, or claimed before): {tostring(first.message)}`
		)
	end
	task.wait(SETTINGS.settleSeconds)
	local before = balances(watch)
	task.wait(SETTINGS.devGap)
	local second = invoke("ClaimSeasonReward", payload)
	check(ctx, "tier 1 can't be claimed twice", second ~= nil and second.ok ~= true, describe(second))
	task.wait(SETTINGS.settleSeconds)
	local after = balances(watch)
	check(
		ctx,
		"the second claim granted nothing",
		before ~= nil and after ~= nil and sameBalances(before, after),
		`before {showBalances(before)}, after {showBalances(after)}`
	)
	watch.connection:Disconnect()
	return finish(ctx)
end

-- All four, in order.
function StoreTests.all(opts: Options?): { results: { Result }, passed: boolean }
	local results = { StoreTests.comingSoon() }
	task.wait(SETTINGS.storeGap)
	table.insert(results, StoreTests.purchases(opts))
	table.insert(results, StoreTests.streak())
	table.insert(results, StoreTests.season())
	local passed = true
	for _, result in results do
		passed = passed and result.passed
	end
	print(`{LOG} all: {if passed then "PASSED" else "FAILED"}`)
	return { results = results, passed = passed }
end

return StoreTests
