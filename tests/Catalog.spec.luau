--!strict
-- The catalog is complete and every trim sits inside its class band (PLAN.md §3.3).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Catalog = require(ReplicatedStorage.Shared.Vehicle.Catalog)
local Harness = require(ReplicatedStorage.Shared.Testing.Harness)
local Units = require(ReplicatedStorage.Shared.Util.Units)

return function(t: Harness.Api)
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
			t.expect(Catalog.totalPrice("ohm_arc", "boost")).toBe(4000000)
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
