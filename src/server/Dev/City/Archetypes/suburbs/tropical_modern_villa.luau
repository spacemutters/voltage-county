--!strict
-- R06 tropical_modern_villa (docs/city/ARCHETYPES.md §7, R06): the new Miami house. Two crisp white boxes: a ground
-- floor that is mostly a glass room (lit like a lantern at night) beside a white garage, and an upper box that slides
-- out past it over the pool, its front cantilevered over the entrance. A corner window wraps the upper box's street
-- corner behind a screen of vertical wood slats; a razor-thin white roof slab overhangs three studs all round with a
-- warm LED line under its front edge. A limestone deck with a lap pool under the cantilever, a white garden wall and
-- a hedge for privacy, a pale drive to the garage, a planter by the pivot door.
--
-- What makes it itself: two crisp white boxes, the upper one sliding out over a pool, under a razor-thin roof, with a
-- wood screen.
-- Placement, sizes, heights and its budget: Config/CityArchetypes/tropical_modern_villa.
-- Variants: palette (3: ipe slats with blue-green glass, pale teak, charcoal aluminium), crown (1 the roof slab over a
-- long cantilever, 2 a shorter upper box and the roof running on as a pergola of white beams over the pool), rhythm
-- (1 slats on the upper box, 2 on the ground floor's glass), mirror (pool left or right).
--
-- Previewing: from the street at eye height and from the pool corner. Check the cantilever reads (a deep shadow
-- under the upper box over the pool), the roof slab is thin and crisp with its shadow line, the slats stand clear of
-- the glass, the pergola's beams meet the slab. At night: the glass room and the corner window glow and the LED line
-- under the roof edge is warm.

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
	garage = 11,
	garageFrom = 20, -- a garage when the ground floor is at least this wide
	roof = 0.8,
	roofOver = 3,
	edge = 1.7, -- the upper box's pool end from the site's side line
	pergolaGap = 2, -- crown 2: the upper box ends this far past the glass room
	slats = 6,
	slat = { width = 0.6, proud = 1.8, gap = 1.5 },
	beams = 4,
}

local PALETTES = {
	{ slat = rgb(139, 90, 60), slatMaterial = Enum.Material.WoodPlanks, glass = rgb(96, 128, 138) },
	{ slat = rgb(176, 128, 84), slatMaterial = Enum.Material.WoodPlanks, glass = rgb(84, 120, 132) },
	{ slat = rgb(72, 76, 82), slatMaterial = Enum.Material.Metal, glass = rgb(70, 104, 118) },
}

local WHITE = rgb(247, 247, 245)
local STONE = rgb(231, 225, 212)
local DOOR = rgb(120, 82, 56)
local GARAGE = rgb(68, 72, 78)
local CONCRETE = rgb(226, 222, 214)
local HEDGE = rgb(54, 104, 58)
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

	-------------------------------------------------------------------------------------------------------
	-- The plan, drawn with the pool on the right (the kit mirrors it)
	-------------------------------------------------------------------------------------------------------
	local X0, X1 = -hw + SHAPE.side, hw - SHAPE.side
	local avail = X1 - X0
	local Wg = share(avail, SHAPE.groundWidth)
	local gx0 = X0 + 1
	local gx1 = gx0 + Wg
	local zF = -hd + share(D, SHAPE.yard) -- the upper box's front
	local Du = share(D, SHAPE.depth)
	local zB = zF + Du -- both boxes' back
	local zG = zF + SHAPE.frontIn -- the ground floor's front
	local G = SHAPE.ground
	local roofY = H - SHAPE.roof
	local ux1 = if pergola then math.min(X1 - SHAPE.edge, gx1 + SHAPE.pergolaGap) else X1 - SHAPE.edge
	local ux0 = math.max(gx0 + 2, ux1 - (Wg + 4))
	local garage = Wg >= SHAPE.garageFrom
	local lx0 = if garage then gx0 + SHAPE.garage else gx0 -- the glass room's left end

	-------------------------------------------------------------------------------------------------------
	-- The deck and the pool, the ground floor: garage and glass room
	-------------------------------------------------------------------------------------------------------
	Kit.box(
		m,
		"Deck",
		Vector3.new(gx0 - 0.6, -KIT.bury, zG - 2.5),
		Vector3.new(X1 - 0.2, 0.4, zB + 1),
		Kit.look(STONE, Enum.Material.Limestone)
	)
	local poolLength = math.min(Du - 4, 22)
	Kit.pool(m, "Pool", Vector3.new(gx1 + 1.4, 0, zG - 1), Vector3.new(X1 - 1.4, 0, zG - 1 + poolLength), 0.4)
	if garage then
		Kit.box(m, "Garage", Vector3.new(gx0, -KIT.bury, zG), Vector3.new(lx0, G, zB), white)
		local door = Kit.trim(
			m,
			"GarageDoor",
			Vector3.new(gx0 + 1.2, 0.4, zG - 0.15),
			Vector3.new(lx0 - 1.2, 8.4, zG + 0.1),
			Kit.look(GARAGE, Enum.Material.Metal)
		)
		door.textures = {
			{ face = Enum.NormalId.Front, image = City.textures.slabLine, u = 8, v = 1.3, color = rgb(110, 114, 120) },
		}
	end
	Kit.glass(m, "Room", Vector3.new(lx0, 0.4, zG), Vector3.new(gx1, G - 0.02, zB), pal.glass, {
		image = City.textures.windowFine,
		faces = if garage
			then { Enum.NormalId.Front, Enum.NormalId.Right, Enum.NormalId.Back }
			else { Enum.NormalId.Front, Enum.NormalId.Right, Enum.NormalId.Back, Enum.NormalId.Left },
		u = 4,
		v = G - 0.42,
		lines = WHITE,
		lit = true,
		reflectance = 0.2,
	})
	-- A tall wood pivot door at the glass room's front.
	Kit.trim(
		m,
		"Door",
		Vector3.new(lx0 + 0.6, 0.4, zG - 0.25),
		Vector3.new(lx0 + 3.2, G - 1.2, zG + 0.1),
		Kit.look(DOOR, Enum.Material.WoodPlanks)
	)

	-------------------------------------------------------------------------------------------------------
	-- The upper box, its wrapped corner window, the slats, the razor roof and its LED line
	-------------------------------------------------------------------------------------------------------
	Kit.box(m, "Upper", Vector3.new(ux0, G, zF), Vector3.new(ux1, roofY, zB), white)
	Kit.glass(
		m,
		"Corner",
		Vector3.new(ux0 + 1.5, G + 2.2, zF - 0.06),
		Vector3.new(ux1 + 0.06, roofY - 2.2, zB - 1.5),
		pal.glass,
		{
			image = City.textures.windowFine,
			faces = { Enum.NormalId.Front, Enum.NormalId.Right },
			u = 3.2,
			v = roofY - 4.4 - G,
			lines = WHITE,
			lit = true,
			reflectance = 0.2,
		}
	)
	-- A slim slot on the far side.
	Kit.glass(
		m,
		"Slot",
		Vector3.new(ux0 - 0.06, G + 1.5, zF + 2),
		Vector3.new(ux0 + 0.3, roofY - 1.5, zF + 3.6),
		pal.glass,
		{ lit = true }
	)
	local s = SHAPE.slat
	local span = (SHAPE.slats - 1) * s.gap
	if variant.rhythm ~= 2 then
		Kit.fins(
			m,
			"Slat",
			"front",
			zF,
			ux0 + 1.2,
			ux0 + 1.2 + span,
			SHAPE.slats,
			G + 0.8,
			roofY - 0.8,
			s.proud,
			s.width,
			slat
		)
	else
		local a = lx0 + 4.2
		Kit.fins(
			m,
			"Slat",
			"front",
			zG,
			a,
			math.min(a + span, gx1 - 0.6),
			SHAPE.slats,
			0.6,
			G - 0.6,
			s.proud,
			s.width,
			slat
		)
	end
	local o = SHAPE.roofOver
	local roofX1 = if pergola then ux1 + 1.2 else ux1 + o
	Kit.box(m, "Roof", Vector3.new(ux0 - o, roofY, zF - o), Vector3.new(roofX1, H, zB + o), white)
	Kit.neonStrip(
		m,
		"Soffit",
		Vector3.new(ux0 - o + 0.4, roofY - 0.2, zF - o + 0.15),
		Vector3.new(roofX1 - 0.4, roofY, zF - o + 0.45),
		"neonAmber", -- a warm line; the pale streetlight kind turned white-hot
		LED
	)
	if pergola then
		-- The roof runs on over the pool as white beams, tied by an edge beam on one slim column.
		local bx0, bx1 = roofX1 - 0.1, X1 + 1.3
		local z0, z1 = zF - o + 0.6, zB + o - 0.6
		for i = 1, SHAPE.beams do
			local z = z0 + (z1 - z0) * (i - 1) / (SHAPE.beams - 1)
			Kit.trim(m, `Beam{i}`, Vector3.new(bx0, H - 0.7, z - 0.35), Vector3.new(bx1, H - 0.05, z + 0.35), white)
		end
		Kit.trim(
			m,
			"EdgeBeam",
			Vector3.new(bx1 - 0.8, H - 0.75, z0 - 0.35),
			Vector3.new(bx1, H - 0.02, z1 + 0.35),
			white
		)
		Kit.column(m, "Column", bx1 - 0.4, z1, 0, H - 0.75, 0.6, white)
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
			Vector3.new(lx0 - 0.6, 0.14, zG - 2.55),
			concrete
		)
	end
	Kit.detail(m, "Walk", Vector3.new(lx0 + 0.4, 0.02, -hd + 0.2), Vector3.new(lx0 + 3.4, 0.14, zG - 2.55), concrete)
	local wallX0 = math.max(gx1 + 0.2, lx0 + 4)
	if X1 + 1 - wallX0 >= 3 then
		Kit.box(m, "Wall", Vector3.new(wallX0, -KIT.bury, -hd + 1.2), Vector3.new(X1 + 1, 4.2, -hd + 2), white)
		Kit.trim(
			m,
			"Hedge",
			Vector3.new(wallX0 + 0.2, 0, -hd + 2.05),
			Vector3.new(X1 + 0.8, 5.6, -hd + 3.6),
			Kit.look(HEDGE, Enum.Material.LeafyGrass)
		)
	end
	if variant.rhythm ~= 2 then
		Kit.planter(m, "Planter", Vector3.new(lx0 + 3.8, 0.4, zG - 2.3), Vector3.new(lx0 + 6.6, 1.6, zG - 0.8), white)
	end
end

local archetype: Types.Archetype = { id = "tropical_modern_villa", build = build }
return archetype
