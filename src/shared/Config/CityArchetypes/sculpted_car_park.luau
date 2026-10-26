--!strict
-- sculpted_car_park: placement and limits (Config/City archetypes; docs/city/ARCHETYPES.md).
-- W04: the car park as sculpture, bare slabs at uneven heights on thin blades set at odd angles. Two to four plots,
-- on Plant Avenue and downtown's east edge (Config/City areas).

return {
	district = "arts",
	weight = 1,
	maxCopies = 2,
	perBlock = 1,
	minSpacing = 600,
	minWidth = 64,
	maxWidth = 140,
	minDepth = 46,
	maxPlots = 4,
	heights = { min = 76, max = 92 },
	crownMax = 12,
	budget = 64, -- the widest, with three blades a floor and its parked cars, needs about 59
	palettes = 3,
	crowns = 2,
	rhythms = 3,
	ownModel = false,
}
