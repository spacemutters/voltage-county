--!strict
-- B11 mimo_truss_motel (docs/city/ARCHETYPES.md §6, B11): the boulevard's mid-century motel. A two-storey white motel
-- round a pool court open to the road (a U, or an L), flat roofs reaching out over the court; along the back wing an
-- upper catwalk on pairs of thin pastel V-struts, a balustrade of slim bars, doors in two alternating pastels, jalousie
-- window bands; a stair rising to the catwalk beside a flat-arched portal; stone-faced piers at the wings' road ends,
-- teal shadow boxes and a shell fountain. By the road its signature: a pill-shaped name board held up by two lattice
-- pylons in two bright colours (crown 1 leaning in toward each other, crown 2 splayed out under a starburst), with a
-- VACANCY panel; and over the office a raked porte-cochère on V-legs whose masts pierce it and end in saucers.
--
-- What makes it itself: a name board held high by two leaning lattice pylons in front of a catwalk motel.
-- Placement, sizes, heights and its budget: Config/CityArchetypes/mimo_truss_motel.
-- Variants: palette (4 pairs of pylon colours with their doors, struts and board), crown (1 pylons leaning in, ball
-- finials; 2 pylons splayed out, a starburst over the board), rhythm (1 a U round the court, 2 an L, the court open on
-- the sign's side), mirror (the sign and the office swap sides).
--
-- Previewing (the Studio helper): look from the road at eye height and from a front corner. Check that the pylons'
-- lattice zigzags between their two rails, that the board's round ends sit on the pylons, that the V-struts meet the
-- catwalk's edge, that the stair's slope rises toward the portal (not away), that the bars of the balustrade show
-- (a see-through part with a bar texture), that the porte-cochère rakes up toward the road. At night: the board glows
-- pink, the VACANCY panel and the office sign cyan, the pool cyan, the ground-floor rooms warm, and the wash lights the
-- upper doors. Compare with photos of its inspiration (ARCHETYPES.md B11).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local City = require(ReplicatedStorage.Shared.Config.City)
local Kit = require(script.Parent.Parent.Parent.Kit)
local Types = require(script.Parent.Parent.Parent.Types)

local P = City.palettes
local KIT = City.kit
local rgb = Color3.fromRGB

-- The recipe, in studs.
local SHAPE = {
	roof = 0.8, -- the roof slabs over the walls (two storeys under them)
	front = 10, -- the side wings' road ends stand this far behind the front line
	sideInset = 1.5,
	wing = 15, -- a side wing's width
	backWing = 15, -- the back wing's depth
	overhang = { court = 3.5, outer = 1, step = 0.04 }, -- past the court faces, past the outer walls; side roofs lower
	catwalk = { depth = 3.5, thick = 0.7, rail = 3.2, bars = 1.2 },
	strut = { every = 11, count = { 3, 5 }, thick = 0.45, spread = 1.6 },
	louvre = 0.8, -- jalousie slats in the window bands
	room = 9, -- a room's width along the catwalk
	doors = 6, -- at most
	door = { width = 3.2, height = 7 },
	stair = { width = 3.5, run = 1.1, thick = 0.8, tread = 1.1 }, -- the run is this share of the climb
	portal = { width = 6, pier = 1, lintel = 1.6, over = 3.5 },
	stone = { width = 4.5, rise = 5, proud = 0.6 },
	shadowBox = { size = 2.4, proud = 0.8, step = 3.4 },
	fountain = { basin = 7, height = 1.5, shell = 6 },
	sign = {
		rise = 12,
		lean = 6,
		rail = 0.5,
		gap = 2.8,
		spread = 18,
		lattice = 5,
		bar = 0.35,
		behind = 1,
		board = { 1, 8 },
	},
	vacancy = { width = 8, height = 2 },
	star = { size = 5, lift = 3 }, -- crown 2: the starburst over the board
	porte = { width = 22, low = 11, high = 13, thick = 0.8, mast = 7, saucer = 3, vee = 1.4, leg = 0.4, inset = 4 },
	court = 0.3, -- the paving's top
	foot = 0.5, -- slanted legs and rails start this far under the ground (their corners dip a little further)
}

-- The two pylons' colours (the first also the struts, legs and roof edge), the board's colour, the doors' two pastels.
local PALETTES = {
	{ pylons = { P.deco.aqua, rgb(238, 128, 108) }, board = rgb(36, 56, 140), doors = { P.deco.pink, P.deco.lemon } },
	{ pylons = { rgb(238, 128, 108), P.deco.lemon }, board = rgb(28, 104, 120), doors = { P.deco.aqua, P.deco.mint } },
	{ pylons = { P.deco.mint, P.deco.pink }, board = rgb(120, 40, 96), doors = { P.deco.sky, P.deco.peach } },
	{ pylons = { P.deco.sky, P.deco.lemon }, board = rgb(30, 84, 128), doors = { P.deco.pink, P.deco.mint } },
}

local WASH = rgb(255, 196, 150)

local function build(m: Types.Model)
	local site = m.site
	local variant = site.variant
	local pal = PALETTES[math.clamp(variant.palette, 1, #PALETTES)]
	local crown = math.clamp(variant.crown, 1, 2)
	local uPlan = variant.rhythm ~= 2
	local rng = Kit.rng(m)
	local W, D = site.width, site.depth
	local hw, hd = W / 2, D / 2
	local H = site.height
	local wallTop = H - SHAPE.roof
	local f1 = wallTop / 2 -- each storey

	local white = Kit.look(P.deco.white, Enum.Material.SmoothPlastic)
	local accent = Kit.look(pal.pylons[1], Enum.Material.SmoothPlastic)
	local terrazzo = Kit.look(P.deco.terrazzo, Enum.Material.SmoothPlastic)
	local stoneLook = Kit.look(rgb(185, 168, 142), Enum.Material.Sandstone)
	local dark = P.window.dark

	local x0, x1 = -hw + SHAPE.sideInset, hw - SHAPE.sideInset
	local zB = hd - 1
	local zW = -hd + SHAPE.front -- the side wings' road ends
	local zK = zB - SHAPE.backWing -- the back wing's court face
	local sw = SHAPE.wing
	local cx0 = x0 + sw -- the court's left edge
	local cx1 = if uPlan then x1 - sw else x1 - 1 -- and its right edge

	-------------------------------------------------------------------------------------------------------
	-- The wings and their roofs
	-------------------------------------------------------------------------------------------------------
	Kit.box(m, "BackWing", Vector3.new(x0, -KIT.bury, zK), Vector3.new(x1, wallTop, zB), white)
	-- The side wings stand a hair in from the back wing's ends, so their outer walls never share its plane; a panel of
	-- punched windows on each one's court face (its top on the wall top, so the tiles fall per storey).
	Kit.box(m, "WingL", Vector3.new(x0 + 0.04, -KIT.bury, zW), Vector3.new(cx0, wallTop, zK + 0.5), white)
	Kit.punched(
		m,
		"WindowsL",
		Vector3.new(cx0 - 0.4, 0, zW + 1),
		Vector3.new(cx0 + 0.06, wallTop - 0.05, zK - 0.5),
		P.deco.white,
		dark,
		{ Enum.NormalId.Right },
		SHAPE.room / 2,
		f1
	)
	if uPlan then
		Kit.box(m, "WingR", Vector3.new(cx1, -KIT.bury, zW), Vector3.new(x1 - 0.04, wallTop, zK + 0.5), white)
		Kit.punched(
			m,
			"WindowsR",
			Vector3.new(cx1 - 0.06, 0, zW + 1),
			Vector3.new(cx1 + 0.4, wallTop - 0.05, zK - 0.5),
			P.deco.white,
			dark,
			{ Enum.NormalId.Left },
			SHAPE.room / 2,
			f1
		)
	end
	local ov = SHAPE.overhang
	Kit.trim(
		m,
		"RoofBack",
		Vector3.new(x0 - ov.outer, wallTop, zK - ov.court),
		Vector3.new(x1 + ov.outer, H, zB + 0.9),
		white
	)
	Kit.detail(
		m,
		"Fascia",
		Vector3.new(x0 - ov.outer, wallTop + 0.1, zK - ov.court - 0.15),
		Vector3.new(x1 + ov.outer, H - 0.1, zK - ov.court + 0.05),
		accent
	)
	Kit.trim(
		m,
		"RoofL",
		Vector3.new(x0 - ov.outer, wallTop - ov.step, zW - ov.outer),
		Vector3.new(cx0 + ov.court, H - ov.step, zK),
		white
	)
	if uPlan then
		Kit.trim(
			m,
			"RoofR",
			Vector3.new(cx1 - ov.court, wallTop - ov.step, zW - ov.outer),
			Vector3.new(x1 + ov.outer, H - ov.step, zK),
			white
		)
	end

	-------------------------------------------------------------------------------------------------------
	-- The back wing's court face: jalousie bands, the catwalk on V-struts, its balustrade, the upper doors
	-------------------------------------------------------------------------------------------------------
	for k = 1, 2 do
		local yb = (k - 1) * f1
		Kit.glass(
			m,
			`Louvres{k}`,
			Vector3.new(cx0 + 1, yb + 2.2, zK - 0.12),
			Vector3.new(cx1 - 1, yb + f1 - 2, zK + 0.3),
			dark,
			{
				image = City.textures.windowBold,
				faces = { Enum.NormalId.Front },
				u = SHAPE.room,
				v = SHAPE.louvre,
				lines = rgb(232, 236, 236),
				reflectance = 0.15,
				lit = k == 1,
			}
		)
	end
	local cw = SHAPE.catwalk
	local zE = zK - cw.depth -- the catwalk's front edge
	Kit.box(m, "Catwalk", Vector3.new(cx0, f1 - cw.thick, zE), Vector3.new(cx1, f1, zK + 0.4), white)
	-- The balustrade: one see-through panel whose bar texture draws the slim bars, a rail and a kick band.
	local rail = Kit.detail(
		m,
		"Balustrade",
		Vector3.new(cx0, f1, zE + 0.05),
		Vector3.new(cx1, f1 + cw.rail, zE + 0.25),
		Kit.look(rgb(240, 242, 242), Enum.Material.Metal, 0, 1)
	)
	rail.textures = {
		{
			face = Enum.NormalId.Front,
			image = City.textures.windowBold,
			u = cw.bars,
			v = cw.rail,
			color = rgb(244, 246, 246),
		},
	}
	local st = SHAPE.strut
	local span = cx1 - cx0
	local nV = math.clamp(math.floor(span / st.every) + 1, st.count[1], st.count[2])
	for j = 1, nV do
		local vx = cx0 + 2 + (span - 4) * (j - 1) / (nV - 1)
		local foot = Vector3.new(vx, 0, zE + 0.8)
		for s, dx in { -1, 1 } do
			local head = Vector3.new(vx + dx * st.spread, f1 - cw.thick + 0.1, zE + 0.4)
			Kit.strut(m, `Strut{j}{s}`, foot, head, st.thick, accent, "detail")
		end
	end
	local nDoors = math.min(SHAPE.doors, math.floor(span / SHAPE.room))
	local dw = SHAPE.door.width / 2
	for j = 1, nDoors do
		local dx = cx0 + span * (j - 0.5) / nDoors
		Kit.detail(
			m,
			`Door{j}`,
			Vector3.new(dx - dw, f1 + 0.05, zK - 0.18),
			Vector3.new(dx + dw, f1 + SHAPE.door.height, zK + 0.1),
			Kit.look(pal.doors[(j - 1) % 2 + 1], Enum.Material.SmoothPlastic)
		)
	end

	-------------------------------------------------------------------------------------------------------
	-- The stair up to the catwalk and the flat-arched portal beside it (two flights when the court is wide enough)
	-------------------------------------------------------------------------------------------------------
	local sr = SHAPE.stair
	local pt = SHAPE.portal
	local run = f1 * sr.run
	local zs0, zs1 = zE - sr.width, zE + 0.05
	local inner = pt.width / 2 + pt.pier -- the flights start past the portal's piers
	local twin = 2 * (inner + run) <= span - 4
	-- Two flights meet the portal in the court's middle; one flight runs on the far side from the office, the portal as
	-- near the middle as it fits.
	local px = if twin then (cx0 + cx1) / 2 else math.min(cx1 - 2 - run - inner, (cx0 + cx1) / 2)
	-- Open flights: a sloped plank each, its treads drawn on top, rising to the catwalk at the portal.
	local zsc = (zs0 + zs1) / 2
	local treadLook = Kit.look(rgb(232, 222, 210), Enum.Material.SmoothPlastic)
	for _, side in (if twin then { 1, -1 } else { 1 }) :: { number } do
		local headX = px + side * inner
		local flight = Kit.strut(
			m,
			if side > 0 then "StairR" else "StairL",
			Vector3.new(headX + side * run, sr.thick / 2, zsc),
			Vector3.new(headX, f1 - sr.thick / 2, zsc),
			sr.thick,
			treadLook,
			"box",
			sr.width
		)
		flight.textures = {
			{
				face = Enum.NormalId.Top,
				image = City.textures.slabLine,
				u = sr.width,
				v = sr.tread,
				color = rgb(150, 140, 130),
			},
		}
	end
	local portalTop = f1 + pt.over
	for i, s in { -1, 1 } do
		local a, b = px + s * pt.width / 2, px + s * inner
		Kit.box(
			m,
			`PortalPier{i}`,
			Vector3.new(math.min(a, b), -KIT.bury, zs0 - 0.3),
			Vector3.new(math.max(a, b), portalTop, zs1),
			white
		)
	end
	Kit.trim(
		m,
		"PortalLintel",
		Vector3.new(px - inner - 0.4, portalTop, zs0 - 0.5),
		Vector3.new(px + inner + 0.4, portalTop + pt.lintel, zs1 + 0.2),
		accent
	)

	-------------------------------------------------------------------------------------------------------
	-- The wings' road ends: stone piers, the office under the porte-cochère, shadow boxes, the shell fountain
	-------------------------------------------------------------------------------------------------------
	local sn = SHAPE.stone
	Kit.box(
		m,
		"StoneL",
		Vector3.new(x0 + 0.5, -KIT.bury, zW - sn.proud),
		Vector3.new(x0 + 0.5 + sn.width, H + sn.rise, zW + 1.2),
		stoneLook
	)
	Kit.glass(
		m,
		"Office",
		Vector3.new(x0 + 1.3 + sn.width, 0.5, zW - 0.12),
		Vector3.new(cx0 - 1.5, f1 - 1.5, zW + 0.3),
		dark,
		{
			image = City.textures.windowBold,
			faces = { Enum.NormalId.Front },
			u = 2.6,
			v = f1 - 2,
			lines = P.deco.white,
			lit = true,
		}
	)
	local sb = SHAPE.shadowBox
	local bx = x0 + 1.3 + sn.width
	for k = 1, 3 do
		local y = f1 + 0.8 + (k - 1) * sb.step
		Kit.trim(
			m,
			`ShadowBox{k}`,
			Vector3.new(bx, y, zW - sb.proud),
			Vector3.new(bx + sb.size, y + sb.size, zW + 0.3),
			accent
		)
	end
	if uPlan then
		Kit.box(
			m,
			"StoneR",
			Vector3.new(x1 - 0.5 - sn.width, -KIT.bury, zW - sn.proud),
			Vector3.new(x1 - 0.5, H + sn.rise, zW + 1.2),
			stoneLook
		)
		local fn = SHAPE.fountain
		local fx = cx1 + fn.basin / 2 + 1
		Kit.column(m, "Basin", fx, zW, -KIT.bury, fn.height, fn.basin, white)
		-- The shell: a pink disc on the end wall, its foot hidden behind the basin's rim.
		Kit.tube(
			m,
			"Shell",
			Vector3.new(fx, fn.height + fn.shell * 0.4, zW - 0.5),
			Vector3.new(fx, fn.height + fn.shell * 0.4, zW + 0.3),
			fn.shell,
			Kit.look(P.deco.pink, Enum.Material.SmoothPlastic),
			"trim"
		)
	end

	-------------------------------------------------------------------------------------------------------
	-- The porte-cochère over the office: a plank raked up toward the road, its OFFICE sign, two V-legs whose masts
	-- pierce it and end in saucers
	-------------------------------------------------------------------------------------------------------
	local po = SHAPE.porte
	local pw = math.min(po.width, sw + 6)
	local pa, pb = x0 + 0.5, x0 + 0.5 + pw
	local zBack, zFront = zW - 0.3, -hd + 1
	local pc = (pa + pb) / 2
	Kit.strut(m, "Porte", Vector3.new(pc, po.low, zBack), Vector3.new(pc, po.high, zFront), po.thick, white, "trim", pw)
	Kit.sign(
		m,
		"OfficeSign",
		Vector3.new(pa + 1, po.high + 0.3, zFront + 0.25),
		Vector3.new(pa + 9, po.high + 2.3, zFront + 0.65),
		Enum.NormalId.Front,
		"OFFICE",
		pal.board,
		P.deco.white,
		Enum.Font.Sarpanch,
		"sign"
	)
	local zp = -hd + 3.5
	local yU = po.low + (po.high - po.low) * (zBack - zp) / (zBack - zFront) - po.thick / 2 -- the plank's underside
	for i, xp in { pa + po.inset, pb - po.inset } do
		for s, dx in { -1, 1 } do
			Kit.strut(
				m,
				`PorteLeg{i}{s}`,
				Vector3.new(xp, -SHAPE.foot, zp),
				Vector3.new(xp + dx * po.vee, yU, zp),
				po.leg,
				accent
			)
		end
		Kit.column(m, `Mast{i}`, xp, zp, yU - 0.5, yU + po.mast, po.leg, accent, "detail")
		Kit.disc(m, `Saucer{i}`, xp, zp, yU + po.mast + 0.2, po.saucer, 0.35, accent)
	end

	-------------------------------------------------------------------------------------------------------
	-- The sign: two lattice pylons (leaning in, or splayed out) holding a pill-shaped board and a VACANCY panel
	-------------------------------------------------------------------------------------------------------
	local sg = SHAPE.sign
	local Hp = H + sg.rise
	local slope = math.tan(math.rad(sg.lean)) * (if crown == 1 then -1 else 1) -- outward drift per stud of height
	local reachOut = sg.spread / 2 + sg.gap / 2 + math.max(0, slope * Hp) + sg.rail
	local sxC = x1 - reachOut - 1
	local zP = -hd + 3.5
	local zR = zP + sg.behind -- the pylons' plane
	local bars = sg.lattice
	local function xAt(foot: number, side: number, y: number): number
		return foot + side * slope * y
	end
	local tops: { number } = {}
	for i, side in { -1, 1 } do
		local foot = sxC + side * sg.spread / 2
		local look = Kit.look(pal.pylons[i], Enum.Material.SmoothPlastic)
		-- Two rails side by side along the road (so the lattice faces the street), behind the board.
		for r, dx in { -sg.gap / 2, sg.gap / 2 } do
			Kit.strut(
				m,
				`Pylon{i}Rail{r}`,
				Vector3.new(xAt(foot + dx, side, -SHAPE.foot), -SHAPE.foot, zR),
				Vector3.new(xAt(foot + dx, side, Hp), Hp, zR),
				sg.rail,
				look
			)
		end
		-- The lattice: bars zigzagging from rail to rail up the pylon.
		for k = 1, bars do
			local ya, yb = 1 + (Hp - 3) * (k - 1) / bars, 1 + (Hp - 3) * k / bars
			local flip = if k % 2 == 1 then 1 else -1
			Kit.strut(
				m,
				`Pylon{i}Bar{k}`,
				Vector3.new(xAt(foot - flip * sg.gap / 2, side, ya), ya, zR),
				Vector3.new(xAt(foot + flip * sg.gap / 2, side, yb), yb, zR),
				sg.bar,
				look,
				"detail"
			)
		end
		tops[i] = xAt(foot, side, Hp)
		if crown == 1 then
			Kit.ball(m, `Finial{i}`, Vector3.new(tops[i], Hp + 0.7, zR), 1.4, look)
		end
	end
	local names = City.signNames.hotels
	local yb0, yb1 = H + sg.board[1], H + sg.board[2]
	local bh = yb1 - yb0
	local edgeL = xAt(sxC - sg.spread / 2, -1, yb1) + 0.3
	local edgeR = xAt(sxC + sg.spread / 2, 1, yb1) - 0.3
	local boardLook = Kit.look(pal.board, Enum.Material.SmoothPlastic)
	Kit.sign(
		m,
		"Board",
		Vector3.new(edgeL, yb0, zP - 0.35),
		Vector3.new(edgeR, yb1, zP + 0.35),
		Enum.NormalId.Front,
		`{names[rng:NextInteger(1, #names)]} MOTEL`,
		pal.board,
		P.deco.white,
		Enum.Font.Sarpanch,
		"neonPink"
	)
	for i, ex in { edgeL, edgeR } do
		Kit.lit(
			Kit.tube(
				m,
				`BoardEnd{i}`,
				Vector3.new(ex, (yb0 + yb1) / 2, zP - 0.3),
				Vector3.new(ex, (yb0 + yb1) / 2, zP + 0.3),
				bh,
				boardLook,
				"detail"
			),
			"neonPink"
		)
	end
	local vc = SHAPE.vacancy
	Kit.sign(
		m,
		"Vacancy",
		Vector3.new(sxC - vc.width / 2, yb0 - 0.6 - vc.height, zP - 0.25),
		Vector3.new(sxC + vc.width / 2, yb0 - 0.6, zP + 0.25),
		Enum.NormalId.Front,
		"VACANCY",
		rgb(30, 32, 44),
		P.deco.pink,
		Enum.Font.Sarpanch,
		"sign"
	)
	if crown == 2 then
		-- A starburst over the board: a ball and three crossed spikes.
		local sr2 = SHAPE.star
		local c = Vector3.new(sxC, yb1 + sr2.lift, zP)
		local starLook = Kit.look(pal.pylons[2], Enum.Material.SmoothPlastic)
		Kit.ball(m, "Star", c, 1.6, starLook)
		local h = sr2.size / 2
		Kit.tube(m, "StarX", c - Vector3.xAxis * h, c + Vector3.xAxis * h, 0.35, starLook)
		Kit.tube(m, "StarY", c - Vector3.yAxis * h, c + Vector3.yAxis * h, 0.35, starLook)
		Kit.tube(m, "StarZ", c - Vector3.zAxis * h, c + Vector3.zAxis * h, 0.35, starLook)
	end

	-------------------------------------------------------------------------------------------------------
	-- The court: paving, the pool in front of the stair (it glows at night), the wash on the catwalk's edge
	-------------------------------------------------------------------------------------------------------
	Kit.box(m, "Court", Vector3.new(-hw + 0.3, 0, -hd + 0.3), Vector3.new(hw - 0.3, SHAPE.court, zK + 0.5), terrazzo)
	local qz0, qz1 = zW + 1.5, zs0 - 2
	if qz1 - qz0 >= 5 then
		local pool = Kit.pool(m, "Pool", Vector3.new(cx0 + 2.5, 0, qz0), Vector3.new(cx1 - 2.5, 0, qz1), SHAPE.court)
		Kit.lit(pool[2], "sign")
	end
	Kit.wash(m, "Wash", cx0 + 1, cx1 - 1, zE + 0.6, f1 + 0.02, WASH)
end

local archetype: Types.Archetype = { id = "mimo_truss_motel", build = build }
return archetype
