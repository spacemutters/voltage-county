--!strict
-- The local player's own profile, as the server last sent it (docs/phase-4-contracts.md "Client UI").
--
-- Services/ProfileSyncService sends Net "ProfileSnapshot" on load and after every change. This controller keeps
-- the latest one and fires `onChanged` (snapshot, previous) whenever what it hands out changes. The phone, the HUD
-- (speed units) and the shops read it with `get()`; nothing here ever changes the real data, which only the
-- server does (clients send intents: UpdateSettings, SetFavorite).
--
-- Optimistic changes: when the phone sends an intent whose result is obvious (a units switch, a favorite star),
-- it calls patchSettings / patchFavorite so the screen answers at once. A patch overlays the snapshot until a
-- snapshot from the server agrees with it, or until PhoneConfig.confirmHoldSeconds pass, after which the screen
-- shows what the server has (so a refused change quietly goes back).
--
-- The pure parts (normalize: checking a payload; merge: applying patches) are exposed for tests/Phone.spec.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Data = require(ReplicatedStorage.Shared.Config.Data)
local Garage = require(ReplicatedStorage.Shared.Config.Garage)
local Net = require(ReplicatedStorage.Shared.Net)
local Types = require(ReplicatedStorage.Shared.Types)
local InputController = require(script.Parent.InputController)

local PhoneConfig = require(script.Parent.Parent.UI.Phone.PhoneConfig)

local REMOTE = "ProfileSnapshot"

-- A change waiting for the server to confirm it, and when it stops waiting (os.clock()).
type Pending<T> = { value: T, untilTime: number }

export type Patches = {
	settings: { [string]: Pending<any> }, -- by Settings field name
	favorites: { [string]: Pending<boolean> }, -- by vehicle uid
}

local ProfileController = {}

-- Fires (snapshot: Types.ProfileSnapshot, previous: Types.ProfileSnapshot?) whenever get() would return
-- something new: a snapshot from the server, a patch, or a patch running out.
ProfileController.onChanged = InputController.newSignal()

local snapshot: Types.ProfileSnapshot? = nil -- the server's latest, checked
local merged: Types.ProfileSnapshot? = nil -- the same with the waiting patches applied (what get() returns)
local patches: Patches = { settings = {}, favorites = {} }

-- Pure helpers -------------------------------------------------------------------------------------------------

local function finite(value: any): boolean
	return type(value) == "number" and value == value and math.abs(value) ~= math.huge
end

local function numberOr(value: any, fallback: number): number
	return if finite(value) then value else fallback
end

local function stringOr(value: any, fallback: string): string
	return if type(value) == "string" then value else fallback
end

-- The settings a fresh profile starts with (Config/Data), for any field the payload lacks or got wrong.
function ProfileController.defaultSettings(): Types.Settings
	local defaults = Data.defaults.settings
	return { units = defaults.units, camera = defaults.camera, musicVolume = defaults.musicVolume }
end

-- Valid fields of `value` over `fallback` (the defaults when nil); anything missing or wrong keeps the fallback.
local function normalizeSettings(value: any, fallback: Types.Settings?): Types.Settings
	local settings: Types.Settings = if fallback then table.clone(fallback) else ProfileController.defaultSettings()
	if type(value) ~= "table" then
		return settings
	end
	if table.find(Garage.settings.units, value.units) then
		settings.units = value.units
	end
	if table.find(Garage.settings.cameras, value.camera) then
		settings.camera = value.camera
	end
	if finite(value.musicVolume) then
		local range = Garage.settings.musicVolume
		settings.musicVolume = math.clamp(value.musicVolume, range.min, range.max)
	end
	return settings
end

local function normalizeVehicle(value: any): Types.SnapshotVehicle?
	if type(value) ~= "table" or type(value.uid) ~= "string" or type(value.vehicleId) ~= "string" then
		return nil
	end
	if type(value.trim) ~= "string" then
		return nil
	end
	return {
		uid = value.uid,
		vehicleId = value.vehicleId,
		trim = value.trim,
		favorite = value.favorite == true,
		paid = math.max(numberOr(value.paid, 0), 0),
		paint = stringOr(value.paint, Garage.defaults.paint),
		finish = stringOr(value.finish, Garage.defaults.finish),
		wheels = stringOr(value.wheels, Garage.defaults.wheels),
		acquiredAt = numberOr(value.acquiredAt, 0),
	}
end

-- A checked copy of a ProfileSnapshot payload, or nil when it isn't one. The payload comes from our own server,
-- but a bad field (an older server, a bug) must never break the phone: missing or wrong fields get safe
-- defaults, broken cars are left out, and the cars come back in the garage order (Config/Garage).
function ProfileController.normalize(payload: any): Types.ProfileSnapshot?
	if type(payload) ~= "table" or not finite(payload.cash) then
		return nil
	end
	local vehicles: { Types.SnapshotVehicle } = {}
	if type(payload.vehicles) == "table" then
		for _, value in payload.vehicles do
			local vehicle = normalizeVehicle(value)
			if vehicle then
				table.insert(vehicles, vehicle)
			end
		end
	end
	local credits = if type(payload.credits) == "table" then payload.credits else {}
	return {
		cash = payload.cash,
		garageSlots = math.max(numberOr(payload.garageSlots, 0), 0),
		customSlots = math.max(numberOr(payload.customSlots, 0), 0),
		starterClaimed = payload.starterClaimed == true,
		vehicles = Garage.sortVehicles(vehicles),
		settings = normalizeSettings(payload.settings),
		credits = { balance = math.max(numberOr(credits.balance, 0), 0) },
	}
end

-- Drops the patches the snapshot already agrees with, and those whose wait is over (at `now`, os.clock()).
function ProfileController.prune(base: Types.ProfileSnapshot?, current: Patches, now: number)
	local settings: { [string]: any } = if base then base.settings :: any else {}
	for field, pending in current.settings do
		if now >= pending.untilTime or settings[field] == pending.value then
			current.settings[field] = nil
		end
	end
	local favorites: { [string]: boolean } = {}
	if base then
		for _, vehicle in base.vehicles do
			favorites[vehicle.uid] = vehicle.favorite
		end
	end
	for uid, pending in current.favorites do
		if now >= pending.untilTime or favorites[uid] == pending.value or favorites[uid] == nil then
			current.favorites[uid] = nil
		end
	end
end

-- The snapshot with the waiting patches applied: a new table (the snapshot is left alone), cars re-sorted.
function ProfileController.merge(base: Types.ProfileSnapshot, current: Patches): Types.ProfileSnapshot
	local result = table.clone(base)
	local settings = table.clone(base.settings) :: any
	for field, pending in current.settings do
		settings[field] = pending.value
	end
	result.settings = normalizeSettings(settings, base.settings)
	local vehicles: { Types.SnapshotVehicle } = {}
	for _, vehicle in base.vehicles do
		local pending = current.favorites[vehicle.uid]
		if pending ~= nil and pending.value ~= vehicle.favorite then
			local copy = table.clone(vehicle)
			copy.favorite = pending.value
			table.insert(vehicles, copy)
		else
			table.insert(vehicles, vehicle)
		end
	end
	result.vehicles = Garage.sortVehicles(vehicles)
	return result
end

-- State ------------------------------------------------------------------------------------------------------

-- Re-applies the patches and tells listeners when the result changed.
local function refresh()
	local base = snapshot
	ProfileController.prune(base, patches, os.clock())
	if base == nil then
		return
	end
	local previous = merged
	local current = if next(patches.settings) == nil and next(patches.favorites) == nil
		then base
		else ProfileController.merge(base, patches)
	if current == previous then
		return -- nothing new (a wait ran out after the server had already agreed)
	end
	merged = current
	ProfileController.onChanged:Fire(current, previous)
end

-- Checks again once a patch's wait is over, so a change the server refused goes back on screen.
local function scheduleExpiry()
	task.delay(PhoneConfig.confirmHoldSeconds, refresh)
end

-- Public API ---------------------------------------------------------------------------------------------------

-- The latest snapshot (with any changes still waiting for the server), or nil until the first one arrives.
-- Treat it as read-only.
function ProfileController.get(): Types.ProfileSnapshot?
	return merged
end

function ProfileController.isLoaded(): boolean
	return merged ~= nil
end

-- The player's settings, or the defaults until their profile arrives.
function ProfileController.settings(): Types.Settings
	local current = merged
	return if current then current.settings else ProfileController.defaultSettings()
end

-- Shows a settings change at once while Net UpdateSettings carries it to the server (the caller sends it).
function ProfileController.patchSettings(partial: { [string]: any })
	local untilTime = os.clock() + PhoneConfig.confirmHoldSeconds
	for field, value in partial do
		patches.settings[field] = { value = value, untilTime = untilTime }
	end
	refresh()
	scheduleExpiry()
end

-- Shows a favorite star at once while Net SetFavorite carries it to the server (the caller sends it).
function ProfileController.patchFavorite(uid: string, favorite: boolean)
	patches.favorites[uid] = { value = favorite, untilTime = os.clock() + PhoneConfig.confirmHoldSeconds }
	refresh()
	scheduleExpiry()
end

function ProfileController:Start()
	Net.onClientEvent(REMOTE, function(payload: any)
		local checked = ProfileController.normalize(payload)
		if checked == nil then
			warn("[ProfileController] Ignored a profile snapshot that didn't look right")
			return
		end
		snapshot = checked
		refresh()
	end)
end

return ProfileController
