--!strict
-- The phone's Garage app: the player's cars as cards, favorites first and then the newest (the snapshot's
-- order, Config/Garage.sortVehicles). Each card shows the car's name and trim from Vehicle/Catalog, a favorite
-- star, and its actions: Spawn (or Put away for the car that's out) and Sell, which asks first in a confirm sheet
-- showing the price (Config/Garage.sellPrice, formatted with Config/Economy.formatCash).
--
-- While one request is with the server every action button is disabled and the one that was tapped says what
-- it's doing, so nothing can be tapped twice. An empty garage offers directions to the used lot and the
-- dealership. Presentation only: PhoneController passes the snapshot, the state and the callbacks.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local React = require(ReplicatedStorage.Packages.React)
local Catalog = require(ReplicatedStorage.Shared.Vehicle.Catalog)
local Economy = require(ReplicatedStorage.Shared.Config.Economy)
local Garage = require(ReplicatedStorage.Shared.Config.Garage)
local Types = require(ReplicatedStorage.Shared.Types)

local Kit = require(script.Parent.Kit)
local PhoneConfig = require(script.Parent.PhoneConfig)
local Theme = require(script.Parent.Parent.Theme)

local e = React.createElement
local colors = Theme.colors
local text = PhoneConfig.garageText

export type Action = "spawn" | "despawn" | "sell"

-- The request waiting on the server, if any.
export type Busy = { uid: string?, action: Action }

export type Props = {
	profile: Types.ProfileSnapshot?,
	outUid: string?, -- the car that's out, if the phone knows of one
	busy: Busy?,
	confirmUid: string?, -- the car whose sell confirm is showing
	onSpawn: (uid: string) -> (),
	onPutAway: () -> (),
	onFavorite: (uid: string, favorite: boolean) -> (),
	onAskSell: (uid: string) -> (),
	onCancelSell: () -> (),
	onConfirmSell: (uid: string) -> (),
	onDirections: (locationId: string) -> (),
}

-- Names -------------------------------------------------------------------------------------------------------

-- The car's name and trim as players see them (only ever from the catalog), e.g. "Ohm Spark", "Spark (used)".
local function namesOf(vehicle: Types.SnapshotVehicle): (string, string)
	if vehicle.vehicleId == Garage.customVehicleId then
		return text.customName, ""
	end
	local entry = Catalog.getVehicle(vehicle.vehicleId)
	local trim = Catalog.getTrim(vehicle.vehicleId, vehicle.trim)
	return if entry then entry.displayName else vehicle.vehicleId, if trim then trim.displayName else vehicle.trim
end

-- True when selling this car pays something (the free starter and player designs can't be sold here).
local function sellable(vehicle: Types.SnapshotVehicle): boolean
	return vehicle.vehicleId ~= Garage.customVehicleId and Garage.sellPrice(vehicle.paid) > 0
end

-- A car's card -------------------------------------------------------------------------------------------------

local function Star(props: { on: boolean, onTap: () -> () })
	local garage = PhoneConfig.garage
	return e("TextButton", {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0),
		Size = UDim2.fromOffset(garage.starSize, garage.starSize),
		BackgroundTransparency = 1,
		AutoButtonColor = false,
		FontFace = Theme.fonts.bold,
		Text = if props.on then text.favoriteOn else text.favoriteOff,
		TextColor3 = if props.on then colors.accent else colors.textDim,
		TextSize = garage.starTextSize,
		[React.Event.Activated] = function()
			props.onTap()
		end,
	})
end

local function CarCard(props: {
	vehicle: Types.SnapshotVehicle,
	out: boolean,
	busy: Busy?,
	order: number,
	actions: Props,
})
	local vehicle = props.vehicle
	local busy = props.busy
	local garage = PhoneConfig.garage
	local name, trimName = namesOf(vehicle)
	local canSell = sellable(vehicle)
	local locked = busy ~= nil
	local busyHere = busy ~= nil and (busy.uid == vehicle.uid or (busy.action == "despawn" and props.out))

	local primary
	if props.out then
		primary = e(Kit.Button, {
			label = if busyHere and busy and busy.action == "despawn" then text.puttingAway else text.putAway,
			style = "secondary",
			disabled = locked,
			order = 1,
			size = UDim2.fromScale(1, 1),
			onTap = props.actions.onPutAway,
		})
	else
		primary = e(Kit.Button, {
			label = if busyHere and busy and busy.action == "spawn" then text.spawning else text.spawn,
			style = "primary",
			disabled = locked,
			order = 1,
			size = UDim2.fromScale(1, 1),
			onTap = function()
				props.actions.onSpawn(vehicle.uid)
			end,
		})
	end
	local buttons: { [string]: any } = { Primary = primary }
	if canSell then
		buttons.Sell = e(Kit.Button, {
			label = if busyHere and busy and busy.action == "sell" then text.selling else text.sell,
			style = "dangerText",
			disabled = locked,
			order = 2,
			size = UDim2.fromScale(1, 1),
			onTap = function()
				props.actions.onAskSell(vehicle.uid)
			end,
		})
	end

	-- "Out now" and "Starter car" notes, when they apply, in a row.
	local notes: { [string]: any } = {}
	if props.out then
		notes.Out = Kit.Pill({ text = text.outNow, order = 1 })
	end
	if not canSell and vehicle.vehicleId ~= Garage.customVehicleId then
		-- The free starter by its trim (GarageService.isStarter's rule); any other car that sells for nothing
		-- (a limited drop, a retired trim) says why the Sell button is missing.
		local trim = Catalog.getTrim(vehicle.vehicleId, vehicle.trim)
		local starter = trim ~= nil and trim.acquisition == "starter"
		notes.Starter = Kit.Pill({
			text = if starter then text.starter else text.noValue,
			order = 2,
			color = colors.textDim,
		})
	end
	local hasNotes = next(notes) ~= nil
	notes.Layout = e("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		SortOrder = Enum.SortOrder.LayoutOrder,
		Padding = UDim.new(0, Theme.spacing.sm),
	})

	return Kit.Card({ order = props.order }, {
		Top = e("Frame", {
			LayoutOrder = 1,
			Size = UDim2.fromScale(1, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
		}, {
			Names = Kit.Stack({ gap = 2 }, {
				Name = Kit.Text({ text = name, order = 1, size = Theme.text.heading, font = Theme.fonts.bold }),
				Trim = if trimName ~= "" then Kit.Text({ text = trimName, order = 2, color = colors.textDim }) else nil,
				Room = e("UIPadding", { PaddingRight = UDim.new(0, garage.starSize + Theme.spacing.sm) }),
			}),
			Star = e(Star, {
				on = vehicle.favorite,
				onTap = function()
					props.actions.onFavorite(vehicle.uid, not vehicle.favorite)
				end,
			}),
		}),
		Notes = if hasNotes
			then e("Frame", {
				LayoutOrder = 2,
				Size = UDim2.new(1, 0, 0, garage.pillHeight),
				BackgroundTransparency = 1,
			}, notes)
			else nil,
		Buttons = Kit.ButtonRow({ order = 3, buttons = buttons, count = if canSell then 2 else 1 }),
	})
end

-- The sell confirm ---------------------------------------------------------------------------------------------

local function SellConfirm(props: { vehicle: Types.SnapshotVehicle, busy: boolean, actions: Props })
	local vehicle = props.vehicle
	local name = namesOf(vehicle)
	local price = Economy.formatCash(Garage.sellPrice(vehicle.paid))
	local percent = math.round(Garage.sellBackRate * 100)
	local fade = Kit.useAppear(false)
	local scrimTransparency = colors.scrimTransparency
	return e("Frame", {
		ZIndex = 5,
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
	}, {
		-- Dims the garage behind; tapping it is the same as Keep it.
		Scrim = e("TextButton", {
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
				if not props.busy then
					props.actions.onCancelSell()
				end
			end,
		}),
		Sheet = e("Frame", {
			ZIndex = 2,
			AnchorPoint = Vector2.new(0.5, 1),
			Position = fade:map(function(value: number): UDim2
				return UDim2.new(0.5, 0, 1, -PhoneConfig.sheet.padding + value * PhoneConfig.sheet.slideOffset)
			end),
			Size = UDim2.new(1, -2 * PhoneConfig.sheet.padding, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
			Active = true,
		}, {
			Card = Kit.Card({ gap = Theme.spacing.md, padding = Theme.spacing.lg }, {
				Title = Kit.Text({
					text = string.format(text.confirmTitle, name),
					order = 1,
					size = Theme.text.heading,
					font = Theme.fonts.bold,
				}),
				Body = Kit.Text({
					text = string.format(text.confirmBody, price, percent),
					order = 2,
					color = colors.textDim,
				}),
				Buttons = Kit.ButtonRow({
					order = 3,
					count = 2,
					buttons = {
						Keep = e(Kit.Button, {
							label = text.keep,
							disabled = props.busy,
							order = 1,
							size = UDim2.fromScale(1, 1),
							onTap = props.actions.onCancelSell,
						}),
						Sell = e(Kit.Button, {
							label = if props.busy then text.selling else string.format(text.confirmSell, price),
							style = "danger",
							disabled = props.busy,
							order = 2,
							size = UDim2.fromScale(1, 1),
							onTap = function()
								props.actions.onConfirmSell(vehicle.uid)
							end,
						}),
					},
				}),
			}),
		}),
	})
end

-- The app -----------------------------------------------------------------------------------------------------

local function EmptyGarage(props: { order: number, actions: Props })
	local garage = PhoneConfig.garage
	return Kit.Card({ order = props.order, gap = Theme.spacing.md, padding = Theme.spacing.lg }, {
		Title = Kit.Text({ text = text.emptyTitle, order = 1, size = Theme.text.heading, font = Theme.fonts.bold }),
		Body = Kit.Text({ text = text.emptyBody, order = 2, color = colors.textDim }),
		UsedLot = e(Kit.Button, {
			label = text.toUsedLot,
			style = "primary",
			order = 3,
			onTap = function()
				props.actions.onDirections(garage.usedLotLocation)
			end,
		}),
		Dealership = e(Kit.Button, {
			label = text.toDealership,
			order = 4,
			onTap = function()
				props.actions.onDirections(garage.dealershipLocation)
			end,
		}),
	})
end

local function GarageApp(props: Props)
	local profile = props.profile
	if profile == nil then
		return Kit.Page({}, {
			Loading = Kit.Text({ text = PhoneConfig.labels.loading, color = colors.textDim }),
		})
	end

	-- Player designs live in their own slots (customSlots), so only catalog cars count against the garage.
	local parked = 0
	for _, vehicle in profile.vehicles do
		if vehicle.vehicleId ~= Garage.customVehicleId then
			parked += 1
		end
	end
	local children: { [string]: any } = {
		Spaces = Kit.Text({
			text = string.format(text.spaces, parked, profile.garageSlots),
			order = 0,
			size = Theme.text.small,
			font = Theme.fonts.medium,
			color = colors.textDim,
		}),
	}
	local confirming: Types.SnapshotVehicle? = nil
	for index, vehicle in profile.vehicles do
		children[`Car_{vehicle.uid}`] = e(CarCard, {
			vehicle = vehicle,
			out = vehicle.uid == props.outUid,
			busy = props.busy,
			order = index,
			actions = props,
		})
		if vehicle.uid == props.confirmUid then
			confirming = vehicle
		end
	end
	if #profile.vehicles == 0 then
		children.Empty = e(EmptyGarage, { order = 1, actions = props })
	end

	local busy = props.busy
	return e("Frame", {
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
	}, {
		Page = Kit.Page({}, children),
		Confirm = if confirming
			then e(SellConfirm, {
				vehicle = confirming,
				busy = busy ~= nil and busy.action == "sell",
				actions = props,
			})
			else nil,
	})
end

return GarageApp
