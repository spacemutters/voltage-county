--!strict
-- The moving parts of exclusive looks (Config/Customization exclusiveWraps; Vehicle/Appearance builds the rest):
--
--   * Pearls: every part Appearance tagged Customization.pearl.tag drifts between its two colors (the
--     pearl.fromAttribute and pearl.toAttribute attributes) by Customization.pearlMix on the server clock, so every
--     client and every part of a car show the same shade at the same moment. One Heartbeat connection, only while
--     such parts are streamed in, writing pearl.updateHz times a second to at most pearl.maxParts parts.
--   * Underglow: every PointLight tagged Customization.underglow.lightTag shines at the day or night brightness for
--     Lighting.ClockTime (Customization.underglowBrightness), switched when the clock crosses dusk or dawn.
--
-- Client-side only: the colors and brightness written here never replicate, so the server's look stays the record,
-- and a pearl that comes off ends on the server's color. Works on the Wrap & Tint shop's client-only preview too.
-- No polling: CollectionService signals, Lighting's ClockTime signal and the one throttled Heartbeat.

local CollectionService = game:GetService("CollectionService")
local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Customization = require(ReplicatedStorage.Shared.Config.Customization)

local PEARL = Customization.pearl
local GLOW = Customization.underglow

local LookEffectsController = {}

-- A drifting part: the color it drifts from (its look's own) and the color this client last wrote, if any.
type Pearl = { from: Color3, written: Color3? }

local pearls: { [BasePart]: Pearl } = {}
local pearlCount = 0
local heartbeat: RBXScriptConnection? = nil
local sinceWrite = 0

local lights: { [PointLight]: boolean } = {}
local night: boolean? = nil

-- Pearls ---------------------------------------------------------------------------------------------------------

local function colorsOf(part: BasePart): (Color3?, Color3?)
	local from, to = part:GetAttribute(PEARL.fromAttribute), part:GetAttribute(PEARL.toAttribute)
	if typeof(from) == "Color3" and typeof(to) == "Color3" then
		return from, to
	end
	return nil, nil
end

-- Every drifting part at the shade for now. The colors are read each time: a look that swaps one pearl for another
-- keeps the tag and changes only the attributes.
local function writePearls()
	local mix = Customization.pearlMix(Workspace:GetServerTimeNow(), PEARL.seconds)
	for part, pearl in pearls do
		local from, to = colorsOf(part)
		if from ~= nil and to ~= nil then
			part.Color = from:Lerp(to, mix)
			-- Read back: a part stores its color in whole 0..255 steps, and removePearl compares with what is stored.
			pearl.from, pearl.written = from, part.Color
		end
	end
end

local function onHeartbeat(dt: number)
	sinceWrite += dt
	if sinceWrite < 1 / PEARL.updateHz then
		return
	end
	sinceWrite = 0
	writePearls()
end

-- The Heartbeat runs only while there is something to drift.
local function updateHeartbeat()
	local connection = heartbeat
	if pearlCount > 0 and connection == nil then
		sinceWrite = math.huge -- the first frame writes at once
		heartbeat = RunService.Heartbeat:Connect(onHeartbeat)
	elseif pearlCount == 0 and connection ~= nil then
		connection:Disconnect()
		heartbeat = nil
	end
end

local function addPearl(instance: Instance)
	if not instance:IsA("BasePart") or pearls[instance] ~= nil or pearlCount >= PEARL.maxParts then
		return
	end
	local from = colorsOf(instance)
	pearls[instance] = { from = from or instance.Color, written = nil }
	pearlCount += 1
	updateHeartbeat()
end

-- A pearl that came off. When nothing replaced the color this client last wrote, the server's color never changed
-- (the look kept the same body color), so the part goes back to it; otherwise the server's new color is already on.
local function removePearl(instance: Instance)
	if not instance:IsA("BasePart") then
		return
	end
	local pearl = pearls[instance]
	if pearl == nil then
		return
	end
	pearls[instance] = nil
	pearlCount -= 1
	if pearl.written ~= nil and instance.Color == pearl.written then
		instance.Color = pearl.from
	end
	updateHeartbeat()
end

-- Underglow ------------------------------------------------------------------------------------------------------

local function addLight(instance: Instance)
	if instance:IsA("PointLight") then
		lights[instance] = true
		instance.Brightness = Customization.underglowBrightness(Lighting.ClockTime)
	end
end

local function removeLight(instance: Instance)
	if instance:IsA("PointLight") then
		lights[instance] = nil
	end
end

-- Lighting's clock moved: only dusk and dawn change anything.
local function onClock()
	local clock = Lighting.ClockTime
	local isNight = Customization.isNight(clock)
	if isNight == night then
		return
	end
	night = isNight
	local brightness = Customization.underglowBrightness(clock)
	for light in lights do
		light.Brightness = brightness
	end
end

-- Boot -----------------------------------------------------------------------------------------------------------

function LookEffectsController:Start()
	CollectionService:GetInstanceAddedSignal(PEARL.tag):Connect(addPearl)
	CollectionService:GetInstanceRemovedSignal(PEARL.tag):Connect(removePearl)
	for _, instance in CollectionService:GetTagged(PEARL.tag) do
		addPearl(instance)
	end

	CollectionService:GetInstanceAddedSignal(GLOW.lightTag):Connect(addLight)
	CollectionService:GetInstanceRemovedSignal(GLOW.lightTag):Connect(removeLight)
	for _, instance in CollectionService:GetTagged(GLOW.lightTag) do
		addLight(instance)
	end
	night = Customization.isNight(Lighting.ClockTime)
	Lighting:GetPropertyChangedSignal("ClockTime"):Connect(onClock)
end

return LookEffectsController
