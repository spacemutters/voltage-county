--!strict
-- The garage: the cars a player owns, bringing them out, putting them away, favorites, selling back and the
-- player's settings (PLAN.md Phase 4; docs/phase-4-contracts.md "GarageService").
--
-- Remotes (all declared in Net, which has already checked each payload's shape and rate-limited it):
--   SpawnOwned { uid }            function: brings that owned car out at the SpawnPad nearest the player
--                                 (replacing any car they had out), marks it with the OwnedUid attribute and
--                                 seats them. Answers { ok, message }.
--   DespawnOwned                  function: puts away the car they have out. Answers { ok, message }.
--   SetFavorite { uid, favorite } event: stars or unstars a car (favorites sort first on the phone).
--   SellVehicle { uid }           function: sells the car back for Config/Garage.sellBackRate of what was paid,
--                                 putting it away first if it's out. Answers { ok, message }.
--   UpdateSettings { units?, camera?, musicVolume? }  event: stores the values that are valid, ignores the rest.
--
-- For the dealership and the used lot:
--   GarageService.hasRoom(player)                          true while the garage has a free slot
--   GarageService.addVehicle(player, vehicleId, trim, paid) adds a car (default look) and returns its uid, or nil
--   GarageService.spawnOwned(player, uid)                  what SpawnOwned does, for server code that just
--                                                          handed the player a car
--
-- Energy (Phase 5, docs/phase-5-contracts.md "Server"): a car brought out carries its saved charge or tank level
-- (OwnedVehicle.energy) for EnergyService, and putting cars away (or replacing them) first has EnergyService write
-- their current level back to the save, so the car comes out again exactly as it went in.
--
-- Server-authoritative (CLAUDE.md hard rule 1): a client only ever names a uid, and the server looks it up in that
-- player's own data and nowhere else. A sale removes the car and pays for it inside one DataService.update, which
-- re-checks that the car is still there, so a double click (or a forged burst) can never sell a car twice. No
-- polling: everything here runs on remote calls.
--
-- The rules are exported as pure helpers (findVehicle, sellCheck, sellPrice, roomIn, cleanSettings,
-- sortVehicles) so tests/Garage.spec can check them in Edit mode.

local CollectionService = game:GetService("CollectionService")
local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Catalog = require(ReplicatedStorage.Shared.Vehicle.Catalog)
local Data = require(ReplicatedStorage.Shared.Config.Data)
local Economy = require(ReplicatedStorage.Shared.Config.Economy)
local Garage = require(ReplicatedStorage.Shared.Config.Garage)
local Net = require(ReplicatedStorage.Shared.Net)
local Spawning = require(ReplicatedStorage.Shared.Config.Spawning)
local Types = require(ReplicatedStorage.Shared.Types)
local EconomyService = require(script.Parent.EconomyService)
local Template = require(script.Parent.DataService.Template)

-- DataService and VehicleService are required in Init rather than here: DataService loads ProfileStore, which
-- talks to DataStores straight away, and tests/Garage.spec requires this module in Edit mode for its pure
-- helpers.
type DataServiceModule = typeof(require(script.Parent.DataService))
type VehicleServiceModule = typeof(require(script.Parent.VehicleService))
type EnergyServiceModule = typeof(require(script.Parent.EnergyService))

-- What the function remotes answer.
export type Reply = { ok: boolean, message: string }

local LOG = "[GarageService]"
local OWNER_ATTRIBUTE = "OwnerUserId" -- set on every spawned car by VehicleService

local messages = Garage.messages

local GarageService = {}

local DataService: DataServiceModule? = nil
local VehicleService: VehicleServiceModule? = nil
local EnergyService: EnergyServiceModule? = nil

-- Pure helpers ----------------------------------------------------------------------------------------------

GarageService.sellPrice = Garage.sellPrice
GarageService.sortVehicles = Garage.sortVehicles

local function isFinite(value: number): boolean
	return value == value and value ~= math.huge and value ~= -math.huge
end

-- The car with `uid` in a player's data and its index, or nil. Only ever looks in the data it is given.
function GarageService.findVehicle(data: Types.PlayerData, uid: string): (Types.OwnedVehicle?, number?)
	local vehicles = data.vehicles
	if type(vehicles) ~= "table" then
		return nil, nil
	end
	for index, vehicle in vehicles do
		if type(vehicle) == "table" and vehicle.uid == uid then
			return vehicle, index
		end
	end
	return nil, nil
end

-- True for a player design, which lives in its own slots and isn't sold back here.
local function isCustom(vehicle: Types.OwnedVehicle): boolean
	return vehicle.vehicleId == Garage.customVehicleId
end

-- True for the free starter car (a trim handed out by the starter claim, Config/Vehicles acquisition "starter").
function GarageService.isStarter(vehicle: Types.OwnedVehicle): boolean
	if type(vehicle.vehicleId) ~= "string" or type(vehicle.trim) ~= "string" then
		return false
	end
	local trim = Catalog.getTrim(vehicle.vehicleId, vehicle.trim)
	return trim ~= nil and trim.acquisition == "starter"
end

-- Whether a car may be sold back, and if not, what to tell the player. The free starter stays, designs aren't
-- sold here, and a car that would sell for $0 (nothing was paid for it) can't be sold either.
function GarageService.sellCheck(vehicle: Types.OwnedVehicle): (boolean, string?)
	if GarageService.isStarter(vehicle) then
		return false, messages.starterKept
	end
	if isCustom(vehicle) then
		return false, messages.customKept
	end
	if Garage.sellPrice(vehicle.paid) < 1 then
		return false, messages.noValue
	end
	return true, nil
end

-- How many garage slots the player's cars take (designs use customSlots instead).
function GarageService.slotsUsed(data: Types.PlayerData): number
	local used = 0
	if type(data.vehicles) == "table" then
		for _, vehicle in data.vehicles do
			if type(vehicle) == "table" and not isCustom(vehicle) then
				used += 1
			end
		end
	end
	return used
end

-- True while the garage has a free slot (a damaged slot count falls back to Config/Economy.garageSlots).
function GarageService.roomIn(data: Types.PlayerData): boolean
	local slots = data.garageSlots
	if type(slots) ~= "number" or not isFinite(slots) or slots < 0 then
		slots = Economy.garageSlots
	end
	return GarageService.slotsUsed(data) < slots
end

local function validChoice(value: any, options: { string }): boolean
	return type(value) == "string" and table.find(options, value) ~= nil
end

local function validVolume(value: any): boolean
	local range = Garage.settings.musicVolume
	return type(value) == "number" and isFinite(value) and value >= range.min and value <= range.max
end

-- The settings after applying `request` ({ units?, camera?, musicVolume? }) to `current`, and whether anything
-- changed. Only valid values are taken; anything else in the request is ignored. A damaged current value is
-- replaced by its default (Config/Data.defaults.settings). Returns a new table; `current` is left alone.
function GarageService.cleanSettings(current: any, request: any): (Types.Settings, boolean)
	local defaults = Data.defaults.settings
	local options = Garage.settings
	local base = if type(current) == "table" then current else {}
	local units = if validChoice(base.units, options.units) then base.units else defaults.units
	local camera = if validChoice(base.camera, options.cameras) then base.camera else defaults.camera
	local musicVolume = if validVolume(base.musicVolume) then base.musicVolume else defaults.musicVolume
	if type(request) == "table" then
		if validChoice(request.units, options.units) then
			units = request.units
		end
		if validChoice(request.camera, options.cameras) then
			camera = request.camera
		end
		if validVolume(request.musicVolume) then
			musicVolume = request.musicVolume
		end
	end
	local settings: Types.Settings = { units = units :: any, camera = camera, musicVolume = musicVolume }
	local changed = base.units ~= units or base.camera ~= camera or base.musicVolume ~= musicVolume
	return settings, changed
end

-- Helpers ---------------------------------------------------------------------------------------------------

local function reply(ok: boolean, message: string): Reply
	return { ok = ok, message = message }
end

local function vehicleName(vehicleId: string): string
	local vehicle = Catalog.getVehicle(vehicleId)
	return if vehicle ~= nil then vehicle.displayName else vehicleId
end

local function flatDistance(a: Vector3, b: Vector3): number
	return Vector3.new(a.X - b.X, 0, a.Z - b.Z).Magnitude
end

-- True when another player's car stands on the pad (the player's own car is about to be replaced anyway).
local function padTaken(pad: BasePart, player: Player): boolean
	local vehicles = Workspace:FindFirstChild(Spawning.vehiclesFolder)
	if vehicles == nil then
		return false
	end
	for _, car in vehicles:GetChildren() do
		if
			car:IsA("Model")
			and car:GetAttribute(OWNER_ATTRIBUTE) ~= player.UserId
			and flatDistance(car:GetPivot().Position, pad.Position) <= Garage.padClearRadius
		then
			return true
		end
	end
	return false
end

-- The free SpawnPad nearest `position`, or the nearest pad when every one is taken; nil with no pads on the map.
local function nearestPad(player: Player, position: Vector3): BasePart?
	local pads: { BasePart } = {}
	for _, instance in CollectionService:GetTagged(Garage.spawnPadTag) do
		if instance:IsA("BasePart") and instance:IsDescendantOf(Workspace) then
			table.insert(pads, instance)
		end
	end
	table.sort(pads, function(a: BasePart, b: BasePart): boolean
		return flatDistance(a.Position, position) < flatDistance(b.Position, position)
	end)
	for _, pad in pads do
		if not padTaken(pad, player) then
			return pad
		end
	end
	return pads[1]
end

local function rootPosition(player: Player): Vector3?
	local character = player.Character
	local root = if character then character:FindFirstChild("HumanoidRootPart") else nil
	return if root ~= nil and root:IsA("BasePart") then root.Position else nil
end

-- The player's car if one is out, and the uid of the owned car it is (nil for a car that isn't from the garage).
local function carOut(player: Player): (Model?, string?)
	local vehicleService = VehicleService
	local car = if vehicleService ~= nil then vehicleService.getCar(player) else nil
	if car == nil then
		return nil, nil
	end
	local uid = car:GetAttribute(Garage.ownedUidAttribute)
	return car, if type(uid) == "string" then uid else nil
end

local function onTestDrive(car: Model?): boolean
	return car ~= nil and car:GetAttribute(Garage.testDriveAttribute) == true
end

-- Writes the energy level of every car the player has out back to their save, before those cars are put away.
local function saveEnergy(player: Player)
	local energyService = EnergyService
	if energyService ~= nil then
		energyService.persistPlayer(player)
	end
end

-- For the dealership and used lot ---------------------------------------------------------------------------

-- True while the player's data is loaded and their garage has a free slot.
function GarageService.hasRoom(player: Player): boolean
	local dataService = DataService
	local data = if dataService ~= nil then dataService.get(player) else nil
	return data ~= nil and GarageService.roomIn(data)
end

-- Adds a car to the player's garage with the default look and returns its new uid. `paid` is what the player
-- paid in whole dollars (0 for the free starter). Returns nil, adding nothing, when the vehicle or trim isn't in
-- the catalog, `paid` isn't a whole number of at least 0, the garage is full or the data isn't loaded. Callers
-- that charged first refund on nil.
function GarageService.addVehicle(player: Player, vehicleId: string, trim: string, paid: number): string?
	local dataService = DataService
	if dataService == nil then
		return nil
	end
	if Catalog.getTrim(vehicleId, trim) == nil then
		warn(`{LOG} addVehicle for {player.Name} refused: no "{vehicleId}" / "{trim}" in the catalog`)
		return nil
	end
	if type(paid) ~= "number" or not isFinite(paid) or paid < 0 or paid % 1 ~= 0 then
		warn(`{LOG} addVehicle for {player.Name} refused: paid {tostring(paid)} isn't a whole number of dollars`)
		return nil
	end
	local uid = HttpService:GenerateGUID(false)
	local added = false
	local updated = dataService.update(player, function(data: Types.PlayerData)
		-- Check the room inside the update, so two purchases at once can't both take the last slot.
		if not GarageService.roomIn(data) then
			return
		end
		table.insert(data.vehicles, Template.ownedVehicle(uid, vehicleId, trim, paid, os.time()))
		added = true
	end)
	if not updated or not added then
		print(`{LOG} addVehicle for {player.Name} refused: garage full or data not loaded`)
		return nil
	end
	return uid
end

-- Remotes ---------------------------------------------------------------------------------------------------

-- Brings an owned car out at the SpawnPad nearest the player and seats them. Replaces any car they had out,
-- except a dealership test drive, which has to finish first.
function GarageService.spawnOwned(player: Player, uid: string): Reply
	local dataService, vehicleService = DataService, VehicleService
	local data = if dataService ~= nil then dataService.get(player) else nil
	if data == nil or vehicleService == nil then
		return reply(false, messages.notLoaded)
	end
	local vehicle = GarageService.findVehicle(data, uid)
	if vehicle == nil then
		warn(`{LOG} {player.Name} asked to spawn a car they don't own ({uid})`)
		return reply(false, messages.notFound)
	end
	local catalogVehicle = Catalog.getVehicle(vehicle.vehicleId)
	if
		catalogVehicle == nil
		or not catalogVehicle.playerDrivable
		or Catalog.getTrim(vehicle.vehicleId, vehicle.trim) == nil
	then
		return reply(false, messages.cantSpawn)
	end
	local current = carOut(player)
	if onTestDrive(current) then
		return reply(false, messages.testDriveOut)
	end
	local position = rootPosition(player)
	if position == nil then
		return reply(false, messages.noCharacter)
	end

	-- "Replaces any car they had out": put every car away first (saving their energy, so bringing the same car
	-- out again reads its current level), then bring this one out.
	saveEnergy(player)
	vehicleService.despawn(player)
	local pad = nearestPad(player, position)
	-- No pads on the map: VehicleService puts the car just in front of the player instead.
	local model = vehicleService.spawn(player, vehicle.vehicleId, vehicle.trim, if pad then pad.CFrame else nil)
	if model == nil then
		return reply(false, messages.spawnFailed)
	end
	model:SetAttribute(Garage.ownedUidAttribute, vehicle.uid)
	local energyService = EnergyService
	if energyService ~= nil then
		energyService.attach(model, vehicle.energy) -- `vehicle` is the live entry, so this is the level just saved
	end
	if Garage.seatDriver then
		vehicleService.seatDriver(player)
	end
	return reply(true, string.format(messages.spawned, vehicleName(vehicle.vehicleId)))
end

-- Puts away the car the player has out (not a test drive, which the dealership ends).
function GarageService.despawnOwned(player: Player): Reply
	local vehicleService = VehicleService
	if vehicleService == nil then
		return reply(false, messages.notLoaded)
	end
	local car = carOut(player)
	if car == nil then
		return reply(false, messages.nothingOut)
	end
	if onTestDrive(car) then
		return reply(false, messages.testDriveOut)
	end
	saveEnergy(player)
	vehicleService.despawn(player)
	return reply(true, messages.putAway)
end

local function setFavorite(player: Player, uid: string, favorite: boolean)
	local dataService = DataService
	local data = if dataService ~= nil then dataService.get(player) else nil
	if dataService == nil or data == nil then
		return
	end
	local vehicle = GarageService.findVehicle(data, uid)
	if vehicle == nil then
		warn(`{LOG} {player.Name} tried to favorite a car they don't own ({uid})`)
		return
	end
	if vehicle.favorite == favorite then
		return -- nothing to change (and nothing to sync)
	end
	dataService.update(player, function(fresh: Types.PlayerData)
		local current = GarageService.findVehicle(fresh, uid)
		if current ~= nil then
			current.favorite = favorite
		end
	end)
end

-- Sells a car back. Checks everything first, puts the car away if it's out, then removes it and pays for it in
-- one update that re-checks the car is still there, so it can only ever be sold once.
function GarageService.sell(player: Player, uid: string): Reply
	local dataService, vehicleService = DataService, VehicleService
	local data = if dataService ~= nil then dataService.get(player) else nil
	if dataService == nil or vehicleService == nil or data == nil then
		return reply(false, messages.notLoaded)
	end
	local vehicle = GarageService.findVehicle(data, uid)
	if vehicle == nil then
		-- Also what a second click on a car that just sold gets.
		print(`{LOG} {player.Name} asked to sell a car they don't own ({uid})`)
		return reply(false, messages.notFound)
	end
	local sellable, refusal = GarageService.sellCheck(vehicle)
	if not sellable then
		return reply(false, refusal or messages.sellFailed)
	end

	local car, outUid = carOut(player)
	if car ~= nil and outUid == uid then
		vehicleService.despawn(player)
	end

	local vehicleId = vehicle.vehicleId
	local refused: string? = nil
	local gained = 0
	local updated = dataService.update(player, function(fresh: Types.PlayerData)
		local current, index = GarageService.findVehicle(fresh, uid)
		if current == nil or index == nil then
			refused = messages.notFound -- sold a moment ago
			return
		end
		local ok, reason = GarageService.sellCheck(current)
		if not ok then
			refused = reason
			return
		end
		local price = Garage.sellPrice(current.paid)
		local newBalance, added = EconomyService.applyAdd(fresh.cash, price, Economy.maxCash)
		if added < price then
			refused = messages.walletFull -- never sell for less than the car is worth
			return
		end
		table.remove(fresh.vehicles, index)
		fresh.cash = newBalance
		gained = added
	end)
	if not updated then
		return reply(false, messages.sellFailed)
	end
	if refused ~= nil then
		return reply(false, refused)
	end
	EconomyService.recordChange(player, "source", gained, Garage.sellReason)
	print(`{LOG} {player.Name} sold {vehicleId} ({uid}) for ${gained}`)
	return reply(true, string.format(messages.sold, vehicleName(vehicleId), Economy.formatCash(gained)))
end

local function updateSettings(player: Player, request: any)
	local dataService = DataService
	local data = if dataService ~= nil then dataService.get(player) else nil
	if dataService == nil or data == nil then
		return
	end
	local _, changed = GarageService.cleanSettings(data.settings, request)
	if not changed then
		return
	end
	dataService.update(player, function(fresh: Types.PlayerData)
		fresh.settings = GarageService.cleanSettings(fresh.settings, request)
	end)
end

-- Boot ------------------------------------------------------------------------------------------------------

function GarageService:Init()
	DataService = require(script.Parent.DataService)
	VehicleService = require(script.Parent.VehicleService)
	EnergyService = require(script.Parent.EnergyService)
end

function GarageService:Start()
	Net.onServerInvoke("SpawnOwned", function(player: Player, payload: any): Reply
		return GarageService.spawnOwned(player, payload.uid)
	end)
	Net.onServerInvoke("DespawnOwned", function(player: Player, _payload: any): Reply
		return GarageService.despawnOwned(player)
	end)
	Net.onServerInvoke("SellVehicle", function(player: Player, payload: any): Reply
		return GarageService.sell(player, payload.uid)
	end)
	Net.onServerEvent("SetFavorite", function(player: Player, payload: any)
		setFavorite(player, payload.uid, payload.favorite)
	end)
	Net.onServerEvent("UpdateSettings", updateSettings)
end

return GarageService
