--!strict
-- Sizes and words for the admin panel (PLAN.md Phase 12 "Admin tools"; UI/Admin/AdminPanel,
-- Controllers/AdminController). Colors, fonts, text sizes and spacing come from UI/Theme and the phone's kit, so the
-- panel matches the phone. Mobile-first: sizes are pixels at UI scale 1, and every tappable thing is at least
-- Theme.size.touchTarget (44 px) in both directions.

local Theme = require(script.Parent.Parent.Theme)

local AdminStyle = {
	-- Draw order: above the phone and the shops, below notices (UI/Theme.displayOrder).
	displayOrder = Theme.displayOrder.shop + 1,

	-- The small "Admin" button that opens the panel: top left, to the right of the Studio spawn menu's column.
	toggle = {
		size = Vector2.new(84, Theme.size.touchTarget),
		position = Vector2.new(250, Theme.spacing.lg), -- from the safe area's top-left corner
	},
	-- Keyboard shortcut (desktop): opens and closes the panel when nothing else has the key.
	toggleKey = Enum.KeyCode.F8,

	sheet = {
		margin = Theme.spacing.lg, -- from the screen edges
		headerHeight = 56,
		closeSize = Vector2.new(84, Theme.size.touchTarget),
	},

	-- How long a Kick button waits for its second tap before it goes back to normal.
	confirmSeconds = 4,
	-- Log lines shown (newest last); the server keeps more.
	logLinesShown = 40,
	-- Design reports and analytics events shown under the log.
	reportsShown = 10,
	eventsShown = 10,

	-- Studio only: set your own cash or credits to one of these (the dev remotes refuse outside Studio).
	studioCash = { 100000, 1000000, 10000000 },
	studioCredits = { 10, 100 },

	-- What the admin reads. Plain words.
	text = {
		toggle = "Admin",
		title = "Admin tools",
		close = "Close",
		players = "Players here",
		you = "(you)",
		kick = "Kick",
		confirmKick = "Tap again to kick",
		despawn = "Put car away",
		hide = "Hide a design or mod",
		hideHint = "Design or car id",
		hideButton = "Hide",
		log = "Recent log",
		serverLog = "Warnings, errors and admin actions",
		refresh = "Refresh",
		empty = "Nothing yet. Tap Refresh.",
		reports = "Latest design reports",
		events = "Latest analytics events",
		studio = "Studio only",
		cash = "Cash: %s", -- the amount, e.g. "$1,000,000"
		credits = "Credits: %d",
		working = "Working...",
		noAnswer = "No answer from the server. Try again.",
	},
}

return AdminStyle
