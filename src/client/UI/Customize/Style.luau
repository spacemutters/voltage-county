--!strict
-- Layout sizes and words for the Wrap & Tint shop (docs/phase-7-contracts.md "Client"; PLAN.md Phase 7).
--
-- Colors, fonts, text sizes, radii, spacing, touch-target size and draw order all come from UI/Theme; this
-- module adds only what is specific to the shop: the side panel's size and the heights of its rows (so the
-- panel can be laid out without measuring text), the swatch and card sizes, the keys, the steps the custom color
-- moves in, and every string a player reads. Sizes are pixels at UI scale 1 (a landscape phone;
-- CustomizationController scales the whole tree up for bigger screens, never down). Every tappable size is at
-- least Theme.size.touchTarget (tests/CustomizeShop.spec checks).

local Theme = require(script.Parent.Parent.Theme)

local spacing = Theme.spacing
local touch = Theme.size.touchTarget
local smallLine = Theme.text.small + spacing.xs + 1 -- one line of small text
local line = Theme.text.body + spacing.xs -- one line of body text

local Style = {
	layout = {
		-- The side panel stands on the right of the screen, full height, so the car stays in view in the middle
		-- and the panel covers the touch pedals (the car can't be driven off by a stray tap while shopping).
		margin = spacing.sm, -- between the panel and the screen edges
		widthShare = 0.4, -- of the screen width
		minWidth = 300,
		maxWidth = 380,
		pad = spacing.md, -- inside the panel

		-- Header: "Wrap & Tint" over the car's name on the left; Reset (when anything changed) and the close
		-- button on the right, all one touch target tall.
		headerTop = spacing.sm,
		headerHeight = touch,
		eyebrowHeight = smallLine,
		titleHeight = Theme.text.heading + 4,
		resetWidth = 72,
		closeSize = touch, -- the shops' round close button (UI/Shop/Primitives.CloseButton)
		headerGap = spacing.sm,

		-- Category tabs: one row of the shops' chips (UI/Shop/Primitives.TrimChips) that scrolls sideways.
		tabsGap = spacing.sm, -- above the row
		scrollBar = spacing.xs, -- the body's scroll bar

		-- The body: the current tab's options, scrolling.
		sectionGap = spacing.sm,
		detailHeight = line + 2, -- "Pearl White · $400" above a swatch grid
		noteLineHeight = smallLine,
		noteLines = 2,
		notePadding = spacing.md,
		plateRulesLines = 2, -- the plate rules under the text box

		-- Color swatches (paint, calipers): rounded squares, the chosen one ringed in the accent.
		swatchSize = 48,
		swatchGap = spacing.sm,
		swatchRing = 3, -- the chosen swatch's ring
		swatchSavedDot = 8, -- the small dot on the car's current color

		-- Option cards (finish, wrap, wheels, tint, extras, plate formats): name over price, two or three across.
		cardHeight = 56,
		cardGap = spacing.sm,
		cardMinWidth = 104, -- a column is added while every card stays at least this wide
		cardMaxColumns = 3,
		cardPadding = spacing.sm + 2,
		cardNameHeight = line,
		cardPriceHeight = smallLine,

		-- Steppers (ride height, the custom color's hue, saturation and brightness): - [value] +.
		stepperHeight = touch,
		stepperButton = touch,
		stepperLabelHeight = smallLine,
		stepperBarHeight = 8,
		stepperGap = spacing.xs,

		-- The custom plate text box and its Set button.
		inputHeight = Theme.size.buttonHeight,
		plateButtonWidth = 112,

		-- Footer: the running total on the left, Buy on the right.
		footerPad = spacing.sm,
		buttonHeight = Theme.size.buttonHeight,
		buyWidthShare = 0.5, -- of the footer's inner width
		totalLabelHeight = smallLine,
		totalValueHeight = Theme.text.price + 2,

		-- Confirm dialog.
		confirmWidth = 340,
		confirmTitleHeight = Theme.text.heading + 8,
		confirmRowHeight = line + spacing.sm,
		confirmGap = spacing.md,
		actionGap = spacing.sm,

		-- The "Customize" button that shows while the player's car stands in a shop's bay (prompts are hidden
		-- while seated). Centered near the top, under the notices, clear of the touch buttons in the corner.
		entryHeight = Theme.size.buttonHeight,
		entryMinWidth = 160,
		entryGap = 8, -- below the notices band (HudController.noticesRect), like the light show button
		entryKeyWidth = 28, -- the key hint chip ("E", "A") inside the button
	},

	-- How the custom color moves: each - / + tap steps by this much (0..1 scales; hue wraps round). The limits
	-- come from Config/Customization.customColor; these are only the step sizes.
	colorSteps = {
		h = 1 / 24, -- 15 degrees
		s = 0.05,
		v = 0.05,
	},

	-- The rainbow on the custom color swatch before a custom color has been picked (hue runs left to right).
	rainbow = { saturation = 0.6, value = 0.85 },

	-- Keys. While the car stands in a bay, E (keyboard) or A (gamepad) opens the shop like the prompt would;
	-- B closes it (bound above the driving controls so it doesn't stand the player up). Escape stays with the
	-- Roblox menu; keyboard and mouse use the close button.
	input = {
		openKeys = { Enum.KeyCode.E, Enum.KeyCode.ButtonA },
		openKeyGlyphs = { keyboard = "E", gamepad = "A" } :: { [string]: string },
		closeKeys = { Enum.KeyCode.ButtonB },
	},

	-- While the shop is open the orbit camera is slid sideways so the car sits in the middle of the screen left free
	-- by the panel, easing there at this stiffness (the share of the gap closed is 1 - exp(-stiffness * dt), like
	-- Controllers/CameraController).
	framing = { stiffness = 8 },

	-- How often (per second) the controller checks, while the player drives, whether their car stands in a
	-- shop's bay (for the Customize button) and, while the shop is open, whether it has driven out.
	bayCheckHz = 4,
	-- How high above a bay's floor a car's chassis may be and still count as in the bay (not on a bridge above).
	bayHeight = 12,

	copy = {
		eyebrow = "Wrap & Tint",
		reset = "Reset",
		separator = " · ",

		-- (Tab names come from Config/Customization.categories.)

		-- Prices on swatches and cards.
		current = "On your car",
		free = "Free",
		removing = "Comes off (free)",

		-- Paint.
		customColor = "Custom color",
		hue = "Hue",
		saturation = "Saturation",
		brightness = "Brightness",
		degrees = "%d°",
		percent = "%d%%",
		down = "-",
		up = "+",

		-- Stance.
		stock = "Stock",
		lowered = "Lowered %d",
		raised = "Raised %d",
		rideHeight = "Ride height",

		-- Wraps.
		paintOnlyWraps = "Stripes don't fit this car's curved body. Exclusive wraps go on as a full color.",

		-- Extras.
		noExtras = "No kit extras fit this car.",
		extrasHint = "Tap to add or take off. A spoiler, roof carrier or front piece swaps for another.",

		-- Plates.
		plateFormats = "Plate style (free)",
		plateText = "Custom text",
		platePlaceholder = "ABC 123",
		setPlate = "Set plate",
		settingPlate = "Setting...",
		plateLocked = "Custom plate text comes with the Custom Plates pass.",
		plateClearHint = "Leave it empty for your standard plate.",

		-- Footer and confirm.
		total = "Total",
		noChanges = "No changes yet",
		needMore = "You need %s more",
		buy = "Buy",
		apply = "Apply",
		buying = "Buying...",
		confirmTitle = "Buy these changes?",
		confirmTotal = "Total",
		yourCash = "Your cash",
		after = "After",
		cancel = "Cancel",

		-- Opening. (Replies to calls use the shops' words: UI/Shop/ShopModel.outcome.)
		customize = "Customize",
		notYourCar = "Drive one of your own cars into the bay to customize it.",
		loading = "Your garage is still loading. Try again in a moment.",
	},
}

return Style
