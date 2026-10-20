--!strict
-- A car preview for the designer's screens (docs/phase-11-contracts.md "Client"): a rounded ViewportFrame showing a
-- copy of a Model (a design built locally with Vehicle/SpecBuilder, a mod applied with Vehicle/ModBuilder, or what
-- the server sent), with the camera circling it slowly. An optional label ("Before", "After") sits in its corner.
--
-- The copy is made when the model changes and destroyed with the component, so the caller keeps (and destroys) its
-- own model. Scripts, sounds and prompts are stripped from the copy (a car cloned from the world could carry
-- them, and a script under PlayerGui would run). The camera's distance fits the car to the box's shape and is
-- worked out again when the box is resized. The turn is a looping TweenService tween on a NumberValue: no per-frame
-- code of ours. Presentation only.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local React = require(ReplicatedStorage.Packages.React)

local Theme = require(script.Parent.Parent.Theme)
local DesignerStyle = require(script.Parent.DesignerStyle)

local e = React.createElement
local colors = Theme.colors
local layout = DesignerStyle.layout

local FULL_TURN = 2 * math.pi
local LIGHT_DIRECTION = Vector3.new(-1, -1.5, -0.6) -- from above and to one side, like the sun at mid-morning
local AMBIENT = Color3.fromRGB(150, 155, 165)

-- Things a preview copy never keeps.
local STRIP = { "BaseScript", "ModuleScript", "Sound", "ProximityPrompt", "ClickDetector" }

export type Props = {
	model: Model?,
	label: string?,
	size: UDim2?, -- default: full width, layout.previewHeight tall
	order: number?,
	position: UDim2?,
}

local Preview = {}

-- How far the camera stands from the box's centre to fit a car of `size` (studs) in a box of `aspect` (width /
-- height), looking down by `elevation` radians, with a vertical field of view `fov` degrees. Pure, for specs.
function Preview.distanceFor(size: Vector3, aspect: number, fov: number, elevation: number): number
	local half = math.rad(fov) / 2
	local across = math.sqrt(size.X * size.X + size.Z * size.Z) / 2 -- the farthest the car reaches as it turns
	local horizontalHalf = math.atan(math.tan(half) * math.max(aspect, 0.1))
	local tall = size.Y / 2 + math.sin(elevation) * across
	local fitWidth = across / math.sin(horizontalHalf)
	local fitHeight = tall / math.sin(half)
	return math.max(fitWidth, fitHeight) * layout.previewFill
end

local function strip(model: Model)
	for _, descendant in model:GetDescendants() do
		for _, className in STRIP do
			if descendant:IsA(className) then
				descendant:Destroy()
				break
			end
		end
	end
end

function Preview.Preview(props: Props)
	local frameRef = React.useRef(nil :: ViewportFrame?)
	local model = props.model

	React.useEffect(function(): (() -> ())?
		local frame = frameRef.current
		if frame == nil or model == nil then
			return nil
		end
		local cloned, copy = pcall(function(): Model?
			return model:Clone()
		end)
		if not cloned or copy == nil then
			return nil
		end
		strip(copy)
		local boxCFrame, boxSize = copy:GetBoundingBox()
		local center = boxCFrame.Position
		copy.Parent = frame

		local camera = Instance.new("Camera")
		camera.FieldOfView = layout.previewFov
		camera.Parent = frame
		frame.CurrentCamera = camera

		local elevation = layout.previewElevation
		local distance = 0
		local angle = Instance.new("NumberValue")
		local function place()
			local turn = angle.Value
			local flat = math.cos(elevation) * distance
			local offset = Vector3.new(math.cos(turn) * flat, math.sin(elevation) * distance, math.sin(turn) * flat)
			camera.CFrame = CFrame.lookAt(center + offset, center)
		end
		local function measure()
			local area = frame.AbsoluteSize
			local aspect = if area.Y > 0 then area.X / area.Y else 1
			distance = Preview.distanceFor(boxSize, aspect, layout.previewFov, elevation)
			place()
		end
		measure()
		local resized = frame:GetPropertyChangedSignal("AbsoluteSize"):Connect(measure)
		local turned = angle.Changed:Connect(place)
		local tween = TweenService:Create(
			angle,
			TweenInfo.new(layout.previewTurnSeconds, Enum.EasingStyle.Linear, Enum.EasingDirection.In, -1),
			{ Value = FULL_TURN }
		)
		tween:Play()
		return function()
			tween:Cancel()
			turned:Disconnect()
			resized:Disconnect()
			angle:Destroy()
			camera:Destroy() -- the frame lets go of it as its CurrentCamera
			copy:Destroy()
		end
	end, { model } :: { any })

	local label = props.label
	return e("ViewportFrame", {
		LayoutOrder = props.order or 0,
		Position = props.position,
		Size = props.size or UDim2.new(1, 0, 0, layout.previewHeight),
		BackgroundColor3 = colors.panelRaised,
		BorderSizePixel = 0,
		Ambient = AMBIENT,
		LightColor = Color3.new(1, 1, 1),
		LightDirection = LIGHT_DIRECTION,
		ref = frameRef,
	}, {
		Corner = e("UICorner", { CornerRadius = UDim.new(0, Theme.radius.card) }),
		Label = if label
			then e("TextLabel", {
				Position = UDim2.fromOffset(Theme.spacing.md, Theme.spacing.sm),
				Size = UDim2.new(1, -2 * Theme.spacing.md, 0, layout.previewLabelHeight),
				BackgroundTransparency = 1,
				FontFace = Theme.fonts.bold,
				Text = label,
				TextColor3 = colors.textDim,
				TextSize = Theme.text.small,
				TextXAlignment = Enum.TextXAlignment.Left,
				ZIndex = 2,
			})
			else nil,
		Missing = if model == nil
			then e("TextLabel", {
				Size = UDim2.fromScale(1, 1),
				BackgroundTransparency = 1,
				FontFace = Theme.fonts.medium,
				Text = DesignerStyle.copy.previewMissing,
				TextColor3 = colors.textDim,
				TextSize = Theme.text.small,
				TextWrapped = true,
			})
			else nil,
	})
end

return Preview
