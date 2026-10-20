--!strict
-- The used lot: the free starter car, the daily stock of classics and its supply-capped, rising prices (PLAN.md
-- Phase 4; docs/phase-4-contracts.md "Commerce"). Read by Services/UsedLotService, the shop UI and
-- Dev/ShopTests.
--
-- The day's stock is a pure function of the UTC date (`stockFor`), so every server (and every client) works out
-- the same cars for the same day with no network call: the date string is hashed into a seed, and a small
-- deterministic generator (Park-Miller, exact in double arithmetic, the same on every machine) shuffles the pool
-- of every `usedLot` trim in Config/Vehicles into the numbered spaces. Each space sells at most `supplyPerDay`
-- copies across all servers (UsedLotService counts them in a DataStore), and its price rises as they sell
-- (`price`).
--
-- Pure data plus pure helpers: no Roblox services.

local MapLayout = require(script.Parent.MapLayout)
local Vehicles = require(script.Parent.Vehicles)

-- One trim the used lot can stock.
export type PoolEntry = { vehicleId: string, trim: string, basePrice: number }

-- One numbered space's car for a day.
export type StockEntry = {
	slot: number, -- 1..UsedLot.slots; the numbered space (Config/MapLayout usedLot.pads[slot])
	vehicleId: string,
	trim: string,
	basePrice: number, -- the trim's Config/Vehicles price; the price before any copy has sold
	supply: number, -- copies for sale today, across every server
}

local SECONDS_PER_DAY = 86400
local MODULUS = 2147483647 -- 2^31 - 1, the Park-Miller prime
local MULTIPLIER = 48271 -- Park-Miller multiplier: state * MULTIPLIER stays far below 2^53, so it's exact
local HASH_BASE = 33 -- djb2-style string hash, reduced mod MODULUS at every step (also exact)

-- Every used-lot trim with a price, in a fixed order (vehicle id, then the trim's place in its vehicle).
local function buildPool(): { PoolEntry }
	local ids: { string } = {}
	for id in Vehicles do
		table.insert(ids, id)
	end
	table.sort(ids)
	local pool: { PoolEntry } = {}
	for _, id in ids do
		local vehicle = Vehicles[id]
		if not vehicle.playerDrivable then
			continue
		end
		for _, trim in vehicle.trims do
			if trim.acquisition == "usedLot" and trim.price ~= nil and trim.price > 0 then
				table.insert(pool, { vehicleId = id, trim = trim.id, basePrice = trim.price })
			end
		end
	end
	return pool
end

local UsedLot = {
	-- Numbered spaces, one car each per day: one per used-lot pad in Config/MapLayout.
	slots = #MapLayout.usedLot.pads,
	-- The daily pool: every `acquisition = "usedLot"` trim in Config/Vehicles (built once at load).
	pool = buildPool(),
	-- Copies of each space's car for sale per UTC day, across every server.
	supplyPerDay = 5,
	-- Price = base x (1 + rise x sold / supply), never more than base x maxMultiplier, in whole dollars.
	priceCurve = {
		rise = 0.5,
		maxMultiplier = 1.4,
	},

	-- The free starter: once per player (PlayerData.starterClaimed), paid = 0.
	starter = {
		vehicleId = "ohm_spark",
		trim = "used",
	},

	-- Global supply counters: DataStore `storeName` (live) or `studioStoreName` (Studio), key "<date>:<slot>",
	-- value = copies sold. UpdateAsync only ever adds one while sold < supply. In Studio, when DataStores can't be
	-- used (no API access), the counts live in the server's memory instead. On a live server a store error refuses
	-- the sale (messages.busy): it never hands out a copy the global count didn't approve.
	storeName = "UsedLotSupply",
	studioStoreName = "UsedLotSupply_Studio",
	-- How long a server trusts a count it read before reading it again (GetUsedLot), in seconds.
	soldCacheSeconds = 20,

	-- EconomyService reasons (Roblox economy analytics item SKUs).
	reasons = {
		buy = "usedLot",
		refund = "refund",
	},

	-- What the player is told. Plain words.
	messages = {
		notLoaded = "Your garage is still loading. Try again in a moment.",
		unknownSlot = "That space is empty today.",
		soldOut = "Sold out for today. New cars arrive tomorrow.",
		noRoom = "Your garage is full. Sell a car to make room.",
		noCash = "You need %s more for that.", -- the amount short
		busy = "The lot is busy. Try again in a moment.",
		-- The confirm the player saw is out of date: the price rose past it, or the lot restocked at midnight.
		priceChanged = "The price changed to %s. Have another look.", -- the new price
		lotChanged = "Today's cars have changed. Have another look.",
		buyFailed = "Something went wrong, so you weren't charged. Try again in a moment.",
		bought = "You bought the %s for %s! It's waiting at the spawn pad.", -- vehicle name, price paid
		boughtInGarage = "You bought the %s for %s! Bring it out from the Garage app.",
		starterAlready = "You've already claimed your free car. Bring it out from the Garage app.",
		starterNoRoom = "Your garage is full. Sell a car to make room for your free one.",
		starterFailed = "Couldn't hand over your free car. Try again in a moment.",
		starterClaimed = "Your free %s is ready. Enjoy the drive!", -- vehicle name
		starterInGarage = "Your free %s is in your garage. Bring it out from the Garage app.",
	},
}

-- The UTC date of `time` (os.time() seconds; now when nil) as "YYYY-MM-DD": the used lot's day. (Roblox's
-- os.date only takes "*t" formats, so the string is built from the table.)
function UsedLot.dateKey(time: number?): string
	local parts = os.date("!*t", time or os.time()) :: any
	return string.format("%04d-%02d-%02d", parts.year, parts.month, parts.day)
end

-- Seconds from `time` until the next UTC midnight (when the stock changes); between 1 and a day.
function UsedLot.secondsUntilNextDay(time: number): number
	local into = time % SECONDS_PER_DAY
	return SECONDS_PER_DAY - into
end

-- The DataStore key of a space's counter on a day.
function UsedLot.supplyKey(dateKey: string, slot: number): string
	return `{dateKey}:{slot}`
end

-- A whole-number hash of a string in 1..MODULUS-1, the same everywhere.
function UsedLot.hash(text: string): number
	local h = 5381
	for i = 1, #text do
		h = (h * HASH_BASE + string.byte(text, i)) % MODULUS
	end
	if h == 0 then
		h = 1
	end
	return h
end

-- A deterministic generator: next(n) returns a whole number in 1..n.
local function generator(seed: number): (n: number) -> number
	local state = seed % MODULUS
	if state == 0 then
		state = 1
	end
	return function(n: number): number
		state = (state * MULTIPLIER) % MODULUS
		return state % n + 1
	end
end

-- The day's stock: one entry per numbered space, from the pool shuffled by the date. Pure and deterministic:
-- the same dateKey always gives the same stock. `pool` and `slots` default to the catalog's pool and the pad
-- count (specs pass fixtures). Spaces repeat the pool when there are more spaces than trims; an empty pool
-- gives no stock.
function UsedLot.stockFor(dateKey: string, pool: { PoolEntry }?, slots: number?): { StockEntry }
	local entries = pool or UsedLot.pool
	local count = slots or UsedLot.slots
	local stock: { StockEntry } = {}
	if #entries == 0 then
		return stock
	end
	-- Fisher-Yates shuffle of a copy.
	local nextInt = generator(UsedLot.hash(dateKey))
	local order = table.clone(entries)
	for i = #order, 2, -1 do
		local j = nextInt(i)
		order[i], order[j] = order[j], order[i]
	end
	for slot = 1, count do
		local entry = order[(slot - 1) % #order + 1]
		table.insert(stock, {
			slot = slot,
			vehicleId = entry.vehicleId,
			trim = entry.trim,
			basePrice = entry.basePrice,
			supply = UsedLot.supplyPerDay,
		})
	end
	return stock
end

-- The price of the next copy after `sold` of `supply` have gone: base x (1 + rise x sold / supply), capped at
-- base x maxMultiplier, rounded down to whole dollars. Never falls as more sell; 0 for a damaged base price.
function UsedLot.price(base: number, sold: number, supply: number): number
	if type(base) ~= "number" or base ~= base or base == math.huge or base <= 0 then
		return 0
	end
	local curve = UsedLot.priceCurve
	local fraction = if supply > 0 then math.max(sold, 0) / supply else 1
	if fraction ~= fraction then
		fraction = 1 -- a damaged count prices like a sold-out space
	end
	local multiplier = math.min(1 + curve.rise * fraction, curve.maxMultiplier)
	return math.floor(base * multiplier)
end

return UsedLot
