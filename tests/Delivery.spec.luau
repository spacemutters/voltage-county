--!strict
-- Delivery jobs (docs/phase-6-contracts.md "Delivery"): nearest-next stop ordering, stop counts by class and
-- level, pay with the bonus-class +20 % and the level multiplier, and offers only for classes that can deliver.
-- The offer and job tests drive the real JobType functions with a stand-in Context (straight-line distances
-- over the real MapLayout locations), so no routing or services run. Pure logic: runs in Edit mode.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Economy = require(ReplicatedStorage.Shared.Config.Economy)
local Harness = require(ReplicatedStorage.Shared.Testing.Harness)
local Jobs = require(ReplicatedStorage.Shared.Config.Jobs)
local MapLayout = require(ReplicatedStorage.Shared.Config.MapLayout)
local JobService = ServerScriptService.Server.Services.JobService
local Delivery = require(JobService.Delivery)
local Types = require(JobService.Types)

type Context = Types.Context
type Location = MapLayout.Location

local def = Jobs.types.delivery
local stops = def.stops :: Jobs.Range
local bonusStops = def.bonusStops :: Jobs.Range

local SEED = 20261020
local DRAWS = 400 -- random stop counts drawn per class
local OFFERS = 3
local MONEY = 1 -- dollars: components are rounded down separately
local SAME = 1e-6

local function horizontal(a: Vector3, b: Vector3): number
	return Vector3.new(b.X - a.X, 0, b.Z - a.Z).Magnitude
end

-- A stand-in Context: straight-line "road" lengths, MapLayout's locations, a fixed seed, and a newJob that
-- just records what the module gave it.
local function fakeContext(classId: string?, overrides: { [string]: any }?): Context
	local nextId = 0
	local context = {
		now = 0,
		def = def,
		graph = nil,
		pathfind = nil,
		mapLayout = MapLayout,
		car = nil,
		-- Parked downtown at the used lot, facing north.
		carPose = CFrame.new(460, 0, 350),
		vehicleId = "test",
		classId = classId,
		seats = 4,
		level = 1,
		levelMultiplier = 1,
		unlocks = {},
		offerCount = OFFERS,
		random = Random.new(SEED),
		newId = function(): string
			nextId += 1
			return `offer{nextId}`
		end,
		routeLength = function(from: Vector3, to: Vector3, _heading: Vector3?): number?
			return horizontal(from, to)
		end,
		locations = function(tag: string): { Location }
			local list: { Location } = {}
			for _, location in MapLayout.locations do
				if location.tag == tag then
					table.insert(list, location)
				end
			end
			return list
		end,
		makeStop = function(location: Location, kind: Types.StopKind, dwell: number?): Types.Stop
			return {
				position = location.gpsTarget or location.position,
				locationId = location.id,
				kind = kind,
				label = location.displayName,
				dwell = dwell,
			}
		end,
		newJob = function(player: Player, offer: Types.Offer, jobStops: { Types.Stop }, lengths, data): Types.Job
			return {
				id = "job1",
				type = offer.type,
				player = player,
				title = offer.title,
				stops = jobStops,
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
			} :: Types.Job
		end,
	}
	for key, value in overrides or {} do
		(context :: any)[key] = value
	end
	return context :: any
end

local function locationById(id: string): Location
	for _, location in MapLayout.locations do
		if location.id == id then
			return location
		end
	end
	error(`no location {id}`)
end

local function dropCount(offer: Types.Offer): number
	return #(offer.data :: Delivery.Data).dropIds
end

return function(t: Harness.Api)
	t.describe("Delivery", function()
		t.describe("orderNearestNext", function()
			-- Points along a line: distance is just the gap.
			local function gap(a: number, b: number): number?
				return math.abs(a - b)
			end

			t.it("always goes to the nearest remaining stop next", function()
				local ordered = Delivery.orderNearestNext(0, { 50, 10, -15, 30 }, gap)
				t.expect(ordered.items).toEqual({ 10, 30, 50, -15 })
				t.expect(ordered.legs).toEqual({ 10, 20, 20, 65 })
				t.expect(ordered.length).toBe(115)
			end)

			t.it("keeps the earlier stop on a tie", function()
				t.expect(Delivery.orderNearestNext(0, { 10, -10 }, gap).items).toEqual({ 10, -10 })
				t.expect(Delivery.orderNearestNext(0, { -10, 10 }, gap).items).toEqual({ -10, 10 })
			end)

			t.it("leaves out stops no road reaches", function()
				local function noRouteTo99(a: number, b: number): number?
					return if b == 99 then nil else math.abs(a - b)
				end
				local ordered = Delivery.orderNearestNext(0, { 99, 20, 5 }, noRouteTo99)
				t.expect(ordered.items).toEqual({ 5, 20 })
				t.expect(ordered.length).toBe(20)
			end)

			t.it("uses road lengths, not straight lines", function()
				-- B is closer as the crow flies, but A is closer by road.
				local road = { ["s>a"] = 100, ["s>b"] = 300, ["a>b"] = 150, ["b>a"] = 150 }
				local ordered = Delivery.orderNearestNext("s", { "b", "a" }, function(from: string, to: string)
					return road[`{from}>{to}`]
				end)
				t.expect(ordered.items).toEqual({ "a", "b" })
				t.expect(ordered.length).toBe(250)
			end)

			t.it("orders a real route from the depot nearest-next", function()
				local depot = locationById("cb_parcel_depot")
				local houses = {
					locationById("rv_willow_ct_3"),
					locationById("rv_elm_st_3"),
					locationById("rv_cedar_ct_1"),
					locationById("rv_elm_st_1"),
				}
				local ordered = Delivery.orderNearestNext(depot, houses, function(a: Location, b: Location)
					return horizontal(a.position, b.position)
				end)
				local ids: { string } = {}
				for _, house in ordered.items do
					table.insert(ids, house.id)
				end
				t.expect(ids).toEqual({ "rv_elm_st_3", "rv_elm_st_1", "rv_cedar_ct_1", "rv_willow_ct_3" })
			end)
		end)

		t.describe("stop counts", function()
			t.it("gives bonus classes the bonus range and others the normal one", function()
				t.expect(Delivery.stopRange(def, "sedan")).toEqual(stops)
				t.expect(Delivery.stopRange(def, "economy")).toEqual(stops)
				for _, classId in def.bonusClasses :: { string } do
					t.expect(Delivery.stopRange(def, classId)).toEqual(bonusStops)
				end
				t.expect(bonusStops.max).toBeGreaterThan(stops.max)
			end)

			t.it("keeps every route within the 3-6 drops the contract allows", function()
				t.expect(stops.min >= 3 and bonusStops.max <= 6).toBe(true)
				for _, classId in { "sedan", "van" } do
					for _, unlocks in { {}, { extraStop = true } } do
						local range = Delivery.stopRange(def, classId, unlocks)
						t.expect(range.min >= 3 and range.max <= 6 and range.min <= range.max).toBe(true)
					end
				end
			end)

			t.it("adds a stop with the extraStop unlock, capped at the most any route carries", function()
				local ceiling = math.max(stops.max, bonusStops.max)
				local normal = Delivery.stopRange(def, "sedan", { extraStop = true })
				t.expect(normal.min).toBe(math.min(stops.min + 1, ceiling))
				t.expect(normal.max).toBe(math.min(stops.max + 1, ceiling))
				local bonus = Delivery.stopRange(def, "van", { extraStop = true })
				t.expect(bonus.max).toBe(ceiling)
			end)

			t.it("draws counts across the whole range, never outside it", function()
				for _, classId in { "sedan", "pickup" } do
					local range = Delivery.stopRange(def, classId)
					local random = Random.new(SEED)
					local seen: { [number]: boolean } = {}
					for _ = 1, DRAWS do
						local count = Delivery.stopCount(def, classId, nil, random)
						t.expect(count >= range.min and count <= range.max).toBe(true)
						seen[count] = true
					end
					for count = range.min, range.max do
						t.expect(seen[count]).toBe(true)
					end
				end
			end)

			t.it("picks different houses", function()
				local houses = fakeContext("van").locations("HousePlot")
				local picked = Delivery.pick(houses, 6, Random.new(SEED))
				t.expect(#picked).toBe(6)
				local seen: { [string]: boolean } = {}
				for _, house in picked do
					t.expect(seen[house.id]).toBe(nil)
					seen[house.id] = true
				end
				t.expect(#Delivery.pick({ 1, 2 }, 5, Random.new(SEED))).toBe(2)
			end)
		end)

		t.describe("pay", function()
			t.it("pays base, per drop and per stud", function()
				local pay = Delivery.payFor(def, 4, 5000, false, 1)
				local base = def.basePay + (def.payPerDrop :: number) * 4
				t.expect(pay.base).toBeNear(base, MONEY)
				t.expect(pay.distance).toBeNear(5000 * def.payPerStud, MONEY)
				t.expect(pay.class).toBe(0)
				t.expect(pay.tip).toBe(0)
				t.expect(pay.level).toBe(0)
				t.expect(pay.total).toBe(pay.base + pay.distance + pay.class + pay.tip + pay.level)
			end)

			t.it("adds 20 % in a bonus class", function()
				t.expect(def.bonusMultiplier).toBeNear(1 + Economy.activities.deliveryVehicleBonus, SAME)
				local plain = Delivery.payFor(def, 5, 6000, false, 1)
				local bonus = Delivery.payFor(def, 5, 6000, true, 1)
				t.expect(bonus.class).toBeNear((plain.base + plain.distance) * 0.2, MONEY + 1)
				t.expect(bonus.total / plain.total).toBeNear(1.2, 0.001)
			end)

			t.it("scales by the level multiplier on top", function()
				local plain = Delivery.payFor(def, 3, 4000, true, 1)
				local levelled = Delivery.payFor(def, 3, 4000, true, 1.25)
				t.expect(levelled.level).toBeNear(plain.total * 0.25, MONEY + 1)
				t.expect(levelled.total / plain.total).toBeNear(1.25, 0.001)
			end)

			t.it("pays more for every extra drop and stud", function()
				local short = Delivery.payFor(def, 3, 3000, false, 1).total
				t.expect(Delivery.payFor(def, 4, 3000, false, 1).total).toBeGreaterThan(short)
				t.expect(Delivery.payFor(def, 3, 3500, false, 1).total).toBeGreaterThan(short)
			end)

			t.it("pays in whole dollars", function()
				local pay = Delivery.payFor(def, 6, 6226.7, true, 1.15)
				for _, amount in { pay.base, pay.distance, pay.class, pay.level, pay.total } do
					t.expect(amount).toBe(math.floor(amount))
				end
			end)
		end)

		t.describe("offers", function()
			t.it("offers nothing to classes that can't deliver, or with no car", function()
				for _, classId in { "sports", "luxury", "muscle", "heavy" } do
					t.expect(#Delivery.offers(nil :: any, nil, fakeContext(classId))).toBe(0)
				end
				t.expect(#Delivery.offers(nil :: any, nil, fakeContext(nil))).toBe(0)
			end)

			t.it("offers every eligible class offerCount routes with the right number of drops", function()
				for _, classId in def.classes do
					local offers = Delivery.offers(nil :: any, nil, fakeContext(classId))
					t.expect(#offers).toBe(OFFERS)
					local range = Delivery.stopRange(def, classId)
					for _, offer in offers do
						local drops = dropCount(offer)
						t.expect(drops >= range.min and drops <= range.max).toBe(true)
						t.expect(offer.stops).toBe(drops + 1)
						t.expect(offer.type).toBe("delivery")
					end
				end
			end)

			t.it("loads at the delivery depot and prices the route as payFor does", function()
				local context = fakeContext("van")
				for _, offer in Delivery.offers(nil :: any, nil, context) do
					local data = offer.data :: Delivery.Data
					t.expect(data.depotId).toBe("cb_parcel_depot")
					t.expect(data.bonus).toBe(true)
					local expected = Delivery.payFor(def, #data.dropIds, data.paidLength, true, 1)
					t.expect(offer.pay).toBe(expected.total)
					-- The distance shown includes the unpaid leg to the depot.
					t.expect(offer.distance).toBeGreaterThan(data.paidLength)
				end
			end)

			t.it("orders each offer's drops nearest-next from the depot", function()
				local context = fakeContext("sedan")
				local depot = locationById("cb_parcel_depot")
				for _, offer in Delivery.offers(nil :: any, nil, context) do
					local data = offer.data :: Delivery.Data
					local here = depot.position
					local remaining = table.clone(data.dropIds)
					for _, id in data.dropIds do
						local chosen = locationById(id)
						for _, otherId in remaining do
							local other = locationById(otherId)
							local closer = horizontal(here, other.position) < horizontal(here, chosen.position) - SAME
							t.expect(closer).toBe(false)
						end
						table.remove(remaining, table.find(remaining, id) :: number)
						here = chosen.position
					end
				end
			end)
		end)

		t.describe("a job", function()
			t.it("starts with a load stop at the depot, then the drops in order", function()
				local context = fakeContext("pickup")
				local offer = Delivery.offers(nil :: any, nil, context)[1]
				local job = Delivery.start(nil :: any, offer, context) :: Types.Job
				t.expect(job ~= nil).toBe(true)
				local data = offer.data :: Delivery.Data
				t.expect(#job.stops).toBe(#data.dropIds + 1)
				t.expect(job.stops[1].kind).toBe("load")
				t.expect(job.stops[1].locationId).toBe("cb_parcel_depot")
				t.expect(job.stops[1].dwell).toBe(def.loadSeconds)
				for index, id in data.dropIds do
					t.expect(job.stops[index + 1].kind).toBe("drop")
					t.expect(job.stops[index + 1].locationId).toBe(id)
					t.expect(job.stops[index + 1].dwell).toBe(def.dropSeconds)
				end
				t.expect(job.paidLength).toBe(data.paidLength)
				t.expect(job.routeLength).toBeGreaterThan(job.paidLength)
			end)

			t.it("refuses to start in a car that can't deliver", function()
				local offer = Delivery.offers(nil :: any, nil, fakeContext("sedan"))[1]
				t.expect(Delivery.start(nil :: any, offer, fakeContext("sports"))).toBe(nil)
			end)

			t.it("takes the bonus from the car the job starts in", function()
				local offer = Delivery.offers(nil :: any, nil, fakeContext("sedan"))[1]
				local context = fakeContext("suv")
				local job = Delivery.start(nil :: any, offer, context) :: Types.Job
				t.expect((job.data :: Delivery.Data).bonus).toBe(true)
				local data = offer.data :: Delivery.Data
				t.expect(Delivery.pay(job, context).total)
					.toBe(Delivery.payFor(def, #data.dropIds, data.paidLength, true, 1).total)
			end)

			t.it("advances after loading and each drop, and completes at the last", function()
				local context = fakeContext("van")
				local offer = Delivery.offers(nil :: any, nil, context)[1]
				local job = Delivery.start(nil :: any, offer, context) :: Types.Job
				for index = 1, #job.stops - 1 do
					t.expect(Delivery.onArrive(job, index, context).outcome).toBe("advance")
				end
				t.expect(Delivery.onArrive(job, #job.stops, context).outcome).toBe("complete")
			end)

			t.it("pays at the player's level when the job ends", function()
				local context = fakeContext("economy")
				local offer = Delivery.offers(nil :: any, nil, context)[1]
				local job = Delivery.start(nil :: any, offer, context) :: Types.Job
				local levelled = fakeContext("economy", { levelMultiplier = 1.1 })
				t.expect(Delivery.pay(job, levelled).total).toBeGreaterThan(Delivery.pay(job, context).total)
			end)
		end)
	end)
end
