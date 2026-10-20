--!strict
-- The shop sheet's frame (docs/phase-4-contracts.md "Shops"): a dimmed screen behind it, the sheet itself, and
-- the confirm dialog on top when one is open. It draws whatever Primitives.Content it is given (the dealership
-- or the used lot) in one of three shapes picked by ShopModel.layoutFor:
--
--   sheet   portrait phones: a bottom sheet across the full width, up to 90% of the screen tall, with the header
--           (and its close button) on top, the body scrolling under it and the buttons pinned to the bottom
--   card    tablets and desktop: the same column as a centered card
--   wide    landscape phones and short windows: a wide card with the stats on the left and the price, notes
--           and buttons on the right, so the buttons never scroll out of view
--
-- The sheet is as tall as its content, up to the layout's maxHeight; past that the body scrolls. Tapping the dim
-- area closes the sheet (or cancels the dialog). The sheet slides in when it opens (Theme.motion).
-- Presentation only: ShopController passes the content, the confirm dialog and the callbacks.

local GuiService = game:GetService("GuiService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local React = require(ReplicatedStorage.Packages.React)
local Theme = require(script.Parent.Parent.Theme)
local Primitives = require(script.Parent.Primitives)
local ShopModel = require(script.Parent.ShopModel)
local Style = require(script.Parent.Style)

local e = React.createElement

local colors = Theme.colors
local fonts = Theme.fonts
local layout = Style.layout

export type Props = {
	content: Primitives.Content,
	layout: ShopModel.Layout,
	screen: Vector2, -- unscaled pixels inside the safe area (the layout was picked for it)
	confirm: Primitives.Confirm?,
	gamepad: boolean?, -- the player uses a gamepad: the main button (or the dialog's confirm) is selected
	onClose: () -> (),
}

-- Heights of the parts of a sheet, in unscaled pixels.
export type Metrics = {
	height: number, -- the whole sheet
	header: number,
	footer: number, -- the button row and its padding (0 without buttons)
	body: number, -- visible height of the scrolling body (stacked) or of both columns (wide)
	bodyContent: number, -- stacked: main and summary; wide: the left column
	asideContent: number, -- wide: the summary in the right column (0 when stacked)
	overflow: boolean, -- the body scrolls
}

local ShopSheet = {}

-- The footer button a gamepad selects: the first enabled primary one, else the first enabled one; nil when
-- every button is off.
function ShopSheet.focusActionKey(actions: { Primitives.Action }): string?
	local fallback: string? = nil
	for _, action in actions do
		if not action.disabled then
			if action.style == "primary" then
				return action.key
			end
			fallback = fallback or action.key
		end
	end
	return fallback
end

local function lerp(from: number, to: number, alpha: number): number
	return from + (to - from) * alpha
end

-- The height of blocks stacked with the section gap between them.
local function stackHeight(sections: { Primitives.Section }): number
	local total = 0
	for index, section in sections do
		total += section.height
		if index > 1 then
			total += layout.sectionGap
		end
	end
	return total
end

local function headerHeight(hasSubtitle: boolean): number
	local height = layout.headerTop + layout.eyebrowHeight + layout.titleHeight + layout.headerBottom
	return if hasSubtitle then height + layout.subtitleHeight else height
end

local function footerHeight(actionCount: number): number
	return if actionCount > 0 then layout.footerPad + layout.buttonHeight + layout.pad else 0
end

-- How tall each part of a sheet is for this content and layout. Pure, for tests/Shop.spec.
function ShopSheet.measure(content: Primitives.Content, sheetLayout: ShopModel.Layout): Metrics
	local header = headerHeight(content.subtitle ~= nil)
	local footer = footerHeight(#content.actions)
	-- The body ends with one pad of space, or the footer's own padding when there are buttons below it.
	local bodyEnd = if footer > 0 then 0 else layout.pad

	if sheetLayout.mode == "wide" then
		local left = stackHeight(content.main) + layout.pad
		local summary = stackHeight(content.summary)
		local right = summary + (if footer > 0 then footer else layout.pad)
		local height = math.min(header + math.max(left, right), sheetLayout.maxHeight)
		local body = math.max(height - header, 0)
		return {
			height = height,
			header = header,
			footer = footer,
			body = body,
			bodyContent = left,
			asideContent = summary,
			overflow = left > body or right > body,
		}
	end

	local sections = table.clone(content.main)
	table.move(content.summary, 1, #content.summary, #sections + 1, sections)
	local bodyContent = stackHeight(sections) + bodyEnd
	local height = math.min(header + bodyContent + footer, sheetLayout.maxHeight)
	local body = math.max(height - header - footer, 0)
	return {
		height = height,
		header = header,
		footer = footer,
		body = body,
		bodyContent = bodyContent,
		asideContent = 0,
		overflow = bodyContent > body,
	}
end

-- Parts ------------------------------------------------------------------------------------------------------

-- Eyebrow (accent), title and subtitle, with the close button in the top-right corner.
local function Header(props: { content: Primitives.Content, height: number, onClose: () -> () })
	local content = props.content
	local textWidth = UDim.new(1, -(2 * layout.pad + layout.closeSize + Theme.spacing.sm))
	local subtitle = content.subtitle
	return e("Frame", {
		Size = UDim2.new(1, 0, 0, props.height),
		BackgroundTransparency = 1,
	}, {
		Text = e("Frame", {
			Position = UDim2.fromOffset(layout.pad, layout.headerTop),
			Size = UDim2.new(textWidth.Scale, textWidth.Offset, 1, -layout.headerTop),
			BackgroundTransparency = 1,
		}, {
			Layout = e("UIListLayout", {
				FillDirection = Enum.FillDirection.Vertical,
				SortOrder = Enum.SortOrder.LayoutOrder,
			}),
			Eyebrow = e(Primitives.Label, {
				order = 1,
				text = content.eyebrow,
				height = layout.eyebrowHeight,
				textSize = Theme.text.small,
				font = fonts.bold,
				color = colors.accent,
			}),
			Title = e(Primitives.Label, {
				order = 2,
				text = content.title,
				height = layout.titleHeight,
				textSize = Theme.text.title,
				font = fonts.bold,
			}),
			Subtitle = if subtitle
				then e(Primitives.Label, {
					order = 3,
					text = subtitle,
					height = layout.subtitleHeight,
					textSize = Theme.text.small,
					color = colors.textDim,
				})
				else nil,
		}),
		Close = e(Primitives.CloseButton, {
			anchor = Vector2.new(1, 0),
			position = UDim2.new(1, -layout.pad, 0, layout.headerTop),
			onTap = props.onClose,
		}),
	})
end

-- A vertical scrolling list of sections, padded on the sides and by `bottomPad` under the last one.
local function SectionScroll(props: {
	sections: { Primitives.Section },
	position: UDim2,
	size: UDim2,
	bottomPad: number,
})
	local children: { [string]: any } = {
		Layout = e("UIListLayout", {
			FillDirection = Enum.FillDirection.Vertical,
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, layout.sectionGap),
		}),
		Padding = e("UIPadding", {
			PaddingLeft = UDim.new(0, layout.pad),
			PaddingRight = UDim.new(0, layout.pad),
			PaddingBottom = UDim.new(0, props.bottomPad),
		}),
	}
	for index, section in props.sections do
		children[`{index}_{section.key}`] = e("Frame", {
			LayoutOrder = index,
			Size = UDim2.new(1, 0, 0, section.height),
			BackgroundTransparency = 1,
		}, {
			Content = section.element,
		})
	end
	return e("ScrollingFrame", {
		Position = props.position,
		Size = props.size,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		ScrollBarThickness = layout.chipScrollBar,
		ScrollBarImageColor3 = colors.textDim,
	}, children)
end

-- The button row: every action the same width, side by side, with a hairline above it when the body scrolls.
local function Footer(props: {
	actions: { Primitives.Action },
	position: UDim2,
	width: UDim,
	divider: boolean,
	focusRef: any,
})
	local count = #props.actions
	local focusKey = ShopSheet.focusActionKey(props.actions)
	local children: { [string]: any } = {
		Layout = e("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, layout.actionGap),
		}),
	}
	local share = (count - 1) * layout.actionGap / math.max(count, 1)
	for index, action in props.actions do
		children[action.key] = e(Primitives.Button, {
			order = index,
			label = action.label,
			style = action.style,
			disabled = action.disabled,
			size = UDim2.new(1 / count, -share, 0, layout.buttonHeight),
			onTap = action.onTap,
			buttonRef = if action.key == focusKey then props.focusRef else nil,
		})
	end
	return e("Frame", {
		Position = props.position,
		Size = UDim2.new(props.width.Scale, props.width.Offset, 0, footerHeight(count)),
		BackgroundTransparency = 1,
	}, {
		Divider = if props.divider
			then e("Frame", {
				Size = UDim2.new(1, 0, 0, 1),
				BackgroundColor3 = colors.divider,
				BorderSizePixel = 0,
			})
			else nil,
		Row = e("Frame", {
			Position = UDim2.fromOffset(layout.pad, layout.footerPad),
			Size = UDim2.new(1, -2 * layout.pad, 0, layout.buttonHeight),
			BackgroundTransparency = 1,
		}, children),
	})
end

-- The confirm dialog, centered over a second dim layer. Tapping outside it cancels (unless the call is running).
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
					label = Style.copy.cancel,
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

-- The sheet ----------------------------------------------------------------------------------------------------

function ShopSheet.Sheet(props: Props)
	local appear = Primitives.useAppear()
	local content = props.content
	local sheetLayout = props.layout
	local metrics = ShopSheet.measure(content, sheetLayout)
	local mode = sheetLayout.mode
	local radius = Theme.radius.sheet

	-- Gamepad: select the main button (or the dialog's confirm) when the sheet opens, a dialog opens or closes,
	-- or the buttons change. ShopController lets go of the selection when the sheet closes.
	local footerRef = React.useRef(nil :: GuiObject?)
	local confirmRef = React.useRef(nil :: GuiObject?)
	local hasConfirm = props.confirm ~= nil
	local focusKey = ShopSheet.focusActionKey(content.actions) or ""
	React.useEffect(function()
		if props.gamepad then
			local target = if hasConfirm then confirmRef.current else footerRef.current
			if target ~= nil then
				GuiService.SelectedObject = target
			end
		end
	end, { props.gamepad == true, hasConfirm, focusKey } :: { any })

	-- A bottom sheet hangs `radius` below the screen edge so only its top corners show rounded.
	local hang = if mode == "sheet" then radius else 0
	local frameHeight = metrics.height + hang
	local position = if mode == "sheet"
		then appear:map(function(value: number): UDim2
			return UDim2.new(0.5, 0, 1, hang + (1 - value) * frameHeight)
		end)
		else appear:map(function(value: number): UDim2
			return UDim2.new(0.5, 0, 0.5, (1 - value) * layout.cardRise)
		end)

	local parts: { [string]: any } = {
		Corner = Primitives.corner(radius),
		Header = e(Header, { content = content, height = metrics.header, onClose = props.onClose }),
	}

	if mode == "wide" then
		local aside = sheetLayout.asideWidth
		local asideBody = math.max(metrics.body - metrics.footer, 0)
		parts.Main = e(SectionScroll, {
			sections = content.main,
			position = UDim2.fromOffset(0, metrics.header),
			size = UDim2.new(1, -aside, 0, metrics.body),
			bottomPad = layout.pad,
		})
		parts.Rule = e("Frame", {
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, -aside, 0, metrics.header),
			Size = UDim2.fromOffset(1, math.max(metrics.body - layout.pad, 0)),
			BackgroundColor3 = colors.divider,
			BorderSizePixel = 0,
		})
		parts.Aside = e("Frame", {
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, 0, 0, metrics.header),
			Size = UDim2.fromOffset(aside, metrics.body),
			BackgroundTransparency = 1,
		}, {
			Summary = e(SectionScroll, {
				sections = content.summary,
				position = UDim2.new(),
				size = UDim2.new(1, 0, 0, asideBody),
				bottomPad = if metrics.footer > 0 then 0 else layout.pad,
			}),
			Footer = if #content.actions > 0
				then e(Footer, {
					actions = content.actions,
					position = UDim2.fromOffset(0, asideBody),
					width = UDim.new(1, 0),
					divider = metrics.asideContent > asideBody,
					focusRef = footerRef,
				})
				else nil,
		})
	else
		local sections = table.clone(content.main)
		table.move(content.summary, 1, #content.summary, #sections + 1, sections)
		parts.Body = e(SectionScroll, {
			sections = sections,
			position = UDim2.fromOffset(0, metrics.header),
			size = UDim2.new(1, 0, 0, metrics.body),
			bottomPad = if metrics.footer > 0 then 0 else layout.pad,
		})
		parts.Footer = if #content.actions > 0
			then e(Footer, {
				actions = content.actions,
				position = UDim2.fromOffset(0, metrics.header + metrics.body),
				width = UDim.new(1, 0),
				divider = metrics.overflow,
				focusRef = footerRef,
			})
			else nil
	end

	local confirm = props.confirm
	return e("Frame", {
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
	}, {
		-- Tapping the dim area closes the sheet, like the close button.
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
			ZIndex = 1,
			[React.Event.Activated] = function()
				props.onClose()
			end,
		}),
		Sheet = e("Frame", {
			AnchorPoint = if mode == "sheet" then Vector2.new(0.5, 1) else Vector2.new(0.5, 0.5),
			Position = position,
			Size = UDim2.fromOffset(sheetLayout.width, frameHeight),
			BackgroundColor3 = colors.panel,
			BackgroundTransparency = colors.panelTransparency,
			BorderSizePixel = 0,
			Active = true, -- taps on the sheet don't fall through to the dim area or the world
			ClipsDescendants = true,
			ZIndex = 2,
		}, parts),
		Confirm = if confirm ~= nil
			then e(ConfirmDialog, { confirm = confirm, screenWidth = props.screen.X, focusRef = confirmRef })
			else nil,
	})
end

return ShopSheet
