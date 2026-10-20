--!strict
-- Ambient pod routes (docs/phase-9-contracts.md "Ambient pods = ambient traffic"): Road/TrafficPath's polyline math
-- (length, the point and heading at a distance, with and without hints), lane lines on the right (mitred bends,
-- U-turns, a route starting where the last one ended), speed profiles (at rest at both ends, under each segment's
-- cruise speed, slower through bends, smooth), whole routes on the county (in their lane, the same every time,
-- chained routes joining up), the TrafficRoutes payload's encode and decode, and sane Config/Traffic numbers (no pod
-- ever over a road's limit). Pure logic: runs in Edit mode.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Graph = require(ReplicatedStorage.Shared.Road.Graph)
local Harness = require(ReplicatedStorage.Shared.Testing.Harness)
local Pathfind = require(ReplicatedStorage.Shared.Road.Pathfind)
local RoadGraph = require(ReplicatedStorage.Shared.Config.RoadGraph)
local Traffic = require(ReplicatedStorage.Shared.Config.Traffic)
local TrafficPath = require(ReplicatedStorage.Shared.Road.TrafficPath)
local Units = require(ReplicatedStorage.Shared.Util.Units)
local World = require(ReplicatedStorage.Shared.Config.World)

local SEED = 20261020
-- Vector3 components are 32-bit floats: exact to ~1e-4 near a few thousand studs.
local TOLERANCE = 1e-3
local SAME = 1e-9 -- for plain numbers
local STEP = 0.05 -- seconds between samples of a profile
local RANDOM_ROUTES = 40 -- county routes planned and checked end to end
local STUCK_SECONDS = 3 -- Dev/TrafficTests: a pod still for longer is stuck

local OFFSET = Traffic.lane.offsetLanes * World.laneWidth

-- Easy numbers for the profile cases: studs and seconds.
local SETTINGS: TrafficPath.ProfileSettings = {
	accel = 4,
	decel = 6,
	lateralAccel = 10,
	cornerSpan = 60,
	minCornerSpeed = 2,
	dwell = 2,
}

local function near(t: Harness.Api, actual: Vector3, expected: Vector3)
	t.expect((actual - expected).Magnitude).toBeNear(0, TOLERANCE)
end

local indexOf: { [string]: number } = {}
for index, node in Graph.nodes() do
	indexOf[node.id] = index
end

local function indicesOf(ids: { string }): { number }
	local indices: { number } = {}
	for _, id in ids do
		table.insert(indices, indexOf[id])
	end
	return indices
end

-- The county path between two node ids, as node indices.
local function countyPath(t: Harness.Api, from: string, to: string): { number }
	local ids = Pathfind.findPath(from, to)
	t.expect(ids ~= nil).toBe(true)
	return indicesOf(ids :: { string })
end

-- Samples a profile every STEP seconds from 0 to just past its end: distances and speeds.
local function sample(profile: TrafficPath.Profile): ({ number }, { number })
	local distances, speeds = {}, {}
	local hint: number? = nil
	local t = 0
	while t <= profile.duration + STEP do
		local distance, speed, segment = TrafficPath.distanceAt(profile, t, hint)
		hint = segment
		table.insert(distances, distance)
		table.insert(speeds, speed)
		t += STEP
	end
	return distances, speeds
end

-- Checks the shape every profile must have: still through the dwell, never backwards, no jumps, no faster than
-- `fastest`, speed changing no quicker than the settings allow, at rest at the end of the path.
local function checkProfile(
	t: Harness.Api,
	profile: TrafficPath.Profile,
	settings: TrafficPath.ProfileSettings,
	fastest: number
)
	local distances, speeds = sample(profile)
	local hardest = math.max(settings.accel, settings.decel)
	for i, distance in distances do
		t.expect(speeds[i]).toBeLessThan(fastest + SAME)
		if (i - 1) * STEP < settings.dwell - STEP / 2 then
			t.expect(distance).toBe(0)
		end
		if i > 1 then
			t.expect(distance + SAME).toBeGreaterThan(distances[i - 1])
			t.expect(distance - distances[i - 1]).toBeLessThan(fastest * STEP + 1e-6)
			t.expect(math.abs(speeds[i] - speeds[i - 1])).toBeLessThan(hardest * STEP + 1e-6)
		end
	end
	t.expect(distances[#distances]).toBeNear(profile.length, 1e-6)
	t.expect(speeds[#speeds]).toBe(0)
end

-- A route record for the payload cases.
local function record(pod: number, seq: number, startAt: number, scale: number, lead: number, nodes: { number })
	return { pod = pod, seq = seq, startAt = startAt, scale = scale, lead = lead, nodes = nodes }
end

-- A copy of `data` cut to `size` bytes (longer: padded with zeros).
local function resized(data: buffer, size: number): buffer
	local copy = buffer.create(size)
	buffer.copy(copy, 0, data, 0, math.min(size, buffer.len(data)))
	return copy
end

return function(t: Harness.Api)
	t.describe("TrafficPath polylines", function()
		-- 30 studs east, then 40 studs south: 70 studs.
		local corner = TrafficPath.fromPoints({ Vector3.new(0, 0, 0), Vector3.new(30, 0, 0), Vector3.new(30, 0, 40) })

		t.it("measures a polyline", function()
			t.expect(corner.length).toBeNear(70, SAME)
			t.expect(corner.along).toEqual({ 0, 30, 70 })
			t.expect(TrafficPath.fromPoints({ Vector3.new(5, 1, 5) }).length).toBe(0)
		end)

		t.it("finds the point at a distance, clamped to the path, with or without a hint", function()
			local cases = {
				{ distance = -5, point = Vector3.new(0, 0, 0) },
				{ distance = 0, point = Vector3.new(0, 0, 0) },
				{ distance = 15, point = Vector3.new(15, 0, 0) },
				{ distance = 30, point = Vector3.new(30, 0, 0) },
				{ distance = 50, point = Vector3.new(30, 0, 20) },
				{ distance = 70, point = Vector3.new(30, 0, 40) },
				{ distance = 100, point = Vector3.new(30, 0, 40) },
			}
			for _, case in cases do
				local point = TrafficPath.positionAt(corner, case.distance)
				near(t, point, case.point)
				for hint = 1, 2 do
					local hinted = TrafficPath.positionAt(corner, case.distance, hint)
					near(t, hinted, case.point)
				end
			end
			local _, segment = TrafficPath.positionAt(corner, 50)
			t.expect(segment).toBe(2)
			local single = TrafficPath.fromPoints({ Vector3.new(5, 1, 5) })
			near(t, (TrafficPath.positionAt(single, 3)), Vector3.new(5, 1, 5))
		end)

		t.it("faces along the path, and halfway round at a bend", function()
			near(t, TrafficPath.directionAt(corner, 10, 4), Vector3.new(1, 0, 0))
			near(t, TrafficPath.directionAt(corner, 60, 4), Vector3.new(0, 0, 1))
			near(t, TrafficPath.directionAt(corner, 30, 4), Vector3.new(1, 0, 1).Unit)
			-- At the ends it looks along the first and last stretch.
			near(t, TrafficPath.directionAt(corner, 0, 4), Vector3.new(1, 0, 0))
			near(t, TrafficPath.directionAt(corner, 70, 4), Vector3.new(0, 0, 1))
		end)
	end)

	t.describe("TrafficPath lane lines", function()
		t.it("drives on the right", function()
			-- Heading east the right is south (+Z); heading north (-Z) it is east (+X).
			local east = TrafficPath.laneLine({ Vector3.new(0, 0, 0), Vector3.new(100, 0, 0) }, 6, -0.5, { 10 })
			near(t, east[1], Vector3.new(0, 0, 6))
			near(t, east[2], Vector3.new(100, 0, 6))
			local north = TrafficPath.laneLine({ Vector3.new(0, 2, 0), Vector3.new(0, 2, -100) }, 6, -0.5, { 10 })
			near(t, north[1], Vector3.new(6, 2, 0))
			near(t, north[2], Vector3.new(6, 2, -100))
		end)

		t.it("mitres a bend so the lane keeps its width", function()
			-- East, then a right turn south at (100, 0, 0): the inside corner is 6 studs from both centre lines.
			local points, speeds = TrafficPath.laneLine(
				{ Vector3.new(0, 0, 0), Vector3.new(100, 0, 0), Vector3.new(100, 0, 100) },
				6,
				-0.5,
				{ 10, 20 }
			)
			t.expect(#points).toBe(3)
			near(t, points[2], Vector3.new(94, 0, 6))
			t.expect(speeds).toEqual({ 10, 20 })
			-- A left turn north instead: the outside corner.
			local left = TrafficPath.laneLine(
				{ Vector3.new(0, 0, 0), Vector3.new(100, 0, 0), Vector3.new(100, 0, -100) },
				6,
				-0.5,
				{ 10, 20 }
			)
			near(t, left[2], Vector3.new(106, 0, 6))
		end)

		t.it("crosses straight over at a U-turn, at the slower road's speed", function()
			local points, speeds = TrafficPath.laneLine(
				{ Vector3.new(0, 0, 0), Vector3.new(100, 0, 0), Vector3.new(0, 0, 0) },
				6,
				-0.5,
				{ 10, 20 }
			)
			t.expect(#points).toBe(4)
			near(t, points[1], Vector3.new(0, 0, 6))
			near(t, points[2], Vector3.new(100, 0, 6))
			near(t, points[3], Vector3.new(100, 0, -6))
			near(t, points[4], Vector3.new(0, 0, -6))
			t.expect(speeds).toEqual({ 10, 10, 20 })
		end)

		t.it("starts where a line along the lead direction ended", function()
			-- Arrived heading east at (100, 0, 0), now heading north: the line starts in the eastbound lane.
			local turn = TrafficPath.laneLine(
				{ Vector3.new(100, 0, 0), Vector3.new(100, 0, -200) },
				6,
				-0.5,
				{ 10 },
				Vector3.new(1, 0, 0)
			)
			t.expect(#turn).toBe(2)
			near(t, turn[1], Vector3.new(100, 0, 6))
			near(t, turn[2], Vector3.new(106, 0, -200))
			-- Arrived heading west, now heading back east: it crosses over first.
			local back, speeds = TrafficPath.laneLine(
				{ Vector3.new(100, 0, 0), Vector3.new(300, 0, 0) },
				6,
				-0.5,
				{ 10 },
				Vector3.new(-1, 0, 0)
			)
			t.expect(#back).toBe(3)
			near(t, back[1], Vector3.new(100, 0, -6))
			near(t, back[2], Vector3.new(100, 0, 6))
			near(t, back[3], Vector3.new(300, 0, 6))
			t.expect(speeds).toEqual({ 10, 10 })
		end)
	end)

	t.describe("TrafficPath speed profiles", function()
		t.it("rests, speeds up to cruise, holds it and slows to a stop on a long straight", function()
			local path = TrafficPath.fromPoints({ Vector3.new(0, 0, 0), Vector3.new(1000, 0, 0) })
			local profile = TrafficPath.profile(path, { 40 }, SETTINGS)
			-- 10 s and 200 studs up to 40, 40/6 s and 133.3 studs down, 666.7 studs held at 40.
			local expected = SETTINGS.dwell + 40 / 4 + (1000 - 200 - 1600 / 12) / 40 + 40 / 6
			t.expect(profile.duration).toBeNear(expected, 1e-6)
			t.expect(profile.peakSpeed[1]).toBeNear(40, SAME)
			local distance, speed = TrafficPath.distanceAt(profile, 1)
			t.expect(distance).toBe(0)
			t.expect(speed).toBe(0)
			distance, speed = TrafficPath.distanceAt(profile, SETTINGS.dwell + 5)
			t.expect(distance).toBeNear(0.5 * 4 * 25, 1e-6)
			t.expect(speed).toBeNear(20, 1e-9)
			distance, speed = TrafficPath.distanceAt(profile, SETTINGS.dwell + 20)
			t.expect(distance).toBeNear(200 + 40 * 10, 1e-6)
			t.expect(speed).toBeNear(40, SAME)
			distance, speed = TrafficPath.distanceAt(profile, profile.duration + 5)
			t.expect(distance).toBeNear(1000, SAME)
			t.expect(speed).toBe(0)
			checkProfile(t, profile, SETTINGS, 40)
		end)

		t.it("never reaches cruise on a short hop", function()
			local path = TrafficPath.fromPoints({ Vector3.new(0, 0, 0), Vector3.new(50, 0, 0) })
			local profile = TrafficPath.profile(path, { 40 }, SETTINGS)
			local peak = math.sqrt(2 * 4 * 6 * 50 / (4 + 6))
			t.expect(profile.peakSpeed[1]).toBeNear(peak, 1e-9)
			t.expect(profile.duration).toBeNear(SETTINGS.dwell + peak / 4 + peak / 6, 1e-9)
			checkProfile(t, profile, SETTINGS, peak)
		end)

		t.it("slows for a bend to what its angle and the room around it allow", function()
			-- A right angle with 300 studs each side: room = cornerSpan (60), radius 60 / tan(45°) = 60.
			local path =
				TrafficPath.fromPoints({ Vector3.new(0, 0, 0), Vector3.new(300, 0, 0), Vector3.new(300, 0, 300) })
			local profile = TrafficPath.profile(path, { 40, 40 }, SETTINGS)
			local bend = math.sqrt(SETTINGS.lateralAccel * 60)
			t.expect(profile.exitSpeed[1]).toBeNear(bend, 1e-9)
			t.expect(profile.entrySpeed[2]).toBeNear(bend, 1e-9)
			checkProfile(t, profile, SETTINGS, 40)
			-- Gentle bends of a long curve barely slow it; a hairpin crawls at minCornerSpeed.
			local gentle = TrafficPath.fromPoints({
				Vector3.new(0, 0, 0),
				Vector3.new(300, 0, 0),
				Vector3.new(300 + 300 * math.cos(math.rad(5)), 0, 300 * math.sin(math.rad(5))),
			})
			t.expect(TrafficPath.profile(gentle, { 40, 40 }, SETTINGS).exitSpeed[1]).toBeNear(40, SAME)
			local hairpin = TrafficPath.fromPoints({
				Vector3.new(0, 0, 0),
				Vector3.new(300, 0, 0),
				Vector3.new(0, 0, 1),
			})
			t.expect(TrafficPath.profile(hairpin, { 40, 40 }, SETTINGS).exitSpeed[1])
				.toBeNear(SETTINGS.minCornerSpeed, 1e-6)
		end)

		t.it("slows before a slower road and never cruises below the crawl speed", function()
			local path =
				TrafficPath.fromPoints({ Vector3.new(0, 0, 0), Vector3.new(500, 0, 0), Vector3.new(1000, 0, 0) })
			local profile = TrafficPath.profile(path, { 40, 15 }, SETTINGS)
			t.expect(profile.exitSpeed[1]).toBeNear(15, SAME)
			t.expect(profile.peakSpeed[2]).toBeNear(15, SAME)
			checkProfile(t, profile, SETTINGS, 40)
			local crawl =
				TrafficPath.profile(TrafficPath.fromPoints({ Vector3.zero, Vector3.new(100, 0, 0) }), { 0 }, SETTINGS)
			t.expect(crawl.peakSpeed[1]).toBeNear(SETTINGS.minCornerSpeed, SAME)
			t.expect(crawl.duration < math.huge).toBe(true)
		end)

		t.it("gives the same answer with a hint as without", function()
			local path = TrafficPath.fromPoints({
				Vector3.new(0, 0, 0),
				Vector3.new(200, 0, 0),
				Vector3.new(200, 0, 150),
				Vector3.new(500, 0, 150),
			})
			local profile = TrafficPath.profile(path, { 40, 25, 50 }, SETTINGS)
			local hint = 1
			local time = 0
			while time <= profile.duration + 1 do
				local plain, plainSpeed = TrafficPath.distanceAt(profile, time)
				local hinted, hintedSpeed, segment = TrafficPath.distanceAt(profile, time, hint)
				t.expect(hinted).toBe(plain)
				t.expect(hintedSpeed).toBe(plainSpeed)
				hint = segment
				time += 0.37
			end
		end)
	end)

	t.describe("TrafficPath routes on the county", function()
		t.it("keeps every segment at or under its road's cruise speed, in the right-hand lane", function()
			local nodes = countyPath(t, "cb_a1", "cb_g7")
			local scale = TrafficPath.quantizeScale(Traffic.speed.scaleMax)
			local plan = TrafficPath.plan(Graph, nodes, scale, nil)
			t.expect(plan ~= nil).toBe(true)
			local route = plan :: TrafficPath.Plan
			-- The cruise speeds plan() used, rebuilt from the edges.
			local centre, cruise = {}, {}
			for i, index in nodes do
				table.insert(centre, Graph.nodes()[index].position)
				if i > 1 then
					local fromId, toId = Graph.nodes()[nodes[i - 1]].id, Graph.nodes()[index].id
					for _, neighbor in Graph.neighbors(fromId) do
						if neighbor.node == toId then
							local edge = Graph.edges()[neighbor.edge]
							local speed = TrafficPath.cruiseSpeed(edge, scale)
							t.expect(speed).toBeLessThan(Units.mphToStuds(edge.speedLimitMph))
							table.insert(cruise, speed)
							break
						end
					end
				end
			end
			local _, speeds = TrafficPath.laneLine(centre, OFFSET, Traffic.lane.sharpTurnDot, cruise)
			t.expect(#speeds).toBe(#route.path.points - 1)
			for i, peak in route.profile.peakSpeed do
				t.expect(peak).toBeLessThan(speeds[i] + SAME)
			end
			checkProfile(t, route.profile, TrafficPath.settings(), math.max(table.unpack(speeds)))
			-- Midway along every lane segment the pod is one half-lane from the nearest centre line.
			for i = 1, #route.path.points - 1 do
				local middle = route.path.points[i]:Lerp(route.path.points[i + 1], 0.5)
				local _, _, distance = Graph.nearestEdge(middle)
				t.expect(distance).toBeNear(OFFSET, TOLERANCE)
			end
		end)

		t.it("comes out the same every time (the server and every client agree)", function()
			local nodes = countyPath(t, "cb_b2", "cb_f6")
			local a = TrafficPath.plan(Graph, nodes, 0.947, nil) :: TrafficPath.Plan
			local b = TrafficPath.plan(Graph, table.clone(nodes), 0.947, nil) :: TrafficPath.Plan
			t.expect(a.duration).toBe(b.duration)
			t.expect(a.length).toBe(b.length)
			for time = 0, math.ceil(a.duration), 1.5 do
				t.expect((TrafficPath.distanceAt(a.profile, time))).toBe((TrafficPath.distanceAt(b.profile, time)))
			end
		end)

		t.it("starts each route where the last one ended, also after a U-turn", function()
			local first = countyPath(t, "cb_a1", "cb_d1")
			local plan = TrafficPath.plan(Graph, first, 1, nil) :: TrafficPath.Plan
			local stop = plan.path.points[#plan.path.points]
			local last, before = first[#first], first[#first - 1]
			-- On round a corner, and straight back the way it came.
			for _, target in { "cb_d4", "cb_a1" } do
				local nodes = countyPath(t, Graph.nodes()[last].id, target)
				local following = TrafficPath.plan(Graph, nodes, 1, before)
				t.expect(following ~= nil).toBe(true)
				local route = following :: TrafficPath.Plan
				near(t, route.path.points[1], stop)
				t.expect((TrafficPath.distanceAt(route.profile, 0))).toBe(0)
			end
		end)

		t.it("refuses node lists that aren't a path", function()
			t.expect(TrafficPath.plan(Graph, { indexOf.cb_a1 }, 1, nil)).toBe(nil)
			t.expect(TrafficPath.plan(Graph, { indexOf.cb_a1, indexOf.cb_g7 }, 1, nil)).toBe(nil)
			t.expect(TrafficPath.plan(Graph, { indexOf.cb_a1, #Graph.nodes() + 1 }, 1, nil)).toBe(nil)
			t.expect(TrafficPath.plan(Graph, countyPath(t, "cb_a1", "cb_b1"), 0, nil)).toBe(nil)
		end)

		t.it("plans random county routes end to end", function()
			local rng = Random.new(SEED)
			local list = Graph.nodes()
			local planned = 0
			for _ = 1, RANDOM_ROUTES * 4 do
				if planned >= RANDOM_ROUTES then
					break
				end
				local a, b = list[rng:NextInteger(1, #list)], list[rng:NextInteger(1, #list)]
				local ids = if a ~= b then Pathfind.findPath(a.id, b.id) else nil
				if ids and #ids >= 2 then
					planned += 1
					local scale =
						TrafficPath.quantizeScale(rng:NextNumber(Traffic.speed.scaleMin, Traffic.speed.scaleMax))
					local plan = TrafficPath.plan(Graph, indicesOf(ids), scale, nil)
					t.expect(plan ~= nil).toBe(true)
					local route = plan :: TrafficPath.Plan
					t.expect(route.length).toBeGreaterThan(0)
					t.expect(route.duration).toBeGreaterThan(Traffic.route.dwellSeconds)
					t.expect(route.duration < math.huge).toBe(true)
					local distance = TrafficPath.distanceAt(route.profile, route.duration)
					t.expect(distance).toBeNear(route.length, SAME)
				end
			end
			t.expect(planned).toBe(RANDOM_ROUTES)
		end)
	end)

	t.describe("TrafficRoutes payload", function()
		local records = {
			record(1, 0, 1234.567890123456, 0.937, 0, { 1, 2, 3 }),
			record(255, 4294967295, 0.125, 1, 65535, { 65535, 7 }),
		}

		t.it("round-trips every field", function()
			t.expect(TrafficPath.decode(TrafficPath.encode(records))).toEqual(records)
			t.expect(TrafficPath.decode(TrafficPath.encode({}))).toEqual({})
		end)

		t.it("is compact: 2 bytes, then 19 per route and 2 per node", function()
			t.expect(buffer.len(TrafficPath.encode(records))).toBe(2 + 19 * 2 + 2 * 5)
		end)

		t.it("carries the speed scale in thousandths", function()
			t.expect(TrafficPath.quantizeScale(0.93749)).toBe(0.937)
			t.expect(TrafficPath.quantizeScale(0.9375)).toBe(0.938)
			local decoded = TrafficPath.decode(TrafficPath.encode({ record(3, 9, 50, 0.93749, 0, { 4, 5 }) }))
			t.expect((decoded :: { TrafficPath.Record })[1].scale).toBe(0.937)
		end)

		t.it("refuses anything that isn't a route buffer", function()
			local good = TrafficPath.encode(records)
			t.expect(TrafficPath.decode(nil)).toBe(nil)
			t.expect(TrafficPath.decode("not a buffer")).toBe(nil)
			t.expect(TrafficPath.decode({})).toBe(nil)
			t.expect(TrafficPath.decode(buffer.create(0))).toBe(nil)
			t.expect(TrafficPath.decode(resized(good, buffer.len(good) - 1))).toBe(nil)
			t.expect(TrafficPath.decode(resized(good, buffer.len(good) + 1))).toBe(nil)
			local wrongFormat = resized(good, buffer.len(good))
			buffer.writeu8(wrongFormat, 0, 2)
			t.expect(TrafficPath.decode(wrongFormat)).toBe(nil)
			local noPod = resized(good, buffer.len(good))
			buffer.writeu8(noPod, 2, 0)
			t.expect(TrafficPath.decode(noPod)).toBe(nil)
			-- Node and lead indices past the graph.
			t.expect(TrafficPath.decode(good, 3)).toBe(nil)
			local small = TrafficPath.encode({ record(1, 1, 1, 1, 0, { 1, 2 }) })
			t.expect(TrafficPath.decode(small, 2) ~= nil).toBe(true)
			t.expect(TrafficPath.decode(small, 1)).toBe(nil)
			t.expect(TrafficPath.decode(TrafficPath.encode({ record(1, 1, 1, 1, 3, { 1, 2 }) }), 2)).toBe(nil)
			-- A route of one node.
			local short = buffer.create(2 + 19 + 2)
			buffer.writeu8(short, 0, 1)
			buffer.writeu8(short, 1, 1)
			buffer.writeu8(short, 2, 1)
			buffer.writeu16(short, 15, 1000)
			buffer.writeu16(short, 19, 1)
			buffer.writeu16(short, 21, 5)
			t.expect(TrafficPath.decode(short)).toBe(nil)
		end)

		t.it("won't encode a record out of range", function()
			local function encodeOne(value: any)
				return function()
					TrafficPath.encode({ value })
				end
			end
			t.expect(encodeOne(record(0, 1, 1, 1, 0, { 1, 2 }))).toThrow("pod")
			t.expect(encodeOne(record(256, 1, 1, 1, 0, { 1, 2 }))).toThrow("pod")
			t.expect(encodeOne(record(1, -1, 1, 1, 0, { 1, 2 }))).toThrow("seq")
			t.expect(encodeOne(record(1, 1, 1, 0, 0, { 1, 2 }))).toThrow("scale")
			t.expect(encodeOne(record(1, 1, 1, 1, 0, { 1 }))).toThrow("nodes")
			t.expect(encodeOne(record(1, 1, 1, 1, 0, { 1, 0 }))).toThrow("node")
		end)
	end)

	t.describe("Config/Traffic", function()
		t.it("keeps every pod under every road's limit, even while catching up", function()
			for kind in RoadGraph.styles do
				local fraction = Traffic.speed.byKind[kind]
				t.expect(fraction ~= nil).toBe(true)
				t.expect((fraction :: number) * Traffic.speed.scaleMax * (1 + Traffic.yield.catchUp)).toBeLessThan(1)
			end
			t.expect(Traffic.speed.otherKinds * Traffic.speed.scaleMax * (1 + Traffic.yield.catchUp)).toBeLessThan(1)
		end)

		t.it("has numbers that fit together", function()
			t.expect(Traffic.pods.count >= 1 and Traffic.pods.count <= 255).toBe(true)
			t.expect(Traffic.route.minLength).toBeLessThan(Traffic.route.maxLength)
			t.expect(Traffic.speed.scaleMin).toBeGreaterThan(0)
			t.expect(Traffic.speed.scaleMin <= Traffic.speed.scaleMax).toBe(true)
			t.expect(Traffic.speed.minCornerMph).toBeGreaterThan(0)
			t.expect(Traffic.lane.sharpTurnDot).toBeGreaterThan(-1)
			t.expect(Traffic.lane.sharpTurnDot).toBeLessThan(1)
			t.expect(Traffic.yield.gap).toBeLessThan(Traffic.yield.lookAhead)
			t.expect(Traffic.render.hiddenCheckSeconds).toBeLessThan(STUCK_SECONDS)
			-- A pod resting between routes must not look stuck to Dev/TrafficTests.
			t.expect(Traffic.route.dwellSeconds + Traffic.render.hiddenCheckSeconds).toBeLessThan(STUCK_SECONDS)
			-- The next route is published before the quickest route in the band could end.
			local fastest = 0
			for _, edge in RoadGraph.edges do
				fastest = math.max(fastest, TrafficPath.cruiseSpeed(edge, Traffic.speed.scaleMax))
			end
			local quickest = Traffic.route.dwellSeconds + Traffic.route.minLength / fastest
			t.expect(Traffic.route.sendAhead).toBeLessThan(quickest)
		end)
	end)
end
