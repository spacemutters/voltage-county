--!strict
-- The GPS on screen (docs/phase-2-contracts.md "GpsController"; since Phase 4 the destination list lives in
-- the phone's GPS app, UI/Phone/GpsApp). What's left here is the route chip, shown while a route is active:
--
--   route chip   top right, just below the touch Mode / Camera / Exit row, so it never covers the touch pedals,
--                the touch buttons or the speed panel: where you're going and the distance left, with an End
--                button that clears the route. Tapping the place name opens the phone's GPS app.
--
-- Presentation only: GpsController passes the route and the callbacks as props. Sizes come from Config/Gps
-- `panel` at UI scale 1; every touch target is at least 44 px (Gps.spec checks the sizes).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local React = require(ReplicatedStorage.Packages.React)
local Controls = require(ReplicatedStorage.Shared.Config.Controls)
local Gps = require(ReplicatedStorage.Shared.Config.Gps)

local e = React.createElement

export type Props = {
	activeName: string?, -- nil when there is no route (nothing shows)
	distanceText: string?, -- e.g. "1.2 mi"
	onClear: () -> (),
	onOpen: () -> (), -- the place name was tapped
}

-- Where you're going and how far is left, with the End button.
local function RouteChip(props: { name: string, distanceText: string?, onClear: () -> (), onOpen: () -> () })
	local theme = Controls.theme
	local panel = Gps.panel
	local pad = panel.chipPadding
	local textWidth = panel.chipWidth - panel.endButtonSize.X - 2 * pad - panel.gap
	local distance = props.distanceText
	return e("Frame", {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -panel.margin, 0, panel.top),
		Size = UDim2.fromOffset(panel.chipWidth, panel.buttonSize.Y),
		BackgroundColor3 = theme.panel,
		BackgroundTransparency = theme.panelTransparency,
		BorderSizePixel = 0,
	}, {
		Corner = e("UICorner", { CornerRadius = UDim.new(0, panel.cornerRadius) }),
		-- The whole text area is one button: it opens the phone's GPS app to pick somewhere else.
		Labels = e("TextButton", {
			AnchorPoint = Vector2.new(0, 0.5),
			Position = UDim2.new(0, pad, 0.5, 0),
			Size = UDim2.new(0, textWidth, 1, 0),
			BackgroundTransparency = 1,
			AutoButtonColor = false,
			Text = "",
			[React.Event.Activated] = function()
				props.onOpen()
			end,
		}, {
			Layout = e("UIListLayout", {
				FillDirection = Enum.FillDirection.Vertical,
				VerticalAlignment = Enum.VerticalAlignment.Center,
				SortOrder = Enum.SortOrder.LayoutOrder,
			}),
			Place = e("TextLabel", {
				LayoutOrder = 1,
				Size = UDim2.fromScale(1, 0),
				AutomaticSize = Enum.AutomaticSize.Y,
				BackgroundTransparency = 1,
				FontFace = theme.fonts.bold,
				Text = props.name,
				TextColor3 = theme.text,
				TextSize = panel.chipNameTextSize,
				TextTruncate = Enum.TextTruncate.AtEnd,
				TextXAlignment = Enum.TextXAlignment.Left,
			}),
			Distance = if distance
				then e("TextLabel", {
					LayoutOrder = 2,
					Size = UDim2.fromScale(1, 0),
					AutomaticSize = Enum.AutomaticSize.Y,
					BackgroundTransparency = 1,
					FontFace = theme.fonts.medium,
					Text = string.format(panel.labels.distanceLeft, distance),
					TextColor3 = theme.textDim,
					TextSize = panel.chipDistanceTextSize,
					TextXAlignment = Enum.TextXAlignment.Left,
				})
				else nil,
		}),
		End = e("TextButton", {
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -(panel.buttonSize.Y - panel.endButtonSize.Y) / 2, 0.5, 0),
			Size = UDim2.fromOffset(panel.endButtonSize.X, panel.endButtonSize.Y),
			BackgroundColor3 = theme.panelRaised,
			BorderSizePixel = 0,
			AutoButtonColor = true,
			FontFace = theme.fonts.bold,
			Text = panel.labels.endRoute,
			TextColor3 = theme.text,
			TextSize = panel.buttonTextSize,
			[React.Event.Activated] = function()
				props.onClear()
			end,
		}, {
			Corner = e("UICorner", { CornerRadius = UDim.new(0, panel.rowCornerRadius) }),
		}),
	})
end

local function GpsPanel(props: Props)
	local activeName = props.activeName
	return e("Frame", {
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
	}, {
		Route = if activeName
			then e(RouteChip, {
				name = activeName,
				distanceText = props.distanceText,
				onClear = props.onClear,
				onOpen = props.onOpen,
			})
			else nil,
	})
end

return GpsPanel
