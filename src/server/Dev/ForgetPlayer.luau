--!strict
-- ForgetPlayer: takes one player out of the game's records that their save doesn't hold, for Roblox's daily "right
-- to be forgotten" message and for a player's or a parent's own request (docs/LAUNCH.md step 7; docs/privacy.html
-- "Deleting your data"; docs/COMPLIANCE.md section 8). Roblox's deletion templates (LAUNCH step 7) remove the
-- PlayerData save and the AdRewards row; this does what a template can't, for one UserId:
--   1 drag strip   their best time on every weekly board: one OrderedDataStore per ISO week (Config/DragStrip
--                  storePrefix .. week, keyed by UserId), from SETTINGS.firstBoardUtc to this week
--   2 serials      their UserId in each limited drop's and cosmetic's owners map (Config/Limiteds; LimitedService)
--                  becomes "forgotten_<serial>": the number stays taken, so serials stay unique, and no longer
--                  names them (`sold` is untouched)
--   3 design log   their salted hash (DesignerService.hashFor with the DesignerSalt DataStore's salt) and the SQL
--                  that deletes their vc_designer_usage rows. The game can't reach the database: Claude runs the
--                  SQL on Supabase. vc_designs has no player hash, so nothing there names them.
-- With { save = true } it also removes the save (PlayerData Player_<id>) and the AdRewards row, for a request that
-- comes without an account deletion (no template fires then). Only for a player who isn't in a live server.
--
-- Edit-mode tool only (CLAUDE.md hard rules 8 and 9): the published place with Studio API access on. It works on
-- the LIVE stores (the names a live server uses, never the Studio ones) unless { studio = true }. First look, then
-- apply. From MCP execute_luau (Edit datamodel) or the command bar:
--   require(game.ServerScriptService.Server.Dev.ForgetPlayer).run(<userId>)                    -- reports only
--   require(game.ServerScriptService.Server.Dev.ForgetPlayer).run(<userId>, { apply = true })  -- removes
-- Safe to run again: a second run finds nothing left. A DataStore call that fails is listed in `errors` (run it
-- again). forget(userId, options, deps) is the same with the stores passed in (tests/ForgetPlayer.spec).

local DataStoreService = game:GetService("DataStoreService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage.Shared
local Ads = require(Shared.Config.Ads)
local Data = require(Shared.Config.Data)
local Designer = require(Shared.Config.Designer)
local DragStrip = require(Shared.Config.DragStrip)
local Limiteds = require(Shared.Config.Limiteds)
local DesignerService = require(ServerScriptService.Server.Services.DesignerService)
local LimitedService = require(ServerScriptService.Server.Services.LimitedService)

local SETTINGS = {
	-- The first week a weekly drag strip board can hold a time: the Monday of the week the drag strip shipped
	-- (2026-10-19 00:00 UTC, Phase 10). An earlier week only costs a read.
	firstBoardUtc = 1792368000,
	-- What replaces a forgotten player's UserId in a serial owners map, followed by the serial.
	forgottenOwnerPrefix = "forgotten_",
	-- The design service's request log and its player-hash column (backend/supabase/migrations/0001_designer.sql).
	usageTable = "public.vc_designer_usage",
	usageHashColumn = "user_hash",
}

local LOG = "[ForgetPlayer]"
local SECONDS_PER_WEEK = 7 * 86400
local HASH_LENGTH = 64 -- Util/Sha256 hex

-- What ForgetPlayer needs of a DataStore or an OrderedDataStore.
export type Store = {
	GetAsync: (self: any, key: string) -> any,
	RemoveAsync: (self: any, key: string) -> any,
	UpdateAsync: (self: any, key: string, transform: (old: any) -> any) -> any,
}

export type Deps = {
	ordered: (name: string) -> Store, -- an OrderedDataStore by name
	standard: (name: string) -> Store, -- a DataStore by name
	now: () -> number, -- os.time()
}

export type Options = {
	apply: boolean?, -- remove and rename (default: only report)
	studio: boolean?, -- the Studio stores instead of the live ones
	save: boolean?, -- also the save and the AdRewards row
}

export type Report = {
	ok: boolean, -- every DataStore call answered
	applied: boolean,
	userId: number,
	weeks: { string }, -- drag strip weeks that held their time (removed when applied)
	serials: { string }, -- "<store key> #<serial>" owner entries that named them (renamed when applied)
	save: { string }, -- "<store> <key>" rows that held their save or ad row (removed when applied), with save = true
	userHash: string?, -- nil when the salt couldn't be read
	sql: string?, -- the delete for the design service's rows (Claude runs it on Supabase)
	errors: { string },
}

local ForgetPlayer = {}
ForgetPlayer.SETTINGS = SETTINGS

-- Pure helpers ----------------------------------------------------------------------------------------------------

-- Every ISO week key from the week of `fromUnix` to the week of `toUnix`, oldest first, each once.
function ForgetPlayer.weekKeys(fromUnix: number, toUnix: number): { string }
	local keys: { string } = {}
	local seen: { [string]: boolean } = {}
	local function add(at: number)
		local key = DragStrip.weekKey(at)
		if not seen[key] then
			seen[key] = true
			table.insert(keys, key)
		end
	end
	local at = fromUnix
	while at <= toUnix do
		add(at)
		at += SECONDS_PER_WEEK
	end
	if fromUnix <= toUnix then
		add(toUnix)
	end
	return keys
end

-- The owner key that replaces a forgotten player's UserId: it keeps their serial taken without naming them.
function ForgetPlayer.placeholder(serial: number): string
	return SETTINGS.forgottenOwnerPrefix .. tostring(serial)
end

-- The UpdateAsync transform for one serial counter: the record with `userKey`'s entry renamed to its placeholder,
-- and their serial. Nil and nil when the record doesn't name them (UpdateAsync then writes nothing).
function ForgetPlayer.forgetOwner(raw: any, userKey: string): (LimitedService.Record?, number?)
	local record = LimitedService.cleanRecord(raw)
	local serial = record.owners[userKey]
	if serial == nil then
		return nil, nil
	end
	record.owners[userKey] = nil
	record.owners[ForgetPlayer.placeholder(serial)] = serial
	return record, serial
end

-- The SQL that deletes a player's rows from the design service's request log, or nil for a malformed hash.
function ForgetPlayer.usageSql(hash: string): string?
	if #hash ~= HASH_LENGTH or string.find(hash, "^%x+$") == nil then
		return nil
	end
	return `delete from {SETTINGS.usageTable} where {SETTINGS.usageHashColumn} = '{string.lower(hash)}';`
end

-- The flow ----------------------------------------------------------------------------------------------------------

local function call(report: Report, what: string, fn: () -> ...any): (boolean, any)
	local ok, result = pcall(fn)
	if not ok then
		table.insert(report.errors, `{what}: {result}`)
	end
	return ok, result
end

-- Removes (or with apply off, looks for) one row of a standard DataStore and lists it when it was there.
local function removeRow(report: Report, deps: Deps, label: string, key: string, apply: boolean)
	local ok, value = call(report, `{label} {key}`, function(): any
		local store = deps.standard(label)
		return if apply then store:RemoveAsync(key) else store:GetAsync(key)
	end)
	if ok and value ~= nil then
		table.insert(report.save, `{label} {key}`)
	end
end

-- Forgets `userId` in the stores `deps` gives (yields once per DataStore call). See the header for the steps.
function ForgetPlayer.forget(userId: number, options: Options?, deps: Deps): Report
	local opts: Options = options or {}
	local apply = opts.apply == true
	local studio = opts.studio == true
	local userKey = tostring(userId)
	local report: Report = {
		ok = true,
		applied = apply,
		userId = userId,
		weeks = {},
		serials = {},
		save = {},
		userHash = nil,
		sql = nil,
		errors = {},
	}

	-- 1 The weekly drag strip boards.
	local prefix = if studio then DragStrip.studioStorePrefix else DragStrip.storePrefix
	for _, week in ForgetPlayer.weekKeys(SETTINGS.firstBoardUtc, deps.now()) do
		local ok, value = call(report, `{prefix}{week}`, function(): any
			local board = deps.ordered(prefix .. week)
			return if apply then board:RemoveAsync(userKey) else board:GetAsync(userKey)
		end)
		if ok and value ~= nil then
			table.insert(report.weeks, week)
		end
	end

	-- 2 The serial ledger: every drop and cosmetic has its own counter key.
	local serialStoreName = if studio then Limiteds.studioStore else Limiteds.store
	local keyPrefix = if studio then Limiteds.studioKeyPrefix else Limiteds.keyPrefix
	local ids: { string } = {}
	for id in Limiteds.drops do
		table.insert(ids, id)
	end
	for id in Limiteds.cosmetics do
		table.insert(ids, id)
	end
	table.sort(ids)
	for _, id in ids do
		local key = keyPrefix .. id
		local found: number? = nil
		call(report, key, function()
			-- Fetched inside the call, so a DataStore Studio can't reach is listed rather than stopping the run.
			local serialStore = deps.standard(serialStoreName)
			if apply then
				serialStore:UpdateAsync(key, function(old: any): any
					local record, serial = ForgetPlayer.forgetOwner(old, userKey)
					found = serial
					return record
				end)
			else
				local _, serial = ForgetPlayer.forgetOwner(serialStore:GetAsync(key), userKey)
				found = serial
			end
		end)
		if found ~= nil then
			table.insert(report.serials, `{key} #{found}`)
		end
	end

	-- 3 The design service's rows, found by the salted hash (the salt store is the same in Studio and live).
	local ok, salt = call(report, Designer.salt.store, function(): any
		return deps.standard(Designer.salt.store):GetAsync(Designer.salt.key)
	end)
	-- No salt at all means no request ever left the game, so there are no rows to delete (userHash stays nil).
	if ok and type(salt) == "string" and salt ~= "" then
		local hash = DesignerService.hashFor(salt, userId)
		report.userHash = hash
		report.sql = ForgetPlayer.usageSql(hash)
	end

	-- The save and the ad row, only when asked.
	if opts.save == true then
		local dataStore = if studio then Data.studioStoreName else Data.storeName
		removeRow(report, deps, dataStore, Data.profileKeyPrefix .. userKey, apply)
		local rewarded = Ads.rewardedVideo
		local adStore = if studio then rewarded.studioStore else rewarded.store
		removeRow(report, deps, adStore, rewarded.keyPrefix .. userKey, apply)
	end

	report.ok = #report.errors == 0
	return report
end

local function liveDeps(): Deps
	return {
		ordered = function(name: string): Store
			return DataStoreService:GetOrderedDataStore(name) :: any
		end,
		standard = function(name: string): Store
			return DataStoreService:GetDataStore(name) :: any
		end,
		now = function(): number
			return os.time()
		end,
	}
end

local function listed(items: { string }): string
	return if #items == 0 then "none" else table.concat(items, ", ")
end

-- Forgets `userId` in the real DataStores, prints what it found or did, and returns the report. Studio only.
function ForgetPlayer.run(userId: number, options: Options?): Report?
	if not RunService:IsStudio() then
		warn(`{LOG} runs only in Studio`)
		return nil
	end
	if type(userId) ~= "number" or userId < 1 or userId % 1 ~= 0 then
		warn(`{LOG} give a UserId (a whole number)`)
		return nil
	end
	local report = ForgetPlayer.forget(userId, options, liveDeps())
	local verb = if report.applied then "removed" else "found (nothing changed; run with { apply = true })"
	print(`{LOG} {userId}: drag strip weeks {verb}: {listed(report.weeks)}`)
	print(`{LOG} {userId}: serials {if report.applied then "renamed" else "found"}: {listed(report.serials)}`)
	if options ~= nil and options.save == true then
		print(`{LOG} {userId}: save rows {if report.applied then "removed" else "found"}: {listed(report.save)}`)
	end
	if report.sql ~= nil then
		print(`{LOG} {userId}: design service rows: run on Supabase: {report.sql}`)
	elseif #report.errors == 0 then
		print(`{LOG} {userId}: design service rows: no salt, so no request ever left the game`)
	end
	for _, problem in report.errors do
		warn(`{LOG} {userId}: couldn't reach {problem}`)
	end
	print(`{LOG} {userId}: {if report.ok then "done" else "some stores didn't answer; run it again"}`)
	return report
end

return ForgetPlayer
