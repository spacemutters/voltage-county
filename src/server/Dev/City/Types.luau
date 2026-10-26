--!strict
-- The city builder's data shapes (docs/city/ARCHETYPE_GUIDE.md): a plot from MapBuilder's plot pass, a site the
-- placement makes of one or more plots (and maybe a core claim behind them), the model an archetype writes its parts
-- into, an archetype module, and the clear checks MapBuilder lends the placement for core claims.

local MapTypes = require(script.Parent.Parent.MapTypes)

export type PartSpec = MapTypes.PartSpec
export type TextureSpec = MapTypes.TextureSpec

-- How one copy of an archetype differs from the next (all drawn from the site's seed).
export type Variant = {
	palette: number, -- 1..ArchetypeConfig.palettes
	crown: number, -- 1..crowns
	rhythm: number, -- 1..rhythms
	mirror: boolean, -- flipped along the road (local X)
}

-- One building site. Its frame sits on the ground at the centre of its footprint, local X along the road, local -Z
-- toward its front: the front line is z = -depth/2 and the back z = +depth/2, the sides x = ±width/2. The front
-- looks at the site's road unless `face` is "back" (a bay-row one-off turned to the lake). Every part must stay
-- inside that footprint, between y = -kit.bury and y = maxHeight.
export type Site = {
	id: string, -- "B<index>" of its first plot: every part's name starts with it
	archetype: string,
	district: string,
	zone: string,
	frame: CFrame,
	width: number,
	depth: number, -- its plots' depth, plus its core claim's
	height: number, -- the main roof
	maxHeight: number, -- crowns, spires, signs and flagpoles included
	seed: number, -- its own random stream (Kit.rng)
	variant: Variant,
	folder: string, -- the Atomic model its parts go in (below Workspace.Map.Generated): SLIM, still parts only
	lightsFolder: string, -- the Atomic model its night lights, signs and lights go in (not SLIM; CityBuilder.file)
	plots: { number }, -- the plots it stands on (MapBuilder's building numbers)
	block: number, -- the city block (MapBuilder's findBlocks face) it stands in
	band: string, -- "L", "M", "H", "T" or "S" (Config/City bands)
	face: "road" | "back",
	claim: number, -- studs of its depth that are a core claim behind its plots (0 for none)
	-- Open to a cross street at that end, as the archetype draws it (after the mirror): corner archetypes put their
	-- corner feature at the right (+x) end, and placement mirrors them to the street corner.
	corner: { left: boolean, right: boolean },
	landmark: boolean, -- a one-off (Config/City landmarks)
	skyline: boolean, -- its main masses and crown light go in the always-loaded Skyline model (Config/City skyline)
}

-- One plot of MapBuilder's plot pass (addBuildings), with everything both the city and the old look need.
export type Plot = {
	index: number, -- MapBuilder's building number (stable: the old look's name and random stream use it)
	frontage: string, -- "<edge id>:<side>": plots of one frontage line up edge to edge along the road
	block: number, -- the city block it faces into
	along: number, -- where it starts along its road (studs from the road's first node)
	width: number, -- along the road
	plotDepth: number, -- from the front line back
	frontStart: Vector2, -- its corner on the front line at `along` (plan x, z)
	u: Vector2, -- the road's direction
	away: Vector2, -- unit, from the road into the plot
	zone: string,
	tall: number, -- 0..1, the plot's height roll
	nearSpot: boolean, -- within Config/City nearSpotRange of a gameplay location (its height is capped)
	shade: number, -- the plot's integer roll (its random stream)
	folder: string, -- the block tile model the old look puts it in ("Buildings/Block3")
	cornerStart: boolean?, -- within Config/City rules.cornerReach of its frontage's cut end at its road's start...
	cornerEnd: boolean?, -- ...or at its end (a block corner)
	-- The old look's building (MapBuilder addBuilding): footprint centre, size, height, colour.
	center: Vector2,
	buildingDepth: number,
	buildingWidth: number,
	height: number,
	color: Color3,
}

-- What MapBuilder lends the placement for core claims: a plan rectangle (its centre, the way its road runs, half its
-- length along the road and half its depth across it).
export type Env = {
	-- Whether the rectangle is clear for a claim behind `frontage`'s plots: flat open ground in the map, clear of
	-- everything a plot keeps off (the frontage's own plots excepted) by the plots' clearance.
	clear: (center: Vector2, u: Vector2, halfAlong: number, halfAcross: number, frontage: string) -> boolean,
	-- Takes it for site `owner`: it is paved, and later claims and trees keep off it.
	claim: (center: Vector2, u: Vector2, halfAlong: number, halfAcross: number, owner: string) -> (),
}

-- What an archetype's build() writes into (Dev/City/Kit makes it and adds parts to it).
export type Model = {
	site: Site,
	frame: CFrame,
	mirror: boolean,
	folder: string,
	prefix: string,
	specs: { PartSpec },
	names: { [string]: boolean },
}

-- An archetype module (src/server/Dev/City/Archetypes/<district>/<id>.luau). Its placement, limits and budget are
-- in Config/City archetypes[id].
export type Archetype = {
	id: string,
	build: (m: Model) -> (),
}

return {}
