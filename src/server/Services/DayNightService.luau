--!strict
-- The day/night cycle and the city's lighting look (docs/roast-2026-10-24.md point 3, docs/city/TECH.md §1,
-- docs/city/SCENERY.md §9; Config/Environment dayNight and nightLights).
--
--   the scene   set once at server start from dayNight.scene: the Realistic lighting style with lighting quality put
--               before view distance, the latitude (a high subtropical sun), shadows, sky light and reflections, the
--               Default tone mapper on Lighting's ColorGradingEffect, the bloom effect's size, a colour grade and sun
--               rays. Effects already under Lighting are reused, missing ones made. The engine's newer switches are
--               set inside a pcall, so a refusal warns and the clock still runs.
--   the clock   Lighting.ClockTime runs through a full day in dayNight.dayLengthMinutes real minutes (24 by
--               default), dawn to dawn: the day (dawnClock to duskClock) takes 1 - nightShare of it and the night
--               (duskClock round midnight to dawnClock) nightShare, so the night is shorter than the day. A new
--               server starts at startClock. The server moves the clock every stepSeconds (a RunService.Heartbeat
--               connection that adds up frame times, no loop); Lighting replicates it to every client.
--   the sky     Lighting.Ambient, OutdoorAmbient, FogColor, Brightness, ColorShift_Top and ExposureCompensation, the
--               Atmosphere's Color, Decay, Density, Haze and Glare, the colour grade's tint and the bloom's Intensity
--               and Threshold follow the clock, blended between dayNight.keyframes (warm bright days, pink-orange golden
--               hours, deep blue nights where neon halos). Lighting gets an Atmosphere (dayNight.atmosphere) and a Sky
--               (scene.sky: without one the night sky stays black under any atmosphere) if it has none.
--   the lights  every part tagged nightLights.tag (Dev/MapBuilder and the city kit tag streetlight heads, lit windows,
--               neon, crowns, LED edges, washes, signs, the water tower's beacon and the bridge's arches) has a kind
--               (nightLights.kindAttribute) and its day colour (dayColorAttribute). When the clock crosses dusk the
--               server switches them all to their kind's night look (its material and colour, any Light in the part
--               on, and on sign kinds their text brighter); when it crosses dawn, back to their day look. Only when
--               the clock crosses the line, never every frame, a few hundred parts a frame (flipPerStep). A part's
--               own NightColor attribute beats its kind's colour; a light show kind picks one colour per night. A
--               tagged part that appears later takes the current look. Lighting's nightLights.nightAttribute says
--               which it is (true at night).
--   Studio      set Lighting's nightLights.devClockAttribute (a number of hours) to jump the clock there, in a
--               playtest, from the command bar or the Properties panel: Lighting:SetAttribute("DevClockTime", 20).
--               Outside Studio the attribute is ignored. In Edit mode, DayNightService.preview(clock) puts the scene
--               and the sky on at a clock without starting the cycle (for screenshots through execute_luau).
--
-- The maths is pure and exported for tests/DayNight.spec: clockAt (seconds into the cycle -> clock), secondsAt (its
-- inverse), isNight (the line), lookAt (the sky at a clock), nightLook (a night light's look), showColor (a light
-- show's colour on a night) and signBrightness (a sign's text brightness).

local CollectionService = game:GetService("CollectionService")
local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Environment = require(ReplicatedStorage.Shared.Config.Environment)

local DAY_NIGHT = Environment.dayNight
local LIGHTS = Environment.nightLights
local HOURS = 24
local SECONDS_PER_MINUTE = 60

export type Look = {
	ambient: Color3,
	outdoorAmbient: Color3,
	fogColor: Color3,
	atmosphereColor: Color3,
	atmosphereDecay: Color3,
	brightness: number,
	colorShiftTop: Color3,
	exposure: number,
	bloomIntensity: number,
	bloomThreshold: number,
	tint: Color3,
	density: number,
	haze: number,
	glare: number,
}

local DayNightService = {}

-- Pure: the clock ------------------------------------------------------------------------------------------------

-- Hours from dusk round midnight to dawn.
local function nightHours(cycle: Environment.Cycle): number
	return (cycle.dawnClock - cycle.duskClock) % HOURS
end

-- Real seconds in a full day.
function DayNightService.cycleSeconds(cycle: Environment.Cycle?): number
	local shape = cycle or DAY_NIGHT
	return shape.dayLengthMinutes * SECONDS_PER_MINUTE
end

-- Real seconds from dawn to dusk and from dusk to dawn.
local function spans(cycle: Environment.Cycle): (number, number)
	local total = DayNightService.cycleSeconds(cycle)
	return total * (1 - cycle.nightShare), total * cycle.nightShare
end

-- Lighting.ClockTime (hours, 0 <= clock < 24) `seconds` into the cycle, which starts at dawn: by day the clock runs
-- from dawnClock to duskClock over the day's seconds, by night from duskClock round midnight to dawnClock over the
-- night's. Any number of seconds, negative included, wraps round the cycle.
function DayNightService.clockAt(seconds: number, cycle: Environment.Cycle?): number
	local shape = cycle or DAY_NIGHT
	local day, night = spans(shape)
	local phase = seconds % (day + night)
	local clock: number
	if phase < day then
		clock = shape.dawnClock + (HOURS - nightHours(shape)) * phase / day
	else
		clock = shape.duskClock + nightHours(shape) * (phase - day) / night
	end
	return clock % HOURS
end

-- Whether `clock` (hours) is night: from duskClock (on) round midnight to dawnClock (off).
function DayNightService.isNight(clock: number, cycle: Environment.Cycle?): boolean
	local shape = cycle or DAY_NIGHT
	local fromDusk = (clock - shape.duskClock) % HOURS
	return fromDusk < nightHours(shape)
end

-- The seconds into the cycle (0 <= seconds < cycleSeconds) at which the clock reads `clock`: clockAt's inverse.
function DayNightService.secondsAt(clock: number, cycle: Environment.Cycle?): number
	local shape = cycle or DAY_NIGHT
	local day, night = spans(shape)
	if DayNightService.isNight(clock, shape) then
		local hours = (clock - shape.duskClock) % HOURS
		return day + night * hours / nightHours(shape)
	end
	local hours = (clock - shape.dawnClock) % HOURS
	return day * hours / (HOURS - nightHours(shape))
end

-- Pure: the sky ----------------------------------------------------------------------------------------------------

local function lerp(a: number, b: number, alpha: number): number
	return a + (b - a) * alpha
end

-- The sky at `clock`: the two keyframes either side of it blended (after the last, round midnight into the first).
-- Keyframes are in clock order.
function DayNightService.lookAt(clock: number, keyframes: { Environment.Keyframe }?): Look
	local frames = keyframes or DAY_NIGHT.keyframes
	local at = clock % HOURS
	local count = #frames
	-- Before the first keyframe: between the last and the first, round midnight.
	local before, after = frames[count], frames[1]
	for i, frame in frames do
		if frame.clock <= at then
			before = frame
			after = frames[i % count + 1]
		end
	end
	local gap = (after.clock - before.clock) % HOURS
	local alpha = if gap > 0 then ((at - before.clock) % HOURS) / gap else 0
	-- The optional fields fall back to the scene's colour grade and the atmosphere's settings.
	local grade = DAY_NIGHT.scene.colorCorrection.tintColor
	local air = DAY_NIGHT.atmosphere
	return {
		ambient = before.ambient:Lerp(after.ambient, alpha),
		outdoorAmbient = before.outdoorAmbient:Lerp(after.outdoorAmbient, alpha),
		fogColor = before.fogColor:Lerp(after.fogColor, alpha),
		atmosphereColor = before.atmosphereColor:Lerp(after.atmosphereColor, alpha),
		atmosphereDecay = before.atmosphereDecay:Lerp(after.atmosphereDecay, alpha),
		brightness = lerp(before.brightness, after.brightness, alpha),
		colorShiftTop = before.colorShiftTop:Lerp(after.colorShiftTop, alpha),
		exposure = lerp(before.exposure, after.exposure, alpha),
		bloomIntensity = lerp(before.bloomIntensity, after.bloomIntensity, alpha),
		bloomThreshold = lerp(before.bloomThreshold, after.bloomThreshold, alpha),
		tint = (before.tint or grade):Lerp(after.tint or grade, alpha),
		density = lerp(before.density or air.density, after.density or air.density, alpha),
		haze = lerp(before.haze or air.haze, after.haze or air.haze, alpha),
		glare = lerp(before.glare or air.glare, after.glare or air.glare, alpha),
	}
end

-- Pure: the lights ---------------------------------------------------------------------------------------------------

-- A light show's colour on night number `nightNumber`: on look.showShare of the nights one of look.showColors (the
-- same one for the whole night, picked from the night's number and nightLights.showSeed), otherwise look.nightColor.
-- A look without a show is always its nightColor.
function DayNightService.showColor(look: Environment.NightLook, nightNumber: number): Color3
	local colors = look.showColors
	local share = look.showShare or 0
	if colors == nil or #colors == 0 or share <= 0 then
		return look.nightColor
	end
	local random = Random.new(LIGHTS.showSeed + math.floor(nightNumber))
	if random:NextNumber() >= share then
		return look.nightColor
	end
	return colors[random:NextInteger(1, #colors)]
end

-- A night light of `kind` at night or by day: its material and colour. By day `dayColor`; at night the part's own
-- `override` (its NightColor attribute) if it has one, else its day colour for a keepDayColor kind, else the kind's
-- colour on night number `nightNumber` (1 if not given; it only matters to a light show). Nil for an unknown kind.
function DayNightService.nightLook(
	kind: string,
	night: boolean,
	dayColor: Color3,
	nightNumber: number?,
	override: Color3?
): (Enum.Material?, Color3?)
	local look = LIGHTS.kinds[kind]
	if look == nil then
		return nil, nil
	end
	if not night then
		return look.dayMaterial, dayColor
	end
	if override then
		return look.nightMaterial, override
	end
	if look.keepDayColor then
		return look.nightMaterial, dayColor
	end
	return look.nightMaterial, DayNightService.showColor(look, nightNumber or 1)
end

-- SurfaceGui.Brightness for the sign text on a night light of `kind`: the kind's guiBrightness at night,
-- nightLights.dayGuiBrightness by day. Nil when the kind leaves its text alone (or is unknown).
function DayNightService.signBrightness(kind: string, night: boolean): number?
	local look = LIGHTS.kinds[kind]
	if look == nil or look.guiBrightness == nil then
		return nil
	end
	return if night then look.guiBrightness else LIGHTS.dayGuiBrightness
end

-- Running ------------------------------------------------------------------------------------------------------------

local startPhase = 0 -- seconds into the cycle when the clock was last set
local startedAt = 0 -- os.clock() then
local night: boolean? = nil
local nightNumber = 0 -- counts the nights; a light show's colour follows it
local atmosphere: Atmosphere? = nil
local bloom: BloomEffect? = nil
local grading: ColorCorrectionEffect? = nil
local flipToken = 0

-- One tagged part in the day or night look.
local function applyPart(part: BasePart, isNight: boolean)
	local kind = part:GetAttribute(LIGHTS.kindAttribute)
	if type(kind) ~= "string" then
		return
	end
	local stored = part:GetAttribute(LIGHTS.dayColorAttribute)
	local dayColor: Color3 = if typeof(stored) == "Color3" then stored else part.Color
	if typeof(stored) ~= "Color3" then
		-- Hand-placed lamps: remember the day colour before the first night changes it.
		part:SetAttribute(LIGHTS.dayColorAttribute, dayColor)
	end
	local own = part:GetAttribute(LIGHTS.nightColorAttribute)
	local override: Color3? = if typeof(own) == "Color3" then own else nil
	local material, color = DayNightService.nightLook(kind, isNight, dayColor, nightNumber, override)
	if material == nil or color == nil then
		return
	end
	part.Material = material
	part.Color = color
	local text = DayNightService.signBrightness(kind, isNight)
	for _, child in part:GetChildren() do
		if child:IsA("Light") then
			child.Enabled = isNight
		elseif text ~= nil and child:IsA("SurfaceGui") then
			child.Brightness = text
		end
	end
end

-- Every tagged part in the day or night look, flipPerStep a frame. A newer flip stops an older one part-way.
local function flipAll(isNight: boolean)
	flipToken += 1
	local token = flipToken
	for i, instance in CollectionService:GetTagged(LIGHTS.tag) do
		if token ~= flipToken then
			return
		end
		if instance:IsA("BasePart") then
			applyPart(instance, isNight)
		end
		if i % LIGHTS.flipPerStep == 0 then
			task.wait()
		end
	end
end

-- Lighting, its Atmosphere and its bloom in the sky's look at `clock`.
local function applySky(clock: number)
	local look = DayNightService.lookAt(clock)
	Lighting.ClockTime = clock
	Lighting.Ambient = look.ambient
	Lighting.OutdoorAmbient = look.outdoorAmbient
	Lighting.FogColor = look.fogColor
	Lighting.Brightness = look.brightness
	Lighting.ColorShift_Top = look.colorShiftTop
	Lighting.ExposureCompensation = look.exposure
	local sky = atmosphere
	if sky then
		sky.Color = look.atmosphereColor
		sky.Decay = look.atmosphereDecay
		sky.Density = look.density
		sky.Haze = look.haze
		sky.Glare = look.glare
	end
	local grade = grading
	if grade then
		grade.TintColor = look.tint
	end
	local glow = bloom
	if glow then
		glow.Intensity = look.bloomIntensity
		glow.Threshold = look.bloomThreshold
	end
end

-- The sky at `clock`, and the night lights switched when the clock crossed dusk or dawn.
local function apply(clock: number)
	applySky(clock)
	local isNight = DayNightService.isNight(clock)
	if isNight ~= night then
		if isNight then
			nightNumber += 1
		end
		night = isNight
		Lighting:SetAttribute(LIGHTS.nightAttribute, isNight)
		task.spawn(flipAll, isNight)
	end
end

local function step()
	apply(DayNightService.clockAt(startPhase + os.clock() - startedAt))
end

-- Sets the clock to `clock` (hours) from now on.
local function setClock(clock: number)
	startPhase = DayNightService.secondsAt(clock % HOURS)
	startedAt = os.clock()
	step()
end

-- Lighting's Atmosphere (made when there is none) with Config/Environment's density, offset, glare and haze.
local function findAtmosphere(): Atmosphere
	local settings = DAY_NIGHT.atmosphere
	local sky = Lighting:FindFirstChildOfClass("Atmosphere")
	if sky == nil then
		local made = Instance.new("Atmosphere")
		made.Name = settings.name
		sky = made
	end
	local found = sky :: Atmosphere
	found.Density = settings.density
	found.Offset = settings.offset
	found.Glare = settings.glare
	found.Haze = settings.haze
	found.Parent = Lighting
	return found
end

-- Lighting's BloomEffect (made when there is none), switched on at Config/Environment's size; its intensity and
-- threshold follow the clock.
local function findBloom(): BloomEffect
	local settings = DAY_NIGHT.scene.bloom
	local glow = Lighting:FindFirstChildOfClass("BloomEffect")
	if glow == nil then
		local made = Instance.new("BloomEffect")
		made.Name = settings.name
		glow = made
	end
	local found = glow :: BloomEffect
	found.Size = settings.size
	found.Enabled = true
	found.Parent = Lighting
	return found
end

-- The tone mapper on every ColorGradingEffect under Lighting (only the last one parented counts, so all get it), or
-- on a new one when there is none.
local function applyToneMapper()
	local settings = DAY_NIGHT.scene.toneMapper
	local graded = false
	for _, child in Lighting:GetChildren() do
		if child:IsA("ColorGradingEffect") then
			child.TonemapperPreset = settings.preset
			graded = true
		end
	end
	if not graded then
		local made = Instance.new("ColorGradingEffect")
		made.Name = settings.name
		made.TonemapperPreset = settings.preset
		made.Parent = Lighting
	end
end

-- Lighting's scene settings and effects from Config/Environment dayNight.scene, set once: the lighting style, the
-- latitude, shadows, sky light and reflections, the tone mapper, a little contrast and colour, and sun rays (an effect
-- already there under the same name is reused).
local function applyScene()
	local scene = DAY_NIGHT.scene
	Lighting.GlobalShadows = scene.globalShadows
	Lighting.ShadowSoftness = scene.shadowSoftness
	Lighting.EnvironmentSpecularScale = scene.environmentSpecularScale
	Lighting.EnvironmentDiffuseScale = scene.environmentDiffuseScale
	Lighting.GeographicLatitude = scene.geographicLatitude
	-- The lighting style and lighting-quality switch are place settings a game script may not write (they need Studio's
	-- capability): the place carries them, set in Studio (docs/LAUNCH.md). Edit-mode previews (preview(), with that
	-- capability) set them; a running server only says so when the place's differ.
	local styled = pcall(function()
		if
			Lighting.LightingStyle ~= scene.lightingStyle
			or Lighting.PrioritizeLightingQuality ~= scene.prioritizeLightingQuality
		then
			Lighting.LightingStyle = scene.lightingStyle
			Lighting.PrioritizeLightingQuality = scene.prioritizeLightingQuality
		end
	end)
	if not styled then
		warn(
			`DayNightService: set Lighting.LightingStyle to {scene.lightingStyle.Name} and PrioritizeLightingQuality to `
				.. `{scene.prioritizeLightingQuality} in Studio (a game script can't): the place has `
				.. `{Lighting.LightingStyle.Name} and {Lighting.PrioritizeLightingQuality}`
		)
	end
	local mapped, mapProblem = pcall(applyToneMapper)
	if not mapped then
		warn(`DayNightService: the tone mapper was not set: {mapProblem}`)
	end
	local grade = scene.colorCorrection
	local color = Lighting:FindFirstChild(grade.name) or Instance.new("ColorCorrectionEffect")
	if color:IsA("ColorCorrectionEffect") then
		color.Name = grade.name
		color.Contrast = grade.contrast
		color.Saturation = grade.saturation
		color.Brightness = grade.brightness
		color.TintColor = grade.tintColor
		color.Parent = Lighting
		grading = color
	end
	-- A Sky when the place has none: without one the engine's plain night sky stays black under any atmosphere.
	if Lighting:FindFirstChildOfClass("Sky") == nil then
		local settings = scene.sky
		local made = Instance.new("Sky")
		made.Name = settings.name
		made.SkyboxBk = string.format(settings.faces, "bk")
		made.SkyboxDn = string.format(settings.faces, "dn")
		made.SkyboxFt = string.format(settings.faces, "ft")
		made.SkyboxLf = string.format(settings.faces, "lf")
		made.SkyboxRt = string.format(settings.faces, "rt")
		made.SkyboxUp = string.format(settings.faces, "up")
		made.StarCount = settings.starCount
		made.Parent = Lighting
	end
	local rays = scene.sunRays
	local sun = Lighting:FindFirstChild(rays.name) or Instance.new("SunRaysEffect")
	if sun:IsA("SunRaysEffect") then
		sun.Name = rays.name
		sun.Intensity = rays.intensity
		sun.Spread = rays.spread
		sun.Parent = Lighting
	end
	atmosphere = findAtmosphere()
	bloom = findBloom()
end

-- Studio, Edit mode: the scene and the sky at `clock` (hours) as the game runs them, without starting the cycle (for
-- screenshots through execute_luau). It leaves the map's night lights alone, so a saved place never keeps a night look
-- (Dev/City/Preview.night switches its own models). It changes the place's Lighting as the game would at runtime, and
-- the effects it makes stay under Lighting; Dev/City/Preview keeps its own save-and-restore.
function DayNightService.preview(clock: number)
	if not RunService:IsStudio() or RunService:IsRunning() then
		error("DayNightService.preview runs in Studio's Edit mode only", 2)
	end
	applyScene()
	applySky(clock % HOURS)
end

-- Boot ---------------------------------------------------------------------------------------------------------------

function DayNightService:Start()
	-- Different servers' light shows start on different nights.
	nightNumber = os.time() // DayNightService.cycleSeconds()
	applyScene()
	setClock(DAY_NIGHT.startClock)

	local sinceStep = 0
	RunService.Heartbeat:Connect(function(deltaTime: number)
		sinceStep += deltaTime
		if sinceStep >= DAY_NIGHT.stepSeconds then
			sinceStep = 0
			step()
		end
	end)

	-- A night light that appears later (a part streamed or rebuilt in) takes the current look.
	CollectionService:GetInstanceAddedSignal(LIGHTS.tag):Connect(function(instance: Instance)
		local current = night
		if current ~= nil and instance:IsA("BasePart") then
			applyPart(instance, current)
		end
	end)

	if RunService:IsStudio() then
		local attribute = LIGHTS.devClockAttribute
		Lighting:GetAttributeChangedSignal(attribute):Connect(function()
			local wanted = Lighting:GetAttribute(attribute)
			if type(wanted) == "number" and wanted == wanted then
				setClock(wanted)
			end
		end)
	end
end

return DayNightService
