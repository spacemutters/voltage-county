--!strict
-- finned_tower_hotel: placement and limits (Config/City archetypes; docs/city/ARCHETYPES.md).
-- B08: the all-white stepped hotel slab whose central tower breaks out into a crown of fins.

return {
	district = "beach",
	weight = 1,
	maxCopies = 2,
	perBlock = 1,
	minSpacing = 600,
	minWidth = 64,
	maxWidth = 104,
	minDepth = 44,
	maxPlots = 3,
	heights = { min = 140, max = 176 },
	crownMax = 48, -- the shaft (33), its cap and the fins' horns (7) reach about 41; the mast and its beacon take the rest
	budget = 72,
	palettes = 3,
	crowns = 2,
	rhythms = 2,
	ownModel = true,
}
