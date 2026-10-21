--!strict
-- Economy targets and tunables (PLAN.md §4; docs/phase-3-contracts.md "Economy and codes").
--
-- Read by DataService (starting cash and slots), EconomyService (the cap, analytics), CodeService (code entry
-- messages), DriveEarn and Dev/EconSim (activity rates and milestone targets) and the HUD (cash readout and the
-- Codes entry). Pure data plus one formatter: no requires and no Roblox types, so any module can read it.
--
-- Activity rates are target averages in $ per minute for a mid-skill player. The systems that pay them
-- (drive-to-earn now, jobs and the robotaxi fleet in later phases) are tuned to land near these numbers, and
-- Dev/EconSim checks the time-to-milestone targets they add up to.

export type VehicleChoice = { vehicleId: string, trim: string }

-- A time-to-milestone target from PLAN.md §4: owning one of `vehicles` after minHours..maxHours of mid-skill play.
export type Milestone = {
	id: string,
	label: string,
	vehicles: { VehicleChoice }, -- any one of these counts (Config/Vehicles ids and trims)
	minHours: number,
	maxHours: number,
}

local Economy = {
	-- A new player's wallet and garage (PLAN.md §4).
	startingCash = 2500,
	garageSlots = 6,
	customSlots = 3,
	-- Players can never send cash to each other (prevents scams and real-money trading).
	playerTransfers = false,

	-- Target average $ per minute for mid-skill play, by activity (PLAN.md §4 table).
	activities = {
		freeDrive = 300, -- drive-to-earn (Services/DriveEarnService)
		rideshare = 1000, -- sedan
		rideshareXL = 1250, -- crossover / six seats
		delivery = 1000,
		deliveryVehicleBonus = 0.2, -- +20% delivery pay in a vehicle of a `deliveryBonusClasses` class
		towing = 1600, -- with a pickup
		freight = 3000, -- with a semi and the freight license
		robotaxiPerPod = 60, -- each fleet pod while the owner is online
		robotaxiOfflineRate = 0.25, -- share of the online rate a pod earns while the owner is offline
		robotaxiOfflineCapHours = 8, -- offline earnings stop after this many hours
	},
	-- Config/Classes ids whose vehicles get the delivery bonus.
	deliveryBonusClasses = { "van", "suv", "pickup" },

	-- VIP: job pay +20% (sold for Robux in Phase 12).
	vipJobPayBonus = 0.2,
	-- One-off sink: the license freight jobs need (Phase 8).
	freightLicensePrice = 25000,

	-- Sanity cap on any wallet: far above anything the economy pays out, and it still fits the HUD readout.
	-- EconomyService never adds past it.
	maxCash = 999999999,

	-- Time-to-milestone targets (PLAN.md §4) for Dev/EconSim to print its simulated times against, in the order
	-- players buy them. minHours == maxHours means "about" that long (the Spark's ≈ 30 min).
	milestones = {
		{
			id = "spark",
			label = "New Ohm Spark",
			vehicles = { { vehicleId = "ohm_spark", trim = "standard" } },
			minHours = 0.5,
			maxHours = 0.5,
		},
		{
			id = "crossoverOrPickup",
			label = "Crossover or pickup",
			vehicles = {
				{ vehicleId = "ohm_current", trim = "standard" },
				{ vehicleId = "ohm_mesa", trim = "standard" },
			},
			minHours = 1,
			maxHours = 2,
		},
		{
			id = "semi",
			label = "Semi",
			vehicles = { { vehicleId = "ohm_hauler", trim = "standard" } },
			minHours = 4,
			maxHours = 5,
		},
		{
			id = "arc",
			label = "Ohm Arc",
			vehicles = { { vehicleId = "ohm_arc", trim = "performance" } },
			minHours = 15,
			maxHours = 20,
		},
		{
			id = "arcBoost",
			label = "Arc Boost",
			vehicles = { { vehicleId = "ohm_arc", trim = "boost" } },
			minHours = 40,
			maxHours = 50,
		},
	} :: { Milestone },

	-- The player attribute EconomyService keeps equal to the player's cash, for the HUD (server-set).
	cashAttribute = "Cash",

	-- Timed earnings boosts (from codes). Each active boost adds its bonus (a 2x boost adds 1) to a base of 1;
	-- the total never goes above maxMultiplier, however many boosts are running.
	boosts = {
		maxMultiplier = 3,
	},

	-- Roblox economy analytics (AnalyticsService:LogEconomyEvent). Every cash change is logged with the
	-- currency below, the reason as the item SKU, and the reason's transaction type: a name of
	-- Enum.AnalyticsEconomyTransactionType (tests/Economy.spec checks every name here is one).
	analytics = {
		currency = "Cash",
		defaultTransactionType = "Gameplay", -- any reason not listed below
		transactionTypes = {
			drive = "Gameplay", -- drive-to-earn
			code = "TimedReward", -- codes are time-limited rewards
			dev = "Gameplay", -- Studio-only grants (Roblox never records Studio events)
			-- Phase 4 car trade (Config/Dealership, Config/UsedLot and Config/Garage reasons).
			dealership = "Shop", -- buying a new car
			usedLot = "Shop", -- buying a used car
			upgrade = "Shop", -- an upgrade trim
			sell = "Shop", -- selling a car back (a source)
			refund = "Shop", -- a failed purchase's charge given back, so it nets out against the shop sink
			-- Phase 7 Wrap & Tint shop (Config/Customization.shop.economyReason).
			customize = "Shop",
			-- Phase 9 robotaxi fleet (Config/Fleet.reasons; selling a pod reuses "sell", a refund "refund") and
			-- pod rides (Config/Hail.economyReason; a cancelled ride's refund is "refund", so it nets out here).
			pod = "Shop", -- buying a pod
			fleet = "Gameplay", -- fleet earnings collected
			hail = "Shop", -- a pod ride's fare
			-- Phase 12 (Config/Monetization.cashReason, Config/Limiteds.reasons, Config/Season reasons).
			purchase = "IAP", -- cash from a cash pack or the Starter Pack, bought for Robux
			limited = "Shop", -- buying a limited drop (a sold-out drop's refund is "refund")
			streak = "TimedReward", -- the daily login reward
			season = "Gameplay", -- a season tier reward, earned with season XP from driving and jobs
		} :: { [string]: string },
	},

	-- Redeeming codes (Config/Codes, Services/CodeService) and what the player is told.
	codes = {
		maxLength = 32, -- characters; the RedeemCode remote in Net accepts no more
		reason = "code", -- EconomyService reason for cash from a code
		messages = {
			empty = "Type a code first.",
			unknown = "That code doesn't exist. Check the spelling and try again.",
			expired = "Sorry, that code has expired.",
			redeemed = "You've already used that code.",
			loading = "Your progress is still loading. Try again in a moment.",
			failed = "That code couldn't be used right now. Please try again.",
			tryLater = "Too many tries. Wait a few seconds and try again.", -- the server didn't answer
			cash = "Code redeemed! %s added.", -- %s is the amount, e.g. "$5,000"
			multiplier = "Code redeemed! %s earnings for %s.", -- e.g. "2x", "30 minutes"
			minute = "minute",
			minutes = "minutes",
		},
	},

	-- How cash is written: "$12,345".
	display = {
		symbol = "$",
		thousandsSeparator = ",",
	},

	-- The cash readout and the Codes entry in the HUD (UI/Hud), in pixels at UI scale 1 like Config/Controls.
	-- They sit in the top-left corner, lined up with the touch steering zones below them: clear of the GPS
	-- (top right), the notices (top centre) and the touch controls (bottom corners and top right).
	hud = {
		rowHeight = 44, -- the cash readout and the Codes button; also the touch target height
		gap = 10, -- between the readout and the Codes button below it
		cashMinWidth = 96,
		cashMaxWidth = 170, -- wide enough for maxCash
		cashPadding = 14, -- text inset inside the readout
		cashTextSize = 20,
		codesButtonWidth = 72,
		buttonTextSize = 15,
		cornerRadius = 14,
		loadingText = "$...", -- shown until the player's data has loaded
		codesLabel = "Codes",
		-- The code entry sheet, in the middle of the screen while open.
		panel = {
			width = 300,
			padding = 12,
			headerHeight = 52,
			inputHeight = 44,
			buttonHeight = 44,
			closeButtonWidth = 72,
			titleTextSize = 17,
			textSize = 15,
			cornerRadius = 14,
			innerCornerRadius = 10,
			title = "Redeem a code",
			placeholder = "Type a code",
			redeemLabel = "Redeem",
			redeemingLabel = "Checking...",
			closeLabel = "Close",
		},
	},
}

-- The largest whole number formatCash writes exactly (Luau numbers are doubles).
local MAX_EXACT = 2 ^ 53
-- Splits the last three digits off a run of digits, so a separator can go between them.
local GROUP_PATTERN = "^(%d+)(%d%d%d)"

-- "$12,345": rounded down to whole dollars, with a thousands separator. Non-finite amounts read as $0.
function Economy.formatCash(amount: number): string
	local finite = amount == amount and math.abs(amount) ~= math.huge
	local whole = if finite then math.clamp(math.floor(amount), -MAX_EXACT, MAX_EXACT) else 0
	local separated = string.format("%d", math.abs(whole))
	local replacement = "%1" .. Economy.display.thousandsSeparator .. "%2"
	while true do
		local grouped, count = string.gsub(separated, GROUP_PATTERN, replacement)
		separated = grouped
		if count == 0 then
			break
		end
	end
	local sign = if whole < 0 then "-" else ""
	return sign .. Economy.display.symbol .. separated
end

return Economy
