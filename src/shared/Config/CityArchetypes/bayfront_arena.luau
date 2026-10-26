--!strict
-- bayfront_arena: placement and limits (Config/City archetypes; docs/city/ARCHETYPES.md §9, C04).
-- C04: the bayfront arena, a white oval with glass stair halls at its corners and a giant picture on its roof, a
-- one-off landmark on the bay row (CITY_PLAN §5.1). Weight 0: the per-plot draw never picks it. Its front (-z) is the
-- entrance canopy, the name and the video board, so its landmark entry should face the road; its back (+z) is the
-- terraces. Its full look wants a site about 230 wide and 190+ deep (a core claim): on a plain 53-deep plot the oval
-- is a long, thin pill.

return {
	district = "beach",
	weight = 0,
	maxCopies = 1,
	perBlock = 1,
	minSpacing = 2000,
	-- Its bay-row run (d7..e7, west of the breakdown spot) is 147 studs once the gap between buildings is kept.
	minWidth = 140,
	maxWidth = 260,
	minDepth = 44,
	maxPlots = 6,
	-- The roof's top (the picture lies on it). Masts and the stair halls' caps stay under crownMax over it.
	heights = { min = 60, max = 68 },
	crownMax = 16,
	-- About 86 parts at most (four stair halls with mullioned glass, corner posts and three flights each).
	budget = 100,
	palettes = 3,
	crowns = 2,
	rhythms = 2,
	ownModel = true,
}
