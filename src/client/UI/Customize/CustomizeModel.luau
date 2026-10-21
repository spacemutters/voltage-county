--!strict
-- The Wrap & Tint shop's logic, with no UI, no network and no instances changed (docs/phase-7-contracts.md
-- "Client"), so tests/CustomizeShop.spec can check it in Edit mode:
--
--   tabs, tabId()                 the shop's tabs, in Config/Customization.categories order
--   savedLook(), cloneLook(),     the car's look as this client knows it, copies and comparisons
--   sameLook()
--   pick(), step()                the look after tapping an option, or a - / + (custom color, ride height);
--                                 nil when nothing would change
--   changesOf()                   the BuyCustomization `changes`: only the fields that differ from the car
--   totalOf(), canAfford(),       the running total (Config/Customization.priceOf, the server's own pricing),
--   confirmRows()                 and the confirm dialog's rows
--   tabView(), panelView()        everything the panel shows for a tab: swatches, cards, steppers, notes, prices
--   panelLayout() and heights     where the side panel goes on a screen, and how many cards fit across
--   shops(), inBay(), bayAt(),    the CustomShop bays from Config/MapLayout: whether a car stands in one, and
--   bayOfPrompt(), isShopPrompt() which bay a triggered prompt belongs to
--   cleanPlate()                  custom plate text as the player types it
--
-- Every price comes from Config/Customization (scaled by the car's class tier there); every word from
-- UI/Customize/Style. The server decides every purchase: these checks only keep the buttons honest.

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Catalog = require(ReplicatedStorage.Shared.Vehicle.Catalog)
local Customization = require(ReplicatedStorage.Shared.Config.Customization)
local Economy = require(ReplicatedStorage.Shared.Config.Economy)
local MapLayout = require(ReplicatedStorage.Shared.Config.MapLayout)
local Primitives = require(script.Parent.Parent.Shop.Primitives)
local Style = require(script.Parent.Style)

export type Look = Customization.Look
export type Changes = Customization.Changes
export type HSV = Customization.HSV
export type Location = MapLayout.Location
export type TabId = string -- a Config/Customization.categories id (also the Changes field the tab edits)

-- One option on a swatch grid or card list.
export type Choice = {
	key: string, -- what pick() gets back when it is tapped
	label: string,
	priceText: string, -- "$1,500", "Free", "On your car"
	selected: boolean, -- in the look being tried on
	saved: boolean, -- on the car now
	color: Color3?, -- swatches
	disabled: boolean?, -- can't be chosen now (too many extras)
}

-- A - [label, value, bar] + row.
export type Stepper = {
	key: string, -- what step() gets back
	label: string,
	valueText: string,
	fraction: number, -- 0..1: the bar's fill
	canDown: boolean,
	canUp: boolean,
	color: Color3?, -- the bar's color (the custom color itself)
}

export type PlateView = {
	allowed: boolean, -- custom text may be set (the Custom Plates pass, or Studio)
	maxLength: number,
	rules: string,
	lockedNote: string,
	busy: boolean, -- SetPlate is in flight
}

-- What a tab shows, top to bottom (UI/Customize/Options draws it).
export type TabView = {
	detail: string?,
	swatches: { Choice }?,
	customSwatch: Choice?,
	steppers: { Stepper }?,
	cardsHeading: string?,
	cards: { Choice }?,
	note: string?,
	plate: PlateView?,
}

export type Total = {
	amount: number, -- whole $ (0 with no changes, or only free ones)
	hasChanges: boolean,
	text: string,
	tone: Primitives.Tone,
	status: string?, -- "You need $X more", when the cash is known and short
}

export type PanelInput = {
	title: string,
	tab: TabId,
	saved: Look,
	pending: Look,
	class: string,
	bodyStyle: string?, -- Config/Vehicles bodyStyle: some extras fit only some bodies
	cash: number?,
	busy: boolean, -- any call in flight
	platePending: boolean, -- the call in flight is SetPlate
	plateAllowed: boolean,
	-- Phase 12: the exclusive looks the player has (the profile snapshot's `looks`, by id); the Wrap tab lists those
	-- exclusive wraps too (Config/Customization.wrapsFor). nil: none.
	looks: { [string]: boolean }?,
	-- The car's body takes paint but no wrap bands (final art: Vehicle/Appearance.takesWraps is false), so the Wrap
	-- tab lists only the wraps that fit it (Config/Customization.wrapFitsMesh: no bands, or a full-color look for
	-- final art) and says why.
	paintOnly: boolean?,
}

export type PanelView = {
	title: string,
	tabs: { { id: TabId, label: string } },
	tab: TabId,
	body: TabView,
	total: Total,
	canReset: boolean,
	busy: boolean,
	buy: { label: string, disabled: boolean },
}

-- The side panel on a screen, in unscaled pixels from the top-left corner.
export type PanelRect = { left: number, top: number, width: number, height: number, columns: number }

export type VehicleInfo = { name: string, class: string, bodyStyle: string }

local CustomizeModel = {}

local copy = Style.copy
local layout = Style.layout

-- The MapLayout tag of a Wrap & Tint shop's bay (docs/phase-7-contracts.md).
local SHOP_TAG = "CustomShop"
-- The key of the "custom color" swatch (palette ids are words like "pearl_white", never this).
local CUSTOM_KEY = "custom"
-- Stepper keys: the custom color's parts and the ride height.
local HUE, SATURATION, VALUE, RIDE_HEIGHT = "h", "s", "v", "rideHeight"
-- Floating-point slack when comparing ride heights and tints (they cross the network as decimals).
local EPSILON = 1e-4
local DEGREES = 360 -- hue is shown in degrees
local PERCENT = 100

-- Tabs -------------------------------------------------------------------------------------------------------------

CustomizeModel.tabs = {} :: { { id: TabId, label: string } }
for _, category in Customization.categories do
	table.insert(CustomizeModel.tabs, { id = category.id, label = category.displayName })
end

-- `id` when it is one of the tabs, else nil.
function CustomizeModel.tabId(id: string): TabId?
	for _, tab in CustomizeModel.tabs do
		if tab.id == id then
			return tab.id
		end
	end
	return nil
end

-- Looks -------------------------------------------------------------------------------------------------------------

local function sameNumber(a: number, b: number): boolean
	return math.abs(a - b) <= EPSILON
end

local function wrapOf(look: Look): string
	return look.wrap or Customization.defaults.wrap
end

-- True when the two lists hold the same ids (order doesn't matter).
local function sameSet(a: { string }, b: { string }): boolean
	if #a ~= #b then
		return false
	end
	local inA: { [string]: boolean } = {}
	for _, id in a do
		inA[id] = true
	end
	for _, id in b do
		if not inA[id] then
			return false
		end
	end
	return true
end

function CustomizeModel.cloneLook(look: Look): Look
	local copied = table.clone(look)
	copied.extras = table.clone(look.extras)
	return copied
end

-- True when the two looks would make the car look the same (everything the shop can change).
function CustomizeModel.sameLook(a: Look, b: Look): boolean
	return a.paint == b.paint
		and a.finish == b.finish
		and wrapOf(a) == wrapOf(b)
		and a.wheels == b.wheels
		and sameNumber(a.rideHeight, b.rideHeight)
		and sameNumber(a.tint, b.tint)
		and a.caliper == b.caliper
		and sameSet(a.extras, b.extras)
		and a.plateFormat == b.plateFormat
end

local function stringOr(value: any, fallback: string): string
	return if type(value) == "string" and value ~= "" then value else fallback
end

local function numberOr(value: any, fallback: number): number
	return if type(value) == "number" and value == value and math.abs(value) ~= math.huge then value else fallback
end

-- The car's look as far as this client knows it: the owned car's fields from the profile snapshot (any it lacks
-- fall back to Config/Customization.defaults, the look every car starts with), seeded by its uid so the standard
-- plate number matches the server's. `plateText` is the filtered text already on the car's plate (nil: the plate
-- style's standard text).
function CustomizeModel.savedLook(owned: { [string]: any }, plateText: string?): Look
	local defaults = Customization.defaults
	local extras: { string } = {}
	if type(owned.extras) == "table" then
		for _, id in owned.extras do
			if type(id) == "string" and not table.find(extras, id) then
				table.insert(extras, id)
			end
		end
	end
	return {
		uid = stringOr(owned.uid, ""),
		paint = stringOr(owned.paint, defaults.paint),
		finish = stringOr(owned.finish, defaults.finish),
		wrap = stringOr(owned.wrap, defaults.wrap),
		wheels = stringOr(owned.wheels, defaults.wheels),
		rideHeight = numberOr(owned.rideHeight, defaults.rideHeight),
		tint = numberOr(owned.tint, defaults.tint),
		caliper = stringOr(owned.caliper, defaults.caliper),
		extras = extras,
		plateFormat = stringOr(owned.plateFormat, defaults.plateFormat),
		plateText = plateText,
	}
end

-- The name and class of a catalog car (nil for an unknown id, e.g. a player design).
function CustomizeModel.vehicleInfo(vehicleId: string): VehicleInfo?
	local vehicle = Catalog.getVehicle(vehicleId)
	if vehicle == nil then
		return nil
	end
	return { name = vehicle.displayName, class = vehicle.class, bodyStyle = vehicle.bodyStyle }
end

-- Changes -----------------------------------------------------------------------------------------------------------

-- The BuyCustomization `changes` that turn `saved` into `pending`: only the fields that differ (a custom color as
-- `customColor`, a palette paint as `paint`; extras as the whole new list). nil when nothing differs.
function CustomizeModel.changesOf(saved: Look, pending: Look): Changes?
	local changes: Changes = {}
	local any = false
	if pending.paint ~= saved.paint then
		local hsv = Customization.parseCustomPaint(pending.paint)
		if hsv ~= nil then
			changes.customColor = hsv
		else
			changes.paint = pending.paint
		end
		any = true
	end
	if pending.finish ~= saved.finish then
		changes.finish = pending.finish
		any = true
	end
	if wrapOf(pending) ~= wrapOf(saved) then
		changes.wrap = wrapOf(pending)
		any = true
	end
	if pending.wheels ~= saved.wheels then
		changes.wheels = pending.wheels
		any = true
	end
	if not sameNumber(pending.rideHeight, saved.rideHeight) then
		changes.rideHeight = pending.rideHeight
		any = true
	end
	if not sameNumber(pending.tint, saved.tint) then
		changes.tint = pending.tint
		any = true
	end
	if pending.caliper ~= saved.caliper then
		changes.caliper = pending.caliper
		any = true
	end
	if not sameSet(pending.extras, saved.extras) then
		changes.extras = table.clone(pending.extras)
		any = true
	end
	if pending.plateFormat ~= saved.plateFormat then
		changes.plateFormat = pending.plateFormat
		any = true
	end
	return if any then changes else nil
end

-- What these changes cost on this car (Config/Customization.priceOf: only what differs; plate styles and removing
-- extras are free).
local function priceOf(changes: Changes, saved: Look, class: string): number
	local total = Customization.priceOf(changes, saved, class)
	return total
end

local function cash(amount: number): string
	return Economy.formatCash(amount)
end

-- The running total of trying `pending` on a car that looks like `saved`.
function CustomizeModel.totalOf(saved: Look, pending: Look, class: string): Total
	local changes = CustomizeModel.changesOf(saved, pending)
	if changes == nil then
		return { amount = 0, hasChanges = false, text = copy.noChanges, tone = "dim", status = nil }
	end
	local amount = priceOf(changes, saved, class)
	return {
		amount = amount,
		hasChanges = true,
		text = if amount > 0 then cash(amount) else copy.free,
		tone = "normal",
		status = nil,
	}
end

-- True when the player can pay the total (or their cash isn't known yet: the server checks anyway).
function CustomizeModel.canAfford(total: Total, cashNow: number?): boolean
	return cashNow == nil or total.amount <= cashNow
end

-- The confirm dialog's rows: the total, the player's cash and what's left after (when the cash is known).
function CustomizeModel.confirmRows(total: Total, cashNow: number?): { Primitives.ConfirmRow }
	local rows: { Primitives.ConfirmRow } = { { label = copy.confirmTotal, value = cash(total.amount) } }
	if cashNow ~= nil then
		local after = cashNow - total.amount
		table.insert(rows, { label = copy.yourCash, value = cash(cashNow), tone = "dim" })
		table.insert(
			rows,
			{ label = copy.after, value = cash(after), tone = if after < 0 then "warning" else "normal" }
		)
	end
	return rows
end

-- Choosing ----------------------------------------------------------------------------------------------------------

local function isCustom(paint: string): boolean
	return Customization.parseCustomPaint(paint) ~= nil
end

-- A custom color to start from: the car's current color, pulled inside the custom color's limits.
local function customFrom(paint: string): string
	local color = Customization.paintColor(paint) or Color3.new(1, 1, 1)
	local h, s, v = color:ToHSV()
	return Customization.customPaintId({ h = h, s = s, v = v })
end

local function with(look: Look, field: string, value: any): Look
	local changed = CustomizeModel.cloneLook(look);
	(changed :: any)[field] = value
	return changed
end

-- The tint level a card key names.
local function tintLevelFor(key: string): Customization.TintLevel?
	for _, level in Customization.tint.levels do
		if tostring(level.value) == key then
			return level
		end
	end
	return nil
end

-- The extras list after tapping `id`: off if it was on; else on, replacing any extra in the same group (one
-- spoiler, one roof carrier, one front piece). nil when it can't go on this car or the car is full.
function CustomizeModel.toggleExtra(extras: { string }, id: string, class: string, bodyStyle: string?): { string }?
	local list = table.clone(extras)
	local at = table.find(list, id)
	if at ~= nil then
		table.remove(list, at)
		return list
	end
	local extra = Customization.getExtra(id)
	if extra == nil or not Customization.extraAllowed(id, class, bodyStyle) then
		return nil
	end
	local group = extra.group
	if group ~= nil then
		for index = #list, 1, -1 do
			local other = Customization.getExtra(list[index])
			if other ~= nil and other.group == group then
				table.remove(list, index)
			end
		end
	end
	if #list >= Customization.maxExtras then
		return nil
	end
	table.insert(list, id)
	return list
end

-- The look after tapping option `key` on `tab` while trying `pending` on a car that looks like `saved`, or nil
-- when the key is unknown or nothing would change. The custom color swatch goes back to the car's own custom color
-- when it has one, else starts a custom color from the paint being tried on.
function CustomizeModel.pick(
	saved: Look,
	pending: Look,
	tab: TabId,
	key: string,
	class: string,
	bodyStyle: string?
): Look?
	local result: Look? = nil
	if tab == "paint" then
		if key == CUSTOM_KEY then
			local start = if isCustom(saved.paint) then saved.paint else customFrom(pending.paint)
			result = if isCustom(pending.paint) then nil else with(pending, "paint", start)
		elseif Customization.getPaint(key) ~= nil then
			result = with(pending, "paint", key)
		end
	elseif tab == "finish" then
		result = if Customization.getFinish(key) ~= nil then with(pending, "finish", key) else nil
	elseif tab == "wrap" then
		result = if Customization.getWrap(key) ~= nil then with(pending, "wrap", key) else nil
	elseif tab == "wheels" then
		result = if Customization.getWheel(key) ~= nil then with(pending, "wheels", key) else nil
	elseif tab == "tint" then
		local level = tintLevelFor(key)
		result = if level ~= nil then with(pending, "tint", level.value) else nil
	elseif tab == "caliper" then
		result = if Customization.getCaliper(key) ~= nil then with(pending, "caliper", key) else nil
	elseif tab == "extras" then
		local extras = CustomizeModel.toggleExtra(pending.extras, key, class, bodyStyle)
		result = if extras ~= nil then with(pending, "extras", extras) else nil
	elseif tab == "plateFormat" then
		result = if Customization.getPlateFormat(key) ~= nil then with(pending, "plateFormat", key) else nil
	end
	if result ~= nil and CustomizeModel.sameLook(result, pending) then
		return nil
	end
	return result
end

-- The look after a - (direction -1) or + (1) on a stepper, or nil when it is at its end or unknown. Hue wraps
-- round; saturation and brightness stop at Config/Customization's limits; ride height moves in its steps.
function CustomizeModel.step(pending: Look, key: string, direction: number): Look?
	local sign = if direction < 0 then -1 else 1
	if key == RIDE_HEIGHT then
		local ride = Customization.rideHeight
		local steps = math.floor(pending.rideHeight / ride.step + 0.5) + sign
		local value = math.clamp(steps * ride.step, ride.min, ride.max)
		return if sameNumber(value, pending.rideHeight) then nil else with(pending, "rideHeight", value)
	end
	local hsv = Customization.parseCustomPaint(pending.paint)
	if hsv == nil then
		return nil
	end
	local limits = Customization.customColor
	local stepSize = (Style.colorSteps :: any)[key]
	if stepSize == nil then
		return nil
	end
	local h, s, v = hsv.h, hsv.s, hsv.v
	if key == HUE then
		h = (h + sign * stepSize) % 1
	elseif key == SATURATION then
		s = math.clamp(s + sign * stepSize, limits.minSaturation, limits.maxSaturation)
	elseif key == VALUE then
		v = math.clamp(v + sign * stepSize, limits.minValue, limits.maxValue)
	end
	local paint = Customization.customPaintId({ h = h, s = s, v = v })
	return if paint == pending.paint then nil else with(pending, "paint", paint)
end

-- Tab views ---------------------------------------------------------------------------------------------------------

-- "On your car", "Free" or the price of changing just this one thing.
local function priceText(saved: Look, changes: Changes, class: string, onCar: boolean): string
	if onCar then
		return copy.current
	end
	local price = priceOf(changes, saved, class)
	return if price > 0 then cash(price) else copy.free
end

local function detail(label: string, price: string): string
	return label .. copy.separator .. price
end

-- "Stock", "Lowered 2", "Raised 1": a ride height in steps from stock.
function CustomizeModel.stanceLabel(value: number): string
	local steps = math.floor(math.abs(value) / Customization.rideHeight.step + 0.5)
	if steps == 0 then
		return copy.stock
	end
	return string.format(if value < 0 then copy.lowered else copy.raised, steps)
end

local function range(value: number, min: number, max: number): number
	return if max > min then math.clamp((value - min) / (max - min), 0, 1) else 1
end

local function paintView(saved: Look, pending: Look, class: string): TabView
	local swatches: { Choice } = {}
	local chosen: Choice? = nil
	for _, paint in Customization.paints do
		local choice: Choice = {
			key = paint.id,
			label = paint.displayName,
			priceText = priceText(saved, { paint = paint.id }, class, saved.paint == paint.id),
			selected = pending.paint == paint.id,
			saved = saved.paint == paint.id,
			color = paint.color,
		}
		table.insert(swatches, choice)
		if choice.selected then
			chosen = choice
		end
	end

	-- The custom swatch: the custom color being tried on, else the car's own custom color, else a rainbow.
	local pendingHsv = Customization.parseCustomPaint(pending.paint)
	local savedHsv = Customization.parseCustomPaint(saved.paint)
	local shown = if pendingHsv ~= nil then pending.paint elseif savedHsv ~= nil then saved.paint else nil
	local custom: Choice = {
		key = CUSTOM_KEY,
		label = copy.customColor,
		-- Tapping it brings back the car's own custom color (nothing to pay) or starts a new one.
		priceText = if pendingHsv ~= nil
			then priceText(saved, { customColor = pendingHsv }, class, pending.paint == saved.paint)
			elseif savedHsv ~= nil then copy.current
			else cash(Customization.scaledPrice(Customization.customColor.price, class)),
		selected = pendingHsv ~= nil,
		saved = savedHsv ~= nil,
		color = if shown ~= nil then Customization.paintColor(shown) else nil,
	}

	local steppers: { Stepper }? = nil
	if pendingHsv ~= nil then
		local limits = Customization.customColor
		local color = Customization.paintColor(pending.paint)
		steppers = {
			{
				key = HUE,
				label = copy.hue,
				valueText = string.format(copy.degrees, math.floor(pendingHsv.h * DEGREES + 0.5) % DEGREES),
				fraction = pendingHsv.h,
				canDown = true,
				canUp = true,
				color = color,
			},
			{
				key = SATURATION,
				label = copy.saturation,
				valueText = string.format(copy.percent, math.floor(pendingHsv.s * PERCENT + 0.5)),
				fraction = range(pendingHsv.s, limits.minSaturation, limits.maxSaturation),
				canDown = pendingHsv.s > limits.minSaturation + EPSILON,
				canUp = pendingHsv.s < limits.maxSaturation - EPSILON,
				color = color,
			},
			{
				key = VALUE,
				label = copy.brightness,
				valueText = string.format(copy.percent, math.floor(pendingHsv.v * PERCENT + 0.5)),
				fraction = range(pendingHsv.v, limits.minValue, limits.maxValue),
				canDown = pendingHsv.v > limits.minValue + EPSILON,
				canUp = pendingHsv.v < limits.maxValue - EPSILON,
				color = color,
			},
		}
	end

	local named = if pendingHsv ~= nil then custom else chosen
	return {
		detail = if named ~= nil then detail(named.label, named.priceText) else nil,
		swatches = swatches,
		customSwatch = custom,
		steppers = steppers,
	}
end

local function caliperView(saved: Look, pending: Look, class: string): TabView
	local swatches: { Choice } = {}
	local chosen: Choice? = nil
	for _, caliper in Customization.calipers do
		local choice: Choice = {
			key = caliper.id,
			label = caliper.displayName,
			priceText = priceText(saved, { caliper = caliper.id }, class, saved.caliper == caliper.id),
			selected = pending.caliper == caliper.id,
			saved = saved.caliper == caliper.id,
			color = caliper.color,
		}
		table.insert(swatches, choice)
		if choice.selected then
			chosen = choice
		end
	end
	return {
		detail = if chosen ~= nil then detail(chosen.label, chosen.priceText) else nil,
		swatches = swatches,
	}
end

-- Cards for a list of { id, displayName } options of one Changes field.
local function cardsFor(
	list: { any },
	field: string,
	saved: Look,
	pending: Look,
	class: string,
	current: (look: Look) -> string
): { Choice }
	local cards: { Choice } = {}
	for _, option in list do
		local changes: any = { [field] = option.id }
		local onCar = current(saved) == option.id
		table.insert(cards, {
			key = option.id,
			label = option.displayName,
			priceText = priceText(saved, changes, class, onCar),
			selected = current(pending) == option.id,
			saved = onCar,
		})
	end
	return cards
end

local function stanceView(saved: Look, pending: Look, class: string): TabView
	local ride = Customization.rideHeight
	local value = pending.rideHeight
	local price = priceText(saved, { rideHeight = value }, class, sameNumber(value, saved.rideHeight))
	return {
		detail = detail(CustomizeModel.stanceLabel(value), price),
		steppers = {
			{
				key = RIDE_HEIGHT,
				label = copy.rideHeight,
				valueText = CustomizeModel.stanceLabel(value),
				fraction = range(value, ride.min, ride.max),
				canDown = value > ride.min + EPSILON,
				canUp = value < ride.max - EPSILON,
			},
		},
	}
end

local function tintView(saved: Look, pending: Look, class: string): TabView
	local cards: { Choice } = {}
	for _, level in Customization.tint.levels do
		local onCar = sameNumber(saved.tint, level.value)
		table.insert(cards, {
			key = tostring(level.value),
			label = level.displayName,
			priceText = priceText(saved, { tint = level.value }, class, onCar),
			selected = sameNumber(pending.tint, level.value),
			saved = onCar,
		})
	end
	return { cards = cards }
end

local function extrasView(saved: Look, pending: Look, class: string, bodyStyle: string?): TabView
	local available = Customization.extrasFor(class, bodyStyle)
	if #available == 0 then
		return { note = copy.noExtras }
	end
	local cards: { Choice } = {}
	for _, extra in available do
		local on = table.find(pending.extras, extra.id) ~= nil
		local onCar = table.find(saved.extras, extra.id) ~= nil
		local text = if onCar
			then (if on then copy.current else copy.removing)
			else priceText(saved, { extras = { extra.id } }, class, false)
		table.insert(cards, {
			key = extra.id,
			label = extra.displayName,
			priceText = text,
			selected = on,
			saved = onCar,
			-- Off when adding it would go over the limit (swapping within a group is always fine).
			disabled = not on and CustomizeModel.toggleExtra(pending.extras, extra.id, class, bodyStyle) == nil,
		})
	end
	return { cards = cards, note = copy.extrasHint }
end

local function plateView(saved: Look, pending: Look, class: string, input: PanelInput): TabView
	local rules = Customization.plate
	return {
		cardsHeading = copy.plateFormats,
		cards = cardsFor(Customization.plateFormats, "plateFormat", saved, pending, class, function(look: Look): string
			return look.plateFormat
		end),
		plate = {
			allowed = input.plateAllowed,
			maxLength = rules.maxLength,
			rules = rules.allowedDescription .. " " .. copy.plateClearHint,
			lockedNote = copy.plateLocked,
			busy = input.platePending,
		},
	}
end

-- What the panel's body shows for `input.tab`.
function CustomizeModel.tabView(input: PanelInput): TabView
	local saved, pending, class = input.saved, input.pending, input.class
	local tab = input.tab
	if tab == "paint" then
		return paintView(saved, pending, class)
	elseif tab == "finish" then
		return {
			cards = cardsFor(Customization.finishes, "finish", saved, pending, class, function(look: Look): string
				return look.finish
			end),
		}
	elseif tab == "wrap" then
		local wraps = Customization.wrapsFor(input.looks, wrapOf(saved), input.paintOnly)
		return {
			cards = cardsFor(wraps, "wrap", saved, pending, class, wrapOf),
			note = if input.paintOnly == true then copy.paintOnlyWraps else nil,
		}
	elseif tab == "wheels" then
		return {
			cards = cardsFor(Customization.wheels, "wheels", saved, pending, class, function(look: Look): string
				return look.wheels
			end),
		}
	elseif tab == "rideHeight" then
		return stanceView(saved, pending, class)
	elseif tab == "tint" then
		return tintView(saved, pending, class)
	elseif tab == "caliper" then
		return caliperView(saved, pending, class)
	elseif tab == "extras" then
		return extrasView(saved, pending, class, input.bodyStyle)
	elseif tab == "plateFormat" then
		return plateView(saved, pending, class, input)
	end
	return {}
end

-- Everything the panel shows: tabs, the tab's body, the running total and the state of Buy and Reset.
function CustomizeModel.panelView(input: PanelInput): PanelView
	local total = CustomizeModel.totalOf(input.saved, input.pending, input.class)
	local cashNow = input.cash
	local affordable = CustomizeModel.canAfford(total, cashNow)
	if total.hasChanges and not affordable and cashNow ~= nil then
		total.status = string.format(copy.needMore, cash(total.amount - cashNow))
		total.tone = "warning"
	end
	local buying = input.busy and not input.platePending
	local label = if buying then copy.buying elseif total.hasChanges and total.amount <= 0 then copy.apply else copy.buy
	return {
		title = input.title,
		tabs = CustomizeModel.tabs,
		tab = input.tab,
		body = CustomizeModel.tabView(input),
		total = total,
		canReset = total.hasChanges,
		busy = input.busy,
		buy = { label = label, disabled = input.busy or not total.hasChanges or not affordable },
	}
end

-- Layout ------------------------------------------------------------------------------------------------------------

function CustomizeModel.headerHeight(): number
	return layout.headerTop + layout.headerHeight
end

function CustomizeModel.tabsHeight(): number
	return layout.tabsGap + Primitives.chipsHeight()
end

function CustomizeModel.footerHeight(): number
	return layout.footerPad + layout.buttonHeight + layout.footerPad
end

-- The side panel on a screen (unscaled pixels inside the safe area): on the right, full height inside the margins,
-- a share of the width between the min and max (never wider than the screen allows), and how many cards fit
-- across it.
function CustomizeModel.panelLayout(screen: Vector2): PanelRect
	local margin = layout.margin
	local wanted = math.clamp(math.floor(screen.X * layout.widthShare), layout.minWidth, layout.maxWidth)
	local width = math.max(math.min(wanted, screen.X - 2 * margin), 0)
	local height = math.max(screen.Y - 2 * margin, 0)
	local inner = width - 2 * layout.pad
	local columns = math.floor((inner + layout.cardGap) / (layout.cardMinWidth + layout.cardGap))
	return {
		left = screen.X - margin - width,
		top = margin,
		width = width,
		height = height,
		columns = math.clamp(columns, 1, layout.cardMaxColumns),
	}
end

-- How far (studs, to the camera's right) to slide a camera looking at a point `distance` studs away so the point
-- moves from the middle of the screen to the middle of what the panel leaves free, when the panel covers
-- `coveredShare` (0..1) of the screen width on the right. `fieldOfView` is the camera's vertical field of view in
-- degrees and `aspect` the screen's width over its height.
function CustomizeModel.framingShift(
	coveredShare: number,
	fieldOfView: number,
	aspect: number,
	distance: number
): number
	local covered = math.clamp(coveredShare, 0, 1)
	return covered * distance * math.tan(math.rad(fieldOfView) / 2) * aspect
end

-- Bays --------------------------------------------------------------------------------------------------------------

local shopList: { Location } = {}
local shopsById: { [string]: Location } = {}
for _, location in MapLayout.locations do
	if location.tag == SHOP_TAG then
		table.insert(shopList, location)
		shopsById[location.id] = location
	end
end

-- Every Wrap & Tint shop's bay on the map (Config/MapLayout CustomShop locations).
function CustomizeModel.shops(): { Location }
	return shopList
end

-- True when `position` is over the bay's footprint (grown by `slack` studs on every side) and no higher above its
-- floor than Style.bayHeight.
function CustomizeModel.inBay(position: Vector3, bay: Location, slack: number): boolean
	local frame = CFrame.new(bay.position) * CFrame.Angles(0, math.rad(bay.yaw), 0)
	local offset = frame:PointToObjectSpace(position)
	return math.abs(offset.X) <= bay.size.X / 2 + slack
		and math.abs(offset.Z) <= bay.size.Z / 2 + slack
		and offset.Y >= -slack
		and offset.Y <= Style.bayHeight + slack
end

-- The bay `position` stands in, or nil.
function CustomizeModel.bayAt(position: Vector3, slack: number): Location?
	for _, bay in shopList do
		if CustomizeModel.inBay(position, bay, slack) then
			return bay
		end
	end
	return nil
end

-- The bay a triggered prompt belongs to: the first ancestor named after a CustomShop location (MapBuilder names
-- each location part by its id). nil for any other prompt.
function CustomizeModel.bayOfPrompt(prompt: Instance): Location?
	local node = prompt.Parent
	while node ~= nil and node ~= game do
		local bay = shopsById[node.Name]
		if bay ~= nil then
			return bay
		end
		node = node.Parent
	end
	return nil
end

-- True when the prompt sits under a part tagged CustomShop (a shop this client's MapLayout doesn't know of).
function CustomizeModel.isShopPrompt(prompt: Instance): boolean
	local node = prompt.Parent
	while node ~= nil and node ~= game do
		if CollectionService:HasTag(node, SHOP_TAG) then
			return true
		end
		node = node.Parent
	end
	return false
end

-- Plates ------------------------------------------------------------------------------------------------------------

-- Custom plate text as the player types it: capitals, only letters, digits, spaces and dashes, no leading or
-- doubled spaces, at most `maxLength` characters. `final` also trims a trailing space (what gets sent; the server
-- checks it again with Config/Customization's rules and filters it).
function CustomizeModel.cleanPlate(text: string, maxLength: number, final: boolean): string
	local clean = string.upper(text)
	clean = string.gsub(clean, "[^A-Z0-9 %-]", "")
	clean = string.gsub(clean, "^ +", "")
	clean = string.gsub(clean, "  +", " ")
	clean = string.sub(clean, 1, math.max(maxLength, 0))
	if final then
		clean = Customization.normalizePlateText(clean)
	end
	return clean
end

function CustomizeModel.plateMaxLength(): number
	return Customization.plate.maxLength
end

return CustomizeModel
