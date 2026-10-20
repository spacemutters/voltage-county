--!strict
-- The HUD.
--
--   driving panel   (PLAN.md Phase 1 "HUD stub") while driving: speed in mph, gear and drive mode in one panel
--                   at the bottom center, with a row of key hints under it on keyboard and gamepad.
--   wallet          (Phase 3, docs/phase-3-contracts.md "HUD cash readout") always: the player's cash
--                   ("$12,345") in the top-left corner, with a small Codes button under it.
--   code sheet      while open: a text box and a Redeem button in the middle of the screen (until Phase 4's
--                   phone takes codes over).
--
-- Presentation only: HudController passes every value and callback in as props and redraws about 10 times a
-- second while driving. Sizes come from Config/Controls and Config/Economy `hud` at UI scale 1; HudController
-- scales the whole tree for bigger screens. Every touch target is at least 44 px (Economy.spec checks).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local React = require(ReplicatedStorage.Packages.React)
local Controls = require(ReplicatedStorage.Shared.Config.Controls)
local Economy = require(ReplicatedStorage.Shared.Config.Economy)
local Types = require(ReplicatedStorage.Shared.Types)

local e = React.createElement

export type HintItem = { keys: string, label: string }

export type Props = {
	driving: boolean, -- the driving panel and hints show only while driving
	mph: number, -- already rounded
	gear: string,
	mode: Types.DriveMode,
	regen: Types.RegenLevel,
	hints: { HintItem }?, -- nil or empty hides the hint row (touch devices)
	cash: number?, -- from the player's Cash attribute; nil until their data has loaded
	codesOpen: boolean, -- the code sheet is showing
	redeeming: boolean, -- a code is being checked by the server
	onToggleCodes: () -> (),
	onCloseCodes: () -> (),
	onRedeem: (text: string) -> (),
}

type DrivingProps = {
	mph: number,
	gear: string,
	mode: Types.DriveMode,
	regen: Types.RegenLevel,
	hints: { HintItem }?,
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

-- Speed, gear and drive mode, bottom center, with the key hints under them.
local function Driving(props: DrivingProps)
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

-- "$12,345" as rich text, with the currency symbol in the accent color.
local function cashText(cash: number): string
	local formatted = Economy.formatCash(cash)
	local symbol = Economy.display.symbol
	local at = string.find(formatted, symbol, 1, true)
	if at == nil then
		return formatted
	end
	local accent = Controls.theme.accent:ToHex()
	return string.sub(formatted, 1, at - 1)
		.. `<font color="#{accent}">{symbol}</font>`
		.. string.sub(formatted, at + #symbol)
end

-- The player's cash, top left (lined up with the touch steering zones), with the Codes button under it.
local function Wallet(props: { cash: number?, codesOpen: boolean, onToggleCodes: () -> () })
	local theme = Controls.theme
	local hud = Economy.hud
	local margin = Controls.touch.margin
	local cash = props.cash
	local open = props.codesOpen

	return e("Frame", {
		Position = UDim2.fromOffset(margin, margin),
		Size = UDim2.fromOffset(hud.cashMaxWidth, 2 * hud.rowHeight + hud.gap),
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
			BackgroundColor3 = theme.panel,
			BackgroundTransparency = theme.panelTransparency,
			BorderSizePixel = 0,
			FontFace = theme.fonts.bold,
			RichText = cash ~= nil,
			Text = if cash ~= nil then cashText(cash) else hud.loadingText,
			TextColor3 = if cash ~= nil then theme.text else theme.textDim,
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
		-- Opens and closes the code sheet; filled with the accent while it's open, like the GPS button.
		Codes = e("TextButton", {
			LayoutOrder = 2,
			Size = UDim2.fromOffset(hud.codesButtonWidth, hud.rowHeight),
			BackgroundColor3 = if open then theme.accent else theme.panel,
			BackgroundTransparency = if open then 0 else theme.panelTransparency,
			BorderSizePixel = 0,
			AutoButtonColor = true,
			FontFace = theme.fonts.bold,
			Text = hud.codesLabel,
			TextColor3 = if open then theme.onAccent else theme.text,
			TextSize = hud.buttonTextSize,
			[React.Event.Activated] = function()
				props.onToggleCodes()
			end,
		}, {
			Corner = e("UICorner", { CornerRadius = UDim.new(0, hud.cornerRadius) }),
		}),
	})
end

-- The code sheet: a title with a Close button, a text box, and Redeem (Enter in the box works too). The typed
-- text stays in the box itself; HudController closes the sheet when a code works and leaves it open to fix a
-- typo when it doesn't.
local function CodeSheet(props: { redeeming: boolean, onRedeem: (text: string) -> (), onClose: () -> () })
	local theme = Controls.theme
	local panel = Economy.hud.panel
	local box = React.useRef(nil :: TextBox?)

	-- Put the cursor in the box when the sheet opens (on phones this brings up the keyboard).
	React.useEffect(function()
		local current = box.current
		if current ~= nil then
			current:CaptureFocus()
		end
	end, {})

	local function submit()
		local current = box.current
		if current ~= nil and not props.redeeming then
			props.onRedeem(current.Text)
		end
	end

	local pad = panel.padding
	local innerWidth = panel.width - 2 * pad
	local buttonTop = panel.headerHeight + panel.inputHeight + pad
	local height = buttonTop + panel.buttonHeight + pad

	return e("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(panel.width, height),
		BackgroundColor3 = theme.panel,
		BackgroundTransparency = theme.panelTransparency,
		BorderSizePixel = 0,
		Active = true, -- taps on the sheet don't fall through to the controls or the world
	}, {
		Corner = e("UICorner", { CornerRadius = UDim.new(0, panel.cornerRadius) }),
		Title = e("TextLabel", {
			Position = UDim2.fromOffset(pad, 0),
			Size = UDim2.fromOffset(innerWidth - panel.closeButtonWidth, panel.headerHeight),
			BackgroundTransparency = 1,
			FontFace = theme.fonts.bold,
			Text = panel.title,
			TextColor3 = theme.text,
			TextSize = panel.titleTextSize,
			TextXAlignment = Enum.TextXAlignment.Left,
		}),
		Close = e("TextButton", {
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -pad, 0, panel.headerHeight / 2),
			Size = UDim2.fromOffset(panel.closeButtonWidth, panel.buttonHeight),
			BackgroundColor3 = theme.panelRaised,
			BorderSizePixel = 0,
			AutoButtonColor = true,
			FontFace = theme.fonts.bold,
			Text = panel.closeLabel,
			TextColor3 = theme.text,
			TextSize = panel.textSize,
			[React.Event.Activated] = function()
				props.onClose()
			end,
		}, {
			Corner = e("UICorner", { CornerRadius = UDim.new(0, panel.innerCornerRadius) }),
		}),
		Input = e("TextBox", {
			Position = UDim2.fromOffset(pad, panel.headerHeight),
			Size = UDim2.fromOffset(innerWidth, panel.inputHeight),
			BackgroundColor3 = theme.panelRaised,
			BorderSizePixel = 0,
			ClearTextOnFocus = false,
			TextEditable = not props.redeeming,
			FontFace = theme.fonts.medium,
			PlaceholderText = panel.placeholder,
			PlaceholderColor3 = theme.textDim,
			Text = "",
			TextColor3 = theme.text,
			TextSize = panel.textSize,
			TextTruncate = Enum.TextTruncate.AtEnd,
			TextXAlignment = Enum.TextXAlignment.Left,
			ref = box,
			[React.Event.FocusLost] = function(_rbx: TextBox, enterPressed: boolean)
				if enterPressed then
					submit()
				end
			end,
		}, {
			Corner = e("UICorner", { CornerRadius = UDim.new(0, panel.innerCornerRadius) }),
			Padding = e("UIPadding", {
				PaddingLeft = UDim.new(0, pad),
				PaddingRight = UDim.new(0, pad),
			}),
		}),
		Redeem = e("TextButton", {
			Position = UDim2.fromOffset(pad, buttonTop),
			Size = UDim2.fromOffset(innerWidth, panel.buttonHeight),
			BackgroundColor3 = if props.redeeming then theme.panelRaised else theme.accent,
			BorderSizePixel = 0,
			AutoButtonColor = not props.redeeming,
			FontFace = theme.fonts.bold,
			Text = if props.redeeming then panel.redeemingLabel else panel.redeemLabel,
			TextColor3 = if props.redeeming then theme.textDim else theme.onAccent,
			TextSize = panel.textSize,
			[React.Event.Activated] = submit,
		}, {
			Corner = e("UICorner", { CornerRadius = UDim.new(0, panel.innerCornerRadius) }),
		}),
	})
end

local function Hud(props: Props)
	return e("Frame", {
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		-- Drawn above the touch controls (a sibling in HudController's tree), so the open code sheet covers them.
		ZIndex = 2,
	}, {
		Driving = if props.driving
			then e(Driving, {
				mph = props.mph,
				gear = props.gear,
				mode = props.mode,
				regen = props.regen,
				hints = props.hints,
			})
			else nil,
		Wallet = e(Wallet, {
			cash = props.cash,
			codesOpen = props.codesOpen,
			onToggleCodes = props.onToggleCodes,
		}),
		CodeSheet = if props.codesOpen
			then e(CodeSheet, {
				redeeming = props.redeeming,
				onRedeem = props.onRedeem,
				onClose = props.onCloseCodes,
			})
			else nil,
	})
end

return Hud
