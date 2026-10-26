--!strict
-- B01 deco_stripe_hotel (docs/city/ARCHETYPES.md §6, B01): the beach strip's Art Deco hotel. A white stucco block
-- with both front corners rounded, its upper floors overhanging a shaded porch; continuous eyebrows over ribbon
-- windows that wrap the rounded corners; and its signature, three tall fluted pilasters that run up past the
-- roofline, each crowned with a half-moon hood and a stepped cap, the centre one carrying a flagpole. A stepped
-- parapet between them, pierced grille panels, a name sign over the porch, a neon line under the cornice, a
-- terrazzo café terrace with umbrellas and a low balustrade, and a wash that lights the facade at night.
--
-- What makes it itself: three stripes rising past the roof, each with a half-moon and a stepped cap.
-- Placement, sizes, heights and its budget: Config/City archetypes.deco_stripe_hotel.
-- Variants: palette (5 accent and neon sets), crown (1 white pilasters with pastel flutes, 2 pastel pilasters with
-- white flutes), rhythm (1 or 2 flutes per pilaster), mirror (symmetric, so it changes nothing visible).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local City = require(ReplicatedStorage.Shared.Config.City)
local Kit = require(script.Parent.Parent.Parent.Kit)
local Types = require(script.Parent.Parent.Parent.Types)

local P = City.palettes
local KIT = City.kit
local rgb = Color3.fromRGB

-- The recipe, in studs.
local SHAPE = {
	ground = 14, -- the porch floor, double height
	floorMin = 10.5, -- upper floors are at least this tall...
	floors = { 3, 4 }, -- ...and this many
	terrace = 9, -- the café terrace between the front line and the facade
	bodyDepth = 40, -- at most
	sideBay = 6.5, -- a side window bay
	sideInset = 3.4, -- the canopy band's rounded ends reach round the corners, so the walls keep this far in
	radius = 5, -- the rounded front corners; the porch sits this far back under the upper floors
	window = 6, -- ribbon window height; it tops out `head` under the floor line
	head = 1.4,
	eyebrow = { thick = 0.6, proud = 2.6 },
	canopy = { thick = 0.9, proud = 3.2 }, -- the band at the foot of the overhang
	cornice = { thick = 1.1, proud = 1.3 },
	pilasterSpacing = { 0.17, 7.5, 11.5 }, -- share of the width, clamped
	pilasterWidth = { 0.085, 4.2, 5.6 },
	pilasterProud = 3.4,
	pilasterRise = 6, -- past the roof
	centreStart = 3.4, -- the centre pilaster starts this far over the porch (the sign sits under it)
	hood = 2.6, -- the half-moon's reach past the pilaster's width
	flute = 0.7,
	parapet = 3.2,
	terraceTop = 0.9,
	balustrade = 2.2,
	gate = 3.5, -- half the balustrade's opening
	umbrella = 8.5,
	flag = 7,
}

-- Accent (flutes, grilles, coping, umbrellas), its neon kind at night and the facade wash's colour.
local PALETTES = {
	{ body = P.deco.white, accent = P.deco.pink, neon = "neonPink", wash = rgb(255, 120, 200) },
	{ body = P.deco.white, accent = P.deco.mint, neon = "sign", wash = rgb(120, 230, 220) },
	{ body = P.deco.white, accent = P.deco.lemon, neon = "neonAmber", wash = rgb(255, 200, 140) },
	{ body = P.deco.white, accent = P.deco.lilac, neon = "neonViolet", wash = rgb(200, 140, 255) },
	{ body = rgb(252, 238, 228), accent = P.deco.sky, neon = "neonBlue", wash = rgb(140, 190, 255) },
}

local function share(width: number, rule: { number }): number
	return math.clamp(width * rule[1], rule[2], rule[3])
end

local function build(m: Types.Model)
	local site = m.site
	local variant = site.variant
	local pal = PALETTES[math.clamp(variant.palette, 1, #PALETTES)]
	local rng = Kit.rng(m)
	local W, D = site.width, site.depth
	local hw, hd = W / 2, D / 2
	local G = SHAPE.ground
	local up = math.clamp(math.floor((site.height - G) / SHAPE.floorMin), SHAPE.floors[1], SHAPE.floors[2])
	local f = (site.height - G) / up
	local H = G + up * f
	local R = SHAPE.radius

	local white = Kit.look(pal.body, Enum.Material.SmoothPlastic)
	local trimWhite = Kit.look(P.deco.white, Enum.Material.SmoothPlastic)
	local accent = Kit.look(pal.accent, Enum.Material.SmoothPlastic)
	local pastelPilasters = variant.crown == 2
	local pilasterLook = if pastelPilasters then accent else trimWhite
	local fluteDay = if pastelPilasters then P.deco.white else pal.accent

	local x0, x1 = -hw + SHAPE.sideInset, hw - SHAPE.sideInset
	local zF = -hd + SHAPE.terrace
	local zB = math.min(hd - 1, zF + SHAPE.bodyDepth)
	local corners = { fl = true, fr = true }
	local bodyMin, bodyMax = Vector3.new(x0, 0, zF), Vector3.new(x1, 0, zB)

	-------------------------------------------------------------------------------------------------------
	-- Body: a block behind the porch, the upper floors' rounded front over it
	-------------------------------------------------------------------------------------------------------
	Kit.box(m, "Body", Vector3.new(x0, -KIT.bury, zF + R), Vector3.new(x1, H, zB), white)
	Kit.box(m, "Front", Vector3.new(x0 + R, G, zF), Vector3.new(x1 - R, H - 0.03, zF + R + 0.4), white)
	Kit.column(m, "CornerL", x0 + R, zF + R, G + 0.02, H - 0.02, 2 * R, white)
	Kit.column(m, "CornerR", x1 - R, zF + R, G + 0.02, H - 0.02, 2 * R, white)
	-- The porch's shop front, glowing warm at night.
	Kit.glass(
		m,
		"Shop",
		Vector3.new(x0 + 2.5, SHAPE.terraceTop, zF + R - 0.25),
		Vector3.new(x1 - 2.5, G - 1.4, zF + R + 0.3),
		P.window.dark,
		{
			image = City.textures.windowBold,
			faces = { Enum.NormalId.Front },
			u = 4,
			v = G - 1.4 - SHAPE.terraceTop,
			lines = P.deco.white,
			lit = true,
		}
	)
	-- The sides: stucco with punched windows, one tile a bay and a floor, from behind the rounded corners back.
	for i, sx in { -1, 1 } do
		local wallX = if sx < 0 then x0 else x1
		local face = if sx < 0 then Enum.NormalId.Left else Enum.NormalId.Right
		local a = Vector3.new(wallX - sx * 0.4, G, zF + 2 * R + 0.5)
		local b = Vector3.new(wallX + sx * 0.06, H - 0.05, zB - 0.6)
		Kit.punched(m, `Side{i}`, a, b, pal.body, P.window.dark, { face }, SHAPE.sideBay, f)
	end

	-------------------------------------------------------------------------------------------------------
	-- Bands: the canopy band at the foot of the overhang, an eyebrow over every window, the cornice
	-------------------------------------------------------------------------------------------------------
	-- The canopy band carries the hotel's pastel: the one strong line of colour across the front.
	Kit.band(m, "Canopy", bodyMin, bodyMax, R, corners, G, SHAPE.canopy.thick, SHAPE.canopy.proud, accent, "front")
	for k = 1, up - 1 do
		local y = G + k * f - SHAPE.head + SHAPE.eyebrow.thick / 2 + 0.1
		Kit.band(
			m,
			`Brow{k}`,
			bodyMin,
			bodyMax,
			R,
			corners,
			y,
			SHAPE.eyebrow.thick,
			SHAPE.eyebrow.proud,
			trimWhite,
			"front"
		)
	end
	local corniceY = H - SHAPE.cornice.thick / 2 + 0.06 -- its top a hair over the roof, never level with it
	Kit.band(
		m,
		"Cornice",
		bodyMin,
		bodyMax,
		R,
		corners,
		corniceY,
		SHAPE.cornice.thick,
		SHAPE.cornice.proud,
		trimWhite,
		"front"
	)

	-- Ribbon windows across the front, one per floor, gridded like steel casements.
	for k = 1, up do
		local top = G + k * f - SHAPE.head
		Kit.glass(
			m,
			`Window{k}`,
			Vector3.new(x0 + R + 1, top - SHAPE.window, zF - 0.12),
			Vector3.new(x1 - R - 1, top, zF + 0.3),
			P.window.dark,
			{
				image = City.textures.windowFine,
				faces = { Enum.NormalId.Front },
				u = 2.2,
				v = SHAPE.window,
				lines = P.deco.white,
				reflectance = 0.2,
			}
		)
	end
	-- The neon line under the cornice.
	Kit.neon(
		m,
		"Neon",
		Vector3.new(x0 + R, H - SHAPE.cornice.thick - 0.2, zF - 0.45),
		Vector3.new(x1 - R, H - SHAPE.cornice.thick - 0.2, zF - 0.45),
		"sign",
		P.deco.aqua
	)

	-------------------------------------------------------------------------------------------------------
	-- The three pilasters: fluted, past the roof, a half-moon hood and a stepped cap each
	-------------------------------------------------------------------------------------------------------
	local s = share(W, SHAPE.pilasterSpacing)
	local pw = share(W, SHAPE.pilasterWidth)
	local pp = SHAPE.pilasterProud
	local rise = H + SHAPE.pilasterRise
	local flutes: { number } = if variant.rhythm == 2 then { -0.22, 0.22 } else { 0 }
	for i, px in { -s, 0, s } do
		local centre = i == 2
		local y0 = if centre then G + SHAPE.centreStart else G - SHAPE.canopy.thick / 2 - 0.08
		Kit.box(
			m,
			`Pilaster{i}`,
			Vector3.new(px - pw / 2, y0, zF - pp),
			Vector3.new(px + pw / 2, rise, zF + 0.6),
			pilasterLook
		)
		for j, at in flutes do
			local fx = px + at * pw
			Kit.neon(
				m,
				`Flute{i}{j}`,
				Vector3.new(fx, y0 + 1, zF - pp - 0.2),
				Vector3.new(fx, rise - 2.2, zF - pp - 0.2),
				pal.neon,
				fluteDay,
				SHAPE.flute
			)
		end
		Kit.disc(m, `Hood{i}`, px, zF - pp, rise - 2.6, pw + SHAPE.hood, 0.5, pilasterLook)
		Kit.box(
			m,
			`Cap{i}`,
			Vector3.new(px - pw / 2 - 0.5, rise, zF - pp - 0.5),
			Vector3.new(px + pw / 2 + 0.5, rise + 1, zF + 1.1),
			trimWhite
		)
		if centre then
			Kit.box(
				m,
				"CapTop",
				Vector3.new(px - pw / 2 + 0.6, rise + 1, zF - pp + 0.6),
				Vector3.new(px + pw / 2 - 0.6, rise + 2.2, zF + 0.5),
				trimWhite
			)
			Kit.column(
				m,
				"Flagpole",
				px,
				zF - pp / 2 + 0.3,
				rise + 2.2,
				rise + 2.2 + SHAPE.flag,
				0.3,
				Kit.look(rgb(220, 224, 228), Enum.Material.Metal),
				"detail"
			)
		end
	end

	-------------------------------------------------------------------------------------------------------
	-- The roofline: a stepped parapet between the outer pilasters with pierced grilles, a stair house
	-------------------------------------------------------------------------------------------------------
	Kit.box(m, "Parapet", Vector3.new(-s, H - 0.1, zF + 0.4), Vector3.new(s, H + SHAPE.parapet, zF + 4), white)
	Kit.box(
		m,
		"ParapetStep",
		Vector3.new(-s * 0.45, H + SHAPE.parapet - 0.05, zF + 0.9),
		Vector3.new(s * 0.45, H + SHAPE.parapet + 1.6, zF + 3.4),
		white
	)
	local grilleW = math.max(1.5, s - pw - 1.6)
	for i, gx in { -s / 2, s / 2 } do
		local grille = Kit.detail(
			m,
			`Grille{i}`,
			Vector3.new(gx - grilleW / 2, H + 0.4, zF + 0.28),
			Vector3.new(gx + grilleW / 2, H + SHAPE.parapet - 0.5, zF + 0.5),
			accent
		)
		grille.textures = {
			{ face = Enum.NormalId.Front, image = City.textures.windowBold, u = 1.1, v = 1.1, color = P.deco.white },
		}
	end
	Kit.roofBox(m, "Stair", Vector3.new(x1 - 12, H, zB - 10), Vector3.new(x1 - 4, H + 7, zB - 3), white)

	-------------------------------------------------------------------------------------------------------
	-- The name over the porch, the café terrace, and the night wash
	-------------------------------------------------------------------------------------------------------
	local names = City.signNames.hotels
	Kit.sign(
		m,
		"Sign",
		Vector3.new(-s + pw / 2 + 0.8, G + 0.75, zF - 0.55),
		Vector3.new(s - pw / 2 - 0.8, G + 2.95, zF - 0.15),
		Enum.NormalId.Front,
		names[rng:NextInteger(1, #names)],
		pal.body,
		rgb(236, 62, 140),
		City.districtLooks.beach.font
	)
	local terrace = Kit.look(P.deco.terrazzo, Enum.Material.SmoothPlastic)
	Kit.box(
		m,
		"Terrace",
		Vector3.new(-hw + 0.2, 0, -hd + 0.3),
		Vector3.new(hw - 0.2, SHAPE.terraceTop, zF + R + 0.3),
		terrace
	)
	local railTop = SHAPE.terraceTop + SHAPE.balustrade
	for i, side in { -1, 1 } do
		local a, b = side * SHAPE.gate, side * (hw - 0.6)
		Kit.box(
			m,
			`Balustrade{i}`,
			Vector3.new(math.min(a, b), SHAPE.terraceTop, -hd + 0.6),
			Vector3.new(math.max(a, b), railTop, -hd + 1.3),
			trimWhite
		)
		Kit.detail(
			m,
			`Coping{i}`,
			Vector3.new(math.min(a, b) - 0.1, railTop, -hd + 0.5),
			Vector3.new(math.max(a, b) + 0.1, railTop + 0.35, -hd + 1.4),
			accent
		)
	end
	local spots: { number } = if W >= 56 then { -0.62, -0.24, 0.62 } else { -0.5, 0.5 }
	local tz = (-hd + 1.4 + zF) / 2
	local size = math.min(SHAPE.umbrella, SHAPE.terrace - 1)
	for i, at in spots do
		local color = if i % 2 == 1 then pal.accent else P.deco.white
		Kit.umbrella(m, `Umbrella{i}`, at * hw, tz, SHAPE.terraceTop, size, color, true)
	end
	-- On top of the canopy band, washing the upper floors and the pilasters.
	local inner = s - pw / 2 - 0.3
	Kit.wash(m, "Wash", -inner, inner, zF - SHAPE.canopy.proud + 0.9, G + SHAPE.canopy.thick / 2, pal.wash)
end

local archetype: Types.Archetype = { id = "deco_stripe_hotel", build = build }
return archetype
