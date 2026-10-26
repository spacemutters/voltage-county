--!strict
-- pink_layered_house: placement and limits (Config/City archetypes; docs/city/ARCHETYPES.md).
-- R04: five flat walls one behind another, each a paler pink (or sea green) and taller than the last, a porthole in
-- the front one onto a walled lap-pool court. Lean and flat-topped: it fits the narrowest plots too (21 up).

return {
	district = "suburbs",
	weight = 0.7,
	maxCopies = 8,
	perBlock = 1,
	minSpacing = 300,
	minWidth = 21,
	maxWidth = 47,
	minDepth = 40,
	maxPlots = 2,
	heights = { min = 22, max = 26 },
	crownMax = 1,
	budget = 28,
	palettes = 2,
	crowns = 2,
	rhythms = 2,
	ownModel = false,
}
