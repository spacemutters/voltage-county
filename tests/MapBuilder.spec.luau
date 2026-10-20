--!strict
-- MapBuilder's plan (docs/phase-2-contracts.md, "Map builder"; PLAN.md Phase 2 acceptance): the same every
-- time; road parts that never overlap by more than 0.05 studs, measured exactly (wedges as wedges) and the way
-- Dev/MapCheck measures them (every part as its whole box, parts of one pad model excepted); road surfaces with
-- no gaps and no lips; every location with its part and tag; every part within the size limit and the map;
-- buildings off roads, sidewalks and locations; a way from every pad to its road with no kerb or post a car
-- can't drive over (sidewalks stop for a driveway). Pure: builds nothing. Runs on small hand-made junctions and on
-- the real county.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Catalog = require(ReplicatedStorage.Shared.Vehicle.Catalog)
local Harness = require(ReplicatedStorage.Shared.Testing.Harness)
local MapBuilder = require(ServerScriptService.Server.Dev.MapBuilder)
local MapLayout = require(ReplicatedStorage.Shared.Config.MapLayout)
local RoadGraph = require(ReplicatedStorage.Shared.Config.RoadGraph)
local World = require(ReplicatedStorage.Shared.Config.World)

type PartSpec = MapBuilder.PartSpec
type Plan = MapBuilder.Plan

local TOLERANCE = 0.05 -- studs of overlap allowed between two road parts (contracts)
local BRIDGE_CLEARANCE = 15 -- a bridge may pass over a road this far above it (contracts)
local MAX_PART_SIZE = 2048 -- Roblox's limit per axis
local PART_BUDGET = 6500 -- the whole county (the brief aims under about 6,000)
local MAX_STEP = 0.05 -- the most the road surface may jump between two samples, beyond its slope
local MAX_GRADE = 0.4 -- steepest road surface a sample walk expects (trails are 0.25, a little steeper by pads)

---------------------------------------------------------------------------------------------------------------
-- Solids: the exact convex shape of a planned part
---------------------------------------------------------------------------------------------------------------

type Solid = {
	spec: PartSpec,
	group: string, -- parts in one Model below Roads/Intersections share a group (MapCheck skips those pairs)
	verts: { Vector3 },
	normals: { Vector3 },
	edges: { Vector3 },
	min: Vector3,
	max: Vector3,
}

-- Corners of each shape in units of half its size, and its faces as corner lists. A WedgePart's slope runs
-- from its top back edge (+Y, +Z) down to its bottom front edge; a CornerWedgePart's peak is over its (+X, -Z)
-- bottom corner.
local SHAPES: { [string]: { corners: { Vector3 }, faces: { { number } } } } = {
	block = {
		corners = {
			Vector3.new(-1, -1, -1),
			Vector3.new(1, -1, -1),
			Vector3.new(1, 1, -1),
			Vector3.new(-1, 1, -1),
			Vector3.new(-1, -1, 1),
			Vector3.new(1, -1, 1),
			Vector3.new(1, 1, 1),
			Vector3.new(-1, 1, 1),
		},
		faces = { { 1, 2, 3, 4 }, { 5, 6, 7, 8 }, { 1, 2, 6, 5 }, { 4, 3, 7, 8 }, { 1, 4, 8, 5 }, { 2, 3, 7, 6 } },
	},
	wedge = {
		corners = {
			Vector3.new(-1, -1, -1),
			Vector3.new(1, -1, -1),
			Vector3.new(-1, -1, 1),
			Vector3.new(1, -1, 1),
			Vector3.new(-1, 1, 1),
			Vector3.new(1, 1, 1),
		},
		faces = { { 1, 2, 4, 3 }, { 3, 4, 6, 5 }, { 1, 2, 6, 5 }, { 1, 3, 5 }, { 2, 4, 6 } },
	},
	cornerWedge = {
		corners = {
			Vector3.new(-1, -1, -1),
			Vector3.new(1, -1, -1),
			Vector3.new(1, -1, 1),
			Vector3.new(-1, -1, 1),
			Vector3.new(1, 1, -1),
		},
		faces = { { 1, 2, 3, 4 }, { 1, 2, 5 }, { 2, 3, 5 }, { 3, 4, 5 }, { 4, 1, 5 } },
	},
}

local function solidOf(spec: PartSpec, group: string?): Solid
	local shape = SHAPES[spec.shape] or SHAPES.block
	local cf, half = spec.cframe, spec.size / 2
	local x, y, z = cf.RightVector, cf.UpVector, -cf.LookVector
	local verts: { Vector3 } = {}
	local low, high = Vector3.one * math.huge, -Vector3.one * math.huge
	for _, c in shape.corners do
		local p = cf.Position + x * (c.X * half.X) + y * (c.Y * half.Y) + z * (c.Z * half.Z)
		table.insert(verts, p)
		low, high = low:Min(p), high:Max(p)
	end
	-- Distinct directions only (a direction and its opposite are one axis), so the pair test stays cheap.
	local function addAxis(list: { Vector3 }, v: Vector3)
		if v.Magnitude < 1e-9 then
			return
		end
		local unit = v.Unit
		for _, other in list do
			if math.abs(math.abs(other:Dot(unit)) - 1) < 1e-9 then
				return
			end
		end
		table.insert(list, unit)
	end
	local normals: { Vector3 } = {}
	local edges: { Vector3 } = {}
	for _, face in shape.faces do
		local a, b, c = verts[face[1]], verts[face[2]], verts[face[3]]
		addAxis(normals, (b - a):Cross(c - a))
		for i, index in face do
			addAxis(edges, verts[face[i % #face + 1]] - verts[index])
		end
	end
	return {
		spec = spec,
		group = group or `{spec.folder}/{spec.name}`,
		verts = verts,
		normals = normals,
		edges = edges,
		min = low,
		max = high,
	}
end

-- The same part as its whole box (how MapCheck sees a wedge), made once per solid.
local boxes: { [Solid]: Solid } = setmetatable({}, { __mode = "k" }) :: any
local function boxOf(solid: Solid): Solid
	if solid.spec.shape == "block" then
		return solid
	end
	local box = boxes[solid]
	if box == nil then
		local spec = table.clone(solid.spec)
		spec.shape = "block"
		box = solidOf(spec, solid.group)
		boxes[solid] = box
	end
	return box :: Solid
end

-- How deep two convex solids overlap: the smallest overlap of their shadows over every face normal and every
-- cross product of edge directions (exact for convex polyhedra). 0 when they are apart or only touch.
local function overlapDepth(a: Solid, b: Solid): number
	local axes: { Vector3 } = table.clone(a.normals)
	for _, n in b.normals do
		table.insert(axes, n)
	end
	for _, ea in a.edges do
		for _, eb in b.edges do
			local c = ea:Cross(eb)
			if c.Magnitude > 1e-6 then
				table.insert(axes, c.Unit)
			end
		end
	end
	local depth = math.huge
	for _, axis in axes do
		local minA, maxA, minB, maxB = math.huge, -math.huge, math.huge, -math.huge
		for _, p in a.verts do
			local d = p:Dot(axis)
			minA, maxA = math.min(minA, d), math.max(maxA, d)
		end
		for _, p in b.verts do
			local d = p:Dot(axis)
			minB, maxB = math.min(minB, d), math.max(maxB, d)
		end
		local overlap = math.min(maxA, maxB) - math.max(minA, minB)
		if overlap <= 0 then
			return 0
		end
		depth = math.min(depth, overlap)
	end
	return depth
end

-- Every pair from `as` x `bs` (or within `as` when `bs` is nil) whose boxes come within `margin`, found by
-- sweeping along X.
local function pairs2(as: { Solid }, bs: { Solid }?, margin: number, visit: (Solid, Solid) -> ())
	local list: { { solid: Solid, side: number } } = {}
	for _, s in as do
		table.insert(list, { solid = s, side = 1 })
	end
	local others: { Solid } = bs or {}
	for _, s in others do
		table.insert(list, { solid = s, side = 2 })
	end
	table.sort(list, function(p, q)
		return p.solid.min.X < q.solid.min.X
	end)
	for i, p in list do
		for j = i + 1, #list do
			local q = list[j]
			if q.solid.min.X > p.solid.max.X + margin then
				break
			end
			local wanted = if bs then p.side ~= q.side else true
			local a, b = p.solid, q.solid
			if
				wanted
				and a.min.Y <= b.max.Y + margin
				and b.min.Y <= a.max.Y + margin
				and a.min.Z <= b.max.Z + margin
				and b.min.Z <= a.max.Z + margin
			then
				if p.side == 2 then
					visit(b, a)
				else
					visit(a, b)
				end
			end
		end
	end
end

local function isRoadPart(spec: PartSpec): boolean
	return spec.role == "road" or spec.role == "pad"
end

-- The group MapCheck uses: parts in one Model below Intersections are one piece of road.
local function groupOf(spec: PartSpec): string
	if string.find(spec.folder, "^Roads/Intersections/") then
		return spec.folder
	end
	return `{spec.folder}/{spec.name}`
end

local function isBridge(spec: PartSpec): boolean
	return spec.attributes ~= nil and spec.attributes.Kind == "bridge"
end

-- The highest point of a solid's top over the middle of where two solids' boxes meet: tells a bridge from the
-- road under it.
local function topY(solid: Solid): number
	return solid.max.Y
end

type Findings = { exact: { string }, boxed: { string } }

-- Road parts that overlap: exactly, and as whole boxes between different groups. A bridge over a road with
-- the clearance between them is allowed.
local function roadOverlaps(plan: Plan): Findings
	local solids: { Solid } = {}
	for _, spec in plan.specs do
		if isRoadPart(spec) then
			table.insert(solids, solidOf(spec, groupOf(spec)))
		end
	end
	local found: Findings = { exact = {}, boxed = {} }
	pairs2(solids, nil, 0, function(a, b)
		local bridgeGap = math.abs(topY(a) - topY(b))
		if (isBridge(a.spec) or isBridge(b.spec)) and bridgeGap >= BRIDGE_CLEARANCE then
			return
		end
		local depth = overlapDepth(a, b)
		if depth > TOLERANCE then
			table.insert(found.exact, `{a.group}/{a.spec.name} x {b.group}/{b.spec.name} {depth}`)
		end
		if a.group ~= b.group then
			local boxed = overlapDepth(boxOf(a), boxOf(b))
			if boxed > TOLERANCE then
				table.insert(found.boxed, `{a.group}/{a.spec.name} x {b.group}/{b.spec.name} {boxed}`)
			end
		end
	end)
	return found
end

-- Parts of one role overlapping parts of another (exactly).
local function crossOverlaps(plan: Plan, roleA: { [string]: boolean }, roleB: { [string]: boolean }): { string }
	local as: { Solid }, bs: { Solid } = {}, {}
	for _, spec in plan.specs do
		if roleA[spec.role] then
			table.insert(as, solidOf(spec))
		elseif roleB[spec.role] then
			table.insert(bs, solidOf(spec))
		end
	end
	local found: { string } = {}
	pairs2(as, bs, 0, function(a, b)
		local depth = overlapDepth(a, b)
		if depth > TOLERANCE then
			table.insert(found, `{a.spec.folder}/{a.spec.name} x {b.spec.folder}/{b.spec.name} {depth}`)
		end
	end)
	return found
end

---------------------------------------------------------------------------------------------------------------
-- Surfaces: where the road top is, for the gap and lip checks
---------------------------------------------------------------------------------------------------------------

type Top = { corners: { Vector2 }, point: Vector3, normal: Vector3, solid: Solid }

-- A road part's top face: its plan outline and plane.
local function topOf(solid: Solid): Top?
	local spec = solid.spec
	local cf = spec.cframe
	local shape = SHAPES[spec.shape] or SHAPES.block
	local best, bestFace = -1, nil
	local bestNormal = Vector3.yAxis
	for _, face in shape.faces do
		local a, b, c = solid.verts[face[1]], solid.verts[face[2]], solid.verts[face[3]]
		local n = (b - a):Cross(c - a)
		if n.Magnitude > 1e-9 then
			n = n.Unit
			-- Outward: away from the part's centre.
			if n:Dot(a - cf.Position) < 0 then
				n = -n
			end
			if n.Y > best then
				best, bestFace, bestNormal = n.Y, face, n
			end
		end
	end
	if bestFace == nil or best < 0.5 then
		return nil
	end
	local corners: { Vector2 } = {}
	for _, index in bestFace do
		local p = solid.verts[index]
		table.insert(corners, Vector2.new(p.X, p.Z))
	end
	return { corners = corners, point = solid.verts[bestFace[1]], normal = bestNormal, solid = solid }
end

local function inside(p: Vector2, corners: { Vector2 }): boolean
	local sign = 0
	for i, a in corners do
		local b = corners[i % #corners + 1]
		local side = b - a
		-- Signed distance from the edge's line; points within a thousandth of a stud count as on it.
		local c = (side.X * (p.Y - a.Y) - side.Y * (p.X - a.X)) / math.max(side.Magnitude, 1e-9)
		if math.abs(c) > 1e-3 then
			local s = if c > 0 then 1 else -1
			if sign == 0 then
				sign = s
			elseif s ~= sign then
				return false
			end
		end
	end
	return true
end

local function heightOn(top: Top, p: Vector2): number
	local n, q = top.normal, top.point
	return q.Y - (n.X * (p.X - q.X) + n.Z * (p.Y - q.Z)) / n.Y
end

-- Road tops on a grid, to find the ones over a point quickly.
type TopGrid = { cell: number, cells: { [number]: { Top } } }

local function topGrid(plan: Plan): TopGrid
	local grid: TopGrid = { cell = 32, cells = {} }
	for _, spec in plan.specs do
		if isRoadPart(spec) then
			local top = topOf(solidOf(spec))
			if top then
				local s = top.solid
				for x = math.floor(s.min.X / grid.cell), math.floor(s.max.X / grid.cell) do
					for z = math.floor(s.min.Z / grid.cell), math.floor(s.max.Z / grid.cell) do
						local key = x * 65536 + z
						grid.cells[key] = grid.cells[key] or {}
						table.insert(grid.cells[key], top)
					end
				end
			end
		end
	end
	return grid
end

-- The road surface height at a plan point nearest to `expect`, or nil when no road part covers it.
local function surfaceAt(grid: TopGrid, p: Vector2, expect: number): number?
	local list: { Top } = grid.cells[math.floor(p.X / grid.cell) * 65536 + math.floor(p.Y / grid.cell)] or {}
	local best: number? = nil
	for _, top in list do
		if inside(p, top.corners) then
			local h = heightOn(top, p)
			if best == nil or math.abs(h - expect) < math.abs((best :: number) - expect) then
				best = h
			end
		end
	end
	return best
end

type Graph = MapBuilder.GraphData

-- Walks every road from node to node along its centre line and across its lanes, and reports places with no
-- road part under them (gaps) and steps in the surface (lips). The centre line is walked all the way into each
-- junction; the lane edges along the road's slab (inside a junction the pad's outline, not the road's, is the
-- edge).
local function surfaceProblems(plan: Plan, graph: Graph, step: number): { string }
	local grid = topGrid(plan)
	local slabs: { [string]: PartSpec } = {}
	for _, spec in plan.specs do
		if spec.role == "road" then
			slabs[spec.name] = spec
		end
	end
	local byId: { [string]: Vector3 } = {}
	for _, node in graph.nodes do
		byId[node.id] = node.position
	end
	local problems: { string } = {}
	for _, edge in graph.edges do
		local a, b = byId[edge.from], byId[edge.to]
		local style = graph.styles[edge.kind]
		local half = (edge.lanes * World.laneWidth + 2 * style.shoulder) / 2
		local plan2 = Vector2.new(b.X - a.X, b.Z - a.Z)
		local length = plan2.Magnitude
		local u = plan2.Unit
		local l = Vector2.new(-u.Y, u.X)
		local count = math.max(2, math.ceil(length / step))
		-- Where the road's slab runs (plan distance from `from`), from the planned segment part.
		local slab = slabs[`{edge.from}-{edge.to}`]
		local first, last = 0, length
		if slab then
			local look = slab.cframe.LookVector
			local run = slab.size.Z * Vector2.new(look.X, look.Z).Magnitude
			local middle = (Vector2.new(slab.cframe.X, slab.cframe.Z) - Vector2.new(a.X, a.Z)):Dot(u)
			first, last = middle - run / 2, middle + run / 2
		else
			table.insert(problems, `no slab for {edge.from}-{edge.to}`)
		end
		for _, lateral in { -(half - 0.1), 0, half - 0.1 } do
			local previous: number? = nil
			for i = 0, count do
				local f = i / count
				local along = length * f
				if lateral == 0 or (along >= first and along <= last) then
					local p = Vector2.new(a.X, a.Z) + u * along + l * lateral
					local expect = a.Y + (b.Y - a.Y) * f
					local h = surfaceAt(grid, p, expect)
					if h == nil then
						table.insert(
							problems,
							`gap on {edge.from}-{edge.to} at {math.floor(along)} studs, {lateral} across`
						)
						previous = nil
						break
					end
					local height = h :: number
					if previous and math.abs(height - previous) > MAX_GRADE * length / count + MAX_STEP then
						table.insert(
							problems,
							`lip on {edge.from}-{edge.to} at {math.floor(along)} studs: {height - previous}`
						)
						break
					end
					previous = height
				end
			end
		end
	end
	return problems
end

---------------------------------------------------------------------------------------------------------------
-- Fixtures
---------------------------------------------------------------------------------------------------------------

local ASPHALT = Color3.fromRGB(70, 72, 76)
local PAINT = Color3.fromRGB(236, 236, 228)

local STYLES: { [string]: MapBuilder.StyleData } = {
	highway = { shoulder = 8, sidewalk = 0, color = ASPHALT, lineColor = PAINT },
	arterial = { shoulder = 4, sidewalk = 10, color = ASPHALT, lineColor = PAINT },
	street = { shoulder = 3, sidewalk = 8, color = ASPHALT, lineColor = PAINT },
	ramp = { shoulder = 4, sidewalk = 0, color = ASPHALT, lineColor = PAINT },
	bridge = { shoulder = 3, sidewalk = 0, color = ASPHALT, lineColor = PAINT },
	dirt = { shoulder = 4, sidewalk = 0, color = ASPHALT, lineColor = PAINT },
}
local LANES: { [string]: number } = { highway = 4, arterial = 4, street = 2, ramp = 2, bridge = 4, dirt = 2 }

type FixtureGraph = {
	nodes: { MapBuilder.NodeData },
	edges: { MapBuilder.EdgeData },
	styles: { [string]: MapBuilder.StyleData },
}

local function newGraph(): FixtureGraph
	return { nodes = {}, edges = {}, styles = STYLES }
end

local function addNode(graph: FixtureGraph, id: string, x: number, y: number, z: number)
	table.insert(graph.nodes, { id = id, position = Vector3.new(x, y, z), zone = "town" })
end

local function addEdge(graph: FixtureGraph, from: string, to: string, kind: string)
	table.insert(graph.edges, {
		from = from,
		to = to,
		lanes = LANES[kind],
		speedLimitMph = 30,
		surface = if kind == "dirt" then "dirt" else "asphalt",
		kind = kind,
	})
end

-- A junction of roads leaving (x, z) at the given compass-free angles (degrees), `length` studs long.
local function star(
	graph: FixtureGraph,
	id: string,
	x: number,
	z: number,
	roads: { { number | string } },
	length: number
)
	addNode(graph, id, x, 0.2, z)
	for i, road in roads do
		local angle, kind = math.rad(road[1] :: number), road[2] :: string
		local tip = `{id}_{i}`
		addNode(graph, tip, x + length * math.cos(angle), 0.2, z + length * math.sin(angle))
		addEdge(graph, id, tip, kind)
	end
end

-- A chain of `count` roads turning `turn` degrees at every node, with optional heights per node.
local function chain(
	graph: FixtureGraph,
	id: string,
	x: number,
	z: number,
	turn: number,
	kind: string,
	heights: { number }?
)
	local angle = 0
	-- Sharp turns get one bend only, so the chain never folds back across itself.
	local count = if heights then #heights - 1 elseif turn > 60 then 2 else 3
	local step = 160
	for i = 0, count do
		local y = if heights then heights[i + 1] else 0.2
		addNode(graph, `{id}{i}`, x, y, z)
		if i > 0 then
			addEdge(graph, `{id}{i - 1}`, `{id}{i}`, kind)
		end
		x += step * math.cos(angle)
		z += step * math.sin(angle)
		angle += math.rad(turn)
	end
end

-- Hand-made junctions spread over the map: square, T, Y and skewed crossings, a ramp merging at 15 degrees,
-- bends from gentle to hairpin, a change of width, crests and valleys, a sloped trail junction, an 8-sided
-- turning loop and a bridge over a road.
local function fixtureGraph(): FixtureGraph
	local g = newGraph()
	star(g, "cross", -3000, -3000, { { 0, "arterial" }, { 90, "street" }, { 180, "arterial" }, { 270, "street" } }, 300)
	star(g, "tee", -2000, -3000, { { 0, "arterial" }, { 90, "street" }, { 180, "arterial" } }, 300)
	star(g, "acute", -1000, -3000, { { 0, "arterial" }, { 40, "street" }, { 180, "arterial" } }, 300)
	star(g, "wye", 0, -3000, { { 0, "street" }, { 120, "street" }, { 240, "street" } }, 300)
	star(g, "skew", 1000, -3000, { { 10, "arterial" }, { 70, "street" }, { 190, "arterial" }, { 250, "street" } }, 300)
	star(g, "merge", 2200, -3000, { { 0, "highway" }, { 15, "ramp" }, { 180, "highway" } }, 600)
	star(
		g,
		"five",
		3500,
		-3000,
		{ { 0, "arterial" }, { 70, "street" }, { 150, "highway" }, { 220, "street" }, { 290, "ramp" } },
		300
	)
	for i, turn in { 3, 15, 45, 90, 135 } do
		chain(g, `bend{i}_`, -3500 + 1300 * (i - 1), -1500, turn, "street")
		chain(g, `wide{i}_`, -3500 + 1300 * (i - 1), -500, turn, "highway")
	end
	-- A street widening into an arterial at a gentle bend.
	addNode(g, "widen0", -3500, 0.2, 800)
	addNode(g, "widen1", -3300, 0.2, 800)
	addNode(g, "widen2", -3110, 0.2, 860)
	addEdge(g, "widen0", "widen1", "street")
	addEdge(g, "widen1", "widen2", "arterial")
	-- Crests, valleys and a bend over a crest (grades of 0.12 and a 0.25 trail).
	chain(g, "crest", -2500, 800, 0, "street", { 0.2, 19.4, 0.2 })
	chain(g, "valley", -2500, 1000, 0, "street", { 19.4, 0.2, 19.4 })
	chain(g, "steep", -2500, 1200, 0, "dirt", { 0.2, 40.2, 0.2 })
	chain(g, "bendcrest", -1500, 800, 20, "street", { 0.2, 19.4, 0.2 })
	-- A trail junction on a slope.
	addNode(g, "slope", 0, 30.2, 1000)
	addNode(g, "slope_1", 160, 0.2, 1000)
	addNode(g, "slope_2", -80, 50.2, 1000 + 138.6)
	addNode(g, "slope_3", -80, 30.2, 1000 - 138.6)
	addEdge(g, "slope", "slope_1", "dirt")
	addEdge(g, "slope", "slope_2", "dirt")
	addEdge(g, "slope", "slope_3", "dirt")
	-- An 8-sided turning loop at the end of a street.
	addNode(g, "loop_in", 1500, 0.2, 1000)
	for i = 0, 7 do
		local angle = math.rad(45 * i)
		addNode(g, `loop{i}`, 1800 + 70 * math.cos(angle), 0.2, 1000 + 70 * math.sin(angle))
	end
	for i = 0, 7 do
		addEdge(g, `loop{i}`, `loop{(i + 1) % 8}`, "street")
	end
	addEdge(g, "loop_in", "loop4", "street")
	-- A bridge over a street: approaches at 0.1, a deck 20 above the street.
	addNode(g, "br_a", 2800, 0.2, 0)
	addNode(g, "br_b", 2800, 20.2, 200)
	addNode(g, "br_c", 2800, 20.2, 400)
	addNode(g, "br_d", 2800, 0.2, 600)
	addEdge(g, "br_a", "br_b", "bridge")
	addEdge(g, "br_b", "br_c", "bridge")
	addEdge(g, "br_c", "br_d", "bridge")
	addNode(g, "under_a", 2600, 0.2, 300)
	addNode(g, "under_b", 3000, 0.2, 300)
	addEdge(g, "under_a", "under_b", "street")
	return g
end

local TAGS = {
	"SpawnPad",
	"ChargerStall",
	"TruckCharger",
	"FuelPump",
	"Dealership",
	"UsedLot",
	"DesignStudio",
	"JobDepot",
	"RideshareHotspot",
	"HousePlot",
	"MeetSpot",
	"FlightZone",
	"NoFlyZone",
	"DragStripGate",
}

-- One zone that builds (sidewalks only come with Cedar Bend or Riverside, so the fixture's own zone has none
-- unless it is called that) and a location of every tag beside the T junction's east arm.
local function fixtureLayout(sidewalks: boolean): MapBuilder.LayoutData
	local zoneId = if sidewalks then "cedar_bend" else "town"
	local zone: MapBuilder.ZoneData = {
		id = zoneId,
		displayName = "Town",
		min = Vector2.new(-4000, -4000),
		max = Vector2.new(4000, 4000),
		groundColor = Color3.fromRGB(120, 130, 100),
		buildingColors = { Color3.fromRGB(150, 140, 130) },
		buildingHeight = { min = 20, max = 60 },
		buildingDensity = 0.8,
	}
	local locations: { MapBuilder.LocationData } = {}
	for i, tag in TAGS do
		local volume = tag == "FlightZone" or tag == "NoFlyZone"
		local size = if volume then Vector3.new(60, 80, 60) else Vector3.new(14, 1, 20)
		table.insert(locations, {
			id = `place_{i}`,
			displayName = `Place {i}`,
			tag = tag,
			zone = zoneId,
			position = Vector3.new(-2000 + 40 * i, 0, -3000 - 60),
			yaw = 180, -- facing the road to its south
			size = size,
			attributes = { index = i },
		})
	end
	return {
		seed = 7,
		zones = { [zoneId] = zone },
		zoneOrder = { zoneId },
		locations = locations,
		playerSpawns = { CFrame.new(-1900, 0, -3200) },
	}
end

local function sidewalkGraph(graph: FixtureGraph): FixtureGraph
	local copy = table.clone(graph)
	copy.nodes = {}
	for _, node in graph.nodes do
		table.insert(copy.nodes, { id = node.id, position = node.position, zone = "cedar_bend" })
	end
	return copy
end

local function report(t: Harness.Api, label: string, list: { string })
	for i, line in list do
		if i > 10 then
			print(`  {label}: ...and {#list - 10} more`)
			break
		end
		print(`  {label}: {line}`)
	end
	t.expect(#list).toBe(0)
end

-- Every drivable trim's ride height, lowest first: the most a car can drive over is just under the first.
local function lowestRideHeight(): number
	local lowest = math.huge
	for _, vehicleId in Catalog.vehicleIds() do
		local vehicle = Catalog.getVehicle(vehicleId)
		if vehicle and vehicle.playerDrivable then
			for _, trim in vehicle.trims do
				local geometry = Catalog.geometry(vehicleId, trim.id)
				if geometry then
					lowest = math.min(lowest, geometry.rideHeight)
				end
			end
		end
	end
	return lowest
end

-- Locations no car drives off: volumes, and the gates that span the drag strip.
local NOT_PADS: { [string]: boolean } = { FlightZone = true, NoFlyZone = true, DragStripGate = true }
-- Solid things a car leaving a pad could hit (kerbs and sidewalks, posts, railings, buildings, ramps).
local OBSTACLES: { [string]: boolean } =
	{ sidewalk = true, light = true, support = true, building = true, landmark = true, ramp = true }
local EXIT_HEIGHT = 6 -- studs of the box a car sweeps on its way out, from its ride height up

-- Parts in the way of a car driving straight from each pad to the nearest point of the road: anything solid
-- standing higher than the lowest car's ride height above the pad, in a box as wide as the pad.
local function padExitProblems(plan: Plan, layout: MapBuilder.LayoutData, graph: Graph, lowest: number): { string }
	local obstacles: { Solid } = {}
	for _, spec in plan.specs do
		if OBSTACLES[spec.role] and spec.collide then
			table.insert(obstacles, solidOf(spec))
		end
	end
	local byId: { [string]: Vector3 } = {}
	for _, node in graph.nodes do
		byId[node.id] = node.position
	end
	local exits: { Solid } = {}
	for _, location in layout.locations do
		if NOT_PADS[location.tag] then
			continue
		end
		local c = Vector2.new(location.position.X, location.position.Z)
		local road: Vector2? = nil
		local best = math.huge
		for _, edge in graph.edges do
			local a3, b3 = byId[edge.from], byId[edge.to]
			local a, b = Vector2.new(a3.X, a3.Z), Vector2.new(b3.X, b3.Z)
			local length = (b - a).Magnitude
			local along = math.clamp((c - a):Dot((b - a).Unit), 0, length)
			local point = a + (b - a).Unit * along
			if (point - c).Magnitude < best then
				road, best = point, (point - c).Magnitude
			end
		end
		if road == nil or best < 1 then
			continue
		end
		local way = (road :: Vector2) - c
		local middle = (c + (road :: Vector2)) / 2
		local center = Vector3.new(middle.X, location.position.Y + lowest + EXIT_HEIGHT / 2, middle.Y)
		table.insert(
			exits,
			solidOf({
				folder = "Exit",
				name = location.id,
				class = "Part",
				shape = "block",
				role = "location",
				size = Vector3.new(location.size.X, EXIT_HEIGHT, way.Magnitude),
				cframe = CFrame.lookAt(center, center + Vector3.new(way.X, 0, way.Y)),
				color = Color3.new(),
				material = Enum.Material.SmoothPlastic,
				collide = false,
				query = false,
				touch = false,
				shadow = false,
				transparency = 1,
			})
		)
	end
	local found: { string } = {}
	pairs2(exits, obstacles, 0, function(exit, obstacle)
		local depth = overlapDepth(exit, obstacle)
		if depth > TOLERANCE then
			table.insert(found, `{exit.spec.name} -> its road: {obstacle.spec.folder}/{obstacle.spec.name} {depth}`)
		end
	end)
	return found
end

local function partProblems(plan: Plan, half: number): { string }
	local problems: { string } = {}
	for _, spec in plan.specs do
		local size = spec.size
		if math.max(size.X, size.Y, size.Z) > MAX_PART_SIZE then
			table.insert(problems, `{spec.folder}/{spec.name} is {size}`)
		end
		if size.X ~= size.X or size.Y ~= size.Y or size.Z ~= size.Z or math.min(size.X, size.Y, size.Z) <= 0 then
			table.insert(problems, `{spec.folder}/{spec.name} has a bad size {size}`)
		end
		local solid = solidOf(spec)
		if
			solid.min.X < -half - 1e-3
			or solid.max.X > half + 1e-3
			or solid.min.Z < -half - 1e-3
			or solid.max.Z > half + 1e-3
		then
			table.insert(problems, `{spec.folder}/{spec.name} reaches outside the map`)
		end
	end
	return problems
end

---------------------------------------------------------------------------------------------------------------
-- Specs
---------------------------------------------------------------------------------------------------------------

return function(t: Harness.Api)
	local half = World.mapHalfExtent

	t.describe("MapBuilder junctions (fixtures)", function()
		local graph = sidewalkGraph(fixtureGraph())
		local plan = MapBuilder.planWith(fixtureLayout(true), graph)

		t.it("builds every road and leaves no notes", function()
			local segments = 0
			for _, spec in plan.specs do
				if spec.role == "road" then
					segments += 1
				end
			end
			t.expect(segments).toBe(#graph.edges)
			report(t, "note", plan.notes)
		end)

		t.it("never overlaps two road parts by more than 0.05 studs, exactly or as MapCheck sees them", function()
			local found = roadOverlaps(plan)
			report(t, "exact", found.exact)
			report(t, "whole box", found.boxed)
		end)

		t.it("leaves no gaps or lips along any road", function()
			report(t, "surface", surfaceProblems(plan, graph, 0.5))
		end)

		t.it("keeps sidewalks, railings and buildings off the road", function()
			local roads = { road = true, pad = true }
			report(t, "sidewalk", crossOverlaps(plan, { sidewalk = true }, roads))
			report(t, "support", crossOverlaps(plan, { support = true }, roads))
			report(t, "building", crossOverlaps(plan, { building = true, landmark = true }, roads))
		end)

		t.it("leaves every pad a way to its road with nothing a car can't drive over", function()
			report(t, "pad exit", padExitProblems(plan, fixtureLayout(true), graph, lowestRideHeight()))
		end)

		t.it("stands no pillar on the road under the bridge", function()
			local pillars, onRoad = 0, 0
			for _, spec in plan.specs do
				if spec.role == "support" and string.find(spec.name, "Pillar") then
					pillars += 1
					local p = spec.cframe.Position
					if math.abs(p.Z - 300) < 15 + 2 then
						onRoad += 1
					end
				end
			end
			t.expect(pillars).toBeGreaterThan(0)
			t.expect(onRoad).toBe(0)
		end)

		t.it("gives every location its tagged part, attributes and props, and spawns", function()
			local layout = fixtureLayout(true)
			local byName: { [string]: PartSpec } = {}
			local props = 0
			for _, spec in plan.specs do
				if spec.folder == "Locations" and spec.parent == nil then
					byName[spec.name] = spec
				elseif spec.role == "prop" then
					props += 1
				end
			end
			for _, location in layout.locations do
				local spec = byName[location.id]
				t.expect(spec ~= nil).toBe(true)
				if spec then
					t.expect(spec.tag).toBe(location.tag)
					local attributes: { [string]: any } = spec.attributes or {}
					t.expect(attributes.DisplayName).toBe(location.displayName)
					t.expect(attributes.Zone).toBe(location.zone)
					t.expect(attributes.index).toBe((location.attributes :: any).index)
					t.expect(spec.collide).toBe(false)
					t.expect(spec.size).toBe(location.size)
				end
			end
			t.expect(props).toBeGreaterThan(10)
			local spawns = 0
			for _, spec in plan.specs do
				if spec.class == "SpawnLocation" then
					spawns += 1
				end
			end
			t.expect(spawns).toBe(#layout.playerSpawns)
		end)
	end)

	t.describe("MapBuilder.plan (the county)", function()
		local plan = MapBuilder.county()
		local specs = MapBuilder.plan()

		t.it("is the same every time", function()
			t.expect(#specs).toBe(#plan.specs)
			for i, spec in plan.specs do
				local again = specs[i]
				t.expect(again.folder).toBe(spec.folder)
				t.expect(again.name).toBe(spec.name)
				t.expect(again.cframe == spec.cframe).toBe(true)
				t.expect(again.size == spec.size).toBe(true)
			end
		end)

		t.it(`stays under {PART_BUDGET} parts`, function()
			local roles: { string } = {}
			for role, count in plan.counts do
				table.insert(roles, `{role} {count}`)
			end
			table.sort(roles)
			print(`  MapBuilder: {#plan.specs} parts ({table.concat(roles, ", ")})`)
			t.expect(#plan.specs).toBeLessThan(PART_BUDGET)
		end)

		t.it("builds a slab for every road and leaves no notes", function()
			local segments: { [string]: boolean } = {}
			for _, spec in plan.specs do
				if spec.role == "road" then
					segments[spec.name] = true
				end
			end
			local missing: { string } = {}
			for _, edge in RoadGraph.edges do
				if not segments[`{edge.from}-{edge.to}`] then
					table.insert(missing, `{edge.from}-{edge.to}`)
				end
			end
			report(t, "no slab", missing)
			report(t, "note", plan.notes)
		end)

		t.it("never overlaps two road parts by more than 0.05 studs, exactly or as MapCheck sees them", function()
			local found = roadOverlaps(plan)
			report(t, "exact", found.exact)
			report(t, "whole box", found.boxed)
		end)

		t.it("leaves no gaps or lips along any road", function()
			report(t, "surface", surfaceProblems(plan, RoadGraph :: any, 2))
		end)

		t.it("keeps every part under the size limit and inside the map", function()
			report(t, "part", partProblems(plan, half))
		end)

		t.it("keeps sidewalks and buildings off the roads, and buildings off locations and landmarks", function()
			local roads = { road = true, pad = true }
			report(t, "sidewalk", crossOverlaps(plan, { sidewalk = true }, roads))
			report(
				t,
				"building",
				crossOverlaps(
					plan,
					{ building = true, lot = true },
					{ road = true, pad = true, sidewalk = true, location = true, landmark = true }
				)
			)
		end)

		t.it("leaves every pad a way to its road with nothing a car can't drive over", function()
			report(t, "pad exit", padExitProblems(plan, MapLayout :: any, RoadGraph :: any, lowestRideHeight()))
		end)

		t.it("gives every MapLayout location one part with its tag, DisplayName and Zone", function()
			local count: { [string]: number } = {}
			local byName: { [string]: PartSpec } = {}
			for _, spec in plan.specs do
				if spec.folder == "Locations" and spec.parent == nil then
					count[spec.name] = (count[spec.name] or 0) + 1
					byName[spec.name] = spec
				end
			end
			local problems: { string } = {}
			for _, location in MapLayout.locations do
				local spec = byName[location.id]
				if spec == nil or count[location.id] ~= 1 then
					table.insert(problems, `{location.id}: {count[location.id] or 0} parts`)
				elseif spec.tag ~= location.tag then
					table.insert(problems, `{location.id}: tag {spec.tag}`)
				else
					local attributes: { [string]: any } = spec.attributes or {}
					if attributes.DisplayName ~= location.displayName or attributes.Zone ~= location.zone then
						table.insert(problems, `{location.id}: DisplayName or Zone wrong`)
					end
					local wanted: { [string]: any } = location.attributes or {}
					for key, value in wanted do
						if attributes[key] ~= value then
							table.insert(problems, `{location.id}: attribute {key}`)
						end
					end
				end
			end
			report(t, "location", problems)
		end)

		t.it("streams the ground and roads as Persistent models and blocks as Atomic ones", function()
			local kinds: { [string]: MapBuilder.Container } = {}
			for _, entry in plan.containers do
				kinds[entry.path] = entry
			end
			for _, name in { "Ground", "Roads" } do
				local entry = kinds[name]
				t.expect(entry ~= nil and entry.class == "Model").toBe(true)
				t.expect(entry and entry.streaming).toBe(Enum.ModelStreamingMode.Persistent)
			end
			local unknown: { string } = {}
			for _, spec in plan.specs do
				if kinds[spec.folder] == nil then
					table.insert(unknown, `{spec.folder}/{spec.name}`)
				end
				if string.find(spec.folder, "^Buildings/") then
					local entry = kinds[spec.folder]
					if entry == nil or entry.streaming ~= Enum.ModelStreamingMode.Atomic then
						table.insert(unknown, `{spec.folder} is not Atomic`)
					end
				end
			end
			report(t, "container", unknown)
		end)

		t.it("lights at most one streetlight per 200 studs", function()
			local lit: { Vector3 } = {}
			for _, spec in plan.specs do
				if spec.light then
					table.insert(lit, spec.cframe.Position)
				end
			end
			t.expect(#lit).toBeGreaterThan(0)
			local close = 0
			for i, a in lit do
				for j = i + 1, #lit do
					if (Vector2.new(a.X, a.Z) - Vector2.new(lit[j].X, lit[j].Z)).Magnitude < 200 then
						close += 1
					end
				end
			end
			t.expect(close).toBe(0)
		end)
	end)
end
