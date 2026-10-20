--!strict
-- A fresh PlayerData profile (PLAN.md §6; docs/phase-3-contracts.md "Player data").
--
-- Every field of Types.PlayerData is filled in, at Config/Data.schemaVersion, from Config/Economy (starting cash
-- and slots) and Config/Data (everything else). Each call builds brand-new tables, so two profiles never share
-- a table. Pure: no Roblox services, so tests/DataTemplate.spec.luau can check it in Edit mode.
--
-- Time fields: `Template.new()` stamps them with os.time(). DataService gives ProfileStore a template built with
-- `Template.UNSET_TIME` instead (ProfileStore copies that one template into every new profile, so its clock
-- would be the server's start time), then calls `Template.stamp` when a profile loads.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Data = require(ReplicatedStorage.Shared.Config.Data)
local Economy = require(ReplicatedStorage.Shared.Config.Economy)
local Types = require(ReplicatedStorage.Shared.Types)

local Template = {}

-- Marks a time field that hasn't been stamped yet. Real os.time() values are never 0.
Template.UNSET_TIME = 0

-- A complete profile at the current schema version. `now` (os.time() seconds) defaults to the current time.
function Template.new(now: number?): Types.PlayerData
	local stamp = if now ~= nil then now else os.time()
	local settings = Data.defaults.settings
	return {
		version = Data.schemaVersion,
		cash = Economy.startingCash,
		starterClaimed = false,
		vehicles = {},
		garageSlots = Economy.garageSlots,
		designs = {},
		customSlots = Economy.customSlots,
		credits = { balance = Data.defaults.credits, freeDesignUsed = false, reserved = {} },
		fleet = { pods = {}, lastCollectedAt = stamp },
		jobs = { xp = {}, licenses = {} },
		house = { upgrades = {} },
		stats = { milesDriven = 0, tripsCompleted = 0, playtimeSec = 0 },
		codesRedeemed = {},
		season = { id = "", xp = 0, premium = false, claimed = {} },
		streak = { lastDay = 0, count = 0 },
		offersSeen = {},
		club = {},
		receipts = {},
		pendingGrants = {},
		settings = { units = settings.units, camera = settings.camera, musicVolume = settings.musicVolume },
		firstJoinAt = stamp,
		boosts = {},
	}
end

-- Fills any time field still at UNSET_TIME with `now`. Returns true if it changed anything (a new profile).
function Template.stamp(data: Types.PlayerData, now: number): boolean
	local changed = false
	if data.firstJoinAt == Template.UNSET_TIME then
		data.firstJoinAt = now
		changed = true
	end
	if data.fleet.lastCollectedAt == Template.UNSET_TIME then
		data.fleet.lastCollectedAt = now
		changed = true
	end
	return changed
end

return Template
