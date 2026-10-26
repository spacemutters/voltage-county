--!strict
-- mosaic_townhouse_row: placement and limits (Config/City archetypes; docs/city/ARCHETYPES.md).
-- R08: a row of four to six white townhouses of different heights (the tallest is the height), each under a crisp
-- coping with its own bold colour hit (a deep picture-frame box among them), roof stair houses with thin canopies,
-- and (crown 2) a taller mosaic-tiled end unit cut by deep loggias. Two or three plots merged (56..100). Budget: up to
-- 60 parts as drawn.

return {
	district = "suburbs",
	weight = 1,
	maxCopies = 16,
	perBlock = 2,
	minSpacing = 150,
	minWidth = 56,
	maxWidth = 100,
	minDepth = 42,
	maxPlots = 3,
	heights = { min = 42, max = 50 },
	crownMax = 9,
	budget = 66,
	palettes = 4,
	crowns = 2,
	rhythms = 2,
	ownModel = false,
}
