--!strict
-- T08 sky_court_slab (docs/city/ARCHETYPES.md §5, T08): a broad, thin slab of saturated blue glass, finely gridded
-- in white, with a square sky court punched right through it a little above half way and off to one side. The court
-- is lined in yellow and holds a red spiral stair, a palm, a round spa and a waving yellow wall that glows at night,
-- with sky showing through over it. A white grid of bars stands proud of the glass in big squares; yellow triangle
-- balconies stack at the far end; a column of small square windows runs up beside the court; a red triangle frame
-- stands on the roof with a red light at its tip. The slab floats on round white columns over a glass lobby.
--
-- What makes it itself: the square hole through a blue grid wall, with a palm and a red stair standing in it.
-- Placement, sizes, heights and its budget: Config/CityArchetypes/sky_court_slab.
-- Variants: palette (3: blue glass and white grid, teal glass and lemon grid, steel-blue glass and white grid),
-- crown (1 the red triangle at the court's end of the roof, 2 a bigger one right over the court), rhythm (1 grid
-- squares four floors tall and three balconies, 2 three floors tall and five balconies), mirror (the court left or
-- right).
--
-- Seen in Studio 2026-10-25, day and night (docs/images/city/sky_court_slab-day.jpg, -night.jpg).
-- Preview check: you see sky through the court above its wall from the street; the glass grid
-- runs on unbroken across the four slab pieces round the court (all whole bays and floors); the yellow lining reads
-- as a frame on both faces; the stair, palm and spa read at 70 mph as a red twist and a green burst (the palm is
-- made of parts: if it reads as a toy, the scenery step's mesh palm could replace it); the triangle and its light
-- stay under the crown limit; nothing pokes past the footprint at 110 and 200 wide, 46 and 53 deep.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local City = require(ReplicatedStorage.Shared.Config.City)
local Kit = require(script.Parent.Parent.Parent.Kit)
local Types = require(script.Parent.Parent.Parent.Types)

local P = City.palettes
local KIT = City.kit
local rgb = Color3.fromRGB

local FRONT, BACK = Enum.NormalId.Front, Enum.NormalId.Back

-- The recipe, in studs.
local SHAPE = {
	floor = 12,
	lobby = 16,
	bay = 4, -- the glass grid's bay: the slab's width, the court and its place are whole bays
	tile = { u = 4, v = 6 }, -- the glass overlay's tile: two to a floor, nearly square
	slabSpare = 8, -- the slab is the site's width less this...
	slabWidth = { 96, 152 }, -- ...between these
	frontRoom = 16, -- the slab is the site's depth less this...
	slabDepth = { 28, 34 }, -- ...between these
	back = 2.5,
	court = { 36, 48 }, -- the sky court's side (whole floors and bays): the big one on slabs this wide or more...
	courtWide = 130,
	courtAt = 0.53, -- its floor, share of the height (snapped to whole floors under the roof)
	courtOff = 0.2, -- its centre off the slab's middle, share of the width
	keep = 12, -- the slab keeps at least this much beside the court (whole bays)
	liner = 0.6, -- the court's lining, standing this far out of both faces as a frame
	deck = 0.8, -- the court's floor
	soffit = 1.2,
	wave = { height = 0.55, deep = 3.5, back = 1.5, thick = 0.6 }, -- the waving wall: share of the court's height
	stair = { treads = 8, reach = 4.2, tread = 2.2, thick = 0.5, climb = 0.8, pole = 1, at = 7 },
	palm = { fronds = 6, reach = 6.5, droop = 2.4, height = 0.62, trunk = 1.1, at = 8 },
	spa = 9,
	bar = 1.4, -- the white grid's bars...
	barProud = 1, -- ...standing this far out of the glass
	gridFloors = { 4, 3 }, -- by rhythm: the grid's squares, in floors
	balconies = { 3, 5 }, -- by rhythm: the yellow triangle balconies at the slab's far end
	balcony = { reach = 9, width = 26, thick = 1.6 },
	strip = 5, -- the column of small square windows beside the court
	pilotiEvery = 24,
	piloti = 2,
	canopy = { y = 12.5, thick = 1.4, half = 12, reach = 7 },
	triangle = { 30, 40 }, -- by crown: the roof triangle's base
	triangleBar = 1.8,
}

-- Glass, the proud grid, the court's yellow, the red of the stair and the roof triangle.
local PALETTES = {
	{ glass = rgb(47, 111, 179), grid = P.frame.white, court = rgb(255, 214, 72), red = rgb(211, 48, 43) },
	{ glass = rgb(46, 111, 142), grid = P.deco.lemon, court = rgb(255, 214, 72), red = rgb(211, 48, 43) },
	{ glass = rgb(70, 112, 150), grid = P.frame.white, court = rgb(255, 200, 80), red = rgb(222, 70, 56) },
}

local function build(m: Types.Model)
	local site = m.site
	local variant = site.variant
	local pal = PALETTES[math.clamp(variant.palette, 1, #PALETTES)]
	local rhythm = math.clamp(variant.rhythm, 1, 2)
	local crown = math.clamp(variant.crown, 1, 2)
	local rng = Kit.rng(m)
	local W, D, H = site.width, site.depth, site.height
	local hd = D / 2
	local F = SHAPE.floor
	local white = Kit.look(P.frame.white, Enum.Material.SmoothPlastic)
	local yellow = Kit.look(pal.court, Enum.Material.SmoothPlastic)
	local red = Kit.look(pal.red, Enum.Material.SmoothPlastic)
	local deck = Kit.look(P.deco.terrazzo, Enum.Material.SmoothPlastic)
	local tag = City.signNames.towers[rng:NextInteger(1, #City.signNames.towers)]

	-------------------------------------------------------------------------------------------------------
	-- The slab and the court's place: whole bays across, whole floors down from the roof
	-------------------------------------------------------------------------------------------------------
	local bay = SHAPE.bay
	local sw = bay * math.floor(math.clamp(W - SHAPE.slabSpare, SHAPE.slabWidth[1], SHAPE.slabWidth[2]) / bay)
	local x0, x1 = -sw / 2, sw / 2
	local sd = math.clamp(D - SHAPE.frontRoom, SHAPE.slabDepth[1], SHAPE.slabDepth[2])
	local zB = hd - SHAPE.back
	local zF = zB - sd
	local zc = (zF + zB) / 2
	local v = if sw >= SHAPE.courtWide then SHAPE.court[2] else SHAPE.court[1]
	-- Floors of slab over the court: about courtAt up, at least two, and two floors at least under it.
	local most = math.max(2, math.floor((H - v - SHAPE.lobby - 2 * F) / F))
	local over = math.clamp(math.round((H - v - H * SHAPE.courtAt) / F), 2, most)
	local vy = H - v - F * over
	local offset = bay * math.round(((0.5 + SHAPE.courtOff) * sw - v / 2) / bay)
	offset = math.clamp(offset, SHAPE.keep, sw - v - SHAPE.keep)
	local vl = x0 + offset
	local vr = vl + v

	-- Blue glass with a fine white grid; every piece's top is a floor line, so the grid runs on across the pieces. The
	-- grid wraps the slab's two ends too (only the faces that show: the court's inner faces are under its lining).
	local function slab(name: string, min: Vector3, max: Vector3, ends: { Enum.NormalId })
		local faces = { FRONT, BACK }
		for _, face in ends do
			table.insert(faces, face)
		end
		Kit.glass(m, name, min, max, pal.glass, {
			image = City.textures.windowFine,
			faces = faces,
			u = SHAPE.tile.u,
			v = SHAPE.tile.v,
			lines = P.frame.white,
			reflectance = 0.2,
		})
	end
	local LEFT, RIGHT = Enum.NormalId.Left, Enum.NormalId.Right
	slab("Below", Vector3.new(x0, SHAPE.lobby, zF), Vector3.new(x1, vy, zB), { LEFT, RIGHT })
	slab("Above", Vector3.new(x0, vy + v, zF), Vector3.new(x1, H, zB), { LEFT, RIGHT })
	slab("Left", Vector3.new(x0, vy, zF), Vector3.new(vl, vy + v, zB), { LEFT })
	slab("Right", Vector3.new(vr, vy, zF), Vector3.new(x1, vy + v, zB), { RIGHT })

	-------------------------------------------------------------------------------------------------------
	-- Ground: a glass lobby under the slab, round white columns along its front, a canopy and a name
	-------------------------------------------------------------------------------------------------------
	Kit.glass(
		m,
		"Lobby",
		Vector3.new(x0 + 3, -KIT.bury, zF + 3),
		Vector3.new(x1 - 3, SHAPE.lobby + 0.3, zB - 3),
		rgb(44, 60, 70),
		{
			image = City.textures.windowBold,
			faces = { FRONT },
			u = 6,
			v = SHAPE.lobby + 0.3,
			lines = P.frame.white,
			lit = true,
		}
	)
	local columns = math.floor(sw / SHAPE.pilotiEvery) + 1
	for i = 1, columns do
		local x = x0 + 2 + (sw - 4) * (i - 1) / (columns - 1)
		Kit.column(m, `Piloti{i}`, x, zF + 1.5, -KIT.bury, SHAPE.lobby + 0.05, SHAPE.piloti, white)
	end
	local cn = SHAPE.canopy
	local cx = (x0 + vl) / 2
	Kit.canopy(m, "Canopy", cx - cn.half, cx + cn.half, zF - cn.reach, zF + 3.5, cn.y, cn.thick, white)
	local canopyTop = cn.y + cn.thick
	Kit.sign(
		m,
		"Name",
		Vector3.new(cx - cn.half * 0.75, canopyTop, zF - cn.reach + 0.3),
		Vector3.new(cx + cn.half * 0.75, canopyTop + 2.4, zF - cn.reach + 0.8),
		FRONT,
		tag,
		pal.glass:Lerp(Color3.new(0, 0, 0), 0.4),
		P.frame.white,
		City.districtLooks.downtown.font
	)

	-------------------------------------------------------------------------------------------------------
	-- The sky court: a yellow lining that frames both faces, a waving wall, a red spiral stair, a palm, a spa
	-------------------------------------------------------------------------------------------------------
	local L = SHAPE.liner
	local cz0, cz1 = zF - L, zB + L
	local floorY = vy + SHAPE.deck
	local roofY = vy + v - SHAPE.soffit
	Kit.trim(m, "CourtDeck", Vector3.new(vl, vy, cz0), Vector3.new(vr, floorY, cz1), deck)
	Kit.trim(m, "CourtSoffit", Vector3.new(vl, roofY, cz0), Vector3.new(vr, vy + v, cz1), yellow)
	Kit.trim(m, "CourtSideL", Vector3.new(vl, floorY, cz0), Vector3.new(vl + L, roofY, cz1), yellow)
	Kit.trim(m, "CourtSideR", Vector3.new(vr - L, floorY, cz0), Vector3.new(vr, roofY, cz1), yellow)

	-- The waving wall across the back of the court, three panels zig-zagging: it glows amber at night.
	local wv = SHAPE.wave
	local wallH = wv.height * v
	local wy = floorY + wallH / 2
	local points: { Vector3 } = {}
	for i = 0, 3 do
		local z = if i % 2 == 0 then zB - wv.back else zB - wv.back - wv.deep
		table.insert(points, Vector3.new(vl + L + (v - 2 * L) * i / 3, wy, z))
	end
	for i = 1, 3 do
		local a, b = points[i], points[i + 1]
		local reach = (b - a).Unit * 0.4 -- the panels overlap at their corners
		Kit.lit(Kit.strut(m, `Wave{i}`, a - reach, b + reach, wallH, yellow, "trim", wv.thick), "neonAmber")
	end

	-- The red spiral stair: a pole and eight treads turning an eighth of a turn each.
	local st = SHAPE.stair
	local sx, sz = vl + st.at, zc - 2
	local climb = st.climb * v
	Kit.column(m, "StairPole", sx, sz, floorY, floorY + climb + 3, st.pole, red, "trim")
	for i = 1, st.treads do
		local t = (i - 1) * math.pi / 4
		local ty = floorY + climb * (i - 0.4) / st.treads
		local tip = Vector3.new(sx + st.reach * math.cos(t), ty, sz + st.reach * math.sin(t))
		Kit.strut(m, `Tread{i}`, Vector3.new(sx, ty, sz), tip, st.thick, red, "trim", st.tread)
	end

	-- The palm: a trunk, a crown and six drooping fronds.
	local pm = SHAPE.palm
	local px, pz = vr - pm.at, zc + 3
	local palmTop = floorY + pm.height * v
	Kit.column(
		m,
		"PalmTrunk",
		px,
		pz,
		floorY,
		palmTop,
		pm.trunk,
		Kit.look(rgb(150, 128, 100), Enum.Material.Wood),
		"trim"
	)
	local leaf = Kit.look(P.leaf, Enum.Material.Grass)
	Kit.ball(m, "PalmCrown", Vector3.new(px, palmTop, pz), 2, leaf)
	for i = 1, pm.fronds do
		local t = (i - 0.5) * 2 * math.pi / pm.fronds
		local tip = Vector3.new(px + pm.reach * math.cos(t), palmTop - pm.droop, pz + pm.reach * math.sin(t))
		Kit.strut(m, `Frond{i}`, Vector3.new(px, palmTop, pz), tip, 0.3, leaf, "detail", 1.8)
	end

	-- The round spa between them.
	local spx, spz = (sx + px) / 2, zc - 5
	Kit.disc(m, "SpaRim", spx, spz, floorY + 0.4, SHAPE.spa, 0.8, deck)
	Kit.disc(
		m,
		"Spa",
		spx,
		spz,
		floorY + 0.9,
		SHAPE.spa - 1.6,
		0.3,
		Kit.look(P.water, Enum.Material.Glass, 0.3, 0),
		"detail"
	)

	-------------------------------------------------------------------------------------------------------
	-- The face: a proud grid of bars in big squares, the column of small windows, the triangle balconies
	-------------------------------------------------------------------------------------------------------
	local gridLook = Kit.look(pal.grid, Enum.Material.SmoothPlastic)
	local gb, gp = SHAPE.bar / 2, SHAPE.barProud
	local gridTop = H - 1.3
	for i, x in { x0 + 1.2, (x0 + vl) / 2, x1 - 1.2 } do
		Kit.trim(
			m,
			`GridV{i}`,
			Vector3.new(x - gb, SHAPE.lobby + 0.05, zF - gp - 0.1), -- a hair over the slab's underside
			Vector3.new(x + gb, gridTop, zF + 0.1),
			gridLook
		)
	end
	local n = 0
	local function bar(a: number, b: number, at: number)
		n += 1
		Kit.trim(m, `GridH{n}`, Vector3.new(a, at - gb, zF - gp), Vector3.new(b, at + gb, zF + 0.1), gridLook)
	end
	local step = SHAPE.gridFloors[rhythm] * F
	local y = H - step
	while y >= SHAPE.lobby + F do
		if y > vy - 1 and y < vy + v + 1 then
			bar(x0 - 0.3, vl, y) -- split round the court
			bar(vr, x1 + 0.3, y)
		else
			bar(x0 - 0.3, x1 + 0.3, y)
		end
		y -= step
	end

	local xs = (vr + x1) / 2
	Kit.punched(
		m,
		"Strip",
		Vector3.new(xs - SHAPE.strip / 2, SHAPE.lobby + 0.05, zF - 0.25),
		Vector3.new(xs + SHAPE.strip / 2, gridTop, zF + 0.05),
		P.frame.white,
		P.glass.smoke,
		{ FRONT },
		SHAPE.strip,
		SHAPE.tile.v
	)

	local bl = SHAPE.balcony
	for i = 1, SHAPE.balconies[rhythm] do
		local by = SHAPE.lobby + F * (i + 1) - 0.6
		Kit.prism(
			m,
			`Balcony{i}`,
			Vector3.new(x0 + 1, by, zF - bl.reach),
			Vector3.new(x0 + 1 + bl.width, by + bl.thick, zF + 0.4),
			"bl",
			yellow,
			"trim"
		)
	end

	-------------------------------------------------------------------------------------------------------
	-- The roof: a white cap, two white plant boxes, the red triangle with a light at its tip
	-------------------------------------------------------------------------------------------------------
	Kit.trim(m, "Cap", Vector3.new(x0 - 0.6, H - 1.3, zF - 0.6), Vector3.new(x1 + 0.6, H + 0.06, zB + 0.6), white)
	Kit.roofBox(m, "RoofBox1", Vector3.new(x0 + 6, H + 0.06, zF + 5), Vector3.new(x0 + 20, H + 10, zB - 5), white)
	Kit.roofBox(m, "RoofBox2", Vector3.new(x0 + 26, H + 0.06, zF + 6), Vector3.new(x0 + 38, H + 7, zB - 6), white)
	local tb = SHAPE.triangle[crown]
	local tx = if crown == 1 then x1 - tb / 2 - 4 else (vl + vr) / 2
	local th = tb * math.sqrt(3) / 2
	local tz = zF + 2.5
	local ty0 = H + 1.2
	local t1 = Vector3.new(tx - tb / 2, ty0, tz)
	local t2 = Vector3.new(tx + tb / 2, ty0, tz)
	local t3 = Vector3.new(tx, ty0 + th, tz)
	local tbar = SHAPE.triangleBar
	Kit.strut(m, "TriangleBase", t1, t2, tbar, red, "trim", tbar)
	Kit.strut(m, "TriangleL", t1, t3, tbar, red, "trim", tbar)
	Kit.strut(m, "TriangleR", t2, t3, tbar, red, "trim", tbar)
	Kit.lit(
		Kit.ball(
			m,
			"TriangleLight",
			Vector3.new(tx, ty0 + th + 1.6, tz),
			1.2,
			Kit.look(rgb(150, 40, 36), Enum.Material.SmoothPlastic)
		),
		"beacon"
	)
end

local archetype: Types.Archetype = { id = "sky_court_slab", build = build }
return archetype
