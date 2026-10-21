--!strict
-- Ads and analytics, the pure parts (PLAN.md Phase 12 "Highway billboards", "Rewarded video ads" and "Analytics";
-- docs/phase-12-contracts.md "Ads, analytics, admin"):
--   * Config/Ads: a readable poster (4.5:1 text) for every brand, sane ad limits, the reward product a placeholder.
--   * Config/MapLayout billboards: unique, real brands and zones, every ad face inside Roblox's limits, and the
--     county plan (Dev/MapBuilder) builds each one as a tagged panel with its AdGui, its poster and two posts.
--   * Services/AdsService decisions: the UTC day, the billboard mode, the offer checks, and the reward receipt flow
--     against a fake row store: one credit per UTC day, a redelivered receipt never pays twice, a failed grant hands
--     the day back and pays once on the retry, a store that can't be reached pays nothing.
--   * Services/AnalyticsService: the custom fields, the save comparison (onboarding steps, jobs, designer requests
--     and their outcomes, Design Credit sources and sinks, the club's months) and a purchase's events.
-- Pure: runs in Edit mode.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Ads = require(ReplicatedStorage.Shared.Config.Ads)
local Brands = require(ReplicatedStorage.Shared.Config.Brands)
local Harness = require(ReplicatedStorage.Shared.Testing.Harness)
local MapLayout = require(ReplicatedStorage.Shared.Config.MapLayout)
local World = require(ReplicatedStorage.Shared.Config.World)
local Services = ServerScriptService.Server.Services
local AdsService = require(Services.AdsService)
local AnalyticsService = require(Services.AnalyticsService)
local MapBuilder = require(ServerScriptService.Server.Dev.MapBuilder)

local DAY = 86400
local NOW = 1800000000 -- a fixed "now" (os.time() seconds, January 2027)
local CONTRAST_FLOOR = 4.5 -- body text on its background (CLAUDE.md / mobile-first UI rules)

local rewarded = Ads.rewardedVideo
local billboards = Ads.billboards

-- WCAG relative luminance and contrast ratio.
local function luminance(color: Color3): number
	local function channel(value: number): number
		return if value <= 0.03928 then value / 12.92 else ((value + 0.055) / 1.055) ^ 2.4
	end
	return 0.2126 * channel(color.R) + 0.7152 * channel(color.G) + 0.0722 * channel(color.B)
end

local function contrast(a: Color3, b: Color3): number
	local la, lb = luminance(a), luminance(b)
	return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05)
end

-- A fake row store: rows in a table; `down` makes every call fail like an unreachable DataStore.
type FakeStore = { rows: { [string]: any }, down: boolean, store: AdsService.Store }

local function fakeStore(): FakeStore
	local fake: FakeStore = { rows = {}, down = false, store = nil :: any }
	fake.store = {
		get = function(key: string): (boolean, any)
			if fake.down then
				return false, nil
			end
			return true, fake.rows[key]
		end,
		update = function(key: string, transform: (old: any) -> any): boolean
			if fake.down then
				return false
			end
			local value = transform(fake.rows[key])
			if value ~= nil then
				fake.rows[key] = value
			end
			return true
		end,
	}
	return fake
end

type Rig = {
	fake: FakeStore,
	deps: AdsService.Deps,
	credits: number,
	grantWorks: boolean,
	now: number,
	notices: { string },
}

local function newWorld(): Rig
	local world: Rig = {
		fake = fakeStore(),
		deps = nil :: any,
		credits = 0,
		grantWorks = true,
		now = NOW,
		notices = {},
	}
	world.deps = {
		store = world.fake.store,
		clock = function(): number
			return world.now
		end,
		grantCredits = function(_player: Player, amount: number, _reason: string): boolean
			if not world.grantWorks then
				return false
			end
			world.credits += amount
			return true
		end,
		notify = function(_player: Player, text: string)
			table.insert(world.notices, text)
		end,
		claimed = function(_player: Player, _day: number?) end,
	}
	return world
end

local PLAYER: Player = { UserId = 4242, Name = "SpecDriver" } :: any

local function adReceipt(purchaseId: string): { [string]: any }
	return { PurchaseId = purchaseId, PlayerId = PLAYER.UserId, ProductId = 1, CurrencySpent = 0 }
end

local function facts(overrides: { [string]: any }?): AnalyticsService.Facts
	local base = AnalyticsService.factsFrom({})
	for key, value in overrides or {} do
		(base :: any)[key] = value
	end
	return base
end

local function kinds(events: { AnalyticsService.Event }): string
	local list: { string } = {}
	for _, event in events do
		table.insert(list, event.kind)
	end
	return table.concat(list, ",")
end

local function find(events: { AnalyticsService.Event }, kind: string): AnalyticsService.Event?
	for _, event in events do
		if event.kind == kind then
			return event
		end
	end
	return nil
end

return function(t: Harness.Api)
	t.describe("Config/Ads", function()
		t.it("has a poster for every brand, readable on its own background", function()
			local problems: { string } = {}
			for brandId in Brands do
				local poster = billboards.posters[brandId]
				if poster == nil then
					table.insert(problems, `{brandId}: no poster`)
				else
					if contrast(poster.title, poster.background) < CONTRAST_FLOOR then
						table.insert(problems, `{brandId}: title contrast {contrast(poster.title, poster.background)}`)
					end
					if contrast(poster.text, poster.background) < CONTRAST_FLOOR then
						table.insert(problems, `{brandId}: tagline contrast {contrast(poster.text, poster.background)}`)
					end
					if poster.tagline == "" then
						table.insert(problems, `{brandId}: no tagline`)
					end
				end
			end
			for brandId in billboards.posters do
				if Brands[brandId] == nil then
					table.insert(problems, `{brandId}: a poster for a brand that doesn't exist`)
				end
			end
			t.expect(table.concat(problems, "; ")).toBe("")
		end)

		t.it("keeps Roblox's ad unit limits and the face rules straight", function()
			t.expect(billboards.minFace).toEqual(Vector2.new(8, 4.5))
			t.expect(billboards.maxFace).toEqual(Vector2.new(32, 18))
			t.expect(billboards.adFace ~= billboards.posterFace).toBe(true)
			t.expect(billboards.serveAds).toBe(false) -- posters until the game is eligible
		end)

		t.it("starts the reward product as a placeholder that pays one credit", function()
			t.expect(rewarded.productId).toBe(0)
			t.expect(rewarded.credits).toBe(1)
			t.expect(Ads.productIds()[rewarded.productKey]).toBe(0)
			for _, key in { "off", "comingSoon", "loading", "claimed", "busy", "notReady", "interrupted", "failed" } do
				t.expect(type(rewarded.messages[key])).toBe("string")
			end
		end)
	end)

	t.describe("Config/MapLayout billboards", function()
		t.it("are unique, on real brands and zones, inside the map and inside the ad limits", function()
			local problems: { string } = {}
			local seen: { [string]: boolean } = {}
			t.expect(#MapLayout.billboards).toBeGreaterThan(0)
			for _, board in MapLayout.billboards do
				if seen[board.id] then
					table.insert(problems, `{board.id}: listed twice`)
				end
				seen[board.id] = true
				if Brands[board.brandId] == nil then
					table.insert(problems, `{board.id}: unknown brand {board.brandId}`)
				end
				if MapLayout.zones[board.zone] == nil then
					table.insert(problems, `{board.id}: unknown zone {board.zone}`)
				end
				if not AdsService.faceFits(board.size.X, board.size.Y) then
					table.insert(problems, `{board.id}: face {board.size.X} x {board.size.Y} outside the limits`)
				end
				if board.clearance <= 0 or board.size.Z <= 0 or board.size.Z >= board.size.X then
					table.insert(problems, `{board.id}: odd clearance or thickness`)
				end
				local half = World.mapHalfExtent
				if math.abs(board.position.X) > half or math.abs(board.position.Z) > half then
					table.insert(problems, `{board.id}: outside the map`)
				end
			end
			t.expect(table.concat(problems, "; ")).toBe("")
		end)

		t.it("are built as tagged panels with an AdGui, the brand's poster and two posts", function()
			local plan = MapBuilder.county()
			local panels: { [string]: MapBuilder.PartSpec } = {}
			local posts = 0
			for _, spec in plan.specs do
				if spec.folder == "Billboards" then
					if spec.parent == nil then
						panels[spec.name] = spec
					else
						posts += 1
					end
				end
			end
			local problems: { string } = {}
			for _, board in MapLayout.billboards do
				local panel = panels[board.id]
				if panel == nil then
					table.insert(problems, `{board.id}: not built`)
					continue
				end
				local attributes: { [string]: any } = panel.attributes or {}
				local unit = panel.adUnit
				local labels = panel.labels or {}
				if panel.tag ~= billboards.tag or attributes[billboards.brandAttribute] ~= board.brandId then
					table.insert(problems, `{board.id}: tag or brand attribute wrong`)
				end
				if unit == nil or unit.face ~= billboards.adFace or unit.name ~= billboards.adUnitName then
					table.insert(problems, `{board.id}: no AdGui on the ad face`)
				end
				if #labels ~= 2 or labels[1].face ~= billboards.posterFace then
					table.insert(problems, `{board.id}: no poster on the back`)
				elseif labels[1].text ~= Brands[board.brandId].displayName then
					table.insert(problems, `{board.id}: the poster doesn't name its brand`)
				end
				if (panel.size - board.size).Magnitude > 1e-3 then
					table.insert(problems, `{board.id}: built at {panel.size}`)
				end
				local bottom = panel.cframe.Position.Y - board.size.Y / 2
				if math.abs(bottom - (board.position.Y + board.clearance)) > 1e-3 then
					table.insert(problems, `{board.id}: panel bottom at {bottom}`)
				end
			end
			t.expect(table.concat(problems, "; ")).toBe("")
			t.expect(posts).toBe(2 * #MapLayout.billboards)
			for _, text in plan.notes do
				t.expect(string.find(text, "billboard", 1, true)).toBe(nil)
			end
		end)
	end)

	t.describe("AdsService decisions", function()
		t.it("counts UTC days from midnight", function()
			t.expect(AdsService.utcDay(0)).toBe(0)
			t.expect(AdsService.utcDay(DAY - 1)).toBe(0)
			t.expect(AdsService.utcDay(DAY)).toBe(1)
			t.expect(AdsService.utcDay(NOW)).toBe(math.floor(NOW / DAY))
		end)

		t.it("serves ads on a billboard only when switched on, flagged on and fitted with its AdGui", function()
			t.expect(AdsService.billboardMode(true, true, true, true)).toBe("ad")
			t.expect(AdsService.billboardMode(false, true, true, true)).toBe("poster")
			t.expect(AdsService.billboardMode(true, false, true, true)).toBe("poster")
			t.expect(AdsService.billboardMode(true, true, false, true)).toBe("poster")
		end)

		t.it("keeps the poster up while the brand's poster image isn't uploaded (no Roblox default image)", function()
			t.expect(AdsService.billboardMode(true, true, true, false)).toBe("poster")
		end)

		t.it("checks the ad face against the limits, edges included", function()
			t.expect(AdsService.faceFits(8, 4.5)).toBe(true)
			t.expect(AdsService.faceFits(32, 18)).toBe(true)
			t.expect(AdsService.faceFits(7.9, 4.5)).toBe(false)
			t.expect(AdsService.faceFits(32, 18.1)).toBe(false)
		end)

		t.it("offers an ad only when the flag, the product, the save and today's credit all allow it", function()
			local ok: AdsService.WatchFacts =
				{ flagOn = true, productId = 123, loaded = true, claimedToday = false, showing = false }
			t.expect(select(2, AdsService.watchDecision(ok))).toBe("ok")
			local function why(change: { [string]: any }): string
				local changed = table.clone(ok) :: any
				for key, value in change do
					changed[key] = value
				end
				local _, code = AdsService.watchDecision(changed)
				return code
			end
			t.expect(why({ flagOn = false })).toBe("off")
			t.expect(why({ productId = 0 })).toBe("comingSoon")
			t.expect(why({ loaded = false })).toBe("loading")
			t.expect(why({ showing = true })).toBe("busy")
			t.expect(why({ claimedToday = true })).toBe("claimed")
			-- The flag is checked first: with it off nothing else is even looked at.
			t.expect(why({ flagOn = false, productId = 0, loaded = false })).toBe("off")
		end)

		t.it("reads stored rows defensively", function()
			t.expect(AdsService.cleanClaim(nil)).toBe(nil)
			t.expect(AdsService.cleanClaim("junk")).toBe(nil)
			t.expect(AdsService.cleanClaim({ day = 5 })).toBe(nil)
			t.expect(AdsService.cleanClaim({ day = 5.7, purchaseId = "a", granted = "yes" }))
				.toEqual({ day = 5, purchaseId = "a", granted = false })
			t.expect(AdsService.paidDay({ day = 5, purchaseId = "a", granted = true })).toBe(5)
			t.expect(AdsService.paidDay({ day = 5, purchaseId = "a", granted = false })).toBe(nil)
		end)

		t.it("decides each receipt: claim, already paid, or today's credit already used", function()
			local today = AdsService.utcDay(NOW)
			local paid = { day = today, purchaseId = "a", granted = true }
			t.expect(AdsService.claimDecision(nil, today, "a", true)).toBe("claim")
			t.expect(AdsService.claimDecision(paid, today, "a", true)).toBe("granted")
			t.expect(AdsService.claimDecision(paid, today + 3, "a", true)).toBe("granted")
			t.expect(AdsService.claimDecision(paid, today, "b", true)).toBe("used")
			t.expect(AdsService.claimDecision(paid, today + 1, "b", true)).toBe("claim")
			t.expect(AdsService.claimDecision(paid, today, "b", false)).toBe("claim") -- Robux spent: no daily limit
			local handedBack = { day = today, purchaseId = "a", granted = false }
			t.expect(AdsService.claimDecision(handedBack, today, "b", true)).toBe("claim")
			t.expect(AdsService.claimDecision(handedBack, today, "a", true)).toBe("claim")
		end)

		t.it("applies the daily limit to ads and free receipts, not to Robux spent", function()
			t.expect(AdsService.isLimitedReceipt({ CurrencySpent = 0 })).toBe(true)
			t.expect(AdsService.isLimitedReceipt({})).toBe(true)
			t.expect(AdsService.isLimitedReceipt({ CurrencySpent = 25 })).toBe(false)
			t.expect(AdsService.isLimitedReceipt({
				CurrencySpent = 25,
				ProductPurchaseChannel = Enum.ProductPurchaseChannel.AdReward,
			})).toBe(true)
		end)
	end)

	t.describe("AdsService.rewardReceipt (fake store)", function()
		t.it("pays one credit for the day's first ad and never again for the same receipt", function()
			local world = newWorld()
			t.expect(AdsService.rewardReceipt(world.deps, PLAYER, adReceipt("p1"))).toBe(true)
			t.expect(world.credits).toBe(rewarded.credits)
			for _ = 1, 3 do
				t.expect(AdsService.rewardReceipt(world.deps, PLAYER, adReceipt("p1"))).toBe(true)
			end
			t.expect(world.credits).toBe(rewarded.credits)
		end)

		t.it(
			"accepts a second ad's receipt on the same UTC day without a credit, and pays again the next day",
			function()
				local world = newWorld()
				AdsService.rewardReceipt(world.deps, PLAYER, adReceipt("p1"))
				t.expect(AdsService.rewardReceipt(world.deps, PLAYER, adReceipt("p2"))).toBe(true)
				t.expect(world.credits).toBe(rewarded.credits)
				t.expect(world.notices[#world.notices]).toBe(rewarded.messages.claimed)
				world.now = NOW + DAY
				t.expect(AdsService.rewardReceipt(world.deps, PLAYER, adReceipt("p3"))).toBe(true)
				t.expect(world.credits).toBe(2 * rewarded.credits)
			end
		)

		t.it("hands the day back when the grant fails, and pays exactly once on the retry", function()
			local world = newWorld()
			world.grantWorks = false
			t.expect(AdsService.rewardReceipt(world.deps, PLAYER, adReceipt("p1"))).toBe(false)
			t.expect(world.credits).toBe(0)
			local row = AdsService.cleanClaim(world.fake.rows[rewarded.keyPrefix .. tostring(PLAYER.UserId)])
			t.expect(row ~= nil and row.granted).toBe(false)
			world.grantWorks = true
			t.expect(AdsService.rewardReceipt(world.deps, PLAYER, adReceipt("p1"))).toBe(true)
			t.expect(AdsService.rewardReceipt(world.deps, PLAYER, adReceipt("p1"))).toBe(true)
			t.expect(world.credits).toBe(rewarded.credits)
		end)

		t.it("pays nothing and asks for a redelivery while the store can't be reached", function()
			local world = newWorld()
			world.fake.down = true
			t.expect(AdsService.rewardReceipt(world.deps, PLAYER, adReceipt("p1"))).toBe(false)
			t.expect(world.credits).toBe(0)
			world.fake.down = false
			t.expect(AdsService.rewardReceipt(world.deps, PLAYER, adReceipt("p1"))).toBe(true)
			t.expect(world.credits).toBe(rewarded.credits)
		end)

		t.it("pays a receipt with Robux spent even after today's ad, once", function()
			local world = newWorld()
			AdsService.rewardReceipt(world.deps, PLAYER, adReceipt("p1"))
			local paid = adReceipt("p2")
			paid.CurrencySpent = 10
			t.expect(AdsService.rewardReceipt(world.deps, PLAYER, paid)).toBe(true)
			t.expect(AdsService.rewardReceipt(world.deps, PLAYER, paid)).toBe(true)
			t.expect(world.credits).toBe(2 * rewarded.credits)
		end)

		t.it("refuses a receipt with no PurchaseId", function()
			local world = newWorld()
			t.expect(AdsService.rewardReceipt(world.deps, PLAYER, { PlayerId = PLAYER.UserId })).toBe(false)
			t.expect(world.credits).toBe(0)
		end)
	end)

	t.describe("AnalyticsService", function()
		t.it("keys custom fields the way Roblox reads them, at most three", function()
			local fields = AnalyticsService.fields({ "a", "b", "c", "d" })
			t.expect(fields[Enum.AnalyticsCustomFieldKeys.CustomField01.Name]).toBe("a")
			t.expect(fields[Enum.AnalyticsCustomFieldKeys.CustomField03.Name]).toBe("c")
			local count = 0
			for _ in fields do
				count += 1
			end
			t.expect(count).toBe(3)
		end)

		t.it("numbers the onboarding funnel join -> claim car -> first drive -> first job -> first purchase", function()
			local ids: { string } = {}
			for _, step in AnalyticsService.ONBOARDING do
				table.insert(ids, step.id)
			end
			t.expect(table.concat(ids, ",")).toBe("join,claimCar,firstDrive,firstJob,firstPurchase")
			t.expect(AnalyticsService.onboardingStep("firstJob")).toBe(4)
			t.expect(AnalyticsService.onboardingStep("nope")).toBe(nil)
		end)

		t.it("reads a save defensively", function()
			local read = AnalyticsService.factsFrom({
				starterClaimed = false,
				vehicles = { {} },
				jobs = { xp = { delivery = 120, towing = -5, freight = 0 / 0 } },
				receipts = { "r1", "r2" },
				credits = { balance = 7, freeDesignUsed = true, reserved = { { id = "x", amount = 2 }, "junk" } },
				designs = { { uid = "d1" }, { nope = true } },
				club = { lastGrantMonth = "2027-01" },
			})
			t.expect(read.hasCar).toBe(true)
			t.expect(read.totalXp).toBe(120)
			t.expect(read.jobXp.towing).toBe(0)
			t.expect(read.lastReceipt).toBe("r2")
			t.expect(read.balance).toBe(7)
			t.expect(read.reserved).toEqual({ x = 2 })
			t.expect(read.designs).toEqual({ d1 = true })
			t.expect(read.clubMonth).toBe("2027-01")
			t.expect(AnalyticsService.factsFrom(nil).hasCar).toBe(false)
		end)

		t.it("finds the first car, the first job and every job's XP", function()
			local events = AnalyticsService.diff(
				facts(),
				facts({ hasCar = true, jobXp = { delivery = 50, towing = 10 }, totalXp = 60 })
			)
			t.expect(kinds(events)).toBe("claimCar,firstJob,job,job")
			local job = find(events, "job") :: AnalyticsService.Event
			t.expect(job.jobType).toBe("delivery")
			t.expect(job.after).toBe(50)
			local again = AnalyticsService.diff(
				facts({ hasCar = true, jobXp = { delivery = 50 }, totalXp = 50 }),
				facts({ hasCar = true, jobXp = { delivery = 90 }, totalXp = 90 })
			)
			t.expect(kinds(again)).toBe("job")
		end)

		t.it("follows a paid design request from submit to built, with its credits as a sink", function()
			local start = facts({ balance = 10 })
			local reserved = facts({ balance = 8, reserved = { r1 = 2 } })
			local submit = AnalyticsService.diff(start, reserved)
			t.expect(kinds(submit)).toBe("submit")
			t.expect((find(submit, "submit") :: AnalyticsService.Event).free).toBe(false)
			local built = AnalyticsService.diff(reserved, facts({ balance = 8, designs = { d1 = true } }))
			t.expect(kinds(built)).toBe("result,sink")
			local result = find(built, "result") :: AnalyticsService.Event
			t.expect(result.outcome).toBe("built")
			t.expect(result.designUid).toBe("d1")
			local sink = find(built, "sink") :: AnalyticsService.Event
			t.expect(sink.amount).toBe(2)
			t.expect(sink.transaction).toBe(Enum.AnalyticsEconomyTransactionType.Shop.Name)
		end)

		t.it("sees a refund as an outcome, not as new credits", function()
			local reserved = facts({ balance = 8, reserved = { r1 = 2 } })
			local refunded = AnalyticsService.diff(reserved, facts({ balance = 10 }))
			t.expect(kinds(refunded)).toBe("result")
			t.expect((find(refunded, "result") :: AnalyticsService.Event).outcome).toBe("refunded")
			-- The free first car: nothing moves but the flag comes back.
			local free = facts({ freeUsed = true, reserved = { ["free:r2"] = 0 } })
			local freeBack = AnalyticsService.diff(free, facts({ freeUsed = false }))
			t.expect((find(freeBack, "result") :: AnalyticsService.Event).outcome).toBe("refunded")
			local freeSpent = AnalyticsService.diff(free, facts({ freeUsed = true }))
			t.expect((find(freeSpent, "result") :: AnalyticsService.Event).outcome).toBe("spent")
			t.expect(find(freeSpent, "sink")).toBe(nil)
		end)

		t.it("labels new credits by where they came from", function()
			local base = facts({ balance = 3, lastReceipt = "r1" })
			local bought = AnalyticsService.diff(base, facts({ balance = 18, lastReceipt = "r2" }))
			local source = find(bought, "source") :: AnalyticsService.Event
			t.expect(source.amount).toBe(15)
			t.expect(source.balance).toBe(18)
			t.expect(source.transaction).toBe(Enum.AnalyticsEconomyTransactionType.IAP.Name)
			local club = AnalyticsService.diff(base, facts({ balance = 13, lastReceipt = "r1", clubMonth = "2027-01" }))
			t.expect((find(club, "source") :: AnalyticsService.Event).transaction)
				.toBe(Enum.AnalyticsEconomyTransactionType.TimedReward.Name)
			t.expect((find(club, "club") :: AnalyticsService.Event).first).toBe(true)
			local reward = AnalyticsService.diff(base, facts({ balance = 4, lastReceipt = "r1" }))
			t.expect((find(reward, "source") :: AnalyticsService.Event).transaction)
				.toBe(Enum.AnalyticsEconomyTransactionType.Gameplay.Name)
			local renewal = AnalyticsService.diff(
				facts({ clubMonth = "2027-01", balance = 13 }),
				facts({ clubMonth = "2027-02", balance = 23 })
			)
			t.expect((find(renewal, "club") :: AnalyticsService.Event).first).toBe(false)
		end)

		t.it("logs a purchase, its pack, and the onboarding step once", function()
			local sent: { string } = {}
			AnalyticsService.setSender(function(method: string, _player: Player, ...: any)
				local first = ...
				table.insert(sent, `{method}:{tostring(first)}`)
			end)
			AnalyticsService.purchase(PLAYER, "credits15", "credits")
			AnalyticsService.purchase(PLAYER, "cash1", "cash")
			AnalyticsService.setSender(nil)
			t.expect(table.concat(sent, ","))
				.toBe(
					"LogCustomEvent:Purchase,LogCustomEvent:CreditPack,LogOnboardingFunnelStepEvent:5,LogCustomEvent:Purchase"
				)
		end)
	end)
end
