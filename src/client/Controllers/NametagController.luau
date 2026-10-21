--!strict
-- Nametags (PLAN.md Phase 13; docs/phase-13-contracts.md "Social"): a BillboardGui over every other player's head
-- with their display name and, under it, the title of their best job level ("Freight Hauler II").
--
--   title      the player attribute Config/Social nametag.titleAttribute, which Services/SocialSetupService keeps
--              from the player's job XP (Config/Social.bestTitle). A player with no job XP shows just their name.
--   look       a small dark rounded panel (UI/Theme colors, 4.5:1 for both lines over a bright sky), a fixed pixel
--              size at every distance, hidden beyond Config/Social nametag.maxDistance. Roblox's own name over the
--              character is switched off on this client (Humanoid.DisplayDistanceType), so the name shows once.
--   hidden     while that character sits in a car going faster than nametag.hideAboveMph (shown again under
--              showBelowMph, so it doesn't flicker), and every nametag while this player's cutscene plays (the
--              LocalPlayer attribute Config/Hail cutscene.attribute). Your own nametag shows only when
--              nametag.showOwn is on.
--
-- Built on the client only (each client draws everyone else's), inside each character's head, so it goes with the
-- character. No polling for the tags themselves: characters, heads, seats and the title come from events. Car speeds
-- are read on a slow timer (nametag.speedCheckSeconds) that runs only while someone sits in a car. Display names
-- come from Roblox and titles from Config/Jobs, so nothing here needs filtering.
--
-- The visibility rules are pure (speedHidden, visible) and exported for tests/Nametags.spec.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Hail = require(ReplicatedStorage.Shared.Config.Hail)
local Social = require(ReplicatedStorage.Shared.Config.Social)
local Spawning = require(ReplicatedStorage.Shared.Config.Spawning)
local Units = require(ReplicatedStorage.Shared.Util.Units)

local Theme = require(script.Parent.Parent.UI.Theme)

local HEAD = "Head"
local NAME_LABEL = "DisplayName"
local TITLE_LABEL = "Title"

local config = Social.nametag
local colors = Theme.colors

type Tag = {
	character: Model,
	gui: BillboardGui?, -- nil until the head arrives
	title: TextLabel?,
	car: BasePart?, -- the chassis of the car the character sits in
	fast: boolean, -- hidden for speed
	connections: { RBXScriptConnection },
}

type PlayerEntry = {
	tag: Tag?, -- the current character's nametag
	connections: { RBXScriptConnection },
}

local NametagController = {}

local entries: { [Player]: PlayerEntry } = {}
local cutscene = false
local speedTimer: thread? = nil

-- Pure rules ---------------------------------------------------------------------------------------------------------

-- Whether a character's nametag is hidden for speed: `speedMph` is the speed of the car it sits in (nil when it
-- isn't in one), `wasHidden` whether it was hidden for speed until now.
function NametagController.speedHidden(wasHidden: boolean, speedMph: number?): boolean
	if speedMph == nil then
		return false
	end
	if wasHidden then
		return speedMph > config.showBelowMph
	end
	return speedMph > config.hideAboveMph
end

-- Whether a nametag shows: not during this player's cutscene, and not while hidden for speed.
function NametagController.visible(inCutscene: boolean, hiddenForSpeed: boolean): boolean
	return not inCutscene and not hiddenForSpeed
end

-- Drawing ------------------------------------------------------------------------------------------------------------

local function label(name: string, text: string, size: number, font: Font, color: Color3, order: number): TextLabel
	local textLabel = Instance.new("TextLabel")
	textLabel.Name = name
	textLabel.LayoutOrder = order
	textLabel.AutomaticSize = Enum.AutomaticSize.XY
	textLabel.Size = UDim2.new()
	textLabel.BackgroundTransparency = 1
	textLabel.FontFace = font
	textLabel.Text = text
	textLabel.TextColor3 = color
	textLabel.TextSize = size
	return textLabel
end

local function titleOf(player: Player): string?
	local title = player:GetAttribute(config.titleAttribute)
	return if type(title) == "string" and title ~= "" then title else nil
end

local function applyTitle(tag: Tag, title: string?)
	local titleLabel = tag.title
	if titleLabel ~= nil then
		titleLabel.Text = title or ""
		titleLabel.Visible = title ~= nil
	end
end

local function applyVisibility(tag: Tag)
	local gui = tag.gui
	if gui ~= nil then
		gui.Enabled = NametagController.visible(cutscene, tag.fast)
	end
end

local function build(player: Player, tag: Tag, head: BasePart)
	local gui = Instance.new("BillboardGui")
	gui.Name = config.guiName
	gui.Adornee = head
	gui.Size = UDim2.fromOffset(config.size.X, config.size.Y)
	gui.StudsOffset = config.studsOffset
	gui.MaxDistance = config.maxDistance
	gui.AlwaysOnTop = false
	gui.LightInfluence = 0
	gui.ClipsDescendants = false

	local panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.AnchorPoint = Vector2.new(0.5, 1)
	panel.Position = UDim2.fromScale(0.5, 1)
	panel.Size = UDim2.new()
	panel.AutomaticSize = Enum.AutomaticSize.XY
	panel.BackgroundColor3 = colors.panel
	panel.BackgroundTransparency = config.panelTransparency
	panel.BorderSizePixel = 0
	panel.Parent = gui

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, config.cornerRadius)
	corner.Parent = panel
	local padding = Instance.new("UIPadding")
	local pad = UDim.new(0, config.padding)
	padding.PaddingLeft, padding.PaddingRight, padding.PaddingTop, padding.PaddingBottom = pad, pad, pad, pad
	padding.Parent = panel
	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = panel
	local limit = Instance.new("UISizeConstraint")
	limit.MaxSize = config.size
	limit.Parent = panel

	local nameLabel = label(NAME_LABEL, player.DisplayName, config.nameTextSize, Theme.fonts.bold, colors.text, 1)
	nameLabel.Parent = panel
	local titleLabel = label(TITLE_LABEL, "", config.titleTextSize, Theme.fonts.medium, colors.accent, 2)
	titleLabel.Parent = panel

	tag.gui = gui
	tag.title = titleLabel
	applyTitle(tag, titleOf(player))
	applyVisibility(tag)
	gui.Parent = head
end

-- Speed --------------------------------------------------------------------------------------------------------------

-- The chassis of the spawned car `seat` belongs to, or nil.
local function carOf(seat: Instance?): BasePart?
	local node = if seat then seat.Parent else nil
	while node ~= nil and node ~= game do
		if node:IsA("Model") and CollectionService:HasTag(node, Spawning.vehicleTag) then
			return node.PrimaryPart
		end
		node = node.Parent
	end
	return nil
end

local scheduleSpeedCheck: () -> ()

-- Looks at every seated character's car speed once, then checks again later while anyone is still in a car.
local function checkSpeeds()
	speedTimer = nil
	local anyone = false
	for _, entry in entries do
		local tag = entry.tag
		if tag == nil then
			continue
		end
		local car = tag.car
		local speed = if car ~= nil and car.Parent ~= nil
			then Units.studsToMph(car.AssemblyLinearVelocity.Magnitude)
			else nil
		anyone = anyone or speed ~= nil
		local fast = NametagController.speedHidden(tag.fast, speed)
		if fast ~= tag.fast then
			tag.fast = fast
			applyVisibility(tag)
		end
	end
	if anyone then
		scheduleSpeedCheck()
	end
end

scheduleSpeedCheck = function()
	if speedTimer == nil then
		speedTimer = task.delay(config.speedCheckSeconds, checkSpeeds)
	end
end

-- Characters ---------------------------------------------------------------------------------------------------------

local function dropTag(entry: PlayerEntry)
	local tag = entry.tag
	entry.tag = nil
	if tag == nil then
		return
	end
	for _, connection in tag.connections do
		connection:Disconnect()
	end
	local gui = tag.gui
	if gui ~= nil then
		gui:Destroy()
	end
end

local function watchHumanoid(tag: Tag, humanoid: Humanoid)
	-- Roblox's own name over the character would show the name twice (this client only; it doesn't replicate).
	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	local function onSeat()
		local car = carOf(humanoid.SeatPart)
		tag.car = car
		if car ~= nil then
			scheduleSpeedCheck()
		elseif tag.fast then
			tag.fast = false
			applyVisibility(tag)
		end
	end
	table.insert(tag.connections, humanoid:GetPropertyChangedSignal("SeatPart"):Connect(onSeat))
	onSeat()
end

local function attach(player: Player, entry: PlayerEntry, character: Model)
	dropTag(entry)
	local tag: Tag = { character = character, gui = nil, title = nil, car = nil, fast = false, connections = {} }
	entry.tag = tag
	local function onChild(child: Instance)
		if entry.tag ~= tag then
			return
		end
		if child.Name == HEAD and child:IsA("BasePart") and tag.gui == nil then
			build(player, tag, child)
		elseif child:IsA("Humanoid") then
			watchHumanoid(tag, child)
		end
	end
	-- Heads and Humanoids can arrive after the character (streaming, the avatar loading).
	table.insert(tag.connections, character.ChildAdded:Connect(onChild))
	for _, child in character:GetChildren() do
		onChild(child)
	end
end

local function addPlayer(player: Player)
	if entries[player] ~= nil then
		return
	end
	local entry: PlayerEntry = { tag = nil, connections = {} }
	entries[player] = entry
	local isOwn = player == Players.LocalPlayer
	if isOwn and not config.showOwn then
		return -- tracked (so it isn't added twice), never drawn
	end
	table.insert(
		entry.connections,
		player.CharacterAdded:Connect(function(character: Model)
			attach(player, entry, character)
		end)
	)
	table.insert(
		entry.connections,
		player.CharacterRemoving:Connect(function(character: Model)
			local tag = entry.tag
			if tag ~= nil and tag.character == character then
				dropTag(entry)
			end
		end)
	)
	table.insert(
		entry.connections,
		player:GetAttributeChangedSignal(config.titleAttribute):Connect(function()
			local tag = entry.tag
			if tag ~= nil then
				applyTitle(tag, titleOf(player))
			end
		end)
	)
	if player.Character ~= nil then
		attach(player, entry, player.Character)
	end
end

local function removePlayer(player: Player)
	local entry = entries[player]
	if entry == nil then
		return
	end
	entries[player] = nil
	dropTag(entry)
	for _, connection in entry.connections do
		connection:Disconnect()
	end
end

-- Cutscene -----------------------------------------------------------------------------------------------------------

local function onCutsceneChanged()
	local now = Players.LocalPlayer:GetAttribute(Hail.cutscene.attribute) == true
	if now == cutscene then
		return
	end
	cutscene = now
	for _, entry in entries do
		local tag = entry.tag
		if tag ~= nil then
			applyVisibility(tag)
		end
	end
end

function NametagController:Start()
	local localPlayer = Players.LocalPlayer
	localPlayer:GetAttributeChangedSignal(Hail.cutscene.attribute):Connect(onCutsceneChanged)
	onCutsceneChanged()
	Players.PlayerAdded:Connect(addPlayer)
	Players.PlayerRemoving:Connect(removePlayer)
	for _, player in Players:GetPlayers() do
		addPlayer(player)
	end
end

return NametagController
