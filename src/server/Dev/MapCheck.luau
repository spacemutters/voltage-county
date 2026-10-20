--!strict
-- MapCheck: the script check of the built county (PLAN.md Phase 2 acceptance; docs/phase-2-contracts.md,
-- "World settings and test tooling"). It
--   1. builds the map twice with Dev/MapBuilder and compares the instance counts (they must match);
--   2. looks for road parts (Workspace.Map.Generated.Roads: Segments and Intersections) that overlap in volume
--      by more than SETTINGS.overlapTolerance, with separating-axis math on the real parts (oriented boxes;
--      cylinders and balls by their true shape). A bridge passing over another road with clearance is allowed;
--   3. checks every MapLayout location has its part under Generated.Locations, with its tag and attributes
--      (plus DisplayName and Zone), and that its footprint comes within RoadGraph.roadReach of a road;
--   4. checks every road node is reachable from the node nearest the used lot;
--   5. times Pathfind.route from the player spawn to every location, GPS destinations included (max and mean
--      ms; each call must stay under 5 ms).
-- It also confirms the Ground and Roads models stream as Persistent (so a fast car never outruns its road).
--
-- Edit-mode tool only (CLAUDE.md hard rule 9). Run it from MCP execute_luau (Edit datamodel) or the command bar:
--   require(game.ServerScriptService.Server.Dev.MapCheck).run()
-- run({ build = false }) checks the map as it stands without rebuilding (skips step 1, so `counts` holds only
-- the current instance count).
--
-- Returns a Report and prints a summary. `ok` is true only when every check passed. Lists are plain strings:
-- overlaps read "partA x partB depth" (paths below Roads, depth in studs), the others name what is wrong.

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Graph = require(ReplicatedStorage.Shared.Road.Graph)
local MapBuilder = require(script.Parent.MapBuilder)
local MapLayout = require(ReplicatedStorage.Shared.Config.MapLayout)
local Pathfind = require(ReplicatedStorage.Shared.Road.Pathfind)
local RoadGraph = require(ReplicatedStorage.Shared.Config.RoadGraph)

export type Report = {
	ok: boolean,
	counts: { number }, -- instance count after each build
	overlaps: { string }, -- "partA x partB depth"
	missing: { string }, -- locations without their part, tag or attributes; missing folders; streaming modes
	unreachable: { string }, -- road nodes the used lot can't reach, locations too far from a road, failed routes
	routeMs: { max: number, mean: number },
	notes: { string }, -- information that doesn't fail the check
}

export type Options = {
	build: boolean?, -- rebuild twice first (default true)
}

-- A convex solid standing in for one part, for the overlap check.
export type Solid = {
	kind: "box" | "cylinder" | "ball",
	center: Vector3,
	axes: { Vector3 }, -- box: its three unit axes; cylinder: { its length axis }; ball: {}
	half: { number }, -- box: half its size along each axis; cylinder: { half its length }; ball: {}
	radius: number, -- cylinder and ball; 0 for a box
	min: Vector3, -- world-axis bounding box
	max: Vector3,
	exact: boolean, -- false when a wedge, mesh or union is stood in for by its whole box
}

-- A dev tool, so its numbers live here rather than in Shared/Config (like Dev/AutoDriver's TUNING).
local SETTINGS = {
	overlapTolerance = 0.05, -- studs of overlap allowed between two road parts (contracts)
	bridgeClearance = 15, -- studs between a bridge's surface and the road under it (contracts, RoadGraph rules)
	routeBudgetMs = 5, -- each Pathfind.route call must take less than this (PLAN.md Phase 2)
	routeRepeats = 3, -- each route is timed this many times and the median kept, so one GC pause can't fail it
	printLimit = 25, -- lines printed per list (the Report always holds every entry)
	bridgeWords = { "bridge" }, -- a part is a bridge when its name, or a folder or model above it, has one
	bridgeAttributes = { "Kind", "RoadKind", "EdgeKind" }, -- ...or one of these attributes says "bridge"
}

local EPSILON = 1e-6
local WORLD_AXES = { Vector3.xAxis, Vector3.yAxis, Vector3.zAxis }

---------------------------------------------------------------------------------------------------------------
-- Geometry (pure). Exposed as MapCheck.Geometry so a spec can check it.
---------------------------------------------------------------------------------------------------------------

local Geometry = {}

-- Half the length of a solid's shadow on a unit axis.
function Geometry.extent(solid: Solid, axis: Vector3): number
	if solid.kind == "ball" then
		return solid.radius
	elseif solid.kind == "cylinder" then
		-- A cylinder's shadow: its length along the axis plus its round face across it.
		local along = math.abs(solid.axes[1]:Dot(axis))
		return solid.half[1] * along + solid.radius * math.sqrt(math.max(0, 1 - along * along))
	end
	local axes, half = solid.axes, solid.half
	return math.abs(axes[1]:Dot(axis)) * half[1]
		+ math.abs(axes[2]:Dot(axis)) * half[2]
		+ math.abs(axes[3]:Dot(axis)) * half[3]
end

-- A solid from its shape, centre and axes, with its world bounding box filled in.
function Geometry.solid(kind: "box" | "cylinder" | "ball", cframe: CFrame, size: Vector3, exact: boolean): Solid
	local solid: Solid = {
		kind = kind,
		center = cframe.Position,
		axes = {},
		half = {},
		radius = 0,
		min = cframe.Position,
		max = cframe.Position,
		exact = exact,
	}
	if kind == "box" then
		solid.axes = { cframe.RightVector, cframe.UpVector, cframe.LookVector }
		solid.half = { size.X / 2, size.Y / 2, size.Z / 2 }
	elseif kind == "cylinder" then
		-- Roblox cylinders run along their local X axis.
		solid.axes = { cframe.RightVector }
		solid.half = { size.X / 2 }
		solid.radius = math.min(size.Y, size.Z) / 2
	else
		solid.radius = math.min(size.X, size.Y, size.Z) / 2
	end
	local reach = Vector3.new(
		Geometry.extent(solid, Vector3.xAxis),
		Geometry.extent(solid, Vector3.yAxis),
		Geometry.extent(solid, Vector3.zAxis)
	)
	solid.min = solid.center - reach
	solid.max = solid.center + reach
	return solid
end

-- The solid for a part: blocks, cylinders and balls exactly; anything else (wedges, meshes, unions) by its box.
function Geometry.fromPart(part: BasePart): Solid
	if part:IsA("Part") then
		local shape = (part :: Part).Shape
		if shape == Enum.PartType.Block then
			return Geometry.solid("box", part.CFrame, part.Size, true)
		elseif shape == Enum.PartType.Cylinder then
			return Geometry.solid("cylinder", part.CFrame, part.Size, true)
		elseif shape == Enum.PartType.Ball then
			return Geometry.solid("ball", part.CFrame, part.Size, true)
		end
	end
	return Geometry.solid("box", part.CFrame, part.Size, false)
end

-- The point of a solid closest to `point` (for the axis that separates a round solid from another).
local function closestPoint(solid: Solid, point: Vector3): Vector3
	local offset = point - solid.center
	if solid.kind == "box" then
		local result = solid.center
		for i, axis in solid.axes do
			result += axis * math.clamp(offset:Dot(axis), -solid.half[i], solid.half[i])
		end
		return result
	elseif solid.kind == "cylinder" then
		local axis = solid.axes[1]
		local along = math.clamp(offset:Dot(axis), -solid.half[1], solid.half[1])
		local across = offset - axis * offset:Dot(axis)
		if across.Magnitude > solid.radius then
			across = across.Unit * solid.radius
		end
		return solid.center + axis * along + across
	end
	if offset.Magnitude > solid.radius then
		return solid.center + offset.Unit * solid.radius
	end
	return point
end

-- For a round solid, the direction from its axis (or centre) toward the nearest point of the other solid.
local function roundAxis(round: Solid, other: Solid): Vector3?
	local toward = closestPoint(other, round.center) - round.center
	if round.kind == "cylinder" then
		local axis = round.axes[1]
		toward -= axis * toward:Dot(axis)
	end
	return if toward.Magnitude > EPSILON then toward.Unit else nil
end

-- The axes worth testing for a pair: each solid's face normals, every cross product of their edge directions
-- (the 15 axes that decide two boxes exactly), the world axes, and for round solids the direction toward the
-- other solid.
local function candidateAxes(a: Solid, b: Solid): { Vector3 }
	local axes: { Vector3 } = {}
	local function add(axis: Vector3?)
		if axis and axis.Magnitude > EPSILON then
			table.insert(axes, axis.Unit)
		end
	end
	for _, axis in a.axes do
		add(axis)
	end
	for _, axis in b.axes do
		add(axis)
	end
	for _, edgeA in a.axes do
		for _, edgeB in b.axes do
			add(edgeA:Cross(edgeB))
		end
	end
	for _, axis in WORLD_AXES do
		add(axis)
	end
	if a.kind ~= "box" then
		add(roundAxis(a, b))
	end
	if b.kind ~= "box" then
		add(roundAxis(b, a))
	end
	return axes
end

-- How far two solids overlap (studs): the smallest overlap of their shadows over the candidate axes, which for
-- two boxes is exactly the depth one must move to clear the other. 0 when they are apart or only touch.
-- Extra axes can only tighten the answer: no axis ever shows less overlap than the true depth.
function Geometry.overlapDepth(a: Solid, b: Solid): number
	local offset = b.center - a.center
	local depth = math.huge
	for _, axis in candidateAxes(a, b) do
		local overlap = Geometry.extent(a, axis) + Geometry.extent(b, axis) - math.abs(offset:Dot(axis))
		if overlap <= 0 then
			return 0
		end
		depth = math.min(depth, overlap)
	end
	return depth
end

-- Height of a solid's top surface above the point (x, z): the face whose outward normal points most nearly up.
function Geometry.topAt(solid: Solid, x: number, z: number): number
	if solid.kind == "ball" then
		return solid.center.Y + solid.radius
	end
	local normal, half = Vector3.yAxis, 0
	local best = -1
	for i, axis in solid.axes do
		if math.abs(axis.Y) > best then
			best = math.abs(axis.Y)
			normal = if axis.Y >= 0 then axis else -axis
			half = solid.half[i]
		end
	end
	if solid.kind == "cylinder" and best < 0.5 then
		return solid.max.Y -- lying on its side: the top of its round face
	elseif best < EPSILON then
		return solid.max.Y
	end
	-- Points p on the top face satisfy (p - centre) . normal = half.
	local c = solid.center
	return c.Y + (half - normal.X * (x - c.X) - normal.Z * (z - c.Z)) / normal.Y
end

-- A rectangle on the ground (X and Z).
export type Rect = { minX: number, maxX: number, minZ: number, maxZ: number }

local function pointRectDistance(p: Vector2, rect: Rect): number
	local dx = math.max(rect.minX - p.X, 0, p.X - rect.maxX)
	local dz = math.max(rect.minZ - p.Y, 0, p.Y - rect.maxZ)
	return math.sqrt(dx * dx + dz * dz)
end

local function pointSegmentDistance(p: Vector2, a: Vector2, b: Vector2): number
	local ab = b - a
	local lengthSquared = ab:Dot(ab)
	local t = if lengthSquared > 0 then math.clamp((p - a):Dot(ab) / lengthSquared, 0, 1) else 0
	return (a + ab * t - p).Magnitude
end

-- True when the segment a-b passes through the rectangle (Liang-Barsky clipping).
local function segmentHitsRect(a: Vector2, b: Vector2, rect: Rect): boolean
	local t0, t1 = 0, 1
	local d = b - a
	local function clip(p: number, q: number): boolean
		if p == 0 then
			return q >= 0 -- parallel to this side: inside only if it starts inside
		end
		local r = q / p
		if p < 0 then
			t0 = math.max(t0, r)
		else
			t1 = math.min(t1, r)
		end
		return t0 <= t1
	end
	return clip(-d.X, a.X - rect.minX)
		and clip(d.X, rect.maxX - a.X)
		and clip(-d.Y, a.Y - rect.minZ)
		and clip(d.Y, rect.maxZ - a.Y)
end

-- Shortest distance on the ground between the segment a-b and the rectangle (0 when they touch).
function Geometry.segmentRectDistance(a: Vector2, b: Vector2, rect: Rect): number
	if segmentHitsRect(a, b, rect) then
		return 0
	end
	local best = math.min(pointRectDistance(a, rect), pointRectDistance(b, rect))
	for _, corner in
		{
			Vector2.new(rect.minX, rect.minZ),
			Vector2.new(rect.maxX, rect.minZ),
			Vector2.new(rect.minX, rect.maxZ),
			Vector2.new(rect.maxX, rect.maxZ),
		}
	do
		best = math.min(best, pointSegmentDistance(corner, a, b))
	end
	return best
end

---------------------------------------------------------------------------------------------------------------
-- The checks
---------------------------------------------------------------------------------------------------------------

type RoadPart = { part: BasePart, solid: Solid, name: string }

local function format(value: number): string
	return string.format("%.2f", value)
end

-- The path of an instance below `root`, e.g. "Segments/edge_12".
local function pathBelow(instance: Instance, root: Instance): string
	local names: { string } = {}
	local node: Instance? = instance
	while node and node ~= root do
		table.insert(names, 1, node.Name)
		node = node.Parent
	end
	return table.concat(names, "/")
end

local function hasBridgeWord(name: string): boolean
	local lower = string.lower(name)
	for _, word in SETTINGS.bridgeWords do
		if string.find(lower, word, 1, true) then
			return true
		end
	end
	return false
end

-- The graph edge whose centre line passes closest to `point` in 3D (so a bridge deck and the road under it
-- are told apart by height).
local function nearestEdge3D(point: Vector3): RoadGraph.Edge?
	local best: RoadGraph.Edge? = nil
	local bestDistance = math.huge
	for _, edge in Graph.edges() do
		local from, to = Graph.node(edge.from), Graph.node(edge.to)
		if from and to then
			local a, ab = from.position, to.position - from.position
			local lengthSquared = ab:Dot(ab)
			local t = if lengthSquared > 0 then math.clamp((point - a):Dot(ab) / lengthSquared, 0, 1) else 0
			local distance = (a + ab * t - point).Magnitude
			if distance < bestDistance then
				best, bestDistance = edge, distance
			end
		end
	end
	return best
end

-- A part belongs to a bridge when an attribute, its name or a container's name says so, or when the road
-- edge nearest to it in 3D is a bridge edge.
local function isBridge(part: BasePart, roads: Instance): boolean
	local node: Instance? = part
	while node and node ~= roads do
		for _, key in SETTINGS.bridgeAttributes do
			if node:GetAttribute(key) == "bridge" then
				return true
			end
		end
		if hasBridgeWord(node.Name) then
			return true
		end
		node = node.Parent
	end
	local edge = nearestEdge3D(part.Position)
	return edge ~= nil and edge.kind == "bridge"
end

-- Two parts inside the same sub-model (not the Roads, Segments or Intersections containers themselves) are
-- one piece of road by construction, so they aren't compared.
local function samePiece(a: BasePart, b: BasePart, containers: { [Instance]: boolean }): boolean
	local parent = a.Parent
	return parent ~= nil and parent == b.Parent and parent:IsA("Model") and not containers[parent]
end

-- Every driving-surface part under Roads/Segments and Roads/Intersections. Paint and other parts that neither
-- collide nor take raycasts are skipped.
local function collectRoadParts(roads: Instance, report: Report): { RoadPart }
	local parts: { RoadPart } = {}
	local skipped, approximate = 0, 0
	for _, folderName in { "Segments", "Intersections" } do
		local folder = roads:FindFirstChild(folderName)
		if folder == nil then
			table.insert(report.missing, `Roads/{folderName} (Workspace.Map.Generated.Roads.{folderName})`)
			continue
		end
		for _, descendant in folder:GetDescendants() do
			if descendant:IsA("BasePart") then
				if descendant.CanCollide or descendant.CanQuery then
					local solid = Geometry.fromPart(descendant)
					if not solid.exact then
						approximate += 1
					end
					table.insert(parts, { part = descendant, solid = solid, name = pathBelow(descendant, roads) })
				else
					skipped += 1
				end
			end
		end
	end
	table.insert(report.notes, `{#parts} road parts compared for overlaps ({skipped} decorative parts skipped)`)
	if approximate > 0 then
		table.insert(report.notes, `{approximate} road parts are wedges, meshes or unions: checked as their whole box`)
	end
	return parts
end

-- Step 2: every overlapping pair of road parts, found by sweeping their bounding boxes along X and then
-- measuring candidates with the separating-axis test.
local function checkOverlaps(generated: Instance, report: Report)
	local roads = generated:FindFirstChild("Roads")
	if roads == nil then
		table.insert(report.missing, "Roads (Workspace.Map.Generated.Roads)")
		return
	end
	local containers: { [Instance]: boolean } = { [roads] = true }
	for _, name in { "Segments", "Intersections" } do
		local folder = roads:FindFirstChild(name)
		if folder then
			containers[folder] = true
		end
	end

	local parts = collectRoadParts(roads, report)
	table.sort(parts, function(a, b)
		return a.solid.min.X < b.solid.min.X
	end)

	local tolerance = SETTINGS.overlapTolerance
	local bridgesAllowed = 0
	for i, a in parts do
		for j = i + 1, #parts do
			local b = parts[j]
			-- Sorted by min X: once one starts past a's far side, every later one does too.
			if b.solid.min.X >= a.solid.max.X - tolerance then
				break
			end
			local low = Vector3.new(
				b.solid.min.X,
				math.max(a.solid.min.Y, b.solid.min.Y),
				math.max(a.solid.min.Z, b.solid.min.Z)
			)
			local high = a.solid.max:Min(b.solid.max)
			-- The true depth is never more than the bounding boxes' overlap on any axis.
			local boxOverlap = math.min(high.X - low.X, high.Y - low.Y, high.Z - low.Z)
			if boxOverlap > tolerance and not samePiece(a.part, b.part, containers) then
				local depth = Geometry.overlapDepth(a.solid, b.solid)
				if depth > tolerance then
					-- A bridge over another road: measure the gap between their surfaces where they cross.
					local x, z = (low.X + high.X) / 2, (low.Z + high.Z) / 2
					local gap = math.abs(Geometry.topAt(a.solid, x, z) - Geometry.topAt(b.solid, x, z))
					if gap >= SETTINGS.bridgeClearance and (isBridge(a.part, roads) or isBridge(b.part, roads)) then
						bridgesAllowed += 1
					else
						table.insert(report.overlaps, `{a.name} x {b.name} {format(depth)}`)
					end
				end
			end
		end
	end
	if bridgesAllowed > 0 then
		table.insert(
			report.notes,
			`{bridgesAllowed} bridge crossings allowed (surfaces {SETTINGS.bridgeClearance}+ studs apart)`
		)
	end
end

-- How far (studs) a location's footprint is from the side of the nearest road; 0 or less means it touches one.
local function roadGap(location: MapLayout.Location): number
	local frame = CFrame.new(location.position) * CFrame.Angles(0, math.rad(location.yaw), 0)
	local half = location.size / 2
	local rect: Rect = { minX = -half.X, maxX = half.X, minZ = -half.Z, maxZ = half.Z }
	local best = math.huge
	for index, edge in Graph.edges() do
		local from, to = Graph.node(edge.from), Graph.node(edge.to)
		if from and to then
			-- Measure in the location's own frame, where its footprint is an upright rectangle.
			local a = frame:PointToObjectSpace(from.position)
			local b = frame:PointToObjectSpace(to.position)
			local distance = Geometry.segmentRectDistance(Vector2.new(a.X, a.Z), Vector2.new(b.X, b.Z), rect)
			best = math.min(best, distance - Graph.edgeWidth(index) / 2)
		end
	end
	return best
end

-- Step 3: each location's part, tag, attributes and road reach.
local function checkLocations(generated: Instance, report: Report)
	local folder = generated:FindFirstChild("Locations")
	if folder == nil then
		table.insert(report.missing, "Locations (Workspace.Map.Generated.Locations)")
		return
	end
	local expected: { [string]: boolean } = {}
	for _, location in MapLayout.locations do
		local id = location.id
		expected[id] = true

		local found = folder:FindFirstChild(id)
		if found == nil or not found:IsA("BasePart") then
			table.insert(report.missing, `{id}: no part`)
		else
			local part = found :: BasePart
			if not CollectionService:HasTag(part, location.tag) then
				table.insert(report.missing, `{id}: no {location.tag} tag`)
			end
			local wanted: { [string]: any } = { DisplayName = location.displayName, Zone = location.zone }
			for key, value in location.attributes or {} do
				wanted[key] = value
			end
			for key, value in wanted do
				local actual = part:GetAttribute(key)
				if actual ~= value then
					table.insert(report.missing, `{id}: attribute {key} is {tostring(actual)}, want {tostring(value)}`)
				end
			end
			if (part.Size - location.size).Magnitude > SETTINGS.overlapTolerance then
				table.insert(
					report.notes,
					`{id}: part size {tostring(part.Size)}, layout says {tostring(location.size)}`
				)
			end
		end

		local gap = roadGap(location)
		if gap > RoadGraph.roadReach then
			table.insert(
				report.unreachable,
				`location {id}: {format(gap)} studs from the nearest road (reach {RoadGraph.roadReach})`
			)
		end
	end
	for _, child in folder:GetChildren() do
		if not expected[child.Name] then
			table.insert(report.notes, `Locations/{child.Name} is not in MapLayout`)
		end
	end
end

-- The used lot's position (where new players spawn), or nil.
local function usedLotPosition(): Vector3?
	for _, location in MapLayout.locations do
		if location.tag == "UsedLot" then
			return location.position
		end
	end
	return nil
end

-- Step 4: breadth-first search over the graph from the node nearest the used lot.
local function checkReachable(report: Report)
	local from = usedLotPosition()
	if from == nil then
		table.insert(report.missing, "a UsedLot location in MapLayout (reachability starts there)")
		local first = MapLayout.playerSpawns[1]
		from = if first then first.Position else Vector3.zero
	end
	local startId = Graph.nearestNode(from :: Vector3)
	if startId == nil then
		table.insert(report.unreachable, "no road node near the used lot")
		return
	end
	local seen: { [string]: boolean } = { [startId] = true }
	local queue: { string } = { startId }
	local head = 1
	while head <= #queue do
		local id = queue[head]
		head += 1
		for _, link in Graph.neighbors(id) do
			if not seen[link.node] then
				seen[link.node] = true
				table.insert(queue, link.node)
			end
		end
	end
	for _, node in Graph.nodes() do
		if not seen[node.id] then
			table.insert(report.unreachable, `node {node.id} ({node.zone})`)
		end
	end
	table.insert(report.notes, `{#queue} of {#Graph.nodes()} road nodes reachable from {startId} (used lot)`)
end

-- Step 5: time Pathfind.route from the player spawn to every location.
local function timeRoutes(report: Report)
	local firstSpawn = MapLayout.playerSpawns[1]
	local from = if firstSpawn then firstSpawn.Position else usedLotPosition()
	if from == nil then
		table.insert(report.missing, "a player spawn in MapLayout.playerSpawns (routes start there)")
		return
	end
	local start = from :: Vector3
	-- One untimed call first, so the graph's one-time setup isn't counted against the first destination.
	pcall(Pathfind.route, start, start)

	local total, count, gps = 0, 0, 0
	for _, location in MapLayout.locations do
		local samples: { number } = {}
		local routed = true
		for i = 1, SETTINGS.routeRepeats do
			local began = os.clock()
			local ok, route = pcall(Pathfind.route, start, location.position)
			samples[i] = (os.clock() - began) * 1000
			if not ok then
				routed = false
				table.insert(report.unreachable, `route to {location.id}: error {tostring(route)}`)
				break
			elseif route == nil then
				routed = false
				table.insert(report.unreachable, `route to {location.id}: no route`)
				break
			end
		end
		if routed then
			table.sort(samples)
			local ms = samples[(#samples + 1) // 2]
			report.routeMs.max = math.max(report.routeMs.max, ms)
			total += ms
			count += 1
			if location.gps then
				gps += 1
			end
		end
	end
	report.routeMs.mean = if count > 0 then total / count else 0
	table.insert(
		report.notes,
		`timed {count} routes from the player spawn ({gps} GPS destinations), median of {SETTINGS.routeRepeats} calls each`
	)
	if count > 0 and report.routeMs.max >= SETTINGS.routeBudgetMs then
		table.insert(
			report.notes,
			`slowest route {format(report.routeMs.max)} ms is over the {SETTINGS.routeBudgetMs} ms budget`
		)
	end
end

-- Cars drive on Ground and Roads, so both must be Persistent: never streamed out under a fast car.
local function checkStreaming(generated: Instance, report: Report)
	for _, name in { "Ground", "Roads" } do
		local model = generated:FindFirstChild(name)
		if model == nil then
			table.insert(report.missing, `{name} (Workspace.Map.Generated.{name})`)
		elseif not model:IsA("Model") then
			table.insert(report.missing, `{name}: is a {model.ClassName}, want a Model (Persistent)`)
		elseif (model :: Model).ModelStreamingMode ~= Enum.ModelStreamingMode.Persistent then
			table.insert(
				report.missing,
				`{name}: ModelStreamingMode is {(model :: Model).ModelStreamingMode.Name}, want Persistent`
			)
		end
	end
	if not Workspace.StreamingEnabled then
		table.insert(
			report.notes,
			"Workspace.StreamingEnabled is off here; default.project.json turns it on (rebuild the place or set it in Workspace properties)"
		)
	end
end

local function generatedFolder(): Instance?
	local map = Workspace:FindFirstChild("Map")
	return if map then map:FindFirstChild("Generated") else nil
end

local function printList(title: string, list: { string })
	if #list == 0 then
		return
	end
	print(`[MapCheck] {title} ({#list}):`)
	for i, line in list do
		if i > SETTINGS.printLimit then
			print(`  ...and {#list - SETTINGS.printLimit} more (see the returned report)`)
			break
		end
		print(`  {line}`)
	end
end

local function printReport(report: Report)
	local countText: { string } = {}
	for _, count in report.counts do
		table.insert(countText, tostring(count))
	end
	local counts = table.concat(countText, " / ")
	print(
		`[MapCheck] {if report.ok then "PASS" else "FAIL"}: instances {counts}, {#report.overlaps} overlaps, `
			.. `{#report.missing} missing, {#report.unreachable} unreachable, route max {format(report.routeMs.max)} ms `
			.. `(mean {format(report.routeMs.mean)} ms)`
	)
	printList("overlaps", report.overlaps)
	printList("missing", report.missing)
	printList("unreachable", report.unreachable)
	printList("notes", report.notes)
end

local MapCheck = {}
MapCheck.Geometry = Geometry
MapCheck.SETTINGS = SETTINGS

local running = false

function MapCheck.run(opts: Options?): Report
	if not RunService:IsStudio() then
		error("MapCheck is a Studio-only tool", 2)
	end
	if RunService:IsRunning() then
		error("MapCheck runs in Edit mode only; stop the playtest first", 2)
	end
	if running then
		error("MapCheck is already running", 2)
	end
	running = true

	local report: Report = {
		ok = false,
		counts = {},
		overlaps = {},
		missing = {},
		unreachable = {},
		routeMs = { max = 0, mean = 0 },
		notes = {},
	}

	local ok, err = pcall(function()
		-- Step 1: two builds, same count.
		local countsMatch = true
		if opts == nil or opts.build ~= false then
			for i = 1, 2 do
				local built, count = pcall(MapBuilder.build)
				if not built then
					table.insert(report.notes, `build {i} failed: {tostring(count)}`)
					countsMatch = false
					break
				end
				table.insert(report.counts, count)
			end
			if #report.counts == 2 and report.counts[1] ~= report.counts[2] then
				countsMatch = false
				table.insert(report.notes, `the two builds made different instance counts`)
			end
		else
			table.insert(report.notes, "not rebuilt: the two-build instance count wasn't checked")
		end

		local generated = generatedFolder()
		if generated == nil then
			table.insert(report.missing, "Workspace.Map.Generated (run MapBuilder.build first)")
			return
		end
		local present = #generated:GetDescendants()
		if opts ~= nil and opts.build == false then
			table.insert(report.counts, present)
		elseif #report.counts > 0 and present ~= report.counts[#report.counts] then
			table.insert(
				report.notes,
				`Generated holds {present} instances; MapBuilder.build reported {report.counts[#report.counts]}`
			)
		end

		checkStreaming(generated, report)
		checkOverlaps(generated, report)
		checkLocations(generated, report)
		checkReachable(report)
		timeRoutes(report)

		report.ok = countsMatch
			and #report.overlaps == 0
			and #report.missing == 0
			and #report.unreachable == 0
			and report.routeMs.max < SETTINGS.routeBudgetMs
	end)

	running = false
	if not ok then
		report.ok = false
		table.insert(report.notes, `MapCheck stopped: {tostring(err)}`)
	end
	printReport(report)
	return report
end

return MapCheck
