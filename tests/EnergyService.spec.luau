--!strict
-- EnergyService's decisions (docs/phase-5-contracts.md "Server"): how a sampled car moved, whether it stands on a
-- station pad, charging steps with their per-percent bills, the low-energy alerts, limp mode, the plaza hangout
-- bonus and the nearest station by road. Pure logic: runs in Edit mode.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Energy = require(ReplicatedStorage.Shared.Vehicle.Energy)
local EnergyConfig = require(ReplicatedStorage.Shared.Config.Energy)
local Harness = require(ReplicatedStorage.Shared.Testing.Harness)
local Units = require(ReplicatedStorage.Shared.Util.Units)
local Rules = require(ServerScriptService.Server.Services.EnergyService.Rules)

type MotionSample = Rules.MotionSample

local WINDOW = 0.5 -- seconds of motion the ground-speed check looks back over
local MAX_SPEED = 200 -- studs/s
local AGREEMENT = 8 -- studs/s: velocity counts while within this of the ground speed
local CATCH_UP = 5 -- seconds: the longest stall a catch-up is spread over
local STILL = 0.05 -- studs: moved less than this counts as not moved
local DT = 0.25 -- seconds between samples
-- Vector3 components are 32-bit floats: positions far from the origin carry a little rounding.
local FLOAT_TOLERANCE = 1e-3
local PERCENT = 100
local LEVELS: Rules.AlertLevels = { warning = 0.2, critical = 0.1, rearmEmpty = 0.02 }

-- Samples of a car moving along +X at `speed` studs/s (velocity reporting `reported`, default the true speed),
-- climbing `climb` studs/s, one every DT from t = 0.
local function track(count: number, speed: number, climb: number?, reported: number?): { MotionSample }
	local samples: { MotionSample } = {}
	for index = 0, count - 1 do
		local t = index * DT
		table.insert(samples, {
			t = t,
			position = Vector3.new(1000 + speed * t, 10 + (climb or 0) * t, -500),
			velocitySpeed = if reported ~= nil then reported else speed,
		})
	end
	return samples
end

-- Measures every sample in turn the way EnergyService does (keeping its history, its ground speeds and when
-- the car last moved) and returns every sample's motion; the last one is the newest. `serverMovedAt` is when the
-- server last moved the car itself, if it did.
local function measureAll(samples: { MotionSample }, serverMovedAt: number?): { Rules.Motion }
	local history: { MotionSample } = {}
	local movedAt = samples[1].t
	local motions: { Rules.Motion } = {}
	for _, sample in samples do
		local current: MotionSample = table.clone(sample)
		local previous = history[#history]
		local motion = Rules.measure(history, current, {
			window = WINDOW,
			maxSpeed = MAX_SPEED,
			agreement = AGREEMENT,
			movedAt = movedAt,
			catchUpSeconds = CATCH_UP,
			serverMovedAt = serverMovedAt,
		})
		if motion.restart or previous == nil or (current.position - previous.position).Magnitude > STILL then
			movedAt = current.t
		end
		if motion.restart then
			table.clear(history)
		end
		if not motion.jumped then
			current.groundSpeed = motion.groundSpeed
		end
		table.insert(history, current)
		while #history > 2 and current.t - history[2].t >= WINDOW do
			table.remove(history, 1)
		end
		table.insert(motions, motion)
	end
	return motions
end

-- The newest sample's motion.
local function measureLast(samples: { MotionSample }, serverMovedAt: number?): Rules.Motion
	local motions = measureAll(samples, serverMovedAt)
	return motions[#motions]
end

-- Charges from `from` to `to` (or full) at `kind` with `attributes` in steps of DT, the way EnergyService does.
-- Returns the seconds it took and the whole dollars billed.
local function chargeRun(
	kind: Energy.StationKind,
	attributes: { [string]: any },
	vehicleId: string,
	trim: string,
	from: number,
	to: number
): (number, number)
	local level, owed, billed, seconds = from, 0, 0, 0
	local cost = Energy.costPerFraction(kind)
	while level < to - 1e-9 and seconds < 600 do
		local rate = Energy.chargeRatePerSecond(kind, attributes, vehicleId, trim, level)
		local step = Rules.chargeStep(level, rate, DT, cost, owed)
		level, owed = step.level, step.owed
		billed += step.bill
		seconds += DT
		if step.full then
			break
		end
	end
	return seconds, billed
end

return function(t: Harness.Api)
	t.describe("EnergyService.measure", function()
		t.it("drains nothing on the first sample", function()
			local motion = measureLast(track(1, 50))
			t.expect(motion.jumped).toBe(true)
			t.expect(motion.speed).toBe(0)
		end)

		t.it("reads a steady speed with no acceleration or climb", function()
			local motion = measureLast(track(6, 60))
			t.expect(motion.jumped).toBe(false)
			t.expect(motion.speed).toBeNear(60, FLOAT_TOLERANCE * 60)
			t.expect(motion.accel).toBeNear(0, FLOAT_TOLERANCE)
			t.expect(motion.climb).toBeNear(0, FLOAT_TOLERANCE)
		end)

		t.it("reads climbing from the height gained over the window", function()
			local motion = measureLast(track(6, 60, 4))
			t.expect(motion.climb).toBeNear(4, 0.01)
			local descent = measureLast(track(6, 60, -3))
			t.expect(descent.climb).toBeNear(-3, 0.01)
		end)

		t.it("reads acceleration from the change in velocity while it matches the ground covered", function()
			local samples = track(3, 40)
			samples[3].velocitySpeed = 45 -- 5 studs/s faster over one DT
			local motion = measureLast(samples)
			t.expect(motion.accel).toBeNear(5 / DT, FLOAT_TOLERANCE)
			t.expect(motion.speed).toBe(45)
			samples[3].velocitySpeed = 34
			t.expect(measureLast(samples).accel).toBeNear(-6 / DT, FLOAT_TOLERANCE)
			t.expect(measureLast(samples).seconds).toBeNear(DT, 1e-9)
		end)

		t.it("pays for the ground covered even when the reported velocity is low", function()
			local motion = measureLast(track(6, 80, 0, 0))
			t.expect(motion.speed).toBeNear(80, 0.05)
		end)

		t.it("ignores a reported velocity the car isn't doing", function()
			local motion = measureLast(track(6, 40, 0, 120))
			t.expect(motion.speed).toBeNear(40, 0.05)
			t.expect(motion.accel).toBeNear(0, 0.05)
		end)

		t.it("earns no regen from a velocity that keeps falling while the car holds its speed", function()
			local samples = track(24, 60)
			for index, sample in samples do
				sample.velocitySpeed = 60 - 2 * (index - 1) -- falling 8 studs/s² while the car really holds 60
			end
			local motions = measureAll(samples)
			local credited = 0
			for _, motion in motions do
				if not motion.jumped and motion.accel < 0 then
					credited += -motion.accel * motion.seconds
				end
			end
			-- The velocity is believed only while it is within AGREEMENT of the ground speed: no more than that
			-- much slowing down can be claimed, however long it keeps falling.
			t.expect(credited <= AGREEMENT + 2 + FLOAT_TOLERANCE).toBe(true)
			local last = motions[#motions]
			t.expect(last.speed).toBeNear(60, 0.05)
			t.expect(last.accel).toBeNear(0, 0.05)
		end)

		t.it("caps the speed at the car's limit and bills the whole distance", function()
			local motion = measureLast(track(3, 400))
			t.expect(motion.jumped).toBe(false)
			t.expect(motion.speed).toBe(MAX_SPEED)
			-- 100 studs a sample at most 200 studs/s: billed for half a second of driving at the cap.
			t.expect(motion.seconds).toBeNear(100 / MAX_SPEED, 1e-9)
		end)

		t.it("bills a catch-up after a stall as the travel it is", function()
			-- 60 studs/s for three samples, then the server's view stalls for 2 s (velocity 0), then catches up.
			local samples = track(3, 60)
			local stalled = samples[3].position
			for index = 1, 8 do
				table.insert(samples, { t = samples[3].t + index * DT, position = stalled, velocitySpeed = 0 })
			end
			local resumeAt = samples[3].t + 9 * DT
			local caughtUp = stalled + Vector3.new(60 * (resumeAt - samples[3].t), 0, 0)
			table.insert(samples, { t = resumeAt, position = caughtUp, velocitySpeed = 60 })
			local motion = measureLast(samples)
			t.expect(motion.jumped).toBe(false)
			t.expect(motion.restart).toBe(true)
			t.expect(motion.seconds).toBeNear(9 * DT, 1e-6)
			t.expect(motion.speed).toBeNear(60, FLOAT_TOLERANCE * 60)
		end)

		t.it("drains nothing for a move the server made", function()
			local samples = track(3, 60)
			samples[3].position += Vector3.new(500, 0, 0)
			local moved = measureLast(samples, samples[2].t + DT / 2)
			t.expect(moved.jumped).toBe(true)
			t.expect(moved.speed).toBe(0)
			-- An older server move doesn't excuse a new jump: it is billed as travel.
			local forged = measureLast(samples, samples[1].t - DT)
			t.expect(forged.jumped).toBe(false)
			t.expect(forged.speed * forged.seconds).toBeNear(500 + 60 * DT, 1)
		end)

		t.it("treats a sample with no time since the last as no driving", function()
			local samples = track(2, 60)
			samples[2].t = samples[1].t
			t.expect(measureLast(samples).jumped).toBe(true)
		end)

		t.it("averages within 2 % of the catalog drain over noisy samples at a steady cruise", function()
			local cruise = Units.mphToStuds(EnergyConfig.cruiseMph)
			local random = Random.new(5)
			for _, car in { { "ohm_spark", "standard" }, { "halden_fernlow", "standard" } } do
				local vehicleId, trimId = car[1], car[2]
				local samples: { MotionSample } = {}
				for index = 0, 799 do
					local at = index * DT + random:NextNumber(0, 1 / 60) -- samples land a little late
					-- Positions arrive up to a 60th of a second old; the velocity wobbles a little.
					local age = random:NextNumber(0, 1 / 60)
					table.insert(samples, {
						t = at,
						position = Vector3.new(1000 + cruise * (at - age), 10, -500),
						velocitySpeed = cruise + random:NextNumber(-0.3, 0.3),
					})
				end
				local drained, seconds = 0, 0
				for _, motion in measureAll(samples) do
					if not motion.jumped then
						local perSecond =
							Energy.drainPerSecond(vehicleId, trimId, motion.speed, motion.accel, motion.climb)
						drained += perSecond * motion.seconds
						seconds += motion.seconds
					end
				end
				local expected = Energy.drainPerSecond(vehicleId, trimId, cruise, 0, 0)
				t.expect(drained / seconds).toBeNear(expected, expected * 0.02)
			end
		end)
	end)

	t.describe("EnergyService.insideFootprint", function()
		local size = Vector3.new(12, 1, 20) -- a stall: 12 across, 20 deep
		local HEIGHT_ABOVE = 5

		t.it("matches a chassis over the pad and not one beside it", function()
			local pad = CFrame.new(335, 0.5, 265)
			t.expect(Rules.insideFootprint(pad, size, Vector3.new(335, 3, 265), HEIGHT_ABOVE)).toBe(true)
			t.expect(Rules.insideFootprint(pad, size, Vector3.new(340.9, 3, 274.9), HEIGHT_ABOVE)).toBe(true)
			t.expect(Rules.insideFootprint(pad, size, Vector3.new(341.5, 3, 265), HEIGHT_ABOVE)).toBe(false)
			t.expect(Rules.insideFootprint(pad, size, Vector3.new(335, 3, 275.5), HEIGHT_ABOVE)).toBe(false)
		end)

		t.it("follows the pad's yaw", function()
			-- Turned 90 degrees: the 20-stud depth now runs along X.
			local pad = CFrame.new(1115, 0.5, 2075) * CFrame.Angles(0, math.rad(90), 0)
			t.expect(Rules.insideFootprint(pad, size, Vector3.new(1124, 3, 2075), HEIGHT_ABOVE)).toBe(true)
			t.expect(Rules.insideFootprint(pad, size, Vector3.new(1115, 3, 2084), HEIGHT_ABOVE)).toBe(false)
		end)

		t.it("ignores a car far above or below the pad", function()
			local pad = CFrame.new(0, 0.5, 0)
			t.expect(Rules.insideFootprint(pad, size, Vector3.new(0, 0.5 + 0.5 + HEIGHT_ABOVE, 0), HEIGHT_ABOVE))
				.toBe(true)
			t.expect(Rules.insideFootprint(pad, size, Vector3.new(0, 30, 0), HEIGHT_ABOVE)).toBe(false)
			t.expect(Rules.insideFootprint(pad, size, Vector3.new(0, -5, 0), HEIGHT_ABOVE)).toBe(false)
		end)
	end)

	t.describe("EnergyService.chargeStep", function()
		t.it("bills the energy added", function()
			-- $300 a full charge = $3 a percent; 0.105 -> 0.135 adds 3 %.
			local step = Rules.chargeStep(0.105, 0.03, 1, 300, 0)
			t.expect(step.level).toBeNear(0.135, 1e-9)
			t.expect(step.bill).toBe(9)
			t.expect(step.owed).toBeNear(0, 1e-9)
			t.expect(step.full).toBe(false)
			t.expect(step.short).toBe(false)
		end)

		t.it("bills nothing until a whole dollar is due, and carries the cents", function()
			local step = Rules.chargeStep(0.101, 0.001, 1, 300, 0)
			t.expect(step.bill).toBe(0)
			t.expect(step.owed).toBeNear(0.3, 1e-9)
			t.expect(step.level).toBeNear(0.102, 1e-9)
		end)

		t.it("charges a sliver of a top-up cents, and never starts a stop over one", function()
			-- A car left on a pad after a full charge: the idle drain took a hair off.
			local level = 1 - 1e-5
			local step = Rules.chargeStep(level, 0.01, DT, 300, 0)
			t.expect(step.bill).toBe(0)
			t.expect(step.full).toBe(true)
			t.expect(Rules.canStartCharging(level, EnergyConfig.charging.startBelow)).toBe(false)
			t.expect(Rules.canStartCharging(0.98, EnergyConfig.charging.startBelow)).toBe(true)
			t.expect(EnergyConfig.charging.startBelow <= 0.99).toBe(true) -- at least a whole % missing
		end)

		t.it("adds only what the player's cash pays for", function()
			-- A pump at $4 a percent, 2 % this step ($8), with $5: 1.25 % for $5, then it stops.
			local step = Rules.chargeStep(0.5, 0.04, 0.5, 400, 0, 5)
			t.expect(step.short).toBe(true)
			t.expect(step.bill).toBe(5)
			t.expect(step.level).toBeNear(0.5125, 1e-9)
			-- With enough cash the whole step goes through.
			local paid = Rules.chargeStep(0.5, 0.04, 0.5, 400, 0, 8)
			t.expect(paid.short).toBe(false)
			t.expect(paid.bill).toBe(8)
			-- With nothing to spend, nothing is added.
			local broke = Rules.chargeStep(0.5, 0.04, 0.5, 400, 0.5, 0)
			t.expect(broke.short).toBe(true)
			t.expect(broke.bill).toBe(0)
			t.expect(broke.level).toBe(0.5)
		end)

		t.it("carries cents into later steps when a percent costs less than a dollar", function()
			-- $50 a full tank = $0.50 a percent: a dollar every two percents.
			local first = Rules.chargeStep(0.10, 0.01, 1, 50, 0)
			t.expect(first.bill).toBe(0)
			t.expect(first.owed).toBeNear(0.5, 1e-9)
			local second = Rules.chargeStep(first.level, 0.01, 1, 50, first.owed)
			t.expect(second.bill).toBe(1)
			t.expect(second.owed).toBeNear(0, 1e-9)
		end)

		t.it("stops at full", function()
			local step = Rules.chargeStep(0.995, 0.05, 1, 300, 0)
			t.expect(step.level).toBe(1)
			t.expect(step.full).toBe(true)
			t.expect(step.bill).toBe(1) -- only the last half percent ($1.50): $1 now, 50 cents carried
			t.expect(step.owed).toBeNear(0.5, 1e-9)
		end)

		t.it("adds nothing at a zero rate or with no time", function()
			t.expect(Rules.chargeStep(0.5, 0, 1, 300, 0).level).toBe(0.5)
			t.expect(Rules.chargeStep(0.5, 0.01, 0, 300, 0).level).toBe(0.5)
			t.expect(Rules.chargeStep(0.5, -1, 1, 300, 0).level).toBe(0.5)
		end)

		t.it("charges 10 -> 80 % at the fastest stall within the PLAN.md time for the configured cost", function()
			local seconds, billed = chargeRun("ChargerStall", { kW = 350 }, "ohm_spark", "standard", 0.1, 0.8)
			t.expect(seconds >= 60 - DT and seconds <= 90 + DT).toBe(true)
			local expected = 70 * Energy.costPerFraction("ChargerStall") / PERCENT
			t.expect(billed).toBeNear(expected, Energy.costPerFraction("ChargerStall") / PERCENT)
		end)

		t.it("fuels 10 -> 100 % at a pump within the PLAN.md time for the configured cost", function()
			local seconds, billed = chargeRun("FuelPump", { rate = 4 }, "halden_fernlow", "standard", 0.1, 1)
			t.expect(seconds >= 20 - DT and seconds <= 30 + DT).toBe(true)
			local expected = 90 * Energy.costPerFraction("FuelPump") / PERCENT
			t.expect(billed).toBeNear(expected, Energy.costPerFraction("FuelPump") / PERCENT)
		end)
	end)

	t.describe("EnergyService alerts and limp mode", function()
		t.it("warns at 20 % and 10 % once per drop", function()
			local state = Rules.newAlerts()
			t.expect(Rules.updateAlerts(state, 0.5, LEVELS)).toBe(nil)
			t.expect(Rules.updateAlerts(state, 0.2, LEVELS)).toBe("warning")
			t.expect(Rules.updateAlerts(state, 0.15, LEVELS)).toBe(nil)
			t.expect(Rules.updateAlerts(state, 0.1, LEVELS)).toBe("critical")
			t.expect(Rules.updateAlerts(state, 0.05, LEVELS)).toBe(nil)
			t.expect(Rules.updateAlerts(state, 0, LEVELS)).toBe("empty")
			t.expect(Rules.updateAlerts(state, 0, LEVELS)).toBe(nil)
		end)

		t.it("says only the most severe alert a big drop reaches", function()
			local state = Rules.newAlerts()
			t.expect(Rules.updateAlerts(state, 0.05, LEVELS)).toBe("critical")
			t.expect(Rules.updateAlerts(state, 0.15, LEVELS)).toBe(nil) -- warning was used up by that drop
			local empty = Rules.newAlerts()
			t.expect(Rules.updateAlerts(empty, 0, LEVELS)).toBe("empty")
			t.expect(Rules.updateAlerts(empty, 0.05, LEVELS)).toBe(nil)
		end)

		t.it("re-arms each alert once the level climbs back above it", function()
			local state = Rules.newAlerts()
			Rules.updateAlerts(state, 0, LEVELS)
			t.expect(Rules.updateAlerts(state, 0.01, LEVELS)).toBe(nil) -- a sliver of charge: still used up
			t.expect(Rules.updateAlerts(state, 0, LEVELS)).toBe(nil)
			t.expect(Rules.updateAlerts(state, 0.5, LEVELS)).toBe(nil) -- charged up: everything re-arms
			t.expect(Rules.updateAlerts(state, 0.19, LEVELS)).toBe("warning")
			t.expect(Rules.updateAlerts(state, 0.09, LEVELS)).toBe("critical")
			t.expect(Rules.updateAlerts(state, 0.12, LEVELS)).toBe(nil)
			t.expect(Rules.updateAlerts(state, 0.1, LEVELS)).toBe("critical") -- back below after rising above
			t.expect(Rules.updateAlerts(state, 0, LEVELS)).toBe("empty")
		end)

		t.it("uses the configured alert levels", function()
			t.expect(EnergyConfig.warningLevel).toBe(0.2)
			t.expect(EnergyConfig.criticalLevel).toBe(0.1)
			t.expect(EnergyConfig.limpClearLevel > 0 and EnergyConfig.limpClearLevel < EnergyConfig.criticalLevel)
				.toBe(true)
		end)

		t.it("starts limp mode at 0 and clears it only above the clear level", function()
			local clear = EnergyConfig.limpClearLevel
			t.expect(Rules.limpNext(false, 0.5, clear)).toBe(false)
			t.expect(Rules.limpNext(false, 0, clear)).toBe(true)
			t.expect(Rules.limpNext(true, clear / 2, clear)).toBe(true)
			t.expect(Rules.limpNext(false, clear / 2, clear)).toBe(false)
			t.expect(Rules.limpNext(true, clear, clear)).toBe(true)
			t.expect(Rules.limpNext(true, clear + 0.001, clear)).toBe(false)
		end)

		t.it("judges a limping car by the limp speed once it has slowed, or once its time to slow is up", function()
			local cap, grace = 30, EnergyConfig.limpCapGraceSeconds
			t.expect(Rules.limpCapDue(25, cap, 10, 10.5, grace)).toBe(true) -- already slow
			t.expect(Rules.limpCapDue(80, cap, 10, 10 + grace / 2, grace)).toBe(false) -- still slowing down
			t.expect(Rules.limpCapDue(80, cap, 10, 10 + grace, grace)).toBe(true) -- ignored limp mode
			t.expect(grace > 0 and grace <= 10).toBe(true)
		end)

		t.it("limps slower than any car drives", function()
			t.expect(Units.mphToStuds(EnergyConfig.limpMph) > 0).toBe(true)
			t.expect(EnergyConfig.limpMph).toBe(15)
		end)

		t.it("rounds levels for the attribute and the save", function()
			t.expect(Rules.roundLevel(0.12345, 0.001)).toBeNear(0.123, 1e-9)
			t.expect(Rules.roundLevel(0.9996, 0.001)).toBe(1)
			t.expect(Rules.roundLevel(-0.2, 0.001)).toBe(0)
			t.expect(Rules.roundLevel(1.4, 0.001)).toBe(1)
			t.expect(Rules.roundLevel(0 / 0, 0.001)).toBe(0)
		end)
	end)

	t.describe("EnergyService.hangoutPayees", function()
		t.it("pays everyone charging at a plaza with enough players", function()
			local payees = Rules.hangoutPayees({ a = "cedar", b = "cedar", c = "cedar" }, 3)
			t.expect(payees).toEqual({ a = "cedar", b = "cedar", c = "cedar" })
		end)

		t.it("pays nobody at a plaza with too few players", function()
			local payees = Rules.hangoutPayees({ a = "cedar", b = "cedar", c = "loop" }, 3)
			t.expect(payees).toEqual({})
		end)

		t.it("counts plazas separately", function()
			local charging = { a = "cedar", b = "cedar", c = "cedar", d = "loop", e = "loop" }
			t.expect(Rules.hangoutPayees(charging, 3)).toEqual({ a = "cedar", b = "cedar", c = "cedar" })
		end)

		t.it("uses the configured group size", function()
			t.expect(EnergyConfig.hangout.minPlayers).toBe(3)
		end)

		t.it("pays for the time spent charging together, not for being there at the payout", function()
			t.expect(Rules.hangoutPay(60, 50, 1)).toBe(50)
			t.expect(Rules.hangoutPay(30, 50, 2)).toBe(50)
			t.expect(Rules.hangoutPay(DT, 50, 1)).toBe(0) -- a quarter second at the tick earns nothing
			t.expect(Rules.hangoutPay(0, 50, 1)).toBe(0)
		end)
	end)

	t.describe("EnergyService.nearestStation", function()
		local candidates: { Rules.Candidate } = {
			{ id = "near_by_air", position = Vector3.new(100, 0, 0) },
			{ id = "near_by_road", position = Vector3.new(0, 0, 300) },
			{ id = "far", position = Vector3.new(2000, 0, 0) },
		}

		t.it("picks the station nearest by road, not in a straight line", function()
			local lengths = { [100] = 900, [0] = 350, [2000] = 2100 }
			local routed = 0
			local id, length = Rules.nearestStation(Vector3.zero, candidates, function(position: Vector3): number?
				routed += 1
				return lengths[position.X]
			end)
			t.expect(id).toBe("near_by_road")
			t.expect(length).toBe(350)
			t.expect(routed).toBe(2) -- the far one is farther in a straight line than 350 studs of road
		end)

		t.it("skips stations with no route", function()
			local id = Rules.nearestStation(Vector3.zero, candidates, function(position: Vector3): number?
				return if position.X == 2000 then 2100 else nil
			end)
			t.expect(id).toBe("far")
		end)

		t.it("falls back to the straight-line nearest when nothing has a route", function()
			local id, distance = Rules.nearestStation(Vector3.zero, candidates, function(): number?
				return nil
			end)
			t.expect(id).toBe("near_by_air")
			t.expect(distance).toBeNear(100, FLOAT_TOLERANCE)
		end)

		t.it("returns nil with no candidates", function()
			local id = Rules.nearestStation(Vector3.zero, {}, function(): number?
				return 1
			end)
			t.expect(id).toBe(nil)
		end)
	end)
end
