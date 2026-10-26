--!strict
-- L6 pocket_park (Config/CityLots; Config/CityArchetypes/pocket_park): a small neighbourhood park. The idea: a green
-- lawn crossed by a pale path, one thing to do on it (a playground, a fenced dog run or a little bandshell) and a globe
-- lamp by the path. While its part allowance lasts it adds a palm, benches along the path, the feature's collision
-- box, a second palm, a planter and a bistro table.
-- Variants: palette (lawn and path: grass and pale concrete, lush lawn and coral stone, meadow and brick), crown (a
-- playground, a dog run, a bandshell on a wide enough lot), rhythm (the path along the front, or straight through from
-- the street to the back), mirror.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local City = require(ReplicatedStorage.Shared.Config.City)
local Kit = require(script.Parent.Parent.Parent.Kit)
local LotKit = require(script.Parent.Parent.Parent.LotKit)
local Types = require(script.Parent.Parent.Parent.Types)

local P = City.palettes
local rgb = Color3.fromRGB

-- The recipe, in studs.
local SHAPE = {
	path = { width = 5, front = 3 }, -- the path along the front starts this far in from the front line
	lamp = { side = 2.4, front = 1.4 },
	feature = 4, -- the feature's middle, toward the back from the lawn's middle
	bandshellFrom = 70, -- a park this wide may have a bandshell (crown 3)
	-- front: behind the benches and planter. bar: the pickets' spacing (at 0.7 a white fence blurred into a frosted wall).
	dogRun = { side = 3, front = 15.5, back = 3, tall = 4.5, bar = 1.8 },
	royalFrom = 50, -- a park this wide takes a royal palm (else sabals)
	palmIn = { royal = 10, sabal = 8 },
	palmWant = 36,
	bench = 3.4, -- benches stand this far behind the path's edge
	planter = 4.5,
}

local PALETTES = {
	{ lawn = rgb(86, 138, 70), grass = Enum.Material.Grass, path = rgb(224, 218, 204), walk = Enum.Material.Concrete },
	{
		lawn = rgb(78, 130, 66),
		grass = Enum.Material.LeafyGrass,
		path = rgb(226, 206, 180),
		walk = Enum.Material.Sandstone,
	},
	{ lawn = rgb(96, 146, 76), grass = Enum.Material.Grass, path = rgb(178, 98, 74), walk = Enum.Material.Brick },
}
local LAMP_POLE = rgb(40, 44, 48)
local FENCE = rgb(46, 54, 50) -- black-green powder-coated metal, as a dog run's fence is

local function build(m: Types.Model)
	local site = m.site
	local v = site.variant
	local pal = LotKit.pick(PALETTES, v.palette)
	local limit = LotKit.allowance(site)
	local hw, hd = site.width / 2, site.depth / 2
	local top = LotKit.top
	local across = v.rhythm == 2 -- the path runs from the street straight to the back

	-- The core: the lawn, the path and the lamp.
	LotKit.floor(m, "Lawn", -hw, -hd, hw, hd, Kit.look(pal.lawn, pal.grass))
	local p = SHAPE.path
	local walk = Kit.look(pal.path, pal.walk)
	if across then
		Kit.detail(m, "Path", Vector3.new(-p.width / 2, top - 0.1, -hd), Vector3.new(p.width / 2, top + 0.06, hd), walk)
	else
		Kit.detail(
			m,
			"Path",
			Vector3.new(-hw, top - 0.1, -hd + p.front),
			Vector3.new(hw, top + 0.06, -hd + p.front + p.width),
			walk
		)
	end
	local lampX = if across then p.width / 2 + SHAPE.lamp.side else hw - SHAPE.lamp.side
	LotKit.lamp(m, "Lamp", lampX, -hd + SHAPE.lamp.front, site.height, "globe", LAMP_POLE)

	-- The extras, in order, while the allowance lasts. First the feature, behind the path.
	local fz = SHAPE.feature
	local fx = if across then hw * 0.5 + p.width / 4 else 0
	local crown = if v.crown == 3 and site.width < SHAPE.bandshellFrom then 1 else v.crown
	local featureSpec: Types.PartSpec? = nil
	local featureProp = if crown == 3 then "Bandshell" else "PlaygroundSet"
	if crown == 2 then
		if LotKit.fits(m, limit, 1) then
			local d = SHAPE.dogRun
			local x0 = if across then p.width / 2 + 1 else -hw + d.side
			Kit.railing(
				m,
				"DogRun",
				Vector3.new(x0, top, -hd + d.front),
				Vector3.new(hw - d.side, top + d.tall, hd - d.back),
				{ Enum.NormalId.Front, Enum.NormalId.Back, Enum.NormalId.Left, Enum.NormalId.Right },
				FENCE,
				d.bar
			)
		end
	elseif LotKit.fits(m, limit, 1) then
		featureSpec = LotKit.prop(m, "Feature", featureProp, fx, fz, 0)[1]
	end
	local royal = site.width >= SHAPE.royalFrom
	local species = if royal then "royal" else "sabal"
	local palmIn = if royal then SHAPE.palmIn.royal else SHAPE.palmIn.sabal
	if LotKit.fits(m, limit, 2) then
		LotKit.palm(m, "Palm", species, -hw + palmIn, hd - palmIn, SHAPE.palmWant, v.palette)
	end
	-- Benches facing the feature from beside the path.
	local benchZ = if across then 0 else -hd + p.front + p.width + SHAPE.bench
	for k = 1, 2 do
		if LotKit.fits(m, limit, 1) then
			local x = if across then -p.width / 2 - SHAPE.bench else (k - 1.5) * math.min(16, hw * 0.8)
			local z = if across then benchZ + (k - 1.5) * 12 else benchZ
			LotKit.prop(m, `Bench{k}`, "ParkBench", x, z, if across then -90 else 180)
		end
	end
	local feature = featureSpec
	if feature and LotKit.fits(m, limit, 1) then
		LotKit.collider(m, "FeatureBox", feature, featureProp)
	end
	if LotKit.fits(m, limit, 2) and site.width >= 36 then
		LotKit.palm(m, "Palm2", "sabal", hw - 8, hd - 8, SHAPE.palmWant - 8, v.palette + 1)
	end
	if LotKit.fits(m, limit, 2) and site.width >= 40 then
		-- In the front corner, or just behind the path when it runs along the front.
		local s = SHAPE.planter
		local z = if across then -hd + s else -hd + p.front + p.width + s
		LotKit.planter(m, "Planter", -hw + s, z, s, s, P.deco.terrazzo)
	end
	if LotKit.fits(m, limit, 1) and site.width >= 40 then
		LotKit.prop(m, "Picnic", "BistroPair", hw * 0.5, hd - 4, 0)
	end
end

local archetype: Types.Archetype = { id = "pocket_park", build = build }
return archetype
