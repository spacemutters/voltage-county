--!strict
-- tiered_curve_crown_tower: placement and limits (Config/City archetypes; docs/city/ARCHETYPES.md §5, T03).
-- T03: the pinstriped office tower on a city garage, D-shaped in plan, whose three curved tiers step back toward the
-- front and glow in one colour at night. A one-off landmark (CITY_PLAN §5; Config/City landmarks, turned to face the
-- spawn): weight 0, so the per-plot draw never picks it, and the planner builds it once at its anchor with a core
-- claim. Its full look wants a site about 170 wide and 110 deep (a 90 x 64 tower behind a roof terrace). A bare
-- 53-deep plot gets a 40-deep tower with setbacks of about 5 and no terrace.

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
	-- The top tier's roof (625 ft compressed to about 440). A plant room, twin beacon masts or the crown screen rise up
	-- to crownMax over it.
	heights = { min = 430, max = 450 },
	crownMax = 26,
	-- 98..121 parts over the spec's sample sites and every variant on 110-deep sites (checked off-Studio 2026-10-26).
	budget = 135,
	palettes = 5,
	crowns = 3,
	rhythms = 2,
	ownModel = true,
	claimDepth = 110,
}
