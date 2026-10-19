--!strict
-- AntiExploit's motion and strike rules (PLAN.md Phase 1; acceptance: a forged 500-stud teleport is caught).
-- Pure logic: runs in Edit mode.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local AntiExploit = require(ReplicatedStorage.Shared.Config.AntiExploit)
local Catalog = require(ReplicatedStorage.Shared.Vehicle.Catalog)
local Harness = require(ReplicatedStorage.Shared.Testing.Harness)
local Units = require(ReplicatedStorage.Shared.Util.Units)
local MotionGuard = require(ServerScriptService.Server.Services.AntiExploitService.MotionGuard)

local function topSpeedOf(vehicleId: string, trimId: string): number
	local trim = Catalog.getTrim(vehicleId, trimId)
	assert(trim, `{vehicleId}/{trimId} is in the catalog`)
	return Units.mphToStuds(trim.topSpeedMph)
end

-- The fastest top speed (studs/s) of any car a player can drive.
local function fastestTopSpeed(): number
	local fastest = 0
	for _, vehicleId in Catalog.vehicleIds() do
		local vehicle = Catalog.getVehicle(vehicleId)
		if vehicle ~= nil and vehicle.playerDrivable then
			for _, trim in vehicle.trims do
				fastest = math.max(fastest, trim.topSpeedMph)
			end
		end
	end
	return Units.mphToStuds(fastest)
end

return function(t: Harness.Api)
	local step = AntiExploit.sampleInterval
	local sparkTop = topSpeedOf("ohm_spark", "standard")
	local spark = MotionGuard.limits(sparkTop, AntiExploit)
	local arc = MotionGuard.limits(topSpeedOf("ohm_arc", "boost"), AntiExploit)
	local origin = Vector3.new(120, 8, -60)
	local diagonal = Vector3.new(1, 0, 1).Unit

	t.describe("MotionGuard.check", function()
		t.it("lets normal driving through", function()
			for _, fraction in { 0, 0.25, 0.5, 0.9, 1, 1.1 } do
				local verdict = MotionGuard.check(origin, origin + diagonal * sparkTop * fraction * step, step, spark)
				t.expect(verdict).toBe("ok")
			end
		end)

		t.it("lets a car round a curve at top speed for many samples", function()
			local radius = 300
			local turn = sparkTop * step / radius -- radians per sample at top speed
			local credit = 0
			local previous = origin + Vector3.new(radius, 0, 0)
			for index = 1, 40 do
				local angle = turn * index
				local current = origin + Vector3.new(radius * math.cos(angle), 0, radius * math.sin(angle))
				local verdict, measured = MotionGuard.check(previous, current, step, spark, credit)
				t.expect(verdict).toBe("ok")
				credit = measured.credit
				previous = current
			end
		end)

		t.it("catches 1.3x top speed as speed", function()
			local verdict = MotionGuard.check(origin, origin + diagonal * sparkTop * 1.3 * step, step, spark)
			t.expect(verdict).toBe("speed")
		end)

		t.it("catches a car holding 1.3x top speed within 10 samples, even with full catch-up credit", function()
			local credit = spark.maxCredit
			local position = origin
			local caughtAt: number? = nil
			for index = 1, 20 do
				local nextPosition = position + Vector3.xAxis * sparkTop * 1.3 * step
				local verdict, measured = MotionGuard.check(position, nextPosition, step, spark, credit)
				if verdict ~= "ok" then
					t.expect(verdict).toBe("speed")
					caughtAt = index
					break
				end
				credit = measured.credit
				position = nextPosition
			end
			t.expect(caughtAt ~= nil).toBe(true)
			t.expect(caughtAt or math.huge).toBeLessThan(11)
		end)

		t.it("lets the server's view catch up after a stalled sample", function()
			local cruise = sparkTop * 0.9 * step -- studs per sample
			-- One normal sample, one where the car seems to stand still, then one covering both samples.
			local verdict1, measured1 = MotionGuard.check(origin, origin + Vector3.xAxis * cruise, step, spark)
			local stalled = origin + Vector3.xAxis * cruise
			local verdict2, measured2 = MotionGuard.check(stalled, stalled, step, spark, measured1.credit)
			local verdict3 =
				MotionGuard.check(stalled, stalled + Vector3.xAxis * cruise * 2, step, spark, measured2.credit)
			t.expect(verdict1).toBe("ok")
			t.expect(verdict2).toBe("ok")
			t.expect(verdict3).toBe("ok")
		end)

		t.it("catches 500 studs in one sample as a teleport, even for the fastest car with full credit", function()
			local jump = origin + Vector3.new(500, 0, 0)
			t.expect((MotionGuard.check(origin, jump, step, spark))).toBe("teleport")
			t.expect((MotionGuard.check(origin, jump, step, arc, arc.maxCredit))).toBe("teleport")
		end)

		t.it("lets a long fall through", function()
			local gravity = Workspace.Gravity
			local drift = Vector3.xAxis * sparkTop * 0.3 -- rolling off a cliff edge
			local credit = 0
			local previous = origin
			for index = 1, 16 do -- 8 seconds of free fall, hundreds of studs per sample by the end
				local elapsed = index * step
				local current = origin + drift * elapsed - Vector3.yAxis * (0.5 * gravity * elapsed * elapsed)
				local verdict, measured = MotionGuard.check(previous, current, step, spark, credit)
				t.expect(verdict).toBe("ok")
				credit = measured.credit
				previous = current
			end
			t.expect((MotionGuard.check(origin, origin - Vector3.yAxis * 2000, step, spark))).toBe("ok")
		end)

		t.it("lets a car launch off a ramp at top speed", function()
			local launch = Vector3.new(0.8, 0.6, 0) * sparkTop * step -- 37 degrees up at top speed
			t.expect((MotionGuard.check(origin, origin + launch, step, spark))).toBe("ok")
		end)

		t.it("catches a car climbing faster than it could drive", function()
			local climb = Vector3.yAxis * spark.maxRiseSpeed * 1.2 * step
			t.expect((MotionGuard.check(origin, origin + climb, step, spark))).toBe("speed")
		end)

		t.it("catches 500 studs straight up in one sample as a teleport", function()
			t.expect((MotionGuard.check(origin, origin + Vector3.yAxis * 500, step, spark))).toBe("teleport")
		end)

		t.it("doesn't call a legal move over a long server hitch a teleport", function()
			local hitch = 3 -- seconds between samples
			local moved = origin + Vector3.xAxis * sparkTop * hitch -- top speed for the whole hitch
			t.expect((MotionGuard.check(origin, moved, hitch, spark))).toBe("ok")
		end)

		t.it("treats a NaN or infinite position as a teleport", function()
			t.expect((MotionGuard.check(origin, Vector3.new(0 / 0, 0, 0), step, spark))).toBe("teleport")
			t.expect((MotionGuard.check(origin, Vector3.new(math.huge, 0, 0), step, spark))).toBe("teleport")
		end)

		t.it("reports what it measured", function()
			local _, measured = MotionGuard.check(origin, origin + Vector3.new(30, -5, 40), step, spark)
			t.expect(measured.horizontal).toBeNear(50, 1e-6)
			t.expect(measured.horizontalSpeed).toBeNear(50 / step, 1e-6)
			t.expect(measured.rise).toBe(0)
		end)
	end)

	t.describe("MotionGuard.checkSettling", function()
		t.it("catches a 500-stud move 0.5 s after the car was tracked or reset", function()
			local jump = origin + Vector3.new(500, 0, 0)
			t.expect((MotionGuard.checkSettling(origin, jump, step, spark))).toBe("teleport")
			t.expect((MotionGuard.checkSettling(origin, jump, step, arc))).toBe("teleport")
		end)

		t.it("catches a far jump at any point in the settling period", function()
			local far = origin + Vector3.new(5000, 0, 0)
			local elapsed = step
			while elapsed <= AntiExploit.graceSeconds + 1e-9 do
				t.expect((MotionGuard.checkSettling(origin, far, elapsed, arc))).toBe("teleport")
				elapsed += step
			end
		end)

		t.it("hands a reset car back to its driver before the settling period ends", function()
			t.expect(AntiExploit.resetOwnershipDelay).toBeGreaterThan(0)
			t.expect(AntiExploit.resetOwnershipDelay).toBeLessThan(AntiExploit.graceSeconds)
		end)

		t.it("never judges speed while settling", function()
			local fast = origin + Vector3.xAxis * spark.maxHorizontalSpeed * 1.5 * step
			t.expect((MotionGuard.check(origin, fast, step, spark))).toBe("speed")
			t.expect((MotionGuard.checkSettling(origin, fast, step, spark))).toBe("ok")
		end)
	end)

	t.describe("MotionGuard.limits", function()
		t.it("caps speed at top speed x 1.15 (PLAN.md Phase 1)", function()
			t.expect(AntiExploit.speedTolerance).toBe(1.15)
			t.expect(spark.maxHorizontalSpeed).toBeNear(sparkTop * 1.15, 1e-6)
		end)

		t.it("keeps the teleport distance above the fastest car's legal travel in one sample", function()
			local cap = fastestTopSpeed() * AntiExploit.speedTolerance
			local legal = cap * (AntiExploit.sampleInterval + AntiExploit.catchUpSeconds)
			t.expect(AntiExploit.teleportDistance).toBeGreaterThan(legal)
			t.expect(AntiExploit.teleportDistance).toBeLessThan(500) -- the PLAN.md forged teleport stays a teleport
		end)
	end)

	t.describe("MotionGuard strikes", function()
		t.it("forgives one strike per full decay period", function()
			t.expect(MotionGuard.decayedStrikes(3, 0, 60)).toBe(3)
			t.expect(MotionGuard.decayedStrikes(3, 59, 60)).toBe(3)
			t.expect(MotionGuard.decayedStrikes(3, 60, 60)).toBe(2)
			t.expect(MotionGuard.decayedStrikes(3, 1000, 60)).toBe(0)
		end)

		t.it("resets on the first offense, logs repeats, then kicks", function()
			local toLog, toKick = AntiExploit.strikesToLog, AntiExploit.strikesToKick
			t.expect(toLog).toBeGreaterThan(1)
			t.expect(toKick).toBeGreaterThan(toLog)
			t.expect(MotionGuard.response(1, toLog, toKick)).toBe("reset")
			t.expect(MotionGuard.response(toLog, toLog, toKick)).toBe("log")
			t.expect(MotionGuard.response(toKick, toLog, toKick)).toBe("kick")
		end)
	end)
end
