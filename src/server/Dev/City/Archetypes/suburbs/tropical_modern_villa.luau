--!strict
-- R06 tropical_modern_villa (docs/city/ARCHETYPES.md §7, R06): the new Miami island house. Crisp white volumes on a
-- limestone terrace: a ground floor that is mostly a glass room (lit like a lantern at night) beside a white garage,
-- and an upper box that slides out past it over the pool. The upper box's street face is a deep white picture frame
-- round a wall of glass, a screen of vertical wood slats standing in its reveal; its pool end is glass too. A tall
-- stone-clad blade wall runs back from the street between the garage and the glass room, right through the razor-thin
-- roof slab and past it, the house's spine. The roof slab overhangs three studs all round with a warm LED line under its
-- front edge. A lap pool under the cantilever, a white garden wall and a hedge for privacy, a pale drive, a planter by
-- the tall pivot door.
--
-- What makes it itself: two crisp white boxes, the upper one sliding out over a pool, under a razor-thin roof, with a
-- wood screen.
-- Placement, sizes, heights and its budget: Config/CityArchetypes/tropical_modern_villa.
-- Variants: palette (3: ipe slats and a charcoal slate blade, pale teak and a travertine blade, charcoal aluminium and
-- a dark basalt blade), crown (1 the roof slab over a long cantilever, 2 a shorter upper box and the roof running on as
-- a pergola of white beams over the pool), rhythm (1 slats on the upper box, 2 on the ground floor's glass), mirror
-- (pool left or right). There's a garage only on sites wide enough for one.
--
-- Previewing: from the street at eye height and from the pool corner. Check the cantilever reads (a deep shadow under
-- the upper box over the pool), the picture frame's reveal holds a shadow on the glass, the slats stand clear of the
-- glass and through the frame's plane, the blade pierces the roof slab cleanly and stays the only thing above it, the
-- roof slab is thin and crisp with its shadow line, the pergola's beams meet the slab. At night: the glass room, the
-- framed glass and the pool end glow, and the LED line under the roof edge is warm.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local City = require(ReplicatedStorage.Shared.Config.City)
local Kit = require(script.Parent.Parent.Parent.Kit)
local Types = require(script.Parent.Parent.Parent.Types)

local KIT = City.kit
local rgb = Color3.fromRGB

-- The recipe, in studs.
local SHAPE = {
	side = 1.5,
	yard = { 0.2, 7, 11 },
	ground = 11, -- the upper floor's level
	groundWidth = { 0.6, 17, 26 }, -- share of the width, clamped
	depth = { 0.38, 16, 20 }, -- the upper box's depth; the ground floor is 3 shallower at the front
	frontIn = 3, -- the ground floor under the cantilevered front
	deck = 0.4, -- the limestone terrace
	garage = 11,
	garageFrom = 20, -- a garage when the ground floor is at least this wide
	blade = { thick = 1.2, out = 3.3, rise = 0.8 }, -- the stone spine: past the roof's front edge, over the roof
	frame = { depth = 1.2, side = 1.2, sill = 1.1, head = 1.1 }, -- the upper box's picture frame
	roof = 0.8,
	roofOver = 3,
	edge = 1.7, -- the upper box's pool end from the site's side line
	pergolaGap = 2, -- crown 2: the upper box ends this far past the glass room
	slats = 6,
	slat = { width = 0.6, proud = 1.7, gap = 1.5 },
	beams = 4,
}

-- Slats (and their material), the blade's stone, the glass.
local PALETTES = {
	{
		slat = rgb(139, 90, 60),
		slatMaterial = Enum.Material.WoodPlanks,
		blade = rgb(78, 82, 86),
		bladeMaterial = Enum.Material.Slate,
		glass = rgb(96, 128, 138),
	},
	{
		slat = rgb(176, 128, 84),
		slatMaterial = Enum.Material.WoodPlanks,
		blade = rgb(214, 202, 178),
		bladeMaterial = Enum.Material.Limestone,
		glass = rgb(84, 120, 132),
	},
	{
		slat = rgb(72, 76, 82),
		slatMaterial = Enum.Material.Metal,
		blade = rgb(58, 60, 62),
		bladeMaterial = Enum.Material.Basalt,
		glass = rgb(70, 104, 118),
	},
}

local WHITE = rgb(247, 247, 245)
local STONE = rgb(231, 225, 212)
local DOOR = rgb(120, 82, 56)
local GARAGE = rgb(150, 104, 70)
local CONCRETE = rgb(226, 222, 214)
local HEDGE = rgb(86, 138, 64) -- darker greens read as black boxes in the game's light
local LED = rgb(236, 234, 228)

local function share(x: number, rule: { number }): number
	return math.clamp(x * rule[1], rule[2], rule[3])
end

local function build(m: Types.Model)
	local site = m.site
	local variant = site.variant
	local pal = PALETTES[math.clamp(variant.palette, 1, #PALETTES)]
	local pergola = variant.crown == 2
	local W, D, H = site.width, site.depth, site.height
	local hw, hd = W / 2, D / 2

	local white = Kit.look(WHITE, Enum.Material.SmoothPlastic)
	local slat = Kit.look(pal.slat, pal.slatMaterial)
	local fine = function(tall: number, faces: { Enum.NormalId }): Kit.GlassOptions
		-- Mullions only: one overlay tile well taller than the glass, so its spandrel falls past the part's edge.
		return {
			image = City.textures.windowFine,
			faces = faces,
			u = 4,
			v = tall * 1.6 + 2,
			lines = WHITE,
			lit = true,
			reflectance = 0.2,
		}
	end

	-------------------------------------------------------------------------------------------------------
	-- The plan, drawn with the garage and the blade on the left and the pool on the right (the kit mirrors it)
	-------------------------------------------------------------------------------------------------------
	local X0, X1 = -hw + SHAPE.side, hw - SHAPE.side
	local avail = X1 - X0
	local Wg = share(avail, SHAPE.groundWidth)
	local gx0 = X0 + 1
	local gx1 = gx0 + Wg
	local garage = Wg >= SHAPE.garageFrom
	local bx0 = if garage then gx0 + SHAPE.garage else gx0 -- the blade
	local bx1 = bx0 + SHAPE.blade.thick
	local zF = -hd + share(D, SHAPE.yard) -- the upper box's front (its frame's face)
	local Du = share(D, SHAPE.depth)
	local zB = zF + Du -- both boxes' back
	local zG = zF + SHAPE.frontIn -- the ground floor's front
	local G = SHAPE.ground
	local roofY = H - SHAPE.roof
	local ux0 = bx1
	local ux1 = if pergola then math.min(X1 - SHAPE.edge, gx1 + SHAPE.pergolaGap) else X1 - SHAPE.edge
	local fl = SHAPE.deck

	-------------------------------------------------------------------------------------------------------
	-- The terrace and the pool, the ground floor: garage, the stone blade, the glass room
	-------------------------------------------------------------------------------------------------------
	Kit.box(
		m,
		"Deck",
		Vector3.new(gx0 - 0.6, -KIT.bury, zG - 2.5),
		Vector3.new(X1 - 0.2, fl, zB + 1),
		Kit.look(STONE, Enum.Material.Limestone)
	)
	local poolLength = math.min(Du - 4, 22)
	Kit.pool(m, "Pool", Vector3.new(gx1 + 1.4, 0, zG - 1), Vector3.new(X1 - 1.4, 0, zG - 1 + poolLength), fl)
	if garage then
		Kit.box(m, "Garage", Vector3.new(gx0, -KIT.bury, zG), Vector3.new(bx0 + 0.05, G + 0.6, zB), white)
		local door = Kit.trim(
			m,
			"GarageDoor",
			Vector3.new(gx0 + 1.2, fl, zG - 0.15),
			Vector3.new(bx0 - 1.2, 8.6, zG + 0.1),
			Kit.look(GARAGE, Enum.Material.WoodPlanks)
		)
		door.textures = {
			{
				face = Enum.NormalId.Front,
				image = City.textures.slabLine,
				u = 8,
				v = 0.7,
				color = GARAGE:Lerp(Color3.new(0, 0, 0), 0.4),
			},
		}
	end
	-- The blade: stone, from in front of the roof's edge back through the house and up past the roof slab.
	Kit.box(
		m,
		"Blade",
		Vector3.new(bx0, -KIT.bury, zF - SHAPE.blade.out),
		Vector3.new(bx1, H + SHAPE.blade.rise, zB - 1),
		Kit.look(pal.blade, pal.bladeMaterial)
	)
	Kit.glass(
		m,
		"Room",
		Vector3.new(bx1, fl, zG),
		Vector3.new(gx1, G - 0.02, zB),
		pal.glass,
		fine(G - fl, { Enum.NormalId.Front, Enum.NormalId.Right, Enum.NormalId.Back })
	)
	-- A tall wood pivot door at the glass room's front, by the blade.
	Kit.trim(
		m,
		"Door",
		Vector3.new(bx1 + 0.6, fl, zG - 0.25),
		Vector3.new(bx1 + 3.2, G - 1.2, zG + 0.1),
		Kit.look(DOOR, Enum.Material.WoodPlanks)
	)

	-------------------------------------------------------------------------------------------------------
	-- The upper box: a deep white frame round its glass front, glass at the pool end, the slats, the razor roof
	-------------------------------------------------------------------------------------------------------
	local fr = SHAPE.frame
	local face = zF + fr.depth -- the glass's plane, behind the frame
	Kit.box(m, "Upper", Vector3.new(ux0, G, face), Vector3.new(ux1, roofY, zB), white)
	Kit.skin(m, "Frame", "front", face, ux0, ux1, G, roofY, fr.depth, white, {
		{ a0 = ux0 + fr.side, a1 = ux1 - fr.side, y0 = G + fr.sill, y1 = roofY - fr.head, lit = true },
	}, {
		glass = pal.glass,
		panes = { image = City.textures.windowFine, u = 3.2, lines = WHITE, reflectance = 0.2 },
		kind = "box",
	})
	Kit.glass(
		m,
		"PoolEnd",
		Vector3.new(ux1 - 0.3, G + fr.sill, face + 1),
		Vector3.new(ux1 + 0.06, roofY - fr.head, zB - 1.5),
		pal.glass,
		fine(roofY - fr.head - G - fr.sill, { Enum.NormalId.Right })
	)
	local s = SHAPE.slat
	local span = (SHAPE.slats - 1) * s.gap
	-- As many slats as fit between a0 and a1 at about their gap, at most SHAPE.slats.
	local function count(a0: number, a1: number): number
		return math.clamp(math.floor((a1 - a0) / s.gap + 1e-6) + 1, 3, SHAPE.slats)
	end
	if variant.rhythm ~= 2 then
		-- In the frame's reveal, standing through its plane, clear of the jambs.
		local a = ux0 + fr.side + 0.9
		local a1 = math.min(a + span, ux1 - fr.side - 0.9)
		Kit.fins(
			m,
			"Slat",
			"front",
			face - 0.06,
			a,
			a1,
			count(a, a1),
			G + fr.sill + 0.05,
			roofY - fr.head - 0.05,
			s.proud,
			s.width,
			slat
		)
	else
		local a = bx1 + 4.2
		local a1 = math.min(a + span, gx1 - 0.6)
		Kit.fins(m, "Slat", "front", zG, a, a1, count(a, a1), fl + 0.2, G - 0.6, s.proud, s.width, slat)
	end
	local o = SHAPE.roofOver
	local roofX0 = bx0 - 2
	local roofX1 = if pergola then ux1 + 1.2 else ux1 + o
	Kit.box(m, "Roof", Vector3.new(roofX0, roofY, zF - o), Vector3.new(roofX1, H, zB + o), white)
	Kit.neonStrip(
		m,
		"Soffit",
		Vector3.new(roofX0 + 0.4, roofY - 0.2, zF - o + 0.15),
		Vector3.new(roofX1 - 0.4, roofY, zF - o + 0.45),
		"neonAmber", -- a warm line; the pale streetlight kind turned white-hot
		LED
	)
	if pergola then
		-- The roof runs on over the pool as white beams, tied by an edge beam on one slim column.
		local px0, px1 = roofX1 - 0.1, X1 + 1.3
		local z0, z1 = zF - o + 0.6, zB + o - 0.6
		for i = 1, SHAPE.beams do
			local z = z0 + (z1 - z0) * (i - 1) / (SHAPE.beams - 1)
			Kit.trim(m, `Beam{i}`, Vector3.new(px0, H - 0.7, z - 0.35), Vector3.new(px1, H - 0.05, z + 0.35), white)
		end
		Kit.trim(
			m,
			"EdgeBeam",
			Vector3.new(px1 - 0.8, H - 0.75, z0 - 0.35),
			Vector3.new(px1, H - 0.02, z1 + 0.35),
			white
		)
		Kit.column(m, "Column", px1 - 0.4, z1, 0, H - 0.75, 0.6, white)
	end

	-------------------------------------------------------------------------------------------------------
	-- The lot: a pale drive to the garage, a walk to the door, a white wall and a hedge before the pool, a planter
	-------------------------------------------------------------------------------------------------------
	local concrete = Kit.look(CONCRETE, Enum.Material.Concrete)
	if garage then
		Kit.detail(
			m,
			"Drive",
			Vector3.new(gx0 + 0.6, 0.02, -hd + 0.2),
			Vector3.new(bx0 - 0.6, 0.14, zG - 2.55),
			concrete
		)
	end
	Kit.detail(m, "Walk", Vector3.new(bx1 + 0.4, 0.02, -hd + 0.2), Vector3.new(bx1 + 3.4, 0.14, zG - 2.55), concrete)
	local wallX0 = math.max(gx1 + 0.2, bx1 + 4)
	if X1 + 1 - wallX0 >= 3 then
		Kit.box(m, "Wall", Vector3.new(wallX0, -KIT.bury, -hd + 1.2), Vector3.new(X1 + 1, 3, -hd + 2), white)
		Kit.trim(
			m,
			"Hedge",
			Vector3.new(wallX0 + 0.2, 0, -hd + 2.05),
			Vector3.new(X1 + 0.8, 5.2, -hd + 3.6),
			Kit.look(HEDGE, Enum.Material.Grass)
		)
	end
	if variant.rhythm ~= 2 then
		Kit.planter(m, "Planter", Vector3.new(bx1 + 3.8, fl, zG - 2.3), Vector3.new(bx1 + 6.6, 1.6, zG - 0.8), white)
	end
end

local archetype: Types.Archetype = { id = "tropical_modern_villa", build = build }
return archetype
