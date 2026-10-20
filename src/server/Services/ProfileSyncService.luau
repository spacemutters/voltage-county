--!strict
-- Keeps each player's client up to date with their own profile (PLAN.md Phase 4; docs/phase-4-contracts.md
-- "ProfileSyncService").
--
-- On load and after every change (DataService.onChanged) the player gets a ProfileSnapshot over Net: a fresh
-- copy of the sanitized fields the phone and HUD need (Types.ProfileSnapshot), never the live table and never
-- anything else in the save (receipts, reservations, plate text, mods). A burst of changes (a purchase changes
-- cash and the garage in quick succession) is coalesced: at most one snapshot per player every
-- Config/Data.snapshotMinInterval seconds, and always one after the last change.
--
-- Only ever sends a player their own data. No polling: one task.defer or task.delay per burst, per player.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Data = require(ReplicatedStorage.Shared.Config.Data)
local Economy = require(ReplicatedStorage.Shared.Config.Economy)
local Garage = require(ReplicatedStorage.Shared.Config.Garage)
local Net = require(ReplicatedStorage.Shared.Net)
local Types = require(ReplicatedStorage.Shared.Types)

-- DataService is required in Init rather than here: requiring it loads ProfileStore, which talks to DataStores
-- straight away, and specs may require this module in Edit mode for `snapshot`.
type DataServiceModule = typeof(require(script.Parent.DataService))

local REMOTE = "ProfileSnapshot"

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

-- The client's copy of one owned car: only the listed fields, each a plain value of the right type.
local function snapshotVehicle(vehicle: { [string]: any }): Types.SnapshotVehicle
	local look = Garage.defaults
	return {
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
end

-- The snapshot a player's client gets of their own data: new tables throughout (nothing shared with the save),
-- sanitized fields only, cars sorted favorites first then newest (Config/Garage.sortVehicles).
function ProfileSyncService.snapshot(data: Types.PlayerData): Types.ProfileSnapshot
	local raw = data :: any
	local vehicles: { Types.SnapshotVehicle } = {}
	if type(raw.vehicles) == "table" then
		for _, vehicle in raw.vehicles do
			if type(vehicle) == "table" and type(vehicle.uid) == "string" then
				table.insert(vehicles, snapshotVehicle(vehicle))
			end
		end
	end
	local defaults = Data.defaults.settings
	local settings = if type(raw.settings) == "table" then raw.settings else {}
	local credits = if type(raw.credits) == "table" then raw.credits else {}
	return {
		cash = number(raw.cash, 0),
		garageSlots = number(raw.garageSlots, Economy.garageSlots),
		customSlots = number(raw.customSlots, Economy.customSlots),
		starterClaimed = raw.starterClaimed == true,
		vehicles = Garage.sortVehicles(vehicles),
		settings = {
			units = if settings.units == "kph" or settings.units == "mph" then settings.units else defaults.units,
			camera = text(settings.camera, defaults.camera),
			musicVolume = number(settings.musicVolume, defaults.musicVolume),
		},
		credits = { balance = number(credits.balance, Data.defaults.credits) },
	}
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
	Net.fireClient(REMOTE, player, ProfileSyncService.snapshot(data))
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
