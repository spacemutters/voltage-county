--!strict
-- The goals card (roast fixes 2026-10-24; Controllers/GoalsController decides what it says and where it goes):
--
--   tall     a small panel: an eyebrow line in the accent ("Step 1 of 3 · $3,000 bonus", "Daily goal done"), the
--            goal's title, a thin bar while it shows progress, and across its bottom the one button that does the step
--            ("Start", "Test drive", "Design", "Collect $1,500"). Tapping the words opens the list.
--   compact  the same in one row where the tall card has no room: the shorter eyebrow ("Step 1/3 · $3,000") and the
--            title on the left, the short button ("Drive", "Collect") on the right.
--   pill     the daily goals' small button ("Goals 1/3") when nothing is ready to collect; a tap opens the list.
--
-- Presentation only: every value and callback comes in as props. Sizes come from Config/Goals card at UI scale 1;
-- the buttons and the pill are at least Theme.size.touchTarget tall. Text keeps the theme's 4.5:1 contrast on the
-- panel; a title too long for the card shrinks to card.minTextSize, then is cut short.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local React = require(ReplicatedStorage.Packages.React)
local Goals = require(ReplicatedStorage.Shared.Config.Goals)

local Kit = require(script.Parent.Parent.Phone.Kit)
local Layout = require(script.Parent.Parent.Phone.Layout)
local Theme = require(script.Parent.Parent.Theme)

local e = React.createElement
local colors = Theme.colors

export type Kind = "path" | "daily" | "pill"

-- How the card is laid out where it goes (GoalsController.placeCard).
export type Shape = "tall" | "compact" | "pill"

-- What the card shows (GoalsController.cardFor).
export type Card = {
	kind: Kind,
	goalId: string?, -- the goal the button acts on (nil for the pill)
	eyebrow: string,
	shortEyebrow: string, -- the compact card's
	title: string,
	actionLabel: string?, -- nil: no button (the words open the list)
	shortLabel: string?, -- the compact card's button
	collect: boolean, -- the button collects a reward
	progress: number?, -- 0..1: a bar under the title on the tall card (nil: none)
}

export type Props = {
	rect: Layout.Rect, -- where it goes, in UI-scale-1 px, sized for its shape
	shape: Shape,
	card: Card,
	busy: boolean, -- a request for the card is in flight: the button waits
	onAction: () -> (),
	onOpen: () -> (),
}

local config = Goals.card

-- One line of text that shrinks to fit, then cuts off.
local function line(props: { text: string, order: number, size: number, font: Font, color: Color3 })
	return e("TextLabel", {
		LayoutOrder = props.order,
		Size = UDim2.new(1, 0, 0, props.size + 3),
		BackgroundTransparency = 1,
		FontFace = props.font,
		Text = props.text,
		TextColor3 = props.color,
		TextScaled = true,
		TextTruncate = Enum.TextTruncate.AtEnd,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Center,
	}, {
		Limit = e("UITextSizeConstraint", { MaxTextSize = props.size, MinTextSize = config.minTextSize }),
	})
end

local function bar(order: number, progress: number)
	return e("Frame", {
		LayoutOrder = order,
		Size = UDim2.new(1, 0, 0, config.barHeight),
		BackgroundColor3 = colors.track,
		BorderSizePixel = 0,
	}, {
		Corner = e("UICorner", { CornerRadius = UDim.new(0.5, 0) }),
		Fill = e("Frame", {
			Size = UDim2.fromScale(math.clamp(progress, 0, 1), 1),
			BackgroundColor3 = colors.accent,
			BorderSizePixel = 0,
		}, {
			Corner = e("UICorner", { CornerRadius = UDim.new(0.5, 0) }),
		}),
	})
end

local function Pill(props: Props)
	return e("TextButton", {
		Position = UDim2.fromOffset(props.rect.left, props.rect.top),
		Size = UDim2.fromOffset(Layout.width(props.rect), Layout.height(props.rect)),
		BackgroundColor3 = colors.panel,
		BackgroundTransparency = colors.panelTransparency,
		BorderSizePixel = 0,
		AutoButtonColor = true,
		FontFace = Theme.fonts.bold,
		Text = props.card.title,
		TextColor3 = colors.text,
		TextSize = config.titleTextSize,
		[React.Event.Activated] = function()
			props.onOpen()
		end,
	}, {
		Corner = e("UICorner", { CornerRadius = UDim.new(0, config.cornerRadius) }),
		-- A thin accent edge marks it as goals at a glance (well over 3:1 against the panel).
		Edge = e("UIStroke", {
			ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
			Color = colors.accent,
			Thickness = 1,
		}),
	})
end

local function CardPanel(props: Props)
	local card = props.card
	local compact = props.shape == "compact"
	local pad = if compact then config.compactPadding else config.padding
	local width, height = Layout.width(props.rect), Layout.height(props.rect)
	local label = if compact then card.shortLabel or card.actionLabel else card.actionLabel
	local progress = if compact then nil else card.progress
	-- The words' box: above the button on the tall card, left of it on the compact one.
	local wordsSize = if compact
		then UDim2.fromOffset(
			width - 4 * pad - (if label ~= nil then config.compactActionWidth else 0),
			height - 2 * pad
		)
		else UDim2.fromOffset(
			width - 2 * pad,
			height - 2 * pad - (if label ~= nil then config.actionHeight + pad else 0)
		)
	return e("Frame", {
		Position = UDim2.fromOffset(props.rect.left, props.rect.top),
		Size = UDim2.fromOffset(width, height),
		BackgroundColor3 = colors.panel,
		BackgroundTransparency = colors.panelTransparency,
		BorderSizePixel = 0,
	}, {
		Corner = e("UICorner", { CornerRadius = UDim.new(0, config.cornerRadius) }),
		-- The words are one button: they open the list.
		Words = e("TextButton", {
			Position = UDim2.fromOffset(pad + (if compact then pad else 0), pad),
			Size = wordsSize,
			BackgroundTransparency = 1,
			AutoButtonColor = false,
			Text = "",
			[React.Event.Activated] = function()
				props.onOpen()
			end,
		}, {
			Layout = e("UIListLayout", {
				FillDirection = Enum.FillDirection.Vertical,
				VerticalAlignment = Enum.VerticalAlignment.Center,
				SortOrder = Enum.SortOrder.LayoutOrder,
				Padding = UDim.new(0, 2),
			}),
			Eyebrow = line({
				text = if compact then card.shortEyebrow else card.eyebrow,
				order = 1,
				size = config.eyebrowTextSize,
				font = Theme.fonts.medium,
				color = colors.accent,
			}),
			Title = line({
				text = card.title,
				order = 2,
				size = config.titleTextSize,
				font = Theme.fonts.bold,
				color = colors.text,
			}),
			Bar = if progress ~= nil then bar(3, progress) else nil,
		}),
		Action = if label ~= nil
			then e(Kit.Button, {
				label = label,
				style = "primary",
				disabled = props.busy,
				anchor = if compact then Vector2.new(1, 0.5) else Vector2.new(0.5, 1),
				position = if compact then UDim2.new(1, -pad, 0.5, 0) else UDim2.new(0.5, 0, 1, -pad),
				size = if compact
					then UDim2.fromOffset(config.compactActionWidth, config.actionHeight)
					else UDim2.new(1, -2 * pad, 0, config.actionHeight),
				textSize = if compact then Theme.text.small else nil,
				onTap = props.onAction,
			})
			else nil,
	})
end

local function GoalCard(props: Props)
	if props.card.kind == "pill" then
		return e(Pill, props)
	end
	return e(CardPanel, props)
end

return GoalCard
