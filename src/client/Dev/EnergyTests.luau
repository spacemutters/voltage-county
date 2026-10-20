--!strict
-- Studio-only energy tests (PLAN.md Phase 5 acceptance; docs/phase-5-contracts.md "Client"). Each drives the car
-- the local player sits in with Dev/AutoDriver and measures what Services/EnergyService actually did, from the
-- car's attributes (Energy, Charging, Limp) and the player's Cash:
--   cruise(seconds, mph)   joins the County Loop (RoadGraph.loopNodeIds) and cruises it at `mph` (default
--                          Config/Energy.cruiseMph); once the car is on the loop at speed it measures the drain per
--                          minute over `seconds` and extrapolates how many minutes a full charge or tank lasts.
--                          Acceptance: the catalog's energyMinutes ±10 % at the reference cruise speed (at any
--                          other speed, what Vehicle/Energy predicts for the speed actually driven).
--   charge(opts)           with a battery car (the one you sit in, else a fresh SETTINGS.batteryCar) drives into the
--                          nearest fast ChargerStall (kW >= SETTINGS.fastStallMinKW), sets the level to 10 % with
--                          the Studio-only DevSetEnergy remote, and times 10 -> 80 % and what it cost.
--                          Acceptance: 60-90 s, and the cost (Vehicle/Energy.costPerFraction) is deducted.
--   refuel(opts)           the same at the nearest FuelPump with a fuel car (the one you sit in, else the first
--                          player-drivable fuel car in the catalog), 10 -> 100 %. Acceptance: 20-30 s, cost deducted.
--   limpToStation(vehicleId, trim)  puts a fresh car of that trim (DevSpawnVehicle) on the road-graph node farthest
--                          from every station it may use, empties it (DevSetEnergy 0), waits for the server's
--                          EnergyAlert, and drives at the limp speed to the station the alert names (else the
--                          nearest compatible one by road), parking in it. Reports arrival, time, distance, top
--                          speed, whether the GPS was routing there and whether charging started. Acceptance:
--                          arrives, never faster than the limp speed (plus anti-exploit's tolerance).
--   start(name, ...)       runs any of them in the background and returns at once; lastResult() returns its result
--                          once done (nil while it runs), status() what it's doing, stop() cancels it.
-- Each returns a Result (see the type): { name, passed, reason, vehicle, elapsed, ... } plus the test's numbers and
-- notes. Results are printed as they finish, so get_console_output shows them even if execute_luau stops waiting.
--
-- Run from MCP execute_luau in the Client datamodel of a playtest, once the player sits in a car's Driver seat
-- (limpToStation only needs a character). Runs take minutes, longer than an execute_luau call waits:
--   require(game.Players.LocalPlayer.PlayerScripts.Client.Dev.EnergyTests).start("cruise", 120)
--   require(game.Players.LocalPlayer.PlayerScripts.Client.Dev.EnergyTests).start("limpToStation", "ohm_spark")
--   require(game.Players.LocalPlayer.PlayerScripts.Client.Dev.EnergyTests).lastResult()
--
-- Driving goes through AutoDriver's Bridge (see its header), so calls from MCP's copy of this module drive the
-- game's controllers; remotes go through this copy's own Net (set up on first use, as Dev/ShopTests does). State
-- that every copy must see (running, cancel, the last result) lives in attributes on this ModuleScript, as in
-- Dev/EarnTests. Charging and the alerts cost real (Studio) cash and change the car's saved level.
--
-- Does nothing outside Studio (CLAUDE.md hard rule 8); the server refuses DevSetEnergy and DevSpawnVehicle
-- outside Studio too. The client loader never boots it.

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local AutoDriver = require(script.Parent.AutoDriver)
local Catalog = require(Shared.Vehicle.Catalog)
local Economy = require(Shared.Config.Economy)
local Energy = require(Shared.Vehicle.Energy)
local EnergyConfig = require(Shared.Config.Energy)
local Gps = require(Shared.Config.Gps)
local Graph = require(Shared.Road.Graph)
local MapLayout = require(Shared.Config.MapLayout)
local Net = require(Shared.Net)
local Pathfind = require(Shared.Road.Pathfind)
local RoadGraph = require(Shared.Config.RoadGraph)
local RouteTests = require(script.Parent.RouteTests)
local Spawning = require(Shared.Config.Spawning)
local Units = require(Shared.Util.Units)
local World = require(Shared.Config.World)

export type TestName = "cruise" | "charge" | "refuel" | "limpToStation"

export type Options = {
	vehicleId: string?, -- charge / refuel: spawn this car instead of using the one you sit in
	trim: string?, -- with vehicleId (default: the vehicle's first trim)
	station: string?, -- charge / refuel: a MapLayout location id to use instead of the nearest
}

export type Result = {
	name: string,
	passed: boolean, -- inside the PLAN.md Phase 5 acceptance
	reason: string, -- "done", or why it ended early
	vehicle: string?, -- "vehicleId/trim"
	elapsed: number, -- seconds the whole test took
	notes: { string },
	-- cruise
	targetMph: number?,
	averageMph: number?, -- what the car actually averaged while measured
	measuredSeconds: number?,
	drainedPercent: number?,
	drainPerMinute: number?, -- % of a full charge or tank per minute
	fullMinutes: number?, -- extrapolated minutes a full charge or tank lasts
	catalogMinutes: number?, -- the trim's energyMinutes (defined at Config/Energy.cruiseMph)
	expectedMinutes: number?, -- what Vehicle/Energy predicts at the speed actually averaged
	-- charge, refuel, limpToStation
	station: string?, -- MapLayout location id
	stationKind: string?,
	-- charge, refuel
	fromPercent: number?,
	toPercent: number?,
	seconds: number?, -- from the start level to the target level
	windowSeconds: { number }?, -- the acceptance window
	cost: number?, -- cash spent while filling
	expectedCost: number?,
	-- limpToStation
	startNode: string?, -- the road-graph node it started from
	straightDistance: number?, -- studs, straight line from the start to the station
	routeStuds: number?, -- studs along the road route driven
	alertStation: string?, -- the station the server's EnergyAlert named (nil: none came)
	gpsRouted: boolean?, -- the GPS was showing a route ending at the station after the alert
	arrived: boolean?,
	driveSeconds: number?,
	maxMph: number?,
	chargingStarted: boolean?,
}

-- A dev tool, so its numbers live here rather than in Shared/Config (like Dev/EarnTests' SETTINGS). The windows
-- and tolerance are PLAN.md Phase 5's acceptance.
local SETTINGS = {
	-- cruise()
	cruiseTolerance = 0.10, -- full-charge minutes within ±10 %
	-- Measuring starts once the car has held this share of the cruise speed on the loop for readyHoldSeconds
	-- (so the speeding up before it isn't measured as cruising).
	readyFraction = 0.97,
	readyHoldSeconds = 3,
	settleTimeout = 60, -- seconds allowed to reach it after joining the loop
	joinRadius = 60, -- studs from the loop node where the car counts as on the loop
	extraLaps = 1, -- laps driven beyond what the measurement needs, so the car never slows for the finish
	-- charge() / refuel()
	batteryCar = { vehicleId = "ohm_spark", trim = "standard" },
	fastStallMinKW = 250, -- a "fast" stall (Config/MapLayout: 150, 250 and 350 kW stalls)
	startLevel = 0.10,
	chargeTarget = 0.80,
	refuelTarget = 1.0,
	chargeWindow = { 60, 90 }, -- seconds, 10 -> 80 % at a fast stall
	refuelWindow = { 20, 30 }, -- seconds, 10 -> 100 % at a pump
	-- A level set with DevSetEnergy counts once the attribute reads within this above it: one server sample
	-- (Config/Energy.sampling.interval) of the fastest pump may already have added to it.
	setLevelSlack = 0.02,
	levelTolerance = 0.0015, -- "reached" a target within this (the attribute is rounded to 0.001)
	townMph = 25, -- driving to a station
	approachStuds = 8, -- the car lines up this far in front of a station's footprint before pulling in
	parkArriveRadius = 5, -- studs from the footprint's centre that count as parked in it
	maxMiter = 2, -- right-hand lane offset at corners (as Dev/RouteTests)
	-- limpToStation()
	limpSpeedSlack = 1.15, -- the car may touch this x the limp speed (Config/AntiExploit's tolerance)
	standHeight = 3, -- studs above the road the character is put at before the car spawns
	-- Waiting (seconds)
	setLevelTimeout = 10,
	chargeStartTimeout = 10,
	fillTimeout = 240,
	alertTimeout = 10,
	spawnTimeout = 15,
	exitTimeout = 5,
	settleSeconds = 1.5, -- after getting out, teleporting or sitting down, before the next step
	cashSettleSeconds = 1, -- after the target level, for the last charge to reach the Cash attribute
	holdSeconds = 2, -- after a test: brake and hold this long so the car ends stopped
}

local STATUS = "Status" -- attribute: "idle", "running", "done", "stopped" or "failed"
local CURRENT = "Current" -- attribute: what the running test is doing now
local RESULT = "Result" -- attribute: the last result, as JSON
local CANCEL = "Cancel" -- attribute: true asks a running test to stop
local RUN_ID = "RunId" -- attribute: the id of the newest test
local LOG = "[EnergyTests]"
local PERCENT = 100
local SECONDS_PER_MINUTE = 60
local EPSILON = 1e-6

-- Car attributes (docs/phase-5-contracts.md) and the vehicle model contract.
local ENERGY_ATTRIBUTE = "Energy"
local CHARGING_ATTRIBUTE = "Charging"
local LIMP_ATTRIBUTE = "Limp"
local DRIVER_SEAT = "Driver"
local STATION_TAGS: { Energy.StationKind } = {
	"ChargerStall" :: Energy.StationKind,
	"TruckCharger" :: Energy.StationKind,
	"FuelPump" :: Energy.StationKind,
}

type Context = { id: string, name: TestName, started: number }
type Alert = { level: number?, stationId: string? }

local locationsById: { [string]: MapLayout.Location } = {}
for _, location in MapLayout.locations do
	locationsById[location.id] = location
end

---------------------------------------------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------------------------------------------

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

local function cancelRequested(ctx: Context): boolean
	return script:GetAttribute(CANCEL) == true or script:GetAttribute(RUN_ID) ~= ctx.id
end

local function setCurrent(ctx: Context, text: string)
	if script:GetAttribute(RUN_ID) == ctx.id then
		script:SetAttribute(CURRENT, text)
	end
	print(`{LOG} {ctx.name}: {text}`)
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

-- The vehicle's first trim id (its default), or nil for an unknown vehicle.
local function defaultTrimId(vehicleId: string): string?
	local trim = Catalog.defaultTrim(vehicleId)
	return if trim then trim.id else nil
end

local function levelOf(car: Model): number?
	local value = car:GetAttribute(ENERGY_ATTRIBUTE)
	return if type(value) == "number" then value else nil
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

-- Calls a function remote; whatever it answers (nil when the call failed or was refused by Net).
local function invoke(name: string, payload: any?): any
	ensureNet()
	local ok, reply = pcall(Net.invokeServer, name, payload)
	if not ok then
		warn(`{LOG} {name} failed: {reply}`)
		return nil
	end
	return reply
end

-- Sets the driven car's level with DevSetEnergy. The car's Energy attribute is the proof: true once it reads
-- `level` (or up to SETTINGS.setLevelSlack above it, when a station is already filling it).
local function setEnergy(ctx: Context, car: Model, level: number): boolean
	invoke("DevSetEnergy", { level = level })
	return waitFor(ctx, function(): boolean
		local current = levelOf(car)
		return current ~= nil
			and current >= level - SETTINGS.levelTolerance
			and current <= level + SETTINGS.setLevelSlack
	end, car:GetAttributeChangedSignal(ENERGY_ATTRIBUTE), SETTINGS.setLevelTimeout)
end

-- Right-hand lane offset for the stretch a-b, from the lanes of the road under its middle (as Dev/RouteTests).
local function laneOffsetFor(a: Vector3, b: Vector3): number
	local edgeIndex = Graph.nearestEdge((a + b) / 2)
	local edge = if edgeIndex then Graph.edges()[edgeIndex] else nil
	return if edge then RouteTests.Math.rightLaneOffset(edge.lanes, World.laneWidth) else 0
end

-- Road length from `from` to a station (Pathfind's route, plus the last bit off the road), or math.huge.
local function roadDistance(from: CFrame, location: MapLayout.Location): number
	local route = Pathfind.route(from.Position, location.position, from.LookVector)
	if route == nil then
		return math.huge
	end
	local last = route.points[#route.points] or from.Position
	return route.length + flatDistance(location.position, last)
end

-- The station among `candidates` nearest `from` by road, and that distance.
local function nearestByRoad(from: CFrame, candidates: { MapLayout.Location }): (MapLayout.Location?, number)
	local best: MapLayout.Location? = nil
	local bestDistance = math.huge
	for _, location in candidates do
		local distance = roadDistance(from, location)
		if distance < bestDistance then
			best, bestDistance = location, distance
		end
	end
	return best, bestDistance
end

-- Every station on the map that `vehicleId` may use, of the given kinds (default: any kind).
local function stationsFor(vehicleId: string, kinds: { Energy.StationKind }?): { MapLayout.Location }
	local wanted: { [string]: boolean } = {}
	local wantedKinds: { Energy.StationKind } = kinds or STATION_TAGS
	for _, kind in wantedKinds do
		wanted[kind] = true
	end
	local list: { MapLayout.Location } = {}
	for _, location in MapLayout.locations do
		local kind: Energy.StationKind = location.tag :: any
		if wanted[location.tag] and Energy.isCompatible(vehicleId, kind) then
			table.insert(list, location)
		end
	end
	return list
end

-- The station's footprint on the ground: its centre, turned to its yaw (MapLayout's convention).
local function stationFrame(location: MapLayout.Location): CFrame
	return CFrame.new(location.position) * CFrame.Angles(0, math.rad(location.yaw), 0)
end

-- Where a car pulls into a station: lined up in front of its footprint (stations face the road), then its centre.
local function stationApproach(location: MapLayout.Location): (Vector3, Vector3)
	local facing = stationFrame(location).LookVector
	local front = location.position + flat(facing).Unit * (location.size.Z / 2 + SETTINGS.approachStuds)
	return front, location.position
end

-- True when `position` is over the station's footprint (seen from above).
local function overFootprint(location: MapLayout.Location, position: Vector3): boolean
	local localPosition = stationFrame(location):PointToObjectSpace(position)
	return math.abs(localPosition.X) <= location.size.X / 2 and math.abs(localPosition.Z) <= location.size.Z / 2
end

-- Drives the car along the road to `location` at `mph` and parks it in the footprint. Returns AutoDriver's report
-- (reason "no route" / "not driving" when it couldn't start) and the route length driven.
local function parkAt(location: MapLayout.Location, mph: number): (AutoDriver.Report, number)
	local function failed(reason: string): AutoDriver.Report
		return { completed = false, elapsed = 0, stuckEvents = 0, maxMph = 0, reason = reason, pointsReached = 0 }
	end
	local pose = carPose()
	if pose == nil then
		return failed("not driving"), 0
	end
	local front, centre = stationApproach(location)
	local route = Pathfind.route(pose.Position, front, pose.LookVector)
	if route == nil then
		return failed("no route"), 0
	end
	local points = RouteTests.Math.keepRight(route.points, laneOffsetFor, SETTINGS.maxMiter)
	table.insert(points, front)
	table.insert(points, centre)
	local length = RouteTests.Math.length(pose.Position, points)
	local report = AutoDriver.drive(points, {
		targetMph = mph,
		timeout = RouteTests.Math.timeoutFor(length, mph),
		arriveRadius = SETTINGS.parkArriveRadius,
		stopAtEnd = true,
	})
	return report, length
end

-- Sits the player in a fresh `vehicleId`/`trim` (DevSpawnVehicle spawns it in front of the character and seats
-- them). With `at`, the character first gets out of any car and is moved there (facing the way the car should).
-- Returns the car, or nil and why.
local function spawnCar(ctx: Context, vehicleId: string, trim: string, at: CFrame?): (Model?, string?)
	local humanoid = humanoidOf()
	local character = Players.LocalPlayer.Character
	if humanoid == nil or character == nil then
		return nil, "no character"
	end
	local seatSignal = humanoid:GetPropertyChangedSignal("SeatPart")
	if at then
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
		character:PivotTo(at)
		task.wait(SETTINGS.settleSeconds)
	end

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

local function newResult(ctx: Context): Result
	return { name = ctx.name, passed = false, reason = "done", vehicle = nil, elapsed = 0, notes = {} }
end

local function fail(result: Result, reason: string): Result
	result.passed = false
	result.reason = reason
	return result
end

local function note(result: Result, text: string)
	table.insert(result.notes, text)
	print(`{LOG} {result.name}: {text}`)
end

---------------------------------------------------------------------------------------------------------------
-- cruise
---------------------------------------------------------------------------------------------------------------

-- The County Loop's node positions, in loop order.
local function loopPositions(): { Vector3 }
	local positions: { Vector3 } = {}
	for _, id in RoadGraph.loopNodeIds do
		local node = Graph.node(id)
		if node then
			table.insert(positions, node.position)
		end
	end
	return positions
end

-- Points for joining the loop at its node nearest `pose` and driving `laps` laps from there, in the direction
-- that carries straight on from the way the car arrives. Returns the points and where it joins.
local function loopPlan(pose: CFrame, laps: number): ({ Vector3 }?, Vector3?)
	local positions = loopPositions()
	local count = #positions
	if count < 3 then
		return nil, nil
	end
	local startIndex, nearest = 1, math.huge
	for index, position in positions do
		local distance = flatDistance(position, pose.Position)
		if distance < nearest then
			startIndex, nearest = index, distance
		end
	end
	local join = positions[startIndex]
	local route = Pathfind.route(pose.Position, join, pose.LookVector)
	if route == nil then
		return nil, nil
	end
	local points = table.clone(route.points)
	-- The way the car arrives at the loop: the route's last stretch, or its heading if it is already there.
	local arriving = flat(pose.LookVector)
	if #points >= 2 then
		local lastStep = flat(points[#points] - points[#points - 1])
		if lastStep.Magnitude > EPSILON then
			arriving = lastStep
		end
	end
	local nextStep = flat(positions[startIndex % count + 1] - join)
	local previousStep = flat(positions[(startIndex - 2) % count + 1] - join)
	local direction = if nextStep.Magnitude > EPSILON
			and previousStep.Magnitude > EPSILON
			and arriving.Unit:Dot(previousStep.Unit) > arriving.Unit:Dot(nextStep.Unit)
		then -1
		else 1
	for _ = 1, laps do
		for _, index in RouteTests.Math.lapOrder(count, startIndex, direction) do
			table.insert(points, positions[index])
		end
	end
	return RouteTests.Math.keepRight(points, laneOffsetFor, SETTINGS.maxMiter), join
end

local function loopLength(): number
	local positions = loopPositions()
	local length = 0
	for index, position in positions do
		length += flatDistance(position, positions[index % #positions + 1])
	end
	return length
end

local function cruiseTest(ctx: Context, seconds: number, mph: number): Result
	local result = newResult(ctx)
	result.targetMph = mph
	local car = currentCar()
	local chassis = if car then car.PrimaryPart else nil
	if car == nil or chassis == nil then
		return fail(result, "not driving")
	end
	local vehicleId, trimId = carIdentity(car)
	local trim = if vehicleId and trimId then Catalog.getTrim(vehicleId, trimId) else nil
	if vehicleId == nil or trimId == nil or trim == nil then
		return fail(result, "the car has no catalog VehicleId / Trim")
	end
	result.vehicle = `{vehicleId}/{trimId}`
	result.catalogMinutes = trim.energyMinutes

	setCurrent(ctx, "filling up (DevSetEnergy 100 %)")
	if not setEnergy(ctx, car, 1) then
		return fail(result, "DevSetEnergy didn't change the car's Energy (Studio only; is EnergyService running?)")
	end

	local pose = carPose() :: CFrame
	local speed = Units.mphToStuds(mph)
	local needed = (seconds + SETTINGS.settleTimeout) * speed
	local laps = math.ceil(needed / math.max(loopLength(), EPSILON)) + SETTINGS.extraLaps
	local points, join = loopPlan(pose, laps)
	if points == nil or join == nil then
		return fail(result, "no route onto the County Loop")
	end
	local length = RouteTests.Math.length(pose.Position, points)

	-- The driving runs alongside the measurement.
	local changed = Instance.new("BindableEvent")
	local driving = true
	local driveReason = ""
	setCurrent(ctx, `driving to the County Loop, then {laps} lap(s) at {mph} mph`)
	task.spawn(function()
		local report = AutoDriver.drive(points, {
			targetMph = mph,
			timeout = RouteTests.Math.timeoutFor(length, mph),
			stopAtEnd = false,
		})
		driving = false
		driveReason = report.reason
		changed:Fire()
	end)

	-- Joining -> settling (on the loop, getting to speed) -> measuring -> done; Heartbeat tracks the distance.
	local phase = "joining"
	local settlingSince = 0
	local heldSince: number? = nil -- since when the car has held readyFraction of the cruise speed
	local measureStart = 0
	local distance = 0
	local lastPosition = chassis.Position
	local changes: { { time: number, level: number } } = {}
	local heartbeat = RunService.Heartbeat:Connect(function()
		local now = os.clock()
		local position = chassis.Position
		if phase == "joining" then
			if flatDistance(position, join) <= SETTINGS.joinRadius then
				phase = "settling"
				settlingSince = now
				setCurrent(ctx, "on the loop, getting up to speed")
			end
		elseif phase == "settling" then
			local mphNow = Units.studsToMph(flat(chassis.AssemblyLinearVelocity).Magnitude)
			if mphNow >= mph * SETTINGS.readyFraction then
				heldSince = heldSince or now
			else
				heldSince = nil
			end
			if heldSince ~= nil and now - heldSince >= SETTINGS.readyHoldSeconds then
				phase = "measuring"
				measureStart = now
				lastPosition = position
				setCurrent(ctx, `measuring for {seconds} s`)
			elseif now - settlingSince > SETTINGS.settleTimeout then
				phase = "too slow"
				changed:Fire()
			end
		elseif phase == "measuring" then
			distance += flatDistance(position, lastPosition)
			lastPosition = position
			if now - measureStart >= seconds then
				phase = "done"
				changed:Fire()
			end
		end
	end)
	local levelConnection = car:GetAttributeChangedSignal(ENERGY_ATTRIBUTE):Connect(function()
		local level = levelOf(car)
		if phase == "measuring" and level ~= nil then
			table.insert(changes, { time = os.clock(), level = level })
		end
	end)

	-- The drive's own timeout ends it (and this wait) first; this is only a backstop.
	local backstop = RouteTests.Math.timeoutFor(length, mph) + SETTINGS.settleTimeout + seconds
	waitFor(ctx, function(): boolean
		return phase == "done" or phase == "too slow" or not driving
	end, changed.Event, backstop)
	local measured = os.clock() - measureStart
	heartbeat:Disconnect()
	levelConnection:Disconnect()
	AutoDriver.stop()
	changed:Destroy()

	if cancelRequested(ctx) then
		return fail(result, "stopped")
	elseif phase == "too slow" then
		return fail(result, `couldn't hold {round(mph * SETTINGS.readyFraction, 1)} mph on the loop`)
	elseif phase ~= "done" then
		return fail(result, `the drive ended early ({driveReason}) while {phase}`)
	elseif #changes < 2 then
		return fail(result, "the car's Energy didn't change while cruising (is EnergyService running?)")
	end

	-- From the first to the last change of the (rounded) level, so the rounding doesn't skew the rate.
	local first, last = changes[1], changes[#changes]
	local span = last.time - first.time
	local drained = first.level - last.level
	if span <= EPSILON or drained <= 0 then
		return fail(result, "no drain measured")
	end
	local perMinute = drained / span * SECONDS_PER_MINUTE
	local averageSpeed = distance / math.max(measured, EPSILON)
	local expectedPerSecond = Energy.drainPerSecond(vehicleId, trimId, averageSpeed, 0, 0)

	result.measuredSeconds = round(measured, 1)
	result.averageMph = round(Units.studsToMph(averageSpeed), 1)
	result.drainedPercent = round(drained * PERCENT, 2)
	result.drainPerMinute = round(perMinute * PERCENT, 3)
	result.fullMinutes = round(1 / perMinute, 2)
	result.expectedMinutes = if expectedPerSecond > 0
		then round(1 / (expectedPerSecond * SECONDS_PER_MINUTE), 2)
		else nil

	-- At the reference cruise speed the catalog is the target; at any other speed, the model's prediction.
	local reference = if mph == EnergyConfig.cruiseMph then result.catalogMinutes else result.expectedMinutes
	if reference == nil then
		return fail(result, "no reference minutes for this trim")
	end
	result.passed = math.abs(1 / perMinute - reference) <= SETTINGS.cruiseTolerance * reference
	if not result.passed then
		result.reason =
			`full charge lasts {result.fullMinutes} min, expected {reference} ±{SETTINGS.cruiseTolerance * PERCENT} %`
	end
	return result
end

---------------------------------------------------------------------------------------------------------------
-- charge / refuel
---------------------------------------------------------------------------------------------------------------

-- The car for a charge or refuel test: opts.vehicleId, else the one you sit in if it runs on `energy`, else the
-- default (SETTINGS.batteryCar, or the first player-drivable fuel car in the catalog).
local function pickVehicle(energy: "battery" | "fuel", opts: Options): (string?, string?)
	if opts.vehicleId then
		return opts.vehicleId, opts.trim or defaultTrimId(opts.vehicleId)
	end
	local car = currentCar()
	if car then
		local vehicleId, trim = carIdentity(car)
		local vehicle = if vehicleId then Catalog.getVehicle(vehicleId) else nil
		if vehicle and vehicle.energy == energy then
			return vehicleId, trim
		end
	end
	if energy == "battery" then
		return SETTINGS.batteryCar.vehicleId, SETTINGS.batteryCar.trim
	end
	for _, vehicleId in Catalog.vehicleIds() do
		local vehicle = Catalog.getVehicle(vehicleId)
		local trimId = defaultTrimId(vehicleId)
		if vehicle and trimId and vehicle.energy == "fuel" and vehicle.playerDrivable then
			return vehicleId, trimId
		end
	end
	return nil, nil
end

local function fillTest(ctx: Context, opts: Options?): Result
	local options: Options = opts or {}
	local result = newResult(ctx)
	local fuel = ctx.name == "refuel"
	local kind: Energy.StationKind = if fuel then "FuelPump" else "ChargerStall"
	local target = if fuel then SETTINGS.refuelTarget else SETTINGS.chargeTarget
	local window = if fuel then SETTINGS.refuelWindow else SETTINGS.chargeWindow
	result.stationKind = kind
	result.windowSeconds = table.clone(window)

	-- The car.
	local vehicleId, trimId = pickVehicle(if fuel then "fuel" else "battery", options)
	if vehicleId == nil or trimId == nil or Catalog.getTrim(vehicleId, trimId) == nil then
		return fail(result, "no car to test with")
	end
	result.vehicle = `{vehicleId}/{trimId}`
	if not Energy.isCompatible(vehicleId, kind) then
		return fail(result, `{vehicleId} can't use a {kind}`)
	end
	local car = currentCar()
	local currentId: string?, currentTrim: string? = nil, nil
	if car then
		currentId, currentTrim = carIdentity(car)
	end
	if car == nil or currentId ~= vehicleId or currentTrim ~= trimId then
		setCurrent(ctx, `spawning {result.vehicle}`)
		local spawned, why = spawnCar(ctx, vehicleId, trimId, nil)
		if spawned == nil then
			return fail(result, why or "couldn't spawn the car")
		end
		car = spawned
	end
	local driven = car :: Model

	-- The station.
	local pose = carPose()
	if pose == nil then
		return fail(result, "not driving")
	end
	local location: MapLayout.Location? = nil
	if options.station then
		location = locationsById[options.station]
		if location == nil then
			return fail(result, `no MapLayout location "{options.station}"`)
		end
	else
		local candidates: { MapLayout.Location } = {}
		for _, station in stationsFor(vehicleId, { kind }) do
			local kW = if station.attributes then station.attributes.kW else nil
			if fuel or (type(kW) == "number" and kW >= SETTINGS.fastStallMinKW) then
				table.insert(candidates, station)
			end
		end
		location = nearestByRoad(pose, candidates)
		if location == nil then
			return fail(result, `no {if fuel then "fuel pump" else "fast charging stall"} reachable by road`)
		end
	end
	local station = location :: MapLayout.Location
	result.station = station.id
	if station.tag ~= kind or not Energy.isCompatible(vehicleId, kind) then
		return fail(result, `{station.id} is a {station.tag}, not a {kind} this car can use`)
	end

	-- Drive in and park (stopping a little off the centre still counts, as long as it is over the footprint).
	setCurrent(ctx, `driving to {station.displayName} ({station.id})`)
	local report = parkAt(station, SETTINGS.townMph)
	local parkedPose = carPose()
	if not report.completed and not (parkedPose and overFootprint(station, parkedPose.Position)) then
		return fail(result, `didn't park at the station ({report.reason})`)
	end

	-- 10 %, then time the fill.
	setCurrent(ctx, `setting the level to {SETTINGS.startLevel * PERCENT} %`)
	if not setEnergy(ctx, driven, SETTINGS.startLevel) then
		return fail(result, "DevSetEnergy didn't change the car's Energy (Studio only; is EnergyService running?)")
	end
	local fromLevel = levelOf(driven) or SETTINGS.startLevel
	result.fromPercent = round(fromLevel * PERCENT, 1)

	-- The cost is what the cash went down by: drive-to-earn keeps paying out while the player sits in the car,
	-- so only drops count.
	local spent = 0
	local lastCash = cash()
	local cashConnection = Players.LocalPlayer:GetAttributeChangedSignal(Economy.cashAttribute):Connect(function()
		local now = cash()
		if now < lastCash then
			spent += lastCash - now
		end
		lastCash = now
	end)
	-- The clock starts at the first rise after the set level (a stop already running when the level was set
	-- may have added to it before the set; the server's first step after it counts time from before).
	local energySignal = driven:GetAttributeChangedSignal(ENERGY_ATTRIBUTE)
	local started: number? = nil
	local riseConnection = energySignal:Connect(function()
		local level = levelOf(driven)
		if started == nil and level ~= nil and level > fromLevel + EPSILON then
			started = os.clock()
		end
	end)
	local function stopWatching()
		cashConnection:Disconnect()
		riseConnection:Disconnect()
	end

	setCurrent(ctx, "waiting for charging to start")
	if
		not waitFor(ctx, function(): boolean
			return driven:GetAttribute(CHARGING_ATTRIBUTE) == true
		end, driven:GetAttributeChangedSignal(CHARGING_ATTRIBUTE), SETTINGS.chargeStartTimeout)
	then
		stopWatching()
		return fail(result, "charging never started (parked outside the footprint, or not still?)")
	end
	setCurrent(ctx, `filling to {target * PERCENT} %`)
	local reached = waitFor(ctx, function(): boolean
		local level = levelOf(driven)
		return level ~= nil and level >= target - SETTINGS.levelTolerance
	end, energySignal, SETTINGS.fillTimeout)
	local seconds = os.clock() - (started or os.clock())
	task.wait(SETTINGS.cashSettleSeconds)
	stopWatching()
	local toLevel = levelOf(driven) or 0

	result.seconds = round(seconds, 1)
	result.toPercent = round(toLevel * PERCENT, 1)
	result.cost = spent
	-- The price of the range actually charged (the server bills the energy it adds, in whole dollars).
	result.expectedCost = round((toLevel - fromLevel) * Energy.costPerFraction(kind), 0)
	if cancelRequested(ctx) then
		return fail(result, "stopped")
	elseif not reached then
		return fail(result, `stopped filling at {result.toPercent} % (out of cash, or the car moved?)`)
	end

	local onePercent = Energy.costPerFraction(kind) / PERCENT
	-- One server sample either way: the clock starts and stops on samples.
	local slack = EnergyConfig.sampling.interval
	local inWindow = seconds >= window[1] - slack and seconds <= window[2] + slack
	local costOk = math.abs((result.cost or 0) - (result.expectedCost or 0)) <= onePercent + EPSILON
	result.passed = inWindow and costOk
	if not inWindow then
		result.reason = `took {result.seconds} s, outside {window[1]}-{window[2]} s`
	elseif not costOk then
		result.reason = `cost ${result.cost}, expected about ${result.expectedCost}`
	end
	return result
end

---------------------------------------------------------------------------------------------------------------
-- limpToStation
---------------------------------------------------------------------------------------------------------------

-- A node counts as drivable when a paved road leaves it (dirt trails are for off-roaders).
local function pavedEdgeFrom(nodeId: string): (number?, string?)
	local bestEdge: number? = nil
	local bestNeighbor: string? = nil
	local bestLength = -1
	for _, neighbor in Graph.neighbors(nodeId) do
		local edge = Graph.edges()[neighbor.edge]
		if edge and edge.surface ~= "dirt" then
			local length = Graph.edgeLength(neighbor.edge)
			if length > bestLength then
				bestEdge, bestNeighbor, bestLength = neighbor.edge, neighbor.node, length
			end
		end
	end
	return bestEdge, bestNeighbor
end

-- The drivable road-graph node farthest (straight line) from every one of `stations`, and that distance.
local function farthestNode(stations: { MapLayout.Location }): (Graph.Node?, number)
	local best: Graph.Node? = nil
	local bestDistance = -1
	for _, node in Graph.nodes() do
		if pavedEdgeFrom(node.id) ~= nil then
			local nearest = math.huge
			for _, station in stations do
				nearest = math.min(nearest, flatDistance(node.position, station.position))
			end
			if nearest > bestDistance and nearest < math.huge then
				best, bestDistance = node, nearest
			end
		end
	end
	return best, bestDistance
end

-- Where the character stands so DevSpawnVehicle puts the car on `node`'s longest paved road, facing along it:
-- the car spawns Spawning.spawnOffset + half its length in front of the character.
local function spawnStand(node: Graph.Node, vehicleId: string, trim: string): CFrame?
	local edgeIndex, neighborId = pavedEdgeFrom(node.id)
	local neighbor = if neighborId then Graph.node(neighborId) else nil
	local geometry = Catalog.geometry(vehicleId, trim)
	if edgeIndex == nil or neighbor == nil or geometry == nil then
		return nil
	end
	local along = flat(neighbor.position - node.position)
	if along.Magnitude < EPSILON then
		return nil
	end
	local heading = along.Unit
	local carCentre = node.position + heading * math.min(Graph.edgeLength(edgeIndex) / 2, geometry.length)
	local stand = carCentre
		- heading * (Spawning.spawnOffset + geometry.length / 2)
		+ Vector3.yAxis * SETTINGS.standHeight
	return CFrame.lookAt(stand, stand + heading)
end

-- True while the GPS (drawn on this client in Workspace.GpsRoute) shows its arrival marker within the
-- arrival radius of the road nearest `location`.
local function gpsRoutesTo(location: MapLayout.Location): boolean
	local folder = Workspace:FindFirstChild(Gps.route.folderName)
	local carrier = if folder then folder:FindFirstChild(Gps.route.carrierName) else nil
	local pillar = if carrier then carrier:FindFirstChild("ArrivalPillar") else nil
	local base = if carrier then carrier:FindFirstChild("ArrivalBase") else nil
	if pillar == nil or base == nil or not pillar:IsA("Beam") or not base:IsA("Attachment") then
		return false
	end
	local _, _, offRoad = Graph.nearestEdge(location.position)
	return pillar.Enabled and flatDistance(base.WorldPosition, location.position) <= offRoad + Gps.tracking.arriveRadius
end

local function limpTest(ctx: Context, vehicleId: string, trimId: string): Result
	local result = newResult(ctx)
	local vehicle = Catalog.getVehicle(vehicleId)
	if vehicle == nil or not vehicle.playerDrivable or Catalog.getTrim(vehicleId, trimId) == nil then
		return fail(result, `{vehicleId}/{trimId} is not a drivable vehicle and trim`)
	end
	result.vehicle = `{vehicleId}/{trimId}`

	-- The far end of the map for this car.
	local stations = stationsFor(vehicleId, nil)
	if #stations == 0 then
		return fail(result, "no station on the map this car may use")
	end
	local node, distance = farthestNode(stations)
	local stand = if node then spawnStand(node, vehicleId, trimId) else nil
	if node == nil or stand == nil then
		return fail(result, "no drivable road node to start from")
	end
	result.startNode = node.id
	result.straightDistance = round(distance, 0)

	setCurrent(ctx, `spawning {result.vehicle} at {node.id}, {result.straightDistance} studs from the nearest station`)
	local car, why = spawnCar(ctx, vehicleId, trimId, stand)
	if car == nil then
		return fail(result, why or "couldn't spawn the car")
	end

	-- Empty it and wait for the server's alert (heard by this copy's own listener) and limp mode.
	ensureNet()
	local alertEvent = Instance.new("BindableEvent")
	local alert: Alert? = nil
	local alertConnection = Net.onClientEvent("EnergyAlert", function(payload: any)
		if type(payload) == "table" then
			alert = {
				level = if type(payload.level) == "number" then payload.level else nil,
				stationId = if type(payload.stationId) == "string" then payload.stationId else nil,
			}
			alertEvent:Fire()
		end
	end)
	setCurrent(ctx, "emptying the car (DevSetEnergy 0)")
	local emptied = setEnergy(ctx, car, 0)
	local alerted = emptied
		and waitFor(ctx, function(): boolean
			return alert ~= nil
		end, alertEvent.Event, SETTINGS.alertTimeout)
	alertConnection:Disconnect()
	alertEvent:Destroy()
	if not emptied then
		return fail(result, "DevSetEnergy didn't change the car's Energy (Studio only; is EnergyService running?)")
	end
	local limp = waitFor(ctx, function(): boolean
		return car:GetAttribute(LIMP_ATTRIBUTE) == true
	end, car:GetAttributeChangedSignal(LIMP_ATTRIBUTE), SETTINGS.alertTimeout)
	if not limp then
		return fail(result, "the car never went into limp mode (Limp attribute)")
	end

	-- The station: the one the alert named, else the nearest compatible one by road.
	local received = alert
	local location: MapLayout.Location? = nil
	if alerted and received and received.stationId then
		result.alertStation = received.stationId
		location = locationsById[received.stationId]
		if location == nil then
			note(result, `the alert named "{received.stationId}", which isn't a MapLayout location`)
		end
	else
		note(result, "no EnergyAlert with a station came; driving to the nearest compatible station by road")
	end
	local pose = carPose()
	if pose == nil then
		return fail(result, "not driving")
	end
	if location == nil then
		location = nearestByRoad(pose, stations)
	end
	if location == nil then
		return fail(result, "no compatible station reachable by road")
	end
	local station = location :: MapLayout.Location
	result.station = station.id
	result.stationKind = station.tag
	if not Energy.isCompatible(vehicleId, station.tag :: Energy.StationKind) then
		note(result, `{station.id} is a {station.tag}, which this car can't use`)
	end
	result.gpsRouted = alerted and gpsRoutesTo(station)

	-- Limp there and park.
	setCurrent(ctx, `limping to {station.displayName} ({station.id}) at {EnergyConfig.limpMph} mph`)
	local report, length = parkAt(station, EnergyConfig.limpMph)
	local finalPose = carPose()
	result.routeStuds = round(length, 0)
	result.driveSeconds = round(report.elapsed, 1)
	result.maxMph = round(report.maxMph, 1)
	result.arrived = report.completed
		or (finalPose ~= nil and flatDistance(finalPose.Position, station.position) <= Gps.tracking.arriveRadius)
	if cancelRequested(ctx) then
		return fail(result, "stopped")
	end
	result.chargingStarted = result.arrived
		and waitFor(ctx, function(): boolean
			return car:GetAttribute(CHARGING_ATTRIBUTE) == true
		end, car:GetAttributeChangedSignal(CHARGING_ATTRIBUTE), SETTINGS.chargeStartTimeout)

	local slowEnough = report.maxMph <= EnergyConfig.limpMph * SETTINGS.limpSpeedSlack
	result.passed = result.arrived == true and slowEnough
	if not result.arrived then
		result.reason = `didn't reach the station ({report.reason})`
	elseif not slowEnough then
		result.reason = `reached {result.maxMph} mph, over the {EnergyConfig.limpMph} mph limp speed`
	end
	return result
end

---------------------------------------------------------------------------------------------------------------
-- Running a test
---------------------------------------------------------------------------------------------------------------

local function emptyResult(name: string, reason: string): Result
	return { name = name, passed = false, reason = reason, vehicle = nil, elapsed = 0, notes = {} }
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
		warn(`{LOG} a test is already running; EnergyTests.stop() cancels it`)
		return emptyResult(name, "busy")
	end

	local ctx: Context = { id = HttpService:GenerateGUID(false), name = name, started = os.clock() }
	script:SetAttribute(RUN_ID, ctx.id)
	script:SetAttribute(STATUS, "running")
	script:SetAttribute(CANCEL, false)
	script:SetAttribute(RESULT, nil)

	local ok, outcome = pcall(body, ctx)
	local result: Result = if ok then outcome else emptyResult(name, `error: {tostring(outcome)}`)
	if not ok then
		warn(`{LOG} {name} failed: {outcome}`)
	end

	-- Hand the controls back and leave the car stopped.
	AutoDriver.stop()
	if currentCar() ~= nil and not cancelRequested(ctx) then
		AutoDriver.holdStill(SETTINGS.holdSeconds)
	end
	result.elapsed = os.clock() - ctx.started
	printResult(result)

	if script:GetAttribute(RUN_ID) == ctx.id then
		local status = if result.reason == "stopped" then "stopped" elseif result.passed then "done" else "failed"
		script:SetAttribute(RESULT, HttpService:JSONEncode(result))
		script:SetAttribute(CURRENT, nil)
		script:SetAttribute(STATUS, status)
	end
	return result
end

local EnergyTests = {}
EnergyTests.SETTINGS = SETTINGS

-- Cruises the County Loop at `mph` (default Config/Energy.cruiseMph) and measures `seconds` (default 120) of drain.
function EnergyTests.cruise(seconds: number?, mph: number?): Result
	local measureSeconds = seconds or 2 * SECONDS_PER_MINUTE
	local cruiseMph = mph or EnergyConfig.cruiseMph
	if type(measureSeconds) ~= "number" or measureSeconds <= 0 or type(cruiseMph) ~= "number" or cruiseMph <= 0 then
		warn(`{LOG} cruise(seconds, mph) needs positive numbers`)
		return emptyResult("cruise", "bad arguments")
	end
	return runTest("cruise", function(ctx: Context): Result
		return cruiseTest(ctx, measureSeconds, cruiseMph)
	end)
end

-- Times 10 -> 80 % at the nearest fast charging stall with a battery car.
function EnergyTests.charge(opts: Options?): Result
	return runTest("charge", function(ctx: Context): Result
		return fillTest(ctx, opts)
	end)
end

-- Times 10 -> 100 % at the nearest fuel pump with a fuel car.
function EnergyTests.refuel(opts: Options?): Result
	return runTest("refuel", function(ctx: Context): Result
		return fillTest(ctx, opts)
	end)
end

-- Empties a fresh `vehicleId`/`trim` at the far end of the map and limps it to a compatible station.
function EnergyTests.limpToStation(vehicleId: string, trim: string?): Result
	if type(vehicleId) ~= "string" then
		warn(`{LOG} limpToStation(vehicleId, trim) needs a vehicle id`)
		return emptyResult("limpToStation", "bad arguments")
	end
	local trimId = trim or defaultTrimId(vehicleId)
	if trimId == nil then
		warn(`{LOG} no trim for "{vehicleId}"`)
		return emptyResult("limpToStation", "bad arguments")
	end
	return runTest("limpToStation", function(ctx: Context): Result
		return limpTest(ctx, vehicleId, trimId)
	end)
end

local STARTERS: { [string]: (...any) -> Result } = {
	cruise = EnergyTests.cruise,
	charge = EnergyTests.charge,
	refuel = EnergyTests.refuel,
	limpToStation = EnergyTests.limpToStation,
}

-- Starts a test in the background and returns at once: start("cruise", 120, 45), start("charge"),
-- start("refuel"), start("limpToStation", "ohm_spark", "standard"). Poll lastResult() or watch the console.
function EnergyTests.start(name: TestName, ...: any)
	local starter = STARTERS[name]
	if starter == nil then
		warn(`{LOG} unknown test "{name}"; use "cruise", "charge", "refuel" or "limpToStation"`)
		return
	end
	task.spawn(starter, ...)
end

-- The last finished result, or nil while a test runs (or before any has finished).
function EnergyTests.lastResult(): Result?
	local encoded = script:GetAttribute(RESULT)
	if script:GetAttribute(STATUS) == "running" or type(encoded) ~= "string" then
		return nil
	end
	return HttpService:JSONDecode(encoded)
end

-- "idle", "running", "done", "stopped" or "failed", and what the running test is doing.
function EnergyTests.status(): (string, string?)
	local status = script:GetAttribute(STATUS)
	local current = script:GetAttribute(CURRENT)
	return if type(status) == "string" then status else "idle", if type(current) == "string" then current else nil
end

-- Cancels a running test and hands the controls back; clears a "running" status left by a test whose thread died.
function EnergyTests.stop()
	if not RunService:IsStudio() then
		return
	end
	script:SetAttribute(CANCEL, true)
	AutoDriver.stop()
	if script:GetAttribute(STATUS) == "running" then
		script:SetAttribute(STATUS, "stopped")
	end
end

return EnergyTests
