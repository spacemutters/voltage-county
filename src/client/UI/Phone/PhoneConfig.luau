--!strict
-- Tunables and words for the phone (docs/phase-4-contracts.md "Client UI") and the parts of the redesigned HUD
-- that are new in Phase 4: the energy row, the active-job slot and the speed unit labels.
--
-- Read by Controllers/PhoneController, Controllers/HudController, UI/Hud and every file in UI/Phone. Colors,
-- fonts, text sizes, corner radii and draw order come from UI/Theme; the driving HUD's own sizes stay in
-- Config/Controls `hud` and Config/Economy `hud`. Sizes are pixels at UI scale 1 (a landscape phone, Config/
-- Controls `hud.referenceShortSide`); the UI only ever scales up from there, so every touch target listed here
-- stays at least Theme.size.touchTarget (tests/Phone.spec checks them).

local Theme = require(script.Parent.Parent.Theme)

local spacing = Theme.spacing

export type AppId = "gps" | "garage" | "jobs" | "fleet" | "wallet" | "codes" | "settings"
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

	-- The "arriving soon" screens (Jobs, Fleet).
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

	-- Optimistic changes (a units switch, a favorite star) show at once and wait this long for the server's
	-- next ProfileSnapshot to confirm them; if it never does, the screen goes back to what the server has.
	confirmHoldSeconds = 4,
	-- Settings and favorites are sent this long after the last tap, so a burst of taps (the volume + button)
	-- sends one request and stays inside the remotes' rate limits (Net UpdateSettings, SetFavorite).
	sendDelaySeconds = 0.4,

	-- The apps, in the order they sit on the home screen.
	apps = {
		{ id = "gps", label = "GPS" },
		{ id = "garage", label = "Garage" },
		{ id = "jobs", label = "Jobs" },
		{ id = "fleet", label = "Fleet" },
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

	fleet = {
		title = "Run your own robotaxi fleet",
		body = "Buy self-driving pods that pick up riders around the county and earn for you.",
		pill = "Arriving soon",
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
		-- The energy row along the bottom of the speed panel. Phase 5 fills it; until then the bar shows full
		-- with no number.
		energy = {
			rowHeight = 18,
			barHeight = 4,
			labelWidth = 52,
			valueWidth = 38,
			labels = { battery = "Battery", fuel = "Fuel" } :: { [string]: string },
			percentFormat = "%d%%",
		},
		-- The active job, under the cash readout (Phase 6 fills it; empty until then).
		jobSlot = {
			size = Vector2.new(200, 56),
			padding = 12,
			titleTextSize = 15,
			detailTextSize = 13,
		},
		phoneHint = "Phone", -- the HUD hint row entry for the phone key
	},
}

return PhoneConfig
