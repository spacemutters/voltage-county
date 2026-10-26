--!strict
-- The scenery planner's data shapes (Dev/City/Scenery): what Dev/MapBuilder hands it (the Host: the roads as they were
-- built, the placement grid's checks and a way to add parts) and the plan rectangles it checks with. Kept apart from
-- MapBuilder so the scenery modules never require it (MapBuilder requires them).

local MapTypes = require(script.Parent.Parent.Parent.MapTypes)

export type PartSpec = MapTypes.PartSpec
export type Role = MapTypes.Role
export type TemplateSpec = MapTypes.TemplateSpec
export type TextureSpec = MapTypes.TextureSpec

-- A plan rectangle (x, z) as Dev/MapBuilder's grid takes it: its centre, the unit direction of its long axis `u`, and
-- its half sizes along `u` (ha) and across it (hc).
export type Rect = { c: Vector2, u: Vector2, ha: number, hc: number }

-- One built road edge: from its `from` node (plan `a`) along `u` for `length` studs, `half` studs wide each side of
-- its centre line, with `sidewalk` studs of sidewalk each side (0 for none). Its slab runs between the cut-backs
-- trimFrom and trimTo; `surface` is its top's height `along` studs from `a`. fromRoads and toRoads count the roads
-- at each end node (3 or more is a junction with a pad).
export type Street = {
	id: number,
	name: string,
	kind: string,
	fromZone: string,
	toZone: string,
	a: Vector2,
	u: Vector2,
	l: Vector2, -- the right-hand normal: lateral + is toward +l
	length: number,
	half: number,
	sidewalk: number,
	trimFrom: number,
	trimTo: number,
	fromRoads: number,
	toRoads: number,
	surface: (along: number) -> number,
}

export type Lake = { id: string, min: Vector2, max: Vector2, waterY: number, bedY: number }
export type Park = { id: string, min: Vector2, max: Vector2, hole: { min: Vector2, max: Vector2 }? }

-- Parts a group of scenery may still add (Dev/City/Scenery Piece.take spends from it).
export type Ledger = { used: number, limit: number }

-- What Dev/MapBuilder gives the planner.
export type Host = {
	seed: number,
	half: number, -- the map's half extent
	sidewalkRaise: number, -- a sidewalk's top stands this far above its road's surface
	lineLift: number, -- paint floats this far above a road's top
	streets: { Street },
	lakes: { Lake },
	parks: { Park },
	groundAt: (x: number, z: number) -> number,
	-- True when `rect` overlaps (deeper than `tolerance`) something of one of `kinds` in the placement grid
	-- (Dev/MapBuilder's kinds: road, sidewalk, driveway, support, lake, landmark, location, access, prop, light, lamp,
	-- lot, park, tree, feature, ramp, mesa, plus the scenery's own "streetscape").
	blocked: (rect: Rect, kinds: { [string]: boolean }, tolerance: number) -> boolean,
	reserve: (rect: Rect, kind: string) -> (), -- puts a rectangle into the grid as `kind`
	add: (spec: PartSpec) -> (),
	-- `lod` is the Model's LevelOfDetail name ("SLIM" for still scenery, "Disabled" for its lights; Dev/MapTypes).
	container: (path: string, class: "Folder" | "Model", streaming: Enum.ModelStreamingMode?, lod: string?) -> (),
	note: (text: string) -> (),
}

return {}
