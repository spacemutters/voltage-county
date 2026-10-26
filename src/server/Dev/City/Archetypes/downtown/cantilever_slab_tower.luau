--!strict
-- T13 cantilever_slab_tower (docs/city/ARCHETYPES.md §5, T13): the white honeycomb tower. A slim condo slab whose
-- deep white concrete floor slabs cantilever past the glass on every side, one every floor, with a white column
-- standing at the slab edge every bay, so each face reads as a fine white grid of deep cells with the glass sunk in
-- their shade. The slab edges swell and pull back floor by floor in a slow wave (front and back out of step, the ends
-- following), so the tower's outline ripples up its height. It stands on a glazed lobby held by sculpted hourglass
-- columns, with a round white drop-off canopy and a skylight at its door, and finishes in a thick white cap that
-- overhangs everything below it. Tower glass is blue-green and the concrete stays white: the one white tower downtown.
--
-- What makes it itself: an all-white grid of deep slabs and columns, rippling at its edges, under a thick white cap.
-- Placement, sizes, heights and its budget: Config/CityArchetypes/cantilever_slab_tower.
-- Variants: palette (4 concrete and glass sets: white or warm concrete over sea-green, teal, slate or navy glass), crown
-- (1 a floating cap over a dark reveal with a lit line in it; 2 a pool deck under a glass rail; 3 a white open frame
-- standing on the columns over the roof), rhythm (the slab wave: 1 slow and deep, 2 quick, 3 a stagger of deep and
-- shallow slabs), mirror (the roof's pool, cabana and plant room swap ends).
--
-- Studio pass 2026-10-26 (docs/images/city/cantilever_slab_tower-*.jpg): a column every 9.5 studs and pale
-- mullions read as an office egg-crate, so the columns stand a wide bay apart, the glass has wide dark-framed panes
-- and mirrors little sky, and the wave is deeper so the outline ripples from the corner view; the hourglass columns
-- read as an X brace until their struts were splayed less. At night: one lit run, the lobby, an ice-blue line round
-- every fifth slab, the canopy rim, the crown's line.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local City = require(ReplicatedStorage.Shared.Config.City)
local Kit = require(script.Parent.Parent.Parent.Kit)
local Types = require(script.Parent.Parent.Parent.Types)

local P = City.palettes
local KIT = City.kit
local rgb = Color3.fromRGB

-- The recipe, in studs.
local SHAPE = {
	floor = 12, -- a floor, nominal: fitted so the cap lands on the site's height
	lobby = 18, -- the glazed ground floor under the first slab
	minFloors = 12,
	frontGap = 2.2, -- the cap's front edge keeps this far behind the front line...
	backGap = 1.6, -- ...this far from the back line...
	sideGap = 1.6, -- ...and from the sides
	coreWidth = { 50, 84 }, -- the glass core along the road
	coreMargin = 14, -- from each side of the site to the core, at least (lawns and planters)
	coreDepth = { 24, 40 },
	plateThick = 1.6,
	proud = 4.8, -- a front or back slab edge past the glass, at its shallowest
	ends = 3, -- an end slab edge past the glass, at its shallowest
	-- By rhythm: how far past its shallowest a slab edge swells, and over how many floors the wave rises and falls (2:
	-- every other slab deep, a stagger).
	waves = {
		{ amp = 3.6, period = 8 },
		{ amp = 2.8, period = 4 },
		{ amp = 3, period = 2 },
	},
	endShare = 0.45, -- the ends swell this share of the faces' swell
	-- The columns on the long faces stand about this far apart: wide bays, so the slabs read as long white bands (at
	-- 9.5 the faces read as an office egg-crate).
	bay = 19,
	pane = 9.5, -- a window bay on the glass: wide sliding doors, so the slabs, not mullions, make the lines
	sheen = 0.05, -- the glass mirrors little sky: it stays dark in the slabs' shade
	column = { width = 1.6, depth = 3.6 }, -- out from the glass: inside the shallowest slab edge
	endColumn = { width = 1.5, depth = 2.3 },
	ringEvery = 5, -- an LED line round every fifth slab
	lobbyInset = 3.5, -- the lobby glass stands this far inside the core's faces
	-- Two struts crossing at mid-height, splayed only a little so they read as one waisted column (at 1.5 apart they
	-- read as an X brace); `out` in front of the glass.
	hourglass = { spread = 0.6, thick = 1.9, out = 1.7 },
	caps = { -- by crown: the cap's thickness, its reach past the deepest slab edge, the reveal under it
		{ thick = 3.4, reach = 1, reveal = 2.2 },
		{ thick = 2.4, reach = 0.8, reveal = 0 },
		{ thick = 2.6, reach = 0.8, reveal = 0 },
	},
	frame = { rise = 10, post = 1.5, beam = 1.6 }, -- crown 3
	canopy = { radius = 12.5, y = 10.5, thick = 1.4, oculus = 0.5 },
	post = 1.2,
	paving = 0.35,
	lawn = 0.7,
	planter = { 8, 1.4, 2.4 }, -- width, height, depth
	signHeight = 2.4,
}

-- Concrete (slabs, columns, cap) and glass: white on aqua, warm on teal, white on silver, warm on navy.
local PALETTES = {
	{ concrete = rgb(240, 238, 233), glass = rgb(46, 84, 96) },
	{ concrete = rgb(232, 224, 210), glass = P.glass.teal },
	{ concrete = rgb(244, 243, 239), glass = rgb(72, 92, 106) },
	{ concrete = rgb(236, 230, 220), glass = P.glass.navy },
}

local RAIL = Kit.look(rgb(214, 236, 242), Enum.Material.Glass, 0.1, KIT.railTransparency)

local function build(m: Types.Model)
	local site = m.site
	local variant = site.variant
	local pal = PALETTES[math.clamp(variant.palette, 1, #PALETTES)]
	local rng = Kit.rng(m)
	local W, D, H = site.width, site.depth, site.height
	local hw, hd = W / 2, D / 2
	local crown = math.clamp(variant.crown, 1, #SHAPE.caps)
	local capSpec = SHAPE.caps[crown]
	local wave = SHAPE.waves[math.clamp(variant.rhythm, 1, #SHAPE.waves)]
	local L = SHAPE.lobby
	local t = SHAPE.plateThick

	local concrete = Kit.look(pal.concrete, Enum.Material.SmoothPlastic)
	local paving = Kit.look(P.deco.terrazzo, Enum.Material.SmoothPlastic)
	local lawn = Kit.look(P.leaf, Enum.Material.Grass)
	local lobbyGlass = rgb(44, 60, 70)

	-------------------------------------------------------------------------------------------------------
	-- The wave: how far each slab edge reaches past the glass
	-------------------------------------------------------------------------------------------------------
	local function swell(k: number): number
		if wave.period <= 2 then
			return if k % 2 == 0 then 1 else 0
		end
		return 0.5 - 0.5 * math.cos(2 * math.pi * (k - 1) / wave.period)
	end
	local shift = math.floor(wave.period / 2) -- the back's wave runs half a period behind the front's
	local function front(k: number): number
		return SHAPE.proud + wave.amp * swell(k)
	end
	local function back(k: number): number
		return SHAPE.proud + wave.amp * swell(k + shift)
	end
	local function ends(k: number): number
		return SHAPE.ends + wave.amp * SHAPE.endShare * swell(k)
	end
	local maxP = SHAPE.proud + wave.amp
	local maxE = SHAPE.ends + wave.amp * SHAPE.endShare
	local reach = capSpec.reach

	-------------------------------------------------------------------------------------------------------
	-- The core: as wide as the site allows inside its margins, as deep as the slabs leave room for, at the back
	-------------------------------------------------------------------------------------------------------
	local tx = math.clamp(W - 2 * SHAPE.coreMargin, SHAPE.coreWidth[1], SHAPE.coreWidth[2]) / 2
	tx = math.min(tx, hw - SHAPE.sideGap - maxE - reach)
	local room = D - SHAPE.frontGap - SHAPE.backGap - 2 * (maxP + reach)
	local td = math.min(SHAPE.coreDepth[2], room)
	local zG1 = hd - SHAPE.backGap - maxP - reach
	local zG0 = zG1 - td

	-- Floors: the slabs from the lobby's ceiling up, the cap (and its reveal) on top.
	local Hc = H - capSpec.thick -- the cap's underside
	local Ht = Hc - capSpec.reveal -- the core's top
	local n = math.max(SHAPE.minFloors, math.round((Ht - L) / SHAPE.floor))
	local f = (Ht - L) / n
	local function slabY(k: number): number
		return L + (k - 1) * f
	end

	-------------------------------------------------------------------------------------------------------
	-- The ground: paving, lawns on the wide sides, the lobby, its hourglass columns, the drop-off canopy
	-------------------------------------------------------------------------------------------------------
	local lobbyFront = zG0 + SHAPE.lobbyInset
	Kit.box(m, "Paving", Vector3.new(-hw + 0.5, 0, -hd + 0.5), Vector3.new(hw - 0.5, SHAPE.paving, hd - 0.5), paving)
	local lawnX = tx + maxE + 2
	if hw - 0.5 - lawnX >= 4 then
		for i, sx in { -1, 1 } do
			Kit.box(
				m,
				`Lawn{i}`,
				Vector3.new(sx * lawnX, 0, -hd + 3),
				Vector3.new(sx * (hw - 0.5), SHAPE.lawn, hd - 0.8),
				lawn
			)
		end
	end

	-- The lobby: glass set in under the first slab on the front and sides, glowing warm at night.
	Kit.glass(
		m,
		"Lobby",
		Vector3.new(-tx + SHAPE.lobbyInset, -KIT.bury, lobbyFront),
		Vector3.new(tx - SHAPE.lobbyInset, L + 0.4, zG1 - SHAPE.lobbyInset),
		lobbyGlass,
		{
			image = City.textures.windowBold,
			faces = { Enum.NormalId.Front, Enum.NormalId.Left, Enum.NormalId.Right },
			u = 6,
			v = L,
			lines = pal.concrete,
			lit = true,
		}
	)

	-- The drop-off canopy: a half-round white disc out of the lobby (or a whole one standing free in front of a deep
	-- site's tower), a skylight in it, a lit rim, two posts and the name on top.
	local C = SHAPE.canopy
	local deep = (zG0 - maxP) - -hd >= 2 * C.radius + 4
	local cz = if deep then -hd + 1 + C.radius else lobbyFront
	local R = math.min(C.radius, cz + hd - 0.6)
	local canopyTop = C.y + C.thick
	Kit.disc(m, "Canopy", 0, cz, C.y + C.thick / 2, 2 * R, C.thick, concrete, "trim")
	-- The skylight sits in the canopy's free half (the rest of a half-round canopy is inside the lobby).
	Kit.disc(
		m,
		"Skylight",
		0,
		cz - (if deep then 0 else R * 0.5),
		canopyTop + 0.15,
		2 * R * C.oculus * (if deep then 1 else 0.9),
		0.3,
		Kit.glassLook(pal.glass, 0.25),
		"detail"
	)
	local rim = Kit.disc(m, "CanopyLed", 0, cz, C.y + C.thick / 2, 2 * R + 0.3, 0.4, concrete, "detail")
	Kit.lit(rim, "ledEdge")
	for i, sx in { -1, 1 } do
		Kit.column(m, `Post{i}`, sx * R * 0.55, cz - R * 0.45, -KIT.bury, C.y + 0.1, SHAPE.post, concrete)
	end
	local names = City.signNames.towers
	local signW = math.min(R * 0.6, 8)
	local signZ = cz - R * 0.7
	Kit.sign(
		m,
		"Name",
		Vector3.new(-signW, canopyTop + 0.3, signZ),
		Vector3.new(signW, canopyTop + 0.3 + SHAPE.signHeight, signZ + 0.4),
		Enum.NormalId.Front,
		names[rng:NextInteger(1, #names)],
		rgb(40, 44, 50),
		pal.concrete,
		City.districtLooks.downtown.font
	)

	-- The lobby's sculpted columns: two struts crossing at mid-height, an hourglass, clear of the canopy.
	local hg = SHAPE.hourglass
	local spots: { number } = {}
	local outer = tx - 1.5
	local clear = if deep then 0 else R + 3
	if outer >= clear then
		table.insert(spots, outer)
		local inner = (outer + clear) / 2
		if not deep and inner - clear >= 2 and outer - inner >= 8 then
			table.insert(spots, inner)
		end
	end
	local hz = zG0 - hg.out
	local count = 0
	for _, x in spots do
		for _, sx in { -1, 1 } do
			count += 1
			local cx = sx * x
			Kit.strut(
				m,
				`Hourglass{count}A`,
				Vector3.new(cx - hg.spread, -0.4, hz),
				Vector3.new(cx + hg.spread, L + 0.5, hz),
				hg.thick,
				concrete,
				"trim"
			)
			Kit.strut(
				m,
				`Hourglass{count}B`,
				Vector3.new(cx + hg.spread, -0.4, hz),
				Vector3.new(cx - hg.spread, L + 0.5, hz),
				hg.thick,
				concrete,
				"trim"
			)
		end
	end

	-- A planter each side of the canopy along the front, where there is room.
	local pw, ph, pdp = SHAPE.planter[1], SHAPE.planter[2], SHAPE.planter[3]
	local px = math.max(R + 3, tx * 0.5)
	if px + pw <= hw - 1 then
		for i, sx in { -1, 1 } do
			local xa, xb = sx * px, sx * (px + pw)
			Kit.planter(
				m,
				`Planter{i}`,
				Vector3.new(math.min(xa, xb), SHAPE.paving, -hd + 0.9),
				Vector3.new(math.max(xa, xb), SHAPE.paving + ph, -hd + 0.9 + pdp),
				concrete
			)
		end
	end

	-- A warm wash along the lobby's front, behind the hourglass columns: it lights them and the slab soffits at night.
	Kit.wash(m, "Wash", -tx * 0.8, tx * 0.8, zG0 + 1.5, SHAPE.paving, rgb(255, 214, 170))

	-------------------------------------------------------------------------------------------------------
	-- The core glass, in two runs split inside a slab: one may glow at night
	-------------------------------------------------------------------------------------------------------
	local split = math.clamp(math.round(n * (0.4 + 0.2 * rng:NextNumber())), 2, n - 1)
	local ySplit = slabY(split) + t / 2
	local litRoll = rng:NextNumber()
	-- Dark mullions: pale ones read as a second white grid and turn the slabs' bands into an office egg-crate.
	local lines = pal.glass:Lerp(Color3.new(0, 0, 0), 0.35)
	local function run(name: string, y0: number, y1: number, isLit: boolean)
		Kit.glass(m, name, Vector3.new(-tx, y0, zG0), Vector3.new(tx, y1, zG1), pal.glass, {
			image = City.textures.windowFine,
			u = SHAPE.pane,
			v = f,
			lines = lines,
			lit = isLit,
			reflectance = SHAPE.sheen,
		})
	end
	run("Core", L + 0.2, ySplit, litRoll < 0.35)
	run("CoreUpper", ySplit, Ht, litRoll >= 0.35 and litRoll < 0.7)

	-------------------------------------------------------------------------------------------------------
	-- The slabs, one a floor, their edges riding the wave; an LED line round every fifth
	-------------------------------------------------------------------------------------------------------
	for k = 1, n do
		local y0 = slabY(k)
		local pf, pb, pe = front(k), back(k), ends(k)
		Kit.trim(m, `Slab{k}`, Vector3.new(-tx - pe, y0, zG0 - pf), Vector3.new(tx + pe, y0 + t, zG1 + pb), concrete)
		if k % SHAPE.ringEvery == 0 then
			-- A hair bigger than the slab and sunk in its middle: a lit line round its edge, not a glowing underside.
			Kit.neonStrip(
				m,
				`Ring{k}`,
				Vector3.new(-tx - pe - 0.15, y0 + t / 2 - 0.25, zG0 - pf - 0.15),
				Vector3.new(tx + pe + 0.15, y0 + t / 2 + 0.25, zG1 + pb + 0.15),
				"ledEdge",
				pal.concrete
			)
		end
	end

	-------------------------------------------------------------------------------------------------------
	-- The columns: one a bay on the long faces (the corners included), two on each end, from the first slab up into
	-- the cap
	-------------------------------------------------------------------------------------------------------
	local col, endCol = SHAPE.column, SHAPE.endColumn
	local c0, c1 = slabY(1) + t / 2, Hc + 0.3
	local across = math.max(4, math.round(2 * tx / SHAPE.bay) + 1)
	for i = 1, across do
		local x = -tx + 2 * tx * (i - 1) / (across - 1)
		local a, b = x - col.width / 2, x + col.width / 2
		Kit.trim(m, `ColumnF{i}`, Vector3.new(a, c0, zG0 - col.depth), Vector3.new(b, c1, zG0 + 0.3), concrete)
		Kit.trim(m, `ColumnB{i}`, Vector3.new(a, c0, zG1 - 0.3), Vector3.new(b, c1, zG1 + col.depth), concrete)
	end
	for i, sx in { -1, 1 } do
		for j = 1, 2 do
			local z = zG0 + td * j / 3
			local inner, out = sx * (tx - 0.3), sx * (tx + endCol.depth)
			Kit.trim(
				m,
				`ColumnE{i}{j}`,
				Vector3.new(math.min(inner, out), c0, z - endCol.width / 2),
				Vector3.new(math.max(inner, out), c1, z + endCol.width / 2),
				concrete
			)
		end
	end

	-------------------------------------------------------------------------------------------------------
	-- The cap and the crown
	-------------------------------------------------------------------------------------------------------
	local capX = tx + maxE + reach
	local capZ0, capZ1 = zG0 - maxP - reach, zG1 + maxP + reach
	Kit.trim(m, "Cap", Vector3.new(-capX, Hc, capZ0), Vector3.new(capX, H, capZ1), concrete)
	local zc = (zG0 + zG1) / 2

	if crown == 1 then
		-- The cap floats over a dark reveal set in from the glass, a lit line running round it.
		local inset = 1.2
		Kit.trim(
			m,
			"Reveal",
			Vector3.new(-tx + inset, Ht - 0.3, zG0 + inset),
			Vector3.new(tx - inset, Hc + 0.2, zG1 - inset),
			Kit.glassLook(P.glass.smoke, 0.1)
		)
		Kit.neonStrip(
			m,
			"CrownLine",
			Vector3.new(-tx + inset - 0.15, Ht + capSpec.reveal / 2 - 0.3, zG0 + inset - 0.15),
			Vector3.new(tx - inset + 0.15, Ht + capSpec.reveal / 2 + 0.3, zG1 - inset + 0.15),
			"crown",
			P.glass.smoke
		)
		Kit.roofBox(
			m,
			"Plant",
			Vector3.new(tx * 0.15, H, zc - td * 0.25),
			Vector3.new(tx * 0.55, H + 6, zc + td * 0.25),
			concrete
		)
	elseif crown == 2 then
		-- A pool deck on the cap: a glass rail along its front, the pool at one end, a cabana and umbrellas.
		Kit.detail(
			m,
			"Rail",
			Vector3.new(-capX + 0.3, H, capZ0 + 0.3),
			Vector3.new(capX - 0.3, H + KIT.railHeight, capZ0 + 0.6),
			RAIL
		)
		Kit.pool(m, "SkyPool", Vector3.new(-tx + 2, 0, zG0 + 1), Vector3.new(-tx * 0.1, 0, zc + td * 0.15), H)
		Kit.roofBox(
			m,
			"Cabana",
			Vector3.new(tx * 0.45, H, zc - td * 0.1),
			Vector3.new(tx - 2, H + 7, zG1 - 1),
			concrete
		)
		for i, ux in { tx * 0.12, tx * 0.42 } do
			Kit.umbrella(m, `Umbrella{i}`, ux, zG0 + 3.5, H, 6, if i == 1 then pal.concrete else P.deco.aqua, true)
		end
		Kit.neonStrip(
			m,
			"CrownLine",
			Vector3.new(-capX - 0.1, Hc + 0.4, capZ0 - 0.15),
			Vector3.new(capX + 0.1, Hc + 0.9, capZ0 - 0.05),
			"crown",
			pal.concrete
		)
	else
		-- A white open frame on the corner columns' lines, over a plant room: the grid carried past the roof.
		local fr = SHAPE.frame
		local top = H + fr.rise
		local fx = tx
		for i, corner in { { -1, -1 }, { 1, -1 }, { -1, 1 }, { 1, 1 } } do
			local x = corner[1] * fx
			local z = if corner[2] < 0 then zG0 - col.depth / 2 else zG1 + col.depth / 2
			Kit.trim(
				m,
				`FramePost{i}`,
				Vector3.new(x - fr.post / 2, H - 0.2, z - fr.post / 2),
				Vector3.new(x + fr.post / 2, top - fr.beam + 0.05, z + fr.post / 2),
				concrete
			)
		end
		for i, z in { zG0 - col.depth / 2, zG1 + col.depth / 2 } do
			Kit.trim(
				m,
				`FrameBeam{i}`,
				Vector3.new(-fx - fr.post / 2 - 0.3, top - fr.beam, z - fr.post / 2 - 0.2),
				Vector3.new(fx + fr.post / 2 + 0.3, top, z + fr.post / 2 + 0.2),
				concrete
			)
		end
		Kit.neonStrip(
			m,
			"CrownLine",
			Vector3.new(-fx, top - fr.beam - 0.4, zG0 - col.depth / 2 - fr.post / 2 + 0.1),
			Vector3.new(fx, top - fr.beam - 0.05, zG0 - col.depth / 2 + fr.post / 2 - 0.1),
			"crown",
			pal.concrete
		)
		Kit.roofBox(
			m,
			"Plant",
			Vector3.new(-tx * 0.35, H, zc - td * 0.22),
			Vector3.new(tx * 0.35, H + 6.5, zc + td * 0.22),
			concrete
		)
	end
end

local archetype: Types.Archetype = { id = "cantilever_slab_tower", build = build }
return archetype
