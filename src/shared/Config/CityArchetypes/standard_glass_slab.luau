--!strict
-- standard_glass_slab: placement and limits (Config/City archetypes; docs/city/ARCHETYPES.md).
-- T06: the city's standard glass condo slab on a parking podium (the reusable background tower, done well).

return {
	district = "downtown",
	weight = 1,
	maxCopies = 16,
	perBlock = 1,
	minSpacing = 400,
	minWidth = 70,
	maxWidth = 150,
	minDepth = 46,
	maxPlots = 4,
	heights = { min = 200, max = 440 },
	crownMax = 70,
	budget = 80,
	palettes = 4,
	crowns = 3,
	rhythms = 3,
	ownModel = true,
}
