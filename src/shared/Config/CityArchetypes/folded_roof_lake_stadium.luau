--!strict
-- folded_roof_lake_stadium: placement and limits (Config/City archetypes; docs/city/ARCHETYPES.md §9, C06).
-- C06: the lake stadium, a long white roof of folded concrete plates floating out over a grandstand by the water,
-- a one-off landmark on the lake shore (its site needs the planner, see the module's header). Weight 0: the per-plot
-- draw never picks it. Unlike every other archetype its FRONT (-z) faces the WATER: the stands look out over the lake
-- and the roof reaches toward it; its back (+z) faces the road, with the stadium's name on its back wall. Its full
-- look wants a site about 210 along the shore and 50+ deep, the front line on the water's edge.

return {
	district = "beach",
	weight = 0,
	maxCopies = 1,
	perBlock = 1,
	minSpacing = 2000,
	minWidth = 150,
	maxWidth = 230,
	minDepth = 44,
	maxPlots = 6,
	-- The roof's highest point (its folds' ridges at the front edge). The flagpole stays under crownMax over it.
	heights = { min = 48, max = 54 },
	crownMax = 8,
	budget = 100,
	palettes = 3,
	crowns = 2,
	rhythms = 2,
	ownModel = true,
}
