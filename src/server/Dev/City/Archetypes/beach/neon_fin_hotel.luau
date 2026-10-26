--!strict
-- B02 neon_fin_hotel (docs/city/ARCHETYPES.md §6, B02): the beach strip's low Streamline hotel with the strip's
-- classic sign. A white block with square corners and strong horizontal bands: on every floor a white eyebrow with
-- rounded ends over a ribbon window that wraps round both corners, set 0.7 behind slab-like spandrels that turn the
-- corners with it, and a pastel line along each spandrel that turns the corners too. The lobby is glazed between
-- two corner piers behind a café terrace. Its signature is an inverted-T sign: a boxy marquee over the entrance with
-- the name on three faces and, standing up from it, one tall blade fin with the name in stacked letters on both
-- faces, rising well past the roof. At night neon outlines the fin and the marquee, the pastel lines glow in a second
-- colour, the marquee's soffit and the lobby glow warm, and a wash lights the facade.
--
-- What makes it itself: one tall blade fin standing up from a boxy marquee over a low, banded white block.
-- Placement, sizes, heights and its budget: Config/CityArchetypes/neon_fin_hotel.
-- Variants: palette (4: the line colour, the lines' neon and the sign's neon), crown (1 a stepped fin top over a
-- stepped parapet, 2 a rounded fin top with a needle and a lit ball over a flat roofline), rhythm (1 the fin and
-- the entrance centred, 2 both in the left bay), mirror (the off-centre fin and the stair house change sides).
--
-- Previewed in Studio (2026-10-25, docs/images/city/neon_fin_hotel-*.jpg): the stacked fin letters, the corner wrap
-- and both neons read; round 2 moved the wash from the canopy (its dark fixture showed as bars at the corners) onto
-- the marquee's roof, where it lights the fin.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local City = require(ReplicatedStorage.Shared.Config.City)
local Kit = require(script.Parent.Parent.Parent.Kit)
local MapTypes = require(script.Parent.Parent.Parent.Parent.MapTypes)
local Types = require(script.Parent.Parent.Parent.Types)

local P = City.palettes
local KIT = City.kit
local FONT = City.districtLooks.beach.font
local rgb = Color3.fromRGB

-- The recipe, in studs.
local SHAPE = {
	ground = 14, -- the lobby floor, double height
	parapet = 3, -- at least: the parapet takes up what whole floors leave
	floorMin = 10.4,
	floorMax = 11.8,
	floors = { 2, 3 }, -- upper floors
	terrace = 9, -- the café terrace between the front line and the facade
	bodyDepth = 38, -- at most
	sideInset = 3, -- the eyebrows' rounded ends reach round the corners, so the walls keep this far in
	wall = 1, -- the wall plane, behind the spandrels' faces
	glassIn = 0.7, -- the ribbon glass's face, behind the spandrels' faces
	wrap = 6.3, -- the spandrels and the corner windows reach this far round onto the sides
	ends = 0.5, -- the spandrels' ends stand this far out of the side walls
	sill = 2.4, -- wall under a window
	head = 1.5, -- wall over a window, under the floor line
	lintel = 2, -- the lobby glass tops out this far under the first floor
	pier = 2.6, -- the lobby's corner piers
	browRadius = 3, -- the eyebrows' rounded ends
	eyebrow = { thick = 0.6, proud = 2.4 },
	canopy = { thick = 0.9, proud = 2.4 },
	cornice = { thick = 0.8, proud = 1.2 },
	line = 0.8, -- the pastel line's height...
	lineDrop = 1.4, -- ...its top this far under the spandrel's top (the parapet's: under the roof)
	sideBay = 6.5,
	fin = { thick = 2.2, out = 5.5 }, -- the blade: across, and how far it stands out of the facade
	finRise = { 13, 11 }, -- the fin's top over the roof, by crown
	marquee = { share = 0.5, min = 12, max = 24, under = 3.6, over = 1.6, out = 4.4 },
	offset = 0.22, -- rhythm 2: the fin this share of the width left of centre (as far as fits)
	stepShare = 0.2, -- crown 1: the parapet step's half-width, a share of the width
	needle = 18.4, -- crown 2: the needle's top over the roof
	terraceTop = 0.9,
	balustrade = 2.2,
	gate = 3.5, -- half the balustrade's opening, in front of the entrance
	umbrella = 7.5,
	washIn = 1.2, -- the wash fixture's line, behind the marquee's front edge
}

-- Line colour, the lines' neon at night, the sign's neon, the letters (by day on white; at night bright), the wash.
local PALETTES = {
	{
		line = rgb(70, 196, 200),
		lineKind = "sign",
		signKind = "neonBlue",
		letters = rgb(46, 104, 236),
		wash = rgb(120, 170, 255),
	},
	{
		line = P.deco.mint,
		lineKind = "sign",
		signKind = "neonPink",
		letters = rgb(236, 62, 140),
		wash = rgb(255, 130, 200),
	},
	{
		line = rgb(246, 140, 120),
		lineKind = "neonPink",
		signKind = "neonBlue",
		letters = rgb(46, 104, 236),
		wash = rgb(255, 150, 170),
	},
	{
		line = P.deco.lilac,
		lineKind = "neonViolet",
		signKind = "neonAmber",
		letters = rgb(226, 132, 36),
		wash = rgb(210, 150, 255),
	},
}

local FRONT, LEFT, RIGHT = Enum.NormalId.Front, Enum.NormalId.Left, Enum.NormalId.Right

-- Upper floors and their height for a roof at `height`: whole floors, the parapet taking up the rest.
local function storeys(height: number): (number, number)
	local room = height - SHAPE.ground - SHAPE.parapet
	local up = math.clamp(math.floor(room / SHAPE.floorMin + 1e-6), SHAPE.floors[1], SHAPE.floors[2])
	return up, math.min(room / up, SHAPE.floorMax)
end

-- A hotel name short enough to stack down a fin (the leading "THE " dropped), and the name in full.
local function pickName(rng: Random): (string, string)
	local short: { string } = {}
	for _, name in City.signNames.hotels do
		if #(string.gsub(name, "^THE ", "")) <= 9 then
			table.insert(short, name)
		end
	end
	local list = if #short > 0 then short else City.signNames.hotels
	local name = list[rng:NextInteger(1, #list)]
	local word = string.gsub(name, "^THE ", "")
	local letters: { string } = {}
	for i = 1, #word do
		table.insert(letters, string.sub(word, i, i))
	end
	return name, table.concat(letters, "\n")
end

-- Text on some faces of a part (SurfaceGuis; Kit.sign's look, on parts that aren't boards).
local function label(
	m: Types.Model,
	spec: Types.PartSpec,
	faces: { Enum.NormalId },
	text: string,
	color: Color3,
	size: Vector2
)
	local labels: { MapTypes.LabelSpec } = spec.labels or {}
	for _, face in faces do
		table.insert(labels, {
			face = Kit.face(m, face),
			text = text,
			color = color,
			font = FONT,
			size = size,
			pixelsPerStud = KIT.signPixelsPerStud,
		})
	end
	spec.labels = labels
end

local function build(m: Types.Model)
	local site = m.site
	local variant = site.variant
	local pal = PALETTES[math.clamp(variant.palette, 1, #PALETTES)]
	local crown = math.clamp(variant.crown, 1, 2)
	local rng = Kit.rng(m)
	local W, D = site.width, site.depth
	local hw, hd = W / 2, D / 2
	local G = SHAPE.ground
	local H = site.height
	local up, f = storeys(H)
	local T = G + up * f -- the top floor line; the parapet runs from here to the roof

	local white = Kit.look(P.deco.white, Enum.Material.SmoothPlastic)
	local lineLook = Kit.look(pal.line, Enum.Material.SmoothPlastic)

	local x0, x1 = -hw + SHAPE.sideInset, hw - SHAPE.sideInset
	local zF = -hd + SHAPE.terrace -- the spandrels' faces: the facade
	local zB = math.min(hd - 1, zF + SHAPE.bodyDepth)
	local zWall = zF + SHAPE.wall
	local e = SHAPE.ends
	local lintel = G - SHAPE.lintel

	-------------------------------------------------------------------------------------------------------
	-- Body, the lobby between its corner piers
	-------------------------------------------------------------------------------------------------------
	Kit.box(m, "Body", Vector3.new(x0, -KIT.bury, zWall), Vector3.new(x1, H, zB), white)
	for i, sx in { -1, 1 } do
		local outer = if sx < 0 then x0 - 0.05 else x1 + 0.05
		local inner = if sx < 0 then x0 + SHAPE.pier else x1 - SHAPE.pier
		Kit.box(m, `Pier{i}`, Vector3.new(outer, -KIT.bury, zF), Vector3.new(inner, lintel, zWall + 0.25), white)
	end
	Kit.glass(
		m,
		"Lobby",
		Vector3.new(x0 + SHAPE.pier, SHAPE.terraceTop - 0.3, zF + SHAPE.glassIn),
		Vector3.new(x1 - SHAPE.pier, lintel, zWall + 0.2),
		P.window.dark,
		{
			image = City.textures.windowBold,
			faces = { FRONT },
			u = 4,
			v = lintel - SHAPE.terraceTop + 0.3,
			lines = P.deco.white,
			lit = true,
		}
	)

	-------------------------------------------------------------------------------------------------------
	-- The bands: spandrels with their pastel lines (both turning the corners), wrapping ribbon windows between
	-- them, an eyebrow over every window, the cornice
	-------------------------------------------------------------------------------------------------------
	-- Spandrel 0 is the lintel over the lobby, 1..up-1 lie between two floors, and `up` is the parapet.
	for k = 0, up do
		local y0 = if k == 0 then lintel else G + k * f - SHAPE.head
		local y1 = if k == up then H - 0.04 else G + k * f + SHAPE.sill
		Kit.box(m, `Spandrel{k}`, Vector3.new(x0 - e, y0, zF), Vector3.new(x1 + e, y1, zF + SHAPE.wrap), white)
		local top = if k == up then H - SHAPE.lineDrop else y1 - SHAPE.lineDrop
		local line = Kit.detail(
			m,
			`Line{k}`,
			Vector3.new(x0 - e - 0.1, top - SHAPE.line, zF - 0.1),
			Vector3.new(x1 + e + 0.1, top, zF + SHAPE.wrap - 0.3),
			lineLook
		)
		Kit.lit(line, pal.lineKind)
	end
	for k = 1, up do
		local y0 = G + (k - 1) * f + SHAPE.sill
		local y1 = G + k * f - SHAPE.head
		Kit.glass(
			m,
			`Window{k}`,
			Vector3.new(x0 - e + 0.25, y0, zF + SHAPE.glassIn),
			Vector3.new(x1 + e - 0.25, y1, zF + SHAPE.wrap - 0.05),
			P.window.dark,
			{
				image = City.textures.windowFine,
				faces = { FRONT, LEFT, RIGHT },
				u = 2.2,
				v = y1 - y0,
				lines = P.deco.white,
				reflectance = 0.2,
			}
		)
	end
	local bodyMin, bodyMax = Vector3.new(x0, 0, zF), Vector3.new(x1, 0, zB)
	local corners = { fl = true, fr = true }
	local r = SHAPE.browRadius
	local cp = SHAPE.canopy
	Kit.band(
		m,
		"Canopy",
		bodyMin,
		bodyMax,
		r,
		corners,
		lintel + cp.thick / 2 + 0.05,
		cp.thick,
		cp.proud,
		white,
		"front"
	)
	local brow = SHAPE.eyebrow
	for k = 1, up do
		local y = G + k * f - SHAPE.head + brow.thick / 2 + 0.1
		Kit.band(m, `Brow{k}`, bodyMin, bodyMax, r, corners, y, brow.thick, brow.proud, white, "front")
	end
	local cn = SHAPE.cornice
	Kit.band(m, "Cornice", bodyMin, bodyMax, r, corners, H - cn.thick / 2 + 0.06, cn.thick, cn.proud, white, "front")

	-- The sides: stucco with punched windows behind the corner wrap.
	for i, sx in { -1, 1 } do
		local wallX = if sx < 0 then x0 else x1
		local face = if sx < 0 then LEFT else RIGHT
		Kit.punched(
			m,
			`Side{i}`,
			Vector3.new(wallX - sx * 0.4, G, zF + SHAPE.wrap + 0.3),
			Vector3.new(wallX + sx * 0.06, T, zB - 0.6),
			P.deco.white,
			P.window.dark,
			{ face },
			SHAPE.sideBay,
			f
		)
	end

	-------------------------------------------------------------------------------------------------------
	-- The inverted-T sign: the marquee and the blade fin standing up from it
	-------------------------------------------------------------------------------------------------------
	local name, stacked = pickName(rng)
	local mq = SHAPE.marquee
	local mw = math.clamp(W * mq.share, mq.min, math.min(mq.max, x1 - x0 - 2 * SHAPE.pier))
	local finX = 0
	if variant.rhythm == 2 then
		finX = -math.clamp(W * SHAPE.offset, 0, (x1 - x0) / 2 - mw / 2 - SHAPE.pier)
	end
	local mzF = zF - mq.out
	local marquee = Kit.trim(
		m,
		"Marquee",
		Vector3.new(finX - mw / 2, G - mq.under, mzF),
		Vector3.new(finX + mw / 2, G + mq.over, zWall + 0.2),
		white
	)
	label(m, marquee, { FRONT }, name, pal.letters, Vector2.new(0.9, 0.62))
	label(m, marquee, { LEFT, RIGHT }, "HOTEL", pal.letters, Vector2.new(0.8, 0.5))
	for i, y in { G + mq.over - 0.35, G - mq.under + 0.35 } do
		Kit.neon(
			m,
			`MarqueeNeon{i}`,
			Vector3.new(finX - mw / 2 + 0.4, y, mzF - 0.35),
			Vector3.new(finX + mw / 2 - 0.4, y, mzF - 0.35),
			pal.signKind,
			pal.line
		)
	end
	-- Lamps in the marquee's soffit, warm over the entrance at night.
	Kit.neonStrip(
		m,
		"Soffit",
		Vector3.new(finX - mw / 2 + 0.8, G - mq.under - 0.2, mzF + 0.6),
		Vector3.new(finX + mw / 2 - 0.8, G - mq.under + 0.1, zF - 0.3),
		"window",
		rgb(228, 222, 210)
	)

	local fin = SHAPE.fin
	local finTop = H + SHAPE.finRise[crown]
	local fz0, fz1 = zF - fin.out, zWall + 0.2
	local blade = Kit.trim(
		m,
		"Fin",
		Vector3.new(finX - fin.thick / 2, G + mq.over - 0.05, fz0),
		Vector3.new(finX + fin.thick / 2, finTop, fz1),
		white
	)
	label(m, blade, { LEFT, RIGHT }, stacked, pal.letters, Vector2.new(0.72, 0.94))
	Kit.neon(
		m,
		"FinNeon",
		Vector3.new(finX, G + mq.over + 0.4, fz0 - 0.35),
		Vector3.new(finX, finTop - 0.6, fz0 - 0.35),
		pal.signKind,
		pal.line
	)

	if crown == 1 then
		-- A stepped top on the fin, and the parapet stepping up behind it.
		Kit.trim(
			m,
			"FinCap",
			Vector3.new(finX - fin.thick / 2 - 0.5, finTop - 0.3, fz0 - 0.5),
			Vector3.new(finX + fin.thick / 2 + 0.5, finTop + 1, fz1),
			white
		)
		Kit.trim(
			m,
			"FinCapTop",
			Vector3.new(finX - fin.thick / 2 + 0.2, finTop + 0.98, fz0 + 1.2),
			Vector3.new(finX + fin.thick / 2 - 0.2, finTop + 2.4, fz1 - 1.5),
			white
		)
		local reach = math.min(finX - x0, x1 - finX) - 1
		local s1 = math.clamp(W * SHAPE.stepShare, math.min(3, reach), reach)
		Kit.box(
			m,
			"Step1",
			Vector3.new(finX - s1, H - 0.05, zF + 0.3),
			Vector3.new(finX + s1, H + 3.2, zF + 4.5),
			white
		)
		Kit.box(
			m,
			"Step2",
			Vector3.new(finX - s1 * 0.55, H + 3.15, zF + 0.9),
			Vector3.new(finX + s1 * 0.55, H + 5.4, zF + 4),
			white
		)
	else
		-- A rounded fin top, a needle and a lit ball.
		local cz = (fz0 + fz1) / 2
		local head = fz1 - fz0
		Kit.tube(
			m,
			"FinHead",
			Vector3.new(finX - fin.thick / 2 - 0.15, finTop, cz),
			Vector3.new(finX + fin.thick / 2 + 0.15, finTop, cz),
			head,
			white,
			"trim"
		)
		local needle = H + SHAPE.needle
		Kit.column(
			m,
			"Needle",
			finX,
			cz,
			finTop + head / 2 - 0.4,
			needle,
			0.35,
			Kit.look(rgb(220, 224, 228), Enum.Material.Metal),
			"detail"
		)
		Kit.lit(Kit.ball(m, "Ball", Vector3.new(finX, needle + 0.5, cz), 1, lineLook), pal.signKind)
	end
	Kit.roofBox(m, "Stair", Vector3.new(x1 - 11, H, zB - 10), Vector3.new(x1 - 4, H + 6, zB - 3), white)

	-------------------------------------------------------------------------------------------------------
	-- The café terrace, its balustrade open at the entrance, umbrellas, and the night wash
	-------------------------------------------------------------------------------------------------------
	local tTop = SHAPE.terraceTop
	Kit.box(
		m,
		"Terrace",
		Vector3.new(-hw + 0.2, 0, -hd + 0.3),
		Vector3.new(hw - 0.2, tTop, zWall + 0.2),
		Kit.look(P.deco.terrazzo, Enum.Material.SmoothPlastic)
	)
	local railTop = tTop + SHAPE.balustrade
	local tz = (-hd + 1.4 + zF) / 2
	local room = math.min(SHAPE.umbrella, (zF - 0.4 - tz) * 2, (tz + hd - 1.4) * 2)
	local segments = { { -hw + 0.6, finX - SHAPE.gate }, { finX + SHAPE.gate, hw - 0.6 } }
	for i, seg in segments do
		local a, b = seg[1], seg[2]
		if b - a < 1 then
			continue
		end
		Kit.box(m, `Balustrade{i}`, Vector3.new(a, tTop, -hd + 0.6), Vector3.new(b, railTop, -hd + 1.3), white)
		Kit.detail(
			m,
			`Coping{i}`,
			Vector3.new(a - 0.1, railTop, -hd + 0.5),
			Vector3.new(b + 0.1, railTop + 0.35, -hd + 1.4),
			lineLook
		)
		local len = b - a - 1.6
		local count = math.clamp(math.floor(len / (room + 3)), 0, 2)
		for j = 1, count do
			local x = a + 0.8 + len * (j - 0.5) / count
			local color = if (i + j) % 2 == 0 then pal.line else P.deco.white
			Kit.umbrella(m, `Umbrella{i}{j}`, x, tz, tTop, math.min(room, len / count - 1), color)
		end
	end
	-- On the marquee's roof, out of sight from the street, washing the fin and the floors behind it (on the canopy the
	-- dark fixture showed as a line either side of the marquee).
	Kit.wash(m, "Wash", finX - mw / 2 + 0.6, finX + mw / 2 - 0.6, mzF + SHAPE.washIn, G + mq.over, pal.wash)
end

local archetype: Types.Archetype = { id = "neon_fin_hotel", build = build }
return archetype
