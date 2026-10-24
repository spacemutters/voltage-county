--!strict
-- Monetization core (PLAN.md Phase 12 acceptance; docs/phase-12-contracts.md "Monetization core"):
--   * the same receipt delivered 3 times grants once, credit packs included, and its PurchaseId is saved with it;
--     PurchaseGranted only once the DataStore holds the receipt
--   * ids of 0 no-op: nothing is prompted, asked of Roblox or granted, and the store says "coming soon"
--   * a product granting a look the Wrap & Tint shop doesn't have is never sold; every look anything sells exists
--   * the Starter Pack shows after each of its moments, can be bought once, and its offer never shows again; the
--     store's offer flags read the same way in the Store app (UI/Store/StoreModel)
--   * credit pack bonus amounts (and a running event's bonus share)
--   * only the newest Config/Data.maxReceipts receipts are kept; NotProcessedYet while the save isn't loaded
--   * pass checks are cached, retried when Roblox errors on join, a pass bought in game counts at once, Garage+ adds
--     its slots; DevPurchase is Studio only
--   * the store waits for a save that is still loading
--   * schema 7: the 6 -> 7 migration gives every save an empty `cosmetics`
--   * the store's words: Light Show Pro says plainly its routines are lights only while any has no music, the club
--     card names its look, the Season Pass counts its looks; the season and the launch-week sales share launch day
-- It drives the real MonetizationService with fake Roblox pieces (MonetizationService.setDeps): a marketplace that
-- records every call, a save table, a fixed clock and a Studio switch. Pure: runs in Edit mode.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local StarterPlayer = game:GetService("StarterPlayer")

local Audio = require(ReplicatedStorage.Shared.Config.Audio)
local Customization = require(ReplicatedStorage.Shared.Config.Customization)
local LightShows = require(ReplicatedStorage.Shared.Config.LightShows)
local Data = require(ReplicatedStorage.Shared.Config.Data)
local Economy = require(ReplicatedStorage.Shared.Config.Economy)
local Events = require(ReplicatedStorage.Shared.Config.Events)
local Harness = require(ReplicatedStorage.Shared.Testing.Harness)
local Limiteds = require(ReplicatedStorage.Shared.Config.Limiteds)
local Monetization = require(ReplicatedStorage.Shared.Config.Monetization)
local Offers = require(ReplicatedStorage.Shared.Config.Offers)
local Season = require(ReplicatedStorage.Shared.Config.Season)
local Types = require(ReplicatedStorage.Shared.Types)
local Services = ServerScriptService.Server.Services
local Migrations = require(Services.DataService.Migrations)
local MonetizationService = require(Services.MonetizationService)
local Template = require(Services.DataService.Template)
local StoreModel = require(StarterPlayer.StarterPlayerScripts.Client.UI.Store.StoreModel)
local ChatTagController = require(StarterPlayer.StarterPlayerScripts.Client.Controllers.ChatTagController)

local NOW = 1_790_000_000 -- any fixed os.time()
local USER_ID = 4242
local STRANGER_ID = 7 -- a buyer who isn't in this server
local PRODUCT_ID_BASE = 1000
local PASS_ID_BASE = 2000
local CLUB_ID = "EXP-SPEC-CLUB"
local UNKNOWN_PRODUCT_ID = 999999
local REGISTERED_ID = 5555

local GRANTED = Enum.ProductPurchaseDecision.PurchaseGranted
local NOT_YET = Enum.ProductPurchaseDecision.NotProcessedYet

local PASS_KEYS = { "vip", "fleetManager", "garagePlus", "lightShowPro", "customPlates", "seasonPass" }
local PRODUCT_KEYS =
	{ "credits5", "credits15", "credits40", "starterPack", "customSlot", "cash1", "cash2", "cash3", "cash4" }

type Config = Monetization.Monetization

-- Config/Monetization with every id filled in (the shipped one starts at 0 / "").
local function liveConfig(): Config
	local config: any = table.clone(Monetization)
	config.products = {}
	for index, key in Monetization.productOrder do
		config.products[key] = PRODUCT_ID_BASE + index
	end
	config.passes = {}
	for index, key in Monetization.passOrder do
		config.passes[key] = PASS_ID_BASE + index
	end
	config.subscriptions = { [Monetization.club.key] = CLUB_ID }
	return config
end

-- Config/Monetization with every id at 0 / "" (whatever ids Davis has pasted in since).
local function zeroConfig(): Config
	local config: any = table.clone(Monetization)
	config.products = {}
	for key in Monetization.products do
		config.products[key] = 0
	end
	config.passes = {}
	for key in Monetization.passes do
		config.passes[key] = 0
	end
	config.subscriptions = {}
	for key in Monetization.subscriptions do
		config.subscriptions[key] = ""
	end
	return config
end

type World = {
	player: Player,
	data: Types.PlayerData,
	loaded: boolean, -- the save has loaded (get / waitFor answer it)
	loadsOnWait: boolean, -- waitFor finishes loading the save (a store fetched while the save loads)
	updateWorks: boolean, -- DataService.update succeeds
	saves: boolean, -- DataService.saveConfirmed: the DataStore takes the save
	saveAsks: number, -- how many times a save was asked for
	passFailures: { [number]: number }, -- UserOwnsGamePassAsync errors this many more times for a pass id
	timers: { () -> () }, -- what was scheduled (pass retries), to run by hand
	studio: boolean,
	storeOn: boolean, -- the "store" feature flag
	now: number,
	eventShare: number, -- EventService.bonusCredits
	calls: { string }, -- every marketplace method called, in order
	prompts: { string }, -- "<method>:<id>" for every prompt
	owns: { [number]: boolean }, -- pass ids the player owns
	prices: { [number]: number }, -- PriceInRobux by product or pass id (nil: Roblox gives none)
	attributes: { [string]: any },
	sent: { any }, -- StoreUpdate payloads
	notes: { string }, -- Notify texts
	cashLogged: number, -- cash reported to EconomyService.recordChange
}

local function count(list: { string }, item: string): number
	local found = 0
	for _, entry in list do
		if entry == item then
			found += 1
		end
	end
	return found
end

-- A fresh world: one player with a brand-new save, MonetizationService pointed at fakes.
local function makeWorld(config: Config): World
	local fakePlayer: any = { UserId = USER_ID, Name = "SpecDriver" }
	local world: World = {
		player = fakePlayer :: Player,
		data = Template.new(NOW),
		loaded = true,
		loadsOnWait = false,
		updateWorks = true,
		saves = true,
		saveAsks = 0,
		passFailures = {},
		timers = {},
		studio = false,
		storeOn = true,
		now = NOW,
		eventShare = 0,
		calls = {},
		prompts = {},
		owns = {},
		prices = {},
		attributes = {},
		sent = {},
		notes = {},
		cashLogged = 0,
	}
	local market: any = {}
	local function record(name: string)
		table.insert(world.calls, name)
	end
	function market.UserOwnsGamePassAsync(_self: any, _userId: number, passId: number): boolean
		record("UserOwnsGamePassAsync")
		local failures = world.passFailures[passId] or 0
		if failures > 0 then
			world.passFailures[passId] = failures - 1
			error("Roblox couldn't be reached")
		end
		return world.owns[passId] == true
	end
	function market.PromptProductPurchase(_self: any, _player: any, id: number)
		record("PromptProductPurchase")
		table.insert(world.prompts, `PromptProductPurchase:{id}`)
	end
	function market.PromptGamePassPurchase(_self: any, _player: any, id: number)
		record("PromptGamePassPurchase")
		table.insert(world.prompts, `PromptGamePassPurchase:{id}`)
	end
	function market.PromptSubscriptionPurchase(_self: any, _player: any, id: string)
		record("PromptSubscriptionPurchase")
		table.insert(world.prompts, `PromptSubscriptionPurchase:{id}`)
	end
	function market.GetProductInfoAsync(_self: any, id: number, _infoType: any): any
		record("GetProductInfoAsync")
		return { PriceInRobux = world.prices[id] }
	end
	function market.GetProductInfo(_self: any, _id: number, _infoType: any): any
		record("GetProductInfo")
		return {}
	end
	function market.GetSubscriptionProductInfoAsync(_self: any, _id: string): any
		record("GetSubscriptionProductInfoAsync")
		return {}
	end
	function market.GetUserSubscriptionStatusAsync(_self: any, _player: any, _id: string): any
		record("GetUserSubscriptionStatusAsync")
		return { IsSubscribed = false, IsRenewing = false }
	end
	function market.GetUserSubscriptionPaymentHistoryAsync(_self: any, _player: any, _id: string): any
		record("GetUserSubscriptionPaymentHistoryAsync")
		return {}
	end
	local guids = 0
	MonetizationService.setDeps({
		marketplace = market,
		data = {
			get = function(_player: Player): Types.PlayerData?
				return if world.loaded then world.data else nil
			end,
			update = function(_player: Player, fn: (data: Types.PlayerData) -> ()): boolean
				if not world.loaded or not world.updateWorks then
					return false
				end
				fn(world.data)
				return true
			end,
			waitFor = function(_player: Player, _timeout: number?): Types.PlayerData?
				if world.loadsOnWait then
					world.loaded = true
				end
				return if world.loaded then world.data else nil
			end,
			-- The DataStore holds whatever the save holds, once it takes the save.
			saveConfirmed = function(_player: Player, check: (saved: any) -> boolean, _timeout: number): boolean
				world.saveAsks += 1
				return world.saves and check(world.data)
			end,
		},
		config = config,
		offers = Offers,
		clock = function(): number
			return world.now
		end,
		isStudio = function(): boolean
			return world.studio
		end,
		playerByUserId = function(userId: number): Player?
			return if userId == USER_ID then world.player else nil
		end,
		setAttribute = function(_player: Player, name: string, value: any)
			world.attributes[name] = value
		end,
		sendStore = function(_player: Player, payload: any)
			table.insert(world.sent, payload)
		end,
		notify = function(_player: Player, text: string)
			table.insert(world.notes, text)
		end,
		push = function(_player: Player) end,
		recordCash = function(_player: Player, amount: number, _reason: string)
			world.cashLogged += amount
		end,
		eventBonus = function(_now: number): number
			return world.eventShare
		end,
		schedule = function(_seconds: number, fn: () -> ()): thread?
			table.insert(world.timers, fn)
			return nil
		end,
		cancel = function(_thread: thread) end,
		spawn = function(fn: () -> ())
			fn()
		end,
		guid = function(): string
			guids += 1
			return `guid-{guids}`
		end,
		limitedIds = function(): { [string]: number }
			return {}
		end,
		flagOn = function(_name: string): boolean
			return world.storeOn
		end,
	})
	return world
end

local function receipt(config: Config, key: string, purchaseId: string, userId: number?): { [string]: any }
	return {
		PurchaseId = purchaseId,
		PlayerId = userId or USER_ID,
		ProductId = config.products[key],
		CurrencySpent = 0,
	}
end

local function productEntry(store: any, key: string): any
	for _, entry in store.products do
		if entry.key == key then
			return entry
		end
	end
	error(`no product {key} in the store payload`)
end

local function setFirstDesignDone(data: Types.PlayerData)
	data.credits.freeDesignUsed = true
	data.credits.reserved = {}
end

return function(t: Harness.Api)
	t.describe("Config/Monetization", function()
		t.it("has the pinned pass, product and subscription keys", function()
			for _, key in PASS_KEYS do
				t.expect(type(Monetization.passes[key])).toBe("number")
				t.expect(Monetization.passInfo[key] ~= nil).toBe(true)
				t.expect(table.find(Monetization.passOrder, key) ~= nil).toBe(true)
			end
			for _, key in PRODUCT_KEYS do
				t.expect(type(Monetization.products[key])).toBe("number")
				t.expect(Monetization.grants[key] ~= nil).toBe(true)
				t.expect(Monetization.productInfo[key] ~= nil).toBe(true)
				t.expect(table.find(Monetization.productOrder, key) ~= nil).toBe(true)
			end
			t.expect(type(Monetization.subscriptions.club)).toBe("string")
			t.expect(Monetization.club.key).toBe("club")
		end)

		t.it("holds only usable ids: whole numbers of at least 0 (0 = not created yet)", function()
			for _, ids in { Monetization.passes, Monetization.products } do
				for key, id in ids do
					local usable = type(id) == "number" and id >= 0 and id % 1 == 0
					t.expect(`{key}: {usable}`).toBe(`{key}: true`)
				end
			end
			for key, id in Monetization.subscriptions do
				t.expect(`{key}: {type(id)}`).toBe(`{key}: string`)
			end
		end)

		t.it("lists every product and pass in the store order exactly once", function()
			local seen: { [string]: number } = {}
			for _, key in Monetization.productOrder do
				seen[key] = (seen[key] or 0) + 1
				t.expect(Monetization.products[key] ~= nil).toBe(true)
			end
			for key in Monetization.products do
				t.expect(`{key}: {seen[key] or 0}`).toBe(`{key}: 1`)
			end
			local passSeen: { [string]: number } = {}
			for _, key in Monetization.passOrder do
				passSeen[key] = (passSeen[key] or 0) + 1
			end
			for key in Monetization.passes do
				t.expect(`{key}: {passSeen[key] or 0}`).toBe(`{key}: 1`)
				t.expect(#Monetization.passInfo[key].perks).toBeGreaterThan(0)
			end
		end)

		t.it("sells 5, 15 and 40 credit packs with bonus credits on the bigger packs", function()
			local grants = Monetization.grants
			t.expect(grants.credits5.credits).toBe(5)
			t.expect(grants.credits15.credits).toBe(15)
			t.expect(grants.credits40.credits).toBe(40)
			local small, middle, big =
				grants.credits5.bonus or 0, grants.credits15.bonus or 0, grants.credits40.bonus or 0
			t.expect(small).toBe(0)
			t.expect(middle).toBeGreaterThan(0)
			t.expect(big).toBeGreaterThan(middle)
			-- The bigger the pack, the bigger its bonus share.
			t.expect(big / 40).toBeGreaterThan(middle / 15)
		end)

		t.it("gives the Starter Pack and every cash pack something, and four cash packs that grow", function()
			local starter = Monetization.grants.starterPack
			t.expect((starter.credits or 0) > 0 and (starter.cash or 0) > 0).toBe(true)
			t.expect(starter.customSlots).toBe(1)
			local last = 0
			for _, key in { "cash1", "cash2", "cash3", "cash4" } do
				local cash = Monetization.grants[key].cash or 0
				t.expect(cash).toBeGreaterThan(last)
				t.expect(Monetization.productInfo[key].kind).toBe("cash")
				last = cash
			end
		end)

		t.it("tags a VIP's chat messages, and only a VIP's", function()
			local tag = Monetization.chatTags.vip
			t.expect(string.match(tag.colorHex, "^%x%x%x%x%x%x$") ~= nil).toBe(true)
			local vip = ChatTagController.prefixFor(true, "Driver:")
			t.expect(string.find(vip, tag.text, 1, true) ~= nil).toBe(true)
			t.expect(string.sub(vip, -#"Driver:")).toBe("Driver:")
			t.expect(ChatTagController.prefixFor(false, "Driver:")).toBe("Driver:")
		end)

		t.it("has offers that sell real products after known moments", function()
			for id, offer in Offers do
				t.expect(offer.id).toBe(id)
				t.expect(Monetization.products[offer.productKey] ~= nil).toBe(true)
				t.expect(#offer.showAfter).toBeGreaterThan(0)
				for _, moment in offer.showAfter do
					t.expect(moment == "firstDesign" or moment == "firstJobPayout").toBe(true)
				end
			end
			t.expect(Offers.starterPack.productKey).toBe("starterPack")
		end)
	end)

	t.describe("Receipts", function()
		t.it("grants a credit pack once when the same receipt arrives three times", function()
			local config = liveConfig()
			local world = makeWorld(config)
			local info = receipt(config, "credits15", "purchase-A")
			for _ = 1, 3 do
				t.expect(MonetizationService.processReceipt(table.clone(info))).toBe(GRANTED)
			end
			local grant = config.grants.credits15
			t.expect(world.data.credits.balance).toBe((grant.credits or 0) + (grant.bonus or 0))
			t.expect(count(world.data.receipts, "purchase-A")).toBe(1)
			t.expect(#world.notes).toBe(1)
		end)

		t.it("grants every built-in product once per receipt, with its PurchaseId saved in the same update", function()
			for _, key in PRODUCT_KEYS do
				local config = liveConfig()
				local world = makeWorld(config)
				local before = Template.new(NOW)
				local id = `purchase-{key}`
				for _ = 1, 3 do
					t.expect(MonetizationService.processReceipt(receipt(config, key, id))).toBe(GRANTED)
				end
				local grant = config.grants[key]
				local data = world.data
				t.expect(`{key} credits {data.credits.balance}`)
					.toBe(`{key} credits {before.credits.balance + MonetizationService.packCredits(grant, 0)}`)
				t.expect(`{key} cash {data.cash}`).toBe(`{key} cash {before.cash + (grant.cash or 0)}`)
				t.expect(`{key} slots {data.customSlots}`)
					.toBe(`{key} slots {before.customSlots + (grant.customSlots or 0)}`)
				t.expect(`{key} cash logged {world.cashLogged}`).toBe(`{key} cash logged {grant.cash or 0}`)
				for _, cosmetic in grant.cosmetics or {} do
					t.expect(data.cosmetics[cosmetic]).toBe(0)
				end
				t.expect(data.receipts).toEqual({ id })
			end
		end)

		t.it("grants nothing when the save can't be written, and grants once when Roblox retries", function()
			local config = liveConfig()
			local world = makeWorld(config)
			local info = receipt(config, "credits5", "purchase-B")
			world.updateWorks = false
			t.expect(MonetizationService.processReceipt(table.clone(info))).toBe(NOT_YET)
			t.expect(world.data.credits.balance).toBe(0)
			t.expect(world.data.receipts).toEqual({})
			world.updateWorks = true
			t.expect(MonetizationService.processReceipt(table.clone(info))).toBe(GRANTED)
			t.expect(MonetizationService.processReceipt(table.clone(info))).toBe(GRANTED)
			t.expect(world.data.credits.balance).toBe(5)
		end)

		t.it("answers PurchaseGranted only once the receipt is saved, granting once across retries", function()
			local config = liveConfig()
			local world = makeWorld(config)
			local info = receipt(config, "credits15", "purchase-saved")
			local packed = MonetizationService.packCredits(config.grants.credits15, 0)
			world.saves = false
			-- Granted in the save, but the DataStore hasn't taken it: Roblox must deliver it again.
			t.expect(MonetizationService.processReceipt(table.clone(info))).toBe(NOT_YET)
			t.expect(world.data.credits.balance).toBe(packed)
			t.expect(world.data.receipts).toEqual({ "purchase-saved" })
			-- The redelivery grants nothing more and still waits for the save.
			t.expect(MonetizationService.processReceipt(table.clone(info))).toBe(NOT_YET)
			t.expect(world.data.credits.balance).toBe(packed)
			world.saves = true
			t.expect(MonetizationService.processReceipt(table.clone(info))).toBe(GRANTED)
			t.expect(world.data.credits.balance).toBe(packed)
			t.expect(world.saveAsks).toBe(3)

			-- A registered product's receipt waits for the save too.
			MonetizationService.registerProduct("specSaved", function(_player: Player, _info: any): boolean
				return true
			end, { productId = REGISTERED_ID + 2 })
			world.saves = false
			local registeredInfo = { PurchaseId = "reg-saved", PlayerId = USER_ID, ProductId = REGISTERED_ID + 2 }
			t.expect(MonetizationService.processReceipt(table.clone(registeredInfo))).toBe(NOT_YET)
			world.saves = true
			t.expect(MonetizationService.processReceipt(table.clone(registeredInfo))).toBe(GRANTED)
		end)

		t.it("answers NotProcessedYet while the buyer's save isn't loaded, then grants once", function()
			local config = liveConfig()
			local world = makeWorld(config)
			local info = receipt(config, "credits40", "purchase-C")
			world.loaded = false
			t.expect(MonetizationService.processReceipt(table.clone(info))).toBe(NOT_YET)
			t.expect(world.data.credits.balance).toBe(0)
			world.loaded = true
			t.expect(MonetizationService.processReceipt(table.clone(info))).toBe(GRANTED)
			t.expect(MonetizationService.processReceipt(table.clone(info))).toBe(GRANTED)
			t.expect(world.data.credits.balance).toBe(MonetizationService.packCredits(config.grants.credits40, 0))
		end)

		t.it("answers NotProcessedYet for a buyer who isn't in this server or a product it doesn't sell", function()
			local config = liveConfig()
			local world = makeWorld(config)
			t.expect(MonetizationService.processReceipt(receipt(config, "credits5", "p-away", STRANGER_ID)))
				.toBe(NOT_YET)
			local unknown = receipt(config, "credits5", "p-unknown")
			unknown.ProductId = UNKNOWN_PRODUCT_ID
			t.expect(MonetizationService.processReceipt(unknown)).toBe(NOT_YET)
			local noId = receipt(config, "credits5", "")
			t.expect(MonetizationService.processReceipt(noId)).toBe(NOT_YET)
			t.expect(world.data.credits.balance).toBe(0)
			t.expect(world.data.receipts).toEqual({})
		end)

		t.it("keeps only the newest receipts", function()
			local config = liveConfig()
			local world = makeWorld(config)
			local total = Data.maxReceipts + 5
			for index = 1, total do
				t.expect(MonetizationService.processReceipt(receipt(config, "credits5", `r-{index}`))).toBe(GRANTED)
			end
			local receipts = world.data.receipts
			t.expect(#receipts).toBe(Data.maxReceipts)
			t.expect(receipts[1]).toBe("r-6")
			t.expect(receipts[#receipts]).toBe(`r-{total}`)
			t.expect(world.data.credits.balance).toBe(5 * total)

			local list = { "a", "b" }
			MonetizationService.Receipts.record(list, "c", 2)
			t.expect(list).toEqual({ "b", "c" })
			t.expect(MonetizationService.Receipts.has(list, "a")).toBe(false)
			t.expect(MonetizationService.Receipts.has(list, "c")).toBe(true)
		end)

		t.it("repairs a damaged receipt list instead of failing", function()
			local config = liveConfig()
			local world = makeWorld(config)
			local data: any = world.data
			data.receipts = "broken"
			t.expect(MonetizationService.processReceipt(receipt(config, "credits5", "p-fix"))).toBe(GRANTED)
			t.expect(world.data.receipts).toEqual({ "p-fix" })
		end)

		t.it("hands a registered product to its handler once per receipt, and retries when it says no", function()
			local config = liveConfig()
			local world = makeWorld(config)
			local handled = 0
			MonetizationService.registerProduct("specCosmetic", function(_player: Player, _info: any): boolean
				handled += 1
				return true
			end, { productId = REGISTERED_ID })
			local info = { PurchaseId = "reg-1", PlayerId = USER_ID, ProductId = REGISTERED_ID }
			for _ = 1, 3 do
				t.expect(MonetizationService.processReceipt(table.clone(info))).toBe(GRANTED)
			end
			t.expect(handled).toBe(1)
			t.expect(world.data.receipts).toEqual({ "reg-1" })

			local refusals = 0
			MonetizationService.registerProduct("specRefused", function(_player: Player, _info: any): boolean
				refusals += 1
				return false
			end, { productId = REGISTERED_ID + 1 })
			local refused = { PurchaseId = "reg-2", PlayerId = USER_ID, ProductId = REGISTERED_ID + 1 }
			t.expect(MonetizationService.processReceipt(table.clone(refused))).toBe(NOT_YET)
			t.expect(MonetizationService.processReceipt(table.clone(refused))).toBe(NOT_YET)
			t.expect(refusals).toBe(2)
			t.expect(world.data.receipts).toEqual({ "reg-1" })
		end)
	end)

	t.describe("Credit pack bonus", function()
		t.it("gives each pack its credits plus its bonus", function()
			for _, key in { "credits5", "credits15", "credits40" } do
				local config = liveConfig()
				local world = makeWorld(config)
				MonetizationService.processReceipt(receipt(config, key, `bonus-{key}`))
				local grant = config.grants[key]
				t.expect(world.data.credits.balance).toBe((grant.credits or 0) + (grant.bonus or 0))
			end
			t.expect(MonetizationService.packCredits({ credits = 15, bonus = 3 }, 0)).toBe(18)
			t.expect(MonetizationService.packCredits({ credits = 5 }, nil)).toBe(5)
		end)

		t.it("adds a running event's share of the pack's credits, rounded down", function()
			local config = liveConfig()
			local world = makeWorld(config)
			world.eventShare = 0.5
			MonetizationService.processReceipt(receipt(config, "credits15", "event-1"))
			local grant = config.grants.credits15
			local base = grant.credits or 0
			t.expect(world.data.credits.balance).toBe(base + (grant.bonus or 0) + math.floor(base * 0.5))
		end)

		t.it("caps the event share and ignores values that make no sense", function()
			local grant = { credits = 15, bonus = 3 }
			t.expect(MonetizationService.packCredits(grant, 10)).toBe(15 + 3 + 15) -- at most doubles the credits
			t.expect(MonetizationService.packCredits(grant, -1)).toBe(18)
			t.expect(MonetizationService.packCredits(grant, 0 / 0)).toBe(18)
		end)

		t.it("gives the event bonus on credit packs only", function()
			local config = liveConfig()
			local world = makeWorld(config)
			world.eventShare = 0.5
			MonetizationService.processReceipt(receipt(config, "starterPack", "event-starter"))
			t.expect(world.data.credits.balance).toBe(config.grants.starterPack.credits)
		end)
	end)

	t.describe("Ids of 0", function()
		t.it("prompt nothing, ask Roblox nothing and say coming soon", function()
			local config = zeroConfig()
			local world = makeWorld(config)
			MonetizationService.onJoin(world.player)
			for key in config.products do
				local answer = MonetizationService.buyProduct(world.player, key)
				t.expect(answer.ok).toBe(false)
				t.expect(answer.comingSoon).toBe(true)
				t.expect(answer.message).toBe(config.messages.comingSoon)
			end
			for key in config.passes do
				local answer = MonetizationService.buyPass(world.player, key)
				t.expect(answer.comingSoon).toBe(true)
				t.expect(MonetizationService.hasPass(world.player, key)).toBe(false)
				t.expect(MonetizationService.passCreated(key)).toBe(false)
			end
			t.expect(MonetizationService.joinClub(world.player).comingSoon).toBe(true)
			t.expect(MonetizationService.isClubMember(world.player)).toBe(false)
			t.expect(world.calls).toEqual({})
			t.expect(world.prompts).toEqual({})
		end)

		t.it("never match a receipt, so nothing is granted", function()
			local config = zeroConfig()
			local world = makeWorld(config)
			for _, key in PRODUCT_KEYS do
				t.expect(MonetizationService.processReceipt(receipt(config, key, `zero-{key}`))).toBe(NOT_YET)
			end
			t.expect(world.data.credits.balance).toBe(0)
			t.expect(world.data.cash).toBe(Economy.startingCash)
			t.expect(world.data.customSlots).toBe(Economy.customSlots)
			t.expect(world.data.receipts).toEqual({})
			t.expect(world.data.offersSeen).toEqual({})
		end)

		t.it("show every item as coming soon with no price, and no offer", function()
			local config = zeroConfig()
			local world = makeWorld(config)
			setFirstDesignDone(world.data)
			MonetizationService.onJoin(world.player)
			local store = MonetizationService.storeSnapshot(world.player)
			t.expect(#store.products).toBe(#config.productOrder)
			for _, entry in store.products do
				t.expect(entry.available).toBe(false)
				t.expect(entry.canBuy).toBe(false)
				t.expect(entry.price).toBe(nil)
				t.expect(entry.note).toBe(config.messages.comingSoon)
			end
			for _, entry in store.passes do
				t.expect(entry.available).toBe(false)
				t.expect(entry.owned).toBe(false)
				t.expect(entry.price).toBe(nil)
			end
			t.expect(store.club.available).toBe(false)
			t.expect(store.club.member).toBe(false)
			for _, offer in store.offers do
				t.expect(offer.due).toBe(false)
			end
			t.expect(world.calls).toEqual({})
		end)
	end)

	t.describe("Exclusive looks", function()
		t.it("exist in the Wrap & Tint shop for everything that grants one", function()
			local missing: { string } = {}
			local function check(where: string, lookId: any)
				if type(lookId) ~= "string" or not Customization.lookExists(lookId) then
					table.insert(missing, `{where}: {tostring(lookId)}`)
				end
			end
			for key, grant in Monetization.grants do
				for _, lookId in grant.cosmetics or {} do
					check(`grants.{key}`, lookId)
				end
			end
			for _, lookId in Monetization.club.cosmetics do
				check("club.cosmetics", lookId)
			end
			for index, tier in Season.tiers do
				for _, reward in { tier.free, tier.premium } do
					if reward ~= nil and reward.kind ~= "cash" and reward.kind ~= "credits" then
						check(`Season tier {index}`, reward.ref)
					end
				end
			end
			-- A limited cosmetic may wait for its look (plate frames aren't built yet) only while its product isn't
			-- created: one with a product id must sell a look that exists.
			for id, cosmetic in Limiteds.cosmetics do
				if cosmetic.productId > 0 then
					check(`Limiteds.{id}`, cosmetic.ref)
				end
			end
			t.expect(missing).toEqual({})
		end)

		t.it("are never sold before the shop has them, whatever the product's id", function()
			local config: any = liveConfig()
			config.grants = table.clone(Monetization.grants)
			config.grants.starterPack = { credits = 5, cosmetics = { "no_such_look" } }
			local world = makeWorld(config)
			setFirstDesignDone(world.data)
			MonetizationService.onJoin(world.player)
			t.expect(MonetizationService.productReady("starterPack")).toBe(false)
			t.expect(MonetizationService.productReady("credits5")).toBe(true)
			local answer = MonetizationService.buyProduct(world.player, "starterPack")
			t.expect(answer.ok).toBe(false)
			t.expect(answer.comingSoon).toBe(true)
			t.expect(world.prompts).toEqual({})
			local store = MonetizationService.storeSnapshot(world.player)
			local entry = productEntry(store, "starterPack")
			t.expect(entry.available).toBe(false)
			t.expect(entry.canBuy).toBe(false)
			t.expect(entry.note).toBe(config.messages.comingSoon)
			t.expect(store.offers[1].due).toBe(false)
		end)
	end)

	t.describe("Store words and launch day", function()
		t.it("says Light Show Pro's routines are lights and doors only while any of them has no music", function()
			local names: { string } = {}
			local silent = false
			for _, id in LightShows.routineOrder do
				local routine = LightShows.routines[id]
				if routine ~= nil and routine.pro then
					table.insert(names, routine.displayName)
					local track = Audio.tracks[routine.trackId]
					silent = silent or track == nil or track.assetId == 0
				end
			end
			t.expect(#names).toBeGreaterThan(0)
			local perks = Monetization.passInfo[LightShows.proPass].perks
			local text = table.concat(perks, " / ")
			for _, name in names do
				t.expect(`{name} named: {string.find(text, name, 1, true) ~= nil}`).toBe(`{name} named: true`)
			end
			local says = string.find(string.lower(text), "no music", 1, true) ~= nil
			t.expect(says).toBe(silent)
			-- Nothing on the card promises music or a boombox.
			t.expect(string.find(string.lower(text), "boombox", 1, true)).toBe(nil)
			t.expect(string.find(string.lower(text), "with music", 1, true)).toBe(nil)
		end)

		t.it("names the club's look and counts the Season Pass's looks", function()
			local look = Monetization.club.cosmetics[1]
			local blurb = Customization.lookBlurb(look)
			t.expect(blurb ~= nil).toBe(true)
			local clubText = table.concat(Monetization.club.perks, " / ")
			t.expect(string.find(clubText, blurb :: string, 1, true) ~= nil).toBe(true)
			local looks = 0
			for _, tier in Season.tiers do
				local reward = tier.premium
				if reward ~= nil and reward.kind ~= "cash" and reward.kind ~= "credits" then
					looks += 1
				end
			end
			local seasonText = table.concat(Monetization.passInfo[Season.passKey].perks, " / ")
			t.expect(string.find(seasonText, `{looks} exclusive car looks`, 1, true) ~= nil).toBe(true)
		end)

		t.it("opens the season, the launch-week limited and the Arc Flight drop on one launch day", function()
			t.expect(Season.launchAtUtc).toBe(Limiteds.launchAtUtc)
			t.expect(Events.launchAtUtc).toBe(Season.launchAtUtc)
			t.expect(Season.startsAtUtc).toBe(Season.launchAtUtc)
			t.expect(Limiteds.drops.arc_flight_1.startsAtUtc).toBe(Limiteds.launchAtUtc)
			t.expect(Limiteds.cosmetics.launch_wrap.startsAtUtc).toBe(Limiteds.launchAtUtc)
			t.expect(Limiteds.cosmetics.launch_wrap.endsAtUtc).toBe(Limiteds.launchAtUtc + 7 * 24 * 60 * 60)
			t.expect(Limiteds.cosmetics.launch_frame.startsAtUtc).toBe(Limiteds.launchAtUtc)
			-- The Arc Flight weekend opens with the drop.
			local opening: Events.Event? = nil
			for _, event in Events.schedule do
				if event.id == "arc_flight_weekend" then
					opening = event
				end
			end
			t.expect((opening :: Events.Event).startsAtUtc).toBe(Limiteds.drops.arc_flight_1.startsAtUtc)
		end)
	end)

	t.describe("DevPurchase", function()
		t.it("is refused outside Studio and grants nothing", function()
			local config = liveConfig()
			local world = makeWorld(config)
			MonetizationService.onJoin(world.player)
			local answer = MonetizationService.devPurchase(world.player, { key = "credits5" })
			t.expect(answer.ok).toBe(false)
			t.expect(answer.message).toBe(config.messages.devOnly)
			t.expect(MonetizationService.devPurchase(world.player, { key = "vip" }).ok).toBe(false)
			t.expect(MonetizationService.hasPassCached(world.player, "vip")).toBe(false)
			t.expect(world.data.credits.balance).toBe(0)
			t.expect(world.data.receipts).toEqual({})
		end)

		t.it("runs the real receipt path in Studio, once per purchaseId, before the product exists", function()
			local config = zeroConfig()
			local world = makeWorld(config)
			world.studio = true
			MonetizationService.onJoin(world.player)
			for _ = 1, 3 do
				t.expect(MonetizationService.devPurchase(world.player, { key = "credits15", purchaseId = "dev-1" }).ok)
					.toBe(true)
			end
			t.expect(world.data.credits.balance).toBe(MonetizationService.packCredits(config.grants.credits15, 0))
			t.expect(world.data.receipts).toEqual({ "dev-1" })
			-- Without a purchaseId each call is a new purchase.
			MonetizationService.devPurchase(world.player, { key = "credits5" })
			t.expect(#world.data.receipts).toBe(2)
			t.expect(world.calls).toEqual({})
		end)

		t.it("gives a pass for the session in Studio, with its perks", function()
			local config = zeroConfig()
			local world = makeWorld(config)
			world.studio = true
			MonetizationService.onJoin(world.player)
			t.expect(MonetizationService.devPurchase(world.player, { key = "garagePlus" }).ok).toBe(true)
			t.expect(MonetizationService.hasPass(world.player, "garagePlus")).toBe(true)
			local slots = config.passSlots.garagePlus
			t.expect(world.attributes[config.attributes.garageBonus]).toBe(slots.garageSlots)
			t.expect(world.attributes[config.attributes.customBonus]).toBe(slots.customSlots)
			t.expect(MonetizationService.devPurchase(world.player, { key = "nope" }).ok).toBe(false)
			t.expect(world.calls).toEqual({})
		end)
	end)

	t.describe("Starter Pack", function()
		t.it("isn't offered before its moments", function()
			local config = liveConfig()
			local world = makeWorld(config)
			MonetizationService.onJoin(world.player)
			t.expect(MonetizationService.offerVisible(world.data, Offers.starterPack)).toBe(false)
			local store = MonetizationService.storeSnapshot(world.player)
			t.expect(store.offers).toEqual({
				{ id = "starterPack", productKey = "starterPack", shown = false, due = false },
			})
		end)

		t.it("is offered after the first free design and after the first job payout", function()
			local design = Template.new(NOW)
			setFirstDesignDone(design)
			t.expect(MonetizationService.offerVisible(design, Offers.starterPack)).toBe(true)

			local built = Template.new(NOW)
			built.designs = { { uid = "d-1", spec = {}, createdAt = NOW, hidden = false } }
			t.expect(MonetizationService.offerVisible(built, Offers.starterPack)).toBe(true)

			local job = Template.new(NOW)
			job.jobs.xp.rideshare = 25
			t.expect(MonetizationService.offerVisible(job, Offers.starterPack)).toBe(true)

			-- Not while the free design is still being made (a failed request gives it back).
			local pending = Template.new(NOW)
			pending.credits.freeDesignUsed = true
			pending.credits.reserved = { { id = "free:req-1", amount = 0, at = NOW } }
			t.expect(MonetizationService.offerVisible(pending, Offers.starterPack)).toBe(false)
		end)

		t.it("can be bought once, and is never offered or sold again", function()
			local config = liveConfig()
			local world = makeWorld(config)
			setFirstDesignDone(world.data)
			MonetizationService.onJoin(world.player)
			local before = MonetizationService.storeSnapshot(world.player)
			t.expect(before.offers[1].due).toBe(true)
			t.expect(before.offers[1].shown).toBe(false)
			t.expect(productEntry(before, "starterPack").canBuy).toBe(true)
			t.expect(MonetizationService.buyProduct(world.player, "starterPack").ok).toBe(true)

			local info = receipt(config, "starterPack", "starter-1")
			t.expect(MonetizationService.processReceipt(table.clone(info))).toBe(GRANTED)
			local grant = config.grants.starterPack
			t.expect(world.data.offersSeen.starterPack).toBe(true)
			t.expect(world.data.credits.balance).toBe(grant.credits)
			t.expect(world.data.cash).toBe(Economy.startingCash + (grant.cash or 0))
			t.expect(world.data.customSlots).toBe(Economy.customSlots + (grant.customSlots or 0))
			for _, cosmetic in grant.cosmetics or {} do
				t.expect(MonetizationService.ownsCosmetic(world.player, cosmetic)).toBe(true)
			end

			local prompts = #world.prompts
			local again = MonetizationService.buyProduct(world.player, "starterPack")
			t.expect(again.ok).toBe(false)
			t.expect(again.message).toBe(config.messages.starterBought)
			t.expect(#world.prompts).toBe(prompts)

			local after = MonetizationService.storeSnapshot(world.player)
			t.expect(after.offers[1].shown).toBe(true) -- taken: never shown again
			t.expect(after.offers[1].due).toBe(false)
			local entry = productEntry(after, "starterPack")
			t.expect(entry.owned).toBe(true)
			t.expect(entry.canBuy).toBe(false)

			t.expect(MonetizationService.processReceipt(table.clone(info))).toBe(GRANTED)
			t.expect(world.data.credits.balance).toBe(grant.credits)
			t.expect(world.data.customSlots).toBe(Economy.customSlots + (grant.customSlots or 0))
		end)

		t.it("tells the player's store once when the offer comes up, not on every join", function()
			local config = liveConfig()
			local world = makeWorld(config)
			MonetizationService.onJoin(world.player)
			MonetizationService.dataChanged(world.player, world.data) -- the join: nothing to show yet
			local sent = #world.sent
			setFirstDesignDone(world.data)
			MonetizationService.dataChanged(world.player, world.data)
			t.expect(#world.sent).toBe(sent + 1)
			local update = world.sent[#world.sent]
			t.expect(update.changed).toEqual({ kind = "offer", key = "starterPack" })
			MonetizationService.dataChanged(world.player, world.data)
			t.expect(#world.sent).toBe(sent + 1)

			-- A player who joins with the moment already behind them isn't pushed the offer again.
			MonetizationService.forget(world.player)
			MonetizationService.onJoin(world.player)
			local rejoined = #world.sent
			MonetizationService.dataChanged(world.player, world.data)
			t.expect(#world.sent).toBe(rejoined)
		end)

		t.it("comes up again at its other moment (the first job payout after the first design)", function()
			local config = liveConfig()
			local world = makeWorld(config)
			MonetizationService.onJoin(world.player)
			MonetizationService.dataChanged(world.player, world.data)
			setFirstDesignDone(world.data)
			MonetizationService.dataChanged(world.player, world.data)
			local afterDesign = #world.sent
			world.data.jobs.xp.rideshare = 25
			MonetizationService.dataChanged(world.player, world.data)
			t.expect(#world.sent).toBe(afterDesign + 1)
			t.expect(world.sent[#world.sent].changed).toEqual({ kind = "offer", key = "starterPack" })

			-- Never once it's bought.
			local bought = makeWorld(config)
			MonetizationService.onJoin(bought.player)
			MonetizationService.dataChanged(bought.player, bought.data)
			bought.data.offersSeen.starterPack = true
			setFirstDesignDone(bought.data)
			MonetizationService.dataChanged(bought.player, bought.data)
			for _, update in bought.sent do
				t.expect(update.changed == nil or update.changed.kind ~= "offer").toBe(true)
			end
		end)

		t.it("reaches the Store app's Credits page while it's due, and leaves it once bought", function()
			local config = liveConfig()
			local world = makeWorld(config)
			setFirstDesignDone(world.data)
			MonetizationService.onJoin(world.player)
			local due = StoreModel.normalize(MonetizationService.storeSnapshot(world.player))
			assert(due, "store")
			t.expect(#StoreModel.offerCards(due)).toBe(1)
			local offer, pack = StoreModel.dueOffer(due, nil)
			assert(offer and pack, "due offer")
			t.expect(pack.key).toBe("starterPack")

			t.expect(MonetizationService.processReceipt(receipt(config, "starterPack", "starter-store"))).toBe(GRANTED)
			local after = StoreModel.normalize(MonetizationService.storeSnapshot(world.player))
			assert(after, "store")
			t.expect(#StoreModel.offerCards(after)).toBe(0)
			t.expect((StoreModel.dueOffer(after, nil))).toBe(nil)
			t.expect((StoreModel.dueOffer(after, "starterPack"))).toBe(nil)
		end)
	end)

	t.describe("Prompts", function()
		t.it("prompt a created product, and refuse unknown keys and unloaded saves without prompting", function()
			local config = liveConfig()
			local world = makeWorld(config)
			MonetizationService.onJoin(world.player)
			t.expect(MonetizationService.buyProduct(world.player, "credits5").ok).toBe(true)
			t.expect(world.prompts).toEqual({ `PromptProductPurchase:{config.products.credits5}` })
			t.expect(MonetizationService.buyProduct(world.player, "freeMoney").message).toBe(config.messages.unknown)
			world.loaded = false
			t.expect(MonetizationService.buyProduct(world.player, "credits5").message).toBe(config.messages.notLoaded)
			t.expect(#world.prompts).toBe(1)
		end)

		t.it("prompt nothing while the store is switched off", function()
			local config = liveConfig()
			local world = makeWorld(config)
			world.storeOn = false
			MonetizationService.onJoin(world.player)
			t.expect(MonetizationService.buyProduct(world.player, "credits5").message).toBe(config.messages.storeClosed)
			t.expect(MonetizationService.buyPass(world.player, "vip").message).toBe(config.messages.storeClosed)
			t.expect(MonetizationService.joinClub(world.player).message).toBe(config.messages.storeClosed)
			t.expect(world.prompts).toEqual({})
			local store = MonetizationService.storeSnapshot(world.player)
			t.expect(store.open).toBe(false)
			t.expect(productEntry(store, "credits5").canBuy).toBe(false)
		end)

		t.it("stop selling custom slots at the cap", function()
			local config = liveConfig()
			local world = makeWorld(config)
			world.data.customSlots = config.maxCustomSlots
			t.expect(MonetizationService.buyProduct(world.player, "customSlot").message).toBe(config.messages.slotsFull)
			t.expect(world.prompts).toEqual({})
		end)

		t.it("prompt a pass once, and not one the player already owns", function()
			local config = liveConfig()
			local world = makeWorld(config)
			world.owns[config.passes.vip] = true
			MonetizationService.onJoin(world.player)
			t.expect(MonetizationService.buyPass(world.player, "vip").message).toBe(config.messages.alreadyOwned)
			t.expect(MonetizationService.buyPass(world.player, "garagePlus").ok).toBe(true)
			t.expect(world.prompts).toEqual({ `PromptGamePassPurchase:{config.passes.garagePlus}` })
		end)
	end)

	t.describe("Passes", function()
		t.it("ask Roblox once per player and pass, then answer from the cache", function()
			local config = liveConfig()
			local world = makeWorld(config)
			world.owns[config.passes.vip] = true
			MonetizationService.onJoin(world.player)
			local asked = count(world.calls, "UserOwnsGamePassAsync")
			t.expect(asked).toBe(#PASS_KEYS)
			for _ = 1, 3 do
				t.expect(MonetizationService.hasPass(world.player, "vip")).toBe(true)
				t.expect(MonetizationService.hasPass(world.player, "customPlates")).toBe(false)
			end
			t.expect(MonetizationService.hasPassCached(world.player, "vip")).toBe(true)
			t.expect(count(world.calls, "UserOwnsGamePassAsync")).toBe(asked)
			t.expect(world.attributes[config.attributes.passPrefix .. "vip"]).toBe(true)

			-- A player who leaves is forgotten; a rejoin asks again.
			MonetizationService.forget(world.player)
			t.expect(MonetizationService.hasPassCached(world.player, "vip")).toBe(false)
			MonetizationService.onJoin(world.player)
			t.expect(count(world.calls, "UserOwnsGamePassAsync")).toBe(asked * 2)
		end)

		t.it("ask again later when Roblox errors on join, so an owner still gets the perks", function()
			local config = liveConfig()
			local world = makeWorld(config)
			local vip = config.passes.vip
			world.owns[vip] = true
			world.passFailures[vip] = 2
			MonetizationService.onJoin(world.player)
			t.expect(MonetizationService.hasPassCached(world.player, "vip")).toBe(false)
			-- Run the scheduled retries (each failure schedules one more, up to passRetries).
			local runs = 0
			while #world.timers > 0 and runs < config.passRetries do
				local fn = table.remove(world.timers, 1) :: () -> ()
				fn()
				runs += 1
			end
			t.expect(runs).toBe(2)
			t.expect(MonetizationService.hasPassCached(world.player, "vip")).toBe(true)
			t.expect(world.attributes[config.attributes.passPrefix .. "vip"]).toBe(true)

			-- It gives up after passRetries tries.
			local stubborn = makeWorld(config)
			stubborn.owns[vip] = true
			stubborn.passFailures[vip] = config.passRetries + 10
			MonetizationService.onJoin(stubborn.player)
			local tries = 0
			while #stubborn.timers > 0 and tries < config.passRetries + 5 do
				local fn = table.remove(stubborn.timers, 1) :: () -> ()
				fn()
				tries += 1
			end
			t.expect(tries).toBe(config.passRetries)
			t.expect(MonetizationService.hasPassCached(stubborn.player, "vip")).toBe(false)
		end)

		t.it("count a pass bought in game at once, with its slots and listeners", function()
			local config = liveConfig()
			local world = makeWorld(config)
			local heard: { boolean } = {}
			MonetizationService.onPassChanged("garagePlus", function(_player: Player, owned: boolean)
				table.insert(heard, owned)
			end)
			MonetizationService.onJoin(world.player)
			t.expect(heard).toEqual({ false })
			t.expect(world.attributes[config.attributes.garageBonus]).toBe(0)

			MonetizationService.passPurchaseFinished(world.player, config.passes.garagePlus, false)
			t.expect(MonetizationService.hasPassCached(world.player, "garagePlus")).toBe(false)

			MonetizationService.passPurchaseFinished(world.player, config.passes.garagePlus, true)
			t.expect(MonetizationService.hasPassCached(world.player, "garagePlus")).toBe(true)
			t.expect(heard).toEqual({ false, true })
			local slots = config.passSlots.garagePlus
			local garage, custom = MonetizationService.slotBonus(world.player)
			t.expect(garage).toBe(slots.garageSlots)
			t.expect(custom).toBe(slots.customSlots)
			t.expect(world.attributes[config.attributes.garageBonus]).toBe(slots.garageSlots)
			t.expect(world.attributes[config.attributes.customBonus]).toBe(slots.customSlots)
			t.expect(world.sent[#world.sent].changed).toEqual({ kind = "pass", key = "garagePlus" })
		end)
	end)

	t.describe("Store", function()
		t.it("lists products and passes in store order with MarketplaceService prices, cached", function()
			local config = liveConfig()
			local world = makeWorld(config)
			local price = 7 -- what the fake marketplace says; the game never writes a price itself
			world.prices[config.products.credits5] = price
			MonetizationService.onJoin(world.player)
			local store = MonetizationService.storeSnapshot(world.player)
			for index, key in config.productOrder do
				local entry = store.products[index]
				t.expect(entry.key).toBe(key)
				t.expect(entry.name).toBe(config.productInfo[key].name)
				t.expect(entry.kind).toBe(config.productInfo[key].kind)
				t.expect(entry.available).toBe(true)
				t.expect(entry.grants.credits).toBe(config.grants[key].credits)
			end
			t.expect(productEntry(store, "credits5").price).toBe(price)
			t.expect(productEntry(store, "credits15").price).toBe(nil)
			for index, key in config.passOrder do
				t.expect(store.passes[index].key).toBe(key)
				t.expect(store.passes[index].perks).toEqual(config.passInfo[key].perks)
			end
			t.expect(store.club.available).toBe(true)
			t.expect(store.club.monthlyCredits).toBe(config.club.monthlyCredits)
			t.expect(store.credits).toBe(0)

			local lookups = count(world.calls, "GetProductInfoAsync")
			t.expect(lookups).toBe(#config.productOrder + #config.passOrder)
			MonetizationService.storeSnapshot(world.player)
			t.expect(count(world.calls, "GetProductInfoAsync")).toBe(lookups)
			world.now += config.priceCacheSeconds
			MonetizationService.storeSnapshot(world.player)
			t.expect(count(world.calls, "GetProductInfoAsync")).toBe(lookups * 2)
		end)

		t.it("waits for a save that is still loading, so the first store can be bought from", function()
			local config = liveConfig()
			local world = makeWorld(config)
			world.loaded = false
			world.loadsOnWait = true
			MonetizationService.onJoin(world.player)
			local store = MonetizationService.storeSnapshot(world.player)
			t.expect(productEntry(store, "credits5").canBuy).toBe(true)
			t.expect(productEntry(store, "starterPack").owned).toBe(false)
		end)

		t.it("sends the fresh store after a purchase", function()
			local config = liveConfig()
			local world = makeWorld(config)
			MonetizationService.onJoin(world.player)
			MonetizationService.processReceipt(receipt(config, "cash1", "store-1"))
			local update = world.sent[#world.sent]
			t.expect(update.changed).toEqual({ kind = "product", key = "cash1" })
			t.expect(#update.products).toBe(#config.productOrder)
		end)
	end)

	t.describe("Schema 7", function()
		t.it("is at schema version 7 or later, with a 6 -> 7 step", function()
			t.expect(Data.schemaVersion >= 7).toBe(true)
			t.expect(type(Migrations.steps[6])).toBe("function")
			t.expect(Template.new(NOW).cosmetics).toEqual({})
		end)

		t.it(
			"gives a version 6 save an empty cosmetics table and keeps everything else (version 7 or later)",
			function()
				local save: any = Template.new(NOW)
				save.version = 6
				save.cosmetics = nil
				save.receipts = { "p-1" }
				save.offersSeen = { starterPack = true }
				save.club = { lastGrantMonth = "2026-09" }
				local migrated, fromVersion = Migrations.run(save)
				t.expect(fromVersion).toBe(6)
				t.expect(migrated.version).toBe(Data.schemaVersion)
				t.expect(migrated.cosmetics).toEqual({})
				t.expect(migrated.receipts).toEqual({ "p-1" })
				t.expect(migrated.offersSeen).toEqual({ starterPack = true })
				t.expect(migrated.club).toEqual({ lastGrantMonth = "2026-09" })
			end
		)

		t.it("keeps usable cosmetics and drops what can't be one", function()
			local save: any = Template.new(NOW)
			save.version = 6
			save.cosmetics = { kept = 3, unnumbered = 0, negative = -1, fraction = 1.5, word = "x", nan = 0 / 0 }
			t.expect(Migrations.run(save).cosmetics).toEqual({ kept = 3, unnumbered = 0 })

			local broken: any = Template.new(NOW)
			broken.version = 6
			broken.cosmetics = "oops"
			t.expect(Migrations.run(broken).cosmetics).toEqual({})
		end)

		t.it("brings older saves up to version 7 or later with cosmetics", function()
			local old: any = Template.new(NOW)
			old.version = 5
			old.cosmetics = nil
			local migrated = Migrations.run(old)
			t.expect(migrated.version).toBe(Data.schemaVersion)
			t.expect(migrated.cosmetics).toEqual({})
		end)
	end)

	t.describe("Clean-up", function()
		t.it("puts the real dependencies back", function()
			MonetizationService.resetDeps()
			t.expect(MonetizationService.passCreated("no-such-pass")).toBe(false)
		end)
	end)
end
