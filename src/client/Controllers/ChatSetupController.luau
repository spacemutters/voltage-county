--!strict
-- Chat on the client (PLAN.md Phase 13; docs/phase-13-contracts.md "Social"): Roblox's TextChatService with its
-- defaults, bubble chat on (Config/Social chat). It only switches on Roblox's own bubbles, chat window and input bar
-- for this player; it never sends, makes channels for or rewrites messages, so everything players type goes through
-- Roblox's filtering. (Controllers/ChatTagController adds the VIP tag in front of names; Services/SocialSetupService
-- checks the place's chat settings on the server.) Does nothing under the legacy chat.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextChatService = game:GetService("TextChatService")

local Social = require(ReplicatedStorage.Shared.Config.Social)

local ChatSetupController = {}

local function enable(className: string, on: boolean)
	local configuration: any = TextChatService:FindFirstChildOfClass(className)
	if configuration ~= nil then
		configuration.Enabled = on
	end
end

function ChatSetupController:Start()
	if TextChatService.ChatVersion ~= Enum.ChatVersion.TextChatService then
		return
	end
	local chat = Social.chat
	enable("BubbleChatConfiguration", chat.bubbles)
	enable("ChatWindowConfiguration", chat.window)
	enable("ChatInputBarConfiguration", chat.window)
end

return ChatSetupController
