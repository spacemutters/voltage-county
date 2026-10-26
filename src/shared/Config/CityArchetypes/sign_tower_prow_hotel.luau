--!strict
-- sign_tower_prow_hotel: placement and limits (Config/City archetypes; docs/city/ARCHETYPES.md).
-- B03: two banded wings over a porch on posts, either side of a sign tower whose coloured ship's-bow prow carries the
-- name and whose shoulders step down beside it, rising far over the roof to a needle or turned tiers. Three storeys;
-- always two plots (a wide F2 site).

return {
	district = "beach",
	weight = 1,
	maxCopies = 5,
	perBlock = 1,
	minSpacing = 300,
	minWidth = 52,
	maxWidth = 92,
	minDepth = 40,
	maxPlots = 2,
	heights = { min = 38, max = 44 },
	crownMax = 42,
	budget = 66,
	palettes = 4,
	crowns = 2,
	rhythms = 2,
	ownModel = false,
}
