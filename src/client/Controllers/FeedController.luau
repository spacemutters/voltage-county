--!strict
-- The phone's Feed on the client (PLAN.md Phase 13; docs/phase-13-contracts.md "Social"): recent events on this
-- server, newest first, from Net FeedUpdate { id, kind, text, at, meetSpotId?, cars?, backlog? }.
--
--   entries    kept newest first (by `at`, server time), one per id, at most Config/Social feed.maxEntries.
--   toast      every new entry shows as a notice (NotifyController), except the backlog the server sends a player
--              who just joined, and except while a cutscene plays (the LocalPlayer attribute PhoneConfig
--              cutsceneAttribute; the entry still goes in the Feed).
--   unseen     how many new entries arrived since the Feed app was last open: UI/Phone/Phone puts an accent dot on
--              the Feed icon while it is above 0, and UI/Phone/FeedApp clears it (markSeen) while it shows.
--
-- UI/Phone/FeedApp and UI/Phone/Phone read the state with the useFeed hook. This module requires nothing that
-- requires the phone, so they can require it. Pure helpers (normalize, insert) are exported for specs. No polling:
-- the remote and the cutscene attribute drive everything.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local React = require(ReplicatedStorage.Packages.React)
local Net = require(ReplicatedStorage.Shared.Net)
local Social = require(ReplicatedStorage.Shared.Config.Social)
local NotifyController = require(script.Parent.NotifyController)

local PhoneConfig = require(script.Parent.Parent.UI.Phone.PhoneConfig)

export type Entry = Social.FeedEntry

export type State = {
	entries: { Entry }, -- newest first
	unseen: number,
}

type Listener = (state: State) -> ()

local FeedController = {}

local state: State = { entries = {}, unseen = 0 }
local listeners: { [number]: Listener } = {}
local nextListener = 0

-- Pure helpers ---------------------------------------------------------------------------------------------------

-- A FeedUpdate payload as an entry, and whether it is backlog (sent on join); nil when it is malformed.
function FeedController.normalize(payload: any): (Entry?, boolean)
	if type(payload) ~= "table" then
		return nil, false
	end
	local id, kind, text, at = payload.id, payload.kind, payload.text, payload.at
	if type(id) ~= "string" or type(kind) ~= "string" or type(text) ~= "string" or type(at) ~= "number" then
		return nil, false
	end
	if id == "" or text == "" or at ~= at then
		return nil, false
	end
	local entry: Entry = { id = id, kind = kind, text = text, at = at }
	if type(payload.meetSpotId) == "string" then
		entry.meetSpotId = payload.meetSpotId
	end
	if type(payload.cars) == "number" then
		entry.cars = payload.cars
	end
	return entry, payload.backlog == true
end

-- `entries` with `entry` added: newest first by `at` (a tie keeps the one already there first), an entry with an id
-- already listed replaced, at most `limit` kept. A new list; `entries` is not changed. Also returns whether the entry
-- is new (its id wasn't listed).
function FeedController.insert(entries: { Entry }, entry: Entry, limit: number): ({ Entry }, boolean)
	local list: { Entry } = {}
	local fresh = true
	for _, existing in entries do
		if existing.id == entry.id then
			fresh = false
		else
			table.insert(list, existing)
		end
	end
	local at = #list + 1
	for index, existing in list do
		if entry.at > existing.at then
			at = index
			break
		end
	end
	table.insert(list, at, entry)
	while #list > limit do
		table.remove(list)
	end
	return list, fresh
end

-- State ------------------------------------------------------------------------------------------------------------

local function setState(nextState: State)
	state = nextState
	for _, listener in table.clone(listeners) do
		task.spawn(listener, state)
	end
end

function FeedController.get(): State
	return state
end

-- Calls `listener(state)` after every change. Returns the function that stops it.
function FeedController.subscribe(listener: Listener): () -> ()
	nextListener += 1
	local id = nextListener
	listeners[id] = listener
	return function()
		listeners[id] = nil
	end
end

-- A React hook: the latest state; the component re-renders when it changes.
function FeedController.useFeed(): State
	local current, setCurrent = React.useState(state)
	React.useEffect(function()
		setCurrent(state) -- a change between the render and this effect
		return FeedController.subscribe(function(latest: State)
			setCurrent(latest)
		end)
	end, {})
	return current
end

-- The Feed app is showing: nothing in it is new any more.
function FeedController.markSeen()
	if state.unseen ~= 0 then
		setState({ entries = state.entries, unseen = 0 })
	end
end

local function inCutscene(): boolean
	local player = Players.LocalPlayer
	return player ~= nil and player:GetAttribute(PhoneConfig.cutsceneAttribute) == true
end

local function onFeedUpdate(payload: any)
	local entry, backlog = FeedController.normalize(payload)
	if entry == nil then
		return
	end
	local entries, fresh = FeedController.insert(state.entries, entry, Social.feed.maxEntries)
	local live = fresh and not backlog
	setState({ entries = entries, unseen = if live then state.unseen + 1 else state.unseen })
	if live and not inCutscene() then
		NotifyController.show(entry.text, Social.feed.toastKind)
	end
end

function FeedController:Start()
	Net.onClientEvent("FeedUpdate", onFeedUpdate)
end

return FeedController
