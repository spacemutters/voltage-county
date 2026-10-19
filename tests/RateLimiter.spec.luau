--!strict
-- The per-player token bucket behind every remote's rate limit.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Harness = require(ReplicatedStorage.Shared.Testing.Harness)
local RateLimiter = require(ReplicatedStorage.Shared.Util.RateLimiter)

return function(t: Harness.Api)
	t.describe("RateLimiter", function()
		local now = 0
		local function clock(): number
			return now
		end

		t.beforeEach(function()
			now = 0
		end)

		t.it("allows a burst, then refuses", function()
			local limiter = RateLimiter.new(3, 1, clock)
			t.expect(limiter.take("a")).toBe(true)
			t.expect(limiter.take("a")).toBe(true)
			t.expect(limiter.take("a")).toBe(true)
			t.expect(limiter.take("a")).toBe(false)
		end)

		t.it("refills over time, never above the burst", function()
			local limiter = RateLimiter.new(2, 1, clock)
			limiter.take("a")
			limiter.take("a")
			t.expect(limiter.take("a")).toBe(false)
			now = 1
			t.expect(limiter.take("a")).toBe(true)
			t.expect(limiter.take("a")).toBe(false)
			now = 100
			t.expect(limiter.take("a")).toBe(true)
			t.expect(limiter.take("a")).toBe(true)
			t.expect(limiter.take("a")).toBe(false)
		end)

		t.it("keeps keys separate and forgets them", function()
			local limiter = RateLimiter.new(1, 0, clock)
			t.expect(limiter.take("a")).toBe(true)
			t.expect(limiter.take("b")).toBe(true)
			t.expect(limiter.take("a")).toBe(false)
			limiter.forget("a")
			t.expect(limiter.take("a")).toBe(true)
		end)
	end)
end
