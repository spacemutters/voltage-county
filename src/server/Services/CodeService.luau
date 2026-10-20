--!strict
-- Redeeming codes (PLAN.md Phase 3; docs/phase-3-contracts.md "Codes"). The codes and their effects live in
-- Config/Codes; what the player is told lives in Config/Economy `codes`.
--
-- The client invokes Net "RedeemCode" with the code as typed (Net has already checked it's a string of at most
-- 32 bytes and rate-limited it). The server trims it, upper-cases it, and checks that it exists, hasn't expired
-- (UTC os.time()) and hasn't been redeemed by this player; then, in one DataService.update, applies the effect
-- and marks the code used, so a code can never pay twice or be lost half-applied. It answers
-- { ok: boolean, message: string }, which the HUD shows as a notice.
--
-- `evaluate` makes the decision as a pure function of the code, the code table, the time and the player's
-- redeemed set, so tests/Codes.spec can check expiry and one-per-player in Edit mode.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Codes = require(ReplicatedStorage.Shared.Config.Codes)
local Economy = require(ReplicatedStorage.Shared.Config.Economy)
local Net = require(ReplicatedStorage.Shared.Net)
local Types = require(ReplicatedStorage.Shared.Types)
local EconomyService = require(script.Parent.EconomyService)

-- DataService is required in Init rather than here: requiring it loads ProfileStore, which talks to DataStores
-- straight away, and tests/Codes.spec requires this module in Edit mode for `evaluate`.
type DataServiceModule = typeof(require(script.Parent.DataService))

export type Status = "ok" | "empty" | "unknown" | "expired" | "redeemed"

-- What `evaluate` decided. `key` and `effect` are set only when ok.
export type Decision = {
	ok: boolean,
	status: Status,
	key: string?, -- the code as stored in Config/Codes (upper case)
	effect: Codes.Effect?,
	message: string, -- what to tell the player
}

-- What the RedeemCode remote answers.
export type Reply = { ok: boolean, message: string }

local SECONDS_PER_MINUTE = 60
local REMOTE = "RedeemCode"

local CodeService = {}

local DataService: DataServiceModule? = nil

-- Pure helpers ----------------------------------------------------------------------------------------------

-- The code as it is stored: surrounding spaces removed, upper case. nil when it is longer than
-- Config/Economy codes.maxLength (no such code can exist).
function CodeService.normalize(text: string): string?
	local trimmed = string.match(text, "^%s*(.-)%s*$") or ""
	if #trimmed > Economy.codes.maxLength then
		return nil
	end
	return string.upper(trimmed)
end

-- "2", "1.5": a multiplier factor without trailing zeros.
local function factorText(factor: number): string
	if factor % 1 == 0 then
		return string.format("%d", factor)
	end
	local text = string.format("%.2f", factor)
	text = string.gsub(text, "0+$", "")
	text = string.gsub(text, "%.$", "")
	return text
end

-- The success message for an effect, e.g. "Code redeemed! $5,000 added."
function CodeService.describe(effect: Codes.Effect): string
	local messages = Economy.codes.messages
	if effect.kind == "cash" then
		return string.format(messages.cash, Economy.formatCash(effect.amount))
	end
	local minutes = math.floor(effect.minutes)
	local duration = `{minutes} {if minutes == 1 then messages.minute else messages.minutes}`
	return string.format(messages.multiplier, factorText(effect.factor) .. "x", duration)
end

-- Decides whether `code` (as the player typed it) can be redeemed at `now` (UTC os.time() seconds) by a player
-- who has already redeemed the codes in `redeemed`. Checks, in order: something was typed, the code exists,
-- it hasn't expired (it stops working at expiresAtUtc), and this player hasn't used it.
function CodeService.evaluate(
	code: string,
	codes: { [string]: Codes.Code },
	now: number,
	redeemed: { [string]: boolean }
): Decision
	local messages = Economy.codes.messages
	local key = CodeService.normalize(code)
	if key == "" then
		return { ok = false, status = "empty", message = messages.empty }
	end
	local entry = if key ~= nil then codes[key] else nil
	if key == nil or entry == nil then
		return { ok = false, status = "unknown", message = messages.unknown }
	end
	if now >= entry.expiresAtUtc then
		return { ok = false, status = "expired", message = messages.expired }
	end
	if redeemed[key] == true then
		return { ok = false, status = "redeemed", message = messages.redeemed }
	end
	return { ok = true, status = "ok", key = key, effect = entry.effect, message = CodeService.describe(entry.effect) }
end

-- Redeeming -------------------------------------------------------------------------------------------------

local function reply(ok: boolean, message: string): Reply
	return { ok = ok, message = message }
end

-- Redeems `text` for `player`: decides, then applies the effect and marks the code used in one update.
function CodeService.redeem(player: Player, text: string): Reply
	local messages = Economy.codes.messages
	local dataService = DataService
	local data = if dataService ~= nil then dataService.get(player) else nil
	if dataService == nil or data == nil then
		return reply(false, messages.loading)
	end

	local now = os.time()
	local decision = CodeService.evaluate(text, Codes, now, data.codesRedeemed)
	local decidedKey, decidedEffect = decision.key, decision.effect
	if not decision.ok or decidedKey == nil or decidedEffect == nil then
		return reply(false, decision.message)
	end
	-- Non-optional copies, so the update function below sees them as set.
	local key: string = decidedKey
	local effect: Codes.Effect = decidedEffect

	local applied = false
	local cashAdded = 0
	local updated = dataService.update(player, function(fresh: Types.PlayerData)
		-- Check again inside the update, so two requests can never redeem one code twice.
		if fresh.codesRedeemed[key] == true then
			return
		end
		if effect.kind == "cash" then
			local newBalance, added = EconomyService.applyAdd(fresh.cash, effect.amount, Economy.maxCash)
			fresh.cash = newBalance
			cashAdded = added
		else
			-- Clear out boosts that have run out while adding the new one.
			local boosts = EconomyService.activeBoosts(fresh.boosts or {}, now)
			table.insert(boosts, {
				id = key,
				factor = effect.factor,
				endsAt = now + effect.minutes * SECONDS_PER_MINUTE,
			})
			fresh.boosts = boosts
		end
		fresh.codesRedeemed[key] = true
		applied = true
	end)

	if not updated then
		return reply(false, messages.failed)
	end
	if not applied then
		return reply(false, messages.redeemed)
	end
	if effect.kind == "cash" then
		EconomyService.recordChange(player, "source", cashAdded, Economy.codes.reason)
	end
	return reply(true, decision.message)
end

-- Boot ------------------------------------------------------------------------------------------------------

function CodeService:Init()
	DataService = require(script.Parent.DataService)
end

function CodeService:Start()
	Net.onServerInvoke(REMOTE, function(player: Player, payload: any): Reply
		-- Net has checked the payload is a string of at most Config/Economy codes.maxLength bytes.
		return CodeService.redeem(player, payload)
	end)
end

return CodeService
