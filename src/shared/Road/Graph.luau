--!strict
-- Road graph queries (docs/phase-2-contracts.md, "Road modules") over Config/RoadGraph.
--
-- Built once, at first require: node lookup by id, adjacency lists, each edge's length and width, and a uniform
-- grid of cells (RoadGraph.spatialCellSize studs wide) listing the edges and nodes that pass through each cell.
-- The nearest-road queries search the grid outward ring by ring from the query point and stop as soon as no
-- farther cell can hold anything closer, so they look at a handful of edges instead of all of them (Phase 3 asks
-- nearestEdge for every driver every second).
--
-- The module's own functions answer for the county. Graph.fromData builds the same queries over other node and
-- edge lists (tests/Pathfind.spec routes over a small hand-made graph); styles and tunables still come from
-- Config/RoadGraph and zones from Config/MapLayout.
--
-- "Nearest" and "within" distances are horizontal (X and Z only): a car on a road is above its centre line, not on
-- it. A point on an edge is on its centre line, at the road surface height there (interpolated between the edge's
-- two nodes). Everything returned is shared, read-only data: copy it before changing it.

local Config = script.Parent.Parent.Config
local MapLayout = require(Config.MapLayout)
local RoadGraph = require(Config.RoadGraph)
local World = require(Config.World)

export type Node = RoadGraph.Node
export type Edge = RoadGraph.Edge
export type Neighbor = { node: string, edge: number } -- edge = index into edges()

export type Api = {
	-- Builds another graph with the same queries over the given nodes and edges.
	fromData: (nodes: { Node }, edges: { Edge }) -> Api,
	node: (id: string) -> Node?,
	nodes: () -> { Node },
	edges: () -> { Edge },
	neighbors: (id: string) -> { Neighbor },
	edgeWidth: (edgeIndex: number) -> number,
	edgeLength: (edgeIndex: number) -> number,
	-- The point `t` (0..1, clamped) of the way along an edge's centre line, on the road surface.
	pointOnEdge: (edgeIndex: number, t: number) -> Vector3,
	-- Nearest node: its id and horizontal distance (nil and math.huge for an empty graph).
	nearestNode: (position: Vector3) -> (string?, number),
	-- Nearest edge: its index, how far along it (0..1), the horizontal distance, and the closest point on its centre
	-- line (nil, 0, math.huge and `position` for a graph with no edges).
	nearestEdge: (position: Vector3) -> (number?, number, number, Vector3),
	-- Within half the road's width + margin of a centre line (horizontally) and between RoadGraph.onRoadBelow under
	-- and RoadGraph.onRoadAbove over the surface there.
	isOnRoad: (position: Vector3, margin: number?) -> boolean,
	-- The County Loop on or beside a highway or ramp edge (RoadGraph.loopZoneKinds), else the MapLayout zone whose
	-- bounds hold the point, else nil (open country).
	zoneAt: (position: Vector3) -> string?,
}

-- Everything the queries need, precomputed. Per-edge numbers sit in flat arrays for the hot loops.
type State = {
	nodeList: { Node },
	edgeList: { Edge },
	nodeById: { [string]: Node },
	neighborsById: { [string]: { Neighbor } },
	-- edge i runs from (ax, ay, az) to (bx, by, bz)
	ax: { number },
	ay: { number },
	az: { number },
	bx: { number },
	by: { number },
	bz: { number },
	width: { number },
	halfWidth: { number },
	length: { number },
	loopEdge: { boolean }, -- counts as the County Loop for zoneAt
	maxHalfWidth: number,
	maxLoopHalfWidth: number,
	-- The grid: column c, row r (from 0) covers x in [originX + c * cellSize, ...) and z likewise.
	cellSize: number,
	originX: number,
	originZ: number,
	columns: number,
	rows: number,
	edgeCells: { [number]: { number } }, -- cell key -> indices of the edges whose bounding box touches it
	nodeCells: { [number]: { number } }, -- cell key -> indices of the nodes in it
	-- The query that last looked at each edge, so an edge listed in several cells is measured once per query.
	edgeSeen: { number },
	query: number,
}

local EMPTY: { Neighbor } = table.freeze({})

-- The zone the County Loop's nodes carry, and the edge kinds that belong to it.
local LOOP_ZONE = (function(): string?
	for _, node in RoadGraph.nodes do
		if node.id == RoadGraph.loopNodeIds[1] then
			return node.zone
		end
	end
	return nil
end)()
local LOOP_KINDS: { [string]: boolean } = {}
for _, kind in RoadGraph.loopZoneKinds do
	LOOP_KINDS[kind] = true
end

local function cellKey(state: State, column: number, row: number): number
	return row * state.columns + column + 1
end

local function columnOf(state: State, x: number): number
	return math.floor((x - state.originX) / state.cellSize)
end

local function rowOf(state: State, z: number): number
	return math.floor((z - state.originZ) / state.cellSize)
end

local function addToCells(
	state: State,
	cells: { [number]: { number } },
	index: number,
	minX: number,
	maxX: number,
	minZ: number,
	maxZ: number
)
	for row = rowOf(state, minZ), rowOf(state, maxZ) do
		for column = columnOf(state, minX), columnOf(state, maxX) do
			local key = cellKey(state, column, row)
			local list = cells[key]
			if list == nil then
				list = {}
				cells[key] = list
			end
			table.insert(list, index)
		end
	end
end

local function build(nodes: { Node }, edges: { Edge }): State
	local state: State = {
		nodeList = nodes,
		edgeList = edges,
		nodeById = {},
		neighborsById = {},
		ax = {},
		ay = {},
		az = {},
		bx = {},
		by = {},
		bz = {},
		width = {},
		halfWidth = {},
		length = {},
		loopEdge = {},
		maxHalfWidth = 0,
		maxLoopHalfWidth = 0,
		cellSize = RoadGraph.spatialCellSize,
		originX = 0,
		originZ = 0,
		columns = 1,
		rows = 1,
		edgeCells = {},
		nodeCells = {},
		edgeSeen = {},
		query = 0,
	}

	for _, node in nodes do
		state.nodeById[node.id] = node
		state.neighborsById[node.id] = {}
	end

	for i, edge in edges do
		local a, b = state.nodeById[edge.from], state.nodeById[edge.to]
		if a == nil or b == nil then
			error(`Road graph edge {i} ({edge.from} - {edge.to}) names a node that does not exist`)
		end
		table.insert(state.neighborsById[edge.from], { node = edge.to, edge = i })
		table.insert(state.neighborsById[edge.to], { node = edge.from, edge = i })

		state.ax[i], state.ay[i], state.az[i] = a.position.X, a.position.Y, a.position.Z
		state.bx[i], state.by[i], state.bz[i] = b.position.X, b.position.Y, b.position.Z
		state.length[i] = (b.position - a.position).Magnitude
		state.edgeSeen[i] = 0

		local style = RoadGraph.styles[edge.kind]
		local width = edge.lanes * World.laneWidth + 2 * style.shoulder
		state.width[i] = width
		state.halfWidth[i] = width / 2
		state.maxHalfWidth = math.max(state.maxHalfWidth, width / 2)
		state.loopEdge[i] = LOOP_KINDS[edge.kind] == true
		if state.loopEdge[i] then
			state.maxLoopHalfWidth = math.max(state.maxLoopHalfWidth, width / 2)
		end
	end

	-- The grid covers every node; edges are straight, so it covers every edge too.
	if #nodes > 0 then
		local minX, maxX, minZ, maxZ = math.huge, -math.huge, math.huge, -math.huge
		for _, node in nodes do
			minX, maxX = math.min(minX, node.position.X), math.max(maxX, node.position.X)
			minZ, maxZ = math.min(minZ, node.position.Z), math.max(maxZ, node.position.Z)
		end
		state.originX, state.originZ = minX, minZ
		state.columns = columnOf(state, maxX) + 1
		state.rows = rowOf(state, maxZ) + 1
	end

	for i = 1, #edges do
		addToCells(
			state,
			state.edgeCells,
			i,
			math.min(state.ax[i], state.bx[i]),
			math.max(state.ax[i], state.bx[i]),
			math.min(state.az[i], state.bz[i]),
			math.max(state.az[i], state.bz[i])
		)
	end
	for i, node in nodes do
		local p = node.position
		addToCells(state, state.nodeCells, i, p.X, p.X, p.Z, p.Z)
	end

	return state
end

-- How far along edge i (0..1) the point nearest (px, pz) is, and the squared horizontal distance to it.
local function closestOnEdge(state: State, i: number, px: number, pz: number): (number, number)
	local ax, az = state.ax[i], state.az[i]
	local dx, dz = state.bx[i] - ax, state.bz[i] - az
	local lengthSquared = dx * dx + dz * dz
	local t = if lengthSquared > 0 then math.clamp(((px - ax) * dx + (pz - az) * dz) / lengthSquared, 0, 1) else 0
	local ox, oz = ax + dx * t - px, az + dz * t - pz
	return t, ox * ox + oz * oz
end

local function pointOn(state: State, i: number, t: number): Vector3
	return Vector3.new(
		state.ax[i] + (state.bx[i] - state.ax[i]) * t,
		state.ay[i] + (state.by[i] - state.ay[i]) * t,
		state.az[i] + (state.bz[i] - state.az[i]) * t
	)
end

-- Searches `cells` ring by ring outward from the cell holding (px, pz). `measure` returns the squared distance to
-- an item (or math.huge to skip it). Stops once the best found is no farther than the nearest unsearched ring:
-- every point of a cell in ring r + 1 is at least r cells away. Returns the best item and its squared distance.
local function ringSearch(
	state: State,
	cells: { [number]: { number } },
	px: number,
	pz: number,
	measure: (index: number) -> number
): (number?, number)
	local columns, rows = state.columns, state.rows
	local column, row = columnOf(state, px), rowOf(state, pz)
	-- Past this ring every cell lies outside the grid.
	local lastRing = math.max(column, columns - 1 - column, row, rows - 1 - row, 0)
	local best: number? = nil
	local bestSquared = math.huge
	for ring = 0, lastRing do
		for r = math.max(row - ring, 0), math.min(row + ring, rows - 1) do
			-- Full rows at the top and bottom of the ring; only its two side cells in between.
			local fullRow = r == row - ring or r == row + ring
			local step = if fullRow then 1 else 2 * ring
			local c = column - ring
			while c <= column + ring do
				if c >= 0 and c < columns then
					local list = cells[cellKey(state, c, r)]
					if list then
						for _, index in list do
							local squared = measure(index)
							if squared < bestSquared then
								best, bestSquared = index, squared
							end
						end
					end
				end
				c += step
			end
		end
		local reach = ring * state.cellSize
		if bestSquared <= reach * reach then
			break
		end
	end
	return best, bestSquared
end

-- Calls `visit` once for every edge listed in a cell within `radius` of (px, pz) (a superset of the edges whose
-- centre line comes that close). Stops early when `visit` returns true, and returns whether it did.
local function anyEdgeNear(
	state: State,
	px: number,
	pz: number,
	radius: number,
	visit: (index: number) -> boolean
): boolean
	state.query += 1
	local query = state.query
	local firstColumn = math.max(columnOf(state, px - radius), 0)
	local lastColumn = math.min(columnOf(state, px + radius), state.columns - 1)
	for row = math.max(rowOf(state, pz - radius), 0), math.min(rowOf(state, pz + radius), state.rows - 1) do
		for column = firstColumn, lastColumn do
			local list = state.edgeCells[cellKey(state, column, row)]
			if list then
				for _, index in list do
					if state.edgeSeen[index] ~= query then
						state.edgeSeen[index] = query
						if visit(index) then
							return true
						end
					end
				end
			end
		end
	end
	return false
end

local fromData: (nodes: { Node }, edges: { Edge }) -> Api

local function makeApi(state: State): Api
	local api: Api

	local function edgeNumber(list: { number }, edgeIndex: number, what: string): number
		local value = list[edgeIndex]
		if value == nil then
			error(`Graph.{what}: there is no edge {edgeIndex}`, 3)
		end
		return value
	end

	local function nearestEdge(position: Vector3): (number?, number, number, Vector3)
		local px, pz = position.X, position.Z
		state.query += 1
		local query = state.query
		local best, bestSquared = ringSearch(state, state.edgeCells, px, pz, function(index)
			-- An edge spans several cells: measure it once per query.
			if state.edgeSeen[index] == query then
				return math.huge
			end
			state.edgeSeen[index] = query
			local _, squared = closestOnEdge(state, index, px, pz)
			return squared
		end)
		if best == nil then
			return nil, 0, math.huge, position
		end
		local t = closestOnEdge(state, best, px, pz)
		return best, t, math.sqrt(bestSquared), pointOn(state, best, t)
	end

	api = {
		fromData = function(nodes: { Node }, edges: { Edge }): Api
			return fromData(nodes, edges)
		end,

		node = function(id: string): Node?
			return state.nodeById[id]
		end,

		nodes = function(): { Node }
			return state.nodeList
		end,

		edges = function(): { Edge }
			return state.edgeList
		end,

		neighbors = function(id: string): { Neighbor }
			return state.neighborsById[id] or EMPTY
		end,

		edgeWidth = function(edgeIndex: number): number
			return edgeNumber(state.width, edgeIndex, "edgeWidth")
		end,

		edgeLength = function(edgeIndex: number): number
			return edgeNumber(state.length, edgeIndex, "edgeLength")
		end,

		pointOnEdge = function(edgeIndex: number, t: number): Vector3
			edgeNumber(state.length, edgeIndex, "pointOnEdge")
			return pointOn(state, edgeIndex, math.clamp(t, 0, 1))
		end,

		nearestNode = function(position: Vector3): (string?, number)
			local px, pz = position.X, position.Z
			local best, bestSquared = ringSearch(state, state.nodeCells, px, pz, function(index)
				local p = state.nodeList[index].position
				local dx, dz = p.X - px, p.Z - pz
				return dx * dx + dz * dz
			end)
			if best == nil then
				return nil, math.huge
			end
			return state.nodeList[best].id, math.sqrt(bestSquared)
		end,

		nearestEdge = nearestEdge,

		isOnRoad = function(position: Vector3, margin: number?): boolean
			local extra = margin or 0
			local px, py, pz = position.X, position.Y, position.Z
			return anyEdgeNear(state, px, pz, state.maxHalfWidth + extra, function(index)
				local t, squared = closestOnEdge(state, index, px, pz)
				local reach = state.halfWidth[index] + extra
				if reach < 0 or squared > reach * reach then
					return false
				end
				local surface = state.ay[index] + (state.by[index] - state.ay[index]) * t
				return py >= surface - RoadGraph.onRoadBelow and py <= surface + RoadGraph.onRoadAbove
			end)
		end,

		zoneAt = function(position: Vector3): string?
			local px, pz = position.X, position.Z
			local margin = RoadGraph.loopZoneMargin
			if LOOP_ZONE then
				local onLoop = anyEdgeNear(state, px, pz, state.maxLoopHalfWidth + margin, function(index)
					if not state.loopEdge[index] then
						return false
					end
					local _, squared = closestOnEdge(state, index, px, pz)
					local reach = state.halfWidth[index] + margin
					return squared <= reach * reach
				end)
				if onLoop then
					return LOOP_ZONE
				end
			end
			for _, id in MapLayout.zoneOrder do
				local zone = MapLayout.zones[id]
				if id ~= LOOP_ZONE and zone then
					if px >= zone.min.X and px <= zone.max.X and pz >= zone.min.Y and pz <= zone.max.Y then
						return id
					end
				end
			end
			return nil
		end,
	}
	return api
end

fromData = function(nodes: { Node }, edges: { Edge }): Api
	return makeApi(build(nodes, edges))
end

local Graph: Api = fromData(RoadGraph.nodes, RoadGraph.edges)

return Graph
