--!strict
-- The shared shapes of the jobs framework (docs/phase-6-contracts.md "Server"). JobService (init) runs the jobs;
-- each job type module (Rideshare, Delivery, Towing, Freight) plugs in through the JobType interface below. Keep
-- these stable: every job type module is written against them.
--
-- Life of a job:
--   offers    JobService asks every type module for a few Offers for the player's current car (Context says
--             which car, its class and seats). An Offer carries the module's own `data` (where to go), which
--             never leaves the server; the phone gets the rest.
--   start     the player accepts an offer: JobService gives it back to its module's start(), which builds the
--             Job (Context.newJob does the bookkeeping: id, deadline, car).
--   arrive    JobService watches the car (Heartbeat, server-observed positions only). When the chassis is within
--             Config/Jobs arriveRadius of the current stop and slower than stillSpeedMph (for the stop's `dwell`
--             seconds), it calls onArrive(job, index, context). The StepResult says what happens next.
--   pay       on "complete", JobService calls pay(job, context) for the PayBreakdown, multiplies its total by
--             EconomyService.earningsMultiplier and JobService.vipMultiplier, pays it and adds XP.
-- Fails (time-out, out of the car too long, another car, car gone) and cancels are JobService's alone.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local Graph = require(Shared.Road.Graph)
local Jobs = require(Shared.Config.Jobs)
local MapLayout = require(Shared.Config.MapLayout)
local Pathfind = require(Shared.Road.Pathfind)

-- A Config/Jobs JobType id: "rideshare" | "delivery" | "towing" | "freight". Typed as a plain string so ids read from config tables
-- and remotes need no casts; Config/Jobs.types lists the valid ones.
export type JobKind = string

-- couple / decouple (Phase 8, towing and freight): the stop is done when the server sees the job's car couple the
-- job's trailer or towed car (Job.towTarget), and when it uncouples it at the drop, rather than by stopping there.
-- waypoint (freight long hauls): done by passing within the type's waypointRadius, at any speed.
export type StopKind = "pickup" | "dropoff" | "load" | "drop" | "couple" | "decouple" | "waypoint"

export type Stop = {
	position: Vector3, -- where the stop is (the kerbside spot; the client stands its figure or parcel here)
	locationId: string?, -- MapLayout location id, when the stop is one
	kind: StopKind,
	label: string, -- what the player reads ("Town Square", "5 Cedar Court")
	-- The nearest point on a road's centre line to `position`. A car within arriveRadius of either point has
	-- arrived, so a big lot or a pad set back from the road still counts from the street.
	approach: Vector3?,
	-- Seconds the car must stay within the radius and nearly still before the stop counts (loading parcels,
	-- a passenger getting in). nil or 0: as soon as it stops.
	dwell: number?,
}

-- What the phone lists. `data` is the module's own (pickup and drop-off, drop list) and is never sent to clients.
export type Offer = {
	id: string, -- unique per offer (at most 40 characters: Net JobAction offerId)
	type: JobKind,
	title: string, -- "Fare to Theater Row"
	subtitle: string, -- "Pick up at Town Square"
	-- Estimated pay in $: the PayBreakdown total the module expects without any tip, with the level multiplier
	-- (Context.levelMultiplier) but before earnings boosts and VIP (JobService applies those when it shows it).
	pay: number,
	distance: number, -- studs of road the job drives in all (pickup or depot leg included)
	stops: number, -- how many stops the job has
	xl: boolean?, -- rideshare: an XL fare
	data: any?,
}

export type JobState = "offered" | "accepted" | "complete" | "failed"

-- Smooth-driving record for tips, kept by JobService while `tracking` is on (rideshare: passenger aboard).
export type Smoothness = {
	tracking: boolean,
	hardBrakes: number,
	crashes: number,
	lastEventAt: number, -- os.clock() of the last counted event (events closer than Config cooldown are one)
	lastEvent: ("hardBrake" | "crash")?, -- what that event was
}

export type Job = {
	id: string, -- a GUID (at most 64 characters: Net JobAction jobId)
	type: JobKind,
	player: Player,
	title: string,
	stops: { Stop },
	index: number, -- the current stop
	startedAt: number, -- os.clock()
	deadline: number, -- os.clock()
	routeLength: number, -- studs of road for the whole job (pickup or depot leg included): the time limit
	-- Studs of road that pay (rideshare: the pickup leg up to pickupMaxStuds, then the ride; delivery: depot
	-- through the drops): pay and XP.
	paidLength: number,
	car: Model?, -- the car the job was accepted in; another car, or this one gone, fails the job
	carUid: string?, -- its OwnedUid, when it is a garage car
	estPay: number, -- the offer's estimate (before boosts and VIP)
	xl: boolean?,
	state: JobState,
	smooth: Smoothness,
	data: any, -- the module's own
	-- Towing and freight: the trailer or broken-down car the job hitches (the module spawns it in start). JobService
	-- watches its coupling at couple / decouple stops, fails the job when it comes off anywhere else, and uncouples
	-- it when the job ends.
	towTarget: Model?,
}

export type Lengths = { routeLength: number, paidLength: number }

-- What a job type module gets from JobService on every call.
export type Context = {
	now: number, -- os.clock()
	def: Jobs.JobDef, -- this job type's Config/Jobs entry
	graph: Graph.Api,
	pathfind: Pathfind.Router,
	mapLayout: typeof(MapLayout),
	-- The player's current car (offers, start) or the job's car (onArrive, pay); nil when they have none out.
	car: Model?,
	carPose: CFrame?, -- the car's chassis pose as the server sees it
	vehicleId: string?,
	classId: string?, -- Config/Classes id
	seats: number, -- the trim's seats (0 with no car)
	level: number, -- the player's level in this job type (1 = new)
	levelMultiplier: number, -- pay multiplier of that level
	unlocks: { [string]: boolean }, -- every unlock id reached at that level or below (Config/Jobs levels)
	offerCount: number, -- how many offers to make (Config/Jobs offers.perType, plus "extraOffer")
	-- The job licenses the player holds (PlayerData.jobs.licenses; Config/Jobs JobDef.license). nil: not loaded.
	licenses: { [string]: boolean }?,
	random: Random,
	newId: () -> string, -- a fresh id for an offer
	-- Studs of road on the fastest route, or nil when there is none. `heading` (a LookVector) makes it start
	-- forward, like the GPS.
	routeLength: (from: Vector3, to: Vector3, heading: Vector3?) -> number?,
	-- Every MapLayout location with this CollectionService tag.
	locations: (tag: string) -> { MapLayout.Location },
	-- A stop at a MapLayout location: position (its GPS target or footprint centre), label (display name),
	-- approach (nearest road point) and dwell filled in.
	makeStop: (location: MapLayout.Location, kind: StopKind, dwell: number?) -> Stop,
	-- A new Job in state "accepted" at stop 1, with its id, deadline (from routeLength and the type's time
	-- limit), car and smoothness record set. The module fills nothing else in but `data` (passed here).
	newJob: (player: Player, offer: Offer, stops: { Stop }, lengths: Lengths, data: any?) -> Job,
}

-- What onArrive tells JobService.
export type StepResult = {
	outcome: "advance" | "complete" | "fail", -- next stop / pay and finish / fail with `message`
	message: string?, -- a short notice for the player
	-- true: start counting hard braking and crashes for the tip (passenger aboard); false: stop.
	smoothTracking: boolean?,
}

-- Dollar amounts; total = base + distance + class + tip + level. JobService multiplies the total by
-- EconomyService.earningsMultiplier and JobService.vipMultiplier before paying it.
export type PayBreakdown = {
	base: number,
	distance: number, -- paid length x payPerStud
	class: number, -- extra from the car's class (XL fares, the delivery bonus classes)
	tip: number,
	level: number, -- extra from the level multiplier
	total: number,
}

-- The interface every job type module implements (docs/phase-6-contracts.md).
export type JobType = {
	id: JobKind,
	offers: (player: Player, car: Model?, context: Context) -> { Offer },
	start: (player: Player, offer: Offer, context: Context) -> Job?,
	onArrive: (job: Job, stopIndex: number, context: Context) -> StepResult,
	pay: (job: Job, context: Context) -> PayBreakdown,
}

-- What a job type module may also have (towing, freight): `finish(job, outcome)`, called once when a job of its
-- type ends however it ends ("complete" or "failed", cancels included), after JobService has uncoupled the job's
-- towTarget. The module removes what it put in the world.
export type Finish = (job: Job, outcome: JobState) -> ()

return {}
