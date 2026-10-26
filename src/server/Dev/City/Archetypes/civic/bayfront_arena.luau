--!strict
-- C04 bayfront_arena (docs/city/ARCHETYPES.md §9, C04): the bayfront arena. A big white oval in layers: a lit glass
-- concourse set back under a white deck band, a dark glass ribbon, the white upper bowl, a roof-edge band ringed with
-- LED light, then a low stepped roof carrying a giant picture made to be seen from the towers. At its corners the
-- signature glass stair halls: see-through boxes with slim white mullions and corner posts, their zig-zag stairs in
-- the roof picture's colour showing through, glowing at night. Terraces step out toward the water; a long canopy with
-- the arena's name marks the entrance, and a wash lights the bowl's front at night.
--
-- What makes it itself: a white oval with glowing glass stair halls at its corners and a picture on its roof.
-- Placement, sizes, heights and its budget: Config/CityArchetypes/bayfront_arena. Front (-z): the road and the
-- entrance; back (+z): the water and the terraces (so its landmark entry should face the road; see the config).
-- Variants: palette (1 white, blue glass and a yellow bolt; 2 white, teal glass and a coral picture; 3 silver, smoke
-- glass and a mint picture), crown (1 a lightning bolt across the roof, 2 the county's name lettered on a roof
-- disc), rhythm (1 four stair halls at the corners, 2 two big halls at the front corners and deeper terraces),
-- mirror (the entrance canopy sits off-centre).
--
-- Previewing (Studio helper): Preview.build("bayfront_arena", { width = 230, depth = 200 }) for the full look (a whole
-- lakefront site); width 160, depth 53 is the plain-plot fallback (a thin pill). Check from the air and from a tower
-- that the picture reads on the roof; from the street that the halls read as framed glass boxes (mullions on their
-- three outer faces, white posts at their outer corners) with the coloured stairs showing through, and the bands
-- read as shadow lines; at night the concourse, the halls, the LED ring and the picture glow, and the wash lights
-- the bowl's front over the deck band.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local City = require(ReplicatedStorage.Shared.Config.City)
local Kit = require(script.Parent.Parent.Parent.Kit)
local Types = require(script.Parent.Parent.Parent.Types)

local P = City.palettes
local KIT = City.kit
local rgb = Color3.fromRGB

-- The recipe, in studs.
local SHAPE = {
	sideInset = 2,
	plaza = 12, -- in front, for the entrance canopy
	back = 10, -- behind, for the terraces
	oval = { width = 220, depth = 170 },
	-- The bowl's layers, bottom up: { from, to, inset (+ in, - out) }
	concourse = { y = 14, inset = 5 },
	deck = { y = 20, proud = 0.6 },
	ribbon = { y = 30, inset = 1.2 },
	bowl = { y = 44 },
	edge = { y = 47.5, proud = 1.2 },
	led = { y = 44.2, thick = 0.6, proud = 1.4 },
	roof = { inset = 9, share = 0.55, inset2 = 22 },
	hall = {
		{ count = 4, width = 30, depth = 18, height = 52, flights = 3 }, -- rhythm 1
		{ count = 2, width = 38, depth = 20, height = 56, flights = 4 }, -- rhythm 2
	},
	stair = { thick = 1.2, wide = 6, rise = 12 },
	hallMullion = 5, -- the stair halls' glass: one pane this wide, a floor (stair.rise) tall
	terrace = { { 6, 2 }, { 9, 3 } }, -- by rhythm: how far out, how many levels (at the deck and the ribbon's top)
	canopy = { y = 14.5, thick = 1.4, share = 0.36, out = 9 },
	doors = 10, -- the glass doors' height under the canopy
	picture = { width = 0.15 },
	fins = { count = 28, wide = 1.2, proud = 1.6 }, -- white fins round the upper bowl
	screen = { width = 50, from = 31, to = 42 }, -- the video board on the bowl's front
}

-- Walls, glass, the picture's colour and its night kind, the roof.
local PALETTES = {
	{
		wall = rgb(248, 248, 246),
		glass = P.glass.blue,
		picture = rgb(255, 201, 60),
		night = "neonAmber",
		roof = rgb(238, 240, 240),
	},
	{
		wall = rgb(246, 244, 238),
		glass = P.glass.teal,
		picture = rgb(240, 110, 90),
		night = "neonPink",
		roof = rgb(240, 238, 232),
	},
	{
		wall = rgb(214, 220, 226),
		glass = P.glass.smoke,
		picture = rgb(110, 210, 176),
		night = "neonBlue",
		roof = rgb(222, 228, 234),
	},
}

local HAIR = 0.02

local function build(m: Types.Model)
	local site = m.site
	local variant = site.variant
	local pal = PALETTES[math.clamp(variant.palette, 1, #PALETTES)]
	local rhythm = math.clamp(variant.rhythm, 1, 2)
	local W, D, H = site.width, site.depth, site.height
	local hw, hd = W / 2, D / 2
	local wall = Kit.look(pal.wall, Enum.Material.SmoothPlastic)
	local hs = SHAPE.hall[rhythm]

	-------------------------------------------------------------------------------------------------------
	-- Layout: the oval's centre, size and its outline
	-------------------------------------------------------------------------------------------------------
	local hallOut = math.min(hs.depth / 2, 9)
	local front, back = math.max(SHAPE.plaza, hallOut + 1.5), math.max(SHAPE.back, hallOut + 1.5)
	local ow = math.min(W - 2 * SHAPE.sideInset - 2 * SHAPE.edge.proud, SHAPE.oval.width)
	local od = math.min(D - front - back, SHAPE.oval.depth)
	local zc = (-hd + front + hd - back) / 2
	local screenW = math.min(SHAPE.screen.width, (ow - od) * 0.8) -- the video board on the front, if there's room

	-- A slab of the given kind between two corners.
	local function slab(name: string, min: Vector3, max: Vector3, look: Kit.Look, kind: Kit.Kind): Types.PartSpec
		if kind == "trim" then
			return Kit.trim(m, name, min, max, look)
		elseif kind == "detail" then
			return Kit.detail(m, name, min, max, look)
		end
		return Kit.box(m, name, min, max, look)
	end
	-- A pill (a stadium shape) centred on the oval, `grow` bigger than it on every side: a box and two round ends,
	-- the ends a hair inside the box's top and bottom so no faces are coplanar. 2 or 3 parts.
	local function pill(
		name: string,
		grow: number,
		y0: number,
		y1: number,
		look: Kit.Look,
		kind: Kit.Kind?
	): { Types.PartSpec }
		local L, Dp = ow + 2 * grow, od + 2 * grow
		local k: Kit.Kind = kind or "box"
		local out: { Types.PartSpec } = {}
		if L >= Dp then
			local s = (L - Dp) / 2
			if s > 0.05 then
				table.insert(
					out,
					slab(name, Vector3.new(-s, y0, zc - Dp / 2), Vector3.new(s, y1, zc + Dp / 2), look, k)
				)
			end
			table.insert(out, Kit.column(m, name .. "L", -s, zc, y0 + HAIR, y1 - HAIR, Dp, look, k))
			table.insert(out, Kit.column(m, name .. "R", s, zc, y0 + HAIR, y1 - HAIR, Dp, look, k))
		else
			local s = (Dp - L) / 2
			if s > 0.05 then
				table.insert(out, slab(name, Vector3.new(-L / 2, y0, zc - s), Vector3.new(L / 2, y1, zc + s), look, k))
			end
			table.insert(out, Kit.column(m, name .. "F", 0, zc - s, y0 + HAIR, y1 - HAIR, L, look, k))
			table.insert(out, Kit.column(m, name .. "B", 0, zc + s, y0 + HAIR, y1 - HAIR, L, look, k))
		end
		return out
	end
	-- How far the oval reaches from its centre line (z) at x.
	local function reach(x: number): number
		local r = math.min(ow, od) / 2
		local s = math.max(0, (ow - od) / 2)
		local over = math.abs(x) - s
		if ow < od or over <= 0 then
			return od / 2
		end
		return math.sqrt(math.max(0, r * r - over * over))
	end

	-------------------------------------------------------------------------------------------------------
	-- The plaza and the bowl's layers
	-------------------------------------------------------------------------------------------------------
	Kit.box(
		m,
		"Plaza",
		Vector3.new(-hw + 0.3, 0, -hd + 0.3),
		Vector3.new(hw - 0.3, 0.25, hd - 0.3),
		Kit.look(rgb(214, 210, 202), Enum.Material.Concrete)
	)
	-- The ribbon reads darker than the lit concourse under it, so the white deck between them stands out.
	local glass = Kit.glassLook(pal.glass:Lerp(Color3.new(0, 0, 0), 0.3), 0.12)
	local co = SHAPE.concourse
	for _, spec in pill("Concourse", -co.inset, -KIT.bury, co.y + 0.5, Kit.glassLook(pal.glass, 0.15)) do
		Kit.lit(spec, "window")
	end
	pill("Deck", SHAPE.deck.proud, co.y, SHAPE.deck.y, wall, "trim")
	pill("Ribbon", -SHAPE.ribbon.inset, SHAPE.deck.y - 0.5, SHAPE.ribbon.y + 0.5, glass)
	pill("Bowl", 0, SHAPE.ribbon.y, SHAPE.bowl.y, wall)
	pill("Edge", SHAPE.edge.proud, SHAPE.bowl.y - 0.05, SHAPE.edge.y, wall, "trim")
	local ld = SHAPE.led
	for _, spec in
		pill("Led", ld.proud, ld.y, ld.y + ld.thick, Kit.look(pal.wall, Enum.Material.SmoothPlastic), "detail")
	do
		Kit.lit(spec, "ledBlue")
	end

	-- The roof: two shallow stepped tiers to the top, where the picture lies.
	local rf = SHAPE.roof
	local roofLook = Kit.look(pal.roof, Enum.Material.SmoothPlastic)
	local r1 = SHAPE.edge.y + (H - SHAPE.edge.y) * rf.share
	local inset1 = math.min(rf.inset, math.min(ow, od) * 0.12)
	local inset2 = math.min(rf.inset2, math.min(ow, od) * 0.28)
	pill("Roof", -inset1, SHAPE.edge.y - 0.05, r1, roofLook)
	pill("RoofTop", -inset2, r1 - 0.05, H, roofLook)

	-------------------------------------------------------------------------------------------------------
	-- The picture on the roof
	-------------------------------------------------------------------------------------------------------
	local topL, topD = ow - 2 * inset2, od - 2 * inset2
	local pw = math.max(2, math.min(topL, topD) * SHAPE.picture.width)
	local picLook = Kit.look(pal.picture, Enum.Material.SmoothPlastic)
	if variant.crown == 2 then
		-- The county's name on a disc.
		local dd = math.min(topL, topD) * 0.8
		Kit.lit(Kit.disc(m, "PictureDisc", 0, zc, H + 0.1, dd, 0.3, picLook, "detail"), pal.night)
		local tw = math.min(topL * 0.8, dd * 1.4)
		Kit.sign(
			m,
			"RoofName",
			Vector3.new(-tw / 2, H + 0.25, zc - dd * 0.16),
			Vector3.new(tw / 2, H + 0.5, zc + dd * 0.16),
			Enum.NormalId.Top,
			"VOLTAGE COUNTY",
			pal.wall,
			rgb(30, 34, 40),
			City.districtLooks.downtown.font
		)
	else
		-- A lightning bolt across the top: a stroke down to the middle, a jog back across it, a stroke on down.
		local a = Vector2.new(-topL * 0.3, -topD * 0.4)
		local b = Vector2.new(topL * 0.2, topD * 0.03)
		local c = Vector2.new(-topL * 0.2, -topD * 0.03)
		local d = Vector2.new(topL * 0.3, topD * 0.4)
		for i, seg in { { a, b }, { b, c }, { c, d } } do
			local p0, p1 = seg[1], seg[2]
			local mid = (p0 + p1) / 2
			local dir = p1 - p0
			local yaw = math.atan2(-dir.Y, dir.X)
			Kit.lit(
				Kit.oriented(
					m,
					`Bolt{i}`,
					"block",
					CFrame.new(mid.X, H + 0.1 + i * 0.02, zc + mid.Y) * CFrame.Angles(0, yaw, 0),
					Vector3.new(dir.Magnitude + pw * 0.8, 0.3, pw),
					picLook,
					"detail"
				),
				pal.night
			)
		end
	end

	-------------------------------------------------------------------------------------------------------
	-- The stair halls: see-through glass boxes half out of the oval, zig-zag stairs inside, a white cap
	-------------------------------------------------------------------------------------------------------
	local hallGlass = Kit.look(pal.glass:Lerp(Color3.new(1, 1, 1), 0.35), Enum.Material.Glass, 0.15, 0.35)
	-- The stairs in the picture's colour, so their zig-zag reads through the glass by day.
	local stairLook = Kit.look(pal.picture, Enum.Material.SmoothPlastic)
	local st = SHAPE.stair
	local spots: { { x: number, side: number } } = {}
	local hx = math.max((ow - od) / 2, ow * 0.25)
	hx = math.min(hx, ow / 2 - hs.width / 2 - 2)
	table.insert(spots, { x = -hx, side = -1 })
	table.insert(spots, { x = hx, side = -1 })
	if hs.count == 4 then
		table.insert(spots, { x = -hx, side = 1 })
		table.insert(spots, { x = hx, side = 1 })
	end
	local hd2 = hallOut
	-- Fins round the upper bowl, a vertical rhythm over the bands, kept clear of the halls.
	local fn = SHAPE.fins
	local r0 = math.min(ow, od) / 2
	local s0 = math.abs(ow - od) / 2
	local along = ow >= od
	local perimeter = 4 * s0 + 2 * math.pi * r0
	local function outline(t: number): (Vector2, Vector2)
		-- A point on the oval's outline and its outward normal, t from 0 to the perimeter.
		local legs = { 2 * s0, math.pi * r0, 2 * s0, math.pi * r0 }
		local p: Vector2, nrm: Vector2
		if t < legs[1] then
			p, nrm = Vector2.new(-s0 + t, -r0), Vector2.new(0, -1)
		elseif t < legs[1] + legs[2] then
			local a = -math.pi / 2 + (t - legs[1]) / r0
			nrm = Vector2.new(math.cos(a), math.sin(a))
			p = Vector2.new(s0, 0) + nrm * r0
		elseif t < legs[1] + legs[2] + legs[3] then
			p, nrm = Vector2.new(s0 - (t - legs[1] - legs[2]), r0), Vector2.new(0, 1)
		else
			local a = math.pi / 2 + (t - legs[1] - legs[2] - legs[3]) / r0
			nrm = Vector2.new(math.cos(a), math.sin(a))
			p = Vector2.new(-s0, 0) + nrm * r0
		end
		if not along then
			-- The oval runs along z: swap the axes.
			p, nrm = Vector2.new(p.Y, p.X), Vector2.new(nrm.Y, nrm.X)
		end
		return p, nrm
	end
	local finLook = Kit.look(pal.wall, Enum.Material.SmoothPlastic)
	local fy0, fy1 = SHAPE.deck.y + 0.4, SHAPE.bowl.y - 0.4
	local nf = 0
	for k = 0, fn.count - 1 do
		local p, nrm = outline(perimeter * (k + 0.5) / fn.count)
		local clear = true
		for _, spot in spots do
			if math.abs(p.X - spot.x) < hs.width / 2 + 2 then
				clear = false
			end
		end
		if nrm.Y < -0.9 and math.abs(p.X) < screenW / 2 + 1 then
			clear = false -- the video board's place
		end
		if clear then
			nf += 1
			local at = p + nrm * (fn.proud / 2 - 0.3)
			Kit.oriented(
				m,
				`Fin{nf}`,
				"block",
				CFrame.new(at.X, (fy0 + fy1) / 2, zc + at.Y) * CFrame.Angles(0, math.atan2(nrm.X, nrm.Y), 0),
				Vector3.new(fn.wide, fy1 - fy0, fn.proud + 0.6),
				finLook,
				"trim"
			)
		end
	end
	for i, spot in spots do
		local zEdge = zc + spot.side * reach(spot.x)
		local x0, x1 = spot.x - hs.width / 2, spot.x + hs.width / 2
		local z0, z1 = zEdge - hd2, zEdge + hd2
		local top = math.min(hs.height, H - 2)
		local hallSpec =
			Kit.lit(Kit.box(m, `Hall{i}`, Vector3.new(x0, 0.25, z0), Vector3.new(x1, top, z1), hallGlass), "window")
		-- Slim white mullions on its three outer faces, a floor to a tile: a glass box, not a blur.
		local outerFace = if spot.side < 0 then Enum.NormalId.Front else Enum.NormalId.Back
		local mullions: { Types.TextureSpec } = {}
		for _, face in { outerFace, Enum.NormalId.Left, Enum.NormalId.Right } do
			table.insert(mullions, {
				face = Kit.face(m, face),
				image = City.textures.windowFine,
				u = SHAPE.hallMullion,
				v = st.rise,
				color = pal.wall,
			})
		end
		hallSpec.textures = mullions
		Kit.trim(
			m,
			`HallCap{i}`,
			Vector3.new(x0 - 0.6, top, z0 - 0.6),
			Vector3.new(x1 + 0.6, top + 1.4, z1 + 0.6),
			wall
		)
		-- White corner posts on its two outer corners, from the plaza to the cap.
		local zo = if spot.side < 0 then z0 else z1
		for c, x in { x0, x1 } do
			Kit.trim(
				m,
				`HallPost{i}{c}`,
				Vector3.new(x - 0.55, 0.25, zo - 0.55),
				Vector3.new(x + 0.55, top + 0.02, zo + 0.55),
				wall
			)
		end
		-- The stairs inside, in the hall's outer half, flight by flight in a zig-zag.
		local zs = zEdge + spot.side * hd2 * 0.45
		for f = 1, hs.flights do
			local y0 = 2 + (f - 1) * st.rise
			if y0 + st.rise > top - 2 then
				break
			end
			local left = f % 2 == 1
			local a = Vector3.new(if left then x0 + 2.5 else x1 - 2.5, y0, zs)
			local b = Vector3.new(if left then x1 - 2.5 else x0 + 2.5, y0 + st.rise, zs)
			Kit.strut(m, `Stair{i}{f}`, a, b, st.thick, stairLook, "detail", math.min(st.wide, hd2 * 0.8))
		end
	end

	-------------------------------------------------------------------------------------------------------
	-- Terraces toward the water, the entrance canopy and the name
	-------------------------------------------------------------------------------------------------------
	local tr = SHAPE.terrace[rhythm]
	local tw = math.max(10, (ow - od) * 0.8)
	tw = math.min(tw, ow * 0.6)
	local railLook = Kit.look(rgb(214, 236, 242), Enum.Material.Glass, 0.1, KIT.railTransparency)
	local zBack = zc + od / 2
	for lvl = 1, tr[2] do
		local y = if lvl == 1 then SHAPE.deck.y else SHAPE.ribbon.y + 0.6 + (lvl - 2) * 7
		local out = math.min(tr[1], hd - zBack - 0.6)
		if out < 1 then
			break
		end
		Kit.trim(m, `Terrace{lvl}`, Vector3.new(-tw / 2, y - 1.2, zBack - 2), Vector3.new(tw / 2, y, zBack + out), wall)
		Kit.detail(
			m,
			`TerraceRail{lvl}`,
			Vector3.new(-tw / 2 + 0.2, y, zBack + out - 0.5),
			Vector3.new(tw / 2 - 0.2, y + 3.2, zBack + out - 0.2),
			railLook
		)
	end

	local ca = SHAPE.canopy
	local cw = math.max(16, ow * ca.share)
	local cx = math.clamp(ow * 0.12, 0, ow / 2 - cw / 2 - 2) -- off-centre: the mirror's side
	local zFront = zc - od / 2
	local out = math.min(ca.out, zFront + hd - 0.6)
	Kit.canopy(m, "Canopy", cx - cw / 2, cx + cw / 2, zFront - out, zFront + 3, ca.y, ca.thick, wall)
	Kit.neonStrip(
		m,
		"CanopyLed",
		Vector3.new(cx - cw / 2, ca.y - 0.3, zFront - out + 0.1),
		Vector3.new(cx + cw / 2, ca.y - 0.05, zFront - out + 0.6),
		"ledBlue",
		pal.wall
	)
	-- The doors: a lit run of glass doors on the concourse's flat front, under the canopy.
	local straight = math.max(0, (ow - od) / 2) - 2
	local dx0, dx1 = math.max(cx - cw / 2 + 2, -straight), math.min(cx + cw / 2 - 2, straight)
	if dx1 - dx0 > 8 then
		local zDoor = zFront + co.inset
		Kit.glass(
			m,
			"Doors",
			Vector3.new(dx0, 0.25, zDoor - 0.2),
			Vector3.new(dx1, SHAPE.doors, zDoor + 0.4),
			P.window.deep,
			{
				image = City.textures.windowBold,
				faces = { Enum.NormalId.Front },
				u = 4,
				v = SHAPE.doors - 0.25,
				lines = pal.wall,
				lit = true,
				reflectance = 0.05,
			}
		)
	end
	local nw = math.min(cw * 0.8, 60)
	Kit.sign(
		m,
		"Name",
		Vector3.new(cx - nw / 2, ca.y + ca.thick, zFront - out + 0.3),
		Vector3.new(cx + nw / 2, ca.y + ca.thick + 3.4, zFront - out + 0.8),
		Enum.NormalId.Front,
		City.signNames.civic.arena,
		rgb(30, 34, 40),
		pal.wall,
		City.districtLooks.downtown.font,
		"sign"
	)
	-- The video board: a dark screen on the bowl's flat front, glowing at night.
	local sc = SHAPE.screen
	local sw = screenW
	if sw > 12 then
		Kit.lit(
			Kit.glass(
				m,
				"Screen",
				Vector3.new(-sw / 2, sc.from, zFront - 0.5),
				Vector3.new(sw / 2, sc.to, zFront + 0.4),
				rgb(24, 28, 34),
				{
					image = City.textures.windowBold,
					faces = { Enum.NormalId.Front },
					u = 2,
					v = 2,
					lines = rgb(44, 50, 58),
				}
			),
			"sign"
		)
	end
	-- At night a wash on the deck band lights the bowl's flat front in the picture's colour.
	local washHalf = math.min(ow * 0.22, straight)
	if washHalf > 6 then
		local dy = SHAPE.deck.y
		Kit.wash(m, "Wash", -washHalf, washHalf, zFront - SHAPE.deck.proud + 0.35, dy, pal.picture)
	end
end

local archetype: Types.Archetype = { id = "bayfront_arena", build = build }
return archetype
