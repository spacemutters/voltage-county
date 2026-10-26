--!strict
-- Edit-mode previews of city archetypes (docs/city/ARCHETYPE_GUIDE.md "Look at your work"). Builds sample sites into
-- Workspace.CityPreview, on the open grass south of the county (z 3,600..4,400), exactly as MapBuilder.build() would
-- build them, so a helper can photograph an archetype without rebuilding the map. Studio and Edit mode only (hard rules
-- 8 and 9); it owns only Workspace.CityPreview and puts the camera and Lighting back as it found them.
--
--   local Preview = require(game.ServerScriptService.Server.Dev.City.Preview)
--   Preview.lighting(true)                                -- the game's runtime light: shadows, sky light, reflections
--   Preview.row("deco_stripe_hotel", { count = 3 })       -- three variants side by side
--   Preview.camera(Vector3.new(0, 30, 3900), Vector3.new(0, 20, 4000))
--   ... screen_capture ...
--   Preview.clear()                                       -- removes the models, restores the camera and Lighting

local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local City = require(ReplicatedStorage.Shared.Config.City)
local CityBuilder = require(script.Parent.CityBuilder)
local DayNightService = require(script.Parent.Parent.Parent.Services.DayNightService)
local MapBuilder = require(script.Parent.Parent.MapBuilder)
local Palms = require(script.Parent.Scenery.Palms)
local Types = require(script.Parent.Types)

export type Options = {
	width: number?, -- default: halfway between the archetype's minWidth and maxWidth
	depth: number?, -- default 53, a full plot
	height: number?, -- default: the middle of its heights
	variant: Types.Variant?,
	seed: number?,
	at: Vector3?, -- the footprint's centre on the ground
	facing: ("south" | "north")?, -- where its front faces (default south, into the afternoon sun)
	count: number?, -- row(): how many
	gap: number?, -- row(): studs between neighbours
}

local ROOT = "CityPreview"
local ORIGIN = Vector3.new(0, 0, 4000)

local Preview = {}

local function guard()
	if not RunService:IsStudio() or RunService:IsRunning() then
		error("City Preview runs in Studio's Edit mode only", 3)
	end
end

local function root(): Instance
	local folder = Workspace:FindFirstChild(ROOT)
	if folder == nil then
		local made = Instance.new("Folder")
		made.Name = ROOT
		made.Parent = Workspace
		folder = made
	end
	return folder :: Instance
end

-- Builds one sample site and returns its model (named after the archetype and seed), or errors with the site's
-- problems.
function Preview.build(archetype: string, options: Options?): Model
	guard()
	local o: Options = options or {}
	local config = City.archetypes[archetype] or error(`no archetype {archetype} in Config/City`)
	local width = o.width or (config.minWidth + config.maxWidth) / 2
	local depth = o.depth or 53
	local height = o.height or (config.heights.min + config.heights.max) / 2
	local seed = o.seed or 1
	local variant: Types.Variant = o.variant or { palette = 1, crown = 1, rhythm = 1, mirror = false }
	-- Its front faces south (+Z), into the afternoon sun, so the photographs show the facade lit; stand south of it.
	local at = o.at or ORIGIN
	local facing = if o.facing == "north" then -Vector3.zAxis else Vector3.zAxis
	local frame = CFrame.lookAt(at, at + facing)
	local site = CityBuilder.sampleSite(archetype, frame, width, depth, height, variant, seed)
	local specs, problem = CityBuilder.build(site)
	if specs == nil then
		error(problem, 2)
	end
	local model = Instance.new("Model")
	model.Name = `{archetype}_{seed}_{variant.palette}{variant.crown}{variant.rhythm}`
	model:SetAttribute("Parts", #specs)
	for _, spec in specs do
		-- A templated piece (the street front's café sets and planters) is cloned from its template, as the build does.
		if spec.template then
			Palms.instantiate(spec, MapBuilder.createPart).Parent = model
		else
			MapBuilder.createPart(spec).Parent = model
		end
	end
	model.Parent = root()
	return model
end

-- `count` copies side by side along x, each a different variant and seed, the first at `at`.
function Preview.row(archetype: string, options: Options?): { Model }
	local o: Options = options or {}
	local config = City.archetypes[archetype] or error(`no archetype {archetype} in Config/City`)
	local width = o.width or (config.minWidth + config.maxWidth) / 2
	local at = o.at or ORIGIN
	local models: { Model } = {}
	for i = 1, o.count or 3 do
		local copy = table.clone(o)
		copy.at = at + Vector3.new((i - 1) * (width + (o.gap or 20)), 0, 0)
		copy.seed = (o.seed or 1) + i - 1
		copy.variant = o.variant
			or {
				palette = (i - 1) % config.palettes + 1,
				crown = (i - 1) % config.crowns + 1,
				rhythm = (i - 1) % config.rhythms + 1,
				mirror = i % 2 == 0,
			}
		table.insert(models, Preview.build(archetype, copy))
	end
	return models
end

-- What the preview changed, kept as attributes on Workspace.CityPreview (each execute_luau may require a fresh copy
-- of this module, so module state wouldn't last until clear()).
local LIGHTING_KEYS = {
	"GlobalShadows",
	"ShadowSoftness",
	"EnvironmentSpecularScale",
	"EnvironmentDiffuseScale",
	"ClockTime",
	"Ambient",
	"OutdoorAmbient",
	"Brightness",
}

-- Points the camera from `from` at `target` (Scriptable); clear() puts it back.
function Preview.camera(from: Vector3, target: Vector3)
	guard()
	local folder = root()
	local camera = Workspace.CurrentCamera
	if folder:GetAttribute("SavedCamera") == nil then
		folder:SetAttribute("SavedCamera", camera.CFrame)
		folder:SetAttribute("SavedCameraType", camera.CameraType.Name)
	end
	camera.CameraType = Enum.CameraType.Scriptable
	camera.CFrame = CFrame.lookAt(from, target)
end

-- The light the game runs with (Config/Environment dayNight.scene; a 2 pm sun unless `clock` says otherwise) on, or
-- back as it was: the scene's shadows, sky light and reflections, and the sky's ambient, outdoor ambient and
-- brightness at that clock (Services/DayNightService.lookAt), so a day shot is as bright as the game's. Edit mode
-- starts with shadows and sky light off, which hides every edge the city is built to show.
function Preview.lighting(on: boolean, clock: number?)
	guard()
	local folder = root()
	local lighting: any = Lighting
	if on then
		if folder:GetAttribute("SavedLighting") == nil then
			folder:SetAttribute("SavedLighting", true)
			for _, key in LIGHTING_KEYS do
				folder:SetAttribute(`Saved{key}`, lighting[key])
			end
			folder:SetAttribute("SavedLightingStyle", lighting.LightingStyle.Name)
			folder:SetAttribute("SavedPrioritize", lighting.PrioritizeLightingQuality)
		end
		local scene = require(ReplicatedStorage.Shared.Config.Environment).dayNight.scene
		lighting.GlobalShadows = scene.globalShadows
		lighting.ShadowSoftness = scene.shadowSoftness
		lighting.EnvironmentSpecularScale = scene.environmentSpecularScale
		lighting.EnvironmentDiffuseScale = scene.environmentDiffuseScale
		lighting.LightingStyle = Enum.LightingStyle.Realistic
		lighting.PrioritizeLightingQuality = true
		local at = clock or 14
		local sky = DayNightService.lookAt(at)
		lighting.ClockTime = at
		lighting.Ambient = sky.ambient
		lighting.OutdoorAmbient = sky.outdoorAmbient
		lighting.Brightness = sky.brightness
	elseif folder:GetAttribute("SavedLighting") then
		for _, key in LIGHTING_KEYS do
			local value = folder:GetAttribute(`Saved{key}`)
			if value ~= nil then
				lighting[key] = value
			end
		end
		lighting.LightingStyle = (Enum.LightingStyle :: any)[folder:GetAttribute("SavedLightingStyle")]
		lighting.PrioritizeLightingQuality = folder:GetAttribute("SavedPrioritize")
		folder:SetAttribute("SavedLighting", nil)
	end
end

-- Night (or back to day): the preview models' night lights in their night look under the night sky (21:00), or the
-- day sky again (14:00). Each light looks exactly as Services/DayNightService makes it at runtime (DayNightService
-- nightLook and signBrightness): its own NightColor first, a keepDayColor kind (stained glass) in its day colour,
-- a light show's colour on night `nightNumber` (default 1), and the kind's sign text brightness. Call lighting(true)
-- first.
function Preview.night(on: boolean, nightNumber: number?)
	guard()
	local Environment = require(ReplicatedStorage.Shared.Config.Environment)
	local lights = Environment.nightLights
	local folder = root()
	local lighting: any = Lighting
	local sky = DayNightService.lookAt(if on then 21 else 14)
	lighting.ClockTime = if on then 21 else 14
	lighting.Ambient = sky.ambient
	lighting.OutdoorAmbient = sky.outdoorAmbient
	lighting.Brightness = sky.brightness
	for _, part in folder:GetDescendants() do
		if part:IsA("BasePart") and part:HasTag(lights.tag) then
			local kind = part:GetAttribute(lights.kindAttribute)
			local dayColor = part:GetAttribute(lights.dayColorAttribute)
			if type(kind) == "string" and typeof(dayColor) == "Color3" then
				local own = part:GetAttribute(lights.nightColorAttribute)
				local override: Color3? = if typeof(own) == "Color3" then own else nil
				local material, color = DayNightService.nightLook(kind, on, dayColor, nightNumber or 1, override)
				if material and color then
					part.Material = material
					part.Color = color
				end
				local text = DayNightService.signBrightness(kind, on)
				for _, child in part:GetChildren() do
					if child:IsA("Light") then
						child.Enabled = on
					elseif text ~= nil and child:IsA("SurfaceGui") then
						child.Brightness = text
					end
				end
			end
		end
	end
end

-- Removes every preview model and puts the camera and Lighting back.
function Preview.clear()
	guard()
	local folder = Workspace:FindFirstChild(ROOT)
	if folder == nil then
		return
	end
	local saved = folder:GetAttribute("SavedCamera")
	if typeof(saved) == "CFrame" then
		local camera = Workspace.CurrentCamera
		camera.CameraType = (Enum.CameraType :: any)[folder:GetAttribute("SavedCameraType")]
		camera.CFrame = saved
	end
	Preview.lighting(false)
	folder:Destroy()
end

return Preview
