--!strict
-- Jobs: offers, the active job, arrival, pay, XP and levels (PLAN.md §4 and Phase 6; docs/phase-6-contracts.md
-- "Server"). Job types plug in as modules implementing JobService/Types.JobType: Rideshare (here) and Delivery
-- (script.Delivery). A missing or broken Delivery or Levels module is logged and the rest keeps working.
--
-- Server-authoritative (CLAUDE.md hard rule 1): clients only ask (Net JobAction: accept, arrive, cancel,
-- refresh). Every step is decided here from where the server sees the car, and only the server pays.
--
-- One active job per player. State machine (JobService.transition): offered -> accepted -> (stops in order:
-- pickup, dropoff / load, drop, drop ...) -> complete | failed.
--   offers   every player has a few offers per eligible job type, made for their current car (eligibility by
--            Config/Classes class, never by name) and made again every Config/Jobs offers.refreshSec, when a
--            cooldown ends, when they change car, after a job ends, and on JobAction "refresh". With no car, a
--            test-drive car or a car of the wrong class, a type has no offers and its availability says why.
--   accept   JobAction { action = "accept", offerId } starts a job from the player's current offers, in the
--            car the offers were made for.
--   watch    one Heartbeat accumulator (Config/Jobs.checkInterval) samples each active job's car chassis
--            (server-observed position; speed is the distance covered over a short window, because one
--            sample's view of a client-driven car wobbles). The car has arrived at the current stop when it
--            is within the type's arriveRadius of the stop (or of its road approach point) and slower than
--            stillSpeedMph, for the stop's dwell seconds. Then the type module's onArrive says what follows.
--            JobAction "arrive" asks for that check at once; when the server sees the car far from the stop
--            (Config/Jobs.forgedArriveFactor x arriveRadius) the call is rejected and logged.
--   tips     while the module turns smooth tracking on (rideshare: passenger aboard) each sample compares the
--            speed now with the speed a moment ago: a sudden big loss is a crash, a fast one a hard brake
--            (Config/Jobs.smoothness). The module's pay() turns the counts into the tip.
--   fail     out of time, out of the car's Driver seat for Config/Jobs.leaveCarSec, another car, or the car
--            gone. JobAction "cancel" ends the job too. Both start that type's cooldown.
--   pay      EconomyService.add(player, total x earningsMultiplier x vipMultiplier, "job:<type>"); XP in
--            PlayerData.jobs.xp[type] (Config/Jobs xp, scaled by the paid length); a level-up is announced.
--   publish  every change pushes Net JobUpdate to the player (coalesced to one push per frame):
--            { job = { id, type, title, stopIndex, stops = { { position, label, kind } }, deadline, startedAt,
--              estPay, xl, routeLength } | nil, offers = { Offer }? (nil during a job), reason = string?,
--              availability = { [type] = { ok, reason? } }, progress = { [type] = { xp, level, multiplier,
--              nextXp?, unlocks } } }.
--            deadline and startedAt are Workspace:GetServerTimeNow() seconds, so a client can count down with
--            its own GetServerTimeNow(). Distances are studs; pay is $ after boosts and VIP.
--
-- While a player has an active job DriveEarnService pays them nothing (hasActiveJob): the job is the earning.
--
-- Studio only: Net DevJob { action = "teleportToStop" } moves the player's job car next to the current stop
-- (VehicleService.resetCar, which tells AntiExploitService.allowTeleport) for the automated job tests.
--
-- The decisions are pure helpers on this module (transition, timeLimit, isEligible, distanceToStop,
-- arrivalDecision, speedOver, speedLossEvent, recordSmoothEvent, xpFor, levelFor) for tests/Jobs.spec;
-- Rideshare has the fare, tip and XL helpers. No polling beyond the one Heartbeat (CLAUDE.md hard rule 10).

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local Catalog = require(Shared.Vehicle.Catalog)
local Classes = require(Shared.Config.Classes)
local Economy = require(Shared.Config.Economy)
local Garage = require(Shared.Config.Garage)
local Graph = require(Shared.Road.Graph)
local Jobs = require(Shared.Config.Jobs)
local MapLayout = require(Shared.Config.MapLayout)
local Net = require(Shared.Net)
local Pathfind = require(Shared.Road.Pathfind)
local SharedTypes = require(Shared.Types)
local Units = require(Shared.Util.Units)
local AntiExploitService = require(script.Parent.AntiExploitService)
local EconomyService = require(script.Parent.EconomyService)
local VehicleService = require(script.Parent.VehicleService)
local Rideshare = require(script.Rideshare)
local Types = require(script.Types)

-- DataService is required in Init rather than here: it loads ProfileStore, which talks to DataStores straight
-- away, and tests/Jobs.spec requires this module in Edit mode for its pure helpers.
type DataServiceModule = typeof(require(script.Parent.DataService))

type Job = Types.Job
type Offer = Types.Offer
type JobKind = Types.JobKind
type JobState = Types.JobState
type Stop = Types.Stop
type Context = Types.Context
type JobModule = Types.JobType
type Def = Jobs.JobDef

-- One position sample of a job car; `speed` is studs/s over Config/Jobs.smoothness.speedWindow (nil until the
-- samples cover the window).
export type Sample = { t: number, position: Vector3, speed: number? }
export type Arrival = "far" | "moving" | "dwelling" | "arrived"
export type SmoothEvent = "hardBrake" | "crash"
export type JobEvent = "accept" | "advance" | "complete" | "fail" | "cancel"

type Availability = { ok: boolean, reason: string? }

-- Levels.luau: levelFor(type, xp) -> (level, multiplier); unlocks(type, level) -> unlock ids (that level's or
-- every level's up to it: unlocksUpTo takes the union either way).
type LevelsModule = {
	levelFor: (kind: string, xp: number) -> (number, number),
	unlocks: (kind: string, level: number) -> { string },
}

type CarInfo = {
	car: Model,
	chassis: BasePart,
	vehicleId: string?,
	classId: string?,
	seats: number,
	testDrive: boolean,
}

type PlayerState = {
	job: Job?,
	offers: { Offer },
	offersById: { [string]: Offer },
	offersCar: Model?, -- the car the offers were made for
	nextRefresh: number, -- os.clock() when the offers are made again
	offersSignature: string, -- what the last offers push showed (offer ids and availability)
	lastRefresh: number,
	availability: { [JobKind]: Availability },
	cooldowns: { [JobKind]: number }, -- os.clock() each type's cooldown ends
	outOfCarSince: number?,
	stillSince: number?, -- os.clock() the car became still inside the stop's radius
	history: { Sample },
	pushQueued: boolean,
}

local LOG = "[JobService]"
local SEATS_FOLDER = "Seats" -- seat names from the vehicle model contract
local DRIVER_SEAT = "Driver"
local VEHICLE_ID_ATTRIBUTE = "VehicleId"
local TRIM_ATTRIBUTE = "Trim"
local DEV_RESET_REASON = "devTeleport"
local ROUTE_STEP = 0.02 -- fraction of an edge either side of a point, to find the road's direction there
local MIN_DIRECTION = 1e-3 -- shorter than this across the ground has no usable direction
local MIN_SAMPLE_GAP = 1e-3 -- seconds: two samples closer than this are one
local OFFER_PREFIX = { rideshare = "r", delivery = "d" } :: { [string]: string }
local CLASS_SEPARATOR = ", "
local SIGNATURE_SEPARATOR = "|"

local JobService = {}

local DataService: DataServiceModule? = nil
local Levels: LevelsModule? = nil
-- Job type modules by type id, in Init (Delivery only when present and complete).
local modules: { [JobKind]: JobModule } = {}

local states: { [Player]: PlayerState } = {}
local sinceCheck = 0
local offerSerial = 0
local random = Random.new()
local warned: { [string]: boolean } = {} -- each distinct error is logged once

local stillSpeedCache: { [JobKind]: number } = {}

-- Pure helpers ------------------------------------------------------------------------------------------------

-- The next state of a job after `event`, or nil when the event isn't allowed in `state`.
function JobService.transition(state: JobState, event: JobEvent): JobState?
	if state == "offered" then
		return if event == "accept" then "accepted" else nil
	elseif state == "accepted" then
		if event == "advance" then
			return "accepted"
		elseif event == "complete" then
			return "complete"
		elseif event == "fail" or event == "cancel" then
			return "failed"
		end
	end
	return nil -- complete and failed are final
end

-- Seconds allowed for a job whose route (pickup or depot leg included) is `routeLength` studs.
function JobService.timeLimit(def: Def, routeLength: number): number
	return math.max(routeLength, 0) * def.timeLimitPerStud + def.timeGraceSec
end

-- True when a car of Config/Classes class `classId` can do this job.
function JobService.isEligible(def: Def, classId: string?): boolean
	return classId ~= nil and table.find(def.classes, classId) ~= nil
end

local function flatDistance(a: Vector3, b: Vector3): number
	return Vector2.new(a.X - b.X, a.Z - b.Z).Magnitude
end

-- Horizontal studs from `position` to the stop: to the stop itself or its road approach point, whichever is
-- nearer.
function JobService.distanceToStop(stop: Stop, position: Vector3): number
	local distance = flatDistance(stop.position, position)
	local approach = stop.approach
	if approach ~= nil then
		distance = math.min(distance, flatDistance(approach, position))
	end
	return distance
end

-- Whether a car `distance` studs from a stop, going `speed` studs/s (nil: not known yet), has arrived: within
-- `radius`, no faster than `stillSpeed`, and still for at least `dwell` seconds (`stillFor` so far).
function JobService.arrivalDecision(
	distance: number,
	speed: number?,
	radius: number,
	stillSpeed: number,
	stillFor: number,
	dwell: number
): Arrival
	if distance > radius then
		return "far"
	elseif speed == nil or speed > stillSpeed then
		return "moving"
	elseif stillFor < dwell then
		return "dwelling"
	end
	return "arrived"
end

-- Speed (studs/s across the ground) from the newest sample back to the latest sample at least `window` seconds
-- older; nil while the samples don't cover the window.
function JobService.speedOver(history: { Sample }, window: number): number?
	local newest = history[#history]
	if newest == nil then
		return nil
	end
	for i = #history - 1, 1, -1 do
		local earlier = history[i]
		local seconds = newest.t - earlier.t
		if seconds >= window then
			return flatDistance(newest.position, earlier.position) / seconds
		end
	end
	return nil
end

-- What losing speed from `before` to `after` (studs/s) over `seconds` was: a crash (a big loss quicker than
-- any brake), a hard brake (a fast loss), or nil (smooth, or slow to begin with).
function JobService.speedLossEvent(before: number, after: number, seconds: number): SmoothEvent?
	local settings = Jobs.smoothness
	local beforeMph, afterMph = Units.studsToMph(before), Units.studsToMph(after)
	local loss = beforeMph - afterMph
	if beforeMph < settings.minSpeedMph or loss <= 0 or seconds <= 0 then
		return nil
	end
	-- Samples arrive every checkInterval, so the pair spans the window plus up to one interval.
	if loss >= settings.crashSpeedLossMph and seconds <= settings.crashWindow + Jobs.checkInterval then
		return "crash"
	end
	if loss / seconds >= settings.hardBrakeMphPerSec then
		return "hardBrake"
	end
	return nil
end

-- Counts a smoothness event at `now`. Events within Config cooldown of the last one are the same event, except
-- that a crash right after a hard brake turns that brake into the crash. Returns true when something changed.
function JobService.recordSmoothEvent(smooth: Types.Smoothness, event: SmoothEvent, now: number): boolean
	local cooldown = Jobs.smoothness.eventCooldownSec
	local recent = smooth.lastEventAt > 0 and now - smooth.lastEventAt < cooldown
	if recent then
		if event == "crash" and smooth.lastEvent == "hardBrake" and smooth.hardBrakes > 0 then
			smooth.hardBrakes -= 1
			smooth.crashes += 1
			smooth.lastEvent = "crash"
			smooth.lastEventAt = now
			return true
		end
		return false
	end
	if event == "crash" then
		smooth.crashes += 1
	else
		smooth.hardBrakes += 1
	end
	smooth.lastEvent = event
	smooth.lastEventAt = now
	return true
end

-- XP for a completed job of `paidLength` studs: def.xp scaled by length within Config/Jobs.xpScale.
function JobService.xpFor(def: Def, paidLength: number): number
	local scale = math.clamp(paidLength / def.xpReferenceStuds, Jobs.xpScale.min, Jobs.xpScale.max)
	return math.max(math.floor(def.xp * scale + 0.5), 0)
end

-- Levels from Config/Jobs, used when Levels.luau is missing or fails.
local function fallbackLevelFor(kind: string, xp: number): (number, number)
	local ladder = Jobs.levels[kind]
	if ladder == nil or #ladder == 0 then
		return 1, 1
	end
	local level = 1
	for index, entry in ladder do
		if xp >= entry.xp then
			level = index
		end
	end
	return level, ladder[level].payMultiplier
end

local function fallbackUnlocks(kind: string, level: number): { string }
	local ladder = Jobs.levels[kind]
	local entry = if ladder ~= nil then ladder[level] else nil
	return if entry ~= nil then entry.unlocks else {}
end

local function warnOnce(key: string, text: string)
	if not warned[key] then
		warned[key] = true
		warn(`{LOG} {text}`)
	end
end

-- The level (1 = new) and its pay multiplier for `xp` in a job type (Levels.luau, or Config/Jobs directly).
function JobService.levelFor(kind: JobKind, xp: number): (number, number)
	local levels = Levels
	if levels ~= nil then
		local ok, level, multiplier = pcall(levels.levelFor, kind, xp)
		if ok and type(level) == "number" and type(multiplier) == "number" then
			return level, multiplier
		end
		warnOnce("levelFor", `Levels.levelFor failed, using Config/Jobs levels: {level}`)
	end
	return fallbackLevelFor(kind, xp)
end

-- Every unlock id reached at `level` or below.
local function unlocksUpTo(kind: JobKind, level: number): { [string]: boolean }
	local set: { [string]: boolean } = {}
	for each = 1, level do
		local list: { string }? = nil
		local levels = Levels
		if levels ~= nil then
			local ok, result = pcall(levels.unlocks, kind, each)
			if ok and type(result) == "table" then
				list = result
			else
				warnOnce("unlocks", `Levels.unlocks failed, using Config/Jobs levels: {result}`)
			end
		end
		for _, id in list or fallbackUnlocks(kind, each) do
			set[id] = true
		end
	end
	return set
end

-- Public API ----------------------------------------------------------------------------------------------------

-- The VIP pass's job pay multiplier: 1 until Phase 12 wires the pass (Config/Economy.vipJobPayBonus).
function JobService.vipMultiplier(_player: Player): number
	return 1
end

-- True while the player has a job in progress (DriveEarnService pays nothing then).
function JobService.hasActiveJob(player: Player): boolean
	local state = states[player]
	return state ~= nil and state.job ~= nil
end

-- The player's active job (read-only), or nil.
function JobService.getJob(player: Player): Job?
	local state = states[player]
	return if state ~= nil then state.job else nil
end

-- Cars ------------------------------------------------------------------------------------------------------------

local function carInfo(car: Model?): CarInfo?
	if car == nil or car.Parent == nil then
		return nil
	end
	local chassis = car.PrimaryPart
	if chassis == nil then
		return nil
	end
	local vehicleId, trimId = car:GetAttribute(VEHICLE_ID_ATTRIBUTE), car:GetAttribute(TRIM_ATTRIBUTE)
	local vehicle = if type(vehicleId) == "string" then Catalog.getVehicle(vehicleId) else nil
	local trim = if type(vehicleId) == "string" and type(trimId) == "string"
		then Catalog.getTrim(vehicleId, trimId)
		else nil
	return {
		car = car,
		chassis = chassis,
		vehicleId = if type(vehicleId) == "string" then vehicleId else nil,
		classId = if vehicle ~= nil then vehicle.class else nil,
		seats = if trim ~= nil then trim.seats else 0,
		testDrive = car:GetAttribute(Garage.testDriveAttribute) == true,
	}
end

-- True when the player's living character sits in this car's Driver seat.
local function isDriving(player: Player, car: Model): boolean
	local seats = car:FindFirstChild(SEATS_FOLDER)
	local seat = if seats ~= nil then seats:FindFirstChild(DRIVER_SEAT) else nil
	if seat == nil or not seat:IsA("Seat") then
		return false
	end
	local occupant = seat.Occupant
	local character = player.Character
	return occupant ~= nil and character ~= nil and occupant.Parent == character and occupant.Health > 0
end

local function stillSpeedFor(kind: JobKind): number
	local cached = stillSpeedCache[kind]
	if cached == nil then
		cached = Units.mphToStuds(Jobs.types[kind].stillSpeedMph)
		stillSpeedCache[kind] = cached
	end
	return cached
end

-- A pose on the road nearest `target`, facing along it (the Studio teleport).
local function roadPose(target: Vector3): CFrame
	local edge, t, _, point = Graph.nearestEdge(target)
	if edge == nil then
		return CFrame.new(target)
	end
	local ahead = Graph.pointOnEdge(edge, math.min(t + ROUTE_STEP, 1))
	local behind = Graph.pointOnEdge(edge, math.max(t - ROUTE_STEP, 0))
	local direction = Vector3.new(ahead.X - behind.X, 0, ahead.Z - behind.Z)
	if direction.Magnitude < MIN_DIRECTION then
		return CFrame.new(point)
	end
	return CFrame.lookAt(point, point + direction.Unit)
end

-- Context ---------------------------------------------------------------------------------------------------------

local locationsByTag: { [string]: { MapLayout.Location } } = (function()
	local byTag: { [string]: { MapLayout.Location } } = {}
	for _, location in MapLayout.locations do
		local list = byTag[location.tag]
		if list == nil then
			list = {}
			byTag[location.tag] = list
		end
		table.insert(list, location)
	end
	return byTag
end)()

local function xpOf(player: Player, kind: JobKind): number
	local dataService = DataService
	local data = if dataService ~= nil then dataService.get(player) else nil
	local jobs = if data ~= nil then data.jobs else nil
	local xp = if jobs ~= nil and jobs.xp ~= nil then jobs.xp[kind] else nil
	return if type(xp) == "number" then xp else 0
end

local function newOfferId(kind: JobKind): string
	offerSerial += 1
	return `{OFFER_PREFIX[kind] or kind}{offerSerial}`
end

local function routeLength(from: Vector3, to: Vector3, heading: Vector3?): number?
	local route = Pathfind.route(from, to, heading)
	return if route ~= nil then route.length else nil
end

local function makeStop(location: MapLayout.Location, kind: Types.StopKind, dwell: number?): Stop
	local position = location.gpsTarget or location.position
	local _, _, _, approach = Graph.nearestEdge(position)
	return {
		position = position,
		locationId = location.id,
		kind = kind,
		label = location.displayName,
		approach = approach,
		dwell = dwell,
	}
end

-- Everything a job type module gets: the car, the player's level in the type, and the helpers.
local function contextFor(player: Player, kind: JobKind, info: CarInfo?): Context
	local def = Jobs.types[kind]
	local now = os.clock()
	local level, multiplier = JobService.levelFor(kind, xpOf(player, kind))
	local unlocks = unlocksUpTo(kind, level)
	local car = if info ~= nil then info.car else nil
	local context: Context = {
		now = now,
		def = def,
		graph = Graph,
		pathfind = Pathfind,
		mapLayout = MapLayout,
		car = car,
		carPose = if info ~= nil then info.chassis.CFrame else nil,
		vehicleId = if info ~= nil then info.vehicleId else nil,
		classId = if info ~= nil then info.classId else nil,
		seats = if info ~= nil then info.seats else 0,
		level = level,
		levelMultiplier = multiplier,
		unlocks = unlocks,
		offerCount = Jobs.offers.perType + (if unlocks.extraOffer then 1 else 0),
		random = random,
		newId = function(): string
			return newOfferId(kind)
		end,
		routeLength = routeLength,
		locations = function(tag: string): { MapLayout.Location }
			return locationsByTag[tag] or {}
		end,
		makeStop = makeStop,
		newJob = function(owner: Player, offer: Offer, stops: { Stop }, lengths: Types.Lengths, data: any?): Job
			local uid = if car ~= nil then car:GetAttribute(Garage.ownedUidAttribute) else nil
			return {
				id = HttpService:GenerateGUID(false),
				type = kind,
				player = owner,
				title = offer.title,
				stops = stops,
				index = 1,
				startedAt = now,
				deadline = now + JobService.timeLimit(def, lengths.routeLength),
				routeLength = lengths.routeLength,
				paidLength = lengths.paidLength,
				car = car,
				carUid = if type(uid) == "string" then uid else nil,
				estPay = offer.pay,
				xl = offer.xl,
				state = "accepted",
				smooth = { tracking = false, hardBrakes = 0, crashes = 0, lastEventAt = 0, lastEvent = nil },
				data = data,
			}
		end,
	}
	return context
end

-- Publishing ------------------------------------------------------------------------------------------------------

local function notify(player: Player, text: string, kind: string)
	if player.Parent == Players then
		Net.fireClient("Notify", player, { text = text, kind = kind })
	end
end

-- What the player is shown as pay: $ after earnings boosts and VIP, whole dollars.
local function shownPay(amount: number, multiplier: number): number
	return math.floor(amount * multiplier)
end

local function publicJob(job: Job, multiplier: number): any
	local serverNow = Workspace:GetServerTimeNow()
	local clock = os.clock()
	local stops = table.create(#job.stops)
	for _, stop in job.stops do
		table.insert(stops, { position = stop.position, label = stop.label, kind = stop.kind })
	end
	return {
		id = job.id,
		type = job.type,
		title = job.title,
		stopIndex = job.index,
		stops = stops,
		deadline = serverNow + (job.deadline - clock),
		startedAt = serverNow - (clock - job.startedAt),
		estPay = shownPay(job.estPay, multiplier),
		xl = job.xl == true,
		routeLength = job.routeLength,
	}
end

local function publicOffer(offer: Offer, multiplier: number): any
	return {
		id = offer.id,
		type = offer.type,
		title = offer.title,
		subtitle = offer.subtitle,
		pay = shownPay(offer.pay, multiplier),
		distance = math.floor(offer.distance),
		stops = offer.stops,
		xl = offer.xl == true,
	}
end

local function progressOf(player: Player): { [string]: any }
	local progress: { [string]: any } = {}
	for _, kind in Jobs.order do
		local xp = xpOf(player, kind)
		local level, multiplier = JobService.levelFor(kind, xp)
		local ladder = Jobs.levels[kind]
		local nextLevel = if ladder ~= nil then ladder[level + 1] else nil
		local unlocks: { string } = {}
		for id in unlocksUpTo(kind, level) do
			table.insert(unlocks, id)
		end
		table.sort(unlocks)
		progress[kind] = {
			xp = xp,
			level = level,
			multiplier = multiplier,
			nextXp = if nextLevel ~= nil then nextLevel.xp else nil,
			unlocks = unlocks,
		}
	end
	return progress
end

local function push(player: Player)
	local state = states[player]
	if state == nil or player.Parent ~= Players then
		return
	end
	state.pushQueued = false
	local multiplier = EconomyService.earningsMultiplier(player) * JobService.vipMultiplier(player)
	local job = state.job
	local offers: { any }? = nil
	local reason: string? = nil
	local availability: { [string]: Availability } = {}
	if job == nil then
		local list = {}
		for _, offer in state.offers do
			table.insert(list, publicOffer(offer, multiplier))
		end
		offers = list
		for _, kind in Jobs.order do
			local entry = state.availability[kind]
			if entry ~= nil then
				availability[kind] = entry
				if reason == nil and #list == 0 and not entry.ok then
					reason = entry.reason
				end
			end
		end
	end
	Net.fireClient("JobUpdate", player, {
		job = if job ~= nil then publicJob(job, multiplier) else nil,
		offers = offers,
		reason = reason,
		availability = availability,
		progress = progressOf(player),
	})
end

-- Pushes once at the end of this frame however many changes happen in it.
local function queuePush(player: Player)
	local state = states[player]
	if state == nil or state.pushQueued then
		return
	end
	state.pushQueued = true
	task.defer(push, player)
end

-- Offers ------------------------------------------------------------------------------------------------------------

local function classNames(classIds: { string }): string
	local names: { string } = {}
	for _, id in classIds do
		local class = Classes[id]
		table.insert(names, if class ~= nil then class.displayName else id)
	end
	return table.concat(names, CLASS_SEPARATOR)
end

local function availabilityFor(state: PlayerState, kind: JobKind, info: CarInfo?, now: number): Availability
	local def = Jobs.types[kind]
	local messages = Jobs.messages
	if info == nil then
		return { ok = false, reason = messages.noCar }
	elseif info.testDrive then
		return { ok = false, reason = messages.testDrive }
	elseif not JobService.isEligible(def, info.classId) then
		return { ok = false, reason = string.format(messages.wrongClass, def.displayName, classNames(def.classes)) }
	end
	local cooldownEnds = state.cooldowns[kind]
	if cooldownEnds ~= nil and cooldownEnds > now then
		return {
			ok = false,
			reason = string.format(messages.cooldown, def.displayName, math.ceil(cooldownEnds - now)),
		}
	end
	return { ok = true, reason = nil }
end

-- Makes the player's offers again for their current car, and pushes them.
local function refreshOffers(player: Player, state: PlayerState, now: number)
	local car = VehicleService.getCar(player)
	local info = carInfo(car)
	local offers: { Offer } = {}
	local byId: { [string]: Offer } = {}
	local nextRefresh = now + Jobs.offers.refreshSec
	for _, kind in Jobs.order do
		local module = modules[kind]
		if module == nil then
			continue
		end
		local availability = availabilityFor(state, kind, info, now)
		state.availability[kind] = availability
		local cooldownEnds = state.cooldowns[kind]
		if cooldownEnds ~= nil and cooldownEnds > now then
			nextRefresh = math.min(nextRefresh, cooldownEnds) -- offers return the moment the cooldown ends
		end
		if availability.ok then
			local ok, list = pcall(module.offers, player, car, contextFor(player, kind, info))
			if ok and type(list) == "table" then
				for _, offer in list do
					offer.type = kind
					table.insert(offers, offer)
					byId[offer.id] = offer
				end
			else
				warnOnce(`offers:{kind}`, `{kind} offers failed: {list}`)
			end
		end
	end
	state.offers = offers
	state.offersById = byId
	state.offersCar = car
	state.nextRefresh = nextRefresh
	state.lastRefresh = now
	-- Push only when something the player sees changed (a player on foot isn't sent the same "no car" every
	-- refresh).
	local parts: { string } = {}
	for _, offer in offers do
		table.insert(parts, offer.id)
	end
	for _, kind in Jobs.order do
		local entry = state.availability[kind]
		table.insert(parts, if entry ~= nil then entry.reason or kind else "")
	end
	local signature = table.concat(parts, SIGNATURE_SEPARATOR)
	if signature ~= state.offersSignature then
		state.offersSignature = signature
		queuePush(player)
	end
end

-- Ending jobs -----------------------------------------------------------------------------------------------------

local function endJob(player: Player, state: PlayerState)
	state.job = nil
	state.outOfCarSince = nil
	state.stillSince = nil
	state.offersSignature = "" -- the next offers are always pushed
	table.clear(state.history)
	queuePush(player)
end

-- Fails (or cancels) the active job: the type's cooldown starts (unless `noCooldown`), the player is told why,
-- and new offers are made.
local function failJob(
	player: Player,
	state: PlayerState,
	text: string,
	now: number,
	cancelled: boolean,
	noCooldown: boolean?
)
	local job = state.job
	if job == nil then
		return
	end
	job.state = JobService.transition(job.state, if cancelled then "cancel" else "fail") or "failed"
	endJob(player, state)
	local def = Jobs.types[job.type]
	if not noCooldown then
		state.cooldowns[job.type] = now + def.cooldownSec
	end
	local messages = Jobs.messages
	if cancelled then
		notify(player, string.format(messages.cancelled, def.displayName, def.cooldownSec), Jobs.notifyKinds.info)
	else
		notify(player, string.format(messages.failed, text), Jobs.notifyKinds.bad)
	end
	refreshOffers(player, state, now)
end

-- Adds XP and announces a level-up. Runs in the payment thread.
local function awardXp(player: Player, kind: JobKind, amount: number)
	local dataService = DataService
	if dataService == nil or amount <= 0 then
		return
	end
	local before = JobService.levelFor(kind, xpOf(player, kind))
	local updated = dataService.update(player, function(data: SharedTypes.PlayerData)
		local jobs = data.jobs
		if type(jobs) ~= "table" then
			jobs = { xp = {}, licenses = {} }
			data.jobs = jobs
		end
		if type(jobs.xp) ~= "table" then
			jobs.xp = {}
		end
		local current = jobs.xp[kind]
		jobs.xp[kind] = (if type(current) == "number" then current else 0) + amount
	end)
	if not updated then
		return
	end
	local after, multiplier = JobService.levelFor(kind, xpOf(player, kind))
	if after > before then
		local def = Jobs.types[kind]
		local text = string.format(Jobs.messages.levelUp, def.displayName, after, string.format("%g", multiplier))
		notify(player, text, Jobs.notifyKinds.good)
	end
end

-- Pays a finished job (in its own thread: EconomyService writes player data), adds XP, and makes new offers.
local function completeJob(player: Player, state: PlayerState, now: number)
	local job = state.job
	if job == nil then
		return
	end
	job.state = JobService.transition(job.state, "complete") or "complete"
	local module = modules[job.type]
	local context = contextFor(player, job.type, carInfo(job.car))
	endJob(player, state)
	local ok, result = pcall(module.pay, job, context)
	local breakdown: Types.PayBreakdown? = nil
	if ok and type(result) == "table" and type(result.total) == "number" then
		breakdown = result
	else
		warn(`{LOG} {job.type} pay failed for {player.Name}: {result}`)
	end
	local def = Jobs.types[job.type]
	local xp = JobService.xpFor(def, job.paidLength)
	task.spawn(function()
		if breakdown ~= nil then
			local multiplier = EconomyService.earningsMultiplier(player) * JobService.vipMultiplier(player)
			local total = breakdown.total * multiplier
			if EconomyService.add(player, total, Jobs.reasonPrefix .. job.type) then
				local tip = math.floor(breakdown.tip * multiplier)
				local messages = Jobs.messages
				local text = if tip >= 1
					then string.format(messages.completedTip, Economy.formatCash(total), Economy.formatCash(tip))
					else string.format(messages.completed, Economy.formatCash(total))
				notify(player, text, Jobs.notifyKinds.good)
			end
		end
		awardXp(player, job.type, xp)
		queuePush(player) -- progress changed
	end)
	refreshOffers(player, state, now)
end

-- Arrival ---------------------------------------------------------------------------------------------------------

-- The current stop is done: ask the job's module what follows.
local function advance(player: Player, state: PlayerState, now: number)
	local job = state.job
	if job == nil then
		return
	end
	local module = modules[job.type]
	local ok, result = pcall(module.onArrive, job, job.index, contextFor(player, job.type, carInfo(job.car)))
	if not ok or type(result) ~= "table" then
		warn(`{LOG} {job.type} onArrive failed for {player.Name}: {result}`)
		failJob(player, state, Jobs.messages.failError, now, false, true)
		return
	end
	state.stillSince = nil
	if result.smoothTracking ~= nil then
		job.smooth.tracking = result.smoothTracking
	end
	if result.outcome == "fail" then
		failJob(player, state, result.message or Jobs.messages.failError, now, false)
		return
	end
	if result.message ~= nil then
		notify(player, result.message, Jobs.notifyKinds.info)
	end
	if result.outcome == "complete" or job.index >= #job.stops then
		completeJob(player, state, now)
		return
	end
	job.state = JobService.transition(job.state, "advance") or job.state
	job.index += 1
	queuePush(player)
end

-- Records where the car is now (and its speed over the window). A move the server made itself (a reset or the
-- Studio teleport) starts the history over, so it never reads as speed or a crash.
local function sample(state: PlayerState, car: Model, chassis: BasePart, now: number): Sample
	local history = state.history
	local last: Sample? = history[#history]
	local moved = AntiExploitService.lastServerMove(car)
	if last ~= nil and moved ~= nil and moved > last.t then
		table.clear(history)
	elseif last ~= nil and now - last.t < MIN_SAMPLE_GAP then
		return last
	end
	local entry: Sample = { t = now, position = chassis.Position, speed = nil }
	table.insert(history, entry)
	entry.speed = JobService.speedOver(history, Jobs.smoothness.speedWindow)
	local cutoff = now - Jobs.historySeconds
	while #history > 2 and history[1].t < cutoff do
		table.remove(history, 1)
	end
	return entry
end

-- What the speed loss from the latest sample at least `window` seconds before the newest one was (nil: none, or
-- the samples don't cover the window yet).
local function lossEventOver(history: { Sample }, window: number): SmoothEvent?
	local newest = history[#history]
	if newest == nil or newest.speed == nil then
		return nil
	end
	for i = #history - 1, 1, -1 do
		local earlier = history[i]
		local seconds = newest.t - earlier.t
		if seconds >= window then
			local before = earlier.speed
			if before == nil then
				return nil
			end
			return JobService.speedLossEvent(before, newest.speed :: number, seconds)
		end
	end
	return nil
end

-- Hard braking and crashes while the module tracks smooth driving: crashes over the short crashWindow, hard
-- brakes over the longer brakeWindow (a short press of an on/off brake isn't one), and no hard brake while the
-- car is `nearStop` (it has to stop there).
local function checkSmoothness(job: Job, history: { Sample }, now: number, nearStop: boolean)
	local settings = Jobs.smoothness
	if lossEventOver(history, settings.crashWindow) == "crash" then
		JobService.recordSmoothEvent(job.smooth, "crash", now)
		return
	end
	if not nearStop and lossEventOver(history, settings.brakeWindow) == "hardBrake" then
		JobService.recordSmoothEvent(job.smooth, "hardBrake", now)
	end
end

-- The arrival decision for the current stop from the newest sample (and keeps the still-since timer).
local function arrivalNow(state: PlayerState, job: Job, latest: Sample, now: number): (Arrival, number)
	local stop = job.stops[job.index]
	local def = Jobs.types[job.type]
	local distance = JobService.distanceToStop(stop, latest.position)
	local stillSpeed = stillSpeedFor(job.type)
	local still = latest.speed ~= nil and (latest.speed :: number) <= stillSpeed
	if distance <= def.arriveRadius and still then
		state.stillSince = state.stillSince or now
	else
		state.stillSince = nil
	end
	local stillFor = if state.stillSince ~= nil then now - state.stillSince else 0
	local decision: Arrival =
		JobService.arrivalDecision(distance, latest.speed, def.arriveRadius, stillSpeed, stillFor, stop.dwell or 0)
	return decision, distance
end

-- One check of an active job: fails first, then the sample, smoothness and arrival.
local function watchJob(player: Player, state: PlayerState, job: Job, now: number)
	local messages = Jobs.messages
	local info = carInfo(job.car)
	if info == nil then
		failJob(player, state, messages.failCarGone, now, false)
		return
	elseif VehicleService.getCar(player) ~= info.car then
		failJob(player, state, messages.failSwitchedCar, now, false)
		return
	elseif now > job.deadline then
		failJob(player, state, messages.failTimeout, now, false)
		return
	end
	if not isDriving(player, info.car) then
		state.outOfCarSince = state.outOfCarSince or now
		state.stillSince = nil
		if now - (state.outOfCarSince :: number) > Jobs.leaveCarSec then
			failJob(player, state, messages.failLeftCar, now, false)
		end
		return
	end
	state.outOfCarSince = nil
	local latest = sample(state, info.car, info.chassis, now)
	if job.smooth.tracking then
		local stop = job.stops[job.index]
		local approach = Jobs.types[job.type].arriveRadius * Jobs.smoothness.stopApproachFactor
		local nearStop = stop ~= nil and JobService.distanceToStop(stop, latest.position) <= approach
		checkSmoothness(job, state.history, now, nearStop)
	end
	if arrivalNow(state, job, latest, now) == "arrived" then
		advance(player, state, now)
	end
end

local function tick(now: number)
	for player, state in states do
		local ok, err = pcall(function()
			local job = state.job
			if job ~= nil then
				watchJob(player, state, job, now)
			elseif VehicleService.getCar(player) ~= state.offersCar or now >= state.nextRefresh then
				refreshOffers(player, state, now)
			end
		end)
		if not ok then
			warnOnce(`tick:{err}`, `check for {player.Name} failed: {err}`)
		end
	end
end

local function onHeartbeat(dt: number)
	sinceCheck += dt
	if sinceCheck < Jobs.checkInterval then
		return
	end
	sinceCheck = 0
	tick(os.clock())
end

-- Remotes ---------------------------------------------------------------------------------------------------------

local function answer(ok: boolean, message: string): { ok: boolean, message: string }
	return { ok = ok, message = message }
end

-- New offers after a refused accept, but no more often than a "refresh" may ask (Config/Jobs offers.minRefreshSec):
-- a stale or made-up offer id must not re-roll the offers faster. Otherwise the player is sent what they have.
local function refreshIfDue(player: Player, state: PlayerState, now: number)
	if now - state.lastRefresh >= Jobs.offers.minRefreshSec then
		refreshOffers(player, state, now)
	end
	queuePush(player)
end

local function onAccept(player: Player, state: PlayerState, offerId: string?, now: number)
	local messages = Jobs.messages
	if state.job ~= nil then
		return answer(false, messages.busy)
	end
	local dataService = DataService
	if dataService == nil or dataService.get(player) == nil then
		return answer(false, messages.loading)
	end
	local offer = if offerId ~= nil then state.offersById[offerId] else nil
	local car = VehicleService.getCar(player)
	if offer == nil or car ~= state.offersCar then
		refreshIfDue(player, state, now)
		return answer(false, messages.noOffer)
	end
	local kind = offer.type
	local module = modules[kind]
	local info = carInfo(car)
	local availability = availabilityFor(state, kind, info, now)
	if module == nil or not availability.ok then
		refreshIfDue(player, state, now)
		return answer(false, availability.reason or messages.noOffer)
	end
	local ok, job = pcall(module.start, player, offer, contextFor(player, kind, info))
	if not ok or type(job) ~= "table" then
		if not ok then
			warn(`{LOG} {kind} start failed for {player.Name}: {job}`)
		end
		refreshIfDue(player, state, now)
		return answer(false, messages.cantStart)
	end
	local started = job :: Job
	started.state = "accepted"
	started.type = kind
	state.job = started
	state.offers = {}
	state.offersById = {}
	state.outOfCarSince = nil
	state.stillSince = nil
	table.clear(state.history)
	notify(player, string.format(messages.accepted, started.title), Jobs.notifyKinds.info)
	queuePush(player)
	return answer(true, messages.ok)
end

-- JobAction "arrive": an immediate arrival check. Far from the stop it is a forged arrival: rejected and logged.
local function onArrive(player: Player, state: PlayerState, jobId: string?, now: number)
	local messages = Jobs.messages
	local job = state.job
	if job == nil or jobId ~= job.id then
		return answer(false, messages.noJob)
	end
	local info = carInfo(job.car)
	if info == nil then
		return answer(false, messages.noCar)
	end
	local def = Jobs.types[job.type]
	local stop = job.stops[job.index]
	local distance = JobService.distanceToStop(stop, info.chassis.Position)
	if distance > def.arriveRadius * Jobs.forgedArriveFactor then
		warn(
			string.format(
				"%s Rejected an arrival from %s (%d): the car is %d studs from stop %d of job %s",
				LOG,
				player.Name,
				player.UserId,
				math.floor(distance),
				job.index,
				job.id
			)
		)
		return answer(false, messages.notAtStop)
	end
	if not isDriving(player, info.car) then
		return answer(false, messages.noCar)
	end
	local latest = sample(state, info.car, info.chassis, now)
	local decision = arrivalNow(state, job, latest, now)
	if decision == "far" then
		return answer(false, messages.notAtStop)
	elseif decision == "moving" then
		return answer(false, messages.slowDown)
	elseif decision == "dwelling" then
		return answer(false, messages.holdStill)
	end
	advance(player, state, now)
	return answer(true, messages.ok)
end

local function onJobAction(player: Player, payload: any): any
	local state = states[player]
	if state == nil then
		return answer(false, Jobs.messages.loading)
	end
	local now = os.clock()
	local action = payload.action
	if action == "accept" then
		return onAccept(player, state, payload.offerId, now)
	elseif action == "arrive" then
		return onArrive(player, state, payload.jobId, now)
	elseif action == "cancel" then
		local job = state.job
		if job == nil or payload.jobId ~= job.id then
			return answer(false, Jobs.messages.noJob)
		end
		failJob(player, state, "", now, true)
		return answer(true, Jobs.messages.ok)
	end
	-- "refresh": new offers, at most once per Config minRefreshSec; during a job, just the current state. Every
	-- refresh is answered with a JobUpdate, even when the offers came out the same.
	if state.job == nil and now - state.lastRefresh >= Jobs.offers.minRefreshSec then
		refreshOffers(player, state, now)
	end
	queuePush(player)
	return answer(true, Jobs.messages.ok)
end

-- Studio only: put the job car on the road at the current stop (the automated tests' pickup shortcut).
local function onDevJob(player: Player, _payload: any): any
	if not RunService:IsStudio() then
		warn(`{LOG} DevJob refused outside Studio ({player.Name})`)
		return answer(false, Jobs.messages.devOnly)
	end
	local state = states[player]
	local job = if state ~= nil then state.job else nil
	local info = if job ~= nil then carInfo(job.car) else nil
	if state == nil or job == nil or info == nil then
		return answer(false, Jobs.messages.noJob)
	end
	local stop = job.stops[job.index]
	VehicleService.resetCar(info.car, roadPose(stop.approach or stop.position), DEV_RESET_REASON)
	AntiExploitService.allowTeleport(info.car)
	table.clear(state.history)
	state.stillSince = nil
	return answer(true, Jobs.messages.ok)
end

-- Boot ------------------------------------------------------------------------------------------------------------

local function newState(): PlayerState
	return {
		job = nil,
		offers = {},
		offersById = {},
		offersCar = nil,
		nextRefresh = 0,
		offersSignature = "",
		lastRefresh = -math.huge,
		availability = {},
		cooldowns = {},
		outOfCarSince = nil,
		stillSince = nil,
		history = {},
		pushQueued = false,
	}
end

local function addPlayer(player: Player)
	if states[player] == nil then
		states[player] = newState()
	end
end

-- A sibling module by name, or nil (logged) when it is missing or fails to load.
local function optionalModule(name: string): any?
	local child = script:FindFirstChild(name)
	if child == nil or not child:IsA("ModuleScript") then
		warn(`{LOG} {name} module is missing; carrying on without it`)
		return nil
	end
	local ok, result = pcall(require :: any, child)
	if not ok or type(result) ~= "table" then
		warn(`{LOG} {name} module failed to load; carrying on without it: {result}`)
		return nil
	end
	return result
end

local function isJobModule(module: any): boolean
	return type(module) == "table"
		and type(module.offers) == "function"
		and type(module.start) == "function"
		and type(module.onArrive) == "function"
		and type(module.pay) == "function"
end

function JobService:Init()
	DataService = require(script.Parent.DataService)
	modules.rideshare = Rideshare
	local delivery = optionalModule("Delivery")
	if delivery ~= nil then
		if isJobModule(delivery) then
			modules.delivery = delivery
		else
			warn(`{LOG} Delivery doesn't implement the JobType interface; rideshare only`)
		end
	end
	local levels = optionalModule("Levels")
	if levels ~= nil then
		if type(levels.levelFor) == "function" and type(levels.unlocks) == "function" then
			Levels = levels
		else
			warn(`{LOG} Levels lacks levelFor / unlocks; using Config/Jobs levels`)
		end
	end
end

function JobService:Start()
	-- Always answer, so the remotes never hang; DevJob itself refuses outside Studio.
	Net.onServerInvoke("JobAction", onJobAction)
	Net.onServerInvoke("DevJob", onDevJob)
	Players.PlayerAdded:Connect(addPlayer)
	for _, player in Players:GetPlayers() do
		addPlayer(player)
	end
	Players.PlayerRemoving:Connect(function(leaving: Player)
		states[leaving] = nil -- an unfinished job is dropped unpaid
	end)
	local dataService = DataService
	if dataService ~= nil then
		-- Levels and pay estimates depend on the player's XP: make offers again once it has loaded, and always push
		-- (a player on foot has the same "no car" offers as before, but their level and XP are new).
		dataService.onLoaded(function(player: Player, _data: SharedTypes.PlayerData)
			local state = states[player]
			if state ~= nil then
				if state.job == nil then
					refreshOffers(player, state, os.clock())
				end
				queuePush(player)
			end
		end)
	end
	RunService.Heartbeat:Connect(onHeartbeat)
end

return JobService
