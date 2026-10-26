--!strict
-- Palms (docs/city/SCENERY.md §1; Config/CityScenery palms). Every palm in the plan is two parts:
--   <name>Trunk  the trunk a car hits: an invisible cylinder over the lower trunk (CanCollide on, no shadow). A mesh's own
--                collision box would be its whole crown, and cars hop and boost into crowns, so cars hit trunks and
--                pass through fronds, as with every tree (Config/Environment trees)
--   <name>Crown  the space the crown fills (its box, for the plan's checks), carrying a template (Dev/MapTypes
--                TemplateSpec): the build clones ServerStorage.CityAssets.Palms.<species> there, scaled to the palm's
--                height and turned to its yaw and lean, so every copy shares one mesh and draws as one instanced call.
--                While that template is missing the build puts up a parts-only stand-in instead (fallback), so the map
--                and Dev/MapCheck work before the meshes exist
-- Variety without new meshes: each palm draws its own yaw, scale and extra lean, and a variant when the template is a
-- folder of them.
--
-- The template's contract (for whoever makes the meshes in Studio): a MeshPart or a Model, or a Folder of them (its
-- variants, used in name order), named after the species (royal, coconut, sabal), in ServerStorage.CityAssets.Palms.
-- Its pivot is the centre of the trunk's foot on the ground, +Y up; a leaning palm leans toward its front (-Z). Any
-- size: the build scales it to the palm's height. The build turns off its collisions, raycasts and touches.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local CityScenery = require(ReplicatedStorage.Shared.Config.CityScenery)
local Types = require(script.Parent.Types)

type PartSpec = Types.PartSpec
type TemplateSpec = Types.TemplateSpec
type Role = Types.Role
export type Species = CityScenery.PalmSpecies

local PALMS = CityScenery.palms
local QUARTER = math.pi / 2

local Palms = {}

Palms.species = PALMS.species :: { [string]: Species }

-- One palm's own random draws, each 0..1 (drawn by the caller, so a palm that doesn't fit never shifts the next one's).
export type Rolls = { scale: number, yaw: number, lean: number, variant: number }

-- The frame a palm's template stands at: its foot at `foot`, turned `yaw` (radians), leaning `lean` degrees toward
-- its front.
local function pivotAt(foot: Vector3, yaw: number, lean: number): CFrame
	return CFrame.new(foot) * CFrame.Angles(0, yaw, 0) * CFrame.Angles(-math.rad(lean), 0, 0)
end

-- How big one palm is: its scale and height (studs) from its rolls.
function Palms.size(species: Species, rolls: Rolls, scale: { number }?): (number, number)
	local range = scale or species.scale
	local s = range[1] + rolls.scale * (range[2] - range[1])
	return s, species.height * s
end

-- How far a palm's crown reaches out from its trunk in plan (its spread's half, and the lean's sideways drift).
function Palms.reach(species: Species, scale: number): number
	local height = species.height * scale
	local drift = height * math.sin(math.rad(species.baseLean + species.lean[2])) * species.crownTo
	return species.crown * scale / 2 + drift
end

-- The plan's two parts for one palm of `speciesName` with its foot at `foot` (on the ground), filed in `folder` as
-- `role` ("tree" in the parks and groves, "scenery" in the streets and on the beach). `yaw` turns it (radians);
-- `scale` overrides the species' range.
function Palms.specs(
	folder: string,
	name: string,
	role: Role,
	speciesName: string,
	foot: Vector3,
	yaw: number,
	rolls: Rolls,
	scale: { number }?
): (PartSpec, PartSpec)
	local species = Palms.species[speciesName]
	if species == nil then
		error(`Palms: no species {speciesName} in Config/CityScenery palms`, 2)
	end
	local s, height = Palms.size(species, rolls, scale)
	local lean = species.lean[1] + rolls.lean * (species.lean[2] - species.lean[1])
	local pivot = pivotAt(foot - Vector3.yAxis * (species.sink or PALMS.sink), yaw, lean)
	local trunkFrame = pivot * CFrame.Angles(-math.rad(species.baseLean), 0, 0)

	-- The trunk a car hits.
	local across = species.collider.X * s
	local tall = species.collider.Y * s
	local trunk: PartSpec = {
		folder = folder,
		name = `{name}Trunk`,
		class = "Part",
		shape = "cylinder",
		role = role,
		size = Vector3.new(tall, across, across),
		cframe = trunkFrame * CFrame.new(0, tall / 2, 0) * CFrame.Angles(0, 0, QUARTER),
		color = species.fallback.trunk.color,
		material = species.fallback.trunk.material,
		collide = true,
		query = true,
		touch = false,
		shadow = false,
		transparency = 1,
	}

	-- The crown's box: from crownFrom to crownTo of the height along the leaning trunk, as wide as its spread.
	local spread = species.crown * s
	local mid = (species.crownFrom + species.crownTo) / 2 * height
	local centre = trunkFrame * Vector3.new(0, mid, 0)
	local variants = math.max(1, PALMS.variants)
	local crown: PartSpec = {
		folder = folder,
		name = `{name}Crown`,
		class = "Part",
		shape = "block",
		role = role,
		size = Vector3.new(spread, (species.crownTo - species.crownFrom) * height, spread),
		cframe = CFrame.new(centre) * CFrame.Angles(0, yaw, 0),
		color = species.fallback.fronds.color,
		material = Enum.Material.LeafyGrass,
		collide = false,
		query = false,
		touch = false,
		shadow = false,
		transparency = 1,
		template = {
			path = { PALMS.templateRoot[1], PALMS.templateRoot[2], speciesName },
			pivot = pivot,
			height = height,
			variant = math.clamp(math.floor(rolls.variant * variants) + 1, 1, variants),
			fallback = speciesName,
		},
	}
	return trunk, crown
end

-- A plant cloned from a template the same way (a planter's clump): one decor spec standing for its box, its foot at
-- `foot`, turned `yaw` (radians), scaled to `height` tall, about `spread` across. Its stand-in is nothing (Palms.fallback
-- knows no species by the template's name), so a planter stays an empty box while the mesh is missing.
function Palms.plant(
	folder: string,
	name: string,
	path: { string },
	foot: Vector3,
	yaw: number,
	height: number,
	spread: number
): PartSpec
	local pivot = CFrame.new(foot) * CFrame.Angles(0, yaw, 0)
	return {
		folder = folder,
		name = name,
		class = "Part",
		shape = "block",
		role = "scenery",
		size = Vector3.new(spread, height, spread),
		cframe = pivot * CFrame.new(0, height / 2, 0),
		color = Color3.fromRGB(70, 120, 60),
		material = Enum.Material.LeafyGrass,
		collide = false,
		query = false,
		touch = false,
		shadow = false,
		transparency = 1,
		template = { path = path, pivot = pivot, height = height, variant = 1, fallback = path[#path] },
	}
end

---------------------------------------------------------------------------------------------------------------
-- The build: a template's clone, or the stand-in
---------------------------------------------------------------------------------------------------------------

-- The parts-only stand-in for a palm (docs/city/SCENERY.md §1: parts palms read as toys next to a mesh, so this is
-- only for the time before the meshes exist): a trunk (in two curving pieces when the species leans), a swollen foot
-- or a crownshaft or a round head as the species has, and a ring of flat fronds. Decor that casts shadows.
function Palms.fallback(t: TemplateSpec, folder: string, name: string): { PartSpec }
	local species = Palms.species[t.fallback]
	if species == nil then
		return {}
	end
	local f = species.fallback
	local h = t.height
	local s = h / species.height
	local out: { PartSpec } = {}
	local function piece(
		suffix: string,
		shape: "block" | "cylinder" | "ball",
		cf: CFrame,
		size: Vector3,
		color: Color3,
		material: Enum.Material
	)
		table.insert(out, {
			folder = folder,
			name = `{name}{suffix}`,
			class = "Part",
			shape = shape,
			role = "tree",
			size = size,
			cframe = cf,
			color = color,
			material = material,
			collide = false,
			query = false,
			touch = false,
			shadow = true,
			transparency = 0,
		})
	end
	local trunkD = f.trunk.diameter * s
	local column = f.trunk.top * h
	local lean = species.baseLean
	-- The trunk's path: one straight piece, or two that curve up when the species leans.
	local frame = t.pivot * CFrame.Angles(-math.rad(lean), 0, 0)
	local pieces = if lean > 0 then 2 else 1
	local step = column / pieces
	for k = 1, pieces do
		local d = trunkD * (1 - 0.12 * (k - 1))
		piece(
			`Stem{k}`,
			"cylinder",
			frame * CFrame.new(0, step / 2, 0) * CFrame.Angles(0, 0, QUARTER),
			Vector3.new(step + 0.2, d, d),
			f.trunk.color,
			f.trunk.material
		)
		frame = frame * CFrame.new(0, step, 0) * CFrame.Angles(math.rad(lean * 0.5), 0, 0)
	end
	local top = frame -- where the trunk ends, turned as its last piece
	if f.trunk.foot > f.trunk.diameter and lean == 0 then
		local footD = f.trunk.foot * s
		local footH = 0.08 * h
		piece(
			"Foot",
			"cylinder",
			t.pivot * CFrame.new(0, footH / 2, 0) * CFrame.Angles(0, 0, QUARTER),
			Vector3.new(footH, footD, footD),
			f.trunk.color,
			f.trunk.material
		)
	end
	local shaft = f.shaft
	if shaft then
		local shaftH = (shaft.top - f.trunk.top) * h
		local sd = shaft.diameter * s
		piece(
			"Shaft",
			"cylinder",
			top * CFrame.new(0, shaftH / 2, 0) * CFrame.Angles(0, 0, QUARTER),
			Vector3.new(shaftH, sd, sd),
			shaft.color,
			Enum.Material.SmoothPlastic
		)
		top = top * CFrame.new(0, shaftH, 0)
	end
	local head = f.head
	if head then
		local hd = head.diameter * s
		piece("Head", "ball", top * CFrame.new(0, hd * 0.25, 0), Vector3.one * hd, head.color, Enum.Material.LeafyGrass)
	end
	-- The fronds: flat blades round the crown point, pitched up or drooping.
	local fronds = f.fronds
	local length, width, thick = fronds.length * s, fronds.width * s, fronds.thick * s
	for i = 1, fronds.count do
		local turn = (i - 1) / fronds.count * 2 * math.pi + 0.3
		local pitch = math.rad(fronds.pitch + (if i % 2 == 0 then -6 else 4))
		local cf = top * CFrame.Angles(0, turn, 0) * CFrame.Angles(pitch, 0, 0) * CFrame.new(0, 0, -length / 2)
		piece(`Frond{i}`, "block", cf, Vector3.new(width, thick, length), fronds.color, Enum.Material.LeafyGrass)
	end
	return out
end

-- The template a palm clones: ServerStorage along `path`, or the `variant`-th (in name order) of a folder of them.
function Palms.findTemplate(path: { string }, variant: number): Instance?
	local node: Instance? = ServerStorage
	for _, step in path do
		if node == nil then
			return nil
		end
		node = (node :: Instance):FindFirstChild(step)
	end
	if node == nil then
		return nil
	end
	local found = node :: Instance
	if found:IsA("BasePart") or found:IsA("Model") then
		return found
	end
	local options: { Instance } = {}
	for _, child in found:GetChildren() do
		if child:IsA("BasePart") or child:IsA("Model") then
			table.insert(options, child)
		end
	end
	if #options == 0 then
		return nil
	end
	table.sort(options, function(a: Instance, b: Instance): boolean
		return a.Name < b.Name
	end)
	return options[(variant - 1) % #options + 1]
end

-- Scenery, not a wall: anchored, nothing collides with it, raycasts and touches pass through, its shadow stays.
local function decorate(part: BasePart)
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = true
	if part:IsA("MeshPart") then
		pcall(function()
			(part :: MeshPart).RenderFidelity = Enum.RenderFidelity.Automatic
		end)
	end
end

-- Scales a template's clone to `t.height` and stands it at `t.pivot`.
function Palms.fit(clone: Instance, t: TemplateSpec)
	if clone:IsA("BasePart") then
		local part = clone :: BasePart
		local tall = part.Size.Y
		if tall > 0 then
			local s = t.height / tall
			local offset = part.PivotOffset
			part.Size = part.Size * s
			part.PivotOffset = CFrame.new(offset.Position * s) * offset.Rotation
		end
		part:PivotTo(t.pivot)
		decorate(part)
	elseif clone:IsA("Model") then
		local model = clone :: Model
		local tall = model:GetExtentsSize().Y
		if tall > 0 then
			model:ScaleTo(model:GetScale() * t.height / tall)
		end
		model:PivotTo(t.pivot)
		for _, descendant in model:GetDescendants() do
			if descendant:IsA("BasePart") then
				decorate(descendant)
			end
		end
	end
end

-- The attribute a stand-in palm's Model carries. The plan and the phone gate count a palm as two parts; a stand-in is
-- about ten, so Dev/MapCheck fails a map that holds any (the templates are Studio-owned: a place copy without
-- ServerStorage.CityAssets would otherwise pass its budgets while far over them).
Palms.standInAttribute = "PalmStandIn"

local warned = false

-- What the build puts in a palm crown's place: the template's clone, or a Model of the stand-in's parts made with
-- `makePart` (Dev/MapBuilder createPart), marked with standInAttribute (warned once per session). Named after the
-- spec.
function Palms.instantiate(spec: PartSpec, makePart: (PartSpec) -> BasePart): Instance
	local t = spec.template
	if t == nil then
		return makePart(spec)
	end
	local source = Palms.findTemplate(t.path, t.variant)
	if source then
		local clone = source:Clone()
		Palms.fit(clone, t)
		clone.Name = spec.name
		return clone
	end
	if not warned then
		warned = true
		warn(
			`[Palms] no template at ServerStorage.{table.concat(t.path, ".")}: building parts-only stand-in palms, `
				.. "about five times the parts the budgets count (Dev/MapCheck fails while any stand)"
		)
	end
	local model = Instance.new("Model")
	model.Name = spec.name
	model:SetAttribute(Palms.standInAttribute, true)
	for _, part in Palms.fallback(t, spec.folder, spec.name) do
		makePart(part).Parent = model
	end
	return model
end

return Palms
