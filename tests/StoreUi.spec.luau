--!strict
-- The store's client screens (docs/phase-12-contracts.md "Store UI"): price text from the server's numbers (never a
-- typed Robux amount), the "Coming soon" state for anything not on sale (an id of 0), items this player can't buy
-- now and a closed store, GetStore replies read defensively, what a product gives and what credits buy in plain
-- words, event, drop and daily-reward countdowns under a fake clock, which one-time offer may show, the Store app on
-- the phone, and touch targets and contrast (UI/Store/StoreStyle). Pure logic on fixtures (UI/Store/StoreModel):
-- runs in Edit mode and never touches module state or the network.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")

local Economy = require(ReplicatedStorage.Shared.Config.Economy)
local Harness = require(ReplicatedStorage.Shared.Testing.Harness)
local Season = require(ReplicatedStorage.Shared.Config.Season)

local Client = StarterPlayer.StarterPlayerScripts.Client
local Theme = require(Client.UI.Theme)
local PhoneConfig = require(Client.UI.Phone.PhoneConfig)
local StoreModel = require(Client.UI.Store.StoreModel)
local StoreStyle = require(Client.UI.Store.StoreStyle)

local MIN_TARGET = 44
local MIN_CONTRAST = 4.5
local DAY = 86400
local HOUR = 3600
local MINUTE = 60

local copy = StoreStyle.copy

-- A fake clock: midday UTC on some day, in server UTC seconds.
local TODAY = 20000
local NOW = TODAY * DAY + 12 * HOUR

-- Robux amounts for the fixtures, worked out rather than typed, so no Robux price appears in source.
local function robux(hundreds: number): number
	return hundreds * 100
end

local function priceOf(amount: number): string
	return string.format(copy.robux, StoreModel.groupDigits(amount))
end

-- A GetStore reply shaped like MonetizationService.storeSnapshot (docs/phase-12-contracts.md, pinned payload).
local function payload(): { [string]: any }
	return {
		open = true,
		products = {
			{
				key = "credits15",
				name = "15 Design Credits",
				kind = "credits",
				grants = { credits = 15, bonus = 3 },
				price = robux(4),
				available = true,
				canBuy = true,
			},
			{
				key = "credits5",
				name = "5 Design Credits",
				kind = "credits",
				grants = { credits = 5 },
				available = true,
			},
			{
				key = "credits40",
				name = "40 Design Credits",
				kind = "credits",
				grants = { credits = 40, bonus = 12 },
				price = robux(9),
				available = false,
				canBuy = false,
				note = "Coming soon!",
			},
			{
				key = "starterPack",
				name = "Starter Pack",
				kind = "starter",
				grants = { credits = 5, cash = 25000, customSlots = 1, cosmetics = { "starter_wrap" } },
				price = robux(3),
				available = true,
				canBuy = true,
				owned = false,
			},
			{
				key = "customSlot",
				name = "Extra Custom Car Slot",
				kind = "slot",
				grants = { customSlots = 1 },
				available = true,
				canBuy = false,
				note = "You have as many custom car slots as you can get.",
			},
			{ key = "cash1", name = "Cash Stack", kind = "cash", grants = { cash = 50000 }, available = false },
			{ key = "credits15", name = "a duplicate", kind = "credits", grants = {}, available = true },
			{ name = "no key", kind = "credits", available = true },
			"not a product",
		},
		passes = {
			{
				key = "vip",
				name = "VIP",
				perks = { "+20% pay from every job", "A VIP tag in chat", 7 },
				price = robux(2),
				owned = false,
				available = true,
			},
			{
				key = "fleetManager",
				name = "Fleet Manager",
				perks = {},
				owned = false,
				available = false,
				price = robux(1),
			},
			{ key = "garagePlus", name = "Garage+", perks = {}, owned = true, available = true },
		},
		club = { available = false, member = false, price = robux(5), monthlyCredits = 10, perks = {} },
		offers = {
			-- As MonetizationService.storeSnapshot sends it: due = up now, shown = already bought.
			{ id = "starter", productKey = "starterPack", shown = false, due = true },
			{ id = "broken" },
		},
		credits = 0,
	}
end

local function store(raw: { [string]: any }?): StoreModel.Store
	local normalized = StoreModel.normalize(raw or payload())
	assert(normalized, "normalized")
	return normalized
end

local function product(from: StoreModel.Store, key: string): StoreModel.Product
	local found = StoreModel.product(from, key)
	assert(found, key)
	return found
end

-- WCAG relative luminance and contrast ratio.
local function luminance(color: Color3): number
	local function channel(value: number): number
		return if value <= 0.03928 then value / 12.92 else ((value + 0.055) / 1.055) ^ 2.4
	end
	return 0.2126 * channel(color.R) + 0.7152 * channel(color.G) + 0.0722 * channel(color.B)
end

local function contrast(a: Color3, b: Color3): number
	local la, lb = luminance(a), luminance(b)
	return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05)
end

local function strings(value: any, into: { string })
	if type(value) == "string" then
		table.insert(into, value)
	elseif type(value) == "table" then
		for _, item in value do
			strings(item, into)
		end
	end
end

return function(t: Harness.Api)
	t.describe("Store prices", function()
		t.it("groups digits with the cash separator", function()
			t.expect(StoreModel.groupDigits(0)).toBe("0")
			t.expect(StoreModel.groupDigits(999)).toBe("999")
			t.expect(StoreModel.groupDigits(1000)).toBe("1,000")
			t.expect(StoreModel.groupDigits(1234567)).toBe("1,234,567")
			t.expect(StoreModel.groupDigits(12.9)).toBe("12")
			t.expect(Economy.display.thousandsSeparator).toBe(",")
		end)

		t.it("shows the server's number with the Robux icon", function()
			local amount = robux(12)
			t.expect(StoreModel.priceText(amount)).toBe(string.format(copy.robux, "1,200"))
			t.expect(string.find(StoreModel.priceText(amount), "\u{E002}", 1, true) ~= nil).toBe(true)
		end)

		t.it("says Buy when the price didn't load or isn't a real price", function()
			t.expect(StoreModel.priceText(nil)).toBe(copy.buy)
			t.expect(StoreModel.priceText(0)).toBe(copy.buy)
			t.expect(StoreModel.priceText(-robux(1))).toBe(copy.buy)
			t.expect(StoreModel.priceText(0 / 0)).toBe(copy.buy)
		end)

		t.it("never writes a Robux amount in its words", function()
			local all: { string } = {}
			strings(StoreStyle.copy, all)
			for _, line in all do
				local lower = string.lower(line)
				local typed = string.find(lower, "\u{E002}%s*%d") ~= nil
					or string.find(lower, "r%$%s*%d") ~= nil
					or string.find(lower, "%d%s*r%$") ~= nil
					or string.find(lower, "%d[%d,%.]*%s*robux") ~= nil
					or string.find(lower, "robux%s*[=:]%s*%d") ~= nil
				t.expect(`{line}: {typed}`).toBe(`{line}: false`)
			end
			t.expect(string.find(copy.robux, "%d") == nil).toBe(true)
		end)
	end)

	t.describe("Coming soon and can't-buy-now", function()
		t.it("never sells an item the server didn't put on sale, and drops its price", function()
			local big = product(store(), "credits40")
			t.expect(big.available).toBe(false)
			t.expect(big.price).toBe(nil)
			t.expect(StoreModel.itemState(big)).toBe("comingSoon")
			t.expect(StoreModel.buttonLabel(big, false)).toBe(nil)
			t.expect(StoreModel.pillText("comingSoon")).toBe(copy.comingSoon)
		end)

		t.it("sells an item on sale for the price the server sent", function()
			local current = store()
			local pack = product(current, "credits15")
			t.expect(StoreModel.itemState(pack)).toBe("buy")
			t.expect(StoreModel.buttonLabel(pack, false)).toBe(priceOf(robux(4)))
			t.expect(StoreModel.buttonLabel(pack, true)).toBe(copy.opening)
			t.expect(StoreModel.buttonLabel(product(current, "credits5"), false)).toBe(copy.buy)
		end)

		t.it("shows the server's note instead of a button for an item this player can't buy now", function()
			local slot = product(store(), "customSlot")
			t.expect(StoreModel.itemState(slot)).toBe("blocked")
			t.expect(StoreModel.buttonLabel(slot, false)).toBe(nil)
			t.expect(StoreModel.pillText("blocked")).toBe(nil)
			t.expect(StoreModel.noteText(slot)).toBe("You have as many custom car slots as you can get.")
			t.expect(StoreModel.noteText({ note = nil })).toBe(copy.unavailable)
		end)

		t.it("sells nothing while the store is closed", function()
			local raw = payload()
			raw.open = false
			raw.club = { available = true, member = false, price = robux(5), monthlyCredits = 10 }
			local closed = store(raw)
			t.expect(closed.open).toBe(false)
			local pack = product(closed, "credits15")
			t.expect(StoreModel.itemState(pack)).toBe("blocked")
			t.expect(StoreModel.noteText(pack)).toBe(copy.storeClosed)
			t.expect(StoreModel.itemState(closed.passes[1])).toBe("blocked")
			t.expect(StoreModel.clubButton(closed.club, false)).toBe(nil)
			t.expect((StoreModel.dueOffer(closed, "starter"))).toBe(nil)
		end)

		t.it("shows Owned for a pass the player has, with no button", function()
			local current = store()
			local owned = current.passes[3]
			t.expect(owned.key).toBe("garagePlus")
			t.expect(StoreModel.itemState(owned)).toBe("owned")
			t.expect(StoreModel.buttonLabel(owned, false)).toBe(nil)
			t.expect(StoreModel.pillText("owned")).toBe(copy.owned)
			local soon = current.passes[2]
			t.expect(soon.price).toBe(nil)
			t.expect(StoreModel.itemState(soon)).toBe("comingSoon")
		end)

		t.it("shows the club as coming soon until it's on sale", function()
			local club = store().club
			t.expect(club.available).toBe(false)
			t.expect(club.price).toBe(nil)
			t.expect(StoreModel.clubButton(club, false)).toBe(nil)
			t.expect(StoreModel.clubLines(club)).toEqual({ string.format(copy.clubCredits, "10 credits") })

			local function clubOf(raw: { [string]: any }): StoreModel.Club
				return store({ club = raw }).club
			end
			local onSale = clubOf({ available = true, member = false, price = robux(5), monthlyCredits = 10 })
			t.expect(StoreModel.clubButton(onSale, false)).toBe(string.format(copy.clubJoin, priceOf(robux(5))))
			t.expect(StoreModel.clubButton(onSale, true)).toBe(copy.opening)
			local local_ =
				clubOf({ available = true, member = false, displayPrice = "local price", monthlyCredits = 10 })
			t.expect(StoreModel.clubButton(local_, false)).toBe(string.format(copy.clubJoin, "local price"))
			local member = clubOf({ available = true, member = true, price = robux(5), monthlyCredits = 10 })
			t.expect(StoreModel.clubButton(member, false)).toBe(nil)
			local noPrice = clubOf({ available = true, member = false, monthlyCredits = 0 })
			t.expect(StoreModel.clubButton(noPrice, false)).toBe(copy.clubJoinNoPrice)
			t.expect(StoreModel.clubLines(noPrice)).toEqual({})
			local perks = clubOf({ available = true, perks = { "The club lounge", 3 }, monthlyCredits = 10 })
			t.expect(StoreModel.clubLines(perks)).toEqual({ "The club lounge" })
		end)
	end)

	t.describe("GetStore replies", function()
		t.it("keeps good items once each and drops broken ones", function()
			local current = store()
			t.expect(#current.products).toBe(6)
			t.expect(#current.passes).toBe(3)
			t.expect(current.passes[1].perks).toEqual({ "+20% pay from every job", "A VIP tag in chat" })
			t.expect(#current.offers).toBe(1)
			t.expect(product(current, "credits15").name).toBe("15 Design Credits")
		end)

		t.it("survives a reply that isn't a store", function()
			t.expect(StoreModel.normalize(nil)).toBe(nil)
			t.expect(StoreModel.normalize("nope")).toBe(nil)
			local empty = store({})
			t.expect(#empty.products).toBe(0)
			t.expect(empty.open).toBe(true)
			t.expect(empty.club.available).toBe(false)
		end)

		t.it("lists packs smallest first, whatever order they came in", function()
			local packs = StoreModel.productsOf(store(), { "credits" })
			t.expect(#packs).toBe(3)
			t.expect(packs[1].key).toBe("credits5")
			t.expect(packs[2].key).toBe("credits15")
			t.expect(packs[3].key).toBe("credits40")
			t.expect(#StoreModel.productsOf(nil, { "credits" })).toBe(0)
		end)

		t.it("works out a kind the server left out from the grants", function()
			local current = store({
				products = {
					{ key = "a", grants = { credits = 5 }, available = true },
					{ key = "b", grants = { cash = 100 }, available = true },
					{ key = "c", grants = { look = "wrap" }, available = true },
				},
			})
			t.expect(current.products[1].kind).toBe("credits")
			t.expect(current.products[2].kind).toBe("cash")
			t.expect(current.products[3].kind).toBe("cosmetic")
		end)
	end)

	t.describe("What things give", function()
		t.it("counts the bonus into a pack's credits", function()
			t.expect(StoreModel.grantLines({ credits = 15, bonus = 3 })).toEqual({
				string.format(copy.grantCredits, "18"),
			})
			t.expect(StoreModel.grantLines({ credits = 1 })).toEqual({ copy.grantOneCredit })
		end)

		t.it("describes the Starter Pack in plain words", function()
			local starter = product(store(), "starterPack")
			t.expect(StoreModel.grantLines(starter.grants)).toEqual({
				string.format(copy.grantCredits, "5"),
				string.format(copy.grantCash, "$25,000"),
				copy.grantCustomSlot,
				copy.grantLook,
			})
			t.expect(StoreModel.grantLines({ customSlots = 2, garageSlots = 10, plateFrame = true })).toEqual({
				string.format(copy.grantCustomSlots, 2),
				string.format(copy.grantGarageSlots, 10),
				copy.grantPlateFrame,
			})
			t.expect(StoreModel.grantLines({ look = "wrap", cosmetics = { "a", "b" } })).toEqual({
				copy.grantWrap,
				string.format(copy.grantLooks, 2),
			})
			t.expect(StoreModel.grantLines({ mystery = 3 })).toEqual({})
		end)

		t.it("titles packs by what they give", function()
			local current = store()
			local pack = product(current, "credits15")
			t.expect(StoreModel.packTitle(pack)).toBe("15 credits")
			t.expect(StoreModel.packDetail(pack)).toBe(string.format(copy.bonus, "3"))
			t.expect(StoreModel.packDetail(product(current, "credits5"))).toBe(nil)
			t.expect(StoreModel.packTitle(product(current, "cash1"))).toBe("$50,000")
			t.expect(StoreModel.packTitle(product(current, "starterPack"))).toBe("Starter Pack")
		end)

		t.it("says what credits buy from the designer's prices", function()
			local uses = StoreModel.creditUses({ newCar = 2, mod = 1, rerollsPaid = 1 })
			t.expect(uses[1]).toBe(string.format(copy.useMod, "1 credit"))
			t.expect(uses[2]).toBe(string.format(copy.rerollOne, string.format(copy.useCar, "2 credits")))
			local none = StoreModel.creditUses({ newCar = 3, mod = 2, rerollsPaid = 0 })
			t.expect(none[2]).toBe(string.format(copy.useCar, "3 credits"))
		end)
	end)

	t.describe("Countdowns", function()
		t.it("writes whole units, largest first", function()
			t.expect(StoreModel.countdownText(0)).toBe(copy.now)
			t.expect(StoreModel.countdownText(-5)).toBe(copy.now)
			t.expect(StoreModel.countdownText(9)).toBe("9s")
			t.expect(StoreModel.countdownText(59.9)).toBe("59s")
			t.expect(StoreModel.countdownText(2 * MINUTE + 5)).toBe("2m 05s")
			t.expect(StoreModel.countdownText(HOUR + 2 * MINUTE + 5)).toBe("1h 2m")
			t.expect(StoreModel.countdownText(DAY + HOUR + MINUTE + 1)).toBe("1d 1h")
		end)

		t.it("redraws right after the shown text changes, not every frame", function()
			local slack = StoreStyle.countdownSlackSeconds
			t.expect(StoreModel.tickAfter(HOUR + 50)).toBeNear(50 + slack, 1e-6)
			t.expect(StoreModel.tickAfter(9.5)).toBeNear(0.5 + slack, 1e-6)
			t.expect(StoreModel.tickAfter(DAY + 2 * HOUR)).toBeNear(HOUR + slack, 1e-6)
			t.expect(StoreModel.tickAfter(30)).toBeNear(1 + slack, 1e-6)
			-- One tick after "1h 0m" the text reads under an hour.
			local after = HOUR + 50 - StoreModel.tickAfter(HOUR + 50)
			t.expect(StoreModel.countdownText(after)).toBe("59m 59s")
		end)
	end)

	t.describe("Events and drops under a fake clock", function()
		-- An EventUpdate payload shaped like EventService.payload (with LimitedService's drops).
		local function events(): { StoreModel.Event }
			return StoreModel.normalizeEvents({
				now = NOW,
				active = {
					{
						id = "weekend",
						name = "Double cash weekend",
						startsAt = NOW - HOUR,
						endsAt = NOW + 2 * HOUR,
						earningsMultiplier = 2,
					},
				},
				upcoming = {
					{
						id = "credits",
						name = "Bonus credits",
						banner = "Make a car this weekend",
						startsAt = NOW + 100,
						endsAt = NOW + 100 + HOUR,
						bonusCredits = 0.5,
					},
					{ id = "weekend", name = "a duplicate", startsAt = NOW, endsAt = NOW + 1 },
					{ id = "backwards", name = "Backwards", startsAt = NOW + 10, endsAt = NOW },
					{ name = "no id", startsAt = NOW, endsAt = NOW + 1 },
				},
				drops = {
					{
						id = "arc_flight",
						name = "Arc Flight",
						vehicleId = "ohm_arc",
						trim = "flight",
						startsAt = NOW + DAY,
						endsAt = NOW + 2 * DAY,
						price = 250000,
						supply = 50,
						remaining = 12,
						open = false,
					},
				},
			})
		end

		t.it("reads each event once and drops broken ones", function()
			local list = events()
			t.expect(#list).toBe(3)
			t.expect(list[1].title).toBe("Double cash weekend")
			t.expect(list[2].bonusPercent).toBe(50)
			t.expect(list[2].subtitle).toBe("Make a car this weekend")
			t.expect(list[3].drop).toBe(true)
			t.expect(#StoreModel.normalizeEvents(nil)).toBe(0)
		end)

		t.it("switches an event on at its start time and off at its end", function()
			local list = events()
			local live, upcoming = StoreModel.liveEvents(list, NOW)
			t.expect(#live).toBe(1)
			t.expect(live[1].id).toBe("weekend")
			t.expect(#upcoming).toBe(2)
			t.expect(upcoming[1].id).toBe("credits")
			t.expect(StoreModel.eventCountdown(upcoming[1], NOW)).toBe(string.format(copy.startsIn, "1m 40s"))

			live, upcoming = StoreModel.liveEvents(list, NOW + 100)
			t.expect(#live).toBe(2)
			t.expect(#upcoming).toBe(1)
			-- Soonest to end first.
			t.expect(live[1].id).toBe("credits")
			t.expect(StoreModel.eventCountdown(live[1], NOW + 100)).toBe(string.format(copy.endsIn, "1h 0m"))
			t.expect(StoreModel.eventCountdown(live[2], NOW + 100)).toBe(string.format(copy.endsIn, "1h 58m"))

			live, upcoming = StoreModel.liveEvents(list, NOW + 3 * HOUR)
			t.expect(#live).toBe(0)
			t.expect(#upcoming).toBe(1)
			t.expect(StoreModel.eventCountdown(upcoming[1], NOW + 3 * HOUR))
				.toBe(string.format(copy.startsIn, "21h 0m"))

			live, upcoming = StoreModel.liveEvents(list, NOW + 3 * DAY)
			t.expect(#live).toBe(0)
			t.expect(#upcoming).toBe(0)
		end)

		t.it("knows when the banner next changes", function()
			local list = events()
			t.expect(StoreModel.soonest(list, NOW)).toBe(100)
			t.expect(StoreModel.soonest(list, NOW + 100)).toBe(HOUR)
			t.expect(StoreModel.soonest(list, NOW + 3 * HOUR)).toBe(DAY - 3 * HOUR)
			t.expect(StoreModel.soonest(list, NOW + 3 * DAY)).toBe(nil)
		end)

		t.it("says what an event or a drop does", function()
			local list = events()
			t.expect(StoreModel.eventLines(list[1])).toEqual({ string.format(copy.eventEarnings, "2") })
			t.expect(StoreModel.eventLines(list[2])).toEqual({
				"Make a car this weekend",
				string.format(copy.eventBonusCredits, "50"),
			})
			t.expect(StoreModel.eventLines(list[3])).toEqual({
				string.format(copy.dropSupply, "50"),
				string.format(copy.dropLeft, "12"),
				string.format(copy.dropPrice, Economy.formatCash(250000)),
			})
			t.expect(StoreModel.eventTag(list[1], true)).toBe(copy.eventLive)
			t.expect(StoreModel.eventTag(list[2], false)).toBe(copy.eventSoon)
			t.expect(StoreModel.eventTag(list[3], false)).toBe(copy.dropSoon)
			t.expect(StoreModel.eventTag(list[3], true)).toBe(copy.dropLive)
		end)

		t.it("offers Buy on a drop only while it's on and the server says it's open", function()
			local drop = events()[3]
			t.expect(StoreModel.canBuyDrop(drop, NOW)).toBe(false) -- not started
			t.expect(StoreModel.canBuyDrop(drop, NOW + DAY + 1)).toBe(false) -- on, but the server says closed
			local open = table.clone(drop)
			open.open = true
			t.expect(StoreModel.canBuyDrop(open, NOW + DAY + 1)).toBe(true)
			t.expect(StoreModel.canBuyDrop(open, NOW + 2 * DAY)).toBe(false) -- over
			t.expect(StoreModel.canBuyDrop(events()[1], NOW)).toBe(false) -- not a drop
		end)
	end)

	t.describe("Season Pass card", function()
		local function season(): Season.Season
			local copied: any = table.clone(Season)
			copied.id = "spec"
			copied.startsAtUtc = NOW - DAY
			copied.endsAtUtc = NOW + DAY
			copied.claimGraceSeconds = DAY
			copied.tiers = {
				{ xp = 100, free = { kind = "cash", amount = 5000 }, premium = { kind = "credits", amount = 2 } },
				{ xp = 300, free = { kind = "credits", amount = 1 }, premium = { kind = "wrap", ref = "a_wrap" } },
				{ xp = 600, free = { kind = "cash", amount = 6000 }, premium = nil },
			}
			return copied
		end

		t.it("shows the tier, the XP to the next one and the next reward on each track", function()
			local view = StoreModel.seasonView(season(), { xp = 350, premium = false, claimed = "free:1" }, NOW)
			t.expect(view.show).toBe(true)
			t.expect(view.tier).toBe(2)
			t.expect(view.tiers).toBe(3)
			t.expect(view.nextXp).toBe(600)
			t.expect(view.endsIn).toBe(DAY)
			t.expect(view.startsIn).toBe(nil)
			t.expect(view.free).toEqual({ tier = 2, track = "free", text = copy.grantOneCredit })
			t.expect(view.premiumClaim).toBe(nil)
			-- Without the pass: what the premium track would give, no button.
			t.expect(view.premiumLocked).toEqual({
				tier = 1,
				track = "premium",
				text = string.format(copy.grantCredits, "2"),
			})
		end)

		t.it("claims the premium track with the pass, and has nothing left once all is claimed", function()
			local claimed = "free:1,free:2,premium:1"
			local view = StoreModel.seasonView(season(), { xp = 350, premium = true, claimed = claimed }, NOW)
			t.expect(view.free).toBe(nil)
			t.expect(view.premiumClaim).toEqual({ tier = 2, track = "premium", text = copy.grantWrap })
			t.expect(view.premiumLocked).toBe(nil)
			local top = StoreModel.seasonView(season(), { xp = 900, premium = true, claimed = nil }, NOW)
			t.expect(top.tier).toBe(3)
			t.expect(top.nextXp).toBe(nil)
			t.expect(top.free).toEqual({ tier = 1, track = "free", text = Economy.formatCash(5000) })
		end)

		t.it("counts down to the start, claims through the grace, then goes away", function()
			local before = StoreModel.seasonView(season(), { xp = nil, premium = nil, claimed = nil }, NOW - 2 * DAY)
			t.expect(before.show).toBe(true)
			t.expect(before.startsIn).toBe(DAY)
			t.expect(before.claimable).toBe(false)
			t.expect(before.free).toBe(nil)
			local grace = StoreModel.seasonView(season(), { xp = 150, premium = false, claimed = "" }, NOW + 1.5 * DAY)
			t.expect(grace.endsIn).toBe(nil)
			t.expect(grace.claimable).toBe(true)
			t.expect(grace.free ~= nil).toBe(true)
			local gone = StoreModel.seasonView(season(), { xp = 150, premium = false, claimed = "" }, NOW + 3 * DAY)
			t.expect(gone.show).toBe(false)
			local none: any = season()
			none.id = ""
			t.expect(StoreModel.seasonView(none, { xp = 150, premium = false, claimed = "" }, NOW).show).toBe(false)
			-- Broken attributes read as nothing.
			local broken = StoreModel.seasonView(season(), { xp = "lots", premium = "yes", claimed = 7 }, NOW)
			t.expect(broken.xp).toBe(0)
			t.expect(broken.premium).toBe(false)
		end)
	end)

	t.describe("Daily reward", function()
		t.it("lets the server decide before it has said anything", function()
			local status = StoreModel.streakStatus(nil, NOW)
			t.expect(status.known).toBe(false)
			t.expect(status.claimable).toBe(true)
		end)

		t.it("follows what the server says (StreakService's attributes)", function()
			local ready = StoreModel.streakStatus({ count = 3, day = 4, claimable = true, nextAt = nil }, NOW)
			t.expect(ready.known).toBe(true)
			t.expect(ready.claimable).toBe(true)
			t.expect(ready.day).toBe(4)
			local taken =
				StoreModel.streakStatus({ count = 4, day = 4, claimable = false, nextAt = (TODAY + 1) * DAY }, NOW)
			t.expect(taken.claimable).toBe(false)
			t.expect(taken.nextIn).toBe(12 * HOUR)
		end)

		t.it("is ready once a new UTC day starts", function()
			local claimed = StoreModel.streakStatus({ count = 3, lastDay = TODAY }, NOW)
			t.expect(claimed.claimable).toBe(false)
			t.expect(claimed.nextIn).toBe(12 * HOUR)
			local yesterday = StoreModel.streakStatus({ count = 3, lastDay = TODAY - 1 }, NOW)
			t.expect(yesterday.claimable).toBe(true)
			t.expect(yesterday.day).toBe(3)
			-- A saved time in seconds works too.
			local seconds = StoreModel.streakStatus({ count = 1, lastDay = NOW - HOUR }, NOW)
			t.expect(seconds.claimable).toBe(false)
			local tomorrow = StoreModel.streakStatus({ count = 1, lastDay = TODAY }, (TODAY + 1) * DAY)
			t.expect(tomorrow.claimable).toBe(true)
		end)

		t.it("takes the streak the claim's reply sends", function()
			local reply = {
				ok = true,
				message = "Day 4 reward: $2,500!",
				streak = { count = 4, lastDay = TODAY, claimable = false, nextAt = (TODAY + 1) * DAY, day = 4 },
			}
			local after = StoreModel.streakAfterClaim(nil, reply, NOW)
			assert(after, "streak")
			t.expect(after.count).toBe(4)
			t.expect(StoreModel.streakStatus(after, NOW).claimable).toBe(false)
			local marked = StoreModel.streakAfterClaim({ count = 2, lastDay = TODAY - 1 }, { ok = true }, NOW)
			assert(marked, "streak")
			t.expect(marked.count).toBe(3)
			t.expect(StoreModel.streakStatus(marked, NOW).claimable).toBe(false)
			local refused = StoreModel.streakAfterClaim(nil, { ok = false, message = "Come back tomorrow" }, NOW)
			t.expect(refused).toBe(nil)
		end)
	end)

	t.describe("One-time offers", function()
		t.it("offers the Starter Pack while the server says it's up and it's on sale", function()
			local current = store()
			local offer, pack = StoreModel.dueOffer(current, nil)
			assert(offer and pack, "due")
			t.expect(offer.id).toBe("starter")
			t.expect(pack.key).toBe("starterPack")
			t.expect(#StoreModel.offerCards(current)).toBe(1)
			t.expect(StoreModel.badge(true, nil, NOW)).toBe(true)
		end)

		t.it("shows an offer that isn't up only when the server names it", function()
			local raw = payload()
			raw.offers[1].due = false
			local current = store(raw)
			t.expect((StoreModel.dueOffer(current, nil))).toBe(nil)
			t.expect((StoreModel.dueOffer(current, "starter")) ~= nil).toBe(true)
			t.expect(#StoreModel.offerCards(current)).toBe(0)
		end)

		t.it("never offers a pack that isn't on sale (an id of 0) or is already bought", function()
			local notCreated = payload()
			notCreated.products[4].available = false
			t.expect((StoreModel.dueOffer(store(notCreated), "starter"))).toBe(nil)
			local bought = payload()
			bought.products[4].owned = true
			bought.products[4].canBuy = false
			t.expect((StoreModel.dueOffer(store(bought), "starter"))).toBe(nil)
			t.expect(#StoreModel.offerCards(store(bought))).toBe(0)
			t.expect((StoreModel.dueOffer(nil, nil))).toBe(nil)
		end)

		t.it("reads a bought offer the way the server sends it: shown = taken, never offered again", function()
			local taken = payload()
			taken.offers[1] = { id = "starter", productKey = "starterPack", shown = true, due = false }
			taken.products[4].owned = true
			taken.products[4].canBuy = false
			local current = store(taken)
			t.expect(current.offers[1].bought).toBe(true)
			t.expect(current.offers[1].due).toBe(false)
			t.expect((StoreModel.dueOffer(current, nil))).toBe(nil)
			t.expect((StoreModel.dueOffer(current, "starter"))).toBe(nil)
			t.expect(#StoreModel.offerCards(current)).toBe(0)
			-- Even a payload that says both is read as taken.
			local both = payload()
			both.offers[1].shown = true
			t.expect(#StoreModel.offerCards(store(both))).toBe(0)
		end)

		t.it("dots the Store icon for a ready daily reward the server reported", function()
			t.expect(StoreModel.badge(false, nil, NOW)).toBe(false)
			t.expect(StoreModel.badge(false, { count = 1, lastDay = TODAY - 1 }, NOW)).toBe(true)
			t.expect(StoreModel.badge(false, { count = 1, lastDay = TODAY }, NOW)).toBe(false)
		end)
	end)

	t.describe("Store on the phone", function()
		t.it("is one of the phone's apps, once", function()
			local count = 0
			for _, app in PhoneConfig.apps do
				if app.id == "store" then
					count += 1
				end
			end
			t.expect(count).toBe(1)
		end)

		t.it("keeps its buttons big enough to tap", function()
			t.expect(StoreStyle.card.buttonHeight >= MIN_TARGET).toBe(true)
			t.expect(Theme.size.buttonHeight >= MIN_TARGET).toBe(true)
			t.expect(Theme.size.touchTarget >= MIN_TARGET).toBe(true)
		end)

		t.it("keeps its text readable on the cards", function()
			local colors = Theme.colors
			for _, color in { colors.text, colors.textDim, colors.success, colors.accent, colors.warning } do
				t.expect(contrast(color, colors.panelRaised) >= MIN_CONTRAST).toBe(true)
			end
			t.expect(contrast(colors.onAccent, colors.accent) >= MIN_CONTRAST).toBe(true)
		end)

		t.it("has a label for every page", function()
			local ids: { [string]: boolean } = {}
			for _, page in StoreStyle.pages do
				ids[page.id] = page.label ~= ""
			end
			t.expect(ids).toEqual({ credits = true, passes = true, more = true })
		end)

		t.it("waits a while for a busy screen, then gives up", function()
			t.expect(StoreStyle.offer.retrySeconds > 0).toBe(true)
			t.expect(StoreStyle.offer.maxWaitSeconds > StoreStyle.offer.retrySeconds).toBe(true)
			t.expect(StoreStyle.refreshAfterSeconds > 0).toBe(true)
			t.expect(StoreStyle.storeRetrySeconds > 0).toBe(true)
		end)
	end)
end
