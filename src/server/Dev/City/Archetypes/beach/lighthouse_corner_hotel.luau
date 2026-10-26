--!strict
-- B07 lighthouse_corner_hotel (docs/city/ARCHETYPES.md §6, B07): the beach strip's lighthouse hotel. A white stucco
-- block on a corner whose street corner is a round drum; the upper floors overhang a recessed café porch under a sloped
-- awning; pastel eyebrows over every floor wrap the drum and run on down the side street; a fluted pilaster beside the
-- drum rises past the roof; and its signature, a little lighthouse standing on the drum: a plinth drum with a pastel
-- ring, a stout white shaft carrying the corner drum on up, a gallery ledge, a fat see-through glass lantern behind six
-- mullions round a lamp that glows at night, a broad saucer hat, and on top a pastel dome or a spire.
--
-- What makes it itself: a lighthouse with a glowing lantern on the hotel's rounded corner.
-- Placement, sizes, heights and its budget: Config/CityArchetypes/lighthouse_corner_hotel.
-- Variants: palette (4 pastel accents: eyebrows, awning, ribs, the ring, the dome and the neon line), crown (1 a
-- lighthouse with a glass block band up its shaft, a pastel dome and an amber lamp; 2 a slimmer two-stage lighthouse
-- with a porthole, a second gallery, a spire and a cool white lamp), rhythm (1 ribbon windows on every floor; 2 punched pairs of windows, glass
-- only round the drum), mirror (the corner and its lighthouse on the right or on the left).
--
-- Previewing (the Studio helper): stand at the front three-quarter on the drum side, then straight on. Check that the
-- eyebrow discs wrap the drum with no gap and meet the side-street eyebrows; that the lantern reads see-through by day
-- with the lamp inside it and its four posts; that the awning slopes down toward the street (not up); at night that
-- the lamp glows amber (crown 1) or white (crown 2), the pilaster's centre rib glows and the wash lights the drum and
-- the pilaster. Compare with photos of its inspiration (ARCHETYPES.md B07): the lighthouse should read at 70 mph.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local City = require(ReplicatedStorage.Shared.Config.City)
local Kit = require(script.Parent.Parent.Parent.Kit)
local Types = require(script.Parent.Parent.Parent.Types)

local P = City.palettes
local KIT = City.kit
local rgb = Color3.fromRGB

-- The recipe, in studs.
local SHAPE = {
	ground = 14, -- the café porch storey
	floorMin = 10.5, -- upper floors are at least this tall...
	floors = { 3, 4 }, -- ...and this many
	terrace = 8, -- the café terrace between the front line and the facade
	bodyDepth = 38, -- at most
	sideInset = 3.2, -- eyebrows stand proud past the side walls, so the walls keep this far in
	radius = { 0.17, 6, 8 }, -- the corner drum: share of the width, clamped
	porch = 1.6, -- the porch (and its drum) sits this far in under the upper floors
	window = 5.8, -- ribbon window height at most; it tops out `head` under the floor line
	head = 1.4,
	ribbonBay = 2.2, -- steel casement bays in the ribbons
	punchedBay = 6.5, -- rhythm 2: one pair of windows per bay
	eyebrow = { thick = 0.6, proud = 2.6 },
	canopy = { thick = 0.9, proud = 0.9 }, -- the accent band along the foot of the overhang
	cornice = { thick = 1.2, proud = 1.4 },
	sideRun = { 0.4, 10, 16 }, -- the side-street windows and eyebrows run back this far: share of the depth
	pilaster = { width = 3.4, proud = 1.1, rise = 4.5, gap = 0.6, cap = 0.8 },
	rib = 0.45,
	terraceTop = 0.9,
	awning = { reach = 3, low = 4.4, high = 1.6, valance = 0.8 }, -- out past the facade; its edges under the overhang
	gate = 4, -- half the opening between the two planters
	planter = 1.6,
	umbrella = 6,
	-- The lighthouse on the drum, by crown.
	towerInset = 2.2, -- its plinth drum is this much narrower than the corner drum
	plinth = 3.5, -- the plinth drum's height over the roof
	ring = 0.6, -- the pastel ring round the plinth's top
	shaft = { 12, 10 }, -- by crown: the lighthouse shaft's diameter at most (its lantern 1.4 narrower: a fat harbour lantern)...
	shaftNarrow = 1.8, -- ...and at least this much narrower than the plinth drum (it reads as the corner drum carrying on)
	shaftRise = { 8, 6 }, -- ...and its height
	lantern = { 5.5, 6 }, -- lantern height
	glassBlock = 1.4, -- crown 1: the glass block band starts this far up the shaft
	stage = 3.6, -- crown 2: the upper drum between the two galleries
	gallery = 0.8,
	post = 0.5,
	posts = 6, -- mullions round the lantern glass
	lamp = 0.58, -- the lamp's share of the lantern's diameter: big enough to read as a lit lantern at night
	hat = 0.9, -- crown 1's hat; crown 2's is the same thickness
	hatOver = { 2, 1.5 }, -- by crown: the hat's overhang past the lantern all round (a broad saucer, like a harbour light)
	dome = 7, -- crown 1: the pastel dome's diameter at most
	spire = 3.4,
}

-- Accent (eyebrows, canopy band, awning, ribs, umbrellas), the neon line's kind, the wash's colour and the sign's text.
local PALETTES = {
	{ accent = P.deco.aqua, neon = "sign", wash = rgb(120, 230, 220), text = rgb(28, 120, 128) },
	{ accent = P.deco.peach, neon = "neonPink", wash = rgb(255, 140, 170), text = rgb(206, 92, 56) },
	{ accent = P.deco.mint, neon = "sign", wash = rgb(130, 236, 200), text = rgb(36, 130, 100) },
	{ accent = P.deco.pink, neon = "neonPink", wash = rgb(255, 120, 200), text = rgb(206, 60, 112) },
}

-- The lamp in the lantern, by crown: amber like a harbour light, or a cool white.
local LAMPS = {
	{ kind = "neonAmber", day = rgb(255, 226, 160) },
	{ kind = "crown", day = rgb(236, 242, 248) },
}

local LANTERN = Kit.look(rgb(206, 232, 240), Enum.Material.Glass, 0.3, KIT.railTransparency)
local GLASS_BLOCK = Kit.look(rgb(196, 222, 228), Enum.Material.Glass, 0.25)
local CHROME = Kit.look(rgb(217, 222, 227), Enum.Material.Metal)

local function share(size: number, rule: { number }): number
	return math.clamp(size * rule[1], rule[2], rule[3])
end

local function build(m: Types.Model)
	local site = m.site
	local variant = site.variant
	local pal = PALETTES[math.clamp(variant.palette, 1, #PALETTES)]
	local crown = math.clamp(variant.crown, 1, 2)
	local ribbons = variant.rhythm ~= 2
	local rng = Kit.rng(m)
	local W, D = site.width, site.depth
	local hw, hd = W / 2, D / 2
	local G = SHAPE.ground
	local up = math.clamp(math.floor((site.height - G) / SHAPE.floorMin), SHAPE.floors[1], SHAPE.floors[2])
	local f = (site.height - G) / up
	local H = G + up * f
	local R = share(W, SHAPE.radius)
	local porch = SHAPE.porch

	local white = Kit.look(P.deco.white, Enum.Material.SmoothPlastic)
	local accent = Kit.look(pal.accent, Enum.Material.SmoothPlastic)
	local terrazzo = Kit.look(P.deco.terrazzo, Enum.Material.SmoothPlastic)

	local x0, x1 = -hw + SHAPE.sideInset, hw - SHAPE.sideInset
	local zF = -hd + SHAPE.terrace
	local zB = math.min(hd - 1, zF + SHAPE.bodyDepth)
	local cx, cz = x1 - R, zF + R -- the drum's axis
	local corner = { fr = true }
	local bodyMin, bodyMax = Vector3.new(x0, 0, zF), Vector3.new(x1, 0, zB)
	local sideRun = share(D, SHAPE.sideRun)
	local pil = SHAPE.pilaster
	local pxR = cx - pil.gap
	local pxL = pxR - pil.width

	-------------------------------------------------------------------------------------------------------
	-- Body: the porch storey set in under the upper floors, both round at the corner on one axis
	-------------------------------------------------------------------------------------------------------
	Kit.roundedBox(
		m,
		"Base",
		Vector3.new(x0 + 0.05, -KIT.bury, zF + porch),
		Vector3.new(x1 - porch, G + 0.3, zB - 0.05),
		R - porch,
		corner,
		white
	)
	Kit.roundedBox(m, "Body", Vector3.new(x0, G, zF), Vector3.new(x1, H, zB), R, corner, white)

	-- The café front, round the corner and down the side street, glowing warm at night.
	local shopTop = G - 1.2
	local shopFront = zF + porch
	Kit.glass(
		m,
		"Shop",
		Vector3.new(x0 + 2.2, SHAPE.terraceTop, shopFront - 0.12),
		Vector3.new(cx - 0.3, shopTop, shopFront + 0.3),
		P.window.dark,
		{
			image = City.textures.windowBold,
			faces = { Enum.NormalId.Front },
			u = 4,
			v = shopTop - SHAPE.terraceTop,
			lines = P.deco.white,
			lit = true,
		}
	)
	Kit.lit(
		Kit.column(
			m,
			"ShopCorner",
			cx,
			cz,
			SHAPE.terraceTop,
			shopTop,
			2 * (R - porch) + 0.14,
			Kit.glassLook(P.window.dark, 0.2),
			"detail"
		),
		"window"
	)
	Kit.glass(
		m,
		"ShopSide",
		Vector3.new(x1 - porch - 0.3, SHAPE.terraceTop, cz + 0.3),
		Vector3.new(x1 - porch + 0.12, shopTop, cz + sideRun),
		P.window.dark,
		{
			image = City.textures.windowBold,
			faces = { Enum.NormalId.Right },
			u = 4,
			v = shopTop - SHAPE.terraceTop,
			lines = P.deco.white,
			lit = true,
		}
	)

	-------------------------------------------------------------------------------------------------------
	-- Windows: ribbons (rhythm 1) or punched pairs (rhythm 2) on the front and the side street; a glass band round
	-- the drum on every floor either way
	-------------------------------------------------------------------------------------------------------
	local win = math.min(SHAPE.window, f - 3.6)
	local frontA, frontB = x0 + 2.2, pxL - 0.7
	local sideA, sideB = cz + 0.4, cz + sideRun
	local litFloor = if rng:NextNumber() < 0.6 then rng:NextInteger(1, up) else 0
	for k = 1, up do
		local top = G + k * f - SHAPE.head
		Kit.column(m, `Round{k}`, cx, cz, top - win, top, 2 * R + 0.12, Kit.glassLook(P.window.dark, 0.2), "detail")
		if ribbons then
			Kit.glass(
				m,
				`Window{k}`,
				Vector3.new(frontA, top - win, zF - 0.12),
				Vector3.new(frontB, top, zF + 0.3),
				P.window.dark,
				{
					image = City.textures.windowFine,
					faces = { Enum.NormalId.Front },
					u = SHAPE.ribbonBay,
					v = win,
					lines = P.deco.white,
					reflectance = 0.2,
					lit = k == litFloor,
				}
			)
			Kit.glass(
				m,
				`SideWindow{k}`,
				Vector3.new(x1 - 0.3, top - win, sideA),
				Vector3.new(x1 + 0.12, top, sideB),
				P.window.dark,
				{
					image = City.textures.windowFine,
					faces = { Enum.NormalId.Right },
					u = SHAPE.ribbonBay,
					v = win,
					lines = P.deco.white,
					reflectance = 0.2,
				}
			)
		end
	end
	if not ribbons then
		-- One wall of punched windows over all the upper floors, its top on the roof line so the tiles fall per floor.
		local bays = math.max(2, math.round((frontB - frontA) / SHAPE.punchedBay))
		Kit.punched(
			m,
			"Front",
			Vector3.new(frontA - 1.2, G, zF - 0.06),
			Vector3.new(frontB + 0.5, H, zF + 0.4),
			P.deco.white,
			P.window.dark,
			{ Enum.NormalId.Front },
			(frontB - frontA + 1.7) / bays,
			f,
			litFloor > 0
		)
		Kit.punched(
			m,
			"Side",
			Vector3.new(x1 - 0.4, G, sideA),
			Vector3.new(x1 + 0.06, H, sideB),
			P.deco.white,
			P.window.dark,
			{ Enum.NormalId.Right },
			(sideB - sideA) / math.max(1, math.round((sideB - sideA) / SHAPE.punchedBay)),
			f
		)
	end

	-------------------------------------------------------------------------------------------------------
	-- Bands: the accent band at the foot of the overhang, a pastel eyebrow over every floor but the top, the cornice;
	-- each wraps the drum and carries on down the side street
	-------------------------------------------------------------------------------------------------------
	local sideEnd = cz + sideRun + 1.5
	Kit.band(m, "Canopy", bodyMin, bodyMax, R, corner, G, SHAPE.canopy.thick, SHAPE.canopy.proud, accent, "front")
	local brow = SHAPE.eyebrow
	for k = 1, up - 1 do
		local y = G + k * f - SHAPE.head + brow.thick / 2 + 0.1
		Kit.band(m, `Brow{k}`, bodyMin, bodyMax, R, corner, y, brow.thick, brow.proud, accent, "front")
		-- A hair thinner than the disc, so their tops never meet in one plane.
		Kit.trim(
			m,
			`SideBrow{k}`,
			Vector3.new(x1 - 0.5, y - brow.thick / 2 + 0.02, cz),
			Vector3.new(x1 + brow.proud, y + brow.thick / 2 - 0.02, sideEnd),
			accent
		)
	end
	local cor = SHAPE.cornice
	local corniceY = H - cor.thick / 2 + 0.06 -- its top a hair over the roof, never level with it
	Kit.band(m, "Cornice", bodyMin, bodyMax, R, corner, corniceY, cor.thick, cor.proud, white, "front")
	Kit.trim(
		m,
		"SideCornice",
		Vector3.new(x1 - 0.5, corniceY - cor.thick / 2 + 0.02, cz),
		Vector3.new(x1 + cor.proud, corniceY + cor.thick / 2 - 0.02, zB - 0.3),
		white
	)

	-------------------------------------------------------------------------------------------------------
	-- The fluted pilaster beside the drum: past the roof, a stepped cap, two pastel ribs and a neon one between
	-------------------------------------------------------------------------------------------------------
	local pilTop = H + pil.rise
	local pilFront = zF - pil.proud
	Kit.box(
		m,
		"Pilaster",
		Vector3.new(pxL, G - SHAPE.canopy.thick / 2 - 0.08, pilFront),
		Vector3.new(pxR, pilTop, zF + 0.6),
		white
	)
	Kit.box(
		m,
		"PilasterCap",
		Vector3.new(pxL - 0.4, pilTop, pilFront - 0.4),
		Vector3.new(pxR + 0.4, pilTop + pil.cap, zF + 1.2),
		white
	)
	local pxC = (pxL + pxR) / 2
	for i, dx in { -1, 1 } do
		local rx = pxC + dx * pil.width * 0.28
		Kit.detail(
			m,
			`Rib{i}`,
			Vector3.new(rx - SHAPE.rib / 2, G + 1.2, pilFront - 0.14),
			Vector3.new(rx + SHAPE.rib / 2, pilTop - 1.2, pilFront + 0.05),
			accent
		)
	end
	Kit.neon(
		m,
		"RibNeon",
		Vector3.new(pxC, G + 1.2, pilFront - 0.32),
		Vector3.new(pxC, pilTop - 1.2, pilFront - 0.32),
		pal.neon,
		pal.accent
	)

	-------------------------------------------------------------------------------------------------------
	-- The lighthouse on the drum
	-------------------------------------------------------------------------------------------------------
	-- A squat plinth drum on the corner with a pastel ring, then the slimmer white shaft of the lighthouse proper.
	local dB = 2 * R - SHAPE.towerInset
	local plinthTop = H + SHAPE.plinth
	Kit.column(m, "TowerBase", cx, cz, H - 0.3, plinthTop, dB, white)
	Kit.disc(m, "PlinthRing", cx, cz, plinthTop + SHAPE.ring / 2, dB + 1.2, SHAPE.ring, accent)
	local dS = math.min(dB - SHAPE.shaftNarrow, SHAPE.shaft[crown])
	local shaftTop = plinthTop + SHAPE.ring + SHAPE.shaftRise[crown]
	Kit.column(m, "Shaft", cx, cz, plinthTop + SHAPE.ring - 0.1, shaftTop, dS, white)
	if crown == 1 then
		Kit.column(
			m,
			"GlassBlock",
			cx,
			cz,
			plinthTop + SHAPE.ring + SHAPE.glassBlock,
			shaftTop - 1.6,
			dS + 0.14,
			GLASS_BLOCK,
			"detail"
		)
	else
		Kit.porthole(
			m,
			"Porthole",
			cx,
			plinthTop + SHAPE.ring + SHAPE.shaftRise[2] * 0.5,
			cz - dS / 2,
			2.2,
			P.window.dark,
			accent
		)
	end
	local y = shaftTop
	Kit.disc(m, "Gallery", cx, cz, y + SHAPE.gallery / 2, dS + 3, SHAPE.gallery, white)
	y += SHAPE.gallery
	local dL = dS - 1.4
	if crown == 2 then
		local dT = dS - 1.6
		Kit.column(m, "Stage", cx, cz, y - 0.1, y + SHAPE.stage, dT, white)
		y += SHAPE.stage
		Kit.disc(m, "Gallery2", cx, cz, y + 0.35, dT + 2, 0.7, white)
		y += 0.7
		dL = dT - 1
	end
	local ly0, ly1 = y, y + SHAPE.lantern[crown]
	Kit.column(m, "Lantern", cx, cz, ly0 + 0.02, ly1 - 0.02, dL, LANTERN, "detail")
	local lamp = LAMPS[crown]
	Kit.lit(
		Kit.column(
			m,
			"Lamp",
			cx,
			cz,
			ly0 + 0.5,
			ly1 - 0.6,
			dL * SHAPE.lamp,
			Kit.look(lamp.day, Enum.Material.SmoothPlastic),
			"detail"
		),
		lamp.kind
	)
	local pr = dL / 2 - 0.1
	local np = SHAPE.posts
	for i = 1, np do
		local a = math.pi / np + (i - 1) * 2 * math.pi / np
		Kit.column(m, `Post{i}`, cx + pr * math.cos(a), cz + pr * math.sin(a), ly0, ly1, SHAPE.post, white, "detail")
	end
	local hatD = dL + 2 * SHAPE.hatOver[crown]
	if crown == 1 then
		-- A broad saucer hat, then a pastel dome on a short drum (its lower half inside the drum and the hat, so none of it
		-- shows through the lantern glass) and a ball finial.
		Kit.disc(m, "Hat", cx, cz, ly1 + SHAPE.hat / 2, hatD, SHAPE.hat, white)
		local dD = math.min(SHAPE.dome, dL - 0.6)
		local c = ly1 + dD / 2
		Kit.column(m, "DomeDrum", cx, cz, ly1 + SHAPE.hat - 0.1, c, dD + 0.1, white)
		Kit.ball(m, "Dome", Vector3.new(cx, c, cz), dD, accent, "trim")
		Kit.ball(m, "Finial", Vector3.new(cx, c + dD / 2 + 0.5, cz), 1.2, white)
	else
		Kit.disc(m, "Hat", cx, cz, ly1 + SHAPE.hat / 2, hatD, SHAPE.hat, white)
		local top = ly1 + SHAPE.hat
		Kit.disc(m, "HatTop", cx, cz, top + 0.4, dL - 0.8, 0.8, white)
		top += 0.8
		Kit.spire(m, "Spire", cx, cz, top, SHAPE.spire, 0.7, CHROME, 2, false)
	end

	-- A stair house at the back of the roof.
	Kit.roofBox(m, "Stair", Vector3.new(x0 + 3, H, zB - 9), Vector3.new(x0 + 10, H + 6, zB - 3), white)

	-------------------------------------------------------------------------------------------------------
	-- The café: a sloped awning over the porch, the name on the fascia, the terrace, planters and umbrellas, the wash
	-------------------------------------------------------------------------------------------------------
	local aw = SHAPE.awning
	Kit.wedge(
		m,
		"Awning",
		Vector3.new(x0 + 0.8, G - aw.low, zF - aw.reach),
		Vector3.new(cx - 0.3, G - aw.high, shopFront - 0.05),
		"back",
		accent,
		"trim"
	)
	Kit.detail(
		m,
		"Valance",
		Vector3.new(x0 + 0.8, G - aw.low - aw.valance, zF - aw.reach - 0.05),
		Vector3.new(cx - 0.3, G - aw.low, zF - aw.reach + 0.15),
		accent
	)
	local names = City.signNames.hotels
	Kit.sign(
		m,
		"Sign",
		Vector3.new(x0 + 2.5, G + 0.75, zF - 0.5),
		Vector3.new(pxL - 1.2, G + 3, zF - 0.08),
		Enum.NormalId.Front,
		names[rng:NextInteger(1, #names)],
		P.deco.white,
		pal.text,
		City.districtLooks.beach.font
	)
	Kit.box(
		m,
		"Terrace",
		Vector3.new(-hw + 0.2, 0, -hd + 0.3),
		Vector3.new(hw - 0.2, SHAPE.terraceTop, shopFront + 0.3),
		terrazzo
	)
	for i, side in { -1, 1 } do
		local a, b = side * SHAPE.gate, side * (hw - 1)
		Kit.planter(
			m,
			`Planter{i}`,
			Vector3.new(math.min(a, b), SHAPE.terraceTop, -hd + 0.6),
			Vector3.new(math.max(a, b), SHAPE.terraceTop + SHAPE.planter, -hd + 2),
			white
		)
	end
	local tz = (-hd + 2 + zF - aw.reach) / 2
	for i, at in { -0.5, 0.42 } do
		local color = if i == 1 then pal.accent else P.deco.white
		Kit.umbrella(m, `Umbrella{i}`, at * hw, tz, SHAPE.terraceTop, SHAPE.umbrella, color)
	end
	-- On the cornice ledge in front of the lighthouse, washing its base, gallery and lantern from below.
	Kit.wash(m, "Wash", cx - 0.45 * R, cx + 0.45 * R, cz - R - 0.6, corniceY + cor.thick / 2 + 0.02, pal.wash)
end

local archetype: Types.Archetype = { id = "lighthouse_corner_hotel", build = build }
return archetype
