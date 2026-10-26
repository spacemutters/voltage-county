--!strict
-- exoskeleton_tower: placement and limits (Config/City archetypes; docs/city/ARCHETYPES.md §5, T02).
-- T02: the slender glass tower in a white exoskeleton: a trunk splitting into an eye of ribs on every face, corner
-- legs and arches at the street, round corner balconies, horns at the crown. The north peak. A one-off landmark
-- (CITY_PLAN §5; Config/City landmarks): weight 0, so the per-plot draw never picks it, and the planner builds it once
-- at its anchor with a core claim. Its full look wants a site about 90 wide and 90+ deep (a 66-stud core, 84 with the
-- exoskeleton). A bare 53-deep plot gets a 31-stud core.

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
	-- The horns' tips (707 ft compressed to about 500); the core's roof stands 14 under them. The helipad, folded
	-- canopy or lantern and a beacon mast rise up to crownMax over the tips.
	heights = { min = 470, max = 500 },
	crownMax = 36,
	-- 164..223 parts over the spec's sample sites and every variant on 110-deep sites (checked off-Studio 2026-10-26):
	-- the hero landmark, 64 rib segments and up to 64 round balconies.
	budget = 230,
	palettes = 3,
	crowns = 3,
	rhythms = 3,
	ownModel = true,
	claimDepth = 110,
}
