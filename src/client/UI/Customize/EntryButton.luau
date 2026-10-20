--!strict
-- The "Customize" button that shows while the player's own car stands in a Wrap & Tint shop's bay
-- (docs/phase-7-contracts.md "Client"). The shop's "Customize" prompt can't show while the player sits in the
-- car (Controllers/DriveController hides every prompt while seated), so this button opens the shop instead: it
-- sits at the top centre under the notices, clear of the touch controls, with the key that also opens the shop
-- (E, or A on a gamepad) in a small chip on its left when a keyboard or gamepad is in use. It fades in when it
-- mounts. Presentation only: CustomizationController decides when it shows and what a tap does.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local React = require(ReplicatedStorage.Packages.React)
local Theme = require(script.Parent.Parent.Theme)
local Primitives = require(script.Parent.Parent.Shop.Primitives)
local Style = require(script.Parent.Style)

local e = React.createElement

local colors = Theme.colors
local fonts = Theme.fonts
local layout = Style.layout

export type Props = {
	label: string, -- "Customize"
	keyGlyph: string?, -- "E" or "A"; nil on touch
	top: number, -- pixels from the top (unscaled): under the notices band
	onTap: () -> (),
}

local function EntryButton(props: Props)
	local appear = Primitives.useAppear()
	local glyph = props.keyGlyph
	local inset = if glyph ~= nil then layout.entryKeyWidth + Theme.spacing.sm else 0
	return e("TextButton", {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = appear:map(function(value: number): UDim2
			return UDim2.new(0.5, 0, 0, props.top - (1 - value) * Theme.spacing.sm)
		end),
		Size = UDim2.fromOffset(0, layout.entryHeight),
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundColor3 = colors.accent,
		BackgroundTransparency = appear:map(function(value: number): number
			return 1 - value
		end),
		BorderSizePixel = 0,
		AutoButtonColor = true,
		FontFace = fonts.bold,
		Text = props.label,
		TextColor3 = colors.onAccent,
		TextSize = Theme.text.body,
		TextTransparency = appear:map(function(value: number): number
			return 1 - value
		end),
		[React.Event.Activated] = function()
			props.onTap()
		end,
	}, {
		Corner = Primitives.corner(Theme.radius.pill),
		Padding = e("UIPadding", {
			PaddingLeft = UDim.new(0, Theme.spacing.lg + inset),
			PaddingRight = UDim.new(0, Theme.spacing.lg),
		}),
		Limits = e("UISizeConstraint", {
			MinSize = Vector2.new(layout.entryMinWidth, layout.entryHeight),
		}),
		Key = if glyph ~= nil
			then e("TextLabel", {
				AnchorPoint = Vector2.new(1, 0.5),
				Position = UDim2.new(0, -Theme.spacing.sm, 0.5, 0),
				Size = UDim2.fromOffset(layout.entryKeyWidth, layout.entryKeyWidth),
				BackgroundColor3 = colors.onAccent,
				BorderSizePixel = 0,
				FontFace = fonts.bold,
				Text = glyph,
				TextColor3 = colors.accent,
				TextSize = Theme.text.small,
			}, {
				Corner = Primitives.corner(Theme.radius.button),
			})
			else nil,
	})
end

return EntryButton
