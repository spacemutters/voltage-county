--!strict
-- W03 collage_parking_garage (docs/city/ARCHETYPES.md §8, W03): a parking garage wearing five different outfits side
-- by side, as if five designers each dressed one bay of its street face without seeing the others'. Behind them a
-- plain garage: pale deck bands over dark slots that wrap the sides and back, a roof cap, a stair tower and a light
-- mast on the top deck, and an arcade of shops under the first deck with the car entrance at one end. The outfits,
-- each standing proud of the garage on its own backing and rising to its own height past the roof:
--   barriers  upright orange and white boards leaning every which way on black, an amber neon line along the top
--   cars      gold and silver cars stuck climbing a perforated dark screen, a traffic jam up the wall (the signature)
--   puzzle    four striped pieces in cyan, magenta, yellow and black, locked by round knobs at two depths
--   antfarm   a perforated metal screen split by a slot where a red stair zigzags up past glowing glass rooms
--   figures   two tall abstract figures holding a gold lintel over their heads, caryatids for a car park
--
-- What makes it itself: a car park in five outfits, one of them a wall of cars climbing it.
-- Night: the barriers' amber line, the ant farm's glass rooms in their own colours, every climbing car's headlights
-- and a wash up the car wall, the lit shops, the parking sign over the entrance and the mast's floodlight.
-- Placement, sizes, heights and its budget: Config/City archetypes.collage_parking_garage (also a one-off on Plant
-- Avenue, Config/City landmarks).
-- Variants: palette (3 sets of the puzzle's colours and the figures' backdrop), crown (which outfit stays off a
-- site too narrow for all five, never the cars, and how the outfits' tops step), rhythm (3 orders of the outfits),
-- mirror.
--
-- Previewing: straight on and from both corners, at street level and from 150 studs. Check each outfit reads on its
-- own and they don't touch; the cars read as cars (body, cabin, two wheels) and climb rather than float, each
-- headlight on the end it climbs toward; the tilted boards and cars stay inside their own bay; the outfits' tops step
-- against the sky. Sites narrower than 175 show four outfits.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local City = require(ReplicatedStorage.Shared.Config.City)
local Kit = require(script.Parent.Parent.Parent.Kit)
local Types = require(script.Parent.Parent.Parent.Types)

local P = City.palettes
local KIT = City.kit
local rgb = Color3.fromRGB

-- The recipe, in studs.
local SHAPE = {
	front = 5, -- the garage's face this far behind the front line (the outfits stand in front of it)
	sideInset = 1,
	bodyDepth = 64, -- at most
	ground = 14, -- the shop floor under the first deck
	level = 10, -- a parking level, about...
	levels = { 5, 6 }, -- ...and this many
	slot = 3.8,
	bandProud = 0.4,
	cap = { thick = 1.6, proud = 0.7 },
	arcade = 3.2, -- the shops this far back under the first deck
	soffit = 0.8, -- the arcade ceiling's depth under the first deck
	columns = 4,
	column = 1.8,
	entry = { wide = 22, tall = 9.5 },
	allFive = 175, -- a garage this wide wears all five outfits
	panel = { gap = 1.2, back = 0.75, thick = 0.35 }, -- each outfit's backing, its back this far in front of the face
	-- The outfits' tops over the roof, in order (the crown turns the list): far enough apart to step against the sky
	-- from across the street; the highest stays under crownMax.
	rises = { 0, 8, -3, 12, 4 },
	board = { wide = 3.2, thick = 0.8, every = 4.6 },
	-- The cars in the jam: one every `rise` up the screen, at most `most`, alternate ones `out` further out (cars
	-- overlap, so their faces never share a plane; the front line leaves no room for more).
	-- `lamp`: how far its headlight strip stands past its nose.
	car = {
		long = 17,
		tall = 4.2,
		deep = 3.2,
		cabin = 8.6,
		roof = 3,
		wheel = 3.6,
		rise = 7.2,
		most = 7,
		out = 0.35,
		lamp = 0.7,
	},
	-- The caryatids: legs apart at the feet, a torso, a head over a neck gap, arms raised; `out`: their axis in
	-- front of the backing.
	figure = { leg = 2.4, stance = 2.8, hips = 1.4, torso = 8.4, head = 4.8, neck = 0.7, arm = 1.6, out = 1.2 },
	room = { wide = 9, tall = 7 },
	mast = 12,
	tower = { wide = 10, deep = 10, tall = 12 },
}

local ORDERS = {
	{ "barriers", "cars", "puzzle", "antfarm", "figures" },
	{ "puzzle", "figures", "cars", "barriers", "antfarm" },
	{ "antfarm", "barriers", "figures", "cars", "puzzle" },
}
local DROPS = { "barriers", "puzzle", "antfarm", "figures" } -- by crown: the outfit a narrow garage leaves off
-- Each outfit's share of the street face (the cars a little wider).
local WEIGHTS: { [string]: number } = { barriers = 1, cars = 1.35, puzzle = 1, antfarm = 1, figures = 1.1 }

-- The puzzle's four colours and their stripes, and the figures' backdrop.
type Palette = { puzzle: { Color3 }, stripes: { Color3 }, backdrop: Color3 }
local PALETTES: { Palette } = {
	{
		puzzle = { rgb(0, 190, 220), rgb(232, 44, 140), rgb(255, 214, 0), rgb(27, 27, 31) },
		stripes = { rgb(246, 244, 238), rgb(246, 244, 238), rgb(27, 27, 31), rgb(246, 244, 238) },
		backdrop = rgb(246, 196, 206),
	},
	{
		puzzle = { rgb(232, 44, 140), rgb(255, 214, 0), rgb(27, 27, 31), rgb(0, 190, 220) },
		stripes = { rgb(246, 244, 238), rgb(27, 27, 31), rgb(246, 244, 238), rgb(246, 244, 238) },
		backdrop = rgb(170, 220, 236),
	},
	{
		puzzle = { rgb(255, 214, 0), rgb(27, 27, 31), rgb(0, 190, 220), rgb(232, 44, 140) },
		stripes = { rgb(27, 27, 31), rgb(246, 244, 238), rgb(246, 244, 238), rgb(246, 244, 238) },
		backdrop = rgb(255, 226, 150),
	},
}

local WHITE = rgb(246, 244, 238)
local INK = rgb(27, 27, 31)
local ORANGE = rgb(242, 106, 33)
local GOLD = rgb(201, 167, 74)
local SILVER = rgb(199, 204, 209)
local LEANS = { -6, 4, -3, 7, -5, 2, -4 } -- the boards' lean, degrees
local CAR_TURNS = { 24, -18, 32, -12, 36, -26, 16 } -- the cars' climb, degrees
local CAR_LANES = { 0.32, 0.68, 0.42, 0.7, 0.3, 0.62, 0.46 } -- where across the screen each sits

local function build(m: Types.Model)
	local site = m.site
	local variant = site.variant
	local pal = PALETTES[math.clamp(variant.palette, 1, #PALETTES)]
	local rng = Kit.rng(m)
	local W, D, H = site.width, site.depth, site.height
	local hw, hd = W / 2, D / 2
	local G = SHAPE.ground
	local x0, x1 = -hw + SHAPE.sideInset, hw - SHAPE.sideInset
	local zF = -hd + SHAPE.front
	local zB = math.min(hd - 1, zF + SHAPE.bodyDepth)
	local cap = SHAPE.cap
	local top = H - cap.thick
	local levels = math.clamp(math.round((top - G) / SHAPE.level), SHAPE.levels[1], SHAPE.levels[2])

	local concrete = Kit.look(P.concrete.pale, Enum.Material.Concrete)
	local dark = Kit.look(P.concrete.dark, Enum.Material.SmoothPlastic)
	local function flat(color: Color3): Kit.Look
		return Kit.look(color, Enum.Material.SmoothPlastic)
	end

	-------------------------------------------------------------------------------------------------------
	-- The garage: deck bands over dark slots on every side, a roof cap, the top deck's tower and mast
	-------------------------------------------------------------------------------------------------------
	Kit.podium(
		m,
		"Deck",
		Vector3.new(x0, G, zF),
		Vector3.new(x1, top + 0.05, zB),
		levels,
		SHAPE.slot,
		SHAPE.bandProud,
		concrete,
		dark
	)
	Kit.trim(
		m,
		"Cap",
		Vector3.new(x0 - cap.proud, top, zF - cap.proud),
		Vector3.new(x1 + cap.proud, H, zB + cap.proud),
		concrete
	)
	local tw = SHAPE.tower
	local towerBack = zB - 3
	Kit.roofBox(
		m,
		"Tower",
		Vector3.new(x1 - 3 - tw.wide, H, towerBack - tw.deep),
		Vector3.new(x1 - 3, H + tw.tall, towerBack),
		concrete
	)
	local mastX, mastZ = x0 + 6, math.max(zF + 10, zB - 12)
	Kit.column(
		m,
		"Mast",
		mastX,
		mastZ,
		H,
		H + SHAPE.mast,
		0.6,
		Kit.look(rgb(150, 154, 158), Enum.Material.Metal),
		"detail"
	)
	Kit.lit(
		Kit.detail(
			m,
			"MastLamp",
			Vector3.new(mastX - 1.6, H + SHAPE.mast, mastZ - 0.5),
			Vector3.new(mastX + 1.6, H + SHAPE.mast + 0.6, mastZ + 0.5),
			flat(rgb(220, 224, 228))
		),
		"floodlight"
	)

	-------------------------------------------------------------------------------------------------------
	-- The street floor: shops behind an arcade of columns, the car entrance and its sign at one end
	-------------------------------------------------------------------------------------------------------
	local zA = zF + SHAPE.arcade
	local soffit = G - SHAPE.soffit
	Kit.box(m, "Ground", Vector3.new(x0, -KIT.bury, zA), Vector3.new(x1, G + 0.05, zB - 0.05), concrete)
	-- The arcade's ceiling: the first deck's thick edge over the street (it also covers the faces the deck's mass and
	-- its first band share there).
	local bp = SHAPE.bandProud + 0.05
	Kit.trim(m, "Soffit", Vector3.new(x0 - bp, soffit, zF - bp), Vector3.new(x1 + bp, G + 0.02, zA + 0.1), concrete)
	Kit.box(m, "Paving", Vector3.new(-hw + 0.3, -0.6, -hd + 0.3), Vector3.new(hw - 0.3, 0.2, zA + 0.4), concrete)
	local en = SHAPE.entry
	local ex1 = x1 - 3
	local ex0 = ex1 - en.wide
	Kit.detail(m, "Entrance", Vector3.new(ex0, 0.2, zA - 0.1), Vector3.new(ex1, en.tall, zA + 0.2), dark)
	Kit.detail(
		m,
		"Barrier",
		Vector3.new(ex0 + 1.5, 3.4, zF + 1),
		Vector3.new(ex0 + 1.5 + en.wide * 0.45, 3.9, zF + 1.4),
		flat(rgb(255, 196, 40))
	)
	Kit.sign(
		m,
		"Park",
		Vector3.new(ex0 + 2, soffit - 3.6, zF + 0.4),
		Vector3.new(ex0 + 5.6, soffit - 0.02, zF + 0.7),
		Enum.NormalId.Front,
		"P",
		rgb(40, 90, 200),
		WHITE,
		Enum.Font.Michroma,
		"sign"
	)
	local shop1 = ex0 - 3
	Kit.glass(
		m,
		"Shops",
		Vector3.new(x0 + 2, 0.2, zA - 0.5),
		Vector3.new(shop1, soffit - 1.2, zA + 0.15),
		rgb(44, 60, 70),
		{
			image = City.textures.windowBold,
			faces = { Enum.NormalId.Front },
			u = 5,
			v = soffit - 1.4,
			lines = rgb(60, 64, 70),
			lit = true,
		}
	)
	local names = City.signNames.arts
	Kit.sign(
		m,
		"ShopName",
		Vector3.new(x0 + 4, soffit - 1.15, zA - 0.75),
		Vector3.new(math.max(x0 + 10, x0 + 4 + (shop1 - x0) * 0.45), soffit - 0.02, zA - 0.5),
		Enum.NormalId.Front,
		names[rng:NextInteger(1, #names)],
		INK,
		WHITE,
		City.districtLooks.arts.font
	)
	for i = 1, SHAPE.columns do
		local x = x0 + 4 + (shop1 - x0 - 6) * (i - 0.5) / SHAPE.columns
		Kit.column(m, `Column{i}`, x, zF + 1.2, -KIT.bury, soffit + 0.3, SHAPE.column, concrete)
	end

	-------------------------------------------------------------------------------------------------------
	-- The outfits
	-------------------------------------------------------------------------------------------------------
	local pn = SHAPE.panel
	local zP = zF - pn.back - pn.thick -- each backing's face
	local py0 = G + 0.6
	local function backing(name: string, a: number, b: number, y1: number, look: Kit.Look): Types.PartSpec
		return Kit.trim(m, name, Vector3.new(a, py0, zP), Vector3.new(b, y1, zF - pn.back), look)
	end

	-- Upright barrier boards, leaning, orange and white on black, an amber line along the top.
	local function barriers(a: number, b: number, y1: number)
		backing("BarrierBack", a, b, y1, dark)
		local bd = SHAPE.board
		local count = math.clamp(math.floor((b - a) / bd.every), 4, 7)
		local long = y1 - py0 - 2.4
		local shift = rng:NextInteger(0, #LEANS - 1)
		for i = 1, count do
			local lean = math.rad(LEANS[(i + shift - 1) % #LEANS + 1])
			local reach = (long * math.abs(math.sin(lean)) + bd.wide * math.cos(lean)) / 2 + 0.3
			local x = a + reach + (b - a - 2 * reach) * (i - 1) / (count - 1)
			-- Every other board stands further out, so boards that cross never meet.
			local z = zP - bd.thick / 2 - 0.2 - (i % 2) * (bd.thick + 0.1)
			local cf = CFrame.new(x, (py0 + y1) / 2, z) * CFrame.Angles(0, 0, lean)
			local color = if i % 2 == 1 then ORANGE else WHITE
			Kit.oriented(m, `Board{i}`, "block", cf, Vector3.new(bd.wide, long, bd.thick), flat(color), "trim")
		end
		Kit.neon(
			m,
			"BarrierNeon",
			Vector3.new(a + 0.6, y1 - 0.6, zP - 0.4),
			Vector3.new(b - 0.6, y1 - 0.6, zP - 0.4),
			"neonAmber",
			ORANGE
		)
	end

	-- Cars climbing a perforated dark screen, gold and silver, each a body, a cabin and two wheels.
	local function cars(a: number, b: number, y1: number)
		local screen = backing("CarScreen", a, b, y1, Kit.look(rgb(58, 62, 68), Enum.Material.DiamondPlate))
		screen.textures = {
			{
				face = Kit.face(m, Enum.NormalId.Front),
				image = City.textures.windowBold,
				u = 1.2,
				v = 1.2,
				color = rgb(30, 32, 36),
			},
		}
		local c = SHAPE.car
		local count = math.clamp(math.floor((y1 - py0 - 4) / c.rise), 3, c.most)
		local step = (y1 - py0 - 6) / count
		local wheel = Kit.look(rgb(30, 30, 32), Enum.Material.SmoothPlastic)
		for i = 1, count do
			local turn = math.rad(CAR_TURNS[(i - 1) % #CAR_TURNS + 1])
			local cos, sin = math.cos(turn), math.sin(turn)
			-- Kept inside the bay: half the turned car's width either side.
			local half = (c.long * math.abs(cos) + (c.tall + c.roof + 1.2) * math.abs(sin)) / 2 + 0.6
			local cx = math.clamp(a + (b - a) * CAR_LANES[(i - 1) % #CAR_LANES + 1], a + half, b - half)
			local cy = py0 + 3.5 + step * (i - 0.5)
			local zc = zP - c.deep / 2 - 0.1 - (i % 2) * c.out
			local function at(u: number, v: number): (number, number)
				return cx + u * cos - v * sin, cy + u * sin + v * cos
			end
			local body = Kit.look(if i % 2 == 1 then GOLD else SILVER, Enum.Material.Foil)
			local spin = CFrame.Angles(0, 0, turn)
			Kit.oriented(
				m,
				`Car{i}`,
				"block",
				CFrame.new(cx, cy, zc) * spin,
				Vector3.new(c.long, c.tall, c.deep),
				body,
				"trim"
			)
			-- Every car noses up the wall: its cabin sits back from the end it climbs toward, its headlights on that end.
			local ahead = if turn >= 0 then 1 else -1
			local kx, ky = at(-ahead, c.tall * 0.5 + c.roof / 2 - 0.1)
			Kit.oriented(
				m,
				`Cabin{i}`,
				"block",
				CFrame.new(kx, ky, zc + 0.3) * spin,
				Vector3.new(c.cabin, c.roof, c.deep - 0.6),
				body,
				"trim"
			)
			-- At night the jam is a column of headlights going up the wall: big enough to read from across the street.
			local hx, hy = at(ahead * (c.long / 2 + c.lamp / 2 - 0.05), c.tall * 0.05)
			Kit.lit(
				Kit.oriented(
					m,
					`Headlight{i}`,
					"block",
					CFrame.new(hx, hy, zc - 0.2) * spin, -- its face a hair proud of the body's
					Vector3.new(c.lamp, c.tall * 0.55, c.deep - 0.3),
					flat(rgb(236, 232, 214)),
					"detail"
				),
				"floodlight"
			)
			for j, u in { -c.long * 0.32, c.long * 0.32 } do
				local wx, wy = at(u, -c.tall * 0.5)
				Kit.tube(
					m,
					`Wheel{i}_{j}`,
					Vector3.new(wx, wy, zc - c.deep / 2 - 0.25),
					Vector3.new(wx, wy, zc - c.deep / 2 + 0.4),
					c.wheel,
					wheel,
					"detail"
				)
			end
		end
		Kit.wash(m, "Wash", a + 1, b - 1, zP - 0.5, G + 0.1, rgb(255, 226, 190))
	end

	-- Four striped puzzle pieces in a two-by-two, at two depths, locked by knobs turning round the middle.
	local function puzzle(a: number, b: number, y1: number)
		backing("PuzzleBack", a, b, y1, flat(WHITE))
		local midX, midY = (a + b) / 2, (py0 + y1) / 2
		local inset = 0.5
		local quads = {
			{ a + inset, py0 + inset, midX - inset * 0.5, midY - inset * 0.5 },
			{ midX + inset * 0.5, py0 + inset, b - inset, midY - inset * 0.5 },
			{ midX + inset * 0.5, midY + inset * 0.5, b - inset, y1 - inset },
			{ a + inset, midY + inset * 0.5, midX - inset * 0.5, y1 - inset },
		}
		local knob = math.min(b - a, y1 - py0) * 0.16
		-- Each knob sits on the edge it shares with the next piece round: right, up, left, down.
		local knobs = {
			Vector2.new(midX, (py0 + midY) / 2),
			Vector2.new((midX + b) / 2, midY),
			Vector2.new(midX, (midY + y1) / 2),
			Vector2.new((a + midX) / 2, midY),
		}
		for i, q in quads do
			local depth = if i % 2 == 1 then 1 else 0.5
			local look = flat(pal.puzzle[i])
			local piece =
				Kit.trim(m, `Piece{i}`, Vector3.new(q[1], q[2], zP - depth), Vector3.new(q[3], q[4], zP + 0.05), look)
			piece.textures = {
				{
					face = Kit.face(m, Enum.NormalId.Front),
					image = City.textures.slabLine,
					u = q[3] - q[1],
					v = 2.2,
					color = pal.stripes[i],
				},
			}
			local k = knobs[i]
			Kit.tube(
				m,
				`Knob{i}`,
				Vector3.new(k.X, k.Y, zP - 1.15),
				Vector3.new(k.X, k.Y, zP + 0.05),
				knob,
				look,
				"trim"
			)
		end
	end

	-- A perforated screen split by a slot: a red stair zigzags up it past two glowing glass rooms.
	local function antfarm(a: number, b: number, y1: number)
		backing("FarmBack", a, b, y1, dark)
		local slot0, slot1 = a + (b - a) * 0.3, a + (b - a) * 0.72
		local mesh = Kit.look(rgb(143, 150, 156), Enum.Material.DiamondPlate)
		for i, span in { { a + 0.3, slot0 }, { slot1, b - 0.3 } } do
			local screen = Kit.trim(
				m,
				`Screen{i}`,
				Vector3.new(span[1], py0 + 0.3, zP - 0.6),
				Vector3.new(span[2], y1 - 0.3, zP + 0.05),
				mesh
			)
			screen.textures = {
				{
					face = Kit.face(m, Enum.NormalId.Front),
					image = City.textures.windowBold,
					u = 1,
					v = 1,
					color = rgb(96, 102, 108),
				},
			}
		end
		local flights = math.min(levels, 5)
		local rise = (y1 - py0 - 3) / flights
		local red = flat(rgb(220, 60, 50))
		for k = 1, flights do
			local ya, yb = py0 + 1.5 + (k - 1) * rise, py0 + 1.5 + k * rise
			local left, right = slot0 + 1.6, slot1 - 1.6
			local from = if k % 2 == 1 then left else right
			local to = if k % 2 == 1 then right else left
			Kit.strut(
				m,
				`Flight{k}`,
				Vector3.new(from, ya, zP - 1.2),
				Vector3.new(to, yb, zP - 1.2),
				1.4,
				red,
				"trim",
				2.6
			)
		end
		local rm = SHAPE.room
		local rw = math.min(rm.wide, (slot1 - slot0) * 0.55)
		for i, room in { { at = 0.22, colour = rgb(60, 190, 110) }, { at = 0.62, colour = rgb(240, 170, 40) } } do
			local ry = py0 + (y1 - py0) * room.at
			local rx = if i == 1 then slot0 + 0.8 else slot1 - 0.8 - rw
			local spec = Kit.glass(
				m,
				`Room{i}`,
				Vector3.new(rx, ry, zP - 0.5),
				Vector3.new(rx + rw, ry + rm.tall, zP + 0.05),
				room.colour
			)
			Kit.lit(spec, "stained")
		end
	end

	-- Two tall figures holding a gold lintel over their heads.
	local function figures(a: number, b: number, y1: number)
		backing("FigureBack", a, b, y1, flat(pal.backdrop))
		local lintelY = y1 - 4.2
		Kit.trim(
			m,
			"Lintel",
			Vector3.new(a + 0.8, lintelY, zP - 2.2),
			Vector3.new(b - 0.8, y1 - 1, zP + 0.05),
			Kit.look(GOLD, Enum.Material.Foil)
		)
		local tall = lintelY - py0 - 1
		local fg = SHAPE.figure
		local white, ink = flat(WHITE), flat(INK)
		local body = flat(pal.puzzle[1])
		for i, f in { 0.28, 0.72 } do
			local fx = a + (b - a) * f
			local foot = py0 + 0.6
			local hip = foot + tall * 0.42
			local shoulder = hip + tall * 0.3
			local zc = zP - fg.out
			for j, side in { -1, 1 } do
				Kit.strut(
					m,
					`Leg{i}_{j}`,
					Vector3.new(fx + side * fg.stance, foot, zc),
					Vector3.new(fx + side * fg.hips, hip + 0.4, zc),
					fg.leg,
					white,
					"trim"
				)
			end
			Kit.trim(
				m,
				`Torso{i}`,
				Vector3.new(fx - fg.torso / 2, hip, zc - 1.3),
				Vector3.new(fx + fg.torso / 2, shoulder, zc + 1.3),
				body
			)
			Kit.ball(
				m,
				`Head{i}`,
				Vector3.new(fx, shoulder + fg.neck + fg.head / 2, zc),
				fg.head,
				Kit.look(GOLD, Enum.Material.Foil),
				"trim"
			)
			for j, side in { -1, 1 } do
				Kit.strut(
					m,
					`Arm{i}_{j}`,
					Vector3.new(fx + side * (fg.torso / 2 - 0.6), shoulder - 0.8, zc),
					Vector3.new(fx + side * (fg.torso / 2 + 1.6), lintelY + 0.3, zc),
					fg.arm,
					ink,
					"trim"
				)
			end
		end
	end

	local makers: { [string]: (number, number, number) -> () } = {
		barriers = barriers,
		cars = cars,
		puzzle = puzzle,
		antfarm = antfarm,
		figures = figures,
	}

	local order = ORDERS[math.clamp(variant.rhythm, 1, #ORDERS)]
	local crown = math.clamp(variant.crown, 1, #DROPS)
	local span = x1 - x0
	local drop = if span >= SHAPE.allFive then "" else DROPS[crown]
	local chosen: { string } = {}
	local total = 0
	for _, id in order do
		if id ~= drop then
			table.insert(chosen, id)
			total += WEIGHTS[id]
		end
	end
	local room = span - pn.gap * (#chosen - 1)
	local cursor = x0
	for i, id in chosen do
		local wide = room * WEIGHTS[id] / total
		local rise = SHAPE.rises[(i + crown - 2) % #SHAPE.rises + 1]
		makers[id](cursor, cursor + wide, H + rise)
		cursor += wide + pn.gap
	end
end

local archetype: Types.Archetype = { id = "collage_parking_garage", build = build }
return archetype
