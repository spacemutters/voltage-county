--!strict
-- mediterranean_villa: placement and limits (Config/City archetypes; docs/city/ARCHETYPES.md).
-- R01: the suburbs' Mediterranean Revival villa: a stucco block under a low hipped tile roof, a three-arch loggia and
-- a square stair tower. The grand house of the street, so it wants a wide plot (36..47) or two narrow ones merged.

return {
	district = "suburbs",
	weight = 1,
	maxCopies = 12,
	perBlock = 2,
	minSpacing = 120,
	minWidth = 36,
	maxWidth = 47,
	minDepth = 40,
	maxPlots = 2,
	heights = { min = 22, max = 28 },
	crownMax = 11,
	budget = 64,
	palettes = 4,
	crowns = 2,
	rhythms = 2,
	ownModel = false,
}
