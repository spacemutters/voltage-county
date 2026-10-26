--!strict
-- triple_tower_podium: placement and limits (Config/City archetypes; docs/city/ARCHETYPES.md §5, T12).
-- T12: a one-off. Two identical slim grid towers and a shorter hotel tower, each two interlocking slabs under open
-- lattice frames, on one glass podium with a pool deck, lifted at the street over a drive lined with giant stone
-- monoliths with glowing eyes. It needs a whole frontage: five to seven plots.

return {
	district = "downtown",
	weight = 1,
	maxCopies = 1,
	perBlock = 1,
	minSpacing = 600,
	minWidth = 170,
	maxWidth = 280,
	minDepth = 48,
	maxPlots = 7,
	heights = { min = 320, max = 440 },
	crownMax = 16, -- the lattice frames (14) and their plates over the tall slabs
	-- The podium and ground 10..11, the monoliths 5 each (4..7 of them), three towers of two slabs 16..18 each, the
	-- deck up to 15: 101..112 over tests/City.spec's sample sites.
	budget = 120,
	palettes = 3,
	crowns = 2,
	rhythms = 2, -- 1 the short slabs step forward and stop four floors under; 2 they step back and stop six under
	ownModel = true,
}
