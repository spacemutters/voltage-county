--!strict
-- Studio-only AI Car Designer tests (PLAN.md Phase 11 acceptance; docs/phase-11-contracts.md "Tests"). Each one uses
-- only what a player's client can do: Net DesignCar, DesignChoice, ModCar, SpawnOwned, SellVehicle and BuyVehicle,
-- the Studio-only DevCredits, DevSetCash and DevSpawnVehicle, the DesignResult, ProfileSnapshot and VehicleReset the
-- server sends, and the car's own pose. Services/DesignerService decides every design and mod, answered by its Studio
-- fake backend (Config/Designer.devFakeBackend: these tests refuse to run without it, so they never reach the real
-- backend), and Services/CreditsService every charge. The tests measure what they did:
--   design(classId, opts)  asks for a design in that class, builds it, brings it out of the garage (SpawnOwned), puts
--                          it on the dev track (Config/DevTrack) and runs the Phase 1 driving checks with
--                          Dev/AutoDriver: it settles on its suspension at its ride height without bouncing, crosses
--                          the speed-bump lane at the sign's speed without flipping, and its 0-60 lands inside its class
--                          band (and within the Phase 1 tolerance of the design's own figure). The test car is then
--                          scrapped (SellVehicle on a design), so its custom slot is free again (opts.keep keeps it).
--                          An exotic needs an owned exotic: without one the request must be refused; the cheapest
--                          exotic is then bought (DevSetCash + BuyVehicle; opts.buyMissing = false skips instead).
--   credits(opts)          the credit rules at a 0, 1 and 5 credit balance (DevCredits): the free new car once (a
--                          second at 0 credits is refused), a new car costs Config/Designer.prices.newCar with one free
--                          re-roll and not a second, a refusal (the fake backend's refuse trigger) costs nothing, and no
--                          balance the server sends is ever below zero. Every design is discarded, so it takes no
--                          custom slot.
--   mod(opts)              an AI mod on an owned catalog car (opts.uid, else the first one in the garage; the cheapest
--                          dealership car is bought when there is none): a refused mod costs nothing, a mod costs
--                          Config/Designer.prices.mod, and the car brought out before and after differs only in what a
--                          catalog mod may change (paint, wheels, stance, extras): the chassis, wheel hubs and motors,
--                          seats and every body panel's shape stay the same (the body may only move up or down as a
--                          whole: stance), and nothing added takes part in physics. Physics unchanged means the modded
--                          car drives exactly as the car did, so it needs no drive of its own.
--   all(opts)              credits, mod, then design() for every designable class (Config/DesignKit.json).
--   start(name, ...)       runs any of them in the background and returns at once; lastResult() returns its result once
--                          done (nil while it runs), status() what it's doing, stop() cancels it.
-- Each returns a Result: { name, passed, skipped, reason, checks, notes, runs, elapsed }; runs holds one entry per
-- design driven, with its numbers. Every check is printed as it finishes, so get_console_output shows them even if
-- execute_luau stops waiting.
--
-- Getting a design onto the dev track. The garage always brings a car out at the spawn pad nearest the player, and
-- every pad is in Cedar Bend, far from the track. So design() first brings it out there (SpawnOwned, which also
-- publishes its catalog entry "custom:<designUid>"), then (opts.via):
--   "spawn" (tried first)  stands the character on the track and fires DevSpawnVehicle with the design's catalog id
--                          and trim, which puts a fresh copy Spawning.spawnOffset + half its length in front of them and
--                          seats them, as the other dev tests do with catalog cars. Needs Services/VehicleService to
--                          dev-spawn a published design and Net to let its id through.
--   "drive" (the fallback) drives the owned car there: Road/Pathfind's route in the right-hand lanes to the road point
--                          nearest the track, then across the open country west of the County Loop to the run-up. A
--                          car the server swaps for a fresh copy on the way (its generated look arriving) is driven on.
--
-- Run from MCP execute_luau in the Client datamodel of a playtest, once the player's data has loaded (a character is
-- enough: every test brings out its own car). Runs take minutes, longer than an execute_luau call waits:
--   require(game.Players.LocalPlayer.PlayerScripts.Client.Dev.DesignerTests).start("credits")
--   require(game.Players.LocalPlayer.PlayerScripts.Client.Dev.DesignerTests).start("mod")
--   require(game.Players.LocalPlayer.PlayerScripts.Client.Dev.DesignerTests).start("design", "sports")
--   require(game.Players.LocalPlayer.PlayerScripts.Client.Dev.DesignerTests).start("all")
--   require(game.Players.LocalPlayer.PlayerScripts.Client.Dev.DesignerTests).status()
--   require(game.Players.LocalPlayer.PlayerScripts.Client.Dev.DesignerTests).lastResult()
--
-- The bridge: execute_luau runs its own copy of every ModuleScript, so driving goes through Dev/AutoDriver's Bridge
-- (its header), which runs each drive in the game's own controllers. Remotes go through this copy's own Net (set up
-- on first use, as Dev/FleetTests does), and this copy listens to ProfileSnapshot, DesignResult and VehicleReset
-- itself. State every copy must see (running, cancel, the last result, when each remote was last called) lives in
-- attributes on this ModuleScript. Every test puts the credits and cash back as they were (opts.cleanup = false keeps
-- them); a car bought for a test stays in the garage.
--
-- Does nothing outside Studio (CLAUDE.md hard rule 8); the server refuses DevCredits, DevSetCash and DevSpawnVehicle
-- outside Studio too. The client loader never boots it.

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local AutoDriver = require(script.Parent.AutoDriver)
local Catalog = require(Shared.Vehicle.Catalog)
local Classes = require(Shared.Config.Classes)
local Customization = require(Shared.Config.Customization)
local DevTrack = require(Shared.Config.DevTrack)
local Economy = require(Shared.Config.Economy)
local Garage = require(Shared.Config.Garage)
local Graph = require(Shared.Road.Graph)
local Net = require(Shared.Net)
local Pathfind = require(Shared.Road.Pathfind)
local RouteTests = require(script.Parent.RouteTests)
local Spawning = require(Shared.Config.Spawning)
local Units = require(Shared.Util.Units)
local World = require(Shared.Config.World)

-- Config/Designer and the kit are read field by field with fallbacks, so a renamed field shows as a plain failure.
local Designer: any = require(Shared.Config.Designer)
local kit: any = require(Shared.Config.DesignKit)

export type TestName = "design" | "credits" | "mod" | "all"
export type Via = "spawn" | "drive"

export type Options = {
	via: Via?, -- design: how the car gets to the dev track (default: "spawn", then "drive" if that fails)
	keep: boolean?, -- design: keep each test car in the garage (default false: it is scrapped after its checks)
	buyMissing: boolean?, -- design (exotic) and mod: buy a car the test needs when there is none (default true)
	uid: string?, -- mod: the owned catalog car to mod (default: the first one in the garage)
	classes: { string }?, -- all: only these classes (default: every designable class)
	cleanup: boolean?, -- put the credits and cash back afterwards (default true)
}

export type Check = { name: string, passed: boolean, detail: string }

-- One design taken to the dev track.
export type DesignRun = {
	classId: string,
	passed: boolean,
	reason: string, -- why it stopped early, or "done"
	name: string?, -- the design's name
	vehicleId: string?, -- its catalog id ("custom:<designUid>")
	look: string?, -- "kit" or "generated": the body that was driven
	placedBy: string?, -- "spawn" or "drive"
	rideHeight: number?, -- studs, measured at rest
	configuredRideHeight: number?, -- studs, from its catalog geometry
	restVerticalSpeed: number?, -- studs/s, the most seen over the end of the settle
	bumpMaxTilt: number?, -- degrees from upright, the most seen on the bumps lane
	bumpMph: number?, -- average over the humps
	zeroToSixty: number?, -- seconds, measured
	designZeroToSixty: number?, -- seconds, the design's own figure (its trim)
	bandMin: number?, -- the class band's 0-60
	bandMax: number?,
}

export type Result = {
	name: string,
	passed: boolean,
	skipped: boolean,
	reason: string,
	checks: { Check },
	notes: { string },
	runs: { DesignRun },
	elapsed: number,
}

-- A dev tool, so its numbers live here rather than in Shared/Config (like Dev/AutoDriver's TUNING).
local SETTINGS = {
	-- Prompts. Generic and original; the fake backend answers each class with a fixed spec.
	designPrompt = "a friendly rounded %s for the test track", -- the class display name, in lower case
	modPrompt = "lift it, longer and wider body, new front bumper, big wing, chunky off-road tires, roof rack, "
		.. "desert tan paint",
	-- A prompt the fake backend refuses: Config/Designer.devFake.triggers.refuse goes first, and this follows it
	-- (docs: "the fake backend refuses prompts containing refuse-me").
	refuseText = "refuse-me: a test car nobody may build",
	creditsClass = "economy", -- credits(): the class asked for (open to everyone)
	creditsBalance = 5, -- credits(): the balance the paid steps start from
	-- Fallbacks for Config/Designer fields (PLAN.md §4 prices; Designer's time limits).
	newCarPrice = 2,
	modPrice = 1,
	freeRerolls = 1,
	requestSeconds = 20,
	-- Placing the car.
	runUpStuds = 120, -- the car starts this far before the bumps lane's near end, so it is at speed by the humps
	approachStuds = 150, -- "drive": comes to the run-up from this far further back, straight on
	standHeight = 3, -- studs above the ground the character is put at before a dev spawn
	streamTimeout = 10, -- seconds to wait for the map around the track to stream in
	spawnTimeout = 20, -- seconds for a spawn to seat the player
	exitTimeout = 5,
	settleSeconds = 1.5, -- after getting out, moving or sitting down, before the next step
	legRetries = 2, -- "drive": how often a leg carries on after the server swaps the car for a fresh copy
	-- Driving.
	transitMph = 45, -- "drive": on the roads to the track
	offroadMph = 25, -- "drive": across the open country to the run-up
	repositionMph = 15, -- from the end of the bumps lane onto the straight
	exitStep = 50, -- studs between the points from the bumps lane's end onto the straight
	maxMiter = 2, -- right-hand lane offset at corners (as Dev/RouteTests)
	-- The Phase 1 checks (docs/PROGRESS.md: the Spark settled at 0.65 studs for 0.7 configured; the lowest Ohm car
	-- peaked at 2.6 degrees over the humps at 40 mph; 0-60 within ±15 % of the configured figure).
	holdSeconds = 4, -- settle: held still this long once the car is placed...
	bounceWindow = 1.5, -- ...and over the last this-many seconds of it...
	maxRestVerticalSpeed = 0.5, -- ...the chassis moves up or down no faster than this (studs/s)
	restUprightDot = 0.98, -- at rest on flat ground the chassis UpVector.Y is at least this
	maxRestMph = 1, -- and it is this still
	rideHeightTolerance = 0.3, -- measured ride height within this many studs of the configured one...
	rideHeightShare = 0.3, -- ...or this share of it, whichever is more
	rayLength = 50, -- studs searched below the chassis for the ground
	maxBumpTiltDegrees = 30, -- the worst tilt allowed over the humps
	endUprightDot = 0.95, -- after the bumps the chassis UpVector.Y is at least this
	bumpSpeedShare = 0.85, -- average speed over the humps at least this share of the sign's speed
	bumpTimeout = 60, -- seconds for the bumps lane
	zeroToSixtyTimeout = 30,
	zeroToSixtyTolerance = 0.15, -- the Phase 1 check: within ±15 % of the configured figure
	-- Remotes and waiting.
	resultSlack = 15, -- seconds on top of the server's own time limits when waiting for a DesignResult
	snapshotTimeout = 10, -- seconds to wait for a ProfileSnapshot after a change
	callSlack = 0.15, -- seconds added to Net's refill time between two calls to one remote
	spareCash = 1000, -- left over after a car the test buys
	-- Comparing a car before and after a mod.
	shapeTolerance = 0.01, -- studs
}

local STATUS = "Status" -- attribute: "idle", "running", "done", "skipped", "stopped" or "failed"
local CURRENT = "Current" -- attribute: what the running test is doing now
local RESULT = "Result" -- attribute: the last result, as JSON
local CANCEL = "Cancel" -- attribute: true asks a running test to stop
local RUN_ID = "RunId" -- attribute: the id of the newest test
local CALL_PREFIX = "LastCall_" -- attribute per remote: os.clock() of its last call from any copy
local LOG = "[DesignerTests]"
local DRIVER_SEAT = "Driver" -- the vehicle model contract
local PANEL_FOLDERS = { "Body", "Lights", "Doors" } -- visual parts a stance may move together (Vehicle/Appearance)
local SEATS_FOLDER = "Seats"
local WHEELS_FOLDER = "Wheels"
local LOOK_FOLDER = "Look" -- what Vehicle/Appearance builds (wrap vinyl, extras, plates)
local PAINT_TAG = "Paint"
local WHEEL_NAMES = { "FL", "FR", "RL", "RR" }
local MOD_BLOCKS = { "body", "parts", "paint", "stance" }
local EPSILON = 1e-6

-- Everything the server tells this client during a test, kept as it arrives.
type ResultView = {
	requestId: string?,
	ok: boolean,
	message: string,
	raw: { [string]: any },
	at: number, -- os.clock()
}

type Watch = {
	snapshot: { [string]: any }?, -- the latest ProfileSnapshot payload
	snapshots: number,
	lowestBalance: number?, -- the lowest credit balance any snapshot showed
	results: { ResultView }, -- DesignResults, in arrival order
	resets: number, -- VehicleResets
	changed: BindableEvent, -- fires after every one of the above
	connections: { RBXScriptConnection },
}

type Context = {
	id: string,
	name: string,
	started: number,
	result: Result,
	watch: Watch,
	options: Options,
	spawnBroken: string?, -- why a dev spawn of a design didn't work (later designs drive straight away)
}

type Reply = { [string]: any }

---------------------------------------------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------------------------------------------

local function flat(v: Vector3): Vector3
	return Vector3.new(v.X, 0, v.Z)
end

local function round(value: number?, places: number): number?
	if value == nil then
		return nil
	end
	local scale = 10 ^ places
	return math.round(value * scale) / scale
end

local function format(value: number?, places: number): string
	return if value == nil then "?" else string.format(`%.{places}f`, value)
end

local function numberIn(map: any, key: string, fallback: number): number
	local value = if type(map) == "table" then map[key] else nil
	return if type(value) == "number" and value == value then value else fallback
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

local function check(ctx: Context, name: string, passed: boolean, detail: string): boolean
	table.insert(ctx.result.checks, { name = name, passed = passed, detail = detail })
	print(`{LOG} {ctx.name}: {if passed then "PASS" else "FAIL"} {name} ({detail})`)
	return passed
end

local function failedChecks(ctx: Context): number
	local failed = 0
	for _, item in ctx.result.checks do
		if not item.passed then
			failed += 1
		end
	end
	return failed
end

local netReady = false

-- This copy of Net may be MCP's own (not the game's), so make sure it knows the remotes.
local function ensureNet()
	if not netReady then
		Net.setupClient()
		netReady = true
	end
end

-- Waits until `test()` is true, re-checking whenever one of `signals` fires, for at most `timeout` seconds; a
-- cancel ends the wait too. Returns whether `test()` came true.
local function waitFor(ctx: Context, test: () -> boolean, signals: { RBXScriptSignal }, timeout: number): boolean
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
	for _, signal in signals do
		table.insert(
			connections,
			signal:Connect(function()
				if test() then
					finish(true)
				end
			end)
		)
	end
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

-- Waits out what's left of Net's refill time since the last call to `remote` (from any copy of this module), so
-- Net never drops a call: one call per 1 / perSecond seconds, plus SETTINGS.callSlack.
local function spaceCalls(remote: string)
	local spec = Net.declared()[remote]
	local gap = if spec ~= nil and spec.perSecond > 0 then 1 / spec.perSecond + SETTINGS.callSlack else 0
	local attribute = CALL_PREFIX .. remote
	local last = script:GetAttribute(attribute)
	if type(last) == "number" then
		local wait = gap - (os.clock() - last)
		if wait > 0 then
			task.wait(wait)
		end
	end
	script:SetAttribute(attribute, os.clock())
end

-- Calls a function remote; the reply table, or nil when the call failed or Net turned it away. `retry` sends a call
-- that got no reply once more (only for calls that are safe to repeat).
local function invoke(remote: string, payload: any?, retry: boolean?): Reply?
	ensureNet()
	for _ = 1, if retry then 2 else 1 do
		spaceCalls(remote)
		local ok, reply = pcall(Net.invokeServer, remote, payload)
		if ok and type(reply) == "table" then
			return reply
		end
		if not ok then
			warn(`{LOG} {remote} failed: {reply}`)
		end
	end
	return nil
end

local function fire(remote: string, payload: any?)
	ensureNet()
	spaceCalls(remote)
	Net.fireServer(remote, payload)
end

local function describe(reply: Reply?): string
	if reply == nil then
		return "no reply"
	end
	return `{if reply.ok == true then "ok" else "refused"}: {tostring(reply.message)}`
end

local function cash(): number
	local value = Players.LocalPlayer:GetAttribute(Economy.cashAttribute)
	return if type(value) == "number" then value else 0
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

local function carPose(): CFrame?
	local car = currentCar()
	local chassis = if car then car.PrimaryPart else nil
	return if chassis then chassis.CFrame else nil
end

local function carIdentity(car: Model): (string?, string?)
	local vehicleId, trim = car:GetAttribute("VehicleId"), car:GetAttribute("Trim")
	return if type(vehicleId) == "string" then vehicleId else nil, if type(trim) == "string" then trim else nil
end

local function seatSignals(ctx: Context): { RBXScriptSignal }
	local signals: { RBXScriptSignal } = { ctx.watch.changed.Event }
	local humanoid = humanoidOf()
	if humanoid then
		table.insert(signals, humanoid:GetPropertyChangedSignal("SeatPart"))
	end
	return signals
end

-- Waits until the player sits in the Driver seat of a car that passes `test`. The car, or nil on a timeout.
local function waitForCar(ctx: Context, test: (car: Model) -> boolean, timeout: number): Model?
	local found: Model? = nil
	waitFor(ctx, function(): boolean
		local car = currentCar()
		if car ~= nil and test(car) then
			found = car
			return true
		end
		return false
	end, seatSignals(ctx), timeout)
	return found
end

-- Gets out of any car and waits for the server to stand the character beside it.
local function leaveCar(ctx: Context): boolean
	local humanoid = humanoidOf()
	if humanoid == nil or humanoid.SeatPart == nil then
		return true
	end
	humanoid.Sit = false
	humanoid.Jump = true
	local out = waitFor(ctx, function(): boolean
		return humanoid.SeatPart == nil
	end, { humanoid:GetPropertyChangedSignal("SeatPart") }, SETTINGS.exitTimeout)
	if out then
		task.wait(SETTINGS.settleSeconds)
	end
	return out
end

local function lowerFirst(text: string): string
	return string.lower(string.sub(text, 1, 1)) .. string.sub(text, 2)
end

local function classLabel(classId: string): string
	local class = Classes[classId]
	return if class ~= nil then class.displayName else classId
end

---------------------------------------------------------------------------------------------------------------
-- What the server says: ProfileSnapshot, DesignResult, VehicleReset
---------------------------------------------------------------------------------------------------------------

local function balanceOf(snapshot: any): number?
	local credits = if type(snapshot) == "table" then snapshot.credits else nil
	local balance = if type(credits) == "table" then credits.balance else nil
	return if type(balance) == "number" then balance else nil
end

local function newWatch(): Watch
	ensureNet()
	local watch: Watch = {
		snapshot = nil,
		snapshots = 0,
		lowestBalance = nil,
		results = {},
		resets = 0,
		changed = Instance.new("BindableEvent"),
		connections = {},
	}
	table.insert(
		watch.connections,
		Net.onClientEvent("ProfileSnapshot", function(payload: any)
			if type(payload) ~= "table" then
				return
			end
			watch.snapshot = payload
			watch.snapshots += 1
			local balance = balanceOf(payload)
			if balance ~= nil and (watch.lowestBalance == nil or balance < (watch.lowestBalance :: number)) then
				watch.lowestBalance = balance
			end
			watch.changed:Fire()
		end)
	)
	table.insert(
		watch.connections,
		Net.onClientEvent("DesignResult", function(payload: any)
			if type(payload) ~= "table" then
				return
			end
			table.insert(watch.results, {
				requestId = if type(payload.requestId) == "string" then payload.requestId else nil,
				ok = payload.ok == true,
				message = if type(payload.message) == "string" then payload.message else "",
				raw = payload,
				at = os.clock(),
			})
			watch.changed:Fire()
		end)
	)
	table.insert(
		watch.connections,
		Net.onClientEvent("VehicleReset", function()
			watch.resets += 1
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

-- Sets the cash to exactly `amount` (DevSetCash) and waits for the Cash attribute to show it.
local function setCash(ctx: Context, amount: number): boolean
	local target = math.max(0, math.floor(amount))
	local reply = invoke("DevSetCash", { amount = target }, true)
	if reply == nil or reply.ok ~= true then
		return false
	end
	local player = Players.LocalPlayer
	return waitFor(ctx, function(): boolean
		return cash() == target
	end, { player:GetAttributeChangedSignal(Economy.cashAttribute) }, SETTINGS.snapshotTimeout)
end

-- The profile as the server has it now. Nothing sends a snapshot until something changes, so this changes the cash
-- by $1 (runTest puts the cash back) and reads the snapshot that follows. nil when none comes.
local function freshSnapshot(ctx: Context): { [string]: any }?
	local since = ctx.watch.snapshots
	if not setCash(ctx, cash() + 1) then
		return nil
	end
	waitFor(ctx, function(): boolean
		return ctx.watch.snapshots > since
	end, { ctx.watch.changed.Event }, SETTINGS.snapshotTimeout)
	return if ctx.watch.snapshots > since then ctx.watch.snapshot else nil
end

local function balanceNow(ctx: Context): number?
	return balanceOf(freshSnapshot(ctx))
end

-- Sets the credits to exactly `amount` (DevCredits). True once the server's reply and a snapshot show it.
local function setCredits(ctx: Context, amount: number): boolean
	local reply = invoke("DevCredits", { amount = amount }, true)
	if reply == nil or reply.ok ~= true then
		note(ctx, `DevCredits {amount}: {describe(reply)}`)
		return false
	end
	return balanceNow(ctx) == amount
end

-- The uids of the player's custom cars in a snapshot.
local function customUids(snapshot: any): { [string]: boolean }
	local uids: { [string]: boolean } = {}
	local vehicles = if type(snapshot) == "table" then snapshot.vehicles else nil
	if type(vehicles) == "table" then
		for _, vehicle in vehicles do
			if
				type(vehicle) == "table"
				and vehicle.vehicleId == Garage.customVehicleId
				and type(vehicle.uid) == "string"
			then
				uids[vehicle.uid] = true
			end
		end
	end
	return uids
end

-- The player's drivable catalog cars in a snapshot: { uid, vehicleId, trim }, in garage order.
local function catalogCars(snapshot: any): { { uid: string, vehicleId: string, trim: string } }
	local cars: { { uid: string, vehicleId: string, trim: string } } = {}
	local vehicles = if type(snapshot) == "table" then snapshot.vehicles else nil
	if type(vehicles) ~= "table" then
		return cars
	end
	for _, vehicle in vehicles do
		if
			type(vehicle) == "table"
			and type(vehicle.uid) == "string"
			and type(vehicle.vehicleId) == "string"
			and type(vehicle.trim) == "string"
			and vehicle.vehicleId ~= Garage.customVehicleId
		then
			local entry = Catalog.getVehicle(vehicle.vehicleId)
			if entry ~= nil and entry.playerDrivable then
				table.insert(cars, { uid = vehicle.uid, vehicleId = vehicle.vehicleId, trim = vehicle.trim })
			end
		end
	end
	return cars
end

-- Seconds to wait for a DesignResult: the server's request time limit (with its retries), the fake backend's delay
-- and the generation budget, plus slack.
local function resultTimeout(): number
	local requestSeconds = numberIn(Designer, "requestTimeoutSeconds", SETTINGS.requestSeconds)
	local retries = numberIn(Designer, "networkRetries", 0)
	local fake = numberIn(Designer.devFake, "delaySeconds", 0)
	local generation = Designer.generation
	local generationSeconds = if type(generation) == "table" and generation.enabled ~= false
		then numberIn(generation, "timeoutSeconds", 0)
		else 0
	return requestSeconds * (1 + retries) + fake + generationSeconds + SETTINGS.resultSlack
end

-- The first DesignResult after the `since`-th one whose requestId is one of `ids` (any, when `ids` is empty).
local function awaitResult(ctx: Context, ids: { string }, since: number): ResultView?
	local found: ResultView? = nil
	waitFor(ctx, function(): boolean
		for i = since + 1, #ctx.watch.results do
			local view = ctx.watch.results[i]
			if #ids == 0 or (view.requestId ~= nil and table.find(ids, view.requestId) ~= nil) then
				found = view
				return true
			end
		end
		return false
	end, { ctx.watch.changed.Event }, resultTimeout())
	return found
end

-- Sends a request (DesignCar or ModCar) and waits for its DesignResult. The reply, and the result when the request
-- was taken (nil when it was refused at once or no result came).
local function request(ctx: Context, remote: string, payload: { [string]: any }): (Reply?, ResultView?)
	local since = #ctx.watch.results
	local reply = invoke(remote, payload)
	if reply == nil or reply.ok ~= true then
		return reply, nil
	end
	local ids: { string } = if type(reply.requestId) == "string" then { reply.requestId } else {}
	return reply, awaitResult(ctx, ids, since)
end

-- Sends a DesignChoice for a finished design. For a re-roll, also waits for the new design's result.
local function choose(ctx: Context, view: ResultView, choice: string): (Reply?, ResultView?)
	local since = #ctx.watch.results
	local reply = invoke("DesignChoice", { requestId = view.requestId, choice = choice })
	if choice ~= "reroll" or reply == nil or reply.ok ~= true then
		return reply, nil
	end
	-- The new design comes back under the id the reply names, or the old one; with neither, the next result is it
	-- (only one design is ever in flight).
	local ids: { string } = {}
	if type(reply.requestId) == "string" then
		table.insert(ids, reply.requestId)
		if view.requestId ~= nil then
			table.insert(ids, view.requestId)
		end
	end
	return reply, awaitResult(ctx, ids, since)
end

-- The spec a DesignResult carries (a design or a mod), wherever the server put it, or nil.
local function specOf(view: ResultView): { [string]: any }?
	local raw = view.raw
	for _, candidate in { raw.spec, raw.design, if type(raw.design) == "table" then raw.design.spec else nil, raw.mod } do
		if
			type(candidate) == "table"
			and (candidate.body ~= nil or candidate.parts ~= nil or candidate.paint ~= nil or candidate.class ~= nil)
		then
			return candidate
		end
	end
	return nil
end

local function price(kind: string, fallback: number): number
	return numberIn(Designer.prices, kind, fallback)
end

local function designPrompt(classId: string): string
	return string.format(SETTINGS.designPrompt, string.lower(classLabel(classId)))
end

local function refusePrompt(): string
	local triggers = if type(Designer.devFake) == "table" then Designer.devFake.triggers else nil
	local trigger = if type(triggers) == "table" and type(triggers.refuse) == "string" then triggers.refuse else ""
	return if trigger ~= "" then `{trigger} {SETTINGS.refuseText}` else SETTINGS.refuseText
end

-- Whether a refused request's message is the server's "a design is still waiting for build, re-roll or discard".
local function pendingFromBefore(reply: Reply?): boolean
	if reply == nil then
		return false
	end
	if reply.code == "pending" or reply.code == "busy" then
		return true
	end
	local messages = Designer.messages
	return type(messages) == "table" and (reply.message == messages.pendingChoice or reply.message == messages.busy)
end

---------------------------------------------------------------------------------------------------------------
-- Cars the tests need
---------------------------------------------------------------------------------------------------------------

-- Brings an owned car out of the garage (SpawnOwned seats the player). The car, or nil and why.
local function spawnOwned(ctx: Context, uid: string): (Model?, string?)
	setCurrent(ctx, `bringing out car {uid}`)
	local previous = currentCar()
	local reply = invoke("SpawnOwned", { uid = uid }, true)
	if reply == nil or reply.ok ~= true then
		return nil, `SpawnOwned {describe(reply)}`
	end
	local car = waitForCar(ctx, function(found: Model): boolean
		return found ~= previous and found:GetAttribute(Garage.ownedUidAttribute) == uid
	end, SETTINGS.spawnTimeout)
	if car == nil then
		return nil, "SpawnOwned answered, but didn't seat you in the car"
	end
	-- The game's DriveController starts once the car has arrived on this client; its look goes on just before.
	task.wait(SETTINGS.settleSeconds)
	return currentCar(), nil
end

-- The cheapest base dealership trim of a class (any class when nil): vehicleId, trim and price.
local function cheapestDealershipCar(classId: string?): (string?, string?, number?)
	local bestId: string?, bestTrim: string?, bestPrice = nil, nil, math.huge
	for _, vehicleId in Catalog.vehicleIds() do
		local vehicle = Catalog.getVehicle(vehicleId)
		if vehicle ~= nil and vehicle.playerDrivable and (classId == nil or vehicle.class == classId) then
			for _, trim in vehicle.trims do
				local cost = Catalog.totalPrice(vehicleId, trim.id)
				if
					trim.acquisition == "dealership"
					and trim.upgradeFrom == nil
					and cost ~= nil
					and cost < bestPrice
				then
					bestId, bestTrim, bestPrice = vehicleId, trim.id, cost
				end
			end
		end
	end
	return bestId, bestTrim, if bestId ~= nil then bestPrice else nil
end

-- Buys the cheapest dealership car of a class (any when nil), with the cash set to cover it. Its uid, or nil.
local function buyCar(ctx: Context, classId: string?): string?
	local vehicleId, trim, cost = cheapestDealershipCar(classId)
	if vehicleId == nil or trim == nil or cost == nil then
		note(ctx, `no dealership car to buy{if classId then ` in {classId}` else ""}`)
		return nil
	end
	setCurrent(ctx, `buying a {vehicleId}/{trim} for the test`)
	if not setCash(ctx, cost + SETTINGS.spareCash) then
		note(ctx, `couldn't set the cash to {Economy.formatCash(cost + SETTINGS.spareCash)}`)
		return nil
	end
	local reply = invoke("BuyVehicle", { vehicleId = vehicleId, trim = trim })
	if reply == nil or reply.ok ~= true or type(reply.uid) ~= "string" then
		note(ctx, `BuyVehicle {vehicleId}/{trim}: {describe(reply)}`)
		return nil
	end
	note(ctx, `bought a {vehicleId}/{trim} for the test (it stays in the garage)`)
	return reply.uid
end

-- Whether the player owns a catalog car of `classId`.
local function ownsClass(snapshot: any, classId: string): boolean
	for _, car in catalogCars(snapshot) do
		local vehicle = Catalog.getVehicle(car.vehicleId)
		if vehicle ~= nil and vehicle.class == classId then
			return true
		end
	end
	return false
end

---------------------------------------------------------------------------------------------------------------
-- Getting a design onto the dev track
---------------------------------------------------------------------------------------------------------------

-- The way along the bumps lane (its waypoints run from the near end to the far end), on the ground plane.
local function laneAxis(): Vector3
	return flat(DevTrack.bumpsEnd - DevTrack.bumpsStart).Unit
end

-- Where the car starts: in line with the bumps lane, SETTINGS.runUpStuds before its near end, facing along it.
local function runUpPoint(): Vector3
	local b = DevTrack.bumps
	local nearEnd = Vector3.new(b.centerX, DevTrack.surfaceY, b.nearZ)
	return nearEnd - laneAxis() * SETTINGS.runUpStuds
end

-- Right-hand lane offset for the stretch a-b, from the lanes of the road under its middle (as Dev/RouteTests).
local function laneOffsetFor(a: Vector3, b: Vector3): number
	local edgeIndex = Graph.nearestEdge((a + b) / 2)
	local edge = if edgeIndex then Graph.edges()[edgeIndex] else nil
	return if edge then RouteTests.Math.rightLaneOffset(edge.lanes, World.laneWidth) else 0
end

-- Puts a fresh copy of the design on the run-up with DevSpawnVehicle (see the header). The car, or nil and why.
local function devSpawnOnTrack(ctx: Context, vehicleId: string, trim: string): (Model?, string?)
	local payload = { vehicleId = vehicleId, trim = trim }
	if not Net.declared().DevSpawnVehicle.validate(payload) then
		return nil, `Net's DevSpawnVehicle check turns away the {#vehicleId}-byte id "{vehicleId}"`
	end
	local geometry = Catalog.geometry(vehicleId, trim)
	if geometry == nil then
		return nil, `this client can't look up {vehicleId}/{trim} in the catalog`
	end
	local character = Players.LocalPlayer.Character
	if character == nil then
		return nil, "no character"
	end
	if not leaveCar(ctx) then
		return nil, "couldn't get out of the car"
	end
	local heading = laneAxis()
	local stand = runUpPoint()
		- heading * (Spawning.spawnOffset + geometry.length / 2)
		+ Vector3.yAxis * SETTINGS.standHeight
	setCurrent(ctx, `dev-spawning {vehicleId} on the dev track`)
	pcall(function()
		Players.LocalPlayer:RequestStreamAroundAsync(stand, SETTINGS.streamTimeout)
	end)
	character:PivotTo(CFrame.lookAt(stand, stand + heading))
	-- DevSpawnVehicle spawns in front of where the server sees the character: give the move time to get there.
	task.wait(SETTINGS.settleSeconds)
	fire("DevSpawnVehicle", payload)
	local car = waitForCar(ctx, function(found: Model): boolean
		return (carIdentity(found)) == vehicleId
	end, SETTINGS.spawnTimeout)
	if car == nil then
		return nil, `DevSpawnVehicle didn't seat you in {vehicleId} (does VehicleService dev-spawn designs yet?)`
	end
	task.wait(SETTINGS.settleSeconds)
	return currentCar(), nil
end

-- Drives `points` at `mph`. When the server swaps the car for a fresh copy of the same owned car on the way
-- (GarageService.refreshOwned: its generated look arriving), waits to sit in the new one and drives on from the
-- points not yet reached, up to SETTINGS.legRetries times. True when the car got to the last point, and why not.
local function driveLeg(ctx: Context, label: string, points: { Vector3 }, mph: number, uid: string?): (boolean, string)
	local remaining = table.clone(points)
	for _ = 0, SETTINGS.legRetries do
		local pose = carPose()
		if pose == nil then
			return false, "not driving"
		end
		local length = RouteTests.Math.length(pose.Position, remaining)
		local timeout = RouteTests.Math.timeoutFor(length, mph)
		setCurrent(ctx, `{label} ({math.floor(length)} studs)`)
		local report = AutoDriver.drive(remaining, { targetMph = mph, timeout = timeout })
		if report.completed then
			return true, report.reason
		end
		if report.reason ~= "left the car" or uid == nil or cancelRequested(ctx) then
			return false, report.reason
		end
		local again = waitForCar(ctx, function(car: Model): boolean
			return car:GetAttribute(Garage.ownedUidAttribute) == uid
		end, SETTINGS.spawnTimeout)
		if again == nil then
			return false, report.reason
		end
		local rest: { Vector3 } = {}
		table.move(remaining, report.pointsReached + 1, #remaining, 1, rest)
		if #rest == 0 then
			return true, "arrived"
		end
		remaining = rest
		note(ctx, `{label}: the server swapped the car for a fresh copy; driving on`)
		task.wait(SETTINGS.settleSeconds)
	end
	return false, "the car kept being swapped"
end

-- Drives the owned car from wherever it is to the run-up: the road route to the road point nearest the track,
-- then straight across the open country, coming to the run-up from behind. The car, or nil and why.
local function driveToTrack(ctx: Context, uid: string): (Model?, string?)
	local pose = carPose()
	if pose == nil then
		return nil, "not driving"
	end
	local runUp = runUpPoint()
	local approach = runUp - laneAxis() * SETTINGS.approachStuds
	local route = Pathfind.route(pose.Position, approach, pose.LookVector)
	if route == nil then
		return nil, "no road route toward the dev track"
	end
	if #route.points > 0 then
		local roadPoints = RouteTests.Math.keepRight(route.points, laneOffsetFor, SETTINGS.maxMiter)
		local ok, why = driveLeg(ctx, "driving to the dev track", roadPoints, SETTINGS.transitMph, uid)
		if not ok then
			return nil, `the drive to the dev track ended: {why}`
		end
	end
	local ok, why = driveLeg(ctx, "crossing to the run-up", { approach, runUp }, SETTINGS.offroadMph, uid)
	if not ok then
		return nil, `the drive across to the run-up ended: {why}`
	end
	return currentCar(), nil
end

-- Puts the design (owned car `uid`, catalog id `vehicleId`) on the run-up, by opts.via (see the header). The car,
-- or nil and why.
local function placeOnTrack(
	ctx: Context,
	run: DesignRun,
	uid: string,
	vehicleId: string,
	trim: string
): (Model?, string?)
	local via = ctx.options.via
	local spawnWhy: string? = nil
	if via ~= "drive" and ctx.spawnBroken == nil then
		local car, why = devSpawnOnTrack(ctx, vehicleId, trim)
		if car ~= nil then
			run.placedBy = "spawn"
			return car, nil
		end
		spawnWhy = why
		if via ~= "spawn" then
			ctx.spawnBroken = why
			note(ctx, `dev spawn didn't work ({why}); driving there instead (later designs drive straight away)`)
		end
	elseif via ~= "drive" then
		spawnWhy = ctx.spawnBroken
	end
	if via == "spawn" then
		return nil, spawnWhy or "dev spawn didn't work"
	end
	-- Drive the owned car there (bring it out again if the dev spawn attempt left it).
	local car = currentCar()
	if car == nil or car:GetAttribute(Garage.ownedUidAttribute) ~= uid then
		local spawned, why = spawnOwned(ctx, uid)
		if spawned == nil then
			return nil, why
		end
	end
	local placed, why = driveToTrack(ctx, uid)
	if placed ~= nil then
		run.placedBy = "drive"
	end
	return placed, why
end

---------------------------------------------------------------------------------------------------------------
-- The Phase 1 driving checks
---------------------------------------------------------------------------------------------------------------

-- Studs from the bottom of the chassis box to the ground under its middle, or nil when no ground is found.
local function rideHeightOf(car: Model): number?
	local chassis = car.PrimaryPart
	if chassis == nil then
		return nil
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local exclude: { Instance } = { car }
	local character = Players.LocalPlayer.Character
	if character then
		table.insert(exclude, character)
	end
	params.FilterDescendantsInstances = exclude
	local hit = Workspace:Raycast(chassis.Position, Vector3.new(0, -SETTINGS.rayLength, 0), params)
	if hit == nil then
		return nil
	end
	return chassis.Position.Y - chassis.Size.Y / 2 - hit.Position.Y
end

-- Settles: held still, the car rests upright on its suspension at its ride height without bouncing.
local function settleCheck(ctx: Context, run: DesignRun, car: Model, vehicleId: string, trim: string)
	local c = run.classId
	local chassis = car.PrimaryPart :: BasePart
	setCurrent(ctx, `{c}: letting it settle`)
	local samples: { { at: number, vy: number } } = {}
	local started = os.clock()
	local connection = RunService.Heartbeat:Connect(function()
		if chassis.Parent ~= nil then
			table.insert(samples, { at = os.clock() - started, vy = chassis.AssemblyLinearVelocity.Y })
		end
	end)
	AutoDriver.holdStill(SETTINGS.holdSeconds)
	connection:Disconnect()

	local windowStart = SETTINGS.holdSeconds - SETTINGS.bounceWindow
	local bounce = 0
	for _, sample in samples do
		if sample.at >= windowStart then
			bounce = math.max(bounce, math.abs(sample.vy))
		end
	end
	local mph = Units.studsToMph(chassis.AssemblyLinearVelocity.Magnitude)
	local up = chassis.CFrame.UpVector.Y
	run.restVerticalSpeed = round(bounce, 3)
	check(
		ctx,
		`{c}: settles on its suspension`,
		#samples > 0
			and up >= SETTINGS.restUprightDot
			and mph <= SETTINGS.maxRestMph
			and bounce <= SETTINGS.maxRestVerticalSpeed,
		`upright {format(up, 3)}, {format(mph, 2)} mph, up/down at most {format(bounce, 2)} studs/s over the last `
			.. `{SETTINGS.bounceWindow} s`
	)

	local geometry = Catalog.geometry(vehicleId, trim)
	local configured = if geometry ~= nil then geometry.rideHeight else nil
	local measured = rideHeightOf(car)
	run.rideHeight = round(measured, 3)
	run.configuredRideHeight = configured
	local tolerance = if configured ~= nil
		then math.max(SETTINGS.rideHeightTolerance, configured * SETTINGS.rideHeightShare)
		else 0
	check(
		ctx,
		`{c}: rests at its ride height`,
		measured ~= nil and configured ~= nil and math.abs(measured - configured) <= tolerance,
		`{format(measured, 2)} studs, configured {format(configured, 2)} (±{format(tolerance, 2)})`
	)
end

-- The bumps lane at the sign's speed: the car gets to its end, never tips past SETTINGS.maxBumpTiltDegrees, ends
-- upright with no VehicleReset, and averages close to the sign's speed over the humps.
local function bumpsCheck(ctx: Context, run: DesignRun, car: Model)
	local c = run.classId
	local b = DevTrack.bumps
	local chassis = car.PrimaryPart :: BasePart
	local axis = laneAxis()
	local nearEnd = Vector3.new(b.centerX, DevTrack.surfaceY, b.nearZ)
	local first, last = math.huge, -math.huge
	for _, distance in b.at do
		first = math.min(first, distance)
		last = math.max(last, distance)
	end
	local humpsFrom, humpsTo = first - b.chord / 2, last + b.chord / 2

	local maxTilt, mphSum, mphCount = 0, 0, 0
	local resetsBefore = ctx.watch.resets
	local connection = RunService.Heartbeat:Connect(function()
		if chassis.Parent == nil then
			return
		end
		local cframe = chassis.CFrame
		maxTilt = math.max(maxTilt, math.deg(math.acos(math.clamp(cframe.UpVector.Y, -1, 1))))
		local along = flat(cframe.Position - nearEnd):Dot(axis)
		if along >= humpsFrom and along <= humpsTo then
			mphSum += Units.studsToMph(math.abs(chassis.AssemblyLinearVelocity:Dot(cframe.LookVector)))
			mphCount += 1
		end
	end)
	setCurrent(ctx, `{c}: crossing the bumps at {b.signMph} mph`)
	local report = AutoDriver.drive(
		{ DevTrack.bumpsStart, DevTrack.bumpsEnd },
		{ targetMph = b.signMph, timeout = SETTINGS.bumpTimeout }
	)
	connection:Disconnect()

	local averageMph = if mphCount > 0 then mphSum / mphCount else nil
	local resets = ctx.watch.resets - resetsBefore
	local up = chassis.CFrame.UpVector.Y
	run.bumpMaxTilt = round(maxTilt, 1)
	run.bumpMph = round(averageMph, 1)
	check(
		ctx,
		`{c}: drives the length of the bumps lane`,
		report.completed and report.stuckEvents == 0,
		`{report.reason} in {format(report.elapsed, 1)} s, {report.stuckEvents} stuck`
	)
	check(
		ctx,
		`{c}: crosses the bumps without flipping`,
		maxTilt <= SETTINGS.maxBumpTiltDegrees and up >= SETTINGS.endUprightDot and resets == 0,
		`worst tilt {format(maxTilt, 1)} degrees, ends upright {format(up, 3)}, {resets} resets`
	)
	check(
		ctx,
		`{c}: takes the humps at {b.signMph} mph`,
		averageMph ~= nil and averageMph >= b.signMph * SETTINGS.bumpSpeedShare,
		`{format(averageMph, 1)} mph on average over the humps`
	)
end

-- From the far end of the bumps lane onto the straight beside it, stopped and facing up it. The track runs along
-- -Z with the bumps lane west of the straight (Config/DevTrack), so the points step along the lane's axis and across
-- in X.
local function toStraight(ctx: Context, run: DesignRun): boolean
	local b, s = DevTrack.bumps, DevTrack.straight
	local axis = laneAxis()
	local y = DevTrack.surfaceY
	local farEnd = Vector3.new(b.centerX, y, b.nearZ) + axis * b.length
	local step = SETTINGS.exitStep
	local function at(x: number, steps: number): Vector3
		local along = farEnd + axis * (step * steps)
		return Vector3.new(x, y, along.Z)
	end
	local points = {
		at(b.centerX, 0.6),
		at((b.centerX + s.centerX) / 2, 1.6),
		at(s.centerX, 2.6),
		at(s.centerX, 3.6),
	}
	local stop = points[#points]
	local onStraight = stop.Z <= DevTrack.straightStart.Z and stop.Z >= DevTrack.straightEnd.Z
	local ok, why = driveLeg(ctx, `{run.classId}: onto the straight`, points, SETTINGS.repositionMph, nil)
	return check(
		ctx,
		`{run.classId}: gets onto the straight`,
		ok and onStraight,
		if onStraight then why else "the straight isn't beside the bumps lane's far end"
	)
end

-- 0-60 from a standstill on the straight: inside the class band, and within the Phase 1 tolerance of the design's
-- own figure.
local function zeroToSixtyCheck(ctx: Context, run: DesignRun, vehicleId: string, trim: string)
	local c = run.classId
	setCurrent(ctx, `{c}: 0-60`)
	local seconds = AutoDriver.zeroToSixty({ timeout = SETTINGS.zeroToSixtyTimeout })
	local band = Classes[c].zeroToSixtySec
	local own = Catalog.getTrim(vehicleId, trim)
	local figure = if own ~= nil then own.zeroToSixtySec else nil
	run.zeroToSixty = round(seconds, 2)
	run.designZeroToSixty = figure
	run.bandMin, run.bandMax = band.min, band.max
	check(
		ctx,
		`{c}: 0-60 inside the {classLabel(c)} band`,
		seconds ~= nil and seconds >= band.min - EPSILON and seconds <= band.max + EPSILON,
		`{format(seconds, 2)} s, band {band.min}..{band.max} s`
	)
	check(
		ctx,
		`{c}: 0-60 within {math.round(SETTINGS.zeroToSixtyTolerance * 100)} % of its own figure`,
		seconds ~= nil and figure ~= nil and math.abs(seconds - figure) <= figure * SETTINGS.zeroToSixtyTolerance,
		`{format(seconds, 2)} s measured, {format(figure, 2)} s configured`
	)
end

---------------------------------------------------------------------------------------------------------------
-- design(classId)
---------------------------------------------------------------------------------------------------------------

-- An exotic needs an owned exotic (Config/DesignKit requiresOwnedClass). Without one, a request must be refused;
-- then the cheapest one is bought (opts.buyMissing). True when the class can be designed now.
local function meetTierRule(ctx: Context, classId: string): boolean
	local required = kit.classes[classId].requiresOwnedClass
	if type(required) ~= "string" then
		return true
	end
	local snapshot = freshSnapshot(ctx)
	if ownsClass(snapshot, required) then
		note(ctx, `{classId}: you already own a {required}, so the tier rule's refusal isn't checked`)
		return true
	end
	setCurrent(ctx, `{classId}: asking without an owned {required}`)
	local reply, result = request(ctx, "DesignCar", { prompt = designPrompt(classId), classId = classId })
	if result ~= nil and result.ok then
		choose(ctx, result, "discard")
	end
	check(ctx, `{classId}: refused without an owned {required}`, reply ~= nil and reply.ok ~= true, describe(reply))
	if ctx.options.buyMissing == false then
		note(ctx, `{classId}: not buying a {required} (opts.buyMissing = false)`)
		return false
	end
	return buyCar(ctx, required) ~= nil
end

local function newRun(classId: string): DesignRun
	return { classId = classId, passed = false, reason = "" }
end

-- Scraps a test car (SellVehicle on a design scraps it) unless opts.keep.
local function scrap(ctx: Context, uid: string, name: string)
	if ctx.options.keep then
		note(ctx, `kept {name} in the garage (opts.keep)`)
		return
	end
	leaveCar(ctx)
	local reply = invoke("SellVehicle", { uid = uid })
	if reply == nil or reply.ok ~= true then
		note(ctx, `couldn't scrap the test car {name}: {describe(reply)}`)
	end
end

local function designOne(ctx: Context, classId: string): DesignRun
	local c = classId
	local run = newRun(c)
	table.insert(ctx.result.runs, run)
	local failedBefore = failedChecks(ctx)
	local function stop(reason: string): DesignRun
		run.reason = reason
		run.passed = false
		note(ctx, `{c}: stopped: {reason}`)
		return run
	end

	if kit.classes[c] == nil then
		check(ctx, `{c}: is a designable class`, false, "not in Config/DesignKit.json classes")
		return stop("not designable")
	end
	if not meetTierRule(ctx, c) then
		return stop(`needs an owned {kit.classes[c].requiresOwnedClass}`)
	end

	-- Ask for it, with credits for a paid design (the free car is used instead while it lasts).
	local newCar = price("newCar", SETTINGS.newCarPrice)
	if not setCredits(ctx, newCar) then
		return stop(`couldn't set the credits to {newCar}`)
	end
	local before = customUids(ctx.watch.snapshot)
	setCurrent(ctx, `{c}: asking for a design`)
	local reply, result = request(ctx, "DesignCar", { prompt = designPrompt(c), classId = c })
	local made = result ~= nil and result.ok
	check(
		ctx,
		`{c}: the designer makes it`,
		made,
		if result ~= nil then `result: {result.message}` else describe(reply)
	)
	if result == nil or not result.ok then
		if pendingFromBefore(reply) then
			note(ctx, "a design from before is still waiting: build, re-roll or discard it in the Design Studio first")
		end
		return stop(if result ~= nil then result.message else describe(reply))
	end
	local spec = specOf(result)
	run.name = if spec ~= nil and type(spec.name) == "string" then spec.name else nil
	if spec ~= nil and spec.class ~= nil then
		check(ctx, `{c}: the design is the class asked for`, spec.class == c, `class {tostring(spec.class)}`)
	end

	-- Build it: a new custom car in the garage.
	setCurrent(ctx, `{c}: building it`)
	local built = choose(ctx, result, "build")
	local uid: string? = if built ~= nil and type(built.uid) == "string" then built.uid else nil
	if uid == nil and built ~= nil and built.ok == true then
		waitFor(ctx, function(): boolean
			for candidate in customUids(ctx.watch.snapshot) do
				if not before[candidate] then
					uid = candidate
					return true
				end
			end
			return false
		end, { ctx.watch.changed.Event }, SETTINGS.snapshotTimeout)
		if uid == nil then
			for candidate in customUids(freshSnapshot(ctx)) do
				if not before[candidate] then
					uid = candidate
				end
			end
		end
	end
	if not check(ctx, `{c}: it goes in the garage`, uid ~= nil, describe(built)) or uid == nil then
		return stop("no new custom car in the garage")
	end
	local carUid = uid :: string

	-- Out of the garage: that publishes its catalog entry, and tells us its catalog id.
	local owned, spawnWhy = spawnOwned(ctx, carUid)
	if not check(ctx, `{c}: the garage brings it out`, owned ~= nil, spawnWhy or "seated") or owned == nil then
		scrap(ctx, carUid, `the {c} design`)
		return stop(spawnWhy or "not brought out")
	end
	local vehicleId, trim = carIdentity(owned)
	local entry = if vehicleId ~= nil then Catalog.getVehicle(vehicleId) else nil
	run.vehicleId = vehicleId
	check(
		ctx,
		`{c}: its catalog entry is the class asked for`,
		entry ~= nil and entry.class == c,
		`{tostring(vehicleId)}: {if entry ~= nil then entry.class else "not in this client's catalog"}`
	)
	if vehicleId == nil or trim == nil or entry == nil then
		scrap(ctx, carUid, `the {c} design`)
		return stop("its catalog entry can't be found")
	end

	-- Onto the dev track.
	local car, placeWhy = placeOnTrack(ctx, run, carUid, vehicleId, trim)
	if not check(ctx, `{c}: it gets onto the dev track`, car ~= nil, placeWhy or `by {run.placedBy}`) or car == nil then
		scrap(ctx, carUid, `the {c} design`)
		return stop(placeWhy or "not placed")
	end
	-- Driving the owned car, the server may still swap in its generated look (GarageService.refreshOwned) until the
	-- generation budget has passed; wait it out so no check is cut short.
	local generation = Designer.generation
	if run.placedBy == "drive" and type(generation) == "table" and generation.enabled ~= false then
		local untilDone = result.at + numberIn(generation, "timeoutSeconds", 0) + SETTINGS.settleSeconds
		if os.clock() < untilDone then
			setCurrent(ctx, `{c}: waiting out the generated look`)
			task.wait(untilDone - os.clock())
		end
		car = currentCar() or car
	end
	local lookAttribute = if type(generation) == "table" and type(generation.lookAttribute) == "string"
		then generation.lookAttribute
		else "GeneratedLook"
	run.look = if car:GetAttribute(lookAttribute) == true then "generated" else "kit"

	settleCheck(ctx, run, car, vehicleId, trim)
	if not cancelRequested(ctx) then
		bumpsCheck(ctx, run, car)
	end
	if not cancelRequested(ctx) and toStraight(ctx, run) then
		zeroToSixtyCheck(ctx, run, vehicleId, trim)
	end
	AutoDriver.stop()

	scrap(ctx, carUid, run.name or `the {c} design`)
	run.reason = if cancelRequested(ctx) then "stopped" else "done"
	run.passed = failedChecks(ctx) == failedBefore and not cancelRequested(ctx)
	print(
		`{LOG} {c}: {run.name or "?"} ({run.look}, by {run.placedBy}) rests at {format(run.rideHeight, 2)} studs, `
			.. `bumps worst {format(run.bumpMaxTilt, 1)} degrees at {format(run.bumpMph, 1)} mph, 0-60 `
			.. `{format(run.zeroToSixty, 2)} s -> {if run.passed then "PASS" else "FAIL"}`
	)
	return run
end

---------------------------------------------------------------------------------------------------------------
-- credits()
---------------------------------------------------------------------------------------------------------------

local function creditsTest(ctx: Context)
	local c = SETTINGS.creditsClass
	local newCar = price("newCar", SETTINGS.newCarPrice)
	local freeRerolls = numberIn(Designer.prices, "rerollsPaid", SETTINGS.freeRerolls)
	local start = SETTINGS.creditsBalance

	-- 1. The free new car, at 0 credits.
	if not check(ctx, "credits set to 0", setCredits(ctx, 0), "DevCredits") then
		return
	end
	-- Whether the snapshot says the free car is used (credits.freeDesignUsed, when the server sends it).
	local snapshotCredits = if type(ctx.watch.snapshot) == "table" then (ctx.watch.snapshot :: any).credits else nil
	local freeUsed: boolean? = if type(snapshotCredits) == "table"
			and type(snapshotCredits.freeDesignUsed) == "boolean"
		then snapshotCredits.freeDesignUsed
		else nil
	setCurrent(ctx, "the free new car")
	local reply, result = request(ctx, "DesignCar", { prompt = designPrompt(c), classId = c })
	if reply ~= nil and reply.ok == true then
		local came = result ~= nil and result.ok
		check(ctx, "the free new car is designed", came, if result then result.message else "no result")
		if result ~= nil and result.ok then
			choose(ctx, result, "discard")
		end
		local balance = balanceNow(ctx)
		check(ctx, "the free new car costs nothing", balance == 0, `balance {tostring(balance)}`)
	else
		if pendingFromBefore(reply) then
			note(ctx, "a design from before is still waiting: build, re-roll or discard it in the Design Studio first")
		end
		note(ctx, `no free new car on this save ({describe(reply)}): it was used before, so "once" isn't watched here`)
		if freeUsed ~= nil then
			check(
				ctx,
				"the free car is refused only once it's used",
				freeUsed,
				`the snapshot says freeDesignUsed = {tostring(freeUsed)}`
			)
		end
	end

	-- 2. Only once: another new car at 0 credits is refused, and the balance stays at 0.
	setCurrent(ctx, "a second new car at 0 credits")
	local again, againResult = request(ctx, "DesignCar", { prompt = designPrompt(c), classId = c })
	if againResult ~= nil and againResult.ok then
		choose(ctx, againResult, "discard")
	end
	check(ctx, "a second free car is refused", again ~= nil and again.ok ~= true, describe(again))
	local afterSecond = balanceNow(ctx)
	check(ctx, "the balance stays at 0", afterSecond == 0, `balance {tostring(afterSecond)}`)

	-- 3. Fewer credits than a new car costs: refused, nothing taken.
	local short = newCar - 1
	if short > 0 and setCredits(ctx, short) then
		setCurrent(ctx, `a new car with {short} credit(s)`)
		local tooFew, tooFewResult = request(ctx, "DesignCar", { prompt = designPrompt(c), classId = c })
		if tooFewResult ~= nil and tooFewResult.ok then
			choose(ctx, tooFewResult, "discard")
		end
		check(ctx, `a new car is refused with {short} credit(s)`, tooFew ~= nil and tooFew.ok ~= true, describe(tooFew))
		local balance = balanceNow(ctx)
		check(ctx, `the balance stays at {short}`, balance == short, `balance {tostring(balance)}`)
	end

	-- 4. A paid new car: the price comes off when the design comes back; the free re-roll(s) cost nothing more; the
	-- next re-roll is refused or charged as a new car. Discarding keeps the charge (Config/Designer.prices).
	if not check(ctx, `credits set to {start}`, setCredits(ctx, start), "DevCredits") then
		return
	end
	setCurrent(ctx, "a paid new car")
	local _, paid = request(ctx, "DesignCar", { prompt = designPrompt(c), classId = c })
	if
		not check(
			ctx,
			"a paid new car is designed",
			paid ~= nil and paid.ok,
			if paid then paid.message else "no result"
		)
	then
		return
	end
	local latest = paid :: ResultView
	local balance = balanceNow(ctx)
	check(ctx, `a new car costs {newCar} credits`, balance == start - newCar, `balance {tostring(balance)}`)
	for roll = 1, freeRerolls do
		setCurrent(ctx, `free re-roll {roll}`)
		local rerollReply, rerolled = choose(ctx, latest, "reroll")
		local ok = rerolled ~= nil and rerolled.ok
		check(
			ctx,
			`re-roll {roll} makes a new design`,
			ok,
			if rerolled then rerolled.message else describe(rerollReply)
		)
		if not ok then
			break
		end
		latest = rerolled :: ResultView
		local afterRoll = balanceNow(ctx)
		check(ctx, `re-roll {roll} is free`, afterRoll == start - newCar, `balance {tostring(afterRoll)}`)
	end
	setCurrent(ctx, "one re-roll too many")
	local extraReply, extra = choose(ctx, latest, "reroll")
	local charged = start - 2 * newCar
	if extraReply ~= nil and extraReply.ok == true then
		if extra ~= nil then
			latest = extra
		end
		local afterExtra = balanceNow(ctx)
		check(
			ctx,
			"a re-roll past the free one isn't free",
			afterExtra == charged,
			`accepted; balance {tostring(afterExtra)}, a new car's price would leave {charged}`
		)
	else
		check(ctx, "a re-roll past the free one isn't free", true, `refused: {describe(extraReply)}`)
	end
	local beforeDiscard = balanceNow(ctx)
	choose(ctx, latest, "discard")
	local afterDiscard = balanceNow(ctx)
	check(
		ctx,
		"discarding keeps what the design cost",
		afterDiscard ~= nil and afterDiscard == beforeDiscard,
		`balance {tostring(beforeDiscard)} -> {tostring(afterDiscard)}`
	)

	-- 5. A refusal costs nothing.
	if setCredits(ctx, start) then
		setCurrent(ctx, "a design the fake backend refuses")
		local refusedReply, refused = request(ctx, "DesignCar", { prompt = refusePrompt(), classId = c })
		if refused ~= nil and refused.ok then
			choose(ctx, refused, "discard")
		end
		local wasRefused = (refusedReply ~= nil and refusedReply.ok ~= true) or (refused ~= nil and not refused.ok)
		check(
			ctx,
			"the fake backend refuses it",
			wasRefused,
			if refused then `result: {refused.message}` else describe(refusedReply)
		)
		local afterRefusal = balanceNow(ctx)
		check(ctx, "a refused design costs nothing", afterRefusal == start, `balance {tostring(afterRefusal)}`)
	end

	-- 6. Never below zero, in anything the server sent.
	local lowest = ctx.watch.lowestBalance
	check(ctx, "no balance below zero", lowest ~= nil and lowest >= 0, `lowest seen {tostring(lowest)}`)
end

---------------------------------------------------------------------------------------------------------------
-- mod()
---------------------------------------------------------------------------------------------------------------

type Panel = { size: Vector3, rel: CFrame, class: string, shape: string }

-- What a catalog mod must leave alone, and what it may change, read from a car on this client.
type Shape = {
	identity: string,
	chassisSize: Vector3,
	density: number,
	friction: number,
	elasticity: number,
	hubs: { [string]: Vector3 }, -- every Wheel* attachment on the Chassis
	motors: { [string]: CFrame }, -- each wheel's Motor C0
	seats: { [string]: Panel },
	panels: { [string]: Panel }, -- Body, Lights and Doors parts the car was built with
	paint: { [string]: Color3 }, -- Paint-tagged panels' colours
	lookParts: number, -- parts a look or mod built (Vehicle/Appearance's Look folder or lookTag)
	physical: { string }, -- parts other than the Chassis that take part in physics
}

-- A part's path inside the model ("Body/Hood", "Body/Panel#2" for the second of two siblings with one name).
local function keyOf(model: Model, part: Instance): string
	local names: { string } = {}
	local node: Instance? = part
	while node ~= nil and node ~= model do
		local parent = node.Parent
		local name = node.Name
		if parent ~= nil then
			local index, count = 0, 0
			for _, sibling in parent:GetChildren() do
				if sibling.Name == name then
					count += 1
					if sibling == node then
						index = count
					end
				end
			end
			if count > 1 then
				name = `{name}#{index}`
			end
		end
		table.insert(names, 1, name)
		node = parent
	end
	return table.concat(names, "/")
end

local function isLookPart(model: Model, part: Instance): boolean
	if part:HasTag(Customization.lookTag) then
		return true
	end
	local node = part.Parent
	while node ~= nil and node ~= model do
		if node.Name == LOOK_FOLDER then
			return true
		end
		node = node.Parent
	end
	return false
end

local function shapeOf(car: Model): Shape?
	local chassis = car.PrimaryPart
	if chassis == nil then
		return nil
	end
	local properties = chassis.CurrentPhysicalProperties
	local vehicleId, trim = carIdentity(car)
	local shape: Shape = {
		identity = `{tostring(vehicleId)}/{tostring(trim)}`,
		chassisSize = chassis.Size,
		density = properties.Density,
		friction = properties.Friction,
		elasticity = properties.Elasticity,
		hubs = {},
		motors = {},
		seats = {},
		panels = {},
		paint = {},
		lookParts = 0,
		physical = {},
	}
	for _, child in chassis:GetChildren() do
		if child:IsA("Attachment") and string.sub(child.Name, 1, 5) == "Wheel" then
			shape.hubs[child.Name] = child.Position
		end
	end
	local wheels = car:FindFirstChild(WHEELS_FOLDER)
	for _, name in WHEEL_NAMES do
		local wheel = if wheels then wheels:FindFirstChild(name) else nil
		local motor = if wheel then wheel:FindFirstChild("Motor") else nil
		if motor ~= nil and motor:IsA("Motor6D") then
			shape.motors[name] = motor.C0
		end
	end
	local function panelOf(part: BasePart): Panel
		return {
			size = part.Size,
			rel = chassis.CFrame:ToObjectSpace(part.CFrame),
			class = part.ClassName,
			shape = if part:IsA("Part") then part.Shape.Name else "",
		}
	end
	local seats = car:FindFirstChild(SEATS_FOLDER)
	if seats then
		for _, part in seats:GetDescendants() do
			if part:IsA("BasePart") then
				shape.seats[keyOf(car, part)] = panelOf(part)
			end
		end
	end
	for _, folderName in PANEL_FOLDERS do
		local folder = car:FindFirstChild(folderName)
		if folder then
			for _, part in folder:GetDescendants() do
				if part:IsA("BasePart") and not isLookPart(car, part) then
					local key = keyOf(car, part)
					shape.panels[key] = panelOf(part)
					if part:HasTag(PAINT_TAG) then
						shape.paint[key] = part.Color
					end
				end
			end
		end
	end
	for _, part in car:GetDescendants() do
		if part:IsA("BasePart") and part ~= chassis then
			if isLookPart(car, part) then
				shape.lookParts += 1
			end
			if not part.Massless or part.CanCollide then
				table.insert(shape.physical, keyOf(car, part))
			end
		end
	end
	table.sort(shape.physical)
	return shape
end

local function sameCFrame(a: CFrame, b: CFrame, tolerance: number): boolean
	return a.Position:FuzzyEq(b.Position, tolerance)
		and a.LookVector:FuzzyEq(b.LookVector, tolerance)
		and a.UpVector:FuzzyEq(b.UpVector, tolerance)
end

local function samePanel(a: Panel, b: Panel): boolean
	return a.class == b.class and a.shape == b.shape and a.size:FuzzyEq(b.size, SETTINGS.shapeTolerance)
end

-- What changed between two shapes that a catalog mod must leave alone, as readable lines (empty: nothing), and the
-- one vertical offset every body panel moved by (stance).
local function forbiddenChanges(before: Shape, after: Shape): ({ string }, number)
	local tolerance = SETTINGS.shapeTolerance
	local changes: { string } = {}
	if before.identity ~= after.identity then
		table.insert(changes, `identity {before.identity} -> {after.identity}`)
	end
	if not before.chassisSize:FuzzyEq(after.chassisSize, tolerance) then
		table.insert(changes, `chassis size {before.chassisSize} -> {after.chassisSize}`)
	end
	for _, field in { "density", "friction", "elasticity" } do
		local a, b = (before :: any)[field], (after :: any)[field]
		if math.abs(a - b) > tolerance then
			table.insert(changes, `chassis {field} {a} -> {b}`)
		end
	end
	for name, position in before.hubs do
		local now = after.hubs[name]
		if now == nil or not now:FuzzyEq(position, tolerance) then
			table.insert(changes, `hub {name} moved`)
		end
	end
	for name, c0 in before.motors do
		local now = after.motors[name]
		if now == nil or not sameCFrame(now, c0, tolerance) then
			table.insert(changes, `wheel {name}'s motor moved`)
		end
	end
	for key, seat in before.seats do
		local now = after.seats[key]
		if now == nil or not samePanel(seat, now) or not sameCFrame(seat.rel, now.rel, tolerance) then
			table.insert(changes, `seat {key} changed`)
		end
	end
	-- Body panels: same set, same size and shape, all moved by one vertical offset (or none).
	local offset: number? = nil
	for key, panel in before.panels do
		local now = after.panels[key]
		if now == nil then
			table.insert(changes, `panel {key} is gone`)
		elseif not samePanel(panel, now) then
			table.insert(changes, `panel {key} changed size or shape`)
		else
			local delta = now.rel.Position - panel.rel.Position
			local moved = offset or delta.Y
			offset = moved
			local rotated = not now.rel.LookVector:FuzzyEq(panel.rel.LookVector, tolerance)
				or not now.rel.UpVector:FuzzyEq(panel.rel.UpVector, tolerance)
			if
				math.abs(delta.X) > tolerance
				or math.abs(delta.Z) > tolerance
				or math.abs(delta.Y - moved) > tolerance
				or rotated
			then
				table.insert(changes, `panel {key} moved on its own`)
			end
		end
	end
	table.sort(changes)
	return changes, offset or 0
end

-- The fields of a mod spec that change what a catalog car must keep (outside kit.mod.catalogAllowed).
local function disallowedOnCatalog(spec: { [string]: any }): { string }
	local allowed = kit.mod.catalogAllowed
	local keep = kit.mod.keep
	local touched: { string } = {}
	for _, blockName in MOD_BLOCKS do
		local fields = spec[blockName]
		if type(fields) == "table" and table.find(allowed, blockName) == nil then
			for field, value in fields do
				local changes = if type(value) == "string"
					then value ~= keep
					elseif type(value) == "number" then true
					else type(value) == "table" and value.change == true
				if changes and table.find(allowed, `{blockName}.{field}`) == nil then
					table.insert(touched, `{blockName}.{field}`)
				end
			end
		end
	end
	table.sort(touched)
	return touched
end

local function modTest(ctx: Context)
	local modPrice = price("mod", SETTINGS.modPrice)

	-- The car: opts.uid, the first owned catalog car, or the cheapest dealership car.
	local uid = ctx.options.uid
	if uid == nil then
		local cars = catalogCars(freshSnapshot(ctx))
		uid = if #cars > 0 then cars[1].uid else nil
	end
	if uid == nil and ctx.options.buyMissing ~= false then
		uid = buyCar(ctx, nil)
	end
	if not check(ctx, "an owned catalog car to mod", uid ~= nil, tostring(uid)) or uid == nil then
		return
	end
	local carUid = uid :: string

	local car, why = spawnOwned(ctx, carUid)
	local before = if car ~= nil then shapeOf(car) else nil
	if not check(ctx, "the car comes out before the mod", before ~= nil, why or "seated") or before == nil then
		return
	end
	if car ~= nil and car:GetAttribute("DesignUid") ~= nil then
		check(ctx, "the car is a catalog car", false, "it is a player design; pass opts.uid of a catalog car")
		return
	end

	-- A refused mod costs nothing.
	local start = modPrice + 1
	if not check(ctx, `credits set to {start}`, setCredits(ctx, start), "DevCredits") then
		return
	end
	setCurrent(ctx, "a mod the fake backend refuses")
	local refusedReply, refused = request(ctx, "ModCar", { uid = carUid, prompt = refusePrompt() })
	local wasRefused = (refusedReply ~= nil and refusedReply.ok ~= true) or (refused ~= nil and not refused.ok)
	check(
		ctx,
		"the fake backend refuses the mod",
		wasRefused,
		if refused then `result: {refused.message}` else describe(refusedReply)
	)
	local afterRefusal = balanceNow(ctx)
	check(ctx, "a refused mod costs nothing", afterRefusal == start, `balance {tostring(afterRefusal)}`)

	-- A mod.
	setCurrent(ctx, "modding the car")
	local modReply, modded = request(ctx, "ModCar", { uid = carUid, prompt = SETTINGS.modPrompt })
	local done = modded ~= nil and modded.ok
	check(ctx, "the mod is made", done, if modded then `result: {modded.message}` else describe(modReply))
	if not done or modded == nil then
		return
	end
	local afterMod = balanceNow(ctx)
	check(ctx, `a mod costs {modPrice} credit(s)`, afterMod == start - modPrice, `balance {tostring(afterMod)}`)
	local spec = specOf(modded)
	if spec ~= nil then
		local touched = disallowedOnCatalog(spec)
		check(
			ctx,
			"the mod the server kept changes only what a catalog car may",
			#touched == 0,
			if #touched == 0 then "paint, stance, wheels and extras only" else table.concat(touched, ", ")
		)
	else
		note(ctx, "the DesignResult carried no mod spec, so only the car itself is compared")
	end

	-- The car brought out again wears the mod: only paint, wheels, stance and extras may differ.
	local again, againWhy = spawnOwned(ctx, carUid)
	local after = if again ~= nil then shapeOf(again) else nil
	if not check(ctx, "the car comes out after the mod", after ~= nil, againWhy or "seated") or after == nil then
		return
	end
	local changes, offset = forbiddenChanges(before, after)
	check(
		ctx,
		"the mod leaves the chassis, hubs, seats and body panels alone",
		#changes == 0,
		if #changes == 0
			then `body moved {format(offset, 2)} studs up or down as a whole`
			else table.concat(changes, "; ")
	)
	check(
		ctx,
		"nothing on the modded car takes part in physics but the chassis",
		#after.physical == 0,
		if #after.physical == 0
			then "every other part is massless and non-colliding"
			else table.concat(after.physical, ", ")
	)
	local repainted = 0
	for key, color in before.paint do
		local now = after.paint[key]
		if now ~= nil and now ~= color then
			repainted += 1
		end
	end
	note(
		ctx,
		`what the mod changed: {repainted} painted panels recoloured, look and extra parts {before.lookParts} -> `
			.. `{after.lookParts}, body moved {format(offset, 2)} studs`
	)
end

---------------------------------------------------------------------------------------------------------------
-- Running
---------------------------------------------------------------------------------------------------------------

-- Every designable class, by tier and then id.
local function designableClasses(): { string }
	local ids: { string } = {}
	for classId in kit.classes do
		table.insert(ids, classId)
	end
	table.sort(ids, function(a: string, b: string): boolean
		local tierA = if Classes[a] then Classes[a].tier else math.huge
		local tierB = if Classes[b] then Classes[b].tier else math.huge
		if tierA ~= tierB then
			return tierA < tierB
		end
		return a < b
	end)
	return ids
end

local TESTS: { [string]: (ctx: Context, ...any) -> () } = {
	design = function(ctx: Context, classId: any)
		if type(classId) ~= "string" then
			check(ctx, "a class to design", false, `design(classId) needs a class id, e.g. "sports"`)
			return
		end
		designOne(ctx, classId)
	end,
	credits = creditsTest,
	mod = modTest,
	all = function(ctx: Context)
		creditsTest(ctx)
		if cancelRequested(ctx) then
			return
		end
		modTest(ctx)
		for _, classId in ctx.options.classes or designableClasses() do
			if cancelRequested(ctx) then
				return
			end
			designOne(ctx, classId)
		end
	end,
}

local function emptyResult(name: string, reason: string): Result
	return {
		name = name,
		passed = false,
		skipped = true,
		reason = reason,
		checks = {},
		notes = {},
		runs = {},
		elapsed = 0,
	}
end

-- Why the tests can't run here, or nil when they can.
local function cannotRun(): string?
	if not (RunService:IsStudio() and RunService:IsClient() and RunService:IsRunning()) then
		return "runs only in a Studio playtest (Client datamodel)"
	end
	if Designer.devFakeBackend ~= true then
		return "Config/Designer.devFakeBackend is off, so designs would go to the real backend; these tests run only "
			.. "against the Studio fake"
	end
	if Players.LocalPlayer.Character == nil then
		return "wait for your character to spawn"
	end
	return nil
end

-- Runs one test to the end and returns its result. Refuses outside a Studio playtest client, without the fake
-- backend, or while another test runs.
local function runTest(name: string, opts: Options?, ...: any): Result
	local refusal = cannotRun()
	if refusal ~= nil then
		warn(`{LOG} {refusal}`)
		return emptyResult(name, `skipped: {refusal}`)
	end
	if script:GetAttribute(STATUS) == "running" then
		warn(`{LOG} a test is already running; DesignerTests.stop() cancels it`)
		return emptyResult(name, "skipped: another test is running")
	end

	local ctx: Context = {
		id = HttpService:GenerateGUID(false),
		name = name,
		started = os.clock(),
		result = emptyResult(name, ""),
		watch = newWatch(),
		options = opts or {},
		spawnBroken = nil,
	}
	ctx.result.skipped = false
	script:SetAttribute(RUN_ID, ctx.id)
	script:SetAttribute(STATUS, "running")
	script:SetAttribute(CANCEL, false)
	script:SetAttribute(RESULT, nil)

	local startCash = cash()
	local startBalance = balanceOf(freshSnapshot(ctx))
	local ok, err = true, nil
	if startBalance == nil then
		ctx.result.skipped = true
		ctx.result.reason = "skipped: no ProfileSnapshot came (has your data loaded?)"
		note(ctx, ctx.result.reason)
	else
		ok, err = pcall(TESTS[name], ctx, ...)
		if not ok then
			warn(`{LOG} {name} failed: {err}`)
			check(ctx, "ran to the end", false, `error: {tostring(err)}`)
		end
	end

	AutoDriver.stop()
	if ctx.options.cleanup ~= false then
		if startBalance ~= nil then
			setCredits(ctx, startBalance)
		end
		setCash(ctx, startCash)
	end
	closeWatch(ctx.watch)

	local result = ctx.result
	result.elapsed = round(os.clock() - ctx.started, 1) :: number
	local failed = failedChecks(ctx)
	result.passed = not result.skipped and #result.checks > 0 and failed == 0 and not cancelRequested(ctx)
	if result.reason == "" then
		result.reason = if cancelRequested(ctx)
			then "stopped"
			elseif result.passed then "passed"
			else `{failed} of {#result.checks} checks failed`
	end
	print(
		`{LOG} {name} TOTAL: {#result.checks - failed}/{#result.checks} checks passed, {#result.runs} designs driven, `
			.. `{format(result.elapsed, 1)} s -> {if result.passed
				then "PASS"
				elseif result.skipped then "SKIPPED"
				else "FAIL"}`
	)
	-- A newer test owns the shared status now: leave it alone.
	if script:GetAttribute(RUN_ID) == ctx.id then
		local status = if not ok
			then "failed"
			elseif cancelRequested(ctx) then "stopped"
			elseif result.skipped then "skipped"
			else "done"
		script:SetAttribute(RESULT, HttpService:JSONEncode(result))
		script:SetAttribute(CURRENT, nil)
		script:SetAttribute(STATUS, status)
	end
	return result
end

local DesignerTests = {}
DesignerTests.SETTINGS = SETTINGS

-- Designs a car of `classId` and drives it through the Phase 1 checks on the dev track.
function DesignerTests.design(classId: string, opts: Options?): Result
	return runTest("design", opts, if type(classId) == "string" then lowerFirst(classId) else classId)
end

function DesignerTests.credits(opts: Options?): Result
	return runTest("credits", opts)
end

function DesignerTests.mod(opts: Options?): Result
	return runTest("mod", opts)
end

function DesignerTests.all(opts: Options?): Result
	return runTest("all", opts)
end

-- Starts a test in the background and returns at once: start("design", classId, opts?), start("credits", opts?),
-- start("mod", opts?), start("all", opts?). Poll lastResult() (nil until it finishes) or watch the console.
function DesignerTests.start(name: TestName, ...: any)
	if TESTS[name] == nil then
		warn(`{LOG} unknown test "{name}"; use "design", "credits", "mod" or "all"`)
		return
	end
	local args = table.pack(...)
	if name == "design" then
		task.spawn(DesignerTests.design, args[1], args[2])
	else
		task.spawn(runTest, name, args[1])
	end
end

-- The last finished result, or nil while a test runs (or before any has finished).
function DesignerTests.lastResult(): Result?
	local encoded = script:GetAttribute(RESULT)
	if script:GetAttribute(STATUS) == "running" or type(encoded) ~= "string" then
		return nil
	end
	return HttpService:JSONDecode(encoded)
end

-- "idle", "running", "done", "skipped", "stopped" or "failed", and what the running test is doing now.
function DesignerTests.status(): (string, string?)
	local status = script:GetAttribute(STATUS)
	local current = script:GetAttribute(CURRENT)
	return if type(status) == "string" then status else "idle", if type(current) == "string" then current else nil
end

-- Cancels a running test after handing the controls back, and clears a "running" status left by a test whose
-- thread died.
function DesignerTests.stop()
	if not RunService:IsStudio() then
		return
	end
	script:SetAttribute(CANCEL, true)
	AutoDriver.stop()
	if script:GetAttribute(STATUS) == "running" then
		script:SetAttribute(STATUS, "stopped")
	end
end

return DesignerTests
