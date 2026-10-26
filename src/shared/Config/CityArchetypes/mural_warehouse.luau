--!strict
-- mural_warehouse: placement and limits (Config/City archetypes; docs/city/ARCHETYPES.md).
-- W01: the arts district's painted block warehouse, its whole street wall one giant mural. The district's workhorse:
-- it fits a single plot (a 21..47 site from 26 up) or two or three merged.

return {
	district = "arts",
	weight = 3,
	maxCopies = 25,
	perBlock = 3,
	minSpacing = 90,
	minWidth = 26,
	maxWidth = 96,
	minDepth = 36,
	maxPlots = 3,
	heights = { min = 20, max = 30 },
	crownMax = 11,
	budget = 50,
	palettes = 5,
	crowns = 4,
	rhythms = 4,
	ownModel = false,
}
