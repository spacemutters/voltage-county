--!strict
-- Jobs (PLAN.md §4 and Phase 6; docs/phase-6-contracts.md "Config"): which classes can do each job, the pay
-- formula inputs, XP and levels, time limits, arrival rules, smooth-driving tips, offers and what players read.
-- Read by Services/JobService (and its Rideshare and Delivery modules), the phone's Jobs app and the HUD.
-- Pure data plus a few derived numbers: no Roblox services.
--
-- Pay calibration (PLAN.md §4 targets, Config/Economy.activities: rideshare $1,000/min, XL $1,250, delivery
-- $1,000, +20 % in a bonus class). A mid-skill player at job level 1 spends a whole job cycle like this:
--   * driving at about REFERENCE_MPH (30 mph) on average while moving: Cedar Bend's streets are 30-35 mph and
--     its arterials 35-45, less the corners and lights. At Config/World's scale that is about 47.9 studs/s.
--   * rideshare: a pickup leg (PICKUP_STUDS, 900 on average: offers come from the hotspots nearest the car,
--     downtown's are 500-1,000 studs apart), about STOP_SECONDS (8 s) at each of the 2 stops (slowing down,
--     stopping, the passenger getting in or out), about BETWEEN_SECONDS (15 s) between jobs (reading offers,
--     accepting), and the ride itself (RIDE_STUDS, 2,500 on average) at the reference speed.
--   * delivery: an unpaid leg to the depot (TO_DEPOT_STUDS, 2,700: in chained play every job starts with the
--     drive back from the last Riverside drop, measured at ~2,700 studs over 600 real routes; see Delivery.luau),
--     LOAD_SECONDS_TOTAL (10 s: stop, load, leave), DROP_SECONDS (7 s) at every drop, BETWEEN_SECONDS, and the
--     paid route from the depot through the drops at the reference speed. A first job started downtown (a
--     ~1,000-stud leg) pays ~20 % over the rate.
-- Every second of that cycle should earn rate = target / 60 ($16.67/s at $1,000/min). So the pay formula is
-- linear in the time it costs:
--   rideshare fare = basePay + paid studs x payPerStud, both divided by (1 + the average tip share), so the
--     fare plus a mid-skill tip lands on the target whatever the ride's length. The paid studs are the ride plus
--     the pickup leg as measured from where the car is when the fare is accepted (capped at pickupMaxStuds), so a
--     fare picked up where the car already stands pays no pickup time it never drove, and a leg driven before
--     accepting (while drive-to-earn pays) is never paid twice:
--       basePay    = rate x (2 stops + between jobs) / (1 + AVERAGE_TIP_SHARE)
--                  = 16.67 x (16 + 15) / 1.10                                           ~= $470
--       payPerStud = rate / 47.9 studs/s / 1.10                                         ~= $0.316 a stud
--     An average fare (900-stud pickup + 2,500-stud ride) pays about $1,545 + a ~$155 tip over a ~102 s cycle:
--     ~$1,000/min. Rides are at least routeBand.min (1,800) studs, so the fixed part never dominates a fare.
--     XL fares (xlClasses, or any trim with xlMinSeats or more seats) multiply the whole fare by xlMultiplier =
--     rideshareXL / rideshare = 1.25, so XL lands on $1,250/min.
--     AVERAGE_TIP_SHARE (0.10) is two thirds of tipMax (0.15): a mid-skill driver brakes hard about once a ride.
--   delivery pay = basePay + route studs x payPerStud + drops x payPerDrop (no tips):
--       basePay    = rate x (depot leg time + load + between jobs) = 16.67 x (56.4 + 10 + 15) ~= $1,356
--       payPerStud = rate / 47.9 studs/s                                                  ~= $0.348 a stud
--       payPerDrop = rate x DROP_SECONDS                                                  ~= $117
--     Bonus classes (van, suv, pickup) get more stops and x bonusMultiplier (1.2) on the whole pay, so they land
--     on $1,200/min (Economy.activities.deliveryVehicleBonus).
-- Job levels multiply pay on top (up to +25 % at level 5): the §4 rates are what a level-1 player measures, and
-- levels are the reward for sticking with a job. Dev/JobTests.rate(type, minutes) measures the real $/min.

local Economy = require(script.Parent.Economy)
local Units = require(script.Parent.Parent.Util.Units)

export type JobType = "rideshare" | "delivery" -- towing and freight arrive in Phase 8

-- One job level: reached at `xp` total XP in that job type.
export type Level = {
	xp: number,
	payMultiplier: number,
	unlocks: { string }, -- unlock ids (see unlockNames)
}

export type Range = { min: number, max: number }

export type JobDef = {
	id: JobType,
	displayName: string,
	classes: { string }, -- eligible Config/Classes ids
	xlClasses: { string }?, -- rideshare: classes that get XL fares
	bonusClasses: { string }?, -- delivery: classes that get the bonus and more stops
	basePay: number,
	payPerStud: number, -- along the road route
	xp: number, -- per completed job of xpReferenceStuds paid length (scaled by length, Jobs.xpScale)
	cooldownSec: number, -- after cancelling or failing
	timeLimitPerStud: number, -- seconds allowed per stud of route, plus timeGraceSec
	arriveRadius: number, -- studs from a stop (or its road approach point) that counts as arrived
	stillSpeedMph: number, -- nearly stopped to pick up / drop off
	-- The rest is this framework's choice (documented beside each value).
	timeGraceSec: number, -- fixed seconds added to every time limit
	xpReferenceStuds: number, -- paid length that earns exactly `xp`
	levels: { Level }, -- the same table as Jobs.levels[id]
	-- Rideshare.
	xlMinSeats: number?, -- a trim with at least this many seats gets XL fares in any eligible class
	xlMultiplier: number?, -- XL fares: the whole fare times this
	pickupDwell: number?, -- seconds nearly still at the pickup while the passenger gets in
	dropoffDwell: number?, -- seconds nearly still at the drop-off while they get out
	pickupCandidates: number?, -- offers pick their pickup among this many hotspots nearest the car
	pickupMaxStuds: number?, -- and never one farther than this by road; the pickup leg is paid up to this
	routeBand: Range?, -- ride length (studs of road) of a normal fare
	longRouteBand: Range?, -- ride length of a "longFares" fare (unlocked by level)
	dropoffExcludeTags: { string }?, -- MapLayout tags never used as drop-offs (volumes, drag-strip gates)
	-- Delivery.
	payPerDrop: number?, -- $ per drop
	bonusMultiplier: number?, -- bonus classes: the whole pay times this
	depotJobType: string?, -- JobDepot `jobType` attribute this job loads at
	loadSeconds: number?, -- seconds nearly still at the depot to load
	dropSeconds: number?, -- seconds nearly still at each drop
	stops: Range?, -- drops on a normal route
	bonusStops: Range?, -- drops in a bonus class
}

local SECONDS_PER_MINUTE = 60

-- Calibration inputs (see the header).
local REFERENCE_MPH = 30
local PICKUP_STUDS = 900
local RIDE_STUDS = 2500
local STOP_SECONDS = 8
local RIDESHARE_STOPS = 2
local BETWEEN_SECONDS = 15
local TIP_MAX = 0.15
local AVERAGE_TIP_SHARE = TIP_MAX * 2 / 3
local TO_DEPOT_STUDS = 2700
local LOAD_SECONDS_TOTAL = 10
local DROP_SECONDS = 7
local DELIVERY_ROUTE_STUDS = 2800 -- depot through the drops, an average route (XP reference)
-- Time limits: the whole route at TIME_LIMIT_MPH (half the reference pace), plus a fixed grace.
local TIME_LIMIT_MPH = 15

local referenceSpeed = Units.mphToStuds(REFERENCE_MPH) -- studs/s
local rideshareRate = Economy.activities.rideshare / SECONDS_PER_MINUTE -- $/s
local deliveryRate = Economy.activities.delivery / SECONDS_PER_MINUTE
local timeLimitPerStud = 1 / Units.mphToStuds(TIME_LIMIT_MPH)

-- The pickup leg is paid by the stud (Rideshare.start measures it), so it isn't in the fixed seconds.
local rideshareFixedSeconds = STOP_SECONDS * RIDESHARE_STOPS + BETWEEN_SECONDS
local deliveryFixedSeconds = TO_DEPOT_STUDS / referenceSpeed + LOAD_SECONDS_TOTAL + BETWEEN_SECONDS

-- Levels: the same ladder for both job types for now. "extraOffer" lists one more offer of that type;
-- "longFares" (rideshare) adds cross-county fares; "extraStop" (delivery) adds a drop to every route.
local RIDESHARE_LEVELS: { Level } = {
	{ xp = 0, payMultiplier = 1, unlocks = {} },
	{ xp = 500, payMultiplier = 1.05, unlocks = { "longFares" } },
	{ xp = 1500, payMultiplier = 1.1, unlocks = { "extraOffer" } },
	{ xp = 3500, payMultiplier = 1.15, unlocks = {} },
	{ xp = 7000, payMultiplier = 1.25, unlocks = {} },
}
local DELIVERY_LEVELS: { Level } = {
	{ xp = 0, payMultiplier = 1, unlocks = {} },
	{ xp = 500, payMultiplier = 1.05, unlocks = { "extraStop" } },
	{ xp = 1500, payMultiplier = 1.1, unlocks = { "extraOffer" } },
	{ xp = 3500, payMultiplier = 1.15, unlocks = {} },
	{ xp = 7000, payMultiplier = 1.25, unlocks = {} },
}

local rideshare: JobDef = {
	id = "rideshare",
	displayName = "Rideshare",
	classes = { "economy", "sedan", "minivan", "suv", "luxury", "sports", "muscle" },
	xlClasses = { "suv", "minivan" },
	basePay = rideshareRate * rideshareFixedSeconds / (1 + AVERAGE_TIP_SHARE),
	payPerStud = rideshareRate / referenceSpeed / (1 + AVERAGE_TIP_SHARE),
	xp = 50,
	cooldownSec = 20,
	timeLimitPerStud = timeLimitPerStud,
	arriveRadius = 35, -- a 4-lane arterial's outer lane is 18 studs from its centre line
	stillSpeedMph = 5,
	timeGraceSec = 45,
	xpReferenceStuds = PICKUP_STUDS + RIDE_STUDS, -- an average fare's paid length (pickup leg and ride)
	levels = RIDESHARE_LEVELS,
	xlMinSeats = 6,
	xlMultiplier = Economy.activities.rideshareXL / Economy.activities.rideshare,
	pickupDwell = 1,
	dropoffDwell = 0.5,
	pickupCandidates = 4,
	pickupMaxStuds = 2500, -- also the most of a pickup leg that is paid
	-- At least 1,800 studs (~38 s at the reference pace): with shorter rides the fixed part of the fare (stops and
	-- time between jobs) is most of the pay, which a player who skips that time could farm.
	routeBand = { min = 1800, max = 4500 },
	longRouteBand = { min = 3500, max = 8000 },
	dropoffExcludeTags = { "FlightZone", "NoFlyZone", "DragStripGate", "SpawnPad", "TruckCharger" },
}

local delivery: JobDef = {
	id = "delivery",
	displayName = "Delivery",
	classes = { "van", "suv", "pickup", "minivan", "sedan", "economy" },
	bonusClasses = Economy.deliveryBonusClasses, -- van, suv, pickup
	basePay = deliveryRate * deliveryFixedSeconds,
	payPerStud = deliveryRate / referenceSpeed,
	xp = 60,
	cooldownSec = 30,
	timeLimitPerStud = timeLimitPerStud,
	arriveRadius = 35, -- a house plot is 50 x 40 studs; the road approach point covers the rest
	stillSpeedMph = 5,
	timeGraceSec = 60,
	xpReferenceStuds = DELIVERY_ROUTE_STUDS,
	levels = DELIVERY_LEVELS,
	payPerDrop = deliveryRate * DROP_SECONDS,
	bonusMultiplier = 1 + Economy.activities.deliveryVehicleBonus,
	depotJobType = "delivery",
	loadSeconds = 3,
	dropSeconds = 1,
	stops = { min = 3, max = 4 },
	bonusStops = { min = 4, max = 6 },
}

local ORDER: { string } = { "rideshare", "delivery" }

local Jobs = {
	-- Every job type, by id, and the order the phone lists them in.
	types = {
		rideshare = rideshare,
		delivery = delivery,
	} :: { [string]: JobDef }, -- keyed by JobType
	order = ORDER,

	-- Levels per job type (also on each JobDef as `levels`). Level n is levels[type][n].
	levels = {
		rideshare = RIDESHARE_LEVELS,
		delivery = DELIVERY_LEVELS,
	} :: { [string]: { Level } }, -- keyed by JobType
	-- What each unlock id means, for the phone.
	unlockNames = {
		longFares = "Long-distance fares",
		extraOffer = "One more job offer",
		extraStop = "Bigger routes (one more drop)",
	} :: { [string]: string },

	-- XP per job: def.xp x (paid length / def.xpReferenceStuds), kept within this range of def.xp.
	xpScale = { min = 0.5, max = 2 },

	-- The cycle the pay formulas are calibrated on (see the header), for tests/Jobs.spec and Dev/JobTests.rate,
	-- which measure against these rather than against the pay itself.
	calibration = {
		referenceMph = REFERENCE_MPH, -- average speed while moving
		pickupStuds = PICKUP_STUDS, -- rideshare: an average pickup leg (paid by the stud)
		rideStuds = RIDE_STUDS, -- rideshare: an average ride
		stopSeconds = STOP_SECONDS, -- rideshare: at each of its stops
		rideshareStops = RIDESHARE_STOPS,
		betweenSeconds = BETWEEN_SECONDS, -- between one job ending and the next accept
		toDepotStuds = TO_DEPOT_STUDS, -- delivery: the unpaid leg to the depot (chained play)
		loadSeconds = LOAD_SECONDS_TOTAL, -- delivery: stopping, loading and leaving the depot
		dropSeconds = DROP_SECONDS, -- delivery: at each drop
		averageTipShare = AVERAGE_TIP_SHARE,
	},

	-- Tips (rideshare): up to tipMax of the fare (base + distance + class) for a smooth ride. Each hard brake
	-- takes hardBrakePenalty of the tip away and each crash crashPenalty, never below no tip.
	tipMax = TIP_MAX,
	averageTipShare = AVERAGE_TIP_SHARE, -- what the calibration assumes a mid-skill driver keeps
	smoothness = {
		-- Speed is measured from server-observed positions over `speedWindow` seconds (one sample's view of a
		-- client-driven car wobbles; a window smooths it).
		speedWindow = 0.5,
		-- Hard braking: losing speed at this rate or faster over `brakeWindow` seconds, i.e. 15 mph lost within a
		-- second. Full brakes are 19-31 mph/s (Config/Driving brakes) and keyboard and touch brakes are on/off, so
		-- the window is a whole second: a short press to slow for a corner never counts, holding the brakes on hard
		-- (an emergency stop) does. An easy stop (the AutoDriver plans 0.5 g) is about 11 mph/s.
		hardBrakeMphPerSec = 15,
		brakeWindow = 1,
		-- A crash: losing at least this many mph within `crashWindow` seconds (faster than any brake can).
		crashSpeedLossMph = 20,
		crashWindow = 0.5,
		-- Losses that start below this speed don't count (parking, creeping in traffic).
		minSpeedMph = 8,
		-- Braking within this many times the job's arriveRadius of the current stop never counts as hard: every
		-- ride has to stop there. Crashes still count.
		stopApproachFactor = 3,
		-- Events closer together than this are one event (one long stop is one hard brake).
		eventCooldownSec = 1.5,
		hardBrakePenalty = 0.25,
		crashPenalty = 0.5,
	},

	-- Watching active jobs: one Heartbeat accumulator checks every active job this often (seconds), and samples
	-- the car's position for speed at the same rate.
	checkInterval = 0.25,
	-- Samples of each job car kept (enough for the longest window above at checkInterval, with room).
	historySeconds = 1.5,
	-- Failing: out of the job's car (not in its Driver seat) for this long.
	leaveCarSec = 45,
	-- JobAction "arrive" farther than this many times arriveRadius from the stop is a forged arrival: rejected
	-- and logged. Closer than that (but not arrived yet) is just answered with a hint.
	forgedArriveFactor = 3,

	-- Offers per player: perType of each eligible job type, made again every refreshSec and when the player
	-- asks (JobAction "refresh", at most once per minRefreshSec) or changes car.
	offers = {
		perType = 3,
		refreshSec = 60,
		minRefreshSec = 2,
	},

	-- EconomyService reason prefix: "job:rideshare", "job:delivery".
	reasonPrefix = "job:",

	-- What players read (Notify toasts and JobAction answers). %s are filled in as noted.
	messages = {
		accepted = "Job accepted: %s", -- the job title
		completed = "Job done! +%s", -- the pay, "$1,234"
		completedTip = "Job done! +%s (tip %s)", -- the pay, the tip
		levelUp = "%s level %d! Jobs now pay x%s.", -- job name, level, multiplier "1.05"
		cancelled = "Job cancelled. New %s jobs in %d seconds.", -- job name, cooldown
		failed = "Job failed: %s", -- the reason below
		failTimeout = "you ran out of time.",
		failLeftCar = "you left your car for too long.",
		failSwitchedCar = "you switched cars.",
		failCarGone = "your car is gone.",
		failError = "something went wrong. No cooldown this time.",
		pickedUp = "Passenger aboard. Drive smoothly for a better tip.",
		droppedOff = "Passenger dropped off.",
		notAtStop = "You're not at the stop yet.",
		slowDown = "Stop the car at the marker.",
		holdStill = "Hold still a moment...",
		noJob = "You don't have that job any more.",
		busy = "Finish or cancel your current job first.",
		noOffer = "That offer has gone. Pick another one.",
		noCar = "Get in your car to see jobs.",
		testDrive = "Test drives can't take jobs.",
		wrongClass = "Your car can't do %s jobs. These can: %s.", -- job name, class names
		cooldown = "New %s jobs in %d seconds.", -- job name, seconds
		cantStart = "That job couldn't start. Try another one.",
		loading = "Your progress is still loading. Try again in a moment.",
		devOnly = "That only works in Studio.",
		ok = "OK",
	},
	-- Toast kinds (Config/Gps toast.kindColors).
	notifyKinds = {
		good = "success",
		info = "info",
		bad = "warning",
	},
}

return Jobs
