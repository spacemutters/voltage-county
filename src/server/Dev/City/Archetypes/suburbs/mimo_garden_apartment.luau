--!strict
-- R07 mimo_garden_apartment (docs/city/ARCHETYPES.md §7, R07): the 1940s-50s pastel garden apartment of the bay
-- islands, Miami Modern. A three-storey pastel block whose left third stands open on the ground floor as a see-through
-- breezeway to the garden behind, its upper floors carried at the front on white V-struts. A row of three round
-- windows over the breezeway, jalousie window bands with a white eyebrow, cantilevered balconies (or a continuous open
-- catwalk) on white rails, a white stair tower whose front is a screen of white fins crossed by bands over a lit
-- stairwell, a flat white roof slab overhanging three studs with a rounded streamline corner over the breezeway, the
-- building's name in script on a board over the lobby, terrazzo underfoot, a hedge and planters.
--
-- What makes it itself: a pastel three-storey block with a see-through breezeway, a row of round windows and a
-- breeze-block stair screen.
-- Placement, sizes, heights and its budget: Config/CityArchetypes/mimo_garden_apartment.
-- Variants: palette (4 pastels, each with its own sign neon and stairwell glass: mint, salmon, lemon, sky), crown (1
-- the stair tower under the roof slab, 2 the tower rising through it under a thin cantilevered hood), rhythm (1 two
-- cantilevered balconies, 2 an open catwalk across the front on both upper floors), mirror (breezeway and tower swap
-- ends).
--
-- Previewing: from the street at eye height square on, and from the breezeway's corner. Check you can see through the
-- breezeway to the back, the V-struts meet the slab over them, the stair screen reads as a white grid with depth (fins
-- 1 proud, bands a little less) over the stairwell glass, the rounded roof corner sits over the breezeway end, the
-- round windows sit clear of the eyebrow. Sign text needs a playtest. At night: the jalousie bands, the lobby, the
-- round windows and the stairwell behind its screen glow, and the sign in its neon.

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
	screenIn = 0.8, -- the stairwell's margin inside the tower's front
	fins = 4, -- the screen's upright fins...
	finProud = 1.0,
	bandEvery = 5.5, -- ...and its cross bands, about this far apart
	bandProud = 0.75,
	port = { diameter = 4.4, at = { 0.22, 0.5, 0.78 } },
	-- Jalousie bands: from the floor, under the next floor. Pastel wall above and below each band keeps the block a
	-- pastel block (at 1.6 and 1.4 the bands covered three quarters of the front and it read as an office).
	band = { sill = 3.2, head = 3.0 },
	run = { length = 15, pier = 3, lit = 0.6 }, -- a run of an apartment's jalousies, the pier between runs
	lobby = 13, -- the lobby's glass from the breezeway (the name board over it)
	brow = { thick = 0.6, proud = 2.4 },
	balcony = { proud = 2.6, half = 6 },
	towerGap = 1, -- the bands stop this far short of the tower
}

-- Body pastel, the stairwell glass, the sign's neon.
local PALETTES = {
	{ body = rgb(174, 226, 190), well = rgb(46, 92, 82), neon = "sign" }, -- a softer mint
	{ body = rgb(246, 168, 140), well = rgb(104, 58, 50), neon = "neonPink" },
	{ body = P.deco.lemon, well = rgb(104, 86, 40), neon = "neonAmber" },
	{ body = P.deco.sky, well = rgb(38, 72, 92), neon = "neonBlue" },
}

-- Invented names (never a real building's): script letters on the board over the lobby.
local NAMES = { "Lumen Court", "Volta Gardens", "Coil Court", "Sparkwater" }

local WHITE = P.deco.white
local IRON = rgb(244, 244, 240)
local JALOUSIE = rgb(118, 146, 160) -- louvred glass reads lighter than a picture window
local HEDGE = rgb(86, 138, 64) -- darker greens read as black boxes in the game's light

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
	for i, at in { 0.3, 0.72 } do
		local x = X0 + (bwx - X0) * at
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
		local glow = if i == 2 then "window" else nil
		Kit.porthole(m, `Port{i}`, X0 + (bwx - X0) * s, G + f * 0.5, zF, port.diameter, glass, white, glow)
	end
	local band = SHAPE.band
	local jalousie = { image = City.textures.slabLine, faces = front, u = 6, v = 0.7, lines = WHITE, lit = true }
	-- A floor's jalousie windows from a0 to a1, in runs about SHAPE.run.length long with pastel piers between them, so
	-- a long front reads as a row of apartments (one unbroken band across 60 studs read as an office in the first
	-- preview). Some apartments are dark at night.
	local lights = Kit.rng(m, 7)
	local function windows(name: string, a0: number, a1: number, y0: number, y1: number)
		local run = SHAPE.run
		local count = math.max(1, math.floor((a1 - a0 + run.pier) / (run.length + run.pier) + 0.5))
		local w = (a1 - a0 - (count - 1) * run.pier) / count
		for k = 1, count do
			local x0 = a0 + (k - 1) * (w + run.pier)
			local options = table.clone(jalousie)
			options.lit = count == 1 or lights:NextNumber() < run.lit
			Kit.glass(
				m,
				`{name}{k}`,
				Vector3.new(x0, y0, zF - 0.12),
				Vector3.new(x0 + w, y1, zF + 0.3),
				JALOUSIE,
				options
			)
		end
	end
	windows("Band2", bwx + 1.2, bandEnd, G + band.sill, G + f - band.head)
	windows("Band3", X0 + 1.2, bandEnd, G + f + band.sill, E - band.head)
	local brow = SHAPE.brow
	-- The eyebrow wraps round the breezeway end, the streamline way.
	Kit.trim(
		m,
		"Brow",
		Vector3.new(X0 - brow.proud, G + f - band.head + 0.4, zF - brow.proud),
		Vector3.new(tx0, G + f - band.head + 0.4 + brow.thick, zF + 0.4),
		white
	)
	Kit.trim(
		m,
		"BrowEnd",
		Vector3.new(X0 - brow.proud, G + f - band.head + 0.4, zF + 0.4),
		Vector3.new(X0 + 0.4, G + f - band.head + 0.4 + brow.thick, zF + 6),
		white
	)
	-- The lobby by the breezeway under the name; the ground-floor apartments' jalousies past it.
	local lobbyEnd = math.min(bwx + SHAPE.lobby, bandEnd)
	Kit.glass(m, "Lobby", Vector3.new(bwx + 1.2, 0.4, zF - 0.12), Vector3.new(lobbyEnd, G - 2.9, zF + 0.3), glass, {
		image = City.textures.windowBold,
		faces = front,
		u = 3,
		v = G - 3.3,
		lines = WHITE,
		lit = true,
	})
	if bandEnd - (lobbyEnd + SHAPE.run.pier) >= 4 then
		windows("Band1", lobbyEnd + SHAPE.run.pier, bandEnd, band.sill, G - band.head)
	end
	Kit.sign(
		m,
		"Sign",
		Vector3.new(bwx + 1.2, G - 2.6, zF - 0.4),
		Vector3.new(lobbyEnd, G - 0.75, zF - 0.1),
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
		Kit.railing(
			m,
			`Rail{k}`,
			Vector3.new(bx0 + 0.12, y + 0.3, zF - b.proud + 0.1),
			Vector3.new(bx1 - 0.12, y + 3.3, zF - 0.06),
			{ Enum.NormalId.Front, Enum.NormalId.Left, Enum.NormalId.Right },
			IRON,
			1
		)
	end

	-------------------------------------------------------------------------------------------------------
	-- The stair tower: a white frame, the stairwell glass, and over it a screen of white fins crossed by bands
	-------------------------------------------------------------------------------------------------------
	local tall = variant.crown == 2
	local towerTop = if tall then H + t.rise else E
	local tz0 = zF - t.out
	Kit.box(m, "Tower", Vector3.new(tx0, -KIT.bury, tz0), Vector3.new(tx1, towerTop - 0.04, zF + t.deep), white)
	local si = SHAPE.screenIn
	local sx0, sx1 = tx0 + si, tx1 - si
	local sy0, sy1 = 1.2, towerTop - (if tall then 2.6 else 1.2)
	Kit.glass(m, "Well", Vector3.new(sx0, sy0, tz0 - 0.1), Vector3.new(sx1, sy1, tz0 + 1.2), pal.well, {
		lit = true,
		reflectance = 0.1,
	})
	for i = 1, SHAPE.fins do
		local x = sx0 + 0.35 + (sx1 - sx0 - 0.7) * (i - 1) / (SHAPE.fins - 1)
		Kit.trim(
			m,
			`Fin{i}`,
			Vector3.new(x - 0.22, sy0 + 0.03, tz0 - 0.1 - SHAPE.finProud),
			Vector3.new(x + 0.22, sy1 - 0.03, tz0 - 0.05),
			white
		)
	end
	local bands = math.max(2, math.floor((sy1 - sy0) / SHAPE.bandEvery))
	local step = (sy1 - sy0) / (bands + 1)
	for k = 1, bands do
		local y = sy0 + k * step
		Kit.trim(
			m,
			`ScreenBand{k}`,
			Vector3.new(sx0, y - 0.22, tz0 - 0.1 - SHAPE.bandProud),
			Vector3.new(sx1, y + 0.22, tz0 - 0.07),
			white
		)
	end
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
		Vector3.new(X0 - 0.06, G + 0.2, zF + 6.4),
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
		Kit.look(HEDGE, Enum.Material.Grass)
	)
	Kit.planter(m, "PlanterL", Vector3.new(wc - 5, 0, -hd + 1.5), Vector3.new(wc - 2.6, 1.4, -hd + 4), white)
	Kit.planter(m, "PlanterR", Vector3.new(wc + 2.6, 0, -hd + 1.5), Vector3.new(wc + 5, 1.4, -hd + 4), white)
end

local archetype: Types.Archetype = { id = "mimo_garden_apartment", build = build }
return archetype
