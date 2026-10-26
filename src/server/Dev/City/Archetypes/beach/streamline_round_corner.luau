--!strict
-- B05 streamline_round_corner (docs/city/ARCHETYPES.md §6, B05): the Streamline Moderne hotel of the beach strip, all
-- horizontals. Both front corners are big drums standing on a keystone base; every floor's glass band wraps round
-- them as a glass ring, and pastel eyebrows with rounded ends wrap them like the chrome on a car's fender. The front
-- is asymmetric, as on its inspiration: a long four-light ribbon on one side of the central bay, a pair of shorter
-- windows on the other. The central bay is framed in pink keystone, stands a little proud with the eyebrows running
-- across it, and rises past the roof as a pediment flanked by two chrome medallions; three speed lines ring each drum
-- under a pastel cornice. The keystone ground floor is set back behind the drums under a pastel canopy whose fascia
-- carries the name, behind a café terrace.
--
-- What makes it itself: two fully rounded corners with bands of eyebrow and glass wrapping them like a fender.
-- Placement, sizes, heights and its budget: Config/CityArchetypes/streamline_round_corner.
-- Placed on block corners when it can (Config/City cornerArchetypes "prefer"): its always-round corner and the long
-- ribbon are drawn at the +x end, and placement mirrors them onto the street corner.
-- Variants: palette (5 pastels, each with its neon), crown (1 a stepped pediment, 2 a flat-topped bay and the name
-- stacked down a vertical blade standing on each round drum, neon on its edges, as on a 1948 postcard), rhythm (1 both
-- corners round, 2 only the right one: the left corner square, unless the left end is a street corner too), mirror
-- (the asymmetric front: the long ribbon, the pair of windows and the round corner change sides).
--
-- Round 3 (2026-10-26, from a photo and a 1948 postcard of the inspiration): bigger drums, the keystone frame round
-- the central bay, chrome medallions, the name moved down to the canopy's fascia as on the real porch, the rooftop
-- name blade, and the night line moved off the cornice (now still parts) onto the top speed line and the canopy.
-- Preview check: the drums read as fenders (eyebrow discs and glass rings flush with the flat front's bands), the
-- keystone bay reads pink against the white, the fascia's name sits under the canopy's edge clear of the umbrellas,
-- and crown 2's blade stands on the roof behind the right drum, its letters on both faces.
-- Round 4 (2026-10-26, seen in Studio): crown 2's half-round pediment read as a pink tombstone and its one blade hid
-- behind the drum; now the bay stays flat and a name blade stands on each round drum, letters clear of the cornice.

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
	parapet = 3.6, -- at least
	floorMin = 10.3,
	floorMax = 11.8,
	floors = { 2, 2 },
	terrace = 9,
	bodyDepth = 40,
	sideInset = 3.4, -- the canopy's discs reach this far round the drums
	radius = { share = 0.15, min = 7, max = 10 }, -- the drums
	recess = 1.4, -- the ground floor's wall, behind the drums' front
	sill = 2.4,
	head = 1.5,
	lintel = 2.4, -- the shop glass tops out this far under the first floor
	eyebrow = { thick = 0.6, proud = 2.8 },
	canopy = { thick = 1, proud = 3.2 },
	cornice = { thick = 0.7, proud = 1.4 },
	bay = { share = 0.2, min = 10, max = 15, proud = 1, rise = 4.5, step = 2 },
	pair = 0.72, -- the shorter windows, a share of the ribbon's height
	ribs = { 0.7, 1.5, 2.3 }, -- the speed lines round the drums, over the top floor line (the last one lights)
	medallion = 3.2,
	fascia = { reach = 2, drop = 2.4 }, -- the name board under the canopy: past the bay each side, and its height
	-- Crown 2: the name blades on the drums (their neon starts `lift` over the roof, clear of the cornice), over the roof.
	blade = { width = 4.4, thick = 0.8, lift = 1.6, top = 15.2 },
	sideBay = 6.5,
	terraceTop = 0.9,
	balustrade = 2.2,
	gate = 3.5,
	umbrella = 7.5,
}

-- The pastel (eyebrows, cornice, speed lines, medallions, umbrellas), its neon, the sign's letters and the wash.
local PALETTES = {
	{ pastel = P.deco.peach, neon = "neonPink", letters = rgb(220, 90, 70), wash = rgb(255, 150, 170) },
	{ pastel = P.deco.mint, neon = "neonCyan", letters = rgb(30, 140, 120), wash = rgb(120, 230, 220) },
	{ pastel = P.deco.sky, neon = "neonBlue", letters = rgb(40, 110, 180), wash = rgb(140, 190, 255) },
	{ pastel = P.deco.lilac, neon = "neonViolet", letters = rgb(120, 84, 190), wash = rgb(200, 150, 255) },
	{ pastel = P.deco.lemon, neon = "neonAmber", letters = rgb(200, 140, 30), wash = rgb(255, 200, 140) },
}

local FRONT, BACK, LEFT, RIGHT = Enum.NormalId.Front, Enum.NormalId.Back, Enum.NormalId.Left, Enum.NormalId.Right

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
	local pinkStone = Kit.look(rgb(226, 178, 164), Enum.Material.SmoothPlastic)
	local chrome = Kit.look(rgb(220, 224, 228), Enum.Material.Metal)
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
	-- A neon line along the canopy's straight edge.
	Kit.neon(
		m,
		"CanopyNeon",
		Vector3.new(xa + 0.4, G + 0.15, zF - cp.proud - 0.25),
		Vector3.new(xb - 0.4, G + 0.15, zF - cp.proud - 0.25),
		pal.neon,
		pal.pastel
	)

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
	-- The top: the keystone bay's pediment, the medallions, speed lines round the drums, the cornice
	-------------------------------------------------------------------------------------------------------
	Kit.box(m, "Bay", Vector3.new(bx0, G + 0.3, zBay), Vector3.new(bx1, H + bay.rise, zF + 1.2), pinkStone)
	if crown == 1 then
		Kit.box(
			m,
			"BayStep",
			Vector3.new(bx0 + 1.4, H + bay.rise - 0.02, zBay + 0.4),
			Vector3.new(bx1 - 1.4, H + bay.rise + bay.step, zF + 1),
			pinkStone
		)
	end
	-- (Crown 2's bay stays flat-topped: its signature is the name blades on the drums, below. A half-round pediment
	-- read as a pink tombstone in the preview.)
	-- Chrome medallions either side of the bay, on the parapet between the top eyebrow and the cornice (as big as
	-- that leaves room for), their centres glowing at night.
	local cn = SHAPE.cornice
	local below, above = T - SHAPE.head + 0.4 + brow.thick / 2, H - cn.thick + 0.06
	local medal = math.min(SHAPE.medallion, above - below - 0.4)
	for i, side in { -1, 1 } do
		Kit.porthole(m, `Medal{i}`, side * (bw / 2 + 2.4), (below + above) / 2, zF, medal, pal.pastel, chrome, pal.neon)
	end
	for i, cx in drums do
		for j, rise in SHAPE.ribs do
			local rib = Kit.disc(m, `Rib{i}{j}`, cx, cz, T + rise, 2 * R + 0.7, 0.3, pastel, "trim")
			if j == #SHAPE.ribs then
				Kit.lit(rib, pal.neon)
			end
		end
	end
	Kit.band(m, "Cornice", bodyMin, bodyMax, R, corners, H - cn.thick / 2 + 0.06, cn.thick, cn.proud, pastel, "front")
	for i, side in { -1, 1 } do
		local wallX = if side < 0 then x0 else x1
		Kit.punched(
			m,
			`Side{i}`,
			Vector3.new(wallX - side * 0.4, G, cz + 0.6),
			Vector3.new(wallX + side * 0.06, T, zB - 0.6),
			P.deco.white,
			P.window.dark,
			{ if side < 0 then LEFT else RIGHT },
			SHAPE.sideBay,
			f
		)
	end
	Kit.roofBox(m, "Stair", Vector3.new(x1 - 11, H, zB - 10), Vector3.new(x1 - 4, H + 6, zB - 3), white)

	-------------------------------------------------------------------------------------------------------
	-- The name: on the canopy's fascia over the porch; with crown 2 also stacked down a lit blade on the roof
	-------------------------------------------------------------------------------------------------------
	-- With the blade, a name short enough to stack (the leading "THE " dropped), so the fascia and the blade agree.
	local names = City.signNames.hotels
	local pool: { string } = {}
	if crown == 2 then
		for _, entry in names do
			local word = string.gsub(entry, "^THE ", "")
			if #word <= 9 and not string.find(word, " ", 1, true) then
				table.insert(pool, entry)
			end
		end
	end
	if #pool == 0 then
		pool = names
	end
	local name = pool[rng:NextInteger(1, #pool)]
	local fa = SHAPE.fascia
	local zCanopy = zF - cp.proud -- the canopy's straight edge
	Kit.sign(
		m,
		"Sign",
		Vector3.new(bx0 - fa.reach, G - cp.thick / 2 - fa.drop, zCanopy - 0.15),
		Vector3.new(bx1 + fa.reach, G - cp.thick / 2 + 0.05, zCanopy + 0.1),
		FRONT,
		name,
		P.deco.white,
		pal.letters,
		FONT
	)
	if crown == 2 then
		-- The name stacked down a blade standing on each round drum's top, as on the inspiration's postcard.
		local bl = SHAPE.blade
		local word = string.gsub(name, "^THE ", "")
		local letters: { string } = {}
		for i = 1, #word do
			table.insert(letters, string.sub(word, i, i))
		end
		local stacked = table.concat(letters, "\n")
		local y0 = H - 0.1
		for d, bxc in drums do
			local blade = Kit.sign(
				m,
				`Blade{d}`,
				Vector3.new(bxc - bl.width / 2, y0, cz - bl.thick / 2),
				Vector3.new(bxc + bl.width / 2, H + bl.top, cz + bl.thick / 2),
				FRONT,
				stacked,
				P.deco.white,
				pal.letters,
				FONT
			)
			-- Neon down both front edges (a lit board would glow in the letters' own hue and lose them).
			for i, side in { -1, 1 } do
				local ex = bxc + side * (bl.width / 2 - 0.1)
				Kit.neon(
					m,
					`BladeNeon{d}{i}`,
					Vector3.new(ex, H + bl.lift, cz - bl.thick / 2 - 0.2),
					Vector3.new(ex, H + bl.top - 0.3, cz - bl.thick / 2 - 0.2),
					pal.neon,
					pal.pastel
				)
			end
			local labels: { MapTypes.LabelSpec } = blade.labels or {}
			table.insert(labels, {
				face = BACK,
				text = stacked,
				color = pal.letters,
				font = FONT,
				size = Vector2.new(0.8, 0.92),
				pixelsPerStud = KIT.signPixelsPerStud,
			})
			-- The letters keep to the blade's upper part: from the street the drum's cornice hides its foot.
			for _, lbl in labels do
				lbl.size = Vector2.new(0.8, 0.72)
				lbl.center = Vector2.new(0.5, 0.4)
			end
			blade.labels = labels
		end
	end

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
	-- On the canopy, behind its edge, washing the floors and the drums.
	Kit.wash(m, "Wash", (if fl then xa else x0) + 1, xb - 1, zF - cp.proud + 1.2, G + cp.thick / 2, pal.wash)
end

local archetype: Types.Archetype = { id = "streamline_round_corner", build = build }
return archetype
