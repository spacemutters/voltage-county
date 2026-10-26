--!strict
-- corner_spire_hotel: placement and limits (Config/City archetypes; docs/city/ARCHETYPES.md).
-- B06: the nautical corner hotel: a round corner that rises past the roof as a finned smokestack under a needle
-- spire, the name down a fin on the corner, portholes under the cornice. Three storeys; always two plots. Its round
-- corner stands at one front corner of the site (the mirror picks which), so it reads best at the end of a run.

return {
	district = "beach",
	weight = 1,
	maxCopies = 3,
	perBlock = 1,
	minSpacing = 400,
	minWidth = 48,
	maxWidth = 80,
	minDepth = 40,
	maxPlots = 2,
	heights = { min = 39, max = 45 },
	crownMax = 48,
	budget = 60,
	palettes = 4,
	crowns = 2,
	rhythms = 2,
	ownModel = false,
}
