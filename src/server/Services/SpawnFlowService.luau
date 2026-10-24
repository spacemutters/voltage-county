--!strict
-- The new-player spawn flow (docs/phase-2-contracts.md "SpawnFlowService"; PLAN.md Phase 2, claim from Phase 4;
-- the first spawn from the roast fixes, 2026-10-24, docs/roast-2026-10-24.md point 8).
--
-- First spawn: a player whose first-session path (PlayerData.goals.path, Services/GoalsService) is still running
-- starts their session in a car, not on foot. On their first character of the session the server claims their free
-- used Ohm Spark for them (UsedLotService.claimStarter: into the garage once, out at the spawn pad nearest them, a
-- toast), or brings out the starter they already own (a rejoin mid-path), then moves the car onto the road near the
-- used lot facing down the street toward downtown (Config/Goals firstSpawn: the first spot with no other car near,
-- in its right-hand lane; with none free it stays on its pad) and seats them in the Driver seat. The path's first
-- card (Controllers/GoalsController) and its fare are waiting, and the Player's Config/Goals firstSpawn.flyover
-- attribute (the server clock) tells Controllers/ArcFlyoverController to fly the Arc over them. Everyone else spawns
-- as before.
--
-- The claim prompt: players spawn at the used lot by themselves (MapBuilder puts the SpawnLocations there). This
-- service adds a "Claim your free car" ProximityPrompt to the used lot (the UsedLot-tagged part under
-- Workspace.Map.Generated.Locations), on the edge of the lot nearest the player spawns, for anyone who hasn't got
-- their car yet. Triggering it calls UsedLotService.claimStarter (docs/phase-4-contracts.md).
--
-- Server-authoritative: the prompt is only an intent. The server re-checks the distance, applies a per-player
-- cooldown (Config/Gps spawnFlow), and UsedLotService decides the rest. No polling: ProximityPrompt.Triggered,
-- Players.PlayerAdded / CharacterAdded and Players.PlayerRemoving only (plus a short wait for the map at start, and
-- for each joining player's data and character). The road pose is a pure helper (viewPose) for tests/Goals.spec.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Goals = require(ReplicatedStorage.Shared.Config.Goals)
local Gps = require(ReplicatedStorage.Shared.Config.Gps)
local Graph = require(ReplicatedStorage.Shared.Road.Graph)
local MapLayout = require(ReplicatedStorage.Shared.Config.MapLayout)
local Net = require(ReplicatedStorage.Shared.Net)
local Spawning = require(ReplicatedStorage.Shared.Config.Spawning)
local Types = require(ReplicatedStorage.Shared.Types)
local World = require(ReplicatedStorage.Shared.Config.World)
local UsedLotService = require(script.Parent.UsedLotService)

-- Required in Init rather than here: DataService loads ProfileStore, which talks to DataStores straight away, and
-- tests/Goals.spec requires this module in Edit mode for viewPose.
type DataServiceModule = typeof(require(script.Parent.DataService))
type GarageServiceModule = typeof(require(script.Parent.GarageService))
type VehicleServiceModule = typeof(require(script.Parent.VehicleService))

local BUILD_HINT = "In Studio's Edit mode, run require(game.ServerScriptService.Server.Dev.MapBuilder).build()"
local DISPLAY_NAME_ATTRIBUTE = "DisplayName" -- set on every location part by MapBuilder
local RESET_REASON = "firstSpawn" -- VehicleService.resetCar's reason (the client shows nothing for it)
local MIN_DIRECTION = 1e-3 -- an edge shorter than this across the ground has no direction

-- One used lot with its prompt.
type Lot = {
	part: BasePart,
	prompt: ProximityPrompt,
}

local SpawnFlowService = {}

local DataService: DataServiceModule? = nil
local GarageService: GarageServiceModule? = nil
local VehicleService: VehicleServiceModule? = nil

local lastClaim: { [Player]: number } = {} -- os.clock() of each player's last claim
local firstSpawnDone: { [Player]: boolean } = {} -- the session's first character has been looked at

local function notify(player: Player, text: string, kind: string)
	Net.fireClient("Notify", player, { text = text, kind = kind })
end

-- Map lookup ------------------------------------------------------------------------------------------------

-- Workspace.Map.Generated.Locations, waiting at most Config mapWaitSeconds in all; nil if it never appears.
local function findLocations(): Instance?
	local deadline = os.clock() + Gps.spawnFlow.mapWaitSeconds
	local node: Instance = Workspace
	for _, name in Gps.spawnFlow.mapPath do
		local remaining = deadline - os.clock()
		local child = if remaining > 0 then node:WaitForChild(name, remaining) else node:FindFirstChild(name)
		if child == nil then
			return nil
		end
		node = child
	end
	return node
end

local function taggedParts(folder: Instance, tag: string): { BasePart }
	local found: { BasePart } = {}
	for _, child in folder:GetChildren() do
		if child:IsA("BasePart") and child:HasTag(tag) then
			table.insert(found, child)
		end
	end
	return found
end

-- Where the prompt goes, in the lot's own space: the point of the lot's footprint nearest the middle of the
-- player spawns (pulled `edgeInset` in from the edge), at prompt height above the lot surface. With no player
-- spawns in MapLayout, the middle of the lot.
local function promptOffset(lot: BasePart): Vector3
	local prompt = Gps.spawnFlow.prompt
	local spawns = MapLayout.playerSpawns
	if #spawns == 0 then
		return Vector3.new(0, prompt.height - lot.Size.Y / 2, 0)
	end
	local sum = Vector3.zero
	for _, spawnFrame in spawns do
		sum += spawnFrame.Position
	end
	local target = lot.CFrame:PointToObjectSpace(sum / #spawns)
	local halfX = math.max(lot.Size.X / 2 - prompt.edgeInset, 0)
	local halfZ = math.max(lot.Size.Z / 2 - prompt.edgeInset, 0)
	-- The location part's bottom face sits on the driving surface (Config/MapLayout), so the surface is at
	-- local Y -Size.Y / 2.
	local y = prompt.height - lot.Size.Y / 2
	return Vector3.new(math.clamp(target.X, -halfX, halfX), y, math.clamp(target.Z, -halfZ, halfZ))
end

-- Claiming --------------------------------------------------------------------------------------------------

local function onClaim(lot: Lot, player: Player)
	local flow = Gps.spawnFlow

	-- The prompt only says the player wants a car: check they are really at the lot.
	local character = player.Character
	local rootPart = if character then character:FindFirstChild("HumanoidRootPart") else nil
	if rootPart == nil or not rootPart:IsA("BasePart") then
		return
	end
	local attachment = lot.prompt.Parent
	local promptAt = if attachment and attachment:IsA("Attachment") then attachment.WorldPosition else lot.part.Position
	if (rootPart.Position - promptAt).Magnitude > lot.prompt.MaxActivationDistance + flow.prompt.reachSlack then
		return
	end

	local now = os.clock()
	local last = lastClaim[player]
	if last ~= nil and now - last < flow.cooldownSeconds then
		local secondsLeft = math.ceil(flow.cooldownSeconds - (now - last))
		notify(player, string.format(flow.messages.cooldown, secondsLeft), "info")
		return
	end
	lastClaim[player] = now

	-- The free starter, once per player: into the garage and out at the nearest spawn pad (Phase 4).
	local result = UsedLotService.claimStarter(player)
	if not result.ok then
		lastClaim[player] = nil -- nothing was handed out, so they may try again straight away
	end
	notify(player, result.message, if result.ok then "success" else "info")
end

local function addPrompt(part: BasePart): ProximityPrompt
	local settings = Gps.spawnFlow.prompt
	local attachment = Instance.new("Attachment")
	attachment.Name = settings.attachmentName
	attachment.Position = promptOffset(part)
	attachment.Parent = part

	local displayName = part:GetAttribute(DISPLAY_NAME_ATTRIBUTE)
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = settings.name
	prompt.ActionText = settings.actionText
	prompt.ObjectText = if type(displayName) == "string" then displayName else settings.objectText
	prompt.HoldDuration = settings.holdSeconds
	prompt.MaxActivationDistance = settings.maxDistance
	prompt.RequiresLineOfSight = false -- the lot's sign and props would otherwise hide it
	prompt.Parent = attachment
	return prompt
end

-- First spawn ----------------------------------------------------------------------------------------------

-- Where a car stands on the road near `near`: on the nearest road's centre line, moved `laneOffset` studs to the
-- right of the way it faces, facing along the road in whichever direction points more toward `lookToward`. nil when
-- no road is within `maxSnap` studs (or the road there has no direction).
function SpawnFlowService.viewPose(
	graph: Graph.Api,
	near: Vector3,
	lookToward: Vector3,
	laneOffset: number,
	maxSnap: number
): CFrame?
	local edgeIndex, _, distance, road = graph.nearestEdge(near)
	if edgeIndex == nil or distance > maxSnap then
		return nil
	end
	local a, b = graph.pointOnEdge(edgeIndex, 0), graph.pointOnEdge(edgeIndex, 1)
	local along = Vector3.new(b.X - a.X, 0, b.Z - a.Z)
	if along.Magnitude < MIN_DIRECTION then
		return nil
	end
	local direction = along.Unit
	local toward = Vector3.new(lookToward.X - road.X, 0, lookToward.Z - road.Z)
	if toward:Dot(direction) < 0 then
		direction = -direction
	end
	local right = direction:Cross(Vector3.yAxis) -- facing north (-Z), the right is east (+X)
	local position = road + right * laneOffset
	return CFrame.lookAt(position, position + direction)
end

-- True when a car other than `except` stands within `radius` studs (across the ground) of `position`.
local function carNear(position: Vector3, radius: number, except: Model?): boolean
	for _, instance in CollectionService:GetTagged(Spawning.vehicleTag) do
		if instance ~= except and instance:IsA("Model") then
			local pivot = instance:GetPivot().Position
			if Vector2.new(pivot.X - position.X, pivot.Z - position.Z).Magnitude < radius then
				return true
			end
		end
	end
	return false
end

-- The first Config/Goals firstSpawn spot on a road with no other car near it, or nil.
local function freeViewSpot(car: Model): CFrame?
	local settings = Goals.firstSpawn
	for _, near in settings.spots do
		local pose = SpawnFlowService.viewPose(
			Graph,
			near,
			settings.lookToward,
			settings.laneOffset * World.laneWidth,
			settings.maxSnap
		)
		if pose ~= nil and not carNear(pose.Position, settings.clearRadius, car) then
			return pose
		end
	end
	return nil
end

-- True while the player's first-session path runs (a save whose goals can't be read counts as done).
local function onPath(data: Types.PlayerData): boolean
	local goals: any = (data :: any).goals
	return type(goals) == "table" and type(goals.path) == "table" and goals.path.done == false
end

-- The uid of the free starter the player owns, or nil.
local function starterUid(data: Types.PlayerData): string?
	local garage = GarageService
	if garage == nil or type(data.vehicles) ~= "table" then
		return nil
	end
	for _, vehicle in data.vehicles do
		if type(vehicle) == "table" and type(vehicle.uid) == "string" and garage.isStarter(vehicle) then
			return vehicle.uid
		end
	end
	return nil
end

-- The session's first character of a player on the path: their starter out on the road, them at the wheel. Yields
-- (for their data and their character's parts); gives up quietly when they leave, respawn or already have a car out.
local function firstSpawn(player: Player, character: Model)
	local settings = Goals.firstSpawn
	local dataService, garage, vehicles = DataService, GarageService, VehicleService
	if dataService == nil or garage == nil or vehicles == nil then
		return
	end
	local data = dataService.waitFor(player, settings.waitSeconds)
	if data == nil or not onPath(data) or player.Character ~= character then
		return
	end
	local humanoid = character:WaitForChild("Humanoid", settings.waitSeconds)
	local root = character:WaitForChild("HumanoidRootPart", settings.waitSeconds)
	if humanoid == nil or root == nil or player.Character ~= character or vehicles.getCar(player) ~= nil then
		return
	end

	local spawned = false
	if not data.starterClaimed then
		lastClaim[player] = os.clock() -- the prompt's cooldown starts with this claim
		local result = UsedLotService.claimStarter(player)
		if result.ok then
			notify(player, result.message, "success")
		else
			lastClaim[player] = nil
		end
		spawned = result.ok
	else
		local uid = starterUid(data)
		spawned = uid ~= nil and garage.spawnOwned(player, uid).ok
	end
	local car = vehicles.getCar(player)
	if not spawned or car == nil then
		return
	end
	local pose = freeViewSpot(car)
	if pose ~= nil then
		vehicles.resetCar(car, pose, RESET_REASON)
		-- The car may have moved out from under a seat that took them in the same step: sit them down again.
		vehicles.seatDriverWhenFree(player)
	end
	-- The Arc's fly-over, drawn on their screen only (Controllers/ArcFlyoverController).
	player:SetAttribute(settings.flyover.attribute, Workspace:GetServerTimeNow())
end

local function watchPlayer(player: Player)
	player.CharacterAdded:Connect(function(character: Model)
		if firstSpawnDone[player] then
			return
		end
		firstSpawnDone[player] = true
		firstSpawn(player, character)
	end)
	local character = player.Character
	if character ~= nil and not firstSpawnDone[player] then
		firstSpawnDone[player] = true
		task.spawn(firstSpawn, player, character)
	end
end

-- Boot -----------------------------------------------------------------------------------------------------

function SpawnFlowService:Init()
	DataService = require(script.Parent.DataService)
	GarageService = require(script.Parent.GarageService)
	VehicleService = require(script.Parent.VehicleService)
end

function SpawnFlowService:Start()
	local flow = Gps.spawnFlow

	Players.PlayerRemoving:Connect(function(player: Player)
		lastClaim[player] = nil
		firstSpawnDone[player] = nil
	end)
	-- The first spawn doesn't need the map's location parts, so it starts before looking for them.
	Players.PlayerAdded:Connect(watchPlayer)
	for _, player in Players:GetPlayers() do
		watchPlayer(player)
	end

	-- The map is built in Edit mode and saved with the place, so it is normally there at once.
	local locations = findLocations()
	if locations == nil then
		warn(`[SpawnFlowService] No Workspace.{table.concat(flow.mapPath, ".")}: the map isn't built. {BUILD_HINT}`)
		return
	end
	local lotParts = taggedParts(locations, flow.usedLotTag)
	if #lotParts == 0 then
		warn(`[SpawnFlowService] No {flow.usedLotTag} location part in {locations:GetFullName()}. {BUILD_HINT}`)
		return
	end
	for _, part in lotParts do
		local lot: Lot = {
			part = part,
			prompt = addPrompt(part),
		}
		lot.prompt.Triggered:Connect(function(player: Player)
			onClaim(lot, player)
		end)
	end
end

return SpawnFlowService
