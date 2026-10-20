--!strict
-- The catalog is complete and every trim sits inside its class band (PLAN.md §3.3).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Brands = require(ReplicatedStorage.Shared.Config.Brands)
local Catalog = require(ReplicatedStorage.Shared.Vehicle.Catalog)
local Classes = require(ReplicatedStorage.Shared.Config.Classes)
local Harness = require(ReplicatedStorage.Shared.Testing.Harness)
local Units = require(ReplicatedStorage.Shared.Util.Units)

-- Launch catalog size (PLAN.md §3.3, docs/phase-4-contracts.md "Catalog expansion").
local MIN_VEHICLES = 30
local MIN_PER_BRAND = 3
local MIN_USED_LOT = 6

-- Every greybox body VehicleBuilder knows (Config/Vehicles BodyStyle).
local BODY_STYLES: { [string]: boolean } = {
	sedan = true,
	hatch = true,
	coupe = true,
	wagon = true,
	suv = true,
	pickup = true,
	van = true,
	minivan = true,
	muscle = true,
	exotic = true,
	offroad = true,
	tow = true,
	semi = true,
	pod = true,
	hypercar = true,
}

-- Every vehicle in the catalog, by id order.
local function allVehicles(): { any }
	local list = {}
	for _, vehicleId in Catalog.vehicleIds() do
		table.insert(list, Catalog.getVehicle(vehicleId))
	end
	return list
end

return function(t: Harness.Api)
	t.describe("Catalog at launch size", function()
		t.it(`has at least {MIN_VEHICLES} vehicles`, function()
			t.expect(#Catalog.vehicleIds() >= MIN_VEHICLES).toBe(true)
		end)

		t.it(`gives every brand at least {MIN_PER_BRAND} vehicles`, function()
			local counts: { [string]: number } = {}
			for _, vehicle in allVehicles() do
				counts[vehicle.brandId] = (counts[vehicle.brandId] or 0) + 1
			end
			local short: { string } = {}
			for brandId in Brands do
				if (counts[brandId] or 0) < MIN_PER_BRAND then
					table.insert(short, `{brandId}: {counts[brandId] or 0}`)
				end
			end
			table.sort(short)
			t.expect(short).toEqual({})
		end)

		t.it("uses every class at least once", function()
			local used: { [string]: boolean } = {}
			for _, vehicle in allVehicles() do
				used[vehicle.class] = true
			end
			local unused: { string } = {}
			for classId in Classes do
				if not used[classId] then
					table.insert(unused, classId)
				end
			end
			table.sort(unused)
			t.expect(unused).toEqual({})
		end)

		t.it(`has at least {MIN_USED_LOT} used-lot classics, all priced for the used lot`, function()
			local classics = 0
			local problems: { string } = {}
			for _, vehicle in allVehicles() do
				local onLot = false
				for _, trim in vehicle.trims do
					if trim.acquisition == "usedLot" then
						onLot = true
						if trim.price == nil or trim.upgradeFrom ~= nil then
							table.insert(problems, `{vehicle.id}/{trim.id}: a used-lot trim needs a base price`)
						end
					end
				end
				if onLot then
					classics += 1
				end
			end
			t.expect(problems).toEqual({})
			t.expect(classics >= MIN_USED_LOT).toBe(true)
		end)

		t.it("gives every vehicle a known bodyStyle", function()
			local unknown: { string } = {}
			for _, vehicle in allVehicles() do
				if not BODY_STYLES[vehicle.bodyStyle] then
					table.insert(unknown, `{vehicle.id}: {vehicle.bodyStyle}`)
				end
			end
			t.expect(unknown).toEqual({})
		end)

		t.it("gives every non-Ohm vehicle 2 to 4 trims", function()
			local problems: { string } = {}
			for _, vehicle in allVehicles() do
				if vehicle.brandId ~= "ohm" and (#vehicle.trims < 2 or #vehicle.trims > 4) then
					table.insert(problems, `{vehicle.id}: {#vehicle.trims} trims`)
				end
			end
			t.expect(problems).toEqual({})
		end)

		t.it("stays mostly electric", function()
			local battery, fuel = 0, 0
			for _, vehicle in allVehicles() do
				if vehicle.energy == "battery" then
					battery += 1
				else
					fuel += 1
				end
			end
			t.expect(battery).toBeGreaterThan(fuel)
		end)

		t.it("names every vehicle and trim uniquely", function()
			local vehicleNames: { [string]: boolean } = {}
			local duplicates: { string } = {}
			for _, vehicle in allVehicles() do
				if vehicleNames[vehicle.displayName] then
					table.insert(duplicates, vehicle.displayName)
				end
				vehicleNames[vehicle.displayName] = true
				local trimNames: { [string]: boolean } = {}
				for _, trim in vehicle.trims do
					if trimNames[trim.displayName] then
						table.insert(duplicates, `{vehicle.id}: {trim.displayName}`)
					end
					trimNames[trim.displayName] = true
				end
			end
			t.expect(duplicates).toEqual({})
		end)
	end)

	t.describe("Catalog", function()
		t.it("validates with no problems", function()
			local problems = Catalog.validate()
			for _, message in problems do
				print(`  catalog: {message}`)
			end
			t.expect(#problems).toBe(0)
		end)

		t.it("has all eight Ohm vehicles with their trims", function()
			local expected = {
				ohm_spark = { "used", "standard", "long_range", "performance" },
				ohm_current = { "standard", "long_range", "performance", "long_body" },
				ohm_mesa = { "standard", "performance" },
				ohm_hauler = { "standard", "long_range" },
				ohm_pod = { "standard" },
				ohm_arc = { "performance", "boost", "flight" },
				ohm_grand = { "standard" },
				ohm_summit = { "standard" },
			}
			for vehicleId, trims in expected do
				for _, trimId in trims do
					t.expect(Catalog.getTrim(vehicleId, trimId) ~= nil).toBe(true)
				end
			end
		end)

		t.it("prices an upgrade trim as base plus upgrade", function()
			t.expect(Catalog.totalPrice("ohm_arc", "performance")).toBe(2000000) -- tuned in Phase 3 (EconSim)
			t.expect(Catalog.totalPrice("ohm_arc", "boost")).toBe(7000000)
			t.expect(Catalog.totalPrice("ohm_arc", "flight")).toBe(nil)
		end)

		t.it("names models by the contract", function()
			t.expect(Catalog.modelName("ohm_spark", "standard")).toBe("ohm_spark_standard")
		end)

		t.it("uses a long-body geometry only for that trim", function()
			local standard = Catalog.geometry("ohm_current", "standard")
			local longBody = Catalog.geometry("ohm_current", "long_body")
			assert(standard and longBody, "geometry exists")
			t.expect(longBody.length).toBeGreaterThan(standard.length)
		end)
	end)

	t.describe("Units", function()
		t.it("round-trips mph through studs per second", function()
			t.expect(Units.studsToMph(Units.mphToStuds(60))).toBeNear(60, 1e-9)
		end)

		t.it("puts 60 mph near 96 studs/s at 0.28 m per stud", function()
			t.expect(Units.mphToStuds(60)).toBeNear(95.8, 0.1)
		end)
	end)
end
