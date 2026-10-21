--!strict
-- Season Pass v1 (PLAN.md Phase 12; docs/phase-12-contracts.md "Live-ops"; Config/Season): 30 tiers with a free
-- and a premium track, XP from driving and jobs, each reward claimed once per track.
--
--   XP        EconomyService.onEarned: each drive-to-earn payout and each job paid adds the fixed XP Config/Season
--             gives its reason, while the season runs and the "season" flag is on. The amount earned doesn't
--             matter, so boosts, VIP and events never make the track faster.
--   premium   MonetizationService.hasPass(player, Config/Season.passKey), checked on join, when the pass changes
--             (onPassChanged) and when a premium reward is claimed. Once seen it is saved for the season
--             (PlayerData.season.premium), so it holds even when a check fails.
--   claim     Net ClaimSeasonReward { tier, track }: one DataService.update checks the tier is reached, the track,
--             that it isn't claimed yet and that there's room for the reward, then pays it and marks it claimed,
--             so a double click can never claim twice. Cash goes through EconomyService's helpers (logged), credits
--             through CreditsService.Ledger.grant, a look into PlayerData.cosmetics[ref] (unnumbered, 0).
--             Answers { ok, message, season = status }.
--   new season  a save holding another season's id starts again at 0 XP with nothing claimed.
--   UI        player attributes (Config/Season.attributes): SeasonXp, SeasonTier, SeasonPremium and SeasonClaimed
--             ("free:1,premium:1,..."), set on join and after every change.
--
-- The rules are pure helpers on a season state and a season config, taking the time as an argument (clean,
-- isActive, claimOpen, xpFor, tierFor, addXp, claimKey, check, claimIn) for tests/Season.spec in Edit mode.

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

export type SeasonConfig = Season.Season
export type Reward = Season.Reward
export type Track = Season.Track
export type State = { id: string, xp: number, premium: boolean, claimed: { [string]: boolean } }

-- What a claim did, inside the update: whether it paid, what to say, and the cash it added (for the log).
export type Outcome = { ok: boolean, message: string, cash: number }

export type Status = {
	id: string,
	name: string,
	startsAt: number,
	endsAt: number,
	active: boolean,
	xp: number,
	tier: number,
	premium: boolean,
	claimed: { string },
}

export type Reply = { ok: boolean, message: string, season: Status? }

local LOG = "[SeasonService]"
local FLAG = "season" -- Config/FeatureFlags name
local LOOK_SERIAL = 0 -- a season look isn't numbered

local messages = Season.messages

local SeasonService = {}

local DataService: DataServiceModule? = nil
local flagService: any = nil
local monetization: any = nil

-- Pure helpers ----------------------------------------------------------------------------------------------

local function isWhole(value: any): boolean
	return type(value) == "number" and value == value and value % 1 == 0 and value >= 0 and value ~= math.huge
end

-- The saved season state, repaired, for `season`: another season's (or a damaged) state starts again at 0.
function SeasonService.clean(raw: any, season: SeasonConfig): State
	if type(raw) ~= "table" or raw.id ~= season.id then
		return { id = season.id, xp = 0, premium = false, claimed = {} }
	end
	local claimed: { [string]: boolean } = {}
	if type(raw.claimed) == "table" then
		for key, value in raw.claimed do
			if type(key) == "string" and value == true then
				claimed[key] = true
			end
		end
	end
	return {
		id = season.id,
		xp = if isWhole(raw.xp) then raw.xp else 0,
		premium = raw.premium == true,
		claimed = claimed,
	}
end

-- True while the season earns XP: it has an id and `now` is inside its window.
function SeasonService.isActive(season: SeasonConfig, now: number): boolean
	return season.id ~= "" and season.startsAtUtc <= now and now < season.endsAtUtc
end

-- True while rewards can be claimed: the season has started and its grace after the end hasn't run out.
function SeasonService.claimOpen(season: SeasonConfig, now: number): boolean
	return season.id ~= "" and season.startsAtUtc <= now and now < season.endsAtUtc + season.claimGraceSeconds
end

-- The season XP one EconomyService.add with `reason` is worth (0 for anything that isn't play).
function SeasonService.xpFor(season: SeasonConfig, reason: string): number
	local exact = season.xp.perReason[reason]
	if exact ~= nil then
		return exact
	end
	for _, rule in season.xp.perPrefix do
		if string.sub(reason, 1, #rule.prefix) == rule.prefix then
			return rule.xp
		end
	end
	return 0
end

-- The highest tier `xp` reaches (0 before the first).
function SeasonService.tierFor(season: SeasonConfig, xp: number): number
	local reached = 0
	for index, tier in season.tiers do
		if xp >= tier.xp then
			reached = index
		end
	end
	return reached
end

-- Adds XP to a state while the season runs. Returns what was added (0 outside the season).
function SeasonService.addXp(state: State, season: SeasonConfig, amount: number, now: number): number
	if not SeasonService.isActive(season, now) or not isWhole(amount) or amount < 1 then
		return 0
	end
	state.xp += amount
	return amount
end

function SeasonService.claimKey(track: Track, tier: number): string
	return `{track}:{tier}`
end

-- Whether a reward can be claimed: the reward, or nil and what to tell the player.
function SeasonService.check(
	state: State,
	season: SeasonConfig,
	tier: number,
	track: Track,
	premiumOwned: boolean,
	now: number
): (Reward?, string?)
	if season.id == "" or now < season.startsAtUtc then
		return nil, messages.none
	end
	if not SeasonService.claimOpen(season, now) then
		return nil, messages.ended
	end
	local entry = season.tiers[tier]
	if entry == nil then
		return nil, messages.unknownTier
	end
	if state.xp < entry.xp then
		return nil, string.format(messages.locked, tier)
	end
	if track == "premium" and not premiumOwned then
		return nil, messages.premium
	end
	if state.claimed[SeasonService.claimKey(track, tier)] then
		return nil, messages.claimed
	end
	local reward = if track == "premium" then entry.premium else entry.free
	if reward == nil then
		return nil, messages.noReward
	end
	return reward, nil
end

-- Inside a DataService.update: checks the claim and, when it's good, pays the reward and marks it claimed. Nothing
-- changes when it refuses. Cash isn't logged here (the caller logs Outcome.cash after the update).
function SeasonService.claimIn(
	data: Types.PlayerData,
	season: SeasonConfig,
	tier: number,
	track: Track,
	premiumOwned: boolean,
	now: number
): Outcome
	local state = SeasonService.clean(data.season, season)
	local reward, problem = SeasonService.check(state, season, tier, track, premiumOwned, now)
	if reward == nil then
		return { ok = false, message = problem or messages.notReady, cash = 0 }
	end
	local amount = reward.amount or 0
	local message = messages.notReady
	local cash = 0
	if reward.kind == "cash" then
		local newBalance, added = EconomyService.applyAdd(data.cash, amount, Economy.maxCash)
		if added < 1 then
			return { ok = false, message = messages.full, cash = 0 }
		end
		data.cash = newBalance
		cash = added
		message = string.format(messages.cash, Economy.formatCash(added))
	elseif reward.kind == "credits" then
		local credits = CreditsService.Ledger.sanitize(data.credits)
		if CreditsService.Ledger.grant(credits, amount) < 1 then
			return { ok = false, message = messages.full, cash = 0 }
		end
		data.credits = credits :: any
		message = if amount == 1 then messages.credit else string.format(messages.credits, amount)
	else
		local ref = reward.ref
		if ref == nil then
			return { ok = false, message = messages.notReady, cash = 0 }
		end
		if type(data.cosmetics) ~= "table" then
			data.cosmetics = {} -- a damaged save (schema 7 always has the table)
		end
		if data.cosmetics[ref] == nil then
			data.cosmetics[ref] = LOOK_SERIAL
		end
		message = messages.look
	end
	state.claimed[SeasonService.claimKey(track, tier)] = true
	data.season = state
	return { ok = true, message = message, cash = cash }
end

-- A player's season for the UI.
function SeasonService.statusOf(state: State, season: SeasonConfig, now: number): Status
	local claimed: { string } = {}
	for key in state.claimed do
		table.insert(claimed, key)
	end
	table.sort(claimed)
	return {
		id = season.id,
		name = season.name,
		startsAt = season.startsAtUtc,
		endsAt = season.endsAtUtc,
		active = SeasonService.isActive(season, now),
		xp = state.xp,
		tier = SeasonService.tierFor(season, state.xp),
		premium = state.premium,
		claimed = claimed,
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

local function stateOf(player: Player): State?
	local dataService = DataService
	local data = if dataService ~= nil then dataService.get(player) else nil
	if data == nil then
		return nil
	end
	return SeasonService.clean(data.season, Season)
end

local function publish(player: Player)
	local state = stateOf(player)
	if state == nil then
		return
	end
	local status = SeasonService.statusOf(state, Season, os.time())
	local names = Season.attributes
	player:SetAttribute(names.xp, status.xp)
	player:SetAttribute(names.tier, status.tier)
	player:SetAttribute(names.premium, status.premium)
	player:SetAttribute(names.claimed, table.concat(status.claimed, ","))
end

-- The player's season (nil until their data has loaded).
function SeasonService.status(player: Player): Status?
	local state = stateOf(player)
	return if state ~= nil then SeasonService.statusOf(state, Season, os.time()) else nil
end

-- Saves this season's state (a new season starts again) and, when `premium`, that the player has the pass.
local function save(player: Player, premium: boolean?)
	local dataService = DataService
	local current = if dataService ~= nil then dataService.get(player) else nil
	if dataService == nil or current == nil then
		return
	end
	local saved: any = current.season
	local stale = type(saved) ~= "table" or saved.id ~= Season.id
	if not stale and not (premium and saved.premium ~= true) then
		publish(player)
		return
	end
	dataService.update(player, function(data: Types.PlayerData)
		local state = SeasonService.clean(data.season, Season)
		if premium then
			state.premium = true
		end
		data.season = state
	end)
	publish(player)
end

-- Asks MonetizationService whether the player has this season's pass (may yield; a failure counts as no).
local function hasPass(player: Player): boolean
	local service = monetization
	if service == nil or type(service.hasPass) ~= "function" then
		return false
	end
	local ok, owned = pcall(service.hasPass, player, Season.passKey)
	if not ok then
		warn(`{LOG} hasPass({Season.passKey}) failed for {player.Name}: {owned}`)
	end
	return ok and owned == true
end

local function premiumOwned(player: Player): boolean
	local state = stateOf(player)
	if state ~= nil and state.premium then
		return true
	end
	local owned = hasPass(player)
	if owned then
		save(player, true)
	end
	return owned
end

local function onEarned(player: Player, _amount: number, reason: string)
	local xp = SeasonService.xpFor(Season, reason)
	local dataService = DataService
	if xp < 1 or dataService == nil or not flagOn() then
		return
	end
	local now = os.time()
	if not SeasonService.isActive(Season, now) then
		return
	end
	dataService.update(player, function(data: Types.PlayerData)
		local state = SeasonService.clean(data.season, Season)
		SeasonService.addXp(state, Season, xp, now)
		data.season = state
	end)
	publish(player)
end

local function onClaim(player: Player, payload: any): Reply
	if not flagOn() then
		return { ok = false, message = messages.off, season = SeasonService.status(player) }
	end
	local dataService = DataService
	if dataService == nil or dataService.get(player) == nil then
		return { ok = false, message = messages.loading }
	end
	local tier: number = payload.tier
	local track: Track = payload.track
	local premium = track == "premium" and premiumOwned(player) -- may yield, so before the update
	local now = os.time()
	local outcome: Outcome = { ok = false, message = messages.loading, cash = 0 }
	dataService.update(player, function(data: Types.PlayerData)
		outcome = SeasonService.claimIn(data, Season, tier, track, premium, now)
	end)
	if outcome.cash > 0 then
		EconomyService.recordChange(player, "source", outcome.cash, Season.reason)
	end
	publish(player)
	return { ok = outcome.ok, message = outcome.message, season = SeasonService.status(player) }
end

local function onLoaded(player: Player, _data: Types.PlayerData)
	save(player, nil)
	task.spawn(function()
		if hasPass(player) then
			save(player, true)
		end
	end)
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

function SeasonService:Init()
	DataService = require(script.Parent.DataService)
	flagService = optional("FeatureFlagService")
	monetization = optional("MonetizationService")
end

function SeasonService:Start()
	Net.onServerInvoke("ClaimSeasonReward", onClaim)
	EconomyService.onEarned(onEarned)
	local service = monetization
	if service ~= nil and type(service.onPassChanged) == "function" then
		pcall(service.onPassChanged, Season.passKey, function(player: Player, owned: any)
			if owned ~= false and typeof(player) == "Instance" and player.Parent == Players then
				save(player, true)
			end
		end)
	end
	local dataService = DataService
	if dataService ~= nil then
		dataService.onLoaded(onLoaded)
	end
end

return SeasonService
