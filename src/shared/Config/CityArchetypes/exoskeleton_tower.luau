--!strict
-- exoskeleton_tower: placement and limits (Config/City archetypes; docs/city/ARCHETYPES.md §5, T02).
-- T02: the slender glass tower in a white curving exoskeleton, the north peak. A one-off landmark (CITY_PLAN §5;
-- Config/City landmarks): weight 0, so the per-plot draw never picks it, and the planner builds it once at its anchor
-- with a core claim. Its full look wants a site about 90 wide and 90+ deep (a 66-stud core). A bare 53-deep plot gets
-- a 32-stud core.

return {
	district = "downtown",
	weight = 0,
	maxCopies = 1,
	perBlock = 1,
	minSpacing = 2000,
	minWidth = 90,
	maxWidth = 160,
	minDepth = 53,
	maxPlots = 5,
	-- The roof slab over the rib heads (707 ft compressed to about 500). The helipad, folded canopy or lantern and a
	-- beacon mast rise up to crownMax over it.
	heights = { min = 470, max = 500 },
	crownMax = 36,
	budget = 150,
	palettes = 3,
	crowns = 3,
	rhythms = 3,
	ownModel = true,
	claimDepth = 110,
}
