--!strict
-- Data safety (PLAN.md Phase 14 "Data safety review"; docs/phase-14-contracts.md "Data safety"): the parts of the
-- review that are pure rules, each run against a server dying at every point that matters.
--   * Credit reservations (CreditsService.Ledger): whatever a dead server left reserved is refunded on the next
--     join, once; no reservation is ever both spent and refunded; and through any mix of reserving, spending,
--     refunding, saving, crashing and joining (a seeded random run), credits are never made or lost and the free
--     new car is never both used and available.
--   * pendingGrants (LimitedService): a drop paid for but not in the garage when the server died (before its serial
--     was claimed, after that, or after the grant but before it was saved) is granted on the next join exactly once,
--     with the serial it was sold and paid for once, and the join after that changes nothing. A purchase that never
--     reached the save costs nothing and keeps the player's serial for when they buy again.
--   * receipts (MonetizationService.Receipts): the list never grows past Config/Data.maxReceipts, the oldest go
--     first, and every one of the newest is still recognised, so a recent PurchaseId delivered again grants nothing.
-- DataService's session locks need ProfileStore and DataStores, so they are checked in Studio, not here. Migrations
-- are tests/MigrationFixtures.spec and tests/Migrations.spec. Pure logic: runs in Edit mode.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Data = require(ReplicatedStorage.Shared.Config.Data)
local Economy = require(ReplicatedStorage.Shared.Config.Economy)
local Harness = require(ReplicatedStorage.Shared.Testing.Harness)
local Limiteds = require(ReplicatedStorage.Shared.Config.Limiteds)
local Types = require(ReplicatedStorage.Shared.Types)
local Services = ServerScriptService.Server.Services
local CreditsService = require(Services.CreditsService)
local LimitedService = require(Services.LimitedService)
local MonetizationService = require(Services.MonetizationService)
local Template = require(Services.DataService.Template)

type Credits = CreditsService.Credits
type Deps = LimitedService.Deps
type Drop = LimitedService.Drop

local Ledger = CreditsService.Ledger
local Receipts = MonetizationService.Receipts

local NOW = 1_790_000_000 -- any fixed os.time()
local START_CREDITS = 50
local RANDOM_SEEDS = { 1, 2, 3, 20261021, 99991 }
local RANDOM_STEPS = 3000

local PRICE = 1000
local DROP: Drop = {
	id = "safety_drop",
	name = "Safety drop",
	vehicleId = "ohm_arc",
	trim = "flight",
	startsAtUtc = NOW - 3600,
	endsAtUtc = NOW + 3600,
	supply = 10,
	price = PRICE,
}
local KEY = "safety_" .. DROP.id
local messages = Limiteds.messages

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

-- Credits: a save's timeline -----------------------------------------------------------------------------------

-- The credits as the save holds them, plus what this timeline has settled: spent credits, whether the free car was
-- used, and how each reservation id ended. A crash rolls all of it back to the last save together, like the profile.
type Timeline = {
	credits: Credits,
	spent: number,
	freeSpent: boolean,
	settled: { [string]: string }, -- reservation id -> "spent" | "refunded"
}

local function holding(credits: Credits): (number, boolean)
	local amount, free = 0, false
	for _, entry in credits.reserved do
		amount += entry.amount
		if Ledger.isFreeId(entry.id) then
			free = true
		end
	end
	return amount, free
end

-- What is wrong with `timeline` (nil when nothing is): credits made or lost, a negative balance, the free car out of
-- step, an id reserved twice, or a reservation still held after it was settled.
local function problemWith(timeline: Timeline): string?
	local credits = timeline.credits
	local held, freeHeld = holding(credits)
	if credits.balance < 0 then
		return `the balance went below zero ({credits.balance})`
	end
	if credits.balance + held + timeline.spent ~= START_CREDITS then
		return `credits made or lost: balance {credits.balance} + held {held} + spent {timeline.spent}`
			.. ` <> {START_CREDITS}`
	end
	if credits.freeDesignUsed ~= (freeHeld or timeline.freeSpent) then
		return `the free car is out of step (used {credits.freeDesignUsed}, held {freeHeld}, spent {timeline.freeSpent})`
	end
	local seen: { [string]: boolean } = {}
	for _, entry in credits.reserved do
		if seen[entry.id] then
			return `{entry.id} is reserved twice`
		end
		seen[entry.id] = true
		if timeline.settled[entry.id] ~= nil then
			return `{entry.id} is still reserved after it was {timeline.settled[entry.id]}`
		end
	end
	return nil
end

-- Settles reservation `id` one way, recording it; an id settled before is a problem.
local function settle(timeline: Timeline, id: string, how: "spent" | "refunded"): string?
	local amount, free = 0, Ledger.isFreeId(id)
	for _, entry in timeline.credits.reserved do
		if entry.id == id then
			amount = entry.amount
		end
	end
	local done = if how == "spent" then Ledger.spend(timeline.credits, id) else Ledger.refund(timeline.credits, id)
	if not done then
		return nil
	end
	if timeline.settled[id] ~= nil then
		return `{id} was {how} after it was already {timeline.settled[id]}`
	end
	timeline.settled[id] = how
	if how == "spent" then
		timeline.spent += amount
		timeline.freeSpent = timeline.freeSpent or free
	end
	return nil
end

-- A new server's join: everything still reserved was left by a session that ended (CreditsService's onLoaded).
local function join(timeline: Timeline): string?
	local stale: { string } = {}
	for _, entry in timeline.credits.reserved do
		table.insert(stale, entry.id)
	end
	local refunded = Ledger.clearStale(timeline.credits, {})
	if refunded ~= #stale then
		return `the join refunded {refunded} of {#stale} reservations left behind`
	end
	for _, id in stale do
		if timeline.settled[id] ~= nil then
			return `the join refunded {id} after it was already {timeline.settled[id]}`
		end
		timeline.settled[id] = "refunded"
	end
	return nil
end

-- Runs `steps` random operations from `seed` and returns the first problem, or nil.
local function randomRun(seed: number, steps: number): string?
	local random = Random.new(seed)
	local live: Timeline = {
		credits = Ledger.sanitize({ balance = START_CREDITS, freeDesignUsed = false, reserved = {} }),
		spent = 0,
		freeSpent = false,
		settled = {},
	}
	local saved: Timeline = deepCopy(live)
	local ids: { string } = {}
	local made = 0
	for step = 1, steps do
		local roll = random:NextInteger(1, 100)
		local problem: string? = nil
		if roll <= 30 then
			made += 1
			local id = `request-{made}`
			if random:NextInteger(1, 6) == 1 then
				id = Ledger.freeId(id)
				Ledger.reserve(live.credits, 0, id, NOW + step)
			else
				Ledger.reserve(live.credits, random:NextInteger(0, 9), id, NOW + step)
			end
			table.insert(ids, id)
		elseif roll <= 50 and #ids > 0 then
			problem = settle(live, ids[random:NextInteger(1, #ids)], "spent")
		elseif roll <= 70 and #ids > 0 then
			problem = settle(live, ids[random:NextInteger(1, #ids)], "refunded")
		elseif roll <= 85 then
			saved = deepCopy(live) -- an autosave
		elseif roll <= 95 then
			-- The server dies: everything since the last save is gone, and the player joins another server.
			live = deepCopy(saved)
			problem = join(live)
		else
			-- The player leaves: this server refunds what it still holds and saves; the next server finds nothing.
			for _, entry in table.clone(live.credits.reserved) do
				problem = problem or settle(live, entry.id, "refunded")
			end
			saved = deepCopy(live)
			problem = problem or join(live)
		end
		problem = problem or problemWith(live)
		if problem ~= nil then
			return `seed {seed}, step {step}: {problem}`
		end
	end
	return nil
end

-- pendingGrants: one player, one server at a time, and the save -----------------------------------------------

type MockStore = {
	values: { [string]: any },
	failNext: number, -- this many calls throw, like a DataStore outage or a server dying mid-call
	UpdateAsync: (self: MockStore, key: string, transform: (old: any) -> any) -> any,
	GetAsync: (self: MockStore, key: string) -> any,
}

local function newStore(): MockStore
	local store: MockStore = {
		values = {},
		failNext = 0,
		UpdateAsync = nil :: any,
		GetAsync = nil :: any,
	}
	store.UpdateAsync = function(self: MockStore, key: string, transform: (old: any) -> any): any
		if self.failNext > 0 then
			self.failNext -= 1
			error("mock DataStore outage")
		end
		local result = transform(deepCopy(self.values[key]))
		if result ~= nil then
			self.values[key] = deepCopy(result)
		end
		return deepCopy(result)
	end
	store.GetAsync = function(self: MockStore, key: string): any
		return deepCopy(self.values[key])
	end
	return store
end

-- The player's profile as one server holds it. `diesAfter`: every update after that many is refused (the server is
-- gone, nothing it does reaches the save). `savesAfter`: the save is written right after those updates.
type Server = {
	data: Types.PlayerData,
	updates: number,
	diesAfter: number?,
	savesAfter: { [number]: boolean },
}

type World = {
	store: MockStore,
	saved: Types.PlayerData, -- the profile as the DataStore holds it
}

local nextUserId = 900000

local function newPlayer(): Player
	nextUserId += 1
	return ({ Name = `SafetyDriver{nextUserId}`, UserId = nextUserId } :: any) :: Player
end

-- A server that loads the player's save (the same UserId every time, as on a real rejoin).
local function serverFrom(world: World): Server
	return { data = deepCopy(world.saved), updates = 0, diesAfter = nil, savesAfter = {} }
end

local function depsFor(world: World, server: Server, userId: number): Deps
	local uids = 0
	return {
		store = world.store,
		keyFor = function(id: string): string
			return "safety_" .. id
		end,
		now = function(): number
			return NOW
		end,
		update = function(_player: Player, fn: (data: Types.PlayerData) -> ()): boolean
			server.updates += 1
			local dies = server.diesAfter
			if dies ~= nil and server.updates > dies then
				return false
			end
			local ok = pcall(fn, server.data)
			if ok and server.savesAfter[server.updates] then
				world.saved = deepCopy(server.data)
			end
			return ok
		end,
		userId = function(_player: Player): number
			return userId
		end,
		newUid = function(): string
			uids += 1
			return `safety-car-{uids}`
		end,
		recordCash = function(_player: Player, _flow: LimitedService.Flow, _amount: number, _reason: string) end,
		flagOn = function(): boolean
			return true
		end,
		drops = { [DROP.id] = DROP },
		cosmetics = {},
	}
end

local function dropCars(data: Types.PlayerData): { Types.OwnedVehicle }
	local cars: { Types.OwnedVehicle } = {}
	for _, vehicle in data.vehicles do
		if vehicle.vehicleId == DROP.vehicleId and vehicle.trim == DROP.trim then
			table.insert(cars, vehicle)
		end
	end
	return cars
end

local function soldOf(world: World): number
	return LimitedService.cleanRecord(world.store.values[KEY]).sold
end

-- When the first server dies during a purchase. In every case the save holds the charge and the pendingGrants entry
-- (the charge's update was saved) and no car.
type Crash = {
	label: string,
	claimFails: boolean, -- the serial's UpdateAsync never finishes (the server died in it)
	diesAfter: number, -- 1: after the charge; 2: after the grant was made in memory
	toldOk: boolean, -- what the dying server told the player
}
local CRASHES: { Crash } = {
	{ label = "before its serial was claimed", claimFails = true, diesAfter = 1, toldOk = false },
	{ label = "after its serial was claimed, before the grant", claimFails = false, diesAfter = 1, toldOk = false },
	{ label = "after the grant, before the grant was saved", claimFails = false, diesAfter = 2, toldOk = true },
}

return function(t: Harness.Api)
	t.describe("Data safety: credit reservations", function()
		t.it("refunds what a dead server left reserved on the next join, once", function()
			local credits = Ledger.sanitize({
				balance = 10,
				freeDesignUsed = true,
				reserved = {
					{ id = "design-1", amount = 3, at = NOW },
					{ id = Ledger.freeId("design-2"), amount = 0, at = NOW },
					{ id = "mod-3", amount = 1, at = NOW },
				},
			})
			t.expect(Ledger.clearStale(credits, {})).toBe(3)
			t.expect(credits.balance).toBe(14)
			t.expect(credits.freeDesignUsed).toBe(false)
			t.expect(credits.reserved).toEqual({})
			-- The join after that finds nothing left to refund.
			t.expect(Ledger.clearStale(credits, {})).toBe(0)
			t.expect(credits.balance).toBe(14)
			-- And the dead server's own settle, had it run, finds nothing to settle either.
			t.expect(Ledger.spend(credits, "design-1")).toBe(false)
			t.expect(Ledger.refund(credits, "mod-3")).toBe(false)
			t.expect(Ledger.spend(credits, Ledger.freeId("design-2"))).toBe(false)
			t.expect(credits.balance).toBe(14)
			t.expect(credits.freeDesignUsed).toBe(false)
		end)

		t.it("never spends and refunds the same reservation", function()
			local credits = Ledger.sanitize({ balance = 10, freeDesignUsed = false, reserved = {} })
			t.expect(Ledger.reserve(credits, 4, "a", NOW)).toBe(true)
			t.expect(Ledger.reserve(credits, 0, Ledger.freeId("b"), NOW)).toBe(true)
			t.expect(Ledger.spend(credits, "a")).toBe(true)
			t.expect(Ledger.refund(credits, "a")).toBe(false)
			t.expect(Ledger.refund(credits, Ledger.freeId("b"))).toBe(true)
			t.expect(Ledger.spend(credits, Ledger.freeId("b"))).toBe(false)
			t.expect(Ledger.clearStale(credits, {})).toBe(0)
			t.expect(credits.balance).toBe(6)
			t.expect(credits.freeDesignUsed).toBe(false)
		end)

		t.it("never makes or loses credits through random reserves, settles, saves, crashes and joins", function()
			local problems: { string } = {}
			for _, seed in RANDOM_SEEDS do
				local problem = randomRun(seed, RANDOM_STEPS)
				if problem ~= nil then
					table.insert(problems, problem)
				end
			end
			t.expect(table.concat(problems, "\n")).toBe("")
		end)

		t.it("the random run catches a ledger that refunds twice (the check itself works)", function()
			local timeline: Timeline = {
				credits = Ledger.sanitize({ balance = START_CREDITS, freeDesignUsed = false, reserved = {} }),
				spent = 0,
				freeSpent = false,
				settled = {},
			}
			Ledger.reserve(timeline.credits, 5, "x", NOW)
			t.expect(settle(timeline, "x", "refunded")).toBe(nil)
			-- A broken refund that gave the credits back a second time.
			timeline.credits.balance += 5
			t.expect(problemWith(timeline) ~= nil).toBe(true)
		end)
	end)

	t.describe("Data safety: pendingGrants after a server dies", function()
		for _, crash in CRASHES do
			t.it(`grants a drop exactly once when the server died {crash.label}`, function()
				local player = newPlayer()
				local userId = (player :: any).UserId
				local world: World = { store = newStore(), saved = Template.new(NOW) }
				local first = serverFrom(world)
				first.diesAfter = crash.diesAfter
				first.savesAfter = { [1] = true } -- the charge reached the save
				if crash.claimFails then
					world.store.failNext = 1
				end
				local reply = LimitedService.buy(depsFor(world, first, userId), player, DROP.id)
				t.expect(reply.ok).toBe(crash.toldOk)
				if not crash.toldOk then
					t.expect(reply.message).toBe(messages.pending)
				end
				-- What the save holds: paid, the entry, no car.
				t.expect(world.saved.cash).toBe(Economy.startingCash - PRICE)
				t.expect(#world.saved.pendingGrants).toBe(1)
				t.expect(#dropCars(world.saved)).toBe(0)

				-- The next join, on another server.
				local second = serverFrom(world)
				second.savesAfter = { [1] = true, [2] = true }
				local answers = LimitedService.completePending(depsFor(world, second, userId), newPlayer(), second.data)
				t.expect(#answers).toBe(1)
				t.expect(answers[1].ok).toBe(true)
				t.expect(answers[1].message).toBe(string.format(messages.completed, DROP.name, 1))
				local cars = dropCars(second.data)
				t.expect(#cars).toBe(1)
				t.expect(cars[1].serial).toBe(1) -- the serial it was sold
				t.expect(cars[1].paid).toBe(PRICE)
				t.expect(second.data.cash).toBe(Economy.startingCash - PRICE) -- paid once
				t.expect(second.data.pendingGrants).toEqual({})
				t.expect(soldOf(world)).toBe(1)
				t.expect(world.saved).toEqual(second.data)

				-- The join after that: nothing to do, nothing changes.
				local third = serverFrom(world)
				local snapshot = deepCopy(third.data)
				local again = LimitedService.completePending(depsFor(world, third, userId), newPlayer(), third.data)
				t.expect(#again).toBe(0)
				t.expect(third.data).toEqual(snapshot)
				t.expect(soldOf(world)).toBe(1)
			end)
		end

		t.it("finishes a purchase whose grant was saved with nothing left over", function()
			local player = newPlayer()
			local userId = (player :: any).UserId
			local world: World = { store = newStore(), saved = Template.new(NOW) }
			local first = serverFrom(world)
			first.savesAfter = { [1] = true, [2] = true }
			t.expect(LimitedService.buy(depsFor(world, first, userId), player, DROP.id).ok).toBe(true)
			local second = serverFrom(world)
			local snapshot = deepCopy(second.data)
			t.expect(#LimitedService.completePending(depsFor(world, second, userId), newPlayer(), second.data)).toBe(0)
			t.expect(second.data).toEqual(snapshot)
			t.expect(#dropCars(second.data)).toBe(1)
			t.expect(second.data.cash).toBe(Economy.startingCash - PRICE)
		end)

		t.it("costs nothing when the purchase never reached the save, and the serial waits for that player", function()
			local player = newPlayer()
			local userId = (player :: any).UserId
			local world: World = { store = newStore(), saved = Template.new(NOW) }
			local first = serverFrom(world)
			first.diesAfter = 2 -- charged and granted in memory, then the server died before any save
			LimitedService.buy(depsFor(world, first, userId), player, DROP.id)
			t.expect(soldOf(world)).toBe(1) -- the serial was claimed

			local second = serverFrom(world)
			t.expect(second.data.cash).toBe(Economy.startingCash) -- nothing was charged
			t.expect(#LimitedService.completePending(depsFor(world, second, userId), newPlayer(), second.data)).toBe(0)
			t.expect(#dropCars(second.data)).toBe(0)
			-- Buying again gets the same serial, not a second one, and charges once.
			local reply = LimitedService.buy(depsFor(world, second, userId), newPlayer(), DROP.id)
			t.expect(reply.ok).toBe(true)
			t.expect(reply.serial).toBe(1)
			t.expect(#dropCars(second.data)).toBe(1)
			t.expect(second.data.cash).toBe(Economy.startingCash - PRICE)
			t.expect(soldOf(world)).toBe(1)
		end)
	end)

	t.describe("Data safety: receipts", function()
		t.it("keeps at least the last 100 purchases (PLAN.md Phase 12)", function()
			t.expect(Data.maxReceipts % 1).toBe(0)
			t.expect(Data.maxReceipts >= 100).toBe(true)
		end)

		t.it("never keeps more than Config/Data.maxReceipts, dropping the oldest first", function()
			local receipts: { string } = {}
			local total = Data.maxReceipts * 2 + 7
			local longest = 0
			for index = 1, total do
				Receipts.record(receipts, `purchase-{index}`, Data.maxReceipts)
				longest = math.max(longest, #receipts)
			end
			t.expect(longest).toBe(Data.maxReceipts)
			t.expect(#receipts).toBe(Data.maxReceipts)
			t.expect(receipts[1]).toBe(`purchase-{total - Data.maxReceipts + 1}`)
			t.expect(receipts[#receipts]).toBe(`purchase-{total}`)
		end)

		t.it("still recognises every one of the newest purchases, so one delivered again grants nothing", function()
			local receipts: { string } = {}
			local total = Data.maxReceipts + 40
			for index = 1, total do
				Receipts.record(receipts, `purchase-{index}`, Data.maxReceipts)
			end
			local missed: { string } = {}
			for index = total - Data.maxReceipts + 1, total do
				if not Receipts.has(receipts, `purchase-{index}`) then
					table.insert(missed, tostring(index))
				end
			end
			t.expect(table.concat(missed, ", ")).toBe("")
			t.expect(Receipts.has(receipts, `purchase-{total - Data.maxReceipts}`)).toBe(false)
		end)

		t.it("trims a list longer than the cap back to it on the next purchase", function()
			local receipts: { string } = {}
			for index = 1, Data.maxReceipts + 30 do
				receipts[index] = `old-{index}`
			end
			Receipts.record(receipts, "new", Data.maxReceipts)
			t.expect(#receipts).toBe(Data.maxReceipts)
			t.expect(receipts[1]).toBe("old-32")
			t.expect(receipts[#receipts]).toBe("new")
		end)
	end)
end
