--!strict
-- deco_porthole_highrise: placement and limits (Config/City archetypes; docs/city/ARCHETYPES.md).
-- B04: the beach strip's tall Deco hotel: ten to twelve storeys of piers and spandrels, a projecting porthole entry,
-- and a stepped ziggurat crown ringed in neon with the name on it. Two or three plots; its own model (it is seen from
-- far along the shore).

return {
	district = "beach",
	weight = 1,
	maxCopies = 3,
	perBlock = 1,
	minSpacing = 500,
	minWidth = 50,
	maxWidth = 96,
	minDepth = 40,
	maxPlots = 3,
	heights = { min = 124, max = 140 },
	crownMax = 32, -- the ziggurat's three tiers (24) and the flagpole and finial over them
	budget = 88,
	palettes = 3,
	crowns = 2,
	rhythms = 2,
	ownModel = true,
}
