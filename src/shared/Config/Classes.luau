--!strict
-- Vehicle classes, tiers and stat bands (PLAN.md §3.3). Every vehicle's stats must sit inside its class band,
-- player designs and AI mods included. Filled in Phase 1.

export type Range = { min: number, max: number }

export type Class = {
	id: string,
	tier: number, -- 1..5
	price: Range,
	topSpeedMph: Range,
	zeroToSixtySec: Range,
	energyMinutes: Range, -- minutes of driving on a full charge or tank
	handling: Range, -- 0..1
	seats: Range,
	designable: boolean, -- can the AI Car Designer make this class (Phase 11)
}

local Classes: { [string]: Class } = {}

return Classes
