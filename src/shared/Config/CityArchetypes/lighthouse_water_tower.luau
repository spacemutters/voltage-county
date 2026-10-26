--!strict
-- lighthouse_water_tower: placement and limits (Config/City archetypes; docs/city/ARCHETYPES.md §9, C07).
-- C07: the suburbs' water tower dressed as a Mediterranean lighthouse, a one-off. ARCHETYPES §9 has it replace the
-- look of the riverside_water_tower feature (Config/MapLayout features: 30 x 30, 112 tall): the scenery or planner
-- step builds it there as a 30 x 30 site. Weight 0: the per-plot draw never picks it. Every size from 28 to 46 works;
-- 30 x 30 is its own.

return {
	district = "suburbs",
	weight = 0,
	maxCopies = 1,
	perBlock = 1,
	minSpacing = 2000,
	minWidth = 28,
	maxWidth = 46,
	minDepth = 28,
	maxPlots = 1,
	-- The gallery's floor. The lantern, its dome, the finial and the beacon rise up to crownMax over it (at most
	-- 112 in all, the feature's height).
	heights = { min = 80, max = 86 },
	crownMax = 26,
	budget = 72,
	palettes = 3,
	crowns = 2,
	rhythms = 2,
	ownModel = true,
}
