--!strict
-- The phone's Fleet app (PLAN.md Phase 9; docs/phase-9-contracts.md "Fleet UI"): the player's robotaxi fleet.
--
--   earnings   what the pods have earned and not collected yet, with Collect (Net CollectFleet), about how much
--              the fleet makes an hour, and the offline rule in plain words ("Pods earn a quarter as much while
--              you're away, for up to 8 hours.", from the snapshot's offlineRate and offlineCapHours). With no
--              pods and nothing to collect, a short intro takes its place.
--   buy        Buy a pod with its price and the slots used of the slots allowed. It opens the zone picker, and
--              picking a zone buys the pod there (Net BuyPod). When it can't be used it says why: every slot
--              full, or the cash short.
--   pods       one card per pod: its zone with that zone's demand and what a pod makes there an hour, Move (the
--              zone picker, Net AssignPod) and Sell (a confirm showing what you get back, Net SellPod).
--   picker     a page of every zone the snapshot lists: name, demand, and the expected $ an hour per pod; the
--              moving pod's zone is marked "Here now". Cancel, or the header's Back, leaves it.
--
-- Everything shown comes from the profile snapshot's fleet (ProfileController.fleetOf) and every change from the
-- server's answers: while one request is with the server every action is off and the tapped one says what it's
-- doing. Presentation only: PhoneController passes the fleet, the state and the callbacks. The module returns
-- the component as `App` and its pure helpers (offlineRuleText, hourlyTotal, demandText, buyBlock) for
-- tests/Phone.spec.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local React = require(ReplicatedStorage.Packages.React)
local Economy = require(ReplicatedStorage.Shared.Config.Economy)

local Kit = require(script.Parent.Kit)
local PhoneConfig = require(script.Parent.PhoneConfig)
local Theme = require(script.Parent.Parent.Theme)
local ProfileController = require(script.Parent.Parent.Parent.Controllers.ProfileController)

local e = React.createElement
local colors = Theme.colors
local text = PhoneConfig.fleetText

local PERCENT = 100
local SAME_RATE = 1e-6 -- two offline shares this close are the same share
local SHOWN_DECIMALS = 100 -- demand and hours show at most two decimals ("1.25x", "1.5 hours")

type Fleet = ProfileController.Fleet
type FleetPod = ProfileController.FleetPod
type FleetZone = ProfileController.FleetZone

export type Action = "buy" | "assign" | "collect" | "sell"

-- The request waiting on the server, if any: which action, and the pod or zone it is about.
export type Busy = { action: Action, uid: string?, zone: string? }

-- The zone picker: for a new pod ("buy"), or to move pod `uid` ("assign").
export type Picker = { kind: "buy" | "assign", uid: string? }

-- Why Buy can't be used: every slot has a pod, the cash is short, or there's no zone to send a pod to.
export type BuyBlock = "full" | "cash" | "zones"

export type Props = {
	fleet: Fleet?, -- nil until the snapshot brings one
	cash: number?, -- the player's cash, when known
	busy: Busy?,
	picker: Picker?, -- the zone picker is showing
	confirmUid: string?, -- the pod whose sell confirm is showing
	onCollect: () -> (),
	onAskBuy: () -> (), -- open the picker for a new pod
	onAskMove: (uid: string) -> (), -- open the picker for this pod
	onPickZone: (zone: string) -> (), -- a zone was picked in the open picker
	onCancelPick: () -> (),
	onAskSell: (uid: string) -> (),
	onCancelSell: () -> (),
	onConfirmSell: (uid: string) -> (),
}

local FleetApp = {}

-- Pure helpers ---------------------------------------------------------------------------------------------------

-- A number with at most two decimals and no trailing zeros: 1 -> "1", 1.2 -> "1.2", 1.256 -> "1.26".
local function shortNumber(value: number): string
	local rounded = math.round(value * SHOWN_DECIMALS) / SHOWN_DECIMALS
	if rounded % 1 == 0 then
		return string.format("%d", rounded)
	end
	local written = string.format("%.2f", rounded)
	local trimmed = string.gsub(written, "0+$", "")
	return trimmed
end

-- The offline rule in plain words: "Pods earn a quarter as much while you're away, for up to 8 hours." A share
-- with no words of its own reads as a percent; no offline earning at all says pods earn only while you play.
function FleetApp.offlineRuleText(rate: number, capHours: number): string
	if rate <= 0 or capHours <= 0 then
		return text.onlineOnly
	end
	local share: string? = nil
	for _, named in text.offlineShares do
		if math.abs(named.rate - rate) < SAME_RATE then
			share = named.words
			break
		end
	end
	local hours = if capHours == 1 then text.oneHour else string.format(text.hours, shortNumber(capHours))
	return string.format(text.offline, share or string.format(text.offlinePercent, math.round(rate * PERCENT)), hours)
end

-- "1.2x demand".
function FleetApp.demandText(demand: number): string
	return string.format(text.demand, shortNumber(demand))
end

local function zonesById(fleet: Fleet): { [string]: FleetZone }
	local byId: { [string]: FleetZone } = {}
	for _, zone in fleet.zones do
		byId[zone.id] = zone
	end
	return byId
end

-- What the whole fleet is expected to make an hour while the player is online: each pod's zone's perHour.
function FleetApp.hourlyTotal(fleet: Fleet): number
	local byId = zonesById(fleet)
	local total = 0
	for _, pod in fleet.pods do
		local zone = byId[pod.zone]
		if zone then
			total += zone.perHour
		end
	end
	return total
end

-- Why Buy can't be used now (nil: it can), and how much cash is missing when that's why. Unknown cash doesn't
-- block it: the server checks again anyway.
function FleetApp.buyBlock(fleet: Fleet, cash: number?): (BuyBlock?, number?)
	if #fleet.pods >= fleet.slots then
		return "full", nil
	elseif #fleet.zones == 0 then
		return "zones", nil
	elseif cash ~= nil and cash < fleet.podPrice then
		return "cash", fleet.podPrice - cash
	end
	return nil, nil
end

local function podName(index: number): string
	return string.format(text.podName, index)
end

-- "$12,345" as rich text, with the currency symbol in the accent color (like the Wallet app and the HUD).
local function cashText(amount: number): string
	local formatted = Economy.formatCash(amount)
	local symbol = Economy.display.symbol
	local at = string.find(formatted, symbol, 1, true)
	if at == nil then
		return formatted
	end
	return string.sub(formatted, 1, at - 1)
		.. `<font color="#{colors.accent:ToHex()}">{symbol}</font>`
		.. string.sub(formatted, at + #symbol)
end

-- Cards ----------------------------------------------------------------------------------------------------------

local function dim(label: string, order: number)
	return Kit.Text({ text = label, order = order, size = Theme.text.small, color = colors.textDim })
end

-- No pods and nothing to collect: what the fleet is, and the offline rule.
local function IntroCard(props: { fleet: Fleet, order: number })
	local fleet = props.fleet
	return Kit.Card({ order = props.order, gap = PhoneConfig.fleet.cardGap, padding = Theme.spacing.lg }, {
		Title = Kit.Text({ text = text.introTitle, order = 1, size = Theme.text.heading, font = Theme.fonts.bold }),
		Body = Kit.Text({ text = text.introBody, order = 2, color = colors.textDim }),
		Offline = dim(FleetApp.offlineRuleText(fleet.offlineRate, fleet.offlineCapHours), 3),
	})
end

-- Uncollected earnings with Collect, the fleet's rate an hour and the offline rule.
local function EarningsCard(props: { fleet: Fleet, busy: Busy?, order: number, actions: Props })
	local fleet = props.fleet
	local busy = props.busy
	local hourly = FleetApp.hourlyTotal(fleet)
	local collecting = busy ~= nil and busy.action == "collect"
	return Kit.Card({ order = props.order, gap = PhoneConfig.fleet.cardGap, padding = Theme.spacing.lg }, {
		Label = Kit.Text({
			text = text.ready,
			order = 1,
			size = Theme.text.small,
			font = Theme.fonts.medium,
			color = colors.textDim,
		}),
		Value = Kit.Text({
			text = cashText(fleet.uncollected),
			order = 2,
			size = Theme.text.price,
			font = Theme.fonts.bold,
			richText = true,
		}),
		Rate = if hourly > 0 then dim(string.format(text.perHour, Economy.formatCash(hourly)), 3) else nil,
		Offline = dim(FleetApp.offlineRuleText(fleet.offlineRate, fleet.offlineCapHours), 4),
		Collect = e(Kit.Button, {
			label = if collecting then text.collecting else text.collect,
			style = "primary",
			disabled = busy ~= nil or fleet.uncollected < 1,
			order = 5,
			onTap = props.actions.onCollect,
		}),
	})
end

-- Buy a pod: the slots used, the button with the price, and why it's off when it is.
local function BuyCard(props: { fleet: Fleet, cash: number?, busy: Busy?, order: number, actions: Props })
	local fleet = props.fleet
	local block, shortBy = FleetApp.buyBlock(fleet, props.cash)
	local note: string? = nil
	if block == "full" then
		note = text.slotsFull
	elseif block == "zones" then
		note = text.noZones
	elseif block == "cash" and shortBy ~= nil then
		note = string.format(text.cashNeeded, Economy.formatCash(shortBy))
	end
	-- The fleet's main action until it has a pod; after that Collect is.
	local first = #fleet.pods == 0
	return Kit.Card({ order = props.order, gap = PhoneConfig.fleet.cardGap }, {
		Slots = Kit.Text({
			text = string.format(text.slots, #fleet.pods, fleet.slots),
			order = 1,
			size = Theme.text.small,
			font = Theme.fonts.medium,
			color = colors.textDim,
		}),
		Buy = e(Kit.Button, {
			label = string.format(text.buy, Economy.formatCash(fleet.podPrice)),
			style = if first then "primary" else "secondary",
			disabled = props.busy ~= nil or block ~= nil,
			order = 2,
			onTap = props.actions.onAskBuy,
		}),
		Note = if note
			then Kit.Text({ text = note, order = 3, size = Theme.text.small, color = colors.warning })
			else nil,
	})
end

-- One pod: its name, its zone with the demand, what it makes there an hour, and Move and Sell.
local function PodCard(props: {
	pod: FleetPod,
	index: number,
	zone: FleetZone?,
	canMove: boolean,
	busy: Busy?,
	order: number,
	actions: Props,
})
	local pod = props.pod
	local zone = props.zone
	local busy = props.busy
	local locked = busy ~= nil
	local busyHere = busy ~= nil and busy.uid == pod.uid
	return Kit.Card({ order = props.order }, {
		Name = Kit.Text({ text = podName(props.index), order = 1, size = Theme.text.heading, font = Theme.fonts.bold }),
		Zone = Kit.Text({
			text = if zone
				then string.format(text.zoneLine, zone.name, FleetApp.demandText(zone.demand))
				else text.unknownZone,
			order = 2,
			color = colors.textDim,
		}),
		Earns = if zone
			then Kit.Text({
				text = string.format(text.earns, Economy.formatCash(zone.perHour)),
				order = 3,
				size = Theme.text.small,
				font = Theme.fonts.bold,
				color = colors.accent,
			})
			else nil,
		Buttons = Kit.ButtonRow({
			order = 4,
			count = 2,
			buttons = {
				Move = e(Kit.Button, {
					label = if busyHere and busy and busy.action == "assign" then text.moving else text.move,
					disabled = locked or not props.canMove,
					order = 1,
					size = UDim2.fromScale(1, 1),
					onTap = function()
						props.actions.onAskMove(pod.uid)
					end,
				}),
				Sell = e(Kit.Button, {
					label = if busyHere and busy and busy.action == "sell" then text.selling else text.sell,
					style = "dangerText",
					disabled = locked,
					order = 2,
					size = UDim2.fromScale(1, 1),
					onTap = function()
						props.actions.onAskSell(pod.uid)
					end,
				}),
			},
		}),
	})
end

-- The zone picker ------------------------------------------------------------------------------------------------

-- One zone as a tappable row: its name, then its demand and what a pod makes there an hour. The moving pod's
-- current zone carries a "Here now" pill and can't be picked. While the request is out the picked row says so.
local function ZoneRow(props: {
	zone: FleetZone,
	order: number,
	current: boolean,
	locked: boolean,
	busyLabel: string?,
	onPick: (zone: string) -> (),
})
	local zone = props.zone
	local list = PhoneConfig.list
	local config = PhoneConfig.fleet
	local inactive = props.current or props.locked
	local pillRoom = if props.current then config.hereNowWidth else 0
	local detail = props.busyLabel
		or string.format(
			text.zoneDetail,
			FleetApp.demandText(zone.demand),
			string.format(text.earns, Economy.formatCash(zone.perHour))
		)
	return e("TextButton", {
		LayoutOrder = props.order,
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = colors.panelRaised,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		AutoButtonColor = not inactive,
		Active = not inactive,
		Selectable = not inactive,
		Text = "",
		[React.Event.Activated] = function()
			if not inactive then
				props.onPick(zone.id)
			end
		end,
	}, {
		Tall = e("UISizeConstraint", { MinSize = Vector2.new(0, list.rowHeight) }),
		Padding = e("UIPadding", {
			PaddingLeft = UDim.new(0, list.rowPadding),
			PaddingRight = UDim.new(0, list.rowPadding + pillRoom),
			PaddingTop = UDim.new(0, config.zoneRowPadding),
			PaddingBottom = UDim.new(0, config.zoneRowPadding),
		}),
		Lines = Kit.Stack({ gap = config.zoneLineGap }, {
			Name = Kit.Text({ text = zone.name, order = 1, font = Theme.fonts.bold }),
			Detail = Kit.Text({
				text = detail,
				order = 2,
				size = Theme.text.small,
				font = if props.busyLabel then Theme.fonts.bold else Theme.fonts.regular,
				color = if props.busyLabel then colors.accent else colors.textDim,
			}),
		}),
		Here = if props.current
			then e("Frame", {
				AnchorPoint = Vector2.new(0, 0.5),
				Position = UDim2.new(1, Theme.spacing.sm, 0.5, 0),
				Size = UDim2.fromOffset(pillRoom - Theme.spacing.sm, PhoneConfig.garage.pillHeight),
				BackgroundTransparency = 1,
			}, {
				Align = e("UIListLayout", { HorizontalAlignment = Enum.HorizontalAlignment.Right }),
				Pill = Kit.Pill({ text = text.hereNow }),
			})
			else nil,
	})
end

-- Every zone on one card, thin dividers between them (like the GPS app's lists).
local function ZoneList(props: {
	fleet: Fleet,
	currentZone: string?,
	busy: Busy?,
	order: number,
	onPick: (zone: string) -> (),
})
	local list = PhoneConfig.list
	local busy = props.busy
	local rows: { [string]: any } = {
		Layout = e("UIListLayout", {
			FillDirection = Enum.FillDirection.Vertical,
			HorizontalAlignment = Enum.HorizontalAlignment.Center, -- dividers sit inset from both edges
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
		Corner = e("UICorner", { CornerRadius = UDim.new(0, Theme.radius.card) }),
	}
	for index, zone in props.fleet.zones do
		if index > 1 then
			rows[`Divider{index}`] = e("Frame", {
				LayoutOrder = 2 * index - 1,
				Size = UDim2.new(1, -2 * list.rowPadding, 0, 1),
				BackgroundColor3 = colors.divider,
				BorderSizePixel = 0,
			})
		end
		local picked = busy ~= nil and busy.zone == zone.id
		rows[`Zone_{zone.id}`] = e(ZoneRow, {
			zone = zone,
			order = 2 * index,
			current = zone.id == props.currentZone,
			locked = busy ~= nil,
			busyLabel = if picked and busy then (if busy.action == "buy" then text.buying else text.moving) else nil,
			onPick = props.onPick,
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

local function ZonePicker(props: { fleet: Fleet, picker: Picker, busy: Busy?, actions: Props })
	local fleet = props.fleet
	local picker = props.picker
	local title, body = text.pickBuyTitle, string.format(text.pickBuyBody, Economy.formatCash(fleet.podPrice))
	local currentZone: string? = nil
	if picker.kind == "assign" then
		for index, pod in fleet.pods do
			if pod.uid == picker.uid then
				title = string.format(text.pickMoveTitle, podName(index))
				currentZone = pod.zone
				break
			end
		end
		body = text.pickMoveBody
	end
	return Kit.Page({}, {
		Title = Kit.Text({ text = title, order = 1, size = Theme.text.heading, font = Theme.fonts.bold }),
		Body = Kit.Text({ text = body, order = 2, color = colors.textDim }),
		Zones = e(ZoneList, {
			fleet = fleet,
			currentZone = currentZone,
			busy = props.busy,
			order = 3,
			onPick = props.actions.onPickZone,
		}),
		Cancel = e(Kit.Button, {
			label = text.cancel,
			disabled = props.busy ~= nil,
			order = 4,
			onTap = props.actions.onCancelPick,
		}),
	})
end

-- The sell confirm -----------------------------------------------------------------------------------------------

-- Over the dimmed fleet, from the bottom (like the Garage app's): what the pod sells for, Keep it and Sell.
local function SellConfirm(props: { name: string, uid: string, sellBack: number, busy: boolean, actions: Props })
	local price = Economy.formatCash(props.sellBack)
	local fade = Kit.useAppear(false)
	local scrimTransparency = colors.scrimTransparency
	local sheet = PhoneConfig.sheet
	return e("Frame", {
		ZIndex = 5,
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
	}, {
		-- Dims the fleet behind; tapping it is the same as Keep it.
		Scrim = e("TextButton", {
			Size = UDim2.fromScale(1, 1),
			BackgroundColor3 = colors.scrim,
			BackgroundTransparency = fade:map(function(value: number): number
				return scrimTransparency + (1 - scrimTransparency) * value
			end),
			BorderSizePixel = 0,
			AutoButtonColor = false,
			Selectable = false,
			Text = "",
			[React.Event.Activated] = function()
				if not props.busy then
					props.actions.onCancelSell()
				end
			end,
		}),
		Sheet = e("Frame", {
			ZIndex = 2,
			AnchorPoint = Vector2.new(0.5, 1),
			Position = fade:map(function(value: number): UDim2
				return UDim2.new(0.5, 0, 1, -sheet.padding + value * sheet.slideOffset)
			end),
			Size = UDim2.new(1, -2 * sheet.padding, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
			Active = true,
		}, {
			Card = Kit.Card({ gap = Theme.spacing.md, padding = Theme.spacing.lg }, {
				Title = Kit.Text({
					text = string.format(text.confirmTitle, props.name),
					order = 1,
					size = Theme.text.heading,
					font = Theme.fonts.bold,
				}),
				Body = Kit.Text({ text = string.format(text.confirmBody, price), order = 2, color = colors.textDim }),
				Buttons = Kit.ButtonRow({
					order = 3,
					count = 2,
					buttons = {
						Keep = e(Kit.Button, {
							label = text.keep,
							disabled = props.busy,
							order = 1,
							size = UDim2.fromScale(1, 1),
							onTap = props.actions.onCancelSell,
						}),
						Sell = e(Kit.Button, {
							label = if props.busy then text.selling else string.format(text.confirmSell, price),
							style = "danger",
							disabled = props.busy,
							order = 2,
							size = UDim2.fromScale(1, 1),
							onTap = function()
								props.actions.onConfirmSell(props.uid)
							end,
						}),
					},
				}),
			}),
		}),
	})
end

-- The app ------------------------------------------------------------------------------------------------------

local function Overview(props: Props, fleet: Fleet)
	local byId = zonesById(fleet)
	local children: { [string]: any } = {}
	if #fleet.pods > 0 or fleet.uncollected > 0 then
		children.Earnings = e(EarningsCard, { fleet = fleet, busy = props.busy, order = 1, actions = props })
	else
		children.Intro = e(IntroCard, { fleet = fleet, order = 1 })
	end
	children.Buy = e(BuyCard, { fleet = fleet, cash = props.cash, busy = props.busy, order = 2, actions = props })
	if #fleet.pods > 0 then
		children.PodsTitle = Kit.SectionTitle({ text = text.yourPods, order = 3 })
		-- Moving needs somewhere else to go.
		local canMove = #fleet.zones > 1
		for index, pod in fleet.pods do
			children[`Pod_{pod.uid}`] = e(PodCard, {
				pod = pod,
				index = index,
				zone = byId[pod.zone],
				canMove = canMove,
				busy = props.busy,
				order = 3 + index,
				actions = props,
			})
		end
	end
	return Kit.Page({}, children)
end

function FleetApp.App(props: Props)
	local fleet = props.fleet
	if fleet == nil then
		return Kit.Page({}, {
			Loading = Kit.Text({ text = text.loading, color = colors.textDim }),
		})
	end

	local picker = props.picker
	if picker ~= nil then
		return e(ZonePicker, { fleet = fleet, picker = picker, busy = props.busy, actions = props })
	end

	local confirming: { name: string, uid: string }? = nil
	for index, pod in fleet.pods do
		if pod.uid == props.confirmUid then
			confirming = { name = podName(index), uid = pod.uid }
		end
	end
	local busy = props.busy
	return e("Frame", {
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
	}, {
		Page = Overview(props, fleet),
		Confirm = if confirming
			then e(SellConfirm, {
				name = confirming.name,
				uid = confirming.uid,
				sellBack = fleet.sellBack,
				busy = busy ~= nil and busy.action == "sell",
				actions = props,
			})
			else nil,
	})
end

return FleetApp
