--!strict
-- streamline_round_corner: placement and limits (Config/City archetypes; docs/city/ARCHETYPES.md).
-- B05: the Streamline hotel with big round corners that its pastel eyebrows and glass bands wrap like a car's
-- fender, a keystone central bay rising to a pediment between chrome medallions, the name on the canopy (and on a
-- rooftop blade). Three storeys; always two plots (a wide F2 site).

return {
	district = "beach",
	weight = 1,
	maxCopies = 6,
	perBlock = 2,
	minSpacing = 220,
	minWidth = 50,
	maxWidth = 84,
	minDepth = 40,
	maxPlots = 2,
	heights = { min = 38, max = 44 },
	crownMax = 16, -- crown 2's rooftop name blade
	budget = 74,
	palettes = 5,
	crowns = 2,
	rhythms = 2,
	ownModel = false,
}
