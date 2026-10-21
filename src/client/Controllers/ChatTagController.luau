--!strict
-- Chat tags (PLAN.md Phase 12, the VIP pass's "chat tag"; docs/phase-12-contracts.md "Monetization core"): a chat
-- message from a player who owns the VIP pass shows Config/Monetization.chatTags.vip before their name. It reads the
-- player attribute Services/MonetizationService keeps for every owned pass (attributes.passPrefix .. vipPass), so a
-- pass bought in game (or given by DevPurchase in Studio) shows on the next message.
--
-- TextChatService.OnIncomingMessage is a callback with a single owner: this controller is it. Only the prefix in
-- front of the name changes (Roblox's own example for a VIP tag); the message itself is Roblox's, already filtered.
-- Does nothing under the legacy chat. No polling: Roblox calls it for each message.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextChatService = game:GetService("TextChatService")

local Monetization = require(ReplicatedStorage.Shared.Config.Monetization)

local ChatTagController = {}

local VIP_ATTRIBUTE = Monetization.attributes.passPrefix .. Monetization.vipPass

-- The prefix (rich text) a message shows in front of the sender's name: `prefix` as Roblox made it, with the VIP
-- tag first when `isVip`.
function ChatTagController.prefixFor(isVip: boolean, prefix: string): string
	if not isVip then
		return prefix
	end
	local tag = Monetization.chatTags.vip
	return `<font color="#{tag.colorHex}">{tag.text}</font> {prefix}`
end

function ChatTagController:Start()
	if TextChatService.ChatVersion ~= Enum.ChatVersion.TextChatService then
		return
	end
	TextChatService.OnIncomingMessage = function(message: TextChatMessage): TextChatMessageProperties
		local properties = Instance.new("TextChatMessageProperties")
		local source = message.TextSource
		if source ~= nil then
			local player = Players:GetPlayerByUserId(source.UserId)
			if player ~= nil and player:GetAttribute(VIP_ATTRIBUTE) == true then
				properties.PrefixText = ChatTagController.prefixFor(true, message.PrefixText)
			end
		end
		return properties
	end
end

return ChatTagController
