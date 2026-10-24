--!strict
-- Goals (roast fixes 2026-10-24, docs/roast-2026-10-24.md point 8 "The first five minutes have no hook"; point 6's
-- passenger): Config/Goals' numbers against the economy and the map, Services/GoalsService's rules (the goals day and
-- its reset, which goals a day has, what an event counts, collecting once only, skipping the path, the payload),
-- Services/SpawnFlowService's first-spawn pose on the real roads, Controllers/GoalsController's card, its place clear
-- of the HUD on real screen sizes and the list's rows, and Controllers/JobVisualsController's seated passenger.
-- Pure logic: runs in Edit mode.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local StarterPlayer = game:GetService("StarterPlayer")

local Catalog = require(ReplicatedStorage.Shared.Vehicle.Catalog)
local Economy = require(ReplicatedStorage.Shared.Config.Economy)
local Goals = require(ReplicatedStorage.Shared.Config.Goals)
local Graph = require(ReplicatedStorage.Shared.Road.Graph)
local Harness = require(ReplicatedStorage.Shared.Testing.Harness)
local Jobs = require(ReplicatedStorage.Shared.Config.Jobs)
local MapLayout = require(ReplicatedStorage.Shared.Config.MapLayout)
local Types = require(ReplicatedStorage.Shared.Types)
local World = require(ReplicatedStorage.Shared.Config.World)
local Services = ServerScriptService.Server.Services
local GoalsService = require(Services.GoalsService)
local SpawnFlowService = require(Services.SpawnFlowService)
local Template = require(Services.DataService.Template)

local Client = StarterPlayer.StarterPlayerScripts.Client
local ArcFlyoverController = require(Client.Controllers.ArcFlyoverController)
local GoalsController = require(Client.Controllers.GoalsController)
local JobVisualsController = require(Client.Controllers.JobVisualsController)
local Layout = require(Client.UI.Phone.Layout)

local DAY = 86400
local HOUR = 3600
local RESET = Goals.daily.resetHourUtc * HOUR
local TODAY = 20748 -- a goals day
local NOW = TODAY * DAY + RESET + 5 * HOUR -- five hours into it
local TOMORROW = NOW + DAY
local ID_LENGTH = 40 -- Net ClaimGoal's goalId limit
local formatCash = Economy.formatCash

local pathGoals = Goals.path.goals

-- Fresh goals with today's daily goals picked.
local function newGoals(pathDone: boolean): Types.GoalsData
	local goals = Template.goals(pathDone)
	GoalsService.roll(goals, NOW)
	return goals
end

-- Today's goal that counts `counter` (its id), or nil.
local function todays(goals: Types.GoalsData, counter: string): string?
	for _, id in goals.daily.ids do
		local goal = GoalsService.goal(id)
		if goal ~= nil and goal.counter == counter then
			return id
		end
	end
	return nil
end

-- A goals day whose goals include one of `counter` (searching forward from TODAY).
local function dayWith(counter: string): number
	for day = TODAY, TODAY + 60 do
		for _, id in GoalsService.dailyFor(day) do
			local goal = GoalsService.goal(id)
			if goal ~= nil and goal.counter == counter then
				return day
			end
		end
	end
	error(`no day in the next 60 has a {counter} goal`)
end

local function timeOn(day: number): number
	return day * DAY + RESET + HOUR
end

local function everyGoal(): { Goals.Goal }
	local list: { Goals.Goal } = table.clone(pathGoals)
	for _, slot in Goals.daily.slots do
		for _, goal in slot do
			table.insert(list, goal)
		end
	end
	return list
end

local COUNTERS = {
	job = true,
	testDrive = true,
	design = true,
	miles = true,
	charge = true,
	meet = true,
	earn = true,
	house = true,
}

-- Screens in UI-scale-1 px and what is on them.
type Screen = { label: string, size: Vector2, context: Layout.Context }
local SCREENS: { Screen } = {
	{
		label = "small landscape phone, driving on touch",
		size = Vector2.new(667, 375),
		context = { driving = true, touch = true, hints = false },
	},
	{
		label = "small landscape phone, on foot",
		size = Vector2.new(667, 375),
		context = { driving = false, touch = false, hints = false },
	},
	{
		label = "landscape phone, driving on touch",
		size = Vector2.new(844, 390),
		context = { driving = true, touch = true, hints = false },
	},
	{
		label = "portrait phone, driving on touch",
		size = Vector2.new(375, 667),
		context = { driving = true, touch = true, hints = false },
	},
	{
		label = "desktop, driving with keys",
		size = Vector2.new(1024, 576),
		context = { driving = true, touch = false, hints = true },
	},
}

local function stateOf(goals: Types.GoalsData): GoalsController.State
	local state = GoalsController.normalize(GoalsService.payload(goals, NOW))
	assert(state ~= nil, "the payload normalizes")
	return state
end

return function(t: Harness.Api)
	t.describe("Goals config", function()
		t.it("has unique goal ids that fit Net ClaimGoal, and a skip id that is none of them", function()
			local seen: { [string]: boolean } = {}
			for _, goal in everyGoal() do
				t.expect(seen[goal.id]).toBe(nil)
				seen[goal.id] = true
				t.expect(#goal.id <= ID_LENGTH).toBe(true)
			end
			t.expect(seen[Goals.path.skipId]).toBe(nil)
			t.expect(#Goals.path.skipId <= ID_LENGTH).toBe(true)
		end)

		t.it("names only counters, job types, cars and places that exist", function()
			local places: { [string]: boolean } = {}
			for _, location in MapLayout.locations do
				places[location.id] = true
			end
			for _, goal in everyGoal() do
				t.expect(`{goal.id} {COUNTERS[goal.counter] == true}`).toBe(`{goal.id} true`)
				if goal.jobType ~= nil then
					t.expect(Jobs.types[goal.jobType] ~= nil).toBe(true)
				end
				if goal.vehicleId ~= nil then
					local vehicle = Catalog.getVehicle(goal.vehicleId)
					t.expect(vehicle ~= nil and vehicle.playerDrivable).toBe(true)
				end
				if goal.gpsTo ~= nil then
					t.expect(`{goal.id} {places[goal.gpsTo] == true}`).toBe(`{goal.id} true`)
				end
				if goal.action ~= nil then
					t.expect(goal.actionLabel ~= nil).toBe(true)
				end
				if goal.action == "gps" or goal.action == "testDrive" then
					t.expect(goal.gpsTo ~= nil).toBe(true)
				end
				t.expect((string.find(Goals.titleOf(goal, formatCash), "%", 1, true))).toBe(nil)
			end
		end)

		t.it("pays whole dollars, nothing random, and never enough to skip the price ladder", function()
			local pathTotal = 0
			for _, goal in pathGoals do
				t.expect(goal.reward > 0 and goal.reward % 1 == 0).toBe(true)
				t.expect(goal.target).toBe(1) -- one event finishes a step
				pathTotal += goal.reward
			end
			local spark = Catalog.totalPrice("ohm_spark", "standard") :: number
			local rideshareMinute = Economy.activities.rideshare
			-- The whole path is worth under a fifth of the first new car and under ten minutes of rideshare.
			t.expect(pathTotal * 5 <= spark).toBe(true)
			t.expect(pathTotal <= 10 * rideshareMinute).toBe(true)
			-- The first-ride bonus is a thrill: more than the starting wallet, and more than a minute of rideshare.
			local bonus = pathGoals[1].reward
			t.expect(pathGoals[1].id).toBe("firstFare")
			t.expect(bonus > Economy.startingCash).toBe(true)
			t.expect(bonus > rideshareMinute).toBe(true)
			-- A whole day of daily goals: at most ten minutes of rideshare.
			local dayMax = 0
			for _, slot in Goals.daily.slots do
				local best = 0
				for _, goal in slot do
					t.expect(goal.reward > 0 and goal.reward % 1 == 0).toBe(true)
					t.expect(goal.target > 0).toBe(true)
					best = math.max(best, goal.reward)
				end
				dayMax += best
			end
			t.expect(dayMax <= 10 * rideshareMinute).toBe(true)
		end)

		t.it("has three daily slots of at least two goals, so one day's goals differ from the next", function()
			t.expect(#Goals.daily.slots).toBe(3)
			for _, slot in Goals.daily.slots do
				t.expect(#slot >= 2).toBe(true)
			end
			t.expect(Goals.daily.resetHourUtc >= 0 and Goals.daily.resetHourUtc < 24).toBe(true)
		end)
	end)

	t.describe("Goals days", function()
		t.it("starts a goals day at the reset hour", function()
			t.expect(GoalsService.dayOf(TODAY * DAY + RESET)).toBe(TODAY)
			t.expect(GoalsService.dayOf(TODAY * DAY + RESET - 1)).toBe(TODAY - 1)
			t.expect(GoalsService.dayOf(NOW)).toBe(TODAY)
			t.expect(GoalsService.nextResetAt(NOW)).toBe((TODAY + 1) * DAY + RESET)
			t.expect(GoalsService.nextResetAt(TODAY * DAY + RESET)).toBe((TODAY + 1) * DAY + RESET)
		end)

		t.it("picks one goal from each slot a day, the same every time, and steps each slot on a day", function()
			local today = GoalsService.dailyFor(TODAY)
			t.expect(#today).toBe(#Goals.daily.slots)
			for index, id in today do
				local inSlot = false
				for _, goal in Goals.daily.slots[index] do
					inSlot = inSlot or goal.id == id
				end
				t.expect(inSlot).toBe(true)
			end
			t.expect(GoalsService.dailyFor(TODAY)).toEqual(today)
			local tomorrow = GoalsService.dailyFor(TODAY + 1)
			for index in today do
				t.expect(tomorrow[index] ~= today[index]).toBe(true)
			end
		end)

		t.it("rolls to a new day's goals with nothing done, and leaves the same day alone", function()
			local goals = newGoals(true)
			t.expect(goals.daily.day).toBe(TODAY)
			t.expect(goals.daily.ids).toEqual(GoalsService.dailyFor(TODAY))
			local first = goals.daily.ids[1]
			goals.daily.progress[first] = 1
			goals.daily.claimed[first] = true
			t.expect(GoalsService.roll(goals, NOW + HOUR)).toBe(false)
			t.expect(goals.daily.claimed[first]).toBe(true)
			t.expect(GoalsService.roll(goals, TOMORROW)).toBe(true)
			t.expect(goals.daily.day).toBe(TODAY + 1)
			t.expect(goals.daily.ids).toEqual(GoalsService.dailyFor(TODAY + 1))
			t.expect(goals.daily.progress).toEqual({})
			t.expect(goals.daily.claimed).toEqual({})
		end)
	end)

	t.describe("Goals counting", function()
		t.it("finishes a path step on its own event only", function()
			local goals = newGoals(false)
			-- A delivery isn't a fare, and a test drive of another car isn't the Arc.
			t.expect(GoalsService.record(goals, "job", 1, { jobType = "delivery" }, NOW).finished).toEqual({})
			t.expect(GoalsService.record(goals, "testDrive", 1, { vehicleId = "ohm_spark" }, NOW).finished).toEqual({})
			t.expect(goals.path.finished).toEqual({})
			t.expect(GoalsService.record(goals, "job", 1, { jobType = "rideshare" }, NOW).finished)
				.toEqual({ "firstFare" })
			t.expect(GoalsService.record(goals, "testDrive", 1, { vehicleId = "ohm_arc" }, NOW).finished).toEqual({
				"testDriveArc",
			})
			-- Once is enough.
			t.expect(GoalsService.record(goals, "job", 1, { jobType = "rideshare" }, NOW).finished).toEqual({})
		end)

		t.it("ignores the path once it is done", function()
			local goals = newGoals(true)
			GoalsService.record(goals, "job", 1, { jobType = "rideshare" }, NOW)
			GoalsService.record(goals, "design", 1, nil, NOW)
			t.expect(goals.path.finished).toEqual({})
			t.expect(GoalsService.currentStep(goals)).toBe(nil)
		end)

		t.it("moves today's goals toward their targets, never past them, and says when one is ready", function()
			local day = dayWith("miles")
			local now = timeOn(day)
			local goals = Template.goals(true)
			GoalsService.roll(goals, now)
			local id = todays(goals, "miles") :: string
			local target = (GoalsService.goal(id) :: Goals.Goal).target
			t.expect(GoalsService.record(goals, "miles", target / 2, nil, now).ready).toEqual({})
			t.expect(goals.daily.progress[id]).toBeNear(target / 2, 1e-9)
			t.expect(GoalsService.milesLeft(goals, now) :: number).toBeNear(target / 2, 1e-9)
			t.expect(GoalsService.record(goals, "miles", target, nil, now).ready).toEqual({ id })
			t.expect(goals.daily.progress[id]).toBe(target)
			t.expect(GoalsService.milesLeft(goals, now)).toBe(nil)
			-- Past the target nothing moves and nothing is ready again.
			t.expect(GoalsService.record(goals, "miles", 5, nil, now).ready).toEqual({})
			t.expect(GoalsService.wants(goals, "miles", nil, now)).toBe(false)
		end)

		t.it("counts nothing for a bad amount or another counter", function()
			local goals = newGoals(false)
			local before = table.clone(goals.daily.progress)
			for _, bad in { 0, -3, 0 / 0, math.huge } do
				GoalsService.record(goals, "earn", bad, nil, NOW)
				GoalsService.record(goals, "job", bad, { jobType = "rideshare" }, NOW)
			end
			t.expect(goals.daily.progress).toEqual(before)
			t.expect(goals.path.finished).toEqual({})
		end)

		t.it("wants an event only when it can move something", function()
			local goals = newGoals(true)
			local day = dayWith("earn")
			local now = timeOn(day)
			GoalsService.roll(goals, now)
			t.expect(GoalsService.wants(goals, "earn", nil, now)).toBe(true)
			t.expect(GoalsService.wants(goals, "design", nil, now)).toBe(false) -- no design goal, path done
			GoalsService.record(goals, "earn", 1e9, nil, now)
			t.expect(GoalsService.wants(goals, "earn", nil, now)).toBe(false)
			-- A new path still wants its steps' events; a day that has to roll wants what tomorrow counts.
			t.expect(GoalsService.wants(newGoals(false), "design", nil, NOW)).toBe(true)
			local stale = newGoals(true)
			local tomorrowCounter = (GoalsService.goal(GoalsService.dailyFor(TODAY + 1)[1]) :: Goals.Goal).counter
			t.expect(GoalsService.wants(stale, tomorrowCounter, { jobType = "rideshare" }, TOMORROW)).toBe(true)
		end)

		t.it(
			"counts driving, job and fleet cash toward earn goals, and never rewards, codes, sales or purchases",
			function()
				t.expect(GoalsService.earnCounts("drive")).toBe(true)
				t.expect(GoalsService.earnCounts("fleet")).toBe(true)
				t.expect(GoalsService.earnCounts("job:rideshare")).toBe(true)
				t.expect(GoalsService.earnCounts("job:freight")).toBe(true)
				for _, reason in { Goals.economyReason, "code", "purchase", "sell", "refund", "dev", "streak" } do
					t.expect(`{reason} {GoalsService.earnCounts(reason)}`).toBe(`{reason} false`)
				end
			end
		)
	end)

	t.describe("Goals collecting", function()
		t.it("pays a daily goal once only", function()
			local day = dayWith("job")
			local now = timeOn(day)
			local goals = Template.goals(true)
			GoalsService.roll(goals, now)
			local id = todays(goals, "job") :: string
			local goal = GoalsService.goal(id) :: Goals.Goal
			local reward, refusal = GoalsService.claimIn(goals, id, now)
			t.expect(reward).toBe(nil)
			t.expect(refusal).toBe("notFinished")
			GoalsService.record(goals, "job", goal.target, { jobType = goal.jobType or "rideshare" }, now)
			local paid, why = GoalsService.claimIn(goals, id, now)
			t.expect(paid).toBe(goal.reward)
			t.expect(why).toBe(nil)
			t.expect(goals.daily.claimed[id]).toBe(true)
			local again, second = GoalsService.claimIn(goals, id, now)
			t.expect(again).toBe(nil)
			t.expect(second).toBe("claimed")
			-- A collected goal counts nothing more.
			t.expect(GoalsService.record(goals, "job", 1, { jobType = goal.jobType or "rideshare" }, now).ready)
				.toEqual({})
		end)

		t.it("refuses a goal that isn't on today's list, and one the reset took away", function()
			local goals = newGoals(true)
			local notToday: string? = nil
			for _, slot in Goals.daily.slots do
				for _, goal in slot do
					if table.find(goals.daily.ids, goal.id) == nil then
						notToday = goal.id
					end
				end
			end
			local _, refusal = GoalsService.claimIn(goals, notToday :: string, NOW)
			t.expect(refusal).toBe("unknown")
			local _, nonsense = GoalsService.claimIn(goals, "not-a-goal", NOW)
			t.expect(nonsense).toBe("unknown")

			-- Finished yesterday, claimed after the reset: gone, and today's goals are in.
			local id = goals.daily.ids[1]
			goals.daily.progress[id] = (GoalsService.goal(id) :: Goals.Goal).target
			local reward, expired = GoalsService.claimIn(goals, id, TOMORROW)
			t.expect(reward).toBe(nil)
			t.expect(expired).toBe("expired")
			t.expect(goals.daily.day).toBe(TODAY + 1)
			t.expect(goals.daily.progress).toEqual({})
		end)

		t.it("pays each path step once, ends the path with the last, and shows the next step meanwhile", function()
			local goals = newGoals(false)
			t.expect(GoalsService.currentStep(goals)).toBe("firstFare")
			local _, early = GoalsService.claimIn(goals, "firstFare", NOW)
			t.expect(early).toBe("notFinished")
			local total = 0
			for index, goal in pathGoals do
				t.expect(GoalsService.currentStep(goals)).toBe(goal.id)
				goals.path.finished[goal.id] = true
				local reward = GoalsService.claimIn(goals, goal.id, NOW)
				t.expect(reward).toBe(goal.reward)
				total += reward :: number
				local _, twice = GoalsService.claimIn(goals, goal.id, NOW)
				t.expect(twice).toBe("claimed")
				t.expect(goals.path.done).toBe(index == #pathGoals)
			end
			t.expect(GoalsService.currentStep(goals)).toBe(nil)
			local expected = 0
			for _, goal in pathGoals do
				expected += goal.reward
			end
			t.expect(total).toBe(expected)
		end)

		t.it("skips the path for good without paying", function()
			local goals = newGoals(false)
			t.expect(GoalsService.skip(goals)).toBe(true)
			t.expect(goals.path.done).toBe(true)
			t.expect(GoalsService.skip(goals)).toBe(false)
			goals.path.finished.firstFare = true
			local reward, refusal = GoalsService.claimIn(goals, "firstFare", NOW)
			t.expect(reward).toBe(nil)
			t.expect(refusal).toBe("done")
			t.expect(GoalsService.record(goals, "design", 1, nil, NOW).finished).toEqual({})
		end)
	end)

	t.describe("Goals payload", function()
		t.it("sends the path while it runs and today's goals with the next reset", function()
			local goals = newGoals(false)
			goals.path.finished.firstFare = true
			goals.path.claimed.firstFare = true
			local payload = GoalsService.payload(goals, NOW)
			local path = payload.path :: any
			t.expect(path.current).toBe("testDriveArc")
			t.expect(#path.steps).toBe(#pathGoals)
			t.expect(path.steps[1]).toEqual({ id = "firstFare", finished = true, claimed = true })
			t.expect(payload.daily.day).toBe(TODAY)
			t.expect(payload.daily.resetsAt).toBe(GoalsService.nextResetAt(NOW))
			t.expect(#payload.daily.goals).toBe(#goals.daily.ids)
			t.expect(GoalsService.payload(newGoals(true), NOW).path).toBe(nil)
		end)

		t.it("survives the trip to the client: the client reads the same goals back", function()
			local goals = newGoals(false)
			goals.daily.progress[goals.daily.ids[1]] = 1
			local state = stateOf(goals)
			t.expect((state.path :: any).current).toBe("firstFare")
			t.expect(#state.daily.goals).toBe(#goals.daily.ids)
			t.expect(state.daily.goals[1].progress).toBe(1)
			-- Junk and unknown goals are dropped.
			t.expect(GoalsController.normalize("nope")).toBe(nil)
			local odd = GoalsController.normalize({
				daily = { day = TODAY, resetsAt = 0, goals = { { id = "made-up", progress = 1 }, "junk" } :: { any } },
				path = { steps = { { id = "made-up" } }, current = "made-up" },
			}) :: GoalsController.State
			t.expect(odd.daily.goals).toEqual({})
			t.expect((odd.path :: any).current).toBe(nil)
		end)
	end)

	t.describe("Goals first spawn", function()
		t.it("puts the starter on a road near each spot, in its right-hand lane, facing toward downtown", function()
			local settings = Goals.firstSpawn
			local offset = settings.laneOffset * World.laneWidth
			for _, near in settings.spots do
				local pose = SpawnFlowService.viewPose(Graph, near, settings.lookToward, offset, settings.maxSnap)
				t.expect(pose ~= nil).toBe(true)
				local frame = pose :: CFrame
				t.expect(Graph.isOnRoad(frame.Position)).toBe(true)
				local toward = Vector3.new(settings.lookToward.X - frame.X, 0, settings.lookToward.Z - frame.Z)
				t.expect(frame.LookVector:Dot(toward.Unit) > 0).toBe(true)
				t.expect(math.abs(frame.LookVector.Y) < 1e-3).toBe(true) -- level
				-- The road's centre line is to the car's left, `offset` studs away.
				local _, _, _, road = Graph.nearestEdge(near)
				local fromCentre = Vector3.new(frame.X - road.X, 0, frame.Z - road.Z)
				t.expect(fromCentre.Magnitude).toBeNear(offset, 1e-3)
				t.expect(fromCentre:Dot(frame.RightVector) > 0).toBe(true)
			end
		end)

		t.it("finds no pose far from every road", function()
			local settings = Goals.firstSpawn
			local far = Vector3.new(World.mapHalfExtent * 3, 0, World.mapHalfExtent * 3)
			t.expect(SpawnFlowService.viewPose(Graph, far, settings.lookToward, 0, settings.maxSnap)).toBe(nil)
		end)

		t.it("flies the Arc over the starter: from behind, over the roof, down ahead", function()
			local flyover = Goals.firstSpawn.flyover
			t.expect(Catalog.getVehicle(flyover.vehicleId) ~= nil).toBe(true)
			t.expect(flyover.seconds).toBeGreaterThan(0)
			t.expect(flyover.rollSeconds).toBeGreaterThan(0)
			t.expect(flyover.delaySeconds < flyover.maxAgeSeconds).toBe(true)
			local from, to = Vector3.new(0, 0, 60), Vector3.new(0, 0, -110)
			local peak = flyover.peakHeight
			local start = ArcFlyoverController.hopFrame(from, to, peak, 0)
			t.expect((start.Position - from).Magnitude).toBeNear(0, 1e-6)
			t.expect(start.LookVector.Y > 0).toBe(true) -- nose up at take-off
			local top = ArcFlyoverController.hopFrame(from, to, peak, 0.5)
			t.expect(top.Position.Y).toBeNear(peak, 1e-6)
			t.expect(math.abs(top.LookVector.Y) < 1e-6).toBe(true) -- level at the top
			t.expect(top.LookVector.Z < 0).toBe(true) -- still heading for `to`
			local land = ArcFlyoverController.hopFrame(from, to, peak, 1)
			t.expect((land.Position - to).Magnitude).toBeNear(0, 1e-6)
			t.expect(land.LookVector.Y < 0).toBe(true) -- nose down onto the road
			-- High enough to clear a car's roof (the tallest bodies are about 7 studs).
			t.expect(peak > 2 * 7).toBe(true)
		end)
	end)

	t.describe("Goals card", function()
		local quiet: GoalsController.Context = { jobRunning = false, nearCar = false }

		t.it("shows the path's current step with its bonus and the button that does it", function()
			local goals = newGoals(false)
			local card = GoalsController.cardFor(stateOf(goals), quiet, formatCash) :: any
			t.expect(card.kind).toBe("path")
			t.expect(card.goalId).toBe("firstFare")
			t.expect(card.actionLabel).toBe(pathGoals[1].actionLabel)
			t.expect(string.find(card.eyebrow, formatCash(pathGoals[1].reward), 1, true) ~= nil).toBe(true)
			t.expect(card.collect).toBe(false)
			-- Hidden while the fare runs: the HUD's job slot says what to do.
			t.expect(GoalsController.cardFor(stateOf(goals), { jobRunning = true, nearCar = false }, formatCash))
				.toBe(nil)
		end)

		t.it("says Go far from the test-drive car and Test drive beside it", function()
			local goals = newGoals(false)
			goals.path.finished.firstFare = true
			goals.path.claimed.firstFare = true
			local step = pathGoals[2]
			local far = GoalsController.cardFor(stateOf(goals), quiet, formatCash) :: any
			t.expect(far.goalId).toBe(step.id)
			t.expect(far.actionLabel).toBe(step.goLabel)
			local near =
				GoalsController.cardFor(stateOf(goals), { jobRunning = false, nearCar = true }, formatCash) :: any
			t.expect(near.actionLabel).toBe(step.actionLabel)
			t.expect(near.shortLabel).toBe(step.shortLabel)
		end)

		t.it("offers a ready daily goal's reward, else the small goals button", function()
			local goals = newGoals(true)
			local pill = GoalsController.cardFor(stateOf(goals), quiet, formatCash) :: any
			t.expect(pill.kind).toBe("pill")
			t.expect(pill.title).toBe(string.format(Goals.text.dailyPill, 0, #goals.daily.ids))
			local id = goals.daily.ids[2]
			local goal = GoalsService.goal(id) :: Goals.Goal
			goals.daily.progress[id] = goal.target
			local ready =
				GoalsController.cardFor(stateOf(goals), { jobRunning = true, nearCar = false }, formatCash) :: any
			t.expect(ready.kind).toBe("daily")
			t.expect(ready.goalId).toBe(id)
			t.expect(ready.collect).toBe(true)
			t.expect(ready.actionLabel).toBe(string.format(Goals.text.collect, formatCash(goal.reward)))
			goals.daily.claimed[id] = true
			local after = GoalsController.cardFor(stateOf(goals), quiet, formatCash) :: any
			t.expect(after.title).toBe(string.format(Goals.text.dailyPill, 1, #goals.daily.ids))
			t.expect(GoalsController.cardFor(nil, quiet, formatCash)).toBe(nil)
		end)

		t.it("sits clear of the HUD and the driving controls on every screen", function()
			for _, screen in SCREENS do
				for _, pill in { false, true } do
					local rect, shape = GoalsController.placeCard(screen.size, screen.context, pill)
					local label = `{screen.label} ({shape})`
					t.expect(`{label} {Layout.contains(Layout.screen(screen.size), rect)}`).toBe(`{label} true`)
					for index, blocker in GoalsController.cardBlockers(screen.size, screen.context) do
						t.expect(`{label} vs blocker {index}: {Layout.overlaps(rect, blocker)}`)
							.toBe(`{label} vs blocker {index}: false`)
					end
					t.expect(Layout.height(rect) >= 44).toBe(true) -- a touch target
				end
			end
		end)

		t.it("takes the tall card where it fits and the compact one on a small phone driving on touch", function()
			local _, roomy = GoalsController.placeCard(Vector2.new(844, 390), SCREENS[3].context, false)
			t.expect(roomy).toBe("tall")
			local _, small = GoalsController.placeCard(Vector2.new(667, 375), SCREENS[1].context, false)
			t.expect(small).toBe("compact")
			local _, onFoot = GoalsController.placeCard(Vector2.new(667, 375), SCREENS[2].context, false)
			t.expect(onFoot).toBe("tall")
		end)

		t.it("starts the rideshare fare with the least driving", function()
			local function offer(id: string, kind: string, distance: number): any
				return {
					id = id,
					type = kind,
					title = id,
					subtitle = "",
					pay = 1,
					distance = distance,
					stops = 2,
					xl = false,
				}
			end
			local offers = { offer("a", "rideshare", 1900), offer("b", "delivery", 300), offer("c", "rideshare", 1200) }
			t.expect((GoalsController.nearestFare(offers) :: any).id).toBe("c")
			t.expect(GoalsController.nearestFare({ offer("d", "delivery", 10) })).toBe(nil)
		end)

		t.it("writes the list's rows and the time to the reset", function()
			local goals = newGoals(false)
			goals.path.finished.firstFare = true
			goals.path.claimed.firstFare = true
			local steps, daily = GoalsController.rowsFor(stateOf(goals), formatCash)
			local rows = steps :: { GoalsController.StepRow }
			t.expect(#rows).toBe(#pathGoals)
			t.expect(rows[1].claimed).toBe(true)
			t.expect(rows[2].current).toBe(true)
			t.expect(#daily).toBe(#goals.daily.ids)
			for _, row in daily do
				t.expect(row.progress).toBe(0)
				t.expect(row.ready).toBe(false)
			end
			t.expect(GoalsController.durationText(5 * HOUR + 12 * 60))
				.toBe(string.format(Goals.text.hoursMinutes, 5, 12))
			t.expect(GoalsController.durationText(90)).toBe(string.format(Goals.text.minutes, 2))
			t.expect(GoalsController.durationText(0)).toBe(string.format(Goals.text.minutes, 1))
		end)
	end)

	t.describe("Goals passenger", function()
		t.it("sits with the legs forward from the hips and the head over the seat", function()
			local frames = JobVisualsController.figureFrames("sit", 0)
			local legLength = JobVisualsController.look.figure.legSize.Y
			for _, name in { "LeftLeg", "RightLeg" } do
				local leg = frames[name]
				t.expect(leg.Position.Z).toBeNear(-legLength / 2, 1e-6) -- forward of the hips (-Z)
				t.expect(math.abs(leg.UpVector.Z)).toBeNear(1, 1e-6) -- lying along the seat
			end
			t.expect(frames.Head.Position.X).toBeNear(0, 1e-6)
			t.expect(frames.Head.Position.Z).toBeNear(0, 1e-6)
			-- Standing, the same figure's feet are on the ground and its head higher than sitting.
			local standing = JobVisualsController.figureFrames("stand", 0)
			t.expect(standing.Head.Position.Y > frames.Head.Position.Y).toBe(true)
			t.expect(standing.LeftLeg.Position.Y).toBeNear(legLength / 2, 1e-6)
		end)

		t.it("shrinks a seated passenger only as much as the cabin needs", function()
			local min = JobVisualsController.look.passenger.minScale
			t.expect(JobVisualsController.seatedScale(100)).toBe(1)
			t.expect(JobVisualsController.seatedScale(0)).toBe(min)
			local fits = JobVisualsController.seatedScale(3.2)
			t.expect(fits <= 1 and fits >= min).toBe(true)
			-- At that scale the head (with its hair) stays under the roof.
			local look = JobVisualsController.look.figure
			local top = (look.torsoSize.Y + look.neck + look.headSize.Y + look.hairHeight - look.hairOverhang) * fits
			t.expect(top <= 3.2 - JobVisualsController.look.passenger.headroomMargin + 1e-6).toBe(true)
		end)

		t.it("gets in and out on the side of the car its seat is on", function()
			local car = CFrame.new(10, 0, 5) * CFrame.Angles(0, math.rad(90), 0)
			t.expect(JobVisualsController.doorSide(car, car * Vector3.new(1.5, 1, -1))).toBe(1)
			t.expect(JobVisualsController.doorSide(car, car * Vector3.new(-1.5, 1, 2))).toBe(-1)
		end)
	end)
end
