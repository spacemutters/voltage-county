--!strict
-- sawtooth_office_tower: placement and limits (Config/City archetypes; docs/city/ARCHETYPES.md).
-- T05: downtown's one-off stone office tower, one corner cut into a staircase of teeth up to a stepped top, a lit
-- notch down its street face, a parking annex and a space-frame plaza. A half-block site: 4 or 5 plots.

return {
	district = "downtown",
	weight = 1,
	maxCopies = 1,
	perBlock = 1,
	minSpacing = 900,
	minWidth = 140,
	maxWidth = 240,
	minDepth = 46,
	maxPlots = 5,
	heights = { min = 280, max = 530 },
	crownMax = 46,
	budget = 80,
	palettes = 3,
	crowns = 2,
	rhythms = 2,
	ownModel = true,
}
