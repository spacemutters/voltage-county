--!strict
-- cupola_bell_tower: placement and limits (Config/City archetypes; docs/city/ARCHETYPES.md §9, C01).
-- C01: downtown's Spanish Renaissance bell tower, a one-off landmark (CITY_PLAN §5.1). Weight 0: the per-plot draw
-- never picks it; the planner places it once at its anchor. Its full look wants a site about 100 wide and 50+ deep
-- (a 4-storey base, a press wing, a 36-stud tower); narrower and shallower sites get a smaller tower and no wing.

return {
	district = "downtown",
	weight = 0,
	maxCopies = 1,
	perBlock = 1,
	minSpacing = 2000,
	minWidth = 60,
	maxWidth = 140,
	minDepth = 40,
	maxPlots = 4,
	-- The top of the shaft's cornice. The belvedere, cupola, dome, lantern and vane rise up to crownMax over it
	-- (about 225 in all, ARCHETYPES §9).
	heights = { min = 160, max = 180 },
	crownMax = 66,
	budget = 120,
	palettes = 3,
	crowns = 2,
	rhythms = 2,
	ownModel = true,
}
