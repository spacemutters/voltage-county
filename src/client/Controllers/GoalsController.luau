--!strict
-- Goals on the client (roast fixes 2026-10-24, docs/roast-2026-10-24.md point 8 "The first five minutes have no
-- hook"): the one card that says what to do next, and the list behind it (UI/Goals). The server decides every goal
-- (Services/GoalsService); this controller keeps what it last said (Net GoalsUpdate), shows it, and turns the card's
-- one tap into the request it stands for.
--
--   card       while the first-session path runs: its current step ("Step 1 of 3 · $3,000 bonus", the title) with
--              the one button that does it. Else today's first daily goal that is ready, with "Collect $1,500", or
--              the small "Goals 1/3" button. Tapping the card's words opens the list. Hidden while a job runs (the
--              HUD's job slot says what to do then) unless a goal is ready to collect, and during a pod ride's
--              cutscene. It sits clear of the HUD (placeCard: below the light-show button's place, else beside the
--              cash column, else under the GPS chip, else under the cash column), at the HUD's UI scale: tall where
--              it fits, else in one compact row (a small landscape phone driving on touch).
--   buttons    startFare: accepts the nearest rideshare offer for the player's car (JobController.accept, after a
--              silent refresh when there are no offers yet). testDrive: within Config/Dealership testDrive
--              maxStartDistance of the goal's display car, starts its test drive (Net StartTestDrive with the display
--              car's own trim); farther away the GPS leads to that display car (to the dealership until it has
--              streamed in, then on to the car). openDesigner: the AI Car Designer
--              (DesignerController.openStudio, which also unlocks the phone's Designer app). gps: the GPS to the
--              goal's place. Collect: Net ClaimGoal { goalId }. Skip (in the list, two taps: it gives up the
--              bonuses for good): Net ClaimGoal { goalId = Config/Goals path.skipId }. The server's answers show as
--              notices.
--   GPS line   when a path step with a place (gpsTo) becomes the current step, the GPS leads there, once, and only
--              while no route is set: a job's route, or one the player chose, is never replaced. The test drive's
--              line ends at the Arc's display car itself (the Ohm pads stand far past the test-drive reach from the
--              dealership's GPS point). The fare's line is the job's own (JobController).
--   first fare starts by itself once a session, within Config/Goals path.autoStartSeconds of the step first
--              showing, as soon as the player sits in their own car with no job and the server has offered a fare.
--   list       the path's steps with Skip, today's three goals with progress, reward and Collect (or Go), and when
--              they reset (UI/Goals/GoalsSheet, placed like the phone's sheet).
--
-- Whether the goal's car is close enough to test drive is looked at every Config/Goals path.nearCheckSeconds
-- (Heartbeat with an accumulator) only while the test-drive step is on the card. Everything else follows events:
-- GoalsUpdate, JobController.onChanged, DriveController.onDrivingChanged, the input kind, the screen size and the
-- cutscene attribute. The pure parts (normalize, cardFor, cardRect, placeCard, cardBlockers, nearestFare, rowsFor,
-- durationText) are exposed for tests/Goals.spec.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local React = require(ReplicatedStorage.Packages.React)
local ReactRoblox = require(ReplicatedStorage.Packages.ReactRoblox)
local Controls = require(ReplicatedStorage.Shared.Config.Controls)
local Dealership = require(ReplicatedStorage.Shared.Config.Dealership)
local Economy = require(ReplicatedStorage.Shared.Config.Economy)
local Garage = require(ReplicatedStorage.Shared.Config.Garage)
local Goals = require(ReplicatedStorage.Shared.Config.Goals)
local LightShows = require(ReplicatedStorage.Shared.Config.LightShows)
local Net = require(ReplicatedStorage.Shared.Net)
local DriveController = require(script.Parent.DriveController)
local GpsController = require(script.Parent.GpsController)
local HudController = require(script.Parent.HudController)
local JobController = require(script.Parent.JobController)
local NotifyController = require(script.Parent.NotifyController)

local UI = script.Parent.Parent.UI
local GoalCard = require(UI.Goals.GoalCard)
local GoalsSheet = require(UI.Goals.GoalsSheet)
local Layout = require(UI.Phone.Layout)
local PhoneConfig = require(UI.Phone.PhoneConfig)
local Theme = require(UI.Theme)

local GUI_NAME = "Goals"
local DESIGNER_MODULE = "DesignerController" -- found when the card's Design is tapped (keeps tests/Goals.spec light)
local REMOTE_UPDATE = "GoalsUpdate"
local REMOTE_CLAIM = "ClaimGoal"
local REMOTE_TEST_DRIVE = "StartTestDrive"
local OWNER_ATTRIBUTE = "OwnerUserId" -- set by VehicleService on every spawned car
local ROOT_PART = "HumanoidRootPart"
local CARD_BUSY = "card" -- view.busy while the card's own button works
local RIDESHARE = "rideshare" -- the Config/Jobs type a startFare step accepts
local SECONDS_PER_MINUTE = 60
local MINUTES_PER_HOUR = 60

local e = React.createElement
local text = Goals.text

export type Card = GoalCard.Card
export type StepRow = GoalsSheet.StepRow
export type DailyRow = GoalsSheet.DailyRow

-- One path step and one daily goal as GoalsUpdate sends them (checked by normalize).
export type Step = { id: string, finished: boolean, claimed: boolean }
export type Daily = { id: string, progress: number, claimed: boolean }

export type State = {
	path: { steps: { Step }, current: string? }?, -- nil once the path is done
	daily: { day: number, resetsAt: number, goals: { Daily } }, -- resetsAt: Unix seconds
}

-- What the card depends on besides the goals.
export type Context = {
	jobRunning: boolean,
	nearCar: boolean, -- close enough to the test-drive step's car to start it
}

type View = {
	state: State?,
	jobRunning: boolean,
	nearCar: boolean,
	driving: boolean,
	cutscene: boolean,
	open: boolean, -- the list is showing
	busy: string?, -- a goal id (or CARD_BUSY) a request is in flight for
	inputKind: string,
	scale: number,
	screen: Vector2, -- UI-scale-1 px
}

local GoalsController = {}

local view: View = {
	state = nil,
	jobRunning = false,
	nearCar = false,
	driving = false,
	cutscene = false,
	open = false,
	busy = nil,
	inputKind = "keyboard",
	scale = 1,
	screen = Vector2.new(Controls.hud.referenceShortSide, Controls.hud.referenceShortSide),
}

local root: any = nil
local nearTicker: RBXScriptConnection? = nil
local sinceNearCheck = 0
local routedStep: string? = nil -- the path step the GPS was last pointed at
local routedToCar = false -- the test-drive step's route ends at its display car itself (not the dealership)
local autoStarted = false
local autoStartDeadline: number? = nil -- os.clock() after which the first fare waits for a tap

local pathById: { [string]: Goals.Goal } = {}
for _, goal in Goals.path.goals do
	pathById[goal.id] = goal
end
local dailyById: { [string]: Goals.Goal } = {}
for _, slot in Goals.daily.slots do
	for _, goal in slot do
		dailyById[goal.id] = goal
	end
end

-- Pure helpers ---------------------------------------------------------------------------------------------------

local function finite(value: any): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

-- A GoalsUpdate payload checked and copied (unknown goals left out), or nil when it isn't one.
function GoalsController.normalize(payload: any): State?
	if type(payload) ~= "table" or type(payload.daily) ~= "table" then
		return nil
	end
	local raw = payload.daily
	local goals: { Daily } = {}
	if type(raw.goals) == "table" then
		for _, entry in raw.goals do
			if type(entry) == "table" and type(entry.id) == "string" and dailyById[entry.id] ~= nil then
				local progress = if finite(entry.progress) then math.max(entry.progress, 0) else 0
				table.insert(goals, { id = entry.id, progress = progress, claimed = entry.claimed == true })
			end
		end
	end
	local path: { steps: { Step }, current: string? }? = nil
	local rawPath = payload.path
	if type(rawPath) == "table" and type(rawPath.steps) == "table" then
		local steps: { Step } = {}
		for _, entry in rawPath.steps do
			if type(entry) == "table" and type(entry.id) == "string" and pathById[entry.id] ~= nil then
				table.insert(
					steps,
					{ id = entry.id, finished = entry.finished == true, claimed = entry.claimed == true }
				)
			end
		end
		local current = rawPath.current
		path = { steps = steps, current = if type(current) == "string" and pathById[current] then current else nil }
	end
	return {
		path = path,
		daily = {
			day = if finite(raw.day) then raw.day else 0,
			resetsAt = if finite(raw.resetsAt) then raw.resetsAt else 0,
			goals = goals,
		},
	}
end

local function stepOf(state: State, id: string): (Step?, number)
	local path = state.path
	if path == nil then
		return nil, 0
	end
	for index, step in path.steps do
		if step.id == id then
			return step, index
		end
	end
	return nil, 0
end

-- What the card shows, or nil when it shouldn't show. `formatCash` writes the rewards ("$3,000").
function GoalsController.cardFor(state: State?, context: Context, formatCash: (amount: number) -> string): Card?
	if state == nil then
		return nil
	end
	local path = state.path
	local current = if path ~= nil then path.current else nil
	if path ~= nil and current ~= nil then
		local goal = pathById[current]
		local step, index = stepOf(state, current)
		local paid = step ~= nil and step.claimed
		-- A finished step pays by itself; one still waiting (a missed payment) is collected with a tap.
		local finished = step ~= nil and step.finished and not paid
		if context.jobRunning and not finished then
			return nil
		end
		local reward = formatCash(goal.reward)
		local label, short = goal.actionLabel, goal.shortLabel or goal.actionLabel
		if finished then
			label, short = string.format(text.collect, reward), text.collectShort
		elseif goal.action == "testDrive" and not context.nearCar then
			label = goal.goLabel or text.go
			short = label
		end
		local number = math.max(index, 1)
		return {
			kind = "path",
			goalId = goal.id,
			eyebrow = string.format(text.pathEyebrow, number, #path.steps, reward),
			shortEyebrow = string.format(text.pathEyebrowShort, number, #path.steps, reward),
			title = Goals.titleOf(goal, formatCash),
			actionLabel = label,
			shortLabel = short,
			collect = finished,
			progress = nil,
		}
	end
	local collected = 0
	for _, entry in state.daily.goals do
		local goal = dailyById[entry.id]
		if entry.claimed then
			collected += 1
		elseif goal ~= nil and entry.progress >= goal.target then
			local reward = formatCash(goal.reward)
			return {
				kind = "daily",
				goalId = entry.id,
				eyebrow = text.dailyEyebrow,
				shortEyebrow = string.format(text.dailyEyebrowShort, reward),
				title = Goals.titleOf(goal, formatCash),
				actionLabel = string.format(text.collect, reward),
				shortLabel = text.collectShort,
				collect = true,
				progress = 1,
			}
		end
	end
	local total = #state.daily.goals
	if total == 0 or context.jobRunning then
		return nil
	end
	return {
		kind = "pill",
		goalId = nil,
		eyebrow = "",
		shortEyebrow = "",
		title = string.format(text.dailyPill, collected, total),
		actionLabel = nil,
		shortLabel = nil,
		collect = false,
		progress = nil,
	}
end

-- The cash readout, the job slot and the hitch row under it: the HUD's cash column.
local function cashColumn(screen: Vector2): Layout.Rect
	local margin = Controls.touch.margin
	local hitch = HudController.hitchRect(screen)
	local width = math.max(Economy.hud.cashMaxWidth, PhoneConfig.hud.jobSlot.size.X, Layout.width(hitch))
	return Layout.rect(margin, margin, width, hitch.bottom - margin)
end

-- The light-show button's place, under the notices band (Controllers/LightShowController).
local function lightShowRect(screen: Vector2): Layout.Rect
	local width = LightShows.button.width
	local top = HudController.noticesRect(screen).bottom + LightShows.button.gap
	return Layout.rect((screen.X - width) / 2, top, width, Theme.size.buttonHeight)
end

-- What the card and the pill keep clear of on `screen` (UI-scale-1 px): the notices band, the light-show button's
-- place, the GPS route chip, the cash column (with its job slot and hitch row) and the fleet chip's lower place, the
-- phone button, the speed panel while driving, and on touch the steering zones, pedals (Layout.touchZones counts the
-- Horn / Lights row above them) and touch buttons.
function GoalsController.cardBlockers(screen: Vector2, context: Layout.Context): { Layout.Rect }
	local list: { Layout.Rect } = {
		HudController.noticesRect(screen),
		lightShowRect(screen),
		HudController.gpsChipRect(screen),
		cashColumn(screen),
		HudController.fleetChipBelowRect(screen),
		Layout.phoneButton(screen, context),
	}
	if context.driving then
		table.insert(list, Layout.cluster(screen, context.hints))
	end
	if context.touch then
		local zones = Layout.touchZones(screen)
		table.insert(list, zones.steering)
		table.insert(list, zones.pedals)
		table.insert(list, zones.buttons)
	end
	return list
end

-- The spots a card of `size` may take on `screen`, best first: centred under the light-show button's place, beside
-- the cash column at the same height, under the GPS chip, or under the cash column (below the fleet chip's place).
local function candidatesFor(screen: Vector2, size: Vector2): { Layout.Rect }
	local gap = Goals.card.gap
	local top = lightShowRect(screen).bottom + gap
	local column = cashColumn(screen)
	local gps = HudController.gpsChipRect(screen)
	local fleet = HudController.fleetChipBelowRect(screen)
	return {
		Layout.rect((screen.X - size.X) / 2, top, size.X, size.Y),
		Layout.rect(column.right + gap, top, size.X, size.Y),
		Layout.rect(gps.right - size.X, gps.bottom + gap, size.X, size.Y),
		Layout.rect(column.left, fleet.bottom + gap, size.X, size.Y),
	}
end

-- The first spot for a card of `size` that is on screen and clear of every cardBlockers rect, or nil.
function GoalsController.cardRect(screen: Vector2, context: Layout.Context, size: Vector2): Layout.Rect?
	local blockers = GoalsController.cardBlockers(screen, context)
	local whole = Layout.screen(screen)
	for _, candidate in candidatesFor(screen, size) do
		local clear = Layout.contains(whole, candidate)
		for _, blocker in blockers do
			if not clear then
				break
			end
			clear = not Layout.overlaps(candidate, blocker)
		end
		if clear then
			return candidate
		end
	end
	return nil
end

-- Where the card goes and in which shape: the pill at its own size; a card tall where it fits, else compact. On a
-- screen too small for either (none seen so far), the compact card in its first spot.
function GoalsController.placeCard(
	screen: Vector2,
	context: Layout.Context,
	pill: boolean
): (Layout.Rect, GoalCard.Shape)
	local config = Goals.card
	if pill then
		local size = config.pillSize
		return GoalsController.cardRect(screen, context, size) or candidatesFor(screen, size)[1], "pill"
	end
	local tall = GoalsController.cardRect(screen, context, config.size)
	if tall ~= nil then
		return tall, "tall"
	end
	local size = config.compactSize
	return GoalsController.cardRect(screen, context, size) or candidatesFor(screen, size)[1], "compact"
end

-- The rideshare offer with the least road to drive, or nil.
function GoalsController.nearestFare(offers: { JobController.Offer }): JobController.Offer?
	local best: JobController.Offer? = nil
	for _, offer in offers do
		if offer.type == RIDESHARE and (best == nil or offer.distance < best.distance) then
			best = offer
		end
	end
	return best
end

-- "5 h 12 min", or "12 min" under an hour (never below a minute).
function GoalsController.durationText(seconds: number): string
	local minutes = math.max(math.ceil(seconds / SECONDS_PER_MINUTE), 1)
	if minutes >= MINUTES_PER_HOUR then
		return string.format(text.hoursMinutes, minutes // MINUTES_PER_HOUR, minutes % MINUTES_PER_HOUR)
	end
	return string.format(text.minutes, minutes)
end

-- A goal's progress as the list writes it: "1.2 / 3 miles", "$4,200 / $10,000", "1 / 3".
local function progressText(goal: Goals.Goal, progress: number, formatCash: (amount: number) -> string): string
	local done: string
	if goal.counter == "miles" then
		done = string.format("%.1f", math.floor(progress * 10) / 10)
	elseif goal.counter == "earn" then
		done = formatCash(progress)
	else
		done = string.format("%d", math.floor(progress))
	end
	return string.format(text.progress, done, Goals.formatTarget(goal, formatCash))
end

-- The list's rows: the path's steps (nil once it is done) and today's goals.
function GoalsController.rowsFor(state: State, formatCash: (amount: number) -> string): ({ StepRow }?, { DailyRow })
	local steps: { StepRow }? = nil
	local path = state.path
	if path ~= nil then
		local list: { StepRow } = {}
		for _, step in path.steps do
			local goal = pathById[step.id]
			local bonus = string.format(text.bonus, formatCash(goal.reward))
			local current = step.id == path.current
			local note = if step.claimed
				then string.format(text.stepDone, formatCash(goal.reward))
				elseif current then string.format(text.stepNow, bonus)
				else bonus
			table.insert(list, {
				id = step.id,
				title = Goals.titleOf(goal, formatCash),
				note = note,
				current = current,
				claimed = step.claimed,
			})
		end
		steps = list
	end
	local daily: { DailyRow } = {}
	for _, entry in state.daily.goals do
		local goal = dailyById[entry.id]
		if goal ~= nil then
			local progress = math.min(entry.progress, goal.target)
			table.insert(daily, {
				id = entry.id,
				title = Goals.titleOf(goal, formatCash),
				detail = goal.detail,
				progress = if goal.target > 0 then progress / goal.target else 1,
				progressText = progressText(goal, progress, formatCash),
				reward = formatCash(goal.reward),
				ready = not entry.claimed and entry.progress >= goal.target,
				claimed = entry.claimed,
				canGo = goal.gpsTo ~= nil,
			})
		end
	end
	return steps, daily
end

-- The world -------------------------------------------------------------------------------------------------------

local function currentStepGoal(): Goals.Goal?
	local state = view.state
	local path = if state ~= nil then state.path else nil
	local current = if path ~= nil then path.current else nil
	return if current ~= nil then pathById[current] else nil
end

local function playerPosition(): Vector3?
	local character = Players.LocalPlayer.Character
	local part = if character ~= nil then character:FindFirstChild(ROOT_PART) else nil
	return if part ~= nil and part:IsA("BasePart") then part.Position else nil
end

-- The dealership's display car of `vehicleId`, when it has streamed in here.
local function displayCar(vehicleId: string): Model?
	local showroom = Workspace:FindFirstChild(Dealership.display.folderName)
	local folder = if showroom ~= nil then showroom:FindFirstChild(Dealership.display.dealershipFolderName) else nil
	if folder == nil then
		return nil
	end
	for _, child in folder:GetChildren() do
		if child:IsA("Model") and child:GetAttribute(Dealership.prompt.vehicleIdAttribute) == vehicleId then
			return child
		end
	end
	return nil
end

-- The goal's display car when the player stands (or sits) close enough to test drive it.
local function testCarInReach(goal: Goals.Goal): Model?
	local vehicleId = goal.vehicleId
	local position = playerPosition()
	local car = if vehicleId ~= nil then displayCar(vehicleId) else nil
	if car == nil or position == nil then
		return nil
	end
	return if (car:GetPivot().Position - position).Magnitude <= Dealership.testDrive.maxStartDistance then car else nil
end

-- The player sits in the Driver seat of their own car (not a test drive).
local function inOwnCar(): boolean
	local car = DriveController.getCar()
	return car ~= nil
		and car:GetAttribute(OWNER_ATTRIBUTE) == Players.LocalPlayer.UserId
		and car:GetAttribute(Garage.testDriveAttribute) ~= true
end

-- Drawing -----------------------------------------------------------------------------------------------------------

local render: () -> ()

local function context(): Layout.Context
	local touch = view.inputKind == "touch"
	return {
		driving = view.driving,
		touch = view.driving and touch,
		hints = view.driving and not touch,
	}
end

local function showReply(called: boolean, reply: any)
	if not called then
		NotifyController.show(text.failed, "error")
	elseif type(reply) == "table" and type(reply.message) == "string" and reply.message ~= "" then
		NotifyController.show(reply.message, if reply.ok == true then "success" else "warning")
	elseif type(reply) ~= "table" then
		NotifyController.show(PhoneConfig.labels.tryLater, "warning") -- Net turned it away (too many in a row)
	end
end

-- Runs `work` with the card (or one goal's button) waiting, one request at a time.
local function busyWhile(key: string, work: () -> ())
	if view.busy ~= nil then
		return
	end
	view.busy = key
	render()
	local ok, err = pcall(work :: any)
	if not ok then
		warn(`[GoalsController] {err}`)
		NotifyController.show(text.failed, "error")
	end
	view.busy = nil
	render()
end

local function claim(goalId: string)
	task.spawn(busyWhile, goalId, function()
		local called, reply = pcall(Net.invokeServer, REMOTE_CLAIM, { goalId = goalId })
		showReply(called, reply)
	end)
end

local function routeTo(goal: Goals.Goal)
	local place = goal.gpsTo
	if place ~= nil then
		GpsController.setDestination(place, { name = Goals.titleOf(goal, Economy.formatCash) })
	end
end

-- Accepts the nearest fare for the player's car. `auto`: the first fare starting by itself (says nothing on failure).
-- Yields.
local function startFare(auto: boolean)
	if JobController.get().job ~= nil then
		return
	end
	local offer = GoalsController.nearestFare(JobController.get().offers)
	if offer == nil then
		if DriveController.getCar() == nil then
			if not auto then
				NotifyController.show(text.noFare, "info")
			end
			return
		end
		if not auto then
			NotifyController.show(text.findingFare, "info")
		end
		JobController.refresh(true) -- silent; the server answers with the offers (or why there are none)
		offer = GoalsController.nearestFare(JobController.get().offers)
	end
	if offer == nil then
		if not auto then
			local availability = JobController.get().availability[RIDESHARE]
			local reason = if availability ~= nil and not availability.ok then availability.reason else nil
			NotifyController.show(reason or text.noFare, "info")
		end
		return
	end
	JobController.accept(offer.id)
end

-- A test-drive goal's route: to its display car itself when it has streamed in here (the Ohm pads stand behind the
-- showroom, well past the test-drive reach from the dealership's GPS point), else to the dealership. True when the
-- route ends at the car.
local function routeToTestCar(goal: Goals.Goal): boolean
	local vehicleId = goal.vehicleId
	local shown = if vehicleId ~= nil then displayCar(vehicleId) else nil
	if shown ~= nil then
		GpsController.setDestination(shown:GetPivot().Position, { name = Goals.titleOf(goal, Economy.formatCash) })
		return true
	end
	routeTo(goal)
	return false
end

local function testDrive(goal: Goals.Goal)
	local car = testCarInReach(goal)
	local vehicleId = goal.vehicleId
	local trim = if car ~= nil then car:GetAttribute(Dealership.prompt.trimAttribute) else nil
	if car == nil or vehicleId == nil or type(trim) ~= "string" then
		routedToCar = routeToTestCar(goal)
		NotifyController.show(text.goToCar, "info")
		return
	end
	local called, reply = pcall(Net.invokeServer, REMOTE_TEST_DRIVE, { vehicleId = vehicleId, trim = trim })
	showReply(called, reply)
end

-- Opens the AI Car Designer. Required when first needed: by the time anyone taps, every controller has loaded.
local function openDesigner()
	local module = script.Parent:FindFirstChild(DESIGNER_MODULE)
	if module == nil or not module:IsA("ModuleScript") then
		NotifyController.show(text.failed, "error")
		return
	end
	local ok, designer = pcall(require :: any, module)
	if ok and type(designer) == "table" and type(designer.openStudio) == "function" then
		designer.openStudio(true)
	else
		NotifyController.show(text.failed, "error")
	end
end

-- The card's button.
local function onCardAction()
	local card = GoalsController.cardFor(view.state, {
		jobRunning = view.jobRunning,
		nearCar = view.nearCar,
	}, Economy.formatCash)
	local goalId = if card ~= nil then card.goalId else nil
	if card == nil or goalId == nil then
		return
	end
	if card.collect then
		claim(goalId)
		return
	end
	local goal = pathById[goalId] or dailyById[goalId]
	if goal == nil then
		return
	end
	local action = goal.action
	if action == "startFare" then
		task.spawn(busyWhile, CARD_BUSY, function()
			startFare(false)
		end)
	elseif action == "testDrive" then
		task.spawn(busyWhile, CARD_BUSY, function()
			testDrive(goal)
		end)
	elseif action == "openDesigner" then
		openDesigner()
	elseif action == "gps" then
		routeTo(goal)
	end
end

local function openList()
	view.open = true
	render()
end

local function closeList()
	view.open = false
	render()
end

local function onGo(goalId: string)
	local goal = dailyById[goalId] or pathById[goalId]
	if goal ~= nil then
		routeTo(goal)
	end
	closeList()
end

local function onSkip()
	claim(Goals.path.skipId)
	closeList()
end

local function App(props: { view: View })
	local current = props.view
	local scale = current.scale
	local children: { [string]: any } = {
		Scale = e("UIScale", { Scale = scale }),
	}
	local state = current.state
	if not current.cutscene and state ~= nil then
		local placement = context()
		if current.open then
			local steps, daily = GoalsController.rowsFor(state, Economy.formatCash)
			local resetsIn = state.daily.resetsAt - Workspace:GetServerTimeNow()
			children.Sheet = e(GoalsSheet, {
				sheet = Layout.sheet(current.screen, placement),
				steps = steps,
				daily = daily,
				resetText = if state.daily.resetsAt > 0
					then string.format(text.resetsIn, GoalsController.durationText(resetsIn))
					else nil,
				busyId = current.busy,
				onClose = closeList,
				onClaim = claim,
				onGo = onGo,
				onSkip = onSkip,
			})
		else
			local card = GoalsController.cardFor(state, {
				jobRunning = current.jobRunning,
				nearCar = current.nearCar,
			}, Economy.formatCash)
			if card ~= nil then
				local rect, shape = GoalsController.placeCard(current.screen, placement, card.kind == "pill")
				children.Card = e(GoalCard, {
					rect = rect,
					shape = shape,
					card = card,
					busy = current.busy ~= nil,
					onAction = onCardAction,
					onOpen = openList,
				})
			end
		end
	end
	return e("Frame", {
		Size = UDim2.fromScale(1 / scale, 1 / scale),
		BackgroundTransparency = 1,
	}, children)
end

render = function()
	if root ~= nil then
		root:render(e(App, { view = table.clone(view) }))
	end
end

-- Following the game -------------------------------------------------------------------------------------------------

local function stopNearTicker()
	if nearTicker ~= nil then
		nearTicker:Disconnect()
		nearTicker = nil
	end
end

local function checkNear()
	local goal = currentStepGoal()
	local near = goal ~= nil and goal.action == "testDrive" and testCarInReach(goal) ~= nil
	if near ~= view.nearCar then
		view.nearCar = near
		render()
	end
	-- The step's route went to the dealership because its car hadn't streamed in: once it has, carry the route on to
	-- the car (also when the player has just arrived at the dealership and the route cleared), so one tap is enough.
	-- A route the player set themselves is left alone.
	if goal == nil or goal.action ~= "testDrive" or near or routedToCar or routedStep ~= goal.id then
		return
	end
	local vehicleId = goal.vehicleId
	if vehicleId == nil or displayCar(vehicleId) == nil then
		return
	end
	local destination = GpsController.getDestination()
	if destination == nil or destination.id == goal.gpsTo then
		routedToCar = routeToTestCar(goal)
	end
end

-- Watches the distance to the test-drive step's car only while that step is on the card.
local function syncNearTicker()
	local goal = currentStepGoal()
	if goal ~= nil and goal.action == "testDrive" then
		if nearTicker == nil then
			sinceNearCheck = 0
			nearTicker = RunService.Heartbeat:Connect(function(dt: number)
				sinceNearCheck += dt
				if sinceNearCheck >= Goals.path.nearCheckSeconds then
					sinceNearCheck = 0
					checkNear()
				end
			end)
		end
	else
		stopNearTicker()
		view.nearCar = false
	end
end

-- Points the GPS at the current path step's place, once per step, while no route is set.
local function routeForStep()
	local state = view.state
	local path = if state ~= nil then state.path else nil
	local current = if path ~= nil then path.current else nil
	if current == nil or current == routedStep then
		return
	end
	local goal = pathById[current]
	if goal.gpsTo == nil then
		routedStep = current
		return
	end
	if view.jobRunning or GpsController.getDestination() ~= nil then
		return -- tried again when the job ends or the route clears
	end
	routedStep = current
	if goal.action == "testDrive" then
		routedToCar = routeToTestCar(goal)
	else
		routeTo(goal)
	end
end

-- The first fare starts by itself once a session, early on, when everything is ready for it.
local function maybeAutoStart()
	local goal = currentStepGoal()
	if autoStarted or goal == nil or goal.action ~= "startFare" then
		return
	end
	local now = os.clock()
	local deadline: number = autoStartDeadline or now + Goals.path.autoStartSeconds
	autoStartDeadline = deadline
	if now > deadline or view.busy ~= nil or view.jobRunning or not inOwnCar() then
		return
	end
	if GoalsController.nearestFare(JobController.get().offers) == nil then
		return
	end
	autoStarted = true
	task.spawn(busyWhile, CARD_BUSY, function()
		startFare(true)
	end)
end

local function onGoals(payload: any)
	local state = GoalsController.normalize(payload)
	if state == nil then
		warn("[GoalsController] ignored a GoalsUpdate that isn't one")
		return
	end
	view.state = state
	syncNearTicker()
	routeForStep()
	maybeAutoStart()
	render()
end

local function onJobs(jobs: JobController.View)
	local running = jobs.job ~= nil
	if running ~= view.jobRunning then
		view.jobRunning = running
		render()
	end
	routeForStep()
	maybeAutoStart()
end

local function onCutsceneChanged()
	local cutscene = Players.LocalPlayer:GetAttribute(PhoneConfig.cutsceneAttribute) == true
	if cutscene ~= view.cutscene then
		view.cutscene = cutscene
		render()
	end
end

-- Boot ----------------------------------------------------------------------------------------------------------

function GoalsController:Start()
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")

	local gui = Instance.new("ScreenGui")
	gui.Name = GUI_NAME
	gui.ResetOnSpawn = false -- one GUI for the whole session
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.DisplayOrder = Theme.displayOrder.gps -- above the HUD, under the phone and the shop sheets
	gui.ScreenInsets = Enum.ScreenInsets.CoreUISafeInsets
	gui.Parent = playerGui

	root = ReactRoblox.createRoot(gui)
	view.scale = HudController.scaleFor(gui.AbsoluteSize)
	view.screen = Layout.layoutSize(gui.AbsoluteSize, view.scale)
	view.inputKind = HudController.getInputKind()
	view.driving = DriveController.getCar() ~= nil
	gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		view.scale = HudController.scaleFor(gui.AbsoluteSize)
		view.screen = Layout.layoutSize(gui.AbsoluteSize, view.scale)
		render()
	end)
	HudController.onInputKindChanged:Connect(function(kind: string)
		view.inputKind = kind
		render()
	end)
	DriveController.onDrivingChanged:Connect(function(driving: boolean)
		view.driving = driving
		render()
		maybeAutoStart()
	end)
	Players.LocalPlayer:GetAttributeChangedSignal(PhoneConfig.cutsceneAttribute):Connect(onCutsceneChanged)
	onCutsceneChanged()

	JobController.onChanged:Connect(onJobs)
	onJobs(JobController.get())

	Net.onClientEvent(REMOTE_UPDATE, onGoals)
	render()
end

return GoalsController
