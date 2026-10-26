--!strict
-- C07 lighthouse_water_tower (docs/city/ARCHETYPES.md §9, C07): the suburbs' water tower dressed as a Mediterranean
-- lighthouse. A coral-rock octagonal plinth with an arched door, then three octagonal stucco stages, each narrower
-- than the last, with a string course at every step and slit windows; a corbelled gallery wider than the shaft with a
-- see-through iron rail, and the signature: a lantern of slim posts round a glowing core under a domed cap, a finial
-- and a red beacon. Floodlit at night.
--
-- What makes it itself: a lighthouse in a suburb, an octagonal tapering shaft with a gallery and a domed lantern.
-- Placement, sizes, heights and its budget: Config/CityArchetypes/lighthouse_water_tower (built as a 30 x 30 site in
-- place of the riverside_water_tower feature's old look).
-- Variants: palette (1 cream with terracotta courses and a copper-green dome, 2 white with coral courses and a red
-- tile cap, 3 sand with white courses and a bronze dome), crown (1 an open lantern of eight posts under a dome, 2 a
-- walled lantern with four arched openings under a stepped cap), rhythm (1 slit windows stacked front and back, 2 slit
-- windows turning round the shaft stage by stage), mirror (the spiral's direction).
--
-- Previewing (Studio helper): Preview.build("lighthouse_water_tower", { width = 30, depth = 30 }). Check: the stages
-- read as octagons (flat faces, not stars) stepping in; the string courses and the gallery stand proud; the rail is
-- see-through; at night the lantern glows amber, the beacon red, and the wash lights the shaft's front.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local City = require(ReplicatedStorage.Shared.Config.City)
local Kit = require(script.Parent.Parent.Parent.Kit)
local Types = require(script.Parent.Parent.Parent.Types)

local P = City.palettes
local KIT = City.kit
local rgb = Color3.fromRGB
local COS8 = math.cos(math.pi / 8)

-- The recipe, in studs.
local SHAPE = {
	maxAcross = 30, -- the plinth's widest
	plinth = { height = 5, inset = 1.5 },
	stages = { 0.42, 0.74 }, -- where the shaft steps in, as shares of the gallery's height
	shrink = { 0.84, 0.68 }, -- stages two and three, as shares of stage one
	course = { thick = 1.6, proud = 1.3 },
	corbel = 2,
	gallery = { thick = 1, out = 3 },
	rail = { height = 2.6, transparency = 0.55 },
	lantern = { share = 0.42, height = 11, post = 0.7 },
	door = { width = 4.4, spring = 6.4 },
	slit = { width = 1.8, height = 6 },
	finial = 3.4,
}

-- Walls, string courses and trim, the plinth's coral rock, the cap, the lantern's day colour, the wash.
local PALETTES = {
	{
		wall = rgb(239, 227, 200),
		course = rgb(196, 112, 74),
		rock = rgb(205, 187, 149),
		cap = Kit.look(rgb(94, 143, 123), Enum.Material.SmoothPlastic),
		lantern = rgb(246, 226, 170),
		wash = rgb(255, 214, 170),
	},
	{
		wall = rgb(247, 245, 240),
		course = rgb(238, 128, 106),
		rock = rgb(214, 200, 168),
		cap = Kit.look(rgb(181, 88, 58), Enum.Material.ClayRoofTiles),
		lantern = rgb(250, 236, 196),
		wash = rgb(255, 222, 190),
	},
	{
		wall = rgb(232, 214, 178),
		course = rgb(248, 246, 240),
		rock = rgb(196, 176, 140),
		cap = Kit.look(rgb(150, 116, 70), Enum.Material.Metal),
		lantern = rgb(246, 220, 150),
		wash = rgb(255, 206, 150),
	},
}

local IRON = rgb(40, 42, 44)
local DARK = P.window.deep
-- Face normals in plan (x, z), in turn round the shaft.
local FACES = { Vector2.new(0, -1), Vector2.new(1, 0), Vector2.new(0, 1), Vector2.new(-1, 0) }

local function build(m: Types.Model)
	local site = m.site
	local variant = site.variant
	local pal = PALETTES[math.clamp(variant.palette, 1, #PALETTES)]
	local crown = math.clamp(variant.crown, 1, 2)
	local rhythm = math.clamp(variant.rhythm, 1, 2)
	local W, D, H = site.width, site.depth, site.height
	local wall = Kit.look(pal.wall, Enum.Material.SmoothPlastic)
	local course = Kit.look(pal.course, Enum.Material.SmoothPlastic)
	local rock = Kit.look(pal.rock, Enum.Material.Limestone)

	local A0 = math.min(W, D, SHAPE.maxAcross + 3) - 3 -- the plinth
	local A1 = A0 - 2 * SHAPE.plinth.inset
	local A2, A3 = A1 * SHAPE.shrink[1], A1 * SHAPE.shrink[2]
	local y1, y2 = H * SHAPE.stages[1], H * SHAPE.stages[2]
	local pl = SHAPE.plinth
	local cs = SHAPE.course

	-------------------------------------------------------------------------------------------------------
	-- The plinth, the door, the three stages and their string courses
	-------------------------------------------------------------------------------------------------------
	Kit.octagon(m, "Plinth", 0, 0, -KIT.bury, pl.height, A0, rock)
	Kit.octagon(m, "Stage1", 0, 0, pl.height - 0.3, y1, A1, wall)
	Kit.octagon(m, "Course1", 0, 0, y1 - cs.thick / 2, y1 + cs.thick / 2, A1 + 2 * cs.proud, course, "trim")
	Kit.octagon(m, "Stage2", 0, 0, y1 + cs.thick / 2 - 0.1, y2, A2, wall)
	Kit.octagon(m, "Course2", 0, 0, y2 - cs.thick / 2, y2 + cs.thick / 2, A2 + 2 * cs.proud, course, "trim")
	local ga = SHAPE.gallery
	Kit.octagon(m, "Stage3", 0, 0, y2 + cs.thick / 2 - 0.1, H - ga.thick, A3, wall)

	local dr = SHAPE.door
	local front = -A1 / 2
	Kit.glass(
		m,
		"Door",
		Vector3.new(-dr.width / 2, pl.height, front - 0.1),
		Vector3.new(dr.width / 2, dr.spring + pl.height, front + 0.3),
		rgb(70, 52, 38),
		{ reflectance = 0.05 }
	)
	Kit.tube(
		m,
		"DoorArch",
		Vector3.new(0, dr.spring + pl.height, front - 0.06),
		Vector3.new(0, dr.spring + pl.height, front + 0.3),
		dr.width,
		Kit.look(rgb(70, 52, 38), Enum.Material.Wood),
		"detail"
	)
	Kit.box(
		m,
		"Step",
		Vector3.new(-dr.width / 2 - 1, pl.height - 0.6, -A0 / 2 - 1.2),
		Vector3.new(dr.width / 2 + 1, pl.height, front + 0.2),
		rock
	)

	-- Slit windows: stacked on the front and back (rhythm 1), or turning a quarter round the shaft at each stage
	-- (rhythm 2).
	local sl = SHAPE.slit
	local stages = {
		{ across = A1, y0 = pl.height + 12, y1 = y1 - 4 },
		{ across = A2, y0 = y1 + 4, y1 = y2 - 4 },
		{ across = A3, y0 = y2 + 4, y1 = H - 5 },
	}
	local n = 0
	for i, st in stages do
		local faces: { Vector2 } = if rhythm == 1 then { FACES[1], FACES[3] } else { FACES[(i - 1) % 4 + 1] }
		for _, f in faces do
			local mid = (st.y0 + st.y1) / 2
			local ys = { mid - sl.height / 2 - 1.5, mid + sl.height / 2 + 1.5 }
			for _, y in ys do
				if y - sl.height / 2 < st.y0 or y + sl.height / 2 > st.y1 then
					continue
				end
				n += 1
				local r = st.across / 2
				local c = f * r
				local along = Vector2.new(-f.Y, f.X) * (sl.width / 2)
				local out = f * 0.08
				local inn = -f * 0.3
				local a = c + along + out
				local b = c - along + inn
				Kit.glass(
					m,
					`Slit{n}`,
					Vector3.new(a.X, y - sl.height / 2, a.Y),
					Vector3.new(b.X, y + sl.height / 2, b.Y),
					DARK,
					{ reflectance = 0.15 }
				)
			end
		end
	end

	-------------------------------------------------------------------------------------------------------
	-- The gallery: a corbel ring, the floor, the see-through rail
	-------------------------------------------------------------------------------------------------------
	local gAcross = math.min(A3 + 2 * ga.out, A0)
	Kit.disc(m, "Corbel", 0, 0, H - ga.thick - SHAPE.corbel / 2, A3 / COS8 + 1, SHAPE.corbel, course)
	Kit.octagon(m, "Gallery", 0, 0, H - ga.thick, H, gAcross, course, "trim")
	local rl = SHAPE.rail
	Kit.column(
		m,
		"Rail",
		0,
		0,
		H,
		H + rl.height,
		gAcross - 0.6,
		Kit.look(IRON, Enum.Material.Metal, 0, rl.transparency),
		"detail"
	)

	-------------------------------------------------------------------------------------------------------
	-- The lantern and its cap, the finial and the beacon
	-------------------------------------------------------------------------------------------------------
	local la = SHAPE.lantern
	local r = A3 * la.share
	local lTop = H + 0.2 + la.height
	local lampLook = Kit.look(pal.lantern, Enum.Material.SmoothPlastic)
	local capTop: number
	if crown == 2 then
		-- A walled lantern, an arched opening on each axis face, under a stepped cap.
		local across = 2 * r + 1
		Kit.octagon(m, "Lantern", 0, 0, H + 0.02, lTop, across, wall)
		Kit.lit(Kit.column(m, "Lamp", 0, 0, H + 1, lTop - 1, across - 1.6, lampLook, "detail"), "neonAmber")
		for k, f in FACES do
			local ow = across * 0.3
			local c = f * (across / 2)
			local along = Vector2.new(-f.Y, f.X) * (ow / 2)
			local a = c + along + f * 0.08
			local b = c - along - f * 0.3
			local spring = lTop - 2.4 - ow / 2
			Kit.lit(
				Kit.glass(
					m,
					`Opening{k}`,
					Vector3.new(a.X, H + 1.6, a.Y),
					Vector3.new(b.X, spring, b.Y),
					DARK,
					{ reflectance = 0.1 }
				),
				"neonAmber"
			)
			local p0 = Vector3.new(c.X + f.X * 0.06, spring, c.Y + f.Y * 0.06)
			local p1 = Vector3.new(c.X - f.X * 0.3, spring, c.Y - f.Y * 0.3)
			Kit.lit(Kit.tube(m, `OpeningArch{k}`, p0, p1, ow, Kit.glassLook(DARK, 0.1), "detail"), "neonAmber")
		end
		local y = lTop
		for k, share in { 1.25, 0.9, 0.55 } do
			Kit.disc(m, `Cap{k}`, 0, 0, y + 0.6, across * share, 1.2, pal.cap, "trim")
			y += 1.2
		end
		capTop = y
	else
		-- An open lantern: eight slim posts round a glowing core, a cornice and a dome.
		Kit.lit(Kit.column(m, "Lamp", 0, 0, H, lTop, 2 * r - 0.8, lampLook, "detail"), "neonAmber")
		for k = 0, 7 do
			local a = math.pi / 8 + k * math.pi / 4
			Kit.column(
				m,
				`Post{k + 1}`,
				r * math.sin(a),
				-r * math.cos(a),
				H,
				lTop,
				la.post,
				Kit.look(IRON, Enum.Material.Metal),
				"detail"
			)
		end
		Kit.disc(m, "Cornice", 0, 0, lTop + 0.4, 2 * r + 2.4, 0.8, course)
		local dome = 2 * r + 1
		Kit.ball(m, "Dome", Vector3.new(0, lTop + 0.4, 0), dome, pal.cap, "trim")
		capTop = lTop + 0.4 + dome / 2
	end
	local fTop = math.min(capTop + SHAPE.finial, site.maxHeight - 1.4)
	Kit.column(m, "Finial", 0, 0, capTop - 0.3, fTop, 0.5, Kit.look(IRON, Enum.Material.Metal), "detail")
	Kit.lit(
		Kit.ball(
			m,
			"Beacon",
			Vector3.new(0, fTop + 0.5, 0),
			1.2,
			Kit.look(rgb(150, 40, 36), Enum.Material.SmoothPlastic)
		),
		"beacon"
	)

	-- At night a wash at the plinth's front lights the shaft.
	Kit.wash(m, "Wash", -A1 * 0.3, A1 * 0.3, -A0 / 2 - 1.2, 0.05, pal.wash)
end

local archetype: Types.Archetype = { id = "lighthouse_water_tower", build = build }
return archetype
