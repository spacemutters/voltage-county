--!strict
-- Studio-only job tests (PLAN.md Phase 6 acceptance; docs/phase-6-contracts.md "Tests"). Each one drives real
-- jobs with Dev/AutoDriver using only what a player's client can do: the JobAction remote (refresh, accept, arrive,
-- cancel), the JobUpdate the server sends back, and the car's position. Services/JobService decides every step
-- from the positions it sees, and pays; the tests measure what it paid (the player's Cash attribute):
--   rideshare(opts)       spawns an eligible sedan (SETTINGS.rideshareCar, or opts.vehicleId / opts.trim) on an
--                         open road, asks for fresh offers, accepts the first rideshare fare listed (what a typical
--                         player takes; the server makes offers at random), drives to the pickup
--                         along Pathfind's route, holds still until the server picks the fare up, then drives to
--                         the drop-off and holds still until it pays. Reports the pay, each leg's length and time
--                         (driving, then waiting for the server), the whole job's time and its $/min.
--   delivery(car, opts)   the same with a delivery job, through the depot (loading) and every drop. `car` is a
--                         vehicle id or a Config/Classes id (the first drivable vehicle of that class); the default
--                         is a Northline van (SETTINGS.deliveryCar).
--   forgedComplete(opts)  accepts the first fare (opts.type: "rideshare" by default, or "delivery"); while the car
--                         is still far from the stop it sends JobAction arrive for it and expects a refusal: the
--                         reply says no, the job stays at that stop and nothing is paid. It then drives every stop
--                         but the last for real and forges the last one ("complete the job") from far away the same
--                         way, sends arrive for a job id that isn't the player's, and cancels the job (the cancel
--                         cooldown, Config/Jobs cooldownSec, applies afterwards). JobService logs each refusal.
--   rate(type, minutes, opts)  chains jobs of `type` ("rideshare" or "delivery") back to back for `minutes` (the
--                         last job is finished) and reports the average $/min against Config/Economy.activities:
--                         rideshare, rideshareXL in an XL car, delivery with the +20 % in a bonus class. Passes
--                         within SETTINGS.rateTolerance. opts.teleportPickup jumps every pickup or depot leg with
--                         the Studio-only DevJob teleportToStop instead of driving it; without it, a pickup or depot
--                         leg the AutoDriver can't finish is rescued the same way (and noted). Drop-off and drop
--                         legs are always driven.
--   start(name, ...)      runs any of them in the background and returns at once; lastResult() returns its result
--                         once done (nil while it runs), status() what it's doing, stop() cancels it.
-- Each returns a Result (see the type): { name, passed, reason, checks, vehicle, elapsed, ... } plus the test's
-- numbers. Every check and result is printed as it finishes, so get_console_output shows them even if execute_luau
-- stops waiting.
--
-- How the numbers are measured:
--   * Pay is the Cash gained from just before the accept to just after the job ends, less any drive-to-earn payout
--     in that window (DriveEarnService's Studio-only DriveEarnLast decisions). A job and drive-to-earn never stack,
--     so drive-to-earn paying anything while the job runs fails a check.
--   * A job's time runs from the accept to the JobUpdate that ends it; its cycle adds the offer refresh and the
--     accept before it. In rate() a cycle runs from the previous job's end (so the wait for its pay counts too),
--     holds still for Config/Jobs.calibration.betweenSeconds (reading and choosing offers), then refreshes, accepts
--     the first offer listed and drives it. rate()'s $/min is the pay of every job over the sum of their cycles.
--     Waiting out a cooldown (after a job the test driver had to give up) isn't counted.
--   * Config/Jobs calibrates the §4 rates for a level-1, mid-skill player with no earnings boost. Each job's level
--     and pay multiplier come from the JobUpdate's progress, and rate() compares the pay with each job's level
--     multiplier taken back out of its fare and its tip swapped for the calibration's average tip
--     (perMinuteAtLevel1): the AutoDriver brakes gently and always keeps the whole tip. An earnings boost (a code)
--     can't be seen from here: run rate() with none running.
--   * The AutoDriver cruises at SETTINGS.cruiseMph and slows for corners, which averages about the 30 mph
--     Config/Jobs calibrates on.
--
-- Run from MCP execute_luau in the Client datamodel of a playtest (a character is enough: every test spawns its
-- own car on an open road unless opts.keepCar and the car you sit in can do the job). Runs take minutes, longer than
-- an execute_luau call waits:
--   require(game.Players.LocalPlayer.PlayerScripts.Client.Dev.JobTests).start("rideshare")
--   require(game.Players.LocalPlayer.PlayerScripts.Client.Dev.JobTests).start("delivery", "northline_satchel")
--   require(game.Players.LocalPlayer.PlayerScripts.Client.Dev.JobTests).start("forgedComplete")
--   require(game.Players.LocalPlayer.PlayerScripts.Client.Dev.JobTests).start("rate", "rideshare", 10)
--   require(game.Players.LocalPlayer.PlayerScripts.Client.Dev.JobTests).lastResult()
--
-- Driving goes through AutoDriver's Bridge (see its header), so calls from MCP's copy of this module drive the
-- game's controllers; remotes go through this copy's own Net (set up on first use, as Dev/EnergyTests does), and
-- this copy listens to JobUpdate and Notify itself. State that every copy must see (running, cancel, the last
-- result) lives in attributes on this ModuleScript, as in Dev/EarnTests. Jobs pay real (Studio) cash and XP.
--
-- Does nothing outside Studio (CLAUDE.md hard rule 8); the server refuses DevJob and DevSpawnVehicle outside
-- Studio too. The client loader never boots it.

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local AutoDriver = require(script.Parent.AutoDriver)
local Catalog = require(Shared.Vehicle.Catalog)
local Classes = require(Shared.Config.Classes)
local DriveEarn = require(Shared.Config.DriveEarn)
local Economy = require(Shared.Config.Economy)
local Graph = require(Shared.Road.Graph)
local Jobs = require(Shared.Config.Jobs)
local MapLayout = require(Shared.Config.MapLayout)
local Net = require(Shared.Net)
local Pathfind = require(Shared.Road.Pathfind)
local RouteTests = require(script.Parent.RouteTests)
local Spawning = require(Shared.Config.Spawning)
local World = require(Shared.Config.World)

export type TestName = "rideshare" | "delivery" | "forgedComplete" | "rate"
export type JobKind = Jobs.JobType

export type Options = {
	vehicleId: string?, -- spawn this car (default: SETTINGS.rideshareCar or SETTINGS.deliveryCar)
	trim: string?, -- with vehicleId (default: the vehicle's first trim)
	keepCar: boolean?, -- use the car you sit in when it can do the job (default: spawn a fresh one)
	startAt: string?, -- a MapLayout location id: spawn on the open road nearest it (default: nearest you)
	mph: number?, -- AutoDriver cruise speed (default SETTINGS.cruiseMph)
	teleportPickup: boolean?, -- DevJob teleportToStop for every pickup or depot leg instead of driving it
	type: JobKind?, -- forgedComplete: the job type to accept (default "rideshare")
}

export type Check = { name: string, passed: boolean, detail: string }

-- One stop of a job, driven (or teleported to) and waited at.
export type Leg = {
	index: number, -- the stop's index in the job
	kind: string, -- "pickup", "dropoff", "load" or "drop"
	label: string, -- the stop's name ("Town Square", "5 Cedar Court")
	routeStuds: number, -- studs of road driven to it
	driveSeconds: number, -- AutoDriver, from leaving to stopping
	waitSeconds: number, -- held still at the stop until the server moved the job on
	seconds: number, -- the whole leg: from the previous stop (or the accept) to the server moving on
	maxMph: number,
	stuckEvents: number,
	askedArrive: boolean, -- the server hadn't moved on after SETTINGS.advanceTimeout, so it was asked (arrive)
	teleported: boolean, -- DevJob teleportToStop was used for this leg
	reason: string, -- "advanced", or why the leg failed
}

-- One job, from the offer to the pay.
export type JobRun = {
	type: string,
	title: string,
	offerPay: number, -- the offer's estimate (before boosts and VIP)
	offerDistance: number, -- studs of road the offer said the job drives (unpaid leg included)
	xl: boolean, -- the offer was an XL fare
	stops: number, -- stops in the job (rideshare: pickup and drop-off; delivery: the depot and the drops)
	completed: boolean, -- the server finished the job and paid
	pay: number, -- $ the job paid (cash gained, less drive-to-earn)
	tip: number?, -- rideshare: the tip the completion notice named
	driveEarnPaid: number, -- $ drive-to-earn paid while the job was active (should be 0)
	seconds: number, -- accept to the job ending
	cycleSeconds: number, -- refresh (rate(): the previous job's end) to the job ending (what rate() counts)
	perMinute: number, -- pay per minute of `seconds`
	routeStuds: number, -- studs of road driven for the job
	timeAllowed: number?, -- seconds from the accept to the job's deadline (Config/Jobs time limit)
	timeLeft: number?, -- seconds still left on the deadline when the job ended
	level: number?, -- the player's level in this job type when it was accepted
	levelMultiplier: number?, -- that level's pay multiplier
	xpGained: number, -- XP the job added (from the JobUpdate's progress)
	legs: { Leg },
	reason: string, -- "completed", or why it ended
}

export type Result = {
	name: string,
	passed: boolean,
	reason: string, -- "done", or why it ended early
	checks: { Check },
	vehicle: string?, -- "vehicleId/trim"
	class: string?, -- its Config/Classes id
	elapsed: number, -- seconds the whole test took
	notes: { string },
	notices: { string }, -- the Notify toasts the server sent during the test, in order
	-- rideshare, delivery, forgedComplete
	job: JobRun?,
	-- rate
	jobs: { JobRun }?,
	minutes: number?, -- minutes counted (the jobs' cycles)
	earned: number?,
	perMinute: number?, -- what was paid, per minute counted
	perMinuteAtLevel1: number?, -- the same with each job's level multiplier taken back out (what §4 targets)
	target: number?, -- Config/Economy.activities $/min for this job type and car
	targetName: string?, -- which activity rate that is
	ratio: number?, -- perMinuteAtLevel1 / target
	failedJobs: number?,
}

-- A dev tool, so its numbers live here rather than in Shared/Config (like Dev/EarnTests' SETTINGS).
local SETTINGS = {
	-- The cars (docs/phase-6-contracts.md "Tests": an eligible sedan; a Northline van).
	rideshareCar = { vehicleId = "ohm_spark", trim = "standard" },
	deliveryCar = { vehicleId = "northline_satchel", trim = "standard" },
	-- Driving. The AutoDriver slows for corners and junctions, so a 35 mph cruise averages about the 30 mph
	-- Config/Jobs calibrates pay on.
	cruiseMph = 35,
	maxMiter = 2, -- right-hand lane offset at corners (as Dev/RouteTests)
	-- Stops. The AutoDriver drives to the road point nearest the stop (arrival counts from there too) and stops
	-- within stopArriveRadius of it. When even that point is farther than reachFraction x the job's arriveRadius
	-- from the stop, it pulls in toward the stop until it is that close.
	stopArriveRadius = 6,
	reachFraction = 0.5,
	advanceTimeout = 20, -- seconds held still at a stop before asking the server (JobAction arrive)
	arriveRetryTimeout = 10, -- seconds after asking (or after a teleport) before giving up on the stop
	-- Spawning on an open road: the middle of the nearest edge this long or longer, of one of these kinds (no
	-- highway, ramp, bridge or trail), in its right-hand lane.
	minStartEdge = 100,
	startKinds = { "street", "arterial" },
	standHeight = 3, -- studs above the road the character is put at before the car spawns
	streamTimeout = 10, -- seconds to wait for the map around the start to stream in
	spawnTimeout = 15,
	exitTimeout = 5,
	settleSeconds = 1.5, -- after getting out, moving or sitting down, before the next step
	-- Remotes.
	actionGap = 1.1, -- seconds between JobAction calls (Net allows a burst of 4, then one a second)
	updateTimeout = 10, -- seconds to wait for the JobUpdate a JobAction should bring
	stateTimeout = 3, -- seconds to wait for a JobUpdate showing a job left over from before the test
	offerTries = 4, -- refreshes tried before giving up on an offer of the wanted type
	cooldownSlack = 1, -- seconds added to a cooldown before trying again
	cashSettleSeconds = 3, -- after a job ends, for its pay to reach the Cash attribute
	-- forgedComplete: the car counts as far from a stop when it is this many studs beyond Config/Jobs
	-- forgedArriveFactor x arriveRadius from it (and from its road point), and the job is watched this long
	-- after each forged arrive for a JobUpdate that moves it on.
	forgedMargin = 25,
	forgedWatchSeconds = 3,
	-- rate()
	rateTolerance = 0.15, -- passes within ±15 % of the §4 target
	maxFailuresInARow = 3, -- stops the chain after this many failed jobs in a row
	-- Housekeeping.
	maxNotices = 60, -- Notify texts kept in a result
	holdSeconds = 2, -- after a test: brake and hold this long so the car ends stopped
}

local STATUS = "Status" -- attribute: "idle", "running", "done", "stopped" or "failed"
local CURRENT = "Current" -- attribute: what the running test is doing now
local RESULT = "Result" -- attribute: the last result, as JSON
local CANCEL = "Cancel" -- attribute: true asks a running test to stop
local RUN_ID = "RunId" -- attribute: the id of the newest test
local LOG = "[JobTests]"
local SECONDS_PER_MINUTE = 60
local EPSILON = 1e-6
local DRIVER_SEAT = "Driver" -- the vehicle model contract
local PICKUP_KINDS = { "pickup", "load" } -- the legs before the paid part of a job

-- What this client sees of the server's JobUpdate (docs/phase-6-contracts.md "Server"; Services/JobService).
type StopView = { position: Vector3, label: string, kind: string }
type JobView = {
	id: string,
	type: string,
	title: string,
	stopIndex: number,
	stops: { StopView },
	estPay: number?,
	deadline: number?, -- Workspace:GetServerTimeNow() seconds
	startedAt: number?, -- the same clock
}
type Progress = { xp: number, level: number, multiplier: number }
type Availability = { ok: boolean, reason: string }
type OfferView = {
	id: string,
	type: string,
	title: string,
	pay: number,
	distance: number,
	stops: number,
	xl: boolean,
}
type Reply = { ok: boolean, message: string }

-- Everything the server tells this client during a test, kept as it arrives.
type Watch = {
	job: JobView?, -- the active job as the server last sent it (nil: none)
	offers: { OfferView }?, -- the offers the server last sent (nil during a job: it sends none then)
	availability: { [string]: Availability }, -- per job type: whether it can be offered now, and why not
	progress: { [string]: Progress }, -- per job type: XP, level and pay multiplier
	updates: number, -- JobUpdates received
	offerUpdates: number, -- JobUpdates that carried offers
	changedAt: number, -- os.clock() of the last JobUpdate
	endedAt: { [string]: number }, -- job id -> os.clock() of the JobUpdate that showed it gone
	notices: { { at: number, text: string } },
	driveEarn: { { at: number, amount: number } }, -- drive-to-earn decisions (Studio debug attributes)
	changed: BindableEvent, -- fires after every JobUpdate, notice, cash change and drive-to-earn decision
	connections: { RBXScriptConnection },
}

type Context = {
	id: string,
	name: TestName,
	started: number,
	result: Result,
	watch: Watch,
}

---------------------------------------------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------------------------------------------

local locationsById: { [string]: MapLayout.Location } = {}
for _, location in MapLayout.locations do
	locationsById[location.id] = location
end

local function flat(v: Vector3): Vector3
	return Vector3.new(v.X, 0, v.Z)
end

local function flatDistance(a: Vector3, b: Vector3): number
	return (flat(a) - flat(b)).Magnitude
end

local function round(value: number, places: number): number
	local scale = 10 ^ places
	return math.round(value * scale) / scale
end

local function textOf(value: any): string
	return if type(value) == "string" then value else ""
end

local function numberOf(value: any): number
	return if type(value) == "number" and value == value then value else 0
end

-- A Lua pattern that matches text made from a Config/Jobs message format: %s and %d become captures.
local function patternOf(format: string): string
	local escaped = string.gsub(format, "[%^%$%(%)%.%[%]%*%+%-%?]", "%%%0")
	escaped = string.gsub(escaped, "%%s", "(.-)")
	escaped = string.gsub(escaped, "%%d", "(%%d+)")
	return "^" .. escaped .. "$"
end

local COOLDOWN_PATTERN = patternOf(Jobs.messages.cooldown)
local CANCELLED_PATTERN = patternOf(Jobs.messages.cancelled)
local COMPLETED_TIP_PATTERN = patternOf(Jobs.messages.completedTip)
local FAILED_PATTERN = patternOf(Jobs.messages.failed)
local LEVEL_UP_PATTERN = patternOf(Jobs.messages.levelUp)

-- "$1,234" -> 1234.
local function dollars(text: string): number?
	local digits = string.gsub(text, "[^%d]", "")
	return tonumber(digits)
end

local function cancelRequested(ctx: Context): boolean
	return script:GetAttribute(CANCEL) == true or script:GetAttribute(RUN_ID) ~= ctx.id
end

local function setCurrent(ctx: Context, text: string)
	if script:GetAttribute(RUN_ID) == ctx.id then
		script:SetAttribute(CURRENT, text)
	end
	print(`{LOG} {ctx.name}: {text}`)
end

local function note(ctx: Context, text: string)
	table.insert(ctx.result.notes, text)
	print(`{LOG} {ctx.name}: {text}`)
end

local function check(ctx: Context, name: string, passed: boolean, detail: string)
	table.insert(ctx.result.checks, { name = name, passed = passed, detail = detail })
	print(`{LOG} {ctx.name}: {if passed then "PASS" else "FAIL"} {name} ({detail})`)
end

local netReady = false

-- This copy of Net may be MCP's own (not the game's), so make sure it knows the remotes.
local function ensureNet()
	if not netReady then
		Net.setupClient()
		netReady = true
	end
end

local function humanoidOf(): Humanoid?
	local character = Players.LocalPlayer.Character
	return if character then character:FindFirstChildOfClass("Humanoid") else nil
end

-- The car whose Driver seat the local player sits in, or nil.
local function currentCar(): Model?
	local humanoid = humanoidOf()
	local seat = if humanoid then humanoid.SeatPart else nil
	if seat == nil or seat.Name ~= DRIVER_SEAT then
		return nil
	end
	local node: Instance? = seat.Parent
	while node do
		if node:IsA("Model") and node:GetAttribute("VehicleId") ~= nil then
			return node
		end
		node = node.Parent
	end
	return nil
end

-- The pose of the driven car's chassis, or nil.
local function carPose(): CFrame?
	local car = currentCar()
	local chassis = if car then car.PrimaryPart else nil
	return if chassis then chassis.CFrame else nil
end

local function carIdentity(car: Model): (string?, string?)
	local vehicleId, trim = car:GetAttribute("VehicleId"), car:GetAttribute("Trim")
	return if type(vehicleId) == "string" then vehicleId else nil, if type(trim) == "string" then trim else nil
end

local function cash(): number
	local value = Players.LocalPlayer:GetAttribute(Economy.cashAttribute)
	return if type(value) == "number" then value else 0
end

-- Waits until `test()` is true, re-checking whenever `signal` fires, for at most `timeout` seconds; a cancel ends
-- the wait too. Returns whether `test()` came true.
local function waitFor(ctx: Context, test: () -> boolean, signal: RBXScriptSignal, timeout: number): boolean
	if test() then
		return true
	end
	if cancelRequested(ctx) then
		return false
	end
	local thread = coroutine.running()
	local settled = false
	local connections: { RBXScriptConnection } = {}
	local timer: thread? = nil
	local function finish(result: boolean)
		if settled then
			return
		end
		settled = true
		for _, connection in connections do
			connection:Disconnect()
		end
		if timer ~= nil and coroutine.running() ~= timer then
			task.cancel(timer)
		end
		task.spawn(thread, result)
	end
	table.insert(
		connections,
		signal:Connect(function()
			if test() then
				finish(true)
			end
		end)
	)
	table.insert(
		connections,
		script:GetAttributeChangedSignal(CANCEL):Connect(function()
			if cancelRequested(ctx) then
				finish(false)
			end
		end)
	)
	timer = task.delay(timeout, function()
		finish(test())
	end)
	return coroutine.yield()
end

-- Holds the car still (AutoDriver.holdStill) until `test()` comes true, re-checked whenever the watch changes, or
-- `timeout` seconds pass. The change that makes it true ends the hold at once. Returns whether it came true.
local function holdUntil(ctx: Context, test: () -> boolean, timeout: number): boolean
	if test() then
		return true
	end
	if cancelRequested(ctx) then
		return false
	end
	local holding = true
	local connection = ctx.watch.changed.Event:Connect(function()
		if holding and test() then
			holding = false
			AutoDriver.stop()
		end
	end)
	AutoDriver.holdStill(timeout)
	holding = false
	connection:Disconnect()
	return test()
end

---------------------------------------------------------------------------------------------------------------
-- What the server says: JobUpdate, Notify, cash and drive-to-earn
---------------------------------------------------------------------------------------------------------------

local function parseJob(raw: any): JobView?
	if type(raw) ~= "table" or type(raw.id) ~= "string" or type(raw.stops) ~= "table" then
		return nil
	end
	local stops: { StopView } = {}
	for _, stop in raw.stops do
		if type(stop) == "table" and typeof(stop.position) == "Vector3" then
			table.insert(stops, { position = stop.position, label = textOf(stop.label), kind = textOf(stop.kind) })
		end
	end
	return {
		id = raw.id,
		type = textOf(raw.type),
		title = textOf(raw.title),
		stopIndex = if type(raw.stopIndex) == "number" then raw.stopIndex else 1,
		stops = stops,
		estPay = if type(raw.estPay) == "number" then raw.estPay else nil,
		deadline = if type(raw.deadline) == "number" then raw.deadline else nil,
		startedAt = if type(raw.startedAt) == "number" then raw.startedAt else nil,
	}
end

-- Per job type entries of the update's `progress` ({ xp, level, multiplier }) and `availability` ({ ok, reason }).
local function parseProgress(raw: any, into: { [string]: Progress })
	if type(raw) ~= "table" then
		return
	end
	for kind, entry in raw do
		if type(kind) == "string" and type(entry) == "table" then
			into[kind] =
				{ xp = numberOf(entry.xp), level = numberOf(entry.level), multiplier = numberOf(entry.multiplier) }
		end
	end
end

local function parseAvailability(raw: any, into: { [string]: Availability })
	if type(raw) ~= "table" then
		return
	end
	for kind, entry in raw do
		if type(kind) == "string" and type(entry) == "table" then
			into[kind] = { ok = entry.ok == true, reason = textOf(entry.reason) }
		end
	end
end

local function parseOffers(raw: any): { OfferView }?
	if type(raw) ~= "table" then
		return nil
	end
	local offers: { OfferView } = {}
	for _, offer in raw do
		if type(offer) == "table" and type(offer.id) == "string" then
			table.insert(offers, {
				id = offer.id,
				type = textOf(offer.type),
				title = textOf(offer.title),
				pay = numberOf(offer.pay),
				distance = numberOf(offer.distance),
				stops = numberOf(offer.stops),
				xl = offer.xl == true,
			})
		end
	end
	return offers
end

-- The decision DriveEarnService last published (Studio only), or nil.
local function lastDriveEarnAmount(): number?
	local encoded = Players.LocalPlayer:GetAttribute(DriveEarn.debugDecisionAttribute)
	if type(encoded) ~= "string" then
		return nil
	end
	local ok, decoded = pcall(HttpService.JSONDecode, HttpService, encoded)
	return if ok and type(decoded) == "table" and type(decoded.amount) == "number" then decoded.amount else nil
end

local function newWatch(): Watch
	ensureNet()
	local watch: Watch = {
		job = nil,
		offers = nil,
		availability = {},
		progress = {},
		updates = 0,
		offerUpdates = 0,
		changedAt = os.clock(),
		endedAt = {},
		notices = {},
		driveEarn = {},
		changed = Instance.new("BindableEvent"),
		connections = {},
	}
	local player = Players.LocalPlayer
	table.insert(
		watch.connections,
		Net.onClientEvent("JobUpdate", function(payload: any)
			if type(payload) ~= "table" then
				return
			end
			local now = os.clock()
			local previous = watch.job
			local job = parseJob(payload.job)
			if previous ~= nil and (job == nil or job.id ~= previous.id) then
				watch.endedAt[previous.id] = now
			end
			watch.job = job
			local offers = parseOffers(payload.offers)
			if offers ~= nil then
				watch.offers = offers
				watch.offerUpdates += 1
			elseif job ~= nil then
				watch.offers = nil -- none are offered during a job
			end
			parseProgress(payload.progress, watch.progress)
			if job == nil then
				-- Availability is only sent while there is no job.
				table.clear(watch.availability)
				parseAvailability(payload.availability, watch.availability)
			end
			watch.updates += 1
			watch.changedAt = now
			watch.changed:Fire()
		end)
	)
	table.insert(
		watch.connections,
		Net.onClientEvent("Notify", function(payload: any)
			local text = if type(payload) == "table" then textOf(payload.text) else ""
			if text ~= "" then
				table.insert(watch.notices, { at = os.clock(), text = text })
				watch.changed:Fire()
			end
		end)
	)
	table.insert(
		watch.connections,
		player:GetAttributeChangedSignal(Economy.cashAttribute):Connect(function()
			watch.changed:Fire()
		end)
	)
	table.insert(
		watch.connections,
		player:GetAttributeChangedSignal(DriveEarn.debugTickAttribute):Connect(function()
			table.insert(watch.driveEarn, { at = os.clock(), amount = lastDriveEarnAmount() or 0 })
			watch.changed:Fire()
		end)
	)
	return watch
end

local function closeWatch(watch: Watch)
	for _, connection in watch.connections do
		connection:Disconnect()
	end
	watch.changed:Destroy()
end

-- Drive-to-earn paid since `since` (os.clock()).
local function driveEarnSince(watch: Watch, since: number): number
	local total = 0
	for _, decision in watch.driveEarn do
		if decision.at >= since then
			total += decision.amount
		end
	end
	return total
end

-- The newest notice since `since` matching `pattern`, with its captures.
local function noticeSince(watch: Watch, since: number, pattern: string): (string?, { string })
	for index = #watch.notices, 1, -1 do
		local notice = watch.notices[index]
		if notice.at < since then
			break
		end
		local captures = { string.match(notice.text, pattern) }
		if #captures > 0 then
			return notice.text, captures
		end
	end
	return nil, {}
end

-- The newest notice since `since`, whatever it says.
local function lastNoticeSince(watch: Watch, since: number): string?
	local notice = watch.notices[#watch.notices]
	return if notice and notice.at >= since then notice.text else nil
end

---------------------------------------------------------------------------------------------------------------
-- Remotes
---------------------------------------------------------------------------------------------------------------

local lastActionAt = -math.huge

-- Calls JobAction no faster than Net's rate limit allows (a call over the limit is dropped, and its nil answer would
-- read as a refusal). Returns the server's { ok, message }, or nil when there was no answer.
local function jobAction(payload: { [string]: any }): Reply?
	ensureNet()
	local gap = SETTINGS.actionGap - (os.clock() - lastActionAt)
	if gap > 0 then
		task.wait(gap)
	end
	lastActionAt = os.clock()
	local ok, reply = pcall(Net.invokeServer, "JobAction", payload)
	if not ok then
		warn(`{LOG} JobAction {payload.action} failed: {reply}`)
		return nil
	end
	if type(reply) ~= "table" then
		return nil
	end
	return { ok = reply.ok == true, message = textOf(reply.message) }
end

-- Studio only: moves the car next to the job's current stop. The server's { ok, message }, or nil.
local function teleportToStop(): Reply?
	ensureNet()
	local ok, reply = pcall(Net.invokeServer, "DevJob", { action = "teleportToStop" })
	if not ok or type(reply) ~= "table" then
		return nil
	end
	return { ok = reply.ok == true, message = textOf(reply.message) }
end

local function describe(reply: Reply?): string
	if reply == nil then
		return "no answer"
	end
	return `{if reply.ok then "ok" else "refused"}: "{reply.message}"`
end

-- Asks for fresh offers and waits up to `timeout` seconds for the JobUpdate that brings them (and the active job).
-- JobService always answers with one during a job or when the offers change; with nothing new to show (no car,
-- same reasons) it sends none. True when one came.
local function refresh(ctx: Context, timeout: number): boolean
	local watch = ctx.watch
	local before = watch.updates
	jobAction({ action = "refresh" })
	return waitFor(ctx, function(): boolean
		return watch.updates > before
	end, watch.changed.Event, timeout)
end

---------------------------------------------------------------------------------------------------------------
-- Cars and eligibility
---------------------------------------------------------------------------------------------------------------

local function defOf(jobType: JobKind): Jobs.JobDef
	return Jobs.types[jobType]
end

local function classOf(vehicleId: string): string?
	local vehicle = Catalog.getVehicle(vehicleId)
	return if vehicle then vehicle.class else nil
end

local function canDo(jobType: JobKind, vehicleId: string): boolean
	local classId = classOf(vehicleId)
	return classId ~= nil and table.find(defOf(jobType).classes, classId) ~= nil
end

-- Whether a trim gets XL fares: an XL class, or an eligible class with at least xlMinSeats seats.
local function isXl(vehicleId: string, trimId: string): boolean
	local def = defOf("rideshare")
	local classId = classOf(vehicleId)
	local trim = Catalog.getTrim(vehicleId, trimId)
	if classId == nil or trim == nil or table.find(def.classes, classId) == nil then
		return false
	end
	if def.xlClasses ~= nil and table.find(def.xlClasses, classId) ~= nil then
		return true
	end
	return def.xlMinSeats ~= nil and trim.seats >= def.xlMinSeats
end

local function isBonusClass(vehicleId: string): boolean
	local def = defOf("delivery")
	local classId = classOf(vehicleId)
	return classId ~= nil and def.bonusClasses ~= nil and table.find(def.bonusClasses, classId) ~= nil
end

-- The §4 target $/min for `jobType` in this car, and which activity rate it is.
local function targetFor(jobType: JobKind, vehicleId: string, trimId: string): (number, string)
	local rates = Economy.activities
	if jobType == "rideshare" then
		if isXl(vehicleId, trimId) then
			return rates.rideshareXL, "rideshareXL"
		end
		return rates.rideshare, "rideshare"
	end
	if isBonusClass(vehicleId) then
		return rates.delivery * (1 + rates.deliveryVehicleBonus), "delivery + vehicle bonus"
	end
	return rates.delivery, "delivery"
end

-- The car a test should use: opts.vehicleId, else `car` (a vehicle id or a Config/Classes id: that class's first
-- drivable vehicle), else `fallback`; the trim is opts.trim or the vehicle's first.
local function chooseCar(opts: Options, car: string?, fallback: { vehicleId: string, trim: string }): (string?, string?)
	local vehicleId = opts.vehicleId or car
	if vehicleId ~= nil and Catalog.getVehicle(vehicleId) == nil and Classes[vehicleId] ~= nil then
		local classId = vehicleId
		vehicleId = nil
		for _, id in Catalog.vehicleIds() do
			local vehicle = Catalog.getVehicle(id)
			if vehicle and vehicle.class == classId and vehicle.playerDrivable then
				vehicleId = id
				break
			end
		end
		if vehicleId == nil then
			return nil, nil
		end
	end
	if vehicleId == nil then
		return fallback.vehicleId, opts.trim or fallback.trim
	end
	local defaultTrim = Catalog.defaultTrim(vehicleId)
	return vehicleId, opts.trim or (if defaultTrim then defaultTrim.id else nil)
end

-- Right-hand lane offset for the stretch a-b, from the lanes of the road under its middle (as Dev/RouteTests).
local function laneOffsetFor(a: Vector3, b: Vector3): number
	local edgeIndex = Graph.nearestEdge((a + b) / 2)
	local edge = if edgeIndex then Graph.edges()[edgeIndex] else nil
	return if edge then RouteTests.Math.rightLaneOffset(edge.lanes, World.laneWidth) else 0
end

-- Where the character stands so DevSpawnVehicle puts a car of this trim in the right-hand lane in the middle of
-- the open road nearest `near`, facing along it: the car spawns Spawning.spawnOffset + half its length in front of
-- the character. Returns the stand pose and the road's description.
local function openRoadStand(near: Vector3, vehicleId: string, trimId: string): (CFrame?, string)
	local geometry = Catalog.geometry(vehicleId, trimId)
	if geometry == nil then
		return nil, "no geometry for the car"
	end
	local edges = Graph.edges()
	local bestIndex: number? = nil
	local bestDistance = math.huge
	for index, edge in edges do
		if
			table.find(SETTINGS.startKinds, edge.kind) ~= nil
			and edge.surface ~= "dirt"
			and Graph.edgeLength(index) >= SETTINGS.minStartEdge
		then
			local distance = flatDistance(Graph.pointOnEdge(index, 0.5), near)
			if distance < bestDistance then
				bestIndex, bestDistance = index, distance
			end
		end
	end
	if bestIndex == nil then
		return nil, "no open road long enough"
	end
	local edge = edges[bestIndex]
	local from, to = Graph.node(edge.from), Graph.node(edge.to)
	if from == nil or to == nil then
		return nil, "the road's nodes are missing"
	end
	local along = flat(to.position - from.position)
	if along.Magnitude < EPSILON then
		return nil, "the road has no length"
	end
	local heading = along.Unit
	local right = Vector3.new(-heading.Z, 0, heading.X)
	local carCentre = Graph.pointOnEdge(bestIndex, 0.5)
		+ right * RouteTests.Math.rightLaneOffset(edge.lanes, World.laneWidth)
	local stand = carCentre
		- heading * (Spawning.spawnOffset + geometry.length / 2)
		+ Vector3.yAxis * SETTINGS.standHeight
	return CFrame.lookAt(stand, stand + heading), `{edge.kind} {edge.from} -> {edge.to}`
end

-- Sits the player in a fresh `vehicleId`/`trim` on the open road nearest `near`: gets out of any car, moves the
-- character there (with the map streamed in around it) and spawns the car with DevSpawnVehicle, which seats them.
-- Returns the car, or nil and why.
local function spawnOnRoad(ctx: Context, vehicleId: string, trim: string, near: Vector3): (Model?, string?)
	local humanoid = humanoidOf()
	local character = Players.LocalPlayer.Character
	if humanoid == nil or character == nil then
		return nil, "no character"
	end
	local stand, road = openRoadStand(near, vehicleId, trim)
	if stand == nil then
		return nil, road
	end
	setCurrent(ctx, `spawning {vehicleId}/{trim} on the {road}`)
	local seatSignal = humanoid:GetPropertyChangedSignal("SeatPart")
	if humanoid.SeatPart ~= nil then
		humanoid.Sit = false
		humanoid.Jump = true
		if
			not waitFor(ctx, function(): boolean
				return humanoid.SeatPart == nil
			end, seatSignal, SETTINGS.exitTimeout)
		then
			return nil, "couldn't get out of the car"
		end
		-- The server stands the character beside the car it left; move only after that.
		task.wait(SETTINGS.settleSeconds)
	end
	-- With streaming on, the road there may not be on this client yet.
	pcall(function()
		Players.LocalPlayer:RequestStreamAroundAsync(stand.Position, SETTINGS.streamTimeout)
	end)
	character:PivotTo(stand)
	task.wait(SETTINGS.settleSeconds)

	local previous = currentCar()
	ensureNet()
	Net.fireServer("DevSpawnVehicle", { vehicleId = vehicleId, trim = trim })
	local seated = waitFor(ctx, function(): boolean
		local car = currentCar()
		if car == nil or car == previous then
			return false
		end
		local id, trimId = carIdentity(car)
		return id == vehicleId and trimId == trim
	end, seatSignal, SETTINGS.spawnTimeout)
	if not seated then
		return nil, `{vehicleId}/{trim} didn't spawn with you in it (is its model in ServerStorage.VehicleModels?)`
	end
	-- The game's DriveController starts once the car has arrived on this client.
	task.wait(SETTINGS.settleSeconds)
	return currentCar(), nil
end

-- Cancels a job left over from before the test (it would fail anyway when the car changes) and waits out the
-- cooldown that starts. Learns the active job from a refresh (the server always answers one during a job).
local function clearActiveJob(ctx: Context)
	refresh(ctx, SETTINGS.stateTimeout)
	local job = ctx.watch.job
	if job == nil then
		return
	end
	note(ctx, `cancelling a job left over from before ({job.title})`)
	local reply = jobAction({ action = "cancel", jobId = job.id })
	local message = if reply then reply.message else ""
	local _, seconds = string.match(message, CANCELLED_PATTERN)
	local jobType = job.type :: JobKind
	local def = Jobs.types[jobType]
	local wait = tonumber(seconds) or (if def then def.cooldownSec else 0)
	setCurrent(ctx, `waiting out the {wait} s cooldown`)
	task.wait(wait + SETTINGS.cooldownSlack)
end

-- Gets the player into a car that can do `jobType`: the one they sit in (opts.keepCar, when it can), else a fresh
-- `vehicleId`/`trim` on an open road. Fills in the result's vehicle and class. Returns the vehicle and trim ids, or
-- nil and why.
local function prepareCar(
	ctx: Context,
	jobType: JobKind,
	vehicleId: string?,
	trimId: string?,
	opts: Options
): (string?, string?, string?)
	if vehicleId == nil or trimId == nil or Catalog.getTrim(vehicleId, trimId) == nil then
		return nil, nil, "no such car and trim in Config/Vehicles"
	end
	local vehicle = Catalog.getVehicle(vehicleId)
	if vehicle == nil or not vehicle.playerDrivable then
		return nil, nil, `{vehicleId} isn't a drivable car`
	end
	clearActiveJob(ctx)

	local current = currentCar()
	local currentId, currentTrim = nil, nil
	if current then
		currentId, currentTrim = carIdentity(current)
	end
	local id: string, trim: string = vehicleId, trimId
	if opts.keepCar and currentId ~= nil and currentTrim ~= nil and canDo(jobType, currentId) then
		id, trim = currentId, currentTrim
		note(ctx, `using the car you sit in ({id}/{trim})`)
	else
		local near: Vector3? = nil
		if opts.startAt then
			local location = locationsById[opts.startAt]
			if location == nil then
				return nil, nil, `no MapLayout location "{opts.startAt}"`
			end
			near = location.position
		else
			local pose = carPose()
			local character = Players.LocalPlayer.Character
			near = if pose then pose.Position elseif character then character:GetPivot().Position else nil
		end
		if near == nil then
			return nil, nil, "no character"
		end
		local car, why = spawnOnRoad(ctx, id, trim, near)
		if car == nil then
			return nil, nil, why
		end
	end
	ctx.result.vehicle = `{id}/{trim}`
	ctx.result.class = classOf(id)
	return id, trim, nil
end

---------------------------------------------------------------------------------------------------------------
-- Offers
---------------------------------------------------------------------------------------------------------------

-- The first offer of `jobType` in `offers`, as the phone lists them. Not the most profitable one: rate() has to
-- measure what a typical player earns (the server makes offers at random), not a player fishing for the best.
local function firstOffer(offers: { OfferView }?, jobType: JobKind): OfferView?
	if offers == nil then
		return nil
	end
	for _, offer in offers do
		if offer.type == jobType then
			return offer
		end
	end
	return nil
end

-- Refreshes the offers until one of `jobType` shows up (Config/Jobs offers.minRefreshSec apart). A cooldown the
-- server reports for the type is waited out (not counted as a try); any other reason it can't offer the type (no
-- car, wrong class) ends the search. Returns the offer, or nil and why, and when the last cooldown wait ended.
local function findOffer(ctx: Context, jobType: JobKind): (OfferView?, string?, number?)
	local watch = ctx.watch
	local cooledAt: number? = nil
	local tries = 0
	while tries < SETTINGS.offerTries do
		if cancelRequested(ctx) then
			return nil, "stopped", cooledAt
		end
		refresh(ctx, SETTINGS.updateTimeout)
		local offer = if watch.job == nil then firstOffer(watch.offers, jobType) else nil
		if offer then
			return offer, nil, cooledAt
		end
		local availability = watch.availability[jobType]
		if availability ~= nil and not availability.ok then
			local _, seconds = string.match(availability.reason, COOLDOWN_PATTERN)
			local cooldown = tonumber(seconds)
			if cooldown == nil then
				return nil, `the server offers no {jobType} jobs: "{availability.reason}"`, cooledAt
			end
			setCurrent(ctx, `{jobType} cooldown: waiting {cooldown} s`)
			task.wait(cooldown + SETTINGS.cooldownSlack)
			cooledAt = os.clock()
		else
			tries += 1
			task.wait(Jobs.offers.minRefreshSec)
		end
	end
	local active = if watch.job then ` (a job is active: "{watch.job.title}")` else ""
	return nil, `no {jobType} offer after {SETTINGS.offerTries} refreshes{active}`, cooledAt
end

-- An accepted job and what its measurement starts from.
type Accepted = {
	job: JobView?, -- nil: not accepted (see failure)
	offer: OfferView, -- the offer actually accepted
	acceptedAt: number, -- os.clock() just before the accept that worked
	cashBefore: number, -- Cash just before it
	cycleStart: number?, -- os.clock() a cooldown wait ended, when there was one (the cycle starts there)
	failure: string?,
}

-- Accepts `offer` and waits for the JobUpdate that shows the job. A cooldown refusal is waited out once, with a
-- fresh offer after it.
local function acceptOffer(ctx: Context, jobType: JobKind, offer: OfferView): Accepted
	local watch = ctx.watch
	local accepted: Accepted = { job = nil, offer = offer, acceptedAt = os.clock(), cashBefore = cash() }
	for attempt = 1, 2 do
		accepted.acceptedAt = os.clock()
		accepted.cashBefore = cash()
		local reply = jobAction({ action = "accept", offerId = accepted.offer.id })
		if reply and reply.ok then
			local shown = waitFor(ctx, function(): boolean
				return watch.job ~= nil
			end, watch.changed.Event, SETTINGS.updateTimeout)
			if shown then
				accepted.job = watch.job
			else
				accepted.failure = "accepted, but no JobUpdate showed the job"
			end
			return accepted
		end
		local _, seconds = string.match(if reply then reply.message else "", COOLDOWN_PATTERN)
		local cooldown = tonumber(seconds)
		if attempt > 1 or cooldown == nil then
			accepted.failure = `accept {describe(reply)}`
			return accepted
		end
		setCurrent(ctx, `cooldown: waiting {cooldown} s`)
		task.wait(cooldown + SETTINGS.cooldownSlack)
		accepted.cycleStart = os.clock()
		local fresh, why = findOffer(ctx, jobType)
		if fresh == nil then
			accepted.failure = why
			return accepted
		end
		accepted.offer = fresh
	end
	return accepted
end

---------------------------------------------------------------------------------------------------------------
-- Driving a job
---------------------------------------------------------------------------------------------------------------

local function failedReport(reason: string): AutoDriver.Report
	return { completed = false, elapsed = 0, stuckEvents = 0, maxMph = 0, reason = reason, pointsReached = 0 }
end

-- The point on a road centre line nearest `position`: arrival counts from there as well as from the stop.
local function roadPointNear(position: Vector3): Vector3
	local _, _, _, point = Graph.nearestEdge(position)
	return point
end

-- How far `position` is from a stop, counting the stop's road point as the stop (JobService's arrival rule).
local function distanceToStop(position: Vector3, stop: StopView): number
	return math.min(flatDistance(position, stop.position), flatDistance(position, roadPointNear(stop.position)))
end

-- Drives Pathfind's route to the road point nearest `stop` (right-hand lanes) and stops there; when even that is
-- out of reach of the stop, pulls in toward the stop until it isn't. Returns AutoDriver's report and the length.
local function driveToStop(stop: StopView, arriveRadius: number, mph: number): (AutoDriver.Report, number)
	local pose = carPose()
	if pose == nil then
		return failedReport("not driving"), 0
	end
	local reach = arriveRadius * SETTINGS.reachFraction
	if distanceToStop(pose.Position, stop) <= reach then
		return { completed = true, elapsed = 0, stuckEvents = 0, maxMph = 0, reason = "arrived", pointsReached = 0 }, 0
	end
	local route = Pathfind.route(pose.Position, stop.position, pose.LookVector)
	if route == nil then
		return failedReport("no route"), 0
	end
	local points = RouteTests.Math.keepRight(route.points, laneOffsetFor, SETTINGS.maxMiter)
	local last = points[#points] or pose.Position
	local gap = distanceToStop(last, stop)
	if gap > reach then
		local toward = flat(stop.position - last)
		if toward.Magnitude > EPSILON then
			table.insert(points, last + toward.Unit * math.min(gap - reach, toward.Magnitude))
		end
	end
	if #points == 0 then
		return failedReport("no route"), 0
	end
	local length = RouteTests.Math.length(pose.Position, points)
	local report = AutoDriver.drive(points, {
		targetMph = mph,
		timeout = RouteTests.Math.timeoutFor(length, mph),
		arriveRadius = SETTINGS.stopArriveRadius,
		stopAtEnd = true,
	})
	return report, length
end

-- True once the server has moved job `jobId` past stop `index` (or ended it).
local function movedOnFrom(watch: Watch, jobId: string, index: number): () -> boolean
	return function(): boolean
		local job = watch.job
		return job == nil or job.id ~= jobId or job.stopIndex ~= index
	end
end

-- Drives to the job's current stop and holds still there until the server moves the job on. A pickup or depot
-- leg is teleported instead when `teleport` is "always", and rescued with a teleport when the drive fails and
-- `teleport` is "rescue".
local function driveLeg(ctx: Context, job: JobView, mph: number, teleport: "always" | "rescue" | "never"): Leg
	local watch = ctx.watch
	local index = job.stopIndex
	local stop = job.stops[index]
	local leg: Leg = {
		index = index,
		kind = if stop then stop.kind else "?",
		label = if stop then stop.label else "?",
		routeStuds = 0,
		driveSeconds = 0,
		waitSeconds = 0,
		seconds = 0,
		maxMph = 0,
		stuckEvents = 0,
		askedArrive = false,
		teleported = false,
		reason = "advanced",
	}
	local started = os.clock()
	local movedOn = movedOnFrom(watch, job.id, index)
	if stop == nil then
		leg.reason = "the job has no such stop"
		return leg
	end
	local def = Jobs.types[job.type :: JobKind]
	local arriveRadius = if def then def.arriveRadius else 0
	local canTeleport = table.find(PICKUP_KINDS, stop.kind) ~= nil and teleport ~= "never"

	local reached = false
	if canTeleport and teleport == "always" then
		setCurrent(ctx, `teleporting to stop {index}: {stop.label} ({stop.kind})`)
		local reply = teleportToStop()
		leg.teleported = true
		reached = reply ~= nil and reply.ok
		if not reached then
			leg.reason = `teleportToStop {describe(reply)}`
		end
	else
		setCurrent(ctx, `driving to stop {index}: {stop.label} ({stop.kind})`)
		local report, length = driveToStop(stop, arriveRadius, mph)
		leg.routeStuds = round(length, 0)
		leg.driveSeconds = round(report.elapsed, 1)
		leg.maxMph = round(report.maxMph, 1)
		leg.stuckEvents = report.stuckEvents
		local pose = carPose()
		reached = pose ~= nil and distanceToStop(pose.Position, stop) <= arriveRadius
		if not reached then
			leg.reason = `didn't reach the stop ({report.reason})`
		end
	end
	if not reached and canTeleport and teleport == "rescue" and not cancelRequested(ctx) then
		note(ctx, `stop {index} ({stop.label}): {leg.reason}; rescuing with DevJob teleportToStop`)
		local reply = teleportToStop()
		leg.teleported = true
		reached = reply ~= nil and reply.ok
		leg.reason = if reached then "advanced" else `teleportToStop {describe(reply)}`
	end
	if not reached or cancelRequested(ctx) then
		leg.seconds = round(os.clock() - started, 1)
		if cancelRequested(ctx) then
			leg.reason = "stopped"
		end
		return leg
	end

	-- At the stop: hold still until the server's arrival check moves the job on.
	setCurrent(ctx, `at stop {index}: {stop.label}, waiting for the server`)
	local waitStarted = os.clock()
	local advanced = holdUntil(ctx, movedOn, SETTINGS.advanceTimeout)
	if not advanced and not cancelRequested(ctx) then
		-- What a player's "I'm here" does: ask the server to check now.
		leg.askedArrive = true
		local reply = jobAction({ action = "arrive", jobId = job.id })
		note(ctx, `stop {index} ({stop.label}) not taken after {SETTINGS.advanceTimeout} s; arrive {describe(reply)}`)
		advanced = holdUntil(ctx, movedOn, SETTINGS.arriveRetryTimeout)
	end
	local endedAt = if advanced then watch.changedAt else os.clock()
	leg.waitSeconds = round(math.max(endedAt - waitStarted, 0), 1)
	leg.seconds = round(endedAt - started, 1)
	if not advanced then
		local pose = carPose()
		local away = if pose then round(distanceToStop(pose.Position, stop), 0) else -1
		leg.reason = if cancelRequested(ctx)
			then "stopped"
			else `the server didn't move on ({away} studs from the stop, arriveRadius {arriveRadius})`
	end
	return leg
end

local function newRun(jobType: JobKind, offer: OfferView, stops: number): JobRun
	return {
		type = jobType,
		title = offer.title,
		offerPay = round(offer.pay, 0),
		offerDistance = round(offer.distance, 0),
		xl = offer.xl,
		stops = stops,
		completed = false,
		pay = 0,
		tip = nil,
		driveEarnPaid = 0,
		seconds = 0,
		cycleSeconds = 0,
		perMinute = 0,
		routeStuds = 0,
		xpGained = 0,
		legs = {},
		reason = "",
	}
end

-- How rate() chains jobs: each cycle starts where the previous job ended (os.clock()), so the wait for its pay and
-- the refresh count, and the car holds still until `betweenSeconds` after that before looking at offers (the
-- reading and choosing time Config/Jobs.calibration pays for).
type Chain = { from: number, betweenSeconds: number }

-- Finds, accepts and drives one job of `jobType` from start to pay. `teleport` as in driveLeg. Returns the run
-- (nil when no job could be started, with why) and os.clock() when it ended (the next cycle's start).
local function runJob(
	ctx: Context,
	jobType: JobKind,
	mph: number,
	teleport: "always" | "rescue" | "never",
	chain: Chain?
): (JobRun?, string?, number)
	local watch = ctx.watch
	local cycleStarted = if chain then chain.from else os.clock()
	if chain then
		local idle = chain.betweenSeconds - (os.clock() - chain.from)
		if idle > 0 and not cancelRequested(ctx) then
			setCurrent(ctx, `between jobs: holding still {round(idle, 1)} s`)
			AutoDriver.holdStill(idle)
		end
	end
	setCurrent(ctx, `looking for a {jobType} offer`)
	local offer, why, cooledAt = findOffer(ctx, jobType)
	if offer == nil then
		return nil, why, os.clock()
	end
	setCurrent(ctx, `accepting "{offer.title}" (est. ${round(offer.pay, 0)}, {round(offer.distance, 0)} studs)`)
	local progress = watch.progress[jobType]
	local xpBefore = if progress then progress.xp else nil
	local accepted = acceptOffer(ctx, jobType, offer)
	local job = accepted.job
	if job == nil then
		return nil, accepted.failure, os.clock()
	end
	local run = newRun(jobType, accepted.offer, #job.stops)
	run.level = if progress then progress.level else nil
	run.levelMultiplier = if progress then progress.multiplier else nil
	if job.deadline ~= nil and job.startedAt ~= nil then
		run.timeAllowed = round(job.deadline - job.startedAt, 1)
	end
	local acceptedAt, cashBefore = accepted.acceptedAt, accepted.cashBefore
	-- Cooldown waits (in findOffer or acceptOffer) aren't part of the cycle.
	cycleStarted = accepted.cycleStart or cooledAt or cycleStarted

	-- Every stop in turn, until the job ends (paid or failed) or a leg fails.
	while not cancelRequested(ctx) do
		local active = watch.job
		if active == nil or active.id ~= job.id then
			break
		end
		local leg = driveLeg(ctx, active, mph, teleport)
		table.insert(run.legs, leg)
		run.routeStuds += leg.routeStuds
		if leg.reason ~= "advanced" then
			break
		end
	end

	local active = watch.job
	if active ~= nil and active.id == job.id then
		-- A leg failed (or the test was stopped): give the job up so the next one can start. The time up to here
		-- counts; the cooldown after it doesn't (it is the test driver's failure, not a player's choice).
		run.seconds = round(os.clock() - acceptedAt, 1)
		run.cycleSeconds = round(os.clock() - cycleStarted, 1)
		local reply = jobAction({ action = "cancel", jobId = job.id })
		local last = run.legs[#run.legs]
		run.reason = if last then last.reason else "stopped"
		note(ctx, `cancelled "{run.title}" ({run.reason}); cancel {describe(reply)}`)
		local _, seconds = string.match(if reply then reply.message else "", CANCELLED_PATTERN)
		local wait = tonumber(seconds) or Jobs.types[jobType].cooldownSec
		if not cancelRequested(ctx) then
			setCurrent(ctx, `waiting out the {wait} s cooldown`)
			task.wait(wait + SETTINGS.cooldownSlack)
		end
		return run, nil, os.clock()
	end

	-- The job ended: wait for its pay to reach the Cash attribute and its XP the next JobUpdate (JobService pays,
	-- then adds XP), or for a failure notice.
	local endedAt = watch.endedAt[job.id] or os.clock()
	if job.deadline ~= nil then
		local serverEnded = Workspace:GetServerTimeNow() - (os.clock() - endedAt)
		run.timeLeft = round(job.deadline - serverEnded, 1)
	end
	local function xpNow(): number?
		local entry = watch.progress[jobType]
		return if entry then entry.xp else nil
	end
	waitFor(ctx, function(): boolean
		local failed = noticeSince(watch, acceptedAt, FAILED_PATTERN)
		local paid = cash() - driveEarnSince(watch, acceptedAt) > cashBefore
		local xp = xpNow()
		local xpIn = xpBefore == nil or (xp ~= nil and xp > xpBefore)
		return failed ~= nil or (paid and xpIn)
	end, watch.changed.Event, SETTINGS.cashSettleSeconds)
	local xpAfter = xpNow()
	run.xpGained = if xpBefore ~= nil and xpAfter ~= nil then xpAfter - xpBefore else 0
	local driveEarnDuring = 0
	for _, decision in watch.driveEarn do
		if decision.at >= acceptedAt and decision.at <= endedAt then
			driveEarnDuring += decision.amount
		end
	end
	run.driveEarnPaid = driveEarnDuring
	run.pay = cash() - cashBefore - driveEarnSince(watch, acceptedAt)
	run.seconds = round(endedAt - acceptedAt, 1)
	run.cycleSeconds = round(endedAt - cycleStarted, 1)
	run.perMinute = if run.seconds > EPSILON then round(run.pay * SECONDS_PER_MINUTE / run.seconds, 0) else 0
	run.completed = run.pay > 0
	local _, tipCaptures = noticeSince(watch, acceptedAt, COMPLETED_TIP_PATTERN)
	run.tip = if tipCaptures[2] then dollars(tipCaptures[2]) else nil
	if run.completed then
		run.reason = "completed"
	else
		local failed = noticeSince(watch, acceptedAt, FAILED_PATTERN)
		local last = lastNoticeSince(watch, acceptedAt)
		run.reason = failed or (if last then `ended without pay (last notice: "{last}")` else "ended without pay")
	end
	local levelUp = noticeSince(watch, acceptedAt, LEVEL_UP_PATTERN)
	if levelUp then
		note(ctx, `level up: "{levelUp}" (later jobs pay more)`)
	end
	print(
		`{LOG} {ctx.name}: "{run.title}" {run.reason}: ${run.pay} in {run.seconds} s ({run.perMinute}/min), `
			.. `{#run.legs} stop(s), {run.routeStuds} studs driven, est. ${run.offerPay}, +{run.xpGained} XP`
	)
	return run, nil, endedAt
end

local function legsDetail(run: JobRun): string
	local parts: { string } = {}
	for _, leg in run.legs do
		table.insert(
			parts,
			`{leg.kind} {leg.label}: {leg.routeStuds} studs, drive {leg.driveSeconds} s + wait {leg.waitSeconds} s`
				.. (if leg.teleported then " (teleported)" else "")
		)
	end
	return table.concat(parts, "; ")
end

---------------------------------------------------------------------------------------------------------------
-- Tests
---------------------------------------------------------------------------------------------------------------

-- rideshare() and delivery(): one job of `jobType`, end to end.
local function oneJobTest(ctx: Context, jobType: JobKind, vehicleId: string?, trimId: string?, opts: Options): Result
	local result = ctx.result
	local id, trim, why = prepareCar(ctx, jobType, vehicleId, trimId, opts)
	if id == nil or trim == nil then
		result.reason = why or "no car"
		return result
	end
	check(ctx, "car can do the job", canDo(jobType, id), `{id} is class {result.class}`)
	if not canDo(jobType, id) then
		result.reason = `{id} can't do {jobType} jobs`
		return result
	end
	local run, failure = runJob(ctx, jobType, opts.mph or SETTINGS.cruiseMph, "never")
	if run == nil then
		check(ctx, "accepted an offer", false, failure or "no job")
		result.reason = failure or "no job"
		return result
	end
	result.job = run
	check(ctx, "accepted an offer", true, `"{run.title}", est. ${run.offerPay} over {run.offerDistance} studs`)
	local advanced = 0
	for _, leg in run.legs do
		if leg.reason == "advanced" then
			advanced += 1
		end
	end
	check(ctx, "every stop taken", advanced == run.stops and #run.legs == run.stops, legsDetail(run))
	check(ctx, "paid", run.completed, `${run.pay} in {run.seconds} s = ${run.perMinute}/min ({run.reason})`)
	check(
		ctx,
		"no drive-to-earn during the job",
		run.driveEarnPaid == 0,
		`drive-to-earn paid ${run.driveEarnPaid} while the job ran`
	)
	local target, name = targetFor(jobType, id, trim)
	note(ctx, `{name} target ${round(target, 0)}/min; this job ${run.perMinute}/min (rate() measures the average)`)
	result.reason = if run.completed then "done" else run.reason
	return result
end

-- Studs the car must be from a stop for an arrive there to count as forged (JobService's own rule, plus margin).
local function forgedDistance(jobType: string): number
	local def = Jobs.types[jobType :: JobKind]
	return if def then Jobs.forgedArriveFactor * def.arriveRadius + SETTINGS.forgedMargin else math.huge
end

-- Sends a forged arrive for the job's current stop from where the car is, and checks it is refused: the reply
-- says no, the job stays at that stop and nothing is paid. `what` names the stop in the checks. Returns false
-- (with a note) when the car is too near the stop for the arrive to be a forgery.
local function forgeArrive(ctx: Context, job: JobView, what: string): boolean
	local watch = ctx.watch
	local index = job.stopIndex
	local stop = job.stops[index]
	local pose = carPose()
	if stop == nil or pose == nil then
		note(ctx, `{what}: {if stop == nil then "no stop" else "not driving"}, so no forged arrive`)
		return false
	end
	local farEnough = round(forgedDistance(job.type), 0)
	local away = round(distanceToStop(pose.Position, stop), 0)
	if away < farEnough then
		note(ctx, `{what}: only {away} studs from {stop.label} (a forgery needs {farEnough}), so not forged`)
		return false
	end
	local cashBefore = cash()
	local since = os.clock()
	local before = watch.updates
	local reply = jobAction({ action = "arrive", jobId = job.id })
	check(
		ctx,
		`{what}: forged arrive refused`,
		reply ~= nil and not reply.ok,
		`{away} studs from {stop.label}: {describe(reply)}`
	)
	-- Watch a moment for anything that moves the job on or pays (the server answers before it would).
	local moved = movedOnFrom(watch, job.id, index)
	waitFor(ctx, moved, watch.changed.Event, SETTINGS.forgedWatchSeconds)
	local updates = watch.updates - before
	check(
		ctx,
		`{what}: job didn't move on`,
		not moved(),
		if moved()
			then `the job moved past stop {index} (now {if watch.job then watch.job.stopIndex else "ended"})`
			else `still at stop {index} ({updates} JobUpdate(s) since)`
	)
	local gained = cash() - cashBefore - driveEarnSince(watch, since)
	check(ctx, `{what}: nothing paid`, gained <= 0, `cash changed by ${gained}`)
	return true
end

local function forgedTest(ctx: Context, opts: Options): Result
	local result = ctx.result
	local jobType: JobKind = opts.type or "rideshare"
	if Jobs.types[jobType] == nil then
		result.reason = `unknown job type "{jobType}"`
		return result
	end
	local fallback = if jobType == "rideshare" then SETTINGS.rideshareCar else SETTINGS.deliveryCar
	local vehicleId, trimId = chooseCar(opts, nil, fallback)
	local id, _, why = prepareCar(ctx, jobType, vehicleId, trimId, opts)
	if id == nil then
		result.reason = why or "no car"
		return result
	end
	local mph = opts.mph or SETTINGS.cruiseMph
	local offer, failure = findOffer(ctx, jobType)
	if offer == nil then
		result.reason = failure or "no offer"
		return result
	end
	local accepted = acceptOffer(ctx, jobType, offer)
	local job = accepted.job
	if job == nil then
		check(ctx, "accepted an offer", false, accepted.failure or "no job")
		result.reason = accepted.failure or "no job"
		return result
	end
	check(ctx, "accepted an offer", true, `"{accepted.offer.title}"`)
	local run = newRun(jobType, accepted.offer, #job.stops)
	result.job = run
	local watch = ctx.watch
	local forged = 0

	-- 1. The first stop, from where the car is (when that is far enough away for a forgery).
	if job.stopIndex < #job.stops then
		AutoDriver.holdStill(SETTINGS.holdSeconds)
		local first = job.stops[job.stopIndex]
		if forgeArrive(ctx, job, `stop {job.stopIndex} ({if first then first.kind else "?"})`) then
			forged += 1
		end
	end

	-- 2. Drive every stop but the last for real, then forge the last one: completing the job from far away.
	while not cancelRequested(ctx) do
		local active = watch.job
		if active == nil or active.id ~= job.id then
			break
		end
		if active.stopIndex >= #active.stops then
			AutoDriver.holdStill(SETTINGS.holdSeconds)
			local last = active.stops[active.stopIndex]
			if forgeArrive(ctx, active, `last stop ({if last then last.kind else "?"})`) then
				forged += 1
			end
			break
		end
		local leg = driveLeg(ctx, active, mph, "rescue")
		table.insert(run.legs, leg)
		if leg.reason ~= "advanced" then
			check(ctx, "drove to the stops before the last", false, leg.reason)
			break
		end
	end

	check(ctx, "forged at least one arrive far from its stop", forged > 0, `{forged} forged arrive(s) sent`)

	-- 3. Arrive for a job that isn't the player's.
	local fake = HttpService:GenerateGUID(false)
	local reply = jobAction({ action = "arrive", jobId = fake })
	check(ctx, "arrive for someone else's job refused", reply ~= nil and not reply.ok, describe(reply))

	-- Clean up: give the job up (its cooldown starts now).
	local active = watch.job
	if active ~= nil and active.id == job.id then
		local cancelReply = jobAction({ action = "cancel", jobId = job.id })
		check(ctx, "job cancelled afterwards", cancelReply ~= nil and cancelReply.ok, describe(cancelReply))
		run.reason = "cancelled"
	else
		run.reason = "ended before the cleanup"
		note(ctx, "the job had already ended before it was cancelled")
	end
	result.reason = "done"
	return result
end

local function rateTest(ctx: Context, jobType: JobKind, minutes: number, opts: Options): Result
	local result = ctx.result
	local fallback = if jobType == "rideshare" then SETTINGS.rideshareCar else SETTINGS.deliveryCar
	local vehicleId, trimId = chooseCar(opts, nil, fallback)
	local id, trim, why = prepareCar(ctx, jobType, vehicleId, trimId, opts)
	if id == nil or trim == nil then
		result.reason = why or "no car"
		return result
	end
	if not canDo(jobType, id) then
		check(ctx, "car can do the job", false, `{id} is class {result.class}`)
		result.reason = `{id} can't do {jobType} jobs`
		return result
	end
	local target, targetName = targetFor(jobType, id, trim)
	result.target = round(target, 0)
	result.targetName = targetName
	local teleport: "always" | "rescue" = if opts.teleportPickup then "always" else "rescue"
	local mph = opts.mph or SETTINGS.cruiseMph
	local runs: { JobRun } = {}
	result.jobs = runs
	local counted, earned, failures, inARow = 0, 0, 0, 0
	-- Pay as a level-1 mid-skill player would have earned it: Config/Jobs calibrates the §4 rates at level 1 with
	-- the calibration's average tip (Jobs.calibration.averageTipShare of the fare). A level's multiplier scales the
	-- fare but not the tip, and the AutoDriver's gentle braking always keeps the whole tip, so the fare is taken
	-- back to level 1 and the tip it actually got is swapped for the average one.
	local earnedAtLevel1 = 0
	local averageTip = if jobType == "rideshare" then Jobs.calibration.averageTipShare else 0
	local budget = minutes * SECONDS_PER_MINUTE
	-- Every cycle starts where the last job ended and holds still for the calibration's time between jobs.
	local chain: Chain = { from = os.clock(), betweenSeconds = Jobs.calibration.betweenSeconds }

	while counted < budget and not cancelRequested(ctx) do
		setCurrent(ctx, `job {#runs + 1}: {round(counted / SECONDS_PER_MINUTE, 1)} of {minutes} min, ${earned} so far`)
		local run, failure, endedAt = runJob(ctx, jobType, mph, teleport, chain)
		chain = { from = endedAt, betweenSeconds = Jobs.calibration.betweenSeconds }
		if run == nil then
			note(ctx, `couldn't start a job: {failure or "?"}`)
			break
		end
		table.insert(runs, run)
		counted += run.cycleSeconds
		earned += run.pay
		local tip = run.tip or 0
		local fareAtLevel1 = (run.pay - tip) / math.max(run.levelMultiplier or 1, EPSILON)
		earnedAtLevel1 += fareAtLevel1 * (1 + averageTip)
		if run.completed then
			inARow = 0
		else
			failures += 1
			inARow += 1
			if inARow >= SETTINGS.maxFailuresInARow then
				note(ctx, `{inARow} jobs failed in a row: stopping`)
				break
			end
		end
	end

	local perMinute = if counted > EPSILON then earned * SECONDS_PER_MINUTE / counted else 0
	local atLevel1 = if counted > EPSILON then earnedAtLevel1 * SECONDS_PER_MINUTE / counted else 0
	result.minutes = round(counted / SECONDS_PER_MINUTE, 2)
	result.earned = earned
	result.perMinute = round(perMinute, 0)
	result.perMinuteAtLevel1 = round(atLevel1, 0)
	result.ratio = round(atLevel1 / target, 3)
	result.failedJobs = failures
	local startMultiplier = if #runs > 0 then runs[1].levelMultiplier or 1 else 1
	local endMultiplier = if #runs > 0 then runs[#runs].levelMultiplier or 1 else 1
	if startMultiplier ~= 1 or endMultiplier ~= 1 then
		note(ctx, `job level pay x{startMultiplier} at the start, x{endMultiplier} at the end: compared at level 1`)
	end
	local teleported = 0
	for _, run in runs do
		for _, leg in run.legs do
			if leg.teleported then
				teleported += 1
			end
		end
	end
	if teleported > 0 then
		note(ctx, `{teleported} leg(s) teleported (pickup or depot legs only), which shortens the time counted`)
	end
	check(ctx, "jobs completed", #runs > 0 and failures < #runs, `{#runs - failures} of {#runs} paid`)
	check(ctx, "covered the time asked", counted >= budget, `{result.minutes} of {minutes} min`)
	check(
		ctx,
		"rate in the §4 band",
		#runs > 0 and math.abs(atLevel1 / target - 1) <= SETTINGS.rateTolerance,
		`${result.perMinuteAtLevel1}/min at level 1 (${result.perMinute}/min paid) vs {targetName} `
			.. `${result.target}/min (x{result.ratio}, ±{SETTINGS.rateTolerance * 100} % passes)`
	)
	result.reason = if cancelRequested(ctx) then "stopped" else "done"
	return result
end

---------------------------------------------------------------------------------------------------------------
-- Running a test
---------------------------------------------------------------------------------------------------------------

local function emptyResult(name: string, reason: string): Result
	return { name = name, passed = false, reason = reason, checks = {}, elapsed = 0, notes = {}, notices = {} }
end

local function printResult(result: Result)
	local verdict = if result.passed then "PASSED" else "FAILED"
	print(`{LOG} {result.name}: {verdict} ({result.reason}) in {math.floor(result.elapsed)} s`)
	local ok, encoded = pcall(HttpService.JSONEncode, HttpService, result)
	if ok then
		print(`{LOG} {result.name}: {encoded}`)
	end
end

local function runTest(name: TestName, body: (ctx: Context) -> Result): Result
	if not (RunService:IsStudio() and RunService:IsRunning()) then
		warn(`{LOG} runs only in a Studio playtest (Client datamodel)`)
		return emptyResult(name, "studio only")
	end
	if script:GetAttribute(STATUS) == "running" then
		warn(`{LOG} a test is already running; JobTests.stop() cancels it`)
		return emptyResult(name, "busy")
	end
	if humanoidOf() == nil then
		warn(`{LOG} wait for your character to spawn (and run this in the Client datamodel)`)
		return emptyResult(name, "no character")
	end

	local ctx: Context = {
		id = HttpService:GenerateGUID(false),
		name = name,
		started = os.clock(),
		result = emptyResult(name, "done"),
		watch = newWatch(),
	}
	script:SetAttribute(RUN_ID, ctx.id)
	script:SetAttribute(STATUS, "running")
	script:SetAttribute(CANCEL, false)
	script:SetAttribute(RESULT, nil)

	local ok, outcome = pcall(body, ctx)
	local result: Result = if ok then outcome else ctx.result
	if not ok then
		result.reason = `error: {tostring(outcome)}`
		warn(`{LOG} {name} failed: {outcome}`)
	end

	-- Hand the controls back and leave the car stopped.
	AutoDriver.stop()
	if currentCar() ~= nil and not cancelRequested(ctx) then
		AutoDriver.holdStill(SETTINGS.holdSeconds)
	end
	for index, notice in ctx.watch.notices do
		if index > SETTINGS.maxNotices then
			break
		end
		table.insert(result.notices, notice.text)
	end
	closeWatch(ctx.watch)
	if cancelRequested(ctx) and result.reason == "done" then
		result.reason = "stopped"
	end
	result.passed = ok and result.reason == "done" and #result.checks > 0
	for _, item in result.checks do
		if not item.passed then
			result.passed = false
		end
	end
	result.elapsed = round(os.clock() - ctx.started, 1)
	printResult(result)

	if script:GetAttribute(RUN_ID) == ctx.id then
		local status = if result.reason == "stopped" then "stopped" elseif result.passed then "done" else "failed"
		script:SetAttribute(RESULT, HttpService:JSONEncode(result))
		script:SetAttribute(CURRENT, nil)
		script:SetAttribute(STATUS, status)
	end
	return result
end

local JobTests = {}
JobTests.SETTINGS = SETTINGS

-- One rideshare fare end to end in an eligible sedan (opts.vehicleId / opts.trim for another car).
function JobTests.rideshare(opts: Options?): Result
	local options: Options = opts or {}
	local vehicleId, trimId = chooseCar(options, nil, SETTINGS.rideshareCar)
	return runTest("rideshare", function(ctx: Context): Result
		return oneJobTest(ctx, "rideshare", vehicleId, trimId, options)
	end)
end

-- One delivery route end to end. `car`: a vehicle id or a Config/Classes id (default a Northline van).
function JobTests.delivery(car: string?, opts: Options?): Result
	local options: Options = opts or {}
	local vehicleId, trimId = chooseCar(options, car, SETTINGS.deliveryCar)
	return runTest("delivery", function(ctx: Context): Result
		if vehicleId == nil then
			ctx.result.reason = `no drivable vehicle or class "{car}"`
			return ctx.result
		end
		return oneJobTest(ctx, "delivery", vehicleId, trimId, options)
	end)
end

-- Forged arrivals far from the stop are refused (PLAN.md Phase 6 acceptance).
function JobTests.forgedComplete(opts: Options?): Result
	local options: Options = opts or {}
	return runTest("forgedComplete", function(ctx: Context): Result
		return forgedTest(ctx, options)
	end)
end

-- Jobs of `jobType` back to back for `minutes`; the average $/min against PLAN.md §4.
function JobTests.rate(jobType: JobKind, minutes: number, opts: Options?): Result
	local options: Options = opts or {}
	if Jobs.types[jobType] == nil or type(minutes) ~= "number" or minutes <= 0 then
		warn(`{LOG} rate(type, minutes) needs "rideshare" or "delivery" and a positive number of minutes`)
		return emptyResult("rate", "bad arguments")
	end
	return runTest("rate", function(ctx: Context): Result
		return rateTest(ctx, jobType, minutes, options)
	end)
end

local STARTERS: { [string]: (...any) -> Result } = {
	rideshare = JobTests.rideshare,
	delivery = JobTests.delivery,
	forgedComplete = JobTests.forgedComplete,
	rate = JobTests.rate,
}

-- Starts a test in the background and returns at once: start("rideshare"), start("delivery", "northline_satchel"),
-- start("forgedComplete"), start("rate", "delivery", 10). Poll lastResult() or watch the console.
function JobTests.start(name: TestName, ...: any)
	local starter = STARTERS[name]
	if starter == nil then
		warn(`{LOG} unknown test "{name}"; use "rideshare", "delivery", "forgedComplete" or "rate"`)
		return
	end
	task.spawn(starter, ...)
end

-- The last finished result, or nil while a test runs (or before any has finished).
function JobTests.lastResult(): Result?
	local encoded = script:GetAttribute(RESULT)
	if script:GetAttribute(STATUS) == "running" or type(encoded) ~= "string" then
		return nil
	end
	return HttpService:JSONDecode(encoded)
end

-- "idle", "running", "done", "stopped" or "failed", and what the running test is doing.
function JobTests.status(): (string, string?)
	local status = script:GetAttribute(STATUS)
	local current = script:GetAttribute(CURRENT)
	return if type(status) == "string" then status else "idle", if type(current) == "string" then current else nil
end

-- Cancels a running test and hands the controls back; clears a "running" status left by a test whose thread died.
-- A job the test had accepted is cancelled by the test as it stops.
function JobTests.stop()
	if not RunService:IsStudio() then
		return
	end
	script:SetAttribute(CANCEL, true)
	AutoDriver.stop()
	if script:GetAttribute(STATUS) == "running" then
		script:SetAttribute(STATUS, "stopped")
	end
end

return JobTests
