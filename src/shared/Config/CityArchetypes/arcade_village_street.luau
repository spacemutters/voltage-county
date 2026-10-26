--!strict
-- arcade_village_street: placement and limits (Config/City archetypes; docs/city/ARCHETYPES.md).
-- B12: the Mediterranean shop row: an arcade or striped awnings, iron balconies, red tile, a belvedere.

return {
	district = "beach",
	weight = 1,
	maxCopies = 7,
	perBlock = 1,
	minSpacing = 220,
	minWidth = 60,
	maxWidth = 104,
	minDepth = 40,
	maxPlots = 3,
	heights = { min = 30, max = 40 },
	crownMax = 24, -- the belvedere: its shaft, loggia, eave, pyramid and finial reach about 22 over the roof
	budget = 96, -- a row of five or six shopfronts: up to six arches with a striped awning (3 parts) in each, the belvedere 21
	palettes = 3,
	crowns = 2,
	rhythms = 2,
	ownModel = false,
}
