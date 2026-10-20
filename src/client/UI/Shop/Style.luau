--!strict
-- Layout sizes and words for the dealership and used-lot sheets (docs/phase-4-contracts.md "Shops").
--
-- Colors, fonts, text sizes, radii, spacing, touch-target size and draw order all come from UI/Theme; this
-- module only adds what is specific to the shop sheets: the heights of each block (so ShopSheet can size the
-- sheet to its content without measuring text), the screen sizes where the layout changes, and every string a
-- player reads. Sizes are pixels at UI scale 1 (ShopController scales the whole tree for bigger screens, never
-- down), and every tappable size is at least Theme.size.touchTarget (tests/Shop.spec checks).

local Theme = require(script.Parent.Parent.Theme)

local spacing = Theme.spacing
local touch = Theme.size.touchTarget
local line = Theme.text.body + spacing.xs -- one line of body text with its leading
local smallLine = Theme.text.small + spacing.xs + 1 -- one line of small text

local Style = {
	layout = {
		-- Screen shapes (in unscaled pixels, inside the safe area):
		--   sheet  narrower than a card plus its margins (portrait phones): a bottom sheet across the full width
		--   wide   at least wideMinWidth wide and shorter than wideBelowHeight (landscape phones, small windows):
		--          a wide card with two columns, so the price and the buttons never scroll out of view
		--   card   everything else (tablets, desktop): a centered card Theme.size.sheetMaxWidth wide
		margin = spacing.lg, -- between a card and the screen edge
		wideMinWidth = 540,
		wideBelowHeight = 600,
		wideMaxWidth = 760,
		asideShare = 0.44, -- share of a wide card the right column (price and buttons) takes
		asideMinWidth = 240,
		asideMaxWidth = 320,
		cardRise = spacing.xl, -- a card slides up this far as it opens (a bottom sheet slides up from the edge)

		pad = spacing.lg, -- inside the sheet
		sectionGap = spacing.md, -- between blocks in the scrolling body

		-- Header: eyebrow (brand), title (car), subtitle (segment), with the close button top right.
		headerTop = spacing.md + 2,
		eyebrowHeight = smallLine,
		titleHeight = Theme.text.title + 6,
		subtitleHeight = smallLine,
		headerBottom = spacing.sm + 2,
		closeSize = touch,
		closeGlyph = 16, -- the X drawn inside the close button
		closeStroke = 2,

		-- Trim chips: one row that scrolls sideways when the trims don't fit.
		chipHeight = touch,
		chipPadding = spacing.lg, -- text inset on each side of a chip
		chipGap = spacing.sm,
		chipScrollBar = spacing.xs,

		specLineHeight = smallLine, -- "Sedan · RWD · Electric"

		-- Stat bars: label and value on one line, the bar under them.
		statLabelHeight = smallLine,
		statBarGap = spacing.xs + 2,
		statGap = spacing.md,
		statMinFill = 0.06, -- the lowest value in the catalog still shows a sliver of bar

		-- Price block: a small label, the price, and one status line (cash after, cash needed, stock left).
		priceLabelHeight = smallLine,
		priceHeight = Theme.text.price + 6,
		priceStatusHeight = smallLine,
		priceGap = 2,

		-- Note card: a short explanation in a raised card (how to get a trim, why Buy is off).
		noteLines = 2,
		noteLineHeight = smallLine,
		notePadding = spacing.md,

		finePrintHeight = smallLine,

		-- Free-starter banner on the used lot.
		claimPadding = spacing.md,
		claimTitleHeight = line + 2,
		claimTextHeight = smallLine,
		claimGap = spacing.sm,

		-- The robotaxi fleet card on the fleet brand's cars (Phase 9): a title, two lines of small text and a
		-- button, inside an outline (so the raised button shows against it).
		fleetCardPadding = spacing.md,
		fleetCardTitleHeight = line + 2,
		fleetCardLines = 2,
		fleetCardGap = spacing.sm,

		-- Action buttons in the footer.
		buttonHeight = Theme.size.buttonHeight,
		actionGap = spacing.sm,
		footerPad = spacing.md,

		-- Confirm dialog.
		confirmWidth = 340,
		confirmTitleHeight = Theme.text.heading + 8,
		confirmRowHeight = line + spacing.sm,
		confirmGap = spacing.md,

		statusHeight = line * 2, -- loading and empty messages in the body
	},

	-- Keys that close the open sheet (or cancel its confirm dialog). Keyboard and mouse use the close button;
	-- Escape stays with the Roblox menu.
	input = {
		closeKeys = { Enum.KeyCode.ButtonB },
	},

	copy = {
		close = "Close",
		separator = " · ",

		-- Spec line and stat bars.
		energy = {
			battery = "Electric",
			fuel = "Gas",
		} :: { [string]: string },
		inGarage = "In your garage",
		stats = {
			topSpeed = "Top speed",
			zeroToSixty = "0-60 mph",
			range = "Range",
			handling = "Handling",
			seats = "Seats",
		},
		units = {
			mph = "%d mph",
			kph = "%d km/h",
			seconds = "%.1f s",
			minutes = "%d min",
			handling = "%.1f / 10",
			seats = "%d",
			none = "-",
		},

		-- Dealership.
		price = "Price",
		upgradePrice = "Upgrade price",
		cashAfter = "Cash after: %s",
		cashNeeded = "You need %s more",
		cashLoading = "Checking your cash...",
		buy = "Buy",
		buying = "Buying...",
		garageFull = "Your garage is full. Sell a car in the phone's Garage app to make room.",
		testDrive = "Test drive",
		testDriveStarting = "Starting...",
		testDriveFinePrint = "Test drives last %d min and don't earn cash.",
		upgrade = "Upgrade",
		upgrading = "Upgrading...",
		upgradeOwned = "Upgrades the %s you already own.",
		upgradeLocked = "Buy the %s first, then upgrade it here.",
		-- The robotaxi fleet card (Phase 9): opens the phone's Fleet app, where pods are bought.
		fleetCard = {
			title = "Robotaxi fleet",
			body = "Self-driving pods carry riders around the county and earn for you.",
			open = "Buy pods",
		},
		how = {
			starter = "Your first used %s is free at the used lot.",
			usedLot = "Sold at the used lot. The stock changes every day.",
			fleet = "Bought for your robotaxi fleet in the phone's Fleet app.",
			limited = "Only in limited drops. Watch for the next one.",
			other = "Not sold here.",
		} :: { [string]: string },

		-- Used lot.
		lotEyebrow = "Used lot · Space %d",
		lotTitle = "Today's stock", -- the title until the space's car is known
		todaysPrice = "Today's price",
		left = "%d left today",
		soldOut = "Sold out today",
		priceRises = "Price rises as they sell",
		loading = "Checking today's stock...",
		loadingButton = "Loading...",
		loadFailed = "Couldn't load today's stock.",
		retry = "Try again",
		emptySpace = "This space is empty today. Check back tomorrow.",
		claimTitle = "Your free car is waiting",
		claimText = "Claim a used %s. One per player.",
		claimFallbackCar = "car",
		claim = "Claim free car",
		claiming = "Claiming...",

		-- Confirm dialog.
		confirmBuy = "Buy the %s?",
		confirmUpgrade = "Upgrade to the %s?",
		confirmUsed = "Buy this %s?",
		yourCash = "Your cash",
		after = "After",
		cancel = "Cancel",

		-- Replies (the server's own message is shown when it sends one).
		done = "Done!",
		failed = "That didn't go through. Please try again.",
		tryLater = "Too many tries. Wait a few seconds and try again.",
	},
}

return Style
