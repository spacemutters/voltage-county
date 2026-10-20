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

export type Step = (data: { [string]: any }) -> ()

local Migrations = {}

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
