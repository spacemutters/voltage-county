--!strict
-- Scheduled events (Phase 12): banners, the featured dealership pad, earnings multipliers, bonus-credit
-- weekends and countdowns, on a UTC schedule. Events switch on without a server restart.

export type Event = {
	id: string,
	startsAtUtc: number,
	endsAtUtc: number,
	banner: string?,
	featuredVehicleId: string?,
	earningsMultiplier: number?,
}

local Events: { Event } = {}

return Events
