--!strict
-- harbor_market_pavilions: placement and limits (Config/City archetypes; docs/city/ARCHETYPES.md §9, C03).
-- C03: the bayfront market, two open market halls either side of a plaza with a giant observation wheel, a one-off
-- landmark on the bay row's west end (CITY_PLAN §5.1). Weight 0: the per-plot draw never picks it. Its front (-z) is
-- the gateway and the halls' shop arcades, so its landmark entry should face the road; its back (+z) is the boardwalk.
-- Its full look wants a site about 200 wide and 80+ deep (a core claim): on a plain 53-deep plot the wheel shrinks to
-- fit between the halls.

return {
	district = "beach",
	weight = 0,
	maxCopies = 1,
	perBlock = 1,
	minSpacing = 2000,
	minWidth = 150,
	maxWidth = 260,
	minDepth = 44,
	maxPlots = 6,
	-- The halls' top (the clerestories' ridge over steep two-storey roofs). The wheel rises up to crownMax over it
	-- (about 160 in all).
	heights = { min = 36, max = 40 },
	crownMax = 124,
	-- Two halls of about 25 parts each (posts, a hipped and gabled roof, a clerestory, a round gable window), the plaza
	-- and boardwalk about 28, the wheel up to 57 (24 rim segments, nine spoke bars, sixteen cabins, two braced A-frames).
	budget = 150,
	palettes = 3,
	crowns = 2,
	rhythms = 2,
	ownModel = true,
}
