--!strict
-- Road/Pathfind finds the fastest route (docs/phase-2-contracts.md, "Road modules"). On a small hand-made graph,
-- where the fastest way is not the shortest, its paths and routes match a brute-force Dijkstra exactly, and
-- route() joins the road mid-edge and leaves by whichever end is faster. On the full county it matches Dijkstra
-- too, and every route from the player spawn to a GPS destination keeps to the road and takes under 5 ms
-- (PLAN.md Phase 2 acceptance). Pure logic: runs in Edit mode.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Graph = require(ReplicatedStorage.Shared.Road.Graph)
local Harness = require(ReplicatedStorage.Shared.Testing.Harness)
local MapLayout = require(ReplicatedStorage.Shared.Config.MapLayout)
local Pathfind = require(ReplicatedStorage.Shared.Road.Pathfind)
local RoadGraph = require(ReplicatedStorage.Shared.Config.RoadGraph)
local Units = require(ReplicatedStorage.Shared.Util.Units)

local SEED = 20261019
local ROUTE_BUDGET_MS = 5 -- per route on the full county (PLAN.md Phase 2 acceptance)
local COUNTY_SOURCES = 12 -- Dijkstra runs on the county (each one is compared against many findPath targets)
local TARGETS_PER_SOURCE = 25
local FIXTURE_ROUTES = 300 -- random point-to-point routes on the fixture
local SAME = 1e-6 -- seconds or studs: equal within rounding
local ON_LINE = 1e-3 -- studs: a route point this close to a centre line is on it

-- A small graph where the fastest way is not the shortest: a -> h is 1,200 studs of 30 mph street straight
-- along the bottom, but the 70 mph highway through g (1,354 studs) is quicker. Apart from them, p - q is a
-- 1,200-stud lane at 10 mph with a 70 mph bypass through r, so between two points near either end of the lane
-- it is quicker to leave it and come back on. y1 - y2 is an island.
--
--   g (400, -300)            highway a-g-h
--   a ---- b ---- c ---- h    streets along z = 0
--   |      |      |
--   d ---- e ---- f           streets along z = 400
--   p ------------------ q    a slow lane along z = 1,600, well clear of the grid, bypassed by the
--                             highway p-r-q through r (600, 1800)
local FIXTURE_Y = 0.2
local SLOW_LANE_MPH = 10
local function fixtureNode(id: string, x: number, z: number): Graph.Node
	return { id = id, position = Vector3.new(x, FIXTURE_Y, z), zone = "cedar_bend" }
end
local function street(from: string, to: string): Graph.Edge
	return { from = from, to = to, lanes = 2, speedLimitMph = 30, surface = "asphalt", kind = "street" }
end
local function highway(from: string, to: string): Graph.Edge
	return { from = from, to = to, lanes = 4, speedLimitMph = 70, surface = "asphalt", kind = "highway" }
end

local fixture = Graph.fromData({
	fixtureNode("a", 0, 0),
	fixtureNode("b", 400, 0),
	fixtureNode("c", 800, 0),
	fixtureNode("h", 1200, 0),
	fixtureNode("d", 0, 400),
	fixtureNode("e", 400, 400),
	fixtureNode("f", 800, 400),
	fixtureNode("g", 400, -300),
	fixtureNode("p", 0, 1600),
	fixtureNode("q", 1200, 1600),
	fixtureNode("r", 600, 1800),
	fixtureNode("y1", 2000, 2000),
	fixtureNode("y2", 2300, 2000),
}, {
	street("a", "b"),
	street("b", "c"),
	street("c", "h"),
	street("a", "d"),
	street("d", "e"),
	street("e", "f"),
	street("f", "c"),
	street("b", "e"),
	highway("a", "g"),
	highway("g", "h"),
	{ from = "p", to = "q", lanes = 2, speedLimitMph = SLOW_LANE_MPH, surface = "dirt", kind = "street" },
	highway("p", "r"),
	highway("r", "q"),
	street("y1", "y2"),
})
local fixtureRouter = Pathfind.forGraph(fixture)

-- Seconds to drive edge `index` of `graph` at its limit (the cost the router minimises).
local function edgeSeconds(graph: Graph.Api, index: number): number
	return graph.edgeLength(index) / Units.mphToStuds(graph.edges()[index].speedLimitMph)
end

-- Plain Dijkstra (no heap, no heuristic): seconds from `source` to every node it reaches.
local function dijkstra(graph: Graph.Api, source: string): { [string]: number }
	local seconds: { [string]: number } = { [source] = 0 }
	local done: { [string]: boolean } = {}
	while true do
		local best: string? = nil
		local bestSeconds = math.huge
		for id, s in seconds do
			if not done[id] and s < bestSeconds then
				best, bestSeconds = id, s
			end
		end
		if best == nil then
			return seconds
		end
		done[best] = true
		for _, neighbor in graph.neighbors(best) do
			local s = bestSeconds + edgeSeconds(graph, neighbor.edge)
			if seconds[neighbor.node] == nil or s < seconds[neighbor.node] then
				seconds[neighbor.node] = s
			end
		end
	end
end

-- Seconds along a list of node ids, or nil if two neighbours in it are not joined by an edge.
local function pathSeconds(graph: Graph.Api, path: { string }): number?
	local total = 0
	for i = 2, #path do
		local best = math.huge
		for _, neighbor in graph.neighbors(path[i - 1]) do
			if neighbor.node == path[i] then
				best = math.min(best, edgeSeconds(graph, neighbor.edge))
			end
		end
		if best == math.huge then
			return nil
		end
		total += best
	end
	return total
end

-- Seconds of a route: the part of its start edge, the edges between its nodes, the part of its end edge.
local function routeSeconds(graph: Graph.Api, from: Vector3, to: Vector3, route: Pathfind.Route): number?
	local startEdge, startT = graph.nearestEdge(from)
	local endEdge, endT = graph.nearestEdge(to)
	if startEdge == nil or endEdge == nil then
		return nil
	end
	if #route.nodes == 0 then
		return math.abs(endT - startT) * edgeSeconds(graph, startEdge)
	end
	local function part(edgeIndex: number, t: number, nodeId: string): number?
		local edge = graph.edges()[edgeIndex]
		if edge.from == nodeId then
			return t * edgeSeconds(graph, edgeIndex)
		elseif edge.to == nodeId then
			return (1 - t) * edgeSeconds(graph, edgeIndex)
		end
		return nil
	end
	local first = part(startEdge, startT, route.nodes[1])
	local middle = pathSeconds(graph, route.nodes)
	local last = part(endEdge, endT, route.nodes[#route.nodes])
	if first == nil or middle == nil or last == nil then
		return nil
	end
	return first + middle + last
end

-- The fastest seconds between two points by brute force: every way off the start edge and onto the end edge.
local function bruteRouteSeconds(graph: Graph.Api, from: Vector3, to: Vector3): number?
	local startEdge, startT = graph.nearestEdge(from)
	local endEdge, endT = graph.nearestEdge(to)
	if startEdge == nil or endEdge == nil then
		return nil
	end
	-- Both on one edge: straight along it, unless a way off it and back on is quicker (checked below).
	local best: number? = if startEdge == endEdge then math.abs(endT - startT) * edgeSeconds(graph, startEdge) else nil
	local s, e = graph.edges()[startEdge], graph.edges()[endEdge]
	local starts = {
		{ id = s.from, seconds = startT * edgeSeconds(graph, startEdge) },
		{ id = s.to, seconds = (1 - startT) * edgeSeconds(graph, startEdge) },
	}
	local ends = {
		{ id = e.from, seconds = endT * edgeSeconds(graph, endEdge) },
		{ id = e.to, seconds = (1 - endT) * edgeSeconds(graph, endEdge) },
	}
	for _, start in starts do
		local reach = dijkstra(graph, start.id)
		for _, finish in ends do
			local between = reach[finish.id]
			if between then
				local total = start.seconds + between + finish.seconds
				if best == nil or total < best then
					best = total
				end
			end
		end
	end
	return best
end

local function sumLength(points: { Vector3 }): number
	local total = 0
	for i = 2, #points do
		total += (points[i] - points[i - 1]).Magnitude
	end
	return total
end

local function near(a: Vector3, b: Vector3): boolean
	return (a - b).Magnitude < ON_LINE
end

return function(t: Harness.Api)
	t.describe("Pathfind on a hand-made graph", function()
		t.it("takes the fastest way, not the shortest", function()
			t.expect(fixtureRouter.findPath("a", "h")).toEqual({ "a", "g", "h" })
			t.expect(fixtureRouter.findPath("h", "a")).toEqual({ "h", "g", "a" })
			t.expect(fixtureRouter.findPath("d", "f")).toEqual({ "d", "e", "f" })
		end)

		t.it("handles the same node, unknown nodes and unreachable ones", function()
			t.expect(fixtureRouter.findPath("a", "a")).toEqual({ "a" })
			t.expect(fixtureRouter.findPath("a", "nowhere")).toBe(nil)
			t.expect(fixtureRouter.findPath("nowhere", "a")).toBe(nil)
			t.expect(fixtureRouter.findPath("a", "y1")).toBe(nil)
			t.expect(fixtureRouter.findPath("y1", "y2")).toEqual({ "y1", "y2" })
		end)

		t.it("matches a brute-force Dijkstra between every pair of nodes", function()
			for _, source in fixture.nodes() do
				local reach = dijkstra(fixture, source.id)
				for _, target in fixture.nodes() do
					local path = fixtureRouter.findPath(source.id, target.id)
					local expected = reach[target.id]
					if expected == nil then
						t.expect(path).toBe(nil)
					else
						assert(path, `a path from {source.id} to {target.id}`)
						t.expect(path[1]).toBe(source.id)
						t.expect(path[#path]).toBe(target.id)
						t.expect(pathSeconds(fixture, path)).toBeNear(expected, SAME)
					end
				end
			end
		end)

		t.it("stays on one edge when both ends are on it", function()
			local route = fixtureRouter.route(Vector3.new(100, 0, 10), Vector3.new(300, 0, -10))
			assert(route, "a route along a - b")
			t.expect(#route.nodes).toBe(0)
			t.expect(#route.points).toBe(2)
			t.expect(near(route.points[1], Vector3.new(100, FIXTURE_Y, 0))).toBe(true)
			t.expect(near(route.points[2], Vector3.new(300, FIXTURE_Y, 0))).toBe(true)
			t.expect(route.length).toBeNear(200, SAME)
		end)

		t.it("goes round a slow edge by a faster road when both ends are on it", function()
			local route = fixtureRouter.route(Vector3.new(60, 0, 1590), Vector3.new(1140, 0, 1590))
			assert(route, "a route along p - q")
			t.expect(route.nodes).toEqual({ "p", "r", "q" })
			t.expect(near(route.points[1], Vector3.new(60, FIXTURE_Y, 1600))).toBe(true)
			t.expect(near(route.points[#route.points], Vector3.new(1140, FIXTURE_Y, 1600))).toBe(true)
		end)

		t.it("joins the road mid-edge and leaves it by the faster end, with no detour behind", function()
			-- From beside a - b (210 studs from a) to beside e - f: forward through b and e, never back to a.
			local route = fixtureRouter.route(Vector3.new(210, 0, 30), Vector3.new(590, 0, 420))
			assert(route, "a route from a - b to e - f")
			t.expect(route.nodes).toEqual({ "b", "e" })
			t.expect(near(route.points[1], Vector3.new(210, FIXTURE_Y, 0))).toBe(true)
			t.expect(near(route.points[#route.points], Vector3.new(590, FIXTURE_Y, 400))).toBe(true)
			t.expect(route.length).toBeNear(190 + 400 + 190, SAME)
		end)

		t.it("starts the way the car faces, going round the block instead of turning back", function()
			-- On b - c (590 studs from a), facing east, to beside a - d: without a heading it turns back through b;
			-- facing east it goes on to c and round by f and e (or the highway), never straight back down b - c.
			local from, to = Vector3.new(590, 0, 0), Vector3.new(0, 0, 200)
			local free = fixtureRouter.route(from, to)
			assert(free, "a route without a heading")
			t.expect(free.nodes[1]).toBe("b")
			local east = fixtureRouter.route(from, to, Vector3.new(1, 0, 0))
			assert(east, "a route facing east")
			t.expect(east.nodes[1]).toBe("c")
			t.expect(east.nodes[2] ~= "b").toBe(true)
			-- Facing west it is free to go back through b, as without a heading.
			local west = fixtureRouter.route(from, to, Vector3.new(-1, 0, 0))
			assert(west, "a route facing west")
			t.expect(west.nodes).toEqual(free.nodes)
			-- Facing across the road (out of a pad) either end will do.
			local across = fixtureRouter.route(from, to, Vector3.new(0, 0, 1))
			assert(across, "a route facing across")
			t.expect(across.nodes).toEqual(free.nodes)
			-- Both ends on one edge, the end behind: round the block, not a U-turn.
			local behind = fixtureRouter.route(Vector3.new(300, 0, 0), Vector3.new(100, 0, 0), Vector3.new(1, 0, 0))
			assert(behind, "a route to a point behind")
			t.expect(behind.nodes[1]).toBe("b")
			t.expect(behind.nodes[2] ~= "a").toBe(true)
			-- A dead end ahead (y1 - y2 has nowhere to go): turn round after all.
			local deadEnd =
				fixtureRouter.route(Vector3.new(2100, 0, 2000), Vector3.new(2050, 0, 2000), Vector3.new(1, 0, 0))
			assert(deadEnd, "a route out of a dead end")
			t.expect(#deadEnd.nodes).toBe(0)
		end)

		t.it("starts and ends cleanly on a node", function()
			local route = fixtureRouter.route(Vector3.new(0, 0, 0), Vector3.new(1200, 0, 0))
			assert(route, "a route from a to h")
			t.expect(route.nodes).toEqual({ "a", "g", "h" })
			t.expect(#route.points).toBe(3)
			for i = 2, #route.points do
				t.expect((route.points[i] - route.points[i - 1]).Magnitude).toBeGreaterThan(ON_LINE)
			end
		end)

		t.it("routes between random points as fast as a brute-force search, along the road", function()
			local random = Random.new(SEED)
			for _ = 1, FIXTURE_ROUTES do
				local from = Vector3.new(random:NextNumber(-100, 1300), 0, random:NextNumber(-400, 500))
				local to = Vector3.new(random:NextNumber(-100, 1300), 0, random:NextNumber(-400, 500))
				local route = fixtureRouter.route(from, to)
				assert(route, `a route from {from} to {to}`)
				local expected = bruteRouteSeconds(fixture, from, to)
				assert(expected, "brute force finds a way")
				t.expect(routeSeconds(fixture, from, to, route)).toBeNear(expected, SAME)
				t.expect(route.length).toBeNear(sumLength(route.points), SAME)
				for _, point in route.points do
					local _, _, distance = fixture.nearestEdge(point)
					t.expect(distance).toBeLessThan(ON_LINE)
				end
			end
		end)

		t.it("returns nil when the ends are on roads that never meet", function()
			t.expect(fixtureRouter.route(Vector3.new(100, 0, 0), Vector3.new(2100, 0, 2000))).toBe(nil)
		end)
	end)

	t.describe("Pathfind on the county", function()
		t.it("finds the same fastest paths as a brute-force Dijkstra", function()
			local random = Random.new(SEED + 1)
			local nodes = Graph.nodes()
			for _ = 1, COUNTY_SOURCES do
				local source = nodes[random:NextInteger(1, #nodes)]
				local reach = dijkstra(Graph, source.id)
				for _ = 1, TARGETS_PER_SOURCE do
					local target = nodes[random:NextInteger(1, #nodes)]
					local path = Pathfind.findPath(source.id, target.id)
					assert(path, `a path from {source.id} to {target.id}`)
					t.expect(pathSeconds(Graph, path)).toBeNear(reach[target.id], SAME)
				end
			end
		end)

		t.it("routes from the player spawn to every GPS destination along the road, each in under 5 ms", function()
			local spawn = MapLayout.playerSpawns[1]
			assert(spawn, "a player spawn")
			local from = spawn.Position
			local _, _, _, start = Graph.nearestEdge(from)
			local count, total, slowest, slowestId = 0, 0, 0, ""
			for _, location in MapLayout.locations do
				if location.gps then
					local started = os.clock()
					local route = Pathfind.route(from, location.position)
					local ms = (os.clock() - started) * 1000
					count += 1
					total += ms
					if ms > slowest then
						slowest, slowestId = ms, location.id
					end
					assert(route, `a route to {location.id}`)
					t.expect(#route.points >= 2).toBe(true)
					t.expect(near(route.points[1], start)).toBe(true)
					local finish = route.points[#route.points]
					local gap = Vector2.new(finish.X - location.position.X, finish.Z - location.position.Z).Magnitude
					t.expect(gap <= RoadGraph.roadReach).toBe(true)
					t.expect(route.length).toBeNear(sumLength(route.points), SAME)
					for _, point in route.points do
						t.expect(Graph.isOnRoad(point)).toBe(true)
					end
				end
			end
			print(
				`  Pathfind.route: {count} GPS destinations, max {string.format("%.3f", slowest)} ms ({slowestId}),`
					.. ` mean {string.format("%.3f", total / math.max(count, 1))} ms`
			)
			t.expect(count).toBeGreaterThan(0)
			t.expect(slowest).toBeLessThan(ROUTE_BUDGET_MS)
		end)

		t.it("follows the County Loop between neighbouring loop nodes", function()
			local ids = RoadGraph.loopNodeIds
			for i, id in ids do
				local nextId = ids[i % #ids + 1]
				t.expect(Pathfind.findPath(id, nextId)).toEqual({ id, nextId })
			end
		end)
	end)
end
