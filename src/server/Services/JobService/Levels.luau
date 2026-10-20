--!strict
-- Job XP levels (PLAN.md Phase 6 "Job XP levels unlock higher-paying work"; docs/phase-6-contracts.md "XP and
-- levels"). Pure: no state and no side effects (it only reads Config/Jobs), so tests/Levels.spec can run it in
-- Edit mode.
--
-- Each job type has its own XP (PlayerData.jobs.xp[type]) and its own ladder in Config/Jobs.levels[type]:
--   { { xp = 0, payMultiplier = 1, unlocks = {} }, { xp = 500, payMultiplier = 1.05, unlocks = { ... } }, ... }
-- Entry N is level N: a player is at the highest level whose `xp` threshold they have reached. Level 1 is the
-- first entry (its threshold should be 0; XP below it still counts as level 1, so a new player is never level 0).
-- The pay multiplier is the current level's. Unlocks accumulate: a level keeps everything the levels below it
-- unlocked, so the unlock ids a player has are those of every level up to and including theirs.
--
-- Every function takes the ladder itself (so specs can pass hand-made ones); the `*For(jobType, xp)` forms read
-- the ladder from Config/Jobs.levels. A job type with no ladder is level 1 with multiplier 1 and no unlocks.

export type LevelDef = {
	xp: number, -- total XP needed to reach this level
	payMultiplier: number, -- job pay x this at this level
	unlocks: { string }, -- ids this level unlocks (kept by every higher level)
}

export type Ladder = { LevelDef }

export type Info = {
	level: number, -- 1-based
	maxLevel: number, -- the ladder's top level
	xp: number, -- the player's XP for this job type
	levelXp: number, -- the threshold of the current level
	nextXp: number?, -- the threshold of the next level (nil at the top)
	progress: number, -- 0..1 of the way from this level to the next (1 at the top)
	payMultiplier: number,
	unlocks: { string }, -- everything unlocked so far, lowest level first, without duplicates
}

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Jobs = require(ReplicatedStorage.Shared.Config.Jobs) :: any

local BASE_MULTIPLIER = 1 -- pay multiplier with no ladder

local Levels = {}

-- The ladder for a job type from Config/Jobs, or an empty ladder when Config/Jobs has none for it.
local function ladderFor(jobType: string): Ladder
	local levels = Jobs.levels
	if type(levels) == "table" and type(levels[jobType]) == "table" then
		return levels[jobType] :: Ladder
	end
	return {}
end

-- XP must be a finite, non-negative number; anything else (nil from old data, NaN, negative) reads as 0.
local function cleanXp(xp: number?): number
	if type(xp) ~= "number" or xp ~= xp or xp < 0 then
		return 0
	end
	return xp
end

-- The 1-based level for `xp` on `ladder` (1 for an empty ladder).
function Levels.levelOf(ladder: Ladder, xp: number?): number
	local amount = cleanXp(xp)
	local level = 1
	for index, def in ladder do
		if amount >= def.xp then
			level = index
		else
			break -- thresholds rise, so no later level can be reached either
		end
	end
	return level
end

-- The pay multiplier at `xp` (1 for an empty ladder).
function Levels.payMultiplier(ladder: Ladder, xp: number?): number
	local def = ladder[Levels.levelOf(ladder, xp)]
	return if def then def.payMultiplier else BASE_MULTIPLIER
end

-- Every unlock id reached at `xp`, lowest level first, each once.
function Levels.unlocksAt(ladder: Ladder, xp: number?): { string }
	local reached = Levels.levelOf(ladder, xp)
	local list: { string } = {}
	local seen: { [string]: boolean } = {}
	for index = 1, math.min(reached, #ladder) do
		for _, id in ladder[index].unlocks do
			if not seen[id] then
				seen[id] = true
				table.insert(list, id)
			end
		end
	end
	return list
end

-- Whether `unlockId` is unlocked at `xp`.
function Levels.isUnlocked(ladder: Ladder, xp: number?, unlockId: string): boolean
	return table.find(Levels.unlocksAt(ladder, xp), unlockId) ~= nil
end

-- The level that first unlocks `unlockId` (nil: no level does). For "reach level N to unlock" hints.
function Levels.levelUnlocking(ladder: Ladder, unlockId: string): number?
	for index, def in ladder do
		if table.find(def.unlocks, unlockId) then
			return index
		end
	end
	return nil
end

-- Everything about a player's standing on `ladder` at `xp` (for JobUpdate and the Jobs app).
function Levels.info(ladder: Ladder, xp: number?): Info
	local amount = cleanXp(xp)
	local level = Levels.levelOf(ladder, amount)
	local def = ladder[level]
	local nextDef = ladder[level + 1]
	local levelXp = if def then def.xp else 0
	local progress = 1
	if nextDef then
		local span = nextDef.xp - levelXp
		progress = if span > 0 then math.clamp((amount - levelXp) / span, 0, 1) else 1
	end
	return {
		level = level,
		maxLevel = math.max(#ladder, 1),
		xp = amount,
		levelXp = levelXp,
		nextXp = if nextDef then nextDef.xp else nil,
		progress = progress,
		payMultiplier = if def then def.payMultiplier else BASE_MULTIPLIER,
		unlocks = Levels.unlocksAt(ladder, amount),
	}
end

-- The levels gained going from `oldXp` to `newXp`, in order (empty when none). JobService announces each one.
function Levels.levelsGained(ladder: Ladder, oldXp: number?, newXp: number?): { number }
	local from, to = Levels.levelOf(ladder, oldXp), Levels.levelOf(ladder, newXp)
	local gained: { number } = {}
	for level = from + 1, to do
		table.insert(gained, level)
	end
	return gained
end

-- The unlock ids new at `level` (not unlocked by any level below it), for the level-up notice.
function Levels.newUnlocksAt(ladder: Ladder, level: number): { string }
	local def = ladder[level]
	if def == nil then
		return {}
	end
	local before = if level > 1 then Levels.unlocksAt(ladder, ladder[level - 1].xp) else {}
	local fresh: { string } = {}
	for _, id in def.unlocks do
		if not table.find(before, id) and not table.find(fresh, id) then
			table.insert(fresh, id)
		end
	end
	return fresh
end

-- Problems with a ladder (empty when it is sound): it must start at 0 XP, its thresholds must rise strictly,
-- and its multipliers must be positive and never fall. tests/Levels.spec runs it over every ladder in Config/Jobs.
function Levels.validate(ladder: Ladder): { string }
	local problems: { string } = {}
	for index, def in ladder do
		if type(def.xp) ~= "number" or type(def.payMultiplier) ~= "number" or type(def.unlocks) ~= "table" then
			table.insert(problems, `level {index}: needs xp, payMultiplier and unlocks`)
			continue
		end
		if index == 1 and def.xp ~= 0 then
			table.insert(problems, `level 1 starts at {def.xp} XP, not 0`)
		end
		if def.payMultiplier <= 0 then
			table.insert(problems, `level {index}: payMultiplier {def.payMultiplier} is not positive`)
		end
		local below = ladder[index - 1]
		if index > 1 and type(below.xp) == "number" and type(below.payMultiplier) == "number" then
			if def.xp <= below.xp then
				table.insert(problems, `level {index}: {def.xp} XP does not rise above level {index - 1}`)
			end
			if def.payMultiplier < below.payMultiplier then
				table.insert(problems, `level {index}: payMultiplier falls below level {index - 1}'s`)
			end
		end
	end
	return problems
end

-- The same queries for a job type, reading its ladder from Config/Jobs.levels. levelFor and unlocks are what
-- JobService calls (its LevelsModule type).

-- The level (1 = new) and its pay multiplier for `xp` in a job type.
function Levels.levelFor(jobType: string, xp: number?): (number, number)
	local ladder = ladderFor(jobType)
	return Levels.levelOf(ladder, xp), Levels.payMultiplier(ladder, xp)
end

-- The unlock ids listed at one level of a job type (JobService gathers levels 1..N itself). A copy, so callers
-- can't change Config/Jobs.
function Levels.unlocks(jobType: string, level: number): { string }
	local def = ladderFor(jobType)[level]
	return if def then table.clone(def.unlocks) else {}
end

function Levels.ladder(jobType: string): Ladder
	return ladderFor(jobType)
end

function Levels.infoFor(jobType: string, xp: number?): Info
	return Levels.info(ladderFor(jobType), xp)
end

function Levels.payMultiplierFor(jobType: string, xp: number?): number
	return Levels.payMultiplier(ladderFor(jobType), xp)
end

function Levels.isUnlockedFor(jobType: string, xp: number?, unlockId: string): boolean
	return Levels.isUnlocked(ladderFor(jobType), xp, unlockId)
end

return Levels
