--!strict
-- The Wrap & Tint shop's server rules (Services/CustomizationService pure helpers; docs/phase-7-contracts.md
-- "CustomizationService", "Plates" and "Schema v5"): validating and pricing a change set (only what differs is
-- charged; unknown ids, off-step numbers and extras a class can't take are refused), saving a look without
-- touching the raw plate text, where the shop works, the plate text rules and who may set custom text, and the
-- two CustomShop locations in MapLayout. Pure logic on fixtures: runs in Edit mode.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Catalog = require(ReplicatedStorage.Shared.Vehicle.Catalog)
local Classes = require(ReplicatedStorage.Shared.Config.Classes)
local Customization = require(ReplicatedStorage.Shared.Config.Customization)
local Data = require(ReplicatedStorage.Shared.Config.Data)
local Harness = require(ReplicatedStorage.Shared.Testing.Harness)
local MapLayout = require(ReplicatedStorage.Shared.Config.MapLayout)
local Types = require(ReplicatedStorage.Shared.Types)
local CustomizationService = require(ServerScriptService.Server.Services.CustomizationService)
local Template = require(ServerScriptService.Server.Services.DataService.Template)

local JOIN_TIME = 1700000000 -- any fixed os.time()
local VEHICLE_ID = "ohm_spark"
local TRIM = "standard"

local function car(): Types.OwnedVehicle
	return Template.ownedVehicle("car-1", VEHICLE_ID, TRIM, 35000, JOIN_TIME)
end

local function classOf(vehicleId: string): string
	local vehicle = Catalog.getVehicle(vehicleId)
	assert(vehicle, `{vehicleId} is in the catalog`)
	return vehicle.class
end

-- The first palette paint that isn't `except`.
local function otherPaint(except: string): string
	for _, paint in Customization.paints do
		if paint.id ~= except then
			return paint.id
		end
	end
	error("the palette has only one paint")
end

-- An extra and a class that may not take it (nil when every extra fits every class).
local function extraNotFor(): (string?, string?)
	for _, extra in Customization.extras do
		for classId in Classes do
			if not Customization.extraAllowed(extra.id, classId) then
				return extra.id, classId
			end
		end
	end
	return nil, nil
end

-- A situation where the shop works; specs knock out one thing at a time.
local function usable(): CustomizationService.Situation
	return {
		hasCar = true,
		testDrive = false,
		ownedUid = "car-1",
		owned = true,
		inDriverSeat = true,
		inShop = true,
	}
end

return function(t: Harness.Api)
	t.describe("CustomizationService", function()
		t.it("builds a look from a saved car and never copies its raw plate text", function()
			local vehicle = car()
			vehicle.plateText = "RAW TEXT"
			local look = CustomizationService.lookOf(vehicle, nil)
			t.expect(look.uid).toBe("car-1")
			t.expect(look.paint).toBe(vehicle.paint)
			t.expect(look.caliper).toBe(Customization.defaults.caliper)
			t.expect(look.plateFormat).toBe(Customization.defaults.plateFormat)
			t.expect(look.plateText).toBe(nil)
			t.expect(look.extras == vehicle.extras).toBe(false) -- a copy
			t.expect(CustomizationService.lookOf(vehicle, "FILTERED").plateText).toBe("FILTERED")
			t.expect(CustomizationService.lookOf(vehicle, "").plateText).toBe("")
		end)

		t.it("fills damaged look fields from Config/Customization defaults", function()
			local damaged: any = car()
			damaged.paint = 7
			damaged.rideHeight = 0 / 0
			damaged.extras = { "roof_rack", 3, false } :: { any }
			damaged.caliper = nil
			local look = CustomizationService.lookOf(damaged, nil)
			t.expect(look.paint).toBe(Customization.defaults.paint)
			t.expect(look.rideHeight).toBe(Customization.defaults.rideHeight)
			t.expect(look.extras).toEqual({ "roof_rack" })
			t.expect(look.caliper).toBe(Customization.defaults.caliper)
		end)

		t.it("a new car's look is all valid shop values (template, Data defaults and the catalog agree)", function()
			local look = CustomizationService.lookOf(car(), nil)
			local ok, problem = Customization.check({
				paint = look.paint,
				finish = look.finish,
				wheels = look.wheels,
				rideHeight = look.rideHeight,
				tint = look.tint,
				caliper = look.caliper,
				extras = look.extras,
				plateFormat = look.plateFormat,
			}, classOf(VEHICLE_ID))
			t.expect(problem).toBe(nil)
			t.expect(ok).toBe(true)
			t.expect(Data.defaults.vehicleLook.caliper).toBe(Customization.defaults.caliper)
			t.expect(Data.defaults.vehicleLook.plateFormat).toBe(Customization.defaults.plateFormat)
		end)

		t.it("prices only what differs from the saved look", function()
			local vehicle = car()
			local class = classOf(VEHICLE_ID)
			local paint = otherPaint(vehicle.paint)
			local ok, problem, cost, after = CustomizationService.validate(vehicle, class, {
				paint = paint,
				finish = vehicle.finish, -- unchanged: free
				wheels = vehicle.wheels, -- unchanged: free
			})
			t.expect(problem).toBe(nil)
			t.expect(ok).toBe(true)
			t.expect(cost).toBe(Customization.scaledPrice(Customization.paintPrice, class))
			t.expect(cost > 0).toBe(true)
			assert(after, "a look comes back")
			t.expect(after.paint).toBe(paint)
			t.expect(after.finish).toBe(vehicle.finish)
		end)

		t.it("refuses a change set that changes nothing", function()
			local vehicle = car()
			local ok, problem, cost = CustomizationService.validate(vehicle, classOf(VEHICLE_ID), {
				paint = vehicle.paint,
				tint = vehicle.tint,
			})
			t.expect(ok).toBe(false)
			t.expect(problem).toBe(Customization.messages.nothingChanged)
			t.expect(cost).toBe(0)
			local empty = CustomizationService.validate(vehicle, classOf(VEHICLE_ID), {})
			t.expect(empty).toBe(false)
		end)

		t.it("refuses unknown ids and off-step numbers", function()
			local vehicle = car()
			local class = classOf(VEHICLE_ID)
			local cases: { { changes: CustomizationService.Changes, message: string } } = {
				{ changes = { paint = "not_a_paint" }, message = Customization.messages.unknownPaint },
				{ changes = { finish = "chrome_glitter" }, message = Customization.messages.unknownFinish },
				{ changes = { wrap = "not_a_wrap" }, message = Customization.messages.unknownWrap },
				{ changes = { wheels = "not_wheels" }, message = Customization.messages.unknownWheels },
				{ changes = { rideHeight = 0.3 }, message = Customization.messages.badRideHeight },
				{ changes = { tint = 0.6 }, message = Customization.messages.badTint },
				{ changes = { caliper = "gold_leaf" }, message = Customization.messages.unknownCaliper },
				{ changes = { extras = { "jet_engine" } }, message = Customization.messages.unknownExtra },
				{ changes = { plateFormat = "real_state" }, message = Customization.messages.unknownPlate },
			}
			for _, case in cases do
				local ok, problem, cost = CustomizationService.validate(vehicle, class, case.changes)
				t.expect(ok).toBe(false)
				t.expect(problem).toBe(case.message)
				t.expect(cost).toBe(0)
			end
		end)

		t.it("refuses an extra the car's class can't take", function()
			local extraId, classId = extraNotFor()
			if extraId == nil or classId == nil then
				return -- every extra fits every class: nothing to refuse
			end
			local ok, problem = CustomizationService.validate(car(), classId, { extras = { extraId } })
			t.expect(ok).toBe(false)
			t.expect(problem).toBe(Customization.messages.extraNotForClass)
		end)

		t.it("refuses a custom color outside the limits and stores a valid one as a custom paint id", function()
			local vehicle = car()
			local class = classOf(VEHICLE_ID)
			local limits = Customization.customColor
			local neon = CustomizationService.validate(
				vehicle,
				class,
				{ customColor = { h = 0.3, s = math.min(1, limits.maxSaturation + 0.1), v = 0.9 } }
			)
			if limits.maxSaturation < 1 then
				t.expect(neon).toBe(false)
			end
			local ok, _, cost, after =
				CustomizationService.validate(vehicle, class, { customColor = { h = 0.55, s = 0.5, v = 0.6 } })
			t.expect(ok).toBe(true)
			t.expect(cost).toBe(Customization.scaledPrice(limits.price, class))
			assert(after, "a look comes back")
			t.expect(Customization.parseCustomPaint(after.paint) ~= nil).toBe(true)
		end)

		t.it("lets free changes through at no cost (plate formats, removing extras)", function()
			local vehicle = car()
			local class = classOf(VEHICLE_ID)
			local other: string? = nil
			for _, format in Customization.plateFormats do
				if format.id ~= vehicle.plateFormat then
					other = format.id
					break
				end
			end
			assert(other, "there is a second plate format")
			local ok, _, cost = CustomizationService.validate(vehicle, class, { plateFormat = other })
			t.expect(ok).toBe(true)
			t.expect(cost).toBe(0)

			local fitting = Customization.extrasFor(class)
			if #fitting > 0 then
				vehicle.extras = { fitting[1].id }
				local removed, _, removeCost = CustomizationService.validate(vehicle, class, { extras = {} })
				t.expect(removed).toBe(true)
				t.expect(removeCost).toBe(0)
			end
		end)

		t.it("charges each new extra once and nothing for extras already fitted", function()
			local vehicle = car()
			local class = classOf(VEHICLE_ID)
			local fitting = Customization.extrasFor(class)
			if #fitting == 0 then
				return
			end
			local first = fitting[1]
			local ok, _, cost = CustomizationService.validate(vehicle, class, { extras = { first.id } })
			t.expect(ok).toBe(true)
			t.expect(cost).toBe(Customization.scaledPrice(first.price, class))
			vehicle.extras = { first.id }
			local again = CustomizationService.validate(vehicle, class, { extras = { first.id } })
			t.expect(again).toBe(false) -- nothing changed
		end)

		t.it("saves a look's fields and leaves plate text, energy and ownership alone", function()
			local vehicle = car()
			vehicle.plateText = "VOLT 1"
			vehicle.energy = 0.4
			local class = classOf(VEHICLE_ID)
			local ok, _, _, after = CustomizationService.validate(vehicle, class, {
				paint = otherPaint(vehicle.paint),
				tint = Customization.tint.levels[#Customization.tint.levels].value,
				rideHeight = Customization.rideHeight.min,
			})
			t.expect(ok).toBe(true)
			assert(after, "a look comes back")
			CustomizationService.saveLook(vehicle, after)
			t.expect(vehicle.paint).toBe(after.paint)
			t.expect(vehicle.tint).toBe(after.tint)
			t.expect(vehicle.rideHeight).toBe(Customization.rideHeight.min)
			t.expect(vehicle.plateText).toBe("VOLT 1")
			t.expect(vehicle.energy).toBe(0.4)
			t.expect(vehicle.uid).toBe("car-1")
			t.expect(vehicle.paid).toBe(35000)
			t.expect(vehicle.extras == after.extras).toBe(false) -- the save holds its own list
		end)

		t.it("stores 'no wrap' as an unset wrap, and treats nil and 'none' as the same", function()
			local vehicle = car()
			vehicle.wrap = nil
			local look = CustomizationService.lookOf(vehicle, nil)
			local none = table.clone(look)
			none.wrap = "none"
			t.expect(#CustomizationService.changedFields(look, none)).toBe(0)
			CustomizationService.saveLook(vehicle, none)
			t.expect(vehicle.wrap).toBe(nil)
		end)

		t.it("puts an exclusive wrap on only for a player who has it, free", function()
			local exclusive = Customization.exclusiveWraps[1].id
			local function owns(lookId: string): boolean
				return lookId == exclusive
			end
			local function ownsNothing(_lookId: string): boolean
				return false
			end
			local changes: any = { wrap = exclusive }
			t.expect((CustomizationService.exclusiveAllowed(changes, nil, owns))).toBe(true)
			local allowed, message = CustomizationService.exclusiveAllowed(changes, nil, ownsNothing)
			t.expect(allowed).toBe(false)
			t.expect(message).toBe(Customization.messages.lockedWrap)
			-- Already on the car (the club lapsed since): keeping it is fine; shop wraps never need a look.
			t.expect((CustomizationService.exclusiveAllowed(changes, exclusive, ownsNothing))).toBe(true)
			local shopWrap: any = { wrap = Customization.wraps[2].id }
			t.expect((CustomizationService.exclusiveAllowed(shopWrap, nil, ownsNothing))).toBe(true)
			t.expect((CustomizationService.exclusiveAllowed({} :: any, nil, ownsNothing))).toBe(true)
			-- It validates like any wrap, and costs nothing.
			local vehicle = car()
			local ok, _, cost = CustomizationService.validate(vehicle, classOf(VEHICLE_ID), changes)
			t.expect(ok).toBe(true)
			t.expect(cost).toBe(0)
		end)

		t.it("never sells an exclusive look's finish, and charges only the shop price of what else changed", function()
			local vehicle = car()
			local class = classOf(VEHICLE_ID)
			for _, finish in Customization.exclusiveFinishes do
				local ok, message, cost, after =
					CustomizationService.validate(vehicle, class, { finish = finish.id } :: any)
				t.expect(ok).toBe(false)
				t.expect(message).toBe(Customization.messages.unknownFinish)
				t.expect(cost).toBe(0)
				t.expect(after).toBe(nil)
			end
			local current = CustomizationService.lookOf(vehicle, nil)
			for _, wrap in Customization.exclusiveWraps do
				local ok, _, cost, after = CustomizationService.validate(vehicle, class, { wrap = wrap.id } :: any)
				t.expect(ok).toBe(true)
				t.expect(cost).toBe(0)
				-- The look's finish is worn, never saved: the car keeps its own on record.
				t.expect(after ~= nil and after.finish).toBe(vehicle.finish)
				t.expect(after ~= nil and after.paint).toBe(vehicle.paint)
				local _, _, both =
					CustomizationService.validate(vehicle, class, { wrap = wrap.id, finish = "matte" } :: any)
				t.expect(both).toBe((Customization.priceOf({ finish = "matte" }, current, class)))
			end
		end)

		t.it("refuses stripes on a final-art body, and lets every exclusive look and plain paint through", function()
			local striped: any = { wrap = "rally" }
			t.expect((CustomizationService.wrapFits(striped, nil, true))).toBe(true) -- a greybox or designed body
			local fits, message = CustomizationService.wrapFits(striped, nil, false)
			t.expect(fits).toBe(false)
			t.expect(message).toBe(Customization.messages.wrapDoesntFit)
			-- Already on the car (bought before the art came): keeping it is fine.
			t.expect((CustomizationService.wrapFits(striped, "rally", false))).toBe(true)
			t.expect((CustomizationService.wrapFits({ wrap = "none" } :: any, "rally", false))).toBe(true)
			t.expect((CustomizationService.wrapFits({} :: any, nil, false))).toBe(true)
			for _, wrap in Customization.exclusiveWraps do
				t.expect((CustomizationService.wrapFits({ wrap = wrap.id } :: any, nil, false))).toBe(true)
			end
		end)

		t.it("lists exactly the fields that changed", function()
			local look = CustomizationService.lookOf(car(), nil)
			local after = table.clone(look)
			after.tint = 0.5
			after.extras = { "roof_rack" }
			t.expect(CustomizationService.changedFields(look, after)).toEqual({ "tint", "extras" })
		end)

		t.it("only opens for the driver of their own garage car inside a shop bay", function()
			local messages = CustomizationService.SHOP.messages
			t.expect((CustomizationService.canCustomize(usable(), "car-1"))).toBe(true)
			t.expect((CustomizationService.canCustomize(usable(), nil))).toBe(true)

			local function refusal(change: (CustomizationService.Situation) -> (), uid: string?): string?
				local situation = usable()
				change(situation)
				local ok, message = CustomizationService.canCustomize(situation, uid)
				t.expect(ok).toBe(false)
				return message
			end
			t.expect(refusal(function(s)
				s.hasCar = false
			end)).toBe(messages.noCar)
			t.expect(refusal(function(s)
				s.testDrive = true
				s.ownedUid = nil
				s.owned = false
			end)).toBe(messages.testDrive)
			t.expect(refusal(function(s)
				s.ownedUid = nil
			end)).toBe(messages.notOwned)
			t.expect(refusal(function(s)
				s.owned = false -- the uid isn't in this player's data (sold, or someone else's)
			end)).toBe(messages.notOwned)
			t.expect(refusal(function(s)
				s.inDriverSeat = false
			end)).toBe(messages.notDriving)
			t.expect(refusal(function(s)
				s.inShop = false
			end)).toBe(messages.notInShop)
			t.expect(refusal(function() end, "car-2")).toBe(messages.wrongCar)
		end)

		t.it("knows when a point stands over a shop bay, turned or not", function()
			local size = Vector3.new(24, 1, 32)
			local frame = CFrame.new(100, 0.5, 200)
			t.expect(CustomizationService.insideFootprint(frame, size, Vector3.new(100, 0, 200), 0)).toBe(true)
			t.expect(CustomizationService.insideFootprint(frame, size, Vector3.new(111, 3, 215), 0)).toBe(true)
			t.expect(CustomizationService.insideFootprint(frame, size, Vector3.new(113, 0, 200), 0)).toBe(false)
			t.expect(CustomizationService.insideFootprint(frame, size, Vector3.new(113, 0, 200), 2)).toBe(true)
			-- Turned a quarter: its 32-stud side now runs along X.
			local turned = frame * CFrame.Angles(0, math.rad(90), 0)
			t.expect(CustomizationService.insideFootprint(turned, size, Vector3.new(115, 0, 200), 0)).toBe(true)
			t.expect(CustomizationService.insideFootprint(turned, size, Vector3.new(100, 0, 214), 0)).toBe(false)
		end)

		t.it("normalizes custom plate text and refuses text that breaks the rules", function()
			t.expect((CustomizationService.checkPlateText("  volt   1 "))).toBe("VOLT 1")
			t.expect((CustomizationService.checkPlateText("EV-2026"))).toBe("EV-2026")
			t.expect((CustomizationService.checkPlateText("   "))).toBe("") -- back to the standard plate
			local maxLength = Customization.plate.maxLength
			local tooLong, why = CustomizationService.checkPlateText(string.rep("A", maxLength + 1))
			t.expect(tooLong).toBe(nil)
			t.expect(why).toBe(Customization.plate.allowedDescription)
			t.expect((CustomizationService.checkPlateText(string.rep("B", maxLength)))).toBe(string.rep("B", maxLength))
			for _, bad in { "HI!", "A_B", "<b>", "Ü1" } do
				t.expect((CustomizationService.checkPlateText(bad))).toBe(nil)
			end
		end)

		t.it("unlocks custom plate text with the pass, or only in Studio before the pass exists", function()
			t.expect(CustomizationService.customTextAllowed(nil, true)).toBe(true)
			t.expect(CustomizationService.customTextAllowed(nil, false)).toBe(false)
			t.expect(CustomizationService.customTextAllowed(true, false)).toBe(true)
			t.expect(CustomizationService.customTextAllowed(false, true)).toBe(false)
		end)

		t.it("has a Wrap & Tint shop in Cedar Bend and one at The Plant, on the GPS", function()
			local zones: { [string]: number } = {}
			local tag = CustomizationService.SHOP.tag
			for _, location in MapLayout.locations do
				if location.tag == tag then
					zones[location.zone] = (zones[location.zone] or 0) + 1
					t.expect(location.gps).toBe(true)
					-- The bay holds every car in the catalog (its pivot, the car's middle, is then well inside).
					for _, vehicleId in Catalog.vehicleIds() do
						local trim = Catalog.defaultTrim(vehicleId)
						local geometry = if trim then Catalog.geometry(vehicleId, trim.id) else nil
						if geometry then
							t.expect(geometry.length <= location.size.Z).toBe(true)
							t.expect(geometry.width <= location.size.X).toBe(true)
						end
					end
				end
			end
			t.expect(zones.cedar_bend).toBe(1)
			t.expect(zones.the_plant).toBe(1)
		end)
	end)
end
