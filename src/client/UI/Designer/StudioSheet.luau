--!strict
-- What the designer's sheets show (docs/phase-11-contracts.md "Client"; PLAN.md Phase 11), as shop-sheet content
-- (UI/Shop/Primitives.Content) that UI/Shop/ShopSheet draws: the same frame, header, scrolling body, footer
-- buttons and confirm dialog as the dealership, so the designer looks like the rest of the game. One builder per
-- screen:
--
--   disclosure     the AI notice, acknowledged with "Got it" before the first request
--   compose        the Design Studio: the prompt box with its 200-character counter, the class picker (kit
--                  classes and "AI picks"), the cost ("Free" for the first car, else the credits) and Design it
--   progress       a sliding bar while the AI works; after a while it says the sheet can be closed
--   result         the new design: a turning preview, name, tagline, class and energy, stat bars, Report, and
--                  Build / Free redesign (while the design has one; the re-roll in code) / Discard. Redesigns
--                  are never sold: once the free one is used, the note says to discard and change the words
--   refused        the server's friendly refusal (credits come back), with Try again
--   built          the design is in the garage: Drive it / Done
--   modCompose     "Mod with AI": the car as it is, the prompt box and the cost
--   modResult      the mod is on: before and after side by side, Report
--   outOfCredits   what a request costs, the balance, and Get credits (Controllers/StoreController puts this sheet
--                  away and opens the phone's Store app on its Credits page)
--   store          only if the Store app couldn't open: where the credit packs are, and Open the Store
--   report         the reasons from Config/Designer, one row each, and Send report
--
-- Every block has a fixed height (ShopSheet sizes the sheet from them); text that wraps is measured with
-- TextService for the column it sits in (widthsFor). Presentation only: DesignerController passes the values and
-- callbacks; every word comes from UI/Designer/DesignerStyle (or Config/Designer, through DesignerModel).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextService = game:GetService("TextService")
local TweenService = game:GetService("TweenService")

local React = require(ReplicatedStorage.Packages.React)

local Theme = require(script.Parent.Parent.Theme)
local Primitives = require(script.Parent.Parent.Shop.Primitives)
local ShopModel = require(script.Parent.Parent.Shop.ShopModel)
local ShopStyle = require(script.Parent.Parent.Shop.Style)
local DesignerModel = require(script.Parent.DesignerModel)
local DesignerStyle = require(script.Parent.DesignerStyle)
local Preview = require(script.Parent.Preview)
local StoreState = require(script.Parent.Parent.Store.StoreState)

local e = React.createElement
local colors = Theme.colors
local fonts = Theme.fonts
local layout = DesignerStyle.layout
local shopLayout = ShopStyle.layout
local copy = DesignerStyle.copy

-- The text widths (inside the sheet's padding) of the body column and, on a wide card, the right column.
export type Widths = { main: number, aside: number }

export type Content = Primitives.Content
export type Section = Primitives.Section
export type Tone = Primitives.Tone

local MEASURE_HEIGHT = 10000 -- px: a box taller than any sheet, so wrapped text is measured in full

local StudioSheet = {}

-- Measuring ------------------------------------------------------------------------------------------------------

-- The text widths for a sheet layout (ShopModel.layoutFor): one column, or the wide card's two.
function StudioSheet.widthsFor(sheetLayout: ShopModel.Layout): Widths
	local pad = 2 * shopLayout.pad
	if sheetLayout.mode == "wide" then
		return {
			main = math.max(sheetLayout.width - sheetLayout.asideWidth - pad, 0),
			aside = math.max(sheetLayout.asideWidth - pad, 0),
		}
	end
	local width = math.max(sheetLayout.width - pad, 0)
	return { main = width, aside = width }
end

-- The height wrapped text takes in a column `width` px wide (BuilderSans, the Theme's family), at least one line.
function StudioSheet.textHeight(text: string, textSize: number, width: number, bold: boolean?): number
	local font = if bold then Enum.Font.BuilderSansBold else Enum.Font.BuilderSans
	local ok, size = pcall(function(): Vector2
		return TextService:GetTextSize(text, textSize, font, Vector2.new(math.max(width, 1), MEASURE_HEIGHT))
	end)
	local measured = if ok then size.Y else textSize
	return math.ceil(math.max(measured, textSize)) + Theme.spacing.xs
end

-- Small sections --------------------------------------------------------------------------------------------------

type ParagraphOptions = { tone: Tone?, size: number?, bold: boolean? }

-- A wrapped paragraph as tall as its text.
local function paragraph(key: string, text: string, width: number, props: ParagraphOptions?): Section
	local options: ParagraphOptions = props or {}
	local size = options.size or Theme.text.body
	local height = StudioSheet.textHeight(text, size, width, options.bold)
	return {
		key = key,
		height = height,
		element = e(Primitives.Label, {
			text = text,
			height = height,
			textSize = size,
			font = if options.bold then fonts.bold else fonts.regular,
			color = Primitives.toneColor(options.tone),
			wrapped = true,
		}),
	}
end

-- A full-width secondary button inside the body (Report this design).
local function inlineButton(key: string, label: string, disabled: boolean, onTap: () -> ()): Section
	return {
		key = key,
		height = layout.inlineButtonHeight,
		element = e(Primitives.Button, {
			label = label,
			style = "secondary",
			disabled = disabled,
			size = UDim2.new(1, 0, 0, layout.inlineButtonHeight),
			onTap = onTap,
		}),
	}
end

local function priceSection(key: string, label: string, price: string, status: string?, tone: Tone?): Section
	return {
		key = key,
		height = Primitives.priceBlockHeight(),
		element = e(Primitives.PriceBlock, { label = label, price = price, status = status, statusTone = tone }),
	}
end

local function previewSection(key: string, model: Model?, label: string?): Section
	return {
		key = key,
		height = layout.previewHeight,
		element = e(Preview.Preview, { model = model, label = label }),
	}
end

local function statsSection(key: string, rows: { Primitives.StatRow }): Section?
	if #rows == 0 then
		return nil
	end
	return { key = key, height = Primitives.statListHeight(#rows), element = e(Primitives.StatList, { rows = rows }) }
end

local function action(
	key: string,
	label: string,
	style: Primitives.ButtonStyle,
	disabled: boolean,
	onTap: () -> ()
): Primitives.Action
	return { key = key, label = label, style = style, disabled = disabled, onTap = onTap }
end

-- The prompt box ----------------------------------------------------------------------------------------------------

export type PromptProps = {
	text: string,
	limit: number,
	placeholder: string,
	disabled: boolean,
	autoFocus: boolean, -- keyboard players get the cursor in the box (on phones it would pop the keyboard up)
	onText: (text: string) -> (),
	onSubmit: () -> (),
}

local function promptBoxHeight(): number
	return 2 * layout.promptPadding + layout.promptLines * layout.promptLineHeight
end

-- A wrapped text box a few lines tall, with "12/200" under it on the right (in the warning color at the limit).
-- The controller keeps the text: every change comes back through onText, already cut to the limit.
local function PromptBox(props: PromptProps)
	local box = React.useRef(nil :: TextBox?)
	React.useEffect(function()
		local current = box.current
		if current ~= nil and props.autoFocus and not props.disabled then
			current:CaptureFocus()
		end
	end, {})
	local count = DesignerModel.charCount(props.text)
	local boxHeight = promptBoxHeight()
	local onFocusLost: any = function(_rbx: TextBox, enterPressed: boolean)
		if enterPressed then
			props.onSubmit()
		end
	end
	return e("Frame", {
		Size = UDim2.new(1, 0, 0, boxHeight + layout.counterGap + layout.counterHeight),
		BackgroundTransparency = 1,
	}, {
		Box = e("TextBox", {
			Size = UDim2.new(1, 0, 0, boxHeight),
			BackgroundColor3 = colors.panelRaised,
			BorderSizePixel = 0,
			ClearTextOnFocus = false,
			MultiLine = false, -- Enter sends; long text still wraps
			TextEditable = not props.disabled,
			FontFace = fonts.medium,
			PlaceholderText = props.placeholder,
			PlaceholderColor3 = colors.textDim,
			Text = props.text,
			TextColor3 = colors.text,
			TextSize = Theme.text.body,
			TextWrapped = true,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextYAlignment = Enum.TextYAlignment.Top,
			ref = box,
			[React.Change.Text] = function(rbx: TextBox)
				-- Cut to the limit on the box itself (a re-render with an unchanged prop wouldn't).
				local clamped = DesignerModel.clampPrompt(rbx.Text, props.limit)
				if clamped ~= rbx.Text then
					rbx.Text = clamped -- fires this handler again with the cut text
					return
				end
				if clamped ~= props.text then
					props.onText(clamped)
				end
			end,
			[React.Event.FocusLost] = onFocusLost,
		}, {
			Corner = e("UICorner", { CornerRadius = UDim.new(0, Theme.radius.button) }),
			Padding = e("UIPadding", {
				PaddingLeft = UDim.new(0, layout.promptPadding),
				PaddingRight = UDim.new(0, layout.promptPadding),
				PaddingTop = UDim.new(0, layout.promptPadding),
				PaddingBottom = UDim.new(0, layout.promptPadding),
			}),
		}),
		Counter = e(Primitives.Label, {
			text = DesignerModel.counterText(props.text, props.limit),
			height = layout.counterHeight,
			textSize = Theme.text.small,
			font = fonts.medium,
			color = if count >= props.limit then colors.warning else colors.textDim,
			align = Enum.TextXAlignment.Right,
			position = UDim2.fromOffset(0, boxHeight + layout.counterGap),
		}),
	})
end

local function promptSection(key: string, props: PromptProps): Section
	return {
		key = key,
		height = promptBoxHeight() + layout.counterGap + layout.counterHeight,
		element = e(PromptBox, props),
	}
end

-- The class picker -------------------------------------------------------------------------------------------------

local function classSection(
	options: { DesignerModel.Option },
	choice: string,
	disabled: boolean,
	onPick: (id: string) -> ()
): Section
	local chips: { Primitives.Chip } = {}
	for _, option in options do
		table.insert(chips, { id = option.id, label = option.label, selected = option.id == choice })
	end
	return {
		key = "classes",
		height = layout.pickerTitleHeight + layout.pickerGap + Primitives.chipsHeight(),
		element = e("Frame", {
			Size = UDim2.fromScale(1, 1),
			BackgroundTransparency = 1,
		}, {
			Title = e(Primitives.Label, {
				text = copy.classTitle,
				height = layout.pickerTitleHeight,
				textSize = Theme.text.small,
				font = fonts.medium,
				color = colors.textDim,
			}),
			Chips = e("Frame", {
				Position = UDim2.fromOffset(0, layout.pickerTitleHeight + layout.pickerGap),
				Size = UDim2.new(1, 0, 0, Primitives.chipsHeight()),
				BackgroundTransparency = 1,
			}, {
				Row = e(Primitives.TrimChips, { chips = chips, disabled = disabled, onPick = onPick }),
			}),
		}),
	}
end

-- The AI notice card --------------------------------------------------------------------------------------------------

local function disclosureSection(text: string, width: number): Section
	local inner = width - 2 * layout.disclosurePadding
	local leadHeight = StudioSheet.textHeight(copy.disclosureLead, Theme.text.heading, inner, true)
	local bodyHeight = StudioSheet.textHeight(text, Theme.text.body, inner)
	local pad = UDim.new(0, layout.disclosurePadding)
	return {
		key = "disclosure",
		height = 2 * layout.disclosurePadding + leadHeight + Theme.spacing.sm + bodyHeight,
		element = e("Frame", {
			Size = UDim2.fromScale(1, 1),
			BackgroundColor3 = colors.panelRaised,
			BorderSizePixel = 0,
		}, {
			Corner = Primitives.corner(Theme.radius.card),
			Padding = e("UIPadding", { PaddingLeft = pad, PaddingRight = pad, PaddingTop = pad, PaddingBottom = pad }),
			Layout = e("UIListLayout", {
				FillDirection = Enum.FillDirection.Vertical,
				SortOrder = Enum.SortOrder.LayoutOrder,
				Padding = UDim.new(0, Theme.spacing.sm),
			}),
			Lead = e(Primitives.Label, {
				order = 1,
				text = copy.disclosureLead,
				height = leadHeight,
				textSize = Theme.text.heading,
				font = fonts.bold,
				wrapped = true,
			}),
			Body = e(Primitives.Label, {
				order = 2,
				text = text,
				height = bodyHeight,
				wrapped = true,
			}),
		}),
	}
end

-- The progress bar ---------------------------------------------------------------------------------------------------

-- A short accent bar sliding along a track, over and over (a looping tween on a NumberValue).
local function ProgressBar()
	local slide, setSlide = React.useBinding(0)
	React.useEffect(function()
		local value = Instance.new("NumberValue")
		local connection = value.Changed:Connect(function(current: number)
			setSlide(current)
		end)
		local tween = TweenService:Create(
			value,
			TweenInfo.new(layout.progressSeconds, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1),
			{ Value = 1 }
		)
		tween:Play()
		return function()
			tween:Cancel()
			connection:Disconnect()
			value:Destroy()
		end
	end, {})
	local share = layout.progressShare
	return e("Frame", {
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.fromScale(0, 0.5),
		Size = UDim2.new(1, 0, 0, layout.progressHeight),
		BackgroundColor3 = colors.track,
		BorderSizePixel = 0,
		ClipsDescendants = true,
	}, {
		Corner = Primitives.corner(Theme.radius.pill),
		Bar = e("Frame", {
			Position = slide:map(function(value: number): UDim2
				return UDim2.fromScale(value * (1 + share) - share, 0)
			end),
			Size = UDim2.fromScale(share, 1),
			BackgroundColor3 = colors.accent,
			BorderSizePixel = 0,
		}, {
			Corner = Primitives.corner(Theme.radius.pill),
		}),
	})
end

-- Two previews side by side (before and after a mod) --------------------------------------------------------------------

local function beforeAfterSection(before: Model?, after: Model?): Section
	local gap = layout.previewGap
	local half = UDim2.new(0.5, -gap / 2, 1, 0)
	return {
		key = "beforeAfter",
		height = layout.beforeAfterHeight,
		element = e("Frame", {
			Size = UDim2.fromScale(1, 1),
			BackgroundTransparency = 1,
		}, {
			Before = e(Preview.Preview, { model = before, label = copy.before, size = half }),
			After = e(Preview.Preview, {
				model = after,
				label = copy.after,
				size = half,
				position = UDim2.new(0.5, gap / 2, 0, 0),
			}),
		}),
	}
end

-- Report reasons --------------------------------------------------------------------------------------------------------

local function reasonsSection(
	reasons: { DesignerModel.Option },
	selected: string?,
	disabled: boolean,
	onPick: (id: string) -> ()
): Section
	local rows: { [string]: any } = {
		Layout = e("UIListLayout", {
			FillDirection = Enum.FillDirection.Vertical,
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, layout.reasonGap),
		}),
	}
	for index, reason in reasons do
		local chosen = reason.id == selected
		rows[`Reason_{index}`] = e("TextButton", {
			LayoutOrder = index,
			Size = UDim2.new(1, 0, 0, layout.reasonRowHeight),
			BackgroundColor3 = if chosen then colors.accent else colors.panelRaised,
			BorderSizePixel = 0,
			AutoButtonColor = not chosen and not disabled,
			FontFace = if chosen then fonts.bold else fonts.medium,
			Text = reason.label,
			TextColor3 = if chosen then colors.onAccent else colors.text,
			TextSize = Theme.text.body,
			TextTruncate = Enum.TextTruncate.AtEnd,
			TextXAlignment = Enum.TextXAlignment.Left,
			[React.Event.Activated] = function()
				if not disabled and not chosen then
					onPick(reason.id)
				end
			end,
		}, {
			Corner = Primitives.corner(Theme.radius.button),
			Padding = e("UIPadding", {
				PaddingLeft = UDim.new(0, Theme.spacing.md),
				PaddingRight = UDim.new(0, Theme.spacing.md),
			}),
		})
	end
	local count = #reasons
	return {
		key = "reasons",
		height = count * layout.reasonRowHeight + math.max(count - 1, 0) * layout.reasonGap,
		element = e("Frame", { Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1 }, rows),
	}
end

-- Screens ----------------------------------------------------------------------------------------------------------------

export type DisclosureProps = {
	kind: DesignerModel.Kind,
	text: string, -- the notice's body (Config/Designer's, else DesignerStyle's)
	widths: Widths,
	onAccept: () -> (),
}

function StudioSheet.disclosure(props: DisclosureProps): Content
	return {
		eyebrow = if props.kind == "mod" then copy.modEyebrow else copy.studio,
		title = copy.disclosureTitle,
		main = { disclosureSection(props.text, props.widths.main) },
		summary = {},
		actions = { action("ok", copy.disclosureOk, "primary", false, props.onAccept) },
	}
end

export type ComposeProps = {
	text: string,
	limit: number,
	options: { DesignerModel.Option },
	choice: string, -- the picked class chip (DesignerModel.surpriseId for "AI picks")
	costLabel: string, -- "Free", "2 credits"
	balanceLine: string,
	balanceTone: Tone,
	sending: boolean, -- DesignCar is with the server
	autoFocus: boolean,
	widths: Widths,
	onText: (text: string) -> (),
	onPick: (id: string) -> (),
	onSend: () -> (),
}

function StudioSheet.compose(props: ComposeProps): Content
	return {
		eyebrow = copy.studio,
		title = copy.describeTitle,
		subtitle = copy.describeHint,
		main = {
			promptSection("prompt", {
				text = props.text,
				limit = props.limit,
				placeholder = copy.placeholder,
				disabled = props.sending,
				autoFocus = props.autoFocus,
				onText = props.onText,
				onSubmit = props.onSend,
			}),
			classSection(props.options, props.choice, props.sending, props.onPick),
		},
		summary = {
			priceSection("cost", copy.cost, props.costLabel, props.balanceLine, props.balanceTone),
			paragraph("finePrint", copy.finePrint, props.widths.aside, { tone = "dim", size = Theme.text.small }),
		},
		actions = {
			action(
				"design",
				if props.sending then copy.sending else copy.design,
				"primary",
				props.sending,
				props.onSend
			),
		},
	}
end

export type ProgressProps = {
	kind: DesignerModel.Kind,
	slow: boolean, -- it's taking a while: say the sheet can be closed
	widths: Widths,
	onClose: () -> (),
}

function StudioSheet.progress(props: ProgressProps): Content
	local body = if props.slow then copy.slowBody else copy.designingBody
	return {
		eyebrow = if props.kind == "mod" then copy.modEyebrow else copy.studio,
		title = if props.kind == "mod" then copy.moddingTitle else copy.designingTitle,
		main = {
			{ key = "bar", height = layout.progressBlockHeight, element = e(ProgressBar) },
			paragraph("body", body, props.widths.main, { tone = "dim" }),
		},
		summary = {},
		actions = { action("close", copy.close, "secondary", false, props.onClose) },
	}
end

export type ResultBusy = "build" | "reroll" | "discard"

export type ResultProps = {
	card: DesignerModel.Card,
	model: Model?, -- the preview (nil: "Preview not available")
	stats: { Primitives.StatRow },
	rerollFree: boolean, -- a free re-roll is left (there is no other kind)
	newDesignCost: string, -- "2 credits": what a new design from changed words costs
	busy: ResultBusy?,
	widths: Widths,
	onBuild: () -> (),
	onReroll: () -> (),
	onDiscard: () -> (),
	onReport: () -> (),
}

function StudioSheet.result(props: ResultProps): Content
	local card = props.card
	local busy = props.busy
	local locked = busy ~= nil
	local main: { Section } = { previewSection("preview", props.model, nil) }
	if card.specLine ~= "" then
		table.insert(main, Primitives.specSection("spec", card.specLine))
	end
	local stats = statsSection("stats", props.stats)
	if stats ~= nil then
		table.insert(main, stats)
	end
	table.insert(main, inlineButton("report", copy.report, locked, props.onReport))
	local actions: { Primitives.Action } = {
		action("build", if busy == "build" then copy.building else copy.build, "primary", locked, props.onBuild),
	}
	if props.rerollFree or busy == "reroll" then
		local rerollLabel = if busy == "reroll" then copy.rerolling else copy.freeReroll
		table.insert(actions, action("reroll", rerollLabel, "secondary", locked, props.onReroll))
	end
	local discardLabel = if busy == "discard" then copy.discarding else copy.discard
	table.insert(actions, action("discard", discardLabel, "secondary", locked, props.onDiscard))
	local note = if props.rerollFree then copy.rerollNote else string.format(copy.changeWords, props.newDesignCost)
	return {
		eyebrow = copy.resultEyebrow,
		title = card.name,
		subtitle = card.tagline,
		main = main,
		summary = { paragraph("reroll", note, props.widths.aside, { tone = "dim", size = Theme.text.small }) },
		actions = actions,
	}
end

-- The confirm dialog before Discard (UI/Shop/ShopSheet draws it over the result).
function StudioSheet.discardConfirm(busy: boolean, onConfirm: () -> (), onCancel: () -> ()): Primitives.Confirm
	return {
		title = copy.discardTitle,
		rows = { { label = copy.discardRow, value = "", tone = "dim" } },
		confirmLabel = copy.discard,
		busyLabel = copy.discarding,
		busy = busy,
		onConfirm = onConfirm,
		onCancel = onCancel,
	}
end

export type RefusedProps = {
	kind: DesignerModel.Kind,
	message: string, -- the server's friendly words
	widths: Widths,
	onRetry: () -> (),
	onClose: () -> (),
}

function StudioSheet.refused(props: RefusedProps): Content
	local message = if props.message ~= "" then props.message else copy.failed
	return {
		eyebrow = if props.kind == "mod" then copy.modEyebrow else copy.studio,
		title = if props.kind == "mod" then copy.modRefusedTitle else copy.refusedTitle,
		main = { paragraph("message", message, props.widths.main) },
		summary = {},
		actions = {
			action("retry", copy.tryAgain, "primary", false, props.onRetry),
			action("close", copy.close, "secondary", false, props.onClose),
		},
	}
end

export type BuiltProps = {
	card: DesignerModel.Card,
	model: Model?,
	canDrive: boolean, -- the server said which garage car it is
	busy: boolean, -- SpawnOwned is with the server
	widths: Widths,
	onDrive: () -> (),
	onDone: () -> (),
}

function StudioSheet.built(props: BuiltProps): Content
	local actions: { Primitives.Action } = {}
	if props.canDrive then
		table.insert(actions, action("drive", copy.driveIt, "primary", props.busy, props.onDrive))
	end
	table.insert(
		actions,
		action("done", copy.done, if props.canDrive then "secondary" else "primary", props.busy, props.onDone)
	)
	return {
		eyebrow = props.card.name,
		title = copy.builtTitle,
		main = {
			previewSection("preview", props.model, nil),
			paragraph("body", copy.builtBody, props.widths.main, { tone = "dim" }),
		},
		summary = {},
		actions = actions,
	}
end

export type ModComposeProps = {
	carName: string,
	catalog: boolean, -- a dealership car: the AI may change only the look
	before: Model?,
	text: string,
	limit: number,
	costLabel: string,
	balanceLine: string,
	balanceTone: Tone,
	sending: boolean,
	autoFocus: boolean,
	widths: Widths,
	onText: (text: string) -> (),
	onSend: () -> (),
}

function StudioSheet.modCompose(props: ModComposeProps): Content
	local main: { Section } = {
		previewSection("before", props.before, nil),
		promptSection("prompt", {
			text = props.text,
			limit = props.limit,
			placeholder = copy.modPlaceholder,
			disabled = props.sending,
			autoFocus = props.autoFocus,
			onText = props.onText,
			onSubmit = props.onSend,
		}),
	}
	if props.catalog then
		table.insert(
			main,
			paragraph("catalog", copy.modCatalogNote, props.widths.main, { tone = "dim", size = Theme.text.small })
		)
	end
	return {
		eyebrow = copy.modEyebrow,
		title = props.carName,
		subtitle = copy.modBody,
		main = main,
		summary = {
			priceSection("cost", copy.cost, props.costLabel, props.balanceLine, props.balanceTone),
			paragraph("finePrint", copy.modFinePrint, props.widths.aside, { tone = "dim", size = Theme.text.small }),
		},
		actions = {
			action("mod", if props.sending then copy.sending else copy.modIt, "primary", props.sending, props.onSend),
		},
	}
end

export type ModResultProps = {
	title: string, -- the mod's summary
	carName: string,
	before: Model?,
	after: Model?,
	widths: Widths,
	onDone: () -> (),
	onReport: () -> (),
}

function StudioSheet.modResult(props: ModResultProps): Content
	return {
		eyebrow = props.carName,
		title = props.title,
		main = {
			beforeAfterSection(props.before, props.after),
			inlineButton("report", copy.reportMod, false, props.onReport),
		},
		summary = {},
		actions = { action("done", copy.done, "primary", false, props.onDone) },
	}
end

export type OutOfCreditsProps = {
	kind: DesignerModel.Kind,
	cost: string, -- "2 credits"
	balance: string, -- "0 credits"
	widths: Widths,
	onGetCredits: () -> (),
	onClose: () -> (),
}

function StudioSheet.outOfCredits(props: OutOfCreditsProps): Content
	local lead = string.format(if props.kind == "mod" then copy.outMod else copy.outDesign, props.cost)
	return {
		eyebrow = copy.creditsEyebrow,
		title = copy.outTitle,
		main = { paragraph("body", string.format(copy.outBody, lead, props.balance), props.widths.main) },
		summary = { priceSection("balance", copy.yourCredits, props.balance, nil, nil) },
		actions = {
			action("get", copy.getCredits, "primary", false, props.onGetCredits),
			action("close", copy.notNow, "secondary", false, props.onClose),
		},
	}
end

-- Where the credit packs are, if Get credits couldn't open the Store app (UI/Store/StoreState.open tries again).
function StudioSheet.store(widths: Widths, onBack: () -> ()): Content
	return {
		eyebrow = copy.creditsEyebrow,
		title = copy.storeTitle,
		main = { paragraph("body", copy.storeBody, widths.main, { tone = "dim" }) },
		summary = {},
		actions = {
			action("open", copy.openStore, "primary", false, function()
				StoreState.open("credits")
			end),
			action("back", copy.back, "secondary", false, onBack),
		},
	}
end

export type ReportProps = {
	carName: string,
	reasons: { DesignerModel.Option },
	selected: string?,
	busy: boolean, -- ReportDesign is with the server
	widths: Widths,
	onPick: (id: string) -> (),
	onSend: () -> (),
	onCancel: () -> (),
}

function StudioSheet.report(props: ReportProps): Content
	return {
		eyebrow = copy.reportEyebrow,
		title = props.carName,
		main = {
			paragraph("body", copy.reportBody, props.widths.main, { tone = "dim" }),
			reasonsSection(props.reasons, props.selected, props.busy, props.onPick),
		},
		summary = {},
		actions = {
			action(
				"send",
				if props.busy then copy.sending else copy.sendReport,
				"primary",
				props.busy or props.selected == nil,
				props.onSend
			),
			action("cancel", ShopStyle.copy.cancel, "secondary", props.busy, props.onCancel),
		},
	}
end

return StudioSheet
