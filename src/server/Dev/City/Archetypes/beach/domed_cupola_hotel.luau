--!strict
-- B09 domed_cupola_hotel (docs/city/ARCHETYPES.md §6, B09): the beach avenue's cream hotel tower with a belfry and
-- a metal dome. A tall cream block at the front, two projecting window bays up its face, a pastel fluted half-drum at
-- the top centre carrying the name; two lower wings either side (one a floor lower than the other) running back to the
-- water; a pastel line along every cornice; a flat porte-cochère on square piers across the front. On the roof, its
-- signature: an open belfry (corner posts, arched heads over its front openings, a dim core that glows amber through
-- them at night) under a silver or gold dome on a drum, with a neck and a spike. On a deep site a pool court opens
-- between the wings behind the tower.
--
-- What makes it itself: a slim tower crowned by an open belfry and a shining dome.
-- Placement, sizes, heights and its budget: Config/CityArchetypes/domed_cupola_hotel.
-- Variants: palette (1 cream, pink and a silver dome; 2 cream, mint and a gold dome; 3 peach, sky and a silver dome),
-- crown (1 one wide opening a side, 2 twin openings a side on middle posts), rhythm (1 wings 3 and 4 floors lower, 2
-- wings 5 and 6 floors lower), mirror (which wing is the lower one).
--
-- Previewing (the Studio helper): a mid view from about 250 studs and a street view. Check that the dome reads as a
-- dome on a drum (most of the ball showing, none of it poking into the belfry openings), that the belfry openings read
-- as openings (posts, the arched corners on the front, the dark core behind), that the half-drum and its ribs stand
-- proud under the belfry, and that the wings step down unevenly. At night: the core glows amber, the wash lights the
-- belfry front and the dome, the lobby glows. Compare with photos of its inspiration (ARCHETYPES.md B09).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local City = require(ReplicatedStorage.Shared.Config.City)
local Kit = require(script.Parent.Parent.Parent.Kit)
local Types = require(script.Parent.Parent.Parent.Types)

local P = City.palettes
local KIT = City.kit
local rgb = Color3.fromRGB

-- The recipe, in studs.
local SHAPE = {
	ground = 16, -- the lobby storey under everything
	floorMin = 11,
	minFloors = 8,
	terrace = 10, -- the forecourt under the porte-cochère
	sideInset = 1.5,
	baseInset = 2, -- the ground storey's face behind the tower's
	towerWidth = { 0.3, 28, 38 }, -- share of the site's width, clamped: slim against its wings
	towerDepth = { 26, 34 }, -- the site's depth less `towerSlack`, clamped
	towerSlack = 20,
	wingSet = 3, -- the wings' faces stand this far behind the tower's
	drops = { { 4, 5 }, { 6, 7 } }, -- by rhythm: floors the left and the right wing stand lower than the tower
	windowBay = 5.5,
	bay = { width = 7, proud = 1.8, edge = 1.2 }, -- the tower's two projecting bays, this far in from its sides
	cornice = { thick = 1.1, proud = 0.8 },
	feature = { diameter = 7, floors = 2.2, rib = 0.35, over = 1.4 }, -- the fluted half-drum at the top centre
	belfry = {
		share = 0.62,
		min = 18,
		max = 24,
		plinth = 3,
		height = 19,
		post = 3.2,
		core = 2.4,
		slab = 1.6,
		front = 2,
	},
	twin = 0.35, -- crown 2: a middle post is this share of a corner post's width each side of the centre
	arch = 0.36, -- the arched corners over the front openings: share of the opening's width
	dome = { drum = 2, share = 1, lift = 0.25, neck = 1.6, spike = 6 }, -- lifted so the ball waists in like an onion
	canopy = { y = 13, thick = 1.2, past = 4 },
	pier = 1.6,
	pool = 20, -- a pool court behind the tower when the site leaves at least this much behind it
	forecourt = 0.4,
	planter = 1.6,
}

-- Body, accent (the half-drum, cornice lines), dome metal, the name's colour and the wash's.
local PALETTES = {
	{
		body = rgb(245, 232, 206),
		accent = P.deco.pink,
		dome = rgb(214, 218, 224),
		text = rgb(206, 92, 120),
		wash = rgb(255, 196, 150),
	},
	{
		body = rgb(244, 234, 212),
		accent = P.deco.mint,
		dome = rgb(214, 178, 96),
		text = rgb(46, 140, 112),
		wash = rgb(255, 210, 150),
	},
	{
		body = rgb(250, 226, 204),
		accent = P.deco.sky,
		dome = rgb(214, 218, 224),
		text = rgb(60, 130, 180),
		wash = rgb(200, 220, 255),
	},
}

-- The belfry's four corners, as signs along x and z.
local CORNERS = { { x = -1, z = -1 }, { x = 1, z = -1 }, { x = -1, z = 1 }, { x = 1, z = 1 } }

local function build(m: Types.Model)
	local site = m.site
	local variant = site.variant
	local pal = PALETTES[math.clamp(variant.palette, 1, #PALETTES)]
	local crown = math.clamp(variant.crown, 1, 2)
	local rhythm = math.clamp(variant.rhythm, 1, 2)
	local rng = Kit.rng(m)
	local W, D = site.width, site.depth
	local hw, hd = W / 2, D / 2
	local G = SHAPE.ground
	local up = math.max(SHAPE.minFloors, math.floor((site.height - G) / SHAPE.floorMin))
	local f = (site.height - G) / up
	local H = G + up * f

	local body = Kit.look(pal.body, Enum.Material.SmoothPlastic)
	local accent = Kit.look(pal.accent, Enum.Material.SmoothPlastic)
	-- Smooth and a little mirror-like: Foil's crinkle reads as a disco ball up close.
	local metal = Kit.look(pal.dome, Enum.Material.SmoothPlastic, 0.3)
	local terrazzo = Kit.look(P.deco.terrazzo, Enum.Material.SmoothPlastic)
	local dark = P.window.dark
	local walls = { Enum.NormalId.Front, Enum.NormalId.Back, Enum.NormalId.Left, Enum.NormalId.Right }

	local x0, x1 = -hw + SHAPE.sideInset, hw - SHAPE.sideInset
	local zF = -hd + SHAPE.terrace
	local zB = hd - 1
	local tx = math.clamp(W * SHAPE.towerWidth[1], SHAPE.towerWidth[2], SHAPE.towerWidth[3]) / 2
	local td = math.clamp(D - SHAPE.towerSlack, SHAPE.towerDepth[1], SHAPE.towerDepth[2])
	local zT1 = zF + td -- the tower's back
	local cor = SHAPE.cornice
	-- A deep site (a core claim) leaves room for a pool court between the wings behind the tower.
	local deep = zB - zT1 >= SHAPE.pool

	-------------------------------------------------------------------------------------------------------
	-- The lobby storey under the tower and the wings, its glass across the front
	-------------------------------------------------------------------------------------------------------
	local zG = zF + SHAPE.baseInset
	local baseBack = if deep then zT1 else zB - 0.5
	Kit.box(m, "Base", Vector3.new(x0 + 0.5, -KIT.bury, zG), Vector3.new(x1 - 0.5, G + 0.3, baseBack), body)
	if deep then
		-- A hair in from the main base's sides, so the faces where they overlap never share a plane.
		Kit.box(m, "BaseL", Vector3.new(x0 + 0.53, -KIT.bury, zT1 - 0.5), Vector3.new(-tx, G + 0.25, zB - 0.5), body)
		Kit.box(m, "BaseR", Vector3.new(tx, -KIT.bury, zT1 - 0.5), Vector3.new(x1 - 0.53, G + 0.25, zB - 0.5), body)
	end
	Kit.glass(m, "Lobby", Vector3.new(x0 + 2, 0.4, zG - 0.12), Vector3.new(x1 - 2, G - 1.6, zG + 0.3), dark, {
		image = City.textures.windowBold,
		faces = { Enum.NormalId.Front },
		u = 4,
		v = G - 2,
		lines = pal.body,
		lit = true,
	})

	-------------------------------------------------------------------------------------------------------
	-- The tower: punched walls, two projecting bays, a cornice with a pastel line, the fluted half-drum and the name
	-------------------------------------------------------------------------------------------------------
	Kit.punched(m, "Tower", Vector3.new(-tx, G, zF), Vector3.new(tx, H, zT1), pal.body, dark, walls, SHAPE.windowBay, f)
	Kit.trim(
		m,
		"Cornice",
		Vector3.new(-tx - cor.proud, H - cor.thick + 0.06, zF - cor.proud),
		Vector3.new(tx + cor.proud, H + 0.06, zT1 + cor.proud),
		body
	)
	Kit.detail(
		m,
		"CorniceLine",
		Vector3.new(-tx - cor.proud - 0.05, H - 0.75, zF - cor.proud - 0.15),
		Vector3.new(tx + cor.proud + 0.05, H - 0.3, zF - cor.proud + 0.05),
		accent
	)
	local bay = SHAPE.bay
	for i, side in { -1, 1 } do
		local bx = side * (tx - bay.edge - bay.width / 2)
		Kit.punched(
			m,
			`Bay{i}`,
			Vector3.new(bx - bay.width / 2, G, zF - bay.proud),
			Vector3.new(bx + bay.width / 2, H - f, zF + 0.5),
			pal.body,
			dark,
			{ Enum.NormalId.Front, Enum.NormalId.Left, Enum.NormalId.Right },
			bay.width / 2,
			f
		)
	end
	-- The half-drum, sunk half into the face, white ribs down it and the name across it.
	local ft = SHAPE.feature
	local fr = ft.diameter / 2
	local fy0 = H - ft.floors * f
	Kit.column(m, "Feature", 0, zF, fy0, H + ft.over, ft.diameter, accent)
	for i, dx in { -1.6, 0, 1.6 } do
		local zr = zF - math.sqrt(fr * fr - dx * dx)
		Kit.detail(
			m,
			`Rib{i}`,
			Vector3.new(dx - ft.rib / 2, fy0 + 0.8, zr - 0.25),
			Vector3.new(dx + ft.rib / 2, H + ft.over - 0.6, zr + 0.25),
			body
		)
	end
	local names = City.signNames.hotels
	local name = names[rng:NextInteger(1, #names)]
	-- Between the two bays (it stands in front of them).
	local nw = math.min(math.clamp(tx * 0.8, 9, 16), 2 * (tx - bay.edge - bay.width) - 1)
	local ny = fy0 + 0.35 * f
	Kit.sign(
		m,
		"Name",
		Vector3.new(-nw / 2, ny, zF - fr - 0.45),
		Vector3.new(nw / 2, ny + 2.6, zF - fr - 0.1),
		Enum.NormalId.Front,
		name,
		pal.body,
		pal.text,
		City.districtLooks.beach.font
	)

	-------------------------------------------------------------------------------------------------------
	-- The wings, either side, running back; each with its cornice, its line and a roof box
	-------------------------------------------------------------------------------------------------------
	local drops = SHAPE.drops[rhythm]
	local zW = zF + SHAPE.wingSet
	for i, side in { -1, 1 } do
		local outer = if side < 0 then x0 else x1
		local inner = side * tx
		local wa, wb = math.min(outer, inner), math.max(outer, inner)
		local top = G + (up - drops[i]) * f
		local outerFace = if side < 0 then Enum.NormalId.Left else Enum.NormalId.Right
		local innerFace = if side < 0 then Enum.NormalId.Right else Enum.NormalId.Left
		-- On a deep site the wing's inner side faces the pool court, so it gets windows too.
		local faces = if deep
			then { Enum.NormalId.Front, Enum.NormalId.Back, outerFace, innerFace }
			else { Enum.NormalId.Front, Enum.NormalId.Back, outerFace }
		Kit.punched(
			m,
			`Wing{i}`,
			Vector3.new(wa, G, zW),
			Vector3.new(wb, top, zB),
			pal.body,
			dark,
			faces,
			SHAPE.windowBay,
			f
		)
		local ca = if side < 0 then wa - cor.proud else wa - 0.5
		local cb = if side < 0 then wb + 0.5 else wb + cor.proud
		Kit.trim(
			m,
			`WingCornice{i}`,
			Vector3.new(ca, top - cor.thick + 0.06, zW - cor.proud),
			Vector3.new(cb, top + 0.06, zB + cor.proud),
			body
		)
		local la = if side < 0 then ca - 0.05 else wa
		local lb = if side < 0 then wb else cb + 0.05
		Kit.detail(
			m,
			`WingLine{i}`,
			Vector3.new(la, top - 0.75, zW - cor.proud - 0.15),
			Vector3.new(lb, top - 0.3, zW - cor.proud + 0.05),
			accent
		)
		local rx = (wa + wb) / 2
		Kit.roofBox(m, `RoofBox{i}`, Vector3.new(rx - 4, top, zB - 10), Vector3.new(rx + 4, top + 5, zB - 3), body)
	end

	-------------------------------------------------------------------------------------------------------
	-- The belfry: a plinth, corner posts (and middle ones for crown 2), a core that glows through the openings,
	-- arched corners over the front openings, an entablature with a pastel line
	-------------------------------------------------------------------------------------------------------
	local b = SHAPE.belfry
	local bW = math.clamp(2 * tx * b.share, b.min, b.max)
	local bh = bW / 2
	local bz = zF + b.front + bh -- its centre: its face `front` behind the tower's
	local yP = H + b.plinth
	local yS = yP + b.height
	local p = b.post
	Kit.box(
		m,
		"BelfryBase",
		Vector3.new(-bh - 0.6, H - 0.3, bz - bh - 0.6),
		Vector3.new(bh + 0.6, yP, bz + bh + 0.6),
		body
	)
	for i, c in CORNERS do
		local px0 = if c.x < 0 then -bh else bh - p
		local pz0 = if c.z < 0 then bz - bh else bz + bh - p
		Kit.box(m, `Post{i}`, Vector3.new(px0, yP - 0.1, pz0), Vector3.new(px0 + p, yS + 0.1, pz0 + p), body)
	end
	local tw = SHAPE.twin * p
	if crown == 2 then
		Kit.box(m, "PostFront", Vector3.new(-tw, yP - 0.1, bz - bh), Vector3.new(tw, yS + 0.1, bz - bh + p), body)
		Kit.box(m, "PostBack", Vector3.new(-tw, yP - 0.1, bz + bh - p), Vector3.new(tw, yS + 0.1, bz + bh), body)
		Kit.box(m, "PostLeft", Vector3.new(-bh, yP - 0.1, bz - tw), Vector3.new(-bh + p, yS + 0.1, bz + tw), body)
		Kit.box(m, "PostRight", Vector3.new(bh - p, yP - 0.1, bz - tw), Vector3.new(bh, yS + 0.1, bz + tw), body)
	end
	local ci = b.core
	Kit.lit(
		Kit.box(
			m,
			"Bells",
			Vector3.new(-bh + ci, yP - 0.05, bz - bh + ci),
			Vector3.new(bh - ci, yS + 0.05, bz + bh - ci),
			Kit.look(rgb(92, 76, 64), Enum.Material.SmoothPlastic)
		),
		"neonAmber"
	)
	-- Arched corners over each front opening.
	local openings: { { number } } = if crown == 2
		then { { -bh + p, -tw }, { tw, bh - p } }
		else { { -bh + p, bh - p } }
	for k, o in openings do
		local a = (o[2] - o[1]) * SHAPE.arch
		local z = bz - bh
		Kit.triangle(m, `Arch{k}L`, o[1], yS - a, o[1] + a, yS, z, p * 0.8, "x0y1", body)
		Kit.triangle(m, `Arch{k}R`, o[2] - a, yS - a, o[2], yS, z, p * 0.8, "x1y1", body)
	end
	Kit.box(
		m,
		"BelfryTop",
		Vector3.new(-bh - 0.5, yS, bz - bh - 0.5),
		Vector3.new(bh + 0.5, yS + b.slab, bz + bh + 0.5),
		body
	)
	Kit.detail(
		m,
		"BelfryLine",
		Vector3.new(-bh - 0.55, yS + 0.5, bz - bh - 0.65),
		Vector3.new(bh + 0.55, yS + 0.95, bz - bh - 0.45),
		accent
	)

	-------------------------------------------------------------------------------------------------------
	-- The dome: a drum, a ball most of which shows, a neck, a spike and a finial
	-------------------------------------------------------------------------------------------------------
	local dm = SHAPE.dome
	local yT = yS + b.slab
	local drumD = bW - 2
	local domeD = drumD * dm.share
	Kit.column(m, "DomeDrum", 0, bz, yT - 0.1, yT + dm.drum, drumD, body)
	local cy = yT + dm.drum + domeD * dm.lift
	Kit.ball(m, "Dome", Vector3.new(0, cy, bz), domeD, metal, "trim")
	local ballTop = cy + domeD / 2
	Kit.column(m, "Neck", 0, bz, ballTop - 0.6, ballTop + 1.2, dm.neck, metal, "detail")
	Kit.spire(m, "Spike", 0, bz, ballTop + 1.2, dm.spike, 0.7, metal, 2, false)
	Kit.ball(m, "Finial", Vector3.new(0, ballTop + 1.2 + dm.spike + 0.45, bz), 1, metal)
	-- On the plinth's ledge, washing the belfry's front and the dome.
	Kit.wash(m, "Wash", -bh + 1, bh - 1, bz - bh - 0.3, yP + 0.02, pal.wash)

	-------------------------------------------------------------------------------------------------------
	-- The porte-cochère, the forecourt, planters, and a pool court behind the tower on a deep site
	-------------------------------------------------------------------------------------------------------
	local cp = SHAPE.canopy
	local cwC = tx + cp.past
	Kit.canopy(m, "Canopy", -cwC, cwC, -hd + 1, zG + 0.05, cp.y, cp.thick, body)
	Kit.detail(
		m,
		"CanopyLine",
		Vector3.new(-cwC - 0.05, cp.y + 0.3, -hd + 0.9),
		Vector3.new(cwC + 0.05, cp.y + 0.8, -hd + 1.1),
		accent
	)
	local sw = math.min(cwC * 0.9, 14)
	Kit.sign(
		m,
		"CanopySign",
		Vector3.new(-sw / 2, cp.y + cp.thick, -hd + 1.4),
		Vector3.new(sw / 2, cp.y + cp.thick + 2.2, -hd + 1.8),
		Enum.NormalId.Front,
		name,
		pal.body,
		pal.text,
		City.districtLooks.beach.font
	)
	for i, x in { -(cwC - 1.2), -tx * 0.4, tx * 0.4, cwC - 1.2 } do
		local hp = SHAPE.pier / 2
		Kit.box(
			m,
			`Pier{i}`,
			Vector3.new(x - hp, -KIT.bury, -hd + 1.6),
			Vector3.new(x + hp, cp.y, -hd + 1.6 + 2 * hp),
			body
		)
	end
	Kit.box(
		m,
		"Forecourt",
		Vector3.new(-hw + 0.2, 0, -hd + 0.3),
		Vector3.new(hw - 0.2, SHAPE.forecourt, zG + 0.3),
		terrazzo
	)
	for i, side in { -1, 1 } do
		local a, c = side * (cwC + 2), side * (hw - 1.5)
		Kit.planter(
			m,
			`Planter{i}`,
			Vector3.new(math.min(a, c), SHAPE.forecourt, -hd + 0.8),
			Vector3.new(math.max(a, c), SHAPE.forecourt + SHAPE.planter, -hd + 2.6),
			body
		)
	end
	if deep then
		Kit.box(
			m,
			"PoolDeck",
			Vector3.new(-tx + 0.05, 0, zT1 + 0.5),
			Vector3.new(tx - 0.05, SHAPE.forecourt, zB - 0.5),
			terrazzo
		)
		Kit.pool(m, "Pool", Vector3.new(-tx + 4, 0, zT1 + 5), Vector3.new(tx - 4, 0, zB - 5), SHAPE.forecourt)
	end
end

local archetype: Types.Archetype = { id = "domed_cupola_hotel", build = build }
return archetype
