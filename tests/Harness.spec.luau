--!strict
-- Sample spec: proves the harness collects, runs and reports a test.

local Harness = require(game:GetService("ReplicatedStorage").Shared.Testing.Harness)

return function(t: Harness.Api)
	t.describe("Harness", function()
		t.it("runs a passing test", function()
			t.expect(1 + 1).toBe(2)
		end)
	end)
end
