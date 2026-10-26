--!strict
-- L4 sports_court (Config/CityLots; Config/CityArchetypes/sports_court): a neighbourhood basketball court. The idea: a
-- bright acrylic court with its lines inside a darker surround, a hoop at the far end, a floodlight over it. While its
-- part allowance lasts it adds the chain-link fence, the second hoop of a full court, a second floodlight, a bench and
-- a bike rack at the kerb.
-- Variants: palette (blue on green, terracotta on green, coral on teal, purple on grey), crown (a tall galvanised
-- chain-link fence or a low green one), rhythm (a half court, or a full court across the lot when it is wide enough),
-- mirror.

local Kit = require(script.Parent.Parent.Parent.Kit)
local LotKit = require(script.Parent.Parent.Parent.LotKit)
local Types = require(script.Parent.Parent.Parent.Types)

local rgb = Color3.fromRGB

-- The recipe, in studs.
local SHAPE = {
	half = Vector2.new(50, 43), -- a half court at most this wide (x) and long (z)
	full = Vector2.new(94, 46), -- a full court at most this long (x) and wide (z)
	fullFrom = 96, -- a lot this wide takes a full court (rhythm 2)
	margin = { side = 6, ends = 10 }, -- the surround round the court, at least (both sides together)
	inlay = 0.06, -- the court stands this far over the surround
	hoop = Vector3.new(4, 13, 6), -- a hoop's box (Config/CityProps BasketballHoop), its rim toward its -z
	hoopBack = 1, -- the hoop's box reaches this far past the baseline (its post), the rim over the court
	-- bar: post spacing (at 0.9 it blurred to a haze). opening, openingTop: the railing image's opening, its share of a
	-- tile's height and how far below the tile's top it starts (Config/City textures.punched).
	fence = { out = 1.5, edge = 0.2, tall = 12, low = 5, bar = 1.5, opening = 0.56, openingTop = 0.12 },
	flood = { side = 2, back = 1.2 },
	bench = { x = -6, front = 1.6, room = 2.6 }, -- room: the depth it needs in front of the fence
	rack = { side = 5, front = 1.2, room = 2.2 },
}

local PALETTES = {
	{ surround = rgb(64, 118, 84), court = rgb(52, 96, 168), lines = rgb(246, 246, 240) },
	{ surround = rgb(70, 112, 78), court = rgb(186, 96, 66), lines = rgb(246, 246, 240) },
	-- Coral on deep teal (a teal court on navy read as a swimming pool from above, 2026-10-26).
	{ surround = rgb(34, 88, 92), court = rgb(222, 112, 104), lines = rgb(246, 246, 240) },
	{ surround = rgb(80, 82, 88), court = rgb(120, 70, 170), lines = rgb(255, 196, 70) },
}
-- Galvanised chain link (tall) or a low green fence. A black tall fence read as a smoked-glass box round the court.
local FENCES = { rgb(150, 156, 160), rgb(44, 86, 58) }
local POLE = rgb(70, 72, 76)

local function build(m: Types.Model)
	local site = m.site
	local v = site.variant
	local pal = LotKit.pick(PALETTES, v.palette)
	local limit = LotKit.allowance(site)
	local hw, hd = site.width / 2, site.depth / 2
	local top = LotKit.top
	local full = v.rhythm == 2 and site.width >= SHAPE.fullFrom

	-- The court: along z with its hoop at the back (a half court), or along x with a hoop at each end (a full one).
	local cx: number, cz: number
	if full then
		cx = math.min(site.width - SHAPE.margin.ends, SHAPE.full.X) / 2
		cz = math.min(site.depth - SHAPE.margin.side, SHAPE.full.Y) / 2
	else
		cx = math.min(site.width - SHAPE.margin.side, SHAPE.half.X) / 2
		cz = math.min(site.depth - SHAPE.margin.ends, SHAPE.half.Y) / 2
	end

	-- The core: the surround, the court with its lines, a hoop and a floodlight.
	LotKit.floor(m, "Surround", -hw, -hd, hw, hd, Kit.look(pal.surround, Enum.Material.SmoothPlastic))
	local court = Kit.detail(
		m,
		"Court",
		Vector3.new(-cx, top - 0.1, -cz),
		Vector3.new(cx, top + SHAPE.inlay, cz),
		Kit.look(pal.court, Enum.Material.SmoothPlastic)
	)
	-- The lines: the outline of each tile (a half court is one tile, a full court two, so its centre line shows).
	if full then
		LotKit.texture(m, court, LotKit.images.grid, cx, 2 * cz, pal.lines)
	else
		LotKit.texture(m, court, LotKit.images.grid, 2 * cx, 2 * cz, pal.lines)
	end
	local box = SHAPE.hoop
	local reach = SHAPE.hoopBack - box.Z / 2 -- the hoop box's middle, from the baseline outward
	if full then
		LotKit.prop(m, "Hoop", "BasketballHoop", -cx - reach, 0, -90, box)
	else
		LotKit.prop(m, "Hoop", "BasketballHoop", 0, cz + reach, 0, box)
	end
	local f = SHAPE.flood
	LotKit.lamp(m, "Flood", -hw + f.side, hd - f.back, site.height, "flood", POLE, true)

	-- The extras, in order, while the allowance lasts.
	if LotKit.fits(m, limit, 1) then
		local fence = SHAPE.fence
		local fx = math.min(cx + fence.out, hw - fence.edge)
		local fz = math.min(cz + fence.out, hd - fence.edge)
		local tall = if v.crown == 2 then fence.low else fence.tall
		local railing = Kit.railing(
			m,
			"Fence",
			Vector3.new(-fx, top, -fz),
			Vector3.new(fx, top + tall, fz),
			{ Enum.NormalId.Front, Enum.NormalId.Back, Enum.NormalId.Left, Enum.NormalId.Right },
			LotKit.pick(FENCES, v.crown),
			fence.bar
		)
		-- The railing image's opening sized and moved to fill the fence's whole height, so only its posts show: its
		-- solid band along the top read as a frosted panel round the court (2026-10-26).
		for _, texture in railing.textures or {} do
			texture.v = tall / fence.opening
			texture.offsetV = fence.openingTop * texture.v
		end
	end
	if full and LotKit.fits(m, limit, 1) then
		LotKit.prop(m, "Hoop2", "BasketballHoop", cx + reach, 0, 90, box)
	end
	if LotKit.fits(m, limit, 2) then
		LotKit.lamp(m, "Flood2", hw - f.side, hd - f.back, site.height, "flood", POLE, true)
	end
	-- A bench and a bike rack at the kerb, outside the fence when there is room for them there.
	local outside = hd - (cz + SHAPE.fence.out)
	if LotKit.fits(m, limit, 1) and outside >= SHAPE.bench.room then
		LotKit.prop(m, "Bench", "ParkBench", SHAPE.bench.x, -hd + SHAPE.bench.front, 180)
	end
	if LotKit.fits(m, limit, 1) and outside >= SHAPE.rack.room then
		LotKit.prop(m, "Rack", "BikeRack", hw - SHAPE.rack.side, -hd + SHAPE.rack.front, 0)
	end
end

local archetype: Types.Archetype = { id = "sports_court", build = build }
return archetype
