--!strict
-- construction_site: placement and limits (Config/City archetypes; Config/CityLots).
-- L5: a tower going up: a hoarding with an invented developer's sign, a concrete frame a few floors
-- high round its core, the tower crane, site cabins.
-- A lot type: weight 0, so the building passes never draw it; the lot pass (Dev/City/CityBuilder, Config/CityLots mix)
-- puts it on open plots. Its height is its tallest pole's; its parts follow Config/CityLots parts (budget is the most).

return {
	district = "downtown",
	weight = 0,
	maxCopies = 20,
	perBlock = 1,
	minSpacing = 300,
	minWidth = 60,
	maxWidth = 150,
	minDepth = 45,
	maxPlots = 4,
	heights = { min = 26, max = 46 },
	crownMax = 80,
	budget = 18,
	palettes = 3,
	crowns = 2,
	rhythms = 2,
	ownModel = false,
}
