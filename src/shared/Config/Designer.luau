--!strict
-- The AI Car Designer and AI mods: prices, the backend, time limits, slot rules, moderation and every message the
-- player reads (PLAN.md Phase 11 and §4; docs/phase-11-contracts.md "Server").
--
-- Read by Services/CreditsService (the free design, the balance cap), Services/DesignerService (the request flow,
-- the backend, the dev fake backend, reports and hiding), Services/VehicleService and GarageService (custom cars),
-- Vehicle/GeneratedAdapter (the session-only generated look) and the client's Design Studio, mod screen and Out of
-- credits sheet (prices, the AI disclosure, the report reasons, the messages). Everything the design itself may
-- hold (classes, templates, parts, ranges, text limits) lives in Config/DesignKit.json instead.
--
-- Pure data: no requires and no Roblox types, so any module (and the client) can read it.
--
-- Secrets never live here (CLAUDE.md hard rule 11): the game reads the shared backend key from the Roblox Secrets
-- store by the NAME below, and the salt for the player hash is made once on a live server and kept in a DataStore.

export type ReportReason = { id: string, label: string }

local Designer = {
	-- Config/FeatureFlags key that switches the designer off: FeatureFlagService.isOn(featureFlag) is false (its
	-- live override, else FeatureFlags.defaults[featureFlag]). A missing key means `enabledByDefault`. The backend
	-- has its own on/off switch as well (designer_settings).
	featureFlag = "designer",
	enabledByDefault = true,

	-- The backend (backend/ on Vercel), its bare production origin. "" would answer `messages.closed` to every
	-- request with nothing charged; until its keys are set the backend itself answers 503 and the game refunds.
	backendUrl = "https://voltage-county-designer.vercel.app",
	-- Name of the shared secret in the experience's Secrets store (HttpService:GetSecret). Davis enters the value
	-- in the Creator Dashboard (and under Local Secrets for Studio); it is sent only in the header below.
	secretName = "designer_key",
	apiKeyHeader = "x-api-key",
	paths = {
		design = "/api/design",
		mod = "/api/mod",
	},
	-- How long the game waits for the backend before giving up (the credits come back), and how many times a
	-- request that failed to reach the backend at all (no HTTP status) is sent again within that time. Keep the
	-- timeout at least 5 s above the backend's own budget (backend/lib/limits.ts REQUEST_BUDGET_MS, 25 s), or a
	-- request that needs its retry is refunded here while the backend still spends and caches it
	-- (backend/tests/kit.test.ts checks this).
	requestTimeoutSeconds = 35,
	networkRetries = 1,

	-- Studio only (RunService:IsStudio()): answer requests with a local fake that returns a valid fixed spec per
	-- class, so the designer can be tested without the real backend. Live servers ignore this.
	devFakeBackend = true,
	devFake = {
		delaySeconds = 1.5, -- pretend the backend takes this long
		-- A prompt starting with one of these makes the fake fail that way (to test refunds in Studio). `empty`
		-- answers a mod the way the backend does when nothing it can build was asked for: every field kept, an
		-- empty extras list and an accessory (it is refunded as "didn't find anything to change").
		triggers = { refuse = "test:refuse", error = "test:error", timeout = "test:timeout", empty = "test:empty" },
		refusal = "That one isn't something the studio can make. Try another idea!",
		name = "Studio %s", -- the class display name
		tagline = "A fixed test design from the Studio fake",
		meshPrompt = "simple %s car body with smooth rounded panels", -- the body template id
		personality = "balanced",
		paint = { primary = "#2F6FDB", secondary = "#F2F2F2", finish = "metallic", stripe = "center" },
		mod = {
			summary = "Desert tan paint, chunky wheels, roof rack",
			primary = "#C8A878",
			wheels = "trail",
			rideHeight = 0.6,
			extras = { "roof_rack" } :: { string },
		},
	},

	-- The player hash sent to the backend: SHA-256 of a salt and the UserId (never the UserId itself). The salt is
	-- a random GUID made once with UpdateAsync and kept in this DataStore; it never leaves the server.
	salt = { store = "DesignerSalt", key = "salt" },

	-- Prices in Design Credits (PLAN.md §4). The first new car is free; after that a new car costs `newCar` with
	-- `rerollsPaid` free re-rolls included, and an AI mod on a car you own costs `mod`. Credits are reserved when a
	-- request starts, spent once a design comes back (whether it is then built or discarded) and refunded on a
	-- refusal, a moderation failure, an error or a timeout.
	prices = {
		newCar = 2,
		mod = 1,
		rerollsPaid = 1, -- free re-rolls with a paid design
		rerollsFree = 0, -- free re-rolls with the one free design
	},
	-- Nobody's balance ever goes above this (a sanity cap far beyond any pack).
	maxCredits = 100000,

	-- Custom cars (PLAN.md §6): OwnedVehicle.vehicleId is `customVehicleId` (Config/Garage) with `designUid` set,
	-- and they take one of the player's customSlots (Config/Economy.customSlots to start) instead of a garage slot.
	-- A spawned design is a catalog entry `catalogPrefix .. designUid` with the single trim `designTrim`
	-- (Vehicle/Catalog resolves it through ReplicatedStorage.DesignCatalog).
	catalogPrefix = "custom:",
	designTrim = "design",
	-- Built design models (one per design per server, plus the session-only generated looks) are kept here, in
	-- ServerStorage, for VehicleService to clone.
	modelsFolder = "DesignModels",

	-- The session-only generated look (Vehicle/GeneratedAdapter). A new design asks GenerationService for a body
	-- from the spec's meshPrompt; if it arrives within `timeoutSeconds`, the car wears it for the rest of that
	-- server session. The saved car always rebuilds from its kit spec.
	generation = {
		enabled = true,
		schema = "Car5",
		timeoutSeconds = 55,
		promptSuffix = ", original design, no logos, badges or text",
		lookAttribute = "GeneratedLook",
		-- The generated body is scaled so its axles line up with the kit build's; the scale is then kept within
		-- these shares of the scale that would make its length match the kit body (stops a squat or stretched
		-- mesh from ending far bigger or smaller than the car).
		minLengthShare = 0.85,
		maxLengthShare = 1.2,
	},

	-- Reports (ReportDesign) and hiding (HideDesign). Reports go to the server log and a short in-memory list for
	-- the admin tools; each player may report a car once and at most `maxPerSession` cars per session. Hidden
	-- designs and mods are recorded in the `hiddenStore` DataStore (key = design or car uid) so they stay hidden on
	-- every server; the car falls back to the plain look below (designs) or its stock look (mods).
	report = {
		maxPerSession = 10,
		recentKept = 100,
		reasons = {
			{ id = "rude", label = "Rude or offensive" },
			{ id = "brand", label = "Copies a real car brand" },
			{ id = "unsafe", label = "Not OK for younger players" },
			{ id = "other", label = "Something else" },
		} :: { ReportReason },
	},
	hiddenStore = "DesignerHidden",
	-- In Studio anyone may use HideDesign (to test it); live servers allow only Config/Admins.
	studioCountsAsAdmin = true,
	-- The plain look a hidden design falls back to (same class, template and stats; neutral paint, base parts).
	plainLook = {
		primary = "#B8BCC2",
		secondary = "#2B2F36",
		finish = "gloss",
		stripe = "none",
	},

	-- Shown before the first request, in the Design Studio and on the mod screen (PLAN.md "Disclosure").
	disclosure = "An AI designs these cars. Describe your idea and an AI turns it into an original car. "
		.. "What you type is checked for safety first and sent to our design service without your name. "
		.. "Designs are always original: no real car brands.",

	-- What the player reads. Plain words. %s / %d fill-ins are noted on each line.
	messages = {
		loading = "Your garage is still loading. Try again in a moment.",
		off = "The design studio is closed right now. Try again later.",
		closed = "The design studio is opening soon. Check back later!",
		busy = "Your last request is still being worked on. Wait for it to finish first.",
		pendingChoice = "Build, re-roll or discard your last design first.",
		working = "Designing your car...",
		modWorking = "Working on your mod...",
		empty = "Describe your car first.",
		tooLong = "Keep it to %d characters.", -- the limit
		badText = "That text can't be used. Try different words.",
		promptFiltered = "Not enough of that description could be used. Try describing it differently. "
			.. "You weren't charged.",
		filterFailed = "We couldn't check your description right now. You weren't charged. Try again in a moment.",
		unknownClass = "Pick a class from the list.",
		classLocked = "You need to own an exotic before you can design one.",
		slotsFull = "Your custom car slots are full. Scrap a custom car to make room.",
		outOfCredits = "You need %d credits for this.", -- the price
		refusedSuffix = " You weren't charged.", -- added after the designer's own friendly refusal
		refused = "The designer couldn't make that one. Try a different idea. You weren't charged.",
		limited = "The design studio is very busy. You weren't charged. Try again later.",
		error = "Something went wrong while designing. You weren't charged. Try again in a moment.",
		timeout = "The designer took too long. You weren't charged. Try again in a moment.",
		invalid = "The designer made something we can't build. You weren't charged. Try again.",
		ready = "Your design is ready!",
		built = "Your %s is in your garage.", -- the design's name
		discarded = "Design discarded.",
		rerolling = "Re-rolling your design...",
		noReroll = "There's no free re-roll left for this design.",
		rerollFailed = "The re-roll didn't work, so here's your design again. Your free re-roll is still there.",
		noPending = "That design isn't waiting anymore.",
		modReady = "Mod done: %s", -- the mod's summary
		modNothing = "The designer didn't find anything to change. Try describing it differently. "
			.. "You weren't charged.",
		notYours = "That car isn't in your garage.",
		cantMod = "That car can't be modded.",
		modHidden = "This car's mod was hidden by a moderator, so it shows its stock look.",
		reported = "Thanks. We'll take a look at that car.",
		reportAlready = "You already reported that car.",
		reportLimit = "You've sent a lot of reports. Thanks! Try again later.",
		reportNotFound = "We couldn't find that car.",
		reportReason = "Pick a reason from the list.",
		notAdmin = "Only admins can do that.",
		hidden = "Hidden. That car now shows its plain look.",
		hiddenLater = "Saved. It will be hidden when its owner next joins a server.",
		hideFailed = "Couldn't save that right now. Try again in a moment.",
		devOnly = "Dev tools only work in Studio.",
		devCredits = "Credits set to %d.", -- the new balance
		scrapped = "Scrapped your %s. Its custom slot is free again.", -- the design's name
		fallbackName = "Custom %s", -- class display name; a design name the text filter removed
		hiddenName = "Custom %s", -- class display name; a design a moderator hid
		genericClass = "Car", -- in those names when the class is unknown (a damaged save)
		fallbackSummary = "Mod applied",
	},
}

return Designer
