--!strict
-- Job XP levels (docs/phase-6-contracts.md "XP and levels"): the level from XP at and around every threshold,
-- the pay multiplier, unlocks that accumulate, level-ups between two XP totals, bad XP values, and the ladders in
-- Config/Jobs. Pure logic: runs in Edit mode.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Harness = require(ReplicatedStorage.Shared.Testing.Harness)
local Jobs = require(ReplicatedStorage.Shared.Config.Jobs) :: any
local Levels = require(ServerScriptService.Server.Services.JobService.Levels)

local SAME = 1e-9

-- A hand-made ladder, so the spec doesn't depend on the tuned numbers in Config/Jobs.
local LADDER: Levels.Ladder = {
	{ xp = 0, payMultiplier = 1, unlocks = {} },
	{ xp = 100, payMultiplier = 1.1, unlocks = { "a" } },
	{ xp = 300, payMultiplier = 1.25, unlocks = { "b", "c" } },
	{ xp = 1000, payMultiplier = 1.5, unlocks = { "a", "d" } }, -- "a" again: still listed once
}

return function(t: Harness.Api)
	t.describe("Levels", function()
		t.describe("levelOf", function()
			t.it("is level 1 from 0 XP", function()
				t.expect(Levels.levelOf(LADDER, 0)).toBe(1)
				t.expect(Levels.levelOf(LADDER, 99)).toBe(1)
			end)

			t.it("reaches a level exactly at its threshold, not one XP before", function()
				for index, def in LADDER do
					t.expect(Levels.levelOf(LADDER, def.xp)).toBe(index)
					if index > 1 then
						t.expect(Levels.levelOf(LADDER, def.xp - 1)).toBe(index - 1)
						t.expect(Levels.levelOf(LADDER, def.xp - 0.001)).toBe(index - 1)
					end
				end
			end)

			t.it("stays at the top level past the last threshold", function()
				t.expect(Levels.levelOf(LADDER, 1e9)).toBe(#LADDER)
			end)

			t.it("reads missing, negative and NaN XP as 0", function()
				t.expect(Levels.levelOf(LADDER, nil)).toBe(1)
				t.expect(Levels.levelOf(LADDER, -50)).toBe(1)
				t.expect(Levels.levelOf(LADDER, 0 / 0)).toBe(1)
			end)

			t.it("is level 1 on an empty ladder, or for a job type with no ladder", function()
				t.expect(Levels.levelFor("noSuchJob", 5000)).toBe(1)
				t.expect(#Levels.unlocks("noSuchJob", 1)).toBe(0)
				t.expect(Levels.levelOf({}, 5000)).toBe(1)
				t.expect(Levels.payMultiplier({}, 5000)).toBe(1)
				t.expect(#Levels.unlocksAt({}, 5000)).toBe(0)
			end)
		end)

		t.describe("payMultiplier", function()
			t.it("is the current level's multiplier", function()
				t.expect(Levels.payMultiplier(LADDER, 0)).toBeNear(1, SAME)
				t.expect(Levels.payMultiplier(LADDER, 150)).toBeNear(1.1, SAME)
				t.expect(Levels.payMultiplier(LADDER, 299)).toBeNear(1.1, SAME)
				t.expect(Levels.payMultiplier(LADDER, 300)).toBeNear(1.25, SAME)
				t.expect(Levels.payMultiplier(LADDER, 5000)).toBeNear(1.5, SAME)
			end)
		end)

		t.describe("unlocks", function()
			t.it("accumulates every level's unlocks up to the player's, each once", function()
				t.expect(Levels.unlocksAt(LADDER, 0)).toEqual({})
				t.expect(Levels.unlocksAt(LADDER, 100)).toEqual({ "a" })
				t.expect(Levels.unlocksAt(LADDER, 300)).toEqual({ "a", "b", "c" })
				t.expect(Levels.unlocksAt(LADDER, 1000)).toEqual({ "a", "b", "c", "d" })
			end)

			t.it("answers isUnlocked at the boundary", function()
				t.expect(Levels.isUnlocked(LADDER, 299, "b")).toBe(false)
				t.expect(Levels.isUnlocked(LADDER, 300, "b")).toBe(true)
				t.expect(Levels.isUnlocked(LADDER, 300, "d")).toBe(false)
				t.expect(Levels.isUnlocked(LADDER, 1000, "a")).toBe(true)
			end)

			t.it("finds the level that first unlocks an id", function()
				t.expect(Levels.levelUnlocking(LADDER, "a")).toBe(2)
				t.expect(Levels.levelUnlocking(LADDER, "c")).toBe(3)
				t.expect(Levels.levelUnlocking(LADDER, "zzz")).toBe(nil)
			end)

			t.it("lists only what is new at a level", function()
				t.expect(Levels.newUnlocksAt(LADDER, 2)).toEqual({ "a" })
				t.expect(Levels.newUnlocksAt(LADDER, 4)).toEqual({ "d" }) -- "a" came at level 2
				t.expect(Levels.newUnlocksAt(LADDER, 9)).toEqual({})
			end)
		end)

		t.describe("info", function()
			t.it("reports progress toward the next level", function()
				local info = Levels.info(LADDER, 200)
				t.expect(info.level).toBe(2)
				t.expect(info.maxLevel).toBe(#LADDER)
				t.expect(info.levelXp).toBe(100)
				t.expect(info.nextXp).toBe(300)
				t.expect(info.progress).toBeNear(0.5, SAME)
				t.expect(info.payMultiplier).toBeNear(1.1, SAME)
				t.expect(info.unlocks).toEqual({ "a" })
			end)

			t.it("is full progress with no next level at the top", function()
				local info = Levels.info(LADDER, 4000)
				t.expect(info.level).toBe(#LADDER)
				t.expect(info.nextXp).toBe(nil)
				t.expect(info.progress).toBe(1)
			end)
		end)

		t.describe("levelsGained", function()
			t.it("lists each level crossed, in order", function()
				t.expect(Levels.levelsGained(LADDER, 50, 99)).toEqual({})
				t.expect(Levels.levelsGained(LADDER, 50, 100)).toEqual({ 2 })
				t.expect(Levels.levelsGained(LADDER, 50, 2000)).toEqual({ 2, 3, 4 })
				t.expect(Levels.levelsGained(LADDER, 2000, 3000)).toEqual({})
			end)
		end)

		t.describe("validate", function()
			t.it("accepts a sound ladder", function()
				t.expect(Levels.validate(LADDER)).toEqual({})
			end)

			t.it("rejects a ladder that doesn't start at 0, falls back, or cuts pay", function()
				t.expect(#Levels.validate({ { xp = 10, payMultiplier = 1, unlocks = {} } })).toBe(1)
				t.expect(#Levels.validate({
					{ xp = 0, payMultiplier = 1, unlocks = {} },
					{ xp = 0, payMultiplier = 1.1, unlocks = {} },
				})).toBe(1)
				t.expect(#Levels.validate({
					{ xp = 0, payMultiplier = 1.2, unlocks = {} },
					{ xp = 50, payMultiplier = 1, unlocks = {} },
				})).toBe(1)
			end)
		end)

		t.describe("Config/Jobs ladders", function()
			t.it("has a sound ladder for every job type that has one", function()
				local ladders = if type(Jobs.levels) == "table" then Jobs.levels else {}
				for jobType, ladder in ladders do
					local problems = Levels.validate(ladder)
					t.expect(`{jobType}: {table.concat(problems, "; ")}`).toBe(`{jobType}: `)
				end
			end)

			t.it("has a ladder for delivery and rideshare that pays more at its top", function()
				for _, jobType in { "delivery", "rideshare" } do
					local ladder = Levels.ladder(jobType)
					t.expect(#ladder).toBeGreaterThan(1)
					t.expect(Levels.payMultiplierFor(jobType, 0)).toBeNear(1, SAME)
					t.expect(Levels.payMultiplierFor(jobType, ladder[#ladder].xp)).toBeGreaterThan(1)
					t.expect(Levels.infoFor(jobType, ladder[#ladder].xp).level).toBe(#ladder)
				end
			end)

			t.it("answers JobService's levelFor and unlocks for each job type", function()
				for _, jobType in { "delivery", "rideshare" } do
					local ladder = Levels.ladder(jobType)
					for index, def in ladder do
						local level, multiplier = Levels.levelFor(jobType, def.xp)
						t.expect(level).toBe(index)
						t.expect(multiplier).toBeNear(def.payMultiplier, SAME)
						t.expect(Levels.unlocks(jobType, index)).toEqual(def.unlocks)
					end
					t.expect(Levels.unlocks(jobType, #ladder + 1)).toEqual({})
					local level, multiplier = Levels.levelFor(jobType, 0)
					t.expect(level).toBe(1)
					t.expect(multiplier).toBeNear(1, SAME)
				end
			end)
		end)
	end)
end
