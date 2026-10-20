--!strict
-- The Mesa Test Site drag strip (PLAN.md Phase 10; docs/phase-10-contracts.md "Arc tuning, drag strip and
-- leaderboard"): every tunable, plus the pure rules that Services/DragStripService runs on the server and that
-- specs and Studio test drivers can run anywhere. Read by Services/DragStripService,
-- Controllers/DragStripController and tests/DragStrip.spec.
--
-- A run: a car that stops (slower than staging.stillSpeed for staging.stillSeconds) with its front at most
-- staging.depth studs behind gate 1, inside the strip's width, is armed. The run starts the moment its front
-- crosses gate 1; gates 2 and 3 give splits, and gate 4 finishes it. A crossing is the moment the front face of
-- the car's Chassis box (frontPoint) passes a gate's plane going forward, the way the gate faces. Times are the
-- server's clock (Workspace:GetServerTimeNow()), interpolated inside one server frame from the front's position
-- and velocity on both sides of the plane (crossingTime).
--
-- Faults (faultFor): the server moved the car or it jumped further than its speed allows (a reset or a
-- teleport), an ability ran, the owner left the Driver seat, the car left the strip sideways, or the run took
-- too long. An armed car that backs away from the line is cancelled. A finished run or split quicker than the car
-- could possibly be (isPlausible against fastestSplits, worked out from its own Vehicle/Tuning numbers) is shown
-- but never saved.
--
-- Units: studs and seconds. The weekly leaderboard stores whole milliseconds (lower is better); every `time`,
-- `best` and split that DragStripUpdate and GetDragLeaderboard send is in seconds (milliseconds / 1000).

local Driving = require(script.Parent.Driving)
local MapLayout = require(script.Parent.MapLayout)
local Powertrain = require(script.Parent.Parent.Vehicle.Powertrain)

-- One gate, from its Config/MapLayout location.
export type Gate = {
	index: number, -- 1 = start line, 2 = 330 ft, 3 = 1/8 mile, 4 = 1/4 mile (finish)
	id: string, -- the MapLayout location id
	origin: Vector3, -- centre of the gate's footprint on the road
	normal: Vector3, -- flat unit vector the gate faces: the direction of travel
	right: Vector3, -- flat unit vector to the right of the direction of travel
	halfWidth: number, -- studs from the centre line to the gate's edge
}

export type Fault = "cancelled" | "sideways" | "teleport" | "ability" | "driver" | "timeout"

-- What the staging rule looks at, from one server sample.
export type ArmFacts = {
	frontPast: number, -- studs the car's front is past gate 1 (negative = behind the line)
	lateral: number, -- studs from the strip's centre line to the car's centre (positive = right)
	halfWidth: number, -- the strip's half width (gate 1's)
	speed: number, -- studs/s
	ability: boolean, -- the car's Ability attribute is set
	driving: boolean, -- the owner sits in the car's Driver seat
}

-- What the fault rules look at, from one server sample of an armed or running car.
export type RunFacts = {
	phase: "armed" | "running",
	frontPast: number,
	lateral: number,
	halfWidth: number,
	ability: boolean,
	moved: boolean, -- the server moved the car since the run armed (a reset, an unstuck, a dev teleport)
	jumped: boolean, -- the front moved further between two samples than the car's speed allows
	driving: boolean,
	elapsed: number, -- seconds since the start line (0 while armed)
}

-- One leaderboard row: a player and their best time this week, in milliseconds.
export type Entry = { userId: number, ms: number }

local SECONDS_PER_DAY = 86400
local THURSDAY = 4 -- ISO weekday; an ISO week belongs to the year its Thursday falls in
local DAYS_PER_WEEK = 7
local MS_PER_SECOND = 1000

local DragStrip = {
	gateTag = "DragStripGate", -- the Config/MapLayout tag of the four gates (attribute `index` 1..4)
	gateCount = 4,

	-- Arming. The staging area is the strip's width behind gate 1.
	staging = {
		depth = 30, -- the car's front must be at most this many studs behind the line (and not past it)
		-- The touch sensor the service builds behind the line reaches this much further back, so a long car whose
		-- front is in the staging area always touches it; a car whose front is further back is no longer watched.
		sensorTail = 30,
		sensorHeight = 20,
		stillSpeed = 1.5, -- studs/s: slower than this counts as stopped
		stillSeconds = 0.5, -- stopped this long arms the run
		backOffMargin = 4, -- an armed car whose front backs this many studs out of the staging area is cancelled
	},

	-- The strip is gate 1's width; a car whose centre strays this much further sideways has left it.
	sideMargin = 2,

	maxRunSeconds = 45, -- a run that hasn't reached gate 4 by then is void (the slowest car needs about 25 s)
	-- A finished run, and each split, counts only when it is no quicker than plausibleShare x the quickest that car
	-- could possibly do it (fastestSplits). The server sees a client-driven car, so without this a cheat that
	-- moves it just under anti-exploit's speed cap could top the board; the share leaves room for the server's
	-- view of the car arriving unevenly.
	plausibleShare = 0.9,
	-- And never quicker than this over the quarter mile, whatever the car (the quickest Arc needs about 6 s).
	minPlausibleSeconds = 4,
	-- fastestSplits steps through the run this many seconds at a time, for at most fastestMaxSeconds.
	fastestStep = 1 / 120,
	fastestMaxSeconds = 60,

	-- Teleport check between two server samples: the front may move across the ground at most the car's top
	-- speed x jumpSpeedFactor over max(sample gap, jumpMinWindow), plus jumpMarginStuds. The window and margin
	-- cover the server's view of a client-driven car arriving in bunches.
	jumpSpeedFactor = 1.5,
	jumpMinWindow = 0.25,
	jumpMarginStuds = 10,

	-- After gate 4 the result waits this long before it counts: longer than two Config/AntiExploit samples, so a
	-- teleport or speed trick near the line is caught (and voids the run) first.
	finishConfirmSeconds = 1.2,

	bisectionSteps = 30, -- halvings of one frame when finding a crossing (far below a millisecond)

	-- The weekly leaderboard: one OrderedDataStore per ISO week, named storePrefix .. weekKey (for example
	-- "DragStripWeek_2026-W43"), keyed by UserId, holding each player's best in milliseconds. Studio uses its own
	-- prefix so tests never touch the live board.
	storePrefix = "DragStripWeek_",
	studioStorePrefix = "DragStripWeekStudio_",
	boardSize = 10, -- rows on the board and entries GetDragLeaderboard returns
	rankPageSize = 100, -- times read in one go (GetSortedAsync's page limit); a rank is found among these
	cacheSeconds = 30, -- GetDragLeaderboard answers from a read at most this old
	refreshSeconds = 120, -- the board re-reads the week's times this often while anyone is in the server
	-- Every DataStore call waits until each request type it uses has at least minRequestBudget left, checking
	-- every budgetWaitSeconds up to budgetMaxWaits times, then gives up.
	minRequestBudget = 1,
	budgetWaitSeconds = 1,
	budgetMaxWaits = 5,
	fallbackName = "Driver", -- shown when a player's name can't be looked up

	-- The in-world board, built by the service at Start in Workspace[folderName] (never in Map.Generated).
	board = {
		folderName = "DragStrip",
		-- Where it stands, from gate 1: `along` studs down the strip (negative = behind the line) and `across`
		-- studs to the right of the direction of travel (negative = left: north of the strip, between it and the
		-- Return Road). It turns to face the strip's centre line `lookAlong` studs from the line, a little back
		-- toward the approach so drivers read it as they pull up.
		along = -20,
		across = -66,
		lookAlong = -40,
		panelSize = Vector3.new(32, 22, 1), -- studs
		clearance = 4, -- studs between the ground and the panel's bottom edge
		postWidth = 1.2,
		-- The face is 640 x 440 pixels: padding, a title row, a subtitle, ten rows and a footer fit with room
		-- to spare (sizes in pixels).
		pixelsPerStud = 20,
		padding = 20,
		titleSize = 40,
		subtitleSize = 22,
		rowHeight = 24,
		rowTextSize = 20,
		rankWidth = 44, -- the "10." column
		timeWidth = 150, -- the time column
		footerSize = 20,
		gap = 4, -- between rows and blocks
	},

	messages = {
		armed = "Ready. Launch when you like!",
		finished = "Drag strip: %s.", -- the time
		newBest = "New best this week!",
		rank = "You're #%d this week.",
		testDrive = "Test drives don't go on the board.",
		notSaved = "Your time couldn't be saved right now.",
		implausible = "That run didn't look right, so it wasn't saved.",
		faults = {
			cancelled = "Run cancelled. Stop behind the start line to try again.",
			sideways = "Run void: you left the strip.",
			teleport = "Run void: your car was moved.",
			ability = "Run void: no thrusters on the drag strip.",
			driver = "Run void: you left the driver's seat.",
			timeout = "Run void: that took too long.",
		} :: { [Fault]: string },
		board = {
			title = "Drag Strip",
			week = "Week %d",
			subtitle = "This week's top 10, quarter mile",
			empty = "No times yet this week. Set the first one!",
			row = "%d.",
			footer = "Stop behind the line, then launch.",
		},
		timeFormat = "%.3f s",
	},
}

-- Gates ----------------------------------------------------------------------------------------------------

local gates: { Gate }? = nil

-- The drag-strip gates from Config/MapLayout, sorted by index (1 = start). Read-only.
function DragStrip.gates(): { Gate }
	local cached = gates
	if cached ~= nil then
		return cached
	end
	local list: { Gate } = {}
	for _, location in MapLayout.locations do
		if location.tag ~= DragStrip.gateTag then
			continue
		end
		local attributes: { [string]: any } = location.attributes or {}
		local facing = CFrame.Angles(0, math.rad(location.yaw), 0)
		table.insert(list, {
			index = attributes.index,
			id = location.id,
			origin = location.position,
			normal = facing.LookVector,
			right = facing.RightVector,
			halfWidth = location.size.X / 2,
		})
	end
	table.sort(list, function(a, b)
		return a.index < b.index
	end)
	for _, gate in list do
		table.freeze(gate)
	end
	table.freeze(list)
	gates = list
	return list
end

-- Geometry ---------------------------------------------------------------------------------------------------

-- The centre of the front face of a car's Chassis box (the vehicle model contract: the chassis faces -Z).
function DragStrip.frontPoint(chassisCFrame: CFrame, chassisSize: Vector3): Vector3
	return chassisCFrame.Position + chassisCFrame.LookVector * (chassisSize.Z / 2)
end

-- How far `point` is past the gate's plane, along the way it faces (negative = before it), in studs.
function DragStrip.distancePast(gate: Gate, point: Vector3): number
	return (point - gate.origin):Dot(gate.normal)
end

-- How far `point` is to the right of the strip's centre line through `gate` (negative = left), in studs.
function DragStrip.lateral(gate: Gate, point: Vector3): number
	return (point - gate.origin):Dot(gate.right)
end

-- The moment a point crosses a plane going forward, between two samples: at time t0 it was d0 studs past the
-- plane moving at r0 studs/s toward it (along the plane's normal), at t1 d1 studs past moving at r1. Nil unless
-- it was before the plane at t0 and on or past it at t1. The path between the samples is the cubic that matches
-- both positions and both velocities (exact for constant acceleration), and the crossing is found by bisection,
-- so the answer is always inside [t0, t1].
function DragStrip.crossingTime(t0: number, d0: number, r0: number, t1: number, d1: number, r1: number): number?
	if not (d0 < 0 and d1 >= 0) then
		return nil
	end
	local h = t1 - t0
	if h <= 0 then
		return t1
	end
	local m0, m1 = r0 * h, r1 * h
	-- Cubic Hermite through (0, d0) and (1, d1) with slopes m0 and m1, at s in 0..1.
	local function at(s: number): number
		local s2 = s * s
		local s3 = s2 * s
		return (2 * s3 - 3 * s2 + 1) * d0 + (s3 - 2 * s2 + s) * m0 + (3 * s2 - 2 * s3) * d1 + (s3 - s2) * m1
	end
	local low, high = 0, 1
	for _ = 1, DragStrip.bisectionSteps do
		local middle = (low + high) / 2
		if at(middle) < 0 then
			low = middle
		else
			high = middle
		end
	end
	return t0 + h * (low + high) / 2
end

-- True when the front moved further across the ground between two samples `dt` seconds apart than a car with
-- this top speed (studs/s) could: a teleport.
function DragStrip.isJump(distance: number, dt: number, topSpeed: number): boolean
	local window = math.max(dt, DragStrip.jumpMinWindow)
	return distance > topSpeed * DragStrip.jumpSpeedFactor * window + DragStrip.jumpMarginStuds
end

-- Rules ------------------------------------------------------------------------------------------------------

-- True while a car is worth watching for a run: its front is in the stretch the staging sensor covers (behind
-- the line) and its centre is on the strip.
function DragStrip.staysStaged(frontPast: number, lateral: number, halfWidth: number): boolean
	local staging = DragStrip.staging
	return frontPast < 0
		and frontPast >= -(staging.depth + staging.sensorTail)
		and math.abs(lateral) <= halfWidth + DragStrip.sideMargin
end

-- True when this sample counts toward arming: the owner drives, no ability runs, the car is stopped, its front
-- is in the staging area behind the line and its centre is inside the strip's width.
function DragStrip.canArm(facts: ArmFacts): boolean
	return facts.driving
		and not facts.ability
		and facts.speed < DragStrip.staging.stillSpeed
		and facts.frontPast < 0
		and facts.frontPast >= -DragStrip.staging.depth
		and math.abs(facts.lateral) <= facts.halfWidth
end

-- The fault an armed or running car has committed in this sample, or nil. A move by the server or a jump comes
-- first (nothing else about that sample can be trusted), then an ability, the driver, the strip's sides, and
-- last the armed car backing away (cancelled) or the running car's time limit.
function DragStrip.faultFor(facts: RunFacts): Fault?
	if facts.moved or facts.jumped then
		return "teleport"
	elseif facts.ability then
		return "ability"
	elseif not facts.driving then
		return "driver"
	elseif math.abs(facts.lateral) > facts.halfWidth + DragStrip.sideMargin then
		return "sideways"
	end
	if facts.phase == "armed" then
		local staging = DragStrip.staging
		if facts.frontPast < -(staging.depth + staging.backOffMargin) then
			return "cancelled"
		end
	elseif facts.elapsed > DragStrip.maxRunSeconds then
		return "timeout"
	end
	return nil
end

-- The most drive acceleration the tires accept in any drive mode (studs/s²).
local function bestTraction(spec: Powertrain.Spec): number
	local share = 0
	for _, mode in Driving.modes do
		share = math.max(share, mode.tractionUse)
	end
	return spec.tractionLimit * share
end

-- The quickest a car with these numbers (Vehicle/Tuning) could possibly get from the start line to each of
-- `distances` (studs past it), in seconds from the moment its front crosses the line. It starts from rest
-- staging.depth + staging.backOffMargin behind the line (the furthest back an armed car may roll) and pulls with
-- its full force curve and all the grip any drive mode allows, less drag and rolling resistance, with no
-- throttle ramp, gear shifts or limiter (each of those only ever slows a car). 0 for a distance it doesn't
-- reach within fastestMaxSeconds: no bound.
function DragStrip.fastestSplits(spec: Powertrain.Spec, distances: { number }): { number }
	local staging = DragStrip.staging
	local dt = DragStrip.fastestStep
	local traction = bestTraction(spec)
	local times: { number } = table.create(#distances, 0)
	local done: { boolean } = table.create(#distances, false)
	local left = #distances
	local position = -(staging.depth + staging.backOffMargin)
	local speed, clock = 0, 0
	local startedAt: number? = nil
	while left > 0 and clock < DragStrip.fastestMaxSeconds do
		local accel = math.min(Powertrain.tractiveAccel(spec, speed), traction) - Powertrain.resistance(spec, speed)
		local nextSpeed = math.max(0, speed + accel * dt)
		local nextPosition = position + (speed + nextSpeed) / 2 * dt
		if not (nextPosition > position) then
			break -- it never moves: no bound
		end
		local span = nextPosition - position
		if startedAt == nil and nextPosition >= 0 then
			startedAt = clock + dt * -position / span
		end
		local started = startedAt
		if started ~= nil then
			for index, distance in distances do
				if not done[index] and nextPosition >= distance then
					done[index] = true
					left -= 1
					times[index] = math.max(clock + dt * (distance - position) / span - started, 0)
				end
			end
		end
		position, speed = nextPosition, nextSpeed
		clock += dt
	end
	return times
end

-- True for a time a car could really run, in seconds: a number above zero, no quicker than plausibleShare x
-- `fastest` (fastestSplits for that car and stretch; nil or 0 when it isn't known) and, for the whole quarter
-- mile (`split` false), never under minPlausibleSeconds.
function DragStrip.isPlausible(seconds: number, fastest: number?, split: boolean?): boolean
	if not (seconds == seconds and seconds > 0 and seconds < math.huge) then
		return false
	end
	local floor = if split then 0 else DragStrip.minPlausibleSeconds
	if fastest ~= nil and fastest > 0 and fastest < math.huge then
		floor = math.max(floor, fastest * DragStrip.plausibleShare)
	end
	return seconds >= floor
end

-- Leaderboard -------------------------------------------------------------------------------------------------

-- The ISO 8601 week of a moment in UTC, as "YYYY-Www" (2026-10-20 is "2026-W43"). Weeks start on Monday, and
-- week 1 is the week with the year's first Thursday, so a few days round New Year belong to the other year.
function DragStrip.weekKey(unixSeconds: number): string
	local day = os.date("!*t", unixSeconds) :: any
	-- os.date's wday runs 1 = Sunday .. 7 = Saturday; ISO weekdays run 1 = Monday .. 7 = Sunday.
	local isoWeekday = (day.wday + 5) % DAYS_PER_WEEK + 1
	local thursday = os.date("!*t", unixSeconds + (THURSDAY - isoWeekday) * SECONDS_PER_DAY) :: any
	local week = math.floor((thursday.yday - 1) / DAYS_PER_WEEK) + 1
	return string.format("%04d-W%02d", thursday.year, week)
end

-- The week number of a week key ("2026-W43" -> 43), or nil.
function DragStrip.weekNumber(week: string): number?
	local digits = string.match(week, "%-W(%d+)$")
	return if digits then tonumber(digits) else nil
end

-- Seconds to the whole milliseconds the board stores.
function DragStrip.toMs(seconds: number): number
	return math.floor(seconds * MS_PER_SECOND + 0.5)
end

function DragStrip.toSeconds(ms: number): number
	return ms / MS_PER_SECOND
end

-- A time as players see it ("9.873 s").
function DragStrip.formatTime(seconds: number): string
	return string.format(DragStrip.messages.timeFormat, seconds)
end

-- True when `ms` beats the stored best `old` (nil = no time yet this week). Only a personal best is written.
function DragStrip.isPersonalBest(old: number?, ms: number): boolean
	return old == nil or ms < old
end

-- A sorted copy of `entries` (fastest first, ties by UserId) with the player's time set to the better of their
-- old one and `ms`, cut to `limit` rows.
function DragStrip.mergeEntry(entries: { Entry }, userId: number, ms: number, limit: number): { Entry }
	local merged: { Entry } = {}
	local best = ms
	for _, entry in entries do
		if entry.userId == userId then
			best = math.min(best, entry.ms)
		else
			table.insert(merged, entry)
		end
	end
	table.insert(merged, { userId = userId, ms = best })
	table.sort(merged, function(a, b)
		if a.ms ~= b.ms then
			return a.ms < b.ms
		end
		return a.userId < b.userId
	end)
	while #merged > limit do
		table.remove(merged)
	end
	return merged
end

-- The player's place in sorted `entries` (1 = fastest), or nil when they aren't in them.
function DragStrip.rankOf(entries: { Entry }, userId: number): number?
	for index, entry in entries do
		if entry.userId == userId then
			return index
		end
	end
	return nil
end

return DragStrip
