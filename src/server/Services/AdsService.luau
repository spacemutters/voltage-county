--!strict
-- Ads on the server (PLAN.md Phase 12 "Highway billboards" and "Rewarded video ads"; docs/phase-12-contracts.md
-- "Ads, analytics, admin"; Config/Ads). Fair monetization (CLAUDE.md hard rule 6): ads go only through Roblox's ad
-- APIs, and only when Roblox says one can show.
--
-- Billboards: Dev/MapBuilder builds a panel per Config/MapLayout billboard, tagged Config/Ads.billboards.tag, with a
-- switched-off AdGui on its ad face and the brand's poster on its back face. At Start (and whenever the `billboards`
-- flag changes) every panel is put in one of two modes (billboardMode):
--   ad      Config/Ads.billboards.serveAds is true, the flag is on, the panel has its AdGui and its brand's poster
--           has an uploaded image: the AdGui switches on with that image as its fallback (what shows when Roblox
--           serves no ad) and the ad face holds nothing else.
--   poster  anything else: the AdGui stays off and the poster is copied onto the ad face, so both faces show it. A
--           brand whose poster image isn't uploaded yet stays here, so a billboard never shows Roblox's default image.
--
-- Rewarded video ("watch an ad for 1 credit a day"; off until the `rewardedAds` flag is on):
--   offer    the player attribute Config/Ads.rewardedVideo.readyAttribute is true while the flag is on, the reward
--            product exists (its id isn't 0), the save is loaded and today's (UTC) credit isn't claimed yet. The store
--            shows the button only while it is true AND the client's own AdService:GetAdAvailabilityNowAsync answers
--            IsAvailable (Roblox's call; it is good for one play).
--   watch    Net WatchAdReward (no payload) checks the same things again (watchDecision), turns the product into an
--            AdReward and plays the ad (AdService:ShowRewardedVideoAdAsync). Answers { ok, message, code } straight
--            away when refused, else when the ad ends.
--   reward   Roblox pays the reward as a receipt for that product. MonetizationService's one ProcessReceipt hands it
--            here (registerProduct; the product is never shown or prompted in the store). One DataStore row per
--            player { day, purchaseId, granted } (UpdateAsync) holds the daily limit across servers and makes the
--            grant idempotent: a receipt that already paid never pays again, and a second ad's receipt on the same
--            UTC day is accepted without a credit. The claim is written before CreditsService.grant; if the grant
--            fails the claim is handed back and the receipt is left for Roblox to redeliver. A receipt that shows
--            Robux spent (never prompted, but possible) is paid without the daily limit.
--
-- Pure decisions (utcDay, billboardMode, faceFits, watchDecision, claimDecision, cleanClaim, isLimitedReceipt) and
-- the receipt flow (rewardReceipt, with a fake store and clock) are exported for tests/Ads.spec, which runs in Edit
-- mode. Server-authoritative: the client only asks; the server decides. No polling: one timer per UTC midnight
-- refreshes the offer.

local AdServiceRoblox: any = game:GetService("AdService")
local CollectionService = game:GetService("CollectionService")
local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Ads = require(ReplicatedStorage.Shared.Config.Ads)
local Net = require(ReplicatedStorage.Shared.Net)

-- DataService is required in Init rather than here: it loads ProfileStore, which talks to DataStores straight away,
-- and tests/Ads.spec requires this module in Edit mode.
type DataServiceModule = typeof(require(script.Parent.DataService))

export type Mode = "ad" | "poster"
export type Reply = { ok: boolean, message: string, code: string }

-- What watchDecision looks at.
export type WatchFacts = {
	flagOn: boolean, -- the rewardedAds flag
	productId: number, -- the reward product (0 = not created)
	loaded: boolean, -- the player's save is loaded
	claimedToday: boolean, -- today's credit is already paid
	showing: boolean, -- an ad is playing for this player right now
}

-- One player's DataStore row.
export type Claim = { day: number, purchaseId: string, granted: boolean }

-- "claim": pay it (and write the row); "granted": this receipt already paid; "used": today's credit went to
-- another ad, accept the receipt without a credit.
export type ClaimOutcome = "claim" | "granted" | "used"

-- A DataStore row store (the real one wraps DataStoreService; the spec passes a table-backed fake).
-- update returns false when the store couldn't be reached; the transform returns nil to leave the row as it is.
export type Store = {
	get: (key: string) -> (boolean, any),
	update: (key: string, transform: (old: any) -> any) -> boolean,
}

export type Deps = {
	store: Store,
	clock: () -> number, -- os.time() seconds
	grantCredits: (player: Player, amount: number, reason: string) -> boolean,
	notify: (player: Player, text: string) -> (),
	claimed: (player: Player, day: number?) -> (), -- tells the cache (nil: unknown again)
}

local LOG = "[AdsService]"
local SECONDS_PER_DAY = 86400
local NOTIFY_KIND = "success" -- Net Notify toast kind for the credit

local billboards = Ads.billboards
local rewarded = Ads.rewardedVideo

local AdsService = {}

local DataService: DataServiceModule? = nil
local CreditsService: any = nil
local flagService: any = nil
local monetization: any = nil
local analytics: any = nil

local claimedDay: { [Player]: number } = {} -- the UTC day this player's credit was last paid (known players only)
local known: { [Player]: boolean } = {} -- their row has been read
local reading: { [Player]: boolean } = {} -- their row is being read
local showing: { [Player]: boolean } = {}
local memoryRows: { [string]: any } = {} -- Studio only, when DataStores can't be reached
local storeWarned = false

-- Pure decisions --------------------------------------------------------------------------------------------

-- The UTC day number of a time (whole days since 1970-01-01 UTC).
function AdsService.utcDay(now: number): number
	return math.floor(now / SECONDS_PER_DAY)
end

-- How a billboard should look: the ad only when ads are served at all, the flag is on, it has its AdGui and its
-- brand's poster has an uploaded image for the AdGui to fall back on when Roblox serves no ad (without one a no-fill
-- would show Roblox's generic default image instead of the brand's poster).
function AdsService.billboardMode(serveAds: boolean, flagOn: boolean, hasAdUnit: boolean, hasPosterImage: boolean): Mode
	return if serveAds and flagOn and hasAdUnit and hasPosterImage then "ad" else "poster"
end

-- True when an ad face (width x height, studs) is inside Roblox's ad unit limits (Config/Ads.billboards).
function AdsService.faceFits(width: number, height: number): boolean
	return width >= billboards.minFace.X
		and height >= billboards.minFace.Y
		and width <= billboards.maxFace.X
		and height <= billboards.maxFace.Y
end

-- Whether an ad may be offered now; the second value is the Config/Ads.rewardedVideo.messages key that says why
-- not (or "ok").
function AdsService.watchDecision(facts: WatchFacts): (boolean, string)
	if not facts.flagOn then
		return false, "off"
	elseif facts.productId <= 0 then
		return false, "comingSoon"
	elseif not facts.loaded then
		return false, "loading"
	elseif facts.showing then
		return false, "busy"
	elseif facts.claimedToday then
		return false, "claimed"
	end
	return true, "ok"
end

-- A stored row read back from the DataStore (untrusted): a Claim, or nil when it isn't one.
function AdsService.cleanClaim(raw: any): Claim?
	if type(raw) ~= "table" then
		return nil
	end
	local day, purchaseId = raw.day, raw.purchaseId
	if type(day) ~= "number" or day ~= day or type(purchaseId) ~= "string" then
		return nil
	end
	return { day = math.floor(day), purchaseId = purchaseId, granted = raw.granted == true }
end

-- The day a row says a credit was paid on, or nil.
function AdsService.paidDay(raw: any): number?
	local row = AdsService.cleanClaim(raw)
	return if row ~= nil and row.granted then row.day else nil
end

-- What to do with receipt `purchaseId` on UTC day `today`, given the player's stored row. `limited`: the daily
-- limit applies (an ad's receipt; see isLimitedReceipt).
function AdsService.claimDecision(raw: any, today: number, purchaseId: string, limited: boolean): ClaimOutcome
	local row = AdsService.cleanClaim(raw)
	if row ~= nil and row.granted and row.purchaseId == purchaseId then
		return "granted"
	end
	if limited and row ~= nil and row.granted and row.day == today then
		return "used"
	end
	return "claim"
end

-- True when the daily limit applies to a receipt: anything but a receipt that shows Robux were spent and didn't
-- come from an ad (receiptInfo.ProductPurchaseChannel is Enum.ProductPurchaseChannel.AdReward for an ad's reward).
function AdsService.isLimitedReceipt(receiptInfo: { [string]: any }): boolean
	if receiptInfo.ProductPurchaseChannel == Enum.ProductPurchaseChannel.AdReward then
		return true
	end
	local spent = receiptInfo.CurrencySpent
	return not (type(spent) == "number" and spent > 0)
end

-- The receipt flow -------------------------------------------------------------------------------------------

local function rowKey(player: Player): string
	return rewarded.keyPrefix .. tostring(player.UserId)
end

-- MonetizationService's handler for the reward product: true when the receipt is settled (paid now, paid before,
-- or a second ad today that earns nothing), false to have Roblox redeliver it later.
function AdsService.rewardReceipt(deps: Deps, player: Player, receiptInfo: { [string]: any }): boolean
	local rawId = receiptInfo.PurchaseId
	local purchaseId = if type(rawId) == "string" then rawId elseif type(rawId) == "number" then tostring(rawId) else ""
	if purchaseId == "" then
		return false
	end
	local limited = AdsService.isLimitedReceipt(receiptInfo)
	local today = AdsService.utcDay(deps.clock())
	local key = rowKey(player)
	local outcome: ClaimOutcome = "claim"
	local paidOn: number? = nil
	local written = deps.store.update(key, function(old: any): any
		outcome = AdsService.claimDecision(old, today, purchaseId, limited)
		paidOn = AdsService.paidDay(old)
		if outcome ~= "claim" then
			return nil
		end
		return { day = today, purchaseId = purchaseId, granted = true }
	end)
	if not written then
		return false
	end
	if outcome ~= "claim" then
		deps.claimed(player, paidOn)
		if outcome == "used" then
			deps.notify(player, rewarded.messages.claimed)
		end
		return true
	end
	deps.claimed(player, today)
	if deps.grantCredits(player, rewarded.credits, rewarded.reason) then
		deps.notify(player, string.format(rewarded.messages.granted, rewarded.credits))
		return true
	end
	-- The credit couldn't be added: hand the day back (only if the row is still this receipt's) and let Roblox
	-- deliver the receipt again later.
	deps.store.update(key, function(old: any): any
		local row = AdsService.cleanClaim(old)
		if row == nil or row.purchaseId ~= purchaseId then
			return nil
		end
		return { day = row.day, purchaseId = purchaseId, granted = false }
	end)
	deps.claimed(player, nil)
	return false
end

-- Live deps ----------------------------------------------------------------------------------------------------

local function warnStore(what: string, err: any)
	if not storeWarned then
		storeWarned = true
		warn(`{LOG} the ad reward store couldn't be reached ({what}; later failures are not reported): {err}`)
	end
end

-- The real store: DataStoreService (Studio uses its own store, and an in-memory table when DataStores can't be
-- reached there, so the flow can still be tried).
local function liveStore(): Store
	local name = if RunService:IsStudio() then rewarded.studioStore else rewarded.store
	local store: Store = {
		get = function(key: string): (boolean, any)
			local ok, value = pcall(function(): any
				return DataStoreService:GetDataStore(name):GetAsync(key)
			end)
			if ok then
				return true, value
			end
			warnStore("read", value)
			if RunService:IsStudio() then
				return true, memoryRows[key]
			end
			return false, nil
		end,
		update = function(key: string, transform: (old: any) -> any): boolean
			local ok, err = pcall(function()
				DataStoreService:GetDataStore(name):UpdateAsync(key, function(old: any): any
					return transform(old)
				end)
			end)
			if ok then
				return true
			end
			warnStore("write", err)
			if RunService:IsStudio() then
				local value = transform(memoryRows[key])
				if value ~= nil then
					memoryRows[key] = value
				end
				return true
			end
			return false
		end,
	}
	return store
end

local function notify(player: Player, text: string)
	if player.Parent == Players then
		Net.fireClient("Notify", player, { text = text, kind = NOTIFY_KIND })
	end
end

local function flagOn(name: string): boolean
	local service = flagService
	if service == nil or type(service.isOn) ~= "function" then
		return false
	end
	local ok, on = pcall(service.isOn, name)
	return ok and on == true
end

local function loaded(player: Player): boolean
	local dataService = DataService
	return dataService ~= nil and dataService.get(player) ~= nil
end

local refreshReady: (player: Player) -> ()

local function setClaimed(player: Player, day: number?)
	if day ~= nil then
		claimedDay[player] = day
		known[player] = true
	else
		claimedDay[player] = nil
		known[player] = nil
	end
	refreshReady(player)
end

local function liveDeps(): Deps
	return {
		store = liveStore(),
		clock = os.time,
		grantCredits = function(player: Player, amount: number, reason: string): boolean
			local credits = CreditsService
			if credits == nil then
				return false
			end
			return credits.grant(player, amount, reason) == true
		end,
		notify = notify,
		claimed = setClaimed,
	}
end

-- Reads the player's row once (yields). True when it is known afterwards.
local function readRow(player: Player): boolean
	if known[player] then
		return true
	end
	local ok, value = liveStore().get(rowKey(player))
	if not ok or player.Parent ~= Players then
		return false
	end
	known[player] = true
	local day = AdsService.paidDay(value)
	if day ~= nil then
		claimedDay[player] = day
	end
	return true
end

local function claimedToday(player: Player): boolean
	return claimedDay[player] == AdsService.utcDay(os.time())
end

-- Keeps the offer attribute in step: true only while an ad may be offered. The player's row is read (once, in the
-- background) the first time it matters; until then the attribute stays false.
function refreshReady(player: Player)
	if player.Parent ~= Players then
		return
	end
	local ok = AdsService.watchDecision({
		flagOn = flagOn(rewarded.flag),
		productId = rewarded.productId,
		loaded = loaded(player),
		claimedToday = claimedToday(player),
		showing = false,
	})
	if ok and not known[player] then
		player:SetAttribute(rewarded.readyAttribute, false)
		if not reading[player] then
			reading[player] = true
			task.spawn(function()
				local read = readRow(player)
				reading[player] = nil
				if read then
					refreshReady(player)
				end
			end)
		end
		return
	end
	player:SetAttribute(rewarded.readyAttribute, ok)
end

local function refreshAllReady()
	for _, player in Players:GetPlayers() do
		refreshReady(player)
	end
end

-- At every UTC midnight the day's credit comes back.
local function scheduleMidnight()
	local now = os.time()
	local wait = (AdsService.utcDay(now) + 1) * SECONDS_PER_DAY - now
	task.delay(wait, function()
		refreshAllReady()
		scheduleMidnight()
	end)
end

-- Rewarded video -----------------------------------------------------------------------------------------------

local function answer(ok: boolean, code: string): Reply
	return { ok = ok, message = rewarded.messages[code] or rewarded.messages.failed, code = code }
end

-- Plays the ad. Returns the Enum.ShowAdResult name, or "error" when the call itself failed.
local function showAd(player: Player): string
	local ok, result = pcall(function(): any
		local reward = AdServiceRoblox:CreateAdRewardFromDevProductId(rewarded.productId)
		if rewarded.placementId > 0 then
			return AdServiceRoblox:ShowRewardedVideoAdAsync(player, reward, rewarded.placementId)
		end
		return AdServiceRoblox:ShowRewardedVideoAdAsync(player, reward)
	end)
	if not ok then
		warn(`{LOG} couldn't play an ad for {player.Name}: {result}`)
		return "error"
	end
	return if typeof(result) == "EnumItem" then (result :: EnumItem).Name else tostring(result)
end

-- The ad's result as a reply code.
local RESULT_CODES: { [string]: string } = {
	ShowCompleted = "thanks",
	AdNotReady = "notReady",
	AdAlreadyShowing = "busy",
	ShowInterrupted = "interrupted",
}

local function watchFacts(player: Player, claimed: boolean): WatchFacts
	return {
		flagOn = flagOn(rewarded.flag),
		productId = rewarded.productId,
		loaded = loaded(player),
		claimedToday = claimed,
		showing = showing[player] == true,
	}
end

local function onWatch(player: Player, _payload: any): Reply
	-- Everything but today's credit first, so nothing reads the store while the offer is off.
	local ok, code = AdsService.watchDecision(watchFacts(player, false))
	if not ok then
		return answer(false, code)
	end
	if not readRow(player) then
		return answer(false, "failed") -- the row couldn't be read, so we can't tell; nothing is shown
	end
	ok, code = AdsService.watchDecision(watchFacts(player, claimedToday(player)))
	if not ok then
		return answer(false, code)
	end
	showing[player] = true
	local result = showAd(player)
	showing[player] = nil
	local resultCode = RESULT_CODES[result] or "failed"
	local service = analytics
	if service ~= nil and type(service.rewardedAd) == "function" then
		pcall(service.rewardedAd, player, result)
	end
	return answer(resultCode == "thanks", resultCode)
end

-- Billboards ---------------------------------------------------------------------------------------------------

local function isFrontCopy(child: Instance): boolean
	local prefix = billboards.frontPosterPrefix
	return child:IsA("SurfaceGui") and string.sub(child.Name, 1, #prefix) == prefix
end

-- Puts one panel in `mode` (see the header). Safe to call again with the same mode.
local function applyBillboard(panel: Instance, mode: Mode)
	local unit: any = panel:FindFirstChild(billboards.adUnitName)
	if mode == "ad" then
		for _, child in panel:GetChildren() do
			if isFrontCopy(child) then
				child:Destroy()
			end
		end
		if unit ~= nil then
			local brandId = panel:GetAttribute(billboards.brandAttribute)
			local poster = if type(brandId) == "string" then billboards.posters[brandId] else nil
			local ok, err = pcall(function()
				unit.EnableVideoAds = billboards.enableVideoAds
				if poster ~= nil and poster.image ~= "" then
					unit.FallbackImage = poster.image
				end
				unit.Enabled = true
			end)
			if not ok then
				warn(`{LOG} couldn't switch on the ad unit on {panel:GetFullName()}: {err}`)
			end
		end
		return
	end
	if unit ~= nil then
		pcall(function()
			unit.Enabled = false
		end)
	end
	for _, child in panel:GetChildren() do
		if isFrontCopy(child) then
			return -- already showing the poster on the ad face
		end
	end
	local count = 0
	for _, child in panel:GetChildren() do
		if child:IsA("SurfaceGui") and (child :: SurfaceGui).Face == billboards.posterFace then
			count += 1
			local copy = (child :: SurfaceGui):Clone()
			copy.Name = `{billboards.frontPosterPrefix}{count}`
			copy.Face = billboards.adFace
			copy.Parent = panel
		end
	end
end

local function billboardModeNow(panel: Instance): Mode
	local hasUnit = panel:FindFirstChild(billboards.adUnitName) ~= nil
	local brandId = panel:GetAttribute(billboards.brandAttribute)
	local poster = if type(brandId) == "string" then billboards.posters[brandId] else nil
	local hasImage = poster ~= nil and poster.image ~= ""
	return AdsService.billboardMode(billboards.serveAds, flagOn(billboards.flag), hasUnit, hasImage)
end

local function applyAllBillboards()
	for _, panel in CollectionService:GetTagged(billboards.tag) do
		applyBillboard(panel, billboardModeNow(panel))
	end
end

-- Boot ---------------------------------------------------------------------------------------------------------

local function optional(name: string): any
	local module = script.Parent:FindFirstChild(name)
	if module == nil or not module:IsA("ModuleScript") then
		return nil
	end
	local ok, result = pcall(require :: any, module)
	return if ok and type(result) == "table" then result else nil
end

local function onFlag(name: string, fn: () -> ())
	local service = flagService
	if service ~= nil and type(service.onChanged) == "function" then
		pcall(service.onChanged, name, function(_on: boolean)
			fn()
		end)
	end
end

function AdsService:Init()
	DataService = require(script.Parent.DataService)
	CreditsService = optional("CreditsService")
	flagService = optional("FeatureFlagService")
	monetization = optional("MonetizationService")
	analytics = optional("AnalyticsService")
end

function AdsService:Start()
	Net.onServerInvoke("WatchAdReward", onWatch)

	-- Billboards.
	applyAllBillboards()
	CollectionService:GetInstanceAddedSignal(billboards.tag):Connect(function(panel: Instance)
		applyBillboard(panel, billboardModeNow(panel))
	end)
	onFlag(billboards.flag, applyAllBillboards)

	-- Rewarded video: the receipts, the offer attribute and its midnight refresh.
	local service = monetization
	if service ~= nil and type(service.registerProduct) == "function" then
		local ok, err = pcall(
			service.registerProduct,
			rewarded.productKey,
			function(player: Player, receipt: any): boolean
				return AdsService.rewardReceipt(liveDeps(), player, receipt)
			end,
			{ productId = rewarded.productId, available = false }
		)
		if not ok then
			warn(`{LOG} couldn't register the ad reward product: {err}`)
		end
	else
		warn(`{LOG} MonetizationService.registerProduct isn't there: ad rewards can't be paid`)
	end
	onFlag(rewarded.flag, refreshAllReady)
	local dataService = DataService
	if dataService ~= nil then
		dataService.onLoaded(function(player: Player, _data: any)
			refreshReady(player)
		end)
	end
	Players.PlayerRemoving:Connect(function(player: Player)
		claimedDay[player] = nil
		known[player] = nil
		reading[player] = nil
		showing[player] = nil
	end)
	scheduleMidnight()
end

return AdsService
