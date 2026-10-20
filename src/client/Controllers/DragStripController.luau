--!strict
-- The drag strip on the client (docs/phase-10-contracts.md "Arc tuning, drag strip and leaderboard"). The server
-- times every run (Services/DragStripService); this controller keeps this player's run state from Net
-- "DragStripUpdate" and shows what the server says as a toast through NotifyController: "Ready" when a run arms,
-- the time (with a new best and the week's rank) when it finishes, and the reason when it's void. Nothing shows
-- for the start itself, so the screen stays clear for the launch.
--
-- Studio test drivers and later screens read it through state(), lastUpdate(), onUpdate() and
-- fetchLeaderboard() (Net "GetDragLeaderboard"). Every time is in seconds; startedAt/finishedAt are the server
-- clock times (Workspace:GetServerTimeNow()) of the gate-1 and gate-4 crossings. No polling: one remote listener.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Net = require(ReplicatedStorage.Shared.Net)
local NotifyController = require(script.Parent.NotifyController)

export type State = "idle" | "armed" | "running" | "finished" | "fault"

-- One DragStripUpdate, checked.
export type Update = {
	state: State,
	message: string?,
	gate: number?, -- "running": the gate just crossed (1 = the start; 2 and 3 carry a split in `time`)
	time: number?, -- seconds from gate 1: to gate 4 ("finished") or to `gate` (a "running" split)
	best: number?, -- this player's best this week, seconds
	rank: number?, -- their place on this week's board
	newBest: boolean?,
	splits: { number }?, -- seconds from the start to gates 2 and 3
	startedAt: number?,
	finishedAt: number?,
}

export type Leaderboard = {
	week: string,
	entries: { { name: string, time: number } },
	best: number?,
	rank: number?,
}

type Listener = (update: Update) -> ()

-- The toast kind (Config/Gps toast.kindColors) for each state that shows one.
local TOAST_KINDS: { [State]: string } = {
	armed = "info",
	finished = "success",
	fault = "warning",
}

local STATES: { [string]: boolean } = { armed = true, running = true, finished = true, fault = true }

local DragStripController = {}

local state: State = "idle"
local last: Update? = nil
local listeners: { Listener } = {}

local function optionalNumber(value: any): number?
	return if type(value) == "number" and value == value then value else nil
end

-- A server payload as an Update, or nil when it isn't one. Server -> client payloads are trusted but checked
-- anyway, so a bad one is ignored.
function DragStripController.parse(payload: any): Update?
	if type(payload) ~= "table" or type(payload.state) ~= "string" or not STATES[payload.state] then
		return nil
	end
	local splits: { number }? = nil
	if type(payload.splits) == "table" then
		local list: { number } = {}
		for _, split in payload.splits do
			local seconds = optionalNumber(split)
			if seconds ~= nil then
				table.insert(list, seconds)
			end
		end
		splits = list
	end
	return {
		state = payload.state :: State,
		message = if type(payload.message) == "string" then payload.message else nil,
		gate = optionalNumber(payload.gate),
		time = optionalNumber(payload.time),
		best = optionalNumber(payload.best),
		rank = optionalNumber(payload.rank),
		newBest = if type(payload.newBest) == "boolean" then payload.newBest else nil,
		splits = splits,
		startedAt = optionalNumber(payload.startedAt),
		finishedAt = optionalNumber(payload.finishedAt),
	}
end

-- This player's run state: "idle" until the first update, then the latest update's state.
function DragStripController.state(): State
	return state
end

-- The latest update, or nil.
function DragStripController.lastUpdate(): Update?
	return last
end

-- Calls `listener(update)` after every update (in its own thread). Returns a function that removes it.
function DragStripController.onUpdate(listener: Listener): () -> ()
	table.insert(listeners, listener)
	return function()
		local index = table.find(listeners, listener)
		if index ~= nil then
			table.remove(listeners, index)
		end
	end
end

-- This week's board from the server (yields), or nil when the request was refused.
function DragStripController.fetchLeaderboard(): Leaderboard?
	local ok, result = pcall(Net.invokeServer, "GetDragLeaderboard")
	if not ok or type(result) ~= "table" or type(result.week) ~= "string" or type(result.entries) ~= "table" then
		return nil
	end
	local entries: { { name: string, time: number } } = {}
	for _, entry in result.entries do
		if type(entry) == "table" and type(entry.name) == "string" and optionalNumber(entry.time) ~= nil then
			table.insert(entries, { name = entry.name, time = entry.time })
		end
	end
	return {
		week = result.week,
		entries = entries,
		best = optionalNumber(result.best),
		rank = optionalNumber(result.rank),
	}
end

local function onUpdate(payload: any)
	local update = DragStripController.parse(payload)
	if update == nil then
		return
	end
	state = update.state
	last = update
	local kind = TOAST_KINDS[update.state]
	local message = update.message
	if kind ~= nil and message ~= nil then
		NotifyController.show(message, kind)
	end
	for _, listener in table.clone(listeners) do
		task.spawn(listener, update)
	end
end

function DragStripController:Start()
	Net.onClientEvent("DragStripUpdate", onUpdate)
end

return DragStripController
