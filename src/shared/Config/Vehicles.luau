--!strict
-- The vehicle catalog (PLAN.md §3). Each entry names its brand, class, energy type and trims; every trim's
-- stats sit inside its class band. Filled in Phase 1 with the Ohm Motors lineup.

export type Trim = {
	id: string,
	displayName: string,
	price: number?, -- in-game $; nil when not sold new (free starter, fleet-only, limited drop)
	topSpeedMph: number,
	zeroToSixtySec: number,
	energyMinutes: number?, -- nil for NPC-only vehicles
	seats: number,
}

export type Vehicle = {
	id: string,
	brandId: string,
	displayName: string,
	class: string,
	energy: "battery" | "fuel",
	playerDrivable: boolean,
	trims: { Trim },
}

local Vehicles: { [string]: Vehicle } = {}

return Vehicles
