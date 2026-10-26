--!strict
-- cantilever_slab_tower: placement and limits (Config/City archetypes; docs/city/ARCHETYPES.md §5, T13).
-- T13: a slim condo tower of deep white floor slabs whose edges ripple in and out up the tower, held at the corners
-- by stacked columns that swell at every slab. Heights from the T blocks' caps up; the tallest only where a cap
-- allows (Config/City heightCaps).

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
	crownMax = 12, -- the roof rooms, the pergola and the pool deck's rail
	budget = 120, -- a slab every floor, a swelling on each of the four columns at every third: measured 70..116
	palettes = 4,
	crowns = 3,
	rhythms = 3, -- the slab edges' wave: slow and deep, quicker, or a stagger
	ownModel = true,
}
