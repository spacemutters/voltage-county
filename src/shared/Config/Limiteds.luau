--!strict
-- Limited drops and limited cosmetics (PLAN.md Phase 12; docs/phase-12-contracts.md "Live-ops").
--
-- Drops: a vehicle and trim sold for in-game cash in a UTC window, with a fixed supply. Each buyer gets the next
-- serial number (1, 2, 3 ... supply), assigned atomically with DataStore UpdateAsync on one key per drop, so two
-- servers can never hand out the same serial or sell past the supply. One per player per drop. Arc Flight ships
-- only this way. Nothing is random.
--
-- Limited cosmetics: serial-numbered wraps and plate frames sold for Robux as developer products in a fixed window
-- (never random, no supply cap: every buyer in the window gets the next serial). Their product ids live here, start
-- at 0 ("not created yet": not for sale, the store shows "Coming soon") and Davis pastes them in once he creates
-- the products. No Robux price is ever written here: the store reads it from MarketplaceService.
--
-- Times are Unix seconds in UTC (os.time()); a window runs from startsAtUtc up to, not including, endsAtUtc.
-- Prices are in-game $ (drops only). Ids use letters, digits and _ only.

export type Drop = {
	id: string,
	name: string, -- what the store and the countdown call it
	vehicleId: string, -- Config/Vehicles id
	trim: string, -- a trim of that vehicle with acquisition "limited"
	startsAtUtc: number,
	endsAtUtc: number,
	supply: number, -- serials 1..supply
	price: number, -- in-game $
}

export type CosmeticKind = "wrap" | "plateFrame"

export type Cosmetic = {
	id: string, -- the sale (its serial counter's key)
	name: string,
	kind: CosmeticKind,
	-- The look it unlocks: an exclusive Wrap & Tint look id (Config/Customization.exclusiveWraps; never sold in the
	-- shop), the key its serial is saved under in PlayerData.cosmetics, like the Starter Pack's and the club's looks
	-- (Config/Monetization).
	ref: string,
	productKey: string, -- the key MonetizationService sells it under (BuyProduct { key }, GetStore)
	productId: number, -- the developer product id; 0 until Davis creates it
	startsAtUtc: number,
	endsAtUtc: number,
}

export type Limiteds = {
	drops: { [string]: Drop },
	cosmetics: { [string]: Cosmetic },
	-- Serial counters. Studio uses its own store AND its own key prefix, so a Studio test never touches a live key.
	store: string,
	studioStore: string,
	keyPrefix: string,
	studioKeyPrefix: string,
	pendingKind: string, -- PlayerData.pendingGrants kind of a drop bought but not yet in the garage
	refreshSeconds: number, -- how often an open drop's remaining supply is re-read for the countdown banner
	reasons: { buy: string, refund: string }, -- EconomyService reasons
	messages: { [string]: string },
	-- The developer product id of every limited cosmetic, by its product key (MonetizationService merges these
	-- into the products it sells; an id of 0 means not created yet).
	productIds: () -> { [string]: number },
}

local Limiteds: Limiteds

local function productIds(): { [string]: number }
	local ids: { [string]: number } = {}
	for _, cosmetic in Limiteds.cosmetics do
		ids[cosmetic.productKey] = cosmetic.productId
	end
	return ids
end

Limiteds = {
	drops = {
		arc_flight_1 = {
			id = "arc_flight_1",
			name = "Arc Flight, first drop",
			vehicleId = "ohm_arc",
			trim = "flight",
			startsAtUtc = 1800036000, -- 2027-01-15 18:00 UTC (Config/Events arc_flight_weekend, Config/Season s1)
			endsAtUtc = 1800640800, -- 2027-01-22 18:00 UTC
			supply = 500,
			price = 7500000, -- above the Arc Boost ($5M), the top of the dealership ladder
		},
	},

	cosmetics = {
		launch_wrap = {
			id = "launch_wrap",
			name = "Launch Week wrap",
			kind = "wrap",
			ref = "launch_week_wrap",
			productKey = "limitedLaunchWrap",
			productId = 0,
			startsAtUtc = 1800036000, -- 2027-01-15 18:00 UTC
			endsAtUtc = 1800640800, -- 2027-01-22 18:00 UTC
		},
		-- Waits for plate frames: its look isn't one the Wrap & Tint shop has yet (Config/Customization.lookExists),
		-- so MonetizationService shows it as coming soon and never prompts it, even with a product id pasted in
		-- (tests/Monetization.spec fails on an id here until the look exists).
		launch_frame = {
			id = "launch_frame",
			name = "Launch Week plate frame",
			kind = "plateFrame",
			ref = "launch_week_plate_frame",
			productKey = "limitedLaunchFrame",
			productId = 0,
			startsAtUtc = 1800036000,
			endsAtUtc = 1800640800,
		},
	},

	store = "LimitedSerials",
	studioStore = "LimitedSerials_Studio",
	keyPrefix = "serials_",
	studioKeyPrefix = "studio_serials_",
	pendingKind = "limitedDrop",
	refreshSeconds = 60,
	reasons = { buy = "limited", refund = "refund" },

	messages = {
		off = "Limited drops are paused right now. Check back soon.",
		unknown = "That drop doesn't exist.",
		notYet = "This drop hasn't started yet.",
		ended = "This drop has ended.",
		loading = "Your progress is still loading. Try again in a moment.",
		busy = "Your last purchase is still going through. Give it a moment.",
		full = "Your garage is full. Sell a car to make room first.",
		cash = "You need %s for this.", -- %s is the price, e.g. "$7,500,000"
		soldOut = "Sold out! Your %s has been refunded.", -- %s is the price
		owned = "You already own serial #%d from this drop. Your %s has been refunded.",
		pending = "Your purchase is saved and will finish the next time you join.",
		bought = "You got %s #%d! It's in your garage.", -- name, serial
		completed = "Your %s #%d arrived in your garage.", -- a purchase finished on join
		refunded = "%s sold out before your purchase went through. Your %s has been refunded.",
		ownedCosmetic = "You already own serial #%d of this.",
	},

	productIds = productIds,
}

return Limiteds
