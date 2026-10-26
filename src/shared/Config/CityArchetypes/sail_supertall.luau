--!strict
-- sail_supertall: placement and limits (Config/City archetypes; docs/city/ARCHETYPES.md §5, T04).
-- T04: the pale banded glass sail, a teardrop in plan with a round bow, whose head leans out over a dark lip, on the
-- bay row. A one-off landmark (CITY_PLAN §5; Config/City landmarks, turned to face the lake): weight 0, so the per-plot
-- draw never picks it, and the planner builds it once at its anchor with a core claim. Its full look wants a site about
-- 130 wide and 70+ deep (a 112 x 49 sail with a garage behind it). A bare 53-deep plot gets a thinner sail and no
-- garage.

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
	-- The head's roof (816 ft compressed to about 560); the bow stops at the lip three quarters of the way up. The tail's
	-- mast, the raked blade or a beacon rise up to crownMax over the roof.
	heights = { min = 530, max = 560 },
	crownMax = 44,
	-- 142..202 parts over the spec's sample sites (tests/City.spec in Studio, 2026-10-26, after the soffit rework): a
	-- band of strips round the sail every two floors (rhythm 1).
	budget = 210,
	palettes = 3,
	crowns = 3,
	rhythms = 2,
	ownModel = true,
	claimDepth = 110,
}
