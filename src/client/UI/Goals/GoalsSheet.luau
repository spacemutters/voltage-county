--!strict
-- The goals list (roast fixes 2026-10-24; Controllers/GoalsController opens it from the card and fills it):
--
--   header         "Goals" and Close.
--   Getting started  while the first-session path runs: its three steps in order, each with its bonus, the one
--                  being done now marked, the paid ones marked done; then "Skip these steps". Skipping ends the
--                  path for good and its bonuses with it, so it takes two taps: the first asks "Skip for good?"
--                  with Keep them and Skip; only Skip calls onSkip.
--   Today          the three daily goals: title, one detail line, a progress bar with "1.2 / 3 miles", and on the
--                  right Collect (at the target), Done (collected), Go (a goal with a place: the GPS) or the reward.
--   footer         when the goals reset ("New goals in 5 h 12 min").
--
-- Presentation only: the controller passes the rows (GoalsController.rowsFor) and the callbacks. The sheet goes where
-- UI/Phone/Layout.sheet puts a phone sheet (never over the touch pedals or steering), dimming the screen behind it
-- when Layout asks (a tap there closes it). Every button is at least Theme.size.touchTarget tall.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local React = require(ReplicatedStorage.Packages.React)
local Goals = require(ReplicatedStorage.Shared.Config.Goals)

local Kit = require(script.Parent.Parent.Phone.Kit)
local Layout = require(script.Parent.Parent.Phone.Layout)
local Theme = require(script.Parent.Parent.Theme)

local e = React.createElement
local colors = Theme.colors

-- One step of the path as the list shows it.
export type StepRow = {
	id: string,
	title: string,
	note: string, -- "$3,000 bonus", "Now · $3,000 bonus", "Done · +$3,000"
	current: boolean,
	claimed: boolean,
}

-- One of today's goals as the list shows it.
export type DailyRow = {
	id: string,
	title: string,
	detail: string,
	progress: number, -- 0..1
	progressText: string, -- "1.2 / 3 miles"
	reward: string, -- "$1,500"
	ready: boolean, -- at its target, not collected
	claimed: boolean,
	canGo: boolean, -- has a place the GPS can lead to
}

export type Props = {
	sheet: Layout.Sheet,
	steps: { StepRow }?, -- nil once the path is done
	daily: { DailyRow },
	resetText: string?,
	busyId: string?, -- the goal a request is in flight for
	onClose: () -> (),
	onClaim: (goalId: string) -> (),
	onGo: (goalId: string) -> (),
	onSkip: () -> (),
}

local config = Goals.sheet
local text = Goals.text

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

local function StepCard(props: { row: StepRow, order: number })
	local row = props.row
	return e(Kit.Card, { order = props.order, gap = Theme.spacing.xs, padding = config.rowPadding }, {
		Title = e(Kit.Text, {
			text = row.title,
			order = 1,
			font = Theme.fonts.bold,
			color = if row.claimed then colors.textDim else colors.text,
		}),
		Note = e(Kit.Text, {
			text = row.note,
			order = 2,
			size = Theme.text.small,
			color = if row.current then colors.accent else colors.textDim,
		}),
	})
end

-- The right-hand control of a daily goal: Collect, Done, Go or the reward.
local function dailyControl(props: Props, row: DailyRow): any
	local busy = props.busyId == row.id
	if row.ready then
		return e(Kit.Button, {
			label = string.format(text.collect, row.reward),
			style = "primary",
			disabled = busy,
			size = UDim2.fromOffset(config.collectButtonWidth, Theme.size.touchTarget),
			textSize = Theme.text.small,
			onTap = function()
				props.onClaim(row.id)
			end,
		})
	elseif row.claimed then
		return e(Kit.Pill, { text = text.done, color = Theme.colors.success })
	elseif row.canGo then
		return e(Kit.Button, {
			label = text.go,
			size = UDim2.fromOffset(config.goButtonWidth, Theme.size.touchTarget),
			textSize = Theme.text.small,
			onTap = function()
				props.onGo(row.id)
			end,
		})
	end
	return e(Kit.Pill, { text = row.reward })
end

local function DailyCard(props: { parent: Props, row: DailyRow, order: number })
	local row = props.row
	return e(Kit.Card, { order = props.order, gap = Theme.spacing.xs, padding = config.rowPadding }, {
		Title = e(Kit.Text, { text = row.title, order = 1, font = Theme.fonts.bold }),
		Detail = e(Kit.Text, { text = row.detail, order = 2, size = Theme.text.small, color = colors.textDim }),
		Bar = bar(3, row.progress),
		Footer = e("Frame", {
			LayoutOrder = 4,
			Size = UDim2.new(1, 0, 0, Theme.size.touchTarget),
			BackgroundTransparency = 1,
		}, {
			Progress = e("TextLabel", {
				AnchorPoint = Vector2.new(0, 0.5),
				Position = UDim2.fromScale(0, 0.5),
				Size = UDim2.new(1, -config.collectButtonWidth - Theme.spacing.sm, 1, 0),
				BackgroundTransparency = 1,
				FontFace = Theme.fonts.medium,
				Text = row.progressText,
				TextColor3 = colors.textDim,
				TextSize = Theme.text.small,
				TextTruncate = Enum.TextTruncate.AtEnd,
				TextXAlignment = Enum.TextXAlignment.Left,
			}),
			Control = e("Frame", {
				AnchorPoint = Vector2.new(1, 0.5),
				Position = UDim2.fromScale(1, 0.5),
				Size = UDim2.new(0, config.collectButtonWidth, 1, 0),
				BackgroundTransparency = 1,
			}, {
				Layout = e("UIListLayout", {
					FillDirection = Enum.FillDirection.Horizontal,
					HorizontalAlignment = Enum.HorizontalAlignment.Right,
					VerticalAlignment = Enum.VerticalAlignment.Center,
				}),
				Item = dailyControl(props.parent, row),
			}),
		}),
	})
end

local function GoalsSheet(props: Props)
	-- "Skip these steps" was tapped once: ask before skipping for good (reset when the list closes).
	local confirmSkip, setConfirmSkip = React.useState(false)
	local rect = props.sheet.rect
	local pad = Theme.spacing.lg
	local children: { [string]: any } = {}
	local order = 0
	local function add(key: string, element: any)
		order += 1
		children[key] = element
	end

	local steps = props.steps
	if steps ~= nil then
		add("PathTitle", e(Kit.SectionTitle, { text = text.pathSection, order = order + 1 }))
		for index, row in steps do
			add(`Step{index}`, e(StepCard, { row = row, order = order + 1 }))
		end
		if confirmSkip then
			add(
				"SkipQuestion",
				e(Kit.Text, {
					text = text.skipConfirm,
					order = order + 1,
					size = Theme.text.small,
					color = colors.textDim,
				})
			)
			add(
				"SkipChoice",
				Kit.ButtonRow({
					order = order + 1,
					count = 2,
					buttons = {
						Keep = e(Kit.Button, {
							label = text.skipKeep,
							order = 1,
							style = "primary",
							onTap = function()
								setConfirmSkip(false)
							end,
						}),
						Skip = e(Kit.Button, {
							label = text.skipForGood,
							order = 2,
							style = "dangerText",
							onTap = props.onSkip,
						}),
					},
				})
			)
		else
			add(
				"Skip",
				e(Kit.Button, {
					label = text.skip,
					order = order + 1,
					onTap = function()
						setConfirmSkip(true)
					end,
				})
			)
		end
	end
	if #props.daily > 0 then
		add("DailyTitle", e(Kit.SectionTitle, { text = text.dailySection, order = order + 1 }))
		for index, row in props.daily do
			add(`Daily{index}`, e(DailyCard, { parent = props, row = row, order = order + 1 }))
		end
	end
	if props.resetText ~= nil then
		add(
			"Reset",
			e(Kit.Text, {
				text = props.resetText,
				order = order + 1,
				size = Theme.text.small,
				color = colors.textDim,
				align = Enum.TextXAlignment.Center,
			})
		)
	end

	return e("Frame", {
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
	}, {
		Scrim = if props.sheet.scrim
			then e("TextButton", {
				Size = UDim2.fromScale(1, 1),
				BackgroundColor3 = colors.scrim,
				BackgroundTransparency = colors.scrimTransparency,
				BorderSizePixel = 0,
				AutoButtonColor = false,
				Text = "",
				[React.Event.Activated] = function()
					props.onClose()
				end,
			})
			else nil,
		Sheet = e("Frame", {
			Position = Layout.position(rect),
			Size = Layout.size(rect),
			BackgroundColor3 = colors.panel,
			BorderSizePixel = 0,
			ZIndex = 2,
		}, {
			Corner = e("UICorner", { CornerRadius = UDim.new(0, Theme.radius.sheet) }),
			Header = e("Frame", {
				Size = UDim2.new(1, 0, 0, config.headerHeight),
				BackgroundTransparency = 1,
			}, {
				Title = e("TextLabel", {
					Position = UDim2.fromOffset(pad, 0),
					Size = UDim2.new(1, -2 * pad - config.closeSize.X, 1, 0),
					BackgroundTransparency = 1,
					FontFace = Theme.fonts.bold,
					Text = text.listTitle,
					TextColor3 = colors.text,
					TextSize = Theme.text.title,
					TextXAlignment = Enum.TextXAlignment.Left,
				}),
				Close = e(Kit.Button, {
					label = text.close,
					anchor = Vector2.new(1, 0.5),
					position = UDim2.new(1, -pad, 0.5, 0),
					size = UDim2.fromOffset(config.closeSize.X, config.closeSize.Y),
					onTap = props.onClose,
				}),
			}),
			Body = e("Frame", {
				Position = UDim2.fromOffset(0, config.headerHeight),
				Size = UDim2.new(1, 0, 1, -config.headerHeight),
				BackgroundTransparency = 1,
			}, {
				Page = e(Kit.Page, { gap = Theme.spacing.sm }, children),
			}),
		}),
	})
end

return GoalsSheet
