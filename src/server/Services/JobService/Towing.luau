--!strict
-- Towing jobs (PLAN.md Phase 8; docs/phase-8-contracts.md "Jobs"). A job type module for JobService
-- (Types.JobType): a broken-down NPC car waits on the shoulder at a Breakdown spot; the player drives there in a
-- tow-capable truck, couples it (Net TrailerAction "couple", HitchService), tows it to the County Tow Yard and
-- uncouples it at a TowDrop spot there.
--
-- Who can tow: a car of a Config/Jobs towing class (pickup, service) that also has the "towHitch" feature
-- (Config/Vehicles; the service class has trucks without one). JobService refuses the rest with the reason.
--
-- The broken-down car: offers only name a spot and a car; accepting the offer spawns the car there (a catalog
-- model, Config/Jobs towing.breakdownClasses, with the attribute Towed = true and the Config/Trailers.towedTag
-- tag, so every client poses its wheels), anchored, facing along the road.
-- HitchService unanchors it when it is coupled. Each Breakdown spot holds one job's car at a time. When the job
-- ends the car goes: Config/Jobs props.despawnDelaySec after a delivery (so it doesn't vanish under the
-- player's eyes), at once after a fail or cancel (it may be left in the road). JobService uncouples it first.
--
-- Stops: "couple" at the breakdown (done when the server sees the coupling), then "decouple" at the drop (done
-- when the server sees it uncoupled there). JobService watches both and fails the job if the car comes off
-- anywhere else (Types.StopKind).
--
-- The drop: the TowDrop spot nearest the breakdown by road (all of them are in the County Tow Yard), or the tow
-- yard's own JobDepot (jobType "towing") on a map without TowDrop spots.
--
-- Pay (Types.PayBreakdown, whole dollars; the calibration is in Config/Jobs's header, $1,600/min):
--     base     = basePay (the coupling, the drop and the time between jobs)
--     distance = tow studs x payPerStud + approach studs x approachPayPerStud
--     level    = (base + distance) x (level multiplier - 1)
--   The approach is the road from where the car is when the job is accepted to the breakdown, paid up to
--   approachMaxStuds; the tow is the road from the breakdown to the drop. No tips and no class bonus. JobService
--   multiplies the total by the earnings boost and VIP when it pays.
--
-- The pure helpers (eligibility, pay, breakdown cars, spot picking, the car's pose) are exported for
-- tests/FreightJobs.spec; the JobType functions at the bottom glue them to JobService's Context. Towing.props
-- spawns and removes the car; a spec swaps it for a stand-in.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local Catalog = require(Shared.Vehicle.Catalog)
local Graph = require(Shared.Road.Graph)
local Jobs = require(Shared.Config.Jobs)
local MapLayout = require(Shared.Config.MapLayout)
local Spawning = require(Shared.Config.Spawning)
local Trailers = require(Shared.Config.Trailers)
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
	breakdownId: string, -- the Breakdown location
	dropId: string, -- the TowDrop (or tow yard JobDepot) location
	vehicleId: string, -- the broken-down car
	trimId: string,
	approach: number, -- studs of road from the car to the breakdown (the job keeps only the paid part)
	tow: number, -- studs of road from the breakdown to the drop
}

-- A car that can break down: a catalog vehicle and the trim whose model is spawned.
export type BreakdownCar = { vehicleId: string, trimId: string, displayName: string }

-- What puts the broken-down car in the world and takes it away. The default uses ServerStorage's car models.
export type Props = {
	spawn: (vehicleId: string, trimId: string, pose: CFrame, owner: Player) -> Model?,
	despawn: (model: Model, delaySeconds: number) -> (),
}

local BREAKDOWN_TAG = "Breakdown"
local DROP_TAG = "TowDrop"
local DEPOT_TAG = "JobDepot"
local DEPOT_ATTRIBUTE = "jobType"
local CHASSIS = "Chassis" -- the vehicle model contract's physics body
local VEHICLE_ID_ATTRIBUTE = "VehicleId"
local TRIM_ATTRIBUTE = "Trim"
local ROAD_STEP = 0.02 -- fraction of an edge either side of a point, to find the road's direction there
local MIN_DIRECTION = 1e-3 -- shorter than this across the ground has no usable direction

-- What the player reads. %s are filled in as noted.
local MESSAGES = {
	title = "Tow a %s", -- the car's name
	subtitle = "Broken down at %s", -- the spot's name
	coupled = "Hooked up. Tow it to %s.", -- the drop
	dropped = "Car dropped at %s.", -- the drop
}

local Towing = {}
-- The module itself is the JobType JobService plugs in (id, offers, start, onArrive, pay, finish).
Towing.id = "towing" :: Types.JobKind

-- Breakdown spots in use: location id -> the id of the job whose car stands there.
local taken: { [string]: string } = {}

-- Pure helpers ---------------------------------------------------------------------------------------------

-- Whether catalog vehicle `vehicleId` has the Config/Vehicles feature `feature`.
function Towing.hasFeature(vehicleId: string?, feature: string): boolean
	local vehicle = if vehicleId ~= nil then Catalog.getVehicle(vehicleId) else nil
	return vehicle ~= nil and table.find(vehicle.features, feature :: any) ~= nil
end

-- Whether a car of `classId` (catalog vehicle `vehicleId`) can tow: an eligible class and, when the def asks for
-- one, the feature (a tow hitch).
function Towing.isEligible(def: JobDef, classId: string?, vehicleId: string?): boolean
	if classId == nil or table.find(def.classes, classId) == nil then
		return false
	end
	local feature = def.requiresFeature
	return feature == nil or Towing.hasFeature(vehicleId, feature)
end

-- The studs of an approach leg that are paid: all of it, up to def.approachMaxStuds.
function Towing.paidApproach(def: JobDef, studs: number): number
	return math.clamp(studs, 0, def.approachMaxStuds or math.huge)
end

-- The pay for a tow of `towStuds` after an approach of `approachStuds` (see the header), in whole dollars,
-- components rounded down so they add up to the total exactly.
function Towing.payFor(def: JobDef, approachStuds: number, towStuds: number, levelMultiplier: number): PayBreakdown
	local rawBase = def.basePay
	local rawDistance = math.max(towStuds, 0) * def.payPerStud
		+ Towing.paidApproach(def, approachStuds) * (def.approachPayPerStud or 0)
	local rawLevel = (rawBase + rawDistance) * (math.max(levelMultiplier, 1) - 1)
	local base = math.floor(rawBase)
	local distance = math.floor(rawDistance)
	local level = math.floor(rawLevel)
	return { base = base, distance = distance, class = 0, tip = 0, level = level, total = base + distance + level }
end

-- Every catalog car that can break down (a def.breakdownClasses class), with its first trim, by vehicle id.
function Towing.breakdownCars(def: JobDef): { BreakdownCar }
	local classes = def.breakdownClasses or {}
	local cars: { BreakdownCar } = {}
	for _, vehicleId in Catalog.vehicleIds() do
		local vehicle = Catalog.getVehicle(vehicleId)
		local trim = Catalog.defaultTrim(vehicleId)
		if vehicle ~= nil and trim ~= nil and table.find(classes, vehicle.class) ~= nil then
			table.insert(cars, { vehicleId = vehicleId, trimId = trim.id, displayName = vehicle.displayName })
		end
	end
	table.sort(cars, function(a, b)
		return a.vehicleId < b.vehicleId
	end)
	return cars
end

local function flatDistance(a: Vector3, b: Vector3): number
	return Vector2.new(a.X - b.X, a.Z - b.Z).Magnitude
end

local function stopPoint(location: Location): Vector3
	return location.gpsTarget or location.position
end

-- Up to `count` of `spots` nearest `from` in a straight line, leaving out those in `busy` (location id -> any).
function Towing.nearestFree(spots: { Location }, from: Vector3, count: number, busy: { [string]: any }): { Location }
	local free: { Location } = {}
	for _, spot in spots do
		if busy[spot.id] == nil then
			table.insert(free, spot)
		end
	end
	table.sort(free, function(a, b)
		return flatDistance(stopPoint(a), from) < flatDistance(stopPoint(b), from)
	end)
	while #free > count do
		table.remove(free)
	end
	return free
end

-- `count` different items from `candidates` at random (all of them, shuffled, when there are fewer).
function Towing.pick<T>(candidates: { T }, count: number, random: Random): { T }
	local pool = table.clone(candidates)
	local picked: { T } = {}
	while #picked < count and #pool > 0 do
		table.insert(picked, table.remove(pool, random:NextInteger(1, #pool)) :: T)
	end
	return picked
end

-- Where the broken-down car stands on a Breakdown spot. A spot faces its road and runs along it (its X axis,
-- MapLayout's pad convention), with room for the car and a tow truck pulled in ahead of it. The car faces along
-- the road nearest it (`graph`) the way traffic on that side runs (shoulder on its right), set back from the
-- spot's centre by Config/Jobs props.breakdownSetBack of the spot's length, so the truck backs up to its nose.
-- Without a graph or a road it faces along the spot. The pose is the ground point under the chassis (the
-- vehicle model contract's pivot), so PivotTo(it) puts the car on its wheels.
function Towing.poseAt(location: Location, graph: Graph.Api?): CFrame
	local position = location.position
	local along = CFrame.Angles(0, math.rad(location.yaw), 0).RightVector
	if graph ~= nil then
		local edge, t, _, point = graph.nearestEdge(position)
		if edge ~= nil then
			local ahead = graph.pointOnEdge(edge, math.min(t + ROAD_STEP, 1))
			local behind = graph.pointOnEdge(edge, math.max(t - ROAD_STEP, 0))
			local direction = Vector3.new(ahead.X - behind.X, 0, ahead.Z - behind.Z)
			if direction.Magnitude >= MIN_DIRECTION then
				along = direction.Unit
				local side = Vector3.new(position.X - point.X, 0, position.Z - point.Z)
				if along:Cross(Vector3.yAxis):Dot(side) < 0 then
					along = -along -- the shoulder is on the left of that way: face the other way
				end
			end
		end
	end
	local at = position - along * (location.size.X * Jobs.props.breakdownSetBack)
	return CFrame.lookAt(at, at + along)
end

-- Whether the breakdown spot `id` is free (no job's car stands there).
function Towing.isFree(id: string): boolean
	return taken[id] == nil
end

-- Props -------------------------------------------------------------------------------------------------------

local function propsFolder(): Folder
	local name = Jobs.props.folder
	local existing = Workspace:FindFirstChild(name)
	if existing ~= nil and existing:IsA("Folder") then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = name
	folder.Parent = Workspace
	return folder
end

-- A copy of the car's model from ServerStorage (Config/Spawning.modelsFolder), parked at `pose` with its chassis
-- anchored (every other part is welded to it), marked Towed (Config/Trailers: HitchService tows it by its
-- TowPoint) and as `owner`'s job prop (only they can hitch it), its seats shut.
local function spawnCar(vehicleId: string, trimId: string, pose: CFrame, owner: Player): Model?
	local folder = ServerStorage:FindFirstChild(Spawning.modelsFolder)
	local template = if folder ~= nil then folder:FindFirstChild(Catalog.modelName(vehicleId, trimId)) else nil
	if template == nil or not template:IsA("Model") then
		return nil
	end
	local chassis = template.PrimaryPart
	if chassis == nil or chassis.Name ~= CHASSIS then
		return nil
	end
	local model = template:Clone()
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Anchored = false
		end
		if descendant:IsA("Seat") then
			descendant.Disabled = true -- nobody gets into a broken-down car
		end
	end
	local body = model.PrimaryPart :: BasePart
	body.Anchored = true
	local props = Jobs.props
	model:SetAttribute(Trailers.towedAttribute, true)
	model:SetAttribute(props.ownerAttribute, owner.UserId)
	model:SetAttribute(VEHICLE_ID_ATTRIBUTE, vehicleId)
	model:SetAttribute(TRIM_ATTRIBUTE, trimId)
	-- Not a player's car (no Config/Spawning.vehicleTag): TrailerController poses its wheels for everyone.
	model:AddTag(Trailers.towedTag)
	model:PivotTo(pose)
	model.Parent = propsFolder()
	return model
end

-- Removes a prop now, or after `delaySeconds` (one task.delay, no polling).
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
Towing.props = { spawn = spawnCar, despawn = despawn } :: Props

-- Glue to JobService --------------------------------------------------------------------------------------

-- Road studs between two locations, cached by id pair per router function (held weakly, so a spec's stand-in
-- router never shares answers with the county's). Locations never move.
type LegCache = { [string]: number | false }
local legCaches: { [any]: LegCache } = setmetatable({}, { __mode = "k" }) :: any

local function legBetween(context: Context, from: Location, to: Location): number?
	local cache = legCaches[context.routeLength]
	if cache == nil then
		cache = {}
		legCaches[context.routeLength] = cache
	end
	local key = from.id .. ">" .. to.id
	local cached = cache[key]
	if cached == nil then
		local length = context.routeLength(stopPoint(from), stopPoint(to))
		local entry: number | false = if length ~= nil then length else false
		cache[key] = entry
		cached = entry
	end
	return if type(cached) == "number" then cached else nil
end

-- The places a towed car can be dropped: the TowDrop spots, or the tow yard's JobDepot without any.
local function dropsIn(context: Context): { Location }
	local drops = context.locations(DROP_TAG)
	if #drops > 0 then
		return drops
	end
	local depots: { Location } = {}
	for _, depot in context.locations(DEPOT_TAG) do
		local attributes = depot.attributes
		if attributes ~= nil and attributes[DEPOT_ATTRIBUTE] == context.def.depotJobType then
			table.insert(depots, depot)
		end
	end
	return depots
end

-- The drop nearest `breakdown` by road, with the tow's length (nil: none reachable).
local function nearestDrop(context: Context, breakdown: Location): (Location?, number?)
	local best: Location?, bestLength: number? = nil, nil
	for _, drop in dropsIn(context) do
		local length = legBetween(context, breakdown, drop)
		if length ~= nil and (bestLength == nil or length < bestLength) then
			best, bestLength = drop, length
		end
	end
	return best, bestLength
end

local function findLocation(context: Context, tags: { string }, id: string): Location?
	for _, tag in tags do
		for _, location in context.locations(tag) do
			if location.id == id then
				return location
			end
		end
	end
	return nil
end

local function isEligibleNow(context: Context): boolean
	return Towing.isEligible(context.def, context.classId, context.vehicleId)
end

-- Offers for the player's truck: none unless it can tow; otherwise up to context.offerCount free breakdown spots
-- picked at random among the def.breakdownCandidates nearest the truck, each with a random broken-down car and
-- its drop, priced at the player's level.
function Towing.offers(_player: Player, car: Model?, context: Context): { Offer }
	local def = context.def
	local pose = context.carPose
	local offers: { Offer } = {}
	if car == nil or pose == nil or not isEligibleNow(context) then
		return offers
	end
	local cars = Towing.breakdownCars(def)
	if #cars == 0 then
		return offers
	end
	local candidates =
		Towing.nearestFree(context.locations(BREAKDOWN_TAG), pose.Position, def.breakdownCandidates or math.huge, taken)
	for _, breakdown in Towing.pick(candidates, context.offerCount, context.random) do
		local approach = context.routeLength(pose.Position, stopPoint(breakdown), pose.LookVector)
		local drop, tow = nearestDrop(context, breakdown)
		if approach == nil or drop == nil or tow == nil then
			continue
		end
		local broken = cars[context.random:NextInteger(1, #cars)]
		local data: Data = {
			breakdownId = breakdown.id,
			dropId = drop.id,
			vehicleId = broken.vehicleId,
			trimId = broken.trimId,
			approach = approach,
			tow = tow,
		}
		table.insert(offers, {
			id = context.newId(),
			type = Towing.id,
			title = string.format(MESSAGES.title, broken.displayName),
			subtitle = string.format(MESSAGES.subtitle, breakdown.displayName),
			pay = Towing.payFor(def, approach, tow, context.levelMultiplier).total,
			distance = approach + tow,
			stops = 2, -- the breakdown, then the drop
			data = data,
		})
	end
	return offers
end

-- The offer's car first, then every other car that can break down (a model missing from ServerStorage never
-- stops the job).
local function spawnBrokenCar(context: Context, data: Data, pose: CFrame, owner: Player): (Model?, string, string)
	local model = Towing.props.spawn(data.vehicleId, data.trimId, pose, owner)
	if model ~= nil then
		return model, data.vehicleId, data.trimId
	end
	for _, other in Towing.breakdownCars(context.def) do
		if other.vehicleId ~= data.vehicleId then
			local fallback = Towing.props.spawn(other.vehicleId, other.trimId, pose, owner)
			if fallback ~= nil then
				return fallback, other.vehicleId, other.trimId
			end
		end
	end
	return nil, data.vehicleId, data.trimId
end

-- Builds the job from an accepted offer: spawns the broken-down car at the breakdown (unless another job's car
-- stands there now), then the couple and decouple stops. The approach is measured again from where the truck is
-- now (it may have moved since the offer).
function Towing.start(player: Player, offer: Offer, context: Context): Job?
	local def = context.def
	local data = offer.data :: Data?
	local pose = context.carPose
	if type(data) ~= "table" or pose == nil or not isEligibleNow(context) then
		return nil
	end
	local breakdown = findLocation(context, { BREAKDOWN_TAG }, data.breakdownId)
	local drop = findLocation(context, { DROP_TAG, DEPOT_TAG }, data.dropId)
	if breakdown == nil or drop == nil or not Towing.isFree(breakdown.id) then
		return nil
	end
	local approach = context.routeLength(pose.Position, stopPoint(breakdown), pose.LookVector) or data.approach
	local target, vehicleId, trimId = spawnBrokenCar(context, data, Towing.poseAt(breakdown, context.graph), player)
	if target == nil then
		return nil
	end
	local paidApproach = Towing.paidApproach(def, approach)
	local stops: { Stop } = {
		context.makeStop(breakdown, "couple"),
		context.makeStop(drop, "decouple"),
	}
	local jobData: Data = {
		breakdownId = data.breakdownId,
		dropId = data.dropId,
		vehicleId = vehicleId,
		trimId = trimId,
		approach = paidApproach,
		tow = data.tow,
	}
	local ok, job = pcall(context.newJob, player, offer, stops, {
		routeLength = approach + data.tow,
		paidLength = paidApproach + data.tow,
	}, jobData)
	if not ok or type(job) ~= "table" then
		Towing.props.despawn(target, 0)
		return nil
	end
	local started = job :: Job
	started.towTarget = target
	taken[breakdown.id] = started.id
	target:SetAttribute(Jobs.props.jobAttribute, started.id)
	return started
end

-- Coupled at the breakdown: on to the drop. Uncoupled at the drop: done.
function Towing.onArrive(job: Job, stopIndex: number, _context: Context): StepResult
	local stop = job.stops[stopIndex]
	local nextStop = job.stops[stopIndex + 1]
	if stop ~= nil and stop.kind == "couple" and nextStop ~= nil then
		return { outcome = "advance", message = string.format(MESSAGES.coupled, nextStop.label) }
	end
	return { outcome = "complete", message = if stop then string.format(MESSAGES.dropped, stop.label) else nil }
end

-- The pay for a finished tow, at the player's level now.
function Towing.pay(job: Job, context: Context): PayBreakdown
	local data = job.data :: Data
	return Towing.payFor(context.def, data.approach, data.tow, context.levelMultiplier)
end

-- The job is over: free its breakdown spot and remove its car (after a while when it was delivered).
function Towing.finish(job: Job, outcome: Types.JobState)
	local data = job.data :: Data?
	if data ~= nil and taken[data.breakdownId] == job.id then
		taken[data.breakdownId] = nil
	end
	local target = job.towTarget
	job.towTarget = nil
	if target ~= nil and target.Parent ~= nil then
		Towing.props.despawn(target, if outcome == "complete" then Jobs.props.despawnDelaySec else 0)
	end
end

-- Checked against the interface (a type error here means Towing no longer fits Types.JobType / Types.Finish).
local _interface: Types.JobType = Towing
local _finish: Types.Finish = Towing.finish

return Towing
