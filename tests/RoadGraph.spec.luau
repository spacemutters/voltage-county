--!strict
-- The county's road graph and map layout (Config/RoadGraph, Config/MapLayout) keep every rule in
-- docs/phase-2-contracts.md ("Data"), plus the layout rules MapBuilder relies on to build roads that never
-- overlap: roads that don't meet stay apart, junction angles stay wide, roads lie on the ground (or stand clear of
-- the water on the bridge), and pads sit beside roads, never on them. Then Road/Graph's queries are checked
-- against brute force over the same data. Pure logic: runs in Edit mode.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Graph = require(ReplicatedStorage.Shared.Road.Graph)
local Harness = require(ReplicatedStorage.Shared.Testing.Harness)
local MapLayout = require(ReplicatedStorage.Shared.Config.MapLayout)
local RoadGraph = require(ReplicatedStorage.Shared.Config.RoadGraph)
local World = require(ReplicatedStorage.Shared.Config.World)

local SEED = 20261019
local MAX_SHOWN = 12 -- problems printed when a check fails
local SAMPLE_STEP = 5 -- studs between height samples along an edge
local HEIGHT_TOLERANCE = 0.06 -- studs; the data is rounded (positions to 0.1, heights to 0.01)
-- Two roads closer than they should be are still fine when a short run of road joins them (the next-but-one
-- pieces of a curve or a cul-de-sac ring): the run is at most this many times the gap they needed.
local JOINED_RUN_FACTOR = 1.6
local FACING_MIN = 0.7 -- cosine: a pad's front points at its road within about 45 degrees
local NEAREST_SAMPLES = 600 -- random points for the nearest-road checks
local NEAR_ROAD_SAMPLES = 300 -- extra points scattered close to nodes, where several roads meet
local SAMPLE_REACH = 4000 -- random points fall in this square around the origin
local NEAREST_BUDGET_MS = 0.25 -- mean milliseconds per nearestEdge (Phase 3 calls it every second per driver)
local LEVEL = 0.01 -- studs: ground under a pad that varies less than this is level
local EPSILON = 1e-6

-- Tags that must appear, and the attributes each must carry (PLAN.md §5).
local TAG_ATTRIBUTES: { [string]: { string } } = {
	SpawnPad = {},
	ChargerStall = { "kW" },
	TruckCharger = {},
	FuelPump = { "rate" },
	Dealership = {},
	UsedLot = {},
	DesignStudio = {},
	JobDepot = { "jobType" },
	RideshareHotspot = {},
	HousePlot = {},
	MeetSpot = {},
	FlightZone = {},
	NoFlyZone = {},
	DragStripGate = { "index" },
	CustomShop = {},
	-- Phase 8: freight depots' trailer spots, the tow yard's drops and the towing job's breakdown spots.
	TrailerSpawn = { "depot", "trailer" },
	TowDrop = { "yard" },
	Breakdown = {},
}
-- Volumes and timing gates may span roads; every other location is a pad beside one.
local SPANS_ROADS: { [string]: boolean } = { FlightZone = true, NoFlyZone = true, DragStripGate = true }
local DRAG_GATES = 4

type Problems = { string }

local function report(t: Harness.Api, problems: Problems)
	for i = 1, math.min(#problems, MAX_SHOWN) do
		print(`  {problems[i]}`)
	end
	if #problems > MAX_SHOWN then
		print(`  ... and {#problems - MAX_SHOWN} more`)
	end
	t.expect(#problems).toBe(0)
end

local function fmt(n: number): string
	return string.format("%.1f", n)
end

-- Geometry on the ground plane (x, z).

local function pointSegment(px: number, pz: number, ax: number, az: number, bx: number, bz: number): (number, number)
	local dx, dz = bx - ax, bz - az
	local lengthSquared = dx * dx + dz * dz
	local t = if lengthSquared > 0 then math.clamp(((px - ax) * dx + (pz - az) * dz) / lengthSquared, 0, 1) else 0
	local ox, oz = ax + dx * t - px, az + dz * t - pz
	return math.sqrt(ox * ox + oz * oz), t
end

local function orient(ax: number, az: number, bx: number, bz: number, cx: number, cz: number): number
	return (bx - ax) * (cz - az) - (bz - az) * (cx - ax)
end

-- Whether two segments properly cross (each one's ends on opposite sides of the other).
local function segmentsCross(a: Vector2, b: Vector2, c: Vector2, d: Vector2): boolean
	local o1 = orient(a.X, a.Y, b.X, b.Y, c.X, c.Y)
	local o2 = orient(a.X, a.Y, b.X, b.Y, d.X, d.Y)
	local o3 = orient(c.X, c.Y, d.X, d.Y, a.X, a.Y)
	local o4 = orient(c.X, c.Y, d.X, d.Y, b.X, b.Y)
	return o1 * o2 < 0 and o3 * o4 < 0
end

-- Where the lines through a-b and c-d meet, as fractions along each (the middles when they are parallel).
local function crossingAt(a: Vector2, b: Vector2, c: Vector2, d: Vector2): (number, number)
	local ab, cd, ac = b - a, d - c, c - a
	local denominator = ab.X * cd.Y - ab.Y * cd.X
	if math.abs(denominator) < EPSILON then
		return 0.5, 0.5
	end
	local along1 = (ac.X * cd.Y - ac.Y * cd.X) / denominator
	local along2 = (ac.X * ab.Y - ac.Y * ab.X) / denominator
	return math.clamp(along1, 0, 1), math.clamp(along2, 0, 1)
end

local function segmentDistance(a: Vector2, b: Vector2, c: Vector2, d: Vector2): number
	if segmentsCross(a, b, c, d) then
		return 0
	end
	return math.min(
		(pointSegment(a.X, a.Y, c.X, c.Y, d.X, d.Y)),
		(pointSegment(b.X, b.Y, c.X, c.Y, d.X, d.Y)),
		(pointSegment(c.X, c.Y, a.X, a.Y, b.X, b.Y)),
		(pointSegment(d.X, d.Y, a.X, a.Y, b.X, b.Y))
	)
end

-- Footprint corners (on the ground plane) of a part of `size` standing at `position` turned by `yaw` degrees.
local function footprint(position: Vector3, yaw: number, size: Vector3): { Vector2 }
	local frame = CFrame.new(position) * CFrame.Angles(0, math.rad(yaw), 0)
	local corners = {}
	for _, corner in { { -1, -1 }, { 1, -1 }, { 1, 1 }, { -1, 1 } } do
		local p = frame:PointToWorldSpace(Vector3.new(corner[1] * size.X / 2, 0, corner[2] * size.Z / 2))
		table.insert(corners, Vector2.new(p.X, p.Z))
	end
	return corners
end

local function insideConvex(p: Vector2, polygon: { Vector2 }): boolean
	local sign = 0
	for i, a in polygon do
		local b = polygon[i % #polygon + 1]
		local o = orient(a.X, a.Y, b.X, b.Y, p.X, p.Y)
		if o ~= 0 then
			local s = if o > 0 then 1 else -1
			if sign == 0 then
				sign = s
			elseif s ~= sign then
				return false
			end
		end
	end
	return true
end

local function polygonSegmentDistance(polygon: { Vector2 }, a: Vector2, b: Vector2): number
	if insideConvex(a, polygon) or insideConvex(b, polygon) then
		return 0
	end
	local best = math.huge
	for i, p in polygon do
		best = math.min(best, segmentDistance(p, polygon[i % #polygon + 1], a, b))
	end
	return best
end

local function polygonsDistance(p1: { Vector2 }, p2: { Vector2 }): number
	for _, corner in p1 do
		if insideConvex(corner, p2) then
			return 0
		end
	end
	for _, corner in p2 do
		if insideConvex(corner, p1) then
			return 0
		end
	end
	local best = math.huge
	for i, a in p1 do
		best = math.min(best, polygonSegmentDistance(p2, a, p1[i % #p1 + 1]))
	end
	return best
end

local function rectDistance(p: Vector2, min: Vector2, max: Vector2): number
	local dx = math.max(min.X - p.X, 0, p.X - max.X)
	local dz = math.max(min.Y - p.Y, 0, p.Y - max.Y)
	return math.sqrt(dx * dx + dz * dz)
end

-- The road data, indexed.

type RoadEdge = {
	index: number,
	edge: RoadGraph.Edge,
	a: Vector3,
	b: Vector3,
	a2: Vector2,
	b2: Vector2,
	halfWidth: number,
	corridor: number, -- half the width including sidewalks
	minX: number,
	maxX: number,
	minZ: number,
	maxZ: number,
}

local nodeById: { [string]: RoadGraph.Node } = {}
for _, node in RoadGraph.nodes do
	nodeById[node.id] = node
end

local roads: { RoadEdge } = {}
for i, edge in RoadGraph.edges do
	local a, b = nodeById[edge.from], nodeById[edge.to]
	if a and b then
		local style = RoadGraph.styles[edge.kind]
		local halfWidth = edge.lanes * World.laneWidth / 2 + style.shoulder
		local corridor = halfWidth + style.sidewalk
		table.insert(roads, {
			index = i,
			edge = edge,
			a = a.position,
			b = b.position,
			a2 = Vector2.new(a.position.X, a.position.Z),
			b2 = Vector2.new(b.position.X, b.position.Z),
			halfWidth = halfWidth,
			corridor = corridor,
			minX = math.min(a.position.X, b.position.X) - corridor,
			maxX = math.max(a.position.X, b.position.X) + corridor,
			minZ = math.min(a.position.Z, b.position.Z) - corridor,
			maxZ = math.max(a.position.Z, b.position.Z) + corridor,
		})
	end
end

-- The County Loop's edges (consecutive loopNodeIds, closed) and the zone its nodes carry.
local loopEdges: { [string]: boolean } = {}
for i, id in RoadGraph.loopNodeIds do
	local nextId = RoadGraph.loopNodeIds[i % #RoadGraph.loopNodeIds + 1]
	loopEdges[`{id}|{nextId}`] = true
	loopEdges[`{nextId}|{id}`] = true
end
local loopStart = nodeById[RoadGraph.loopNodeIds[1]]
local LOOP_ZONE = if loopStart then loopStart.zone else ""

local function isLoopEdge(edge: RoadGraph.Edge): boolean
	return loopEdges[`{edge.from}|{edge.to}`] == true
end

local function shareNode(r1: RoadEdge, r2: RoadEdge): boolean
	local e1, e2 = r1.edge, r2.edge
	return e1.from == e2.from or e1.from == e2.to or e1.to == e2.from or e1.to == e2.to
end

local function boxesNear(r1: RoadEdge, r2: RoadEdge, margin: number): boolean
	return r1.minX - margin <= r2.maxX
		and r2.minX - margin <= r1.maxX
		and r1.minZ - margin <= r2.maxZ
		and r2.minZ - margin <= r1.maxZ
end

-- Adjacency for walking the roads (node id -> { neighbour id, length }).
local links: { [string]: { { to: string, length: number } } } = {}
for _, node in RoadGraph.nodes do
	links[node.id] = {}
end
for _, road in roads do
	local length = (road.b2 - road.a2).Magnitude
	table.insert(links[road.edge.from], { to = road.edge.to, length = length })
	table.insert(links[road.edge.to], { to = road.edge.from, length = length })
end

-- Shortest run of road (horizontal length) from any of `starts` to any of `goals`, if it is at most `limit`.
local function roadRun(starts: { string }, goals: { [string]: boolean }, limit: number): number?
	local best: { [string]: number } = {}
	local open: { string } = {}
	for _, id in starts do
		best[id] = 0
		table.insert(open, id)
	end
	while #open > 0 do
		-- Few nodes are ever open (the limit is short), so a linear pick of the nearest is fine.
		local pick, pickIndex = open[1], 1
		for i, id in open do
			if best[id] < best[pick] then
				pick, pickIndex = id, i
			end
		end
		table.remove(open, pickIndex)
		if goals[pick] then
			return best[pick]
		end
		for _, link in links[pick] do
			local run = best[pick] + link.length
			if run <= limit and (best[link.to] == nil or run < best[link.to]) then
				if best[link.to] == nil then
					table.insert(open, link.to)
				end
				best[link.to] = run
			end
		end
	end
	return nil
end

local function surfaceAt(road: RoadEdge, t: number): number
	return road.a.Y + (road.b.Y - road.a.Y) * t
end

local function onBridgeEdge(): { [string]: boolean }
	local set = {}
	for _, road in roads do
		if road.edge.kind == "bridge" then
			set[road.edge.from] = true
			set[road.edge.to] = true
		end
	end
	return set
end

-- Brute-force nearest road to a point.
local function bruteNearest(p: Vector3): (RoadEdge?, number, number)
	local best: RoadEdge? = nil
	local bestDistance, bestT = math.huge, 0
	for _, road in roads do
		local d, t = pointSegment(p.X, p.Z, road.a2.X, road.a2.Y, road.b2.X, road.b2.Y)
		if d < bestDistance then
			best, bestDistance, bestT = road, d, t
		end
	end
	return best, bestDistance, bestT
end

local function areaZoneAt(p: Vector3): string?
	for _, id in MapLayout.zoneOrder do
		local zone = MapLayout.zones[id]
		if id ~= LOOP_ZONE and zone then
			if p.X >= zone.min.X and p.X <= zone.max.X and p.Z >= zone.min.Y and p.Z <= zone.max.Y then
				return id
			end
		end
	end
	return nil
end

-- Vector3 components are 32-bit floats: positions out to ~5,000 studs are only exact to ~5e-4.
local NEAREST_TOLERANCE = 1e-3

return function(t: Harness.Api)
	t.describe("RoadGraph data", function()
		t.it("has unique node ids and edges that join two different, existing nodes, once each", function()
			local problems: Problems = {}
			local seen: { [string]: boolean } = {}
			for _, node in RoadGraph.nodes do
				if seen[node.id] then
					table.insert(problems, `node id {node.id} is used twice`)
				end
				seen[node.id] = true
			end
			local joined: { [string]: boolean } = {}
			for i, edge in RoadGraph.edges do
				if nodeById[edge.from] == nil or nodeById[edge.to] == nil then
					table.insert(problems, `edge {i} ({edge.from} - {edge.to}) names a missing node`)
				end
				if edge.from == edge.to then
					table.insert(problems, `edge {i} joins {edge.from} to itself`)
				end
				local key = if edge.from < edge.to then `{edge.from}|{edge.to}` else `{edge.to}|{edge.from}`
				if joined[key] then
					table.insert(problems, `edge {edge.from} - {edge.to} is listed twice`)
				end
				joined[key] = true
				if RoadGraph.styles[edge.kind] == nil then
					table.insert(problems, `edge {edge.from} - {edge.to} has unknown kind {edge.kind}`)
				end
				if edge.lanes <= 0 or edge.speedLimitMph <= 0 then
					table.insert(problems, `edge {edge.from} - {edge.to} needs lanes and a speed limit`)
				end
			end
			report(t, problems)
		end)

		t.it("is one connected graph", function()
			local reached: { [string]: boolean } = {}
			local first = RoadGraph.nodes[1]
			t.expect(first ~= nil).toBe(true)
			local stack = { first.id }
			reached[first.id] = true
			local count = 1
			while #stack > 0 do
				local id = table.remove(stack) :: string
				for _, link in links[id] do
					if not reached[link.to] then
						reached[link.to] = true
						count += 1
						table.insert(stack, link.to)
					end
				end
			end
			local problems: Problems = {}
			for _, node in RoadGraph.nodes do
				if not reached[node.id] then
					table.insert(problems, `{node.id} can't be reached from {first.id}`)
				end
			end
			report(t, problems)
			t.expect(count).toBe(#RoadGraph.nodes)
		end)

		t.it("never crosses edges except at a shared node, unless a bridge clears the other road", function()
			local problems: Problems = {}
			local clearance = RoadGraph.rules.bridgeClearance
			for i = 1, #roads do
				local r1 = roads[i]
				for j = i + 1, #roads do
					local r2 = roads[j]
					if boxesNear(r1, r2, 0) and not shareNode(r1, r2) then
						local touching = segmentDistance(r1.a2, r1.b2, r2.a2, r2.b2) < EPSILON
						if touching then
							local bridge = r1.edge.kind == "bridge" or r2.edge.kind == "bridge"
							-- Heights of both roads where they cross.
							local t1, t2 = crossingAt(r1.a2, r1.b2, r2.a2, r2.b2)
							local gap = math.abs(surfaceAt(r1, t1) - surfaceAt(r2, t2))
							if not bridge or gap < clearance then
								table.insert(
									problems,
									`{r1.edge.from}-{r1.edge.to} crosses {r2.edge.from}-{r2.edge.to}`
										.. ` ({fmt(gap)} studs apart)`
								)
							end
						end
					end
				end
			end
			report(t, problems)
		end)

		t.it("keeps roads that do not meet apart, sidewalks and all", function()
			local problems: Problems = {}
			local gap = RoadGraph.rules.roadGap
			for i = 1, #roads do
				local r1 = roads[i]
				for j = i + 1, #roads do
					local r2 = roads[j]
					local needed = r1.corridor + r2.corridor + gap
					if boxesNear(r1, r2, gap) and not shareNode(r1, r2) then
						local distance = segmentDistance(r1.a2, r1.b2, r2.a2, r2.b2)
						-- A bridge passing over a road is the crossing check's business, not this one's.
						local overpass = r1.edge.kind == "bridge" or r2.edge.kind == "bridge"
						if distance < needed and not (overpass and distance < EPSILON) then
							local run = roadRun(
								{ r1.edge.from, r1.edge.to },
								{ [r2.edge.from] = true, [r2.edge.to] = true },
								JOINED_RUN_FACTOR * needed
							)
							if run == nil then
								table.insert(
									problems,
									`{r1.edge.from}-{r1.edge.to} and {r2.edge.from}-{r2.edge.to} are {fmt(distance)}`
										.. ` studs apart (need {fmt(needed)})`
								)
							end
						end
					end
				end
			end
			report(t, problems)
		end)

		t.it("meets other roads at wide enough angles", function()
			local problems: Problems = {}
			local minimum = math.rad(RoadGraph.rules.minJunctionAngle)
			for _, node in RoadGraph.nodes do
				local list = links[node.id]
				for i = 1, #list do
					for j = i + 1, #list do
						local a = nodeById[list[i].to].position - node.position
						local b = nodeById[list[j].to].position - node.position
						local flatA, flatB = Vector2.new(a.X, a.Z).Unit, Vector2.new(b.X, b.Z).Unit
						local angle = math.acos(math.clamp(flatA:Dot(flatB), -1, 1))
						if angle < minimum then
							table.insert(
								problems,
								`{list[i].to} and {list[j].to} leave {node.id} {fmt(math.deg(angle))} degrees apart`
							)
						end
					end
				end
			end
			report(t, problems)
		end)

		t.it("keeps grades and edge lengths within the limits", function()
			local problems: Problems = {}
			local rules = RoadGraph.rules
			for _, road in roads do
				local run = (road.b2 - road.a2).Magnitude
				local rise = math.abs(road.b.Y - road.a.Y)
				local limit = if road.edge.kind == "dirt" then rules.maxTrailGrade else rules.maxGrade
				if run <= 0 or rise / run > limit + EPSILON then
					table.insert(problems, `{road.edge.from}-{road.edge.to} grade {rise / run} > {limit}`)
				end
				if (road.b - road.a).Magnitude > rules.maxEdgeLength then
					table.insert(problems, `{road.edge.from}-{road.edge.to} is longer than {rules.maxEdgeLength}`)
				end
			end
			report(t, problems)
		end)

		t.it("closes the County Loop with highway edges, and uses highway edges only there", function()
			local problems: Problems = {}
			local ids = RoadGraph.loopNodeIds
			t.expect(#ids >= 3).toBe(true)
			local seen: { [string]: boolean } = {}
			for _, id in ids do
				if seen[id] then
					table.insert(problems, `loop visits {id} twice`)
				end
				seen[id] = true
			end
			local found: { [string]: boolean } = {}
			for _, road in roads do
				local key = `{road.edge.from}|{road.edge.to}`
				if loopEdges[key] then
					found[key] = true
					found[`{road.edge.to}|{road.edge.from}`] = true
					if road.edge.kind ~= "highway" then
						table.insert(problems, `loop edge {key} is a {road.edge.kind}`)
					end
				elseif road.edge.kind == "highway" then
					table.insert(problems, `highway edge {key} is not on the loop`)
				end
			end
			for i, id in ids do
				local nextId = ids[i % #ids + 1]
				if not found[`{id}|{nextId}`] then
					table.insert(problems, `no edge between loop nodes {id} and {nextId}`)
				end
			end
			report(t, problems)
		end)

		t.it("stays inside the map and leaves the dev track's ground to the County Loop", function()
			local problems: Problems = {}
			local limit = World.mapHalfExtent
			for _, road in roads do
				if road.minX < -limit or road.maxX > limit or road.minZ < -limit or road.maxZ > limit then
					table.insert(problems, `{road.edge.from}-{road.edge.to} leaves the map`)
				end
				if road.minX < MapLayout.reservedWestOfX and not isLoopEdge(road.edge) then
					table.insert(problems, `{road.edge.from}-{road.edge.to} reaches into the dev track's ground`)
				end
			end
			report(t, problems)
		end)

		t.it("lays every road on the ground, except the bridge, which stands clear of the water", function()
			local problems: Problems = {}
			local above = RoadGraph.rules.surfaceAboveGround
			local bridgeNodes = onBridgeEdge()
			for _, node in RoadGraph.nodes do
				local ground = MapLayout.groundHeight(node.position.X, node.position.Z)
				if not bridgeNodes[node.id] and math.abs(node.position.Y - (ground + above)) > HEIGHT_TOLERANCE then
					table.insert(problems, `{node.id} is at y {node.position.Y}, the ground there is {fmt(ground)}`)
				end
			end
			for _, road in roads do
				local bridge = road.edge.kind == "bridge"
				local steps = math.max(1, math.ceil((road.b2 - road.a2).Magnitude / SAMPLE_STEP))
				for step = 0, steps do
					local f = step / steps
					local p = road.a:Lerp(road.b, f)
					local ground = MapLayout.groundHeight(p.X, p.Z)
					local where = `{road.edge.from}-{road.edge.to} at {math.floor(f * 100)}%`
					if bridge then
						if p.Y < ground + above - HEIGHT_TOLERANCE then
							table.insert(problems, `{where} is under the ground`)
						end
					elseif math.abs(p.Y - (ground + above)) > HEIGHT_TOLERANCE then
						table.insert(problems, `{where} is at y {fmt(p.Y)}, the ground there is {fmt(ground)}`)
						break
					end
					for _, lake in MapLayout.lakes do
						local distance = rectDistance(Vector2.new(p.X, p.Z), lake.min, lake.max)
						if bridge then
							if distance == 0 and p.Y - lake.waterY < RoadGraph.rules.bridgeClearance then
								table.insert(problems, `{where} is only {fmt(p.Y - lake.waterY)} over {lake.id}`)
							end
						elseif distance < road.corridor then
							table.insert(problems, `{where} runs into {lake.id}`)
							break
						end
					end
				end
			end
			report(t, problems)
		end)

		t.it("crosses every lake on a bridge", function()
			for _, lake in MapLayout.lakes do
				local crossings = 0
				for _, road in roads do
					local middle = (road.a2 + road.b2) / 2
					if road.edge.kind == "bridge" and rectDistance(middle, lake.min, lake.max) == 0 then
						crossings += 1
					end
				end
				t.expect(crossings).toBeGreaterThan(0)
			end
		end)

		t.it("gives every node a MapLayout zone", function()
			local problems: Problems = {}
			for _, node in RoadGraph.nodes do
				if MapLayout.zones[node.zone] == nil then
					table.insert(problems, `{node.id} has unknown zone {node.zone}`)
				end
			end
			report(t, problems)
		end)
	end)

	t.describe("MapLayout", function()
		t.it("lists every zone once in zoneOrder, under its own id, without overlapping areas", function()
			local listed: { [string]: boolean } = {}
			for _, id in MapLayout.zoneOrder do
				t.expect(listed[id]).toBe(nil)
				listed[id] = true
				t.expect(MapLayout.zones[id] ~= nil).toBe(true)
			end
			for id, zone in MapLayout.zones do
				t.expect(zone.id).toBe(id)
				t.expect(listed[id]).toBe(true)
				t.expect(zone.min.X < zone.max.X and zone.min.Y < zone.max.Y).toBe(true)
				t.expect(zone.buildingDensity >= 0 and zone.buildingDensity <= 1).toBe(true)
				t.expect(zone.buildingHeight.min <= zone.buildingHeight.max).toBe(true)
			end
			t.expect(MapLayout.zones[LOOP_ZONE] ~= nil).toBe(true)
			local order = MapLayout.zoneOrder
			for i = 1, #order do
				for j = i + 1, #order do
					local a, b = MapLayout.zones[order[i]], MapLayout.zones[order[j]]
					if a.id ~= LOOP_ZONE and b.id ~= LOOP_ZONE then
						local overlap = a.min.X < b.max.X
							and b.min.X < a.max.X
							and a.min.Y < b.max.Y
							and b.min.Y < a.max.Y
						t.expect(overlap).toBe(false)
					end
				end
			end
		end)

		t.it("gives every location a unique id, a known tag and zone, and a place in the map", function()
			local problems: Problems = {}
			local seen: { [string]: boolean } = {}
			local limit = World.mapHalfExtent
			for _, location in MapLayout.locations do
				if seen[location.id] then
					table.insert(problems, `location id {location.id} is used twice`)
				end
				seen[location.id] = true
				if TAG_ATTRIBUTES[location.tag] == nil then
					table.insert(problems, `{location.id} has unknown tag {location.tag}`)
				end
				if MapLayout.zones[location.zone] == nil then
					table.insert(problems, `{location.id} has unknown zone {location.zone}`)
				end
				if location.displayName == "" then
					table.insert(problems, `{location.id} has no display name`)
				end
				for _, corner in footprint(location.position, location.yaw, location.size) do
					if math.abs(corner.X) > limit or math.abs(corner.Y) > limit then
						table.insert(problems, `{location.id} leaves the map`)
					elseif corner.X < MapLayout.reservedWestOfX then
						table.insert(problems, `{location.id} is on the dev track's ground`)
					end
				end
			end
			report(t, problems)
		end)

		t.it("puts every location within roadReach of a road", function()
			local problems: Problems = {}
			for _, location in MapLayout.locations do
				local _, distance = bruteNearest(location.position)
				if distance > RoadGraph.roadReach then
					table.insert(problems, `{location.id} is {fmt(distance)} studs from the nearest road`)
				end
			end
			report(t, problems)
		end)

		t.it("keeps pads off every road and sidewalk, on level ground, facing their road", function()
			local problems: Problems = {}
			for _, location in MapLayout.locations do
				if not SPANS_ROADS[location.tag] then
					local corners = footprint(location.position, location.yaw, location.size)
					for _, road in roads do
						local clearance = road.corridor + MapLayout.padClearance
						local distance = polygonSegmentDistance(corners, road.a2, road.b2)
						if distance < clearance then
							table.insert(
								problems,
								`{location.id} is {fmt(distance)} from {road.edge.from}-{road.edge.to} (needs {clearance})`
							)
						end
					end
					local ground = MapLayout.groundHeight(location.position.X, location.position.Z)
					for _, corner in corners do
						if math.abs(MapLayout.groundHeight(corner.X, corner.Y) - ground) > LEVEL then
							table.insert(problems, `{location.id} straddles uneven ground`)
							break
						end
					end
					if math.abs(location.position.Y - ground) > LEVEL then
						table.insert(problems, `{location.id} is at y {location.position.Y}, the ground is {ground}`)
					end
					local road, _, along = bruteNearest(location.position)
					if road then
						local onRoad = road.a2:Lerp(road.b2, along)
						local toRoad = onRoad - Vector2.new(location.position.X, location.position.Z)
						local yaw = math.rad(location.yaw)
						local front = Vector2.new(-math.sin(yaw), -math.cos(yaw))
						if toRoad.Magnitude > 0 and front:Dot(toRoad.Unit) < FACING_MIN then
							table.insert(problems, `{location.id} does not face its road`)
						end
					end
				end
			end
			report(t, problems)
		end)

		t.it("never overlaps two pads", function()
			local problems: Problems = {}
			local pads = {}
			for _, location in MapLayout.locations do
				if not SPANS_ROADS[location.tag] then
					table.insert(
						pads,
						{ location = location, corners = footprint(location.position, location.yaw, location.size) }
					)
				end
			end
			for i = 1, #pads do
				for j = i + 1, #pads do
					if polygonsDistance(pads[i].corners, pads[j].corners) < MapLayout.padClearance then
						table.insert(problems, `{pads[i].location.id} overlaps {pads[j].location.id}`)
					end
				end
			end
			report(t, problems)
		end)

		t.it("uses every tag at least once, with its attributes", function()
			local problems: Problems = {}
			local used: { [string]: number } = {}
			local gates: { [number]: number } = {}
			for _, location in MapLayout.locations do
				used[location.tag] = (used[location.tag] or 0) + 1
				local attributes: { [string]: any } = location.attributes or {}
				local required: { string } = TAG_ATTRIBUTES[location.tag] or {}
				for _, name in required do
					if attributes[name] == nil then
						table.insert(problems, `{location.id} ({location.tag}) has no {name}`)
					end
				end
				if location.tag == "ChargerStall" or location.tag == "TruckCharger" then
					local kW = attributes.kW
					if kW ~= nil and (type(kW) ~= "number" or kW <= 0) then
						table.insert(problems, `{location.id} kW must be a positive number`)
					end
				elseif location.tag == "FuelPump" then
					if type(attributes.rate) ~= "number" or attributes.rate <= 0 then
						table.insert(problems, `{location.id} rate must be a positive number`)
					end
				elseif location.tag == "JobDepot" then
					if type(attributes.jobType) ~= "string" or attributes.jobType == "" then
						table.insert(problems, `{location.id} jobType must be a name`)
					end
				elseif location.tag == "DragStripGate" then
					local index = attributes.index
					if type(index) == "number" then
						gates[index] = (gates[index] or 0) + 1
					end
				end
			end
			for tag in TAG_ATTRIBUTES do
				if used[tag] == nil then
					table.insert(problems, `no location is tagged {tag}`)
				end
			end
			for index = 1, DRAG_GATES do
				if gates[index] ~= 1 then
					table.insert(problems, `drag strip gate {index} appears {gates[index] or 0} times`)
				end
			end
			report(t, problems)
		end)

		t.it("names the zone each location is in", function()
			local problems: Problems = {}
			for _, location in MapLayout.locations do
				local area = areaZoneAt(location.position)
				if location.zone == LOOP_ZONE then
					if area ~= nil then
						table.insert(problems, `{location.id} is in {area} but says {location.zone}`)
					end
				elseif area ~= location.zone then
					table.insert(problems, `{location.id} is in {area or "open country"} but says {location.zone}`)
				end
				if Graph.zoneAt(location.position) ~= location.zone then
					table.insert(problems, `Graph.zoneAt puts {location.id} in {Graph.zoneAt(location.position)}`)
				end
			end
			report(t, problems)
		end)

		t.it("has a GPS destination in every zone", function()
			local destinations: { [string]: number } = {}
			for _, location in MapLayout.locations do
				if location.gps then
					destinations[location.zone] = (destinations[location.zone] or 0) + 1
				end
			end
			for id in MapLayout.zones do
				t.expect(destinations[id] or 0).toBeGreaterThan(0)
			end
		end)

		t.it("puts the player spawns on the used lot, on the ground", function()
			local lot: MapLayout.Location? = nil
			for _, location in MapLayout.locations do
				if location.tag == "UsedLot" then
					lot = location
				end
			end
			assert(lot, "a location is tagged UsedLot")
			local corners = footprint(lot.position, lot.yaw, lot.size)
			t.expect(#MapLayout.playerSpawns).toBeGreaterThan(0)
			for _, spawn in MapLayout.playerSpawns do
				local p = spawn.Position
				t.expect(insideConvex(Vector2.new(p.X, p.Z), corners)).toBe(true)
				t.expect(p.Y).toBeNear(MapLayout.groundHeight(p.X, p.Z), LEVEL)
			end
		end)

		t.it("keeps jump ramps and landmarks off roads, pads and each other, on level ground", function()
			local problems: Problems = {}
			local things: { { id: string, position: Vector3, yaw: number, size: Vector3 } } = {}
			for _, ramp in MapLayout.jumpRamps do
				table.insert(things, { id = ramp.id, position = ramp.position, yaw = ramp.yaw, size = ramp.size })
			end
			for _, landmark in MapLayout.landmarks do
				table.insert(things, {
					id = landmark.id,
					position = landmark.position,
					yaw = landmark.yaw,
					size = landmark.size,
				})
			end
			local pads = {}
			for _, location in MapLayout.locations do
				if not SPANS_ROADS[location.tag] then
					table.insert(
						pads,
						{ id = location.id, corners = footprint(location.position, location.yaw, location.size) }
					)
				end
			end
			local shapes = {}
			for _, thing in things do
				local corners = footprint(thing.position, thing.yaw, thing.size)
				table.insert(shapes, corners)
				for _, road in roads do
					if polygonSegmentDistance(corners, road.a2, road.b2) < road.corridor + RoadGraph.rules.roadGap then
						table.insert(problems, `{thing.id} is on road {road.edge.from}-{road.edge.to}`)
					end
				end
				for _, pad in pads do
					if polygonsDistance(corners, pad.corners) < MapLayout.padClearance then
						table.insert(problems, `{thing.id} overlaps {pad.id}`)
					end
				end
				local ground = MapLayout.groundHeight(thing.position.X, thing.position.Z)
				if math.abs(thing.position.Y - ground) > LEVEL then
					table.insert(problems, `{thing.id} is not on the ground`)
				end
				for _, corner in corners do
					if math.abs(MapLayout.groundHeight(corner.X, corner.Y) - ground) > LEVEL then
						table.insert(problems, `{thing.id} straddles uneven ground`)
						break
					end
				end
			end
			for i = 1, #shapes do
				for j = i + 1, #shapes do
					if polygonsDistance(shapes[i], shapes[j]) < MapLayout.padClearance then
						table.insert(problems, `{things[i].id} overlaps {things[j].id}`)
					end
				end
			end
			report(t, problems)
		end)
	end)

	t.describe("Graph", function()
		t.it("looks up nodes, edges and neighbours as the config lists them", function()
			t.expect(#Graph.nodes()).toBe(#RoadGraph.nodes)
			t.expect(#Graph.edges()).toBe(#RoadGraph.edges)
			for _, node in RoadGraph.nodes do
				t.expect(Graph.node(node.id)).toBe(node)
				local neighbors = Graph.neighbors(node.id)
				t.expect(#neighbors).toBe(#links[node.id])
				for _, neighbor in neighbors do
					local edge = Graph.edges()[neighbor.edge]
					local joins = (edge.from == node.id and edge.to == neighbor.node)
						or (edge.to == node.id and edge.from == neighbor.node)
					t.expect(joins).toBe(true)
				end
			end
			t.expect(Graph.node("no such node")).toBe(nil)
			t.expect(#Graph.neighbors("no such node")).toBe(0)
		end)

		t.it("measures each edge's width and length", function()
			for _, road in roads do
				t.expect(Graph.edgeWidth(road.index)).toBeNear(2 * road.halfWidth, EPSILON)
				t.expect(Graph.edgeLength(road.index)).toBeNear((road.b - road.a).Magnitude, EPSILON)
				t.expect((Graph.pointOnEdge(road.index, 0.5) - road.a:Lerp(road.b, 0.5)).Magnitude).toBeNear(0, EPSILON)
			end
		end)

		t.it("finds the same nearest edge and node as a brute-force search", function()
			local random = Random.new(SEED)
			local points: { Vector3 } = {}
			for _ = 1, NEAREST_SAMPLES do
				local x = random:NextNumber(-SAMPLE_REACH, SAMPLE_REACH)
				local z = random:NextNumber(-SAMPLE_REACH, SAMPLE_REACH)
				table.insert(points, Vector3.new(x, 0, z))
			end
			for _ = 1, NEAR_ROAD_SAMPLES do
				local node = RoadGraph.nodes[random:NextInteger(1, #RoadGraph.nodes)]
				local offset = Vector3.new(random:NextNumber(-40, 40), 0, random:NextNumber(-40, 40))
				table.insert(points, node.position + offset)
			end
			local problems: Problems = {}
			for _, p in points do
				local index, along, distance, point = Graph.nearestEdge(p)
				local _, bruteDistance = bruteNearest(p)
				if index == nil or math.abs(distance - bruteDistance) > NEAREST_TOLERANCE then
					table.insert(problems, `nearestEdge at {p}: {distance} vs brute force {bruteDistance}`)
				else
					local expected = Graph.pointOnEdge(index, along)
					local flatGap = Vector2.new(point.X - p.X, point.Z - p.Z).Magnitude
					if
						(expected - point).Magnitude > NEAREST_TOLERANCE
						or math.abs(flatGap - distance) > NEAREST_TOLERANCE
					then
						table.insert(problems, `nearestEdge at {p} returned an inconsistent point`)
					end
				end
				local id, nodeDistance = Graph.nearestNode(p)
				local bruteNode = math.huge
				for _, node in RoadGraph.nodes do
					bruteNode = math.min(bruteNode, Vector2.new(node.position.X - p.X, node.position.Z - p.Z).Magnitude)
				end
				if id == nil or math.abs(nodeDistance - bruteNode) > NEAREST_TOLERANCE then
					table.insert(problems, `nearestNode at {p}: {nodeDistance} vs brute force {bruteNode}`)
				end
			end
			report(t, problems)
		end)

		t.it("tells on-road from off-road the way a brute-force search does", function()
			local random = Random.new(SEED + 1)
			local problems: Problems = {}
			local function brute(p: Vector3, margin: number): boolean
				for _, road in roads do
					local d, along = pointSegment(p.X, p.Z, road.a2.X, road.a2.Y, road.b2.X, road.b2.Y)
					local surface = surfaceAt(road, along)
					if
						d <= road.halfWidth + margin
						and p.Y >= surface - RoadGraph.onRoadBelow
						and p.Y <= surface + RoadGraph.onRoadAbove
					then
						return true
					end
				end
				return false
			end
			local onCount = 0
			for _ = 1, NEAREST_SAMPLES do
				local road = roads[random:NextInteger(1, #roads)]
				local base = road.a:Lerp(road.b, random:NextNumber())
				local p = base
					+ Vector3.new(
						random:NextNumber(-60, 60),
						random:NextNumber(-RoadGraph.onRoadBelow - 2, RoadGraph.onRoadAbove + 2),
						random:NextNumber(-60, 60)
					)
				local margin = random:NextNumber(-2, 6)
				local expected = brute(p, margin)
				if expected then
					onCount += 1
				end
				if Graph.isOnRoad(p, margin) ~= expected then
					table.insert(problems, `isOnRoad({p}, {fmt(margin)}) should be {expected}`)
				end
			end
			report(t, problems)
			t.expect(onCount).toBeGreaterThan(0)
			-- Every edge's middle, just above the surface, is on the road; far above it is not.
			for _, road in roads do
				local middle = road.a:Lerp(road.b, 0.5)
				t.expect(Graph.isOnRoad(middle + Vector3.new(0, 1, 0))).toBe(true)
				t.expect(Graph.isOnRoad(middle + Vector3.new(0, RoadGraph.onRoadAbove + 40, 0))).toBe(false)
			end
		end)

		t.it("puts loop roads in the County Loop, areas in their zones, and open country in none", function()
			for _, id in RoadGraph.loopNodeIds do
				local node = nodeById[id]
				t.expect(Graph.zoneAt(node.position)).toBe(LOOP_ZONE)
			end
			local downtown = Graph.node("cb_d4")
			assert(downtown, "the town centre node exists")
			t.expect(Graph.zoneAt(downtown.position)).toBe("cedar_bend")
			-- A point far from every road and outside every area zone.
			local open: Vector3? = nil
			for x = -3000, 3000, 250 do
				for z = -3000, 3000, 250 do
					local p = Vector3.new(x, 0, z)
					local _, distance = bruteNearest(p)
					if open == nil and distance > 200 and areaZoneAt(p) == nil then
						open = p
					end
				end
			end
			assert(open, "the county has open country")
			t.expect(Graph.zoneAt(open)).toBe(nil)
		end)

		t.it("answers nearestEdge quickly", function()
			local random = Random.new(SEED + 2)
			local points: { Vector3 } = {}
			for _ = 1, NEAREST_SAMPLES do
				table.insert(
					points,
					Vector3.new(
						random:NextNumber(-SAMPLE_REACH, SAMPLE_REACH),
						0,
						random:NextNumber(-SAMPLE_REACH, SAMPLE_REACH)
					)
				)
			end
			local started = os.clock()
			for _, p in points do
				Graph.nearestEdge(p)
			end
			local meanMs = (os.clock() - started) * 1000 / #points
			print(`  Graph.nearestEdge: {string.format("%.4f", meanMs)} ms per call over {#points} points`)
			t.expect(meanMs).toBeLessThan(NEAREST_BUDGET_MS)
		end)
	end)
end
