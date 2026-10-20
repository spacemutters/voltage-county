--!strict
-- The phone's GPS app (replaces Phase 2's standalone destination list). At the top, the active route: where
-- you're heading, the distance left, and End route. Under it every GPS destination from Config/MapLayout,
-- grouped by zone in MapLayout.zoneOrder (GpsController.destinations), the current one highlighted. Picking a
-- place starts the route through GpsController.setDestination and closes the phone so the road is in view.
--
-- Phase 9 (docs/phase-9-contracts.md "Hail a pod"): on foot, each place it can reach also has a Hail button with
-- the estimated fare ("Hail $125", Controllers/HailController.quotes; the server's charge is the truth). One tap
-- books the ride (HailController.hail, which shows the server's answer as a notice); while that request is with
-- the server the tapped button says "Calling..." and every Hail button waits. After a booked ride `onHailed`
-- runs (PhoneController can close the phone with it). In a car the buttons give way to a line saying to get out
-- first. Places too close to ride to, or with no road there, have no button.
--
-- The lists, the route and the GPS callbacks come from PhoneController; the hail state comes from HailController.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local React = require(ReplicatedStorage.Packages.React)
local Economy = require(ReplicatedStorage.Shared.Config.Economy)
local Gps = require(ReplicatedStorage.Shared.Config.Gps)

local Kit = require(script.Parent.Kit)
local PhoneConfig = require(script.Parent.PhoneConfig)
local Theme = require(script.Parent.Parent.Theme)

local Controllers = script.Parent.Parent.Parent.Controllers
local HailController = require(Controllers.HailController)

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
	onHailed: (() -> ())?, -- after a ride is booked (optional)
}

-- The Hail button on a place's row (px at UI scale 1). Its height is Theme.size.touchTarget.
local HAIL = {
	width = 112, -- room for "Hail $1,234" at Theme.text.small inside Kit.Button's padding
	gap = Theme.spacing.sm, -- between the place and the button
	inset = Theme.spacing.xs, -- from the row's right edge
}

-- What players read. %s is the estimated fare ("$125").
local TEXT = {
	hail = "Hail %s",
	hailing = "Calling...",
	hailHint = "Or tap Hail to ride there in a pod.",
	onFootOnly = "Get out of the car to hail a pod to any of these places.",
}

-- What every row needs to know about hailing.
type HailRow = {
	fares: { [string]: number }?, -- nil: not on foot, so no Hail buttons
	hailingId: string?, -- the place a request is with the server for
	waiting: boolean, -- a request is with the server or a ride is playing: every Hail button waits
	onHail: (id: string) -> (),
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

-- One place: the name (tap for directions) and, when it can be ridden to, its Hail button.
local function PlaceRow(props: {
	item: Item,
	active: boolean,
	hail: HailRow,
	onPick: (id: string) -> (),
	order: number,
})
	local list = PhoneConfig.list
	local item, active, hail = props.item, props.active, props.hail
	local fare = if hail.fares ~= nil then hail.fares[item.id] else nil
	local placeWidth = if fare ~= nil
		then UDim2.new(1, -(HAIL.width + HAIL.gap + HAIL.inset), 1, 0)
		else UDim2.fromScale(1, 1)
	return e("Frame", {
		LayoutOrder = props.order,
		Size = UDim2.new(1, 0, 0, list.rowHeight),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
	}, {
		Place = e("TextButton", {
			Size = placeWidth,
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
		}),
		Hail = if fare ~= nil
			then e(Kit.Button, {
				label = if hail.hailingId == item.id
					then TEXT.hailing
					else string.format(TEXT.hail, Economy.formatCash(fare)),
				onTap = function()
					hail.onHail(item.id)
				end,
				disabled = hail.waiting,
				anchor = Vector2.new(1, 0.5),
				position = UDim2.new(1, -HAIL.inset, 0.5, 0),
				size = UDim2.fromOffset(HAIL.width, Theme.size.touchTarget),
				textSize = Theme.text.small,
			})
			else nil,
	})
end

-- One zone's places, as rows on a card with thin dividers between them.
local function SectionRows(props: {
	section: Section,
	activeId: string?,
	hail: HailRow,
	onPick: (id: string) -> (),
	order: number,
})
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
		if index > 1 then
			rows[`Divider{index}`] = e("Frame", {
				LayoutOrder = 2 * index - 1,
				Size = UDim2.new(1, -2 * list.rowPadding, 0, 1),
				BackgroundColor3 = colors.divider,
				BorderSizePixel = 0,
			})
		end
		rows[`Place_{item.id}`] = e(PlaceRow, {
			item = item,
			active = item.id == props.activeId,
			hail = props.hail,
			onPick = props.onPick,
			order = 2 * index,
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

-- HailController's state, redrawn whenever it changes.
local function useHailState(): HailController.State
	local state, setState = React.useState(HailController.getState)
	React.useEffect(function()
		local live = true
		local connection = HailController.onChanged:Connect(function()
			if live then
				setState(HailController.getState())
			end
		end)
		setState(HailController.getState())
		return function()
			live = false
			connection:Disconnect()
		end
	end, {})
	return state
end

local function GpsApp(props: Props)
	local status = props.status
	local hailState = useHailState()
	local live = React.useRef(true)
	React.useEffect(function()
		live.current = true
		return function()
			live.current = false
		end
	end, {})

	local onHailed = props.onHailed
	local hail: HailRow = {
		fares = HailController.quotes(),
		hailingId = hailState.hailingId,
		waiting = hailState.hailingId ~= nil or hailState.riding,
		onHail = function(id: string)
			task.spawn(function()
				local booked = HailController.hail(id)
				if booked and live.current and onHailed ~= nil then
					onHailed()
				end
			end)
		end,
	}

	local children: { [string]: any } = {}
	local order = 1
	if status then
		children.Route = e(RouteCard, { status = status, onClear = props.onClear, order = order })
	else
		children.Hint = Kit.Text({ text = PhoneConfig.gps.pick, order = order, color = colors.textDim })
	end
	if #props.sections > 0 then
		order += 1
		children.HailHint = Kit.Text({
			text = if hail.fares ~= nil then TEXT.hailHint else TEXT.onFootOnly,
			order = order,
			color = colors.textDim,
		})
	end
	for index, section in props.sections do
		order += 1
		children[`Title{index}`] = Kit.SectionTitle({ text = section.title, order = order })
		order += 1
		children[`Section{index}`] = e(SectionRows, {
			section = section,
			activeId = if status then status.id else nil,
			hail = hail,
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
