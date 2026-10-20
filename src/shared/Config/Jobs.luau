--!strict
-- Jobs (PLAN.md §4, Phases 6 and 8; docs/phase-6-contracts.md "Config", docs/phase-8-contracts.md "Jobs"):
-- which classes can do each job, the pay formula inputs, XP and levels, time limits, arrival rules,
-- smooth-driving tips, offers, the freight license and what players read. Read by Services/JobService (and its
-- Rideshare, Delivery, Towing and Freight modules), HitchService (the license), the phone's Jobs app and the HUD.
-- Pure data plus a few derived numbers: no Roblox services.
--
-- Pay calibration (PLAN.md §4 targets, Config/Economy.activities: rideshare $1,000/min, XL $1,250, delivery
-- $1,000, +20 % in a bonus class, towing $1,600, freight $3,000). A mid-skill player at job level 1 spends a
-- whole job cycle like this:
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
--   towing pay = basePay + tow studs x payPerStud + approach studs x approachPayPerStud (no tips; Phase 8,
--     $1,600/min = $26.67/s). A tow cycle: the drive from where the car is to the breakdown (the approach,
--     measured by road at the accept, paid up to approachMaxStuds) at REFERENCE_MPH; COUPLE_SECONDS_TOW (20 s:
--     slowing, reversing up to the car, lining up the hitch, coupling); the tow to the County Tow Yard at TOW_MPH
--     (25 mph: a car in tow corners and brakes gently, and the tow truck is no sports car); DECOUPLE_SECONDS_TOW
--     (10 s) at the drop; BETWEEN_SECONDS:
--       basePay            = rate x (couple + decouple + between) = 26.67 x (20 + 10 + 15)              ~= $1,200
--       payPerStud         = rate / 39.9 studs/s (25 mph)                                             ~= $0.668 a stud
--       approachPayPerStud = rate / 47.9 studs/s (30 mph)                                             ~= $0.557 a stud
--     A breakdown downtown, 2,800 studs of road from the yard both ways: $1,200 + $1,559 + $1,870 = $4,629 over
--     45 + 58 + 70 = 174 s, $1,600/min. Both legs are paid by the stud, so near and far breakdowns earn the same
--     rate; driving off before accepting only adds an unpaid drive back.
--   freight pay = basePay + haul studs x (payPerStud, or longHaulPayPerStud on a long haul) + approach studs x
--     approachPayPerStud ($3,000/min = $50/s, with a semi and the freight license). A freight cycle: the bobtail
--     drive to the trailer (the approach; in chained play it is often nothing, the next trailer waits at the depot
--     the last one was dropped at) at FREIGHT_MPH; COUPLE_SECONDS_FREIGHT (30 s: backing under the trailer,
--     lining up the kingpin, coupling); the haul at FREIGHT_MPH (35 mph: short runs use the Plant's works roads,
--     arterials and ramps, and a loaded semi gains speed slowly) or, round the County Loop, at LONG_HAUL_MPH
--     (45 mph: most of a long haul is 70 mph highway, held back by the trailer's speed cap and the legs to and
--     from the loop); DECOUPLE_SECONDS_FREIGHT (15 s); BETWEEN_SECONDS:
--       basePay             = rate x (couple + decouple + between) = 50 x (30 + 15 + 15)               = $3,000
--       payPerStud          = rate / 55.9 studs/s (35 mph)                                            ~= $0.895 a stud
--       longHaulPayPerStud  = rate / 71.9 studs/s (45 mph)                                            ~= $0.696 a stud
--       approachPayPerStud  = payPerStud (a bobtail semi on the same roads)
--     A short run from the Plant to the Loop Stop (~2,500 studs) pays ~$5,240 over ~105 s; a long haul round the
--     loop (~20,000 studs) ~$16,900 over ~340 s: both ~$3,000/min, the long haul the biggest single payout.
--   The freight license (freightLicense) needs level FREIGHT_LICENSE_LEVEL (3, 1,500 XP) in delivery or towing:
--     ~25 delivery routes or ~19 tows, about an hour of jobs. That is well before a mid-skill player can afford
--     the $240,000 Hauler (§4: semi at 4-5 h), so the gate never holds a player back who earned the truck, but it
--     does make freight the step after the other jobs (and stops cash from codes or a lucky start skipping them).
--     The license costs Economy.freightLicensePrice ($25,000) on top, the §4 sink.
-- Job levels multiply pay on top (up to +25 % at level 5): the §4 rates are what a level-1 player measures, and
-- levels are the reward for sticking with a job. Dev/JobTests.rate(type, minutes) measures the real $/min.

local Economy = require(script.Parent.Economy)
local Units = require(script.Parent.Parent.Util.Units)

export type JobType = "rideshare" | "delivery" | "towing" | "freight"

-- A trailer freight offers can hitch: a ServerStorage.TrailerModels model and what it carries (the offer's
-- title).
export type TrailerChoice = { model: string, cargo: string }

-- A job license (freightLicense): bought with Net BuyLicense once the player has `xpRequired` XP in any of
-- `jobTypes`, for `price`.
export type License = {
	id: string, -- PlayerData.jobs.licenses key
	displayName: string,
	xpRequired: number, -- XP in any one of jobTypes
	level: number, -- the job level that XP is (for "reach level 3")
	jobTypes: { string }, -- the job types whose XP counts
	price: number, -- $
}

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
	-- Towing and freight (Phase 8).
	requiresFeature: string?, -- a Config/Vehicles feature the car needs as well as its class (towHitch, kingpin)
	license: string?, -- a Jobs.licenses id the player must hold
	approachPayPerStud: number?, -- $ per stud of the leg from the car to the job's first stop (measured at accept)
	approachMaxStuds: number?, -- the most of that leg that is paid
	breakdownClasses: { string }?, -- towing: classes of the broken-down cars
	breakdownCandidates: number?, -- towing: offers pick among this many free breakdown spots nearest the car
	longHaulPayPerStud: number?, -- freight: $ per stud of a long haul round the County Loop
	waypointRadius: number?, -- studs from a waypoint stop that count as passing it (at any speed)
	loopWaypointDegrees: number?, -- freight: long hauls have a waypoint at least every this many degrees of loop
	trailers: { TrailerChoice }?, -- freight: the trailers offers pick from
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
-- Towing and freight (Phase 8; see the header).
local TOW_MPH = 25 -- with a car in tow
local COUPLE_SECONDS_TOW = 20
local DECOUPLE_SECONDS_TOW = 10
local TOW_APPROACH_STUDS = 2800 -- an average drive to the breakdown (XP reference)
local TOW_STUDS = 2800 -- an average tow to the yard (XP reference)
local FREIGHT_MPH = 35 -- a loaded semi on a short run, and a bobtail one on the way to its trailer
local LONG_HAUL_MPH = 45 -- a loaded semi on a long haul round the County Loop
local COUPLE_SECONDS_FREIGHT = 30
local DECOUPLE_SECONDS_FREIGHT = 15
local FREIGHT_RUN_STUDS = 3000 -- an average short run (XP reference; long hauls earn up to xpScale.max)
local FREIGHT_LICENSE_LEVEL = 3 -- the delivery or towing level the freight license needs
-- Time limits: the whole route at TIME_LIMIT_MPH (half the reference pace), plus a fixed grace.
local TIME_LIMIT_MPH = 15

local referenceSpeed = Units.mphToStuds(REFERENCE_MPH) -- studs/s
local rideshareRate = Economy.activities.rideshare / SECONDS_PER_MINUTE -- $/s
local deliveryRate = Economy.activities.delivery / SECONDS_PER_MINUTE
local towingRate = Economy.activities.towing / SECONDS_PER_MINUTE
local freightRate = Economy.activities.freight / SECONDS_PER_MINUTE
local timeLimitPerStud = 1 / Units.mphToStuds(TIME_LIMIT_MPH)

-- The pickup leg is paid by the stud (Rideshare.start measures it), so it isn't in the fixed seconds.
local rideshareFixedSeconds = STOP_SECONDS * RIDESHARE_STOPS + BETWEEN_SECONDS
local deliveryFixedSeconds = TO_DEPOT_STUDS / referenceSpeed + LOAD_SECONDS_TOTAL + BETWEEN_SECONDS
-- Towing and freight pay both legs by the stud, so only the hitching and the time between jobs are fixed.
local towingFixedSeconds = COUPLE_SECONDS_TOW + DECOUPLE_SECONDS_TOW + BETWEEN_SECONDS
local freightFixedSeconds = COUPLE_SECONDS_FREIGHT + DECOUPLE_SECONDS_FREIGHT + BETWEEN_SECONDS
local freightPayPerStud = freightRate / Units.mphToStuds(FREIGHT_MPH)

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
-- Towing and freight use the same thresholds, so "level 3" means the same XP in every job the freight license
-- counts (tests/FreightJobs.spec checks it).
local TOWING_LEVELS: { Level } = {
	{ xp = 0, payMultiplier = 1, unlocks = {} },
	{ xp = 500, payMultiplier = 1.05, unlocks = {} },
	{ xp = 1500, payMultiplier = 1.1, unlocks = { "extraOffer" } },
	{ xp = 3500, payMultiplier = 1.15, unlocks = {} },
	{ xp = 7000, payMultiplier = 1.25, unlocks = {} },
}
local FREIGHT_LEVELS: { Level } = {
	{ xp = 0, payMultiplier = 1, unlocks = {} },
	{ xp = 500, payMultiplier = 1.05, unlocks = {} },
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

local towing: JobDef = {
	id = "towing",
	displayName = "Towing",
	classes = { "pickup", "service" },
	requiresFeature = "towHitch", -- the service class also has trucks without one (the pod)
	basePay = towingRate * towingFixedSeconds,
	payPerStud = towingRate / Units.mphToStuds(TOW_MPH),
	approachPayPerStud = towingRate / referenceSpeed,
	-- Farther than the breakdowns farthest from the yard (Riverside's west edge is ~6,000 studs of road away):
	-- every leg the offers can make is paid; the cap only stops a leg driven to farm it.
	approachMaxStuds = 7000,
	xp = 80,
	cooldownSec = 30,
	timeLimitPerStud = timeLimitPerStud,
	-- Only the drop uses it (coupling happens at the anchored car): the truck and its tow within this of the tow
	-- drop. Generous: HitchService only uncouples inside a yard or depot footprint anyway, so the radius only has to
	-- tell the right yard from somewhere else.
	arriveRadius = 80,
	stillSpeedMph = 5,
	timeGraceSec = 120, -- the time limit's pace has no room for lining up the hitch
	xpReferenceStuds = TOW_APPROACH_STUDS + TOW_STUDS,
	levels = TOWING_LEVELS,
	depotJobType = "towing", -- the tow yard's JobDepot: the drop when the map has no TowDrop spots
	breakdownClasses = { "economy", "sedan", "minivan", "suv", "sports", "muscle", "luxury", "van" },
	breakdownCandidates = 8,
}

local freight: JobDef = {
	id = "freight",
	displayName = "Freight",
	classes = { "heavy" },
	requiresFeature = "kingpin",
	license = "freight",
	basePay = freightRate * freightFixedSeconds,
	payPerStud = freightPayPerStud,
	approachPayPerStud = freightPayPerStud,
	approachMaxStuds = 7000,
	longHaulPayPerStud = freightRate / Units.mphToStuds(LONG_HAUL_MPH),
	xp = 120,
	cooldownSec = 45,
	timeLimitPerStud = timeLimitPerStud,
	-- The decouple stop: a depot footprint is 80 x 36 studs and a semi with its trailer ~65 long, so the truck or
	-- the trailer within this of the depot. Depots are thousands of studs apart: no wrong depot is this close.
	arriveRadius = 120,
	stillSpeedMph = 5,
	timeGraceSec = 150,
	xpReferenceStuds = FREIGHT_RUN_STUDS,
	levels = FREIGHT_LEVELS,
	depotJobType = "freight",
	-- Long hauls pass waypoints on the loop at speed: a 70 mph semi covers ~28 studs between two checks
	-- (checkInterval), and a 4-lane highway's outer lane is ~18 studs off its centre line.
	waypointRadius = 70,
	-- At most a quarter of the loop between waypoints: the fastest way between two points a quarter apart is the
	-- loop itself (6,500 studs at 70 mph beat ~6,800 through town at 45), so the route really goes round.
	loopWaypointDegrees = 90,
	trailers = {
		{ model = "box_trailer", cargo = "Box freight" },
		{ model = "flatbed_trailer", cargo = "Flatbed load" },
		{ model = "tanker_trailer", cargo = "Tanker" },
	},
}

-- The freight license (docs/phase-8-contracts.md "Licenses"; the header has the reasoning). HitchService's
-- BuyLicense reads xpRequired and price; JobService's offers say how to get it.
local freightLicense: License = {
	id = "freight",
	displayName = "Freight license",
	xpRequired = TOWING_LEVELS[FREIGHT_LICENSE_LEVEL].xp,
	level = FREIGHT_LICENSE_LEVEL,
	jobTypes = { "delivery", "towing" },
	price = Economy.freightLicensePrice,
}

local ORDER: { string } = { "rideshare", "delivery", "towing", "freight" }

local Jobs = {
	-- Every job type, by id, and the order the phone lists them in.
	types = {
		rideshare = rideshare,
		delivery = delivery,
		towing = towing,
		freight = freight,
	} :: { [string]: JobDef }, -- keyed by JobType
	order = ORDER,

	-- Levels per job type (also on each JobDef as `levels`). Level n is levels[type][n].
	levels = {
		rideshare = RIDESHARE_LEVELS,
		delivery = DELIVERY_LEVELS,
		towing = TOWING_LEVELS,
		freight = FREIGHT_LEVELS,
	} :: { [string]: { Level } }, -- keyed by JobType

	-- Job licenses by id (JobDef.license), and the freight one by name (the contract's freightLicense).
	licenses = {
		freight = freightLicense,
	} :: { [string]: License },
	freightLicense = freightLicense,
	-- What a JobDef.requiresFeature is called in "it has no tow hitch".
	featureNames = {
		towHitch = "tow hitch",
		kingpin = "fifth wheel",
	} :: { [string]: string },

	-- The things towing and freight jobs put in the world or take for themselves: the broken-down car and the
	-- trailer. (The hitch's own names, Towed, TowingModel and Towing, are Config/Trailers'.)
	props = {
		folder = "JobProps", -- Workspace.JobProps holds the broken-down cars while their job runs
		jobAttribute = "JobId", -- the job a prop belongs to
		-- The UserId of the player whose job it is (only they should hitch it). Not OwnerUserId: that marks a
		-- player's own car (VehicleService), and a prop is nobody's car.
		ownerAttribute = "JobOwnerUserId",
		-- Seconds a delivered car or trailer stays where it was dropped before it goes (so it doesn't vanish
		-- under the player's eyes). A failed or cancelled job's prop goes at once: it may be in the road. A
		-- depot's trailer that goes is replaced on its spot by HitchService.
		despawnDelaySec = 20,
		-- A broken-down car stands this fraction of its Breakdown spot's length behind the spot's centre: the back
		-- half holds the car, the front half the tow truck pulled in ahead of it.
		breakdownSetBack = 0.25,
	},
	-- What each unlock id means, for the phone.
	unlockNames = {
		longFares = "Long-distance fares",
		extraOffer = "One more job offer",
		extraStop = "Bigger routes (one more drop)",
	} :: { [string]: string },

	-- XP per job: def.xp x (paid length / def.xpReferenceStuds), kept within this range of def.xp.
	xpScale = { min = 0.5, max = 2 },

	-- Towing and freight pay the approach leg by the road route, but a truck already standing by its load (pulled
	-- in ahead of a broken-down car, facing on) gets a route that loops round the block. The paid approach is at
	-- most this many times the straight-line distance: a fair road detour on the county's grid (a right-angle
	-- corner is about 1.41x), never the loop the truck doesn't drive.
	approachDetourFactor = 1.6,

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
		towMph = TOW_MPH, -- towing: average speed with a car in tow (the approach is at referenceMph)
		coupleSecondsTow = COUPLE_SECONDS_TOW, -- towing: lining up and coupling at the breakdown
		decoupleSecondsTow = DECOUPLE_SECONDS_TOW, -- towing: at the tow drop
		towApproachStuds = TOW_APPROACH_STUDS, -- towing: an average drive to the breakdown
		towStuds = TOW_STUDS, -- towing: an average tow
		freightMph = FREIGHT_MPH, -- freight: short runs and the bobtail approach
		longHaulMph = LONG_HAUL_MPH, -- freight: long hauls round the loop
		coupleSecondsFreight = COUPLE_SECONDS_FREIGHT, -- freight: backing under the trailer and coupling
		decoupleSecondsFreight = DECOUPLE_SECONDS_FREIGHT, -- freight: at the destination depot
		freightRunStuds = FREIGHT_RUN_STUDS, -- freight: an average short run
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
		failDetached = "you uncoupled away from the drop-off.",
		failLoadGone = "the load is gone.",
		coupleFirst = "Line up the hitch and couple first.",
		uncoupleHere = "Uncouple here to finish the job.",
		-- License gates (JobDef.license): the job name, then the level, the job names ("Delivery or Towing") and
		-- the price; or just the price once the player has the XP.
		needLicenseXp = "%s jobs need a license: reach level %d in %s, then buy it for %s.",
		needLicense = "%s jobs need a license. Buy it for %s.",
		jobNameSeparator = " or ", -- between the job names in needLicenseXp
		needsFeature = "Your car can't do %s jobs: it has no %s.", -- job name, feature name
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
