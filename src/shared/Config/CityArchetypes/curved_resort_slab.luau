--!strict
-- curved_resort_slab: placement and limits (Config/City archetypes; docs/city/ARCHETYPES.md).
-- B10: the beach's one big mid-century resort, a balconied slab bent round its pool. One copy only.

return {
	district = "beach",
	weight = 1,
	maxCopies = 1,
	perBlock = 1,
	minSpacing = 2000,
	minWidth = 100,
	maxWidth = 200,
	minDepth = 46,
	maxPlots = 5,
	heights = { min = 128, max = 168 },
	crownMax = 16,
	budget = 136, -- about 123 on its 200 x 140 landmark site, plus a row of three pool umbrellas (6) on a deep site
	palettes = 2,
	crowns = 2,
	rhythms = 2,
	ownModel = true,
}
