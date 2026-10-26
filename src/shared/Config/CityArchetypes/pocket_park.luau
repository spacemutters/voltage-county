--!strict
-- pocket_park: placement and limits (Config/City archetypes; Config/CityLots).
-- L6: a small park: a lawn, a path, palms and benches round a playground, a fenced dog run or a
-- bandshell.
-- A lot type: weight 0, so the building passes never draw it; the lot pass (Dev/City/CityBuilder, Config/CityLots mix)
-- puts it on open plots. Its height is its tallest pole's; its parts follow Config/CityLots parts (budget is the most).

return {
	district = "suburbs",
	weight = 0,
	maxCopies = 60,
	perBlock = 2,
	minSpacing = 0,
	minWidth = 21,
	maxWidth = 150,
	minDepth = 30,
	maxPlots = 4,
	heights = { min = 12, max = 14 },
	crownMax = 32,
	budget = 18,
	palettes = 3,
	crowns = 3,
	rhythms = 2,
	ownModel = false,
}
