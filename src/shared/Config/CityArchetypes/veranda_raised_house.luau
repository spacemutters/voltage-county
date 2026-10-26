--!strict
-- veranda_raised_house: placement and limits (Config/City archetypes; docs/city/ARCHETYPES.md).
-- R03: the Old Florida clapboard house: a deep veranda all round the upper floor on tall posts under a white frieze,
-- a steep pointed roof (its peak is the roof, 32..36: about 40 degrees over the deck) with a louvred cupola or a
-- finial spike. Budget: up to 45 parts as drawn (five posts a side, the cupola).

return {
	district = "suburbs",
	weight = 1,
	maxCopies = 16,
	perBlock = 2,
	minSpacing = 120,
	minWidth = 30,
	maxWidth = 47,
	minDepth = 40,
	maxPlots = 2,
	heights = { min = 32, max = 36 },
	crownMax = 5,
	budget = 48,
	palettes = 3,
	crowns = 2,
	rhythms = 2,
	ownModel = false,
}
