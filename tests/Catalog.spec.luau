--!strict
-- The catalog is complete and every trim sits inside its class band (PLAN.md §3.3). The price ladder holds
-- (docs/roast-2026-10-24.md point 5): only the top tiers launch under 3 s, and their bands out-launch and out-grip
-- every class below them; nothing for sale is a downgrade from the free starter; and within a brand every dearer
-- car is better than each cheaper one at something a player feels.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Brands = require(ReplicatedStorage.Shared.Config.Brands)
local Catalog = require(ReplicatedStorage.Shared.Vehicle.Catalog)
local Classes = require(ReplicatedStorage.Shared.Config.Classes)
local Economy = require(ReplicatedStorage.Shared.Config.Economy)
local Harness = require(ReplicatedStorage.Shared.Testing.Harness)
local Jobs = require(ReplicatedStorage.Shared.Config.Jobs)
local Units = require(ReplicatedStorage.Shared.Util.Units)
local UsedLot = require(ReplicatedStorage.Shared.Config.UsedLot)

-- Launch catalog size (PLAN.md §3.3, docs/phase-4-contracts.md "Catalog expansion").
local MIN_VEHICLES = 30
local MIN_PER_BRAND = 3
local MIN_USED_LOT = 6

-- The price ladder (docs/roast-2026-10-24.md point 5): classes in tiers from TOP_TIER up (exotic, hypercar) are the
-- only ones whose band reaches under LADDER_FLOOR_SEC to 60.
local TOP_TIER = 4
local LADDER_FLOOR_SEC = 3
-- A first car a new player can save up for in their first session or two (the Fernlows on the used lot, the Tovi).
local CHEAP_PRICE = 40000
-- How a car is sold for cash (the starter, the fleet pod and limited drops aren't).
local CASH_ACQUISITIONS: { [string]: boolean } = { dealership = true, usedLot = true }

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

-- A trim with what the ladder compares: its vehicle and its total price.
type Offer = { name: string, vehicle: any, trim: any, price: number }

-- Every drivable trim sold for cash, by its total price (an upgrade trim counts the trim it upgrades).
local function cashOffers(): { Offer }
	local offers: { Offer } = {}
	for _, vehicle in allVehicles() do
		if not vehicle.playerDrivable then
			continue
		end
		for _, trim in vehicle.trims do
			local price = Catalog.totalPrice(vehicle.id, trim.id)
			if CASH_ACQUISITIONS[trim.acquisition] and price ~= nil then
				table.insert(offers, { name = `{vehicle.id}/{trim.id}`, vehicle = vehicle, trim = trim, price = price })
			end
		end
	end
	return offers
end

-- The most a car can earn a minute (Config/Economy.activities, the PLAN.md §4 rates): free driving, or the best job
-- its class and features can take (Config/Jobs), with rideshare XL and the delivery bonus where they apply. What a
-- van, a pickup or a semi is for.
local function workRate(vehicle: any, trim: any): number
	local rates: { [string]: number } = Economy.activities :: any
	local best = rates.freeDrive
	for jobId, job in Jobs.types do
		local rate = rates[jobId]
		if rate == nil or table.find(job.classes, vehicle.class) == nil then
			continue
		end
		local feature = job.requiresFeature
		if feature ~= nil and table.find(vehicle.features, feature) == nil then
			continue
		end
		local xlClasses, xlSeats, xlMultiplier = job.xlClasses, job.xlMinSeats, job.xlMultiplier
		local xl = (xlClasses ~= nil and table.find(xlClasses, vehicle.class) ~= nil)
			or (xlSeats ~= nil and trim.seats >= xlSeats)
		if xl and xlMultiplier ~= nil then
			rate *= xlMultiplier
		end
		local bonusClasses, bonusMultiplier = job.bonusClasses, job.bonusMultiplier
		if bonusClasses ~= nil and bonusMultiplier ~= nil and table.find(bonusClasses, vehicle.class) ~= nil then
			rate *= bonusMultiplier
		end
		best = math.max(best, rate)
	end
	return best
end

-- What `a` is better at than `b`, of the things a player feels: top speed, 0-60, handling, seats, range and pay.
local function betterAt(a: Offer, b: Offer): { string }
	local ta, tb = a.trim, b.trim
	local edges: { string } = {}
	if ta.topSpeedMph > tb.topSpeedMph then
		table.insert(edges, "top speed")
	end
	if ta.zeroToSixtySec < tb.zeroToSixtySec then
		table.insert(edges, "0-60")
	end
	if ta.handling > tb.handling then
		table.insert(edges, "handling")
	end
	if ta.seats > tb.seats then
		table.insert(edges, "seats")
	end
	if (ta.energyMinutes or 0) > (tb.energyMinutes or 0) then
		table.insert(edges, "range")
	end
	if workRate(a.vehicle, ta) > workRate(b.vehicle, tb) then
		table.insert(edges, "work")
	end
	return edges
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

	t.describe("Catalog price ladder", function()
		t.it(`keeps every class below tier {TOP_TIER} at {LADDER_FLOOR_SEC} s or slower to 60`, function()
			local problems: { string } = {}
			for classId, class in Classes do
				if class.tier < TOP_TIER and class.zeroToSixtySec.min < LADDER_FLOOR_SEC then
					table.insert(problems, `{classId}: band allows {class.zeroToSixtySec.min} s`)
				end
			end
			table.sort(problems)
			t.expect(problems).toEqual({})
		end)

		-- Band against band, so designs and AI mods keep the order too: the slowest top-tier car is still quicker to
		-- 60 and grippier than the best of any class below.
		t.it(`puts every tier {TOP_TIER}+ band ahead of every lower band on 0-60 and handling`, function()
			local problems: { string } = {}
			for topId, top in Classes do
				if top.tier < TOP_TIER then
					continue
				end
				for classId, class in Classes do
					if class.tier >= TOP_TIER then
						continue
					end
					if class.zeroToSixtySec.min <= top.zeroToSixtySec.max then
						table.insert(problems, `{classId} reaches 60 as soon as the slowest {topId}`)
					end
					if class.handling.max >= top.handling.min then
						table.insert(problems, `{classId} handles as well as the loosest {topId}`)
					end
				end
			end
			table.sort(problems)
			t.expect(problems).toEqual({})
		end)

		t.it("makes no car for sale a downgrade from the free starter", function()
			local starter = UsedLot.starter
			local vehicle = Catalog.getVehicle(starter.vehicleId)
			local trim = Catalog.getTrim(starter.vehicleId, starter.trim)
			assert(vehicle and trim, "the starter is in the catalog")
			local free: Offer = { name = "starter", vehicle = vehicle, trim = trim, price = 0 }
			local problems: { string } = {}
			for _, offer in cashOffers() do
				if #betterAt(offer, free) == 0 then
					table.insert(problems, `{offer.name} (${offer.price}) is better than the starter at nothing`)
				end
			end
			table.sort(problems)
			t.expect(problems).toEqual({})
		end)

		t.it("makes every dearer car of a brand better at something than each cheaper one", function()
			local offers = cashOffers()
			local problems: { string } = {}
			for _, dearer in offers do
				for _, cheaper in offers do
					if
						dearer.vehicle.brandId == cheaper.vehicle.brandId
						and dearer.price > cheaper.price
						and #betterAt(dearer, cheaper) == 0
					then
						table.insert(
							problems,
							`{dearer.name} (${dearer.price}) is better than {cheaper.name} (${cheaper.price}) at nothing`
						)
					end
				end
			end
			table.sort(problems)
			t.expect(problems).toEqual({})
		end)

		-- Range or seats alone don't make a cheap car worth buying over the free one (roast 2026-10-24 point 5): it has
		-- to be quicker, faster or better paid (a work van).
		t.it(`makes every car under ${CHEAP_PRICE} quicker, faster or better paid than the free starter`, function()
			local starter = UsedLot.starter
			local vehicle = Catalog.getVehicle(starter.vehicleId)
			local trim = Catalog.getTrim(starter.vehicleId, starter.trim)
			assert(vehicle and trim, "the starter is in the catalog")
			local free: Offer = { name = "starter", vehicle = vehicle, trim = trim, price = 0 }
			local problems: { string } = {}
			for _, offer in cashOffers() do
				if offer.price >= CHEAP_PRICE then
					continue
				end
				local edges = betterAt(offer, free)
				if
					table.find(edges, "0-60") == nil
					and table.find(edges, "top speed") == nil
					and table.find(edges, "work") == nil
				then
					table.insert(
						problems,
						`{offer.name} (${offer.price}) is only better at {table.concat(edges, ", ")}`
					)
				end
			end
			table.sort(problems)
			t.expect(problems).toEqual({})
		end)

		-- Prove the ladder checks fire before trusting them on the catalog.
		t.it("catches a car that is better at nothing", function()
			local spark = Catalog.getVehicle("ohm_spark")
			local standard = Catalog.getTrim("ohm_spark", "standard")
			assert(spark and standard, "the Spark is in the catalog")
			local base: Offer = { name = "base", vehicle = spark, trim = standard, price = 1 }
			local slower = table.clone(standard)
			slower.topSpeedMph -= 1
			local copy: Offer = { name = "copy", vehicle = spark, trim = table.clone(standard), price = 2 }
			local worse: Offer = { name = "worse", vehicle = spark, trim = slower, price = 2 }
			t.expect(betterAt(copy, base)).toEqual({})
			t.expect(betterAt(worse, base)).toEqual({})
			t.expect(betterAt(base, worse)).toEqual({ "top speed" })
			-- A van earns more than a sedan it is slower than (the delivery bonus).
			local van = Catalog.getVehicle("northline_satchel")
			local vanTrim = Catalog.getTrim("northline_satchel", "standard")
			assert(van and vanTrim, "the Satchel is in the catalog")
			t.expect(workRate(van, vanTrim)).toBeGreaterThan(workRate(spark, standard))
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
