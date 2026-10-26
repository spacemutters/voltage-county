--!strict
-- C08 lifeguard_stand (docs/city/ARCHETYPES.md §9 C08; docs/city/SCENERY.md §6): the beach's lifeguard towers. A bright
-- little hut lifted on four white legs over the sand, a deck railed toward the sea, a ramp down to the sand behind,
-- a flag, a lit number board, and a roof in one of four shapes, so neighbours never share a silhouette:
--   deco      a rounded sea front wrapped by a ribbon window and a belt, a round roof slab, a fin and a stepped parapet,
--             a porthole that glows amber at night
--   swoop     three tilted roof slabs curving up toward the sea over a wide window, speed lines down the side
--   sunburst  a roof pitched up toward the sea with a fan of fins rising from its edge round a half sun
--   capsule   a round hut under a dome, a wraparound window, a ring cap and a finial
-- What makes it itself: a hut on stilts with a funny roof, in colours no neighbour shares.
--
-- Drawn with the city kit in the stand's own frame (Dev/City/Scenery Piece): x across, y up from the sand, z back from
-- its front, which faces the sea. The legs, deck, hut and ramp are solid (a player can climb up); the rest is decor.
-- Sizes and colour schemes: Config/CityScenery lifeguard. 18 to 25 parts.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CityScenery = require(ReplicatedStorage.Shared.Config.CityScenery)
local Kit = require(script.Parent.Parent.Kit)
local CityTypes = require(script.Parent.Parent.Types)

type Model = CityTypes.Model
type Scheme = CityScenery.StandScheme

local LIFEGUARD = CityScenery.lifeguard
local PALETTE = CityScenery.palette
local KIT = Kit.KIT

-- The recipe, in studs (the deck, platform, hut, legs and ramp come from Config/CityScenery).
local SHAPE = {
	legInset = 0.8, -- legs stand this far in from the platform's corners
	porch = 1.5, -- the hut's front stands this far back from the middle of the platform
	window = { 9.8, 13.6 }, -- the window band's bottom and top
	belt = { 8.6, 9.2 },
	rail = 1.3, -- the deck rail's height
	flag = { pole = 13, width = 2.4, tall = 1.5 },
	sign = Vector2.new(4.4, 1.1),
	rampX = 4.4, -- the ramp runs down behind the deck at this x
	roundAt = 0.5, -- the deco hut's rounded front is centred this far back of the platform's middle
	swoop = { { 4, 3.6 }, { 12, 3.6 }, { 22, 3.6 } }, -- the swoop roof's slabs, back to front: degrees up, length
	rays = { -50, -25, 0, 25, 50 }, -- the sunburst's fins, degrees from upright
}

local LifeguardStand = {}

-- Draws one stand of `shape` (Config/CityScenery lifeguard.shapes) in `scheme`'s colours into `m`, its board showing
-- `number`.
function LifeguardStand.build(m: Model, shape: string, scheme: Scheme, number: number)
	local deck = LIFEGUARD.deck
	local plat = LIFEGUARD.platform
	local hut = LIFEGUARD.hut
	local px, pz = plat.X / 2, plat.Z / 2
	local body = Kit.look(scheme.body, Enum.Material.SmoothPlastic)
	local accent = Kit.look(scheme.accent, Enum.Material.SmoothPlastic)
	local trim = Kit.look(scheme.trim, Enum.Material.SmoothPlastic)
	local white = Kit.look(PALETTE.white, Enum.Material.SmoothPlastic)
	local wood = Kit.look(PALETTE.wood, Enum.Material.WoodPlanks)
	local glass = LIFEGUARD.window
	local hx = hut.X / 2
	local wy0, wy1 = SHAPE.window[1], SHAPE.window[2]

	-- The base: four legs, the deck, its rail toward the sea.
	for i, corner in { { -1, -1 }, { 1, -1 }, { -1, 1 }, { 1, 1 } } do
		local x, z = corner[1] * (px - SHAPE.legInset), corner[2] * (pz - SHAPE.legInset)
		Kit.column(m, `Leg{i}`, x, z, -KIT.bury, deck - plat.Y, LIFEGUARD.legs, white)
	end
	Kit.box(m, "Deck", Vector3.new(-px, deck - plat.Y, -pz), Vector3.new(px, deck, pz), wood)
	Kit.detail(
		m,
		"Rail",
		Vector3.new(-px + 0.1, deck, -pz + 0.05),
		Vector3.new(px - 0.1, deck + SHAPE.rail, -pz + 0.3),
		accent
	)

	-- The ramp down to the sand behind, and its handrail.
	local rise = deck - 0.2
	local run = math.sqrt(math.max(1, LIFEGUARD.ramp.length ^ 2 - rise ^ 2))
	local a = Vector3.new(SHAPE.rampX, deck - 0.17, pz)
	local b = Vector3.new(SHAPE.rampX, 0.03, pz + run)
	Kit.part(
		m,
		"Ramp",
		"block",
		CFrame.lookAt((a + b) / 2, b),
		Vector3.new(LIFEGUARD.ramp.width, 0.35, (b - a).Magnitude),
		wood,
		"box"
	)
	local side = Vector3.new(LIFEGUARD.ramp.width / 2 + 0.1, SHAPE.rail, 0)
	Kit.part(
		m,
		"RampRail",
		"block",
		CFrame.lookAt((a + b) / 2 + side, b + side),
		Vector3.new(0.2, 0.2, (b - a).Magnitude),
		accent,
		"detail"
	)

	-- The flag on the front corner.
	local fx, fz = -px + 0.6, -pz + 0.6
	Kit.column(m, "FlagPole", fx, fz, deck, deck + SHAPE.flag.pole, 0.22, white, "detail")
	local top = deck + SHAPE.flag.pole - 0.3
	Kit.detail(
		m,
		"Flag",
		Vector3.new(fx - 0.04, top - SHAPE.flag.tall, fz + 0.15),
		Vector3.new(fx + 0.04, top, fz + 0.15 + SHAPE.flag.width),
		Kit.look(LIFEGUARD.flag, Enum.Material.SmoothPlastic)
	)

	-- The number board, lit at night.
	local function board(y: number, z: number)
		local w, h = SHAPE.sign.X / 2, SHAPE.sign.Y
		Kit.sign(
			m,
			"Number",
			Vector3.new(-w, y, z - 0.15),
			Vector3.new(w, y + h, z),
			Enum.NormalId.Front,
			tostring(number),
			scheme.trim,
			PALETTE.dark,
			Enum.Font.JosefinSans,
			"sign"
		)
	end

	if shape == "deco" then
		-- A rounded sea front: a box behind a drum as wide as the hut, a ribbon window and a belt wrapping it.
		local c = SHAPE.roundAt
		local back = c + hx + 0.6
		Kit.box(m, "Hut", Vector3.new(-hx, deck, c), Vector3.new(hx, deck + hut.Y, back), body)
		Kit.column(m, "Nose", 0, c, deck + 0.02, deck + hut.Y - 0.02, hut.X, body)
		Kit.column(m, "Window", 0, c, wy0 + 0.4, wy1 - 0.2, hut.X + 0.12, Kit.glassLook(glass, 0.2), "detail")
		Kit.disc(m, "BeltRound", 0, c, (SHAPE.belt[1] + SHAPE.belt[2]) / 2, hut.X + 0.16, 0.6, accent)
		Kit.trim(
			m,
			"Belt",
			Vector3.new(-hx - 0.08, SHAPE.belt[1], c),
			Vector3.new(hx + 0.08, SHAPE.belt[2], back + 0.08),
			accent
		)
		-- A round roof slab overhanging the drum, a fin up the nose and a stepped parapet behind it.
		local roof = deck + hut.Y
		Kit.trim(m, "Roof", Vector3.new(-hx - 0.9, roof, c), Vector3.new(hx + 0.9, roof + 0.6, back + 0.5), white)
		Kit.disc(m, "RoofRound", 0, c, roof + 0.3, hut.X + 1.8, 0.6, white)
		Kit.trim(
			m,
			"Fin",
			Vector3.new(-0.7, roof - 2.5, c - hx - 0.6),
			Vector3.new(0.7, roof + 4.5, c - hx + 0.9),
			accent
		)
		Kit.box(m, "Step1", Vector3.new(-3.2, roof + 0.6, c + 0.5), Vector3.new(3.2, roof + 1.9, c + 2.7), body)
		Kit.box(m, "Step2", Vector3.new(-1.8, roof + 1.9, c + 0.9), Vector3.new(1.8, roof + 3.1, c + 2.3), accent)
		board(roof + 0.75, c + 0.5)
		-- A porthole on the side, glowing amber at night.
		local py, pzz = (wy0 + wy1) / 2, c + 3
		Kit.tube(m, "PortRim", Vector3.new(hx - 0.3, py, pzz), Vector3.new(hx + 0.2, py, pzz), 2.2, trim, "trim")
		local pane = Kit.tube(
			m,
			"Port",
			Vector3.new(hx + 0.15, py, pzz),
			Vector3.new(hx + 0.28, py, pzz),
			1.6,
			Kit.glassLook(glass, 0.25),
			"detail"
		)
		Kit.lit(pane, "neonAmber")
	elseif shape == "capsule" then
		-- A round hut under a dome.
		local c = SHAPE.roundAt + 1
		local d = hut.X - 1
		local roof = deck + hut.Y - 1.1
		Kit.column(m, "Hut", 0, c, deck, roof, d, body)
		Kit.ball(m, "Dome", Vector3.new(0, roof, c), d, accent, "box")
		Kit.column(m, "Window", 0, c, wy0 + 0.2, wy1 - 0.8, d + 0.12, Kit.glassLook(glass, 0.2), "detail")
		Kit.disc(m, "Belt", 0, c, (SHAPE.belt[1] + SHAPE.belt[2]) / 2, d + 0.2, 0.6, accent)
		Kit.disc(m, "Cap", 0, c, roof, d + 0.7, 0.45, trim)
		Kit.ball(m, "Finial", Vector3.new(0, roof + d / 2 + 0.3, c), 0.9, trim)
		Kit.column(m, "Mast", 0, c, roof + d / 2 + 0.6, roof + d / 2 + 2.4, 0.18, white, "detail")
		board(wy1 - 0.6, c - d / 2 - 0.05)
	else
		-- A box hut with a window band toward the sea and a belt round it.
		local front = -SHAPE.porch
		local back = front + hut.Z
		local roof = deck + hut.Y
		Kit.box(m, "Hut", Vector3.new(-hx, deck, front), Vector3.new(hx, roof, back), body)
		-- The window toward the sea: glass in a white frame, split in three by two mullions (a crisp edge round the
		-- dark glass, not a flat dark panel).
		Kit.trim(
			m,
			"WindowFrame",
			Vector3.new(-hx + 0.45, wy0 - 0.35, front - 0.1),
			Vector3.new(hx - 0.45, wy1 + 0.35, front + 0.3),
			white
		)
		Kit.box(
			m,
			"Window",
			Vector3.new(-hx + 0.8, wy0, front - 0.14),
			Vector3.new(hx - 0.8, wy1, front + 0.3),
			Kit.glassLook(glass, 0.2)
		)
		for i, sx in { -1, 1 } do
			local x = sx * (hx - 0.8) / 3
			Kit.detail(
				m,
				`Mullion{i}`,
				Vector3.new(x - 0.12, wy0, front - 0.2),
				Vector3.new(x + 0.12, wy1, front - 0.1),
				white
			)
		end
		Kit.trim(
			m,
			"Belt",
			Vector3.new(-hx - 0.08, SHAPE.belt[1], front - 0.08),
			Vector3.new(hx + 0.08, SHAPE.belt[2], back + 0.08),
			accent
		)
		if shape == "swoop" then
			-- Three slabs, each steeper than the one behind it, curving up toward the sea.
			local p = Vector3.new(0, roof, back + 0.6)
			for i, slab in SHAPE.swoop do
				local angle = math.rad(slab[1])
				local q = p + Vector3.new(0, slab[2] * math.sin(angle), -slab[2] * math.cos(angle))
				Kit.part(
					m,
					`Roof{i}`,
					"block",
					CFrame.lookAt((p + q) / 2 + Vector3.new(0, 0.22, 0), q + Vector3.new(0, 0.22, 0)),
					Vector3.new(hut.X + 1.6, 0.45, slab[2] + 0.3),
					accent,
					"trim"
				)
				p = q
			end
			-- Speed lines down the side.
			for i = 1, 2 do
				local y = roof - 1.7 + (i - 1) * 0.6
				Kit.detail(
					m,
					`Speed{i}`,
					Vector3.new(hx, y, front + 1),
					Vector3.new(hx + 0.08, y + 0.3, back - 0.5),
					trim
				)
			end
			board(roof - 1.5, front - 0.06)
		else
			-- A roof pitched up toward the sea, a half sun and a fan of fins rising from its high edge.
			local ridge = roof + 2.2
			Kit.wedge(
				m,
				"Roof",
				Vector3.new(-hx - 0.9, roof, front - 1.1),
				Vector3.new(hx + 0.9, ridge, back + 0.7),
				"front",
				white
			)
			local base = Vector3.new(0, ridge - 0.1, front - 0.6)
			Kit.tube(
				m,
				"Sun",
				base - Vector3.new(0, 0, 0.25),
				base + Vector3.new(0, 0, 0.25),
				3.4,
				Kit.look(scheme.trim, Enum.Material.SmoothPlastic),
				"trim"
			)
			for i, degrees in SHAPE.rays do
				local angle = math.rad(degrees)
				local dir = Vector3.new(math.sin(angle), math.cos(angle), 0)
				local length = if degrees == 0 then 5.2 else 4.4
				local centre = base + dir * (1.5 + length / 2)
				Kit.part(
					m,
					`Ray{i}`,
					"block",
					CFrame.new(centre) * CFrame.Angles(0, 0, -angle),
					Vector3.new(1, length, 0.25),
					if i % 2 == 0 then trim else accent,
					"trim"
				)
			end
			board(roof - 1.5, front - 0.06)
		end
	end
end

return LifeguardStand
