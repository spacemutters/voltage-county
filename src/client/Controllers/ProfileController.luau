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
-- The robotaxi fleet (Phase 9, docs/phase-9-contracts.md "Fleet UI"): the snapshot's `fleet` field (pods with
-- their zones, uncollected earnings, slots, the pod price and sell-back, the zones with their demand and expected
-- $ per pod per hour, and the offline rule) is checked like the rest and read with fleetOf(snapshot) or fleet().
-- It is nil until the server sends one. The fleet is never patched: Buy, Assign, Collect and Sell wait for the
-- server's answer and the snapshot that follows it.
--
-- The AI Car Designer (Phase 11, docs/phase-11-contracts.md "Client"): the credits balance, whether the free first
-- car is used, the player's designs (each with its validated spec, so the phone can name it and the designer can
-- preview it) and which owned cars are custom designs or carry an AI mod. normalizeDesigner reads them from the
-- same payload into a Designer kept beside the snapshot (read with designer(); onChanged fires with each new one,
-- as it comes with every snapshot); like the fleet it is never patched. Services/ProfileSyncService sends these
-- shapes (any may be missing; missing means none):
--   credits = { balance, freeDesignUsed }           (a top-level `freeDesignUsed` works too)
--   designs = { { uid, name?, tagline?, hidden?, createdAt?, spec? } } (or a map designUid -> the same without uid);
--             `name` is the server's (filtered, or the plain name of a hidden design), else the spec's; `spec` is
--             what the phone previews (the plain look for a hidden design)
--   vehicles[i].designUid, vehicles[i].mods (the car's mod spec) or vehicles[i].modded = true (a hidden mod)
--   mods = { [vehicleUid] = modSpec }                (instead of vehicles[i].mods)
--
-- The pure parts (normalize: checking a payload; normalizeFleet; normalizeDesigner; merge: applying patches) are
-- exposed for tests/Phone.spec and tests/DesignerUi.spec.

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

-- The robotaxi fleet as the snapshot sends it (docs/phase-9-contracts.md; Services/ProfileSyncService).
export type FleetPod = Types.FleetPod -- zone: a MapLayout zone id
export type FleetZone = Types.SnapshotFleetZone
export type Fleet = Types.SnapshotFleet

-- One of the player's designs (Phase 11). `name` is the name the server sent (filtered when the design was made, or
-- a plain "Custom <class>" for a design a moderator hid), else the spec's, or nil when there is none to show.
export type DesignInfo = {
	uid: string,
	spec: { [string]: any }?, -- nil when the server had none it could send
	hidden: boolean,
	createdAt: number,
	name: string?,
	tagline: string?,
}

-- The designer's part of the snapshot.
export type Designer = {
	balance: number, -- Design Credits
	freeDesignUsed: boolean,
	designs: { [string]: DesignInfo }, -- by design uid
	designCount: number,
	vehicleDesigns: { [string]: string }, -- owned car uid -> its design uid (custom cars)
	mods: { [string]: { [string]: any } }, -- owned car uid -> its AI mod spec (empty when only known as modded)
}

local ProfileController = {}

-- Fires (snapshot: Types.ProfileSnapshot, previous: Types.ProfileSnapshot?) whenever get() would return
-- something new: a snapshot from the server, a patch, or a patch running out.
ProfileController.onChanged = InputController.newSignal()

local snapshot: Types.ProfileSnapshot? = nil -- the server's latest, checked
local merged: Types.ProfileSnapshot? = nil -- the same with the waiting patches applied (what get() returns)
local patches: Patches = { settings = {}, favorites = {} }
local designerPart: Designer? = nil -- the designer's part of the server's latest snapshot (never patched)

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

local function wholeAtLeastZero(value: any): number
	return math.max(math.floor(numberOr(value, 0)), 0)
end

-- A checked copy of the snapshot's `fleet` field, or nil when there isn't one (a server without the fleet yet).
-- Pods and zones without a string id are left out (as are repeats of a uid or zone id); money and counts are
-- whole and never negative; the offline share stays within 0..1. The payload comes from our own server: this
-- only keeps a bad field from breaking the Fleet app.
function ProfileController.normalizeFleet(value: any): Fleet?
	if type(value) ~= "table" then
		return nil
	end
	local pods: { FleetPod } = {}
	local seenPods: { [string]: boolean } = {}
	if type(value.pods) == "table" then
		for _, pod in value.pods do
			if type(pod) == "table" and type(pod.uid) == "string" and type(pod.zone) == "string" then
				if not seenPods[pod.uid] then
					seenPods[pod.uid] = true
					table.insert(pods, { uid = pod.uid, zone = pod.zone })
				end
			end
		end
	end
	local zones: { FleetZone } = {}
	local seenZones: { [string]: boolean } = {}
	if type(value.zones) == "table" then
		for _, zone in value.zones do
			if type(zone) == "table" and type(zone.id) == "string" and not seenZones[zone.id] then
				seenZones[zone.id] = true
				table.insert(zones, {
					id = zone.id,
					name = stringOr(zone.name, zone.id),
					demand = math.max(numberOr(zone.demand, 0), 0),
					perHour = wholeAtLeastZero(zone.perHour),
				})
			end
		end
	end
	return {
		pods = pods,
		uncollected = wholeAtLeastZero(value.uncollected),
		slots = wholeAtLeastZero(value.slots),
		podPrice = wholeAtLeastZero(value.podPrice),
		sellBack = wholeAtLeastZero(value.sellBack),
		zones = zones,
		offlineRate = math.clamp(numberOr(value.offlineRate, 0), 0, 1),
		offlineCapHours = math.max(numberOr(value.offlineCapHours, 0), 0),
	}
end

-- The fleet a (normalized) snapshot carries, or nil.
function ProfileController.fleetOf(profile: Types.ProfileSnapshot?): Fleet?
	return if profile ~= nil then profile.fleet else nil
end

-- One design from the payload's `designs` (`uid` from the entry or, for a map, its key), or nil when it isn't one.
local function normalizeDesign(value: any, key: any): DesignInfo?
	if type(value) ~= "table" then
		return nil
	end
	local uid = if type(value.uid) == "string" then value.uid elseif type(key) == "string" then key else nil
	if uid == nil then
		return nil
	end
	local hidden = value.hidden == true
	local spec = if type(value.spec) == "table" then value.spec else nil
	local function text(field: any): string?
		return if type(field) == "string" and field ~= "" then field else nil
	end
	-- The server's name first (it already stands in a plain name for a hidden design); the spec's only when shown.
	local name = text(value.name) or (if spec ~= nil and not hidden then text(spec.name) else nil)
	local tagline = if hidden then nil else text(value.tagline) or (if spec ~= nil then text(spec.tagline) else nil)
	return {
		uid = uid,
		spec = spec,
		hidden = hidden,
		createdAt = numberOr(value.createdAt, 0),
		name = name,
		tagline = tagline,
	}
end

-- A checked copy of the designer's part of a ProfileSnapshot payload (see the header for the shapes it reads).
-- Never nil: a payload without designer fields means a balance of 0, the free car unused, no designs, no mods.
function ProfileController.normalizeDesigner(payload: any): Designer
	local raw = if type(payload) == "table" then payload else {}
	local credits = if type(raw.credits) == "table" then raw.credits else {}
	local designs: { [string]: DesignInfo } = {}
	local count = 0
	if type(raw.designs) == "table" then
		for key, value in raw.designs do
			local design = normalizeDesign(value, key)
			if design ~= nil and designs[design.uid] == nil then
				designs[design.uid] = design
				count += 1
			end
		end
	end
	local vehicleDesigns: { [string]: string } = {}
	local mods: { [string]: { [string]: any } } = {}
	if type(raw.vehicles) == "table" then
		for _, vehicle in raw.vehicles do
			if type(vehicle) == "table" and type(vehicle.uid) == "string" then
				if type(vehicle.designUid) == "string" then
					vehicleDesigns[vehicle.uid] = vehicle.designUid
				end
				if type(vehicle.mods) == "table" then
					mods[vehicle.uid] = vehicle.mods
				elseif vehicle.modded == true then
					mods[vehicle.uid] = {}
				end
			end
		end
	end
	if type(raw.mods) == "table" then
		for uid, spec in raw.mods do
			if type(uid) == "string" and type(spec) == "table" and mods[uid] == nil then
				mods[uid] = spec
			end
		end
	end
	local freeUsed = if type(credits.freeDesignUsed) == "boolean" then credits.freeDesignUsed else raw.freeDesignUsed
	return {
		balance = wholeAtLeastZero(credits.balance),
		freeDesignUsed = freeUsed == true,
		designs = designs,
		designCount = count,
		vehicleDesigns = vehicleDesigns,
		mods = mods,
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
		fleet = ProfileController.normalizeFleet(payload.fleet), -- Phase 9; merge's table.clone carries it over
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

-- The player's robotaxi fleet from the latest snapshot, or nil until one with a fleet arrives. Read-only.
function ProfileController.fleet(): Fleet?
	return ProfileController.fleetOf(merged)
end

-- The designer's part of the latest snapshot (credits, the free car, designs, mods), or nil until the first
-- snapshot arrives. Read-only. onChanged fires whenever it changes (it comes with every snapshot).
function ProfileController.designer(): Designer?
	return designerPart
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
		designerPart = ProfileController.normalizeDesigner(payload)
		refresh()
	end)
end

return ProfileController
