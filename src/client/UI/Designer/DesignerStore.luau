--!strict
-- The AI Car Designer's shared client state (docs/phase-11-contracts.md "Client"): the small bridge between
-- Controllers/DesignerController and the phone. The phone's screens (UI/Phone/Phone, GarageApp, DesignerApp) can't
-- require DesignerController, because it requires PhoneController (to put the phone away) and PhoneController
-- requires them; they read and call this instead, and it requires nothing of ours.
--
--   state      unlocked (the phone's Designer app shows) and status (idle, a request with the server, a result
--              waiting to be seen); DesignerController keeps it up to date.
--   actions    openStudio, openMod(uid), openReport(uid): DesignerController registers what they do at Start.
--              Called before that (or without it) they do nothing.
--   useState   a React hook: the latest state, re-rendering the component when it changes.
--
-- No polling: listeners are called when the state changes.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local React = require(ReplicatedStorage.Packages.React)

-- idle: nothing with the server; working: a design or mod is being made; ready: a new design waits to be seen.
export type Status = "idle" | "working" | "ready"

export type State = {
	unlocked: boolean,
	status: Status,
}

export type Handlers = {
	openStudio: () -> (),
	openMod: (uid: string) -> (),
	openReport: (uid: string) -> (),
}

type Listener = (state: State) -> ()

local DesignerStore = {}

local state: State = { unlocked = false, status = "idle" }
local listeners: { [number]: Listener } = {}
local nextListener = 0
local handlers: Handlers? = nil

-- The current state. Read-only: a new table replaces it on every change.
function DesignerStore.get(): State
	return state
end

-- Changes some fields and tells the listeners when anything actually changed.
function DesignerStore.set(partial: { unlocked: boolean?, status: Status? })
	local unlocked: boolean = if partial.unlocked ~= nil then partial.unlocked else state.unlocked
	local status: Status = if partial.status ~= nil then partial.status else state.status
	if unlocked == state.unlocked and status == state.status then
		return
	end
	state = { unlocked = unlocked, status = status }
	for _, listener in table.clone(listeners) do
		task.spawn(listener, state)
	end
end

-- Calls `listener(state)` after every change. Returns the function that stops it.
function DesignerStore.subscribe(listener: Listener): () -> ()
	nextListener += 1
	local id = nextListener
	listeners[id] = listener
	return function()
		listeners[id] = nil
	end
end

-- A React hook: the latest state; the component re-renders when it changes.
function DesignerStore.useState(): State
	local current, setCurrent = React.useState(state)
	React.useEffect(function()
		setCurrent(state) -- a change between the render and this effect
		return DesignerStore.subscribe(function(latest: State)
			setCurrent(latest)
		end)
	end, {})
	return current
end

-- Actions ------------------------------------------------------------------------------------------------------

-- DesignerController says what the actions do (once, at Start).
function DesignerStore.register(newHandlers: Handlers)
	handlers = newHandlers
end

-- Opens the Design Studio sheet (it puts the phone away).
function DesignerStore.openStudio()
	local current = handlers
	if current ~= nil then
		current.openStudio()
	end
end

-- Opens "Mod with AI" for one of the player's cars (an OwnedVehicle uid).
function DesignerStore.openMod(uid: string)
	local current = handlers
	if current ~= nil then
		current.openMod(uid)
	end
end

-- Opens the Report sheet for one of the player's custom or modded cars.
function DesignerStore.openReport(uid: string)
	local current = handlers
	if current ~= nil then
		current.openReport(uid)
	end
end

return DesignerStore
