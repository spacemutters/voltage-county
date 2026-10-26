--!strict
-- MapBuilder's plan (docs/phase-2-contracts.md, "Map builder"; PLAN.md Phase 2 acceptance): the same every
-- time; road parts that never overlap by more than 0.05 studs, measured exactly (wedges as wedges) and the way
-- Dev/MapCheck measures them (every part as its whole box, parts of one pad model excepted); road surfaces with
-- no gaps and no lips; every location with its part and tag; every part within the size limit and the map;
-- buildings off roads, sidewalks and locations; a way from every pad to its road with no kerb or post a car
-- can't drive over (sidewalks stop for a driveway); every dealership and used-lot display pad built where
-- MapLayout puts it, with its tag, attributes and brand sign, and nothing built on it (Phase 4). The look beyond the
-- roads (docs/roast-2026-10-24.md point 3): the map within Config/Environment's part budget, role by role; the
-- ground a patchwork of grass; trees between the configured counts, trunks solid and leaves not, clear of roads,
-- sidewalks, lots, pads, house plots, buildings, features and water; every old-facade building with glass and a roof
-- edge; the city (Dev/City; docs/city/CITY_PLAN.md §10): every site inside its footprint, height and part budget, with
-- glass and a roof, each archetype placed and within its copies, every one-off built once, neighbours never twins,
-- no look twice, no two near towers of one height, most of them lit at night, SLIM models holding still parts only, the
-- Skyline Persistent and within budget, building parts per district, and the phone gate (budget.inViewParts); the
-- hills, parks and features where MapLayout puts them, off the roads. Pure: builds nothing. Runs on small hand-made
-- junctions and on the real county.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Brands = require(ReplicatedStorage.Shared.Config.Brands)
local Catalog = require(ReplicatedStorage.Shared.Vehicle.Catalog)
local City = require(ReplicatedStorage.Shared.Config.City)
local CityBuilder = require(ServerScriptService.Server.Dev.City.CityBuilder)
local Dealership = require(ReplicatedStorage.Shared.Config.Dealership)
local Environment = require(ReplicatedStorage.Shared.Config.Environment)
local Harness = require(ReplicatedStorage.Shared.Testing.Harness)
local MapBuilder = require(ServerScriptService.Server.Dev.MapBuilder)
local MapCheck = require(ServerScriptService.Server.Dev.MapCheck)
local MapLayout = require(ReplicatedStorage.Shared.Config.MapLayout)
local Perf = require(ReplicatedStorage.Shared.Config.Perf)
local RoadGraph = require(ReplicatedStorage.Shared.Config.RoadGraph)
local World = require(ReplicatedStorage.Shared.Config.World)

type PartSpec = MapBuilder.PartSpec
type Plan = MapBuilder.Plan

local TOLERANCE = 0.05 -- studs of overlap allowed between two road parts (contracts)
local BRIDGE_CLEARANCE = 15 -- a bridge may pass over a road this far above it (contracts)
local MAX_PART_SIZE = 2048 -- Roblox's limit per axis
local BUDGET = Environment.budget -- the whole county and its parts by role (Config/Environment says why)
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

-- Parts `pick` chooses overlapping parts of the given roles (exactly).
local function pickedOverlaps(plan: Plan, pick: (PartSpec) -> boolean, roles: { [string]: boolean }): { string }
	local as: { Solid }, bs: { Solid } = {}, {}
	for _, spec in plan.specs do
		if pick(spec) then
			table.insert(as, solidOf(spec))
		elseif roles[spec.role] then
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
	"CustomShop",
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

		t.it("plans the same parts every time", function()
			local again = MapBuilder.planWith(fixtureLayout(true), graph).specs
			t.expect(#again).toBe(#plan.specs)
			for i, spec in plan.specs do
				local other = again[i]
				t.expect(other.folder).toBe(spec.folder)
				t.expect(other.name).toBe(spec.name)
				t.expect(other.cframe == spec.cframe).toBe(true)
				t.expect(other.size == spec.size).toBe(true)
			end
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
		-- Planned once for every case below: the county is about 15,000 parts, and each plan takes a while in Edit
		-- mode. (The fixtures check the planner gives the same parts every time; a plain Dev/MapCheck.run() builds
		-- the county twice and compares.)
		local plan = MapBuilder.county()

		t.it(`stays within the part budget: {BUDGET.mapParts} in all, and per role`, function()
			local roles: { string } = {}
			for role, count in plan.counts do
				table.insert(roles, `{role} {count}`)
			end
			table.sort(roles)
			print(`  MapBuilder: {#plan.specs} parts ({table.concat(roles, ", ")})`)
			local over: { string } = {}
			local function within(label: string, count: number, limit: number)
				if count > limit then
					table.insert(over, `{label} {count} > {limit}`)
				end
			end
			within("map", #plan.specs, BUDGET.mapParts)
			within("tree", plan.counts.tree or 0, BUDGET.treeParts)
			within("building", plan.counts.building or 0, BUDGET.buildingParts)
			within("feature", plan.counts.feature or 0, BUDGET.featureParts)
			within("ground", plan.counts.ground or 0, BUDGET.groundParts)
			-- The city (Config/City budgets): the Skyline model and the building night lights hold; building parts per
			-- district are the plan's shares of buildingParts (CITY_PLAN §9), printed with any district past its share
			-- so the lead can see where the parts go (buildingParts and mapParts are the limits that fail).
			local districts: { string } = {}
			for district, count in plan.city.parts do
				local share = City.budgets.districts[district]
				local past = if share and count > share then ` (over its share of {share})` else ""
				table.insert(districts, `{if district == "" then "no district" else district} {count}{past}`)
			end
			table.sort(districts)
			print(`  MapBuilder: building parts by district: {table.concat(districts, ", ")}`)
			within("Skyline", plan.city.skyline, City.budgets.skyline)
			within("building night lights", plan.city.lights, City.budgets.nightLights)
			report(t, "over budget", over)
		end)

		-- The phone gate (Config/Environment budget.inViewParts; CITY_PLAN §9): every Persistent part, plus every part
		-- within the streaming target radius of the worst road node.
		t.it(`keeps at most {BUDGET.inViewParts} parts in view at once`, function()
			local points: { Vector3 } = {}
			for _, node in RoadGraph.nodes do
				table.insert(points, node.position)
			end
			local parts, at = MapCheck.inView(plan.specs, plan.containers, points, Perf.streaming.targetRadius)
			local where = if at then `({math.round(at.X)}, {math.round(at.Z)})` else "nowhere"
			print(`  MapBuilder: at most {parts} parts in view at once, near {where}`)
			t.expect(parts <= BUDGET.inViewParts).toBe(true)
		end)

		t.it("lays the open land and the green zones in a patchwork of grass shades", function()
			local looks: { [string]: boolean } = {}
			local shades = 0
			for _, spec in plan.specs do
				local grass = spec.material == Enum.Material.Grass or spec.material == Enum.Material.LeafyGrass
				if spec.folder == "Ground" and string.find(spec.name, "^Ground") and grass then
					local key = `{spec.color}:{spec.material.Name}`
					if not looks[key] then
						looks[key] = true
						shades += 1
					end
				end
			end
			-- The County Loop's four shades, and Riverside's and Lakefront's (Config/MapLayout groundShades).
			t.expect(shades).toBeGreaterThan(4)
		end)

		t.it("plants trees within the configured count: trunks cars hit, leaves they pass through", function()
			local config = Environment.trees
			local trunks, leaves = 0, 0
			local problems: { string } = {}
			for _, spec in plan.specs do
				if spec.role ~= "tree" then
					continue
				end
				if string.find(spec.folder, "^Trees/Tile") == nil then
					table.insert(problems, `{spec.folder}/{spec.name}: not in a tree tile`)
				end
				if string.find(spec.name, "Trunk$") then
					trunks += 1
					if not spec.collide or not spec.query then
						table.insert(problems, `{spec.name}: a trunk cars pass through`)
					end
				else
					leaves += 1
					if spec.collide or spec.query or spec.touch then
						table.insert(problems, `{spec.name}: leaves a car would hit`)
					end
				end
			end
			print(`  MapBuilder: {trunks} trees ({leaves} leaf blocks)`)
			report(t, "tree", problems)
			t.expect(trunks >= config.minTrees).toBe(true)
			t.expect(trunks <= config.maxTrees).toBe(true)
			t.expect(leaves >= trunks).toBe(true)
		end)

		t.it("keeps trees off roads, sidewalks, lots, pads, house plots, buildings, features and water", function()
			report(
				t,
				"tree",
				crossOverlaps(plan, { tree = true }, {
					road = true,
					pad = true,
					sidewalk = true,
					support = true,
					lot = true,
					building = true,
					landmark = true,
					location = true,
					prop = true,
					displayPad = true,
					sign = true,
					billboard = true,
					feature = true,
					light = true,
					spawn = true,
					water = true,
					ramp = true,
				})
			)
		end)

		-- The old facade stands only on plots no archetype fits (Config/City districtLooks legacyWeight 0): however few,
		-- each still has glass and a roof edge proud of it.
		t.it("gives every old-look building glass and a roof edge, and counts them by district", function()
			local buildings: { [string]: { [string]: PartSpec } } = {}
			for _, spec in plan.specs do
				local id = if spec.role == "building" then string.match(spec.name, "^Building%d+") else nil
				if id then
					local parts = buildings[id] or {}
					parts[string.sub(spec.name, #id + 1)] = spec
					buildings[id] = parts
				end
			end
			local problems: { string } = {}
			local count, lit, banded = 0, 0, 0
			for id, parts in buildings do
				count += 1
				local glass, top = parts[""], parts.Top
				if glass == nil or glass.material ~= Enum.Material.Glass then
					table.insert(problems, `{id}: no glass`)
					continue
				end
				if top == nil then
					table.insert(problems, `{id}: no roof edge`)
					continue
				end
				-- The roof edge stands on the footprint, proud of the glass, and rises past the glass.
				local upper = parts.Upper or glass
				if top.size.X <= glass.size.X or top.size.Z <= glass.size.Z then
					table.insert(problems, `{id}: its roof edge isn't proud of the glass`)
				end
				if top.cframe.Y + top.size.Y / 2 <= upper.cframe.Y + upper.size.Y / 2 then
					table.insert(problems, `{id}: its roof edge is below its glass`)
				end
				if parts.Band1 or parts.Pier1 then
					banded += 1
				end
				for _, spec in parts do
					if spec.tag == Environment.nightLights.tag then
						lit += 1
						break
					end
				end
			end
			local districts: { string } = {}
			for district, n in plan.city.legacy do
				table.insert(districts, `{if district == "" then "no district" else district} {n}`)
			end
			table.sort(districts)
			print(
				`  MapBuilder: {count} old-look buildings ({banded} banded, {lit} lit) on plots no archetype fits: `
					.. `{if #districts > 0 then table.concat(districts, ", ") else "none"}`
			)
			report(t, "building", problems)
		end)

		-- The city (Dev/City; docs/city/CITY_PLAN.md §10). A site's parts are the ones named after it, wherever they are
		-- filed: its own model, its lights model or the Skyline.
		local bySite: { [string]: { PartSpec } } = {}
		for _, spec in plan.specs do
			local id = if spec.role == "building" then string.match(spec.name, "^B%d+") else nil
			if id then
				local list = bySite[id] or {}
				table.insert(list, spec)
				bySite[id] = list
			end
		end
		local notReady: { [string]: boolean } = {}
		for _, line in plan.city.missing do
			notReady[string.match(line, "^[%w_]+") or line] = true
		end

		-- Every site built from its archetype stays inside its footprint, its height and its part budget
		-- (CityBuilder.check, run again on the planned parts), has glass and reaches its roof; no archetype passes its
		-- copies; and at least one of each archetype placement may draw stands in the county.
		t.it("builds every city site from its archetype, inside its footprint, height and budget", function()
			local problems: { string } = {}
			local copies: { [string]: number } = {}
			for _, site in plan.sites do
				local specs: { PartSpec } = bySite[site.id] or {}
				for _, problem in CityBuilder.check(site, specs) do
					table.insert(problems, `{site.id} {site.archetype}: {problem}`)
				end
				local glass, top = false, -math.huge
				for _, spec in specs do
					glass = glass or spec.material == Enum.Material.Glass
					top = math.max(top, spec.cframe.Y + spec.size.Y / 2)
				end
				if not glass then
					table.insert(problems, `{site.id}: no glass`)
				end
				if top < site.height - 1 then
					table.insert(problems, `{site.id}: its top {top} is short of its height {site.height}`)
				end
				if site.band ~= CityBuilder.bandOf(site.height) then
					table.insert(problems, `{site.id}: band {site.band} for a height of {site.height}`)
				end
				copies[site.archetype] = (copies[site.archetype] or 0) + 1
			end
			for id, config in City.archetypes do
				if City.notOnPlots[id] or notReady[id] then
					continue
				end
				local count = copies[id] or 0
				if count == 0 then
					table.insert(problems, `{id}: not one in the county`)
				elseif count > config.maxCopies then
					table.insert(problems, `{id}: {count} copies, over {config.maxCopies}`)
				end
			end
			print(
				`  MapBuilder: {#plan.sites} city sites, {plan.city.claims} core claims; not written yet: `
					.. `{if #plan.city.missing > 0 then table.concat(plan.city.missing, ", ") else "nothing"}`
			)
			report(t, "city", problems)
		end)

		-- Every one-off (Config/City landmarks) whose archetype is written stands once, near its anchor.
		t.it("builds every one-off once, near its anchor", function()
			local problems: { string } = {}
			for _, id in plan.city.unplaced do
				table.insert(problems, `{id}: found no site near its anchor`)
			end
			for _, entry in City.landmarks do
				if notReady[entry.id] or City.notOnPlots[entry.id] then
					continue
				end
				local found = 0
				for _, site in plan.sites do
					if site.archetype == entry.id and site.landmark then
						found += 1
						local far = (Vector2.new(site.frame.X, site.frame.Z) - entry.at).Magnitude
						if far > (entry.radius or City.landmarkRadius) + site.width / 2 + site.depth then
							table.insert(problems, `{entry.id}: {math.round(far)} studs from its anchor`)
						end
					end
				end
				if found ~= 1 then
					table.insert(problems, `{entry.id}: built {found} times as a one-off`)
				end
			end
			report(t, "one-off", problems)
		end)

		-- Neighbours (beside, across the street, round the corner) never share an archetype, except across the street
		-- as the last resort, a palette apart and rules.acrossHeight taller or lower; no look (archetype, palette, crown,
		-- rhythm) twice while its archetype has looks left; no two towers near each other within two floors of one
		-- height; and most sites light up at night.
		t.it(
			"never stands twins side by side, repeats a look or twins a tower's height, and lights most sites",
			function()
				local rules = City.rules
				local problems: { string } = {}
				local sites = plan.sites
				for a = 1, #sites do
					local one = sites[a]
					for b = a + 1, #sites do
						local other = sites[b]
						if
							one.archetype == other.archetype
							and CityBuilder.gapBetween(one, other) <= rules.neighbourGap
						then
							local apart = rules.acrossHeight * math.max(one.height, other.height) - 0.01
							local across = one.block ~= other.block
								and one.variant.palette ~= other.variant.palette
								and math.abs(one.height - other.height) >= apart
							if not across then
								table.insert(problems, `{one.id} and {other.id}: two {one.archetype} side by side`)
							end
						end
						if one.height >= City.bands.T and other.height >= City.bands.T then
							local far = (Vector2.new(one.frame.X, one.frame.Z) - Vector2.new(
								other.frame.X,
								other.frame.Z
							)).Magnitude
							if
								far <= rules.twinRange
								and math.abs(one.height - other.height) < rules.twinGap - 0.01
							then
								table.insert(
									problems,
									`{one.id} and {other.id}: towers {math.round(far)} apart, one height`
								)
							end
						end
					end
				end
				local looks: { [string]: string } = {}
				local copies: { [string]: number } = {}
				for _, site in sites do
					copies[site.archetype] = (copies[site.archetype] or 0) + 1
				end
				local lit = 0
				for _, site in sites do
					local config = City.archetypes[site.archetype]
					local v = site.variant
					local key = `{site.archetype}:{v.palette}:{v.crown}:{v.rhythm}`
					if looks[key] and config.palettes * config.crowns * config.rhythms >= copies[site.archetype] then
						table.insert(problems, `{site.id} and {looks[key]}: one look`)
					end
					looks[key] = site.id
					local specs: { PartSpec } = bySite[site.id] or {}
					for _, spec in specs do
						if spec.tag == Environment.nightLights.tag then
							lit += 1
							break
						end
					end
				end
				print(`  MapBuilder: {lit} of {#sites} city sites light up at night`)
				report(t, "city rules", problems)
				t.expect(lit >= 0.4 * #sites).toBe(true)
			end
		)

		-- SLIM models hold still parts only (docs/city/TECH.md §6): night lights, signs, lights and ad units change at
		-- runtime, so they live in each site's lights model. The Skyline model is Persistent.
		t.it("keeps night lights, signs and lights out of SLIM models, and the Skyline Persistent", function()
			local slim: { [string]: boolean } = {}
			local kinds: { [string]: MapBuilder.Container } = {}
			for _, entry in plan.containers do
				kinds[entry.path] = entry
				if entry.lod == "SLIM" then
					slim[entry.path] = true
				end
			end
			local problems: { string } = {}
			for _, spec in plan.specs do
				if slim[spec.folder] and CityBuilder.isLight(spec) then
					table.insert(problems, `{spec.folder}/{spec.name}: changes at runtime, in a SLIM model`)
				end
				if spec.folder == City.skyline.folder then
					local entry = kinds[spec.folder]
					if entry == nil or entry.streaming ~= Enum.ModelStreamingMode.Persistent then
						table.insert(problems, `{spec.folder}: not a Persistent model`)
					end
				end
			end
			for _, site in plan.sites do
				local entry = kinds[site.folder]
				if entry == nil or entry.lod ~= "SLIM" or entry.streaming ~= Enum.ModelStreamingMode.Atomic then
					table.insert(problems, `{site.folder}: not an Atomic SLIM model`)
				end
			end
			report(t, "slim", problems)
		end)

		t.it("builds the hills, parks and features where MapLayout puts them, off the roads", function()
			local byPath: { [string]: PartSpec } = {}
			local featureParts: { [string]: number } = {}
			for _, spec in plan.specs do
				byPath[`{spec.folder}/{spec.name}`] = spec
				local id = string.match(spec.folder, "^Features/(.+)$")
				if id then
					featureParts[id] = (featureParts[id] or 0) + 1
				end
			end
			local problems: { string } = {}
			for _, hill in MapLayout.hills do
				local top = byPath[`Ground/{hill.id}Top`]
				if top == nil then
					table.insert(problems, `hill {hill.id}: not built`)
				elseif math.abs(top.cframe.Y + top.size.Y / 2 - hill.height) > 1e-3 then
					table.insert(problems, `hill {hill.id}: its top isn't at {hill.height}`)
				end
				local ground =
					MapLayout.groundHeight((hill.topMin.X + hill.topMax.X) / 2, (hill.topMin.Y + hill.topMax.Y) / 2)
				if math.abs(ground - hill.height) > 1e-3 then
					table.insert(problems, `hill {hill.id}: MapLayout.groundHeight doesn't know it`)
				end
				if hill.topMin.X - (hill.height + 1) / hill.slope < MapLayout.reservedWestOfX then
					table.insert(problems, `hill {hill.id}: reaches into the dev track's ground`)
				end
			end
			for _, feature in MapLayout.features do
				if (featureParts[feature.id] or 0) == 0 then
					table.insert(problems, `feature {feature.id}: not built`)
				end
			end
			for _, park in MapLayout.parks do
				local color = park.groundColor
				if color then
					local found = false
					for _, spec in plan.specs do
						local p = spec.cframe.Position
						if
							spec.folder == "Ground"
							and spec.color == color
							and p.X > park.min.X
							and p.X < park.max.X
							and p.Z > park.min.Y
							and p.Z < park.max.Y
						then
							found = true
							break
						end
					end
					if not found then
						table.insert(problems, `park {park.id}: no ground of its own`)
					end
				end
				for _, spec in plan.specs do
					local p = spec.cframe.Position
					local inPark = p.X > park.min.X and p.X < park.max.X and p.Z > park.min.Y and p.Z < park.max.Y
					local hole = park.hole
					if hole and p.X > hole.min.X and p.X < hole.max.X and p.Z > hole.min.Y and p.Z < hole.max.Y then
						inPark = false
					end
					if inPark and (spec.role == "building" or spec.role == "lot") then
						table.insert(problems, `park {park.id}: {spec.folder}/{spec.name} stands in it`)
					end
				end
			end
			report(t, "map", problems)
			-- Hills and features never reach a road, sidewalk, pad or building.
			local function isHillOrFeature(spec: PartSpec): boolean
				if spec.role == "feature" then
					return true
				end
				if spec.folder ~= "Ground" then
					return false
				end
				for _, hill in MapLayout.hills do
					if string.sub(spec.name, 1, #hill.id) == hill.id then
						return true
					end
				end
				return false
			end
			report(
				t,
				"hill or feature",
				pickedOverlaps(plan, isHillOrFeature, {
					road = true,
					pad = true,
					sidewalk = true,
					support = true,
					location = true,
					displayPad = true,
					building = true,
					lot = true,
					landmark = true,
					light = true,
				})
			)
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

		t.it("builds every dealership and used-lot display pad with its tag and attributes", function()
			local pads = Dealership.pads
			local byKey: { [string]: PartSpec } = {}
			local signs: { [string]: PartSpec } = {}
			for _, spec in plan.specs do
				local attributes: { [string]: any } = spec.attributes or {}
				if spec.tag == pads.dealershipTag then
					byKey[`{attributes[pads.brandAttribute]}:{attributes[pads.indexAttribute]}`] = spec
				elseif spec.tag == pads.usedLotTag then
					byKey[`usedLot:{attributes[pads.indexAttribute]}`] = spec
				elseif spec.role == "sign" and spec.name == "Sign" then
					signs[spec.folder] = spec
				end
			end
			local problems: { string } = {}
			local function expectPad(key: string, pad: CFrame, size: Vector3)
				local spec = byKey[key]
				if spec == nil then
					table.insert(problems, `{key}: no pad`)
				elseif spec.role ~= "displayPad" or (spec.size - size).Magnitude > 1e-3 then
					table.insert(problems, `{key}: role {spec.role}, size {spec.size}`)
				elseif (spec.cframe.Position - (pad.Position + Vector3.yAxis * size.Y / 2)).Magnitude > 1e-3 then
					table.insert(problems, `{key}: not where MapLayout puts it`)
				end
			end
			for _, section in MapLayout.dealership.sections do
				for i, pad in section.pads do
					expectPad(`{section.brandId}:{i}`, pad, MapLayout.dealership.padSize)
				end
				local sign = signs[`Dealership/{section.brandId}`]
				local labels = if sign then sign.labels or {} else {}
				local brand = Brands[section.brandId]
				if sign == nil or #labels == 0 or brand == nil or labels[1].text ~= brand.displayName then
					table.insert(problems, `{section.brandId}: no sign with the brand's name`)
				end
			end
			for i, pad in MapLayout.usedLot.pads do
				expectPad(`usedLot:{i}`, pad, MapLayout.usedLot.padSize)
			end
			report(t, "display pad", problems)
			t.expect(#MapLayout.usedLot.pads >= 8).toBe(true)
		end)

		t.it("keeps buildings, lots, sidewalks, roads, lights and props off the display pads", function()
			report(
				t,
				"display pad",
				crossOverlaps(plan, { displayPad = true }, {
					building = true,
					lot = true,
					sidewalk = true,
					road = true,
					pad = true,
					light = true,
					prop = true,
					landmark = true,
					location = true,
					support = true,
					sign = true,
				})
			)
		end)

		t.it("clears the dealership's mall block of buildings", function()
			-- The rectangle round the dealership pads that face north (the block across from the showroom).
			local minX, maxX, minZ, maxZ = math.huge, -math.huge, math.huge, -math.huge
			local size = MapLayout.dealership.padSize
			for _, section in MapLayout.dealership.sections do
				for _, pad in section.pads do
					if pad.LookVector.Z < -0.5 then
						minX, maxX =
							math.min(minX, pad.Position.X - size.X / 2), math.max(maxX, pad.Position.X + size.X / 2)
						minZ, maxZ =
							math.min(minZ, pad.Position.Z - size.Z / 2), math.max(maxZ, pad.Position.Z + size.Z / 2)
					end
				end
			end
			local built: { string } = {}
			for _, spec in plan.specs do
				local p = spec.cframe.Position
				if
					(spec.role == "building" or spec.role == "lot")
					and p.X > minX
					and p.X < maxX
					and p.Z > minZ
					and p.Z < maxZ
				then
					table.insert(built, `{spec.folder}/{spec.name}`)
				end
			end
			report(t, "building in the mall", built)
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

		t.it(
			"streams the ground and roads as Persistent models and blocks, trees and features as Atomic ones",
			function()
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
					local tiled = string.find(spec.folder, "^Buildings/")
						or string.find(spec.folder, "^BuildingLights/")
						or string.find(spec.folder, "^Trees/")
						or string.find(spec.folder, "^Features/")
					if tiled then
						local entry = kinds[spec.folder]
						if entry == nil or entry.streaming ~= Enum.ModelStreamingMode.Atomic then
							table.insert(unknown, `{spec.folder} is not Atomic`)
						end
					end
				end
				report(t, "container", unknown)
			end
		)

		-- Streetlights only: a city building's facade wash (Dev/City Kit.wash) carries a SurfaceLight of its own and is
		-- held to its archetype's budget instead (tests/City.spec).
		t.it("lights at most one streetlight per 200 studs", function()
			local lit: { Vector3 } = {}
			for _, spec in plan.specs do
				if spec.light and spec.role == "light" then
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

		-- Services/DayNightService switches these at dusk and dawn (tests/DayNight.spec has its maths).
		t.it("tags every night light with a kind DayNightService knows and its day colour, its light off", function()
			local lights = Environment.nightLights
			local problems: { string } = {}
			local counts: { [string]: number } = {}
			for _, spec in plan.specs do
				if spec.tag == lights.tag then
					local attributes: { [string]: any } = spec.attributes or {}
					local kind = attributes[lights.kindAttribute]
					local look = if type(kind) == "string" then lights.kinds[kind] else nil
					if look == nil then
						table.insert(problems, `{spec.folder}/{spec.name}: kind {tostring(kind)}`)
					else
						counts[kind] = (counts[kind] or 0) + 1
						if spec.material ~= look.dayMaterial then
							table.insert(problems, `{spec.folder}/{spec.name}: not built in its day look`)
						end
					end
					if typeof(attributes[lights.dayColorAttribute]) ~= "Color3" then
						table.insert(problems, `{spec.folder}/{spec.name}: no day colour`)
					end
					local light = spec.light
					if light and light.enabled ~= false then
						table.insert(problems, `{spec.folder}/{spec.name}: its light is built on`)
					end
				end
			end
			t.expect(table.concat(problems, "; ")).toBe("")
			for _, kind in { "streetlight", "window", "sign", "beacon", "arch", "floodlight" } do
				t.expect(counts[kind] or 0).toBeGreaterThan(0)
			end
		end)
	end)
end
