--!strict
-- Studio-only freight and towing tests (PLAN.md Phase 8 acceptance; docs/phase-8-contracts.md "Tests"). Each one
-- drives with Dev/AutoDriver using only what a player's client can do: Net TrailerAction (couple, decouple),
-- BuyLicense, JobAction, the JobUpdate the server sends back and the car's position. HitchService decides every
-- coupling and JobService every job step; the tests measure what they did:
--   loop(opts)             spawns the semi (SETTINGS.semi) at an idle box trailer of the freight depot nearest the
--                          County Loop (opts.depot for another) and couples it, then drives onto the loop and once
--                          round it at the loop's speed limit, or the semi's top speed when lower (opts.mph).
--                          Every frame it samples the hitch articulation:
--                          the tractor's heading against the trailer's, seen from above. Reports completion, the
--                          largest articulation, every jackknife event (articulation over
--                          Config/Trailers.jackknifeAngle) and whether the hitch held. Passes with the whole lap
--                          driven, still coupled, at highway speed, with no jackknife and no anti-exploit reset.
--   decoupleOutside(opts)  couples the same way at the freight depot nearest you, drives out onto an open road clear
--                          of every depot, yard, tow drop and trailer spot, stops and asks to uncouple. Expects a
--                          refusal with a message and nothing changed: the same trailer still coupled and hitched.
--                          Then it drives back into the depot and uncouples there (opts.stayCoupled skips that).
--   freight(opts)          one freight job end to end: makes sure of the freight license (BuyLicense; DevSetCash tops
--                          up the cash in Studio when it is short, and DevJob grantLicenseXp the XP gate; if it
--                          still can't, it skips and says so), puts the semi at the idle trailer on the first spot of the
--                          depot nearest you (opts.depot), accepts the offer that starts there (else the first),
--                          couples, drives through any long-haul waypoints to the destination depot and uncouples
--                          there. Pay, time, $/min.
--   towing(opts)           one towing job in a pickup (SETTINGS.towCar, or opts.vehicleId): puts it on the Breakdown
--                          spot nearest you (opts.breakdown) with its TowHitch just ahead of where the offered car's
--                          TowPoint will be, accepts that offer, couples, tows the car to the yard and uncouples
--                          there. Pay, time, $/min.
--   rate(type, minutes, opts)  chains "freight" or "towing" jobs back to back for `minutes` (the last job is
--                          finished) and reports the average $/min against Config/Economy.activities (§4: towing
--                          $1,600, freight $3,000), passing within SETTINGS.rateTolerance.
--   start(name, ...)       runs any of them in the background and returns at once; lastResult() returns its result
--                          once done (nil while it runs), status() what it's doing, stop() cancels it.
-- Each returns a Result (see the type): { name, passed, reason, checks, vehicle, elapsed, ... } plus the test's
-- numbers. Every check and result is printed as it finishes, so get_console_output shows them even if execute_luau
-- stops waiting.
--
-- Coupling without reversing. A player backs the semi under the trailer (or the pickup up to the car), but the
-- AutoDriver only drives forward, and a client PivotTo of a car is a teleport to AntiExploit. So:
--   * the semi: DevSpawnVehicle puts a car Spawning.spawnOffset + half its length in front of the character,
--     facing the way the character faces. The character is stood (on the trailer's roof) where that puts the
--     semi's Kingpin on the trailer's, facing the way the trailer faces; when the semi's chassis box would overlap
--     the trailer there, it goes forward SETTINGS.slideStep at a time until clear. A first spawn of the semi (or the
--     one you sit in) measures where its Kingpin and chassis are. Then TrailerAction couple, as the HUD sends it.
--   * freight jobs: respawning the job's car fails the job, so the semi is placed before accepting, at the trailer
--     on the depot's first spot (in Config/MapLayout order: Freight starts its offers at the depot nearest the
--     truck, from its first spot with an idle trailer; JobService also adopts any trailer coupled within the job's
--     arriveRadius of its couple stop). If the job's spot is farther, DevJob teleportToStop is tried once; then the
--     job is cancelled and the semi placed at that spot's trailer (SETTINGS.originTries).
--   * towing: the broken-down car only appears with its job, but where it will stand is fixed by its Breakdown
--     spot (JobService/Towing.poseAt, mirrored here) and its length (the offer names the car). So the pickup is
--     spawned on the spot before accepting, its TowHitch SETTINGS.towGap ahead of where the TowPoint of the longest
--     car that can break down will be; an offer whose car's TowPoint would then be out of
--     Config/Trailers.coupleDistance gets the pickup placed again for that car (SETTINGS.towPlaceTries). Offers come
--     from the spots nearest the truck, so the spot it stands on is soon among them.
--
-- How the numbers are measured (as Dev/JobTests):
--   * Pay is the Cash gained from just before the accept to just after the job ends, less any drive-to-earn payout
--     in that window (DriveEarnService's Studio-only DriveEarnLast decisions).
--   * A job's time runs from the accept to the JobUpdate that ends it. rate() counts each cycle: the hold of
--     Config/Jobs.calibration.betweenSeconds after the previous job, the offer search, and the job, plus what the
--     respawn skipped: calibration.coupleSecondsFreight (backing under the trailer) or coupleSecondsTow (backing up
--     to the car). The respawn itself isn't counted. The drive to the trailer or the breakdown is left out with its
--     pay: both jobs pay that approach by the stud at the calibrated rate, and a truck respawned there has none.
--     Waiting out a cooldown after a job the test driver had to give up isn't counted either.
--   * The AutoDriver cruises SETTINGS.cruisePerAverage x the calibration's average speed for each leg (towMph with a
--     car in tow, freightMph on a short run, longHaulMph through long-haul waypoints); it slows for corners itself,
--     which brings the average down to about the calibrated one.
--   * Config/Jobs calibrates the §4 rates for a level-1 player: rate() takes each job's level multiplier (from the
--     JobUpdate's progress) back out of its pay. An earnings boost (a code) can't be seen from here: run rate() with
--     none running.
--
-- Run from MCP execute_luau in the Client datamodel of a playtest (a character is enough: every test spawns its own
-- car). Runs take minutes, longer than an execute_luau call waits:
--   require(game.Players.LocalPlayer.PlayerScripts.Client.Dev.FreightTests).start("loop")
--   require(game.Players.LocalPlayer.PlayerScripts.Client.Dev.FreightTests).start("decoupleOutside")
--   require(game.Players.LocalPlayer.PlayerScripts.Client.Dev.FreightTests).start("freight")
--   require(game.Players.LocalPlayer.PlayerScripts.Client.Dev.FreightTests).start("towing")
--   require(game.Players.LocalPlayer.PlayerScripts.Client.Dev.FreightTests).start("rate", "freight", 10)
--   require(game.Players.LocalPlayer.PlayerScripts.Client.Dev.FreightTests).lastResult()
--
-- Driving goes through AutoDriver's Bridge (see its header), so calls from MCP's copy of this module drive the
-- game's controllers; remotes go through this copy's own Net (set up on first use, as Dev/JobTests does), and this
-- copy listens to JobUpdate, Notify and VehicleReset itself. State that every copy must see (running, cancel, the
-- last result) lives in attributes on this ModuleScript. Jobs pay real (Studio) cash and XP; the license costs
-- real (Studio) cash. loop() leaves the semi coupled on the loop (it can only uncouple at a depot); the next spawn
-- replaces it.
--
-- Does nothing outside Studio (CLAUDE.md hard rule 8); the server refuses DevJob, DevSetCash and DevSpawnVehicle
-- outside Studio too. The client loader never boots it.

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local AutoDriver = require(script.Parent.AutoDriver)
local Catalog = require(Shared.Vehicle.Catalog)
local DriveEarn = require(Shared.Config.DriveEarn)
local Economy = require(Shared.Config.Economy)
local Graph = require(Shared.Road.Graph)
local Jobs = require(Shared.Config.Jobs)
local MapLayout = require(Shared.Config.MapLayout)
local Net = require(Shared.Net)
local Pathfind = require(Shared.Road.Pathfind)
local RoadGraph = require(Shared.Config.RoadGraph)
local RouteTests = require(script.Parent.RouteTests)
local Spawning = require(Shared.Config.Spawning)
local Units = require(Shared.Util.Units)
local World = require(Shared.Config.World)

export type TestName = "loop" | "decoupleOutside" | "freight" | "towing" | "rate"
export type HaulKind = "freight" | "towing"

export type Options = {
	vehicleId: string?, -- the truck (default SETTINGS.semi, or SETTINGS.towCar for towing)
	trim: string?, -- with vehicleId (default: the vehicle's first trim)
	depot: string?, -- a freight JobDepot's MapLayout id to start at (default: see each test)
	breakdown: string?, -- towing: a Breakdown spot's MapLayout id to start at (default: the one nearest you)
	mph: number?, -- loop: lap speed (default loopSpeedMph()); jobs: cruise on every leg (default: calibrated)
	stayCoupled: boolean?, -- decoupleOutside: leave the trailer coupled out on the road
}

export type Check = { name: string, passed: boolean, detail: string }

-- An articulation over Config/Trailers.jackknifeAngle, from the frame it went over to the frame it came back.
export type JackknifeEvent = {
	phase: string, -- "joining" (driving onto the loop), "loop" (the lap), or a job leg's
	at: number, -- seconds into the sampling
	degrees: number, -- the articulation that first went over, signed (positive: the trailer points left of the cab)
	mph: number, -- the tractor's speed then
}

-- One stop (or run of long-haul waypoints and the stop after them) of a job.
export type Leg = {
	index: number, -- the job's stop index it started at
	kind: string, -- the stop kinds driven ("couple", "decouple", "waypoint x2 + decouple")
	label: string, -- the last stop's name
	routeStuds: number,
	driveSeconds: number,
	waitSeconds: number, -- held still at the stop until the server moved the job on
	seconds: number,
	mph: number, -- the cruise asked of the AutoDriver
	maxMph: number,
	stuckEvents: number,
	askedArrive: boolean, -- the server hadn't moved on after SETTINGS.advanceTimeout, so it was asked (arrive)
	teleported: boolean, -- DevJob teleportToStop was used for this leg
	reason: string, -- "advanced", or why the leg failed
}

-- One freight or towing job, from the offer to the pay.
export type JobRun = {
	type: string,
	title: string,
	subtitle: string,
	offerPay: number, -- the offer's estimate (before boosts and VIP)
	offerDistance: number, -- studs of road the offer said the job drives
	stops: number,
	completed: boolean, -- the server finished the job and paid
	pay: number, -- $ the job paid (cash gained, less drive-to-earn)
	driveEarnPaid: number, -- $ drive-to-earn paid while the job was active (should be 0)
	seconds: number, -- accept to the job ending
	cycleSeconds: number, -- what rate() counts (see the header)
	creditedSeconds: number, -- the backing up to the load the respawn skipped (calibration allowance)
	perMinute: number, -- pay per minute of `seconds`
	routeStuds: number, -- studs of road driven for the job
	timeAllowed: number?, -- seconds from the accept to the job's deadline
	timeLeft: number?, -- seconds still left on the deadline when the job ended
	level: number?, -- the player's level in this job type when it was accepted
	levelMultiplier: number?, -- that level's pay multiplier
	xpGained: number,
	originTries: number, -- jobs accepted (and given up) before this one coupled: freight's wrong spots
	coupleGap: number?, -- studs between the coupling points when it asked to couple
	coupled: boolean,
	coupleReply: string?, -- what TrailerAction couple answered
	uncoupled: boolean,
	uncoupleReply: string?, -- what TrailerAction decouple answered at the drop
	maxArticulation: number, -- degrees, while coupled
	jackknifes: number, -- articulation over Config/Trailers.jackknifeAngle while coupled
	legs: { Leg },
	reason: string, -- "completed", or why it ended
}

export type Result = {
	name: string,
	passed: boolean,
	skipped: boolean, -- the test couldn't run here (the reason says why); not a failure of the game
	reason: string, -- "done", or why it ended early
	checks: { Check },
	vehicle: string?, -- "vehicleId/trim"
	elapsed: number,
	notes: { string },
	notices: { string }, -- the Notify toasts the server sent during the test, in order
	-- loop, decoupleOutside
	depot: string?, -- MapLayout id of the freight depot it started at
	trailer: string?, -- the trailer's name
	kingpinGap: number?, -- studs between the semi's Kingpin and the trailer's when it asked to couple
	slid: number?, -- studs the semi went forward of the exact spot to clear the trailer
	coupleDistance: number?, -- Config/Trailers.coupleDistance, when it is there
	-- loop
	targetMph: number?,
	lapCompleted: boolean?,
	lapStuds: number?,
	lapSeconds: number?,
	averageMph: number?, -- on the lap
	maxMph: number?,
	stuckEvents: number?,
	maxArticulation: number?, -- degrees, the whole drive
	maxArticulationLoop: number?, -- degrees, on the lap
	jackknifeAngle: number?, -- degrees (Config/Trailers.jackknifeAngle)
	jackknifeEvents: { JackknifeEvent }?,
	maxHitchGap: number?, -- studs between the coupling points, the most seen
	resets: number?, -- VehicleReset (anti-exploit or unstuck moves) during the drive
	-- decoupleOutside
	refusal: string?, -- what the server answered
	clearOfFootprints: number?, -- studs from the nearest depot, yard, tow drop or trailer spot where it asked
	-- freight, towing
	job: JobRun?,
	license: string?, -- what happened with the freight license
	-- rate
	jobs: { JobRun }?,
	minutes: number?, -- minutes counted (the jobs' cycles)
	earned: number?,
	perMinute: number?, -- what was paid, per minute counted
	perMinuteAtLevel1: number?, -- the same with each job's level multiplier taken back out (what §4 targets)
	target: number?, -- Config/Economy.activities $/min for this job type
	ratio: number?, -- perMinuteAtLevel1 / target
	failedJobs: number?,
	creditedMinutes: number?, -- minutes of skipped backing up to loads added to the count
}

-- A dev tool, so its numbers live here rather than in Shared/Config (like Dev/JobTests' SETTINGS).
local SETTINGS = {
	-- The rigs (docs/phase-8-contracts.md: a semi with a box trailer; PLAN.md §4: towing with a pickup).
	semi = { vehicleId = "ohm_hauler", trim = "standard" },
	towCar = { vehicleId = "ohm_mesa", trim = "standard" },
	preferredTrailer = "box_trailer", -- ServerStorage.TrailerModels name loop() and decoupleOutside() want
	-- loop(): the speed players drive the lap at, the County Loop's own speed limit (Config/RoadGraph highway
	-- edges) or the semi's top speed when that is lower (HitchService caps a coupled rig at its tractor's); the
	-- drive onto the loop is slower. The lap must reach highwayMinShare of that speed at least once.
	-- fallbackLoopMph only stands in when neither can be read.
	fallbackLoopMph = 70,
	approachMph = 25,
	highwayMinShare = 0.9,
	-- Coupled driving: an event ends once the articulation is this many degrees back under the threshold, and the
	-- coupling points this far apart (studs) or closer still count as hitched.
	jackknifeHysteresis = 5,
	maxHitchGap = 2,
	minAxisStuds = 1, -- a towed body's heading is its chassis-to-coupling-point line when that is this long
	-- Job legs: the AutoDriver cruises this many times the calibrated average speed. Dev/JobTests measured a 35 mph
	-- cruise averaging the 30 mph Config/Jobs calibrates on: corners, junctions and stops take the rest.
	cruisePerAverage = 35 / 30,
	maxMiter = 2, -- right-hand lane offset at corners (as Dev/RouteTests)
	-- Placing the semi at a trailer.
	slideStep = 0.5, -- studs forward at a time until the semi's chassis clears the trailer's collidable parts
	maxSlide = 16,
	probeUp = 40, -- surface rays start this far above the point (over a trailer's roof)...
	probeDown = 200, -- ...and look this far down
	standHeight = 3, -- studs above the surface the character is put at before a car spawns
	standSettleSeconds = 2, -- after moving the character, before the spawn (the server has to see it there)
	depotRadius = 300, -- studs: trailers (and TrailerSpawn spots without a depot attribute) this near a depot are its
	spotSlack = 4, -- studs: a trailer whose chassis centre is this near a TrailerSpawn footprint stands on it
	pointTimeout = 10, -- seconds to wait for a coupling attachment to stream in
	coupleTimeout = 5, -- seconds after TrailerAction for the car's TowingModel attribute to change
	decoupleWatchSeconds = 3, -- after a refused uncouple, watched this long for anything changing
	-- decoupleOutside(): the open road is at least openRoadStuds along the route from the depot and outsideMargin
	-- from every footprint where a coupling may be undone (and every trailer spot).
	openRoadStuds = 250,
	outsideMargin = 100,
	-- towing: the pickup's TowHitch goes towGap studs ahead of where the longest breakdown car's TowPoint will be
	-- (its chassis then clears the car's by a few studs more). An offer is taken when its car's TowPoint will be
	-- within Config/Trailers.coupleDistance less coupleMargin of the hitch and not past it; otherwise the pickup is
	-- placed again for the offered car, at most towPlaceTries times. Offers come a few at a time from the spots
	-- nearest the truck: towOfferTries refreshes are made for one at the spot it stands on.
	towGap = 1,
	coupleMargin = 1,
	towPlaceTries = 3,
	towOfferTries = 8,
	towedSearchRadius = 120, -- studs round the breakdown stop the Towed car is looked for
	-- Where Towing stands its car: the road's direction is measured roadStep of an edge either side of the spot,
	-- and needs at least minDirection studs (JobService/Towing's ROAD_STEP and MIN_DIRECTION).
	roadStep = 0.02,
	minDirection = 1e-3,
	-- Jobs accepted before giving up on coupling one (freight: the job's spot was another than the semi's).
	originTries = 3,
	-- Stops. The AutoDriver ends a leg within stopArriveRadius of its last point; a stop farther off the road
	-- than pullInMin gets a straight pull-in toward it.
	stopArriveRadius = 4,
	pullInMin = 2,
	advanceTimeout = 20, -- seconds held still at a stop before asking the server (JobAction arrive)
	arriveRetryTimeout = 10, -- seconds after asking before giving up on the stop
	maxExtraLegs = 3, -- legs driven beyond the job's stops (a long-haul waypoint missed and driven back to)
	-- Spawning on an open road (as Dev/JobTests): the middle of the nearest edge this long or longer, of one of
	-- these kinds, in its right-hand lane.
	minStartEdge = 100,
	startKinds = { "street", "arterial" },
	streamTimeout = 10, -- seconds to wait for the map around a place to stream in
	streamRetries = 3, -- looks for a trailer or car that may still be streaming in...
	streamRetrySeconds = 1, -- ...this far apart
	spawnTimeout = 15,
	exitTimeout = 5,
	settleSeconds = 1.5, -- after getting out, moving or sitting down, before the next step
	-- Remotes: seconds between calls of each (Net's burst and refill rates; a call over them is dropped).
	remoteGaps = {
		JobAction = 1.1,
		TrailerAction = 2.1,
		BuyLicense = 5.1,
		DevJob = 1.1,
		DevSetCash = 1.1,
	} :: { [string]: number },
	updateTimeout = 10, -- seconds to wait for the JobUpdate a JobAction should bring
	stateTimeout = 3, -- seconds to wait for a JobUpdate showing the state before the test
	offerTries = 4, -- refreshes tried before giving up on an offer of the wanted type
	cooldownSlack = 1, -- seconds added to a cooldown before trying again
	cashSettleSeconds = 3, -- after a job ends, for its pay to reach the Cash attribute
	-- rate()
	rateTolerance = 0.15, -- passes within ±15 % of the §4 target
	maxFailuresInARow = 3,
	-- Housekeeping.
	maxNotices = 60,
	holdSeconds = 2, -- after a test: brake and hold this long so the car ends stopped
}

local STATUS = "Status" -- attribute: "idle", "running", "done", "skipped", "stopped" or "failed"
local CURRENT = "Current" -- attribute: what the running test is doing now
local RESULT = "Result" -- attribute: the last result, as JSON
local CANCEL = "Cancel" -- attribute: true asks a running test to stop
local RUN_ID = "RunId" -- attribute: the id of the newest test
local LOG = "[FreightTests]"
local SECONDS_PER_MINUTE = 60
local EPSILON = 1e-6
local SAME_POINT = 1e-3 -- studs: route points closer than this are one
local PROBE_NAME = "FreightTestsProbe"

-- The vehicle model contract (docs/phase-1-contracts.md) and docs/phase-8-contracts.md.
local DRIVER_SEAT = "Driver"
local VEHICLE_ID = "VehicleId"
local CHASSIS = "Chassis"
local KINGPIN = "Kingpin" -- the semi's fifth wheel and a trailer's pin
local TOW_HITCH = "TowHitch" -- a pickup's or tow truck's hitch
local TOW_POINT = "TowPoint" -- a towed car's front tow point
local DEPOT_TAG = "JobDepot"
local SPAWN_TAG = "TrailerSpawn"
local TOW_DROP_TAG = "TowDrop"
local BREAKDOWN_TAG = "Breakdown"
local FREIGHT_JOB = "freight"
local TOWING_JOB = "towing"
local SPAWN_DEPOT_ATTRIBUTE = "depot" -- TrailerSpawn: its depot's location id (Config/MapLayout)

-- Names Config/Jobs keeps for the hitch and the job props (Jobs.hitch, Jobs.props), with the contract's names
-- when it doesn't have them. Read loosely: the freight-jobs helper owns those tables.
local jobsConfig: any = Jobs
local hitchConfig: any = if type(jobsConfig.hitch) == "table" then jobsConfig.hitch else {}
local propsConfig: any = if type(jobsConfig.props) == "table" then jobsConfig.props else {}
local calibration: any = Jobs.calibration

local function configName(value: any, fallback: string): string
	return if type(value) == "string" and value ~= "" then value else fallback
end

local TOWING_ATTRIBUTE = configName(hitchConfig.towingAttribute, "TowingModel")
local TOWING_VALUE = configName(hitchConfig.towingValue, "Towing")
local TOWED_ATTRIBUTE = configName(propsConfig.towedAttribute, "Towed")
local JOB_ATTRIBUTE = configName(propsConfig.jobAttribute, "JobId")
local OWNER_ATTRIBUTE = configName(propsConfig.ownerAttribute, "JobOwnerUserId")
local PROPS_FOLDER = configName(propsConfig.folder, "JobProps")

-- What this client sees of the server's JobUpdate (Services/JobService header).
type StopView = { position: Vector3, label: string, kind: string }
type JobView = {
	id: string,
	type: string,
	title: string,
	stopIndex: number,
	stops: { StopView },
	estPay: number?,
	deadline: number?, -- Workspace:GetServerTimeNow() seconds
	startedAt: number?,
}
type Progress = { xp: number, level: number, multiplier: number }
type Availability = { ok: boolean, reason: string }
type OfferView = {
	id: string,
	type: string,
	title: string,
	subtitle: string,
	pay: number,
	distance: number,
	stops: number,
}
type Reply = { ok: boolean, message: string }

-- Everything the server tells this client during a test, kept as it arrives.
type Watch = {
	job: JobView?,
	offers: { OfferView }?,
	availability: { [string]: Availability },
	progress: { [string]: Progress },
	licenses: { [string]: boolean },
	updates: number,
	changedAt: number, -- os.clock() of the last JobUpdate
	endedAt: { [string]: number }, -- job id -> os.clock() of the JobUpdate that showed it gone
	notices: { { at: number, text: string } },
	driveEarn: { { at: number, amount: number } },
	resets: { number }, -- os.clock() of each VehicleReset (the server moved the car back)
	changed: BindableEvent, -- fires after every JobUpdate, notice, cash change, drive-to-earn decision and reset
	connections: { RBXScriptConnection },
}

type Context = {
	id: string,
	name: TestName,
	started: number,
	result: Result,
	watch: Watch,
}

-- A trailer, or a car that can be towed, as this client sees it.
type Towable = {
	model: Model,
	chassis: BasePart,
	point: Attachment, -- its coupling point: a trailer's Kingpin, a towed car's TowPoint
	parked: boolean, -- its chassis is anchored: standing idle, hitched to nothing
	preferred: boolean, -- a SETTINGS.preferredTrailer
	distance: number, -- flat studs from where it was looked for
}

-- A truck's coupling point and chassis, measured on a spawned one.
type RigGeometry = {
	coupleLocal: Vector3, -- the coupling point in the chassis's space (front is -Z, so a rear hitch has Z > 0)
	chassisSize: Vector3,
	chassisHeight: number, -- chassis centre above the ground point under it (the model pivot)
	length: number, -- Config/Vehicles length: DevSpawnVehicle places the car by it
	collisionGroup: string,
}

-- Where the semi's chassis goes in front of a trailer.
type Placement = {
	frame: CFrame,
	slid: number, -- studs forward of the exact spot, to clear the trailer
	clear: boolean, -- nothing else collidable in the way there
	blocker: string?, -- what is in the way when not clear
}

-- The semi spawned at a trailer.
type Placed = {
	car: Model,
	trailer: Towable,
	rig: RigGeometry,
	placement: Placement,
	gap: number, -- flat studs between the two Kingpins after the spawn
}

-- The articulation sampler running while a rig is coupled.
type Monitor = {
	phase: string,
	maxDegrees: number,
	maxByPhase: { [string]: number },
	events: { JackknifeEvent },
	maxGap: number,
	phaseStuds: number, -- studs the tractor has covered in the current phase
	samples: number,
	stop: () -> (),
}

---------------------------------------------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------------------------------------------

local locationsById: { [string]: MapLayout.Location } = {}
for _, location in MapLayout.locations do
	locationsById[location.id] = location
end

local function flat(v: Vector3): Vector3
	return Vector3.new(v.X, 0, v.Z)
end

local function flatDistance(a: Vector3, b: Vector3): number
	return (flat(a) - flat(b)).Magnitude
end

local function round(value: number, places: number): number
	local scale = 10 ^ places
	return math.round(value * scale) / scale
end

local function textOf(value: any): string
	return if type(value) == "string" then value else ""
end

local function numberOf(value: any): number
	return if type(value) == "number" and value == value then value else 0
end

-- A Lua pattern that matches text made from a Config/Jobs message format: %s and %d become captures.
local function patternOf(format: string): string
	local escaped = string.gsub(format, "[%^%$%(%)%.%[%]%*%+%-%?]", "%%%0")
	escaped = string.gsub(escaped, "%%s", "(.-)")
	escaped = string.gsub(escaped, "%%d", "(%%d+)")
	return "^" .. escaped .. "$"
end

local COOLDOWN_PATTERN = patternOf(Jobs.messages.cooldown)
local CANCELLED_PATTERN = patternOf(Jobs.messages.cancelled)
local FAILED_PATTERN = patternOf(Jobs.messages.failed)
local LEVEL_UP_PATTERN = patternOf(Jobs.messages.levelUp)

local function cancelRequested(ctx: Context): boolean
	return script:GetAttribute(CANCEL) == true or script:GetAttribute(RUN_ID) ~= ctx.id
end

local function setCurrent(ctx: Context, text: string)
	if script:GetAttribute(RUN_ID) == ctx.id then
		script:SetAttribute(CURRENT, text)
	end
	print(`{LOG} {ctx.name}: {text}`)
end

local function note(ctx: Context, text: string)
	table.insert(ctx.result.notes, text)
	print(`{LOG} {ctx.name}: {text}`)
end

local function check(ctx: Context, name: string, passed: boolean, detail: string)
	table.insert(ctx.result.checks, { name = name, passed = passed, detail = detail })
	print(`{LOG} {ctx.name}: {if passed then "PASS" else "FAIL"} {name} ({detail})`)
end

-- Ends a test that can't run here (no XP for the license, a missing Phase 8 piece): not a game failure.
local function skip(ctx: Context, reason: string): Result
	ctx.result.skipped = true
	ctx.result.reason = `skipped: {reason}`
	note(ctx, ctx.result.reason)
	return ctx.result
end

local netReady = false

-- This copy of Net may be MCP's own (not the game's), so make sure it knows the remotes.
local function ensureNet()
	if not netReady then
		Net.setupClient()
		netReady = true
	end
end

local function humanoidOf(): Humanoid?
	local character = Players.LocalPlayer.Character
	return if character then character:FindFirstChildOfClass("Humanoid") else nil
end

-- The car whose Driver seat the local player sits in, or nil.
local function currentCar(): Model?
	local humanoid = humanoidOf()
	local seat = if humanoid then humanoid.SeatPart else nil
	if seat == nil or seat.Name ~= DRIVER_SEAT then
		return nil
	end
	local node: Instance? = seat.Parent
	while node do
		if node:IsA("Model") and node:GetAttribute(VEHICLE_ID) ~= nil then
			return node
		end
		node = node.Parent
	end
	return nil
end

-- The pose of the driven car's chassis, or nil.
local function carPose(): CFrame?
	local car = currentCar()
	local chassis = if car then car.PrimaryPart else nil
	return if chassis then chassis.CFrame else nil
end

-- Where the player is: the driven car's chassis, else the character.
local function playerPosition(): Vector3?
	local pose = carPose()
	if pose then
		return pose.Position
	end
	local character = Players.LocalPlayer.Character
	return if character then character:GetPivot().Position else nil
end

local function carIdentity(car: Model): (string?, string?)
	local vehicleId, trim = car:GetAttribute(VEHICLE_ID), car:GetAttribute("Trim")
	return if type(vehicleId) == "string" then vehicleId else nil, if type(trim) == "string" then trim else nil
end

local function cash(): number
	local value = Players.LocalPlayer:GetAttribute(Economy.cashAttribute)
	return if type(value) == "number" then value else 0
end

-- Waits until `test()` is true, re-checking whenever `signal` fires, for at most `timeout` seconds; a cancel ends
-- the wait too. Returns whether `test()` came true.
local function waitFor(ctx: Context, test: () -> boolean, signal: RBXScriptSignal, timeout: number): boolean
	if test() then
		return true
	end
	if cancelRequested(ctx) then
		return false
	end
	local thread = coroutine.running()
	local settled = false
	local connections: { RBXScriptConnection } = {}
	local timer: thread? = nil
	local function finish(result: boolean)
		if settled then
			return
		end
		settled = true
		for _, connection in connections do
			connection:Disconnect()
		end
		if timer ~= nil and coroutine.running() ~= timer then
			task.cancel(timer)
		end
		task.spawn(thread, result)
	end
	table.insert(
		connections,
		signal:Connect(function()
			if test() then
				finish(true)
			end
		end)
	)
	table.insert(
		connections,
		script:GetAttributeChangedSignal(CANCEL):Connect(function()
			if cancelRequested(ctx) then
				finish(false)
			end
		end)
	)
	timer = task.delay(timeout, function()
		finish(test())
	end)
	return coroutine.yield()
end

-- Holds the car still (AutoDriver.holdStill) until `test()` comes true, re-checked whenever the watch changes, or
-- `timeout` seconds pass. The change that makes it true ends the hold at once. Returns whether it came true.
local function holdUntil(ctx: Context, test: () -> boolean, timeout: number): boolean
	if test() then
		return true
	end
	if cancelRequested(ctx) then
		return false
	end
	local holding = true
	local connection = ctx.watch.changed.Event:Connect(function()
		if holding and test() then
			holding = false
			AutoDriver.stop()
		end
	end)
	AutoDriver.holdStill(timeout)
	holding = false
	connection:Disconnect()
	return test()
end

-- Asks for the map round `position` (streaming); quietly carries on when the engine says no.
local function streamAround(position: Vector3)
	pcall(function()
		Players.LocalPlayer:RequestStreamAroundAsync(position, SETTINGS.streamTimeout)
	end)
end

local function findAttachment(model: Instance, name: string): Attachment?
	local found = model:FindFirstChild(name, true)
	return if found ~= nil and found:IsA("Attachment") then found else nil
end

-- Waits for `model` to have an attachment called `name` (with streaming, a model can arrive in pieces).
local function waitForAttachment(ctx: Context, model: Model, name: string): Attachment?
	waitFor(ctx, function(): boolean
		return findAttachment(model, name) ~= nil
	end, model.DescendantAdded, SETTINGS.pointTimeout)
	return findAttachment(model, name)
end

local function chassisOf(model: Model): BasePart?
	local primary = model.PrimaryPart
	if primary ~= nil then
		return primary
	end
	local named = model:FindFirstChild(CHASSIS)
	return if named ~= nil and named:IsA("BasePart") then named else nil
end

-- Config/Trailers belongs to the trailer-physics helper (docs/phase-8-contracts.md). Only the values the contract
-- names are read, loosely (top level, else any section), so a missing one is reported rather than guessed.
local function trailersConfig(): any
	local module = Shared.Config:FindFirstChild("Trailers")
	if module == nil or not module:IsA("ModuleScript") then
		return nil
	end
	local ok, loaded = pcall(require :: any, module)
	return if ok and type(loaded) == "table" then loaded else nil
end

local function trailersNumber(key: string): number?
	local config = trailersConfig()
	if config == nil then
		return nil
	end
	if type(config[key]) == "number" then
		return config[key]
	end
	for _, section in config do
		if type(section) == "table" and type(section[key]) == "number" then
			return section[key]
		end
	end
	return nil
end

-- Config/Trailers.jackknifeAngle in degrees (Config/Trailers keeps angles in degrees, like BallSocketConstraint).
local function jackknifeDegrees(): number?
	local value = trailersNumber("jackknifeAngle")
	return if value ~= nil and value > 0 then value else nil
end

-- A Config/Jobs.calibration speed (mph), or `fallback` when it has none.
local function calibratedMph(key: string, fallback: number): number
	local value = calibration[key]
	return if type(value) == "number" and value > 0 then value else fallback
end

---------------------------------------------------------------------------------------------------------------
-- What the server says: JobUpdate, Notify, cash, drive-to-earn and resets
---------------------------------------------------------------------------------------------------------------

local function parseJob(raw: any): JobView?
	if type(raw) ~= "table" or type(raw.id) ~= "string" or type(raw.stops) ~= "table" then
		return nil
	end
	local stops: { StopView } = {}
	for _, stop in raw.stops do
		if type(stop) == "table" and typeof(stop.position) == "Vector3" then
			table.insert(stops, { position = stop.position, label = textOf(stop.label), kind = textOf(stop.kind) })
		end
	end
	return {
		id = raw.id,
		type = textOf(raw.type),
		title = textOf(raw.title),
		stopIndex = if type(raw.stopIndex) == "number" then raw.stopIndex else 1,
		stops = stops,
		estPay = if type(raw.estPay) == "number" then raw.estPay else nil,
		deadline = if type(raw.deadline) == "number" then raw.deadline else nil,
		startedAt = if type(raw.startedAt) == "number" then raw.startedAt else nil,
	}
end

local function parseOffers(raw: any): { OfferView }?
	if type(raw) ~= "table" then
		return nil
	end
	local offers: { OfferView } = {}
	for _, offer in raw do
		if type(offer) == "table" and type(offer.id) == "string" then
			table.insert(offers, {
				id = offer.id,
				type = textOf(offer.type),
				title = textOf(offer.title),
				subtitle = textOf(offer.subtitle),
				pay = numberOf(offer.pay),
				distance = numberOf(offer.distance),
				stops = numberOf(offer.stops),
			})
		end
	end
	return offers
end

-- The decision DriveEarnService last published (Studio only), or nil.
local function lastDriveEarnAmount(): number?
	local encoded = Players.LocalPlayer:GetAttribute(DriveEarn.debugDecisionAttribute)
	if type(encoded) ~= "string" then
		return nil
	end
	local ok, decoded = pcall(HttpService.JSONDecode, HttpService, encoded)
	return if ok and type(decoded) == "table" and type(decoded.amount) == "number" then decoded.amount else nil
end

local function onJobUpdate(watch: Watch, payload: any)
	if type(payload) ~= "table" then
		return
	end
	local now = os.clock()
	local previous = watch.job
	local job = parseJob(payload.job)
	if previous ~= nil and (job == nil or job.id ~= previous.id) then
		watch.endedAt[previous.id] = now
	end
	watch.job = job
	local offers = parseOffers(payload.offers)
	if offers ~= nil then
		watch.offers = offers
	elseif job ~= nil then
		watch.offers = nil -- none are offered during a job
	end
	if type(payload.progress) == "table" then
		for kind, entry in payload.progress do
			if type(kind) == "string" and type(entry) == "table" then
				watch.progress[kind] =
					{ xp = numberOf(entry.xp), level = numberOf(entry.level), multiplier = numberOf(entry.multiplier) }
			end
		end
	end
	if job == nil then
		-- Availability is only sent while there is no job.
		table.clear(watch.availability)
		if type(payload.availability) == "table" then
			for kind, entry in payload.availability do
				if type(kind) == "string" and type(entry) == "table" then
					watch.availability[kind] = { ok = entry.ok == true, reason = textOf(entry.reason) }
				end
			end
		end
	end
	if type(payload.licenses) == "table" then
		table.clear(watch.licenses)
		for id, held in payload.licenses do
			if type(id) == "string" then
				watch.licenses[id] = held == true
			end
		end
	end
	watch.updates += 1
	watch.changedAt = now
	watch.changed:Fire()
end

local function newWatch(): Watch
	ensureNet()
	local watch: Watch = {
		job = nil,
		offers = nil,
		availability = {},
		progress = {},
		licenses = {},
		updates = 0,
		changedAt = os.clock(),
		endedAt = {},
		notices = {},
		driveEarn = {},
		resets = {},
		changed = Instance.new("BindableEvent"),
		connections = {},
	}
	local player = Players.LocalPlayer
	table.insert(
		watch.connections,
		Net.onClientEvent("JobUpdate", function(payload: any)
			onJobUpdate(watch, payload)
		end)
	)
	table.insert(
		watch.connections,
		Net.onClientEvent("Notify", function(payload: any)
			local text = if type(payload) == "table" then textOf(payload.text) else ""
			if text ~= "" then
				table.insert(watch.notices, { at = os.clock(), text = text })
				watch.changed:Fire()
			end
		end)
	)
	table.insert(
		watch.connections,
		Net.onClientEvent("VehicleReset", function()
			table.insert(watch.resets, os.clock())
			watch.changed:Fire()
		end)
	)
	table.insert(
		watch.connections,
		player:GetAttributeChangedSignal(Economy.cashAttribute):Connect(function()
			watch.changed:Fire()
		end)
	)
	table.insert(
		watch.connections,
		player:GetAttributeChangedSignal(DriveEarn.debugTickAttribute):Connect(function()
			table.insert(watch.driveEarn, { at = os.clock(), amount = lastDriveEarnAmount() or 0 })
			watch.changed:Fire()
		end)
	)
	return watch
end

local function closeWatch(watch: Watch)
	for _, connection in watch.connections do
		connection:Disconnect()
	end
	watch.changed:Destroy()
end

-- Drive-to-earn paid since `since` (os.clock()).
local function driveEarnSince(watch: Watch, since: number): number
	local total = 0
	for _, decision in watch.driveEarn do
		if decision.at >= since then
			total += decision.amount
		end
	end
	return total
end

local function resetsSince(watch: Watch, since: number): number
	local count = 0
	for _, at in watch.resets do
		if at >= since then
			count += 1
		end
	end
	return count
end

-- The newest notice since `since` matching `pattern`, or nil.
local function noticeSince(watch: Watch, since: number, pattern: string): string?
	for index = #watch.notices, 1, -1 do
		local notice = watch.notices[index]
		if notice.at < since then
			break
		end
		if string.match(notice.text, pattern) ~= nil then
			return notice.text
		end
	end
	return nil
end

local function lastNoticeSince(watch: Watch, since: number): string?
	local notice = watch.notices[#watch.notices]
	return if notice and notice.at >= since then notice.text else nil
end

---------------------------------------------------------------------------------------------------------------
-- Remotes
---------------------------------------------------------------------------------------------------------------

local lastCallAt: { [string]: number } = {}

-- Calls a function remote no faster than Net's rate limit for it allows (a call over the limit is dropped, and its
-- empty answer would read as a refusal). Reads either reply shape: { ok, message } or ok, message. Nil when there
-- was no answer.
local function call(name: string, payload: { [string]: any }): Reply?
	ensureNet()
	local gap = (SETTINGS.remoteGaps[name] or 0) - (os.clock() - (lastCallAt[name] or -math.huge))
	if gap > 0 then
		task.wait(gap)
	end
	lastCallAt[name] = os.clock()
	local answer = table.pack(pcall(Net.invokeServer :: any, name, payload))
	if not answer[1] then
		warn(`{LOG} {name} failed: {answer[2]}`)
		return nil
	end
	local first, second = answer[2], answer[3]
	if type(first) == "table" then
		return { ok = first.ok == true, message = textOf(first.message) }
	elseif type(first) == "boolean" then
		return { ok = first, message = textOf(second) }
	end
	return nil
end

local function describe(reply: Reply?): string
	if reply == nil then
		return "no answer"
	end
	return `{if reply.ok then "ok" else "refused"}: "{reply.message}"`
end

local function jobAction(payload: { [string]: any }): Reply?
	return call("JobAction", payload)
end

-- The loop() lap speed: the County Loop's speed limit (the fastest Config/RoadGraph highway edge), or the
-- semi's catalog top speed when that is lower.
local function loopSpeedMph(): number
	local limit = 0
	for _, edge in RoadGraph.edges do
		if edge.kind == "highway" then
			limit = math.max(limit, edge.speedLimitMph)
		end
	end
	local trim = Catalog.getTrim(SETTINGS.semi.vehicleId, SETTINGS.semi.trim)
	if trim ~= nil then
		limit = if limit > 0 then math.min(limit, trim.topSpeedMph) else trim.topSpeedMph
	end
	return if limit > 0 then limit else SETTINGS.fallbackLoopMph
end

-- Studio only: moves the job's car next to the job's current stop.
local function teleportToStop(): Reply?
	return call("DevJob", { action = "teleportToStop" })
end

-- Asks for fresh offers and waits up to `timeout` seconds for the JobUpdate that brings them (and the job).
local function refresh(ctx: Context, timeout: number): boolean
	local watch = ctx.watch
	local before = watch.updates
	jobAction({ action = "refresh" })
	return waitFor(ctx, function(): boolean
		return watch.updates > before
	end, watch.changed.Event, timeout)
end

---------------------------------------------------------------------------------------------------------------
-- The map: depots, footprints and the County Loop
---------------------------------------------------------------------------------------------------------------

local function locationsTagged(tag: string): { MapLayout.Location }
	local list: { MapLayout.Location } = {}
	for _, location in MapLayout.locations do
		if location.tag == tag then
			table.insert(list, location)
		end
	end
	return list
end

local function isFreightDepot(location: MapLayout.Location): boolean
	return location.tag == DEPOT_TAG and location.attributes ~= nil and location.attributes.jobType == FREIGHT_JOB
end

local function freightDepots(): { MapLayout.Location }
	local list: { MapLayout.Location } = {}
	for _, location in MapLayout.locations do
		if isFreightDepot(location) then
			table.insert(list, location)
		end
	end
	return list
end

local function nearestOf(locations: { MapLayout.Location }, position: Vector3): MapLayout.Location?
	local best: MapLayout.Location? = nil
	local bestDistance = math.huge
	for _, location in locations do
		local distance = flatDistance(location.position, position)
		if distance < bestDistance then
			best, bestDistance = location, distance
		end
	end
	return best
end

-- The County Loop's node positions, in loop order.
local function loopPositions(): { Vector3 }
	local positions: { Vector3 } = {}
	for _, id in RoadGraph.loopNodeIds do
		local node = Graph.node(id)
		if node then
			table.insert(positions, node.position)
		end
	end
	return positions
end

-- The freight depot `id` (opts.depot), else the one nearest `near`, else the one nearest the County Loop.
local function chooseDepot(id: string?, near: Vector3?): (MapLayout.Location?, string?)
	if id ~= nil then
		local location = locationsById[id]
		if location == nil or not isFreightDepot(location) then
			return nil, `"{id}" isn't a freight JobDepot in Config/MapLayout`
		end
		return location, nil
	end
	local depots = freightDepots()
	if #depots == 0 then
		return nil, "Config/MapLayout has no freight JobDepot"
	end
	if near ~= nil then
		return nearestOf(depots, near), nil
	end
	-- Nearest the loop's road: the distance to each stretch between two of its nodes, seen from above.
	local positions = loopPositions()
	local function toLoop(position: Vector3): number
		local nearest = math.huge
		for index, a in positions do
			local b = positions[index % #positions + 1]
			local span = flat(b - a)
			local t = if span.Magnitude > EPSILON
				then math.clamp(flat(position - a):Dot(span) / (span.Magnitude * span.Magnitude), 0, 1)
				else 0
			nearest = math.min(nearest, flatDistance(position, a + span * t))
		end
		return nearest
	end
	local best: MapLayout.Location? = nil
	local bestDistance = math.huge
	for _, depot in depots do
		local distance = toLoop(depot.position)
		if distance < bestDistance then
			best, bestDistance = depot, distance
		end
	end
	return best, nil
end

-- A location's footprint on the ground: its centre, turned to its yaw (MapLayout's convention).
local function footprintFrame(location: MapLayout.Location): CFrame
	return CFrame.new(location.position) * CFrame.Angles(0, math.rad(location.yaw), 0)
end

-- Flat studs from `position` to the location's footprint (0 inside it).
local function outsideDistance(location: MapLayout.Location, position: Vector3): number
	local here = footprintFrame(location):PointToObjectSpace(position)
	local dx = math.max(math.abs(here.X) - location.size.X / 2, 0)
	local dz = math.max(math.abs(here.Z) - location.size.Z / 2, 0)
	return math.sqrt(dx * dx + dz * dz)
end

-- Where a coupling may be undone (freight depots, the tow yard, tow drops) and the trailer spots: decoupleOutside()
-- stops clear of all of them.
local function couplingZones(): { MapLayout.Location }
	local list: { MapLayout.Location } = {}
	for _, location in MapLayout.locations do
		if location.tag == DEPOT_TAG or location.tag == TOW_DROP_TAG or location.tag == SPAWN_TAG then
			table.insert(list, location)
		end
	end
	return list
end

local function nearestFootprint(position: Vector3, zones: { MapLayout.Location }): (MapLayout.Location?, number)
	local best: MapLayout.Location? = nil
	local bestDistance = math.huge
	for _, zone in zones do
		local distance = outsideDistance(zone, position)
		if distance < bestDistance then
			best, bestDistance = zone, distance
		end
	end
	return best, bestDistance
end

-- The TrailerSpawn spots that belong to `depot` (their depot attribute, else within SETTINGS.depotRadius).
local function spotsOf(depot: MapLayout.Location): { MapLayout.Location }
	local list: { MapLayout.Location } = {}
	for _, spot in locationsTagged(SPAWN_TAG) do
		local owner = if spot.attributes then spot.attributes[SPAWN_DEPOT_ATTRIBUTE] else nil
		if
			owner == depot.id or (owner == nil and flatDistance(spot.position, depot.position) <= SETTINGS.depotRadius)
		then
			table.insert(list, spot)
		end
	end
	return list
end

-- The freight depot an offer starts at: the one its subtitle names ("Hitch up at <origin>", "... from <origin>";
-- Freight's offers name the destination in the title). The longest name wins where one contains another.
local function originOf(offer: OfferView): MapLayout.Location?
	local best: MapLayout.Location? = nil
	for _, depot in freightDepots() do
		if string.find(offer.subtitle, depot.displayName, 1, true) ~= nil then
			if best == nil or #depot.displayName > #best.displayName then
				best = depot
			end
		end
	end
	return best
end

---------------------------------------------------------------------------------------------------------------
-- Trailers, towed cars and couplings
---------------------------------------------------------------------------------------------------------------

local function isPreferred(model: Model): boolean
	if model.Name == SETTINGS.preferredTrailer then
		return true
	end
	for _, value in model:GetAttributes() do
		if value == SETTINGS.preferredTrailer then
			return true
		end
	end
	return false
end

-- Every trailer this client has streamed in within `radius` of `near`: a model with a Kingpin attachment that is
-- no catalog car (the semi has a Kingpin too, and a VehicleId). Nearest first. One scan of the Workspace: an
-- occasional look by a dev tool, not a loop.
local function trailersNear(near: Vector3, radius: number): { Towable }
	local found: { Towable } = {}
	local seen: { [Model]: boolean } = {}
	for _, descendant in Workspace:GetDescendants() do
		if descendant:IsA("Attachment") and descendant.Name == KINGPIN then
			local part = descendant.Parent
			local model = if part then part:FindFirstAncestorOfClass("Model") :: Model? else nil
			if
				part
				and part:IsA("BasePart")
				and model
				and not seen[model]
				and model:GetAttribute(VEHICLE_ID) == nil
			then
				seen[model] = true
				local chassis = chassisOf(model) or part
				local distance = flatDistance(chassis.Position, near)
				if distance <= radius then
					table.insert(found, {
						model = model,
						chassis = chassis,
						point = descendant,
						parked = chassis.Anchored,
						preferred = isPreferred(model),
						distance = distance,
					})
				end
			end
		end
	end
	table.sort(found, function(a: Towable, b: Towable): boolean
		return a.distance < b.distance
	end)
	return found
end

-- The cars marked Towed (docs/phase-8-contracts.md) within `radius` of `near`, this player's own job props first
-- (Config/Jobs props: the owner's UserId, or job `jobId`), then nearest. Looks in Workspace.JobProps when it is
-- there, else everywhere.
local function towedCarsNear(near: Vector3, radius: number, jobId: string?): { Towable }
	local found: { Towable } = {}
	local root: Instance = Workspace:FindFirstChild(PROPS_FOLDER) or Workspace
	local mine: { [Model]: boolean } = {}
	for _, descendant in root:GetDescendants() do
		if descendant:IsA("Model") and descendant:GetAttribute(TOWED_ATTRIBUTE) == true then
			local chassis = chassisOf(descendant)
			local point = findAttachment(descendant, TOW_POINT)
			if chassis and point then
				local distance = flatDistance(chassis.Position, near)
				if distance <= radius then
					mine[descendant] = descendant:GetAttribute(OWNER_ATTRIBUTE) == Players.LocalPlayer.UserId
						or (jobId ~= nil and descendant:GetAttribute(JOB_ATTRIBUTE) == jobId)
					table.insert(found, {
						model = descendant,
						chassis = chassis,
						point = point,
						parked = chassis.Anchored,
						preferred = false,
						distance = distance,
					})
				end
			end
		end
	end
	table.sort(found, function(a: Towable, b: Towable): boolean
		if mine[a.model] ~= mine[b.model] then
			return mine[a.model] == true
		end
		return a.distance < b.distance
	end)
	return found
end

-- Looks for something round `position` with `find`, giving the map (and what stands on it) time to stream in.
local function lookAround(ctx: Context, position: Vector3, find: () -> { Towable }): { Towable }
	streamAround(position)
	for _ = 1, SETTINGS.streamRetries do
		local found = find()
		if #found > 0 or cancelRequested(ctx) then
			return found
		end
		task.wait(SETTINGS.streamRetrySeconds)
	end
	return find()
end

-- What the server shows coupled to `car` (HitchService): the TowingModel attribute (nil: nothing coupled) and the
-- Towing ObjectValue's model (nil until that model streams in).
local function towingOf(car: Model): (string?, Model?)
	local name = car:GetAttribute(TOWING_ATTRIBUTE)
	local holder = car:FindFirstChild(TOWING_VALUE) or car:FindFirstChild(TOWING_VALUE, true)
	local towed: Model? = nil
	if holder ~= nil and holder:IsA("ObjectValue") then
		local value = holder.Value
		if value ~= nil and value:IsA("Model") then
			towed = value
		end
	end
	return if type(name) == "string" and name ~= "" then name else nil, towed
end

-- The way a towed body points, seen from above: its chassis-to-coupling-point line (a trailer's Kingpin and a car's
-- TowPoint are at its front), else its chassis's LookVector.
local function towedHeading(chassis: BasePart, point: Attachment?): Vector3?
	if point ~= nil then
		local toward = flat(point.WorldPosition - chassis.Position)
		if toward.Magnitude >= SETTINGS.minAxisStuds then
			return toward.Unit
		end
	end
	local look = flat(chassis.CFrame.LookVector)
	return if look.Magnitude > EPSILON then look.Unit else nil
end

-- The hitch articulation in degrees: the tractor's heading against the towed body's, seen from above. Positive
-- when the towed body points to the tractor's left. nil when either has no heading.
local function articulationDegrees(tractor: BasePart, towed: BasePart, towedPoint: Attachment?): number?
	local ahead = flat(tractor.CFrame.LookVector)
	local behind = towedHeading(towed, towedPoint)
	if ahead.Magnitude < EPSILON or behind == nil then
		return nil
	end
	local unit = ahead.Unit
	-- Roblox's Y-up frame: a positive cross product's Y means `behind` lies to the left of `unit`.
	return math.deg(math.atan2(unit:Cross(behind).Y, unit:Dot(behind)))
end

-- Samples the hitch every frame while it runs (RunService.Heartbeat): the articulation, its largest per phase,
-- jackknife events over `threshold` degrees (nil: none counted), the gap between the coupling points and the
-- studs the tractor covers in the current phase.
local function startMonitor(
	ctx: Context,
	car: Model,
	towed: Model,
	tractorPointName: string,
	towedPointName: string,
	threshold: number?
): Monitor
	local started = os.clock()
	local over = false
	local last: Vector3? = nil
	local tractorPoint = findAttachment(car, tractorPointName)
	local towedPoint = findAttachment(towed, towedPointName)
	local monitor: Monitor
	monitor = {
		phase = "",
		maxDegrees = 0,
		maxByPhase = {},
		events = {},
		maxGap = 0,
		phaseStuds = 0,
		samples = 0,
		stop = function() end,
	}
	local lastPhase = monitor.phase
	local connection = RunService.Heartbeat:Connect(function()
		local chassis = car.PrimaryPart
		local towedChassis = chassisOf(towed)
		if chassis == nil or towedChassis == nil or chassis.Parent == nil then
			return
		end
		if tractorPoint == nil or tractorPoint.Parent == nil then
			tractorPoint = findAttachment(car, tractorPointName)
		end
		if towedPoint == nil or towedPoint.Parent == nil then
			towedPoint = findAttachment(towed, towedPointName)
		end
		if monitor.phase ~= lastPhase then
			lastPhase = monitor.phase
			monitor.phaseStuds = 0
			last = nil
		end
		local position = chassis.Position
		if last ~= nil then
			monitor.phaseStuds += flatDistance(position, last)
		end
		last = position
		if tractorPoint ~= nil and towedPoint ~= nil then
			monitor.maxGap = math.max(monitor.maxGap, (tractorPoint.WorldPosition - towedPoint.WorldPosition).Magnitude)
		end
		local degrees = articulationDegrees(chassis, towedChassis, towedPoint)
		if degrees == nil then
			return
		end
		local size = math.abs(degrees)
		monitor.samples += 1
		monitor.maxDegrees = math.max(monitor.maxDegrees, size)
		monitor.maxByPhase[monitor.phase] = math.max(monitor.maxByPhase[monitor.phase] or 0, size)
		if threshold == nil then
			return
		end
		if not over and size > threshold then
			over = true
			local mph = Units.studsToMph(flat(chassis.AssemblyLinearVelocity).Magnitude)
			table.insert(monitor.events, {
				phase = monitor.phase,
				at = round(os.clock() - started, 1),
				degrees = round(degrees, 1),
				mph = round(mph, 1),
			})
			print(`{LOG} {ctx.name}: jackknife ({monitor.phase}): {round(degrees, 1)} degrees at {round(mph, 1)} mph`)
		elseif over and size < threshold - SETTINGS.jackknifeHysteresis then
			over = false
		end
	end)
	monitor.stop = function()
		connection:Disconnect()
	end
	return monitor
end

-- Flat studs between a tractor's coupling point and the towed body's, or nil when either isn't there.
local function couplingGap(car: Model, carPoint: string, towed: Towable): number?
	local point = findAttachment(car, carPoint)
	return if point then flatDistance(point.WorldPosition, towed.point.WorldPosition) else nil
end

-- Holds the car still (HitchService couples a nearly still truck) and asks to couple, as the HUD does. True once
-- the server shows the coupling on the car (its TowingModel attribute).
local function coupleNow(ctx: Context, car: Model): (Reply?, boolean)
	AutoDriver.holdStill(SETTINGS.settleSeconds)
	local reply = call("TrailerAction", { action = "couple" })
	local coupled = waitFor(ctx, function(): boolean
		return towingOf(car) ~= nil
	end, car:GetAttributeChangedSignal(TOWING_ATTRIBUTE), SETTINGS.coupleTimeout)
	return reply, coupled
end

-- Holds still and asks to uncouple. True once the car's TowingModel attribute is gone.
local function uncoupleNow(ctx: Context, car: Model): (Reply?, boolean)
	AutoDriver.holdStill(SETTINGS.settleSeconds)
	local reply = call("TrailerAction", { action = "decouple" })
	local uncoupled = waitFor(ctx, function(): boolean
		return towingOf(car) == nil
	end, car:GetAttributeChangedSignal(TOWING_ATTRIBUTE), SETTINGS.coupleTimeout)
	return reply, uncoupled
end

---------------------------------------------------------------------------------------------------------------
-- Spawning and placing
---------------------------------------------------------------------------------------------------------------

-- Right-hand lane offset for the stretch a-b, from the lanes of the road under its middle (as Dev/RouteTests).
local function laneOffsetFor(a: Vector3, b: Vector3): number
	local edgeIndex = Graph.nearestEdge((a + b) / 2)
	local edge = if edgeIndex then Graph.edges()[edgeIndex] else nil
	return if edge then RouteTests.Math.rightLaneOffset(edge.lanes, World.laneWidth) else 0
end

-- The top of whatever solid thing is under `position` (from SETTINGS.probeUp above it), ignoring `ignore` and the
-- local character, and the part it is; nil when there is nothing within SETTINGS.probeDown.
local function surfaceBelow(position: Vector3, ignore: { Instance }): (number?, BasePart?)
	local list = table.clone(ignore)
	local character = Players.LocalPlayer.Character
	if character then
		table.insert(list, character)
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = list
	params.RespectCanCollide = true
	local origin = position + Vector3.yAxis * SETTINGS.probeUp
	local hit = Workspace:Raycast(origin, Vector3.yAxis * -(SETTINGS.probeUp + SETTINGS.probeDown), params)
	if hit == nil then
		return nil, nil
	end
	return hit.Position.Y, hit.Instance
end

-- The collidable parts a box of `size` at `cframe` would overlap, for a body in collision group `group`: among
-- `include` when given, else everything but `exclude`. Uses a throwaway query part on this client only.
local function overlapping(
	cframe: CFrame,
	size: Vector3,
	group: string,
	include: { Instance }?,
	exclude: { Instance }?
): { BasePart }
	local probe = Instance.new("Part")
	probe.Name = PROBE_NAME
	probe.Anchored = true
	probe.CanCollide = false
	probe.CanTouch = false
	probe.CanQuery = false
	probe.Transparency = 1
	probe.Size = size
	probe.CFrame = cframe
	probe.Parent = Workspace
	local params = OverlapParams.new()
	if include ~= nil then
		params.FilterType = Enum.RaycastFilterType.Include
		params.FilterDescendantsInstances = include
	else
		local list = if exclude then table.clone(exclude) else {}
		table.insert(list, probe)
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = list
	end
	params.RespectCanCollide = true
	params.CollisionGroup = group
	local hits = Workspace:GetPartsInPart(probe, params)
	probe:Destroy()
	return hits
end

-- The truck's coupling point and chassis, measured on `car` (nil when it lacks either).
local function rigGeometry(car: Model, pointName: string): RigGeometry?
	local chassis = car.PrimaryPart
	local point = findAttachment(car, pointName)
	local vehicleId, trim = carIdentity(car)
	local geometry = if vehicleId and trim then Catalog.geometry(vehicleId, trim) else nil
	if chassis == nil or point == nil or geometry == nil then
		return nil
	end
	-- The model pivot is the ground under the chassis (VehicleBuilder: PivotOffset = (0, -height, 0)).
	local height = -chassis.PivotOffset.Position.Y
	return {
		coupleLocal = chassis.CFrame:PointToObjectSpace(point.WorldPosition),
		chassisSize = chassis.Size,
		chassisHeight = if height > EPSILON then height else chassis.Size.Y / 2,
		length = geometry.length,
		collisionGroup = chassis.CollisionGroup,
	}
end

-- Where the character stands so DevSpawnVehicle puts a car of this trim in the right-hand lane in the middle of
-- the open road nearest `near`, facing along it (as Dev/JobTests). Returns the stand pose and the road's name.
local function openRoadStand(near: Vector3, vehicleId: string, trimId: string): (CFrame?, string)
	local geometry = Catalog.geometry(vehicleId, trimId)
	if geometry == nil then
		return nil, "no geometry for the car"
	end
	local edges = Graph.edges()
	local bestIndex: number? = nil
	local bestDistance = math.huge
	for index, edge in edges do
		if
			table.find(SETTINGS.startKinds, edge.kind) ~= nil
			and edge.surface ~= "dirt"
			and Graph.edgeLength(index) >= SETTINGS.minStartEdge
		then
			local distance = flatDistance(Graph.pointOnEdge(index, 0.5), near)
			if distance < bestDistance then
				bestIndex, bestDistance = index, distance
			end
		end
	end
	if bestIndex == nil then
		return nil, "no open road long enough"
	end
	local edge = edges[bestIndex]
	local from, to = Graph.node(edge.from), Graph.node(edge.to)
	if from == nil or to == nil then
		return nil, "the road's nodes are missing"
	end
	local along = flat(to.position - from.position)
	if along.Magnitude < EPSILON then
		return nil, "the road has no length"
	end
	local heading = along.Unit
	local right = Vector3.new(-heading.Z, 0, heading.X)
	local carCentre = Graph.pointOnEdge(bestIndex, 0.5)
		+ right * RouteTests.Math.rightLaneOffset(edge.lanes, World.laneWidth)
	local stand = carCentre
		- heading * (Spawning.spawnOffset + geometry.length / 2)
		+ Vector3.yAxis * SETTINGS.standHeight
	return CFrame.lookAt(stand, stand + heading), `{edge.kind} {edge.from} -> {edge.to}`
end

-- Sits the player in a fresh `vehicleId`/`trim` spawned by DevSpawnVehicle from where the character stands at
-- `stand`: gets out of any car, moves the character there (with the map streamed in round it), gives the server
-- time to see it there, and spawns. Returns the car, or nil and why.
local function spawnFrom(ctx: Context, vehicleId: string, trim: string, stand: CFrame): (Model?, string?)
	local humanoid = humanoidOf()
	local character = Players.LocalPlayer.Character
	if humanoid == nil or character == nil then
		return nil, "no character"
	end
	local seatSignal = humanoid:GetPropertyChangedSignal("SeatPart")
	if humanoid.SeatPart ~= nil then
		AutoDriver.stop()
		humanoid.Sit = false
		humanoid.Jump = true
		if
			not waitFor(ctx, function(): boolean
				return humanoid.SeatPart == nil
			end, seatSignal, SETTINGS.exitTimeout)
		then
			return nil, "couldn't get out of the car"
		end
		-- The server stands the character beside the car it left; move only after that.
		task.wait(SETTINGS.settleSeconds)
	end
	streamAround(stand.Position)
	character:PivotTo(stand)
	task.wait(SETTINGS.standSettleSeconds)

	local previous = currentCar()
	ensureNet()
	Net.fireServer("DevSpawnVehicle", { vehicleId = vehicleId, trim = trim })
	local seated = waitFor(ctx, function(): boolean
		local car = currentCar()
		if car == nil or car == previous then
			return false
		end
		local id, trimId = carIdentity(car)
		return id == vehicleId and trimId == trim
	end, seatSignal, SETTINGS.spawnTimeout)
	if not seated then
		return nil, `{vehicleId}/{trim} didn't spawn with you in it (is its model in ServerStorage.VehicleModels?)`
	end
	-- The game's DriveController starts once the car has arrived on this client.
	task.wait(SETTINGS.settleSeconds)
	return currentCar(), nil
end

local function spawnOnRoad(ctx: Context, vehicleId: string, trim: string, near: Vector3): (Model?, string?)
	local stand, road = openRoadStand(near, vehicleId, trim)
	if stand == nil then
		return nil, road
	end
	setCurrent(ctx, `spawning {vehicleId}/{trim} on the {road}`)
	return spawnFrom(ctx, vehicleId, trim, stand)
end

-- Sits the player in `vehicleId`/`trim` (the car they sit in when it is one, else a fresh one on the open road
-- nearest `near`) and measures it. Returns the car and its geometry, or nil and why.
local function rigFor(
	ctx: Context,
	vehicleId: string,
	trim: string,
	pointName: string,
	near: Vector3
): (Model?, RigGeometry?, string?)
	local car = currentCar()
	local id, trimId = nil, nil
	if car then
		id, trimId = carIdentity(car)
	end
	if car == nil or id ~= vehicleId or trimId ~= trim then
		local spawned, why = spawnOnRoad(ctx, vehicleId, trim, near)
		if spawned == nil then
			return nil, nil, why
		end
		car = spawned
	end
	local driven = car :: Model
	if waitForAttachment(ctx, driven, pointName) == nil then
		return nil, nil, `{vehicleId}/{trim} has no {pointName} attachment (rebuild it with Dev/VehicleBuilder)`
	end
	local rig = rigGeometry(driven, pointName)
	if rig == nil then
		return nil, nil, `couldn't measure {vehicleId}/{trim} (no chassis or catalog geometry)`
	end
	return driven, rig, nil
end

-- Where the semi's chassis goes so its Kingpin sits on the trailer's, facing the way the trailer faces: slid
-- forward SETTINGS.slideStep at a time (at most SETTINGS.maxSlide) until its chassis box clears the trailer's
-- collidable parts and no part of the trailer is above its centre (VehicleService sets a spawned car down on the
-- first solid thing under that point, which would be the trailer's nose), then checked against everything else.
local function semiPlacement(trailer: Towable, rig: RigGeometry): Placement?
	local heading = towedHeading(trailer.chassis, trailer.point)
	if heading == nil then
		return nil
	end
	-- The Kingpin's offset from the chassis centre, turned to face `heading`: chassis space has X to the right and
	-- Z to the back (a car faces -Z), and right is heading x up.
	local right = heading:Cross(Vector3.yAxis)
	local reach = right * rig.coupleLocal.X - heading * rig.coupleLocal.Z
	local base = flat(trailer.point.WorldPosition) - reach
	local pinHeight = trailer.point.WorldPosition.Y
	local others: { Instance } = {}
	local driven = currentCar()
	if driven then
		table.insert(others, driven)
	end
	local ignore: { Instance } = table.clone(others)
	table.insert(ignore, trailer.model)
	local function frameAt(slid: number): (CFrame, BasePart?, boolean)
		local centre = base + heading * slid
		local probe = Vector3.new(centre.X, pinHeight, centre.Z)
		local ground, part = surfaceBelow(probe, ignore)
		-- No ground found: put it where its Kingpin height says the ground is.
		local groundY = ground or (pinHeight - rig.coupleLocal.Y - rig.chassisHeight)
		local position = Vector3.new(centre.X, groundY + rig.chassisHeight, centre.Z)
		local _, top = surfaceBelow(probe, others)
		local under = top ~= nil and top:IsDescendantOf(trailer.model)
		return CFrame.lookAt(position, position + heading), part, under
	end

	local trailerOnly: { Instance } = { trailer.model }
	local slid = 0
	local frame, groundPart, under = frameAt(slid)
	while under or #overlapping(frame, rig.chassisSize, rig.collisionGroup, trailerOnly, nil) > 0 do
		slid += SETTINGS.slideStep
		if slid > SETTINGS.maxSlide then
			return { frame = frame, slid = slid - SETTINGS.slideStep, clear = false, blocker = trailer.model.Name }
		end
		frame, groundPart, under = frameAt(slid)
	end
	local exclude: { Instance } = table.clone(ignore)
	table.insert(exclude, Workspace.Terrain)
	if groundPart then
		table.insert(exclude, groundPart)
	end
	local hits = overlapping(frame, rig.chassisSize, rig.collisionGroup, nil, exclude)
	return {
		frame = frame,
		slid = slid,
		clear = #hits == 0,
		blocker = if #hits > 0 then hits[1]:GetFullName() else nil,
	}
end

-- Where the character stands for DevSpawnVehicle to put the semi's chassis at `frame`: Spawning.spawnOffset + half
-- its length behind it, on whatever surface is there (the trailer's roof, usually), facing the same way.
local function standFor(frame: CFrame, rig: RigGeometry): CFrame
	local heading = flat(frame.LookVector).Unit
	local spot = frame.Position - heading * (Spawning.spawnOffset + rig.length / 2)
	local ignore: { Instance } = {}
	local driven = currentCar()
	if driven then
		table.insert(ignore, driven)
	end
	local top = surfaceBelow(spot, ignore)
	local y = (top or frame.Position.Y - rig.chassisHeight) + SETTINGS.standHeight
	local stand = Vector3.new(spot.X, y, spot.Z)
	return CFrame.lookAt(stand, stand + heading)
end

-- The idle trailers at `depot`, in the order to try them. Idle: parked (anchored), no job's prop (a delivered
-- trailer is removed a few seconds after its drop), and standing on one of the depot's TrailerSpawn spots when it
-- has any. Order: `toward` first puts the one nearest that point (a job's own spot); else "box" puts box trailers
-- first (loop(), decoupleOutside()) and "first" goes by the depot's spots in Config/MapLayout order (freight():
-- Freight's offers take the first spot with an idle trailer). Then nearest the depot.
local function idleTrailersAt(
	ctx: Context,
	depot: MapLayout.Location,
	prefer: "box" | "first",
	toward: Vector3?
): ({ Towable }, string?)
	local spots = spotsOf(depot)
	local centre = if #spots > 0 then spots[1].position else depot.position
	local all = lookAround(ctx, centre, function(): { Towable }
		return trailersNear(depot.position, SETTINGS.depotRadius)
	end)
	-- Which of the depot's spots (by its index in map order) a trailer stands on; 0 with no spots, nil off them.
	local function spotIndex(trailer: Towable): number?
		if #spots == 0 then
			return 0
		end
		for index, spot in spots do
			if outsideDistance(spot, trailer.chassis.Position) <= SETTINGS.spotSlack then
				return index
			end
		end
		return nil
	end
	local idle: { Towable } = {}
	local order: { [Model]: number } = {}
	for _, trailer in all do
		local index = spotIndex(trailer)
		if trailer.parked and trailer.model:GetAttribute(JOB_ATTRIBUTE) == nil and index ~= nil then
			table.insert(idle, trailer)
			order[trailer.model] = index
		end
	end
	if #idle == 0 then
		local where = `{depot.displayName} ({#spots} TrailerSpawn spot(s), {SETTINGS.depotRadius} studs round)`
		if #all > 0 then
			return idle, `none of the {#all} trailer(s) at {where} stands idle on a spot`
		end
		return idle, `no trailer at {where}: HitchService stands an idle one on each spot at Start`
	end
	table.sort(idle, function(a: Towable, b: Towable): boolean
		if toward ~= nil then
			return flatDistance(a.chassis.Position, toward) < flatDistance(b.chassis.Position, toward)
		end
		if prefer == "box" and a.preferred ~= b.preferred then
			return a.preferred
		end
		if prefer == "first" and order[a.model] ~= order[b.model] then
			return order[a.model] < order[b.model]
		end
		return a.distance < b.distance
	end)
	return idle, nil
end

-- Spawns the semi in front of one of `trailers` (the first whose spot in front is clear; else the first, noted)
-- with its Kingpin on the trailer's. Returns what was placed, or nil and why.
local function placeSemi(ctx: Context, trailers: { Towable }, vehicleId: string, trim: string): (Placed?, string?)
	local first = trailers[1]
	if first == nil then
		return nil, "no trailer to put the semi at"
	end
	setCurrent(ctx, `measuring {vehicleId}/{trim}`)
	local _, rig, why = rigFor(ctx, vehicleId, trim, KINGPIN, first.chassis.Position)
	if rig == nil then
		return nil, why
	end
	local chosen: Towable? = nil
	local placement: Placement? = nil
	for _, trailer in trailers do
		local candidate = semiPlacement(trailer, rig)
		if candidate ~= nil and candidate.clear then
			chosen, placement = trailer, candidate
			break
		end
		if chosen == nil and candidate ~= nil then
			chosen, placement = trailer, candidate
		end
	end
	if chosen == nil or placement == nil then
		return nil, "none of the trailers has a heading to line up with"
	end
	if not placement.clear then
		note(ctx, `the spot in front of {chosen.model.Name} isn't clear ({placement.blocker or "?"}); spawning anyway`)
	end
	setCurrent(ctx, `putting the semi in front of {chosen.model.Name} (slid {round(placement.slid, 1)} studs)`)
	local car, spawnWhy = spawnFrom(ctx, vehicleId, trim, standFor(placement.frame, rig))
	if car == nil then
		return nil, spawnWhy
	end
	if waitForAttachment(ctx, car, KINGPIN) == nil then
		return nil, `the spawned {vehicleId} has no {KINGPIN}`
	end
	local gap = couplingGap(car, KINGPIN, chosen) or math.huge
	return { car = car, trailer = chosen, rig = rig, placement = placement, gap = gap }, nil
end

---------------------------------------------------------------------------------------------------------------
-- Driving
---------------------------------------------------------------------------------------------------------------

local function failedReport(reason: string): AutoDriver.Report
	return { completed = false, elapsed = 0, stuckEvents = 0, maxMph = 0, reason = reason, pointsReached = 0 }
end

local function arrivedReport(): AutoDriver.Report
	return { completed = true, elapsed = 0, stuckEvents = 0, maxMph = 0, reason = "arrived", pointsReached = 0 }
end

-- Drives `points` with the AutoDriver at `mph`, its timeout scaled from their length. Returns the report and the
-- length.
local function drivePoints(
	points: { Vector3 },
	mph: number,
	stopAtEnd: boolean,
	arriveRadius: number?
): (AutoDriver.Report, number)
	local pose = carPose()
	if pose == nil then
		return failedReport("not driving"), 0
	end
	if #points == 0 then
		return arrivedReport(), 0
	end
	local length = RouteTests.Math.length(pose.Position, points)
	local report = AutoDriver.drive(points, {
		targetMph = mph,
		timeout = RouteTests.Math.timeoutFor(length, mph),
		arriveRadius = arriveRadius,
		stopAtEnd = stopAtEnd,
	})
	return report, length
end

-- The point on a road centre line nearest `position`: arrival counts from there as well as from the stop.
local function roadPointNear(position: Vector3): Vector3
	local _, _, _, point = Graph.nearestEdge(position)
	return point
end

-- How far `position` is from a stop, counting the stop's road point as the stop (JobService's arrival rule).
local function distanceToStop(position: Vector3, stop: StopView): number
	return math.min(flatDistance(position, stop.position), flatDistance(position, roadPointNear(stop.position)))
end

-- Pathfind's route through `targets` in order, each leg starting the way the last one ended, in right-hand lanes.
-- Then, when the last target is off the road, a straight pull-in toward it; and, with `behind` > 0, on along that
-- line so a coupling point `behind` studs behind the chassis centre ends over the target rather than the cab.
-- Nil when there is no route.
local function routeThrough(pose: CFrame, targets: { Vector3 }, behind: number): { Vector3 }?
	local raw: { Vector3 } = {}
	local from, heading = pose.Position, pose.LookVector
	for _, target in targets do
		local route = Pathfind.route(from, target, heading)
		if route == nil then
			return nil
		end
		for _, point in route.points do
			if #raw == 0 or flatDistance(point, raw[#raw]) > SAME_POINT then
				table.insert(raw, point)
			end
		end
		local count = #raw
		if count >= 2 then
			local step = flat(raw[count] - raw[count - 1])
			if step.Magnitude > EPSILON then
				heading = step.Unit
			end
		end
		from = raw[count] or from
	end
	local points = RouteTests.Math.keepRight(raw, laneOffsetFor, SETTINGS.maxMiter)
	if #targets == 0 then
		return points
	end
	local last = if #points > 0 then points[#points] else pose.Position
	local final = targets[#targets]
	local finalPoint = Vector3.new(final.X, last.Y, final.Z)
	local toward = flat(finalPoint - last)
	local direction = flat(heading)
	if toward.Magnitude > SETTINGS.pullInMin then
		table.insert(points, finalPoint)
		direction = toward
	end
	if behind > EPSILON and direction.Magnitude > EPSILON then
		table.insert(points, finalPoint + direction.Unit * behind)
	end
	return points
end

-- The County Loop for one lap from the node nearest `pose`, in the direction that carries straight on from the way
-- the car faces, closing at that node (right-hand lanes).
local function lapPoints(pose: CFrame): ({ Vector3 }?, number)
	local positions = loopPositions()
	local count = #positions
	if count < 3 then
		return nil, 0
	end
	local startIndex, nearest = 1, math.huge
	for index, position in positions do
		local distance = flatDistance(position, pose.Position)
		if distance < nearest then
			startIndex, nearest = index, distance
		end
	end
	local forward = flat(pose.LookVector)
	local towardNext = flat(positions[startIndex % count + 1] - pose.Position)
	local towardPrevious = flat(positions[(startIndex - 2) % count + 1] - pose.Position)
	local direction = if towardNext.Magnitude > EPSILON
			and towardPrevious.Magnitude > EPSILON
			and forward:Dot(towardPrevious.Unit) > forward:Dot(towardNext.Unit)
		then -1
		else 1
	local lap: { Vector3 } = {}
	for _, index in RouteTests.Math.lapOrder(count, startIndex, direction) do
		table.insert(lap, positions[index])
	end
	return RouteTests.Math.keepRight(lap, laneOffsetFor, SETTINGS.maxMiter), startIndex
end

---------------------------------------------------------------------------------------------------------------
-- Breakdowns: where Towing will stand its car, and the pickup put in front of it
---------------------------------------------------------------------------------------------------------------

-- A car that can break down (JobService/Towing.breakdownCars): a catalog car of a Config/Jobs towing
-- breakdownClasses class, in its first trim.
type BreakdownCar = { vehicleId: string, trim: string, displayName: string, length: number }

local function breakdownCars(): { BreakdownCar }
	local def: any = Jobs.types[TOWING_JOB]
	local classes: { string } = if def ~= nil and type(def.breakdownClasses) == "table"
		then def.breakdownClasses
		else {}
	local cars: { BreakdownCar } = {}
	for _, vehicleId in Catalog.vehicleIds() do
		local vehicle = Catalog.getVehicle(vehicleId)
		local trim = Catalog.defaultTrim(vehicleId)
		local geometry = if trim then Catalog.geometry(vehicleId, trim.id) else nil
		if vehicle ~= nil and trim ~= nil and geometry ~= nil and table.find(classes, vehicle.class) ~= nil then
			table.insert(cars, {
				vehicleId = vehicleId,
				trim = trim.id,
				displayName = vehicle.displayName,
				length = geometry.length,
			})
		end
	end
	return cars
end

-- The longest of the cars that can break down: what the pickup is placed for before an offer names one, so no car
-- that turns up (even one the offer's title doesn't name, or Towing's fallback car) can stand into it.
local function longestLength(cars: { BreakdownCar }): number?
	local longest: number? = nil
	for _, car in cars do
		longest = math.max(longest or 0, car.length)
	end
	return longest
end

-- The car a towing offer names (Towing's title, "Tow a <car>"); the longest name wins where one holds another.
local function offeredCar(offer: OfferView, cars: { BreakdownCar }): BreakdownCar?
	local best: BreakdownCar? = nil
	for _, car in cars do
		if string.find(offer.title, car.displayName, 1, true) ~= nil then
			if best == nil or #car.displayName > #best.displayName then
				best = car
			end
		end
	end
	return best
end

-- The Breakdown spot a towing offer names (Towing's subtitle, "Broken down at <spot>"); the longest name wins.
local function offeredSpot(offer: OfferView): MapLayout.Location?
	local best: MapLayout.Location? = nil
	for _, spot in locationsTagged(BREAKDOWN_TAG) do
		if string.find(offer.subtitle, spot.displayName, 1, true) ~= nil then
			if best == nil or #spot.displayName > #best.displayName then
				best = spot
			end
		end
	end
	return best
end

-- The Breakdown spot `id` (opts.breakdown), else the one nearest `near`.
local function chooseBreakdown(id: string?, near: Vector3?): (MapLayout.Location?, string?)
	if id ~= nil then
		local location = locationsById[id]
		if location == nil or location.tag ~= BREAKDOWN_TAG then
			return nil, `"{id}" isn't a Breakdown spot in Config/MapLayout`
		end
		return location, nil
	end
	local spots = locationsTagged(BREAKDOWN_TAG)
	if #spots == 0 then
		return nil, "Config/MapLayout has no Breakdown spot"
	end
	return nearestOf(spots, near or Vector3.zero), nil
end

-- Where Towing will stand a broken-down car on `spot` (JobService/Towing.poseAt, mirrored: a server module can't
-- be required on the client): its chassis centre on the ground, and the way it faces. A spot runs along its road
-- (its X axis); the car faces along the nearest road the way traffic on that side runs (the shoulder on its
-- right), set back from the spot's centre by Config/Jobs props.breakdownSetBack of the spot's length.
local function breakdownPose(spot: MapLayout.Location): (Vector3, Vector3)
	local position = spot.position
	local along = CFrame.Angles(0, math.rad(spot.yaw), 0).RightVector
	local edge, t, _, point = Graph.nearestEdge(position)
	if edge ~= nil then
		local ahead = Graph.pointOnEdge(edge, math.min(t + SETTINGS.roadStep, 1))
		local behind = Graph.pointOnEdge(edge, math.max(t - SETTINGS.roadStep, 0))
		local direction = flat(ahead - behind)
		if direction.Magnitude >= SETTINGS.minDirection then
			along = direction.Unit
			if along:Cross(Vector3.yAxis):Dot(flat(position - point)) < 0 then
				along = -along -- the shoulder is on the left of that way: face the other way
			end
		end
	end
	return position - along * (spot.size.X * numberOf(propsConfig.breakdownSetBack)), along
end

-- Where the TowPoint of a car `length` long standing at `at` facing `along` will be, seen from above:
-- Config/Trailers.towed.towPointAhead in front of its chassis's front face (Dev/VehicleBuilder builds every chassis
-- the catalog length long and puts the TowPoint there).
local function towPointAt(at: Vector3, along: Vector3, length: number, ahead: number): Vector3
	return flat(at) + along * (length / 2 + ahead)
end

-- Spawns the pickup on `spot` facing the way its broken-down car will, with its TowHitch SETTINGS.towGap ahead of
-- where the TowPoint of a car `length` long will be. Returns the pickup, its geometry and its hitch's place seen
-- from above, or nil and why.
local function placePickup(
	ctx: Context,
	spot: MapLayout.Location,
	length: number,
	vehicleId: string,
	trim: string
): (Model?, RigGeometry?, Vector3?, string?)
	local ahead = trailersNumber("towPointAhead")
	if ahead == nil then
		return nil, nil, nil, "Config/Trailers has no towed.towPointAhead (where a car's TowPoint is)"
	end
	setCurrent(ctx, `measuring {vehicleId}/{trim}`)
	local _, rig, why = rigFor(ctx, vehicleId, trim, TOW_HITCH, spot.position)
	if rig == nil then
		return nil, nil, nil, why
	end
	local at, along = breakdownPose(spot)
	local hitchAt = towPointAt(at, along, length, ahead) + along * SETTINGS.towGap
	-- The hitch's offset from the chassis centre, turned to face `along` (X right, Z back; right is along x up).
	local right = along:Cross(Vector3.yAxis)
	local centre = hitchAt - (right * rig.coupleLocal.X - along * rig.coupleLocal.Z)
	local ignore: { Instance } = {}
	local driven = currentCar()
	if driven then
		table.insert(ignore, driven)
	end
	local ground = surfaceBelow(Vector3.new(centre.X, spot.position.Y, centre.Z), ignore)
	local position = Vector3.new(centre.X, (ground or spot.position.Y) + rig.chassisHeight, centre.Z)
	local frame = CFrame.lookAt(position, position + along)
	setCurrent(ctx, `putting the pickup on {spot.displayName}, ahead of where a {round(length, 1)}-stud car will stand`)
	local truck, spawnWhy = spawnFrom(ctx, vehicleId, trim, standFor(frame, rig))
	if truck == nil then
		return nil, nil, nil, spawnWhy
	end
	local hitch = waitForAttachment(ctx, truck, TOW_HITCH)
	if hitch == nil then
		return nil, nil, nil, `the spawned {vehicleId} has no {TOW_HITCH}`
	end
	return truck, rig, flat(hitch.WorldPosition), nil
end

-- The cruise for a hauling leg: opts.mph, else SETTINGS.cruisePerAverage x the calibrated average speed for it
-- (towMph with a car in tow; freightMph on a short run, longHaulMph through long-haul waypoints).
local function cruiseFor(kind: HaulKind, longHaul: boolean, opts: Options): number
	if opts.mph ~= nil then
		return opts.mph
	end
	local reference = Jobs.calibration.referenceMph
	local average = if kind == "towing"
		then calibratedMph("towMph", reference)
		elseif longHaul then calibratedMph("longHaulMph", reference)
		else calibratedMph("freightMph", reference)
	return average * SETTINGS.cruisePerAverage
end

---------------------------------------------------------------------------------------------------------------
-- Offers and licenses
---------------------------------------------------------------------------------------------------------------

-- Chooses an offer among those listed (nil: none fits).
type Picker = (offers: { OfferView }) -> OfferView?

-- The first freight offer that starts at `depot` (its subtitle names it), else the first freight offer.
local function freightFrom(depot: MapLayout.Location?): Picker
	return function(offers: { OfferView }): OfferView?
		local first: OfferView? = nil
		for _, offer in offers do
			if offer.type == FREIGHT_JOB then
				first = first or offer
				if depot ~= nil and originOf(offer) == depot then
					return offer
				end
			end
		end
		return first
	end
end

-- The first towing offer at Breakdown spot `spot` (its subtitle names it).
local function towingAt(spot: MapLayout.Location): Picker
	return function(offers: { OfferView }): OfferView?
		for _, offer in offers do
			if offer.type == TOWING_JOB and offeredSpot(offer) == spot then
				return offer
			end
		end
		return nil
	end
end

-- Refreshes the offers until `pick` finds one (Config/Jobs offers.minRefreshSec apart), at most `tries` times
-- (default SETTINGS.offerTries). A cooldown the server reports for the type is waited out (not counted as a try);
-- any other reason it can't offer the type (no car, wrong class, no license) ends the search. Returns the offer, or
-- nil and why, and when the last cooldown ended.
local function findOffer(ctx: Context, jobType: string, pick: Picker, tries: number?): (OfferView?, string?, number?)
	local watch = ctx.watch
	local cooledAt: number? = nil
	local limit = tries or SETTINGS.offerTries
	local made = 0
	while made < limit do
		if cancelRequested(ctx) then
			return nil, "stopped", cooledAt
		end
		refresh(ctx, SETTINGS.updateTimeout)
		local offer = if watch.job == nil and watch.offers ~= nil then pick(watch.offers) else nil
		if offer then
			return offer, nil, cooledAt
		end
		local availability = watch.availability[jobType]
		if availability ~= nil and not availability.ok then
			local _, seconds = string.match(availability.reason, COOLDOWN_PATTERN)
			local cooldown = tonumber(seconds)
			if cooldown == nil then
				return nil, `the server offers no {jobType} jobs: "{availability.reason}"`, cooledAt
			end
			setCurrent(ctx, `{jobType} cooldown: waiting {cooldown} s`)
			task.wait(cooldown + SETTINGS.cooldownSlack)
			cooledAt = os.clock()
		else
			made += 1
			task.wait(Jobs.offers.minRefreshSec)
		end
	end
	local active = if watch.job then ` (a job is active: "{watch.job.title}")` else ""
	return nil, `no fitting {jobType} offer after {limit} refreshes{active}`, cooledAt
end

type Accepted = {
	job: JobView?, -- nil: not accepted (see failure)
	offer: OfferView,
	acceptedAt: number, -- os.clock() just before the accept that worked
	cashBefore: number,
	failure: string?,
}

-- Accepts `offer` and waits for the JobUpdate that shows the job. A cooldown refusal is waited out once, with a
-- fresh offer after it.
local function acceptOffer(ctx: Context, jobType: string, offer: OfferView, pick: Picker): Accepted
	local watch = ctx.watch
	local accepted: Accepted = { job = nil, offer = offer, acceptedAt = os.clock(), cashBefore = cash() }
	for attempt = 1, 2 do
		accepted.acceptedAt = os.clock()
		accepted.cashBefore = cash()
		local reply = jobAction({ action = "accept", offerId = accepted.offer.id })
		if reply and reply.ok then
			local shown = waitFor(ctx, function(): boolean
				return watch.job ~= nil
			end, watch.changed.Event, SETTINGS.updateTimeout)
			if shown then
				accepted.job = watch.job
			else
				accepted.failure = "accepted, but no JobUpdate showed the job"
			end
			return accepted
		end
		local _, seconds = string.match(if reply then reply.message else "", COOLDOWN_PATTERN)
		local cooldown = tonumber(seconds)
		if attempt > 1 or cooldown == nil then
			accepted.failure = `accept {describe(reply)}`
			return accepted
		end
		setCurrent(ctx, `cooldown: waiting {cooldown} s`)
		task.wait(cooldown + SETTINGS.cooldownSlack)
		local fresh, why = findOffer(ctx, jobType, pick)
		if fresh == nil then
			accepted.failure = why
			return accepted
		end
		accepted.offer = fresh
	end
	return accepted
end

-- Cancels job `jobId` and waits out the cooldown that starts (it isn't counted anywhere). Returns the reply.
local function cancelJob(ctx: Context, jobId: string, jobType: string): Reply?
	local reply = jobAction({ action = "cancel", jobId = jobId })
	local _, seconds = string.match(if reply then reply.message else "", CANCELLED_PATTERN)
	local def = Jobs.types[jobType]
	local wait = tonumber(seconds) or (if def then def.cooldownSec else 0)
	if not cancelRequested(ctx) then
		setCurrent(ctx, `waiting out the {wait} s cooldown`)
		task.wait(wait + SETTINGS.cooldownSlack)
	end
	return reply
end

-- Cancels a job left over from before the test (changing car would fail it anyway). The server always answers a
-- refresh with a JobUpdate during a job.
local function clearActiveJob(ctx: Context)
	refresh(ctx, SETTINGS.stateTimeout)
	local job = ctx.watch.job
	if job ~= nil then
		note(ctx, `cancelling a job left over from before ({job.title})`)
		cancelJob(ctx, job.id, job.type)
	end
end

-- Makes sure the player holds the freight license. The JobUpdate says which licenses they hold; without it,
-- BuyLicense (idempotent) is asked. Short of cash, DevSetCash (Studio) adds the price and it is asked again; a
-- refusal with the cash there is the XP gate (Config/Jobs.freightLicense.xpRequired in delivery or towing):
-- DevJob grantLicenseXp (Studio) raises the XP to it and it is asked once more. Returns whether the license is
-- held, and what happened.
local function ensureFreightLicense(ctx: Context): (boolean, string)
	local watch = ctx.watch
	refresh(ctx, SETTINGS.stateTimeout)
	if watch.licenses[FREIGHT_JOB] == true then
		return true, "already held"
	end
	local license: any = jobsConfig.freightLicense
	local price = if type(license) == "table" and type(license.price) == "number"
		then license.price
		else Economy.freightLicensePrice
	setCurrent(ctx, "buying the freight license (BuyLicense)")
	local before = cash()
	local reply = call("BuyLicense", { license = FREIGHT_JOB })
	if reply ~= nil and reply.ok then
		return true, `BuyLicense {describe(reply)} (cash {before} -> {cash()})`
	end
	local firstReply = describe(reply)
	if cash() < price then
		local amount = math.floor(cash() + price)
		local set = call("DevSetCash", { amount = amount })
		note(ctx, `cash short of the ${price} license: DevSetCash {amount} {describe(set)}`)
		reply = call("BuyLicense", { license = FREIGHT_JOB })
		if reply ~= nil and reply.ok then
			return true, `bought after a Studio cash top-up: {describe(reply)}`
		end
	end
	-- Maybe it was held all along and the reply just says so: offers would show it.
	refresh(ctx, SETTINGS.stateTimeout)
	if watch.licenses[FREIGHT_JOB] == true then
		return true, `held (BuyLicense {describe(reply)})`
	end
	-- The XP gate: Studio grants the XP, then it is asked again.
	local granted = call("DevJob", { action = "grantLicenseXp" })
	note(ctx, `short of the license XP: DevJob grantLicenseXp {describe(granted)}`)
	if granted ~= nil and granted.ok then
		if cash() < price then
			call("DevSetCash", { amount = math.floor(cash() + price) })
		end
		reply = call("BuyLicense", { license = FREIGHT_JOB })
		if reply ~= nil and reply.ok then
			return true, `bought after a Studio XP grant: {describe(reply)}`
		end
	end
	local needed = if type(license) == "table" and type(license.xpRequired) == "number"
		then tostring(license.xpRequired)
		else "?"
	local delivery = watch.progress.delivery
	local towing = watch.progress.towing
	return false,
		`BuyLicense {firstReply}{if reply ~= nil then ", then " .. describe(reply) else ""}: delivery XP `
			.. `{if delivery then delivery.xp else "?"}, towing XP {if towing then towing.xp else "?"}, `
			.. `{needed} needed in either, and the Studio XP grant didn't get it ({describe(granted)})`
end

---------------------------------------------------------------------------------------------------------------
-- Driving a job
---------------------------------------------------------------------------------------------------------------

local function newLeg(index: number, kind: string, label: string): Leg
	return {
		index = index,
		kind = kind,
		label = label,
		routeStuds = 0,
		driveSeconds = 0,
		waitSeconds = 0,
		seconds = 0,
		mph = 0,
		maxMph = 0,
		stuckEvents = 0,
		askedArrive = false,
		teleported = false,
		reason = "advanced",
	}
end

local function newRun(jobType: string, offer: OfferView, stops: number): JobRun
	return {
		type = jobType,
		title = offer.title,
		subtitle = offer.subtitle,
		offerPay = round(offer.pay, 0),
		offerDistance = round(offer.distance, 0),
		stops = stops,
		completed = false,
		pay = 0,
		driveEarnPaid = 0,
		seconds = 0,
		cycleSeconds = 0,
		creditedSeconds = 0,
		perMinute = 0,
		routeStuds = 0,
		xpGained = 0,
		originTries = 1,
		coupled = false,
		uncoupled = false,
		maxArticulation = 0,
		jackknifes = 0,
		legs = {},
		reason = "",
	}
end

local function applyReport(leg: Leg, report: AutoDriver.Report, length: number, mph: number)
	leg.routeStuds += round(length, 0)
	leg.driveSeconds += round(report.elapsed, 1)
	leg.mph = round(mph, 1)
	leg.maxMph = math.max(leg.maxMph, round(report.maxMph, 1))
	leg.stuckEvents += report.stuckEvents
end

-- True once the server has moved job `jobId` past stop `index` (or ended it).
local function movedOnFrom(watch: Watch, jobId: string, index: number): () -> boolean
	return function(): boolean
		local job = watch.job
		return job == nil or job.id ~= jobId or job.stopIndex ~= index
	end
end

-- Holds still at the job's current stop until the server moves on; after SETTINGS.advanceTimeout it asks
-- (JobAction arrive, what a player's "I'm here" does) and holds a little longer. Fills the leg's wait.
local function waitAtStop(ctx: Context, job: JobView, leg: Leg, started: number): boolean
	local watch = ctx.watch
	local index = job.stopIndex
	local movedOn = movedOnFrom(watch, job.id, index)
	local waitStarted = os.clock()
	local advanced = holdUntil(ctx, movedOn, SETTINGS.advanceTimeout)
	if not advanced and not cancelRequested(ctx) then
		leg.askedArrive = true
		local reply = jobAction({ action = "arrive", jobId = job.id })
		note(ctx, `stop {index} not taken after {SETTINGS.advanceTimeout} s; arrive {describe(reply)}`)
		advanced = holdUntil(ctx, movedOn, SETTINGS.arriveRetryTimeout)
	end
	local endedAt = if advanced then watch.changedAt else os.clock()
	leg.waitSeconds += round(math.max(endedAt - waitStarted, 0), 1)
	leg.seconds = round(endedAt - started, 1)
	if not advanced then
		leg.reason = if cancelRequested(ctx) then "stopped" else "the server didn't move on"
	end
	return advanced
end

-- Couples the semi, placed before the accept, to the job's trailer. When the trailer it stands at is farther than
-- the job's arriveRadius from the couple stop (JobService wouldn't adopt it), DevJob teleportToStop is tried once.
-- Returns whether it coupled, and the couple stop's position when it didn't (to place the semi there next time).
local function coupleFreight(ctx: Context, run: JobRun, job: JobView, placed: Placed): (boolean, Vector3?)
	local stop = job.stops[job.stopIndex]
	local def = Jobs.types[FREIGHT_JOB]
	local leg = newLeg(job.stopIndex, if stop then stop.kind else "?", if stop then stop.label else "?")
	table.insert(run.legs, leg)
	local started = os.clock()
	run.coupleGap = round(placed.gap, 2)
	local car = placed.car
	local reply: Reply? = nil
	local coupled = false
	local away = if stop then flatDistance(placed.trailer.point.WorldPosition, stop.position) else math.huge
	if stop ~= nil and def ~= nil and away <= def.arriveRadius then
		setCurrent(ctx, `coupling {placed.trailer.model.Name} ({run.coupleGap} studs between the Kingpins)`)
		reply, coupled = coupleNow(ctx, car)
	else
		note(
			ctx,
			`the job's trailer spot ({if stop then stop.label else "?"}) is {round(away, 0)} studs from the trailer the `
				.. `semi stands at (arriveRadius {if def then def.arriveRadius else "?"}): trying DevJob teleportToStop`
		)
		local teleport = teleportToStop()
		leg.teleported = true
		if teleport ~= nil and teleport.ok then
			task.wait(SETTINGS.settleSeconds)
			reply, coupled = coupleNow(ctx, car)
		else
			reply = teleport
		end
	end
	run.coupleReply = describe(reply)
	run.coupled = coupled
	leg.seconds = round(os.clock() - started, 1)
	if not coupled then
		leg.reason = `couple {describe(reply)}`
		return false, if stop then stop.position else nil
	end
	return true, nil
end

-- Couples the pickup, placed on the Breakdown spot before the accept, to the job's broken-down car once it has
-- streamed in. Returns whether it coupled, and the car.
local function coupleTow(ctx: Context, run: JobRun, job: JobView, truck: Model): (boolean, Towable?)
	local stop = job.stops[job.stopIndex]
	local leg = newLeg(job.stopIndex, if stop then stop.kind else "?", if stop then stop.label else "?")
	table.insert(run.legs, leg)
	local started = os.clock()
	if stop == nil then
		leg.reason = "the job has no stop"
		return false, nil
	end
	setCurrent(ctx, `looking for the broken-down car at {stop.label}`)
	local found = lookAround(ctx, stop.position, function(): { Towable }
		return towedCarsNear(stop.position, SETTINGS.towedSearchRadius, job.id)
	end)
	local towed = found[1]
	if towed == nil then
		leg.reason = `no car marked {TOWED_ATTRIBUTE} with a {TOW_POINT} within {SETTINGS.towedSearchRadius} studs`
		leg.seconds = round(os.clock() - started, 1)
		return false, nil
	end
	run.coupleGap = round(couplingGap(truck, TOW_HITCH, towed) or math.huge, 2)
	setCurrent(ctx, `coupling the {towed.model.Name} ({run.coupleGap} studs between the hitch and the tow point)`)
	local reply, coupled = coupleNow(ctx, truck)
	run.coupleReply = describe(reply)
	run.coupled = coupled
	leg.seconds = round(os.clock() - started, 1)
	if not coupled then
		leg.reason = `couple {describe(reply)} ({run.coupleGap} studs between the hitch and the tow point)`
	end
	return coupled, towed
end

-- One drive of a coupled job: from the current stop through any run of long-haul waypoints (passed at speed) to the
-- stop after them, stopping with the point `aimBehind` studs behind the chassis centre over it (the middle of the
-- rig: the coupling point and the towed body both inside the drop's footprint). At a decouple stop (or the last) it
-- uncouples there, recording the reply on the run; then it holds still until the server moves the job on.
local function haulLeg(
	ctx: Context,
	run: JobRun,
	job: JobView,
	car: Model,
	aimBehind: number,
	kind: HaulKind,
	opts: Options
): Leg
	local watch = ctx.watch
	local first = job.stopIndex
	local targets: { Vector3 } = {}
	local waypoints = 0
	local lastIndex = first
	for index = first, #job.stops do
		local stop = job.stops[index]
		table.insert(targets, stop.position)
		lastIndex = index
		if stop.kind ~= "waypoint" then
			break
		end
		waypoints += 1
	end
	local finalStop = job.stops[lastIndex]
	local kindText = if waypoints > 0 then `waypoint x{waypoints} + {finalStop.kind}` else finalStop.kind
	local leg = newLeg(first, kindText, finalStop.label)
	local started = os.clock()
	local mph = cruiseFor(kind, waypoints > 0, opts)
	local def = Jobs.types[kind]
	local arriveRadius = if def then def.arriveRadius else 0
	local pose = carPose()
	if pose == nil then
		leg.reason = "not driving"
		return leg
	end
	if waypoints > 0 or distanceToStop(pose.Position, finalStop) > SETTINGS.stopArriveRadius then
		local points = routeThrough(pose, targets, aimBehind)
		if points == nil then
			leg.reason = "no route"
			return leg
		end
		setCurrent(ctx, `hauling to {finalStop.label} ({kindText}) at {round(mph, 0)} mph`)
		local report, length = drivePoints(points, mph, true, SETTINGS.stopArriveRadius)
		applyReport(leg, report, length, mph)
		local here = carPose()
		if here == nil or distanceToStop(here.Position, finalStop) > arriveRadius then
			leg.seconds = round(os.clock() - started, 1)
			leg.reason = if cancelRequested(ctx) then "stopped" else `didn't reach {finalStop.label} ({report.reason})`
			return leg
		end
	end
	-- A long-haul waypoint the server didn't count. Uncoupling here would fail the job (off away from the drop), so
	-- the next leg drives back to it; with no stop counted at all this time, the leg failed.
	local active = watch.job
	if active ~= nil and active.id == job.id and active.stopIndex < lastIndex then
		local missed = active.stops[active.stopIndex]
		note(ctx, `the server didn't count stop {active.stopIndex} ({if missed then missed.label else "?"})`)
		leg.seconds = round(os.clock() - started, 1)
		if active.stopIndex <= first then
			leg.reason = `stop {first} wasn't counted on the way past`
		end
		return leg
	end
	if finalStop.kind == "decouple" or lastIndex >= #job.stops then
		setCurrent(ctx, `uncoupling at {finalStop.label}`)
		local reply, uncoupled = uncoupleNow(ctx, car)
		run.uncoupleReply = describe(reply)
		run.uncoupled = uncoupled
		if not uncoupled then
			leg.reason = `decouple {describe(reply)}`
			leg.seconds = round(os.clock() - started, 1)
			return leg
		end
	end
	local now = watch.job
	if now ~= nil and now.id == job.id then
		waitAtStop(ctx, now, leg, started)
	else
		leg.seconds = round(os.clock() - started, 1)
	end
	return leg
end

-- How rate() chains jobs: each cycle starts where the previous job ended (os.clock()), and the car holds still until
-- `betweenSeconds` after that before looking at offers (the reading and choosing time the calibration pays for).
type Chain = { from: number, betweenSeconds: number }

-- A job accepted with the truck ready to couple.
type Start = {
	truck: Model,
	rig: RigGeometry,
	accepted: Accepted, -- its job is set
	searchStarted: number, -- os.clock() the offer search that found it started
	credited: number, -- seconds of backing up to the load the respawn skipped (rate() counts them)
	placed: Placed?, -- freight: the semi at its trailer
}

-- Freight: the semi spawned at the idle trailer on the first spot of the depot nearest `near` (opts.depot), or the
-- one nearest `toward` (a job's spot, on a retry); then the offer that starts at that depot (else the first), and
-- the accept. Nil and why when it couldn't.
local function startFreight(
	ctx: Context,
	opts: Options,
	vehicleId: string,
	trim: string,
	near: Vector3?,
	toward: Vector3?
): (Start?, string?)
	local depot, depotWhy = chooseDepot(opts.depot, near)
	if depot == nil then
		return nil, depotWhy
	end
	local trailers, why = idleTrailersAt(ctx, depot, "first", toward)
	if #trailers == 0 then
		return nil, why
	end
	local placed, placeWhy = placeSemi(ctx, trailers, vehicleId, trim)
	if placed == nil then
		return nil, placeWhy
	end
	local searchStarted = os.clock()
	local pick = freightFrom(depot)
	setCurrent(ctx, `looking for a freight offer from {depot.displayName}`)
	local offer, offerWhy = findOffer(ctx, FREIGHT_JOB, pick, nil)
	if offer == nil then
		return nil, offerWhy
	end
	setCurrent(ctx, `accepting "{offer.title}" ({offer.subtitle}; est. ${round(offer.pay, 0)})`)
	local accepted = acceptOffer(ctx, FREIGHT_JOB, offer, pick)
	if accepted.job == nil then
		return nil, accepted.failure
	end
	-- What the respawn skipped: backing under the trailer (the calibration's allowance). Not the bobtail drive to
	-- it: that is paid by the stud at the calibrated rate (approach pay), and the respawn earns none, so leaving out
	-- both its time and its pay keeps the rate.
	return {
		truck = placed.car,
		rig = placed.rig,
		accepted = accepted,
		searchStarted = searchStarted,
		credited = numberOf(calibration.coupleSecondsFreight),
		placed = placed,
	},
		nil
end

-- Towing: the pickup spawned on the Breakdown spot nearest `near` (opts.breakdown), its TowHitch ahead of where the
-- broken-down car's TowPoint will be; then an offer at that spot, placed again for the offered car when its
-- TowPoint would be out of Config/Trailers.coupleDistance; then the accept. Nil and why when it couldn't.
local function startTowing(
	ctx: Context,
	opts: Options,
	vehicleId: string,
	trim: string,
	near: Vector3?
): (Start?, string?)
	local spot, spotWhy = chooseBreakdown(opts.breakdown, near)
	if spot == nil then
		return nil, spotWhy
	end
	local cars = breakdownCars()
	local length = longestLength(cars)
	local reach = trailersNumber("coupleDistance")
	local ahead = trailersNumber("towPointAhead")
	if length == nil or ahead == nil then
		return nil,
			if length == nil
				then "Config/Jobs towing has no breakdownClasses cars"
				else "Config/Trailers has no towed.towPointAhead"
	end
	local at, along = breakdownPose(spot)
	local pick = towingAt(spot)
	for try = 1, SETTINGS.towPlaceTries do
		local truck, rig, hitch, why = placePickup(ctx, spot, length, vehicleId, trim)
		if truck == nil or rig == nil or hitch == nil then
			return nil, why
		end
		local searchStarted = os.clock()
		setCurrent(ctx, `looking for a towing offer at {spot.displayName}`)
		local offer, offerWhy = findOffer(ctx, TOWING_JOB, pick, SETTINGS.towOfferTries)
		if offer == nil then
			return nil, offerWhy
		end
		-- Taken when the car's TowPoint will be within reach of the hitch and not past it (past it, a longer car would
		-- stand into the pickup: with the hitch ahead, the two chassis keep towGap + towPointAhead apart and more).
		local car = offeredCar(offer, cars)
		local towPoint = if car then towPointAt(at, along, car.length, ahead) else nil
		local gap = if towPoint then flatDistance(hitch, towPoint) else math.huge
		local behind = towPoint == nil or (hitch - towPoint):Dot(along) >= 0
		local limit = if reach then reach - SETTINGS.coupleMargin else math.huge
		if (gap <= limit and behind) or car == nil or try >= SETTINGS.towPlaceTries then
			if gap > limit or not behind then
				note(
					ctx,
					`"{offer.title}": its TowPoint will be {round(gap, 1)} studs from the hitch; taking it anyway`
				)
			end
			setCurrent(ctx, `accepting "{offer.title}" ({offer.subtitle}; est. ${round(offer.pay, 0)})`)
			local accepted = acceptOffer(ctx, TOWING_JOB, offer, pick)
			if accepted.job == nil then
				return nil, accepted.failure
			end
			return {
				truck = truck,
				rig = rig,
				accepted = accepted,
				searchStarted = searchStarted,
				credited = numberOf(calibration.coupleSecondsTow),
				placed = nil,
			},
				nil
		end
		note(
			ctx,
			`"{offer.title}" is a {car.length}-stud car: its TowPoint would be {round(gap, 1)} studs from the hitch`
				.. `{if behind then "" else ", past it"} (coupleDistance {reach}); placing the pickup again for it`
		)
		length = car.length
	end
	return nil, "no towing offer the pickup could be placed for"
end

-- Finds, accepts, couples, hauls and uncouples one job of `kind`, then waits for the pay. Returns the run (nil when
-- no job could be started, with why) and os.clock() when it ended (the next cycle's start).
local function runHaulJob(ctx: Context, kind: HaulKind, opts: Options, chain: Chain?): (JobRun?, string?, number)
	local watch = ctx.watch
	local cycleStarted = if chain then chain.from else os.clock()
	if chain then
		local idle = chain.betweenSeconds - (os.clock() - chain.from)
		if idle > 0 and not cancelRequested(ctx) then
			setCurrent(ctx, `between jobs: holding still {round(idle, 1)} s`)
			AutoDriver.holdStill(idle)
		end
	end
	local held = os.clock() - cycleStarted
	local fallback = if kind == "freight" then SETTINGS.semi else SETTINGS.towCar
	local vehicleId = opts.vehicleId or fallback.vehicleId
	local defaultTrim = Catalog.defaultTrim(vehicleId)
	local trim = opts.trim or (if opts.vehicleId then (if defaultTrim then defaultTrim.id else "") else fallback.trim)
	local pointName = if kind == "freight" then KINGPIN else TOW_HITCH
	local towedPointName = if kind == "freight" then KINGPIN else TOW_POINT
	local near = playerPosition()
	local spotWanted: Vector3? = nil -- freight retries: the spot of the job that couldn't be coupled

	for attempt = 1, SETTINGS.originTries do
		if cancelRequested(ctx) then
			return nil, "stopped", os.clock()
		end
		-- 1. The truck at its load and the job accepted (respawning after the accept would fail the job).
		local start: Start?, why: string? = nil, nil
		if kind == "freight" then
			start, why = startFreight(ctx, opts, vehicleId, trim, near, spotWanted)
		else
			start, why = startTowing(ctx, opts, vehicleId, trim, near)
		end
		if start == nil then
			return nil, why, os.clock()
		end
		local truck, geometry, accepted = start.truck, start.rig, start.accepted
		local job = accepted.job :: JobView
		local credited, searchStarted = start.credited, start.searchStarted
		local tv, tt = carIdentity(truck)
		ctx.result.vehicle = `{tv or "?"}/{tt or "?"}`
		local progress = watch.progress[kind]
		local xpBefore = if progress then progress.xp else nil
		local run = newRun(kind, accepted.offer, #job.stops)
		run.originTries = attempt
		run.creditedSeconds = round(credited, 1)
		run.level = if progress then progress.level else nil
		run.levelMultiplier = if progress then progress.multiplier else nil
		if job.deadline ~= nil and job.startedAt ~= nil then
			run.timeAllowed = round(job.deadline - job.startedAt, 1)
		end
		local acceptedAt, cashBefore = accepted.acceptedAt, accepted.cashBefore

		-- 2. Couple.
		local coupled = false
		local towedModel: Model? = nil
		local retryAt: Vector3? = nil
		local placed = start.placed
		if placed ~= nil then
			coupled, retryAt = coupleFreight(ctx, run, job, placed)
			towedModel = placed.trailer.model
		else
			local towed: Towable? = nil
			coupled, towed = coupleTow(ctx, run, job, truck)
			towedModel = if towed then towed.model else nil
		end
		local _, couplingModel = towingOf(truck)
		towedModel = couplingModel or towedModel

		-- 3. Haul it through the stops while it stays on, sampling the hitch. At the drop the middle of the rig
		--    stops over the stop: the coupling point, plus half the way to the towed body's centre.
		local monitor: Monitor? = nil
		local aimBehind = geometry.coupleLocal.Z
		if coupled and towedModel ~= nil then
			local sampler = startMonitor(ctx, truck, towedModel, pointName, towedPointName, jackknifeDegrees())
			sampler.phase = kind
			monitor = sampler
			local towedChassis = chassisOf(towedModel)
			local towedPoint = findAttachment(towedModel, towedPointName)
			if towedChassis ~= nil and towedPoint ~= nil then
				aimBehind += flatDistance(towedPoint.WorldPosition, towedChassis.Position) / 2
			end
		end
		local legs = 0
		while coupled and not cancelRequested(ctx) and legs < #job.stops + SETTINGS.maxExtraLegs do
			local active = watch.job
			if active == nil or active.id ~= job.id then
				break
			end
			legs += 1
			local stop = active.stops[active.stopIndex]
			local leg: Leg
			if stop ~= nil and stop.kind == "couple" then
				-- Coupled already: JobService takes the stop when it sees the coupling.
				leg = newLeg(active.stopIndex, stop.kind, stop.label)
				waitAtStop(ctx, active, leg, os.clock())
			else
				leg = haulLeg(ctx, run, active, truck, aimBehind, kind, opts)
			end
			table.insert(run.legs, leg)
			run.routeStuds += leg.routeStuds
			if leg.reason ~= "advanced" then
				break
			end
		end
		if monitor ~= nil then
			monitor.stop()
			run.maxArticulation = round(monitor.maxDegrees, 1)
			run.jackknifes = #monitor.events
		end
		local last = run.legs[#run.legs]

		local active = watch.job
		if active ~= nil and active.id == job.id then
			-- Not finished (not coupled, a leg failed, or stopped): give it up. Its time counts; the cooldown doesn't.
			run.seconds = round(os.clock() - acceptedAt, 1)
			run.cycleSeconds = round(held + credited + os.clock() - searchStarted, 1)
			run.reason = if last then last.reason else "stopped"
			local reply = cancelJob(ctx, job.id, kind)
			note(ctx, `cancelled "{run.title}" ({run.reason}); cancel {describe(reply)}`)
			if kind == "freight" and not coupled and retryAt ~= nil and attempt < SETTINGS.originTries then
				-- Try again with the semi at the trailer nearest the job's own spot. The failed try's time isn't
				-- counted (the next search starts the count again); the hold between jobs still is.
				note(ctx, `placing the semi again, nearer {run.legs[1] and run.legs[1].label or "the job's spot"}`)
				near = retryAt
				spotWanted = retryAt
				opts = table.clone(opts)
				opts.depot = nil
				continue
			end
			return run, nil, os.clock()
		end

		-- 4. The job ended: wait for its pay to reach the Cash attribute and its XP the next JobUpdate, or a
		--    failure notice.
		local endedAt = watch.endedAt[job.id] or os.clock()
		if job.deadline ~= nil then
			local serverEnded = Workspace:GetServerTimeNow() - (os.clock() - endedAt)
			run.timeLeft = round(job.deadline - serverEnded, 1)
		end
		local function xpNow(): number?
			local entry = watch.progress[kind]
			return if entry then entry.xp else nil
		end
		waitFor(ctx, function(): boolean
			local failed = noticeSince(watch, acceptedAt, FAILED_PATTERN)
			local paid = cash() - driveEarnSince(watch, acceptedAt) > cashBefore
			local xp = xpNow()
			return failed ~= nil or (paid and (xpBefore == nil or (xp ~= nil and xp > xpBefore)))
		end, watch.changed.Event, SETTINGS.cashSettleSeconds)
		local xpAfter = xpNow()
		run.xpGained = if xpBefore ~= nil and xpAfter ~= nil then xpAfter - xpBefore else 0
		local driveEarnDuring = 0
		for _, decision in watch.driveEarn do
			if decision.at >= acceptedAt and decision.at <= endedAt then
				driveEarnDuring += decision.amount
			end
		end
		run.driveEarnPaid = driveEarnDuring
		run.pay = cash() - cashBefore - driveEarnSince(watch, acceptedAt)
		run.seconds = round(endedAt - acceptedAt, 1)
		run.cycleSeconds = round(held + credited + endedAt - searchStarted, 1)
		run.perMinute = if run.seconds > EPSILON then round(run.pay * SECONDS_PER_MINUTE / run.seconds, 0) else 0
		run.completed = run.pay > 0
		if run.completed then
			run.reason = "completed"
		else
			local failed = noticeSince(watch, acceptedAt, FAILED_PATTERN)
			local lastNotice = lastNoticeSince(watch, acceptedAt)
			run.reason = failed
				or (if lastNotice then `ended without pay (last notice: "{lastNotice}")` else "ended without pay")
		end
		local levelUp = noticeSince(watch, acceptedAt, LEVEL_UP_PATTERN)
		if levelUp then
			note(ctx, `level up: "{levelUp}" (later jobs pay more)`)
		end
		print(
			`{LOG} {ctx.name}: "{run.title}" {run.reason}: ${run.pay} in {run.seconds} s ({run.perMinute}/min), `
				.. `{#run.legs} leg(s), {run.routeStuds} studs driven, est. ${run.offerPay}, +{run.xpGained} XP`
		)
		return run, nil, endedAt
	end
	return nil, `couldn't couple a {kind} job's trailer in {SETTINGS.originTries} tries`, os.clock()
end

local function legsDetail(run: JobRun): string
	local parts: { string } = {}
	for _, leg in run.legs do
		table.insert(
			parts,
			`{leg.kind} {leg.label}: {leg.routeStuds} studs, drive {leg.driveSeconds} s + wait {leg.waitSeconds} s`
				.. (if leg.teleported then " (teleported)" else "")
				.. (if leg.reason ~= "advanced" then ` [{leg.reason}]` else "")
		)
	end
	return table.concat(parts, "; ")
end

---------------------------------------------------------------------------------------------------------------
-- Tests
---------------------------------------------------------------------------------------------------------------

-- The semi coupled to an idle trailer at `depot` (loop(), decoupleOutside()). Fills the result's depot, trailer,
-- kingpinGap, slid and coupleDistance and checks the coupling. Nil (with the result's reason set) when it failed.
local function coupledRig(ctx: Context, depot: MapLayout.Location, opts: Options): (Model?, Towable?, RigGeometry?)
	local result = ctx.result
	result.depot = depot.id
	result.coupleDistance = trailersNumber("coupleDistance")
	local vehicleId = opts.vehicleId or SETTINGS.semi.vehicleId
	local defaultTrim = Catalog.defaultTrim(vehicleId)
	local trim = opts.trim
		or (if opts.vehicleId then (if defaultTrim then defaultTrim.id else "") else SETTINGS.semi.trim)
	if Catalog.getTrim(vehicleId, trim) == nil then
		result.reason = `no {vehicleId}/{trim} in Config/Vehicles`
		return nil, nil, nil
	end
	local trailers, why = idleTrailersAt(ctx, depot, "box", nil)
	check(ctx, "an idle trailer at the depot", #trailers > 0, why or `{#trailers} at {depot.displayName}`)
	if #trailers == 0 then
		result.reason = why or "no trailer"
		return nil, nil, nil
	end
	local placed, placeWhy = placeSemi(ctx, trailers, vehicleId, trim)
	if placed == nil then
		result.reason = placeWhy or "couldn't place the semi"
		return nil, nil, nil
	end
	local trailer = placed.trailer
	result.vehicle = `{vehicleId}/{trim}`
	result.trailer = trailer.model.Name
	result.kingpinGap = round(placed.gap, 2)
	result.slid = round(placed.placement.slid, 1)
	if not trailer.preferred then
		note(ctx, `no idle {SETTINGS.preferredTrailer} there: using {trailer.model.Name}`)
	end
	setCurrent(ctx, `coupling {trailer.model.Name} ({result.kingpinGap} studs between the Kingpins)`)
	local reply, coupled = coupleNow(ctx, placed.car)
	local reach = if result.coupleDistance then `; coupleDistance {result.coupleDistance}` else ""
	check(
		ctx,
		"coupled the trailer",
		coupled,
		`{describe(reply)}; Kingpins {result.kingpinGap} studs apart, slid {result.slid}{reach}`
	)
	if not coupled then
		result.reason = `couldn't couple: {describe(reply)}`
		return nil, nil, nil
	end
	local name, towed = towingOf(placed.car)
	check(
		ctx,
		"coupled to that trailer",
		towed == trailer.model or name == trailer.model.Name,
		`TowingModel "{name or ""}", Towing {if towed then towed:GetFullName() else "nil"}`
	)
	return placed.car, trailer, placed.rig
end

local function loopTest(ctx: Context, opts: Options): Result
	local result = ctx.result
	local depot, why = chooseDepot(opts.depot, nil)
	if depot == nil then
		result.reason = why or "no depot"
		return result
	end
	local threshold = jackknifeDegrees()
	result.jackknifeAngle = if threshold then round(threshold, 1) else nil
	check(
		ctx,
		"Config/Trailers.jackknifeAngle is set",
		threshold ~= nil,
		if threshold then `{round(threshold, 1)} degrees` else "missing: jackknife events can't be counted"
	)
	local mph = opts.mph or loopSpeedMph()
	result.targetMph = round(mph, 1)
	local car, trailer = coupledRig(ctx, depot, opts)
	if car == nil or trailer == nil then
		return result
	end
	local watch = ctx.watch
	local since = os.clock()
	local monitor = startMonitor(ctx, car, trailer.model, KINGPIN, KINGPIN, threshold)

	-- 1. Onto the loop at its node nearest the depot, at the approach speed.
	local pose = carPose()
	local positions = loopPositions()
	if pose == nil or #positions < 3 then
		monitor.stop()
		result.reason = if pose == nil then "not driving" else "RoadGraph.loopNodeIds has fewer than 3 nodes"
		return result
	end
	local joinIndex, nearest = 1, math.huge
	for index, position in positions do
		local distance = flatDistance(position, pose.Position)
		if distance < nearest then
			joinIndex, nearest = index, distance
		end
	end
	local join = Pathfind.route(pose.Position, positions[joinIndex], pose.LookVector)
	if join == nil then
		monitor.stop()
		result.reason = "no route onto the County Loop"
		return result
	end
	monitor.phase = "joining"
	setCurrent(ctx, `driving onto the County Loop at {SETTINGS.approachMph} mph`)
	local joinPoints = RouteTests.Math.keepRight(join.points, laneOffsetFor, SETTINGS.maxMiter)
	local joined = drivePoints(joinPoints, SETTINGS.approachMph, false, nil)
	check(ctx, "drove onto the County Loop", joined.completed, joined.reason)
	if not joined.completed or cancelRequested(ctx) then
		monitor.stop()
		result.maxArticulation = round(monitor.maxDegrees, 1)
		result.jackknifeEvents = monitor.events
		result.reason = if cancelRequested(ctx) then "stopped" else `didn't reach the loop ({joined.reason})`
		return result
	end

	-- 2. One whole lap at highway speed.
	local lapPose = carPose()
	local lap = if lapPose then lapPoints(lapPose) else nil
	if lap == nil then
		monitor.stop()
		result.reason = "no lap of the County Loop"
		return result
	end
	monitor.phase = "loop"
	setCurrent(ctx, `once round the County Loop at {round(mph, 1)} mph, sampling the hitch`)
	local lapStarted = os.clock()
	local report, length = drivePoints(lap, mph, true, nil)
	local lapSeconds = os.clock() - lapStarted
	local lapStuds = monitor.phaseStuds
	monitor.stop()

	result.lapCompleted = report.completed
	result.lapStuds = round(length, 0)
	result.lapSeconds = round(lapSeconds, 1)
	result.averageMph = round(Units.studsToMph(lapStuds / math.max(lapSeconds, EPSILON)), 1)
	result.maxMph = round(report.maxMph, 1)
	result.stuckEvents = report.stuckEvents
	result.maxArticulation = round(monitor.maxDegrees, 1)
	result.maxArticulationLoop = round(monitor.maxByPhase.loop or 0, 1)
	result.jackknifeEvents = monitor.events
	result.maxHitchGap = round(monitor.maxGap, 2)
	result.resets = resetsSince(watch, since)

	local highway = mph * SETTINGS.highwayMinShare
	check(
		ctx,
		"completed the County Loop",
		report.completed,
		`{report.reason}: {result.lapStuds} studs in {result.lapSeconds} s`
	)
	check(
		ctx,
		"at highway speed",
		report.maxMph >= highway,
		`max {result.maxMph} mph (needs {round(highway, 1)}), average {result.averageMph} mph`
	)
	local eventText: { string } = {}
	for _, event in monitor.events do
		table.insert(eventText, `{event.phase} {event.degrees} deg at {event.mph} mph ({event.at} s)`)
	end
	check(
		ctx,
		"no jackknife",
		threshold ~= nil and #monitor.events == 0,
		`max articulation {result.maxArticulation} deg (lap {result.maxArticulationLoop}), threshold `
			.. `{result.jackknifeAngle or "?"}; {#monitor.events} event(s){if #eventText > 0
				then ": " .. table.concat(eventText, "; ")
				else ""}`
	)
	local name, towed = towingOf(car)
	check(
		ctx,
		"still coupled after the lap",
		name ~= nil and (towed == nil or towed == trailer.model),
		`TowingModel "{name or ""}"`
	)
	check(
		ctx,
		"the hitch held",
		monitor.maxGap <= SETTINGS.maxHitchGap,
		`coupling points at most {result.maxHitchGap} studs apart (allowed {SETTINGS.maxHitchGap})`
	)
	check(ctx, "no anti-exploit reset", result.resets == 0, `{result.resets} VehicleReset(s) during the drive`)
	result.reason = if cancelRequested(ctx) then "stopped" else "done"
	return result
end

-- A route from where the semi stands out onto an open road: toward the County Loop, cut at the first point at least
-- SETTINGS.openRoadStuds along it and SETTINGS.outsideMargin from every coupling zone. Nil when there is no route.
local function openRoadPoints(pose: CFrame, zones: { MapLayout.Location }): { Vector3 }?
	local positions = loopPositions()
	if #positions == 0 then
		return nil
	end
	local target = positions[1]
	local nearest = math.huge
	for _, position in positions do
		local distance = flatDistance(position, pose.Position)
		if distance < nearest then
			target, nearest = position, distance
		end
	end
	local route = Pathfind.route(pose.Position, target, pose.LookVector)
	if route == nil then
		return nil
	end
	local points = RouteTests.Math.keepRight(route.points, laneOffsetFor, SETTINGS.maxMiter)
	local along = 0
	local last = pose.Position
	for index, point in points do
		along += flatDistance(point, last)
		last = point
		local _, clearance = nearestFootprint(point, zones)
		if along >= SETTINGS.openRoadStuds and clearance >= SETTINGS.outsideMargin then
			return table.move(points, 1, index, 1, {})
		end
	end
	return points
end

local function decoupleOutsideTest(ctx: Context, opts: Options): Result
	local result = ctx.result
	local depot, why = chooseDepot(opts.depot, playerPosition())
	if depot == nil then
		result.reason = why or "no depot"
		return result
	end
	local car, trailer, rig = coupledRig(ctx, depot, opts)
	if car == nil or trailer == nil or rig == nil then
		return result
	end

	-- 1. Out onto an open road and stop there.
	local zones = couplingZones()
	local pose = carPose()
	local points = if pose then openRoadPoints(pose, zones) else nil
	if points == nil then
		result.reason = "no route out of the depot"
		return result
	end
	setCurrent(ctx, "driving out onto an open road")
	local report = drivePoints(points, SETTINGS.approachMph, true, nil)
	check(ctx, "drove out of the depot", report.completed, report.reason)
	AutoDriver.holdStill(SETTINGS.settleSeconds)
	local kingpin = findAttachment(car, KINGPIN)
	local here = if kingpin then kingpin.WorldPosition else (carPose() or CFrame.new()).Position
	local zone, clearance = nearestFootprint(here, zones)
	result.clearOfFootprints = round(clearance, 0)
	check(
		ctx,
		"stopped on an open road",
		clearance >= SETTINGS.outsideMargin,
		`{result.clearOfFootprints} studs from {if zone then zone.displayName .. " (" .. zone.tag .. ")" else "nothing"}`
	)

	-- 2. Ask to uncouple: refused, and nothing changes.
	local nameBefore, towedBefore = towingOf(car)
	setCurrent(ctx, "asking to uncouple out here (expecting a refusal)")
	local reply = call("TrailerAction", { action = "decouple" })
	local refusal = describe(reply)
	result.refusal = refusal
	check(ctx, "uncoupling refused", reply ~= nil and not reply.ok, refusal)
	check(
		ctx,
		"the refusal says why",
		reply ~= nil and reply.message ~= "",
		`message "{if reply then reply.message else ""}"`
	)
	waitFor(ctx, function(): boolean
		return towingOf(car) ~= nameBefore
	end, car:GetAttributeChangedSignal(TOWING_ATTRIBUTE), SETTINGS.decoupleWatchSeconds)
	local nameAfter, towedAfter = towingOf(car)
	check(
		ctx,
		"still coupled to the same trailer",
		nameAfter ~= nil and nameAfter == nameBefore and towedAfter == towedBefore,
		`TowingModel "{nameBefore or ""}" -> "{nameAfter or ""}", Towing `
			.. `{if towedBefore then towedBefore.Name else "nil"} -> {if towedAfter then towedAfter.Name else "nil"}`
	)
	local gap = couplingGap(car, KINGPIN, trailer)
	local trailerChassis = chassisOf(trailer.model)
	check(
		ctx,
		"still hitched",
		gap ~= nil and gap <= SETTINGS.maxHitchGap and trailerChassis ~= nil and not trailerChassis.Anchored,
		`Kingpins {if gap then round(gap, 2) else "?"} studs apart, trailer {if trailerChassis
				and trailerChassis.Anchored
			then "anchored (parked)"
			else "free"}`
	)

	-- 3. Back into the depot to uncouple there (and leave things tidy).
	if not opts.stayCoupled and not cancelRequested(ctx) then
		local backPose = carPose()
		local back = if backPose then routeThrough(backPose, { depot.position }, rig.coupleLocal.Z) else nil
		if back == nil then
			note(ctx, "no route back into the depot: left coupled")
		else
			setCurrent(ctx, `driving back into {depot.displayName}`)
			local backReport = drivePoints(back, SETTINGS.approachMph, true, SETTINGS.stopArriveRadius)
			local pin = findAttachment(car, KINGPIN)
			-- HitchService's drop rule: the hitch inside the footprint, or within Config/Trailers.decoupleRadius of
			-- its centre.
			local radius = trailersNumber("decoupleRadius") or 0
			local inside = pin ~= nil
				and (
					outsideDistance(depot, pin.WorldPosition) <= 0
					or flatDistance(pin.WorldPosition, depot.position) <= radius
				)
			if inside then
				local uncoupleReply, uncoupled = uncoupleNow(ctx, car)
				check(ctx, "uncoupled inside the depot", uncoupled, describe(uncoupleReply))
			else
				note(
					ctx,
					`couldn't stop inside {depot.displayName} ({backReport.reason}; Kingpin `
						.. `{if pin then round(outsideDistance(depot, pin.WorldPosition), 0) else "?"} studs outside): left coupled`
				)
			end
		end
	end
	result.reason = if cancelRequested(ctx) then "stopped" else "done"
	return result
end

-- The job def for `kind`, or nil when Config/Jobs has none yet.
local function haulDef(kind: HaulKind): Jobs.JobDef?
	return Jobs.types[kind]
end

-- The §4 rate (Config/Economy.activities, $/min) a job of `kind` is calibrated to.
local function targetFor(kind: HaulKind): number
	return if kind == "freight" then Economy.activities.freight else Economy.activities.towing
end

-- freight() and towing(): one job end to end.
local function oneJobTest(ctx: Context, kind: HaulKind, opts: Options): Result
	local result = ctx.result
	if haulDef(kind) == nil then
		return skip(ctx, `Config/Jobs has no {kind} job`)
	end
	clearActiveJob(ctx)
	if kind == "freight" then
		local held, licenseText = ensureFreightLicense(ctx)
		result.license = licenseText
		if not held then
			return skip(ctx, `no freight license: {licenseText}`)
		end
		note(ctx, `freight license: {licenseText}`)
	end
	local run, failure = runHaulJob(ctx, kind, opts, nil)
	if run == nil then
		check(ctx, "accepted an offer", false, failure or "no job")
		result.reason = failure or "no job"
		return result
	end
	result.job = run
	check(ctx, "accepted an offer", true, `"{run.title}" ({run.subtitle}), est. ${run.offerPay}`)
	check(
		ctx,
		"coupled",
		run.coupled,
		`{run.coupleReply or "?"}; {if run.coupleGap then run.coupleGap else "?"} studs between the coupling points`
			.. (if run.originTries > 1 then ` (job {run.originTries}: the ones before started elsewhere)` else "")
	)
	-- The server takes every stop itself (couple, waypoints, decouple); the job ending in pay is the proof.
	check(ctx, "every stop taken", run.completed, legsDetail(run))
	check(ctx, "uncoupled at the drop", run.uncoupled, run.uncoupleReply or "never asked")
	check(ctx, "paid", run.completed, `${run.pay} in {run.seconds} s = ${run.perMinute}/min ({run.reason})`)
	check(ctx, "no drive-to-earn during the job", run.driveEarnPaid == 0, `drive-to-earn paid ${run.driveEarnPaid}`)
	local threshold = jackknifeDegrees()
	if threshold ~= nil then
		check(
			ctx,
			"no jackknife",
			run.jackknifes == 0,
			`max articulation {run.maxArticulation} deg, threshold {round(threshold, 1)}`
		)
	end
	local target = targetFor(kind)
	note(ctx, `{kind} target ${target}/min; this job ${run.perMinute}/min (rate() measures the average)`)
	result.reason = if run.completed then "done" else run.reason
	return result
end

local function rateTest(ctx: Context, kind: HaulKind, minutes: number, opts: Options): Result
	local result = ctx.result
	if haulDef(kind) == nil then
		return skip(ctx, `Config/Jobs has no {kind} job`)
	end
	clearActiveJob(ctx)
	if kind == "freight" then
		local held, licenseText = ensureFreightLicense(ctx)
		result.license = licenseText
		if not held then
			return skip(ctx, `no freight license: {licenseText}`)
		end
	end
	local target = targetFor(kind)
	result.target = target
	local runs: { JobRun } = {}
	result.jobs = runs
	local counted, earned, earnedAtLevel1, credited, failures, inARow = 0, 0, 0, 0, 0, 0
	local budget = minutes * SECONDS_PER_MINUTE
	local chain: Chain? = nil

	while counted < budget and not cancelRequested(ctx) do
		setCurrent(ctx, `job {#runs + 1}: {round(counted / SECONDS_PER_MINUTE, 1)} of {minutes} min, ${earned} so far`)
		local run, failure, endedAt = runHaulJob(ctx, kind, opts, chain)
		chain = { from = endedAt, betweenSeconds = Jobs.calibration.betweenSeconds }
		if run == nil then
			note(ctx, `couldn't start a job: {failure or "?"}`)
			break
		end
		table.insert(runs, run)
		counted += run.cycleSeconds
		credited += run.creditedSeconds
		earned += run.pay
		earnedAtLevel1 += run.pay / math.max(run.levelMultiplier or 1, EPSILON)
		if run.completed then
			inARow = 0
		else
			failures += 1
			inARow += 1
			if inARow >= SETTINGS.maxFailuresInARow then
				note(ctx, `{inARow} jobs failed in a row: stopping`)
				break
			end
		end
	end

	local perMinute = if counted > EPSILON then earned * SECONDS_PER_MINUTE / counted else 0
	local atLevel1 = if counted > EPSILON then earnedAtLevel1 * SECONDS_PER_MINUTE / counted else 0
	result.minutes = round(counted / SECONDS_PER_MINUTE, 2)
	result.creditedMinutes = round(credited / SECONDS_PER_MINUTE, 2)
	result.earned = earned
	result.perMinute = round(perMinute, 0)
	result.perMinuteAtLevel1 = round(atLevel1, 0)
	result.ratio = round(atLevel1 / target, 3)
	result.failedJobs = failures
	if credited > 0 then
		note(ctx, `{result.creditedMinutes} min counted for backing up to loads (the truck was respawned at each)`)
	end
	check(ctx, "jobs completed", #runs > 0 and failures < #runs, `{#runs - failures} of {#runs} paid`)
	check(ctx, "covered the time asked", counted >= budget, `{result.minutes} of {minutes} min`)
	check(
		ctx,
		"rate in the §4 band",
		#runs > 0 and math.abs(atLevel1 / target - 1) <= SETTINGS.rateTolerance,
		`${result.perMinuteAtLevel1}/min at level 1 (${result.perMinute}/min paid) vs {kind} ${target}/min `
			.. `(x{result.ratio}, ±{SETTINGS.rateTolerance * 100} % passes)`
	)
	result.reason = if cancelRequested(ctx) then "stopped" else "done"
	return result
end

---------------------------------------------------------------------------------------------------------------
-- Running a test
---------------------------------------------------------------------------------------------------------------

local function emptyResult(name: string, reason: string): Result
	return {
		name = name,
		passed = false,
		skipped = false,
		reason = reason,
		checks = {},
		elapsed = 0,
		notes = {},
		notices = {},
	}
end

local function printResult(result: Result)
	local verdict = if result.skipped then "SKIPPED" elseif result.passed then "PASSED" else "FAILED"
	print(`{LOG} {result.name}: {verdict} ({result.reason}) in {math.floor(result.elapsed)} s`)
	local ok, encoded = pcall(HttpService.JSONEncode, HttpService, result)
	if ok then
		print(`{LOG} {result.name}: {encoded}`)
	end
end

local function runTest(name: TestName, body: (ctx: Context) -> Result): Result
	if not (RunService:IsStudio() and RunService:IsRunning()) then
		warn(`{LOG} runs only in a Studio playtest (Client datamodel)`)
		return emptyResult(name, "studio only")
	end
	if script:GetAttribute(STATUS) == "running" then
		warn(`{LOG} a test is already running; FreightTests.stop() cancels it`)
		return emptyResult(name, "busy")
	end
	if humanoidOf() == nil then
		warn(`{LOG} wait for your character to spawn (and run this in the Client datamodel)`)
		return emptyResult(name, "no character")
	end

	local ctx: Context = {
		id = HttpService:GenerateGUID(false),
		name = name,
		started = os.clock(),
		result = emptyResult(name, "done"),
		watch = newWatch(),
	}
	script:SetAttribute(RUN_ID, ctx.id)
	script:SetAttribute(STATUS, "running")
	script:SetAttribute(CANCEL, false)
	script:SetAttribute(RESULT, nil)

	local ok, outcome = pcall(body, ctx)
	local result: Result = if ok then outcome else ctx.result
	if not ok then
		result.reason = `error: {tostring(outcome)}`
		warn(`{LOG} {name} failed: {outcome}`)
	end

	-- Hand the controls back and leave the car stopped.
	AutoDriver.stop()
	if currentCar() ~= nil and not cancelRequested(ctx) then
		AutoDriver.holdStill(SETTINGS.holdSeconds)
	end
	for index, notice in ctx.watch.notices do
		if index > SETTINGS.maxNotices then
			break
		end
		table.insert(result.notices, notice.text)
	end
	closeWatch(ctx.watch)
	if cancelRequested(ctx) and result.reason == "done" then
		result.reason = "stopped"
	end
	result.passed = ok and not result.skipped and result.reason == "done" and #result.checks > 0
	for _, item in result.checks do
		if not item.passed then
			result.passed = false
		end
	end
	result.elapsed = round(os.clock() - ctx.started, 1)
	printResult(result)

	if script:GetAttribute(RUN_ID) == ctx.id then
		local status = if result.reason == "stopped"
			then "stopped"
			elseif result.skipped then "skipped"
			elseif result.passed then "done"
			else "failed"
		script:SetAttribute(RESULT, HttpService:JSONEncode(result))
		script:SetAttribute(CURRENT, nil)
		script:SetAttribute(STATUS, status)
	end
	return result
end

local FreightTests = {}
FreightTests.SETTINGS = SETTINGS

-- The semi with a coupled trailer once round the County Loop at highway speed: completion, articulation, jackknifes.
function FreightTests.loop(opts: Options?): Result
	local options: Options = opts or {}
	return runTest("loop", function(ctx: Context): Result
		return loopTest(ctx, options)
	end)
end

-- Uncoupling on an open road is refused, and nothing changes (PLAN.md Phase 8 acceptance).
function FreightTests.decoupleOutside(opts: Options?): Result
	local options: Options = opts or {}
	return runTest("decoupleOutside", function(ctx: Context): Result
		return decoupleOutsideTest(ctx, options)
	end)
end

-- One freight job end to end in the semi.
function FreightTests.freight(opts: Options?): Result
	local options: Options = opts or {}
	return runTest("freight", function(ctx: Context): Result
		return oneJobTest(ctx, "freight", options)
	end)
end

-- One towing job end to end in a pickup.
function FreightTests.towing(opts: Options?): Result
	local options: Options = opts or {}
	return runTest("towing", function(ctx: Context): Result
		return oneJobTest(ctx, "towing", options)
	end)
end

-- Jobs of `kind` back to back for `minutes`; the average $/min against PLAN.md §4.
function FreightTests.rate(kind: HaulKind, minutes: number, opts: Options?): Result
	local options: Options = opts or {}
	if (kind ~= "freight" and kind ~= "towing") or type(minutes) ~= "number" or minutes <= 0 then
		warn(`{LOG} rate(type, minutes) needs "freight" or "towing" and a positive number of minutes`)
		return emptyResult("rate", "bad arguments")
	end
	return runTest("rate", function(ctx: Context): Result
		return rateTest(ctx, kind, minutes, options)
	end)
end

local STARTERS: { [string]: (...any) -> Result } = {
	loop = FreightTests.loop,
	decoupleOutside = FreightTests.decoupleOutside,
	freight = FreightTests.freight,
	towing = FreightTests.towing,
	rate = FreightTests.rate,
}

-- Starts a test in the background and returns at once: start("loop"), start("decoupleOutside"), start("freight"),
-- start("towing"), start("rate", "freight", 10). Poll lastResult() or watch the console.
function FreightTests.start(name: TestName, ...: any)
	local starter = STARTERS[name]
	if starter == nil then
		warn(`{LOG} unknown test "{name}"; use "loop", "decoupleOutside", "freight", "towing" or "rate"`)
		return
	end
	task.spawn(starter, ...)
end

-- The last finished result, or nil while a test runs (or before any has finished).
function FreightTests.lastResult(): Result?
	local encoded = script:GetAttribute(RESULT)
	if script:GetAttribute(STATUS) == "running" or type(encoded) ~= "string" then
		return nil
	end
	return HttpService:JSONDecode(encoded)
end

-- "idle", "running", "done", "skipped", "stopped" or "failed", and what the running test is doing.
function FreightTests.status(): (string, string?)
	local status = script:GetAttribute(STATUS)
	local current = script:GetAttribute(CURRENT)
	return if type(status) == "string" then status else "idle", if type(current) == "string" then current else nil
end

-- Cancels a running test and hands the controls back; clears a "running" status left by a test whose thread died.
-- A job the test had accepted is cancelled by the test as it stops.
function FreightTests.stop()
	if not RunService:IsStudio() then
		return
	end
	script:SetAttribute(CANCEL, true)
	AutoDriver.stop()
	if script:GetAttribute(STATUS) == "running" then
		script:SetAttribute(STATUS, "stopped")
	end
end

return FreightTests
