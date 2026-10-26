--!strict
-- B06 corner_spire_hotel (docs/city/ARCHETYPES.md §6, B06): the nautical corner hotel, a landlocked liner. Its street
-- corner is a round drum: the glass bands wrap it as rings and the eyebrows round it as discs, a lemon canopy rings it
-- over a lit door set square to the corner, and it carries on past the roof as a smokestack with two teal funnel
-- bands and a cap, then a needle spire lit in neon. A tall blade fin stands out of the drum on the corner's diagonal,
-- from over the canopy to above the stack, with the name stacked down both faces and a neon edge; two smaller fins
-- point down the two streets. The front is a white wall of ribbon windows under eyebrows, a row of portholes under a
-- teal cornice, and a café terrace that opens toward the corner door.
--
-- What makes it itself: a finned smokestack on the round corner, topped by a needle spire, the name down its fin.
-- Placement, sizes, heights and its budget: Config/CityArchetypes/corner_spire_hotel. A corner archetype (Config/City
-- cornerArchetypes): it draws its drum at the +x end and placement mirrors it onto the block corner.
-- Variants: palette (4: canopy band, trim, the spire's neon and the portholes' neon), crown (1 a tall lit needle
-- spire, 2 two stepped drum tiers with a neon ring and a short mast), rhythm (1 a drum 14 across, 2 a fatter one 17
-- across), mirror (set by placement: the corner the drum stands on).
--
-- Previewed in Studio (2026-10-25, docs/images/city/corner_spire_hotel-*.jpg): the diagonal fin, the door panel, the
-- rings and the porthole row read; round 2 raised the smokestack (12 over the roof hid behind the cornice from the
-- street) and thickened its funnel bands.

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
	ground = 14,
	parapet = 4.2, -- at least: room for the portholes
	floorMin = 10.3,
	floorMax = 11.6,
	floors = { 2, 2 },
	terrace = 9,
	bodyDepth = 40,
	sideInset = 3.6, -- the canopy's disc and the fins reach round the corner
	radius = { 7, 8.5 }, -- the drum, by rhythm
	recess = 1.4, -- the ground floor's wall, behind the upper floors' face
	sill = 2.4,
	head = 1.5,
	lintel = 2.4,
	eyebrow = { thick = 0.6, proud = 2.6 },
	canopy = { thick = 1, proud = 3 }, -- the band over the ground floor: round the drum, the corner door's canopy
	cornice = { thick = 0.9, proud = 1.4 },
	porthole = { d = 2.6, every = 7.5, min = 3, max = 5 },
	stack = { rise = 16, bands = { 4.5, 9.5 }, band = 1 }, -- the smokestack over the roof
	fin = { thick = 1.4, out = 4.5, sunk = 2, over = 6 }, -- the corner fin: out of the drum, into it, over the stack
	sideFin = { thick = 1, out = 2.4, over = 2.4 },
	spire = { diameter = 1.4, top = 46 }, -- crown 1: the spire's tip over the roof
	mast = 16, -- crown 2: the mast's top over the stack
	door = 6,
	sideBay = 6.5,
	terraceTop = 0.9,
	balustrade = 2.2,
	umbrella = 7.5,
}

-- The canopy band, the trim (cornice, funnel bands, small fins, porthole rims), the spire's neon and its day colour,
-- the portholes' neon, the letters and the wash.
local PALETTES = {
	{
		band = P.deco.lemon,
		trim = rgb(46, 127, 160),
		spireKind = "neonPink",
		spire = rgb(250, 200, 222),
		portKind = "neonAmber",
		letters = rgb(236, 62, 140),
		wash = rgb(255, 140, 200),
	},
	{
		band = P.deco.mint,
		trim = rgb(40, 84, 150),
		spireKind = "neonBlue",
		spire = rgb(200, 216, 250),
		portKind = "neonAmber",
		letters = rgb(46, 90, 200),
		wash = rgb(140, 180, 255),
	},
	{
		band = P.deco.peach,
		trim = rgb(30, 140, 150),
		spireKind = "sign",
		spire = rgb(200, 240, 244),
		portKind = "neonPink",
		letters = rgb(20, 130, 150),
		wash = rgb(255, 170, 150),
	},
	{
		band = P.deco.sky,
		trim = rgb(110, 84, 176),
		spireKind = "neonViolet",
		spire = rgb(224, 210, 250),
		portKind = "neonAmber",
		letters = rgb(110, 84, 176),
		wash = rgb(200, 150, 255),
	},
}

local FRONT, BACK, LEFT, RIGHT = Enum.NormalId.Front, Enum.NormalId.Back, Enum.NormalId.Left, Enum.NormalId.Right
-- The corner's diagonal, out of the drum toward the front-right corner: (+1, -1) / root 2.
local DIAGONAL = math.sqrt(0.5)
local ALONG = CFrame.Angles(0, math.pi / 4, 0) -- a part's x along the diagonal
local ACROSS = CFrame.Angles(0, -math.pi / 4, 0) -- a part's x across it (tangent to the drum there)

-- Upper floors and their height for a roof at `height`: whole floors, the parapet taking up the rest.
local function storeys(height: number): (number, number)
	local room = height - SHAPE.ground - SHAPE.parapet
	local up = math.clamp(math.floor(room / SHAPE.floorMin + 1e-6), SHAPE.floors[1], SHAPE.floors[2])
	return up, math.min(room / up, SHAPE.floorMax)
end

-- A hotel name short enough to stack down the fin, its letters one per line (the leading "THE " dropped).
local function pickName(rng: Random): string
	local short: { string } = {}
	for _, name in City.signNames.hotels do
		if #(string.gsub(name, "^THE ", "")) <= 9 then
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
	local T = G + up * f -- the top floor line

	local white = Kit.look(P.deco.white, Enum.Material.SmoothPlastic)
	local bandLook = Kit.look(pal.band, Enum.Material.SmoothPlastic)
	local trim = Kit.look(pal.trim, Enum.Material.SmoothPlastic)
	local spireLook = Kit.look(pal.spire, Enum.Material.SmoothPlastic)
	local ringGlass = Kit.glassLook(P.window.dark, 0.2)

	local R = SHAPE.radius[math.clamp(variant.rhythm, 1, 2)]
	local x0, x1 = -hw + SHAPE.sideInset, hw - SHAPE.sideInset
	local zF = -hd + SHAPE.terrace
	local zB = math.min(hd - 1, zF + SHAPE.bodyDepth)
	local cx, cz = x1 - R, zF + R -- the drum's centre, at the corner end (+x)
	local Hs = H + SHAPE.stack.rise -- the smokestack's top
	local corners = { fr = true }
	local bodyMin, bodyMax = Vector3.new(x0, 0, zF), Vector3.new(x1, 0, zB)
	-- A point `r` out of the drum's centre along the corner's diagonal, at height y.
	local function out(r: number, y: number): Vector3
		return Vector3.new(cx + r * DIAGONAL, y, cz - r * DIAGONAL)
	end

	-------------------------------------------------------------------------------------------------------
	-- Body: the block, the upper floors' front, the set-back ground floor, the drum up to the stack's top
	-------------------------------------------------------------------------------------------------------
	Kit.box(m, "Core", Vector3.new(x0, -KIT.bury, cz), Vector3.new(x1, H, zB), white)
	Kit.box(m, "Upper", Vector3.new(x0 - 0.05, G, zF), Vector3.new(cx, H - 0.03, cz + 0.4), white)
	Kit.box(m, "Ground", Vector3.new(x0 - 0.05, -KIT.bury, zF + SHAPE.recess), Vector3.new(cx, G, cz + 0.4), white)
	Kit.box(m, "Pier", Vector3.new(x0 - 0.1, -KIT.bury, zF), Vector3.new(x0 + 3, G, zF + SHAPE.recess + 0.3), white)
	Kit.column(m, "Drum", cx, cz, -KIT.bury, Hs, 2 * R, white)
	Kit.glass(
		m,
		"Shop",
		Vector3.new(x0 + 3, SHAPE.terraceTop - 0.3, zF + SHAPE.recess - 0.3),
		Vector3.new(cx - 1, G - SHAPE.lintel, zF + SHAPE.recess + 0.2),
		P.window.dark,
		{
			image = City.textures.windowBold,
			faces = { FRONT },
			u = 4,
			v = G - SHAPE.lintel - SHAPE.terraceTop + 0.3,
			lines = P.deco.white,
			lit = true,
		}
	)
	-- The corner door: a lit glass panel standing on the drum, square to the corner's diagonal; its Front face looks
	-- out along the diagonal.
	local doorTop = G - 3
	local doorY0 = SHAPE.terraceTop - 0.3
	local door = Kit.oriented(
		m,
		"Door",
		"block",
		CFrame.new(out(R + 0.1, (doorY0 + doorTop) / 2)) * ACROSS,
		Vector3.new(SHAPE.door, doorTop - doorY0, 0.4),
		ringGlass,
		"box"
	)
	door.textures = {
		{
			face = Kit.face(m, FRONT),
			image = City.textures.windowBold,
			u = SHAPE.door / 2,
			v = doorTop - doorY0,
			color = P.deco.white,
		},
	}
	Kit.lit(door, "window")
	local cp = SHAPE.canopy
	Kit.band(m, "Canopy", bodyMin, bodyMax, R, corners, G, cp.thick, cp.proud, bandLook, "front")

	-------------------------------------------------------------------------------------------------------
	-- The floors: ribbons, glass rings round the drum, eyebrows; portholes under the teal cornice; the sides
	-------------------------------------------------------------------------------------------------------
	local brow = SHAPE.eyebrow
	for k = 1, up do
		local y0 = G + (k - 1) * f + SHAPE.sill
		local y1 = G + k * f - SHAPE.head
		Kit.glass(m, `Ribbon{k}`, Vector3.new(x0 + 1.6, y0, zF - 0.12), Vector3.new(cx, y1, zF + 0.4), P.window.dark, {
			image = City.textures.windowFine,
			faces = { FRONT },
			u = 2.2,
			v = y1 - y0,
			lines = P.deco.white,
			reflectance = 0.2,
		})
		Kit.column(m, `Ring{k}`, cx, cz, y0, y1, 2 * R + 0.1, ringGlass)
		Kit.band(m, `Brow{k}`, bodyMin, bodyMax, R, corners, y1 + 0.4, brow.thick, brow.proud, white, "front")
	end
	local cn = SHAPE.cornice
	Kit.band(m, "Cornice", bodyMin, bodyMax, R, corners, H - cn.thick / 2 + 0.06, cn.thick, cn.proud, trim, "front")
	-- A row of portholes centred on the front, between the top floor and the cornice.
	local ph = SHAPE.porthole
	local px0, px1 = x0 + 2.5, cx - R - 2
	local count = math.clamp(math.floor((px1 - px0) / ph.every) + 1, ph.min, ph.max)
	local spacing = math.min(ph.every, (px1 - px0) / (count - 1))
	local start = (px0 + px1) / 2 - spacing * (count - 1) / 2
	local py = T + (H - cn.thick - T) / 2
	for i = 1, count do
		Kit.porthole(m, `Port{i}`, start + (i - 1) * spacing, py, zF, ph.d, P.window.deep, trim, pal.portKind)
	end
	for i, sx in { -1, 1 } do
		local wallX = if sx < 0 then x0 else x1
		Kit.punched(
			m,
			`Side{i}`,
			Vector3.new(wallX - sx * 0.4, G, cz + 0.6),
			Vector3.new(wallX + sx * 0.06, T, zB - 0.6),
			P.deco.white,
			P.window.dark,
			{ if sx < 0 then LEFT else RIGHT },
			SHAPE.sideBay,
			f
		)
	end
	Kit.roofBox(m, "Stair", Vector3.new(x0 + 4, H, zB - 10), Vector3.new(x0 + 11, H + 6, zB - 3), white)

	-------------------------------------------------------------------------------------------------------
	-- The smokestack: funnel bands, a cap, the named fin on the diagonal, two small fins, the spire or the tiers
	-------------------------------------------------------------------------------------------------------
	local st = SHAPE.stack
	for i, rise in st.bands do
		Kit.disc(m, `Funnel{i}`, cx, cz, H + rise, 2 * R + 0.8, st.band, trim, "trim")
	end
	Kit.disc(m, "Cap", cx, cz, Hs + 0.3, 2 * R + 1.2, 1, white, "trim")
	local fn = SHAPE.fin
	local inner, outer = R - fn.sunk, R + fn.out
	local fy0, fy1 = G + 1, Hs + fn.over
	local fin = Kit.oriented(
		m,
		"Fin",
		"block",
		CFrame.new(out((inner + outer) / 2, (fy0 + fy1) / 2)) * ALONG,
		Vector3.new(outer - inner, fy1 - fy0, fn.thick),
		white,
		"trim"
	)
	-- Turned along the diagonal, the fin's Front face looks along the front street, its Back face down the side one.
	local name = pickName(rng)
	local labels: { MapTypes.LabelSpec } = {}
	for _, face in { FRONT, BACK } do
		table.insert(labels, {
			face = face,
			text = name,
			color = pal.letters,
			font = FONT,
			size = Vector2.new(0.76, 0.94),
			pixelsPerStud = KIT.signPixelsPerStud,
		})
	end
	fin.labels = labels
	Kit.neon(m, "FinNeon", out(outer + 0.3, fy0 + 0.6), out(outer + 0.3, fy1 - 0.6), pal.spireKind, pal.spire)
	local sf = SHAPE.sideFin
	Kit.trim(
		m,
		"FinFront",
		Vector3.new(cx - sf.thick / 2, H + 1.2, zF - sf.out),
		Vector3.new(cx + sf.thick / 2, Hs + sf.over, cz),
		trim
	)
	Kit.trim(
		m,
		"FinSide",
		Vector3.new(cx, H + 1.2, cz - sf.thick / 2),
		Vector3.new(x1 + sf.out, Hs + sf.over, cz + sf.thick / 2),
		trim
	)
	if crown == 1 then
		local base = Hs + 0.8
		local tip = H + SHAPE.spire.top
		for _, spec in Kit.spire(m, "Spire", cx, cz, base, tip - base, SHAPE.spire.diameter, spireLook, 3, false) do
			Kit.lit(spec, pal.spireKind)
		end
		Kit.lit(Kit.ball(m, "Tip", Vector3.new(cx, tip + 0.6, cz), 1.2, spireLook), pal.spireKind)
	else
		local t1, t2 = 2 * R * 0.72, 2 * R * 0.45
		Kit.column(m, "Tier1", cx, cz, Hs + 0.75, Hs + 4.5, t1, white)
		Kit.lit(Kit.disc(m, "TierRing", cx, cz, Hs + 3.9, t1 + 0.5, 0.35, spireLook, "detail"), pal.spireKind)
		Kit.column(m, "Tier2", cx, cz, Hs + 4.48, Hs + 7.5, t2, white)
		local mast = Hs + SHAPE.mast
		Kit.column(m, "Mast", cx, cz, Hs + 7.48, mast, 0.5, Kit.look(rgb(220, 224, 228), Enum.Material.Metal), "detail")
		Kit.lit(Kit.ball(m, "Tip", Vector3.new(cx, mast + 0.6, cz), 1.2, spireLook), pal.spireKind)
	end

	-------------------------------------------------------------------------------------------------------
	-- The café terrace, open toward the corner door; umbrellas; the wash on the canopy at the corner
	-------------------------------------------------------------------------------------------------------
	local tTop = SHAPE.terraceTop
	Kit.box(
		m,
		"Terrace",
		Vector3.new(-hw + 0.2, 0, -hd + 0.3),
		Vector3.new(hw - 0.2, tTop, zF + SHAPE.recess + 0.2),
		Kit.look(P.deco.terrazzo, Enum.Material.SmoothPlastic)
	)
	local railTop = tTop + SHAPE.balustrade
	local a, c = -hw + 0.6, cx - 4
	Kit.box(m, "Balustrade", Vector3.new(a, tTop, -hd + 0.6), Vector3.new(c, railTop, -hd + 1.3), white)
	Kit.detail(
		m,
		"Coping",
		Vector3.new(a - 0.1, railTop, -hd + 0.5),
		Vector3.new(c + 0.1, railTop + 0.35, -hd + 1.4),
		bandLook
	)
	local tz = (-hd + 1.4 + zF) / 2
	local room = math.min(SHAPE.umbrella, (zF - 0.4 - tz) * 2, (tz + hd - 1.4) * 2)
	local len = c - a - 1.6
	local umbrellas = math.clamp(math.floor(len / (room + 3)), 0, 3)
	for j = 1, umbrellas do
		local x = a + 0.8 + len * (j - 0.5) / umbrellas
		local color = if j % 2 == 1 then pal.band else P.deco.white
		Kit.umbrella(m, `Umbrella{j}`, x, tz, tTop, math.min(room, len / umbrellas - 1), color)
	end
	Kit.wash(m, "Wash", cx - R - 4, cx + 4, zF - 1.8, G + cp.thick / 2, pal.wash)
end

local archetype: Types.Archetype = { id = "corner_spire_hotel", build = build }
return archetype
