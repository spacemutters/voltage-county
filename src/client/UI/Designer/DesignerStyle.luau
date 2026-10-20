--!strict
-- Layout sizes and words for the AI Car Designer's screens (docs/phase-11-contracts.md "Client"; PLAN.md Phase 11):
-- the Design Studio sheet, "Mod with AI", the Out of credits sheet, the Report sheet and the phone's Designer app.
--
-- Colors, fonts, text sizes, radii, spacing, touch-target size and draw order all come from UI/Theme, and the
-- sheet's frame and blocks from the shop kit (UI/Shop/Style, Primitives, ShopSheet). This module adds only what is
-- specific to the designer: the heights of its own blocks (so ShopSheet can size the sheet without measuring text),
-- the studio prompt, the attributes that remember the player's first visit and the AI notice, and every string a
-- player reads. Prices, the full AI notice and the report reasons come from Config/Designer when it has them
-- (UI/Designer/DesignerModel reads it); the words here are what shows until it does. Sizes are pixels at UI scale
-- 1; every tappable size is at least Theme.size.touchTarget (tests/DesignerUi.spec checks).
--
-- Read by Controllers/DesignerController, UI/Designer/* and UI/Phone/DesignerApp.

local Theme = require(script.Parent.Parent.Theme)

local spacing = Theme.spacing
local touch = Theme.size.touchTarget
local line = Theme.text.body + spacing.xs -- one line of body text with its leading
local smallLine = Theme.text.small + spacing.xs + 1 -- one line of small text

local DesignerStyle = {
	-- Where the studio is: a Config/MapLayout location id. Its part (tagged with the location's tag) gets a
	-- "Design a car" prompt on this client; triggering it opens the studio and unlocks the phone's Designer app.
	studio = {
		locationId = "pl_design_studio",
		promptName = "DesignStudioPrompt",
		holdSeconds = 0,
		reachMargin = 8, -- studs past the footprint's half diagonal
	},

	-- LocalPlayer attributes that remember, for the session, that the player visited the studio (the phone's
	-- Designer app shows) and acknowledged the AI notice. The server may set the same attributes to keep them
	-- across visits; either way the profile (any design, mod or the free car used) counts as both.
	attributes = {
		unlocked = "DesignerUnlocked",
		disclosureSeen = "DesignerDisclosureSeen",
	},

	-- Above the driving controls and the phone's own Back (Config/Controls.actionPriority + 1), so gamepad B closes
	-- the designer sheet first.
	priorityAbovePhone = 2,
	closeKeys = { Enum.KeyCode.ButtonB },

	-- Waiting for a result (DesignResult). The server always answers (a design, a refusal or a timeout, with the
	-- credits refunded); these only keep the screen honest if an answer is lost.
	waiting = {
		slowAfterSeconds = 20, -- the progress screen says it can be closed
		giveUpSeconds = 180, -- the request is dropped from the screen (a late answer still shows)
	},

	-- What a new car and a mod cost, and the free re-rolls that come with a paid and with the free design, used only
	-- when Config/Designer doesn't say (PLAN.md §4). The server charges and counts; these are words on a button.
	fallbackPrices = { newCar = 2, mod = 1, rerollsPaid = 1, rerollsFree = 0 },

	-- The longest report reason id Net ReportDesign accepts (its REPORT_REASON_LENGTH); longer ids are left out.
	reportReasonMaxLength = 40,

	layout = {
		-- The prompt box: a few wrapped lines, with the character counter under it on the right.
		promptLines = 3,
		promptLineHeight = line,
		promptPadding = spacing.md,
		counterHeight = smallLine,
		counterGap = spacing.xs,

		-- The class picker: a small title over one row of the shops' chips.
		pickerTitleHeight = smallLine,
		pickerGap = spacing.xs,

		-- The AI notice card before the first request.
		disclosureLines = 6,
		disclosureLineHeight = line,
		disclosurePadding = spacing.md,

		-- Plain paragraphs (a refusal, the out-of-credits explanation).
		paragraphLines = 3,
		paragraphLineHeight = line,

		-- The car preview: a turning car in a rounded box.
		previewHeight = 180,
		beforeAfterHeight = 150, -- each of the two boxes side by side on the mod result
		previewLabelHeight = smallLine,
		previewGap = spacing.sm,
		previewTurnSeconds = 14, -- one slow turn
		previewElevation = 0.32, -- radians the camera looks down from
		previewFov = 40,
		previewFill = 1.15, -- distance multiplier past a tight fit, so the car never touches the edges

		-- The progress bar: a short bar sliding along a track.
		progressHeight = 6,
		progressShare = 0.3, -- of the track the moving bar covers
		progressSeconds = 1.4, -- one pass along the track
		progressBlockHeight = line * 3,

		-- Report reasons: one full-width row each.
		reasonRowHeight = touch,
		reasonGap = spacing.xs,

		-- A full-width button inside the body (Report this design).
		inlineButtonHeight = Theme.size.buttonHeight,
	},

	-- Every string a player reads. Plain words.
	copy = {
		studio = "Design Studio",
		modEyebrow = "Mod with AI",
		creditsEyebrow = "Design Credits",
		reportEyebrow = "Report",

		-- The prompt.
		promptAction = "Design a car", -- the studio prompt's action text
		describeTitle = "Describe your car",
		describeHint = "Shape, style, colors, vibe.",
		placeholder = "A tough little off-roader in mint green with a roof rack",
		modPlaceholder = "Lift it, chunky off-road tires, roof rack, desert tan",
		counter = "%d/%d", -- characters used, the limit
		classTitle = "Class",
		surprise = "Surprise me",
		emptyPrompt = "Describe your car first.",
		emptyModPrompt = "Describe the change first.",
		shortPrompt = "Tell the AI a little more about it.",

		-- The AI notice (Config/Designer's own text replaces `disclosureBody` when it has one).
		disclosureTitle = "Before you start",
		disclosureLead = "An AI designs your car from your words.",
		disclosureBody = "It makes original cars only, so real brands become a car with the same vibe. "
			.. "Keep your words friendly, and never type personal info like your name or address.",
		disclosureOk = "Got it",
		finePrint = "An AI designs your car from your words.",
		modFinePrint = "An AI changes your car from your words.",

		-- Cost.
		cost = "Cost",
		free = "Free",
		oneCredit = "1 credit",
		credits = "%d credits",
		usesOne = "This uses 1 credit.",
		uses = "This uses %d credits.",
		firstFree = "Your first car is free.",
		balance = "You have %s.", -- "2 credits"
		needMore = "You need %s more.", -- "1 credit"
		checking = "Checking your credits...",
		design = "Design it",
		modIt = "Mod it",
		sending = "Sending...",

		-- Progress.
		designingTitle = "Designing your car",
		moddingTitle = "Changing your car",
		designingBody = "The AI is working on it. This usually takes under a minute.",
		slowBody = "Still working. You can close this and keep driving; we'll tell you when it's ready.",
		close = "Close",
		ready = "Your new design is ready. Open the Design Studio to see it.",
		modReady = "Your mod is done.",
		gaveUp = "That took too long. Any credits it used will come back.",

		-- The result.
		resultEyebrow = "Your design",
		build = "Build",
		building = "Building...",
		reroll = "Re-roll",
		freeReroll = "Free re-roll",
		rerolling = "Re-rolling...",
		discard = "Discard",
		discarding = "Discarding...",
		rerollNote = "One re-roll is free.",
		rerollCost = "A re-roll now makes a new design for %s.", -- "2 credits"
		report = "Report this design",
		discardTitle = "Discard this design?",
		discardRow = "It won't be saved.",
		keep = "Keep it",
		builtTitle = "It's in your garage",
		builtBody = "Find it any time in your phone's Garage app.",
		driveIt = "Drive it",
		done = "Done",
		previewMissing = "Preview not available",
		energy = { battery = "Electric", fuel = "Gas" } :: { [string]: string },
		separator = " · ",

		-- Refused or failed.
		refusedTitle = "Couldn't design that",
		modRefusedTitle = "Couldn't change that",
		tryAgain = "Try again",

		-- Mod with AI.
		modBody = "Describe a change and the AI applies it to your copy of this car.",
		modCatalogNote = "On dealership cars the AI can change the paint, wheels, stance and extras.",
		modDoneTitle = "Your mod is on",
		before = "Before",
		after = "After",
		reportMod = "Report this mod",

		-- Out of credits and the credit store (the store arrives in a later update).
		outTitle = "Out of credits",
		outBody = "%s, and you have %s.", -- "A new car uses 2 credits", "0 credits"
		outDesign = "A new car uses %s",
		outMod = "A mod uses %s",
		yourCredits = "Your credits",
		getCredits = "Get credits",
		notNow = "Not now",
		storeTitle = "Credit store",
		storeBody = "The credit store opens in a coming update. Check back soon.",
		back = "Back",

		-- Report.
		reportTitle = "Report this car",
		reportBody = "Tell us what's wrong. A moderator will take a look.",
		sendReport = "Send report",
		reportReasons = {
			{ id = "offensive", label = "It's rude or offensive" },
			{ id = "brand", label = "It copies a real brand" },
			{ id = "unsafe", label = "It's not OK for kids" },
			{ id = "other", label = "Something else" },
		} :: { { id: string, label: string } },

		-- Replies (the server's own message is shown when it sends one).
		failed = "That didn't go through. Please try again.",
		tryLater = "Too many tries. Wait a few seconds and try again.",
		loading = "Loading your designs...",
		yourDesign = "Your design", -- a design with no name to show (hidden, or not loaded)
		yourCar = "Your car",
	},

	-- The phone's Designer app (UI/Phone/DesignerApp).
	app = {
		title = "Design Studio",
		body = "An AI designs your car from your words. Describe it, pick a class, and drive it minutes later.",
		open = "Open the Design Studio",
		freeCar = "Your first car is free.",
		credits = "Design Credits",
		working = "Your car is being designed...",
		readyTitle = "Your design is ready",
		see = "See it",
		watch = "View progress",
		designs = "Your designs",
		slots = "%d of %d design spaces used", -- designs owned, custom slots
		noDesigns = "No designs yet. Your first one is free.",
		modTip = 'Change any car you own with "Mod with AI" in the Garage app.',
	},

	-- The Garage app's entries on each car (UI/Phone/GarageApp). A design is scrapped, not sold.
	garage = {
		modWithAi = "Mod with AI",
		report = "Report",
		scrap = "Scrap",
		scrapping = "Scrapping...",
		scrapTitle = "Scrap your %s?", -- the design's name
		scrapBody = "It's gone for good, and its design space is free again. You don't get credits back.",
		scrapConfirm = "Scrap it",
	},
}

return DesignerStyle
