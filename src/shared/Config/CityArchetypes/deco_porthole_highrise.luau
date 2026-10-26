--!strict
-- deco_porthole_highrise: placement and limits (Config/City archetypes; docs/city/ARCHETYPES.md).
-- B04: the beach strip's tall Deco hotel: ten to twelve storeys, a centre shaft of piers stepping up into a ziggurat
-- attic between corner bays of wrapping eyebrows, a projecting porthole entry, a lantern under a rooftop name board.
-- Two or three plots; its own model (it is seen from far along the shore).

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
	crownMax = 32, -- the ziggurat's three tiers (21) and the lantern and name board over them (to 31)
	budget = 80,
	palettes = 3,
	crowns = 2,
	rhythms = 2,
	ownModel = true,
}
