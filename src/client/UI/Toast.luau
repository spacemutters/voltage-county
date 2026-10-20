--!strict
-- One short notice at the top centre of the screen (docs/phase-2-contracts.md "notices"). NotifyController
-- decides what shows and for how long; this component only draws it: a dark rounded panel with a small dot in
-- the notice's kind color and the text in the HUD's white, consistent with UI/Hud.
--
-- It fades and slides in when it mounts and fades and rises out when `leaving` turns true. The fade is one
-- binding driven by a short TweenService tween (no per-frame code of ours). The toast never takes input, so
-- it never blocks a tap on the controls below it.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local React = require(ReplicatedStorage.Packages.React)
local Controls = require(ReplicatedStorage.Shared.Config.Controls)
local Gps = require(ReplicatedStorage.Shared.Config.Gps)

local e = React.createElement

export type Props = {
	text: string,
	kind: string?, -- a key of Config/Gps toast.kindColors; anything else shows as the default kind
	leaving: boolean, -- true starts the fade out
}

local HIDDEN = 1 -- fade value of a fully hidden toast
local SHOWN = 0

local function lerp(from: number, to: number, alpha: number): number
	return from + (to - from) * alpha
end

local function Toast(props: Props)
	local theme = Controls.theme
	local toast = Gps.toast

	-- 0 = fully shown, 1 = fully hidden. Starts hidden so the first effect fades it in.
	local fade, setFade = React.useBinding(HIDDEN)

	React.useEffect(function()
		local target = if props.leaving then HIDDEN else SHOWN
		local seconds = if props.leaving then toast.fadeOutSeconds else toast.fadeInSeconds
		-- Tween a NumberValue and mirror it into the binding; the tween starts from wherever the fade is now.
		local value = Instance.new("NumberValue")
		value.Value = fade:getValue()
		local connection = value.Changed:Connect(function(current: number)
			setFade(current)
		end)
		local tween = TweenService:Create(
			value,
			TweenInfo.new(seconds, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ Value = target }
		)
		tween:Play()
		return function()
			tween:Cancel()
			connection:Disconnect()
			value:Destroy()
		end
	end, { props.leaving })

	local kindColor = toast.kindColors[props.kind or toast.defaultKind] or toast.kindColors[toast.defaultKind]
	local panelTransparency = fade:map(function(value: number): number
		return lerp(theme.panelTransparency, 1, value)
	end)

	return e("Frame", {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = fade:map(function(value: number): UDim2
			return UDim2.new(0.5, 0, 0, toast.margin - value * toast.slideOffset)
		end),
		Size = UDim2.new(),
		AutomaticSize = Enum.AutomaticSize.XY,
		BackgroundColor3 = theme.panel,
		BackgroundTransparency = panelTransparency,
		BorderSizePixel = 0,
		Active = false,
	}, {
		Corner = e("UICorner", { CornerRadius = UDim.new(0, toast.cornerRadius) }),
		Padding = e("UIPadding", {
			PaddingLeft = UDim.new(0, toast.padding.X),
			PaddingRight = UDim.new(0, toast.padding.X),
			PaddingTop = UDim.new(0, toast.padding.Y),
			PaddingBottom = UDim.new(0, toast.padding.Y),
		}),
		Layout = e("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			VerticalAlignment = Enum.VerticalAlignment.Center,
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, toast.gap),
		}),
		Dot = e("Frame", {
			LayoutOrder = 1,
			Size = UDim2.fromOffset(toast.dotSize, toast.dotSize),
			BackgroundColor3 = kindColor,
			BackgroundTransparency = fade,
			BorderSizePixel = 0,
		}, {
			Corner = e("UICorner", { CornerRadius = UDim.new(0.5, 0) }),
		}),
		Text = e("TextLabel", {
			LayoutOrder = 2,
			Size = UDim2.new(),
			AutomaticSize = Enum.AutomaticSize.XY,
			BackgroundTransparency = 1,
			FontFace = theme.fonts.medium,
			Text = props.text,
			TextColor3 = theme.text,
			TextTransparency = fade,
			TextSize = toast.textSize,
			TextWrapped = true,
			TextXAlignment = Enum.TextXAlignment.Left,
		}, {
			-- Grows to fit one line up to this width, then wraps onto more lines.
			MaxWidth = e("UISizeConstraint", { MaxSize = Vector2.new(toast.maxTextWidth, math.huge) }),
		}),
	})
end

return Toast
