--!strict
-- bayfront_arena: placement and limits (Config/City archetypes; docs/city/ARCHETYPES.md §9, C04).
-- C04: the bayfront arena, a white oval with glass stair halls at its corners and a giant picture on its roof, a
-- one-off landmark on the lake's north shore (CITY_PLAN §3.2; its site needs the planner, see the module's header).
-- Weight 0: the per-plot draw never picks it. Its full look wants a site about 230 wide and 190+ deep (a whole block
-- or a lakefront site): on a plain 53-deep plot the oval is a long, thin pill.

return {
	district = "beach",
	weight = 0,
	maxCopies = 1,
	perBlock = 1,
	minSpacing = 2000,
	minWidth = 150,
	maxWidth = 260,
	minDepth = 44,
	maxPlots = 6,
	-- The roof's top (the picture lies on it). Masts and the stair halls' caps stay under crownMax over it.
	heights = { min = 60, max = 68 },
	crownMax = 16,
	budget = 100,
	palettes = 3,
	crowns = 2,
	rhythms = 2,
	ownModel = true,
}
