--!strict
-- Studio-only light show test (docs/phase-7-contracts.md "Studio test"; a single-client frame-timing check toward
-- PLAN.md Phase 7's "Three cars run the same show within 100 ms of each other", see below).
--
--   sync(cars)   (default 3) stands the character at a meet spot (default SETTINGS.meetSpotId), spawns a car
--                there with DevSpawnVehicle (it seats the player), waits for it to settle, and starts a show with
--                JoinLightShow using the Studio-only dev fill (Config/LightShows.dev.fillPrefix), so the server
--                adds parked test cars until the show has `cars`. Then it reads the game's LightShowController
--                timing probe until every car has run its first Config dev.probeFiresPerCar cues: for each cue,
--                when it was due and when it actually ran on this client, both in seconds after the shared
--                startAt (server clock). The spread is the largest minus the smallest lateness over all those
--                cues; it passes at or under Config dev.maxSpread (100 ms). Finally it leaves the show
--                (LeaveLightShow), which ends it and removes the test cars, unless keepShow is set.
--   start(cars)  runs sync in the background and returns at once; lastResult() returns its result once done
--                (nil while it runs). Results are printed too, so get_console_output shows them.
--
-- What this does and doesn't prove: every car is drawn by the same frame loop on this one client, so the spread is
-- only how far into a frame each cue fell (frame jitter, a hitch, a late streamed-in car). It can't see a client
-- whose server clock is off or whose LightShowStart came late. It is the contract's single-client check, NOT the
-- PLAN.md acceptance ("three cars within 100 ms" across players): that needs three clients against one clock
-- (a live server with several devices, or Studio's multi-client test), and stays a check for Davis.
--
-- Run from MCP execute_luau in the Client datamodel of a playtest (the character must be spawned):
--   require(game.Players.LocalPlayer.PlayerScripts.Client.Dev.LightShowTests).start(3)
--   require(game.Players.LocalPlayer.PlayerScripts.Client.Dev.LightShowTests).lastResult()
--
-- The probe is a BindableFunction the game's LightShowController puts under itself in Studio, so this works from
-- MCP's own copy of the modules. Remotes go through this copy's own Net (set up on first use, as Dev/ShopTests
-- does). Does nothing outside Studio (CLAUDE.md hard rule 8); the server refuses the dev fill and
-- DevSpawnVehicle outside Studio too. The client loader never boots it.

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local Catalog = require(Shared.Vehicle.Catalog)
local LightShows = require(Shared.Config.LightShows)
local MapLayout = require(Shared.Config.MapLayout)
local Net = require(Shared.Net)
local Spawning = require(Shared.Config.Spawning)
local Units = require(Shared.Util.Units)

local LOG = "[LightShowTests]"
local DRIVER_SEAT = "Driver"
local STATUS = "Status" -- attributes on this ModuleScript, shared by every copy of it
local RESULT = "Result"

export type CarTiming = {
	car: string, -- the car's full name
	slot: number,
	cues: { { cue: number, scheduled: number, fired: number, late: number } }, -- seconds after startAt
}

export type Result = {
	name: string,
	passed: boolean,
	reason: string, -- "done", or why it ended early
	meetSpotId: string?,
	showId: string?,
	routineId: string?,
	carsWanted: number,
	carsTimed: number, -- cars that ran all their timed cues
	spread: number?, -- seconds between the latest and the earliest cue lateness
	maxSpread: number,
	scope: string, -- what was measured: this client's frame timing only (see the header)
	timings: { CarTiming },
	elapsed: number,
}

-- A dev tool, so its numbers live here (like Dev/EnergyTests' SETTINGS).
local SETTINGS = {
	meetSpotId = "lk_overlook",
	vehicleId = "ohm_spark", -- the player's car
	standHeight = 3, -- studs above the footprint the character is put at before the car spawns
	pollSeconds = 0.1, -- how often waits re-check
	exitTimeout = 5,
	spawnTimeout = 20, -- seconds for DevSpawnVehicle to seat the player
	afterMoveWait = 1.5, -- seconds after moving the character before asking the server for a car
	settleTimeout = 15, -- seconds for the car to come to rest on its suspension
	settleHold = 1, -- seconds it must stay under Config/LightShows.client.stillMph
	joinTries = 3, -- a "not still" refusal is retried after settleHold
	probeTimeout = 10, -- seconds past the show's start to wait for every car's first cues
}

local netReady = false

-- This copy of Net may be MCP's own (not the game's), so make sure it knows the remotes.
local function ensureNet()
	if not netReady then
		Net.setupClient()
		netReady = true
	end
end

local function invoke(name: string, payload: any?): any
	ensureNet()
	local ok, reply = pcall(Net.invokeServer, name, payload)
	if not ok then
		warn(`{LOG} {name} failed: {reply}`)
		return nil
	end
	return reply
end

-- Waits (dev test only) until `test()` is true or `timeout` seconds pass; returns whether it came true.
local function waitUntil(test: () -> boolean, timeout: number): boolean
	local deadline = os.clock() + timeout
	while not test() do
		if os.clock() >= deadline then
			return false
		end
		task.wait(SETTINGS.pollSeconds)
	end
	return true
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

local function meetSpot(id: string): MapLayout.Location?
	for _, location in MapLayout.locations do
		if location.id == id and location.tag == "MeetSpot" then
			return location
		end
	end
	return nil
end

local function emptyResult(reason: string, cars: number): Result
	return {
		name = "sync",
		passed = false,
		reason = reason,
		meetSpotId = nil,
		showId = nil,
		routineId = nil,
		carsWanted = cars,
		carsTimed = 0,
		spread = nil,
		maxSpread = LightShows.dev.maxSpread,
		scope = "single client: frame timing of cues scheduled from one startAt; cross-client sync not measured",
		timings = {},
		elapsed = 0,
	}
end

-- Puts the player in a fresh car in the meet spot's first slot, facing the footprint's front.
local function parkAtSpot(location: MapLayout.Location): (Model?, string?)
	local humanoid = humanoidOf()
	local character = Players.LocalPlayer.Character
	if humanoid == nil or character == nil then
		return nil, "no character"
	end
	if humanoid.SeatPart ~= nil then
		humanoid.Sit = false
		humanoid.Jump = true
		if not waitUntil(function(): boolean
			return humanoid.SeatPart == nil
		end, SETTINGS.exitTimeout) then
			return nil, "couldn't get out of the car"
		end
	end
	local trim = Catalog.defaultTrim(SETTINGS.vehicleId)
	local geometry = if trim then Catalog.geometry(SETTINGS.vehicleId, trim.id) else nil
	if trim == nil or geometry == nil then
		return nil, `no vehicle "{SETTINGS.vehicleId}" in the catalog`
	end
	local frame = LightShows.footprintFrame(location.position, location.yaw)
	local slot = LightShows.slotFrames(frame, location.size)[1]
	local heading = frame.LookVector
	-- DevSpawnVehicle puts the car's centre spawnOffset + length / 2 in front of the character.
	local stand = slot.Position
		- heading * (Spawning.spawnOffset + geometry.length / 2)
		+ Vector3.yAxis * SETTINGS.standHeight
	character:PivotTo(CFrame.lookAt(stand, stand + heading))
	-- Give the move time to reach the server: DevSpawnVehicle spawns in front of where the server sees the
	-- character, and asking at once spawned the car back where the player had been.
	task.wait(SETTINGS.afterMoveWait)

	ensureNet()
	Net.fireServer("DevSpawnVehicle", { vehicleId = SETTINGS.vehicleId, trim = trim.id })
	local seated = waitUntil(function(): boolean
		local car = currentCar()
		return car ~= nil and car:GetAttribute("VehicleId") == SETTINGS.vehicleId
	end, SETTINGS.spawnTimeout)
	if not seated then
		return nil, `{SETTINGS.vehicleId} didn't spawn with you in it (is its model in ServerStorage.VehicleModels?)`
	end
	-- Let it come to rest on its suspension.
	local stillSpeed = Units.mphToStuds(LightShows.client.stillMph)
	local stillSince: number? = nil
	waitUntil(function(): boolean
		local car = currentCar()
		local chassis = if car then car.PrimaryPart else nil
		if chassis == nil then
			return false
		end
		local velocity = chassis.AssemblyLinearVelocity
		if Vector3.new(velocity.X, 0, velocity.Z).Magnitude > stillSpeed then
			stillSince = nil
			return false
		end
		local since = stillSince or os.clock()
		stillSince = since
		return os.clock() - since >= SETTINGS.settleHold
	end, SETTINGS.settleTimeout)
	return currentCar(), nil
end

-- The game's LightShowController timing probe, or nil when that controller isn't running.
local function probeFunction(): BindableFunction?
	local scripts = Players.LocalPlayer:FindFirstChild("PlayerScripts")
	local client = if scripts then scripts:FindFirstChild("Client") else nil
	local controllers = if client then client:FindFirstChild("Controllers") else nil
	local controller = if controllers then controllers:FindFirstChild("LightShowController") else nil
	local probe = if controller then controller:FindFirstChild("Probe") else nil
	return if probe ~= nil and probe:IsA("BindableFunction") then probe else nil
end

-- Groups the probe's fires by car (each car's first fires, in the order they ran).
local function timingsFrom(fires: { any }): { CarTiming }
	local byCar: { [string]: CarTiming } = {}
	local order: { CarTiming } = {}
	for _, fire in fires do
		local timing = byCar[fire.car]
		if timing == nil then
			timing = { car = fire.car, slot = fire.slot, cues = {} }
			byCar[fire.car] = timing
			table.insert(order, timing)
		end
		table.insert(timing.cues, {
			cue = fire.cue,
			scheduled = fire.scheduled,
			fired = fire.fired,
			late = fire.fired - fire.scheduled,
		})
	end
	table.sort(order, function(a, b)
		return a.slot < b.slot
	end)
	return order
end

local function syncTest(cars: number, keepShow: boolean): Result
	local started = os.clock()
	local result = emptyResult("done", cars)
	local location = meetSpot(SETTINGS.meetSpotId)
	if location == nil then
		result.reason = `no MeetSpot "{SETTINGS.meetSpotId}" in Config/MapLayout`
		return result
	end
	result.meetSpotId = location.id
	local probe = probeFunction()
	if probe == nil then
		result.reason = "the game's LightShowController isn't running (no Probe)"
		return result
	end

	local car, why = parkAtSpot(location)
	if car == nil then
		result.reason = why or "no car"
		return result
	end
	print(`{LOG} parked {car:GetFullName()} at {location.displayName}; starting a show with {cars} cars`)

	local reply: any = nil
	for _ = 1, SETTINGS.joinTries do
		reply = invoke("JoinLightShow", {
			meetSpotId = `{LightShows.dev.fillPrefix}{cars}:{location.id}`,
		})
		if type(reply) == "table" and reply.ok then
			break
		end
		task.wait(SETTINGS.settleHold)
	end
	if type(reply) ~= "table" or not reply.ok or type(reply.showId) ~= "string" then
		result.reason = `JoinLightShow refused: {if type(reply) == "table" then reply.message else "no reply"}`
		return result
	end
	result.showId = reply.showId
	result.routineId = reply.routineId
	local startAt: number = reply.startAt

	-- Wait for every car's first cues to run on this client.
	local perCar = LightShows.dev.probeFiresPerCar
	local entry: any = nil
	local deadline = startAt - Workspace:GetServerTimeNow() + SETTINGS.probeTimeout
	local complete = waitUntil(function(): boolean
		entry = probe:Invoke(reply.showId)
		if type(entry) ~= "table" then
			return false
		end
		local timings = timingsFrom(entry.fires)
		local done = 0
		for _, timing in timings do
			if #timing.cues >= perCar then
				done += 1
			end
		end
		return done >= cars
	end, math.max(deadline, SETTINGS.pollSeconds))

	local timings: { CarTiming } = if type(entry) == "table" then timingsFrom(entry.fires) else {}
	result.timings = timings
	local earliest, latest = math.huge, -math.huge
	for _, timing in timings do
		if #timing.cues >= perCar then
			result.carsTimed += 1
		end
		for _, fire in timing.cues do
			earliest = math.min(earliest, fire.late)
			latest = math.max(latest, fire.late)
		end
	end
	if latest >= earliest then
		result.spread = latest - earliest
	end

	if not keepShow then
		invoke("LeaveLightShow")
	end

	if not complete or result.carsTimed < cars then
		result.reason = `only {result.carsTimed} of {cars} cars ran {perCar} cues (are the test cars' models built?)`
	elseif result.spread == nil or result.spread > LightShows.dev.maxSpread then
		result.reason = "spread over the limit"
	else
		result.passed = true
	end
	result.elapsed = os.clock() - started
	return result
end

local function printResult(result: Result)
	local verdict = if result.passed then "PASSED" else "FAILED"
	local spread = if result.spread then `{math.round(result.spread * 1000)} ms` else "n/a"
	-- Labelled for what it measures (see the header): this client's frame timing, not cross-client sync.
	print(
		`{LOG} sync (this client's cue timing; cross-client sync not measured): {verdict} ({result.reason}); `
			.. `spread {spread}, {result.carsTimed}/{result.carsWanted} cars`
	)
	local ok, encoded = pcall(HttpService.JSONEncode, HttpService, result)
	if ok then
		print(`{LOG} sync: {encoded}`)
	end
end

local LightShowTests = {}
LightShowTests.SETTINGS = SETTINGS

-- Starts a show with `cars` cars (default 3) at SETTINGS.meetSpotId and measures how closely their first cues
-- ran together on this client. Yields until done (about leadIn + a few seconds).
function LightShowTests.sync(cars: number?, keepShow: boolean?): Result
	local count = cars or 3
	if not (RunService:IsStudio() and RunService:IsRunning()) then
		warn(`{LOG} runs only in a Studio playtest (Client datamodel)`)
		return emptyResult("studio only", count)
	end
	if type(count) ~= "number" or count < 1 or count > LightShows.show.maxCars then
		warn(`{LOG} sync(cars) needs 1..{LightShows.show.maxCars} cars`)
		return emptyResult("bad arguments", count)
	end
	if script:GetAttribute(STATUS) == "running" then
		warn(`{LOG} a test is already running`)
		return emptyResult("busy", count)
	end
	script:SetAttribute(STATUS, "running")
	script:SetAttribute(RESULT, nil)
	local ok, outcome = pcall(syncTest, math.floor(count), keepShow == true)
	local result: Result = if ok then outcome else emptyResult(`error: {tostring(outcome)}`, count)
	printResult(result)
	local encoded = pcall(function()
		script:SetAttribute(RESULT, HttpService:JSONEncode(result))
	end)
	if not encoded then
		script:SetAttribute(RESULT, nil)
	end
	script:SetAttribute(STATUS, if result.passed then "passed" else "failed")
	return result
end

-- Runs sync in the background and returns at once; read lastResult() when it is done.
function LightShowTests.start(cars: number?, keepShow: boolean?)
	task.spawn(LightShowTests.sync, cars, keepShow)
end

-- The last finished result (decoded), or nil while a test runs or before the first.
function LightShowTests.lastResult(): any
	if script:GetAttribute(STATUS) == "running" then
		return nil
	end
	local encoded = script:GetAttribute(RESULT)
	if type(encoded) ~= "string" then
		return nil
	end
	local ok, decoded = pcall(HttpService.JSONDecode, HttpService, encoded)
	return if ok then decoded else nil
end

return LightShowTests
