--!strict
-- coral_rock_cottage: placement and limits (Config/City archetypes; docs/city/ARCHETYPES.md).
-- R02: the low coral-rock cottage under coral-red gables with a white-columned porch. One and a half storeys: the
-- ridge is the roof (17..20) and only the chimney rises past it.

return {
	district = "suburbs",
	weight = 1,
	maxCopies = 16,
	perBlock = 2,
	minSpacing = 120,
	minWidth = 26,
	maxWidth = 47,
	minDepth = 40,
	maxPlots = 2,
	heights = { min = 17, max = 20 },
	crownMax = 4,
	budget = 46,
	palettes = 3,
	crowns = 2,
	rhythms = 2,
	ownModel = false,
}
