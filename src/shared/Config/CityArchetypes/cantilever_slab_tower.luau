--!strict
-- cantilever_slab_tower: placement and limits (Config/City archetypes; docs/city/ARCHETYPES.md §5, T13).
-- T13: the white honeycomb tower: deep white slabs every floor and a white column every bay, the slab edges rippling
-- up the tower, a thick white cap, a glazed lobby on hourglass columns and a round drop-off canopy. Heights from the
-- T blocks' caps up; the tallest only where a cap allows (Config/City heightCaps).

return {
	district = "downtown",
	weight = 1,
	maxCopies = 3,
	perBlock = 1,
	minSpacing = 600,
	minWidth = 76,
	maxWidth = 150,
	minDepth = 48,
	maxPlots = 4,
	heights = { min = 300, max = 460 },
	crownMax = 12, -- crown 3's open frame (10), crown 2's umbrellas (8) and cabana, crown 1's plant room
	-- A slab a floor (23..37), a ring every fifth, 12..14 columns, the ground (16..24), the cap and crown (4..11):
	-- 64..95 over tests/City.spec's sample sites.
	budget = 100,
	palettes = 4,
	crowns = 3,
	rhythms = 3, -- the slab wave: slow and deep, quick, or a stagger
	ownModel = true,
}
