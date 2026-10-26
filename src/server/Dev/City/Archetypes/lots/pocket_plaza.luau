--!strict
-- L2 pocket_plaza (Config/CityLots; Config/CityArchetypes/pocket_plaza): a small public plaza between towers. The idea:
-- a pale patterned floor (terrazzo, limestone or coral-stone pavers) round one centrepiece, a fountain or a sculpture,
-- with a globe lamp at its front corner. While its part allowance lasts it adds benches facing the centrepiece, a palm
-- in the back corner, the centrepiece's collision box, a planter in the front corner, a second palm, a glass kiosk with
-- café tables, and news boxes at the kerb.
-- Variants: palette (terrazzo, limestone, coral stone, white concrete pavers), crown (the fountain, sculpture A or B),
-- rhythm (the centrepiece in the middle with the kiosk in the back corner, or off to one side with the kiosk on the
-- other), mirror.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local City = require(ReplicatedStorage.Shared.Config.City)
local CityScenery = require(ReplicatedStorage.Shared.Config.CityScenery)
local Kit = require(script.Parent.Parent.Parent.Kit)
local LotKit = require(script.Parent.Parent.Parent.LotKit)
local Types = require(script.Parent.Parent.Parent.Types)

local P = City.palettes
local rgb = Color3.fromRGB

-- The recipe, in studs.
local SHAPE = {
	lamp = { side = 2.4, front = 2.4 }, -- the globe lamp, in from the front +x corner
	centreZ = 2, -- the centrepiece's middle, from the plaza's middle toward the back
	benchGap = 5.5, -- benches stand this far in front of and behind the centrepiece's box
	royalFrom = 40, -- a plaza this wide or wider takes royal palms (else sabals)
	palmIn = { royal = 10, sabal = 8 }, -- a palm's foot, in from its corner
	palmWant = 44,
	planter = 4.5, -- the planter box, square, in the front -x corner
	secondPalmFrom = 50,
	kioskFrom = 64, -- a plaza this wide gets a glass kiosk with café tables
	kiosk = { w = 8, d = 6, back = 4, side = 4, height = 7.5, roof = 0.6, over = 0.8 },
	cafeGap = 7, -- café tables stand this far in front of the kiosk
	cafeStep = 10,
	newsFrom = 30,
	news = 9, -- the news boxes, in from the +x side at the kerb
}

local PALETTES = {
	{
		floor = rgb(236, 226, 212),
		material = Enum.Material.Marble,
		variant = CityScenery.townSquare.plaza.variant :: string?,
		grid = rgb(214, 204, 190),
		tile = Vector2.new(10, 10),
		accent = P.deco.aqua,
		cafe = "CafeSetWhite",
	},
	{
		floor = rgb(222, 214, 196),
		material = Enum.Material.Limestone,
		variant = nil :: string?,
		grid = rgb(194, 186, 168),
		tile = Vector2.new(6, 6),
		accent = P.deco.white,
		cafe = "CafeSetMint",
	},
	{
		floor = rgb(226, 206, 180),
		material = Enum.Material.Sandstone,
		variant = nil :: string?,
		grid = rgb(198, 176, 148),
		tile = Vector2.new(8, 4),
		accent = P.deco.peach,
		cafe = "CafeSetPink",
	},
	{
		floor = rgb(232, 230, 224),
		material = Enum.Material.Concrete,
		variant = nil :: string?,
		grid = rgb(206, 202, 194),
		tile = Vector2.new(5, 5),
		accent = P.deco.pink,
		cafe = "CafeSetPink",
	},
}

local CENTREPIECES = { "Fountain", "SculptureA", "SculptureB" }
local LAMP_POLE = rgb(236, 236, 230)

local function build(m: Types.Model)
	local site = m.site
	local v = site.variant
	local pal = LotKit.pick(PALETTES, v.palette)
	local limit = LotKit.allowance(site)
	local hw, hd = site.width / 2, site.depth / 2
	local wide = site.width >= SHAPE.kioskFrom
	local aside = v.rhythm == 2 and wide
	-- The centrepiece: in the middle, or (rhythm 2, with a kiosk on the other side to balance it) off toward -x.
	local cx = if aside then -hw * 0.3 else 0
	local cz = math.min(SHAPE.centreZ, hd - 9)

	-- The core: the paving, the centrepiece, the lamp.
	local floor = LotKit.floor(m, "Paving", -hw, -hd, hw, hd, Kit.look(pal.floor, pal.material))
	floor.materialVariant = pal.variant
	-- The joints faded half into the paving: at full strength they read as bold stripes from the street.
	LotKit.texture(m, floor, LotKit.images.grid, pal.tile.X, pal.tile.Y, pal.grid, nil, nil, 0.5)
	local piece = LotKit.pick(CENTREPIECES, v.crown)
	local centre = LotKit.prop(m, "Centre", piece, cx, cz, 0)[1]
	LotKit.lamp(m, "Lamp", hw - SHAPE.lamp.side, -hd + SHAPE.lamp.front, site.height, "globe", LAMP_POLE)

	-- The extras, in order, while the allowance lasts.
	local reach = centre.size.Z / 2 + SHAPE.benchGap
	for k, z in { cz - reach, cz + reach } do
		if LotKit.fits(m, limit, 1) and math.abs(z) < hd - 1.5 then
			-- Each faces the centrepiece: the front one turned away from the road, the back one toward it.
			LotKit.prop(m, `Bench{k}`, "ParkBench", cx, z, if k == 1 then 180 else 0)
		end
	end
	local royal = site.width >= SHAPE.royalFrom
	local species = if royal then "royal" else "sabal"
	local palmIn = if royal then SHAPE.palmIn.royal else SHAPE.palmIn.sabal
	if LotKit.fits(m, limit, 2) then
		LotKit.palm(m, "Palm", species, hw - palmIn, hd - palmIn, SHAPE.palmWant, v.palette)
	end
	if LotKit.fits(m, limit, 1) then
		LotKit.collider(m, "CentreBox", centre, piece)
	end
	if LotKit.fits(m, limit, 2) and site.width >= SHAPE.newsFrom then
		local s = SHAPE.planter
		LotKit.planter(m, "Planter", -hw + s, -hd + s, s, s, pal.accent)
	end
	if LotKit.fits(m, limit, 2) and site.width >= SHAPE.secondPalmFrom then
		LotKit.palm(m, "Palm2", species, -hw + palmIn, -hd + palmIn + 6, SHAPE.palmWant - 6, v.palette + 1)
	end
	if LotKit.fits(m, limit, 2) and wide then
		-- The kiosk: in the back -x corner, or (rhythm 2) on the +x side opposite the centrepiece.
		local k = SHAPE.kiosk
		local x = if aside then hw * 0.45 else -hw + k.side + k.w / 2
		local z1 = hd - k.back
		Kit.punched(
			m,
			"Kiosk",
			Vector3.new(x - k.w / 2, -0.5, z1 - k.d),
			Vector3.new(x + k.w / 2, k.height, z1),
			pal.accent,
			P.window.dark,
			{ Enum.NormalId.Front, Enum.NormalId.Left, Enum.NormalId.Right },
			2,
			k.height + 0.5,
			true
		)
		Kit.trim(
			m,
			"KioskRoof",
			Vector3.new(x - k.w / 2 - k.over, k.height, z1 - k.d - k.over),
			Vector3.new(x + k.w / 2 + k.over, k.height + k.roof, z1 + k.over),
			Kit.look(P.deco.white, Enum.Material.SmoothPlastic)
		)
		for c = 1, 2 do
			if LotKit.fits(m, limit, 1) then
				local cxx = x + (c - 1.5) * SHAPE.cafeStep
				LotKit.prop(m, `Cafe{c}`, pal.cafe, cxx, z1 - k.d - SHAPE.cafeGap, 0)
			end
		end
	end
	if LotKit.fits(m, limit, 1) and site.width >= SHAPE.newsFrom then
		LotKit.prop(m, "News", "NewsBoxes", hw - SHAPE.news, -hd + 1.6, 0)
	end
end

local archetype: Types.Archetype = { id = "pocket_plaza", build = build }
return archetype
