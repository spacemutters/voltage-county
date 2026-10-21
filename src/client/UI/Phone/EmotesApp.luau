--!strict
-- The phone's Emotes app (PLAN.md Phase 13; docs/phase-13-contracts.md "Social"): Roblox's default emotes (wave,
-- point, cheer, laugh and the three dances; Config/Social emotes.list), two buttons to a row. Tapping one plays it on
-- the player's own character and puts the phone away so they can see it; walking stops it.
--
-- On foot only: while the character sits anywhere (a car, a passenger seat) the buttons are off and a line says to
-- get out first; the app follows the Humanoid's SeatPart, so it changes the moment they sit or stand. The emote
-- plays through Humanoid:PlayEmoteAsync (PlayEmote's current name), and when the avatar has no such emote equipped,
-- through the default Animate script's own emote hook, which knows Roblox's built-in ones. Both run on the client,
-- and Roblox replicates the character's animation to everyone, so no remote is needed. If neither plays it (the
-- character is moving, or a custom animation script), a notice says so.
--
-- UI/Phone/Phone mounts it for the "emotes" app (and draws its icon, Glyph). The module returns the component as
-- `App`, the icon as `Glyph`, and onFoot and play.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local React = require(ReplicatedStorage.Packages.React)
local Social = require(ReplicatedStorage.Shared.Config.Social)

local Kit = require(script.Parent.Kit)
local Theme = require(script.Parent.Parent.Theme)
local NotifyController = require(script.Parent.Parent.Parent.Controllers.NotifyController)

local e = React.createElement
local colors = Theme.colors
local config = Social.emotes

local FAILED_KIND = "warning" -- the notice's kind (Config/Gps toast.kindColors)

export type Props = {
	onClose: () -> (), -- puts the phone away once an emote starts
}

local EmotesApp = {}

-- The local character's living Humanoid, or nil.
local function localHumanoid(): Humanoid?
	local character = Players.LocalPlayer.Character
	local humanoid = if character then character:FindFirstChildOfClass("Humanoid") else nil
	if humanoid == nil or humanoid.Health <= 0 then
		return nil
	end
	return humanoid
end

-- True when the local character is alive and not sitting anywhere.
function EmotesApp.onFoot(): boolean
	local humanoid = localHumanoid()
	return humanoid ~= nil and humanoid.SeatPart == nil
end

-- Asks the Humanoid to play emote `id` (PlayEmoteAsync, or PlayEmote where that's all there is), then the Animate
-- script's hook (Roblox's built-in emotes). Yields.
local function playOn(humanoid: Humanoid, id: string): boolean
	for _, method in { "PlayEmoteAsync", "PlayEmote" } do
		local ok, played = pcall(function(): any
			return (humanoid :: any)[method](humanoid, id)
		end)
		if ok and played == true then
			return true
		end
	end
	local character = humanoid.Parent
	local animate = if character then character:FindFirstChild(config.animateScript) else nil
	local hook = if animate then animate:FindFirstChild(config.playEmoteBindable) else nil
	if hook == nil or not hook:IsA("BindableFunction") then
		return false
	end
	local hookOk, result = pcall(function(): any
		return (hook :: BindableFunction):Invoke(id)
	end)
	return hookOk and result == true
end

-- Plays emote `id` on the local character if it is on foot. Returns false at once when it isn't (or `id` isn't one of
-- Config/Social's emotes); otherwise true, and a notice follows if the emote doesn't play after all.
function EmotesApp.play(id: string): boolean
	local known = false
	for _, emote in config.list do
		if emote.id == id then
			known = true
			break
		end
	end
	local humanoid = localHumanoid()
	if not known or humanoid == nil or humanoid.SeatPart ~= nil then
		return false
	end
	task.spawn(function()
		if not playOn(humanoid, id) then
			NotifyController.show(config.text.failed, FAILED_KIND)
		end
	end)
	return true
end

-- A React hook: whether the local character is on foot, kept current as it sits, stands and respawns.
local function useOnFoot(): boolean
	local onFoot, setOnFoot = React.useState(EmotesApp.onFoot())
	React.useEffect(function()
		local player = Players.LocalPlayer
		local humanoidConnections: { RBXScriptConnection } = {}
		local alive = true -- false once the app closes (a respawn may still be waiting for its Humanoid)
		local function refresh()
			setOnFoot(EmotesApp.onFoot())
		end
		local function watch(character: Model?)
			if not alive then
				return
			end
			for _, connection in humanoidConnections do
				connection:Disconnect()
			end
			table.clear(humanoidConnections)
			local humanoid = if character then character:FindFirstChildOfClass("Humanoid") else nil
			if humanoid ~= nil then
				table.insert(humanoidConnections, humanoid:GetPropertyChangedSignal("SeatPart"):Connect(refresh))
				table.insert(humanoidConnections, humanoid.Died:Connect(refresh))
			end
			refresh()
		end
		local added = player.CharacterAdded:Connect(function(character: Model)
			-- The Humanoid may arrive a moment after the character.
			character:WaitForChild("Humanoid")
			watch(character)
		end)
		watch(player.Character)
		return function()
			alive = false
			added:Disconnect()
			for _, connection in humanoidConnections do
				connection:Disconnect()
			end
		end
	end, {})
	return onFoot
end

function EmotesApp.App(props: Props)
	local onFoot = useOnFoot()
	local text = config.text
	local children: { [string]: any } = {
		Intro = Kit.Text({
			text = if onFoot then text.intro else text.onFootOnly,
			order = 1,
			color = if onFoot then colors.textDim else colors.warning,
			font = if onFoot then Theme.fonts.regular else Theme.fonts.medium,
		}),
	}
	local columns = config.columns
	local list = config.list
	local rows = math.ceil(#list / columns)
	for row = 1, rows do
		local buttons: { [string]: any } = {}
		local count = 0
		for column = 1, columns do
			local emote = list[(row - 1) * columns + column]
			if emote == nil then
				break
			end
			count += 1
			buttons[`Emote_{emote.id}`] = e(Kit.Button, {
				label = emote.label,
				order = column,
				disabled = not onFoot,
				onTap = function()
					if EmotesApp.play(emote.id) then
						props.onClose() -- let them see it
					end
				end,
			})
		end
		-- A short last row keeps the same button width as the full rows.
		children[`Row{row}`] = Kit.ButtonRow({ order = row + 1, buttons = buttons, count = math.max(count, columns) })
	end
	return Kit.Page({ gap = Theme.spacing.sm }, children)
end

-- The icon ------------------------------------------------------------------------------------------------------------

local function piece(at: Vector2, size: Vector2, color: Color3, radius: number, rotation: number, round: boolean?)
	return e("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(at.X, at.Y),
		Size = UDim2.fromScale(size.X, if round then size.X else size.Y),
		SizeConstraint = if round then Enum.SizeConstraint.RelativeXX else Enum.SizeConstraint.RelativeXY,
		Rotation = rotation,
		BackgroundColor3 = color,
		BorderSizePixel = 0,
	}, {
		Corner = e("UICorner", { CornerRadius = UDim.new(radius, 0) }),
	})
end

-- The Emotes icon: a little figure cheering with both arms up, like UI/Phone/Glyphs (no image assets).
function EmotesApp.Glyph(props: { color: Color3, background: Color3, size: Vector2? })
	local ink = props.color
	local size = props.size
	return e("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = if size then UDim2.fromOffset(size.X, size.Y) else UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
	}, {
		Head = piece(Vector2.new(0.5, 0.16), Vector2.new(0.24, 0), ink, 0.5, 0, true),
		Body = piece(Vector2.new(0.5, 0.5), Vector2.new(0.14, 0.36), ink, 0.5, 0),
		LeftArm = piece(Vector2.new(0.32, 0.3), Vector2.new(0.1, 0.34), ink, 0.5, -40),
		RightArm = piece(Vector2.new(0.68, 0.3), Vector2.new(0.1, 0.34), ink, 0.5, 40),
		LeftLeg = piece(Vector2.new(0.4, 0.8), Vector2.new(0.11, 0.34), ink, 0.5, 18),
		RightLeg = piece(Vector2.new(0.6, 0.8), Vector2.new(0.11, 0.34), ink, 0.5, -18),
	})
end

return EmotesApp
