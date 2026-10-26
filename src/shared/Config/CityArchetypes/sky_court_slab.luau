--!strict
-- sky_court_slab: placement and limits (Config/City archetypes; docs/city/ARCHETYPES.md).
-- T08: a broad blue mirror-glass slab under a white supergrid, with one square of the grid punched right through it
-- as a sky court (a palm, a red spiral stair, a spa and a glowing yellow wall inside), a solid red gable on the roof,
-- yellow triangle balconies at the far end and white balcony bands on the back. Its landmark on the bay row asks 70
-- deep and faces the lake.
-- Budget: about 76 parts on a wide, tall site (the court's stair, palm and wall are 25 of them).

return {
	district = "downtown",
	weight = 1,
	maxCopies = 3,
	perBlock = 1,
	minSpacing = 450,
	minWidth = 110,
	maxWidth = 200,
	minDepth = 46,
	maxPlots = 4,
	-- A broad, low slab (Studio round 1: up to 240 tall it read as a squat tower, not the photos' long wall).
	heights = { min = 130, max = 200 },
	crownMax = 40,
	budget = 86,
	palettes = 3,
	crowns = 2,
	rhythms = 2,
	ownModel = true,
}
