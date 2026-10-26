--!strict
-- mimo_garden_apartment: placement and limits (Config/City archetypes; docs/city/ARCHETYPES.md).
-- R07: the pastel three-storey MiMo garden apartment: a see-through breezeway on V-struts, a row of round windows, a
-- stair tower screened by a white grid of fins and bands over a lit stairwell, and a flat roof slab with a rounded
-- corner. Two or three plots merged (52..95). Budget: up to 49 parts as drawn (the tall tower crown).

return {
	district = "suburbs",
	weight = 1,
	maxCopies = 18,
	perBlock = 2,
	minSpacing = 140,
	minWidth = 52,
	maxWidth = 95,
	minDepth = 42,
	maxPlots = 3,
	heights = { min = 34, max = 38 },
	crownMax = 7,
	budget = 60,
	palettes = 4,
	crowns = 2,
	rhythms = 2,
	ownModel = false,
}
