--!strict
-- The dealership: display cars, buying, upgrades and test drives (PLAN.md Phase 4; docs/phase-4-contracts.md
-- "Commerce"). Read by Services/DealershipService and Services/UsedLotService (display cars and their "View"
-- prompts), the shop UI (the prompt's name and attributes) and Dev/ShopTests. Where the pads are lives in
-- Config/MapLayout (`dealership`, `usedLot`); prices live in Config/Vehicles.
--
-- Pure data: no requires, no Roblox types.

local Dealership = {
	-- Display cars: anchored copies of the ServerStorage.VehicleModels templates standing on the pads. They are
	-- never drivable (seats disabled), never tagged as a spawned Vehicle, never tracked by anti-exploit and never
	-- paid by drive-to-earn.
	display = {
		folderName = "Showroom", -- Workspace.Showroom holds every display car (server-made)
		dealershipFolderName = "Dealership", -- Workspace.Showroom.Dealership: one car per brand pad
		usedLotFolderName = "UsedLot", -- Workspace.Showroom.UsedLot: one car per numbered space
		tag = "DisplayCar", -- CollectionService tag on every display car model
		-- Turntable speed in degrees per second. 0 keeps the cars still: pads stand 19 studs apart and the
		-- longest bodies are 24 long, so neighbouring cars would sweep through each other if they turned. Raise it
		-- only with wider pad spacing (Config/MapLayout PAD_PITCH).
		rotationDegreesPerSecond = 0,
		rotationStepsPerSecond = 15, -- how often a turning car is moved (only while rotation is on)
		-- The event spotlight (Phase 12): while a running event names a featured car (Config/Events
		-- featuredVehicleId, Services/EventService), that car's display model gets a Highlight called
		-- `highlightName` in this colour (0-255 RGB) and the model attribute `attribute` = true. It moves the moment
		-- an event starts or ends.
		featured = {
			highlightName = "FeaturedSpotlight",
			attribute = "Featured",
			rgb = { 255, 196, 64 },
			fillTransparency = 0.85,
		},
	},

	-- The "View" prompt on every display car. The shop UI listens for it (ProximityPromptService
	-- .PromptTriggered on the client) and reads its attributes.
	prompt = {
		name = "ViewPrompt",
		actionText = "View",
		holdSeconds = 0, -- a tap opens the shop
		maxDistance = 14, -- studs: about half a pad's length from its nose or tail
		-- Attribute names on the prompt (and on the display car model).
		vehicleIdAttribute = "VehicleId", -- dealership cars: the vehicle id
		trimAttribute = "Trim", -- dealership and used-lot cars: the trim on show
		slotAttribute = "Slot", -- used-lot cars: the day's slot number (1..Config/UsedLot.slots)
	},

	-- Tags and attributes on the platforms MapBuilder builds (Workspace.Map.Generated.Dealership / .UsedLot).
	pads = {
		dealershipTag = "DealershipPad", -- attributes BrandId, Index
		usedLotTag = "UsedLotPad", -- attribute Index
		brandAttribute = "BrandId",
		indexAttribute = "Index",
	},

	-- Test drives: a temporary car (attribute TestDrive = true, Config/Garage.testDriveAttribute) that never
	-- earns and never takes a garage slot.
	testDrive = {
		seconds = 120, -- PLAN.md Phase 4: 2-minute test drives
		cooldownSeconds = 30, -- after one ends, before the next may start
		-- When it ends the player is stood at the Dealership location (Config/MapLayout), this far above it so
		-- they drop onto the ground rather than into it.
		returnHeight = 4,
		endOnExit = true, -- getting out of the car ends the test drive at once
		-- Studs: a test drive starts only when the player stands this close to that car's display car (the View
		-- prompt reaches 14, so this leaves room to step back while the shop is open).
		maxStartDistance = 40,
	},

	-- EconomyService reasons (Roblox economy analytics item SKUs).
	reasons = {
		buy = "dealership",
		upgrade = "upgrade",
		refund = "refund", -- money given back when a purchase fails after the charge
		dev = "dev", -- DevSetCash (Studio only)
	},

	-- What the player is told (toasts in the shop). Plain words.
	messages = {
		notLoaded = "Your garage is still loading. Try again in a moment.",
		unknownVehicle = "That car isn't for sale here.",
		notDrivable = "That car isn't for sale.",
		unknownTrim = "That version of the car doesn't exist.",
		notForSale = "That version isn't sold at the dealership.",
		upgradeTrim = "That's an upgrade. Buy the car first, then upgrade it.",
		noRoom = "Your garage is full. Sell a car to make room.",
		noCash = "You need %s more for that.", -- the amount short, e.g. "$1,200"
		buyFailed = "Something went wrong, so you weren't charged. Try again in a moment.",
		bought = "You bought the %s! It's waiting at the spawn pad.", -- vehicle name
		boughtInGarage = "You bought the %s! Bring it out from the Garage app.",
		notOwned = "That car isn't in your garage.",
		notUpgrade = "That isn't an upgrade.",
		wrongBase = "This upgrade is for the %s.", -- the trim it upgrades, e.g. "Arc Performance"
		upgradeFailed = "Couldn't upgrade your car, so you weren't charged. Try again in a moment.",
		upgraded = "Your car is now the %s!", -- the new trim's name
		testDriveStarted = "Test drive: you have %s. Enjoy!", -- e.g. "2 minutes"
		testDriveEnded = "Test drive over. Welcome back!",
		testDriveBusy = "You're already on a test drive.",
		testDriveCooldown = "Your next test drive is ready in %d seconds.",
		testDriveFailed = "Couldn't start the test drive. Try again in a moment.",
		testDriveTooFar = "Walk up to the car at the dealership to test drive it.",
		noCharacter = "Wait until you've respawned, then try again.",
		minute = "minute",
		minutes = "minutes",
		seconds = "seconds",
		devOnly = "That only works in Studio.",
		devCashSet = "Cash set to %s.",
		devCashFailed = "Couldn't set cash to %s (it's %s).", -- wanted, actual
	},
}

return Dealership
