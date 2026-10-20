--!strict
-- The HUD (PLAN.md Phase 4 "HUD: speed, energy placeholder, cash, active job"; Phase 5 energy).
--
--   speed panel     while driving, bottom centre: the gear, the speed in the player's units (mph or km/h, from
--                   their settings), the drive mode and regen level, and along its bottom the energy row: a
--                   battery or fuel-pump drawing, a bar of what's left, the % and the estimated range in the
--                   player's units. Amber under Config/Energy.warningLevel, red under criticalLevel, and "Limp
--                   mode" in place of the range once the car is empty. Before the server has published the car's
--                   level the bar shows full and quiet, with no number. On keyboard and gamepad a row of key hints
--                   sits under the panel, ending with the phone key.
--   charging card   while the car charges or fuels: a small card above the speed panel with the level filling,
--                   the rate and the cost per %. HudController picks its spot (clear of the touch controls, the
--                   phone button, the GPS chip and the notices) and passes it in.
--   wallet          always, top left: the player's cash ("$12,345"), lined up with the touch steering zones.
--   active job      under the cash: the job in progress (Phase 6 fills it; empty until then, so nothing shows).
--
-- Codes moved to the phone's Codes app, and the phone button is drawn by the phone itself (UI/Phone), placed
-- beside this speed panel by UI/Phone/Layout, which shares the panel's size and position with this file.
-- Presentation only: HudController passes every value in as props (EnergyController works out the energy
-- texts) and redraws about 10 times a second while driving. Sizes come from Config/Controls, Config/Economy
-- `hud`, UI/Phone/PhoneConfig `hud` and ENERGY below, at UI scale 1; HudController scales the whole tree for
-- bigger screens. The battery and pump are drawn from frames, so no image assets are needed.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local React = require(ReplicatedStorage.Packages.React)
local Controls = require(ReplicatedStorage.Shared.Config.Controls)
local Economy = require(ReplicatedStorage.Shared.Config.Economy)
local Types = require(ReplicatedStorage.Shared.Types)

local Layout = require(script.Parent.Phone.Layout)
local PhoneConfig = require(script.Parent.Phone.PhoneConfig)
local Theme = require(script.Parent.Theme)

local e = React.createElement

local PERCENT = 100
local PERCENT_EPSILON = 1e-6 -- absorbs float noise when rounding a level down to whole percent (0.29 * 100)

export type HintItem = { keys: string, label: string }

-- The job in progress, as the HUD shows it (Phase 6 decides what goes in it).
export type ActiveJob = { title: string, detail: string? }

-- How worried the energy row looks: "low" is amber, "critical" red (Config/Energy warningLevel, criticalLevel).
export type EnergyAlert = "normal" | "low" | "critical"

-- The car's energy as the HUD shows it (Controllers/EnergyController works it out from the car's attributes).
export type Energy = {
	kind: "battery" | "fuel",
	level: number?, -- 0..1; nil until the server publishes the car's level (the bar then shows full, quietly)
	rangeText: string?, -- estimated range in the player's units, e.g. "48 mi"
	alert: EnergyAlert,
	limp: boolean, -- out of energy: the car is held to the limp speed
}

-- The car is charging or fueling right now.
export type Charging = {
	kind: "battery" | "fuel",
	level: number, -- 0..1
	rateText: string, -- e.g. "+0.9% a second"
	costText: string?, -- e.g. "$3 per %"; nil when it's free
}

export type Props = {
	driving: boolean, -- the speed panel and hints show only while driving
	speed: number, -- already rounded, in the units of `unitLabel`
	unitLabel: string, -- "mph" or "km/h"
	gear: string,
	mode: Types.DriveMode,
	regen: Types.RegenLevel,
	energy: Energy?,
	charging: Charging?, -- nil: not charging, no card
	chargingRect: Layout.Rect?, -- where the charging card goes (UI-scale-1 pixels), from HudController
	hints: { HintItem }?, -- nil or empty hides the hint row (touch devices)
	cash: number?, -- from the player's Cash attribute; nil until their data has loaded
	job: ActiveJob?, -- nil: no job, the slot stays empty
}

type DrivingProps = {
	speed: number,
	unitLabel: string,
	gear: string,
	mode: Types.DriveMode,
	regen: Types.RegenLevel,
	energy: Energy?,
	charging: Charging?,
	chargingRect: Layout.Rect?,
	hints: { HintItem }?,
}

-- The energy row's and charging card's sizes and words (px at UI scale 1): PhoneConfig.hud.energy and
-- PhoneConfig.hud.chargingCard. The card's place is HudController's.
local ENERGY = {
	iconSize = PhoneConfig.hud.energy.iconSize,
	iconStroke = PhoneConfig.hud.energy.iconStroke,
	iconInset = PhoneConfig.hud.energy.iconInset,
	nubSize = PhoneConfig.hud.energy.nubSize,
	gap = PhoneConfig.hud.energy.gap,
	valueWidth = PhoneConfig.hud.energy.valueWidth,
	rangeSpacing = PhoneConfig.hud.energy.rangeSpacing,
	limpText = PhoneConfig.hud.energy.limpText,
	card = PhoneConfig.hud.chargingCard,
}

-- "W/S Drive    A/D Steer ..." with the keys in bold white and the labels in the dim text color.
local function hintText(hints: { HintItem }): string
	local keyColor = Theme.colors.text:ToHex()
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

-- A column of lines in the top part of the speed panel, vertically centred there.
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
		Size = UDim2.fromOffset(props.width, Controls.hud.clusterSize.Y),
		BackgroundTransparency = 1,
	}, children)
end

-- The color an alert level draws in: the accent when all is well, amber when low, red when nearly empty.
local function alertColor(alert: EnergyAlert): Color3
	local colors = Theme.colors
	if alert == "critical" then
		return colors.danger
	elseif alert == "low" then
		return colors.warning
	end
	return colors.accent
end

-- "62%" for a 0..1 level, rounded down so the HUD never shows more than is left (a car just under 20 % reads
-- 19 %, in amber).
local function percentText(level: number): string
	local percent = math.floor(math.clamp(level, 0, 1) * PERCENT + PERCENT_EPSILON)
	return string.format(PhoneConfig.hud.energy.percentFormat, percent)
end

-- A small rounded box: filled, or outlined when `stroke` is given.
local function box(props: {
	position: UDim2,
	size: UDim2,
	color: Color3,
	stroke: number?,
	anchor: Vector2?,
	radius: number?,
	order: number?,
})
	return e("Frame", {
		AnchorPoint = props.anchor or Vector2.zero,
		Position = props.position,
		Size = props.size,
		BackgroundColor3 = props.color,
		BackgroundTransparency = if props.stroke then 1 else 0,
		BorderSizePixel = 0,
		ZIndex = props.order or 1,
	}, {
		Corner = e("UICorner", { CornerRadius = UDim.new(0, props.radius or 1) }),
		Stroke = if props.stroke
			then e("UIStroke", {
				ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
				Color = props.color,
				Thickness = props.stroke,
			})
			else nil,
	})
end

-- The battery (an outline with a terminal, filled to `level`) or the fuel pump (a body with a window and a
-- hose), in `color`, inside an ENERGY.iconSize box anchored at its left middle.
local function EnergyIcon(props: { kind: "battery" | "fuel", level: number?, color: Color3, position: UDim2 })
	local size = ENERGY.iconSize
	local stroke = ENERGY.iconStroke
	local nub = ENERGY.nubSize
	local children: { [string]: any }
	if props.kind == "fuel" then
		-- Pump body on the left two-thirds, a window near its top, and the hose curling down its right side.
		local bodyWidth = math.floor(size.X * 2 / 3)
		children = {
			Body = box({
				position = UDim2.fromOffset(0, 0),
				size = UDim2.fromOffset(bodyWidth, size.Y),
				color = props.color,
				stroke = stroke,
			}),
			Window = box({
				position = UDim2.fromOffset(ENERGY.iconInset + stroke, ENERGY.iconInset + stroke),
				size = UDim2.fromOffset(bodyWidth - 2 * (ENERGY.iconInset + stroke), nub.Y / 2),
				color = props.color,
			}),
			Arm = box({
				position = UDim2.fromOffset(bodyWidth, ENERGY.iconInset),
				size = UDim2.fromOffset(size.X - bodyWidth, stroke),
				color = props.color,
			}),
			Hose = box({
				position = UDim2.fromOffset(size.X - stroke, ENERGY.iconInset),
				size = UDim2.fromOffset(stroke, size.Y - ENERGY.iconInset),
				color = props.color,
			}),
		}
	else
		-- Battery outline, its terminal on the right, and the charge inside it.
		local bodyWidth = size.X - nub.X
		local inner = ENERGY.iconInset + stroke
		local level = math.clamp(props.level or 1, 0, 1)
		children = {
			Body = box({
				position = UDim2.fromOffset(0, 0),
				size = UDim2.fromOffset(bodyWidth, size.Y),
				color = props.color,
				stroke = stroke,
			}),
			Nub = box({
				anchor = Vector2.new(0, 0.5),
				position = UDim2.new(0, bodyWidth, 0.5, 0),
				size = UDim2.fromOffset(nub.X, nub.Y),
				color = props.color,
			}),
			Charge = if level > 0
				then box({
					position = UDim2.fromOffset(inner, inner),
					size = UDim2.fromOffset(math.max(1, (bodyWidth - 2 * inner) * level), size.Y - 2 * inner),
					color = props.color,
					radius = 0,
				})
				else nil,
		}
	end
	return e("Frame", {
		AnchorPoint = Vector2.new(0, 0.5),
		Position = props.position,
		Size = UDim2.fromOffset(size.X, size.Y),
		BackgroundTransparency = 1,
	}, children)
end

-- A bar of `fill` (0..1) on the track color.
local function Bar(props: {
	fill: number,
	color: Color3,
	position: UDim2,
	size: UDim2,
	anchor: Vector2?,
	order: number?,
})
	return e("Frame", {
		LayoutOrder = props.order,
		AnchorPoint = props.anchor or Vector2.zero,
		Position = props.position,
		Size = props.size,
		BackgroundColor3 = Theme.colors.track,
		BorderSizePixel = 0,
	}, {
		Corner = e("UICorner", { CornerRadius = UDim.new(0.5, 0) }),
		Fill = if props.fill > 0
			then e("Frame", {
				Size = UDim2.fromScale(math.clamp(props.fill, 0, 1), 1),
				BackgroundColor3 = props.color,
				BorderSizePixel = 0,
			}, {
				Corner = e("UICorner", { CornerRadius = UDim.new(0.5, 0) }),
			})
			else nil,
	})
end

-- The energy row along the bottom of the speed panel: the battery or pump, a bar, the % and the range.
local function EnergyRow(props: { energy: Energy? })
	local config = PhoneConfig.hud.energy
	local colors = Theme.colors
	local energy = props.energy
	local level = if energy then energy.level else nil
	local kind = if energy then energy.kind else "battery"
	local alert: EnergyAlert = if energy then energy.alert else "normal"
	local pad = Controls.hud.clusterPadding
	local barLeft = ENERGY.iconSize.X + ENERGY.gap

	-- Before the server publishes the level the bar only marks where energy shows, so it stays quiet.
	local barColor = if level ~= nil then alertColor(alert) else colors.textDim
	local inkColor = if alert == "normal" then colors.textDim else alertColor(alert)

	local value: string? = nil
	if level ~= nil and energy then
		local percentColor = if alert == "normal" then colors.text else alertColor(alert)
		local percent = `<font color="#{percentColor:ToHex()}"><b>{percentText(level)}</b></font>`
		local after = if energy.limp
			then `<font color="#{colors.danger:ToHex()}">{ENERGY.limpText}</font>`
			elseif energy.rangeText then `<font color="#{colors.textDim:ToHex()}">{energy.rangeText}</font>`
			else nil
		value = if after then percent .. ENERGY.rangeSpacing .. after else percent
	end
	local valueWidth = if value then ENERGY.valueWidth + ENERGY.gap else 0

	return e("Frame", {
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromScale(0, 1),
		Size = UDim2.new(1, 0, 0, config.rowHeight),
		BackgroundTransparency = 1,
	}, {
		Padding = e("UIPadding", {
			PaddingLeft = UDim.new(0, pad),
			PaddingRight = UDim.new(0, pad),
			PaddingBottom = UDim.new(0, Theme.spacing.sm),
		}),
		Icon = e(EnergyIcon, {
			kind = kind,
			level = level,
			color = inkColor,
			position = UDim2.fromScale(0, 0.5),
		}),
		Bar = e(Bar, {
			fill = if level ~= nil then level else 1,
			color = barColor,
			anchor = Vector2.new(0, 0.5),
			position = UDim2.new(0, barLeft, 0.5, 0),
			size = UDim2.new(1, -(barLeft + valueWidth), 0, config.barHeight),
		}),
		Value = if value
			then e("TextLabel", {
				AnchorPoint = Vector2.new(1, 0),
				Position = UDim2.fromScale(1, 0),
				Size = UDim2.new(0, ENERGY.valueWidth, 1, 0),
				BackgroundTransparency = 1,
				FontFace = Theme.fonts.medium,
				RichText = true,
				Text = value,
				TextColor3 = colors.textDim,
				TextSize = Controls.hud.smallTextSize,
				TextXAlignment = Enum.TextXAlignment.Right,
			})
			else nil,
	})
end

-- A row of the charging card: one label on the left and one on the right.
local function cardRow(props: {
	order: number,
	left: string,
	right: string?,
	leftFont: Font,
	rightFont: Font,
	size: number,
	leftColor: Color3,
	rightColor: Color3,
	icon: any?,
})
	local iconSpace = if props.icon then ENERGY.iconSize.X + ENERGY.gap else 0
	return e("Frame", {
		LayoutOrder = props.order,
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
	}, {
		Icon = props.icon,
		Left = e("TextLabel", {
			Position = UDim2.fromOffset(iconSpace, 0),
			Size = UDim2.new(1, -iconSpace, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
			FontFace = props.leftFont,
			Text = props.left,
			TextColor3 = props.leftColor,
			TextSize = props.size,
			TextXAlignment = Enum.TextXAlignment.Left,
		}),
		Right = if props.right
			then e("TextLabel", {
				Size = UDim2.fromScale(1, 0),
				AutomaticSize = Enum.AutomaticSize.Y,
				BackgroundTransparency = 1,
				FontFace = props.rightFont,
				Text = props.right,
				TextColor3 = props.rightColor,
				TextSize = props.size,
				TextXAlignment = Enum.TextXAlignment.Right,
			})
			else nil,
	})
end

-- While the car charges or fuels: "Charging 62%", the level filling, the rate and the cost per %.
local function ChargingCard(props: { charging: Charging, rect: Layout.Rect })
	local colors = Theme.colors
	local card = ENERGY.card
	local charging = props.charging
	return e("Frame", {
		Position = Layout.position(props.rect),
		Size = Layout.size(props.rect),
		BackgroundColor3 = colors.panel,
		BackgroundTransparency = colors.panelTransparency,
		BorderSizePixel = 0,
	}, {
		Corner = e("UICorner", { CornerRadius = UDim.new(0, Controls.hud.cornerRadius) }),
		Padding = e("UIPadding", {
			PaddingLeft = UDim.new(0, card.padding.X),
			PaddingRight = UDim.new(0, card.padding.X),
			PaddingTop = UDim.new(0, card.padding.Y),
			PaddingBottom = UDim.new(0, card.padding.Y),
		}),
		Layout = e("UIListLayout", {
			FillDirection = Enum.FillDirection.Vertical,
			VerticalAlignment = Enum.VerticalAlignment.Center,
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, card.rowGap),
		}),
		Header = e(cardRow, {
			order = 1,
			left = card.titles[charging.kind] or card.titles.battery,
			right = percentText(charging.level),
			leftFont = Theme.fonts.bold,
			rightFont = Theme.fonts.bold,
			size = Theme.text.body,
			leftColor = colors.text,
			rightColor = colors.success,
			icon = e(EnergyIcon, {
				kind = charging.kind,
				level = charging.level,
				color = colors.success,
				position = UDim2.fromScale(0, 0.5),
			}),
		}),
		Level = e(Bar, {
			order = 2,
			fill = charging.level,
			color = colors.success,
			position = UDim2.fromScale(0, 0),
			size = UDim2.new(1, 0, 0, card.barHeight),
		}),
		Footer = e(cardRow, {
			order = 3,
			left = charging.rateText,
			right = charging.costText,
			leftFont = Theme.fonts.medium,
			rightFont = Theme.fonts.medium,
			size = Theme.text.small,
			leftColor = colors.textDim,
			rightColor = colors.textDim,
		}),
	})
end

-- Speed, gear, drive mode and energy, bottom centre, with the key hints under them.
local function Driving(props: DrivingProps)
	local colors = Theme.colors
	local layout = Controls.hud
	local pad = layout.clusterPadding
	local hints = props.hints
	local showHints = hints ~= nil and #hints > 0
	local size = Layout.clusterSize()
	local top = layout.clusterSize.Y -- the gear / speed / mode part; the energy row is under it

	local cluster = e("Frame", {
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -Layout.clusterBottom(showHints)),
		Size = UDim2.fromOffset(size.X, size.Y),
		BackgroundColor3 = colors.panel,
		BackgroundTransparency = colors.panelTransparency,
		BorderSizePixel = 0,
	}, {
		Corner = e("UICorner", { CornerRadius = UDim.new(0, layout.cornerRadius) }),
		Gear = e("TextLabel", {
			AnchorPoint = Vector2.new(0, 0.5),
			Position = UDim2.fromOffset(pad, top / 2),
			Size = UDim2.fromOffset(layout.gearSize, layout.gearSize),
			BackgroundColor3 = colors.panelRaised,
			BorderSizePixel = 0,
			FontFace = Theme.fonts.bold,
			Text = props.gear,
			TextColor3 = colors.text,
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
					text = tostring(props.speed),
					font = Theme.fonts.bold,
					size = layout.speedTextSize,
					color = colors.text,
				}),
				Unit = e(line, {
					order = 2,
					text = props.unitLabel,
					font = Theme.fonts.medium,
					size = layout.unitTextSize,
					color = colors.textDim,
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
					font = Theme.fonts.bold,
					size = layout.modeTextSize,
					color = colors.accent,
					align = Enum.TextXAlignment.Right,
				}),
				Regen = e(line, {
					order = 2,
					text = layout.regenLabels[props.regen] or props.regen,
					font = Theme.fonts.regular,
					size = layout.smallTextSize,
					color = colors.textDim,
					align = Enum.TextXAlignment.Right,
				}),
			},
		}),
		Energy = e(EnergyRow, { energy = props.energy }),
	})

	local hintRow = if showHints and hints
		then e("TextLabel", {
			AnchorPoint = Vector2.new(0.5, 1),
			Position = UDim2.new(0.5, 0, 1, -layout.margin),
			Size = UDim2.fromOffset(0, layout.hintHeight),
			AutomaticSize = Enum.AutomaticSize.X,
			BackgroundColor3 = colors.panel,
			BackgroundTransparency = colors.panelTransparency,
			BorderSizePixel = 0,
			FontFace = Theme.fonts.regular,
			RichText = true,
			Text = hintText(hints),
			TextColor3 = colors.textDim,
			TextSize = layout.hintTextSize,
		}, {
			Corner = e("UICorner", { CornerRadius = UDim.new(0.5, 0) }),
			Padding = e("UIPadding", {
				PaddingLeft = UDim.new(0, pad),
				PaddingRight = UDim.new(0, pad),
			}),
		})
		else nil

	local charging = props.charging
	local chargingRect = props.chargingRect

	return e("Frame", {
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
	}, {
		Cluster = cluster,
		Hints = hintRow,
		Charging = if charging and chargingRect
			then e(ChargingCard, { charging = charging, rect = chargingRect })
			else nil,
	})
end

-- "$12,345" as rich text, with the currency symbol in the accent color.
local function cashText(cash: number): string
	local formatted = Economy.formatCash(cash)
	local symbol = Economy.display.symbol
	local at = string.find(formatted, symbol, 1, true)
	if at == nil then
		return formatted
	end
	local accent = Theme.colors.accent:ToHex()
	return string.sub(formatted, 1, at - 1)
		.. `<font color="#{accent}">{symbol}</font>`
		.. string.sub(formatted, at + #symbol)
end

-- The job in progress: its title and one line of detail, on a panel under the cash.
local function JobSlot(props: { job: ActiveJob, order: number })
	local slot = PhoneConfig.hud.jobSlot
	local colors = Theme.colors
	local job = props.job
	return e("Frame", {
		LayoutOrder = props.order,
		Size = UDim2.fromOffset(slot.size.X, slot.size.Y),
		BackgroundColor3 = colors.panel,
		BackgroundTransparency = colors.panelTransparency,
		BorderSizePixel = 0,
	}, {
		Corner = e("UICorner", { CornerRadius = UDim.new(0, Controls.hud.cornerRadius) }),
		Padding = e("UIPadding", {
			PaddingLeft = UDim.new(0, slot.padding),
			PaddingRight = UDim.new(0, slot.padding),
		}),
		Layout = e("UIListLayout", {
			FillDirection = Enum.FillDirection.Vertical,
			VerticalAlignment = Enum.VerticalAlignment.Center,
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
		Title = e(line, {
			order = 1,
			text = job.title,
			font = Theme.fonts.bold,
			size = slot.titleTextSize,
			color = colors.text,
			align = Enum.TextXAlignment.Left,
		}),
		Detail = if job.detail
			then e(line, {
				order = 2,
				text = job.detail,
				font = Theme.fonts.regular,
				size = slot.detailTextSize,
				color = colors.textDim,
				align = Enum.TextXAlignment.Left,
			})
			else nil,
	})
end

-- The player's cash, top left (lined up with the touch steering zones), with the active job under it.
local function Wallet(props: { cash: number?, job: ActiveJob? })
	local colors = Theme.colors
	local hud = Economy.hud
	local margin = Controls.touch.margin
	local cash = props.cash
	local job = props.job

	return e("Frame", {
		Position = UDim2.fromOffset(margin, margin),
		Size = UDim2.fromOffset(
			math.max(hud.cashMaxWidth, PhoneConfig.hud.jobSlot.size.X),
			hud.rowHeight + hud.gap + PhoneConfig.hud.jobSlot.size.Y
		),
		BackgroundTransparency = 1,
	}, {
		Layout = e("UIListLayout", {
			FillDirection = Enum.FillDirection.Vertical,
			HorizontalAlignment = Enum.HorizontalAlignment.Left,
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, hud.gap),
		}),
		-- Grows with the amount, between cashMinWidth and cashMaxWidth.
		Cash = e("TextLabel", {
			LayoutOrder = 1,
			Size = UDim2.fromOffset(0, hud.rowHeight),
			AutomaticSize = Enum.AutomaticSize.X,
			BackgroundColor3 = colors.panel,
			BackgroundTransparency = colors.panelTransparency,
			BorderSizePixel = 0,
			FontFace = Theme.fonts.bold,
			RichText = cash ~= nil,
			Text = if cash ~= nil then cashText(cash) else hud.loadingText,
			TextColor3 = if cash ~= nil then colors.text else colors.textDim,
			TextSize = hud.cashTextSize,
		}, {
			Corner = e("UICorner", { CornerRadius = UDim.new(0, hud.cornerRadius) }),
			Padding = e("UIPadding", {
				PaddingLeft = UDim.new(0, hud.cashPadding),
				PaddingRight = UDim.new(0, hud.cashPadding),
			}),
			Limits = e("UISizeConstraint", {
				MinSize = Vector2.new(hud.cashMinWidth, hud.rowHeight),
				MaxSize = Vector2.new(hud.cashMaxWidth, hud.rowHeight),
			}),
		}),
		Job = if job then e(JobSlot, { job = job, order = 2 }) else nil,
	})
end

local function Hud(props: Props)
	return e("Frame", {
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		-- Drawn above the touch controls (a sibling in HudController's tree).
		ZIndex = 2,
	}, {
		Driving = if props.driving
			then e(Driving, {
				speed = props.speed,
				unitLabel = props.unitLabel,
				gear = props.gear,
				mode = props.mode,
				regen = props.regen,
				energy = props.energy,
				charging = props.charging,
				chargingRect = props.chargingRect,
				hints = props.hints,
			})
			else nil,
		Wallet = e(Wallet, { cash = props.cash, job = props.job }),
	})
end

return Hud
