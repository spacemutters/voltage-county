--!strict
-- Houses (PLAN.md Phase 13; docs/phase-13-contracts.md "Houses"): the HousePlots in Riverside (Config/MapLayout)
-- that players claim for as long as they are on this server.
--
--   plots      at Start every HousePlot gets a model Workspace.<Config/Houses folderName>.<plotId> (outside
--              Workspace.Map.Generated, which MapBuilder owns) with its sign by the road: "Free house" and the
--              address, and a "Claim house" ProximityPrompt while the plot is free.
--   claiming   the prompt (checked by Roblox) or Net ClaimHouse { plotId } (the character must stand within
--              Config/Houses claimReach of the sign). One plot per player per server (claimRefusal): a plot already
--              theirs, a second plot or someone else's plot is refused with a plain reason, and so is a lot where a
--              car's chassis or another player stands where a wall would appear (Config/Houses lotClear). The house
--              appears at
--              once (Config/Houses structure: walls, roof, windows, front door, the garage with its door and the
--              home charger's bay, the driveway, the mailbox and the owned upgrades), the sign shows the owner's
--              display name (Roblox display names need no filtering) and the prompt goes away. The windows and the
--              porch lights are night lights (Config/Houses Piece.night): Services/DayNightService lights them from
--              dusk to dawn.
--   releasing  Net LeaveHouse, or the player leaving the server: the house is removed and the plot is free again.
--   upgrades   Net BuyHouseUpgrade { upgrade }: Config/Houses upgrades, bought once with cash through
--              EconomyService.trySpend (reason Config/Houses economyReason; refunded if the save can't be written)
--              and saved in PlayerData.house.upgrades[id] = true. They apply to whichever plot the player claims,
--              and at once to the one they hold: the extras are rebuilt and the charger's attributes updated.
--   charging   the garage's charger bay is tagged Config/Houses charger.tag with the owner's UserId, its kW and its
--              price per full charge (Config/Houses chargerKW and chargerCostPerFull); Services/EnergyService
--              charges only the owner's own car there.
--   the door   an invisible sensor over the driveway and the garage bay: when the owner's car (its Chassis part)
--              touches it, the garage door swings up under the roof. A look Config/Houses door.closeCheckSeconds
--              later decides: a car moving in the sensor (being driven, not standing still) looks again after the
--              same delay; a car standing in the doorway (door.doorwaySize) keeps it open and the service waits,
--              without a timer, for that car to be driven off or removed; otherwise the door closes. With it shut,
--              the owner's cars standing in the sensor (parked in the bay, say) are watched the same way, and the
--              door opens once one of them moves off. A car stands when its chassis is anchored (parked) or
--              EnergyService marks it still (Config/Energy attributes.still). No polling while nothing moves
--              (CLAUDE.md hard rule 10).
--
-- Remotes (declared in Net): ClaimHouse { plotId } and BuyHouseUpgrade { upgrade } and LeaveHouse reply
-- { ok, message, plotId?, address? }; HouseUpdate (server -> the player) { plotId?, address?, upgrades, message? }
-- whenever their house or upgrades change, and when their data loads. The client shows a reply's message as a
-- notice; a claim made with the prompt (no client waiting) is answered with a Notify toast instead.
-- Server-authoritative (CLAUDE.md hard rule 1): the client only names a plot or an upgrade.
--
-- The decisions are pure helpers for tests/Houses.spec: claimRefusal, claim, release, ownerOf, plotOf, opensFor,
-- insideBox, overlapsBox, lotBoxes and lotBlocked (the upgrade and charger math is in Config/Houses).

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local Controls = require(Shared.Config.Controls)
local Economy = require(Shared.Config.Economy)
local EnergyConfig = require(Shared.Config.Energy)
local Environment = require(Shared.Config.Environment)
local Houses = require(Shared.Config.Houses)
local MapLayout = require(Shared.Config.MapLayout)
local Net = require(Shared.Net)
local Spawning = require(Shared.Config.Spawning)
local Types = require(Shared.Types)

-- The services this one calls are required in Init rather than here, so tests/Houses.spec can require this module
-- in Edit mode for its pure helpers without loading DataService (ProfileStore talks to DataStores at once).
type DataServiceModule = typeof(require(script.Parent.DataService))
type EconomyServiceModule = typeof(require(script.Parent.EconomyService))

-- Who holds which plot on this server: plot id -> UserId and UserId -> plot id, always in step.
export type Claims = { byPlot: { [string]: number }, byUser: { [number]: string } }

-- Why a claim is refused (nil: it may go ahead): no such plot, it is already theirs, they hold another plot, or
-- someone else holds it.
export type ClaimRefusal = "noPlot" | "yours" | "hasHouse" | "taken"

export type Reply = { ok: boolean, message: string, plotId: string?, address: string? }

-- A box in the world: its centre frame and size (a part, a car's chassis, a piece of the house).
export type Box = { frame: CFrame, size: Vector3 }

-- One plot's instances on this server.
type Plot = {
	location: MapLayout.Location,
	frame: CFrame,
	wallColor: Color3,
	model: Model,
	prompt: ProximityPrompt,
	topLabel: TextLabel,
	titleLabel: TextLabel,
	house: Model?, -- while claimed
	extras: Folder?, -- inside the house: the mailbox and the upgrades' parts
	pad: BasePart?, -- the home charger's bay
	door: BasePart?,
	sensor: BasePart?,
	doorOpen: boolean,
	doorTween: Tween?,
	doorTimer: thread?, -- the pending close check while a car moves in the sensor
	doorWatch: { RBXScriptConnection }, -- standing cars the door waits on (no timer runs meanwhile)
}

local LOG = "[HouseService]"
local VEHICLES_FOLDER = Spawning.vehiclesFolder
local STILL_ATTRIBUTE = EnergyConfig.attributes.still -- EnergyService: the car stands still
local ROOT_PART = "HumanoidRootPart"
local SIGN_NAME = "Sign"
local HOUSE_NAME = "House"
local EXTRAS_NAME = "Extras"

local text = Houses.text
local signConfig = Houses.sign
local doorConfig = Houses.door
local chargerConfig = Houses.charger

local HouseService = {}

local DataService: DataServiceModule? = nil
local EconomyService: EconomyServiceModule? = nil

local plots: { [string]: Plot } = {}
-- Roast fixes (2026-10-24): onClaimed listeners (Services/GoalsService's "claim a house" goal).
local claimedListeners: { (player: Player, plotId: string) -> () } = {}

-- Every HousePlot location by id, and its place among them (it picks the wall colour).
local plotLocations: { [string]: MapLayout.Location } = {}
local plotOrder: { string } = {}
for _, location in MapLayout.locations do
	if location.tag == Houses.plotTag then
		plotLocations[location.id] = location
		table.insert(plotOrder, location.id)
	end
end

-- Pure helpers ----------------------------------------------------------------------------------------------

function HouseService.newClaims(): Claims
	return { byPlot = {}, byUser = {} }
end

-- Why `userId` can't claim `plotId` (nil: they can). `plotExists` says whether it is a HousePlot on the map.
function HouseService.claimRefusal(claims: Claims, userId: number, plotId: string, plotExists: boolean): ClaimRefusal?
	if not plotExists then
		return "noPlot"
	end
	local held = claims.byUser[userId]
	if held == plotId then
		return "yours"
	elseif held ~= nil then
		return "hasHouse"
	elseif claims.byPlot[plotId] ~= nil then
		return "taken"
	end
	return nil
end

-- Records `userId` holding `plotId`. Only after claimRefusal said nil; returns false (and changes nothing) when the
-- plot or the player is already taken, so a claim can never double up.
function HouseService.claim(claims: Claims, userId: number, plotId: string): boolean
	if claims.byUser[userId] ~= nil or claims.byPlot[plotId] ~= nil then
		return false
	end
	claims.byUser[userId] = plotId
	claims.byPlot[plotId] = userId
	return true
end

-- Frees whatever plot `userId` holds and returns its id (nil when they held none).
function HouseService.release(claims: Claims, userId: number): string?
	local plotId = claims.byUser[userId]
	if plotId == nil then
		return nil
	end
	claims.byUser[userId] = nil
	if claims.byPlot[plotId] == userId then
		claims.byPlot[plotId] = nil
	end
	return plotId
end

-- The UserId holding `plotId`, or nil while it is free.
function HouseService.ownerOf(claims: Claims, plotId: string): number?
	return claims.byPlot[plotId]
end

-- The plot `userId` holds, or nil.
function HouseService.plotOf(claims: Claims, userId: number): string?
	return claims.byUser[userId]
end

-- Whether a car whose OwnerUserId attribute is `carOwner` opens the garage door of a plot held by `plotOwner`:
-- only the owner's own car, never a car with no owner, and never on a free plot.
function HouseService.opensFor(plotOwner: number?, carOwner: any): boolean
	return plotOwner ~= nil and type(carOwner) == "number" and carOwner == plotOwner
end

-- True when `position` lies inside the box of `size` at `frame` (in the box's own axes).
function HouseService.insideBox(frame: CFrame, size: Vector3, position: Vector3): boolean
	local localPosition = frame:PointToObjectSpace(position)
	local half = size / 2
	return math.abs(localPosition.X) <= half.X
		and math.abs(localPosition.Y) <= half.Y
		and math.abs(localPosition.Z) <= half.Z
end

-- True when the box `partSize` at `partFrame` overlaps the box `size` at `frame`. Tested on `frame`'s own axes with
-- the part's reach along each, so a part turned against the box counts a little early (never late). Boxes that only
-- touch don't overlap.
function HouseService.overlapsBox(frame: CFrame, size: Vector3, partFrame: CFrame, partSize: Vector3): boolean
	local relative = frame:ToObjectSpace(partFrame)
	local _, _, _, r00, r01, r02, r10, r11, r12, r20, r21, r22 = relative:GetComponents()
	local half = partSize / 2
	local reachX = math.abs(r00) * half.X + math.abs(r01) * half.Y + math.abs(r02) * half.Z
	local reachY = math.abs(r10) * half.X + math.abs(r11) * half.Y + math.abs(r12) * half.Z
	local reachZ = math.abs(r20) * half.X + math.abs(r21) * half.Y + math.abs(r22) * half.Z
	local centre = relative.Position
	return math.abs(centre.X) < size.X / 2 + reachX
		and math.abs(centre.Y) < size.Y / 2 + reachY
		and math.abs(centre.Z) < size.Z / 2 + reachZ
end

-- Where a house piece stands on a plot whose frame is `frame` (as it is built).
local function pieceFrame(piece: Houses.Piece, frame: CFrame): CFrame
	return frame * CFrame.new(piece.offset) * CFrame.Angles(math.rad(piece.tilt or 0), math.rad(piece.turn or 0), 0)
end

-- The boxes of a house on the plot at `frame` that must be clear before it is built (Config/Houses lotClear).
function HouseService.lotBoxes(frame: CFrame): { Box }
	local check = Houses.lotClear
	local boxes: { Box } = {}
	for _, piece in Houses.structure do
		if table.find(check.pieces, piece.name) ~= nil then
			table.insert(boxes, { frame = pieceFrame(piece, frame), size = piece.size })
		end
	end
	if check.door then
		local door = Houses.door
		table.insert(boxes, { frame = frame * CFrame.new(door.offset), size = door.size })
	end
	return boxes
end

-- True when any of `parts` (cars' chassis, players' root parts) overlaps any of `boxes`.
function HouseService.lotBlocked(boxes: { Box }, parts: { Box }): boolean
	for _, part in parts do
		for _, box in boxes do
			if HouseService.overlapsBox(box.frame, box.size, part.frame, part.size) then
				return true
			end
		end
	end
	return false
end

-- State --------------------------------------------------------------------------------------------------------

local claims = HouseService.newClaims()

local function notify(player: Player, message: string, kind: string)
	if player.Parent == Players then
		Net.fireClient("Notify", player, { text = message, kind = kind })
	end
end

-- A remote's answer. The client shows its message as a notice (the prompt's path shows it with Notify instead).
local function reply(ok: boolean, message: string, plotId: string?): Reply
	local location = if plotId ~= nil then plotLocations[plotId] else nil
	return {
		ok = ok,
		message = message,
		plotId = plotId,
		address = if location ~= nil then location.displayName else nil,
	}
end

-- The player's owned upgrades from their save (an empty set until it loads).
local function ownedUpgrades(player: Player): { [string]: boolean }
	local dataService = DataService
	local data = if dataService ~= nil then dataService.get(player) else nil
	if data == nil then
		return {}
	end
	local house: any = data.house
	return Houses.cleanUpgrades(if type(house) == "table" then house.upgrades else nil)
end

-- Tells the player about their house: where it is (if they hold one) and the upgrades they own.
local function sendUpdate(player: Player, message: string?)
	if player.Parent ~= Players then
		return
	end
	local plotId = HouseService.plotOf(claims, player.UserId)
	local location = if plotId ~= nil then plotLocations[plotId] else nil
	Net.fireClient("HouseUpdate", player, {
		plotId = plotId,
		address = if location ~= nil then location.displayName else nil,
		upgrades = Houses.ownedList(ownedUpgrades(player)),
		message = message,
	})
end

-- Building -----------------------------------------------------------------------------------------------------

local function newPart(piece: Houses.Piece, frame: CFrame, color: Color3, parent: Instance): BasePart
	local part: BasePart = if piece.shape == "wedge" then Instance.new("WedgePart") else Instance.new("Part")
	part.Name = piece.name
	part.Size = piece.size
	part.CFrame = pieceFrame(piece, frame)
	part.Color = piece.color or color
	part.Material = piece.material
	part.Transparency = piece.transparency or 0
	part.Anchored = true
	part.CanCollide = piece.solid
	part.CanQuery = piece.solid
	part.CanTouch = false
	part.CastShadow = piece.solid
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	if piece.glow == true then
		local glow = Houses.porchLight
		local light = Instance.new("PointLight")
		light.Range = glow.range
		light.Brightness = glow.brightness
		light.Color = glow.color
		light.Parent = part
	end
	local night = piece.night
	if night ~= nil then
		-- Lit from dusk to dawn by Services/DayNightService, which gives the part the current look (and switches
		-- its PointLight) the moment the house enters the world.
		local lights = Environment.nightLights
		part:SetAttribute(lights.kindAttribute, night)
		part:SetAttribute(lights.dayColorAttribute, part.Color)
		CollectionService:AddTag(part, lights.tag)
	end
	part.Parent = parent
	return part
end

local function buildPieces(pieces: { Houses.Piece }, plot: Plot, parent: Instance)
	for _, piece in pieces do
		newPart(piece, plot.frame, plot.wallColor, parent)
	end
end

local function signLabel(name: string, row: { number }, font: Font, color: Color3, parent: Instance): TextLabel
	local padding = signConfig.padding
	local label = Instance.new("TextLabel")
	label.Name = name
	label.BackgroundTransparency = 1
	label.Position = UDim2.fromScale(padding, row[1])
	label.Size = UDim2.fromScale(1 - 2 * padding, row[2])
	label.FontFace = font
	label.TextColor3 = color
	label.TextScaled = true
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextTruncate = Enum.TextTruncate.AtEnd
	label.Parent = parent
	return label
end

-- Shows the plot as free (title in the free colour, the prompt on) or as `owner`'s home.
local function setSign(plot: Plot, owner: Player?)
	if owner ~= nil then
		plot.topLabel.Text = text.signOwnedTop
		plot.titleLabel.Text = owner.DisplayName
		plot.titleLabel.TextColor3 = signConfig.ownedColor
		plot.model:SetAttribute(Houses.plotAttributes.owner, owner.UserId)
	else
		plot.topLabel.Text = text.signFreeTop
		plot.titleLabel.Text = text.signFreeTitle
		plot.titleLabel.TextColor3 = signConfig.freeColor
		plot.model:SetAttribute(Houses.plotAttributes.owner, nil)
	end
	plot.prompt.Enabled = owner == nil
end

local claimPlot: (player: Player, plotId: string, viaPrompt: boolean) -> Reply

-- The plot's model and its sign (built once at Start for every HousePlot).
local function buildPlot(parent: Instance, location: MapLayout.Location, index: number): Plot
	local frame = Houses.plotFrame(location.position, location.yaw)
	local colors = Houses.wallColors
	local model = Instance.new("Model")
	model.Name = location.id
	model.ModelStreamingMode = Enum.ModelStreamingMode.Atomic
	model:SetAttribute(Houses.plotAttributes.address, location.displayName)

	local sign = Instance.new("Model")
	sign.Name = SIGN_NAME
	local postPiece: Houses.Piece = {
		name = "Post",
		offset = signConfig.postOffset,
		size = signConfig.postSize,
		color = signConfig.postColor,
		material = Enum.Material.Metal,
		solid = true,
	}
	local boardPiece: Houses.Piece = {
		name = "Board",
		offset = signConfig.boardOffset,
		size = signConfig.boardSize,
		color = signConfig.boardColor,
		material = Enum.Material.SmoothPlastic,
		solid = true,
	}
	newPart(postPiece, frame, signConfig.postColor, sign)
	local board = newPart(boardPiece, frame, signConfig.boardColor, sign)

	local gui = Instance.new("SurfaceGui")
	gui.Name = "Text"
	gui.Face = Enum.NormalId.Front -- the board's front faces the road, like the plot
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = signConfig.pixelsPerStud
	gui.LightInfluence = 0
	gui.Parent = board
	local fonts = Controls.theme.fonts
	local topLabel = signLabel("Top", signConfig.topRow, fonts.medium, signConfig.dimColor, gui)
	local titleLabel = signLabel("Title", signConfig.titleRow, fonts.bold, signConfig.freeColor, gui)
	local addressLabel = signLabel("Address", signConfig.addressRow, fonts.regular, signConfig.textColor, gui)
	addressLabel.Text = location.displayName

	local promptConfig = Houses.prompt
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = promptConfig.name
	prompt.ActionText = promptConfig.actionText
	prompt.ObjectText = location.displayName
	prompt.HoldDuration = promptConfig.holdSeconds
	prompt.MaxActivationDistance = promptConfig.maxDistance
	prompt.RequiresLineOfSight = false
	prompt.Parent = board
	local plotId = location.id
	prompt.Triggered:Connect(function(player: Player)
		-- No client is waiting on a reply here: the answer goes out as a notice.
		local result = claimPlot(player, plotId, true)
		notify(player, result.message, if result.ok then "success" else "info")
	end)

	sign.Parent = model
	model.Parent = parent

	local plot: Plot = {
		location = location,
		frame = frame,
		wallColor = colors[(index - 1) % #colors + 1],
		model = model,
		prompt = prompt,
		topLabel = topLabel,
		titleLabel = titleLabel,
		house = nil,
		extras = nil,
		pad = nil,
		door = nil,
		sensor = nil,
		doorOpen = false,
		doorTween = nil,
		doorTimer = nil,
		doorWatch = {},
	}
	setSign(plot, nil)
	return plot
end

-- (Re)builds the house's extras and the charger's attributes from the owner's upgrades.
local function decorate(plot: Plot, owned: { [string]: boolean })
	local house = plot.house
	if house == nil then
		return
	end
	local old = plot.extras
	if old ~= nil then
		old:Destroy()
	end
	local extras = Instance.new("Folder")
	extras.Name = EXTRAS_NAME
	if owned[Houses.plainMailboxReplacedBy] ~= true then
		buildPieces(Houses.plainMailbox, plot, extras)
	end
	for _, upgrade in Houses.upgrades do
		local pieces = Houses.extras[upgrade.id]
		if owned[upgrade.id] == true and pieces ~= nil then
			buildPieces(pieces, plot, extras)
		end
	end
	extras.Parent = house
	plot.extras = extras

	local pad = plot.pad
	if pad ~= nil then
		pad:SetAttribute(chargerConfig.kWAttribute, Houses.chargerKW(owned))
		pad:SetAttribute(chargerConfig.costAttribute, Houses.chargerCostPerFull(owned))
	end
end

-- The garage door ------------------------------------------------------------------------------------------------

local function doorFrame(plot: Plot, open: boolean): CFrame
	if open then
		return plot.frame * CFrame.new(doorConfig.openOffset) * CFrame.Angles(math.rad(doorConfig.openTilt), 0, 0)
	end
	return plot.frame * CFrame.new(doorConfig.offset)
end

local function moveDoor(plot: Plot, open: boolean)
	local door = plot.door
	if door == nil then
		return
	end
	local running = plot.doorTween
	if running ~= nil then
		running:Cancel()
	end
	plot.doorOpen = open
	door.CanCollide = false -- solid again only once it is fully shut
	local seconds = if open then doorConfig.openSeconds else doorConfig.closeSeconds
	local tween = TweenService:Create(
		door,
		TweenInfo.new(seconds, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut),
		{ CFrame = doorFrame(plot, open) }
	)
	plot.doorTween = tween
	tween.Completed:Connect(function(state: Enum.PlaybackState)
		if state == Enum.PlaybackState.Completed and plot.doorTween == tween then
			plot.doorTween = nil
			if not plot.doorOpen and plot.door == door then
				door.CanCollide = true
			end
		end
	end)
	tween:Play()
end

-- Every car's chassis in Workspace.Vehicles.
local function carChassis(): { BasePart }
	local list: { BasePart } = {}
	local vehicles = Workspace:FindFirstChild(VEHICLES_FOLDER)
	if vehicles == nil then
		return list
	end
	for _, car in vehicles:GetChildren() do
		local chassis = car:FindFirstChild(doorConfig.chassisName)
		if chassis ~= nil and chassis:IsA("BasePart") then
			table.insert(list, chassis)
		end
	end
	return list
end

-- Whether a car stands: parked (its chassis anchored) or still with its driver in it (EnergyService's Still).
local function standing(chassis: BasePart): boolean
	local car = chassis.Parent
	return chassis.Anchored or (car ~= nil and car:GetAttribute(STILL_ATTRIBUTE) == true)
end

local function inSensor(plot: Plot, chassis: BasePart): boolean
	local sensor = plot.sensor
	return sensor ~= nil and HouseService.insideBox(sensor.CFrame, sensor.Size, chassis.Position)
end

local function stopWatching(plot: Plot)
	for _, connection in plot.doorWatch do
		connection:Disconnect()
	end
	table.clear(plot.doorWatch)
end

-- Waits, with no timer, for any of `cars` to be driven or move off, or to leave the world; then calls `wake` once.
local function watchCars(plot: Plot, cars: { BasePart }, wake: () -> ())
	stopWatching(plot)
	local function fire()
		stopWatching(plot)
		if plot.house ~= nil then
			wake()
		end
	end
	for _, chassis in cars do
		table.insert(plot.doorWatch, chassis:GetPropertyChangedSignal("Anchored"):Connect(fire))
		table.insert(plot.doorWatch, chassis.AncestryChanged:Connect(fire))
		local car = chassis.Parent
		if car ~= nil then
			table.insert(plot.doorWatch, car:GetAttributeChangedSignal(STILL_ATTRIBUTE):Connect(fire))
		end
	end
end

local scheduleClose: (plot: Plot) -> ()

local function openDoor(plot: Plot)
	stopWatching(plot)
	if not plot.doorOpen then
		moveDoor(plot, true)
	end
	scheduleClose(plot)
end

-- With the door shut: opens it once one of the owner's cars standing in the sensor (parked in the bay or on the
-- driveway) moves off, and until then waits on them without a timer.
local function settleShut(plot: Plot)
	stopWatching(plot)
	if plot.house == nil or plot.doorOpen then
		return
	end
	local owner = HouseService.ownerOf(claims, plot.location.id)
	local waiting: { BasePart } = {}
	for _, chassis in carChassis() do
		local car = chassis.Parent
		if
			car ~= nil
			and HouseService.opensFor(owner, car:GetAttribute(doorConfig.carOwnerAttribute))
			and inSensor(plot, chassis)
		then
			if not standing(chassis) then
				openDoor(plot)
				return
			end
			table.insert(waiting, chassis)
		end
	end
	if #waiting > 0 then
		watchCars(plot, waiting, function()
			settleShut(plot)
		end)
	end
end

-- With the door open: closes it once no car is in its way. A car moving in the sensor means a look again shortly;
-- a car standing in the doorway keeps it open until that car moves or goes (watched, no timer).
local function checkDoor(plot: Plot)
	if plot.house == nil or not plot.doorOpen then
		return
	end
	local doorway = doorFrame(plot, false)
	local moving = false
	local inDoorway: { BasePart } = {}
	for _, chassis in carChassis() do
		local blocking = HouseService.overlapsBox(doorway, doorConfig.doorwaySize, chassis.CFrame, chassis.Size)
		if not standing(chassis) and (blocking or inSensor(plot, chassis)) then
			moving = true
			break
		elseif blocking then
			table.insert(inDoorway, chassis)
		end
	end
	if moving then
		scheduleClose(plot)
	elseif #inDoorway > 0 then
		watchCars(plot, inDoorway, function()
			scheduleClose(plot)
		end)
	else
		moveDoor(plot, false)
		settleShut(plot)
	end
end

scheduleClose = function(plot: Plot)
	stopWatching(plot)
	local pending = plot.doorTimer
	if pending ~= nil then
		task.cancel(pending)
	end
	plot.doorTimer = task.delay(doorConfig.closeCheckSeconds, function()
		plot.doorTimer = nil
		checkDoor(plot)
	end)
end

local function onSensorTouched(plot: Plot, hit: BasePart)
	if hit.Name ~= doorConfig.chassisName then
		return
	end
	local car = hit.Parent
	local vehicles = Workspace:FindFirstChild(VEHICLES_FOLDER)
	if car == nil or vehicles == nil or car.Parent ~= vehicles then
		return
	end
	local owner = HouseService.ownerOf(claims, plot.location.id)
	if not HouseService.opensFor(owner, car:GetAttribute(doorConfig.carOwnerAttribute)) then
		return
	end
	openDoor(plot)
end

-- Claiming and releasing -------------------------------------------------------------------------------------------

local function buildHouse(plot: Plot, owner: Player, owned: { [string]: boolean })
	local house = Instance.new("Model")
	house.Name = HOUSE_NAME
	buildPieces(Houses.structure, plot, house)

	local padConfig = Houses.chargerPad
	local pad = newPart({
		name = padConfig.name,
		offset = padConfig.offset,
		size = padConfig.size,
		color = padConfig.color,
		material = Enum.Material.SmoothPlastic,
		solid = false,
		transparency = padConfig.transparency,
	}, plot.frame, padConfig.color, house)
	pad:SetAttribute(chargerConfig.ownerAttribute, owner.UserId)
	pad:SetAttribute(chargerConfig.plotAttribute, plot.location.id)

	local door = newPart({
		name = doorConfig.name,
		offset = doorConfig.offset,
		size = doorConfig.size,
		color = doorConfig.color,
		material = doorConfig.material,
		solid = true,
	}, plot.frame, doorConfig.color, house)

	local sensor = Instance.new("Part")
	sensor.Name = doorConfig.sensorName
	sensor.Size = doorConfig.sensorSize
	sensor.CFrame = plot.frame * CFrame.new(doorConfig.sensorOffset)
	sensor.Anchored = true
	sensor.Transparency = 1
	sensor.CanCollide = false
	sensor.CanQuery = false -- rays and overlap queries go straight through
	sensor.CanTouch = true
	sensor.CastShadow = false
	sensor.Touched:Connect(function(hit: BasePart)
		onSensorTouched(plot, hit)
	end)
	sensor.Parent = house

	plot.house = house
	plot.pad = pad
	plot.door = door
	plot.sensor = sensor
	plot.doorOpen = false
	decorate(plot, owned)
	house.Parent = plot.model
	-- Tagged once it is in the world, so EnergyService only ever sees a charger with its attributes set.
	CollectionService:AddTag(pad, chargerConfig.tag)
	-- The owner's cars already standing in the sensor (left in the bay last time, say) open the door when driven.
	settleShut(plot)
end

local function clearHouse(plot: Plot)
	stopWatching(plot)
	local timer = plot.doorTimer
	if timer ~= nil then
		task.cancel(timer)
	end
	local tween = plot.doorTween
	if tween ~= nil then
		tween:Cancel()
	end
	local house = plot.house
	plot.house, plot.extras, plot.pad, plot.door, plot.sensor = nil, nil, nil, nil, nil
	plot.doorOpen, plot.doorTween, plot.doorTimer = false, nil, nil
	if house ~= nil then
		house:Destroy()
	end
	setSign(plot, nil)
end

-- Frees the player's plot (if any) and removes its house. Returns the plot id that was freed.
local function releasePlayer(player: Player): string?
	local plotId = HouseService.release(claims, player.UserId)
	local plot = if plotId ~= nil then plots[plotId] else nil
	if plot ~= nil then
		clearHouse(plot)
	end
	return plotId
end

-- Whether the player's character stands within reach of the plot's sign.
local function nearSign(player: Player, location: MapLayout.Location): boolean?
	local character = player.Character
	local root = if character ~= nil then character:FindFirstChild("HumanoidRootPart") else nil
	if root == nil or not root:IsA("BasePart") then
		return nil
	end
	local sign = Houses.signPosition(location.position, location.yaw)
	return (root.Position - sign).Magnitude <= Houses.claimReach
end

-- Whether a car (anyone's: the claimer's own would be trapped too) or another player stands where the house's walls
-- would appear on `plot` (Config/Houses lotClear).
local function lotTaken(plot: Plot, claimer: Player): boolean
	local parts: { Box } = {}
	for _, chassis in carChassis() do
		table.insert(parts, { frame = chassis.CFrame, size = chassis.Size })
	end
	for _, other in Players:GetPlayers() do
		local character = other.Character
		local root = if other ~= claimer and character ~= nil then character:FindFirstChild(ROOT_PART) else nil
		if root ~= nil and root:IsA("BasePart") then
			table.insert(parts, { frame = root.CFrame, size = root.Size })
		end
	end
	return HouseService.lotBlocked(HouseService.lotBoxes(plot.frame), parts)
end

claimPlot = function(player: Player, plotId: string, viaPrompt: boolean): Reply
	local location = plotLocations[plotId]
	local plot = plots[plotId]
	local refusal = HouseService.claimRefusal(claims, player.UserId, plotId, location ~= nil and plot ~= nil)
	if refusal == "noPlot" or location == nil or plot == nil then
		return reply(false, text.noPlot)
	elseif refusal == "yours" then
		return reply(false, text.alreadyYours, plotId)
	elseif refusal == "hasHouse" then
		local held = HouseService.plotOf(claims, player.UserId)
		local heldLocation = if held ~= nil then plotLocations[held] else nil
		local address = if heldLocation ~= nil then heldLocation.displayName else ""
		return reply(false, string.format(text.hasHouse, address), held)
	elseif refusal == "taken" then
		return reply(false, text.taken)
	end

	local dataService = DataService
	if dataService == nil or dataService.get(player) == nil then
		return reply(false, text.loading)
	end
	if not viaPrompt then
		local near = nearSign(player, location)
		if near == nil then
			return reply(false, text.notReady)
		elseif not near then
			return reply(false, text.tooFar)
		end
	end
	if lotTaken(plot, player) then
		return reply(false, text.blocked)
	end

	if not HouseService.claim(claims, player.UserId, plotId) then
		return reply(false, text.taken)
	end
	local ok, err = pcall(buildHouse, plot, player, ownedUpgrades(player))
	if not ok then
		warn(`{LOG} building the house at {plotId} for {player.UserId} failed: {err}`)
		releasePlayer(player)
		return reply(false, text.failed)
	end
	setSign(plot, player)
	local message = string.format(text.claimed, location.displayName)
	sendUpdate(player, message)
	for _, listener in claimedListeners do
		task.spawn(listener, player, plotId)
	end
	return reply(true, message, plotId)
end

-- Remotes --------------------------------------------------------------------------------------------------------

local function onClaim(player: Player, payload: any): Reply
	return claimPlot(player, payload.plotId, false)
end

local function onLeave(player: Player): Reply
	local plotId = releasePlayer(player)
	local location = if plotId ~= nil then plotLocations[plotId] else nil
	if location == nil then
		return reply(false, text.noHouse)
	end
	local message = string.format(text.left, location.displayName)
	sendUpdate(player, message)
	return reply(true, message)
end

local function onBuyUpgrade(player: Player, payload: any): Reply
	local id: string = payload.upgrade
	local upgrade = Houses.upgrade(id)
	local dataService, economyService = DataService, EconomyService
	if upgrade == nil then
		return reply(false, text.unknownUpgrade)
	end
	if dataService == nil or economyService == nil or dataService.get(player) == nil then
		return reply(false, text.loading)
	end
	local cash = economyService.getCash(player)
	local refusal = Houses.buyRefusal(ownedUpgrades(player), id, cash)
	if refusal == "owned" then
		return reply(false, text.owned)
	elseif refusal == "cash" then
		return reply(false, string.format(text.cash, Economy.formatCash(upgrade.price - cash)))
	elseif refusal ~= nil then
		return reply(false, text.unknownUpgrade)
	end
	if not economyService.trySpend(player, upgrade.price, Houses.economyReason) then
		local now = economyService.getCash(player)
		return reply(false, string.format(text.cash, Economy.formatCash(math.max(upgrade.price - now, 0))))
	end
	local saved = dataService.update(player, function(data: Types.PlayerData)
		local house: any = data.house
		if type(house) ~= "table" then
			house = { upgrades = {} }
			data.house = house
		end
		if type(house.upgrades) ~= "table" then
			house.upgrades = {}
		end
		house.upgrades[id] = true
	end)
	if not saved then
		-- Paid but not saved: give the money back rather than lose it.
		economyService.add(player, upgrade.price, Houses.refundReason)
		return reply(false, text.failed)
	end

	local plotId = HouseService.plotOf(claims, player.UserId)
	local plot = if plotId ~= nil then plots[plotId] else nil
	if plot ~= nil then
		decorate(plot, ownedUpgrades(player))
	end
	local message = string.format(if plot ~= nil then text.bought else text.boughtLater, upgrade.name)
	sendUpdate(player, message)
	return reply(true, message, plotId)
end

-- Public API -------------------------------------------------------------------------------------------------------

-- The plot id the player holds on this server, or nil.
function HouseService.getPlot(player: Player): string?
	return HouseService.plotOf(claims, player.UserId)
end

-- Roast fixes (2026-10-24): calls fn(player, plotId) in its own thread whenever a player claims a house.
-- Services/GoalsService counts claims here.
function HouseService.onClaimed(fn: (player: Player, plotId: string) -> ())
	table.insert(claimedListeners, fn)
end

-- Boot -------------------------------------------------------------------------------------------------------------

function HouseService:Init()
	DataService = require(script.Parent.DataService)
	EconomyService = require(script.Parent.EconomyService)
end

function HouseService:Start()
	local existing = Workspace:FindFirstChild(Houses.folderName)
	if existing ~= nil then
		existing:Destroy() -- left from an earlier run in Studio: this server builds its own
	end
	local made = Instance.new("Folder")
	made.Name = Houses.folderName
	made.Parent = Workspace
	for index, plotId in plotOrder do
		local ok, result = pcall(buildPlot, made, plotLocations[plotId], index)
		if ok then
			plots[plotId] = result
		else
			warn(`{LOG} building the sign at {plotId} failed: {result}`)
		end
	end

	Net.onServerInvoke("ClaimHouse", onClaim)
	Net.onServerInvoke("LeaveHouse", onLeave)
	Net.onServerInvoke("BuyHouseUpgrade", onBuyUpgrade)

	Players.PlayerRemoving:Connect(function(player: Player)
		releasePlayer(player)
	end)
	local dataService = DataService
	if dataService ~= nil then
		dataService.onLoaded(function(player: Player)
			sendUpdate(player)
		end)
	end
end

return HouseService
