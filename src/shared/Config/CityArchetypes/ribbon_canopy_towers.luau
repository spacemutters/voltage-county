--!strict
-- ribbon_canopy_towers: placement and limits (Config/City archetypes; docs/city/ARCHETYPES.md).
-- T16: a three-storey open-air shopping podium cut by a pedestrian street, two or three chamfer-topped glass towers on
-- it, and a folded white ribbon canopy floating over the street and along the front. A one-off.

return {
	district = "downtown",
	weight = 1,
	maxCopies = 1, -- a one-off: Config/City landmarks places it, 110 deep, by the spawn street
	perBlock = 1,
	minSpacing = 2000,
	minWidth = 150, -- two shop blocks either side of the street, a tower on each
	maxWidth = 250, -- a third tower once one block can hold two
	minDepth = 46,
	maxPlots = 6,
	heights = { min = 260, max = 380 }, -- the tallest tower; the others step down 26 at a time
	crownMax = 6, -- the copings over the chamfers
	budget = 116,
	palettes = 2,
	crowns = 2,
	rhythms = 2,
	ownModel = true,
}
