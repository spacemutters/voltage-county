--!strict
-- The GPS on screen (docs/phase-2-contracts.md "GpsController"), in the driving HUD's look (UI/Hud):
--
--   GPS button      top right, just below the touch Mode / Camera / Exit row, so it never covers the touch
--                   pedals, the touch buttons or the speed panel. Opens and closes the destination list.
--   route chip      left of the button while a route is active: where you're going, the distance left in
--                   miles, and an End button that clears the route.
--   destination list  a sheet in the middle of the screen: every GPS destination grouped by zone, the active
--                   one highlighted. Picking one starts the route and closes the list.
--
-- Presentation only: GpsController passes the destinations, the active route and the callbacks as props.
-- Whether the list is open is this component's own state. Sizes come from Config/Gps `panel` at UI scale 1;
-- every touch target is at least 44 px (Gps.spec checks the sizes).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local React = require(ReplicatedStorage.Packages.React)
local Controls = require(ReplicatedStorage.Shared.Config.Controls)
local Gps = require(ReplicatedStorage.Shared.Config.Gps)

local e = React.createElement

export type Item = { id: string, name: string }
export type Section = { title: string, items: { Item } }

export type Props = {
	sections: { Section }, -- GPS destinations grouped by zone, in display order
	activeId: string?, -- the destination being routed to, when it is a listed place
	activeName: string?, -- nil when there is no route
	distanceText: string?, -- e.g. "1.2 mi"
	onPick: (id: string) -> (),
	onClear: () -> (),
}

-- A rounded text button in the panel style. `highlighted` fills it with the accent.
local function PanelButton(
	props: {
		anchor: Vector2,
		position: UDim2,
		size: Vector2,
		label: string,
		highlighted: boolean?,
		raised: boolean?, -- a lighter fill, for buttons that sit on a panel
		cornerRadius: number?, -- default: the list rows' corner radius
		onTap: () -> (),
	}
)
	local theme = Controls.theme
	local panel = Gps.panel
	local fill = if props.highlighted then theme.accent elseif props.raised then theme.panelRaised else theme.panel
	return e("TextButton", {
		AnchorPoint = props.anchor,
		Position = props.position,
		Size = UDim2.fromOffset(props.size.X, props.size.Y),
		BackgroundColor3 = fill,
		BackgroundTransparency = if props.highlighted or props.raised then 0 else theme.panelTransparency,
		BorderSizePixel = 0,
		AutoButtonColor = true,
		FontFace = theme.fonts.bold,
		Text = props.label,
		TextColor3 = if props.highlighted then theme.onAccent else theme.text,
		TextSize = panel.buttonTextSize,
		[React.Event.Activated] = function()
			props.onTap()
		end,
	}, {
		Corner = e("UICorner", { CornerRadius = UDim.new(0, props.cornerRadius or panel.rowCornerRadius) }),
	})
end

-- Where you're going and how far is left, with the End button.
local function RouteChip(props: { name: string, distanceText: string?, onClear: () -> () })
	local theme = Controls.theme
	local panel = Gps.panel
	local pad = panel.chipPadding
	local textWidth = panel.chipWidth - panel.endButtonSize.X - 2 * pad - panel.gap
	local distance = props.distanceText
	return e("Frame", {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -(panel.margin + panel.buttonSize.X + panel.gap), 0, panel.top),
		Size = UDim2.fromOffset(panel.chipWidth, panel.buttonSize.Y),
		BackgroundColor3 = theme.panel,
		BackgroundTransparency = theme.panelTransparency,
		BorderSizePixel = 0,
	}, {
		Corner = e("UICorner", { CornerRadius = UDim.new(0, panel.cornerRadius) }),
		Labels = e("Frame", {
			AnchorPoint = Vector2.new(0, 0.5),
			Position = UDim2.new(0, pad, 0.5, 0),
			Size = UDim2.new(0, textWidth, 1, 0),
			BackgroundTransparency = 1,
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
		End = e(PanelButton, {
			anchor = Vector2.new(1, 0.5),
			position = UDim2.new(1, -(panel.buttonSize.Y - panel.endButtonSize.Y) / 2, 0.5, 0),
			size = panel.endButtonSize,
			label = panel.labels.endRoute,
			raised = true,
			onTap = props.onClear,
		}),
	})
end

-- The destination list: a header with a Close button, then a scrolling list of zones and places.
local function DestinationSheet(props: {
	sections: { Section },
	activeId: string?,
	onPick: (id: string) -> (),
	onClose: () -> (),
})
	local theme = Controls.theme
	local panel = Gps.panel

	local rows: { [string]: any } = {
		Layout = e("UIListLayout", {
			FillDirection = Enum.FillDirection.Vertical,
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
	}
	local order = 0
	local contentHeight = 0
	for _, section in props.sections do
		order += 1
		contentHeight += panel.sectionHeight
		rows[`Section{order}`] = e("TextLabel", {
			LayoutOrder = order,
			Size = UDim2.new(1, 0, 0, panel.sectionHeight),
			BackgroundTransparency = 1,
			FontFace = theme.fonts.medium,
			Text = section.title,
			TextColor3 = theme.textDim,
			TextSize = panel.sectionTextSize,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextYAlignment = Enum.TextYAlignment.Bottom,
		}, {
			Padding = e("UIPadding", {
				PaddingLeft = UDim.new(0, panel.rowPadding),
				PaddingBottom = UDim.new(0, panel.listInset),
			}),
		})
		for _, item in section.items do
			order += 1
			contentHeight += panel.rowHeight
			local active = item.id == props.activeId
			rows[`Place_{item.id}`] = e("TextButton", {
				LayoutOrder = order,
				Size = UDim2.new(1, 0, 0, panel.rowHeight),
				BackgroundColor3 = if active then theme.accent else theme.panelRaised,
				BackgroundTransparency = if active then 0 else 1,
				BorderSizePixel = 0,
				AutoButtonColor = true,
				FontFace = theme.fonts.medium,
				Text = item.name,
				TextColor3 = if active then theme.onAccent else theme.text,
				TextSize = panel.textSize,
				TextTruncate = Enum.TextTruncate.AtEnd,
				TextXAlignment = Enum.TextXAlignment.Left,
				[React.Event.Activated] = function()
					props.onPick(item.id)
				end,
			}, {
				Padding = e("UIPadding", {
					PaddingLeft = UDim.new(0, panel.rowPadding),
					PaddingRight = UDim.new(0, panel.rowPadding),
				}),
				Corner = e("UICorner", { CornerRadius = UDim.new(0, panel.rowCornerRadius) }),
			})
		end
	end
	if order == 0 then
		contentHeight = panel.rowHeight
		rows.Empty = e("TextLabel", {
			Size = UDim2.new(1, 0, 0, panel.rowHeight),
			BackgroundTransparency = 1,
			FontFace = theme.fonts.regular,
			Text = panel.labels.empty,
			TextColor3 = theme.textDim,
			TextSize = panel.textSize,
		})
	end
	-- The list is as tall as its content, up to maxListHeight; beyond that it scrolls.
	local listHeight = math.min(contentHeight + panel.listInset, panel.maxListHeight)

	return e("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(panel.sheetWidth, panel.headerHeight + listHeight),
		BackgroundColor3 = theme.panel,
		BackgroundTransparency = theme.panelTransparency,
		BorderSizePixel = 0,
		Active = true, -- taps on the sheet don't fall through to the world
	}, {
		Corner = e("UICorner", { CornerRadius = UDim.new(0, panel.cornerRadius) }),
		Title = e("TextLabel", {
			Position = UDim2.fromOffset(panel.rowPadding, 0),
			Size = UDim2.new(1, -(2 * panel.rowPadding + panel.closeButtonSize.X), 0, panel.headerHeight),
			BackgroundTransparency = 1,
			FontFace = theme.fonts.bold,
			Text = panel.labels.title,
			TextColor3 = theme.text,
			TextSize = panel.titleTextSize,
			TextXAlignment = Enum.TextXAlignment.Left,
		}),
		Close = e(PanelButton, {
			anchor = Vector2.new(1, 0.5),
			position = UDim2.new(1, -panel.listInset, 0, panel.headerHeight / 2),
			size = panel.closeButtonSize,
			label = panel.labels.close,
			raised = true,
			onTap = props.onClose,
		}),
		List = e("ScrollingFrame", {
			Position = UDim2.fromOffset(0, panel.headerHeight),
			Size = UDim2.new(1, 0, 0, listHeight),
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			CanvasSize = UDim2.new(),
			AutomaticCanvasSize = Enum.AutomaticSize.Y,
			ScrollingDirection = Enum.ScrollingDirection.Y,
			ScrollBarThickness = panel.scrollBarThickness,
			ScrollBarImageColor3 = theme.textDim,
		}, {
			Padding = e("UIPadding", {
				PaddingLeft = UDim.new(0, panel.listInset),
				PaddingRight = UDim.new(0, panel.listInset),
				PaddingBottom = UDim.new(0, panel.listInset),
			}),
			Rows = e("Frame", {
				Size = UDim2.fromScale(1, 0),
				AutomaticSize = Enum.AutomaticSize.Y,
				BackgroundTransparency = 1,
			}, rows),
		}),
	})
end

local function GpsPanel(props: Props)
	local open, setOpen = React.useState(false)
	local panel = Gps.panel
	local activeName = props.activeName

	return e("Frame", {
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
	}, {
		Button = e(PanelButton, {
			anchor = Vector2.new(1, 0),
			position = UDim2.new(1, -panel.margin, 0, panel.top),
			size = panel.buttonSize,
			label = panel.labels.button,
			highlighted = open,
			cornerRadius = panel.cornerRadius,
			onTap = function()
				setOpen(not open)
			end,
		}),
		Route = if activeName
			then e(RouteChip, {
				name = activeName,
				distanceText = props.distanceText,
				onClear = props.onClear,
			})
			else nil,
		Sheet = if open
			then e(DestinationSheet, {
				sections = props.sections,
				activeId = props.activeId,
				onPick = function(id: string)
					setOpen(false)
					props.onPick(id)
				end,
				onClose = function()
					setOpen(false)
				end,
			})
			else nil,
	})
end

return GpsPanel
