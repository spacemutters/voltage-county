--!strict
-- The player's house on this client (PLAN.md Phase 13; docs/phase-13-contracts.md "Houses"): what the server says
-- about it, and the Home app's requests.
--
--   state        from Net HouseUpdate { plotId?, address?, upgrades, message? }: the plot the player holds on this
--                server (nil: none), its address and the upgrades they own (Config/Houses ids). `loaded` turns true
--                with the first update (sent when their data loads). `busy` names the request with the server
--                ("leave" or "upgrade:<id>"), one at a time; `confirmLeave` is the Home app's "Move out?" step.
--   requests     leave() -> Net LeaveHouse; buy(id) -> Net BuyHouseUpgrade { upgrade }. Each reply's message shows
--                as a notice (NotifyController); the new state follows in a HouseUpdate.
--   GPS          setGpsHome() routes the GPS to the player's plot (GpsController.setDestination, named
--                Config/Houses app.gpsName); directions() with no house routes to Config/Houses directionsPlot.
--   useState     a React hook for UI/Phone/HomeApp: the latest state, re-rendering when it changes.
--
-- Claiming happens at a plot's sign (the server's ProximityPrompt), not here. This controller draws nothing of its
-- own: the Home app lives in the phone, which hides during cutscenes (PhoneConfig.cutsceneAttribute). No polling:
-- everything runs on the remote event and taps. Requiring it has no side effects (UI/Phone/HomeApp requires it).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local React = require(ReplicatedStorage.Packages.React)
local Houses = require(ReplicatedStorage.Shared.Config.Houses)
local Net = require(ReplicatedStorage.Shared.Net)
local GpsController = require(script.Parent.GpsController)
local NotifyController = require(script.Parent.NotifyController)

local PhoneConfig = require(script.Parent.Parent.UI.Phone.PhoneConfig)

export type State = {
	loaded: boolean, -- the server has said where the player lives (or that they don't yet)
	plotId: string?,
	address: string?,
	upgrades: { [string]: boolean }, -- owned, by Config/Houses upgrade id
	busy: string?, -- "leave" or "upgrade:<id>" while a request is with the server
	confirmLeave: boolean, -- the Home app is asking "Move out?"
}

type Listener = (state: State) -> ()

local BUSY_LEAVE = "leave"
local BUSY_UPGRADE = "upgrade:"

local HouseController = {}

local state: State = {
	loaded = false,
	plotId = nil,
	address = nil,
	upgrades = {},
	busy = nil,
	confirmLeave = false,
}
local listeners: { [number]: Listener } = {}
local nextListener = 0

-- State ------------------------------------------------------------------------------------------------------------

-- The current state. Read-only: a new table replaces it on every change.
function HouseController.get(): State
	return state
end

local function update(change: (draft: State) -> ())
	local draft = table.clone(state)
	change(draft)
	state = draft
	for _, listener in table.clone(listeners) do
		task.spawn(listener, state)
	end
end

-- Calls `listener(state)` after every change. Returns the function that stops it.
function HouseController.subscribe(listener: Listener): () -> ()
	nextListener += 1
	local id = nextListener
	listeners[id] = listener
	return function()
		listeners[id] = nil
	end
end

-- A React hook: the latest state; the component re-renders when it changes.
function HouseController.useState(): State
	local current, setCurrent = React.useState(state)
	React.useEffect(function()
		setCurrent(state) -- a change between the render and this effect
		return HouseController.subscribe(function(latest: State)
			setCurrent(latest)
		end)
	end, {})
	return current
end

-- A HouseUpdate payload as a checked part of the state, or nil when it doesn't look right. Pure (tests can call it).
function HouseController.normalize(
	payload: any
): { plotId: string?, address: string?, upgrades: { [string]: boolean } }?
	if type(payload) ~= "table" then
		return nil
	end
	local plotId = if type(payload.plotId) == "string" then payload.plotId else nil
	local address = if type(payload.address) == "string" then payload.address else nil
	local owned: { [string]: boolean } = {}
	if type(payload.upgrades) == "table" then
		for _, id in payload.upgrades do
			if type(id) == "string" and Houses.upgrade(id) ~= nil then
				owned[id] = true
			end
		end
	end
	return { plotId = plotId, address = address, upgrades = owned }
end

-- Requests -----------------------------------------------------------------------------------------------------------

-- Shows a server reply ({ ok, message }) as a notice. Returns true when the request worked.
local function showReply(called: boolean, reply: any): boolean
	if not called then
		NotifyController.show(PhoneConfig.labels.failed, "error")
		return false
	elseif type(reply) == "table" and type(reply.message) == "string" then
		local worked = reply.ok == true
		NotifyController.show(reply.message, if worked then "success" else "error")
		return worked
	end
	-- No answer: Net turned the request away (too many in a row).
	NotifyController.show(PhoneConfig.labels.tryLater, "warning")
	return false
end

-- Sends one request (one at a time) and shows its reply.
local function request(remote: string, payload: any, busy: string)
	if state.busy ~= nil then
		return
	end
	update(function(draft: State)
		draft.busy = busy
	end)
	task.spawn(function()
		local called, reply = pcall(Net.invokeServer, remote, payload)
		showReply(called, reply)
		update(function(draft: State)
			draft.busy = nil
			draft.confirmLeave = false
		end)
	end)
end

-- The busy name for buying an upgrade (HomeApp compares it).
function HouseController.upgradeBusy(id: string): string
	return BUSY_UPGRADE .. id
end

HouseController.leaveBusy = BUSY_LEAVE

function HouseController.buy(id: string)
	request("BuyHouseUpgrade", { upgrade = id }, HouseController.upgradeBusy(id))
end

-- The Home app's "Move out" asks first; askLeave(false) cancels.
function HouseController.askLeave(asking: boolean)
	update(function(draft: State)
		draft.confirmLeave = asking and draft.plotId ~= nil
	end)
end

function HouseController.leave()
	request("LeaveHouse", nil, BUSY_LEAVE)
end

-- Routes the GPS to the player's house (nothing without one).
function HouseController.setGpsHome()
	local plotId = state.plotId
	if plotId ~= nil and GpsController.hasLocation(plotId) then
		GpsController.setDestination(plotId, { name = Houses.app.gpsName })
	end
end

-- With no house: routes the GPS to Riverside's houses.
function HouseController.directions()
	local plotId = Houses.directionsPlot
	if GpsController.hasLocation(plotId) then
		GpsController.setDestination(plotId)
	end
end

-- Boot ---------------------------------------------------------------------------------------------------------------

function HouseController:Start()
	Net.onClientEvent("HouseUpdate", function(payload: any)
		local checked = HouseController.normalize(payload)
		if checked == nil then
			warn("[HouseController] Ignored a house update that didn't look right")
			return
		end
		update(function(draft: State)
			local moved = draft.plotId ~= checked.plotId
			draft.loaded = true
			draft.plotId = checked.plotId
			draft.address = checked.address
			draft.upgrades = checked.upgrades
			if moved or checked.plotId == nil then
				draft.confirmLeave = false
			end
		end)
	end)
end

return HouseController
