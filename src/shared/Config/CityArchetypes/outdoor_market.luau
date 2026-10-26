--!strict
-- outdoor_market: placement and limits (Config/City archetypes; Config/CityLots).
-- L7: an open-air market: paved ground, rows of market stalls under lanterns, a sign over the way in
-- or string lights.
-- A lot type: weight 0, so the building passes never draw it; the lot pass (Dev/City/CityBuilder, Config/CityLots mix)
-- puts it on open plots. Its height is its tallest pole's; its parts follow Config/CityLots parts (budget is the most).

return {
	district = "arts",
	weight = 0,
	maxCopies = 40,
	perBlock = 2,
	minSpacing = 160,
	minWidth = 40,
	maxWidth = 150,
	minDepth = 40,
	maxPlots = 4,
	heights = { min = 13, max = 16 },
	crownMax = 10,
	budget = 18,
	palettes = 4,
	crowns = 2,
	rhythms = 2,
	ownModel = false,
}
