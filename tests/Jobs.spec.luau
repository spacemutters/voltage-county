--!strict
-- The jobs framework's decisions (docs/phase-6-contracts.md "Tests"): the job state machine, the arrival decision
-- (distance to a stop or its road point, still speed, dwell) and the speed it is judged on, the rideshare pay
-- formula with its smooth-driving tip and XL fares, how both job types' pay lands on the PLAN.md §4 rates, time
-- limits, eligibility by class, XL by seats, and XP per job. Delivery's own route and pay helpers have
-- tests/Delivery.spec, and levels tests/Levels.spec. Pure logic: runs in Edit mode.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Catalog = require(ReplicatedStorage.Shared.Vehicle.Catalog)
local Classes = require(ReplicatedStorage.Shared.Config.Classes)
local Economy = require(ReplicatedStorage.Shared.Config.Economy)
local Graph = require(ReplicatedStorage.Shared.Road.Graph)
local Harness = require(ReplicatedStorage.Shared.Testing.Harness)
local Jobs = require(ReplicatedStorage.Shared.Config.Jobs)
local Units = require(ReplicatedStorage.Shared.Util.Units)
local JobServiceFolder = ServerScriptService.Server.Services.JobService
local JobService = require(JobServiceFolder)
local Delivery = require(JobServiceFolder.Delivery)
local Rideshare = require(JobServiceFolder.Rideshare)
local Types = require(JobServiceFolder.Types)

type Sample = JobService.Sample
type JobEvent = JobService.JobEvent

local RIDESHARE = Jobs.types.rideshare
local DELIVERY = Jobs.types.delivery
local SECONDS_PER_MINUTE = 60

-- The contract's classes (docs/phase-6-contracts.md "Config").
local RIDESHARE_CLASSES = { "economy", "sedan", "minivan", "suv", "luxury", "sports", "muscle" }
local RIDESHARE_XL_CLASSES = { "suv", "minivan" }
local DELIVERY_CLASSES = { "van", "suv", "pickup", "minivan", "sedan", "economy" }
local DELIVERY_BONUS_CLASSES = { "van", "suv", "pickup" }

-- The test cars Dev/JobTests drives (an eligible sedan and a Northline van) and a car that can do neither job.
local SEDAN = { vehicleId = "ohm_spark", trim = "standard" }
local VAN = { vehicleId = "northline_satchel", trim = "standard" }
local SEMI = { vehicleId = "ohm_hauler", trim = "standard" }

local EVENTS: { JobEvent } = { "accept", "advance", "complete", "fail", "cancel" }
local FINAL_STATES: { Types.JobState } = { "complete", "failed" }

-- Vector3 components are 32-bit floats: positions far from the origin carry a little rounding.
local FLOAT_TOLERANCE = 1e-3
local SAME = 1e-9 -- unrounded sums of the same numbers
local RELATIVE = 1e-9 -- unrounded rates, as a share of the rate
-- Delivery.payFor rounds each of its parts down to whole dollars: at most this many dollars short in all.
local ROUNDING_DOLLARS = 4
-- A driver at the calibration pace gets at least this many times the driving time it needs, plus every dwell.
local TIME_LIMIT_HEADROOM = 1.5

-- The pace (studs/s) Config/Jobs calibrates driving on (Jobs.calibration.referenceMph).
local CALIBRATION = Jobs.calibration
local referencePace = Units.mphToStuds(CALIBRATION.referenceMph)

local function contains(list: { string }?, value: string): boolean
	return list ~= nil and table.find(list, value) ~= nil
end

local function listOf(list: { string }?): { string }
	return list or {}
end

-- A range Config/Jobs must have set (the spec fails here, by name, when it hasn't).
local function rangeOf(range: Jobs.Range?, name: string): Jobs.Range
	assert(range ~= nil, `Config/Jobs is missing {name}`)
	return range
end

-- Samples of a car moving along +X at `speed` studs/s (climbing `climb` studs/s), one every `dt` from t = 0.
local function track(count: number, speed: number, dt: number, climb: number?): { Sample }
	local samples: { Sample } = {}
	for index = 0, count - 1 do
		local t = index * dt
		table.insert(samples, {
			t = t,
			position = Vector3.new(1200 + speed * t, 4 + (climb or 0) * t, -900),
			speed = nil,
		})
	end
	return samples
end

local function smooth(): Types.Smoothness
	return { tracking = true, hardBrakes = 0, crashes = 0, lastEventAt = 0 }
end

local function mph(value: number): number
	return Units.mphToStuds(value)
end

return function(t: Harness.Api)
	t.describe("Jobs", function()
		t.describe("state machine", function()
			t.it("starts a job only from an offer, by accepting it", function()
				t.expect(JobService.transition("offered", "accept")).toBe("accepted")
				for _, event: JobEvent in EVENTS do
					if event ~= "accept" then
						t.expect(JobService.transition("offered", event)).toBe(nil)
					end
				end
			end)

			t.it("stays accepted while it moves from stop to stop", function()
				t.expect(JobService.transition("accepted", "advance")).toBe("accepted")
			end)

			t.it("completes from the last stop, and fails on a failure or a cancel", function()
				t.expect(JobService.transition("accepted", "complete")).toBe("complete")
				t.expect(JobService.transition("accepted", "fail")).toBe("failed")
				t.expect(JobService.transition("accepted", "cancel")).toBe("failed")
			end)

			t.it("never accepts a job twice", function()
				t.expect(JobService.transition("accepted", "accept")).toBe(nil)
			end)

			t.it("never leaves complete or failed", function()
				for _, state: Types.JobState in FINAL_STATES do
					for _, event: JobEvent in EVENTS do
						t.expect(JobService.transition(state, event)).toBe(nil)
					end
				end
			end)

			t.it("walks a whole delivery: accept, load and drops, complete", function()
				local state: Types.JobState = "offered"
				local events: { JobEvent } = { "accept", "advance", "advance", "advance", "complete" }
				for _, event: JobEvent in events do
					local nextState = JobService.transition(state, event)
					t.expect(nextState).never.toBe(nil)
					state = nextState :: Types.JobState
				end
				t.expect(state).toBe("complete")
			end)
		end)

		t.describe("arrival", function()
			local radius = RIDESHARE.arriveRadius
			local still = mph(RIDESHARE.stillSpeedMph)
			local dwell = RIDESHARE.pickupDwell or 0

			t.it("is far outside the arrive radius, however still the car is", function()
				t.expect(JobService.arrivalDecision(radius + 0.01, 0, radius, still, dwell + 1, dwell)).toBe("far")
			end)

			t.it("counts the arrive radius itself as close enough", function()
				t.expect(JobService.arrivalDecision(radius, 0, radius, still, dwell, dwell)).toBe("arrived")
			end)

			t.it("waits while the car moves faster than the still speed, or before its speed is known", function()
				t.expect(JobService.arrivalDecision(radius / 2, still + 0.01, radius, still, dwell, dwell))
					.toBe("moving")
				t.expect(JobService.arrivalDecision(radius / 2, nil, radius, still, dwell, dwell)).toBe("moving")
			end)

			t.it("counts the still speed itself as still", function()
				t.expect(JobService.arrivalDecision(radius / 2, still, radius, still, dwell, dwell)).toBe("arrived")
			end)

			t.it("holds the car for the stop's dwell before it counts", function()
				local load = DELIVERY.loadSeconds or 0
				t.expect(load).toBeGreaterThan(0)
				t.expect(JobService.arrivalDecision(0, 0, radius, still, load - 0.01, load)).toBe("dwelling")
				t.expect(JobService.arrivalDecision(0, 0, radius, still, load, load)).toBe("arrived")
			end)

			t.it("arrives at once at a stop with no dwell", function()
				t.expect(JobService.arrivalDecision(radius / 2, 0, radius, still, 0, 0)).toBe("arrived")
			end)

			t.it("measures to the stop or its road point, whichever is nearer, across the ground", function()
				local stop: Types.Stop = {
					position = Vector3.new(-750, 0, 250), -- a lot set back from the road
					approach = Vector3.new(-750, 0.2, 300), -- the road point in front of it
					kind = "load",
					label = "Depot",
				}
				-- On the road 10 studs past the road point, and high above it: 10 studs.
				t.expect(JobService.distanceToStop(stop, Vector3.new(-740, 30, 300))).toBeNear(10, FLOAT_TOLERANCE)
				-- Inside the lot: from the stop itself.
				t.expect(JobService.distanceToStop(stop, Vector3.new(-750, 2, 262))).toBeNear(12, FLOAT_TOLERANCE)
				-- With no road point, only the stop counts.
				local bare: Types.Stop = { position = stop.position, kind = "drop", label = "House" }
				t.expect(JobService.distanceToStop(bare, Vector3.new(-740, 30, 300)))
					.toBeNear(math.sqrt(10 * 10 + 50 * 50), FLOAT_TOLERANCE)
			end)

			t.it("calls an arrive forged only well outside the arrive radius", function()
				-- An honest "I'm here" within the radius (or just outside it) is never logged as a forgery.
				t.expect(Jobs.forgedArriveFactor).toBeGreaterThan(1)
			end)
		end)

		t.describe("speed over a window", function()
			local window = Jobs.smoothness.speedWindow
			local dt = Jobs.checkInterval
			local covering = math.ceil(window / dt - SAME) + 1 -- samples that just span the window

			t.it("is unknown with no samples, or until they span the window", function()
				t.expect(JobService.speedOver({}, window)).toBe(nil)
				t.expect(JobService.speedOver(track(covering - 1, 20, dt), window)).toBe(nil)
			end)

			t.it("is the ground distance over the time once they do", function()
				t.expect(JobService.speedOver(track(covering, 20, dt), window)).toBeNear(20, FLOAT_TOLERANCE)
				t.expect(JobService.speedOver(track(covering + 4, 35, dt), window)).toBeNear(35, FLOAT_TOLERANCE)
			end)

			t.it("ignores climbing", function()
				t.expect(JobService.speedOver(track(covering, 20, dt, 15), window)).toBeNear(20, FLOAT_TOLERANCE)
			end)

			t.it("looks back from the newest sample only as far as the window", function()
				-- Still for a while, then moving at 20 studs/s for exactly the window.
				local samples = track(covering + 3, 0, dt)
				local newest = samples[#samples].t
				for _, sample in samples do
					local moving = math.max(sample.t - (newest - window), 0)
					sample.position += Vector3.new(20 * moving, 0, 0)
				end
				t.expect(JobService.speedOver(samples, window)).toBeNear(20, FLOAT_TOLERANCE)
			end)
		end)

		t.describe("smooth driving", function()
			local settings = Jobs.smoothness
			local fast = settings.minSpeedMph + settings.crashSpeedLossMph + 10 -- mph, well above every threshold

			t.it("ignores slowing that starts below the minimum speed", function()
				local before = mph(settings.minSpeedMph - 1)
				t.expect(JobService.speedLossEvent(before, 0, settings.crashWindow)).toBe(nil)
			end)

			t.it("ignores holding speed and speeding up", function()
				t.expect(JobService.speedLossEvent(mph(fast), mph(fast), settings.brakeWindow)).toBe(nil)
				t.expect(JobService.speedLossEvent(mph(fast), mph(fast + 5), settings.brakeWindow)).toBe(nil)
			end)

			t.it("lets a gentle stop go and calls a fast one hard braking", function()
				local seconds = settings.brakeWindow
				local gentle = (settings.hardBrakeMphPerSec - 1) * seconds
				local hard = (settings.hardBrakeMphPerSec + 1) * seconds
				t.expect(hard).toBeLessThan(settings.crashSpeedLossMph) -- not a crash: a brake
				t.expect(JobService.speedLossEvent(mph(fast), mph(fast - gentle), seconds)).toBe(nil)
				t.expect(JobService.speedLossEvent(mph(fast), mph(fast - hard), seconds)).toBe("hardBrake")
			end)

			t.it("calls a big sudden loss a crash", function()
				local loss = settings.crashSpeedLossMph + 1
				t.expect(JobService.speedLossEvent(mph(fast), mph(fast - loss), settings.crashWindow)).toBe("crash")
			end)

			t.it("never calls the same loss spread over a longer time a crash", function()
				local loss = settings.crashSpeedLossMph + 1
				local slow = settings.crashWindow + Jobs.checkInterval + 1
				t.expect(JobService.speedLossEvent(mph(fast), mph(fast - loss), slow)).never.toBe("crash")
			end)

			t.it("counts the first hard brake and the first crash", function()
				local record = smooth()
				t.expect(JobService.recordSmoothEvent(record, "hardBrake", 10)).toBe(true)
				t.expect(record.hardBrakes).toBe(1)
				local other = smooth()
				t.expect(JobService.recordSmoothEvent(other, "crash", 10)).toBe(true)
				t.expect(other.crashes).toBe(1)
			end)

			t.it("counts one long stop as one hard brake", function()
				local record = smooth()
				JobService.recordSmoothEvent(record, "hardBrake", 10)
				t.expect(JobService.recordSmoothEvent(record, "hardBrake", 10 + settings.eventCooldownSec / 2))
					.toBe(false)
				t.expect(record.hardBrakes).toBe(1)
			end)

			t.it("turns a hard brake into a crash when the crash follows at once", function()
				local record = smooth()
				JobService.recordSmoothEvent(record, "hardBrake", 10)
				t.expect(JobService.recordSmoothEvent(record, "crash", 10 + settings.eventCooldownSec / 2)).toBe(true)
				t.expect(record.hardBrakes).toBe(0)
				t.expect(record.crashes).toBe(1)
			end)

			t.it("counts events again once the cooldown has passed", function()
				local record = smooth()
				JobService.recordSmoothEvent(record, "hardBrake", 10)
				JobService.recordSmoothEvent(record, "hardBrake", 10 + settings.eventCooldownSec + 0.01)
				t.expect(record.hardBrakes).toBe(2)
			end)
		end)

		t.describe("rideshare pay", function()
			local studs = 2500

			t.it("pays base plus distance along the road", function()
				local base, distance, class = Rideshare.fare(RIDESHARE, studs, false)
				t.expect(base).toBeNear(RIDESHARE.basePay, SAME)
				t.expect(distance).toBeNear(studs * RIDESHARE.payPerStud, SAME)
				t.expect(class).toBeNear(0, SAME)
			end)

			t.it("pays no distance for a ride of no length", function()
				local _, distance = Rideshare.fare(RIDESHARE, -50, false)
				t.expect(distance).toBe(0)
			end)

			t.it("multiplies the whole XL fare by xlMultiplier, the §4 XL / sedan ratio", function()
				local multiplier = RIDESHARE.xlMultiplier or 1
				t.expect(multiplier).toBeNear(Economy.activities.rideshareXL / Economy.activities.rideshare, SAME)
				local base, distance, class = Rideshare.fare(RIDESHARE, studs, true)
				t.expect(base + distance + class).toBeNear((base + distance) * multiplier, SAME)
			end)

			t.it("pays more for a longer ride", function()
				local short = Rideshare.breakdown(RIDESHARE, studs, false, 1, 1).total
				local long = Rideshare.breakdown(RIDESHARE, studs + 100, false, 1, 1).total
				t.expect(long).toBeGreaterThan(short)
			end)

			t.it("keeps the whole tip for a smooth ride and loses a share per hard brake and crash", function()
				local settings = Jobs.smoothness
				t.expect(Rideshare.tipShare(0, 0)).toBe(1)
				t.expect(Rideshare.tipShare(1, 0)).toBeNear(1 - settings.hardBrakePenalty, SAME)
				t.expect(Rideshare.tipShare(0, 1)).toBeNear(1 - settings.crashPenalty, SAME)
				t.expect(Rideshare.tipShare(100, 100)).toBe(0)
			end)

			t.it("adds a tip of up to tipMax of the fare and the level on top; the total is the parts", function()
				local multiplier = 1.1
				local share = 0.5
				local pay = Rideshare.breakdown(RIDESHARE, studs, false, multiplier, share)
				local fare = pay.base + pay.distance + pay.class
				t.expect(pay.tip).toBeNear(fare * Jobs.tipMax * share, SAME)
				t.expect(pay.level).toBeNear(fare * (multiplier - 1), SAME)
				t.expect(pay.total).toBeNear(fare + pay.tip + pay.level, SAME)
			end)

			t.it("never scales the tip by the level, nor pays below level 1", function()
				local top = Rideshare.breakdown(RIDESHARE, studs, false, 1.25, 1)
				local first = Rideshare.breakdown(RIDESHARE, studs, false, 1, 1)
				t.expect(top.tip).toBeNear(first.tip, SAME)
				t.expect(Rideshare.breakdown(RIDESHARE, studs, false, 0.5, 0).level).toBe(0)
			end)

			t.it("pays the pickup leg driven, up to pickupMaxStuds", function()
				local most = RIDESHARE.pickupMaxStuds or math.huge
				t.expect(Rideshare.paidPickup(RIDESHARE, 0)).toBe(0)
				t.expect(Rideshare.paidPickup(RIDESHARE, -50)).toBe(0)
				t.expect(Rideshare.paidPickup(RIDESHARE, 700)).toBe(math.min(700, most))
				t.expect(Rideshare.paidPickup(RIDESHARE, most + 1000)).toBe(most)
			end)
		end)

		t.describe("pay against the §4 rates", function()
			-- Config/Jobs calibrates a whole job cycle (Jobs.calibration: unpaid legs, stops and time between jobs,
			-- paid for by basePay) plus the paid route at one pace. These rebuild that cycle from the calibration
			-- inputs, not from the pay, and check every route length lands on the rate.

			t.it("prices both job types' driving at the calibration pace", function()
				local rate = Economy.activities.rideshare / SECONDS_PER_MINUTE
				local ridesharePace = rate / (RIDESHARE.payPerStud * (1 + Jobs.averageTipShare))
				t.expect(ridesharePace).toBeNear(referencePace, referencePace * RELATIVE)
				local deliveryPace = Economy.activities.delivery / SECONDS_PER_MINUTE / DELIVERY.payPerStud
				t.expect(deliveryPace).toBeNear(referencePace, referencePace * RELATIVE)
				t.expect(CALIBRATION.averageTipShare).toBe(Jobs.averageTipShare)
			end)

			t.it("prices driving at a pace the county's paved roads allow", function()
				local slowest, fastest = math.huge, 0
				for _, edge in Graph.edges() do
					if edge.surface ~= "dirt" then
						slowest = math.min(slowest, edge.speedLimitMph)
						fastest = math.max(fastest, edge.speedLimitMph)
					end
				end
				local pace = Units.studsToMph(referencePace)
				t.expect(pace).toBeGreaterThan(slowest - SAME)
				t.expect(pace).toBeLessThan(fastest + SAME)
			end)

			t.it("assumes a mid-skill tip no bigger than the largest", function()
				t.expect(Jobs.averageTipShare).toBeGreaterThan(0)
				t.expect(Jobs.averageTipShare).toBeLessThan(Jobs.tipMax + SAME)
			end)

			t.it("pays a mid-skill rideshare driver the sedan and XL rates for any ride and pickup leg", function()
				local band = rangeOf(RIDESHARE.routeBand, "rideshare routeBand")
				local share = CALIBRATION.averageTipShare / Jobs.tipMax -- a mid-skill driver's share of the largest tip
				-- The calibrated cycle besides the driving: both stops and the time between jobs.
				local fixedSeconds = CALIBRATION.stopSeconds * CALIBRATION.rideshareStops + CALIBRATION.betweenSeconds
				local pickups = { 0, CALIBRATION.pickupStuds, RIDESHARE.pickupMaxStuds or CALIBRATION.pickupStuds }
				local cases = {
					{ xl = false, target = Economy.activities.rideshare },
					{ xl = true, target = Economy.activities.rideshareXL },
				}
				for _, case in cases do
					for _, pickup in pickups do
						for _, studs in { band.min, (band.min + band.max) / 2, band.max } do
							local paid = Rideshare.paidPickup(RIDESHARE, pickup) + studs
							local pay = Rideshare.breakdown(RIDESHARE, paid, case.xl, 1, share).total
							local seconds = fixedSeconds + (pickup + studs) / referencePace
							t.expect(pay / seconds * SECONDS_PER_MINUTE).toBeNear(case.target, case.target * RELATIVE)
						end
					end
				end
			end)

			t.it("keeps the shortest ride's fixed pay under half its fare", function()
				-- With shorter rides the fixed part (stops, time between jobs) is most of a fare, which a player who
				-- skips that time could farm.
				local band = rangeOf(RIDESHARE.routeBand, "rideshare routeBand")
				local shortest = Rideshare.breakdown(RIDESHARE, band.min, false, 1, 0)
				t.expect(shortest.base).toBeLessThan(shortest.total / 2)
			end)

			t.it("pays a delivery driver the rate (+20 % in a bonus class) for any route", function()
				local rate = Economy.activities.delivery / SECONDS_PER_MINUTE
				-- The calibrated cycle besides the paid route: the leg to the depot, loading and the time between jobs.
				local fixedSeconds = CALIBRATION.toDepotStuds / referencePace
					+ CALIBRATION.loadSeconds
					+ CALIBRATION.betweenSeconds
				local dropSeconds = CALIBRATION.dropSeconds
				t.expect(DELIVERY.payPerDrop or 0).toBeNear(rate * dropSeconds, SAME)
				local bonusRate = Economy.activities.delivery * (1 + Economy.activities.deliveryVehicleBonus)
				t.expect(DELIVERY.bonusMultiplier or 1).toBeNear(1 + Economy.activities.deliveryVehicleBonus, SAME)
				local normalStops = rangeOf(DELIVERY.stops, "delivery stops")
				local bonusStops = rangeOf(DELIVERY.bonusStops, "delivery bonusStops")
				for drops = math.min(normalStops.min, bonusStops.min), math.max(normalStops.max, bonusStops.max) do
					for _, studs in { 2000, 5000, 8000 } do
						local seconds = fixedSeconds + drops * dropSeconds + studs / referencePace
						local slack = ROUNDING_DOLLARS * SECONDS_PER_MINUTE / seconds
						local normal = Delivery.payFor(DELIVERY, drops, studs, false, 1).total
						local bonus = Delivery.payFor(DELIVERY, drops, studs, true, 1).total
						t.expect(normal / seconds * SECONDS_PER_MINUTE).toBeNear(Economy.activities.delivery, slack)
						t.expect(bonus / seconds * SECONDS_PER_MINUTE).toBeNear(bonusRate, slack)
					end
				end
			end)
		end)

		t.describe("time limits", function()
			t.it("allow the route at timeLimitPerStud plus the grace", function()
				for _, def in { RIDESHARE, DELIVERY } do
					t.expect(JobService.timeLimit(def, 1000))
						.toBeNear(1000 * def.timeLimitPerStud + def.timeGraceSec, SAME)
				end
			end)

			t.it("give a route of no length the grace and never less", function()
				t.expect(JobService.timeLimit(RIDESHARE, 0)).toBeNear(RIDESHARE.timeGraceSec, SAME)
				t.expect(JobService.timeLimit(RIDESHARE, -500)).toBeNear(RIDESHARE.timeGraceSec, SAME)
			end)

			t.it("allow longer for longer routes", function()
				t.expect(JobService.timeLimit(DELIVERY, 4000)).toBeGreaterThan(JobService.timeLimit(DELIVERY, 3000))
			end)

			t.it("leave a driver at the calibration pace plenty of time, stops included", function()
				local rideshareDwell = (RIDESHARE.pickupDwell or 0) + (RIDESHARE.dropoffDwell or 0)
				local mostDrops = math.max(
					rangeOf(DELIVERY.stops, "delivery stops").max,
					rangeOf(DELIVERY.bonusStops, "delivery bonusStops").max
				)
				local deliveryDwell = (DELIVERY.loadSeconds or 0) + mostDrops * (DELIVERY.dropSeconds or 0)
				local cases = { { def = RIDESHARE, dwell = rideshareDwell }, { def = DELIVERY, dwell = deliveryDwell } }
				for _, case in cases do
					for _, studs in { 500, 2500, 8000 } do
						local needed = studs / referencePace * TIME_LIMIT_HEADROOM + case.dwell
						t.expect(JobService.timeLimit(case.def, studs)).toBeGreaterThan(needed)
					end
				end
			end)
		end)

		t.describe("eligibility by class", function()
			t.it("lets exactly the contract's classes do rideshare", function()
				for classId in Classes do
					t.expect(JobService.isEligible(RIDESHARE, classId)).toBe(contains(RIDESHARE_CLASSES, classId))
				end
			end)

			t.it("lets exactly the contract's classes deliver, with the bonus for vans, SUVs and pickups", function()
				for classId in Classes do
					t.expect(JobService.isEligible(DELIVERY, classId)).toBe(contains(DELIVERY_CLASSES, classId))
					t.expect(Delivery.isBonusClass(DELIVERY, classId)).toBe(contains(DELIVERY_BONUS_CLASSES, classId))
					t.expect(contains(Economy.deliveryBonusClasses, classId))
						.toBe(contains(DELIVERY_BONUS_CLASSES, classId))
				end
			end)

			t.it("refuses a car with no class or a class that doesn't exist", function()
				t.expect(JobService.isEligible(RIDESHARE, nil)).toBe(false)
				t.expect(JobService.isEligible(DELIVERY, "not_a_class")).toBe(false)
			end)

			t.it("names only real classes", function()
				for _, def in { RIDESHARE, DELIVERY } do
					local lists: { { string } } = { def.classes, listOf(def.xlClasses), listOf(def.bonusClasses) }
					for _, list in lists do
						for _, classId in list do
							t.expect(Classes[classId] ~= nil).toBe(true)
						end
					end
				end
			end)

			t.it("has a drivable car in the catalog for every eligible class", function()
				local drivable: { [string]: boolean } = {}
				for _, vehicleId in Catalog.vehicleIds() do
					local vehicle = Catalog.getVehicle(vehicleId)
					if vehicle and vehicle.playerDrivable then
						drivable[vehicle.class] = true
					end
				end
				for _, def in { RIDESHARE, DELIVERY } do
					for _, classId in def.classes do
						t.expect(drivable[classId] == true).toBe(true)
					end
				end
			end)

			t.it("goes by the car's class: the test cars", function()
				local function classOf(car: { vehicleId: string, trim: string }): string?
					local vehicle = Catalog.getVehicle(car.vehicleId)
					t.expect(vehicle ~= nil and Catalog.getTrim(car.vehicleId, car.trim) ~= nil).toBe(true)
					return if vehicle then vehicle.class else nil
				end
				t.expect(JobService.isEligible(RIDESHARE, classOf(SEDAN))).toBe(true)
				t.expect(JobService.isEligible(DELIVERY, classOf(SEDAN))).toBe(true)
				t.expect(JobService.isEligible(RIDESHARE, classOf(VAN))).toBe(false)
				t.expect(JobService.isEligible(DELIVERY, classOf(VAN))).toBe(true)
				t.expect(Delivery.isBonusClass(DELIVERY, classOf(VAN))).toBe(true)
				t.expect(JobService.isEligible(RIDESHARE, classOf(SEMI))).toBe(false)
				t.expect(JobService.isEligible(DELIVERY, classOf(SEMI))).toBe(false)
			end)
		end)

		t.describe("XL fares", function()
			local minSeats = RIDESHARE.xlMinSeats or math.huge

			t.it("go to every SUV and minivan, whatever the seats", function()
				t.expect(#listOf(RIDESHARE.xlClasses)).toBe(#RIDESHARE_XL_CLASSES)
				for _, classId in RIDESHARE_XL_CLASSES do
					t.expect(contains(RIDESHARE.xlClasses, classId)).toBe(true)
					t.expect(Rideshare.isXL(RIDESHARE, classId, Classes[classId].seats.min)).toBe(true)
				end
			end)

			t.it("go to any other eligible car from xlMinSeats seats up, and not one seat fewer", function()
				t.expect(RIDESHARE.xlMinSeats).toBe(6) -- the contract: "any trim with ≥ 6 seats"
				t.expect(Rideshare.isXL(RIDESHARE, "luxury", minSeats)).toBe(true)
				t.expect(Rideshare.isXL(RIDESHARE, "luxury", minSeats - 1)).toBe(false)
				t.expect(Rideshare.isXL(RIDESHARE, "sedan", minSeats - 1)).toBe(false)
			end)

			t.it("never go to a car that can't do rideshare, however many seats", function()
				t.expect(Rideshare.isXL(RIDESHARE, "van", minSeats + 10)).toBe(false)
				t.expect(Rideshare.isXL(RIDESHARE, nil, minSeats + 10)).toBe(false)
			end)

			t.it(
				"follow the catalog's seats: big trims outside the XL classes get them, the test sedan doesn't",
				function()
					local bySeats = 0
					for _, vehicleId in Catalog.vehicleIds() do
						local vehicle = Catalog.getVehicle(vehicleId)
						if vehicle and vehicle.playerDrivable and contains(RIDESHARE.classes, vehicle.class) then
							for _, trim in vehicle.trims do
								local byClass = contains(RIDESHARE.xlClasses, vehicle.class)
								local expected = byClass or trim.seats >= minSeats
								t.expect(Rideshare.isXL(RIDESHARE, vehicle.class, trim.seats)).toBe(expected)
								if expected and not byClass then
									bySeats += 1
								end
							end
						end
					end
					t.expect(bySeats).toBeGreaterThan(0) -- the seat rule matters in the real catalog
					local sedan = Catalog.getTrim(SEDAN.vehicleId, SEDAN.trim)
					local sedanClass = Catalog.getVehicle(SEDAN.vehicleId)
					t.expect(sedan ~= nil and sedanClass ~= nil).toBe(true)
					if sedan and sedanClass then
						t.expect(Rideshare.isXL(RIDESHARE, sedanClass.class, sedan.seats)).toBe(false)
					end
				end
			)
		end)

		t.describe("XP per job", function()
			t.it("gives a job of the reference length exactly its xp", function()
				for _, def in { RIDESHARE, DELIVERY } do
					t.expect(JobService.xpFor(def, def.xpReferenceStuds)).toBe(def.xp)
				end
			end)

			t.it("scales with the paid length, within xpScale", function()
				local def = RIDESHARE
				local shortest = math.floor(def.xp * Jobs.xpScale.min + 0.5)
				local longest = math.floor(def.xp * Jobs.xpScale.max + 0.5)
				t.expect(JobService.xpFor(def, 0)).toBe(shortest)
				t.expect(JobService.xpFor(def, def.xpReferenceStuds * 100)).toBe(longest)
				local double = JobService.xpFor(def, def.xpReferenceStuds * 2)
				t.expect(double).toBe(math.min(def.xp * 2, longest))
			end)

			t.it("is always a whole number", function()
				for _, studs in { 1, 777, 1234.5, 3999 } do
					local xp = JobService.xpFor(DELIVERY, studs)
					t.expect(xp % 1).toBe(0)
				end
			end)
		end)
	end)
end
