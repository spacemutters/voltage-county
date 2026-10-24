--!strict
-- Game passes, developer products and the Voltage Club subscription (PLAN.md Phase 12 and §11;
-- docs/phase-12-contracts.md "Monetization core"). Read by Services/MonetizationService (receipts, prompts, pass
-- checks, the club, the store payload), the services that apply pass perks (JobService VIP pay, FleetService,
-- GarageService slots, CustomizationService plates, LightShowService Pro routines) and the store UI.
--
-- Davis creates the passes, products and the subscription in the Creator Dashboard and pastes their ids here. An id
-- of 0 (or "" for the subscription) means "not created yet": nothing is prompted, nothing is granted, and the store
-- shows the item as coming soon.
--
-- Fair monetization (CLAUDE.md hard rule 6): what each item GRANTS is config; what it COSTS never is. Prices come
-- from MarketplaceService (cached), so Managed Pricing and price tests can change them; tests/NoRobuxPrices.spec
-- fails on any price written into the source. Nothing sold here is random, and credits only ever buy looks.

local Audio = require(script.Parent.Audio)
local Customization = require(script.Parent.Customization)
local Economy = require(script.Parent.Economy)
local Fleet = require(script.Parent.Fleet)
local LightShows = require(script.Parent.LightShows)
local Season = require(script.Parent.Season)

export type ProductKind = "credits" | "cash" | "slot" | "starter" | "cosmetic"

-- What one developer product gives each time it is bought (every field optional; missing means none).
export type Grant = {
	credits: number?, -- Design Credits
	bonus: number?, -- extra Design Credits on the bigger packs (shown separately in the store)
	cash: number?, -- in-game $
	customSlots: number?, -- extra custom-car slots, kept for good
	cosmetics: { string }?, -- exclusive looks this unlocks (ids the Wrap & Tint shop knows)
}

export type ProductInfo = { name: string, kind: ProductKind }

export type PassInfo = { name: string, perks: { string } }

-- Slots a pass or the club adds on top of the saved counts while it is owned (never written into the save).
export type SlotBonus = { garageSlots: number, customSlots: number }

export type Club = {
	key: string, -- the subscriptions key
	name: string,
	perks: { string },
	monthlyCredits: number, -- Design Credits once per billing month while subscribed
	slots: SlotBonus, -- while subscribed
	cosmetics: { string }, -- exclusive looks members can use while subscribed
	-- A member is checked again when their paid billing cycle ends (one timer per member, no polling), but never
	-- sooner than this many seconds after the last check.
	minRecheckSeconds: number,
}

-- A tag in front of a player's name on their chat messages (Controllers/ChatTagController): its words and its colour
-- as a six-digit hex RGB string ("F5C542").
export type ChatTag = { text: string, colorHex: string }

export type Attributes = {
	passPrefix: string, -- player attribute "<prefix><pass key>" = true while the pass is owned
	club: string, -- true while the player is a Voltage Club member
	garageBonus: string, -- garage slots the player's passes add right now
	customBonus: string, -- custom-car slots the player's passes and club add right now
}

export type Monetization = {
	passes: { [string]: number },
	products: { [string]: number },
	subscriptions: { [string]: string },
	grants: { [string]: Grant },
	productInfo: { [string]: ProductInfo },
	productOrder: { string },
	passInfo: { [string]: PassInfo },
	passOrder: { string },
	passSlots: { [string]: SlotBonus },
	vipPass: string,
	club: Club,
	maxCustomSlots: number,
	receiptWaitSeconds: number,
	receiptSaveSeconds: number,
	passRetrySeconds: number,
	passRetries: number,
	priceCacheSeconds: number,
	priceRetrySeconds: number,
	cashReason: string,
	creditsReasonPrefix: string,
	notifyKind: string,
	featureFlag: string,
	attributes: Attributes,
	chatTags: { vip: ChatTag },
	messages: { [string]: string },
}

-- Numbers the perk text below repeats, so the words and the rules can't drift apart.
local GARAGE_PLUS: SlotBonus = { garageSlots = 10, customSlots = 2 }
local CLUB_MONTHLY_CREDITS = 10
local CLUB_SLOTS: SlotBonus = { garageSlots = 0, customSlots = 2 }
local CLUB_LOOK = "club_wrap" -- Config/Customization.exclusiveWraps

-- "A", "A and B", "A, B and C".
local function joinNames(names: { string }): string
	if #names <= 1 then
		return names[1] or ""
	end
	return table.concat(names, ", ", 1, #names - 1) .. " and " .. names[#names]
end

-- Light Show Pro's perk lines, from Config/LightShows and Config/Audio: the Pro routines by name, and, while any of
-- them has no music (a track's assetId is 0), plainly that they are lights and doors only.
local function lightShowPerks(): { string }
	local names: { string } = {}
	local silent = false
	for _, id in LightShows.routineOrder do
		local routine = LightShows.routines[id]
		if routine ~= nil and routine.pro then
			table.insert(names, routine.displayName)
			local track = Audio.tracks[routine.trackId]
			silent = silent or track == nil or track.assetId == 0
		end
	end
	local perks = {
		string.format("The %s light show%s at car meets", joinNames(names), if #names == 1 then "" else "s"),
	}
	if silent then
		table.insert(perks, "Lights and doors only, no music")
	end
	return perks
end

-- The Season Pass's look line: how many exclusive car looks its premium track gives (Config/Season).
local function seasonLooksPerk(): string?
	local looks = 0
	for _, tier in Season.tiers do
		local reward = tier.premium
		if reward ~= nil and reward.kind ~= "cash" and reward.kind ~= "credits" then
			looks += 1
		end
	end
	if looks == 0 then
		return nil
	end
	return if looks == 1 then "An exclusive car look" else string.format("%d exclusive car looks", looks)
end

local seasonPerks = { "The premium reward track this season" }
local seasonLooks = seasonLooksPerk()
if seasonLooks ~= nil then
	table.insert(seasonPerks, seasonLooks)
end

local Monetization: Monetization = {
	-- Game pass ids (Creator Dashboard > Monetization > Passes). 0 = not created yet.
	passes = {
		vip = 0,
		fleetManager = 0,
		garagePlus = 0,
		lightShowPro = 0,
		customPlates = 0,
		seasonPass = 0, -- premium rewards are claimed on the Store app's More page (Season Pass card)
	},

	-- Developer product ids (Creator Dashboard > Monetization > Developer Products). 0 = not created yet.
	products = {
		credits5 = 0,
		credits15 = 0,
		credits40 = 0,
		starterPack = 0,
		customSlot = 0,
		cash1 = 0,
		cash2 = 0,
		cash3 = 0,
		cash4 = 0,
	},

	-- Subscription ids ("EXP-..." from the Creator Dashboard). "" = not created yet.
	subscriptions = {
		club = "",
	},

	-- What each product gives, by product key. The Starter Pack is a one-time offer (Config/Offers). `cosmetics` are
	-- exclusive look ids from Config/Customization.exclusiveWraps. A product that grants a look the Wrap & Tint shop
	-- doesn't have isn't sold, whatever its id: the store shows it as coming soon (MonetizationService.productReady),
	-- and tests/Monetization.spec fails on it.
	grants = {
		credits5 = { credits = 5, bonus = 0 },
		credits15 = { credits = 15, bonus = 3 },
		credits40 = { credits = 40, bonus = 12 },
		starterPack = { credits = 5, cash = 25000, customSlots = 1, cosmetics = { "starter_wrap" } },
		customSlot = { customSlots = 1 },
		cash1 = { cash = 10000 },
		cash2 = { cash = 35000 },
		cash3 = { cash = 100000 },
		cash4 = { cash = 300000 },
	},

	-- How the store names and groups each product (plain words; the player reads these).
	productInfo = {
		credits5 = { name = "5 Design Credits", kind = "credits" },
		credits15 = { name = "15 Design Credits", kind = "credits" },
		credits40 = { name = "40 Design Credits", kind = "credits" },
		starterPack = { name = "Starter Pack", kind = "starter" },
		customSlot = { name = "Extra Custom Car Slot", kind = "slot" },
		cash1 = { name = "Cash Stack", kind = "cash" },
		cash2 = { name = "Cash Bag", kind = "cash" },
		cash3 = { name = "Cash Case", kind = "cash" },
		cash4 = { name = "Cash Vault", kind = "cash" },
	},
	productOrder = {
		"credits5",
		"credits15",
		"credits40",
		"starterPack",
		"customSlot",
		"cash1",
		"cash2",
		"cash3",
		"cash4",
	},

	-- The perks the store lists are only ones the game delivers today: a perk line goes in when its feature ships,
	-- never before (the player pays for what the card says).
	passInfo = {
		vip = {
			name = "VIP",
			perks = {
				string.format("+%d%% pay from every job", math.floor(Economy.vipJobPayBonus * 100 + 0.5)),
				"A VIP tag on your chat messages", -- Controllers/ChatTagController (chatTags.vip)
				-- Planned (PLAN.md Phase 12), listed here once built: the VIP lounge at the charging plaza (reads the
				-- player attribute attributes.passPrefix .. "vip").
			},
		},
		fleetManager = {
			name = "Fleet Manager",
			perks = {
				string.format("+%d robotaxi pod slots", Fleet.pass.bonusSlots),
				"Fleet earnings collect themselves",
			},
		},
		garagePlus = {
			name = "Garage+",
			perks = {
				string.format("+%d garage spaces", GARAGE_PLUS.garageSlots),
				string.format("+%d custom car slots", GARAGE_PLUS.customSlots),
			},
		},
		lightShowPro = {
			-- PLAN.md's "Boombox & Light Show Pro": the name gets "Boombox &" back when the boombox ships. Its
			-- routines have no music until Config/Audio has their tracks, and the card says so (lightShowPerks).
			name = "Light Show Pro",
			perks = lightShowPerks(),
		},
		customPlates = {
			name = "Custom Plates",
			perks = { "Write your own plate text" },
		},
		seasonPass = {
			name = "Season Pass",
			perks = seasonPerks,
		},
	},
	passOrder = { "vip", "fleetManager", "garagePlus", "lightShowPro", "customPlates", "seasonPass" },

	-- Slots passes add while owned (the Voltage Club's are in club.slots).
	passSlots = {
		garagePlus = GARAGE_PLUS,
	},

	-- The pass whose owners get Config/Economy.vipJobPayBonus on job pay (Services/JobService).
	vipPass = "vip",

	-- The Voltage Club (§11): a monthly subscription priced in local currency.
	club = {
		key = "club",
		name = "Voltage Club",
		perks = {
			string.format("%d Design Credits every month", CLUB_MONTHLY_CREDITS),
			string.format("+%d custom car slots while you're a member", CLUB_SLOTS.customSlots),
			-- The look's own words (Config/Customization blurb), so the card says what it is.
			string.format("Members-only look: %s", Customization.lookBlurb(CLUB_LOOK) or "the Voltage Club wrap"),
			-- Planned (§11), listed here once built: a members-only plate frame (plate frames aren't a look yet; add
			-- its id to `cosmetics` then) and the club lounge (reads the player attribute attributes.club).
		},
		monthlyCredits = CLUB_MONTHLY_CREDITS,
		slots = CLUB_SLOTS,
		-- Exclusive looks members may use while subscribed (MonetizationService.ownsCosmetic; ids from
		-- Config/Customization.exclusiveWraps).
		cosmetics = { CLUB_LOOK },
		minRecheckSeconds = 300,
	},

	-- The custom-car slot product stops being offered at this many slots (saved slots, without pass bonuses).
	maxCustomSlots = 20,

	-- ProcessReceipt waits this long for a joining player's save before answering NotProcessedYet (Roblox retries).
	-- GetStore waits as long for a save that is still loading, so the first store a player sees can be bought from.
	receiptWaitSeconds = 20,

	-- After granting, ProcessReceipt asks for a save and answers PurchaseGranted only once the DataStore holds the
	-- receipt (Roblox never delivers an acknowledged receipt again). Not saved within this many seconds: it answers
	-- NotProcessedYet, and the retry finds the receipt already granted and waits for the save again.
	receiptSaveSeconds = 30,

	-- A pass check that fails on join (UserOwnsGamePassAsync errored) is tried again this often, this many times,
	-- so one Roblox hiccup doesn't cost an owner their perks for the session.
	passRetrySeconds = 20,
	passRetries = 5,

	-- Prices read from MarketplaceService are kept this long; a failed lookup is retried after priceRetrySeconds.
	priceCacheSeconds = 600,
	priceRetrySeconds = 60,

	-- EconomyService reason for cash from a cash pack or the Starter Pack, and the credits log prefix.
	cashReason = "purchase",
	creditsReasonPrefix = "purchase:",

	notifyKind = "success", -- Notify toast kind for purchases and the club's monthly credits

	-- Config/FeatureFlags name: switched off, nothing is prompted and the store shows closed. Receipts still grant
	-- (a receipt means the player already paid).
	featureFlag = "store",

	attributes = {
		passPrefix = "Pass_",
		club = "VoltageClub",
		garageBonus = "GarageBonusSlots",
		customBonus = "CustomBonusSlots",
	},

	-- Chat tags: VIP pass owners' chat messages start with this (the pass's attribute, so it shows at once).
	chatTags = {
		vip = { text = "[VIP]", colorHex = "F5C542" },
	},

	-- What the player reads. Plain words.
	messages = {
		comingSoon = "Coming soon!",
		unknown = "That isn't in the store.",
		notLoaded = "Your save is still loading. Try again in a moment.",
		prompted = "Check the purchase window.",
		promptFailed = "The store couldn't open right now. Try again in a moment.",
		storeClosed = "The store is closed for a moment. Try again soon.",
		alreadyOwned = "You already have that.",
		alreadyMember = "You're already in the Voltage Club.",
		starterBought = "You already have the Starter Pack.",
		slotsFull = "You have as many custom car slots as you can get.",
		devOnly = "That only works in Studio.",
		devGranted = "Test purchase done: %s.", -- the item's name
		devFailed = "Test purchase didn't go through: %s.", -- the item's name
		granted = "Thanks! %s is yours.", -- the item's name
		clubCredits = "Voltage Club: +%d Design Credits this month.", -- the credits
	},
}

return Monetization
