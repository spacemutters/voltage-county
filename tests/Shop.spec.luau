--!strict
-- The shop sheets' logic (UI/Shop/ShopModel): which shop a "View" prompt opens, stat bars scaled to the whole
-- catalog, trim chips and the opening trim, what the dealership offers each trim (buy, upgrade, or where to get
-- it) with the cash maths, today's used-lot stock from a GetUsedLot reply, remote replies as notices, and the
-- sheet shape and heights for portrait phones, landscape phones and desktop (UI/Shop/ShopSheet.measure); plus
-- the buttons the dealership and used-lot sheets show in each state, and touch-target sizes. Pure logic on the
-- catalog and fixtures: runs in Edit mode.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")

local Catalog = require(ReplicatedStorage.Shared.Vehicle.Catalog)
local Dealership = require(ReplicatedStorage.Shared.Config.Dealership)
local Garage = require(ReplicatedStorage.Shared.Config.Garage)
local Harness = require(ReplicatedStorage.Shared.Testing.Harness)
local Vehicles = require(ReplicatedStorage.Shared.Config.Vehicles)

local Client = StarterPlayer.StarterPlayerScripts.Client
local Theme = require(Client.UI.Theme)
local DealershipSheet = require(Client.UI.Shop.DealershipSheet)
local Primitives = require(Client.UI.Shop.Primitives)
local ShopModel = require(Client.UI.Shop.ShopModel)
local ShopSheet = require(Client.UI.Shop.ShopSheet)
local Style = require(Client.UI.Shop.Style)
local UsedLotSheet = require(Client.UI.Shop.UsedLotSheet)

local TOLERANCE = 1e-9
local KPH_PER_MPH = 1.609344

-- Screens in unscaled pixels inside the safe area.
local PORTRAIT_PHONE = Vector2.new(375, 667)
local LANDSCAPE_PHONE = Vector2.new(667, 375)
local LANDSCAPE_PHONE_TOPBAR = Vector2.new(667, 317) -- what's left under the Roblox top bar
local SMALL_LANDSCAPE = Vector2.new(568, 280)
local DESKTOP = Vector2.new(1536, 830)

local function noop() end

type Pick = { vehicleId: string, trim: Vehicles.Trim, vehicle: Vehicles.Vehicle }

-- The first trim in the catalog (sorted by vehicle id) that passes `test`.
local function findTrim(test: (vehicle: Vehicles.Vehicle, trim: Vehicles.Trim) -> boolean): Pick?
	for _, vehicleId in Catalog.vehicleIds() do
		local vehicle = Catalog.getVehicle(vehicleId)
		if vehicle ~= nil then
			for _, trim in vehicle.trims do
				if test(vehicle, trim) then
					return { vehicleId = vehicleId, trim = trim, vehicle = vehicle }
				end
			end
		end
	end
	return nil
end

local function isBuyable(vehicle: Vehicles.Vehicle, trim: Vehicles.Trim): boolean
	return vehicle.playerDrivable and trim.acquisition == "dealership" and trim.upgradeFrom == nil and trim.price ~= nil
end

local function owned(vehicleId: string, trim: string, uid: string): ShopModel.OwnedSummary
	return { uid = uid, vehicleId = vehicleId, trim = trim }
end

-- A small fixture vehicle for the pure helpers.
local function fixtureTrim(id: string, name: string, stats: { [string]: any }): Vehicles.Trim
	return {
		id = id,
		displayName = name,
		acquisition = "dealership",
		price = 1000,
		topSpeedMph = stats.topSpeedMph or 100,
		zeroToSixtySec = stats.zeroToSixtySec or 5,
		energyMinutes = stats.energyMinutes,
		seats = stats.seats or 4,
		handling = stats.handling or 0.5,
		drive = "RWD",
	}
end

local FIXTURE_GEOMETRY: Vehicles.Geometry = {
	length = 14,
	width = 6,
	height = 4.6,
	wheelbase = 9,
	track = 5,
	wheelRadius = 1.2,
	wheelWidth = 0.8,
	rideHeight = 0.7,
	chassisHeight = 2.4,
}

-- Cast through any: the Vehicle type gains fields as the catalog grows (bodyStyle in Phase 4), and the
-- helpers under test only read the ones below.
local function fixtureVehicle(id: string, name: string, trims: { Vehicles.Trim }): Vehicles.Vehicle
	local vehicle: any = {
		id = id,
		brandId = "ohm",
		displayName = name,
		class = "sedan",
		energy = "battery",
		bodyStyle = "sedan",
		playerDrivable = true,
		geometry = FIXTURE_GEOMETRY,
		features = {},
		trims = trims,
	}
	return vehicle
end

local function actionKeys(content: Primitives.Content): { string }
	local keys = {}
	for _, action in content.actions do
		table.insert(keys, action.key)
	end
	return keys
end

local function actionNamed(content: Primitives.Content, key: string): Primitives.Action?
	for _, action in content.actions do
		if action.key == key then
			return action
		end
	end
	return nil
end

local function hasSection(sections: { Primitives.Section }, key: string): boolean
	for _, section in sections do
		if section.key == key then
			return true
		end
	end
	return false
end

local function dealership(pick: Pick, overrides: { [string]: any }?): Primitives.Content
	local props: DealershipSheet.Props = {
		vehicleId = pick.vehicleId,
		trimId = pick.trim.id,
		snapshot = nil,
		cash = nil,
		units = "mph",
		busy = nil,
		testDriveSeconds = 120,
		onPickTrim = function(_trimId: string) end,
		onBuy = noop,
		onUpgrade = noop,
		onTestDrive = noop,
	}
	local changes: { [string]: any } = overrides or {}
	for key, value in changes do
		(props :: any)[key] = value
	end
	return DealershipSheet.content(props)
end

local function usedLot(overrides: { [string]: any }): Primitives.Content
	local props: UsedLotSheet.Props = {
		slot = 1,
		state = "loading",
		entry = nil,
		starterClaimed = nil,
		snapshot = nil,
		cash = nil,
		units = "mph",
		busy = nil,
		onBuy = noop,
		onClaim = noop,
		onRetry = noop,
	}
	for key, value in overrides do
		(props :: any)[key] = value
	end
	return UsedLotSheet.content(props)
end

return function(t: Harness.Api)
	local buy = findTrim(isBuyable)
	local upgrade = findTrim(function(_vehicle, trim)
		return trim.acquisition == "dealership" and trim.upgradeFrom ~= nil and trim.price ~= nil
	end)
	local elsewhere = findTrim(function(_vehicle, trim)
		return trim.acquisition ~= "dealership"
	end)

	t.describe("Shop stat bars", function()
		t.it("finds each stat's range over every trim, skipping missing range", function()
			local ranges = ShopModel.rangesOf({
				a = fixtureVehicle("a", "Alpha One", {
					fixtureTrim("x", "One", { topSpeedMph = 90, zeroToSixtySec = 7, energyMinutes = 20, seats = 2 }),
					fixtureTrim("y", "One Fast", { topSpeedMph = 150, zeroToSixtySec = 3, seats = 5, handling = 0.8 }),
				}),
				b = fixtureVehicle("b", "Beta", {
					fixtureTrim("z", "Beta", { topSpeedMph = 120, energyMinutes = 40, handling = 0.3 }),
				}),
			})
			t.expect(ranges.topSpeedMph).toEqual({ min = 90, max = 150 })
			t.expect(ranges.zeroToSixtySec).toEqual({ min = 3, max = 7 })
			t.expect(ranges.energyMinutes).toEqual({ min = 20, max = 40 })
			t.expect(ranges.handling).toEqual({ min = 0.3, max = 0.8 })
			t.expect(ranges.seats).toEqual({ min = 2, max = 5 })
		end)

		t.it("falls back to 0..1 when no trim has a stat", function()
			local ranges = ShopModel.rangesOf({
				a = fixtureVehicle("a", "Alpha", { fixtureTrim("x", "Alpha", {}) }),
			})
			t.expect(ranges.energyMinutes).toEqual({ min = 0, max = 1 })
		end)

		t.it("fills from a sliver at the minimum to full at the maximum", function()
			local range = { min = 10, max = 20 }
			t.expect(ShopModel.fraction(10, range, false, 0.1)).toBeNear(0.1, TOLERANCE)
			t.expect(ShopModel.fraction(20, range, false, 0.1)).toBeNear(1, TOLERANCE)
			t.expect(ShopModel.fraction(15, range, false, 0)).toBeNear(0.5, TOLERANCE)
		end)

		t.it("flips stats where lower is better", function()
			local range = { min = 2, max = 10 }
			t.expect(ShopModel.fraction(2, range, true, 0)).toBeNear(1, TOLERANCE)
			t.expect(ShopModel.fraction(10, range, true, 0)).toBeNear(0, TOLERANCE)
		end)

		t.it("clamps values outside the range and reads a range with no spread as full", function()
			t.expect(ShopModel.fraction(50, { min = 10, max = 20 }, false, 0)).toBeNear(1, TOLERANCE)
			t.expect(ShopModel.fraction(-5, { min = 10, max = 20 }, false, 0)).toBeNear(0, TOLERANCE)
			t.expect(ShopModel.fraction(4, { min = 4, max = 4 }, true, 0)).toBeNear(1, TOLERANCE)
		end)

		t.it("gives every catalog trim its stats in order, with bars between 0 and 1", function()
			for _, vehicleId in Catalog.vehicleIds() do
				local vehicle = Catalog.getVehicle(vehicleId)
				local trims: { Vehicles.Trim } = if vehicle then vehicle.trims else {}
				for _, trim in trims do
					local rows = ShopModel.stats(vehicleId, trim.id, "mph")
					t.expect(#rows).toBe(#ShopModel.statIds)
					for index, row in rows do
						t.expect(row.id).toBe(ShopModel.statIds[index])
						t.expect(row.fraction >= 0 and row.fraction <= 1).toBe(true)
						t.expect(row.value ~= "").toBe(true)
					end
				end
			end
		end)

		t.it("fills the 0-60 bar for the quickest car in the catalog", function()
			local quickest = findTrim(function(_vehicle, trim)
				return trim.zeroToSixtySec == ShopModel.ranges().zeroToSixtySec.min
			end)
			t.expect(quickest ~= nil).toBe(true)
			if quickest then
				local rows = ShopModel.stats(quickest.vehicleId, quickest.trim.id, "mph")
				t.expect(rows[2].id).toBe("zeroToSixty")
				t.expect(rows[2].fraction).toBeNear(1, TOLERANCE)
			end
		end)

		t.it("shows top speed in the player's units", function()
			t.expect(buy ~= nil).toBe(true)
			if buy then
				local mph = ShopModel.stats(buy.vehicleId, buy.trim.id, "mph")[1].value
				local kph = ShopModel.stats(buy.vehicleId, buy.trim.id, "kph")[1].value
				t.expect(mph).toBe(string.format(Style.copy.units.mph, math.round(buy.trim.topSpeedMph)))
				t.expect(kph).toBe(string.format(Style.copy.units.kph, math.round(buy.trim.topSpeedMph * KPH_PER_MPH)))
			end
		end)

		t.it("has no stats for an unknown trim", function()
			t.expect(#ShopModel.stats("no_such_car", "standard", "mph")).toBe(0)
		end)
	end)

	t.describe("Shop trims", function()
		local vehicle = fixtureVehicle("a", "Ohm Spark", {})

		t.it("drops the model name from chip labels when the rest still means something", function()
			t.expect(ShopModel.chipLabel(vehicle, fixtureTrim("lr", "Spark Long Range", {}))).toBe("Long Range")
			t.expect(ShopModel.chipLabel(vehicle, fixtureTrim("p", "Spark Performance", {}))).toBe("Performance")
			t.expect(ShopModel.chipLabel(vehicle, fixtureTrim("s", "Spark", {}))).toBe("Spark")
			t.expect(ShopModel.chipLabel(vehicle, fixtureTrim("u", "Spark (used)", {}))).toBe("Spark (used)")
			t.expect(ShopModel.chipLabel(vehicle, fixtureTrim("o", "Other Name", {}))).toBe("Other Name")
		end)

		t.it("opens on a trim sold at the dealership", function()
			for _, vehicleId in Catalog.vehicleIds() do
				local car = Catalog.getVehicle(vehicleId)
				local hasBuyable = false
				local trims: { Vehicles.Trim } = if car then car.trims else {}
				for _, trim in trims do
					if trim.acquisition == "dealership" and trim.upgradeFrom == nil and trim.price ~= nil then
						hasBuyable = true
					end
				end
				local opening = ShopModel.initialTrim(vehicleId, nil)
				t.expect(opening ~= nil).toBe(true)
				if hasBuyable and opening then
					local trim = Catalog.getTrim(vehicleId, opening)
					t.expect(trim ~= nil and trim.acquisition == "dealership" and trim.upgradeFrom == nil).toBe(true)
				end
			end
		end)

		t.it("keeps the display car's trim when it is sold here and replaces it when it isn't", function()
			if buy then
				t.expect(ShopModel.initialTrim(buy.vehicleId, buy.trim.id)).toBe(buy.trim.id)
			end
			local starter = findTrim(function(_vehicle, trim)
				return trim.acquisition == "starter"
			end)
			if starter then
				local opening = ShopModel.initialTrim(starter.vehicleId, starter.trim.id)
				t.expect(opening ~= starter.trim.id).toBe(true)
			end
			t.expect(ShopModel.initialTrim("no_such_car", nil)).toBe(nil)
		end)
	end)

	t.describe("Shop offers", function()
		t.it("matches every catalog trim's acquisition", function()
			for _, vehicleId in Catalog.vehicleIds() do
				local vehicle = Catalog.getVehicle(vehicleId)
				local trims: { Vehicles.Trim } = if vehicle then vehicle.trims else {}
				for _, trim in trims do
					local offer = ShopModel.offer(vehicleId, trim.id, nil, nil)
					if trim.acquisition ~= "dealership" or trim.price == nil then
						t.expect(offer.kind).toBe("elsewhere")
						t.expect(type(offer.how) == "string" and offer.how ~= "").toBe(true)
						t.expect(offer.canTestDrive).toBe(false)
					elseif trim.upgradeFrom ~= nil then
						t.expect(offer.kind).toBe("upgradeLocked")
						t.expect(offer.price).toBe(trim.price)
					else
						t.expect(offer.kind).toBe("buy")
						t.expect(offer.price).toBe(Catalog.totalPrice(vehicleId, trim.id))
					end
				end
			end
		end)

		t.it("works out the cash left after, or the cash still needed", function()
			t.expect(buy ~= nil).toBe(true)
			if buy == nil then
				return
			end
			local price = Catalog.totalPrice(buy.vehicleId, buy.trim.id) :: number
			local exact = ShopModel.offer(buy.vehicleId, buy.trim.id, nil, price)
			t.expect(exact.cashAfter).toBe(0)
			t.expect(exact.shortBy).toBe(nil)

			local short = ShopModel.offer(buy.vehicleId, buy.trim.id, nil, price - 1)
			t.expect(short.cashAfter).toBe(-1)
			t.expect(short.shortBy).toBe(1)

			local unknown = ShopModel.offer(buy.vehicleId, buy.trim.id, nil, nil)
			t.expect(unknown.cashAfter).toBe(nil)
			t.expect(unknown.shortBy).toBe(nil)
		end)

		t.it("sees a full garage and counts the cars of this trim the player owns", function()
			if buy == nil then
				return
			end
			local snapshot: ShopModel.Snapshot = {
				cash = 0,
				garageSlots = 2,
				vehicles = {
					owned(buy.vehicleId, buy.trim.id, "a"),
					owned(buy.vehicleId, buy.trim.id, "b"),
				},
			}
			local offer = ShopModel.offer(buy.vehicleId, buy.trim.id, snapshot, 0)
			t.expect(offer.garageFull).toBe(true)
			t.expect(offer.ownedCount).toBe(2)
			snapshot.garageSlots = 6
			t.expect(ShopModel.offer(buy.vehicleId, buy.trim.id, snapshot, 0).garageFull).toBe(false)
			t.expect(ShopModel.garageFull(nil)).toBe(false)
		end)

		t.it("doesn't count player designs against the garage", function()
			local snapshot: ShopModel.Snapshot = {
				garageSlots = 1,
				vehicles = { owned(Garage.customVehicleId, "custom", "design") },
			}
			t.expect(ShopModel.garageFull(snapshot)).toBe(false)
		end)

		t.it("offers an upgrade only to a player who owns the trim it upgrades", function()
			if upgrade == nil then
				return -- the catalog has no upgrade trims right now
			end
			local baseId = upgrade.trim.upgradeFrom :: string
			local without = ShopModel.offer(upgrade.vehicleId, upgrade.trim.id, { vehicles = {} }, nil)
			t.expect(without.kind).toBe("upgradeLocked")
			t.expect(without.upgradeUid).toBe(nil)

			local snapshot: ShopModel.Snapshot = {
				cash = upgrade.trim.price,
				garageSlots = 1,
				vehicles = { owned(upgrade.vehicleId, baseId, "base-car") },
			}
			local with = ShopModel.offer(upgrade.vehicleId, upgrade.trim.id, snapshot, upgrade.trim.price)
			t.expect(with.kind).toBe("upgrade")
			t.expect(with.upgradeUid).toBe("base-car")
			t.expect(with.cashAfter).toBe(0)
			-- An upgrade changes a car the player has, so a full garage doesn't stop it.
			t.expect(with.garageFull).toBe(false)
		end)

		t.it("says where to get trims that aren't sold here", function()
			if elsewhere then
				local offer = ShopModel.offer(elsewhere.vehicleId, elsewhere.trim.id, nil, 1000000)
				t.expect(offer.kind).toBe("elsewhere")
				t.expect(offer.price).toBe(nil)
			end
			t.expect(ShopModel.offer("no_such_car", "standard", nil, nil).kind).toBe("elsewhere")
		end)
	end)

	t.describe("Shop used lot", function()
		local first = Catalog.vehicleIds()[1]
		local firstTrim = (Catalog.defaultTrim(first) :: Vehicles.Trim).id

		t.it("reads a plain list or a reply with a stock list, sorted by slot", function()
			local list: { any } = {
				{ slot = 2, vehicleId = first, trim = firstTrim, price = 2000, supply = 5, sold = 1 },
				{ slot = 1, vehicleId = first, trim = firstTrim, basePrice = 1000, remaining = 3 },
			}
			for _, reply in { list, { ok = true, message = "", stock = list } } do
				local entries = ShopModel.normalizeLot(reply)
				t.expect(entries ~= nil).toBe(true)
				if entries then
					t.expect(#entries).toBe(2)
					t.expect(entries[1].slot).toBe(1)
					t.expect(entries[1].price).toBe(1000) -- falls back to the base price
					t.expect(entries[1].remaining).toBe(3)
					t.expect(entries[2].remaining).toBe(4) -- supply - sold
					t.expect(entries[2].price).toBe(2000)
				end
			end
		end)

		t.it("skips entries it can't use", function()
			local reply: { any } = {
				{ slot = 1.5, vehicleId = first, trim = firstTrim, price = 10 },
				{ slot = 2, vehicleId = "no_such_car", trim = "standard", price = 10 },
				{ slot = 3, vehicleId = first, trim = firstTrim },
				{ slot = 4, vehicleId = first, trim = firstTrim, price = 10, remaining = -2 },
				"junk",
			}
			local entries = ShopModel.normalizeLot(reply)
			t.expect(entries ~= nil and #entries).toBe(1)
			if entries then
				t.expect(entries[1].slot).toBe(4)
				t.expect(entries[1].remaining).toBe(0)
			end
		end)

		t.it("prices a sold-out space at its base price, not 0", function()
			local list: { any } = {
				{ slot = 1, vehicleId = first, trim = firstTrim, basePrice = 900, price = 0, remaining = 0 },
			}
			local entries = ShopModel.normalizeLot({ ok = true, message = "", stock = list })
			t.expect(entries ~= nil and entries[1].price).toBe(900)
		end)

		t.it("reads the starter claim from a GetUsedLot reply", function()
			t.expect(ShopModel.lotStarterClaimed({ ok = true, starterClaimed = false })).toBe(false)
			t.expect(ShopModel.lotStarterClaimed({ ok = true, starterClaimed = true })).toBe(true)
			t.expect(ShopModel.lotStarterClaimed({ ok = true })).toBe(nil)
			t.expect(ShopModel.lotStarterClaimed(nil)).toBe(nil)
		end)

		t.it("passes on the server's no, and gives nothing for a turned-away call", function()
			local entries, message = ShopModel.normalizeLot({ ok = false, message = "Closed today." })
			t.expect(entries).toBe(nil)
			t.expect(message).toBe("Closed today.")
			t.expect((ShopModel.normalizeLot(nil))).toBe(nil)
		end)

		t.it("finds a space and words what's left", function()
			local entries = ShopModel.normalizeLot({ { slot = 3, vehicleId = first, trim = firstTrim, price = 5 } })
			t.expect(ShopModel.lotEntry(entries, 3) ~= nil).toBe(true)
			t.expect(ShopModel.lotEntry(entries, 4)).toBe(nil)
			t.expect(ShopModel.lotEntry(nil, 3)).toBe(nil)
			t.expect(ShopModel.remainingText(nil)).toBe(nil)
			t.expect(ShopModel.remainingText(0)).toBe(Style.copy.soldOut)
			t.expect(ShopModel.remainingText(3)).toBe(string.format(Style.copy.left, 3))
		end)
	end)

	t.describe("Shop prompt targets", function()
		local vehicleId = Catalog.vehicleIds()[1]
		local view = Dealership.prompt

		-- A display car: Model (VehicleId, Trim) > Part > ProximityPrompt. Destroyed after each check.
		local function displayCar(promptName: string, actionText: string): (Model, ProximityPrompt)
			local model = Instance.new("Model")
			model:SetAttribute(view.vehicleIdAttribute, vehicleId)
			model:SetAttribute(view.trimAttribute, "standard")
			local part = Instance.new("Part")
			part.Parent = model
			local prompt = Instance.new("ProximityPrompt")
			prompt.Name = promptName
			prompt.ActionText = actionText
			prompt.Parent = part
			return model, prompt
		end

		t.it("opens the dealership for a display car's VehicleId and Trim", function()
			local model, prompt = displayCar(view.name, view.actionText)
			local target = ShopModel.targetOf(prompt)
			model:Destroy()
			t.expect(target).toEqual({ kind = "dealership", vehicleId = vehicleId, trim = "standard" })
		end)

		t.it("opens the used lot when there is a Slot, even on a vehicle model", function()
			local model, prompt = displayCar(view.name, view.actionText)
			prompt:SetAttribute(view.slotAttribute, 4)
			local target = ShopModel.targetOf(prompt)
			model:Destroy()
			t.expect(target).toEqual({ kind = "usedLot", slot = 4 })
		end)

		t.it("knows a View prompt by its name or its action text", function()
			local byText, textPrompt = displayCar("SomePrompt", view.actionText)
			local byName, namePrompt = displayCar(view.name, "Look")
			local fromText, fromName = ShopModel.targetOf(textPrompt), ShopModel.targetOf(namePrompt)
			byText:Destroy()
			byName:Destroy()
			t.expect(fromText ~= nil).toBe(true)
			t.expect(fromName ~= nil).toBe(true)
		end)

		t.it("ignores other prompts and broken attributes", function()
			local model, prompt = displayCar("Drive", "Drive")
			t.expect(ShopModel.targetOf(prompt)).toBe(nil)
			prompt.Name = view.name
			prompt:SetAttribute(view.slotAttribute, 0)
			t.expect(ShopModel.targetOf(prompt)).toBe(nil)
			prompt:SetAttribute(view.slotAttribute, 2.5)
			t.expect(ShopModel.targetOf(prompt)).toBe(nil)
			prompt:SetAttribute(view.slotAttribute, nil)
			model:SetAttribute(view.vehicleIdAttribute, "no_such_car")
			t.expect(ShopModel.targetOf(prompt)).toBe(nil)
			model:Destroy()
		end)
	end)

	t.describe("Shop replies", function()
		-- (ok, message, kind) for a call and its reply.
		local function check(called: boolean, reply: any, ok: boolean, message: string, kind: string)
			local gotOk, gotMessage, gotKind = ShopModel.outcome(called, reply)
			t.expect(gotOk).toBe(ok)
			t.expect(gotMessage).toBe(message)
			t.expect(gotKind).toBe(kind)
		end

		t.it("shows the server's message with a kind that matches the answer", function()
			check(true, { ok = true, message = "Enjoy!" }, true, "Enjoy!", "success")
			check(true, { ok = false, message = "Too pricey." }, false, "Too pricey.", "error")
		end)

		t.it("fills in a message when the server sent none, the call failed or was turned away", function()
			check(true, { ok = true }, true, Style.copy.done, "success")
			check(true, { ok = false }, false, Style.copy.failed, "error")
			check(false, "error text", false, Style.copy.failed, "error")
			check(true, nil, false, Style.copy.tryLater, "warning")
		end)
	end)

	t.describe("Shop layout", function()
		t.it("uses a full-width bottom sheet on portrait phones", function()
			local layout = ShopModel.layoutFor(PORTRAIT_PHONE)
			t.expect(layout.mode).toBe("sheet")
			t.expect(layout.width).toBe(PORTRAIT_PHONE.X)
			t.expect(layout.maxHeight).toBe(math.floor(PORTRAIT_PHONE.Y * Theme.size.sheetMaxHeightScale))
		end)

		t.it("uses a wide two-column card on landscape phones", function()
			for _, screen in { LANDSCAPE_PHONE, LANDSCAPE_PHONE_TOPBAR, SMALL_LANDSCAPE } do
				local layout = ShopModel.layoutFor(screen)
				t.expect(layout.mode).toBe("wide")
				t.expect(layout.width <= screen.X - 2 * Style.layout.margin).toBe(true)
				t.expect(layout.asideWidth >= Style.layout.asideMinWidth).toBe(true)
				t.expect(layout.asideWidth < layout.width).toBe(true)
			end
		end)

		t.it("uses a centered card on desktop", function()
			local layout = ShopModel.layoutFor(DESKTOP)
			t.expect(layout.mode).toBe("card")
			t.expect(layout.width).toBe(Theme.size.sheetMaxWidth)
		end)

		t.it("keeps the dealership's buttons on screen at every size", function()
			if buy == nil then
				return
			end
			local content = dealership(buy, { cash = 0, snapshot = { cash = 0, garageSlots = 6, vehicles = {} } })
			t.expect(#content.actions > 0).toBe(true)
			for _, screen in { PORTRAIT_PHONE, LANDSCAPE_PHONE, LANDSCAPE_PHONE_TOPBAR, SMALL_LANDSCAPE, DESKTOP } do
				local layout = ShopModel.layoutFor(screen)
				local metrics = ShopSheet.measure(content, layout)
				t.expect(metrics.height <= layout.maxHeight).toBe(true)
				t.expect(metrics.footer > 0).toBe(true)
				-- The header and the button row fit with room to spare for the body.
				t.expect(metrics.body - (if layout.mode == "wide" then metrics.footer else 0) > 0).toBe(true)
				t.expect(metrics.header + metrics.body + (if layout.mode == "wide" then 0 else metrics.footer))
					.toBe(metrics.height)
			end
		end)

		t.it("fits a short sheet to its content without scrolling", function()
			local content: Primitives.Content = {
				eyebrow = "",
				title = "",
				subtitle = nil,
				main = { Primitives.statusSection("Status", "") },
				summary = {},
				actions = {},
			}
			local metrics = ShopSheet.measure(content, ShopModel.layoutFor(DESKTOP))
			t.expect(metrics.overflow).toBe(false)
			t.expect(metrics.body).toBe(Style.layout.statusHeight + Style.layout.pad)
		end)

		t.it("keeps every tappable size at least a touch target", function()
			local minimum = Theme.size.touchTarget
			t.expect(Style.layout.chipHeight >= minimum).toBe(true)
			t.expect(Style.layout.closeSize >= minimum).toBe(true)
			t.expect(Style.layout.buttonHeight >= minimum).toBe(true)
		end)
	end)

	t.describe("Shop sheet buttons", function()
		t.it("offers Test drive and Buy, with Buy off when the cash is short", function()
			if buy == nil then
				return
			end
			local price = Catalog.totalPrice(buy.vehicleId, buy.trim.id) :: number
			local rich = dealership(buy, { cash = price })
			t.expect(actionKeys(rich)).toEqual({ "TestDrive", "Buy" })
			t.expect((actionNamed(rich, "Buy") :: Primitives.Action).disabled).toBe(false)
			t.expect((actionNamed(rich, "TestDrive") :: Primitives.Action).disabled).toBe(false)

			local poor = dealership(buy, { cash = price - 1 })
			t.expect((actionNamed(poor, "Buy") :: Primitives.Action).disabled).toBe(true)
		end)

		t.it("turns every button off while a call is in flight", function()
			if buy == nil then
				return
			end
			local content = dealership(buy, { cash = 1e9, busy = "buy" })
			for _, action in content.actions do
				t.expect(action.disabled).toBe(true)
			end
			t.expect((actionNamed(content, "Buy") :: Primitives.Action).label).toBe(Style.copy.buying)
		end)

		t.it("shows a note instead of Buy for trims sold elsewhere", function()
			if elsewhere == nil then
				return
			end
			local content = dealership(elsewhere)
			t.expect(actionNamed(content, "Buy")).toBe(nil)
			t.expect(hasSection(content.summary, "Note")).toBe(true)
		end)

		t.it("shows the free-starter claim only while it hasn't been claimed", function()
			t.expect(hasSection(usedLot({ starterClaimed = false }).main, "Claim")).toBe(true)
			t.expect(hasSection(usedLot({ starterClaimed = true }).main, "Claim")).toBe(false)
			t.expect(hasSection(usedLot({ starterClaimed = nil }).main, "Claim")).toBe(false)
		end)

		t.it("waits while loading, offers a retry when loading failed, and stops at sold out", function()
			local loading = usedLot({ state = "loading" })
			t.expect((actionNamed(loading, "Buy") :: Primitives.Action).disabled).toBe(true)

			local failed = usedLot({ state = "failed" })
			t.expect(actionKeys(failed)).toEqual({ "Retry" })

			local first = Catalog.vehicleIds()[1]
			local entry: ShopModel.LotEntry = {
				slot = 1,
				vehicleId = first,
				trim = (Catalog.defaultTrim(first) :: Vehicles.Trim).id,
				price = 100,
				basePrice = 100,
				remaining = 0,
				supply = 4,
			}
			local soldOut = usedLot({ state = "ready", entry = entry, cash = 1000 })
			local soldOutBuy = actionNamed(soldOut, "Buy") :: Primitives.Action
			t.expect(soldOutBuy.disabled).toBe(true)
			t.expect(soldOutBuy.label).toBe(Style.copy.soldOut)

			entry.remaining = 2
			local inStock = usedLot({ state = "ready", entry = entry, cash = 1000 })
			t.expect((actionNamed(inStock, "Buy") :: Primitives.Action).disabled).toBe(false)
		end)

		t.it("keeps the same height from loading to loaded, so the sheet doesn't jump", function()
			local first = Catalog.vehicleIds()[1]
			local entry: ShopModel.LotEntry = {
				slot = 1,
				vehicleId = first,
				trim = (Catalog.defaultTrim(first) :: Vehicles.Trim).id,
				price = 100,
				basePrice = 100,
				remaining = 2,
				supply = 4,
			}
			local loading = usedLot({ state = "loading" })
			local loaded = usedLot({ state = "ready", entry = entry, cash = 1000 })
			for _, screen in { PORTRAIT_PHONE, LANDSCAPE_PHONE, DESKTOP } do
				local layout = ShopModel.layoutFor(screen)
				local before = ShopSheet.measure(loading, layout)
				local after = ShopSheet.measure(loaded, layout)
				t.expect(before.height).toBe(after.height)
			end
		end)
	end)
end
