--!strict
-- The admin panel (PLAN.md Phase 12 "Admin tools"): a small "Admin" button and, when open, a sheet with the players
-- in this server (Kick, which asks for a second tap, and Put car away), Hide a design or mod (by its id), the recent
-- server log with the latest design reports and analytics events, and, in Studio only, buttons that set your own
-- cash and credits. Presentation only: Controllers/AdminController owns the state and talks to the server (Net
-- AdminAction, and in Studio DevSetCash / DevCredits), and mounts this only for Config/Admins users. Built from the
-- phone's kit (UI/Phone/Kit) in the one look (UI/Theme); every tappable thing is at least 44 px.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local React = require(ReplicatedStorage.Packages.React)

local Kit = require(script.Parent.Parent.Phone.Kit)
local Theme = require(script.Parent.Parent.Theme)
local AdminStyle = require(script.Parent.AdminStyle)

local e = React.createElement
local colors = Theme.colors
local words = AdminStyle.text

export type PlayerRow = { userId: number, name: string }
export type LogLine = { at: number, kind: string, text: string }

export type Props = {
	scale: number, -- UI scale (Controllers/HudController.scaleFor)
	open: boolean,
	busy: boolean, -- a request is with the server
	status: string?, -- the server's last answer
	players: { PlayerRow },
	selfUserId: number,
	confirmKick: number?, -- the player whose Kick button waits for its second tap
	logs: { LogLine },
	reports: { string }, -- one line per design report
	events: { string }, -- one line per analytics event
	studio: boolean,
	onToggle: () -> (),
	onKick: (userId: number) -> (),
	onDespawn: (userId: number) -> (),
	onRefresh: () -> (),
	onHide: (ref: string) -> (),
	onCash: (amount: number) -> (),
	onCredits: (amount: number) -> (),
}

-- "$1,000,000"
local function money(amount: number): string
	local digits = tostring(math.floor(amount))
	local grouped = string.reverse((string.gsub(string.reverse(digits), "(%d%d%d)", "%1,")))
	if string.sub(grouped, 1, 1) == "," then
		grouped = string.sub(grouped, 2)
	end
	return "$" .. grouped
end

local function clock(at: number): string
	return os.date("!%H:%M:%S", at)
end

local function PlayerCard(props: {
	row: PlayerRow,
	order: number,
	isSelf: boolean,
	confirming: boolean,
	busy: boolean,
	onKick: (userId: number) -> (),
	onDespawn: (userId: number) -> (),
})
	local row = props.row
	local name = if props.isSelf then `{row.name} {words.you}` else row.name
	return Kit.Card({ order = props.order }, {
		Name = Kit.Text({ text = name, order = 1, font = Theme.fonts.bold }),
		Id = Kit.Text({ text = tostring(row.userId), order = 2, size = Theme.text.small, color = colors.textDim }),
		Buttons = Kit.ButtonRow({
			order = 3,
			count = 2,
			buttons = {
				Kick = e(Kit.Button, {
					label = if props.confirming then words.confirmKick else words.kick,
					style = if props.confirming then "danger" else "dangerText",
					disabled = props.busy or props.isSelf,
					order = 1,
					onTap = function()
						props.onKick(row.userId)
					end,
				}),
				Despawn = e(Kit.Button, {
					label = words.despawn,
					disabled = props.busy,
					order = 2,
					onTap = function()
						props.onDespawn(row.userId)
					end,
				}),
			},
		}),
	})
end

local function HideBox(props: { order: number, busy: boolean, onHide: (ref: string) -> () })
	local box = React.useRef(nil :: TextBox?)
	local function submit()
		local current = box.current
		if current ~= nil and not props.busy then
			props.onHide(current.Text)
		end
	end
	return Kit.Card({ order = props.order }, {
		Title = Kit.Text({ text = words.hide, order = 1, font = Theme.fonts.bold }),
		Input = e("TextBox", {
			LayoutOrder = 2,
			Size = UDim2.new(1, 0, 0, Theme.size.buttonHeight),
			BackgroundColor3 = colors.panel,
			BorderSizePixel = 0,
			ClearTextOnFocus = false,
			FontFace = Theme.fonts.medium,
			PlaceholderText = words.hideHint,
			PlaceholderColor3 = colors.textDim,
			Text = "",
			TextColor3 = colors.text,
			TextSize = Theme.text.body,
			TextTruncate = Enum.TextTruncate.AtEnd,
			TextXAlignment = Enum.TextXAlignment.Left,
			ref = box,
			[React.Event.FocusLost] = function(_rbx: TextBox, enterPressed: boolean)
				if enterPressed then
					submit()
				end
			end,
		}, {
			Corner = e("UICorner", { CornerRadius = UDim.new(0, Theme.radius.button) }),
			Padding = e("UIPadding", {
				PaddingLeft = UDim.new(0, Theme.spacing.md),
				PaddingRight = UDim.new(0, Theme.spacing.md),
			}),
		}),
		Hide = e(Kit.Button, {
			label = words.hideButton,
			style = "danger",
			disabled = props.busy,
			order = 3,
			onTap = submit,
		}),
	})
end

local function lines(list: { string }, order: number, title: string, limit: number)
	local children: { [string]: any } = {
		Title = Kit.Text({ text = title, order = 0, font = Theme.fonts.bold }),
	}
	local first = math.max(1, #list - limit + 1)
	for index = first, #list do
		children[`Line{index}`] = Kit.Text({ text = list[index], order = index, size = Theme.text.small })
	end
	if #list == 0 then
		children.Empty = Kit.Text({ text = words.empty, order = 1, size = Theme.text.small, color = colors.textDim })
	end
	return Kit.Card({ order = order, gap = Theme.spacing.xs }, children)
end

local function Body(props: Props)
	local children: { [string]: any } = {}
	local order = 0
	local function nextOrder(): number
		order += 1
		return order
	end
	if props.busy or props.status ~= nil then
		children.Status = Kit.Text({
			text = if props.busy then words.working else props.status or "",
			order = nextOrder(),
			color = colors.textDim,
		})
	end
	children.PlayersTitle = Kit.SectionTitle({ text = words.players, order = nextOrder() })
	for _, row in props.players do
		children[`Player{row.userId}`] = e(PlayerCard, {
			row = row,
			order = nextOrder(),
			isSelf = row.userId == props.selfUserId,
			confirming = props.confirmKick == row.userId,
			busy = props.busy,
			onKick = props.onKick,
			onDespawn = props.onDespawn,
		})
	end
	children.Hide = e(HideBox, { order = nextOrder(), busy = props.busy, onHide = props.onHide })
	children.LogTitle = Kit.SectionTitle({ text = words.log, order = nextOrder() })
	children.Refresh = e(Kit.Button, {
		label = words.refresh,
		style = "primary",
		disabled = props.busy,
		order = nextOrder(),
		onTap = props.onRefresh,
	})
	local logText: { string } = {}
	for _, line in props.logs do
		table.insert(logText, `{clock(line.at)} {line.kind}: {line.text}`)
	end
	children.Log = lines(logText, nextOrder(), words.serverLog, AdminStyle.logLinesShown)
	children.Reports = lines(props.reports, nextOrder(), words.reports, AdminStyle.reportsShown)
	children.Events = lines(props.events, nextOrder(), words.events, AdminStyle.eventsShown)
	if props.studio then
		children.StudioTitle = Kit.SectionTitle({ text = words.studio, order = nextOrder() })
		local cash: { [string]: any } = {}
		for index, amount in AdminStyle.studioCash do
			cash[`Cash{index}`] = e(Kit.Button, {
				label = string.format(words.cash, money(amount)),
				disabled = props.busy,
				order = index,
				textSize = Theme.text.small,
				onTap = function()
					props.onCash(amount)
				end,
			})
		end
		children.Cash = Kit.ButtonRow({ order = nextOrder(), count = #AdminStyle.studioCash, buttons = cash })
		local credits: { [string]: any } = {}
		for index, amount in AdminStyle.studioCredits do
			credits[`Credits{index}`] = e(Kit.Button, {
				label = string.format(words.credits, amount),
				disabled = props.busy,
				order = index,
				onTap = function()
					props.onCredits(amount)
				end,
			})
		end
		children.Credits = Kit.ButtonRow({ order = nextOrder(), count = #AdminStyle.studioCredits, buttons = credits })
	end
	return Kit.Page({}, children)
end

local function Sheet(props: Props)
	local sheet = AdminStyle.sheet
	local margin = sheet.margin
	return e("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.new(1, -2 * margin, Theme.size.sheetMaxHeightScale, 0),
		BackgroundColor3 = colors.panel,
		BackgroundTransparency = colors.panelTransparency,
		BorderSizePixel = 0,
		Active = true,
	}, {
		Corner = e("UICorner", { CornerRadius = UDim.new(0, Theme.radius.sheet) }),
		MaxWidth = e("UISizeConstraint", { MaxSize = Vector2.new(Theme.size.sheetMaxWidth, math.huge) }),
		Header = e("Frame", {
			Size = UDim2.new(1, 0, 0, sheet.headerHeight),
			BackgroundTransparency = 1,
		}, {
			Title = e("TextLabel", {
				AnchorPoint = Vector2.new(0, 0.5),
				Position = UDim2.new(0, Theme.spacing.lg, 0.5, 0),
				Size = UDim2.new(1, -(2 * Theme.spacing.lg + sheet.closeSize.X), 1, 0),
				BackgroundTransparency = 1,
				FontFace = Theme.fonts.bold,
				Text = words.title,
				TextColor3 = colors.text,
				TextSize = Theme.text.title,
				TextXAlignment = Enum.TextXAlignment.Left,
			}),
			Close = e(Kit.Button, {
				label = words.close,
				anchor = Vector2.new(1, 0.5),
				position = UDim2.new(1, -Theme.spacing.sm, 0.5, 0),
				size = UDim2.fromOffset(sheet.closeSize.X, sheet.closeSize.Y),
				onTap = props.onToggle,
			}),
		}),
		Content = e("Frame", {
			Position = UDim2.fromOffset(0, sheet.headerHeight),
			Size = UDim2.new(1, 0, 1, -sheet.headerHeight),
			BackgroundTransparency = 1,
		}, {
			Body = e(Body, props),
		}),
	})
end

local function AdminPanel(props: Props)
	local toggle = AdminStyle.toggle
	local children: { [string]: any } = {
		Scale = e("UIScale", { Scale = props.scale }),
		Toggle = e(Kit.Button, {
			label = words.toggle,
			style = if props.open then "primary" else "secondary",
			position = UDim2.fromOffset(toggle.position.X, toggle.position.Y),
			size = UDim2.fromOffset(toggle.size.X, toggle.size.Y),
			onTap = props.onToggle,
		}),
	}
	if props.open then
		children.Scrim = e("TextButton", {
			Size = UDim2.fromScale(1, 1),
			BackgroundColor3 = colors.scrim,
			BackgroundTransparency = colors.scrimTransparency,
			BorderSizePixel = 0,
			AutoButtonColor = false,
			Text = "",
			ZIndex = 2,
			[React.Event.Activated] = props.onToggle,
		})
		children.Sheet = e("Frame", {
			Size = UDim2.fromScale(1, 1),
			BackgroundTransparency = 1,
			ZIndex = 3,
		}, {
			Sheet = e(Sheet, props),
		})
	end
	return e("Frame", {
		Size = UDim2.fromScale(1 / props.scale, 1 / props.scale),
		BackgroundTransparency = 1,
	}, children)
end

return AdminPanel
