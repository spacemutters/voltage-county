--!strict
-- Drive-to-earn's per-minute decision (PLAN.md Phase 3; docs/phase-3-contracts.md "Drive-to-earn"): ordinary
-- driving on roads pays about $300 a minute, and parked cars, tight circles, off-road driving and teleport jumps
-- earn nothing. Pure logic: runs in Edit mode.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Catalog = require(ReplicatedStorage.Shared.Vehicle.Catalog)
local DriveEarn = require(ReplicatedStorage.Shared.Config.DriveEarn)
local Economy = require(ReplicatedStorage.Shared.Config.Economy)
local Harness = require(ReplicatedStorage.Shared.Testing.Harness)
local Units = require(ReplicatedStorage.Shared.Util.Units)
local Earnings = require(ServerScriptService.Server.Services.DriveEarnService.Earnings)

type Sample = Earnings.Sample

local MINUTE = 60
-- Vector3 components are 32-bit floats, so distances summed over a minute carry a little rounding.
local DISTANCE_TOLERANCE = 0.5 -- studs
local CASH_TOLERANCE = 2 -- dollars (rounding down plus float error)

-- The fastest a step may legally be for a trim (studs/s), as DriveEarnService works it out.
local function maxSpeedOf(vehicleId: string, trimId: string): number
	local trim = Catalog.getTrim(vehicleId, trimId)
	assert(trim, `{vehicleId}/{trimId} is in the catalog`)
	return Units.mphToStuds(trim.topSpeedMph) * DriveEarn.jumpSpeedTolerance
end

-- One sample per DriveEarn.sampleInterval from `from` to `to` seconds (inclusive), with positions from
-- `positionAt(t)` and on-road flags from `onRoadAt(t)` (default: always on a road).
local function track(
	from: number,
	to: number,
	positionAt: (t: number) -> Vector3,
	onRoadAt: ((t: number) -> boolean)?
): { Sample }
	local samples: { Sample } = {}
	local step = DriveEarn.sampleInterval
	for index = 0, math.floor((to - from) / step + 1e-9) do
		local t = from + index * step
		table.insert(samples, { t = t, position = positionAt(t), onRoad = if onRoadAt then onRoadAt(t) else true })
	end
	return samples
end

-- A straight run east from `origin` at `speed` studs/s.
local function straight(origin: Vector3, speed: number): (t: number) -> Vector3
	return function(t: number): Vector3
		return origin + Vector3.new(speed * t, 0, 0)
	end
end

-- Driving round a closed polyline (a town block loop) at `speed` studs/s, starting at its first point.
local function aroundPolyline(points: { Vector3 }, speed: number): (t: number) -> Vector3
	local lengths: { number } = {}
	local total = 0
	for index, point in points do
		local nextPoint = points[index % #points + 1]
		lengths[index] = (nextPoint - point).Magnitude
		total += lengths[index]
	end
	return function(t: number): Vector3
		local distance = (speed * t) % total
		for index, point in points do
			if distance <= lengths[index] then
				local nextPoint = points[index % #points + 1]
				return point:Lerp(nextPoint, distance / lengths[index])
			end
			distance -= lengths[index]
		end
		return points[1]
	end
end

-- Circling `centre` at `radius` studs and `speed` studs/s.
local function circling(centre: Vector3, radius: number, speed: number): (t: number) -> Vector3
	return function(t: number): Vector3
		local angle = speed * t / radius
		return centre + Vector3.new(radius * math.cos(angle), 0, radius * math.sin(angle))
	end
end

return function(t: Harness.Api)
	local sparkLimit = maxSpeedOf("ohm_spark", "standard")
	local arcLimit = maxSpeedOf("ohm_arc", "boost")
	local reference = Units.mphToStuds(DriveEarn.referenceMph) -- studs/s
	local origin = Vector3.new(-2400, 0, 50)
	local freeDrive = Economy.activities.freeDrive

	t.describe("Config/DriveEarn", function()
		t.it("is calibrated so a minute at the reference speed pays the §4 free-drive rate", function()
			t.expect(DriveEarn.cashPerStud * reference * MINUTE).toBeNear(freeDrive, 1e-6)
			t.expect(DriveEarn.capPerMinute).toBeNear(freeDrive * DriveEarn.capMultiple, 1e-6)
			t.expect(DriveEarn.capPerMinute).toBeGreaterThan(freeDrive)
		end)

		t.it("keeps the windows and limits consistent", function()
			t.expect(DriveEarn.payInterval >= DriveEarn.sampleInterval).toBe(true)
			t.expect(DriveEarn.afkWindow >= DriveEarn.payInterval).toBe(true)
			t.expect(DriveEarn.loopWindow >= DriveEarn.payInterval).toBe(true)
			-- The loop box is wider than the AFK distance: a car that moves but stays in a small area is loop farming.
			t.expect(DriveEarn.minBoundingBox).toBeGreaterThan(2 * DriveEarn.meaningfulDistance)
			t.expect(DriveEarn.jumpSpeedTolerance >= 1).toBe(true)
		end)
	end)

	t.describe("Earnings.decide: driving on roads", function()
		t.it("pays about $300 for a minute at 40 mph", function()
			local samples = track(0, MINUTE, straight(origin, reference))
			local decision = Earnings.decide(samples, MINUTE, sparkLimit, 1, DriveEarn, 0)
			t.expect(decision.reason).toBe("paid")
			t.expect(decision.distance).toBeNear(reference * MINUTE, DISTANCE_TOLERANCE)
			t.expect(decision.amount).toBeNear(freeDrive, CASH_TOLERANCE)
			t.expect(decision.amount % 1).toBe(0)
			t.expect(decision.capped).toBe(false)
		end)

		t.it("pays each minute once over two minutes of steady driving", function()
			local samples = track(0, 2 * MINUTE, straight(origin, reference))
			local first = Earnings.decide(samples, MINUTE, sparkLimit, 1, DriveEarn, 0)
			local second = Earnings.decide(samples, 2 * MINUTE, sparkLimit, 1, DriveEarn, MINUTE)
			t.expect(first.distance).toBeNear(reference * MINUTE, DISTANCE_TOLERANCE)
			t.expect(second.distance).toBeNear(reference * MINUTE, DISTANCE_TOLERANCE)
			t.expect(first.amount + second.amount).toBeNear(2 * freeDrive, 2 * CASH_TOLERANCE)
		end)

		t.it("pays round town blocks the same as a straight road", function()
			-- Round a 600 x 900 stud loop of streets at 40 mph: two minutes of this spans far more than the box.
			local loop = {
				Vector3.new(-300, 0, -450),
				Vector3.new(300, 0, -450),
				Vector3.new(300, 0, 450),
				Vector3.new(-300, 0, 450),
			}
			local samples = track(0, 2 * MINUTE, aroundPolyline(loop, reference))
			local decision = Earnings.decide(samples, 2 * MINUTE, sparkLimit, 1, DriveEarn, MINUTE)
			t.expect(decision.reason).toBe("paid")
			-- Cutting the corners between samples loses a little distance.
			t.expect(decision.amount).toBeGreaterThan(freeDrive * 0.97)
			t.expect(decision.amount).toBeLessThan(freeDrive + CASH_TOLERANCE)
		end)

		t.it("defaults the pay window to the last payInterval", function()
			local samples = track(0, 2 * MINUTE, straight(origin, reference))
			local explicit = Earnings.decide(samples, 2 * MINUTE, sparkLimit, 1, DriveEarn, MINUTE)
			local default = Earnings.decide(samples, 2 * MINUTE, sparkLimit, 1, DriveEarn)
			t.expect(default.amount).toBe(explicit.amount)
		end)
	end)

	t.describe("Earnings.decide: nothing for not driving", function()
		t.it("pays nothing for a car parked three minutes", function()
			local samples = track(0, 3 * MINUTE, function()
				return origin
			end)
			for minute = 1, 3 do
				local decision =
					Earnings.decide(samples, minute * MINUTE, sparkLimit, 1, DriveEarn, (minute - 1) * MINUTE)
				t.expect(decision.amount).toBe(0)
				t.expect(decision.reason).toBe("afk")
			end
		end)

		t.it("pays nothing for a parked car that gets nudged about", function()
			-- Rocking back and forth a few studs (bumped by others, rolling on a slope) is not driving.
			local samples = track(0, 2 * MINUTE, function(time: number)
				return origin + Vector3.new(3 * math.sin(time), 0, 2 * math.cos(time / 3))
			end)
			local decision = Earnings.decide(samples, 2 * MINUTE, sparkLimit, 1, DriveEarn, MINUTE)
			t.expect(decision.amount).toBe(0)
			t.expect(decision.reason).toBe("afk")
		end)

		t.it("pays nothing for two minutes of tight circles, even on pavement", function()
			-- 18-stud circles at 10 mph (the Studio circle test), counted as on a road: they cover real distance
			-- but never get far from where they started.
			local samples = track(0, 2 * MINUTE, circling(origin, 18, Units.mphToStuds(10)))
			t.expect(Earnings.roadDistance(samples, MINUTE, sparkLimit)).toBeGreaterThan(500)
			for minute = 1, 2 do
				local decision =
					Earnings.decide(samples, minute * MINUTE, sparkLimit, 1, DriveEarn, (minute - 1) * MINUTE)
				t.expect(decision.amount).toBe(0)
				t.expect(decision.reason).never.toBe("paid")
			end
		end)

		t.it("pays nothing for wider circles in a big lot (loop farming)", function()
			-- Circles that wander farther than the AFK distance are caught by the bounding box instead.
			for _, circle in { { radius = 30, mph = 15 }, { radius = 50, mph = 30 }, { radius = 100, mph = 40 } } do
				local samples = track(0, 2 * MINUTE, circling(origin, circle.radius, Units.mphToStuds(circle.mph)))
				t.expect(Earnings.roadDistance(samples, MINUTE, sparkLimit)).toBeGreaterThan(500)
				for minute = 1, 2 do
					local decision =
						Earnings.decide(samples, minute * MINUTE, sparkLimit, 1, DriveEarn, (minute - 1) * MINUTE)
					t.expect(decision.amount).toBe(0)
					t.expect(decision.reason).toBe("loop")
					t.expect(decision.moved).toBeGreaterThan(DriveEarn.meaningfulDistance)
					t.expect(decision.boundingBox).toBeLessThan(DriveEarn.minBoundingBox)
				end
			end
		end)

		t.it("pays nothing for circles on a road split by a teleport jump", function()
			-- One 2,000-stud jump inside the windows must not make the circles look spread out.
			local jumpAt = 90
			local jump = Vector3.new(2000, 0, 0)
			for _, circle in { { radius = 18, mph = 10 }, { radius = 30, mph = 15 } } do
				local path = circling(origin, circle.radius, Units.mphToStuds(circle.mph))
				local samples = track(0, 2 * MINUTE, function(time: number)
					local position = path(time)
					return if time >= jumpAt then position + jump else position
				end)
				local decision = Earnings.decide(samples, 2 * MINUTE, sparkLimit, 1, DriveEarn, MINUTE)
				t.expect(decision.amount).toBe(0)
				t.expect(decision.reason == "afk" or decision.reason == "loop").toBe(true)
				t.expect(decision.boundingBox).toBeLessThan(DriveEarn.minBoundingBox)
			end
		end)
	end)

	t.describe("Earnings.decide: what counts as distance", function()
		t.it("doesn't count distance off the road", function()
			local offRoad = track(0, MINUTE, straight(origin, reference), function()
				return false
			end)
			local decision = Earnings.decide(offRoad, MINUTE, sparkLimit, 1, DriveEarn, 0)
			t.expect(decision.distance).toBe(0)
			t.expect(decision.amount).toBe(0)
			t.expect(decision.reason).toBe("noRoad")

			-- On the road for the first half minute only: the steps with both ends on the road count.
			local halfway = MINUTE / 2
			local mixed = track(0, MINUTE, straight(origin, reference), function(time: number)
				return time <= halfway
			end)
			local half = Earnings.decide(mixed, MINUTE, sparkLimit, 1, DriveEarn, 0)
			t.expect(half.distance).toBeNear(reference * halfway, DISTANCE_TOLERANCE)
			t.expect(half.amount).toBeNear(freeDrive / 2, CASH_TOLERANCE)
		end)

		t.it("doesn't count a teleport jump", function()
			local jumpAt = MINUTE / 2
			local jump = Vector3.new(2000, 0, 0)
			local samples = track(0, MINUTE, function(time: number)
				local position = straight(origin, reference)(time)
				return if time >= jumpAt then position + jump else position
			end)
			local decision = Earnings.decide(samples, MINUTE, sparkLimit, 1, DriveEarn, 0)
			-- Every step but the jump: 59 seconds of driving.
			t.expect(decision.distance).toBeNear(reference * (MINUTE - 1), DISTANCE_TOLERANCE)
			t.expect(decision.amount).toBeNear(freeDrive * (MINUTE - 1) / MINUTE, CASH_TOLERANCE)
		end)

		t.it("counts steps up to the car's top speed with AntiExploit's headroom, and not beyond", function()
			local topSpeed = sparkLimit / DriveEarn.jumpSpeedTolerance
			local legal = track(0, MINUTE, straight(origin, topSpeed * 1.1))
			local tooFast = track(0, MINUTE, straight(origin, sparkLimit * 1.05))
			t.expect(Earnings.roadDistance(legal, 0, sparkLimit)).toBeNear(topSpeed * 1.1 * MINUTE, DISTANCE_TOLERANCE)
			t.expect(Earnings.roadDistance(tooFast, 0, sparkLimit)).toBe(0)
		end)
	end)

	t.describe("Earnings.decide: cap and multiplier", function()
		local hypercar = straight(origin, Units.mphToStuds(150))

		t.it("caps a minute at capPerMinute", function()
			local samples = track(0, MINUTE, hypercar)
			local decision = Earnings.decide(samples, MINUTE, arcLimit, 1, DriveEarn, 0)
			t.expect(decision.capped).toBe(true)
			t.expect(decision.gross).toBeGreaterThan(DriveEarn.capPerMinute)
			t.expect(decision.amount).toBe(math.floor(DriveEarn.capPerMinute))
		end)

		t.it("multiplies by the earnings multiplier after the cap, rounding down", function()
			local steady = track(0, MINUTE, straight(origin, reference))
			local base = Earnings.decide(steady, MINUTE, sparkLimit, 1, DriveEarn, 0)
			local doubled = Earnings.decide(steady, MINUTE, sparkLimit, 2, DriveEarn, 0)
			t.expect(doubled.amount).toBe(math.floor(base.gross * 2))
			t.expect(doubled.amount).toBeNear(2 * freeDrive, 2 * CASH_TOLERANCE)

			local fast = track(0, MINUTE, hypercar)
			local boosted = Earnings.decide(fast, MINUTE, arcLimit, 2, DriveEarn, 0)
			t.expect(boosted.amount).toBe(math.floor(DriveEarn.capPerMinute * 2))

			local odd = Earnings.decide(steady, MINUTE, sparkLimit, 1.37, DriveEarn, 0)
			t.expect(odd.amount).toBe(math.floor(base.gross * 1.37))
		end)

		t.it("pays a drive that ends between payouts for its share of the minute", function()
			-- Getting out after 30 s: the driving is paid, and the cap is half a minute's.
			local halfway = MINUTE / 2
			local steady = track(0, halfway, straight(origin, reference))
			local short = Earnings.decide(steady, halfway, sparkLimit, 1, DriveEarn, 0)
			t.expect(short.reason).toBe("paid")
			t.expect(short.amount).toBeNear(freeDrive / 2, CASH_TOLERANCE)

			local fast = track(0, halfway, hypercar)
			local capped = Earnings.decide(fast, halfway, arcLimit, 1, DriveEarn, 0)
			t.expect(capped.capped).toBe(true)
			t.expect(capped.amount).toBe(math.floor(Earnings.cap(DriveEarn, halfway)))
			t.expect(capped.amount).toBeLessThan(DriveEarn.capPerMinute)
		end)

		t.it("multiplies nothing into nothing", function()
			local parked = track(0, MINUTE, function()
				return origin
			end)
			t.expect(Earnings.decide(parked, MINUTE, sparkLimit, 3, DriveEarn, 0).amount).toBe(0)
		end)
	end)
end
