--!strict
-- tiled_mural_midrise: placement and limits (Config/City archetypes; docs/city/ARCHETYPES.md).
-- T18: a floating dark glass office block whose two end walls are giant blue-and-white tile murals, beside a stained
-- glass box raised on one stem.

return {
	district = "downtown",
	weight = 1,
	maxCopies = 4,
	perBlock = 1,
	minSpacing = 450,
	minWidth = 96, -- the block and the raised glass box beside it
	maxWidth = 140,
	minDepth = 46,
	maxPlots = 3,
	heights = { min = 96, max = 128 }, -- eight storeys over a recessed ground floor; its inspiration is 104
	crownMax = 8, -- the roof's plant room
	budget = 80, -- at most 77 (140 wide, the tree mural and the glass box: 24 mosaic panes)
	palettes = 2,
	crowns = 2,
	rhythms = 2,
	ownModel = false,
}
