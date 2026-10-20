--!strict
-- Rideshare fares (PLAN.md Phase 6; docs/phase-6-contracts.md "Rideshare"). A job type module for JobService:
-- it implements the Types.JobType interface and decides nothing about time limits, fails or arrival, which are
-- JobService's.
--
-- A fare: an NPC waits at a RideshareHotspot (MapLayout) near the car; the player drives there (the pickup leg),
-- stops, the passenger gets in, and the player drives them to the drop-off: another hotspot or a GPS destination
-- whose ride length by road is inside Config/Jobs routeBand (longRouteBand for one offer once "longFares" is
-- unlocked).
--
-- Pay (Config/Jobs has the calibration): fare = (basePay + paid studs x payPerStud) x xlMultiplier for XL fares,
-- where the paid studs are the ride plus the pickup leg measured from where the car is at the accept (up to
-- pickupMaxStuds: paidPickup). A fare picked up where the car already stands pays no pickup driving, and driving to
-- a pickup before accepting (drive-to-earn time) is never paid again by the job;
-- the tip is up to tipMax of the fare, less hardBrakePenalty for each hard brake and crashPenalty for each crash
-- JobService counted while the passenger was aboard; the level multiplier scales the fare (not the tip).
--
-- XL fares: a car of an xlClasses class (suv, minivan), or any eligible trim with xlMinSeats (6) or more seats.
--
-- The pay math and the XL rule are pure helpers (paidPickup, fare, tipShare, breakdown, isXL) for tests/Jobs.spec.

local Shared = game:GetService("ReplicatedStorage").Shared
local Jobs = require(Shared.Config.Jobs)
local MapLayout = require(Shared.Config.MapLayout)
local Types = require(script.Parent.Types)

local HOTSPOT_TAG = "RideshareHotspot"
local DROPOFF_TRIES = 8 -- drop-offs tried per offer before settling for fewer offers

type Def = Jobs.JobDef
type Offer = Types.Offer
type Context = Types.Context
type Job = Types.Job
type MapLocation = MapLayout.Location

-- What a rideshare offer keeps for start().
type FareData = {
	pickupId: string,
	dropoffId: string,
	pickupLength: number, -- studs of road from the car to the pickup when offered
	rideLength: number, -- studs of road from the pickup to the drop-off (paid)
}

local Rideshare = {}
local ID: Types.JobKind = "rideshare"
Rideshare.id = ID

-- Pure helpers -------------------------------------------------------------------------------------------------

local function contains(list: { string }?, value: string?): boolean
	if list == nil or value == nil then
		return false
	end
	return table.find(list, value) ~= nil
end

-- True when a car of `classId` with `seats` seats gets XL fares: an XL class, or an eligible class with at
-- least xlMinSeats seats.
function Rideshare.isXL(def: Def, classId: string?, seats: number): boolean
	if not contains(def.classes, classId) then
		return false
	end
	if contains(def.xlClasses, classId) then
		return true
	end
	local minSeats = def.xlMinSeats
	return minSeats ~= nil and seats >= minSeats
end

-- The studs of a pickup leg that are paid: all of it, up to def.pickupMaxStuds.
function Rideshare.paidPickup(def: Def, pickupStuds: number): number
	return math.clamp(pickupStuds, 0, def.pickupMaxStuds or math.huge)
end

-- The fare in parts: base, distance (`rideStuds`: every paid stud, pickup leg included) and the XL extra ($).
function Rideshare.fare(def: Def, rideStuds: number, xl: boolean): (number, number, number)
	local base = def.basePay
	local distance = math.max(rideStuds, 0) * def.payPerStud
	local multiplier = if xl then def.xlMultiplier or 1 else 1
	return base, distance, (base + distance) * (multiplier - 1)
end

-- The share of the maximum tip (0..1) a ride earns after its hard brakes and crashes.
function Rideshare.tipShare(hardBrakes: number, crashes: number): number
	local smoothness = Jobs.smoothness
	local lost = hardBrakes * smoothness.hardBrakePenalty + crashes * smoothness.crashPenalty
	return math.clamp(1 - lost, 0, 1)
end

-- The whole pay breakdown for a ride of `rideStuds` with `tipShare` (0..1) of the maximum tip.
function Rideshare.breakdown(
	def: Def,
	rideStuds: number,
	xl: boolean,
	levelMultiplier: number,
	tipShare: number
): Types.PayBreakdown
	local base, distance, class = Rideshare.fare(def, rideStuds, xl)
	local fare = base + distance + class
	local tip = fare * Jobs.tipMax * math.clamp(tipShare, 0, 1)
	local level = fare * (math.max(levelMultiplier, 1) - 1)
	return {
		base = base,
		distance = distance,
		class = class,
		tip = tip,
		level = level,
		total = base + distance + class + tip + level,
	}
end

-- Locations -----------------------------------------------------------------------------------------------------

local byId: { [string]: MapLocation }? = nil
local dropoffs: { MapLocation }? = nil
-- Ride lengths between two locations never change: pickupId .. ">" .. dropoffId -> studs (false: no route).
local rideLengths: { [string]: number | false } = {}

local function locationIndex(context: Context): { [string]: MapLocation }
	local index = byId
	if index == nil then
		local built: { [string]: MapLocation } = {}
		for _, location in context.mapLayout.locations do
			built[location.id] = location
		end
		byId = built
		return built
	end
	return index
end

-- Every place a passenger can ask to go: the hotspots and the GPS destinations, less the excluded tags.
local function dropoffList(context: Context): { MapLocation }
	local list = dropoffs
	if list == nil then
		local built: { MapLocation } = {}
		local excluded = context.def.dropoffExcludeTags or {}
		for _, location in context.mapLayout.locations do
			if (location.tag == HOTSPOT_TAG or location.gps == true) and not table.find(excluded, location.tag) then
				table.insert(built, location)
			end
		end
		dropoffs = built
		return built
	end
	return list
end

local function stopPoint(location: MapLocation): Vector3
	return location.gpsTarget or location.position
end

local function flatDistance(a: Vector3, b: Vector3): number
	return Vector2.new(a.X - b.X, a.Z - b.Z).Magnitude
end

local function rideLength(context: Context, pickup: MapLocation, dropoff: MapLocation): number?
	local key = pickup.id .. ">" .. dropoff.id
	local cached = rideLengths[key]
	if cached == nil then
		local length = context.routeLength(stopPoint(pickup), stopPoint(dropoff), nil)
		local entry: number | false = if length ~= nil then length else false
		rideLengths[key] = entry
		cached = entry
	end
	return if type(cached) == "number" then cached else nil
end

-- Hotspots to pick passengers up at: the def.pickupCandidates nearest the car (straight line), with their
-- road distance from it; those farther than pickupMaxStuds by road are left out unless none is closer.
local function pickupCandidates(
	context: Context,
	from: Vector3,
	heading: Vector3?
): { { location: MapLocation, length: number } }
	local def = context.def
	local hotspots = context.locations(HOTSPOT_TAG)
	local sorted = table.clone(hotspots)
	table.sort(sorted, function(a, b)
		return flatDistance(stopPoint(a), from) < flatDistance(stopPoint(b), from)
	end)
	local wanted = def.pickupCandidates or #sorted
	local maxStuds = def.pickupMaxStuds or math.huge
	local near: { { location: MapLocation, length: number } } = {}
	local far: { { location: MapLocation, length: number } } = {}
	for i = 1, math.min(wanted, #sorted) do
		local location = sorted[i]
		local length = context.routeLength(from, stopPoint(location), heading)
		if length ~= nil then
			table.insert(if length <= maxStuds then near else far, { location = location, length = length })
		end
	end
	if #near > 0 then
		return near
	end
	table.sort(far, function(a, b)
		return a.length < b.length
	end)
	return if #far > 0 then { far[1] } else {}
end

-- Interface ------------------------------------------------------------------------------------------------------

function Rideshare.offers(_player: Player, car: Model?, context: Context): { Offer }
	local pose = context.carPose
	if car == nil or pose == nil then
		return {}
	end
	local def = context.def
	local pickups = pickupCandidates(context, pose.Position, pose.LookVector)
	if #pickups == 0 then
		return {}
	end
	local xl = Rideshare.isXL(def, context.classId, context.seats)
	local candidates = dropoffList(context)
	local offers: { Offer } = {}
	local used: { [string]: boolean } = {}
	for i = 1, context.offerCount do
		local band = def.routeBand or { min = 0, max = math.huge }
		-- The last offer is a long fare once the player has unlocked them.
		if context.unlocks.longFares and i == context.offerCount and def.longRouteBand ~= nil then
			band = def.longRouteBand
		end
		local pickup = pickups[context.random:NextInteger(1, #pickups)]
		for _ = 1, DROPOFF_TRIES do
			local dropoff = candidates[context.random:NextInteger(1, #candidates)]
			local key = pickup.location.id .. ">" .. dropoff.id
			if dropoff.id ~= pickup.location.id and not used[key] then
				local length = rideLength(context, pickup.location, dropoff)
				if length ~= nil and length >= band.min and length <= band.max then
					used[key] = true
					local paid = Rideshare.paidPickup(def, pickup.length) + length
					local estimate = Rideshare.breakdown(def, paid, xl, context.levelMultiplier, 0)
					local data: FareData = {
						pickupId = pickup.location.id,
						dropoffId = dropoff.id,
						pickupLength = pickup.length,
						rideLength = length,
					}
					local titleFormat = if xl then "XL fare to %s" else "Fare to %s"
					table.insert(offers, {
						id = context.newId(),
						type = ID,
						title = string.format(titleFormat, dropoff.displayName),
						subtitle = string.format("Pick up at %s", pickup.location.displayName),
						pay = estimate.total,
						distance = pickup.length + length,
						stops = 2,
						xl = xl,
						data = data,
					})
					break
				end
			end
		end
	end
	return offers
end

function Rideshare.start(player: Player, offer: Offer, context: Context): Job?
	local data = offer.data :: FareData?
	local pose = context.carPose
	if type(data) ~= "table" or pose == nil then
		return nil
	end
	local index = locationIndex(context)
	local pickup, dropoff = index[data.pickupId], index[data.dropoffId]
	if pickup == nil or dropoff == nil then
		return nil
	end
	local def = context.def
	-- The car may have moved since the offer was made: time and pay the pickup leg from where it is now.
	local pickupLength = context.routeLength(pose.Position, stopPoint(pickup), pose.LookVector) or data.pickupLength
	local stops = {
		context.makeStop(pickup, "pickup", def.pickupDwell),
		context.makeStop(dropoff, "dropoff", def.dropoffDwell),
	}
	-- XL only if the car accepting it still qualifies (the offer was made for the same car).
	local xl = offer.xl == true and Rideshare.isXL(def, context.classId, context.seats)
	local job = context.newJob(player, offer, stops, {
		routeLength = pickupLength + data.rideLength,
		paidLength = Rideshare.paidPickup(def, pickupLength) + data.rideLength,
	}, data)
	job.xl = xl
	return job
end

function Rideshare.onArrive(job: Job, stopIndex: number, _context: Context): Types.StepResult
	local stop = job.stops[stopIndex]
	if stop ~= nil and stop.kind == "pickup" then
		return { outcome = "advance", message = Jobs.messages.pickedUp, smoothTracking = true }
	end
	return { outcome = "complete", message = Jobs.messages.droppedOff, smoothTracking = false }
end

function Rideshare.pay(job: Job, context: Context): Types.PayBreakdown
	local share = Rideshare.tipShare(job.smooth.hardBrakes, job.smooth.crashes)
	return Rideshare.breakdown(context.def, job.paidLength, job.xl == true, context.levelMultiplier, share)
end

-- Checked against the interface (a type error here means Rideshare no longer fits Types.JobType).
local _interface: Types.JobType = Rideshare

return Rideshare
