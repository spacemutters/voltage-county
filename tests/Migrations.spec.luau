--!strict
-- PlayerData migrations (CLAUDE.md hard rule 7; PLAN.md Phase 3 acceptance: migration specs pass; Phase 4 adds
-- schema version 3, docs/phase-4-contracts.md "Data changes"; Phase 5 adds version 4, docs/phase-5-contracts.md
-- "Schema v4"; Phase 7 adds version 5, docs/phase-7-contracts.md "Schema v5"). Pure logic: runs in Edit mode.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Catalog = require(ReplicatedStorage.Shared.Vehicle.Catalog)
local Data = require(ReplicatedStorage.Shared.Config.Data)
local Harness = require(ReplicatedStorage.Shared.Testing.Harness)
local Migrations = require(ServerScriptService.Server.Services.DataService.Migrations)
local Template = require(ServerScriptService.Server.Services.DataService.Template)

local JOIN_TIME = 1700000000 -- any fixed os.time()

-- A car as a version 1 or 2 save stored it (no `favorite`, no `paid`).
local function oldCar(uid: string, vehicleId: string, trim: string): { [string]: any }
	return {
		uid = uid,
		vehicleId = vehicleId,
		trim = trim,
		paint = "white",
		finish = "gloss",
		wheels = "stock",
		rideHeight = 0,
		tint = 0.2,
		acquiredAt = JOIN_TIME,
	}
end

-- A version 2 save with some player-owned data in it: the free starter, a bought Spark, an upgraded Arc (its
-- price includes the trim it upgrades), a limited drop (never sold for cash), a player design and a car whose
-- trim the catalog no longer has.
local function v2Save(): { [string]: any }
	local data: { [string]: any } = Template.new(JOIN_TIME) :: any
	data.version = 2
	data.cash = 48250
	data.starterClaimed = true
	data.vehicles = {
		oldCar("car-starter", "ohm_spark", "used"),
		oldCar("car-spark", "ohm_spark", "standard"),
		oldCar("car-arc", "ohm_arc", "boost"),
		oldCar("car-flight", "ohm_arc", "flight"),
		oldCar("car-custom", "custom", "base"),
		oldCar("car-gone", "ohm_spark", "retired_trim"),
	}
	data.vehicles[5].designUid = "design-1"
	data.vehicles[2].plateText = "VOLT 1"
	data.codesRedeemed = { LAUNCH = true }
	data.receipts = { "purchase-1", "purchase-2" }
	data.boosts = { { id = "LAUNCH2X", factor = 2, endsAt = JOIN_TIME + 1800 } }
	return data
end

-- A version 1 save as the Phase 1-2 template wrote it (no boosts).
local function v1Save(): { [string]: any }
	local data = v2Save()
	data.version = 1
	data.boosts = nil
	return data
end

-- A version 3 save as the Phase 4 template wrote it: every car has `favorite` and `paid`, none has `energy`.
local function v3Save(): { [string]: any }
	local data = v2Save()
	data.version = 3
	for _, car in data.vehicles do
		car.favorite = false
		car.paid = 0
	end
	data.vehicles[2].favorite = true
	data.vehicles[2].paid = 35000
	return data
end

-- A version 4 save as the Phase 5 template wrote it: every car has `energy`, none has `caliper`, `extras` or
-- `plateFormat`. One car already wears a wrap and custom plate text from before the shop opened.
local function v4Save(): { [string]: any }
	local data = v3Save()
	data.version = 4
	for _, car in data.vehicles do
		car.energy = 1
	end
	data.vehicles[1].energy = 0.35
	data.vehicles[2].wrap = "old_wrap"
	return data
end

-- The v5 look fields, for the "only these were added" checks.
local V5_FIELDS = { caliper = true, extras = true, plateFormat = true }

local function keysOf(t: { [any]: any }): { [string]: boolean }
	local keys = {}
	for key in t do
		keys[tostring(key)] = true
	end
	return keys
end

local function deepCopy(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local copy = {}
	for key, item in value do
		copy[key] = deepCopy(item)
	end
	return copy
end

-- The car with `uid` in a migrated save.
local function carIn(data: { [string]: any }, uid: string): { [string]: any }
	for _, car in data.vehicles do
		if car.uid == uid then
			return car
		end
	end
	error(`no car {uid} in the migrated save`)
end

return function(t: Harness.Api)
	t.describe("Migrations", function()
		t.it("is at schema version 5", function()
			t.expect(Data.schemaVersion).toBe(5)
		end)

		t.it("has a step from every older version up to the schema version", function()
			for version = Data.unversionedVersion, Data.schemaVersion - 1 do
				t.expect(type(Migrations.steps[version])).toBe("function")
			end
		end)

		t.it("upgrades a version 1 save without boosts to the latest version with boosts = {}", function()
			local migrated, fromVersion = Migrations.run(v1Save())
			t.expect(fromVersion).toBe(1)
			t.expect(migrated.version).toBe(Data.schemaVersion)
			t.expect(migrated.boosts).toEqual({})
		end)

		t.it("treats a save with no version field as version 1", function()
			local save = v1Save()
			save.version = nil
			local migrated, fromVersion = Migrations.run(save)
			t.expect(fromVersion).toBe(Data.unversionedVersion)
			t.expect(fromVersion).toBe(1)
			t.expect(migrated.version).toBe(Data.schemaVersion)
			t.expect(migrated.boosts).toEqual({})
			t.expect(carIn(migrated, "car-spark").favorite).toBe(false)
		end)

		t.it("keeps boosts a version 1 save somehow already has", function()
			local save = v1Save()
			save.boosts = { { id = "LAUNCH2X", factor = 2, endsAt = JOIN_TIME + 1800 } }
			local migrated = Migrations.run(save)
			t.expect(#migrated.boosts).toBe(1)
			t.expect(migrated.boosts[1].factor).toBe(2)
		end)

		t.it("2 -> 3: every owned car gains favorite = false", function()
			local migrated, fromVersion = Migrations.run(v2Save())
			t.expect(fromVersion).toBe(2)
			t.expect(migrated.version).toBe(Data.schemaVersion)
			t.expect(#migrated.vehicles).toBe(6)
			for _, car in migrated.vehicles do
				t.expect(car.favorite).toBe(false)
			end
		end)

		t.it("2 -> 3: paid is the catalog price of the car's trim", function()
			local migrated = Migrations.run(v2Save())
			t.expect(carIn(migrated, "car-spark").paid).toBe(Catalog.totalPrice("ohm_spark", "standard"))
			t.expect(carIn(migrated, "car-spark").paid > 0).toBe(true)
			-- An upgrade trim counts the trim it upgrades as well.
			local arcPaid = carIn(migrated, "car-arc").paid
			t.expect(arcPaid).toBe(Catalog.totalPrice("ohm_arc", "boost"))
			t.expect(arcPaid > (Catalog.totalPrice("ohm_arc", "performance") :: number)).toBe(true)
		end)

		t.it("2 -> 3: paid is 0 for cars never sold for cash or no longer in the catalog", function()
			local migrated = Migrations.run(v2Save())
			t.expect(carIn(migrated, "car-starter").paid).toBe(0) -- the free starter
			t.expect(carIn(migrated, "car-flight").paid).toBe(0) -- a limited drop
			t.expect(carIn(migrated, "car-custom").paid).toBe(0) -- a player design
			t.expect(carIn(migrated, "car-gone").paid).toBe(0) -- a trim the catalog dropped
		end)

		t.it("2 -> 3: keeps favorite and paid a car already has", function()
			local save = v2Save()
			save.vehicles[2].favorite = true
			save.vehicles[2].paid = 12345
			local migrated = Migrations.run(save)
			t.expect(carIn(migrated, "car-spark").favorite).toBe(true)
			t.expect(carIn(migrated, "car-spark").paid).toBe(12345)
		end)

		t.it("2 -> 3: survives damaged vehicle lists and entries", function()
			local missing = v2Save()
			missing.vehicles = nil
			local migrated = Migrations.run(missing)
			t.expect(migrated.version).toBe(Data.schemaVersion)
			t.expect(migrated.vehicles).toBe(nil) -- left for Reconcile to fill from the template

			local damaged = v2Save()
			damaged.vehicles =
				{ "not a car", oldCar("car-ok", "ohm_spark", "standard"), { uid = "car-bare" } } :: { any }
			local fixed = Migrations.run(damaged)
			t.expect(fixed.vehicles[1]).toBe("not a car")
			t.expect(carIn(fixed, "car-ok").favorite).toBe(false)
			t.expect(carIn(fixed, "car-bare").paid).toBe(0)
		end)

		t.it("3 -> 4: every owned car gains a full energy level", function()
			local migrated, fromVersion = Migrations.run(v3Save())
			t.expect(fromVersion).toBe(3)
			t.expect(migrated.version).toBe(Data.schemaVersion)
			t.expect(#migrated.vehicles).toBe(6)
			for _, car in migrated.vehicles do
				t.expect(car.energy).toBe(1)
				t.expect(car.energy).toBe(Data.defaults.vehicleEnergy)
			end
			-- What version 3 added is untouched.
			t.expect(carIn(migrated, "car-spark").favorite).toBe(true)
			t.expect(carIn(migrated, "car-spark").paid).toBe(35000)
		end)

		t.it("3 -> 4: older saves reach the latest version with full cars too", function()
			for _, makeSave in { v1Save, v2Save } do
				local migrated = Migrations.run(makeSave())
				t.expect(migrated.version).toBe(Data.schemaVersion)
				for _, car in migrated.vehicles do
					t.expect(car.energy).toBe(1)
				end
			end
		end)

		t.it("3 -> 4: keeps a level a car already has, pulled into 0..1", function()
			local save = v3Save()
			save.vehicles[1].energy = 0.42
			save.vehicles[2].energy = 0
			save.vehicles[3].energy = 1.7
			save.vehicles[4].energy = -0.3
			local migrated = Migrations.run(save)
			t.expect(carIn(migrated, "car-starter").energy).toBe(0.42)
			t.expect(carIn(migrated, "car-spark").energy).toBe(0)
			t.expect(carIn(migrated, "car-arc").energy).toBe(1)
			t.expect(carIn(migrated, "car-flight").energy).toBe(0)
		end)

		t.it("3 -> 4: replaces a level that isn't a number with a full one", function()
			local save = v3Save()
			save.vehicles[1].energy = "half" :: any
			save.vehicles[2].energy = 0 / 0
			save.vehicles[3].energy = true :: any
			local migrated = Migrations.run(save)
			t.expect(carIn(migrated, "car-starter").energy).toBe(1)
			t.expect(carIn(migrated, "car-spark").energy).toBe(1)
			t.expect(carIn(migrated, "car-arc").energy).toBe(1)
		end)

		t.it("3 -> 4: survives damaged vehicle lists and entries", function()
			local missing = v3Save()
			missing.vehicles = nil
			local migrated = Migrations.run(missing)
			t.expect(migrated.version).toBe(Data.schemaVersion)
			t.expect(migrated.vehicles).toBe(nil) -- left for Reconcile to fill from the template

			local damaged = v3Save()
			damaged.vehicles = { "junk", { uid = "car-bare" } } :: { any }
			local fixed = Migrations.run(damaged)
			t.expect(fixed.vehicles[1]).toBe("junk")
			t.expect(carIn(fixed, "car-bare").energy).toBe(1)
		end)

		t.it("running the 3 -> 4 step twice changes nothing the second time", function()
			local save = v3Save()
			save.vehicles[1].energy = 0.25
			Migrations.steps[3](save)
			local once = deepCopy(save)
			Migrations.steps[3](save)
			t.expect(save).toEqual(once)
		end)

		t.it("4 -> 5: every owned car gains the stock caliper, plate format and no extras", function()
			local migrated, fromVersion = Migrations.run(v4Save())
			t.expect(fromVersion).toBe(4)
			t.expect(migrated.version).toBe(5)
			t.expect(#migrated.vehicles).toBe(6)
			for _, car in migrated.vehicles do
				t.expect(car.caliper).toBe(Data.defaults.vehicleLook.caliper)
				t.expect(car.plateFormat).toBe(Data.defaults.vehicleLook.plateFormat)
				t.expect(car.extras).toEqual({})
			end
			-- Every car gets its own extras list, never a shared one.
			t.expect(migrated.vehicles[1].extras == migrated.vehicles[2].extras).toBe(false)
		end)

		t.it("4 -> 5: moves the old white default to the factory paint and keeps any other paint", function()
			local save = v4Save()
			save.vehicles[3].paint = "cobalt"
			local migrated = Migrations.run(save)
			t.expect(carIn(migrated, "car-spark").paint).toBe(Data.defaults.vehicleLook.paint)
			t.expect(carIn(migrated, "car-spark").paint).toBe("factory")
			t.expect(carIn(migrated, "car-arc").paint).toBe("cobalt")
		end)

		t.it("4 -> 5: leaves the rest of the existing look, energy and plate text alone", function()
			local migrated = Migrations.run(v4Save())
			local spark = carIn(migrated, "car-spark")
			t.expect(spark.finish).toBe("gloss")
			t.expect(spark.wheels).toBe("stock")
			t.expect(spark.wrap).toBe("old_wrap")
			t.expect(spark.tint).toBe(0.2)
			t.expect(spark.plateText).toBe("VOLT 1") -- raw, as typed: filtered whenever it is shown
			t.expect(spark.favorite).toBe(true)
			t.expect(spark.paid).toBe(35000)
			t.expect(carIn(migrated, "car-starter").energy).toBe(0.35)
		end)

		t.it("4 -> 5: older saves reach version 5 with the new fields too", function()
			for _, makeSave in { v1Save, v2Save, v3Save } do
				local migrated = Migrations.run(makeSave())
				t.expect(migrated.version).toBe(5)
				for _, car in migrated.vehicles do
					t.expect(car.caliper).toBe(Data.defaults.vehicleLook.caliper)
					t.expect(car.plateFormat).toBe(Data.defaults.vehicleLook.plateFormat)
					t.expect(car.extras).toEqual({})
					t.expect(car.energy).toBe(1)
				end
			end
		end)

		t.it("4 -> 5: keeps values a car already has and replaces ones of the wrong type", function()
			local save = v4Save()
			save.vehicles[1].caliper = "red"
			save.vehicles[1].extras = { "spoiler" }
			save.vehicles[1].plateFormat = "classic"
			save.vehicles[2].caliper = 7 :: any
			save.vehicles[2].extras = "spoiler" :: any
			save.vehicles[2].plateFormat = false :: any
			local migrated = Migrations.run(save)
			local starter = carIn(migrated, "car-starter")
			t.expect(starter.caliper).toBe("red")
			t.expect(starter.extras).toEqual({ "spoiler" })
			t.expect(starter.plateFormat).toBe("classic")
			local spark = carIn(migrated, "car-spark")
			t.expect(spark.caliper).toBe(Data.defaults.vehicleLook.caliper)
			t.expect(spark.extras).toEqual({})
			t.expect(spark.plateFormat).toBe(Data.defaults.vehicleLook.plateFormat)
		end)

		t.it("4 -> 5: survives damaged vehicle lists and entries", function()
			local missing = v4Save()
			missing.vehicles = nil
			local migrated = Migrations.run(missing)
			t.expect(migrated.version).toBe(5)
			t.expect(migrated.vehicles).toBe(nil) -- left for Reconcile to fill from the template

			local damaged = v4Save()
			damaged.vehicles = { "wreck", { uid = "car-bare" } } :: { any }
			local fixed = Migrations.run(damaged)
			t.expect(fixed.vehicles[1]).toBe("wreck")
			t.expect(carIn(fixed, "car-bare").caliper).toBe(Data.defaults.vehicleLook.caliper)
			t.expect(carIn(fixed, "car-bare").extras).toEqual({})
		end)

		t.it("running the 4 -> 5 step twice changes nothing the second time", function()
			local save = v4Save()
			save.vehicles[3].extras = { "roof_rack" }
			Migrations.steps[4](save)
			local once = deepCopy(save)
			Migrations.steps[4](save)
			t.expect(save).toEqual(once)
		end)

		t.it("the stock look the 4 -> 5 step gives is the one a new car gets", function()
			local car = Template.ownedVehicle("car-new", "ohm_spark", "standard", 30000, JOIN_TIME)
			local migrated = Migrations.run(v4Save())
			t.expect(migrated.vehicles[1].caliper).toBe(car.caliper)
			t.expect(migrated.vehicles[1].plateFormat).toBe(car.plateFormat)
			t.expect(migrated.vehicles[1].extras).toEqual(car.extras)
		end)

		t.it("never drops a field and keeps every player-owned value", function()
			for _, makeSave in { v1Save, v2Save, v3Save, v4Save } do
				local before = makeSave()
				local snapshot = deepCopy(before)
				local migrated = Migrations.run(before)
				local after = keysOf(migrated)
				for key in keysOf(snapshot) do
					t.expect(after[key]).toBe(true)
				end
				for key, value in snapshot do
					if key ~= "version" and key ~= "vehicles" and key ~= "boosts" then
						t.expect(migrated[key]).toEqual(value)
					end
				end
				-- Cars: same cars in the same order, every old field kept as it was; only the new fields added.
				t.expect(#migrated.vehicles).toBe(#snapshot.vehicles)
				for index, oldCarValue in snapshot.vehicles do
					local newCar = migrated.vehicles[index]
					for field, value in oldCarValue do
						if field == "paint" and value == Data.defaults.vehicleLook.oldDefaultPaint then
							-- The one value 4 -> 5 rewrites: the pre-shop "as built" default.
							t.expect(newCar[field]).toBe(Data.defaults.vehicleLook.paint)
						else
							t.expect(newCar[field]).toEqual(value)
						end
					end
					for field in newCar do
						local isNew = field == "favorite"
							or field == "paid"
							or field == "energy"
							or V5_FIELDS[field] == true
						t.expect(oldCarValue[field] ~= nil or isNew).toBe(true)
					end
				end
			end
		end)

		t.it("leaves a save at the latest version unchanged (idempotent)", function()
			local current: { [string]: any } = Template.new(JOIN_TIME) :: any
			current.cash = 777
			table.insert(current.vehicles, Template.ownedVehicle("car-new", "ohm_spark", "standard", 30000, JOIN_TIME))
			current.vehicles[1].favorite = true
			local snapshot = deepCopy(current)
			local migrated, fromVersion = Migrations.run(current)
			t.expect(fromVersion).toBe(Data.schemaVersion)
			t.expect(migrated).toEqual(snapshot)
			local again, againFrom = Migrations.run(migrated)
			t.expect(againFrom).toBe(Data.schemaVersion)
			t.expect(again).toEqual(snapshot)
		end)

		t.it("running the 2 -> 3 step twice changes nothing the second time", function()
			local save = v2Save()
			Migrations.steps[2](save)
			local once = deepCopy(save)
			Migrations.steps[2](save)
			t.expect(save).toEqual(once)
		end)

		t.it("refuses a save from a newer version and leaves it untouched", function()
			local future: { [string]: any } = Template.new(JOIN_TIME) :: any
			future.version = Data.schemaVersion + 1
			future.somethingNew = { kept = true }
			local snapshot = deepCopy(future)
			t.expect(function()
				Migrations.run(future)
			end).toThrow("newer")
			t.expect(future).toEqual(snapshot)
		end)

		t.it("refuses a nonsense version", function()
			for _, bad in { 0, -1, 1.5, "2" } :: { any } do
				local save = v1Save()
				save.version = bad
				t.expect(function()
					Migrations.run(save)
				end).toThrow("invalid")
			end
		end)
	end)
end
