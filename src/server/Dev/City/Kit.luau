--!strict
-- The city's building kit (docs/city/ARCHETYPE_GUIDE.md; CITY_PLAN §8.4; TECH §2 and §5). Pure: every helper adds
-- MapBuilder PartSpecs to a Model and returns them. It never makes instances.
--
-- Coordinates are the site's own, in studs: x along the road (±width/2), y up from the ground, z away from the road
-- (the front line is z = -depth/2, the back z = +depth/2). A part's Front face (-Z) faces the road. Boxes are given by
-- two corners (min, max); the kit turns them into the site's frame and mirrors x when the site's variant says so,
-- so an archetype draws one handedness and gets both.
--
-- Three kinds of part, by what a car and the light do with them:
--   box     a solid mass: collides, takes raycasts, casts a shadow (walls, slabs a car could hit, podiums)
--   trim    decor that casts a shadow: eyebrows, fins, slab edges, cornices. Their shadow lines are the look
--   detail  decor with no shadow: mullions, rails, neon, signs, small trim (no collide, raycast or touch)
-- Sharpness rules (CITY_PLAN §8.4): nothing coplanar (anything laid on a face stands at least kit.minProud proud),
-- glass set in from its frame, every building a plinth, an entrance and one readable silhouette idea.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local City = require(ReplicatedStorage.Shared.Config.City)
local Environment = require(ReplicatedStorage.Shared.Config.Environment)
local Types = require(script.Parent.Types)

type PartSpec = Types.PartSpec
type TextureSpec = Types.TextureSpec
type Model = Types.Model
type Site = Types.Site

export type Look = { color: Color3, material: Enum.Material, reflectance: number?, transparency: number? }
export type Kind = "box" | "trim" | "detail"
export type Side = "front" | "back" | "left" | "right"
-- Which corners of a box are rounded: front-left (-x, -z), front-right (+x, -z), back-left, back-right.
export type Corners = { fl: boolean?, fr: boolean?, bl: boolean?, br: boolean? }
-- Glass options: an overlay image on some faces (default the four walls), tile size, its line colour, and whether it
-- is a run of windows that glows at night (Config/Environment nightLights "window").
export type GlassOptions = {
	image: string?,
	faces: { Enum.NormalId }?,
	u: number?,
	v: number?,
	offsetV: number?,
	lines: Color3?,
	lit: boolean?,
	reflectance: number?,
}

local KIT = City.kit
local NIGHT = Environment.nightLights
local EPS = 1e-6
local QUARTER = math.pi / 2

local Kit = {}
Kit.KIT = KIT

---------------------------------------------------------------------------------------------------------------
-- Looks and models
---------------------------------------------------------------------------------------------------------------

function Kit.look(color: Color3, material: Enum.Material, reflectance: number?, transparency: number?): Look
	return { color = color, material = material, reflectance = reflectance, transparency = transparency }
end

-- Tower glass: Glass, opaque, mirroring the sky.
function Kit.glassLook(color: Color3, reflectance: number?): Look
	return Kit.look(color, Enum.Material.Glass, reflectance or KIT.glassReflectance, 0)
end

-- A model to build `site` into.
function Kit.model(site: Site): Model
	return {
		site = site,
		frame = site.frame,
		mirror = site.variant.mirror,
		folder = site.folder,
		prefix = site.id,
		specs = {},
		names = {},
	}
end

-- A seed from a part's name and its site's seed (a stable pick per part, whatever order the parts are made in).
local function nameSeed(name: string, seed: number): number
	local h = seed % 2147483647
	for i = 1, #name do
		h = (h * 31 + string.byte(name, i)) % 2147483647
	end
	return h
end

-- The site's own random stream, salted so two helpers in one archetype don't share numbers.
function Kit.rng(m: Model, salt: number?): Random
	return Random.new((m.site.seed + (salt or 0) * 7919) % 2147483647)
end

-- How many floors of `floor` studs fit in `height` (at least 1).
function Kit.floors(height: number, floor: number): number
	return math.max(1, math.floor(height / floor + 1e-6))
end

---------------------------------------------------------------------------------------------------------------
-- Placing parts
---------------------------------------------------------------------------------------------------------------

local function mx(m: Model, x: number): number
	return if m.mirror then -x else x
end

-- A face named in the site's (unmirrored) terms, as the part sees it once mirrored.
function Kit.face(m: Model, face: Enum.NormalId): Enum.NormalId
	if m.mirror then
		if face == Enum.NormalId.Left then
			return Enum.NormalId.Right
		elseif face == Enum.NormalId.Right then
			return Enum.NormalId.Left
		end
	end
	return face
end

local function flags(spec: PartSpec, kind: Kind, size: Vector3)
	if kind == "box" then
		spec.collide, spec.query, spec.touch, spec.shadow = true, true, false, true
	else
		spec.collide, spec.query, spec.touch = false, false, false
		-- Trim casts a shadow unless it is a sliver (thin both ways across its length).
		local dims = { size.X, size.Y, size.Z }
		table.sort(dims)
		spec.shadow = kind == "trim" and dims[2] >= KIT.trimShadowMin
	end
end

-- The raw helper every other one uses: a part of `shape` at local `cf` (already mirrored) and `size`.
function Kit.part(
	m: Model,
	name: string,
	shape: "block" | "wedge" | "cornerWedge" | "cylinder" | "ball",
	cf: CFrame,
	size: Vector3,
	look: Look,
	kind: Kind
): PartSpec
	local full = m.prefix .. name
	if m.names[full] then
		error(`Kit: two parts named {full}`, 2)
	end
	if size.X <= 0 or size.Y <= 0 or size.Z <= 0 then
		error(`Kit: {full} has size {size}`, 2)
	end
	m.names[full] = true
	-- A pale or pastel wall in SmoothPlastic is stucco: Plaster, which doesn't mirror the blue sky the way smooth
	-- plastic does (roast 2026-10-26 point 5: white walls read baby blue). Trim and details keep their smooth finish.
	local material = look.material
	if kind == "box" and material == Enum.Material.SmoothPlastic and (look.transparency or 0) == 0 then
		local c = look.color
		if math.min(c.R, c.G, c.B) >= KIT.stuccoMin and math.max(c.R, c.G, c.B) >= KIT.stuccoBright then
			material = Enum.Material.Plaster
		end
	end
	local class: "Part" | "WedgePart" | "CornerWedgePart" = if shape == "wedge"
		then "WedgePart"
		elseif shape == "cornerWedge" then "CornerWedgePart"
		else "Part"
	local spec: PartSpec = {
		folder = m.folder,
		name = full,
		class = class,
		shape = shape,
		role = "building",
		size = size,
		cframe = m.frame * cf,
		color = look.color,
		material = material,
		collide = true,
		query = true,
		touch = false,
		shadow = true,
		transparency = look.transparency or 0,
		reflectance = look.reflectance,
	}
	flags(spec, kind, size)
	table.insert(m.specs, spec)
	return spec
end

local function boxAt(m: Model, name: string, min: Vector3, max: Vector3, look: Look, kind: Kind): PartSpec
	local lo, hi = min:Min(max), min:Max(max)
	local c = (lo + hi) / 2
	return Kit.part(m, name, "block", CFrame.new(mx(m, c.X), c.Y, c.Z), hi - lo, look, kind)
end

-- A solid mass between two corners.
function Kit.box(m: Model, name: string, min: Vector3, max: Vector3, look: Look): PartSpec
	return boxAt(m, name, min, max, look, "box")
end

-- Decor that casts a shadow (eyebrows, fins, slab edges, cornices).
function Kit.trim(m: Model, name: string, min: Vector3, max: Vector3, look: Look): PartSpec
	return boxAt(m, name, min, max, look, "trim")
end

-- Decor with no shadow (mullions, rails, small trim).
function Kit.detail(m: Model, name: string, min: Vector3, max: Vector3, look: Look): PartSpec
	return boxAt(m, name, min, max, look, "detail")
end

-- A vertical cylinder standing at (x, z) from y0 to y1: drums, round columns, round towers; a thin one is a disc
-- (an eyebrow round a rounded corner, a round slab, a pool).
function Kit.column(
	m: Model,
	name: string,
	x: number,
	z: number,
	y0: number,
	y1: number,
	diameter: number,
	look: Look,
	kind: Kind?
): PartSpec
	local cf = CFrame.new(mx(m, x), (y0 + y1) / 2, z) * CFrame.Angles(0, 0, QUARTER)
	return Kit.part(m, name, "cylinder", cf, Vector3.new(math.abs(y1 - y0), diameter, diameter), look, kind or "box")
end

-- A horizontal disc of `thickness` centred at height y.
function Kit.disc(
	m: Model,
	name: string,
	x: number,
	z: number,
	y: number,
	diameter: number,
	thickness: number,
	look: Look,
	kind: Kind?
): PartSpec
	return Kit.column(m, name, x, z, y - thickness / 2, y + thickness / 2, diameter, look, kind or "trim")
end

-- A cylinder from a to b along one axis (x, y or z): neon tubes, rails, poles, porthole discs.
function Kit.tube(m: Model, name: string, a: Vector3, b: Vector3, diameter: number, look: Look, kind: Kind?): PartSpec
	local d = b - a
	local length = d.Magnitude
	local c = (a + b) / 2
	local turn: CFrame
	if math.abs(d.Y) >= math.abs(d.X) and math.abs(d.Y) >= math.abs(d.Z) then
		turn = CFrame.Angles(0, 0, QUARTER)
	elseif math.abs(d.Z) >= math.abs(d.X) then
		turn = CFrame.Angles(0, QUARTER, 0)
	else
		turn = CFrame.identity
	end
	return Kit.part(
		m,
		name,
		"cylinder",
		CFrame.new(mx(m, c.X), c.Y, c.Z) * turn,
		Vector3.new(length, diameter, diameter),
		look,
		kind or "detail"
	)
end

-- A ball (a finial, a beacon, a dome sunk into its drum).
function Kit.ball(m: Model, name: string, center: Vector3, diameter: number, look: Look, kind: Kind?): PartSpec
	return Kit.part(
		m,
		name,
		"ball",
		CFrame.new(mx(m, center.X), center.Y, center.Z),
		Vector3.one * diameter,
		look,
		kind or "detail"
	)
end

local RISE_TURN: { [Side]: number } = { back = 0, front = math.pi, right = QUARTER, left = -QUARTER }

-- A wedge filling the box min..max, its slope rising toward `rise` (its high edge on that side): sloped roofs,
-- chamfers, raked fin tops, the steps of a sawtooth.
function Kit.wedge(m: Model, name: string, min: Vector3, max: Vector3, rise: Side, look: Look, kind: Kind?): PartSpec
	local lo, hi = min:Min(max), min:Max(max)
	local c = (lo + hi) / 2
	local s = hi - lo
	local side: Side = rise
	if m.mirror and rise == "left" then
		side = "right"
	elseif m.mirror and rise == "right" then
		side = "left"
	end
	local across = side == "left" or side == "right"
	local size = if across then Vector3.new(s.Z, s.Y, s.X) else s
	local cf = CFrame.new(mx(m, c.X), c.Y, c.Z) * CFrame.Angles(0, RISE_TURN[side], 0)
	return Kit.part(m, name, "wedge", cf, size, look, kind or "box")
end

-- A part turned any way: `cf` is in the site's own (unmirrored) coordinates and the kit mirrors it when the site is
-- mirrored. For shapes the axis-aligned helpers can't make: a box turned in plan (an octagon's bands, an oval's facets,
-- a lightning bolt on a roof), a slab tilted both ways (folded roof plates), a ring of segments standing up (a wheel's
-- rim). Blocks, wedges, cylinders and balls only: each is its own mirror image across its local x, so the mirrored
-- part is the same shape.
function Kit.oriented(
	m: Model,
	name: string,
	shape: "block" | "wedge" | "cylinder" | "ball",
	cf: CFrame,
	size: Vector3,
	look: Look,
	kind: Kind?
): PartSpec
	local placed = cf
	if m.mirror then
		local x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22 = cf:GetComponents()
		placed = CFrame.new(-x, y, z, r00, -r01, -r02, -r10, r11, r12, -r20, r21, r22)
	end
	return Kit.part(m, name, shape, placed, size, look, kind or "box")
end

-- A square bar from a to b, `thick` across (`wide` across its local x when given): slanted columns, legs, struts,
-- spokes, a stair's stringer. 1 part.
function Kit.strut(
	m: Model,
	name: string,
	a: Vector3,
	b: Vector3,
	thick: number,
	look: Look,
	kind: Kind?,
	wide: number?
): PartSpec
	local d = b - a
	local along = d.Unit
	local right = along:Cross(if math.abs(along.Y) > 0.98 then Vector3.zAxis else Vector3.yAxis).Unit
	local cf = CFrame.fromMatrix((a + b) / 2, right, right:Cross(along), -along)
	return Kit.oriented(m, name, "block", cf, Vector3.new(wide or thick, thick, d.Magnitude), look, kind)
end

-- A regular octagonal prism standing at (x, z) from y0 to y1, `across` its flats (cupolas, lighthouse stages, drums,
-- string courses round them). Four boxes as wide as one side, turned 0, 45, 90 and 135 degrees: together they fill
-- the octagon exactly. Their tops and bottoms are set a hair apart so no two faces are coplanar. 4 parts.
function Kit.octagon(
	m: Model,
	name: string,
	x: number,
	z: number,
	y0: number,
	y1: number,
	across: number,
	look: Look,
	kind: Kind?
): { PartSpec }
	local side = across * math.tan(math.pi / 8)
	local hair = 0.02
	local out: { PartSpec } = {}
	for k = 0, 3 do
		local lo, hi = y0 + k * hair, y1 - k * hair
		local cf = CFrame.new(x, (lo + hi) / 2, z) * CFrame.Angles(0, k * math.pi / 4, 0)
		table.insert(out, Kit.oriented(m, `{name}{k + 1}`, "block", cf, Vector3.new(across, hi - lo, side), look, kind))
	end
	return out
end

-- The right-angle corner of a Kit.triangle: the corner of its rectangle (x0..x1, y0..y1) it sits in.
export type TriangleCorner = "x0y0" | "x1y0" | "x0y1" | "x1y1"
-- A WedgePart laid flat against a front face: its triangle faces the street, its right angle at x1y0.
local FLAT = CFrame.Angles(0, QUARTER, 0)
local TRIANGLE_TURN: { [TriangleCorner]: number } = { x1y0 = 0, x1y1 = QUARTER, x0y1 = math.pi, x0y0 = -QUARTER }

-- A flat right-angled triangle on a front face: the half of the rectangle x0..x1, y0..y1 (x along the road, y up)
-- with its right angle at `corner`, `thick` deep from the plane z back (its face toward the street is at z). Two of
-- them make any triangle with a level base. `tilt` (radians) turns it about its long edge, so its right-angle corner
-- stands out toward the street (positive) or sinks back (negative): faceted metal skins, folded panels. Mural
-- triangles, chevrons and peaks. 1 part (a WedgePart).
function Kit.triangle(
	m: Model,
	name: string,
	x0: number,
	y0: number,
	x1: number,
	y1: number,
	z: number,
	thick: number,
	corner: TriangleCorner,
	look: Look,
	kind: Kind?,
	tilt: number?
): PartSpec
	local lx, hx = math.min(x0, x1), math.max(x0, x1)
	local ly, hy = math.min(y0, y1), math.max(y0, y1)
	local w, h = hx - lx, hy - ly
	local level = corner == "x1y0" or corner == "x0y1" -- turned 0 or 180: the wedge's own z runs along x
	local size = if level then Vector3.new(thick, h, w) else Vector3.new(thick, w, h)
	local centre = Vector3.new((lx + hx) / 2, (ly + hy) / 2, z + thick / 2)
	local rotation = CFrame.Angles(0, 0, TRIANGLE_TURN[corner]) * FLAT
	local t = tilt or 0
	if t ~= 0 then
		-- The long edge joins the two corners other than the right angle (cx, cy); the corner moves along z by
		-- (axis x q).Z * sin(angle), so the angle's sign is picked to send it toward the street for a positive tilt.
		local cx = if corner == "x0y0" or corner == "x0y1" then lx else hx
		local cy = if corner == "x0y0" or corner == "x1y0" then ly else hy
		local ox, oy = lx + hx - cx, ly + hy - cy
		local axis = Vector3.new(ox - cx, cy - oy, 0).Unit
		local q = Vector3.new(cx - centre.X, cy - centre.Y, 0)
		local angle = if axis:Cross(q).Z > 0 then -t else t
		rotation = CFrame.fromAxisAngle(axis, angle) * rotation
	end
	return Kit.oriented(m, name, "wedge", CFrame.new(centre) * rotation, size, look, kind or "detail")
end

-- The right-angle corner of a Kit.prism, in plan: front-left (-x, -z), front-right, back-left or back-right.
export type PrismCorner = "fl" | "fr" | "bl" | "br"
-- A WedgePart stood on its side (its own x turned up) has its square corner at the back-right; this turn about y takes
-- that corner to each of the four, and says whether the plan's two extents swap.
local PRISM_TURN: { [PrismCorner]: { angle: number, swap: boolean } } = {
	br = { angle = 0, swap = false },
	fr = { angle = QUARTER, swap = true },
	fl = { angle = math.pi, swap = false },
	bl = { angle = -QUARTER, swap = true },
}

-- A standing prism that is a right-angled triangle in plan: the half of the box min..max on one side of its plan
-- diagonal, its right angle at `corner`, its sloped face looking toward the opposite corner, from min.Y up to max.Y.
-- Three-cornered towers (two of them back to back), V-notches, raked corners, triangular balconies (a thin one).
-- 1 part (a WedgePart).
function Kit.prism(
	m: Model,
	name: string,
	min: Vector3,
	max: Vector3,
	corner: PrismCorner,
	look: Look,
	kind: Kind?
): PartSpec
	local lo, hi = min:Min(max), min:Max(max)
	local s = hi - lo
	local turn = PRISM_TURN[corner]
	local size = if turn.swap then Vector3.new(s.Y, s.Z, s.X) else Vector3.new(s.Y, s.X, s.Z)
	local cf = CFrame.new((lo + hi) / 2) * CFrame.Angles(0, turn.angle, 0) * CFrame.Angles(0, 0, QUARTER)
	return Kit.oriented(m, name, "wedge", cf, size, look, kind)
end

---------------------------------------------------------------------------------------------------------------
-- Night lights
---------------------------------------------------------------------------------------------------------------

-- Makes a part a night light of `kind` (Config/Environment nightLights): tagged, with its kind and day colour, in its
-- kind's day look, any Light in it switched off. Services/DayNightService switches it at dusk and dawn. `nightColor`,
-- when given, is this part's own night colour (its NightColor attribute): it beats the kind's, for a gradient rib by
-- rib or a dimmer shade of a kind.
function Kit.lit(spec: PartSpec, kind: string, nightColor: Color3?): PartSpec
	local look = NIGHT.kinds[kind]
	if look == nil then
		error(`Kit.lit: unknown night light kind {kind}`, 2)
	end
	spec.tag = NIGHT.tag
	local attributes: { [string]: any } = spec.attributes or {}
	attributes[NIGHT.kindAttribute] = kind
	attributes[NIGHT.dayColorAttribute] = spec.color
	if nightColor then
		attributes[NIGHT.nightColorAttribute] = nightColor
	end
	spec.attributes = attributes
	spec.material = look.dayMaterial
	local light = spec.light
	if light then
		light.enabled = false
	end
	return spec
end

-- A neon tube from a to b (along one axis): a pastel moulding by day, `kind`'s neon at night.
function Kit.neon(m: Model, name: string, a: Vector3, b: Vector3, kind: string, dayColor: Color3, diameter: number?)
	local spec =
		Kit.tube(m, name, a, b, diameter or KIT.neonDiameter, Kit.look(dayColor, Enum.Material.SmoothPlastic), "detail")
	return Kit.lit(spec, kind)
end

-- A flat neon strip (a box): crown rings, LED edges, lit slots.
function Kit.neonStrip(m: Model, name: string, min: Vector3, max: Vector3, kind: string, dayColor: Color3): PartSpec
	return Kit.lit(Kit.detail(m, name, min, max, Kit.look(dayColor, Enum.Material.SmoothPlastic)), kind)
end

-- A facade wash: a slim fixture lying along x0..x1 at (z, y) whose SurfaceLight lights the wall above it at night
-- (TECH §5.3: one per hero facade, never one per tube).
function Kit.wash(m: Model, name: string, x0: number, x1: number, z: number, y: number, color: Color3): PartSpec
	local spec = Kit.detail(
		m,
		name,
		Vector3.new(x0, y, z - 0.3),
		Vector3.new(x1, y + 0.4, z + 0.3),
		Kit.look(Color3.fromRGB(60, 62, 66), Enum.Material.SmoothPlastic)
	)
	spec.light = {
		kind = "surface",
		brightness = KIT.washBrightness,
		range = KIT.washRange,
		angle = KIT.washAngle,
		color = color,
		face = Enum.NormalId.Top,
		enabled = false,
	}
	return Kit.lit(spec, "uplight")
end

---------------------------------------------------------------------------------------------------------------
-- Glass
---------------------------------------------------------------------------------------------------------------

local WALLS = { Enum.NormalId.Front, Enum.NormalId.Back, Enum.NormalId.Left, Enum.NormalId.Right }

-- A glass part between two corners with an overlay image (window grid, slab lines) on its faces. Opaque, mirroring
-- the sky; `lit` makes it a run of windows that glows warm at night (the overlay stays, so lit floors show
-- mullions). Glass is never a collider a car can't see: it is a solid box.
function Kit.glass(m: Model, name: string, min: Vector3, max: Vector3, color: Color3, options: GlassOptions?): PartSpec
	local o: GlassOptions = options or {}
	local spec = Kit.box(m, name, min, max, Kit.glassLook(color, o.reflectance))
	local image = o.image
	local low = math.min(min.Y, max.Y)
	-- A tall tower's glass above its podium keeps floor lines only: a mullion grid reads as a checkerboard from afar.
	if
		m.site.height >= KIT.gridMaxHeight
		and low >= KIT.gridFrom
		and (image == City.textures.windowFine or image == City.textures.windowBold)
	then
		image = City.textures.slabLine
	end
	if image then
		local textures: { TextureSpec } = {}
		local faces: { Enum.NormalId } = o.faces or WALLS
		for _, face in faces do
			table.insert(textures, {
				face = Kit.face(m, face),
				image = image,
				u = o.u or 6,
				v = o.v or 12,
				offsetV = o.offsetV,
				color = o.lines or City.palettes.frame.white,
			})
		end
		spec.textures = textures
	end
	if o.lit then
		-- Each run of windows in one of the night's tints, and some upper runs dark (Config/Environment nightLights
		-- windowTints, windowDarkShare), picked by the part's name so a rebuild lights the same floors.
		local roll = Random.new(nameSeed(spec.name, m.site.seed))
		local dark = low >= NIGHT.windowDarkFrom and roll:NextNumber() < NIGHT.windowDarkShare
		if not dark then
			local tints = NIGHT.windowTints
			Kit.lit(spec, "window", tints[roll:NextInteger(1, #tints)])
		end
	end
	return spec
end

-- A stucco wall with punched windows from one part: dark glass under the punched overlay tinted to the wall's colour,
-- on `faces`. A tile is one window bay `u` wide and one floor `v` tall, counted from the part's top edge, so make the
-- top a floor line and the height whole floors. `lit` lights its windows at night.
function Kit.punched(
	m: Model,
	name: string,
	min: Vector3,
	max: Vector3,
	wall: Color3,
	glass: Color3,
	faces: { Enum.NormalId },
	u: number,
	v: number,
	lit: boolean?
): PartSpec
	return Kit.glass(m, name, min, max, glass, {
		image = City.textures.punched,
		faces = faces,
		u = u,
		v = v,
		lines = wall,
		lit = lit,
		reflectance = 0.1,
	})
end

---------------------------------------------------------------------------------------------------------------
-- Massing
---------------------------------------------------------------------------------------------------------------

-- A box with some of its vertical corners rounded to `radius` (Streamline corners, rounded towers): two crossing
-- boxes, a cylinder at each rounded corner and a square fill where a corner is square but both its neighbours are
-- trimmed. 2 to 6 parts. The pieces' tops and bottoms are set a hair apart so no two faces are coplanar.
function Kit.roundedBox(
	m: Model,
	name: string,
	min: Vector3,
	max: Vector3,
	radius: number,
	corners: Corners,
	look: Look,
	kind: Kind?
): { PartSpec }
	local lo, hi = min:Min(max), min:Max(max)
	local r = math.min(radius, (hi.X - lo.X) / 2, (hi.Z - lo.Z) / 2)
	local k: Kind = kind or "box"
	local out: { PartSpec } = {}
	local front = (corners.fl or corners.fr) == true
	local back = (corners.bl or corners.br) == true
	local left = (corners.fl or corners.bl) == true
	local right = (corners.fr or corners.br) == true
	local zf, zb = lo.Z + (if front then r else 0), hi.Z - (if back then r else 0)
	local xl, xr = lo.X + (if left then r else 0), hi.X - (if right then r else 0)
	local hair = 0.02
	table.insert(out, boxAt(m, name, Vector3.new(lo.X, lo.Y, zf), Vector3.new(hi.X, hi.Y, zb), look, k))
	table.insert(
		out,
		boxAt(m, name .. "X", Vector3.new(xl, lo.Y + hair, lo.Z), Vector3.new(xr, hi.Y - hair, hi.Z), look, k)
	)
	local spots = {
		{ key = "fl", on = corners.fl == true, x = lo.X, z = lo.Z, sx = 1, sz = 1 },
		{ key = "fr", on = corners.fr == true, x = hi.X, z = lo.Z, sx = -1, sz = 1 },
		{ key = "bl", on = corners.bl == true, x = lo.X, z = hi.Z, sx = 1, sz = -1 },
		{ key = "br", on = corners.br == true, x = hi.X, z = hi.Z, sx = -1, sz = -1 },
	}
	for _, spot in spots do
		local cx, cz = spot.x + spot.sx * r, spot.z + spot.sz * r
		if spot.on then
			table.insert(
				out,
				Kit.column(m, `{name}R{spot.key}`, cx, cz, lo.Y + 2 * hair, hi.Y - 2 * hair, 2 * r, look, k)
			)
		else
			-- A square corner both crossing boxes miss (its two sides were trimmed for other corners).
			local trimmedX = (spot.sx > 0 and left) or (spot.sx < 0 and right)
			local trimmedZ = (spot.sz > 0 and front) or (spot.sz < 0 and back)
			if trimmedX and trimmedZ then
				local a = Vector3.new(spot.x, lo.Y + 2 * hair, spot.z)
				local b = Vector3.new(cx, hi.Y - 2 * hair, cz)
				table.insert(out, boxAt(m, `{name}S{spot.key}`, a, b, look, k))
			end
		end
	end
	return out
end

-- A horizontal band (an eyebrow, a cornice, a balcony slab) following a body's outline `proud` studs out, `thick`
-- tall, centred at height y. `sides` "front" runs across the front and wraps the front corners (rounded ones with a
-- disc reaching round onto the side); "around" circles the whole body. `radius` and `corners` describe the body's
-- rounded corners (0 and {} for a plain box).
function Kit.band(
	m: Model,
	name: string,
	min: Vector3,
	max: Vector3,
	radius: number,
	corners: Corners,
	y: number,
	thick: number,
	proud: number,
	look: Look,
	sides: "front" | "around"
): { PartSpec }
	local lo, hi = min:Min(max), min:Max(max)
	local y0, y1 = y - thick / 2, y + thick / 2
	if sides == "around" then
		return Kit.roundedBox(
			m,
			name,
			Vector3.new(lo.X - proud, y0, lo.Z - proud),
			Vector3.new(hi.X + proud, y1, hi.Z + proud),
			radius + proud,
			corners,
			look,
			"trim"
		)
	end
	local r = math.min(radius, (hi.X - lo.X) / 2, (hi.Z - lo.Z) / 2)
	local out: { PartSpec } = {}
	local x0 = if corners.fl then lo.X + r else lo.X - proud
	local x1 = if corners.fr then hi.X - r else hi.X + proud
	-- The strip reaches a little into the wall so its back edge never meets the wall face exactly.
	local depth = math.max(proud + 0.5, if r > 0 then r else 0.5)
	table.insert(out, Kit.trim(m, name, Vector3.new(x0, y0, lo.Z - proud), Vector3.new(x1, y1, lo.Z + depth), look))
	if corners.fl and r > 0 then
		table.insert(out, Kit.disc(m, name .. "L", lo.X + r, lo.Z + r, y, 2 * (r + proud), thick, look, "trim"))
	end
	if corners.fr and r > 0 then
		table.insert(out, Kit.disc(m, name .. "R", hi.X - r, lo.Z + r, y, 2 * (r + proud), thick, look, "trim"))
	end
	return out
end

-- Floor plates round a core from y0 up to y1, one every `every` studs: each `thick` tall and `proudX` past the
-- core's ends, `proudZ` past its front and back (balconies on the long faces, a thin edge on the ends). With
-- `rail`, a glass rail sits on each plate (one see-through box, its rim showing round the core). Returns plates
-- then rails.
function Kit.plates(
	m: Model,
	name: string,
	coreMin: Vector3,
	coreMax: Vector3,
	y0: number,
	y1: number,
	every: number,
	thick: number,
	proudX: number,
	proudZ: number,
	look: Look,
	rail: Look?
): { PartSpec }
	local out: { PartSpec } = {}
	local lo, hi = coreMin:Min(coreMax), coreMin:Max(coreMax)
	local count = 0
	local y = y0
	while y + thick <= y1 + EPS do
		count += 1
		local a = Vector3.new(lo.X - proudX, y, lo.Z - proudZ)
		local b = Vector3.new(hi.X + proudX, y + thick, hi.Z + proudZ)
		table.insert(out, Kit.trim(m, `{name}{count}`, a, b, look))
		if rail then
			local inset = 0.15
			local ra = Vector3.new(a.X + inset, y + thick, a.Z + inset)
			local rb = Vector3.new(b.X - inset, y + thick + KIT.railHeight, b.Z - inset)
			table.insert(out, Kit.detail(m, `{name}Rail{count}`, ra, rb, rail))
		end
		y += every
	end
	return out
end

-- Steps stacked on a base: each step `rise` tall and set in `inset` more on every side (Deco ziggurat tops, setback
-- towers, stepped crowns). Returns the steps bottom first and the top of the last one.
function Kit.setbacks(
	m: Model,
	name: string,
	min: Vector3,
	max: Vector3,
	steps: { { rise: number, inset: number } },
	look: Look,
	kind: Kind?
): ({ PartSpec }, number)
	local out: { PartSpec } = {}
	local lo, hi = min:Min(max), min:Max(max)
	local y = hi.Y
	local inset = 0
	for i, step in steps do
		inset += step.inset
		local a = Vector3.new(lo.X + inset, y, lo.Z + inset)
		local b = Vector3.new(hi.X - inset, y + step.rise, hi.Z - inset)
		table.insert(out, boxAt(m, `{name}{i}`, a, b, look, kind or "box"))
		y += step.rise
	end
	return out, y
end

-- Vertical fins across one face from a0 to a1 (x on the front and back, z on the sides), `count` of them evenly
-- spaced, standing `proud` out from the face plane at `plane`, `thick` wide, from y0 to y1.
function Kit.fins(
	m: Model,
	name: string,
	side: Side,
	plane: number,
	a0: number,
	a1: number,
	count: number,
	y0: number,
	y1: number,
	proud: number,
	thick: number,
	look: Look
): { PartSpec }
	local out: { PartSpec } = {}
	for i = 1, count do
		local a = if count == 1 then (a0 + a1) / 2 else a0 + (a1 - a0) * (i - 1) / (count - 1)
		local p0, p1 = a - thick / 2, a + thick / 2
		local min: Vector3, max: Vector3
		if side == "front" then
			min, max = Vector3.new(p0, y0, plane - proud), Vector3.new(p1, y1, plane + 0.3)
		elseif side == "back" then
			min, max = Vector3.new(p0, y0, plane - 0.3), Vector3.new(p1, y1, plane + proud)
		elseif side == "left" then
			min, max = Vector3.new(plane - proud, y0, p0), Vector3.new(plane + 0.3, y1, p1)
		else
			min, max = Vector3.new(plane - 0.3, y0, p0), Vector3.new(plane + proud, y1, p1)
		end
		table.insert(out, Kit.trim(m, `{name}{i}`, min, max, look))
	end
	return out
end

---------------------------------------------------------------------------------------------------------------
-- Pieces
---------------------------------------------------------------------------------------------------------------

-- A round window on the front face at `plane` (z): a dark glass disc in a rim. 2 parts; `kind` lights the glass.
function Kit.porthole(
	m: Model,
	name: string,
	x: number,
	y: number,
	plane: number,
	diameter: number,
	glass: Color3,
	rim: Look,
	kind: string?
): { PartSpec }
	local rimSpec = Kit.tube(
		m,
		name .. "Rim",
		Vector3.new(x, y, plane - 0.4),
		Vector3.new(x, y, plane + 0.3),
		diameter,
		rim,
		"trim"
	)
	local pane = Kit.tube(
		m,
		name,
		Vector3.new(x, y, plane - 0.5),
		Vector3.new(x, y, plane - 0.3),
		diameter * 0.72,
		Kit.glassLook(glass, 0.25),
		"detail"
	)
	if kind then
		Kit.lit(pane, kind)
	end
	return { rimSpec, pane }
end

-- A parapet: four walls `thick` thick standing round the roof outline min..max (x and z) from y up `height`. 4 parts.
-- For a solid roof edge instead, one trim slab a little bigger than the roof is cheaper (Kit.band "around").
function Kit.parapet(
	m: Model,
	name: string,
	min: Vector3,
	max: Vector3,
	y: number,
	height: number,
	thick: number,
	look: Look
): { PartSpec }
	local lo, hi = min:Min(max), min:Max(max)
	local y1 = y + height
	return {
		Kit.trim(m, name .. "Front", Vector3.new(lo.X, y, lo.Z), Vector3.new(hi.X, y1, lo.Z + thick), look),
		Kit.trim(m, name .. "Back", Vector3.new(lo.X, y, hi.Z - thick), Vector3.new(hi.X, y1, hi.Z), look),
		Kit.trim(
			m,
			name .. "Left",
			Vector3.new(lo.X, y + 0.02, lo.Z + thick),
			Vector3.new(lo.X + thick, y1 - 0.02, hi.Z - thick),
			look
		),
		Kit.trim(
			m,
			name .. "Right",
			Vector3.new(hi.X - thick, y + 0.02, lo.Z + thick),
			Vector3.new(hi.X, y1 - 0.02, hi.Z - thick),
			look
		),
	}
end

-- A stepped crown (TECH §5.5) centred at (x, z) from y: one box per tier, bottom up, each { width, depth, height },
-- and with `ring` a neon band round each tier just under its top (one slab, lit on all four sides at night). Returns
-- the parts and the crown's top.
function Kit.steppedCrown(
	m: Model,
	name: string,
	x: number,
	z: number,
	y: number,
	tiers: { { width: number, depth: number, height: number } },
	look: Look,
	ring: { kind: string, color: Color3 }?
): ({ PartSpec }, number)
	local out: { PartSpec } = {}
	local top = y
	for i, tier in tiers do
		local hw, hd = tier.width / 2, tier.depth / 2
		table.insert(
			out,
			Kit.box(
				m,
				`{name}{i}`,
				Vector3.new(x - hw, top, z - hd),
				Vector3.new(x + hw, top + tier.height, z + hd),
				look
			)
		)
		if ring then
			local ry = top + tier.height - 0.8
			table.insert(
				out,
				Kit.neonStrip(
					m,
					`{name}Ring{i}`,
					Vector3.new(x - hw - 0.15, ry - 0.4, z - hd - 0.15),
					Vector3.new(x + hw + 0.15, ry, z + hd + 0.15),
					ring.kind,
					ring.color
				)
			)
		end
		top += tier.height
	end
	return out, top
end

-- A spire: a tapering mast of `segments` cylinders from y up `height`, a beacon at the tip (night kind "beacon").
function Kit.spire(
	m: Model,
	name: string,
	x: number,
	z: number,
	y: number,
	height: number,
	diameter: number,
	look: Look,
	segments: number?,
	beacon: boolean?
): { PartSpec }
	local out: { PartSpec } = {}
	local n = segments or 2
	local step = height / n
	for i = 1, n do
		local d = diameter * (1 - 0.3 * (i - 1) / math.max(1, n - 1))
		table.insert(out, Kit.column(m, `{name}{i}`, x, z, y + (i - 1) * step, y + i * step, d, look, "detail"))
	end
	if beacon then
		local tip = Kit.ball(
			m,
			name .. "Beacon",
			Vector3.new(x, y + height + 0.6, z),
			1.2,
			Kit.look(Color3.fromRGB(150, 40, 36), Enum.Material.SmoothPlastic)
		)
		table.insert(out, Kit.lit(tip, "beacon"))
	end
	return out
end

-- A sign board between two corners with `text` on its `face` (a SurfaceGui; text on signs doesn't show in Edit-mode
-- screenshots). With `kind`, the board glows at night (a neon panel); without, the text alone stays bright.
function Kit.sign(
	m: Model,
	name: string,
	min: Vector3,
	max: Vector3,
	face: Enum.NormalId,
	text: string,
	board: Color3,
	textColor: Color3,
	font: Enum.Font,
	kind: string?
): PartSpec
	local spec = Kit.detail(m, name, min, max, Kit.look(board, Enum.Material.SmoothPlastic))
	spec.labels = {
		{
			face = Kit.face(m, face),
			text = text,
			color = textColor,
			font = font,
			size = Vector2.new(0.92, 0.8),
			pixelsPerStud = KIT.signPixelsPerStud,
		},
	}
	if kind then
		Kit.lit(spec, kind)
	end
	return spec
end

-- A cantilevered entrance canopy: a slab from z0 (the front, at most the front line) back to z1, x0..x1, its
-- underside at y. 1 part.
function Kit.canopy(
	m: Model,
	name: string,
	x0: number,
	x1: number,
	z0: number,
	z1: number,
	y: number,
	thick: number,
	look: Look
): PartSpec
	return Kit.trim(m, name, Vector3.new(x0, y, z0), Vector3.new(x1, y + thick, z1), look)
end

-- A rooftop pool sunk into a deck at height y (the deck is the roof itself): the water and its coping. 2 parts.
function Kit.pool(m: Model, name: string, min: Vector3, max: Vector3, y: number): { PartSpec }
	local lo, hi = min:Min(max), min:Max(max)
	local coping = Kit.detail(
		m,
		name .. "Edge",
		Vector3.new(lo.X - 0.8, y, lo.Z - 0.8),
		Vector3.new(hi.X + 0.8, y + 0.35, hi.Z + 0.8),
		Kit.look(City.palettes.deco.terrazzo, Enum.Material.SmoothPlastic)
	)
	local water = Kit.detail(
		m,
		name,
		Vector3.new(lo.X, y + 0.05, lo.Z),
		Vector3.new(hi.X, y + 0.45, hi.Z),
		Kit.look(City.palettes.water, Enum.Material.Glass, 0.3, 0)
	)
	return { coping, water }
end

-- A planter: a box with a block of greenery on top. 2 parts.
function Kit.planter(m: Model, name: string, min: Vector3, max: Vector3, box: Look): { PartSpec }
	local lo, hi = min:Min(max), min:Max(max)
	local pot = Kit.trim(m, name, lo, hi, box)
	local leaves = Kit.detail(
		m,
		name .. "Leaves",
		Vector3.new(lo.X + 0.3, hi.Y, lo.Z + 0.3),
		Vector3.new(hi.X - 0.3, hi.Y + 1.6, hi.Z - 0.3),
		Kit.look(City.palettes.leaf, Enum.Material.Grass)
	)
	return { pot, leaves }
end

-- A café umbrella standing at (x, z) on a floor at y: a pole and a round canopy (2 parts), or with `square` a
-- market umbrella: a square canopy under a smaller square cap, a stepped pyramid (3 parts).
function Kit.umbrella(
	m: Model,
	name: string,
	x: number,
	z: number,
	y: number,
	size: number,
	color: Color3,
	square: boolean?
): { PartSpec }
	local look = Kit.look(color, Enum.Material.SmoothPlastic)
	local pole = Kit.column(
		m,
		name .. "Pole",
		x,
		z,
		y,
		y + 8,
		0.3,
		Kit.look(Color3.fromRGB(236, 234, 228), Enum.Material.Metal),
		"detail"
	)
	if not square then
		return { pole, Kit.column(m, name, x, z, y + 6.6, y + 7.4, size, look, "trim") }
	end
	local h = size / 2
	local canopy = Kit.trim(m, name, Vector3.new(x - h, y + 6.8, z - h), Vector3.new(x + h, y + 7.2, z + h), look)
	local q = size * 0.22
	local cap = Kit.trim(m, name .. "Cap", Vector3.new(x - q, y + 7.2, z - q), Vector3.new(x + q, y + 7.9, z + q), look)
	return { pole, canopy, cap }
end

-- A roof box (stair or lift overrun, plant room) between two corners. 1 part.
function Kit.roofBox(m: Model, name: string, min: Vector3, max: Vector3, look: Look?): PartSpec
	return Kit.box(m, name, min, max, look or Kit.look(Color3.fromRGB(176, 178, 180), Enum.Material.Concrete))
end

-- A parking podium (TECH K2): a dark mass with a pale spandrel band per level standing `proud` out on every side,
-- so each level reads as a slot in shadow under a band. Returns the mass then the bands.
function Kit.podium(
	m: Model,
	name: string,
	min: Vector3,
	max: Vector3,
	levels: number,
	slot: number,
	proud: number,
	band: Look,
	mass: Look
): { PartSpec }
	local lo, hi = min:Min(max), min:Max(max)
	local out: { PartSpec } = { Kit.box(m, name, lo, hi, mass) }
	local level = (hi.Y - lo.Y) / levels
	for i = 1, levels do
		local y0 = lo.Y + (i - 1) * level
		local a = Vector3.new(lo.X - proud, y0, lo.Z - proud)
		local b = Vector3.new(hi.X + proud, y0 + level - slot, hi.Z + proud)
		table.insert(out, Kit.trim(m, `{name}Band{i}`, a, b, band))
	end
	return out
end

---------------------------------------------------------------------------------------------------------------
-- Roofs and arches (docs/city/ARCHETYPES.md §2 K7; the houses of §7)
---------------------------------------------------------------------------------------------------------------

-- A corner of a box in plan: front-left (-x, -z), front-right (+x, -z), back-left, back-right.
export type Corner = "fl" | "fr" | "bl" | "br"

-- A CornerWedgePart's peak stands over its (+X, -Z) bottom corner ("fr" here; as Dev/MapBuilder's mesas),
-- and each quarter turn about y moves it on round the box: fr, fl, bl, br.
local CORNER_TURNS: { [Corner]: number } = { fr = 0, fl = 1, bl = 2, br = 3 }
local CORNER_MIRROR: { [Corner]: Corner } = { fl = "fr", fr = "fl", bl = "br", br = "bl" }

-- A corner wedge filling the box min..max: its peak stands over the `peak` corner, its two faces on that corner's sides
-- are upright and its two slopes fall to the far sides (the corners of a hip roof, a lean-to's hipped end). 1 part.
function Kit.cornerWedge(
	m: Model,
	name: string,
	min: Vector3,
	max: Vector3,
	peak: Corner,
	look: Look,
	kind: Kind?
): PartSpec
	local lo, hi = min:Min(max), min:Max(max)
	local c = (lo + hi) / 2
	local s = hi - lo
	local turns = CORNER_TURNS[if m.mirror then CORNER_MIRROR[peak] else peak]
	local size = if turns % 2 == 1 then Vector3.new(s.Z, s.Y, s.X) else s
	local cf = CFrame.new(mx(m, c.X), c.Y, c.Z) * CFrame.Angles(0, turns * QUARTER, 0)
	return Kit.part(m, name, "cornerWedge", cf, size, look, kind or "box")
end

-- A wedge hung upside down, filling the box min..max: its flat face on top, its upright face on the `wall` side, its
-- slope running from the foot of that face up to the top of the far side. Corbels and brackets under a balcony or an
-- eave (`wall` the side against the wall), and the haunches of an arch (Kit.archHead). 1 part, trim unless `kind`.
function Kit.corbel(m: Model, name: string, min: Vector3, max: Vector3, wall: Side, look: Look, kind: Kind?): PartSpec
	local lo, hi = min:Min(max), min:Max(max)
	local c = (lo + hi) / 2
	local s = hi - lo
	local side: Side = wall
	if m.mirror and wall == "left" then
		side = "right"
	elseif m.mirror and wall == "right" then
		side = "left"
	end
	local across = side == "left" or side == "right"
	local size = if across then Vector3.new(s.Z, s.Y, s.X) else s
	-- Kit.wedge's turn puts the upright face on `side`; half a roll about that axis turns the wedge over.
	local cf = CFrame.new(mx(m, c.X), c.Y, c.Z) * CFrame.Angles(0, RISE_TURN[side], 0) * CFrame.Angles(0, 0, math.pi)
	return Kit.part(m, name, "wedge", cf, size, look, kind or "trim")
end

-- A hipped roof on walls whose outline is min..max (x and z), min.Y the top of the walls and max.Y the ridge. Every
-- slope has the same pitch; the eaves reach `overhang` past the walls and the roof stands `thick` over the top of the
-- walls at the wall line (so its soffit hides the wall tops). A ridge along the longer side between two wedges, and a
-- corner wedge at each corner: a pyramid when the outline is square. 4 or 6 parts.
function Kit.hipRoof(
	m: Model,
	name: string,
	min: Vector3,
	max: Vector3,
	overhang: number,
	thick: number,
	look: Look,
	kind: Kind?
): { PartSpec }
	local lo, hi = min:Min(max), min:Max(max)
	local k: Kind = kind or "box"
	local half = math.min(hi.X - lo.X, hi.Z - lo.Z) / 2
	local pitch = math.max(0.05, hi.Y - lo.Y - thick) / half
	local x0, x1 = lo.X - overhang, hi.X + overhang
	local z0, z1 = lo.Z - overhang, hi.Z + overhang
	local y0, y1 = hi.Y - pitch * (half + overhang), hi.Y
	local h = half + overhang -- each corner wedge is h square: the ridge's ends stand over their inner corners
	local xc, zc = (x0 + x1) / 2, (z0 + z1) / 2
	local long = (x1 - x0) - (z1 - z0)
	local out: { PartSpec } = {}
	if long > 0.05 then
		table.insert(
			out,
			Kit.wedge(m, name .. "F", Vector3.new(x0 + h, y0, z0), Vector3.new(x1 - h, y1, zc), "back", look, k)
		)
		table.insert(
			out,
			Kit.wedge(m, name .. "B", Vector3.new(x0 + h, y0, zc), Vector3.new(x1 - h, y1, z1), "front", look, k)
		)
	elseif long < -0.05 then
		table.insert(
			out,
			Kit.wedge(m, name .. "L", Vector3.new(x0, y0, z0 + h), Vector3.new(xc, y1, z1 - h), "right", look, k)
		)
		table.insert(
			out,
			Kit.wedge(m, name .. "R", Vector3.new(xc, y0, z0 + h), Vector3.new(x1, y1, z1 - h), "left", look, k)
		)
	end
	table.insert(
		out,
		Kit.cornerWedge(m, name .. "FL", Vector3.new(x0, y0, z0), Vector3.new(x0 + h, y1, z0 + h), "br", look, k)
	)
	table.insert(
		out,
		Kit.cornerWedge(m, name .. "FR", Vector3.new(x1 - h, y0, z0), Vector3.new(x1, y1, z0 + h), "bl", look, k)
	)
	table.insert(
		out,
		Kit.cornerWedge(m, name .. "BL", Vector3.new(x0, y0, z1 - h), Vector3.new(x0 + h, y1, z1), "fr", look, k)
	)
	table.insert(
		out,
		Kit.cornerWedge(m, name .. "BR", Vector3.new(x1 - h, y0, z1 - h), Vector3.new(x1, y1, z1), "fl", look, k)
	)
	return out
end

-- A gabled roof on walls whose outline is min..max (x and z), min.Y the top of the walls and max.Y the ridge, which runs
-- along `ridge` ("x": the gables face the sides; "z": they face front and back). The two slopes reach `overhang` past
-- the eaves and stand `thick` over the top of the walls at the wall line. With `gable`, the gable triangles are wedges
-- of that look flush with the end walls, and the slopes stop just behind them, so each rake shows only a thin edge of
-- tile, as on Mediterranean and coral-rock houses (a solid tile wedge's own end would show a whole triangle of tile).
-- 2 parts, or 4 with gables.
function Kit.gableRoof(
	m: Model,
	name: string,
	min: Vector3,
	max: Vector3,
	ridge: "x" | "z",
	overhang: number,
	thick: number,
	roof: Look,
	gable: Look?,
	kind: Kind?
): { PartSpec }
	local lo, hi = min:Min(max), min:Max(max)
	local k: Kind = kind or "box"
	local inset = if gable then 0.12 else 0
	local out: { PartSpec } = {}
	local top = hi.Y - thick -- the gable triangles' peak
	if ridge == "x" then
		local zc = (lo.Z + hi.Z) / 2
		local half = zc - lo.Z
		local pitch = math.max(0.05, top - lo.Y) / half
		local y0 = hi.Y - pitch * (half + overhang)
		local a0, a1 = lo.X + inset, hi.X - inset
		table.insert(
			out,
			Kit.wedge(m, name .. "F", Vector3.new(a0, y0, lo.Z - overhang), Vector3.new(a1, hi.Y, zc), "back", roof, k)
		)
		table.insert(
			out,
			Kit.wedge(m, name .. "B", Vector3.new(a0, y0, zc), Vector3.new(a1, hi.Y, hi.Z + overhang), "front", roof, k)
		)
		if gable then
			table.insert(
				out,
				Kit.wedge(m, name .. "GF", Vector3.new(lo.X, lo.Y, lo.Z), Vector3.new(hi.X, top, zc), "back", gable, k)
			)
			table.insert(
				out,
				Kit.wedge(m, name .. "GB", Vector3.new(lo.X, lo.Y, zc), Vector3.new(hi.X, top, hi.Z), "front", gable, k)
			)
		end
	else
		local xc = (lo.X + hi.X) / 2
		local half = xc - lo.X
		local pitch = math.max(0.05, top - lo.Y) / half
		local y0 = hi.Y - pitch * (half + overhang)
		local a0, a1 = lo.Z + inset, hi.Z - inset
		table.insert(
			out,
			Kit.wedge(m, name .. "L", Vector3.new(lo.X - overhang, y0, a0), Vector3.new(xc, hi.Y, a1), "right", roof, k)
		)
		table.insert(
			out,
			Kit.wedge(m, name .. "R", Vector3.new(xc, y0, a0), Vector3.new(hi.X + overhang, hi.Y, a1), "left", roof, k)
		)
		if gable then
			table.insert(
				out,
				Kit.wedge(m, name .. "GL", Vector3.new(lo.X, lo.Y, lo.Z), Vector3.new(xc, top, hi.Z), "right", gable, k)
			)
			table.insert(
				out,
				Kit.wedge(m, name .. "GR", Vector3.new(xc, lo.Y, lo.Z), Vector3.new(hi.X, top, hi.Z), "left", gable, k)
			)
		end
	end
	return out
end

-- The head of an arched opening between x0 and x1 whose top is `crown` (the underside of the wall over it), through
-- the wall from z0 to z1: a haunch in each top corner, `rise` tall and reaching `rise` in from its jamb, so the corners
-- are cut back at 45 degrees and the opening reads as an arch from the street (a true curve needs CSG). Loggias,
-- arcades, carriage gates. 2 parts.
function Kit.archHead(
	m: Model,
	name: string,
	x0: number,
	x1: number,
	crown: number,
	z0: number,
	z1: number,
	rise: number,
	look: Look
): { PartSpec }
	local r = math.min(rise, (x1 - x0) / 2 - 0.05)
	return {
		Kit.corbel(m, name .. "L", Vector3.new(x0, crown - r, z0), Vector3.new(x0 + r, crown, z1), "left", look),
		Kit.corbel(m, name .. "R", Vector3.new(x1 - r, crown - r, z0), Vector3.new(x1, crown, z1), "right", look),
	}
end

-- A round-headed window or door on a front face at z: glass from x0 to x1 and from y0 up to `spring`, under a half
-- disc as wide (a glass cylinder whose lower half sinks into the pane). The pane stands 0.2 proud of the face and
-- reaches 0.3 into it; `spring - y0` must be at least half the width. Options as Kit.glass (the overlay goes on the
-- pane; `lit` lights both). 2 parts.
function Kit.archWindow(
	m: Model,
	name: string,
	x0: number,
	x1: number,
	y0: number,
	spring: number,
	z: number,
	color: Color3,
	options: GlassOptions?
): { PartSpec }
	local o: GlassOptions = options or {}
	local cx, w = (x0 + x1) / 2, math.abs(x1 - x0)
	local pane = Kit.glass(m, name, Vector3.new(x0, y0, z - 0.2), Vector3.new(x1, spring, z + 0.3), color, options)
	-- The head stands 0.02 behind the pane's face, so the pane covers its lower half without sharing a plane.
	local head = Kit.tube(
		m,
		name .. "Head",
		Vector3.new(cx, spring, z - 0.18),
		Vector3.new(cx, spring, z + 0.3),
		w,
		Kit.glassLook(color, o.reflectance),
		"detail"
	)
	if o.lit then
		Kit.lit(head, "window")
	end
	return { pane, head }
end

---------------------------------------------------------------------------------------------------------------
-- Walls with real openings, and railings (the houses of docs/city/ARCHETYPES.md §7; any facade that wants reveals)
---------------------------------------------------------------------------------------------------------------

-- An opening in a wall, in the wall's own terms: `a0..a1` along it (x on the front and back, z on the sides) and
-- `y0..y1` up. `glass` false leaves it open (a doorway the caller hangs a door in, an arcade, a breezeway); `lit`
-- lights its run of panes at night.
export type Opening = { a0: number, a1: number, y0: number, y1: number, glass: boolean?, lit: boolean? }

-- Kit.skin's options: the panes' colour and overlay (default: dark window glass with mullions and a transom), a sill
-- under every glazed opening that doesn't start at the wall's foot, and the pieces' kind (default "trim").
export type SkinOptions = {
	glass: Color3?,
	panes: GlassOptions?,
	sill: { proud: number, thick: number, look: Look }?,
	kind: Kind?,
}

local SKIN_EPS = 1e-3
local SKIN_FACE: { [Side]: Enum.NormalId } = {
	front = Enum.NormalId.Front,
	back = Enum.NormalId.Back,
	left = Enum.NormalId.Left,
	right = Enum.NormalId.Right,
}

-- A wall's outer skin, `depth` thick, standing out from a face of the caller's mass (`side` names the face, `plane` is
-- its coordinate: z on the front and back, x on the sides), cut round rectangular openings. The skin is the fewest
-- boxes that tile the rectangle a0..a1 by y0..y1 less the openings (openings in a row share their piers, and pieces
-- of one width one over another merge), and the panes sit back on the face behind it, so every window has a real
-- reveal `depth` deep that holds a shadow. Glazed openings of one height in a row (none open between them) share one
-- glass part behind their piers. The skin's back is the face itself and its ends stop at a0 and a1, so nothing it
-- adds is coplanar with the mass. Returns the pieces, then the panes, then the sills.
function Kit.skin(
	m: Model,
	name: string,
	side: Side,
	plane: number,
	a0: number,
	a1: number,
	y0: number,
	y1: number,
	depth: number,
	wall: Look,
	openings: { Opening },
	options: SkinOptions?
): { PartSpec }
	local o: SkinOptions = options or {}
	local outward = if side == "front" or side == "left" then -1 else 1
	local alongX = side == "front" or side == "back"
	-- A point `n` out from the face (negative: into the mass behind it).
	local function at(a: number, y: number, n: number): Vector3
		local c = plane + outward * n
		return if alongX then Vector3.new(a, y, c) else Vector3.new(c, y, a)
	end
	local lo, hi = math.min(a0, a1), math.max(a0, a1)
	local ylo, yhi = math.min(y0, y1), math.max(y0, y1)
	-- The openings inside the wall, clipped to it.
	local holes: { Opening } = {}
	for _, h in openings do
		local c = {
			a0 = math.max(lo, math.min(h.a0, h.a1)),
			a1 = math.min(hi, math.max(h.a0, h.a1)),
			y0 = math.max(ylo, math.min(h.y0, h.y1)),
			y1 = math.min(yhi, math.max(h.y0, h.y1)),
			glass = h.glass,
			lit = h.lit,
		}
		if c.a1 - c.a0 > SKIN_EPS and c.y1 - c.y0 > SKIN_EPS then
			table.insert(holes, c)
		end
	end

	-- The horizontal cuts: the wall's foot and top and every opening's sill and head.
	local ys = { ylo, yhi }
	for _, h in holes do
		table.insert(ys, h.y0)
		table.insert(ys, h.y1)
	end
	table.sort(ys)
	local cuts: { number } = {}
	for _, y in ys do
		if #cuts == 0 or y - cuts[#cuts] > SKIN_EPS then
			table.insert(cuts, y)
		end
	end
	type Piece = { a0: number, a1: number, y0: number, y1: number }
	local growing: { Piece } = {}
	local done: { Piece } = {}
	for i = 1, #cuts - 1 do
		local ya, yb = cuts[i], cuts[i + 1]
		local across: { Opening } = {}
		for _, h in holes do
			if h.y0 <= ya + SKIN_EPS and h.y1 >= yb - SKIN_EPS then
				table.insert(across, h)
			end
		end
		table.sort(across, function(p: Opening, q: Opening): boolean
			return p.a0 < q.a0
		end)
		local spans: { { number } } = {}
		local cursor = lo
		for _, h in across do
			if h.a0 - cursor > SKIN_EPS then
				table.insert(spans, { cursor, h.a0 })
			end
			cursor = math.max(cursor, h.a1)
		end
		if hi - cursor > SKIN_EPS then
			table.insert(spans, { cursor, hi })
		end
		-- A span as wide as one just under it grows that piece; the rest start new ones.
		local nextGrowing: { Piece } = {}
		for _, s in spans do
			local found: number? = nil
			for gi, g in growing do
				if math.abs(g.a0 - s[1]) < SKIN_EPS and math.abs(g.a1 - s[2]) < SKIN_EPS then
					found = gi
					break
				end
			end
			if found then
				local g = table.remove(growing, found) :: Piece
				g.y1 = yb
				table.insert(nextGrowing, g)
			else
				table.insert(nextGrowing, { a0 = s[1], a1 = s[2], y0 = ya, y1 = yb })
			end
		end
		for _, g in growing do
			table.insert(done, g)
		end
		growing = nextGrowing
	end
	for _, g in growing do
		table.insert(done, g)
	end
	table.sort(done, function(p: Piece, q: Piece): boolean
		if math.abs(p.y0 - q.y0) > SKIN_EPS then
			return p.y0 < q.y0
		end
		return p.a0 < q.a0
	end)

	local out: { PartSpec } = {}
	local kind: Kind = o.kind or "trim"
	for k, p in done do
		table.insert(out, boxAt(m, `{name}{k}`, at(p.a0, p.y0, depth), at(p.a1, p.y1, 0), wall, kind))
	end

	-- The panes: glazed openings of one height and one lighting in a row, with no open one between them, share a run.
	local glazed: { Opening } = {}
	for _, h in holes do
		if h.glass ~= false then
			table.insert(glazed, h)
		end
	end
	table.sort(glazed, function(p: Opening, q: Opening): boolean
		if math.abs(p.y0 - q.y0) > SKIN_EPS then
			return p.y0 < q.y0
		end
		return p.a0 < q.a0
	end)
	local runs: { { Opening } } = {}
	for _, h in glazed do
		local run = runs[#runs]
		local last = run and run[#run]
		local joins = last ~= nil
			and math.abs(last.y0 - h.y0) < SKIN_EPS
			and math.abs(last.y1 - h.y1) < SKIN_EPS
			and (last.lit == true) == (h.lit == true)
		if joins and last then
			for _, gap in holes do
				if
					gap.glass == false
					and gap.a0 >= last.a1 - SKIN_EPS
					and gap.a1 <= h.a0 + SKIN_EPS
					and gap.y0 < h.y1
					and gap.y1 > h.y0
				then
					joins = false
					break
				end
			end
		end
		if joins and run then
			table.insert(run, h)
		else
			table.insert(runs, { h })
		end
	end
	local color = o.glass or City.palettes.window.dark
	for k, run in runs do
		local first, last = run[1], run[#run]
		local ga0 = math.max(lo + 0.02, first.a0 - 0.1)
		local ga1 = math.min(hi - 0.02, last.a1 + 0.1)
		local gy0 = math.max(ylo + 0.02, first.y0 - 0.1)
		local gy1 = math.min(yhi - 0.02, first.y1 + 0.1)
		local base: GlassOptions = o.panes
			or { image = City.textures.windowBold, u = 1.6, lines = City.palettes.frame.white, reflectance = 0.2 }
		local panes: GlassOptions = {
			image = base.image,
			faces = { SKIN_FACE[side] },
			u = base.u,
			-- An overlay tile well taller than the pane: only its mullions and transom show, not its spandrel.
			v = base.v or ((gy1 - gy0) * 1.6 + 2),
			offsetV = base.offsetV,
			lines = base.lines,
			lit = first.lit == true,
			reflectance = base.reflectance,
		}
		table.insert(out, Kit.glass(m, `{name}Glass{k}`, at(ga0, gy0, 0.06), at(ga1, gy1, -0.3), color, panes))
	end

	-- Sills: a slab under each glazed opening, from the pane out past the skin, its ends tucked into the jambs.
	local sill = o.sill
	if sill then
		for k, h in glazed do
			if h.y0 > ylo + SKIN_EPS then
				table.insert(
					out,
					Kit.trim(
						m,
						`{name}Sill{k}`,
						at(h.a0 - 0.35, h.y0 - sill.thick + 0.06, depth + sill.proud),
						at(h.a1 + 0.35, h.y0 + 0.06, 0.02),
						sill.look
					)
				)
			end
		end
	end
	return out
end

-- A railing: an invisible part min..max carrying the punched overlay on `faces` (named as on the front, mirrored with
-- the site), its tiles `bar` studs wide and taller than the part, so only each tile's solid top band and the edges
-- between the openings show: a top rail over square bars (wrought iron, white pipe and picket rails, a veranda's
-- balusters). No collisions and no shadow. 1 part.
function Kit.railing(
	m: Model,
	name: string,
	min: Vector3,
	max: Vector3,
	faces: { Enum.NormalId },
	color: Color3,
	bar: number?
): PartSpec
	local spec = Kit.detail(m, name, min, max, Kit.look(color, Enum.Material.Metal, 0, 1))
	local tall = math.abs(max.Y - min.Y)
	local textures: { TextureSpec } = {}
	for _, face in faces do
		table.insert(textures, {
			face = Kit.face(m, face),
			image = City.textures.punched,
			u = bar or 1.1,
			v = math.max(6, tall * 1.8),
			color = color,
		})
	end
	spec.textures = textures
	return spec
end

---------------------------------------------------------------------------------------------------------------
-- Checks (Dev/City/CityBuilder and tests/City.spec)
---------------------------------------------------------------------------------------------------------------

-- A part's box in the site's frame: its lowest and highest corner (the whole box, whatever its shape).
function Kit.localBounds(frame: CFrame, spec: PartSpec): (Vector3, Vector3)
	local half = spec.size / 2
	local lo, hi = Vector3.one * math.huge, -Vector3.one * math.huge
	local inv = frame:Inverse() * spec.cframe
	for _, sx in { -1, 1 } do
		for _, sy in { -1, 1 } do
			for _, sz in { -1, 1 } do
				local p = inv * Vector3.new(sx * half.X, sy * half.Y, sz * half.Z)
				lo, hi = lo:Min(p), hi:Max(p)
			end
		end
	end
	return lo, hi
end

local function finite(v: Vector3): boolean
	return v.X == v.X
		and v.Y == v.Y
		and v.Z == v.Z
		and math.abs(v.X) < math.huge
		and math.abs(v.Y) < math.huge
		and math.abs(v.Z) < math.huge
end

-- Why a spec is unfit to build, or nil.
function Kit.problem(spec: PartSpec): string?
	if not finite(spec.size) or spec.size.X <= 0 or spec.size.Y <= 0 or spec.size.Z <= 0 then
		return `{spec.name}: size {spec.size}`
	end
	if spec.size.X > 2048 or spec.size.Y > 2048 or spec.size.Z > 2048 then
		return `{spec.name}: larger than a part may be`
	end
	if not finite(spec.cframe.Position) then
		return `{spec.name}: bad position`
	end
	if spec.transparency < 0 or spec.transparency > 1 then
		return `{spec.name}: transparency {spec.transparency}`
	end
	local reflectance = spec.reflectance or 0
	if reflectance < 0 or reflectance > 1 then
		return `{spec.name}: reflectance {reflectance}`
	end
	if
		spec.shape == "ball"
		and (math.abs(spec.size.X - spec.size.Y) > EPS or math.abs(spec.size.Y - spec.size.Z) > EPS)
	then
		return `{spec.name}: a ball with unequal sizes`
	end
	if not spec.collide and (spec.query or spec.touch) then
		return `{spec.name}: decor that takes raycasts or touches`
	end
	if spec.tag == NIGHT.tag then
		local attributes: { [string]: any } = spec.attributes or {}
		local kind = attributes[NIGHT.kindAttribute]
		if type(kind) ~= "string" or NIGHT.kinds[kind] == nil then
			return `{spec.name}: night light of unknown kind {tostring(kind)}`
		end
	end
	return nil
end

return Kit
