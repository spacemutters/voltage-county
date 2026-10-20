--!strict
-- Freight jobs (PLAN.md Phase 8; docs/phase-8-contracts.md "Jobs"). A job type module for JobService
-- (Types.JobType): couple a trailer waiting at one freight depot's TrailerSpawn spot, haul it to another freight
-- depot and uncouple it there. Freight pays the most per minute (§4: $3,000).
--
-- Who can haul: a car of a Config/Jobs freight class (heavy) with the "kingpin" feature (the semi), driven by a
-- player who holds the freight license (PlayerData.jobs.licenses.freight). JobService checks all three before it
-- asks for offers and says what is missing (the license reason tells how to get it: the XP gate, then BuyLicense
-- and its price); offers() and start() check them again.
--
-- The offers (context.offerCount of them):
--   * short runs: from the depot nearest the truck by road (then the next nearest, for a fourth offer) to each
--     other depot, in a random order, by the fastest road;
--   * the last offer is a long haul: from the nearest depot to another one the long way round the County Loop.
--     Its route has waypoint stops on the loop itself, at least one every Config/Jobs loopWaypointDegrees of
--     the ring, spread along the side of the ring away from the short way, so the route really goes round
--     (Freight.loopWaypoints). With a single depot a long haul is the whole ring, back to where it started.
--
-- The trailer: the idle one waiting on a TrailerSpawn spot (Services/HitchService stands one on each, its model
-- named by the spot's `trailer` attribute). Offers only use spots with an idle trailer; accepting takes it for
-- the job (HitchService.takeTrailer: only this player may hitch it, and HitchService neither despawns nor
-- restocks it while the job has it). The job removes it when it ends: Config/Jobs props.despawnDelaySec after a
-- delivery (so it doesn't vanish under the player's eyes, and depots don't fill up), at once after a fail or
-- cancel; HitchService then stocks a fresh one on its spot. Whatever trailer the player couples at the origin
-- depot counts (JobService adopts it, and the job's own goes back): the job never stalls because the player
-- backed under the trailer one spot along.
--
-- Stops: "couple" at the TrailerSpawn, the long haul's "waypoint"s, then "decouple" at the destination depot.
-- JobService watches the coupling (Types.StopKind) and fails the job if the trailer comes off anywhere else.
--
-- Pay (Types.PayBreakdown, whole dollars; the calibration is in Config/Jobs's header, $3,000/min):
--     base     = basePay (coupling, uncoupling and the time between jobs)
--     distance = haul studs x payPerStud (longHaulPayPerStud on a long haul) + approach x approachPayPerStud
--     level    = (base + distance) x (level multiplier - 1)
--   The approach is the road from where the truck is at the accept to the trailer, paid up to approachMaxStuds;
--   the haul is the road from the trailer through any waypoints to the destination. No tips, no class bonus.
--
-- The pure helpers (eligibility, the license, pay, depots and their spots, the loop waypoints) are exported for
-- tests/FreightJobs.spec; the JobType functions at the bottom glue them to JobService's Context. Freight.props
-- finds, takes and removes trailers; a spec swaps it for a stand-in.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local Catalog = require(Shared.Vehicle.Catalog)
local Jobs = require(Shared.Config.Jobs)
local MapLayout = require(Shared.Config.MapLayout)
local RoadGraph = require(Shared.Config.RoadGraph)
local Types = require(script.Parent.Types)

type JobDef = Jobs.JobDef
type Location = MapLayout.Location
type Context = Types.Context
type Offer = Types.Offer
type Job = Types.Job
type Stop = Types.Stop
type PayBreakdown = Types.PayBreakdown
type StepResult = Types.StepResult

-- What an offer remembers (Offer.data; never sent to clients) and the job keeps (Job.data).
export type Data = {
	spawnId: string, -- the TrailerSpawn location the trailer waits on (couple)
	originId: string, -- its freight depot (JobDepot location id)
	destinationId: string, -- the freight depot it goes to (decouple)
	waypointIds: { string }, -- long hauls: RoadGraph loop node ids, in driving order (empty on a short run)
	longHaul: boolean,
	trailer: string, -- the trailer's ServerStorage.TrailerModels name
	approach: number, -- studs of road from the truck to the trailer (the job keeps only the paid part)
	haul: number, -- studs of road from the trailer through the waypoints to the destination
	reserved: Model?, -- job only: the spot's trailer, taken for the job (removed when the job ends)
}

-- A node of the County Loop (RoadGraph.loopNodeIds) and where it is.
export type LoopNode = { id: string, position: Vector3 }

-- What finds, takes and removes the job's trailer. The defaults use Services/HitchService's depot trailers.
export type Props = {
	-- Whether an idle trailer waits on the TrailerSpawn spot (offers only use those).
	idle: (spot: Location) -> boolean,
	-- The spot's idle trailer, taken for `owner`'s job, or nil when there is none now.
	take: (spot: Location, owner: Player) -> Model?,
	despawn: (model: Model, delaySeconds: number) -> (),
}

local DEPOT_TAG = "JobDepot"
local SPAWN_TAG = "TrailerSpawn"
local WAYPOINT_TAG = "Waypoint" -- the made-up tag of a waypoint stop's location (never in the world)
local DEPOT_ATTRIBUTE = "jobType" -- JobDepot: which job it serves
local SPAWN_DEPOT_ATTRIBUTE = "depot" -- TrailerSpawn: its depot's location id
local SPAWN_TRAILER_ATTRIBUTE = "trailer" -- TrailerSpawn: the model of the trailer that waits there
local LOOP_ZONE = "county_loop" -- MapLayout zone of the ring (its display name labels waypoints)
local HITCH_SERVICE = "HitchService" -- Services/HitchService, required when first needed
local TAU = 2 * math.pi
local SAME_ANGLE = 1e-6 -- radians: two points closer than this round the loop are at the same place

-- What the player reads. %s are filled in as noted.
local MESSAGES = {
	title = "%s to %s", -- the trailer's cargo, the destination depot
	longTitle = "Long haul to %s", -- the destination depot
	subtitle = "Hitch up at %s", -- the origin depot
	longSubtitle = "%s round the County Loop from %s", -- the cargo, the origin depot
	waypoint = "%s, %s side", -- the loop's name, a compass side ("County Loop, west side")
	coupled = "Trailer coupled. Deliver it to %s.", -- the next stop
	coupledLong = "Trailer coupled. Head round the loop: %s first.", -- the first waypoint
	passed = "On to %s.", -- the next stop
	delivered = "Trailer delivered to %s.", -- the destination
}
-- Compass sides of the loop, by the axis a waypoint is farthest along (north is -Z).
local SIDES = { east = "east", west = "west", north = "north", south = "south" }

local Freight = {}
-- The module itself is the JobType JobService plugs in (id, offers, start, onArrive, pay, finish).
Freight.id = "freight" :: Types.JobKind

-- TrailerSpawn spots in use: location id -> the id of the job whose trailer it is.
local taken: { [string]: string } = {}

-- Pure helpers ---------------------------------------------------------------------------------------------

-- Whether a car of `classId` (catalog vehicle `vehicleId`) can haul freight: an eligible class and the feature
-- the def asks for (the semi's kingpin).
function Freight.isEligible(def: JobDef, classId: string?, vehicleId: string?): boolean
	if classId == nil or table.find(def.classes, classId) == nil then
		return false
	end
	local feature = def.requiresFeature
	if feature == nil then
		return true
	end
	local vehicle = if vehicleId ~= nil then Catalog.getVehicle(vehicleId) else nil
	return vehicle ~= nil and table.find(vehicle.features, feature :: any) ~= nil
end

-- Whether `licenses` (PlayerData.jobs.licenses; nil = not loaded) hold the license the def needs.
function Freight.hasLicense(def: JobDef, licenses: { [string]: boolean }?): boolean
	local license = def.license
	return license == nil or (licenses ~= nil and licenses[license] == true)
end

-- The studs of an approach leg that are paid: all of it, up to def.approachMaxStuds.
function Freight.paidApproach(def: JobDef, studs: number): number
	return math.clamp(studs, 0, def.approachMaxStuds or math.huge)
end

-- The approach the pay counts: the road route from `from` to `to`, but at most Jobs.approachDetourFactor x the
-- straight-line distance (the route loops round the block when the truck already stands by the trailer).
function Freight.approachStuds(routeStuds: number, from: Vector3, to: Vector3): number
	local dx, dz = to.X - from.X, to.Z - from.Z
	return math.min(routeStuds, math.sqrt(dx * dx + dz * dz) * Jobs.approachDetourFactor)
end

-- The pay for a haul of `haulStuds` (a long haul or a short run) after an approach of `approachStuds` (see the
-- header), in whole dollars, components rounded down so they add up to the total exactly.
function Freight.payFor(
	def: JobDef,
	approachStuds: number,
	haulStuds: number,
	longHaul: boolean,
	levelMultiplier: number
): PayBreakdown
	local perStud = if longHaul then def.longHaulPayPerStud or def.payPerStud else def.payPerStud
	local rawBase = def.basePay
	local rawDistance = math.max(haulStuds, 0) * perStud
		+ Freight.paidApproach(def, approachStuds) * (def.approachPayPerStud or 0)
	local rawLevel = (rawBase + rawDistance) * (math.max(levelMultiplier, 1) - 1)
	local base = math.floor(rawBase)
	local distance = math.floor(rawDistance)
	local level = math.floor(rawLevel)
	return { base = base, distance = distance, class = 0, tip = 0, level = level, total = base + distance + level }
end

-- The freight depots among `locations`: JobDepots whose jobType is def.depotJobType.
function Freight.depotsIn(locations: { Location }, def: JobDef): { Location }
	local depots: { Location } = {}
	for _, location in locations do
		local attributes = location.attributes
		if location.tag == DEPOT_TAG and attributes ~= nil and attributes[DEPOT_ATTRIBUTE] == def.depotJobType then
			table.insert(depots, location)
		end
	end
	return depots
end

local function flatDistance(a: Vector3, b: Vector3): number
	return Vector2.new(a.X - b.X, a.Z - b.Z).Magnitude
end

-- The TrailerSpawn spots of each depot (depot id -> spots, in map order): the depot named by a spot's `depot`
-- attribute, or the nearest depot in a straight line when it names none (or one that isn't a freight depot).
function Freight.spotsByDepot(spots: { Location }, depots: { Location }): { [string]: { Location } }
	local byDepot: { [string]: { Location } } = {}
	local known: { [string]: boolean } = {}
	for _, depot in depots do
		byDepot[depot.id] = {}
		known[depot.id] = true
	end
	for _, spot in spots do
		local attributes = spot.attributes
		local named = if attributes ~= nil then attributes[SPAWN_DEPOT_ATTRIBUTE] else nil
		local depotId: string? = if type(named) == "string" and known[named] then named else nil
		if depotId == nil then
			local best = math.huge
			for _, depot in depots do
				local distance = flatDistance(spot.position, depot.position)
				if distance < best then
					depotId, best = depot.id, distance
				end
			end
		end
		if depotId ~= nil then
			table.insert(byDepot[depotId], spot)
		end
	end
	return byDepot
end

-- The County Loop's nodes in driving order (Config/RoadGraph.loopNodeIds), with their positions.
function Freight.loopNodes(): { LoopNode }
	local positions: { [string]: Vector3 } = {}
	for _, node in RoadGraph.nodes do
		positions[node.id] = node.position
	end
	local nodes: { LoopNode } = {}
	for _, id in RoadGraph.loopNodeIds do
		local position = positions[id]
		if position then
			table.insert(nodes, { id = id, position = position })
		end
	end
	return nodes
end

-- The middle of the ring: the average of its nodes.
local function centreOf(loop: { LoopNode }): Vector3
	local sum = Vector3.zero
	for _, node in loop do
		sum += Vector3.new(node.position.X, 0, node.position.Z)
	end
	return sum / math.max(#loop, 1)
end

local function angleAround(centre: Vector3, point: Vector3): number
	return math.atan2(point.Z - centre.Z, point.X - centre.X)
end

-- The smallest angle (radians, 0..pi) between two directions.
local function angleBetween(a: number, b: number): number
	local difference = (a - b) % TAU
	return math.min(difference, TAU - difference)
end

-- The loop nodes a long haul from `from` to `to` passes, in order: the long way round the ring (the arc that is
-- not the short way; the whole ring when both ends are at the same place), with a waypoint at least every
-- `maxDegrees` of it, spread evenly along it, each the node nearest its angle. At least one waypoint. Nodes that
-- come out the same twice in a row are listed once.
function Freight.loopWaypoints(from: Vector3, to: Vector3, loop: { LoopNode }, maxDegrees: number): { LoopNode }
	local waypoints: { LoopNode } = {}
	if #loop == 0 then
		return waypoints
	end
	local centre = centreOf(loop)
	local start, finish = angleAround(centre, from), angleAround(centre, to)
	local ahead = (finish - start) % TAU -- going round one way
	local sweep: number
	if ahead < SAME_ANGLE or TAU - ahead < SAME_ANGLE then
		sweep = TAU -- the same place: the whole ring
	elseif ahead >= math.pi then
		sweep = ahead -- this way round is the long way
	else
		sweep = ahead - TAU -- the long way is the other way round
	end
	local count = math.max(1, math.ceil(math.abs(sweep) / math.rad(maxDegrees)) - 1)
	for index = 1, count do
		local target = start + sweep * index / (count + 1)
		local best: LoopNode, bestAngle = loop[1], math.huge
		for _, node in loop do
			local angle = angleBetween(angleAround(centre, node.position), target)
			if angle < bestAngle then
				best, bestAngle = node, angle
			end
		end
		if waypoints[#waypoints] ~= best then
			table.insert(waypoints, best)
		end
	end
	return waypoints
end

-- Which side of the ring a point is on ("north" is -Z).
function Freight.sideOf(point: Vector3, centre: Vector3): string
	local x, z = point.X - centre.X, point.Z - centre.Z
	if math.abs(x) >= math.abs(z) then
		return if x >= 0 then SIDES.east else SIDES.west
	end
	return if z >= 0 then SIDES.south else SIDES.north
end

-- The cargo a trailer model carries (Config/Jobs freight.trailers), or the model name.
function Freight.cargoOf(def: JobDef, trailer: string): string
	local choices: { Jobs.TrailerChoice } = def.trailers or {}
	for _, choice in choices do
		if choice.model == trailer then
			return choice.cargo
		end
	end
	return trailer
end

-- The trailer model a spot's trailer is: the spot's `trailer` attribute, or a random Config/Jobs trailer.
function Freight.trailerAt(def: JobDef, spot: Location, random: Random): string?
	local attributes = spot.attributes
	local named = if attributes ~= nil then attributes[SPAWN_TRAILER_ATTRIBUTE] else nil
	if type(named) == "string" then
		return named
	end
	local choices = def.trailers or {}
	return if #choices > 0 then choices[random:NextInteger(1, #choices)].model else nil
end

-- A copy of `list` in a random order.
function Freight.shuffled<T>(list: { T }, random: Random): { T }
	local copy = table.clone(list)
	for index = #copy, 2, -1 do
		local other = random:NextInteger(1, index)
		copy[index], copy[other] = copy[other], copy[index]
	end
	return copy
end

-- Whether the TrailerSpawn spot `id` is free (no job's trailer is on it).
function Freight.isFree(id: string): boolean
	return taken[id] == nil
end

-- Props -------------------------------------------------------------------------------------------------------

-- Services/HitchService, looked up once (nil when it is missing or fails to load: no depot trailers then).
local hitchModule: any = nil
local function hitchService(): any?
	if hitchModule == nil then
		hitchModule = false
		local child = script.Parent.Parent:FindFirstChild(HITCH_SERVICE)
		if child ~= nil and child:IsA("ModuleScript") then
			local ok, result = pcall(require :: any, child)
			if ok and type(result) == "table" then
				hitchModule = result
			end
		end
	end
	return if hitchModule ~= false then hitchModule else nil
end

local function idleTrailer(spot: Location): boolean
	local hitch = hitchService()
	return hitch ~= nil and hitch.idleTrailer(spot.id) ~= nil
end

local function takeTrailer(spot: Location, owner: Player): Model?
	local hitch = hitchService()
	return if hitch ~= nil then hitch.takeTrailer(spot.id, owner) else nil
end

-- Removes a trailer now, or after `delaySeconds` (one task.delay, no polling).
local function despawn(model: Model, delaySeconds: number)
	if delaySeconds <= 0 then
		model:Destroy()
		return
	end
	task.delay(delaySeconds, function()
		if model.Parent ~= nil then
			model:Destroy()
		end
	end)
end

-- Replaceable (tests/FreightJobs.spec puts stand-ins here).
Freight.props = { idle = idleTrailer, take = takeTrailer, despawn = despawn } :: Props

-- Glue to JobService --------------------------------------------------------------------------------------

local loopNodes: { LoopNode }? = nil
local function loop(): { LoopNode }
	local cached = loopNodes
	if cached ~= nil then
		return cached
	end
	local nodes = Freight.loopNodes()
	loopNodes = nodes
	return nodes
end

local function stopPoint(location: Location): Vector3
	return location.gpsTarget or location.position
end

-- Road studs between two points, cached by key per router function (held weakly, so a spec's stand-in router
-- never shares answers with the county's). Locations and loop nodes never move.
type LegCache = { [string]: number | false }
local legCaches: { [any]: LegCache } = setmetatable({}, { __mode = "k" }) :: any

local function leg(context: Context, fromId: string, from: Vector3, toId: string, to: Vector3): number?
	local cache = legCaches[context.routeLength]
	if cache == nil then
		cache = {}
		legCaches[context.routeLength] = cache
	end
	local key = fromId .. ">" .. toId
	local cached = cache[key]
	if cached == nil then
		local length = context.routeLength(from, to)
		local entry: number | false = if length ~= nil then length else false
		cache[key] = entry
		cached = entry
	end
	return if type(cached) == "number" then cached else nil
end

-- The haul from the spot through the waypoints to the destination, in studs of road (nil: some leg has no road).
local function haulLength(context: Context, spot: Location, waypoints: { LoopNode }, destination: Location): number?
	local total = 0
	local fromId, from = spot.id, stopPoint(spot)
	for _, node in waypoints do
		local length = leg(context, fromId, from, node.id, node.position)
		if length == nil then
			return nil
		end
		total += length
		fromId, from = node.id, node.position
	end
	local last = leg(context, fromId, from, destination.id, stopPoint(destination))
	return if last ~= nil then total + last else nil
end

local function isEligibleNow(context: Context): boolean
	return Freight.isEligible(context.def, context.classId, context.vehicleId)
		and Freight.hasLicense(context.def, context.licenses)
end

-- A depot the truck can start from: a usable spot of it, and the road to that spot.
type Origin = { depot: Location, spot: Location, approach: number }

-- A spot no job has now, with an idle trailer waiting on it.
local function usable(spot: Location): boolean
	return Freight.isFree(spot.id) and Freight.props.idle(spot)
end

-- The depots with a usable spot, nearest the truck by road first (the first usable spot of each, in map order).
local function originsFor(context: Context, depots: { Location }, spots: { [string]: { Location } }): { Origin }
	local pose = context.carPose :: CFrame
	local origins: { Origin } = {}
	for _, depot in depots do
		local depotSpots: { Location } = spots[depot.id] or {}
		for _, spot in depotSpots do
			if usable(spot) then
				local point = stopPoint(spot)
				local route = context.routeLength(pose.Position, point, pose.LookVector)
				if route ~= nil then
					local approach = Freight.approachStuds(route, pose.Position, point)
					table.insert(origins, { depot = depot, spot = spot, approach = approach })
				end
				break
			end
		end
	end
	table.sort(origins, function(a, b)
		return a.approach < b.approach
	end)
	return origins
end

local function waypointIds(waypoints: { LoopNode }): { string }
	local ids: { string } = {}
	for _, node in waypoints do
		table.insert(ids, node.id)
	end
	return ids
end

-- One offer from `origin` to `destination` (long: the long way round the loop), or nil when there is no road.
local function makeOffer(context: Context, origin: Origin, destination: Location, long: boolean): Offer?
	local def = context.def
	local waypoints = if long
		then Freight.loopWaypoints(
			stopPoint(origin.spot),
			stopPoint(destination),
			loop(),
			def.loopWaypointDegrees or math.huge
		)
		else {}
	local haul = haulLength(context, origin.spot, waypoints, destination)
	local trailer = Freight.trailerAt(def, origin.spot, context.random)
	if haul == nil or trailer == nil then
		return nil
	end
	local cargo = Freight.cargoOf(def, trailer)
	local data: Data = {
		spawnId = origin.spot.id,
		originId = origin.depot.id,
		destinationId = destination.id,
		waypointIds = waypointIds(waypoints),
		longHaul = long,
		trailer = trailer,
		approach = origin.approach,
		haul = haul,
		reserved = nil,
	}
	return {
		id = context.newId(),
		type = Freight.id,
		title = if long
			then string.format(MESSAGES.longTitle, destination.displayName)
			else string.format(MESSAGES.title, cargo, destination.displayName),
		subtitle = if long
			then string.format(MESSAGES.longSubtitle, cargo, origin.depot.displayName)
			else string.format(MESSAGES.subtitle, origin.depot.displayName),
		pay = Freight.payFor(def, origin.approach, haul, long, context.levelMultiplier).total,
		distance = origin.approach + haul,
		stops = #waypoints + 2, -- the trailer, the waypoints, the destination
		data = data,
	}
end

-- Offers for the player's semi: none without the class, the kingpin and the license; otherwise short runs from
-- the nearest depots and, last, a long haul (see the header), priced at the player's level.
function Freight.offers(_player: Player, car: Model?, context: Context): { Offer }
	local def = context.def
	local offers: { Offer } = {}
	if car == nil or context.carPose == nil or not isEligibleNow(context) then
		return offers
	end
	local depots = Freight.depotsIn(context.locations(DEPOT_TAG), def)
	local origins = originsFor(context, depots, Freight.spotsByDepot(context.locations(SPAWN_TAG), depots))
	if #origins == 0 then
		return offers
	end
	local shortRuns = context.offerCount - 1
	for _, origin in origins do
		for _, destination in Freight.shuffled(depots, context.random) do
			if #offers >= shortRuns then
				break
			end
			if destination.id ~= origin.depot.id then
				local offer = makeOffer(context, origin, destination, false)
				if offer ~= nil then
					table.insert(offers, offer)
				end
			end
		end
	end
	local nearest = origins[1]
	local others: { Location } = {}
	for _, depot in depots do
		if depot.id ~= nearest.depot.id then
			table.insert(others, depot)
		end
	end
	local destination = if #others > 0 then others[context.random:NextInteger(1, #others)] else nearest.depot
	local long = makeOffer(context, nearest, destination, true)
	if long ~= nil then
		table.insert(offers, long)
	end
	return offers
end

local function findLocation(context: Context, tag: string, id: string): Location?
	for _, location in context.locations(tag) do
		if location.id == id then
			return location
		end
	end
	return nil
end

-- The waypoint stops' locations: made up from loop nodes, labelled with the ring's name and side.
local function waypointLocation(context: Context, node: LoopNode): Location
	local zone = context.mapLayout.zones[LOOP_ZONE]
	local name = if zone ~= nil then zone.displayName else LOOP_ZONE
	return {
		id = node.id,
		displayName = string.format(MESSAGES.waypoint, name, Freight.sideOf(node.position, centreOf(loop()))),
		tag = WAYPOINT_TAG,
		zone = LOOP_ZONE,
		position = node.position,
		yaw = 0,
		size = Vector3.zero,
	}
end

-- The spot to couple at: the offer's, or another usable spot of the same depot when that one is taken now.
local function usableSpotFor(context: Context, data: Data): Location?
	local wanted = findLocation(context, SPAWN_TAG, data.spawnId)
	if wanted ~= nil and usable(wanted) then
		return wanted
	end
	local depots = Freight.depotsIn(context.locations(DEPOT_TAG), context.def)
	local spots: { Location } = Freight.spotsByDepot(context.locations(SPAWN_TAG), depots)[data.originId] or {}
	for _, spot in spots do
		if usable(spot) then
			return spot
		end
	end
	return nil
end

-- Builds the job from an accepted offer: takes the idle trailer on the origin spot (or another of the depot's
-- when that one has gone), then the couple, waypoint and decouple stops. The approach is measured again from
-- where the truck is now.
function Freight.start(player: Player, offer: Offer, context: Context): Job?
	local def = context.def
	local data = offer.data :: Data?
	local pose = context.carPose
	if type(data) ~= "table" or pose == nil or not isEligibleNow(context) then
		return nil
	end
	local spot = usableSpotFor(context, data)
	local destination = findLocation(context, DEPOT_TAG, data.destinationId)
	if spot == nil or destination == nil then
		return nil
	end
	local nodes: { [string]: LoopNode } = {}
	for _, node in loop() do
		nodes[node.id] = node
	end
	local stops: { Stop } = { context.makeStop(spot, "couple") }
	for _, id in data.waypointIds do
		local node = nodes[id]
		if node == nil then
			return nil
		end
		table.insert(stops, context.makeStop(waypointLocation(context, node), "waypoint"))
	end
	table.insert(stops, context.makeStop(destination, "decouple"))
	local point = stopPoint(spot)
	local route = context.routeLength(pose.Position, point, pose.LookVector)
	local approach = if route then route else data.approach
	local target = Freight.props.take(spot, player)
	if target == nil then
		return nil
	end
	local paidApproach =
		Freight.paidApproach(def, if route then Freight.approachStuds(route, pose.Position, point) else data.approach)
	local jobData: Data = {
		spawnId = spot.id,
		originId = data.originId,
		destinationId = data.destinationId,
		waypointIds = table.clone(data.waypointIds),
		longHaul = data.longHaul,
		trailer = target.Name,
		approach = paidApproach,
		haul = data.haul,
		reserved = target,
	}
	local ok, job = pcall(context.newJob, player, offer, stops, {
		routeLength = approach + data.haul,
		paidLength = paidApproach + data.haul,
	}, jobData)
	if not ok or type(job) ~= "table" then
		Freight.props.despawn(target, 0) -- HitchService stocks the spot again
		return nil
	end
	local started = job :: Job
	started.towTarget = target
	taken[spot.id] = started.id
	target:SetAttribute(Jobs.props.jobAttribute, started.id)
	return started
end

-- Coupled at the origin, past a waypoint: on to the next stop. Uncoupled at the destination: done.
function Freight.onArrive(job: Job, stopIndex: number, _context: Context): StepResult
	local stop = job.stops[stopIndex]
	local nextStop = job.stops[stopIndex + 1]
	if stop == nil or nextStop == nil then
		return { outcome = "complete", message = if stop then string.format(MESSAGES.delivered, stop.label) else nil }
	end
	if stop.kind == "couple" then
		local format = if nextStop.kind == "waypoint" then MESSAGES.coupledLong else MESSAGES.coupled
		return { outcome = "advance", message = string.format(format, nextStop.label) }
	end
	return { outcome = "advance", message = string.format(MESSAGES.passed, nextStop.label) }
end

-- The pay for a finished haul, at the player's level now.
function Freight.pay(job: Job, context: Context): PayBreakdown
	local data = job.data :: Data
	return Freight.payFor(context.def, data.approach, data.haul, data.longHaul, context.levelMultiplier)
end

-- The job is over: free its spot and remove its trailers, so HitchService stocks their spots again. The hauled
-- one goes Config/Jobs props.despawnDelaySec after a delivery, at once after a fail (it may be in the road); the
-- one taken for the job, when the player hitched another, goes at once.
function Freight.finish(job: Job, outcome: Types.JobState)
	local data = job.data :: Data?
	local target = job.towTarget
	job.towTarget = nil
	if data == nil then
		return
	end
	if taken[data.spawnId] == job.id then
		taken[data.spawnId] = nil
	end
	local reserved = data.reserved
	data.reserved = nil
	if target ~= nil and target.Parent ~= nil then
		Freight.props.despawn(target, if outcome == "complete" then Jobs.props.despawnDelaySec else 0)
	end
	if reserved ~= nil and reserved ~= target and reserved.Parent ~= nil then
		Freight.props.despawn(reserved, 0)
	end
end

-- Checked against the interface (a type error here means Freight no longer fits Types.JobType / Types.Finish).
local _interface: Types.JobType = Freight
local _finish: Types.Finish = Freight.finish

return Freight
