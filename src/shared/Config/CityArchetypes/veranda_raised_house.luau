--!strict
-- veranda_raised_house: placement and limits (Config/City archetypes; docs/city/ARCHETYPES.md).
-- R03: the Old Florida wooden house: a deep veranda all round the upper floor on tall posts, under a steep dark
-- pointed roof (its peak is the roof, 32..36: about 40 degrees over the deck) with a louvred vent lantern or a finial spike.

return {
	district = "suburbs",
	weight = 1,
	maxCopies = 12,
	perBlock = 2,
	minSpacing = 120,
	minWidth = 30,
	maxWidth = 47,
	minDepth = 40,
	maxPlots = 2,
	heights = { min = 32, max = 36 },
	crownMax = 5,
	budget = 46,
	palettes = 3,
	crowns = 2,
	rhythms = 2,
	ownModel = false,
}
