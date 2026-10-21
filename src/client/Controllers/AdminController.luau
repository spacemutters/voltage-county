--!strict
-- The admin panel's controller (PLAN.md Phase 12 "Admin tools"; docs/phase-12-contracts.md "Ads, analytics,
-- admin"). Mounts UI/Admin/AdminPanel only for Config/Admins users (and, in Studio, for anyone while
-- Config/Designer.studioCountsAsAdmin is on, the server's own rule); everyone else gets nothing at all. The check
-- here only decides whether to draw the panel: Services/AdminService checks every request again.
--
-- What it sends (Net, rate-limited there):
--   AdminAction { action = "kick" | "despawn", targetUserId }   Kick asks for a second tap first
--   AdminAction { action = "logs" }                              fills the log, design reports and analytics lines
--   AdminAction { action = "hideDesign", ref }                   falls back to Net HideDesign { designUid } while
--                                                                the server answers "unavailable"
--   DevSetCash { amount } / DevCredits { amount }               Studio only (the server refuses them elsewhere)
-- The panel opens with its button or AdminStyle.toggleKey. No polling: the log is fetched when the panel opens and
-- on Refresh; the player list follows Players.PlayerAdded / PlayerRemoving.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local React = require(ReplicatedStorage.Packages.React)
local ReactRoblox = require(ReplicatedStorage.Packages.ReactRoblox)
local Admins = require(ReplicatedStorage.Shared.Config.Admins)
local Designer = require(ReplicatedStorage.Shared.Config.Designer)
local Net = require(ReplicatedStorage.Shared.Net)
local HudController = require(script.Parent.HudController)

local AdminPanel = require(script.Parent.Parent.UI.Admin.AdminPanel)
local AdminStyle = require(script.Parent.Parent.UI.Admin.AdminStyle)

local GUI_NAME = "AdminPanel"
local UNAVAILABLE = "unavailable" -- AdminService's code while DesignerService.hide isn't exported

local e = React.createElement

local AdminController = {}

type State = {
	open: boolean,
	busy: boolean,
	status: string?,
	confirmKick: number?,
	logs: { AdminPanel.LogLine },
	reports: { string },
	events: { string },
	scale: number,
}

local state: State = {
	open = false,
	busy = false,
	status = nil,
	confirmKick = nil,
	logs = {},
	reports = {},
	events = {},
	scale = 1,
}
local root: any = nil
local confirmToken = 0

-- Whether this player gets the panel (the server's rule; it checks again on every request).
function AdminController.isAdmin(userId: number, inStudio: boolean): boolean
	if inStudio and Designer.studioCountsAsAdmin then
		return true
	end
	return table.find(Admins.userIds, userId) ~= nil
end

local function playerRows(): { AdminPanel.PlayerRow }
	local rows: { AdminPanel.PlayerRow } = {}
	for _, player in Players:GetPlayers() do
		table.insert(rows, { userId = player.UserId, name = player.Name })
	end
	table.sort(rows, function(a, b)
		return string.lower(a.name) < string.lower(b.name)
	end)
	return rows
end

local actions: { [string]: any } = {}

local function render()
	if root == nil then
		return
	end
	root:render(e(AdminPanel, {
		scale = state.scale,
		open = state.open,
		busy = state.busy,
		status = state.status,
		players = playerRows(),
		selfUserId = Players.LocalPlayer.UserId,
		confirmKick = state.confirmKick,
		logs = state.logs,
		reports = state.reports,
		events = state.events,
		studio = RunService:IsStudio(),
		onToggle = actions.toggle,
		onKick = actions.kick,
		onDespawn = actions.despawn,
		onRefresh = actions.refresh,
		onHide = actions.hide,
		onCash = actions.cash,
		onCredits = actions.credits,
	}))
end

-- Sends one request in the background and shows the answer's message. `apply` reads anything else it returned.
local function request(remote: string, payload: any, apply: ((answer: any) -> ())?)
	if state.busy then
		return
	end
	state.busy = true
	state.status = nil
	render()
	task.spawn(function()
		local ok, answer = pcall(Net.invokeServer, remote, payload)
		state.busy = false
		if ok and type(answer) == "table" then
			state.status = if type(answer.message) == "string" then answer.message else nil
			if apply ~= nil then
				apply(answer)
			end
		else
			state.status = AdminStyle.text.noAnswer
		end
		render()
	end)
end

local function reportLine(report: any): string
	if type(report) ~= "table" then
		return tostring(report)
	end
	local at = if type(report.at) == "number" then os.date("!%H:%M:%S", report.at) else "?"
	return `{at} {tostring(report.reason)}: design {tostring(report.designUid)} / car {tostring(report.vehicleUid)}`
		.. ` of user {tostring(report.owner)} (by {tostring(report.reporter)})`
end

local function eventLine(event: any): string
	if type(event) ~= "table" then
		return tostring(event)
	end
	local at = if type(event.at) == "number" then os.date("!%H:%M:%S", event.at) else "?"
	return `{at} {tostring(event.name)} {tostring(event.detail)} (user {tostring(event.userId)})`
end

local function applyLogs(answer: any)
	local logs: { AdminPanel.LogLine } = {}
	if type(answer.logs) == "table" then
		for _, entry in answer.logs do
			if type(entry) == "table" and type(entry.text) == "string" then
				table.insert(logs, {
					at = if type(entry.at) == "number" then entry.at else 0,
					kind = tostring(entry.kind),
					text = entry.text,
				})
			end
		end
	end
	state.logs = logs
	local reports: { string } = {}
	if type(answer.reports) == "table" then
		for _, report in answer.reports do
			table.insert(reports, reportLine(report))
		end
	end
	state.reports = reports
	local events: { string } = {}
	if type(answer.events) == "table" then
		for _, event in answer.events do
			table.insert(events, eventLine(event))
		end
	end
	state.events = events
end

function actions.refresh()
	request("AdminAction", { action = "logs" }, applyLogs)
end

function actions.toggle()
	state.open = not state.open
	state.confirmKick = nil
	render()
	if state.open then
		actions.refresh()
	end
end

-- The first tap arms the button for AdminStyle.confirmSeconds; the second kicks.
function actions.kick(userId: number)
	if state.confirmKick ~= userId then
		state.confirmKick = userId
		confirmToken += 1
		local token = confirmToken
		render()
		task.delay(AdminStyle.confirmSeconds, function()
			if confirmToken == token and state.confirmKick == userId then
				state.confirmKick = nil
				render()
			end
		end)
		return
	end
	state.confirmKick = nil
	request("AdminAction", { action = "kick", targetUserId = userId })
end

function actions.despawn(userId: number)
	state.confirmKick = nil
	request("AdminAction", { action = "despawn", targetUserId = userId })
end

function actions.hide(text: string)
	local ref = string.match(text, "^%s*(.-)%s*$") or ""
	request("AdminAction", { action = "hideDesign", ref = if ref ~= "" then ref else nil }, function(answer: any)
		if answer.code == UNAVAILABLE and ref ~= "" then
			-- DesignerService's hide isn't reachable through AdminAction yet: its own admin-only remote does it.
			task.defer(request, "HideDesign", { designUid = ref })
		end
	end)
end

function actions.cash(amount: number)
	request("DevSetCash", { amount = amount })
end

function actions.credits(amount: number)
	request("DevCredits", { amount = amount })
end

-- Boot ---------------------------------------------------------------------------------------------------------

function AdminController:Start()
	local player = Players.LocalPlayer
	if not AdminController.isAdmin(player.UserId, RunService:IsStudio()) then
		return
	end
	local playerGui = player:WaitForChild("PlayerGui")
	local gui = Instance.new("ScreenGui")
	gui.Name = GUI_NAME
	gui.ResetOnSpawn = false -- one panel for the whole session
	gui.DisplayOrder = AdminStyle.displayOrder
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.ScreenInsets = Enum.ScreenInsets.CoreUISafeInsets
	gui.Parent = playerGui

	root = ReactRoblox.createRoot(gui)
	state.scale = HudController.scaleFor(gui.AbsoluteSize)
	gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		local scale = HudController.scaleFor(gui.AbsoluteSize)
		if scale ~= state.scale then
			state.scale = scale
			render()
		end
	end)
	Players.PlayerAdded:Connect(function()
		render()
	end)
	Players.PlayerRemoving:Connect(function()
		task.defer(render) -- after the player has left the list
	end)
	UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
		if not processed and input.KeyCode == AdminStyle.toggleKey then
			actions.toggle()
		end
	end)
	render()
end

return AdminController
