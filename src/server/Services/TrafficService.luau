--!strict
-- Ambient pods on the server (PLAN.md Phase 9; docs/phase-9-contracts.md "Ambient pods = ambient traffic").
--
-- Publishes routes, never physics. Each of Config/Traffic pods.count pods drives one route after another: the
-- fastest road-graph path (Road/Pathfind) from where its last route ended to a random destination node, picked
-- with this server's seeded Random so the path's length falls in route.minLength..maxLength (and preferably doesn't
-- start straight back the way the pod came), with a start time on workspace:GetServerTimeNow() and a random speed
-- scale. Road/TrafficPath turns a route into its lane line and speed profile, here (to know when it ends) and on
-- every client (to draw the pod, Controllers/TrafficController), from the same numbers.
--
-- Net TrafficRoutes carries TrafficPath.encode buffers: every pod's routes to each player as they join, and each
-- new route to everyone route.sendAhead seconds before the pod's current route ends. A new route starts exactly
-- when and where the last one ended (its record names the node the pod came from, so its lane line starts where
-- the last one stopped). One task.delay per pod schedules that; there is no per-frame loop on the server, and pods
-- are never server instances.
--
-- The pod model (interface 4 of the Phase 9 build): at Start the Ohm Pod greybox
-- (ServerStorage.<Config/Spawning modelsFolder>.<Catalog.modelName>) is cloned to
-- ReplicatedStorage.<Config/Traffic models.folderName>.<models.modelName> for clients to copy: scripts, seats,
-- prompts and physics constraints removed; every part anchored and out of collisions, queries and touches; tags
-- and attributes cleared (it carries only models.podAttribute) so no car system takes it for a car. Welds and the
-- wheel Motors stay, so a client can move a copy by its Chassis and spin its wheels. Without the greybox (the
-- builder hasn't run in this place) it warns once and clients draw plain boxes.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local Catalog = require(Shared.Vehicle.Catalog)
local Graph = require(Shared.Road.Graph)
local Net = require(Shared.Net)
local Pathfind = require(Shared.Road.Pathfind)
local RoadGraph = require(Shared.Config.RoadGraph)
local Spawning = require(Shared.Config.Spawning)
local Traffic = require(Shared.Config.Traffic)
local TrafficPath = require(Shared.Road.TrafficPath)

local LOG = "[TrafficService]"
local SEATS_FOLDER = "Seats" -- vehicle model contract
local REMOTE = "TrafficRoutes"
local MAX_RECORDS = 255 -- per TrafficPath.encode buffer
local SEQ_WRAP = 2 ^ 32 -- route numbers travel as u32
local MAX_SEED = 2 ^ 31 - 1

type Route = {
	record: TrafficPath.Record,
	endAt: number, -- server time the pod comes to rest at its end
}

type Pod = {
	index: number,
	seq: number, -- the last route number used
	routes: { Route }, -- in start order: the one being driven, then the next once it is published
	thread: thread?, -- the task.delay that publishes its next route
}

local TrafficService = {}

local nodeList = Graph.nodes()
local edgeList = Graph.edges()
local candidates: { number } = {} -- node indices a pod may head for
local pods: { Pod } = {}
local rng = Random.new()

-- Helpers ----------------------------------------------------------------------------------------------------------

local function flatDistance(a: Vector3, b: Vector3): number
	local dx, dz = a.X - b.X, a.Z - b.Z
	return math.sqrt(dx * dx + dz * dz)
end

local function now(): number
	return Workspace:GetServerTimeNow()
end

-- Studs along a path of node ids (every edge is straight).
local function lengthOf(ids: { string }): number
	local total = 0
	for i = 2, #ids do
		local a, b = Graph.node(ids[i - 1]), Graph.node(ids[i])
		if a and b then
			total += (b.position - a.position).Magnitude
		end
	end
	return total
end

local indexOf: { [string]: number } = {}
for index, node in nodeList do
	indexOf[node.id] = index
end

local function toIndices(ids: { string }): { number }
	local indices: { number } = table.create(#ids)
	for i, id in ids do
		indices[i] = indexOf[id]
	end
	return indices
end

-- Destinations: nodes where at least route.minRoads roads meet, none of a kind pods avoid.
local function findCandidates(): { number }
	local avoid: { [RoadGraph.Kind]: boolean } = {}
	for _, kind in Traffic.route.avoidKinds do
		avoid[kind] = true
	end
	local found: { number } = {}
	for index, node in nodeList do
		local neighbors = Graph.neighbors(node.id)
		local fit = #neighbors >= Traffic.route.minRoads
		for _, neighbor in neighbors do
			if avoid[edgeList[neighbor.edge].kind] then
				fit = false
			end
		end
		if fit then
			table.insert(found, index)
		end
	end
	if #found == 0 then
		-- A map with no fitting node still gets traffic: any node with a road will do.
		for index, node in nodeList do
			if #Graph.neighbors(node.id) > 0 then
				table.insert(found, index)
			end
		end
	end
	return found
end

-- Picking routes ---------------------------------------------------------------------------------------------------

-- The nodes of a route from node `from`, having come from node `lead` (or none): the first of route.tries random
-- destinations whose fastest path is in the length band and doesn't start back toward `lead`, else the closest miss.
-- With no path at all, one road out of `from`. nil only for a node with no road.
local function chooseRoute(from: number, lead: number?): { number }?
	local route = Traffic.route
	local origin = nodeList[from]
	local leadId = if lead and lead ~= 0 then nodeList[lead].id else nil
	local best: { string }? = nil
	local bestMiss = math.huge
	for _ = 1, route.tries do
		local target = candidates[rng:NextInteger(1, #candidates)]
		local node = nodeList[target]
		-- A path is never shorter than the straight line: skip the search for one that can't fit.
		if target ~= from and flatDistance(origin.position, node.position) <= route.maxLength then
			local ids = Pathfind.findPath(origin.id, node.id)
			if ids and #ids >= 2 then
				local length = lengthOf(ids)
				local miss = math.max(route.minLength - length, length - route.maxLength, 0)
				local turnsBack = leadId ~= nil and ids[2] == leadId
				if miss == 0 and not turnsBack then
					return toIndices(ids)
				end
				if turnsBack then
					miss += route.uTurnPenalty
				end
				if miss < bestMiss then
					best, bestMiss = ids, miss
				end
			end
		end
	end
	if best == nil then
		for _, neighbor in Graph.neighbors(origin.id) do
			if best == nil or neighbor.node ~= leadId then
				best = { origin.id, neighbor.node }
			end
		end
	end
	return if best then toIndices(best) else nil
end

-- A start node for a new pod: route.tries random destinations, the first at least pods.spacing from every pod
-- placed so far, else the one with the most room.
local function pickStart(taken: { Vector3 }): number
	local bestIndex, bestRoom = candidates[1], -1
	for _ = 1, Traffic.route.tries do
		local index = candidates[rng:NextInteger(1, #candidates)]
		local room = math.huge
		for _, position in taken do
			room = math.min(room, flatDistance(position, nodeList[index].position))
		end
		if room >= Traffic.pods.spacing then
			return index
		end
		if room > bestRoom then
			bestIndex, bestRoom = index, room
		end
	end
	return bestIndex
end

-- A new route for `pod` from node `from` (arriving from `lead`), starting at server time `startAt`.
local function newRoute(pod: Pod, from: number, lead: number?, startAt: number): Route?
	local nodes = chooseRoute(from, lead)
	if nodes == nil then
		return nil
	end
	local scale = TrafficPath.quantizeScale(rng:NextNumber(Traffic.speed.scaleMin, Traffic.speed.scaleMax))
	local plan = TrafficPath.plan(Graph, nodes, scale, lead)
	if plan == nil then
		return nil
	end
	pod.seq = (pod.seq + 1) % SEQ_WRAP
	return {
		record = {
			pod = pod.index,
			seq = pod.seq,
			startAt = startAt,
			scale = scale,
			lead = lead or 0,
			nodes = nodes,
		},
		endAt = startAt + plan.duration,
	}
end

-- Publishing -------------------------------------------------------------------------------------------------------

-- Sends records in buffers of at most MAX_RECORDS, to one player or (player nil) to everyone.
local function send(records: { TrafficPath.Record }, player: Player?)
	for first = 1, #records, MAX_RECORDS do
		local chunk = table.move(records, first, math.min(first + MAX_RECORDS - 1, #records), 1, {})
		local data = TrafficPath.encode(chunk)
		if player then
			Net.fireClient(REMOTE, player, data)
		else
			Net.fireAllClients(REMOTE, data)
		end
	end
end

-- Every pod's routes that haven't ended (and each pod's newest, whatever the time), for a player joining.
local function sendAll(player: Player)
	local records: { TrafficPath.Record } = {}
	local time = now()
	for _, pod in pods do
		for i, route in pod.routes do
			if route.endAt > time or i == #pod.routes then
				table.insert(records, route.record)
			end
		end
	end
	if #records > 0 then
		send(records, player)
	end
end

local extend: (pod: Pod) -> ()

-- Wakes `pod` route.sendAhead seconds before its newest route ends, to publish the one after it.
local function schedule(pod: Pod)
	local newest = pod.routes[#pod.routes]
	local seconds = math.max(newest.endAt - Traffic.route.sendAhead - now(), 0)
	pod.thread = task.delay(seconds, extend, pod)
end

-- Picks, keeps and publishes a pod's next route: from where its newest one ends, starting when it ends.
extend = function(pod: Pod)
	pod.thread = nil
	local newest = pod.routes[#pod.routes]
	local nodes = newest.record.nodes
	local route = newRoute(pod, nodes[#nodes], nodes[#nodes - 1], newest.endAt)
	if route == nil then
		warn(`{LOG} no route out of {nodeList[nodes[#nodes]].id} for pod {pod.index}; trying again`)
		pod.thread = task.delay(Traffic.route.retrySeconds, extend, pod)
		return
	end
	local time = now()
	while #pod.routes > 0 and pod.routes[1].endAt < time do
		table.remove(pod.routes, 1)
	end
	table.insert(pod.routes, route)
	send({ route.record })
	schedule(pod)
end

-- A pod's first route, from `from`, starting now. Tries again later if there is none (and says so).
local function begin(pod: Pod, from: number)
	local route = newRoute(pod, from, nil, now())
	if route == nil then
		warn(`{LOG} no route out of {nodeList[from].id} for pod {pod.index}; trying again`)
		pod.thread = task.delay(Traffic.route.retrySeconds, begin, pod, candidates[rng:NextInteger(1, #candidates)])
		return
	end
	table.insert(pod.routes, route)
	send({ route.record })
	schedule(pod)
end

-- The pod model ----------------------------------------------------------------------------------------------------

local function clearTags(instance: Instance)
	for _, tag in instance:GetTags() do
		instance:RemoveTag(tag)
	end
end

-- Copies the Ohm Pod greybox to ReplicatedStorage for clients (see the header). Returns whether it did.
local function publishModel(): boolean
	local models = Traffic.models
	local sourceName = Catalog.modelName(models.vehicleId, models.trimId)
	local folder = ServerStorage:FindFirstChild(Spawning.modelsFolder)
	local source = if folder then folder:FindFirstChild(sourceName) else nil
	if source == nil or not source:IsA("Model") then
		warn(`{LOG} ServerStorage.{Spawning.modelsFolder}.{sourceName} is missing; pods will be plain boxes`)
		return false
	end

	local model = source:Clone()
	local doomed: { Instance } = {}
	local dropNames: { [string]: boolean } = {}
	for _, name in models.dropParts do
		dropNames[name] = true
	end
	for _, descendant in model:GetDescendants() do
		if
			(descendant:IsA("BasePart") and dropNames[descendant.Name])
			or (models.dropLights and descendant:IsA("Light"))
			or descendant:IsA("LuaSourceContainer")
			or descendant:IsA("Seat")
			or descendant:IsA("VehicleSeat")
			or descendant:IsA("ProximityPrompt")
			or descendant:IsA("ClickDetector")
			or descendant:IsA("Constraint")
			or (descendant:IsA("Folder") and descendant.Name == SEATS_FOLDER)
		then
			table.insert(doomed, descendant)
		end
	end
	for _, instance in doomed do
		instance:Destroy()
	end
	for _, descendant in model:GetDescendants() do
		clearTags(descendant)
		if descendant:IsA("BasePart") then
			descendant.Anchored = true
			descendant.CanCollide = false
			descendant.CanQuery = false
			descendant.CanTouch = false
		end
	end
	clearTags(model)
	for name in model:GetAttributes() do
		model:SetAttribute(name, nil)
	end
	model:SetAttribute(models.podAttribute, true)
	model.Name = models.modelName

	local holder: Instance
	local existing = ReplicatedStorage:FindFirstChild(models.folderName)
	if existing then
		holder = existing
	else
		local made = Instance.new("Folder")
		made.Name = models.folderName
		made.Parent = ReplicatedStorage
		holder = made
	end
	local old = holder:FindFirstChild(models.modelName)
	if old then
		old:Destroy()
	end
	model.Parent = holder
	return true
end

-- Lifecycle --------------------------------------------------------------------------------------------------------

function TrafficService:Init()
	assert(Traffic.pods.count >= 0 and Traffic.pods.count <= 255, `{LOG} pods.count must be 0..255`)
	candidates = findCandidates()
	local seed = Traffic.pods.seed
	if seed == 0 then
		seed = Random.new():NextInteger(1, MAX_SEED)
	end
	rng = Random.new(seed)
	if RunService:IsStudio() then
		print(`{LOG} {Traffic.pods.count} pods, seed {seed}`)
	end
end

function TrafficService:Start()
	publishModel()
	if #candidates == 0 then
		warn(`{LOG} the road graph has no road to drive on; no pods`)
		return
	end

	Players.PlayerAdded:Connect(sendAll)
	local taken: { Vector3 } = {}
	for index = 1, Traffic.pods.count do
		local pod: Pod = { index = index, seq = 0, routes = {}, thread = nil }
		pods[index] = pod
		local from = pickStart(taken)
		table.insert(taken, nodeList[from].position)
		begin(pod, from)
	end
	-- Players already here (a Studio playtest can add the first one before Start) get everything at once.
	for _, player in Players:GetPlayers() do
		sendAll(player)
	end
end

-- Every pod's routes that haven't ended, as published (for Studio tools and specs). Read-only copies.
function TrafficService.records(): { TrafficPath.Record }
	local records: { TrafficPath.Record } = {}
	local time = now()
	for _, pod in pods do
		for i, route in pod.routes do
			if route.endAt > time or i == #pod.routes then
				table.insert(records, table.clone(route.record))
			end
		end
	end
	return records
end

return TrafficService
