--!strict
-- The current season (Phase 12): 30 tiers with a free and a premium track, 6-8 weeks, lined up with drops.

export type Reward = { kind: "cash" | "credits" | "wrap" | "plate", amount: number?, ref: string? }

export type Tier = { xp: number, free: Reward?, premium: Reward? }

local Season: { id: string, startsAtUtc: number, endsAtUtc: number, tiers: { Tier } } = {
	id = "",
	startsAtUtc = 0,
	endsAtUtc = 0,
	tiers = {},
}

return Season
