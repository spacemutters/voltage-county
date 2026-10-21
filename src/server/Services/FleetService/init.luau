--!strict
-- The robotaxi fleet (PLAN.md §4 and Phase 9; docs/phase-9-contracts.md "Fleet economy"): a player's pods, what
-- they earn, collecting it, and buying, moving and selling pods. Read by nothing else on the server: the client
-- sees the fleet in the profile snapshot (ProfileSyncService) and acts through the remotes below.
--
-- Remotes (declared in Net, which has already checked each payload's shape and rate-limited it):
--   BuyPod { zone }          function: a new pod in that Config/Fleet zone, if a slot is free (Fleet.slotsFor: 3,
--                            +5 with the Fleet Manager pass), for Fleet.podPrice (the ohm_pod catalog price)
--                            through EconomyService.trySpend. Answers { ok, message, uid? }.
--   AssignPod { uid, zone }  function: moves one of the player's pods to another Config/Fleet zone. Answers
--                            { ok, message }.
--   CollectFleet             function: pays the whole dollars waiting (fleet.uncollected) with
--                            EconomyService.add(player, amount, "fleet"), at most once every
--                            Fleet.collectCooldownSeconds. Answers { ok, message, amount }.
--   SellPod { uid }          function: removes the pod and pays Fleet.sellBack (60 % of the price, like a car) in
--                            one update, so a pod can only ever be sold once. Answers { ok, message, amount? }.
--   DevFleet { action = "simulateOffline", hours }  Studio only: moves fleet.lastOnlineAt back by `hours` and runs
--                            the join-time offline accrual. Answers { ok, message, amount? } (amount: what the
--                            pretend absence added, whole dollars).
--
-- Earnings (pure, FleetService/Earnings; every number in Config/Fleet). The save keeps fleet.uncollected ($, not
-- rounded) and fleet.lastOnlineAt (os.time(): earnings are counted up to here):
--   online   one task.delay timer for every player, every Fleet.tickSeconds: each loaded player with pods earns
--            the online rate from lastOnlineAt to now, times EconomyService.earningsMultiplier (code boosts, like
--            every earning path), into uncollected, and lastOnlineAt moves to now (so it is saved on the timer).
--            With the Fleet Manager pass the whole dollars then go straight to the wallet (auto-collect).
--   joining  the gap since lastOnlineAt earns the offline rate (Fleet.offlineRate), for at most
--            Fleet.offlineCapHours, and the player gets a toast saying how much is waiting.
--   leaving  a last online accrual (DataService.beforeRelease), so lastOnlineAt is saved as they go.
--   changes  buying, moving and selling pods, and collecting, first count the earnings up to now with the fleet
--            as it was: a new pod never earns for time before it was bought, and a moved pod's past minutes keep
--            their old zone.
-- uncollected never grows past Fleet.uncollectedCap for the fleet's pods; what is already there is never taken
-- away. Every change goes through DataService.update, so ProfileSyncService sends the player a fresh snapshot.
--
-- Fleet Manager pass: owned per MonetizationService.hasPass(player, Fleet.pass.key) once Phase 12 adds that
-- service, else MarketplaceService for the id in Config/Monetization.passes (0 or missing: nobody owns it and no
-- call is made). Checked on join and when it is bought in game, and mirrored to the player attribute
-- Fleet.pass.attribute, which ProfileSyncService reads for the snapshot's slots. Robux prices are never read here.
--
-- Server-authoritative (CLAUDE.md hard rule 1): the client names a zone or one of its own pod uids; the server
-- looks it up in that player's own data, prices it and decides every dollar. No polling: one slow timer plus
-- remote, player and data events.
--
-- The clock (os.time) can be swapped with FleetService.setClock, and the accrual steps are exported as pure helpers
-- on a fleet table (cleanFleet, addUncollected, accrueOnline, accrueOffline, findPod) so tests/FleetEarnings.spec
-- can check them in Edit mode with a fake clock.

local HttpService = game:GetService("HttpService")
local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Economy = require(ReplicatedStorage.Shared.Config.Economy)
local Fleet = require(ReplicatedStorage.Shared.Config.Fleet)
local Monetization = require(ReplicatedStorage.Shared.Config.Monetization)
local Net = require(ReplicatedStorage.Shared.Net)
local Types = require(ReplicatedStorage.Shared.Types)
local EconomyService = require(script.Parent.EconomyService)
local Template = require(script.Parent.DataService.Template) -- UNSET_TIME only
local Earnings = require(script.Earnings)

-- DataService and ProfileSyncService are required in Init rather than here: DataService loads ProfileStore, which
-- talks to DataStores straight away, and tests/FleetEarnings.spec requires this module in Edit mode for its pure
-- helpers.
type DataServiceModule = typeof(require(script.Parent.DataService))
type ProfileSyncServiceModule = typeof(require(script.Parent.ProfileSyncService))

-- What the function remotes answer.
export type Reply = { ok: boolean, message: string, uid: string?, amount: number? }

-- MonetizationService.hasPass (Phase 12): whether the player owns the pass with this Config/Monetization key.
type PassChecker = (player: Player, passKey: string) -> boolean

local LOG = "[FleetService]"
local SECONDS_PER_HOUR = Earnings.SECONDS_PER_HOUR
local SIMULATE_OFFLINE = "simulateOffline" -- the one DevFleet action

local messages = Fleet.messages

local FleetService = {}

local DataService: DataServiceModule? = nil
local ProfileSyncService: ProfileSyncServiceModule? = nil
local hasPass: PassChecker? = nil
local clock: () -> number = os.time
local passOwned: { [Player]: boolean } = {}
local timer: thread? = nil

-- Pure helpers ----------------------------------------------------------------------------------------------

local function isFinite(value: any): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

-- Makes a fleet table safe to work on, in place: a pod list, an uncollected amount that is a finite number of at
-- least 0, and finite times. A damaged or never-stamped lastOnlineAt (Template.UNSET_TIME) becomes `now`, so a time
-- we can't trust never pays.
function FleetService.cleanFleet(fleet: Types.FleetData, now: number)
	local raw = fleet :: any
	if type(raw.pods) ~= "table" then
		raw.pods = {}
	end
	if not isFinite(raw.uncollected) or raw.uncollected < 0 then
		raw.uncollected = 0
	end
	if not isFinite(raw.lastOnlineAt) or raw.lastOnlineAt == Template.UNSET_TIME then
		raw.lastOnlineAt = now
	end
	if not isFinite(raw.lastCollectedAt) then
		raw.lastCollectedAt = 0
	end
end

-- The pod with `uid` in a fleet and its index, or nil. Only ever looks in the fleet it is given.
function FleetService.findPod(fleet: Types.FleetData, uid: string): (Types.FleetPod?, number?)
	local pods = (fleet :: any).pods
	if type(pods) ~= "table" then
		return nil, nil
	end
	for index, pod in pods do
		if type(pod) == "table" and pod.uid == uid then
			return pod, index
		end
	end
	return nil, nil
end

-- Adds `amount` to the fleet's uncollected earnings, never past Fleet.uncollectedCap for its pods. What is already
-- there stays, even above a cap that has since dropped (pods sold). Returns how much was really added.
function FleetService.addUncollected(fleet: Types.FleetData, amount: number): number
	if not isFinite(amount) or amount <= 0 then
		return 0
	end
	local current = fleet.uncollected
	local cap = math.max(Fleet.uncollectedCap(#fleet.pods), current)
	local updated = math.min(current + amount, cap)
	fleet.uncollected = updated
	return updated - current
end

-- Online earnings from fleet.lastOnlineAt to `now` (at most Fleet.onlineCatchUpSeconds of them), times the
-- earnings `multiplier`, into uncollected; lastOnlineAt moves to `now`. Returns the $ added. Nothing happens when
-- `now` isn't past lastOnlineAt, so time that was already counted (or a clock that went back) never pays twice.
function FleetService.accrueOnline(fleet: Types.FleetData, now: number, seed: number, multiplier: number): number
	FleetService.cleanFleet(fleet, now)
	local from = fleet.lastOnlineAt
	if now <= from then
		return 0
	end
	from = math.max(from, now - Fleet.onlineCatchUpSeconds)
	local earned = Earnings.accrue(fleet.pods, from, now, true, seed).total
	fleet.lastOnlineAt = now
	local boost = if isFinite(multiplier) and multiplier > 0 then multiplier else 1
	return FleetService.addUncollected(fleet, earned * boost)
end

-- Offline earnings for the time since fleet.lastOnlineAt (Earnings counts at most Fleet.offlineCapHours of it)
-- into uncollected; lastOnlineAt moves to `now`. Returns the $ added. Like accrueOnline, never counts time twice.
function FleetService.accrueOffline(fleet: Types.FleetData, now: number, seed: number): number
	FleetService.cleanFleet(fleet, now)
	local from = fleet.lastOnlineAt
	if now <= from then
		return 0
	end
	local earned = Earnings.accrue(fleet.pods, from, now, false, seed).total
	fleet.lastOnlineAt = now
	return FleetService.addUncollected(fleet, earned)
end

-- The clock --------------------------------------------------------------------------------------------------

-- Replaces the clock (os.time() seconds) for specs; nil puts os.time back.
function FleetService.setClock(fn: (() -> number)?)
	clock = fn or os.time
end

-- Now, on the fleet's clock.
function FleetService.now(): number
	return clock()
end

-- Helpers ---------------------------------------------------------------------------------------------------

local function reply(ok: boolean, message: string, amount: number?, uid: string?): Reply
	return { ok = ok, message = message, amount = amount, uid = uid }
end

local function notify(player: Player, text: string, kind: string)
	Net.fireClient("Notify", player, { text = text, kind = kind })
end

-- Every pod-hour's variation is seeded by the owner, so the same player's fleet earns the same on any server.
local function seedOf(player: Player): number
	return player.UserId
end

-- The player's fleet inside an update, made safe to change (a missing or damaged one is replaced or repaired).
local function fleetOf(data: Types.PlayerData, now: number): Types.FleetData
	local raw = data :: any
	if type(raw.fleet) ~= "table" then
		raw.fleet = { pods = {}, lastCollectedAt = 0, uncollected = 0, lastOnlineAt = now }
	end
	FleetService.cleanFleet(raw.fleet, now)
	return raw.fleet
end

-- The player's fleet as saved, for reading only (an empty table when it is missing or damaged).
local function savedFleet(data: Types.PlayerData): any
	local fleet = (data :: any).fleet
	return if type(fleet) == "table" then fleet else {}
end

-- The player's pods as saved, for reading only (an empty list when the fleet is missing or damaged).
local function podsOf(data: Types.PlayerData): { Types.FleetPod }
	local pods = savedFleet(data).pods
	return if type(pods) == "table" then pods else {}
end

-- True while the player owns the Fleet Manager pass (as last checked).
function FleetService.hasFleetManager(player: Player): boolean
	return passOwned[player] == true
end

-- Pods the player may run right now.
function FleetService.slotsFor(player: Player): number
	return Fleet.slotsFor(FleetService.hasFleetManager(player))
end

-- Takes the whole dollars waiting (as many as the wallet has room for) out of uncollected and pays them with
-- EconomyService.add. A player's own Collect (`manual`) starts the collect cooldown; the pass's auto-collect
-- doesn't. Returns the amount paid and, when nothing was paid, why.
local function payOut(player: Player, now: number, manual: boolean): (number, string?)
	local dataService = DataService
	if dataService == nil then
		return 0, messages.notLoaded
	end
	local taken = 0
	local refused: string? = nil
	local updated = dataService.update(player, function(fresh: Types.PlayerData)
		local fleet = fleetOf(fresh, now)
		local whole = math.floor(fleet.uncollected)
		if whole < 1 then
			refused = messages.nothingToCollect
			return
		end
		local room = math.max(Economy.maxCash - EconomyService.cleanBalance(fresh.cash), 0)
		if room < 1 then
			refused = messages.walletFull
			return
		end
		taken = math.min(whole, room)
		fleet.uncollected -= taken
		if manual then
			fleet.lastCollectedAt = now
		end
	end)
	if not updated then
		return 0, messages.collectFailed
	end
	if taken < 1 then
		return 0, refused or messages.nothingToCollect
	end
	if not EconomyService.add(player, taken, Fleet.reasons.collect) then
		-- Not paid after all: put it back as it was (it was there a moment ago, so no cap applies).
		dataService.update(player, function(fresh: Types.PlayerData)
			fleetOf(fresh, now).uncollected += taken
		end)
		return 0, messages.collectFailed
	end
	return taken, nil
end

-- Counts the player's online earnings up to now, for the timer and for leaving. On the timer a player with no pods
-- is skipped (nothing to earn; every pod change catches lastOnlineAt up first), and the pass auto-collects.
-- Leaving always saves lastOnlineAt and never pays out (it must not yield, and the wallet change can wait).
local function settle(player: Player, leaving: boolean)
	local dataService = DataService
	local data = if dataService ~= nil then dataService.get(player) else nil
	if dataService == nil or data == nil then
		return
	end
	if not leaving and #podsOf(data) == 0 then
		return
	end
	local multiplier = EconomyService.earningsMultiplier(player)
	local now = clock()
	dataService.update(player, function(fresh: Types.PlayerData)
		FleetService.accrueOnline(fleetOf(fresh, now), now, seedOf(player), multiplier)
	end)
	if not leaving and Fleet.pass.autoCollect and FleetService.hasFleetManager(player) then
		payOut(player, now, false)
	end
end

-- Catches the player's online earnings up to `now` before a change to their pods. False if their data isn't
-- loaded or the session isn't active.
local function catchUp(player: Player, now: number): boolean
	local dataService = DataService
	if dataService == nil then
		return false
	end
	local multiplier = EconomyService.earningsMultiplier(player)
	return dataService.update(player, function(fresh: Types.PlayerData)
		FleetService.accrueOnline(fleetOf(fresh, now), now, seedOf(player), multiplier)
	end)
end

-- Actions ---------------------------------------------------------------------------------------------------

-- Buys a pod into `zone`: checks the zone, a free slot and the price first, charges through
-- EconomyService.trySpend, then adds the pod (re-checking the slot); the charge is given back if that fails.
function FleetService.buyPod(player: Player, zone: string): Reply
	local dataService = DataService
	local data = if dataService ~= nil then dataService.get(player) else nil
	if dataService == nil or data == nil then
		return reply(false, messages.notLoaded)
	end
	if not Fleet.isZone(zone) then
		return reply(false, messages.unknownZone)
	end
	local price = EconomyService.wholeAmount(Fleet.podPrice)
	if price == nil then
		return reply(false, messages.notForSale)
	end
	local slots = FleetService.slotsFor(player)
	if #podsOf(data) >= slots then
		return reply(false, messages.noSlots)
	end
	local short = price - EconomyService.cleanBalance(data.cash)
	if short > 0 then
		return reply(false, string.format(messages.noCash, Economy.formatCash(short)))
	end

	local now = clock()
	if not catchUp(player, now) then
		return reply(false, messages.buyFailed)
	end
	if not EconomyService.trySpend(player, price, Fleet.reasons.buy) then
		return reply(false, messages.buyFailed)
	end
	local uid = HttpService:GenerateGUID(false)
	local added = false
	local updated = dataService.update(player, function(fresh: Types.PlayerData)
		local fleet = fleetOf(fresh, now)
		if #fleet.pods >= slots then
			return
		end
		table.insert(fleet.pods, { uid = uid, zone = zone })
		added = true
	end)
	if not updated or not added then
		EconomyService.add(player, price, Fleet.reasons.refund)
		warn(`{LOG} {player.Name} paid for a pod that couldn't be added; refunded ${price}`)
		return reply(false, messages.buyFailed)
	end
	print(`{LOG} {player.Name} bought a pod ({uid}) in {zone} for ${price}`)
	return reply(true, string.format(messages.bought, Fleet.zoneName(zone)), nil, uid)
end

-- Moves one of the player's pods to another zone. Its earnings up to now are counted in the old zone first.
function FleetService.assignPod(player: Player, uid: string, zone: string): Reply
	local dataService = DataService
	local data = if dataService ~= nil then dataService.get(player) else nil
	if dataService == nil or data == nil then
		return reply(false, messages.notLoaded)
	end
	if not Fleet.isZone(zone) then
		return reply(false, messages.unknownZone)
	end
	local pod = FleetService.findPod(savedFleet(data), uid)
	if pod == nil then
		return reply(false, messages.notFound)
	end
	if pod.zone == zone then
		return reply(false, string.format(messages.sameZone, Fleet.zoneName(zone)))
	end

	local now = clock()
	local multiplier = EconomyService.earningsMultiplier(player)
	local refused: string? = nil
	local updated = dataService.update(player, function(fresh: Types.PlayerData)
		local fleet = fleetOf(fresh, now)
		local current = FleetService.findPod(fleet, uid)
		if current == nil then
			refused = messages.notFound -- sold a moment ago
			return
		end
		FleetService.accrueOnline(fleet, now, seedOf(player), multiplier)
		current.zone = zone
	end)
	if not updated then
		return reply(false, messages.assignFailed)
	end
	if refused ~= nil then
		return reply(false, refused)
	end
	return reply(true, string.format(messages.assigned, Fleet.zoneName(zone)))
end

-- Pays out the fleet's uncollected earnings (counted up to now first), at most once per
-- Fleet.collectCooldownSeconds.
function FleetService.collect(player: Player): Reply
	local dataService = DataService
	local data = if dataService ~= nil then dataService.get(player) else nil
	if dataService == nil or data == nil then
		return reply(false, messages.notLoaded, 0)
	end
	local now = clock()
	local last = savedFleet(data).lastCollectedAt
	if isFinite(last) and now >= last and now - last < Fleet.collectCooldownSeconds then
		return reply(false, messages.collectWait, 0)
	end
	if not catchUp(player, now) then
		return reply(false, messages.collectFailed, 0)
	end
	local amount, problem = payOut(player, now, true)
	if amount < 1 then
		return reply(false, problem or messages.nothingToCollect, 0)
	end
	print(`{LOG} {player.Name} collected ${amount} from their fleet`)
	return reply(true, string.format(messages.collected, Economy.formatCash(amount)), amount)
end

-- Sells a pod back for Fleet.sellBack. The pod is removed and paid for in one update that re-checks it is still
-- there, so it can only ever be sold once; a wallet without room for the whole price refuses the sale.
function FleetService.sellPod(player: Player, uid: string): Reply
	local dataService = DataService
	local data = if dataService ~= nil then dataService.get(player) else nil
	if dataService == nil or data == nil then
		return reply(false, messages.notLoaded)
	end
	if FleetService.findPod(savedFleet(data), uid) == nil then
		-- Also what a second click on a pod that just sold gets.
		return reply(false, messages.notFound)
	end

	local price = Fleet.sellBack
	local now = clock()
	local multiplier = EconomyService.earningsMultiplier(player)
	local refused: string? = nil
	local gained = 0
	local updated = dataService.update(player, function(fresh: Types.PlayerData)
		local fleet = fleetOf(fresh, now)
		if FleetService.findPod(fleet, uid) == nil then
			refused = messages.notFound
			return
		end
		local newBalance, added = EconomyService.applyAdd(fresh.cash, price, Economy.maxCash)
		if added < price then
			refused = messages.walletFull -- never sell for less than the pod is worth
			return
		end
		-- The pod's last minutes count before it goes.
		FleetService.accrueOnline(fleet, now, seedOf(player), multiplier)
		local _, index = FleetService.findPod(fleet, uid)
		if index ~= nil then
			table.remove(fleet.pods, index)
		end
		fresh.cash = newBalance
		gained = added
	end)
	if not updated then
		return reply(false, messages.sellFailed)
	end
	if refused ~= nil then
		return reply(false, refused)
	end
	EconomyService.recordChange(player, "source", gained, Fleet.reasons.sell)
	print(`{LOG} {player.Name} sold a pod ({uid}) for ${gained}`)
	return reply(true, string.format(messages.sold, Economy.formatCash(gained)), gained)
end

-- Studio only (Net DevFleet): pretend the player was away for `hours`. Counts their online earnings up to now,
-- moves lastOnlineAt back by `hours`, then runs the join-time offline accrual. The amount is what that added.
function FleetService.devFleet(player: Player, payload: any): Reply
	if not RunService:IsStudio() then
		warn(`{LOG} DevFleet refused outside Studio ({player.Name})`)
		return reply(false, messages.devOnly)
	end
	local dataService = DataService
	if dataService == nil or dataService.get(player) == nil then
		return reply(false, messages.notLoaded)
	end
	local hours = if type(payload) == "table" then payload.hours else nil
	if type(payload) ~= "table" or payload.action ~= SIMULATE_OFFLINE or not isFinite(hours) or hours < 0 then
		return reply(false, messages.devOnly)
	end
	local now = clock()
	local multiplier = EconomyService.earningsMultiplier(player)
	local added = 0
	local updated = dataService.update(player, function(fresh: Types.PlayerData)
		local fleet = fleetOf(fresh, now)
		FleetService.accrueOnline(fleet, now, seedOf(player), multiplier)
		fleet.lastOnlineAt = now - hours * SECONDS_PER_HOUR
		added = FleetService.accrueOffline(fleet, now, seedOf(player))
	end)
	if not updated then
		return reply(false, messages.notLoaded)
	end
	local whole = math.floor(added)
	print(`{LOG} {player.Name} simulated {hours} h away: +${added}`)
	return reply(true, string.format(messages.devOffline, tostring(hours), Economy.formatCash(whole)), whole)
end

-- The Fleet Manager pass -----------------------------------------------------------------------------------

-- The pass's id from Config/Monetization: 0 when it hasn't been created (or isn't a usable id).
local function passId(): number
	local id = Monetization.passes[Fleet.pass.key]
	return if type(id) == "number" and id > 0 and id % 1 == 0 then id else 0
end

-- Records whether the player owns the pass, mirrors it to their attribute and, when it changed, sends a fresh
-- snapshot (their slot count changed without any change to the save).
local function setPass(player: Player, owned: boolean)
	if player.Parent ~= Players then
		return
	end
	local changed = FleetService.hasFleetManager(player) ~= owned
	passOwned[player] = owned
	player:SetAttribute(Fleet.pass.attribute, owned)
	local sync = ProfileSyncService
	if changed and sync ~= nil then
		sync.push(player)
	end
end

-- Asks who owns the pass: MonetizationService once it exists, else MarketplaceService for a real pass id. Yields
-- (run it in its own thread). A failed check counts as not owned until the next one.
local function checkPass(player: Player)
	local owned = false
	local checker = hasPass
	if checker ~= nil then
		local ok, result = pcall(checker, player, Fleet.pass.key)
		if not ok then
			warn(`{LOG} hasPass({Fleet.pass.key}) failed for {player.Name}: {result}`)
		end
		owned = ok and result == true
	else
		local id = passId()
		if id > 0 then
			local ok, result = pcall(function(): boolean
				return MarketplaceService:UserOwnsGamePassAsync(player.UserId, id)
			end)
			if not ok then
				warn(`{LOG} couldn't check the Fleet Manager pass for {player.Name}: {result}`)
			end
			owned = ok and result == true
		end
	end
	setPass(player, owned)
end

local function onPassPurchased(player: Player, gamePassId: number, purchased: boolean)
	local id = passId()
	if purchased and id > 0 and gamePassId == id then
		setPass(player, true)
	end
end

-- Player events ---------------------------------------------------------------------------------------------

-- A player's data loaded: check the pass, then pay the offline gap since they were last online.
local function onLoaded(player: Player, _data: Types.PlayerData)
	task.spawn(checkPass, player)
	local dataService = DataService
	if dataService == nil then
		return
	end
	local now = clock()
	local added = 0
	dataService.update(player, function(fresh: Types.PlayerData)
		added = FleetService.accrueOffline(fleetOf(fresh, now), now, seedOf(player))
	end)
	if added >= 1 then
		notify(player, string.format(messages.awayEarnings, Economy.formatCash(added)), Fleet.notifyKind)
	end
end

local function forget(player: Player)
	passOwned[player] = nil
end

-- The timer: every Fleet.tickSeconds, every player's online earnings. The next run is scheduled first, so one
-- player's failure (reported) never stops the timer or the other players.
local function tick()
	timer = task.delay(Fleet.tickSeconds, tick)
	for _, player in Players:GetPlayers() do
		local ok, err = pcall(settle, player, false)
		if not ok then
			warn(`{LOG} accrual failed for {player.Name}: {err}`)
		end
	end
end

-- Boot ------------------------------------------------------------------------------------------------------

function FleetService:Init()
	DataService = require(script.Parent.DataService)
	ProfileSyncService = require(script.Parent.ProfileSyncService)
	local monetization = script.Parent:FindFirstChild("MonetizationService")
	if monetization ~= nil and monetization:IsA("ModuleScript") then
		local ok, module = pcall(require, monetization)
		if ok and type(module) == "table" and type((module :: any).hasPass) == "function" then
			hasPass = (module :: any).hasPass
			-- Phase 12: follow every change MonetizationService learns of (a purchase, a Studio test pass).
			local onPassChanged = (module :: any).onPassChanged
			if type(onPassChanged) == "function" then
				onPassChanged(Fleet.pass.key, setPass)
			end
		end
	end
end

function FleetService:Start()
	local dataService = DataService
	if dataService == nil then
		return
	end
	Net.onServerInvoke("BuyPod", function(player: Player, payload: any): Reply
		return FleetService.buyPod(player, payload.zone)
	end)
	Net.onServerInvoke("AssignPod", function(player: Player, payload: any): Reply
		return FleetService.assignPod(player, payload.uid, payload.zone)
	end)
	Net.onServerInvoke("CollectFleet", function(player: Player, _payload: any): Reply
		return FleetService.collect(player)
	end)
	Net.onServerInvoke("SellPod", function(player: Player, payload: any): Reply
		return FleetService.sellPod(player, payload.uid)
	end)
	-- Always answer, so the remote never hangs; devFleet itself refuses outside Studio.
	Net.onServerInvoke("DevFleet", FleetService.devFleet)

	Players.PlayerRemoving:Connect(forget)
	MarketplaceService.PromptGamePassPurchaseFinished:Connect(onPassPurchased)
	dataService.onLoaded(onLoaded)
	dataService.beforeRelease(function(player: Player)
		settle(player, true)
	end)
	if timer == nil then
		timer = task.delay(Fleet.tickSeconds, tick)
	end
end

return FleetService
