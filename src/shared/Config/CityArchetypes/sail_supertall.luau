--!strict
-- sail_supertall: placement and limits (Config/City archetypes; docs/city/ARCHETYPES.md §5, T04).
-- T04: the lens-shaped glass sail with a raked head on the bay row. A one-off landmark (CITY_PLAN §5; Config/City
-- landmarks, turned to face the lake): weight 0, so the per-plot draw never picks it, and the planner builds it once at
-- its anchor with a core claim. Its full look wants a site about 130 wide and 70+ deep (a 110 x 50 lens with a garage
-- behind it). A bare 53-deep plot gets a thinner lens and a shallow garage.

return {
	district = "downtown",
	weight = 0,
	maxCopies = 1,
	perBlock = 1,
	minSpacing = 2000,
	minWidth = 100,
	maxWidth = 170,
	minDepth = 53,
	maxPlots = 5,
	-- The leading tip's roof (816 ft compressed to about 560); the roof rakes down 50..76 from it to the trailing tip.
	-- The spine, its mast or the raked blade and a beacon rise up to crownMax over it.
	heights = { min = 530, max = 560 },
	crownMax = 44,
	budget = 160,
	palettes = 3,
	crowns = 3,
	rhythms = 2,
	ownModel = true,
	claimDepth = 110,
}
