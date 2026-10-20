--!strict
-- The phone's GPS app (replaces Phase 2's standalone destination list). At the top, the active route: where
-- you're heading, the distance left, and End route. Under it every GPS destination from Config/MapLayout,
-- grouped by zone in MapLayout.zoneOrder (GpsController.destinations), the current one highlighted. Picking a
-- place starts the route through GpsController.setDestination and closes the phone so the road is in view.
-- Presentation only: PhoneController passes the lists, the route and the callbacks.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local React = require(ReplicatedStorage.Packages.React)
local Gps = require(ReplicatedStorage.Shared.Config.Gps)

local Kit = require(script.Parent.Kit)
local PhoneConfig = require(script.Parent.PhoneConfig)
local Theme = require(script.Parent.Parent.Theme)

local e = React.createElement
local colors = Theme.colors

export type Item = { id: string, name: string }
export type Section = { title: string, items: { Item } }

-- The active route as the GPS app shows it (GpsController.getStatus).
export type Status = { id: string?, name: string, distanceText: string? }

export type Props = {
	sections: { Section },
	status: Status?,
	onPick: (id: string) -> (),
	onClear: () -> (),
}

local function RouteCard(props: { status: Status, onClear: () -> (), order: number })
	local status = props.status
	return Kit.Card({ order = props.order }, {
		Heading = Kit.Text({
			text = PhoneConfig.gps.headingTo,
			order = 1,
			size = Theme.text.small,
			font = Theme.fonts.medium,
			color = colors.textDim,
		}),
		Place = Kit.Text({ text = status.name, order = 2, size = Theme.text.heading, font = Theme.fonts.bold }),
		Distance = if status.distanceText
			then Kit.Text({
				text = string.format(Gps.panel.labels.distanceLeft, status.distanceText),
				order = 3,
				font = Theme.fonts.bold,
				color = colors.accent,
			})
			else nil,
		End = e(Kit.Button, { label = PhoneConfig.gps.endRoute, onTap = props.onClear, order = 4 }),
	})
end

-- One zone's places, as rows on a card with thin dividers between them.
local function SectionRows(props: { section: Section, activeId: string?, onPick: (id: string) -> (), order: number })
	local list = PhoneConfig.list
	local rows: { [string]: any } = {
		Layout = e("UIListLayout", {
			FillDirection = Enum.FillDirection.Vertical,
			HorizontalAlignment = Enum.HorizontalAlignment.Center, -- dividers sit inset from both edges
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
		Corner = e("UICorner", { CornerRadius = UDim.new(0, Theme.radius.card) }),
	}
	for index, item in props.section.items do
		local active = item.id == props.activeId
		if index > 1 then
			rows[`Divider{index}`] = e("Frame", {
				LayoutOrder = 2 * index - 1,
				Size = UDim2.new(1, -2 * list.rowPadding, 0, 1),
				BackgroundColor3 = colors.divider,
				BorderSizePixel = 0,
			})
		end
		rows[`Place_{item.id}`] = e("TextButton", {
			LayoutOrder = 2 * index,
			Size = UDim2.new(1, 0, 0, list.rowHeight),
			BackgroundColor3 = if active then colors.accent else colors.panelRaised,
			BackgroundTransparency = if active then 0 else 1,
			BorderSizePixel = 0,
			AutoButtonColor = true,
			FontFace = if active then Theme.fonts.bold else Theme.fonts.medium,
			Text = item.name,
			TextColor3 = if active then colors.onAccent else colors.text,
			TextSize = Theme.text.body,
			TextTruncate = Enum.TextTruncate.AtEnd,
			TextXAlignment = Enum.TextXAlignment.Left,
			[React.Event.Activated] = function()
				props.onPick(item.id)
			end,
		}, {
			Padding = e("UIPadding", {
				PaddingLeft = UDim.new(0, list.rowPadding),
				PaddingRight = UDim.new(0, list.rowPadding),
			}),
			Corner = e("UICorner", { CornerRadius = UDim.new(0, Theme.radius.card) }),
		})
	end
	return e("Frame", {
		LayoutOrder = props.order,
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = colors.panelRaised,
		BorderSizePixel = 0,
	}, rows)
end

local function GpsApp(props: Props)
	local status = props.status
	local children: { [string]: any } = {}
	local order = 1
	if status then
		children.Route = e(RouteCard, { status = status, onClear = props.onClear, order = order })
	else
		children.Hint = Kit.Text({ text = PhoneConfig.gps.pick, order = order, color = colors.textDim })
	end
	for index, section in props.sections do
		order += 1
		children[`Title{index}`] = Kit.SectionTitle({ text = section.title, order = order })
		order += 1
		children[`Section{index}`] = e(SectionRows, {
			section = section,
			activeId = if status then status.id else nil,
			onPick = props.onPick,
			order = order,
		})
	end
	if #props.sections == 0 then
		children.Empty = Kit.Text({ text = PhoneConfig.gps.empty, order = order + 1, color = colors.textDim })
	end
	return Kit.Page({ gap = Theme.spacing.sm }, children)
end

return GpsApp
