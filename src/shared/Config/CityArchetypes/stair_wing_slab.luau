--!strict
-- stair_wing_slab: placement and limits (Config/City archetypes; docs/city/ARCHETYPES.md).
-- T09: a plain white slab with a giant orange staircase of lit blocks stepping down out of it toward the street.

return {
	district = "downtown",
	weight = 1,
	maxCopies = 2,
	perBlock = 1,
	minSpacing = 600,
	minWidth = 130,
	maxWidth = 220,
	minDepth = 46,
	maxPlots = 5,
	heights = { min = 200, max = 320 },
	crownMax = 24,
	budget = 50,
	palettes = 3,
	crowns = 2,
	rhythms = 2,
	ownModel = true,
}
