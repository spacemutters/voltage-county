--!strict
-- sports_court: placement and limits (Config/City archetypes; Config/CityLots).
-- L4: a fenced basketball court (a half court, or a full one on a wide lot) under floodlights.
-- A lot type: weight 0, so the building passes never draw it; the lot pass (Dev/City/CityBuilder, Config/CityLots mix)
-- puts it on open plots. Its height is its tallest pole's; its parts follow Config/CityLots parts (budget is the most).

return {
	district = "suburbs",
	weight = 0,
	maxCopies = 40,
	perBlock = 2,
	minSpacing = 120,
	minWidth = 40,
	maxWidth = 150,
	minDepth = 45,
	maxPlots = 4,
	heights = { min = 20, max = 24 },
	crownMax = 6,
	budget = 16,
	palettes = 4,
	crowns = 2,
	rhythms = 2,
	ownModel = false,
}
