--!strict
-- Admin tools on the server (PLAN.md Phase 12 "Admin tools"; docs/phase-12-contracts.md "Ads, analytics, admin").
-- Only Config/Admins users may use them (and, in Studio, anyone when Config/Designer.studioCountsAsAdmin is on, the
-- same rule as DesignerService's HideDesign, so a playtest can try them).
--
-- Net AdminAction { action, targetUserId?, ref? } answers { ok, message, code, logs?, reports?, events? }:
--   kick        removes `targetUserId` from this server with a plain message. Never yourself or another admin.
--   despawn     takes away every car `targetUserId` has out (VehicleService.despawn); yourself included.
--   logs        the recent log: server warnings and errors (LogService) and admin actions, oldest first, plus the
--               latest design reports (DesignerService.recentReports) and analytics events (AnalyticsService).
--   hideDesign  hides design or mod `ref` everywhere through DesignerService's own hide path (DesignerService.hide,
--               the one the HideDesign remote uses; the panel falls back to that remote only if this answers
--               "unavailable").
-- Every action an admin takes, allowed or refused, goes into the log; a non-admin's first try does too (and warns),
-- their later tries are refused without a line, so nobody can flush the log. Cash and credit grants are not here:
-- they stay Studio-only through the dev remotes (DevSetCash, DevCredits), which the admin panel offers only in Studio.
--
-- The rules are pure (isAdminFor, decide, Ring) so tests/Admin.spec checks them in Edit mode. No polling: the log
-- fills from LogService.MessageOut and the actions themselves.

local LogService = game:GetService("LogService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Admins = require(ReplicatedStorage.Shared.Config.Admins)
local Designer = require(ReplicatedStorage.Shared.Config.Designer)
local Net = require(ReplicatedStorage.Shared.Net)

export type Action = "kick" | "despawn" | "logs" | "hideDesign"

-- What decide() looks at, gathered by the live handler.
export type Facts = {
	isAdmin: boolean, -- the caller
	actorUserId: number,
	targetPresent: boolean, -- targetUserId is a player in this server
	targetIsAdmin: boolean,
	hasCar: boolean, -- the target has a car out
}

export type Entry = { at: number, kind: string, text: string } -- kind: "warning", "error" or "admin"

export type Ring = {
	push: (entry: Entry) -> (),
	list: () -> { Entry },
	size: () -> number,
}

export type Reply = {
	ok: boolean,
	message: string,
	code: string,
	logs: { Entry }?,
	reports: { any }?,
	events: { any }?,
}

local LOG = "[AdminService]"
local LOGS_KEPT = 200 -- log entries kept (the oldest drop off)
local MAX_TEXT = 300 -- characters kept of one log line

-- What admins (and, for kick, the kicked player) read. Plain words.
local MESSAGES: { [string]: string } = {
	notAdmin = "Only admins can do that.",
	noTarget = "Pick a player first.",
	notHere = "That player isn't in this server.",
	self = "You can't do that to yourself.",
	protected = "Admins can't kick other admins.",
	noCar = "That player has no car out.",
	noRef = "Type the design or car id first.",
	unknown = "That isn't an admin action.",
	unavailable = "Hiding from the admin panel isn't ready on this server yet.",
	kicked = "%s was removed from the server.", -- their name
	despawned = "%s's car was put away.", -- their name
	logs = "Here's the latest.",
	hidden = "Hidden.",
	failed = "That didn't work. Try again in a moment.",
	kickReason = "A moderator removed you from this server. You can rejoin later.",
}

local AdminService = {}
AdminService.MESSAGES = MESSAGES

local VehicleService: any = nil
local DesignerService: any = nil
local AnalyticsService: any = nil

-- Pure rules -------------------------------------------------------------------------------------------------

-- Whether `userId` may use the admin tools: on the list, or anyone in Studio when Studio counts as admin.
function AdminService.isAdminFor(userId: number, list: { number }, inStudio: boolean, studioCounts: boolean): boolean
	if inStudio and studioCounts then
		return true
	end
	return table.find(list, userId) ~= nil
end

-- Whether `action` may go ahead; the second value is the MESSAGES key that says why not (or "ok").
function AdminService.decide(action: string, targetUserId: number?, ref: string?, facts: Facts): (boolean, string)
	if not facts.isAdmin then
		return false, "notAdmin"
	end
	if action == "logs" then
		return true, "ok"
	elseif action == "hideDesign" then
		if ref == nil or string.match(ref, "^%s*$") ~= nil then
			return false, "noRef"
		end
		return true, "ok"
	elseif action == "kick" or action == "despawn" then
		if targetUserId == nil then
			return false, "noTarget"
		elseif not facts.targetPresent then
			return false, "notHere"
		end
		if action == "kick" then
			if targetUserId == facts.actorUserId then
				return false, "self"
			elseif facts.targetIsAdmin then
				return false, "protected"
			end
			return true, "ok"
		end
		if not facts.hasCar then
			return false, "noCar"
		end
		return true, "ok"
	end
	return false, "unknown"
end

-- A fixed-size log: the newest `max` entries, oldest first.
function AdminService.newRing(max: number): Ring
	local entries: { Entry } = {}
	local ring: Ring = {
		push = function(entry: Entry)
			table.insert(entries, entry)
			while #entries > max do
				table.remove(entries, 1)
			end
		end,
		list = function(): { Entry }
			local copy: { Entry } = {}
			for _, entry in entries do
				table.insert(copy, table.clone(entry))
			end
			return copy
		end,
		size = function(): number
			return #entries
		end,
	}
	return ring
end

-- One log line, cut to MAX_TEXT characters (bytes, when it isn't valid UTF-8).
function AdminService.clip(text: string): string
	local length = utf8.len(text)
	if length == nil then
		return string.sub(text, 1, MAX_TEXT)
	elseif length <= MAX_TEXT then
		return text
	end
	local cut = utf8.offset(text, MAX_TEXT + 1)
	return if cut ~= nil then string.sub(text, 1, cut - 1) else text
end

-- The live log ------------------------------------------------------------------------------------------------

local ring = AdminService.newRing(LOGS_KEPT)
local triedWithoutRights: { [Player]: boolean } = {} -- non-admins already logged trying AdminAction (once each)

local function log(kind: string, text: string)
	ring.push({ at = os.time(), kind = kind, text = AdminService.clip(text) })
end

-- The recent log, oldest first (copies).
function AdminService.recentLogs(): { Entry }
	return ring.list()
end

local function isAdmin(player: Player): boolean
	return AdminService.isAdminFor(player.UserId, Admins.userIds, RunService:IsStudio(), Designer.studioCountsAsAdmin)
end
AdminService.isAdmin = isAdmin

local function reply(ok: boolean, code: string, name: string?): Reply
	local message = MESSAGES[code] or MESSAGES.failed
	if name ~= nil then
		message = string.format(message, name)
	end
	return { ok = ok, message = message, code = code }
end

local function hasCar(player: Player): boolean
	local service = VehicleService
	if service == nil or type(service.getCar) ~= "function" then
		return false
	end
	local ok, car = pcall(service.getCar, player)
	return ok and car ~= nil
end

local function hide(admin: Player, ref: string): Reply
	local service = DesignerService
	if service == nil or type(service.hide) ~= "function" then
		return reply(false, "unavailable")
	end
	local ok, result = pcall(service.hide, admin, ref)
	if not ok then
		warn(`{LOG} hide {ref} failed: {result}`)
		return reply(false, "failed")
	end
	local answer: any = result
	if type(answer) == "table" and type(answer.message) == "string" then
		return { ok = answer.ok == true, message = answer.message, code = if answer.ok then "hidden" else "failed" }
	end
	return reply(true, "hidden")
end

local function onAdminAction(player: Player, payload: any): Reply
	local action: string = payload.action
	local targetUserId: number? = payload.targetUserId
	local ref: string? = payload.ref
	local target = if targetUserId ~= nil then Players:GetPlayerByUserId(targetUserId) else nil
	local facts: Facts = {
		isAdmin = isAdmin(player),
		actorUserId = player.UserId,
		targetPresent = target ~= nil,
		targetIsAdmin = target ~= nil and isAdmin(target),
		hasCar = target ~= nil and hasCar(target),
	}
	local allowed, code = AdminService.decide(action, targetUserId, ref, facts)
	local subject = if target ~= nil then `{target.Name} ({target.UserId})` else tostring(targetUserId or ref or "")
	if not allowed then
		if code == "notAdmin" then
			-- Their first try is enough to know: logging every one would let a player push the real entries out.
			if triedWithoutRights[player] then
				return reply(false, code)
			end
			triedWithoutRights[player] = true
			warn(`{LOG} {player.Name} ({player.UserId}) tried AdminAction {action} without being an admin`)
		end
		log("admin", `{player.Name} ({player.UserId}): {action} {subject} refused ({code})`)
		return reply(false, code)
	end
	if action == "logs" then
		local answer = reply(true, "logs")
		answer.logs = ring.list()
		local designer = DesignerService
		if designer ~= nil and type(designer.recentReports) == "function" then
			local ok, reports = pcall(designer.recentReports)
			answer.reports = if ok and type(reports) == "table" then reports else {}
		end
		local analytics = AnalyticsService
		if analytics ~= nil and type(analytics.recent) == "function" then
			local ok, events = pcall(analytics.recent)
			answer.events = if ok and type(events) == "table" then events else {}
		end
		return answer
	end
	log("admin", `{player.Name} ({player.UserId}): {action} {subject}`)
	print(`{LOG} {player.Name} ({player.UserId}): {action} {subject}`)
	if action == "kick" and target ~= nil then
		local name = target.Name
		target:Kick(MESSAGES.kickReason)
		return reply(true, "kicked", name)
	elseif action == "despawn" and target ~= nil then
		local ok, err = pcall(VehicleService.despawn, target)
		if not ok then
			warn(`{LOG} despawn for {target.Name} failed: {err}`)
			return reply(false, "failed")
		end
		return reply(true, "despawned", target.Name)
	elseif action == "hideDesign" and ref ~= nil then
		return hide(player, ref)
	end
	return reply(false, "unknown")
end

-- Boot ---------------------------------------------------------------------------------------------------------

local function optional(name: string): any
	local module = script.Parent:FindFirstChild(name)
	if module == nil or not module:IsA("ModuleScript") then
		return nil
	end
	local ok, result = pcall(require :: any, module)
	return if ok and type(result) == "table" then result else nil
end

function AdminService:Init()
	VehicleService = optional("VehicleService")
	DesignerService = optional("DesignerService")
	AnalyticsService = optional("AnalyticsService")
end

function AdminService:Start()
	Net.onServerInvoke("AdminAction", onAdminAction)
	Players.PlayerRemoving:Connect(function(player: Player)
		triedWithoutRights[player] = nil
	end)
	LogService.MessageOut:Connect(function(message: string, messageType: Enum.MessageType)
		if messageType == Enum.MessageType.MessageWarning then
			log("warning", message)
		elseif messageType == Enum.MessageType.MessageError then
			log("error", message)
		end
	end)
end

return AdminService
