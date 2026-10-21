--!strict
-- Tunables and words for the phone (docs/phase-4-contracts.md "Client UI") and the parts of the redesigned HUD
-- that are new in Phase 4: the energy row, the active-job slot and the speed unit labels.
--
-- Phase 9 adds the Fleet app (`fleet`, `fleetText`), the HUD's fleet chip (`hud.fleetChip`) and the cutscene
-- attribute that hides the HUD, the touch controls and the phone during a pod ride (`cutsceneAttribute`).
-- Phase 11 adds the Designer app to `apps` (its words and sizes live in UI/Designer/DesignerStyle).
-- Phase 12 adds the Store app to `apps` (its words and sizes live in UI/Store/StoreStyle).
--
-- Read by Controllers/PhoneController, Controllers/HudController, UI/Hud and every file in UI/Phone. Colors,
-- fonts, text sizes, corner radii and draw order come from UI/Theme; the driving HUD's own sizes stay in
-- Config/Controls `hud` and Config/Economy `hud`. Sizes are pixels at UI scale 1 (a landscape phone, Config/
-- Controls `hud.referenceShortSide`); the UI only ever scales up from there, so every touch target listed here
-- stays at least Theme.size.touchTarget (tests/Phone.spec checks them).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Hail = require(ReplicatedStorage.Shared.Config.Hail)
local Theme = require(script.Parent.Parent.Theme)

local spacing = Theme.spacing

export type AppId = "gps" | "garage" | "designer" | "jobs" | "fleet" | "store" | "wallet" | "codes" | "settings"
export type Glyph = AppId | "phone"
export type App = { id: AppId, label: string }

local PhoneConfig = {
	-- Opening and closing. The keyboard key and gamepad button toggle the phone from anywhere (not while typing).
	-- ButtonL1 is free: Config/Controls binds the triggers, X, Y, B, R3, D-pad up and A for driving.
	keys = {
		keyboard = { Enum.KeyCode.P },
		gamepad = { Enum.KeyCode.ButtonL1 },
		-- While the phone is open on a gamepad, B goes back a screen (then closes) instead of leaving the car.
		back = { Enum.KeyCode.ButtonB },
	},
	-- How those keys are written on the phone button and in the HUD hint row.
	keyGlyphs = {
		keyboard = "P",
		gamepad = "LB",
	},
	-- ContextActionService names. The back action binds above the driving controls so it wins over B = exit.
	actions = {
		toggle = "VoltagePhoneToggle",
		back = "VoltagePhoneBack",
	},

	-- The phone button: bottom centre on foot; beside or above the speed panel while driving, never over the
	-- touch pedals or steering zones (UI/Phone/Layout picks the spot).
	button = {
		size = Vector2.new(56, 48),
		cornerRadius = 14, -- matches the HUD panels (Config/Controls hud.cornerRadius)
		glyphSize = Vector2.new(14, 22), -- the little phone drawn on it
		badgeSize = 18, -- the key cap ("P", "LB") in its corner on keyboard and gamepad
		badgeTextSize = 11,
		badgeInset = -4, -- the badge pokes out past the button's top-right corner by this much
	},

	-- The phone sheet.
	sheet = {
		margin = spacing.lg, -- from the screen edges
		controlsGap = 10, -- kept clear between the sheet and the touch driving controls
		minWidth = 200, -- two app icons across; narrower spaces fall back to another placement
		minHeight = 240,
		maxHeight = 620, -- on tall screens the phone stays phone-sized
		headerHeight = 60,
		padding = spacing.lg,
		iconSize = 12, -- the Back chevron and the Close cross, drawn inside 44 px round buttons
		iconLine = 2, -- px
		grabberSize = Vector2.new(36, 4), -- the little handle at the top of the sheet
		slideOffset = 24, -- px the sheet rises in from when it opens
		scrollBarThickness = 4,
	},

	-- The home screen's app grid.
	grid = {
		iconSize = Theme.size.phoneAppIcon,
		glyphSize = 32, -- the drawing inside each icon
		labelHeight = 22,
		columnGap = spacing.md,
		rowGap = spacing.lg,
		minColumns = 2,
		maxColumns = 4,
		badgeSize = 12, -- the accent dot on the GPS icon while a route is active
	},

	-- Rows in the GPS list and other lists.
	list = {
		rowHeight = 48,
		sectionHeight = 32,
		rowPadding = 14,
	},

	-- Garage cards.
	garage = {
		cardPadding = 14,
		starSize = 44, -- the favorite toggle (touch target)
		starTextSize = 24,
		pillHeight = 22, -- "Out now"
		pillPadding = 10,
		buttonGap = spacing.sm,
		-- Location ids (Config/MapLayout) the empty garage offers directions to.
		usedLotLocation = "used_lot",
		dealershipLocation = "dealership",
	},

	-- The Fleet app (Phase 9). Its cards and buttons use the garage's sizes; these are the zone picker's rows.
	fleet = {
		zoneRowPadding = 10, -- above and below a zone's two lines (each row stays taller than a touch target)
		zoneLineGap = 2, -- between the zone's name and its demand and earnings line
		hereNowWidth = 88, -- room kept at the right of the moving pod's zone for its "Here now" pill
		cardGap = Theme.spacing.sm, -- between the lines and the button inside the earnings and buy cards
	},

	-- The "arriving soon" screen (Kit.ComingSoon), for an app whose feature lands in a later update.
	comingSoon = {
		topSpace = spacing.lg, -- above the badge
		badgeSize = 96, -- the round badge holding the app's drawing
		glyphSize = 44,
	},

	-- The music volume slider in Settings.
	slider = {
		trackHeight = 6,
		knobSize = 22,
		step = 0.1, -- the - and + buttons (also how gamepads change it)
		stepButtonWidth = 44,
	},

	-- GPS distances for players whose speed units are km/h (miles use Config/Gps panel.milesFormat).
	distance = {
		kilometersFormat = "%.1f km",
		minKilometers = 0.1,
	},

	-- The LocalPlayer attribute Controllers/HailController sets to true for a pod ride's cutscene and back to nil
	-- after it (docs/phase-9-contracts.md; named in Config/Hail). While it is true the HUD, the touch controls
	-- and the phone hide.
	cutsceneAttribute = Hail.cutscene.attribute,

	-- Optimistic changes (a units switch, a favorite star) show at once and wait this long for the server's
	-- next ProfileSnapshot to confirm them; if it never does, the screen goes back to what the server has.
	confirmHoldSeconds = 4,
	-- Settings and favorites are sent this long after the last tap, so a burst of taps (the volume + button)
	-- sends one request and stays inside the remotes' rate limits (Net UpdateSettings, SetFavorite).
	sendDelaySeconds = 0.4,

	-- The apps, in the order they sit on the home screen. The Designer app (Phase 11) shows only once it is unlocked
	-- (after the player's first visit to the Design Studio; UI/Designer/DesignerStore); UI/Phone/Phone draws its
	-- screen (UI/Phone/DesignerApp) and its icon (UI/Designer/DesignerGlyph). The Store app (Phase 12) always shows;
	-- UI/Phone/Phone draws its screen (UI/Phone/StoreApp) and its icon (UI/Store/StoreGlyph).
	apps = {
		{ id = "gps", label = "GPS" },
		{ id = "garage", label = "Garage" },
		{ id = "designer", label = "Designer" },
		{ id = "jobs", label = "Jobs" },
		{ id = "fleet", label = "Fleet" },
		{ id = "store", label = "Store" },
		{ id = "wallet", label = "Wallet" },
		{ id = "codes", label = "Codes" },
		{ id = "settings", label = "Settings" },
	} :: { App },

	-- What the phone says. Plain words: players read these.
	labels = {
		home = "Phone",
		loading = "Loading your phone...",
		tryLater = "Too many taps. Wait a moment and try again.",
		failed = "That didn't work. Please try again.",
	},

	gps = {
		headingTo = "Heading to",
		endRoute = "End route",
		pick = "Pick a place and the route shows on the road.",
		empty = "No destinations yet.",
	},

	garageText = {
		spaces = "%d of %d spaces", -- cars owned, garage slots
		emptyTitle = "Your garage is empty",
		emptyBody = "Claim your free car at the used lot, or buy one at the dealership.",
		toUsedLot = "Directions to the used lot",
		toDealership = "Directions to the dealership",
		spawn = "Spawn",
		spawning = "Spawning...",
		putAway = "Put away",
		puttingAway = "Putting away...",
		sell = "Sell",
		selling = "Selling...",
		outNow = "Out now",
		starter = "Starter car",
		noValue = "No trade-in value", -- a car that can't be sold back (not the starter, not a design)
		customName = "Your design",
		favoriteOn = "★",
		favoriteOff = "☆",
		confirmTitle = "Sell your %s?", -- vehicle name
		confirmBody = "You'll get %s, which is %d%% of what you paid.", -- price, percent
		keep = "Keep it",
		confirmSell = "Sell for %s", -- price
	},

	jobs = {
		title = "Jobs are on the way",
		body = "Rideshare, deliveries and towing will pay more than cruising around. Check back soon.",
		pill = "Arriving soon",
	},

	fleetText = {
		loading = "Loading your fleet...",
		introTitle = "Run your own robotaxi fleet",
		introBody = "Buy self-driving pods that pick up riders around the county and earn for you.",
		-- Earnings.
		ready = "Ready to collect",
		perHour = "Your pods make about %s an hour.", -- the whole fleet's expected $ an hour
		collect = "Collect",
		collecting = "Collecting...",
		-- The offline rule, from the snapshot: "Pods earn a quarter as much while you're away, for up to 8 hours."
		offline = "Pods earn %s as much while you're away, for up to %s.", -- the share in words, the hours
		offlineShares = {
			{ rate = 0.25, words = "a quarter" },
			{ rate = 0.5, words = "half" },
			{ rate = 0.75, words = "three quarters" },
		} :: { { rate: number, words: string } },
		offlinePercent = "%d%%", -- any other share
		hours = "%s hours",
		oneHour = "1 hour",
		onlineOnly = "Pods earn only while you're in the game.",
		-- Buying.
		slots = "%d of %d pod slots used",
		buy = "Buy a pod for %s", -- the price
		buying = "Buying...",
		slotsFull = "Every slot has a pod in it. Sell one to make room.",
		cashNeeded = "You need %s more for a pod.",
		noZones = "There's nowhere to send a pod right now. Check back soon.",
		-- Pods.
		yourPods = "Your pods",
		podName = "Pod %d", -- its place in the list
		demand = "%sx demand", -- the zone's demand multiplier, "1.2x demand"
		zoneLine = "%s · %s", -- zone name, demand
		earns = "About %s an hour", -- what one pod makes there
		unknownZone = "Waiting for a zone",
		move = "Move",
		moving = "Moving...",
		sell = "Sell",
		selling = "Selling...",
		-- The zone picker.
		pickBuyTitle = "Where should it drive?",
		pickBuyBody = "Your new pod costs %s. Busier zones earn more.", -- the price
		pickMoveTitle = "Move %s", -- the pod's name
		pickMoveBody = "Pick the zone it drives riders around. Busier zones earn more.",
		zoneDetail = "%s · %s", -- demand, what one pod makes there
		hereNow = "Here now",
		cancel = "Cancel",
		-- The sell confirm.
		confirmTitle = "Sell %s?", -- the pod's name
		confirmBody = "You'll get %s back, and it stops earning for you.", -- the price
		keep = "Keep it",
		confirmSell = "Sell for %s", -- the price
	},

	wallet = {
		cash = "Cash",
		cashNote = "Earn more by driving around the county.",
		credits = "Design Credits",
		creditsNote = "Spend them in the Design Studio to make cars of your own.",
	},

	codes = {
		body = "Codes come with updates and events. Type one in to claim its reward.",
	},

	settings = {
		units = "Speed units",
		unitOptions = { mph = "mph", kph = "km/h" } :: { [string]: string },
		camera = "Starting camera",
		cameraNote = "The view every drive starts in.",
		cameraOptions = { chase = "Chase", orbit = "Orbit", hood = "Hood" } :: { [string]: string },
		music = "Music volume",
		volumeFormat = "%d%%",
		down = "-",
		up = "+",
	},

	-- New parts of the HUD (UI/Hud).
	hud = {
		unitLabels = { mph = "mph", kph = "km/h" } :: { [string]: string },
		-- The energy row along the bottom of the speed panel (Phase 5): a battery or pump drawing, the level bar,
		-- then the % and the range (or "Limp mode").
		energy = {
			rowHeight = 18,
			barHeight = 4,
			percentFormat = "%d%%",
			iconSize = Vector2.new(16, 10), -- the battery or pump drawing
			iconStroke = 1.5, -- its outline
			iconInset = 2, -- between the battery's outline and its charge
			nubSize = Vector2.new(2, 4), -- the battery's terminal
			gap = 6, -- between the drawing, the bar and the value
			valueWidth = 84, -- "100%  120 mi"
			rangeSpacing = "  ", -- between the % and the range
			limpText = "Limp mode", -- in place of the range once the car is empty
			-- The row shows the level in steps of this (half a percent: under a pixel of the bar), so it redraws
			-- when something visible changes rather than on every server sample.
			shownLevelStep = 0.005,
			-- What the driver reads (Controllers/EnergyController). %s is filled in where noted.
			text = {
				rangeMiles = "%s mi",
				rangeKilometers = "%s km",
				-- Ranges under this (in the shown unit) get one decimal ("4.2 mi"); longer ones are whole.
				decimalsBelow = 10,
				rate = "+%.1f%% a sec", -- percent per second
				costPerPercent = "%s per %%", -- the price
				-- On empty, once the GPS is routing (%s: the station's name).
				routed = {
					battery = "Your GPS is set to the nearest charger: %s.",
					fuel = "Your GPS is set to the nearest fuel station: %s.",
				} :: { [string]: string },
				-- On empty, when the server found no station to route to.
				noStation = {
					battery = "Open the GPS and head for a charging stall.",
					fuel = "Open the GPS and head for a fuel station.",
				} :: { [string]: string },
			},
		},
		-- The card shown while the car charges or fuels (UI/Hud draws it; Controllers/HudController places it,
		-- above the speed panel when there's room, `Config/Controls hud.gap` from it, and never over the touch
		-- controls, the phone button, the cash and job slot, the GPS route chip or the notices). Narrower than
		-- the speed panel so it still fits between the GPS chip and the cash on a small phone.
		chargingCard = {
			size = Vector2.new(180, 60),
			padding = Vector2.new(12, 6), -- sides, top and bottom
			rowGap = 3,
			barHeight = 6,
			titles = { battery = "Charging", fuel = "Fueling" } :: { [string]: string },
			-- The notices band at the top centre is kept clear for a notice this many lines tall.
			noticeLines = 2,
			noticeLineHeight = 1.25, -- line height as a multiple of the notice text size
		},
		-- The active job, under the cash readout (Phase 6 fills it; empty until then).
		jobSlot = {
			size = Vector2.new(200, 56),
			padding = 12,
			titleTextSize = 15,
			detailTextSize = 13,
			-- A title or stop line too long for the slot shrinks down to this before it is cut short.
			minTextSize = 11,
		},
		phoneHint = "Phone", -- the HUD hint row entry for the phone key
		-- The fleet chip (Phase 9): "$1,240 ready" once the robotaxi fleet's uncollected earnings reach the
		-- threshold; tapping it opens the Fleet app. It sits right of the cash readout, or under the cash column
		-- when that spot would touch a driving control (Controllers/HudController.fleetChipPlacement), and is
		-- as tall as the cash readout (Config/Economy hud.rowHeight, a touch target).
		fleetChip = {
			threshold = 1000, -- whole $ uncollected before the chip shows
			maxWidth = 160, -- wider amounts are cut short ("$1,234,5...")
			padding = 12, -- inside the chip, each side
			glyphSize = 18, -- the little pod drawn at its left
			gap = 6, -- between the drawing and the text
			text = "%s ready", -- the amount
		},
	},
}

return PhoneConfig
