--!strict
-- The HUD (PLAN.md Phase 4 "HUD: speed, energy placeholder, cash, active job").
--
--   speed panel     while driving, bottom centre: the gear, the speed in the player's units (mph or km/h, from
--                   their settings), the drive mode and regen level, and along its bottom the energy row (Phase 5
--                   fills it: until then the bar shows full with no number). On keyboard and gamepad a row of
--                   key hints sits under it, ending with the phone key.
--   wallet          always, top left: the player's cash ("$12,345"), lined up with the touch steering zones.
--   active job      under the cash: the job in progress (Phase 6 fills it; empty until then, so nothing shows).
--
-- Codes moved to the phone's Codes app, and the phone button is drawn by the phone itself (UI/Phone), placed
-- beside this speed panel by UI/Phone/Layout, which shares the panel's size and position with this file.
-- Presentation only: HudController passes every value in as props and redraws about 10 times a second while
-- driving. Sizes come from Config/Controls, Config/Economy `hud` and UI/Phone/PhoneConfig `hud` at UI scale 1;
-- HudController scales the whole tree for bigger screens.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local React = require(ReplicatedStorage.Packages.React)
local Controls = require(ReplicatedStorage.Shared.Config.Controls)
local Economy = require(ReplicatedStorage.Shared.Config.Economy)
local Types = require(ReplicatedStorage.Shared.Types)

local Layout = require(script.Parent.Phone.Layout)
local PhoneConfig = require(script.Parent.Phone.PhoneConfig)
local Theme = require(script.Parent.Theme)

local e = React.createElement

export type HintItem = { keys: string, label: string }

-- The job in progress, as the HUD shows it (Phase 6 decides what goes in it).
export type ActiveJob = { title: string, detail: string? }

-- The car's energy: what kind, and how full (0..1); nil level until Phase 5 tracks it.
export type Energy = { kind: "battery" | "fuel", level: number? }

export type Props = {
	driving: boolean, -- the speed panel and hints show only while driving
	speed: number, -- already rounded, in the units of `unitLabel`
	unitLabel: string, -- "mph" or "km/h"
	gear: string,
	mode: Types.DriveMode,
	regen: Types.RegenLevel,
	energy: Energy?,
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
	hints: { HintItem }?,
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

-- The energy row along the bottom of the speed panel: "Battery", a bar, and the percentage once it's known.
local function EnergyRow(props: { energy: Energy? })
	local config = PhoneConfig.hud.energy
	local colors = Theme.colors
	local energy = props.energy
	local level = if energy then energy.level else nil
	local known = level ~= nil
	local fill = if level ~= nil then math.clamp(level, 0, 1) else 1
	local kind = if energy then energy.kind else "battery"
	local pad = Controls.hud.clusterPadding
	local valueWidth = if known then config.valueWidth else 0
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
		Label = e("TextLabel", {
			Size = UDim2.new(0, config.labelWidth, 1, 0),
			BackgroundTransparency = 1,
			FontFace = Theme.fonts.medium,
			Text = config.labels[kind] or kind,
			TextColor3 = colors.textDim,
			TextSize = Controls.hud.smallTextSize,
			TextXAlignment = Enum.TextXAlignment.Left,
		}),
		Bar = e("Frame", {
			AnchorPoint = Vector2.new(0, 0.5),
			Position = UDim2.new(0, config.labelWidth, 0.5, 0),
			Size = UDim2.new(1, -(config.labelWidth + valueWidth), 0, config.barHeight),
			BackgroundColor3 = colors.track,
			BorderSizePixel = 0,
		}, {
			Corner = e("UICorner", { CornerRadius = UDim.new(0.5, 0) }),
			Fill = e("Frame", {
				Size = UDim2.fromScale(fill, 1),
				-- Until Phase 5 the bar only marks where energy will show, so it stays quiet.
				BackgroundColor3 = if known then colors.accent else colors.textDim,
				BorderSizePixel = 0,
			}, {
				Corner = e("UICorner", { CornerRadius = UDim.new(0.5, 0) }),
			}),
		}),
		Value = if level ~= nil
			then e("TextLabel", {
				AnchorPoint = Vector2.new(1, 0),
				Position = UDim2.fromScale(1, 0),
				Size = UDim2.new(0, config.valueWidth, 1, 0),
				BackgroundTransparency = 1,
				FontFace = Theme.fonts.bold,
				Text = string.format(config.percentFormat, math.round(fill * 100)),
				TextColor3 = colors.text,
				TextSize = Controls.hud.smallTextSize,
				TextXAlignment = Enum.TextXAlignment.Right,
			})
			else nil,
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

	return e("Frame", {
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
	}, {
		Cluster = cluster,
		Hints = hintRow,
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
				hints = props.hints,
			})
			else nil,
		Wallet = e(Wallet, { cash = props.cash, job = props.job }),
	})
end

return Hud
