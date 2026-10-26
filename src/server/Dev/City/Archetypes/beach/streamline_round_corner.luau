--!strict
-- B05 streamline_round_corner (docs/city/ARCHETYPES.md §6, B05): the Streamline Moderne hotel of the beach strip,
-- all horizontals. Both front corners are big drums (16 across on a wide site) standing on a keystone base; every
-- floor's glass band wraps round them as a glass ring, and pastel eyebrows with rounded ends wrap them like the
-- chrome on a car's fender. The front is asymmetric, as on its inspiration: a long four-light ribbon on one side of
-- the central bay, a pair of shorter windows on the other. The central bay stands a little proud, the eyebrows
-- running across it, and rises past the roof as a pediment carrying the name, flanked by two porthole medallions;
-- three speed lines ring each drum under a pastel cornice that turns into one neon line round both corners at night.
-- A keystone-clad ground floor is set back behind the drums with a café terrace in front.
--
-- What makes it itself: two fully rounded corners with bands of eyebrow and glass wrapping them like a fender.
-- Placement, sizes, heights and its budget: Config/CityArchetypes/streamline_round_corner.
-- Placed on block corners when it can (Config/City cornerArchetypes "prefer"): its always-round corner and the long
-- ribbon are drawn at the +x end, and placement mirrors them onto the street corner.
-- Variants: palette (5 pastels, each with its neon), crown (1 a stepped pediment, 2 a half-round "rising sun"
-- pediment), rhythm (1 both corners round, 2 only the right one: the left corner square, unless the left end is a
-- street corner too), mirror (the asymmetric front: the long ribbon, the pair of windows and the round corner change
-- sides).
--
-- Previewed in Studio (2026-10-25, docs/images/city/streamline_round_corner-*.jpg): the glass rings, eyebrow discs
-- and the lit cornice read; round 2 made the keystone base smooth and warmer and the medallions bigger.

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
	ground = 14,
	parapet = 3.6, -- at least
	floorMin = 10.3,
	floorMax = 11.8,
	floors = { 2, 2 },
	terrace = 9,
	bodyDepth = 40,
	sideInset = 3.4, -- the canopy's discs reach this far round the drums
	radius = { share = 0.13, min = 6, max = 8 }, -- the drums
	recess = 1.4, -- the ground floor's wall, behind the drums' front
	sill = 2.4,
	head = 1.5,
	lintel = 2.4, -- the shop glass tops out this far under the first floor
	eyebrow = { thick = 0.6, proud = 2.8 },
	canopy = { thick = 1, proud = 3.2 },
	cornice = { thick = 0.7, proud = 1.4 },
	bay = { share = 0.2, min = 10, max = 15, proud = 1, rise = 4.5, step = 2 },
	pair = 0.72, -- the shorter windows, a share of the ribbon's height
	ribs = { 0.7, 1.5, 2.3 }, -- the speed lines round the drums, over the top floor line
	medallion = 3.2,
	sideBay = 6.5,
	terraceTop = 0.9,
	balustrade = 2.2,
	gate = 3.5,
	umbrella = 7.5,
}

-- The pastel (eyebrows, cornice, speed lines, medallions, umbrellas), its neon, the sign's letters and the wash.
local PALETTES = {
	{ pastel = P.deco.peach, neon = "neonPink", letters = rgb(220, 90, 70), wash = rgb(255, 150, 170) },
	{ pastel = P.deco.mint, neon = "sign", letters = rgb(30, 140, 120), wash = rgb(120, 230, 220) },
	{ pastel = P.deco.sky, neon = "neonBlue", letters = rgb(40, 110, 180), wash = rgb(140, 190, 255) },
	{ pastel = P.deco.lilac, neon = "neonViolet", letters = rgb(120, 84, 190), wash = rgb(200, 150, 255) },
	{ pastel = P.deco.lemon, neon = "neonAmber", letters = rgb(200, 140, 30), wash = rgb(255, 200, 140) },
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

	local white = Kit.look(P.deco.white, Enum.Material.SmoothPlastic)
	local pastel = Kit.look(pal.pastel, Enum.Material.SmoothPlastic)
	-- Smooth, not Limestone: in the porch's shade the Limestone texture read as dirty grey-green in the preview.
	local keystone = Kit.look(rgb(238, 214, 178), Enum.Material.SmoothPlastic)
	local ringGlass = Kit.glassLook(P.window.dark, 0.2)

	local R = math.clamp(W * SHAPE.radius.share, SHAPE.radius.min, SHAPE.radius.max)
	local fl = variant.rhythm ~= 2 or site.corner.left -- rhythm 2: the left corner square (unless it is a corner)
	local corners = { fl = fl, fr = true }
	local x0, x1 = -hw + SHAPE.sideInset, hw - SHAPE.sideInset
	local zF = -hd + SHAPE.terrace
	local zB = math.min(hd - 1, zF + SHAPE.bodyDepth)
	local cz = zF + R -- the drums' centres
	local xa = if fl then x0 + R else x0 - 0.05 -- the flat front's ends
	local xb = x1 - R
	local drums: { number } = {}
	if fl then
		table.insert(drums, x0 + R)
	end
	table.insert(drums, x1 - R)
	local bodyMin, bodyMax = Vector3.new(x0, 0, zF), Vector3.new(x1, 0, zB)

	-------------------------------------------------------------------------------------------------------
	-- Body: the block, the upper floors' front, the set-back keystone ground floor, the drums
	-------------------------------------------------------------------------------------------------------
	Kit.box(m, "Core", Vector3.new(x0, -KIT.bury, cz), Vector3.new(x1, H, zB), white)
	Kit.box(m, "Upper", Vector3.new(xa, G, zF), Vector3.new(xb, H - 0.03, cz + 0.4), white)
	Kit.box(m, "Ground", Vector3.new(xa, -KIT.bury, zF + SHAPE.recess), Vector3.new(xb, G, cz + 0.4), keystone)
	if not fl then
		Kit.box(
			m,
			"Pier",
			Vector3.new(x0 - 0.1, -KIT.bury, zF),
			Vector3.new(x0 + 3, G, zF + SHAPE.recess + 0.3),
			keystone
		)
	end
	for i, cx in drums do
		Kit.column(m, `DrumBase{i}`, cx, cz, -KIT.bury, G, 2 * R, keystone)
		Kit.column(m, `Drum{i}`, cx, cz, G, H - 0.02, 2 * R, white)
	end
	Kit.glass(
		m,
		"Shop",
		Vector3.new(if fl then xa + 1.2 else x0 + 3, SHAPE.terraceTop - 0.3, zF + SHAPE.recess - 0.3),
		Vector3.new(xb - 1.2, G - SHAPE.lintel, zF + SHAPE.recess + 0.2),
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
	local cp = SHAPE.canopy
	Kit.band(m, "Canopy", bodyMin, bodyMax, R, corners, G, cp.thick, cp.proud, pastel, "front")

	-------------------------------------------------------------------------------------------------------
	-- The floors: the long ribbon, the pair of windows, glass rings round the drums, the bay's windows, eyebrows
	-------------------------------------------------------------------------------------------------------
	local bay = SHAPE.bay
	local bw = math.clamp(W * bay.share, bay.min, bay.max)
	local bx0, bx1 = -bw / 2, bw / 2
	local zBay = zF - bay.proud
	local pairX = if fl then xa + 2.6 else x0 + 2.2
	local brow = SHAPE.eyebrow
	for k = 1, up do
		local y0 = G + (k - 1) * f + SHAPE.sill
		local y1 = G + k * f - SHAPE.head
		local tall = y1 - y0
		Kit.glass(m, `Ribbon{k}`, Vector3.new(bx1 - 0.5, y0, zF - 0.12), Vector3.new(xb, y1, zF + 0.4), P.window.dark, {
			image = City.textures.windowBold,
			faces = { FRONT },
			u = (xb - bx1 + 0.5) / 4,
			v = tall,
			lines = P.deco.white,
			reflectance = 0.2,
		})
		Kit.glass(
			m,
			`Pair{k}`,
			Vector3.new(pairX, y1 - tall * SHAPE.pair, zF - 0.12),
			Vector3.new(bx0 + 0.5, y1, zF + 0.4),
			P.window.dark,
			{
				image = City.textures.windowBold,
				faces = { FRONT },
				u = (bx0 + 0.5 - pairX) / 2,
				v = tall * SHAPE.pair,
				lines = P.deco.white,
				reflectance = 0.2,
			}
		)
		for i, cx in drums do
			Kit.column(m, `Ring{i}{k}`, cx, cz, y0, y1, 2 * R + 0.1, ringGlass)
		end
		Kit.glass(
			m,
			`BayGlass{k}`,
			Vector3.new(bx0 + 1.2, y0, zBay - 0.12),
			Vector3.new(bx1 - 1.2, y1, zBay + 0.3),
			P.window.dark,
			{
				image = City.textures.windowBold,
				faces = { FRONT },
				u = (bw - 2.4) / 2,
				v = tall,
				lines = P.deco.white,
				reflectance = 0.2,
			}
		)
		Kit.band(m, `Brow{k}`, bodyMin, bodyMax, R, corners, y1 + 0.4, brow.thick, brow.proud, pastel, "front")
	end

	-------------------------------------------------------------------------------------------------------
	-- The top: the bay's pediment with the name, the medallions, speed lines round the drums, the lit cornice
	-------------------------------------------------------------------------------------------------------
	Kit.box(m, "Bay", Vector3.new(bx0, G + 0.3, zBay), Vector3.new(bx1, H + bay.rise, zF + 1.2), white)
	if crown == 1 then
		Kit.box(
			m,
			"BayStep",
			Vector3.new(bx0 + 1.4, H + bay.rise - 0.02, zBay + 0.4),
			Vector3.new(bx1 - 1.4, H + bay.rise + bay.step, zF + 1),
			white
		)
	else
		-- A half-round pediment: a cylinder lying front to back on the bay, its face a hair proud of the bay's.
		Kit.tube(
			m,
			"BayArch",
			Vector3.new(0, H + bay.rise, zBay - 0.1),
			Vector3.new(0, H + bay.rise, zF + 1.1),
			bw,
			white,
			"box"
		)
	end
	local names = City.signNames.hotels
	Kit.sign(
		m,
		"Sign",
		Vector3.new(bx0 + 0.8, H + 0.3, zBay - 0.45),
		Vector3.new(bx1 - 0.8, H + bay.rise - 0.3, zBay + 0.05),
		FRONT,
		names[rng:NextInteger(1, #names)],
		P.deco.white,
		pal.letters,
		FONT
	)
	for i, sx in { -1, 1 } do
		Kit.porthole(m, `Medal{i}`, sx * (bw / 2 + 2.4), T + 1.5, zF, SHAPE.medallion, pal.pastel, white, pal.neon)
	end
	for i, cx in drums do
		for j, rise in SHAPE.ribs do
			Kit.disc(m, `Rib{i}{j}`, cx, cz, T + rise, 2 * R + 0.7, 0.3, pastel, "trim")
		end
	end
	local cn = SHAPE.cornice
	local cornice = Kit.band(
		m,
		"Cornice",
		bodyMin,
		bodyMax,
		R,
		corners,
		H - cn.thick / 2 + 0.06,
		cn.thick,
		cn.proud,
		pastel,
		"front"
	)
	for _, spec in cornice do
		Kit.lit(spec, pal.neon)
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
	Kit.roofBox(m, "Stair", Vector3.new(x1 - 11, H, zB - 10), Vector3.new(x1 - 4, H + 6, zB - 3), white)

	-------------------------------------------------------------------------------------------------------
	-- The café terrace in front of the drums, market umbrellas, and the wash on the canopy
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
	local tz = (-hd + 1.4 + zF) / 2
	local room = math.min(SHAPE.umbrella, (zF - 0.4 - tz) * 2, (tz + hd - 1.4) * 2)
	local segments = { { -hw + 0.6, -SHAPE.gate }, { SHAPE.gate, hw - 0.6 } }
	for i, seg in segments do
		local a, c = seg[1], seg[2]
		Kit.box(m, `Balustrade{i}`, Vector3.new(a, tTop, -hd + 0.6), Vector3.new(c, railTop, -hd + 1.3), white)
		Kit.detail(
			m,
			`Coping{i}`,
			Vector3.new(a - 0.1, railTop, -hd + 0.5),
			Vector3.new(c + 0.1, railTop + 0.35, -hd + 1.4),
			pastel
		)
		local len = c - a - 1.6
		local count = math.clamp(math.floor(len / (room + 3)), 0, 2)
		for j = 1, count do
			local x = a + 0.8 + len * (j - 0.5) / count
			local color = if (i + j) % 2 == 0 then pal.pastel else P.deco.white
			Kit.umbrella(m, `Umbrella{i}{j}`, x, tz, tTop, math.min(room, len / count - 1), color, true)
		end
	end
	Kit.wash(m, "Wash", (if fl then xa else x0) + 1, xb - 1, zF - cp.proud + 0.8, G + cp.thick / 2, pal.wash)
end

local archetype: Types.Archetype = { id = "streamline_round_corner", build = build }
return archetype
