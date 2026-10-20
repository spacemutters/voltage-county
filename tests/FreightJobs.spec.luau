--!strict
-- Towing and freight jobs (docs/phase-8-contracts.md "Jobs" and "Tests"): pay math and how it lands on the
-- PLAN.md §4 rates ($1,600/min towing, $3,000/min freight) for the Config/Jobs calibration cycle, eligibility
-- (class and feature), the freight license gate and its reasons, the long haul's waypoints round the County
-- Loop, the coupling decisions JobService makes at couple / decouple stops, and the stop sequences the modules
-- build. The offer and job tests drive the real JobType functions with a stand-in Context (straight-line
-- distances over fixture locations) and stand-in props (no models are spawned), so no routing, services or
-- world are touched. Pure logic: runs in Edit mode.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Catalog = require(ReplicatedStorage.Shared.Vehicle.Catalog)
local Economy = require(ReplicatedStorage.Shared.Config.Economy)
local Harness = require(ReplicatedStorage.Shared.Testing.Harness)
local Jobs = require(ReplicatedStorage.Shared.Config.Jobs)
local MapLayout = require(ReplicatedStorage.Shared.Config.MapLayout)
local Units = require(ReplicatedStorage.Shared.Util.Units)
local JobServiceFolder = ServerScriptService.Server.Services.JobService
local Freight = require(JobServiceFolder.Freight)
local JobService = require(JobServiceFolder)
local Levels = require(JobServiceFolder.Levels)
local Towing = require(JobServiceFolder.Towing)
local Types = require(JobServiceFolder.Types)

type Context = Types.Context
type Location = MapLayout.Location
type Job = Types.Job

local TOWING = Jobs.types.towing
local FREIGHT = Jobs.types.freight
local CALIBRATION = Jobs.calibration
local SECONDS_PER_MINUTE = 60

local SEED = 20261020
local OFFERS = 3
local ROUNDING_DOLLARS = 3 -- payFor rounds base, distance and level down separately
local RATE_TOLERANCE = 2 -- $/min: the rounding over a cycle of a minute or more
local SAME = 1e-6
local ANGLE_SLACK = 25 -- degrees: loop nodes are up to ~20 degrees apart on the ring's straight sides

-- Test cars (Config/Vehicles): a pickup with a tow hitch, the semi, the pod (service class, no hitch).
local PICKUP = "ohm_mesa"
local SEMI = "ohm_hauler"
local POD = "ohm_pod"

-- A fake player: the modules only pass it on (and read UserId for a prop's owner).
local PLAYER = ({ UserId = 1, Name = "Tester" } :: any) :: Player

-- Fixture locations, placed like the county's (the map's own spots may still move).
local function location(id: string, tag: string, position: Vector3, attributes: { [string]: any }?): Location
	return {
		id = id,
		displayName = id,
		tag = tag,
		zone = "the_plant",
		position = position,
		yaw = 90,
		size = Vector3.new(32, 1, 24),
		attributes = attributes,
	}
end

local FREIGHT_ATTRIBUTES = { jobType = "freight" }
local PLANT_DEPOT = location("fx_plant_depot", "JobDepot", Vector3.new(2258, 0, 350), FREIGHT_ATTRIBUTES)
local LOOP_DEPOT = location("fx_loop_depot", "JobDepot", Vector3.new(3235, 0, 1780), FREIGHT_ATTRIBUTES)
local WEST_DEPOT = location("fx_west_depot", "JobDepot", Vector3.new(-3323, 0, -180), FREIGHT_ATTRIBUTES)
local TOW_YARD = location("fx_tow_yard", "JobDepot", Vector3.new(2858, 0, -400), { jobType = "towing" })

local FIXTURES: { [string]: { Location } } = {
	JobDepot = { PLANT_DEPOT, LOOP_DEPOT, WEST_DEPOT, TOW_YARD },
	TrailerSpawn = {
		location("fx_plant_trailer_1", "TrailerSpawn", Vector3.new(2248, 0, 425), {
			depot = "fx_plant_depot",
			trailer = "box_trailer",
		}),
		location("fx_plant_trailer_2", "TrailerSpawn", Vector3.new(2248, 0, 491), {
			depot = "fx_plant_depot",
			trailer = "tanker_trailer",
		}),
		location("fx_loop_trailer_1", "TrailerSpawn", Vector3.new(3226, 0, 1854), {
			depot = "fx_loop_depot",
			trailer = "flatbed_trailer",
		}),
		-- No depot attribute: it belongs to the nearest depot (the west one).
		location("fx_west_trailer_1", "TrailerSpawn", Vector3.new(-3167, 0, -45)),
	},
	TowDrop = { location("fx_tow_drop", "TowDrop", Vector3.new(2855, 0, -452), { yard = "fx_tow_yard" }) },
	Breakdown = {
		location("fx_breakdown_plant", "Breakdown", Vector3.new(1960, 0, -751)),
		location("fx_breakdown_town", "Breakdown", Vector3.new(-936, 0, -150)),
		location("fx_breakdown_lake", "Breakdown", Vector3.new(450, 0, 2886)),
		location("fx_breakdown_mesa", "Breakdown", Vector3.new(51, 0, -1950)),
	},
}

local function horizontal(a: Vector3, b: Vector3): number
	return Vector3.new(b.X - a.X, 0, b.Z - a.Z).Magnitude
end

-- A stand-in Context: straight-line "road" lengths, the fixtures, a fixed seed, and a newJob that just records
-- what the module gave it. `overrides` replaces any field.
local function fakeContext(
	def: Jobs.JobDef,
	classId: string?,
	vehicleId: string?,
	overrides: { [string]: any }?
): Context
	local nextId = 0
	local context = {
		now = 0,
		def = def,
		graph = nil,
		pathfind = nil,
		mapLayout = MapLayout,
		car = nil,
		-- At the Plant's gate, facing north.
		carPose = CFrame.new(2100, 0, 300),
		vehicleId = vehicleId,
		classId = classId,
		seats = 2,
		level = 1,
		levelMultiplier = 1,
		unlocks = {},
		offerCount = OFFERS,
		licenses = { freight = true },
		random = Random.new(SEED),
		newId = function(): string
			nextId += 1
			return `offer{nextId}`
		end,
		routeLength = function(from: Vector3, to: Vector3, _heading: Vector3?): number?
			return horizontal(from, to)
		end,
		locations = function(tag: string): { Location }
			return FIXTURES[tag] or {}
		end,
		makeStop = function(where: Location, kind: Types.StopKind, dwell: number?): Types.Stop
			return {
				position = where.gpsTarget or where.position,
				locationId = where.id,
				kind = kind,
				label = where.displayName,
				dwell = dwell,
			}
		end,
		newJob = function(player: Player, offer: Types.Offer, stops: { Types.Stop }, lengths, data): Job
			nextId += 1
			return {
				id = `job{nextId}`,
				type = offer.type,
				player = player,
				title = offer.title,
				stops = stops,
				index = 1,
				startedAt = 0,
				deadline = 0,
				routeLength = lengths.routeLength,
				paidLength = lengths.paidLength,
				car = nil,
				carUid = nil,
				estPay = offer.pay,
				state = "accepted",
				smooth = { tracking = false, hardBrakes = 0, crashes = 0, lastEventAt = 0 },
				data = data,
			} :: Job
		end,
	}
	local changes: { [string]: any } = overrides or {}
	for key, value in changes do
		(context :: any)[key] = value
	end
	return context :: any
end

local CAR = Instance.new("Model") -- the player's truck (the modules only check it is there)
-- Where stand-in props live (a prop with no parent counts as gone). Never parented to the world.
local STAGE = Instance.new("Folder")

local function stagedModel(): Model
	local model = Instance.new("Model")
	model.Parent = STAGE
	return model
end

-- Stand-in props for the length of `body`: towing's spawn and freight's take hand out plain models and remember
-- them (every trailer spot has an idle trailer unless `recorder.idle` is false); despawn records the delays.
type Recorder = { spawned: { Model }, despawned: { { model: Model, delay: number } }, idle: boolean }

local function withProps(body: (recorder: Recorder) -> ())
	local recorder: Recorder = { spawned = {}, despawned = {}, idle = true }
	local towingProps, freightProps = Towing.props, Freight.props
	local function spawned(): Model
		local model = stagedModel()
		table.insert(recorder.spawned, model)
		return model
	end
	local function despawn(model: Model, delay: number)
		table.insert(recorder.despawned, { model = model, delay = delay })
	end
	Towing.props = {
		spawn = function(_vehicleId: string, _trimId: string, _pose: CFrame, _owner: Player): Model?
			return spawned()
		end,
		despawn = despawn,
	}
	Freight.props = {
		idle = function(_spot: Location): boolean
			return recorder.idle
		end,
		take = function(_spot: Location, _owner: Player): Model?
			return if recorder.idle then spawned() else nil
		end,
		despawn = despawn,
	}
	local ok, err = pcall(body, recorder)
	Towing.props, Freight.props = towingProps, freightProps
	if not ok then
		error(err, 0)
	end
end

local function kinds(job: Job): { string }
	local list: { string } = {}
	for _, stop in job.stops do
		table.insert(list, stop.kind)
	end
	return list
end

local function towingOffers(overrides: { [string]: any }?): { Types.Offer }
	return Towing.offers(PLAYER, CAR, fakeContext(TOWING, "pickup", PICKUP, overrides))
end

-- Freight offers with every trailer spot stocked (stand-in props).
local function freightOffers(overrides: { [string]: any }?): { Types.Offer }
	local offers: { Types.Offer } = {}
	withProps(function()
		offers = Freight.offers(PLAYER, CAR, fakeContext(FREIGHT, "heavy", SEMI, overrides))
	end)
	return offers
end

-- Degrees round the loop's middle from `a` to `b` the short way.
local function degreesBetween(a: Vector3, b: Vector3, centre: Vector3): number
	local angleA = math.atan2(a.Z - centre.Z, a.X - centre.X)
	local angleB = math.atan2(b.Z - centre.Z, b.X - centre.X)
	local difference = (angleA - angleB) % (2 * math.pi)
	return math.deg(math.min(difference, 2 * math.pi - difference))
end

local function loopCentre(): Vector3
	local sum = Vector3.zero
	local nodes = Freight.loopNodes()
	for _, node in nodes do
		sum += Vector3.new(node.position.X, 0, node.position.Z)
	end
	return sum / #nodes
end

return function(t: Harness.Api)
	t.describe("FreightJobs", function()
		t.describe("config", function()
			t.it("lists towing and freight after the Phase 6 jobs, each with a sound ladder", function()
				t.expect(Jobs.order).toEqual({ "rideshare", "delivery", "towing", "freight" })
				for _, id in { "towing", "freight" } do
					t.expect(Jobs.types[id].id).toBe(id)
					t.expect(Levels.validate(Jobs.levels[id])).toEqual({})
					t.expect(Jobs.types[id].levels).toBe(Jobs.levels[id])
				end
			end)

			t.it("puts the freight license at level 3 of delivery and towing, for the §4 price", function()
				local license = Jobs.freightLicense
				t.expect(Jobs.licenses.freight).toBe(license)
				t.expect(FREIGHT.license).toBe(license.id)
				t.expect(license.price).toBe(Economy.freightLicensePrice)
				t.expect(license.jobTypes).toEqual({ "delivery", "towing" })
				for _, kind in license.jobTypes do
					t.expect(Jobs.levels[kind][license.level].xp).toBe(license.xpRequired)
				end
				t.expect(license.xpRequired).toBeGreaterThan(0)
			end)

			t.it("names the classes and features the contract gives", function()
				t.expect(TOWING.classes).toEqual({ "pickup", "service" })
				t.expect(TOWING.requiresFeature).toBe("towHitch")
				t.expect(FREIGHT.classes).toEqual({ "heavy" })
				t.expect(FREIGHT.requiresFeature).toBe("kingpin")
				t.expect(Jobs.featureNames.towHitch ~= nil and Jobs.featureNames.kingpin ~= nil).toBe(true)
			end)
		end)

		t.describe("pay", function()
			t.it("adds up: base, both legs by the stud, the level on top", function()
				local pay = Towing.payFor(TOWING, 2000, 3000, 1)
				t.expect(pay.base).toBe(math.floor(TOWING.basePay))
				local distance = 3000 * TOWING.payPerStud + 2000 * (TOWING.approachPayPerStud :: number)
				t.expect(pay.distance).toBeNear(distance, 1)
				t.expect(pay.class + pay.tip + pay.level).toBe(0)
				t.expect(pay.total).toBe(pay.base + pay.distance)
				local levelled = Towing.payFor(TOWING, 2000, 3000, 1.25)
				t.expect(levelled.level).toBeNear((pay.base + pay.distance) * 0.25, ROUNDING_DOLLARS)
				t.expect(levelled.total).toBe(levelled.base + levelled.distance + levelled.level)
			end)

			t.it("pays the approach only up to approachMaxStuds, and nothing for negative lengths", function()
				for _, def in { TOWING, FREIGHT } do
					local cap = def.approachMaxStuds :: number
					local capped = if def == TOWING
						then Towing.payFor(def, cap * 10, 0, 1)
						else Freight.payFor(def, cap * 10, 0, false, 1)
					t.expect(capped.distance).toBe(math.floor(cap * (def.approachPayPerStud :: number)))
					local none = if def == TOWING
						then Towing.payFor(def, -5, -5, 1)
						else Freight.payFor(def, -5, -5, false, 1)
					t.expect(none.total).toBe(math.floor(def.basePay))
				end
			end)

			t.it("pays a long haul by longHaulPayPerStud and a short run by payPerStud", function()
				local short = Freight.payFor(FREIGHT, 0, 10000, false, 1)
				local long = Freight.payFor(FREIGHT, 0, 10000, true, 1)
				t.expect(short.distance).toBe(math.floor(10000 * FREIGHT.payPerStud))
				t.expect(long.distance).toBe(math.floor(10000 * (FREIGHT.longHaulPayPerStud :: number)))
			end)

			t.it("lands towing on $1,600/min for the calibration cycle, whatever the legs' lengths", function()
				t.expect(Economy.activities.towing).toBe(1600)
				local fixed = CALIBRATION.coupleSecondsTow + CALIBRATION.decoupleSecondsTow + CALIBRATION.betweenSeconds
				local approachPace = Units.mphToStuds(CALIBRATION.referenceMph)
				local towPace = Units.mphToStuds(CALIBRATION.towMph)
				local cases = {
					{ CALIBRATION.towApproachStuds, CALIBRATION.towStuds },
					{ 500, 1500 },
					{ 6000, 6000 },
				}
				for _, case in cases do
					local approach, tow = case[1], case[2]
					local seconds = fixed + approach / approachPace + tow / towPace
					local rate = Towing.payFor(TOWING, approach, tow, 1).total / seconds * SECONDS_PER_MINUTE
					t.expect(rate).toBeNear(Economy.activities.towing, RATE_TOLERANCE)
				end
			end)

			t.it("lands freight on $3,000/min for short runs and long hauls", function()
				t.expect(Economy.activities.freight).toBe(3000)
				local fixed = CALIBRATION.coupleSecondsFreight
					+ CALIBRATION.decoupleSecondsFreight
					+ CALIBRATION.betweenSeconds
				local pace = Units.mphToStuds(CALIBRATION.freightMph)
				local longPace = Units.mphToStuds(CALIBRATION.longHaulMph)
				for _, case in { { 0, CALIBRATION.freightRunStuds }, { 1500, 6000 } } do
					local approach, haul = case[1], case[2]
					local seconds = fixed + (approach + haul) / pace
					local rate = Freight.payFor(FREIGHT, approach, haul, false, 1).total / seconds * SECONDS_PER_MINUTE
					t.expect(rate).toBeNear(Economy.activities.freight, RATE_TOLERANCE)
				end
				local seconds = fixed + 1000 / pace + 20000 / longPace
				local long = Freight.payFor(FREIGHT, 1000, 20000, true, 1)
				t.expect(long.total / seconds * SECONDS_PER_MINUTE).toBeNear(Economy.activities.freight, RATE_TOLERANCE)
				-- The long haul is the biggest single payout.
				t.expect(long.total).toBeGreaterThan(Freight.payFor(FREIGHT, 1000, 6000, false, 1).total)
			end)

			t.it("pays freight more per minute than towing, and towing more than delivery", function()
				t.expect(Economy.activities.freight).toBeGreaterThan(Economy.activities.towing)
				t.expect(Economy.activities.towing).toBeGreaterThan(Economy.activities.delivery)
			end)

			t.it("gives the reference XP for the reference length", function()
				t.expect(JobService.xpFor(TOWING, TOWING.xpReferenceStuds)).toBe(TOWING.xp)
				t.expect(JobService.xpFor(FREIGHT, FREIGHT.xpReferenceStuds)).toBe(FREIGHT.xp)
				-- A long haul earns the most XP xpScale allows.
				t.expect(JobService.xpFor(FREIGHT, 20000)).toBe(math.floor(FREIGHT.xp * Jobs.xpScale.max + 0.5))
			end)
		end)

		t.describe("eligibility", function()
			t.it("lets only pickup and service trucks with a tow hitch tow", function()
				local any = false
				for _, vehicleId in Catalog.vehicleIds() do
					local vehicle = Catalog.getVehicle(vehicleId)
					assert(vehicle, vehicleId)
					local classOk = vehicle.class == "pickup" or vehicle.class == "service"
					local hitch = table.find(vehicle.features, "towHitch") ~= nil
					t.expect(Towing.isEligible(TOWING, vehicle.class, vehicleId)).toBe(classOk and hitch)
					any = any or (classOk and hitch)
				end
				t.expect(any).toBe(true)
				t.expect(Towing.isEligible(TOWING, "pickup", PICKUP)).toBe(true)
				t.expect(Towing.isEligible(TOWING, "service", POD)).toBe(false)
				t.expect(Towing.isEligible(TOWING, "heavy", SEMI)).toBe(false)
				t.expect(Towing.isEligible(TOWING, nil, nil)).toBe(false)
			end)

			t.it("lets only the semi haul freight", function()
				t.expect(Freight.isEligible(FREIGHT, "heavy", SEMI)).toBe(true)
				t.expect(Freight.isEligible(FREIGHT, "pickup", PICKUP)).toBe(false)
				t.expect(Freight.isEligible(FREIGHT, "heavy", PICKUP)).toBe(false) -- no kingpin
			end)

			t.it("makes no towing offers in a car that can't tow", function()
				t.expect(#Towing.offers(PLAYER, CAR, fakeContext(TOWING, "service", POD))).toBe(0)
				t.expect(#Towing.offers(PLAYER, CAR, fakeContext(TOWING, "sedan", "ohm_spark"))).toBe(0)
				t.expect(#Towing.offers(PLAYER, nil, fakeContext(TOWING, "pickup", PICKUP))).toBe(0)
			end)
		end)

		t.describe("license gate", function()
			local license = Jobs.freightLicense
			local price = Economy.formatCash(license.price)

			t.it("lets jobs without a license through", function()
				local ok, reason = JobService.licenseStatus(TOWING, nil, {})
				t.expect(ok).toBe(true)
				t.expect(reason).toBe(nil)
			end)

			t.it("waits for the player's data", function()
				local ok, reason = JobService.licenseStatus(FREIGHT, nil, {})
				t.expect(ok).toBe(false)
				t.expect(reason).toBe(Jobs.messages.loading)
			end)

			t.it("tells a player without the XP the level, the jobs and the price", function()
				local ok, reason = JobService.licenseStatus(FREIGHT, {}, { delivery = license.xpRequired - 1 })
				t.expect(ok).toBe(false)
				local expected = string.format(
					Jobs.messages.needLicenseXp,
					FREIGHT.displayName,
					license.level,
					"Delivery or Towing",
					price
				)
				t.expect(reason).toBe(expected)
				t.expect(string.find(reason :: string, "$25,000", 1, true) ~= nil).toBe(true)
			end)

			t.it("tells a player with the XP in either job to buy it", function()
				for _, kind in license.jobTypes do
					local ok, reason = JobService.licenseStatus(FREIGHT, {}, { [kind] = license.xpRequired })
					t.expect(ok).toBe(false)
					t.expect(reason).toBe(string.format(Jobs.messages.needLicense, FREIGHT.displayName, price))
				end
			end)

			t.it("opens freight once the license is held", function()
				local ok, reason = JobService.licenseStatus(FREIGHT, { freight = true }, {})
				t.expect(ok).toBe(true)
				t.expect(reason).toBe(nil)
			end)

			t.it("counts the XP gate from exactly xpRequired, in delivery or towing only", function()
				t.expect(JobService.meetsLicenseXp(license, { towing = license.xpRequired })).toBe(true)
				t.expect(JobService.meetsLicenseXp(license, { delivery = license.xpRequired - 1 })).toBe(false)
				t.expect(JobService.meetsLicenseXp(license, { rideshare = license.xpRequired * 10 })).toBe(false)
				t.expect(JobService.meetsLicenseXp(license, {})).toBe(false)
			end)

			t.it("makes no freight offers without the license, and offers with it", function()
				t.expect(#freightOffers({ licenses = {} })).toBe(0)
				withProps(function()
					local loading = fakeContext(FREIGHT, "heavy", SEMI);
					(loading :: any).licenses = nil -- the player's data hasn't loaded
					t.expect(#Freight.offers(PLAYER, CAR, loading)).toBe(0)
				end)
				t.expect(Freight.hasLicense(FREIGHT, { freight = true })).toBe(true)
				t.expect(#freightOffers()).toBe(OFFERS)
			end)
		end)

		t.describe("offers", function()
			t.it("offers tows from free breakdown spots to the tow drop, priced on both legs", function()
				local offers = towingOffers()
				t.expect(#offers).toBe(OFFERS)
				local seen: { [string]: boolean } = {}
				for _, offer in offers do
					local data = offer.data :: Towing.Data
					t.expect(seen[data.breakdownId]).toBe(nil)
					seen[data.breakdownId] = true
					t.expect(data.dropId).toBe("fx_tow_drop")
					t.expect(offer.type).toBe("towing")
					t.expect(offer.stops).toBe(2)
					t.expect(offer.distance).toBeNear(data.approach + data.tow, SAME)
					t.expect(offer.pay).toBe(Towing.payFor(TOWING, data.approach, data.tow, 1).total)
					local vehicle = Catalog.getVehicle(data.vehicleId)
					assert(vehicle, data.vehicleId)
					t.expect(table.find(TOWING.breakdownClasses :: { string }, vehicle.class) ~= nil).toBe(true)
				end
			end)

			t.it("drops at the tow yard's depot on a map without TowDrop spots", function()
				local function noDrops(tag: string): { Location }
					return if tag == "TowDrop" then {} else FIXTURES[tag] or {}
				end
				for _, offer in towingOffers({ locations = noDrops }) do
					t.expect((offer.data :: Towing.Data).dropId).toBe(TOW_YARD.id)
				end
			end)

			t.it("offers short runs from the nearest depot, then a long haul round the loop", function()
				local offers = freightOffers()
				t.expect(#offers).toBe(OFFERS)
				for index, offer in offers do
					local data = offer.data :: Freight.Data
					t.expect(data.originId).toBe(PLANT_DEPOT.id) -- the truck is at the Plant
					t.expect(data.destinationId ~= data.originId).toBe(true)
					t.expect(data.longHaul).toBe(index == #offers)
					t.expect(offer.stops).toBe(#data.waypointIds + 2)
					t.expect(offer.pay).toBe(Freight.payFor(FREIGHT, data.approach, data.haul, data.longHaul, 1).total)
				end
				local long = offers[#offers].data :: Freight.Data
				t.expect(#long.waypointIds).toBeGreaterThan(0)
				-- The long haul pays the most of the three.
				for index = 1, #offers - 1 do
					t.expect(offers[#offers].pay).toBeGreaterThan(offers[index].pay)
				end
			end)

			t.it("only offers spots with an idle trailer waiting", function()
				withProps(function(recorder)
					recorder.idle = false
					t.expect(#Freight.offers(PLAYER, CAR, fakeContext(FREIGHT, "heavy", SEMI))).toBe(0)
				end)
			end)

			t.it("finds each trailer spot's depot by attribute or, without one, by distance", function()
				local depots = Freight.depotsIn(FIXTURES.JobDepot, FREIGHT)
				t.expect(#depots).toBe(3) -- not the tow yard
				local byDepot = Freight.spotsByDepot(FIXTURES.TrailerSpawn, depots)
				t.expect(#byDepot[PLANT_DEPOT.id]).toBe(2)
				t.expect(#byDepot[LOOP_DEPOT.id]).toBe(1)
				t.expect(byDepot[WEST_DEPOT.id][1].id).toBe("fx_west_trailer_1")
			end)
		end)

		t.describe("long hauls", function()
			local loop = Freight.loopNodes()
			local centre = loopCentre()
			local maxDegrees = FREIGHT.loopWaypointDegrees :: number

			-- Waypoints never sit on the short arc between the ends, and no gap is much over maxDegrees.
			local function checkRoute(from: Vector3, to: Vector3)
				local waypoints = Freight.loopWaypoints(from, to, loop, maxDegrees)
				t.expect(#waypoints).toBeGreaterThan(0)
				local short = degreesBetween(from, to, centre)
				local points: { Vector3 } = { from }
				for _, node in waypoints do
					local detour = degreesBetween(from, node.position, centre)
						+ degreesBetween(node.position, to, centre)
					t.expect(detour).toBeGreaterThan(short + 1)
					table.insert(points, node.position)
				end
				table.insert(points, to)
				local total = 0
				for index = 2, #points do
					local gap = degreesBetween(points[index - 1], points[index], centre)
					t.expect(gap).toBeLessThan(maxDegrees + ANGLE_SLACK)
					total += gap
				end
				-- Round the long way: at least half the ring.
				t.expect(total).toBeGreaterThan(180 - ANGLE_SLACK)
				return waypoints
			end

			t.it("reads the whole ring from Config/RoadGraph", function()
				t.expect(#loop).toBeGreaterThan(40)
			end)

			t.it("goes the long way between two depots on the same side", function()
				local waypoints = checkRoute(PLANT_DEPOT.position, LOOP_DEPOT.position)
				t.expect(#waypoints).toBe(3) -- ~340 degrees in gaps of at most 90
				-- The middle one is across the county, on the west side.
				t.expect(waypoints[2].position.X).toBeLessThan(0)
			end)

			t.it("goes round between depots across the county from each other", function()
				checkRoute(PLANT_DEPOT.position, WEST_DEPOT.position)
				checkRoute(WEST_DEPOT.position, LOOP_DEPOT.position)
			end)

			t.it("goes the whole ring back to the same depot", function()
				local waypoints = Freight.loopWaypoints(PLANT_DEPOT.position, PLANT_DEPOT.position, loop, maxDegrees)
				t.expect(#waypoints).toBe(3)
				local sides: { [string]: boolean } = {}
				for _, node in waypoints do
					sides[Freight.sideOf(node.position, centre)] = true
				end
				t.expect(sides.east).toBe(nil) -- the Plant is east: the waypoints are the other three sides
			end)

			t.it("has nothing to pass on a map without a loop", function()
				t.expect(#Freight.loopWaypoints(PLANT_DEPOT.position, LOOP_DEPOT.position, {}, maxDegrees)).toBe(0)
			end)
		end)

		t.describe("hitch decisions", function()
			local decide = JobService.hitchDecision

			t.it("finishes a couple stop when the load is coupled", function()
				t.expect(decide("couple", false, true, true, false)).toBe("arrived")
				t.expect(decide("couple", false, false, true, true)).toBe("wait")
				t.expect(decide("couple", false, false, false, true)).toBe("gone")
			end)

			t.it("finishes a decouple stop when the load comes off there", function()
				t.expect(decide("decouple", true, true, true, true)).toBe("wait")
				t.expect(decide("decouple", true, false, true, true)).toBe("arrived")
				t.expect(decide("decouple", true, false, false, true)).toBe("arrived") -- taken over at the drop
			end)

			t.it("fails a load that comes off anywhere else", function()
				t.expect(decide("decouple", true, false, true, false)).toBe("detached")
				t.expect(decide("decouple", true, false, false, false)).toBe("gone")
				t.expect(decide("waypoint", true, false, true, false)).toBe("detached")
				t.expect(decide("waypoint", true, false, false, false)).toBe("gone")
			end)

			t.it("leaves other stops to the usual arrival while the load is on (or before it is)", function()
				t.expect(decide("waypoint", true, true, true, false)).toBe("normal")
				t.expect(decide("pickup", false, false, false, false)).toBe("normal")
			end)

			t.it("knows when the load is meant to be on, and the waypoint radius", function()
				local job = ({ index = 1, stops = { { kind = "couple" }, { kind = "decouple" } } } :: any) :: Job
				t.expect(JobService.isHitched(job)).toBe(false)
				job.index = 2
				t.expect(JobService.isHitched(job)).toBe(true)
				local waypoint = ({ kind = "waypoint" } :: any) :: Types.Stop
				local drop = ({ kind = "decouple" } :: any) :: Types.Stop
				t.expect(JobService.stopRadius(FREIGHT, waypoint)).toBe(FREIGHT.waypointRadius)
				t.expect(JobService.stopRadius(FREIGHT, drop)).toBe(FREIGHT.arriveRadius)
			end)
		end)

		t.describe("stop sequences", function()
			t.it("tows: couple at the breakdown, decouple at the drop, the car spawned there", function()
				withProps(function(recorder)
					local context = fakeContext(TOWING, "pickup", PICKUP)
					local offer = Towing.offers(PLAYER, CAR, context)[1]
					local data = offer.data :: Towing.Data
					local job = Towing.start(PLAYER, offer, context)
					assert(job, "a job")
					t.expect(kinds(job)).toEqual({ "couple", "decouple" })
					t.expect(job.stops[1].locationId).toBe(data.breakdownId)
					t.expect(job.stops[2].locationId).toBe(data.dropId)
					t.expect(#recorder.spawned).toBe(1)
					t.expect(job.towTarget).toBe(recorder.spawned[1])
					t.expect(recorder.spawned[1]:GetAttribute(Jobs.props.jobAttribute)).toBe(job.id)
					t.expect(job.paidLength).toBeNear(Towing.paidApproach(TOWING, data.approach) + data.tow, SAME)
					-- The spot is busy while the job runs: no second job there, and no offers for it.
					t.expect(Towing.isFree(data.breakdownId)).toBe(false)
					t.expect(Towing.start(PLAYER, offer, context)).toBe(nil)
					for _, other in towingOffers({ offerCount = #FIXTURES.Breakdown }) do
						t.expect((other.data :: Towing.Data).breakdownId ~= data.breakdownId).toBe(true)
					end
					t.expect(Towing.onArrive(job, 1, context).outcome).toBe("advance")
					t.expect(Towing.onArrive(job, 2, context).outcome).toBe("complete")
					local pay = Towing.pay(job, context)
					t.expect(pay.total).toBe(Towing.payFor(TOWING, data.approach, data.tow, 1).total)
					-- Delivered: the car goes after the delay, and the spot is free again.
					Towing.finish(job, "complete")
					t.expect(recorder.despawned[1].delay).toBe(Jobs.props.despawnDelaySec)
					t.expect(Towing.isFree(data.breakdownId)).toBe(true)
					t.expect(job.towTarget).toBe(nil)
				end)
			end)

			t.it("removes a failed tow's car at once", function()
				withProps(function(recorder)
					local context = fakeContext(TOWING, "pickup", PICKUP)
					local job = Towing.start(PLAYER, Towing.offers(PLAYER, CAR, context)[1], context)
					assert(job, "a job")
					Towing.finish(job, "failed")
					t.expect(recorder.despawned[1].delay).toBe(0)
				end)
			end)

			t.it("hauls a short run: couple at the trailer spot, decouple at the other depot", function()
				withProps(function(recorder)
					local context = fakeContext(FREIGHT, "heavy", SEMI)
					local offer = Freight.offers(PLAYER, CAR, context)[1]
					local data = offer.data :: Freight.Data
					local job = Freight.start(PLAYER, offer, context)
					assert(job, "a job")
					t.expect(kinds(job)).toEqual({ "couple", "decouple" })
					t.expect(job.stops[1].locationId).toBe(data.spawnId)
					t.expect(job.stops[2].locationId).toBe(data.destinationId)
					t.expect(job.towTarget).toBe(recorder.spawned[1]) -- the spot's trailer, taken for the job
					t.expect(recorder.spawned[1]:GetAttribute(Jobs.props.jobAttribute)).toBe(job.id)
					t.expect(Freight.isFree(data.spawnId)).toBe(false)
					t.expect(Freight.onArrive(job, 1, context).outcome).toBe("advance")
					t.expect(Freight.onArrive(job, 2, context).outcome).toBe("complete")
					-- Failed on the way: the trailer goes at once (its spot is stocked again).
					job.index = 2
					Freight.finish(job, "failed")
					t.expect(recorder.despawned[1].delay).toBe(0)
					t.expect(Freight.isFree(data.spawnId)).toBe(true)
				end)
			end)

			t.it("hauls a long haul through its waypoints", function()
				withProps(function(recorder)
					local context = fakeContext(FREIGHT, "heavy", SEMI)
					local offers = Freight.offers(PLAYER, CAR, context)
					local offer = offers[#offers]
					local data = offer.data :: Freight.Data
					t.expect(data.longHaul).toBe(true)
					local job = Freight.start(PLAYER, offer, context)
					assert(job, "a job")
					local expected = { "couple" }
					for _ = 1, #data.waypointIds do
						table.insert(expected, "waypoint")
					end
					table.insert(expected, "decouple")
					t.expect(kinds(job)).toEqual(expected)
					local trailer = recorder.spawned[1]
					t.expect(job.towTarget).toBe(trailer)
					local loopName = MapLayout.zones.county_loop.displayName
					t.expect((string.find(job.stops[2].label, loopName, 1, true))).toBe(1)
					for index = 1, #job.stops - 1 do
						t.expect(Freight.onArrive(job, index, context).outcome).toBe("advance")
					end
					t.expect(Freight.onArrive(job, #job.stops, context).outcome).toBe("complete")
					t.expect(Freight.pay(job, context).total)
						.toBe(
							Freight.payFor(FREIGHT, Freight.paidApproach(FREIGHT, data.approach), data.haul, true, 1).total
						)
					-- Delivered: the trailer goes after the delay.
					Freight.finish(job, "complete")
					t.expect(#recorder.despawned).toBe(1)
					t.expect(recorder.despawned[1].model).toBe(trailer)
					t.expect(recorder.despawned[1].delay).toBe(Jobs.props.despawnDelaySec)
				end)
			end)

			t.it("gives back the trailer it took when the player hitched another one at the depot", function()
				withProps(function(recorder)
					local context = fakeContext(FREIGHT, "heavy", SEMI)
					local job = Freight.start(PLAYER, Freight.offers(PLAYER, CAR, context)[1], context)
					assert(job, "a job")
					local taken = recorder.spawned[1]
					local hitched = stagedModel()
					job.towTarget = hitched -- JobService adopted the one the player coupled
					Freight.finish(job, "complete")
					t.expect(#recorder.despawned).toBe(2)
					t.expect(recorder.despawned[1].model).toBe(hitched)
					t.expect(recorder.despawned[1].delay).toBe(Jobs.props.despawnDelaySec)
					t.expect(recorder.despawned[2].model).toBe(taken)
					t.expect(recorder.despawned[2].delay).toBe(0)
				end)
			end)

			t.it("starts nothing when the spot's trailer has gone since the offer", function()
				withProps(function(recorder)
					local context = fakeContext(FREIGHT, "heavy", SEMI)
					local offer = Freight.offers(PLAYER, CAR, context)[1]
					recorder.idle = false
					t.expect(Freight.start(PLAYER, offer, context)).toBe(nil)
				end)
			end)

			t.it("moves to the depot's next stocked spot when the offer's spot is taken", function()
				withProps(function()
					local context = fakeContext(FREIGHT, "heavy", SEMI)
					local offer = Freight.offers(PLAYER, CAR, context)[1]
					local first = Freight.start(PLAYER, offer, context)
					local second = Freight.start(PLAYER, offer, context)
					assert(first and second, "two jobs")
					t.expect(first.stops[1].locationId ~= second.stops[1].locationId).toBe(true)
					Freight.finish(first, "failed")
					Freight.finish(second, "failed")
				end)
			end)

			t.it("won't start freight without the license", function()
				withProps(function(recorder)
					local offer = freightOffers()[1]
					local context = fakeContext(FREIGHT, "heavy", SEMI, { licenses = {} })
					t.expect(Freight.start(PLAYER, offer, context)).toBe(nil)
					t.expect(#recorder.spawned).toBe(0)
				end)
			end)
		end)
	end)
end
