--!strict
-- neon_fin_hotel: placement and limits (Config/City archetypes; docs/city/ARCHETYPES.md).
-- B02: the low banded beach hotel with one tall blade fin standing up from a boxy marquee (an inverted-T sign).
-- Three or four storeys (37..51): the parapet takes up what whole floors leave. One plot or two.

return {
	district = "beach",
	weight = 1,
	maxCopies = 5,
	perBlock = 2,
	minSpacing = 200,
	minWidth = 30,
	maxWidth = 58,
	minDepth = 40,
	maxPlots = 2,
	heights = { min = 37, max = 51 },
	crownMax = 20,
	budget = 64,
	palettes = 4,
	crowns = 2,
	rhythms = 2,
	ownModel = false,
}
