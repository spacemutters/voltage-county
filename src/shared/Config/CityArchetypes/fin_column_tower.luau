--!strict
-- fin_column_tower: placement and limits (Config/City archetypes; docs/city/ARCHETYPES.md §5, T14).
-- T14: a slim glass tower held by four white blades on the diagonal at its corners, running from the ground past the
-- roof, a smooth blue glass spine down its front between two cascading balcony stacks, low glass wings either side.

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
	crownMax = 28, -- the blades rise 26 past the roof (crowns 1 and 2), the spine's cap 9
	-- A front slab a floor (24..37), a back one every third, the blades and their lines and rakes (8..12), the ground
	-- (8..12, the canopy's posts included), the crown (3..7), the wings (up to 19): 59..99 over tests/City.spec's
	-- sample sites.
	budget = 110,
	palettes = 3,
	crowns = 3,
	rhythms = 3, -- the cascade: a slow wave, a quick one, or a diagonal shift
	ownModel = true,
}
