--!strict
-- tiered_curve_crown_tower: placement and limits (Config/City archetypes; docs/city/ARCHETYPES.md §5, T03).
-- T03: the banded office tower on a city garage whose three curved tiers glow in one colour at night. A one-off
-- landmark (CITY_PLAN §5; Config/City landmarks, turned to face the spawn): weight 0, so the per-plot draw never picks
-- it, and the planner builds it once at its anchor with a core claim. Its full look wants a site about 170 wide and
-- 110 deep (a 78 x 68 tower behind a roof terrace). A bare 53-deep plot gets a 40-deep tower with no terrace.

return {
	district = "downtown",
	weight = 0,
	maxCopies = 1,
	perBlock = 1,
	minSpacing = 2000,
	minWidth = 140,
	maxWidth = 240,
	minDepth = 53,
	maxPlots = 6,
	-- The top of the third tier's cap (625 ft compressed to about 440). A plant room and a beacon mast rise up to
	-- crownMax over it.
	heights = { min = 430, max = 450 },
	crownMax = 26,
	budget = 120,
	palettes = 5,
	crowns = 3,
	rhythms = 2,
	ownModel = true,
	claimDepth = 110,
}
