--!strict
-- surface_parking: placement and limits (Config/City archetypes; Config/CityLots).
-- L1: surface parking on an open plot: asphalt, painted stalls, wheel stops, a pay booth, light
-- poles and a palm island; its stalls are handed to the parked cars (Dev/City/Street Parking.fillStalls).
-- A lot type: weight 0, so the building passes never draw it; the lot pass (Dev/City/CityBuilder, Config/CityLots mix)
-- puts it on open plots. Its height is its tallest pole's; its parts follow Config/CityLots parts (budget is the most).

return {
	district = "downtown",
	weight = 0,
	maxCopies = 120,
	perBlock = 2,
	minSpacing = 0,
	minWidth = 21,
	maxWidth = 150,
	minDepth = 40,
	maxPlots = 4,
	heights = { min = 16, max = 22 },
	crownMax = 14,
	budget = 18,
	palettes = 3,
	crowns = 3,
	rhythms = 2,
	ownModel = false,
}
