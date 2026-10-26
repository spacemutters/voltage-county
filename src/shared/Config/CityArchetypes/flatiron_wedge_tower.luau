--!strict
-- flatiron_wedge_tower: placement and limits (Config/City archetypes; docs/city/ARCHETYPES.md).
-- T07: a three-cornered glass tower, its rounded nose at the street, striped with swelling white balcony slabs, on a
-- perforated-metal podium of the same plan, under a crown that sweeps up to the nose.

return {
	district = "downtown",
	weight = 1,
	maxCopies = 2,
	perBlock = 1,
	minSpacing = 600,
	minWidth = 70,
	maxWidth = 130,
	minDepth = 46,
	maxPlots = 3,
	heights = { min = 260, max = 490 },
	crownMax = 32,
	budget = 96,
	palettes = 3,
	crowns = 2,
	rhythms = 2,
	ownModel = true,
}
