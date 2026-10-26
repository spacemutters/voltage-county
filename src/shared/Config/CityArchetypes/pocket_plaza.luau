--!strict
-- pocket_plaza: placement and limits (Config/City archetypes; Config/CityLots).
-- L2: a pocket plaza: patterned paving, a fountain or a sculpture, benches, palms, planters and a
-- glass kiosk with café tables when it is wide enough.
-- A lot type: weight 0, so the building passes never draw it; the lot pass (Dev/City/CityBuilder, Config/CityLots mix)
-- puts it on open plots. Its height is its tallest pole's; its parts follow Config/CityLots parts (budget is the most).

return {
	district = "downtown",
	weight = 0,
	maxCopies = 120,
	perBlock = 2,
	minSpacing = 0,
	minWidth = 21,
	maxWidth = 150,
	minDepth = 30,
	maxPlots = 4,
	heights = { min = 13, max = 16 },
	crownMax = 34,
	budget = 18,
	palettes = 4,
	crowns = 3,
	rhythms = 2,
	ownModel = false,
}
