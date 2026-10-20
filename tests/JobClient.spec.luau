--!strict
-- The jobs client (docs/phase-6-contracts.md "Client"), as pure logic: JobController's checks of a JobUpdate (the
-- active job and its deadline, offers, availability, levels from the server's progress), the HUD slot's texts (the
-- stop, distance and time left, amber then red as time runs short), eligibility and class lists, the GPS decision
-- (route to each stop, clear only the job's own route), JobVisualsController's markers and where its figures and
-- parcels stand (off the road, facing it), and where the HUD's job slot sits on landscape phones, tablets and
-- desktops (clear of the notices, the GPS chip, the phone button, the speed panel and the touch controls). Runs in
-- Edit mode and never touches module state.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")

local Catalog = require(ReplicatedStorage.Shared.Vehicle.Catalog)
local Classes = require(ReplicatedStorage.Shared.Config.Classes)
local Economy = require(ReplicatedStorage.Shared.Config.Economy)
local Graph = require(ReplicatedStorage.Shared.Road.Graph)
local Harness = require(ReplicatedStorage.Shared.Testing.Harness)
local Jobs = require(ReplicatedStorage.Shared.Config.Jobs)
local MapLayout = require(ReplicatedStorage.Shared.Config.MapLayout)

local Client = StarterPlayer.StarterPlayerScripts.Client
local HudController = require(Client.Controllers.HudController)
local JobController = require(Client.Controllers.JobController)
local JobVisualsController = require(Client.Controllers.JobVisualsController)
local Layout = require(Client.UI.Phone.Layout)

local CLOCK_NOW = 1000 -- os.clock() on the client in these fixtures
local SERVER_NOW = 1.8e9 -- Workspace:GetServerTimeNow() in these fixtures
local TIME_TOLERANCE = 1e-6
local POSITION_TOLERANCE = 1e-3 -- Vector3 is 32-bit floats

type Job = JobController.Job

-- Landscape phones (the game is landscape-only on phones), a tablet and a desktop, in UI-scale-1 pixels. The small
-- heights are phones with the Roblox top bar taken off (ScreenInsets.CoreUISafeInsets).
local SCREENS: { { name: string, size: Vector2 } } = {
	{ name = "landscape phone 844x390", size = Vector2.new(844, 390) },
	{ name = "notched phone without the top bar 750x332", size = Vector2.new(750, 332) },
	{ name = "small landscape phone 667x375", size = Vector2.new(667, 375) },
	{ name = "small phone without the top bar 667x317", size = Vector2.new(667, 317) },
	{ name = "tablet 819x614", size = Vector2.new(819, 614) },
	{ name = "desktop 1229x691", size = Vector2.new(1229, 691) },
}

local CONTEXTS: { { name: string, context: Layout.Context } } = {
	{ name = "on foot", context = { driving = false, touch = false, hints = false } },
	{ name = "driving on touch", context = { driving = true, touch = true, hints = false } },
	{ name = "driving with keys", context = { driving = true, touch = false, hints = true } },
}

local function stop(kind: string, label: string, x: number): { [string]: any }
	return { position = Vector3.new(x, 0, 0), label = label, kind = kind }
end

-- A JobUpdate as Services/JobService publishes it.
local function payload(): { [string]: any }
	return {
		job = {
			id = "job-1",
			type = "rideshare",
			title = "Fare to Theater Row",
			stopIndex = 1,
			stops = { stop("pickup", "Town Square", 0), stop("dropoff", "Theater Row", 500) },
			deadline = SERVER_NOW + 90,
			startedAt = SERVER_NOW - 5,
			estPay = 1240,
			xl = true,
			routeLength = 3000,
		},
		offers = {
			{
				id = "a",
				type = "rideshare",
				title = "Fare to Lakefront",
				subtitle = "Pick up at Town Square",
				pay = 1500,
				distance = 2500,
				stops = 2,
				xl = false,
			},
			-- No xl field: reads as not XL.
			{
				id = "b",
				type = "delivery",
				title = "Riverside route",
				subtitle = "Load up at the depot",
				pay = 2100,
				distance = 3200,
				stops = 5,
			},
		} :: { any },
		availability = {
			rideshare = { ok = true },
			delivery = { ok = false, reason = "New Delivery jobs in 20 seconds." },
		},
		progress = {
			rideshare = { xp = 620, level = 2, multiplier = 1.05, nextXp = 1500, unlocks = { "longFares" } },
			delivery = { xp = 0, level = 1, multiplier = 1, unlocks = {} },
		},
	}
end

local function job(fields: { [string]: any }?): Job
	local update = JobController.normalize(payload(), CLOCK_NOW, SERVER_NOW)
	assert(update and update.job, "the fixture job")
	local copy: { [string]: any } = table.clone(update.job) :: any
	if fields then
		for key, value in fields do
			copy[key] = value
		end
	end
	return copy :: any
end

local function car(vehicleId: string, classId: string, seats: number): JobController.Car
	return { vehicleId = vehicleId, classId = classId, seats = seats, name = vehicleId }
end

local function markerList(markers: { JobVisualsController.Marker }): { string }
	local list: { string } = {}
	for _, marker in markers do
		table.insert(list, `{marker.index}:{marker.look}`)
	end
	return list
end

local function locationsTagged(tag: string): { MapLayout.Location }
	local list: { MapLayout.Location } = {}
	for _, location in MapLayout.locations do
		if location.tag == tag then
			table.insert(list, location)
		end
	end
	return list
end

-- How far `position` is (horizontally) from the nearest road's centre line, and how wide that road's carriageway
-- is on each side.
local function roadClearance(position: Vector3): (number, number, Vector3)
	local edgeIndex, _, distance, point = Graph.nearestEdge(position)
	assert(edgeIndex, "the county has roads")
	return distance, Graph.edgeWidth(edgeIndex) / 2, point
end

local function facesRoad(stand: CFrame): boolean
	local _, _, road = roadClearance(stand.Position)
	local toRoad = road - stand.Position
	return stand.LookVector:Dot(Vector3.new(toRoad.X, 0, toRoad.Z).Unit) > 0
end

return function(t: Harness.Api)
	t.describe("JobUpdate", function()
		t.it("keeps a good update: the job, its stops and deadline, offers, availability and levels", function()
			local update = JobController.normalize(payload(), CLOCK_NOW, SERVER_NOW)
			assert(update, "an update")
			local active = update.job
			assert(active, "a job")
			t.expect(active.id).toBe("job-1")
			t.expect(active.title).toBe("Fare to Theater Row")
			t.expect(active.stopIndex).toBe(1)
			t.expect(#active.stops).toBe(2)
			t.expect(active.stops[2].label).toBe("Theater Row")
			t.expect(active.stops[2].kind).toBe("dropoff")
			t.expect(active.estPay).toBe(1240)
			t.expect(active.xl).toBe(true)
			t.expect(active.endsAt :: number).toBeNear(CLOCK_NOW + 90, TIME_TOLERANCE)

			local offers = update.offers
			assert(offers, "offers")
			t.expect(#offers).toBe(2)
			t.expect(offers[1].pay).toBe(1500)
			t.expect(offers[1].stops).toBe(2)
			t.expect(offers[2].xl).toBe(false)

			local availability = update.availability
			assert(availability, "availability")
			t.expect(availability.rideshare.ok).toBe(true)
			t.expect(availability.delivery.ok).toBe(false)
			t.expect(availability.delivery.reason).toBe("New Delivery jobs in 20 seconds.")

			local levels = update.levels
			assert(levels, "levels")
			local rideshare = levels.rideshare
			local ladder = Jobs.levels.rideshare
			t.expect(rideshare.level).toBe(2)
			t.expect(rideshare.xp).toBe(620)
			t.expect(rideshare.levelXp).toBe(ladder[2].xp) -- not sent: read from Config/Jobs
			t.expect(rideshare.nextXp).toBe(1500)
			t.expect(rideshare.progress).toBeNear((620 - ladder[2].xp) / (1500 - ladder[2].xp), 1e-9)
			t.expect(rideshare.maxLevel).toBe(#ladder)
			t.expect(rideshare.multiplier).toBe(1.05)
			t.expect(rideshare.unlocks).toEqual({ "longFares" })
			t.expect(levels.delivery.level).toBe(1)
		end)

		t.it("refuses something that isn't an update", function()
			t.expect(JobController.normalize(nil, CLOCK_NOW, SERVER_NOW)).toBe(nil)
			t.expect(JobController.normalize("job", CLOCK_NOW, SERVER_NOW)).toBe(nil)
			t.expect(JobController.normalize(42, CLOCK_NOW, SERVER_NOW)).toBe(nil)
		end)

		t.it("drops broken offers, and reads a job with a broken stop as no job", function()
			local raw = payload()
			table.insert(raw.offers, { id = 7, type = "rideshare", title = "x" })
			table.insert(raw.offers, "not an offer")
			table.insert(raw.offers, { id = "c", type = "rideshare" }) -- no title
			raw.job.stops[2].position = "here"
			local update = JobController.normalize(raw, CLOCK_NOW, SERVER_NOW)
			assert(update, "an update")
			t.expect(update.job).toBe(nil)
			t.expect(#(update.offers :: { JobController.Offer })).toBe(2)
		end)

		t.it("leaves out what wasn't sent, so the last offers and levels stand", function()
			local update = JobController.normalize({ job = payload().job }, CLOCK_NOW, SERVER_NOW)
			assert(update, "an update")
			t.expect(update.job ~= nil).toBe(true)
			t.expect(update.offers).toBe(nil)
			t.expect(update.levels).toBe(nil)
			t.expect(update.availability).toBe(nil)
			local empty = JobController.normalize({}, CLOCK_NOW, SERVER_NOW)
			assert(empty, "an update")
			t.expect(empty.job).toBe(nil)
		end)

		t.it(
			"counts down from a deadline in server seconds, or a timeLeft, and never from one it can't read",
			function()
				t.expect(JobController.endsAt({ deadline = SERVER_NOW + 30 }, CLOCK_NOW, SERVER_NOW) :: number)
					.toBeNear(CLOCK_NOW + 30, TIME_TOLERANCE)
				t.expect(JobController.endsAt({ timeLeft = 45 }, CLOCK_NOW, SERVER_NOW) :: number)
					.toBeNear(CLOCK_NOW + 45, TIME_TOLERANCE)
				-- A deadline on the server's os.clock() means nothing on this client.
				t.expect(JobController.endsAt({ deadline = 500 }, CLOCK_NOW, SERVER_NOW)).toBe(nil)
				t.expect(JobController.endsAt({}, CLOCK_NOW, SERVER_NOW)).toBe(nil)
			end
		)

		t.it("keeps the stop index on the job's stops", function()
			local raw = payload()
			raw.job.stopIndex = 9
			local update = JobController.normalize(raw, CLOCK_NOW, SERVER_NOW)
			assert(update and update.job, "a job")
			t.expect(update.job.stopIndex).toBe(2)
		end)
	end)

	t.describe("Levels", function()
		t.it("reads the level from XP on every Config/Jobs ladder", function()
			for _, id in Jobs.order do
				local ladder = Jobs.levels[id]
				local first = JobController.levelFromXp(ladder, 0)
				t.expect(first.level).toBe(1)
				t.expect(first.nextXp).toBe(ladder[2].xp)
				t.expect(first.progress).toBe(0)
				local second = JobController.levelFromXp(ladder, ladder[2].xp)
				t.expect(second.level).toBe(2)
				t.expect(second.progress).toBe(0)
				local top = JobController.levelFromXp(ladder, ladder[#ladder].xp * 10)
				t.expect(top.level).toBe(#ladder)
				t.expect(top.nextXp).toBe(nil)
				t.expect(top.progress).toBe(1)
				t.expect(top.maxLevel).toBe(#ladder)
			end
		end)

		t.it("shows XP alone when there is no ladder", function()
			local level = JobController.levelFromXp(nil, 250)
			t.expect(level.level).toBe(nil)
			t.expect(level.xp).toBe(250)
		end)

		t.it("reads a bare XP number against Config/Jobs", function()
			local level = JobController.normalizeLevel("delivery", Jobs.levels.delivery[3].xp)
			assert(level, "a level")
			t.expect(level.level).toBe(3)
		end)
	end)

	t.describe("HUD slot", function()
		t.it("shows the title, pay, what to do at the stop, and the distance and time left", function()
			local hud = JobController.hudFor(job(), 161, "0.8 mi", false)
			t.expect(hud.title).toBe("Fare to Theater Row")
			t.expect(hud.pay).toBe(Economy.formatCash(1240))
			t.expect(hud.detail).toBe(string.format(JobController.text.stops.pickup, "Town Square"))
			t.expect(hud.status).toBe(string.format(JobController.text.status, "0.8 mi", "2:41"))
			t.expect(hud.alert).toBe("normal")
		end)

		t.it("says to stop once the car is close enough to count", function()
			local hud = JobController.hudFor(job({ stopIndex = 2 }), 100, "0.1 mi", true)
			t.expect(hud.detail).toBe(string.format(JobController.text.stops.dropoff, "Theater Row"))
			t.expect(hud.status).toBe(JobController.text.near.dropoff)
		end)

		t.it("shows what it knows when the distance or the time is missing", function()
			t.expect(JobController.hudFor(job(), nil, "1.2 mi", false).status)
				.toBe(string.format(JobController.text.distanceOnly, "1.2 mi"))
			t.expect(JobController.hudFor(job(), 75, nil, false).status)
				.toBe(string.format(JobController.text.timeOnly, "1:15"))
			t.expect(JobController.hudFor(job(), nil, nil, false).status).toBe(nil)
		end)

		t.it("turns amber, then red, as time runs short", function()
			local tuning = JobController.tuning
			t.expect(tuning.lowSeconds > tuning.criticalSeconds).toBe(true)
			t.expect(JobController.timeAlert(nil)).toBe("normal")
			t.expect(JobController.timeAlert(tuning.lowSeconds)).toBe("normal")
			t.expect(JobController.timeAlert(tuning.lowSeconds - 1)).toBe("low")
			t.expect(JobController.timeAlert(tuning.criticalSeconds - 1)).toBe("critical")
			t.expect(JobController.timeAlert(0)).toBe("critical")
		end)

		t.it("writes times as m:ss, and h:mm:ss past an hour", function()
			t.expect(JobController.formatTime(161)).toBe("2:41")
			t.expect(JobController.formatTime(59.2)).toBe("1:00")
			t.expect(JobController.formatTime(0)).toBe("0:00")
			t.expect(JobController.formatTime(-5)).toBe("0:00")
			t.expect(JobController.formatTime(3725)).toBe("1:02:05")
		end)

		t.it("has words for every kind of stop", function()
			for _, kind in { "pickup", "dropoff", "load", "drop" } do
				t.expect(JobController.text.stops[kind] ~= nil).toBe(true)
				t.expect(JobController.text.near[kind] ~= nil).toBe(true)
			end
			local unknown = { position = Vector3.zero, label = "Somewhere", kind = "teleport" }
			t.expect(JobController.stopText(unknown)).toBe("Somewhere")
		end)

		t.it("counts a stop from its road approach point too", function()
			local near = {
				position = Vector3.new(100, 0, 0),
				label = "Plot",
				kind = "drop",
				approach = Vector3.new(10, 0, 0),
			}
			t.expect(JobController.distanceTo(near, Vector3.new(0, 30, 0))).toBeNear(10, POSITION_TOLERANCE)
		end)
	end)

	t.describe("Eligibility", function()
		t.it("lists only real classes for every job type", function()
			local types = JobController.jobTypes()
			t.expect(#types).toBe(#Jobs.order)
			local unknown: { string } = {}
			for _, info in types do
				for _, classId in info.classes do
					if Classes[classId] == nil then
						table.insert(unknown, `{info.id}: {classId}`)
					end
				end
				t.expect(info.arriveRadius > 0).toBe(true)
			end
			t.expect(unknown).toEqual({})
		end)

		t.it("writes class lists the way people say them", function()
			t.expect(JobController.classNames({ "van", "suv", "pickup" }))
				.toBe(`{Classes.van.displayName}, {Classes.suv.displayName} or {Classes.pickup.displayName}`)
			t.expect(JobController.classNames({ "van" })).toBe(Classes.van.displayName)
			t.expect(JobController.classNames({ "nope" })).toBe("")
			t.expect(JobController.classNames({})).toBe("")
		end)

		t.it("decides by class, never by name", function()
			local rideshare = JobController.jobType("rideshare")
			local delivery = JobController.jobType("delivery")
			assert(rideshare and delivery, "both job types")
			t.expect(JobController.canDo(rideshare, "sedan")).toBe(true)
			t.expect(JobController.canDo(rideshare, "van")).toBe(false)
			t.expect(JobController.canDo(delivery, "van")).toBe(true)
			t.expect(JobController.canDo(delivery, "sports")).toBe(false)
			t.expect(JobController.canDo(delivery, nil)).toBe(false)
		end)

		t.it("knows which cars earn extra: XL classes and seats, and the delivery bonus classes", function()
			local rideshare = JobController.jobType("rideshare")
			local delivery = JobController.jobType("delivery")
			assert(rideshare and delivery, "both job types")
			t.expect(JobController.earnsBonus(delivery, car("v", "van", 2))).toBe(true)
			t.expect(JobController.earnsBonus(delivery, car("s", "sedan", 5))).toBe(false)
			t.expect(JobController.earnsBonus(rideshare, car("u", "suv", 5))).toBe(true)
			t.expect(JobController.earnsBonus(rideshare, car("s", "sedan", 5))).toBe(false)
			local minSeats = rideshare.xlMinSeats
			if minSeats then
				t.expect(JobController.earnsBonus(rideshare, car("m", "economy", minSeats))).toBe(true)
			end
			t.expect(JobController.earnsBonus(rideshare, car("v", "van", 8))).toBe(false) -- can't do rideshare
			t.expect(JobController.earnsBonus(rideshare, nil)).toBe(false)
		end)

		t.it("reads a car's class and seats from the catalog", function()
			local vehicleId = Catalog.vehicleIds()[1]
			local entry = Catalog.getVehicle(vehicleId)
			local trim = Catalog.defaultTrim(vehicleId)
			assert(entry and trim, "a catalog car")
			local info = JobController.carInfo(vehicleId, trim.id)
			assert(info, "car info")
			t.expect(info.classId).toBe(entry.class)
			t.expect(info.seats).toBe(trim.seats)
			t.expect(JobController.carInfo("no_such_car", "x")).toBe(nil)
			t.expect(JobController.carInfo(nil, nil)).toBe(nil)
		end)
	end)

	t.describe("GPS", function()
		t.it("routes to the first stop of a new job", function()
			local step = JobController.gpsStep(job(), nil, nil)
			t.expect(step.action).toBe("route")
			if step.action == "route" then
				t.expect(step.key).toBe("job-1#1")
				t.expect(step.stop.label).toBe("Town Square")
			end
		end)

		t.it("leaves the GPS alone while the stop stays the same, even if the player picked somewhere else", function()
			local routed = { key = "job-1#1", position = Vector3.new(0, 0, 0) }
			t.expect(JobController.gpsStep(job(), routed, Vector3.new(999, 0, 0)).action).toBe("none")
			t.expect(JobController.gpsStep(job(), routed, nil).action).toBe("none")
		end)

		t.it("routes again when the stop moves on, and for a new job", function()
			local routed = { key = "job-1#1", position = Vector3.new(0, 0, 0) }
			local step = JobController.gpsStep(job({ stopIndex = 2 }), routed, routed.position)
			t.expect(step.action).toBe("route")
			if step.action == "route" then
				t.expect(step.key).toBe("job-1#2")
				t.expect(step.stop.label).toBe("Theater Row")
			end
			t.expect(JobController.gpsStep(job({ id = "job-2" }), routed, routed.position).action).toBe("route")
		end)

		t.it("clears the route when the job ends, only if it is still the job's", function()
			local routed = { key = "job-1#2", position = Vector3.new(500, 0, 0) }
			t.expect(JobController.gpsStep(nil, routed, Vector3.new(500, 0, 0)).action).toBe("clear")
			t.expect(JobController.gpsStep(nil, routed, Vector3.new(42, 0, 0)).action).toBe("none")
			t.expect(JobController.gpsStep(nil, routed, nil).action).toBe("none")
			t.expect(JobController.gpsStep(nil, nil, Vector3.new(500, 0, 0)).action).toBe("none")
		end)
	end)

	t.describe("Job visuals", function()
		t.it("shows the fare at the pickup until it's picked up, and someone at the drop-off", function()
			local stops =
				{ { position = Vector3.zero, kind = "pickup" }, { position = Vector3.zero, kind = "dropoff" } }
			t.expect(markerList(JobVisualsController.markersFor(stops, 1))).toEqual({ "1:hailing", "2:waiting" })
			t.expect(markerList(JobVisualsController.markersFor(stops, 2))).toEqual({ "2:waiting" })
		end)

		t.it("shows a parcel at each drop still to do, and nothing at the depot", function()
			local stops = {
				{ position = Vector3.zero, kind = "load" },
				{ position = Vector3.zero, kind = "drop" },
				{ position = Vector3.zero, kind = "drop" },
				{ position = Vector3.zero, kind = "drop" },
			}
			t.expect(markerList(JobVisualsController.markersFor(stops, 1)))
				.toEqual({ "2:parcel", "3:parcel", "4:parcel" })
			t.expect(markerList(JobVisualsController.markersFor(stops, 3))).toEqual({ "3:parcel", "4:parcel" })
		end)

		t.it("stands every fare at a rideshare hotspot off the road, on the spot, facing the road", function()
			local problems: { string } = {}
			local hotspots = locationsTagged("RideshareHotspot")
			t.expect(#hotspots > 0).toBe(true)
			for _, location in hotspots do
				local stand = JobVisualsController.standFor(location.position)
				local distance, halfWidth = roadClearance(stand.Position)
				if distance <= halfWidth then
					table.insert(problems, `{location.id}: on the carriageway ({distance} studs from the centre)`)
				end
				if not facesRoad(stand) then
					table.insert(problems, `{location.id}: faces away from the road`)
				end
				if math.abs(stand.Position.Y - (location.position.Y + location.size.Y)) > POSITION_TOLERANCE then
					table.insert(problems, `{location.id}: not on the spot's top`)
				end
			end
			t.expect(problems).toEqual({})
		end)

		t.it("puts each parcel on its house plot, on the side toward the road", function()
			local problems: { string } = {}
			local plots = locationsTagged("HousePlot")
			t.expect(#plots > 0).toBe(true)
			for _, location in plots do
				local stand = JobVisualsController.standFor(location.position)
				local distance = roadClearance(stand.Position)
				local centre = roadClearance(location.position)
				if distance > centre + POSITION_TOLERANCE then
					table.insert(problems, `{location.id}: farther from the road than the plot's centre`)
				end
				if math.abs(stand.Position.Y - (location.position.Y + location.size.Y)) > POSITION_TOLERANCE then
					table.insert(problems, `{location.id}: not on the plot`)
				end
			end
			t.expect(problems).toEqual({})
		end)

		t.it("moves a figure for a stop on the road to beside it, past the sidewalk, facing it", function()
			local edges = Graph.edges()
			local problems: { string } = {}
			for edgeIndex = 1, #edges, math.max(#edges // 25, 1) do
				local onRoad = Graph.pointOnEdge(edgeIndex, 0.5)
				if JobVisualsController.locationAt(onRoad) ~= nil then
					continue
				end
				local stand = JobVisualsController.standFor(onRoad)
				local distance, halfWidth = roadClearance(stand.Position)
				if distance <= halfWidth then
					table.insert(problems, `edge {edgeIndex}: still on the carriageway`)
				end
				if not facesRoad(stand) then
					table.insert(problems, `edge {edgeIndex}: faces away from the road`)
				end
			end
			t.expect(problems).toEqual({})
		end)
	end)

	t.describe("HUD job slot", function()
		t.it("sits on screen, clear of the notices, GPS chip, phone button, speed panel and touch controls", function()
			local problems: { string } = {}
			for _, screen in SCREENS do
				local slot = HudController.jobSlotRect(screen.size)
				if not Layout.contains(Layout.screen(screen.size), slot) then
					table.insert(problems, `{screen.name}: off screen`)
				end
				for _, entry in CONTEXTS do
					for index, blocker in HudController.jobSlotBlockers(screen.size, entry.context) do
						if Layout.overlaps(slot, blocker) then
							table.insert(problems, `{screen.name}, {entry.name}: covers blocker {index}`)
						end
					end
				end
			end
			t.expect(problems).toEqual({})
		end)
	end)
end
