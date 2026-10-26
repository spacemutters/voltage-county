--!strict
-- R02 coral_rock_cottage (docs/city/ARCHETYPES.md §7, R02): the old coral-rock cottage of the suburbs. A low house of
-- rough tan stone, one and a half storeys under a steep gable of coral-red tiles whose rakes show only a thin tile
-- edge over the stone gables; a front-facing cross gable pushed forward as a bay, with a Palladian window (an arched
-- centre light between two side lights in a white surround) over a wide white-framed window; a porch on white round
-- columns beside it under a tile lean-to on a white beam, wrapping round the side on some copies (a hipped corner
-- over the turn); the door and a lantern in the porch; a stone chimney up the far gable end; a low stone garden wall
-- and a hedge.
--
-- What makes it itself: a low stone cottage of rough tan coral rock under coral-red gables, with a white-columned
-- porch.
-- Placement, sizes, heights and its budget: Config/CityArchetypes/coral_rock_cottage.
-- Variants: palette (3: limestone with green door, sandstone with a wood door, grey stone with a blue door), crown
-- (1 the Palladian window in the cross gable, 2 a triple window under a round oculus), rhythm (1 a front porch, 2 the
-- porch wraps round the side when the plot is wide enough), mirror (bay and chimney left or right).
--
-- Previewing: from the street at eye height and from the porch corner. Check the gable wedges' stone faces cover the
-- tile slopes' ends (only a thin tile edge on each rake: Kit.gableRoof), the cross gable meets the main roof in a
-- clean valley, the porch lean-to tucks under the main eave and its hipped corner (Kit.cornerWedge) sits right on the
-- wrap, the Palladian surround stays inside the gable triangle on the lowest roof. At night: the windows and the
-- Palladian light glow and the porch lantern is warm.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local City = require(ReplicatedStorage.Shared.Config.City)
local Kit = require(script.Parent.Parent.Parent.Kit)
local Types = require(script.Parent.Parent.Parent.Types)

local P = City.palettes
local KIT = City.kit
local rgb = Color3.fromRGB

-- The recipe, in studs.
local SHAPE = {
	side = 1.8,
	yard = { 0.3, 11, 16 }, -- the front garden (the bay and the porch stand in its back part)
	bodyDepth = { 0.36, 15, 19 },
	bodyMax = 30,
	minBody = 20, -- the wrap needs this much house beside it
	walls = 10.5, -- the eaves line
	porch = 6, -- the porch's depth (and the wrap's width); the bay projects as far
	porchFloor = 1.6,
	beam = { 8, 8.9 }, -- the porch beam's underside and top
	porchTop = 10.4, -- the lean-to's high edge, against the wall
	column = 1.1,
	columnGap = 5.2,
	bay = { 0.45, 10, 13 }, -- the cross gable's width: share of the house, clamped
	bayIn = 1.5, -- from the house's end
	overhang = 1.4,
	thick = 0.5,
	crossDrop = 0.6, -- the cross ridge stands this far under the main ridge
	chimney = 2.6, -- over the ridge
}

-- Stone (and its material), tiles, trim and the door.
local PALETTES = {
	{
		rock = rgb(206, 190, 152),
		material = Enum.Material.Limestone,
		tile = rgb(201, 121, 78),
		trim = rgb(250, 248, 242),
		door = rgb(52, 92, 70),
	},
	{
		rock = rgb(209, 190, 151),
		material = Enum.Material.Sandstone,
		tile = rgb(184, 96, 62),
		trim = rgb(250, 248, 242),
		door = rgb(118, 76, 50),
	},
	{
		rock = rgb(194, 186, 162),
		material = Enum.Material.Limestone,
		tile = rgb(196, 108, 72),
		trim = rgb(244, 238, 222),
		door = rgb(64, 92, 112),
	},
}

local HEDGE = rgb(60, 108, 56)
local PAVER = rgb(222, 212, 190)
local LANTERN = rgb(255, 214, 160)

local function share(x: number, rule: { number }): number
	return math.clamp(x * rule[1], rule[2], rule[3])
end

local function build(m: Types.Model)
	local site = m.site
	local variant = site.variant
	local pal = PALETTES[math.clamp(variant.palette, 1, #PALETTES)]
	local W, D, H = site.width, site.depth, site.height
	local hw, hd = W / 2, D / 2

	local rock = Kit.look(pal.rock, pal.material)
	local tile = Kit.look(pal.tile, Enum.Material.ClayRoofTiles)
	local trim = Kit.look(pal.trim, Enum.Material.SmoothPlastic)
	local door = Kit.look(pal.door, Enum.Material.SmoothPlastic)
	local glass = P.window.dark
	local front = { Enum.NormalId.Front }

	-------------------------------------------------------------------------------------------------------
	-- The plan, drawn with the bay and the chimney on the left (the kit mirrors it)
	-------------------------------------------------------------------------------------------------------
	local X0, X1 = -hw + SHAPE.side, hw - SHAPE.side
	local avail = X1 - X0
	local wrap = variant.rhythm == 2 and avail - SHAPE.porch >= SHAPE.minBody
	local Wb = math.min(SHAPE.bodyMax, avail - (if wrap then SHAPE.porch else 0))
	local bx0, bx1 = X0, X0 + Wb
	local zF = -hd + share(D, SHAPE.yard)
	local zB = zF + share(D, SHAPE.bodyDepth)
	local zc = (zF + zB) / 2 -- the main ridge
	local E = SHAPE.walls
	local gw = share(Wb, SHAPE.bay)
	local gx0 = bx0 + SHAPE.bayIn
	local gx1 = gx0 + gw
	local zG = zF - SHAPE.porch -- the bay's front, level with the porch's
	local cx = (gx0 + gx1) / 2

	-------------------------------------------------------------------------------------------------------
	-- The stone house under its main gable, the bay under its cross gable
	-------------------------------------------------------------------------------------------------------
	Kit.box(m, "House", Vector3.new(bx0, -KIT.bury, zF), Vector3.new(bx1, E, zB), rock)
	Kit.gableRoof(
		m,
		"Roof",
		Vector3.new(bx0, E, zF),
		Vector3.new(bx1, H, zB),
		"x",
		SHAPE.overhang,
		SHAPE.thick,
		tile,
		rock
	)
	Kit.box(m, "Bay", Vector3.new(gx0, -KIT.bury, zG), Vector3.new(gx1, E - 0.03, zF + 0.6), rock)
	Kit.gableRoof(
		m,
		"Gable",
		Vector3.new(gx0, E, zG),
		Vector3.new(gx1, H - SHAPE.crossDrop, zc),
		"z",
		0.9,
		SHAPE.thick,
		tile,
		rock
	)

	-- The gable window over a wide white-framed window.
	Kit.trim(m, "BayFrame", Vector3.new(cx - 3.4, 2.2, zG - 0.12), Vector3.new(cx + 3.4, 7.4, zG + 0.2), trim)
	Kit.glass(m, "BayWindow", Vector3.new(cx - 3, 2.6, zG - 0.3), Vector3.new(cx + 3, 7, zG + 0.1), glass, {
		image = City.textures.windowBold,
		faces = front,
		u = 1.5,
		v = 2.2,
		lines = pal.trim,
		lit = true,
	})
	if variant.crown ~= 2 then
		-- Palladian: an arched centre light between two lower side lights, in one white surround.
		local spring = E + 1.25
		Kit.trim(
			m,
			"Surround",
			Vector3.new(cx - 3.2, E - 2.9, zG - 0.12),
			Vector3.new(cx + 3.2, spring, zG + 0.2),
			trim
		)
		Kit.tube(
			m,
			"SurroundHead",
			Vector3.new(cx, spring, zG - 0.1),
			Vector3.new(cx, spring, zG + 0.2),
			3.6,
			trim,
			"trim"
		)
		Kit.archWindow(m, "Palladian", cx - 1.2, cx + 1.2, E - 2.5, spring, zG - 0.12, glass, {
			image = City.textures.windowBold,
			faces = front,
			u = 1.2,
			v = 1.25,
			lines = pal.trim,
			lit = true,
		})
		for i, sx in { -1, 1 } do
			Kit.glass(
				m,
				`SideLight{i}`,
				Vector3.new(cx + sx * 1.6, E - 2.5, zG - 0.3),
				Vector3.new(cx + sx * 3, E + 0.6, zG + 0.1),
				glass,
				{ image = City.textures.windowBold, faces = front, u = 1.4, v = 1.55, lines = pal.trim }
			)
		end
	else
		-- A triple window in one white frame under a round oculus.
		Kit.trim(m, "Surround", Vector3.new(cx - 3, E - 2.8, zG - 0.12), Vector3.new(cx + 3, E + 0.5, zG + 0.2), trim)
		Kit.glass(
			m,
			"Triple",
			Vector3.new(cx - 2.6, E - 2.4, zG - 0.3),
			Vector3.new(cx + 2.6, E + 0.1, zG + 0.1),
			glass,
			{
				image = City.textures.windowBold,
				faces = front,
				u = 5.2 / 3,
				v = 2.5,
				lines = pal.trim,
				lit = true,
			}
		)
		Kit.porthole(m, "Oculus", cx, E + 2.3, zG, 2.2, glass, trim, "window")
	end

	-------------------------------------------------------------------------------------------------------
	-- The porch: a stone floor, white columns, a white beam and a tile lean-to, round the side on a wrap
	-------------------------------------------------------------------------------------------------------
	local px0 = gx1
	local px1 = if wrap then bx1 + SHAPE.porch else bx1
	local zP = zF - SHAPE.porch
	local fl = SHAPE.porchFloor
	local b0, b1 = SHAPE.beam[1], SHAPE.beam[2]
	local top = SHAPE.porchTop
	Kit.box(m, "PorchFloor", Vector3.new(px0, -KIT.bury, zP), Vector3.new(px1, fl, zF), rock)
	local cz = zP + 0.7
	local x0, x1 = px0 + 0.9, px1 - 0.7
	local n = math.clamp(math.floor((x1 - x0) / SHAPE.columnGap + 0.5) + 1, 3, 5)
	for i = 1, n do
		local x = x0 + (x1 - x0) * (i - 1) / (n - 1)
		Kit.column(m, `Column{i}`, x, cz, fl, b0, SHAPE.column, trim)
	end
	Kit.trim(m, "Beam", Vector3.new(px0, b0, zP), Vector3.new(px1, b1, zP + 1.4), trim)
	local over = 0.5 -- the lean-to's eave past the beam
	if wrap then
		Kit.wedge(m, "PorchRoof", Vector3.new(px0, b1, zP - over), Vector3.new(bx1, top, zF), "back", tile)
		Kit.cornerWedge(m, "PorchHip", Vector3.new(bx1, b1, zP - over), Vector3.new(px1 + over, top, zF), "bl", tile)
		local zS = zB - 1.6 -- the wrap's back end
		Kit.box(m, "WrapFloor", Vector3.new(bx1 - 0.3, -KIT.bury, zF), Vector3.new(px1, fl, zS), rock)
		Kit.trim(m, "WrapBeam", Vector3.new(px1 - 1.4, b0, zP + 1.4), Vector3.new(px1, b1, zS), trim)
		Kit.wedge(m, "WrapRoof", Vector3.new(bx1, b1, zF), Vector3.new(px1 + over, top, zS + over), "left", tile)
		local sideCount = math.clamp(math.floor((zS - 0.7 - cz) / SHAPE.columnGap), 1, 3)
		for i = 1, sideCount do
			local z = cz + (zS - 0.7 - cz) * i / sideCount
			Kit.column(m, `WrapColumn{i}`, x1, z, fl, b0, SHAPE.column, trim)
		end
	else
		Kit.wedge(m, "PorchRoof", Vector3.new(px0, b1, zP - over), Vector3.new(px1 + over, top, zF), "back", tile)
		-- A window in the far gable end.
		local wz = (zF + zB) / 2
		Kit.trim(m, "EndFrame", Vector3.new(bx1 - 0.1, 2.4, wz - 1.9), Vector3.new(bx1 + 0.12, 7.2, wz + 1.9), trim)
		Kit.glass(
			m,
			"EndWindow",
			Vector3.new(bx1 - 0.1, 2.8, wz - 1.5),
			Vector3.new(bx1 + 0.3, 6.8, wz + 1.5),
			glass,
			{ image = City.textures.windowBold, faces = { Enum.NormalId.Right }, u = 1.5, v = 2, lines = pal.trim }
		)
	end

	-- The door, a window beside it and the lantern, under the porch.
	local dx = math.clamp(px0 + 3.2, px0 + 2, bx1 - 2)
	Kit.trim(m, "Door", Vector3.new(dx - 1.4, fl, zF - 0.15), Vector3.new(dx + 1.4, fl + 6.2, zF + 0.1), door)
	if bx1 - dx >= 8 then
		local wx = (dx + 1.4 + bx1) / 2
		Kit.trim(m, "WindowFrame", Vector3.new(wx - 1.9, 3, zF - 0.12), Vector3.new(wx + 1.9, 7.6, zF + 0.1), trim)
		Kit.glass(m, "Window", Vector3.new(wx - 1.5, 3.4, zF - 0.3), Vector3.new(wx + 1.5, 7.2, zF + 0.1), glass, {
			image = City.textures.windowBold,
			faces = front,
			u = 1.5,
			v = 1.9,
			lines = pal.trim,
			lit = true,
		})
	end
	local lantern = Kit.detail(
		m,
		"Lantern",
		Vector3.new(dx - 0.35, b0 - 1.1, zP + 2.6),
		Vector3.new(dx + 0.35, b1 - 0.05, zP + 3.3),
		Kit.look(LANTERN, Enum.Material.SmoothPlastic)
	)
	Kit.lit(lantern, "neonAmber") -- warm: a pale kind turns white-hot Neon

	-------------------------------------------------------------------------------------------------------
	-- The chimney up the far gable end
	-------------------------------------------------------------------------------------------------------
	local cTop = H + SHAPE.chimney
	Kit.box(m, "Chimney", Vector3.new(bx0 - 1.4, -KIT.bury, zc - 1.2), Vector3.new(bx0 + 0.8, cTop, zc + 1.2), rock)
	Kit.trim(
		m,
		"ChimneyCap",
		Vector3.new(bx0 - 1.65, cTop, zc - 1.45),
		Vector3.new(bx0 + 1.05, cTop + 0.45, zc + 1.45),
		trim
	)

	-------------------------------------------------------------------------------------------------------
	-- The lot: a stone walk and steps to the porch, a low stone garden wall either side (knee high, so the porch
	-- shows over it from the street), a hedge
	-------------------------------------------------------------------------------------------------------
	Kit.box(m, "Steps", Vector3.new(dx - 1.8, -KIT.bury, zP - 1.4), Vector3.new(dx + 1.8, fl * 0.5, zP + 0.1), rock)
	local paver = Kit.look(PAVER, Enum.Material.Pavement)
	Kit.detail(m, "Walk", Vector3.new(dx - 1.5, 0.02, -hd + 0.2), Vector3.new(dx + 1.5, 0.14, zP - 1.45), paver)
	local wz0, wz1 = -hd + 1, -hd + 2
	if dx - 2.4 - (X0 - 1.2) >= 2 then
		Kit.box(m, "WallL", Vector3.new(X0 - 1.2, -KIT.bury, wz0), Vector3.new(dx - 2.4, 1.8, wz1), rock)
		Kit.trim(
			m,
			"Hedge",
			Vector3.new(X0 - 1, 0, wz1 + 0.05),
			Vector3.new(dx - 2.6, 3.0, wz1 + 1.8),
			Kit.look(HEDGE, Enum.Material.LeafyGrass)
		)
	end
	if X1 + 1.2 - (dx + 2.4) >= 2 then
		Kit.box(m, "WallR", Vector3.new(dx + 2.4, -KIT.bury, wz0), Vector3.new(X1 + 1.2, 1.8, wz1), rock)
	end
end

local archetype: Types.Archetype = { id = "coral_rock_cottage", build = build }
return archetype
