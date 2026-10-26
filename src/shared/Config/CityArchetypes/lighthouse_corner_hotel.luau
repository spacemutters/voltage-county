--!strict
-- lighthouse_corner_hotel: placement and limits (Config/City archetypes; docs/city/ARCHETYPES.md).
-- B07: the corner hotel with a little lighthouse on its rounded corner.

return {
	district = "beach",
	weight = 1,
	maxCopies = 3,
	perBlock = 1,
	minSpacing = 300,
	minWidth = 36,
	maxWidth = 60,
	minDepth = 40,
	maxPlots = 2,
	heights = { min = 46, max = 56 },
	crownMax = 28,
	budget = 78, -- 61 to 74 seen: six lantern mullions and the broad hat; a little headroom
	palettes = 4,
	crowns = 2,
	rhythms = 2,
	ownModel = false,
}
