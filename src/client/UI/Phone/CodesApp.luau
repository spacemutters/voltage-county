--!strict
-- The phone's Codes app (moved here from the HUD's Codes button): a text box and Redeem (Enter in the box works
-- too). PhoneController sends the code with Net "RedeemCode" and shows the server's answer as a notice; it
-- clears the box when a code works (by bumping `clearToken`) and leaves the text when it doesn't, so a typo can be
-- fixed. Presentation only. Words come from Config/Economy (the same as the old code sheet).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local React = require(ReplicatedStorage.Packages.React)
local Economy = require(ReplicatedStorage.Shared.Config.Economy)

local Kit = require(script.Parent.Kit)
local PhoneConfig = require(script.Parent.PhoneConfig)
local Theme = require(script.Parent.Parent.Theme)

local e = React.createElement
local colors = Theme.colors

export type Props = {
	redeeming: boolean, -- a code is with the server
	clearToken: number, -- changes when the box should empty (a code worked)
	autoFocus: boolean, -- put the cursor in the box on open (keyboard players; on phones it would pop the keyboard)
	onRedeem: (text: string) -> (),
}

local function CodesApp(props: Props)
	local panel = Economy.hud.panel
	local box = React.useRef(nil :: TextBox?)

	React.useEffect(function()
		local current = box.current
		if current ~= nil and props.autoFocus then
			current:CaptureFocus()
		end
	end, {})

	React.useEffect(function()
		local current = box.current
		if current ~= nil and props.clearToken > 0 then
			current.Text = ""
		end
	end, { props.clearToken })

	local function submit()
		local current = box.current
		if current ~= nil and not props.redeeming then
			props.onRedeem(current.Text)
		end
	end

	return Kit.Page({}, {
		Intro = Kit.Text({ text = PhoneConfig.codes.body, order = 1, color = colors.textDim }),
		Input = e("TextBox", {
			LayoutOrder = 2,
			Size = UDim2.new(1, 0, 0, Theme.size.buttonHeight),
			BackgroundColor3 = colors.panelRaised,
			BorderSizePixel = 0,
			ClearTextOnFocus = false,
			TextEditable = not props.redeeming,
			FontFace = Theme.fonts.medium,
			PlaceholderText = panel.placeholder,
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
		Redeem = e(Kit.Button, {
			label = if props.redeeming then panel.redeemingLabel else panel.redeemLabel,
			style = "primary",
			disabled = props.redeeming,
			order = 3,
			onTap = submit,
		}),
	})
end

return CodesApp
