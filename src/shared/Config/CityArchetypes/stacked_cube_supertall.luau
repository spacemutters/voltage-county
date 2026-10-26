--!strict
-- stacked_cube_supertall: placement and limits (Config/City archetypes; docs/city/ARCHETYPES.md §5, T01).
-- T01: nine sleek glass cubes, each slid a sixth of its width off the one below, split by dark joints, on a ten-storey
-- podium: the county's tallest tower. A one-off landmark (CITY_PLAN §5; Config/City landmarks): weight 0, so the
-- per-plot draw never picks it, and the planner builds it once at its anchor with a core claim. Its full look wants a
-- site about 200 wide and 110 deep (72-stud cubes, a pool deck on the podium beside the stack). Narrower or shallower
-- sites get smaller cubes; a bare 53-deep plot gets a slim stack of 33-stud cubes.

return {
	district = "downtown",
	weight = 0,
	maxCopies = 1,
	perBlock = 1,
	minSpacing = 2000,
	minWidth = 110,
	maxWidth = 230,
	minDepth = 53,
	maxPlots = 6,
	-- The top cube's roof (ARCHETYPES §1: 1,049 ft compressed to 700 studs). The crown (a sky pool and a mast, a lantern
	-- cube or an open frame, a beacon) rises up to crownMax over it.
	heights = { min = 660, max = 700 },
	crownMax = 40,
	-- 118..152 parts over the spec's sample sites and every variant on 110-deep sites (2026-10-26: the nine dark joint
	-- slabs, lit at night, added after the Studio preview).
	budget = 160,
	palettes = 3,
	crowns = 3,
	rhythms = 3,
	ownModel = true,
	claimDepth = 110,
}
