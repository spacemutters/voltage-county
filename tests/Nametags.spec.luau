--!strict
-- Nametags (docs/phase-13-contracts.md "Social"): the job title a player wears (Config/Social.bestTitle over their job
-- XP, which Services/SocialSetupService publishes): none without job XP, the best level wins, ties go to more XP and
-- then to Config/Jobs.order; every level in Config/Jobs has a title; and when a nametag hides (Controllers/
-- NametagController.speedHidden and visible: driving fast, with a gap so it doesn't flicker, and cutscenes).
-- Pure logic: runs in Edit mode.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")

local Harness = require(ReplicatedStorage.Shared.Testing.Harness)
local Jobs = require(ReplicatedStorage.Shared.Config.Jobs)
local Social = require(ReplicatedStorage.Shared.Config.Social)

local Client = StarterPlayer.StarterPlayerScripts.Client
local NametagController = require(Client.Controllers.NametagController)

local nametag = Social.nametag

-- The XP that reaches `level` in `jobType` exactly.
local function xpFor(jobType: string, level: number): number
	return Jobs.levels[jobType][level].xp
end

return function(t: Harness.Api)
	t.describe("Nametag titles", function()
		t.it("has no title without job XP", function()
			t.expect(Social.bestTitle(nil)).toBe(nil)
			t.expect(Social.bestTitle({})).toBe(nil)
			t.expect(Social.bestTitle({ rideshare = 0, delivery = 0 })).toBe(nil)
		end)

		t.it("gives a first job's level-1 title", function()
			t.expect(Social.bestTitle({ rideshare = 10 })).toBe(Jobs.levels.rideshare[1].title)
			t.expect(Social.bestTitle({ freight = 1 })).toBe("Freight Hauler")
		end)

		t.it("names the level reached, from its threshold on", function()
			local second = xpFor("freight", 2)
			t.expect(Social.bestTitle({ freight = second - 1 })).toBe("Freight Hauler")
			t.expect(Social.bestTitle({ freight = second })).toBe("Freight Hauler II")
			local top = #Jobs.levels.freight
			t.expect(Social.bestTitle({ freight = xpFor("freight", top) * 10 })).toBe(Jobs.levels.freight[top].title)
		end)

		t.it("picks the job with the highest level", function()
			local xp = { delivery = xpFor("delivery", 3), freight = xpFor("freight", 2) + 100 }
			t.expect(Social.bestTitle(xp)).toBe(Jobs.levels.delivery[3].title)
		end)

		t.it("breaks a level tie by more XP", function()
			local xp = { towing = xpFor("towing", 2) + 300, freight = xpFor("freight", 2) + 100 }
			t.expect(Social.bestTitle(xp)).toBe(Jobs.levels.towing[2].title)
		end)

		t.it("breaks an exact tie by the order jobs are listed in", function()
			local first, second = Jobs.order[1], Jobs.order[2]
			local xp = { [second] = xpFor(second, 2), [first] = xpFor(first, 2) }
			t.expect(Social.bestTitle(xp)).toBe(Jobs.levels[first][2].title)
		end)

		t.it("ignores bad XP and jobs it doesn't know", function()
			t.expect(Social.bestTitle({ rideshare = -50 })).toBe(nil)
			t.expect(Social.bestTitle({ rideshare = 0 / 0 })).toBe(nil)
			t.expect(Social.bestTitle({ astronaut = 9999 })).toBe(nil)
			t.expect(Social.bestTitle({ astronaut = 9999, delivery = 5 })).toBe(Jobs.levels.delivery[1].title)
		end)

		t.it("has a title on every level of every job, different at each level", function()
			for _, jobType in Jobs.order do
				local seen: { [string]: boolean } = {}
				for level, def in Jobs.levels[jobType] do
					local title = def.title
					t.expect(`{jobType} {level}: {type(title)}`).toBe(`{jobType} {level}: string`)
					if title ~= nil then
						t.expect(seen[title]).toBe(nil)
						seen[title] = true
						t.expect(#title > 0 and #title <= 24).toBe(true) -- fits the nametag on one line
					end
				end
			end
		end)

		t.it("uses the contract's example title", function()
			t.expect(Jobs.levels.freight[2].title).toBe("Freight Hauler II")
		end)
	end)

	t.describe("Nametag visibility", function()
		t.it("shows on foot and in a slow car", function()
			t.expect(NametagController.speedHidden(false, nil)).toBe(false)
			t.expect(NametagController.speedHidden(false, 0)).toBe(false)
			t.expect(NametagController.speedHidden(false, nametag.hideAboveMph)).toBe(false)
		end)

		t.it("hides in a fast car", function()
			t.expect(NametagController.speedHidden(false, nametag.hideAboveMph + 1)).toBe(true)
		end)

		t.it("stays hidden until the car is well below the hiding speed", function()
			local between = (nametag.hideAboveMph + nametag.showBelowMph) / 2
			t.expect(NametagController.speedHidden(true, between)).toBe(true)
			t.expect(NametagController.speedHidden(false, between)).toBe(false)
			t.expect(NametagController.speedHidden(true, nametag.showBelowMph - 1)).toBe(false)
			t.expect(NametagController.speedHidden(true, nil)).toBe(false) -- got out
		end)

		t.it("keeps a gap between hiding and showing again", function()
			t.expect(nametag.showBelowMph).toBeLessThan(nametag.hideAboveMph)
			t.expect(nametag.showBelowMph).toBeGreaterThan(0)
		end)

		t.it("hides during a cutscene", function()
			t.expect(NametagController.visible(false, false)).toBe(true)
			t.expect(NametagController.visible(true, false)).toBe(false)
			t.expect(NametagController.visible(false, true)).toBe(false)
		end)

		t.it("keeps its text readable", function()
			t.expect(nametag.nameTextSize >= 14).toBe(true)
			t.expect(nametag.titleTextSize >= 12).toBe(true)
			t.expect(nametag.maxDistance).toBeGreaterThan(0)
		end)
	end)
end
