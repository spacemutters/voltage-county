--!strict
-- The economy simulator (PLAN.md §4 deliverable): it runs, every profile reaches every milestone, better players
-- are never slower, and VIP is never slower. It also prints the mid profile's hours next to the §4 targets; how
-- close those land is the lead's tuning call, so the spec only reports them. Pure logic: runs in Edit mode.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Harness = require(ReplicatedStorage.Shared.Testing.Harness)
local EconSim = require(ServerScriptService.Server.Dev.EconSim)

type Run = EconSim.Run

-- Float sums of whole minutes: allow for rounding when comparing hours.
local HOURS_TOLERANCE = 1e-9

local function find(runs: { Run }, profile: EconSim.ProfileId, vip: boolean): Run
	for _, run in runs do
		if run.profile == profile and run.vip == vip then
			return run
		end
	end
	error(`no run for {profile} (vip = {vip})`)
end

return function(t: Harness.Api)
	local runs = EconSim.runAll()
	local milestoneCount = #EconSim.MILESTONES

	t.describe("EconSim", function()
		t.it("runs every profile with and without VIP", function()
			t.expect(#runs).toBe(#EconSim.PROFILES * 2)
			for _, profile in EconSim.PROFILES do
				t.expect(find(runs, profile.id, false).milestones[1] ~= nil).toBe(true)
				t.expect(find(runs, profile.id, true).milestones[1] ~= nil).toBe(true)
			end
		end)

		t.it("reaches every milestone in every run, in order", function()
			for _, run in runs do
				t.expect(#run.milestones).toBe(milestoneCount)
				local previous = 0
				for _, result in run.milestones do
					local hours = result.hours
					if hours == nil then
						error(`{run.label} never reaches "{result.label}"`)
					end
					t.expect(hours >= previous).toBe(true)
					previous = hours
				end
			end
		end)

		t.it("is never slower for a better player (grinder <= mid <= casual)", function()
			for _, vip in { false, true } do
				local casual, mid, grinder =
					find(runs, "casual", vip), find(runs, "mid", vip), find(runs, "grinder", vip)
				for index = 1, milestoneCount do
					local c, m, g =
						casual.milestones[index].hours, mid.milestones[index].hours, grinder.milestones[index].hours
					assert(c and m and g, "every milestone is reached")
					t.expect(g <= m + HOURS_TOLERANCE).toBe(true)
					t.expect(m <= c + HOURS_TOLERANCE).toBe(true)
				end
			end
		end)

		t.it("is never slower with VIP", function()
			for _, profile in EconSim.PROFILES do
				local plain, vip = find(runs, profile.id, false), find(runs, profile.id, true)
				for index = 1, milestoneCount do
					local withoutVip, withVip = plain.milestones[index].hours, vip.milestones[index].hours
					assert(withoutVip and withVip, "every milestone is reached")
					t.expect(withVip <= withoutVip + HOURS_TOLERANCE).toBe(true)
				end
			end
		end)

		t.it("is deterministic", function()
			local again = EconSim.runAll()
			for index, run in runs do
				for milestone = 1, milestoneCount do
					t.expect(again[index].milestones[milestone].hours).toBe(run.milestones[milestone].hours)
				end
			end
		end)

		t.it("reports the mid profile next to the §4 targets", function()
			for _, line in EconSim.format(runs) do
				print(line)
			end
			local comparison = EconSim.midComparison(runs)
			for _, line in comparison do
				print(line)
			end
			t.expect(#comparison).toBe(milestoneCount)
		end)
	end)
end
