--!strict
-- Studio-only thruster tests (PLAN.md Phase 10 acceptance; docs/phase-10-contracts.md "Tests"). Each one drives an
-- Arc with Dev/AutoDriver using only what a player's client can do: the UseAbility remote (plus the Studio-only
-- DevAbility resetCooldowns between runs), the car attributes the server sets (Ability, AbilityStartsAt,
-- AbilityEndsAt, boostHopReadyAt, flightReadyAt), the DragStripUpdate and VehicleReset it sends, and the car's own
-- pose. Services/AbilityService decides every ability and Services/DragStripService times every run; the tests
-- measure what they did:
--   hops(n)      n boost-hops (default 50) in an Arc Boost on the drag strip's Return Road, driving west in its
--                right-hand lane (outside the No-Fly Zone). The AutoDriver builds speed past Config/Abilities
--                boostHop.minSpeedMph, the test asks UseAbility boostHop and keeps driving through the hop, then
--                brakes once the wheels are down and holds still past the server's own settle check (Config/Abilities
--                landingSeconds + settleSeconds after AbilityEndsAt, plus SETTINGS.resetWatchSeconds). Every hop must
--                end upright (the chassis's UpVector.Y at least Config/Abilities.uprightDot), on its wheels (a ray down
--                the car from each wheel hub finds the ground within reach), clear of the map (the chassis box
--                overlaps nothing collidable in Workspace.Map), with no VehicleReset (an anti-exploit strike or the
--                server's unstuck) and able to drive away. DevAbility resetCooldowns clears the cooldown before each
--                hop; the car is put back at the start of the road when the road runs out or it ends off its lane.
--   flights(n)   n flights (default 50) in an Arc Flight on open ground in the Flight Field (ms_flight_field): asks
--                UseAbility flight from a standstill, plays one of SETTINGS.flightPatterns (roll and flip input)
--                while it flies, lets the controlled landing finish, then the same checks. The car is put back on
--                the spot when it lands too far away.
--   forged()     asks UseAbility for what the server must refuse: a hop standing still and at SETTINGS.slowMph
--                (under the hop's minimum), flight in an Arc Boost (its trim has none), a hop during a hop and
--                while it recharges, both abilities in an Arc trim without them and in a car with no thrusters,
--                flight on the Return Road outside the Flight Field, and both inside the No-Fly Zone
--                (ms_control_nofly), the hop at speed. Each must be refused with nothing changed on the car: no
--                new ability window, no cooldown.
--   drag()       an Arc stopped just behind gate 1 until the strip arms, then down the strip with the AutoDriver to
--                past gate 4. Every frame (Heartbeat) the test notes where the chassis's front face is (the point
--                the server times; its centre too), how fast it moves and Workspace:GetServerTimeNow(), and times
--                each gate crossing the way the server does: Config/DragStrip's gates, frontPoint and crossingTime
--                (the cubic through the two frames either side of the plane). The server's time (DragStripUpdate
--                finished) and its gate 2 and 3 splits must match the client's within SETTINGS.dragTolerance
--                (±0.05 s).
--   all()        forged(), then hops(5) and flights(5), then drag().
--   start(name, ...)  runs any of them in the background and returns at once; lastResult() returns its result once
--                done (nil while it runs), status() what it's doing, stop() cancels it and lets go of the controls.
-- Each returns a Result (see the type): { name, passed, reason, checks, elapsed, ... } with a Summary for hops and
-- flights (counts, the worst final tilt, stuck runs, resets, the fastest climb), the forged cases and the drag
-- times. Every check is printed as it finishes, so get_console_output shows them even if execute_luau stops waiting.
--
-- Run from MCP execute_luau in the Client datamodel of a playtest (a character is enough: every test spawns its own
-- car). Runs take minutes, longer than an execute_luau call waits:
--   require(game.Players.LocalPlayer.PlayerScripts.Client.Dev.AbilityTests).start("all")
--   require(game.Players.LocalPlayer.PlayerScripts.Client.Dev.AbilityTests).start("hops", 50)
--   require(game.Players.LocalPlayer.PlayerScripts.Client.Dev.AbilityTests).start("flights", 50)
--   require(game.Players.LocalPlayer.PlayerScripts.Client.Dev.AbilityTests).start("forged")
--   require(game.Players.LocalPlayer.PlayerScripts.Client.Dev.AbilityTests).start("drag")
--   require(game.Players.LocalPlayer.PlayerScripts.Client.Dev.AbilityTests).lastResult()
--
-- Driving goes through AutoDriver's Bridge (see its header); remotes go through this copy's own Net (set up on first
-- use, as Dev/JobTests does), and this copy listens to VehicleReset, Notify and DragStripUpdate itself. A flight's
-- roll and flip input goes into the game's own InputController (setOverride, where every key and touch button
-- ends up) through this module's own Bridge: in Studio the game's client scripts call AbilityTests.serve() once,
-- and that copy puts a BindableFunction named "Bridge" under this module. With no bridge up, the input is
-- approximated through AutoDriver instead (full steer toward a point far to the side, full throttle toward one far
-- ahead; brake can't be asked that way) and each run says which path it used (inputPath). State every copy must
-- see (running, cancel, the last result) lives in attributes on this ModuleScript.
--
-- Placing cars: DevSpawnVehicle puts a car Spawning.spawnOffset + half its length in front of where the server
-- last saw the character, on the ground there; so the test gets out, moves the character (streaming the map in
-- round it), waits SETTINGS.standSettleSeconds and spawns. A client PivotTo of a car counts as a teleport to
-- AntiExploit, so a car is only ever put back by spawning a fresh one. AntiExploit removes a player at
-- Config/AntiExploit.strikesToKick strikes: a test stops early, and says so, once SETTINGS.strikeGuard more would.
--
-- Does nothing outside Studio (CLAUDE.md hard rule 8); the server refuses DevAbility and DevSpawnVehicle outside
-- Studio too. The client loader never boots it.

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local Abilities = require(Shared.Config.Abilities)
local AntiExploit = require(Shared.Config.AntiExploit)
local AutoDriver = require(script.Parent.AutoDriver)
local Catalog = require(Shared.Vehicle.Catalog)
local DragStrip = require(Shared.Config.DragStrip)
local Graph = require(Shared.Road.Graph)
local MapLayout = require(Shared.Config.MapLayout)
local Net = require(Shared.Net)
local RouteTests = require(script.Parent.RouteTests)
local Spawning = require(Shared.Config.Spawning)
local Types = require(Shared.Types)
local Units = require(Shared.Util.Units)
local World = require(Shared.Config.World)

local ClientFolder = (script.Parent :: Instance).Parent :: Instance

export type TestName = "hops" | "flights" | "forged" | "drag" | "all"

export type Check = { name: string, passed: boolean, detail: string }

-- One hop or flight, from the ask to the drive away.
export type AbilityRun = {
	index: number,
	ability: string,
	vehicle: string, -- "vehicleId/trim"
	replaced: boolean, -- the car was put back (a fresh spawn) before this run
	askedMph: number, -- forward speed when UseAbility was asked
	reply: string, -- what UseAbility answered
	allowed: boolean,
	pattern: string?, -- flights: the SETTINGS.flightPatterns entry played
	inputPath: string?, -- flights: "bridge", "host" (this copy is the game's) or "autodriver" (approximate)
	rise: number, -- studs: the chassis's highest point above where it was at the ask
	maxTilt: number, -- degrees from upright, the most seen from the ask to the end of the settle
	finalTilt: number, -- degrees from upright after the settle
	maxUpSpeed: number, -- studs/s, the fastest climb seen
	maxDownSpeed: number, -- studs/s, the fastest fall seen
	maxHorizontalSpeed: number, -- studs/s across the ground
	speedGain: number, -- studs/s across the ground over the speed at the ask
	landedAfter: number?, -- seconds after AbilityEndsAt the wheels were down (nil: not within landingTimeout)
	wheelsDown: number, -- wheels whose ray found the ground after the settle
	upright: boolean,
	inside: string?, -- the map part the chassis overlaps after the settle, if any
	resets: { string }, -- VehicleReset reasons during the run (and any that came after its checks: "(late)")
	droveAway: boolean,
	stuck: boolean, -- off its wheels, inside the map or couldn't drive away
	passed: boolean,
	reason: string, -- "ok", or the first thing that failed
}

-- hops() and flights() in numbers.
export type Summary = {
	asked: number, -- runs started
	allowed: number, -- UseAbility said yes
	passed: number,
	failed: number,
	stuck: number,
	resets: number, -- runs the server reset (anti-exploit or unstuck)
	replaced: number, -- times the car was put back
	maxTilt: number, -- degrees, the most seen in any run (flips included)
	maxFinalTilt: number, -- degrees, the most tilted any run ended
	worstRun: number?, -- the run that ended most tilted
	slowestLanding: number?, -- seconds after AbilityEndsAt, the latest touchdown
	minRise: number?, -- studs, the least any allowed run rose
	maxRise: number,
	maxUpSpeed: number, -- studs/s
	maxDownSpeed: number,
	maxHorizontalSpeed: number,
	maxSpeedGain: number,
	failures: { string }, -- "run 7: <why>", the first SETTINGS.maxFailuresListed
	runs: { AbilityRun },
}

-- One forged UseAbility.
export type ForgedCase = {
	name: string,
	ability: string,
	vehicle: string,
	mph: number, -- forward speed when it was asked
	where: string, -- how far inside or outside the Flight Field and the No-Fly Zone the car was
	reply: string,
	refused: boolean,
	unchanged: boolean,
	changes: string, -- the car attributes that changed, or ""
	expected: string?, -- the Config/Abilities message this refusal should be ("tooSlow", "noAbility.flight")
	asExpected: boolean?, -- the reply was that message (shown, not checked: the server picks which rule to name)
}

-- One gate of the drag run, in seconds from gate 1 (on the server clock).
export type GateTime = {
	gate: number,
	client: number?, -- the chassis front's crossing, as the server times it (nil: not seen crossing)
	centre: number?, -- the chassis centre's crossing
	server: number?, -- the server's time or split for this gate
	error: number?, -- client - server
}

export type DragReport = {
	vehicle: string,
	armed: boolean,
	state: string, -- the last DragStripUpdate's state ("none" when none came)
	message: string?, -- a fault's message
	serverTime: number?, -- seconds, gate 1 to the last gate (DragStripUpdate finished)
	clientTime: number?, -- the same from this client's own crossings of the chassis front
	centreTime: number?, -- and of the chassis centre
	error: number?, -- clientTime - serverTime
	serverLag: number?, -- seconds the server saw the front cross gate 1 after this client did (its startedAt)
	gates: { GateTime },
	maxMph: number,
	best: number?,
	rank: number?,
	updates: { string }, -- every DragStripUpdate from the stop behind gate 1 on, as text
	leaderboard: string?, -- GetDragLeaderboard afterwards, as text
}

export type Result = {
	name: string,
	passed: boolean,
	skipped: boolean, -- the test couldn't run here (the reason says why); not a failure of the game
	reason: string, -- "done", or why it ended early
	checks: { Check },
	elapsed: number,
	notes: { string },
	notices: { string }, -- the Notify toasts the server sent during the test, in order
	hops: Summary?,
	flights: Summary?,
	forged: { ForgedCase }?,
	drag: DragReport?,
}

type CarSpec = { vehicleId: string, trim: string }

-- Driving input held for a while during a flight: steer rolls, throttle and brake flip (docs/phase-10-contracts.md).
type InputStep = { steer: number, throttle: number, brake: number, seconds: number }
type Pattern = { name: string, steps: { InputStep } }

local function step(steer: number, throttle: number, brake: number, seconds: number): InputStep
	return { steer = steer, throttle = throttle, brake = brake, seconds = seconds }
end

-- A dev tool, so its numbers live here rather than in Shared/Config (like Dev/JobTests' SETTINGS).
local SETTINGS = {
	-- The cars (docs/phase-10-contracts.md; Config/Abilities.byTrim).
	hopCar = { vehicleId = "ohm_arc", trim = "boost" } :: CarSpec,
	flightCar = { vehicleId = "ohm_arc", trim = "flight" } :: CarSpec,
	plainArc = { vehicleId = "ohm_arc", trim = "performance" } :: CarSpec, -- the Arc trim with no abilities
	plainCar = { vehicleId = "ohm_spark", trim = "standard" } :: CarSpec, -- a car with no thrusters at all
	dragCar = { vehicleId = "ohm_arc", trim = "performance" } :: CarSpec,
	defaultRuns = 50,
	allRuns = 5, -- hops and flights in all()
	maxRuns = 500,
	-- Where: Config/MapLayout ids, the tag of the drag-strip gates and the map's root folder in the Workspace.
	flightField = "ms_flight_field",
	noFlyZone = "ms_control_nofly",
	gateTag = "DragStripGate",
	mapFolder = "Map",
	-- hops(): the Return Road from ms_ret_2520 west to ms_return_w_1, one straight 2,250 studs long, in its
	-- right-hand lane. A pass starts runwayStart studs in and ends runwayEnd short of the far end; the car is put
	-- back at the start when less than runwayNeeded is left ahead of it, or when it ends more than laneSlack studs
	-- off its lane or turned more than headingSlack degrees from the road.
	runway = { from = "ms_ret_2520", to = "ms_return_w_1" },
	runwayStart = 40,
	runwayEnd = 150,
	runwayNeeded = 500,
	laneSlack = 10,
	headingSlack = 30,
	joinStuds = 30, -- a drive rejoins the lane this far ahead of the car
	hopMph = 40, -- the cruise held before and through a hop
	hopSpeedMargin = 8, -- the hop is asked once the car is this many mph over the hop's minimum...
	speedHoldSeconds = 1, -- ...and has stayed there this long (the server judges a smoothed speed)
	runUpTimeout = 12,
	minHopRise = 1.5, -- studs the chassis must rise for a hop to count as one
	-- flights(): the first of these offsets from the Flight Field's centre (studs along its length, across it) that
	-- is flat open ground: the ground there faces up (normal Y at least flatNormal) and no collidable map part stands
	-- in a box spotClearance studs round it, from clearLift above the ground to spotHeight above that (so the
	-- ground and road slabs stay below the box, and ramps don't).
	flightSpots = {
		Vector2.new(0, 0),
		Vector2.new(-150, 0),
		Vector2.new(150, 0),
		Vector2.new(0, 120),
		Vector2.new(0, -120),
	},
	flatNormal = 0.98,
	spotClearance = 30,
	clearLift = 0.5,
	spotHeight = 20,
	flightDrift = 120, -- the car is put back when it lands farther than this from the spot
	preFlightHold = 1, -- seconds braked before each flight, so it starts from a standstill
	minFlightRise = 10, -- studs the chassis must rise for a flight to count as one
	-- The input played during a flight, run by run in turn, after inputDelay seconds of hands-off climb: steps of
	-- steer (-1 left .. 1 right), throttle and brake (0..1), each held `seconds`. Steer rolls the car and throttle
	-- or brake flips it (docs/phase-10-contracts.md); how far and which way is Controllers/AbilityController's.
	-- Every pattern fits inside a 4 s flight (Config/Abilities.flight.durationSeconds) less inputDelay.
	inputDelay = 0.5,
	flightPatterns = {
		{ name = "hands off", steps = {} },
		{ name = "steer left, then right", steps = { step(-1, 0, 0, 0.8), step(1, 0, 0, 0.8) } },
		{ name = "throttle held", steps = { step(0, 1, 0, 1.5) } },
		{ name = "brake held", steps = { step(0, 0, 1, 1.5) } },
		{ name = "long steer right", steps = { step(1, 0, 0, 2.5) } },
		{ name = "steer with throttle, then with brake", steps = { step(-1, 1, 0, 1.2), step(1, 0, 1, 1.2) } },
		{
			name = "rock left and right",
			steps = { step(-1, 0, 0, 0.4), step(1, 0, 0, 0.4), step(-1, 0, 0, 0.4), step(1, 0, 0, 0.4) },
		},
	} :: { Pattern },
	-- Without the input bridge: AutoDriver steers toward a point fallbackReach studs to the side (at a cruise of 0)
	-- or ahead (at fallbackFlipMph).
	fallbackReach = 200,
	fallbackFlipMph = 60,
	-- Landing and settling.
	landingTimeout = 12, -- seconds after AbilityEndsAt for the wheels to be down
	settleSlack = 0.5, -- held still this much beyond Config/Abilities.settleSeconds...
	resetWatchSeconds = 2, -- ...and this much more, for the server's unstuck check to answer
	wheelReach = 1.5, -- studs below a wheel's rest bottom a ray may find the ground (suspension travel)
	minWheelsDown = 3, -- of four: one wheel may hang over a kerb or a road edge
	overlapShrink = 0.2, -- studs off every side of the chassis box in the map query (resting on it isn't in it)
	driveAwayStuds = 25,
	driveAwayMph = 12,
	driveAwayArrive = 4,
	driveAwayTimeout = 10,
	maxRefusedInARow = 3, -- refusals in a row end hops() and flights(): the server says no for a reason to fix
	maxFailuresListed = 10,
	-- forged()
	slowMph = 10, -- the too-slow hop is asked at about this speed...
	slowSlack = 3, -- ...within this many mph (and always this many under the hop's minimum)
	noFlyRoute = { from = "ms_gate", to = "ms_range_end" }, -- the street through the No-Fly Zone
	noFlyMph = 32,
	scanStep = 2, -- studs between the points checked when finding the stretch of road inside a zone
	zoneMargin = 20, -- studs a car must be inside (or outside) a zone for a case to count
	outsideFieldAlong = 1500, -- flight outside the Flight Field: this far along the Return Road (x about 1,020)
	forgedWatchSeconds = 1.2, -- after a forged ask, watched this long for anything changing on the car
	attributeSlack = 0.1, -- seconds: a watch during a real hop ends this long before the hop's window does
	driveTimeout = 20, -- seconds for a forged() drive to end at its last point
	-- drag()
	dragStage = 3, -- studs from the chassis's front to gate 1's plane when it stops to arm (DragStrip.staging.depth)
	dragEnd = { node = "ms_strip_e", short = 100 }, -- the drive ends this far short of the strip's end node
	dragArrive = 10,
	armTimeout = 15,
	resultTimeout = 10, -- seconds after the drive for the finished (or fault) update
	dragTolerance = 0.05, -- PLAN.md Phase 10 acceptance: ±0.05 s
	millisecondsOver = 100, -- a server time this many times the client's is taken to be in milliseconds
	-- Placing cars and the character.
	standHeight = 3,
	standSettleSeconds = 1.5, -- the server must see the character there before DevSpawnVehicle
	probeUp = 40, -- ground rays start this far above a point...
	probeDown = 200, -- ...and look this far down
	streamTimeout = 10,
	spawnTimeout = 15,
	exitTimeout = 5,
	settleSeconds = 1.5, -- after getting out or sitting down, before the next step
	-- Remotes: seconds between calls of each (Net's burst and refill; a call over them is dropped).
	remoteGaps = { UseAbility = 1.1, DevAbility = 0.6, GetDragLeaderboard = 2.1 } :: { [string]: number },
	-- What Config/Abilities should say, used (and noted) only when it doesn't.
	fallbacks = {
		settleSeconds = 2,
		uprightDot = 0.9,
		minSpeedMph = 20,
		hopSeconds = 2,
		flightSeconds = 4,
		landingSeconds = 5,
	},
	-- AntiExploit: a test stops once this many more strikes would reach Config/AntiExploit.strikesToKick.
	strikeGuard = 2,
	-- Housekeeping.
	maxNotices = 60,
	holdSeconds = 2, -- after a test: brake and hold this long so the car ends stopped
}

local STATUS = "Status" -- attribute: "idle", "running", "done", "skipped", "stopped" or "failed"
local CURRENT = "Current" -- attribute: what the running test is doing now
local RESULT = "Result" -- attribute: the last result, as JSON
local CANCEL = "Cancel" -- attribute: true asks a running test to stop
local RUN_ID = "RunId" -- attribute: the id of the newest test
local LOG = "[AbilityTests]"
local BRIDGE_NAME = "Bridge"
local PROBE_NAME = "AbilityTestsProbe"
local EPSILON = 1e-6

-- The vehicle model contract (docs/phase-1-contracts.md) and docs/phase-10-contracts.md "Shared names".
local DRIVER_SEAT = "Driver"
local VEHICLE_ID = "VehicleId"
local TRIM = "Trim"
local WHEELS = { "WheelFL", "WheelFR", "WheelRL", "WheelRR" }
local HOP = "boostHop"
local FLIGHT = "flight"
local ABILITY = "Ability"
local STARTS_AT = "AbilityStartsAt"
local ENDS_AT = "AbilityEndsAt"
local CAR_ATTRIBUTES = { ABILITY, STARTS_AT, ENDS_AT, HOP .. "ReadyAt", FLIGHT .. "ReadyAt" }
-- VehicleReset reasons that come with an anti-exploit strike: AntiExploit's own verdicts and AbilityService's
-- out-of-bounds offense. (Its settle check's move, "unstuck", is no strike, but still fails a run.)
local STRIKE_REASONS = { "speed", "teleport", "ability" }

-- Config/Abilities belongs to the ability-server helper; the names read here are the contract's. Read loosely, so
-- a missing one is noted and stood in for (SETTINGS.fallbacks) rather than breaking the test.
local abilitiesConfig: any = Abilities
-- Config/DragStrip's pure rules (gates, frontPoint, crossingTime) are the ones Services/DragStripService times
-- with; drag() measures with the same ones, read loosely like Config/Abilities.
local dragConfig: any = DragStrip

-- What this client sees of a DragStripUpdate (docs/phase-10-contracts.md "Shared names").
type DragUpdate = {
	at: number, -- os.clock() it arrived
	state: string,
	time: number?,
	best: number?,
	rank: number?,
	gate: number?, -- the gate a split is for, when the server says
	startedAt: number?, -- server clock time the front crossed gate 1
	message: string?,
	text: string,
}

-- Everything the server tells this client during a test, kept as it arrives.
type Watch = {
	resets: { { at: number, reason: string } }, -- VehicleReset (anti-exploit or unstuck moved the car)
	notices: { { at: number, text: string } },
	drag: { DragUpdate },
	changed: BindableEvent, -- fires after every reset, notice and drag update
	connections: { RBXScriptConnection },
}

type Context = {
	id: string,
	name: TestName,
	started: number,
	result: Result,
	watch: Watch,
	prefix: string, -- put before every check's name (all() runs several tests in one)
	noted: { [string]: boolean }, -- notes already made once
}

-- What UseAbility answers (docs/phase-10-contracts.md "Shared names").
type AbilityReply = { ok: boolean, message: string, startsAt: number?, endsAt: number?, readyAt: number? }

-- A straight stretch of road, in its right-hand lane.
type Line = { origin: Vector3, heading: Vector3, right: Vector3, length: number, offset: number }

-- A drive running in the background (startDrive).
type DriveHandle = { done: boolean, report: AutoDriver.Report? }

-- What a running hop or flight did, sampled every frame while it runs.
type Monitor = {
	startY: number,
	startSpeed: number, -- across the ground, at the start
	rise: number,
	maxTilt: number,
	maxUp: number,
	maxDown: number,
	maxHorizontal: number,
	stop: () -> (),
}

-- A drag-strip gate as a vertical plane through `point`: `normal` points the way the run goes.
type Gate = { index: number, point: Vector3, normal: Vector3 }

-- The gate crossings seen during a drag run (server clock): the chassis's front face (what the server times) and
-- its centre.
type Sampler = { front: { [number]: number }, centre: { [number]: number }, maxMph: number, stop: () -> () }

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

local function numberOrNil(value: any): number?
	return if type(value) == "number" and value == value and math.abs(value) ~= math.huge then value else nil
end

local function serverNow(): number
	return Workspace:GetServerTimeNow()
end

local function nameOf(spec: CarSpec): string
	return `{spec.vehicleId}/{spec.trim}`
end

local function cancelRequested(ctx: Context): boolean
	return script:GetAttribute(CANCEL) == true or script:GetAttribute(RUN_ID) ~= ctx.id
end

local function setCurrent(ctx: Context, text: string)
	if script:GetAttribute(RUN_ID) == ctx.id then
		script:SetAttribute(CURRENT, text)
	end
	print(`{LOG} {ctx.name}: {ctx.prefix}{text}`)
end

local function note(ctx: Context, text: string)
	table.insert(ctx.result.notes, ctx.prefix .. text)
	print(`{LOG} {ctx.name}: {ctx.prefix}{text}`)
end

-- A note made once per test, however often its reason comes up.
local function noteOnce(ctx: Context, key: string, text: string)
	if not ctx.noted[key] then
		ctx.noted[key] = true
		note(ctx, text)
	end
end

-- Adds a check and returns it, so a later finding (a reset that came late) can still change it.
local function check(ctx: Context, name: string, passed: boolean, detail: string): Check
	local item: Check = { name = ctx.prefix .. name, passed = passed, detail = detail }
	table.insert(ctx.result.checks, item)
	print(`{LOG} {ctx.name}: {if passed then "PASS" else "FAIL"} {item.name} ({detail})`)
	return item
end

-- Waits until `test()` is true, re-checking whenever `signal` fires, for at most `timeout` seconds; a cancel ends
-- the wait too. A test that errors counts as false. Returns whether `test()` came true.
local function waitFor(ctx: Context, test: () -> boolean, signal: RBXScriptSignal, timeout: number): boolean
	local function holds(): boolean
		local ok, value = pcall(test)
		return ok and value == true
	end
	if holds() then
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
			if holds() then
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
		finish(holds())
	end)
	return coroutine.yield()
end

-- Waits `seconds`, or less when the test is cancelled.
local function pause(ctx: Context, seconds: number)
	if seconds > 0 then
		waitFor(ctx, function(): boolean
			return false
		end, script:GetAttributeChangedSignal(CANCEL), seconds)
	end
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

-- Asks for the map round `position` (streaming); quietly carries on when the engine says no.
local function streamAround(position: Vector3)
	pcall(function()
		Players.LocalPlayer:RequestStreamAroundAsync(position, SETTINGS.streamTimeout)
	end)
end

local netReady = false

-- This copy of Net may be MCP's own (not the game's), so make sure it knows the remotes.
local function ensureNet()
	if not netReady then
		Net.setupClient()
		netReady = true
	end
end

---------------------------------------------------------------------------------------------------------------
-- Config/Abilities
---------------------------------------------------------------------------------------------------------------

local function configNumber(section: any, key: string): number?
	return if type(section) == "table" then numberOrNil(section[key]) else nil
end

-- A Config/Abilities number, or SETTINGS' stand-in for it (noted once).
local function tunable(ctx: Context, section: any, label: string, key: string, fallback: number): number
	local value = configNumber(section, key)
	if value ~= nil then
		return value
	end
	noteOnce(ctx, label, `Config/Abilities has no {label}: using {fallback}`)
	return fallback
end

local function settleTime(ctx: Context): number
	return tunable(ctx, abilitiesConfig, "settleSeconds", "settleSeconds", SETTINGS.fallbacks.settleSeconds)
end

local function uprightDot(ctx: Context): number
	return tunable(ctx, abilitiesConfig, "uprightDot", "uprightDot", SETTINGS.fallbacks.uprightDot)
end

local function minHopMph(ctx: Context): number
	local section = abilitiesConfig.boostHop
	return tunable(ctx, section, "boostHop.minSpeedMph", "minSpeedMph", SETTINGS.fallbacks.minSpeedMph)
end

local function durationOf(ctx: Context, ability: string): number
	local section = abilitiesConfig[ability]
	local fallback = if ability == HOP then SETTINGS.fallbacks.hopSeconds else SETTINGS.fallbacks.flightSeconds
	return tunable(ctx, section, `{ability}.durationSeconds`, "durationSeconds", fallback)
end

-- Seconds from AbilityEndsAt to the server's settle check: <ability>.landingSeconds + settleSeconds. Until then the
-- server counts the ability as still running (a new ask is refused) and may yet move a stuck car.
local function settleCheckAfter(ctx: Context, ability: string): number
	local section = abilitiesConfig[ability]
	local landing =
		tunable(ctx, section, `{ability}.landingSeconds`, "landingSeconds", SETTINGS.fallbacks.landingSeconds)
	return landing + settleTime(ctx)
end

-- A Lua pattern for the Config/Abilities message at `path` (under messages; %d and %s match anything), or nil.
local function messagePattern(path: { string }): string?
	local value: any = abilitiesConfig.messages
	for _, key in path do
		value = if type(value) == "table" then value[key] else nil
	end
	if type(value) ~= "string" then
		return nil
	end
	local escaped = string.gsub(value, "[%^%$%(%)%.%[%]%*%+%-%?]", "%%%0")
	escaped = string.gsub(escaped, "%%s", ".-")
	escaped = string.gsub(escaped, "%%d", "%%d+")
	return "^" .. escaped .. "$"
end

-- Whether Config/Abilities.byTrim gives `spec` the ability.
local function trimHas(spec: CarSpec, ability: string): boolean
	local byTrim = abilitiesConfig.byTrim
	local list = if type(byTrim) == "table" then byTrim[nameOf(spec)] else nil
	return type(list) == "table" and table.find(list, ability) ~= nil
end

-- A note of what the server allows next to what this client saw (Config/Abilities.bounds).
local function boundsNote(ability: string, summary: Summary): string
	local bounds = if type(abilitiesConfig.bounds) == "table" then abilitiesConfig.bounds[ability] else nil
	local function bound(key: string): string
		local value = configNumber(bounds, key)
		return if value then ` (bounds.{ability}.{key} {value})` else ""
	end
	return `fastest climb {summary.maxUpSpeed} studs/s{bound("maxUpSpeed")}, fastest fall {summary.maxDownSpeed}`
		.. `{bound("maxDownSpeed")}, fastest across the ground {summary.maxHorizontalSpeed}`
		.. `{bound("maxHorizontalSpeed")}, most speed gained {summary.maxSpeedGain}{bound("maxSpeedGain")}`
end

---------------------------------------------------------------------------------------------------------------
-- The car
---------------------------------------------------------------------------------------------------------------

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
		if node:IsA("Model") and node:GetAttribute(VEHICLE_ID) ~= nil then
			return node
		end
		node = node.Parent
	end
	return nil
end

local function carIdentity(car: Model): (string?, string?)
	local vehicleId, trim = car:GetAttribute(VEHICLE_ID), car:GetAttribute(TRIM)
	return if type(vehicleId) == "string" then vehicleId else nil, if type(trim) == "string" then trim else nil
end

local function isCar(car: Model?, spec: CarSpec): boolean
	if car == nil then
		return false
	end
	local vehicleId, trim = carIdentity(car)
	return vehicleId == spec.vehicleId and trim == spec.trim
end

local function carName(car: Model): string
	local vehicleId, trim = carIdentity(car)
	return `{vehicleId or "?"}/{trim or "?"}`
end

-- Signed forward speed in mph, read straight from the chassis.
local function forwardMph(chassis: BasePart): number
	return Units.studsToMph(chassis.AssemblyLinearVelocity:Dot(chassis.CFrame.LookVector))
end

-- Degrees between the car's up and the world's.
local function tiltOf(frame: CFrame): number
	return math.deg(math.acos(math.clamp(frame.UpVector.Y, -1, 1)))
end

local function wheelRadiusOf(spec: CarSpec): number
	local geometry = Catalog.geometry(spec.vehicleId, spec.trim)
	return if geometry then geometry.wheelRadius else 0
end

-- Every character, plus `extra`: what ground and wheel rays look past.
local function ignoreList(extra: { Instance }?): { Instance }
	local list: { Instance } = if extra then table.clone(extra) else {}
	for _, player in Players:GetPlayers() do
		if player.Character then
			table.insert(list, player.Character)
		end
	end
	return list
end

-- The first collidable thing straight down from above `position`, ignoring characters and `ignore`.
local function groundHit(position: Vector3, ignore: { Instance }?): RaycastResult?
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = ignoreList(ignore)
	params.RespectCanCollide = true
	local origin = position + Vector3.yAxis * SETTINGS.probeUp
	return Workspace:Raycast(origin, Vector3.yAxis * -(SETTINGS.probeUp + SETTINGS.probeDown), params)
end

-- How many wheels stand on something: a ray down the car (along -UpVector, so a car on its roof finds nothing) from
-- each wheel hub, wheelRadius + SETTINGS.wheelReach long.
local function wheelsDown(car: Model, chassis: BasePart, wheelRadius: number): number
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local extra: { Instance } = { car }
	params.FilterDescendantsInstances = ignoreList(extra)
	params.RespectCanCollide = true
	local down = -chassis.CFrame.UpVector * (wheelRadius + SETTINGS.wheelReach)
	local count = 0
	for _, name in WHEELS do
		local hub = chassis:FindFirstChild(name)
		if hub ~= nil and hub:IsA("Attachment") and Workspace:Raycast(hub.WorldPosition, down, params) ~= nil then
			count += 1
		end
	end
	return count
end

-- The collidable map part the chassis box (SETTINGS.overlapShrink smaller on every side) overlaps, or nil. Uses a
-- throwaway query part on this client only, so the exact shapes count (a ramp's wedge, not its bounding box).
local function insideMap(car: Model, chassis: BasePart): string?
	local map = Workspace:FindFirstChild(SETTINGS.mapFolder)
	local shrink = Vector3.one * (2 * SETTINGS.overlapShrink)
	local probe = Instance.new("Part")
	probe.Name = PROBE_NAME
	probe.Anchored = true
	probe.CanCollide = false
	probe.CanTouch = false
	probe.CanQuery = false
	probe.Transparency = 1
	probe.Size = (chassis.Size - shrink):Max(Vector3.one * SETTINGS.overlapShrink)
	probe.CFrame = chassis.CFrame
	probe.Parent = Workspace
	local params = OverlapParams.new()
	if map ~= nil then
		params.FilterType = Enum.RaycastFilterType.Include
		params.FilterDescendantsInstances = { map }
	else
		params.FilterType = Enum.RaycastFilterType.Exclude
		local extra: { Instance } = { car, probe }
		params.FilterDescendantsInstances = ignoreList(extra)
	end
	params.RespectCanCollide = true
	params.CollisionGroup = chassis.CollisionGroup
	local hits = Workspace:GetPartsInPart(probe, params)
	probe:Destroy()
	return if #hits > 0 then hits[1]:GetFullName() else nil
end

-- The car attributes an ability writes, as text, for before/after comparisons.
local function carState(car: Model): { [string]: string }
	local state: { [string]: string } = {}
	for _, name in CAR_ATTRIBUTES do
		state[name] = tostring(car:GetAttribute(name))
	end
	return state
end

---------------------------------------------------------------------------------------------------------------
-- What the server says: VehicleReset, Notify and DragStripUpdate
---------------------------------------------------------------------------------------------------------------

local function parseDrag(payload: any): DragUpdate?
	if type(payload) ~= "table" or type(payload.state) ~= "string" then
		return nil
	end
	local time = numberOrNil(payload.time)
	local gate = numberOrNil(payload.gate) or numberOrNil(payload.index)
	local message = if type(payload.message) == "string" then payload.message else nil
	local parts = { payload.state }
	if time then
		table.insert(parts, `time {time}`)
	end
	if gate then
		table.insert(parts, `gate {gate}`)
	end
	if numberOrNil(payload.best) then
		table.insert(parts, `best {payload.best}`)
	end
	if numberOrNil(payload.rank) then
		table.insert(parts, `rank {payload.rank}`)
	end
	if message then
		table.insert(parts, `"{message}"`)
	end
	return {
		at = os.clock(),
		state = payload.state,
		time = time,
		best = numberOrNil(payload.best),
		rank = numberOrNil(payload.rank),
		gate = gate,
		startedAt = numberOrNil(payload.startedAt),
		message = message,
		text = table.concat(parts, ", "),
	}
end

local function newWatch(): Watch
	ensureNet()
	local watch: Watch = {
		resets = {},
		notices = {},
		drag = {},
		changed = Instance.new("BindableEvent"),
		connections = {},
	}
	table.insert(
		watch.connections,
		Net.onClientEvent("VehicleReset", function(payload: any)
			local reason = if type(payload) == "table" then textOf(payload.reason) else ""
			table.insert(watch.resets, { at = os.clock(), reason = if reason ~= "" then reason else "reset" })
			print(`{LOG} VehicleReset: {reason}`)
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
		Net.onClientEvent("DragStripUpdate", function(payload: any)
			local update = parseDrag(payload)
			if update then
				table.insert(watch.drag, update)
				print(`{LOG} DragStripUpdate: {update.text}`)
				watch.changed:Fire()
			end
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

-- The reasons of every VehicleReset since `since` (os.clock()).
local function resetsSince(watch: Watch, since: number): { string }
	local reasons: { string } = {}
	for _, reset in watch.resets do
		if reset.at >= since then
			table.insert(reasons, reset.reason)
		end
	end
	return reasons
end

-- True once SETTINGS.strikeGuard more anti-exploit strikes would get the player removed. Strikes decay, so only the
-- last Config/AntiExploit.strikeDecaySeconds count.
local function nearKick(ctx: Context): (boolean, number)
	local strikes = 0
	for _, reason in resetsSince(ctx.watch, os.clock() - AntiExploit.strikeDecaySeconds) do
		if table.find(STRIKE_REASONS, reason) ~= nil then
			strikes += 1
		end
	end
	return strikes > 0 and strikes >= AntiExploit.strikesToKick - SETTINGS.strikeGuard, strikes
end

---------------------------------------------------------------------------------------------------------------
-- Remotes
---------------------------------------------------------------------------------------------------------------

local lastCallAt: { [string]: number } = {}

-- Waits until Net's rate limit lets the remote `name` be called again.
local function waitGap(name: string)
	local gap = (SETTINGS.remoteGaps[name] or 0) - (os.clock() - (lastCallAt[name] or -math.huge))
	if gap > 0 then
		task.wait(gap)
	end
end

-- Calls a function remote no faster than Net's rate limit for it allows (a call over the limit is dropped, and its
-- empty answer would read as a refusal). Returns the raw answer (nil when there was none).
local function call(name: string, payload: any?): any
	ensureNet()
	waitGap(name)
	lastCallAt[name] = os.clock()
	local ok, answer = pcall(Net.invokeServer, name, payload)
	if not ok then
		warn(`{LOG} {name} failed: {answer}`)
		return nil
	end
	return answer
end

local function useAbility(ability: string): AbilityReply?
	local raw = call("UseAbility", { ability = ability })
	if type(raw) ~= "table" then
		return nil
	end
	return {
		ok = raw.ok == true,
		message = textOf(raw.message),
		startsAt = numberOrNil(raw.startsAt),
		endsAt = numberOrNil(raw.endsAt),
		readyAt = numberOrNil(raw.readyAt),
	}
end

local function describe(reply: AbilityReply?): string
	if reply == nil then
		return "no answer"
	end
	return `{if reply.ok then "ok" else "refused"}: "{reply.message}"`
end

-- Studio only: clears the driven car's cooldowns. True when the server said ok (noted once when it didn't).
local function resetCooldowns(ctx: Context): boolean
	local raw = call("DevAbility", { action = "resetCooldowns" })
	local ok = raw == true or (type(raw) == "table" and raw.ok == true)
	if not ok then
		local message = if type(raw) == "table" then textOf(raw.message) else tostring(raw)
		noteOnce(ctx, "devAbility", `DevAbility resetCooldowns didn't say ok ("{message}"): runs may meet a cooldown`)
	end
	return ok
end

-- The server time the running ability's window ends: the reply's, else the car's attribute, else now + `duration`.
local function windowEnd(car: Model, reply: AbilityReply, duration: number): number
	return reply.endsAt or numberOrNil(car:GetAttribute(ENDS_AT)) or serverNow() + duration
end

---------------------------------------------------------------------------------------------------------------
-- The input bridge (as Dev/AutoDriver's: see the header)
---------------------------------------------------------------------------------------------------------------

local isHost = false

-- The InputController this copy can reach: the game's own in the copy that serves the bridge.
local function inputController(): any
	local folder = ClientFolder:FindFirstChild("Controllers")
	local moduleScript = if folder then folder:FindFirstChild("InputController") else nil
	if moduleScript == nil or not moduleScript:IsA("ModuleScript") then
		return nil
	end
	local ok, loaded = pcall(require :: any, moduleScript)
	return if ok then loaded else nil
end

local function setInputHere(controls: Types.Controls?): boolean
	local input = inputController()
	if input == nil or type(input.setOverride) ~= "function" then
		return false
	end
	input.setOverride(controls)
	return true
end

local BRIDGE_COMMANDS: { [string]: (...any) -> ...any } = {
	setInput = setInputHere,
}

local function inputBridge(): BindableFunction?
	if isHost then
		return nil
	end
	local found = script:FindFirstChild(BRIDGE_NAME)
	return if found ~= nil and found:IsA("BindableFunction") then found else nil
end

-- How flight input reaches the game: "host" (this copy is the game's), "bridge", or "autodriver" (approximate).
local function inputPath(): string
	if isHost then
		return "host"
	end
	return if inputBridge() ~= nil then "bridge" else "autodriver"
end

-- Sets (or with nil, clears) the game's InputController override. False when no bridge reaches it.
local function setInput(controls: Types.Controls?): boolean
	if isHost then
		return setInputHere(controls)
	end
	local bridge = inputBridge()
	if bridge == nil then
		return false
	end
	local ok, answer = pcall(function(): any
		return bridge:Invoke("setInput", controls)
	end)
	return ok and answer == true
end

-- Lets go of everything a test drives with: the AutoDriver and the bridge's input override.
local function releaseControls()
	AutoDriver.stop()
	if inputPath() ~= "autodriver" then
		setInput(nil)
	end
end

---------------------------------------------------------------------------------------------------------------
-- Driving
---------------------------------------------------------------------------------------------------------------

-- Starts the AutoDriver along `points` at `mph` in the background (it stops at the last point). AutoDriver.stop() or
-- the next AutoDriver call ends it early.
local function startDrive(points: { Vector3 }, mph: number): DriveHandle
	local handle: DriveHandle = { done = false, report = nil }
	task.spawn(function()
		handle.report = AutoDriver.drive(points, { targetMph = mph, stopAtEnd = true })
		handle.done = true
	end)
	return handle
end

-- Waits until the car's forward speed has stayed within [minMph, maxMph] (and `extra()` held) for
-- SETTINGS.speedHoldSeconds. Checked every frame, only while waiting.
local function waitForSpeed(
	ctx: Context,
	chassis: BasePart,
	minMph: number,
	maxMph: number,
	timeout: number,
	extra: (() -> boolean)?
): boolean
	local since: number? = nil
	return waitFor(ctx, function(): boolean
		local mph = forwardMph(chassis)
		if mph >= minMph and mph <= maxMph and (extra == nil or extra()) then
			local started = since or os.clock()
			since = started
			return os.clock() - started >= SETTINGS.speedHoldSeconds
		end
		since = nil
		return false
	end, RunService.Heartbeat, timeout)
end

-- A short drive to `target` at a crawl: true when the car got there (it isn't stuck).
local function driveAway(target: Vector3): boolean
	local report = AutoDriver.drive({ target }, {
		targetMph = SETTINGS.driveAwayMph,
		timeout = SETTINGS.driveAwayTimeout,
		arriveRadius = SETTINGS.driveAwayArrive,
		stopAtEnd = true,
	})
	return report.completed
end

-- Without the bridge: holds one input step through AutoDriver, which feeds the same InputController override.
-- Steer: a drive toward a point far to that side at a cruise of 0 (full steer, no throttle). Throttle: toward a
-- point far ahead at SETTINGS.fallbackFlipMph. Brake can't be asked that way, so that step is flown hands-off.
local function stepThroughAutoDriver(ctx: Context, input: InputStep)
	local car = currentCar()
	local chassis = if car then car.PrimaryPart else nil
	if chassis == nil then
		return
	end
	local frame = chassis.CFrame
	local forward = flat(frame.LookVector)
	if forward.Magnitude < EPSILON then
		forward = flat(-frame.UpVector) -- nose straight up or down: the roof says which way is ahead
	end
	if forward.Magnitude < EPSILON then
		pause(ctx, input.seconds)
		return
	end
	forward = forward.Unit
	local right = Vector3.new(-forward.Z, 0, forward.X)
	local target: Vector3? = nil
	local mph = 0
	if input.steer ~= 0 then
		target = frame.Position + right * (math.sign(input.steer) * SETTINGS.fallbackReach)
	elseif input.throttle > 0 then
		target = frame.Position + forward * SETTINGS.fallbackReach
		mph = SETTINGS.fallbackFlipMph
	elseif input.brake > 0 then
		noteOnce(ctx, "fallbackBrake", "no input bridge: brake steps were flown hands-off")
	end
	if target == nil then
		pause(ctx, input.seconds)
		return
	end
	local points = { target }
	task.spawn(function()
		AutoDriver.drive(points, { targetMph = mph, timeout = input.seconds + 1, stopAtEnd = false })
	end)
	pause(ctx, input.seconds)
	AutoDriver.stop()
end

-- Plays `pattern` on the driven car and lets go afterwards. Returns the input path used (see inputPath).
local function playPattern(ctx: Context, pattern: Pattern): string
	local path = inputPath()
	if path == "autodriver" and #pattern.steps > 0 then
		noteOnce(
			ctx,
			"fallbackInput",
			"no input bridge (AbilityTests.serve() isn't called by the game in Studio): roll and flip input went "
				.. "through AutoDriver, approximately"
		)
	end
	for _, input in pattern.steps do
		if cancelRequested(ctx) then
			break
		end
		if path == "autodriver" then
			stepThroughAutoDriver(ctx, input)
		else
			local controls = { throttle = input.throttle, brake = input.brake, steer = input.steer, handbrake = false }
			if not setInput(controls) then
				noteOnce(ctx, "bridgeFailed", "the input bridge didn't take the flight input: that step was hands-off")
			end
			pause(ctx, input.seconds)
		end
	end
	releaseControls()
	return path
end

---------------------------------------------------------------------------------------------------------------
-- The map: zones, straight roads and the drag strip
---------------------------------------------------------------------------------------------------------------

local function volumeFrame(volume: MapLayout.Location): CFrame
	return CFrame.new(volume.position) * CFrame.Angles(0, math.rad(volume.yaw), 0)
end

-- How far inside a volume (FlightZone, NoFlyZone) `position` is across the ground: the least distance to its four
-- sides, negative outside.
local function depthInside(volume: MapLayout.Location, position: Vector3): number
	local here = volumeFrame(volume):PointToObjectSpace(position)
	return math.min(volume.size.X / 2 - math.abs(here.X), volume.size.Z / 2 - math.abs(here.Z))
end

-- "N studs inside the Flight Field, M studs outside the No-Fly Zone".
local function whereText(position: Vector3): string
	local parts: { string } = {}
	for _, zone in { { SETTINGS.flightField, "the Flight Field" }, { SETTINGS.noFlyZone, "the No-Fly Zone" } } do
		local volume = locationsById[zone[1]]
		if volume then
			local depth = depthInside(volume, position)
			local side = if depth >= 0 then "inside" else "outside"
			table.insert(parts, `{round(math.abs(depth), 0)} studs {side} {zone[2]}`)
		end
	end
	return table.concat(parts, ", ")
end

-- Right-hand lane offset for the stretch a-b, from the lanes of the road under its middle (as Dev/JobTests).
local function laneOffsetFor(a: Vector3, b: Vector3): number
	local edgeIndex = Graph.nearestEdge((a + b) / 2)
	local edge = if edgeIndex then Graph.edges()[edgeIndex] else nil
	return if edge then RouteTests.Math.rightLaneOffset(edge.lanes, World.laneWidth) else 0
end

-- The straight road from node `fromId` to node `toId`, driven in its right-hand lane.
local function lineBetween(fromId: string, toId: string): (Line?, string?)
	local from, to = Graph.node(fromId), Graph.node(toId)
	if from == nil or to == nil then
		return nil, `Config/RoadGraph has no node "{if from == nil then fromId else toId}"`
	end
	local along = flat(to.position - from.position)
	if along.Magnitude < EPSILON then
		return nil, `{fromId} -> {toId} has no length`
	end
	local heading = along.Unit
	return {
		origin = from.position,
		heading = heading,
		right = Vector3.new(-heading.Z, 0, heading.X),
		length = along.Magnitude,
		offset = laneOffsetFor(from.position, to.position),
	},
		nil
end

local function linePoint(line: Line, along: number): Vector3
	return line.origin + line.heading * along + line.right * line.offset
end

-- How far along the line `position` is, and how far right of its lane (negative: left).
local function lineFrame(line: Line, position: Vector3): (number, number)
	local offset = flat(position - line.origin)
	return offset:Dot(line.heading), offset:Dot(line.right) - line.offset
end

-- The stretch of `line` (from, to: studs along) whose lane lies `margin` inside `volume`, or nil.
local function stretchInside(line: Line, volume: MapLayout.Location, margin: number): (number?, number?)
	local first: number? = nil
	local last: number? = nil
	local along = 0
	while along <= line.length do
		if depthInside(volume, linePoint(line, along)) >= margin then
			first = first or along
			last = along
		end
		along += SETTINGS.scanStep
	end
	return first, last
end

-- Flat open ground at the first SETTINGS.flightSpots offset in the Flight Field that has it (see SETTINGS).
local function flightSpot(field: MapLayout.Location): (Vector3?, string?)
	local frame = volumeFrame(field)
	local map = Workspace:FindFirstChild(SETTINGS.mapFolder)
	streamAround(field.position)
	for _, offset in SETTINGS.flightSpots do
		local spot = frame:PointToWorldSpace(Vector3.new(offset.X, 0, offset.Y))
		local car = currentCar()
		local ignore: { Instance } = if car then { car } else {}
		local hit = groundHit(spot, ignore)
		if hit ~= nil and hit.Normal.Y >= SETTINGS.flatNormal then
			local params = OverlapParams.new()
			if map ~= nil then
				params.FilterType = Enum.RaycastFilterType.Include
				params.FilterDescendantsInstances = { map }
			else
				params.FilterType = Enum.RaycastFilterType.Exclude
				params.FilterDescendantsInstances = ignoreList(ignore)
			end
			params.RespectCanCollide = true
			local centre = hit.Position + Vector3.yAxis * (SETTINGS.clearLift + SETTINGS.spotHeight / 2)
			local size = Vector3.new(SETTINGS.spotClearance * 2, SETTINGS.spotHeight, SETTINGS.spotClearance * 2)
			if #Workspace:GetPartBoundsInBox(CFrame.new(centre), size, params) == 0 then
				return hit.Position, nil
			end
		end
	end
	return nil, "no flat open ground at any SETTINGS.flightSpots offset in the Flight Field (is the map streamed in?)"
end

-- The drag-strip gates as planes, in gate order, every normal pointing the way the run goes: Config/DragStrip's
-- own (what the server times against), else built from the Config/MapLayout locations the same way.
local function dragGates(): { Gate }
	local gates: { Gate } = {}
	local ok, shared = pcall(function(): any
		return if type(dragConfig.gates) == "function" then dragConfig.gates() else nil
	end)
	if ok and type(shared) == "table" then
		for _, gate in shared do
			local index = if type(gate) == "table" then numberOrNil(gate.index) else nil
			if index ~= nil and typeof(gate.origin) == "Vector3" and typeof(gate.normal) == "Vector3" then
				table.insert(gates, { index = index, point = gate.origin, normal = gate.normal })
			end
		end
	end
	if #gates == 0 then
		for _, location in MapLayout.locations do
			local index = if location.tag == SETTINGS.gateTag and location.attributes
				then numberOrNil(location.attributes.index)
				else nil
			if index ~= nil then
				local normal = flat(CFrame.Angles(0, math.rad(location.yaw), 0).LookVector).Unit
				table.insert(gates, { index = index, point = location.position, normal = normal })
			end
		end
	end
	table.sort(gates, function(a: Gate, b: Gate): boolean
		return a.index < b.index
	end)
	if #gates >= 2 and flat(gates[#gates].point - gates[1].point):Dot(gates[1].normal) < 0 then
		for _, gate in gates do
			gate.normal = -gate.normal
		end
	end
	return gates
end

-- The chassis's front face centre: the point the server times (Config/DragStrip.frontPoint).
local function frontPoint(chassis: BasePart): Vector3
	local frame = chassis.CFrame
	if type(dragConfig.frontPoint) == "function" then
		return dragConfig.frontPoint(frame, chassis.Size)
	end
	return frame.Position + frame.LookVector * (chassis.Size.Z / 2)
end

-- The moment a point crossed a gate plane between two frames: at t0 it was d0 studs past the plane moving at r0
-- studs/s along its normal, at t1 d1 past at r1. Config/DragStrip.crossingTime (the server's own: the cubic
-- through both positions and speeds), else a straight line between the two positions. nil unless it went from
-- behind (< 0) to on or past the plane (>= 0).
local function crossingTime(t0: number, d0: number, r0: number, t1: number, d1: number, r1: number): number?
	if type(dragConfig.crossingTime) == "function" then
		return dragConfig.crossingTime(t0, d0, r0, t1, d1, r1)
	end
	if d0 >= 0 or d1 < 0 then
		return nil
	end
	return t0 + (t1 - t0) * (-d0 / (d1 - d0))
end

-- One frame's view of a point against a gate: when, how far past the plane and how fast along its normal.
type Crossing = { time: number, distance: number, rate: number }

-- Notes every gate crossing of the chassis's front and centre on the server clock (Workspace:GetServerTimeNow()),
-- from where they are and how fast they move each frame (Heartbeat, after the frame's physics), until stopped.
local function startCrossings(chassis: BasePart, gates: { Gate }): Sampler
	local sampler: Sampler = { front = {}, centre = {}, maxMph = 0, stop = function() end }
	local lastFront: { [number]: Crossing } = {}
	local lastCentre: { [number]: Crossing } = {}
	local function cross(times: { [number]: number }, last: { [number]: Crossing }, gate: Gate, here: Crossing)
		local before = last[gate.index]
		if times[gate.index] == nil and before ~= nil then
			local crossed = crossingTime(before.time, before.distance, before.rate, here.time, here.distance, here.rate)
			if crossed ~= nil then
				times[gate.index] = crossed
			end
		end
		last[gate.index] = here
	end
	local connection = RunService.Heartbeat:Connect(function()
		local now = serverNow()
		local front = frontPoint(chassis)
		local frontVelocity = chassis:GetVelocityAtPosition(front)
		local centre = chassis.Position
		local centreVelocity = chassis.AssemblyLinearVelocity
		for _, gate in gates do
			local frontHere: Crossing = {
				time = now,
				distance = flat(front - gate.point):Dot(gate.normal),
				rate = frontVelocity:Dot(gate.normal),
			}
			local centreHere: Crossing = {
				time = now,
				distance = flat(centre - gate.point):Dot(gate.normal),
				rate = centreVelocity:Dot(gate.normal),
			}
			cross(sampler.front, lastFront, gate, frontHere)
			cross(sampler.centre, lastCentre, gate, centreHere)
		end
		sampler.maxMph = math.max(sampler.maxMph, forwardMph(chassis))
	end)
	sampler.stop = function()
		connection:Disconnect()
	end
	return sampler
end

---------------------------------------------------------------------------------------------------------------
-- Placing cars
---------------------------------------------------------------------------------------------------------------

-- Sits the player in a fresh `spec` whose chassis comes down at `centre` (on the ground there) facing `heading`:
-- gets out of any car, stands the character Spawning.spawnOffset + half the car's length behind that point (with
-- the map streamed in round it), gives the server time to see it there and spawns with DevSpawnVehicle, which
-- seats them. The old car goes when the new one comes (Config/Spawning.maxCarsPerPlayer). Returns the car, or nil
-- and why.
local function spawnCar(ctx: Context, spec: CarSpec, centre: Vector3, heading: Vector3): (Model?, string?)
	local geometry = Catalog.geometry(spec.vehicleId, spec.trim)
	if geometry == nil then
		return nil, `{nameOf(spec)} isn't in Config/Vehicles`
	end
	local humanoid = humanoidOf()
	local character = Players.LocalPlayer.Character
	if humanoid == nil or character == nil then
		return nil, "no character"
	end
	local facing = flat(heading)
	if facing.Magnitude < EPSILON then
		return nil, "no heading to spawn along"
	end
	facing = facing.Unit
	local old = currentCar()
	releaseControls()
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
	if cancelRequested(ctx) then
		return nil, "stopped"
	end
	streamAround(centre)
	local spot = centre - facing * (Spawning.spawnOffset + geometry.length / 2)
	local ignore: { Instance } = if old then { old } else {}
	local ground = groundHit(spot, ignore)
	local y = (if ground then ground.Position.Y else centre.Y) + SETTINGS.standHeight
	local stand = Vector3.new(spot.X, y, spot.Z)
	character:PivotTo(CFrame.lookAt(stand, stand + facing))
	task.wait(SETTINGS.standSettleSeconds)

	ensureNet()
	Net.fireServer("DevSpawnVehicle", { vehicleId = spec.vehicleId, trim = spec.trim })
	local seated = waitFor(ctx, function(): boolean
		local car = currentCar()
		return car ~= nil and car ~= old and isCar(car, spec)
	end, seatSignal, SETTINGS.spawnTimeout)
	if not seated then
		return nil,
			`{nameOf(spec)} didn't spawn with you in it (DevSpawnVehicle needs a drivable trim and its model, `
				.. `ServerStorage.VehicleModels.{Catalog.modelName(spec.vehicleId, spec.trim)})`
	end
	-- The game's DriveController starts once the car has arrived on this client.
	task.wait(SETTINGS.settleSeconds)
	local car = currentCar()
	if car == nil or car.PrimaryPart == nil then
		return nil, `{nameOf(spec)} spawned but has no chassis here`
	end
	return car, nil
end

---------------------------------------------------------------------------------------------------------------
-- One hop or flight
---------------------------------------------------------------------------------------------------------------

local function newRun(index: number, ability: string, spec: CarSpec, replaced: boolean): AbilityRun
	return {
		index = index,
		ability = ability,
		vehicle = nameOf(spec),
		replaced = replaced,
		askedMph = 0,
		reply = "",
		allowed = false,
		rise = 0,
		maxTilt = 0,
		finalTilt = 0,
		maxUpSpeed = 0,
		maxDownSpeed = 0,
		maxHorizontalSpeed = 0,
		speedGain = 0,
		landedAfter = nil,
		wheelsDown = 0,
		upright = false,
		inside = nil,
		resets = {},
		droveAway = false,
		stuck = false,
		passed = false,
		reason = "",
	}
end

-- Samples the car every frame from the ask until stopped: how high it rose, how far it tilted, how fast it moved.
local function startMonitor(chassis: BasePart): Monitor
	local velocity = chassis.AssemblyLinearVelocity
	local monitor: Monitor = {
		startY = chassis.Position.Y,
		startSpeed = flat(velocity).Magnitude,
		rise = 0,
		maxTilt = tiltOf(chassis.CFrame),
		maxUp = 0,
		maxDown = 0,
		maxHorizontal = flat(velocity).Magnitude,
		stop = function() end,
	}
	local connection = RunService.Heartbeat:Connect(function()
		local frame = chassis.CFrame
		local moving = chassis.AssemblyLinearVelocity
		monitor.rise = math.max(monitor.rise, frame.Position.Y - monitor.startY)
		monitor.maxTilt = math.max(monitor.maxTilt, tiltOf(frame))
		monitor.maxUp = math.max(monitor.maxUp, moving.Y)
		monitor.maxDown = math.max(monitor.maxDown, -moving.Y)
		monitor.maxHorizontal = math.max(monitor.maxHorizontal, flat(moving).Magnitude)
	end)
	monitor.stop = function()
		connection:Disconnect()
	end
	return monitor
end

-- Waits until the ability's window has ended (server clock) and the wheels are down, at most SETTINGS
-- .landingTimeout past the window. Checked every frame, only while waiting. Seconds after the window's end it
-- landed, or nil.
local function waitLanding(ctx: Context, car: Model, chassis: BasePart, endsAt: number, wheelRadius: number): number?
	local landedAt: number? = nil
	local timeout = math.max(endsAt - serverNow(), 0) + SETTINGS.landingTimeout
	waitFor(ctx, function(): boolean
		local now = serverNow()
		if now >= endsAt and wheelsDown(car, chassis, wheelRadius) >= SETTINGS.minWheelsDown then
			landedAt = now
			return true
		end
		return false
	end, RunService.Heartbeat, timeout)
	return if landedAt ~= nil then round(landedAt - endsAt, 2) else nil
end

-- What a hop or flight is measured on: the car, its chassis and wheel size, and when its run began (os.clock()).
type Ride = { car: Model, chassis: BasePart, wheelRadius: number, since: number }

-- Fills in how the run ended, from the monitor and the car after the settle.
local function measure(ctx: Context, run: AbilityRun, ride: Ride, monitor: Monitor)
	local chassis = ride.chassis
	run.rise = round(monitor.rise, 2)
	run.maxTilt = round(monitor.maxTilt, 1)
	run.maxUpSpeed = round(monitor.maxUp, 1)
	run.maxDownSpeed = round(monitor.maxDown, 1)
	run.maxHorizontalSpeed = round(monitor.maxHorizontal, 1)
	run.speedGain = round(math.max(monitor.maxHorizontal - monitor.startSpeed, 0), 1)
	run.finalTilt = round(tiltOf(chassis.CFrame), 1)
	run.upright = chassis.CFrame.UpVector.Y >= uprightDot(ctx)
	run.wheelsDown = wheelsDown(ride.car, chassis, ride.wheelRadius)
	run.inside = insideMap(ride.car, chassis)
	run.resets = resetsSince(ctx.watch, ride.since)
end

-- Whether the run passed, and the first thing that failed. A run that never asked (stopped, or the car couldn't
-- build speed) keeps the reason it already has.
local function verdict(run: AbilityRun, minRise: number)
	run.passed = false
	if run.reason == "stopped" or (not run.allowed and run.reply == "") then
		return
	end
	if not run.allowed then
		run.reason = `refused ({run.reply})`
		return
	end
	run.stuck = run.wheelsDown < SETTINGS.minWheelsDown or run.inside ~= nil or not run.droveAway
	local reason = if run.rise < minRise
		then `didn't leave the ground (rose {run.rise} studs, needs {minRise})`
		elseif run.landedAfter == nil then `wasn't back on its wheels {SETTINGS.landingTimeout} s after the window`
		elseif not run.upright then `ended tilted {run.finalTilt} degrees from upright`
		elseif run.wheelsDown < SETTINGS.minWheelsDown then `only {run.wheelsDown} wheel(s) on the ground`
		elseif run.inside ~= nil then `ended inside map geometry ({run.inside})`
		elseif #run.resets > 0 then `the server reset it ({table.concat(run.resets, ", ")})`
		elseif not run.droveAway then "couldn't drive away"
		else "ok"
	run.reason = reason
	run.passed = reason == "ok"
end

local function runDetail(run: AbilityRun): string
	if not run.allowed then
		return run.reason
	end
	local landed = if run.landedAfter ~= nil then `landed {run.landedAfter} s after the window` else "never landed"
	local parts = {
		run.reason,
		`asked at {run.askedMph} mph`,
		`rose {run.rise} studs`,
		landed,
		`final tilt {run.finalTilt} deg (most {run.maxTilt})`,
		`{run.wheelsDown} wheels down`,
	}
	if run.pattern then
		table.insert(parts, `input "{run.pattern}" via {run.inputPath or "?"}`)
	end
	if run.replaced then
		table.insert(parts, "car put back first")
	end
	return table.concat(parts, ", ")
end

-- A VehicleReset that came after a run's checks (before the next run started) still belongs to that run.
local function attachLate(ctx: Context, run: AbilityRun?, item: Check?, since: number, minRise: number)
	if run == nil then
		return
	end
	local late = resetsSince(ctx.watch, since)
	if #late == 0 then
		return
	end
	for _, reason in late do
		table.insert(run.resets, `{reason} (late)`)
	end
	verdict(run, minRise)
	if item then
		item.passed = run.passed
		item.detail = runDetail(run)
	end
	print(`{LOG} {ctx.name}: {ctx.prefix}run {run.index} was reset after its checks: {table.concat(late, ", ")}`)
end

-- Holds the car still once it is down: Config/Abilities.settleSeconds at least, and until the server's own settle
-- check (settleCheckAfter the window's end) has had SETTINGS.resetWatchSeconds to answer with an unstuck move.
local function settle(ctx: Context, ability: string, endsAt: number)
	local untilCheck = endsAt + settleCheckAfter(ctx, ability) - serverNow()
	local hold = math.max(settleTime(ctx) + SETTINGS.settleSlack, untilCheck) + SETTINGS.resetWatchSeconds
	AutoDriver.holdStill(hold)
end

-- One hop from where the car stands on the runway: build speed along the lane, ask, ride it out, land, settle.
local function hopOnce(
	ctx: Context,
	index: number,
	line: Line,
	endAlong: number,
	since: number,
	replaced: boolean
): AbilityRun
	local spec = SETTINGS.hopCar
	local run = newRun(index, HOP, spec, replaced)
	local car = currentCar()
	local chassis = if car then car.PrimaryPart else nil
	if car == nil or chassis == nil then
		run.reason = "not in a car"
		return run
	end
	resetCooldowns(ctx)
	local along = lineFrame(line, chassis.Position)
	startDrive({ linePoint(line, along + SETTINGS.joinStuds), linePoint(line, endAlong) }, SETTINGS.hopMph)
	local threshold = minHopMph(ctx) + SETTINGS.hopSpeedMargin
	if not waitForSpeed(ctx, chassis, threshold, math.huge, SETTINGS.runUpTimeout) then
		AutoDriver.stop()
		if cancelRequested(ctx) then
			run.reason = "stopped"
		else
			run.reason = `couldn't build speed: {round(forwardMph(chassis), 1)} mph after {SETTINGS.runUpTimeout} s`
				.. ` (needs {threshold})`
			run.stuck = true
		end
		AutoDriver.holdStill(SETTINGS.holdSeconds)
		return run
	end

	local monitor = startMonitor(chassis)
	run.askedMph = round(forwardMph(chassis), 1)
	local reply = useAbility(HOP)
	run.reply = describe(reply)
	run.allowed = reply ~= nil and reply.ok
	if reply == nil or not reply.ok then
		monitor.stop()
		AutoDriver.stop()
		AutoDriver.holdStill(SETTINGS.holdSeconds)
		verdict(run, SETTINGS.minHopRise)
		return run
	end
	local endsAt = windowEnd(car, reply, durationOf(ctx, HOP))
	local ride: Ride = { car = car, chassis = chassis, wheelRadius = wheelRadiusOf(spec), since = since }
	setCurrent(ctx, `hop {index}: in the air`)
	-- The AutoDriver keeps driving along the lane through the hop, like a player holding the throttle.
	run.landedAfter = waitLanding(ctx, car, chassis, endsAt, ride.wheelRadius)
	AutoDriver.stop()
	settle(ctx, HOP, endsAt)
	monitor.stop()
	measure(ctx, run, ride, monitor)
	if run.upright and run.inside == nil and run.wheelsDown >= SETTINGS.minWheelsDown and not cancelRequested(ctx) then
		local here = lineFrame(line, chassis.Position)
		run.droveAway = driveAway(linePoint(line, here + SETTINGS.driveAwayStuds))
	end
	if cancelRequested(ctx) then
		run.reason = "stopped"
	end
	verdict(run, SETTINGS.minHopRise)
	return run
end

-- One flight from a standstill on the spot: ask, play the input, land, settle.
local function flightOnce(ctx: Context, index: number, since: number, replaced: boolean): AbilityRun
	local spec = SETTINGS.flightCar
	local run = newRun(index, FLIGHT, spec, replaced)
	local pattern = SETTINGS.flightPatterns[(index - 1) % #SETTINGS.flightPatterns + 1]
	run.pattern = pattern.name
	local car = currentCar()
	local chassis = if car then car.PrimaryPart else nil
	if car == nil or chassis == nil then
		run.reason = "not in a car"
		return run
	end
	resetCooldowns(ctx)
	AutoDriver.holdStill(SETTINGS.preFlightHold)
	if cancelRequested(ctx) then
		run.reason = "stopped"
		return run
	end

	local monitor = startMonitor(chassis)
	run.askedMph = round(forwardMph(chassis), 1)
	local reply = useAbility(FLIGHT)
	run.reply = describe(reply)
	run.allowed = reply ~= nil and reply.ok
	if reply == nil or not reply.ok then
		monitor.stop()
		verdict(run, SETTINGS.minFlightRise)
		return run
	end
	local endsAt = windowEnd(car, reply, durationOf(ctx, FLIGHT))
	local ride: Ride = { car = car, chassis = chassis, wheelRadius = wheelRadiusOf(spec), since = since }
	setCurrent(ctx, `flight {index}: flying "{pattern.name}"`)
	pause(ctx, SETTINGS.inputDelay)
	run.inputPath = playPattern(ctx, pattern)
	setCurrent(ctx, `flight {index}: landing`)
	run.landedAfter = waitLanding(ctx, car, chassis, endsAt, ride.wheelRadius)
	settle(ctx, FLIGHT, endsAt)
	monitor.stop()
	measure(ctx, run, ride, monitor)
	if run.upright and run.inside == nil and run.wheelsDown >= SETTINGS.minWheelsDown and not cancelRequested(ctx) then
		local forward = flat(chassis.CFrame.LookVector)
		if forward.Magnitude > EPSILON then
			run.droveAway = driveAway(chassis.Position + forward.Unit * SETTINGS.driveAwayStuds)
		end
	end
	if cancelRequested(ctx) then
		run.reason = "stopped"
	end
	verdict(run, SETTINGS.minFlightRise)
	return run
end

local function summarize(runs: { AbilityRun }): Summary
	local summary: Summary = {
		asked = #runs,
		allowed = 0,
		passed = 0,
		failed = 0,
		stuck = 0,
		resets = 0,
		replaced = 0,
		maxTilt = 0,
		maxFinalTilt = 0,
		worstRun = nil,
		slowestLanding = nil,
		minRise = nil,
		maxRise = 0,
		maxUpSpeed = 0,
		maxDownSpeed = 0,
		maxHorizontalSpeed = 0,
		maxSpeedGain = 0,
		failures = {},
		runs = runs,
	}
	for _, run in runs do
		if run.allowed then
			summary.allowed += 1
			summary.maxTilt = math.max(summary.maxTilt, run.maxTilt)
			if run.finalTilt >= summary.maxFinalTilt then
				summary.maxFinalTilt = run.finalTilt
				summary.worstRun = run.index
			end
			local landed = run.landedAfter
			if landed ~= nil then
				summary.slowestLanding = math.max(summary.slowestLanding or landed, landed)
			end
			summary.minRise = math.min(summary.minRise or run.rise, run.rise)
			summary.maxRise = math.max(summary.maxRise, run.rise)
			summary.maxUpSpeed = math.max(summary.maxUpSpeed, run.maxUpSpeed)
			summary.maxDownSpeed = math.max(summary.maxDownSpeed, run.maxDownSpeed)
			summary.maxHorizontalSpeed = math.max(summary.maxHorizontalSpeed, run.maxHorizontalSpeed)
			summary.maxSpeedGain = math.max(summary.maxSpeedGain, run.speedGain)
		end
		if run.passed then
			summary.passed += 1
		else
			summary.failed += 1
			if #summary.failures < SETTINGS.maxFailuresListed then
				table.insert(summary.failures, `run {run.index}: {run.reason}`)
			end
		end
		if run.stuck then
			summary.stuck += 1
		end
		if #run.resets > 0 then
			summary.resets += 1
		end
		if run.replaced then
			summary.replaced += 1
		end
	end
	return summary
end

local function printSummary(ctx: Context, label: string, summary: Summary)
	local worst = if summary.worstRun then ` (run {summary.worstRun})` else ""
	print(
		`{LOG} {ctx.name}: {label}: {summary.passed} of {summary.asked} passed, {summary.allowed} allowed, `
			.. `{summary.stuck} stuck, {summary.resets} reset, {summary.replaced} put back; worst final tilt `
			.. `{summary.maxFinalTilt} deg{worst}, most tilt in the air {summary.maxTilt} deg, slowest landing `
			.. `{summary.slowestLanding or "-"} s after the window`
	)
	for _, failure in summary.failures do
		print(`{LOG} {ctx.name}: {label}: {failure}`)
	end
end

-- Runs `n` hops or flights: puts the car in place when it needs it (`ready` false, or not the right car), runs
-- one, checks it, and stops early on a cancel, a run of refusals or anti-exploit strikes nearing a kick. Returns
-- the runs and why it stopped early (nil when it ran them all).
local function runSeries(
	ctx: Context,
	label: string,
	n: number,
	spec: CarSpec,
	minRise: number,
	ready: (car: Model, chassis: BasePart) -> boolean,
	place: () -> (Model?, string?),
	once: (index: number, since: number, replaced: boolean) -> AbilityRun
): ({ AbilityRun }, string?, boolean)
	local runs: { AbilityRun } = {}
	local previous: AbilityRun? = nil
	local previousCheck: Check? = nil
	local previousEnd = os.clock()
	local refusedInARow = 0
	local stuckBefore = false
	for index = 1, n do
		if cancelRequested(ctx) then
			return runs, "stopped", false
		end
		attachLate(ctx, previous, previousCheck, previousEnd, minRise)
		local close, strikes = nearKick(ctx)
		if close then
			return runs,
				`stopped early: {strikes} anti-exploit strike(s) in the last {AntiExploit.strikeDecaySeconds} s, `
					.. `and {AntiExploit.strikesToKick} would remove the player`,
				false
		end
		local since = os.clock()
		local car = currentCar()
		local chassis = if car then car.PrimaryPart else nil
		local replaced = false
		-- A car left stuck is put back too, so one bad landing doesn't spoil the runs after it.
		if stuckBefore or car == nil or chassis == nil or not isCar(car, spec) or not ready(car, chassis) then
			setCurrent(ctx, `{label} {index}: putting the {nameOf(spec)} in place`)
			local placed, why = place()
			if placed == nil then
				return runs, why or "couldn't place the car", index == 1
			end
			replaced = index > 1
		end
		setCurrent(ctx, `{label} {index} of {n}`)
		local run = once(index, since, replaced)
		table.insert(runs, run)
		if run.reason == "stopped" then
			return runs, "stopped", false
		end
		previous, previousEnd = run, os.clock()
		previousCheck = check(ctx, `{label} {index}`, run.passed, runDetail(run))
		stuckBefore = run.stuck
		refusedInARow = if not run.allowed and run.reply ~= "" then refusedInARow + 1 else 0
		if refusedInARow >= SETTINGS.maxRefusedInARow then
			return runs, `{refusedInARow} refused in a row (last: {run.reply})`, false
		end
	end
	attachLate(ctx, previous, previousCheck, previousEnd, minRise)
	return runs, nil, false
end

---------------------------------------------------------------------------------------------------------------
-- Tests. Each returns "done", "skipped", "failed" or "stopped", and why when it isn't "done".
---------------------------------------------------------------------------------------------------------------

local function hopsTest(ctx: Context, n: number): (string, string?)
	local spec = SETTINGS.hopCar
	local hasHop = trimHas(spec, HOP)
	check(ctx, "Config/Abilities.byTrim gives the Arc Boost the hop", hasHop, `byTrim["{nameOf(spec)}"]`)
	local line, why = lineBetween(SETTINGS.runway.from, SETTINGS.runway.to)
	if line == nil then
		return "failed", why
	end
	local runway: Line = line
	local endAlong = runway.length - SETTINGS.runwayEnd
	local cosSlack = math.cos(math.rad(SETTINGS.headingSlack))

	-- On the runway's lane, facing along it, upright, with enough road ahead.
	local function ready(_car: Model, chassis: BasePart): boolean
		local along, lateral = lineFrame(runway, chassis.Position)
		local facing = flat(chassis.CFrame.LookVector)
		return along >= 0
			and endAlong - along >= SETTINGS.runwayNeeded
			and math.abs(lateral) <= SETTINGS.laneSlack
			and facing.Magnitude > EPSILON
			and facing.Unit:Dot(runway.heading) >= cosSlack
			and chassis.CFrame.UpVector.Y >= uprightDot(ctx)
	end
	local function place(): (Model?, string?)
		return spawnCar(ctx, spec, linePoint(runway, SETTINGS.runwayStart), runway.heading)
	end
	local function once(index: number, since: number, replaced: boolean): AbilityRun
		return hopOnce(ctx, index, runway, endAlong, since, replaced)
	end

	local runs, stopped, couldNotStart = runSeries(ctx, "hop", n, spec, SETTINGS.minHopRise, ready, place, once)
	local summary = summarize(runs)
	ctx.result.hops = summary
	if couldNotStart then
		return "skipped", stopped
	end
	check(
		ctx,
		`all {n} hops ran`,
		#runs == n and stopped == nil,
		if stopped then `{#runs} of {n}: {stopped}` else `{#runs} of {n}`
	)
	printSummary(ctx, "hops", summary)
	if summary.allowed > 0 then
		note(ctx, `hops: {boundsNote(HOP, summary)}`)
	end
	return if cancelRequested(ctx) then "stopped" else "done", nil
end

local function flightsTest(ctx: Context, n: number): (string, string?)
	local spec = SETTINGS.flightCar
	local hasFlight = trimHas(spec, FLIGHT)
	check(ctx, "Config/Abilities.byTrim gives the Arc Flight flight", hasFlight, `byTrim["{nameOf(spec)}"]`)
	local field = locationsById[SETTINGS.flightField]
	if field == nil then
		return "failed", `Config/MapLayout has no "{SETTINGS.flightField}"`
	end
	local spot, why = flightSpot(field)
	if spot == nil then
		return "failed", why
	end
	local start: Vector3 = spot
	local heading = flat(volumeFrame(field).RightVector) -- along the field's length
	note(ctx, `flights start at {round(start.X, 0)}, {round(start.Z, 0)} ({whereText(start)})`)

	local function ready(_car: Model, chassis: BasePart): boolean
		return flatDistance(chassis.Position, start) <= SETTINGS.flightDrift
			and depthInside(field, chassis.Position) >= SETTINGS.zoneMargin
			and chassis.CFrame.UpVector.Y >= uprightDot(ctx)
	end
	local function place(): (Model?, string?)
		return spawnCar(ctx, spec, start, heading)
	end
	local function once(index: number, since: number, replaced: boolean): AbilityRun
		return flightOnce(ctx, index, since, replaced)
	end

	local runs, stopped, couldNotStart = runSeries(ctx, "flight", n, spec, SETTINGS.minFlightRise, ready, place, once)
	local summary = summarize(runs)
	ctx.result.flights = summary
	if couldNotStart then
		return "skipped", stopped
	end
	check(
		ctx,
		`all {n} flights ran`,
		#runs == n and stopped == nil,
		if stopped then `{#runs} of {n}: {stopped}` else `{#runs} of {n}`
	)
	printSummary(ctx, "flights", summary)
	if summary.allowed > 0 then
		note(ctx, `flights: {boundsNote(FLIGHT, summary)}`)
	end
	return if cancelRequested(ctx) then "stopped" else "done", nil
end

-- How one forged ask is judged: `expect` is the Config/Abilities.messages entry the refusal should be (a path,
-- { "noAbility", "flight" }); `watchUntil` (server clock) ends the watch early: during a real hop, before its own
-- window ends.
type ForgeOptions = { expect: { string }?, watchUntil: number? }

-- Asks `ability` from the car the player drives and checks the server refuses it with nothing changed on the car.
local function forgeCase(ctx: Context, cases: { ForgedCase }, name: string, ability: string, opts: ForgeOptions?)
	local options: ForgeOptions = opts or {}
	local watchUntil = options.watchUntil
	local car = currentCar()
	local chassis = if car then car.PrimaryPart else nil
	if car == nil or chassis == nil then
		check(ctx, `{name}: asked`, false, "not in a car")
		return
	end
	-- Wait out the rate limit first, so the car's state is read right before the ask.
	waitGap("UseAbility")
	local before = carState(car)
	local changes: { string } = {}
	local connection = car.AttributeChanged:Connect(function(attribute: string)
		if table.find(CAR_ATTRIBUTES, attribute) ~= nil then
			local value = car:GetAttribute(attribute)
			-- A real ability's window ending (Ability cleared) is no change made by this ask.
			if not (attribute == ABILITY and value == nil) then
				table.insert(changes, `{attribute} -> {tostring(value)}`)
			end
		end
	end)
	local mph = round(forwardMph(chassis), 1)
	local where = whereText(chassis.Position)
	local reply = useAbility(ability)
	local watchFor = SETTINGS.forgedWatchSeconds
	if watchUntil ~= nil then
		watchFor = math.min(watchFor, watchUntil - serverNow())
	end
	pause(ctx, watchFor)
	connection:Disconnect()
	local after = carState(car)
	for _, attribute in CAR_ATTRIBUTES do
		local changed = before[attribute] ~= after[attribute]
		local expired = attribute == ABILITY and after[attribute] == tostring(nil)
		if changed and not expired and #changes == 0 then
			table.insert(changes, `{attribute}: {before[attribute]} -> {after[attribute]}`)
		end
	end
	local case: ForgedCase = {
		name = name,
		ability = ability,
		vehicle = carName(car),
		mph = mph,
		where = where,
		reply = describe(reply),
		refused = reply ~= nil and not reply.ok,
		unchanged = #changes == 0,
		changes = table.concat(changes, ", "),
	}
	local expect = options.expect
	local pattern = if expect then messagePattern(expect) else nil
	local because = ""
	if expect ~= nil and reply ~= nil then
		case.expected = table.concat(expect, ".")
		case.asExpected = pattern ~= nil and string.match(reply.message, pattern) ~= nil
		because = `; {if case.asExpected then "the" else "not the"} {case.expected} message`
	end
	table.insert(cases, case)
	check(ctx, `{name}: refused`, case.refused, `{case.vehicle} at {mph} mph, {where}: {case.reply}{because}`)
	check(
		ctx,
		`{name}: nothing changed`,
		case.unchanged,
		if case.unchanged then "car attributes unchanged" else case.changes
	)
	if not case.refused or not case.unchanged then
		-- Let the next case ask fresh rather than meet this one's cooldown.
		resetCooldowns(ctx)
	end
end

-- Drives the car along the runway at `mph` and waits until it holds the speed. The drive keeps going (it stops at
-- the runway's end); AutoDriver.stop() ends it.
local function cruiseOnRunway(ctx: Context, runway: Line, endAlong: number, mph: number, minMph: number): boolean
	local car = currentCar()
	local chassis = if car then car.PrimaryPart else nil
	if chassis == nil then
		return false
	end
	local along = lineFrame(runway, chassis.Position)
	startDrive({ linePoint(runway, along + SETTINGS.joinStuds), linePoint(runway, endAlong) }, mph)
	return waitForSpeed(ctx, chassis, minMph, math.huge, SETTINGS.runUpTimeout)
end

local function stopAndHold()
	AutoDriver.stop()
	AutoDriver.holdStill(SETTINGS.holdSeconds)
end

local function forgedTest(ctx: Context): (string, string?)
	local cases: { ForgedCase } = {}
	ctx.result.forged = cases
	local line, why = lineBetween(SETTINGS.runway.from, SETTINGS.runway.to)
	if line == nil then
		return "failed", why
	end
	local runway: Line = line
	local endAlong = runway.length - SETTINGS.runwayEnd
	local minMph = minHopMph(ctx)
	local fast = minMph + SETTINGS.hopSpeedMargin
	local start = linePoint(runway, SETTINGS.runwayStart)

	-- 1. An Arc Boost on the Return Road: too slow, flight it doesn't have, a hop during a hop and on cooldown.
	setCurrent(ctx, "forged: an Arc Boost on the Return Road")
	local boost, boostWhy = spawnCar(ctx, SETTINGS.hopCar, start, runway.heading)
	if boost == nil then
		return "skipped", boostWhy
	end
	resetCooldowns(ctx)
	AutoDriver.holdStill(SETTINGS.holdSeconds)
	forgeCase(ctx, cases, "hop standing still", HOP, { expect = { "tooSlow" } })
	forgeCase(
		ctx,
		cases,
		"flight in an Arc Boost (its trim has no flight)",
		FLIGHT,
		{ expect = { "noAbility", FLIGHT } }
	)

	local chassis = boost.PrimaryPart :: BasePart
	local along = lineFrame(runway, chassis.Position)
	startDrive({ linePoint(runway, along + SETTINGS.joinStuds), linePoint(runway, endAlong) }, SETTINGS.slowMph)
	local slowTop = math.min(SETTINGS.slowMph + SETTINGS.slowSlack, minMph - SETTINGS.slowSlack)
	if waitForSpeed(ctx, chassis, SETTINGS.slowMph - SETTINGS.slowSlack, slowTop, SETTINGS.runUpTimeout) then
		forgeCase(ctx, cases, `hop at {SETTINGS.slowMph} mph (under {minMph})`, HOP, { expect = { "tooSlow" } })
	else
		check(ctx, `held {SETTINGS.slowMph} mph for the too-slow hop`, false, `{round(forwardMph(chassis), 1)} mph`)
	end

	if cruiseOnRunway(ctx, runway, endAlong, SETTINGS.hopMph, fast) then
		local reply = useAbility(HOP)
		check(ctx, "a real hop is allowed (so the refusals mean something)", reply ~= nil and reply.ok, describe(reply))
		if reply ~= nil and reply.ok then
			local endsAt = windowEnd(boost, reply, durationOf(ctx, HOP))
			local during: ForgeOptions = { expect = { "busy" }, watchUntil = endsAt - SETTINGS.attributeSlack }
			forgeCase(ctx, cases, "hop again during the hop", HOP, during)
			waitLanding(ctx, boost, chassis, endsAt, wheelRadiusOf(SETTINGS.hopCar))
			-- Until its landing and settle are over the server counts the hop as running (busy); after that only
			-- the cooldown is left. Keep driving meanwhile.
			local runEnds = endsAt + settleCheckAfter(ctx, HOP) + SETTINGS.settleSlack
			waitFor(ctx, function(): boolean
				return serverNow() >= runEnds
			end, RunService.Heartbeat, math.max(runEnds - serverNow(), 0) + SETTINGS.settleSlack)
			if waitForSpeed(ctx, chassis, fast, math.huge, SETTINGS.runUpTimeout) then
				forgeCase(ctx, cases, "hop again while it recharges", HOP, { expect = { "recharging" } })
			else
				check(ctx, "back to speed after the real hop", false, `{round(forwardMph(chassis), 1)} mph`)
			end
		end
	else
		check(ctx, `reached {fast} mph for the real hop`, false, `{round(forwardMph(chassis), 1)} mph`)
	end
	stopAndHold()
	resetCooldowns(ctx)

	-- 2. Cars without abilities, at speed: the Arc's own plain trim and a car with no thrusters.
	for _, spec in { SETTINGS.plainArc, SETTINGS.plainCar } do
		if cancelRequested(ctx) then
			break
		end
		setCurrent(ctx, `forged: {nameOf(spec)} on the Return Road`)
		local plain, plainWhy = spawnCar(ctx, spec, start, runway.heading)
		if plain == nil then
			check(ctx, `{nameOf(spec)} spawned`, false, plainWhy or "?")
			continue
		end
		if cruiseOnRunway(ctx, runway, endAlong, SETTINGS.hopMph, fast) then
			forgeCase(ctx, cases, `hop in a {nameOf(spec)} (no abilities)`, HOP, { expect = { "noAbility", HOP } })
			local noFlight: ForgeOptions = { expect = { "noAbility", FLIGHT } }
			forgeCase(ctx, cases, `flight in a {nameOf(spec)} (no abilities)`, FLIGHT, noFlight)
		else
			check(ctx, `{nameOf(spec)} reached {fast} mph`, false, "the AutoDriver couldn't build speed")
		end
		stopAndHold()
	end

	-- 3. An Arc Flight on the Return Road, well outside the Flight Field.
	local field = locationsById[SETTINGS.flightField]
	local flightCarOk = false
	if not cancelRequested(ctx) then
		setCurrent(ctx, "forged: an Arc Flight outside the Flight Field")
		local outside = linePoint(runway, SETTINGS.outsideFieldAlong)
		local flier, flierWhy = spawnCar(ctx, SETTINGS.flightCar, outside, runway.heading)
		flightCarOk = flier ~= nil
		check(ctx, "the Arc Flight spawned", flightCarOk, if flier then nameOf(SETTINGS.flightCar) else flierWhy or "?")
		if flier ~= nil then
			if field ~= nil and depthInside(field, outside) > -SETTINGS.zoneMargin then
				note(ctx, `SETTINGS.outsideFieldAlong puts the car only {whereText(outside)}`)
			end
			resetCooldowns(ctx)
			AutoDriver.holdStill(SETTINGS.holdSeconds)
			forgeCase(ctx, cases, "flight outside the Flight Field", FLIGHT, { expect = { "flightZone" } })
		end
	end

	-- 4. The No-Fly Zone round Mesa Control: the hop at speed, then flight standing still, both inside it.
	local noFly = locationsById[SETTINGS.noFlyZone]
	local street, streetWhy = lineBetween(SETTINGS.noFlyRoute.from, SETTINGS.noFlyRoute.to)
	if cancelRequested(ctx) then
		return "stopped", nil
	elseif noFly == nil or street == nil then
		check(ctx, "found the No-Fly Zone and its street", false, streetWhy or `no "{SETTINGS.noFlyZone}"`)
	else
		local spec = if flightCarOk then SETTINGS.flightCar else SETTINGS.hopCar
		local geometry = Catalog.geometry(spec.vehicleId, spec.trim)
		local half = if geometry then geometry.length / 2 else 0
		local from, to = stretchInside(street, noFly, SETTINGS.zoneMargin + half)
		if from == nil or to == nil then
			check(ctx, "the street runs through the No-Fly Zone", false, `{SETTINGS.noFlyRoute.from} -> ...`)
		else
			setCurrent(ctx, `forged: {nameOf(spec)} in the No-Fly Zone`)
			local zoned, zonedWhy = spawnCar(ctx, spec, linePoint(street, from), street.heading)
			if zoned == nil then
				check(ctx, `{nameOf(spec)} spawned in the No-Fly Zone`, false, zonedWhy or "?")
			else
				resetCooldowns(ctx)
				local zonedChassis = zoned.PrimaryPart :: BasePart
				local drive = startDrive({ linePoint(street, to) }, SETTINGS.noFlyMph)
				local function inside(): boolean
					return depthInside(noFly, zonedChassis.Position) >= SETTINGS.zoneMargin
				end
				if waitForSpeed(ctx, zonedChassis, fast, math.huge, SETTINGS.runUpTimeout, inside) then
					forgeCase(ctx, cases, "hop in the No-Fly Zone", HOP, { expect = { "noFlyZone" } })
				else
					check(ctx, `reached {fast} mph inside the No-Fly Zone`, false, whereText(zonedChassis.Position))
				end
				waitFor(ctx, function(): boolean
					return drive.done
				end, RunService.Heartbeat, SETTINGS.driveTimeout)
				AutoDriver.holdStill(SETTINGS.holdSeconds)
				if trimHas(spec, FLIGHT) and inside() then
					forgeCase(ctx, cases, "flight in the No-Fly Zone", FLIGHT, { expect = { "noFlyZone" } })
				elseif trimHas(spec, FLIGHT) then
					check(ctx, "stopped inside the No-Fly Zone", false, whereText(zonedChassis.Position))
				else
					note(ctx, "flight in the No-Fly Zone not asked: no Arc Flight here")
				end
			end
		end
	end
	resetCooldowns(ctx)
	if cancelRequested(ctx) then
		return "stopped", nil
	end
	return "done", nil
end

-- The server's times from gate 1 for each gate: "finished" gives the last gate's (the run's time); "running"
-- updates that carry a time give the splits, for the gate they name or, without one, gates 2, 3 ... in turn.
local function serverGateTimes(updates: { DragUpdate }, lastGate: number): { [number]: number }
	local times: { [number]: number } = {}
	local nextGate = 2
	for _, update in updates do
		local time = update.time
		if update.state == "running" and time ~= nil and time > 0 then
			local gate = update.gate or nextGate
			times[gate] = time
			nextGate = gate + 1
		elseif update.state == "finished" and time ~= nil then
			times[lastGate] = time
		end
	end
	return times
end

local function dragTest(ctx: Context): (string, string?)
	local gates = dragGates()
	if #gates < 2 then
		return "failed", `Config/MapLayout has {#gates} {SETTINGS.gateTag} location(s); a run needs two or more`
	end
	local first, last = gates[1], gates[#gates]
	local spec = SETTINGS.dragCar
	local geometry = Catalog.geometry(spec.vehicleId, spec.trim)
	local trim = Catalog.getTrim(spec.vehicleId, spec.trim)
	local endNode = Graph.node(SETTINGS.dragEnd.node)
	if geometry == nil or trim == nil or endNode == nil then
		return "failed", `no {nameOf(spec)} in Config/Vehicles or no node "{SETTINGS.dragEnd.node}"`
	end
	local report: DragReport = {
		vehicle = nameOf(spec),
		armed = false,
		state = "none",
		gates = {},
		maxMph = 0,
		updates = {},
	}
	ctx.result.drag = report
	local watch = ctx.watch

	-- Stop with the chassis's front just behind gate 1 (the chassis box is the car's length) and hold still until
	-- the strip arms.
	local centre = first.point - first.normal * (SETTINGS.dragStage + geometry.length / 2)
	setCurrent(ctx, "drag: stopping behind gate 1")
	-- Updates from here on count: the strip may arm while the car is still settling after the spawn.
	local from = #watch.drag
	local car, why = spawnCar(ctx, spec, centre, first.normal)
	if car == nil then
		return "skipped", why
	end
	local chassis = car.PrimaryPart :: BasePart
	local function sawState(after: number, states: { string }): DragUpdate?
		for index = after + 1, #watch.drag do
			if table.find(states, watch.drag[index].state) ~= nil then
				return watch.drag[index]
			end
		end
		return nil
	end
	report.armed = holdUntil(ctx, function(): boolean
		return sawState(from, { "armed" }) ~= nil
	end, SETTINGS.armTimeout)
	check(
		ctx,
		"the strip armed",
		report.armed,
		if report.armed
			then `stopped {SETTINGS.dragStage} studs behind gate 1`
			else `no "armed" DragStripUpdate within {SETTINGS.armTimeout} s of stopping {SETTINGS.dragStage} studs `
				.. `behind gate 1`
	)
	if not report.armed then
		return if cancelRequested(ctx) then "stopped" else "done", nil
	end

	-- The run: every frame notes the gate crossings while the AutoDriver drives the strip to near its end.
	local runFrom = #watch.drag
	local sampler = startCrossings(chassis, gates)
	local endAlong = flat(endNode.position - first.point):Dot(first.normal) - SETTINGS.dragEnd.short
	local target = first.point + first.normal * endAlong
	setCurrent(ctx, "drag: down the strip")
	local driven = AutoDriver.drive(
		{ target },
		{ targetMph = trim.topSpeedMph, arriveRadius = SETTINGS.dragArrive, stopAtEnd = true }
	)
	waitFor(ctx, function(): boolean
		return sawState(runFrom, { "finished", "fault" }) ~= nil
	end, watch.changed.Event, SETTINGS.resultTimeout)
	sampler.stop()
	report.maxMph = round(math.max(sampler.maxMph, driven.maxMph), 1)

	local runUpdates: { DragUpdate } = {}
	for index = from + 1, #watch.drag do
		table.insert(report.updates, watch.drag[index].text)
		if index > runFrom then
			table.insert(runUpdates, watch.drag[index])
		end
	end
	local final = sawState(runFrom, { "finished", "fault" })
	local lastUpdate = runUpdates[#runUpdates]
	report.state = if final then final.state elseif lastUpdate then lastUpdate.state else "none"
	report.message = if final then final.message else nil
	report.best = if final then final.best else nil
	report.rank = if final then final.rank else nil
	check(
		ctx,
		"the run finished",
		final ~= nil and final.state == "finished",
		if final then final.text else `no finished DragStripUpdate ({driven.reason}, max {report.maxMph} mph)`
	)

	local missing: { string } = {}
	for _, gate in gates do
		if sampler.front[gate.index] == nil then
			table.insert(missing, tostring(gate.index))
		end
	end
	check(
		ctx,
		"crossed every gate",
		#missing == 0,
		if #missing == 0 then `{#gates} gates` else `no crossing seen at gate(s) {table.concat(missing, ", ")}`
	)

	local startFront, startCentre = sampler.front[first.index], sampler.centre[first.index]
	if final == nil or final.state ~= "finished" or startFront == nil then
		return if cancelRequested(ctx) then "stopped" else "done", nil
	end
	-- When the server saw the front cross gate 1, against this client: the replication lag (both clocks are the
	-- server's). It cancels out of every time from gate 1.
	for _, update in runUpdates do
		if update.startedAt ~= nil then
			report.serverLag = round(update.startedAt - startFront, 3)
			break
		end
	end
	local serverTimes = serverGateTimes(runUpdates, last.index)
	local serverTotal = serverTimes[last.index]
	local clientEnd = sampler.front[last.index]
	local scale = 1
	if
		serverTotal ~= nil
		and clientEnd ~= nil
		and serverTotal > (clientEnd - startFront) * SETTINGS.millisecondsOver
	then
		scale = 1 / 1000
		note(ctx, "the server's drag times look like milliseconds: compared as seconds")
	end
	local previousClient = 0
	for _, gate in gates do
		if gate.index == first.index then
			continue
		end
		local crossedAt = sampler.front[gate.index]
		local centreAt = sampler.centre[gate.index]
		local client = if crossedAt then crossedAt - startFront else nil
		local centreTime = if centreAt and startCentre then centreAt - startCentre else nil
		local server = if serverTimes[gate.index] then serverTimes[gate.index] * scale else nil
		local gateTime: GateTime = {
			gate = gate.index,
			client = if client then round(client, 3) else nil,
			centre = if centreTime then round(centreTime, 3) else nil,
			server = if server then round(server, 3) else nil,
			error = if client and server then round(client - server, 3) else nil,
		}
		table.insert(report.gates, gateTime)
		if client ~= nil and server ~= nil then
			local within = math.abs(client - server) <= SETTINGS.dragTolerance
			local detail =
				`client {round(client, 3)} s, server {round(server, 3)} s (off by {round(client - server, 3)})`
			-- A split may be timed from the previous gate rather than from gate 1.
			if gate.index ~= last.index and not within then
				local stretch = client - previousClient
				if math.abs(stretch - server) <= SETTINGS.dragTolerance then
					within = true
					detail ..= `; timed from the previous gate it matches (client {round(stretch, 3)} s)`
				end
			end
			if gate.index == last.index then
				report.clientTime = round(client, 3)
				report.serverTime = round(server, 3)
				report.centreTime = gateTime.centre
				report.error = gateTime.error
				check(ctx, `time within ±{SETTINGS.dragTolerance} s of the server`, within, detail)
				if not within and centreTime ~= nil and math.abs(centreTime - server) <= SETTINGS.dragTolerance then
					note(
						ctx,
						`the chassis centre's time ({round(centreTime, 3)} s) matches: the server times the centre`
					)
				end
			else
				check(ctx, `gate {gate.index} split within ±{SETTINGS.dragTolerance} s`, within, detail)
			end
		elseif gate.index == last.index then
			check(ctx, `time within ±{SETTINGS.dragTolerance} s of the server`, false, "no time to compare")
		end
		if client ~= nil then
			previousClient = client
		end
	end

	-- This week's board, as a note (it is written only on a personal best and cached a short while).
	local board = call("GetDragLeaderboard", nil)
	if type(board) == "table" then
		local entries = if type(board.entries) == "table" then #board.entries else 0
		local best, rank = tostring(board.best), tostring(board.rank)
		report.leaderboard = `{textOf(board.week)}: {entries} entries, your best {best}, rank {rank}`
		note(ctx, `leaderboard {report.leaderboard}`)
	end
	AutoDriver.holdStill(SETTINGS.holdSeconds)
	return if cancelRequested(ctx) then "stopped" else "done", nil
end

local function allTest(ctx: Context): (string, string?)
	local parts: { { name: string, run: () -> (string, string?) } } = {
		{
			name = "forged",
			run = function()
				return forgedTest(ctx)
			end,
		},
		{
			name = "hops",
			run = function()
				return hopsTest(ctx, SETTINGS.allRuns)
			end,
		},
		{
			name = "flights",
			run = function()
				return flightsTest(ctx, SETTINGS.allRuns)
			end,
		},
		{
			name = "drag",
			run = function()
				return dragTest(ctx)
			end,
		},
	}
	for _, part in parts do
		if cancelRequested(ctx) then
			break
		end
		ctx.prefix = `{part.name}: `
		local ok, status, why = pcall(part.run)
		releaseControls()
		if not ok then
			check(ctx, "ran", false, `error: {tostring(status)}`)
		elseif status == "skipped" or status == "failed" then
			check(ctx, "ran", false, `{status}: {why or "?"}`)
		end
		ctx.prefix = ""
	end
	return if cancelRequested(ctx) then "stopped" else "done", nil
end

---------------------------------------------------------------------------------------------------------------
-- Running a test
---------------------------------------------------------------------------------------------------------------

local function emptyResult(name: string, reason: string): Result
	return {
		name = name,
		passed = false,
		skipped = false,
		reason = reason,
		checks = {},
		elapsed = 0,
		notes = {},
		notices = {},
	}
end

local function printResult(result: Result)
	local verdictText = if result.skipped then "SKIPPED" elseif result.passed then "PASSED" else "FAILED"
	print(`{LOG} {result.name}: {verdictText} ({result.reason}) in {math.floor(result.elapsed)} s`)
	local ok, encoded = pcall(HttpService.JSONEncode, HttpService, result)
	if ok then
		print(`{LOG} {result.name}: {encoded}`)
	end
end

local function runTest(name: TestName, body: (ctx: Context) -> (string, string?)): Result
	if not (RunService:IsStudio() and RunService:IsRunning()) then
		warn(`{LOG} runs only in a Studio playtest (Client datamodel)`)
		return emptyResult(name, "studio only")
	end
	if script:GetAttribute(STATUS) == "running" then
		warn(`{LOG} a test is already running; AbilityTests.stop() cancels it`)
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
		prefix = "",
		noted = {},
	}
	script:SetAttribute(RUN_ID, ctx.id)
	script:SetAttribute(STATUS, "running")
	script:SetAttribute(CANCEL, false)
	script:SetAttribute(RESULT, nil)

	local result = ctx.result
	local ok, status, why = pcall(body, ctx)
	if not ok then
		result.reason = `error: {tostring(status)}`
		warn(`{LOG} {name} failed: {status}`)
	elseif status == "skipped" then
		result.skipped = true
		result.reason = `skipped: {why or "?"}`
		note(ctx, result.reason)
	elseif status == "stopped" or cancelRequested(ctx) then
		result.reason = "stopped"
	elseif status ~= "done" then
		result.reason = why or status
	end

	-- Hand the controls back and leave the car stopped.
	releaseControls()
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
	result.passed = ok and not result.skipped and result.reason == "done" and #result.checks > 0
	for _, item in result.checks do
		if not item.passed then
			result.passed = false
		end
	end
	result.elapsed = round(os.clock() - ctx.started, 1)
	printResult(result)

	if script:GetAttribute(RUN_ID) == ctx.id then
		local final = if result.reason == "stopped"
			then "stopped"
			elseif result.skipped then "skipped"
			elseif result.passed then "done"
			else "failed"
		script:SetAttribute(RESULT, HttpService:JSONEncode(result))
		script:SetAttribute(CURRENT, nil)
		script:SetAttribute(STATUS, final)
	end
	return result
end

local function runCount(n: number?, label: string): number?
	local count = if n == nil then SETTINGS.defaultRuns else n
	if type(count) ~= "number" or count < 1 or count > SETTINGS.maxRuns or count % 1 ~= 0 then
		warn(`{LOG} {label}(n) needs a whole number from 1 to {SETTINGS.maxRuns}`)
		return nil
	end
	return count
end

local AbilityTests = {}
AbilityTests.SETTINGS = SETTINGS

-- `n` boost-hops (default 50) on the Return Road; each must end upright, on its wheels and unstuck.
function AbilityTests.hops(n: number?): Result
	local count = runCount(n, "hops")
	if count == nil then
		return emptyResult("hops", "bad arguments")
	end
	return runTest("hops", function(ctx: Context): (string, string?)
		return hopsTest(ctx, count)
	end)
end

-- `n` flights (default 50) over the Flight Field with roll and flip input; the same checks.
function AbilityTests.flights(n: number?): Result
	local count = runCount(n, "flights")
	if count == nil then
		return emptyResult("flights", "bad arguments")
	end
	return runTest("flights", function(ctx: Context): (string, string?)
		return flightsTest(ctx, count)
	end)
end

-- Forged ability requests are refused and change nothing (PLAN.md Phase 10 acceptance).
function AbilityTests.forged(): Result
	return runTest("forged", forgedTest)
end

-- The drag strip's server time against this client's own, within ±0.05 s (PLAN.md Phase 10 acceptance).
function AbilityTests.drag(): Result
	return runTest("drag", dragTest)
end

-- forged(), then hops(5) and flights(5), then drag().
function AbilityTests.all(): Result
	return runTest("all", allTest)
end

local STARTERS: { [string]: (...any) -> Result } = {
	hops = AbilityTests.hops,
	flights = AbilityTests.flights,
	forged = AbilityTests.forged,
	drag = AbilityTests.drag,
	all = AbilityTests.all,
}

-- Starts a test in the background and returns at once: start("all"), start("hops", 50), start("flights", 50),
-- start("forged"), start("drag"). Poll lastResult() or watch the console.
function AbilityTests.start(name: TestName, ...: any)
	local starter = STARTERS[name]
	if starter == nil then
		warn(`{LOG} unknown test "{name}"; use "hops", "flights", "forged", "drag" or "all"`)
		return
	end
	task.spawn(starter, ...)
end

-- The last finished result, or nil while a test runs (or before any has finished).
function AbilityTests.lastResult(): Result?
	local encoded = script:GetAttribute(RESULT)
	if script:GetAttribute(STATUS) == "running" or type(encoded) ~= "string" then
		return nil
	end
	return HttpService:JSONDecode(encoded)
end

-- "idle", "running", "done", "skipped", "stopped" or "failed", and what the running test is doing.
function AbilityTests.status(): (string, string?)
	local status = script:GetAttribute(STATUS)
	local current = script:GetAttribute(CURRENT)
	return if type(status) == "string" then status else "idle", if type(current) == "string" then current else nil
end

-- Cancels a running test and lets go of the controls (the AutoDriver and any flight input); clears a "running"
-- status left by a test whose thread died.
function AbilityTests.stop()
	if not RunService:IsStudio() then
		return
	end
	script:SetAttribute(CANCEL, true)
	releaseControls()
	if script:GetAttribute(STATUS) == "running" then
		script:SetAttribute(STATUS, "stopped")
	end
end

-- Called once by the game's own client scripts in Studio, so flight input sent from MCP's copy of this module
-- reaches the InputController the game actually drives with (see the header).
function AbilityTests.serve()
	if not RunService:IsStudio() or isHost then
		return
	end
	local old = script:FindFirstChild(BRIDGE_NAME)
	if old then
		old:Destroy()
	end
	local bridge = Instance.new("BindableFunction")
	bridge.Name = BRIDGE_NAME
	bridge.OnInvoke = function(command: string, ...: any): ...any
		local handler = BRIDGE_COMMANDS[command]
		if handler == nil then
			error(`AbilityTests: unknown command "{command}"`)
		end
		return handler(...)
	end
	bridge.Parent = script
	isHost = true
end

return AbilityTests
