--!strict
-- Studio-only shop tests (PLAN.md Phase 4 acceptance; docs/phase-4-contracts.md "Studio tests"). Like
-- Dev/RouteTests they need no bridge: they call the real remotes from the client, so they test the real server
-- path (Net validation, rate limits, DealershipService, EconomyService, GarageService, the save).
--   buyExact(vehicleId, trim, opts)  sets cash to exactly the trim's price (DevSetCash, which goes through
--                                    EconomyService's Studio-only grant), buys it, and checks the balance is $0,
--                                    the car is in the saved garage (ProfileSnapshot) and it was spawned
--                                    (Workspace.Vehicles, OwnedUid). Then sells it back and restores the cash
--                                    unless opts.cleanup is false.
--   forgedBuy(opts)                  fires BuyVehicle for the Ohm Arc with $1 too little and expects a refusal
--                                    with the cash untouched; also an upgrade trim, a limited trim and an unknown
--                                    car, each with plenty of cash. Restores the cash.
--   usedLotDeterminism()             works out today's used-lot stock twice, as two servers would
--                                    (Config/UsedLot.stockFor), compares them, and compares both with what this
--                                    server answers to GetUsedLot.
--   all(opts)                        the three in order
-- Each returns a plain table: { name, passed, checks = { { name, passed, detail } }, elapsed }; all() returns
-- { results, passed }. Every check is printed as it finishes, so get_console_output shows them even if the
-- execute_luau call stops waiting first. The server logs each refusal ("[DealershipService] BuyVehicle refused
-- for ...").
--
-- Run from MCP execute_luau in the Client datamodel of a playtest, once the player's data has loaded:
--   require(game.Players.LocalPlayer.PlayerScripts.Client.Dev.ShopTests).all()
--
-- Does nothing outside Studio (CLAUDE.md hard rule 8); DevSetCash is refused by the server outside Studio too.
-- The client loader never boots it.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local Catalog = require(Shared.Vehicle.Catalog)
local Economy = require(Shared.Config.Economy)
local Garage = require(Shared.Config.Garage)
local Net = require(Shared.Net)
local Spawning = require(Shared.Config.Spawning)
local UsedLot = require(Shared.Config.UsedLot)

export type Check = { name: string, passed: boolean, detail: string }
export type Result = { name: string, passed: boolean, checks: { Check }, elapsed: number }
export type Options = {
	cleanup: boolean?, -- buyExact: sell the car back and restore the cash afterwards (default true)
}

type Context = { result: Result, started: number }

-- A dev tool, so its numbers live here rather than in Shared/Config (like Dev/RouteTests' SETTINGS).
local SETTINGS = {
	waitSeconds = 10, -- longest wait for cash, the saved garage or the spawned car to show a change
	checkInterval = 0.1, -- seconds between looks while waiting
	-- Seconds between calls to one remote, inside Net's rate limits (BuyVehicle allows a burst of 3, then one
	-- every 2 s; DevSetCash one a second).
	callGap = 2.2,
	defaultVehicle = "ohm_spark",
	defaultTrim = "standard",
	forgedVehicle = "ohm_arc", -- the forged purchase (contracts: "the Arc with too little cash")
	forgedTrim = "performance",
	unknownVehicle = "not_a_real_car",
	plentyOfCash = 50000000, -- for the refusals that must not be about cash
}

local LOG = "[ShopTests]"
local CASH_ATTRIBUTE = Economy.cashAttribute

local ShopTests = {}

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
	return { result = { name = name, passed = true, checks = {}, elapsed = 0 }, started = os.clock() }
end

local function check(ctx: Context, name: string, passed: boolean, detail: string?)
	local text = detail or ""
	table.insert(ctx.result.checks, { name = name, passed = passed, detail = text })
	if not passed then
		ctx.result.passed = false
	end
	print(`{LOG} {ctx.result.name}: {if passed then "PASS" else "FAIL"} {name}{if text ~= "" then ` ({text})` else ""}`)
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
	check(ctx, "running in a Studio playtest", false, "ShopTests only run in a Studio playtest")
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

local function cash(): number
	local value = Players.LocalPlayer:GetAttribute(CASH_ATTRIBUTE)
	return if type(value) == "number" then value else -1
end

-- Waits until `test()` is true or SETTINGS.waitSeconds pass. Returns whether it came true.
local function waitUntil(test: () -> boolean): boolean
	local deadline = os.clock() + SETTINGS.waitSeconds
	while os.clock() < deadline do
		if test() then
			return true
		end
		task.wait(SETTINGS.checkInterval)
	end
	return test()
end

local function setCash(amount: number): boolean
	local reply = invoke("DevSetCash", { amount = amount })
	if reply == nil or reply.ok ~= true then
		return false
	end
	return waitUntil(function()
		return cash() == amount
	end)
end

local function gap()
	task.wait(SETTINGS.callGap)
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

local function snapshotCar(watch: SnapshotWatch, uid: string): { [string]: any }?
	local latest = watch.latest
	local vehicles = if latest then latest.vehicles else nil
	if type(vehicles) ~= "table" then
		return nil
	end
	for _, vehicle in vehicles do
		if type(vehicle) == "table" and vehicle.uid == uid then
			return vehicle
		end
	end
	return nil
end

-- Cars in the latest snapshot's garage (-1 with no snapshot yet).
local function carCount(watch: SnapshotWatch): number
	local latest = watch.latest
	local vehicles = if latest then latest.vehicles else nil
	return if type(vehicles) == "table" then #vehicles else -1
end

-- The local player's spawned car that is owned car `uid`, if any.
local function spawnedCar(uid: string): Model?
	local folder = Workspace:FindFirstChild(Spawning.vehiclesFolder)
	if folder == nil then
		return nil
	end
	for _, car in folder:GetChildren() do
		if
			car:IsA("Model")
			and car:GetAttribute("OwnerUserId") == Players.LocalPlayer.UserId
			and car:GetAttribute(Garage.ownedUidAttribute) == uid
		then
			return car
		end
	end
	return nil
end

local function sameStock(a: { UsedLot.StockEntry }, b: { UsedLot.StockEntry }): (boolean, string)
	if #a ~= #b then
		return false, `{#a} spaces vs {#b}`
	end
	for i, entry in a do
		local other = b[i]
		if
			other.slot ~= entry.slot
			or other.vehicleId ~= entry.vehicleId
			or other.trim ~= entry.trim
			or other.basePrice ~= entry.basePrice
			or other.supply ~= entry.supply
		then
			return false, `space {i}: {entry.vehicleId}/{entry.trim} vs {other.vehicleId}/{other.trim}`
		end
	end
	return true, `{#a} spaces`
end

-- Tests -----------------------------------------------------------------------------------------------------

-- Buys a trim with exactly its price in cash: the balance ends at $0, the car is saved and spawned.
function ShopTests.buyExact(vehicleId: string?, trim: string?, opts: Options?): Result
	local name = "buyExact"
	local refused = studioOnly(name)
	if refused then
		return refused
	end
	local ctx = begin(name)
	local id = vehicleId or SETTINGS.defaultVehicle
	local trimId = trim or SETTINGS.defaultTrim
	local price = Catalog.totalPrice(id, trimId)
	check(ctx, "the trim has a price", price ~= nil, `{id}/{trimId}: {tostring(price)}`)
	if price == nil then
		return finish(ctx)
	end
	local original = cash()
	check(ctx, "player data loaded", original >= 0, `cash {original}`)
	if original < 0 then
		return finish(ctx)
	end

	local watch = watchSnapshots()
	check(ctx, "cash set to exactly the price", setCash(price), Economy.formatCash(price))
	gap()
	local reply = invoke("BuyVehicle", { vehicleId = id, trim = trimId })
	local uid = if reply and type(reply.uid) == "string" then reply.uid else nil
	check(
		ctx,
		"the purchase went through",
		reply ~= nil and reply.ok == true and uid ~= nil,
		if reply then tostring(reply.message) else "no reply"
	)
	if uid ~= nil then
		local carUid: string = uid
		check(
			ctx,
			"balance is $0",
			waitUntil(function()
				return cash() == 0
			end),
			`cash {cash()}`
		)
		local saved = waitUntil(function()
			return snapshotCar(watch, carUid) ~= nil
		end)
		local record = snapshotCar(watch, carUid)
		check(
			ctx,
			"the car is in the saved garage",
			saved and record ~= nil and record.vehicleId == id and record.trim == trimId and record.paid == price,
			if record then `{record.vehicleId}/{record.trim}, paid {record.paid}` else "not in any ProfileSnapshot"
		)
		check(
			ctx,
			"the car was spawned",
			waitUntil(function()
				return spawnedCar(carUid) ~= nil
			end),
			carUid
		)

		if opts == nil or opts.cleanup ~= false then
			gap()
			local sold = invoke("SellVehicle", { uid = carUid })
			check(
				ctx,
				"cleanup: sold back",
				sold ~= nil and sold.ok == true,
				if sold then tostring(sold.message) else "no reply"
			)
		end
	end
	watch.connection:Disconnect()
	if opts == nil or opts.cleanup ~= false then
		gap()
		check(ctx, "cleanup: cash restored", setCash(original), Economy.formatCash(original))
	end
	return finish(ctx)
end

-- Forged purchases: too little cash for the Arc, then an upgrade trim, a limited trim and an unknown car with
-- plenty of cash. Every one must be refused and leave the cash and the garage alone.
function ShopTests.forgedBuy(): Result
	local name = "forgedBuy"
	local refused = studioOnly(name)
	if refused then
		return refused
	end
	local ctx = begin(name)
	local original = cash()
	check(ctx, "player data loaded", original >= 0, `cash {original}`)
	if original < 0 then
		return finish(ctx)
	end
	local watch = watchSnapshots()

	local id, trimId = SETTINGS.forgedVehicle, SETTINGS.forgedTrim
	local price = Catalog.totalPrice(id, trimId)
	check(ctx, "the Arc has a price", price ~= nil, `{id}/{trimId}: {tostring(price)}`)
	local carsBefore: number? = nil
	if price ~= nil then
		local short = price - 1
		check(ctx, "cash set to $1 short", setCash(short), Economy.formatCash(short))
		-- Setting the cash changed the save, so a ProfileSnapshot with the garage as it is now follows.
		if waitUntil(function()
			return watch.latest ~= nil
		end) then
			carsBefore = carCount(watch)
		end
		gap()
		local reply = invoke("BuyVehicle", { vehicleId = id, trim = trimId })
		check(
			ctx,
			"the Arc with $1 too little is refused",
			reply ~= nil and reply.ok == false,
			if reply then tostring(reply.message) else "no reply"
		)
		task.wait(SETTINGS.checkInterval * 10)
		check(ctx, "cash untouched", cash() == short, `cash {cash()}`)
	end

	-- Refusals that have nothing to do with cash.
	local forged: { { label: string, vehicleId: string, trim: string } } = {}
	local vehicle = Catalog.getVehicle(id)
	if vehicle then
		for _, candidate in vehicle.trims do
			if candidate.upgradeFrom ~= nil then
				table.insert(forged, { label = `upgrade trim {candidate.id}`, vehicleId = id, trim = candidate.id })
			elseif candidate.acquisition == "limited" then
				table.insert(forged, { label = `limited trim {candidate.id}`, vehicleId = id, trim = candidate.id })
			end
		end
	end
	table.insert(forged, { label = "an unknown car", vehicleId = SETTINGS.unknownVehicle, trim = trimId })
	gap()
	check(ctx, "cash set to plenty", setCash(SETTINGS.plentyOfCash), Economy.formatCash(SETTINGS.plentyOfCash))
	for _, case in forged do
		gap()
		local reply = invoke("BuyVehicle", { vehicleId = case.vehicleId, trim = case.trim })
		check(
			ctx,
			`{case.label} is refused`,
			reply ~= nil and reply.ok == false,
			if reply then tostring(reply.message) else "no reply"
		)
	end
	task.wait(SETTINGS.checkInterval * 10) -- a wrongly added car would have sent a snapshot by now
	check(ctx, "cash untouched by the refusals", cash() == SETTINGS.plentyOfCash, `cash {cash()}`)
	local carsAfter = carCount(watch)
	check(
		ctx,
		"no car was added",
		carsBefore ~= nil and carsAfter == carsBefore,
		`{tostring(carsBefore)} cars before, {carsAfter} after`
	)
	watch.connection:Disconnect()

	gap()
	check(ctx, "cleanup: cash restored", setCash(original), Economy.formatCash(original))
	return finish(ctx)
end

-- Today's used-lot stock worked out twice (as two servers would), and compared with this server's answer.
function ShopTests.usedLotDeterminism(): Result
	local name = "usedLotDeterminism"
	local refused = studioOnly(name)
	if refused then
		return refused
	end
	local ctx = begin(name)
	local today = UsedLot.dateKey(os.time())
	-- Two "servers": one with the module's pool, one with its own copy of it.
	local first = UsedLot.stockFor(today)
	local second = UsedLot.stockFor(today, table.clone(UsedLot.pool), UsedLot.slots)
	local same, detail = sameStock(first, second)
	check(ctx, "the same stock twice for one day", same, `{today}: {detail}`)
	check(ctx, "one car per numbered space", #first == UsedLot.slots, `{#first} cars, {UsedLot.slots} spaces`)

	local reply = invoke("GetUsedLot")
	check(ctx, "the server answers GetUsedLot", reply ~= nil and reply.ok == true, if reply then "" else "no reply")
	if reply ~= nil and type(reply.stock) == "table" then
		check(ctx, "the server is on the same day", reply.date == today, `{tostring(reply.date)} vs {today}`)
		local serverStock: { UsedLot.StockEntry } = {}
		for _, offer in reply.stock do
			table.insert(serverStock, {
				slot = offer.slot,
				vehicleId = offer.vehicleId,
				trim = offer.trim,
				basePrice = offer.basePrice,
				supply = offer.supply,
			})
		end
		local match, why = sameStock(first, serverStock)
		check(ctx, "the server shows the same stock", match, why)
	end
	return finish(ctx)
end

-- All three, in order.
function ShopTests.all(opts: Options?): { results: { Result }, passed: boolean }
	local results = {
		ShopTests.usedLotDeterminism(),
		ShopTests.forgedBuy(),
		ShopTests.buyExact(nil, nil, opts),
	}
	local passed = true
	for _, result in results do
		passed = passed and result.passed
	end
	print(`{LOG} all: {if passed then "PASSED" else "FAILED"}`)
	return { results = results, passed = passed }
end

return ShopTests
