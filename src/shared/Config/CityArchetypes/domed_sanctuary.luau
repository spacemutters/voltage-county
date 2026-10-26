--!strict
-- domed_sanctuary: placement and limits (Config/City archetypes; docs/city/ARCHETYPES.md §9, C05).
-- C05: the beach district's domed sanctuary, a smooth pale block crowned by one big round dome, a one-off landmark
-- (its site needs the planner, see the module's header). Weight 0: the per-plot draw never picks it. Its full look
-- wants a two-plot site about 80 wide and 50 deep.

return {
	district = "beach",
	weight = 0,
	maxCopies = 1,
	perBlock = 1,
	minSpacing = 2000,
	minWidth = 56,
	maxWidth = 100,
	minDepth = 44,
	maxPlots = 2,
	-- The block's cornice. The drum, dome, lantern and finial rise up to crownMax over it (about 80 in all).
	heights = { min = 34, max = 40 },
	crownMax = 50,
	budget = 80,
	palettes = 3,
	crowns = 2,
	rhythms = 2,
	ownModel = true,
}
