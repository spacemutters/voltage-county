--!strict
-- harbor_market_pavilions: placement and limits (Config/City archetypes; docs/city/ARCHETYPES.md §9, C03).
-- C03: the bayfront market, two open market halls either side of a plaza with a giant observation wheel, a one-off
-- landmark on the lake's north shore (CITY_PLAN §3.2; its site needs the planner, see the module's header). Weight 0:
-- the per-plot draw never picks it. Its front (-z) faces the road, its back (+z) the water. Its full look wants a
-- site about 200 wide and 90+ deep: on a plain 53-deep plot the wheel shrinks to fit between the halls.

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
	-- The halls' top (the clerestory ridge). The wheel rises up to crownMax over it (about 160 in all).
	heights = { min = 32, max = 36 },
	crownMax = 128,
	budget = 140,
	palettes = 3,
	crowns = 2,
	rhythms = 2,
	ownModel = true,
}
