--!strict
-- Delivery jobs (PLAN.md Phase 6; docs/phase-6-contracts.md "Delivery"). A job type module for JobService
-- (Types.JobType): load parcels at a JobDepot whose `jobType` is Config/Jobs delivery.depotJobType (stand nearly
-- still there for loadSeconds), then drop them at HousePlot locations, each needing the car to arrive and stop
-- for dropSeconds. No return to the depot.
--
-- The route:
--   * Drops: `stops` (3-4) of them, or `bonusStops` (4-6) in a bonus class (van, suv, pickup). The "extraStop"
--     level unlock moves the range up by one, never past the most any route carries (the larger of the two
--     maxima). The houses are picked at random from every HousePlot, so routes cross Riverside's streets and
--     cul-de-sacs rather than circling one court.
--   * Order: nearest-next by road. From the depot, the next drop is always the one with the shortest Pathfind
--     route from where the car is (ties keep the earlier pick). That is not the shortest possible tour, but it is
--     the order a driver would choose looking at the map, and it never doubles back across the suburb.
--   * Lengths (Types.Lengths): paidLength is the road route from the depot through every drop; routeLength (the
--     time limit) adds the unpaid leg from the car to the depot.
--
-- Pay (Types.PayBreakdown, whole dollars; the calibration of the inputs is in Config/Jobs's header):
--     base     = basePay + payPerDrop x drops
--     distance = paidLength x payPerStud
--     class    = (base + distance) x (bonusMultiplier - 1) in a bonus class (+20 %), else 0
--     tip      = 0 (delivery has no tips)
--     level    = (base + distance + class) x (level multiplier - 1)
--   JobService multiplies the total by the earnings boost and VIP when it pays.
--
-- Rate check (PLAN.md §4: $1,000/min at level 1). Measured with Lune: 600 real offers (sedan and van) routed by
-- the county's Pathfind, priced by payFor at level 1 without the bonus, at Config/Jobs's reference pace of 30 mph
-- (47.9 studs/s) with its 10 s to load, 7 s per drop and 15 s between jobs:
--     drops  paid route    pay     job time*   $/min*   leg back from the last drop   job time**  $/min**
--       3    4,362 studs   $2,631    158 s     $1,000          2,690 studs              193 s      $817
--       4    5,217 studs   $3,046    183 s     $1,000          2,712 studs              219 s      $836
--       5    5,770 studs   $3,354    201 s     $1,000          2,656 studs              236 s      $853
--       6    6,158 studs   $3,606    216 s     $1,000          2,643 studs              251 s      $863
--   * with a 1,000-stud leg to the depot (a player starting downtown: the used lot is 1,210 studs from it) and
--     the basePay (~$765) that leg gave. The pay formula is linear in the time each part costs, so every stop
--     count and route length lands on the same rate, and bonus classes earn x1.2 on top ($1,200/min).
--   ** chaining jobs back to back: the drive back from the last drop is ~2,700 studs (56 s), not 1,000 (21 s),
--     so with that basePay the steady rate was ~$840/min. Config/Jobs's TO_DEPOT_STUDS is now this measured
--     ~2,700 (basePay ~$1,356), which puts chained play on $1,000/min and a first job from downtown at ~$1,200.
--     Dev/JobTests.rate("delivery", n) measures the real number.
--
-- The pure helpers (eligibility, stop counts, picking, nearest-next ordering, pay) are exported for
-- tests/Delivery.spec; the four JobType functions at the bottom glue them to JobService's Context.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Jobs = require(ReplicatedStorage.Shared.Config.Jobs)
local MapLayout = require(ReplicatedStorage.Shared.Config.MapLayout)
local Types = require(script.Parent.Types)

type JobDef = Jobs.JobDef
type Location = MapLayout.Location
type Context = Types.Context
type Offer = Types.Offer
type Job = Types.Job
type Stop = Types.Stop
type PayBreakdown = Types.PayBreakdown
type StepResult = Types.StepResult

type Range = Jobs.Range

-- What an offer remembers (Offer.data; never sent to clients) and the job keeps (Job.data).
export type Data = {
	depotId: string, -- MapLayout location id of the depot
	dropIds: { string }, -- HousePlot location ids, in driving order
	paidLength: number, -- studs of road from the depot through the drops
	bonus: boolean, -- a bonus class: more stops, +20 %
}

-- The ordered route nearest-next produces.
export type Ordered<T> = {
	items: { T }, -- in driving order
	legs: { number }, -- legs[i]: road studs from the previous point (the start for i = 1) to items[i]
	length: number, -- the sum of the legs
}

local DEPOT_TAG = "JobDepot"
local DROP_TAG = "HousePlot"
local DEPOT_ATTRIBUTE = "jobType"
local EXTRA_STOP = "extraStop" -- Config/Jobs.unlockNames id: one more drop per route

-- What the player reads. %s and %d are filled in as noted.
local MESSAGES = {
	-- Titles stay short: the HUD's job slot shows them on one line.
	title = "Deliver %d parcels", -- drops
	titleArea = "%d parcels to %s", -- drops, the zone of the drops
	subtitle = "Load at %s", -- depot name
	loaded = "Parcels loaded. First drop: %s.", -- the first address
	delivered = "Delivered to %s. %d to go.", -- address, drops left
	deliveredLast = "Delivered to %s. That was the last one.", -- address
}

local Delivery = {}
-- The module itself is the JobType JobService plugs in (id, offers, start, onArrive, pay).
Delivery.id = "delivery" :: Types.JobKind

-- Pure helpers ---------------------------------------------------------------------------------------------

-- Whether a car of `classId` can do delivery jobs.
function Delivery.isEligible(def: JobDef, classId: string?): boolean
	return classId ~= nil and table.find(def.classes, classId) ~= nil
end

-- Whether `classId` gets the bonus (more stops, +20 %).
function Delivery.isBonusClass(def: JobDef, classId: string?): boolean
	local bonusClasses = def.bonusClasses
	return classId ~= nil and bonusClasses ~= nil and table.find(bonusClasses, classId) ~= nil
end

-- How many drops a route has in a car of `classId` with these level unlocks: `stops`, or `bonusStops` in a bonus
-- class; "extraStop" moves the range up by one, capped at the most either range allows.
function Delivery.stopRange(def: JobDef, classId: string?, unlocks: { [string]: boolean }?): Range
	local normal = def.stops :: Range
	local bonus = def.bonusStops or normal
	local range = if Delivery.isBonusClass(def, classId) then bonus else normal
	local min, max = range.min, range.max
	if unlocks and unlocks[EXTRA_STOP] then
		local ceiling = math.max(normal.max, bonus.max)
		min, max = math.min(min + 1, ceiling), math.min(max + 1, ceiling)
	end
	return { min = min, max = max }
end

-- A random drop count in stopRange.
function Delivery.stopCount(def: JobDef, classId: string?, unlocks: { [string]: boolean }?, random: Random): number
	local range = Delivery.stopRange(def, classId, unlocks)
	return random:NextInteger(range.min, range.max)
end

-- `count` different items from `candidates` at random (all of them, shuffled, when there are fewer).
function Delivery.pick<T>(candidates: { T }, count: number, random: Random): { T }
	local pool = table.clone(candidates)
	local picked: { T } = {}
	while #picked < count and #pool > 0 do
		table.insert(picked, table.remove(pool, random:NextInteger(1, #pool)) :: T)
	end
	return picked
end

-- Orders `items` nearest-next from `start`: each step goes to the remaining item with the shortest
-- `distance(from, to)` (road studs; nil = no route). Items no route reaches are left out. Ties keep the earlier
-- item. `start` and the items are whatever `distance` understands (positions, locations).
function Delivery.orderNearestNext<T>(start: T, items: { T }, distance: (from: T, to: T) -> number?): Ordered<T>
	local remaining = table.clone(items)
	local ordered: Ordered<T> = { items = {}, legs = {}, length = 0 }
	local here = start
	while #remaining > 0 do
		local bestIndex, bestLength = 0, math.huge
		for index, item in remaining do
			local length = distance(here, item)
			if length ~= nil and length < bestLength then
				bestIndex, bestLength = index, length
			end
		end
		if bestIndex == 0 then
			break -- nothing left is reachable from here
		end
		here = table.remove(remaining, bestIndex) :: T
		table.insert(ordered.items, here)
		table.insert(ordered.legs, bestLength)
		ordered.length += bestLength
	end
	return ordered
end

-- The pay for a route of `drops` drops and `paidLength` studs (see the header), in whole dollars, components
-- rounded down so they add up to the total exactly.
function Delivery.payFor(
	def: JobDef,
	drops: number,
	paidLength: number,
	bonus: boolean,
	levelMultiplier: number
): PayBreakdown
	local rawBase = def.basePay + (def.payPerDrop or 0) * drops
	local rawDistance = math.max(paidLength, 0) * def.payPerStud
	local rawClass = if bonus then (rawBase + rawDistance) * ((def.bonusMultiplier or 1) - 1) else 0
	local rawLevel = (rawBase + rawDistance + rawClass) * (levelMultiplier - 1)
	local base = math.floor(rawBase)
	local distance = math.floor(rawDistance)
	local class = math.floor(rawClass)
	local level = math.max(math.floor(rawLevel), 0)
	return {
		base = base,
		distance = distance,
		class = class,
		tip = 0,
		level = level,
		total = base + distance + class + level,
	}
end

-- The depots this job loads at: JobDepot locations whose jobType is def.depotJobType.
function Delivery.depotsIn(locations: { Location }, def: JobDef): { Location }
	local depots: { Location } = {}
	for _, location in locations do
		local attributes = location.attributes
		if location.tag == DEPOT_TAG and attributes and attributes[DEPOT_ATTRIBUTE] == def.depotJobType then
			table.insert(depots, location)
		end
	end
	return depots
end

-- Glue to JobService --------------------------------------------------------------------------------------

-- Road studs between two MapLayout locations' stops, cached by id pair: locations never move, and offers ask for
-- the same pairs over and over (26 houses and one depot: a few hundred routes at most). There is one cache per
-- router function (context.routeLength), held weakly, so a spec's stand-in router never shares answers with the
-- county's.
type LegCache = { [string]: number | false }
local legCaches: { [any]: LegCache } = setmetatable({}, { __mode = "k" }) :: any

local function stopPosition(context: Context, location: Location): Vector3
	return context.makeStop(location, "drop").position
end

local function legBetween(context: Context, from: Location, to: Location): number?
	local cache = legCaches[context.routeLength]
	if cache == nil then
		cache = {}
		legCaches[context.routeLength] = cache
	end
	local key = from.id .. ">" .. to.id
	local cached = cache[key]
	if cached == nil then
		local length = context.routeLength(stopPosition(context, from), stopPosition(context, to))
		local entry: number | false = if length ~= nil then length else false
		cache[key] = entry
		cached = entry
	end
	return if type(cached) == "number" then cached else nil
end

-- The leg from the car to the depot (0 without a car pose; JobService only offers to players in a car).
local function approachLength(context: Context, depot: Location): number?
	local pose = context.carPose
	if pose == nil then
		return 0
	end
	return context.routeLength(pose.Position, stopPosition(context, depot), pose.LookVector)
end

local function locationsById(context: Context, tag: string): { [string]: Location }
	local byId: { [string]: Location } = {}
	for _, location in context.locations(tag) do
		byId[location.id] = location
	end
	return byId
end

-- The depot nearest the car by road, with the leg to it (nil: no depot, or none reachable).
local function nearestDepot(context: Context): (Location?, number)
	local best: Location?, bestLength = nil, math.huge
	for _, depot in Delivery.depotsIn(context.locations(DEPOT_TAG), context.def) do
		local length = approachLength(context, depot)
		if length ~= nil and length < bestLength then
			best, bestLength = depot, length
		end
	end
	return best, bestLength
end

-- "Riverside" when every drop is in one zone, else nil.
local function areaOf(context: Context, drops: { Location }): string?
	local zoneId = drops[1] and drops[1].zone
	for _, drop in drops do
		if drop.zone ~= zoneId then
			return nil
		end
	end
	local zone = zoneId and context.mapLayout.zones[zoneId]
	return if zone then zone.displayName else nil
end

local function titleFor(context: Context, drops: { Location }): string
	local area = areaOf(context, drops)
	return if area then string.format(MESSAGES.titleArea, #drops, area) else string.format(MESSAGES.title, #drops)
end

-- Offers for the player's car: none unless its class can deliver; otherwise context.offerCount random routes
-- from the nearest depot, each priced at the player's level.
function Delivery.offers(_player: Player, _car: Model?, context: Context): { Offer }
	local def = context.def
	local offers: { Offer } = {}
	if not Delivery.isEligible(def, context.classId) then
		return offers
	end
	local depot, toDepot = nearestDepot(context)
	if depot == nil then
		return offers
	end
	local houses = context.locations(DROP_TAG)
	local bonus = Delivery.isBonusClass(def, context.classId)
	for _ = 1, context.offerCount do
		local count = Delivery.stopCount(def, context.classId, context.unlocks, context.random)
		local route = Delivery.orderNearestNext(depot, Delivery.pick(houses, count, context.random), function(a, b)
			return legBetween(context, a, b)
		end)
		local drops = route.items
		if #drops == 0 then
			continue
		end
		local dropIds: { string } = {}
		for _, drop in drops do
			table.insert(dropIds, drop.id)
		end
		local data: Data = { depotId = depot.id, dropIds = dropIds, paidLength = route.length, bonus = bonus }
		table.insert(offers, {
			id = context.newId(),
			type = Delivery.id,
			title = titleFor(context, drops),
			subtitle = string.format(MESSAGES.subtitle, depot.displayName),
			pay = Delivery.payFor(def, #drops, route.length, bonus, context.levelMultiplier).total,
			distance = toDepot + route.length,
			stops = #drops + 1, -- the depot, then the drops
			data = data,
		})
	end
	return offers
end

-- Builds the job from an accepted offer: the load stop at the depot, then the drops in the offer's order. The
-- leg to the depot is measured again from where the car is now (it may have moved since the offer).
function Delivery.start(player: Player, offer: Offer, context: Context): Job?
	local def = context.def
	local data = offer.data :: Data?
	if data == nil or not Delivery.isEligible(def, context.classId) then
		return nil
	end
	local depot = locationsById(context, DEPOT_TAG)[data.depotId]
	if depot == nil then
		return nil
	end
	local houses = locationsById(context, DROP_TAG)
	local stops: { Stop } = { context.makeStop(depot, "load", def.loadSeconds) }
	for _, dropId in data.dropIds do
		local house = houses[dropId]
		if house == nil then
			return nil
		end
		table.insert(stops, context.makeStop(house, "drop", def.dropSeconds))
	end
	local toDepot = approachLength(context, depot)
	if toDepot == nil then
		return nil -- no road from here to the depot
	end
	-- The bonus follows the car the job is accepted in (switching cars fails the job).
	local jobData: Data = {
		depotId = data.depotId,
		dropIds = table.clone(data.dropIds),
		paidLength = data.paidLength,
		bonus = Delivery.isBonusClass(def, context.classId),
	}
	return context.newJob(player, offer, stops, {
		routeLength = toDepot + data.paidLength,
		paidLength = data.paidLength,
	}, jobData)
end

-- The car has loaded at the depot or stopped at a drop: on to the next stop, or done after the last drop.
function Delivery.onArrive(job: Job, stopIndex: number, _context: Context): StepResult
	local stop = job.stops[stopIndex]
	local left = #job.stops - stopIndex
	if stop == nil or left <= 0 then
		return {
			outcome = "complete",
			message = if stop then string.format(MESSAGES.deliveredLast, stop.label) else nil,
		}
	end
	if stop.kind == "load" then
		return { outcome = "advance", message = string.format(MESSAGES.loaded, job.stops[stopIndex + 1].label) }
	end
	return { outcome = "advance", message = string.format(MESSAGES.delivered, stop.label, left) }
end

-- The pay for a finished job, at the player's level now.
function Delivery.pay(job: Job, context: Context): PayBreakdown
	local drops = 0
	for _, stop in job.stops do
		if stop.kind == "drop" then
			drops += 1
		end
	end
	local data = job.data :: Data?
	local bonus = if data then data.bonus else false
	return Delivery.payFor(context.def, drops, job.paidLength, bonus, context.levelMultiplier)
end

-- Checked against the interface (a type error here means Delivery no longer fits Types.JobType).
local _interface: Types.JobType = Delivery

return Delivery
