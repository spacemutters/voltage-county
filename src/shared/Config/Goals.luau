--!strict
-- Goals (roast fixes 2026-10-24, docs/roast-2026-10-24.md point 8 "The first five minutes have no hook"): the
-- first-session path a new player is walked through, and three daily goals. Read by Services/GoalsService (the
-- rules, the counting and the pay), Services/SpawnFlowService (the first spawn), Controllers/GoalsController and
-- UI/Goals (the card and the list). Pure data plus two formatters: no Roblox services.
--
-- Rewards are cash only: no paid currency, nothing random. Calibration against Config/Economy (rideshare's target
-- is $1,000 a minute; a new Ohm Spark, $35,000, is about 30 minutes in): the path pays $5,500 in all, once ever,
-- about 5.5 minutes of rideshare (the $3,000 first-ride bonus is about twice the first fare it rides on, so the
-- first drop-off feels big without buying anyone a car), and a whole day of daily goals pays $4,000 to $7,500
-- (4 to 7.5 minutes of rideshare), a reason to come back that never skips the price ladder.

export type Counter = "job" | "testDrive" | "design" | "miles" | "charge" | "meet" | "earn" | "house"

-- What the card's main button does for a goal (Controllers/GoalsController):
--   startFare     accepts the nearest rideshare offer for the car the player sits in
--   testDrive     near the goal's car at the dealership: starts its test drive (Net StartTestDrive); else the GPS
--                 leads there (gpsTo)
--   openDesigner  opens the AI Car Designer (Controllers/DesignerController)
--   gps           the GPS leads to the goal's place (gpsTo)
export type Action = "startFare" | "testDrive" | "openDesigner" | "gps"

export type Goal = {
	id: string, -- unique across the path and every daily slot (Net ClaimGoal sends it; at most 40 characters)
	counter: Counter, -- the server event that moves it (Services/GoalsService header)
	-- How much of the counter finishes it: miles for "miles", whole $ for "earn", else a count.
	target: number,
	reward: number, -- whole $, paid once
	title: string, -- %s: the target as Goals.formatTarget writes it ("Drive %s" -> "Drive 3 miles")
	detail: string, -- one short line under the title
	jobType: string?, -- "job" goals: only this Config/Jobs type counts (nil: any job)
	vehicleId: string?, -- "testDrive" goals: only this car counts (nil: any car)
	action: Action?, -- the card's button (nil: none; the list opens on a tap)
	actionLabel: string?, -- the button's words for `action`
	shortLabel: string?, -- the same on the compact card's narrow button (nil: actionLabel)
	gpsTo: string?, -- a MapLayout location id: the GPS leads there while it is the path's current step, and the
	-- list's Go button does the same for a daily goal
	goLabel: string?, -- the button's words while the GPS is what it does (testDrive far from the car)
	paidText: string?, -- the notice when a path step pays (%s: the reward); nil: text.paid
}

local Goals = {
	-- The first-session path: a new player's first three steps, in this order on the card. Saves from before
	-- PlayerData schema 8 start with it done (Services/DataService/Migrations), so only new players see it.
	path = {
		goals = {
			{
				id = "firstFare",
				counter = "job",
				jobType = "rideshare",
				target = 1,
				reward = 3000,
				title = "Your first fare",
				detail = "Pick up a rider nearby",
				action = "startFare",
				actionLabel = "Start",
				paidText = "First-ride bonus! +%s",
			},
			{
				id = "testDriveArc",
				counter = "testDrive",
				vehicleId = "ohm_arc",
				target = 1,
				reward = 1000,
				title = "Test drive the Arc",
				detail = "The Ohm Arc, free for 2 minutes at Cedar Bend Motors",
				action = "testDrive",
				actionLabel = "Test drive",
				shortLabel = "Drive",
				gpsTo = "dealership",
				goLabel = "Go",
				paidText = "Test drive bonus! +%s",
			},
			{
				id = "designFreeCar",
				counter = "design",
				target = 1,
				reward = 1500,
				title = "Design your free car",
				detail = "Describe it and an AI builds it",
				action = "openDesigner",
				actionLabel = "Design",
				paidText = "Your first design! +%s",
			},
		} :: { Goal },
		-- Net ClaimGoal with this id skips the rest of the path for good (nothing more is paid for it).
		skipId = "path:skip",
		-- The first fare starts by itself (once a session) when the player sits in their own car with no job in
		-- this many seconds after the path's card first shows; after that it waits for a tap on Start.
		autoStartSeconds = 180,
		-- While the test-drive step is on the card, how often (seconds) the client looks whether the player is close
		-- enough to its car to start the drive (Config/Dealership testDrive.maxStartDistance).
		nearCheckSeconds = 0.5,
	},

	-- Daily goals: one goal from each slot a day, the same three for every player on a goals day. A goals day
	-- starts at resetHourUtc (08:00 UTC is midnight on the US west coast, after most evening play in the
	-- Americas), and each slot steps on to its next goal every day.
	daily = {
		resetHourUtc = 8,
		slots = {
			-- On the road.
			{
				{
					id = "drive3",
					counter = "miles",
					target = 3,
					reward = 1500,
					title = "Drive %s",
					detail = "Any car, any road",
				},
				{
					id = "charge1",
					counter = "charge",
					target = 1,
					reward = 1000,
					title = "Charge or refuel",
					detail = "Stop at any charger or fuel pump",
					action = "gps",
					actionLabel = "Go",
					gpsTo = "cb_charger_1",
				},
				{
					id = "drive8",
					counter = "miles",
					target = 8,
					reward = 3000,
					title = "Drive %s",
					detail = "The County Loop is quickest",
				},
				{
					id = "meet1",
					counter = "meet",
					target = 1,
					reward = 1000,
					title = "Park at a meet spot",
					detail = "Stop inside Lakeview Overlook",
					action = "gps",
					actionLabel = "Go",
					gpsTo = "lk_overlook",
				},
			},
			-- Work.
			{
				{
					id = "rides2",
					counter = "job",
					jobType = "rideshare",
					target = 2,
					reward = 2000,
					title = "Give %s rides",
					detail = "Jobs app, Rideshare",
				},
				{
					id = "jobs3",
					counter = "job",
					target = 3,
					reward = 2500,
					title = "Finish %s jobs",
					detail = "Any job counts",
				},
				{
					id = "deliveries2",
					counter = "job",
					jobType = "delivery",
					target = 2,
					reward = 2000,
					title = "Make %s deliveries",
					detail = "Jobs app, Delivery",
				},
			},
			-- Money and the town.
			{
				{
					id = "earn10k",
					counter = "earn",
					target = 10000,
					reward = 2000,
					title = "Earn %s",
					detail = "From driving, jobs and your fleet",
				},
				{
					id = "testDrive1",
					counter = "testDrive",
					target = 1,
					reward = 1000,
					title = "Test drive any car",
					detail = "At Cedar Bend Motors",
					action = "gps",
					actionLabel = "Go",
					gpsTo = "dealership",
				},
				{
					id = "house1",
					counter = "house",
					target = 1,
					reward = 1000,
					title = "Claim a house",
					detail = "Free plots in Riverside",
					action = "gps",
					actionLabel = "Go",
					gpsTo = "rv_cedar_ct_3",
				},
			},
		} :: { { Goal } },
		-- EconomyService reasons whose cash counts toward "earn" goals (exact, or starting with a prefix). Goal
		-- rewards, codes, purchases, sales and refunds never count.
		earnReasons = { "drive", "fleet", "hangout" },
		earnReasonPrefixes = { "job:" },
		-- Miles: the car is sampled this often while its owner has an unfinished miles goal; a step faster than
		-- maxMph (a jump) or across a server move doesn't count. Progress is saved at most this often while
		-- driving, at once when it reaches a goal, and when the player leaves.
		sampleSeconds = 1,
		maxMph = 260,
		milesCommitSeconds = 15,
	},

	-- The car attribute Services/EnergyService sets to true while a car charges or fuels ("charge" goals).
	chargingAttribute = "Charging",

	-- EconomyService reason for goal rewards (Roblox economy analytics item SKU).
	economyReason = "goal",

	-- The first spawn (Services/SpawnFlowService): a new player's starter car is put on the road near the used lot,
	-- facing down the street toward downtown's towers, with them in the driver's seat. Each spot is moved onto the
	-- nearest road (in its right-hand lane, laneOffset lanes right of the centre line); the first with no other
	-- car within clearRadius studs is used, and with none free the car stays on its spawn pad.
	firstSpawn = {
		-- Along the street in front of the used lot, mid-block (between the cross streets at x = 300 and 600), a car
		-- length and more apart.
		spots = {
			Vector3.new(410, 0, 300),
			Vector3.new(450, 0, 300),
			Vector3.new(490, 0, 300),
			Vector3.new(530, 0, 300),
		},
		lookToward = Vector3.new(0, 0, 0),
		laneOffset = 0.5, -- lanes (Config/World.laneWidth) right of the centre line: the right lane's middle
		maxSnap = 80, -- studs: a spot farther than this from a road is not used
		clearRadius = 14,
		-- How long the server waits for a joining player's data and character before giving up on the first spawn.
		waitSeconds = 20,
		-- The hook (roast point 8, "0:00 spawn already seated in the Spark while the Arc boost-hops over you"): once
		-- the player sits in their starter on the road, Services/SpawnFlowService sets `attribute` on the Player (the
		-- server clock), and Controllers/ArcFlyoverController flies a look-only copy of the dealership's display Arc
		-- over their car once: it takes off `behind` studs behind it, peaks `peakHeight` studs above the road and
		-- comes down `ahead` studs in front, `side` studs to the left (the other lane), then rolls on and fades. Never
		-- solid, never driven, never on the server; nothing happens if the display car hasn't streamed in.
		flyover = {
			attribute = "FirstSpawnFlyover",
			vehicleId = "ohm_arc",
			delaySeconds = 1.5, -- after the attribute, once the car and the camera have settled
			maxAgeSeconds = 20, -- an attribute older than this (the client joined late) plays nothing
			seconds = 2.4, -- the hop, take-off to touch-down
			behind = 60,
			ahead = 110,
			side = 6,
			peakHeight = 26,
			rollSeconds = 0.8, -- after touch-down it rolls on along the road, fading out
			rollSpeed = 70, -- studs a second
		},
	},

	-- The card and the list (UI/Goals), px at UI scale 1. The card sits clear of the HUD (Controllers/
	-- GoalsController.placeCard); every touch target is at least 44 px.
	card = {
		-- The eyebrow, the title and a wide button under them. 220 px fits between the cash column and the touch
		-- pedals on a 667-px-wide landscape phone.
		size = Vector2.new(220, 104),
		-- Where the tall card has no room (a small landscape phone driving on touch, where the phone button sits just
		-- above the speed panel): the words on the left, a short button on the right.
		compactSize = Vector2.new(220, 56),
		compactActionWidth = 76,
		compactPadding = 6,
		pillSize = Vector2.new(132, 44), -- the daily goals' small button when nothing is ready to collect
		gap = 10, -- from everything it keeps clear of
		padding = 10,
		actionHeight = 44,
		eyebrowTextSize = 12,
		titleTextSize = 15,
		minTextSize = 11, -- a title too long for the card shrinks to this before it is cut short
		barHeight = 4,
		cornerRadius = 14,
	},
	-- The list goes where a phone sheet goes (UI/Phone/Layout.sheet).
	sheet = {
		headerHeight = 56,
		closeSize = Vector2.new(72, 44),
		rowPadding = 12,
		barHeight = 6,
		goButtonWidth = 72,
		collectButtonWidth = 120,
	},

	-- What players read. %s are filled in as noted.
	text = {
		pathEyebrow = "Step %d of %d · %s bonus", -- step, steps, reward
		bonus = "%s bonus", -- reward, in the list
		stepNow = "Now · %s", -- the bonus line of the step being done
		stepDone = "Done · +%s", -- reward
		dailyEyebrow = "Daily goal done",
		dailyPill = "Goals %d/%d", -- collected, goals
		collect = "Collect %s", -- reward
		collectShort = "Collect", -- on the compact card (the reward is in its eyebrow then)
		pathEyebrowShort = "Step %d/%d · %s", -- the compact card's: step, steps, reward
		dailyEyebrowShort = "Goal done · %s", -- the compact card's: reward
		done = "Done",
		go = "Go",
		listTitle = "Goals",
		close = "Close",
		pathSection = "Getting started",
		dailySection = "Today",
		skip = "Skip these steps",
		-- Skipping ends the path for good, so the first tap asks.
		skipConfirm = "Skip for good? You'll lose the bonuses.",
		skipKeep = "Keep them",
		skipForGood = "Skip",
		resetsIn = "New goals in %s", -- a duration
		hoursMinutes = "%d h %d min",
		minutes = "%d min",
		progress = "%s / %s", -- progress, target
		miles = "%s miles",
		mile = "%s mile",
		-- Server answers and notices.
		paid = "Goal done! +%s", -- reward (a path step without its own paidText)
		ready = "Goal done: %s. Collect it on the card.", -- goal title
		claimed = "Collected %s!", -- reward
		alreadyClaimed = "You've already collected that.",
		notFinished = "Finish the goal first.",
		expired = "Those goals have reset. Here are today's.",
		unknown = "That goal isn't on your list.",
		skipped = "No problem. Your daily goals are on the card.",
		loading = "Your goals are still loading. Try again in a moment.",
		pathDone = "You're all set! Daily goals are on the card now.",
		-- The card's own messages (Controllers/GoalsController).
		noFare = "Get in your car to find a fare.",
		findingFare = "Finding a fare nearby...",
		goToCar = "Drive to the Ohm Arc at Cedar Bend Motors.",
		failed = "That didn't work. Please try again.",
	},
}

-- A goal's target as its title shows it: "3 miles", "$10,000", or the count.
function Goals.formatTarget(goal: Goal, formatCash: (amount: number) -> string): string
	if goal.counter == "miles" then
		local amount = string.format("%g", goal.target)
		return string.format(if goal.target == 1 then Goals.text.mile else Goals.text.miles, amount)
	elseif goal.counter == "earn" then
		return formatCash(goal.target)
	end
	return string.format("%d", goal.target)
end

-- A goal's title with its target filled in.
function Goals.titleOf(goal: Goal, formatCash: (amount: number) -> string): string
	if string.find(goal.title, "%s", 1, true) == nil then
		return goal.title
	end
	return string.format(goal.title, Goals.formatTarget(goal, formatCash))
end

return Goals
