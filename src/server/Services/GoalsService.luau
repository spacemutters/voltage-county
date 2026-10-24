--!strict
-- Goals (roast fixes 2026-10-24, docs/roast-2026-10-24.md point 8 "The first five minutes have no hook"): the
-- first-session path a new player is walked through, and three daily goals, all paid in cash (Config/Goals).
--
--   path      new players only (PlayerData.goals.path, schema 8; a save from before it, with a car, starts with the
--             path done): a first rideshare fare, a test drive of the Ohm Arc, then designing their free car. A step
--             is finished by the first server event of its counter, in any order, and pays its reward at once: one
--             DataService.update finishes it, pays and marks it paid, so it can never pay twice. The card then shows
--             the next step. Once every step is paid, or the player skips (Net ClaimGoal { goalId = Config/Goals
--             path.skipId }), the path is done for good.
--   daily     three goals a day, one from each Config/Goals daily slot, the same three for everyone on a goals day
--             (dayOf: UTC days that start at daily.resetHourUtc; each slot steps on to its next goal every day,
--             dailyFor). Progress counts from server events only and never passes a goal's target; a goal at its
--             target is collected with Net ClaimGoal { goalId }, once. The day rolls over lazily (every event, claim
--             and join looks at it) and for everyone online at the reset (one timer, not a poll).
--   events    hooks in the services that decide them, so nothing a client says ever counts:
--               job        JobService.onCompleted (player, job type): a completed job, not a failed one
--               testDrive  DealershipService.onTestDriveStarted (player, vehicle id)
--               design     DesignerService.onDesignBuilt (player): a new design saved to the garage
--               house      HouseService.onClaimed (player, plot id)
--               earn       EconomyService.onEarned with a reason in Config/Goals daily.earnReasons (or a prefix):
--                          driving, jobs, the fleet; never a goal's own reward (paid without onEarned), a code, a
--                          purchase, a sale or a refund
--               charge     a player's car's Charging attribute (Config/Goals chargingAttribute) turning true:
--                          Services/EnergyService sets it once a charge or fuel stop really starts
--               meet       a player's car standing still (Config/Energy attributes.still) or parked (its chassis
--                          anchored) with its pivot inside a MeetSpot (MeetService.spotAt, Config/Social margin)
--               miles      one Heartbeat accumulator (Config/Goals daily.sampleSeconds), connected only while someone
--                          online has an unfinished miles goal today: how far their car's chassis moved across the
--                          ground with them in its Driver seat. Test drives, server moves (AntiExploitService
--                          .lastServerMove) and steps faster than daily.maxMph don't count. Saved at most every
--                          daily.milesCommitSeconds, at once when it reaches a goal, and when the player leaves.
--             An event that can't move anything (the goal is done, or not on today's list) writes nothing.
--   publish   Net GoalsUpdate (coalesced to one per frame) after every change and on join: { path = { steps =
--             { { id, finished, claimed } }, current = id? } | nil once done, daily = { day, resetsAt, goals =
--             { { id, progress, claimed } } } }; resetsAt is Unix seconds. The client reads every word, target and
--             reward from Config/Goals by id.
--   ClaimGoal { goalId } (declared in Net, which has checked its shape and rate-limited it) answers { ok, message,
--             reward? }: a daily goal at its target and not yet collected, or a finished path step not yet paid
--             (they pay by themselves, so this only matters if a payment was ever missed), or the skip id.
--             Rewards go into the wallet inside the same update that marks them collected (EconomyService.applyAdd,
--             logged with recordChange under Config/Goals economyReason).
--
-- Studio only: GoalsService.devRestart(player) starts the player's path again with fresh daily goals, for trying the
-- first session on a save that already has it done (rejoin, in Studio Stop and Play again, to see the first spawn).
--
-- The rules are pure helpers that take the time as an argument (dayOf, nextResetAt, dailyFor, roll, wants, record,
-- claimIn, skip, currentStep, milesLeft, payload, earnCounts) for tests/Goals.spec in Edit mode.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage.Shared
local Economy = require(Shared.Config.Economy)
local EnergyConfig = require(Shared.Config.Energy)
local Garage = require(Shared.Config.Garage)
local Goals = require(Shared.Config.Goals)
local MapLayout = require(Shared.Config.MapLayout)
local Net = require(Shared.Net)
local Social = require(Shared.Config.Social)
local Spawning = require(Shared.Config.Spawning)
local Types = require(Shared.Types)
local Units = require(Shared.Util.Units)
local AntiExploitService = require(script.Parent.AntiExploitService)
local EconomyService = require(script.Parent.EconomyService)
local MeetService = require(script.Parent.MeetService)
local Template = require(script.Parent.DataService.Template)
local VehicleService = require(script.Parent.VehicleService)

-- DataService is required in Init rather than here: it loads ProfileStore, which talks to DataStores straight away,
-- and tests/Goals.spec requires this module in Edit mode for its pure rules.
type DataServiceModule = typeof(require(script.Parent.DataService))

type Goal = Goals.Goal
type GoalsData = Types.GoalsData

-- What an event carries besides its counter: the job type, the car.
export type Detail = { jobType: string?, vehicleId: string? }

-- What one event did: the path steps it finished and the daily goals it brought to their target.
export type Effects = { finished: { string }, ready: { string } }

-- Why a claim was refused.
export type Refusal = "done" | "unknown" | "claimed" | "notFinished" | "expired"

export type StepState = { id: string, finished: boolean, claimed: boolean }
export type DailyState = { id: string, progress: number, claimed: boolean }

-- The Net GoalsUpdate payload.
export type Payload = {
	path: { steps: { StepState }, current: string? }?, -- nil once the path is done
	daily: { day: number, resetsAt: number, goals: { DailyState } },
}

export type Reply = { ok: boolean, message: string, reward: number? }

-- One player's miles while they have an unfinished miles goal today.
type Tracker = {
	car: Model?,
	position: Vector3?,
	at: number, -- os.clock() of the last sample
	pending: number, -- studs driven and not counted yet
	committedAt: number, -- os.clock() of the last count
}

local LOG = "[GoalsService]"
local DAY_SECONDS = 86400
local HOUR_SECONDS = 3600
local METERS_PER_MILE = 1609.344
local OWNER_ATTRIBUTE = "OwnerUserId" -- VehicleService marks every player car with its owner
local SEATS_FOLDER = "Seats" -- vehicle model contract
local DRIVER_SEAT = "Driver"
local MEET_TAG = "MeetSpot" -- Config/MapLayout location tag
local STILL_ATTRIBUTE = EnergyConfig.attributes.still

local text = Goals.text
local daily = Goals.daily
local pathGoals = Goals.path.goals

local GoalsService = {}

local DataService: DataServiceModule? = nil

local pushQueued: { [Player]: boolean } = {}
local trackers: { [Player]: Tracker } = {}
local gone: { [Player]: boolean } = setmetatable({}, { __mode = "k" }) :: any -- left the game: never tracked again
-- Warned once about a claim for a goal that isn't theirs (any client can send 2 a second: no log flood).
local warnedUnknown: { [Player]: boolean } = setmetatable({}, { __mode = "k" }) :: any
local sampler: RBXScriptConnection? = nil
local sinceSample = 0

-- Every goal by id.
local pathById: { [string]: Goal } = {}
for _, goal in pathGoals do
	pathById[goal.id] = goal
end
local dailyById: { [string]: Goal } = {}
for _, slot in daily.slots do
	for _, goal in slot do
		dailyById[goal.id] = goal
	end
end

local meetSpots: { MapLayout.Location } = {}
for _, location in MapLayout.locations do
	if location.tag == MEET_TAG then
		table.insert(meetSpots, location)
	end
end

-- Pure rules ----------------------------------------------------------------------------------------------------

local function isFinite(value: any): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

-- A saved progress value as a usable number (0 when it isn't one).
local function cleanProgress(value: any): number
	if not isFinite(value) or value < 0 then
		return 0
	end
	return value
end

-- The goals day of `now` (os.time() seconds): whole days since the epoch, each starting at daily.resetHourUtc.
function GoalsService.dayOf(now: number): number
	return (now - daily.resetHourUtc * HOUR_SECONDS) // DAY_SECONDS
end

-- When the goals day after the one holding `now` starts (Unix seconds).
function GoalsService.nextResetAt(now: number): number
	return (GoalsService.dayOf(now) + 1) * DAY_SECONDS + daily.resetHourUtc * HOUR_SECONDS
end

-- The day's goal ids: one from each slot, each slot stepping on one goal a day.
function GoalsService.dailyFor(day: number): { string }
	local ids: { string } = {}
	for index, slot in daily.slots do
		if #slot > 0 then
			table.insert(ids, slot[(day + index - 1) % #slot + 1].id)
		end
	end
	return ids
end

-- Brings the daily goals to the goals day of `now`: a new day's three goals, nothing done. True when it changed them.
function GoalsService.roll(goals: GoalsData, now: number): boolean
	local day = GoalsService.dayOf(now)
	local today = goals.daily
	if today.day == day then
		return false
	end
	today.day = day
	today.ids = GoalsService.dailyFor(day)
	today.progress = {}
	today.claimed = {}
	return true
end

local function matches(goal: Goal, counter: string, detail: Detail?): boolean
	if goal.counter ~= counter then
		return false
	elseif goal.jobType ~= nil and (detail == nil or detail.jobType ~= goal.jobType) then
		return false
	elseif goal.vehicleId ~= nil and (detail == nil or detail.vehicleId ~= goal.vehicleId) then
		return false
	end
	return true
end

-- Whether an event of `counter` would move anything at `now`: an unfinished path step it finishes, or one of
-- today's goals (after the day rolls) still short of its target. Read-only: an event that wouldn't is never written.
function GoalsService.wants(goals: GoalsData, counter: string, detail: Detail?, now: number): boolean
	local path = goals.path
	if not path.done then
		for _, goal in pathGoals do
			if not path.finished[goal.id] and matches(goal, counter, detail) then
				return true
			end
		end
	end
	local day = GoalsService.dayOf(now)
	local rolls = goals.daily.day ~= day
	local ids: { string } = if rolls then GoalsService.dailyFor(day) else goals.daily.ids
	for _, id in ids do
		local goal = dailyById[id]
		if goal ~= nil and matches(goal, counter, detail) then
			if rolls then
				return true
			end
			if not goals.daily.claimed[id] and cleanProgress(goals.daily.progress[id]) < goal.target then
				return true
			end
		end
	end
	return false
end

-- Counts `amount` of `counter` (miles, $, or 1 for a count): finishes the unfinished path steps it matches (a path
-- step needs one event) and moves today's matching goals toward their targets, never past them (rolling the day
-- first). Changes `goals`; returns what it finished.
function GoalsService.record(goals: GoalsData, counter: string, amount: number, detail: Detail?, now: number): Effects
	local effects: Effects = { finished = {}, ready = {} }
	if not isFinite(amount) or amount <= 0 then
		return effects
	end
	local path = goals.path
	if not path.done then
		for _, goal in pathGoals do
			if not path.finished[goal.id] and matches(goal, counter, detail) then
				path.finished[goal.id] = true
				table.insert(effects.finished, goal.id)
			end
		end
	end
	GoalsService.roll(goals, now)
	local today = goals.daily
	for _, id in today.ids do
		local goal = dailyById[id]
		if goal ~= nil and not today.claimed[id] and matches(goal, counter, detail) then
			local before = cleanProgress(today.progress[id])
			if before < goal.target then
				local after = math.min(before + amount, goal.target)
				today.progress[id] = after
				if after >= goal.target then
					table.insert(effects.ready, id)
				end
			end
		end
	end
	return effects
end

local function allPaid(goals: GoalsData): boolean
	for _, goal in pathGoals do
		if not goals.path.claimed[goal.id] then
			return false
		end
	end
	return true
end

-- Marks `goalId` collected and returns its reward, or nil and why not: a path step must be finished and not yet paid
-- (the last one paid ends the path); a daily goal must be on today's list (after the day rolls: "expired" when the
-- roll just took it away), at its target and not yet collected. Changes `goals` only when it pays.
function GoalsService.claimIn(goals: GoalsData, goalId: string, now: number): (number?, Refusal?)
	local step = pathById[goalId]
	if step ~= nil then
		local path = goals.path
		if path.claimed[goalId] then
			return nil, "claimed"
		elseif path.done then
			return nil, "done"
		elseif not path.finished[goalId] then
			return nil, "notFinished"
		end
		path.claimed[goalId] = true
		if allPaid(goals) then
			path.done = true
		end
		return step.reward, nil
	end
	local goal = dailyById[goalId]
	if goal == nil then
		return nil, "unknown"
	end
	local rolled = GoalsService.roll(goals, now)
	local today = goals.daily
	if table.find(today.ids, goalId) == nil then
		return nil, if rolled then "expired" else "unknown"
	elseif today.claimed[goalId] then
		return nil, "claimed"
	elseif cleanProgress(today.progress[goalId]) < goal.target then
		return nil, if rolled then "expired" else "notFinished"
	end
	today.claimed[goalId] = true
	return goal.reward, nil
end

-- Ends the path for good without paying anything more. True when it was still running.
function GoalsService.skip(goals: GoalsData): boolean
	if goals.path.done then
		return false
	end
	goals.path.done = true
	return true
end

-- The path step the card shows: the first one not yet paid, in Config/Goals order. nil once the path is done.
function GoalsService.currentStep(goals: GoalsData): string?
	if goals.path.done then
		return nil
	end
	for _, goal in pathGoals do
		if not goals.path.claimed[goal.id] then
			return goal.id
		end
	end
	return nil
end

-- How many more miles the nearest of today's unfinished miles goals needs, or nil when none does (or the day hasn't
-- rolled to `now` yet: the roll comes first).
function GoalsService.milesLeft(goals: GoalsData, now: number): number?
	local today = goals.daily
	if today.day ~= GoalsService.dayOf(now) then
		return nil
	end
	local left: number? = nil
	for _, id in today.ids do
		local goal = dailyById[id]
		if goal ~= nil and goal.counter == "miles" and not today.claimed[id] then
			local remaining = goal.target - cleanProgress(today.progress[id])
			if remaining > 0 and (left == nil or remaining < left) then
				left = remaining
			end
		end
	end
	return left
end

-- What the client is sent (Net GoalsUpdate). Call it after rolling the day to `now`.
function GoalsService.payload(goals: GoalsData, now: number): Payload
	local path: { steps: { StepState }, current: string? }? = nil
	if not goals.path.done then
		local steps: { StepState } = {}
		for _, goal in pathGoals do
			table.insert(steps, {
				id = goal.id,
				finished = goals.path.finished[goal.id] == true,
				claimed = goals.path.claimed[goal.id] == true,
			})
		end
		path = { steps = steps, current = GoalsService.currentStep(goals) }
	end
	local today = goals.daily
	local list: { DailyState } = {}
	for _, id in today.ids do
		if dailyById[id] ~= nil then
			table.insert(list, {
				id = id,
				progress = cleanProgress(today.progress[id]),
				claimed = today.claimed[id] == true,
			})
		end
	end
	return {
		path = path,
		daily = { day = today.day, resetsAt = GoalsService.nextResetAt(now), goals = list },
	}
end

-- Whether cash paid with this EconomyService reason counts toward "earn" goals.
function GoalsService.earnCounts(reason: string): boolean
	if table.find(daily.earnReasons, reason) ~= nil then
		return true
	end
	for _, prefix in daily.earnReasonPrefixes do
		if string.sub(reason, 1, #prefix) == prefix then
			return true
		end
	end
	return false
end

-- A goal by id (a path step or a daily goal), for the specs and the client's words.
function GoalsService.goal(goalId: string): Goal?
	return pathById[goalId] or dailyById[goalId]
end

-- Saved data ------------------------------------------------------------------------------------------------

-- The player's goals when every part has the right type (read-only), else nil.
local function goalsOf(data: Types.PlayerData): GoalsData?
	local goals: any = (data :: any).goals
	if type(goals) ~= "table" or type(goals.path) ~= "table" or type(goals.daily) ~= "table" then
		return nil
	end
	local path, today = goals.path, goals.daily
	if
		type(path.done) ~= "boolean"
		or type(path.finished) ~= "table"
		or type(path.claimed) ~= "table"
		or type(today.day) ~= "number"
		or type(today.ids) ~= "table"
		or type(today.progress) ~= "table"
		or type(today.claimed) ~= "table"
	then
		return nil
	end
	return goals
end

-- The player's goals with any broken part replaced, inside a DataService.update. A save whose goals are broken never
-- gets the path forced on it (a broken path counts as done).
local function repaired(data: Types.PlayerData): GoalsData
	local good = goalsOf(data)
	if good ~= nil then
		return good
	end
	local fresh = Template.goals(true)
	local goals: any = (data :: any).goals
	if type(goals) ~= "table" then
		data.goals = fresh
		return fresh
	end
	local path = goals.path
	if type(path) ~= "table" then
		goals.path = fresh.path
	else
		if type(path.done) ~= "boolean" then
			path.done = true
		end
		if type(path.finished) ~= "table" then
			path.finished = {}
		end
		if type(path.claimed) ~= "table" then
			path.claimed = {}
		end
	end
	local today = goals.daily
	if type(today) ~= "table" then
		goals.daily = fresh.daily
	else
		if type(today.day) ~= "number" then
			today.day = fresh.daily.day
		end
		for _, field in { "ids", "progress", "claimed" } do
			if type(today[field]) ~= "table" then
				today[field] = {}
			end
		end
	end
	return goals
end

-- Pays `reward` inside the caller's update. Returns what really went in (the wallet stops at Config/Economy.maxCash).
local function payInto(data: Types.PlayerData, reward: number): number
	local balance, added = EconomyService.applyAdd(data.cash, reward, Economy.maxCash)
	data.cash = balance
	return added
end

-- Publishing ----------------------------------------------------------------------------------------------------

local function notify(player: Player, message: string, kind: string)
	if player.Parent == Players then
		Net.fireClient("Notify", player, { text = message, kind = kind })
	end
end

local function push(player: Player)
	pushQueued[player] = nil
	local dataService = DataService
	local data = if dataService ~= nil then dataService.get(player) else nil
	local goals = if data ~= nil then goalsOf(data) else nil
	if goals == nil or player.Parent ~= Players then
		return
	end
	Net.fireClient("GoalsUpdate", player, GoalsService.payload(goals, os.time()))
end

-- Pushes once at the end of this frame however many changes happen in it.
local function queuePush(player: Player)
	if pushQueued[player] then
		return
	end
	pushQueued[player] = true
	task.defer(push, player)
end

-- Miles ---------------------------------------------------------------------------------------------------------

local onHeartbeat: (dt: number) -> ()

-- The Heartbeat is connected only while someone is sampled.
local function updateSampler()
	local connection = sampler
	if next(trackers) ~= nil and not connection then
		sinceSample = 0
		sampler = RunService.Heartbeat:Connect(onHeartbeat)
	elseif next(trackers) == nil and connection then
		connection:Disconnect()
		sampler = nil
	end
end

-- Starts or stops sampling the player's driving: only while they have an unfinished miles goal today.
local function refreshTracking(player: Player)
	local dataService = DataService
	local data = if dataService ~= nil and not gone[player] then dataService.get(player) else nil
	local goals = if data ~= nil then goalsOf(data) else nil
	local wanted = goals ~= nil and GoalsService.milesLeft(goals, os.time()) ~= nil
	if wanted and trackers[player] == nil then
		local now = os.clock()
		trackers[player] = { car = nil, position = nil, at = now, pending = 0, committedAt = now }
	elseif not wanted and trackers[player] ~= nil then
		trackers[player] = nil
	end
	updateSampler()
end

-- Counting ------------------------------------------------------------------------------------------------------

-- One server event for one player: counts it in a single update (path steps it finishes pay at once), then tells the
-- player and their client. Never yields. Writes nothing when the event can't move anything (GoalsService.wants).
local function count(player: Player, counter: string, amount: number, detail: Detail?)
	local dataService = DataService
	local data = if dataService ~= nil then dataService.get(player) else nil
	if dataService == nil or data == nil then
		return
	end
	local now = os.time()
	local current = goalsOf(data)
	if current ~= nil and not GoalsService.wants(current, counter, detail, now) then
		return
	end
	local effects: Effects? = nil
	local paid: { { goal: Goal, added: number } } = {}
	local ended = false
	local updated = dataService.update(player, function(fresh: Types.PlayerData)
		local goals = repaired(fresh)
		local wasDone = goals.path.done
		local result = GoalsService.record(goals, counter, amount, detail, now)
		effects = result
		for _, id in result.finished do
			local reward = GoalsService.claimIn(goals, id, now)
			if reward ~= nil then
				table.insert(paid, { goal = pathById[id], added = payInto(fresh, reward) })
			end
		end
		ended = goals.path.done and not wasDone
	end)
	local result = effects
	if not updated or result == nil then
		return
	end
	local total = 0
	for _, payment in paid do
		total += payment.added
		local format = payment.goal.paidText or text.paid
		notify(player, string.format(format, Economy.formatCash(payment.goal.reward)), "success")
	end
	if total > 0 then
		EconomyService.recordChange(player, "source", total, Goals.economyReason)
	end
	if ended then
		notify(player, text.pathDone, "success")
	end
	for _, id in result.ready do
		local goal = dailyById[id]
		if goal ~= nil then
			notify(player, string.format(text.ready, Goals.titleOf(goal, Economy.formatCash)), "success")
		end
	end
	refreshTracking(player)
	queuePush(player)
end

-- Counts the miles a tracker holds now if it is time: every daily.milesCommitSeconds, at once when they reach a goal,
-- or when `force` (the player is leaving).
local function commitMiles(player: Player, tracker: Tracker, now: number, force: boolean)
	if tracker.pending <= 0 then
		return
	end
	local miles = Units.studsToMeters(tracker.pending) / METERS_PER_MILE
	local dataService = DataService
	local data = if dataService ~= nil then dataService.get(player) else nil
	local goals = if data ~= nil then goalsOf(data) else nil
	local left = if goals ~= nil then GoalsService.milesLeft(goals, os.time()) else nil
	if left == nil then
		tracker.pending = 0
		return
	end
	if force or miles >= left or now - tracker.committedAt >= daily.milesCommitSeconds then
		tracker.pending = 0
		tracker.committedAt = now
		if force then
			count(player, "miles", miles, nil)
		else
			-- Deferred: counting can stop this player's tracking, and the sampler is walking the trackers.
			task.defer(count, player, "miles", miles, nil)
		end
	end
end

-- The player's own car while they sit in its Driver seat (not a test drive), else nil.
local function drivenCar(player: Player): Model?
	local car = VehicleService.getCar(player)
	if car == nil or car:GetAttribute(Garage.testDriveAttribute) == true then
		return nil
	end
	local seats = car:FindFirstChild(SEATS_FOLDER)
	local seat = if seats ~= nil then seats:FindFirstChild(DRIVER_SEAT) else nil
	local character = player.Character
	if seat == nil or not seat:IsA("Seat") or character == nil then
		return nil
	end
	local occupant = (seat :: Seat).Occupant
	if occupant == nil or occupant.Parent ~= character then
		return nil
	end
	return car
end

local function sampleMiles(now: number)
	local maxSpeed = Units.mphToStuds(daily.maxMph)
	for player, tracker in trackers do
		local car = drivenCar(player)
		local chassis = if car ~= nil then car.PrimaryPart else nil
		local position = if chassis ~= nil then chassis.Position else nil
		local previous = tracker.position
		if car ~= nil and car == tracker.car and position ~= nil and previous ~= nil then
			local step = Vector2.new(position.X - previous.X, position.Z - previous.Z).Magnitude
			local moved = AntiExploitService.lastServerMove(car)
			local legal = (moved == nil or moved <= tracker.at) and step <= maxSpeed * (now - tracker.at)
			if legal then
				tracker.pending += step
			end
		end
		tracker.car = car
		tracker.position = position
		tracker.at = now
		commitMiles(player, tracker, now, false)
	end
end

onHeartbeat = function(dt: number)
	sinceSample += dt
	if sinceSample < daily.sampleSeconds then
		return
	end
	sinceSample = 0
	sampleMiles(os.clock())
end

-- Cars: charging and meet spots -----------------------------------------------------------------------------------

local function ownerOf(model: Model): Player?
	local userId = model:GetAttribute(OWNER_ATTRIBUTE)
	if type(userId) ~= "number" then
		return nil
	end
	return Players:GetPlayerByUserId(userId)
end

-- A player's own car: not a dealership test drive or a Studio meet stand-in.
local function counts(model: Model): boolean
	return model:GetAttribute(Garage.testDriveAttribute) ~= true
		and model:GetAttribute(Social.dev.dummyAttribute) ~= true
end

-- The car stopped or was parked: a "meet" when it stands inside a MeetSpot.
local function onSettled(model: Model)
	local owner = ownerOf(model)
	if owner == nil or not counts(model) then
		return
	end
	if MeetService.spotAt(model:GetPivot().Position, meetSpots, Social.meet.footprintMargin) ~= nil then
		count(owner, "meet", 1, nil)
	end
end

local function watchCar(instance: Instance)
	if not instance:IsA("Model") then
		return
	end
	local model = instance :: Model
	-- The connections go with the car when it is destroyed.
	model:GetAttributeChangedSignal(Goals.chargingAttribute):Connect(function()
		local owner = ownerOf(model)
		if model:GetAttribute(Goals.chargingAttribute) == true and owner ~= nil and counts(model) then
			count(owner, "charge", 1, nil)
		end
	end)
	model:GetAttributeChangedSignal(STILL_ATTRIBUTE):Connect(function()
		if model:GetAttribute(STILL_ATTRIBUTE) == true then
			onSettled(model)
		end
	end)
	local chassis = model.PrimaryPart
	if chassis ~= nil then
		chassis:GetPropertyChangedSignal("Anchored"):Connect(function()
			if chassis.Anchored then
				onSettled(model)
			end
		end)
	end
end

-- Remote --------------------------------------------------------------------------------------------------------

local REFUSALS: { [Refusal]: string } = {
	done = text.alreadyClaimed,
	unknown = text.unknown,
	claimed = text.alreadyClaimed,
	notFinished = text.notFinished,
	expired = text.expired,
}

local function reply(ok: boolean, message: string, reward: number?): Reply
	return { ok = ok, message = message, reward = reward }
end

local function onClaimGoal(player: Player, payload: any): Reply
	local goalId: string = payload.goalId
	local dataService = DataService
	if dataService == nil or dataService.get(player) == nil then
		return reply(false, text.loading)
	end
	local now = os.time()

	if goalId == Goals.path.skipId then
		local skipped = false
		local updated = dataService.update(player, function(data: Types.PlayerData)
			skipped = GoalsService.skip(repaired(data))
		end)
		if not updated then
			return reply(false, text.loading)
		end
		queuePush(player)
		return reply(skipped, if skipped then text.skipped else text.alreadyClaimed)
	end

	local reward: number? = nil
	local refusal: Refusal? = nil
	local added = 0
	local updated = dataService.update(player, function(data: Types.PlayerData)
		reward, refusal = GoalsService.claimIn(repaired(data), goalId, now)
		if reward ~= nil then
			added = payInto(data, reward)
		end
	end)
	if not updated then
		return reply(false, text.loading)
	end
	if added > 0 then
		EconomyService.recordChange(player, "source", added, Goals.economyReason)
	end
	refreshTracking(player)
	queuePush(player)
	if reward == nil then
		if refusal == "unknown" and not warnedUnknown[player] then
			warnedUnknown[player] = true
			warn(`{LOG} {player.Name} ({player.UserId}) claimed a goal that isn't theirs today: {goalId}`)
		end
		return reply(false, REFUSALS[(refusal or "unknown") :: Refusal])
	end
	return reply(true, string.format(text.claimed, Economy.formatCash(reward)), reward)
end

-- Joining and the daily reset -------------------------------------------------------------------------------------

-- Rolls the player's daily goals to today when they aren't (writing only then), and publishes.
local function bringUpToDate(player: Player)
	local dataService = DataService
	local data = if dataService ~= nil then dataService.get(player) else nil
	if dataService == nil or data == nil then
		return
	end
	local now = os.time()
	local goals = goalsOf(data)
	if goals == nil or goals.daily.day ~= GoalsService.dayOf(now) then
		dataService.update(player, function(fresh: Types.PlayerData)
			GoalsService.roll(repaired(fresh), now)
		end)
	end
	refreshTracking(player)
	queuePush(player)
end

-- At every reset, everyone online gets the new day's goals (one timer, not a poll).
local function scheduleReset()
	local now = os.time()
	task.delay(GoalsService.nextResetAt(now) - now + 1, function()
		for _, player in Players:GetPlayers() do
			bringUpToDate(player)
		end
		scheduleReset()
	end)
end

-- Studio only ---------------------------------------------------------------------------------------------------

-- Starts the player's first-session path again with fresh daily goals (CLAUDE.md hard rule 8: Studio only). True
-- when it was saved. Rejoin (in Studio: Stop, then Play) to see the first spawn: it runs on a session's first
-- character.
function GoalsService.devRestart(player: Player): boolean
	if not RunService:IsStudio() then
		warn(`{LOG} devRestart only works in Studio`)
		return false
	end
	local dataService = DataService
	if dataService == nil then
		return false
	end
	local now = os.time()
	local updated = dataService.update(player, function(data: Types.PlayerData)
		local goals = Template.goals(false)
		GoalsService.roll(goals, now)
		data.goals = goals
	end)
	refreshTracking(player)
	queuePush(player)
	return updated
end

-- Boot ------------------------------------------------------------------------------------------------------------

-- Registers `listener` with a service's hook (Services/<name>.<method>). A service or hook that is missing is
-- reported once and its goals just never move.
local function hook(name: string, method: string, listener: any)
	local module = script.Parent:FindFirstChild(name)
	if module == nil or not module:IsA("ModuleScript") then
		warn(`{LOG} no {name}: its goals won't count`)
		return
	end
	local ok, service = pcall(require :: any, module)
	if ok and type(service) == "table" and type(service[method]) == "function" then
		service[method](listener)
	else
		warn(`{LOG} {name}.{method} is missing: its goals won't count`)
	end
end

function GoalsService:Init()
	DataService = require(script.Parent.DataService)
end

function GoalsService:Start()
	local dataService = DataService
	if dataService == nil then
		return
	end

	Net.onServerInvoke("ClaimGoal", onClaimGoal)

	hook("JobService", "onCompleted", function(player: Player, kind: string)
		count(player, "job", 1, { jobType = kind })
	end)
	hook("DealershipService", "onTestDriveStarted", function(player: Player, vehicleId: string)
		count(player, "testDrive", 1, { vehicleId = vehicleId })
	end)
	hook("DesignerService", "onDesignBuilt", function(player: Player)
		count(player, "design", 1, nil)
	end)
	hook("HouseService", "onClaimed", function(player: Player)
		count(player, "house", 1, nil)
	end)
	EconomyService.onEarned(function(player: Player, amount: number, reason: string)
		if GoalsService.earnCounts(reason) then
			count(player, "earn", amount, nil)
		end
	end)

	CollectionService:GetInstanceAddedSignal(Spawning.vehicleTag):Connect(watchCar)
	for _, instance in CollectionService:GetTagged(Spawning.vehicleTag) do
		watchCar(instance)
	end

	-- The miles driven since the last count are counted on the way out (beforeRelease: the session is still open).
	dataService.beforeRelease(function(player: Player)
		local tracker = trackers[player]
		if tracker ~= nil then
			commitMiles(player, tracker, os.clock(), true)
		end
	end)
	Players.PlayerRemoving:Connect(function(player: Player)
		gone[player] = true
		pushQueued[player] = nil
		-- After DataService's own PlayerRemoving handler, whose beforeRelease counted what the tracker held.
		task.defer(function()
			trackers[player] = nil
			updateSampler()
		end)
	end)

	dataService.onLoaded(function(player: Player)
		bringUpToDate(player)
	end)
	scheduleReset()
end

return GoalsService
