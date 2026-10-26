--!strict
-- R02 coral_rock_cottage (docs/city/ARCHETYPES.md §7, R02): the old coral-rock cottage of the suburbs. A low house of
-- rough tan oolitic stone, one and a half storeys under a steep gable of coral-red barrel tiles whose rakes show only
-- a thin tile edge over the stone gables. A front-facing cross gable pushed forward as a bay carries a Palladian
-- window (an arched centre light between two side lights in one white surround) over a wide white-framed window on a
-- stone sill. Beside it a porch of white Doric columns (each under a square cap) holds up a white entablature and a
-- tile lean-to, wrapping round the side on some copies under a hipped corner; the door, a window and a lantern sit in
-- the porch's shade. A stone chimney climbs the far gable end. At the street, the coral-rock garden wall the suburbs
-- are known for: knee high, with two square gate piers under white caps either side of the walk, a hedge behind.
--
-- What makes it itself: a low stone cottage of rough tan coral rock under coral-red gables, with a white-columned
-- porch.
-- Placement, sizes, heights and its budget: Config/CityArchetypes/coral_rock_cottage.
-- Variants: palette (3: tan limestone with a green door, sandstone with a wood door, grey stone with a blue door),
-- crown (1 the Palladian window in the cross gable, 2 a triple window under a round oculus), rhythm (1 a front porch, 2
-- the porch wraps round the side when the plot is wide enough), mirror (bay and chimney left or right).
--
-- Previewing: from the street at eye height and from the porch corner. Check the gable wedges' stone faces cover the
-- tile slopes' ends (only a thin tile edge on each rake: Kit.gableRoof), the cross gable meets the main roof in a
-- clean valley, the porch lean-to tucks under the main eave and its hipped corner sits right on the wrap, the column
-- caps sit tight under the entablature, the Palladian surround stays inside the gable triangle on the lowest roof, and
-- the gate piers frame the walk. At night: the windows and the Palladian light glow and the porch lantern is warm.

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
	beam = { 8, 8.9 }, -- the entablature's underside and top
	porchTop = 10.4, -- the lean-to's high edge, against the wall
	column = 1.1,
	cap = { size = 1.6, thick = 0.4 }, -- a column's square abacus, tight under the entablature
	columnGap = 5.2,
	columns = { 3, 4 }, -- across the front, at least and at most
	bay = { 0.45, 10, 13 }, -- the cross gable's width: share of the house, clamped
	bayIn = 1.5, -- from the house's end
	overhang = 1.4,
	thick = 0.5,
	crossDrop = 0.6, -- the cross ridge stands this far under the main ridge
	chimney = 2.6, -- over the ridge
	wall = { tall = 1.9, thick = 1.1 }, -- the garden wall
	pier = { size = 2.2, tall = 3.4, cap = 0.45 }, -- its gate piers
	gate = 2.2, -- half the gap between the piers
}

-- Stone (and its material), tiles, trim and the door.
local PALETTES = {
	{
		rock = rgb(236, 206, 162),
		material = Enum.Material.Limestone,
		tile = rgb(201, 121, 78),
		trim = rgb(250, 248, 242),
		door = rgb(52, 92, 70),
	},
	{
		rock = rgb(238, 204, 154),
		material = Enum.Material.Sandstone,
		tile = rgb(184, 96, 62),
		trim = rgb(250, 248, 242),
		door = rgb(118, 76, 50),
	},
	{
		rock = rgb(218, 204, 176),
		material = Enum.Material.Limestone,
		tile = rgb(196, 108, 72),
		trim = rgb(244, 238, 222),
		door = rgb(64, 92, 112),
	},
}

local HEDGE = rgb(86, 138, 64) -- darker greens read as black boxes in the game's light
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
	-- The dressed stone of sills, steps and caps: the same rock, a shade paler and smoother.
	local dressed = Kit.look(pal.rock:Lerp(Color3.new(1, 1, 1), 0.25), Enum.Material.Limestone)
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

	-- The wide window in the bay: a white frame, the glass on it, a dressed-stone sill.
	Kit.trim(m, "BayFrame", Vector3.new(cx - 3.4, 2.2, zG - 0.12), Vector3.new(cx + 3.4, 7.4, zG + 0.2), trim)
	Kit.glass(m, "BayWindow", Vector3.new(cx - 3, 2.6, zG - 0.3), Vector3.new(cx + 3, 7, zG + 0.1), glass, {
		image = City.textures.windowBold,
		faces = front,
		u = 1.5,
		v = 2.2,
		lines = pal.trim,
		lit = true,
	})
	Kit.trim(m, "BaySill", Vector3.new(cx - 3.8, 1.75, zG - 0.75), Vector3.new(cx + 3.8, 2.2, zG + 0.3), dressed)
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
		-- The side lights, a white post of the surround between each and the centre light.
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
		Kit.trim(
			m,
			"PalladianSill",
			Vector3.new(cx - 3.5, E - 3.25, zG - 0.6),
			Vector3.new(cx + 3.5, E - 2.9, zG + 0.2),
			dressed
		)
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
	-- The porch: a stone floor, white Doric columns under square caps, a white entablature and a tile lean-to,
	-- round the side on a wrap
	-------------------------------------------------------------------------------------------------------
	local px0 = gx1
	local px1 = if wrap then bx1 + SHAPE.porch else bx1
	local zP = zF - SHAPE.porch
	local fl = SHAPE.porchFloor
	local b0, b1 = SHAPE.beam[1], SHAPE.beam[2]
	local top = SHAPE.porchTop
	local cap = SHAPE.cap
	Kit.box(m, "PorchFloor", Vector3.new(px0, -KIT.bury, zP), Vector3.new(px1, fl, zF), rock)
	-- A column on the porch floor at (x, z): the shaft and its abacus.
	local function column(name: string, x: number, z: number)
		Kit.column(m, name, x, z, fl, b0 - cap.thick + 0.02, SHAPE.column, trim)
		Kit.trim(
			m,
			name .. "Cap",
			Vector3.new(x - cap.size / 2, b0 - cap.thick, z - cap.size / 2),
			Vector3.new(x + cap.size / 2, b0 - 0.02, z + cap.size / 2),
			trim
		)
	end
	local cz = zP + 0.8
	local x0, x1 = px0 + 0.9, px1 - 0.8
	local n = math.clamp(math.floor((x1 - x0) / SHAPE.columnGap + 0.5) + 1, SHAPE.columns[1], SHAPE.columns[2])
	for i = 1, n do
		column(`Column{i}`, x0 + (x1 - x0) * (i - 1) / (n - 1), cz)
	end
	Kit.trim(m, "Beam", Vector3.new(px0, b0, zP), Vector3.new(px1, b1, zP + 1.6), trim)
	local over = 0.5 -- the lean-to's eave past the beam
	if wrap then
		Kit.wedge(m, "PorchRoof", Vector3.new(px0, b1, zP - over), Vector3.new(bx1, top, zF), "back", tile)
		Kit.cornerWedge(m, "PorchHip", Vector3.new(bx1, b1, zP - over), Vector3.new(px1 + over, top, zF), "bl", tile)
		local zS = zB - 1.6 -- the wrap's back end
		Kit.box(m, "WrapFloor", Vector3.new(bx1 - 0.3, -KIT.bury, zF), Vector3.new(px1, fl, zS), rock)
		Kit.trim(m, "WrapBeam", Vector3.new(px1 - 1.6, b0, zP + 1.6), Vector3.new(px1, b1, zS), trim)
		Kit.wedge(m, "WrapRoof", Vector3.new(bx1, b1, zF), Vector3.new(px1 + over, top, zS + over), "left", tile)
		local sideCount = math.clamp(math.floor((zS - 0.8 - cz) / SHAPE.columnGap), 1, 2)
		for i = 1, sideCount do
			column(`WrapColumn{i}`, x1, cz + (zS - 0.8 - cz) * i / sideCount)
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
	Kit.trim(m, "DoorFrame", Vector3.new(dx - 1.8, fl, zF - 0.1), Vector3.new(dx + 1.8, fl + 6.9, zF + 0.1), trim)
	Kit.trim(m, "Door", Vector3.new(dx - 1.4, fl, zF - 0.25), Vector3.new(dx + 1.4, fl + 6.2, zF + 0.1), door)
	if bx1 - dx >= 8 then
		local wx = (dx + 1.8 + bx1) / 2
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
	-- The lot: stone steps and a walk to the porch; the coral-rock garden wall either side of two capped gate
	-- piers (knee high, so the porch shows over it from the street), a hedge behind it
	-------------------------------------------------------------------------------------------------------
	Kit.box(m, "Steps", Vector3.new(dx - 1.8, -KIT.bury, zP - 1.4), Vector3.new(dx + 1.8, fl * 0.5, zP + 0.1), dressed)
	local paver = Kit.look(PAVER, Enum.Material.Pavement)
	Kit.detail(m, "Walk", Vector3.new(dx - 1.5, 0.02, -hd + 0.2), Vector3.new(dx + 1.5, 0.14, zP - 1.45), paver)
	local gw2 = SHAPE.gate
	local wl = SHAPE.wall
	local pr = SHAPE.pier
	local wz0 = -hd + 1
	local wz1 = wz0 + wl.thick
	local pz = (wz0 + wz1) / 2
	local lx = dx - gw2 - pr.size -- the left pier's outer face
	local rx = dx + gw2 + pr.size -- the right pier's outer face
	local piers = lx - 0.25 >= -hw + 0.2 and rx + 0.25 <= hw - 0.2
	for i, px in (if piers then { dx - gw2 - pr.size / 2, dx + gw2 + pr.size / 2 } else {}) :: { number } do
		Kit.box(
			m,
			`GatePier{i}`,
			Vector3.new(px - pr.size / 2, -KIT.bury, pz - pr.size / 2),
			Vector3.new(px + pr.size / 2, pr.tall, pz + pr.size / 2),
			rock
		)
		Kit.trim(
			m,
			`GatePierCap{i}`,
			Vector3.new(px - pr.size / 2 - 0.25, pr.tall, pz - pr.size / 2 - 0.25),
			Vector3.new(px + pr.size / 2 + 0.25, pr.tall + pr.cap, pz + pr.size / 2 + 0.25),
			trim
		)
	end
	local hedge = Kit.look(HEDGE, Enum.Material.Grass)
	if lx - (-hw + 0.6) >= 2 then
		Kit.box(m, "WallL", Vector3.new(-hw + 0.6, -KIT.bury, wz0), Vector3.new(lx + 0.05, wl.tall, wz1), rock)
		Kit.trim(m, "Hedge", Vector3.new(-hw + 0.8, 0, wz1 + 0.05), Vector3.new(lx - 0.2, 3.0, wz1 + 1.8), hedge)
	end
	if hw - 0.6 - rx >= 2 then
		Kit.box(m, "WallR", Vector3.new(rx - 0.05, -KIT.bury, wz0), Vector3.new(hw - 0.6, wl.tall, wz1), rock)
	end
end

local archetype: Types.Archetype = { id = "coral_rock_cottage", build = build }
return archetype
