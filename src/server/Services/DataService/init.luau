--!strict
-- Player data: loading, saving and the only way to change it (PLAN.md Phase 3; docs/phase-3-contracts.md
-- "Player data").
--
-- Built on the vendored ProfileStore, which does session locking (a profile is open on one server at a time)
-- and autosaving. A player's life:
--   join     start a session for "Player_<UserId>" (cancelled if they leave while it loads), tag it with their
--            UserId, migrate the save to Config/Data.schemaVersion, fill in missing fields from the template,
--            then publish it: `DataLoaded` attribute, waiters and onLoaded listeners.
--            If the session can't start or the save can't be migrated, the player is kicked with a plain
--            message (their saved data is never touched in that case).
--   play     other services read with `get` and change data only through `update`, which refuses whenever the
--            session isn't active (so nothing is ever written to a profile this server no longer owns).
--            onChanged listeners hear about every successful update (and every load), e.g. ProfileSyncService.
--   leave    run the beforeRelease listeners (last writes), then end the session; ProfileStore saves and
--            releases the lock.
--   elsewhere if another server takes the session (the player joined somewhere else), we kick them here.
--   shutdown game:BindToClose runs the beforeRelease listeners for everyone, then ends every open session;
--            ProfileStore holds the server open until they've saved.
--
-- Stores: live servers use Config/Data.storeName. Studio uses studioStoreName so playtests never touch live
-- player data, and when DataStores aren't reachable (Studio with API access off, or no internet) it uses
-- ProfileStore's in-memory mock, so nothing is saved. The mode is logged once.
--
-- No polling: everything runs on player, session and close events. The one exception is a Heartbeat wait at
-- boot, in Studio only, until ProfileStore knows whether DataStores are reachable.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Data = require(ReplicatedStorage.Shared.Config.Data)
local Types = require(ReplicatedStorage.Shared.Types)
local Migrations = require(script.Migrations)
local ProfileStore = require(script.Parent.Parent.Vendor.ProfileStore)
local Template = require(script.Template)

local LOG = "[DataService]"
local NOT_READY = "NotReady" -- ProfileStore.DataStoreState before it has checked DataStore access
local ACCESS = "Access" -- ProfileStore.DataStoreState when DataStores are reachable

-- The parts of a ProfileStore profile and store this service uses (the vendored module's own types are loose).
type Profile = {
	Data: Types.PlayerData,
	FirstSessionTime: number,
	OnSessionEnd: { Connect: (self: any, listener: () -> ()) -> any },
	IsActive: (self: Profile) -> boolean,
	Reconcile: (self: Profile) -> (),
	EndSession: (self: Profile) -> (),
	AddUserId: (self: Profile, userId: number) -> (),
}

type SessionStore = {
	StartSessionAsync: (self: SessionStore, key: string, params: { [string]: any }?) -> Profile?,
}

type Waiter = { thread: thread, timer: thread? }

type LoadedListener = (player: Player, data: Types.PlayerData) -> ()

local DataService = {}

local store: any = nil -- the ProfileStore store, created in Init
local sessionStore: SessionStore? = nil -- store or store.Mock, chosen once DataStore access is known

local profiles: { [Player]: Profile } = {} -- loaded, active sessions
local loading: { [Player]: boolean } = {} -- players whose session is starting
local departed: { [Player]: boolean } = {} -- players who left while their session was starting
local waiters: { [Player]: { Waiter } } = {}
local listeners: { LoadedListener } = {}
local changedListeners: { LoadedListener } = {} -- onChanged: after every successful update, and on load
local releaseListeners: { (player: Player) -> () } = {} -- beforeRelease: last writes before a session ends
local releasing: { [Player]: boolean } = {} -- players whose beforeRelease listeners are running
local closing = false -- set by game:BindToClose

-- Helpers ---------------------------------------------------------------------------------------------------

local function isClosing(): boolean
	return closing or ProfileStore.IsClosing
end

local function inGame(player: Player): boolean
	return departed[player] == nil and player.Parent == Players
end

local function deepCopy<T>(value: T): T
	if type(value) ~= "table" then
		return value
	end
	local copy = {}
	for key, item in value :: any do
		copy[key] = deepCopy(item)
	end
	return copy :: any
end

-- Wakes everyone in waitFor(player) with `data` (nil when the player left or never loaded).
local function releaseWaiters(player: Player, data: Types.PlayerData?)
	local list = waiters[player]
	waiters[player] = nil
	if list == nil then
		return
	end
	for _, waiter in list do
		if waiter.timer ~= nil then
			task.cancel(waiter.timer)
		end
		task.spawn(waiter.thread, data)
	end
end

-- Runs one onChanged listener in its own thread, so one that errors (reported here) or yields never stops the
-- others or the update that triggered it.
local function runChangedListener(listener: LoadedListener, player: Player, data: Types.PlayerData)
	task.spawn(function()
		local ok, err = xpcall(listener, debug.traceback, player, data)
		if not ok then
			warn(`{LOG} an onChanged listener failed for {player.Name}: {err}`)
		end
	end)
end

-- Tells every onChanged listener that `player`'s data changed (or loaded).
local function fireChanged(player: Player, data: Types.PlayerData)
	for _, listener in changedListeners do
		runChangedListener(listener, player, data)
	end
end

-- Yields until ProfileStore has checked DataStore access, then picks the store and logs the mode once.
-- Live servers know at once; Studio checks in the background on boot.
local function resolveStore(): SessionStore
	if sessionStore ~= nil then
		return sessionStore
	end
	if ProfileStore.DataStoreState == NOT_READY then
		local thread = coroutine.running()
		local connection: RBXScriptConnection
		connection = RunService.Heartbeat:Connect(function()
			if ProfileStore.DataStoreState ~= NOT_READY then
				connection:Disconnect()
				task.spawn(thread)
			end
		end)
		coroutine.yield()
	end
	if sessionStore == nil then -- another caller may have resolved it while this one waited
		if ProfileStore.DataStoreState == ACCESS then
			sessionStore = store
			print(`{LOG} saving player data to the "{store.Name}" store`)
		else
			sessionStore = store.Mock
			print(
				`{LOG} DataStores unreachable ({ProfileStore.DataStoreState}): using an in-memory store, nothing will save`
			)
		end
	end
	return sessionStore :: SessionStore
end

-- Session lifecycle -----------------------------------------------------------------------------------------

-- The session ended on this server: we ended it (leave, shutdown) or another server took it over.
-- Leave and shutdown remove the profile from `profiles` before ending it, so a profile still listed here was
-- ended by ProfileStore: another server took the session, or ProfileStore's own shutdown save ran first.
local function onSessionEnd(player: Player, profile: Profile)
	if profiles[player] ~= profile then
		return -- we ended it ourselves
	end
	profiles[player] = nil
	player:SetAttribute(Data.loadedAttribute, false)
	if inGame(player) and not isClosing() then
		player:Kick(Data.messages.sessionEnded)
	end
end

-- Migrates a copy of the save, so a refused save is never half-upgraded. Returns nil and a kick message on failure.
local function migrate(profile: Profile, player: Player): (Types.PlayerData?, string?)
	local raw = profile.Data :: any
	local ok, result = pcall(Migrations.run, deepCopy(raw))
	if ok then
		return result :: any, nil
	end
	warn(`{LOG} can't migrate {player.Name}'s save: {result}`)
	local version = if type(raw) == "table" then raw.version else nil
	if type(version) == "number" and version > Data.schemaVersion then
		return nil, Data.messages.newerVersion
	end
	return nil, Data.messages.loadFailed
end

local function loadPlayer(player: Player)
	if loading[player] or profiles[player] ~= nil then
		return
	end
	loading[player] = true

	local profile: Profile? = nil
	local session = resolveStore()
	if inGame(player) and not isClosing() then
		-- Cancel stops ProfileStore retrying once the player has left or the server is closing. (The mock store
		-- ignores params; it loads at once, and the check after this call covers a player who left meanwhile.)
		-- Passing Cancel turns off ProfileStore's own give-up timer, so the deadline here replaces it: past it,
		-- this returns nil and the player is kicked below.
		local deadline = os.clock() + Data.sessionStartTimeout
		profile = session:StartSessionAsync(Data.profileKeyPrefix .. player.UserId, {
			Cancel = function(): boolean
				return not inGame(player) or isClosing() or os.clock() > deadline
			end,
		})
	end
	loading[player] = nil
	local stillHere = inGame(player)
	departed[player] = nil

	if profile == nil then
		if stillHere and not isClosing() then
			warn(`{LOG} couldn't start a session for {player.Name}`)
			player:Kick(Data.messages.loadFailed)
		end
		releaseWaiters(player, nil)
		return
	end
	local active: Profile = profile
	if not stillHere or isClosing() or not active:IsActive() then
		active:EndSession()
		releaseWaiters(player, nil)
		return
	end

	-- Nothing below yields, so the session stays active throughout (ProfileStore's IsActive guarantee).
	active:AddUserId(player.UserId) -- GDPR: ties the save to the player for erasure requests
	local migrated, problem = migrate(active, player)
	if migrated == nil then
		active:EndSession() -- the save is unchanged; this only releases the lock
		player:Kick(problem or Data.messages.loadFailed)
		releaseWaiters(player, nil)
		return
	end
	-- Anything that throws past this point must still release the lock, or it leaks until shutdown.
	local ready: Types.PlayerData = migrated
	local prepared, prepareErr = pcall(function()
		active.Data = ready
		active:Reconcile() -- fills fields this save is missing from the template, keeping everything it has
		Template.stamp(active.Data, os.time()) -- a brand-new profile gets its real join time
	end)
	if not prepared then
		warn(`{LOG} can't prepare {player.Name}'s save: {prepareErr}`)
		active:EndSession()
		player:Kick(Data.messages.loadFailed)
		releaseWaiters(player, nil)
		return
	end

	active.OnSessionEnd:Connect(function()
		onSessionEnd(player, active)
	end)
	profiles[player] = active
	player:SetAttribute(Data.loadedAttribute, true)

	local data = active.Data
	releaseWaiters(player, data)
	for _, listener in listeners do
		task.spawn(listener, player, data)
	end
	fireChanged(player, data)
end

-- Runs every beforeRelease listener for a player whose session is about to end, in order and right now (no
-- yielding), while `update` still accepts their writes. One that errors is reported and the rest still run.
local function runBeforeRelease(player: Player)
	if profiles[player] == nil then
		return
	end
	releasing[player] = true
	for _, listener in releaseListeners do
		local ok, err = xpcall(listener, debug.traceback, player)
		if not ok then
			warn(`{LOG} a beforeRelease listener failed for {player.Name}: {err}`)
		end
	end
	releasing[player] = nil
end

local function onPlayerRemoving(player: Player)
	if loading[player] then
		departed[player] = true -- loadPlayer sees this, cancels or ends the session and clears it
	end
	runBeforeRelease(player)
	local profile = profiles[player]
	profiles[player] = nil
	if profile ~= nil then
		profile:EndSession()
	end
	releaseWaiters(player, nil)
end

local function onClose()
	-- Last writes first (beforeRelease), while every session is still open.
	for player in profiles do
		runBeforeRelease(player)
	end
	closing = true
	-- ProfileStore saves and releases every active session on close and keeps the server open until they're
	-- done. Ending them here as well makes the order explicit: no update lands after its final save, and
	-- OnSessionEnd sees `closing` and doesn't kick anyone.
	for player, profile in profiles do
		profiles[player] = nil
		profile:EndSession()
	end
end

-- API -------------------------------------------------------------------------------------------------------

-- The player's data, or nil until it has loaded. Read-only outside DataService: change it with `update`.
function DataService.get(player: Player): Types.PlayerData?
	local profile = profiles[player]
	return if profile ~= nil then profile.Data else nil
end

-- The only way to change player data. `fn` gets the live data table and must not yield (a yield could outlast
-- the session). Check everything before changing anything: if `fn` errors, the error is reported, this returns
-- false and any changes it already made stay. Returns false without calling `fn` if the data isn't loaded or
-- the session isn't active (the player left, the server is closing, or another server took the session).
function DataService.update(player: Player, fn: (data: Types.PlayerData) -> ()): boolean
	local profile = profiles[player]
	-- beforeRelease listeners may still write while the server closes: their session is open until just after.
	if profile == nil or (isClosing() and not releasing[player]) or not profile:IsActive() then
		return false
	end
	local ok, err = xpcall(fn, debug.traceback, profile.Data)
	if not ok then
		warn(`{LOG} update for {player.Name} failed: {err}`)
		return false
	end
	fireChanged(player, profile.Data)
	return true
end

-- Yields until the player's data has loaded and returns it; nil if they leave, loading fails, or `timeout`
-- seconds (default Config/Data.waitForTimeout) pass first.
function DataService.waitFor(player: Player, timeout: number?): Types.PlayerData?
	local data = DataService.get(player)
	if data ~= nil or not inGame(player) then
		return data
	end
	local list = waiters[player]
	if list == nil then
		list = {}
		waiters[player] = list
	end
	local waiter: Waiter = { thread = coroutine.running(), timer = nil }
	table.insert(list, waiter)
	waiter.timer = task.delay(if timeout ~= nil then timeout else Data.waitForTimeout, function()
		local current = waiters[player]
		if current ~= nil then
			local index = table.find(current, waiter)
			if index ~= nil then
				table.remove(current, index)
			end
			if #current == 0 then
				waiters[player] = nil
			end
		end
		task.spawn(waiter.thread, nil)
	end)
	return coroutine.yield()
end

-- Calls `fn(player, data)` whenever a player's data loads, starting with everyone already loaded.
function DataService.onLoaded(fn: LoadedListener)
	table.insert(listeners, fn)
	for player, profile in profiles do
		task.spawn(fn, player, profile.Data)
	end
end

-- Calls `fn(player, data)` after every successful `update` and whenever a player's data loads, starting with
-- everyone already loaded (like onLoaded), so a listener never misses a player's current data. `data` is the
-- live table: read it, don't change it. Listeners run in their own threads (an error is reported and the rest
-- still run) and must not call `update` every time they're told about a change, or they'd loop forever.
function DataService.onChanged(fn: LoadedListener)
	table.insert(changedListeners, fn)
	for player, profile in profiles do
		runChangedListener(fn, player, profile.Data)
	end
end

-- Calls `fn(player)` just before a loaded player's session ends: when they leave, and for everyone when the
-- server closes. It runs before the session is released, so `update` still works inside it (even while the
-- server closes); it must not yield. For services that keep state outside the save and write it back on the
-- way out (EnergyService's car levels). Register in Init or Start.
function DataService.beforeRelease(fn: (player: Player) -> ())
	table.insert(releaseListeners, fn)
end

-- Lifecycle -------------------------------------------------------------------------------------------------

function DataService:Init()
	local name = if RunService:IsStudio() then Data.studioStoreName else Data.storeName
	-- ProfileStore copies this template into every new profile, so its time fields are left unset and
	-- stamped per player on load (Template.stamp).
	store = ProfileStore.New(name, Template.new(Template.UNSET_TIME))
end

function DataService:Start()
	Players.PlayerRemoving:Connect(onPlayerRemoving)
	game:BindToClose(onClose)

	resolveStore() -- may wait briefly in Studio; players who join meanwhile are picked up below
	Players.PlayerAdded:Connect(loadPlayer)
	for _, player in Players:GetPlayers() do
		task.spawn(loadPlayer, player)
	end
end

return DataService
