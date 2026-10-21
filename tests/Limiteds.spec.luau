--!strict
-- Limited drops and limited cosmetics (Services/LimitedService; PLAN.md Phase 12 acceptance "200 concurrent purchase
-- attempts against a supply of 50 (mock store) sell exactly 50 serials, numbered 1-50, with no duplicates";
-- docs/phase-12-contracts.md "Live-ops"). It drives the real buy / finish / completePending / grantCosmetic flows
-- against a mock DataStore that behaves like UpdateAsync (each transform runs on the value it read, the request
-- yields while "in flight", and a write that lost the race is thrown away and run again on the newer value) and
-- fake profiles that behave like DataService.update. Attempts run as interleaved coroutines in a seeded random
-- order. Also: a failed profile grant leaves a pendingGrants entry the next join completes with the same serial,
-- refunds, refusals, the cosmetics' serials, and the shipped Config/Limiteds. Pure: runs in Edit mode.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Catalog = require(ReplicatedStorage.Shared.Vehicle.Catalog)
local Economy = require(ReplicatedStorage.Shared.Config.Economy)
local Harness = require(ReplicatedStorage.Shared.Testing.Harness)
local Limiteds = require(ReplicatedStorage.Shared.Config.Limiteds)
local Monetization = require(ReplicatedStorage.Shared.Config.Monetization)
local Types = require(ReplicatedStorage.Shared.Types)
local Services = ServerScriptService.Server.Services
local LimitedService = require(Services.LimitedService)
local Template = require(Services.DataService.Template)

type Deps = LimitedService.Deps
type Drop = LimitedService.Drop
type Cosmetic = LimitedService.Cosmetic

local NOW = 1800000000 -- a fixed "now" (os.time() seconds)
local HOUR = 3600
local PRICE = 1000
local ATTEMPTS = 200
local SUPPLY = 50
local SEED = 20261020
local KEY_PREFIX = "spec_"
local messages = Limiteds.messages

local TEST_DROP: Drop = {
	id = "test_drop",
	name = "Test drop",
	vehicleId = "ohm_arc",
	trim = "flight",
	startsAtUtc = NOW - HOUR,
	endsAtUtc = NOW + HOUR,
	supply = SUPPLY,
	price = PRICE,
}
local TINY_DROP: Drop = table.clone(TEST_DROP)
TINY_DROP.id = "tiny_drop"
TINY_DROP.supply = 1
local LATER_DROP: Drop = table.clone(TEST_DROP)
LATER_DROP.id = "later_drop"
LATER_DROP.startsAtUtc = NOW + 1
local OVER_DROP: Drop = table.clone(TEST_DROP)
OVER_DROP.id = "over_drop"
OVER_DROP.endsAtUtc = NOW -- ended exactly now

local TEST_WRAP: Cosmetic = {
	id = "test_wrap",
	name = "Test wrap",
	kind = "wrap",
	ref = "test_wrap_look",
	productKey = "limitedTestWrap",
	productId = 123,
	startsAtUtc = NOW - HOUR,
	endsAtUtc = NOW + HOUR,
}

-- Mock DataStore ----------------------------------------------------------------------------------------------

type MockStore = {
	values: { [string]: any },
	versions: { [string]: number },
	conflicts: number, -- writes that lost a race and ran again
	failNext: number, -- this many calls throw, like a DataStore outage
	yields: boolean,
	UpdateAsync: (self: MockStore, key: string, transform: (old: any) -> any) -> any,
	GetAsync: (self: MockStore, key: string) -> any,
}

local function deepCopy(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local copy = {}
	for key, item in value do
		copy[key] = deepCopy(item)
	end
	return copy
end

local function newStore(yields: boolean): MockStore
	local store: MockStore = {
		values = {},
		versions = {},
		conflicts = 0,
		failNext = 0,
		yields = yields,
		UpdateAsync = nil :: any,
		GetAsync = nil :: any,
	}
	store.UpdateAsync = function(self: MockStore, key: string, transform: (old: any) -> any): any
		if self.failNext > 0 then
			self.failNext -= 1
			error("mock DataStore outage")
		end
		while true do
			local version = self.versions[key] or 0
			local result = transform(deepCopy(self.values[key]))
			if self.yields then
				coroutine.yield() -- in flight: other attempts run meanwhile
			end
			if (self.versions[key] or 0) == version then
				if result ~= nil then
					self.values[key] = deepCopy(result)
					self.versions[key] = version + 1
				end
				return deepCopy(result)
			end
			self.conflicts += 1 -- someone else wrote first: run the transform again on the newer value
		end
	end
	store.GetAsync = function(self: MockStore, key: string): any
		return deepCopy(self.values[key])
	end
	return store
end

-- Fake players and profiles -----------------------------------------------------------------------------------

local function fakePlayer(index: number): Player
	return ({ Name = `player{index}`, UserId = 100000 + index } :: any) :: Player
end

type World = {
	store: MockStore,
	profiles: { [Player]: Types.PlayerData },
	failUpdates: { [number]: boolean }, -- which update calls (1, 2, ...) fail like an ended session
	updates: number,
	flag: boolean,
	cash: { { flow: string, amount: number, reason: string } },
}

local function newWorld(store: MockStore?): World
	return {
		store = store or newStore(false),
		profiles = {},
		failUpdates = {},
		updates = 0,
		flag = true,
		cash = {},
	}
end

local function depsFor(world: World): Deps
	local uids = 0
	return {
		store = world.store,
		keyFor = function(id: string): string
			return KEY_PREFIX .. id
		end,
		now = function(): number
			return NOW
		end,
		-- Like DataService.update: false without calling fn for a session that isn't active; an error in fn is
		-- reported and makes it false.
		update = function(player: Player, fn: (data: Types.PlayerData) -> ()): boolean
			world.updates += 1
			local data = world.profiles[player]
			if data == nil or world.failUpdates[world.updates] then
				return false
			end
			local ok = pcall(fn, data)
			return ok
		end,
		userId = function(player: Player): number
			return (player :: any).UserId
		end,
		newUid = function(): string
			uids += 1
			return `uid-{uids}`
		end,
		recordCash = function(_player: Player, flow: string, amount: number, reason: string)
			table.insert(world.cash, { flow = flow, amount = amount, reason = reason })
		end,
		flagOn = function(): boolean
			return world.flag
		end,
		drops = {
			test_drop = TEST_DROP,
			tiny_drop = TINY_DROP,
			later_drop = LATER_DROP,
			over_drop = OVER_DROP,
		},
		cosmetics = { test_wrap = TEST_WRAP },
	}
end

local function join(world: World, index: number): (Player, Types.PlayerData)
	local player = fakePlayer(index)
	local data = Template.new(NOW)
	world.profiles[player] = data
	return player, data
end

-- Runs every task as a coroutine, resuming them in a seeded random order until all have finished.
local function runInterleaved(tasks: { () -> () }, seed: number)
	local random = Random.new(seed)
	local live: { thread } = {}
	for _, fn in tasks do
		table.insert(live, coroutine.create(fn))
	end
	local steps = 0
	while #live > 0 do
		steps += 1
		assert(steps < 1000000, "the attempts never finished")
		local index = random:NextInteger(1, #live)
		local co = live[index]
		local ok, err = coroutine.resume(co)
		if not ok then
			error(err)
		end
		if coroutine.status(co) == "dead" then
			table.remove(live, index)
		end
	end
end

local function serialCar(data: Types.PlayerData): Types.OwnedVehicle?
	for _, vehicle in data.vehicles do
		if vehicle.serial ~= nil then
			return vehicle
		end
	end
	return nil
end

local function count(map: { [any]: any }): number
	local n = 0
	for _ in map do
		n += 1
	end
	return n
end

return function(t: Harness.Api)
	t.describe("Limited drops: serials under contention", function()
		t.it("200 concurrent attempts on a supply of 50 sell exactly 50 serials, 1-50, no duplicates", function()
			local world = newWorld(newStore(true))
			local deps = depsFor(world)
			local players: { Player } = {}
			for index = 1, ATTEMPTS do
				players[index] = join(world, index)
			end
			local replies: { [number]: LimitedService.Reply } = {}
			local tasks: { () -> () } = {}
			for index, player in players do
				table.insert(tasks, function()
					replies[index] = LimitedService.buy(deps, player, TEST_DROP.id)
				end)
			end
			runInterleaved(tasks, SEED)

			t.expect(world.store.conflicts).toBeGreaterThan(0) -- the attempts really did race
			local serials: { [number]: Player } = {}
			local sold = 0
			local soldOutMessage = string.format(messages.soldOut, Economy.formatCash(PRICE))
			for index, player in players do
				local reply = replies[index]
				local data = world.profiles[player]
				t.expect(reply ~= nil).toBe(true)
				t.expect(#data.pendingGrants).toBe(0)
				if reply.ok then
					sold += 1
					local serial = reply.serial :: number
					t.expect(serials[serial]).toBe(nil) -- no duplicates
					serials[serial] = player
					local car = serialCar(data)
					t.expect(car ~= nil and car.serial == serial).toBe(true)
					t.expect(#data.vehicles).toBe(1)
					t.expect(data.cash).toBe(Economy.startingCash - PRICE)
				else
					t.expect(reply.message).toBe(soldOutMessage)
					t.expect(#data.vehicles).toBe(0)
					t.expect(data.cash).toBe(Economy.startingCash) -- refunded
				end
			end
			t.expect(sold).toBe(SUPPLY)
			for serial = 1, SUPPLY do
				t.expect(serials[serial] ~= nil).toBe(true)
			end
			local record = LimitedService.cleanRecord(world.store.values[KEY_PREFIX .. TEST_DROP.id])
			t.expect(record.sold).toBe(SUPPLY)
			t.expect(count(record.owners)).toBe(SUPPLY)
		end)

		t.it("one player hammering the button pays once and gets one serial", function()
			local world = newWorld(newStore(true))
			local deps = depsFor(world)
			local player, data = join(world, 1)
			local oks = 0
			local tasks: { () -> () } = {}
			for _ = 1, 10 do
				table.insert(tasks, function()
					if LimitedService.buy(deps, player, TEST_DROP.id).ok then
						oks += 1
					end
				end)
			end
			runInterleaved(tasks, SEED + 1)
			t.expect(oks).toBe(1)
			t.expect(#data.vehicles).toBe(1)
			t.expect(data.cash).toBe(Economy.startingCash - PRICE)
			t.expect(#data.pendingGrants).toBe(0)
		end)

		t.it("refunds a second purchase of a drop the player already owns", function()
			local world = newWorld()
			local deps = depsFor(world)
			local player, data = join(world, 1)
			t.expect(LimitedService.buy(deps, player, TEST_DROP.id).ok).toBe(true)
			local again = LimitedService.buy(deps, player, TEST_DROP.id)
			t.expect(again.ok).toBe(false)
			t.expect(again.message).toBe(string.format(messages.owned, 1, Economy.formatCash(PRICE)))
			t.expect(data.cash).toBe(Economy.startingCash - PRICE)
			t.expect(#data.vehicles).toBe(1)
			t.expect(#data.pendingGrants).toBe(0)
		end)
	end)

	t.describe("Limited drops: pending grants", function()
		t.it("a failed profile grant leaves a pendingGrants entry that the next join completes", function()
			local world = newWorld()
			local player, data = join(world, 1)
			world.failUpdates[2] = true -- the charge works, the grant finds the session gone
			local reply = LimitedService.buy(depsFor(world), player, TEST_DROP.id)
			t.expect(reply.ok).toBe(false)
			t.expect(reply.message).toBe(messages.pending)
			t.expect(reply.serial).toBe(1)
			t.expect(data.cash).toBe(Economy.startingCash - PRICE)
			t.expect(#data.vehicles).toBe(0)
			t.expect(data.pendingGrants).toEqual({
				{ kind = Limiteds.pendingKind, ref = LimitedService.pendingRef(TEST_DROP.id, PRICE) },
			})

			-- The next join.
			local rejoin = newWorld(world.store)
			rejoin.profiles[player] = data
			local answers = LimitedService.completePending(depsFor(rejoin), player, data)
			t.expect(#answers).toBe(1)
			t.expect(answers[1].ok).toBe(true)
			t.expect(answers[1].message).toBe(string.format(messages.completed, TEST_DROP.name, 1))
			local car = serialCar(data)
			t.expect(car ~= nil).toBe(true)
			local owned = car :: Types.OwnedVehicle
			t.expect(owned.serial).toBe(1) -- the serial they were sold
			t.expect(owned.vehicleId).toBe(TEST_DROP.vehicleId)
			t.expect(owned.trim).toBe(TEST_DROP.trim)
			t.expect(owned.paid).toBe(PRICE)
			t.expect(#data.pendingGrants).toBe(0)
			t.expect(data.cash).toBe(Economy.startingCash - PRICE) -- paid once
			t.expect(LimitedService.cleanRecord(world.store.values[KEY_PREFIX .. TEST_DROP.id]).sold).toBe(1)

			-- And again: nothing left to do.
			t.expect(#LimitedService.completePending(depsFor(rejoin), player, data)).toBe(0)
			t.expect(#data.vehicles).toBe(1)
		end)

		t.it("keeps the entry when the DataStore is down, and finishes it on the next join", function()
			local world = newWorld()
			local player, data = join(world, 1)
			world.store.failNext = 1
			local reply = LimitedService.buy(depsFor(world), player, TEST_DROP.id)
			t.expect(reply.ok).toBe(false)
			t.expect(reply.message).toBe(messages.pending)
			t.expect(#data.pendingGrants).toBe(1)
			t.expect(data.cash).toBe(Economy.startingCash - PRICE)
			local answers = LimitedService.completePending(depsFor(world), player, data)
			t.expect(answers[1].ok).toBe(true)
			t.expect((serialCar(data) :: Types.OwnedVehicle).serial).toBe(1)
			t.expect(#data.pendingGrants).toBe(0)
		end)

		t.it("refunds an entry whose drop sold out before it got a serial", function()
			local world = newWorld()
			local deps = depsFor(world)
			local other = join(world, 2)
			t.expect(LimitedService.buy(deps, other, TINY_DROP.id).ok).toBe(true) -- takes the only serial
			local player, data = join(world, 1)
			data.cash -= PRICE
			table.insert(
				data.pendingGrants,
				{ kind = Limiteds.pendingKind, ref = LimitedService.pendingRef(TINY_DROP.id, PRICE) }
			)
			local answers = LimitedService.completePending(deps, player, data)
			t.expect(answers[1].ok).toBe(false)
			t.expect(answers[1].message)
				.toBe(string.format(messages.refunded, TINY_DROP.name, Economy.formatCash(PRICE)))
			t.expect(data.cash).toBe(Economy.startingCash)
			t.expect(#data.pendingGrants).toBe(0)
			t.expect(#data.vehicles).toBe(0)
		end)

		t.it("refunds an entry for a drop no longer in the config, and leaves other entries alone", function()
			local world = newWorld()
			local player, data = join(world, 1)
			data.cash -= PRICE
			table.insert(
				data.pendingGrants,
				{ kind = Limiteds.pendingKind, ref = LimitedService.pendingRef("gone_drop", PRICE) }
			)
			table.insert(data.pendingGrants, { kind = "somethingElse", ref = "x" })
			LimitedService.completePending(depsFor(world), player, data)
			t.expect(data.cash).toBe(Economy.startingCash)
			t.expect(data.pendingGrants).toEqual({ { kind = "somethingElse", ref = "x" } })
		end)
	end)

	t.describe("Limited drops: refusals change nothing", function()
		t.it("refuses when switched off, unknown, not started, ended, garage full or short of cash", function()
			local cases: { { setup: (world: World, data: Types.PlayerData) -> (), dropId: string, message: string } } =
				{
					{
						setup = function(world: World, _data: Types.PlayerData)
							world.flag = false
						end,
						dropId = TEST_DROP.id,
						message = messages.off,
					},
					{ setup = function() end, dropId = "no_such_drop", message = messages.unknown },
					{ setup = function() end, dropId = LATER_DROP.id, message = messages.notYet },
					{ setup = function() end, dropId = OVER_DROP.id, message = messages.ended },
					{
						setup = function(_world: World, data: Types.PlayerData)
							data.garageSlots = 0
						end,
						dropId = TEST_DROP.id,
						message = messages.full,
					},
					{
						setup = function(_world: World, data: Types.PlayerData)
							data.cash = PRICE - 1
						end,
						dropId = TEST_DROP.id,
						message = string.format(messages.cash, Economy.formatCash(PRICE)),
					},
				}
			for _, case in cases do
				local world = newWorld()
				local player, data = join(world, 1)
				case.setup(world, data)
				local cash = data.cash
				local reply = LimitedService.buy(depsFor(world), player, case.dropId)
				t.expect(reply.ok).toBe(false)
				t.expect(reply.message).toBe(case.message)
				t.expect(data.cash).toBe(cash)
				t.expect(#data.pendingGrants).toBe(0)
				t.expect((next(world.store.values))).toBe(nil) -- no serial was touched
			end
		end)
	end)

	t.describe("Limited serial rules", function()
		t.it("hands out the next serial, gives an owner their own back, and stops at the supply", function()
			local record, claim = LimitedService.claimTransform(nil, "1", 2)
			t.expect(claim).toEqual({ status = "claimed", serial = 1 })
			local again, same = LimitedService.claimTransform(record, "1", 2)
			t.expect(again).toBe(nil) -- nothing to write
			t.expect(same).toEqual({ status = "owned", serial = 1 })
			local second, next2 = LimitedService.claimTransform(record, "2", 2)
			t.expect(next2.serial).toBe(2)
			local _, full = LimitedService.claimTransform(second, "3", 2)
			t.expect(full.status).toBe("soldOut")
			local _, uncapped = LimitedService.claimTransform(second, "3", nil)
			t.expect(uncapped).toEqual({ status = "claimed", serial = 3 })
		end)

		t.it("repairs a damaged record without ever reusing a serial", function()
			local raw: any = { sold = "x", owners = { a = 7, b = -1, c = 1.5, [true] = 3, [5] = 2 } }
			local record = LimitedService.cleanRecord(raw)
			-- A number key is the same UserId as its string; the highest serial held decides `sold`.
			t.expect(record).toEqual({ sold = 7, owners = { a = 7, ["5"] = 2 } })
			local _, claim = LimitedService.claimTransform(raw, "new", nil)
			t.expect(claim.serial).toBe(8)
			local _, same = LimitedService.claimTransform(raw, "5", nil)
			t.expect(same).toEqual({ status = "owned", serial = 2 })
		end)

		t.it("round-trips pending refs", function()
			local dropId, paid = LimitedService.parseRef(LimitedService.pendingRef("arc_flight_1", 7500000))
			t.expect(dropId).toBe("arc_flight_1")
			t.expect(paid).toBe(7500000)
			t.expect((LimitedService.parseRef("no colon"))).toBe(nil)
			t.expect((LimitedService.parseRef(42))).toBe(nil)
		end)
	end)

	t.describe("Limited cosmetics", function()
		t.it("number every buyer in turn, with no cap, and a redelivered receipt keeps its serial", function()
			local world = newWorld()
			local deps = depsFor(world)
			local datas: { Types.PlayerData } = {}
			local players: { Player } = {}
			for index = 1, 3 do
				local player, data = join(world, index)
				datas[index] = data
				players[index] = player
				t.expect(LimitedService.grantCosmetic(deps, player, TEST_WRAP.id)).toBe(true)
				t.expect(data.cosmetics[TEST_WRAP.ref]).toBe(index)
			end
			t.expect(LimitedService.grantCosmetic(deps, players[1], TEST_WRAP.id)).toBe(true)
			t.expect(datas[1].cosmetics[TEST_WRAP.ref]).toBe(1)
			t.expect(LimitedService.ownedSerial(datas[2], TEST_WRAP.ref)).toBe(2)
		end)

		t.it("answers false (Roblox retries the receipt) when the DataStore or the profile can't be written", function()
			local world = newWorld()
			local player, data = join(world, 1)
			world.store.failNext = 1
			t.expect(LimitedService.grantCosmetic(depsFor(world), player, TEST_WRAP.id)).toBe(false)
			world.failUpdates[1] = true
			t.expect(LimitedService.grantCosmetic(depsFor(world), player, TEST_WRAP.id)).toBe(false)
			t.expect(data.cosmetics[TEST_WRAP.ref]).toBe(nil)
			t.expect(LimitedService.grantCosmetic(depsFor(world), player, "no_such_cosmetic")).toBe(false)
		end)

		t.it("are on sale only with a product id, inside their window, with the flag on", function()
			t.expect(LimitedService.cosmeticAvailable(TEST_WRAP, NOW, true)).toBe(true)
			t.expect(LimitedService.cosmeticAvailable(TEST_WRAP, NOW, false)).toBe(false)
			t.expect(LimitedService.cosmeticAvailable(TEST_WRAP, TEST_WRAP.endsAtUtc, true)).toBe(false)
			t.expect(LimitedService.cosmeticAvailable(TEST_WRAP, TEST_WRAP.startsAtUtc - 1, true)).toBe(false)
			local uncreated = table.clone(TEST_WRAP)
			uncreated.productId = 0
			t.expect(LimitedService.cosmeticAvailable(uncreated, NOW, true)).toBe(false)
		end)
	end)

	t.describe("Config/Limiteds", function()
		t.it("ships Arc Flight as a future drop with a supply and an in-game price", function()
			local drop = Limiteds.drops.arc_flight_1
			t.expect(drop ~= nil).toBe(true)
			t.expect(drop.vehicleId).toBe("ohm_arc")
			t.expect(drop.trim).toBe("flight")
			local trim = Catalog.getTrim(drop.vehicleId, drop.trim)
			t.expect(trim ~= nil and trim.acquisition == "limited").toBe(true)
			t.expect(drop.startsAtUtc).toBeGreaterThan(1792454400) -- after 2026-10-20, when it was written
			t.expect(drop.endsAtUtc).toBeGreaterThan(drop.startsAtUtc)
			t.expect(drop.supply >= 1 and drop.supply % 1 == 0).toBe(true)
			t.expect(drop.price >= 1 and drop.price % 1 == 0).toBe(true)
		end)

		t.it("sells every limited trim in the catalog only through a drop, and every drop is a limited trim", function()
			local dropped: { [string]: boolean } = {}
			for id, drop in Limiteds.drops do
				t.expect(drop.id).toBe(id)
				t.expect(string.match(id, "^[%w_]+$") ~= nil).toBe(true)
				local trim = Catalog.getTrim(drop.vehicleId, drop.trim)
				t.expect(trim ~= nil and trim.acquisition == "limited").toBe(true)
				dropped[`{drop.vehicleId}/{drop.trim}`] = true
			end
			for _, vehicleId in Catalog.vehicleIds() do
				local vehicle = Catalog.getVehicle(vehicleId)
				for _, trim in if vehicle ~= nil then vehicle.trims else {} do
					if trim.acquisition == "limited" then
						t.expect(dropped[`{vehicleId}/{trim.id}`]).toBe(true)
					end
				end
			end
		end)

		t.it("lists cosmetics with ids at 0 or real, unique product keys, and no Robux price anywhere", function()
			local keys: { [string]: boolean } = {}
			local looks: { [string]: boolean } = {}
			for id, cosmetic in Limiteds.cosmetics do
				t.expect(cosmetic.id).toBe(id)
				t.expect(looks[cosmetic.ref]).toBe(nil) -- one sale per look: its serial is saved under the look id
				looks[cosmetic.ref] = true
				t.expect(cosmetic.productId >= 0 and cosmetic.productId % 1 == 0).toBe(true)
				t.expect(keys[cosmetic.productKey]).toBe(nil)
				keys[cosmetic.productKey] = true
				t.expect(Monetization.products[cosmetic.productKey]).toBe(nil) -- not a core product key
				t.expect(cosmetic.endsAtUtc).toBeGreaterThan(cosmetic.startsAtUtc)
				t.expect(cosmetic.kind == "wrap" or cosmetic.kind == "plateFrame").toBe(true)
				t.expect((cosmetic :: any).price).toBe(nil)
			end
			t.expect(Limiteds.productIds()[Limiteds.cosmetics.launch_wrap.productKey])
				.toBe(Limiteds.cosmetics.launch_wrap.productId)
		end)

		t.it("keeps Studio's serial counters away from live keys", function()
			t.expect(Limiteds.studioStore ~= Limiteds.store).toBe(true)
			t.expect(Limiteds.studioKeyPrefix ~= Limiteds.keyPrefix).toBe(true)
			t.expect(string.sub(Limiteds.studioKeyPrefix, 1, #Limiteds.keyPrefix) ~= Limiteds.keyPrefix).toBe(true)
		end)
	end)
end
