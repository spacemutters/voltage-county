--!strict
-- The phone's Wallet app: the player's cash and their Design Credits balance (0 until credits go on sale in
-- Phase 12), both from the profile snapshot. Presentation only.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Economy = require(ReplicatedStorage.Shared.Config.Economy)
local Types = require(ReplicatedStorage.Shared.Types)

local Kit = require(script.Parent.Kit)
local PhoneConfig = require(script.Parent.PhoneConfig)
local Theme = require(script.Parent.Parent.Theme)

local colors = Theme.colors

export type Props = {
	profile: Types.ProfileSnapshot?,
}

-- "$12,345" as rich text, with the currency symbol in the accent color (like the HUD's cash readout).
local function cashText(cash: number): string
	local formatted = Economy.formatCash(cash)
	local symbol = Economy.display.symbol
	local at = string.find(formatted, symbol, 1, true)
	if at == nil then
		return formatted
	end
	return string.sub(formatted, 1, at - 1)
		.. `<font color="#{colors.accent:ToHex()}">{symbol}</font>`
		.. string.sub(formatted, at + #symbol)
end

local function Balance(props: { order: number, label: string, value: string, rich: boolean, note: string })
	return Kit.Card({ order = props.order, gap = Theme.spacing.xs, padding = Theme.spacing.lg }, {
		Label = Kit.Text({
			text = props.label,
			order = 1,
			size = Theme.text.small,
			font = Theme.fonts.medium,
			color = colors.textDim,
		}),
		Value = Kit.Text({
			text = props.value,
			order = 2,
			size = Theme.text.price,
			font = Theme.fonts.bold,
			richText = props.rich,
		}),
		Note = Kit.Text({ text = props.note, order = 3, size = Theme.text.small, color = colors.textDim }),
	})
end

local function WalletApp(props: Props)
	local profile = props.profile
	local copy = PhoneConfig.wallet
	if profile == nil then
		return Kit.Page({}, {
			Loading = Kit.Text({ text = PhoneConfig.labels.loading, color = colors.textDim }),
		})
	end
	return Kit.Page({}, {
		Cash = Balance({
			order = 1,
			label = copy.cash,
			value = cashText(profile.cash),
			rich = true,
			note = copy.cashNote,
		}),
		Credits = Balance({
			order = 2,
			label = copy.credits,
			value = tostring(math.floor(profile.credits.balance)),
			rich = false,
			note = copy.creditsNote,
		}),
	})
end

return WalletApp
