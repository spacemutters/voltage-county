--!strict
-- Keeps each player's client up to date with their own profile (PLAN.md Phase 4; docs/phase-4-contracts.md
-- "ProfileSyncService").
--
-- On load and after every change (DataService.onChanged) the player gets a ProfileSnapshot over Net: a fresh
-- copy of the sanitized fields the phone and HUD need (Types.ProfileSnapshot), never the live table and never
-- anything else in the save (receipts, reservations, plate text, raw mods). A burst of changes (a purchase changes
-- cash and the garage in quick succession) is coalesced: at most one snapshot per player every
-- Config/Data.snapshotMinInterval seconds, and always one after the last change.
--
-- Phase 9 (docs/phase-9-contracts.md): the snapshot also carries the robotaxi fleet (Types.SnapshotFleet): the
-- pods, the whole dollars ready to collect, the slots (Config/Fleet's default plus the Fleet Manager bonus while
-- the player attribute Config/Fleet.pass.attribute is true, which FleetService sets), the pod price and sell-back,
-- every zone with its demand and expected $ an hour, and the offline rule. `push` sends a fresh snapshot for a
-- change that isn't in the save (FleetService calls it when the pass is bought).
--
-- Phase 11 (docs/phase-11-contracts.md): the AI Car Designer's part of the snapshot.
--   credits   { balance, freeDesignUsed } (true while the one free new car is used or held by a request)
--   designs   one entry per saved design: { uid, name, tagline, classId, hidden, createdAt, spec }. `spec` is the
--             design re-validated against the kit without its generation prompt (so the phone can preview it with
--             Vehicle/SpecBuilder); name and tagline were filtered with TextService when the design was made. A
--             design a moderator hid sends its plain look (DesignerService/Validate.plain) and plain name
--             ("Custom <class>"), no tagline.
--   vehicles  each car also carries `designUid` (player designs, vehicleId "custom") and, when it has an AI mod,
--             `modded = true` with `mods` (the mod spec re-validated, without its accessory prompt; its summary
--             was filtered when the mod was made) and `modSummary`. A mod a moderator hid, or any mod on a design a
--             moderator hid (that car spawns plain, Services/VehicleService), sends `modHidden = true` and no spec
--             or summary. Fields that don't apply are left out.
--
-- Phase 12: garageSlots and customSlots include the slots the player's passes (Garage+) and the Voltage Club add
-- right now (the player attributes MonetizationService keeps; never saved), so the phone counts the same room as
-- GarageService. MonetizationService calls `push` when they change. `looks` lists the exclusive looks the player may
-- use right now (Config/Customization.exclusiveWraps ids): those saved in PlayerData.cosmetics, plus the club's
-- (Config/Monetization club.cosmetics) while the club attribute says they are a member; the Wrap & Tint shop lists
-- those wraps (Services/CustomizationService checks ownership again on every purchase).
--
-- Only ever sends a player their own data. No polling: one task.defer or task.delay per burst, per player.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Classes = require(ReplicatedStorage.Shared.Config.Classes)
local Customization = require(ReplicatedStorage.Shared.Config.Customization)
local Data = require(ReplicatedStorage.Shared.Config.Data)
local DesignKit = require(ReplicatedStorage.Shared.Config.DesignKit)
local Designer = require(ReplicatedStorage.Shared.Config.Designer)
local Economy = require(ReplicatedStorage.Shared.Config.Economy)
local Fleet = require(ReplicatedStorage.Shared.Config.Fleet)
local Garage = require(ReplicatedStorage.Shared.Config.Garage)
local Monetization = require(ReplicatedStorage.Shared.Config.Monetization)
local Net = require(ReplicatedStorage.Shared.Net)
local Types = require(ReplicatedStorage.Shared.Types)
local Validate = require(script.Parent.DesignerService.Validate)

-- DataService is required in Init rather than here: requiring it loads ProfileStore, which talks to DataStores
-- straight away, and specs may require this module in Edit mode for `snapshot`.
type DataServiceModule = typeof(require(script.Parent.DataService))

local REMOTE = "ProfileSnapshot"

-- Phase 11 snapshot parts (see the header): Types.ProfileSnapshot's `designs` and `credits.freeDesignUsed`, and
-- Types.SnapshotVehicle's optional `designUid`, `modded`, `modHidden`, `mods` and `modSummary`.
export type SnapshotDesign = Types.SnapshotDesign

-- A car's AI mod as the snapshot carries it (merged into the car's entry).
export type SnapshotMod = {
	modded: boolean,
	modHidden: boolean?,
	mods: { [string]: any }?,
	modSummary: string?,
}

-- Slots passes and the Voltage Club add right now (Phase 12): MonetizationService mirrors them to the player
-- attributes Config/Monetization.attributes.garageBonus / customBonus.
export type SlotBonus = { garage: number, custom: number }

local ProfileSyncService = {}

local DataService: DataServiceModule? = nil

local pending: { [Player]: thread } = {} -- the scheduled send for each player with unsent changes
local lastSent: { [Player]: number } = {} -- os.clock() of each player's last snapshot

-- Pure helpers ----------------------------------------------------------------------------------------------

local function isFinite(value: any): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function number(value: any, fallback: number): number
	return if isFinite(value) then value else fallback
end

local function text(value: any, fallback: string): string
	return if type(value) == "string" then value else fallback
end

-- A slot bonus as a whole number of at least 0 (anything else counts as none).
local function wholeBonus(value: any): number
	return if isFinite(value) and value > 0 then math.floor(value) else 0
end

-- The client's copy of a car's AI mod (see the header), or nil for a car without one. Every saved mod has a string
-- summary; anything else (or a mod the kit no longer accepts) isn't shown as one.
function ProfileSyncService.snapshotMod(mods: any, kind: "kit" | "catalog"): SnapshotMod?
	if type(mods) ~= "table" or type(mods.summary) ~= "string" then
		return nil
	end
	if mods.hidden == true then
		return { modded = true, modHidden = true }
	end
	local checked = Validate.mod(mods, DesignKit, kind)
	if checked == nil then
		return nil
	end
	local spec: { [string]: any } = checked :: any
	spec.accessoryPrompt = nil -- AI text nobody needs to read
	return { modded = true, mods = spec, modSummary = checked.summary }
end

-- The client's copy of one owned car: only the listed fields, each a plain value of the right type (the Phase 11
-- ones only when they apply). `hiddenDesigns` holds the uids of the player's designs a moderator hid.
local function snapshotVehicle(vehicle: { [string]: any }, hiddenDesigns: { [string]: boolean }): Types.SnapshotVehicle
	local look = Garage.defaults
	local copy: { [string]: any } = {
		uid = text(vehicle.uid, ""),
		vehicleId = text(vehicle.vehicleId, ""),
		trim = text(vehicle.trim, ""),
		favorite = vehicle.favorite == true,
		paid = number(vehicle.paid, 0),
		paint = text(vehicle.paint, look.paint),
		finish = text(vehicle.finish, look.finish),
		wheels = text(vehicle.wheels, look.wheels),
		acquiredAt = number(vehicle.acquiredAt, 0),
	}
	local custom = vehicle.vehicleId == Garage.customVehicleId
	if custom and type(vehicle.designUid) == "string" then
		copy.designUid = vehicle.designUid
	end
	local mod = ProfileSyncService.snapshotMod(vehicle.mods, if custom then "kit" else "catalog")
	if mod ~= nil and custom and hiddenDesigns[copy.designUid or ""] then
		mod = { modded = true, modHidden = true }
	end
	if mod ~= nil then
		copy.modded = mod.modded
		copy.modHidden = mod.modHidden
		copy.mods = mod.mods
		copy.modSummary = mod.modSummary
	end
	return copy :: any
end

-- The client's copy of one saved design (see the header), or nil for an entry without a string uid.
function ProfileSyncService.snapshotDesign(design: any): SnapshotDesign?
	if type(design) ~= "table" or type(design.uid) ~= "string" then
		return nil
	end
	local saved = if type(design.spec) == "table" then design.spec else {}
	local classId = text(saved.class, "")
	local hidden = design.hidden == true
	local class = Classes[classId]
	local className = if class ~= nil then class.displayName else Designer.messages.genericClass
	local plainName = string.format(Designer.messages.hiddenName, className)
	local name = text(saved.name, "")
	local valid = Validate.design(saved, DesignKit)
	local spec = if valid == nil then nil elseif hidden then Validate.plain(valid, DesignKit) else valid
	return {
		uid = design.uid,
		name = if hidden or name == "" then plainName else name,
		tagline = if hidden then "" else text(saved.tagline, ""),
		classId = classId,
		hidden = hidden,
		createdAt = number(design.createdAt, 0),
		spec = if spec ~= nil then Validate.clientSpec(spec) else nil,
	}
end

-- The client's copy of the fleet: the saved pods (each a plain uid and zone; entries without a string uid left
-- out), the whole dollars waiting, and the prices, slots, zones and offline rule from Config/Fleet.
-- `hasFleetManager` adds the pass's bonus slots.
function ProfileSyncService.snapshotFleet(fleet: any, hasFleetManager: boolean): Types.SnapshotFleet
	local saved = if type(fleet) == "table" then fleet else {}
	local pods: { Types.FleetPod } = {}
	if type(saved.pods) == "table" then
		for _, pod in saved.pods do
			if type(pod) == "table" and type(pod.uid) == "string" then
				table.insert(pods, { uid = pod.uid, zone = text(pod.zone, Fleet.defaultZone) })
			end
		end
	end
	local zones: { Types.SnapshotFleetZone } = {}
	for _, zone in Fleet.zones do
		table.insert(zones, {
			id = zone.id,
			name = Fleet.zoneName(zone.id),
			demand = zone.demand,
			perHour = Fleet.perHour(zone.id),
		})
	end
	return {
		pods = pods,
		uncollected = math.max(math.floor(number(saved.uncollected, 0)), 0),
		slots = Fleet.slotsFor(hasFleetManager),
		podPrice = Fleet.podPrice,
		sellBack = Fleet.sellBack,
		zones = zones,
		offlineRate = Fleet.offlineRate,
		offlineCapHours = Fleet.offlineCapHours,
	}
end

-- The exclusive looks a player may use right now (see the header): the exclusive look ids saved in `cosmetics`
-- (any whole serial; 0 = not numbered), plus the club's while `clubMember`. Sorted, each once.
function ProfileSyncService.snapshotLooks(cosmetics: any, clubMember: boolean): { string }
	local seen: { [string]: boolean } = {}
	if type(cosmetics) == "table" then
		for id, serial in cosmetics do
			local whole = isFinite(serial) and serial >= 0 and serial % 1 == 0
			if type(id) == "string" and whole and Customization.isExclusive(id) then
				seen[id] = true
			end
		end
	end
	if clubMember then
		for _, id in Monetization.club.cosmetics do
			if Customization.isExclusive(id) then
				seen[id] = true
			end
		end
	end
	local looks: { string } = {}
	for id in seen do
		table.insert(looks, id)
	end
	table.sort(looks)
	return looks
end

-- The snapshot a player's client gets of their own data: new tables throughout (nothing shared with the save),
-- sanitized fields only, cars sorted favorites first then newest (Config/Garage.sortVehicles). `hasFleetManager`
-- (default false) is whether the player owns the Fleet Manager pass, for the fleet's slots. `slotBonus` (default
-- none) is the garage and custom-car slots the player's passes and the Voltage Club add right now (Phase 12; never
-- saved): the snapshot's garageSlots and customSlots count them, as GarageService.roomIn / customRoomIn do.
-- `clubMember` (default false) adds the club's exclusive looks to `looks`.
function ProfileSyncService.snapshot(
	data: Types.PlayerData,
	hasFleetManager: boolean?,
	slotBonus: SlotBonus?,
	clubMember: boolean?
): Types.ProfileSnapshot
	local raw = data :: any
	local hiddenDesigns: { [string]: boolean } = {}
	if type(raw.designs) == "table" then
		for _, design in raw.designs do
			if type(design) == "table" and type(design.uid) == "string" and design.hidden == true then
				hiddenDesigns[design.uid] = true
			end
		end
	end
	local vehicles: { Types.SnapshotVehicle } = {}
	if type(raw.vehicles) == "table" then
		for _, vehicle in raw.vehicles do
			if type(vehicle) == "table" and type(vehicle.uid) == "string" then
				table.insert(vehicles, snapshotVehicle(vehicle, hiddenDesigns))
			end
		end
	end
	local designs: { SnapshotDesign } = {}
	if type(raw.designs) == "table" then
		for _, design in raw.designs do
			local entry = ProfileSyncService.snapshotDesign(design)
			if entry ~= nil then
				table.insert(designs, entry)
			end
		end
	end
	local defaults = Data.defaults.settings
	local settings = if type(raw.settings) == "table" then raw.settings else {}
	local credits = if type(raw.credits) == "table" then raw.credits else {}
	local bonus: SlotBonus = slotBonus or { garage = 0, custom = 0 }
	local snapshot: { [string]: any } = {
		cash = number(raw.cash, 0),
		garageSlots = number(raw.garageSlots, Economy.garageSlots) + wholeBonus(bonus.garage),
		customSlots = number(raw.customSlots, Economy.customSlots) + wholeBonus(bonus.custom),
		starterClaimed = raw.starterClaimed == true,
		vehicles = Garage.sortVehicles(vehicles),
		settings = {
			units = if settings.units == "kph" or settings.units == "mph" then settings.units else defaults.units,
			camera = text(settings.camera, defaults.camera),
			musicVolume = number(settings.musicVolume, defaults.musicVolume),
		},
		credits = {
			balance = number(credits.balance, Data.defaults.credits),
			freeDesignUsed = credits.freeDesignUsed == true,
		},
		fleet = ProfileSyncService.snapshotFleet(raw.fleet, hasFleetManager == true),
		designs = designs,
		looks = ProfileSyncService.snapshotLooks(raw.cosmetics, clubMember == true),
	}
	return snapshot :: any
end

-- Sending ---------------------------------------------------------------------------------------------------

local function send(player: Player)
	pending[player] = nil
	local dataService = DataService
	local data = if dataService ~= nil then dataService.get(player) else nil
	if data == nil or player.Parent ~= Players then
		return -- left, or the session ended; nothing to send
	end
	lastSent[player] = os.clock()
	local hasFleetManager = player:GetAttribute(Fleet.pass.attribute) == true
	local attributes = Monetization.attributes
	local slotBonus: SlotBonus = {
		garage = wholeBonus(player:GetAttribute(attributes.garageBonus)),
		custom = wholeBonus(player:GetAttribute(attributes.customBonus)),
	}
	local clubMember = player:GetAttribute(attributes.club) == true
	Net.fireClient(REMOTE, player, ProfileSyncService.snapshot(data, hasFleetManager, slotBonus, clubMember))
end

-- Schedules a snapshot for the player unless one is already on its way (it will read the latest data when it
-- goes). Goes at the end of this frame's work when the last one was long enough ago, else as soon as it may.
local function schedule(player: Player)
	if pending[player] ~= nil then
		return
	end
	local last = lastSent[player]
	local waitSeconds = if last ~= nil then Data.snapshotMinInterval - (os.clock() - last) else 0
	if waitSeconds > 0 then
		pending[player] = task.delay(waitSeconds, send, player)
	else
		pending[player] = task.defer(send, player)
	end
end

-- Sends the player a fresh snapshot soon, coalesced like every other change. For changes that aren't in the save
-- (the Fleet Manager pass bought or found on join); changes to the save are sent on their own.
function ProfileSyncService.push(player: Player)
	if player.Parent == Players then
		schedule(player)
	end
end

local function forget(player: Player)
	local thread = pending[player]
	pending[player] = nil
	lastSent[player] = nil
	if thread ~= nil then
		task.cancel(thread)
	end
end

-- Boot ------------------------------------------------------------------------------------------------------

function ProfileSyncService:Init()
	DataService = require(script.Parent.DataService)
end

function ProfileSyncService:Start()
	local dataService = DataService
	if dataService == nil then
		return
	end
	Players.PlayerRemoving:Connect(forget)
	-- Fires on load (and for everyone already loaded) as well as after every update.
	dataService.onChanged(function(player: Player, _data: Types.PlayerData)
		schedule(player)
	end)
end

return ProfileSyncService
