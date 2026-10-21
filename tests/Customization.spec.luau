--!strict
-- The Wrap & Tint shop catalog (Config/Customization, docs/phase-7-contracts.md): every id is unique, every
-- price is a whole positive number of dollars, priceOf only charges what changed, extras only name real classes
-- and contract mounts, custom colors stay inside their limits, and plates follow their rules. Pure: runs in
-- Edit mode.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Classes = require(ReplicatedStorage.Shared.Config.Classes)
local Customization = require(ReplicatedStorage.Shared.Config.Customization)
local Garage = require(ReplicatedStorage.Shared.Config.Garage)
local Harness = require(ReplicatedStorage.Shared.Testing.Harness)

-- Mount attachments every model has (vehicle model contract, docs/phase-1-contracts.md).
local CONTRACT_MOUNTS = {
	Mount_Roof = true,
	Mount_Hood = true,
	Mount_Spoiler = true,
	Mount_FrontBumper = true,
	Mount_RearBumper = true,
	Mount_SideL = true,
	Mount_SideR = true,
}

-- A stock car's look (the defaults).
local function stockLook(): Customization.Look
	local d = Customization.defaults
	return {
		uid = "spec-car",
		paint = d.paint,
		finish = d.finish,
		wrap = d.wrap,
		wheels = d.wheels,
		rideHeight = d.rideHeight,
		tint = d.tint,
		caliper = d.caliper,
		extras = {},
		plateFormat = d.plateFormat,
		plateText = nil,
	}
end

local function isWhole(n: number): boolean
	return n % 1 == 0
end

local function ids(list: { any }): { string }
	local result = {}
	for _, entry in list do
		table.insert(result, entry.id)
	end
	return result
end

local function duplicates(list: { string }): { string }
	local seen, dupes = {}, {}
	for _, id in list do
		if seen[id] then
			table.insert(dupes, id)
		end
		seen[id] = true
	end
	return dupes
end

return function(t: Harness.Api)
	t.describe("Customization catalog", function()
		t.it("has unique ids in every list", function()
			for name, list in
				{
					paints = Customization.paints,
					finishes = Customization.finishes,
					wraps = Customization.wraps,
					wheels = Customization.wheels,
					calipers = Customization.calipers,
					extras = Customization.extras,
					plateFormats = Customization.plateFormats,
				} :: { [string]: { any } }
			do
				local dupes = duplicates(ids(list))
				if #dupes > 0 then
					print(`  {name}: duplicate {table.concat(dupes, ", ")}`)
				end
				t.expect(#dupes).toBe(0)
			end
		end)

		t.it("offers the contract's ranges of options", function()
			t.expect(#Customization.paints >= 16 and #Customization.paints <= 24).toBe(true)
			t.expect(ids(Customization.finishes)).toEqual({ "gloss", "matte", "metallic" })
			local designs = #Customization.wraps - 1 -- "none" is not a design
			t.expect(Customization.getWrap("none")).toBeTruthy()
			t.expect(designs >= 6 and designs <= 10).toBe(true)
			t.expect(#Customization.wheels >= 6 and #Customization.wheels <= 8).toBe(true)
		end)

		t.it("has every default in the catalog, matching the garage's defaults", function()
			local d = Customization.defaults
			t.expect(Customization.getPaint(d.paint)).toBeTruthy()
			t.expect(Customization.getFinish(d.finish)).toBeTruthy()
			t.expect(Customization.getWrap(d.wrap)).toBeTruthy()
			t.expect(Customization.getWheel(d.wheels)).toBeTruthy()
			t.expect(Customization.getCaliper(d.caliper)).toBeTruthy()
			t.expect(Customization.getPlateFormat(d.plateFormat)).toBeTruthy()
			t.expect(Customization.getTintLevel(d.tint)).toBeTruthy()
			t.expect(Customization.isRideHeight(d.rideHeight)).toBe(true)
			-- Every car saved before Phase 7 already has these values (paint: the 4 -> 5 migration moves the old
			-- "white" default to "factory").
			t.expect(d.paint).toBe(Garage.defaults.paint)
			t.expect(d.finish).toBe(Garage.defaults.finish)
			t.expect(d.wheels).toBe(Garage.defaults.wheels)
			t.expect(d.rideHeight).toBe(Garage.defaults.rideHeight)
			t.expect(d.tint).toBe(Garage.defaults.tint)
		end)

		t.it("prices everything in whole, positive dollars", function()
			local bad: { string } = {}
			local function checkPrice(label: string, price: number)
				if type(price) ~= "number" or price <= 0 or not isWhole(price) then
					table.insert(bad, `{label} = {price}`)
				end
			end
			checkPrice("paintPrice", Customization.paintPrice)
			checkPrice("customColor", Customization.customColor.price)
			checkPrice("rideHeight", Customization.rideHeight.price)
			checkPrice("tint", Customization.tint.price)
			for name, list in
				{
					finishes = Customization.finishes,
					wraps = Customization.wraps,
					wheels = Customization.wheels,
					calipers = Customization.calipers,
					extras = Customization.extras,
				} :: { [string]: { any } }
			do
				for _, entry in list do
					checkPrice(`{name}.{entry.id}`, entry.price)
				end
			end
			-- Scaled for every class tier too.
			for classId in Classes do
				checkPrice(`scaled paint for {classId}`, Customization.scaledPrice(Customization.paintPrice, classId))
				checkPrice(`scaled wrap for {classId}`, Customization.scaledPrice(2500, classId))
			end
			for _, line in bad do
				print(`  price: {line}`)
			end
			t.expect(bad).toEqual({})
		end)

		t.it("keeps exclusive wraps out of the shop list, free to put on and found by id", function()
			local shopIds: { [string]: boolean } = {}
			for _, wrap in Customization.wraps do
				shopIds[wrap.id] = true
				t.expect(Customization.isExclusive(wrap.id)).toBe(false)
			end
			t.expect(#duplicates(ids(Customization.exclusiveWraps))).toBe(0)
			for _, wrap in Customization.exclusiveWraps do
				t.expect(`{wrap.id} in the shop list: {shopIds[wrap.id] == true}`)
					.toBe(`{wrap.id} in the shop list: false`)
				t.expect(wrap.exclusive).toBe(true)
				t.expect(#wrap.bands).toBeGreaterThan(0)
				t.expect(Customization.getWrap(wrap.id)).toBe(wrap)
				t.expect(Customization.lookExists(wrap.id)).toBe(true)
				t.expect((Customization.priceOf({ wrap = wrap.id }, stockLook(), "sedan"))).toBe(0)
			end
			-- Plate frames aren't a look yet.
			t.expect(Customization.lookExists("launch_week_plate_frame")).toBe(false)
		end)

		t.it("lists an exclusive wrap only for a player who has it, or on the car already", function()
			local first = Customization.exclusiveWraps[1]
			local shop = #Customization.wraps
			t.expect(#Customization.wrapsFor(nil, nil)).toBe(shop)
			t.expect(#Customization.wrapsFor({ [first.id] = true }, nil)).toBe(shop + 1)
			t.expect(#Customization.wrapsFor({}, first.id)).toBe(shop + 1)
			t.expect(#Customization.wrapsFor({ [first.id] = true }, first.id)).toBe(shop + 1)
		end)

		t.it("costs more on a higher-tier class", function()
			local look = stockLook()
			local economy = Customization.priceOf({ paint = "cobalt" }, look, "economy")
			local hypercar = Customization.priceOf({ paint = "cobalt" }, look, "hypercar")
			t.expect(economy).toBe(Customization.paintPrice)
			t.expect(hypercar).toBeGreaterThan(economy)
		end)
	end)

	t.describe("Customization.priceOf", function()
		t.it("charges nothing for no changes", function()
			local total, lines = Customization.priceOf({}, stockLook(), "sedan")
			t.expect(total).toBe(0)
			t.expect(#lines).toBe(0)
		end)

		t.it("charges nothing when every change matches the current look", function()
			local look = stockLook()
			local total = Customization.priceOf({
				paint = look.paint,
				finish = look.finish,
				wrap = look.wrap,
				wheels = look.wheels,
				rideHeight = look.rideHeight,
				tint = look.tint,
				caliper = look.caliper,
				extras = {},
				plateFormat = look.plateFormat,
			}, look, "sedan")
			t.expect(total).toBe(0)
		end)

		t.it("treats a missing wrap as no wrap", function()
			local look = stockLook()
			look.wrap = nil
			t.expect((Customization.priceOf({ wrap = "none" }, look, "sedan"))).toBe(0)
		end)

		t.it("charges exactly the fields that changed", function()
			local look = stockLook()
			local total, lines = Customization.priceOf({
				paint = look.paint, -- unchanged
				finish = "matte",
				wheels = "five_star",
				tint = 0.5,
			}, look, "sedan")
			local categories = {}
			for _, line in lines do
				table.insert(categories, line.category)
			end
			t.expect(categories).toEqual({ "finish", "wheels", "tint" })
			local finish = Customization.getFinish("matte")
			local wheel = Customization.getWheel("five_star")
			assert(finish and wheel, "catalog entries")
			t.expect(total).toBe(finish.price + wheel.price + Customization.tint.price)
		end)

		t.it("charges a custom color at its own price, and nothing to re-pick the same one", function()
			local look = stockLook()
			local hsv = { h = 0.55, s = 0.6, v = 0.7 }
			local total = Customization.priceOf({ customColor = hsv }, look, "sedan")
			t.expect(total).toBe(Customization.customColor.price)
			look.paint = Customization.customPaintId(hsv)
			t.expect((Customization.priceOf({ customColor = hsv }, look, "sedan"))).toBe(0)
		end)

		t.it("charges only newly added extras; removing is free", function()
			local look = stockLook()
			look.extras = { "roof_rack" }
			local lightBar = Customization.getExtra("light_bar")
			assert(lightBar, "light bar")
			local total, lines = Customization.priceOf({ extras = { "roof_rack", "light_bar" } }, look, "offroad")
			t.expect(#lines).toBe(1)
			t.expect(total).toBe(Customization.scaledPrice(lightBar.price, "offroad"))
			t.expect((Customization.priceOf({ extras = {} }, look, "offroad"))).toBe(0)
		end)

		t.it("never charges for a plate style", function()
			t.expect((Customization.priceOf({ plateFormat = "classic" }, stockLook(), "sedan"))).toBe(0)
		end)

		t.it("charges a ride height change once, and nothing for the same height", function()
			local look = stockLook()
			look.rideHeight = -0.5
			t.expect((Customization.priceOf({ rideHeight = -0.5 }, look, "sedan"))).toBe(0)
			t.expect((Customization.priceOf({ rideHeight = 0.25 }, look, "sedan"))).toBe(Customization.rideHeight.price)
		end)
	end)

	t.describe("Customization.check", function()
		t.it("accepts a valid change set", function()
			local ok, message = Customization.check({
				paint = "cobalt",
				finish = "metallic",
				wrap = "rally",
				wheels = "trail",
				rideHeight = 0.75,
				tint = 0.25,
				caliper = "red",
				extras = { "roof_rack", "light_bar", "bull_bar" },
				plateFormat = "metro",
			}, "offroad")
			t.expect(ok).toBe(true)
			t.expect(message).toBe(nil)
		end)

		t.it("refuses unknown ids and off-grid numbers", function()
			local m = Customization.messages
			local function refuses(changes: Customization.Changes, expected: string)
				local ok, message = Customization.check(changes, "sedan")
				t.expect(ok).toBe(false)
				t.expect(message).toBe(expected)
			end
			refuses({ paint = "neon_pink" }, m.unknownPaint)
			refuses({ finish = "chrome" }, m.unknownFinish)
			refuses({ wrap = "flames" }, m.unknownWrap)
			refuses({ wheels = "spinner" }, m.unknownWheels)
			refuses({ rideHeight = 0.3 }, m.badRideHeight)
			refuses({ rideHeight = 1.25 }, m.badRideHeight)
			refuses({ tint = 0.6 }, m.badTint)
			refuses({ caliper = "pink" }, m.unknownCaliper)
			refuses({ extras = { "jet_engine" } }, m.unknownExtra)
			refuses({ plateFormat = "vanity" }, m.unknownPlate)
			refuses({ paint = "cobalt", customColor = { h = 0.5, s = 0.5, v = 0.5 } }, m.paintAndCustom)
			refuses({ customColor = { h = 0.3, s = 1, v = 1 } }, m.customColorLimit)
			refuses({ customColor = { h = 0.3, s = 0.5, v = 0.02 } }, m.customColorLimit)
		end)

		t.it("refuses extras the class can't take, twice, or in the same spot", function()
			local m = Customization.messages
			t.expect(select(2, Customization.check({ extras = { "bull_bar" } }, "sedan"))).toBe(m.extraNotForClass)
			t.expect(select(2, Customization.check({ extras = { "roof_rack", "roof_rack" } }, "suv")))
				.toBe(m.extraTwice)
			t.expect(select(2, Customization.check({ extras = { "lip_spoiler", "wing_spoiler" } }, "sports")))
				.toBe(m.extraClash)
		end)

		t.it("keeps the lip off SUV bodies in its classes, and snaps near-step numbers when applied", function()
			t.expect(Customization.extraAllowed("lip_spoiler", "luxury", "sedan")).toBe(true)
			t.expect(Customization.extraAllowed("lip_spoiler", "luxury", "suv")).toBe(false)
			local m = Customization.messages
			t.expect(select(2, Customization.check({ extras = { "lip_spoiler" } }, "luxury", "suv")))
				.toBe(m.extraNotForClass)
			local current = Customization.applyChanges(
				Customization.applyChanges({
					uid = "u",
					paint = Customization.defaults.paint,
					finish = Customization.defaults.finish,
					wrap = nil,
					wheels = Customization.defaults.wheels,
					rideHeight = 0.25,
					tint = 0.5,
					caliper = Customization.defaults.caliper,
					extras = {},
					plateFormat = Customization.defaults.plateFormat,
					plateText = nil,
				}, {}),
				{ rideHeight = 0.25002, tint = 0.50003 }
			)
			t.expect(current.rideHeight).toBe(0.25)
			t.expect(current.tint).toBe(0.5)
		end)
	end)

	t.describe("Customization extras", function()
		t.it("names only real classes, with a size for each and a contract mount", function()
			local problems: { string } = {}
			for _, extra in Customization.extras do
				if not CONTRACT_MOUNTS[extra.mount] then
					table.insert(problems, `{extra.id}: mount {extra.mount} is not a contract mount`)
				end
				if #extra.classes == 0 then
					table.insert(problems, `{extra.id}: no classes`)
				end
				for _, class in extra.classes do
					if Classes[class] == nil then
						table.insert(problems, `{extra.id}: {class} is not a class`)
					end
					if Customization.extraSize(extra, class) == nil then
						table.insert(problems, `{extra.id}: no size for {class}`)
					end
				end
				for class in extra.sizeByClass do
					if not table.find(extra.classes, class) then
						table.insert(problems, `{extra.id}: size for {class}, which can't take it`)
					end
				end
				if #extra.pieces == 0 then
					table.insert(problems, `{extra.id}: no pieces`)
				end
			end
			for _, problem in problems do
				print(`  extra: {problem}`)
			end
			t.expect(problems).toEqual({})
		end)

		t.it("lets every class take at least one extra", function()
			for classId in Classes do
				t.expect(#Customization.extrasFor(classId)).toBeGreaterThan(0)
			end
		end)
	end)

	t.describe("Customization paint, stance and tint", function()
		t.it("round-trips a custom color through its id and keeps it inside the limits", function()
			local id = Customization.customPaintId({ h = 0.5833, s = 0.65, v = 0.8 })
			t.expect(id).toBe("custom:210,65,80")
			local hsv = Customization.parseCustomPaint(id)
			assert(hsv, "parsed")
			t.expect(hsv.h).toBeNear(210 / 360, 1e-9)
			t.expect(Customization.isPaint(id)).toBe(true)
			t.expect(Customization.paintColor(id)).toBeTruthy()
			-- Out-of-limit picks are clamped into the limits.
			local clamped = Customization.parseCustomPaint(Customization.customPaintId({ h = 0.1, s = 1, v = 0 }))
			assert(clamped, "clamped parse")
			t.expect(clamped.s).toBeNear(Customization.customColor.maxSaturation, 1e-9)
			t.expect(clamped.v).toBeNear(Customization.customColor.minValue, 1e-9)
		end)

		t.it("refuses custom ids it could not have made", function()
			for _, id in
				{ "custom:210,065,80", "custom:360,50,50", "custom:10,90,50", "custom:10,50,5", "custom:a,b,c" }
			do
				t.expect(Customization.parseCustomPaint(id)).toBe(nil)
				t.expect(Customization.isPaint(id)).toBe(false)
			end
		end)

		t.it("has a color for every palette paint", function()
			for _, paint in Customization.paints do
				t.expect(Customization.paintColor(paint.id)).toBe(paint.color)
			end
		end)

		t.it("puts ride heights on steps and offsets the body down at -1 and up at 1", function()
			t.expect(Customization.isRideHeight(-1)).toBe(true)
			t.expect(Customization.isRideHeight(0.25)).toBe(true)
			t.expect(Customization.isRideHeight(0.3)).toBe(false)
			t.expect(Customization.isRideHeight(-1.25)).toBe(false)
			for classId in Classes do
				t.expect(Customization.rideHeight.byClass[classId]).toBeTruthy()
				t.expect(Customization.rideOffset(-1, classId)).toBeLessThan(0)
				t.expect(Customization.rideOffset(1, classId)).toBeGreaterThan(0)
				t.expect(Customization.rideOffset(0, classId)).toBe(0)
			end
		end)

		t.it("has tint levels from factory glass to darkest", function()
			local levels = Customization.tint.levels
			t.expect(levels[1].value).toBe(0)
			t.expect(levels[1].darken).toBe(0)
			for i = 2, #levels do
				t.expect(levels[i].value).toBeGreaterThan(levels[i - 1].value)
				t.expect(levels[i].transparency).toBeLessThan(levels[i - 1].transparency)
			end
			t.expect(levels[#levels].value).toBe(1)
		end)
	end)

	t.describe("Customization plates", function()
		t.it("allows up to 8 letters, numbers, spaces and dashes", function()
			t.expect(Customization.plate.maxLength).toBe(8)
			t.expect(Customization.isPlateTextAllowed("VOLT-24")).toBe(true)
			t.expect(Customization.isPlateTextAllowed("AB CD 12")).toBe(true)
			t.expect(Customization.isPlateTextAllowed("ABCDEFGHI")).toBe(false)
			t.expect(Customization.isPlateTextAllowed("")).toBe(false)
			t.expect(Customization.isPlateTextAllowed("HI!")).toBe(false)
			t.expect(Customization.isPlateTextAllowed("abc")).toBe(false) -- normalize first
			t.expect(Customization.isPlateTextAllowed(string.char(196) .. "BC")).toBe(false) -- not ASCII
		end)

		t.it("normalizes text to capitals and single spaces", function()
			t.expect(Customization.normalizePlateText("  volt   24 ")).toBe("VOLT 24")
			t.expect(Customization.normalizePlateText("a-b")).toBe("A-B")
		end)

		t.it("gives every car a stable standard plate that fits its format and the rules", function()
			for _, format in Customization.plateFormats do
				local seen: { [string]: boolean } = {}
				for i = 1, 20 do
					local text = Customization.standardPlateText(format.id, `car-{i}`)
					t.expect(#text).toBe(#format.pattern)
					t.expect(Customization.isPlateTextAllowed(text)).toBe(true)
					t.expect(Customization.standardPlateText(format.id, `car-{i}`)).toBe(text)
					for j = 1, #format.pattern do
						local slot, char = string.sub(format.pattern, j, j), string.sub(text, j, j)
						if slot == "@" then
							t.expect(string.match(char, "%u") ~= nil).toBe(true)
						elseif slot == "#" then
							t.expect(string.match(char, "%d") ~= nil).toBe(true)
						else
							t.expect(char).toBe(slot)
						end
					end
					for _, avoided in Customization.plate.standardAvoid do
						t.expect((string.find(text, avoided, 1, true))).toBe(nil)
					end
					seen[text] = true
				end
				local distinct = 0
				for _ in seen do
					distinct += 1
				end
				t.expect(distinct).toBeGreaterThan(15) -- different cars, different numbers
			end
		end)

		t.it("falls back to the default format for an unknown one", function()
			local fallback = Customization.standardPlateText("nope", "seed")
			t.expect(fallback).toBe(Customization.standardPlateText(Customization.defaults.plateFormat, "seed"))
		end)
	end)

	t.describe("Customization.applyChanges", function()
		t.it("returns the new look without touching the current one", function()
			local look = stockLook()
			local after = Customization.applyChanges(look, { wheels = "mesh", extras = { "roof_box" }, tint = 1 })
			t.expect(after.wheels).toBe("mesh")
			t.expect(after.extras).toEqual({ "roof_box" })
			t.expect(after.tint).toBe(1)
			t.expect(after.paint).toBe(look.paint)
			t.expect(look.wheels).toBe(Customization.defaults.wheels)
			t.expect(look.extras).toEqual({})
		end)
	end)
end
