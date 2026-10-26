--!strict
-- corner_spire_hotel: placement and limits (Config/City archetypes; docs/city/ARCHETYPES.md).
-- B06: the nautical corner hotel: a round bay on the corner over an open loggia, carrying a slim finned sign tower
-- (or a smokestack) under a needle spire, the name down its blade, portholes under both cornices. Three storeys;
-- always two plots. Its round corner stands at one front corner of the site (the mirror picks which), so it reads
-- best at the end of a run.

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
	budget = 72,
	palettes = 4,
	crowns = 2,
	rhythms = 2,
	ownModel = false,
}
