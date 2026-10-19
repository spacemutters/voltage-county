--!strict
-- Spawns, seats, parks and despawns cars on the server (PLAN.md Phase 1; docs/phase-1-contracts.md "Server").
--
-- A car's life:
--   spawn    clone ServerStorage.VehicleModels.<vehicleId>_<trim> into Workspace.Vehicles, set it on the ground
--            and leave it parked (anchored), with a "Drive" prompt on the Driver seat (owner only) and a "Ride"
--            prompt on each passenger seat.
--   drive    the owner sits in the Driver seat: unanchor, hand the physics to the driver's client
--            (SetNetworkOwner), start anti-exploit tracking, cancel the despawn timer.
--   park     the Driver seat empties: judge the car's last move, physics back to the server, set the car on
--            the ground at ride height keeping its heading, anchor, stop tracking, start the despawn timer,
--            and stand the driver beside the door.
--   despawn  after Config/Spawning.despawnAfterMinutes parked, when the owner spawns another car, or leaves.
--
-- Server-authoritative (CLAUDE.md hard rule 1): the driver's client simulates its car, but the server never
-- takes a position from it. AntiExploitService watches where the car really goes and calls resetCar when a
-- move is impossible. No polling: everything here runs on prompts, seat changes and one task.delay per car.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")
local Workspace = game:GetService("Workspace")

local AntiExploit = require(ReplicatedStorage.Shared.Config.AntiExploit)
local Catalog = require(ReplicatedStorage.Shared.Vehicle.Catalog)
local Net = require(ReplicatedStorage.Shared.Net)
local Spawning = require(ReplicatedStorage.Shared.Config.Spawning)
local Units = require(ReplicatedStorage.Shared.Util.Units)
local AntiExploitService = require(script.Parent.AntiExploitService)

local SECONDS_PER_MINUTE = 60
local MIN_FLAT = 1e-3 -- a direction shorter than this across the ground has no usable heading
local SEAT_WELD = "SeatWeld" -- the weld a Seat creates to hold its occupant
local DRIVER_SEAT = "Driver" -- seat names from the vehicle model contract
local PASSENGER_PREFIX = "Passenger"
local DEFAULT_RESET_REASON = "reset"
local BUILD_HINT = "In Studio's Edit mode, run require(game.ServerScriptService.Server.Dev.VehicleBuilder).buildAll()"

type CarRecord = {
	model: Model,
	owner: Player,
	chassis: BasePart,
	topSpeed: number, -- studs/s, for anti-exploit tracking
	driverSeat: Seat?, -- absent on cars nobody drives (the Pod)
	drivePrompt: ProximityPrompt?,
	driving: boolean, -- the owner is in the Driver seat and the car is unanchored
	despawnThread: thread?, -- the pending despawn while parked
	resetSerial: number, -- bumped by every reset, so only the latest one hands ownership back
	connections: { RBXScriptConnection },
	occupants: { [Seat]: Humanoid }, -- who sits in each seat, to stand them beside it when they get out
	occupantDeaths: { [Seat]: RBXScriptConnection }, -- Died watchers for whoever sits in each seat
}

local VehicleService = {}

local records: { [Model]: CarRecord } = {}
local carsByPlayer: { [Player]: { CarRecord } } = {} -- oldest first

-- Helpers ---------------------------------------------------------------------------------------------------

local function vehiclesFolder(): Folder
	local existing = Workspace:FindFirstChild(Spawning.vehiclesFolder)
	if existing ~= nil and existing:IsA("Folder") then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = Spawning.vehiclesFolder
	folder.Parent = Workspace
	return folder
end

local function carsOf(player: Player): { CarRecord }
	local cars = carsByPlayer[player]
	if cars == nil then
		local fresh: { CarRecord } = {}
		carsByPlayer[player] = fresh
		return fresh
	end
	return cars
end

local function newestCar(player: Player): CarRecord?
	local cars = carsByPlayer[player]
	if cars == nil then
		return nil
	end
	return cars[#cars]
end

-- The player's living humanoid and root part, or nil.
local function aliveCharacter(player: Player): (Humanoid?, BasePart?)
	local character = player.Character
	if character == nil then
		return nil, nil
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local root = character:FindFirstChild("HumanoidRootPart")
	if humanoid == nil or humanoid.Health <= 0 or root == nil or not root:IsA("BasePart") then
		return nil, nil
	end
	return humanoid, root
end

local function playerOf(humanoid: Humanoid): Player?
	local character = humanoid.Parent
	if character ~= nil and character:IsA("Model") then
		return Players:GetPlayerFromCharacter(character)
	end
	return nil
end

-- Takes whoever is in the seat out of it.
local function unseat(seat: Seat)
	for _, child in seat:GetChildren() do
		if child.Name == SEAT_WELD and child:IsA("JointInstance") then
			child:Destroy()
		end
	end
end

-- Network ownership only applies to unanchored parts (anchored ones always belong to the server).
local function setOwner(chassis: BasePart, owner: Player?)
	if chassis.Anchored then
		return
	end
	local allowed, why = chassis:CanSetNetworkOwnership()
	if allowed then
		chassis:SetNetworkOwner(owner)
	else
		local who = if owner then owner.Name else "the server"
		warn(`[VehicleService] Can't hand {chassis:GetFullName()} to {who}: {why}`)
	end
end

local function stopMotion(chassis: BasePart)
	chassis.AssemblyLinearVelocity = Vector3.zero
	chassis.AssemblyAngularVelocity = Vector3.zero
end

-- The car's heading across the ground, as a unit vector.
local function headingOf(cframe: CFrame): Vector3
	local look = cframe.LookVector
	local flat = Vector3.new(look.X, 0, look.Z)
	if flat.Magnitude < MIN_FLAT then
		-- Nose straight down (or up): the roof then points along the old heading (or against it).
		local up = if look.Y < 0 then cframe.UpVector else -cframe.UpVector
		flat = Vector3.new(up.X, 0, up.Z)
	end
	if flat.Magnitude < MIN_FLAT then
		return -Vector3.zAxis
	end
	return flat.Unit
end

-- A pose at `position` facing `heading` (projected onto the ground plane) with `up` as its up vector.
local function poseAt(position: Vector3, heading: Vector3, up: Vector3): CFrame
	local forward = (heading - up * heading:Dot(up)).Unit
	local right = forward:Cross(up)
	return CFrame.fromMatrix(position, right, up)
end

-- Ignore the car itself and every character, and only land on solid (CanCollide) ground.
local function groundParams(model: Model): RaycastParams
	local ignore: { Instance } = { model }
	for _, other in Players:GetPlayers() do
		local character = other.Character
		if character ~= nil then
			table.insert(ignore, character)
		end
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = ignore
	params.RespectCanCollide = true
	return params
end

-- Where the car rests on the ground under `near`, keeping its heading. The model pivot is the ground point
-- under the chassis (vehicle model contract), so PivotTo(this) puts the car at ride height.
local function groundPose(model: Model, near: CFrame): CFrame
	local heading = headingOf(near)
	local park = Spawning.park
	local origin = near.Position + Vector3.yAxis * park.probeUp
	local hit = Workspace:Raycast(origin, Vector3.yAxis * -(park.probeUp + park.probeDown), groundParams(model))
	if hit == nil then
		return poseAt(near.Position, heading, Vector3.yAxis) -- no ground below: park level where it is
	end
	local flushEnough = hit.Normal.Y >= math.cos(math.rad(park.maxGroundTiltDegrees))
	return poseAt(hit.Position, heading, if flushEnough then hit.Normal else Vector3.yAxis)
end

-- Just in front of the player's character, facing the way they face.
local function inFrontOf(player: Player, carLength: number): CFrame?
	local _, root = aliveCharacter(player)
	if root == nil then
		return nil
	end
	local heading = headingOf(root.CFrame)
	local position = root.Position + heading * (Spawning.spawnOffset + carLength / 2)
	return CFrame.lookAt(position, position + heading)
end

-- The model for a trim, or nil (with a warning that says how to build it).
local function findTemplate(vehicleId: string, trimId: string): Model?
	local name = Catalog.modelName(vehicleId, trimId)
	local folder = ServerStorage:FindFirstChild(Spawning.modelsFolder)
	local template = if folder then folder:FindFirstChild(name) else nil
	if template == nil or not template:IsA("Model") then
		warn(`[VehicleService] No car model "{name}" in ServerStorage.{Spawning.modelsFolder}. {BUILD_HINT}`)
		return nil
	end
	local chassis = template.PrimaryPart
	if chassis == nil or chassis.Name ~= "Chassis" then
		warn(`[VehicleService] Car model "{name}" has no Chassis PrimaryPart (vehicle model contract). {BUILD_HINT}`)
		return nil
	end
	return template
end

local function cancelDespawnTimer(record: CarRecord)
	local thread = record.despawnThread
	record.despawnThread = nil
	if thread ~= nil and thread ~= coroutine.running() then
		task.cancel(thread)
	end
end

local function despawnRecord(record: CarRecord)
	local model = record.model
	if records[model] ~= record then
		return
	end
	records[model] = nil
	local cars = carsByPlayer[record.owner]
	if cars ~= nil then
		local index = table.find(cars, record)
		if index ~= nil then
			table.remove(cars, index)
		end
	end
	cancelDespawnTimer(record)
	AntiExploitService.untrack(model)
	for _, connection in record.connections do
		connection:Disconnect()
	end
	for _, connection in record.occupantDeaths do
		connection:Disconnect()
	end
	model:Destroy()
end

local function startDespawnTimer(record: CarRecord)
	cancelDespawnTimer(record)
	record.despawnThread = task.delay(Spawning.despawnAfterMinutes * SECONDS_PER_MINUTE, function()
		record.despawnThread = nil
		if not record.driving then
			despawnRecord(record)
		end
	end)
end

-- Records who now sits in `seat` and returns who sat there before. When whoever sits there dies, take them
-- out, so a dead driver frees the car (and parks it).
local function onOccupantChanged(record: CarRecord, seat: Seat): Humanoid?
	local previous = record.occupants[seat]
	local watcher = record.occupantDeaths[seat]
	if watcher then
		watcher:Disconnect()
		record.occupantDeaths[seat] = nil
	end
	local humanoid = seat.Occupant
	record.occupants[seat] = humanoid
	if humanoid ~= nil then
		record.occupantDeaths[seat] = humanoid.Died:Connect(function()
			if seat.Occupant == humanoid then
				unseat(seat)
			end
		end)
	end
	return previous
end

-- Stands a character that just got out of `seat` on the ground beside that seat's door, facing the way the car
-- faces. Seats sit inside the collidable chassis box, so a character left standing in place would be shoved
-- out of it by the physics.
local function standBeside(record: CarRecord, seat: Seat, humanoid: Humanoid)
	if humanoid.Health <= 0 or humanoid.SeatPart ~= nil then
		return -- dead, or already sitting somewhere else
	end
	local character = humanoid.Parent
	local root = if character then character:FindFirstChild("HumanoidRootPart") else nil
	if character == nil or not character:IsA("Model") or root == nil or not root:IsA("BasePart") then
		return
	end
	local exit = Spawning.exit
	local chassis = record.chassis
	local frame = chassis.CFrame
	local seatLocal = frame:PointToObjectSpace(seat.Position)
	local side = if seatLocal.X > 0 then 1 else -1
	local door = frame:PointToWorldSpace(Vector3.new(side * (chassis.Size.X / 2 + exit.sideGap), 0, seatLocal.Z))
	local ground = groundPose(record.model, frame.Rotation + door).Position
	local legs = if humanoid.RigType == Enum.HumanoidRigType.R6 then exit.r6LegHeight else humanoid.HipHeight
	local stand = ground + Vector3.yAxis * (legs + root.Size.Y / 2 + exit.clearance)
	local rootPose = CFrame.lookAt(stand, stand + headingOf(frame))
	character:PivotTo(rootPose * root.CFrame:ToObjectSpace(character:GetPivot()))
end

-- A prompt fired: seat the player if they are alive, close enough and not already sitting somewhere.
local function trySit(seat: Seat, player: Player)
	if seat.Occupant ~= nil then
		return
	end
	local humanoid, root = aliveCharacter(player)
	if humanoid == nil or root == nil or humanoid.SeatPart ~= nil then
		return
	end
	if (root.Position - seat.Position).Magnitude > Spawning.seatReach then
		return
	end
	seat:Sit(humanoid)
end

local function makePrompt(seat: Seat, name: string, actionText: string, objectText: string): ProximityPrompt
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = name
	prompt.ActionText = actionText
	prompt.ObjectText = objectText
	prompt.HoldDuration = Spawning.prompt.holdSeconds
	prompt.MaxActivationDistance = Spawning.prompt.maxDistance
	prompt.RequiresLineOfSight = false -- seats sit inside the car body, which would block the sight check
	prompt.Parent = seat
	return prompt
end

-- Public API: parking and resets ---------------------------------------------------------------------------

-- Parks a car: physics back to the server, set on the ground at ride height keeping its heading, anchored,
-- no longer tracked, and despawned after Config/Spawning.despawnAfterMinutes unless someone drives it.
function VehicleService.park(model: Model)
	local record = records[model]
	if record == nil then
		return
	end
	local seat = record.driverSeat
	if record.driving then
		record.driving = false
		-- Called while someone is still driving (not from the seat emptying): take them out first.
		if seat ~= nil and seat.Occupant ~= nil then
			unseat(seat)
		end
	end
	-- Judge where the driver left the car before trusting it: a move made since the last sample counts too,
	-- and an illegal one parks the car where it last moved legally instead.
	local legal, lastGood = AntiExploitService.checkNow(model)
	AntiExploitService.untrack(model)

	local chassis = record.chassis
	setOwner(chassis, nil) -- ownership can only change while unanchored, so before anchoring
	local near = if not legal and lastGood ~= nil then lastGood else model:GetPivot()
	model:PivotTo(groundPose(model, near))
	stopMotion(chassis)
	chassis.Anchored = true
	startDespawnTimer(record)
end

-- Moves a car back to `cframe` (on the ground below it, keeping its heading) and stops it. Used by
-- anti-exploit; the driver keeps the car and their client is told why it moved. The server keeps the car's
-- physics for Config/AntiExploit.resetOwnershipDelay first, so physics the driver's client sent before the
-- reset can't undo it.
function VehicleService.resetCar(model: Model, cframe: CFrame, reason: string?)
	local record = records[model]
	if record == nil then
		return
	end
	local chassis = record.chassis
	setOwner(chassis, nil) -- move it as the server so the driver's client can't fight the move
	model:PivotTo(groundPose(model, cframe))
	stopMotion(chassis)
	AntiExploitService.allowTeleport(model)
	if record.driving then
		Net.fireClient("VehicleReset", record.owner, { reason = reason or DEFAULT_RESET_REASON })
		record.resetSerial += 1
		local serial = record.resetSerial
		task.delay(AntiExploit.resetOwnershipDelay, function()
			if records[model] == record and record.driving and record.resetSerial == serial then
				setOwner(chassis, record.owner)
			end
		end)
	end
end

-- Seating ----------------------------------------------------------------------------------------------------

local function startDriving(record: CarRecord)
	if record.driving then
		return
	end
	record.driving = true
	cancelDespawnTimer(record)
	local chassis = record.chassis
	chassis.Anchored = false
	setOwner(chassis, record.owner)
	local model = record.model
	AntiExploitService.track(model, record.owner, {
		topSpeed = record.topSpeed,
		reset = function(lastGood: CFrame, reason: string)
			VehicleService.resetCar(model, lastGood, reason)
		end,
	})
end

local function onDriverSeatChanged(record: CarRecord, seat: Seat)
	if records[record.model] ~= record then
		return
	end
	local previous = onOccupantChanged(record, seat)
	local humanoid = seat.Occupant
	local prompt = record.drivePrompt
	if prompt ~= nil then
		prompt.Enabled = humanoid == nil
	end

	if humanoid == nil then
		if record.driving then
			VehicleService.park(record.model)
		end
		if previous ~= nil then
			standBeside(record, seat, previous) -- after parking, so they stand beside where the car ended up
		end
	elseif playerOf(humanoid) ~= record.owner then
		-- Only the owner drives. The prompt already checks this; this catches anything that slipped past it.
		unseat(seat)
	else
		startDriving(record)
	end
end

local function setupSeat(record: CarRecord, seat: Seat, objectText: string)
	seat.CanTouch = false -- walking into a car never sits you down (vehicle model contract)
	if seat.Name == DRIVER_SEAT then
		record.driverSeat = seat
		local prompt = makePrompt(seat, Spawning.prompt.driveName, Spawning.prompt.driveText, objectText)
		record.drivePrompt = prompt
		table.insert(
			record.connections,
			prompt.Triggered:Connect(function(player: Player)
				if player == record.owner then
					trySit(seat, player)
				end
			end)
		)
		table.insert(
			record.connections,
			seat:GetPropertyChangedSignal("Occupant"):Connect(function()
				onDriverSeatChanged(record, seat)
			end)
		)
	elseif string.sub(seat.Name, 1, #PASSENGER_PREFIX) == PASSENGER_PREFIX then
		local prompt = makePrompt(seat, Spawning.prompt.rideName, Spawning.prompt.rideText, objectText)
		table.insert(
			record.connections,
			prompt.Triggered:Connect(function(player: Player)
				trySit(seat, player)
			end)
		)
		table.insert(
			record.connections,
			seat:GetPropertyChangedSignal("Occupant"):Connect(function()
				local previous = onOccupantChanged(record, seat)
				prompt.Enabled = seat.Occupant == nil
				if seat.Occupant == nil and previous ~= nil then
					standBeside(record, seat, previous)
				end
			end)
		)
	end
end

-- Public API: spawning -------------------------------------------------------------------------------------

-- Spawns a parked car for `player` at `at` (on the ground below it), or just in front of their character.
-- Despawns their previous car first (Config/Spawning.maxCarsPerPlayer). Returns nil, with a warning, when the
-- vehicle, its model or a place to put it is missing.
function VehicleService.spawn(player: Player, vehicleId: string, trimId: string, at: CFrame?): Model?
	local trim = Catalog.getTrim(vehicleId, trimId)
	local geometry = Catalog.geometry(vehicleId, trimId)
	if trim == nil or geometry == nil then
		warn(`[VehicleService] No vehicle "{vehicleId}" with trim "{trimId}" in Config/Vehicles`)
		return nil
	end
	if player.Parent == nil then
		return nil -- left the game
	end
	local template = findTemplate(vehicleId, trimId)
	if template == nil then
		return nil
	end
	local spot = at or inFrontOf(player, geometry.length)
	if spot == nil then
		warn(`[VehicleService] Can't spawn a car for {player.Name}: no spot given and no character to spawn next to`)
		return nil
	end

	-- Make room first, so the old car is gone before the ground under the new one is measured.
	local cars = carsOf(player)
	while #cars > 0 and #cars >= Spawning.maxCarsPerPlayer do
		despawnRecord(cars[1])
	end

	local model = template:Clone()
	local chassis = model.PrimaryPart :: BasePart -- findTemplate checked it
	-- Only the chassis is ever anchored: every other part is welded to it, so it holds the whole car.
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Anchored = false
		end
	end
	chassis.Anchored = true
	model:SetAttribute("OwnerUserId", player.UserId)
	model:AddTag(Spawning.vehicleTag)
	model:PivotTo(groundPose(model, spot))
	model.Parent = vehiclesFolder()

	local record: CarRecord = {
		model = model,
		owner = player,
		chassis = chassis,
		topSpeed = Units.mphToStuds(trim.topSpeedMph),
		driverSeat = nil,
		drivePrompt = nil,
		driving = false,
		despawnThread = nil,
		resetSerial = 0,
		connections = {},
		occupants = {},
		occupantDeaths = {},
	}
	records[model] = record
	table.insert(cars, record)

	local seats = model:FindFirstChild("Seats")
	if seats ~= nil then
		local objectText = `{player.DisplayName}'s {trim.displayName}`
		for _, child in seats:GetChildren() do
			if child:IsA("Seat") then
				setupSeat(record, child, objectText)
			end
		end
	end

	-- Forget the car if it leaves the world some other way (fell below the map, removed by another script).
	table.insert(
		record.connections,
		chassis.AncestryChanged:Connect(function()
			if not chassis:IsDescendantOf(Workspace) then
				despawnRecord(record)
			end
		end)
	)

	startDespawnTimer(record)
	return model
end

-- Removes every car the player has out.
function VehicleService.despawn(player: Player)
	local cars = carsByPlayer[player]
	if cars == nil then
		return
	end
	for _, record in table.clone(cars) do
		despawnRecord(record)
	end
end

-- The player's car, or nil.
function VehicleService.getCar(player: Player): Model?
	local record = newestCar(player)
	return if record then record.model else nil
end

-- Sits the player's character in their car's Driver seat, from anywhere (Studio and tests). Returns true when
-- they are seated or the seat was asked to seat them.
function VehicleService.seatDriver(player: Player): boolean
	local record = newestCar(player)
	local seat = if record then record.driverSeat else nil
	local humanoid = aliveCharacter(player)
	if seat == nil or humanoid == nil then
		return false
	end
	if seat.Occupant == humanoid then
		return true
	elseif seat.Occupant ~= nil then
		return false
	end
	seat:Sit(humanoid)
	return true
end

-- Dev spawn (Studio only) ----------------------------------------------------------------------------------

local function onDevSpawn(player: Player, payload: any)
	if not RunService:IsStudio() then
		return -- dev tools stay dev (CLAUDE.md hard rule 8)
	end
	local vehicleId: string = payload.vehicleId
	local trimId: string = payload.trim
	local vehicle = Catalog.getVehicle(vehicleId)
	if vehicle == nil or not vehicle.playerDrivable or Catalog.getTrim(vehicleId, trimId) == nil then
		warn(`[VehicleService] Dev spawn refused: "{vehicleId}" / "{trimId}" is not a drivable vehicle and trim`)
		return
	end
	if VehicleService.spawn(player, vehicleId, trimId) ~= nil then
		VehicleService.seatDriver(player)
	end
end

-- Boot -----------------------------------------------------------------------------------------------------

function VehicleService:Init()
	vehiclesFolder()
end

function VehicleService:Start()
	-- Always listen, so the remote never queues up; the handler itself refuses outside Studio.
	Net.onServerEvent("DevSpawnVehicle", onDevSpawn)
	Players.PlayerRemoving:Connect(function(leaving: Player)
		VehicleService.despawn(leaving)
		carsByPlayer[leaving] = nil
	end)
end

return VehicleService
