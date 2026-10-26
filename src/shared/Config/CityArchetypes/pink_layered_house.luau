--!strict
-- pink_layered_house: placement and limits (Config/City archetypes; docs/city/ARCHETYPES.md).
-- R04: five flat walls one behind another on a concrete plinth, each a paler pink (or sea green) and taller than the
-- last, each under a crisp coping, a porthole in the front one onto a walled lap-pool court. Lean and flat-topped: it
-- fits the narrowest plots too (21 up). Budget: up to 30 parts as drawn.

return {
	district = "suburbs",
	weight = 0.7,
	maxCopies = 12,
	perBlock = 1,
	minSpacing = 250,
	minWidth = 21,
	maxWidth = 47,
	minDepth = 40,
	maxPlots = 2,
	heights = { min = 22, max = 26 },
	crownMax = 1,
	budget = 32,
	palettes = 2,
	crowns = 2,
	rhythms = 2,
	ownModel = false,
}
