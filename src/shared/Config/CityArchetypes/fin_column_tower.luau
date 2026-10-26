--!strict
-- fin_column_tower: placement and limits (Config/City archetypes; docs/city/ARCHETYPES.md §5, T14).
-- T14: a slim glass tower on a low podium, four white blade fins standing diagonally out of its corners and rising
-- past the roof with raked tops, a cascade of balconies stepping across its front.

return {
	district = "downtown",
	weight = 1,
	maxCopies = 3,
	perBlock = 1,
	minSpacing = 600,
	minWidth = 72,
	maxWidth = 150,
	minDepth = 48,
	maxPlots = 4,
	heights = { min = 300, max = 460 },
	crownMax = 32, -- the blades rise up to 30 past the roof
	budget = 80, -- podium 10, deck up to 8, core and blades 15, crown up to 7, the cascade 2 a balcony: 50..76
	palettes = 3,
	crowns = 3,
	rhythms = 3, -- the cascade: a balcony every 2, 3 or 4 floors (the last on the back face too)
	ownModel = true,
}
