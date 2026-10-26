--!strict
-- flatiron_wedge_tower: placement and limits (Config/City archetypes; docs/city/ARCHETYPES.md).
-- T07: a three-cornered glass tower, its rounded nose at the street corner, striped with swelling white balcony
-- slabs (lit edges round the prow at night), on a perforated-metal podium of the same plan, under a crest of
-- champagne blades that sweeps up to the nose. Block corners only (Config/City cornerArchetypes).
-- Budget: about 98 parts at its tallest (16 balcony rings of 3 parts each are most of it).

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
	budget = 104,
	palettes = 3,
	crowns = 2,
	rhythms = 2,
	ownModel = true,
}
