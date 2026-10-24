--!strict
-- The first spawn's hook (roast fixes 2026-10-24, docs/roast-2026-10-24.md point 8: "0:00 spawn already seated in the
-- Spark while the Arc boost-hops over you"; Config/Goals firstSpawn.flyover).
--
-- Services/SpawnFlowService seats a new player in their starter on the road and sets the flyover attribute on their
-- Player (the server clock). This controller then, once a session, flies a copy of the dealership's display Arc over
-- their car: it takes off behind it, arcs over the roof and comes down ahead in the other lane, rolls on and fades
-- out. The copy is made on this client only, every part anchored and never solid, with no prompts, scripts, sounds or
-- tags, so nothing else in the game sees it and nobody can sit in it or hit it. If the display car hasn't streamed in
-- (or the player isn't in a car any more) nothing happens.
--
-- No polling: the attribute's changed signal, one task.delay and one RenderStepped connection for the 3 s it flies.
-- The hop's shape is a pure helper (hopFrame) for tests/Goals.spec.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Dealership = require(ReplicatedStorage.Shared.Config.Dealership)
local Goals = require(ReplicatedStorage.Shared.Config.Goals)
local DriveController = require(script.Parent.DriveController)

local FLYOVER = Goals.firstSpawn.flyover
local MIN_DIRECTION = 1e-3 -- a car pointing straight up or down has no direction across the ground

local ArcFlyoverController = {}

local played = false

-- Pure: the hop -------------------------------------------------------------------------------------------------

-- Where the Arc is `t` of the way through the hop (0 at take-off, 1 at touch-down) from `from` to `to`, rising
-- `peak` studs above the straight line at the middle, its nose along the way it is moving.
function ArcFlyoverController.hopFrame(from: Vector3, to: Vector3, peak: number, t: number): CFrame
	local s = math.clamp(t, 0, 1)
	local position = from:Lerp(to, s) + Vector3.yAxis * (4 * peak * s * (1 - s))
	local velocity = (to - from) + Vector3.yAxis * (4 * peak * (1 - 2 * s))
	if velocity.Magnitude < MIN_DIRECTION then
		return CFrame.new(position)
	end
	return CFrame.lookAt(position, position + velocity)
end

-- The world -------------------------------------------------------------------------------------------------------

-- The dealership's display car of `vehicleId`, when it has streamed in here.
local function displayCar(vehicleId: string): Model?
	local showroom = Workspace:FindFirstChild(Dealership.display.folderName)
	local folder = if showroom ~= nil then showroom:FindFirstChild(Dealership.display.dealershipFolderName) else nil
	if folder == nil then
		return nil
	end
	for _, child in folder:GetChildren() do
		if child:IsA("Model") and child:GetAttribute(Dealership.prompt.vehicleIdAttribute) == vehicleId then
			return child
		end
	end
	return nil
end

local function untag(instance: Instance)
	for _, tag in CollectionService:GetTags(instance) do
		CollectionService:RemoveTag(instance, tag)
	end
end

-- A look-only copy of `model`: anchored, never solid, no prompts, scripts, sounds or tags. Its parts, for the fade.
local function ghostOf(model: Model): (Model, { BasePart })
	local copy = model:Clone()
	untag(copy)
	local parts: { BasePart } = {}
	for _, descendant in copy:GetDescendants() do
		if descendant:IsA("ProximityPrompt") or descendant:IsA("LuaSourceContainer") or descendant:IsA("Sound") then
			descendant:Destroy()
			continue
		end
		untag(descendant)
		if descendant:IsA("BasePart") then
			descendant.Anchored = true
			descendant.CanCollide = false
			descendant.CanQuery = false
			descendant.CanTouch = false
			if descendant:IsA("Seat") or descendant:IsA("VehicleSeat") then
				(descendant :: any).Disabled = true
			end
			table.insert(parts, descendant)
		end
	end
	copy.Name = "ArcFlyover"
	return copy, parts
end

local function fly()
	local car = DriveController.getCar()
	local source = displayCar(FLYOVER.vehicleId)
	if car == nil or source == nil or source.PrimaryPart == nil then
		return
	end
	local frame = car:GetPivot()
	local look = Vector3.new(frame.LookVector.X, 0, frame.LookVector.Z)
	if look.Magnitude < MIN_DIRECTION then
		return
	end
	local forward = look.Unit
	local right = forward:Cross(Vector3.yAxis)
	local base = frame.Position - right * FLYOVER.side
	local from = base - forward * FLYOVER.behind
	local to = base + forward * FLYOVER.ahead

	local ghost, parts = ghostOf(source)
	ghost:PivotTo(ArcFlyoverController.hopFrame(from, to, FLYOVER.peakHeight, 0))
	ghost.Parent = Workspace
	local startedAt = os.clock()
	local connection: RBXScriptConnection? = nil
	connection = RunService.RenderStepped:Connect(function()
		local elapsed = os.clock() - startedAt
		if elapsed < FLYOVER.seconds then
			ghost:PivotTo(ArcFlyoverController.hopFrame(from, to, FLYOVER.peakHeight, elapsed / FLYOVER.seconds))
			return
		end
		-- Down: it rolls on along the road and fades out.
		local rolled = elapsed - FLYOVER.seconds
		if rolled >= FLYOVER.rollSeconds then
			if connection ~= nil then
				connection:Disconnect()
			end
			ghost:Destroy()
			return
		end
		ghost:PivotTo(CFrame.lookAt(to, to + forward) + forward * (FLYOVER.rollSpeed * rolled))
		local fade = rolled / FLYOVER.rollSeconds
		for _, part in parts do
			part.LocalTransparencyModifier = fade
		end
	end)
end

-- The attribute arrived: fly once a session, unless it is old news (the client joined late).
local function onAttribute()
	local stamp = Players.LocalPlayer:GetAttribute(FLYOVER.attribute)
	if played or type(stamp) ~= "number" or Workspace:GetServerTimeNow() - stamp > FLYOVER.maxAgeSeconds then
		return
	end
	played = true
	task.delay(FLYOVER.delaySeconds, fly)
end

-- Boot -----------------------------------------------------------------------------------------------------------

function ArcFlyoverController:Start()
	Players.LocalPlayer:GetAttributeChangedSignal(FLYOVER.attribute):Connect(onAttribute)
	onAttribute()
end

return ArcFlyoverController
