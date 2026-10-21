--!strict
-- Limited drops and limited cosmetics (PLAN.md Phase 12; docs/phase-12-contracts.md "Live-ops"; Config/Limiteds).
--
-- Serials: one DataStore key per drop (Config/Limiteds store and key prefix; Studio uses its own store and prefix)
-- holds { sold, owners = { [userId] = serial } }. A claim is one UpdateAsync: a player already in `owners` gets
-- their own serial back (so a retried claim never takes a second one), otherwise the next serial while
-- sold < supply, otherwise "sold out". UpdateAsync makes it atomic across every server.
--
-- Buying a drop (Net BuyLimited { dropId }, in-game cash), in three steps so nothing is lost if a step fails:
--   1 charge   one DataService.update checks the window, the "drops" flag, a free garage slot and the cash, takes
--              the price and records a pendingGrants entry { kind = Config/Limiteds.pendingKind, ref = "<dropId>:<paid>" }
--   2 claim    the serial (UpdateAsync). Sold out: the price comes back and the entry goes. A DataStore error: the
--              entry stays, and the purchase finishes on the next join.
--   3 grant    one update puts the car (OwnedVehicle.serial set) in the garage and removes the entry. If it fails
--              (the player left, the session ended) the entry stays and the next join finishes it: the claim gives
--              the same serial back, so the player gets exactly the serial they were sold, and pays once.
-- On every join each entry left over is finished the same way (or refunded when the drop sold out or is gone).
-- The grant ignores the garage limit: the slot was checked when the player paid.
--
-- Limited cosmetics (Robux): each Config/Limiteds cosmetic is registered with MonetizationService.registerProduct
-- under its productKey, so the one idempotent ProcessReceipt hands its receipts here. The handler claims the next
-- serial (no supply cap) and saves PlayerData.cosmetics[ref] = serial (schema 7: by look id, so
-- MonetizationService.ownsCosmetic and the Wrap & Tint shop see it); it answers false (Roblox
-- redelivers the receipt later) when the DataStore or the profile can't be written. A receipt handled twice gets
-- the same serial back from the claim, so it never takes a second serial. The window is checked before the purchase
-- prompt (cosmeticAvailable / canBuyCosmetic), never after: a receipt means Robux was spent, so it is always granted.
--
-- For EventService's banner (Net EventUpdate `drops`): publicDrops(now) and nextChangeAt(now); the remaining supply
-- of open drops is re-read every Config/Limiteds.refreshSeconds (config refresh on a slow timer, not a poll).
--
-- Server-authoritative (CLAUDE.md hard rule 1): a client only names a drop id. Fair monetization (hard rule 6): a
-- serial is the next number, never random, and no Robux price is written anywhere.
-- The flows take their outside world as Deps (store, clock, profile update, cash log), so tests/Limiteds.spec runs
-- them against a mock store and fake profiles in Edit mode.

local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Economy = require(ReplicatedStorage.Shared.Config.Economy)
local FeatureFlags = require(ReplicatedStorage.Shared.Config.FeatureFlags)
local Limiteds = require(ReplicatedStorage.Shared.Config.Limiteds)
local Net = require(ReplicatedStorage.Shared.Net)
local Types = require(ReplicatedStorage.Shared.Types)
local EconomyService = require(script.Parent.EconomyService)
local GarageService = require(script.Parent.GarageService)
local Template = require(script.Parent.DataService.Template)

-- DataService is required in Init: it loads ProfileStore, which talks to DataStores straight away.
type DataServiceModule = typeof(require(script.Parent.DataService))

export type Drop = Limiteds.Drop
export type Cosmetic = Limiteds.Cosmetic
export type Flow = EconomyService.Flow

-- The serial counter saved under each drop's key.
export type Record = { sold: number, owners: { [string]: number } }
export type ClaimStatus = "claimed" | "owned" | "soldOut" | "error"
export type Claim = { status: ClaimStatus, serial: number? }

-- The parts of a DataStore the claims use (a real GlobalDataStore, or the spec's mock).
export type Store = {
	UpdateAsync: (self: any, key: string, transform: (old: any) -> any) -> any,
	GetAsync: (self: any, key: string) -> any,
}

export type Deps = {
	store: Store,
	keyFor: (id: string) -> string, -- the DataStore key of a drop's or cosmetic's serial counter
	now: () -> number, -- os.time() seconds
	update: (player: Player, fn: (data: Types.PlayerData) -> ()) -> boolean, -- DataService.update
	userId: (player: Player) -> number,
	newUid: () -> string, -- a new car's uid
	recordCash: (player: Player, flow: Flow, amount: number, reason: string) -> (), -- EconomyService.recordChange
	flagOn: () -> boolean, -- the "drops" flag
	drops: { [string]: Drop }?, -- default Config/Limiteds.drops (specs pass their own)
	cosmetics: { [string]: Cosmetic }?, -- default Config/Limiteds.cosmetics
}

export type Reply = { ok: boolean, message: string, serial: number? }

export type WindowState = "notYet" | "open" | "ended"

export type PublicDrop = {
	id: string,
	name: string,
	vehicleId: string,
	trim: string,
	startsAt: number,
	endsAt: number,
	price: number,
	supply: number,
	remaining: number?, -- last known; nil until this server has read it
	open: boolean,
}

export type CosmeticProduct = {
	key: string,
	name: string,
	kind: "cosmetic",
	grants: { cosmetic: string, look: string, ref: string },
	available: boolean,
	startsAt: number,
	endsAt: number,
}

local LOG = "[LimitedService]"
local FLAG = "drops" -- Config/FeatureFlags name
local REF_PATTERN = "^([%w_]+):(%d+)$"
local NOTIFY_KIND = "success"

local messages = Limiteds.messages

local LimitedService = {}

local DataService: DataServiceModule? = nil
local flagService: any = nil
local eventService: any = nil
local monetization: any = nil

local busy: { [Player]: boolean } = {} -- one purchase (or join clean-up) at a time per player
local remaining: { [string]: number } = {} -- last known remaining supply by drop id
local timer: thread? = nil

-- Pure helpers ----------------------------------------------------------------------------------------------

local function isWhole(value: any): boolean
	return type(value) == "number" and value == value and value % 1 == 0 and value >= 0 and value ~= math.huge
end

-- A serial counter from an untrusted stored value (nil for a key never written).
function LimitedService.cleanRecord(raw: any): Record
	local record: Record = { sold = 0, owners = {} }
	if type(raw) ~= "table" then
		return record
	end
	if isWhole(raw.sold) then
		record.sold = raw.sold
	end
	if type(raw.owners) == "table" then
		for userKey, serial in raw.owners do
			-- Keys are UserIds as strings; a number key (however the store gave it back) means the same player.
			local key = if type(userKey) == "number" then tostring(userKey) else userKey
			if type(key) == "string" and isWhole(serial) and serial >= 1 then
				record.owners[key] = serial
				record.sold = math.max(record.sold, serial)
			end
		end
	end
	return record
end

-- The UpdateAsync transform of a claim: the record to write (nil = write nothing) and the claim's result.
-- `supply` nil means no cap (limited cosmetics).
function LimitedService.claimTransform(raw: any, userKey: string, supply: number?): (Record?, Claim)
	local record = LimitedService.cleanRecord(raw)
	local existing = record.owners[userKey]
	if existing ~= nil then
		return nil, { status = "owned", serial = existing }
	end
	if supply ~= nil and record.sold >= supply then
		return nil, { status = "soldOut", serial = nil }
	end
	record.sold += 1
	record.owners[userKey] = record.sold
	return record, { status = "claimed", serial = record.sold }
end

-- Claims a serial for `userId` under `key` (yields). "error" when the DataStore call failed.
function LimitedService.claimSerial(store: Store, key: string, userId: number, supply: number?): (ClaimStatus, number?)
	local userKey = tostring(userId)
	local claim: Claim? = nil
	local ok, err = pcall(function()
		store:UpdateAsync(key, function(old: any): any
			local record, result = LimitedService.claimTransform(old, userKey, supply)
			claim = result
			return record
		end)
	end)
	if not ok then
		warn(`{LOG} couldn't claim a serial under {key}: {err}`)
		return "error", nil
	end
	local result = claim
	if result == nil then
		return "error", nil
	end
	return result.status, result.serial
end

-- Where a drop's or cosmetic's sale window stands at `now`.
function LimitedService.windowState(item: { startsAtUtc: number, endsAtUtc: number }, now: number): WindowState
	if now < item.startsAtUtc then
		return "notYet"
	elseif now >= item.endsAtUtc then
		return "ended"
	end
	return "open"
end

-- The pendingGrants ref of a drop paid for but not yet granted, and back.
function LimitedService.pendingRef(dropId: string, paid: number): string
	return `{dropId}:{paid}`
end

function LimitedService.parseRef(ref: any): (string?, number?)
	if type(ref) ~= "string" then
		return nil, nil
	end
	local dropId, paid = string.match(ref, REF_PATTERN)
	if dropId == nil or paid == nil then
		return nil, nil
	end
	return dropId, tonumber(paid)
end

-- The index of the player's pendingGrants entry for `dropId`, or nil.
function LimitedService.pendingIndex(data: Types.PlayerData, dropId: string): number?
	local pending = data.pendingGrants
	if type(pending) ~= "table" then
		return nil
	end
	for index, entry in pending do
		if type(entry) == "table" and entry.kind == Limiteds.pendingKind then
			local id = LimitedService.parseRef(entry.ref)
			if id == dropId then
				return index
			end
		end
	end
	return nil
end

-- True when the player's garage holds this drop's car with this serial.
function LimitedService.hasCar(data: Types.PlayerData, drop: Drop, serial: number): boolean
	for _, vehicle in data.vehicles or {} do
		if
			type(vehicle) == "table"
			and vehicle.vehicleId == drop.vehicleId
			and vehicle.trim == drop.trim
			and vehicle.serial == serial
		then
			return true
		end
	end
	return false
end

local function reply(ok: boolean, message: string, serial: number?): Reply
	return { ok = ok, message = message, serial = serial }
end

-- Drops: buying and finishing --------------------------------------------------------------------------------

-- Takes the pending entry out and gives the price back (a sold-out drop, or one no longer in the config).
local function refundPending(deps: Deps, player: Player, dropId: string, paid: number): boolean
	local added = 0
	local updated = deps.update(player, function(data: Types.PlayerData)
		local index = LimitedService.pendingIndex(data, dropId)
		if index == nil then
			return
		end
		local newBalance, gained = EconomyService.applyAdd(data.cash, paid, Economy.maxCash)
		data.cash = newBalance
		added = gained
		table.remove(data.pendingGrants, index)
	end)
	if updated and added > 0 then
		deps.recordCash(player, "source", added, Limiteds.reasons.refund)
	end
	return updated
end

-- Steps 2 and 3 for a drop the player has paid `paid` for (their pending entry is in the save). `onJoin` words the
-- answer for a purchase finishing on a later join.
function LimitedService.finish(deps: Deps, player: Player, drop: Drop, paid: number, onJoin: boolean): Reply
	local price = Economy.formatCash(paid)
	local status, serial =
		LimitedService.claimSerial(deps.store, deps.keyFor(drop.id), deps.userId(player), drop.supply)
	if status == "error" or serial == nil then
		if status == "soldOut" then
			refundPending(deps, player, drop.id, paid)
			local message = if onJoin
				then string.format(messages.refunded, drop.name, price)
				else string.format(messages.soldOut, price)
			return reply(false, message)
		end
		return reply(false, messages.pending)
	end
	local claimed: number = serial
	local outcome: "granted" | "alreadyOwned" | "gone" = "gone"
	local refunded = 0
	local updated = deps.update(player, function(data: Types.PlayerData)
		local index = LimitedService.pendingIndex(data, drop.id)
		if index == nil then
			outcome = "gone" -- finished by another call already
			return
		end
		if status == "owned" and LimitedService.hasCar(data, drop, claimed) then
			-- A second purchase of a drop this player already owns: give the price back.
			local newBalance, gained = EconomyService.applyAdd(data.cash, paid, Economy.maxCash)
			data.cash = newBalance
			refunded = gained
			table.remove(data.pendingGrants, index)
			outcome = "alreadyOwned"
			return
		end
		local vehicle = Template.ownedVehicle(deps.newUid(), drop.vehicleId, drop.trim, paid, deps.now())
		vehicle.serial = claimed
		table.insert(data.vehicles, vehicle)
		table.remove(data.pendingGrants, index)
		outcome = "granted"
	end)
	if not updated then
		return reply(false, messages.pending, claimed)
	end
	if outcome == "alreadyOwned" then
		if refunded > 0 then
			deps.recordCash(player, "source", refunded, Limiteds.reasons.refund)
		end
		return reply(false, string.format(messages.owned, claimed, price), claimed)
	elseif outcome == "gone" then
		return reply(false, messages.busy, claimed)
	end
	local template = if onJoin then messages.completed else messages.bought
	return reply(true, string.format(template, drop.name, claimed), claimed)
end

-- Step 1, then steps 2 and 3.
local function purchase(deps: Deps, player: Player, drop: Drop): Reply
	local paid = drop.price
	local problem: string? = nil
	local charged = false
	local updated = deps.update(player, function(data: Types.PlayerData)
		if LimitedService.pendingIndex(data, drop.id) ~= nil then
			problem = messages.busy
			return
		end
		if not GarageService.roomIn(data) then
			problem = messages.full
			return
		end
		local newBalance = EconomyService.applySpend(data.cash, paid)
		if newBalance == nil then
			problem = string.format(messages.cash, Economy.formatCash(paid))
			return
		end
		if type(data.pendingGrants) ~= "table" then
			data.pendingGrants = {}
		end
		data.cash = newBalance
		table.insert(
			data.pendingGrants,
			{ kind = Limiteds.pendingKind, ref = LimitedService.pendingRef(drop.id, paid) }
		)
		charged = true
	end)
	if not updated then
		return reply(false, messages.loading)
	end
	if not charged then
		return reply(false, problem or messages.loading)
	end
	deps.recordCash(player, "sink", paid, Limiteds.reasons.buy)
	return LimitedService.finish(deps, player, drop, paid, false)
end

-- Net BuyLimited: buy one serial of drop `dropId` for its in-game price (yields for the DataStore).
function LimitedService.buy(deps: Deps, player: Player, dropId: string): Reply
	if not deps.flagOn() then
		return reply(false, messages.off)
	end
	local drop = (deps.drops or Limiteds.drops)[dropId]
	if drop == nil then
		return reply(false, messages.unknown)
	end
	local state = LimitedService.windowState(drop, deps.now())
	if state == "notYet" then
		return reply(false, messages.notYet)
	elseif state == "ended" then
		return reply(false, messages.ended)
	end
	if busy[player] then
		return reply(false, messages.busy)
	end
	busy[player] = true
	local ok, result = pcall(purchase, deps, player, drop)
	busy[player] = nil
	if not ok then
		warn(`{LOG} a purchase of {dropId} failed: {result}`)
		return reply(false, messages.pending)
	end
	return result
end

-- On join: finishes (or refunds) every drop the player paid for that never reached their garage. Returns the
-- answers, one per entry (yields for the DataStore).
function LimitedService.completePending(deps: Deps, player: Player, data: Types.PlayerData): { Reply }
	local entries: { { dropId: string, paid: number } } = {}
	for _, entry in data.pendingGrants or {} do
		if type(entry) == "table" and entry.kind == Limiteds.pendingKind then
			local dropId, paid = LimitedService.parseRef(entry.ref)
			if dropId ~= nil and paid ~= nil then
				table.insert(entries, { dropId = dropId, paid = paid })
			end
		end
	end
	local replies: { Reply } = {}
	if #entries == 0 or busy[player] then
		return replies
	end
	busy[player] = true
	local drops = deps.drops or Limiteds.drops
	for _, entry in entries do
		local drop = drops[entry.dropId]
		local ok, result = pcall(function(): Reply
			if drop == nil then
				refundPending(deps, player, entry.dropId, entry.paid)
				return reply(false, string.format(messages.refunded, entry.dropId, Economy.formatCash(entry.paid)))
			end
			return LimitedService.finish(deps, player, drop, entry.paid, true)
		end)
		if ok then
			table.insert(replies, result)
		else
			warn(`{LOG} finishing {entry.dropId} failed: {result}`)
		end
	end
	busy[player] = nil
	return replies
end

-- Limited cosmetics -----------------------------------------------------------------------------------------

-- The limited cosmetic sold under a Config/Monetization-style product key, or nil.
function LimitedService.cosmeticFor(productKey: string): Cosmetic?
	for _, cosmetic in Limiteds.cosmetics do
		if cosmetic.productKey == productKey then
			return cosmetic
		end
	end
	return nil
end

-- True when the cosmetic can be offered at `now`: its product exists (id above 0), its window is open and the
-- "drops" flag is on.
function LimitedService.cosmeticAvailable(cosmetic: Cosmetic, now: number, flagOn: boolean): boolean
	return flagOn and cosmetic.productId > 0 and LimitedService.windowState(cosmetic, now) == "open"
end

-- The serial the player owns of a look (PlayerData.cosmetics, by look id: a cosmetic's `ref`), or nil.
function LimitedService.ownedSerial(data: Types.PlayerData, lookId: string): number?
	local owned: any = data.cosmetics
	if type(owned) ~= "table" then
		return nil
	end
	local serial = owned[lookId]
	return if isWhole(serial) then serial else nil
end

-- The receipt handler's work: claims the next serial and saves it. True once it is in the profile (and again for
-- a receipt delivered twice: the claim gives the same serial back). Yields for the DataStore.
function LimitedService.grantCosmetic(deps: Deps, player: Player, cosmeticId: string): boolean
	local cosmetic = (deps.cosmetics or Limiteds.cosmetics)[cosmeticId]
	if cosmetic == nil then
		warn(`{LOG} no limited cosmetic "{cosmeticId}"`)
		return false
	end
	local status, serial = LimitedService.claimSerial(deps.store, deps.keyFor(cosmetic.id), deps.userId(player), nil)
	if status == "error" or serial == nil then
		return false
	end
	local claimed: number = serial
	return deps.update(player, function(data: Types.PlayerData)
		if type(data.cosmetics) ~= "table" then
			data.cosmetics = {} -- a damaged save (schema 7 always has the table)
		end
		data.cosmetics[cosmetic.ref] = claimed
	end)
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

local function storeName(): string
	return if RunService:IsStudio() then Limiteds.studioStore else Limiteds.store
end

local function keyFor(id: string): string
	return (if RunService:IsStudio() then Limiteds.studioKeyPrefix else Limiteds.keyPrefix) .. id
end

-- The real DataStore, fetched on each call so an unreachable DataStore (Studio without API access) fails inside
-- the claim's pcall instead of at boot.
local liveStore: Store = {
	UpdateAsync = function(_self: any, key: string, transform: (old: any) -> any): any
		return DataStoreService:GetDataStore(storeName()):UpdateAsync(key, transform)
	end,
	GetAsync = function(_self: any, key: string): any
		return DataStoreService:GetDataStore(storeName()):GetAsync(key)
	end,
}

local function liveUpdate(player: Player, fn: (data: Types.PlayerData) -> ()): boolean
	local dataService = DataService
	return dataService ~= nil and dataService.update(player, fn)
end

local function liveDeps(): Deps
	return {
		store = liveStore,
		keyFor = keyFor,
		now = os.time,
		update = liveUpdate,
		userId = function(player: Player): number
			return player.UserId
		end,
		newUid = function(): string
			return HttpService:GenerateGUID(false)
		end,
		recordCash = EconomyService.recordChange,
		flagOn = flagOn,
	}
end

local function notify(player: Player, text: string)
	Net.fireClient("Notify", player, { text = text, kind = NOTIFY_KIND })
end

local function republish()
	local service = eventService
	if service ~= nil and type(service.publish) == "function" then
		task.spawn(service.publish)
	end
end

-- Drops not yet over, for the EventUpdate banner and countdowns (soonest first).
function LimitedService.publicDrops(now: number?): { PublicDrop }
	local at = now or os.time()
	local list: { PublicDrop } = {}
	if not flagOn() then
		return list
	end
	for _, drop in Limiteds.drops do
		local state = LimitedService.windowState(drop, at)
		if state ~= "ended" then
			table.insert(list, {
				id = drop.id,
				name = drop.name,
				vehicleId = drop.vehicleId,
				trim = drop.trim,
				startsAt = drop.startsAtUtc,
				endsAt = drop.endsAtUtc,
				price = drop.price,
				supply = drop.supply,
				remaining = remaining[drop.id],
				open = state == "open",
			})
		end
	end
	table.sort(list, function(a: PublicDrop, b: PublicDrop): boolean
		return if a.startsAt ~= b.startsAt then a.startsAt < b.startsAt else a.id < b.id
	end)
	return list
end

-- The next time a drop opens or closes after `now`, or nil.
function LimitedService.nextChangeAt(now: number): number?
	local soonest: number? = nil
	for _, drop in Limiteds.drops do
		for _, at in { drop.startsAtUtc, drop.endsAtUtc } do
			if at > now and (soonest == nil or at < soonest) then
				soonest = at
			end
		end
	end
	return soonest
end

-- Limited cosmetics as GetStore products (MonetizationService.storeSnapshot adds them; price comes from it).
function LimitedService.cosmeticProducts(now: number?): { CosmeticProduct }
	local at = now or os.time()
	local on = flagOn()
	local list: { CosmeticProduct } = {}
	for _, cosmetic in Limiteds.cosmetics do
		if LimitedService.windowState(cosmetic, at) ~= "ended" then
			table.insert(list, {
				key = cosmetic.productKey,
				name = cosmetic.name,
				kind = "cosmetic",
				grants = { cosmetic = cosmetic.id, look = cosmetic.kind, ref = cosmetic.ref },
				available = LimitedService.cosmeticAvailable(cosmetic, at, on),
				startsAt = cosmetic.startsAtUtc,
				endsAt = cosmetic.endsAtUtc,
			})
		end
	end
	table.sort(list, function(a: CosmeticProduct, b: CosmeticProduct): boolean
		return a.key < b.key
	end)
	return list
end

-- Before MonetizationService prompts a limited cosmetic: false and what to say when it isn't on sale now or the
-- player already owns it (a second purchase would buy nothing).
function LimitedService.canBuyCosmetic(player: Player, productKey: string): (boolean, string?)
	local cosmetic = LimitedService.cosmeticFor(productKey)
	if cosmetic == nil then
		return false, messages.unknown
	end
	local now = os.time()
	if not LimitedService.cosmeticAvailable(cosmetic, now, flagOn()) then
		local state = LimitedService.windowState(cosmetic, now)
		return false,
			if state == "ended" then messages.ended elseif state == "notYet" then messages.notYet else messages.off
	end
	local dataService = DataService
	local data = if dataService ~= nil then dataService.get(player) else nil
	if data == nil then
		return false, messages.loading
	end
	local serial = LimitedService.ownedSerial(data, cosmetic.ref)
	if serial ~= nil then
		return false, string.format(messages.ownedCosmetic, serial)
	end
	return true, nil
end

-- Re-reads the remaining supply of open drops (yields) and republishes the banner when it changed.
local function refreshRemaining()
	local changed = false
	local now = os.time()
	for _, drop in Limiteds.drops do
		if LimitedService.windowState(drop, now) == "open" then
			local ok, raw = pcall(liveStore.GetAsync, liveStore, keyFor(drop.id))
			if ok then
				local left = math.max(0, drop.supply - LimitedService.cleanRecord(raw).sold)
				if remaining[drop.id] ~= left then
					remaining[drop.id] = left
					changed = true
				end
			end
		end
	end
	if changed then
		republish()
	end
end

local function tick()
	timer = task.delay(Limiteds.refreshSeconds, tick)
	refreshRemaining()
end

local function onBuy(player: Player, payload: any): Reply
	local dropId: string = payload.dropId
	local result = LimitedService.buy(liveDeps(), player, dropId)
	local drop = Limiteds.drops[dropId]
	if result.serial ~= nil and drop ~= nil then
		local left = math.max(0, drop.supply - result.serial)
		local known = remaining[dropId]
		if known == nil or left < known then
			remaining[dropId] = left
			republish()
		end
	end
	return result
end

local function onLoaded(player: Player, data: Types.PlayerData)
	for _, answer in LimitedService.completePending(liveDeps(), player, data) do
		notify(player, answer.message)
	end
end

local function registerCosmetics()
	local service = monetization
	if service == nil or type(service.registerProduct) ~= "function" then
		warn(`{LOG} MonetizationService.registerProduct isn't there: limited cosmetics can't be sold`)
		return
	end
	for _, cosmetic in Limiteds.cosmetics do
		local id = cosmetic.id
		local ok, err = pcall(
			service.registerProduct,
			cosmetic.productKey,
			function(player: Player, _receipt: any): boolean
				return LimitedService.grantCosmetic(liveDeps(), player, id)
			end
		)
		if not ok then
			warn(`{LOG} couldn't register {cosmetic.productKey}: {err}`)
		end
	end
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

function LimitedService:Init()
	DataService = require(script.Parent.DataService)
	flagService = optional("FeatureFlagService")
	eventService = optional("EventService")
	monetization = optional("MonetizationService")
end

function LimitedService:Start()
	Net.onServerInvoke("BuyLimited", onBuy)
	registerCosmetics()
	Players.PlayerRemoving:Connect(function(player: Player)
		busy[player] = nil
	end)
	local dataService = DataService
	if dataService ~= nil then
		dataService.onLoaded(onLoaded)
	end
	if timer == nil then
		task.spawn(tick)
	end
end

return LimitedService
