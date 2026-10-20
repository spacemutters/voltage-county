--!strict
-- The new-player spawn flow, Phase 2 stub (docs/phase-2-contracts.md "SpawnFlowService"; PLAN.md Phase 2).
--
-- Players spawn at the used lot by themselves (MapBuilder puts the SpawnLocations there). This service adds a
-- "Claim your free car" ProximityPrompt to the used lot (the UsedLot-tagged part under
-- Workspace.Map.Generated.Locations), on the edge of the lot nearest the player spawns. Triggering it spawns a
-- temporary used Ohm Spark on the nearest free SpawnPad (VehicleService.spawn), sits the player in the driver
-- seat, and tells them with a Notify toast that it's a test drive until the garage opens. The real claim, the
-- starter car and saving land in Phase 4.
--
-- Server-authoritative: the prompt is only an intent. The server re-checks the distance, applies a per-player
-- cooldown (Config/Gps spawnFlow) and decides where the car goes. No polling: ProximityPrompt.Triggered and
-- Players.PlayerRemoving only (plus a short wait for the map at start).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Catalog = require(ReplicatedStorage.Shared.Vehicle.Catalog)
local Gps = require(ReplicatedStorage.Shared.Config.Gps)
local MapLayout = require(ReplicatedStorage.Shared.Config.MapLayout)
local Net = require(ReplicatedStorage.Shared.Net)
local Spawning = require(ReplicatedStorage.Shared.Config.Spawning)
local VehicleService = require(script.Parent.VehicleService)

local BUILD_HINT = "In Studio's Edit mode, run require(game.ServerScriptService.Server.Dev.MapBuilder).build()"
local DISPLAY_NAME_ATTRIBUTE = "DisplayName" -- set on every location part by MapBuilder
local OWNER_ATTRIBUTE = "OwnerUserId" -- set on every spawned car by VehicleService

-- One used lot with its prompt and its spawn pads, nearest first.
type Lot = {
	part: BasePart,
	prompt: ProximityPrompt,
	pads: { BasePart },
}

local SpawnFlowService = {}

local lastClaim: { [Player]: number } = {} -- os.clock() of each player's last claim

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

local function flatDistance(a: Vector3, b: Vector3): number
	return Vector3.new(a.X - b.X, 0, a.Z - b.Z).Magnitude
end

-- Spawn pads sorted by their distance from the lot, nearest first.
local function padsByDistance(lot: BasePart, pads: { BasePart }): { BasePart }
	local sorted = table.clone(pads)
	table.sort(sorted, function(a: BasePart, b: BasePart): boolean
		return flatDistance(a.Position, lot.Position) < flatDistance(b.Position, lot.Position)
	end)
	return sorted
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

-- Picking a pad ---------------------------------------------------------------------------------------------

-- True when another player's car stands on the pad (the claimer's own car is replaced by the new one).
local function padTaken(pad: BasePart, player: Player): boolean
	local vehicles = Workspace:FindFirstChild(Spawning.vehiclesFolder)
	if vehicles == nil then
		return false
	end
	local radius = Gps.spawnFlow.padClearRadius
	for _, car in vehicles:GetChildren() do
		if
			car:IsA("Model")
			and car:GetAttribute(OWNER_ATTRIBUTE) ~= player.UserId
			and flatDistance(car:GetPivot().Position, pad.Position) <= radius
		then
			return true
		end
	end
	return false
end

-- The nearest free pad to the lot, or the nearest pad when every one is taken; nil with no pads.
local function choosePad(lot: Lot, player: Player): BasePart?
	for _, pad in lot.pads do
		if not padTaken(pad, player) then
			return pad
		end
	end
	return lot.pads[1]
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

	local pad = choosePad(lot, player)
	-- No pads on the map: VehicleService puts the car just in front of the player instead.
	local model = VehicleService.spawn(player, flow.vehicleId, flow.trimId, if pad then pad.CFrame else nil)
	if model == nil then
		lastClaim[player] = nil -- nothing was handed out, so they may try again straight away
		notify(player, flow.messages.failed, "error")
		return
	end
	if flow.seatDriver then
		VehicleService.seatDriver(player)
	end
	local vehicle = Catalog.getVehicle(flow.vehicleId)
	local name = if vehicle then vehicle.displayName else flow.vehicleId
	notify(player, string.format(flow.messages.claimed, name), "info")
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

-- Boot -----------------------------------------------------------------------------------------------------

function SpawnFlowService:Start()
	local flow = Gps.spawnFlow

	Players.PlayerRemoving:Connect(function(player: Player)
		lastClaim[player] = nil
	end)

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
	local pads = taggedParts(locations, flow.spawnPadTag)
	if #pads == 0 then
		warn(`[SpawnFlowService] No {flow.spawnPadTag} location parts: free cars will appear next to the player`)
	end

	for _, part in lotParts do
		local lot: Lot = {
			part = part,
			prompt = addPrompt(part),
			pads = padsByDistance(part, pads),
		}
		lot.prompt.Triggered:Connect(function(player: Player)
			onClaim(lot, player)
		end)
	end
end

return SpawnFlowService
