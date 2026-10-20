--!strict
-- The one look every screen shares (docs/phase-4-contracts.md, "Client UI"). Colors and fonts come from
-- Config/Controls.theme, the palette the HUD, GPS and toasts already use, so new screens match them; this
-- module adds the sizes, spacing and states the phone and shop screens need. Mobile-first: sizes are pixels at
-- UI scale 1, touch targets are at least 44 px, and body text keeps 4.5:1 contrast on the panels.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Controls = require(ReplicatedStorage.Shared.Config.Controls)

local palette = Controls.theme

local Theme = {
	colors = {
		panel = palette.panel, -- sheet and card backgrounds
		panelRaised = palette.panelRaised, -- cards and buttons on a panel
		panelTransparency = palette.panelTransparency,
		text = palette.text,
		textDim = palette.textDim, -- secondary text (still 4.5:1 on panel)
		accent = palette.accent, -- the one accent: primary buttons, selected states, stat bars
		onAccent = palette.onAccent, -- text on an accent fill
		success = Color3.fromRGB(110, 214, 150),
		warning = Color3.fromRGB(255, 200, 92),
		danger = Color3.fromRGB(255, 120, 120), -- destructive actions (sell) and errors
		scrim = Color3.fromRGB(0, 0, 0), -- behind an open sheet
		scrimTransparency = 0.45,
		divider = Color3.fromRGB(60, 66, 80),
		track = Color3.fromRGB(48, 53, 64), -- empty part of a stat bar
	},

	fonts = palette.fonts,

	text = {
		title = 22,
		heading = 18,
		body = 15,
		small = 13,
		price = 24,
	},

	size = {
		touchTarget = 44, -- minimum height and width of anything you tap
		buttonHeight = 48,
		iconButton = 52,
		statBarHeight = 8,
		sheetMaxWidth = 460, -- phone and shop sheets on wide screens
		sheetMaxHeightScale = 0.9, -- share of the screen height a sheet may use
		phoneAppIcon = 72,
	},

	spacing = {
		xs = 4,
		sm = 8,
		md = 12,
		lg = 16,
		xl = 24,
	},

	radius = {
		sheet = 20,
		card = 14,
		button = 12,
		pill = 999,
	},

	-- Draw order of the ScreenGuis, low to high. The HUD sits at 0; sheets above it; toasts above everything.
	displayOrder = {
		hud = 0,
		gps = 1,
		phone = 5,
		shop = 6,
		toast = 10,
	},

	motion = {
		sheetSeconds = 0.18, -- open/close slide
		pressScale = 0.97, -- a button shrinks slightly while pressed
	},
}

return Theme
