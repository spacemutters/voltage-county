--!strict
-- The store's logic, with no UI and no network (docs/phase-12-contracts.md "Store UI"), so tests/StoreUi.spec can
-- check it in Edit mode with a fake clock:
--
--   normalize(payload)          a checked copy of the server's GetStore reply (MonetizationService.storeSnapshot,
--                               also the body of every StoreUpdate): { open, products, passes, club, offers }, plus
--                               `streak` and `events` when sent. Anything broken is left out or given a safe default;
--                               an item the server didn't mark available is never on sale (it shows "Coming soon"
--                               and loses its price), and while the store is closed nothing can be bought.
--   itemState(item)             "owned", "comingSoon", "blocked" (on sale, but not for this player now: the server's
--                               note says why) or "buy"
--   priceText(price)            the Robux price GetStore sent, with the Robux icon and thousands separators, or "Buy"
--                               when it didn't load
--   buttonLabel(item, busy)     the buy button's words, or nil when there is no buy button
--   grantLines(grants)          what a product gives, in plain words ("18 Design Credits", "$25,000 in cash")
--   packTitle / packDetail      a pack card's title and its bonus line
--   creditUses(prices)          what credits buy, from Config/Designer's prices
--   productsOf(store, kinds)    the products of some kinds, in a steady order (smallest pack first)
--   dueOffer(store, id?)        a one-time offer that can show now, with its product
--   normalizeEvents(payload)    the events and limited drops in an EventUpdate payload ({ active, upcoming, drops })
--   liveEvents(events, now)     which are on now and which are coming, by `now` (server UTC seconds)
--   eventLines(event)           what an event or drop does, in plain words
--   countdownText(seconds)      "1d 4h", "3h 12m", "4m 05s", "9s"
--   tickAfter(seconds)          how long until that text changes (the countdowns redraw then, not every frame)
--   soonest(events, now)        seconds until the next event starts or ends (for the banner's timer)
--   streakStatus(streak, now)   whether today's daily reward can be claimed, and when the next one comes
--   dayIndex(now)               the UTC day number the streak counts in
--   seasonView(season, input, now)  the Season Pass card: tier, XP, the countdown and the next reward each track can
--                               claim, from Config/Season and the attributes Services/SeasonService keeps
--   rewardText(reward)          a season reward in plain words ("$5,000", "2 Design Credits", "Season One Gold look")
--   canBuyDrop(event, now)      whether a limited drop in the banner can be bought now (on now and open)
--
-- Every word comes from UI/Store/StoreStyle; every price and grant from the server; time comes in as `now`.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Customization = require(ReplicatedStorage.Shared.Config.Customization)
local Economy = require(ReplicatedStorage.Shared.Config.Economy)
local Season = require(ReplicatedStorage.Shared.Config.Season)
local Catalog = require(ReplicatedStorage.Shared.Vehicle.Catalog)
local StoreStyle = require(script.Parent.StoreStyle)

-- Units, not tunables.
local SECONDS_PER_MINUTE = 60
local SECONDS_PER_HOUR = 3600
local SECONDS_PER_DAY = 86400
local DIGIT_GROUP = 3
local PERCENT = 100

local copy = StoreStyle.copy

export type Kind = "credits" | "cash" | "slot" | "starter" | "cosmetic"
export type ItemState = "comingSoon" | "owned" | "blocked" | "buy"

export type Product = {
	key: string,
	name: string,
	kind: Kind,
	grants: { [string]: any },
	price: number?, -- Robux, from MarketplaceService on the server; nil when not on sale or it didn't load
	available: boolean, -- created (its id isn't 0)
	canBuy: boolean, -- this player can buy it now (else `note` says why)
	owned: boolean, -- a one-time pack already bought
	note: string?, -- the server's words for why it can't be bought
}

export type Pass = {
	key: string,
	name: string,
	perks: { string },
	price: number?,
	owned: boolean,
	available: boolean,
	canBuy: boolean,
	note: string?,
}

export type Club = {
	available: boolean,
	canBuy: boolean,
	member: boolean,
	price: number?, -- Robux, when the subscription is priced in Robux
	displayPrice: string?, -- the local-currency price as Roblox formats it
	monthlyCredits: number,
	name: string?,
	perks: { string },
}

-- MonetizationService.storeSnapshot sends `due` (up now: one of its moments happened, it isn't bought and its
-- product is on sale) and `shown` (taken: bought, so it never shows again). Read here as:
--   due     the offer is up for this player now (the server's `due`, and not taken)
--   bought  the player already took it (the server's `shown`)
export type Offer = { id: string, productKey: string, due: boolean, bought: boolean }

-- The login streak (Services/StreakService's status): lastDay is a UTC day number (dayIndex); day is the streak
-- day a claim pays now, or the one already claimed today.
export type Streak = { count: number, day: number?, lastDay: number?, claimable: boolean?, nextAt: number? }

-- An event (Config/Events through EventService) or a limited drop (Config/Limiteds through LimitedService).
export type Event = {
	id: string,
	title: string,
	subtitle: string?, -- the banner text, when it says more than the title
	startsAt: number, -- server UTC seconds
	endsAt: number,
	earningsMultiplier: number?,
	bonusPercent: number?, -- extra credits on every credit pack, as a percentage
	featuredVehicleId: string?,
	drop: boolean,
	supply: number?, -- drops: how many are made
	remaining: number?, -- drops: how many are left, when the server knows
	cashPrice: number?, -- drops: the in-game $ price (Net BuyLimited { dropId = id })
	open: boolean?, -- drops: the server says it's on sale now (its window is open and the drops flag is on)
}

-- The Season Pass, as Services/SeasonService keeps it in player attributes (Config/Season.attributes): the XP, whether
-- the player has the premium track and the claimed rewards ("free:1,premium:1,..."). Anything missing reads as none.
export type SeasonInput = { xp: any, premium: any, claimed: any }

export type SeasonTrack = "free" | "premium"

-- A reward the player can claim now: Net ClaimSeasonReward { tier, track }.
export type SeasonClaim = { tier: number, track: SeasonTrack, text: string }

export type SeasonView = {
	show: boolean, -- a season is coming, on, or its rewards can still be claimed
	name: string,
	startsIn: number?, -- seconds, before it starts
	endsIn: number?, -- seconds, while it runs
	claimable: boolean, -- rewards can be claimed now (it started, and its grace after the end isn't over)
	tier: number, -- reached (0 before the first)
	tiers: number,
	xp: number,
	nextXp: number?, -- the XP the next tier needs (nil once every tier is reached)
	premium: boolean,
	free: SeasonClaim?, -- the lowest reached tier with an unclaimed free reward
	premiumClaim: SeasonClaim?, -- the same on the premium track (only with the pass)
	premiumLocked: SeasonClaim?, -- without the pass: the premium reward already reached that the pass would unlock
}

export type Store = {
	open: boolean, -- false while the store is switched off (nothing can be bought)
	products: { Product },
	passes: { Pass },
	club: Club,
	offers: { Offer },
	streak: Streak?,
	events: { Event }?,
}

export type Prices = { newCar: number, mod: number, rerollsPaid: number }

export type StreakStatus = {
	known: boolean, -- the server has told us the streak
	claimable: boolean, -- true when unknown too: the server decides, the button just asks
	day: number, -- the streak day to show (0: none)
	nextIn: number?, -- seconds until the next reward can be claimed, when known and not claimable now
}

local KINDS: { [string]: boolean } = { credits = true, cash = true, slot = true, starter = true, cosmetic = true }
-- The order kinds show in when a page lists several.
local KIND_ORDER: { [string]: number } = { starter = 1, credits = 2, cash = 3, slot = 4, cosmetic = 5 }

local StoreModel = {}

-- Small checks ---------------------------------------------------------------------------------------------------

local function finite(value: any): number?
	if type(value) == "number" and value == value and math.abs(value) ~= math.huge then
		return value
	end
	return nil
end

-- A whole number above zero, else nil.
local function positiveWhole(value: any): number?
	local number = finite(value)
	if number ~= nil and number > 0 and number % 1 == 0 then
		return number
	end
	return nil
end

local function text(value: any): string?
	if type(value) == "string" and value ~= "" then
		return value
	end
	return nil
end

local function textList(value: any): { string }
	local list: { string } = {}
	if type(value) == "table" then
		for _, item in value do
			local line = text(item)
			if line ~= nil then
				table.insert(list, line)
			end
		end
	end
	return list
end

-- Numbers and words ----------------------------------------------------------------------------------------------

-- 1200 -> "1,200", with the same separator as cash (Config/Economy). Whole numbers only (anything else is rounded
-- down first).
function StoreModel.groupDigits(amount: number): string
	local whole = math.floor(math.max(amount, 0))
	local digits = string.format("%d", whole)
	local parts: { string } = {}
	local first = #digits % DIGIT_GROUP
	if first > 0 then
		table.insert(parts, string.sub(digits, 1, first))
	end
	for index = first + 1, #digits, DIGIT_GROUP do
		table.insert(parts, string.sub(digits, index, index + DIGIT_GROUP - 1))
	end
	return table.concat(parts, Economy.display.thousandsSeparator)
end

-- The price GetStore sent, in Robux with the Robux icon; "Buy" when it didn't load (Roblox's own prompt shows the
-- price before anything is charged).
function StoreModel.priceText(price: number?): string
	local amount = positiveWhole(price)
	if amount == nil then
		return copy.buy
	end
	return string.format(copy.robux, StoreModel.groupDigits(amount))
end

-- "1 credit", "15 credits".
function StoreModel.creditsText(amount: number): string
	if amount == 1 then
		return copy.oneCredit
	end
	return string.format(copy.credits, StoreModel.groupDigits(amount))
end

-- Owned beats everything; an item the server didn't put on sale is "Coming soon"; one this player can't buy now is
-- blocked (its note says why); else it can be bought.
function StoreModel.itemState(item: { available: boolean, owned: boolean?, canBuy: boolean? }): ItemState
	if item.owned == true then
		return "owned"
	elseif not item.available then
		return "comingSoon"
	elseif item.canBuy == false then
		return "blocked"
	end
	return "buy"
end

-- The buy button's words, or nil when the item shows a pill or a note instead of a button.
function StoreModel.buttonLabel(
	item: { available: boolean, owned: boolean?, canBuy: boolean?, price: number? },
	busy: boolean
): string?
	if StoreModel.itemState(item) ~= "buy" then
		return nil
	end
	return if busy then copy.opening else StoreModel.priceText(item.price)
end

-- The pill an item without a buy button shows ("Owned", "Coming soon"); nil for a blocked item (it shows its note).
function StoreModel.pillText(state: ItemState): string?
	if state == "owned" then
		return copy.owned
	elseif state == "comingSoon" then
		return copy.comingSoon
	end
	return nil
end

-- Why a blocked item can't be bought: the server's note, else a plain fallback.
function StoreModel.noteText(item: { note: string? }): string
	return item.note or copy.unavailable
end

-- Normalizing the server's replies ---------------------------------------------------------------------------------

-- A product's grants: numbers, words and flags, and lists of words (the looks a pack unlocks).
local function grantsOf(value: any): { [string]: any }
	local grants: { [string]: any } = {}
	if type(value) == "table" then
		for key, item in value do
			if type(key) ~= "string" then
				continue
			elseif finite(item) ~= nil or type(item) == "string" or type(item) == "boolean" then
				grants[key] = item
			elseif type(item) == "table" then
				grants[key] = textList(item)
			end
		end
	end
	return grants
end

local function kindOf(value: any, grants: { [string]: any }): Kind
	if type(value) == "string" and KINDS[value] then
		return value :: Kind
	elseif positiveWhole(grants.credits) ~= nil then
		return "credits"
	elseif positiveWhole(grants.cash) ~= nil then
		return "cash"
	end
	return "cosmetic"
end

local function normalizeProduct(raw: any, open: boolean): Product?
	if type(raw) ~= "table" then
		return nil
	end
	local key = text(raw.key)
	if key == nil then
		return nil
	end
	local grants = grantsOf(raw.grants)
	local available = raw.available == true
	return {
		key = key,
		name = text(raw.name) or key,
		kind = kindOf(raw.kind, grants),
		grants = grants,
		price = if available then positiveWhole(raw.price) else nil,
		available = available,
		canBuy = available and open and raw.canBuy ~= false,
		owned = raw.owned == true,
		note = text(raw.note) or (if open then nil else copy.storeClosed),
	}
end

local function normalizePass(raw: any, open: boolean): Pass?
	if type(raw) ~= "table" then
		return nil
	end
	local key = text(raw.key)
	if key == nil then
		return nil
	end
	local available = raw.available == true
	return {
		key = key,
		name = text(raw.name) or key,
		perks = textList(raw.perks),
		price = if available then positiveWhole(raw.price) else nil,
		owned = raw.owned == true,
		available = available,
		canBuy = available and open and raw.canBuy ~= false,
		note = text(raw.note) or (if open then nil else copy.storeClosed),
	}
end

local function normalizeClub(raw: any, open: boolean): Club
	local club = if type(raw) == "table" then raw else {}
	local available = club.available == true
	return {
		available = available,
		canBuy = available and open,
		member = club.member == true,
		price = if available then positiveWhole(club.price) else nil,
		displayPrice = if available then text(club.displayPrice) else nil,
		monthlyCredits = positiveWhole(club.monthlyCredits) or 0,
		name = text(club.name),
		perks = textList(club.perks),
	}
end

local function normalizeOffer(raw: any): Offer?
	if type(raw) ~= "table" then
		return nil
	end
	local id = text(raw.id)
	local productKey = text(raw.productKey)
	if id == nil or productKey == nil then
		return nil
	end
	local bought = raw.shown == true
	return { id = id, productKey = productKey, due = raw.due == true and not bought, bought = bought }
end

-- A checked streak ({ count, day?, lastDay?, claimable?, nextAt? }), or nil when there's nothing usable in it.
function StoreModel.normalizeStreak(raw: any): Streak?
	if type(raw) ~= "table" then
		return nil
	end
	local count = finite(raw.count)
	local lastDay = finite(raw.lastDay)
	local claimable: boolean? = if type(raw.claimable) == "boolean" then raw.claimable else nil
	if count == nil and lastDay == nil and claimable == nil then
		return nil
	end
	return {
		count = math.max(math.floor(count or 0), 0),
		day = positiveWhole(raw.day),
		lastDay = if lastDay ~= nil and lastDay > 0 then math.floor(lastDay) else nil,
		claimable = claimable,
		nextAt = finite(raw.nextAt),
	}
end

local function normalizeEvent(raw: any): Event?
	if type(raw) ~= "table" then
		return nil
	end
	local id = text(raw.id)
	local startsAt = finite(raw.startsAt) or finite(raw.startsAtUtc)
	local endsAt = finite(raw.endsAt) or finite(raw.endsAtUtc)
	if id == nil or startsAt == nil or endsAt == nil or endsAt <= startsAt then
		return nil
	end
	local drop = text(raw.vehicleId) ~= nil and raw.supply ~= nil
	local vehicle = if drop then Catalog.getVehicle(raw.vehicleId) else nil
	local title = text(raw.name)
		or text(raw.title)
		or text(raw.banner)
		or (if vehicle ~= nil then vehicle.displayName else nil)
		or copy.eventFallback
	local banner = text(raw.banner)
	local multiplier = finite(raw.earningsMultiplier)
	local share = finite(raw.bonusCredits)
	local percent = finite(raw.bonusPercent) or (if share ~= nil then share * PERCENT else nil)
	local remaining = finite(raw.remaining)
	return {
		id = id,
		title = title,
		subtitle = if banner ~= nil and banner ~= title then banner else nil,
		startsAt = startsAt,
		endsAt = endsAt,
		earningsMultiplier = if multiplier ~= nil and multiplier > 1 then multiplier else nil,
		bonusPercent = if percent ~= nil and percent > 0 then percent else nil,
		featuredVehicleId = text(raw.featuredVehicleId),
		drop = drop,
		supply = if drop then positiveWhole(raw.supply) else nil,
		remaining = if drop and remaining ~= nil and remaining >= 0 then math.floor(remaining) else nil,
		cashPrice = if drop then positiveWhole(raw.price) else nil,
		open = if drop then raw.open == true else nil,
	}
end

-- The events and limited drops in an EventUpdate payload ({ now, active, upcoming, drops }), a GetStore `events`
-- field, or a plain list. Each once (by id), whichever list it came in.
function StoreModel.normalizeEvents(payload: any): { Event }
	local events: { Event } = {}
	if type(payload) ~= "table" then
		return events
	end
	local seen: { [string]: boolean } = {}
	local function add(list: any)
		if type(list) ~= "table" then
			return
		end
		for _, raw in list do
			local event = normalizeEvent(raw)
			if event ~= nil and not seen[event.id] then
				seen[event.id] = true
				table.insert(events, event)
			end
		end
	end
	add(payload.active)
	add(payload.upcoming)
	add(payload.next)
	add(payload.drops)
	add(payload.events)
	add(payload)
	return events
end

-- A checked copy of a GetStore reply (or a StoreUpdate, which carries the same), or nil when it isn't one.
function StoreModel.normalize(payload: any): Store?
	if type(payload) ~= "table" then
		return nil
	end
	local open = payload.open ~= false
	local products: { Product } = {}
	local productKeys: { [string]: boolean } = {}
	if type(payload.products) == "table" then
		for _, raw in payload.products do
			local product = normalizeProduct(raw, open)
			if product ~= nil and not productKeys[product.key] then
				productKeys[product.key] = true
				table.insert(products, product)
			end
		end
	end
	local passes: { Pass } = {}
	local passKeys: { [string]: boolean } = {}
	if type(payload.passes) == "table" then
		for _, raw in payload.passes do
			local pass = normalizePass(raw, open)
			if pass ~= nil and not passKeys[pass.key] then
				passKeys[pass.key] = true
				table.insert(passes, pass)
			end
		end
	end
	local offers: { Offer } = {}
	if type(payload.offers) == "table" then
		for _, raw in payload.offers do
			local offer = normalizeOffer(raw)
			if offer ~= nil then
				table.insert(offers, offer)
			end
		end
	end
	return {
		open = open,
		products = products,
		passes = passes,
		club = normalizeClub(payload.club, open),
		offers = offers,
		streak = StoreModel.normalizeStreak(payload.streak),
		events = if payload.events ~= nil then StoreModel.normalizeEvents(payload.events) else nil,
	}
end

-- Products --------------------------------------------------------------------------------------------------------

local function amountOf(product: Product): number
	return positiveWhole(product.grants.credits) or positiveWhole(product.grants.cash) or 0
end

-- The products of these kinds: by kind (Starter Pack, credits, cash, slots, cosmetics), then smallest first, then
-- by key, so the cards never shuffle between visits.
function StoreModel.productsOf(store: Store?, kinds: { Kind }): { Product }
	local wanted: { [string]: boolean } = {}
	for _, kind in kinds do
		wanted[kind] = true
	end
	local list: { Product } = {}
	if store ~= nil then
		for _, product in store.products do
			if wanted[product.kind] then
				table.insert(list, product)
			end
		end
	end
	table.sort(list, function(a: Product, b: Product): boolean
		if a.kind ~= b.kind then
			return (KIND_ORDER[a.kind] or 0) < (KIND_ORDER[b.kind] or 0)
		end
		local amountA, amountB = amountOf(a), amountOf(b)
		if amountA ~= amountB then
			return amountA < amountB
		end
		return a.key < b.key
	end)
	return list
end

function StoreModel.product(store: Store?, key: string): Product?
	if store == nil then
		return nil
	end
	for _, product in store.products do
		if product.key == key then
			return product
		end
	end
	return nil
end

-- What a product gives, one plain line each, in a fixed order. Unknown grant fields are left out.
function StoreModel.grantLines(grants: { [string]: any }): { string }
	local lines: { string } = {}
	local credits = positiveWhole(grants.credits)
	if credits ~= nil then
		local total = credits + (positiveWhole(grants.bonus) or 0)
		table.insert(
			lines,
			if total == 1 then copy.grantOneCredit else string.format(copy.grantCredits, StoreModel.groupDigits(total))
		)
	end
	local cash = positiveWhole(grants.cash)
	if cash ~= nil then
		table.insert(lines, string.format(copy.grantCash, Economy.formatCash(cash)))
	end
	local customSlots = positiveWhole(grants.customSlots) or positiveWhole(grants.customSlot)
	if customSlots ~= nil then
		table.insert(
			lines,
			if customSlots == 1 then copy.grantCustomSlot else string.format(copy.grantCustomSlots, customSlots)
		)
	end
	local garageSlots = positiveWhole(grants.garageSlots)
	if garageSlots ~= nil then
		table.insert(
			lines,
			if garageSlots == 1 then copy.grantGarageSlot else string.format(copy.grantGarageSlots, garageSlots)
		)
	end
	-- Looks: a named wrap or plate frame, or a list of exclusive looks.
	local look = text(grants.look)
	if text(grants.wrap) ~= nil or grants.wrap == true or look == "wrap" then
		table.insert(lines, copy.grantWrap)
	end
	if text(grants.plateFrame) ~= nil or grants.plateFrame == true or look == "plate" or look == "plateFrame" then
		table.insert(lines, copy.grantPlateFrame)
	end
	-- Exclusive looks the shop knows are named, with what makes them special; any others are counted.
	local looks = 0
	if type(grants.cosmetics) == "table" then
		for _, id in grants.cosmetics do
			local named = if type(id) == "string" then StoreModel.lookName(id) else nil
			if named ~= nil then
				table.insert(lines, named)
			else
				looks += 1
			end
		end
	end
	if looks == 1 then
		table.insert(lines, copy.grantLook)
	elseif looks > 1 then
		table.insert(lines, string.format(copy.grantLooks, looks))
	end
	return lines
end

-- An exclusive look's line: "Starter Spark look: Amber pearl that slowly shifts to coral". nil for a look id the
-- shop doesn't know (Config/Customization exclusiveWraps).
function StoreModel.lookName(lookId: string): string?
	local wrap = Customization.getWrap(lookId)
	local blurb = Customization.lookBlurb(lookId)
	if wrap == nil or blurb == nil then
		return nil
	end
	return string.format(copy.grantNamedLook, wrap.displayName, blurb)
end

-- A pack card's title: "15 credits", "$50,000", else the product's name.
function StoreModel.packTitle(product: Product): string
	local credits = positiveWhole(product.grants.credits)
	if product.kind == "credits" and credits ~= nil then
		return StoreModel.creditsText(credits)
	end
	local cash = positiveWhole(product.grants.cash)
	if product.kind == "cash" and cash ~= nil then
		return Economy.formatCash(cash)
	end
	return product.name
end

-- The line under a credit pack's title: its bonus ("+3 bonus"), or nil without one.
function StoreModel.packDetail(product: Product): string?
	local bonus = positiveWhole(product.grants.bonus)
	if product.kind == "credits" and bonus ~= nil then
		return string.format(copy.bonus, StoreModel.groupDigits(bonus))
	end
	return nil
end

-- What credits buy, from Config/Designer's prices: a mod, then a new car (with its free re-rolls).
function StoreModel.creditUses(prices: Prices): { string }
	local lines = { string.format(copy.useMod, StoreModel.creditsText(prices.mod)) }
	local car = string.format(copy.useCar, StoreModel.creditsText(prices.newCar))
	if prices.rerollsPaid == 1 then
		car = string.format(copy.rerollOne, car)
	elseif prices.rerollsPaid > 1 then
		car = string.format(copy.rerollMany, car, prices.rerollsPaid)
	end
	table.insert(lines, car)
	return lines
end

-- What the club gives: the server's perks, else "10 credits every month" (or nothing).
function StoreModel.clubLines(club: Club): { string }
	if #club.perks > 0 then
		return club.perks
	elseif club.monthlyCredits > 0 then
		return { string.format(copy.clubCredits, StoreModel.creditsText(club.monthlyCredits)) }
	end
	return {}
end

-- The club's join button: "<price> a month" (Robux, or the local price Roblox formatted), "Join" when the price
-- didn't load, nil when it isn't on sale, can't be joined now, or the player is already a member.
function StoreModel.clubButton(club: Club, busy: boolean): string?
	if club.member or not club.available or not club.canBuy then
		return nil
	elseif busy then
		return copy.opening
	end
	local price = positiveWhole(club.price)
	if price ~= nil then
		return string.format(copy.clubJoin, StoreModel.priceText(price))
	end
	local display = club.displayPrice
	if display ~= nil then
		return string.format(copy.clubJoin, display)
	end
	return copy.clubJoinNoPrice
end

-- Offers ----------------------------------------------------------------------------------------------------------

-- A one-time offer that can show now, with its product: `offerId`'s offer (the server just said it came up), else
-- the first offer the server says is up for this player; either way only while its product can be bought. nil when
-- none.
function StoreModel.dueOffer(store: Store?, offerId: string?): (Offer?, Product?)
	if store == nil then
		return nil, nil
	end
	for _, offer in store.offers do
		local wanted = not offer.bought and (if offerId ~= nil then offer.id == offerId else offer.due)
		if wanted then
			local product = StoreModel.product(store, offer.productKey)
			if product ~= nil and StoreModel.itemState(product) == "buy" then
				return offer, product
			end
		end
	end
	return nil, nil
end

-- The offers the Store app shows a card for: up for this player and not taken, with their product listed. The
-- Credits page lists these for as long as they are due, so an offer sheet that was closed (or never got its moment
-- on screen) never loses the sale.
function StoreModel.offerCards(store: Store?): { { offer: Offer, product: Product } }
	local cards: { { offer: Offer, product: Product } } = {}
	if store == nil then
		return cards
	end
	for _, offer in store.offers do
		local product = StoreModel.product(store, offer.productKey)
		if offer.due and not offer.bought and product ~= nil and not product.owned then
			table.insert(cards, { offer = offer, product = product })
		end
	end
	return cards
end

-- Countdowns ------------------------------------------------------------------------------------------------------

-- Whole units, largest first: "1d 4h", "3h 12m", "4m 05s", "9s"; "now" at or past zero.
function StoreModel.countdownText(seconds: number): string
	local left = math.floor(seconds)
	if left <= 0 then
		return copy.now
	elseif left >= SECONDS_PER_DAY then
		return string.format(copy.days, left // SECONDS_PER_DAY, (left % SECONDS_PER_DAY) // SECONDS_PER_HOUR)
	elseif left >= SECONDS_PER_HOUR then
		return string.format(copy.hours, left // SECONDS_PER_HOUR, (left % SECONDS_PER_HOUR) // SECONDS_PER_MINUTE)
	elseif left >= SECONDS_PER_MINUTE then
		return string.format(copy.minutes, left // SECONDS_PER_MINUTE, left % SECONDS_PER_MINUTE)
	end
	return string.format(copy.seconds, left)
end

-- Seconds until countdownText(seconds) next changes, plus a little slack so the redraw lands after the change.
function StoreModel.tickAfter(seconds: number): number
	local unit = if seconds >= SECONDS_PER_DAY
		then SECONDS_PER_HOUR
		elseif seconds >= SECONDS_PER_HOUR then SECONDS_PER_MINUTE
		else 1
	local wait = seconds % unit
	if wait <= 0 then
		wait = unit
	end
	return wait + StoreStyle.countdownSlackSeconds
end

-- Events ----------------------------------------------------------------------------------------------------------

-- The events on now (soonest to end first) and those still to come (soonest first), by `now`. Ended ones are
-- dropped: the times decide, whatever list the server put an event in.
function StoreModel.liveEvents(events: { Event }, now: number): ({ Event }, { Event })
	local live: { Event } = {}
	local upcoming: { Event } = {}
	for _, event in events do
		if now >= event.startsAt and now < event.endsAt then
			table.insert(live, event)
		elseif now < event.startsAt then
			table.insert(upcoming, event)
		end
	end
	table.sort(live, function(a: Event, b: Event): boolean
		return if a.endsAt ~= b.endsAt then a.endsAt < b.endsAt else a.id < b.id
	end)
	table.sort(upcoming, function(a: Event, b: Event): boolean
		return if a.startsAt ~= b.startsAt then a.startsAt < b.startsAt else a.id < b.id
	end)
	return live, upcoming
end

-- Seconds until the next start or end among these events, or nil when nothing is still to happen.
function StoreModel.soonest(events: { Event }, now: number): number?
	local best: number? = nil
	for _, event in events do
		local at = if now < event.startsAt then event.startsAt elseif now < event.endsAt then event.endsAt else nil
		if at ~= nil and (best == nil or at - now < best) then
			best = at - now
		end
	end
	return best
end

-- What an event or drop does, in plain words: its banner, the cash multiplier, bonus credits, the featured car; a
-- drop's supply, what's left and its price at the dealership.
function StoreModel.eventLines(event: Event): { string }
	local lines: { string } = {}
	local subtitle = event.subtitle
	if subtitle ~= nil then
		table.insert(lines, subtitle)
	end
	local multiplier = event.earningsMultiplier
	if multiplier ~= nil then
		table.insert(lines, string.format(copy.eventEarnings, string.format("%g", multiplier)))
	end
	local percent = event.bonusPercent
	if percent ~= nil then
		table.insert(lines, string.format(copy.eventBonusCredits, string.format("%g", math.floor(percent + 0.5))))
	end
	local featured = event.featuredVehicleId
	if featured ~= nil then
		local vehicle = Catalog.getVehicle(featured)
		if vehicle ~= nil then
			table.insert(lines, string.format(copy.eventFeatured, vehicle.displayName))
		end
	end
	local supply = event.supply
	if supply ~= nil then
		table.insert(lines, string.format(copy.dropSupply, StoreModel.groupDigits(supply)))
	end
	local remaining = event.remaining
	if remaining ~= nil then
		table.insert(lines, string.format(copy.dropLeft, StoreModel.groupDigits(remaining)))
	end
	local cashPrice = event.cashPrice
	if cashPrice ~= nil then
		table.insert(lines, string.format(copy.dropPrice, Economy.formatCash(cashPrice)))
	end
	return lines
end

-- The small tag above an event: "On now" / "Coming up", or for a drop "Limited drop" / "Limited drop coming".
function StoreModel.eventTag(event: Event, live: boolean): string
	if event.drop then
		return if live then copy.dropLive else copy.dropSoon
	end
	return if live then copy.eventLive else copy.eventSoon
end

-- The countdown line under an event: "Ends in 3h 12m" while it's on, "Starts in 1d 4h" before.
function StoreModel.eventCountdown(event: Event, now: number): string
	if now < event.startsAt then
		return string.format(copy.startsIn, StoreModel.countdownText(event.startsAt - now))
	end
	return string.format(copy.endsIn, StoreModel.countdownText(event.endsAt - now))
end

-- The daily streak ------------------------------------------------------------------------------------------------

-- The UTC day number of `now` (server UTC seconds).
function StoreModel.dayIndex(now: number): number
	return now // SECONDS_PER_DAY
end

-- The UTC day number a saved `lastDay` stands for: a day number already (no later than tomorrow), else a time in
-- UTC seconds (no day number is that big).
function StoreModel.dayOf(lastDay: number, now: number): number
	if lastDay <= StoreModel.dayIndex(now) + 1 then
		return lastDay
	end
	return StoreModel.dayIndex(lastDay)
end

-- Whether today's reward can be claimed and when the next one comes. Unknown (no streak from the server yet): the
-- button shows and the server decides.
function StoreModel.streakStatus(streak: Streak?, now: number): StreakStatus
	if streak == nil then
		return { known = false, claimable = true, day = 0, nextIn = nil }
	end
	local day = streak.day or streak.count
	local claimable: boolean
	if streak.claimable ~= nil then
		claimable = streak.claimable
	elseif streak.lastDay ~= nil then
		claimable = StoreModel.dayOf(streak.lastDay, now) < StoreModel.dayIndex(now)
	else
		return { known = false, claimable = true, day = day, nextIn = nil }
	end
	local nextIn: number? = nil
	if not claimable then
		local nextAt = streak.nextAt or (StoreModel.dayIndex(now) + 1) * SECONDS_PER_DAY
		nextIn = math.max(nextAt - now, 0)
	end
	return { known = true, claimable = claimable, day = day, nextIn = nextIn }
end

-- The streak after a ClaimStreak reply: the server's own when it sent one; else, when the claim worked, today
-- marked claimed; else what we had.
function StoreModel.streakAfterClaim(old: Streak?, reply: any, now: number): Streak?
	if type(reply) ~= "table" then
		return old
	end
	local sent = StoreModel.normalizeStreak(reply.streak)
	if sent ~= nil then
		return sent
	elseif reply.ok == true then
		local count = if old ~= nil then old.count + 1 else 1
		return { count = count, day = nil, lastDay = StoreModel.dayIndex(now), claimable = false, nextAt = nil }
	end
	return old
end

-- Limited drops ----------------------------------------------------------------------------------------------------

-- Whether the banner offers a Buy button for this drop at `now`: it's on now and the server says it's open (the
-- server checks everything again: the window, the supply, the player's cash and garage).
function StoreModel.canBuyDrop(event: Event, now: number): boolean
	return event.drop and event.open == true and now >= event.startsAt and now < event.endsAt
end

-- The Season Pass ----------------------------------------------------------------------------------------------------

-- A season reward in plain words: "$5,000", "2 Design Credits", "Season One Gold look" ("An exclusive wrap" for a
-- look the shop doesn't know).
function StoreModel.rewardText(reward: Season.Reward): string
	local amount = positiveWhole(reward.amount) or 0
	if reward.kind == "cash" then
		return Economy.formatCash(amount)
	elseif reward.kind == "credits" then
		return if amount == 1
			then copy.grantOneCredit
			else string.format(copy.grantCredits, StoreModel.groupDigits(amount))
	elseif reward.kind == "plate" then
		return copy.grantPlateFrame
	end
	-- A look the shop knows is named ("Season One Gold look").
	local wrap = if reward.ref ~= nil and Customization.isExclusive(reward.ref)
		then Customization.getWrap(reward.ref)
		else nil
	if wrap ~= nil then
		return string.format(copy.rewardLook, wrap.displayName)
	end
	return copy.grantWrap
end

-- The claimed rewards in the SeasonClaimed attribute ("free:1,premium:1,...").
local function claimedSet(raw: any): { [string]: boolean }
	local set: { [string]: boolean } = {}
	if type(raw) == "string" then
		for key in string.gmatch(raw, "[^,]+") do
			set[key] = true
		end
	end
	return set
end

-- The Season Pass card for `season` (Config/Season) and the player's attributes at `now` (server UTC seconds): the
-- tier reached (worked out from the XP, Services/SeasonService.tierFor's rule), the countdown, and on each track the
-- lowest reached tier whose reward isn't claimed yet. The server checks every claim again.
function StoreModel.seasonView(season: Season.Season, input: SeasonInput, now: number): SeasonView
	local raw = finite(input.xp)
	local xp = if raw ~= nil and raw > 0 then math.floor(raw) else 0
	local tier = 0
	local nextXp: number? = nil
	for index, entry in season.tiers do
		if xp >= entry.xp then
			tier = index
		elseif nextXp == nil then
			nextXp = entry.xp
		end
	end
	local premium = input.premium == true
	local claimed = claimedSet(input.claimed)
	local exists = season.id ~= ""
	local lastClaim = season.endsAtUtc + season.claimGraceSeconds
	local claimable = exists and now >= season.startsAtUtc and now < lastClaim
	local running = exists and now >= season.startsAtUtc and now < season.endsAtUtc
	local function firstUnclaimed(track: SeasonTrack): SeasonClaim?
		if not claimable then
			return nil
		end
		for index = 1, tier do
			local entry = season.tiers[index]
			local reward = if track == "premium" then entry.premium else entry.free
			if reward ~= nil and not claimed[`{track}:{index}`] then
				return { tier = index, track = track, text = StoreModel.rewardText(reward) }
			end
		end
		return nil
	end
	local premiumNext = firstUnclaimed("premium")
	return {
		show = exists and now < lastClaim,
		name = season.name,
		startsIn = if exists and now < season.startsAtUtc then season.startsAtUtc - now else nil,
		endsIn = if running then season.endsAtUtc - now else nil,
		claimable = claimable,
		tier = tier,
		tiers = #season.tiers,
		xp = xp,
		nextXp = nextXp,
		premium = premium,
		free = firstUnclaimed("free"),
		premiumClaim = if premium then premiumNext else nil,
		premiumLocked = if premium then nil else premiumNext,
	}
end

-- The Store icon's dot on the phone's home screen: an offer waiting, or a daily reward the server says is ready.
function StoreModel.badge(offerDue: boolean, streak: Streak?, now: number): boolean
	if offerDue then
		return true
	end
	local status = StoreModel.streakStatus(streak, now)
	return status.known and status.claimable
end

return StoreModel
