--!strict
-- parallelogram_void_tower: placement and limits (Config/City archetypes; docs/city/ARCHETYPES.md).
-- T15: two clear glass slabs locked side by side, raked tops, a six-storey void with a lap pool cut through the taller
-- one, a lit grid frame up the outer corner.

return {
	district = "downtown",
	weight = 1,
	maxCopies = 2,
	perBlock = 1,
	minSpacing = 700,
	minWidth = 80,
	maxWidth = 150,
	minDepth = 46,
	claimDepth = 100, -- deeper slabs (42) and a pool deck on the podium in front of them
	maxPlots = 4,
	-- Its inspiration is about 490 compressed; the downtown block caps (300..380 in the tower blocks) bring it down.
	heights = { min = 300, max = 460 },
	crownMax = 12, -- copings over the raked top, the grid frame's head
	budget = 96,
	palettes = 3,
	crowns = 3,
	rhythms = 3,
	ownModel = true,
}
