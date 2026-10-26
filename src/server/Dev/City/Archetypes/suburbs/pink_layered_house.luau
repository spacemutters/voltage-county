--!strict
-- R04 pink_layered_house (docs/city/ARCHETYPES.md §7, R04): the bayside modern house made of layered walls. Five flat
-- stucco planes stand one behind another across the lot on a pale concrete plinth (raised against floods), each
-- longer, paler and (crown 1) taller than the one in front, from a deep rose at the street to a pale conch shell at the
-- back, all aligned at one end so their other ends step out like a fan of cards. Every wall is capped with a crisp
-- coping a shade paler that throws a shadow line. The front wall is a walled court: a round porthole in it looks onto
-- a lap pool along a white terrazzo court, a glass entry door up a step under a razor canopy. A glass-block band shows
-- over the second wall and slot windows in the ends of the taller walls; behind the last wall the flat-roofed house,
-- its bay side a wall of glass block under a deep cornice. At night a wash lights the front wall and the porthole
-- glows.
--
-- What makes it itself: five flat walls one behind another, each a paler pink and taller than the last, with a round
-- porthole in the front one.
-- Placement, sizes, heights and its budget: Config/CityArchetypes/pink_layered_house.
-- Variants: palette (1 five pinks, 2 the same idea in sea greens), crown (1 the walls rise front to back, 2 they peak
-- at the middle wall), rhythm (1 one porthole, 2 two on a wide enough front wall), mirror (the fan steps left or
-- right).
--
-- Previewing: from the street at eye height, square on and from the open end. Check the walls read as separate planes
-- with a shadow between each (1.2 thick, 3.2 apart) and a crisp coping on each, the colours step from deep to pale
-- without going lavender (push them if the sky light greys them), the porthole and canopy don't touch on the narrowest
-- (21) site, the pool reads through the gap past the front wall's end, the plinth reads as a base and not a kerb. At
-- night: the wash, the porthole, the glass block and the slots.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local City = require(ReplicatedStorage.Shared.Config.City)
local Kit = require(script.Parent.Parent.Parent.Kit)
local Types = require(script.Parent.Parent.Parent.Types)

local P = City.palettes
local KIT = City.kit
local rgb = Color3.fromRGB

-- The recipe, in studs.
local SHAPE = {
	side = 1.5,
	yard = { 0.16, 5, 9 },
	plinth = 0.9, -- the concrete base everything stands on
	plinthProud = 0.35,
	thick = 1.2, -- every wall
	coping = { proud = 0.2, tall = 0.3 },
	court = 8, -- the pool court behind the front wall
	spacing = 3.2, -- between the walls behind it
	house = { 0.36, 10, 18 }, -- the house's depth behind the last wall
	lengths = { 0.52, 0.64, 0.76, 0.88, 1 }, -- each wall's share of the width
	heights = {
		{ 0.5, 0.66, 0.82, 0.92, 1 }, -- crown 1: rising to the back
		{ 0.5, 0.74, 1, 0.86, 0.74 }, -- crown 2: peaking at the middle wall
	},
	houseDrop = 1.8, -- the house's roof under the last wall's top
	pool = 4.2,
	door = { 1.2, 3.8 }, -- from the walls' end
	doorTop = 7.4, -- over the plinth
	canopy = { y = 7.6, thick = 0.35, proud = 2.2 }, -- over the plinth
	porthole = { 0.42, 2.8, 5.2 }, -- share of the front wall's height, clamped
	slot = 1.2, -- the narrowest slot window worth drawing
}

-- Front to back, the house behind, the porthole's night kind and the wash.
local PALETTES = {
	{
		walls = { rgb(200, 58, 82), rgb(222, 98, 118), rgb(238, 140, 152), rgb(246, 178, 184), rgb(250, 212, 208) },
		house = rgb(250, 236, 232),
		glow = "neonPink",
		wash = rgb(255, 110, 170),
	},
	{
		walls = { rgb(36, 132, 118), rgb(62, 160, 142), rgb(104, 188, 168), rgb(150, 212, 192), rgb(198, 234, 220) },
		house = rgb(236, 248, 242),
		glow = "sign",
		wash = rgb(110, 230, 210),
	},
}

local WHITE = rgb(250, 250, 248)
local BLOCK = rgb(214, 230, 236) -- frosted glass block
local PLINTH = rgb(224, 220, 212)
local TERRAZZO = P.deco.terrazzo
local HEDGE = rgb(86, 138, 64) -- darker greens read as black boxes in the game's light

local function share(x: number, rule: { number }): number
	return math.clamp(x * rule[1], rule[2], rule[3])
end

local function build(m: Types.Model)
	local site = m.site
	local variant = site.variant
	local pal = PALETTES[math.clamp(variant.palette, 1, #PALETTES)]
	local rises = SHAPE.heights[math.clamp(variant.crown, 1, 2)]
	local W, D, H = site.width, site.depth, site.height
	local hw, hd = W / 2, D / 2
	local white = Kit.look(WHITE, Enum.Material.SmoothPlastic)
	local front = { Enum.NormalId.Front }
	local base = SHAPE.plinth

	-------------------------------------------------------------------------------------------------------
	-- The five walls, aligned at their left ends (the kit mirrors them), each under a coping, the house behind the
	-- last, all on the plinth
	-------------------------------------------------------------------------------------------------------
	local X0, X1 = -hw + SHAPE.side, hw - SHAPE.side
	local avail = X1 - X0
	local zF = -hd + share(D, SHAPE.yard)
	local t = SHAPE.thick
	local cp = SHAPE.coping
	local len: { number } = {}
	local tall: { number } = {}
	local at: { number } = {} -- each wall's front face
	for k = 1, 5 do
		len[k] = avail * SHAPE.lengths[k]
		tall[k] = H * rises[k]
		at[k] = if k == 1 then zF else zF + t + SHAPE.court + (k - 2) * SHAPE.spacing
		Kit.box(
			m,
			`Wall{k}`,
			Vector3.new(X0, -KIT.bury, at[k]),
			Vector3.new(X0 + len[k], tall[k] - cp.tall + 0.02, at[k] + t),
			Kit.look(pal.walls[k], Enum.Material.SmoothPlastic)
		)
		Kit.trim(
			m,
			`Coping{k}`,
			Vector3.new(X0 - cp.proud, tall[k] - cp.tall, at[k] - cp.proud),
			Vector3.new(X0 + len[k] + cp.proud, tall[k], at[k] + t + cp.proud),
			Kit.look(pal.walls[k]:Lerp(Color3.new(1, 1, 1), 0.3), Enum.Material.SmoothPlastic)
		)
	end
	local zH0 = at[5] + t
	local zH1 = math.min(zH0 + share(D, SHAPE.house), hd - 1.5)
	local roofY = tall[5] - SHAPE.houseDrop
	Kit.box(
		m,
		"Plinth",
		Vector3.new(X0 - SHAPE.plinthProud, -KIT.bury, zF - SHAPE.plinthProud),
		Vector3.new(X1 + SHAPE.plinthProud, base, zH1 + SHAPE.plinthProud),
		Kit.look(PLINTH, Enum.Material.Concrete)
	)
	Kit.box(
		m,
		"House",
		Vector3.new(X0, base - 0.1, zH0),
		Vector3.new(X1, roofY, zH1),
		Kit.look(pal.house, Enum.Material.SmoothPlastic)
	)
	Kit.trim(
		m,
		"Cornice",
		Vector3.new(X0 - 0.4, roofY - 0.6, zH0 + 0.1),
		Vector3.new(X1 + 0.4, roofY + 0.05, zH1 + 0.6),
		white
	)
	-- The bay side: a glass-block wall, lit at night.
	Kit.glass(
		m,
		"BackBlock",
		Vector3.new(X0 + 2, base + 1.2, zH1 - 0.3),
		Vector3.new(X1 - 2, roofY - 2, zH1 + 0.08),
		BLOCK,
		{
			image = City.textures.windowBold,
			faces = { Enum.NormalId.Back },
			u = 0.9,
			v = 0.9,
			lines = WHITE,
			lit = true,
		}
	)

	-------------------------------------------------------------------------------------------------------
	-- The front wall: the porthole(s), the entry door up a step under its canopy, the night wash
	-------------------------------------------------------------------------------------------------------
	local h1, l1 = tall[1], len[1]
	local d = math.clamp(math.min(h1 * SHAPE.porthole[1], l1 - 5.6), SHAPE.porthole[2], SHAPE.porthole[3])
	local glassDark = rgb(30, 50, 62)
	local portholes: { number } = {}
	if variant.rhythm == 2 and l1 >= 16 then
		portholes = { X0 + l1 * 0.48, X0 + l1 * 0.8 }
		d *= 0.8
	else
		portholes = { math.clamp(X0 + l1 * 0.62, X0 + SHAPE.door[2] + 1 + d / 2, X0 + l1 - d / 2 - 0.6) }
	end
	for i, px in portholes do
		Kit.porthole(m, `Porthole{i}`, px, base + (h1 - base) * 0.55, zF, d, glassDark, white, pal.glow)
	end
	Kit.glass(
		m,
		"Door",
		Vector3.new(X0 + SHAPE.door[1], base, zF - 0.1),
		Vector3.new(X0 + SHAPE.door[2], base + SHAPE.doorTop, zF + 0.3),
		glassDark,
		{ lit = true }
	)
	local c = SHAPE.canopy
	Kit.canopy(m, "Canopy", X0 + 0.6, X0 + SHAPE.door[2] + 0.6, zF - c.proud, zF + 0.3, base + c.y, c.thick, white)
	Kit.box(
		m,
		"Step",
		Vector3.new(X0 + SHAPE.door[1] - 0.4, -KIT.bury, zF - SHAPE.plinthProud - 1.4),
		Vector3.new(X0 + SHAPE.door[2] + 0.4, base * 0.5, zF - SHAPE.plinthProud + 0.05),
		Kit.look(PLINTH, Enum.Material.Concrete)
	)
	-- The wash lies on the ground in front of the plinth, past the step.
	local washX0 = X0 + SHAPE.door[2] + 0.8
	if X0 + l1 - 0.6 - washX0 >= 2 then
		Kit.wash(m, "Wash", washX0, X0 + l1 - 0.6, zF - SHAPE.plinthProud - 0.5, 0, pal.wash)
	end

	-------------------------------------------------------------------------------------------------------
	-- The court: terrazzo and a lap pool behind the front wall, reaching past its end
	-------------------------------------------------------------------------------------------------------
	local courtZ0, courtZ1 = zF + t, at[2]
	Kit.detail(
		m,
		"Court",
		Vector3.new(X0, base + 0.02, courtZ0),
		Vector3.new(X0 + len[2], base + 0.12, courtZ1),
		Kit.look(TERRAZZO, Enum.Material.SmoothPlastic)
	)
	local poolZ = courtZ0 + (SHAPE.court - SHAPE.pool) / 2
	local poolEnd = X0 + math.min(avail - 2.4, 32)
	Kit.pool(m, "Pool", Vector3.new(X0 + 1.2, 0, poolZ), Vector3.new(poolEnd, 0, poolZ + SHAPE.pool), base + 0.1)

	-------------------------------------------------------------------------------------------------------
	-- Openings in the walls behind: glass block over the second wall, slots in the taller walls' ends
	-------------------------------------------------------------------------------------------------------
	local blockTop = tall[2] - cp.tall - 0.8
	if blockTop - (tall[1] + 0.6) >= 1.2 then
		Kit.glass(
			m,
			"Block",
			Vector3.new(X0 + 2, tall[1] + 0.6, at[2] - 0.08),
			Vector3.new(X0 + len[1] - 1, blockTop, at[2] + 0.3),
			BLOCK,
			{ image = City.textures.windowBold, faces = front, u = 0.9, v = 0.9, lines = WHITE, lit = true }
		)
	end
	for k = 3, 5 do
		local x0, x1 = X0 + len[k - 1] + 0.6, X0 + len[k] - 0.6
		if x1 - x0 >= SHAPE.slot and k ~= 4 then
			Kit.glass(
				m,
				`Slot{k}`,
				Vector3.new(x0, base + 1.2, at[k] - 0.08),
				Vector3.new(x1, tall[k] - cp.tall - 1.6, at[k] + 0.3),
				glassDark
			)
		end
	end

	-------------------------------------------------------------------------------------------------------
	-- The lot: a white walk to the step, a clipped hedge along the rest of the front
	-------------------------------------------------------------------------------------------------------
	local walkZ1 = zF - SHAPE.plinthProud - 1.45
	if walkZ1 - (-hd + 0.2) > 0.3 then
		Kit.detail(
			m,
			"Walk",
			Vector3.new(X0 + 0.9, 0.02, -hd + 0.2),
			Vector3.new(X0 + SHAPE.door[2] + 0.3, 0.14, walkZ1),
			Kit.look(TERRAZZO, Enum.Material.SmoothPlastic)
		)
	end
	if X1 - (X0 + SHAPE.door[2] + 1.5) >= 3 then
		Kit.trim(
			m,
			"Hedge",
			Vector3.new(X0 + SHAPE.door[2] + 1.5, 0, -hd + 0.8),
			Vector3.new(X1 + 0.5, 2.2, math.min(-hd + 2.4, zF - SHAPE.plinthProud - 0.3)),
			Kit.look(HEDGE, Enum.Material.Grass)
		)
	end
end

local archetype: Types.Archetype = { id = "pink_layered_house", build = build }
return archetype
