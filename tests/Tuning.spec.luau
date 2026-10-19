--!strict
-- Per-trim physics numbers: complete and sane for every trim in the catalog, placed by the model contract, and
-- with enough grip to put the calibrated acceleration down.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Catalog = require(ReplicatedStorage.Shared.Vehicle.Catalog)
local Harness = require(ReplicatedStorage.Shared.Testing.Harness)
local Tuning = require(ReplicatedStorage.Shared.Vehicle.Tuning)

-- Grip must comfortably exceed the strongest launch: the driven wheels' limit at static load over the peak
-- acceleration, after Standard's traction-control share.
local GRIP_MARGIN = 1.5
local HUB_TOLERANCE = 1e-9

local function isPositiveFinite(value: number): boolean
	return value == value and value > 0 and value < math.huge
end

local function isFinite(value: number): boolean
	return value == value and math.abs(value) < math.huge
end

-- Every number in `tuning` is positive and finite, every Vector3 is finite. Returns the offending keys.
local function badFields(tuning: { [string]: any }): { string }
	local bad: { string } = {}
	for key, value in tuning do
		if type(value) == "number" then
			if not isPositiveFinite(value) then
				table.insert(bad, `{key}={value}`)
			end
		elseif type(value) == "table" then
			for index, item in value do
				local ok = if typeof(item) == "Vector3"
					then isFinite(item.X) and isFinite(item.Y) and isFinite(item.Z)
					else type(item) == "number" and isPositiveFinite(item)
				if not ok then
					table.insert(bad, `{key}.{index}={item}`)
				end
			end
		end
	end
	table.sort(bad)
	return bad
end

local function forEachTrim(callback: (vehicleId: string, trimId: string, drivable: boolean) -> ())
	for _, vehicleId in Catalog.vehicleIds() do
		local vehicle = Catalog.getVehicle(vehicleId)
		if vehicle then
			for _, trim in vehicle.trims do
				callback(vehicleId, trim.id, vehicle.playerDrivable)
			end
		end
	end
end

return function(t: Harness.Api)
	t.describe("Tuning", function()
		t.it("returns positive, finite numbers for every trim", function()
			local problems: { string } = {}
			forEachTrim(function(vehicleId, trimId)
				local tuning = Tuning.forTrim(vehicleId, trimId)
				if tuning == nil then
					table.insert(problems, `{vehicleId}/{trimId}: no tuning`)
					return
				end
				for _, field in badFields(tuning :: any) do
					table.insert(problems, `{vehicleId}/{trimId}: {field}`)
				end
			end)
			t.expect(problems).toEqual({})
		end)

		t.it("returns nil for an unknown trim or vehicle", function()
			t.expect(Tuning.forTrim("ohm_spark", "no_such_trim")).toBe(nil)
			t.expect(Tuning.forTrim("no_such_vehicle", "standard")).toBe(nil)
		end)

		t.it("caches each trim", function()
			t.expect(Tuning.forTrim("ohm_arc", "performance")).toBe(Tuning.forTrim("ohm_arc", "performance"))
		end)

		t.it("puts the hubs where the model contract puts the wheel attachments", function()
			local problems: { string } = {}
			forEachTrim(function(vehicleId, trimId)
				local tuning = Tuning.forTrim(vehicleId, trimId)
				local g = Catalog.geometry(vehicleId, trimId)
				assert(tuning, `{vehicleId}/{trimId} has a tuning`)
				assert(g, `{vehicleId}/{trimId} has a geometry`)
				local y = g.wheelRadius - (g.rideHeight + g.chassisHeight / 2)
				local expected: { [Tuning.WheelId]: Vector3 } = {
					FL = Vector3.new(-g.track / 2, y, -g.wheelbase / 2),
					FR = Vector3.new(g.track / 2, y, -g.wheelbase / 2),
					RL = Vector3.new(-g.track / 2, y, g.wheelbase / 2),
					RR = Vector3.new(g.track / 2, y, g.wheelbase / 2),
				}
				for id, position in expected do
					if (tuning.hubs[id] - position).Magnitude > HUB_TOLERANCE then
						table.insert(problems, `{vehicleId}/{trimId}: hub {id} at {tuning.hubs[id]}`)
					end
				end
			end)
			t.expect(problems).toEqual({})
		end)

		t.it("has the grip to put every drivable trim's launch down", function()
			local problems: { string } = {}
			forEachTrim(function(vehicleId, trimId, drivable)
				local tuning = Tuning.forTrim(vehicleId, trimId)
				assert(tuning, `{vehicleId}/{trimId} exists`)
				if drivable and tuning.tractionLimit < tuning.peakAccel * GRIP_MARGIN then
					table.insert(
						problems,
						`{vehicleId}/{trimId}: traction {tuning.tractionLimit} vs peak {tuning.peakAccel}`
					)
				end
			end)
			t.expect(problems).toEqual({})
		end)

		t.it("gives better-handling trims more grip and quicker cars a higher peak", function()
			local arc = Tuning.forTrim("ohm_arc", "performance")
			local hauler = Tuning.forTrim("ohm_hauler", "standard")
			local spark = Tuning.forTrim("ohm_spark", "standard")
			assert(arc and hauler and spark, "tunings exist")
			t.expect(arc.grip).toBeGreaterThan(spark.grip)
			t.expect(spark.grip).toBeGreaterThan(hauler.grip)
			t.expect(arc.peakAccel).toBeGreaterThan(spark.peakAccel)
			t.expect(arc.topSpeed).toBeGreaterThan(spark.topSpeed)
		end)

		t.it("brakes harder than it accelerates for everyday cars", function()
			local spark = Tuning.forTrim("ohm_spark", "standard")
			assert(spark, "spark tuning")
			t.expect(spark.brakeDecel).toBeGreaterThan(spark.peakAccel)
		end)
	end)
end
