--!strict
-- The body of the Wrap & Tint panel: whatever the chosen tab offers (docs/phase-7-contracts.md "Client").
-- CustomizeModel.tabView describes it; this module only draws it, top to bottom:
--
--   detail     one line naming the chosen swatch and its price ("Pearl White · $1,500"), above a swatch grid
--   swatches   rounded color squares (paint, calipers): the chosen one ringed in the accent, the car's current
--              one marked with a dot; on the Paint tab a last "custom color" square shows the custom color
--   steppers   - [label, value and bar] + rows: the custom color's hue, saturation and brightness, or the ride
--              height
--   cards      name-over-price cards, two or three across (finish, wrap, wheels, tint, extras, plate styles);
--              the chosen ones filled with the accent
--   note       a short hint or an empty message in a raised card
--   plate      the custom plate text box and its Set button, or a note saying what unlocks it
--
-- Presentation only: every tap goes back through the callbacks to CustomizationController, which owns the state.
-- Every tappable thing is at least Theme.size.touchTarget in both directions.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local React = require(ReplicatedStorage.Packages.React)
local Theme = require(script.Parent.Parent.Theme)
local Primitives = require(script.Parent.Parent.Shop.Primitives)
local CustomizeModel = require(script.Parent.CustomizeModel)
local Style = require(script.Parent.Style)

local e = React.createElement

local colors = Theme.colors
local fonts = Theme.fonts
local layout = Style.layout
local copy = Style.copy

export type Props = {
	view: CustomizeModel.TabView,
	columns: number, -- cards across (CustomizeModel.panelLayout)
	busy: boolean, -- a call is in flight: choices stay tappable (they only change the preview), Set plate is off
	onPick: (key: string) -> (),
	onStep: (key: string, direction: number) -> (),
	onPlate: (text: string) -> (),
}

local Options = {}

local function corner(radius: number): any
	return e("UICorner", { CornerRadius = UDim.new(0, radius) })
end

-- A frame as tall as its children, stacked or in a grid, for the body's list layout.
local function autoFrame(order: number, children: { [string]: any }): any
	return e("Frame", {
		LayoutOrder = order,
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
	}, children)
end

-- Swatches -----------------------------------------------------------------------------------------------------

-- One color square. The chosen one has an accent ring; the car's current color carries a small dot. The custom
-- square shows a rainbow until a custom color has been picked.
local function Swatch(props: { choice: CustomizeModel.Choice, order: number, rainbow: boolean?, onPick: () -> () })
	local choice = props.choice
	local stroke = if choice.selected
		then e("UIStroke", {
			ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
			Color = colors.accent,
			Thickness = layout.swatchRing,
		})
		else e("UIStroke", {
			ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
			Color = colors.divider,
			Thickness = 1,
		})
	local dot = layout.swatchSavedDot
	local rainbow = Style.rainbow
	local function hue(at: number): ColorSequenceKeypoint
		return ColorSequenceKeypoint.new(at, Color3.fromHSV(at, rainbow.saturation, rainbow.value))
	end
	return e("TextButton", {
		LayoutOrder = props.order,
		-- A gradient tints the fill, so the rainbow needs a white one under it.
		BackgroundColor3 = if props.rainbow then Color3.new(1, 1, 1) else choice.color or colors.panelRaised,
		BorderSizePixel = 0,
		AutoButtonColor = false,
		Text = "",
		[React.Event.Activated] = function()
			props.onPick()
		end,
	}, {
		Corner = corner(Theme.radius.button),
		Ring = stroke,
		Rainbow = if props.rainbow
			then e("UIGradient", {
				-- Red, green, blue and back to red across the square (the fill under it is white).
				Color = ColorSequence.new({ hue(0), hue(1 / 3), hue(2 / 3), hue(1) }),
			})
			else nil,
		Saved = if choice.saved
			then e("Frame", {
				AnchorPoint = Vector2.new(1, 1),
				Position = UDim2.new(1, -layout.swatchRing - 1, 1, -layout.swatchRing - 1),
				Size = UDim2.fromOffset(dot, dot),
				BackgroundColor3 = colors.text,
				BorderSizePixel = 0,
			}, {
				Corner = e("UICorner", { CornerRadius = UDim.new(0.5, 0) }),
				Edge = e("UIStroke", { Color = colors.panel, Thickness = 1 }),
			})
			else nil,
	})
end

local function SwatchGrid(props: {
	order: number,
	swatches: { CustomizeModel.Choice },
	custom: CustomizeModel.Choice?,
	onPick: (key: string) -> (),
})
	local size = layout.swatchSize
	local children: { [string]: any } = {
		Grid = e("UIGridLayout", {
			CellSize = UDim2.fromOffset(size, size),
			CellPadding = UDim2.fromOffset(layout.swatchGap, layout.swatchGap),
			FillDirection = Enum.FillDirection.Horizontal,
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
		-- Room for the chosen swatch's ring on the outer edges.
		Padding = e("UIPadding", {
			PaddingLeft = UDim.new(0, layout.swatchRing),
			PaddingTop = UDim.new(0, layout.swatchRing),
			PaddingBottom = UDim.new(0, layout.swatchRing),
		}),
	}
	for index, choice in props.swatches do
		children[`Swatch_{choice.key}`] = e(Swatch, {
			choice = choice,
			order = index,
			onPick = function()
				props.onPick(choice.key)
			end,
		})
	end
	local custom = props.custom
	if custom ~= nil then
		children.Custom = e(Swatch, {
			choice = custom,
			order = #props.swatches + 1,
			rainbow = custom.color == nil,
			onPick = function()
				props.onPick(custom.key)
			end,
		})
	end
	return autoFrame(props.order, children)
end

-- Steppers -----------------------------------------------------------------------------------------------------

local function StepButton(
	props: { label: string, disabled: boolean, anchor: Vector2?, position: UDim2?, onTap: () -> () }
)
	return e(Primitives.Button, {
		label = props.label,
		style = "secondary",
		disabled = props.disabled,
		anchor = props.anchor,
		position = props.position,
		size = UDim2.fromOffset(layout.stepperButton, layout.stepperHeight),
		onTap = props.onTap,
	})
end

-- "Hue" ... "120°" over a bar, between - and + buttons. The bar shows the value's place in its range; a custom
-- color's bar is drawn in that color.
local function Stepper(props: { stepper: CustomizeModel.Stepper, order: number, onStep: (direction: number) -> () })
	local stepper = props.stepper
	local inset = layout.stepperButton + layout.stepperGap * 2
	local barTop = layout.stepperLabelHeight + layout.stepperGap
	return e("Frame", {
		LayoutOrder = props.order,
		Size = UDim2.new(1, 0, 0, layout.stepperHeight),
		BackgroundTransparency = 1,
	}, {
		Down = e(StepButton, {
			label = copy.down,
			disabled = not stepper.canDown,
			onTap = function()
				props.onStep(-1)
			end,
		}),
		-- The label, value and bar, centered between the buttons.
		Middle = e("Frame", {
			AnchorPoint = Vector2.new(0, 0.5),
			Position = UDim2.new(0, inset, 0.5, 0),
			Size = UDim2.new(1, -2 * inset, 0, barTop + layout.stepperBarHeight),
			BackgroundTransparency = 1,
		}, {
			Label = e(Primitives.Label, {
				text = stepper.label,
				height = layout.stepperLabelHeight,
				textSize = Theme.text.small,
				font = fonts.medium,
				color = colors.textDim,
				width = UDim.new(0.5, 0),
			}),
			Value = e(Primitives.Label, {
				text = stepper.valueText,
				height = layout.stepperLabelHeight,
				textSize = Theme.text.small,
				font = fonts.bold,
				align = Enum.TextXAlignment.Right,
				position = UDim2.fromScale(0.3, 0),
				width = UDim.new(0.7, 0),
			}),
			Track = e("Frame", {
				Position = UDim2.fromOffset(0, barTop),
				Size = UDim2.new(1, 0, 0, layout.stepperBarHeight),
				BackgroundColor3 = colors.track,
				BorderSizePixel = 0,
			}, {
				Corner = e("UICorner", { CornerRadius = UDim.new(0.5, 0) }),
				Fill = e("Frame", {
					Size = UDim2.fromScale(math.clamp(stepper.fraction, 0, 1), 1),
					BackgroundColor3 = stepper.color or colors.accent,
					BackgroundTransparency = if stepper.fraction > 0 then 0 else 1,
					BorderSizePixel = 0,
				}, {
					Corner = e("UICorner", { CornerRadius = UDim.new(0.5, 0) }),
				}),
			}),
		}),
		Up = e(StepButton, {
			label = copy.up,
			disabled = not stepper.canUp,
			anchor = Vector2.new(1, 0),
			position = UDim2.fromScale(1, 0),
			onTap = function()
				props.onStep(1)
			end,
		}),
	})
end

local function StepperList(props: {
	order: number,
	steppers: { CustomizeModel.Stepper },
	onStep: (key: string, direction: number) -> (),
})
	local children: { [string]: any } = {
		Layout = e("UIListLayout", {
			FillDirection = Enum.FillDirection.Vertical,
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, layout.sectionGap),
		}),
	}
	for index, stepper in props.steppers do
		children[`Stepper_{stepper.key}`] = e(Stepper, {
			stepper = stepper,
			order = index,
			onStep = function(direction: number)
				props.onStep(stepper.key, direction)
			end,
		})
	end
	return autoFrame(props.order, children)
end

-- Cards --------------------------------------------------------------------------------------------------------

-- A name over its price. Chosen cards are filled with the accent (on the Extras tab, every extra that is on).
local function Card(props: { choice: CustomizeModel.Choice, order: number, onPick: () -> () })
	local choice = props.choice
	local selected = choice.selected
	local disabled = choice.disabled == true
	local textColor = if disabled then colors.textDim elseif selected then colors.onAccent else colors.text
	local priceColor = if disabled then colors.textDim elseif selected then colors.onAccent else colors.textDim
	return e("TextButton", {
		LayoutOrder = props.order,
		BackgroundColor3 = if selected then colors.accent else colors.panelRaised,
		BorderSizePixel = 0,
		AutoButtonColor = not disabled,
		Active = not disabled,
		Text = "",
		[React.Event.Activated] = function()
			if not disabled then
				props.onPick()
			end
		end,
	}, {
		Corner = corner(Theme.radius.button),
		Padding = e("UIPadding", {
			PaddingLeft = UDim.new(0, layout.cardPadding),
			PaddingRight = UDim.new(0, layout.cardPadding),
		}),
		Text = e("Frame", {
			AnchorPoint = Vector2.new(0, 0.5),
			Position = UDim2.fromScale(0, 0.5),
			Size = UDim2.new(1, 0, 0, layout.cardNameHeight + layout.cardPriceHeight),
			BackgroundTransparency = 1,
		}, {
			Name = e(Primitives.Label, {
				text = choice.label,
				height = layout.cardNameHeight,
				font = if selected then fonts.bold else fonts.medium,
				color = textColor,
			}),
			Price = e(Primitives.Label, {
				text = choice.priceText,
				height = layout.cardPriceHeight,
				textSize = Theme.text.small,
				font = fonts.medium,
				color = priceColor,
				position = UDim2.fromOffset(0, layout.cardNameHeight),
			}),
		}),
	})
end

local function CardGrid(props: {
	order: number,
	cards: { CustomizeModel.Choice },
	columns: number,
	onPick: (key: string) -> (),
})
	local columns = math.max(props.columns, 1)
	local gap = layout.cardGap
	local children: { [string]: any } = {
		Grid = e("UIGridLayout", {
			CellSize = UDim2.new(1 / columns, -gap * (columns - 1) / columns, 0, layout.cardHeight),
			CellPadding = UDim2.fromOffset(gap, gap),
			FillDirection = Enum.FillDirection.Horizontal,
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
	}
	for index, choice in props.cards do
		children[`Card_{choice.key}`] = e(Card, {
			choice = choice,
			order = index,
			onPick = function()
				props.onPick(choice.key)
			end,
		})
	end
	return autoFrame(props.order, children)
end

-- Notes and the plate editor -----------------------------------------------------------------------------------

local function noteHeight(): number
	return 2 * layout.notePadding + layout.noteLines * layout.noteLineHeight
end

local function Note(props: { text: string, order: number })
	return e("Frame", {
		LayoutOrder = props.order,
		Size = UDim2.new(1, 0, 0, noteHeight()),
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
			color = colors.textDim,
			wrapped = true,
		}),
	})
end

local function Heading(props: { text: string, order: number })
	return e(Primitives.Label, {
		order = props.order,
		text = props.text,
		height = layout.detailHeight,
		font = fonts.bold,
	})
end

-- The custom plate text: a box that keeps only what a plate may show (CustomizeModel.cleanPlate, as you type)
-- and a Set button (Enter in the box works too). The server filters the text before anyone sees it.
local function PlateEditor(props: { plate: CustomizeModel.PlateView, order: number, onSubmit: (text: string) -> () })
	local plate = props.plate
	local box = React.useRef(nil :: TextBox?)
	local buttonWidth = layout.plateButtonWidth

	local function submit()
		local current = box.current
		if current ~= nil and not plate.busy then
			props.onSubmit(current.Text)
		end
	end

	-- Upper case, only what a plate allows, cut to its length: typing never shows anything else.
	local function onTextChanged(rbx: TextBox)
		local clean = CustomizeModel.cleanPlate(rbx.Text, plate.maxLength, false)
		if clean ~= rbx.Text then
			rbx.Text = clean
		end
	end

	local function onFocusLost(_rbx: TextBox, enterPressed: boolean)
		if enterPressed then
			submit()
		end
	end

	return autoFrame(props.order, {
		Layout = e("UIListLayout", {
			FillDirection = Enum.FillDirection.Vertical,
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, layout.sectionGap),
		}),
		Heading = e(Heading, { text = copy.plateText, order = 1 }),
		Row = e("Frame", {
			LayoutOrder = 2,
			Size = UDim2.new(1, 0, 0, layout.inputHeight),
			BackgroundTransparency = 1,
		}, {
			Input = e("TextBox", {
				Size = UDim2.new(1, -(buttonWidth + layout.actionGap), 1, 0),
				BackgroundColor3 = colors.panelRaised,
				BorderSizePixel = 0,
				ClearTextOnFocus = false,
				TextEditable = not plate.busy,
				FontFace = fonts.bold,
				PlaceholderText = copy.platePlaceholder,
				PlaceholderColor3 = colors.textDim,
				Text = "",
				TextColor3 = colors.text,
				TextSize = Theme.text.heading,
				TextTruncate = Enum.TextTruncate.AtEnd,
				TextXAlignment = Enum.TextXAlignment.Left,
				ref = box,
				-- Cast: one props table can't type two handlers of different shapes.
				[React.Change.Text] = onTextChanged :: any,
				[React.Event.FocusLost] = onFocusLost :: any,
			}, {
				Corner = corner(Theme.radius.button),
				Padding = e("UIPadding", {
					PaddingLeft = UDim.new(0, Theme.spacing.md),
					PaddingRight = UDim.new(0, Theme.spacing.md),
				}),
			}),
			Set = e(Primitives.Button, {
				label = if plate.busy then copy.settingPlate else copy.setPlate,
				style = "secondary",
				disabled = plate.busy,
				anchor = Vector2.new(1, 0),
				position = UDim2.fromScale(1, 0),
				size = UDim2.new(0, buttonWidth, 1, 0),
				onTap = submit,
			}),
		}),
		Rules = e(Primitives.Label, {
			order = 3,
			text = plate.rules,
			height = layout.plateRulesLines * layout.noteLineHeight,
			textSize = Theme.text.small,
			color = colors.textDim,
			wrapped = true,
		}),
	})
end

-- The body ------------------------------------------------------------------------------------------------------

-- Everything the tab offers, in a scrolling column that fills its parent.
function Options.Body(props: Props)
	local view = props.view
	local children: { [string]: any } = {
		Layout = e("UIListLayout", {
			FillDirection = Enum.FillDirection.Vertical,
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, layout.sectionGap),
		}),
		Padding = e("UIPadding", {
			PaddingLeft = UDim.new(0, layout.pad),
			PaddingRight = UDim.new(0, layout.pad),
			PaddingBottom = UDim.new(0, layout.pad),
		}),
	}

	local detail = view.detail
	if detail ~= nil then
		children.Detail = e(Primitives.Label, {
			order = 1,
			text = detail,
			height = layout.detailHeight,
			font = fonts.bold,
		})
	end
	local swatches = view.swatches
	if swatches ~= nil then
		children.Swatches = e(SwatchGrid, {
			order = 2,
			swatches = swatches,
			custom = view.customSwatch,
			onPick = props.onPick,
		})
	end
	local steppers = view.steppers
	if steppers ~= nil and #steppers > 0 then
		children.Steppers = e(StepperList, { order = 3, steppers = steppers, onStep = props.onStep })
	end
	local cardsHeading = view.cardsHeading
	if cardsHeading ~= nil then
		children.CardsHeading = e(Heading, { text = cardsHeading, order = 4 })
	end
	local cards = view.cards
	if cards ~= nil and #cards > 0 then
		children.Cards = e(CardGrid, { order = 5, cards = cards, columns = props.columns, onPick = props.onPick })
	end
	local note = view.note
	if note ~= nil then
		children.Note = e(Note, { text = note, order = 6 })
	end
	local plate = view.plate
	if plate ~= nil then
		if plate.allowed then
			children.Plate = e(PlateEditor, { plate = plate, order = 7, onSubmit = props.onPlate })
		else
			children.PlateLocked = e(Note, { text = plate.lockedNote, order = 7 })
		end
	end

	return e("ScrollingFrame", {
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		ScrollBarThickness = layout.scrollBar,
		ScrollBarImageColor3 = colors.textDim,
		Selectable = false,
	}, children)
end

return Options
