--!strict
-- B04 deco_porthole_highrise (docs/city/ARCHETYPES.md §6, B04): the tall Deco hotel of the beach strip, ten to twelve
-- storeys of pale stone. A symmetrical front of seven (or five) bays: full-height piers standing 1.5 proud from the
-- terrace to just past the roof, deep spandrels on every floor line with the casement glass set 0.7 behind them, so
-- the facade is a grid of real shadow. The centre bay pushes out further as a tower of its own, a tall glazed slot
-- between two piers that carry vertical neon lines. At its foot, a projecting three-storey entry block: a lit door
-- under a half-moon hood, the name over it, a row of three portholes under half-moon eyebrows, a ribbon window and a
-- cornice. On the roof a stepped ziggurat as wide as the piers allow, each tier tucked between a pair of piers that
-- run on up past it as finials (so the roofline steps up in pier tops toward the centre), each tier ringed in neon,
-- and a flagpole.
--
-- What makes it itself: a pale stone tower of piers rising to a stepped ziggurat crown, with a porthole entry.
-- Placement, sizes, heights and its budget: Config/CityArchetypes/deco_porthole_highrise.
-- Variants: palette (3: ivory stone, peach with white piers, white with aqua piers; each with its ring neon and its
-- porthole neon), crown (1 three tiers and a flagpole, 2 two tiers and a stepped pyramid with a lit mast), rhythm
-- (1 seven bays, 2 five wider bays), mirror (symmetric: it changes only the stair house).
--
-- Previewed in Studio (2026-10-25): round 1 had a narrow three-bay crown that read as a roof box from the shore and a
-- generic grid; round 2 widened the tiers to the pier groups and ran the piers up through them as finials.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local City = require(ReplicatedStorage.Shared.Config.City)
local Kit = require(script.Parent.Parent.Parent.Kit)
local Types = require(script.Parent.Parent.Parent.Types)

local P = City.palettes
local KIT = City.kit
local FONT = City.districtLooks.beach.font
local rgb = Color3.fromRGB

-- The recipe, in studs.
local SHAPE = {
	ground = 16, -- the lobby floor
	parapet = 4, -- at least
	floorMin = 10.5,
	floorMax = 11.8,
	floors = { 9, 11 }, -- upper floors
	terrace = 12,
	bodyDepth = 40,
	sideInset = 2,
	wall = 1, -- the wall plane, behind the spandrels' faces
	glassIn = 0.7, -- the casement glass's face, behind the spandrels' faces
	sill = 2.2,
	head = 1.4,
	plinth = 2,
	lintel = 3, -- the lobby glass tops out this far under the first floor
	-- `back`: piers reach this far behind the spandrels' faces, so where they rise past the roof they stand against
	-- the crown's tiers (whose faces step back to 3.7) with no gap behind them.
	pier = { inner = 1.6, corner = 2.2, proud = 1.5, over = 1.4, back = 4.2 },
	tierTuck = 0.3, -- a tier's side stands this far inside the piers that flank it (its neon ring 0.15 out of it)
	bays = { 7, 5 }, -- by rhythm
	bay = { pier = 1.8, proud = 3, infill = 1.8, over = 1 }, -- the centre bay
	entry = { share = 0.36, min = 14, max = 30, out = 5.5, storeys = 2 },
	-- The door tops out `under` under the first floor; the name board sits `sign` over the door's top.
	door = { width = 10, under = 4, sign = 1.5, signHeight = 3 },
	porthole = 4.4,
	crownTiers = {
		-- Tall steps: at 7 a tier the crown read as a ledge on a 130-stud tower from the shore.
		{ { depth = 16, rise = 9 }, { depth = 12, rise = 8 }, { depth = 8, rise = 7 } },
		{ { depth = 16, rise = 9 }, { depth = 12, rise = 8 } },
	},
	pyramid = { 0.7, 0.45, 0.22 }, -- crown 2: the stepped pyramid's tiers, shares of the top tier
	pyramidRise = 1.8,
	flag = 6, -- crown 1
	mast = 30, -- crown 2: the mast's top over the roof
	sideBay = 6,
	terraceTop = 0.9,
	balustrade = 2.2,
	umbrella = 7.5,
}

-- Stone (body and spandrels), piers, trim (hoods, caps, porthole rims, the bay's day lines), neons, letters, wash.
local PALETTES = {
	{
		body = rgb(240, 234, 220),
		pier = rgb(250, 248, 242),
		trim = P.deco.aqua,
		ringKind = "crown",
		portKind = "neonAmber",
		letters = rgb(40, 120, 140),
		wash = rgb(255, 210, 160),
	},
	{
		body = rgb(255, 196, 160),
		pier = rgb(252, 248, 240),
		trim = P.deco.pink,
		ringKind = "neonPink",
		portKind = "neonAmber",
		letters = rgb(200, 70, 100),
		wash = rgb(255, 150, 170),
	},
	{
		body = rgb(246, 244, 238),
		pier = rgb(150, 216, 222),
		trim = P.deco.sky,
		ringKind = "neonBlue",
		portKind = "sign",
		letters = rgb(40, 100, 170),
		wash = rgb(150, 190, 255),
	},
}

local FRONT, LEFT, RIGHT = Enum.NormalId.Front, Enum.NormalId.Left, Enum.NormalId.Right

-- Upper floors and their height for a roof at `height`: whole floors, the parapet taking up the rest.
local function storeys(height: number): (number, number)
	local room = height - SHAPE.ground - SHAPE.parapet
	local up = math.clamp(math.floor(room / SHAPE.floorMin + 1e-6), SHAPE.floors[1], SHAPE.floors[2])
	return up, math.min(room / up, SHAPE.floorMax)
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

	local stone = Kit.look(pal.body, Enum.Material.SmoothPlastic)
	local pierLook = Kit.look(pal.pier, Enum.Material.SmoothPlastic)
	local trim = Kit.look(pal.trim, Enum.Material.SmoothPlastic)
	local plinthLook = Kit.look(rgb(214, 198, 168), Enum.Material.Limestone)

	local x0, x1 = -hw + SHAPE.sideInset, hw - SHAPE.sideInset
	local zF = -hd + SHAPE.terrace -- the spandrels' faces
	local zB = math.min(hd - 1, zF + SHAPE.bodyDepth)
	local zWall = zF + SHAPE.wall
	local Wf = x1 - x0
	local n = SHAPE.bays[math.clamp(variant.rhythm, 1, 2)]
	local b = Wf / n -- a bay, pier centre to pier centre
	local half = b / 2 -- the centre bay's half-width
	local centre = (n + 1) / 2 -- the centre bay's number; its piers are numbers centre - 1 and centre
	local pr = SHAPE.pier

	-------------------------------------------------------------------------------------------------------
	-- Body, plinth, lobby glass, the piers
	-------------------------------------------------------------------------------------------------------
	Kit.box(m, "Body", Vector3.new(x0, -KIT.bury, zWall), Vector3.new(x1, H, zB), stone)
	Kit.box(
		m,
		"Plinth",
		Vector3.new(x0 - 0.05, -KIT.bury, zF - 0.4),
		Vector3.new(x1 + 0.05, SHAPE.plinth, zWall + 0.3),
		plinthLook
	)
	local lobbyTop = G - SHAPE.lintel
	Kit.glass(
		m,
		"Lobby",
		Vector3.new(x0 + 0.6, SHAPE.plinth - 0.2, zF + SHAPE.glassIn),
		Vector3.new(x1 - 0.6, lobbyTop, zWall + 0.2),
		P.window.dark,
		{
			image = City.textures.windowBold,
			faces = { FRONT },
			u = b / 2,
			v = lobbyTop - SHAPE.plinth + 0.2,
			lines = pal.pier,
			lit = true,
		}
	)
	-- The ziggurat crown's tiers are as wide as the piers they rise between: pier group g stands (g + 0.5) bays out
	-- from the centre (g 0 is the centre bay's own pair), and tier k covers the groups up to `outer - k`, so each
	-- tier's sides tuck just inside a pair of piers, and those piers run on up past it as stepped finials.
	local tierSpec = SHAPE.crownTiers[crown]
	local outer = (n - 1) / 2
	local function pierHalf(g: number): number
		return if g == 0 then SHAPE.bay.pier / 2 else pr.inner / 2
	end
	local function covered(g: number): number
		local sum = 0
		for k, tier in tierSpec do
			if outer - k >= g then
				sum += tier.rise
			end
		end
		return sum
	end
	for i, sx in { -1, 1 } do
		local outerX = if sx < 0 then x0 - 0.1 else x1 + 0.1
		local inner = if sx < 0 then x0 + pr.corner else x1 - pr.corner
		Kit.box(
			m,
			`Corner{i}`,
			Vector3.new(outerX, -KIT.bury, zF - pr.proud),
			Vector3.new(inner, H + pr.over, zWall + 0.3),
			pierLook
		)
	end
	for i = 1, n - 1 do
		if i == centre - 1 or i == centre then
			continue -- the centre bay's own piers stand there
		end
		local px = x0 + i * b
		local g = math.round(math.abs(px) / b - 0.5)
		Kit.box(
			m,
			`Pier{i}`,
			Vector3.new(px - pr.inner / 2, -KIT.bury, zF - pr.proud),
			Vector3.new(px + pr.inner / 2, H + covered(g) + pr.over, zF + pr.back),
			pierLook
		)
	end

	-------------------------------------------------------------------------------------------------------
	-- Spandrels on every floor line (0 the lintel, `up` the parapet) and the casement glass set in between
	-------------------------------------------------------------------------------------------------------
	for k = 0, up do
		local y0 = if k == 0 then lobbyTop else G + k * f - SHAPE.head
		local y1 = if k == up then H - 0.04 else G + k * f + SHAPE.sill
		Kit.box(m, `Spandrel{k}`, Vector3.new(x0, y0, zF), Vector3.new(x1, y1, zWall + 0.3), stone)
	end
	local casement = b / math.max(2, math.round(b / 2.8))
	for k = 1, up do
		local y0 = G + (k - 1) * f + SHAPE.sill
		local y1 = G + k * f - SHAPE.head
		Kit.glass(
			m,
			`Window{k}`,
			Vector3.new(x0 + 0.2, y0, zF + SHAPE.glassIn),
			Vector3.new(x1 - 0.2, y1, zWall + 0.2),
			P.window.dark,
			{
				image = City.textures.windowFine,
				faces = { FRONT },
				u = casement,
				v = y1 - y0,
				lines = pal.pier,
				reflectance = 0.2,
			}
		)
	end
	Kit.trim(m, "Coping", Vector3.new(x0, H - 0.1, zF - 0.4), Vector3.new(x1, H + 0.5, zWall + 0.3), pierLook)
	for i, sx in { -1, 1 } do
		local wallX = if sx < 0 then x0 else x1
		Kit.punched(
			m,
			`Side{i}`,
			Vector3.new(wallX - sx * 0.4, G, zWall + 0.6),
			Vector3.new(wallX + sx * 0.06, T, zB - 0.6),
			pal.body,
			P.window.dark,
			{ if sx < 0 then LEFT else RIGHT },
			SHAPE.sideBay,
			f
		)
	end

	-------------------------------------------------------------------------------------------------------
	-- The entry block: three storeys, a lit door under a half-moon hood, three portholes, a ribbon, a cornice
	-------------------------------------------------------------------------------------------------------
	local en = SHAPE.entry
	local ew = math.clamp(Wf * en.share, en.min, math.max(en.min, math.min(en.max, 3 * b - 2.8)))
	local zE = zF - en.out
	local Ye = G + en.storeys * f -- the entry's roof
	Kit.box(m, "Entry", Vector3.new(-ew / 2, -KIT.bury, zE), Vector3.new(ew / 2, Ye, zWall + 0.3), stone)
	Kit.trim(
		m,
		"EntryCap",
		Vector3.new(-ew / 2 - 0.6, Ye - 0.3, zE - 0.6),
		Vector3.new(ew / 2 + 0.6, Ye + 0.7, zF + 0.5),
		pierLook
	)
	local doorTop = G - SHAPE.door.under
	local dw = math.min(SHAPE.door.width, ew - 6)
	Kit.glass(
		m,
		"Door",
		Vector3.new(-dw / 2, SHAPE.terraceTop - 0.3, zE - 0.3),
		Vector3.new(dw / 2, doorTop, zE + 0.3),
		P.window.dark,
		{
			image = City.textures.windowBold,
			faces = { FRONT },
			u = dw / 3,
			v = doorTop - SHAPE.terraceTop + 0.3,
			lines = pal.pier,
			lit = true,
		}
	)
	local hood = math.min(dw + 4, 2 * (zE + hd - 1.6))
	Kit.disc(m, "DoorHood", 0, zE, doorTop + 0.4, hood, 0.8, trim, "trim")
	-- The name over the door, under the portholes (the crown's tiers are crossed by piers, so it lives down here
	-- where the street reads it).
	local names = City.signNames.hotels
	local sy = doorTop + SHAPE.door.sign
	Kit.sign(
		m,
		"Sign",
		Vector3.new(-ew / 2 + 1.6, sy, zE - 0.4),
		Vector3.new(ew / 2 - 1.6, sy + SHAPE.door.signHeight, zE + 0.05),
		FRONT,
		names[rng:NextInteger(1, #names)],
		pal.pier,
		pal.letters,
		FONT
	)
	local spacing = ew / 3.4
	local pd = math.min(SHAPE.porthole, spacing - 1.4)
	local py = G + f / 2
	for i, px in { -spacing, 0, spacing } do
		Kit.porthole(m, `Port{i}`, px, py, zE, pd, P.window.deep, trim, pal.portKind)
		Kit.disc(m, `PortHood{i}`, px, zE, py + pd / 2 + 0.9, math.min(pd + 2, spacing - 0.3), 0.5, pierLook, "trim")
	end
	Kit.glass(
		m,
		"EntryRibbon",
		Vector3.new(-ew / 2 + 1.5, G + f + SHAPE.sill, zE - 0.12),
		Vector3.new(ew / 2 - 1.5, Ye - 1, zE + 0.3),
		P.window.dark,
		{
			image = City.textures.windowFine,
			faces = { FRONT },
			u = 2.4,
			v = Ye - 1 - G - f - SHAPE.sill,
			lines = pal.pier,
			reflectance = 0.2,
		}
	)

	-------------------------------------------------------------------------------------------------------
	-- The centre bay: two proud piers with neon lines, a glazed slot between them over a set-forward infill
	-------------------------------------------------------------------------------------------------------
	local bay = SHAPE.bay
	Kit.box(m, "Bay", Vector3.new(-half, Ye - 0.5, zF - bay.infill), Vector3.new(half, H + 0.5, zWall + 0.3), stone)
	local bayTop = H + covered(0) + bay.over
	for i, sx in { -1, 1 } do
		local px = sx * half
		Kit.box(
			m,
			`BayPier{i}`,
			Vector3.new(px - bay.pier / 2, Ye - 0.5, zF - bay.proud),
			Vector3.new(px + bay.pier / 2, bayTop, zF + pr.back),
			pierLook
		)
		Kit.neon(
			m,
			`BayNeon{i}`,
			Vector3.new(px, Ye + 1, zF - bay.proud - 0.35),
			Vector3.new(px, bayTop - 0.6, zF - bay.proud - 0.35),
			pal.ringKind,
			pal.trim
		)
	end
	local slot = 2 * half - bay.pier
	Kit.glass(
		m,
		"Slot",
		Vector3.new(-slot / 2, Ye + 0.7, zF - bay.infill - 0.3),
		Vector3.new(slot / 2, T - SHAPE.head, zF - bay.infill + 0.1),
		P.window.dark,
		{
			image = City.textures.slabLine,
			faces = { FRONT },
			u = slot,
			v = f,
			lines = pal.pier,
			reflectance = 0.2,
		}
	)

	-------------------------------------------------------------------------------------------------------
	-- The crown: a ziggurat ringed in neon, the name on its first tier, a flagpole or a stepped pyramid and mast
	-------------------------------------------------------------------------------------------------------
	local tiers: { { width: number, depth: number, height: number } } = {}
	for k, tier in tierSpec do
		local g = outer - k
		local hw2 = if g >= 0 then (g + 0.5) * b + pierHalf(g) - SHAPE.tierTuck else half - bay.pier / 2 - 0.8 -- past the last pair of piers: inside the centre bay's pair
		table.insert(tiers, { width = 2 * hw2, depth = tier.depth, height = tier.rise })
	end
	local zc = zF - 0.3 + tiers[1].depth / 2 -- the first tier's face 0.3 proud of the parapet
	local _, top = Kit.steppedCrown(m, "Crown", 0, zc, H, tiers, stone, { kind = pal.ringKind, color = pal.trim })
	local metal = Kit.look(rgb(220, 224, 228), Enum.Material.Metal)
	local trimLit = Kit.look(pal.trim, Enum.Material.SmoothPlastic)
	if crown == 1 then
		Kit.column(m, "Flagpole", 0, zc, top - 0.02, top + SHAPE.flag, 0.35, metal, "detail")
		Kit.lit(Kit.ball(m, "Finial", Vector3.new(0, top + SHAPE.flag + 0.5, zc), 1, trimLit), pal.ringKind)
	else
		local y = top
		local last = tiers[#tiers]
		for i, share in SHAPE.pyramid do
			local hx, hz = last.width * share / 2, last.depth * share / 2
			Kit.box(
				m,
				`Pyramid{i}`,
				Vector3.new(-hx, y - 0.02, zc - hz),
				Vector3.new(hx, y + SHAPE.pyramidRise, zc + hz),
				stone
			)
			y += SHAPE.pyramidRise - 0.02
		end
		local mast = H + SHAPE.mast
		Kit.column(m, "Mast", 0, zc, y, mast, 0.4, metal, "detail")
		Kit.lit(Kit.ball(m, "Finial", Vector3.new(0, mast + 0.6, zc), 1.2, trimLit), pal.ringKind)
	end
	Kit.roofBox(m, "Stair", Vector3.new(x1 - 12, H, zB - 11), Vector3.new(x1 - 4, H + 7, zB - 3), stone)

	-------------------------------------------------------------------------------------------------------
	-- The café terrace either side of the entry, umbrellas, and the wash on the entry's roof
	-------------------------------------------------------------------------------------------------------
	local tTop = SHAPE.terraceTop
	Kit.box(
		m,
		"Terrace",
		Vector3.new(-hw + 0.2, 0, -hd + 0.3),
		Vector3.new(hw - 0.2, tTop, zWall + 0.3),
		Kit.look(P.deco.terrazzo, Enum.Material.SmoothPlastic)
	)
	local railTop = tTop + SHAPE.balustrade
	local front = zF - pr.proud -- the piers' faces: the umbrellas keep clear of them
	local tz = (-hd + 1.4 + front) / 2
	local room = math.min(SHAPE.umbrella, (front - 0.4 - tz) * 2, (tz + hd - 1.4) * 2)
	local segments = { { -hw + 0.6, -ew / 2 - 0.8 }, { ew / 2 + 0.8, hw - 0.6 } }
	for i, seg in segments do
		local a, c = seg[1], seg[2]
		if c - a < 1 then
			continue
		end
		Kit.box(m, `Balustrade{i}`, Vector3.new(a, tTop, -hd + 0.6), Vector3.new(c, railTop, -hd + 1.3), pierLook)
		Kit.detail(
			m,
			`Coping{i}`,
			Vector3.new(a - 0.1, railTop, -hd + 0.5),
			Vector3.new(c + 0.1, railTop + 0.35, -hd + 1.4),
			trim
		)
		local len = c - a - 1.6
		local count = math.clamp(math.floor(len / (room + 3)), 0, 2)
		for j = 1, count do
			local x = a + 0.8 + len * (j - 0.5) / count
			local color = if (i + j) % 2 == 0 then pal.trim else P.deco.white
			Kit.umbrella(m, `Umbrella{i}{j}`, x, tz, tTop, math.min(room, len / count - 1), color)
		end
	end
	Kit.wash(m, "Wash", -half - 1.2, half + 1.2, zF - bay.proud - 0.8, Ye + 0.7, pal.wash)
end

local archetype: Types.Archetype = { id = "deco_porthole_highrise", build = build }
return archetype
