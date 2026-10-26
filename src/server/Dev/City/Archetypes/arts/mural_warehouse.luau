--!strict
-- W01 mural_warehouse (docs/city/ARCHETYPES.md §8, W01): the arts district's workhorse. A plain one-storey
-- concrete-block warehouse under a steel coping, its whole street wall one giant original supergraphic painted in
-- flat panels that step a hair proud of each other, so every shape has a crisp edge in the sun. Coloured roll-up
-- doors under steel coil hoods stand at one end, one of them up on a truck dock under a cantilevered canopy hung on
-- tie rods, inside a block of colour whose top rises toward the painting; a glass shop door with an awning and a
-- painted name sign at the other end; the painting's hero fills the wall between them, full height. A dark base
-- course and a paved apron. The roof is one of four: a stepped front parapet with roof units, a sawtooth of
-- north-light glass, a rooftop bar with a pergola, market umbrellas and string lights, or a barrel vault behind a
-- stepped gable (the quarry's hangars).
--
-- What makes it itself: the whole street wall is one painting you read at 70 mph (a lightning bolt over a striped
-- sun, speed chevrons, a sunburst over two peaks, or Memphis blocks with a zigzag), wrapping round the corner.
-- Night: the mural's hero shape glows (the bolt and the sun amber, the chevron and the zigzag in the palette's
-- neon), the shop door and the sawtooth glass are lit, the bar's string lights glow, and some copies wash the wall.
-- Placement, sizes, heights and its budget: Config/City archetypes.mural_warehouse.
-- Variants: palette (5 mural palettes: wall, three paints, ink, door, neon; the paints are shuffled per copy),
-- crown (1 stepped parapet and roof units, 2 sawtooth roof, 3 rooftop bar, 4 barrel vault), rhythm (the mural:
-- 1 bolt over a striped sun, 2 chevrons, 3 sunburst, 4 Memphis blocks), mirror (doors, dock and mural swap ends).
-- Sizes: a narrow site (wall under 34) is a studio with only the shop door; 34 to 40 adds a drive-in door, 40 to 58
-- a truck dock instead, wider both.
--
-- Previewing: from the street at eye height and from a corner. Check the hero reads whole between the doors and
-- the shop door (no shape clipped by the coping or poking past the wall's ends), the doors stand clear of their
-- colour block, the dock canopy's rods meet the wall below the coping on a 20-stud building, the sawtooth's glass
-- faces the street over the parapet, the barrel's gable steps meet its curve with no daylight between, and at night
-- the hero shape glows without swamping the wall.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local City = require(ReplicatedStorage.Shared.Config.City)
local Kit = require(script.Parent.Parent.Parent.Kit)
local Types = require(script.Parent.Parent.Parent.Types)

type PartSpec = Types.PartSpec

local P = City.palettes
local KIT = City.kit
local rgb = Color3.fromRGB

-- The recipe, in studs.
local SHAPE = {
	apron = 8, -- the paved front between the front line and the wall (the dock stands on it)
	sideInset = 0.9,
	bodyDepth = 40, -- at most
	coping = { thick = 0.9, proud = 0.55 },
	base = { tall = 2.2, proud = 0.25 }, -- the dark base course round the foot
	paint = 0.06, -- each mural piece stands this much proud of the one painted before it
	paintBack = 0.25, -- mural pieces reach this far into the wall, so no face lies on the wall's
	margin = 0.6, -- the mural keeps this far inside the wall's ends, the coping and the base course
	doorFront = 0.9, -- doors, the shop glass and the sign stand this far proud of the wall: clear of every paint layer
	door = { wide = { 0.26, 9.5, 12 }, tall = 13 }, -- share of the wall's width, clamped; the drive-in door's height
	driveFrom = 34, -- a wall this wide has a drive-in door...
	dockFrom = 40, -- ...this wide a truck dock instead...
	bothFrom = 58, -- ...and this wide both
	heroMin = 9.5, -- the hero takes the wall between the doors and the shop door when it is this wide (and a
	-- quarter of the mural); else the whole wall
	dockDoor = { 7.5, 10.5 }, -- the dock door's height above the dock
	hood = { tall = 1.8, proud = 1.7, over = 0.7 }, -- the steel coil box over each roll-up door
	dock = { tall = 4.2, deep = 5, over = 1.5 }, -- truck-bed height
	canopy = { thick = 0.6, deep = 6.5, over = 1.2, rise = 4 }, -- its tie rods meet the wall `rise` over it
	field = { over = 2.5, rise = 7 }, -- the colour blocks round the doors and the shop door: this far over their gear
	-- and sign, their tops rising toward the hero
	entry = { wide = 7, tall = 9 },
	awning = { thick = 0.5, proud = 3.2 },
	sign = 2.4,
	bollard = { tall = 3.6, wide = 0.9 },
	wrap = 12, -- the mural turns the corner this far down the side
	step = { tall = 3.4, share = 0.42 }, -- crown 1: the raised centre of the front parapet
	tooth = { tall = 5.6, deep = 10 }, -- crown 2: the sawtooth roof
	bar = { pergola = 9, umbrella = 7, rail = 3.2 }, -- crown 3: the rooftop bar
	-- crown 4: a barrel vault; its rise is this share of the width, clamped; steps of the gable as shares of the span
	barrel = { rise = 0.16, min = 3.5, max = 10, planks = 6, thick = 0.8, steps = { 0.86, 0.6, 0.32 } },
	washChance = 0.45,
}

local PAINT = {
	pink = rgb(255, 79, 154),
	blue = rgb(45, 107, 255),
	yellow = rgb(255, 210, 63),
	mint = rgb(65, 211, 166),
	orange = rgb(255, 122, 47),
	violet = rgb(123, 77, 255),
	black = rgb(27, 27, 31),
	white = rgb(246, 244, 238),
}

-- The wall (the whole body is one flat colour), three paints, the ink (outlines, shadows), the doors, the coping and
-- the neon kind of the mural's lit shape.
type Palette = {
	wall: Color3,
	paints: { Color3 },
	ink: Color3,
	door: Color3,
	cap: Color3,
	neon: string,
}
local PALETTES: { Palette } = {
	{
		wall = PAINT.white,
		paints = { PAINT.pink, PAINT.blue, PAINT.yellow },
		ink = PAINT.black,
		door = PAINT.blue,
		cap = rgb(52, 56, 62),
		neon = "neonPink",
	},
	{
		wall = PAINT.black,
		paints = { PAINT.yellow, PAINT.mint, PAINT.pink },
		ink = PAINT.white,
		door = PAINT.mint,
		cap = PAINT.white,
		neon = "neonCyan",
	},
	{
		wall = PAINT.blue,
		paints = { PAINT.orange, PAINT.white, PAINT.yellow },
		ink = PAINT.black,
		door = PAINT.orange,
		cap = PAINT.white,
		neon = "neonPink",
	},
	{
		wall = PAINT.yellow,
		paints = { PAINT.violet, PAINT.pink, PAINT.white },
		ink = PAINT.black,
		door = PAINT.violet,
		cap = rgb(52, 56, 62),
		neon = "neonViolet",
	},
	{
		wall = PAINT.mint,
		paints = { PAINT.pink, PAINT.violet, PAINT.white },
		ink = PAINT.black,
		door = PAINT.black,
		cap = PAINT.white,
		neon = "neonPink",
	},
}

local RAIL = Kit.look(rgb(214, 236, 242), Enum.Material.Glass, 0.1, KIT.railTransparency)
local STEEL = Kit.look(rgb(190, 194, 198), Enum.Material.Metal)
local SAFETY = Kit.look(rgb(255, 196, 40), Enum.Material.SmoothPlastic)
local STRING = rgb(255, 222, 160)
local WASH = rgb(255, 222, 186)

-- By rhythm: which of the three paints the colour block round the doors takes (the one the hero leans on least).
local FIELD = { 2, 1, 3, 3 }

local function share(width: number, rule: { number }): number
	return math.clamp(width * rule[1], rule[2], rule[3])
end

local function build(m: Types.Model)
	local site = m.site
	local variant = site.variant
	local pal = PALETTES[math.clamp(variant.palette, 1, #PALETTES)]
	local rng = Kit.rng(m)
	local W, D, H = site.width, site.depth, site.height
	local hw, hd = W / 2, D / 2
	local x0, x1 = -hw + SHAPE.sideInset, hw - SHAPE.sideInset
	local zF = -hd + SHAPE.apron
	local zB = math.min(hd - 1, zF + SHAPE.bodyDepth)
	local wallTop = H - SHAPE.coping.thick
	local back = zF + SHAPE.paintBack

	-- The three paints in this copy's order.
	local paints = table.clone(pal.paints)
	for i = #paints, 2, -1 do
		local j = rng:NextInteger(1, i)
		paints[i], paints[j] = paints[j], paints[i]
	end

	local wallLook = Kit.look(pal.wall, Enum.Material.SmoothPlastic)
	local capLook = Kit.look(pal.cap, Enum.Material.SmoothPlastic)
	local concrete = Kit.look(P.concrete.pale, Enum.Material.Concrete)
	local dark = Kit.look(P.concrete.dark, Enum.Material.SmoothPlastic)
	local inkLook = Kit.look(pal.ink, Enum.Material.SmoothPlastic)

	-------------------------------------------------------------------------------------------------------
	-- Body: one painted block, a steel coping, a dark base course round the foot, a paved apron
	-------------------------------------------------------------------------------------------------------
	Kit.box(m, "Body", Vector3.new(x0, -KIT.bury, zF), Vector3.new(x1, wallTop + 0.05, zB), wallLook)
	local cp = SHAPE.coping.proud
	Kit.trim(m, "Coping", Vector3.new(x0 - cp, wallTop, zF - cp), Vector3.new(x1 + cp, H, zB + cp), capLook)
	local bp = SHAPE.base.proud
	Kit.trim(m, "Base", Vector3.new(x0 - bp, -0.5, zF - bp), Vector3.new(x1 + bp, SHAPE.base.tall, zB + bp), dark)
	Kit.box(m, "Apron", Vector3.new(-hw + 0.2, -0.6, -hd + 0.3), Vector3.new(hw - 0.2, 0.18, zF + 0.5), concrete)

	-------------------------------------------------------------------------------------------------------
	-- The street front's layout, worked out before the paint so the hero keeps clear of the doors: a truck
	-- dock and a drive-in door at one end, the shop door and its sign at the other
	-------------------------------------------------------------------------------------------------------
	local span = x1 - x0
	local doorW = share(span, SHAPE.door.wide)
	local hasDock = span >= SHAPE.dockFrom
	local hasDrive = (span >= SHAPE.driveFrom and not hasDock) or span >= SHAPE.bothFrom
	local hood, dk, cn = SHAPE.hood, SHAPE.dock, SHAPE.canopy
	local dockTall = math.clamp(wallTop - 3.2 - dk.tall - hood.tall - 0.9, SHAPE.dockDoor[1], SHAPE.dockDoor[2])
	local driveTall = math.min(SHAPE.door.tall, wallTop - hood.tall - 2.5)
	local cursor = x0 + 2.5
	local dockX, driveX = 0, 0
	local gearTop = 0 -- the top of the doors' hoods and the dock's canopy
	if hasDock then
		dockX = cursor + dk.over + doorW / 2
		cursor = dockX + doorW / 2 + dk.over + 3
		gearTop = dk.tall + dockTall + hood.tall + 0.9 + cn.thick
	end
	if hasDrive then
		driveX = cursor + doorW / 2
		cursor = driveX + doorW / 2 + 3
		gearTop = math.max(gearTop, 0.2 + driveTall + hood.tall)
	end
	local hasDoors = hasDock or hasDrive
	local doorsEnd = cursor - 1.5
	local en = SHAPE.entry
	local ex = math.max(x1 - 2.5 - en.wide / 2, cursor - 1 + en.wide / 2)
	local signHalf = math.min(7, x1 - 1 - ex, ex - (cursor - 2))
	local entryLeft = ex - math.max(signHalf, en.wide / 2 + 1) - 0.8

	-------------------------------------------------------------------------------------------------------
	-- The mural: flat paint pieces, each a hair proud of the last, inside the wall's margins
	-------------------------------------------------------------------------------------------------------
	local mx0, mx1 = x0 + SHAPE.margin, x1 - SHAPE.margin
	local my0, my1 = SHAPE.base.tall + SHAPE.margin * 0.5, wallTop - SHAPE.margin
	local MW, MH = mx1 - mx0, my1 - my0
	-- The hero's box: the wall between the doors and the shop door, full height, when that is wide enough; else the
	-- whole mural (the doors then stand in front of part of it).
	local hx0, hx1 = math.max(mx0, (if hasDoors then doorsEnd else x0) + 0.8), math.min(mx1, entryLeft)
	local inGap = hx1 - hx0 >= math.max(SHAPE.heroMin, MW * 0.24)
	if not inGap then
		hx0, hx1 = mx0, mx1
	end
	local HW = hx1 - hx0
	local layer = 0
	local function nextPlane(): number
		layer += 1
		return zF - SHAPE.paint * layer
	end
	local function paint(color: Color3): Kit.Look
		return Kit.look(color, Enum.Material.SmoothPlastic)
	end
	-- An upright rectangle of paint.
	local function panel(name: string, ax: number, ay: number, bx: number, by: number, color: Color3): PartSpec
		return Kit.detail(m, name, Vector3.new(ax, ay, nextPlane()), Vector3.new(bx, by, back), paint(color))
	end
	-- A stroke of paint from (ax, ay) to (bx, by), `width` across; its ends run on half its width so strokes meet
	-- without notches. A near-upright stroke is an upright rectangle.
	local function stroke(
		name: string,
		ax: number,
		ay: number,
		bx: number,
		by: number,
		width: number,
		color: Color3
	): PartSpec
		local dir = Vector2.new(bx - ax, by - ay).Unit
		if math.abs(dir.Y) > 0.97 then
			return panel(name, ax - width / 2, math.min(ay, by), ax + width / 2, math.max(ay, by), color)
		end
		local front = nextPlane()
		local z = (front + back) / 2
		local run = dir * (width / 2)
		local a = Vector3.new(ax - run.X, ay - run.Y, z)
		local b = Vector3.new(bx + run.X, by + run.Y, z)
		return Kit.strut(m, name, a, b, width, paint(color), "detail", back - front)
	end
	-- A round of paint.
	local function disc(name: string, cx: number, cy: number, diameter: number, color: Color3): PartSpec
		local front = nextPlane()
		return Kit.tube(
			m,
			name,
			Vector3.new(cx, cy, front),
			Vector3.new(cx, cy, back),
			diameter,
			paint(color),
			"detail"
		)
	end
	-- A triangle with a level base from ax to bx, its apex over apexX at height top: two halves on one plane.
	local function peak(name: string, ax: number, bx: number, apexX: number, base: number, top: number, color: Color3)
		local front = nextPlane()
		local look = paint(color)
		Kit.triangle(m, name .. "L", ax, base, apexX, top, front, back - front, "x1y0", look, "detail")
		Kit.triangle(m, name .. "R", apexX, base, bx, top, front, back - front, "x0y0", look, "detail")
	end

	local rhythm = math.clamp(variant.rhythm, 1, 4)
	-- The colour blocks round the doors and round the shop door, never the doors' own colour, their tops rising toward
	-- the hero: with the hero between them the whole wall is painted.
	local fieldColor = paints[FIELD[rhythm]]
	if fieldColor == pal.door then
		fieldColor = paints[FIELD[rhythm] % #paints + 1]
	end
	local function field(name: string, fx0: number, fx1: number, top: number, corner: Kit.TriangleCorner)
		panel(name, fx0, my0, fx1, top, fieldColor)
		local rise = math.min(my1 - top, SHAPE.field.rise)
		if rise > 1 then
			local front = nextPlane()
			Kit.triangle(
				m,
				name .. "Top",
				fx0,
				top - 0.02,
				fx1,
				top + rise,
				front,
				back - front,
				corner,
				paint(fieldColor)
			)
		end
	end
	if inGap then
		if hasDoors then
			field("Field", mx0, math.min(hx0 + 0.4, mx1), math.min(gearTop + SHAPE.field.over, my1 - 2), "x1y0")
		end
		local signTop = en.tall + 1.6 + SHAPE.sign
		field("EntryField", math.max(hx1 - 0.4, mx0), mx1, math.min(signTop + SHAPE.field.over, my1 - 2), "x0y0")
	end

	local first = paints[1] -- the colour the mural turns the corner in
	if rhythm == 1 then
		-- A striped sun with a lightning bolt over it, the bolt casting a hard ink shadow; the bolt glows amber.
		local d = math.min(MH * 0.94, HW * 0.94)
		local r = d / 2
		local sx, sy = (hx0 + hx1) / 2, my0 + MH * 0.5
		disc("Sun", sx, sy, d, paints[1])
		for i, cut in { { 0.14, 0.07 }, { 0.4, 0.09 }, { 0.66, 0.11 } } do
			local top = sy - cut[1] * r
			local half = math.sqrt(math.max(r * r - (cut[1] * r) ^ 2, 0)) + 0.1
			panel(`Cut{i}`, sx - half, top - cut[2] * d, sx + half, top, pal.wall)
		end
		local bh, bw = MH * 0.88, math.min(MH * 0.52, HW * 0.62)
		local sw = math.max(2.2, bw * 0.24)
		local points = {
			Vector2.new(sx + 0.3 * bw, sy + 0.46 * bh),
			Vector2.new(sx - 0.24 * bw, sy + 0.03 * bh),
			Vector2.new(sx + 0.24 * bw, sy + 0.03 * bh),
			Vector2.new(sx - 0.3 * bw, sy - 0.46 * bh),
		}
		local drop = Vector2.new(0.8, -0.8)
		for _, pass in { "Shadow", "Bolt" } do
			for k = 1, 3 do
				local a, b = points[k], points[k + 1]
				if pass == "Shadow" then
					a, b = a + drop, b + drop
				end
				local width = if k == 2 then sw * 0.9 else sw
				local spec =
					stroke(`{pass}{k}`, a.X, a.Y, b.X, b.Y, width, if pass == "Bolt" then paints[3] else pal.ink)
				if pass == "Bolt" then
					Kit.lit(spec, "neonAmber")
				end
			end
		end
	elseif rhythm == 2 then
		-- A tall band of colour (the doors' block, or its own), an ink ground line, and three speed chevrons racing
		-- toward the shop door; the leading chevron glows.
		local cx0 = hx0
		if not inGap then
			panel("Band", mx0, my0, mx0 + MW * 0.36, my1, paints[1])
			cx0 = mx0 + MW * 0.42
		end
		panel("Ground", mx0, my0, mx1, my0 + MH * 0.09, pal.ink)
		local CW = hx1 - cx0
		local hh = MH * 0.38
		local cy = my0 + MH * 0.54
		local s = CW / 3.5
		local w = math.clamp(math.min(MH * 0.14, s * 0.42), 1.2, 4)
		local run = math.min(hh * 0.8, s * 0.8)
		local colours = { paints[2], paints[3], pal.ink }
		for i = 1, 3 do
			local tx = cx0 + CW * 0.08 + (i - 1) * s + run
			local up = stroke(`ChevronUp{i}`, tx - run, cy + hh, tx, cy, w, colours[i])
			local down = stroke(`ChevronDown{i}`, tx - run, cy - hh, tx, cy, w, colours[i])
			if i == 3 then
				Kit.lit(up, pal.neon)
				Kit.lit(down, pal.neon)
			end
		end
	elseif rhythm == 3 then
		-- A sunburst: rays behind an ink halo and a sun that glows amber, two peaks in front.
		local d = math.min(MH * 0.6, HW * 0.44)
		local sx, sy = hx0 + HW * 0.62, my0 + MH * 0.54
		local w = math.max(1.4, d * 0.12)
		for i, degrees in { -70, -35, 0, 35, 70 } do
			local t = math.rad(degrees)
			local dir = Vector2.new(math.sin(t), math.cos(t))
			-- As far as the hero's box allows, less the stroke's half width and its run-on.
			local reach = math.huge
			if dir.X > 1e-3 then
				reach = math.min(reach, (hx1 - w - sx) / dir.X)
			elseif dir.X < -1e-3 then
				reach = math.min(reach, (hx0 + w - sx) / dir.X)
			end
			reach = math.min(reach, (my1 - w - sy) / dir.Y)
			local tip = Vector2.new(sx, sy) + dir * math.max(reach, d * 0.6)
			stroke(`Ray{i}`, sx, sy, tip.X, tip.Y, w, if i % 2 == 1 then paints[2] else paints[1])
		end
		disc("Halo", sx, sy, d + 2 * math.max(1, d * 0.08), pal.ink)
		Kit.lit(disc("Sun", sx, sy, d, paints[1]), "neonAmber")
		peak("PeakBack", hx0, hx0 + HW * 0.56, hx0 + HW * 0.26, my0, my0 + MH * 0.5, pal.ink)
		peak("PeakFront", hx0 + HW * 0.3, hx0 + HW * 0.86, hx0 + HW * 0.56, my0, my0 + MH * 0.36, paints[2])
	else
		-- Memphis blocks: two overlapping slabs of colour, a ring, a triangle, and an ink zigzag that glows.
		panel("BlockA", hx0 + HW * 0.06, my0 + MH * 0.16, hx0 + HW * 0.44, my1 - MH * 0.06, paints[1])
		panel("BlockB", hx0 + HW * 0.34, my0 + MH * 0.06, hx0 + HW * 0.66, my0 + MH * 0.58, paints[2])
		local d = math.min(MH * 0.5, HW * 0.28)
		local rx, ry = hx0 + HW * 0.82, my0 + MH * 0.62
		disc("Ring", rx, ry, d, paints[3])
		disc("RingHole", rx, ry, d * 0.48, pal.wall)
		local front = nextPlane()
		Kit.triangle(
			m,
			"Triangle",
			hx0 + HW * 0.56,
			my0 + MH * 0.08,
			hx0 + HW * 0.94,
			my0 + MH * 0.46,
			front,
			back - front,
			"x0y0",
			paint(paints[1]),
			"detail"
		)
		local amp, step = MH * 0.07, HW * 0.065
		local zx, zy = hx0 + HW * 0.1, my1 - MH * 0.13
		for k = 1, 4 do
			local a = Vector2.new(zx + (k - 1) * step, zy + (if k % 2 == 1 then amp else -amp))
			local b = Vector2.new(zx + k * step, zy + (if k % 2 == 1 then -amp else amp))
			Kit.lit(stroke(`Zigzag{k}`, a.X, a.Y, b.X, b.Y, math.max(1, MH * 0.06), pal.ink), pal.neon)
		end
	end
	-- The painting turns the corner and runs a little way down the side.
	Kit.detail(
		m,
		"Wrap",
		Vector3.new(x0 - 0.12, my0, zF - 0.12),
		Vector3.new(x0 + 0.25, my1, zF + math.min(SHAPE.wrap, zB - zF - 2)),
		paint(first)
	)

	-------------------------------------------------------------------------------------------------------
	-- The street front: a truck dock and roll-up doors under steel hoods, the shop door, its awning and sign
	-------------------------------------------------------------------------------------------------------
	local doorFront = math.min(zF - SHAPE.doorFront, zF - SHAPE.paint * layer - 0.1)
	local doorLook = Kit.look(pal.door, Enum.Material.SmoothPlastic)
	-- The slats a shade darker, or lighter on a dark door.
	local lum = 0.3 * pal.door.R + 0.59 * pal.door.G + 0.11 * pal.door.B
	local slats = if lum < 0.2
		then pal.door:Lerp(Color3.new(1, 1, 1), 0.3)
		else pal.door:Lerp(Color3.new(0, 0, 0), 0.45)
	local function rollUp(name: string, cx: number, y0: number, tall: number)
		local door = Kit.detail(
			m,
			name,
			Vector3.new(cx - doorW / 2, y0, doorFront),
			Vector3.new(cx + doorW / 2, y0 + tall, back),
			doorLook
		)
		door.textures = {
			{
				face = Kit.face(m, Enum.NormalId.Front),
				image = City.textures.slabLine,
				u = doorW,
				v = 0.8,
				color = slats,
			},
		}
		Kit.trim(
			m,
			name .. "Hood",
			Vector3.new(cx - doorW / 2 - hood.over, y0 + tall, zF - hood.proud),
			Vector3.new(cx + doorW / 2 + hood.over, y0 + tall + hood.tall, back),
			STEEL
		)
	end

	if hasDock then
		local cx = dockX
		local left, right = cx - doorW / 2 - dk.over, cx + doorW / 2 + dk.over
		Kit.box(m, "Dock", Vector3.new(left, -KIT.bury, zF - dk.deep), Vector3.new(right, dk.tall, zF + 0.3), concrete)
		for i, side in { -1, 1 } do
			local bx = cx + side * (doorW / 2 - 0.6)
			Kit.detail(
				m,
				`Bumper{i}`,
				Vector3.new(bx - 0.6, 1, zF - dk.deep - 0.7),
				Vector3.new(bx + 0.6, 3.6, zF - dk.deep + 0.2),
				dark
			)
		end
		rollUp("DockDoor", cx, dk.tall + 0.02, dockTall)
		local cy = dk.tall + dockTall + hood.tall + 0.9
		local cz0 = zF - cn.deep
		Kit.canopy(m, "DockCanopy", left - cn.over, right + cn.over, cz0, back, cy, cn.thick, STEEL)
		local rodTop = math.min(cy + cn.thick + cn.rise, wallTop - 0.4)
		for i, x in { left - cn.over + 0.5, right + cn.over - 0.5 } do
			Kit.strut(
				m,
				`DockRod{i}`,
				Vector3.new(x, cy + cn.thick, cz0 + 0.6),
				Vector3.new(x, rodTop, zF - 0.1),
				0.3,
				STEEL,
				"detail"
			)
		end
	end
	if hasDrive then
		rollUp("DriveDoor", driveX, 0.2, driveTall)
		for i, side in { -1, 1 } do
			local bx = driveX + side * (doorW / 2 + 1.1)
			Kit.column(m, `Bollard{i}`, bx, zF - 1.4, 0.1, SHAPE.bollard.tall, SHAPE.bollard.wide, SAFETY, "trim")
		end
	end
	Kit.glass(
		m,
		"Entry",
		Vector3.new(ex - en.wide / 2, 0.18, doorFront),
		Vector3.new(ex + en.wide / 2, en.tall, back),
		P.window.dark,
		{
			image = City.textures.windowBold,
			faces = { Enum.NormalId.Front },
			u = en.wide / 2,
			v = en.tall - 0.18,
			lines = rgb(60, 64, 70),
			lit = true,
		}
	)
	local aw = SHAPE.awning
	Kit.trim(
		m,
		"Awning",
		Vector3.new(ex - en.wide / 2 - 1, en.tall + 0.5, zF - aw.proud),
		Vector3.new(ex + en.wide / 2 + 1, en.tall + 0.5 + aw.thick, back),
		inkLook
	)
	local names = City.signNames.arts
	local signY = en.tall + 1.6
	Kit.sign(
		m,
		"Sign",
		Vector3.new(ex - signHalf, signY, doorFront - 0.15),
		Vector3.new(ex + signHalf, signY + SHAPE.sign, doorFront + 0.05),
		Enum.NormalId.Front,
		names[rng:NextInteger(1, #names)],
		pal.ink,
		if pal.ink == PAINT.white then PAINT.black else paints[1],
		City.districtLooks.arts.font
	)
	Kit.tube(
		m,
		"Downpipe",
		Vector3.new(x1 - 1.2, 0.2, zF - 0.55),
		Vector3.new(x1 - 1.2, wallTop - 0.2, zF - 0.55),
		0.7,
		STEEL,
		"detail"
	)
	if rng:NextNumber() < SHAPE.washChance and HW > 8 then
		Kit.wash(m, "Wash", hx0 + 1, hx1 - 1, zF - 2.4, 0.2, WASH)
	end

	-------------------------------------------------------------------------------------------------------
	-- The roof
	-------------------------------------------------------------------------------------------------------
	local crown = math.clamp(variant.crown, 1, 4)
	if crown == 4 then
		-- A barrel vault of metal planks springing from the side walls, rising behind a stepped gable parapet
		-- whose steps meet the curve (the bowstring-truss warehouse; in the quarry, a hangar).
		local bv = SHAPE.barrel
		local c = span - 0.8
		local s = math.clamp(c * bv.rise, bv.min, bv.max)
		local r = (c * c / 4 + s * s) / (2 * s)
		local cx = (x0 + x1) / 2
		local spring = H - 0.3
		local cy = spring + s - r
		local reach = math.asin(math.clamp((c / 2) / r, -1, 1))
		local z0, z1 = zF + 0.8, zB - 0.2
		local zm = (z0 + z1) / 2
		local metal = Kit.look(rgb(176, 182, 188), Enum.Material.Metal)
		for i = 1, bv.planks do
			local ta = -reach + 2 * reach * (i - 1) / bv.planks
			local tb = -reach + 2 * reach * i / bv.planks
			local a = Vector3.new(cx + r * math.sin(ta), cy + r * math.cos(ta), zm)
			local b = Vector3.new(cx + r * math.sin(tb), cy + r * math.cos(tb), zm)
			local run = (b - a).Unit * 0.15
			Kit.strut(m, `Vault{i}`, a - run, b + run, bv.thick, metal, "trim", z1 - z0)
		end
		-- The gable: steps whose top corners touch the curve, a little proud of the vault's ends.
		for i, f in bv.steps do
			local half = c / 2 * f
			local top = cy + math.sqrt(math.max(r * r - half * half, 0)) - bv.thick / 2 - 0.05
			local set = (i - 1) * 0.08 -- each narrower step a hair behind the one before: no shared faces
			Kit.box(
				m,
				`Gable{i}`,
				Vector3.new(cx - half, H - 0.4 - i * 0.02, zF + 0.6 + set),
				Vector3.new(cx + half, top, zB - 0.4 - set),
				wallLook
			)
		end
	elseif crown == 1 then
		-- A stepped front parapet with its own cap, and plant on the roof behind it.
		local st = SHAPE.step
		local half = span * st.share / 2
		local cx = (x0 + x1) / 2
		Kit.trim(
			m,
			"Step",
			Vector3.new(cx - half, H - 0.05, zF - 0.2),
			Vector3.new(cx + half, H + st.tall, zF + 1.2),
			wallLook
		)
		Kit.trim(
			m,
			"StepCap",
			Vector3.new(cx - half - 0.4, H + st.tall - 0.05, zF - 0.6),
			Vector3.new(cx + half + 0.4, H + st.tall + 0.7, zF + 1.6),
			capLook
		)
		local unitBack = math.max(zF + 8, zB - 4)
		Kit.roofBox(m, "Unit1", Vector3.new(x0 + 3, H, unitBack - 7), Vector3.new(x0 + 10, H + 3.6, unitBack), STEEL)
		Kit.roofBox(m, "Unit2", Vector3.new(x1 - 8, H, unitBack - 5), Vector3.new(x1 - 3, H + 2.8, unitBack), STEEL)
	elseif crown == 2 then
		-- A sawtooth of north-light roofs, each tooth's glass facing the street over the parapet, lit at night.
		local th = SHAPE.tooth
		local s0, s1 = zF + 1.6, zB - 1.2
		local teeth = math.clamp(math.floor((s1 - s0) / th.deep), 2, 4)
		local depth = (s1 - s0) / teeth
		local roof = Kit.look(rgb(150, 156, 162), Enum.Material.Metal)
		for k = 1, teeth do
			local z0 = s0 + (k - 1) * depth
			Kit.wedge(
				m,
				`Tooth{k}`,
				Vector3.new(x0 + 0.8, H - 0.4, z0 + 0.4),
				Vector3.new(x1 - 0.8, H + th.tall, z0 + depth),
				"front",
				roof
			)
			Kit.glass(
				m,
				`Light{k}`,
				Vector3.new(x0 + 1.2, H + 0.1, z0 + 0.1),
				Vector3.new(x1 - 1.2, H + th.tall - 0.35, z0 + 0.45),
				P.window.dark,
				{
					image = City.textures.windowFine,
					faces = { Enum.NormalId.Front },
					u = 3.2,
					v = th.tall - 0.45,
					lines = rgb(200, 204, 208),
					lit = true,
				}
			)
		end
	else
		-- A rooftop bar: a glass rail along the front, a pergola over the bar, market umbrellas, string lights.
		local br = SHAPE.bar
		Kit.detail(m, "BarRail", Vector3.new(x0 + 0.3, H, zF + 0.1), Vector3.new(x1 - 0.3, H + br.rail, zF + 0.4), RAIL)
		local pz1 = zB - 2
		local pz0 = math.max(zF + 8, pz1 - 10)
		local px0, px1 = x0 + 2, x0 + 2 + span * 0.55
		local timber = Kit.look(rgb(120, 86, 60), Enum.Material.Wood)
		for i, x in { px0 + 0.6, px1 - 0.6 } do
			Kit.column(m, `Post{i}`, x, pz0 + 0.6, H, H + br.pergola, 0.8, inkLook, "trim")
		end
		Kit.trim(
			m,
			"Pergola",
			Vector3.new(px0, H + br.pergola, pz0),
			Vector3.new(px1, H + br.pergola + 0.7, pz1),
			timber
		)
		Kit.box(m, "Bar", Vector3.new(px0 + 1.5, H, pz1 - 3), Vector3.new(px1 - 1.5, H + 3.6, pz1 - 1.2), inkLook)
		for i, ends in
			{
				{
					Vector3.new(px0 + 0.6, H + br.pergola - 0.2, pz0 + 0.6),
					Vector3.new(x0 + 0.6, H + br.rail, zF + 0.25),
				},
				{
					Vector3.new(px1 - 0.6, H + br.pergola - 0.2, pz0 + 0.6),
					Vector3.new(x1 - 0.6, H + br.rail, zF + 0.25),
				},
			}
		do
			local spec = Kit.strut(
				m,
				`String{i}`,
				ends[1],
				ends[2],
				0.35,
				Kit.look(STRING, Enum.Material.SmoothPlastic),
				"detail"
			)
			Kit.lit(spec, "neonAmber")
		end
		local uz = (zF + 0.6 + pz0) / 2
		for i, at in { 0.3, 0.62 } do
			local color = if i == 1 then paints[1] else pal.wall
			local size = math.min(br.umbrella, pz0 - zF - 1.5)
			Kit.umbrella(m, `Umbrella{i}`, x0 + span * at, uz, H, size, color, true)
		end
		Kit.roofBox(
			m,
			"Stair",
			Vector3.new(x1 - 9, H, math.max(zF + 4, zB - 8)),
			Vector3.new(x1 - 2.5, H + 8, zB - 1.5),
			wallLook
		)
	end
end

local archetype: Types.Archetype = { id = "mural_warehouse", build = build }
return archetype
