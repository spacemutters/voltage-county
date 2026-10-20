--!strict
-- The used lot (PLAN.md Phase 4; docs/phase-4-contracts.md "Commerce"): the free starter car, and a daily stock
-- of classics with a global supply cap and prices that rise as copies sell.
--
-- The day's stock is Config/UsedLot.stockFor(the UTC date): pure and deterministic, so every server shows the
-- same cars on the same day. On Start (and again at each UTC midnight) a display copy of each space's car stands
-- on its numbered pad (Config/MapLayout usedLot) in Workspace.Showroom.UsedLot, with a "View" prompt carrying the
-- space's Slot (DealershipService.placeDisplayCar).
--
-- Global supply: each space sells at most its supply per day across every server. The count lives in the
-- Config/UsedLot DataStore under "<date>:<slot>", and DataStore:UpdateAsync adds one only while sold < supply
-- (atomic across servers). The price charged is UsedLot.price for the count before that sale. The order is:
-- reserve a copy, then charge, then add the car; if the charge fails the copy is given back, and if adding the
-- car fails the cash is refunded and the copy given back. Only when the store can't be used at all (it couldn't
-- be opened, or Studio has no API access) do the counts live in this server's memory instead, seeded with the
-- last count this server read, and that is logged once. On a live server any other store error refuses the
-- sale (messages.busy), so an outage never sells past the global cap.
--
-- Remotes (declared in Net, which has already checked each payload's shape and rate-limited it):
--   ClaimStarter           function: the free used Ohm Spark, once per player (starterClaimed), paid 0, brought out
--                          at the nearest spawn pad. Answers { ok, message, uid? }. SpawnFlowService's "Claim your
--                          free car" prompt calls claimStarter too.
--   GetUsedLot             function: today's stock with prices and what's left. Answers
--                          { ok, message, date, starterClaimed, stock = { Offer } } (Offer below).
--   BuyUsed { slot, date, maxPrice } function: buys one copy of that space's car. `date` and `maxPrice` are the
--                          lot day and the price the player's confirm showed: a changed day or a higher price
--                          is refused with priceChanged = true (and the new price), never charged. Answers
--                          { ok, message, uid?, price?, priceChanged? }.
-- Every refusal is logged with the player and the reason.
--
-- Server-authoritative (CLAUDE.md hard rule 1): the client names a space; the server works out the car and the
-- price. No polling: remote calls, plus one task.delay to the next UTC midnight.

local DataStoreService = game:GetService("DataStoreService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage.Shared
local Catalog = require(Shared.Vehicle.Catalog)
local Dealership = require(Shared.Config.Dealership)
local Economy = require(Shared.Config.Economy)
local MapLayout = require(Shared.Config.MapLayout)
local Net = require(Shared.Net)
local Types = require(Shared.Types)
local UsedLot = require(Shared.Config.UsedLot)
local DealershipService = require(script.Parent.DealershipService)
local EconomyService = require(script.Parent.EconomyService)

-- DataService and GarageService are required in Init rather than here: DataService loads ProfileStore, which
-- talks to DataStores straight away, and tests/UsedLot.spec requires this module in Edit mode.
type DataServiceModule = typeof(require(script.Parent.DataService))
type GarageServiceModule = typeof(require(script.Parent.GarageService))

-- One space as GetUsedLot shows it.
export type Offer = {
	slot: number,
	vehicleId: string,
	trim: string,
	basePrice: number,
	supply: number, -- copies for sale today across every server
	sold: number, -- copies sold so far (as this server last read it)
	remaining: number, -- supply - sold, never below 0
	price: number, -- what the next copy costs (0 when sold out)
}

export type LotReply = {
	ok: boolean,
	message: string,
	date: string, -- "YYYY-MM-DD" (UTC)
	starterClaimed: boolean,
	stock: { Offer },
}

export type Reply = { ok: boolean, message: string, uid: string?, price: number?, priceChanged: boolean? }

type Backend = "store" | "memory"
type Outcome = "reserved" | "soldOut" | "busy"
local STORE: Backend = "store"
local MEMORY: Backend = "memory"
type Cached = { sold: number, at: number }

local LOG = "[UsedLotService]"
local RELEASE_ATTEMPTS = 3 -- giving a reserved copy back is retried this many times before it's logged
local RELEASE_RETRY_SECONDS = 1

local messages = UsedLot.messages

local UsedLotService = {}

local DataService: DataServiceModule? = nil
local GarageService: GarageServiceModule? = nil

local store: DataStore? = nil
local storeChecked = false
local fallbackLogged = false
local memory: { [string]: number } = {} -- copies sold per key while the store can't be used
local soldCache: { [string]: Cached } = {}
local today = ""
local todayStock: { UsedLot.StockEntry } = {}

-- Pure helpers (the contract's names; the logic lives in Config/UsedLot so clients can run it too) -----------

-- The day's stock for a UTC date key ("YYYY-MM-DD"). Pure and deterministic.
function UsedLotService.stockFor(dateKey: string): { UsedLot.StockEntry }
	return UsedLot.stockFor(dateKey)
end

-- The price of the next copy after `sold` of `supply`: base x (1 + rise x sold / supply), capped.
function UsedLotService.price(base: number, sold: number, supply: number): number
	return UsedLot.price(base, sold, supply)
end

-- A stored count as a whole number of copies, never negative (guards against a damaged value).
function UsedLotService.cleanCount(value: any): number
	if type(value) ~= "number" or value ~= value or value == math.huge or value < 0 then
		return 0
	end
	return math.floor(value)
end

-- Supply counters -------------------------------------------------------------------------------------------

local function logFallback(why: any)
	if not fallbackLogged then
		fallbackLogged = true
		warn(`{LOG} DataStores can't be reached, so used-lot supply is counted in this server's memory: {why}`)
	end
end

local function getStore(): DataStore?
	if not storeChecked then
		storeChecked = true
		local name = if RunService:IsStudio() then UsedLot.studioStoreName else UsedLot.storeName
		local ok, result = pcall(function(): DataStore
			return DataStoreService:GetDataStore(name)
		end)
		if ok then
			store = result
		else
			logFallback(result)
		end
	end
	return store
end

-- A store call failed. In Studio (no API access, an unpublished place) the counts move to this server's memory
-- for the rest of the session: there are no other servers to share them with. True when they did. On a live
-- server the error is only logged, and the caller refuses: a failure is never a free copy.
local function storeFailed(why: any): boolean
	if RunService:IsStudio() then
		logFallback(why)
		store = nil -- storeChecked stays true, so getStore keeps answering nil
		return true
	end
	warn(`{LOG} The used-lot supply store failed: {why}`)
	return false
end

-- The memory count of a key, never below the last count this server read for it.
local function memoryCount(key: string): number
	local cached = soldCache[key]
	local sold = math.max(memory[key] or 0, if cached ~= nil then cached.sold else 0)
	memory[key] = sold
	return sold
end

-- Copies of a space sold so far, read at most every soldCacheSeconds, and whether that count is current. When a
-- live server can't read the store it answers the last count it read (0 if none) and false.
local function soldFor(key: string): (number, boolean)
	local cached = soldCache[key]
	if cached ~= nil and os.clock() - cached.at < UsedLot.soldCacheSeconds then
		return cached.sold, true
	end
	local dataStore = getStore()
	if dataStore ~= nil then
		local ok, value = pcall(function(): any
			return dataStore:GetAsync(key)
		end)
		if ok then
			local sold = UsedLotService.cleanCount(value)
			soldCache[key] = { sold = sold, at = os.clock() }
			return sold, true
		end
		if not storeFailed(value) then
			return (if cached ~= nil then cached.sold else 0), false
		end
	end
	local sold = memoryCount(key)
	soldCache[key] = { sold = sold, at = os.clock() }
	return sold, true
end

-- Takes one copy of a space if any are left: "reserved", "soldOut" or "busy" (the store failed on a live
-- server), the count before, and where it counted.
local function reserve(key: string, supply: number): (Outcome, number, Backend)
	local dataStore = getStore()
	if dataStore ~= nil then
		local outcome: Outcome = "soldOut"
		local before = 0
		local ok, err = pcall(function()
			dataStore:UpdateAsync(key, function(old: any): any
				-- May run more than once; the last run is the one that counts.
				local sold = UsedLotService.cleanCount(old)
				before = sold
				if sold >= supply then
					outcome = "soldOut"
					return nil -- cancels the write
				end
				outcome = "reserved"
				return sold + 1
			end)
		end)
		if ok then
			return outcome, before, STORE
		end
		if not storeFailed(err) then
			return "busy", 0, STORE
		end
	end
	local sold = memoryCount(key)
	if sold >= supply then
		return "soldOut", sold, MEMORY
	end
	memory[key] = sold + 1
	return "reserved", sold, MEMORY
end

-- Gives a reserved copy back, where it was taken.
local function release(key: string, backend: Backend)
	local cached = soldCache[key]
	if cached ~= nil then
		cached.sold = math.max(cached.sold - 1, 0)
	end
	if backend == MEMORY then
		memory[key] = math.max((memory[key] or 0) - 1, 0)
		return
	end
	local dataStore = getStore()
	if dataStore == nil then
		return
	end
	for attempt = 1, RELEASE_ATTEMPTS do
		local ok, err = pcall(function()
			dataStore:UpdateAsync(key, function(old: any): any
				return math.max(UsedLotService.cleanCount(old) - 1, 0)
			end)
		end)
		if ok then
			return
		end
		if attempt == RELEASE_ATTEMPTS then
			warn(`{LOG} Couldn't give back a reserved copy of {key}: {err}`)
		else
			task.wait(RELEASE_RETRY_SECONDS)
		end
	end
end

-- The day's stock and display cars -------------------------------------------------------------------------

-- Moves to the current UTC day if it has changed. True when it did.
local function ensureToday(): boolean
	local key = UsedLot.dateKey(os.time())
	if key == today then
		return false
	end
	today = key
	todayStock = UsedLot.stockFor(key)
	soldCache = {}
	memory = {} -- yesterday's counts are no use; today's keys are new
	return true
end

-- A display copy of each space's car on its numbered pad.
local function buildDisplays()
	local folder = DealershipService.showroomFolder(Dealership.display.usedLotFolderName)
	folder:ClearAllChildren()
	local layout = MapLayout.usedLot
	local count = 0
	for _, entry in todayStock do
		if entry.slot > #layout.pads then
			continue
		end
		local pad = layout.pads[entry.slot]
		local vehicle = Catalog.getVehicle(entry.vehicleId)
		local model = DealershipService.placeDisplayCar({
			vehicleId = entry.vehicleId,
			trim = entry.trim,
			pad = pad,
			padHeight = layout.padSize.Y,
			parent = folder,
			name = `Space{entry.slot}`,
			attributes = { [Dealership.prompt.slotAttribute] = entry.slot },
			objectText = if vehicle then vehicle.displayName else entry.vehicleId,
		})
		if model ~= nil then
			count += 1
		end
	end
	print(`{LOG} {today}: {count} used cars on the lot`)
end

-- Restocks at every UTC midnight.
local function scheduleRestock()
	task.delay(UsedLot.secondsUntilNextDay(os.time()) + 1, function()
		if ensureToday() then
			buildDisplays()
		end
		scheduleRestock()
	end)
end

-- A day change noticed by a remote call (before the timer) restocks the lot too.
local function refreshDay()
	if ensureToday() then
		task.spawn(buildDisplays)
	end
end

-- Helpers ---------------------------------------------------------------------------------------------------

local function reply(ok: boolean, message: string): Reply
	return { ok = ok, message = message }
end

local function logRejection(player: Player, action: string, reason: string, detail: string)
	warn(`{LOG} {action} refused for {player.Name} ({player.UserId}): {reason} ({detail})`)
end

local function trimName(vehicleId: string, trimId: string): string
	local trim = Catalog.getTrim(vehicleId, trimId)
	if trim ~= nil then
		return trim.displayName
	end
	local vehicle = Catalog.getVehicle(vehicleId)
	return if vehicle ~= nil then vehicle.displayName else vehicleId
end

local function shortBy(price: number, cash: number): string
	return string.format(messages.noCash, Economy.formatCash(math.max(price - cash, 0)))
end

-- Starter -----------------------------------------------------------------------------------------------------

-- Gives the player their free used Ohm Spark, once ever (PlayerData.starterClaimed), and brings it out at the
-- nearest spawn pad. The flag is set first, inside one data update, so two claims at once can't both pass; it is
-- cleared again if the car couldn't be added.
function UsedLotService.claimStarter(player: Player): Reply
	local dataService, garage = DataService, GarageService
	local data = if dataService ~= nil then dataService.get(player) else nil
	if dataService == nil or garage == nil or data == nil then
		logRejection(player, "ClaimStarter", "notLoaded", "data not loaded")
		return reply(false, messages.notLoaded)
	end
	if data.starterClaimed then
		return reply(false, messages.starterAlready)
	end
	if not garage.hasRoom(player) then
		logRejection(player, "ClaimStarter", "noRoom", "garage full")
		return reply(false, messages.starterNoRoom)
	end
	local claimed = false
	local updated = dataService.update(player, function(fresh: Types.PlayerData)
		if fresh.starterClaimed then
			return
		end
		fresh.starterClaimed = true
		claimed = true
	end)
	if not updated then
		return reply(false, messages.notLoaded)
	elseif not claimed then
		return reply(false, messages.starterAlready)
	end
	local starter = UsedLot.starter
	local uid = garage.addVehicle(player, starter.vehicleId, starter.trim, 0)
	if uid == nil then
		dataService.update(player, function(fresh: Types.PlayerData)
			fresh.starterClaimed = false
		end)
		logRejection(player, "ClaimStarter", "addFailed", "the starter couldn't be added; claim undone")
		return reply(false, messages.starterFailed)
	end
	print(`{LOG} {player.Name} ({player.UserId}) claimed the free {starter.vehicleId}/{starter.trim}`)
	DealershipService.endTestDrive(player, false) -- the garage won't bring a car out over a test drive
	local spawned = garage.spawnOwned(player, uid)
	local vehicle = Catalog.getVehicle(starter.vehicleId)
	local name = if vehicle then vehicle.displayName else starter.vehicleId
	local text = if spawned.ok then messages.starterClaimed else messages.starterInGarage
	return { ok = true, message = string.format(text, name), uid = uid }
end

-- Remotes ---------------------------------------------------------------------------------------------------

-- Today's stock with this server's latest counts.
function UsedLotService.offers(): { Offer }
	refreshDay()
	local list: { Offer } = {}
	for _, entry in todayStock do
		local sold = soldFor(UsedLot.supplyKey(today, entry.slot)) -- the last count read if the store failed
		local remaining = math.max(entry.supply - sold, 0)
		table.insert(list, {
			slot = entry.slot,
			vehicleId = entry.vehicleId,
			trim = entry.trim,
			basePrice = entry.basePrice,
			supply = entry.supply,
			sold = sold,
			remaining = remaining,
			price = if remaining > 0 then UsedLot.price(entry.basePrice, sold, entry.supply) else 0,
		})
	end
	return list
end

local function onGetUsedLot(player: Player): LotReply
	local dataService = DataService
	local data = if dataService ~= nil then dataService.get(player) else nil
	local stock = UsedLotService.offers()
	return {
		ok = true,
		message = "",
		date = today,
		starterClaimed = data ~= nil and data.starterClaimed == true,
		stock = stock,
	}
end

-- The player's confirm showed a lower price than the next copy now costs.
local function priceChangedReply(price: number): Reply
	return {
		ok = false,
		message = string.format(messages.priceChanged, Economy.formatCash(price)),
		price = price,
		priceChanged = true,
	}
end

local function onBuyUsed(player: Player, payload: any): Reply
	refreshDay()
	local slot: number, shownDate: string, maxPrice: number = payload.slot, payload.date, payload.maxPrice
	if shownDate ~= today then
		-- The sheet was opened on another day: that space now holds a different car.
		logRejection(player, "BuyUsed", "lotChanged", `slot {slot}, shown {shownDate}, today {today}`)
		return { ok = false, message = messages.lotChanged, priceChanged = true }
	end
	local entry = todayStock[slot]
	if entry == nil then
		logRejection(player, "BuyUsed", "unknownSlot", `slot {slot}`)
		return reply(false, messages.unknownSlot)
	end
	local dataService, garage = DataService, GarageService
	if dataService == nil or garage == nil or dataService.get(player) == nil then
		logRejection(player, "BuyUsed", "notLoaded", `slot {slot}`)
		return reply(false, messages.notLoaded)
	end
	local detail = `slot {slot} ({entry.vehicleId}/{entry.trim})`
	if not garage.hasRoom(player) then
		logRejection(player, "BuyUsed", "noRoom", detail)
		return reply(false, messages.noRoom)
	end
	-- A first check from this server's count, so a player who can't afford it never touches the store.
	local dateKey = today
	local key = UsedLot.supplyKey(dateKey, slot)
	local known, current = soldFor(key)
	if not current then
		logRejection(player, "BuyUsed", "busy", `{detail}: the supply count couldn't be read`)
		return reply(false, messages.busy)
	end
	if known >= entry.supply then
		return reply(false, messages.soldOut)
	end
	local cash = EconomyService.getCash(player)
	local estimate = UsedLot.price(entry.basePrice, known, entry.supply)
	if estimate > maxPrice then
		logRejection(player, "BuyUsed", "priceChanged", `{detail}: shown {maxPrice}, now {estimate}`)
		return priceChangedReply(estimate)
	end
	if cash < estimate then
		logRejection(player, "BuyUsed", "noCash", `{detail}, cash {cash}, price {estimate}`)
		return reply(false, shortBy(estimate, cash))
	end

	-- Reserve one copy across every server, then charge for it at the count before that sale.
	local outcome, before, backend: Backend = reserve(key, entry.supply)
	if outcome == "busy" then
		logRejection(player, "BuyUsed", "busy", `{detail}: the supply count couldn't be updated`)
		return reply(false, messages.busy)
	end
	soldCache[key] = { sold = if outcome == "reserved" then before + 1 else before, at = os.clock() }
	if outcome == "soldOut" then
		return reply(false, messages.soldOut)
	end
	local price = UsedLot.price(entry.basePrice, before, entry.supply)
	if price > maxPrice then
		-- Another server sold a copy since the first check: give this one back rather than charge more.
		release(key, backend)
		logRejection(player, "BuyUsed", "priceChanged", `{detail}: shown {maxPrice}, now {price}`)
		return priceChangedReply(price)
	end
	if not EconomyService.trySpend(player, price, UsedLot.reasons.buy) then
		release(key, backend)
		local now = EconomyService.getCash(player)
		logRejection(player, "BuyUsed", "noCash", `{detail}: charge refused, cash {now}, price {price}`)
		return reply(false, shortBy(price, now))
	end
	local uid = garage.addVehicle(player, entry.vehicleId, entry.trim, price)
	if uid == nil then
		EconomyService.add(player, price, UsedLot.reasons.refund)
		release(key, backend)
		logRejection(player, "BuyUsed", "addFailed", `{detail}: refunded {price}`)
		return reply(false, messages.buyFailed)
	end
	print(`{LOG} {player.Name} ({player.UserId}) bought {detail} for {price} ({dateKey}, copy {before + 1})`)
	DealershipService.endTestDrive(player, false) -- the garage won't bring a car out over a test drive
	local spawned = garage.spawnOwned(player, uid)
	local text = if spawned.ok then messages.bought else messages.boughtInGarage
	local name = trimName(entry.vehicleId, entry.trim)
	return { ok = true, message = string.format(text, name, Economy.formatCash(price)), uid = uid, price = price }
end

-- Boot ------------------------------------------------------------------------------------------------------

function UsedLotService:Init()
	DataService = require(script.Parent.DataService)
	GarageService = require(script.Parent.GarageService)
end

function UsedLotService:Start()
	Net.onServerInvoke("ClaimStarter", function(player: Player): Reply
		return UsedLotService.claimStarter(player)
	end)
	Net.onServerInvoke("GetUsedLot", onGetUsedLot)
	Net.onServerInvoke("BuyUsed", onBuyUsed)
	ensureToday()
	buildDisplays()
	scheduleRestock()
end

return UsedLotService
