--!strict
-- Scheduled events (PLAN.md Phase 12; docs/phase-12-contracts.md "Live-ops"): banners, the featured dealership
-- pad, earnings multipliers, bonus-credit weekends and countdowns, on the UTC schedule in Config/Events plus extra
-- events read from a DataStore key, so events switch on (and new ones appear) without a server restart.
--
--   active(now?)              the events running now, soonest-started first (none while the "events" flag is off)
--   upcoming(now?)            events starting within Config/Events.upcoming.windowSeconds, for countdowns
--   earningsMultiplier(now?)  what every earning path is multiplied by (1 = no event): EconomyService adds it to
--                             its boost path, so it stacks with code boosts under the same cap
--   bonusCredits(now?)        the extra share of credits every credit pack gives (0 = none, 0.5 = +50%);
--                             MonetizationService rounds pack credits x this down to whole credits
--   featuredVehicleId(now?)   the Config/Vehicles id whose dealership pad gets the spotlight, or nil
--   payload(now?)             what Net EventUpdate carries (below)
--   onChanged(fn)             fn(payload) whenever what is running (or counting down) changes; returns a stop function
--   setClock(fn)              Studio only: a different clock (os.time() seconds) for playtesting a schedule
--
-- Net EventUpdate (server -> every client; to each player as they join, and to everyone whenever it changes):
--   { now, active = { PublicEvent }, upcoming = { PublicEvent }, drops = { LimitedService.publicDrops() } }
-- PublicEvent = { id, name, banner?, startsAt, endsAt, featuredVehicleId?, earningsMultiplier?, bonusCredits?,
-- bonusPercent? } (bonusCredits is a share, 0.5 = +50%; bonusPercent the same as a whole percentage).
-- Times are Unix seconds (UTC); a client counts down against Workspace:GetServerTimeNow().
--
-- The timer: one task.delay that wakes at the next start or end (so an event switches on exactly on time) and at
-- least every Config/Events.live.refreshSeconds to re-read the DataStore events. Config refresh on a slow timer,
-- not a gameplay poll (CLAUDE.md hard rule 10). The rules are pure helpers taking the time as an argument
-- (validate, merge, activeAt, upcomingAt, combineMultipliers, combineShares, earningsMultiplierAt,
-- bonusCreditsAt, nextChangeAt) so tests/Events.spec checks them under a fake clock in Edit mode.

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Catalog = require(ReplicatedStorage.Shared.Vehicle.Catalog)
local Events = require(ReplicatedStorage.Shared.Config.Events)
local FeatureFlags = require(ReplicatedStorage.Shared.Config.FeatureFlags)
local Net = require(ReplicatedStorage.Shared.Net)

export type Event = Events.Event
export type Stacking = Events.Stacking
export type Clock = () -> number

export type PublicEvent = {
	id: string,
	name: string,
	banner: string?,
	startsAt: number,
	endsAt: number,
	featuredVehicleId: string?,
	earningsMultiplier: number?,
	bonusCredits: number?, -- a share: 0.5 = +50% credits on every credit pack
	bonusPercent: number?, -- the same as a whole percentage (50), for the banner's words
}

export type Payload = {
	now: number,
	active: { PublicEvent },
	upcoming: { PublicEvent },
	drops: { any },
}

local LOG = "[EventService]"
local FLAG = "events" -- Config/FeatureFlags name
local ID_PATTERN = "^[%w_]+$"
local MAX_ID_LENGTH = 40 -- Net's id length
local MAX_TEXT_LENGTH = 200
local MIN_WAIT_SECONDS = 1 -- the timer never re-arms sooner than this (os.time() has whole-second steps)
local PERCENT = 100

local EventService = {}

local clock: Clock = os.time
local liveEvents: { Event } = {}
local lastLiveRead: number? = nil
local readWarned = false
local timer: thread? = nil
local lastSignature: string? = nil
local listeners: { (payload: Payload) -> () } = {}
local flagService: any = nil -- Services/FeatureFlagService
local limitedService: any = nil -- Services/LimitedService (drop countdowns in the payload)

-- Pure helpers ----------------------------------------------------------------------------------------------

local function isFinite(value: any): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function optionalText(value: any): (boolean, string?)
	if value == nil then
		return true, nil
	end
	if type(value) ~= "string" or #value == 0 or #value > MAX_TEXT_LENGTH then
		return false, nil
	end
	return true, value
end

-- A clean copy of an event from an untrusted value (a DataStore entry), or nil and why it was refused.
function EventService.validate(raw: any): (Event?, string?)
	if type(raw) ~= "table" then
		return nil, "not a table"
	end
	local id = raw.id
	if type(id) ~= "string" or #id == 0 or #id > MAX_ID_LENGTH or string.match(id, ID_PATTERN) == nil then
		return nil, "bad id"
	end
	local nameOk, name = optionalText(raw.name)
	if not nameOk or name == nil then
		return nil, `{id}: bad name`
	end
	if not isFinite(raw.startsAtUtc) or not isFinite(raw.endsAtUtc) or raw.endsAtUtc <= raw.startsAtUtc then
		return nil, `{id}: bad times`
	end
	local bannerOk, banner = optionalText(raw.banner)
	if not bannerOk then
		return nil, `{id}: bad banner`
	end
	local featured = raw.featuredVehicleId
	if featured ~= nil and (type(featured) ~= "string" or Catalog.getVehicle(featured) == nil) then
		return nil, `{id}: unknown featured vehicle`
	end
	local multiplier = raw.earningsMultiplier
	if multiplier ~= nil and (not isFinite(multiplier) or multiplier < 1) then
		return nil, `{id}: earningsMultiplier must be at least 1`
	end
	local bonus = raw.bonusCredits
	if bonus ~= nil and (not isFinite(bonus) or bonus < 0) then
		return nil, `{id}: bonusCredits must be at least 0`
	end
	return {
		id = id,
		name = name,
		startsAtUtc = raw.startsAtUtc,
		endsAtUtc = raw.endsAtUtc,
		banner = banner,
		featuredVehicleId = featured,
		earningsMultiplier = multiplier,
		bonusCredits = bonus,
	},
		nil
end

-- The config schedule with the live events on top: a live event with the same id as a config one replaces it
-- (to move or extend it).
function EventService.merge(schedule: { Event }, extra: { Event }): { Event }
	local byId: { [string]: boolean } = {}
	for _, event in extra do
		byId[event.id] = true
	end
	local result: { Event } = {}
	for _, event in schedule do
		if not byId[event.id] then
			table.insert(result, event)
		end
	end
	for _, event in extra do
		table.insert(result, event)
	end
	return result
end

-- True while `event` runs at `now`: from its start up to, not including, its end.
function EventService.isRunning(event: Event, now: number): boolean
	return event.startsAtUtc <= now and now < event.endsAtUtc
end

local function byStart(a: Event, b: Event): boolean
	if a.startsAtUtc ~= b.startsAtUtc then
		return a.startsAtUtc < b.startsAtUtc
	end
	return a.id < b.id
end

-- The events running at `now`, soonest-started first.
function EventService.activeAt(schedule: { Event }, now: number): { Event }
	local result: { Event } = {}
	for _, event in schedule do
		if EventService.isRunning(event, now) then
			table.insert(result, event)
		end
	end
	table.sort(result, byStart)
	return result
end

-- Events that haven't started at `now` but start within `windowSeconds`, soonest first, at most `max`.
function EventService.upcomingAt(schedule: { Event }, now: number, windowSeconds: number, max: number): { Event }
	local result: { Event } = {}
	for _, event in schedule do
		if event.startsAtUtc > now and event.startsAtUtc - now <= windowSeconds then
			table.insert(result, event)
		end
	end
	table.sort(result, byStart)
	while #result > max do
		table.remove(result)
	end
	return result
end

-- Combines earnings multipliers (each at least 1) the Config/Events way, never above `cap`. None gives 1.
function EventService.combineMultipliers(values: { number }, stacking: Stacking, cap: number): number
	local combined = 1
	for _, value in values do
		if stacking == "add" then
			combined += value - 1
		elseif stacking == "multiply" then
			combined *= value
		else
			combined = math.max(combined, value)
		end
	end
	return math.min(combined, cap)
end

-- Combines bonus shares (each at least 0) the Config/Events way, never above `cap`. None gives 0.
function EventService.combineShares(values: { number }, stacking: Stacking, cap: number): number
	local combined = 0
	for _, value in values do
		if stacking == "add" then
			combined += value
		elseif stacking == "multiply" then
			combined = (1 + combined) * (1 + value) - 1
		else
			combined = math.max(combined, value)
		end
	end
	return math.min(combined, cap)
end

-- What every earning path is multiplied by at `now`. `stacking` and `cap` default to Config/Events.
function EventService.earningsMultiplierAt(schedule: { Event }, now: number, stacking: Stacking?, cap: number?): number
	local values: { number } = {}
	for _, event in EventService.activeAt(schedule, now) do
		local value = event.earningsMultiplier
		if value ~= nil and value > 1 then
			table.insert(values, value)
		end
	end
	return EventService.combineMultipliers(
		values,
		stacking or Events.stacking.earnings,
		cap or Events.maxEarningsMultiplier
	)
end

-- The extra share of credits every credit pack gives at `now`. `stacking` and `cap` default to Config/Events.
function EventService.bonusCreditsAt(schedule: { Event }, now: number, stacking: Stacking?, cap: number?): number
	local values: { number } = {}
	for _, event in EventService.activeAt(schedule, now) do
		local value = event.bonusCredits
		if value ~= nil and value > 0 then
			table.insert(values, value)
		end
	end
	return EventService.combineShares(values, stacking or Events.stacking.credits, cap or Events.maxBonusCredits)
end

-- The next start or end after `now`, or nil when nothing is left to change.
function EventService.nextChangeAt(schedule: { Event }, now: number): number?
	local soonest: number? = nil
	for _, event in schedule do
		for _, at in { event.startsAtUtc, event.endsAtUtc } do
			if at > now and (soonest == nil or at < soonest) then
				soonest = at
			end
		end
	end
	return soonest
end

local function public(event: Event): PublicEvent
	return {
		id = event.id,
		name = event.name,
		banner = event.banner,
		startsAt = event.startsAtUtc,
		endsAt = event.endsAtUtc,
		featuredVehicleId = event.featuredVehicleId,
		earningsMultiplier = event.earningsMultiplier,
		bonusCredits = event.bonusCredits,
		bonusPercent = if event.bonusCredits ~= nil then math.round(event.bonusCredits * PERCENT) else nil,
	}
end

-- The EventUpdate payload for a schedule at `now` (drops are added by the live service).
function EventService.payloadAt(schedule: { Event }, now: number, enabled: boolean): Payload
	local active: { PublicEvent } = {}
	local upcoming: { PublicEvent } = {}
	if enabled then
		for _, event in EventService.activeAt(schedule, now) do
			table.insert(active, public(event))
		end
		local window = Events.upcoming
		for _, event in EventService.upcomingAt(schedule, now, window.windowSeconds, window.max) do
			table.insert(upcoming, public(event))
		end
	end
	return { now = now, active = active, upcoming = upcoming, drops = {} }
end

-- The live schedule ---------------------------------------------------------------------------------------

local function enabled(): boolean
	local service = flagService
	if service ~= nil then
		local ok, on = pcall(service.isOn, FLAG)
		if ok and type(on) == "boolean" then
			return on
		end
	end
	return FeatureFlags.defaults[FLAG] == true
end

local function schedule(): { Event }
	return EventService.merge(Events.schedule, liveEvents)
end

function EventService.now(): number
	return clock()
end

function EventService.active(now: number?): { Event }
	if not enabled() then
		return {}
	end
	return EventService.activeAt(schedule(), now or clock())
end

function EventService.upcoming(now: number?): { Event }
	if not enabled() then
		return {}
	end
	local window = Events.upcoming
	return EventService.upcomingAt(schedule(), now or clock(), window.windowSeconds, window.max)
end

function EventService.earningsMultiplier(now: number?): number
	if not enabled() then
		return 1
	end
	return EventService.earningsMultiplierAt(schedule(), now or clock())
end

function EventService.bonusCredits(now: number?): number
	if not enabled() then
		return 0
	end
	return EventService.bonusCreditsAt(schedule(), now or clock())
end

function EventService.featuredVehicleId(now: number?): string?
	for _, event in EventService.active(now) do
		if event.featuredVehicleId ~= nil then
			return event.featuredVehicleId
		end
	end
	return nil
end

local function drops(now: number): { any }
	local service = limitedService
	if service == nil or type(service.publicDrops) ~= "function" then
		return {}
	end
	local ok, result = pcall(service.publicDrops, now)
	return if ok and type(result) == "table" then result else {}
end

function EventService.payload(now: number?): Payload
	local at = now or clock()
	local result = EventService.payloadAt(schedule(), at, enabled())
	result.drops = drops(at)
	return result
end

function EventService.onChanged(fn: (payload: Payload) -> ()): () -> ()
	table.insert(listeners, fn)
	return function()
		local index = table.find(listeners, fn)
		if index ~= nil then
			table.remove(listeners, index)
		end
	end
end

-- What players see, as one string: a change in it means a new EventUpdate.
local function signature(payload: Payload): string
	local parts: { string } = {}
	for _, list in { payload.active, payload.upcoming } do
		for _, event in list do
			table.insert(parts, `{event.id}@{event.startsAt}-{event.endsAt}`)
		end
		table.insert(parts, "|")
	end
	for _, drop in payload.drops do
		if type(drop) == "table" then
			table.insert(parts, `{drop.id}:{drop.open}:{drop.remaining}`)
		end
	end
	return table.concat(parts, ",")
end

-- Sends the current payload to everyone (and the listeners) when it changed, or always with `force`.
function EventService.publish(force: boolean?)
	local payload = EventService.payload()
	local sig = signature(payload)
	if not force and sig == lastSignature then
		return
	end
	lastSignature = sig
	Net.fireAllClients("EventUpdate", payload)
	for _, listener in listeners do
		task.spawn(function()
			local ok, err = xpcall(listener, debug.traceback, payload)
			if not ok then
				warn(`{LOG} an onChanged listener failed: {err}`)
			end
		end)
	end
end

local function storeName(): string
	return if RunService:IsStudio() then Events.live.studioStore else Events.live.store
end

-- Re-reads the DataStore events (yields). A failed read keeps the last good list.
local function readLive()
	local ok, raw = pcall(function(): any
		return DataStoreService:GetDataStore(storeName()):GetAsync(Events.live.key)
	end)
	if not ok then
		if not readWarned then
			readWarned = true
			warn(`{LOG} couldn't read live events (keeping the last good list): {raw}`)
		end
		return
	end
	readWarned = false
	local clean: { Event } = {}
	if type(raw) == "table" then
		for _, entry in raw do
			if #clean >= Events.maxLiveEvents then
				warn(`{LOG} more than {Events.maxLiveEvents} live events; the rest are ignored`)
				break
			end
			local event, problem = EventService.validate(entry)
			if event ~= nil then
				table.insert(clean, event)
			else
				warn(`{LOG} skipped a live event: {problem}`)
			end
		end
	end
	liveEvents = clean
end

-- Studio only: a different clock for playtesting a schedule (e.g. function() return os.time() + 86400 end).
function EventService.setClock(fn: Clock): boolean
	if not RunService:IsStudio() then
		warn(`{LOG} setClock only works in Studio`)
		return false
	end
	clock = fn
	EventService.publish()
	return true
end

-- The timer: wakes at the next start or end (and at least every refreshSeconds to re-read the DataStore).
local function tick()
	local now = clock()
	local lastRead = lastLiveRead
	if lastRead == nil or now - lastRead >= Events.live.refreshSeconds then
		lastLiveRead = now
		readLive()
	end
	EventService.publish()

	local wait = Events.live.refreshSeconds
	local nextAt = EventService.nextChangeAt(schedule(), clock())
	local service = limitedService
	if service ~= nil and type(service.nextChangeAt) == "function" then
		local ok, dropAt = pcall(service.nextChangeAt, clock())
		if ok and type(dropAt) == "number" and (nextAt == nil or dropAt < nextAt) then
			nextAt = dropAt
		end
	end
	if nextAt ~= nil then
		wait = math.clamp(nextAt - clock(), MIN_WAIT_SECONDS, wait)
	end
	timer = task.delay(wait, tick)
end

-- Boot ------------------------------------------------------------------------------------------------------

local function optional(name: string): any
	local module = script.Parent:FindFirstChild(name)
	if module == nil or not module:IsA("ModuleScript") then
		return nil
	end
	local ok, result = pcall(require :: any, module)
	return if ok and type(result) == "table" then result else nil
end

function EventService:Init()
	flagService = optional("FeatureFlagService")
	limitedService = optional("LimitedService")
end

function EventService:Start()
	Players.PlayerAdded:Connect(function(player: Player)
		Net.fireClient("EventUpdate", player, EventService.payload())
	end)
	for _, player in Players:GetPlayers() do
		Net.fireClient("EventUpdate", player, EventService.payload())
	end
	local service = flagService
	if service ~= nil and type(service.onChanged) == "function" then
		service.onChanged(FLAG, function(_on: boolean)
			EventService.publish()
		end)
	end
	if timer == nil then
		task.spawn(tick)
	end
end

return EventService
