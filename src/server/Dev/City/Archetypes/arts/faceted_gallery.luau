--!strict
-- W02 faceted_gallery (docs/city/ARCHETYPES.md §8, W02): the arts district's contemporary gallery. A metal box of
-- two or three gallery floors floats over a recessed glass lobby; its street face is a quilt of folded aluminium
-- triangles, each square of the grid split on a diagonal into two triangles tilted opposite ways about it, so every
-- facet catches the sky at its own angle and the seams read dark. A few triangles are clear glass into the galleries;
-- a few are recessed light panels that glow in the gallery's colour at night. A deep frame (soffit, cornice and side
-- cladding) stands proud of the facets; long brushed letters on a low plinth name it at the plaza's edge, and a
-- cube balanced on one corner stands in the plaza.
--
-- What makes it itself: a box whose whole front is a quilt of tilted metal triangles, some glowing.
-- Night: the light panels glow (the palette's neon), the glass triangles and the lobby are lit, an LED line runs
-- along the soffit's edge and a wash from the soffit lights the facets.
-- Placement, sizes, heights and its budget: Config/City archetypes.faceted_gallery (also a one-off on Plant Avenue,
-- Config/City landmarks).
-- Variants: palette (4 metals with their light colour: silver and violet, champagne and amber, graphite and cyan,
-- white and pink), crown (1 a roof plant room, 2 a glass roof pavilion under a floating slab), rhythm (1 diagonals
-- alternating cell by cell, a diamond lattice; 2 every diagonal one way, ribbons), mirror.
--
-- Previewing: the facets need the sun across them: photograph from the south-west and south-east too, and check the
-- folds read (two shades per cell) and the seams read dark, not as gaps to the sky. Check the frame stands proud of
-- every facet (no triangle corner pokes past the soffit or the cornice), the light panels sit back and the glass
-- triangles read as glass. At night: no more than two neon colours (the panels' and the soffit's line).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local City = require(ReplicatedStorage.Shared.Config.City)
local Kit = require(script.Parent.Parent.Parent.Kit)
local Types = require(script.Parent.Parent.Parent.Types)

local P = City.palettes
local KIT = City.kit
local rgb = Color3.fromRGB

-- The recipe, in studs.
local SHAPE = {
	plaza = 6, -- the facets' face this far behind the front line
	overhang = 7, -- the lobby glass this far behind the facets: the box floats over a porch
	ground = 16, -- the lobby, double height; the metal box starts here
	sideInset = 1.2,
	bodyDepth = 46, -- at most
	core = 1.5, -- the box's concrete face behind the facets
	backer = 0.9, -- a dark plane this far behind the facets: the seams between them read dark
	cell = 13, -- a square of the grid, about
	cols = { 4, 7 },
	rows = { 2, 3 },
	facet = { thick = 0.5, gap = 0.22, tilt = math.rad(7) },
	glassSet = 0.45, -- glass triangles sit this far back, untilted
	lightSet = 0.85, -- light panels this far back, untilted
	special = 7, -- one triangle in this many is glass, and one a light panel (at least two of each)
	frame = { proud = 1.5, cornice = 1.4, soffit = 1.0, side = 0.6 },
	lobby = { inset = 1.5, door = 8, doorTall = 10 },
	plinth = { share = 0.28, max = 18, tall = 1.4, deep = 1.5, letters = 2.8 },
	cube = { size = 6.2, plinth = 0.6 }, -- the sculpture: a cube balanced on one corner on a low plinth
	pavilion = { back = 10, tall = 8, slab = 0.8, proud = 2 }, -- crown 2
}

type Palette = {
	a: Color3, -- the facets that fold out
	b: Color3, -- the facets that fold in
	light: Color3, -- the light panels by day: a deep, saturated colour, so a recessed panel never reads as sky
	neon: string,
	wash: Color3,
	sculpture: Color3,
}
local PALETTES: { Palette } = {
	{
		a = rgb(198, 203, 207),
		b = rgb(170, 175, 180),
		light = rgb(124, 92, 200),
		neon = "neonViolet",
		wash = rgb(190, 150, 255),
		sculpture = rgb(228, 64, 52),
	},
	{
		a = rgb(214, 198, 166),
		b = rgb(186, 171, 141),
		light = rgb(214, 150, 64),
		neon = "neonAmber",
		wash = rgb(255, 196, 140),
		sculpture = rgb(45, 107, 255),
	},
	{
		a = rgb(120, 126, 132),
		b = rgb(96, 102, 108),
		light = rgb(40, 150, 170),
		neon = "neonCyan",
		wash = rgb(130, 220, 255),
		sculpture = rgb(255, 200, 40),
	},
	{
		a = rgb(238, 238, 234),
		b = rgb(212, 214, 212),
		light = rgb(214, 84, 150),
		neon = "neonPink",
		wash = rgb(255, 140, 200),
		sculpture = rgb(34, 34, 38),
	},
}

local function build(m: Types.Model)
	local site = m.site
	local variant = site.variant
	local pal = PALETTES[math.clamp(variant.palette, 1, #PALETTES)]
	local rng = Kit.rng(m)
	local W, D, H = site.width, site.depth, site.height
	local hw, hd = W / 2, D / 2
	local G = SHAPE.ground
	local fr = SHAPE.frame
	local x0, x1 = -hw + SHAPE.sideInset, hw - SHAPE.sideInset
	local zF = -hd + SHAPE.plaza
	local zC = zF + SHAPE.core
	local zL = zF + SHAPE.overhang
	local zB = math.min(hd - 1, zF + SHAPE.bodyDepth)
	local roof = H - fr.cornice

	local concrete = Kit.look(P.concrete.pale, Enum.Material.Concrete)
	local metalA = Kit.look(pal.a, Enum.Material.Metal, 0.12)
	local metalB = Kit.look(pal.b, Enum.Material.Metal, 0.12)
	local frameLook = Kit.look(pal.a, Enum.Material.Metal, 0.08)
	local dark = Kit.look(P.concrete.dark, Enum.Material.SmoothPlastic)
	local granite = Kit.look(rgb(196, 192, 186), Enum.Material.Granite)

	-------------------------------------------------------------------------------------------------------
	-- The floating box: a concrete core, a deep metal frame round its face, the lobby under it
	-------------------------------------------------------------------------------------------------------
	Kit.box(m, "Core", Vector3.new(x0, G, zC), Vector3.new(x1, roof + 0.05, zB), concrete)
	Kit.trim(
		m,
		"Cornice",
		Vector3.new(x0 - fr.side, roof, zF - fr.proud),
		Vector3.new(x1 + fr.side, H, zB + 0.3),
		frameLook
	)
	Kit.trim(
		m,
		"Soffit",
		Vector3.new(x0 - fr.side, G - fr.soffit, zF - fr.proud),
		Vector3.new(x1 + fr.side, G, zL + 0.5),
		frameLook
	)
	for i, side in { -1, 1 } do
		local outer = if side < 0 then x0 - fr.side else x1 + fr.side
		local inner = if side < 0 then x0 + 0.05 else x1 - 0.05
		Kit.trim(
			m,
			`Cheek{i}`,
			Vector3.new(math.min(outer, inner), G, zF - fr.proud + 0.1),
			Vector3.new(math.max(outer, inner), roof, zB + 0.2),
			frameLook
		)
	end
	Kit.neonStrip(
		m,
		"SoffitLed",
		Vector3.new(x0 - fr.side + 0.3, G - fr.soffit - 0.3, zF - fr.proud + 0.15),
		Vector3.new(x1 + fr.side - 0.3, G - fr.soffit + 0.05, zF - fr.proud + 0.75),
		"ledEdge",
		pal.a
	)

	-- The lobby: lit glass behind the porch, its door in a dark bronze frame, the ground floor's mass behind.
	Kit.box(m, "Ground", Vector3.new(x0, -KIT.bury, zL + 0.4), Vector3.new(x1, G + 0.05, zB - 0.05), concrete)
	local li = SHAPE.lobby
	Kit.glass(
		m,
		"Lobby",
		Vector3.new(x0 + li.inset, 0.2, zL),
		Vector3.new(x1 - li.inset, G - fr.soffit - 0.02, zL + 0.5),
		rgb(44, 60, 70),
		{
			image = City.textures.windowBold,
			faces = { Enum.NormalId.Front },
			u = 6,
			v = G - fr.soffit - 0.22,
			lines = rgb(70, 66, 60),
			lit = true,
		}
	)
	local doorX = x0 + (x1 - x0) * 0.32
	Kit.trim(
		m,
		"DoorFrame",
		Vector3.new(doorX - li.door / 2 - 0.6, 0.2, zL - 0.5),
		Vector3.new(doorX + li.door / 2 + 0.6, li.doorTall + 0.6, zL + 0.1),
		Kit.look(rgb(70, 62, 52), Enum.Material.Metal)
	)
	Kit.box(m, "Plaza", Vector3.new(-hw + 0.3, -0.6, -hd + 0.3), Vector3.new(hw - 0.3, 0.2, zL + 0.6), granite)

	-------------------------------------------------------------------------------------------------------
	-- The skin: a grid of squares, each folded on a diagonal into two tilted triangles
	-------------------------------------------------------------------------------------------------------
	local sx0, sx1 = x0 + 0.1, x1 - 0.1
	local sy0, sy1 = G + 0.15, roof - 0.15
	Kit.detail(m, "Backer", Vector3.new(sx0, G, zF + SHAPE.backer), Vector3.new(sx1, roof, zC + 0.05), dark)
	local cols = math.clamp(math.round((sx1 - sx0) / SHAPE.cell), SHAPE.cols[1], SHAPE.cols[2])
	local rows = math.clamp(math.round((sy1 - sy0) / SHAPE.cell), SHAPE.rows[1], SHAPE.rows[2])
	local cw, ch = (sx1 - sx0) / cols, (sy1 - sy0) / rows

	-- Which cells hold a glass triangle and which a light panel: one of the two halves of a shuffled few.
	local cells: { number } = {}
	for k = 1, cols * rows do
		table.insert(cells, k)
	end
	for k = #cells, 2, -1 do
		local j = rng:NextInteger(1, k)
		cells[k], cells[j] = cells[j], cells[k]
	end
	local count = math.max(2, math.round(2 * cols * rows / SHAPE.special))
	local special: { [number]: { glass: boolean, half: number } } = {}
	for k = 1, math.min(#cells, 2 * count) do
		special[cells[k]] = { glass = k <= count, half = rng:NextInteger(1, 2) }
	end

	local ft = SHAPE.facet
	-- Dark tinted glass, so a glass triangle reads as a window into the gallery and never as a hole to the sky.
	local glass = Kit.glassLook(rgb(38, 54, 64), 0.18)
	local light = Kit.look(pal.light, Enum.Material.SmoothPlastic)
	for row = 1, rows do
		for col = 1, cols do
			local k = (row - 1) * cols + col
			local a0 = sx0 + (col - 1) * cw + ft.gap / 2
			local a1 = sx0 + col * cw - ft.gap / 2
			local b0 = sy0 + (row - 1) * ch + ft.gap / 2
			local b1 = sy0 + row * ch - ft.gap / 2
			local even = (row + col) % 2 == 0
			-- Rhythm 1: the diagonal turns cell by cell (diamonds); 2: always one way (ribbons).
			local rising = if variant.rhythm == 2 then true else even
			local halves: { Kit.TriangleCorner }
			if rising then
				halves = { "x1y0", "x0y1" }
			else
				halves = { "x0y0", "x1y1" }
			end
			local fold = if even then 1 else -1
			for h, corner in halves do
				local name = `Facet{row}_{col}_{h}`
				local spec = special[k]
				if spec and spec.half == h then
					local set = if spec.glass then SHAPE.glassSet else SHAPE.lightSet
					local look = if spec.glass then glass else light
					local part = Kit.triangle(m, name, a0, b0, a1, b1, zF + set, 0.4, corner, look, "detail")
					Kit.lit(part, if spec.glass then "window" else pal.neon)
				else
					local out = if h == 1 then fold else -fold
					local look = if out > 0 then metalA else metalB
					Kit.triangle(m, name, a0, b0, a1, b1, zF, ft.thick, corner, look, "trim", out * ft.tilt)
				end
			end
		end
	end
	Kit.wash(m, "Wash", sx0 + 2, sx1 - 2, zF - 1, G + 0.01, pal.wash)

	-------------------------------------------------------------------------------------------------------
	-- The plaza: long brushed letters on a low plinth, and a cube balanced on one corner
	-------------------------------------------------------------------------------------------------------
	local pl = SHAPE.plinth
	local half = math.min(W * pl.share, pl.max)
	local pz0 = -hd + 1.5
	Kit.box(m, "Plinth", Vector3.new(-half, 0.1, pz0), Vector3.new(half, pl.tall, pz0 + pl.deep), granite)
	local names = City.signNames.arts
	Kit.sign(
		m,
		"Name",
		Vector3.new(-half + 1, pl.tall, pz0 + 0.5),
		Vector3.new(half - 1, pl.tall + pl.letters, pz0 + 0.9),
		Enum.NormalId.Front,
		names[rng:NextInteger(1, #names)],
		pal.a,
		rgb(36, 38, 42),
		Enum.Font.Michroma
	)
	-- The sculpture: a cube balanced on one corner (its long diagonal upright) on a low granite plinth.
	local sculpture = Kit.look(pal.sculpture, Enum.Material.SmoothPlastic)
	local cb = SHAPE.cube
	local reach = cb.size * math.sqrt(3) / 2 -- centre to corner
	local cx, cz = x0 + reach + 1, -hd + reach + 0.4
	Kit.box(
		m,
		"CubePlinth",
		Vector3.new(cx - 2.2, 0.1, cz - 2.2),
		Vector3.new(cx + 2.2, 0.2 + cb.plinth, cz + 2.2),
		granite
	)
	-- Turned so the diagonal from one corner to the opposite one stands upright, then about that diagonal.
	local onCorner = CFrame.Angles(0, math.rad(25), 0) * CFrame.Angles(math.atan(1 / math.sqrt(2)), 0, math.rad(45))
	Kit.oriented(
		m,
		"Cube",
		"block",
		CFrame.new(cx, 0.2 + cb.plinth + reach - 0.15, cz) * onCorner,
		Vector3.one * cb.size,
		sculpture,
		"box"
	)

	-------------------------------------------------------------------------------------------------------
	-- The roof
	-------------------------------------------------------------------------------------------------------
	if variant.crown == 2 then
		-- A glass pavilion set back on the roof under a floating slab on two slender posts.
		local pv = SHAPE.pavilion
		local px0, px1 = x0 + (x1 - x0) * 0.35, x1 - 4
		local pz1 = zB - 3
		local pzf = math.min(zF + pv.back, pz1 - 8)
		Kit.glass(m, "Pavilion", Vector3.new(px0, H, pzf), Vector3.new(px1, H + pv.tall, pz1), rgb(60, 84, 96), {
			image = City.textures.windowBold,
			faces = { Enum.NormalId.Front, Enum.NormalId.Left, Enum.NormalId.Right },
			u = 4,
			v = pv.tall,
			lines = pal.a,
			lit = true,
		})
		Kit.trim(
			m,
			"PavilionRoof",
			Vector3.new(px0 - pv.proud * 2, H + pv.tall, pzf - pv.proud),
			Vector3.new(px1 + 0.5, H + pv.tall + pv.slab, pz1 + 0.5),
			frameLook
		)
		Kit.column(
			m,
			"PavilionPost",
			px0 - pv.proud * 2 + 0.8,
			pzf - pv.proud + 0.8,
			H,
			H + pv.tall,
			0.6,
			frameLook,
			"trim"
		)
	else
		Kit.roofBox(m, "Plant", Vector3.new(x1 - 16, H, zB - 14), Vector3.new(x1 - 4, H + 6, zB - 4), concrete)
	end
end

local archetype: Types.Archetype = { id = "faceted_gallery", build = build }
return archetype
