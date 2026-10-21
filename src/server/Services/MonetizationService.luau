--!strict
-- Everything sold for Robux (PLAN.md Phase 12 and §11; docs/phase-12-contracts.md "Monetization core"): developer
-- product receipts, game pass checks, the Voltage Club subscription, the store payload and the purchase prompts.
-- Ids, grants and words live in Config/Monetization and Config/Offers; prices only ever come from MarketplaceService.
--
-- Receipts (MarketplaceService.ProcessReceipt, set here and nowhere else):
--   The product id names a product key (Config/Monetization.products, or one another service registered with
--   registerProduct). The buyer must be in this server with their save loaded (we wait up to
--   Config/Monetization.receiptWaitSeconds while it loads); otherwise the answer is NotProcessedYet and Roblox
--   retries later. A PurchaseId already in PlayerData.receipts is never granted again. Otherwise the grant and the
--   PurchaseId (the newest Config/Data.maxReceipts are kept) land in ONE DataService.update. PurchaseGranted is
--   returned only once the DataStore holds that receipt (DataService.saveConfirmed asks ProfileStore to save and
--   waits up to Config/Monetization.receiptSaveSeconds), as Roblox and ProfileStore advise: Roblox never delivers an
--   acknowledged receipt again, so a grant that only lived in memory when a server crashed would be lost. Not saved
--   in time: NotProcessedYet, and the redelivery finds the receipt already granted and waits for the save again. So
--   the same receipt delivered any number of times grants exactly once, and a grant is never recorded without its
--   receipt or the other way round.
--     credit packs   Design Credits through CreditsService's own rules (Ledger.grant), plus the pack's bonus and any
--                    event bonus (EventService.bonusCredits: a share of the pack's credits, while an event runs)
--     cash packs     in-game $ (EconomyService.applyAdd in the update, then recordChange: the HUD and analytics)
--     custom slot    +1 saved custom-car slot
--     Starter Pack   its grant, and PlayerData.offersSeen marks the offer bought: it is never offered or sold again
--                    (a second receipt from two prompts that raced is still honoured: the player paid for it)
--     registered     another service's handler (limited cosmetics): it grants by itself and returns true, then the
--                    PurchaseId is recorded. It may run again for the same PurchaseId if recording fails, so such a
--                    handler must recognise a PurchaseId it already granted.
--   An id of 0 never matches a receipt: nothing is granted for a product that hasn't been created. A product that
--   grants an exclusive look the Wrap & Tint shop doesn't have yet (Config/Customization.lookExists) isn't ready
--   (productReady): it is never prompted and the store shows it as coming soon, whatever its id, so nobody pays for
--   a look that does nothing.
--
-- Passes: hasPass(player, key) asks UserOwnsGamePassAsync once per player and pass (concurrent askers share the one
-- call) and caches the answer for the session; PromptGamePassPurchaseFinished updates it at once. A pass id of 0
-- means nobody owns it and no call is made. A check that fails on join is tried again (Config/Monetization
-- passRetries, passRetrySeconds apart), so one Roblox error doesn't cost an owner their perks for the session, as
-- hasPassCached (VIP pay, slots) never asks. onPassChanged listeners hear every change. Owned passes are mirrored to
-- player attributes (Config/Monetization.attributes.passPrefix .. key) and so are the slots passes and the club add
-- (garageBonus / customBonus, read by GarageService and the snapshot); slots from passes and the club are never
-- written into the save, so they stop the moment a pass or the club does.
--
-- The Voltage Club: membership is read on join and on Players.UserSubscriptionStatusChanged
-- (GetUserSubscriptionStatusAsync.IsSubscribed), and again when the member's paid billing cycle ends (one timer per
-- player, from GetUserSubscriptionPaymentHistoryAsync). A failed check keeps what we knew and checks again after
-- club.minRecheckSeconds. While a member, the monthly credits are granted once per billing month: the month the paid,
-- unrefunded cycle covering now started, saved in PlayerData.club.lastGrantMonth inside the same update. Credits are
-- only ever paid for a cycle Roblox lists as paid: while the payment history can't be read or lists no paid cycle
-- covering now (a new subscription not listed yet, a lapse Roblox hasn't flipped yet), nothing is granted and the
-- member is checked again after club.minRecheckSeconds. (Studio's DevPurchase club has no payments: it counts the
-- calendar month.) Perks (slots, cosmetics, the club attribute) switch off as soon as a check says it lapsed.
--
-- Remotes (declared in Net, which checks shapes and rate limits): BuyProduct { key }, BuyPass { key }, JoinClub,
-- GetStore -> storeSnapshot (waits for a save that is still loading, up to receiptWaitSeconds, so the first store a
-- player sees can be bought from; it also carries the daily `streak` and the `events` payload when those services
-- run), DevPurchase { key, purchaseId? } (Studio only: runs the real receipt path with a made-up PurchaseId for a
-- product key, or marks a pass key or the club key owned for this session), and StoreUpdate (to the player after
-- anything they own changes, and when one of an offer's moments happens: the store payload plus `changed`).
--
-- Server-authoritative (CLAUDE.md hard rule 1): clients name a key, never an amount; the server decides every grant.
-- No polling: receipts, prompts, joins, subscription events and one club timer per member drive everything.
--
-- Specs (tests/Monetization.spec, tests/Club.spec) swap Roblox and the other services out with setDeps (a fake
-- marketplace, save, clock and Studio flag) and drive the real handlers in Edit mode.

local HttpService = game:GetService("HttpService")
local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Customization = require(ReplicatedStorage.Shared.Config.Customization)
local Data = require(ReplicatedStorage.Shared.Config.Data)
local Economy = require(ReplicatedStorage.Shared.Config.Economy)
local FeatureFlags = require(ReplicatedStorage.Shared.Config.FeatureFlags)
local Limiteds = require(ReplicatedStorage.Shared.Config.Limiteds)
local Monetization = require(ReplicatedStorage.Shared.Config.Monetization)
local Net = require(ReplicatedStorage.Shared.Net)
local OffersConfig = require(ReplicatedStorage.Shared.Config.Offers)
local Types = require(ReplicatedStorage.Shared.Types)
local CreditsService = require(script.Parent.CreditsService)
local EconomyService = require(script.Parent.EconomyService)

-- DataService and ProfileSyncService are required in Init rather than here: DataService loads ProfileStore, which
-- talks to DataStores straight away, and the specs require this module in Edit mode.
type DataServiceModule = typeof(require(script.Parent.DataService))
type ProfileSyncServiceModule = typeof(require(script.Parent.ProfileSyncService))

type Config = Monetization.Monetization
type Grant = Monetization.Grant
type Offer = OffersConfig.Offer

export type Reply = { ok: boolean, message: string, comingSoon: boolean? }

-- A registered product's handler: grant the purchase and return true, or return false to have Roblox retry.
export type ProductHandler = (player: Player, receiptInfo: { [string]: any }) -> boolean
-- productId: the product's id when it isn't in Config/Monetization.products (0 or missing = not created);
-- name: shown in the store (left out of the store without one); available: false keeps it out of the store.
export type ProductOptions = { productId: number?, name: string?, available: boolean? }

export type PassListener = (player: Player, owned: boolean) -> ()
export type ClubListener = (player: Player, member: boolean) -> ()
export type GrantListener = (player: Player, key: string, purchaseId: string) -> ()

-- What a grant really added (credits and cash stop at their caps; cosmetics counts looks new to the player).
export type Applied = { credits: number, cash: number, customSlots: number, cosmetics: number }

-- The GetStore payload (docs/phase-12-contracts.md pinned shape). price is Robux from MarketplaceService, or nil
-- while the item isn't created or its price couldn't be read; available = false shows "Coming soon".
export type StoreProduct = {
	key: string,
	name: string,
	kind: string,
	grants: { [string]: any },
	price: number?,
	available: boolean,
	canBuy: boolean, -- available and not refused (note says why not)
	owned: boolean?, -- a one-time product already bought (the Starter Pack)
	note: string?,
	startsAt: number?, -- limited cosmetics: their sale window (Unix seconds, UTC)
	endsAt: number?,
}
export type StorePass = {
	key: string,
	name: string,
	perks: { string },
	price: number?,
	owned: boolean,
	available: boolean,
}
export type StoreClub = {
	available: boolean,
	member: boolean,
	price: number?, -- Robux, when the subscription is priced in Robux
	displayPrice: string?, -- the local-currency price as Roblox formats it, when it gives one
	monthlyCredits: number,
	name: string,
	perks: { string },
}
-- shown: the offer was taken (PlayerData.offersSeen: bought), so it never shows again; due: one of its moments has
-- happened, it isn't taken and its product is on sale (the store UI decides when to put it on screen).
export type StoreOffer = { id: string, productKey: string, shown: boolean, due: boolean }
export type StorePayload = {
	open: boolean, -- false while the store's feature flag is off (nothing can be bought)
	products: { StoreProduct },
	passes: { StorePass },
	club: StoreClub,
	offers: { StoreOffer },
	credits: number, -- the player's Design Credits balance
	streak: any?, -- StreakService.status (the daily reward), when it runs and the save has loaded
	events: any?, -- EventService.payload ({ now, active, upcoming, drops }), when it runs
	changed: { kind: string, key: string }?, -- StoreUpdate only: what changed
}

-- The save as this service uses it (DataService, or a fake in the specs).
export type DataAccess = {
	get: (player: Player) -> Types.PlayerData?,
	update: (player: Player, fn: (data: Types.PlayerData) -> ()) -> boolean,
	waitFor: (player: Player, timeout: number?) -> Types.PlayerData?,
	-- Saves now and yields until the data as saved to the DataStore passes `check` (DataService.saveConfirmed);
	-- false when it didn't within `timeout`. A save without it (a spec's fake that doesn't model saving) counts
	-- every update as saved.
	saveConfirmed: ((player: Player, check: (saved: any) -> boolean, timeout: number) -> boolean)?,
}

-- Everything outside this module it talks to; setDeps swaps any of them (the specs do).
export type Deps = {
	marketplace: any, -- MarketplaceService
	data: DataAccess?,
	config: Config,
	offers: { [string]: Offer },
	clock: () -> number, -- os.time() seconds (UTC)
	isStudio: () -> boolean,
	playerByUserId: (userId: number) -> Player?,
	setAttribute: (player: Player, name: string, value: any) -> (),
	sendStore: (player: Player, payload: StorePayload) -> (), -- StoreUpdate
	notify: (player: Player, text: string) -> (),
	push: (player: Player) -> (), -- a fresh profile snapshot (slot counts changed)
	recordCash: (player: Player, amount: number, reason: string) -> (),
	eventBonus: (now: number) -> number, -- share of a credit pack's credits added by a running event
	schedule: (seconds: number, fn: () -> ()) -> thread?,
	cancel: (thread: thread) -> (),
	spawn: (fn: () -> ()) -> (),
	guid: () -> string,
	-- LimitedService once it exists (Phase 12 live-ops): cosmeticProducts(now) for the store and
	-- canBuyCosmetic(player, key) before a prompt. nil: no limited cosmetics.
	limited: any,
	limitedIds: () -> { [string]: number }, -- Config/Limiteds.productIds: ids of registered limited cosmetics
	flagOn: (name: string) -> boolean, -- FeatureFlagService.isOn, or Config/FeatureFlags defaults before it exists
	lookExists: (lookId: string) -> boolean, -- Config/Customization.lookExists: the Wrap & Tint shop has this look
	streakOf: (player: Player) -> any?, -- StreakService.status for the store payload (nil: not running)
	eventsNow: () -> any?, -- EventService.payload for the store payload (nil: not running)
}

local LOG = "[MonetizationService]"
local MAX_EVENT_SHARE = 1 -- an event can at most double a pack's credits, whatever EventService says
local DEV_PREFIX = "dev-" -- made-up PurchaseIds from DevPurchase
local UNNUMBERED = 0 -- PlayerData.cosmetics serial of a look that isn't numbered (the Starter Pack's wrap)

local NOT_YET = Enum.ProductPurchaseDecision.NotProcessedYet
local GRANTED = Enum.ProductPurchaseDecision.PurchaseGranted

local MonetizationService = {}

local DataService: DataServiceModule? = nil
local ProfileSyncService: ProfileSyncServiceModule? = nil
local eventModule: any = nil -- EventService once it exists (Phase 12 live-ops), resolved in Init
local limitedModule: any = nil -- LimitedService once it exists (Phase 12 live-ops), resolved in Init
local flagModule: any = nil -- FeatureFlagService once it exists (Phase 12 live-ops), resolved in Init
local streakModule: any = nil -- StreakService once it exists (Phase 12 live-ops), resolved in Init

-- Per-player state, from join to leave.
local known: { [Player]: boolean } = {}
local passCache: { [Player]: { [string]: boolean } } = {}
local studioPasses: { [Player]: { [string]: boolean } } = {} -- DevPurchase, Studio only
local clubMembers: { [Player]: boolean } = {}
local studioClub: { [Player]: boolean } = {} -- DevPurchase, Studio only
local clubTimers: { [Player]: thread } = {}
-- Which of each offer's moments (Config/Offers showAfter) had happened at the last look, per player and offer.
local offerState: { [Player]: { [string]: { [string]: boolean } } } = {}

local passListeners: { [string]: { PassListener } } = {}
local clubListeners: { ClubListener } = {}
local grantListeners: { GrantListener } = {}
local registered: { [string]: { handler: ProductHandler, options: ProductOptions } } = {}
local processing: { [string]: boolean } = {} -- PurchaseIds being granted right now
local inflight: { [string]: { thread } } = {} -- lookups running now, and who waits for them
type PriceEntry = { value: any, at: number }
local priceCache: { [string]: PriceEntry } = {}

-- Dependencies --------------------------------------------------------------------------------------------------

local function defaultEventBonus(now: number): number
	local service = eventModule
	if service == nil or type(service.bonusCredits) ~= "function" then
		return 0
	end
	local ok, value = pcall(service.bonusCredits, now)
	if not ok then
		warn(`{LOG} EventService.bonusCredits failed: {value}`)
		return 0
	end
	return if type(value) == "number" then value else 0
end

local function defaultDeps(): Deps
	return {
		marketplace = MarketplaceService,
		data = DataService :: any,
		config = Monetization,
		offers = OffersConfig,
		clock = os.time,
		isStudio = function(): boolean
			return RunService:IsStudio()
		end,
		playerByUserId = function(userId: number): Player?
			return Players:GetPlayerByUserId(userId)
		end,
		setAttribute = function(player: Player, name: string, value: any)
			player:SetAttribute(name, value)
		end,
		sendStore = function(player: Player, payload: StorePayload)
			if player.Parent == Players then
				Net.fireClient("StoreUpdate", player, payload)
			end
		end,
		notify = function(player: Player, text: string)
			if player.Parent == Players then
				Net.fireClient("Notify", player, { text = text, kind = Monetization.notifyKind })
			end
		end,
		push = function(player: Player)
			local sync = ProfileSyncService
			if sync ~= nil and player.Parent == Players then
				sync.push(player)
			end
		end,
		recordCash = function(player: Player, amount: number, reason: string)
			EconomyService.recordChange(player, "source", amount, reason)
		end,
		eventBonus = defaultEventBonus,
		schedule = function(seconds: number, fn: () -> ()): thread?
			return task.delay(seconds, fn)
		end,
		cancel = function(thread: thread)
			pcall(task.cancel, thread)
		end,
		spawn = function(fn: () -> ())
			task.spawn(fn)
		end,
		guid = function(): string
			return HttpService:GenerateGUID(false)
		end,
		limited = limitedModule,
		limitedIds = Limiteds.productIds,
		flagOn = function(name: string): boolean
			local service = flagModule
			if service ~= nil and type(service.isOn) == "function" then
				local ok, on = pcall(service.isOn, name)
				if ok and type(on) == "boolean" then
					return on
				end
			end
			return FeatureFlags.defaults[name] == true
		end,
		lookExists = Customization.lookExists,
		streakOf = function(player: Player): any?
			local service = streakModule
			if service == nil or type(service.status) ~= "function" then
				return nil
			end
			local ok, status = pcall(service.status, player)
			return if ok and type(status) == "table" then status else nil
		end,
		eventsNow = function(): any?
			local service = eventModule
			if service == nil or type(service.payload) ~= "function" then
				return nil
			end
			local ok, payload = pcall(service.payload)
			return if ok and type(payload) == "table" then payload else nil
		end,
	}
end

local deps: Deps = defaultDeps()

-- Specs: replaces some dependencies (the rest stay) and forgets every player, cache and registration.
function MonetizationService.setDeps(overrides: { [string]: any })
	local fresh: any = defaultDeps()
	for key, value in overrides do
		fresh[key] = value
	end
	deps = fresh
	MonetizationService.resetState()
end

-- Specs: back to the real dependencies, nothing remembered.
function MonetizationService.resetDeps()
	deps = defaultDeps()
	MonetizationService.resetState()
end

function MonetizationService.resetState()
	for _, thread in clubTimers do
		deps.cancel(thread)
	end
	table.clear(known)
	table.clear(passCache)
	table.clear(studioPasses)
	table.clear(clubMembers)
	table.clear(studioClub)
	table.clear(clubTimers)
	table.clear(offerState)
	table.clear(passListeners)
	table.clear(clubListeners)
	table.clear(grantListeners)
	table.clear(registered)
	table.clear(processing)
	table.clear(inflight)
	table.clear(priceCache)
end

-- Small helpers -------------------------------------------------------------------------------------------------

local function isWhole(value: any): boolean
	return type(value) == "number" and value == value and value % 1 == 0 and value >= 0 and value ~= math.huge
end

local function wholeOrZero(value: any): number
	return if isWhole(value) then value else 0
end

local function reply(ok: boolean, message: string, comingSoon: boolean?): Reply
	return { ok = ok, message = message, comingSoon = comingSoon }
end

-- Runs `fetch` once per `key` at a time: whoever asks while it runs waits for the same answer. Returns nil when
-- `fetch` errored (reported).
local function once(key: string, fetch: () -> any): any
	local waiting = inflight[key]
	if waiting ~= nil then
		table.insert(waiting, coroutine.running())
		return coroutine.yield()
	end
	local list: { thread } = {}
	inflight[key] = list
	local ok, result = pcall(fetch)
	inflight[key] = nil
	if not ok then
		warn(`{LOG} {key} failed: {result}`)
	end
	local value = if ok then result else nil
	for _, thread in list do
		task.spawn(thread, value)
	end
	return value
end

-- Ids ----------------------------------------------------------------------------------------------------------

local function usableId(id: any): number
	return if isWhole(id) and id > 0 then id else 0
end

-- The developer product id for a product key (0 = not created, or not a product).
function MonetizationService.productId(key: string): number
	local id = deps.config.products[key]
	if id ~= nil then
		return usableId(id)
	end
	local entry = registered[key]
	if entry == nil then
		return 0
	end
	if entry.options.productId ~= nil then
		return usableId(entry.options.productId)
	end
	local ok, ids = pcall(deps.limitedIds)
	return if ok and type(ids) == "table" then usableId(ids[key]) else 0
end

-- The game pass id for a pass key (0 = not created).
function MonetizationService.passId(key: string): number
	return usableId(deps.config.passes[key])
end

-- True once Davis has created the pass (its id isn't 0). Services that let Studio try a pass's perk before the pass
-- exists check this first.
function MonetizationService.passCreated(key: string): boolean
	return MonetizationService.passId(key) > 0
end

-- False while the store's feature flag is switched off (nothing is prompted; receipts still grant).
local function storeOpen(): boolean
	local ok, on = pcall(deps.flagOn, deps.config.featureFlag)
	return ok and on == true
end

local function clubId(): string
	local id = deps.config.subscriptions[deps.config.club.key]
	return if type(id) == "string" then id else ""
end

local function isProductKey(key: string): boolean
	return deps.config.products[key] ~= nil or registered[key] ~= nil
end

local function lookReady(lookId: any): boolean
	if type(lookId) ~= "string" then
		return false
	end
	local ok, exists = pcall(deps.lookExists, lookId)
	return ok and exists == true
end

-- True when product `key` delivers everything it sells: every exclusive look it grants (Config/Monetization grants'
-- `cosmetics`, a limited cosmetic's `ref`) exists in the Wrap & Tint shop (Config/Customization.lookExists). A
-- product that isn't ready is never prompted and shows as coming soon, whatever its id (a receipt for one is still
-- granted: the player paid).
function MonetizationService.productReady(key: string): boolean
	local grant = deps.config.grants[key]
	if grant ~= nil and grant.cosmetics ~= nil then
		for _, lookId in grant.cosmetics do
			if not lookReady(lookId) then
				return false
			end
		end
	end
	local limited = deps.limited
	if registered[key] ~= nil and limited ~= nil and type(limited.cosmeticFor) == "function" then
		local ok, cosmetic = pcall(limited.cosmeticFor, key)
		if ok and type(cosmetic) == "table" and not lookReady(cosmetic.ref) then
			return false
		end
	end
	return true
end

-- True while product `key` can be offered: created (its id isn't 0) and ready.
local function onSale(key: string): boolean
	return MonetizationService.productId(key) > 0 and MonetizationService.productReady(key)
end

-- The product key a receipt's ProductId names, or nil (0 never matches).
local function keyForProduct(productId: any): string?
	local id = usableId(productId)
	if id == 0 then
		return nil
	end
	for key, candidate in deps.config.products do
		if usableId(candidate) == id then
			return key
		end
	end
	for key in registered do
		if MonetizationService.productId(key) == id then
			return key
		end
	end
	return nil
end

local function keyForPass(gamePassId: any): string?
	local id = usableId(gamePassId)
	if id == 0 then
		return nil
	end
	for key, candidate in deps.config.passes do
		if usableId(candidate) == id then
			return key
		end
	end
	return nil
end

-- Pure rules on a save ------------------------------------------------------------------------------------------

local Receipts = {}
MonetizationService.Receipts = Receipts

function Receipts.has(receipts: { string }, purchaseId: string): boolean
	return table.find(receipts, purchaseId) ~= nil
end

-- Adds `purchaseId` as the newest receipt, keeping only the newest `max`.
function Receipts.record(receipts: { string }, purchaseId: string, max: number)
	table.insert(receipts, purchaseId)
	while #receipts > max do
		table.remove(receipts, 1)
	end
end

-- The save's receipt list, repaired in place (a damaged one becomes empty; non-string entries are dropped).
local function receiptsOf(data: Types.PlayerData): { string }
	local raw: any = data.receipts
	if type(raw) ~= "table" then
		data.receipts = {}
		return data.receipts
	end
	local clean: { string } = {}
	for _, entry in raw do
		if type(entry) == "string" then
			table.insert(clean, entry)
		end
	end
	if #clean ~= #raw then
		data.receipts = clean
	end
	return data.receipts
end

local function offersSeenOf(data: Types.PlayerData): { [string]: boolean }
	if type(data.offersSeen) ~= "table" then
		data.offersSeen = {}
	end
	return data.offersSeen
end

-- Credits from one credit pack: its credits and bonus, plus `eventShare` (0..MAX_EVENT_SHARE) of its credits while
-- an event runs, rounded down.
function MonetizationService.packCredits(grant: Grant, eventShare: number?): number
	local base = wholeOrZero(grant.credits)
	local share = eventShare or 0
	if type(share) ~= "number" or share ~= share or share < 0 then
		share = 0
	end
	return base + wholeOrZero(grant.bonus) + math.floor(base * math.min(share, MAX_EVENT_SHARE))
end

-- Applies a grant to a save (inside a DataService.update): `credits` Design Credits (already including any bonus),
-- the grant's cash and custom slots. Returns what was really added.
function MonetizationService.applyGrant(data: Types.PlayerData, grant: Grant, credits: number): Applied
	local applied: Applied = { credits = 0, cash = 0, customSlots = 0, cosmetics = 0 }
	if isWhole(credits) and credits > 0 then
		local ledger = CreditsService.Ledger.sanitize(data.credits)
		data.credits = ledger :: any
		applied.credits = CreditsService.Ledger.grant(ledger, credits)
	end
	local cash = wholeOrZero(grant.cash)
	if cash > 0 then
		local balance, added = EconomyService.applyAdd(data.cash, cash, Economy.maxCash)
		data.cash = balance
		applied.cash = added
	end
	local slots = wholeOrZero(grant.customSlots)
	if slots > 0 then
		local current = if isWhole(data.customSlots) then data.customSlots else Economy.customSlots
		data.customSlots = current + slots
		applied.customSlots = slots
	end
	if grant.cosmetics ~= nil and #grant.cosmetics > 0 then
		local owned: any = data.cosmetics
		if type(owned) ~= "table" then
			owned = {}
			data.cosmetics = owned
		end
		for _, id in grant.cosmetics do
			if owned[id] == nil then
				owned[id] = UNNUMBERED
				applied.cosmetics += 1
			end
		end
	end
	return applied
end

-- True once `moment` (Config/Offers) has happened for this save.
function MonetizationService.momentHappened(data: Types.PlayerData, moment: string): boolean
	if moment == "firstDesign" then
		if type(data.designs) == "table" and #data.designs > 0 then
			return true
		end
		local credits: any = data.credits
		-- The free car is used and no request still holds it (a failed request gives it back).
		return type(credits) == "table"
			and credits.freeDesignUsed == true
			and (type(credits.reserved) ~= "table" or #credits.reserved == 0)
	elseif moment == "firstJobPayout" then
		local jobs: any = data.jobs
		if type(jobs) ~= "table" or type(jobs.xp) ~= "table" then
			return false
		end
		for _, xp in jobs.xp do
			if type(xp) == "number" and xp > 0 then
				return true
			end
		end
	end
	return false
end

-- True while an offer should show for this save: one of its moments happened and it hasn't been bought.
function MonetizationService.offerVisible(data: Types.PlayerData, offer: Offer): boolean
	local seen: any = data.offersSeen
	if type(seen) == "table" and seen[offer.id] == true then
		return false
	end
	for _, moment in offer.showAfter do
		if MonetizationService.momentHappened(data, moment) then
			return true
		end
	end
	return false
end

-- The offers that sell product `key`.
local function offersFor(key: string): { Offer }
	local list: { Offer } = {}
	for _, offer in deps.offers do
		if offer.productKey == key then
			table.insert(list, offer)
		end
	end
	return list
end

-- True once this save bought a one-time offer that sells product `key`.
local function offerBought(data: Types.PlayerData, key: string): boolean
	local seen: any = data.offersSeen
	if type(seen) ~= "table" then
		return false
	end
	for _, offer in offersFor(key) do
		if seen[offer.id] == true then
			return true
		end
	end
	return false
end

-- Why `key` can't be bought by this save right now, or nil.
local function productRefusal(data: Types.PlayerData, key: string): string?
	local messages = deps.config.messages
	if offerBought(data, key) then
		return messages.starterBought
	end
	local info = deps.config.productInfo[key]
	local grant = deps.config.grants[key]
	if info ~= nil and info.kind == "slot" and grant ~= nil then
		local current = if isWhole(data.customSlots) then data.customSlots else Economy.customSlots
		if current + wholeOrZero(grant.customSlots) > deps.config.maxCustomSlots then
			return messages.slotsFull
		end
	end
	local entry = registered[key]
	if entry ~= nil and entry.options.available == false then
		return messages.comingSoon
	end
	return nil
end

-- The month key the club's monthly credits are counted in ("YYYY-MM", UTC): the month the paid, unrefunded billing
-- cycle covering `now` in `history` (GetUserSubscriptionPaymentHistoryAsync) started. Also returns that cycle's end
-- and whether such a cycle was found. Without one (no history, or no paid cycle covers now) it gives the month of
-- `now`, its end nil and found false: refreshClub then grants nothing (outside Studio), so one paid cycle can never
-- earn two grants under two different keys.
function MonetizationService.billingMonth(now: number, history: { any }?): (string, number?, boolean)
	local function unixOf(value: any): number?
		if type(value) == "number" then
			return value
		end
		local ok, stamp = pcall(function(): any
			return value.UnixTimestamp
		end)
		return if ok and type(stamp) == "number" then stamp else nil
	end
	local start: number? = nil
	local finish: number? = nil
	if type(history) == "table" then
		for _, entry in history do
			if type(entry) == "table" then
				local entryAny: any = entry
				local from, to = unixOf(entryAny.CycleStartTime), unixOf(entryAny.CycleEndTime)
				local status = string.lower(tostring(entryAny.PaymentStatus))
				local refunded = string.find(status, "refund", 1, true) ~= nil
				if from ~= nil and to ~= nil and from <= now and now < to and not refunded then
					start, finish = from, to
					break
				end
			end
		end
	end
	local date = os.date("!*t", start or now)
	return string.format("%04d-%02d", date.year, date.month), finish, start ~= nil
end

-- True when the club's monthly credits for `month` haven't been granted to this save yet.
function MonetizationService.clubGrantDue(data: Types.PlayerData, month: string): boolean
	local club: any = data.club
	return type(club) ~= "table" or club.lastGrantMonth ~= month
end

-- Passes --------------------------------------------------------------------------------------------------------

-- Never yields: the cached answer (false until it is known), or true for a pass given in Studio.
function MonetizationService.hasPassCached(player: Player, key: string): boolean
	local studio = studioPasses[player]
	if studio ~= nil and studio[key] == true and deps.isStudio() then
		return true
	end
	local cache = passCache[player]
	return cache ~= nil and cache[key] == true
end

-- Calls `listener(player, owned)` whenever a player's ownership of pass `key` becomes known or changes. Returns a
-- function that stops it.
function MonetizationService.onPassChanged(key: string, listener: PassListener): () -> ()
	local list = passListeners[key]
	if list == nil then
		list = {}
		passListeners[key] = list
	end
	table.insert(list, listener)
	return function()
		local index = table.find(list, listener)
		if index ~= nil then
			table.remove(list, index)
		end
	end
end

-- Extra garage and custom-car slots the player's passes and club give right now.
function MonetizationService.slotBonus(player: Player): (number, number)
	local garage, custom = 0, 0
	for key, bonus in deps.config.passSlots do
		if MonetizationService.hasPassCached(player, key) then
			garage += wholeOrZero(bonus.garageSlots)
			custom += wholeOrZero(bonus.customSlots)
		end
	end
	if MonetizationService.isClubMember(player) then
		garage += wholeOrZero(deps.config.club.slots.garageSlots)
		custom += wholeOrZero(deps.config.club.slots.customSlots)
	end
	return garage, custom
end

-- Mirrors the slots passes and the club add to the player's attributes and sends a fresh profile snapshot.
local function applySlots(player: Player)
	local garage, custom = MonetizationService.slotBonus(player)
	local attributes = deps.config.attributes
	deps.setAttribute(player, attributes.garageBonus, garage)
	deps.setAttribute(player, attributes.customBonus, custom)
	deps.push(player)
end

local sendStoreUpdate: (player: Player, kind: string, key: string) -> ()

-- Records what we now know about a pass. Listeners hear the first answer and every change; a change after the
-- first answer also refreshes the slots and the store.
local function setPassOwned(player: Player, key: string, owned: boolean)
	if not known[player] then
		return -- the player left while it was being looked up
	end
	local cache = passCache[player]
	if cache == nil then
		cache = {}
		passCache[player] = cache
	end
	local before = cache[key]
	cache[key] = owned
	if before == owned then
		return
	end
	deps.setAttribute(player, deps.config.attributes.passPrefix .. key, owned)
	if deps.config.passSlots[key] ~= nil then
		applySlots(player)
	end
	for _, listener in passListeners[key] or {} do
		task.spawn(listener, player, owned)
	end
	if before ~= nil then
		sendStoreUpdate(player, "pass", key)
	end
end

-- Whether the player owns pass `key`. Cached for the session; the first ask per player and pass yields for
-- UserOwnsGamePassAsync (asks made meanwhile share it). A pass that isn't created (id 0) is owned by nobody and
-- nothing is asked. A failed lookup answers false and is asked again next time.
function MonetizationService.hasPass(player: Player, key: string): boolean
	if MonetizationService.hasPassCached(player, key) then
		return true
	end
	local cache = passCache[player]
	if cache ~= nil and cache[key] ~= nil then
		return cache[key]
	end
	local id = MonetizationService.passId(key)
	if id == 0 then
		return false
	end
	local market = deps.marketplace
	local owned = once(`pass:{player.UserId}:{key}`, function(): boolean
		return market:UserOwnsGamePassAsync(player.UserId, id) == true
	end)
	if type(owned) ~= "boolean" then
		return false
	end
	setPassOwned(player, key, owned)
	return owned
end

local function onPassPurchaseFinished(player: Player, gamePassId: number, purchased: boolean)
	local key = keyForPass(gamePassId)
	if not purchased or key == nil then
		return
	end
	setPassOwned(player, key, true)
	local info = deps.config.passInfo[key]
	if info ~= nil then
		deps.notify(player, string.format(deps.config.messages.granted, info.name))
	end
	sendStoreUpdate(player, "pass", key)
end

-- MarketplaceService.PromptGamePassPurchaseFinished (exported for the specs).
MonetizationService.passPurchaseFinished = onPassPurchaseFinished

-- The Voltage Club ----------------------------------------------------------------------------------------------

-- Never yields: true while the player is a member (as last checked).
function MonetizationService.isClubMember(player: Player): boolean
	return clubMembers[player] == true
end

-- Calls `listener(player, member)` whenever a player's membership changes. Returns a function that stops it.
function MonetizationService.onClubChanged(listener: ClubListener): () -> ()
	table.insert(clubListeners, listener)
	return function()
		local index = table.find(clubListeners, listener)
		if index ~= nil then
			table.remove(clubListeners, index)
		end
	end
end

local function setClubMember(player: Player, member: boolean)
	if not known[player] then
		return
	end
	local before = clubMembers[player] == true
	clubMembers[player] = member
	deps.setAttribute(player, deps.config.attributes.club, member)
	if before == member then
		return
	end
	applySlots(player)
	for _, listener in clubListeners do
		task.spawn(listener, player, member)
	end
	sendStoreUpdate(player, "club", deps.config.club.key)
end

-- Grants the club's monthly credits for `month` unless this save already had them. Returns what was added.
local function grantClubMonth(player: Player, month: string): number
	local access = deps.data
	if access == nil or access.waitFor(player, deps.config.receiptWaitSeconds) == nil then
		return 0
	end
	local amount = wholeOrZero(deps.config.club.monthlyCredits)
	local added = 0
	local granted = false
	local updated = access.update(player, function(fresh: Types.PlayerData)
		if not MonetizationService.clubGrantDue(fresh, month) then
			return
		end
		if type(fresh.club) ~= "table" then
			fresh.club = {}
		end
		local ledger = CreditsService.Ledger.sanitize(fresh.credits)
		fresh.credits = ledger :: any
		added = if amount > 0 then CreditsService.Ledger.grant(ledger, amount) else 0
		fresh.club.lastGrantMonth = month
		granted = true
	end)
	if not updated or not granted then
		return 0
	end
	print(`{LOG} {player.Name}: Voltage Club credits for {month} (+{added})`)
	if added > 0 then
		deps.notify(player, string.format(deps.config.messages.clubCredits, added))
	end
	sendStoreUpdate(player, "club", deps.config.club.key)
	return added
end

-- Stops the player's pending club check, if any.
local function cancelClubCheck(player: Player)
	local timer = clubTimers[player]
	if timer ~= nil then
		clubTimers[player] = nil
		deps.cancel(timer)
	end
end

-- Checks the player's membership again in `seconds` (never sooner than club.minRecheckSeconds). One timer per
-- player: any check already pending is replaced, so overlapping refreshes never leave two.
local function scheduleClubCheck(player: Player, seconds: number)
	cancelClubCheck(player)
	if not known[player] then
		return
	end
	local thread = deps.schedule(math.max(seconds, deps.config.club.minRecheckSeconds), function()
		clubTimers[player] = nil
		MonetizationService.refreshClub(player)
	end)
	if thread ~= nil then
		clubTimers[player] = thread
	end
end

-- Checks the player's membership (yields for the subscription APIs) and, while they are a member, grants the
-- credits for the paid billing cycle covering now once, then schedules the next check for when that cycle ends.
-- A check that fails, or a member with no paid cycle listed for now, grants nothing and is checked again after
-- club.minRecheckSeconds.
function MonetizationService.refreshClub(player: Player)
	if not known[player] then
		return
	end
	local id = clubId()
	local studio = studioClub[player] == true and deps.isStudio()
	local market = deps.marketplace
	local member: boolean
	if studio then
		member = true
	elseif id == "" then
		member = false
	else
		local ok, status = pcall(function(): any
			return market:GetUserSubscriptionStatusAsync(player, id)
		end)
		if not ok or type(status) ~= "table" then
			warn(`{LOG} couldn't check {player.Name}'s Voltage Club status: {status}`)
			scheduleClubCheck(player, deps.config.club.minRecheckSeconds) -- keep what we knew; ask again soon
			return
		end
		member = status.IsSubscribed == true
	end
	setClubMember(player, member)

	if not member then
		cancelClubCheck(player) -- a status change (or the next join) says when they join again
		return
	end
	local history: { any }? = nil
	if not studio then
		local ok, result = pcall(function(): any
			return market:GetUserSubscriptionPaymentHistoryAsync(player, id)
		end)
		if ok and type(result) == "table" then
			history = result
		else
			warn(`{LOG} couldn't read {player.Name}'s Voltage Club payments: {result}`)
		end
	end
	local now = deps.clock()
	local month, cycleEnd, found = MonetizationService.billingMonth(now, history)
	if found or studio then
		grantClubMonth(player, month)
	else
		warn(`{LOG} no paid Voltage Club cycle listed for {player.Name} yet; checking again soon`)
	end
	if cycleEnd ~= nil then
		scheduleClubCheck(player, cycleEnd - now)
	elseif not studio then
		scheduleClubCheck(player, deps.config.club.minRecheckSeconds)
	else
		cancelClubCheck(player)
	end
end

local function onSubscriptionChanged(player: Player, subscriptionId: string)
	if subscriptionId == clubId() and subscriptionId ~= "" then
		deps.spawn(function()
			MonetizationService.refreshClub(player)
		end)
	end
end

-- Players.UserSubscriptionStatusChanged (exported for the specs).
MonetizationService.subscriptionChanged = onSubscriptionChanged

-- Cosmetics -----------------------------------------------------------------------------------------------------

-- True when the player may use an exclusive look: one they own for good (PlayerData.cosmetics: the Starter Pack's
-- wrap, a limited cosmetic) or, while they are a member, one of the club's.
function MonetizationService.ownsCosmetic(player: Player, cosmeticId: string): boolean
	if MonetizationService.isClubMember(player) and table.find(deps.config.club.cosmetics, cosmeticId) ~= nil then
		return true
	end
	local access = deps.data
	local data = if access ~= nil then access.get(player) else nil
	local owned: any = if data ~= nil then data.cosmetics else nil
	return type(owned) == "table" and isWhole(owned[cosmeticId])
end

-- Prices --------------------------------------------------------------------------------------------------------

-- A product or pass price in Robux from MarketplaceService (cached), or nil.
local function robuxPrice(infoType: Enum.InfoType, id: number): number?
	local cacheKey = `{infoType.Name}:{id}`
	local now = deps.clock()
	local entry = priceCache[cacheKey]
	if entry ~= nil then
		local ttl = if entry.value ~= nil then deps.config.priceCacheSeconds else deps.config.priceRetrySeconds
		if now - entry.at < ttl then
			return entry.value
		end
	end
	local market = deps.marketplace
	local value = once(`price:{cacheKey}`, function(): any
		local ok, info = pcall(function(): any
			return market:GetProductInfoAsync(id, infoType)
		end)
		if not ok then
			info = market:GetProductInfo(id, infoType) -- the older name, where the new one isn't there yet
		end
		local price = if type(info) == "table" then info.PriceInRobux else nil
		return if type(price) == "number" then price else nil
	end)
	priceCache[cacheKey] = { value = value, at = now }
	return value
end

-- The club's price: { robux, display } as Roblox gives them (cached); either may be nil.
local function clubPrice(id: string): (number?, string?)
	local cacheKey = `Subscription:{id}`
	local now = deps.clock()
	local entry = priceCache[cacheKey]
	local info: any = nil
	local ttl = if entry ~= nil and entry.value ~= nil
		then deps.config.priceCacheSeconds
		else deps.config.priceRetrySeconds
	if entry ~= nil and now - entry.at < ttl then
		info = entry.value
	else
		local market = deps.marketplace
		info = once(`price:{cacheKey}`, function(): any
			local result = market:GetSubscriptionProductInfoAsync(id)
			return if type(result) == "table" then result else nil
		end)
		priceCache[cacheKey] = { value = info, at = now }
	end
	if type(info) ~= "table" then
		return nil, nil
	end
	local robux = if type(info.PriceInRobux) == "number" then info.PriceInRobux else nil
	local display = if type(info.DisplayPrice) == "string" then info.DisplayPrice else nil
	return robux, display
end

-- The store -----------------------------------------------------------------------------------------------------

local function copyGrant(grant: Grant?): { [string]: any }
	local copy: { [string]: any } = {}
	if grant == nil then
		return copy
	end
	for field, value in grant :: any do
		copy[field] = if type(value) == "table" then table.clone(value) else value
	end
	return copy
end

local function creditsOf(data: Types.PlayerData?): number
	local credits: any = if data ~= nil then data.credits else nil
	return if type(credits) == "table" and isWhole(credits.balance) then credits.balance else 0
end

-- The GetStore payload for this player: every product, pass, the club and the offers, with prices from
-- MarketplaceService (cached; the first look-up of each yields), plus the daily streak and the events when those
-- services run. Waits up to receiptWaitSeconds for a save that is still loading, so a store fetched as the player
-- joins isn't all "can't buy". Nothing is created or prompted.
function MonetizationService.storeSnapshot(player: Player): StorePayload
	local config = deps.config
	local access = deps.data
	local data = if access ~= nil then access.waitFor(player, config.receiptWaitSeconds) else nil
	local open = storeOpen()

	local products: { StoreProduct } = {}
	local function addProduct(key: string, name: string, kind: string, grant: Grant?)
		local id = MonetizationService.productId(key)
		local available = id > 0 and MonetizationService.productReady(key)
		local note: string? = if data ~= nil then productRefusal(data, key) else nil
		if not available then
			note = config.messages.comingSoon
		elseif not open and note == nil then
			note = config.messages.storeClosed
		end
		local owned: boolean? = nil
		if data ~= nil and #offersFor(key) > 0 then
			owned = offerBought(data, key)
		end
		table.insert(products, {
			key = key,
			name = name,
			kind = kind,
			grants = copyGrant(grant),
			price = if available then robuxPrice(Enum.InfoType.Product, id) else nil,
			available = available,
			canBuy = available and data ~= nil and note == nil,
			owned = owned,
			note = note,
		})
	end
	for _, key in config.productOrder do
		local info = config.productInfo[key]
		if info ~= nil then
			addProduct(key, info.name, info.kind, config.grants[key])
		end
	end
	-- Limited cosmetics (LimitedService): on sale only while their window is open and their product exists.
	local listed: { [string]: boolean } = {}
	local limited = deps.limited
	if limited ~= nil and type(limited.cosmeticProducts) == "function" then
		local ok, list = pcall(limited.cosmeticProducts, deps.clock())
		if ok and type(list) == "table" then
			for _, item in list do
				local id = MonetizationService.productId(item.key)
				local available = id > 0 and item.available == true and MonetizationService.productReady(item.key)
				local canBuy, note =
					available and data ~= nil and open, if open then nil else config.messages.storeClosed
				if canBuy and type(limited.canBuyCosmetic) == "function" then
					local checked, allowed, why = pcall(limited.canBuyCosmetic, player, item.key)
					canBuy = checked and allowed == true
					note = if checked and type(why) == "string" then why else nil
				end
				listed[item.key] = true
				table.insert(products, {
					key = item.key,
					name = item.name,
					kind = "cosmetic",
					grants = if type(item.grants) == "table" then table.clone(item.grants) else {},
					price = if id > 0 then robuxPrice(Enum.InfoType.Product, id) else nil,
					available = available,
					canBuy = canBuy,
					note = if available then note else config.messages.comingSoon,
					startsAt = item.startsAt,
					endsAt = item.endsAt,
				})
			end
		end
	end
	-- Other registered products that asked to be listed (a name, not switched off).
	local extra: { string } = {}
	for key, entry in registered do
		local listable = entry.options.name ~= nil and entry.options.available ~= false
		if config.products[key] == nil and not listed[key] and listable then
			table.insert(extra, key)
		end
	end
	table.sort(extra)
	for _, key in extra do
		addProduct(key, registered[key].options.name :: string, "cosmetic", nil)
	end

	local passes: { StorePass } = {}
	for _, key in config.passOrder do
		local info = config.passInfo[key]
		if info ~= nil then
			local id = MonetizationService.passId(key)
			table.insert(passes, {
				key = key,
				name = info.name,
				perks = table.clone(info.perks),
				price = if id > 0 then robuxPrice(Enum.InfoType.GamePass, id) else nil,
				owned = MonetizationService.hasPass(player, key),
				available = id > 0,
			})
		end
	end

	local id = clubId()
	local robux, display = nil, nil
	if id ~= "" then
		robux, display = clubPrice(id)
	end
	local club: StoreClub = {
		available = id ~= "",
		member = MonetizationService.isClubMember(player),
		price = robux,
		displayPrice = display,
		monthlyCredits = config.club.monthlyCredits,
		name = config.club.name,
		perks = table.clone(config.club.perks),
	}

	local offers: { StoreOffer } = {}
	local offerIds: { string } = {}
	for offerId in deps.offers do
		table.insert(offerIds, offerId)
	end
	table.sort(offerIds)
	for _, offerId in offerIds do
		local offer = deps.offers[offerId]
		local seen: any = if data ~= nil then data.offersSeen else nil
		table.insert(offers, {
			id = offer.id,
			productKey = offer.productKey,
			shown = type(seen) == "table" and seen[offer.id] == true,
			due = data ~= nil and onSale(offer.productKey) and MonetizationService.offerVisible(data, offer),
		})
	end

	local okStreak, streak = pcall(deps.streakOf, player)
	local okEvents, events = pcall(deps.eventsNow)
	return {
		open = open,
		products = products,
		passes = passes,
		club = club,
		offers = offers,
		credits = creditsOf(data),
		streak = if okStreak then streak else nil,
		events = if okEvents then events else nil,
	}
end

-- StoreUpdate: the fresh store payload and what changed, in its own thread (the payload may wait on prices).
sendStoreUpdate = function(player: Player, kind: string, key: string)
	if not known[player] then
		return
	end
	deps.spawn(function()
		local ok, payload = pcall(MonetizationService.storeSnapshot, player)
		if ok then
			payload.changed = { kind = kind, key = key }
			deps.sendStore(player, payload)
		else
			warn(`{LOG} couldn't build {player.Name}'s store update: {payload}`)
		end
	end)
end

-- Tells the player's store each time one of an offer's moments happens (Config/Offers showAfter: the first free
-- design, the first job payout), while the offer isn't bought and its product is on sale: so the Starter Pack
-- sheet comes up after each moment, not only the first. The first look after a load only notes which moments are
-- behind the player, so a join never pushes the sheet; a returning player finds a due offer on the Store app's
-- Credits page instead (the payload's `due`).
local function checkOffers(player: Player, data: Types.PlayerData)
	if not known[player] then
		return
	end
	local state = offerState[player]
	local first = state == nil
	if state == nil then
		state = {}
		offerState[player] = state
	end
	for offerId, offer in deps.offers do
		local moments = state[offerId]
		if moments == nil then
			moments = {}
			state[offerId] = moments
		end
		local happenedNow = false
		for _, moment in offer.showAfter do
			local happened = MonetizationService.momentHappened(data, moment)
			if happened and moments[moment] == false then
				happenedNow = true
			end
			moments[moment] = happened
		end
		local seen: any = data.offersSeen
		local bought = type(seen) == "table" and seen[offer.id] == true
		if happenedNow and not first and not bought and onSale(offer.productKey) then
			sendStoreUpdate(player, "offer", offerId)
		end
	end
end

-- DataService.onChanged (exported for the specs).
MonetizationService.dataChanged = checkOffers

-- Receipts ------------------------------------------------------------------------------------------------------

local function announce(player: Player, key: string, purchaseId: string)
	for _, listener in grantListeners do
		task.spawn(listener, player, key, purchaseId)
	end
	sendStoreUpdate(player, "product", key)
end

-- Grants a built-in product and records its receipt in one update.
local function grantBuiltIn(player: Player, access: DataAccess, key: string, purchaseId: string)
	local config = deps.config
	local grant = config.grants[key]
	if grant == nil then
		warn(`{LOG} no grant for product "{key}"; leaving receipt {purchaseId} for later`)
		return NOT_YET
	end
	local info = config.productInfo[key]
	local credits = if info ~= nil and info.kind == "credits"
		then MonetizationService.packCredits(grant, deps.eventBonus(deps.clock()))
		else MonetizationService.packCredits(grant, 0)
	local applied: Applied? = nil
	local already = false
	local updated = access.update(player, function(fresh: Types.PlayerData)
		local receipts = receiptsOf(fresh)
		if Receipts.has(receipts, purchaseId) then
			already = true
			return
		end
		applied = MonetizationService.applyGrant(fresh, grant, credits)
		local seen = offersSeenOf(fresh)
		for _, offer in offersFor(key) do
			seen[offer.id] = true
		end
		Receipts.record(receipts, purchaseId, Data.maxReceipts)
	end)
	if not updated then
		return NOT_YET
	end
	if already or applied == nil then
		return GRANTED
	end
	local done: Applied = applied
	if done.cash > 0 then
		deps.recordCash(player, done.cash, config.cashReason)
	end
	print(`{LOG} {player.Name}: {key} ({purchaseId}) +{done.credits} credits, +${done.cash}, +{done.customSlots} slots`)
	if done.customSlots > 0 then
		deps.push(player)
	end
	local name = if info ~= nil then info.name else key
	deps.notify(player, string.format(config.messages.granted, name))
	announce(player, key, purchaseId)
	return GRANTED
end

-- A registered product: its handler grants, then the receipt is recorded.
local function grantRegistered(player: Player, access: DataAccess, key: string, receiptInfo: { [string]: any })
	local purchaseId: string = receiptInfo.PurchaseId
	local entry = registered[key]
	if entry == nil then
		return NOT_YET
	end
	local ok, result = pcall(entry.handler, player, receiptInfo)
	if not ok then
		warn(`{LOG} {key} handler failed for {player.Name} ({purchaseId}): {result}`)
		return NOT_YET
	elseif result ~= true then
		return NOT_YET
	end
	local updated = access.update(player, function(fresh: Types.PlayerData)
		local receipts = receiptsOf(fresh)
		if not Receipts.has(receipts, purchaseId) then
			Receipts.record(receipts, purchaseId, Data.maxReceipts)
		end
	end)
	if not updated then
		warn(`{LOG} {key} granted to {player.Name} but receipt {purchaseId} wasn't saved; Roblox will retry`)
		return NOT_YET
	end
	print(`{LOG} {player.Name}: {key} ({purchaseId})`)
	announce(player, key, purchaseId)
	return GRANTED
end

-- PurchaseGranted once the DataStore holds `purchaseId` in the player's receipts (asks for a save and waits up to
-- receiptSaveSeconds), else NotProcessedYet: Roblox redelivers, finds the receipt granted and waits again.
local function confirmSaved(player: Player, access: DataAccess, purchaseId: string): Enum.ProductPurchaseDecision
	local confirm = access.saveConfirmed
	if confirm == nil then
		return GRANTED -- a save that doesn't model saving (a spec's fake)
	end
	local ok, saved = pcall(confirm, player, function(savedData: any): boolean
		local list = if type(savedData) == "table" then savedData.receipts else nil
		return type(list) == "table" and table.find(list, purchaseId) ~= nil
	end, deps.config.receiptSaveSeconds)
	if not ok then
		warn(`{LOG} couldn't confirm receipt {purchaseId} was saved: {saved}`)
		return NOT_YET
	elseif saved ~= true then
		warn(`{LOG} receipt {purchaseId} isn't saved yet; Roblox will deliver it again`)
		return NOT_YET
	end
	return GRANTED
end

-- The receipt path for product `key` (ProcessReceipt and DevPurchase both end here).
local function decide(key: string, receiptInfo: { [string]: any }): Enum.ProductPurchaseDecision
	local rawId = receiptInfo.PurchaseId
	local purchaseId = if type(rawId) == "string" then rawId elseif type(rawId) == "number" then tostring(rawId) else ""
	if purchaseId == "" then
		warn(`{LOG} a {key} receipt has no PurchaseId`)
		return NOT_YET
	end
	receiptInfo.PurchaseId = purchaseId
	local userId = receiptInfo.PlayerId
	local player = if type(userId) == "number" then deps.playerByUserId(userId) else nil
	local access = deps.data
	if player == nil or access == nil then
		return NOT_YET -- not in this server; Roblox retries when they're somewhere it can be granted
	end
	local data = access.waitFor(player, deps.config.receiptWaitSeconds)
	if data == nil then
		return NOT_YET
	end
	if processing[purchaseId] then
		return NOT_YET -- the same receipt is being granted right now; this delivery is retried
	end
	processing[purchaseId] = true
	local ok, decision = pcall(function(): Enum.ProductPurchaseDecision
		if Receipts.has(receiptsOf(data), purchaseId) then
			return confirmSaved(player, access, purchaseId) -- granted before: only the save may still be missing
		end
		local granted = if registered[key] ~= nil and deps.config.products[key] == nil
			then grantRegistered(player, access, key, receiptInfo)
			else grantBuiltIn(player, access, key, purchaseId)
		if granted ~= GRANTED then
			return granted
		end
		return confirmSaved(player, access, purchaseId)
	end)
	processing[purchaseId] = nil
	if not ok then
		warn(`{LOG} {key} receipt {purchaseId} failed: {decision}`)
		return NOT_YET
	end
	return decision
end

-- MarketplaceService.ProcessReceipt.
function MonetizationService.processReceipt(receiptInfo: { [string]: any }): Enum.ProductPurchaseDecision
	if type(receiptInfo) ~= "table" then
		return NOT_YET
	end
	local key = keyForProduct(receiptInfo.ProductId)
	if key == nil then
		warn(`{LOG} receipt for unknown product {tostring(receiptInfo.ProductId)}; leaving it for later`)
		return NOT_YET
	end
	return decide(key, receiptInfo)
end

-- Lets another service sell its own developer product through the one idempotent ProcessReceipt (see the header).
function MonetizationService.registerProduct(key: string, handler: ProductHandler, options: ProductOptions?)
	registered[key] = { handler = handler, options = options or {} }
end

-- Calls `listener(player, key, purchaseId)` after each product purchase is granted (analytics).
function MonetizationService.onGranted(listener: GrantListener)
	table.insert(grantListeners, listener)
end

-- Prompts -------------------------------------------------------------------------------------------------------

-- BuyProduct: prompts the purchase, or says why not (an id of 0 is "coming soon" and calls nothing).
function MonetizationService.buyProduct(player: Player, key: string): Reply
	local messages = deps.config.messages
	if not isProductKey(key) then
		return reply(false, messages.unknown)
	end
	local id = MonetizationService.productId(key)
	if id == 0 or not MonetizationService.productReady(key) then
		return reply(false, messages.comingSoon, true)
	end
	if not storeOpen() then
		return reply(false, messages.storeClosed)
	end
	local access = deps.data
	local data = if access ~= nil then access.get(player) else nil
	if data == nil then
		return reply(false, messages.notLoaded)
	end
	local refusal = productRefusal(data, key)
	if refusal ~= nil then
		return reply(false, refusal)
	end
	-- A limited cosmetic is sold only while its window is open, and once per player (checked before the prompt,
	-- never after: a receipt means Robux was spent, so it is always granted).
	local limited = deps.limited
	if registered[key] ~= nil and limited ~= nil and type(limited.canBuyCosmetic) == "function" then
		local isLimited = type(limited.cosmeticFor) ~= "function" or limited.cosmeticFor(key) ~= nil
		if isLimited then
			local checked, allowed, why = pcall(limited.canBuyCosmetic, player, key)
			if not checked or allowed ~= true then
				return reply(false, if checked and type(why) == "string" then why else messages.promptFailed)
			end
		end
	end
	local market = deps.marketplace
	local ok, err = pcall(function()
		market:PromptProductPurchase(player, id)
	end)
	if not ok then
		warn(`{LOG} couldn't prompt {key} for {player.Name}: {err}`)
		return reply(false, messages.promptFailed)
	end
	return reply(true, messages.prompted)
end

-- BuyPass: prompts the pass, or says why not.
function MonetizationService.buyPass(player: Player, key: string): Reply
	local messages = deps.config.messages
	if deps.config.passes[key] == nil then
		return reply(false, messages.unknown)
	end
	local id = MonetizationService.passId(key)
	if id == 0 then
		return reply(false, messages.comingSoon, true)
	end
	if not storeOpen() then
		return reply(false, messages.storeClosed)
	end
	if MonetizationService.hasPass(player, key) then
		return reply(false, messages.alreadyOwned)
	end
	local market = deps.marketplace
	local ok, err = pcall(function()
		market:PromptGamePassPurchase(player, id)
	end)
	if not ok then
		warn(`{LOG} couldn't prompt pass {key} for {player.Name}: {err}`)
		return reply(false, messages.promptFailed)
	end
	return reply(true, messages.prompted)
end

-- JoinClub: prompts the subscription, or says why not.
function MonetizationService.joinClub(player: Player): Reply
	local messages = deps.config.messages
	local id = clubId()
	if id == "" then
		return reply(false, messages.comingSoon, true)
	end
	if not storeOpen() then
		return reply(false, messages.storeClosed)
	end
	if MonetizationService.isClubMember(player) then
		return reply(false, messages.alreadyMember)
	end
	local market = deps.marketplace
	local ok, err = pcall(function()
		market:PromptSubscriptionPurchase(player, id)
	end)
	if not ok then
		warn(`{LOG} couldn't prompt the Voltage Club for {player.Name}: {err}`)
		return reply(false, messages.promptFailed)
	end
	return reply(true, messages.prompted)
end

-- DevPurchase (Studio only): a product key runs the real receipt path with a made-up PurchaseId (pass the same
-- purchaseId again to check it grants once); a pass key or the club key is owned for the rest of this session.
function MonetizationService.devPurchase(player: Player, payload: { [string]: any }): Reply
	local messages = deps.config.messages
	if not deps.isStudio() then
		warn(`{LOG} {player.Name} called DevPurchase outside Studio`)
		return reply(false, messages.devOnly)
	end
	local key = payload.key
	if type(key) ~= "string" then
		return reply(false, messages.unknown)
	end
	if isProductKey(key) then
		local purchaseId = payload.purchaseId
		local receipt: { [string]: any } = {
			PurchaseId = if type(purchaseId) == "string" and purchaseId ~= ""
				then purchaseId
				else DEV_PREFIX .. deps.guid(),
			PlayerId = player.UserId,
			ProductId = MonetizationService.productId(key),
			CurrencySpent = 0,
		}
		local info = deps.config.productInfo[key]
		local name = if info ~= nil then info.name else key
		local decision = decide(key, receipt)
		if decision == GRANTED then
			return reply(true, string.format(messages.devGranted, name))
		end
		return reply(false, string.format(messages.devFailed, name))
	elseif deps.config.passes[key] ~= nil then
		local studio = studioPasses[player]
		if studio == nil then
			studio = {}
			studioPasses[player] = studio
		end
		studio[key] = true
		setPassOwned(player, key, true)
		local info = deps.config.passInfo[key]
		return reply(true, string.format(messages.devGranted, if info ~= nil then info.name else key))
	elseif key == deps.config.club.key then
		studioClub[player] = true
		MonetizationService.refreshClub(player)
		return reply(true, string.format(messages.devGranted, deps.config.club.name))
	end
	return reply(false, messages.unknown)
end

-- Players -------------------------------------------------------------------------------------------------------

-- Asks Roblox whether the player owns pass `key`; while the answer isn't known (the call failed), asks again
-- passRetrySeconds later, at most `triesLeft` more times.
local function checkPassOnJoin(player: Player, key: string, triesLeft: number)
	if not known[player] then
		return
	end
	local owned = MonetizationService.hasPass(player, key)
	local cache = passCache[player]
	if owned or cache == nil or cache[key] ~= nil or triesLeft <= 0 or not known[player] then
		return
	end
	deps.schedule(deps.config.passRetrySeconds, function()
		checkPassOnJoin(player, key, triesLeft - 1)
	end)
end

-- A player joined: look up their passes (in the background, retried if Roblox errors) and their club membership.
function MonetizationService.onJoin(player: Player)
	if known[player] then
		return
	end
	known[player] = true
	passCache[player] = {}
	deps.setAttribute(player, deps.config.attributes.club, false)
	applySlots(player)
	for key in deps.config.passes do
		if MonetizationService.passCreated(key) then
			deps.spawn(function()
				checkPassOnJoin(player, key, deps.config.passRetries)
			end)
		end
	end
	deps.spawn(function()
		MonetizationService.refreshClub(player)
	end)
end

-- A player left: forget everything about them (a rejoin asks again).
function MonetizationService.forget(player: Player)
	known[player] = nil
	passCache[player] = nil
	studioPasses[player] = nil
	clubMembers[player] = nil
	studioClub[player] = nil
	offerState[player] = nil
	local timer = clubTimers[player]
	clubTimers[player] = nil
	if timer ~= nil then
		deps.cancel(timer)
	end
end

-- Boot ----------------------------------------------------------------------------------------------------------

-- A sibling service that may not exist yet (Phase 12 live-ops), or nil.
local function optionalSibling(name: string): any
	local module = script.Parent:FindFirstChild(name)
	if module == nil or not module:IsA("ModuleScript") then
		return nil
	end
	local ok, result = pcall(require :: any, module)
	return if ok and type(result) == "table" then result else nil
end

function MonetizationService:Init()
	DataService = require(script.Parent.DataService)
	ProfileSyncService = require(script.Parent.ProfileSyncService)
	eventModule = optionalSibling("EventService")
	limitedModule = optionalSibling("LimitedService")
	flagModule = optionalSibling("FeatureFlagService")
	streakModule = optionalSibling("StreakService")
	deps = defaultDeps()
end

function MonetizationService:Start()
	MarketplaceService.ProcessReceipt = MonetizationService.processReceipt
	MarketplaceService.PromptGamePassPurchaseFinished:Connect(onPassPurchaseFinished)
	local ok, err = pcall(function()
		(Players :: any).UserSubscriptionStatusChanged:Connect(onSubscriptionChanged)
	end)
	if not ok then
		warn(`{LOG} can't follow subscription changes: {err}`)
	end

	Net.onServerInvoke("BuyProduct", function(player: Player, payload: any): Reply
		return MonetizationService.buyProduct(player, payload.key)
	end)
	Net.onServerInvoke("BuyPass", function(player: Player, payload: any): Reply
		return MonetizationService.buyPass(player, payload.key)
	end)
	Net.onServerInvoke("JoinClub", function(player: Player): Reply
		return MonetizationService.joinClub(player)
	end)
	Net.onServerInvoke("GetStore", function(player: Player): StorePayload
		return MonetizationService.storeSnapshot(player)
	end)
	-- Always answers, so the remote never hangs; devPurchase itself refuses outside Studio.
	Net.onServerInvoke("DevPurchase", function(player: Player, payload: any): Reply
		return MonetizationService.devPurchase(player, payload)
	end)

	Players.PlayerAdded:Connect(MonetizationService.onJoin)
	Players.PlayerRemoving:Connect(MonetizationService.forget)
	for _, player in Players:GetPlayers() do
		MonetizationService.onJoin(player)
	end
	local dataService = DataService
	if dataService ~= nil then
		dataService.onChanged(checkOffers)
	end
end

return MonetizationService
