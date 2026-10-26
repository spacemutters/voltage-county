--!strict
-- Edit-mode previews of the scenery (docs/city/SCENERY.md), like Dev/City/Preview for the buildings: sample pieces built
-- exactly as MapBuilder.build() would, into Workspace.CityPreview on the open grass south of the county, so they can be
-- photographed without rebuilding the map. Studio and Edit mode only (hard rules 8 and 9). Light, camera, night and
-- clearing up are Dev/City/Preview's:
--
--   local City = game.ServerScriptService.Server.Dev.City
--   local Preview, Scene = require(City.Preview), require(City.Scenery.Preview)
--   Preview.lighting(true)
--   Scene.palms()        -- the three palms, two variants each (their templates, or the stand-ins while missing)
--   Scene.stands()       -- the four lifeguard stands
--   Scene.street()       -- the three streetlight styles, a bus shelter, a bench, a beach set and the fountain
--   Scene.causeway()     -- a stretch of the causeway: deck, balustrades, piers, cap, arched spans and lamps
--   Preview.camera(Vector3.new(0, 20, 4150), Vector3.new(0, 15, 4000)) ... Preview.night(true) ... Preview.clear()

local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Beach = require(script.Parent.Beach)
local Causeway = require(script.Parent.Causeway)
local Kit = require(script.Parent.Parent.Kit)
local Lamps = require(script.Parent.Lamps)
local LifeguardStand = require(script.Parent.LifeguardStand)
local MapBuilder = require(script.Parent.Parent.Parent.MapBuilder)
local Palms = require(script.Parent.Palms)
local Piece = require(script.Parent.Piece)
local Streets = require(script.Parent.Streets)
local Types = require(script.Parent.Types)

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CityScenery = require(ReplicatedStorage.Shared.Config.CityScenery)

type PartSpec = Types.PartSpec

local ORIGIN = Vector3.new(0, 0, 4000)

local Scene = {}

local function guard()
	if not RunService:IsStudio() or RunService:IsRunning() then
		error("Scenery Preview runs in Studio's Edit mode only", 3)
	end
end

local function root(): Instance
	local folder = Workspace:FindFirstChild("CityPreview")
	if folder == nil then
		local made = Instance.new("Folder")
		made.Name = "CityPreview"
		made.Parent = Workspace
		folder = made
	end
	return folder :: Instance
end

-- A model of `specs` (templates cloned, as the build does) under Workspace.CityPreview.
local function model(name: string, specs: { PartSpec }): Model
	local m = Instance.new("Model")
	m.Name = name
	m:SetAttribute("Parts", #specs)
	for _, spec in specs do
		if spec.template then
			Palms.instantiate(spec, MapBuilder.createPart).Parent = m
		else
			MapBuilder.createPart(spec).Parent = m
		end
	end
	m.Parent = root()
	return m
end

-- The three palms in a row, two variants each, facing south (+Z), the first at `at`.
function Scene.palms(at: Vector3?): { Model }
	guard()
	local base = at or ORIGIN
	local out: { Model } = {}
	local x = 0
	for _, name in { "royal", "coconut", "sabal" } do
		for variant = 1, 2 do
			local rolls: Palms.Rolls = { scale = 0.5, yaw = 0.5, lean = 0.5, variant = (variant - 0.5) / 2 }
			local trunk, crown =
				Palms.specs("Preview", `{name}{variant}`, "scenery", name, base + Vector3.new(x, 0, 0), math.pi, rolls)
			table.insert(out, model(`palm_{name}_{variant}`, { trunk, crown }))
			x += 34
		end
	end
	return out
end

-- The four lifeguard stands in a row, fronts to the south, the first at `at`.
function Scene.stands(at: Vector3?): { Model }
	guard()
	local base = at or ORIGIN
	local lifeguard = CityScenery.lifeguard
	local out: { Model } = {}
	for k, shape in lifeguard.shapes do
		local pos = base + Vector3.new((k - 1) * 30, 0, 0)
		local m = Piece.model(`Guard{k}`, CFrame.lookAt(pos, pos + Vector3.zAxis), k)
		LifeguardStand.build(m, shape, lifeguard.schemes[((k - 1) * 3) % #lifeguard.schemes + 1], k)
		table.insert(out, model(`stand_{shape}`, m.specs))
	end
	return out
end

-- Street furniture in a row along x, fronts to the south: the three streetlight styles, a bus shelter, a bench, a
-- beach set and the fountain.
function Scene.street(at: Vector3?): { Model }
	guard()
	local base = at or ORIGIN
	local out: { Model } = {}
	local lamps = CityScenery.lamps
	local x = 0
	for _, name in { "avenue", "street", "globe" } do
		local style: Lamps.Style = (lamps :: any)[name]
		local post = Lamps.post(style, "Preview", `Lamp{name}`, Vector2.new(base.X + x, base.Z), base.Y, Vector2.yAxis)
		local specs = { post.pole, post.head }
		for _, extra in post.extras do
			table.insert(specs, extra)
		end
		Kit.lit(post.head, "streetlight")
		table.insert(out, model(`lamp_{name}`, specs))
		x += 16
	end
	local function piece(name: string, offset: number, draw: (m: any) -> ())
		local pos = base + Vector3.new(x + offset, 0, 0)
		local m = Piece.model(name, CFrame.lookAt(pos, pos + Vector3.zAxis), 1)
		draw(m)
		table.insert(out, model(name, m.specs))
		x += offset * 2
	end
	piece("Shelter", 8, Streets.drawShelter)
	local palette = CityScenery.palette
	piece("Bench", 6, function(m)
		Beach.drawBench(
			m,
			Kit.look(palette.wood, Enum.Material.WoodPlanks),
			Kit.look(palette.terrazzo, Enum.Material.SmoothPlastic)
		)
	end)
	piece("Sun", 8, function(m)
		Beach.drawSet(m, palette.pink, palette.white, 6)
	end)
	return out
end

-- A 160-stud stretch of the causeway running along z from `at`: its deck, both balustrades, two pier pairs with
-- caps, the arched span between them, and acorn lamps.
function Scene.causeway(at: Vector3?): Model
	guard()
	local base = at or ORIGIN
	local half, length, deck = 27, 160, 20.2
	local centre = base + Vector3.new(0, deck, length / 2)
	local frame = CFrame.lookAt(centre, centre + Vector3.zAxis)
	local specs: { PartSpec } = {
		{
			folder = "Preview",
			name = "Deck",
			class = "Part",
			shape = "block",
			role = "road",
			size = Vector3.new(2 * half, 1, length),
			cframe = frame * CFrame.new(0, -0.5, 0),
			color = Color3.fromRGB(150, 148, 142),
			material = Enum.Material.Concrete,
			collide = true,
			query = true,
			touch = false,
			shadow = true,
			transparency = 0,
		},
	}
	for _, side in { -1, 1 } do
		local parts, _, _, glow = Causeway.balustrade("Preview", `Rail{side}`, frame, length - 2, half, side)
		Kit.lit(glow, Causeway.glowKind)
		for _, part in parts do
			table.insert(specs, part)
		end
	end
	local stations: { Vector2 } = {}
	for k, z in { 40, 120 } do
		local p = Vector2.new(base.X, base.Z + z)
		for j, lateral in { -19, 19 } do
			table.insert(
				specs,
				Causeway.pier("Preview", `Pier{k}{j}`, p + Vector2.new(lateral, 0), base.Y - 12, deck - 1.01)
			)
		end
		table.insert(specs, Causeway.cap("Preview", `Cap{k}`, p, Vector2.yAxis, deck - 1.03, 2 * half - 1))
		table.insert(stations, p)
	end
	for _, part in
		Causeway.haunches("Preview", "Arch", stations[1], stations[2], Vector2.xAxis, half - 0.6, deck - 1.01)
	do
		table.insert(specs, part)
	end
	for k = 0, 5 do
		local side = if k % 2 == 0 then 1 else -1
		local post, globe = Causeway.lamp("Preview", `CausewayLamp{k}`, frame, -length / 2 + 15 + k * 25, half, side)
		Kit.lit(globe, "streetlight")
		table.insert(specs, post)
		table.insert(specs, globe)
	end
	return model("causeway", specs)
end

return Scene
