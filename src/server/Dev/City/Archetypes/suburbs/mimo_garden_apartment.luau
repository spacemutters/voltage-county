--!strict
-- R07 mimo_garden_apartment (docs/city/ARCHETYPES.md §7, R07): the 1940s-50s pastel garden apartment of the bay
-- islands, Miami Modern. A three-storey pastel block whose left third stands open on the ground floor as a see-through
-- breezeway to the garden behind, its upper floors carried at the front on white V-struts. A row of three round
-- windows over the breezeway, jalousie window bands with a white eyebrow, cantilevered balconies (or a continuous
-- open catwalk) on iron-style rails, a white stair tower whose front is a breeze-block screen over a dark stairwell
-- (washed in colour at night), a flat white roof slab overhanging three studs with a rounded streamline corner over
-- the breezeway, the building's name in script on the fascia, terrazzo underfoot, a hedge and planters.
--
-- What makes it itself: a pastel three-storey block with a see-through breezeway, a row of round windows and a
-- breeze-block stair screen.
-- Placement, sizes, heights and its budget: Config/CityArchetypes/mimo_garden_apartment.
-- Variants: palette (4 pastels, each with its own neon and wash: mint, salmon, lemon, sky), crown (1 the stair tower
-- under the roof slab, 2 the tower rising through it under a thin cantilevered hood), rhythm (1 two cantilevered
-- balconies, 2 an open catwalk across the front on both upper floors), mirror (breezeway and tower swap ends).
--
-- Previewing: from the street at eye height square on, and from the breezeway's corner. Check you can see through
-- the breezeway to the back, the V-struts meet the slab over them, the screen reads as breeze blocks (a punched
-- Texture on an invisible part over a dark box), the rounded roof corner sits over the breezeway end, the round
-- windows sit clear of the eyebrow. Sign text needs a playtest. At night: the jalousie bands, the lobby and the round
-- windows glow, the sign in its neon, and the wash lights the screen.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local City = require(ReplicatedStorage.Shared.Config.City)
local Kit = require(script.Parent.Parent.Parent.Kit)
local Types = require(script.Parent.Parent.Parent.Types)

local P = City.palettes
local KIT = City.kit
local rgb = Color3.fromRGB

-- The recipe, in studs.
local SHAPE = {
	side = 4, -- the walls from the site's sides (the roof slab overhangs 3)
	yard = { 0.2, 8, 12 },
	depth = { 0.5, 24, 30 },
	ground = 11.5,
	roof = 1.2,
	roofOver = 3,
	roofRadius = 6,
	breezeway = 1 / 3, -- of the width, open on the ground floor
	strut = { diameter = 0.8, spread = 2.4, back = 1.4 },
	tower = { width = 8, out = 2.6, deep = 8, rise = 5.5 }, -- out: the roof slab overhangs its front by 0.4
	screenIn = 0.8, -- the screen's margin inside the tower's front
	port = { diameter = 4.4, at = { 0.22, 0.5, 0.78 } },
	-- Jalousie bands: from the floor, under the next floor. Pastel wall above and below each band keeps the block a
	-- pastel block (at 1.6 and 1.4 the bands covered three quarters of the front and it read as an office).
	band = { sill = 3.2, head = 3.0 },
	brow = { thick = 0.6, proud = 2.4 },
	balcony = { proud = 2.6, half = 6 },
	towerGap = 1, -- the bands stop this far short of the tower
}

-- Body pastel, the stairwell's dark, the sign's neon and the wash.
local PALETTES = {
	{ body = rgb(174, 226, 190), well = rgb(46, 92, 82), neon = "sign", wash = rgb(120, 230, 210) }, -- a softer mint
	{ body = rgb(246, 168, 140), well = rgb(104, 58, 50), neon = "neonPink", wash = rgb(255, 140, 170) },
	{ body = P.deco.lemon, well = rgb(104, 86, 40), neon = "neonAmber", wash = rgb(255, 200, 140) },
	{ body = P.deco.sky, well = rgb(38, 72, 92), neon = "neonBlue", wash = rgb(140, 190, 255) },
}

-- Invented names (never a real building's): script letters on the fascia.
local NAMES = { "Lumen Court", "Volta Gardens", "Coil Court", "Sparkwater" }

local WHITE = P.deco.white
local IRON = rgb(244, 244, 240)
local JALOUSIE = rgb(118, 146, 160) -- louvred glass reads lighter than a picture window
local HEDGE = rgb(58, 106, 56)

local function share(x: number, rule: { number }): number
	return math.clamp(x * rule[1], rule[2], rule[3])
end

local function build(m: Types.Model)
	local site = m.site
	local variant = site.variant
	local pal = PALETTES[math.clamp(variant.palette, 1, #PALETTES)]
	local rng = Kit.rng(m)
	local W, D, H = site.width, site.depth, site.height
	local hw, hd = W / 2, D / 2

	local body = Kit.look(pal.body, Enum.Material.SmoothPlastic)
	local white = Kit.look(WHITE, Enum.Material.SmoothPlastic)
	local glass = P.window.dark
	local front = { Enum.NormalId.Front }

	-- A rail: an invisible part with the punched overlay on `faces` (a top rail over square bars).
	local function rail(name: string, min: Vector3, max: Vector3, faces: { Enum.NormalId })
		local spec = Kit.detail(m, name, min, max, Kit.look(IRON, Enum.Material.Metal, 0, 1))
		local textures: { Types.TextureSpec } = {}
		for _, face in faces do
			table.insert(
				textures,
				{ face = Kit.face(m, face), image = City.textures.punched, u = 1, v = 6, color = IRON }
			)
		end
		spec.textures = textures
	end

	-- A raking column from a to b (a cylinder turned along the line between them).
	local function strut(name: string, a: Vector3, b: Vector3)
		local d = b - a
		local cf = CFrame.lookAt((a + b) / 2, b, Vector3.zAxis) * CFrame.Angles(0, math.pi / 2, 0)
		Kit.oriented(
			m,
			name,
			"cylinder",
			cf,
			Vector3.new(d.Magnitude, SHAPE.strut.diameter, SHAPE.strut.diameter),
			white
		)
	end

	-------------------------------------------------------------------------------------------------------
	-- The plan, drawn with the breezeway on the left and the stair tower on the right (the kit mirrors it)
	-------------------------------------------------------------------------------------------------------
	local X0, X1 = -hw + SHAPE.side, hw - SHAPE.side
	local Wb = X1 - X0
	local zF = -hd + share(D, SHAPE.yard)
	local zB = zF + share(D, SHAPE.depth)
	local G = SHAPE.ground
	local E = H - SHAPE.roof -- the top of the walls (the roof slab's underside)
	local f = (E - G) / 2 -- the two upper floors
	local bwx = X0 + Wb * SHAPE.breezeway -- the breezeway's right edge
	local t = SHAPE.tower
	local tx0, tx1 = X1 - t.width - 1, X1 - 1
	local bandEnd = tx0 - SHAPE.towerGap

	-------------------------------------------------------------------------------------------------------
	-- The block: the ground floor right of the breezeway, the upper floors over the whole width on V-struts
	-------------------------------------------------------------------------------------------------------
	Kit.box(m, "Ground", Vector3.new(bwx, -KIT.bury, zF), Vector3.new(X1, G, zB), body)
	Kit.box(m, "Upper", Vector3.new(X0, G, zF), Vector3.new(X1, E, zB), body)
	Kit.detail(
		m,
		"Breezeway",
		Vector3.new(X0, 0.02, zF - 1),
		Vector3.new(bwx, 0.16, zB + 1),
		Kit.look(P.deco.terrazzo, Enum.Material.SmoothPlastic)
	)
	local sz = zF + SHAPE.strut.back
	local spread = SHAPE.strut.spread
	for i, share_ in { 0.3, 0.72 } do
		local x = X0 + (bwx - X0) * share_
		local foot = Vector3.new(x, 0, sz)
		strut(`Strut{i}L`, foot, Vector3.new(x - spread, G - 0.1, sz))
		strut(`Strut{i}R`, foot, Vector3.new(x + spread, G - 0.1, sz))
	end
	-- The roof slab, its streamline corner over the breezeway end.
	local o = SHAPE.roofOver
	Kit.roundedBox(
		m,
		"Roof",
		Vector3.new(X0 - o, E, zF - o),
		Vector3.new(X1 + o, H, zB + 2),
		SHAPE.roofRadius,
		{ fl = true },
		white
	)

	-------------------------------------------------------------------------------------------------------
	-- The front: round windows over the breezeway, jalousie bands, the eyebrow, the lobby and the name
	-------------------------------------------------------------------------------------------------------
	local port = SHAPE.port
	for i, s in port.at do
		Kit.porthole(m, `Port{i}`, X0 + (bwx - X0) * s, G + f * 0.5, zF, port.diameter, glass, white, "window")
	end
	local band = SHAPE.band
	local jalousie = { image = City.textures.slabLine, faces = front, u = 6, v = 0.7, lines = WHITE, lit = true }
	Kit.glass(
		m,
		"Band2",
		Vector3.new(bwx + 1.2, G + band.sill, zF - 0.12),
		Vector3.new(bandEnd, G + f - band.head, zF + 0.3),
		JALOUSIE,
		jalousie
	)
	Kit.glass(
		m,
		"Band3",
		Vector3.new(X0 + 1.2, G + f + band.sill, zF - 0.12),
		Vector3.new(bandEnd, E - band.head, zF + 0.3),
		JALOUSIE,
		jalousie
	)
	local brow = SHAPE.brow
	Kit.trim(
		m,
		"Brow",
		Vector3.new(X0 - 0.3, G + f - band.head + 0.4, zF - brow.proud),
		Vector3.new(tx0, G + f - band.head + 0.4 + brow.thick, zF + 0.4),
		white
	)
	Kit.glass(m, "Lobby", Vector3.new(bwx + 1.2, 0.4, zF - 0.12), Vector3.new(bandEnd, G - 2.9, zF + 0.3), glass, {
		image = City.textures.windowBold,
		faces = front,
		u = 3,
		v = G - 3.3,
		lines = WHITE,
		lit = true,
	})
	Kit.sign(
		m,
		"Sign",
		Vector3.new(bwx + 1.2, G - 2.6, zF - 0.4),
		Vector3.new(math.min(bwx + 13, bandEnd), G - 0.75, zF - 0.1),
		Enum.NormalId.Front,
		NAMES[rng:NextInteger(1, #NAMES)],
		pal.body,
		WHITE,
		Enum.Font.Fondamento,
		pal.neon
	)
	-- The apartments' door off the breezeway.
	Kit.trim(
		m,
		"Door",
		Vector3.new(bwx - 0.15, 0, zF + 4),
		Vector3.new(bwx + 0.1, 7.6, zF + 7),
		Kit.look(pal.well, Enum.Material.SmoothPlastic)
	)

	-------------------------------------------------------------------------------------------------------
	-- Balconies (rhythm 1) or a continuous catwalk (rhythm 2) on both upper floors
	-------------------------------------------------------------------------------------------------------
	local b = SHAPE.balcony
	local mid = (bwx + bandEnd) / 2
	local bx0 = if variant.rhythm == 2 then bwx + 0.5 else math.max(bwx + 0.5, mid - b.half)
	local bx1 = if variant.rhythm == 2 then bandEnd - 0.3 else math.min(bandEnd - 0.3, mid + b.half)
	for k, y in { G, G + f } do
		Kit.trim(m, `Balcony{k}`, Vector3.new(bx0, y - 0.5, zF - b.proud), Vector3.new(bx1, y + 0.3, zF + 0.4), white)
		rail(
			`Rail{k}`,
			Vector3.new(bx0 + 0.12, y + 0.3, zF - b.proud + 0.1),
			Vector3.new(bx1 - 0.12, y + 3.3, zF - 0.06),
			{ Enum.NormalId.Front, Enum.NormalId.Left, Enum.NormalId.Right }
		)
	end

	-------------------------------------------------------------------------------------------------------
	-- The stair tower: a white frame, a dark stairwell and a breeze-block screen, washed at night
	-------------------------------------------------------------------------------------------------------
	local tall = variant.crown == 2
	local towerTop = if tall then H + t.rise else E
	local tz0 = zF - t.out
	Kit.box(m, "Tower", Vector3.new(tx0, -KIT.bury, tz0), Vector3.new(tx1, towerTop - 0.04, zF + t.deep), white)
	local si = SHAPE.screenIn
	local sy0, sy1 = 1.2, towerTop - (if tall then 2.6 else 1.2)
	Kit.box(
		m,
		"Well",
		Vector3.new(tx0 + si, sy0, tz0 - 0.1),
		Vector3.new(tx1 - si, sy1, tz0 + 1.2),
		Kit.look(pal.well, Enum.Material.SmoothPlastic)
	)
	local screen = Kit.detail(
		m,
		"Screen",
		Vector3.new(tx0 + si, sy0, tz0 - 0.45),
		Vector3.new(tx1 - si, sy1, tz0 - 0.25),
		Kit.look(WHITE, Enum.Material.SmoothPlastic, 0, 1)
	)
	screen.textures = {
		{ face = Enum.NormalId.Front, image = City.textures.punched, u = 1.6, v = 1.6, color = WHITE },
	}
	Kit.wash(m, "Wash", tx0 + si + 0.4, tx1 - si - 0.4, tz0 - 1.1, 0, pal.wash)
	if tall then
		-- A thin hood cantilevered over the tower's top.
		Kit.trim(
			m,
			"Hood",
			Vector3.new(tx0 - 0.8, towerTop, tz0 - 1.4),
			Vector3.new(tx1 + 0.8, towerTop + 0.5, zF + t.deep + 0.6),
			white
		)
	end

	-------------------------------------------------------------------------------------------------------
	-- The ends: windows down both sides
	-------------------------------------------------------------------------------------------------------
	Kit.punched(
		m,
		"EndL",
		Vector3.new(X0 - 0.06, G + 0.2, zF + 1),
		Vector3.new(X0 + 0.4, E - 0.05, zB - 1),
		pal.body,
		glass,
		{ Enum.NormalId.Left },
		5,
		f
	)
	Kit.punched(
		m,
		"EndR",
		Vector3.new(X1 - 0.4, 0.4, zF + t.deep + 1),
		Vector3.new(X1 + 0.06, E - 0.05, zB - 1),
		pal.body,
		glass,
		{ Enum.NormalId.Right },
		5,
		f
	)

	-------------------------------------------------------------------------------------------------------
	-- The lot: a terrazzo walk into the breezeway, a hedge along the front, two planters by the walk
	-------------------------------------------------------------------------------------------------------
	local wc = (X0 + bwx) / 2
	Kit.detail(
		m,
		"Walk",
		Vector3.new(wc - 2, 0.02, -hd + 0.2),
		Vector3.new(wc + 2, 0.14, zF - 1.05),
		Kit.look(P.deco.terrazzo, Enum.Material.SmoothPlastic)
	)
	Kit.trim(
		m,
		"Hedge",
		Vector3.new(bwx + 1, 0, -hd + 1),
		Vector3.new(tx0 - 1, 3, -hd + 2.6),
		Kit.look(HEDGE, Enum.Material.LeafyGrass)
	)
	Kit.planter(m, "PlanterL", Vector3.new(wc - 5, 0, -hd + 1.5), Vector3.new(wc - 2.6, 1.4, -hd + 4), white)
	Kit.planter(m, "PlanterR", Vector3.new(wc + 2.6, 0, -hd + 1.5), Vector3.new(wc + 5, 1.4, -hd + 4), white)
end

local archetype: Types.Archetype = { id = "mimo_garden_apartment", build = build }
return archetype
