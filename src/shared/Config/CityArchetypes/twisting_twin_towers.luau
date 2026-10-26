--!strict
-- twisting_twin_towers: placement and limits (Config/City archetypes; docs/city/ARCHETYPES.md §5, T11).
-- T11: two slim condo towers in a garden whose white floor plates turn a little more every floor, the pair twisting
-- opposite ways. Two towers per site, so a wide site (four or five plots) and about twice a tower's parts.

return {
	district = "downtown",
	weight = 1,
	maxCopies = 2,
	perBlock = 1,
	minSpacing = 600,
	minWidth = 130,
	maxWidth = 230,
	minDepth = 48,
	maxPlots = 6,
	heights = { min = 216, max = 264 },
	crownMax = 12, -- the roof pavilions, the floating caps and the pergolas
	budget = 120, -- 2 towers x (a plate and half a glass run a floor, LED rings, lobby, crown) + the garden: 94..112
	palettes = 4,
	crowns = 3,
	rhythms = 3, -- the twist: 30, 38 or 45 degrees
	ownModel = true,
	claimDepth = 90, -- with room in the block, a deeper garden: bigger plates and the lawn and drop-off in front
}
