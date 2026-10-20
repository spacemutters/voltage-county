--!strict
-- The building blocks every phone screen is made of, in the one look from UI/Theme: text, buttons, cards,
-- section titles, pills, a segmented picker, a slider with - and + buttons, a chevron and a scrolling page.
-- Presentation only; every tappable thing is at least Theme.size.touchTarget in both directions.

local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local React = require(ReplicatedStorage.Packages.React)

local Glyph = require(script.Parent.Glyphs)
local PhoneConfig = require(script.Parent.PhoneConfig)
local Theme = require(script.Parent.Parent.Theme)

local e = React.createElement
local colors = Theme.colors

export type ButtonStyle = "primary" | "secondary" | "danger" | "dangerText"

export type Option = { id: string, label: string }

local Kit = {}

local function isPress(input: InputObject): boolean
	return input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1
end

-- Text -------------------------------------------------------------------------------------------------------

-- A label as tall as its (wrapped) text, for stacking in a list layout.
function Kit.Text(
	props: {
		text: string,
		order: number?,
		size: number?, -- default Theme.text.body
		font: Font?, -- default Theme.fonts.regular
		color: Color3?, -- default Theme.colors.text
		align: Enum.TextXAlignment?,
		richText: boolean?,
	}
)
	return e("TextLabel", {
		LayoutOrder = props.order or 0,
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		FontFace = props.font or Theme.fonts.regular,
		RichText = props.richText == true,
		Text = props.text,
		TextColor3 = props.color or colors.text,
		TextSize = props.size or Theme.text.body,
		TextWrapped = true,
		TextXAlignment = props.align or Enum.TextXAlignment.Left,
	})
end

-- A small dim heading above a group of rows or cards.
function Kit.SectionTitle(props: { text: string, order: number? })
	return e("TextLabel", {
		LayoutOrder = props.order or 0,
		Size = UDim2.new(1, 0, 0, PhoneConfig.list.sectionHeight),
		BackgroundTransparency = 1,
		FontFace = Theme.fonts.medium,
		Text = props.text,
		TextColor3 = colors.textDim,
		TextSize = Theme.text.small,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Bottom,
	}, {
		Padding = e("UIPadding", { PaddingBottom = UDim.new(0, Theme.spacing.xs) }),
	})
end

-- Buttons ----------------------------------------------------------------------------------------------------

local function buttonColors(style: ButtonStyle, disabled: boolean): (Color3, Color3)
	if disabled then
		return colors.panelRaised, colors.textDim
	elseif style == "primary" then
		return colors.accent, colors.onAccent
	elseif style == "danger" then
		return colors.danger, colors.onAccent
	elseif style == "dangerText" then
		return colors.panelRaised, colors.danger
	end
	return colors.panelRaised, colors.text
end

-- A rounded button that shrinks a little while pressed. A disabled button keeps its place but does nothing.
function Kit.Button(
	props: {
		label: string,
		onTap: () -> (),
		style: ButtonStyle?,
		disabled: boolean?,
		order: number?,
		size: UDim2?, -- default: full width, Theme.size.buttonHeight tall
		anchor: Vector2?,
		position: UDim2?,
		textSize: number?,
		buttonRef: any?, -- a React ref, for gamepad focus
	}
)
	local pressed, setPressed = React.useBinding(false)
	local disabled = props.disabled == true
	local fill, textColor = buttonColors(props.style or "secondary", disabled)
	local onInputBegan: any = function(_rbx: GuiObject, input: InputObject)
		if isPress(input) and not disabled then
			setPressed(true)
		end
	end
	local onInputEnded: any = function(_rbx: GuiObject, input: InputObject)
		if isPress(input) then
			setPressed(false)
		end
	end
	return e("TextButton", {
		LayoutOrder = props.order or 0,
		AnchorPoint = props.anchor,
		Position = props.position,
		Size = props.size or UDim2.new(1, 0, 0, Theme.size.buttonHeight),
		BackgroundColor3 = fill,
		BorderSizePixel = 0,
		AutoButtonColor = not disabled,
		Selectable = not disabled,
		FontFace = Theme.fonts.bold,
		Text = props.label,
		TextColor3 = textColor,
		TextSize = props.textSize or Theme.text.body,
		TextTruncate = Enum.TextTruncate.AtEnd,
		ref = props.buttonRef,
		[React.Event.Activated] = function()
			if not disabled then
				props.onTap()
			end
		end,
		[React.Event.InputBegan] = onInputBegan,
		[React.Event.InputEnded] = onInputEnded,
	}, {
		Corner = e("UICorner", { CornerRadius = UDim.new(0, Theme.radius.button) }),
		-- Unfilled styles share panelRaised with Kit.Card, so inside a card only an outline shows the button's
		-- shape (textDim on panelRaised is well over the 3:1 floor for controls).
		Outline = if fill == colors.panelRaised
			then e("UIStroke", {
				ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
				Color = colors.textDim,
				Thickness = 1,
			})
			else nil,
		Padding = e("UIPadding", {
			PaddingLeft = UDim.new(0, Theme.spacing.md),
			PaddingRight = UDim.new(0, Theme.spacing.md),
		}),
		Press = e("UIScale", {
			Scale = pressed:map(function(down: boolean): number
				return if down then Theme.motion.pressScale else 1
			end),
		}),
	})
end

-- Two or three buttons side by side, sharing the width.
function Kit.ButtonRow(props: { order: number?, buttons: { [string]: any }, count: number })
	local gap = PhoneConfig.garage.buttonGap
	local children: { [string]: any } = {
		Layout = e("UIGridLayout", {
			CellPadding = UDim2.fromOffset(gap, 0),
			CellSize = UDim2.new(1 / props.count, -gap * (props.count - 1) / props.count, 0, Theme.size.buttonHeight),
			SortOrder = Enum.SortOrder.LayoutOrder,
			FillDirection = Enum.FillDirection.Horizontal,
		}),
	}
	for key, button in props.buttons do
		children[key] = button
	end
	return e("Frame", {
		LayoutOrder = props.order or 0,
		Size = UDim2.new(1, 0, 0, Theme.size.buttonHeight),
		BackgroundTransparency = 1,
	}, children)
end

-- A "<" or ">" drawn from two rounded bars (no image assets), in a box `size` px square.
function Kit.Chevron(props: { direction: number, color: Color3, size: number, thickness: number? })
	local thickness = props.thickness or 2
	local length = props.size * math.sqrt(0.5) + thickness / 2
	local quarter = props.size / 4
	local tilt = 45 * props.direction
	local function bar(offsetY: number, rotation: number)
		return e("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.new(0.5, 0, 0.5, offsetY),
			Size = UDim2.fromOffset(thickness, length),
			Rotation = rotation,
			BackgroundColor3 = props.color,
			BorderSizePixel = 0,
		}, {
			Corner = e("UICorner", { CornerRadius = UDim.new(0.5, 0) }),
		})
	end
	return e("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(props.size, props.size),
		BackgroundTransparency = 1,
	}, {
		Upper = bar(-quarter, -tilt),
		Lower = bar(quarter, tilt),
	})
end

-- Containers ---------------------------------------------------------------------------------------------------

-- Children laid out top to bottom with a gap, as tall as they are.
function Kit.Stack(props: { order: number?, gap: number?, padding: number? }, children: { [string]: any })
	local list: { [string]: any } = table.clone(children)
	list.Layout = e("UIListLayout", {
		FillDirection = Enum.FillDirection.Vertical,
		SortOrder = Enum.SortOrder.LayoutOrder,
		Padding = UDim.new(0, props.gap or Theme.spacing.sm),
	})
	if props.padding then
		local pad = UDim.new(0, props.padding)
		list.Padding = e("UIPadding", { PaddingLeft = pad, PaddingRight = pad, PaddingTop = pad, PaddingBottom = pad })
	end
	return e("Frame", {
		LayoutOrder = props.order or 0,
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
	}, list)
end

-- A raised card holding a stack of children.
function Kit.Card(props: { order: number?, gap: number?, padding: number? }, children: { [string]: any })
	local list: { [string]: any } = table.clone(children)
	local pad = UDim.new(0, props.padding or PhoneConfig.garage.cardPadding)
	list.Layout = e("UIListLayout", {
		FillDirection = Enum.FillDirection.Vertical,
		SortOrder = Enum.SortOrder.LayoutOrder,
		Padding = UDim.new(0, props.gap or Theme.spacing.sm),
	})
	list.Padding = e("UIPadding", { PaddingLeft = pad, PaddingRight = pad, PaddingTop = pad, PaddingBottom = pad })
	list.Corner = e("UICorner", { CornerRadius = UDim.new(0, Theme.radius.card) })
	return e("Frame", {
		LayoutOrder = props.order or 0,
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = colors.panelRaised,
		BorderSizePixel = 0,
	}, list)
end

-- A page that scrolls when its content is taller than the sheet. Children stack top to bottom.
function Kit.Page(props: { gap: number? }, children: { [string]: any })
	local pad = UDim.new(0, PhoneConfig.sheet.padding)
	local list: { [string]: any } = table.clone(children)
	list.Layout = e("UIListLayout", {
		FillDirection = Enum.FillDirection.Vertical,
		SortOrder = Enum.SortOrder.LayoutOrder,
		Padding = UDim.new(0, props.gap or Theme.spacing.md),
	})
	list.Padding = e("UIPadding", { PaddingLeft = pad, PaddingRight = pad, PaddingBottom = pad })
	return e("ScrollingFrame", {
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		ScrollBarThickness = PhoneConfig.sheet.scrollBarThickness,
		ScrollBarImageColor3 = colors.textDim,
		Selectable = false,
	}, list)
end

-- Small pieces ------------------------------------------------------------------------------------------------

-- A rounded outline label ("Arriving soon", "Out now").
function Kit.Pill(props: { text: string, order: number?, color: Color3? })
	local config = PhoneConfig.garage
	local color = props.color or colors.accent
	return e("TextLabel", {
		LayoutOrder = props.order or 0,
		Size = UDim2.fromOffset(0, config.pillHeight),
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundTransparency = 1,
		FontFace = Theme.fonts.bold,
		Text = props.text,
		TextColor3 = color,
		TextSize = Theme.text.small,
	}, {
		Corner = e("UICorner", { CornerRadius = UDim.new(0, Theme.radius.pill) }),
		Stroke = e("UIStroke", {
			ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
			Color = color,
			Thickness = 1,
		}),
		Padding = e("UIPadding", {
			PaddingLeft = UDim.new(0, config.pillPadding),
			PaddingRight = UDim.new(0, config.pillPadding),
		}),
	})
end

-- A row of choices; the chosen one is filled with the accent.
function Kit.Segmented(props: {
	options: { Option },
	selected: string,
	onSelect: (id: string) -> (),
	order: number?,
})
	local count = math.max(#props.options, 1)
	local gap = Theme.spacing.xs
	local children: { [string]: any } = {
		Layout = e("UIGridLayout", {
			CellPadding = UDim2.fromOffset(gap, 0),
			CellSize = UDim2.new(1 / count, -gap * (count - 1) / count, 1, 0),
			SortOrder = Enum.SortOrder.LayoutOrder,
			FillDirection = Enum.FillDirection.Horizontal,
		}),
		Padding = e("UIPadding", {
			PaddingLeft = UDim.new(0, gap),
			PaddingRight = UDim.new(0, gap),
			PaddingTop = UDim.new(0, gap),
			PaddingBottom = UDim.new(0, gap),
		}),
		Corner = e("UICorner", { CornerRadius = UDim.new(0, Theme.radius.button) }),
	}
	for index, option in props.options do
		local chosen = option.id == props.selected
		children[`Option_{option.id}`] = e("TextButton", {
			LayoutOrder = index,
			BackgroundColor3 = if chosen then colors.accent else colors.panelRaised,
			BackgroundTransparency = if chosen then 0 else 1,
			BorderSizePixel = 0,
			AutoButtonColor = not chosen,
			FontFace = if chosen then Theme.fonts.bold else Theme.fonts.medium,
			Text = option.label,
			TextColor3 = if chosen then colors.onAccent else colors.text,
			TextSize = Theme.text.body,
			[React.Event.Activated] = function()
				if not chosen then
					props.onSelect(option.id)
				end
			end,
		}, {
			Corner = e("UICorner", { CornerRadius = UDim.new(0, Theme.radius.button - gap) }),
		})
	end
	-- Each choice is the full button height inside the padding, so it stays a 44 px+ target.
	return e("Frame", {
		LayoutOrder = props.order or 0,
		Size = UDim2.new(1, 0, 0, Theme.size.buttonHeight + 2 * gap),
		BackgroundColor3 = colors.panelRaised,
		BorderSizePixel = 0,
	}, children)
end

-- A 0..1 slider between - and + buttons. Dragging updates `onChange(value, false)` as it moves and
-- `onChange(value, true)` once on release; the buttons step by PhoneConfig.slider.step and are final at once.
function Kit.Slider(props: { value: number, onChange: (value: number, final: boolean) -> (), order: number? })
	local config = PhoneConfig.slider
	local track = React.useRef(nil :: GuiObject?)
	local drag = React.useRef(nil :: { RBXScriptConnection }?)
	local onChange = React.useRef(props.onChange)
	onChange.current = props.onChange
	local value = math.clamp(props.value, 0, 1)

	local function valueAt(x: number): number
		local current = track.current
		if current == nil or current.AbsoluteSize.X <= 0 then
			return value
		end
		return math.clamp((x - current.AbsolutePosition.X) / current.AbsoluteSize.X, 0, 1)
	end

	local function stopDrag()
		local connections = drag.current
		if connections then
			for _, connection in connections do
				connection:Disconnect()
			end
			drag.current = nil
		end
	end

	React.useEffect(function()
		return stopDrag
	end, {})

	local function startDrag(input: InputObject)
		stopDrag()
		local latest = valueAt(input.Position.X)
		onChange.current(latest, false)
		local moved = UserInputService.InputChanged:Connect(function(changed: InputObject)
			local follows = changed == input or changed.UserInputType == Enum.UserInputType.MouseMovement
			if follows then
				latest = valueAt(changed.Position.X)
				onChange.current(latest, false)
			end
		end)
		local ended = UserInputService.InputEnded:Connect(function(finished: InputObject)
			if finished == input or finished.UserInputType == Enum.UserInputType.MouseButton1 then
				stopDrag()
				onChange.current(latest, true)
			end
		end)
		drag.current = { moved, ended }
	end

	local function step(direction: number)
		local stepped = math.clamp(math.round((value + direction * config.step) / config.step) * config.step, 0, 1)
		onChange.current(stepped, true)
	end

	local stepSize = UDim2.new(0, config.stepButtonWidth, 1, 0)
	local trackInset = config.stepButtonWidth + Theme.spacing.md
	return e("Frame", {
		LayoutOrder = props.order or 0,
		Size = UDim2.new(1, 0, 0, Theme.size.buttonHeight),
		BackgroundTransparency = 1,
	}, {
		Down = e(Kit.Button, {
			label = PhoneConfig.settings.down,
			onTap = function()
				step(-1)
			end,
			size = stepSize,
			textSize = Theme.text.heading,
		}),
		-- The whole strip between the buttons takes the drag, so it is easy to grab with a thumb.
		Track = e("TextButton", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.new(1, -2 * trackInset, 1, 0),
			BackgroundTransparency = 1,
			AutoButtonColor = false,
			Selectable = false,
			Text = "",
			ref = track,
			[React.Event.InputBegan] = function(_rbx: GuiObject, input: InputObject)
				if isPress(input) then
					startDrag(input)
				end
			end,
		}, {
			Rail = e("Frame", {
				AnchorPoint = Vector2.new(0, 0.5),
				Position = UDim2.fromScale(0, 0.5),
				Size = UDim2.new(1, 0, 0, config.trackHeight),
				BackgroundColor3 = colors.track,
				BorderSizePixel = 0,
			}, {
				Corner = e("UICorner", { CornerRadius = UDim.new(0.5, 0) }),
				Fill = e("Frame", {
					Size = UDim2.fromScale(value, 1),
					BackgroundColor3 = colors.accent,
					BorderSizePixel = 0,
				}, {
					Corner = e("UICorner", { CornerRadius = UDim.new(0.5, 0) }),
				}),
			}),
			Knob = e("Frame", {
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(value, 0.5),
				Size = UDim2.fromOffset(config.knobSize, config.knobSize),
				BackgroundColor3 = colors.text,
				BorderSizePixel = 0,
			}, {
				Corner = e("UICorner", { CornerRadius = UDim.new(0.5, 0) }),
			}),
		}),
		Up = e(Kit.Button, {
			label = PhoneConfig.settings.up,
			onTap = function()
				step(1)
			end,
			anchor = Vector2.new(1, 0),
			position = UDim2.fromScale(1, 0),
			size = stepSize,
			textSize = Theme.text.heading,
		}),
	})
end

-- A finished-looking "arriving soon" screen for an app whose feature lands in a later update: its drawing in a
-- large round badge, a title, one or two lines about it, and a pill.
function Kit.ComingSoon(props: { glyph: PhoneConfig.Glyph, title: string, body: string, pill: string })
	local soon = PhoneConfig.comingSoon
	local function centred(order: number, label: string, size: number, font: Font, color: Color3)
		return Kit.Text({
			text = label,
			order = order,
			size = size,
			font = font,
			color = color,
			align = Enum.TextXAlignment.Center,
		})
	end
	return Kit.Page({ gap = Theme.spacing.md }, {
		Top = e("Frame", {
			LayoutOrder = 0,
			Size = UDim2.new(1, 0, 0, soon.topSpace),
			BackgroundTransparency = 1,
		}),
		Badge = e("Frame", {
			LayoutOrder = 1,
			Size = UDim2.new(1, 0, 0, soon.badgeSize),
			BackgroundTransparency = 1,
		}, {
			Circle = e("Frame", {
				AnchorPoint = Vector2.new(0.5, 0),
				Position = UDim2.fromScale(0.5, 0),
				Size = UDim2.fromOffset(soon.badgeSize, soon.badgeSize),
				BackgroundColor3 = colors.panelRaised,
				BorderSizePixel = 0,
			}, {
				Corner = e("UICorner", { CornerRadius = UDim.new(0.5, 0) }),
				Glyph = e(Glyph, {
					name = props.glyph,
					color = colors.accent,
					background = colors.panelRaised,
					size = Vector2.new(soon.glyphSize, soon.glyphSize),
				}),
			}),
		}),
		Title = centred(2, props.title, Theme.text.heading, Theme.fonts.bold, colors.text),
		Body = centred(3, props.body, Theme.text.body, Theme.fonts.regular, colors.textDim),
		Pill = e("Frame", {
			LayoutOrder = 4,
			Size = UDim2.new(1, 0, 0, PhoneConfig.garage.pillHeight),
			BackgroundTransparency = 1,
		}, {
			Align = e("UIListLayout", { HorizontalAlignment = Enum.HorizontalAlignment.Center }),
			Pill = Kit.Pill({ text = props.pill }),
		}),
	})
end

-- Fades and slides a sheet in when it mounts and out when `leaving` turns true (one binding driven by a short
-- TweenService tween, like UI/Toast). Returns the binding: 0 = fully shown, 1 = fully hidden.
function Kit.useAppear(leaving: boolean): any
	local fade, setFade = React.useBinding(1)
	React.useEffect(function()
		local value = Instance.new("NumberValue")
		value.Value = fade:getValue()
		local connection = value.Changed:Connect(function(current: number)
			setFade(current)
		end)
		local tween = TweenService:Create(
			value,
			TweenInfo.new(Theme.motion.sheetSeconds, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ Value = if leaving then 1 else 0 }
		)
		tween:Play()
		return function()
			tween:Cancel()
			connection:Disconnect()
			value:Destroy()
		end
	end, { leaving })
	return fade
end

return Kit
