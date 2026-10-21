--!strict
-- Design Credits: the balance, the one free new car, and reserve -> spend / refund (PLAN.md Phase 11 and §4;
-- docs/phase-11-contracts.md "Server", CreditsService). Read by Services/DesignerService (every design and mod),
-- Phase 12's MonetizationService (credit packs and the Club grant through `grant`) and the specs.
--
-- The saved shape is PlayerData.credits = { balance, freeDesignUsed, reserved = { { id, amount, at } } }.
-- How a request is paid for:
--   reserve  takes the price out of the balance at once and records it as a reservation (an id). Nothing can take
--            the balance below zero: a reserve the balance can't cover is refused and changes nothing. A price of
--            0 (an event that makes mods free, say) is an ordinary reservation that holds nothing.
--   reserveFree  the one free new car: a reservation of 0 whose id starts with Ledger.FREE_PREFIX ("free:"). It
--            needs freeDesignUsed false and sets it true, so the free car can never be reserved twice at once, and
--            only these ids ever touch it (a 0 price never uses up the free car). No schema change: the prefix is
--            the whole difference.
--   spend    the request succeeded: the reservation goes, the credits stay spent (the free car stays used).
--   refund   a refusal, a moderation failure, an error or a timeout: the credits go back (the free car comes back).
--            Spending or refunding an id that isn't reserved (already settled) does nothing and returns false, so
--            nothing settles twice.
--   on join  every reservation still in the save is from a session that ended mid-request (a server can only
--            settle what it reserved), so they are all refunded before anything else runs.
--
-- The rules are pure functions on a credits table (CreditsService.Ledger) so tests/Credits.spec checks them in
-- Edit mode, and so DesignerService can settle a reservation inside the same DataService.update that saves a
-- design (one save: the car and the charge land together or not at all).
--
-- Remotes (declared in Net, which has already checked each payload's shape and rate-limited it):
--   DevCredits { amount }   function, Studio only: sets the caller's balance to exactly `amount`. Answers
--                           { ok, message, balance }.
-- Server-authoritative (CLAUDE.md hard rule 1): clients never name an amount except through the Studio-only dev
-- remote. No polling: everything runs on requests and the join.

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Designer = require(ReplicatedStorage.Shared.Config.Designer)
local Net = require(ReplicatedStorage.Shared.Net)
local Types = require(ReplicatedStorage.Shared.Types)

-- DataService is required in Init rather than here: it loads ProfileStore, which talks to DataStores straight
-- away, and tests/Credits.spec requires this module in Edit mode for the Ledger.
type DataServiceModule = typeof(require(script.Parent.DataService))

export type Credits = { balance: number, freeDesignUsed: boolean, reserved: { Types.CreditReservation } }
export type Reply = { ok: boolean, message: string, balance: number }

local LOG = "[CreditsService]"
local FREE_PREFIX = "free:" -- reservation ids of the free new car

local CreditsService = {}

local DataService: DataServiceModule? = nil

-- Reservations this server made and hasn't settled yet: id -> the Player it was made for. The join clean-up keeps
-- the joining Player's own (a request that started in the moment between their data loading and the clean-up
-- running) and refunds everything else in the save, including what an earlier session of theirs on this same server
-- left unsettled: that session's requests belong to a Player who has left, so they can never settle (DataService
-- refuses updates for them). An entry goes when it settles or its Player leaves.
local reservedHere: { [string]: Player } = {}

-- Ledger: pure rules on one credits table -------------------------------------------------------------------

local Ledger = {}
CreditsService.Ledger = Ledger
Ledger.FREE_PREFIX = FREE_PREFIX

local function isWhole(value: any): boolean
	return type(value) == "number" and value == value and value % 1 == 0 and value >= 0 and value ~= math.huge
end

-- The reservation id the free new car is held under for request `id`.
function Ledger.freeId(id: string): string
	return FREE_PREFIX .. id
end

-- True when reservation `id` holds the free new car.
function Ledger.isFreeId(id: string): boolean
	return string.sub(id, 1, #FREE_PREFIX) == FREE_PREFIX
end

-- Repairs a damaged credits table in place and returns it (a new one when `value` isn't a table at all): the
-- balance becomes a whole number in 0..Config/Designer.maxCredits (anything else becomes 0), freeDesignUsed a
-- boolean, and reservations that aren't { string id, whole amount, number at } are dropped (their amount can't be
-- known, so nothing is refunded). Callers store the result back.
function Ledger.sanitize(value: any): Credits
	local credits: any = if type(value) == "table" then value else {}
	local balance = credits.balance
	if type(balance) ~= "number" or balance ~= balance then
		credits.balance = 0
	else
		credits.balance = math.clamp(math.floor(balance), 0, Designer.maxCredits)
	end
	credits.freeDesignUsed = credits.freeDesignUsed == true
	local clean: { Types.CreditReservation } = {}
	if type(credits.reserved) == "table" then
		for _, entry in credits.reserved do
			if
				type(entry) == "table"
				and type(entry.id) == "string"
				and isWhole(entry.amount)
				and type(entry.at) == "number"
			then
				table.insert(clean, entry)
			end
		end
	end
	credits.reserved = clean
	return credits
end

function Ledger.balance(credits: Credits): number
	return credits.balance
end

-- True while the one free new car is unused and not held by a request in flight.
function Ledger.freeAvailable(credits: Credits): boolean
	return not credits.freeDesignUsed
end

local function indexOf(credits: Credits, id: string): number?
	for index, entry in credits.reserved do
		if entry.id == id then
			return index
		end
	end
	return nil
end

-- Reserves `amount` credits under `id`; a free-car id (Ledger.freeId) reserves the free new car instead and must
-- hold 0. Returns false, changing nothing, when the amount isn't a whole number of at least 0, the id is already
-- reserved, the balance can't cover it, or (for a free-car id) the amount isn't 0 or the free car is used or held.
function Ledger.reserve(credits: Credits, amount: number, id: string, now: number): boolean
	if not isWhole(amount) or indexOf(credits, id) ~= nil then
		return false
	end
	if Ledger.isFreeId(id) then
		if amount ~= 0 or credits.freeDesignUsed then
			return false
		end
		credits.freeDesignUsed = true
	else
		if credits.balance < amount then
			return false
		end
		credits.balance -= amount
	end
	table.insert(credits.reserved, { id = id, amount = amount, at = now })
	return true
end

-- The request succeeded: drop the reservation; what it held stays spent. False when `id` isn't reserved.
function Ledger.spend(credits: Credits, id: string): boolean
	local index = indexOf(credits, id)
	if index == nil then
		return false
	end
	table.remove(credits.reserved, index)
	return true
end

-- The request failed: drop the reservation and give back what it held (the free car becomes available again).
-- The balance never goes past Config/Designer.maxCredits. False when `id` isn't reserved.
function Ledger.refund(credits: Credits, id: string): boolean
	local index = indexOf(credits, id)
	if index == nil then
		return false
	end
	local entry = table.remove(credits.reserved, index) :: Types.CreditReservation
	if Ledger.isFreeId(entry.id) then
		credits.freeDesignUsed = false
	else
		credits.balance = math.min(credits.balance + entry.amount, Designer.maxCredits)
	end
	return true
end

-- Refunds every reservation except those in `keep` (on join: everything a session that ended left behind; `keep`
-- holds ids this server reserved itself). Returns how many were refunded.
function Ledger.clearStale(credits: Credits, keep: { [string]: boolean }?): number
	local ids: { string } = {}
	for _, entry in credits.reserved do
		if keep == nil or not keep[entry.id] then
			table.insert(ids, entry.id)
		end
	end
	for _, id in ids do
		Ledger.refund(credits, id)
	end
	return #ids
end

-- Adds a whole number of credits (at least 1), never past Config/Designer.maxCredits. Returns what was added.
function Ledger.grant(credits: Credits, amount: number): number
	if not isWhole(amount) or amount < 1 then
		return 0
	end
	local before = credits.balance
	credits.balance = math.min(before + amount, Designer.maxCredits)
	return credits.balance - before
end

-- Studio only: the balance becomes exactly `amount` (a whole number, capped).
function Ledger.set(credits: Credits, amount: number)
	if isWhole(amount) then
		credits.balance = math.min(amount, Designer.maxCredits)
	end
end

-- Players ---------------------------------------------------------------------------------------------------

local function creditsOf(player: Player): Credits?
	local dataService = DataService
	local data = if dataService ~= nil then dataService.get(player) else nil
	if data == nil or type(data.credits) ~= "table" then
		return nil
	end
	return data.credits :: any
end

-- Runs `fn` on the player's sanitized credits inside one DataService.update. Returns false when the data isn't
-- loaded, the session isn't active, or `fn` returned false.
local function change(player: Player, fn: (credits: Credits) -> boolean): boolean
	local dataService = DataService
	if dataService == nil then
		return false
	end
	local result = false
	local updated = dataService.update(player, function(data: Types.PlayerData)
		local credits = Ledger.sanitize(data.credits)
		data.credits = credits
		result = fn(credits)
	end)
	return updated and result
end

-- The player's balance (0 until their data has loaded).
function CreditsService.balance(player: Player): number
	local credits = creditsOf(player)
	return if credits ~= nil and isWhole(credits.balance) then credits.balance else 0
end

-- True while the player's free new car is unused (and their data has loaded).
function CreditsService.freeAvailable(player: Player): boolean
	local credits = creditsOf(player)
	return credits ~= nil and credits.freeDesignUsed ~= true
end

local function reserveAs(player: Player, amount: number, id: string, what: string, why: string): string?
	local now = os.time()
	local ok = change(player, function(credits: Credits): boolean
		return Ledger.reserve(credits, amount, id, now)
	end)
	if not ok then
		return nil
	end
	reservedHere[id] = player
	print(`{LOG} {player.Name}: reserved {what} for {why} ({id})`)
	return id
end

-- Reserves `amount` credits (0 holds nothing; it never uses the free car) for a request and returns the
-- reservation id, or nil when it can't be covered (or the data isn't loaded). `why` is for the log.
function CreditsService.reserve(player: Player, amount: number, why: string): string?
	return reserveAs(player, amount, HttpService:GenerateGUID(false), `{amount} credits`, why)
end

-- Reserves the player's one free new car and returns the reservation id, or nil when it is used, held by another
-- request, or the data isn't loaded. Spend and refund it like any reservation.
function CreditsService.reserveFree(player: Player, why: string): string?
	return reserveAs(player, 0, Ledger.freeId(HttpService:GenerateGUID(false)), "the free design", why)
end

-- The request behind reservation `id` succeeded. False when it was already settled (or the data isn't there).
function CreditsService.spend(player: Player, id: string): boolean
	reservedHere[id] = nil
	return change(player, function(credits: Credits): boolean
		return Ledger.spend(credits, id)
	end)
end

-- The request behind reservation `id` failed: give it back. False when it was already settled.
function CreditsService.refund(player: Player, id: string): boolean
	reservedHere[id] = nil
	local ok = change(player, function(credits: Credits): boolean
		return Ledger.refund(credits, id)
	end)
	if ok then
		print(`{LOG} {player.Name}: refunded {id}`)
	end
	return ok
end

-- For code already inside a DataService.update (DesignerService saves a design or a mod and spends its
-- reservation in the same update): spends or refunds `id` on that player's data table. Never yields. False when
-- `id` isn't reserved.
function CreditsService.spendIn(data: Types.PlayerData, id: string): boolean
	reservedHere[id] = nil
	local credits = Ledger.sanitize(data.credits)
	data.credits = credits :: any
	return Ledger.spend(credits, id)
end

function CreditsService.refundIn(data: Types.PlayerData, id: string): boolean
	reservedHere[id] = nil
	local credits = Ledger.sanitize(data.credits)
	data.credits = credits :: any
	return Ledger.refund(credits, id)
end

-- Adds credits (Phase 12: credit packs, the Voltage Club, streak and event rewards). `reason` is for the log.
-- Returns false when nothing could be added (not a whole number of at least 1, the cap reached, data not loaded).
function CreditsService.grant(player: Player, amount: number, reason: string): boolean
	local added = 0
	local ok = change(player, function(credits: Credits): boolean
		added = Ledger.grant(credits, amount)
		return added > 0
	end)
	if ok then
		print(`{LOG} {player.Name}: +{added} credits ({reason})`)
	end
	return ok
end

-- Studio only: DevCredits.
local function onDevCredits(player: Player, payload: any): Reply
	if not RunService:IsStudio() then
		warn(`{LOG} {player.Name} called DevCredits outside Studio`)
		return { ok = false, message = Designer.messages.devOnly, balance = CreditsService.balance(player) }
	end
	local amount: number = payload.amount
	local ok = change(player, function(credits: Credits): boolean
		Ledger.set(credits, amount)
		return true
	end)
	local balance = CreditsService.balance(player)
	if not ok then
		return { ok = false, message = Designer.messages.loading, balance = balance }
	end
	return { ok = true, message = string.format(Designer.messages.devCredits, balance), balance = balance }
end

-- The ids of the reservations this server made for `player` (this Player object) and hasn't settled yet.
local function heldBy(player: Player): { [string]: boolean }
	local own: { [string]: boolean } = {}
	for id, owner in reservedHere do
		if owner == player then
			own[id] = true
		end
	end
	return own
end

-- Boot ------------------------------------------------------------------------------------------------------

function CreditsService:Init()
	DataService = require(script.Parent.DataService)
end

function CreditsService:Start()
	Net.onServerInvoke("DevCredits", onDevCredits)
	local dataService = DataService
	if dataService == nil then
		return
	end
	-- Join: refund whatever a session that ended mid-request left reserved.
	dataService.onLoaded(function(player: Player, _data: Types.PlayerData)
		local refunded = 0
		change(player, function(credits: Credits): boolean
			refunded = Ledger.clearStale(credits, heldBy(player))
			return true
		end)
		if refunded > 0 then
			print(`{LOG} {player.Name}: refunded {refunded} reservation(s) left by an earlier session`)
		end
	end)
	-- Leave: forget what this Player still held (DesignerService refunds it into the save as they go; anything it
	-- couldn't is refunded by the clean-up on their next join, on this server or another).
	Players.PlayerRemoving:Connect(function(player: Player)
		for id in heldBy(player) do
			reservedHere[id] = nil
		end
	end)
end

return CreditsService
