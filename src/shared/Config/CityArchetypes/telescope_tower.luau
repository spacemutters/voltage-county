--!strict
-- telescope_tower: placement and limits (Config/City archetypes; docs/city/ARCHETYPES.md).
-- T10: an upside-down tower of three glass tiers, each a big step wider than the one under it along the road, on a
-- narrow glass lobby with pools under the overhangs; white balcony slabs and corner piers frame every tier, white
-- soffits close every step out, lit as four rings that widen upward at night.
-- Budget: about 58 parts at its tallest (18 balcony slabs and 12 corner piers are half of it).

return {
	district = "downtown",
	weight = 1,
	maxCopies = 3,
	perBlock = 1,
	minSpacing = 450,
	minWidth = 76,
	maxWidth = 130,
	minDepth = 46,
	maxPlots = 3,
	heights = { min = 260, max = 460 },
	crownMax = 12,
	budget = 66,
	palettes = 3,
	crowns = 2,
	rhythms = 2,
	ownModel = true,
}
