--!strict
-- triple_tower_podium: placement and limits (Config/City archetypes; docs/city/ARCHETYPES.md §5, T12).
-- T12: a one-off. Two identical slim towers and a shorter third one on one huge podium with a pool deck, and at the
-- street a colonnade of giant stone monoliths with glowing eyes. It needs a whole frontage: five to seven plots.

return {
	district = "downtown",
	weight = 1,
	maxCopies = 1,
	perBlock = 1,
	minSpacing = 600,
	minWidth = 170,
	maxWidth = 280,
	minDepth = 48,
	maxPlots = 7,
	heights = { min = 320, max = 440 },
	crownMax = 16, -- the lattice screens and the lit tiers over the main blocks
	budget = 118, -- podium 8, monoliths 5 parts each (up to 8: 40), pool deck 10, three towers 49..53: about 95..112
	palettes = 3,
	crowns = 2,
	rhythms = 2, -- 1 the second blocks step forward, a balcony every third floor; 2 they step back, every fourth
	ownModel = true,
}
