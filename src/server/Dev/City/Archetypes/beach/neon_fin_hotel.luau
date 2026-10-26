--!strict
-- B02 neon_fin_hotel (docs/city/ARCHETYPES.md §6, B02): the beach strip's postcard hotel. A low white block of three
-- or four storeys banded by horizontals: on every floor a ribbon window that wraps both corners, a coloured eyebrow
-- with rounded ends over it and a coloured sill line under the next, all turning the corners. In the middle a stucco
-- spine stands proud of the bands and rises past the roof: two panels of speed-line stripes flank a narrow bay of
-- small windows. Standing out of the spine is the signature, an inverted-T sign: a boxy marquee over the entrance
-- reading HOTEL, and one tall blade fin climbing from it far past the roof with the name stacked down both faces. The
-- lobby is glazed between corner piers behind a terrazzo café terrace with umbrellas. At night neon outlines the fin
-- and the marquee, the sill lines glow in a second colour, the lobby and the marquee's soffit glow warm, and a wash on
-- the marquee's roof lights the fin and the floors.
--
-- What makes it itself: one tall blade fin standing up from a boxy marquee, in front of a striped spine, on a low
-- banded white block.
-- Placement, sizes, heights and its budget: Config/CityArchetypes/neon_fin_hotel.
-- Variants: palette (4: the eyebrow and sill colour, the stripes, the fin's colour and letters, the two neons), crown
-- (1 the spine's centre stepping up again and a stepped fin cap, 2 a rounded fin top with a needle and a lit ball),
-- rhythm (1 spine and fin centred, 2 both in the left bay), mirror (the off-centre spine and the stair house change
-- sides).
--
-- Round 3 (2026-10-26, from photos of the inspiration): the striped spine behind the fin, coloured eyebrows and sill
-- lines as on the real front, HOTEL on the marquee and the name on the fin, the fin's letters on a thin sleeve and
-- neon on both front edges. Preview check: the stripe panels read as blue/white speed lines (the punched overlay at
-- 1.3 studs a tile), the eyebrows stop behind the spine's face (it stands 0.4 further out), the letters on the fin's
-- sleeve read from down the street both ways, and at night only two neon colours show.
-- Round 4 (2026-10-26, seen in Studio): one-word names only on the fin (a two-word one left a gap), and palette 2's
-- fin and marquee a deep violet with white letters (dark violet on lilac went dull at night).

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
	line = 0.6, -- the sill line's height...
	lineDrop = 0.35, -- ...its top this far under the next window's sill (the frieze's: under the cornice)
	sideBay = 6.5,
	-- The spine: its width (a share of the site's), how far it stands out of the facade (past the eyebrows, so they die
	-- into its sides), how far it rises past the roof, and each striped panel's share of its width.
	spine = { share = 0.3, min = 10, max = 17, proud = 2.8, rise = 2.6, panel = 0.22 },
	stripes = 1.3, -- one speed line every this many studs up the panels
	fin = { thick = 2.2, out = 4.4 }, -- the blade: across, and how far it stands out of the spine
	finRise = { 13, 11 }, -- the fin's top over the roof, by crown
	marquee = { share = 0.5, min = 12, max = 24, under = 3.6, over = 1.6, out = 4.6 },
	offset = 0.22, -- rhythm 2: the spine this share of the width left of centre (as far as fits)
	step = 2.4, -- crown 1: the spine's centre steps up this much again
	needle = 18.4, -- crown 2: the needle's top over the roof
	terraceTop = 0.9,
	balustrade = 2.2,
	gate = 3.5, -- half the balustrade's opening, in front of the entrance
	umbrella = 7.5,
	washIn = 1.2, -- the wash fixture's line, behind the marquee's front edge
}

-- The accent (eyebrows, sill lines, cornice, coping, umbrellas) and its neon; the speed-line stripes; the fin and
-- marquee's colour, their letters (bright enough to read at night too) and their neon; the wash.
local PALETTES = {
	{
		accent = rgb(52, 178, 160),
		lineKind = "neonCyan",
		stripes = rgb(52, 92, 196),
		fin = P.deco.white,
		letters = rgb(46, 104, 236),
		signKind = "neonBlue",
		wash = rgb(120, 170, 255),
	},
	{
		accent = rgb(52, 178, 160),
		lineKind = "neonCyan",
		stripes = rgb(110, 84, 190),
		-- A deep violet fin and marquee with white letters: dark violet on lilac went dull at night.
		fin = rgb(124, 98, 206),
		letters = rgb(250, 248, 240),
		signKind = "neonViolet",
		wash = rgb(200, 150, 255),
	},
	{
		accent = P.deco.pink,
		lineKind = "neonPink",
		stripes = rgb(40, 150, 176),
		fin = P.deco.white,
		letters = rgb(236, 62, 140),
		signKind = "neonCyan",
		wash = rgb(255, 130, 200),
	},
	{
		accent = P.deco.lemon,
		lineKind = "neonAmber",
		stripes = rgb(236, 120, 96),
		fin = P.deco.white,
		letters = rgb(226, 120, 36),
		signKind = "neonPink",
		wash = rgb(255, 190, 150),
	},
}

local FRONT, LEFT, RIGHT = Enum.NormalId.Front, Enum.NormalId.Left, Enum.NormalId.Right

-- Upper floors and their height for a roof at `height`: whole floors, the parapet taking up the rest.
local function storeys(height: number): (number, number)
	local room = height - SHAPE.ground - SHAPE.parapet
	local up = math.clamp(math.floor(room / SHAPE.floorMin + 1e-6), SHAPE.floors[1], SHAPE.floors[2])
	return up, math.min(room / up, SHAPE.floorMax)
end

-- A one-word hotel name short enough to stack down a fin (the leading "THE " dropped), its letters one per line (a
-- two-word name left a blank line and squeezed its letters).
local function stackedName(rng: Random): string
	local short: { string } = {}
	for _, name in City.signNames.hotels do
		local word = string.gsub(name, "^THE ", "")
		if #word <= 9 and not string.find(word, " ", 1, true) then
			table.insert(short, name)
		end
	end
	local list = if #short > 0 then short else City.signNames.hotels
	local word = string.gsub(list[rng:NextInteger(1, #list)], "^THE ", "")
	local letters: { string } = {}
	for i = 1, #word do
		table.insert(letters, string.sub(word, i, i))
	end
	return table.concat(letters, "\n")
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
	local accent = Kit.look(pal.accent, Enum.Material.SmoothPlastic)
	local finLook = Kit.look(pal.fin, Enum.Material.SmoothPlastic)

	local x0, x1 = -hw + SHAPE.sideInset, hw - SHAPE.sideInset
	local zF = -hd + SHAPE.terrace -- the spandrels' faces: the facade
	local zB = math.min(hd - 1, zF + SHAPE.bodyDepth)
	local zWall = zF + SHAPE.wall
	local e = SHAPE.ends
	local lintel = G - SHAPE.lintel

	-- The spine and the marquee: centred, or (rhythm 2) toward the left as far as leaves the lobby's piers clear.
	local sp = SHAPE.spine
	local sw = math.clamp(W * sp.share, sp.min, sp.max)
	local panel = math.clamp(sw * sp.panel, 2.2, 3.6)
	local cw = sw - 2 * panel -- the small windows' bay between the striped panels
	local mq = SHAPE.marquee
	local mw = math.clamp(W * mq.share, mq.min, math.min(mq.max, x1 - x0 - 2 * SHAPE.pier))
	local sx = 0
	if variant.rhythm == 2 then
		sx = -math.clamp(W * SHAPE.offset, 0, (x1 - x0) / 2 - math.max(mw, sw) / 2 - SHAPE.pier)
	end
	local zS = zF - sp.proud -- the spine's face
	local spineTop = H + sp.rise

	-------------------------------------------------------------------------------------------------------
	-- Body, the lobby between its corner piers
	-------------------------------------------------------------------------------------------------------
	Kit.box(m, "Body", Vector3.new(x0, -KIT.bury, zWall), Vector3.new(x1, H, zB), white)
	for i, side in { -1, 1 } do
		local outer = if side < 0 then x0 - 0.05 else x1 + 0.05
		local inner = if side < 0 then x0 + SHAPE.pier else x1 - SHAPE.pier
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
	-- The bands: spandrels with their sill lines (both turning the corners), wrapping ribbon windows between them,
	-- a coloured eyebrow over every window, the canopy over the lobby and the coloured cornice
	-------------------------------------------------------------------------------------------------------
	-- Spandrel 0 is the lintel over the lobby, 1..up-1 lie between two floors, and `up` is the parapet.
	for k = 0, up do
		local y0 = if k == 0 then lintel else G + k * f - SHAPE.head
		local y1 = if k == up then H - 0.04 else G + k * f + SHAPE.sill
		Kit.box(m, `Spandrel{k}`, Vector3.new(x0 - e, y0, zF), Vector3.new(x1 + e, y1, zF + SHAPE.wrap), white)
		-- The sill line under the next floor's window; on the parapet, a frieze line under the cornice.
		local top = if k == up then H - SHAPE.cornice.thick - 0.4 else y1 - SHAPE.lineDrop
		local line = Kit.detail(
			m,
			`Line{k}`,
			Vector3.new(x0 - e - 0.1, top - SHAPE.line, zF - 0.1),
			Vector3.new(x1 + e + 0.1, top, zF + SHAPE.wrap - 0.3),
			accent
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
		Kit.band(m, `Brow{k}`, bodyMin, bodyMax, r, corners, y, brow.thick, brow.proud, accent, "front")
	end
	local cn = SHAPE.cornice
	Kit.band(m, "Cornice", bodyMin, bodyMax, r, corners, H - cn.thick / 2 + 0.06, cn.thick, cn.proud, accent, "front")

	-- The sides: stucco with punched windows behind the corner wrap.
	for i, side in { -1, 1 } do
		local wallX = if side < 0 then x0 else x1
		Kit.punched(
			m,
			`Side{i}`,
			Vector3.new(wallX - side * 0.4, G, zF + SHAPE.wrap + 0.3),
			Vector3.new(wallX + side * 0.06, T, zB - 0.6),
			P.deco.white,
			P.window.dark,
			{ if side < 0 then LEFT else RIGHT },
			SHAPE.sideBay,
			f
		)
	end

	-------------------------------------------------------------------------------------------------------
	-- The spine: proud of the bands and past the roof, a bay of small windows between two striped panels
	-------------------------------------------------------------------------------------------------------
	Kit.box(m, "Spine", Vector3.new(sx - sw / 2, lintel, zS), Vector3.new(sx + sw / 2, spineTop, zWall + 0.3), white)
	for k = 1, up do
		local y0 = G + (k - 1) * f + SHAPE.sill
		local y1 = G + k * f - SHAPE.head
		Kit.glass(
			m,
			`Bay{k}`,
			Vector3.new(sx - cw / 2 + 0.5, y0, zS - 0.12),
			Vector3.new(sx + cw / 2 - 0.5, y1, zS + 0.3),
			P.window.dark,
			{
				image = City.textures.windowBold,
				faces = { FRONT },
				u = (cw - 1) / 2,
				v = y1 - y0,
				lines = P.deco.white,
				reflectance = 0.2,
			}
		)
	end
	-- Speed lines: a white panel under the punched overlay tinted the stripe colour, one opening a tile, so the
	-- openings read as white bars between coloured ones.
	for i, side in { -1, 1 } do
		local a, b = sx + side * cw / 2, sx + side * (sw / 2 - 0.35)
		local stripes = Kit.detail(
			m,
			`Stripes{i}`,
			Vector3.new(math.min(a, b), G + 0.6, zS - 0.15),
			Vector3.new(math.max(a, b), spineTop - 0.7, zS + 0.1),
			white
		)
		stripes.textures = {
			{
				face = Kit.face(m, FRONT),
				image = City.textures.punched,
				u = math.abs(b - a),
				v = SHAPE.stripes,
				color = pal.stripes,
			},
		}
	end

	-------------------------------------------------------------------------------------------------------
	-- The inverted-T sign: the marquee reading HOTEL and the blade fin standing up from it with the name
	-------------------------------------------------------------------------------------------------------
	local mzF = zS - mq.out -- the marquee's face
	Kit.trim(
		m,
		"Marquee",
		Vector3.new(sx - mw / 2, G - mq.under, mzF),
		Vector3.new(sx + mw / 2, G + mq.over, zF + 0.3),
		finLook
	)
	Kit.sign(
		m,
		"MarqueeSign",
		Vector3.new(sx - mw / 2 + 0.6, G - mq.under + 0.8, mzF - 0.06),
		Vector3.new(sx + mw / 2 - 0.6, G + mq.over - 0.8, mzF + 0.2),
		FRONT,
		"HOTEL",
		pal.fin,
		pal.letters,
		FONT
	)
	for i, y in { G + mq.over - 0.35, G - mq.under + 0.35 } do
		Kit.neon(
			m,
			`MarqueeNeon{i}`,
			Vector3.new(sx - mw / 2 + 0.4, y, mzF - 0.35),
			Vector3.new(sx + mw / 2 - 0.4, y, mzF - 0.35),
			pal.signKind,
			pal.accent
		)
	end
	-- Lamps in the marquee's soffit, warm over the entrance at night.
	Kit.neonStrip(
		m,
		"Soffit",
		Vector3.new(sx - mw / 2 + 0.8, G - mq.under - 0.2, mzF + 0.6),
		Vector3.new(sx + mw / 2 - 0.8, G - mq.under + 0.1, zF - 0.3),
		"window",
		rgb(228, 222, 210)
	)

	local fin = SHAPE.fin
	local finTop = H + SHAPE.finRise[crown]
	local fz0, fz1 = zS - fin.out, zS + 0.6
	local fy0 = G + mq.over - 0.05
	Kit.trim(m, "Fin", Vector3.new(sx - fin.thick / 2, fy0, fz0), Vector3.new(sx + fin.thick / 2, finTop, fz1), finLook)
	-- The letters ride on a sleeve a hair proud of the fin's faces, so the fin itself stays with the building's still
	-- parts (a labelled part files with the lights).
	local sleeve = Kit.detail(
		m,
		"FinLetters",
		Vector3.new(sx - fin.thick / 2 - 0.06, fy0 + 1.2, fz0 + 0.45),
		Vector3.new(sx + fin.thick / 2 + 0.06, finTop - 1.2, zS - 0.2),
		finLook
	)
	label(m, sleeve, { LEFT, RIGHT }, stackedName(rng), pal.letters, Vector2.new(0.72, 0.94))
	for i, side in { -1, 1 } do
		local x = sx + side * (fin.thick / 2 - 0.1)
		Kit.neon(
			m,
			`FinNeon{i}`,
			Vector3.new(x, fy0 + 0.4, fz0 - 0.1),
			Vector3.new(x, finTop - 0.6, fz0 - 0.1),
			pal.signKind,
			pal.accent
		)
	end

	if crown == 1 then
		-- The spine's centre steps up again behind the fin, and a stepped cap tops the fin.
		Kit.box(
			m,
			"SpineStep",
			Vector3.new(sx - cw / 2 - 0.4, spineTop - 0.05, zS + 0.5),
			Vector3.new(sx + cw / 2 + 0.4, spineTop + SHAPE.step, zWall + 0.1),
			white
		)
		Kit.trim(
			m,
			"FinCap",
			Vector3.new(sx - fin.thick / 2 - 0.5, finTop - 0.3, fz0 - 0.5),
			Vector3.new(sx + fin.thick / 2 + 0.5, finTop + 1, fz1),
			finLook
		)
		Kit.trim(
			m,
			"FinCapTop",
			Vector3.new(sx - fin.thick / 2 + 0.2, finTop + 0.98, fz0 + 1.2),
			Vector3.new(sx + fin.thick / 2 - 0.2, finTop + 2.4, fz1 - 1.5),
			finLook
		)
	else
		-- A rounded fin top, a needle and a lit ball.
		local cz = (fz0 + fz1) / 2
		local head = fz1 - fz0
		Kit.tube(
			m,
			"FinHead",
			Vector3.new(sx - fin.thick / 2 - 0.15, finTop, cz),
			Vector3.new(sx + fin.thick / 2 + 0.15, finTop, cz),
			head,
			finLook,
			"trim"
		)
		local needle = H + SHAPE.needle
		Kit.column(
			m,
			"Needle",
			sx,
			cz,
			finTop + head / 2 - 0.4,
			needle,
			0.35,
			Kit.look(rgb(220, 224, 228), Enum.Material.Metal),
			"detail"
		)
		Kit.lit(Kit.ball(m, "Ball", Vector3.new(sx, needle + 0.5, cz), 1, accent), pal.signKind)
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
	local segments = { { -hw + 0.6, sx - SHAPE.gate }, { sx + SHAPE.gate, hw - 0.6 } }
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
			accent
		)
		local len = b - a - 1.6
		local count = math.clamp(math.floor(len / (room + 3)), 0, 2)
		for j = 1, count do
			local x = a + 0.8 + len * (j - 0.5) / count
			local color = if (i + j) % 2 == 0 then pal.accent else P.deco.white
			Kit.umbrella(m, `Umbrella{i}{j}`, x, tz, tTop, math.min(room, len / count - 1), color)
		end
	end
	-- On the marquee's roof, out of sight from the street, washing the fin, the spine and the floors behind it.
	Kit.wash(m, "Wash", sx - mw / 2 + 0.6, sx + mw / 2 - 0.6, mzF + SHAPE.washIn, G + mq.over, pal.wash)
end

local archetype: Types.Archetype = { id = "neon_fin_hotel", build = build }
return archetype
