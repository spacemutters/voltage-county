--!strict
-- car_lift_cylinder_tower: placement and limits (Config/City archetypes; docs/city/ARCHETYPES.md).
-- T17: a dark glass round tower ringed by silver balconies, a glass car-lift shaft up its side with cars in it.

return {
	district = "downtown",
	weight = 1,
	maxCopies = 2,
	perBlock = 1,
	minSpacing = 700,
	minWidth = 76, -- the drum, its rings and the 20-stud shaft beside it
	maxWidth = 132, -- wider sites get a drive-in court with a round canopy and a glass pavilion
	minDepth = 46,
	-- The drum is as wide as the site is deep less 9: 44 across on a bare plot (a needle at 400 tall), 64 with a claim.
	claimDepth = 100,
	maxPlots = 3,
	heights = { min = 260, max = 420 }, -- about 455 compressed
	crownMax = 12, -- the shaft's overrun and its machine room
	budget = 84, -- at most 82 (a 46-deep site, a ring every second floor, the lit top floor, six lit floors)
	palettes = 3,
	crowns = 3,
	rhythms = 3,
	ownModel = true,
}
