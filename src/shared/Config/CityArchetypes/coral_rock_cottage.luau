--!strict
-- coral_rock_cottage: placement and limits (Config/City archetypes; docs/city/ARCHETYPES.md).
-- R02: the low coral-rock cottage under coral-red gables with a white-columned porch (Doric columns under square
-- caps) and a coral-rock garden wall with capped gate piers. One and a half storeys: the ridge is the roof (17..20)
-- and only the chimney rises past it. Budget: up to 55 parts as drawn (the wrapped porch, the Palladian window).

return {
	district = "suburbs",
	weight = 1,
	maxCopies = 22,
	perBlock = 2,
	minSpacing = 120,
	minWidth = 26,
	maxWidth = 47,
	minDepth = 40,
	maxPlots = 2,
	heights = { min = 17, max = 20 },
	crownMax = 4,
	budget = 58,
	palettes = 3,
	crowns = 2,
	rhythms = 2,
	ownModel = false,
}
