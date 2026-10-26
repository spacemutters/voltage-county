--!strict
-- The city builder's data shapes (docs/city/ARCHETYPE_GUIDE.md): a plot from MapBuilder's plot pass, a site the
-- placement makes of one or more plots, the model an archetype writes its parts into, and an archetype module.

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
-- toward the road: the front line is z = -depth/2 and the back z = +depth/2, the sides x = ±width/2. Every part
-- must stay inside that footprint, between y = -kit.bury and y = maxHeight.
export type Site = {
	id: string, -- "B<index>" of its first plot: every part's name starts with it
	archetype: string,
	district: string,
	zone: string,
	frame: CFrame,
	width: number,
	depth: number,
	height: number, -- the main roof
	maxHeight: number, -- crowns, spires, signs and flagpoles included
	seed: number, -- its own random stream (Kit.rng)
	variant: Variant,
	folder: string, -- the container its parts go in (below Workspace.Map.Generated)
	plots: { number }, -- the plots it stands on (MapBuilder's building numbers)
	block: number, -- the city block (MapBuilder's findBlocks face) it stands in
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
	-- The old look's building (MapBuilder addBuilding): footprint centre, size, height, colour.
	center: Vector2,
	buildingDepth: number,
	buildingWidth: number,
	height: number,
	color: Color3,
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
