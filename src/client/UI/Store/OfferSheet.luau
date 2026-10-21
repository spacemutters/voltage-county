--!strict
-- The one-time offer sheet (docs/phase-12-contracts.md "Store UI"; PLAN.md Phase 12 "Starter Pack"): what
-- Controllers/StoreController shows after the player's first free design and first job payout, while the offer is
-- still on sale. It is content for the shop kit's sheet (UI/Shop/ShopSheet), so it looks and sizes like every other
-- sheet:
--
--   header    "One-time offer" and the product's name
--   main      one line about it, then what it gives (StoreModel.grantLines), one line each
--   summary   the price GetStore sent (never typed anywhere) and "It won't show again after you buy it."
--   actions   Buy (BuyProduct: Roblox's own prompt shows next) and Not now
--
-- Presentation only: StoreController passes the offer, its product, whether a request is with the server, and the
-- callbacks.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local React = require(ReplicatedStorage.Packages.React)

local Theme = require(script.Parent.Parent.Theme)
local Primitives = require(script.Parent.Parent.Shop.Primitives)
local StoreModel = require(script.Parent.StoreModel)
local StoreStyle = require(script.Parent.StoreStyle)

local e = React.createElement
local colors = Theme.colors
local copy = StoreStyle.copy
local offerStyle = StoreStyle.offer

local OfferSheet = {}

export type Props = {
	product: StoreModel.Product,
	busy: boolean, -- BuyProduct is with the server
	onBuy: () -> (),
	onClose: () -> (),
}

-- What the product gives, a check-mark bullet and one line each.
local function grantsSection(lines: { string }): Primitives.Section
	local children: { [string]: any } = {
		Layout = e("UIListLayout", {
			FillDirection = Enum.FillDirection.Vertical,
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
	}
	for index, line in lines do
		children[`Line{index}`] = e("Frame", {
			LayoutOrder = index,
			Size = UDim2.new(1, 0, 0, offerStyle.lineHeight),
			BackgroundTransparency = 1,
		}, {
			Bullet = e(Primitives.Label, {
				text = copy.bullet,
				height = offerStyle.lineHeight,
				font = Theme.fonts.bold,
				color = colors.accent,
				width = UDim.new(0, offerStyle.bulletWidth),
			}),
			Text = e(Primitives.Label, {
				text = line,
				height = offerStyle.lineHeight,
				font = Theme.fonts.medium,
				position = UDim2.fromOffset(offerStyle.bulletWidth, 0),
				width = UDim.new(1, -offerStyle.bulletWidth),
			}),
		})
	end
	return {
		key = "grants",
		height = #lines * offerStyle.lineHeight,
		element = e("Frame", {
			Size = UDim2.new(1, 0, 0, #lines * offerStyle.lineHeight),
			BackgroundTransparency = 1,
		}, children),
	}
end

-- The sheet's content for ShopSheet.Sheet.
function OfferSheet.content(props: Props): Primitives.Content
	local product = props.product
	local main = { Primitives.finePrintSection("body", copy.offerBody) }
	local lines = StoreModel.grantLines(product.grants)
	if #lines > 0 then
		table.insert(main, grantsSection(lines))
	end
	local label = StoreModel.buttonLabel(product, props.busy) or copy.comingSoon
	-- The price block only when the price loaded (Roblox's prompt shows it either way).
	local summary: { Primitives.Section } = {}
	if product.price ~= nil then
		table.insert(summary, {
			key = "price",
			height = Primitives.priceBlockHeight(),
			element = e(Primitives.PriceBlock, {
				label = copy.priceLabel,
				price = StoreModel.priceText(product.price),
				status = copy.offerStatus,
			}),
		})
	else
		table.insert(summary, Primitives.finePrintSection("once", copy.offerStatus))
	end
	return {
		eyebrow = copy.offerEyebrow,
		title = product.name,
		main = main,
		summary = summary,
		actions = {
			{
				key = "buy",
				label = label,
				style = "primary",
				disabled = props.busy or StoreModel.itemState(product) ~= "buy",
				onTap = props.onBuy,
			},
			{ key = "close", label = copy.notNow, style = "secondary", disabled = false, onTap = props.onClose },
		},
	}
end

return OfferSheet
