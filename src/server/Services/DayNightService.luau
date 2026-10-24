--!strict
-- The day/night cycle (docs/roast-2026-10-24.md point 3; Config/Environment dayNight and nightLights).
--
--   the clock   Lighting.ClockTime runs through a full day in dayNight.dayLengthMinutes real minutes (24 by
--               default), dawn to dawn: the day (dawnClock to duskClock) takes 1 - nightShare of it and the night
--               (duskClock round midnight to dawnClock) nightShare, so the night is shorter than the day. A new
--               server starts at startClock. The server moves the clock every stepSeconds (a RunService.Heartbeat
--               connection that adds up frame times, no loop); Lighting replicates it to every client.
--   the sky     Lighting.Ambient, OutdoorAmbient, FogColor and Brightness and the Atmosphere's Color and Decay follow
--               the clock, blended between dayNight.keyframes (dawn and dusk warm, night dark blue). Lighting gets an
--               Atmosphere (dayNight.atmosphere) if it has none; one already there is driven as it is.
--   the lights  every part tagged nightLights.tag (Dev/MapBuilder tags streetlight heads, lit windows, the diner's
--               neon and windows, the water tower's beacon, the bridge's arches and the Ohm sign's light bar) has a
--               kind (nightLights.kindAttribute) and its day colour (dayColorAttribute). When the clock crosses dusk
--               the server switches them all to their kind's night look (its material and colour, and any Light in
--               the part on); when it crosses dawn, back to their day look. Only when the clock crosses the line,
--               never every frame, a few hundred parts a frame (flipPerStep). A tagged part that appears later takes
--               the current look. Lighting's nightLights.nightAttribute says which it is (true at night).
--   Studio      set Lighting's nightLights.devClockAttribute (a number of hours) to jump the clock there, in a
--               playtest, from the command bar or the Properties panel: Lighting:SetAttribute("DevClockTime", 20).
--               Outside Studio the attribute is ignored.
--
-- The maths is pure and exported for tests/DayNight.spec: clockAt (seconds into the cycle -> clock), secondsAt (its
-- inverse), isNight (the line), lookAt (the sky at a clock) and nightLook (a night light's look).

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
	return {
		ambient = before.ambient:Lerp(after.ambient, alpha),
		outdoorAmbient = before.outdoorAmbient:Lerp(after.outdoorAmbient, alpha),
		fogColor = before.fogColor:Lerp(after.fogColor, alpha),
		atmosphereColor = before.atmosphereColor:Lerp(after.atmosphereColor, alpha),
		atmosphereDecay = before.atmosphereDecay:Lerp(after.atmosphereDecay, alpha),
		brightness = before.brightness + (after.brightness - before.brightness) * alpha,
	}
end

-- Pure: the lights ---------------------------------------------------------------------------------------------------

-- A night light of `kind` at night or by day: its material and colour (`dayColor` by day). Nil for an unknown kind.
function DayNightService.nightLook(kind: string, night: boolean, dayColor: Color3): (Enum.Material?, Color3?)
	local look = LIGHTS.kinds[kind]
	if look == nil then
		return nil, nil
	end
	if night then
		return look.nightMaterial, look.nightColor
	end
	return look.dayMaterial, dayColor
end

-- Running ------------------------------------------------------------------------------------------------------------

local startPhase = 0 -- seconds into the cycle when the clock was last set
local startedAt = 0 -- os.clock() then
local night: boolean? = nil
local atmosphere: Atmosphere? = nil
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
	local material, color = DayNightService.nightLook(kind, isNight, dayColor)
	if material == nil or color == nil then
		return
	end
	part.Material = material
	part.Color = color
	for _, child in part:GetChildren() do
		if child:IsA("Light") then
			child.Enabled = isNight
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

local function apply(clock: number)
	local look = DayNightService.lookAt(clock)
	Lighting.ClockTime = clock
	Lighting.Ambient = look.ambient
	Lighting.OutdoorAmbient = look.outdoorAmbient
	Lighting.FogColor = look.fogColor
	Lighting.Brightness = look.brightness
	local sky = atmosphere
	if sky then
		sky.Color = look.atmosphereColor
		sky.Decay = look.atmosphereDecay
	end
	local isNight = DayNightService.isNight(clock)
	if isNight ~= night then
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

-- Lighting's Atmosphere, made from Config/Environment when there is none.
local function findAtmosphere(): Atmosphere
	local found = Lighting:FindFirstChildOfClass("Atmosphere")
	if found then
		return found
	end
	local settings = DAY_NIGHT.atmosphere
	local made = Instance.new("Atmosphere")
	made.Name = settings.name
	made.Density = settings.density
	made.Offset = settings.offset
	made.Glare = settings.glare
	made.Haze = settings.haze
	made.Parent = Lighting
	return made
end

-- Boot ---------------------------------------------------------------------------------------------------------------

function DayNightService:Start()
	atmosphere = findAtmosphere()
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
