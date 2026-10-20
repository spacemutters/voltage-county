--!strict
-- The dealership's rules (Services/DealershipService pure decisions; docs/phase-4-contracts.md "Commerce";
-- PLAN.md Phase 4 acceptance): buying with exactly the price leaves $0, a dollar short is refused, a full garage
-- is refused, only dealership trims that aren't upgrades can be bought, and upgrades need the car in the trim
-- they upgrade plus the upgrade's own price. Also the layout: every dealership car has a pad in its brand's
-- section. Pure logic on the catalog: runs in Edit mode. Prices come from the catalog, never typed here.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Brands = require(ReplicatedStorage.Shared.Config.Brands)
local Catalog = require(ReplicatedStorage.Shared.Vehicle.Catalog)
local Dealership = require(ReplicatedStorage.Shared.Config.Dealership)
local Harness = require(ReplicatedStorage.Shared.Testing.Harness)
local MapLayout = require(ReplicatedStorage.Shared.Config.MapLayout)
local DealershipService = require(ServerScriptService.Server.Services.DealershipService)

type Found = { vehicleId: string, trim: string }

-- The first trim in the catalog (vehicles in id order) that `match` accepts.
local function findTrim(match: (vehicle: any, trim: any) -> boolean): Found?
	for _, vehicleId in Catalog.vehicleIds() do
		local vehicle = Catalog.getVehicle(vehicleId)
		if vehicle then
			for _, trim in vehicle.trims do
				if match(vehicle, trim) then
					return { vehicleId = vehicleId, trim = trim.id }
				end
			end
		end
	end
	return nil
end

-- A trim the dealership sells outright, with its price.
local function buyable(): (Found, number)
	local found = findTrim(function(vehicle, trim)
		return vehicle.playerDrivable and trim.acquisition == "dealership" and trim.upgradeFrom == nil
	end)
	assert(found, "the catalog has no dealership trim")
	local price = Catalog.totalPrice(found.vehicleId, found.trim)
	assert(price, "a dealership trim has no price")
	return found, price
end

-- An upgrade trim sold at the dealership (the Arc Boost).
local function upgrade(): Found
	local found = findTrim(function(_vehicle, trim)
		return trim.upgradeFrom ~= nil and trim.acquisition == "dealership"
	end)
	assert(found, "the catalog has no upgrade trim")
	return found
end

return function(t: Harness.Api)
	t.describe("DealershipService.decideBuy", function()
		t.it("buys with exactly the price and leaves a balance of $0", function()
			local car, price = buyable()
			local result = DealershipService.decideBuy(car.vehicleId, car.trim, price, true)
			t.expect(result.ok).toBe(true)
			t.expect(result.reason).toBe(nil)
			t.expect(result.price).toBe(price)
			t.expect(result.balanceAfter).toBe(0)
		end)

		t.it("charges the catalog's full price and leaves the change", function()
			local car, price = buyable()
			local result = DealershipService.decideBuy(car.vehicleId, car.trim, price + 1234, true)
			t.expect(result.ok).toBe(true)
			t.expect(result.balanceAfter).toBe(1234)
		end)

		t.it("refuses a dollar short (a forged buy with too little cash)", function()
			local car, price = buyable()
			local result = DealershipService.decideBuy(car.vehicleId, car.trim, price - 1, true)
			t.expect(result.ok).toBe(false)
			t.expect(result.reason).toBe("noCash")
			t.expect(result.balanceAfter).toBe(-1)
			local broke = DealershipService.decideBuy(car.vehicleId, car.trim, 0, true)
			t.expect(broke.reason).toBe("noCash")
		end)

		t.it("refuses when the garage is full, however much cash there is", function()
			local car, price = buyable()
			local result = DealershipService.decideBuy(car.vehicleId, car.trim, price * 10, false)
			t.expect(result.ok).toBe(false)
			t.expect(result.reason).toBe("noRoom")
		end)

		t.it("refuses unknown cars and trims", function()
			local car = buyable()
			t.expect(DealershipService.decideBuy("not_a_real_car", car.trim, 1e9, true).reason).toBe("unknownVehicle")
			t.expect(DealershipService.decideBuy(car.vehicleId, "not_a_real_trim", 1e9, true).reason)
				.toBe("unknownTrim")
		end)

		t.it("refuses trims the dealership doesn't sell (starter, used lot, limited, fleet)", function()
			local count = 0
			for _, vehicleId in Catalog.vehicleIds() do
				local vehicle = Catalog.getVehicle(vehicleId)
				if vehicle and vehicle.playerDrivable then
					for _, trim in vehicle.trims do
						if trim.acquisition ~= "dealership" then
							count += 1
							local result = DealershipService.decideBuy(vehicleId, trim.id, 1e9, true)
							t.expect(result.ok).toBe(false)
							t.expect(result.reason).toBe("notForSale")
						end
					end
				end
			end
			t.expect(count).toBeGreaterThan(0)
		end)

		t.it("refuses upgrade trims (they're bought as upgrades)", function()
			local boost = upgrade()
			local result = DealershipService.decideBuy(boost.vehicleId, boost.trim, 1e9, true)
			t.expect(result.ok).toBe(false)
			t.expect(result.reason).toBe("upgradeTrim")
		end)

		t.it("refuses cars nobody drives", function()
			local found = findTrim(function(vehicle, _trim)
				return not vehicle.playerDrivable
			end)
			if found then
				t.expect(DealershipService.decideBuy(found.vehicleId, found.trim, 1e9, true).reason).toBe("notDrivable")
			end
		end)
	end)

	t.describe("DealershipService.decideUpgrade", function()
		t.it("upgrades a car in the base trim with exactly the upgrade price", function()
			local boost = upgrade()
			local trim = Catalog.getTrim(boost.vehicleId, boost.trim) :: any
			local owned = { vehicleId = boost.vehicleId, trim = trim.upgradeFrom }
			local result = DealershipService.decideUpgrade(owned, boost.trim, trim.price)
			t.expect(result.ok).toBe(true)
			t.expect(result.price).toBe(trim.price)
			t.expect(result.balanceAfter).toBe(0)
		end)

		t.it("refuses a dollar short", function()
			local boost = upgrade()
			local trim = Catalog.getTrim(boost.vehicleId, boost.trim) :: any
			local owned = { vehicleId = boost.vehicleId, trim = trim.upgradeFrom }
			local result = DealershipService.decideUpgrade(owned, boost.trim, trim.price - 1)
			t.expect(result.ok).toBe(false)
			t.expect(result.reason).toBe("noCash")
		end)

		t.it("refuses a car in any other trim", function()
			local boost = upgrade()
			local trim = Catalog.getTrim(boost.vehicleId, boost.trim) :: any
			local vehicle = Catalog.getVehicle(boost.vehicleId) :: any
			local others = 0
			for _, other in vehicle.trims do
				if other.id ~= trim.upgradeFrom then
					others += 1
					local owned = { vehicleId = boost.vehicleId, trim = other.id }
					local result = DealershipService.decideUpgrade(owned, boost.trim, 1e9)
					t.expect(result.ok).toBe(false)
					t.expect(result.reason).toBe("wrongBase")
				end
			end
			t.expect(others).toBeGreaterThan(0)
		end)

		t.it("refuses a car the player doesn't own", function()
			local boost = upgrade()
			local result = DealershipService.decideUpgrade(nil, boost.trim, 1e9)
			t.expect(result.ok).toBe(false)
			t.expect(result.reason).toBe("notOwned")
		end)

		t.it("refuses a target that isn't an upgrade, or doesn't exist", function()
			local car = buyable()
			local owned = { vehicleId = car.vehicleId, trim = car.trim }
			t.expect(DealershipService.decideUpgrade(owned, car.trim, 1e9).reason).toBe("notUpgrade")
			t.expect(DealershipService.decideUpgrade(owned, "not_a_real_trim", 1e9).reason).toBe("unknownTrim")
		end)
	end)

	t.describe("the dealership layout", function()
		t.it("shows a dealership trim on every pad, cheapest first", function()
			for brandId, lineup in DealershipService.lineups() do
				t.expect(Brands[brandId] ~= nil).toBe(true)
				local previous = 0
				for _, entry in lineup do
					local trim = Catalog.getTrim(entry.vehicleId, entry.trim)
					t.expect(trim ~= nil).toBe(true)
					if trim then
						t.expect(trim.acquisition).toBe("dealership")
						t.expect(trim.upgradeFrom).toBe(nil)
					end
					t.expect(entry.price).toBeGreaterThan(0)
					t.expect(entry.price >= previous).toBe(true)
					previous = entry.price
				end
			end
		end)

		t.it("gives every brand one section and every dealership car a pad in it", function()
			local sections: { [string]: number } = {}
			for _, section in MapLayout.dealership.sections do
				t.expect(Brands[section.brandId] ~= nil).toBe(true)
				t.expect(sections[section.brandId]).toBe(nil) -- one section per brand
				sections[section.brandId] = #section.pads
			end
			for brandId in Brands do
				t.expect(sections[brandId] ~= nil).toBe(true)
			end
			local spares: { string } = {}
			for brandId, lineup in DealershipService.lineups() do
				local pads = sections[brandId] or 0
				if pads < #lineup then
					print(`  Dealership: {brandId} has {#lineup} cars for {pads} pads`)
				end
				t.expect(pads >= #lineup).toBe(true)
				table.insert(spares, `{brandId} {pads - #lineup}`)
			end
			table.sort(spares)
			print(`  Dealership spare pads: {table.concat(spares, ", ")}`)
		end)

		t.it("lays every pad out flat on the ground, the same size", function()
			local size = MapLayout.dealership.padSize
			t.expect(size.X).toBeGreaterThan(0)
			t.expect(size.Y).toBeGreaterThan(0)
			t.expect(size.Z).toBeGreaterThan(0)
			for _, section in MapLayout.dealership.sections do
				t.expect(#section.pads).toBeGreaterThan(0)
				for _, pad in section.pads do
					t.expect(pad.Position.Y).toBeNear(0, 1e-3)
					t.expect(pad.UpVector.Y).toBeNear(1, 1e-3)
				end
			end
		end)
	end)

	t.describe("Config/Dealership", function()
		t.it("runs 2-minute test drives with a cooldown, and words their length plainly", function()
			t.expect(Dealership.testDrive.seconds).toBe(120)
			t.expect(Dealership.testDrive.cooldownSeconds).toBeGreaterThan(0)
			t.expect(DealershipService.durationText(120)).toBe("2 minutes")
			t.expect(DealershipService.durationText(60)).toBe("1 minute")
			t.expect(DealershipService.durationText(90)).toBe("90 seconds")
		end)

		t.it("names a View prompt players can reach", function()
			t.expect(Dealership.prompt.actionText).toBe("View")
			t.expect(Dealership.prompt.maxDistance).toBeGreaterThan(0)
			t.expect(Dealership.prompt.vehicleIdAttribute).toBe("VehicleId")
			t.expect(Dealership.prompt.slotAttribute).toBe("Slot")
		end)
	end)
end
