--!strict
-- Remote payload validators reject anything that is not exactly the declared shape.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Check = require(ReplicatedStorage.Shared.Util.Check)
local Harness = require(ReplicatedStorage.Shared.Testing.Harness)

return function(t: Harness.Api)
	t.describe("Check", function()
		t.it("accepts numbers in range and rejects NaN and infinity", function()
			local speed = Check.number(0, 100)
			t.expect(speed(50)).toBe(true)
			t.expect(speed(101)).toBe(false)
			t.expect(speed(0 / 0)).toBe(false)
			t.expect(speed(math.huge)).toBe(false)
			t.expect(speed("50")).toBe(false)
		end)

		t.it("rejects fractions where an integer is required", function()
			t.expect(Check.integer(1, 10)(3)).toBe(true)
			t.expect(Check.integer(1, 10)(3.5)).toBe(false)
		end)

		t.it("caps string length", function()
			local name = Check.string(4)
			t.expect(name("abcd")).toBe(true)
			t.expect(name("abcde")).toBe(false)
			t.expect(name(4)).toBe(false)
		end)

		t.it("only allows listed options", function()
			local mode = Check.oneOf({ "comfort", "standard", "sport" })
			t.expect(mode("sport")).toBe(true)
			t.expect(mode("ludicrous")).toBe(false)
			t.expect(mode(nil)).toBe(false)
		end)

		t.it("rejects tables with undeclared keys", function()
			local buy = Check.shape({ vehicleId = Check.string(32), trim = Check.optional(Check.string(32)) })
			t.expect(buy({ vehicleId = "ohm_spark" })).toBe(true)
			t.expect(buy({ vehicleId = "ohm_spark", trim = "standard" })).toBe(true)
			t.expect(buy({ vehicleId = "ohm_spark", price = 0 })).toBe(false)
			t.expect(buy({})).toBe(false)
			t.expect(buy("ohm_spark")).toBe(false)
		end)

		t.it("rejects arrays that are too long or have gaps", function()
			local list = Check.array(Check.integer(0, 9), 3)
			t.expect(list({ 1, 2, 3 })).toBe(true)
			t.expect(list({ 1, 2, 3, 4 })).toBe(false)
			t.expect(list({ [1] = 1, [3] = 3 })).toBe(false)
			t.expect(list({ 1, "two" })).toBe(false)
		end)

		t.it("requires an empty payload for none()", function()
			t.expect(Check.none()(nil)).toBe(true)
			t.expect(Check.none()(false)).toBe(false)
		end)
	end)
end
