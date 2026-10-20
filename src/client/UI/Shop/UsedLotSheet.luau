--!strict
-- What the used-lot sheet shows for one numbered space (docs/phase-4-contracts.md "Shops", Used lot):
--
--   header    "Used lot · Space 3", the car's name and brand
--   main      the free-starter banner (until the player has claimed it), the trim / class / energy line and
--             the stat bars, or a loading / empty / failed message
--   summary   today's price, how many are left today and the cash left after
--   actions   Buy (or Try again when today's stock couldn't be loaded)
--
-- Today's stock comes from GetUsedLot (ShopController loads it when the sheet opens). content() builds a
-- Primitives.Content for UI/Shop/ShopSheet; ShopController owns the state and the calls.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local React = require(ReplicatedStorage.Packages.React)
local Catalog = require(ReplicatedStorage.Shared.Vehicle.Catalog)
local Theme = require(script.Parent.Parent.Theme)
local Primitives = require(script.Parent.Primitives)
local ShopModel = require(script.Parent.ShopModel)
local Style = require(script.Parent.Style)

local e = React.createElement

local colors = Theme.colors
local layout = Style.layout
local copy = Style.copy

export type LotState = "loading" | "ready" | "failed"

export type Props = {
	slot: number,
	state: LotState,
	entry: ShopModel.LotEntry?, -- this space's car today (nil while loading, or when the space is empty)
	starterClaimed: boolean?, -- false shows the free-starter banner; nil (not known yet) hides it
	snapshot: ShopModel.Snapshot?,
	cash: number?,
	units: ShopModel.Units,
	busy: Primitives.Busy?,
	onBuy: () -> (),
	onClaim: () -> (),
	onRetry: () -> (),
}

local UsedLotSheet = {}

-- The height of the car's details once loaded (spec line, stats, small print), held by the loading message.
local function detailsHeight(): number
	return layout.specLineHeight
		+ Primitives.statListHeight(#ShopModel.statIds)
		+ 2 * layout.finePrintHeight
		+ 2 * layout.sectionGap
end

local function claimHeight(): number
	return 2 * layout.claimPadding
		+ layout.claimTitleHeight
		+ layout.claimTextHeight
		+ layout.claimGap
		+ layout.buttonHeight
end

-- The free-starter banner: a raised card outlined in the accent, with its own Claim button.
local function ClaimBanner(props: { busy: Primitives.Busy?, onClaim: () -> () })
	local claiming = props.busy == "claim"
	return e("Frame", {
		Size = UDim2.new(1, 0, 0, claimHeight()),
		BackgroundColor3 = colors.panelRaised,
		BorderSizePixel = 0,
	}, {
		Corner = Primitives.corner(Theme.radius.card),
		Outline = e("UIStroke", {
			Color = colors.accent,
			Thickness = 1,
			ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		}),
		Padding = e("UIPadding", {
			PaddingLeft = UDim.new(0, layout.claimPadding),
			PaddingRight = UDim.new(0, layout.claimPadding),
			PaddingTop = UDim.new(0, layout.claimPadding),
			PaddingBottom = UDim.new(0, layout.claimPadding),
		}),
		Layout = e("UIListLayout", {
			FillDirection = Enum.FillDirection.Vertical,
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
		Title = e(Primitives.Label, {
			order = 1,
			text = copy.claimTitle,
			height = layout.claimTitleHeight,
			font = Theme.fonts.bold,
		}),
		Text = e(Primitives.Label, {
			order = 2,
			text = string.format(copy.claimText, ShopModel.starterName()),
			height = layout.claimTextHeight,
			textSize = Theme.text.small,
			color = colors.textDim,
		}),
		Gap = e("Frame", {
			LayoutOrder = 3,
			Size = UDim2.new(1, 0, 0, layout.claimGap),
			BackgroundTransparency = 1,
		}),
		Claim = e(Primitives.Button, {
			order = 4,
			label = if claiming then copy.claiming else copy.claim,
			style = "primary",
			disabled = props.busy ~= nil,
			size = UDim2.new(1, 0, 0, layout.buttonHeight),
			onTap = props.onClaim,
		}),
	})
end

-- The status line under today's price: sold out, cash needed (warnings), or what's left and the cash after.
local function lotStatus(entry: ShopModel.LotEntry, cashAfter: number?, shortBy: number?): (string?, Primitives.Tone)
	local remaining = entry.remaining
	if remaining ~= nil and remaining <= 0 then
		return copy.soldOut, "warning"
	elseif shortBy ~= nil then
		return string.format(copy.cashNeeded, ShopModel.cash(shortBy)), "warning"
	end
	local parts: { string } = {}
	local left = ShopModel.remainingText(remaining)
	if left ~= nil then
		table.insert(parts, left)
	end
	if cashAfter ~= nil then
		table.insert(parts, string.format(copy.cashAfter, ShopModel.cash(cashAfter)))
	end
	if #parts == 0 then
		return nil, "dim"
	end
	return table.concat(parts, copy.separator), "dim"
end

function UsedLotSheet.content(props: Props): Primitives.Content
	local busy = props.busy ~= nil
	local entry = props.entry
	local vehicle = if entry then Catalog.getVehicle(entry.vehicleId) else nil
	local trim = if entry then Catalog.getTrim(entry.vehicleId, entry.trim) else nil

	local main: { Primitives.Section } = {}
	local summary: { Primitives.Section } = {}
	local actions: { Primitives.Action } = {}

	-- The free starter, once per player (only when we know it hasn't been claimed).
	local snapshot = props.snapshot
	if props.starterClaimed == false then
		table.insert(main, {
			key = "Claim",
			height = claimHeight(),
			element = e(ClaimBanner, { busy = props.busy, onClaim = props.onClaim }),
		})
	end

	-- The subtitle line (the brand) is kept, blank, until the car is known, so the header never changes height.
	local title = copy.lotTitle
	local subtitle = ""

	if props.state == "loading" then
		-- A placeholder as tall as the loaded sheet: the message where the details go, an empty price block.
		table.insert(main, Primitives.statusSection("Status", copy.loading, "dim", detailsHeight()))
		table.insert(summary, {
			key = "Price",
			height = Primitives.priceBlockHeight(),
			element = e(Primitives.PriceBlock, { label = copy.todaysPrice, price = copy.units.none }),
		})
		table.insert(actions, {
			key = "Buy",
			label = copy.loadingButton,
			style = "primary",
			disabled = true,
			onTap = props.onBuy,
		})
	elseif props.state == "failed" then
		table.insert(main, Primitives.statusSection("Status", copy.loadFailed, "warning"))
		table.insert(actions, {
			key = "Retry",
			label = copy.retry,
			style = "secondary",
			disabled = busy,
			onTap = props.onRetry,
		})
	elseif entry == nil or vehicle == nil or trim == nil then
		table.insert(main, Primitives.statusSection("Status", copy.emptySpace))
	else
		title = vehicle.displayName
		subtitle = ShopModel.brandOf(vehicle)

		local rows = ShopModel.stats(entry.vehicleId, entry.trim, props.units)
		table.insert(main, Primitives.specSection("Spec", ShopModel.specLine(vehicle, trim, trim.displayName)))
		table.insert(main, {
			key = "Stats",
			height = Primitives.statListHeight(#rows),
			element = e(Primitives.StatList, { rows = rows }),
		})
		if entry.supply ~= nil then
			table.insert(main, Primitives.finePrintSection("FinePrint", copy.priceRises))
		end

		local cash = props.cash
		local cashAfter = if cash ~= nil then cash - entry.price else nil
		local shortBy = if cashAfter ~= nil and cashAfter < 0 then -cashAfter else nil
		local status, tone = lotStatus(entry, cashAfter, shortBy)
		table.insert(summary, {
			key = "Price",
			height = Primitives.priceBlockHeight(),
			element = e(Primitives.PriceBlock, {
				label = copy.todaysPrice,
				price = ShopModel.cash(entry.price),
				status = status,
				statusTone = tone,
			}),
		})
		local garageFull = ShopModel.garageFull(snapshot)
		if garageFull then
			table.insert(summary, Primitives.noteSection("Note", copy.garageFull, "warning"))
		end

		local remaining = entry.remaining
		local soldOut = remaining ~= nil and remaining <= 0
		-- Like the dealership: a Buy that can't be used goes dim, and the status line or note says why.
		local label = copy.buy
		if props.busy == "buyUsed" then
			label = copy.buying
		elseif soldOut then
			label = copy.soldOut
		end
		table.insert(actions, {
			key = "Buy",
			label = label,
			style = "primary",
			disabled = busy or soldOut or garageFull or shortBy ~= nil,
			onTap = props.onBuy,
		})
	end

	return {
		eyebrow = string.format(copy.lotEyebrow, props.slot),
		title = title,
		subtitle = subtitle,
		main = main,
		summary = summary,
		actions = actions,
	}
end

return UsedLotSheet
