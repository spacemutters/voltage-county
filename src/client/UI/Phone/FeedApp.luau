--!strict
-- The phone's Feed app (PLAN.md Phase 13; docs/phase-13-contracts.md "Social"): what's been happening on this server,
-- newest first. Each entry is a card: what kind it is and how long ago ("Car meet · 3 min ago"), the words, and for a
-- car meet a Directions button that routes the GPS to the meet spot and puts the phone away. With nothing yet, one
-- line says what shows up here.
--
-- UI/Phone/Phone mounts it for the "feed" app (and draws its icon, Glyph). It reads the entries itself
-- (Controllers/FeedController.useFeed) and marks them seen while it shows, which clears the dot on the Feed icon.
-- Presentation only. The module returns the component as `App`, the icon as `Glyph` and the pure ageText for specs.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local React = require(ReplicatedStorage.Packages.React)
local Social = require(ReplicatedStorage.Shared.Config.Social)

local Kit = require(script.Parent.Kit)
local Theme = require(script.Parent.Parent.Theme)
local Controllers = script.Parent.Parent.Parent.Controllers
local FeedController = require(Controllers.FeedController)
local GpsController = require(Controllers.GpsController)

local e = React.createElement
local colors = Theme.colors
local feed = Social.feed
local text = feed.text

local LINE = 2.5 -- px, the icon's outline (UI/Phone/Glyphs' stroke)
local SEPARATOR = " · " -- between the kind and the age

export type Props = {
	onClose: () -> (), -- puts the phone away (after Directions)
}

local FeedApp = {}

-- "Just now", "3 min ago", "2 h ago" for an entry `seconds` old.
function FeedApp.ageText(seconds: number): string
	local age = math.max(0, seconds)
	if age < feed.justNowSeconds then
		return text.justNow
	elseif age < feed.secondsPerHour then
		return string.format(text.minutesAgo, math.floor(age / feed.secondsPerMinute))
	end
	return string.format(text.hoursAgo, math.floor(age / feed.secondsPerHour))
end

local function EntryCard(props: { entry: Social.FeedEntry, now: number, order: number, onClose: () -> () })
	local entry = props.entry
	local kind = text.kindLabels[entry.kind]
	local age = FeedApp.ageText(props.now - entry.at)
	local spot = entry.meetSpotId
	local children: { [string]: any } = {
		Meta = Kit.Text({
			text = if kind then kind .. SEPARATOR .. age else age,
			order = 1,
			size = Theme.text.small,
			font = Theme.fonts.medium,
			color = colors.textDim,
		}),
		Body = Kit.Text({ text = entry.text, order = 2, font = Theme.fonts.medium }),
	}
	if spot ~= nil and GpsController.hasLocation(spot) then
		children.Directions = e(Kit.Button, {
			label = text.directions,
			order = 3,
			onTap = function()
				GpsController.setDestination(spot)
				props.onClose() -- show the road and the route line
			end,
		})
	end
	return Kit.Card({ order = props.order }, children)
end

function FeedApp.App(props: Props)
	local state = FeedController.useFeed()

	-- Showing the Feed: everything in it has been seen (again whenever something new arrives while it shows).
	React.useEffect(function()
		FeedController.markSeen()
	end, { state.unseen })

	local children: { [string]: any } = {}
	if #state.entries == 0 then
		children.Empty = Kit.Card({ order = 1 }, {
			Text = Kit.Text({ text = text.empty, color = colors.textDim }),
		})
	else
		local now = Workspace:GetServerTimeNow()
		for index, entry in state.entries do
			children[`Entry_{entry.id}`] = e(EntryCard, {
				entry = entry,
				now = now,
				order = index,
				onClose = props.onClose,
			})
		end
	end
	return Kit.Page({ gap = Theme.spacing.md }, children)
end

-- The icon ------------------------------------------------------------------------------------------------------------

local function piece(at: Vector2, size: Vector2, color: Color3, radius: number, order: number, outline: number?)
	local children: { [string]: any } = {
		Corner = e("UICorner", { CornerRadius = UDim.new(radius, 0) }),
	}
	if outline then
		children.Stroke = e("UIStroke", {
			ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
			Color = color,
			Thickness = outline,
		})
	end
	return e("Frame", {
		ZIndex = order,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(at.X, at.Y),
		Size = UDim2.fromScale(size.X, size.Y),
		BackgroundColor3 = color,
		BackgroundTransparency = if outline then 1 else 0,
		BorderSizePixel = 0,
	}, children)
end

-- The Feed icon: a card with a bright dot and three lines of news, like UI/Phone/Glyphs (no image assets).
function FeedApp.Glyph(props: { color: Color3, background: Color3, size: Vector2? })
	local ink = props.color
	local size = props.size
	return e("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = if size then UDim2.fromOffset(size.X, size.Y) else UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
	}, {
		Card = piece(Vector2.new(0.5, 0.5), Vector2.new(0.9, 0.82), ink, 0.18, 1, LINE),
		Dot = piece(Vector2.new(0.28, 0.32), Vector2.new(0.16, 0.16), ink, 0.5, 2),
		Top = piece(Vector2.new(0.6, 0.32), Vector2.new(0.36, 0.08), ink, 0.5, 2),
		Middle = piece(Vector2.new(0.5, 0.52), Vector2.new(0.56, 0.08), ink, 0.5, 2),
		Bottom = piece(Vector2.new(0.42, 0.7), Vector2.new(0.4, 0.08), ink, 0.5, 2),
	})
end

return FeedApp
