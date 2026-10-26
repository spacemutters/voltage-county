--!strict
-- domed_cupola_hotel: placement and limits (Config/City archetypes; docs/city/ARCHETYPES.md).
-- B09: the cream hotel tower crowned by an open belfry and a metal dome, its wings running back.

return {
	district = "beach",
	weight = 1,
	maxCopies = 2,
	perBlock = 1,
	minSpacing = 600,
	minWidth = 76,
	maxWidth = 140,
	minDepth = 44,
	maxPlots = 4,
	heights = { min = 128, max = 160 },
	crownMax = 56, -- the plinth, a 24-wide belfry (23 tall), its dome, spike and finial reach about 50
	budget = 92, -- 83 on a plot; a deep site (a core claim) adds its pool court and the wings' court-side windows
	palettes = 3,
	crowns = 2,
	rhythms = 2,
	ownModel = true,
}
