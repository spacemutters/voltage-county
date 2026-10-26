--!strict
-- red_ziggurat_lowrise: placement and limits (Config/City archetypes; docs/city/ARCHETYPES.md).
-- R05: the bright red stepped pyramid of apartments, six storeys at its peak, stepping up and down along its long axis
-- (along the road on a wide site, back from it on a narrow one) with white ship-rail balconies on its long faces. A
-- rare landmark (Config/City landmarks puts one on the bay row; areas decide the rest).

return {
	district = "suburbs",
	weight = 0.4,
	maxCopies = 3,
	perBlock = 1,
	minSpacing = 600,
	minWidth = 30,
	maxWidth = 80,
	minDepth = 50,
	maxPlots = 3,
	heights = { min = 60, max = 78 },
	crownMax = 6,
	budget = 56,
	palettes = 2,
	crowns = 2,
	rhythms = 2,
	ownModel = false,
}
