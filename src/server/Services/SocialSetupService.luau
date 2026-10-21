--!strict
-- Social setup on the server (PLAN.md Phase 13; docs/phase-13-contracts.md "Social", nametags and chat).
--
--   titles   keeps every player's nametag title in the player attribute Config/Social nametag.titleAttribute: the
--            title of their best job level (Config/Social.bestTitle over PlayerData.jobs.xp), or nil while they have
--            no job XP. Set when their data loads and again whenever it changes (DataService.onChanged), only when
--            the title itself changes. Every client's Controllers/NametagController reads it. The title comes from
--            Config/Jobs, never from a player, so it needs no filtering.
--   chat     TextChatService's own chat with its defaults: bubble chat on (Config/Social chat.bubbles). Nothing here
--            makes channels, sends messages or rewrites text, so everything players type goes through Roblox's
--            filtering. Warns once (and changes nothing) when the place still uses the legacy chat or has its default
--            channels switched off: both are set in Studio, on TextChatService's properties.
--
-- No polling: data-change listeners only.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextChatService = game:GetService("TextChatService")

local Social = require(ReplicatedStorage.Shared.Config.Social)
local Types = require(ReplicatedStorage.Shared.Types)
local DataService = require(script.Parent.DataService)

local LOG = "[SocialSetupService]"

local SocialSetupService = {}

local function publishTitle(player: Player, data: Types.PlayerData)
	local jobs = (data :: any).jobs
	local title = Social.bestTitle(if type(jobs) == "table" then jobs.xp else nil)
	local attribute = Social.nametag.titleAttribute
	if player:GetAttribute(attribute) ~= title then
		player:SetAttribute(attribute, title)
	end
end

local function setupChat()
	if TextChatService.ChatVersion ~= Enum.ChatVersion.TextChatService then
		warn(`{LOG} The place uses the legacy chat. Set TextChatService.ChatVersion to TextChatService in Studio.`)
		return
	end
	local ok, defaults = pcall(function(): boolean
		return TextChatService.CreateDefaultTextChannels
	end)
	if ok and not defaults then
		warn(`{LOG} TextChatService.CreateDefaultTextChannels is off, so players have no chat channel. Turn it on.`)
	end
	local bubbles = TextChatService:FindFirstChildOfClass("BubbleChatConfiguration")
	if bubbles ~= nil then
		bubbles.Enabled = Social.chat.bubbles
	end
end

function SocialSetupService:Start()
	setupChat()
	DataService.onChanged(publishTitle)
end

return SocialSetupService
