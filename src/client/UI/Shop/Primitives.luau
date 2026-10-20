--!strict
-- The building blocks of the shop sheets, in the shared look (UI/Theme): buttons, the round close button, trim
-- chips, stat bars, the price block, note cards and single text lines, plus the types the sheets pass around.
--
-- Every block has a fixed height from UI/Shop/Style (the *Height helpers below), so ShopSheet can size a sheet
-- to its content without measuring text. Presentation only: values and callbacks come in as props. Every
-- tappable thing is at least Theme.size.touchTarget in both directions.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local React = require(ReplicatedStorage.Packages.React)
local Theme = require(script.Parent.Parent.Theme)
local Style = require(script.Parent.Style)

local e = React.createElement

local colors = Theme.colors
local fonts = Theme.fonts
local layout = Style.layout

-- One block in a sheet's body, with its height in unscaled pixels.
export type Section = { key: string, height: number, element: any }

export type ButtonStyle = "primary" | "secondary"

-- One footer button.
export type Action = {
	key: string,
	label: string,
	style: ButtonStyle,
	disabled: boolean,
	onTap: () -> (),
}

-- What a sheet shows: the header, the blocks of the body and the footer buttons. `main` scrolls; `summary`
-- (price, notes) follows it in one column, or sits in the right column next to it on a wide card.
export type Content = {
	eyebrow: string,
	title: string,
	subtitle: string?,
	main: { Section },
	summary: { Section },
	actions: { Action },
}

export type Tone = "normal" | "dim" | "warning"

-- The shop call in flight, if any (ShopController). Every action button is off while one runs.
export type Busy = "buy" | "upgrade" | "testDrive" | "buyUsed" | "claim" | "loadLot"

-- A confirm dialog: a question, a few label/value rows (price, cash, cash after) and two buttons.
export type ConfirmRow = { label: string, value: string, tone: Tone? }
export type Confirm = {
	title: string,
	rows: { ConfirmRow },
	confirmLabel: string,
	busyLabel: string,
	busy: boolean, -- the call is in flight: both buttons are off
	onConfirm: () -> (),
	onCancel: () -> (),
}

local Primitives = {}

local function toneColor(tone: Tone?): Color3
	if tone == "warning" then
		return colors.warning
	elseif tone == "dim" then
		return colors.textDim
	end
	return colors.text
end
Primitives.toneColor = toneColor

local function corner(radius: number): any
	return e("UICorner", { CornerRadius = UDim.new(0, radius) })
end
Primitives.corner = corner

-- Animation ---------------------------------------------------------------------------------------------------

-- A binding that runs from 0 to 1 over Theme.motion.sheetSeconds when the component mounts: the open slide and
-- fade. A short TweenService tween on a NumberValue drives it (no per-frame code of ours).
function Primitives.useAppear(): any
	local appear, setAppear = React.useBinding(0)
	React.useEffect(function()
		local value = Instance.new("NumberValue")
		value.Value = 0
		local connection = value.Changed:Connect(function(current: number)
			setAppear(current)
		end)
		local tween = TweenService:Create(
			value,
			TweenInfo.new(Theme.motion.sheetSeconds, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ Value = 1 }
		)
		tween:Play()
		return function()
			tween:Cancel()
			connection:Disconnect()
			value:Destroy()
		end
	end, {})
	return appear
end

-- Text ---------------------------------------------------------------------------------------------------------

export type LabelProps = {
	text: string,
	height: number,
	textSize: number?,
	font: Font?,
	color: Color3?,
	align: Enum.TextXAlignment?,
	yAlign: Enum.TextYAlignment?, -- default: centered on one line, top when wrapped
	wrapped: boolean?,
	order: number?,
	position: UDim2?,
	width: UDim?,
}

-- One block of text, full width by default, a fixed height, truncated at the end unless it wraps.
function Primitives.Label(props: LabelProps)
	local width = props.width or UDim.new(1, 0)
	return e("TextLabel", {
		LayoutOrder = props.order or 0,
		Position = props.position,
		Size = UDim2.new(width.Scale, width.Offset, 0, props.height),
		BackgroundTransparency = 1,
		FontFace = props.font or fonts.regular,
		Text = props.text,
		TextColor3 = props.color or colors.text,
		TextSize = props.textSize or Theme.text.body,
		TextWrapped = props.wrapped == true,
		TextTruncate = if props.wrapped then Enum.TextTruncate.None else Enum.TextTruncate.AtEnd,
		TextXAlignment = props.align or Enum.TextXAlignment.Left,
		TextYAlignment = props.yAlign
			or (if props.wrapped then Enum.TextYAlignment.Top else Enum.TextYAlignment.Center),
	})
end

-- Buttons ------------------------------------------------------------------------------------------------------

export type ButtonProps = {
	label: string,
	style: ButtonStyle?,
	disabled: boolean?,
	size: UDim2,
	position: UDim2?,
	anchor: Vector2?,
	order: number?,
	onTap: (() -> ())?,
	buttonRef: any?, -- a React ref to the TextButton (the sheet selects it for gamepad players)
}

-- A rounded text button. Primary is filled with the accent (one per screen at most); secondary is a raised
-- panel. Disabled buttons go flat and dim and ignore taps. A pressed button shrinks a touch
-- (Theme.motion.pressScale).
function Primitives.Button(props: ButtonProps)
	local pressed, setPressed = React.useState(false)
	local disabled = props.disabled == true
	local primary = props.style == "primary"

	local fill = if disabled then colors.panelRaised elseif primary then colors.accent else colors.panelRaised
	local textColor = if disabled then colors.textDim elseif primary then colors.onAccent else colors.text

	return e("TextButton", {
		ref = props.buttonRef,
		LayoutOrder = props.order or 0,
		AnchorPoint = props.anchor,
		Position = props.position,
		Size = props.size,
		BackgroundColor3 = fill,
		BorderSizePixel = 0,
		AutoButtonColor = not disabled,
		Active = not disabled,
		Selectable = not disabled,
		FontFace = fonts.bold,
		Text = props.label,
		TextColor3 = textColor,
		TextSize = Theme.text.body,
		TextTruncate = Enum.TextTruncate.AtEnd,
		[React.Event.Activated] = function()
			local onTap = props.onTap
			if not disabled and onTap ~= nil then
				onTap()
			end
		end,
		[React.Event.MouseButton1Down] = function()
			if not disabled then
				setPressed(true)
			end
		end,
		[React.Event.MouseButton1Up] = function()
			setPressed(false)
		end,
		[React.Event.MouseLeave] = function()
			setPressed(false)
		end,
	}, {
		Corner = corner(Theme.radius.button),
		Scale = e("UIScale", { Scale = if pressed and not disabled then Theme.motion.pressScale else 1 }),
		Padding = e("UIPadding", {
			PaddingLeft = UDim.new(0, Theme.spacing.sm),
			PaddingRight = UDim.new(0, Theme.spacing.sm),
		}),
	})
end

-- The round close button with an X drawn from two bars (no image asset needed).
function Primitives.CloseButton(props: { position: UDim2, anchor: Vector2, onTap: () -> () })
	local size = layout.closeSize
	local length = layout.closeGlyph * math.sqrt(2)

	local function bar(rotation: number)
		return e("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromOffset(layout.closeStroke, length),
			Rotation = rotation,
			BackgroundColor3 = colors.text,
			BorderSizePixel = 0,
			Active = false,
		}, {
			Corner = e("UICorner", { CornerRadius = UDim.new(0.5, 0) }),
		})
	end

	return e("TextButton", {
		AnchorPoint = props.anchor,
		Position = props.position,
		Size = UDim2.fromOffset(size, size),
		BackgroundColor3 = colors.panelRaised,
		BorderSizePixel = 0,
		AutoButtonColor = true,
		Text = "",
		[React.Event.Activated] = function()
			props.onTap()
		end,
	}, {
		Corner = corner(Theme.radius.pill),
		Forward = bar(45),
		Back = bar(-45),
	})
end

-- Trim chips ---------------------------------------------------------------------------------------------------

export type Chip = { id: string, label: string, selected: boolean }

function Primitives.chipsHeight(): number
	return layout.chipHeight + layout.chipScrollBar + Theme.spacing.xs
end

-- One row of trim chips that scrolls sideways when they don't fit. The selected chip is filled with the accent.
function Primitives.TrimChips(props: { chips: { Chip }, disabled: boolean, onPick: (id: string) -> () })
	local children: { [string]: any } = {
		Layout = e("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			VerticalAlignment = Enum.VerticalAlignment.Top,
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, layout.chipGap),
		}),
	}
	for index, chip in props.chips do
		local selected = chip.selected
		children[`Chip_{chip.id}`] = e("TextButton", {
			LayoutOrder = index,
			Size = UDim2.fromOffset(0, layout.chipHeight),
			AutomaticSize = Enum.AutomaticSize.X,
			BackgroundColor3 = if selected then colors.accent else colors.panelRaised,
			BorderSizePixel = 0,
			AutoButtonColor = not selected and not props.disabled,
			FontFace = if selected then fonts.bold else fonts.medium,
			Text = chip.label,
			TextColor3 = if selected then colors.onAccent else colors.text,
			TextSize = Theme.text.body,
			[React.Event.Activated] = function()
				if not props.disabled and not selected then
					props.onPick(chip.id)
				end
			end,
		}, {
			Corner = corner(Theme.radius.pill),
			Padding = e("UIPadding", {
				PaddingLeft = UDim.new(0, layout.chipPadding),
				PaddingRight = UDim.new(0, layout.chipPadding),
			}),
			Limits = e("UISizeConstraint", {
				MinSize = Vector2.new(Theme.size.touchTarget, layout.chipHeight),
			}),
		})
	end

	return e("ScrollingFrame", {
		Size = UDim2.new(1, 0, 0, Primitives.chipsHeight()),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.X,
		ScrollingDirection = Enum.ScrollingDirection.X,
		ScrollBarThickness = layout.chipScrollBar,
		ScrollBarImageColor3 = colors.textDim,
		VerticalScrollBarInset = Enum.ScrollBarInset.None,
	}, children)
end

-- Stat bars ----------------------------------------------------------------------------------------------------

export type StatRow = { id: string, label: string, value: string, fraction: number }

local function statRowHeight(): number
	return layout.statLabelHeight + layout.statBarGap + Theme.size.statBarHeight
end

function Primitives.statListHeight(count: number): number
	if count <= 0 then
		return 0
	end
	return count * statRowHeight() + (count - 1) * layout.statGap
end

-- Each stat: its name on the left, the value on the right and an accent bar under them, filled by `fraction`.
function Primitives.StatList(props: { rows: { StatRow } })
	local children: { [string]: any } = {
		Layout = e("UIListLayout", {
			FillDirection = Enum.FillDirection.Vertical,
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, layout.statGap),
		}),
	}
	for index, row in props.rows do
		children[`Stat_{row.id}`] = e("Frame", {
			LayoutOrder = index,
			Size = UDim2.new(1, 0, 0, statRowHeight()),
			BackgroundTransparency = 1,
		}, {
			Name = e(Primitives.Label, {
				text = row.label,
				height = layout.statLabelHeight,
				textSize = Theme.text.small,
				font = fonts.medium,
				color = colors.textDim,
				width = UDim.new(0.6, 0),
			}),
			Value = e(Primitives.Label, {
				text = row.value,
				height = layout.statLabelHeight,
				textSize = Theme.text.small,
				font = fonts.bold,
				align = Enum.TextXAlignment.Right,
				position = UDim2.fromScale(0.4, 0),
				width = UDim.new(0.6, 0),
			}),
			Track = e("Frame", {
				Position = UDim2.fromOffset(0, layout.statLabelHeight + layout.statBarGap),
				Size = UDim2.new(1, 0, 0, Theme.size.statBarHeight),
				BackgroundColor3 = colors.track,
				BorderSizePixel = 0,
			}, {
				Corner = corner(Theme.radius.pill),
				Fill = e("Frame", {
					Size = UDim2.fromScale(math.clamp(row.fraction, 0, 1), 1),
					BackgroundColor3 = colors.accent,
					BackgroundTransparency = if row.fraction > 0 then 0 else 1,
					BorderSizePixel = 0,
				}, {
					Corner = corner(Theme.radius.pill),
				}),
			}),
		})
	end
	return e("Frame", {
		Size = UDim2.new(1, 0, 0, Primitives.statListHeight(#props.rows)),
		BackgroundTransparency = 1,
	}, children)
end

-- Price block --------------------------------------------------------------------------------------------------

function Primitives.priceBlockHeight(): number
	return layout.priceLabelHeight + layout.priceGap + layout.priceHeight + layout.priceGap + layout.priceStatusHeight
end

-- A small label ("Price"), the price in large type, and one status line under it (cash after, cash needed,
-- stock left), colored by its tone.
function Primitives.PriceBlock(props: { label: string, price: string, status: string?, statusTone: Tone? })
	local status = props.status
	return e("Frame", {
		Size = UDim2.new(1, 0, 0, Primitives.priceBlockHeight()),
		BackgroundTransparency = 1,
	}, {
		Layout = e("UIListLayout", {
			FillDirection = Enum.FillDirection.Vertical,
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, layout.priceGap),
		}),
		Label = e(Primitives.Label, {
			order = 1,
			text = props.label,
			height = layout.priceLabelHeight,
			textSize = Theme.text.small,
			font = fonts.medium,
			color = colors.textDim,
		}),
		Price = e(Primitives.Label, {
			order = 2,
			text = props.price,
			height = layout.priceHeight,
			textSize = Theme.text.price,
			font = fonts.bold,
		}),
		Status = if status
			then e(Primitives.Label, {
				order = 3,
				text = status,
				height = layout.priceStatusHeight,
				textSize = Theme.text.small,
				font = fonts.medium,
				color = toneColor(props.statusTone or "dim"),
			})
			else nil,
	})
end

-- Note card ----------------------------------------------------------------------------------------------------

function Primitives.noteHeight(): number
	return 2 * layout.notePadding + layout.noteLines * layout.noteLineHeight
end

-- A short explanation in a raised card: where to get a trim, why Buy is off.
function Primitives.Note(props: { text: string, tone: Tone? })
	return e("Frame", {
		Size = UDim2.new(1, 0, 0, Primitives.noteHeight()),
		BackgroundColor3 = colors.panelRaised,
		BorderSizePixel = 0,
	}, {
		Corner = corner(Theme.radius.card),
		Padding = e("UIPadding", {
			PaddingLeft = UDim.new(0, layout.notePadding),
			PaddingRight = UDim.new(0, layout.notePadding),
			PaddingTop = UDim.new(0, layout.notePadding),
			PaddingBottom = UDim.new(0, layout.notePadding),
		}),
		Text = e(Primitives.Label, {
			text = props.text,
			height = layout.noteLines * layout.noteLineHeight,
			textSize = Theme.text.small,
			font = fonts.medium,
			color = toneColor(props.tone),
			wrapped = true,
		}),
	})
end

-- Robotaxi fleet card (Phase 9) ---------------------------------------------------------------------------------

function Primitives.fleetCardHeight(): number
	return 2 * layout.fleetCardPadding
		+ layout.fleetCardTitleHeight
		+ layout.fleetCardGap
		+ layout.fleetCardLines * layout.noteLineHeight
		+ layout.fleetCardGap
		+ layout.buttonHeight
end

export type FleetCardProps = {
	title: string,
	text: string,
	label: string, -- the button
	disabled: boolean,
	onTap: () -> (),
}

-- On the fleet brand's dealership sheets: a title, a short line about the robotaxi fleet, and a button that opens
-- the phone's Fleet app. Outlined rather than raised, so the raised (secondary) button stands out inside it.
function Primitives.FleetCard(props: FleetCardProps)
	local pad = UDim.new(0, layout.fleetCardPadding)
	return e("Frame", {
		Size = UDim2.new(1, 0, 0, Primitives.fleetCardHeight()),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
	}, {
		Corner = corner(Theme.radius.card),
		Outline = e("UIStroke", {
			ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
			Color = colors.divider,
			Thickness = 1,
		}),
		Padding = e("UIPadding", { PaddingLeft = pad, PaddingRight = pad, PaddingTop = pad, PaddingBottom = pad }),
		Layout = e("UIListLayout", {
			FillDirection = Enum.FillDirection.Vertical,
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, layout.fleetCardGap),
		}),
		Title = e(Primitives.Label, {
			order = 1,
			text = props.title,
			height = layout.fleetCardTitleHeight,
			font = fonts.bold,
		}),
		Text = e(Primitives.Label, {
			order = 2,
			text = props.text,
			height = layout.fleetCardLines * layout.noteLineHeight,
			textSize = Theme.text.small,
			color = colors.textDim,
			wrapped = true,
		}),
		Button = e(Primitives.Button, {
			order = 3,
			label = props.label,
			style = "secondary",
			disabled = props.disabled,
			size = UDim2.new(1, 0, 0, layout.buttonHeight),
			onTap = props.onTap,
		}),
	})
end

function Primitives.fleetCardSection(key: string, props: FleetCardProps): Section
	return { key = key, height = Primitives.fleetCardHeight(), element = e(Primitives.FleetCard, props) }
end

-- Small sections -----------------------------------------------------------------------------------------------

-- A one-line dim detail ("Sedan · RWD · Electric") as a body section.
function Primitives.specSection(key: string, text: string): Section
	return {
		key = key,
		height = layout.specLineHeight,
		element = e(Primitives.Label, {
			text = text,
			height = layout.specLineHeight,
			textSize = Theme.text.small,
			font = fonts.medium,
			color = colors.textDim,
		}),
	}
end

-- Dim small print that may wrap onto two lines ("Test drives last 2 min and don't earn cash.").
function Primitives.finePrintSection(key: string, text: string): Section
	local height = 2 * layout.finePrintHeight
	return {
		key = key,
		height = height,
		element = e(Primitives.Label, {
			text = text,
			height = height,
			textSize = Theme.text.small,
			color = colors.textDim,
			wrapped = true,
		}),
	}
end

-- A centered message in the body (loading, nothing here, couldn't load). `height` lets a loading message hold
-- the space the loaded content will take, so the sheet doesn't jump when it arrives.
function Primitives.statusSection(key: string, text: string, tone: Tone?, height: number?): Section
	local size = height or layout.statusHeight
	return {
		key = key,
		height = size,
		element = e(Primitives.Label, {
			text = text,
			height = size,
			font = fonts.medium,
			color = toneColor(tone or "dim"),
			align = Enum.TextXAlignment.Center,
			yAlign = Enum.TextYAlignment.Center,
			wrapped = true,
		}),
	}
end

function Primitives.noteSection(key: string, text: string, tone: Tone?): Section
	return { key = key, height = Primitives.noteHeight(), element = e(Primitives.Note, { text = text, tone = tone }) }
end

return Primitives
