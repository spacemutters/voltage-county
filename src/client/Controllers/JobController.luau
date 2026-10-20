--!strict
-- Jobs on the client (docs/phase-6-contracts.md "Client"; PLAN.md Phase 6). The server runs every job: it makes
-- the offers, starts a job when the player accepts one, watches the car reach each stop, and pays. This
-- controller keeps what the server last said and asks it for things:
--
--   cache      Net JobUpdate ({ job, offers?, availability?, progress? }, Services/JobService "publish") is
--              checked (normalize) and kept. get() hands it out with what the client adds (the car the player is
--              in, the time and distance left, a request in flight), and onChanged fires whenever any of that
--              changes. The phone's Jobs app and JobVisualsController read it here.
--   requests   accept(offerId), arrive(), cancel() and refresh() call Net JobAction, one at a time, and show the
--              server's reply ({ ok, message }) as a notice (NotifyController). A refused or rate-limited call
--              says so too. An accepted job closes the phone, so the road and the route are in view.
--   HUD        while a job runs, the slot under the cash (HudController.setActiveJob) shows its title, the pay
--              estimate, what to do at the current stop, and the distance and time left (amber, then red, as
--              time runs short; "Stop here..." once the car is close enough to count).
--   GPS        while a job runs the GPS leads to the current stop (GpsController.setDestination with the stop's
--              position and words, kept on arrival so the marker shows where to stop) and re-routes when the
--              stop changes. When the job ends the route is cleared, but only if it is still the job's: with no
--              job the GPS is the player's alone.
--
-- The time and distance left are worked out a few times a second (RunService.Heartbeat with an accumulator,
-- connected only while a job runs), and the HUD and the app redraw only when a shown value changes. Times: the
-- server sends the deadline in Unix seconds, read against Workspace:GetServerTimeNow(); a `timeLeft` in seconds
-- works too. The pure helpers (normalize, levels, the HUD texts, eligibility, the GPS decision) are exposed for
-- tests/JobClient.spec.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Catalog = require(ReplicatedStorage.Shared.Vehicle.Catalog)
local Classes = require(ReplicatedStorage.Shared.Config.Classes)
local Economy = require(ReplicatedStorage.Shared.Config.Economy)
local Graph = require(ReplicatedStorage.Shared.Road.Graph)
local Jobs = require(ReplicatedStorage.Shared.Config.Jobs)
local Net = require(ReplicatedStorage.Shared.Net)
local Spawning = require(ReplicatedStorage.Shared.Config.Spawning)
local DriveController = require(script.Parent.DriveController)
local GpsController = require(script.Parent.GpsController)
local HudController = require(script.Parent.HudController)
local InputController = require(script.Parent.InputController)
local NotifyController = require(script.Parent.NotifyController)
local ProfileController = require(script.Parent.ProfileController)

local PhoneConfig = require(script.Parent.Parent.UI.Phone.PhoneConfig)

local REMOTE_ACTION = "JobAction"
local REMOTE_UPDATE = "JobUpdate"
local OWNER_ATTRIBUTE = "OwnerUserId" -- set by VehicleService on every spawned car
local VEHICLE_ATTRIBUTE = "VehicleId" -- the vehicle model contract (PLAN.md §6)
local TRIM_ATTRIBUTE = "Trim"
local PHONE_MODULE = "PhoneController"
local SECONDS_PER_MINUTE = 60
local SECONDS_PER_HOUR = 3600

-- How the client side of jobs behaves (the server's rules are in Config/Jobs).
local TUNING = {
	tickHz = 4, -- time and distance left, worked out this often while a job runs
	-- Automatic offer refreshes (opening the Jobs app, changing cars) go at most this often, in seconds. A tap on
	-- "Find new offers" always asks (the server limits it too: Config/Jobs offers.minRefreshSec).
	autoRefreshSeconds = 8,
	lowSeconds = 60, -- the time left turns amber under this
	criticalSeconds = 20, -- and red under this
	-- A deadline larger than this is Unix seconds (os.time, Workspace:GetServerTimeNow). Anything smaller can't
	-- be read on this client, so no time left shows.
	unixAfter = 1e9,
}

-- What players read on the HUD and in the GPS chip. %s are filled in as noted.
local TEXT = {
	-- What to do at a stop (%s: the stop's label, e.g. "Town Square", "5 Cedar Court").
	stops = {
		pickup = "Pick up at %s",
		dropoff = "Drop off at %s",
		load = "Load up at %s",
		drop = "Deliver to %s",
		couple = "Hitch up at %s",
		decouple = "Uncouple at %s",
		waypoint = "Pass %s",
	} :: { [string]: string },
	-- Shown in place of the distance once the car is close enough for the stop to count.
	near = {
		pickup = "Stop here to pick up",
		dropoff = "Stop here to drop off",
		load = "Stop here to load up",
		drop = "Stop here to deliver",
		-- Couple and uncouple stops are done with the hitch button, not by stopping; a waypoint counts at speed.
		couple = "Tap Couple",
		decouple = "Stop and tap Uncouple",
		waypoint = "Keep going",
	} :: { [string]: string },
	nearFallback = "Stop here",
	status = "%s · %s left", -- distance, time left
	distanceOnly = "%s to go", -- distance (no deadline known)
	timeOnly = "%s left", -- time left (no position yet)
	clock = "%d:%02d", -- minutes, seconds
	clockHours = "%d:%02d:%02d", -- hours, minutes, seconds
	-- Lists of class names: "Van, SUV or Pickup".
	listJoin = ", ",
	listLast = " or ",
}

export type StopKind = "pickup" | "dropoff" | "load" | "drop" | "couple" | "decouple" | "waypoint"
export type Action = "accept" | "arrive" | "cancel" | "refresh"
export type TimeAlert = "normal" | "low" | "critical"

-- One stop of the active job, as JobUpdate sends it.
export type Stop = {
	position: Vector3,
	label: string,
	kind: string, -- a StopKind; anything else shows its label alone
	approach: Vector3?, -- the nearest road point, when the server sends it
}

-- The active job, as JobUpdate sends it, with its deadline turned into this client's clock.
export type Job = {
	id: string,
	type: string,
	title: string,
	stopIndex: number,
	stops: { Stop },
	endsAt: number?, -- os.clock() on this client when the time runs out; nil when the server sent no deadline
	estPay: number?,
	xl: boolean, -- an XL fare
}

-- An offer, as the phone lists it.
export type Offer = {
	id: string,
	type: string,
	title: string,
	subtitle: string,
	pay: number, -- estimated $
	distance: number, -- studs of road in all
	stops: number,
	xl: boolean,
}

-- The player's standing in one job type (JobUpdate `progress`).
export type Level = {
	level: number?, -- nil: the server sent XP only, and there is no ladder to read a level from
	xp: number,
	levelXp: number, -- XP at the start of this level
	nextXp: number?, -- XP for the next level (nil at the top)
	progress: number, -- 0..1 toward the next level (1 at the top)
	maxLevel: number,
	multiplier: number?, -- this level's pay multiplier, when known
	unlocks: { string }, -- Config/Jobs unlock ids reached so far
}

-- Whether a job type has offers for the player now, and if not, why (the server's words: no car, a test drive,
-- the wrong class with the classes that can, a cooldown).
export type Availability = { ok: boolean, reason: string? }

-- The car the player is driving, or else the car they have out.
export type Car = { vehicleId: string, classId: string, seats: number, name: string }

-- A request with the server.
export type Busy = { action: Action, offerId: string? }

-- One job type as the phone shows it (from Config/Jobs).
export type JobType = {
	id: string,
	name: string,
	classes: { string },
	bonusClasses: { string },
	xlClasses: { string },
	xlMinSeats: number?,
	cooldownSec: number,
	arriveRadius: number,
	waypointRadius: number?, -- studs from a waypoint stop that count as passing it (freight long hauls)
}

-- A checked JobUpdate. A field that is nil was not sent, so the last one stands (offers, availability and
-- levels); `job` nil means no job.
export type Update = {
	job: Job?,
	offers: { Offer }?,
	availability: { [string]: Availability }?,
	levels: { [string]: Level }?,
	licenses: { [string]: boolean }?, -- the job licenses the player holds, by license id
}

-- Everything the Jobs app and the job visuals read.
export type View = {
	loaded: boolean, -- a JobUpdate has arrived
	job: Job?,
	offers: { Offer },
	availability: { [string]: Availability }, -- by job type; empty until the server sends some
	levels: { [string]: Level }, -- by job type; empty until the server sends some
	licenses: { [string]: boolean }, -- by license id, from the server; empty until it sends them
	car: Car?,
	units: string, -- "mph" | "kph" (distances show in miles or kilometres)
	busy: Busy?,
	secondsLeft: number?, -- on the active job, whole seconds
	distanceText: string?, -- to the current stop, e.g. "0.8 mi"
	near: boolean, -- close enough to the current stop for it to count once the car stops
}

-- What the HUD slot shows (UI/Hud ActiveJob).
export type HudJob = HudController.ActiveJob

-- What the GPS should do about the job: route to a stop, clear the job's route, or nothing.
export type GpsStep = { action: "route", key: string, stop: Stop } | { action: "clear" } | { action: "none" }

-- The job's route, as last set: which job and stop, and where it leads.
export type Routed = { key: string, position: Vector3 }

local JobController = {}
JobController.tuning = TUNING
JobController.text = TEXT

-- Fires (view: View) whenever get() would return something new.
JobController.onChanged = InputController.newSignal()

local view: View = {
	loaded = false,
	job = nil,
	offers = {},
	availability = {},
	levels = {},
	licenses = {},
	car = nil,
	units = ProfileController.defaultSettings().units,
	busy = nil,
	secondsLeft = nil,
	distanceText = nil,
	near = false,
}

local ticker: RBXScriptConnection? = nil
local routed: Routed? = nil
local lastAutoRefresh = -math.huge -- os.clock() of the last automatic refresh
local lastHud: HudJob? = nil
local started = false

-- Pure helpers ---------------------------------------------------------------------------------------------------

local function finite(value: any): boolean
	return type(value) == "number" and value == value and math.abs(value) ~= math.huge
end

local function numberOr(value: any, fallback: number): number
	return if finite(value) then value else fallback
end

local function stringList(value: any): { string }
	local list: { string } = {}
	if type(value) == "table" then
		for _, item in value do
			if type(item) == "string" then
				table.insert(list, item)
			end
		end
	end
	return list
end

-- Config/Jobs is fixed data, so its job types are read once (typeList) and handed out as copies.
local typeList: { JobType }? = nil

local function readTypes(): { JobType }
	local cached = typeList
	if cached ~= nil then
		return cached
	end
	local list: { JobType } = {}
	local types = (Jobs.types :: any) :: { [string]: Jobs.JobDef }
	for _, id in Jobs.order do
		local def = types[id]
		if def ~= nil then
			table.insert(list, {
				id = def.id,
				name = def.displayName,
				classes = table.clone(def.classes),
				bonusClasses = if def.bonusClasses then table.clone(def.bonusClasses) else {},
				xlClasses = if def.xlClasses then table.clone(def.xlClasses) else {},
				xlMinSeats = def.xlMinSeats,
				cooldownSec = def.cooldownSec,
				arriveRadius = def.arriveRadius,
				waypointRadius = def.waypointRadius,
			})
		end
	end
	typeList = list
	return list
end

-- Every job type in Config/Jobs, in the order the phone lists them.
function JobController.jobTypes(): { JobType }
	return table.clone(readTypes())
end

-- One job type by id, or nil. Shared data: read it, don't change it.
function JobController.jobType(id: string): JobType?
	for _, info in readTypes() do
		if info.id == id then
			return info
		end
	end
	return nil
end

-- True when a car of class `classId` can do the job type (eligibility comes from the class, never the name).
function JobController.canDo(info: JobType, classId: string?): boolean
	return classId ~= nil and table.find(info.classes, classId) ~= nil
end

-- True when the car earns more on this job type: XL fares (an XL class, or enough seats) or the delivery bonus.
function JobController.earnsBonus(info: JobType, car: Car?): boolean
	if car == nil or not JobController.canDo(info, car.classId) then
		return false
	end
	if table.find(info.bonusClasses, car.classId) or table.find(info.xlClasses, car.classId) then
		return true
	end
	local minSeats = info.xlMinSeats
	return minSeats ~= nil and car.seats >= minSeats
end

-- "Van, SUV or Pickup": Config/Classes display names, in the order given (unknown ids are left out).
function JobController.classNames(classIds: { string }): string
	local names: { string } = {}
	for _, id in classIds do
		local class = Classes[id]
		if class ~= nil then
			table.insert(names, class.displayName)
		end
	end
	if #names <= 1 then
		return names[1] or ""
	end
	return table.concat(names, TEXT.listJoin, 1, #names - 1) .. TEXT.listLast .. names[#names]
end

-- The car a model is, from its VehicleId and Trim attributes and the catalog; nil for anything else.
function JobController.carInfo(vehicleId: any, trimId: any): Car?
	if type(vehicleId) ~= "string" then
		return nil
	end
	local vehicle = Catalog.getVehicle(vehicleId)
	if vehicle == nil then
		return nil
	end
	local trim = if type(trimId) == "string" then Catalog.getTrim(vehicleId, trimId) else nil
	return {
		vehicleId = vehicleId,
		classId = vehicle.class,
		seats = if trim then trim.seats else 0,
		name = vehicle.displayName,
	}
end

-- A player's standing at `xp` on a ladder of levels (Config/Jobs.levels[type]): the highest level whose
-- threshold is reached (level 1 below every threshold), and the way to the next. With no ladder, XP only.
function JobController.levelFromXp(ladder: { { xp: number } }?, xp: number): Level
	local amount = math.max(numberOr(xp, 0), 0)
	if ladder == nil or #ladder == 0 then
		return { level = nil, xp = amount, levelXp = 0, nextXp = nil, progress = 1, maxLevel = 1, unlocks = {} }
	end
	local level = 1
	for index, def in ladder do
		if amount >= def.xp then
			level = index
		else
			break
		end
	end
	local levelXp = ladder[level].xp
	local nextDef = ladder[level + 1]
	local progress = 1
	if nextDef ~= nil then
		local span = nextDef.xp - levelXp
		progress = if span > 0 then math.clamp((amount - levelXp) / span, 0, 1) else 1
	end
	return {
		level = level,
		xp = amount,
		levelXp = levelXp,
		nextXp = if nextDef then nextDef.xp else nil,
		progress = progress,
		maxLevel = #ladder,
		multiplier = nil,
		unlocks = {},
	}
end

local function ladderFor(jobType: string): { { xp: number } }?
	local levels = (Jobs.levels :: any) :: { [string]: { { xp: number } } }
	return levels[jobType]
end

-- One job type's standing as the server sent it (JobService's `progress`: { xp, level, multiplier, nextXp?,
-- unlocks }), or a bare XP number. Whatever the server leaves out (the level's own threshold, the top level)
-- comes from Config/Jobs' ladder. nil for anything else.
function JobController.normalizeLevel(jobType: string, value: any): Level?
	local ladder = ladderFor(jobType)
	if finite(value) then
		return JobController.levelFromXp(ladder, value)
	end
	if type(value) ~= "table" or not finite(value.xp) then
		return nil
	end
	local fromLadder = JobController.levelFromXp(ladder, value.xp)
	if not finite(value.level) then
		return fromLadder
	end
	local level = math.max(math.floor(value.level), 1)
	local xp = math.max(value.xp, 0)
	local rung = if ladder then ladder[level] else nil
	local levelXp = if finite(value.levelXp) then value.levelXp elseif rung then rung.xp else 0
	local nextXp = if finite(value.nextXp) then value.nextXp else nil
	local progress = 1
	if finite(value.progress) then
		progress = math.clamp(value.progress, 0, 1)
	elseif nextXp ~= nil and nextXp > levelXp then
		progress = math.clamp((xp - levelXp) / (nextXp - levelXp), 0, 1)
	end
	return {
		level = level,
		xp = xp,
		levelXp = levelXp,
		nextXp = nextXp,
		progress = progress,
		maxLevel = math.max(numberOr(value.maxLevel, fromLadder.maxLevel), level),
		multiplier = if finite(value.multiplier) then value.multiplier else nil,
		unlocks = stringList(value.unlocks),
	}
end

-- A stop as JobUpdate sends it ({ position, label, kind }). Its road approach point, when the server leaves it
-- out, is worked out the way the server's makeStop does (the nearest point on a road's centre line), so "close
-- enough to count" here matches the server's arrival check.
local function normalizeStop(value: any): Stop?
	if type(value) ~= "table" or typeof(value.position) ~= "Vector3" or type(value.label) ~= "string" then
		return nil
	end
	local approach: Vector3? = if typeof(value.approach) == "Vector3" then value.approach else nil
	if approach == nil then
		local edgeIndex, _, _, point = Graph.nearestEdge(value.position)
		approach = if edgeIndex ~= nil then point else nil
	end
	return {
		position = value.position,
		label = value.label,
		kind = if type(value.kind) == "string" then value.kind else "",
		approach = approach,
	}
end

-- When the job's time runs out, on this client's os.clock() (`clockNow`), from a deadline in Unix seconds read
-- against the server's clock (`serverNow`), or a `timeLeft` in seconds. nil when neither can be read.
function JobController.endsAt(value: { [string]: any }, clockNow: number, serverNow: number): number?
	local deadline = value.deadline
	if finite(deadline) and deadline > TUNING.unixAfter then
		return clockNow + (deadline - serverNow)
	end
	local timeLeft = value.timeLeft
	if finite(timeLeft) then
		return clockNow + timeLeft
	end
	return nil
end

local function normalizeJob(value: any, clockNow: number, serverNow: number): Job?
	if type(value) ~= "table" or type(value.id) ~= "string" or type(value.type) ~= "string" then
		return nil
	end
	if type(value.stops) ~= "table" then
		return nil
	end
	local stops: { Stop } = {}
	for _, raw in value.stops do
		local stop = normalizeStop(raw)
		if stop == nil then
			return nil -- a job with a broken stop can't be followed: show none rather than the wrong one
		end
		table.insert(stops, stop)
	end
	if #stops == 0 then
		return nil
	end
	local info = JobController.jobType(value.type)
	return {
		id = value.id,
		type = value.type,
		title = if type(value.title) == "string" then value.title elseif info then info.name else value.type,
		stopIndex = math.clamp(math.floor(numberOr(value.stopIndex, 1)), 1, #stops),
		stops = stops,
		endsAt = JobController.endsAt(value, clockNow, serverNow),
		estPay = if finite(value.estPay) then value.estPay else nil,
		xl = value.xl == true,
	}
end

local function normalizeOffer(value: any): Offer?
	if type(value) ~= "table" or type(value.id) ~= "string" or type(value.type) ~= "string" then
		return nil
	end
	if type(value.title) ~= "string" then
		return nil
	end
	local stops = if type(value.stops) == "table" then #value.stops else numberOr(value.stops, 0)
	return {
		id = value.id,
		type = value.type,
		title = value.title,
		subtitle = if type(value.subtitle) == "string" then value.subtitle else "",
		pay = math.max(numberOr(value.pay, 0), 0),
		distance = math.max(numberOr(value.distance, 0), 0),
		stops = math.max(math.floor(stops), 0),
		xl = value.xl == true,
	}
end

-- A checked copy of a JobUpdate payload, or nil when it isn't one. The payload comes from our own server, but a
-- bad field must never break the phone or the HUD: broken offers are left out, a job with a broken stop reads as
-- no job. `clockNow` (os.clock) and `serverNow` (Workspace:GetServerTimeNow) turn the deadline into this client's
-- clock.
function JobController.normalize(payload: any, clockNow: number, serverNow: number): Update?
	if type(payload) ~= "table" then
		return nil
	end
	local offers: { Offer }? = nil
	if type(payload.offers) == "table" then
		local list: { Offer } = {}
		for _, raw in payload.offers do
			local offer = normalizeOffer(raw)
			if offer then
				table.insert(list, offer)
			end
		end
		offers = list
	end
	local availability: { [string]: Availability }? = nil
	if type(payload.availability) == "table" then
		local byType: { [string]: Availability } = {}
		for jobType, raw in payload.availability do
			if type(jobType) == "string" and type(raw) == "table" then
				byType[jobType] = {
					ok = raw.ok == true,
					reason = if type(raw.reason) == "string" and raw.reason ~= "" then raw.reason else nil,
				}
			end
		end
		availability = byType
	end
	local levels: { [string]: Level }? = nil
	local source = if type(payload.progress) == "table" then payload.progress else payload.levels
	if type(source) == "table" then
		local byType: { [string]: Level } = {}
		for jobType, raw in source do
			if type(jobType) == "string" then
				local level = JobController.normalizeLevel(jobType, raw)
				if level then
					byType[jobType] = level
				end
			end
		end
		levels = byType
	end
	local licenses: { [string]: boolean }? = nil
	if type(payload.licenses) == "table" then
		local byId: { [string]: boolean } = {}
		for id, held in payload.licenses do
			if type(id) == "string" then
				byId[id] = held == true
			end
		end
		licenses = byId
	end
	return {
		job = normalizeJob(payload.job, clockNow, serverNow),
		offers = offers,
		availability = availability,
		levels = levels,
		licenses = licenses,
	}
end

-- "2:41", or "1:02:41" for an hour or more. Negative times read as 0:00.
function JobController.formatTime(seconds: number): string
	local whole = math.max(math.ceil(numberOr(seconds, 0)), 0)
	if whole >= SECONDS_PER_HOUR then
		return string.format(
			TEXT.clockHours,
			whole // SECONDS_PER_HOUR,
			(whole % SECONDS_PER_HOUR) // SECONDS_PER_MINUTE,
			whole % SECONDS_PER_MINUTE
		)
	end
	return string.format(TEXT.clock, whole // SECONDS_PER_MINUTE, whole % SECONDS_PER_MINUTE)
end

-- How worried the time left looks: amber under TUNING.lowSeconds, red under criticalSeconds.
function JobController.timeAlert(secondsLeft: number?): TimeAlert
	if secondsLeft == nil then
		return "normal"
	elseif secondsLeft < TUNING.criticalSeconds then
		return "critical"
	elseif secondsLeft < TUNING.lowSeconds then
		return "low"
	end
	return "normal"
end

-- "Pick up at Town Square": what to do at a stop.
function JobController.stopText(stop: Stop): string
	local format = TEXT.stops[stop.kind]
	return if format then string.format(format, stop.label) else stop.label
end

-- Horizontal studs from `position` to the stop, or to its road approach point when that is closer (the server
-- counts either, Config/Jobs arriveRadius).
function JobController.distanceTo(stop: Stop, position: Vector3): number
	local function flat(point: Vector3): number
		local delta = point - position
		return Vector3.new(delta.X, 0, delta.Z).Magnitude
	end
	local distance = flat(stop.position)
	local approach = stop.approach
	if approach then
		distance = math.min(distance, flat(approach))
	end
	return distance
end

-- What the HUD slot shows for a job: the title and the pay estimate, what to do at the current stop, and the
-- distance and time left ("Stop here to pick up" once `near`). The time left is amber, then red, as it runs out.
function JobController.hudFor(job: Job, secondsLeft: number?, distanceText: string?, near: boolean): HudJob
	local stop = job.stops[job.stopIndex]
	local status: string? = nil
	if near and stop then
		status = TEXT.near[stop.kind] or TEXT.nearFallback
	elseif distanceText and secondsLeft then
		status = string.format(TEXT.status, distanceText, JobController.formatTime(secondsLeft))
	elseif distanceText then
		status = string.format(TEXT.distanceOnly, distanceText)
	elseif secondsLeft then
		status = string.format(TEXT.timeOnly, JobController.formatTime(secondsLeft))
	end
	local estPay = job.estPay
	return {
		title = job.title,
		detail = if stop then JobController.stopText(stop) else nil,
		status = status,
		pay = if estPay then Economy.formatCash(estPay) else nil,
		alert = JobController.timeAlert(secondsLeft),
	}
end

-- What the GPS should do: route to the current stop when the job or its stop changed since the last route
-- (`current`), clear the job's route once there is no job (only when the GPS still leads where the job sent
-- it: `destination`, the GPS's current target), and otherwise nothing, so a place the player picked stands.
function JobController.gpsStep(job: Job?, current: Routed?, destination: Vector3?): GpsStep
	if job == nil then
		if current ~= nil and destination ~= nil and destination == current.position then
			return { action = "clear" }
		end
		return { action = "none" }
	end
	local stop = job.stops[job.stopIndex]
	local key = `{job.id}#{job.stopIndex}`
	if stop == nil or (current ~= nil and current.key == key) then
		return { action = "none" }
	end
	return { action = "route", key = key, stop = stop }
end

-- State ------------------------------------------------------------------------------------------------------------

local function snapshot(): View
	local copy = table.clone(view)
	copy.offers = table.clone(view.offers)
	copy.availability = table.clone(view.availability)
	copy.levels = table.clone(view.levels)
	copy.licenses = table.clone(view.licenses)
	return copy
end

local function changed()
	JobController.onChanged:Fire(snapshot())
end

-- What get() returns: the cached job, offers and levels, and the client's own additions. A copy: changing it
-- changes nothing here.
function JobController.get(): View
	return snapshot()
end

local function sameHud(a: HudJob?, b: HudJob?): boolean
	if a == nil or b == nil then
		return a == b
	end
	return a.title == b.title
		and a.detail == b.detail
		and a.status == b.status
		and a.pay == b.pay
		and a.alert == b.alert
end

local function refreshHud()
	local job = view.job
	local hud = if job then JobController.hudFor(job, view.secondsLeft, view.distanceText, view.near) else nil
	if sameHud(hud, lastHud) then
		return
	end
	lastHud = hud
	HudController.setActiveJob(hud)
end

-- Where the player is: their car's chassis while they drive, else their character.
local function playerPosition(): Vector3?
	local car = DriveController.getCar()
	local chassis = if car then car.PrimaryPart else nil
	if chassis ~= nil then
		return chassis.Position
	end
	local character = Players.LocalPlayer.Character
	local rootPart = if character then character:FindFirstChild("HumanoidRootPart") else nil
	if rootPart ~= nil and rootPart:IsA("BasePart") then
		return rootPart.Position
	end
	return nil
end

-- Studs left to the stop: along the GPS route while it still leads there (the road distance), else straight.
local function studsLeft(stop: Stop, position: Vector3): number
	local destination = GpsController.getDestination()
	local remaining = GpsController.remaining()
	if destination ~= nil and remaining ~= nil and destination.position == stop.position then
		return remaining
	end
	return JobController.distanceTo(stop, position)
end

-- Works out the time and distance left and whether the car is close enough to count. Returns true when any of
-- them changed (the caller redraws).
local function measure(): boolean
	local job = view.job
	if job == nil then
		return false
	end
	local endsAt = job.endsAt
	local secondsLeft = if endsAt then math.max(math.ceil(endsAt - os.clock()), 0) else nil
	local stop = job.stops[job.stopIndex]
	local position = playerPosition()
	local distanceText: string? = nil
	local near = false
	if stop ~= nil and position ~= nil then
		distanceText = GpsController.distanceText(studsLeft(stop, position), view.units)
		local info = JobController.jobType(job.type)
		-- A waypoint counts within its own (wider) radius, at any speed; every other stop within arriveRadius.
		local radius = if info == nil
			then nil
			elseif stop.kind == "waypoint" then info.waypointRadius or info.arriveRadius
			else info.arriveRadius
		near = radius ~= nil and JobController.distanceTo(stop, position) <= radius
	end
	if secondsLeft == view.secondsLeft and distanceText == view.distanceText and near == view.near then
		return false
	end
	view.secondsLeft = secondsLeft
	view.distanceText = distanceText
	view.near = near
	return true
end

-- One tick of the ticker: redraws the HUD and tells the app only when something shown changed.
local function tick()
	if measure() then
		refreshHud()
		changed()
	end
end

local function startTicker()
	if ticker then
		return
	end
	local interval = 1 / TUNING.tickHz
	local elapsed = 0
	ticker = RunService.Heartbeat:Connect(function(dt: number)
		elapsed += dt
		if elapsed >= interval then
			elapsed = 0
			tick()
		end
	end)
end

local function stopTicker()
	if ticker then
		ticker:Disconnect()
		ticker = nil
	end
end

-- Points the GPS at the current stop when the job or its stop changed, and clears the job's route once the job
-- is over (gpsStep). `force` routes again even to the same stop (the app's Show route).
local function syncGps(force: boolean?)
	local destination = GpsController.getDestination()
	local target = if destination then destination.position else nil
	local step = JobController.gpsStep(view.job, if force then nil else routed, target)
	if step.action == "route" then
		routed = { key = step.key, position = step.stop.position }
		GpsController.setDestination(step.stop.position, {
			name = JobController.stopText(step.stop),
			keepOnArrival = true,
		})
	elseif step.action == "clear" then
		routed = nil
		GpsController.setDestination(nil)
	elseif view.job == nil then
		routed = nil
	end
end

-- Takes in a checked JobUpdate.
local function apply(update: Update)
	local previous = view.job
	view.loaded = true
	view.job = update.job
	if update.offers then
		view.offers = update.offers
	end
	if update.availability then
		view.availability = update.availability
	end
	if update.licenses then
		view.licenses = update.licenses
	end
	if update.levels then
		-- Types the update leaves out keep what we had (a partial update never wipes a level).
		for jobType, level in update.levels do
			view.levels[jobType] = level
		end
	end
	local job = view.job
	if job == nil then
		stopTicker()
		view.secondsLeft = nil
		view.distanceText = nil
		view.near = false
	else
		if previous == nil or previous.id ~= job.id or previous.stopIndex ~= job.stopIndex then
			view.near = false -- a new stop: not there yet until the next tick says so
		end
		startTicker()
	end
	syncGps()
	measure()
	refreshHud()
	changed()
end

-- The car ---------------------------------------------------------------------------------------------------------

-- The car the player drives, else their own car that's out (when it is streamed in here).
local function currentCarModel(): Model?
	local driving = DriveController.getCar()
	if driving ~= nil then
		return driving
	end
	local userId = Players.LocalPlayer.UserId
	for _, instance in CollectionService:GetTagged(Spawning.vehicleTag) do
		if instance:IsA("Model") and instance:GetAttribute(OWNER_ATTRIBUTE) == userId then
			return instance
		end
	end
	return nil
end

local function refreshCar()
	local model = currentCarModel()
	local car = if model
		then JobController.carInfo(model:GetAttribute(VEHICLE_ATTRIBUTE), model:GetAttribute(TRIM_ATTRIBUTE))
		else nil
	local before = view.car
	if before == nil and car == nil then
		return
	end
	if
		before ~= nil
		and car ~= nil
		and before.vehicleId == car.vehicleId
		and before.classId == car.classId
		and before.seats == car.seats
	then
		return
	end
	view.car = car
	changed()
end

-- Requests ----------------------------------------------------------------------------------------------------------

-- The phone, found when it's needed: PhoneController draws the Jobs app, which reads this module, so requiring it
-- while this module loads would be a cycle. By the time a player taps anything every controller has loaded.
local function closePhone()
	local module = script.Parent:FindFirstChild(PHONE_MODULE)
	if module == nil or not module:IsA("ModuleScript") then
		return
	end
	local ok, phone = pcall(require, module)
	if ok and type(phone) == "table" and type(phone.close) == "function" then
		phone.close()
	end
end

-- Whether a JobAction reply ({ ok, message }) says the request worked.
local function replyWorked(called: boolean, reply: any): boolean
	return called and type(reply) == "table" and reply.ok == true
end

-- Shows a JobAction reply as a notice. A success that only says Config/Jobs messages.ok shows nothing: the server
-- tells the player what happened itself (Net Notify: "Job accepted", "Job cancelled").
local function showReply(called: boolean, reply: any)
	if not called then
		NotifyController.show(PhoneConfig.labels.failed, "error")
	elseif type(reply) == "table" then
		local ok = reply.ok == true
		local message = reply.message
		if type(message) == "string" and message ~= "" and not (ok and message == Jobs.messages.ok) then
			NotifyController.show(message, if ok then "success" else "warning")
		end
	else
		-- No answer: Net turned the request away (too many in a row).
		NotifyController.show(PhoneConfig.labels.tryLater, "warning")
	end
end

-- Sends one JobAction (one at a time) and shows the reply, unless `silent` (a refresh the player didn't ask
-- for). Returns whether it worked, or nil when another request was already waiting (nothing was sent). Yields
-- until the server answers.
local function request(payload: { [string]: any }, busy: Busy, silent: boolean): boolean?
	if view.busy ~= nil then
		return nil
	end
	view.busy = busy
	changed()
	local called, reply = pcall(Net.invokeServer, REMOTE_ACTION, payload)
	view.busy = nil
	if not silent then
		showReply(called, reply)
	end
	changed()
	return replyWorked(called, reply)
end

-- Accepts one of the listed offers. On success the server sends the new job (JobUpdate) and the phone closes.
-- Yields; returns whether it worked (nil: another request was waiting).
function JobController.accept(offerId: string): boolean?
	local worked = request({ action = "accept", offerId = offerId }, { action = "accept", offerId = offerId }, false)
	if worked then
		closePhone()
	end
	return worked
end

-- Asks the server to check the current stop right away (it also checks by itself a few times a second). Far from
-- the stop the server refuses it. Yields; returns whether it worked (nil: no job, or another request waiting).
function JobController.arrive(): boolean?
	local job = view.job
	if job == nil then
		return nil
	end
	return request({ action = "arrive", jobId = job.id }, { action = "arrive" }, false)
end

-- Cancels the active job (no pay; Config/Jobs cooldownSec before the next of its type). Yields; returns whether
-- it worked (nil: no job, or another request waiting).
function JobController.cancel(): boolean?
	local job = view.job
	if job == nil then
		return nil
	end
	return request({ action = "cancel", jobId = job.id }, { action = "cancel" }, false)
end

-- Asks for fresh offers for the player's car (the server answers with a JobUpdate). `auto` is a refresh the
-- player didn't tap for (joining, opening the app, changing cars): silent, and at most every
-- TUNING.autoRefreshSeconds. Yields; returns whether it worked (nil: skipped).
function JobController.refresh(auto: boolean?): boolean?
	if auto then
		local now = os.clock()
		if now - lastAutoRefresh < TUNING.autoRefreshSeconds then
			return nil
		end
		lastAutoRefresh = now
	end
	return request({ action = "refresh" }, { action = "refresh" }, auto == true)
end

-- Points the GPS at the current stop again (after the player ended the route or picked somewhere else) and
-- closes the phone so the route is in view.
function JobController.routeToStop()
	if view.job == nil then
		return
	end
	syncGps(true)
	closePhone()
end

-- Boot ------------------------------------------------------------------------------------------------------------

function JobController:Start()
	if started then
		return
	end
	started = true

	view.units = ProfileController.settings().units
	ProfileController.onChanged:Connect(function()
		local units = ProfileController.settings().units
		if units ~= view.units then
			view.units = units
			measure() -- the distance again, in the new units
			refreshHud()
			changed()
		end
	end)

	-- The car the offers are for.
	DriveController.onDrivingChanged:Connect(refreshCar)
	CollectionService:GetInstanceAddedSignal(Spawning.vehicleTag):Connect(function(instance: Instance)
		if instance:IsA("Model") and instance:GetAttribute(OWNER_ATTRIBUTE) == Players.LocalPlayer.UserId then
			refreshCar()
		end
	end)
	CollectionService:GetInstanceRemovedSignal(Spawning.vehicleTag):Connect(refreshCar)
	refreshCar()

	Net.onClientEvent(REMOTE_UPDATE, function(payload: any)
		local update = JobController.normalize(payload, os.clock(), Workspace:GetServerTimeNow())
		if update == nil then
			warn("[JobController] ignored a JobUpdate that isn't one")
			return
		end
		apply(update)
	end)

	-- The first offers and levels (the server also sends them by itself; this covers a JobUpdate sent before
	-- this client was listening).
	task.spawn(JobController.refresh, true)
end

return JobController
