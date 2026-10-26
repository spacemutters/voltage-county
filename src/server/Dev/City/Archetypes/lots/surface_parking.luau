--!strict
-- L1 surface_parking (Config/CityLots; Config/CityArchetypes/surface_parking): a surface car park on open plots. The idea
-- you read at 70 mph: rows of crisp painted stalls on dark asphalt behind a clipped hedge, a light pole over them.
-- While its part allowance lasts (Dev/City/LotKit allowance) it builds: the asphalt, the back row's stall lines and a
-- lamp (the core), then the front row's lines, the back row's wheel stops, the front hedge with the way in left open at
-- one end, a pay booth by the way in, the front row's wheel stops, a P pylon, a palm island and a second lamp.
-- Its stalls go to the parked cars: stalls(site) lists them (less the ones the booth and the island take) for
-- Dev/City/Street Parking.fillStalls.
-- Variants: palette (fresh black asphalt with white lines, faded grey with yellow stops, warm charcoal with yellow
-- lines), crown (the lamps: shoebox heads, twin heads, globes), rhythm (the island mid-row or at the far end), mirror.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local City = require(ReplicatedStorage.Shared.Config.City)
local Kit = require(script.Parent.Parent.Parent.Kit)
local LotKit = require(script.Parent.Parent.Parent.LotKit)
local Types = require(script.Parent.Parent.Parent.Types)

type Site = Types.Site
type Row = { z0: number, z1: number }

local P = City.palettes
local rgb = Color3.fromRGB

-- The recipe, in studs.
local SHAPE = {
	strip = 2.5, -- the planted strip along the front line
	stall = Vector2.new(9.8, 19.5), -- a stall's width and length (the parked cars' stall size, Config/CityStreet)
	aisle = 11, -- the drive between two rows, at least
	endGap = 1.2, -- rows stop at least this far in from the sides
	backGap = 0.5, -- the back row's heads stop this far in from the back line
	poleIn = 1.2, -- lamps stand this far in from the back line
	poleSide = 3.3, -- and at least this far in from the sides (a twin head reaches 3 each way)
	stopIn = 1.6, -- wheel stops' middle, from a stall's head
	hedge = { height = 2.6, front = 0.4, back = 2.2, side = 0.5 },
	entrance = 18, -- the hedge leaves the way in open at the +x end (as drawn)
	booth = { x = 7.6, w = 4.6, d = 4.6, front = 0.6, height = 7, roof = 0.6, over = 0.6 }, -- x: its middle, from +x
	sign = { x = 1.9, w = 2.4, d = 0.8, front = 0.3, height = 8 }, -- the P pylon, its middle in from the +x side
	island = { w = 4.6, top = 0.65, inset = 0.5 },
	palmWant = 40, -- an island palm stands as tall as the site lets it, up to this
	secondLampFrom = 90, -- a lot this wide gets a second lamp
}

local PALETTES = {
	{
		asphalt = rgb(46, 48, 52),
		lines = rgb(240, 240, 234),
		stops = rgb(214, 210, 200),
		booth = P.deco.white,
		trim = P.deco.aqua,
	},
	{
		asphalt = rgb(74, 76, 80),
		lines = rgb(244, 244, 238),
		stops = rgb(236, 190, 60),
		booth = P.deco.mint,
		trim = P.deco.white,
	},
	{
		asphalt = rgb(60, 58, 56),
		lines = rgb(246, 206, 72),
		stops = rgb(220, 216, 206),
		booth = P.deco.pink,
		trim = P.deco.white,
	},
}

local LAMPS: { LotKit.LampStyle } = { "shoebox", "twin", "globe" }
local POLES = { rgb(66, 70, 76), rgb(66, 70, 76), rgb(236, 236, 230) }
local HEDGE = rgb(64, 108, 56)
local SIGN = { board = rgb(36, 92, 170), text = rgb(250, 250, 248) }

-- The extras in the order they are added while the allowance lasts, and what each costs. The core is 4 parts.
local CORE = 4
local EXTRAS: { { name: string, cost: number } } = {
	{ name = "frontLines", cost = 1 },
	{ name = "backStops", cost = 1 },
	{ name = "hedge", cost = 1 },
	{ name = "booth", cost = 2 },
	{ name = "frontStops", cost = 1 },
	{ name = "sign", cost = 1 },
	{ name = "island", cost = 3 },
	{ name = "lamp2", cost = 2 },
}

type Layout = {
	hw: number,
	hd: number,
	x0: number,
	x1: number,
	n: number, -- stalls in a row
	every: number, -- a stall's width
	back: Row,
	front: Row?,
	has: { [string]: boolean }, -- the extras built
	island: number?, -- the back-row stall the island takes
}

-- Where everything goes, and which extras the allowance pays for: build() and stalls() both follow it.
local function layout(site: Site): Layout
	local hw, hd = site.width / 2, site.depth / 2
	-- Whole stalls of the parked cars' width, centred; what is left over is margin at the two ends.
	local n = math.max(1, math.floor((site.width - 2 * SHAPE.endGap) / SHAPE.stall.X + 1e-6))
	local x0, x1 = -n * SHAPE.stall.X / 2, n * SHAPE.stall.X / 2
	local backTop = hd - SHAPE.backGap
	local back: Row = { z0 = backTop - SHAPE.stall.Y, z1 = backTop }
	local front: Row? = nil
	local frontStart = -hd + SHAPE.strip
	if frontStart + SHAPE.stall.Y + SHAPE.aisle <= back.z0 + 1e-6 then
		front = { z0 = frontStart, z1 = frontStart + SHAPE.stall.Y }
	end
	local can: { [string]: boolean } = {
		frontLines = front ~= nil,
		backStops = true,
		hedge = site.width > SHAPE.entrance + 6,
		booth = site.width >= 30,
		frontStops = front ~= nil,
		sign = true,
		island = n >= 3,
		lamp2 = site.width >= SHAPE.secondLampFrom,
	}
	local limit = LotKit.allowance(site)
	local used = CORE
	local has: { [string]: boolean } = {}
	for _, extra in EXTRAS do
		if can[extra.name] and used + extra.cost <= limit then
			has[extra.name] = true
			used += extra.cost
		end
	end
	local island: number? = nil
	if has.island then
		island = if site.variant.rhythm == 2 then 1 else math.ceil(n / 2)
	end
	return {
		hw = hw,
		hd = hd,
		x0 = x0,
		x1 = x1,
		n = n,
		every = SHAPE.stall.X,
		back = back,
		front = front,
		has = has,
		island = island,
	}
end

-- The middle of stall k of a row, along x.
local function stallX(l: Layout, k: number): number
	return l.x0 + l.every * (k - 0.5)
end

-- The booth's x range, roof included.
local function boothSpan(l: Layout): (number, number)
	local b = SHAPE.booth
	local x = l.hw - b.x
	return x - b.w / 2 - b.over, x + b.w / 2 + b.over
end

-- Whether front-row stall k is under the booth.
local function underBooth(l: Layout, k: number): boolean
	if not l.has.booth then
		return false
	end
	local a, b = boothSpan(l)
	local x = stallX(l, k)
	return x + l.every / 2 > a and x - l.every / 2 < b
end

-- A lamp's x: on the stall line nearest `share` of the way along (on the island when it stands mid-row).
local function lampX(l: Layout, share: number): number
	local x = l.x0 + l.every * math.floor(l.n * share + 0.5)
	if l.island and share == 0.5 then
		x = stallX(l, l.island :: number)
	end
	return math.clamp(x, -l.hw + SHAPE.poleSide, l.hw - SHAPE.poleSide)
end

local function build(m: Types.Model)
	local site = m.site
	local l = layout(site)
	local v = site.variant
	local pal = LotKit.pick(PALETTES, v.palette)
	local hw, hd = l.hw, l.hd
	local top = LotKit.top

	-- The core: asphalt, the back row's lines and a lamp over them.
	LotKit.floor(m, "Asphalt", -hw, -hd, hw, hd, Kit.look(pal.asphalt, Enum.Material.Asphalt))
	LotKit.lines(m, "StallsBack", l.x0, l.back.z0, l.x1, l.back.z1, l.every, pal.lines, true)
	local style = LotKit.pick(LAMPS, v.crown)
	local pole = LotKit.pick(POLES, v.crown)
	local lampZ = hd - SHAPE.poleIn
	local lamps = if l.has.lamp2 then { 0.25, 0.75 } else { 0.5 }
	LotKit.lamp(m, "Lamp", lampX(l, lamps[1]), lampZ, site.height, style, pole)

	-- The extras, in EXTRAS' order (layout decided which the allowance pays for).
	local front = l.front
	if l.has.frontLines and front then
		LotKit.lines(m, "StallsFront", l.x0, front.z0, l.x1, front.z1, l.every, pal.lines, true)
	end
	if l.has.backStops then
		LotKit.stops(m, "StopsBack", l.x0 + 0.6, l.x1 - 0.6, l.back.z1 - SHAPE.stopIn, l.every, pal.stops)
	end
	if l.has.hedge then
		local h = SHAPE.hedge
		Kit.box(
			m,
			"Hedge",
			Vector3.new(-hw + h.side, -0.3, -hd + h.front),
			Vector3.new(hw - h.side - SHAPE.entrance, top + h.height, -hd + h.back),
			Kit.look(HEDGE, Enum.Material.LeafyGrass)
		)
	end
	if l.has.booth then
		local b = SHAPE.booth
		local x = hw - b.x
		local z0 = -hd + b.front
		Kit.punched(
			m,
			"Booth",
			Vector3.new(x - b.w / 2, -0.5, z0),
			Vector3.new(x + b.w / 2, b.height, z0 + b.d),
			pal.booth,
			P.window.dark,
			{ Enum.NormalId.Front, Enum.NormalId.Left, Enum.NormalId.Right },
			2.2,
			b.height + 0.5
		)
		Kit.trim(
			m,
			"BoothRoof",
			Vector3.new(x - b.w / 2 - b.over, b.height, math.max(-hd, z0 - b.over)),
			Vector3.new(x + b.w / 2 + b.over, b.height + b.roof, z0 + b.d + b.over),
			Kit.look(pal.trim, Enum.Material.SmoothPlastic)
		)
	end
	if l.has.frontStops and front then
		LotKit.stops(m, "StopsFront", l.x0 + 0.6, l.x1 - 0.6, front.z0 + SHAPE.stopIn, l.every, pal.stops)
	end
	if l.has.sign then
		local s = SHAPE.sign
		local look = City.districtLooks[site.district]
		Kit.sign(
			m,
			"Sign",
			Vector3.new(hw - s.x - s.w / 2, -0.5, -hd + s.front),
			Vector3.new(hw - s.x + s.w / 2, s.height, -hd + s.front + s.d),
			Enum.NormalId.Front,
			"P",
			SIGN.board,
			SIGN.text,
			if look then look.font else Enum.Font.Michroma
		)
	end
	local island = l.island
	if island then
		local i = SHAPE.island
		local x = stallX(l, island)
		Kit.box(
			m,
			"Island",
			Vector3.new(x - i.w / 2, -0.2, l.back.z0 + i.inset),
			Vector3.new(x + i.w / 2, top + i.top, l.back.z1 - i.inset),
			Kit.look(HEDGE, Enum.Material.LeafyGrass)
		)
		local z = (l.back.z0 + l.back.z1) / 2
		if #LotKit.palm(m, "Palm", "royal", x, z, SHAPE.palmWant, v.palette) == 0 then
			LotKit.palm(m, "Palm", "sabal", x, z, SHAPE.palmWant, v.palette)
		end
	end
	if l.has.lamp2 then
		LotKit.lamp(m, "Lamp2", lampX(l, lamps[2]), lampZ, site.height, style, pole)
	end
end

-- The stalls a car may park in (Dev/City/LotKit Stall, in world space): every painted stall of both rows, less the one
-- the island takes and those under the booth. For Dev/City/Street Parking.fillStalls.
local function stalls(site: Site): { LotKit.Stall }
	local l = layout(site)
	local m = Kit.model(site)
	local out: { LotKit.Stall } = {}
	for k = 1, l.n do
		if l.island ~= k then
			table.insert(
				out,
				LotKit.stall(m, stallX(l, k), (l.back.z0 + l.back.z1) / 2, l.every, SHAPE.stall.Y, "back")
			)
		end
	end
	local front = l.front
	if front and l.has.frontLines then
		for k = 1, l.n do
			if not underBooth(l, k) then
				table.insert(
					out,
					LotKit.stall(m, stallX(l, k), (front.z0 + front.z1) / 2, l.every, SHAPE.stall.Y, "front")
				)
			end
		end
	end
	return out
end

return { id = "surface_parking", build = build, stalls = stalls }
