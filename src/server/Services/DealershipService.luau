--!strict
-- The dealership (PLAN.md Phase 4; docs/phase-4-contracts.md "Commerce"): the display cars on every brand's pads,
-- buying, the Arc Boost style upgrades and 2-minute test drives.
--
-- Display cars: on Start, an anchored copy of every dealership vehicle (its first dealership trim) stands on its
-- brand's pads (Config/MapLayout dealership, cheapest first) in Workspace.Showroom.Dealership, tagged DisplayCar,
-- seats disabled, with a "View" ProximityPrompt carrying VehicleId and Trim (Config/Dealership.prompt). The shop
-- UI opens on that prompt. Display cars are never spawned through VehicleService, so they are never driven,
-- tracked by anti-exploit or paid by drive-to-earn. UsedLotService puts its cars up the same way
-- (placeDisplayCar).
--
-- Featured car (Phase 12): while a running event names one (EventService.featuredVehicleId), its display car gets
-- the spotlight (Config/Dealership display.featured: a Highlight and the Featured attribute), moved whenever
-- EventService says the events changed (applyFeatured).
--
-- Remotes (declared in Net, which has already checked each payload's shape and rate-limited it):
--   BuyVehicle { vehicleId, trim }   function: the trim must exist, be sold at the dealership and not be an
--                                    upgrade; the garage needs a free slot; then the price is charged
--                                    (EconomyService.trySpend), the car added (GarageService.addVehicle, refunded
--                                    if that fails) and brought out at the nearest spawn pad. Answers
--                                    { ok, message, uid? }.
--   UpgradeVehicle { uid, trim }     function: for an upgrade trim (upgradeFrom): the player must own that car in
--                                    the trim it upgrades; the upgrade price is charged and the car's trim changed
--                                    (paid += upgrade). Answers { ok, message }.
--   StartTestDrive { vehicleId, trim } function: only within testDrive.maxStartDistance of that car's display
--                                    car; a temporary car (attribute TestDrive = true) at the spawn pad nearest
--                                    the dealership with the player seated, for Config/Dealership testDrive.seconds;
--                                    then it is removed and the player stood back at the dealership with a notice.
--                                    One at a time, with a cooldown after each. Test-drive cars never earn
--                                    (DriveEarnService skips them) and never take a garage slot. Answers
--                                    { ok, message, seconds? }.
--   DevSetCash { amount }            function, Studio only: sets the caller's cash to exactly `amount` through
--                                    EconomyService (adds or spends the difference), for Dev/ShopTests. Answers
--                                    { ok, message, cash }.
-- Every refusal is logged with the player and the reason, so a forged purchase shows up in the output.
--
-- Server-authoritative (CLAUDE.md hard rule 1): the client names a car; the server looks up its price in the
-- catalog and checks the player's own cash and garage. The rules are pure functions (decideBuy, decideUpgrade,
-- lineups, displayTrim) so tests/Dealership.spec checks them in Edit mode. No polling: everything runs on remote
-- calls, one task.delay per test drive and seat events (plus one Heartbeat only if display cars turn).

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local Catalog = require(Shared.Vehicle.Catalog)
local Dealership = require(Shared.Config.Dealership)
local Economy = require(Shared.Config.Economy)
local Garage = require(Shared.Config.Garage)
local MapLayout = require(Shared.Config.MapLayout)
local Net = require(Shared.Net)
local Spawning = require(Shared.Config.Spawning)
local Types = require(Shared.Types)
local EconomyService = require(script.Parent.EconomyService)

-- DataService, GarageService and VehicleService are required in Init rather than here: DataService loads
-- ProfileStore, which talks to DataStores straight away, and tests/Dealership.spec requires this module in Edit
-- mode for its pure rules.
type DataServiceModule = typeof(require(script.Parent.DataService))
type GarageServiceModule = typeof(require(script.Parent.GarageService))
type VehicleServiceModule = typeof(require(script.Parent.VehicleService))

-- Why a purchase or upgrade is refused (each has a message in Config/Dealership.messages, noCash a formatted one).
export type RejectReason =
	"unknownVehicle"
	| "notDrivable"
	| "unknownTrim"
	| "notForSale"
	| "upgradeTrim"
	| "noRoom"
	| "noCash"
	| "notOwned"
	| "notUpgrade"
	| "wrongBase"

-- A pure decision: ok with the price and the cash left after paying it, or a reason. `price` is 0 when the trim
-- has no price; `balanceAfter` is cash - price whenever a price is known (negative when short).
export type Decision = { ok: boolean, reason: RejectReason?, price: number, balanceAfter: number }

-- One car on a brand's pads: the trim on show and its price.
export type LineupEntry = { vehicleId: string, trim: string, price: number }

-- The fields of an owned car the upgrade rule reads.
export type OwnedRef = { vehicleId: string, trim: string }

-- What the function remotes answer.
export type Reply = { ok: boolean, message: string, uid: string?, seconds: number?, cash: number? }

-- placeDisplayCar's options.
export type DisplayOptions = {
	vehicleId: string,
	trim: string,
	pad: CFrame, -- the pad's footprint centre on the ground (Config/MapLayout)
	padHeight: number, -- the platform's height: the car stands on top of it
	parent: Instance,
	name: string,
	attributes: { [string]: any }, -- set on the model and on its View prompt
	objectText: string, -- the prompt's object line
}

type TestDrive = {
	model: Model,
	thread: thread?,
	connections: { RBXScriptConnection },
}

type Spinner = { model: Model, base: CFrame }

local LOG = "[DealershipService]"
local SEATS_FOLDER = "Seats" -- vehicle model contract
local DRIVER_SEAT = "Driver"
local SECONDS_PER_MINUTE = 60

local messages = Dealership.messages

local DealershipService = {}

local DataService: DataServiceModule? = nil
local GarageService: GarageServiceModule? = nil
local VehicleService: VehicleServiceModule? = nil

local testDrives: { [Player]: TestDrive } = {}
local testDriveEnded: { [Player]: number } = {} -- os.clock() when each player's last test drive ended
local spinners: { Spinner } = {} -- display cars that turn (only while rotation is on)
local missingTemplates: { [string]: boolean } = {} -- warned once each

-- Pure rules ------------------------------------------------------------------------------------------------

local function isDealershipTrim(trim: any): boolean
	return trim.acquisition == "dealership" and trim.upgradeFrom == nil and trim.price ~= nil and trim.price > 0
end

-- The trim a vehicle shows on its pad: its first trim sold at the dealership that isn't an upgrade, or nil when
-- the dealership doesn't sell it.
function DealershipService.displayTrim(vehicleId: string): string?
	local vehicle = Catalog.getVehicle(vehicleId)
	if vehicle == nil or not vehicle.playerDrivable then
		return nil
	end
	for _, trim in vehicle.trims do
		if isDealershipTrim(trim) then
			return trim.id
		end
	end
	return nil
end

-- Every brand's dealership cars in pad order: cheapest first (by the trim on show), then by vehicle id.
function DealershipService.lineups(): { [string]: { LineupEntry } }
	local byBrand: { [string]: { LineupEntry } } = {}
	for _, vehicleId in Catalog.vehicleIds() do
		local trimId = DealershipService.displayTrim(vehicleId)
		local vehicle = Catalog.getVehicle(vehicleId)
		if trimId == nil or vehicle == nil then
			continue
		end
		local list = byBrand[vehicle.brandId]
		if list == nil then
			list = {}
			byBrand[vehicle.brandId] = list
		end
		table.insert(list, { vehicleId = vehicleId, trim = trimId, price = Catalog.totalPrice(vehicleId, trimId) or 0 })
	end
	for _, list in byBrand do
		table.sort(list, function(a: LineupEntry, b: LineupEntry): boolean
			if a.price ~= b.price then
				return a.price < b.price
			end
			return a.vehicleId < b.vehicleId
		end)
	end
	return byBrand
end

local function decision(ok: boolean, reason: RejectReason?, price: number, cash: number): Decision
	return { ok = ok, reason = reason, price = price, balanceAfter = cash - price }
end

-- Buying `trimId` of `vehicleId` with `cash` in the wallet; `hasRoom` is whether the garage has a free slot.
-- Checks, in order: the vehicle exists and can be driven, the trim exists, the dealership sells it, it isn't an
-- upgrade, the garage has room, and the cash covers the full price.
function DealershipService.decideBuy(vehicleId: string, trimId: string, cash: number, hasRoom: boolean): Decision
	local vehicle = Catalog.getVehicle(vehicleId)
	if vehicle == nil then
		return decision(false, "unknownVehicle", 0, cash)
	end
	if not vehicle.playerDrivable then
		return decision(false, "notDrivable", 0, cash)
	end
	local trim = Catalog.getTrim(vehicleId, trimId)
	if trim == nil then
		return decision(false, "unknownTrim", 0, cash)
	end
	if trim.acquisition ~= "dealership" then
		return decision(false, "notForSale", 0, cash)
	end
	if trim.upgradeFrom ~= nil then
		return decision(false, "upgradeTrim", 0, cash)
	end
	local price = Catalog.totalPrice(vehicleId, trimId)
	if price == nil or price <= 0 then
		return decision(false, "notForSale", 0, cash)
	end
	if not hasRoom then
		return decision(false, "noRoom", price, cash)
	end
	if cash < price then
		return decision(false, "noCash", price, cash)
	end
	return decision(true, nil, price, cash)
end

-- Upgrading an owned car (`owned`, nil when the player doesn't own it) to `trimId` with `cash`. The target must
-- be an upgrade trim sold at the dealership, the car must be in exactly the trim it upgrades, and the cash must
-- cover the upgrade's own price (Config/Vehicles: an upgrade trim's price is the cost on top of its base).
function DealershipService.decideUpgrade(owned: OwnedRef?, trimId: string, cash: number): Decision
	if owned == nil then
		return decision(false, "notOwned", 0, cash)
	end
	local trim = Catalog.getTrim(owned.vehicleId, trimId)
	if trim == nil then
		return decision(false, "unknownTrim", 0, cash)
	end
	if trim.upgradeFrom == nil then
		return decision(false, "notUpgrade", 0, cash)
	end
	local price = trim.price
	if trim.acquisition ~= "dealership" or price == nil or price <= 0 then
		return decision(false, "notForSale", 0, cash)
	end
	if owned.trim ~= trim.upgradeFrom then
		return decision(false, "wrongBase", price, cash)
	end
	if cash < price then
		return decision(false, "noCash", price, cash)
	end
	return decision(true, nil, price, cash)
end

-- "2 minutes" / "1 minute" / "90 seconds" for a test drive's length.
function DealershipService.durationText(seconds: number): string
	if seconds % SECONDS_PER_MINUTE == 0 then
		local minutes = seconds // SECONDS_PER_MINUTE
		return `{minutes} {if minutes == 1 then messages.minute else messages.minutes}`
	end
	return `{seconds} {messages.seconds}`
end

-- Helpers ---------------------------------------------------------------------------------------------------

local function reply(ok: boolean, message: string): Reply
	return { ok = ok, message = message }
end

local function notify(player: Player, text: string, kind: string)
	Net.fireClient("Notify", player, { text = text, kind = kind })
end

local function logRejection(player: Player, action: string, reason: string, detail: string)
	warn(`{LOG} {action} refused for {player.Name} ({player.UserId}): {reason} ({detail})`)
end

-- A trim's name for messages ("Spark Long Range"), or the vehicle's, or the id.
local function trimName(vehicleId: string, trimId: string): string
	local trim = Catalog.getTrim(vehicleId, trimId)
	if trim ~= nil then
		return trim.displayName
	end
	local vehicle = Catalog.getVehicle(vehicleId)
	return if vehicle ~= nil then vehicle.displayName else vehicleId
end

-- What the player is told for a refusal of `trimId` of `vehicleId`.
local function refusalMessage(result: Decision, vehicleId: string, trimId: string): string
	local reason = result.reason
	if reason == "noCash" then
		return string.format(messages.noCash, Economy.formatCash(-result.balanceAfter)) -- the amount short
	elseif reason == "wrongBase" then
		local trim = Catalog.getTrim(vehicleId, trimId)
		local base = if trim ~= nil and trim.upgradeFrom ~= nil
			then trimName(vehicleId, trim.upgradeFrom)
			else vehicleId
		return string.format(messages.wrongBase, base)
	elseif reason ~= nil then
		local text = (messages :: any)[reason]
		if type(text) == "string" then
			return text
		end
	end
	return messages.buyFailed
end

local function rootPart(player: Player): BasePart?
	local character = player.Character
	local root = if character then character:FindFirstChild("HumanoidRootPart") else nil
	return if root ~= nil and root:IsA("BasePart") then root else nil
end

local function flatDistance(a: Vector3, b: Vector3): number
	return Vector3.new(a.X - b.X, 0, a.Z - b.Z).Magnitude
end

-- The free SpawnPad nearest `position` (a pad is taken while another player's car stands on it), else the
-- nearest; nil with no pads on the map.
local function nearestSpawnPad(player: Player, position: Vector3): BasePart?
	local pads: { BasePart } = {}
	for _, instance in CollectionService:GetTagged(Garage.spawnPadTag) do
		if instance:IsA("BasePart") and instance:IsDescendantOf(Workspace) then
			table.insert(pads, instance)
		end
	end
	table.sort(pads, function(a: BasePart, b: BasePart): boolean
		return flatDistance(a.Position, position) < flatDistance(b.Position, position)
	end)
	local vehicles = Workspace:FindFirstChild(Spawning.vehiclesFolder)
	for _, pad in pads do
		local taken = false
		if vehicles ~= nil then
			for _, car in vehicles:GetChildren() do
				if
					car:IsA("Model")
					and car:GetAttribute("OwnerUserId") ~= player.UserId
					and flatDistance(car:GetPivot().Position, pad.Position) <= Garage.padClearRadius
				then
					taken = true
					break
				end
			end
		end
		if not taken then
			return pad
		end
	end
	return pads[1]
end

-- Display cars ----------------------------------------------------------------------------------------------

local function childFolder(parent: Instance, name: string): Folder
	local existing = parent:FindFirstChild(name)
	if existing ~= nil and existing:IsA("Folder") then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = name
	folder.Parent = parent
	return folder
end

-- Workspace.Showroom.<name>, made if missing.
function DealershipService.showroomFolder(name: string): Folder
	return childFolder(childFolder(Workspace, Dealership.display.folderName), name)
end

-- Puts an anchored, undrivable copy of a trim's model on a pad with a "View" prompt. Returns the model, or nil
-- (warning once per model) when ServerStorage.VehicleModels has no model for the trim.
function DealershipService.placeDisplayCar(options: DisplayOptions): Model?
	local modelName = Catalog.modelName(options.vehicleId, options.trim)
	local models = ServerStorage:FindFirstChild(Spawning.modelsFolder)
	local template = if models then models:FindFirstChild(modelName) else nil
	if template == nil or not template:IsA("Model") or template.PrimaryPart == nil then
		if not missingTemplates[modelName] then
			missingTemplates[modelName] = true
			warn(
				`{LOG} No car model "{modelName}" in ServerStorage.{Spawning.modelsFolder} for a display pad. In Edit mode, run require(game.ServerScriptService.Server.Dev.VehicleBuilder).buildAll()`
			)
		end
		return nil
	end
	local model = template:Clone()
	model.Name = options.name
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Anchored = true
			descendant.CanTouch = false
			if descendant:IsA("Seat") then
				descendant.Disabled = true
			end
		end
	end
	model:AddTag(Dealership.display.tag)
	for key, value in options.attributes do
		model:SetAttribute(key, value)
	end
	-- The model pivot is the ground point under the chassis (vehicle model contract): on top of the platform.
	local base = options.pad * CFrame.new(0, options.padHeight, 0)
	model:PivotTo(base)

	local settings = Dealership.prompt
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = settings.name
	prompt.ActionText = settings.actionText
	prompt.ObjectText = options.objectText
	prompt.HoldDuration = settings.holdSeconds
	prompt.MaxActivationDistance = settings.maxDistance
	prompt.RequiresLineOfSight = false -- the prompt sits inside the car body
	for key, value in options.attributes do
		prompt:SetAttribute(key, value)
	end
	prompt.Parent = model.PrimaryPart
	model.Parent = options.parent
	if Dealership.display.rotationDegreesPerSecond ~= 0 then
		table.insert(spinners, { model = model, base = base })
	end
	return model
end

-- Every dealership vehicle on its brand's pads, cheapest first. Vehicles beyond a section's pads, and brands
-- with no section, are reported (tests/Dealership.spec keeps the layout big enough).
local function buildDisplays()
	local folder = DealershipService.showroomFolder(Dealership.display.dealershipFolderName)
	folder:ClearAllChildren()
	local lineups = DealershipService.lineups()
	local layout = MapLayout.dealership
	local placed: { [string]: boolean } = {}
	local count = 0
	for _, section in layout.sections do
		placed[section.brandId] = true
		local lineup: { LineupEntry } = lineups[section.brandId] or {}
		for index, entry in lineup do
			if index > #section.pads then
				warn(`{LOG} No pad left in the {section.brandId} section for {entry.vehicleId}`)
				continue
			end
			local pad = section.pads[index]
			local vehicle = Catalog.getVehicle(entry.vehicleId)
			local attributes = {
				[Dealership.prompt.vehicleIdAttribute] = entry.vehicleId,
				[Dealership.prompt.trimAttribute] = entry.trim,
			}
			local model = DealershipService.placeDisplayCar({
				vehicleId = entry.vehicleId,
				trim = entry.trim,
				pad = pad,
				padHeight = layout.padSize.Y,
				parent = folder,
				name = `{section.brandId}_{index}`,
				attributes = attributes,
				objectText = if vehicle then vehicle.displayName else entry.vehicleId,
			})
			if model ~= nil then
				count += 1
			end
		end
	end
	for brandId in lineups do
		if not placed[brandId] then
			warn(`{LOG} Brand "{brandId}" has no section in Config/MapLayout dealership`)
		end
	end
	print(`{LOG} {count} display cars on the dealership pads`)
end

-- The event spotlight (Config/Dealership display.featured): the display car of `vehicleId` (nil: none) gets the
-- outline and the Featured attribute; every other display car loses them. Safe to call again with the same id.
function DealershipService.applyFeatured(vehicleId: string?)
	local featured = Dealership.display.featured
	local folder = DealershipService.showroomFolder(Dealership.display.dealershipFolderName)
	local rgb = featured.rgb
	local color = Color3.fromRGB(rgb[1], rgb[2], rgb[3])
	for _, model in folder:GetChildren() do
		if not model:IsA("Model") then
			continue
		end
		local on = vehicleId ~= nil and model:GetAttribute(Dealership.prompt.vehicleIdAttribute) == vehicleId
		local existing = model:FindFirstChild(featured.highlightName)
		if on and existing == nil then
			local highlight = Instance.new("Highlight")
			highlight.Name = featured.highlightName
			highlight.OutlineColor = color
			highlight.FillColor = color
			highlight.FillTransparency = featured.fillTransparency
			highlight.DepthMode = Enum.HighlightDepthMode.Occluded
			highlight.Parent = model
		elseif not on and existing ~= nil then
			existing:Destroy()
		end
		model:SetAttribute(featured.attribute, if on then true else nil)
	end
end

-- Follows EventService (Phase 12): spotlights the featured car now and whenever the events change.
local function followFeatured()
	local module = script.Parent:FindFirstChild("EventService")
	if module == nil or not module:IsA("ModuleScript") then
		return
	end
	local ok, events = pcall(require :: any, module)
	if not ok or type(events) ~= "table" or type(events.featuredVehicleId) ~= "function" then
		return
	end
	local function refresh()
		local found, vehicleId = pcall(events.featuredVehicleId)
		DealershipService.applyFeatured(if found and type(vehicleId) == "string" then vehicleId else nil)
	end
	refresh()
	if type(events.onChanged) == "function" then
		events.onChanged(function(_payload: any)
			refresh()
		end)
	end
end

-- Turns every display car on its pad (only when Config/Dealership display.rotationDegreesPerSecond isn't 0).
local function startTurning()
	local display = Dealership.display
	local step = 1 / display.rotationStepsPerSecond
	local since, angle = 0, 0
	RunService.Heartbeat:Connect(function(dt: number)
		since += dt
		if since < step then
			return
		end
		angle = (angle + display.rotationDegreesPerSecond * since) % 360
		since = 0
		local turn = CFrame.Angles(0, math.rad(angle), 0)
		for i = #spinners, 1, -1 do
			local spinner = spinners[i]
			if spinner.model.Parent == nil then
				table.remove(spinners, i)
			else
				spinner.model:PivotTo(spinner.base * turn)
			end
		end
	end)
end

-- Test drives -------------------------------------------------------------------------------------------------

-- Where a finished test drive leaves the player: the Dealership location (Config/MapLayout).
local function dealershipSpot(): CFrame?
	for _, location in MapLayout.locations do
		if location.tag == "Dealership" then
			local position = location.position + Vector3.yAxis * Dealership.testDrive.returnHeight
			return CFrame.new(position) * CFrame.Angles(0, math.rad(location.yaw), 0)
		end
	end
	return nil
end

-- True when a dealership display car of `vehicleId` stands within Config/Dealership testDrive.maxStartDistance
-- of `position`.
local function nearDisplayCar(position: Vector3, vehicleId: string): boolean
	local showroom = Workspace:FindFirstChild(Dealership.display.folderName)
	local folder = if showroom then showroom:FindFirstChild(Dealership.display.dealershipFolderName) else nil
	if folder == nil then
		return false
	end
	local limit = Dealership.testDrive.maxStartDistance
	for _, car in folder:GetChildren() do
		if
			car:IsA("Model")
			and car:GetAttribute(Dealership.prompt.vehicleIdAttribute) == vehicleId
			and (car:GetPivot().Position - position).Magnitude <= limit
		then
			return true
		end
	end
	return false
end

-- Ends the player's test drive, if they're on one: the car goes, and with `sendBack` the player is stood at the
-- dealership and told. The cooldown starts now.
function DealershipService.endTestDrive(player: Player, sendBack: boolean)
	local drive = testDrives[player]
	if drive == nil then
		return
	end
	testDrives[player] = nil
	testDriveEnded[player] = os.clock()
	local thread = drive.thread
	drive.thread = nil
	if thread ~= nil and thread ~= coroutine.running() then
		task.cancel(thread)
	end
	for _, connection in drive.connections do
		connection:Disconnect()
	end
	local vehicleService = VehicleService
	if vehicleService ~= nil and vehicleService.getCar(player) == drive.model then
		vehicleService.despawn(player)
	elseif drive.model.Parent ~= nil then
		drive.model:Destroy()
	end
	if sendBack and player.Parent ~= nil then
		local spot = dealershipSpot()
		local character = player.Character
		if spot ~= nil and character ~= nil and rootPart(player) ~= nil then
			character:PivotTo(spot)
		end
		notify(player, messages.testDriveEnded, "info")
	end
end

-- True while the player is on a test drive.
function DealershipService.onTestDrive(player: Player): boolean
	return testDrives[player] ~= nil
end

-- Ends the test drive when the player gets out of the car (after they have sat in it at least once).
local function watchDriverSeat(player: Player, drive: TestDrive)
	local seats = drive.model:FindFirstChild(SEATS_FOLDER)
	local seat = if seats then seats:FindFirstChild(DRIVER_SEAT) else nil
	if seat == nil or not seat:IsA("Seat") then
		return
	end
	local seated = false
	table.insert(
		drive.connections,
		seat:GetPropertyChangedSignal("Occupant"):Connect(function()
			if seat.Occupant ~= nil then
				seated = true
			elseif seated then
				-- After VehicleService has parked the car and stood the player beside it.
				task.defer(function()
					if testDrives[player] == drive then
						DealershipService.endTestDrive(player, true)
					end
				end)
			end
		end)
	)
end

local function onStartTestDrive(player: Player, payload: any): Reply
	local vehicleId: string, trimId: string = payload.vehicleId, payload.trim
	local vehicleService = VehicleService
	if vehicleService == nil then
		return reply(false, messages.testDriveFailed)
	end
	local vehicle = Catalog.getVehicle(vehicleId)
	local trim = Catalog.getTrim(vehicleId, trimId)
	local refusal: RejectReason? = nil
	if vehicle == nil then
		refusal = "unknownVehicle"
	elseif not vehicle.playerDrivable then
		refusal = "notDrivable"
	elseif trim == nil then
		refusal = "unknownTrim"
	elseif trim.acquisition ~= "dealership" then
		refusal = "notForSale"
	end
	if refusal ~= nil then
		logRejection(player, "StartTestDrive", refusal, `{vehicleId}/{trimId}`)
		return reply(false, (messages :: any)[refusal])
	end
	if testDrives[player] ~= nil then
		return reply(false, messages.testDriveBusy)
	end
	local settings = Dealership.testDrive
	local ended = testDriveEnded[player]
	if ended ~= nil and os.clock() - ended < settings.cooldownSeconds then
		local secondsLeft = math.ceil(settings.cooldownSeconds - (os.clock() - ended))
		return reply(false, string.format(messages.testDriveCooldown, secondsLeft))
	end
	local root = rootPart(player)
	if root == nil then
		return reply(false, messages.noCharacter)
	end
	-- Only from the showroom floor: the player must stand by that car's display car.
	if not nearDisplayCar(root.Position, vehicleId) then
		logRejection(player, "StartTestDrive", "tooFar", `{vehicleId}/{trimId} at {root.Position}`)
		return reply(false, messages.testDriveTooFar)
	end

	-- The spawn pad by the dealership, not the one nearest the player.
	local spot = dealershipSpot()
	local pad = nearestSpawnPad(player, if spot ~= nil then spot.Position else root.Position)
	-- Replaces any car the player had out (Config/Spawning.maxCarsPerPlayer); with no pads, in front of them.
	local model = vehicleService.spawn(player, vehicleId, trimId, if pad then pad.CFrame else nil)
	if model == nil then
		return reply(false, messages.testDriveFailed)
	end
	model:SetAttribute(Garage.testDriveAttribute, true)
	local drive: TestDrive = { model = model, thread = nil, connections = {} }
	testDrives[player] = drive
	-- The car can go some other way (fell out of the world, the player spawned another): forget the drive.
	table.insert(
		drive.connections,
		model.AncestryChanged:Connect(function()
			if not model:IsDescendantOf(Workspace) and testDrives[player] == drive then
				DealershipService.endTestDrive(player, false)
			end
		end)
	)
	if settings.endOnExit then
		watchDriverSeat(player, drive)
	end
	drive.thread = task.delay(settings.seconds, function()
		drive.thread = nil
		if testDrives[player] == drive then
			DealershipService.endTestDrive(player, true)
		end
	end)
	vehicleService.seatDriverWhenFree(player) -- spawning replaced any car they sat in
	local length = DealershipService.durationText(settings.seconds)
	print(`{LOG} {player.Name} started a test drive in {vehicleId}/{trimId}`)
	return { ok = true, message = string.format(messages.testDriveStarted, length), seconds = settings.seconds }
end

-- Buying and upgrading ----------------------------------------------------------------------------------------

local function onBuy(player: Player, payload: any): Reply
	local vehicleId: string, trimId: string = payload.vehicleId, payload.trim
	local dataService, garage = DataService, GarageService
	if dataService == nil or garage == nil or dataService.get(player) == nil then
		logRejection(player, "BuyVehicle", "notLoaded", `{vehicleId}/{trimId}`)
		return reply(false, messages.notLoaded)
	end
	local cash = EconomyService.getCash(player)
	local result = DealershipService.decideBuy(vehicleId, trimId, cash, garage.hasRoom(player))
	if not result.ok then
		logRejection(
			player,
			"BuyVehicle",
			result.reason or "refused",
			`{vehicleId}/{trimId}, cash {cash}, price {result.price}`
		)
		return reply(false, refusalMessage(result, vehicleId, trimId))
	end
	-- Charge first; trySpend re-checks the balance inside the data update, so two buys at once can't both pass.
	if not EconomyService.trySpend(player, result.price, Dealership.reasons.buy) then
		local now = EconomyService.getCash(player)
		logRejection(player, "BuyVehicle", "noCash", `{vehicleId}/{trimId}: charge refused, cash {now}`)
		return reply(false, string.format(messages.noCash, Economy.formatCash(math.max(result.price - now, 0))))
	end
	local uid = garage.addVehicle(player, vehicleId, trimId, result.price)
	if uid == nil then
		EconomyService.add(player, result.price, Dealership.reasons.refund)
		logRejection(player, "BuyVehicle", "addFailed", `{vehicleId}/{trimId}: refunded {result.price}`)
		return reply(false, messages.buyFailed)
	end
	print(`{LOG} {player.Name} ({player.UserId}) bought {vehicleId}/{trimId} for {result.price}`)
	-- Bring it out at the nearest spawn pad. A test drive in progress ends first (the garage won't spawn over it).
	DealershipService.endTestDrive(player, false)
	local spawned = garage.spawnOwned(player, uid)
	local name = trimName(vehicleId, trimId)
	local text = if spawned.ok then messages.bought else messages.boughtInGarage
	return { ok = true, message = string.format(text, name), uid = uid }
end

local function onUpgrade(player: Player, payload: any): Reply
	local uid: string, trimId: string = payload.uid, payload.trim
	local dataService, garage, vehicleService = DataService, GarageService, VehicleService
	local data = if dataService ~= nil then dataService.get(player) else nil
	if dataService == nil or garage == nil or vehicleService == nil or data == nil then
		logRejection(player, "UpgradeVehicle", "notLoaded", uid)
		return reply(false, messages.notLoaded)
	end
	local findVehicle = garage.findVehicle -- skips non-table entries a migration left alone
	local owned = findVehicle(data, uid)
	local ref: OwnedRef? = if owned then { vehicleId = owned.vehicleId, trim = owned.trim } else nil
	local cash = EconomyService.getCash(player)
	local result = DealershipService.decideUpgrade(ref, trimId, cash)
	local vehicleId = if owned then owned.vehicleId else "?"
	if not result.ok then
		logRejection(
			player,
			"UpgradeVehicle",
			result.reason or "refused",
			`{uid} ({vehicleId}) to {trimId}, cash {cash}, price {result.price}`
		)
		return reply(false, refusalMessage(result, vehicleId, trimId))
	end
	local target = Catalog.getTrim(vehicleId, trimId) :: any -- decideUpgrade checked it exists
	if not EconomyService.trySpend(player, result.price, Dealership.reasons.upgrade) then
		local now = EconomyService.getCash(player)
		logRejection(player, "UpgradeVehicle", "noCash", `{uid} to {trimId}: charge refused, cash {now}`)
		return reply(false, string.format(messages.noCash, Economy.formatCash(math.max(result.price - now, 0))))
	end
	-- Change the trim inside one update that re-checks the car is still there in the trim it upgrades.
	local changed = false
	local updated = dataService.update(player, function(fresh: Types.PlayerData)
		local vehicle = findVehicle(fresh, uid)
		if vehicle == nil or vehicle.trim ~= target.upgradeFrom then
			return
		end
		local paid = if type(vehicle.paid) == "number" and vehicle.paid == vehicle.paid then vehicle.paid else 0
		vehicle.trim = trimId
		vehicle.paid = math.max(math.floor(paid), 0) + result.price
		changed = true
	end)
	if not updated or not changed then
		EconomyService.add(player, result.price, Dealership.reasons.refund)
		logRejection(player, "UpgradeVehicle", "changeFailed", `{uid} to {trimId}: refunded {result.price}`)
		return reply(false, messages.upgradeFailed)
	end
	print(`{LOG} {player.Name} ({player.UserId}) upgraded {uid} ({vehicleId}) to {trimId} for {result.price}`)
	-- If that car is out, bring the upgraded one out in its place.
	local car = vehicleService.getCar(player)
	if car ~= nil and car:GetAttribute(Garage.ownedUidAttribute) == uid then
		garage.spawnOwned(player, uid)
	end
	return reply(true, string.format(messages.upgraded, trimName(vehicleId, trimId)))
end

-- Studio only: sets the caller's cash to exactly `amount` (Dev/ShopTests).
local function onDevSetCash(player: Player, payload: any): Reply
	if not RunService:IsStudio() then
		logRejection(player, "DevSetCash", "notStudio", "dev remote called outside Studio")
		return reply(false, messages.devOnly)
	end
	local amount: number = payload.amount
	local current = EconomyService.getCash(player)
	if amount > current then
		EconomyService.devGrant(player, amount - current)
	elseif amount < current then
		EconomyService.trySpend(player, current - amount, Dealership.reasons.dev)
	end
	local cash = EconomyService.getCash(player)
	local ok = cash == amount
	local text = if ok
		then string.format(messages.devCashSet, Economy.formatCash(cash))
		else string.format(messages.devCashFailed, Economy.formatCash(amount), Economy.formatCash(cash))
	return { ok = ok, message = text, cash = cash }
end

-- Boot ------------------------------------------------------------------------------------------------------

function DealershipService:Init()
	DataService = require(script.Parent.DataService)
	GarageService = require(script.Parent.GarageService)
	VehicleService = require(script.Parent.VehicleService)
end

function DealershipService:Start()
	Net.onServerInvoke("BuyVehicle", onBuy)
	Net.onServerInvoke("UpgradeVehicle", onUpgrade)
	Net.onServerInvoke("StartTestDrive", onStartTestDrive)
	-- Always listen, so the remote never queues up; the handler itself refuses outside Studio.
	Net.onServerInvoke("DevSetCash", onDevSetCash)
	Players.PlayerRemoving:Connect(function(leaving: Player)
		DealershipService.endTestDrive(leaving, false)
		testDriveEnded[leaving] = nil
	end)
	buildDisplays()
	if Dealership.display.rotationDegreesPerSecond ~= 0 then
		startTurning()
	end
	followFeatured()
end

return DealershipService
