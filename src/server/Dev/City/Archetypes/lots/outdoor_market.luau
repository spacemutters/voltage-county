--!strict
-- L7 outdoor_market (Config/CityLots; Config/CityArchetypes/outdoor_market): an open-air market. The idea: brick or
-- cobble paving under a row of striped market stalls facing the street, a lantern at the way in. While its part
-- allowance lasts it adds more stalls (a second row facing the first across an aisle when the rhythm says so), a
-- name board hung over the way in between the lantern and a second post (or a string of lights over the market), café
-- tables and a bike rack.
-- Variants: palette (brick, cobbles, terrazzo, sandstone), crown (the name board or the string of lights), rhythm (one
-- row of stalls along the back, or two rows facing each other), mirror.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local City = require(ReplicatedStorage.Shared.Config.City)
local CityLots = require(ReplicatedStorage.Shared.Config.CityLots)
local CityScenery = require(ReplicatedStorage.Shared.Config.CityScenery)
local Kit = require(script.Parent.Parent.Parent.Kit)
local LotKit = require(script.Parent.Parent.Parent.LotKit)
local Types = require(script.Parent.Parent.Parent.Types)

local P = City.palettes
local rgb = Color3.fromRGB

-- The recipe, in studs.
local SHAPE = {
	stall = Vector3.new(10, 9, 7), -- a market stall's box (Config/CityProps MarketStall), its counter toward -z
	step = 13, -- stalls stand this far apart along a row
	backIn = 5, -- the back row's middle, in from the back line
	frontIn = 11, -- the front row's middle (rhythm 2), in from the front line
	twoRowsFrom = 45, -- a market this deep may have two rows
	lamp = { side = 2, front = 2 }, -- the lantern at the way in, in from the front -x corner
	gate = { span = 16, drop = 2.6, board = 2.2, thick = 0.6, post = 0.4 }, -- the name board under the lantern's top
	stringPole = { side = 1.6, front = 3.4 }, -- the festoon's pole: in from the +x side and the front (behind the rack)
	cafe = 10, -- café tables stand this far either side of the middle (one row: in front of the stalls)
	rack = { side = 5, front = 1.2 },
}

local PALETTES = {
	{ ground = rgb(178, 98, 74), material = Enum.Material.Brick, variant = nil :: string?, board = P.deco.white },
	{
		ground = rgb(150, 146, 140),
		material = Enum.Material.Cobblestone,
		variant = nil :: string?,
		board = P.deco.lemon,
	},
	{
		ground = rgb(236, 226, 212),
		material = Enum.Material.Marble,
		variant = CityScenery.townSquare.plaza.variant :: string?,
		board = P.deco.aqua,
	},
	{ ground = rgb(214, 186, 150), material = Enum.Material.Sandstone, variant = nil :: string?, board = P.deco.pink },
}
local POLE = rgb(40, 42, 46)
local TEXT = rgb(36, 40, 46)

local function build(m: Types.Model)
	local site = m.site
	local v = site.variant
	local pal = LotKit.pick(PALETTES, v.palette)
	local limit = LotKit.allowance(site)
	local hw, hd = site.width / 2, site.depth / 2
	local H = site.height
	local count = math.max(1, math.floor((site.width - 6) / SHAPE.step))
	local twoRows = v.rhythm == 2 and site.depth >= SHAPE.twoRowsFrom

	-- The stalls, in the order they are added: the back row from the middle out, then the front row.
	local slots: { { x: number, z: number, yaw: number } } = {}
	local function row(z: number, yaw: number)
		local order: { number } = {}
		for k = 1, count do
			table.insert(order, k)
		end
		local middle = (count + 1) / 2
		table.sort(order, function(a: number, b: number): boolean
			local da, db = math.abs(a - middle), math.abs(b - middle)
			if math.abs(da - db) > 1e-6 then
				return da < db
			end
			return a < b
		end)
		for _, k in order do
			table.insert(slots, { x = (k - middle) * SHAPE.step, z = z, yaw = yaw })
		end
	end
	row(hd - SHAPE.backIn, 0)
	if twoRows then
		row(-hd + SHAPE.frontIn, 180)
	end
	local placed = 0
	local function stall(): boolean
		local slot = slots[placed + 1]
		if slot == nil then
			return false
		end
		placed += 1
		LotKit.prop(m, `Stall{placed}`, "MarketStall", slot.x, slot.z, slot.yaw, SHAPE.stall)
		return true
	end

	-- The core: the paving, two stalls and the lantern.
	local floor = LotKit.floor(m, "Paving", -hw, -hd, hw, hd, Kit.look(pal.ground, pal.material))
	floor.materialVariant = pal.variant
	stall()
	stall()
	local lampX = -hw + SHAPE.lamp.side
	local lampZ = -hd + SHAPE.lamp.front
	LotKit.lamp(m, "Lamp", lampX, lampZ, H, "lantern", POLE)

	-- The extras, in order, while the allowance lasts: the rest of the stalls first.
	for _ = placed + 1, #slots do
		if not LotKit.fits(m, limit, 1) then
			break
		end
		stall()
	end
	if v.crown == 1 then
		-- The name board, hung between the lantern's post and a second post over the way in.
		local g = SHAPE.gate
		local span = math.min(g.span, site.width - 2 * SHAPE.lamp.side - 1)
		if LotKit.fits(m, limit, 2) and span >= 8 then
			local px = lampX + span
			Kit.column(m, "GatePost", px, lampZ, -0.5, H - g.drop, g.post, Kit.look(POLE, Enum.Material.Metal), "box")
			local look = City.districtLooks[site.district]
			local names = CityLots.names.markets
			Kit.sign(
				m,
				"Board",
				Vector3.new(lampX + g.post, H - g.drop - g.board, lampZ - g.thick / 2),
				Vector3.new(px - g.post, H - g.drop, lampZ + g.thick / 2),
				Enum.NormalId.Front,
				LotKit.pick(names, site.seed % #names + 1),
				pal.board,
				TEXT,
				if look then look.font else Enum.Font.Michroma
			)
		end
	elseif LotKit.fits(m, limit, 3) then
		-- A short festoon over the way in: from the lantern along the front to a pole clear of the bike rack.
		local s = SHAPE.stringPole
		local px = math.min(hw - s.side, lampX + CityLots.festoon.span.X)
		LotKit.festoon(m, "Lights", lampX, lampZ, H - 2.2, px, -hd + s.front, H - 1, POLE)
	end
	-- Café tables: in front of the stalls, or at the ends of the aisle between two rows.
	local cafes = { "CafeSetWhite", "CafeSetPink" }
	for k = 1, 2 do
		if LotKit.fits(m, limit, 1) and site.width >= 40 then
			local side = if k == 1 then -1 else 1
			local x = if twoRows then side * (hw - 6) else side * SHAPE.cafe
			local z = if twoRows then 2 else 0
			LotKit.prop(m, `Cafe{k}`, cafes[k], x, z, 0)
		end
	end
	if LotKit.fits(m, limit, 1) then
		LotKit.prop(m, "Rack", "BikeRack", hw - SHAPE.rack.side, -hd + SHAPE.rack.front, 0)
	end
end

local archetype: Types.Archetype = { id = "outdoor_market", build = build }
return archetype
