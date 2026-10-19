--!strict
-- Job definitions (PLAN.md §4, Phase 6): eligible classes, payout formula inputs, XP and cooldown.

export type Job = {
	id: string,
	displayName: string,
	classes: { string }, -- vehicle classes that can do this job
	basePay: number,
	payPerStud: number,
	xp: number,
	cooldownSec: number,
}

local Jobs: { [string]: Job } = {}

return Jobs
