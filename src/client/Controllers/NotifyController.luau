--!strict
-- Short on-screen notices (docs/phase-2-contracts.md "GPS, spawn flow, notices"). Owns its own ScreenGui and
-- renders UI/Toast with react-lua: one notice at a time at the top centre, fading out after a few seconds,
-- with any others queued behind it.
--
-- Notices come from the server through Net "Notify" ({ text, kind }) and from client code through
-- NotifyController.show (the GPS uses it on arrival). A notice that is already showing or waiting is not
-- queued twice, and when the queue is long the oldest waiting notice is dropped. Timing runs on task.delay;
-- nothing here polls.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local React = require(ReplicatedStorage.Packages.React)
local ReactRoblox = require(ReplicatedStorage.Packages.ReactRoblox)
local Gps = require(ReplicatedStorage.Shared.Config.Gps)
local Net = require(ReplicatedStorage.Shared.Net)
local HudController = require(script.Parent.HudController)

local Toast = require(script.Parent.Parent.UI.Toast)

local GUI_NAME = "Notices"

type Notice = { id: number, text: string, kind: string }

local e = React.createElement

local NotifyController = {}

local queue: { Notice } = {} -- waiting, oldest first
local current: Notice? = nil -- on screen
local leaving = false -- the current notice is fading out
local nextId = 0
local scale = 1
local root: any = nil
local started = false

-- The whole tree: the root frame is sized 1/scale so that, after the UIScale, it fills the screen and the
-- toast is laid out in unscaled (phone) pixels, like the driving HUD.
local function App(props: { notice: Notice?, leaving: boolean, scale: number })
	local children: { [string]: any } = {
		Scale = e("UIScale", { Scale = props.scale }),
	}
	local notice = props.notice
	if notice then
		-- Keyed by id, so each notice mounts fresh and fades in.
		children[`Toast{notice.id}`] = e(Toast, { text = notice.text, kind = notice.kind, leaving = props.leaving })
	end
	return e("Frame", {
		Size = UDim2.fromScale(1 / props.scale, 1 / props.scale),
		BackgroundTransparency = 1,
	}, children)
end

local function render()
	if root then
		root:render(e(App, { notice = current, leaving = leaving, scale = scale }))
	end
end

-- Shows the next waiting notice, then schedules its fade out and the one after it.
local function advance()
	current = table.remove(queue, 1)
	leaving = false
	render()
	local shown = current
	if shown == nil then
		return
	end
	local toast = Gps.toast
	local seconds = if #queue > 0 then toast.busyVisibleSeconds else toast.visibleSeconds
	task.delay(seconds, function()
		if current ~= shown then
			return
		end
		leaving = true
		render()
		task.delay(toast.fadeOutSeconds, function()
			if current ~= shown then
				return
			end
			current = nil
			advance()
		end)
	end)
end

-- Shows a short notice to the local player. `kind` picks the dot color ("info", "success", "warning",
-- "error"; default "info").
function NotifyController.show(text: string, kind: string?)
	local toast = Gps.toast
	local clean = string.match(text, "^%s*(.-)%s*$") or ""
	if clean == "" then
		return
	end
	-- Cut very long notices on a character boundary (utf8.len is nil for invalid text; leave that as it is).
	local length = utf8.len(clean)
	if length ~= nil and length > toast.maxChars then
		local cut = utf8.offset(clean, toast.maxChars + 1)
		if cut ~= nil then
			clean = string.sub(clean, 1, cut - 1) .. "..."
		end
	end
	-- The same notice already on screen or waiting is not shown twice.
	if current and current.text == clean and not leaving then
		return
	end
	for _, waiting in queue do
		if waiting.text == clean then
			return
		end
	end
	nextId += 1
	table.insert(queue, { id = nextId, text = clean, kind = kind or toast.defaultKind })
	while #queue > toast.maxQueued do
		table.remove(queue, 1)
	end
	if started and current == nil then
		advance()
	end
end

function NotifyController:Start()
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")

	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = GUI_NAME
	screenGui.ResetOnSpawn = false -- one GUI for the whole session
	screenGui.DisplayOrder = Gps.toast.displayOrder
	screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	-- Keep notices clear of the Roblox top bar and notches.
	screenGui.ScreenInsets = Enum.ScreenInsets.CoreUISafeInsets
	screenGui.Parent = playerGui

	root = ReactRoblox.createRoot(screenGui)
	scale = HudController.scaleFor(screenGui.AbsoluteSize)
	screenGui:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		local newScale = HudController.scaleFor(screenGui.AbsoluteSize)
		if newScale ~= scale then
			scale = newScale
			render()
		end
	end)

	-- Server notices. The payload is trusted (server -> client) but checked anyway, so a bad one is ignored.
	Net.onClientEvent("Notify", function(payload: any)
		if type(payload) ~= "table" or type(payload.text) ~= "string" then
			return
		end
		local kind = if type(payload.kind) == "string" then payload.kind else nil
		NotifyController.show(payload.text, kind)
	end)

	started = true
	if current == nil and #queue > 0 then
		advance()
	else
		render()
	end
end

return NotifyController
