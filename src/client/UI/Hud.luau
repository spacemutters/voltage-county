--!strict
-- The driving HUD (PLAN.md Phase 1 "HUD stub"): speed in mph, gear and drive mode in one panel at the bottom
-- center, with a row of key hints under it on keyboard and gamepad. Presentation only: HudController passes
-- every value in as props and redraws about 10 times a second while driving. Sizes come from Config/Controls
-- at UI scale 1; HudController scales the whole tree for bigger screens.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local React = require(ReplicatedStorage.Packages.React)
local Controls = require(ReplicatedStorage.Shared.Config.Controls)
local Types = require(ReplicatedStorage.Shared.Types)

local e = React.createElement

export type HintItem = { keys: string, label: string }

export type Props = {
	mph: number, -- already rounded
	gear: string,
	mode: Types.DriveMode,
	regen: Types.RegenLevel,
	hints: { HintItem }?, -- nil or empty hides the hint row (touch devices)
}

-- "W/S Drive    A/D Steer ..." with the keys in bold white and the labels in the dim text color.
local function hintText(hints: { HintItem }): string
	local keyColor = Controls.theme.text:ToHex()
	local parts: { string } = {}
	for _, hint in hints do
		table.insert(parts, `<font color="#{keyColor}"><b>{hint.keys}</b></font> {hint.label}`)
	end
	return table.concat(parts, Controls.hud.hintSpacing)
end

-- A text label that sizes its height to its text, for stacking in a UIListLayout.
local function line(props: {
	order: number,
	text: string,
	font: Font,
	size: number,
	color: Color3,
	align: Enum.TextXAlignment?,
})
	return e("TextLabel", {
		LayoutOrder = props.order,
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		FontFace = props.font,
		Text = props.text,
		TextColor3 = props.color,
		TextSize = props.size,
		TextXAlignment = props.align or Enum.TextXAlignment.Center,
	})
end

local function column(props: {
	anchor: Vector2,
	position: UDim2,
	width: number,
	align: Enum.HorizontalAlignment,
	items: { [string]: any },
})
	local children = table.clone(props.items)
	children.Layout = e("UIListLayout", {
		FillDirection = Enum.FillDirection.Vertical,
		HorizontalAlignment = props.align,
		VerticalAlignment = Enum.VerticalAlignment.Center,
		SortOrder = Enum.SortOrder.LayoutOrder,
	})
	return e("Frame", {
		AnchorPoint = props.anchor,
		Position = props.position,
		Size = UDim2.new(0, props.width, 1, 0),
		BackgroundTransparency = 1,
	}, children)
end

local function Hud(props: Props)
	local theme = Controls.theme
	local layout = Controls.hud
	local pad = layout.clusterPadding
	local hints = props.hints
	local showHints = hints ~= nil and #hints > 0

	-- The speed panel sits above the hint row when there is one.
	local clusterBottom = layout.margin
	if showHints then
		clusterBottom += layout.hintHeight + layout.gap
	end

	local cluster = e("Frame", {
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -clusterBottom),
		Size = UDim2.fromOffset(layout.clusterSize.X, layout.clusterSize.Y),
		BackgroundColor3 = theme.panel,
		BackgroundTransparency = theme.panelTransparency,
		BorderSizePixel = 0,
	}, {
		Corner = e("UICorner", { CornerRadius = UDim.new(0, layout.cornerRadius) }),
		Gear = e("TextLabel", {
			AnchorPoint = Vector2.new(0, 0.5),
			Position = UDim2.new(0, pad, 0.5, 0),
			Size = UDim2.fromOffset(layout.gearSize, layout.gearSize),
			BackgroundColor3 = theme.panelRaised,
			BorderSizePixel = 0,
			FontFace = theme.fonts.bold,
			Text = props.gear,
			TextColor3 = theme.text,
			TextSize = layout.gearTextSize,
		}, {
			Corner = e("UICorner", { CornerRadius = UDim.new(0, layout.gearCornerRadius) }),
		}),
		Speed = e(column, {
			anchor = Vector2.new(0.5, 0),
			position = UDim2.fromScale(0.5, 0),
			width = layout.speedWidth,
			align = Enum.HorizontalAlignment.Center,
			items = {
				Value = e(line, {
					order = 1,
					text = tostring(props.mph),
					font = theme.fonts.bold,
					size = layout.speedTextSize,
					color = theme.text,
				}),
				Unit = e(line, {
					order = 2,
					text = layout.unitLabel,
					font = theme.fonts.medium,
					size = layout.unitTextSize,
					color = theme.textDim,
				}),
			},
		}),
		Mode = e(column, {
			anchor = Vector2.new(1, 0),
			position = UDim2.new(1, -pad, 0, 0),
			width = layout.sideLabelWidth,
			align = Enum.HorizontalAlignment.Right,
			items = {
				Drive = e(line, {
					order = 1,
					text = layout.modeLabels[props.mode] or props.mode,
					font = theme.fonts.bold,
					size = layout.modeTextSize,
					color = theme.accent,
					align = Enum.TextXAlignment.Right,
				}),
				Regen = e(line, {
					order = 2,
					text = layout.regenLabels[props.regen] or props.regen,
					font = theme.fonts.regular,
					size = layout.smallTextSize,
					color = theme.textDim,
					align = Enum.TextXAlignment.Right,
				}),
			},
		}),
	})

	local hintRow = if showHints and hints
		then e("TextLabel", {
			AnchorPoint = Vector2.new(0.5, 1),
			Position = UDim2.new(0.5, 0, 1, -layout.margin),
			Size = UDim2.fromOffset(0, layout.hintHeight),
			AutomaticSize = Enum.AutomaticSize.X,
			BackgroundColor3 = theme.panel,
			BackgroundTransparency = theme.panelTransparency,
			BorderSizePixel = 0,
			FontFace = theme.fonts.regular,
			RichText = true,
			Text = hintText(hints),
			TextColor3 = theme.textDim,
			TextSize = layout.hintTextSize,
		}, {
			Corner = e("UICorner", { CornerRadius = UDim.new(0.5, 0) }),
			Padding = e("UIPadding", {
				PaddingLeft = UDim.new(0, pad),
				PaddingRight = UDim.new(0, pad),
			}),
		})
		else nil

	return e("Frame", {
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
	}, {
		Cluster = cluster,
		Hints = hintRow,
	})
end

return Hud
