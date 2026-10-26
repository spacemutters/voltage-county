--!strict
-- T08 sky_court_slab (docs/city/ARCHETYPES.md §5, T08): a broad, thin slab of saturated blue mirror glass, finely
-- squared like graph paper, with a white supergrid of bars standing proud of it in big squares. One square of the
-- supergrid is missing: a sky court punched right through the slab a little above half way and off to one side. The
-- court is lined in yellow and holds a red spiral stair, a palm, a round spa and a waving yellow wall that glows at
-- night, with sky showing through over it. A solid red gable stands on the roof like a child's drawing of a roof;
-- yellow triangle balconies stack at the far end of the low floors; white balcony bands stripe the back. The slab
-- floats on round white columns over a glass lobby.
--
-- What makes it itself: the square hole through a blue grid wall, with a palm and a red stair standing in it, under a
-- red triangle on the roof.
-- Placement, sizes, heights and its budget: Config/CityArchetypes/sky_court_slab.
-- Variants: palette (3: blue glass and a white supergrid, teal glass and a lemon one, steel-blue glass and white),
-- crown (1 the red gable at the court's end of the roof, 2 a bigger one right over the court), rhythm (1 three
-- balconies every second floor, 2 five, one a floor), mirror (the court left or right).
--
-- Preview check (the Studio step): you see sky through the court above its wall from the street and from the back;
-- the court reads as the one missing square of the white supergrid (its bars frame it on all four sides); the fine
-- glass grid runs on unbroken across the four slab pieces round the court (all whole tiles); the stair, palm and spa
-- read at 70 mph as a red twist and a green burst (the palm is made of parts: if it reads as a toy, the scenery
-- step's mesh palm could replace it); the court glows amber at night and its wash lights the stair and palm; the red
-- gable reads as a solid triangle from the street; nothing pokes past the footprint at 110 and 200 wide, 46, 53 and
-- 70 deep (its landmark's depth).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local City = require(ReplicatedStorage.Shared.Config.City)
local Kit = require(script.Parent.Parent.Parent.Kit)
local Types = require(script.Parent.Parent.Parent.Types)

local P = City.palettes
local KIT = City.kit
local rgb = Color3.fromRGB

local FRONT, BACK = Enum.NormalId.Front, Enum.NormalId.Back
local LEFT, RIGHT = Enum.NormalId.Left, Enum.NormalId.Right

-- The recipe, in studs.
local SHAPE = {
	floor = 12,
	lobby = 16,
	tile = 6, -- the glass grid: square tiles, two to a floor; the slab, the court and its place are whole tiles
	slabSpare = 8, -- the slab is the site's width less this...
	slabWidth = { 96, 160 }, -- ...between these
	frontRoom = 14, -- the slab is the site's depth less this...
	slabDepth = { 28, 36 }, -- ...between these
	back = 4, -- the back face from the back line (the balcony bands reach out behind it)
	court = { 36, 48 }, -- the sky court's side (whole floors and tiles): the big one on slabs this wide or more...
	courtWide = 120,
	courtAt = 0.5, -- its floor, share of the height (snapped to whole floors under the roof)
	courtOff = 0.2, -- its centre off the slab's middle, share of the width
	keep = 12, -- the slab keeps at least this much beside the court
	liner = 0.6, -- the court's lining, standing this far out of both faces
	deck = 0.8, -- the court's floor
	soffit = 1.4,
	wave = { height = 0.55, deep = 3.5, back = 2, thick = 0.8 }, -- the waving wall: share of the court's height
	stair = { treads = 9, reach = 4.6, tread = 2.4, thick = 0.6, climb = 0.8, pole = 1.1, at = 8, landing = 6 },
	palm = { fronds = 6, reach = 7, droop = 2.6, height = 0.66, trunk = 1.2, lean = 1.6, at = 9 },
	spa = 10,
	bar = 1.4, -- the white supergrid's bars...
	barProud = 1, -- ...standing this far out of the glass
	-- By rhythm: the yellow triangle balconies at the slab's far end, low down over the lobby as in the photos (Studio
	-- round 1: thin ones at the top corner read as spikes)...
	balconies = { 3, 5 },
	balconyEvery = { 2, 1 }, -- ...this many floors apart, from the second floor up
	balcony = { reach = 8, width = 32, thick = 2.6 },
	bands = { every = 24, thick = 1.2, reach = 3 }, -- the back's balcony bands
	pilotiEvery = 24,
	piloti = 2.2,
	lobbyInset = 3,
	canopy = { y = 12.5, thick = 1.4, half = 12, reach = 7 },
	gable = { 36, 44 }, -- by crown: the red roof gable's base...
	gableRise = 0.78, -- ...its height, share of the base...
	gableDeep = 14, -- ...and its depth (at most the slab's less 4)
}

-- Glass, the proud supergrid, the court's yellow, the red of the stair and the roof gable.
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
	local hw, hd = W / 2, D / 2
	local F = SHAPE.floor
	local yb = -KIT.bury
	local white = Kit.look(P.frame.white, Enum.Material.SmoothPlastic)
	local yellow = Kit.look(pal.court, Enum.Material.SmoothPlastic)
	local red = Kit.look(pal.red, Enum.Material.SmoothPlastic)
	local deck = Kit.look(P.deco.terrazzo, Enum.Material.SmoothPlastic)
	local tag = City.signNames.towers[rng:NextInteger(1, #City.signNames.towers)]

	-------------------------------------------------------------------------------------------------------
	-- The slab and the court's place: whole tiles across, whole floors down from the roof
	-------------------------------------------------------------------------------------------------------
	local tile = SHAPE.tile
	local sw = tile * math.floor(math.clamp(W - SHAPE.slabSpare, SHAPE.slabWidth[1], SHAPE.slabWidth[2]) / tile)
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
	local offset = tile * math.round(((0.5 + SHAPE.courtOff) * sw - v / 2) / tile)
	offset = math.clamp(offset, SHAPE.keep, sw - v - SHAPE.keep)
	local vl = x0 + offset
	local vr = vl + v

	-- Blue mirror glass squared by a fine grid a little paler than itself; every piece's top is a floor line and its
	-- sides whole tiles from the slab's ends, so the grid runs on across the pieces. It wraps the slab's two ends.
	local lines = pal.glass:Lerp(P.frame.white, 0.5)
	local function slab(name: string, min: Vector3, max: Vector3, ends: { Enum.NormalId })
		local faces = { FRONT, BACK }
		for _, face in ends do
			table.insert(faces, face)
		end
		Kit.glass(m, name, min, max, pal.glass, {
			image = City.textures.windowFine,
			faces = faces,
			u = tile,
			v = tile,
			lines = lines,
			reflectance = 0.2,
		})
	end
	slab("Below", Vector3.new(x0, SHAPE.lobby, zF), Vector3.new(x1, vy, zB), { LEFT, RIGHT })
	slab("Above", Vector3.new(x0, vy + v, zF), Vector3.new(x1, H, zB), { LEFT, RIGHT })
	slab("Left", Vector3.new(x0, vy, zF), Vector3.new(vl, vy + v, zB), { LEFT })
	slab("Right", Vector3.new(vr, vy, zF), Vector3.new(x1, vy + v, zB), { RIGHT })

	-------------------------------------------------------------------------------------------------------
	-- Ground: a lit glass lobby set in under the slab, round white columns along its front, a canopy and a name,
	-- granite paving across the forecourt
	-------------------------------------------------------------------------------------------------------
	local li = SHAPE.lobbyInset
	Kit.glass(
		m,
		"Lobby",
		Vector3.new(x0 + li, yb, zF + li),
		Vector3.new(x1 - li, SHAPE.lobby + 0.3, zB - li),
		rgb(44, 60, 70),
		{
			image = City.textures.windowBold,
			faces = { FRONT, BACK },
			u = 6,
			v = SHAPE.lobby + 1.3,
			lines = P.frame.white,
			lit = true,
		}
	)
	local columns = math.floor(sw / SHAPE.pilotiEvery) + 1
	for i = 1, columns do
		local x = x0 + 2 + (sw - 4) * (i - 1) / (columns - 1)
		Kit.column(m, `Piloti{i}`, x, zF + 1.5, yb, SHAPE.lobby + 0.05, SHAPE.piloti, white)
	end
	local cn = SHAPE.canopy
	local cx = (x0 + vl) / 2
	Kit.canopy(m, "Canopy", cx - cn.half, cx + cn.half, zF - cn.reach, zF + li + 0.5, cn.y, cn.thick, white)
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
	Kit.detail(
		m,
		"Paving",
		Vector3.new(-hw + 1, 0, -hd + 0.5),
		Vector3.new(hw - 1, 0.3, zF + li),
		Kit.look(rgb(206, 200, 190), Enum.Material.Granite)
	)

	-------------------------------------------------------------------------------------------------------
	-- The sky court: a yellow lining that frames both faces, a waving wall that glows, a red spiral stair, a palm, a
	-- spa, and one wash on its deck lighting them at night
	-------------------------------------------------------------------------------------------------------
	local Ln = SHAPE.liner
	local cz0, cz1 = zF - Ln, zB + Ln
	local floorY = vy + SHAPE.deck
	local roofY = vy + v - SHAPE.soffit
	Kit.trim(m, "CourtDeck", Vector3.new(vl, vy, cz0), Vector3.new(vr, floorY, cz1), deck)
	Kit.trim(m, "CourtSoffit", Vector3.new(vl, roofY, cz0), Vector3.new(vr, vy + v, cz1), yellow)
	Kit.trim(m, "CourtSideL", Vector3.new(vl, floorY, cz0), Vector3.new(vl + Ln, roofY, cz1), yellow)
	Kit.trim(m, "CourtSideR", Vector3.new(vr - Ln, floorY, cz0), Vector3.new(vr, roofY, cz1), yellow)

	-- The waving wall across the back of the court, three panels zig-zagging: it glows amber at night.
	local wv = SHAPE.wave
	local wallH = wv.height * v
	local wy = floorY + wallH / 2
	local points: { Vector3 } = {}
	for i = 0, 3 do
		local z = if i % 2 == 0 then zB - wv.back else zB - wv.back - wv.deep
		table.insert(points, Vector3.new(vl + Ln + (v - 2 * Ln) * i / 3, wy, z))
	end
	for i = 1, 3 do
		local a, b = points[i], points[i + 1]
		local reach = (b - a).Unit * 0.4 -- the panels overlap at their corners
		Kit.lit(Kit.strut(m, `Wave{i}`, a - reach, b + reach, wallH, yellow, "trim", wv.thick), "neonAmber")
	end

	-- The red spiral stair: a pole, treads turning an eighth of a turn each, a round landing at the top.
	local st = SHAPE.stair
	local sx, sz = vl + st.at, zc - 2
	local climb = st.climb * v
	Kit.column(m, "StairPole", sx, sz, floorY, floorY + climb + 3.5, st.pole, red, "trim")
	for i = 1, st.treads do
		local t = (i - 1) * math.pi / 4
		local ty = floorY + climb * (i - 0.5) / st.treads
		local tip = Vector3.new(sx + st.reach * math.cos(t), ty, sz + st.reach * math.sin(t))
		Kit.strut(m, `Tread{i}`, Vector3.new(sx, ty, sz), tip, st.thick, red, "trim", st.tread)
	end
	Kit.disc(m, "StairLanding", sx, sz, floorY + climb + 0.3, st.landing, 0.6, red)

	-- The palm: a leaning trunk in two pieces, a head and drooping fronds.
	local pm = SHAPE.palm
	local px, pz = vr - pm.at, zc + 2
	local palmTop = floorY + pm.height * v
	local trunk = Kit.look(rgb(150, 128, 100), Enum.Material.Wood)
	local knee = Vector3.new(px, floorY + (palmTop - floorY) * 0.5, pz)
	local head = Vector3.new(px - pm.lean, palmTop, pz)
	Kit.strut(m, "PalmTrunk1", Vector3.new(px, floorY, pz), knee, pm.trunk, trunk, "trim")
	Kit.strut(m, "PalmTrunk2", knee - Vector3.yAxis * 0.4, head, pm.trunk * 0.85, trunk, "trim")
	local leaf = Kit.look(P.leaf, Enum.Material.Grass)
	Kit.ball(m, "PalmHead", head, 2.2, leaf)
	for i = 1, pm.fronds do
		local t = (i - 0.5) * 2 * math.pi / pm.fronds
		local tip = head + Vector3.new(pm.reach * math.cos(t), -pm.droop, pm.reach * math.sin(t))
		Kit.strut(m, `Frond{i}`, head, tip, 0.3, leaf, "trim", 1.9)
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
	Kit.wash(m, "Wash", vl + 3, vr - 3, zF + 1.2, floorY, rgb(255, 214, 150))

	-------------------------------------------------------------------------------------------------------
	-- The face: the proud supergrid, its squares as big as the court and lined up with it, so the court is the one
	-- square missing; the yellow triangle balconies at the far end of the top floors
	-------------------------------------------------------------------------------------------------------
	local gridLook = Kit.look(pal.grid, Enum.Material.SmoothPlastic)
	local gb, gp = SHAPE.bar / 2, SHAPE.barProud
	local gridTop = H - 1.3
	local verticals = { x0 + gb, x1 - gb }
	for k = -8, 8 do
		local x = vl + k * v
		if x > x0 + 3 and x < x1 - 3 then
			table.insert(verticals, x)
		end
	end
	for i, x in verticals do
		Kit.trim(
			m,
			`GridV{i}`,
			Vector3.new(x - gb, SHAPE.lobby + 0.05, zF - gp - 0.1), -- a hair over the slab's underside
			Vector3.new(x + gb, gridTop, zF + 0.1),
			gridLook
		)
	end
	local nH = 0
	for k = -8, 8 do
		local y = vy + k * v
		if y > SHAPE.lobby + 6 and y < H - 3 then
			nH += 1
			Kit.trim(
				m,
				`GridH{nH}`,
				Vector3.new(x0 - 0.3, y - gb, zF - gp),
				Vector3.new(x1 + 0.3, y + gb, zF + 0.1),
				gridLook
			)
		end
	end

	local bl = SHAPE.balcony
	local reach = math.min(bl.reach, zF + hd - 0.5)
	for i = 1, SHAPE.balconies[rhythm] do
		local by = SHAPE.lobby + F * (1 + (i - 1) * SHAPE.balconyEvery[rhythm]) - 0.4
		if by + bl.thick < H - F then
			Kit.prism(
				m,
				`Balcony{i}`,
				Vector3.new(x0 + 0.5, by, zF - reach),
				Vector3.new(x0 + 0.5 + bl.width, by + bl.thick, zF + 0.4),
				"bl",
				yellow,
				"trim"
			)
		end
	end

	-------------------------------------------------------------------------------------------------------
	-- The back: white balcony bands every second floor, broken round the court
	-------------------------------------------------------------------------------------------------------
	local bd = SHAPE.bands
	local nB = 0
	local function band(a: number, b: number, y: number)
		nB += 1
		Kit.trim(
			m,
			`Band{nB}`,
			Vector3.new(a, y - bd.thick / 2, zB - 0.5),
			Vector3.new(b, y + bd.thick / 2, zB + bd.reach),
			white
		)
	end
	local y = H - F - 0.6
	while y > SHAPE.lobby + F do
		if y > vy - 1 and y < vy + v + 1 then
			band(x0 - 0.4, vl, y) -- broken round the court
			band(vr, x1 + 0.4, y)
		else
			band(x0 - 0.4, x1 + 0.4, y)
		end
		y -= bd.every
	end

	-------------------------------------------------------------------------------------------------------
	-- The roof: a white cap, a white plant box, the solid red gable
	-------------------------------------------------------------------------------------------------------
	Kit.trim(m, "Cap", Vector3.new(x0 - 0.6, H - 1.3, zF - 0.6), Vector3.new(x1 + 0.6, H + 0.06, zB + 0.6), white)
	local tb = SHAPE.gable[crown]
	local tx = if crown == 1 then x1 - tb / 2 - 4 else (vl + vr) / 2
	local th = tb * SHAPE.gableRise
	local gd = math.min(SHAPE.gableDeep, sd - 4)
	local tz0 = zF + 2
	local roof = H + 0.06
	Kit.wedge(m, "GableL", Vector3.new(tx - tb / 2, roof, tz0), Vector3.new(tx, roof + th, tz0 + gd), "right", red)
	Kit.wedge(m, "GableR", Vector3.new(tx, roof, tz0), Vector3.new(tx + tb / 2, roof + th, tz0 + gd), "left", red)
	local bx = if tx > 0 then x0 + 6 else x1 - 22
	Kit.roofBox(m, "RoofBox", Vector3.new(bx, roof, zF + 5), Vector3.new(bx + 16, roof + 9, zB - 5), white)
end

local archetype: Types.Archetype = { id = "sky_court_slab", build = build }
return archetype
