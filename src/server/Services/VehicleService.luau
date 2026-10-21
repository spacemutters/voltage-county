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
--
-- Player designs and AI mods (Phase 11, docs/phase-11-contracts.md "Designs in the catalog ... and spawning"):
--   designs  spawn(player, "custom", ..., at, { design = { uid, spec, hidden } }) builds the car from its saved
--            spec with Vehicle/SpecBuilder (once per design per server, kept in ServerStorage under
--            Config/Designer.modelsFolder), publishes its synthetic catalog entry (Catalog.publishDesign: id
--            "custom:<designUid>", trim "design", stats from SpecBuilder.stats) so every Catalog lookup works
--            unchanged, and marks the model VehicleId = "custom:<designUid>", Trim = "design", DesignUid. A design
--            a moderator hid builds from its plain look (DesignerService/Validate.plain: same class, template and
--            stats). In the session a design was made, setGeneratedLook may hand over its generated body
--            (Vehicle/GeneratedAdapter), which unmodded, unhidden designs wear instead of the kit build.
--   mods     spawn(..., { mods = savedMods, wheels }) applies the car's saved mod spec with Vehicle/ModBuilder to the
--            fresh copy (kind "kit" for designs, "catalog" for catalog cars), re-validated first; `wheels` is the
--            car's Wrap & Tint wheel style, so ModBuilder's part budget counts the faces it will wear. Mods a
--            moderator hid (mods.hidden), and every mod on a design a moderator hid, are skipped, so the car shows
--            its stock or plain look. A mod that fails to apply is logged and the car comes out without it.
--            extrasAfterMods builds the same copy out of the world, so DesignerService can see which extras a mod
--            really puts on before it is paid for.
--   seating  seatDriverWhenFree seats the player once their character has left the seat of a car just taken away
--            from under them (GarageService swapping the car they sit in): Seat:Sit in that same step doesn't take.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")
local Workspace = game:GetService("Workspace")

local AntiExploit = require(ReplicatedStorage.Shared.Config.AntiExploit)
local Catalog = require(ReplicatedStorage.Shared.Vehicle.Catalog)
local DesignKit = require(ReplicatedStorage.Shared.Config.DesignKit)
local Designer = require(ReplicatedStorage.Shared.Config.Designer)
local ModBuilder = require(ReplicatedStorage.Shared.Vehicle.ModBuilder)
local Net = require(ReplicatedStorage.Shared.Net)
local SpecBuilder = require(ReplicatedStorage.Shared.Vehicle.SpecBuilder)
local Spawning = require(ReplicatedStorage.Shared.Config.Spawning)
local Units = require(ReplicatedStorage.Shared.Util.Units)
local AntiExploitService = require(script.Parent.AntiExploitService)
local Validate = require(script.Parent.DesignerService.Validate)

local SECONDS_PER_MINUTE = 60
local MIN_FLAT = 1e-3 -- a direction shorter than this across the ground has no usable heading
local SEAT_WELD = "SeatWeld" -- the weld a Seat creates to hold its occupant
local DRIVER_SEAT = "Driver" -- seat names from the vehicle model contract
local PASSENGER_PREFIX = "Passenger"
local DEFAULT_RESET_REASON = "reset"
local BUILD_HINT = "In Studio's Edit mode, run require(game.ServerScriptService.Server.Dev.VehicleBuilder).buildAll()"
local PLAIN_SUFFIX = "_plain" -- cache key of a hidden design's plain build
local GENERATED_SUFFIX = "_generated" -- name of a design's session-only generated look in the models folder

-- A saved design as VehicleService needs it (Types.CustomDesign's fields).
export type DesignSource = { uid: string, spec: { [string]: any }, hidden: boolean }

-- What an owned car needs beyond its catalog id and trim (GarageService passes them).
export type SpawnOptions = {
	design: DesignSource?, -- set for a player design (vehicleId "custom")
	mods: { [string]: any }?, -- the car's saved AI mod spec (OwnedVehicle.mods)
	wheels: string?, -- the car's Wrap & Tint wheel style (OwnedVehicle.wheels), for ModBuilder's part budget
}

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

-- Player designs ---------------------------------------------------------------------------------------------

local designTemplates: { [string]: Model } = {} -- kit builds, by design uid (plus PLAIN_SUFFIX when hidden)
local generatedLooks: { [string]: Model } = {} -- session-only generated looks, by design uid
local designSources: { [string]: DesignSource } = {} -- the designs published on this server (Studio's dev spawn)

local function designModelsFolder(): Folder
	local existing = ServerStorage:FindFirstChild(Designer.modelsFolder)
	if existing ~= nil and existing:IsA("Folder") then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = Designer.modelsFolder
	folder.Parent = ServerStorage
	return folder
end

-- The catalog id of a design ("custom:<designUid>").
function VehicleService.designVehicleId(designUid: string): string
	return Catalog.designId(designUid)
end

-- The validated spec a design builds from: its saved spec checked again against the kit (the plain look when a
-- moderator hid it). nil, with a warning, when the saved spec no longer validates.
function VehicleService.designSpec(design: DesignSource): Validate.Spec?
	local spec, reasons = Validate.design(design.spec, DesignKit)
	if spec == nil then
		warn(`[VehicleService] Design {design.uid} has a spec the kit no longer accepts: {table.concat(reasons, "; ")}`)
		return nil
	end
	return if design.hidden then Validate.plain(spec, DesignKit) else spec
end

-- Publishes (or re-publishes) the design's synthetic catalog entry, so Catalog.getVehicle("custom:<uid>") and
-- getTrim(..., "design") work on the server and every client. Returns false when the spec doesn't validate or the
-- kit builders refuse it.
function VehicleService.publishDesign(design: DesignSource): boolean
	local spec = VehicleService.designSpec(design)
	if spec == nil then
		return false
	end
	local ok, err = pcall(function()
		Catalog.publishDesign(design.uid, SpecBuilder.vehicleFor(spec, DesignKit, design.uid))
	end)
	if not ok then
		warn(`[VehicleService] Couldn't publish design {design.uid}: {err}`)
	else
		designSources[design.uid] = design
	end
	return ok
end

-- The kit build of a design (built once per server and look, then cloned for every spawn), or nil.
local function designTemplate(design: DesignSource): Model?
	local key = design.uid .. (if design.hidden then PLAIN_SUFFIX else "")
	local cached = designTemplates[key]
	if cached ~= nil and cached.Parent ~= nil then
		return cached
	end
	local spec = VehicleService.designSpec(design)
	if spec == nil then
		return nil
	end
	local ok, built = pcall(SpecBuilder.build, spec, DesignKit)
	if not ok or typeof(built) ~= "Instance" or not built:IsA("Model") or built.PrimaryPart == nil then
		warn(`[VehicleService] SpecBuilder couldn't build design {design.uid}: {if ok then "no model" else built}`)
		return nil
	end
	local model = built :: Model
	model.Name = key
	model.Parent = designModelsFolder()
	designTemplates[key] = model
	return model
end

-- The kit build of a design for a spec that has just been validated (DesignerService, for the generated look to
-- fit onto). Builds and caches it like a spawn would; nil when it can't be built.
function VehicleService.designBuild(design: DesignSource): Model?
	return designTemplate(design)
end

-- True when saved mods would change the car (present, not hidden by a moderator).
local function activeMods(mods: any): boolean
	return type(mods) == "table" and mods.hidden ~= true
end

-- What a design spawns as: its generated look while this session has one (unhidden, unmodded designs only),
-- else its kit build.
local function designModel(design: DesignSource, mods: any): Model?
	local generated = generatedLooks[design.uid]
	if generated ~= nil and generated.Parent ~= nil and not design.hidden and not activeMods(mods) then
		return generated
	end
	return designTemplate(design)
end

-- Hands over a design's session-only generated look (Vehicle/GeneratedAdapter); nil forgets it. The model is
-- kept in ServerStorage and cloned for every spawn of that design until the server closes or forgetDesign.
function VehicleService.setGeneratedLook(designUid: string, look: Model?)
	local old = generatedLooks[designUid]
	generatedLooks[designUid] = nil
	if old ~= nil and old ~= look then
		old:Destroy()
	end
	if look ~= nil then
		look.Name = designUid .. GENERATED_SUFFIX
		look.Parent = designModelsFolder()
		generatedLooks[designUid] = look
	end
end

-- True while this session has a generated look for the design.
function VehicleService.hasGeneratedLook(designUid: string): boolean
	local look = generatedLooks[designUid]
	return look ~= nil and look.Parent ~= nil
end

-- Drops everything this server built for a design (its kit builds and generated look) and takes its catalog
-- entry down, e.g. when it is scrapped, never built, or its owner leaves. Cars already out keep their own copies.
function VehicleService.forgetDesign(designUid: string)
	for _, key in { designUid, designUid .. PLAIN_SUFFIX } do
		local cached = designTemplates[key]
		designTemplates[key] = nil
		if cached ~= nil then
			cached:Destroy()
		end
	end
	VehicleService.setGeneratedLook(designUid, nil)
	designSources[designUid] = nil
	local ok, err = pcall(Catalog.unpublishDesign, designUid)
	if not ok then
		warn(`[VehicleService] Couldn't take design {designUid} out of the catalog: {err}`)
	end
end

-- Applies a car's saved mods to a fresh copy (`wheels`: the wheel style its look puts on afterwards). Never lets a
-- mod problem stop the spawn. False when the mods were there but couldn't be applied.
local function applyMods(model: Model, mods: any, kind: Validate.Kind, wheels: string?): boolean
	if not activeMods(mods) then
		return true
	end
	local checked, reasons = Validate.mod(mods, DesignKit, kind)
	if checked == nil then
		warn(`[VehicleService] Skipped saved mods on {model.Name}: {table.concat(reasons, "; ")}`)
		return false
	end
	local ok, err = pcall(ModBuilder.apply, model, checked, DesignKit, kind, { wheels = wheels })
	if not ok then
		warn(`[VehicleService] Couldn't apply mods to {model.Name}: {err}`)
	end
	return ok
end

-- Gives a copy of a design's kit build its identity as that design (the catalog id it is published under).
local function markDesign(model: Model, design: DesignSource, vehicleId: string, trimId: string)
	model.Name = Catalog.modelName(vehicleId, trimId)
	model:SetAttribute("VehicleId", vehicleId)
	model:SetAttribute("Trim", trimId)
	model:SetAttribute("DesignUid", design.uid)
end

-- The extras an owned car really carries with `options.mods` (in the order they went on): a copy of its model built
-- the way spawn builds it (ModBuilder leaves off extras the car can't carry, or has no room for in the part budget
-- with `options.wheels` on), which never enters the world. DesignerService checks a mod with it before charging.
-- nil when the car can't be built here, or its mods can't be applied.
function VehicleService.extrasAfterMods(vehicleId: string, trimId: string, options: SpawnOptions): { string }?
	local design = options.design
	if design ~= nil then
		if design.hidden or not VehicleService.publishDesign(design) then
			return nil
		end
		vehicleId = VehicleService.designVehicleId(design.uid)
		trimId = Designer.designTrim
	end
	local template = if design ~= nil then designTemplate(design) else findTemplate(vehicleId, trimId)
	if template == nil then
		return nil
	end
	local model = template:Clone()
	if design ~= nil then
		markDesign(model, design, vehicleId, trimId)
	end
	local applied = applyMods(model, options.mods, if design ~= nil then "kit" else "catalog", options.wheels)
	local ids = if applied then ModBuilder.extrasOn(model) else nil
	model:Destroy()
	return ids
end

-- Public API: spawning -------------------------------------------------------------------------------------

-- Spawns a parked car for `player` at `at` (on the ground below it), or just in front of their character.
-- Despawns their previous car first (Config/Spawning.maxCarsPerPlayer). `options` carries a player design (then
-- `vehicleId` and `trimId` are ignored: the design's own catalog id and trim are used) and the car's saved mods.
-- Returns nil, with a warning, when the vehicle, its model or a place to put it is missing.
function VehicleService.spawn(
	player: Player,
	vehicleId: string,
	trimId: string,
	at: CFrame?,
	options: SpawnOptions?
): Model?
	local design = if options ~= nil then options.design else nil
	local mods = if options ~= nil then options.mods else nil
	local wheels = if options ~= nil then options.wheels else nil
	if design ~= nil then
		if design.hidden then
			mods = nil -- a design a moderator hid falls back to its plain kit look, mods and all
		end
		if not VehicleService.publishDesign(design) then
			return nil
		end
		vehicleId = VehicleService.designVehicleId(design.uid)
		trimId = Designer.designTrim
	end
	local trim = Catalog.getTrim(vehicleId, trimId)
	local geometry = Catalog.geometry(vehicleId, trimId)
	if trim == nil or geometry == nil then
		warn(`[VehicleService] No vehicle "{vehicleId}" with trim "{trimId}" in Config/Vehicles`)
		return nil
	end
	if player.Parent == nil then
		return nil -- left the game
	end
	local template = if design ~= nil then designModel(design, mods) else findTemplate(vehicleId, trimId)
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
	local chassis = model.PrimaryPart :: BasePart -- findTemplate (or designTemplate) checked it
	if design ~= nil then
		markDesign(model, design, vehicleId, trimId)
	end
	-- Mods go on before anything else touches the copy, so the Wrap & Tint look (CustomizationService) layers on
	-- top of the modded car.
	applyMods(model, mods, if design ~= nil then "kit" else "catalog", wheels)
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

-- Sits the player in their newest car's Driver seat once their character is out of any seat it was in. A car
-- destroyed under its driver (GarageService swapping the car they sit in, a dev spawn, a test drive) leaves the
-- Humanoid seated for a moment, and a Seat:Sit in that same step doesn't take: this waits until the Humanoid has no
-- SeatPart and has left the Seated state, at most Config/Spawning.reseatTimeoutSeconds, then seats them. Never
-- yields; listens to the Humanoid's own signals (no polling).
function VehicleService.seatDriverWhenFree(player: Player)
	local humanoid = aliveCharacter(player)
	if humanoid == nil then
		return
	end
	local function free(): boolean
		return humanoid.SeatPart == nil and humanoid:GetState() ~= Enum.HumanoidStateType.Seated
	end
	if free() then
		VehicleService.seatDriver(player)
		return
	end
	local done = false
	local connections: { RBXScriptConnection } = {}
	local timer: thread? = nil
	local function finish()
		if done then
			return
		end
		done = true
		for _, connection in connections do
			connection:Disconnect()
		end
		local pending = timer
		timer = nil
		if pending ~= nil and pending ~= coroutine.running() then
			task.cancel(pending)
		end
		VehicleService.seatDriver(player)
	end
	local function check()
		if free() then
			finish()
		end
	end
	table.insert(connections, humanoid:GetPropertyChangedSignal("SeatPart"):Connect(check))
	table.insert(connections, humanoid.StateChanged:Connect(check))
	timer = task.delay(Spawning.reseatTimeoutSeconds, finish)
end

-- Dev spawn (Studio only) ----------------------------------------------------------------------------------

local function onDevSpawn(player: Player, payload: any)
	if not RunService:IsStudio() then
		return -- dev tools stay dev (CLAUDE.md hard rule 8)
	end
	local vehicleId: string = payload.vehicleId
	local trimId: string = payload.trim
	-- A player design ("custom:<designUid>") spawns from the design this server published for it (its owner is
	-- here), built like any spawn of it; there is no stored model to clone. Dev spawns skip the car's saved mods.
	if Catalog.isDesign(vehicleId) then
		local designUid = Catalog.designUidOf(vehicleId)
		local source = if designUid ~= nil then designSources[designUid] else nil
		if source == nil then
			warn(`[VehicleService] Dev spawn refused: design "{vehicleId}" isn't published on this server`)
			return
		end
		if VehicleService.spawn(player, vehicleId, trimId, nil, { design = source }) ~= nil then
			VehicleService.seatDriverWhenFree(player)
		end
		return
	end
	local vehicle = Catalog.getVehicle(vehicleId)
	if vehicle == nil or not vehicle.playerDrivable or Catalog.getTrim(vehicleId, trimId) == nil then
		warn(`[VehicleService] Dev spawn refused: "{vehicleId}" / "{trimId}" is not a drivable vehicle and trim`)
		return
	end
	if VehicleService.spawn(player, vehicleId, trimId) ~= nil then
		VehicleService.seatDriverWhenFree(player)
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
