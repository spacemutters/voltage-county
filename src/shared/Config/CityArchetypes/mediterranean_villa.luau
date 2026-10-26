--!strict
-- mediterranean_villa: placement and limits (Config/City archetypes; docs/city/ARCHETYPES.md).
-- R01: the suburbs' Mediterranean Revival villa: stucco volumes under low barrel-tile roofs (a side-gabled main
-- block, a front gabled bay with an arched window, a recessed arcade under a balcony), a square stair tower and a
-- garage wing or a carriage gate. The grand house of the street, so it wants a wide plot (36..47) or two narrow ones
-- merged. Budget: 66..75 parts as drawn (two or three arches, the mirador crown, the gate).

return {
	district = "suburbs",
	weight = 1,
	maxCopies = 16,
	perBlock = 2,
	minSpacing = 120,
	minWidth = 36,
	maxWidth = 47,
	minDepth = 40,
	maxPlots = 2,
	heights = { min = 22, max = 28 },
	crownMax = 11,
	budget = 80,
	palettes = 4,
	crowns = 2,
	rhythms = 2,
	ownModel = false,
}
