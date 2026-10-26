--!strict
-- L3 food_truck_court (Config/CityLots; Config/CityArchetypes/food_truck_court): food trucks parked round a paved
-- court. The idea: a court of warm stone pavers, a truck with its hatch open, café tables under a sagging string of
-- lights, a lantern at the kerb; in the arts district a mural wall closes the back (stripes, a big disc and a triangle
-- in the district's hot colours) and the trucks park down the sides in front of it. While its part allowance lasts it
-- adds the mural (first in the arts district), café tables, the string of lights from the lantern to a pole at the
-- back, a second truck, a hedge along the front (the way in left open), the mural (elsewhere), the trucks' collision
-- boxes, more café tables and a bistro table. The street-level roast (2026-10-26, point 2): the painted zebra ground
-- read as a crosswalk or placeholder paint, not a venue, and two tables left the court bare, so the ground is one
-- paver material now and the tables fill it while the allowance lasts.
-- Variants: palette (pink-blue-yellow, orange-purple-cyan, cyan-black-pink, lime-yellow-purple), crown (the mural wall
-- early or late in the order outside the arts district), rhythm (trucks along the back with their hatches to the
-- road, or down the sides facing each other), mirror.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CityLots = require(ReplicatedStorage.Shared.Config.CityLots)
local Kit = require(script.Parent.Parent.Parent.Kit)
local LotKit = require(script.Parent.Parent.Parent.LotKit)
local Types = require(script.Parent.Parent.Parent.Types)

type PartSpec = Types.PartSpec
type Truck = { name: string, prop: string, x: number, z: number, yaw: number }

local rgb = Color3.fromRGB

-- The recipe, in studs.
local SHAPE = {
	-- The pavers' joints: a grid this many studs a tile, faded this much into the stone (the painted stripes it had
	-- read as a zebra crossing from every angle: the street-level roast, 2026-10-26).
	paver = Vector2.new(4, 2),
	paverFade = 0.55,
	lamp = { side = 2, front = 2 }, -- the lantern, in from the front -x corner
	truckBack = 7.5, -- a truck along the back: its middle, in from the back line...
	truckEnd = 12, -- ...and in from its side
	truckSide = 5.5, -- a truck down a side: its middle, in from its side
	truckZ = 2, -- and along z
	secondBackFrom = 52, -- a court this wide fits a second truck along the back...
	secondSideFrom = 56, -- ...and this wide a second one down the other side
	wall = { back = 0.4, thick = 1.2, height = 12, side = 3, maxWidth = 64, from = 40 },
	disc = 8,
	stringPole = { side = 1.6, back = 2.6 }, -- the festoon's pole stays at least this far in from the +x side and back
	stringDrop = 2.2, -- the festoon hangs from this far under the lantern's top
	seatStep = 11,
	seatGap = { sides = 24, back = 8 }, -- the width the trucks take from the seating
	seatRows = 2, -- rows of café tables, `seatRowStep` apart toward the road
	seatRowStep = 10,
	seatMax = 4, -- tables in a row, at most
	bistroFront = 6,
	hedge = { height = 2.4, front = 0.4, back = 2.2, side = 0.5, entrance = 14 }, -- the way in open at the -x end
}

-- The court's pavers: a warm stone in Pavement, the joints a shade darker (one per palette, so courts differ).
local PAVERS = {
	{ stone = rgb(214, 196, 170), joint = rgb(150, 132, 112) },
	{ stone = rgb(204, 190, 172), joint = rgb(140, 126, 110) },
	{ stone = rgb(222, 210, 190), joint = rgb(160, 148, 128) },
	{ stone = rgb(196, 176, 156), joint = rgb(136, 118, 100) },
}
local HEDGE = rgb(72, 116, 60)

local PALETTES = {
	{
		ground = rgb(58, 60, 64),
		paint = rgb(250, 60, 150),
		wall = rgb(40, 120, 250),
		disc = rgb(255, 214, 0),
		tri = rgb(246, 244, 238),
		cafe = "CafeSetPink",
	},
	{
		ground = rgb(70, 70, 74),
		paint = rgb(255, 120, 30),
		wall = rgb(130, 60, 220),
		disc = rgb(0, 210, 220),
		tri = rgb(150, 230, 40),
		cafe = "CafeSetMint",
	},
	{
		ground = rgb(176, 172, 164),
		paint = rgb(0, 210, 220),
		wall = rgb(30, 30, 34),
		disc = rgb(250, 60, 150),
		tri = rgb(255, 214, 0),
		cafe = "CafeSetWhite",
	},
	{
		ground = rgb(64, 60, 58),
		paint = rgb(150, 230, 40),
		wall = rgb(255, 214, 0),
		disc = rgb(130, 60, 220),
		tri = rgb(40, 120, 250),
		cafe = "CafeSetMint",
	},
}

local POLE = rgb(40, 42, 46)

local function build(m: Types.Model)
	local site = m.site
	local v = site.variant
	local pal = LotKit.pick(PALETTES, v.palette)
	local limit = LotKit.allowance(site)
	local hw, hd = site.width / 2, site.depth / 2
	local H = site.height
	local muralFirst = site.district == "arts" or v.crown == 1
	-- With a mural (or rhythm 2) the trucks park down the sides, so the back wall shows; else along the back.
	local sides = muralFirst or v.rhythm == 2

	-- The trucks: down a side, a truck's hatch (its right side) faces into the court; along the back, the road.
	local trucks: { Truck } = if sides
		then {
			{ name = "TruckA", prop = "FoodTruckA", x = -hw + SHAPE.truckSide, z = SHAPE.truckZ, yaw = 0 },
			{ name = "TruckB", prop = "FoodTruckB", x = hw - SHAPE.truckSide, z = SHAPE.truckZ, yaw = 180 },
		}
		else {
			{ name = "TruckA", prop = "FoodTruckA", x = -hw + SHAPE.truckEnd, z = hd - SHAPE.truckBack, yaw = 90 },
			{ name = "TruckB", prop = "FoodTruckB", x = hw - SHAPE.truckEnd, z = hd - SHAPE.truckBack, yaw = 90 },
		}
	local placed: { { spec: PartSpec, truck: Truck } } = {}
	local function truck(k: number)
		local t = trucks[k]
		local spec = LotKit.prop(m, t.name, t.prop, t.x, t.z, t.yaw)[1]
		table.insert(placed, { spec = spec, truck = t })
	end

	-- The core: the paved ground, a truck and the lantern.
	local pavers = LotKit.pick(PAVERS, v.palette)
	local ground = LotKit.floor(m, "Ground", -hw, -hd, hw, hd, Kit.look(pavers.stone, Enum.Material.Pavement))
	LotKit.texture(m, ground, LotKit.images.grid, SHAPE.paver.X, SHAPE.paver.Y, pavers.joint, nil, nil, SHAPE.paverFade)
	truck(1)
	LotKit.lamp(m, "Lamp", -hw + SHAPE.lamp.side, -hd + SHAPE.lamp.front, H, "lantern", POLE)

	-- The mural wall: stripes painted on a brick wall at the back, a big disc and a triangle on it. 3 parts.
	local function mural()
		local w = SHAPE.wall
		local half = math.min(hw - w.side, w.maxWidth / 2)
		local z1 = hd - w.back
		local z0 = z1 - w.thick
		local height = math.min(w.height, H - 1)
		local wall = Kit.box(
			m,
			"Wall",
			Vector3.new(-half, -0.5, z0),
			Vector3.new(half, height, z1),
			Kit.look(pal.wall, Enum.Material.Brick)
		)
		LotKit.texture(m, wall, LotKit.images.bars, 8, height + 0.5, pal.paint, { Enum.NormalId.Front }, 0)
		local d = math.min(SHAPE.disc, height - 2, half)
		local dx = -half * 0.35
		Kit.tube(
			m,
			"Disc",
			Vector3.new(dx, height / 2 + 0.5, z0 - 0.2),
			Vector3.new(dx, height / 2 + 0.5, z0 - 0.05),
			d,
			Kit.look(pal.disc, Enum.Material.SmoothPlastic)
		)
		local tx = half * 0.15
		Kit.triangle(
			m,
			"Triangle",
			tx,
			1,
			math.min(half - 0.5, tx + height),
			height - 1,
			z0 - 0.12,
			0.07,
			"x1y0",
			Kit.look(pal.tri, Enum.Material.SmoothPlastic)
		)
	end
	local canMural = site.width >= SHAPE.wall.from

	-- The extras, in order, while the allowance lasts.
	local muralDone = false
	if muralFirst and canMural and LotKit.fits(m, limit, 3) then
		mural()
		muralDone = true
	end
	-- Café tables across the middle of the court, in rows toward the road: the first row now, the rest late.
	local gap = if sides then SHAPE.seatGap.sides else SHAPE.seatGap.back
	local seats = math.clamp(math.floor((site.width - gap) / SHAPE.seatStep), 1, SHAPE.seatMax)
	local seatZ = if sides then -hd * 0.25 else -hd * 0.3
	local function tables(row: number)
		local z = seatZ - (row - 1) * SHAPE.seatRowStep
		-- A table set reaches about 4.5 studs from its middle: the row stays clear of the front hedge.
		if z - 4.5 < -hd + SHAPE.hedge.back + 0.5 then
			return
		end
		for s = 1, seats do
			if LotKit.fits(m, limit, 1) then
				local x = (s - (seats + 1) / 2) * SHAPE.seatStep + (row - 1) * SHAPE.seatStep / 2
				if math.abs(x) <= hw - SHAPE.seatStep / 2 then
					LotKit.prop(m, `Cafe{row}_{s}`, pal.cafe, x, z, (s + row) % 4 * 90)
				end
			end
		end
	end
	tables(1)
	-- String lights: a short festoon from the lantern in over the seating to a pole. 3 parts.
	if LotKit.fits(m, limit, 3) then
		local p = SHAPE.stringPole
		local span = CityLots.festoon.span
		local lx, lz = -hw + SHAPE.lamp.side, -hd + SHAPE.lamp.front
		local px = math.min(hw - p.side, lx + span.X)
		local pz = math.min(hd - p.back, lz + span.Y)
		LotKit.festoon(m, "Lights", lx, lz, H - SHAPE.stringDrop, px, pz, H - 1, POLE)
	end
	local second = site.width >= (if sides then SHAPE.secondSideFrom else SHAPE.secondBackFrom)
	if second and LotKit.fits(m, limit, 1) then
		truck(2)
	end
	-- A hedge along the front line, the way in left open at the lantern's end. 1 part.
	if site.width > SHAPE.hedge.entrance + 8 and LotKit.fits(m, limit, 1) then
		local h = SHAPE.hedge
		Kit.box(
			m,
			"Hedge",
			Vector3.new(-hw + h.side + h.entrance, -0.3, -hd + h.front),
			Vector3.new(hw - h.side, LotKit.top + h.height, -hd + h.back),
			Kit.look(HEDGE, Enum.Material.Grass)
		)
	end
	-- A late mural only behind trucks parked down the sides (along the back they would hide it).
	if not muralDone and sides and canMural and LotKit.fits(m, limit, 3) then
		mural()
	end
	for _, p in placed do
		if LotKit.fits(m, limit, 1) then
			LotKit.collider(m, `{p.truck.name}Box`, p.spec, p.truck.prop)
		end
	end
	for row = 2, SHAPE.seatRows do
		tables(row)
	end
	if LotKit.fits(m, limit, 1) then
		LotKit.prop(m, "Bistro", "BistroPair", hw * 0.2, -hd + SHAPE.bistroFront, 0)
	end
end

local archetype: Types.Archetype = { id = "food_truck_court", build = build }
return archetype
