--!strict
-- mosaic_townhouse_row: placement and limits (Config/City archetypes; docs/city/ARCHETYPES.md).
-- R08: a row of four to six white townhouses of different heights (the tallest is the height), each with its own
-- bold colour hit, roof stair houses with thin canopies, and (crown 2) a taller mosaic-tiled end unit. Two or three
-- plots merged (56..100).

return {
	district = "suburbs",
	weight = 1,
	maxCopies = 8,
	perBlock = 2,
	minSpacing = 200,
	minWidth = 56,
	maxWidth = 100,
	minDepth = 42,
	maxPlots = 3,
	heights = { min = 42, max = 50 },
	crownMax = 9,
	budget = 52,
	palettes = 4,
	crowns = 2,
	rhythms = 2,
	ownModel = false,
}
