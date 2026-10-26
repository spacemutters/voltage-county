--!strict
-- B04 deco_porthole_highrise (docs/city/ARCHETYPES.md §6, B04): the tall hotel of the beach strip, ten to twelve
-- storeys of pale stone in three parts. The middle third stands forward as a shaft of vertical piers, its windows
-- set back between them over coloured spandrels, and the piers climb past the roof in steps toward the centre, each
-- pair flanking a tier of a ziggurat attic ringed in neon. The two corner bays either side are all horizontals: a
-- ribbon window per floor that turns the corner onto the side, under an eyebrow slab that wraps it. At the foot a
-- projecting two-storey entry block of three bays (a lit door under a half-moon hood, a porthole under an eyebrow, a
-- casement window over it) carries the name on its roof. On top, a lantern under a name board on posts, or a stepped
-- pyramid, a mast and two flagpoles.
--
-- What makes it itself: a pale stone tower whose vertical centre of piers steps up into a ziggurat crown between
-- corner bays of wrapping horizontal eyebrows, over a porthole entry.
-- Placement, sizes, heights and its budget: Config/CityArchetypes/deco_porthole_highrise.
-- Variants: palette (3: ivory stone with green-teal spandrels, peach with rose, white with aqua piers and blue; each
-- with its ring neon and its porthole neon), crown (1 a lantern under a rooftop name board, 2 a stepped pyramid, a
-- mast and two flagpoles), rhythm (1 five piers and a three-tier ziggurat, 2 four wider piers and two tiers), mirror
-- (symmetric: it changes only the stair house).
--
-- Round 3 (2026-10-26, from the 1940 and 1950 postcards of the inspiration): the old uniform grid of seven bays gave
-- way to the real three-part front, vertical centre against horizontal corner bays with corner windows, the entry's
-- porthole stack and the rooftop name board. Preview check: the corner bays' one-tile-per-floor punched overlay reads
-- as a ribbon window turning the corner on both faces, the eyebrows die into the outer piers, the pier tops step up
-- toward the centre past the attic tiers, the lit centre glass glows warm at night between dark piers, and the
-- rooftop board's text faces the street.
-- Round 4 (2026-10-26, seen in Studio): one run of glass across the shaft read as an office curtain wall; each bay
-- between the piers is now its own band of casement windows punched in a coloured spandrel panel, with stone showing
-- either side against the piers.

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
	ground = 16, -- the lobby floor
	parapet = 4, -- at least
	floorMin = 10.5,
	floorMax = 11.8,
	floors = { 9, 11 }, -- upper floors
	terrace = 12,
	bodyDepth = 40,
	sideInset = 3, -- the corner bays' eyebrows wrap the sides, so the walls keep this far in
	plinth = 2.2,
	lintel = 3, -- the lobby glass tops out this far under the first floor
	-- The centre shaft: its width (a share of the front, leaving each corner bay at least `wing`), and how far it
	-- stands in front of the corner bays (past their eyebrows, so those die into it).
	centre = { share = 0.52, min = 24, max = 46, proud = 2.8, wing = 8 },
	piers = { 5, 4 }, -- by rhythm, the outer two on the shaft's edges
	pier = { outer = 2.2, inner = 1.8, proud = 1.3, over = 1.6 },
	casement = 3.4, -- about this wide, between the piers
	stripMargin = 0.9, -- stone between a pier and the bay's strip of windows
	eyebrow = { thick = 0.6, proud = 2.4 },
	canopy = { thick = 0.9, proud = 2.4 },
	-- The ziggurat attic: one tier per pier pair, each `rise` tall and `depth` deep, its face stepping back `back` a
	-- tier, its sides tucked `tuck` inside the piers that flank it. Five piers: the third tier is the centre pier's
	-- own.
	tiers = { { rise = 8, depth = 16 }, { rise = 7, depth = 12 }, { rise = 6, depth = 8 } },
	back = 1,
	tuck = 0.3,
	entry = { share = 0.72, min = 16, max = 30, out = 6, storeys = 2 },
	doorUnder = 3, -- the doors top out this far under the first floor
	porthole = 4.4,
	lantern = { diameter = 4, height = 3.4 }, -- crown 1
	board = { width = 16, height = 4, over = 5.8, post = 0.4 }, -- crown 1: the name board on posts over the lantern
	pyramid = { 0.7, 0.45, 0.22 }, -- crown 2: the stepped pyramid's tiers, shares of the top tier
	pyramidRise = 1.8,
	mast = 30, -- crown 2: the mast's top over the roof
	flag = 9, -- crown 2: the flagpoles over the roof
	sideBay = 6,
	terraceTop = 0.9,
	balustrade = 2.2,
	umbrella = 7.5,
}

-- Stone (body, corner bays, attic), piers, trim (hoods, rims, eyebrows over the portholes), the spandrels between the
-- shaft's windows, the ring neon (crown rings and pier lines) and the porthole neon, the letters, the wash.
local PALETTES = {
	{
		body = rgb(240, 234, 220),
		pier = rgb(250, 248, 242),
		trim = P.deco.aqua,
		spandrel = rgb(104, 170, 150),
		ringKind = "crown",
		portKind = "neonAmber",
		letters = rgb(40, 120, 140),
		wash = rgb(255, 210, 160),
	},
	{
		body = rgb(255, 196, 160),
		pier = rgb(252, 248, 240),
		trim = P.deco.pink,
		spandrel = rgb(214, 128, 136),
		ringKind = "neonPink",
		portKind = "neonAmber",
		letters = rgb(200, 70, 100),
		wash = rgb(255, 150, 170),
	},
	{
		body = rgb(246, 244, 238),
		pier = rgb(150, 216, 222),
		trim = P.deco.sky,
		spandrel = rgb(90, 138, 196),
		ringKind = "neonBlue",
		portKind = "neonCyan",
		letters = rgb(40, 100, 170),
		wash = rgb(150, 190, 255),
	},
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

	local stone = Kit.look(pal.body, Enum.Material.SmoothPlastic)
	local pierLook = Kit.look(pal.pier, Enum.Material.SmoothPlastic)
	local trim = Kit.look(pal.trim, Enum.Material.SmoothPlastic)
	local plinthLook = Kit.look(rgb(214, 198, 168), Enum.Material.Limestone)

	local x0, x1 = -hw + SHAPE.sideInset, hw - SHAPE.sideInset
	local zF = -hd + SHAPE.terrace -- the corner bays' face
	local zB = math.min(hd - 1, zF + SHAPE.bodyDepth)
	local Wf = x1 - x0
	local ce = SHAPE.centre
	local cw = math.clamp(Wf * ce.share, ce.min, math.min(ce.max, Wf - 2 * ce.wing))
	local ww = (Wf - cw) / 2 -- a corner bay's width, and how far its windows turn onto the side
	local zC = zF - ce.proud -- the shaft's face
	local n = SHAPE.piers[math.clamp(variant.rhythm, 1, 2)]
	local spacing = cw / (n - 1)
	local pr = SHAPE.pier

	-- The attic's tiers: tier k stands between piers k and n + 1 - k; with an odd count the last is the centre pier's.
	local tierCount = math.ceil(n / 2)
	local function pierWidth(g: number): number
		return if g == 1 then pr.outer else pr.inner
	end
	local function tierHalf(k: number): number
		if 2 * k - 1 == n then
			return spacing / 2 -- the centre pier's own tier
		end
		return cw / 2 - (k - 1) * spacing + pierWidth(k) / 2 - SHAPE.tuck
	end
	local cum: { number } = { [0] = 0 }
	for k = 1, tierCount do
		cum[k] = cum[k - 1] + SHAPE.tiers[k].rise
	end

	-------------------------------------------------------------------------------------------------------
	-- Body, plinth, the lit lobby, the canopy band over it
	-------------------------------------------------------------------------------------------------------
	Kit.box(m, "Body", Vector3.new(x0, -KIT.bury, zF), Vector3.new(x1, H, zB), stone)
	Kit.box(
		m,
		"Plinth",
		Vector3.new(x0 - 0.06, -KIT.bury, zF - 0.4),
		Vector3.new(x1 + 0.06, SHAPE.plinth, zF + ww),
		plinthLook
	)
	local lobbyTop = G - SHAPE.lintel
	Kit.glass(
		m,
		"Lobby",
		Vector3.new(x0 + 1, SHAPE.plinth - 0.2, zF - 0.12),
		Vector3.new(x1 - 1, lobbyTop, zF + 0.3),
		P.window.dark,
		{
			image = City.textures.windowBold,
			faces = { FRONT },
			u = 4,
			v = lobbyTop - SHAPE.plinth + 0.2,
			lines = pal.pier,
			lit = true,
		}
	)
	local cp = SHAPE.canopy
	Kit.trim(
		m,
		"Canopy",
		Vector3.new(x0 - cp.proud, G - cp.thick / 2, zF - cp.proud),
		Vector3.new(x1 + cp.proud, G + cp.thick / 2, zF + ww + 0.3),
		pierLook
	)

	-------------------------------------------------------------------------------------------------------
	-- The corner bays: a ribbon window a floor on the front and turning onto the side, an eyebrow over each
	-------------------------------------------------------------------------------------------------------
	-- One punched tile per floor as wide as the bay (on the side, as deep: the bay is square in plan), so each floor
	-- shows one long window that turns the corner. Tiles count from the part's top, the top floor line.
	for i, side in { -1, 1 } do
		local outer = if side < 0 then x0 - 0.06 else x1 + 0.06
		local inner = side * (cw / 2 - 0.3)
		Kit.punched(
			m,
			`Wing{i}`,
			Vector3.new(math.min(outer, inner), G, zF - 0.06),
			Vector3.new(math.max(outer, inner), T, zF + ww + 0.3),
			pal.body,
			P.window.dark,
			{ FRONT, if side < 0 then LEFT else RIGHT },
			ww + 0.36,
			f
		)
		local wallX = if side < 0 then x0 else x1
		Kit.punched(
			m,
			`Side{i}`,
			Vector3.new(wallX - side * 0.4, G, zF + ww + 0.6),
			Vector3.new(wallX + side * 0.06, T, zB - 0.6),
			pal.body,
			P.window.dark,
			{ if side < 0 then LEFT else RIGHT },
			SHAPE.sideBay,
			f
		)
	end
	local brow = SHAPE.eyebrow
	for k = 1, up do
		-- The punched windows top out 12 % of a floor under the floor line; the eyebrow sits just over them.
		local y = G + k * f - 0.12 * f + brow.thick / 2 + 0.1
		Kit.trim(
			m,
			`Brow{k}`,
			Vector3.new(x0 - brow.proud, y - brow.thick / 2, zF - brow.proud),
			Vector3.new(x1 + brow.proud, y + brow.thick / 2, zF + ww + 0.3),
			pierLook
		)
	end
	Kit.trim(
		m,
		"Coping",
		Vector3.new(x0 - 0.4, H - 0.1, zF - 0.4),
		Vector3.new(x1 + 0.4, H + 0.6, zF + ww + 0.3),
		pierLook
	)

	-------------------------------------------------------------------------------------------------------
	-- The centre shaft: forward of the corner bays, lit glass set back between piers that climb past the roof
	-------------------------------------------------------------------------------------------------------
	Kit.box(m, "Centre", Vector3.new(-cw / 2, -KIT.bury, zC), Vector3.new(cw / 2, H, zF + 0.5), stone)
	-- One band a bay, stone showing either side of it against the piers: casement windows punched in a coloured
	-- spandrel panel, a window a floor (a single run of glass across the shaft read as an office curtain wall).
	local strip = spacing - pr.inner - 2 * SHAPE.stripMargin
	local panes = math.max(1, math.round(strip / SHAPE.casement))
	for b = 1, n - 1 do
		local bx = -cw / 2 + (b - 0.5) * spacing
		Kit.punched(
			m,
			`CentreGlass{b}`,
			Vector3.new(bx - strip / 2, G, zC - 0.12),
			Vector3.new(bx + strip / 2, T, zC + 0.3),
			pal.spandrel,
			P.window.dark,
			{ FRONT },
			strip / panes,
			f,
			true
		)
	end
	local innermost = tierCount -- the pier group nearest the centre carries the neon lines
	for i = 1, n do
		local g = math.min(i, n + 1 - i)
		local px = -cw / 2 + (i - 1) * spacing
		local h = pierWidth(g) / 2
		local top = H + cum[math.min(g, tierCount)] + pr.over
		Kit.box(
			m,
			`Pier{i}`,
			Vector3.new(px - h, -KIT.bury, zC - pr.proud),
			Vector3.new(px + h, top, zF + 0.3),
			pierLook
		)
		if g == innermost then
			Kit.neon(
				m,
				`PierNeon{i}`,
				Vector3.new(px, G + SHAPE.entry.storeys * f + 1.2, zC - pr.proud - 0.35),
				Vector3.new(px, top - 0.6, zC - pr.proud - 0.35),
				pal.ringKind,
				pal.trim
			)
		end
	end

	-------------------------------------------------------------------------------------------------------
	-- The ziggurat attic: a tier between each pier pair, its face stepping back, a neon ring under its top
	-------------------------------------------------------------------------------------------------------
	local lastFront, lastBack, lastHalf = zC, zC, 0
	for k = 1, tierCount do
		local tier = SHAPE.tiers[k]
		local half = tierHalf(k)
		local z0 = zC + SHAPE.tuck + (k - 1) * SHAPE.back
		local z1 = math.min(zC + tier.depth, zB - 2)
		local y0, y1 = H + cum[k - 1] - 0.02, H + cum[k]
		Kit.box(m, `Tier{k}`, Vector3.new(-half, y0, z0), Vector3.new(half, y1, z1), stone)
		Kit.neonStrip(
			m,
			`Ring{k}`,
			Vector3.new(-half - 0.15, y1 - 1.2, z0 - 0.15),
			Vector3.new(half + 0.15, y1 - 0.8, z1 + 0.15),
			pal.ringKind,
			pal.trim
		)
		lastFront, lastBack, lastHalf = z0, z1, half
	end
	local yT = H + cum[tierCount] -- the attic's top
	local metal = Kit.look(rgb(220, 224, 228), Enum.Material.Metal)
	local names = City.signNames.hotels
	local name = names[rng:NextInteger(1, #names)]
	if crown == 1 then
		-- A lantern at the front of the top tier, and the name on a board on two posts behind and over it.
		local lt = SHAPE.lantern
		local lz = lastFront + lt.diameter / 2 + 0.5
		Kit.column(m, "Lantern", 0, lz, yT - 0.02, yT + lt.height, lt.diameter, pierLook)
		Kit.ball(m, "Dome", Vector3.new(0, yT + lt.height, lz), lt.diameter * 0.9, trim, "trim")
		local bd = SHAPE.board
		local bz = math.min(lastBack - 0.5, lz + lt.diameter / 2 + 0.8)
		local postX = math.max(0.6, math.min(bd.width / 2 - 1, lastHalf - 0.6))
		local by0 = yT + bd.over
		for i, side in { -1, 1 } do
			Kit.column(m, `BoardPost{i}`, side * postX, bz, yT - 0.02, by0 + 0.02, bd.post, metal, "detail")
		end
		local board = Kit.sign(
			m,
			"Board",
			Vector3.new(-bd.width / 2, by0, bz - 0.3),
			Vector3.new(bd.width / 2, by0 + bd.height, bz + 0.3),
			FRONT,
			name,
			pal.pier,
			pal.letters,
			FONT
		)
		local labels: { MapTypes.LabelSpec } = board.labels or {}
		table.insert(labels, {
			face = BACK,
			text = name,
			color = pal.letters,
			font = FONT,
			size = Vector2.new(0.92, 0.8),
			pixelsPerStud = KIT.signPixelsPerStud,
		})
		board.labels = labels
		-- The board's light bar, under its front edge.
		Kit.neon(
			m,
			"BoardLight",
			Vector3.new(-bd.width / 2 + 0.6, by0 - 0.35, bz - 0.55),
			Vector3.new(bd.width / 2 - 0.6, by0 - 0.35, bz - 0.55),
			pal.ringKind,
			pal.trim
		)
	else
		-- A stepped pyramid and a mast on the top tier; two flagpoles on the corner bays' roof.
		local y = yT
		local zc = (lastFront + lastBack) / 2
		local depth = lastBack - lastFront
		for i, share in SHAPE.pyramid do
			local hx, hz = lastHalf * share, depth * share / 2
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
		Kit.lit(Kit.ball(m, "Finial", Vector3.new(0, mast + 0.6, zc), 1.2, trim), pal.ringKind)
		for i, side in { -1, 1 } do
			local fx = if side < 0 then x0 + 1.2 else x1 - 1.2
			Kit.column(m, `Flagpole{i}`, fx, zF + 1.2, H + 0.5, H + SHAPE.flag, 0.3, metal, "detail")
		end
	end
	Kit.roofBox(m, "Stair", Vector3.new(x1 - 12, H, zB - 11), Vector3.new(x1 - 4, H + 7, zB - 3), stone)

	-------------------------------------------------------------------------------------------------------
	-- The entry block: three bays of lit door, half-moon hood, porthole, eyebrow and casement; the name on its roof
	-------------------------------------------------------------------------------------------------------
	local en = SHAPE.entry
	local ew = math.clamp(cw * en.share, en.min, math.min(en.max, cw - 2))
	local zE = zC - en.out
	local Ye = G + en.storeys * f -- the entry's roof
	local eb = ew / 3 -- a bay
	Kit.box(m, "Entry", Vector3.new(-ew / 2, -KIT.bury, zE), Vector3.new(ew / 2, Ye, zF + 0.3), stone)
	Kit.trim(
		m,
		"EntryCap",
		Vector3.new(-ew / 2 - 0.6, Ye - 0.3, zE - 0.6),
		Vector3.new(ew / 2 + 0.6, Ye + 0.7, zC + 0.2),
		pierLook
	)
	for i, side in { -1, 1 } do
		local px = side * eb / 2
		Kit.trim(
			m,
			`Pilaster{i}`,
			Vector3.new(px - 0.6, SHAPE.terraceTop - 0.2, zE - 0.8),
			Vector3.new(px + 0.6, Ye - 0.25, zE + 0.3),
			pierLook
		)
	end
	local doorTop = G - SHAPE.doorUnder
	Kit.glass(
		m,
		"Doors",
		Vector3.new(-ew / 2 + 1, SHAPE.terraceTop - 0.3, zE - 0.25),
		Vector3.new(ew / 2 - 1, doorTop, zE + 0.3),
		P.window.dark,
		{
			image = City.textures.windowBold,
			faces = { FRONT },
			u = (ew - 2) / 3,
			v = doorTop - SHAPE.terraceTop + 0.3,
			lines = pal.pier,
			lit = true,
		}
	)
	local reach = 2 * (zE + hd - 0.4) -- a disc on the entry's face may be this wide and stay inside the front line
	local pd = math.min(SHAPE.porthole, eb - 1.4)
	local py = G + f / 2
	for i, bx in { -eb, 0, eb } do
		Kit.disc(m, `Hood{i}`, bx, zE, doorTop + 0.5, math.min(eb - 1.6, reach), 0.6, trim, "trim")
		Kit.porthole(m, `Port{i}`, bx, py, zE, pd, P.window.deep, trim, pal.portKind)
		Kit.disc(m, `PortBrow{i}`, bx, zE, py + pd / 2 + 0.9, math.min(pd + 2, eb - 0.3, reach), 0.5, pierLook, "trim")
	end
	Kit.glass(
		m,
		"EntryRibbon",
		Vector3.new(-ew / 2 + 1.5, G + f + 2.2, zE - 0.12),
		Vector3.new(ew / 2 - 1.5, Ye - 1.2, zE + 0.3),
		P.window.dark,
		{
			image = City.textures.windowFine,
			faces = { FRONT },
			u = 2.4,
			v = Ye - 1.2 - G - f - 2.2,
			lines = pal.pier,
			reflectance = 0.2,
		}
	)
	Kit.sign(
		m,
		"Sign",
		Vector3.new(-ew / 2 + 1.2, Ye + 0.7, zE - 0.4),
		Vector3.new(ew / 2 - 1.2, Ye + 3.5, zE - 0.1),
		FRONT,
		name,
		pal.pier,
		pal.letters,
		FONT
	)

	-------------------------------------------------------------------------------------------------------
	-- The café terrace either side of the entry, umbrellas, and the wash on the entry's roof
	-------------------------------------------------------------------------------------------------------
	local tTop = SHAPE.terraceTop
	Kit.box(
		m,
		"Terrace",
		Vector3.new(-hw + 0.2, 0, -hd + 0.3),
		Vector3.new(hw - 0.2, tTop, zF + 0.3),
		Kit.look(P.deco.terrazzo, Enum.Material.SmoothPlastic)
	)
	local railTop = tTop + SHAPE.balustrade
	local front = zC - pr.proud -- the piers' faces: the umbrellas keep clear of them
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
			Kit.umbrella(m, `Umbrella{i}{j}`, x, tz, tTop, math.max(2, math.min(room, len / count - 1)), color)
		end
	end
	-- On the entry's roof behind its name, washing the shaft's piers and glass.
	Kit.wash(m, "Wash", -cw / 2 + 1.2, cw / 2 - 1.2, zC - 1.6, Ye + 0.7, pal.wash)
end

local archetype: Types.Archetype = { id = "deco_porthole_highrise", build = build }
return archetype
