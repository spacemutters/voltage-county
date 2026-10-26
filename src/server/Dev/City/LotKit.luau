--!strict
-- What the open-plot lots share (Config/CityLots; the lot types in Dev/City/Archetypes/lots): the parts a lot may
-- spend, its floor, lamps whose glass heads glow at night, painted lines and grids laid on the floor as see-through
-- textured parts, wheel stops, props from Config/CityProps, mesh palms and planters. Pure, like Dev/City/Kit: every
-- helper adds specs to the model and returns them, named after the site (the prefix) and filed in its model.
-- Coordinates are the site's own (x along the road, y up from the ground, z away from the road: the front line is
-- z = -depth/2), mirrored with the site like Kit's.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local City = require(ReplicatedStorage.Shared.Config.City)
local CityLots = require(ReplicatedStorage.Shared.Config.CityLots)
local CityProps = require(ReplicatedStorage.Shared.Config.CityProps)
local CityScenery = require(ReplicatedStorage.Shared.Config.CityScenery)
local Kit = require(script.Parent.Kit)
local Palms = require(script.Parent.Scenery.Palms)
local Props = require(script.Parent.Props)
local Types = require(script.Parent.Types)

type Model = Types.Model
type PartSpec = Types.PartSpec
type TextureSpec = Types.TextureSpec

-- One parking stall for the parked cars (Dev/City/Street Parking.fillStalls): its centre on the lot's floor, turned so
-- its LookVector points at the stall's head (where a nosed-in car's nose goes), and its width and length in studs.
export type Stall = { cframe: CFrame, size: Vector2 }

export type LampStyle = "globe" | "lantern" | "shoebox" | "twin" | "flood"

local FLOOR = CityLots.floor
local LINE_THICK = 0.04 -- painted lines: a see-through part this thick, just over the floor
local LINE_LIFT = 0.02

local LotKit = {}

LotKit.top = FLOOR.top
LotKit.bottom = FLOOR.bottom

-- The images a lot draws with (Config/City textures, Config/CityScenery crosswalks): one thin line along the bottom
-- of each tile (stall dividers, court lines), a grid with a band per tile (pavers), bars half a tile wide (wheel
-- stops, painted ground, mural stripes) and a wall with one opening per tile (a concrete frame going up).
LotKit.images = {
	line = City.textures.slabLine,
	grid = City.textures.windowFine,
	bold = City.textures.windowBold,
	bars = CityScenery.crosswalks.image or City.textures.slabLine,
	punched = City.textures.punched,
}

local function mx(m: Model, x: number): number
	return if m.mirror then -x else x
end

-- Adds a spec made outside the kit (props, palms) to the model, refusing a second part of one name like Kit.part.
local function add(m: Model, spec: PartSpec): PartSpec
	if m.names[spec.name] then
		error(`LotKit: two parts named {spec.name}`, 3)
	end
	m.names[spec.name] = true
	table.insert(m.specs, spec)
	return spec
end

-- The site's yaw in the world (its frame turns only about y).
local function yawOf(m: Model): number
	local _, yaw, _ = m.frame:ToEulerAnglesYXZ()
	return yaw
end

-- The `n`th of `list` (1-based, wrapping), for variant picks.
function LotKit.pick<T>(list: { T }, n: number): T
	return list[(math.max(1, math.floor(n)) - 1) % #list + 1]
end

---------------------------------------------------------------------------------------------------------------
-- The part allowance
---------------------------------------------------------------------------------------------------------------

-- The parts this lot may spend (Config/CityLots parts): its district's base, plus perHundred for every 100 studs of
-- frontage it takes (its width and the gap to its neighbours), never past its archetype's budget. A lot builds its
-- core whatever this says, then its extras in order while they fit.
function LotKit.allowance(site: Types.Site): number
	local rate = CityLots.parts[site.district] or CityLots.defaultRate
	local want = math.floor(rate.base + rate.perHundred * (site.width + City.siteGap) / 100 + 0.5)
	local config = City.archetypes[site.archetype]
	local most = if config then config.budget else want
	return math.clamp(want, 1, math.max(1, most))
end

-- Whether `cost` more parts stay within `limit`.
function LotKit.fits(m: Model, limit: number, cost: number): boolean
	return #m.specs + cost <= limit
end

---------------------------------------------------------------------------------------------------------------
-- Floors, lines and textures
---------------------------------------------------------------------------------------------------------------

-- A floor slab over x0..x1, z0..z1 from under the ground up to the lot's floor (or `top`). It collides, so a car or a
-- player stands on it. 1 part.
function LotKit.floor(
	m: Model,
	name: string,
	x0: number,
	z0: number,
	x1: number,
	z1: number,
	look: Kit.Look,
	top: number?
): PartSpec
	return Kit.box(m, name, Vector3.new(x0, FLOOR.bottom, z0), Vector3.new(x1, top or FLOOR.top, z1), look)
end

-- Tiles `image` over faces of `spec` (its top by default), `u` x `v` studs a tile, tinted `color`; `transparency` fades
-- it into the part (worn paint, subtle paver joints).
function LotKit.texture(
	m: Model,
	spec: PartSpec,
	image: string,
	u: number,
	v: number,
	color: Color3,
	faces: { Enum.NormalId }?,
	offsetU: number?,
	transparency: number?
)
	local list: { TextureSpec } = spec.textures or {}
	for _, face in faces or { Enum.NormalId.Top } do
		table.insert(list, {
			face = Kit.face(m, face),
			image = image,
			u = u,
			v = v,
			offsetU = offsetU,
			color = color,
			transparency = transparency,
		})
	end
	spec.textures = list
end

-- A festoon of lights from (x0, z0) to a pole at (x1, z1): the pole (`pole` its colour, `poleTop` high) and two thin
-- strands from `from` studs up at the first end to just under the pole's top, sagging festoon.sag under the straight
-- line at the middle (Config/CityLots festoon). A dark cable by day, a warm glow at night (Config/Environment
-- nightLights kind "window"), the first strand casting a warm light on what is under it. Keep it short (festoon.span):
-- a long strand reads as a pipe, not a string of lights. 3 parts.
function LotKit.festoon(
	m: Model,
	name: string,
	x0: number,
	z0: number,
	from: number,
	x1: number,
	z1: number,
	poleTop: number,
	pole: Color3
): { PartSpec }
	local f = CityLots.festoon
	local post = Kit.column(m, name .. "Pole", x1, z1, -0.5, poleTop, 0.4, Kit.look(pole, Enum.Material.Metal), "box")
	local a = Vector3.new(x0, from, z0)
	local b = Vector3.new(x1, poleTop - 0.2, z1)
	local low = (a + b) / 2 - Vector3.new(0, f.sag, 0)
	local cable = Kit.look(f.cable, Enum.Material.Glass, 0.1, 0)
	local first = Kit.strut(m, name, a, low, f.thick, cable, "detail")
	local second = Kit.strut(m, name .. "2", low, b, f.thick, cable, "detail")
	first.light = {
		kind = "point",
		brightness = f.glow.brightness,
		range = f.glow.range,
		angle = 0,
		color = f.glow.color,
		face = Enum.NormalId.Top,
		enabled = false,
	}
	Kit.lit(first, "window", CityLots.lampColors.warm)
	Kit.lit(second, "window", CityLots.lampColors.warm)
	return { post, first, second }
end

-- Painted lines: a see-through part over x0..x1, z0..z1 just above the floor (or `y`) carrying `image` (default a thin
-- line per tile) on its top, a line every `every` studs. `across`: the lines run across the road (along z) and step
-- along x, as stall dividers do; otherwise they run along the road and step along z. 1 part.
function LotKit.lines(
	m: Model,
	name: string,
	x0: number,
	z0: number,
	x1: number,
	z1: number,
	every: number,
	color: Color3,
	across: boolean,
	image: string?,
	y: number?
): PartSpec
	local lx, hx = math.min(x0, x1), math.max(x0, x1)
	local lz, hz = math.min(z0, z1), math.max(z0, z1)
	local base = (y or FLOOR.top) + LINE_LIFT
	local look = Kit.look(color, Enum.Material.SmoothPlastic, 0, 1)
	local spec: PartSpec
	if across then
		-- Turned a quarter, so the image's lines (along the part's own x) run along the site's z.
		local c = Vector3.new((lx + hx) / 2, base + LINE_THICK / 2, (lz + hz) / 2)
		spec = Kit.oriented(
			m,
			name,
			"block",
			CFrame.new(c) * CFrame.Angles(0, math.pi / 2, 0),
			Vector3.new(hz - lz, LINE_THICK, hx - lx),
			look,
			"detail"
		)
	else
		spec = Kit.detail(m, name, Vector3.new(lx, base, lz), Vector3.new(hx, base + LINE_THICK, hz), look)
	end
	spec.textures = {
		{
			face = Enum.NormalId.Top,
			image = image or LotKit.images.line,
			u = if across then hz - lz else hx - lx,
			v = every,
			color = color,
		},
	}
	return spec
end

-- Wheel stops along x0..x1 with their middle at z: one block every `every` studs (half of it, a gap between), drawn
-- as the bars image on the top and both long faces of one see-through bar. 1 part.
function LotKit.stops(m: Model, name: string, x0: number, x1: number, z: number, every: number, color: Color3): PartSpec
	local spec = Kit.detail(
		m,
		name,
		Vector3.new(x0, FLOOR.top, z - 0.35),
		Vector3.new(x1, FLOOR.top + 0.5, z + 0.35),
		Kit.look(color, Enum.Material.Concrete, 0, 1)
	)
	LotKit.texture(
		m,
		spec,
		LotKit.images.bars,
		every,
		1,
		color,
		{ Enum.NormalId.Top, Enum.NormalId.Front, Enum.NormalId.Back },
		every / 4
	)
	return spec
end

---------------------------------------------------------------------------------------------------------------
-- Lamps
---------------------------------------------------------------------------------------------------------------

-- A lamp at (x, z) whose head tops out at `top`: a pole a car hits (`pole` its colour) and a glass head that glows at
-- night (Config/Environment nightLights kind "window", in the warm lamp colour or, with `cool`, the floodlights'):
--   globe     a round glass globe on a slim post (plazas, parks)
--   lantern   a square glass lantern (markets, food courts)
--   shoebox   a flat head reaching out toward -z (car parks)
--   twin      a bar with a head out each way along x (wide car parks)
--   flood     a glass panel facing -z (courts)
-- 2 parts.
function LotKit.lamp(
	m: Model,
	name: string,
	x: number,
	z: number,
	top: number,
	style: LampStyle,
	pole: Color3,
	cool: boolean?
): { PartSpec }
	local colors = CityLots.lampColors
	local glass = Kit.look(Color3.fromRGB(226, 232, 232), Enum.Material.Glass, 0.15, 0)
	local head: PartSpec
	local poleTop: number
	local diameter: number
	if style == "globe" then
		local d = 1.8
		head = Kit.ball(m, name .. "Globe", Vector3.new(x, top - d / 2, z), d, glass, "detail")
		poleTop, diameter = top - d + 0.15, 0.4
	elseif style == "lantern" then
		head = Kit.detail(
			m,
			name .. "Lantern",
			Vector3.new(x - 0.7, top - 2, z - 0.7),
			Vector3.new(x + 0.7, top, z + 0.7),
			glass
		)
		poleTop, diameter = top - 2, 0.4
	elseif style == "twin" then
		head = Kit.detail(
			m,
			name .. "Head",
			Vector3.new(x - 3, top - 0.5, z - 0.7),
			Vector3.new(x + 3, top, z + 0.7),
			glass
		)
		poleTop, diameter = top - 0.5, 0.6
	elseif style == "flood" then
		head = Kit.detail(
			m,
			name .. "Head",
			Vector3.new(x - 1.8, top - 2.4, z - 0.9),
			Vector3.new(x + 1.8, top, z - 0.3),
			glass
		)
		poleTop, diameter = top - 2.4, 0.7
	else
		head = Kit.detail(
			m,
			name .. "Head",
			Vector3.new(x - 0.7, top - 0.5, z - 3),
			Vector3.new(x + 0.7, top, z + 0.4),
			glass
		)
		poleTop, diameter = top - 0.5, 0.55
	end
	Kit.lit(head, "window", if cool then colors.cool else colors.warm)
	local post =
		Kit.column(m, name .. "Pole", x, z, -0.5, poleTop, diameter, Kit.look(pole, Enum.Material.Metal), "box")
	return { post, head }
end

---------------------------------------------------------------------------------------------------------------
-- Props, palms and planters
---------------------------------------------------------------------------------------------------------------

-- Prop `prop` (Config/CityProps) standing on the floor at (x, z), turned `yaw` degrees (0: its front to the road; 90:
-- to -x; 180: away from the road; -90: to +x), in the box `size` (default the prop's own). It is moved in to stay on
-- the site and scaled down when the site is smaller (or lower) than its box. `collide` adds the invisible box a car or
-- a player bumps into (the prop's collider share of its box, when it has one). Returns its specs, the prop first.
function LotKit.prop(
	m: Model,
	name: string,
	prop: string,
	x: number,
	z: number,
	yaw: number,
	size: Vector3?,
	collide: boolean?
): { PartSpec }
	local info = CityProps.props[prop]
	if info == nil then
		error(`LotKit: no prop {prop} in Config/CityProps`, 2)
	end
	local site = m.site
	local box = size or info.size
	local room = site.maxHeight - FLOOR.top - 0.05
	if box.Y > room then
		box *= room / box.Y
	end
	local r = math.rad(yaw)
	local c, s = math.abs(math.cos(r)), math.abs(math.sin(r))
	local ex = c * box.X / 2 + s * box.Z / 2
	local ez = s * box.X / 2 + c * box.Z / 2
	local hw, hd = site.width / 2 - 0.1, site.depth / 2 - 0.1
	if ex > hw or ez > hd then
		local k = math.min(hw / ex, hd / ez)
		box *= k
		ex *= k
		ez *= k
	end
	local px = math.clamp(x, -hw + ex, hw - ex)
	local pz = math.clamp(z, -hd + ez, hd - ez)
	local turn = if m.mirror then -r else r
	local function at(height: number): CFrame
		return m.frame * CFrame.new(mx(m, px), FLOOR.top + height / 2, pz) * CFrame.Angles(0, turn, 0)
	end
	local spec = add(m, Props.spec(m.folder, m.prefix .. name, prop, at(box.Y), box, "building"))
	local out = { spec }
	if collide then
		local bump = LotKit.collider(m, name .. "Box", spec, prop)
		if bump then
			table.insert(out, bump)
		end
	end
	return out
end

-- The invisible box a car or a player bumps into for a prop LotKit.prop placed (`spec`, a `prop` of Config/CityProps):
-- the prop's collider share of its box, standing on the same floor, turned with it. 1 part, or none when the prop has
-- no collider share.
function LotKit.collider(m: Model, name: string, spec: PartSpec, prop: string): PartSpec?
	local info = CityProps.props[prop]
	local share = if info then info.collider else nil
	if share == nil then
		return nil
	end
	local box = spec.size
	local bump = Vector3.new(box.X * share.X, box.Y * share.Y, box.Z * share.Z)
	return add(m, {
		folder = m.folder,
		name = m.prefix .. name,
		class = "Part",
		shape = "block",
		role = "building",
		size = bump,
		cframe = spec.cframe * CFrame.new(0, (bump.Y - box.Y) / 2, 0),
		color = Color3.fromRGB(128, 128, 128),
		material = Enum.Material.SmoothPlastic,
		collide = true,
		query = true,
		touch = false,
		shadow = false,
		transparency = 1,
	})
end

-- A mesh palm (Config/CityScenery palms; the build clones it) with its foot on the floor at (x, z): `want` studs tall
-- when its crown stays on the site and under the site's maxHeight, shorter when not, and nothing when even
-- CityLots.palmMin of its size won't fit. `turn` (0..3) turns it a quarter at a time and picks its variant. 2 parts (the
-- trunk a car hits, the crown).
function LotKit.palm(
	m: Model,
	name: string,
	species: string,
	x: number,
	z: number,
	want: number,
	turn: number
): { PartSpec }
	local info = Palms.species[species]
	if info == nil then
		error(`LotKit: no palm species {species}`, 2)
	end
	local site = m.site
	local sink = info.sink or CityScenery.palms.sink
	local edge = math.min(site.width / 2 - math.abs(x), site.depth / 2 - math.abs(z)) - 0.3
	local s = math.min(
		want / info.height,
		(site.maxHeight - 0.1 - FLOOR.top + sink) / (info.crownTo * info.height),
		2 * edge / info.crown,
		info.scale[2]
	)
	if s < CityLots.palmMin then
		return {}
	end
	local foot = m.frame * Vector3.new(mx(m, x), FLOOR.top, z)
	local trunk, crown = Palms.specs(
		m.folder,
		m.prefix .. name,
		"building",
		species,
		foot,
		yawOf(m) + (turn % 4) * math.pi / 2,
		{ scale = 0, yaw = 0, lean = 0, variant = (turn % 2) * 0.99 },
		{ s, s }
	)
	return { add(m, trunk), add(m, crown) }
end

-- A planter box w x d centred at (x, z) with the clump plant mesh (Config/CityScenery furniture.planter) growing out
-- of it. 2 parts.
function LotKit.planter(m: Model, name: string, x: number, z: number, w: number, d: number, color: Color3): { PartSpec }
	local p = CityScenery.furniture.planter
	local h = p.size.Y
	local pot = Kit.trim(
		m,
		name,
		Vector3.new(x - w / 2, FLOOR.top - 0.2, z - d / 2),
		Vector3.new(x + w / 2, FLOOR.top + h, z + d / 2),
		Kit.look(color, Enum.Material.Concrete)
	)
	local foot = m.frame * Vector3.new(mx(m, x), FLOOR.top + h, z)
	local plant = Palms.plant(m.folder, `{m.prefix}{name}Plant`, p.plant, foot, yawOf(m), p.plantHeight, math.min(w, d))
	plant.role = "building"
	return { pot, add(m, plant) }
end

-- A stall's world frame and size (see Stall): its centre at (x, z) on the floor, its head toward `head` ("back": +z,
-- "front": -z).
function LotKit.stall(m: Model, x: number, z: number, width: number, length: number, head: "back" | "front"): Stall
	local centre = m.frame * Vector3.new(mx(m, x), FLOOR.top, z)
	local toward = m.frame * Vector3.new(mx(m, x), FLOOR.top, z + (if head == "back" then 1 else -1))
	return { cframe = CFrame.lookAt(centre, toward), size = Vector2.new(width, length) }
end

return LotKit
