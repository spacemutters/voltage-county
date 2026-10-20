--!strict
-- The phone (docs/phase-4-contracts.md "Client UI"): the phone button and the phone sheet with its home screen
-- of apps. PhoneController decides where both go (UI/Phone/Layout), which app shows and what it shows; this
-- component only draws them:
--
--   phone button   a small rounded button with a phone drawn on it, and on keyboard and gamepad the key that
--                  opens the phone in its corner. Filled with the accent while the phone is open.
--   dimming        behind the sheet when Layout asks for it (on foot); a tap on it closes the phone.
--   sheet          slides up from the bottom of the screen. A header (Back inside an app, the title, Close),
--                  then the home screen's app grid or the open app.
--
-- On a gamepad the first app (or the Back button inside an app) is selected when the phone opens, so the D-pad
-- moves around it straight away. Draw order: button, dimming, sheet, so an open sheet covers the button.

local GuiService = game:GetService("GuiService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local React = require(ReplicatedStorage.Packages.React)

local Glyph = require(script.Parent.Glyphs)
local Kit = require(script.Parent.Kit)
local Layout = require(script.Parent.Layout)
local PhoneConfig = require(script.Parent.PhoneConfig)
local Theme = require(script.Parent.Parent.Theme)

local e = React.createElement
local colors = Theme.colors

export type InputKind = "keyboard" | "gamepad" | "touch"

export type Props = {
	screen: Vector2, -- the screen in UI-scale-1 pixels
	button: Layout.Rect,
	sheet: Layout.Sheet,
	inputKind: InputKind,
	open: boolean, -- the sheet is showing (or sliding out)
	leaving: boolean, -- the sheet is sliding out
	app: PhoneConfig.AppId?, -- nil: the home screen
	title: string, -- the header title
	body: any, -- the open app's element (ignored on the home screen)
	routeActive: boolean, -- marks the GPS icon
	onToggle: () -> (),
	onClose: () -> (),
	onBack: () -> (),
	onOpenApp: (id: PhoneConfig.AppId) -> (),
}

-- The phone button --------------------------------------------------------------------------------------------

local function PhoneButton(props: { rect: Layout.Rect, open: boolean, inputKind: InputKind, onTap: () -> () })
	local config = PhoneConfig.button
	local ink = if props.open then colors.onAccent else colors.text
	local fill = if props.open then colors.accent else colors.panel
	local keyText = if props.inputKind == "touch" then nil else PhoneConfig.keyGlyphs[props.inputKind]
	return e("TextButton", {
		Position = Layout.position(props.rect),
		Size = Layout.size(props.rect),
		BackgroundColor3 = fill,
		BackgroundTransparency = if props.open then 0 else colors.panelTransparency,
		BorderSizePixel = 0,
		AutoButtonColor = true,
		Selectable = false,
		Text = "",
		[React.Event.Activated] = function()
			props.onTap()
		end,
	}, {
		Corner = e("UICorner", { CornerRadius = UDim.new(0, config.cornerRadius) }),
		Glyph = e(Glyph, { name = "phone", color = ink, background = fill, size = config.glyphSize }),
		Key = if keyText
			then e("TextLabel", {
				AnchorPoint = Vector2.new(1, 0),
				Position = UDim2.new(1, -config.badgeInset, 0, config.badgeInset),
				Size = UDim2.fromOffset(config.badgeSize, config.badgeSize),
				AutomaticSize = Enum.AutomaticSize.X,
				BackgroundColor3 = colors.panelRaised,
				BorderSizePixel = 0,
				FontFace = Theme.fonts.bold,
				Text = keyText,
				TextColor3 = colors.text,
				TextSize = config.badgeTextSize,
			}, {
				Corner = e("UICorner", { CornerRadius = UDim.new(0, Theme.spacing.xs) }),
				Padding = e("UIPadding", {
					PaddingLeft = UDim.new(0, Theme.spacing.xs),
					PaddingRight = UDim.new(0, Theme.spacing.xs),
				}),
			})
			else nil,
	})
end

-- The home screen ----------------------------------------------------------------------------------------------

local function AppTile(props: {
	app: PhoneConfig.App,
	order: number,
	badge: boolean,
	onOpen: (id: PhoneConfig.AppId) -> (),
	tileRef: any?,
})
	local grid = PhoneConfig.grid
	return e("TextButton", {
		LayoutOrder = props.order,
		BackgroundTransparency = 1,
		AutoButtonColor = false,
		Text = "",
		ref = props.tileRef,
		[React.Event.Activated] = function()
			props.onOpen(props.app.id)
		end,
	}, {
		Icon = e("Frame", {
			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.fromScale(0.5, 0),
			Size = UDim2.fromOffset(grid.iconSize, grid.iconSize),
			BackgroundColor3 = colors.panelRaised,
			BorderSizePixel = 0,
		}, {
			Corner = e("UICorner", { CornerRadius = UDim.new(0, Theme.radius.card) }),
			Glyph = e(Glyph, {
				name = props.app.id,
				color = colors.text,
				background = colors.panelRaised,
				size = Vector2.new(grid.glyphSize, grid.glyphSize),
			}),
			Badge = if props.badge
				then e("Frame", {
					AnchorPoint = Vector2.new(0.5, 0.5),
					Position = UDim2.new(1, -Theme.spacing.sm, 0, Theme.spacing.sm),
					Size = UDim2.fromOffset(grid.badgeSize, grid.badgeSize),
					BackgroundColor3 = colors.accent,
					BorderSizePixel = 0,
				}, {
					Corner = e("UICorner", { CornerRadius = UDim.new(0.5, 0) }),
				})
				else nil,
		}),
		Label = e("TextLabel", {
			AnchorPoint = Vector2.new(0.5, 1),
			Position = UDim2.fromScale(0.5, 1),
			Size = UDim2.new(1, 0, 0, grid.labelHeight),
			BackgroundTransparency = 1,
			FontFace = Theme.fonts.medium,
			Text = props.app.label,
			TextColor3 = colors.text,
			TextSize = Theme.text.small,
			TextTruncate = Enum.TextTruncate.AtEnd,
		}),
	})
end

local function Home(props: {
	width: number,
	routeActive: boolean,
	onOpenApp: (id: PhoneConfig.AppId) -> (),
	focusRef: any,
})
	local grid = PhoneConfig.grid
	local columns = Layout.gridColumns(props.width)
	local tiles: { [string]: any } = {
		Grid = e("UIGridLayout", {
			CellSize = UDim2.fromOffset(grid.iconSize, grid.iconSize + Theme.spacing.xs + grid.labelHeight),
			CellPadding = UDim2.fromOffset(grid.columnGap, grid.rowGap),
			FillDirectionMaxCells = columns,
			HorizontalAlignment = Enum.HorizontalAlignment.Center,
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
	}
	for index, app in PhoneConfig.apps do
		tiles[`App_{app.id}`] = e(AppTile, {
			app = app,
			order = index,
			badge = app.id == "gps" and props.routeActive,
			onOpen = props.onOpenApp,
			tileRef = if index == 1 then props.focusRef else nil,
		})
	end
	return Kit.Page({}, {
		Tiles = e("Frame", {
			Size = UDim2.fromScale(1, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
		}, tiles),
	})
end

-- The header ---------------------------------------------------------------------------------------------------

-- An "X" drawn from two crossed bars, in a box `size` px square.
local function Cross(props: { color: Color3, size: number, thickness: number })
	local function bar(rotation: number)
		return e("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromOffset(props.thickness, props.size * math.sqrt(2)),
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
		A = bar(45),
		B = bar(-45),
	})
end

-- A round, borderless icon button (Back, Close), a full touch target.
local function IconButton(props: {
	anchor: Vector2,
	position: UDim2,
	raised: boolean,
	onTap: () -> (),
	buttonRef: any?,
	icon: any,
})
	local target = Theme.size.touchTarget
	return e("TextButton", {
		AnchorPoint = props.anchor,
		Position = props.position,
		Size = UDim2.fromOffset(target, target),
		BackgroundColor3 = colors.panelRaised,
		BackgroundTransparency = if props.raised then 0 else 1,
		BorderSizePixel = 0,
		AutoButtonColor = true,
		Text = "",
		ref = props.buttonRef,
		[React.Event.Activated] = function()
			props.onTap()
		end,
	}, {
		Corner = e("UICorner", { CornerRadius = UDim.new(0.5, 0) }),
		Icon = props.icon,
	})
end

-- Back (inside an app) on the left, the title beside it, Close on the right; a small handle above them.
local function Header(props: {
	title: string,
	inApp: boolean,
	onBack: () -> (),
	onClose: () -> (),
	backRef: any,
})
	local sheet = PhoneConfig.sheet
	local inset = Theme.spacing.sm
	local target = Theme.size.touchTarget
	local titleLeft = if props.inApp then inset + target + Theme.spacing.xs else sheet.padding
	local titleRight = inset + target + Theme.spacing.sm
	return e("Frame", {
		Size = UDim2.new(1, 0, 0, sheet.headerHeight),
		BackgroundTransparency = 1,
	}, {
		Grabber = e("Frame", {
			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.new(0.5, 0, 0, Theme.spacing.xs),
			Size = UDim2.fromOffset(sheet.grabberSize.X, sheet.grabberSize.Y),
			BackgroundColor3 = colors.divider,
			BorderSizePixel = 0,
		}, {
			Corner = e("UICorner", { CornerRadius = UDim.new(0.5, 0) }),
		}),
		Back = if props.inApp
			then e(IconButton, {
				anchor = Vector2.new(0, 0.5),
				position = UDim2.new(0, inset, 0.5, 0),
				raised = false,
				onTap = props.onBack,
				buttonRef = props.backRef,
				icon = Kit.Chevron({ direction = -1, color = colors.accent, size = sheet.iconSize }),
			})
			else nil,
		Title = e("TextLabel", {
			Position = UDim2.fromOffset(titleLeft, 0),
			Size = UDim2.new(1, -(titleLeft + titleRight), 1, 0),
			BackgroundTransparency = 1,
			FontFace = Theme.fonts.bold,
			Text = props.title,
			TextColor3 = colors.text,
			TextSize = Theme.text.title,
			TextTruncate = Enum.TextTruncate.AtEnd,
			TextXAlignment = Enum.TextXAlignment.Left,
		}),
		Close = e(IconButton, {
			anchor = Vector2.new(1, 0.5),
			position = UDim2.new(1, -inset, 0.5, 0),
			raised = true,
			onTap = props.onClose,
			icon = e(Cross, { color = colors.text, size = sheet.iconSize, thickness = sheet.iconLine }),
		}),
	})
end

-- The sheet ----------------------------------------------------------------------------------------------------

local function Sheet(props: Props)
	local fade = Kit.useAppear(props.leaving)
	local focusRef = React.useRef(nil :: GuiObject?)
	local backRef = React.useRef(nil :: GuiObject?)
	local rect = props.sheet.rect
	local inApp = props.app ~= nil

	-- Gamepad: select the first app, or Back inside an app, whenever the screen changes. Let go on close.
	React.useEffect(function()
		if props.inputKind == "gamepad" and not props.leaving then
			local target = if inApp then backRef.current else focusRef.current
			if target then
				GuiService.SelectedObject = target
			end
		end
	end, { props.app, props.inputKind, props.leaving } :: { any })
	React.useEffect(function()
		return function()
			local selected = GuiService.SelectedObject
			if selected and (selected == focusRef.current or selected == backRef.current) then
				GuiService.SelectedObject = nil
			end
		end
	end, {})

	local headerHeight = PhoneConfig.sheet.headerHeight
	local drop = props.screen.Y - rect.top -- far enough to start fully below the screen
	local scrimTransparency = colors.scrimTransparency
	return e("Frame", {
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		ZIndex = 2,
	}, {
		Scrim = if props.sheet.scrim
			then e("TextButton", {
				Size = UDim2.fromScale(1, 1),
				BackgroundColor3 = colors.scrim,
				BackgroundTransparency = fade:map(function(value: number): number
					return scrimTransparency + (1 - scrimTransparency) * value
				end),
				BorderSizePixel = 0,
				AutoButtonColor = false,
				Selectable = false,
				Text = "",
				[React.Event.Activated] = function()
					props.onClose()
				end,
			})
			else nil,
		Sheet = e("Frame", {
			ZIndex = 2,
			Position = fade:map(function(value: number): UDim2
				return UDim2.fromOffset(rect.left, rect.top + value * drop)
			end),
			Size = Layout.size(rect),
			BackgroundColor3 = colors.panel,
			BackgroundTransparency = colors.panelTransparency,
			BorderSizePixel = 0,
			Active = true, -- taps on the sheet never fall through to the world or the controls
			ClipsDescendants = true,
		}, {
			Corner = e("UICorner", { CornerRadius = UDim.new(0, Theme.radius.sheet) }),
			Header = e(Header, {
				title = props.title,
				inApp = inApp,
				onBack = props.onBack,
				onClose = props.onClose,
				backRef = backRef,
			}),
			Body = e("Frame", {
				Position = UDim2.fromOffset(0, headerHeight),
				Size = UDim2.new(1, 0, 1, -headerHeight),
				BackgroundTransparency = 1,
			}, {
				Screen = if inApp
					then props.body
					else e(Home, {
						width = Layout.width(rect),
						routeActive = props.routeActive,
						onOpenApp = props.onOpenApp,
						focusRef = focusRef,
					}),
			}),
		}),
	})
end

local function Phone(props: Props)
	return e("Frame", {
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
	}, {
		Button = e(PhoneButton, {
			rect = props.button,
			open = props.open and not props.leaving,
			inputKind = props.inputKind,
			onTap = props.onToggle,
		}),
		Open = if props.open then e(Sheet, props) else nil,
	})
end

return Phone
