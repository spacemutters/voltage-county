--!strict
-- Live feature flags (PLAN.md Phase 12; docs/phase-12-contracts.md "Live-ops"): a kill switch per feature.
--
--   isOn(name)            true when the feature is on: the DataStore override if it names `name`, else
--                         Config/FeatureFlags.defaults; a name in neither is off
--   onChanged(name, fn)   calls fn(on) whenever `name`'s answer changes; returns a function that stops it
--   refresh()             re-reads the override now (yields); the server also does it every
--                         Config/FeatureFlags.live.refreshSeconds, so a switch reaches every server within that
--   devSet(name, on?)     Studio only: overrides one flag on this server (nil clears it), for testing
--
-- The override is one value in a DataStore (Config/FeatureFlags.live; Studio uses its own store). A read that fails
-- keeps the last good override (the defaults until one has been read) and is reported once until a read works
-- again. Reads run on a slow config timer (CLAUDE.md hard rule 10 allows timers for config refresh); nothing here
-- runs per frame. Requiring this module touches no DataStore, so specs and other services can require it freely.
--
-- The decisions are pure helpers (resolve, clean, changes) so specs can check them in Edit mode.

local DataStoreService = game:GetService("DataStoreService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local FeatureFlags = require(ReplicatedStorage.Shared.Config.FeatureFlags)

export type Overrides = { [string]: boolean }
export type Listener = (on: boolean) -> ()

local LOG = "[FeatureFlagService]"

local FeatureFlagService = {}

local overrides: Overrides = {}
local devOverrides: Overrides = {} -- Studio only (devSet); win over the DataStore
local listeners: { [string]: { Listener } } = {}
local readWarned = false
local timer: thread? = nil

-- Pure helpers ----------------------------------------------------------------------------------------------

-- The answer for `name`: an override if it names it, else the default, else off.
function FeatureFlagService.resolve(defaults: { [string]: boolean }, current: Overrides, name: string): boolean
	local override = current[name]
	if type(override) == "boolean" then
		return override
	end
	return defaults[name] == true
end

-- An override table from an untrusted DataStore value: string keys with boolean values only.
function FeatureFlagService.clean(raw: any): Overrides
	local result: Overrides = {}
	if type(raw) ~= "table" then
		return result
	end
	for name, value in raw do
		if type(name) == "string" and type(value) == "boolean" then
			result[name] = value
		end
	end
	return result
end

-- Every flag whose answer differs between two override tables, with its new answer.
function FeatureFlagService.changes(defaults: { [string]: boolean }, before: Overrides, after: Overrides): Overrides
	local names: { [string]: boolean } = {}
	for name in defaults do
		names[name] = true
	end
	for name in before do
		names[name] = true
	end
	for name in after do
		names[name] = true
	end
	local changed: Overrides = {}
	for name in names do
		local was = FeatureFlagService.resolve(defaults, before, name)
		local now = FeatureFlagService.resolve(defaults, after, name)
		if was ~= now then
			changed[name] = now
		end
	end
	return changed
end

-- The live answers ------------------------------------------------------------------------------------------

local function effective(): Overrides
	local merged: Overrides = table.clone(overrides)
	for name, value in devOverrides do
		merged[name] = value
	end
	return merged
end

function FeatureFlagService.isOn(name: string): boolean
	return FeatureFlagService.resolve(FeatureFlags.defaults, effective(), name)
end

function FeatureFlagService.onChanged(name: string, fn: Listener): () -> ()
	local list = listeners[name]
	if list == nil then
		list = {}
		listeners[name] = list
	end
	table.insert(list, fn)
	return function()
		local current = listeners[name]
		local index = if current ~= nil then table.find(current, fn) else nil
		if current ~= nil and index ~= nil then
			table.remove(current, index)
		end
	end
end

local function announce(changed: Overrides)
	for name, on in changed do
		print(`{LOG} "{name}" is now {if on then "on" else "off"}`)
		for _, listener in listeners[name] or {} do
			task.spawn(function()
				local ok, err = xpcall(listener, debug.traceback, on)
				if not ok then
					warn(`{LOG} a listener for "{name}" failed: {err}`)
				end
			end)
		end
	end
end

-- Swaps in new overrides (from the DataStore or devSet) and tells the listeners what changed.
local function apply(newOverrides: Overrides?, newDev: Overrides?)
	local before = effective()
	if newOverrides ~= nil then
		overrides = newOverrides
	end
	if newDev ~= nil then
		devOverrides = newDev
	end
	announce(FeatureFlagService.changes(FeatureFlags.defaults, before, effective()))
end

local function storeName(): string
	return if RunService:IsStudio() then FeatureFlags.live.studioStore else FeatureFlags.live.store
end

-- Re-reads the override from the DataStore (yields). False when the read failed (the last good one stays).
function FeatureFlagService.refresh(): boolean
	local ok, result = pcall(function(): any
		return DataStoreService:GetDataStore(storeName()):GetAsync(FeatureFlags.live.key)
	end)
	if not ok then
		if not readWarned then
			readWarned = true
			warn(`{LOG} couldn't read the flag override (keeping the last good one): {result}`)
		end
		return false
	end
	readWarned = false
	apply(FeatureFlagService.clean(result), nil)
	return true
end

-- Studio only: overrides `name` on this server (nil clears it). Never touches the DataStore.
function FeatureFlagService.devSet(name: string, on: boolean?): boolean
	if not RunService:IsStudio() then
		warn(`{LOG} devSet only works in Studio`)
		return false
	end
	local nextDev = table.clone(devOverrides)
	if on == nil then
		nextDev[name] = nil
	else
		nextDev[name] = on
	end
	apply(nil, nextDev)
	return true
end

-- Boot ------------------------------------------------------------------------------------------------------

local function tick()
	timer = task.delay(FeatureFlags.live.refreshSeconds, tick)
	FeatureFlagService.refresh()
end

function FeatureFlagService:Start()
	if timer == nil then
		task.spawn(tick)
	end
end

return FeatureFlagService
