--!strict
-- The pieces of a street front (Dev/City/Street/Frontage; Config/CityStreet frontage). Pure: each maker returns a
-- PartSpec in world space from corners in the site's own frame (x along the road, y up, z away from the road), never
-- mirrored, and adds nothing; Parts.add files a piece, names it after its site and puts it in the scan. Every piece is
-- scenery (role "scenery", so the site's own checks and budget stay its archetype's) and decor (no collide, raycast or
-- touch), except the one invisible box round a café row. Night lights and signs go in the site's lights model (SLIM
-- breaks on parts that change at runtime), the rest in its own model.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local City = require(ReplicatedStorage.Shared.Config.City)
local CityScenery = require(ReplicatedStorage.Shared.Config.CityScenery)
local CityStreet = require(ReplicatedStorage.Shared.Config.CityStreet)
local Environment = require(ReplicatedStorage.Shared.Config.Environment)
local FrontageScan = require(script.Parent.FrontageScan)
local Kit = require(script.Parent.Parent.Kit)
local MapTypes = require(script.Parent.Parent.Parent.MapTypes)
local Palms = require(script.Parent.Parent.Scenery.Palms)
local Props = require(script.Parent.Parent.Props)
local Types = require(script.Parent.Parent.Types)

type PartSpec = Types.PartSpec
type LabelSpec = MapTypes.LabelSpec
type Site = Types.Site
type Scan = FrontageScan.Scan
type ShopLook = CityStreet.ShopLook
type ShopKind = CityStreet.ShopKind

local F = CityStreet.frontage
local SHOP = F.shop
local TERRACE = F.terrace
local NIGHT_TAG = Environment.nightLights.tag
local QUARTER = math.pi / 2
local INFIX = "Street" -- every piece is named <site id>Street<piece>

export type Maker = {
	site: Site,
	scan: Scan,
	out: { PartSpec },
	names: { [string]: boolean },
}

local Parts = {}

Parts.INFIX = INFIX

function Parts.new(site: Site, scan: Scan): Maker
	return { site = site, scan = scan, out = {}, names = {} }
end

-- Whether a piece is one of the frontage's (by its name and role).
function Parts.owns(spec: PartSpec): boolean
	return spec.role == "scenery" and string.match(spec.name, "^B%d+" .. INFIX) ~= nil
end

-- A plain spec: `shape` at `cf` (site frame) and `size`, decor in its site's model.
local function spec(
	m: Maker,
	name: string,
	shape: "block" | "cylinder" | "ball",
	cf: CFrame,
	size: Vector3,
	color: Color3,
	material: Enum.Material,
	shadow: boolean
): PartSpec
	return {
		folder = m.site.folder,
		name = `{m.site.id}{INFIX}{name}`,
		class = "Part",
		shape = shape,
		role = "scenery",
		size = size,
		cframe = m.site.frame * cf,
		color = color,
		material = material,
		collide = false,
		query = false,
		touch = false,
		shadow = shadow,
		transparency = 0,
	}
end

local function boxSpec(
	m: Maker,
	name: string,
	min: Vector3,
	max: Vector3,
	color: Color3,
	material: Enum.Material,
	shadow: boolean
): PartSpec
	local lo, hi = min:Min(max), min:Max(max)
	return spec(m, name, "block", CFrame.new((lo + hi) / 2), hi - lo, color, material, shadow)
end

-- The piece's box in the site's frame.
function Parts.bounds(m: Maker, piece: PartSpec): (Vector3, Vector3)
	return Kit.localBounds(m.site.frame, piece)
end

-- Whether `piece` fits: inside the site's footprint and height, and clear of every part there (with `wall`, the parts
-- wholly behind that plane don't count: a piece set into the wall). A templated piece's stand-in parts are inside its
-- box, so the box answers for them.
function Parts.fits(m: Maker, piece: PartSpec, wall: number?): boolean
	local lo, hi = Parts.bounds(m, piece)
	return FrontageScan.inside(m.scan, lo, hi, m.site.maxHeight) and FrontageScan.free(m.scan, lo, hi, wall)
end

-- Files `piece` (a night light, a sign or a light in the site's lights model) and puts it in the scan. Errors on a
-- name used twice.
function Parts.add(m: Maker, piece: PartSpec)
	if m.names[piece.name] then
		error(`Frontage: two pieces named {piece.name}`, 2)
	end
	m.names[piece.name] = true
	if piece.tag == NIGHT_TAG or piece.labels ~= nil or piece.light ~= nil then
		piece.folder = m.site.lightsFolder
	end
	table.insert(m.out, piece)
	FrontageScan.add(m.scan, piece)
end

---------------------------------------------------------------------------------------------------------------
-- Shop fronts
---------------------------------------------------------------------------------------------------------------

-- A shop window from min to max: glass under the city's bold frame overlay (a stall riser, a transom, mullions every
-- pane), lit at night in the trade's colour.
function Parts.window(m: Maker, name: string, min: Vector3, max: Vector3, look: ShopLook, kind: ShopKind): PartSpec
	local w = SHOP.window
	local piece = boxSpec(m, name, min, max, w.glass, Enum.Material.Glass, false)
	piece.reflectance = w.reflectance
	local wide = math.abs(max.X - min.X)
	local panes = math.max(1, math.round(wide / w.pane))
	piece.textures = {
		{
			face = Enum.NormalId.Front,
			image = City.textures.windowBold,
			u = wide / panes,
			v = math.abs(max.Y - min.Y),
			color = look.frame,
		},
	}
	return Kit.lit(piece, "window", kind.interior)
end

-- An awning over x0..x1 on the wall at z, its top edge `high` over `floor`, reaching `depth` out: a sloped fabric
-- (with white stripes when striped) or a flat canopy, in the look's colour.
function Parts.awning(
	m: Maker,
	name: string,
	x0: number,
	x1: number,
	z: number,
	floor: number,
	depth: number,
	look: ShopLook
): PartSpec
	local a = SHOP.awning
	local wide = x1 - x0
	local cx = (x0 + x1) / 2
	if look.cut == "flat" then
		local flatDepth = math.min(depth, a.flat.depth)
		return boxSpec(
			m,
			name,
			Vector3.new(x0, floor + a.flat.y, z - flatDepth),
			Vector3.new(x1, floor + a.flat.y + a.flat.thick, z + 0.05),
			look.awning,
			Enum.Material.SmoothPlastic,
			true
		)
	end
	-- A slab tilted about x: its top runs from the front edge (low) up to the wall (high), and on into the wall a
	-- little so no gap shows.
	local tilt = math.atan2(a.drop, depth)
	local long = math.sqrt(depth * depth + a.drop * a.drop) + 0.1
	local up = Vector3.new(0, math.cos(tilt), -math.sin(tilt)) -- the slab's own up, turned
	local topMid = Vector3.new(cx, floor + a.high - a.drop / 2, z - depth / 2)
	local centre = topMid - up * (a.thick / 2)
	local piece = spec(
		m,
		name,
		"block",
		CFrame.new(centre) * CFrame.Angles(-tilt, 0, 0),
		Vector3.new(wide, a.thick, long),
		look.awning,
		Enum.Material.SmoothPlastic,
		true
	)
	if look.cut == "striped" then
		piece.textures = {
			{ face = Enum.NormalId.Top, image = a.stripes, u = a.stripeTile, v = long, color = a.stripeColor },
		}
	end
	return piece
end

local function label(face: Enum.NormalId, text: string, look: ShopLook, kind: ShopKind, size: Vector2?): LabelSpec
	return {
		face = face,
		text = text,
		color = look.letters,
		font = kind.font,
		size = size or Vector2.new(0.92, 0.8),
		pixelsPerStud = City.kit.signPixelsPerStud,
	}
end

-- A fascia board over a shop (x0..x1), on the wall at z, with its name. Not a night light: its letters stay bright on
-- their own (a sign's SurfaceGui ignores the light).
function Parts.fascia(
	m: Maker,
	name: string,
	x0: number,
	x1: number,
	z: number,
	floor: number,
	text: string,
	look: ShopLook,
	kind: ShopKind
): PartSpec
	local f = SHOP.fascia
	local room = x1 - x0 - 2 * f.inset
	local wide = math.clamp(#text * f.perChar, math.min(f.min, room), room)
	local cx = (x0 + x1) / 2
	local piece = boxSpec(
		m,
		name,
		Vector3.new(cx - wide / 2, floor + f.low, z - f.thick),
		Vector3.new(cx + wide / 2, floor + f.high, z + 0.05),
		look.board,
		Enum.Material.SmoothPlastic,
		false
	)
	piece.labels = { label(Enum.NormalId.Front, text, look, kind) }
	return piece
end

-- A blade sign standing out from the wall at z, centred on x: a tall board with `word` stacked letter over letter on
-- both faces (big enough to read from across the road); it glows in the look's neon at night.
function Parts.blade(
	m: Maker,
	name: string,
	x: number,
	z: number,
	floor: number,
	word: string,
	look: ShopLook,
	kind: ShopKind
): PartSpec
	local b = SHOP.blade
	local piece = boxSpec(
		m,
		name,
		Vector3.new(x - b.thick / 2, floor + b.low, z - b.out),
		Vector3.new(x + b.thick / 2, floor + b.high, z - b.back),
		look.board,
		Enum.Material.SmoothPlastic,
		false
	)
	local letters: { string } = {}
	for _, code in utf8.codes(word) do
		table.insert(letters, utf8.char(code))
	end
	local stacked = table.concat(letters, "\n")
	local size = Vector2.new(0.9, 0.96)
	piece.labels = {
		label(Enum.NormalId.Left, stacked, look, kind, size),
		label(Enum.NormalId.Right, stacked, look, kind, size),
	}
	return Kit.lit(piece, look.neon)
end

---------------------------------------------------------------------------------------------------------------
-- Planters, café rows, string lights
---------------------------------------------------------------------------------------------------------------

-- A planter standing on `floor` at (x, z), its box `size`: the box and a clump of palmetto in it (the clump is cloned
-- from its template like the palms: Config/CityScenery furniture.planter.plant). Two pieces.
function Parts.planter(
	m: Maker,
	name: string,
	x: number,
	z: number,
	floor: number,
	size: Vector3,
	plant: number,
	color: Color3
): (PartSpec, PartSpec)
	local box = boxSpec(
		m,
		name,
		Vector3.new(x - size.X / 2, floor, z - size.Z / 2),
		Vector3.new(x + size.X / 2, floor + size.Y, z + size.Z / 2),
		color,
		Enum.Material.Concrete,
		true
	)
	-- The clump sits a little down in the box, turned its own way (from where it stands, so a rebuild turns it alike).
	local foot = m.site.frame * Vector3.new(x, floor + size.Y - 0.2, z)
	local clump = Palms.plant(
		m.site.folder,
		`{m.site.id}{INFIX}{name}Plant`,
		CityScenery.furniture.planter.plant,
		foot,
		(foot.X * 0.37 + foot.Z * 0.11) % (2 * math.pi),
		plant,
		math.min(size.X, size.Z) + 0.6
	)
	return box, clump
end

-- A café set or bistro pair (Config/CityProps `prop`) standing on `floor` at (x, z), turned as the site (its front to
-- the street). One templated piece: the build clones the prop's mesh there, or its stand-in.
function Parts.prop(m: Maker, name: string, prop: string, x: number, z: number, floor: number): PartSpec
	local size = Props.catalog[prop].size
	local cf = m.site.frame * CFrame.new(x, floor + size.Y / 2, z)
	return Props.spec(m.site.folder, `{m.site.id}{INFIX}{name}`, prop, cf, size, "scenery")
end

-- The invisible box round a row of tables, min..max: the one solid piece (a car or a player bumps into it; the meshes
-- collide with nothing).
function Parts.collider(m: Maker, name: string, min: Vector3, max: Vector3): PartSpec
	local piece = boxSpec(m, name, min, max, Color3.fromRGB(200, 200, 200), Enum.Material.SmoothPlastic, false)
	piece.transparency = 1
	piece.collide = true
	return piece
end

-- A string-light post standing on `floor` at (x, z), `top` tall.
function Parts.post(m: Maker, name: string, x: number, z: number, floor: number, top: number): PartSpec
	local l = TERRACE.lights
	return spec(
		m,
		name,
		"cylinder",
		CFrame.new(x, floor + top / 2, z) * CFrame.Angles(0, 0, QUARTER),
		Vector3.new(top, l.post, l.post),
		l.postColor,
		Enum.Material.Metal,
		false
	)
end

-- A string of lights from a to b (site frame): a dark cable by day, warm bulbs glowing at night.
function Parts.string(m: Maker, name: string, a: Vector3, b: Vector3): PartSpec
	local l = TERRACE.lights
	local mid = (a + b) / 2
	-- A cylinder's axis is its x: look along the string, then turn x onto the look.
	local cf = CFrame.lookAt(mid, b) * CFrame.Angles(0, QUARTER, 0)
	local piece = spec(
		m,
		name,
		"cylinder",
		cf,
		Vector3.new((b - a).Magnitude, l.wire, l.wire),
		l.cable,
		Enum.Material.SmoothPlastic,
		false
	)
	return Kit.lit(piece, l.kind)
end

return Parts
