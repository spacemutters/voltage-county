--!strict
-- Limited drops (Phase 12): a vehicle/trim sold in a UTC window with a fixed supply and serial numbers.
-- Never random. Arc Flight ships only this way.

export type Limited = {
	vehicleId: string,
	trim: string,
	startsAtUtc: number,
	endsAtUtc: number,
	supply: number,
	price: number, -- in-game $
}

local Limiteds: { [string]: Limited } = {}

return Limiteds
