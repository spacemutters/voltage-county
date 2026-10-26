--!strict
-- collage_parking_garage: placement and limits (Config/City archetypes; docs/city/ARCHETYPES.md).
-- W03: the car park in five outfits, one a wall of cars climbing it. Half a block of frontage (four to six plots);
-- a one-off on Plant Avenue (Config/City landmarks) and at most one more.

return {
	district = "arts",
	weight = 1,
	maxCopies = 2,
	perBlock = 1,
	minSpacing = 600,
	minWidth = 120,
	maxWidth = 230,
	minDepth = 50,
	maxPlots = 6,
	heights = { min = 64, max = 76 },
	crownMax = 14,
	budget = 100, -- a one-off landmark: the widest (all five outfits, seven cars in the jam) needs about 93
	palettes = 3,
	crowns = 4,
	rhythms = 3,
	ownModel = false,
}
