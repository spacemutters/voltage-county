--!strict
-- Words and sizes for the store (docs/phase-12-contracts.md "Store UI"; PLAN.md Phase 12 and §11): the phone's
-- Store app (UI/Phone/StoreApp), its cards (UI/Store/StoreCards), the Starter Pack offer sheet (UI/Store/OfferSheet)
-- and Controllers/StoreController's notices.
--
-- No Robux price is ever written here or anywhere else in the client: every price the player reads is a number the
-- server's GetStore sent (MarketplaceService, cached), dropped into `copy.robux`. Grants (credits per pack, cash per
-- pack) come from the server too; what a credit buys comes from Config/Designer. Plain words: players read these.
-- Colors, fonts, text sizes, corner radii and draw order come from UI/Theme; sizes are pixels at UI scale 1, and
-- every tappable thing is at least Theme.size.touchTarget (tests/StoreUi.spec checks them).

local Theme = require(script.Parent.Parent.Theme)

local spacing = Theme.spacing

local StoreStyle = {
	-- Cards in the Store app (Kit.Card padding and gaps).
	card = {
		padding = 14,
		gap = spacing.sm,
		lineGap = 2, -- between a card's title and its detail lines
		buttonHeight = Theme.size.buttonHeight, -- the buy buttons, full card width
		pillHeight = 28, -- "Coming soon" / "Owned" in place of a buy button
		pillPadding = 12,
	},

	-- The event banner at the top of the Store app.
	banner = {
		padding = 14,
		gap = spacing.xs,
		stripeWidth = 4, -- the accent bar down its left edge
	},

	-- The Starter Pack offer sheet (drawn by UI/Shop/ShopSheet).
	offer = {
		lineHeight = 26, -- one "what you get" line
		bulletWidth = 20,
		-- An offer due while something else is on screen (a designer sheet, a shop sheet, the phone, a drive, a
		-- cutscene) waits; it looks again on the next profile, drive, designer or cutscene change, and on this slow
		-- timer, and gives up after maxWaitSeconds (the Store app still shows the pack).
		retrySeconds = 4,
		maxWaitSeconds = 600,
	},

	-- What the store asks the server for. A GetStore answer older than this is fetched again when the Store app
	-- opens (StoreUpdate always fetches at once). Never on a timer.
	refreshAfterSeconds = 60,
	-- A GetStore call Net turned away (too many in a row, Net.luau's limit) is tried once more after this.
	storeRetrySeconds = 2.5,

	-- Gamepad B closes the offer sheet; bound above the phone's own Back (Config/Controls actionPriority + this).
	priorityAbovePhone = 2,
	closeKeys = { Enum.KeyCode.ButtonB },
	closeAction = "VoltageStoreOfferClose",

	-- Countdowns redraw a moment after the shown value changes, so "59m 59s" never shows a second late.
	countdownSlackSeconds = 0.05,

	-- The pages of the Store app, in order.
	pages = {
		{ id = "credits", label = "Credits" },
		{ id = "passes", label = "Passes" },
		{ id = "more", label = "More" },
	} :: { { id: string, label: string } },

	copy = {
		-- Prices. %s is the Robux amount GetStore sent, with thousands separators. U+E002 is the Robux icon in
		-- Roblox's fonts.
		robux = "\u{E002} %s",
		buy = "Buy", -- a product that's on sale whose price didn't load (Roblox's prompt still shows it)
		opening = "Opening...",
		comingSoon = "Coming soon",
		owned = "Owned",
		unavailable = "You can't buy this right now.", -- a blocked item without the server's own note
		storeClosed = "The store is closed for a moment. Try again soon.",

		loading = "Loading the store...",
		failed = "The store didn't load.",
		retry = "Try again",
		tryLater = "Too many taps. Wait a moment and try again.",
		failedAction = "That didn't work. Please try again.",

		-- Credits page.
		balance = "Your Design Credits",
		oneCredit = "1 credit",
		credits = "%s credits",
		freeCar = "Your first new car is free.",
		usesTitle = "What credits buy",
		useMod = "%s: an AI mod on a car you own", -- "1 credit"
		useCar = "%s: a brand-new car the AI designs for you", -- "2 credits"
		-- "Redesign", never "re-roll". A redesign only ever comes free with a design; none is sold on its own
		-- (docs/COMPLIANCE.md section 2).
		rerollOne = "%s, with a free redesign",
		rerollMany = "%s, with %d free redesigns",
		packsTitle = "Credit packs",
		bonus = "+%s bonus",
		packNote = "Credits change how your cars look. They never make a car faster than its class.",

		-- One-time offers (the Starter Pack card and sheet).
		offerEyebrow = "One-time offer",
		offerBody = "Everything below for one price. You can only buy it once.",
		offerStatus = "It won't show again after you buy it.",
		priceLabel = "Price",
		notNow = "Not now",

		-- What a product gives, from its grants.
		grantCredits = "%s Design Credits",
		grantOneCredit = "1 Design Credit",
		grantCash = "%s in cash",
		grantCustomSlot = "1 more custom-car space",
		grantCustomSlots = "%d more custom-car spaces",
		grantGarageSlot = "1 more garage space",
		grantGarageSlots = "%d more garage spaces",
		grantWrap = "An exclusive wrap",
		grantPlateFrame = "An exclusive plate frame",
		grantLook = "An exclusive look for your cars",
		grantLooks = "%d exclusive looks for your cars",
		bullet = "•",

		-- Passes page.
		passesTitle = "Passes",
		passesBody = "Buy a pass once and keep it.",
		clubTitle = "Voltage Club", -- when the server doesn't name it
		clubBody = "A monthly membership. Cancel any time in your Roblox settings.",
		clubCredits = "%s every month", -- "10 credits", when the server lists no perks
		clubMember = "You're a member. Thanks for being in the club!",
		clubJoin = "%s a month", -- the price text
		clubJoinNoPrice = "Join",

		-- More page.
		streakTitle = "Daily reward",
		streakBody = "Come back every day for cash, and now and then a Design Credit.",
		streakDay = "Day %d of your streak",
		streakClaim = "Claim today's reward",
		streakClaiming = "Claiming...",
		streakNext = "Next reward in %s",
		inviteTitle = "Invite your crew",
		inviteBody = "Send your friends an invite to drive with you.",
		invite = "Invite friends",
		privateTitle = "Private servers",
		privateBody = "Play with just your crew, or host a car meet of your own. Get one in the Servers tab on the "
			.. "game's page.",
		plusPrompt = "Plus members get free private servers.",
		plusButton = "Get Roblox Plus",
		plusMember = "You have Roblox Plus, so your private servers here are free.",
		cashTitle = "Cash packs",
		cashBody = "In-game cash for cars, upgrades and paint.",
		slotTitle = "More space",
		cosmeticsTitle = "Limited looks",
		cosmeticsBody = "Numbered wraps and plate frames, sold for a short time only. What you see is what you get.",

		-- Events.
		eventFallback = "Event",
		eventLive = "On now",
		eventSoon = "Coming up",
		endsIn = "Ends in %s",
		startsIn = "Starts in %s",
		eventEarnings = "%sx cash from driving and jobs",
		eventBonusCredits = "+%s%% credits on every credit pack", -- the extra share as a percentage
		eventFeatured = "Featured at the dealership: %s",
		eventStarted = "%s is on now!",
		dropLive = "Limited drop",
		dropSoon = "Limited drop coming",
		dropSupply = "Only %s made, each with its own serial number",
		dropLeft = "%s left",
		dropPrice = "%s in game cash", -- in-game cash
		dropBuy = "Buy one for %s", -- in-game cash
		dropBuying = "Buying...",

		-- The free daily credit for a rewarded ad (Services/AdsService): shown only while the server says it's on
		-- offer and Roblox says an ad can play.
		adTitle = "A free credit",
		adBody = "Watch a short ad for 1 Design Credit, once a day.",
		adButton = "Watch an ad",
		adWatching = "Playing the ad...",

		-- The Season Pass (Config/Season; Services/SeasonService). Tiers count from 1.
		seasonTier = "Tier %d of %d",
		seasonXp = "%s XP. The next tier is at %s XP.",
		seasonTop = "%s XP. Every tier reached!",
		seasonClaim = "Claim tier %d: %s", -- the tier, the reward
		seasonPremiumClaim = "Premium tier %d: %s", -- the tier, the reward
		seasonClaiming = "Claiming...",
		seasonNothing = "Nothing to claim right now. Keep driving and doing jobs!",
		seasonOver = "This season is over. Claim what you reached before it closes.",
		seasonLocked = "The Season Pass unlocks the premium track: tier %d gives %s.", -- the tier, the reward
		seasonBody = "Earn season XP by driving and doing jobs. Every tier has a reward.",

		-- Countdowns (whole units, largest first).
		days = "%dd %dh",
		hours = "%dh %dm",
		minutes = "%dm %02ds",
		seconds = "%ds",
		now = "now",
	},
}

return StoreStyle
