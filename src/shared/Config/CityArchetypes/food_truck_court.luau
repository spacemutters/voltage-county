--!strict
-- food_truck_court: placement and limits (Config/City archetypes; Config/CityLots).
-- L3: a food-truck court: painted ground, food trucks, café tables and string lights, with a mural
-- wall at the back in the arts district.
-- A lot type: weight 0, so the building passes never draw it; the lot pass (Dev/City/CityBuilder, Config/CityLots mix)
-- puts it on open plots. Its height is its tallest pole's; its parts follow Config/CityLots parts (budget is the most).

return {
	district = "arts",
	weight = 0,
	maxCopies = 70,
	perBlock = 2,
	minSpacing = 0,
	minWidth = 32,
	maxWidth = 150,
	minDepth = 40,
	maxPlots = 4,
	heights = { min = 13, max = 16 },
	crownMax = 18,
	budget = 18,
	palettes = 4,
	crowns = 2,
	rhythms = 2,
	ownModel = false,
}
