--!strict
-- The drag strip's pure rules (Config/DragStrip; docs/phase-10-contracts.md "Arc tuning, drag strip and
-- leaderboard"; PLAN.md Phase 10 acceptance "drag-strip timing is within ±0.05 s of the server clock"): the
-- gates sit on one straight strip at the drag distances, a crossing is interpolated inside one server frame to
-- well under a millisecond, the staging and fault rules, the plausibility floor (a cheat just under anti-exploit's
-- speed cap is refused, an honest full-throttle run never is), ISO week keys for the weekly board, and
-- personal-best bookkeeping. Pure logic: runs in Edit mode.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Catalog = require(ReplicatedStorage.Shared.Vehicle.Catalog)
local DragStrip = require(ReplicatedStorage.Shared.Config.DragStrip)
local Harness = require(ReplicatedStorage.Shared.Testing.Harness)
local Powertrain = require(ReplicatedStorage.Shared.Vehicle.Powertrain)
local Tuning = require(ReplicatedStorage.Shared.Vehicle.Tuning)
local Types = require(ReplicatedStorage.Shared.Types)
local Units = require(ReplicatedStorage.Shared.Util.Units)
local DragStripService = require(ServerScriptService.Server.Services.DragStripService)

local EXACT = 1e-9 -- seconds; pure double arithmetic
local SUB_FRAME = 1e-3 -- seconds; well inside the ±0.05 s acceptance, from 30 fps samples
local VECTOR = 1e-3 -- studs; Vector3 is 32-bit
local GATE_METERS = 1 -- each gate within a meter of its drag distance
-- Drag distances in meters: 330 ft, an eighth of a mile, a quarter mile.
local GATE_DISTANCES = { [2] = 100.584, [3] = 201.168, [4] = 402.336 }
local FRAME = 1 / 30
local BISECTIONS = 60
local CHEAT_SHARE = 0.98 -- of the car's top speed, held from the line: under anti-exploit's cap
local HONEST_LEAD = 2 -- studs: an honest car's front stops about this far behind the line
local HONEST_STEP = 1 / 120
local HONEST_MAX_SECONDS = 60

local function at(year: number, month: number, day: number, hour: number?, minute: number?, second: number?): number
	return DateTime.fromUniversalTime(year, month, day, hour or 0, minute or 0, second or 0).UnixTimestamp
end

local function armFacts(overrides: { [string]: any }?): DragStrip.ArmFacts
	local facts: { [string]: any } = {
		frontPast = -2,
		lateral = 0,
		halfWidth = 32,
		speed = 0,
		ability = false,
		driving = true,
	}
	for key, value in overrides or {} do
		facts[key] = value
	end
	return facts :: any
end

local function runFacts(overrides: { [string]: any }?): DragStrip.RunFacts
	local facts: { [string]: any } = {
		phase = "running",
		frontPast = 200,
		lateral = 0,
		halfWidth = 32,
		ability = false,
		moved = false,
		jumped = false,
		driving = true,
		elapsed = 5,
	}
	for key, value in overrides or {} do
		facts[key] = value
	end
	return facts :: any
end

-- A car leaving the line from rest: distance x(t) = top * (t - (1 - e^(-k t)) / k), speed top * (1 - e^(-k t)).
local TOP, RATE = 150, 0.5
local function distanceAt(seconds: number): number
	return TOP * (seconds - (1 - math.exp(-RATE * seconds)) / RATE)
end
local function speedAt(seconds: number): number
	return TOP * (1 - math.exp(-RATE * seconds))
end

-- Studs from the start line to each later gate, in gate order.
local function gateDistances(): { number }
	local gates = DragStrip.gates()
	local distances: { number } = {}
	for index = 2, #gates do
		table.insert(distances, DragStrip.distancePast(gates[1], gates[index].origin))
	end
	return distances
end

-- An honest run: full throttle in Standard through the same powertrain the chassis drives with (throttle ramp,
-- gears, limiter, traction control at static load), from rest `lead` studs behind the line. Seconds from the
-- front crossing the line to each of `distances`.
local function honestSplits(tuning: Tuning.Tuning, distances: { number }, lead: number): { number }
	local powertrain = Powertrain.new(tuning)
	local controls: Types.Controls = { throttle = 1, brake = 0, steer = 0, handbrake = false }
	local cap = Powertrain.tractionCap(tuning, "standard")
	local times: { number } = {}
	local position, speed, clock = -lead, 0, 0
	local startedAt: number? = nil
	while #times < #distances and clock < HONEST_MAX_SECONDS do
		local output = powertrain:update(HONEST_STEP, controls, speed, "standard", "standard")
		local accel = math.min(output.driveAccel, cap) - Powertrain.resistance(tuning, speed) - output.brakeAccel
		local nextSpeed = math.max(0, speed + accel * HONEST_STEP)
		local nextPosition = position + (speed + nextSpeed) / 2 * HONEST_STEP
		local span = nextPosition - position
		if startedAt == nil and nextPosition >= 0 and span > 0 then
			startedAt = clock + HONEST_STEP * -position / span
		end
		local started = startedAt
		while started ~= nil and #times < #distances and nextPosition >= distances[#times + 1] do
			local distance = distances[#times + 1]
			table.insert(times, clock + HONEST_STEP * (distance - position) / span - started)
		end
		position, speed = nextPosition, nextSpeed
		clock += HONEST_STEP
	end
	return times
end

-- When distanceAt first reaches `target`, by bisection on the exact motion.
local function exactCrossing(target: number, low: number, high: number): number
	for _ = 1, BISECTIONS do
		local middle = (low + high) / 2
		if distanceAt(middle) < target then
			low = middle
		else
			high = middle
		end
	end
	return (low + high) / 2
end

return function(t: Harness.Api)
	t.describe("DragStrip gates", function()
		local gates = DragStrip.gates()

		t.it("reads the four gates from the map, start line first", function()
			t.expect(#gates).toBe(DragStrip.gateCount)
			for index, gate in gates do
				t.expect(gate.index).toBe(index)
				t.expect(gate.halfWidth).toBeGreaterThan(0)
			end
		end)

		t.it("lines the gates up on one straight strip at the drag distances", function()
			local start = gates[1]
			for _, gate in gates do
				t.expect(gate.normal:Dot(start.normal)).toBeNear(1, VECTOR)
				t.expect(math.abs(DragStrip.lateral(start, gate.origin))).toBeLessThan(VECTOR)
			end
			for index, meters in GATE_DISTANCES do
				local studs = DragStrip.distancePast(start, gates[index].origin)
				t.expect(Units.studsToMeters(studs)).toBeNear(meters, GATE_METERS)
			end
		end)

		t.it("measures from the front face of the chassis", function()
			local chassis = CFrame.lookAt(Vector3.new(10, 2, 5), Vector3.new(20, 2, 5))
			local front = DragStrip.frontPoint(chassis, Vector3.new(6, 2, 14))
			t.expect((front - Vector3.new(17, 2, 5)).Magnitude).toBeLessThan(VECTOR)
		end)
	end)

	t.describe("DragStrip.crossingTime", function()
		t.it("finds the exact moment at a steady speed", function()
			-- 3 studs short, then 7 past, at 600 studs/s over 1/60 s: 30% of the way through the frame.
			local crossed = DragStrip.crossingTime(10, -3, 600, 10 + 1 / 60, 7, 600)
			t.expect(crossed).toBeNear(10 + 0.3 / 60, EXACT)
		end)

		t.it("is exact for constant acceleration", function()
			-- x(t) = -2 + 30 t + 40 t^2, sampled at t = 0 and t = 0.2.
			local function x(s: number): number
				return -2 + 30 * s + 40 * s * s
			end
			local function v(s: number): number
				return 30 + 80 * s
			end
			local root = (-30 + math.sqrt(30 * 30 + 4 * 40 * 2)) / (2 * 40)
			t.expect(DragStrip.crossingTime(0, x(0), v(0), 0.2, x(0.2), v(0.2))).toBeNear(root, EXACT)
		end)

		t.it("lands on the second sample when the front is exactly on the line", function()
			t.expect(DragStrip.crossingTime(1, -4, 120, 1.05, 0, 120)).toBeNear(1.05, EXACT)
		end)

		t.it("finds nothing unless the front goes from before the line to on or past it", function()
			t.expect(DragStrip.crossingTime(0, -10, 50, 0.1, -5, 50)).toBe(nil) -- still short
			t.expect(DragStrip.crossingTime(0, 0, 50, 0.1, 5, 50)).toBe(nil) -- already on it
			t.expect(DragStrip.crossingTime(0, 2, 50, 0.1, 7, 50)).toBe(nil) -- already past
			t.expect(DragStrip.crossingTime(0, 3, -40, 0.1, -1, -40)).toBe(nil) -- backing over it
		end)

		t.it("answers the later sample for a zero-length frame", function()
			t.expect(DragStrip.crossingTime(4, -1, 10, 4, 1, 10)).toBe(4)
		end)

		t.it("times every gate of a run sampled at 30 fps to well under a millisecond", function()
			local gates = DragStrip.gates()
			local start = gates[1]
			local lead = 5 -- the front starts this far behind the line
			local function sample(seconds: number): (Vector3, Vector3)
				local front = start.origin + start.normal * (distanceAt(seconds) - lead) + Vector3.yAxis
				return front, start.normal * speedAt(seconds)
			end
			local crossings: { [number]: number } = {}
			local previousTime = 0
			local previousFront, previousVelocity = sample(0)
			local clock = 0
			while clock < DragStrip.maxRunSeconds and crossings[#gates] == nil do
				clock += FRAME
				local front, velocity = sample(clock)
				for _, gate in gates do
					if crossings[gate.index] == nil then
						local crossed = DragStrip.crossingTime(
							previousTime,
							DragStrip.distancePast(gate, previousFront),
							previousVelocity:Dot(gate.normal),
							clock,
							DragStrip.distancePast(gate, front),
							velocity:Dot(gate.normal)
						)
						if crossed ~= nil then
							crossings[gate.index] = crossed
						end
					end
				end
				previousTime, previousFront, previousVelocity = clock, front, velocity
			end
			for _, gate in gates do
				local crossed = crossings[gate.index]
				t.expect(crossed ~= nil).toBe(true)
				local truth = exactCrossing(DragStrip.distancePast(start, gate.origin) + lead, 0, clock)
				t.expect(math.abs((crossed or math.huge) - truth)).toBeLessThan(SUB_FRAME)
			end
		end)
	end)

	t.describe("DragStrip staging", function()
		t.it("arms a car standing still just behind the line", function()
			t.expect(DragStrip.canArm(armFacts())).toBe(true)
			t.expect(DragStrip.canArm(armFacts({ frontPast = -DragStrip.staging.depth }))).toBe(true)
		end)

		t.it("won't arm a car that is moving, on or past the line, too far back or off to the side", function()
			t.expect(DragStrip.canArm(armFacts({ speed = DragStrip.staging.stillSpeed }))).toBe(false)
			t.expect(DragStrip.canArm(armFacts({ frontPast = 0 }))).toBe(false)
			t.expect(DragStrip.canArm(armFacts({ frontPast = 3 }))).toBe(false)
			t.expect(DragStrip.canArm(armFacts({ frontPast = -DragStrip.staging.depth - 1 }))).toBe(false)
			t.expect(DragStrip.canArm(armFacts({ lateral = 33 }))).toBe(false)
			t.expect(DragStrip.canArm(armFacts({ lateral = -33 }))).toBe(false)
		end)

		t.it("won't arm a car with an ability running or nobody at the wheel", function()
			t.expect(DragStrip.canArm(armFacts({ ability = true }))).toBe(false)
			t.expect(DragStrip.canArm(armFacts({ driving = false }))).toBe(false)
		end)

		t.it("keeps watching only cars whose front is in the sensor's stretch behind the line", function()
			local staging = DragStrip.staging
			t.expect(DragStrip.staysStaged(-1, 0, 32)).toBe(true)
			t.expect(DragStrip.staysStaged(-(staging.depth + staging.sensorTail), 0, 32)).toBe(true)
			t.expect(DragStrip.staysStaged(-(staging.depth + staging.sensorTail) - 1, 0, 32)).toBe(false)
			t.expect(DragStrip.staysStaged(0, 0, 32)).toBe(false) -- rolled over the line without arming
			t.expect(DragStrip.staysStaged(-5, 32 + DragStrip.sideMargin + 1, 32)).toBe(false)
		end)
	end)

	t.describe("DragStrip faults", function()
		t.it("lets a clean run go on", function()
			t.expect(DragStrip.faultFor(runFacts())).toBe(nil)
			t.expect(DragStrip.faultFor(runFacts({ phase = "armed", frontPast = -3, elapsed = 0 }))).toBe(nil)
			t.expect(DragStrip.faultFor(runFacts({ lateral = 32 + DragStrip.sideMargin }))).toBe(nil)
			t.expect(DragStrip.faultFor(runFacts({ elapsed = DragStrip.maxRunSeconds }))).toBe(nil)
		end)

		t.it("voids a run when the car is moved or jumps", function()
			t.expect(DragStrip.faultFor(runFacts({ moved = true }))).toBe("teleport")
			t.expect(DragStrip.faultFor(runFacts({ jumped = true }))).toBe("teleport")
		end)

		t.it("voids a run when an ability runs mid-run", function()
			t.expect(DragStrip.faultFor(runFacts({ ability = true }))).toBe("ability")
			t.expect(DragStrip.faultFor(runFacts({ phase = "armed", frontPast = -3, ability = true }))).toBe("ability")
		end)

		t.it("voids a run when the driver gets out", function()
			t.expect(DragStrip.faultFor(runFacts({ driving = false }))).toBe("driver")
		end)

		t.it("voids a run that leaves the strip sideways, either side", function()
			local beyond = 32 + DragStrip.sideMargin + 0.5
			t.expect(DragStrip.faultFor(runFacts({ lateral = beyond }))).toBe("sideways")
			t.expect(DragStrip.faultFor(runFacts({ lateral = -beyond }))).toBe("sideways")
		end)

		t.it("voids a run that takes too long", function()
			t.expect(DragStrip.faultFor(runFacts({ elapsed = DragStrip.maxRunSeconds + 0.01 }))).toBe("timeout")
		end)

		t.it("cancels an armed car that backs away from the line", function()
			local staging = DragStrip.staging
			local away = -(staging.depth + staging.backOffMargin) - 0.5
			t.expect(DragStrip.faultFor(runFacts({ phase = "armed", frontPast = away, elapsed = 0 }))).toBe("cancelled")
		end)

		t.it("puts a move by the server ahead of everything else", function()
			local everything = runFacts({ moved = true, ability = true, driving = false, lateral = 100, elapsed = 99 })
			t.expect(DragStrip.faultFor(everything)).toBe("teleport")
		end)

		t.it("has a plain message for every fault", function()
			for _, fault in { "cancelled", "sideways", "teleport", "ability", "driver", "timeout" } do
				local message = DragStrip.messages.faults[fault :: DragStrip.Fault]
				t.expect(type(message) == "string" and #message > 0).toBe(true)
			end
		end)

		t.it("tells a fast honest frame from a teleport", function()
			local arcTop = Units.mphToStuds(230)
			t.expect(DragStrip.isJump(arcTop / 60, 1 / 60, arcTop)).toBe(false) -- one frame at top speed
			t.expect(DragStrip.isJump(arcTop * 0.25, 1 / 60, arcTop)).toBe(false) -- a bunched quarter second
			t.expect(DragStrip.isJump(500, 1 / 60, arcTop)).toBe(true) -- the 500-stud forged teleport
		end)

		t.it("refuses times no car can run", function()
			t.expect(DragStrip.isPlausible(DragStrip.minPlausibleSeconds - 0.1)).toBe(false)
			t.expect(DragStrip.isPlausible(6.5)).toBe(true)
			t.expect(DragStrip.isPlausible(0 / 0)).toBe(false)
			t.expect(DragStrip.isPlausible(math.huge)).toBe(false)
		end)

		t.it("works out each car's quickest possible time to every gate", function()
			local tuning = Tuning.forTrim("ohm_arc", "flight")
			assert(tuning, "the Arc Flight is in the catalog")
			local fastest = DragStrip.fastestSplits(tuning, gateDistances())
			t.expect(#fastest).toBe(DragStrip.gateCount - 1)
			local previous = 0
			for _, seconds in fastest do
				t.expect(seconds).toBeGreaterThan(previous)
				previous = seconds
			end
			-- A car that never moves has no bound. (table.clone's copy of the frozen tuning isn't frozen.)
			local stuck = table.clone(tuning :: any)
			stuck.peakAccel = 0
			t.expect(DragStrip.fastestSplits(stuck :: any, { 100 })).toEqual({ 0 })
		end)

		t.it("refuses a run held just under anti-exploit's speed cap from the line, and its splits", function()
			local distances = gateDistances()
			for _, trimId in { "performance", "boost", "flight" } do
				local tuning = Tuning.forTrim("ohm_arc", trimId)
				assert(tuning, `ohm_arc/{trimId} is in the catalog`)
				local fastest = DragStrip.fastestSplits(tuning, distances)
				local cheatSpeed = tuning.topSpeed * CHEAT_SHARE
				local total = distances[#distances] / cheatSpeed
				t.expect(DragStrip.isPlausible(total, fastest[#fastest])).toBe(false)
				for index = 1, #distances - 1 do
					t.expect(DragStrip.isPlausible(distances[index] / cheatSpeed, fastest[index], true)).toBe(false)
				end
			end
			-- The Arc at 0.98 x its 220 mph clears the old single 4 s floor: only the car's own floor stops it.
			local arc = Tuning.forTrim("ohm_arc", "performance")
			assert(arc, "the Arc is in the catalog")
			t.expect(distances[#distances] / (arc.topSpeed * CHEAT_SHARE))
				.toBeGreaterThan(DragStrip.minPlausibleSeconds)
		end)

		t.it("never refuses an honest full-throttle run of any drivable car", function()
			local distances = gateDistances()
			local staging = DragStrip.staging
			local problems: { string } = {}
			for _, vehicleId in Catalog.vehicleIds() do
				local vehicle = Catalog.getVehicle(vehicleId)
				if vehicle == nil or not vehicle.playerDrivable then
					continue
				end
				for _, trim in vehicle.trims do
					local tuning = Tuning.forTrim(vehicleId, trim.id)
					assert(tuning, `{vehicleId}/{trim.id} has a tuning`)
					local fastest = DragStrip.fastestSplits(tuning, distances)
					-- From a normal stop just behind the line, and from the furthest back an armed car may roll.
					for _, lead in { HONEST_LEAD, staging.depth + staging.backOffMargin } do
						local honest = honestSplits(tuning, distances, lead)
						for index, seconds in honest do
							local split = index < #distances
							if not DragStrip.isPlausible(seconds, fastest[index], split) then
								table.insert(
									problems,
									`{vehicleId}/{trim.id} from {lead} studs: gate {index + 1} {seconds} s`
								)
							end
						end
					end
				end
			end
			t.expect(problems).toEqual({})
		end)
	end)

	t.describe("DragStrip weekly board", function()
		t.it("keys each board by ISO week", function()
			t.expect(DragStrip.weekKey(at(2026, 10, 20, 12))).toBe("2026-W43")
			t.expect(DragStrip.weekKey(at(2026, 10, 19))).toBe("2026-W43") -- Monday starts the week
			t.expect(DragStrip.weekKey(at(2026, 10, 18, 23, 59, 59))).toBe("2026-W42") -- Sunday ends the last
			t.expect(DragStrip.weekKey(at(2026, 1, 1))).toBe("2026-W01") -- a Thursday
			t.expect(DragStrip.weekKey(at(2027, 1, 3))).toBe("2026-W53") -- 2026 has 53 weeks
			t.expect(DragStrip.weekKey(at(2027, 1, 4))).toBe("2027-W01")
			t.expect(DragStrip.weekKey(at(2021, 1, 1))).toBe("2020-W53") -- New Year in the old year's week
			t.expect(DragStrip.weekKey(at(2024, 12, 30))).toBe("2025-W01") -- ...and in the new year's
		end)

		t.it("reads the week number back from a key", function()
			t.expect(DragStrip.weekNumber("2026-W43")).toBe(43)
			t.expect(DragStrip.weekNumber("2026-W01")).toBe(1)
			t.expect(DragStrip.weekNumber("nonsense")).toBe(nil)
		end)

		t.it("stores whole milliseconds and shows seconds", function()
			t.expect(DragStrip.toMs(9.87349)).toBe(9873)
			t.expect(DragStrip.toMs(9.87351)).toBe(9874)
			t.expect(DragStrip.toSeconds(9873)).toBeNear(9.873, EXACT)
			t.expect(DragStrip.formatTime(9.873)).toBe("9.873 s")
		end)

		t.it("writes only a personal best", function()
			t.expect(DragStrip.isPersonalBest(nil, 9000)).toBe(true)
			t.expect(DragStrip.isPersonalBest(9500, 9000)).toBe(true)
			t.expect(DragStrip.isPersonalBest(9000, 9000)).toBe(false)
			t.expect(DragStrip.isPersonalBest(8000, 9000)).toBe(false)
		end)

		t.it("keeps the board sorted, one best per player, cut to size", function()
			local entries: { DragStrip.Entry } = {
				{ userId = 1, ms = 7000 },
				{ userId = 2, ms = 8000 },
				{ userId = 3, ms = 9000 },
			}
			local faster = DragStrip.mergeEntry(entries, 3, 7500, 10)
			t.expect(faster).toEqual({
				{ userId = 1, ms = 7000 },
				{ userId = 3, ms = 7500 },
				{ userId = 2, ms = 8000 },
			})
			local slower = DragStrip.mergeEntry(entries, 1, 9900, 10)
			t.expect(slower[1]).toEqual({ userId = 1, ms = 7000 })
			t.expect(#slower).toBe(3)
			local tie = DragStrip.mergeEntry(entries, 0, 8000, 10)
			t.expect(tie[2]).toEqual({ userId = 0, ms = 8000 })
			local cut = DragStrip.mergeEntry(entries, 4, 6000, 2)
			t.expect(cut).toEqual({ { userId = 4, ms = 6000 }, { userId = 1, ms = 7000 } })
		end)

		t.it("ranks a player by their place on the board", function()
			local entries: { DragStrip.Entry } = { { userId = 5, ms = 7000 }, { userId = 9, ms = 7100 } }
			t.expect(DragStrip.rankOf(entries, 9)).toBe(2)
			t.expect(DragStrip.rankOf(entries, 7)).toBe(nil)
		end)

		t.it("keeps Studio's boards apart from the live ones", function()
			t.expect(DragStrip.studioStorePrefix ~= DragStrip.storePrefix).toBe(true)
			t.expect(DragStrip.boardSize <= DragStrip.rankPageSize).toBe(true)
		end)
	end)

	t.describe("DragStripService", function()
		t.it("runs the same pure rules as Config/DragStrip", function()
			t.expect(DragStripService.weekKey).toBe(DragStrip.weekKey)
			t.expect(DragStripService.crossingTime).toBe(DragStrip.crossingTime)
			t.expect(DragStripService.faultFor).toBe(DragStrip.faultFor)
		end)
	end)
end
