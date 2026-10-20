--!strict
-- The Wrap & Tint shop's side panel (docs/phase-7-contracts.md "Client"): a full-height panel on the right of
-- the screen, so the player's car stays in view in the middle while they shop. Top to bottom:
--
--   header   "Wrap & Tint" over the car's name; Reset (when anything differs from the car) and the close button
--   tabs     Paint, Finish, Wrap, Wheels, Stance, Tint, Calipers, Extras, Plate: one row of chips that scrolls
--            sideways
--   body     the chosen tab's options (UI/Customize/Options), scrolling
--   footer   the running total (or what the player still needs) and Buy
--
-- with the confirm dialog over everything when one is open. Nothing dims the world behind the panel: taps and
-- drags outside it reach the camera (orbit round the car). The panel slides in from the right when it opens
-- (Theme.motion). Presentation only: CustomizationController passes the view and the callbacks.

local GuiService = game:GetService("GuiService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local React = require(ReplicatedStorage.Packages.React)
local Theme = require(script.Parent.Parent.Theme)
local Primitives = require(script.Parent.Parent.Shop.Primitives)
local CustomizeModel = require(script.Parent.CustomizeModel)
local Options = require(script.Parent.Options)
local Style = require(script.Parent.Style)

local e = React.createElement

local colors = Theme.colors
local fonts = Theme.fonts
local layout = Style.layout
local copy = Style.copy

export type Props = {
	view: CustomizeModel.PanelView,
	screen: Vector2, -- unscaled pixels inside the safe area
	gamepad: boolean, -- the player uses a gamepad: Buy (or the dialog's confirm) is selected
	confirm: Primitives.Confirm?,
	onTab: (tab: string) -> (),
	onReset: () -> (),
	onBuy: () -> (),
	onClose: () -> (),
	onPick: (key: string) -> (),
	onStep: (key: string, direction: number) -> (),
	onPlate: (text: string) -> (),
}

local Panel = {}

local function lerp(from: number, to: number, alpha: number): number
	return from + (to - from) * alpha
end

-- Header ---------------------------------------------------------------------------------------------------------

local function Header(props: { title: string, canReset: boolean, busy: boolean, onReset: () -> (), onClose: () -> () })
	local right = layout.closeSize + (if props.canReset then layout.resetWidth + layout.headerGap else 0)
	return e("Frame", {
		Position = UDim2.fromOffset(layout.pad, layout.headerTop),
		Size = UDim2.new(1, -2 * layout.pad, 0, layout.headerHeight),
		BackgroundTransparency = 1,
	}, {
		Text = e("Frame", {
			AnchorPoint = Vector2.new(0, 0.5),
			Position = UDim2.fromScale(0, 0.5),
			Size = UDim2.new(1, -(right + layout.headerGap), 0, layout.eyebrowHeight + layout.titleHeight),
			BackgroundTransparency = 1,
		}, {
			Eyebrow = e(Primitives.Label, {
				text = copy.eyebrow,
				height = layout.eyebrowHeight,
				textSize = Theme.text.small,
				font = fonts.bold,
				color = colors.accent,
			}),
			Title = e(Primitives.Label, {
				text = props.title,
				height = layout.titleHeight,
				textSize = Theme.text.heading,
				font = fonts.bold,
				position = UDim2.fromOffset(0, layout.eyebrowHeight),
			}),
		}),
		Reset = if props.canReset
			then e(Primitives.Button, {
				label = copy.reset,
				style = "secondary",
				disabled = props.busy,
				anchor = Vector2.new(1, 0.5),
				position = UDim2.new(1, -(layout.closeSize + layout.headerGap), 0.5, 0),
				size = UDim2.fromOffset(layout.resetWidth, layout.headerHeight),
				onTap = props.onReset,
			})
			else nil,
		Close = e(Primitives.CloseButton, {
			anchor = Vector2.new(1, 0.5),
			position = UDim2.fromScale(1, 0.5),
			onTap = props.onClose,
		}),
	})
end

-- Footer ---------------------------------------------------------------------------------------------------------

-- "Total" (or "You need $X more") over the total, and Buy beside it.
local function Footer(props: { view: CustomizeModel.PanelView, focusRef: any, onBuy: () -> () })
	local view = props.view
	local total = view.total
	local labelColor = if total.status ~= nil then colors.warning else colors.textDim
	return e("Frame", {
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromScale(0, 1),
		Size = UDim2.new(1, 0, 0, CustomizeModel.footerHeight()),
		BackgroundTransparency = 1,
	}, {
		Divider = e("Frame", {
			Size = UDim2.new(1, 0, 0, 1),
			BackgroundColor3 = colors.divider,
			BorderSizePixel = 0,
		}),
		Row = e("Frame", {
			Position = UDim2.fromOffset(layout.pad, layout.footerPad),
			Size = UDim2.new(1, -2 * layout.pad, 0, layout.buttonHeight),
			BackgroundTransparency = 1,
		}, {
			Total = e("Frame", {
				AnchorPoint = Vector2.new(0, 0.5),
				Position = UDim2.fromScale(0, 0.5),
				Size = UDim2.new(
					1 - layout.buyWidthShare,
					-layout.actionGap,
					0,
					layout.totalLabelHeight + layout.totalValueHeight
				),
				BackgroundTransparency = 1,
			}, {
				Label = e(Primitives.Label, {
					text = total.status or copy.total,
					height = layout.totalLabelHeight,
					textSize = Theme.text.small,
					font = fonts.medium,
					color = labelColor,
				}),
				Value = e(Primitives.Label, {
					text = total.text,
					height = layout.totalValueHeight,
					textSize = if total.hasChanges then Theme.text.price else Theme.text.body,
					font = if total.hasChanges then fonts.bold else fonts.medium,
					color = Primitives.toneColor(total.tone),
					position = UDim2.fromOffset(0, layout.totalLabelHeight),
				}),
			}),
			Buy = e(Primitives.Button, {
				label = view.buy.label,
				style = "primary",
				disabled = view.buy.disabled,
				anchor = Vector2.new(1, 0),
				position = UDim2.fromScale(1, 0),
				size = UDim2.new(layout.buyWidthShare, 0, 0, layout.buttonHeight),
				onTap = props.onBuy,
				buttonRef = props.focusRef,
			}),
		}),
	})
end

-- Confirm dialog -------------------------------------------------------------------------------------------------

-- The question, the total / cash / cash-after rows and Cancel / Buy, centered over a dim layer. Tapping outside it
-- cancels (unless the call is running).
local function ConfirmDialog(props: { confirm: Primitives.Confirm, screenWidth: number, focusRef: any })
	local confirm = props.confirm
	local appear = Primitives.useAppear()
	local width = math.min(layout.confirmWidth, props.screenWidth - 2 * layout.margin)
	local rowsHeight = #confirm.rows * layout.confirmRowHeight
	local height = 2 * layout.pad
		+ layout.confirmTitleHeight
		+ layout.confirmGap
		+ rowsHeight
		+ layout.confirmGap
		+ layout.buttonHeight

	local rows: { [string]: any } = {
		Layout = e("UIListLayout", {
			FillDirection = Enum.FillDirection.Vertical,
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
	}
	for index, row in confirm.rows do
		rows[`Row{index}`] = e("Frame", {
			LayoutOrder = index,
			Size = UDim2.new(1, 0, 0, layout.confirmRowHeight),
			BackgroundTransparency = 1,
		}, {
			Name = e(Primitives.Label, {
				text = row.label,
				height = layout.confirmRowHeight,
				color = colors.textDim,
				width = UDim.new(0.5, 0),
			}),
			Value = e(Primitives.Label, {
				text = row.value,
				height = layout.confirmRowHeight,
				font = fonts.bold,
				color = Primitives.toneColor(row.tone),
				align = Enum.TextXAlignment.Right,
				position = UDim2.fromScale(0.3, 0),
				width = UDim.new(0.7, 0),
			}),
		})
	end

	local buttonWidth = UDim2.new(0.5, -layout.actionGap / 2, 0, layout.buttonHeight)
	return e("Frame", {
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		ZIndex = 3,
	}, {
		Scrim = e("TextButton", {
			Size = UDim2.fromScale(1, 1),
			BackgroundColor3 = colors.scrim,
			BackgroundTransparency = appear:map(function(value: number): number
				return lerp(1, colors.scrimTransparency, value)
			end),
			BorderSizePixel = 0,
			AutoButtonColor = false,
			Selectable = false,
			Text = "",
			[React.Event.Activated] = function()
				if not confirm.busy then
					confirm.onCancel()
				end
			end,
		}),
		Dialog = e("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromOffset(width, height),
			BackgroundColor3 = colors.panel,
			BorderSizePixel = 0,
			Active = true, -- taps on the dialog don't reach the dim layer
			ZIndex = 2,
		}, {
			Corner = Primitives.corner(Theme.radius.sheet),
			Scale = e("UIScale", {
				Scale = appear:map(function(value: number): number
					return lerp(Theme.motion.pressScale, 1, value)
				end),
			}),
			Padding = e("UIPadding", {
				PaddingLeft = UDim.new(0, layout.pad),
				PaddingRight = UDim.new(0, layout.pad),
				PaddingTop = UDim.new(0, layout.pad),
				PaddingBottom = UDim.new(0, layout.pad),
			}),
			Title = e(Primitives.Label, {
				text = confirm.title,
				height = layout.confirmTitleHeight,
				textSize = Theme.text.heading,
				font = fonts.bold,
			}),
			Rows = e("Frame", {
				Position = UDim2.fromOffset(0, layout.confirmTitleHeight + layout.confirmGap),
				Size = UDim2.new(1, 0, 0, rowsHeight),
				BackgroundTransparency = 1,
			}, rows),
			Buttons = e("Frame", {
				AnchorPoint = Vector2.new(0, 1),
				Position = UDim2.fromScale(0, 1),
				Size = UDim2.new(1, 0, 0, layout.buttonHeight),
				BackgroundTransparency = 1,
			}, {
				Cancel = e(Primitives.Button, {
					label = copy.cancel,
					style = "secondary",
					disabled = confirm.busy,
					size = buttonWidth,
					onTap = confirm.onCancel,
				}),
				Confirm = e(Primitives.Button, {
					label = if confirm.busy then confirm.busyLabel else confirm.confirmLabel,
					style = "primary",
					disabled = confirm.busy,
					anchor = Vector2.new(1, 0),
					position = UDim2.fromScale(1, 0),
					size = buttonWidth,
					onTap = confirm.onConfirm,
					buttonRef = props.focusRef,
				}),
			}),
		}),
	})
end

-- The panel ------------------------------------------------------------------------------------------------------

function Panel.Panel(props: Props)
	local view = props.view
	local appear = Primitives.useAppear()
	local rect = CustomizeModel.panelLayout(props.screen)

	-- Gamepad: select the dialog's confirm, else Buy when it can be used, else the panel's first control (Buy is
	-- off until something changes), when the panel opens or a dialog opens or closes; the player moves to the tabs
	-- and options from there. CustomizationController lets go of the selection on close.
	local panelRef = React.useRef(nil :: GuiObject?)
	local buyRef = React.useRef(nil :: GuiObject?)
	local confirmRef = React.useRef(nil :: GuiObject?)
	local hasConfirm = props.confirm ~= nil
	local buyReady = not view.buy.disabled
	React.useEffect(function()
		if not props.gamepad then
			return
		end
		local target = if hasConfirm then confirmRef.current elseif buyReady then buyRef.current else nil
		local panel = panelRef.current
		if target ~= nil then
			GuiService.SelectedObject = target
		elseif panel ~= nil then
			GuiService:Select(panel)
		end
	end, { props.gamepad, hasConfirm } :: { any })

	local bodyTop = CustomizeModel.headerHeight() + CustomizeModel.tabsHeight()
	local tabs: { Primitives.Chip } = {}
	for _, tab in view.tabs do
		table.insert(tabs, { id = tab.id, label = tab.label, selected = tab.id == view.tab })
	end

	local confirm = props.confirm
	return e("Frame", {
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
	}, {
		Panel = e("Frame", {
			ref = panelRef,
			AnchorPoint = Vector2.new(1, 0),
			-- Slides in from the right edge as it opens.
			Position = appear:map(function(value: number): UDim2
				return UDim2.fromOffset(rect.left + rect.width + (1 - value) * (rect.width + layout.margin), rect.top)
			end),
			Size = UDim2.fromOffset(rect.width, rect.height),
			BackgroundColor3 = colors.panel,
			BackgroundTransparency = colors.panelTransparency,
			BorderSizePixel = 0,
			Active = true, -- taps on the panel don't reach the world (the orbit camera)
			ClipsDescendants = true,
			ZIndex = 2,
		}, {
			Corner = Primitives.corner(Theme.radius.sheet),
			Header = e(Header, {
				title = view.title,
				canReset = view.canReset,
				busy = view.busy,
				onReset = props.onReset,
				onClose = props.onClose,
			}),
			Tabs = e("Frame", {
				Position = UDim2.fromOffset(layout.pad, CustomizeModel.headerHeight() + layout.tabsGap),
				Size = UDim2.new(1, -2 * layout.pad, 0, Primitives.chipsHeight()),
				BackgroundTransparency = 1,
			}, {
				Chips = e(Primitives.TrimChips, { chips = tabs, disabled = false, onPick = props.onTab }),
			}),
			-- Keyed by tab, so each tab's list starts scrolled to the top.
			[`Body_{view.tab}`] = e("Frame", {
				Position = UDim2.fromOffset(0, bodyTop),
				Size = UDim2.new(1, 0, 1, -(bodyTop + CustomizeModel.footerHeight())),
				BackgroundTransparency = 1,
			}, {
				Options = e(Options.Body, {
					view = view.body,
					columns = rect.columns,
					busy = view.busy,
					onPick = props.onPick,
					onStep = props.onStep,
					onPlate = props.onPlate,
				}),
			}),
			Footer = e(Footer, { view = view, focusRef = buyRef, onBuy = props.onBuy }),
		}),
		Confirm = if confirm ~= nil
			then e(ConfirmDialog, { confirm = confirm, screenWidth = props.screen.X, focusRef = confirmRef })
			else nil,
	})
end

return Panel
