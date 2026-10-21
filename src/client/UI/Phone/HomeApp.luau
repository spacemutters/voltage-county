--!strict
-- The phone's Home app (PLAN.md Phase 13; docs/phase-13-contracts.md "Houses"), top to bottom:
--
--   your house   with a house: its address, what charging at home costs and how fast (Config/Houses chargerKW and
--                chargerCostPerFull with the owned upgrades), "Set GPS home" and "Move out" (asks first). With none:
--                how to claim one (walk up to a free house's sign in Riverside) and directions there.
--   upgrades     every Config/Houses upgrade with its price: "Owned", or Buy (greyed out, with what's missing,
--                when the player's cash is short).
--
-- UI/Phone/Phone mounts it for the "home" app (with the sheet's onClose, to put the phone away once the GPS is set)
-- and draws its icon (HomeApp.Glyph). It reads the house's state itself (Controllers/HouseController.useState) and the
-- cash from the profile (ProfileController); the phone re-renders it with every new snapshot. Presentation only:
-- every request is an intent the server decides.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local React = require(ReplicatedStorage.Packages.React)

local Economy = require(ReplicatedStorage.Shared.Config.Economy)
local Houses = require(ReplicatedStorage.Shared.Config.Houses)

local Kit = require(script.Parent.Kit)
local Theme = require(script.Parent.Parent.Theme)
local HouseController = require(script.Parent.Parent.Parent.Controllers.HouseController)
local ProfileController = require(script.Parent.Parent.Parent.Controllers.ProfileController)

local e = React.createElement
local colors = Theme.colors
local copy = Houses.app

local PERCENT = 100

local HomeApp = {}

-- The house card ---------------------------------------------------------------------------------------------------

local function HouseCard(props: { state: HouseController.State, order: number, onClose: () -> () })
	local state = props.state
	local address = state.address
	local busy = state.busy ~= nil
	if state.plotId == nil or address == nil then
		return Kit.Card({ order = props.order, padding = Theme.spacing.lg }, {
			Title = Kit.Text({
				text = copy.noHouseTitle,
				order = 1,
				size = Theme.text.heading,
				font = Theme.fonts.bold,
			}),
			Body = Kit.Text({ text = copy.noHouseBody, order = 2, color = colors.textDim }),
			Directions = e(Kit.Button, {
				label = copy.directions,
				style = "primary",
				order = 3,
				onTap = function()
					HouseController.directions()
					props.onClose() -- the route is on the road: get the phone out of the way
				end,
			}),
		})
	end

	local children: { [string]: any } = {
		Label = Kit.Text({
			text = copy.yourHouse,
			order = 1,
			size = Theme.text.small,
			font = Theme.fonts.medium,
			color = colors.textDim,
		}),
		Address = Kit.Text({ text = address, order = 2, size = Theme.text.heading, font = Theme.fonts.bold }),
		Charger = Kit.Text({
			text = string.format(
				copy.chargerLine,
				tostring(Houses.chargerKW(state.upgrades)),
				Economy.formatCash(Houses.chargerCostPerFull(state.upgrades) / PERCENT)
			),
			order = 3,
			size = Theme.text.small,
			color = colors.textDim,
		}),
	}
	if state.confirmLeave then
		children.ConfirmTitle = Kit.Text({
			text = string.format(copy.confirmTitle, address),
			order = 4,
			font = Theme.fonts.bold,
		})
		children.ConfirmBody = Kit.Text({ text = copy.confirmBody, order = 5, color = colors.textDim })
		children.Confirm = Kit.ButtonRow({
			order = 6,
			count = 2,
			buttons = {
				Stay = e(Kit.Button, {
					label = copy.stay,
					order = 1,
					disabled = busy,
					onTap = function()
						HouseController.askLeave(false)
					end,
				}),
				Leave = e(Kit.Button, {
					label = if state.busy == HouseController.leaveBusy then copy.leaving else copy.confirmLeave,
					style = "danger",
					order = 2,
					disabled = busy,
					onTap = HouseController.leave,
				}),
			},
		})
	else
		children.Gps = e(Kit.Button, {
			label = copy.setGps,
			style = "primary",
			order = 4,
			onTap = function()
				HouseController.setGpsHome()
				props.onClose()
			end,
		})
		children.Leave = e(Kit.Button, {
			label = copy.leave,
			style = "dangerText",
			order = 5,
			disabled = busy,
			onTap = function()
				HouseController.askLeave(true)
			end,
		})
	end
	return Kit.Card({ order = props.order, padding = Theme.spacing.lg }, children)
end

-- The upgrades -------------------------------------------------------------------------------------------------------

local function UpgradeCard(props: {
	upgrade: Houses.Upgrade,
	owned: boolean,
	cash: number?,
	busy: string?,
	order: number,
})
	local upgrade = props.upgrade
	local children: { [string]: any } = {
		Name = Kit.Text({ text = upgrade.name, order = 1, font = Theme.fonts.bold }),
		Description = Kit.Text({
			text = upgrade.description,
			order = 2,
			size = Theme.text.small,
			color = colors.textDim,
		}),
	}
	if props.owned then
		children.Owned = e("Frame", {
			LayoutOrder = 3,
			Size = UDim2.fromScale(1, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
		}, {
			Pill = Kit.Pill({ text = copy.owned, color = colors.success }),
		})
	else
		local cash = props.cash
		local short = if cash ~= nil then math.max(upgrade.price - cash, 0) else 0
		local buying = props.busy == HouseController.upgradeBusy(upgrade.id)
		children.Buy = e(Kit.Button, {
			label = if buying then copy.buying else string.format(copy.buy, Economy.formatCash(upgrade.price)),
			style = "primary",
			order = 3,
			disabled = props.busy ~= nil or cash == nil or short > 0,
			onTap = function()
				HouseController.buy(upgrade.id)
			end,
		})
		if short > 0 then
			children.Short = Kit.Text({
				text = string.format(copy.cashNeeded, Economy.formatCash(short)),
				order = 4,
				size = Theme.text.small,
				color = colors.warning,
			})
		end
	end
	return Kit.Card({ order = props.order }, children)
end

-- The app ------------------------------------------------------------------------------------------------------------

function HomeApp.App(props: { onClose: () -> () })
	local state = HouseController.useState()
	if not state.loaded then
		return Kit.Page({}, {
			Loading = Kit.Text({ text = copy.loading, color = colors.textDim }),
		})
	end
	local profile = ProfileController.get()
	local cash = if profile ~= nil then profile.cash else nil
	local children: { [string]: any } = {
		House = e(HouseCard, { state = state, order = 1, onClose = props.onClose }),
		UpgradesTitle = Kit.SectionTitle({ text = copy.upgrades, order = 2 }),
	}
	for index, upgrade in Houses.upgrades do
		children[`Upgrade_{upgrade.id}`] = e(UpgradeCard, {
			upgrade = upgrade,
			owned = state.upgrades[upgrade.id] == true,
			cash = cash,
			busy = state.busy,
			order = 2 + index,
		})
	end
	return Kit.Page({ gap = Theme.spacing.md }, children)
end

-- The icon -----------------------------------------------------------------------------------------------------------

-- One rounded shape of the icon, as fractions of its box (like UI/Phone/Glyphs).
local function piece(props: {
	at: Vector2,
	size: Vector2,
	color: Color3,
	radius: number,
	rotation: number?,
	order: number,
})
	return e("Frame", {
		ZIndex = props.order,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(props.at.X, props.at.Y),
		Size = UDim2.fromScale(props.size.X, props.size.Y),
		Rotation = props.rotation or 0,
		BackgroundColor3 = props.color,
		BorderSizePixel = 0,
	}, {
		Corner = e("UICorner", { CornerRadius = UDim.new(props.radius, 0) }),
	})
end

-- The Home app's icon (UI/Phone/Phone draws it on the home screen): a house, its roof a square turned on its corner
-- half hidden behind the walls, and the door cut out of the walls in the background colour. No image assets.
function HomeApp.Glyph(props: { color: Color3, background: Color3, size: Vector2? })
	local ink, paper = props.color, props.background
	local size = props.size
	return e("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = if size then UDim2.fromOffset(size.X, size.Y) else UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
	}, {
		Roof = piece({
			at = Vector2.new(0.5, 0.42),
			size = Vector2.new(0.52, 0.52),
			color = ink,
			radius = 0.12,
			rotation = 45,
			order = 1,
		}),
		Walls = piece({
			at = Vector2.new(0.5, 0.68),
			size = Vector2.new(0.62, 0.42),
			color = ink,
			radius = 0.1,
			order = 2,
		}),
		Door = piece({
			at = Vector2.new(0.5, 0.77),
			size = Vector2.new(0.16, 0.24),
			color = paper,
			radius = 0.2,
			order = 3,
		}),
	})
end

return HomeApp
