--!strict
-- sculpted_car_park: placement and limits (Config/City archetypes; docs/city/ARCHETYPES.md).
-- W04: the car park as sculpture, bare slabs at uneven heights on thin blades set at odd angles. Two to four plots,
-- on Plant Avenue and downtown's east edge (Config/City areas).

return {
	district = "arts",
	weight = 1,
	maxCopies = 4,
	perBlock = 1,
	minSpacing = 450,
	minWidth = 64,
	maxWidth = 140,
	minDepth = 46,
	maxPlots = 4,
	heights = { min = 76, max = 92 },
	crownMax = 12,
	budget = 74, -- the widest, with three blades a floor, its parked cars, cable rails and hanging greenery, is 71
	palettes = 3,
	crowns = 2,
	rhythms = 3,
	ownModel = false,
}
