--!strict
-- The part specs Dev/MapBuilder plans and builds, in their own module so the city builder (Dev/City) can make them
-- too without requiring MapBuilder (which requires the city builder). MapBuilder re-exports every type here, so
-- `MapBuilder.PartSpec` keeps working for its specs and for Dev/MapCheck.

-- What a part is for. Specs and MapCheck group parts by it.
export type Role =
	"road" -- a road segment slab (Roads/Segments)
	| "pad" -- a junction pad piece (Roads/Intersections)
	| "line" -- paint
	| "sidewalk"
	| "ground"
	| "water"
	| "ramp" -- a jump ramp
	| "lot"
	| "building"
	| "landmark"
	| "light" -- streetlight post or head
	| "support" -- bridge railings, pillars and fill
	| "location" -- a MapLayout location's tagged part
	| "prop" -- small things on a location
	| "spawn"
	| "displayPad" -- a dealership or used-lot display platform
	| "sign" -- a dealership brand sign (post and board)
	| "billboard" -- a billboard's panel or one of its posts (Phase 12)
	| "tree" -- a tree's trunk or one of its leaf blocks
	| "feature" -- a part of a MapLayout feature (water tower, diner, bridge arches)
	| "scenery" -- the city's street furniture, street palms, beach dressing and lifeguard stands (Dev/City/Scenery)

-- A part the build fills from a template in ServerStorage (Dev/City/Scenery: the palm meshes). The spec itself
-- stands for the space the template fills (its box, for the plan's checks); the build clones the template at `pivot`
-- (the trunk's foot on the ground), turned and scaled so it stands `height` studs tall, and builds the parts-only
-- stand-in `fallback` names instead when the template is missing.
export type TemplateSpec = {
	path: { string }, -- below ServerStorage: { "CityAssets", "Palms", "royal" }
	pivot: CFrame,
	height: number,
	variant: number, -- 1..n: which child when the template is a folder of variants
	fallback: string, -- the stand-in's shape (Dev/City/Scenery Palms species)
	-- Optional, for props (Dev/City/Street): the parts the build puts up while the template is missing, instead of a
	-- palm species' stand-in (still marked a stand-in, so Dev/MapCheck fails until the template is back).
	standIn: { PartSpec }?,
	-- Optional: stand the clone by its box, the bottom centre of its bounding box on `pivot`, whatever pivot the template
	-- was saved with (a generated prop's pivot is often its middle).
	seat: boolean?,
	-- Optional, with `seat`: never wider or deeper than the spec's box either (scaled down to fit it, keeping its
	-- proportions), for a prop whose mesh could reach past the space the plan checked (Config/CityProps contain).
	contain: boolean?,
}

-- Text painted on one face of a part (a SurfaceGui with one TextLabel). `center` and `size` are fractions of the
-- face (defaults: centred, MapBuilder TUNING.labelSize); `pixelsPerStud` defaults to TUNING.labelPixelsPerStud (big
-- signs use fewer, so their SurfaceGui stays a sensible size); `font` defaults to TUNING.labelFont.
export type LabelSpec = {
	face: Enum.NormalId,
	text: string,
	color: Color3,
	center: Vector2?,
	size: Vector2?,
	pixelsPerStud: number?,
	font: Enum.Font?,
}

-- An AdGui on one face of a part (a billboard's ad unit; Config/Ads). Built switched off: Services/AdsService turns it
-- on at runtime only when ads may be served. `fallbackImage` "" leaves Roblox's default.
export type AdUnitSpec = { name: string, face: Enum.NormalId, enableVideoAds: boolean, fallbackImage: string }

-- `enabled` false builds the Light switched off (a night light's: Services/DayNightService switches it on at dusk).
-- A "surface" light is a SurfaceLight on `face` (a facade wash: Dev/City Kit.wash); `angle` is its spread.
export type LightSpec = {
	kind: "point" | "spot" | "surface",
	brightness: number,
	range: number,
	angle: number,
	color: Color3,
	face: Enum.NormalId,
	enabled: boolean?,
}

-- An image tiled over one face of a part (a Texture): the city's window grids and slab lines (Config/City
-- textures). `u` and `v` are studs per tile across and up the face; `offsetU`/`offsetV` shift the tiles;
-- `transparency` 0..1 on top of the image's own alpha.
export type TextureSpec = {
	face: Enum.NormalId,
	image: string,
	u: number,
	v: number,
	offsetU: number?,
	offsetV: number?,
	color: Color3,
	transparency: number?,
}

-- One part of the build. `folder` is the container path below Generated ("Roads/Segments"); every container on
-- it is listed in Plan.containers. A part with `parent` set is parented to the part of that name in `folder`
-- (location props hang under their location part). `reflectance` (0 when nil) and `textures` are for the city's
-- glass; a "ball" is a Part with Shape Ball (its three sizes equal). `materialVariant` names a MaterialVariant on the
-- part's material (a part whose variant isn't in MaterialService shows its plain material). With `template` the build
-- clones a template in its place (TemplateSpec above).
export type PartSpec = {
	folder: string,
	parent: string?,
	name: string,
	class: "Part" | "WedgePart" | "CornerWedgePart" | "SpawnLocation",
	shape: "block" | "wedge" | "cornerWedge" | "cylinder" | "ball",
	role: Role,
	size: Vector3,
	cframe: CFrame,
	color: Color3,
	material: Enum.Material,
	collide: boolean,
	query: boolean,
	touch: boolean,
	shadow: boolean,
	transparency: number,
	reflectance: number?,
	tag: string?,
	attributes: { [string]: any }?,
	light: LightSpec?,
	labels: { LabelSpec }?,
	adUnit: AdUnitSpec?,
	textures: { TextureSpec }?,
	materialVariant: string?,
	template: TemplateSpec?,
}

-- A folder or model below Generated. `lod` names the Model's LevelOfDetail (an Enum.ModelLevelOfDetail item: "SLIM"
-- for a city site's still parts, "Disabled" for its lights model; docs/city/TECH.md §6), set by MapBuilder.build when
-- this Studio knows it.
export type Container = {
	path: string,
	class: "Folder" | "Model",
	streaming: Enum.ModelStreamingMode?,
	lod: string?,
}

return {}
