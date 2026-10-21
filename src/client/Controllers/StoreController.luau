--!strict
-- The store on the client (docs/phase-12-contracts.md "Store UI"; PLAN.md Phase 12 and §11). Keeps the store's
-- shared state (UI/Store/StoreState) that the phone's Store app (UI/Phone/StoreApp) draws, answers its taps, and owns
-- the "StoreOffer" ScreenGui that shows the one-time offer sheet (UI/Store/OfferSheet in the shop kit's sheet).
--
--   the store     Net GetStore (MonetizationService.storeSnapshot): once at start, and again when the Store app
--                 opens and the last answer is older than StoreStyle.refreshAfterSeconds. Every StoreUpdate carries
--                 the whole store again and replaces it. Prices are the numbers the server read from
--                 MarketplaceService; nothing here knows a price. Never on a timer.
--   buying        Buy on a pack, a pass or the club -> Net BuyProduct { key } / BuyPass { key } / JoinClub. The
--                 server checks the id (0: "coming soon") and shows Roblox's own purchase prompt; when a purchase
--                 lands it thanks the player (Notify) and sends StoreUpdate. Items the server didn't put on sale, or
--                 that this player can't buy now, have no button, and this refuses to send for them anyway. One
--                 request at a time; a refusal shows the server's words.
--   daily reward  the card follows StreakService's player attributes (Config/Season.streak.attributes: the day,
--                 whether it can be claimed, when the next day starts). Claim -> Net ClaimStreak; the reply's words
--                 show as a notice and its `streak` updates the card.
--   invites       "Invite your crew" shows when SocialService:CanSendGameInviteAsync says this player can send
--                 invites (asked once, when the store first loads) and opens SocialService:PromptGameInvite.
--   Roblox Plus   the private-servers card reads Player.HasRobloxSubscription (and follows it), and "Get Roblox Plus"
--                 opens MarketplaceService:PromptRobloxSubscriptionPurchase. Both are looked up safely: an engine
--                 without them just doesn't show the button.
--   events        Net EventUpdate (and `events` in GetStore) fill the Store app's banner and countdowns; an event
--                 that's on shows a notice once per session. A limited drop on sale has Buy -> Net BuyLimited
--                 { dropId }; the reply's words show as a notice.
--   Season Pass   the More page's card follows SeasonService's player attributes (Config/Season.attributes); Claim ->
--                 Net ClaimSeasonReward { tier, track }.
--   ad credit     the free daily credit card shows while AdsService's attribute (Config/Ads.rewardedVideo
--                 .readyAttribute) is true AND AdService:GetAdAvailabilityNowAsync(RewardedVideo) answers IsAvailable
--                 (asked when the attribute changes, when the Store app opens and after each ad). Watch -> Net
--                 WatchAdReward; the server plays the ad and the credit arrives as a receipt.
--   Get credits   the Out of credits sheet's Get credits (DesignerController.onGetCredits) puts the designer sheet
--                 away and opens the Store app on its Credits page. StoreState.open does the same from anywhere.
--   the offer     a one-time offer (the Starter Pack, Config/Offers) shows as a sheet when the server says it came
--                 up: MonetizationService sends StoreUpdate with `changed = { kind = "offer", key = <offer id> }` the
--                 moment the player's first free design or first job payout happens (not on join). It shows only while
--                 its product can be bought (an id of 0 is "Coming soon"; a bought pack is owned: no sheet), so it
--                 never shows again after it's bought. When something else is on screen (a drive, a designer or shop
--                 sheet, the phone, a cutscene) it waits, and gives up after StoreStyle.offer.maxWaitSeconds; opening
--                 the Store app counts as seeing it (the Credits page shows the pack while the offer is up). The
--                 Store icon has a dot while it waits.
--   cutscene      while PhoneConfig.cutsceneAttribute is true (a pod ride) the offer sheet is hidden and put back
--                 after.
--
-- Server-authoritative: every purchase, claim and grant is the server's decision. No polling: remotes, profile,
-- drive and attribute events, plus a slow retry only while an offer waits.

local AdService = game:GetService("AdService")
local ContextActionService = game:GetService("ContextActionService")
local GuiService = game:GetService("GuiService")
local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SocialService = game:GetService("SocialService")

local React = require(ReplicatedStorage.Packages.React)
local ReactRoblox = require(ReplicatedStorage.Packages.ReactRoblox)
local Ads = require(ReplicatedStorage.Shared.Config.Ads)
local Controls = require(ReplicatedStorage.Shared.Config.Controls)
local Season = require(ReplicatedStorage.Shared.Config.Season)
local Net = require(ReplicatedStorage.Shared.Net)
local DesignerController = require(script.Parent.DesignerController)
local DriveController = require(script.Parent.DriveController)
local HudController = require(script.Parent.HudController)
local NotifyController = require(script.Parent.NotifyController)
local PhoneController = require(script.Parent.PhoneController)
local ProfileController = require(script.Parent.ProfileController)
local ShopController = require(script.Parent.ShopController)

local UI = script.Parent.Parent.UI
local Theme = require(UI.Theme)
local PhoneConfig = require(UI.Phone.PhoneConfig)
local ShopModel = require(UI.Shop.ShopModel)
local ShopSheet = require(UI.Shop.ShopSheet)
local DesignerStore = require(UI.Designer.DesignerStore)
local OfferSheet = require(UI.Store.OfferSheet)
local StoreModel = require(UI.Store.StoreModel)
local StoreState = require(UI.Store.StoreState)
local StoreStyle = require(UI.Store.StoreStyle)

local GUI_NAME = "StoreOffer"
local CLOSE_PRIORITY = Controls.actionPriority + StoreStyle.priorityAbovePhone
local OFFER_BUSY = "offer" -- StoreState.busy while the offer sheet's Buy is with the server

local e = React.createElement
local copy = StoreStyle.copy

-- The offer sheet on screen.
type OfferView = { offerId: string, productKey: string }

-- An offer the server said came up, waiting for a free screen until `deadline` (os.clock()).
type Pending = { offerId: string, deadline: number }

type View = {
	offer: OfferView?,
	session: number, -- bumped whenever the sheet opens, so it slides in fresh
	scale: number,
	screen: Vector2, -- unscaled pixels inside the safe area
	cutscene: boolean,
}

local StoreController = {}

local localPlayer = Players.LocalPlayer

local view: View = {
	offer = nil,
	session = 0,
	scale = 1,
	screen = Vector2.new(Controls.hud.referenceShortSide, Controls.hud.referenceShortSide),
	cutscene = false,
}

local root: any = nil
local screenGui: ScreenGui? = nil
local closeBound = false
local refetch = false -- a fresh store was asked for while a GetStore call was out: ask again when it's back
local limitRetried = false -- a GetStore call Net turned away was already tried again
local pending: Pending? = nil
local retryScheduled = false
local inviteChecking = false
local adChecking = false
local announced: { [string]: boolean } = {} -- events already announced this session

-- Forward declarations.
local render: () -> ()
local tryShowOffer: () -> ()

-- Replies --------------------------------------------------------------------------------------------------------

-- Shows a refusal or failure as a notice. Returns whether the request worked.
local function showProblem(called: boolean, reply: any): boolean
	if not called then
		NotifyController.show(copy.failedAction, "error")
		return false
	elseif type(reply) ~= "table" then
		NotifyController.show(copy.tryLater, "warning") -- Net turned the call away (too many in a row)
		return false
	elseif reply.ok ~= true then
		local message = if type(reply.message) == "string" and reply.message ~= "" then reply.message else nil
		NotifyController.show(message or copy.failedAction, "warning")
		return false
	end
	return true
end

-- Sends one request (one at a time across the store): `busy` names it on screen until the answer is in. `after`
-- runs with whether it worked and the reply.
local function request(busy: string, remote: string, payload: any?, after: ((worked: boolean, reply: any) -> ())?)
	if StoreState.get().busy ~= nil then
		return
	end
	StoreState.update(function(draft: StoreState.State)
		draft.busy = busy
	end)
	task.spawn(function()
		local called, reply = pcall(Net.invokeServer, remote, payload)
		StoreState.update(function(draft: StoreState.State)
			draft.busy = nil
		end)
		local worked = showProblem(called, reply)
		if after ~= nil then
			after(worked, reply)
		end
	end)
end

-- Events ---------------------------------------------------------------------------------------------------------

-- A notice for each event that's on now, once per session.
local function announce(events: { StoreModel.Event })
	local live = StoreModel.liveEvents(events, StoreState.now())
	for _, event in live do
		if not announced[event.id] then
			announced[event.id] = true
			NotifyController.show(string.format(copy.eventStarted, event.title), "success")
		end
	end
end

local function setEvents(events: { StoreModel.Event })
	StoreState.update(function(draft: StoreState.State)
		draft.events = events
	end)
	announce(events)
end

-- The store ------------------------------------------------------------------------------------------------------

-- Whether Roblox says this player can send game invites (asked once; asked again later only if the call failed).
local function checkInvite()
	if inviteChecking or StoreState.get().invite ~= "unknown" then
		return
	end
	inviteChecking = true
	task.spawn(function()
		local ok, can = pcall(function(): boolean
			return SocialService:CanSendGameInviteAsync(localPlayer)
		end)
		inviteChecking = false
		if ok then
			StoreState.update(function(draft: StoreState.State)
				draft.invite = if can == true then "yes" else "no"
			end)
		end
	end)
end

-- Asks the server what the store sells now: always with `force`, else only when the last answer is old.
local function fetchStore(force: boolean)
	local state = StoreState.get()
	if state.loading then
		refetch = refetch or force
		return
	end
	local fetchedAt = state.fetchedAt
	if not force and fetchedAt ~= nil and os.clock() - fetchedAt < StoreStyle.refreshAfterSeconds then
		return
	end
	StoreState.update(function(draft: StoreState.State)
		draft.loading = true
	end)
	task.spawn(function()
		local called, reply = pcall(Net.invokeServer, "GetStore")
		local store = if called then StoreModel.normalize(reply) else nil
		StoreState.update(function(draft: StoreState.State)
			draft.loading = false
			if store ~= nil then
				draft.store = store
				draft.failed = false
				draft.fetchedAt = os.clock()
				if store.streak ~= nil then
					draft.streak = store.streak
				end
			else
				draft.failed = true -- a store already shown stays on screen
			end
		end)
		if store ~= nil and store.events ~= nil then
			setEvents(store.events)
		end
		if refetch then
			refetch = false
			fetchStore(true)
			return
		end
		if store ~= nil then
			limitRetried = false
		elseif called and reply == nil and not limitRetried then
			-- Net turned the call away (too many in a row): once more in a moment, so a purchase shows.
			limitRetried = true
			task.delay(StoreStyle.storeRetrySeconds, function()
				fetchStore(true)
			end)
		end
		checkInvite()
		tryShowOffer()
	end)
end

local function storeProduct(key: string): StoreModel.Product?
	return StoreModel.product(StoreState.get().store, key)
end

function StoreController.buyProduct(key: string)
	local product = storeProduct(key)
	if product == nil or StoreModel.itemState(product) ~= "buy" then
		return -- not on sale: the card has no button
	end
	request(`product:{key}`, "BuyProduct", { key = key })
end

function StoreController.buyPass(key: string)
	local store = StoreState.get().store
	if store == nil then
		return
	end
	for _, pass in store.passes do
		if pass.key == key and StoreModel.itemState(pass) == "buy" then
			request(`pass:{key}`, "BuyPass", { key = key })
			return
		end
	end
end

function StoreController.joinClub()
	local store = StoreState.get().store
	if store == nil or store.club.member or not store.club.canBuy then
		return
	end
	request("club", "JoinClub", nil)
end

function StoreController.claimStreak()
	request("streak", "ClaimStreak", nil, function(worked: boolean, reply: any)
		if worked and type(reply) == "table" and type(reply.message) == "string" and reply.message ~= "" then
			NotifyController.show(reply.message, "success")
		end
		StoreState.update(function(draft: StoreState.State)
			draft.streak = StoreModel.streakAfterClaim(draft.streak, reply, StoreState.now())
		end)
	end)
end

function StoreController.invite()
	task.spawn(function()
		local ok = pcall(function()
			SocialService:PromptGameInvite(localPlayer)
		end)
		if not ok then
			NotifyController.show(copy.failedAction, "error")
		end
	end)
end

function StoreController.getPlus()
	local ok = pcall(function()
		(MarketplaceService :: any):PromptRobloxSubscriptionPurchase(localPlayer)
	end)
	if not ok then
		NotifyController.show(copy.failedAction, "error")
	end
end

-- A request whose good answer's words show as a success notice (a refusal's already show as a warning).
local function thankOnSuccess(worked: boolean, reply: any)
	if worked and type(reply) == "table" and type(reply.message) == "string" and reply.message ~= "" then
		NotifyController.show(reply.message, "success")
	end
end

-- The free daily ad credit (Services/AdsService) ----------------------------------------------------------------------

local function setAdReady(ready: boolean)
	if StoreState.get().adReady ~= ready then
		StoreState.update(function(draft: StoreState.State)
			draft.adReady = ready
		end)
	end
end

-- Whether the card can show: the server's attribute (on offer today) AND Roblox's own answer that an ad can play now
-- (AdService:GetAdAvailabilityNowAsync, good for one play). Asked when the attribute changes, when the Store app
-- opens and after each ad, never on a timer.
local function checkAd()
	if localPlayer:GetAttribute(Ads.rewardedVideo.readyAttribute) ~= true then
		setAdReady(false)
		return
	end
	if adChecking then
		return
	end
	adChecking = true
	task.spawn(function()
		local ok, available = pcall(function(): boolean
			local format = (Enum :: any).AdFormat.RewardedVideo
			local result = (AdService :: any):GetAdAvailabilityNowAsync(format)
			return result.AdAvailabilityResult == (Enum :: any).AdAvailabilityResult.IsAvailable
		end)
		adChecking = false
		local offered = localPlayer:GetAttribute(Ads.rewardedVideo.readyAttribute) == true
		setAdReady(offered and ok and available == true)
	end)
end

function StoreController.watchAd()
	if not StoreState.get().adReady then
		return
	end
	setAdReady(false) -- Roblox's "can play" is good for one play: ask again after it
	request("ad", "WatchAdReward", nil, function(worked: boolean, reply: any)
		thankOnSuccess(worked, reply)
		checkAd()
	end)
end

-- Limited drops and the Season Pass ------------------------------------------------------------------------------------

function StoreController.buyDrop(dropId: string)
	request(`drop:{dropId}`, "BuyLimited", { dropId = dropId }, thankOnSuccess)
end

function StoreController.claimSeason(tier: number, track: StoreModel.SeasonTrack)
	request(`season:{track}`, "ClaimSeasonReward", { tier = tier, track = track }, thankOnSuccess)
end

-- The Season Pass attributes Services/SeasonService keeps (Config/Season.attributes).
local function readSeason()
	local names = Season.attributes
	local input: StoreModel.SeasonInput = {
		xp = localPlayer:GetAttribute(names.xp),
		premium = localPlayer:GetAttribute(names.premium),
		claimed = localPlayer:GetAttribute(names.claimed),
	}
	StoreState.update(function(draft: StoreState.State)
		draft.season = input
	end)
end

-- Roblox Plus: whether the player has it (nil when this engine doesn't say) and whether the prompt exists.
local function readPlus()
	local ok, value = pcall(function(): any
		return (localPlayer :: any).HasRobloxSubscription
	end)
	local member: boolean? = if ok and type(value) == "boolean" then value else nil
	local promptOk, prompt = pcall(function(): any
		return (MarketplaceService :: any).PromptRobloxSubscriptionPurchase
	end)
	local canPrompt = promptOk and type(prompt) == "function"
	local state = StoreState.get()
	if state.plusMember ~= member or state.plusAvailable ~= canPrompt then
		StoreState.update(function(draft: StoreState.State)
			draft.plusMember = member
			draft.plusAvailable = canPrompt
		end)
	end
end

-- Opens the phone's Store app (on `page`), putting the designer's sheet away first.
function StoreController.open(page: StoreState.Page?)
	if DesignerController.isOpen() then
		DesignerController.close()
	end
	if page ~= nil then
		StoreState.setPage(page)
	end
	PhoneController.open("store")
end

-- The offer sheet --------------------------------------------------------------------------------------------------

local function setOfferDue(due: boolean)
	if StoreState.get().offerDue ~= due then
		StoreState.update(function(draft: StoreState.State)
			draft.offerDue = due
		end)
	end
end

local function onCloseKey(_action: string, state: Enum.UserInputState, _input: InputObject): Enum.ContextActionResult
	if state == Enum.UserInputState.Begin then
		StoreController.closeOffer()
	end
	return Enum.ContextActionResult.Sink
end

local function bindCloseKey(on: boolean)
	if on == closeBound then
		return
	end
	closeBound = on
	if on then
		ContextActionService:BindActionAtPriority(
			StoreStyle.closeAction,
			onCloseKey,
			false,
			CLOSE_PRIORITY,
			table.unpack(StoreStyle.closeKeys)
		)
	else
		ContextActionService:UnbindAction(StoreStyle.closeAction)
	end
end

-- Puts the offer sheet away. `again`: it was pushed off screen (a drive, a cutscene) rather than answered, so it
-- waits to show again.
function StoreController.closeOffer(again: boolean?)
	local offer = view.offer
	if offer == nil then
		return
	end
	view.offer = nil
	bindCloseKey(false)
	local selected = GuiService.SelectedObject
	local gui = screenGui
	if selected ~= nil and gui ~= nil and selected:IsDescendantOf(gui) then
		GuiService.SelectedObject = nil
	end
	render()
	if again then
		pending = { offerId = offer.offerId, deadline = os.clock() + StoreStyle.offer.maxWaitSeconds }
		tryShowOffer() -- whatever pushed it off is on screen now: this starts the wait
	else
		setOfferDue(false)
	end
end

local function buyOffer()
	local offer = view.offer
	if offer == nil then
		return
	end
	local product = storeProduct(offer.productKey)
	if product == nil or StoreModel.itemState(product) ~= "buy" then
		return
	end
	request(OFFER_BUSY, "BuyProduct", { key = offer.productKey }, function(worked: boolean)
		-- Roblox's own prompt is up now: this sheet's job is done.
		if worked and view.offer == offer then
			StoreController.closeOffer()
		end
	end)
end

-- Something else is on screen, or the player is driving: the offer waits.
local function blocked(): boolean
	return view.cutscene
		or DriveController.getCar() ~= nil
		or DesignerController.isOpen()
		or ShopController.isOpen()
		or PhoneController.isOpen()
end

local function scheduleRetry()
	local want = pending
	if retryScheduled or want == nil then
		return
	end
	if os.clock() >= want.deadline then
		pending = nil -- the Store app still shows the pack, and the icon keeps its dot until it's opened
		return
	end
	retryScheduled = true
	task.delay(StoreStyle.offer.retrySeconds, function()
		retryScheduled = false
		tryShowOffer()
	end)
end

tryShowOffer = function()
	local want = pending
	if want == nil or view.offer ~= nil then
		return
	end
	local state = StoreState.get()
	if state.loading then
		return -- the call's answer looks again
	elseif state.store == nil then
		fetchStore(false)
		scheduleRetry()
		return
	end
	local offer, product = StoreModel.dueOffer(state.store, want.offerId)
	if offer == nil or product == nil then
		pending = nil -- bought, not on sale, or not in the store: nothing to show
		setOfferDue(false)
		return
	end
	setOfferDue(true)
	if blocked() then
		scheduleRetry()
		return
	end
	pending = nil
	view.offer = { offerId = offer.id, productKey = product.key }
	view.session += 1
	bindCloseKey(true)
	render()
end

-- The server just said offer `offerId` came up (its moment happened): show it as soon as the screen is free.
local function requestOffer(offerId: string)
	pending = { offerId = offerId, deadline = os.clock() + StoreStyle.offer.maxWaitSeconds }
	tryShowOffer()
end

-- Rendering --------------------------------------------------------------------------------------------------------

render = function()
	if root == nil then
		return
	end
	local offer = view.offer
	local state = StoreState.get()
	local product = if offer ~= nil then StoreModel.product(state.store, offer.productKey) else nil
	if offer == nil or product == nil or view.cutscene then
		root:render(nil)
		return
	end
	root:render(e("Frame", {
		Size = UDim2.fromScale(1 / view.scale, 1 / view.scale),
		BackgroundTransparency = 1,
	}, {
		Scale = e("UIScale", { Scale = view.scale }),
		[`Sheet{view.session}`] = e(ShopSheet.Sheet, {
			content = OfferSheet.content({
				product = product,
				busy = state.busy == OFFER_BUSY,
				onBuy = buyOffer,
				onClose = function()
					StoreController.closeOffer()
				end,
			}),
			layout = ShopModel.layoutFor(view.screen),
			screen = view.screen,
			confirm = nil,
			gamepad = HudController.getInputKind() == "gamepad",
			onClose = function()
				StoreController.closeOffer()
			end,
		}),
	}))
end

-- The screen in unscaled pixels and the UI scale (the HUD's rule: scale up from a landscape phone, never down).
local function measureScreen(): boolean
	local gui = screenGui
	if gui == nil then
		return false
	end
	local size = gui.AbsoluteSize
	local scale = HudController.scaleFor(size)
	local screen = Vector2.new(math.floor(size.X / scale), math.floor(size.Y / scale))
	if scale == view.scale and screen == view.screen then
		return false
	end
	view.scale = scale
	view.screen = screen
	return true
end

-- The daily streak --------------------------------------------------------------------------------------------------

-- The streak from the player attributes Services/StreakService keeps (set on join, after a claim and at every UTC
-- midnight): the day a claim pays (or paid today), whether it can be claimed, and when the next day starts.
local function readStreak()
	local names = Season.streak.attributes
	local day = localPlayer:GetAttribute(names.day)
	local claimable = localPlayer:GetAttribute(names.claimable)
	local nextAt = localPlayer:GetAttribute(names.nextDay)
	if type(claimable) ~= "boolean" then
		return -- not set yet (or the streak is switched off): the card asks the server when tapped
	end
	local whole = if type(day) == "number" and day == day and day > 0 then math.floor(day) else nil
	local streak: StoreModel.Streak = {
		count = whole or 0,
		day = whole,
		lastDay = nil,
		claimable = claimable,
		nextAt = if type(nextAt) == "number" and nextAt == nextAt then nextAt else nil,
	}
	StoreState.update(function(draft: StoreState.State)
		draft.streak = streak
	end)
end

-- Remotes ----------------------------------------------------------------------------------------------------------

-- StoreUpdate carries the whole store again (MonetizationService.storeSnapshot) and `changed = { kind, key }`; a
-- one-time offer coming up is `changed.kind == "offer"` with the offer's id. The purchase's own thanks arrive as a
-- Notify from the server.
local function onStoreUpdate(payload: any)
	local store = StoreModel.normalize(payload)
	if store == nil or type(payload.products) ~= "table" then
		fetchStore(true) -- not a whole store: ask for one
		return
	end
	StoreState.update(function(draft: StoreState.State)
		draft.store = store
		draft.failed = false
		draft.fetchedAt = os.clock()
		if store.streak ~= nil then
			draft.streak = store.streak
		end
	end)
	if store.events ~= nil then
		setEvents(store.events)
	end
	local changed = payload.changed
	if type(changed) == "table" and changed.kind == "offer" and type(changed.key) == "string" then
		requestOffer(changed.key)
	else
		tryShowOffer()
	end
end

-- Cutscene, boot ---------------------------------------------------------------------------------------------------

local function onCutsceneChanged()
	local cutscene = localPlayer:GetAttribute(PhoneConfig.cutsceneAttribute) == true
	if cutscene == view.cutscene then
		return
	end
	view.cutscene = cutscene
	if cutscene then
		StoreController.closeOffer(true)
	end
	local gui = screenGui
	if gui ~= nil then
		gui.Enabled = not cutscene
	end
	render()
	if not cutscene then
		tryShowOffer()
	end
end

function StoreController:Start()
	local playerGui = localPlayer:WaitForChild("PlayerGui")

	local gui = Instance.new("ScreenGui")
	gui.Name = GUI_NAME
	gui.ResetOnSpawn = false -- one GUI for the whole session
	gui.DisplayOrder = Theme.displayOrder.shop
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	-- Keep the sheet clear of the Roblox top bar, notches and the home indicator.
	gui.ScreenInsets = Enum.ScreenInsets.CoreUISafeInsets
	gui.Parent = playerGui
	screenGui = gui

	root = ReactRoblox.createRoot(gui)
	measureScreen()
	gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		if measureScreen() and view.offer ~= nil then
			render()
		end
	end)

	StoreState.register({
		refresh = function(force: boolean)
			-- The Store app opened: the player sees any offer there, so a waiting one no longer pops up and the
			-- icon's dot goes.
			if not force then
				pending = nil
				setOfferDue(false)
				checkAd() -- whether an ad can play now, for the free credit card
			end
			fetchStore(force)
		end,
		buyProduct = StoreController.buyProduct,
		buyPass = StoreController.buyPass,
		joinClub = StoreController.joinClub,
		claimStreak = StoreController.claimStreak,
		invite = StoreController.invite,
		getPlus = StoreController.getPlus,
		open = StoreController.open,
		watchAd = StoreController.watchAd,
		buyDrop = StoreController.buyDrop,
		claimSeason = StoreController.claimSeason,
	})

	-- The offer sheet follows the store (its Buy turning into "Opening...", or the pack no longer on sale).
	StoreState.subscribe(function(state: StoreState.State)
		local offer = view.offer
		if offer == nil then
			return
		end
		local product = StoreModel.product(state.store, offer.productKey)
		if product == nil or StoreModel.itemState(product) ~= "buy" then
			StoreController.closeOffer()
		else
			render()
		end
	end)

	Net.onClientEvent("StoreUpdate", onStoreUpdate)
	Net.onClientEvent("EventUpdate", function(payload: any)
		setEvents(StoreModel.normalizeEvents(payload))
	end)

	-- Get credits on the Out of credits sheet opens the Store app's Credits page.
	DesignerController.onGetCredits:Connect(function()
		StoreController.open("credits")
	end)

	-- Changes that may free the screen for a waiting offer (a designer sheet closing, a new design, a payout).
	ProfileController.onChanged:Connect(function()
		tryShowOffer()
	end)
	DesignerStore.subscribe(function()
		tryShowOffer()
	end)

	-- The daily streak, from StreakService's player attributes.
	for _, name in Season.streak.attributes do
		localPlayer:GetAttributeChangedSignal(name):Connect(readStreak)
	end
	readStreak()
	-- The Season Pass, from SeasonService's player attributes.
	for _, name in Season.attributes do
		localPlayer:GetAttributeChangedSignal(name):Connect(readSeason)
	end
	readSeason()
	-- The free daily ad credit, from AdsService's player attribute.
	localPlayer:GetAttributeChangedSignal(Ads.rewardedVideo.readyAttribute):Connect(checkAd)
	checkAd()
	DriveController.onDrivingChanged:Connect(function(driving: boolean)
		if driving then
			StoreController.closeOffer(true)
		else
			tryShowOffer()
		end
	end)
	-- A shop sheet opening puts the offer away for later.
	ShopController.onOpened:Connect(function()
		StoreController.closeOffer(true)
	end)
	HudController.onInputKindChanged:Connect(function()
		if view.offer ~= nil then
			render()
		end
	end)
	localPlayer:GetAttributeChangedSignal(PhoneConfig.cutsceneAttribute):Connect(onCutsceneChanged)
	onCutsceneChanged()

	-- Roblox Plus, followed when this engine has the property.
	readPlus()
	pcall(function()
		localPlayer:GetPropertyChangedSignal("HasRobloxSubscription" :: any):Connect(readPlus)
	end)

	fetchStore(true)
	render()
end

return StoreController
