--!strict
-- Ordered PlayerData migrations (CLAUDE.md hard rule 7; docs/phase-3-contracts.md "Player data").
--
-- `steps[v]` upgrades a save from version v to v + 1, in place. `run` applies them one at a time until the
-- save reaches Config/Data.schemaVersion. Rules for every step:
--   - only add or reshape fields; never drop a field a player owns
--   - be safe on data that already has the new field (keep what's there)
-- A save with no `version` field predates versioning and counts as Config/Data.unversionedVersion. A save at a
-- higher version than this code knows was written by a newer server: `run` refuses it (errors) rather than
-- risk losing fields it doesn't understand.
--
-- Pure: no Roblox services, so tests/Migrations.spec.luau can run it in Edit mode.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Catalog = require(ReplicatedStorage.Shared.Vehicle.Catalog)
local Data = require(ReplicatedStorage.Shared.Config.Data)
local Template = require(script.Parent.Template) -- UNSET_TIME only

export type Step = (data: { [string]: any }) -> ()

local Migrations = {}

local function isFinite(value: any): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

-- What a car saved before version 3 cost: the catalog's total price for its trim (an upgrade trim includes the
-- trim it upgrades), or 0 when it was never sold for cash (the free starter, a player design, a limited drop)
-- or the save names a vehicle or trim the catalog no longer has.
local function pricePaid(vehicle: { [string]: any }): number
	local vehicleId, trim = vehicle.vehicleId, vehicle.trim
	if type(vehicleId) ~= "string" or type(trim) ~= "string" then
		return 0
	end
	return Catalog.totalPrice(vehicleId, trim) or 0
end

-- Keyed by the version a step upgrades FROM.
Migrations.steps = {
	-- 1 -> 2: timed earnings boosts from codes (Types.Boost).
	[1] = function(data: { [string]: any })
		if type(data.boosts) ~= "table" then
			data.boosts = {}
		end
	end,

	-- 2 -> 3: every owned car gains `favorite` (false) and `paid` (the catalog price of its trim, or 0). A car
	-- that already has either keeps it. A save with no vehicles list is left for Reconcile to fill in.
	[2] = function(data: { [string]: any })
		local vehicles = data.vehicles
		if type(vehicles) ~= "table" then
			return
		end
		for _, vehicle in vehicles do
			if type(vehicle) == "table" then
				if type(vehicle.favorite) ~= "boolean" then
					vehicle.favorite = false
				end
				if type(vehicle.paid) ~= "number" then
					vehicle.paid = pricePaid(vehicle)
				end
			end
		end
	end,

	-- 3 -> 4: every owned car gains `energy`, a full charge or tank (Config/Data.defaults.vehicleEnergy). A car
	-- that already has a usable level keeps it (pulled into 0..1); a level that isn't a number (or is NaN) is
	-- replaced by a full one. A save with no vehicles list is left for Reconcile to fill in.
	[3] = function(data: { [string]: any })
		local vehicles = data.vehicles
		if type(vehicles) ~= "table" then
			return
		end
		for _, vehicle in vehicles do
			if type(vehicle) == "table" then
				local energy = vehicle.energy
				if type(energy) ~= "number" or energy ~= energy then
					vehicle.energy = Data.defaults.vehicleEnergy
				else
					vehicle.energy = math.clamp(energy, 0, 1)
				end
			end
		end
	end,

	-- 4 -> 5 (Phase 7, the Wrap & Tint shop): every owned car gains `caliper` and `plateFormat` (the stock look,
	-- Config/Data.defaults.vehicleLook) and `extras`, an empty list of kit extras. A car that already has a value
	-- of the right type keeps it; one of the wrong type is replaced by the default. Paint "white" becomes
	-- "factory" (Config/Customization): before the shop nobody could choose a paint, so "white" only ever meant
	-- "as built", and keeping it would repaint every brand-colored car white. Every other look field (finish,
	-- wrap, wheels, rideHeight, tint, plateText) is left exactly as it was. A save with no vehicles list is left
	-- for Reconcile to fill in.
	[4] = function(data: { [string]: any })
		local vehicles = data.vehicles
		if type(vehicles) ~= "table" then
			return
		end
		local look = Data.defaults.vehicleLook
		for _, vehicle in vehicles do
			if type(vehicle) == "table" then
				if type(vehicle.caliper) ~= "string" then
					vehicle.caliper = look.caliper
				end
				if type(vehicle.extras) ~= "table" then
					vehicle.extras = {}
				end
				if type(vehicle.plateFormat) ~= "string" then
					vehicle.plateFormat = look.plateFormat
				end
				if vehicle.paint == look.oldDefaultPaint then
					vehicle.paint = look.paint
				end
			end
		end
	end,

	-- 5 -> 6 (Phase 9, the robotaxi fleet): the fleet gains `uncollected` (0, nothing earned yet) and
	-- `lastOnlineAt`, left unset (Template.UNSET_TIME) so DataService's Template.stamp sets it to the join time and
	-- the save earns nothing for the time before (nobody could own a pod before this version). Values already there
	-- are kept when usable: an uncollected amount that isn't a finite number of at least 0 becomes 0, and a
	-- lastOnlineAt that isn't a finite number is unset. Pods and lastCollectedAt are left exactly as they were. A
	-- save with no fleet is left for Reconcile to fill in; a fleet that isn't a table (it can hold nothing a player
	-- owns) is replaced by an empty one.
	[5] = function(data: { [string]: any })
		local fleet = data.fleet
		if fleet == nil then
			return
		end
		if type(fleet) ~= "table" then
			data.fleet = {
				pods = {},
				lastCollectedAt = Template.UNSET_TIME,
				uncollected = 0,
				lastOnlineAt = Template.UNSET_TIME,
			}
			return
		end
		local uncollected = fleet.uncollected
		if not isFinite(uncollected) or uncollected < 0 then
			fleet.uncollected = 0
		end
		if not isFinite(fleet.lastOnlineAt) then
			fleet.lastOnlineAt = Template.UNSET_TIME
		end
	end,
} :: { [number]: Step }

-- The version a save claims (a missing field counts as unversionedVersion); nil if the field is unusable.
local function versionOf(data: { [string]: any }): number?
	local version = data.version
	if version == nil then
		return Data.unversionedVersion
	end
	if type(version) ~= "number" or version ~= version or version % 1 ~= 0 or version < 1 then
		return nil
	end
	return version
end

-- Upgrades `data` in place to Config/Data.schemaVersion and returns it with the version it started at.
-- Idempotent at the latest version. Errors, before changing anything, on an invalid version or one newer than
-- the code knows. A missing step also errors, possibly after earlier steps ran, so callers that must not keep a
-- partial upgrade should migrate a copy (DataService does).
function Migrations.run(data: { [string]: any }): ({ [string]: any }, number)
	local fromVersion = versionOf(data)
	if fromVersion == nil then
		error(`invalid PlayerData version {tostring(data.version)}`, 2)
	end
	local latest = Data.schemaVersion
	if fromVersion > latest then
		error(`PlayerData version {fromVersion} is newer than this server knows ({latest})`, 2)
	end

	local version = fromVersion
	while version < latest do
		local step = Migrations.steps[version]
		if step == nil then
			error(`no PlayerData migration from version {version}`, 2)
		end
		step(data)
		version += 1
		data.version = version
	end
	data.version = latest -- an unversioned save at the latest version still gets its field
	return data, fromVersion
end

return Migrations
