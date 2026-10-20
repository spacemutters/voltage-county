--!strict
-- The Wrap & Tint shop's client logic (UI/Customize/CustomizeModel; docs/phase-7-contracts.md "Client"): the tabs,
-- the car's saved look, picking options and stepping the custom color and ride height, the BuyCustomization
-- changes and the running total (the server's own Config/Customization pricing), what each tab shows, the side
-- panel's place on phone and desktop screens, touch-target sizes, the CustomShop bays and prompts, and plate text.
-- Pure logic on Config and fixtures: runs in Edit mode.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")

local Customization = require(ReplicatedStorage.Shared.Config.Customization)
local Economy = require(ReplicatedStorage.Shared.Config.Economy)
local Harness = require(ReplicatedStorage.Shared.Testing.Harness)

local Client = StarterPlayer.StarterPlayerScripts.Client
local Theme = require(Client.UI.Theme)
local Primitives = require(Client.UI.Shop.Primitives)
local ShopStyle = require(Client.UI.Shop.Style)
local CustomizeModel = require(Client.UI.Customize.CustomizeModel)
local Style = require(Client.UI.Customize.Style)

type Look = CustomizeModel.Look

local CLASS = "sedan" -- the Ohm Spark's class: takes spoilers, roof carriers, a splitter and a diffuser
local UID = "spec-car"
local TOLERANCE = 1e-6

-- Screens in unscaled pixels inside the safe area.
local LANDSCAPE_PHONE_TOPBAR = Vector2.new(667, 317) -- what's left under the Roblox top bar
local DESKTOP = Vector2.new(1228, 664) -- 1536 x 830 at the HUD's largest scale
local NARROW = Vector2.new(280, 500)

local copy = Style.copy
local layout = Style.layout

-- The stock look every car starts with.
local function stock(): Look
	return CustomizeModel.savedLook({ uid = UID }, nil)
end

local function with(look: Look, overrides: { [string]: any }): Look
	local changed = CustomizeModel.cloneLook(look)
	for field, value in overrides do
		(changed :: any)[field] = value
	end
	return changed
end

-- A palette paint that isn't the default.
local function otherPaint(): string
	for _, paint in Customization.paints do
		if paint.id ~= Customization.defaults.paint then
			return paint.id
		end
	end
	error("the palette has only the default paint")
end

local function input(saved: Look, pending: Look, overrides: { [string]: any }?): CustomizeModel.PanelInput
	local base: CustomizeModel.PanelInput = {
		title = "Car",
		tab = "paint",
		saved = saved,
		pending = pending,
		class = CLASS,
		cash = 1000000,
		busy = false,
		platePending = false,
		plateAllowed = true,
	}
	if overrides ~= nil then
		for field, value in overrides do
			(base :: any)[field] = value
		end
	end
	return base
end

local function choiceWith(choices: { CustomizeModel.Choice }?, key: string): CustomizeModel.Choice?
	if choices == nil then
		return nil
	end
	for _, choice in choices do
		if choice.key == key then
			return choice
		end
	end
	return nil
end

return function(t: Harness.Api)
	t.describe("CustomizeShop tabs", function()
		t.it("has one tab per Config/Customization category, in order, with its name", function()
			local categories = Customization.categories
			t.expect(#CustomizeModel.tabs).toBe(#categories)
			for index, category in categories do
				t.expect(CustomizeModel.tabs[index].id).toBe(category.id)
				t.expect(CustomizeModel.tabs[index].label).toBe(category.displayName)
				t.expect(CustomizeModel.tabId(category.id)).toBe(category.id)
			end
			t.expect(CustomizeModel.tabId("nitro")).toBe(nil)
		end)
	end)

	t.describe("CustomizeShop saved look", function()
		t.it("fills what the profile lacks with Config/Customization.defaults", function()
			local saved =
				CustomizeModel.savedLook({ uid = UID, paint = "cobalt", finish = "matte", wheels = "mesh" }, nil)
			local defaults = Customization.defaults
			t.expect(saved.uid).toBe(UID)
			t.expect(saved.paint).toBe("cobalt")
			t.expect(saved.finish).toBe("matte")
			t.expect(saved.wheels).toBe("mesh")
			t.expect(saved.wrap).toBe(defaults.wrap)
			t.expect(saved.rideHeight).toBe(defaults.rideHeight)
			t.expect(saved.tint).toBe(defaults.tint)
			t.expect(saved.caliper).toBe(defaults.caliper)
			t.expect(saved.plateFormat).toBe(defaults.plateFormat)
			t.expect(#saved.extras).toBe(0)
			t.expect(saved.plateText).toBe(nil)
		end)

		t.it("keeps the plate text it is given and drops broken or repeated extras", function()
			local saved =
				CustomizeModel.savedLook({ uid = UID, extras = { "roof_rack", 7 :: any, "roof_rack" } }, "ZAP 1")
			t.expect(saved.extras).toEqual({ "roof_rack" })
			t.expect(saved.plateText).toBe("ZAP 1")
		end)

		t.it("compares looks by what shows, ignoring extras order and float noise", function()
			local a = with(stock(), { extras = { "roof_rack", "lip_spoiler" }, rideHeight = 0.25 })
			local b = with(stock(), { extras = { "lip_spoiler", "roof_rack" }, rideHeight = 0.25 + 1e-7 })
			t.expect(CustomizeModel.sameLook(a, b)).toBe(true)
			t.expect(CustomizeModel.sameLook(a, with(b, { tint = 0.5 }))).toBe(false)
			t.expect(CustomizeModel.sameLook(a, with(b, { wrap = "rally" }))).toBe(false)
			-- No wrap reads the same however it is stored (nil or "none").
			local unwrapped = stock()
			unwrapped.wrap = nil
			t.expect(CustomizeModel.sameLook(unwrapped, with(stock(), { wrap = "none" }))).toBe(true)
			t.expect(CustomizeModel.changesOf(with(stock(), { wrap = "none" }), unwrapped)).toBe(nil)
		end)
	end)

	t.describe("CustomizeShop changes and prices", function()
		t.it("sends nothing when nothing differs", function()
			t.expect(CustomizeModel.changesOf(stock(), stock())).toBe(nil)
			local total = CustomizeModel.totalOf(stock(), stock(), CLASS)
			t.expect(total.hasChanges).toBe(false)
			t.expect(total.amount).toBe(0)
			t.expect(total.text).toBe(copy.noChanges)
		end)

		t.it("sends only the fields that differ, a custom color as customColor", function()
			local paint = otherPaint()
			local changes = CustomizeModel.changesOf(stock(), with(stock(), { paint = paint, tint = 0.5 }))
			t.expect(changes).toEqual({ paint = paint, tint = 0.5 })

			local custom = Customization.customPaintId({ h = 0.5, s = 0.5, v = 0.5 })
			local customChanges = CustomizeModel.changesOf(stock(), with(stock(), { paint = custom }))
			t.expect(customChanges).toEqual({ customColor = Customization.parseCustomPaint(custom) })
			-- The server turns it back into the same paint id.
			t.expect(Customization.paintAfter(customChanges :: any)).toBe(custom)

			local extras = CustomizeModel.changesOf(stock(), with(stock(), { extras = { "roof_rack" } }))
			t.expect(extras).toEqual({ extras = { "roof_rack" } })
		end)

		t.it("totals with the server's pricing and passes the server's checks", function()
			local pending = with(stock(), {
				paint = otherPaint(),
				finish = "metallic",
				wrap = "rally",
				wheels = "mesh",
				rideHeight = -0.5,
				tint = 0.75,
				caliper = "red",
				extras = { "lip_spoiler", "roof_rack" },
			})
			local changes = CustomizeModel.changesOf(stock(), pending)
			t.expect(changes ~= nil).toBe(true)
			local expected = Customization.priceOf(changes :: any, stock(), CLASS)
			local total = CustomizeModel.totalOf(stock(), pending, CLASS)
			t.expect(total.amount).toBe(expected)
			t.expect(total.amount).toBeGreaterThan(0)
			t.expect(total.hasChanges).toBe(true)
			local ok = Customization.check(changes :: any, CLASS)
			t.expect(ok).toBe(true)
		end)

		t.it("treats a plate style as free: Apply, without a price", function()
			local pending = with(stock(), { plateFormat = "metro" })
			local total = CustomizeModel.totalOf(stock(), pending, CLASS)
			t.expect(total.hasChanges).toBe(true)
			t.expect(total.amount).toBe(0)
			t.expect(total.text).toBe(copy.free)
			local view = CustomizeModel.panelView(input(stock(), pending))
			t.expect(view.buy.label).toBe(copy.apply)
			t.expect(view.buy.disabled).toBe(false)
		end)

		t.it("shows cash after in the confirm, warning when it would go below zero", function()
			local total = CustomizeModel.totalOf(stock(), with(stock(), { wrap = "rally" }), CLASS)
			local rows = CustomizeModel.confirmRows(total, total.amount - 1)
			t.expect(#rows).toBe(3)
			t.expect(rows[3].tone).toBe("warning")
			t.expect(#CustomizeModel.confirmRows(total, nil)).toBe(1)
			t.expect(CustomizeModel.canAfford(total, total.amount)).toBe(true)
			t.expect(CustomizeModel.canAfford(total, total.amount - 1)).toBe(false)
			t.expect(CustomizeModel.canAfford(total, nil)).toBe(true)
		end)
	end)

	t.describe("CustomizeShop picking", function()
		t.it("picks palette paints and ignores unknown or unchanged choices", function()
			local paint = otherPaint()
			local picked = CustomizeModel.pick(stock(), stock(), "paint", paint, CLASS)
			t.expect(picked ~= nil and picked.paint).toBe(paint)
			t.expect(CustomizeModel.pick(stock(), stock(), "paint", "no_such_paint", CLASS)).toBe(nil)
			t.expect(CustomizeModel.pick(stock(), stock(), "paint", Customization.defaults.paint, CLASS)).toBe(nil)
			t.expect(CustomizeModel.pick(stock(), stock(), "nitro", paint, CLASS)).toBe(nil)
		end)

		t.it("starts a custom color inside the limits, or brings back the car's own", function()
			local fromPalette =
				CustomizeModel.pick(stock(), with(stock(), { paint = "midnight" }), "paint", "custom", CLASS)
			t.expect(fromPalette ~= nil).toBe(true)
			local hsv = Customization.parseCustomPaint((fromPalette :: Look).paint)
			t.expect(hsv ~= nil).toBe(true)
			t.expect(Customization.customColorAllowed(hsv :: any)).toBe(true)

			local own = Customization.customPaintId({ h = 0.3, s = 0.4, v = 0.6 })
			local saved = with(stock(), { paint = own })
			local back = CustomizeModel.pick(saved, with(saved, { paint = otherPaint() }), "paint", "custom", CLASS)
			t.expect(back ~= nil and back.paint).toBe(own)
			-- Already on a custom color: nothing to do.
			t.expect(CustomizeModel.pick(saved, saved, "paint", "custom", CLASS)).toBe(nil)
		end)

		t.it("toggles extras, swapping within a group, and refuses ones the class can't take", function()
			local on = CustomizeModel.pick(stock(), stock(), "extras", "lip_spoiler", CLASS)
			t.expect(on ~= nil and on.extras).toEqual({ "lip_spoiler" })
			local swapped = CustomizeModel.pick(stock(), on :: Look, "extras", "wing_spoiler", CLASS)
			t.expect(swapped ~= nil and swapped.extras).toEqual({ "wing_spoiler" })
			local off = CustomizeModel.pick(stock(), swapped :: Look, "extras", "wing_spoiler", CLASS)
			t.expect(off ~= nil and #off.extras).toBe(0)
			t.expect(Customization.extraAllowed("bull_bar", CLASS)).toBe(false)
			t.expect(CustomizeModel.pick(stock(), stock(), "extras", "bull_bar", CLASS)).toBe(nil)
		end)

		t.it("refuses an extra once the car carries the most it may", function()
			local full: { string } = {}
			for index = 1, Customization.maxExtras do
				table.insert(full, `filler_{index}`)
			end
			t.expect(CustomizeModel.toggleExtra(full, "rear_diffuser", CLASS)).toBe(nil)
			-- Taking one off is always fine.
			t.expect(CustomizeModel.toggleExtra(full, "filler_1", CLASS) ~= nil).toBe(true)
		end)

		t.it("picks tint levels by their card keys", function()
			local level = Customization.tint.levels[#Customization.tint.levels]
			local picked = CustomizeModel.pick(stock(), stock(), "tint", tostring(level.value), CLASS)
			t.expect(picked ~= nil and picked.tint).toBe(level.value)
			t.expect(CustomizeModel.pick(stock(), stock(), "tint", "0.33", CLASS)).toBe(nil)
		end)
	end)

	t.describe("CustomizeShop steppers", function()
		t.it("moves the ride height in Config steps and stops at the ends", function()
			local ride = Customization.rideHeight
			local lower = CustomizeModel.step(stock(), "rideHeight", -1)
			t.expect(lower ~= nil).toBe(true)
			t.expect((lower :: Look).rideHeight).toBeNear(-ride.step, TOLERANCE)
			t.expect(Customization.isRideHeight((lower :: Look).rideHeight)).toBe(true)
			t.expect(CustomizeModel.step(with(stock(), { rideHeight = ride.max }), "rideHeight", 1)).toBe(nil)
			t.expect(CustomizeModel.step(with(stock(), { rideHeight = ride.min }), "rideHeight", -1)).toBe(nil)
		end)

		t.it("wraps the hue round and keeps saturation and brightness inside the limits", function()
			local limits = Customization.customColor
			local nearRed = with(stock(), { paint = Customization.customPaintId({ h = 0.99, s = 0.5, v = 0.5 }) })
			local wrapped = CustomizeModel.step(nearRed, "h", 1)
			local hsv = Customization.parseCustomPaint((wrapped :: Look).paint)
			t.expect(hsv ~= nil and hsv.h < 0.5).toBe(true)

			local vivid = with(stock(), {
				paint = Customization.customPaintId({ h = 0.5, s = limits.maxSaturation, v = limits.maxValue }),
			})
			t.expect(CustomizeModel.step(vivid, "s", 1)).toBe(nil)
			t.expect(CustomizeModel.step(vivid, "v", 1)).toBe(nil)
			local softer = CustomizeModel.step(vivid, "s", -1)
			t.expect(Customization.customColorAllowed(Customization.parseCustomPaint((softer :: Look).paint) :: any))
				.toBe(true)
		end)

		t.it("does nothing to the color of a palette paint", function()
			t.expect(CustomizeModel.step(stock(), "h", 1)).toBe(nil)
			t.expect(CustomizeModel.step(stock(), "nitro", 1)).toBe(nil)
		end)

		t.it("names stances in steps from stock", function()
			local step = Customization.rideHeight.step
			t.expect(CustomizeModel.stanceLabel(0)).toBe(copy.stock)
			t.expect(CustomizeModel.stanceLabel(-2 * step)).toBe(string.format(copy.lowered, 2))
			t.expect(CustomizeModel.stanceLabel(step)).toBe(string.format(copy.raised, 1))
		end)
	end)

	t.describe("CustomizeShop tab views", function()
		t.it(
			"shows every paint as a swatch, the custom swatch, and the custom steppers only for a custom color",
			function()
				local paint = otherPaint()
				local view = CustomizeModel.tabView(input(stock(), with(stock(), { paint = paint })))
				t.expect(#(view.swatches or {})).toBe(#Customization.paints)
				local chosen = choiceWith(view.swatches, paint)
				local current = choiceWith(view.swatches, Customization.defaults.paint)
				t.expect(chosen ~= nil and chosen.selected).toBe(true)
				t.expect(current ~= nil and current.saved and current.priceText).toBe(copy.current)
				t.expect(view.customSwatch ~= nil).toBe(true)
				t.expect(view.steppers).toBe(nil)
				t.expect(view.detail ~= nil).toBe(true)

				local custom = with(stock(), { paint = Customization.customPaintId({ h = 0.6, s = 0.5, v = 0.5 }) })
				local customView = CustomizeModel.tabView(input(stock(), custom))
				t.expect(#(customView.steppers or {})).toBe(3)
				t.expect(customView.customSwatch ~= nil and customView.customSwatch.selected).toBe(true)
			end
		)

		t.it("prices each card as changing just that one thing", function()
			local view = CustomizeModel.tabView(input(stock(), stock(), { tab = "wrap" }))
			local rally = choiceWith(view.cards, "rally")
			local expected = Customization.priceOf({ wrap = "rally" }, stock(), CLASS)
			t.expect(expected).toBeGreaterThan(0)
			t.expect(rally ~= nil and rally.priceText).toBe(Economy.formatCash(expected))
			local none = choiceWith(view.cards, Customization.defaults.wrap)
			t.expect(none ~= nil and none.priceText).toBe(copy.current)
		end)

		t.it("lists only the extras the class takes", function()
			local view = CustomizeModel.tabView(input(stock(), stock(), { tab = "extras" }))
			local cards: { CustomizeModel.Choice } = view.cards or {}
			t.expect(#cards).toBe(#Customization.extrasFor(CLASS))
			for _, card in cards do
				t.expect(Customization.extraAllowed(card.key, CLASS)).toBe(true)
				t.expect(card.disabled).toBe(false)
			end
			local none = CustomizeModel.tabView(input(stock(), stock(), { tab = "extras", class = "no_such_class" }))
			t.expect(none.cards).toBe(nil)
			t.expect(none.note).toBe(copy.noExtras)
		end)

		t.it("shows the free plate styles and the plate text box only when custom text is allowed", function()
			local view = CustomizeModel.tabView(input(stock(), stock(), { tab = "plateFormat" }))
			t.expect(#(view.cards or {})).toBe(#Customization.plateFormats)
			t.expect(view.plate ~= nil and view.plate.allowed).toBe(true)
			t.expect(view.plate ~= nil and view.plate.maxLength).toBe(Customization.plate.maxLength)
			local locked =
				CustomizeModel.tabView(input(stock(), stock(), { tab = "plateFormat", plateAllowed = false }))
			t.expect(locked.plate ~= nil and locked.plate.allowed).toBe(false)
		end)

		t.it("turns Buy off with no changes, when short of cash, and while a call runs", function()
			local idle = CustomizeModel.panelView(input(stock(), stock()))
			t.expect(idle.buy.disabled).toBe(true)
			t.expect(idle.canReset).toBe(false)

			local pending = with(stock(), { wrap = "rally" })
			local short = CustomizeModel.panelView(input(stock(), pending, { cash = 0 }))
			t.expect(short.buy.disabled).toBe(true)
			t.expect(short.total.status ~= nil).toBe(true)
			t.expect(short.total.tone).toBe("warning")
			t.expect(short.canReset).toBe(true)

			local busy = CustomizeModel.panelView(input(stock(), pending, { busy = true }))
			t.expect(busy.buy.disabled).toBe(true)
			t.expect(busy.buy.label).toBe(copy.buying)

			local ready = CustomizeModel.panelView(input(stock(), pending))
			t.expect(ready.buy.disabled).toBe(false)
			t.expect(ready.buy.label).toBe(copy.buy)
		end)
	end)

	t.describe("CustomizeShop layout", function()
		t.it("puts the panel on the right of a landscape phone with room for the options", function()
			local rect = CustomizeModel.panelLayout(LANDSCAPE_PHONE_TOPBAR)
			t.expect(rect.left + rect.width).toBe(LANDSCAPE_PHONE_TOPBAR.X - layout.margin)
			t.expect(rect.top).toBe(layout.margin)
			t.expect(rect.width).toBeGreaterThan(layout.minWidth - 1)
			t.expect(rect.width).toBeLessThan(LANDSCAPE_PHONE_TOPBAR.X / 2 + 1) -- the car stays in view
			t.expect(rect.height).toBe(LANDSCAPE_PHONE_TOPBAR.Y - 2 * layout.margin)
			t.expect(rect.columns).toBe(2)
			local body = rect.height
				- CustomizeModel.headerHeight()
				- CustomizeModel.tabsHeight()
				- CustomizeModel.footerHeight()
			t.expect(body).toBeGreaterThan(layout.detailHeight + layout.swatchSize)
		end)

		t.it("caps the panel on desktop and fits three cards across", function()
			local rect = CustomizeModel.panelLayout(DESKTOP)
			t.expect(rect.width).toBe(layout.maxWidth)
			t.expect(rect.columns).toBe(layout.cardMaxColumns)
		end)

		t.it("slides the camera so the car sits in the middle of the free part of the screen", function()
			t.expect(CustomizeModel.framingShift(0, 70, 16 / 9, 20)).toBe(0)
			local shift = CustomizeModel.framingShift(0.4, 70, 16 / 9, 20)
			t.expect(shift).toBeGreaterThan(0)
			-- Twice as far away needs twice the slide for the same move on screen.
			t.expect(CustomizeModel.framingShift(0.4, 70, 16 / 9, 40)).toBeNear(2 * shift, TOLERANCE)
			-- Check the geometry: a point `shift` studs to the camera's left lands at the free area's centre.
			local halfWidth = 20 * math.tan(math.rad(70) / 2) * 16 / 9 -- studs across half the view at that depth
			local screenX = 0.5 - 0.5 * shift / halfWidth -- 0 = left edge, 1 = right edge
			t.expect(screenX).toBeNear((1 - 0.4) / 2, TOLERANCE)
		end)

		t.it("never runs off a narrow screen", function()
			local rect = CustomizeModel.panelLayout(NARROW)
			t.expect(rect.left).toBeGreaterThan(layout.margin - 1)
			t.expect(rect.left + rect.width).toBeLessThan(NARROW.X - layout.margin + 1)
			t.expect(rect.columns).toBeGreaterThan(0)
		end)

		t.it("keeps every tappable size at least a touch target", function()
			local minimum = Theme.size.touchTarget
			local sizes = {
				layout.swatchSize,
				layout.cardHeight,
				layout.stepperHeight,
				layout.stepperButton,
				layout.buttonHeight,
				layout.inputHeight,
				layout.closeSize,
				layout.headerHeight,
				layout.resetWidth,
				layout.plateButtonWidth,
				layout.entryHeight,
				layout.entryMinWidth,
				ShopStyle.layout.chipHeight, -- the tabs
				ShopStyle.layout.closeSize,
			}
			for _, size in sizes do
				t.expect(size).toBeGreaterThan(minimum - 1)
			end
			t.expect(Primitives.chipsHeight()).toBeGreaterThan(minimum - 1)
		end)
	end)

	t.describe("CustomizeShop bays", function()
		t.it("finds a car standing in each bay and not one outside or above it", function()
			local shops = CustomizeModel.shops()
			t.expect(#shops).toBeGreaterThan(0)
			for _, bay in shops do
				local frame = CFrame.new(bay.position) * CFrame.Angles(0, math.rad(bay.yaw), 0)
				local centre = frame:PointToWorldSpace(Vector3.new(0, 2, 0))
				t.expect(CustomizeModel.inBay(centre, bay, 0)).toBe(true)
				t.expect(CustomizeModel.bayAt(centre, 0)).toBe(bay)
				local outside = frame:PointToWorldSpace(Vector3.new(bay.size.X / 2 + 1, 2, 0))
				t.expect(CustomizeModel.inBay(outside, bay, 0)).toBe(false)
				t.expect(CustomizeModel.inBay(outside, bay, 2)).toBe(true)
				local above = frame:PointToWorldSpace(Vector3.new(0, Style.bayHeight + 10, 0))
				t.expect(CustomizeModel.inBay(above, bay, 0)).toBe(false)
			end
		end)

		t.it("knows a shop's prompt by the bay part it sits under", function()
			local bay = CustomizeModel.shops()[1]
			local part = Instance.new("Part")
			part.Name = bay.id
			local prompt = Instance.new("ProximityPrompt")
			prompt.Parent = part
			local stray = Instance.new("ProximityPrompt")
			t.expect(CustomizeModel.bayOfPrompt(prompt)).toBe(bay)
			t.expect(CustomizeModel.bayOfPrompt(stray)).toBe(nil)
			t.expect(CustomizeModel.isShopPrompt(stray)).toBe(false)
			part:Destroy()
			stray:Destroy()
		end)
	end)

	t.describe("CustomizeShop plate text", function()
		t.it("keeps only what a plate may show, in capitals, cut to length", function()
			local max = Customization.plate.maxLength
			t.expect(CustomizeModel.cleanPlate("ab-12 !x", max, false)).toBe("AB-12 X")
			t.expect(CustomizeModel.cleanPlate("  hi  there", max, false)).toBe("HI THERE")
			t.expect(CustomizeModel.cleanPlate("go ", max, false)).toBe("GO ") -- still typing
			t.expect(CustomizeModel.cleanPlate("go ", max, true)).toBe("GO")
			t.expect(#CustomizeModel.cleanPlate("ABCDEFGHIJKLMN", max, false)).toBe(max)
			t.expect(Customization.isPlateTextAllowed(CustomizeModel.cleanPlate("v0lt-up", max, true))).toBe(true)
			t.expect(CustomizeModel.cleanPlate("", max, true)).toBe("")
		end)
	end)
end
