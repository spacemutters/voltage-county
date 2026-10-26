--!strict
-- stepped_crown_courthouse: placement and limits (Config/City archetypes; docs/city/ARCHETYPES.md §9, C02).
-- C02: the old city's stone courthouse tower with a colonnade and a stepped pyramid on top, a one-off landmark beside
-- the Courthouse rideshare hotspot (CITY_PLAN §5.1). Weight 0: the per-plot draw never picks it; the planner places it
-- once at its anchor. Its full look wants a site about 120 wide and 90+ deep (a core claim): on a plain 53-deep plot
-- the tower is only about 33 across.

return {
	district = "downtown",
	weight = 0,
	maxCopies = 1,
	perBlock = 1,
	minSpacing = 2000,
	minWidth = 80,
	maxWidth = 180,
	minDepth = 40,
	maxPlots = 4,
	-- The top of the shaft's cornice. The colonnade storey, the stepped pyramid and its lantern rise up to crownMax
	-- over it (about 290 in all, ARCHETYPES §9).
	heights = { min = 216, max = 232 },
	crownMax = 66,
	budget = 120,
	palettes = 3,
	crowns = 2,
	rhythms = 2,
	ownModel = true,
}
