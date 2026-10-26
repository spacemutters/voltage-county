--!strict
-- port_crane_yard: placement and limits (Config/City archetypes; docs/city/ARCHETYPES.md).
-- W05: two ship-to-shore container cranes over a yard of coloured containers, the working port's silhouette. A
-- one-off by the freight depot (Config/City landmarks, with a core claim up to 140 deep); its lowest height is over
-- the arts district's cap, so it never stands as a repeatable. crownMax covers a raised boom's tip and its beacon.

return {
	district = "arts",
	weight = 1,
	maxCopies = 1,
	perBlock = 1,
	minSpacing = 2000,
	minWidth = 150,
	maxWidth = 300,
	minDepth = 50,
	maxPlots = 7,
	heights = { min = 120, max = 136 },
	crownMax = 42,
	budget = 136, -- the cranes and the yard take about 85 (bogies, a box mid-lift); containers fill the rest
	palettes = 2,
	crowns = 3,
	rhythms = 2,
	ownModel = false,
}
