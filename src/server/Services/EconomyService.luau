--!strict
-- Cash: the only code that adds or spends it (PLAN.md §4 and Phase 3; docs/phase-3-contracts.md "Economy and
-- codes").
--
--   add(player, amount, reason)        pays the player; `amount` is rounded down to whole dollars and must be at
--                                      least $1; the wallet never goes past Config/Economy.maxCash
--   trySpend(player, amount, reason)   takes cash only if the player has enough; cash never goes below $0
--   getCash(player)                    the player's cash ($0 until their data has loaded)
--   earningsMultiplier(player)         1 plus the bonus of every boost still running (expired ones are dropped
--                                      from the save); every earning path multiplies its pay by it
--   devGrant(player, amount)           Studio only: adds cash for testing (CLAUDE.md hard rule 8)
--
-- Server-authoritative (CLAUDE.md hard rule 1): no remote reaches this module; only server code that has
-- decided a player earned or spent something calls it. Every change goes through DataService.update, is
-- logged as a Roblox economy analytics event (a source for cash in, a sink for cash out), and is mirrored to
-- the player's `Cash` attribute (Config/Economy cashAttribute) for the HUD.
--
-- The money math is exported as pure helpers (applyAdd, applySpend, activeBoosts, multiplierFrom) so
-- tests/Economy.spec can check it in Edit mode without players.

local AnalyticsService = game:GetService("AnalyticsService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Economy = require(ReplicatedStorage.Shared.Config.Economy)
local Types = require(ReplicatedStorage.Shared.Types)

-- DataService is required in Init rather than here: requiring it loads ProfileStore, which talks to DataStores
-- straight away, and tests/Economy.spec requires this module in Edit mode for its pure helpers.
type DataServiceModule = typeof(require(script.Parent.DataService))

export type Flow = "source" | "sink"

local LOG = "[EconomyService]"
local DEV_REASON = "dev"

local EconomyService = {}

local DataService: DataServiceModule? = nil
local analyticsWarned = false -- report an analytics failure once, not on every payment

-- Pure helpers ----------------------------------------------------------------------------------------------

local function isFinite(value: number): boolean
	return value == value and value ~= math.huge and value ~= -math.huge
end

-- A whole, positive number of dollars from an untrusted amount: rounded down; nil unless it is a finite number
-- of at least $1.
function EconomyService.wholeAmount(amount: any): number?
	if type(amount) ~= "number" or not isFinite(amount) then
		return nil
	end
	local whole = math.floor(amount)
	if whole < 1 then
		return nil
	end
	return whole
end

-- A stored balance as whole dollars, never negative. Guards every calculation against a damaged save.
function EconomyService.cleanBalance(balance: any): number
	if type(balance) ~= "number" or not isFinite(balance) or balance <= 0 then
		return 0
	end
	return math.floor(balance)
end

-- Adding `amount` to `balance` with the wallet capped at `max`: returns the new balance and how much was
-- really added (0 when the amount isn't a valid payment or the wallet is already full). A balance already above
-- `max` (the cap was lowered) is left as it is.
function EconomyService.applyAdd(balance: number, amount: number, max: number): (number, number)
	local current = EconomyService.cleanBalance(balance)
	local whole = EconomyService.wholeAmount(amount)
	if whole == nil then
		return current, 0
	end
	local newBalance = math.max(current, math.min(current + whole, max))
	return newBalance, newBalance - current
end

-- Spending `amount` from `balance`: the new balance, or nil when the amount isn't a valid price or is more
-- than the balance (cash never goes below 0).
function EconomyService.applySpend(balance: number, amount: number): number?
	local current = EconomyService.cleanBalance(balance)
	local whole = EconomyService.wholeAmount(amount)
	if whole == nil or whole > current then
		return nil
	end
	return current - whole
end

-- The boosts still running at `now` (os.time() seconds). A boost runs until `endsAt`, exclusive.
function EconomyService.activeBoosts(boosts: { Types.Boost }, now: number): { Types.Boost }
	local active: { Types.Boost } = {}
	for _, boost in boosts do
		if type(boost) == "table" and type(boost.endsAt) == "number" and now < boost.endsAt then
			table.insert(active, boost)
		end
	end
	return active
end

-- The earnings multiplier from a list of boosts at `now`: 1 plus each running boost's bonus (a 2x boost adds
-- 1), never above Config/Economy boosts.maxMultiplier. Expired and malformed boosts add nothing.
function EconomyService.multiplierFrom(boosts: { Types.Boost }, now: number): number
	local bonus = 0
	for _, boost in EconomyService.activeBoosts(boosts, now) do
		local factor = boost.factor
		if type(factor) == "number" and isFinite(factor) and factor > 1 then
			bonus += factor - 1
		end
	end
	return math.min(1 + bonus, Economy.boosts.maxMultiplier)
end

-- The Enum.AnalyticsEconomyTransactionType name a reason is logged under.
function EconomyService.transactionTypeFor(reason: string): string
	return Economy.analytics.transactionTypes[reason] or Economy.analytics.defaultTransactionType
end

-- Logging and the HUD mirror -------------------------------------------------------------------------------

local function validReason(reason: any): boolean
	return type(reason) == "string" and reason ~= ""
end

-- One cash change to Roblox analytics. Never blocks the economy: a failure is reported once and ignored.
local function logEvent(player: Player, flow: Flow, amount: number, endingBalance: number, reason: string)
	local flowType = if flow == "source"
		then Enum.AnalyticsEconomyFlowType.Source
		else Enum.AnalyticsEconomyFlowType.Sink
	local ok, err = pcall(function()
		AnalyticsService:LogEconomyEvent(
			player,
			flowType,
			Economy.analytics.currency,
			amount,
			endingBalance,
			EconomyService.transactionTypeFor(reason),
			reason
		)
	end)
	if not ok and not analyticsWarned then
		analyticsWarned = true
		warn(`{LOG} Couldn't log an economy event (later failures are not reported): {err}`)
	end
end

-- The player's cash, as stored ($0 until their data has loaded).
function EconomyService.getCash(player: Player): number
	local dataService = DataService
	local data = if dataService ~= nil then dataService.get(player) else nil
	return if data ~= nil then EconomyService.cleanBalance(data.cash) else 0
end

-- After a cash change made inside a DataService.update: mirrors the new balance to the Cash attribute and logs
-- the change (`amount` is what really moved; nothing is logged for 0). add and trySpend call it; so does
-- CodeService, which pays a cash code and marks it used in one update.
function EconomyService.recordChange(player: Player, flow: Flow, amount: number, reason: string)
	local cash = EconomyService.getCash(player)
	player:SetAttribute(Economy.cashAttribute, cash)
	if amount > 0 then
		logEvent(player, flow, amount, cash, reason)
	end
end

-- Earning and spending --------------------------------------------------------------------------------------

-- Pays the player. True when cash was added; false when the amount isn't at least $1, the reason is missing,
-- the player's data isn't loaded, or the wallet is already at Config/Economy.maxCash.
function EconomyService.add(player: Player, amount: number, reason: string): boolean
	local dataService = DataService
	if dataService == nil or not validReason(reason) or EconomyService.wholeAmount(amount) == nil then
		return false
	end
	local added = 0
	local updated = dataService.update(player, function(data: Types.PlayerData)
		local newBalance, gained = EconomyService.applyAdd(data.cash, amount, Economy.maxCash)
		data.cash = newBalance
		added = gained
	end)
	if not updated then
		return false
	end
	EconomyService.recordChange(player, "source", added, reason)
	return added > 0
end

-- Takes cash if the player has at least `amount` (rounded down to whole dollars). True when it was taken;
-- false (and nothing changes) when they can't afford it, the amount isn't at least $1, the reason is missing,
-- or their data isn't loaded.
function EconomyService.trySpend(player: Player, amount: number, reason: string): boolean
	local dataService = DataService
	if dataService == nil or not validReason(reason) or EconomyService.wholeAmount(amount) == nil then
		return false
	end
	local spent = 0
	local updated = dataService.update(player, function(data: Types.PlayerData)
		local newBalance = EconomyService.applySpend(data.cash, amount)
		if newBalance ~= nil then
			spent = EconomyService.cleanBalance(data.cash) - newBalance
			data.cash = newBalance
		end
	end)
	if not updated or spent <= 0 then
		return false
	end
	EconomyService.recordChange(player, "sink", spent, reason)
	return true
end

-- Drops boosts that have run out from the player's save. Returns the boosts still running.
local function pruneBoosts(player: Player, data: Types.PlayerData, now: number): { Types.Boost }
	local boosts = data.boosts or {}
	local active = EconomyService.activeBoosts(boosts, now)
	if #active < #boosts then
		local dataService = DataService
		if dataService ~= nil then
			dataService.update(player, function(fresh: Types.PlayerData)
				fresh.boosts = EconomyService.activeBoosts(fresh.boosts or {}, now)
			end)
		end
	end
	return active
end

-- What the player's earnings are multiplied by right now: 1 with no boosts running.
function EconomyService.earningsMultiplier(player: Player): number
	local dataService = DataService
	local data = if dataService ~= nil then dataService.get(player) else nil
	if data == nil then
		return 1
	end
	local now = os.time()
	return EconomyService.multiplierFrom(pruneBoosts(player, data, now), now)
end

-- Studio only: gives the player cash for testing. Refuses (false) anywhere else.
function EconomyService.devGrant(player: Player, amount: number): boolean
	if not RunService:IsStudio() then
		warn(`{LOG} devGrant only works in Studio`)
		return false
	end
	return EconomyService.add(player, amount, DEV_REASON)
end

-- Boot ------------------------------------------------------------------------------------------------------

function EconomyService:Init()
	DataService = require(script.Parent.DataService)
end

function EconomyService:Start()
	local dataService = DataService
	if dataService == nil then
		return
	end
	-- Show the HUD the player's cash as soon as their data loads, and clear out boosts that ran out while they
	-- were away.
	dataService.onLoaded(function(player: Player, data: Types.PlayerData)
		pruneBoosts(player, data, os.time())
		player:SetAttribute(Economy.cashAttribute, EconomyService.cleanBalance(data.cash))
	end)
end

return EconomyService
