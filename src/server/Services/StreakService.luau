--!strict
-- The daily login streak (PLAN.md Phase 12 and §11 "Growth that pays"; docs/phase-12-contracts.md "Live-ops";
-- Config/Season.streak): one reward per UTC day, cash every day and a Design Credit on the last day of each cycle.
--
--   days      a streak day is a UTC calendar day (os.time() // daySeconds), the same for every player and server.
--   claim     Net ClaimStreak: claimable once per UTC day. Claiming the day after the last claim moves the streak
--             on a day; after a missed day it starts again at day 1. Day n pays Config/Season.streak.rewards for
--             its place in the cycle (day 8 pays like day 1, and so on). One DataService.update checks, pays and
--             saves PlayerData.streak = { lastDay, count }, so a double click can never claim twice. Cash goes
--             through EconomyService's helpers (logged after the update), the credit through CreditsService.Ledger.
--             Answers { ok, message, streak = status }: { count, lastDay, claimable, nextAt, day, reward, today },
--             the Store app's streak shape plus what today pays.
--   UI        player attributes (Config/Season.streak.attributes): StreakDay (the streak day a claim pays now, or
--             the one already claimed today), StreakClaimable, StreakNextDayAt (the next UTC midnight, Unix
--             seconds), set on join, after a claim and at every UTC midnight (one timer, not a poll).
--
-- The rules are pure helpers taking the time as an argument (dayOf, evaluate, rewardFor, claimIn) for
-- tests/Streak.spec in Edit mode.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Economy = require(ReplicatedStorage.Shared.Config.Economy)
local FeatureFlags = require(ReplicatedStorage.Shared.Config.FeatureFlags)
local Net = require(ReplicatedStorage.Shared.Net)
local Season = require(ReplicatedStorage.Shared.Config.Season)
local Types = require(ReplicatedStorage.Shared.Types)
local CreditsService = require(script.Parent.CreditsService)
local EconomyService = require(script.Parent.EconomyService)

-- DataService is required in Init: it loads ProfileStore, which talks to DataStores straight away.
type DataServiceModule = typeof(require(script.Parent.DataService))

export type StreakReward = Season.StreakReward
export type State = { lastDay: number, count: number }

-- Where a player's streak stands at a moment (the Store app's streak: count, lastDay, claimable, nextAt).
export type Status = {
	count: number, -- days in the streak still alive (claimed today or yesterday); 0 once a day was missed
	lastDay: number, -- the UTC day number of the last claim (0 = never)
	claimable: boolean,
	nextAt: number, -- when the next UTC day starts (Unix seconds): the next claim when today's is taken
	day: number, -- the streak day a claim pays now, or the one already claimed today
	reward: StreakReward, -- what that day pays
	today: number, -- the UTC day number of `now`
}

export type Outcome = { ok: boolean, message: string, cash: number, credits: number }
export type Reply = { ok: boolean, message: string, streak: Status? }

local FLAG = "streak" -- Config/FeatureFlags name

local config = Season.streak
local messages = config.messages

local StreakService = {}

local DataService: DataServiceModule? = nil
local flagService: any = nil
local timer: thread? = nil

-- Pure helpers ----------------------------------------------------------------------------------------------

local function isWhole(value: any): boolean
	return type(value) == "number" and value == value and value % 1 == 0 and value >= 0 and value ~= math.huge
end

-- The UTC day number of `now` (os.time() seconds).
function StreakService.dayOf(now: number): number
	return math.floor(now / config.daySeconds)
end

-- What streak day `day` (1, 2, 3 ...) pays: its place in the reward cycle.
function StreakService.rewardFor(day: number): StreakReward
	local rewards = config.rewards
	return rewards[((math.max(day, 1) - 1) % #rewards) + 1]
end

-- A saved streak, repaired.
function StreakService.clean(raw: any): State
	if type(raw) ~= "table" then
		return { lastDay = 0, count = 0 }
	end
	return {
		lastDay = if isWhole(raw.lastDay) then raw.lastDay else 0,
		count = if isWhole(raw.count) then raw.count else 0,
	}
end

-- Where a streak stands at `now`: claimed today already, continuing from yesterday, or starting (again) at day 1.
function StreakService.evaluate(raw: any, now: number): Status
	local state = StreakService.clean(raw)
	local today = StreakService.dayOf(now)
	local claimable = true
	local day = 1
	local count = 0
	if state.count >= 1 and state.lastDay == today then
		claimable = false
		day = state.count
		count = state.count
	elseif state.count >= 1 and state.lastDay == today - 1 then
		day = state.count + 1
		count = state.count
	end
	return {
		count = count,
		lastDay = state.lastDay,
		claimable = claimable,
		nextAt = (today + 1) * config.daySeconds,
		day = day,
		reward = StreakService.rewardFor(day),
		today = today,
	}
end

-- Inside a DataService.update: claims today's reward when it can, paying it and saving the streak. Nothing
-- changes when it refuses. Cash isn't logged here (the caller logs Outcome.cash after the update).
function StreakService.claimIn(data: Types.PlayerData, now: number): Outcome
	local status = StreakService.evaluate(data.streak, now)
	if not status.claimable then
		return { ok = false, message = messages.claimed, cash = 0, credits = 0 }
	end
	local reward = status.reward
	local newBalance, cash = EconomyService.applyAdd(data.cash, reward.cash, Economy.maxCash)
	if cash < 1 then
		return { ok = false, message = messages.full, cash = 0, credits = 0 }
	end
	data.cash = newBalance
	local credits = 0
	if reward.credits ~= nil then
		local ledger = CreditsService.Ledger.sanitize(data.credits)
		credits = CreditsService.Ledger.grant(ledger, reward.credits)
		data.credits = ledger :: any
	end
	data.streak = { lastDay = status.today, count = status.day }
	local template = if credits > 0 then messages.rewardCredit else messages.reward
	return {
		ok = true,
		message = string.format(template, status.day, Economy.formatCash(cash)),
		cash = cash,
		credits = credits,
	}
end

-- The live service ------------------------------------------------------------------------------------------

local function flagOn(): boolean
	local service = flagService
	if service ~= nil then
		local ok, on = pcall(service.isOn, FLAG)
		if ok and type(on) == "boolean" then
			return on
		end
	end
	return FeatureFlags.defaults[FLAG] == true
end

-- The player's streak now (nil until their data has loaded).
function StreakService.status(player: Player): Status?
	local dataService = DataService
	local data = if dataService ~= nil then dataService.get(player) else nil
	return if data ~= nil then StreakService.evaluate(data.streak, os.time()) else nil
end

local function publish(player: Player)
	local status = StreakService.status(player)
	if status == nil then
		return
	end
	local names = config.attributes
	player:SetAttribute(names.day, status.day)
	player:SetAttribute(names.claimable, status.claimable and flagOn())
	player:SetAttribute(names.nextDay, status.nextAt)
end

local function onClaim(player: Player, _payload: any): Reply
	if not flagOn() then
		return { ok = false, message = messages.off, streak = StreakService.status(player) }
	end
	local dataService = DataService
	if dataService == nil or dataService.get(player) == nil then
		return { ok = false, message = messages.loading }
	end
	local now = os.time()
	local outcome: Outcome = { ok = false, message = messages.loading, cash = 0, credits = 0 }
	dataService.update(player, function(data: Types.PlayerData)
		outcome = StreakService.claimIn(data, now)
	end)
	if outcome.cash > 0 then
		EconomyService.recordChange(player, "source", outcome.cash, config.reason)
	end
	publish(player)
	return { ok = outcome.ok, message = outcome.message, streak = StreakService.status(player) }
end

-- At every UTC midnight: today's reward becomes claimable for everyone online.
local function midnight()
	local now = os.time()
	local nextDayAt = (StreakService.dayOf(now) + 1) * config.daySeconds
	timer = task.delay(nextDayAt - now, midnight)
	for _, player in Players:GetPlayers() do
		publish(player)
	end
end

-- Boot ------------------------------------------------------------------------------------------------------

function StreakService:Init()
	DataService = require(script.Parent.DataService)
	local flags = script.Parent:FindFirstChild("FeatureFlagService")
	if flags ~= nil and flags:IsA("ModuleScript") then
		local ok, module = pcall(require :: any, flags)
		if ok and type(module) == "table" then
			flagService = module
		end
	end
end

function StreakService:Start()
	Net.onServerInvoke("ClaimStreak", onClaim)
	local dataService = DataService
	if dataService ~= nil then
		dataService.onLoaded(function(player: Player, _data: Types.PlayerData)
			publish(player)
		end)
	end
	local service = flagService
	if service ~= nil and type(service.onChanged) == "function" then
		service.onChanged(FLAG, function(_on: boolean)
			for _, player in Players:GetPlayers() do
				publish(player)
			end
		end)
	end
	if timer == nil then
		midnight()
	end
end

return StreakService
