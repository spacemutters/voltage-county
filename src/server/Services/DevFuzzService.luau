--!strict
-- The fuzz test's server side (PLAN.md Phase 14; docs/phase-14-contracts.md "Security"), Studio only (CLAUDE.md hard
-- rule 8). Dev/FuzzTests fires every client -> server remote with hostile payloads and asks this service, through
-- Net DevFuzz { action }, what the server made of them:
--   "begin"   starts recording for the caller (calling it again starts over):
--               * every server error and warning: ScriptContext.Error (with the script it came from, when that is
--                 ours: under ServerScriptService, ReplicatedStorage or ServerStorage) and LogService MessageError /
--                 MessageWarning lines, one entry per distinct text with a count. Lines the run is meant to cause
--                 are left out (EXPECTED: AntiExploitService's rejected-call summaries);
--               * every Net rejection of the caller's calls, by remote and reason (Net.onReject);
--               * a snapshot of the caller's economy (economyOf): cash, starterClaimed, cars and their looks,
--                 garage and custom slots, designs, credits, fleet pods and collect time, job licenses, house
--                 upgrades, codes, season id / premium / claims, streak, offers, cosmetics, club, receipts, pending
--                 grants and boosts. What moves on its own while nobody does anything is left out, so it never
--                 counts as a change: a car's energy and favourite star, job and season XP, fleet earnings still to
--                 collect and the fleet's online clock, stats and settings.
--   "finish"  stops and returns { ok, message, errors = { Entry }, dropped, changed = { [field] = { before, after } },
--             rejects = { [remote] = { [reason] = count } }, seconds }. `dropped` counts entries past
--             SETTINGS.maxEntries; `before` and `after` are canonical text cut around the first difference.
-- Anything else that pays out on its own still shows (a Fleet Manager pass's auto-collect adds cash on the fleet
-- timer): run the fuzz test without pods, or read a cash change in that light.
--
-- Refused outside Studio, where it never listens to the log or to Net's rejections either. Nothing here changes
-- player data. The pure parts (economyOf, diff, canonical, expected) are exported for tests/NetFuzz.spec.

local LogService = game:GetService("LogService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ScriptContext = game:GetService("ScriptContext")
local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")

local Net = require(ReplicatedStorage.Shared.Net)

-- DataService is required in Init rather than here: requiring it loads ProfileStore, which talks to DataStores
-- straight away, and tests/NetFuzz.spec requires this module in Edit mode (as CodeService does).
type DataServiceModule = typeof(require(script.Parent.DataService))

export type Entry = {
	kind: "error" | "warning",
	text: string,
	source: string?, -- the script, for a ScriptContext error from our code
	count: number, -- how many times this exact text came up
}

export type Change = { before: string, after: string }

export type Reply = {
	ok: boolean,
	message: string,
	errors: { Entry }?,
	dropped: number?,
	changed: { [string]: Change }?,
	rejects: { [string]: { [string]: number } }?,
	seconds: number?,
}

-- An entry and how often each source reported it: one script error comes from both, so it counts once.
type Seen = { entry: Entry, log: number, script: number }

type Session = {
	started: number, -- os.clock()
	snapshot: { [string]: string }, -- economyOf at begin
	entries: { Entry },
	seen: { [string]: Seen }, -- by raw text
	dropped: number,
	rejects: { [string]: { [string]: number } },
}

-- A dev tool, so its numbers live here rather than in Shared/Config (like Dev/SocialTests' SETTINGS).
local SETTINGS = {
	maxEntries = 100, -- errors and warnings kept per run; the rest are only counted
	maxTextChars = 500, -- an entry's text is cut to this
	maxValueChars = 400, -- a changed field's before and after are cut to this
	contextChars = 80, -- and start this far before the first difference
	maxDepth = 12, -- canonical() goes no deeper (saved data is far shallower)
}

local LOG = "[DevFuzz]"
local MESSAGES = {
	studioOnly = "The fuzz test runs only in Studio.",
	notLoaded = "Your data hasn't loaded yet.",
	recording = "Recording server errors, rejected calls and your data.",
	notRecording = "Nothing is being recorded: send begin first.",
	finished = "Recording stopped.",
}

-- Lines a fuzz run is meant to cause (Lua patterns over the raw text): they are not errors.
local EXPECTED: { string } = {
	"^%[AntiExploit%] .- rejected remote call", -- AntiExploitService's summary of Net rejections
}

-- The PlayerData fields that hold value, and how each is read: `keep` (only these keys) or `perItem` (each list
-- entry without these keys). Types.PlayerData has the fields.
type EconomyField = { field: string, keep: { string }?, perItem: { [string]: boolean }? }
local ECONOMY: { EconomyField } = {
	{ field = "cash" },
	{ field = "starterClaimed" },
	{ field = "vehicles", perItem = { energy = true, favorite = true } },
	{ field = "garageSlots" },
	{ field = "designs" },
	{ field = "customSlots" },
	{ field = "credits" },
	{ field = "fleet", keep = { "pods", "lastCollectedAt" } },
	{ field = "jobs", keep = { "licenses" } },
	{ field = "house" },
	{ field = "codesRedeemed" },
	{ field = "season", keep = { "id", "premium", "claimed" } },
	{ field = "streak" },
	{ field = "offersSeen" },
	{ field = "cosmetics" },
	{ field = "club" },
	{ field = "receipts" },
	{ field = "pendingGrants" },
	{ field = "boosts" },
}

local DevFuzzService = {}

local DataService: DataServiceModule? = nil
local sessions: { [Player]: Session } = {}
local connections: { RBXScriptConnection } = {}

-- Pure helpers ----------------------------------------------------------------------------------------------

-- Text safe to send and to JSON-encode on the client: bytes above 127 become "?" (a cut, or a hostile payload
-- quoted in a message, could leave half a character).
local function ascii(text: string): string
	return (string.gsub(text, "[\128-\255]", "?"))
end

local function clip(text: string, limit: number): string
	if #text <= limit then
		return ascii(text)
	end
	return ascii(string.sub(text, 1, limit)) .. "..."
end

-- True for a line a fuzz run is meant to cause (EXPECTED).
function DevFuzzService.expected(text: string): boolean
	for _, pattern in EXPECTED do
		if string.find(text, pattern) ~= nil then
			return true
		end
	end
	return false
end

-- Keys in a stable order: by type name, then by value.
local function keyBefore(a: any, b: any): boolean
	local typeA, typeB = type(a), type(b)
	if typeA ~= typeB then
		return typeA < typeB
	elseif typeA == "number" or typeA == "string" then
		return a < b
	end
	return tostring(a) < tostring(b)
end

-- One text per value that is the same for equal values whatever order their keys were added in.
function DevFuzzService.canonical(value: any, depth: number?): string
	local level = depth or 0
	local kind = type(value)
	if kind == "string" then
		return string.format("%q", value)
	elseif kind == "number" then
		return if value ~= value then "nan" else tostring(value)
	elseif kind ~= "table" then
		return tostring(value)
	elseif level >= SETTINGS.maxDepth then
		return "{...}"
	end
	local keys = {}
	for key in value do
		table.insert(keys, key)
	end
	table.sort(keys, keyBefore)
	local parts = table.create(#keys)
	for _, key in keys do
		local name = if type(key) == "string" then key else `[{tostring(key)}]`
		table.insert(parts, `{name}={DevFuzzService.canonical(value[key], level + 1)}`)
	end
	return "{" .. table.concat(parts, ",") .. "}"
end

local function only(value: any, keep: { string }): any
	if type(value) ~= "table" then
		return value
	end
	local copy = {}
	for _, key in keep do
		copy[key] = value[key]
	end
	return copy
end

local function eachWithout(value: any, skip: { [string]: boolean }): any
	if type(value) ~= "table" then
		return value
	end
	local list = {}
	for index, item in value do
		if type(item) == "table" then
			local copy = {}
			for key, field in item do
				if not skip[key] then
					copy[key] = field
				end
			end
			list[index] = copy
		else
			list[index] = item
		end
	end
	return list
end

-- The economy part of a player's data (ECONOMY), one canonical text per field. A missing or damaged field reads as
-- whatever it is ("nil" when absent), so damage shows as a change too.
function DevFuzzService.economyOf(data: any): { [string]: string }
	local source = if type(data) == "table" then data else {}
	local view: { [string]: string } = {}
	for _, entry in ECONOMY do
		local value = source[entry.field]
		if entry.keep ~= nil then
			value = only(value, entry.keep)
		elseif entry.perItem ~= nil then
			value = eachWithout(value, entry.perItem)
		end
		view[entry.field] = DevFuzzService.canonical(value)
	end
	return view
end

-- The byte where two texts first differ (one past the shorter when one starts the other).
local function firstDifference(a: string, b: string): number
	local length = math.min(#a, #b)
	for index = 1, length do
		if string.byte(a, index) ~= string.byte(b, index) then
			return index
		end
	end
	return length + 1
end

-- At most SETTINGS.maxValueChars of `text`, starting a little before byte `at`.
local function excerpt(text: string, at: number): string
	if #text <= SETTINGS.maxValueChars then
		return ascii(text)
	end
	local first = math.max(1, at - SETTINGS.contextChars)
	local last = math.min(#text, first + SETTINGS.maxValueChars - 1)
	local cut = ascii(string.sub(text, first, last))
	return (if first > 1 then "..." else "") .. cut .. (if last < #text then "..." else "")
end

-- The fields whose canonical text differs between two economyOf views, with excerpts around the difference.
function DevFuzzService.diff(before: { [string]: string }, after: { [string]: string }): { [string]: Change }
	local changed: { [string]: Change } = {}
	for _, entry in ECONOMY do
		local field = entry.field
		local a, b = before[field] or "nil", after[field] or "nil"
		if a ~= b then
			local at = firstDifference(a, b)
			changed[field] = { before = excerpt(a, at), after = excerpt(b, at) }
		end
	end
	return changed
end

-- Recording ------------------------------------------------------------------------------------------------------

-- Adds a line to every recording session. `fromScript`: ScriptContext.Error (which names the script) rather than
-- LogService (which prints the same error text too).
local function record(kind: "error" | "warning", text: string, source: string?, fromScript: boolean)
	if DevFuzzService.expected(text) then
		return
	end
	for _, session in sessions do
		local seen = session.seen[text]
		if seen == nil then
			if #session.entries >= SETTINGS.maxEntries then
				session.dropped += 1
				continue
			end
			local entry: Entry = { kind = kind, text = clip(text, SETTINGS.maxTextChars), source = nil, count = 0 }
			seen = { entry = entry, log = 0, script = 0 }
			session.seen[text] = seen :: Seen
			table.insert(session.entries, entry)
		end
		local known = seen :: Seen
		if fromScript then
			known.script += 1
		else
			known.log += 1
		end
		known.entry.count = math.max(known.log, known.script)
		if known.entry.source == nil and source ~= nil then
			known.entry.source = source
		end
	end
end

local function ours(source: Instance): boolean
	return source:IsDescendantOf(ServerScriptService)
		or source:IsDescendantOf(ReplicatedStorage)
		or source:IsDescendantOf(ServerStorage)
end

-- Listens to the log while anyone is recording. ScriptContext.Error names the script; LogService also prints the
-- same error text, which then counts once.
local function listen()
	if #connections > 0 then
		return
	end
	table.insert(
		connections,
		LogService.MessageOut:Connect(function(message: string, messageType: Enum.MessageType)
			if messageType == Enum.MessageType.MessageError then
				record("error", message, nil, false)
			elseif messageType == Enum.MessageType.MessageWarning then
				record("warning", message, nil, false)
			end
		end)
	)
	table.insert(
		connections,
		ScriptContext.Error:Connect(function(message: string, _stack: string, source: Instance?)
			if source == nil then
				record("error", message, nil, true)
			elseif ours(source) then
				record("error", message, source:GetFullName(), true)
			end
		end)
	)
end

local function stopListening()
	if next(sessions) ~= nil then
		return
	end
	for _, connection in connections do
		connection:Disconnect()
	end
	table.clear(connections)
end

local function onReject(player: Player, remote: string, reason: Net.RejectReason)
	local session = sessions[player]
	if session == nil then
		return
	end
	local counts = session.rejects[remote]
	if counts == nil then
		counts = {}
		session.rejects[remote] = counts
	end
	local byReason = counts :: { [string]: number }
	byReason[reason] = (byReason[reason] or 0) + 1
end

-- The remote -------------------------------------------------------------------------------------------------------

local function begin(player: Player): Reply
	local dataService = DataService
	local data = if dataService ~= nil then dataService.get(player) else nil
	if data == nil then
		return { ok = false, message = MESSAGES.notLoaded }
	end
	sessions[player] = {
		started = os.clock(),
		snapshot = DevFuzzService.economyOf(data),
		entries = {},
		seen = {},
		dropped = 0,
		rejects = {},
	}
	listen()
	print(`{LOG} recording for {player.Name}`)
	return { ok = true, message = MESSAGES.recording }
end

local function finish(player: Player): Reply
	local session = sessions[player]
	if session == nil then
		return { ok = false, message = MESSAGES.notRecording }
	end
	sessions[player] = nil
	stopListening()
	local dataService = DataService
	local data = if dataService ~= nil then dataService.get(player) else nil
	local changed: { [string]: Change } = if data ~= nil
		then DevFuzzService.diff(session.snapshot, DevFuzzService.economyOf(data))
		else {}
	local fields = 0
	for _ in changed do
		fields += 1
	end
	print(`{LOG} {player.Name}: {#session.entries} error/warning lines, {fields} economy fields changed`)
	return {
		ok = data ~= nil,
		message = if data ~= nil then MESSAGES.finished else MESSAGES.notLoaded,
		errors = session.entries,
		dropped = session.dropped,
		changed = changed,
		rejects = session.rejects,
		seconds = os.clock() - session.started,
	}
end

local function onDevFuzz(player: Player, payload: any): Reply
	if not RunService:IsStudio() then
		warn(`{LOG} {player.Name} ({player.UserId}) called DevFuzz outside Studio`)
		return { ok = false, message = MESSAGES.studioOnly } -- dev tools stay dev (CLAUDE.md hard rule 8)
	end
	if payload.action == "begin" then
		return begin(player)
	end
	return finish(player)
end

-- Boot -------------------------------------------------------------------------------------------------------------

function DevFuzzService:Init()
	DataService = require(script.Parent.DataService)
end

function DevFuzzService:Start()
	-- Always listen, so the remote never queues up; the handler itself refuses outside Studio.
	Net.onServerInvoke("DevFuzz", onDevFuzz)
	if not RunService:IsStudio() then
		return
	end
	Net.onReject(onReject)
	Players.PlayerRemoving:Connect(function(player: Player)
		sessions[player] = nil
		stopListening()
	end)
end

return DevFuzzService
