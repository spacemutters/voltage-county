--!strict
-- Fastest routes over the road graph (docs/phase-2-contracts.md, "Road modules").
--
-- A* over the graph's nodes. An edge costs its length / its speed limit (seconds at the limit), and the heuristic
-- is the straight-line distance left / the fastest speed limit anywhere on the graph. That never overestimates
-- (no road is straighter than a straight line or faster than the fastest limit), and it is consistent, so the
-- first time the search takes a node off the heap it has the fastest way there and the route found is the fastest.
--
-- Everything the search touches is set up once per graph in flat arrays indexed by node number: positions, the
-- edges out of each node, and each edge's cost. The arrays are reused between searches (each search has a number,
-- and an entry only counts if it was written by the current search), so a search allocates almost nothing. The
-- open set is a binary heap with lazy deletion: a node pushed again with a better cost leaves its old entry in
-- the heap, and entries for nodes already finished are skipped when popped.
--
-- route(from, to) joins the road where it is nearest each end: it starts at the closest point on the edge nearest
-- `from` and may leave that edge by either end (so it never detours to a node behind you), and it ends at the
-- closest point on the edge nearest `to`, reached from either end of that edge. The end is a virtual node in the
-- search. With both ends on the same edge, driving straight along it is one candidate and the search checks for a
-- quicker way round. Points are on the road surface, along the centre line, in driving order.
--
-- route(from, to, heading) also knows which way the car faces: it leaves the start edge only by the end ahead,
-- and never turns straight back down the start edge at that end (no U-turn on a narrow street), so it goes round
-- the block instead. When there is no such way (a dead end ahead), it falls back to the route without a heading.

local Graph = require(script.Parent.Graph)
local Units = require(script.Parent.Parent.Util.Units)

export type Route = {
	points: { Vector3 }, -- on the road surface, from the start to the end
	length: number, -- studs along the points
	nodes: { string }, -- the graph nodes passed, in order (empty when both ends are on one edge)
}

export type Router = {
	findPath: (fromNode: string, toNode: string) -> { string }?,
	route: (from: Vector3, to: Vector3, heading: Vector3?) -> Route?,
}

-- Consecutive route points closer than this are the same point (a route that starts or ends on a node).
local SAME_POINT = 1e-3
-- A heading counts as along the start road when the angle between them is under 60 degrees (cosine above this).
local ALONG_ROAD = 0.5

local function routeFrom(points: { Vector3 }, nodes: { string }): Route
	local length = 0
	for i = 2, #points do
		length += (points[i] - points[i - 1]).Magnitude
	end
	return { points = points, length = length, nodes = nodes }
end

local function forGraph(graph: Graph.Api): Router
	local nodeList = graph.nodes()
	local edgeList = graph.edges()
	local count = #nodeList
	local goal = count + 1 -- route()'s end point, a virtual node

	local indexOf: { [string]: number } = {}
	local ids: { string } = table.create(count)
	local positions: { Vector3 } = table.create(count)
	for i, node in nodeList do
		indexOf[node.id] = i
		ids[i] = node.id
		positions[i] = node.position
	end

	-- Seconds to drive each edge at its limit, and the fastest limit anywhere (for the heuristic).
	local edgeCost: { number } = table.create(#edgeList)
	local fastest = 0
	for e, edge in edgeList do
		local speed = Units.mphToStuds(edge.speedLimitMph)
		edgeCost[e] = graph.edgeLength(e) / speed
		fastest = math.max(fastest, speed)
	end
	local secondsPerStud = if fastest > 0 then 1 / fastest else 0

	-- Edges out of node i: entries firstLink[i] .. firstLink[i + 1] - 1 of linkTo / linkEdge.
	local firstLink: { number } = table.create(count + 1)
	local linkTo: { number } = {}
	local linkEdge: { number } = {}
	for i = 1, count do
		firstLink[i] = #linkTo + 1
		for _, neighbor in graph.neighbors(ids[i]) do
			table.insert(linkTo, indexOf[neighbor.node])
			table.insert(linkEdge, neighbor.edge)
		end
	end
	firstLink[count + 1] = #linkTo + 1

	-- Search state, per node (goal included). An entry counts only when its stamp equals the current search.
	local cost: { number } = table.create(goal, 0) -- best seconds from the start found so far
	local cameFrom: { number } = table.create(goal, 0) -- the node before it on that best way (0 = a start)
	local costStamp: { number } = table.create(goal, 0)
	local doneStamp: { number } = table.create(goal, 0) -- finished: its cost is final
	local search = 0

	-- The goal's links for route(): reaching node goalNodeA (or B) means the end is goalCostA (or B) seconds on.
	local goalNodeA, goalNodeB = 0, 0
	local goalCostA, goalCostB = 0, 0
	-- Where the search heads (for the heuristic).
	local targetX, targetY, targetZ = 0, 0, 0
	-- With a heading: the start edge's end ahead of the car, and the start edge, which the search may not take
	-- straight back from that node (0 = no such rule this search). `noGoalLink` also stops it reaching an end on
	-- the start edge from that node (that would be the same U-turn).
	local aheadNode, startEdgeIndex = 0, 0
	local noGoalLink = false

	-- Binary min-heap of (key = cost + heuristic, node).
	local heapKey: { number } = {}
	local heapNode: { number } = {}
	local heapSize = 0

	local function push(key: number, node: number)
		heapSize += 1
		local i = heapSize
		while i > 1 do
			local parent = i // 2
			if heapKey[parent] <= key then
				break
			end
			heapKey[i], heapNode[i] = heapKey[parent], heapNode[parent]
			i = parent
		end
		heapKey[i], heapNode[i] = key, node
	end

	local function pop(): number
		local top = heapNode[1]
		local key, node = heapKey[heapSize], heapNode[heapSize]
		heapSize -= 1
		local i = 1
		while true do
			local child = 2 * i
			if child > heapSize then
				break
			end
			if child < heapSize and heapKey[child + 1] < heapKey[child] then
				child += 1
			end
			if key <= heapKey[child] then
				break
			end
			heapKey[i], heapNode[i] = heapKey[child], heapNode[child]
			i = child
		end
		if heapSize > 0 then
			heapKey[i], heapNode[i] = key, node
		end
		return top
	end

	local function heuristic(node: number): number
		if node == goal then
			return 0
		end
		local p = positions[node]
		local dx, dy, dz = p.X - targetX, p.Y - targetY, p.Z - targetZ
		return math.sqrt(dx * dx + dy * dy + dz * dz) * secondsPerStud
	end

	-- Offers `node` a way costing `seconds`, arriving from `from` (0 = a start).
	local function relax(node: number, seconds: number, from: number)
		if doneStamp[node] == search then
			return
		end
		if costStamp[node] == search and cost[node] <= seconds then
			return
		end
		costStamp[node] = search
		cost[node] = seconds
		cameFrom[node] = from
		push(seconds + heuristic(node), node)
	end

	local function begin(x: number, y: number, z: number)
		search += 1
		heapSize = 0
		goalNodeA, goalNodeB = 0, 0
		targetX, targetY, targetZ = x, y, z
		aheadNode, startEdgeIndex = 0, 0
		noGoalLink = false
	end

	-- Runs the search until `target` is finished. Returns whether it was reached.
	local function run(target: number): boolean
		while heapSize > 0 do
			local node = pop()
			if doneStamp[node] ~= search then
				doneStamp[node] = search
				if node == target then
					return true
				end
				if node ~= goal then
					local here = cost[node]
					-- Reached straight from the start at the end ahead: no turning back down the start edge.
					local noBack = node == aheadNode and cameFrom[node] == 0
					for link = firstLink[node], firstLink[node + 1] - 1 do
						if not (noBack and linkEdge[link] == startEdgeIndex) then
							relax(linkTo[link], here + edgeCost[linkEdge[link]], node)
						end
					end
					if not (noBack and noGoalLink) then
						if node == goalNodeA then
							relax(goal, here + goalCostA, node)
						elseif node == goalNodeB then
							relax(goal, here + goalCostB, node)
						end
					end
				end
			end
		end
		return false
	end

	-- The nodes of the way the search found to `last`, first to last.
	local function wayTo(last: number): { string }
		local reversed: { string } = {}
		local node = last
		while node ~= 0 do
			table.insert(reversed, ids[node])
			node = cameFrom[node]
		end
		local way: { string } = table.create(#reversed)
		for i = #reversed, 1, -1 do
			table.insert(way, reversed[i])
		end
		return way
	end

	local function findPath(fromNode: string, toNode: string): { string }?
		local from, to = indexOf[fromNode], indexOf[toNode]
		if from == nil or to == nil then
			return nil
		end
		if from == to then
			return { fromNode }
		end
		local p = positions[to]
		begin(p.X, p.Y, p.Z)
		relax(from, 0, 0)
		if not run(to) then
			return nil
		end
		return wayTo(to)
	end

	local function route(from: Vector3, to: Vector3, heading: Vector3?): Route?
		local startEdge, startT, _, startPoint = graph.nearestEdge(from)
		local endEdge, endT, _, endPoint = graph.nearestEdge(to)
		if startEdge == nil or endEdge == nil then
			return nil
		end

		local first, last = edgeList[startEdge], edgeList[endEdge]
		local fromNode, toNode = indexOf[first.from], indexOf[first.to]
		-- Which end of the start edge is ahead (nil: no heading, or the car faces across the road, as it does
		-- pulling out of a pad, and may turn either way).
		local aheadIsTo: boolean? = nil
		if heading then
			local along = positions[toNode] - positions[fromNode]
			local lengths =
				math.sqrt((along.X * along.X + along.Z * along.Z) * (heading.X * heading.X + heading.Z * heading.Z))
			local facing = if lengths > 0 then (along.X * heading.X + along.Z * heading.Z) / lengths else 0
			if facing > ALONG_ROAD then
				aheadIsTo = true
			elseif facing < -ALONG_ROAD then
				aheadIsTo = false
			end
		end

		begin(endPoint.X, endPoint.Y, endPoint.Z)
		-- Leave the start edge by either end (or only the one ahead), paying for the part of it driven.
		if aheadIsTo ~= true then
			relax(fromNode, startT * edgeCost[startEdge], 0)
		end
		if aheadIsTo ~= false then
			relax(toNode, (1 - startT) * edgeCost[startEdge], 0)
		end
		if aheadIsTo ~= nil then
			aheadNode = if aheadIsTo then toNode else fromNode
			startEdgeIndex = startEdge
			noGoalLink = startEdge == endEdge
		end
		-- Reach the end from either end of its edge.
		goalNodeA, goalCostA = indexOf[last.from], endT * edgeCost[endEdge]
		goalNodeB, goalCostB = indexOf[last.to], (1 - endT) * edgeCost[endEdge]
		-- Both ends on one edge: driving straight along it is one way to the end (cameFrom 0), if the end is ahead.
		-- The search still looks for a quicker one, off the edge and back on at its other end (round a slow street
		-- by a fast road).
		if startEdge == endEdge then
			local ahead = aheadIsTo == nil or (aheadIsTo and endT >= startT) or (not aheadIsTo and endT <= startT)
			if ahead then
				relax(goal, math.abs(endT - startT) * edgeCost[startEdge], 0)
			end
		end
		if not run(goal) then
			if aheadIsTo ~= nil then
				return route(from, to) -- no way on from the end ahead (a dead end): turn round after all
			end
			return nil
		end
		if cameFrom[goal] == 0 then
			return routeFrom({ startPoint, endPoint }, {})
		end

		local nodes = wayTo(cameFrom[goal])
		local points: { Vector3 } = { startPoint }
		for _, id in nodes do
			local p = positions[indexOf[id]]
			if (p - points[#points]).Magnitude > SAME_POINT then
				table.insert(points, p)
			end
		end
		if (endPoint - points[#points]).Magnitude > SAME_POINT or #points == 1 then
			table.insert(points, endPoint)
		end
		return routeFrom(points, nodes)
	end

	return { findPath = findPath, route = route }
end

local county = forGraph(Graph)

local Pathfind = {
	-- A router over another graph (Graph.fromData), for specs and tools.
	forGraph = forGraph,
	-- The node ids of the fastest way from one node to another (both included), or nil if there is none.
	findPath = county.findPath,
	-- The fastest route between two points, joining the road nearest each, or nil if there is none. With a
	-- heading (the car's LookVector), it starts forward: no U-turn on the start edge unless that is a dead end.
	route = county.route,
}

return Pathfind
