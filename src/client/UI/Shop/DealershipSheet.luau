--!strict
-- What the dealership sheet shows for one display car (docs/phase-4-contracts.md "Shops", Dealership):
--
--   header    the brand's name (accent) and segment, the car's name
--   main      trim chips, the class / drive / energy line, the five stat bars (scaled to the whole catalog),
--             and the test-drive small print
--   summary   the price with the cash left after (or the cash still needed), and a note when Buy can't be used
--             or the trim is sold somewhere else (starter, used lot, fleet, limited drop)
--   actions   Test drive, and Buy or Upgrade (an upgrade trim, when the player owns the trim it upgrades)
--
-- content() builds a Primitives.Content for UI/Shop/ShopSheet; ShopController owns the state and the calls.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local React = require(ReplicatedStorage.Packages.React)
local Catalog = require(ReplicatedStorage.Shared.Vehicle.Catalog)
local Primitives = require(script.Parent.Primitives)
local ShopModel = require(script.Parent.ShopModel)
local Style = require(script.Parent.Style)

local e = React.createElement

local copy = Style.copy

export type Props = {
	vehicleId: string,
	trimId: string,
	snapshot: ShopModel.Snapshot?,
	cash: number?,
	units: ShopModel.Units,
	busy: Primitives.Busy?, -- the call in flight: every button is off while one runs
	testDriveSeconds: number?,
	onPickTrim: (trimId: string) -> (),
	onBuy: () -> (),
	onUpgrade: () -> (),
	onTestDrive: () -> (),
}

local DealershipSheet = {}

-- The status line under the price: cash still needed (warning), cash after, or "checking" while unknown.
local function cashStatus(offer: ShopModel.Offer): (string, Primitives.Tone)
	local short, after = offer.shortBy, offer.cashAfter
	if short ~= nil then
		return string.format(copy.cashNeeded, ShopModel.cash(short)), "warning"
	elseif after ~= nil then
		return string.format(copy.cashAfter, ShopModel.cash(after)), "dim"
	end
	return copy.cashLoading, "dim"
end

local function priceSection(label: string, offer: ShopModel.Offer): Primitives.Section
	local status, tone = cashStatus(offer)
	return {
		key = "Price",
		height = Primitives.priceBlockHeight(),
		element = e(Primitives.PriceBlock, {
			label = label,
			price = ShopModel.cash(offer.price or 0),
			status = status,
			statusTone = tone,
		}),
	}
end

-- The primary button for a trim that is sold here. When it can't be used, it stays labelled with its verb and
-- goes dim; the status line or note above it says why (cash needed, garage full, base trim missing), which
-- keeps the label short enough for two buttons side by side on a phone.
local function primaryAction(props: Props, offer: ShopModel.Offer): Primitives.Action?
	local busy = props.busy ~= nil
	if offer.kind == "buy" then
		return {
			key = "Buy",
			label = if props.busy == "buy" then copy.buying else copy.buy,
			style = "primary",
			disabled = busy or offer.garageFull or offer.shortBy ~= nil,
			onTap = props.onBuy,
		}
	elseif offer.kind == "upgrade" or offer.kind == "upgradeLocked" then
		return {
			key = "Upgrade",
			label = if props.busy == "upgrade" then copy.upgrading else copy.upgrade,
			style = "primary",
			disabled = busy or offer.kind == "upgradeLocked" or offer.shortBy ~= nil,
			onTap = props.onUpgrade,
		}
	end
	return nil
end

function DealershipSheet.content(props: Props): Primitives.Content
	local vehicle = Catalog.getVehicle(props.vehicleId)
	local trim = Catalog.getTrim(props.vehicleId, props.trimId)
	if vehicle == nil or trim == nil then
		return { eyebrow = "", title = "", subtitle = nil, main = {}, summary = {}, actions = {} }
	end

	local brandName, segment = ShopModel.brandOf(vehicle)
	local offer = ShopModel.offer(props.vehicleId, props.trimId, props.snapshot, props.cash)
	local busy = props.busy ~= nil

	-- Main column: trims, spec line, stats, test-drive small print.
	local chips: { Primitives.Chip } = {}
	for _, option in vehicle.trims do
		table.insert(chips, {
			id = option.id,
			label = ShopModel.chipLabel(vehicle, option),
			selected = option.id == trim.id,
		})
	end
	local rows = ShopModel.stats(props.vehicleId, trim.id, props.units)
	local spec = ShopModel.specLine(vehicle, trim)
	if offer.ownedCount > 0 then
		spec ..= copy.separator .. copy.inGarage
	end

	local main: { Primitives.Section } = {
		{
			key = "Trims",
			height = Primitives.chipsHeight(),
			element = e(Primitives.TrimChips, { chips = chips, disabled = busy, onPick = props.onPickTrim }),
		},
		Primitives.specSection("Spec", spec),
		{
			key = "Stats",
			height = Primitives.statListHeight(#rows),
			element = e(Primitives.StatList, { rows = rows }),
		},
	}
	local seconds = props.testDriveSeconds
	if offer.canTestDrive and seconds ~= nil and seconds > 0 then
		local minutes = math.max(1, math.round(seconds / 60))
		table.insert(main, Primitives.finePrintSection("FinePrint", string.format(copy.testDriveFinePrint, minutes)))
	end

	-- Summary: price and the note that goes with it.
	local summary: { Primitives.Section } = {}
	if offer.kind == "buy" then
		table.insert(summary, priceSection(copy.price, offer))
		if offer.garageFull then
			table.insert(summary, Primitives.noteSection("Note", copy.garageFull, "warning"))
		end
	elseif offer.kind == "upgrade" then
		table.insert(summary, priceSection(copy.upgradePrice, offer))
		table.insert(
			summary,
			Primitives.noteSection("Note", string.format(copy.upgradeOwned, offer.baseTrimName or ""))
		)
	elseif offer.kind == "upgradeLocked" then
		table.insert(summary, priceSection(copy.upgradePrice, offer))
		table.insert(
			summary,
			Primitives.noteSection("Note", string.format(copy.upgradeLocked, offer.baseTrimName or ""))
		)
	else
		table.insert(summary, Primitives.noteSection("Note", offer.how or copy.how.other))
	end

	-- Footer: Test drive (secondary) and the primary action.
	local actions: { Primitives.Action } = {}
	if offer.canTestDrive then
		table.insert(actions, {
			key = "TestDrive",
			label = if props.busy == "testDrive" then copy.testDriveStarting else copy.testDrive,
			style = "secondary",
			disabled = busy,
			onTap = props.onTestDrive,
		})
	end
	local primary = primaryAction(props, offer)
	if primary ~= nil then
		table.insert(actions, primary)
	end

	return {
		eyebrow = brandName,
		title = vehicle.displayName,
		subtitle = if segment ~= "" then segment else nil,
		main = main,
		summary = summary,
		actions = actions,
	}
end

return DealershipSheet
