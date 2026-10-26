--!strict
-- stair_wing_slab: placement and limits (Config/City archetypes; docs/city/ARCHETYPES.md).
-- T09: a plain white slab ribbed with white fins, with a giant orange staircase of terraced blocks stepping down out
-- of it toward the street, every tread capped, railed and lit at night. Its landmark (d6, toward the bridge) asks 120
-- deep, so the stair comes right out to the street there.
-- Budget: about 69 parts at its widest (the eight-step stair is 40 of them).

return {
	district = "downtown",
	weight = 1,
	maxCopies = 3,
	perBlock = 1,
	minSpacing = 450,
	minWidth = 130,
	maxWidth = 220,
	minDepth = 46,
	maxPlots = 5,
	heights = { min = 200, max = 320 },
	crownMax = 24,
	budget = 76,
	palettes = 3,
	crowns = 2,
	rhythms = 2,
	ownModel = true,
}
