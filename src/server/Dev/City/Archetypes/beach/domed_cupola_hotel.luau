--!strict
-- B09 domed_cupola_hotel (docs/city/ARCHETYPES.md §6, B09): the beach avenue's cream hotel tower with a belfry and a
-- metal dome. A tripartite front: a centre block standing proud and highest, two wings either side two to four floors
-- lower (one lower than the other) running back toward the water. The centre carries the hotel's Deco ornament: a
-- pastel racing stripe of spandrels up its middle ending in a fluted half-drum that carries the name, two projecting
-- window bays either side of it, and a parapet striped in the same pastel. Windows come in strips with cream piers
-- between; corner windows stand proud at the wings' outer corners; a pastel line runs under every cornice. On the
-- centre's roof, its signature: a belfry on a plinth, tall arched openings between corner piers (a dim core behind
-- them that glows amber at night), an entablature with a pastel band, and a silver or gold dome on a drum with a neck
-- and a spike. A flat porte-cochère on square piers runs across the front over a forecourt; on a deep site a pool
-- court opens between the wings behind the centre.
--
-- What makes it itself: a cream tripartite tower crowned by a belfry and a shining dome, a pastel stripe up its middle.
-- Placement, sizes, heights and its budget: Config/CityArchetypes/domed_cupola_hotel.
-- Variants: palette (1 cream, pink and a silver dome; 2 cream, mint and a gold dome; 3 peach, sky and a silver dome),
-- crown (1 one tall arch a face, 2 twin arches a face on a middle pier), rhythm (1 windows in pairs, wings two and
-- three floors lower; 2 single windows in more strips, wings three and four floors lower), mirror (which wing is the lower
-- one).
--
-- Previewing (the Studio helper): a mid view from about 250 studs and a street view. Check that the dome reads as a
-- dome on a drum (most of the ball showing, none of it inside the belfry), that the belfry's openings read as deep
-- openings (piers, the arch haunches cut back at 45 degrees on the front and sides, the dark core set back), that the
-- stripe runs up into the half-drum, that the bays stand proud with windows round their sides, and that the wings step
-- down unevenly. At night: the core glows amber, the centre's window strips and the lobby glow, the wash lights the
-- belfry front and the dome. Compare with photos of its inspiration (ARCHETYPES.md B09).

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
	terrace = 10, -- the forecourt: the wings' faces stand this far behind the front line
	sideInset = 1.5,
	lobbyInset = 2.5, -- the lobby glass sits this far behind the wings' faces
	centre = { 0.19, 14, 22 }, -- the centre block's half width: share of the site's width, clamped
	centreProud = 2.5, -- its face in front of the wings'
	centreDepth = { 26, 36 }, -- the site's depth less `slack`, clamped
	slack = 18,
	drops = { { 2, 3 }, { 3, 4 } }, -- by rhythm: floors the left and the right wing stand lower than the centre (enough
	-- that the centre reads as a tower rising out of its wings)
	-- Window strips by rhythm (see `strips`): a window's tile, windows per strip, the pier between strips.
	strips = { { tile = 3.2, tiles = 2, gap = 4.5 }, { tile = 3.4, tiles = 1, gap = 3.6 } },
	stripProud = 0.5,
	stripPier = 1, -- a strip keeps at least this much wall either side
	sideTile = 4.4, -- windows on the sides and back
	bay = { width = 7, proud = 2, from = 3.5, cap = 0.8 }, -- the centre's projecting bays, `from` in from its sides
	stripe = { half = 2.4, proud = 0.35 }, -- the pastel stripe of spandrels up the centre
	drum = { diameter = 7.5, floors = 2.2, rib = 0.4, over = 1.6 }, -- the fluted half-drum at the stripe's top
	parapet = { height = 2.6, thick = 1.6, band = 0.9 },
	cornice = { thick = 1, proud = 0.8 },
	cornerBay = { width = 6.5, proud = 1.4 },
	-- The belfry: its width (share of the centre's, clamped), plinth, set-back, height (share of its width), corner piers by
	-- crown (share of its width: slimmer round twin arches), the core's set-back and the entablature.
	belfry = {
		share = 0.62,
		min = 16,
		max = 24,
		plinth = 4,
		back = 2,
		tall = 0.95,
		post = { 0.3, 0.22 },
		core = 2.4,
		slab = 1.6,
	},
	twin = 0.16, -- crown 2: the middle pier's share of the belfry's width
	-- Lifted on a tall drum so the ball waists in and reads over the belfry's top slab from the street.
	dome = { drum = 2.8, share = 0.84, lift = 0.22, neck = 1.4, spike = 5, finial = 1 },
	canopy = { y = 13, thick = 1.2, past = 5 },
	pier = 1.6,
	pool = 20, -- a pool court behind the centre when the site leaves at least this much behind it
	forecourt = 0.4,
	planter = 1.6,
}

-- Body, accent (stripe, half-drum, parapet band, cornice lines), dome metal, the name's colour and the wash's.
-- The creams are pushed well past the paint chip: under the game's bright sun a pale cream reads as plain white.
local PALETTES = {
	{
		body = rgb(240, 221, 182),
		accent = P.deco.pink,
		dome = rgb(214, 218, 224),
		text = rgb(206, 92, 120),
		wash = rgb(255, 196, 150),
	},
	{
		body = rgb(236, 224, 190),
		accent = P.deco.mint,
		dome = rgb(214, 178, 96),
		text = rgb(46, 140, 112),
		wash = rgb(255, 210, 150),
	},
	{
		body = rgb(248, 212, 182),
		accent = P.deco.sky,
		dome = rgb(214, 218, 224),
		text = rgb(60, 130, 180),
		wash = rgb(200, 220, 255),
	},
}

type Strips = { tile: number, tiles: number, gap: number }

-- Window strips across a block's face from x = a to b, on the face at zFace, from y0 up to `top` (both floor lines, so
-- every tile is one window on one floor): evenly spaced, each `tiles` windows wide (narrower when the block is), wall
-- between. Flush and lit, or standing out of the wall. 1 part each.
local function strips(
	m: Types.Model,
	name: string,
	a: number,
	b: number,
	zFace: number,
	y0: number,
	top: number,
	f: number,
	r: Strips,
	wall: Color3,
	lit: boolean
)
	local span = b - a
	local w = math.min(r.tile * r.tiles, span - 2 * SHAPE.stripPier)
	if w < 2.6 then
		return
	end
	local n = math.max(1, math.round(span / (w + r.gap)))
	local pitch = span / n
	local out = if lit then 0.06 else SHAPE.stripProud
	for k = 1, n do
		local cx = a + pitch * (k - 0.5)
		Kit.punched(
			m,
			`{name}{k}`,
			Vector3.new(cx - w / 2, y0, zFace - out),
			Vector3.new(cx + w / 2, top, zFace + 0.3),
			wall,
			P.window.dark,
			{ Enum.NormalId.Front },
			w / r.tiles,
			f,
			lit
		)
	end
end

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
	local rs = SHAPE.strips[rhythm]
	local tile = SHAPE.sideTile

	local x0, x1 = -hw + SHAPE.sideInset, hw - SHAPE.sideInset
	local zF = -hd + SHAPE.terrace -- the wings' faces
	local zB = hd - 1
	local cC = math.clamp(W * SHAPE.centre[1], SHAPE.centre[2], SHAPE.centre[3]) -- the centre's half width
	local zC = zF - SHAPE.centreProud -- the centre's face
	local td = math.clamp(D - SHAPE.slack, SHAPE.centreDepth[1], SHAPE.centreDepth[2])
	local zC1 = math.min(zC + td, zB) -- the centre's back
	local cor = SHAPE.cornice
	local li = SHAPE.lobbyInset
	-- A deep site (a core claim) leaves room for a pool court between the wings behind the centre.
	local deep = zB - zC1 >= SHAPE.pool

	-------------------------------------------------------------------------------------------------------
	-- The lobby storey under the centre and the wings, its glass across the front
	-------------------------------------------------------------------------------------------------------
	local zG = zF + li
	local baseBack = if deep then zC1 else zB - 0.5
	Kit.box(m, "Base", Vector3.new(x0 + 0.5, -KIT.bury, zG), Vector3.new(x1 - 0.5, G + 0.3, baseBack), body)
	if deep then
		-- A hair in from the main base's sides, so the faces where they overlap never share a plane.
		Kit.box(m, "BaseL", Vector3.new(x0 + 0.53, -KIT.bury, zC1 - 0.5), Vector3.new(-cC, G + 0.25, zB - 0.5), body)
		Kit.box(m, "BaseR", Vector3.new(cC, -KIT.bury, zC1 - 0.5), Vector3.new(x1 - 0.53, G + 0.25, zB - 0.5), body)
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
	-- The centre block: windows in its sides and back, its face carrying the stripe, the bays, the half-drum, the name
	-- and the striped parapet
	-------------------------------------------------------------------------------------------------------
	Kit.box(m, "Centre", Vector3.new(-cC, G, zC), Vector3.new(cC, H, zC1), body)
	Kit.trim(
		m,
		"CentreCornice",
		Vector3.new(-cC - cor.proud, H - cor.thick + 0.06, zC + 0.5),
		Vector3.new(cC + cor.proud, H + 0.06, zC1 + cor.proud * 0.5),
		body
	)
	-- The half-drum at the stripe's top, sunk half into the face, white ribs down it and the name across it.
	local dr = SHAPE.drum
	local fr = dr.diameter / 2
	local yD = H - dr.floors * f
	Kit.column(m, "Drum", 0, zC, yD, H + dr.over, dr.diameter, accent)
	for i, dx in { -1.6, 0, 1.6 } do
		local zr = zC - math.sqrt(fr * fr - dx * dx)
		Kit.detail(
			m,
			`Rib{i}`,
			Vector3.new(dx - dr.rib / 2, yD + 0.8, zr - 0.25),
			Vector3.new(dx + dr.rib / 2, H + dr.over - 0.6, zr + 0.25),
			body
		)
	end
	-- The stripe: a pastel strip whose windows leave pastel spandrels between them, up to the half-drum. Its top is a
	-- floor line only when the drum starts on one, so it stops at the floor under the drum.
	local st = SHAPE.stripe
	local stripeTop = G + math.floor((yD - G) / f + 1e-6) * f
	Kit.punched(
		m,
		"Stripe",
		Vector3.new(-st.half, G, zC - st.proud),
		Vector3.new(st.half, stripeTop, zC + 0.3),
		pal.accent,
		dark,
		{ Enum.NormalId.Front },
		2 * st.half,
		f
	)
	-- The projecting bays, stopping a floor under the roof under a little cap.
	local bay = SHAPE.bay
	local bayInner = cC - bay.from - bay.width -- the bays' inner sides
	for i, side in { -1, 1 } do
		local bx = side * (cC - bay.from - bay.width / 2)
		Kit.punched(
			m,
			`Bay{i}`,
			Vector3.new(bx - bay.width / 2, G, zC - bay.proud),
			Vector3.new(bx + bay.width / 2, H - f, zC + 0.5),
			pal.body,
			dark,
			{ Enum.NormalId.Front, Enum.NormalId.Left, Enum.NormalId.Right },
			bay.width / 2,
			f
		)
		Kit.trim(
			m,
			`BayCap{i}`,
			Vector3.new(bx - bay.width / 2 - 0.4, H - f, zC - bay.proud - 0.4),
			Vector3.new(bx + bay.width / 2 + 0.4, H - f + bay.cap, zC + 0.5),
			body
		)
		-- Lit strips between the stripe and the bay: the centre's windows glow at night.
		local sa, sb = side * (st.half + 0.2), side * bayInner
		strips(m, `CentreWindows{i}`, math.min(sa, sb), math.max(sa, sb), zC, G, H, f, rs, pal.body, true)
	end
	local names = City.signNames.hotels
	local name = names[rng:NextInteger(1, #names)]
	local nw = math.min(math.max(2 * bayInner - 1, 9), 16)
	local ny = yD + 0.35 * f
	Kit.sign(
		m,
		"Name",
		Vector3.new(-nw / 2, ny, zC - fr - 0.45),
		Vector3.new(nw / 2, ny + 3.4, zC - fr - 0.1),
		Enum.NormalId.Front,
		name,
		pal.body,
		pal.text,
		City.districtLooks.beach.font
	)
	-- The parapet across the centre's front, a pastel striped band along its top.
	local pp = SHAPE.parapet
	Kit.trim(
		m,
		"Parapet",
		Vector3.new(-cC - 0.3, H - 0.2, zC - 0.3),
		Vector3.new(cC + 0.3, H + pp.height, zC + pp.thick),
		body
	)
	local band = Kit.detail(
		m,
		"ParapetBand",
		Vector3.new(-cC - 0.35, H + pp.height - pp.band - 0.3, zC - 0.5),
		Vector3.new(cC + 0.35, H + pp.height - 0.3, zC - 0.25),
		accent
	)
	band.textures = {
		{ face = Enum.NormalId.Front, image = City.textures.windowBold, u = 1.4, v = pp.band, color = pal.body },
	}

	-------------------------------------------------------------------------------------------------------
	-- The wings, either side, running back: window strips, corner windows, a cornice with a pastel line, a roof box
	-------------------------------------------------------------------------------------------------------
	local drops = SHAPE.drops[rhythm]
	local cb2 = SHAPE.cornerBay
	for i, side in { -1, 1 } do
		local outer = if side < 0 then x0 else x1
		local inner = side * (cC - 0.5)
		local wa, wb = math.min(outer, inner), math.max(outer, inner)
		local top = H - drops[i] * f
		local outerFace = if side < 0 then Enum.NormalId.Left else Enum.NormalId.Right
		local innerFace = if side < 0 then Enum.NormalId.Right else Enum.NormalId.Left
		Kit.box(m, `Wing{i}`, Vector3.new(wa, G, zF), Vector3.new(wb, top, zB), body)
		-- Thin punched skins on the faces that show: the outer side behind the corner windows, the back, and on a deep
		-- site the inner side over the pool court (each skin's top and foot on floor lines).
		local function skin(part: string, xa: number, xb: number, za: number, zb: number, face: Enum.NormalId)
			Kit.punched(
				m,
				part,
				Vector3.new(math.min(xa, xb), G, math.min(za, zb)),
				Vector3.new(math.max(xa, xb), top, math.max(za, zb)),
				pal.body,
				dark,
				{ face },
				tile,
				f
			)
		end
		skin(`WingSide{i}`, outer - side * 0.3, outer + side * 0.06, zF + cb2.width + 0.6, zB - 0.6, outerFace)
		skin(`WingBack{i}`, wa + 0.6, wb - 0.6, zB - 0.3, zB + 0.06, Enum.NormalId.Back)
		if deep then
			skin(`WingCourt{i}`, inner + side * 0.3, inner - side * 0.06, zC1 + 0.6, zB - 0.6, innerFace)
		end
		-- The centre's side over this wing.
		local ca0, ca1 = side * (cC - 0.3), side * (cC + 0.06)
		Kit.punched(
			m,
			`CentreSide{i}`,
			Vector3.new(math.min(ca0, ca1), top, zC + 1),
			Vector3.new(math.max(ca0, ca1), H, zC1 - 1),
			pal.body,
			dark,
			{ outerFace },
			tile,
			f
		)
		local ca = if side < 0 then wa - cor.proud else wa
		local cb = if side < 0 then wb else wb + cor.proud
		Kit.trim(
			m,
			`WingCornice{i}`,
			Vector3.new(ca, top - cor.thick + 0.06, zF - cor.proud),
			Vector3.new(cb, top + 0.06, zB + cor.proud * 0.5),
			body
		)
		local la = if side < 0 then ca - 0.05 else wa
		local lb = if side < 0 then wb else cb + 0.05
		Kit.detail(
			m,
			`WingLine{i}`,
			Vector3.new(la, top - cor.thick - 0.55, zF - 0.15),
			Vector3.new(lb, top - cor.thick - 0.1, zF + 0.05),
			accent
		)
		local ia, ib = side * cC, outer - side * cb2.width
		strips(m, `WingWindows{i}`, math.min(ia, ib), math.max(ia, ib), zF, G, top, f, rs, pal.body, false)
		local ba, bb = outer - side * cb2.width, outer + side * (cb2.proud - 0.25)
		Kit.punched(
			m,
			`CornerBay{i}`,
			Vector3.new(math.min(ba, bb), G, zF - cb2.proud),
			Vector3.new(math.max(ba, bb), top - f, zF + cb2.width),
			pal.body,
			dark,
			{ Enum.NormalId.Front, outerFace },
			cb2.width / 2,
			f
		)
		Kit.trim(
			m,
			`CornerCap{i}`,
			Vector3.new(math.min(ba, bb) - 0.3, top - f, zF - cb2.proud - 0.3),
			Vector3.new(math.max(ba, bb) + (if side > 0 then 0.25 else 0.3), top - f + 0.8, zF + cb2.width + 0.3),
			body
		)
		local rx = (wa + wb) / 2
		Kit.roofBox(m, `RoofBox{i}`, Vector3.new(rx - 4, top, zB - 10), Vector3.new(rx + 4, top + 5, zB - 3), body)
	end

	-------------------------------------------------------------------------------------------------------
	-- The belfry: a plinth, corner piers (and middle ones for crown 2), a dim core set back behind them, arch haunches
	-- over the openings, an entablature with a pastel band
	-------------------------------------------------------------------------------------------------------
	local b = SHAPE.belfry
	local dm = SHAPE.dome
	-- As wide as `share` of the centre, and never deeper than the centre's roof behind the parapet.
	local bW = math.min(math.clamp(2 * cC * b.share, b.min, b.max), zC1 - zC - pp.thick - b.back - 1.6)
	local bh = bW / 2
	local bz = zC + pp.thick + b.back + bh -- its centre: its face behind the parapet
	local yP = H + b.plinth
	local drumD = bW - 2
	local domeD = drumD * dm.share
	-- Its height: as tall as `tall` of its width, less if the crown room says so.
	local above = b.slab + dm.drum + domeD * (0.5 + dm.lift) + dm.neck + dm.spike + dm.finial + 0.4
	local bH = math.clamp(site.maxHeight - yP - above, 10, bW * b.tall)
	local yS = yP + bH
	local p = bW * b.post[crown]
	Kit.box(
		m,
		"BelfryBase",
		Vector3.new(-bh - 0.6, H - 0.3, bz - bh - 0.6),
		Vector3.new(bh + 0.6, yP, bz + bh + 0.6),
		body
	)
	for i, c in { { -1, -1 }, { 1, -1 }, { -1, 1 }, { 1, 1 } } do
		local px0 = if c[1] < 0 then -bh else bh - p
		local pz0 = if c[2] < 0 then bz - bh else bz + bh - p
		Kit.box(m, `Post{i}`, Vector3.new(px0, yP - 0.1, pz0), Vector3.new(px0 + p, yS + 0.1, pz0 + p), body)
	end
	local tw = bW * SHAPE.twin / 2
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
	-- Arch haunches through the piers' depth: on the front over each opening, on each side over its one opening.
	local openings: { { number } } = if crown == 2
		then { { -bh + p, -tw }, { tw, bh - p } }
		else { { -bh + p, bh - p } }
	for k, o in openings do
		local rise = (o[2] - o[1]) * 0.42
		Kit.archHead(m, `Arch{k}`, o[1], o[2], yS, bz - bh - 0.05, bz - bh + ci, rise, body)
	end
	if crown == 1 then
		local rise = (bW - 2 * p) * 0.42
		for i, side in { -1, 1 } do
			-- Through the side's depth, its outer face a hair proud of the piers' (as the front's).
			local xa, xb = side * (bh + 0.05), side * (bh - ci)
			local lo, hi = math.min(xa, xb), math.max(xa, xb)
			Kit.corbel(
				m,
				`SideArch{i}F`,
				Vector3.new(lo, yS - rise, bz - bh + p),
				Vector3.new(hi, yS, bz - bh + p + rise),
				"front",
				body
			)
			Kit.corbel(
				m,
				`SideArch{i}B`,
				Vector3.new(lo, yS - rise, bz + bh - p - rise),
				Vector3.new(hi, yS, bz + bh - p),
				"back",
				body
			)
		end
	end
	Kit.box(
		m,
		"BelfryTop",
		Vector3.new(-bh - 0.6, yS, bz - bh - 0.6),
		Vector3.new(bh + 0.6, yS + b.slab, bz + bh + 0.6),
		body
	)
	local belt = Kit.detail(
		m,
		"BelfryBand",
		Vector3.new(-bh - 0.65, yS + 0.45, bz - bh - 0.75),
		Vector3.new(bh + 0.65, yS + 1.15, bz + bh + 0.75),
		accent
	)
	belt.textures = {
		{ face = Enum.NormalId.Front, image = City.textures.windowBold, u = 1.2, v = 0.7, color = pal.body },
	}

	-------------------------------------------------------------------------------------------------------
	-- The dome: a drum, a ball most of which shows, a neck, a spike and a finial
	-------------------------------------------------------------------------------------------------------
	local yT = yS + b.slab
	Kit.column(m, "DomeDrum", 0, bz, yT - 0.1, yT + dm.drum, drumD, body)
	local cy = yT + dm.drum + domeD * dm.lift
	Kit.ball(m, "Dome", Vector3.new(0, cy, bz), domeD, metal, "trim")
	local ballTop = cy + domeD / 2
	Kit.column(m, "Neck", 0, bz, ballTop - 0.6, ballTop + dm.neck - 0.2, dm.neck, metal, "detail")
	Kit.spire(m, "Spike", 0, bz, ballTop + dm.neck - 0.2, dm.spike, 0.7, metal, 2, false)
	Kit.ball(
		m,
		"Finial",
		Vector3.new(0, ballTop + dm.neck - 0.2 + dm.spike + dm.finial / 2 - 0.05, bz),
		dm.finial,
		metal
	)
	-- On the plinth's ledge, washing the belfry's front and the dome.
	Kit.wash(m, "Wash", -bh + 1, bh - 1, bz - bh - 0.3, yP + 0.02, pal.wash)

	-------------------------------------------------------------------------------------------------------
	-- The porte-cochère, the forecourt, planters, and a pool court behind the centre on a deep site
	-------------------------------------------------------------------------------------------------------
	local cp = SHAPE.canopy
	local cwC = cC + cp.past
	Kit.canopy(m, "Canopy", -cwC, cwC, -hd + 1, zG + 0.05, cp.y, cp.thick, body)
	Kit.detail(
		m,
		"CanopyLine",
		Vector3.new(-cwC - 0.05, cp.y + 0.3, -hd + 0.85),
		Vector3.new(cwC + 0.05, cp.y + 0.8, -hd + 1.05),
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
	for i, x in { -(cwC - 1.2), -cC * 0.4, cC * 0.4, cwC - 1.2 } do
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
			Vector3.new(-cC + 0.05, 0, zC1 + 0.5),
			Vector3.new(cC - 0.05, SHAPE.forecourt, zB - 0.5),
			terrazzo
		)
		Kit.pool(m, "Pool", Vector3.new(-cC + 4, 0, zC1 + 5), Vector3.new(cC - 4, 0, zB - 5), SHAPE.forecourt)
	end
end

local archetype: Types.Archetype = { id = "domed_cupola_hotel", build = build }
return archetype
