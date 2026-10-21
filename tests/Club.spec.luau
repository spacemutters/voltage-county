--!strict
-- The Voltage Club subscription (PLAN.md Phase 12 acceptance and §11; docs/phase-12-contracts.md "Monetization
-- core"):
--   * the monthly credits are granted once per billing month, across rejoins and status changes, under a fake clock
--   * the billing month is the month the paid cycle started, so a cycle that starts on the 30th pays once, not twice
--   * credits are paid only for a cycle Roblox lists as paid: no history, or no paid cycle covering now (a new
--     payment not listed yet, a lapse Roblox hasn't flipped yet), pays nothing and checks again soon
--   * member perks (slots, the club attribute, the club's looks) stop when the subscription lapses, and no credits
--     are granted while it is lapsed
--   * a failed status check keeps what we knew and checks again soon; an id of "" never asks Roblox; JoinClub
--     prompts once
-- It drives the real MonetizationService with fake Roblox pieces (MonetizationService.setDeps). Pure: runs in Edit
-- mode.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Harness = require(ReplicatedStorage.Shared.Testing.Harness)
local Monetization = require(ReplicatedStorage.Shared.Config.Monetization)
local Offers = require(ReplicatedStorage.Shared.Config.Offers)
local Types = require(ReplicatedStorage.Shared.Types)
local Services = ServerScriptService.Server.Services
local MonetizationService = require(Services.MonetizationService)
local Template = require(Services.DataService.Template)

local USER_ID = 4242
local CLUB_ID = "EXP-SPEC-CLUB"
local OTHER_SUBSCRIPTION = "EXP-SOMETHING-ELSE"
local HOUR = 3600

type Config = Monetization.Monetization

-- Noon UTC on a date, as os.time() seconds.
local function at(year: number, month: number, day: number): number
	return DateTime.fromUniversalTime(year, month, day, 12, 0, 0, 0).UnixTimestamp
end

-- A payment history entry as GetUserSubscriptionPaymentHistoryAsync gives it (DateTime cycle bounds).
local function cycle(startsAt: number, endsAt: number, status: string?): { [string]: any }
	return {
		CycleStartTime = DateTime.fromUnixTimestamp(startsAt),
		CycleEndTime = DateTime.fromUnixTimestamp(endsAt),
		PaymentStatus = status or "Paid",
	}
end

-- The paid monthly cycle covering `now`: from 00:00 UTC on the 1st of its month to the 1st of the next.
local function monthCycle(now: number): { [string]: any }
	local date = os.date("!*t", now)
	local nextYear, nextMonth = date.year, date.month + 1
	if nextMonth > 12 then
		nextYear += 1
		nextMonth = 1
	end
	local startsAt = DateTime.fromUniversalTime(date.year, date.month, 1, 0, 0, 0, 0).UnixTimestamp
	local endsAt = DateTime.fromUniversalTime(nextYear, nextMonth, 1, 0, 0, 0, 0).UnixTimestamp
	return cycle(startsAt, endsAt)
end

local function withClub(id: string): Config
	local config: any = table.clone(Monetization)
	config.subscriptions = { [Monetization.club.key] = id }
	return config
end

type World = {
	player: Player,
	data: Types.PlayerData,
	loaded: boolean,
	studio: boolean,
	now: number,
	subscribed: boolean,
	statusFails: boolean,
	history: { any }?, -- the payment history; nil: one paid cycle covering now, the 1st to the 1st (monthCycle)
	historyFails: boolean, -- the payment history can't be read
	calls: { string },
	prompts: { string },
	attributes: { [string]: any },
	notes: { string },
	scheduled: { number }, -- seconds until each recheck asked for
}

local function count(list: { string }, item: string): number
	local found = 0
	for _, entry in list do
		if entry == item then
			found += 1
		end
	end
	return found
end

local function makeWorld(config: Config, now: number): World
	local fakePlayer: any = { UserId = USER_ID, Name = "ClubDriver" }
	local world: World = {
		player = fakePlayer :: Player,
		data = Template.new(now),
		loaded = true,
		studio = false,
		now = now,
		subscribed = false,
		statusFails = false,
		history = nil,
		historyFails = false,
		calls = {},
		prompts = {},
		attributes = {},
		notes = {},
		scheduled = {},
	}
	local market: any = {}
	local function record(name: string)
		table.insert(world.calls, name)
	end
	function market.UserOwnsGamePassAsync(_self: any, _userId: number, _passId: number): boolean
		record("UserOwnsGamePassAsync")
		return false
	end
	function market.GetUserSubscriptionStatusAsync(_self: any, _player: any, id: string): any
		record("GetUserSubscriptionStatusAsync")
		if world.statusFails then
			error("subscription service unavailable")
		end
		local member = world.subscribed and id == CLUB_ID
		return { IsSubscribed = member, IsRenewing = member }
	end
	function market.GetUserSubscriptionPaymentHistoryAsync(_self: any, _player: any, _id: string): any
		record("GetUserSubscriptionPaymentHistoryAsync")
		if world.historyFails then
			error("payment history unavailable")
		end
		return world.history or { monthCycle(world.now) }
	end
	function market.PromptSubscriptionPurchase(_self: any, _player: any, id: string)
		record("PromptSubscriptionPurchase")
		table.insert(world.prompts, `PromptSubscriptionPurchase:{id}`)
	end
	function market.GetProductInfoAsync(_self: any, _id: number, _infoType: any): any
		record("GetProductInfoAsync")
		return {}
	end
	function market.GetSubscriptionProductInfoAsync(_self: any, _id: string): any
		record("GetSubscriptionProductInfoAsync")
		return {}
	end
	MonetizationService.setDeps({
		marketplace = market,
		data = {
			get = function(_player: Player): Types.PlayerData?
				return if world.loaded then world.data else nil
			end,
			update = function(_player: Player, fn: (data: Types.PlayerData) -> ()): boolean
				if not world.loaded then
					return false
				end
				fn(world.data)
				return true
			end,
			waitFor = function(_player: Player, _timeout: number?): Types.PlayerData?
				return if world.loaded then world.data else nil
			end,
		},
		config = config,
		offers = Offers,
		clock = function(): number
			return world.now
		end,
		isStudio = function(): boolean
			return world.studio
		end,
		playerByUserId = function(userId: number): Player?
			return if userId == USER_ID then world.player else nil
		end,
		setAttribute = function(_player: Player, name: string, value: any)
			world.attributes[name] = value
		end,
		sendStore = function(_player: Player, _payload: any) end,
		notify = function(_player: Player, text: string)
			table.insert(world.notes, text)
		end,
		push = function(_player: Player) end,
		recordCash = function(_player: Player, _amount: number, _reason: string) end,
		eventBonus = function(_now: number): number
			return 0
		end,
		schedule = function(seconds: number, _fn: () -> ()): thread?
			table.insert(world.scheduled, seconds)
			return nil
		end,
		cancel = function(_thread: thread) end,
		spawn = function(fn: () -> ())
			fn()
		end,
		limitedIds = function(): { [string]: number }
			return {}
		end,
		flagOn = function(_name: string): boolean
			return true
		end,
	})
	return world
end

-- The player leaves and joins again (a new server session: everything cached about them is forgotten).
local function rejoin(world: World)
	MonetizationService.forget(world.player)
	MonetizationService.onJoin(world.player)
end

local function balance(world: World): number
	return world.data.credits.balance
end

return function(t: Harness.Api)
	local monthly = Monetization.club.monthlyCredits

	t.describe("Voltage Club", function()
		t.it("grants the monthly credits once per billing month, across rejoins", function()
			local world = makeWorld(withClub(CLUB_ID), at(2026, 10, 15))
			world.subscribed = true
			MonetizationService.onJoin(world.player)
			t.expect(MonetizationService.isClubMember(world.player)).toBe(true)
			t.expect(balance(world)).toBe(monthly)
			t.expect(world.data.club.lastGrantMonth).toBe("2026-10")
			t.expect(#world.notes).toBe(1)

			-- Later the same month: a rejoin and a status change grant nothing more.
			world.now = at(2026, 10, 28)
			rejoin(world)
			MonetizationService.subscriptionChanged(world.player, CLUB_ID)
			t.expect(balance(world)).toBe(monthly)

			-- Next month: once more, and only once.
			world.now = at(2026, 11, 2)
			rejoin(world)
			t.expect(balance(world)).toBe(monthly * 2)
			t.expect(world.data.club.lastGrantMonth).toBe("2026-11")
			rejoin(world)
			MonetizationService.refreshClub(world.player)
			t.expect(balance(world)).toBe(monthly * 2)
		end)

		t.it("counts the month the paid cycle started, so a cycle from the 30th pays once", function()
			local startsAt, endsAt = at(2026, 10, 30), at(2026, 11, 30)
			local world = makeWorld(withClub(CLUB_ID), startsAt + HOUR)
			world.subscribed = true
			world.history = { cycle(startsAt, endsAt) }
			MonetizationService.onJoin(world.player)
			t.expect(balance(world)).toBe(monthly)
			t.expect(world.data.club.lastGrantMonth).toBe("2026-10")
			-- The next check is due when the paid cycle ends.
			t.expect(world.scheduled[#world.scheduled]).toBe(endsAt - world.now)

			-- November 5th is still the cycle that started in October.
			world.now = at(2026, 11, 5)
			rejoin(world)
			t.expect(balance(world)).toBe(monthly)

			-- The renewal on November 30th starts a new billing month.
			local nextEnd = at(2026, 12, 30)
			world.history = { cycle(startsAt, endsAt), cycle(endsAt, nextEnd) }
			world.now = endsAt + HOUR
			rejoin(world)
			t.expect(balance(world)).toBe(monthly * 2)
			t.expect(world.data.club.lastGrantMonth).toBe("2026-11")
		end)

		t.it("switches the perks off when the subscription lapses, and grants nothing while lapsed", function()
			local config = withClub(CLUB_ID)
			local world = makeWorld(config, at(2026, 10, 15))
			world.subscribed = true
			MonetizationService.onJoin(world.player)
			local attributes = config.attributes
			local slots = config.club.slots
			t.expect(world.attributes[attributes.club]).toBe(true)
			t.expect(world.attributes[attributes.customBonus]).toBe(slots.customSlots)
			local _, custom = MonetizationService.slotBonus(world.player)
			t.expect(custom).toBe(slots.customSlots)
			for _, look in config.club.cosmetics do
				t.expect(MonetizationService.ownsCosmetic(world.player, look)).toBe(true)
			end

			world.subscribed = false
			MonetizationService.subscriptionChanged(world.player, CLUB_ID)
			t.expect(MonetizationService.isClubMember(world.player)).toBe(false)
			t.expect(world.attributes[attributes.club]).toBe(false)
			t.expect(world.attributes[attributes.customBonus]).toBe(0)
			local _, after = MonetizationService.slotBonus(world.player)
			t.expect(after).toBe(0)
			for _, look in config.club.cosmetics do
				t.expect(MonetizationService.ownsCosmetic(world.player, look)).toBe(false)
			end

			-- Lapsed through the next month: no credits.
			world.now = at(2026, 11, 10)
			rejoin(world)
			t.expect(MonetizationService.isClubMember(world.player)).toBe(false)
			t.expect(balance(world)).toBe(monthly)
		end)

		t.it("doesn't pay a month twice when a member lapses and comes back", function()
			local world = makeWorld(withClub(CLUB_ID), at(2026, 10, 3))
			world.subscribed = true
			MonetizationService.onJoin(world.player)
			world.subscribed = false
			MonetizationService.subscriptionChanged(world.player, CLUB_ID)
			world.now = at(2026, 10, 20)
			world.subscribed = true
			MonetizationService.subscriptionChanged(world.player, CLUB_ID)
			t.expect(MonetizationService.isClubMember(world.player)).toBe(true)
			t.expect(balance(world)).toBe(monthly)
			world.now = at(2026, 11, 20)
			rejoin(world)
			t.expect(balance(world)).toBe(monthly * 2)
		end)

		t.it("keeps what it knew when Roblox can't be asked", function()
			local world = makeWorld(withClub(CLUB_ID), at(2026, 10, 15))
			world.subscribed = true
			MonetizationService.onJoin(world.player)
			world.statusFails = true
			MonetizationService.subscriptionChanged(world.player, CLUB_ID)
			t.expect(MonetizationService.isClubMember(world.player)).toBe(true)
			t.expect(balance(world)).toBe(monthly)
			-- ... and asks again soon, so a lapse in the meantime still switches the perks off this session.
			t.expect(world.scheduled[#world.scheduled]).toBe(Monetization.club.minRecheckSeconds)

			-- A member whose first check fails isn't treated as one (or paid) until a check works.
			local fresh = makeWorld(withClub(CLUB_ID), at(2026, 10, 15))
			fresh.subscribed = true
			fresh.statusFails = true
			MonetizationService.onJoin(fresh.player)
			t.expect(MonetizationService.isClubMember(fresh.player)).toBe(false)
			t.expect(balance(fresh)).toBe(0)
			fresh.statusFails = false
			MonetizationService.subscriptionChanged(fresh.player, CLUB_ID)
			t.expect(balance(fresh)).toBe(monthly)
		end)

		t.it("pays only for a cycle Roblox lists as paid, and checks again soon when none covers now", function()
			-- A new member whose payment isn't listed yet: a member, but no credits until it is.
			local world = makeWorld(withClub(CLUB_ID), at(2026, 10, 15))
			world.subscribed = true
			world.history = {}
			MonetizationService.onJoin(world.player)
			t.expect(MonetizationService.isClubMember(world.player)).toBe(true)
			t.expect(balance(world)).toBe(0)
			t.expect(world.scheduled[#world.scheduled]).toBe(Monetization.club.minRecheckSeconds)
			world.history = nil -- now listed: one paid cycle covering today
			MonetizationService.refreshClub(world.player)
			t.expect(balance(world)).toBe(monthly)

			-- A payment history that can't be read pays nothing either.
			local unread = makeWorld(withClub(CLUB_ID), at(2026, 10, 15))
			unread.subscribed = true
			unread.historyFails = true
			MonetizationService.onJoin(unread.player)
			t.expect(MonetizationService.isClubMember(unread.player)).toBe(true)
			t.expect(balance(unread)).toBe(0)
			t.expect(unread.scheduled[#unread.scheduled]).toBe(Monetization.club.minRecheckSeconds)
		end)

		t.it("never pays a month nobody paid for while Roblox is slow to say a member lapsed", function()
			-- A cancelled member's last cycle runs October 15th to November 15th.
			local startsAt, endsAt = at(2026, 10, 15), at(2026, 11, 15)
			local world = makeWorld(withClub(CLUB_ID), at(2026, 10, 20))
			world.subscribed = true
			world.history = { cycle(startsAt, endsAt) }
			MonetizationService.onJoin(world.player)
			t.expect(balance(world)).toBe(monthly)
			t.expect(world.data.club.lastGrantMonth).toBe("2026-10")

			-- The cycle has ended but Roblox still says subscribed: no paid cycle covers now, so nothing is paid.
			world.now = endsAt + HOUR
			MonetizationService.refreshClub(world.player)
			t.expect(balance(world)).toBe(monthly)
			t.expect(world.scheduled[#world.scheduled]).toBe(Monetization.club.minRecheckSeconds)

			-- Nor on a rejoin in November whose payment history can't be read.
			world.now = at(2026, 11, 20)
			world.historyFails = true
			rejoin(world)
			t.expect(balance(world)).toBe(monthly)
			t.expect(world.data.club.lastGrantMonth).toBe("2026-10")
		end)

		t.it("waits for the save before paying, then pays once", function()
			local world = makeWorld(withClub(CLUB_ID), at(2026, 10, 15))
			world.subscribed = true
			world.loaded = false
			MonetizationService.onJoin(world.player)
			t.expect(MonetizationService.isClubMember(world.player)).toBe(true)
			t.expect(balance(world)).toBe(0)
			world.loaded = true
			MonetizationService.subscriptionChanged(world.player, CLUB_ID)
			MonetizationService.subscriptionChanged(world.player, CLUB_ID)
			t.expect(balance(world)).toBe(monthly)
		end)

		t.it("ignores status changes of other subscriptions", function()
			local world = makeWorld(withClub(CLUB_ID), at(2026, 10, 15))
			MonetizationService.onJoin(world.player)
			local asked = count(world.calls, "GetUserSubscriptionStatusAsync")
			MonetizationService.subscriptionChanged(world.player, OTHER_SUBSCRIPTION)
			t.expect(count(world.calls, "GetUserSubscriptionStatusAsync")).toBe(asked)
		end)

		t.it("never asks Roblox while the subscription isn't created, and nobody is a member", function()
			local config = withClub("")
			local world = makeWorld(config, at(2026, 10, 15))
			world.subscribed = true
			MonetizationService.onJoin(world.player)
			MonetizationService.subscriptionChanged(world.player, "")
			t.expect(MonetizationService.isClubMember(world.player)).toBe(false)
			local answer = MonetizationService.joinClub(world.player)
			t.expect(answer.ok).toBe(false)
			t.expect(answer.comingSoon).toBe(true)
			t.expect(MonetizationService.storeSnapshot(world.player).club.available).toBe(false)
			t.expect(count(world.calls, "GetUserSubscriptionStatusAsync")).toBe(0)
			t.expect(count(world.calls, "GetSubscriptionProductInfoAsync")).toBe(0)
			t.expect(world.prompts).toEqual({})
			t.expect(balance(world)).toBe(0)
		end)

		t.it("prompts JoinClub for non-members only", function()
			local config = withClub(CLUB_ID)
			local world = makeWorld(config, at(2026, 10, 15))
			MonetizationService.onJoin(world.player)
			t.expect(MonetizationService.joinClub(world.player).ok).toBe(true)
			t.expect(world.prompts).toEqual({ `PromptSubscriptionPurchase:{CLUB_ID}` })
			world.subscribed = true
			MonetizationService.subscriptionChanged(world.player, CLUB_ID)
			t.expect(MonetizationService.joinClub(world.player).message).toBe(config.messages.alreadyMember)
			t.expect(#world.prompts).toBe(1)
		end)

		t.it("can be tried in Studio before it exists, paying once a month, and never outside Studio", function()
			local outside = makeWorld(withClub(""), at(2026, 10, 15))
			MonetizationService.onJoin(outside.player)
			t.expect(MonetizationService.devPurchase(outside.player, { key = "club" }).ok).toBe(false)
			t.expect(MonetizationService.isClubMember(outside.player)).toBe(false)

			local world = makeWorld(withClub(""), at(2026, 10, 15))
			world.studio = true
			MonetizationService.onJoin(world.player)
			t.expect(MonetizationService.devPurchase(world.player, { key = "club" }).ok).toBe(true)
			MonetizationService.devPurchase(world.player, { key = "club" })
			t.expect(MonetizationService.isClubMember(world.player)).toBe(true)
			t.expect(balance(world)).toBe(monthly)
			t.expect(count(world.calls, "GetUserSubscriptionStatusAsync")).toBe(0)
			t.expect(count(world.calls, "GetUserSubscriptionPaymentHistoryAsync")).toBe(0)
		end)
	end)

	t.describe("Voltage Club billing month", function()
		t.it("finds no paid cycle without a payment history (and names the UTC month of now)", function()
			local month, cycleEnd, found = MonetizationService.billingMonth(at(2026, 1, 31), nil)
			t.expect(month).toBe("2026-01")
			t.expect(cycleEnd).toBe(nil)
			t.expect(found).toBe(false)
			local empty, _, foundEmpty = MonetizationService.billingMonth(at(2026, 12, 1), {})
			t.expect(empty).toBe("2026-12")
			t.expect(foundEmpty).toBe(false)
		end)

		t.it("is the month the paid cycle covering now started, and gives that cycle's end", function()
			local startsAt, endsAt = at(2026, 3, 29), at(2026, 4, 29)
			local month, cycleEnd, found =
				MonetizationService.billingMonth(at(2026, 4, 10), { cycle(startsAt, endsAt) })
			t.expect(month).toBe("2026-03")
			t.expect(cycleEnd).toBe(endsAt)
			t.expect(found).toBe(true)
			-- Plain Unix seconds work too.
			local plain = { { CycleStartTime = startsAt, CycleEndTime = endsAt, PaymentStatus = "Paid" } }
			t.expect((MonetizationService.billingMonth(at(2026, 4, 10), plain))).toBe("2026-03")
		end)

		t.it("ignores refunded cycles and cycles that don't cover now", function()
			local startsAt, endsAt = at(2026, 3, 29), at(2026, 4, 29)
			local refunded = { cycle(startsAt, endsAt, "Refunded") }
			local month, cycleEnd, found = MonetizationService.billingMonth(at(2026, 4, 10), refunded)
			t.expect(month).toBe("2026-04")
			t.expect(cycleEnd).toBe(nil)
			t.expect(found).toBe(false)
			local old = { cycle(at(2026, 1, 1), at(2026, 2, 1)) }
			t.expect((MonetizationService.billingMonth(at(2026, 4, 10), old))).toBe("2026-04")
		end)

		t.it("is due once per month key", function()
			local data = Template.new(at(2026, 10, 1))
			t.expect(MonetizationService.clubGrantDue(data, "2026-10")).toBe(true)
			data.club.lastGrantMonth = "2026-10"
			t.expect(MonetizationService.clubGrantDue(data, "2026-10")).toBe(false)
			t.expect(MonetizationService.clubGrantDue(data, "2026-11")).toBe(true)
		end)
	end)

	t.describe("Clean-up", function()
		t.it("puts the real dependencies back", function()
			MonetizationService.resetDeps()
			t.expect(MonetizationService.isClubMember((({ UserId = USER_ID }) :: any) :: Player)).toBe(false)
		end)
	end)
end
