--!strict
-- The store's shared client state (docs/phase-12-contracts.md "Store UI"): the small bridge between
-- Controllers/StoreController and the screens that show the store. The phone's screens (UI/Phone/Phone, StoreApp)
-- can't require StoreController, because it requires PhoneController (to open the Store app) and PhoneController
-- requires them; they read and call this instead, and it requires nothing of ours but UI/Store/StoreModel.
--
--   state      the last GetStore answer (normalized), whether it's loading or failed, the request with the server
--              (one at a time), the Store app's page, the events from EventUpdate, the daily streak, Roblox Plus,
--              whether invites can be sent, whether a one-time offer waits to be seen, whether the free ad credit
--              can be offered, and the Season Pass attributes. StoreController keeps it.
--   actions    refresh, buyProduct, buyPass, joinClub, claimStreak, invite, getPlus, open, watchAd, buyDrop,
--              claimSeason: StoreController registers what they do at Start. Called before that (or without it) they
--              do nothing.
--   clock      now(): server UTC seconds (Workspace:GetServerTimeNow()); setClock swaps it for a fake one.
--   useState   a React hook: the latest state, re-rendering the component when it changes.
--
-- No polling: listeners are called when the state changes.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local React = require(ReplicatedStorage.Packages.React)

local StoreModel = require(script.Parent.StoreModel)

export type Page = "credits" | "passes" | "more"
export type Invite = "unknown" | "yes" | "no"

export type State = {
	store: StoreModel.Store?,
	loading: boolean, -- a GetStore call is with the server
	failed: boolean, -- the last GetStore call got no answer
	fetchedAt: number?, -- os.clock() of the last good answer
	-- The request with the server: "product:<key>", "pass:<key>", "club", "streak", "offer", "ad", "drop:<id>",
	-- "season:<track>".
	busy: string?,
	page: Page,
	events: { StoreModel.Event },
	streak: StoreModel.Streak?,
	plusMember: boolean?, -- the player has Roblox Plus (nil: unknown)
	plusAvailable: boolean, -- this client can show Roblox's Plus prompt
	invite: Invite, -- whether this player can send game invites
	offerDue: boolean, -- a one-time offer waits to be shown
	adReady: boolean, -- the free daily ad credit is on offer and Roblox says an ad can play now
	season: StoreModel.SeasonInput, -- the Season Pass attributes Services/SeasonService keeps
}

export type Handlers = {
	refresh: (force: boolean) -> (),
	buyProduct: (key: string) -> (),
	buyPass: (key: string) -> (),
	joinClub: () -> (),
	claimStreak: () -> (),
	invite: () -> (),
	getPlus: () -> (),
	open: (page: Page?) -> (),
	watchAd: () -> (),
	buyDrop: (dropId: string) -> (),
	claimSeason: (tier: number, track: StoreModel.SeasonTrack) -> (),
}

type Listener = (state: State) -> ()

local StoreState = {}

local state: State = {
	store = nil,
	loading = false,
	failed = false,
	fetchedAt = nil,
	busy = nil,
	page = "credits",
	events = {},
	streak = nil,
	plusMember = nil,
	plusAvailable = false,
	invite = "unknown",
	offerDue = false,
	adReady = false,
	season = { xp = nil, premium = nil, claimed = nil },
}
local listeners: { [number]: Listener } = {}
local nextListener = 0
local handlers: Handlers? = nil

local function serverNow(): number
	return Workspace:GetServerTimeNow()
end

local clock: () -> number = serverNow

-- The current state. Read-only: a new table replaces it on every change.
function StoreState.get(): State
	return state
end

-- Changes the state: `change` edits a copy, and the listeners hear about it.
function StoreState.update(change: (draft: State) -> ())
	local draft = table.clone(state)
	change(draft)
	state = draft
	for _, listener in table.clone(listeners) do
		task.spawn(listener, state)
	end
end

-- Calls `listener(state)` after every change. Returns the function that stops it.
function StoreState.subscribe(listener: Listener): () -> ()
	nextListener += 1
	local id = nextListener
	listeners[id] = listener
	return function()
		listeners[id] = nil
	end
end

-- A React hook: the latest state; the component re-renders when it changes.
function StoreState.useState(): State
	local current, setCurrent = React.useState(state)
	React.useEffect(function()
		setCurrent(state) -- a change between the render and this effect
		return StoreState.subscribe(function(latest: State)
			setCurrent(latest)
		end)
	end, {})
	return current
end

-- The clock ------------------------------------------------------------------------------------------------------

-- Server UTC seconds, the time events and the streak are counted in.
function StoreState.now(): number
	return clock()
end

-- Swaps the clock (a fake one in a test); nil puts the server's back.
function StoreState.setClock(fake: (() -> number)?)
	clock = fake or serverNow
end

-- Actions --------------------------------------------------------------------------------------------------------

-- StoreController says what the actions do (once, at Start).
function StoreState.register(newHandlers: Handlers)
	handlers = newHandlers
end

-- Shows another page of the Store app.
function StoreState.setPage(page: Page)
	if page ~= state.page then
		StoreState.update(function(draft: State)
			draft.page = page
		end)
	end
end

-- Asks the server for the store again: always with `force`, else only when the last answer is old.
function StoreState.refresh(force: boolean?)
	local current = handlers
	if current ~= nil then
		current.refresh(force == true)
	end
end

function StoreState.buyProduct(key: string)
	local current = handlers
	if current ~= nil then
		current.buyProduct(key)
	end
end

function StoreState.buyPass(key: string)
	local current = handlers
	if current ~= nil then
		current.buyPass(key)
	end
end

function StoreState.joinClub()
	local current = handlers
	if current ~= nil then
		current.joinClub()
	end
end

function StoreState.claimStreak()
	local current = handlers
	if current ~= nil then
		current.claimStreak()
	end
end

function StoreState.invite()
	local current = handlers
	if current ~= nil then
		current.invite()
	end
end

function StoreState.getPlus()
	local current = handlers
	if current ~= nil then
		current.getPlus()
	end
end

-- Opens the phone's Store app (on `page`), putting a designer sheet away first.
function StoreState.open(page: Page?)
	local current = handlers
	if current ~= nil then
		current.open(page)
	end
end

-- Plays a rewarded ad for the free daily credit (Net WatchAdReward).
function StoreState.watchAd()
	local current = handlers
	if current ~= nil then
		current.watchAd()
	end
end

-- Buys one of a limited drop (Net BuyLimited { dropId }).
function StoreState.buyDrop(dropId: string)
	local current = handlers
	if current ~= nil then
		current.buyDrop(dropId)
	end
end

-- Claims a Season Pass reward (Net ClaimSeasonReward { tier, track }).
function StoreState.claimSeason(tier: number, track: StoreModel.SeasonTrack)
	local current = handlers
	if current ~= nil then
		current.claimSeason(tier, track)
	end
end

return StoreState
