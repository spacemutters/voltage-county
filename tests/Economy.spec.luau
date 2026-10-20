--!strict
-- Cash math and earnings boosts (Services/EconomyService pure helpers: adding and spending, rounding down,
-- never below zero, refusing non-positive and non-finite amounts, the wallet cap, the boost multiplier with
-- expired boosts), the cash formatter, and sane Config/Economy values (PLAN.md §4 targets, analytics
-- transaction types, milestone cars, HUD touch targets and placement). Pure logic on fixtures: runs in Edit mode.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Catalog = require(ReplicatedStorage.Shared.Vehicle.Catalog)
local Controls = require(ReplicatedStorage.Shared.Config.Controls)
local Economy = require(ReplicatedStorage.Shared.Config.Economy)
local Gps = require(ReplicatedStorage.Shared.Config.Gps)
local Harness = require(ReplicatedStorage.Shared.Testing.Harness)
local Types = require(ReplicatedStorage.Shared.Types)
local EconomyService = require(ServerScriptService.Server.Services.EconomyService)

local MAX = 1000 -- a small wallet cap for the fixtures
local NOW = 1800000000 -- a fixed "now" (os.time() seconds)
local NAN = 0 / 0
local MIN_TARGET = 44 -- smallest touch target, px (Config/Controls touch.minTarget)

-- The phone the UI is laid out for, landscape (DriveClient.spec uses the same screen).
local SCREEN = Vector2.new(844, Controls.hud.referenceShortSide)

local function boost(id: string, factor: number, endsAt: number): Types.Boost
	return { id = id, factor = factor, endsAt = endsAt }
end

-- A screen rectangle in UI-scale-1 pixels.
type Rect = { left: number, top: number, right: number, bottom: number }

local function overlaps(a: Rect, b: Rect): boolean
	return a.left < b.right and b.left < a.right and a.top < b.bottom and b.top < a.bottom
end

return function(t: Harness.Api)
	t.describe("EconomyService money math", function()
		t.describe("adding", function()
			t.it("adds whole dollars", function()
				local balance, added = EconomyService.applyAdd(100, 50, MAX)
				t.expect(balance).toBe(150)
				t.expect(added).toBe(50)
			end)

			t.it("rounds amounts down", function()
				local balance, added = EconomyService.applyAdd(100, 12.9, MAX)
				t.expect(balance).toBe(112)
				t.expect(added).toBe(12)
			end)

			t.it("refuses zero, negative and under-a-dollar amounts", function()
				for _, amount in { 0, -5, 0.5, -0.5 } do
					local balance, added = EconomyService.applyAdd(100, amount, MAX)
					t.expect(balance).toBe(100)
					t.expect(added).toBe(0)
				end
			end)

			t.it("refuses NaN and infinite amounts", function()
				for _, amount in { NAN, math.huge, -math.huge } do
					local balance, added = EconomyService.applyAdd(100, amount, MAX)
					t.expect(balance).toBe(100)
					t.expect(added).toBe(0)
				end
			end)

			t.it("stops at the cap and reports only what was added", function()
				local balance, added = EconomyService.applyAdd(990, 50, MAX)
				t.expect(balance).toBe(MAX)
				t.expect(added).toBe(10)
				local full, none = EconomyService.applyAdd(MAX, 50, MAX)
				t.expect(full).toBe(MAX)
				t.expect(none).toBe(0)
			end)

			t.it("never takes cash away from a wallet already over the cap", function()
				local balance, added = EconomyService.applyAdd(1500, 50, MAX)
				t.expect(balance).toBe(1500)
				t.expect(added).toBe(0)
			end)

			t.it("treats a damaged balance as $0", function()
				local fromNan = EconomyService.applyAdd(NAN, 10, MAX)
				local fromNegative = EconomyService.applyAdd(-40, 10, MAX)
				t.expect(fromNan).toBe(10)
				t.expect(fromNegative).toBe(10)
			end)
		end)

		t.describe("spending", function()
			t.it("takes whole dollars, rounding the price down", function()
				t.expect(EconomyService.applySpend(100, 40)).toBe(60)
				t.expect(EconomyService.applySpend(100, 9.99)).toBe(91)
			end)

			t.it("can spend everything but never goes below zero", function()
				t.expect(EconomyService.applySpend(100, 100)).toBe(0)
				t.expect(EconomyService.applySpend(100, 101)).toBe(nil)
				t.expect(EconomyService.applySpend(0, 1)).toBe(nil)
				t.expect(EconomyService.applySpend(-5, 1)).toBe(nil)
			end)

			t.it("refuses zero, negative, under-a-dollar and non-finite prices", function()
				for _, amount in { 0, -10, 0.5, NAN, math.huge, -math.huge } do
					t.expect(EconomyService.applySpend(100, amount)).toBe(nil)
				end
			end)
		end)

		t.describe("amounts and balances", function()
			t.it("accepts only finite numbers of at least $1", function()
				t.expect(EconomyService.wholeAmount(1)).toBe(1)
				t.expect(EconomyService.wholeAmount(7.8)).toBe(7)
				t.expect(EconomyService.wholeAmount(0.99)).toBe(nil)
				t.expect(EconomyService.wholeAmount("5")).toBe(nil)
				t.expect(EconomyService.wholeAmount(nil)).toBe(nil)
			end)

			t.it("cleans stored balances to whole, non-negative dollars", function()
				t.expect(EconomyService.cleanBalance(12.7)).toBe(12)
				t.expect(EconomyService.cleanBalance(-3)).toBe(0)
				t.expect(EconomyService.cleanBalance(NAN)).toBe(0)
				t.expect(EconomyService.cleanBalance(math.huge)).toBe(0)
				t.expect(EconomyService.cleanBalance(nil)).toBe(0)
			end)
		end)
	end)

	t.describe("earnings boosts", function()
		t.it("is 1 with no boosts", function()
			t.expect(EconomyService.multiplierFrom({}, NOW)).toBe(1)
		end)

		t.it("doubles earnings while a 2x boost runs", function()
			t.expect(EconomyService.multiplierFrom({ boost("A", 2, NOW + 60) }, NOW)).toBe(2)
		end)

		t.it("ignores expired boosts, including one ending right now", function()
			t.expect(EconomyService.multiplierFrom({ boost("A", 2, NOW - 1) }, NOW)).toBe(1)
			t.expect(EconomyService.multiplierFrom({ boost("A", 2, NOW) }, NOW)).toBe(1)
			t.expect(EconomyService.multiplierFrom({ boost("A", 2, NOW + 1) }, NOW)).toBe(2)
		end)

		t.it("adds the bonuses of running boosts and skips expired ones", function()
			local boosts = { boost("A", 2, NOW + 600), boost("B", 1.5, NOW + 60), boost("OLD", 3, NOW - 600) }
			t.expect(EconomyService.multiplierFrom(boosts, NOW)).toBeNear(2.5, 1e-9)
		end)

		t.it("never goes above the configured maximum", function()
			local boosts = { boost("A", 3, NOW + 60), boost("B", 3, NOW + 60), boost("C", 3, NOW + 60) }
			t.expect(EconomyService.multiplierFrom(boosts, NOW)).toBe(Economy.boosts.maxMultiplier)
		end)

		t.it("ignores boosts with a broken factor", function()
			local boosts =
				{ boost("NAN", NAN, NOW + 60), boost("SLOW", 0.5, NOW + 60), boost("INF", math.huge, NOW + 60) }
			t.expect(EconomyService.multiplierFrom(boosts, NOW)).toBe(1)
		end)

		t.it("lists only the boosts still running, in order", function()
			local active = EconomyService.activeBoosts(
				{ boost("A", 2, NOW + 10), boost("OLD", 2, NOW - 10), boost("B", 2, NOW + 20) },
				NOW
			)
			t.expect(#active).toBe(2)
			t.expect(active[1].id).toBe("A")
			t.expect(active[2].id).toBe("B")
		end)
	end)

	t.describe("analytics", function()
		t.it("logs every reason under a real transaction type", function()
			local names: { [string]: boolean } = {}
			for _, item in Enum.AnalyticsEconomyTransactionType:GetEnumItems() do
				names[item.Name] = true
			end
			t.expect(names[Economy.analytics.defaultTransactionType]).toBe(true)
			for reason, name in Economy.analytics.transactionTypes do
				t.expect(`{reason}={name}: {names[name] == true}`).toBe(`{reason}={name}: true`)
			end
		end)

		t.it("picks the reason's type, or the default for an unlisted reason", function()
			t.expect(EconomyService.transactionTypeFor("drive")).toBe(Economy.analytics.transactionTypes.drive)
			t.expect(EconomyService.transactionTypeFor("something-new")).toBe(Economy.analytics.defaultTransactionType)
		end)
	end)

	t.describe("formatCash", function()
		t.it("writes whole dollars with thousands separators", function()
			t.expect(Economy.formatCash(0)).toBe("$0")
			t.expect(Economy.formatCash(999)).toBe("$999")
			t.expect(Economy.formatCash(1000)).toBe("$1,000")
			t.expect(Economy.formatCash(12345)).toBe("$12,345")
			t.expect(Economy.formatCash(1234567)).toBe("$1,234,567")
			t.expect(Economy.formatCash(Economy.maxCash)).toBe("$999,999,999")
		end)

		t.it("rounds down and survives bad numbers", function()
			t.expect(Economy.formatCash(12.9)).toBe("$12")
			t.expect(Economy.formatCash(-1500)).toBe("-$1,500")
			t.expect(Economy.formatCash(NAN)).toBe("$0")
			t.expect(Economy.formatCash(math.huge)).toBe("$0")
		end)
	end)

	t.describe("Config/Economy", function()
		t.it("matches the PLAN.md §4 targets", function()
			t.expect(Economy.startingCash).toBe(2500)
			t.expect(Economy.garageSlots).toBe(6)
			t.expect(Economy.customSlots).toBe(3)
			t.expect(Economy.playerTransfers).toBe(false)
			t.expect(Economy.activities.freeDrive).toBe(300)
			t.expect(Economy.activities.freight).toBe(3000)
			t.expect(Economy.freightLicensePrice).toBe(25000)
			t.expect(Economy.maxCash >= Economy.startingCash).toBe(true)
			t.expect(Economy.boosts.maxMultiplier >= 1).toBe(true)
		end)

		t.it("names milestone cars the catalog sells, in rising hours", function()
			local previousMin = 0
			for _, milestone in Economy.milestones do
				t.expect(milestone.minHours <= milestone.maxHours).toBe(true)
				t.expect(milestone.minHours).toBeGreaterThan(previousMin)
				previousMin = milestone.minHours
				t.expect(#milestone.vehicles > 0).toBe(true)
				for _, choice in milestone.vehicles do
					local price = Catalog.totalPrice(choice.vehicleId, choice.trim)
					t.expect(`{choice.vehicleId}/{choice.trim} priced: {price ~= nil}`)
						.toBe(`{choice.vehicleId}/{choice.trim} priced: true`)
					t.expect((price or 0) <= Economy.maxCash).toBe(true)
				end
			end
		end)

		t.it("keeps the HUD's cash and code touch targets at least 44 px", function()
			local hud = Economy.hud
			t.expect(Controls.touch.minTarget >= MIN_TARGET).toBe(true)
			t.expect(hud.rowHeight >= MIN_TARGET).toBe(true)
			t.expect(hud.codesButtonWidth >= MIN_TARGET).toBe(true)
			t.expect(hud.panel.inputHeight >= MIN_TARGET).toBe(true)
			t.expect(hud.panel.buttonHeight >= MIN_TARGET).toBe(true)
			t.expect(hud.panel.closeButtonWidth >= MIN_TARGET).toBe(true)
			t.expect(hud.panel.buttonHeight <= hud.panel.headerHeight).toBe(true) -- Close fits in the header
			t.expect(hud.cashMinWidth <= hud.cashMaxWidth).toBe(true)
		end)

		t.it("puts the cash and Codes button clear of the GPS, the notices and the touch controls", function()
			local hud, touch, panel, toast = Economy.hud, Controls.touch, Gps.panel, Gps.toast
			local width, height = SCREEN.X, SCREEN.Y
			-- UI/Hud: a column in the top-left corner, cash on top, the Codes button under it.
			local wallet: Rect = {
				left = touch.margin,
				top = touch.margin,
				right = touch.margin + math.max(hud.cashMaxWidth, hud.codesButtonWidth),
				bottom = touch.margin + 2 * hud.rowHeight + hud.gap,
			}
			-- UI/GpsPanel: the GPS button and the route chip to its left, top right.
			local gps: Rect = {
				left = width - (panel.margin + panel.buttonSize.X + panel.gap + panel.chipWidth),
				top = panel.top,
				right = width - panel.margin,
				bottom = panel.top + panel.buttonSize.Y,
			}
			-- UI/Toast at its widest: top centre, the text wrapped at maxTextWidth beside the dot, as many lines
			-- tall as it needs (so the whole column under it counts).
			local toastWidth = toast.maxTextWidth + toast.dotSize + toast.gap + 2 * toast.padding.X
			local notices: Rect = {
				left = (width - toastWidth) / 2,
				top = toast.margin,
				right = (width + toastWidth) / 2,
				bottom = height,
			}
			-- UI/TouchControls: the Mode / Camera / Exit row top right, and the steering zones bottom left.
			local buttons: Rect = {
				left = width - (touch.margin + 3 * touch.buttonSize.X + 2 * touch.gap),
				top = touch.margin,
				right = width - touch.margin,
				bottom = touch.margin + touch.buttonSize.Y,
			}
			local steering: Rect = {
				left = touch.margin,
				top = height - (touch.margin + touch.steerSize.Y),
				right = touch.margin + 2 * touch.steerSize.X + touch.gap,
				bottom = height - touch.margin,
			}
			t.expect(overlaps(wallet, gps)).toBe(false)
			t.expect(overlaps(wallet, notices)).toBe(false)
			t.expect(overlaps(wallet, buttons)).toBe(false)
			t.expect(overlaps(wallet, steering)).toBe(false)
		end)

		t.it("fits the code sheet on the phone screen", function()
			local sheet = Economy.hud.panel
			local sheetHeight = sheet.headerHeight + sheet.inputHeight + sheet.buttonHeight + 2 * sheet.padding
			t.expect(sheet.width <= SCREEN.X).toBe(true)
			t.expect(sheetHeight <= SCREEN.Y).toBe(true)
		end)
	end)
end
