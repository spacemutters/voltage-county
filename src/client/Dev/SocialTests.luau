--!strict
-- Studio-only house and car-meet tests (PLAN.md Phase 13 acceptance; docs/phase-13-contracts.md "Tests"). They use
-- only what a player's client can do: Net ClaimHouse, LeaveHouse, DevSpawnVehicle, DevSetEnergy and DevSocial, the
-- HouseUpdate and FeedUpdate the server sends back, and what the server builds and publishes in the world.
-- HouseService, EnergyService and MeetService decide everything; the tests check what they did:
--   house(opts)   moves out of any house you already hold (it is claimed back at the end), walks up to the sign of the
--                 first free HousePlot (opts.plotId for another) and claims it through ClaimHouse. Checks: HouseUpdate
--                 names the plot; Workspace.Houses.<plotId> is built (every Config/Houses structure piece, the garage
--                 door and the HomeCharger pad), marked yours, with your display name on its sign; the pad is tagged
--                 for EnergyService, marked yours, and its kW is Config/Houses.chargerKW for your upgrades. Then a
--                 stand-in car that isn't yours (DevSocial parkDummyCar with the plot's id) must not charge on the pad
--                 over SETTINGS.standInWatchSeconds, and is cleared. Then your own battery car (SETTINGS.batteryCar, or
--                 opts.vehicleId / opts.trim) is spawned on the pad (DevSpawnVehicle), set to SETTINGS.startLevel
--                 (DevSetEnergy) and must start charging; the rate measured from its Energy attribute over
--                 SETTINGS.measureSeconds must match the server's ChargeRate and a ChargerStall of the pad's kW, and
--                 sit between the slowest and the fastest public stall (Config/Energy home). Then LeaveHouse:
--                 HouseUpdate says no house, the house comes down (no owner, no house pieces, your name off the sign),
--                 the car stops charging, and the plot can be claimed again from its sign (then left again).
--   meet(opts)    clears every stand-in (DevSocial clearDummies, which also resets each spot's meet and cooldown),
--                 then parks stand-ins at one MeetSpot (Config/Social dev.defaultMeetSpot, or opts.meetSpotId; a spot
--                 your car stands at is skipped) one at a time, checking DevSocial's count each time. No FeedUpdate
--                 announcing a meet there may arrive with 3 parked (SETTINGS.quietSeconds after the 3rd), one must
--                 arrive after the 4th (within SETTINGS.announceTimeout), and a 5th must not announce it again. Then it
--                 clears the stand-ins.
--   all(opts)     house, then meet
--   start(name, opts)  runs "house", "meet" or "all" in the background and returns at once; lastResult() returns
--                 its result once done (nil while it runs), status() what it's doing, stop() cancels it.
-- house and meet return a Result: { name, passed, reason, checks = { { name, passed, detail } }, notes, elapsed }
-- plus the numbers they measured; all returns { name = "all", passed, reason, results, elapsed }. Every check and
-- result is printed as it finishes, so get_console_output shows them even if execute_luau stops waiting.
--
-- Run from MCP execute_luau in the Client datamodel of a playtest, once the player's data has loaded:
--   require(game.Players.LocalPlayer.PlayerScripts.Client.Dev.SocialTests).start("all")
--   require(game.Players.LocalPlayer.PlayerScripts.Client.Dev.SocialTests).lastResult()
--
-- Nothing is left behind: the stand-ins (DevSocial clearDummies) and the test's own claim (LeaveHouse) are cleared
-- even when a test fails, errors or is stopped, and a house you held before is claimed back. What still needs
-- clearing lives in attributes on this ModuleScript (Studio gives execute_luau its own copy of each module, but the
-- ModuleScript is the same), so stop() from any copy, or the next run, sweeps up after a test whose thread died.
-- Your test car stays parked where the test left it. Remotes go through this copy's own Net (set up on first use, as
-- Dev/StoreTests does); nothing here needs AutoDriver's bridge, since no test drives.
--
-- What it relies on from the other Phase 13 parts (docs/phase-13-contracts.md):
--   * house(): DevSocial { action = "parkDummyCar", meetSpotId = <a claimed HousePlot's id> } parks a stand-in (no
--     owner, Config/Social dev.dummyAttribute) on that house's HomeCharger pad and, once EnergyService samples it,
--     lowers it below full (MeetService.parkAtHome); the test waits for that level before watching it. clearDummies
--     with no spot clears it.
--   * HouseService: Workspace.Houses.<plotId> per plot, attributes and pieces named by Config/Houses.
--
-- Does nothing outside a Studio playtest (CLAUDE.md hard rule 8); the server refuses DevSpawnVehicle, DevSetEnergy and
-- DevSocial outside Studio too. The client loader never boots it.

local CollectionService = game:GetService("CollectionService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local Catalog = require(Shared.Vehicle.Catalog)
local Economy = require(Shared.Config.Economy)
local Energy = require(Shared.Vehicle.Energy)
local EnergyConfig = require(Shared.Config.Energy)
local Houses = require(Shared.Config.Houses)
local MapLayout = require(Shared.Config.MapLayout)
local Net = require(Shared.Net)
local Social = require(Shared.Config.Social)
local Spawning = require(Shared.Config.Spawning)

export type TestName = "house" | "meet" | "all"

export type Check = { name: string, passed: boolean, detail: string }

export type Result = {
	name: string, -- "house" or "meet"
	passed: boolean, -- every check passed and the test ran to the end
	reason: string, -- "done", or why it ended early
	checks: { Check },
	notes: { string },
	elapsed: number, -- seconds
	-- house
	plotId: string?,
	vehicle: string?, -- "vehicleId/trim" charged at home
	homeRate: number?, -- % per second, measured from the car's Energy attribute
	serverRate: number?, -- % per second, the car's ChargeRate attribute
	expectedRate: number?, -- % per second for a ChargerStall of the pad's kW
	publicMinRate: number?, -- % per second at the slowest public stall (same car and level)
	publicMaxRate: number?, -- % per second at the fastest public stall
	-- meet
	meetSpotId: string?,
	announcedAt: number?, -- stand-ins parked when the meet was announced (nil: it wasn't)
	announceDelay: number?, -- seconds from parking that stand-in to the announcement
}

export type AllResult = { name: string, passed: boolean, reason: string, results: { Result }, elapsed: number }

export type Options = {
	plotId: string?, -- house: claim this HousePlot instead of the first free one
	vehicleId: string?, -- house: the battery car to charge at home (default SETTINGS.batteryCar)
	trim: string?, -- with vehicleId (default: its first trim)
	meetSpotId: string?, -- meet: use this MeetSpot (default Config/Social dev.defaultMeetSpot)
}

-- A dev tool, so its numbers live here rather than in Shared/Config (like Dev/EnergyTests' SETTINGS).
local SETTINGS = {
	-- house()
	batteryCar = { vehicleId = "ohm_spark", trim = "standard" },
	maxClaimTries = 3, -- free plots tried before giving up
	startLevel = 0.30, -- your car's level before the home charge is measured (below the taper at 80 %)
	measureSeconds = 10, -- the home charge is measured over this long
	rateTolerance = 0.15, -- measured rate vs the server's ChargeRate and the pad's kW
	standInWatchSeconds = 6, -- the stand-in on your pad is watched this long for any charging
	signStandOff = 4, -- studs in front of a plot's sign (road side) where the character stands to claim
	standHeight = 3, -- studs above the ground the character is put at
	levelTolerance = 0.0015, -- a level "reached" within this (the Energy attribute is rounded to 0.001)
	setLevelSlack = 0.02, -- a set level counts up to this above it (the pad may already be adding to it)
	-- meet()
	meetSize = 4, -- PLAN.md Phase 13 acceptance: the meet is announced at 4 parked cars and not at 3
	extraCars = 1, -- parked after the announcement, which must not announce it again
	quietSeconds = 8, -- after the 3rd stand-in, time a wrong announcement gets to arrive
	announceTimeout = 10, -- after the 4th, longest wait for the announcement
	repeatSeconds = 5, -- after the 5th, time a repeat announcement gets to arrive
	-- Gaps between calls to one remote, inside Net's rate limits (DevSocial 3 a second, ClaimHouse and LeaveHouse
	-- one every 2 s).
	parkGap = 0.5,
	claimGap = 2.1,
	-- Waiting (seconds)
	invokeTimeout = 15, -- a function remote with no reply by then counts as unanswered (its service isn't running)
	updateTimeout = 10,
	houseTimeout = 15,
	spawnTimeout = 15,
	exitTimeout = 5,
	setLevelTimeout = 10,
	chargeStartTimeout = 10,
	chargeStopTimeout = 6,
	standInTimeout = 8,
	clearTimeout = 6,
	streamTimeout = 5,
	settleSeconds = 1.5, -- after getting out, moving or sitting down, before the next step
	recheckSeconds = 0.5, -- waits also look again this often (for changes no signal reports)
	stopGraceSeconds = 3, -- stop(): time a running test gets to clean up before the sweep
}

local STATUS = "Status" -- attribute: "idle", "running", "done", "stopped" or "failed"
local CURRENT = "Current" -- attribute: what the running test is doing now
local RESULT = "Result" -- attribute: the last result, as JSON
local CANCEL = "Cancel" -- attribute: true asks a running test to stop
local RUN_ID = "RunId" -- attribute: the id of the newest run
local CLAIMED = "TestClaim" -- attribute: the plot the test holds now (released in the cleanup)
local PRIOR = "PriorClaim" -- attribute: the plot you held before (claimed back in the cleanup)
local PARKED = "StandInsOut" -- attribute: true while stand-in cars may be out (cleared in the cleanup)
local LOG = "[SocialTests]"
local PERCENT = 100
local EPSILON = 1e-6

-- Car attributes (docs/phase-5-contracts.md) and the vehicle model contract.
local ENERGY_ATTRIBUTE = "Energy"
local CHARGING_ATTRIBUTE = "Charging"
local CHARGE_RATE_ATTRIBUTE = "ChargeRate"
local OWNER_ATTRIBUTE = "OwnerUserId"
local VEHICLE_ID_ATTRIBUTE = "VehicleId"
local TRIM_ATTRIBUTE = "Trim"
local DRIVER_SEAT = "Driver"
local PUBLIC_STALL: Energy.StationKind = "ChargerStall"

type Context = { id: string, label: string, started: number, keepGoing: boolean }
type Change = { time: number, level: number }
type FeedEntry = { at: number, meet: boolean, text: string, cars: number? }
type HouseRun = {
	ctx: Context,
	result: Result,
	options: Options,
	updates: { any }, -- every HouseUpdate payload since the test began
	updated: BindableEvent,
	owned: { [string]: boolean }, -- your house upgrades, from the claim's HouseUpdate
}

local locationsById: { [string]: MapLayout.Location } = {}
local housePlots: { MapLayout.Location } = {}
local meetSpots: { MapLayout.Location } = {}
local publicStalls: { MapLayout.Location } = {}
for _, location in MapLayout.locations do
	locationsById[location.id] = location
	if location.tag == Houses.plotTag then
		table.insert(housePlots, location)
	elseif location.tag == Social.meet.spotTag then
		table.insert(meetSpots, location)
	elseif location.tag == PUBLIC_STALL then
		table.insert(publicStalls, location)
	end
end

-- Everything a claimed house is built from (Config/Houses), by part name.
local HOUSE_PIECES: { string } = {}
for _, piece in Houses.structure do
	table.insert(HOUSE_PIECES, piece.name)
end
table.insert(HOUSE_PIECES, Houses.door.name)
table.insert(HOUSE_PIECES, Houses.chargerPad.name)

---------------------------------------------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------------------------------------------

local function flat(v: Vector3): Vector3
	return Vector3.new(v.X, 0, v.Z)
end

local function round(value: number, places: number): number
	local scale = 10 ^ places
	return math.round(value * scale) / scale
end

local function showVector(v: Vector3): string
	return string.format("(%.1f, %.1f, %.1f)", v.X, v.Y, v.Z)
end

-- True when `a` is within SETTINGS.rateTolerance of `b`.
local function close(a: number, b: number): boolean
	return math.abs(a - b) <= SETTINGS.rateTolerance * math.max(math.abs(b), EPSILON)
end

-- A location's footprint frame: its centre on the ground, turned to its yaw (Config/MapLayout's convention).
local function locationFrame(location: MapLayout.Location): CFrame
	return Houses.plotFrame(location.position, location.yaw)
end

-- The way a plot faces across the ground: toward the road (Config/MapLayout: pads face their road).
local function plotFacing(plot: MapLayout.Location): Vector3
	return flat(locationFrame(plot).LookVector).Unit
end

-- True when `point` is over the footprint (`frame`, `size` in its own axes), grown by `margin`, seen from above.
local function overFootprint(frame: CFrame, size: Vector3, point: Vector3, margin: number): boolean
	local localPoint = frame:PointToObjectSpace(point)
	return math.abs(localPoint.X) <= size.X / 2 + margin and math.abs(localPoint.Z) <= size.Z / 2 + margin
end

-- Run state ----------------------------------------------------------------------------------------------------

local function cancelRequested(ctx: Context): boolean
	if ctx.keepGoing then
		return false
	end
	return script:GetAttribute(CANCEL) == true or script:GetAttribute(RUN_ID) ~= ctx.id
end

local function setCurrent(ctx: Context, text: string)
	if script:GetAttribute(RUN_ID) == ctx.id then
		script:SetAttribute(CURRENT, text)
	end
	print(`{LOG} {ctx.label}: {text}`)
end

-- A context for cleaning up: never cancelled.
local function cleanupContext(): Context
	return { id = "cleanup", label = "cleanup", started = os.clock(), keepGoing = true }
end

-- Results ------------------------------------------------------------------------------------------------------

local function newResult(name: string): Result
	return { name = name, passed = false, reason = "done", checks = {}, notes = {}, elapsed = 0 }
end

local function check(result: Result, name: string, passed: boolean, detail: string?)
	local text = detail or ""
	table.insert(result.checks, { name = name, passed = passed, detail = text })
	print(`{LOG} {result.name}: {if passed then "PASS" else "FAIL"} {name}{if text ~= "" then ` ({text})` else ""}`)
end

local function note(result: Result, text: string)
	table.insert(result.notes, text)
	print(`{LOG} {result.name}: note: {text}`)
end

-- Passed only when the test ran to the end and every one of its checks passed.
local function finishResult(result: Result, started: number): Result
	result.elapsed = os.clock() - started
	local passed = result.reason == "done" and #result.checks > 0
	for _, item in result.checks do
		passed = passed and item.passed
	end
	result.passed = passed
	local failed = 0
	for _, item in result.checks do
		if not item.passed then
			failed += 1
		end
	end
	print(
		`{LOG} {result.name}: {if passed then "PASSED" else "FAILED"} ({result.reason}; {#result.checks - failed} of `
			.. `{#result.checks} checks passed) in {math.floor(result.elapsed)} s`
	)
	local ok, encoded = pcall(HttpService.JSONEncode, HttpService, result)
	if ok then
		print(`{LOG} {result.name}: {encoded}`)
	end
	return result
end

-- Waiting ------------------------------------------------------------------------------------------------------

-- Waits until `test()` is true, looking again whenever one of `signals` fires and every SETTINGS.recheckSeconds,
-- for at most `timeout` seconds; a cancel ends the wait too. Returns whether `test()` came true.
local function waitFor(ctx: Context, test: () -> boolean, signals: { RBXScriptSignal }, timeout: number): boolean
	if test() then
		return true
	end
	if cancelRequested(ctx) then
		return false
	end
	local outcome: boolean? = nil
	local waiting: thread? = nil
	local connections: { RBXScriptConnection } = {}
	local function finish(value: boolean)
		if outcome ~= nil then
			return
		end
		outcome = value
		for _, connection in connections do
			connection:Disconnect()
		end
		local thread = waiting
		if thread ~= nil then
			task.defer(thread)
		end
	end
	local function recheck()
		if outcome == nil and test() then
			finish(true)
		end
	end
	for _, signal in signals do
		table.insert(connections, signal:Connect(recheck))
	end
	table.insert(
		connections,
		script:GetAttributeChangedSignal(CANCEL):Connect(function()
			if cancelRequested(ctx) then
				finish(false)
			end
		end)
	)
	local deadline = os.clock() + timeout
	task.spawn(function()
		while outcome == nil do
			task.wait(math.min(SETTINGS.recheckSeconds, math.max(deadline - os.clock(), 0)))
			if outcome ~= nil then
				break
			end
			if test() then
				finish(true)
			elseif os.clock() >= deadline or cancelRequested(ctx) then
				finish(false)
			end
		end
	end)
	if outcome == nil then
		waiting = coroutine.running()
		coroutine.yield()
	end
	return outcome == true
end

-- Waits `seconds`; false when the test was cancelled meanwhile.
local function pause(ctx: Context, seconds: number): boolean
	waitFor(ctx, function(): boolean
		return false
	end, {}, seconds)
	return not cancelRequested(ctx)
end

-- Remotes ------------------------------------------------------------------------------------------------------

local netReady = false

-- This copy of Net may be MCP's own (not the game's), so make sure it knows the remotes.
local function ensureNet()
	if not netReady then
		Net.setupClient()
		netReady = true
	end
end

-- Calls a function remote. Returns its reply (nil when Net refused it) and whether it answered at all within
-- SETTINGS.invokeTimeout (a remote nobody serves never answers).
local function invoke(name: string, payload: any?): (any, boolean)
	ensureNet()
	local done = false
	local reply: any = nil
	local answered = false
	local waiting: thread? = nil
	local function finish(value: any, didAnswer: boolean)
		if done then
			return
		end
		done = true
		reply, answered = value, didAnswer
		local thread = waiting
		if thread ~= nil then
			task.defer(thread)
		end
	end
	task.spawn(function()
		local ok, value = pcall(Net.invokeServer, name, payload)
		if not ok then
			warn(`{LOG} {name} failed: {value}`)
		end
		finish(if ok then value else nil, ok)
	end)
	task.delay(SETTINGS.invokeTimeout, function()
		finish(nil, false)
	end)
	if not done then
		waiting = coroutine.running()
		coroutine.yield()
	end
	return reply, answered
end

-- The phase's function remotes answer { ok, message, ... }.
local function accepted(reply: any): boolean
	return type(reply) == "table" and reply.ok == true
end

local function describe(reply: any, answered: boolean): string
	if not answered then
		return `no reply in {SETTINGS.invokeTimeout} s (is the service behind it running?)`
	elseif reply == nil then
		return "refused by Net (rate limit or payload)"
	elseif type(reply) ~= "table" then
		return tostring(reply)
	end
	return `{if reply.ok == true then "ok" else "refused"}: {tostring(reply.message)}`
end

-- The character and cars ---------------------------------------------------------------------------------------

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
		if node:IsA("Model") and node:GetAttribute(VEHICLE_ID_ATTRIBUTE) ~= nil then
			return node
		end
		node = node.Parent
	end
	return nil
end

local function carIdentity(car: Model): (string?, string?)
	local vehicleId, trim = car:GetAttribute(VEHICLE_ID_ATTRIBUTE), car:GetAttribute(TRIM_ATTRIBUTE)
	return if type(vehicleId) == "string" then vehicleId else nil, if type(trim) == "string" then trim else nil
end

local function levelOf(car: Model): number?
	local value = car:GetAttribute(ENERGY_ATTRIBUTE)
	return if type(value) == "number" then value else nil
end

local function cash(): number
	local value = Players.LocalPlayer:GetAttribute(Economy.cashAttribute)
	return if type(value) == "number" then value else 0
end

local function isMine(car: Model): boolean
	return car:GetAttribute(OWNER_ATTRIBUTE) == Players.LocalPlayer.UserId
end

-- Every car (Config/Spawning vehicle tag) whose pivot (the ground under its chassis) is over the footprint.
local function carsAt(frame: CFrame, size: Vector3, margin: number): { Model }
	local list: { Model } = {}
	for _, instance in CollectionService:GetTagged(Spawning.vehicleTag) do
		if
			instance:IsA("Model")
			and instance:IsDescendantOf(Workspace)
			and overFootprint(frame, size, instance:GetPivot().Position, margin)
		then
			table.insert(list, instance)
		end
	end
	return list
end

-- Gets the character out of any car and puts it at `at` (streaming the world in around it). Returns whether it
-- moved, and why not.
local function moveTo(ctx: Context, at: CFrame): (boolean, string?)
	local character = Players.LocalPlayer.Character
	local found = humanoidOf()
	if character == nil or found == nil then
		return false, "no character"
	end
	local humanoid: Humanoid = found
	if humanoid.SeatPart ~= nil then
		humanoid.Sit = false
		humanoid.Jump = true
		local out = waitFor(ctx, function(): boolean
			return humanoid.SeatPart == nil
		end, { humanoid:GetPropertyChangedSignal("SeatPart") }, SETTINGS.exitTimeout)
		if not out then
			return false, "couldn't get out of the car"
		end
		-- The server stands the character beside the car it left; move only after that.
		task.wait(SETTINGS.settleSeconds)
	end
	character:PivotTo(at)
	pcall(function()
		Players.LocalPlayer:RequestStreamAroundAsync(at.Position, SETTINGS.streamTimeout)
	end)
	task.wait(SETTINGS.settleSeconds)
	return true, nil
end

-- Spawns a fresh `vehicleId`/`trim` with the player in it: the character stands at `stand` (DevSpawnVehicle puts
-- the car Config/Spawning spawnOffset + half its length in front of it, facing the way it faces). Returns the car,
-- or nil and why.
local function spawnAt(ctx: Context, vehicleId: string, trim: string, stand: CFrame): (Model?, string?)
	local moved, why = moveTo(ctx, stand)
	if not moved then
		return nil, why
	end
	local found = humanoidOf()
	if found == nil then
		return nil, "no character"
	end
	local humanoid: Humanoid = found
	ensureNet()
	Net.fireServer("DevSpawnVehicle", { vehicleId = vehicleId, trim = trim })
	local seated = waitFor(ctx, function(): boolean
		local car = currentCar()
		if car == nil then
			return false
		end
		local id, trimId = carIdentity(car)
		return id == vehicleId and trimId == trim
	end, { humanoid:GetPropertyChangedSignal("SeatPart") }, SETTINGS.spawnTimeout)
	if not seated then
		return nil, `{vehicleId}/{trim} didn't spawn with you in it (is its model in ServerStorage.VehicleModels?)`
	end
	task.wait(SETTINGS.settleSeconds)
	return currentCar(), nil
end

-- Houses -------------------------------------------------------------------------------------------------------

local function housesFolder(): Instance?
	return Workspace:FindFirstChild(Houses.folderName)
end

-- Workspace.Houses.<plotId>: the plot's sign, and its house while it is claimed.
local function plotModel(plotId: string): Instance?
	local folder = housesFolder()
	return if folder then folder:FindFirstChild(plotId) else nil
end

local function ownerOf(model: Instance): number?
	local value = model:GetAttribute(Houses.plotAttributes.owner)
	return if type(value) == "number" then value else nil
end

-- How many of the house's pieces (HOUSE_PIECES) stand on the plot.
local function piecesPresent(model: Instance): number
	local count = 0
	for _, name in HOUSE_PIECES do
		if model:FindFirstChild(name, true) ~= nil then
			count += 1
		end
	end
	return count
end

local function textOf(instance: Instance): string?
	if instance:IsA("TextLabel") or instance:IsA("TextButton") or instance:IsA("TextBox") then
		return (instance :: any).Text
	end
	return nil
end

-- The text object on the plot that shows the local player's display name, or nil.
local function nameShown(model: Instance): Instance?
	local name = Players.LocalPlayer.DisplayName
	for _, descendant in model:GetDescendants() do
		local text = textOf(descendant)
		if text ~= nil and string.find(text, name, 1, true) ~= nil then
			return descendant
		end
	end
	return nil
end

-- The house's home charger pad: tagged for EnergyService (Config/Houses charger.tag), else by its name.
local function chargerPadOf(model: Instance): BasePart?
	local named: BasePart? = nil
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			if CollectionService:HasTag(descendant, Houses.charger.tag) then
				return descendant
			elseif named == nil and descendant.Name == Houses.chargerPad.name then
				named = descendant
			end
		end
	end
	return named
end

-- The plot the local player holds, as far as this client can see.
local function myPlot(): string?
	local folder = housesFolder()
	if folder == nil then
		return nil
	end
	for _, child in folder:GetChildren() do
		if ownerOf(child) == Players.LocalPlayer.UserId and locationsById[child.Name] ~= nil then
			return child.Name
		end
	end
	return nil
end

-- The HousePlot whose address a message names (LeaveHouse says which house you moved out of), or nil.
local function plotNamedIn(message: any): string?
	if type(message) ~= "string" then
		return nil
	end
	for _, plot in housePlots do
		if string.find(message, plot.displayName, 1, true) ~= nil then
			return plot.id
		end
	end
	return nil
end

-- The upgrades a HouseUpdate lists (ids, or an id -> true set), as Config/Houses' clean set.
local function ownedFrom(upgrades: any): { [string]: boolean }
	local set: { [string]: boolean } = {}
	if type(upgrades) == "table" then
		for key, value in upgrades do
			if type(value) == "string" then
				set[value] = true
			elseif value == true and type(key) == "string" then
				set[key] = true
			end
		end
	end
	return Houses.cleanUpgrades(set)
end

local function ownedText(owned: { [string]: boolean }): string
	local list = Houses.ownedList(owned)
	return if #list > 0 then table.concat(list, ", ") else "none"
end

-- Where the character stands to claim a plot: in front of its sign, on the road side, facing it (well inside
-- Config/Houses claimReach).
local function signStand(plot: MapLayout.Location): CFrame
	local board = Houses.signPosition(plot.position, plot.yaw)
	local facing = plotFacing(plot)
	local stand = Vector3.new(board.X, plot.position.Y, board.Z)
		+ facing * SETTINGS.signStandOff
		+ Vector3.yAxis * SETTINGS.standHeight
	return CFrame.lookAt(stand, stand - facing)
end

-- Where the character stands so DevSpawnVehicle puts the car on the pad's centre, along its long side, nose in
-- (away from the road): the character stands on the road side of it, facing the garage.
local function spawnStand(plot: MapLayout.Location, pad: BasePart, vehicleId: string, trim: string): CFrame?
	local geometry = Catalog.geometry(vehicleId, trim)
	if geometry == nil then
		return nil
	end
	local facing = plotFacing(plot)
	local axis = flat(if pad.Size.X > pad.Size.Z then pad.CFrame.RightVector else pad.CFrame.LookVector)
	if axis.Magnitude < EPSILON then
		axis = facing
	end
	local towardRoad = if axis.Unit:Dot(facing) >= 0 then axis.Unit else -axis.Unit
	local centre = Vector3.new(pad.Position.X, plot.position.Y, pad.Position.Z)
	local stand = centre
		+ towardRoad * (Spawning.spawnOffset + geometry.length / 2)
		+ Vector3.yAxis * SETTINGS.standHeight
	return CFrame.lookAt(stand, stand - towardRoad)
end

-- Signals worth looking again on while a house is built or taken down.
local function houseSignals(): { RBXScriptSignal }
	local signals: { RBXScriptSignal } = { Workspace.ChildAdded }
	local folder = housesFolder()
	if folder ~= nil then
		table.insert(signals, folder.DescendantAdded)
		table.insert(signals, folder.DescendantRemoving)
	end
	return signals
end

-- The slowest and the fastest public charging stall's rate for this car at `level` (fraction per second).
local function publicRange(vehicleId: string, trim: string, level: number): (number, number)
	local slowest, fastest = math.huge, 0
	for _, stall in publicStalls do
		local rate = Energy.chargeRatePerSecond(PUBLIC_STALL, stall.attributes, vehicleId, trim, level)
		slowest = math.min(slowest, rate)
		fastest = math.max(fastest, rate)
	end
	return slowest, fastest
end

---------------------------------------------------------------------------------------------------------------
-- Cleaning up
---------------------------------------------------------------------------------------------------------------

-- Clears whatever a test left out, from this ModuleScript's attributes (each is cleared before it is acted on, so
-- two sweeps never do the same thing twice): the stand-in cars, the test's own claim, and the claim back on the
-- house you held before. Returns what it did, for the result's notes.
local function sweepLeftovers(): { string }
	local done: { string } = {}
	if script:GetAttribute(PARKED) == true then
		script:SetAttribute(PARKED, nil)
		local reply, answered = invoke("DevSocial", { action = "clearDummies" })
		table.insert(done, `cleanup: cleared the stand-in cars ({describe(reply, answered)})`)
	end
	local claimed = script:GetAttribute(CLAIMED)
	if type(claimed) == "string" then
		script:SetAttribute(CLAIMED, nil)
		task.wait(SETTINGS.claimGap)
		local reply, answered = invoke("LeaveHouse")
		table.insert(done, `cleanup: moved out of the test's house at {claimed} ({describe(reply, answered)})`)
	end
	local prior = script:GetAttribute(PRIOR)
	if type(prior) == "string" then
		script:SetAttribute(PRIOR, nil)
		local plot = locationsById[prior]
		local reply: any = nil
		local answered = false
		if plot ~= nil then
			moveTo(cleanupContext(), signStand(plot))
			task.wait(SETTINGS.claimGap)
			reply, answered = invoke("ClaimHouse", { plotId = prior })
		end
		table.insert(
			done,
			if accepted(reply)
				then `cleanup: claimed your house at {prior} back`
				else `cleanup: couldn't claim your house at {prior} back ({describe(reply, answered)}); claim it at its sign`
		)
	end
	for _, text in done do
		print(`{LOG} {text}`)
	end
	return done
end

---------------------------------------------------------------------------------------------------------------
-- house
---------------------------------------------------------------------------------------------------------------

-- The first HouseUpdate after the `since`-th that `predicate` accepts, waiting up to SETTINGS.updateTimeout.
local function waitUpdate(run: HouseRun, since: number, predicate: (payload: any) -> boolean): any
	local found: any = nil
	waitFor(run.ctx, function(): boolean
		for index = since + 1, #run.updates do
			if predicate(run.updates[index]) then
				found = run.updates[index]
				return true
			end
		end
		return false
	end, { run.updated.Event }, SETTINGS.updateTimeout)
	return found
end

-- Moves out of a house the player already holds (claimed back in the cleanup), so the test can claim a free one.
-- False when HouseService doesn't answer at all.
local function moveOutFirst(run: HouseRun): boolean
	local result, ctx = run.result, run.ctx
	setCurrent(ctx, "moving out of any house you hold")
	local visible = myPlot()
	local reply, answered = invoke("LeaveHouse")
	if not answered then
		check(result, "HouseService answers LeaveHouse", false, describe(reply, answered))
		result.reason = "HouseService didn't answer"
		return false
	end
	if accepted(reply) then
		local named = if type(reply.plotId) == "string" then reply.plotId else plotNamedIn(reply.message)
		local prior = visible or named
		if prior ~= nil then
			script:SetAttribute(PRIOR, prior)
			note(result, `you lived at {prior}: moved out for the test, claimed back at the end`)
		else
			note(result, "you had a house (this client couldn't tell which): moved out for the test, not claimed back")
		end
		pause(ctx, SETTINGS.claimGap)
	end
	return true
end

-- Walks up to the sign of a free plot and claims it. Returns the plot, or nil.
local function claimFree(run: HouseRun): MapLayout.Location?
	local result, ctx = run.result, run.ctx
	local candidates: { MapLayout.Location } = {}
	if run.options.plotId ~= nil then
		local location = locationsById[run.options.plotId]
		if location == nil or location.tag ~= Houses.plotTag then
			check(
				result,
				"ClaimHouse claims a free plot",
				false,
				`no HousePlot "{run.options.plotId}" in Config/MapLayout`
			)
			return nil
		end
		table.insert(candidates, location)
	else
		for _, plot in housePlots do
			local model = plotModel(plot.id)
			if model == nil or ownerOf(model) == nil then
				table.insert(candidates, plot)
			end
		end
	end

	local refusals: { string } = {}
	for index, plot in candidates do
		if index > SETTINGS.maxClaimTries or cancelRequested(ctx) then
			break
		end
		setCurrent(ctx, `walking up to the sign of {plot.displayName} ({plot.id})`)
		local moved, why = moveTo(ctx, signStand(plot))
		if not moved then
			check(result, "ClaimHouse claims a free plot", false, why or "couldn't move the character")
			return nil
		end
		if index > 1 and not pause(ctx, SETTINGS.claimGap) then
			return nil
		end
		local since = #run.updates
		local reply, answered = invoke("ClaimHouse", { plotId = plot.id })
		if accepted(reply) then
			script:SetAttribute(CLAIMED, plot.id)
			result.plotId = plot.id
			check(result, "ClaimHouse claims a free plot", true, `{plot.id}: {describe(reply, answered)}`)
			local update = waitUpdate(run, since, function(payload: any): boolean
				return type(payload) == "table" and payload.plotId == plot.id
			end)
			check(
				result,
				"HouseUpdate names the claimed plot",
				update ~= nil,
				if update ~= nil then `address {tostring(update.address)}` else `none in {SETTINGS.updateTimeout} s`
			)
			if update ~= nil then
				run.owned = ownedFrom(update.upgrades)
				note(result, `your house upgrades: {ownedText(run.owned)}`)
			end
			return plot
		end
		table.insert(refusals, `{plot.id}: {describe(reply, answered)}`)
		if not answered then
			break
		end
	end
	check(
		result,
		"ClaimHouse claims a free plot",
		false,
		if #refusals > 0 then table.concat(refusals, "; ") else "no free HousePlot in view"
	)
	return nil
end

-- The house on the claimed plot: built, yours, your name on the sign. Returns the plot's model, or nil.
local function checkHouse(run: HouseRun, plot: MapLayout.Location): Instance?
	local result, ctx = run.result, run.ctx
	local userId = Players.LocalPlayer.UserId
	setCurrent(ctx, "waiting for the house to be built")
	waitFor(ctx, function(): boolean
		local model = plotModel(plot.id)
		return model ~= nil
			and ownerOf(model) == userId
			and piecesPresent(model) == #HOUSE_PIECES
			and nameShown(model) ~= nil
	end, houseSignals(), SETTINGS.houseTimeout)
	local model = plotModel(plot.id)
	check(
		result,
		"the house appears under Workspace.Houses",
		model ~= nil,
		if model ~= nil then model:GetFullName() else `no Workspace.{Houses.folderName}.{plot.id}`
	)
	if model == nil then
		return nil
	end
	local present = piecesPresent(model)
	check(
		result,
		"the house is built (walls, roof, garage, door, charger)",
		present == #HOUSE_PIECES,
		`{present} of {#HOUSE_PIECES} pieces`
	)
	local owner = ownerOf(model)
	check(result, "the plot is marked yours", owner == userId, `{Houses.plotAttributes.owner} {tostring(owner)}`)
	local shown = nameShown(model)
	check(
		result,
		"the sign shows your display name",
		shown ~= nil,
		if shown ~= nil
			then `"{textOf(shown)}" on {shown:GetFullName()}`
			else `no text with "{Players.LocalPlayer.DisplayName}" on the plot`
	)
	local address = model:GetAttribute(Houses.plotAttributes.address)
	if address ~= nil and address ~= plot.displayName then
		note(result, `the plot's address reads "{tostring(address)}", Config/MapLayout says "{plot.displayName}"`)
	end
	return model
end

-- The home charger pad: there, tagged, yours, at the power your upgrades give. Returns it, or nil.
local function checkCharger(run: HouseRun, model: Instance): BasePart?
	local result = run.result
	local pad = chargerPadOf(model)
	check(
		result,
		"the garage has its home charger pad",
		pad ~= nil,
		if pad ~= nil then pad:GetFullName() else `no {Houses.chargerPad.name} part`
	)
	if pad == nil then
		return nil
	end
	check(
		result,
		"the pad is tagged for EnergyService",
		CollectionService:HasTag(pad, Houses.charger.tag),
		`tag {Houses.charger.tag}`
	)
	local owner = pad:GetAttribute(Houses.charger.ownerAttribute)
	check(
		result,
		"the pad is marked yours",
		owner == Players.LocalPlayer.UserId,
		`{Houses.charger.ownerAttribute} {tostring(owner)}`
	)
	local kW = pad:GetAttribute(Houses.charger.kWAttribute)
	local expected = Houses.chargerKW(run.owned)
	check(
		result,
		"the pad's power matches your upgrades",
		kW == expected,
		`{Houses.charger.kWAttribute} {tostring(kW)}, Config/Houses.chargerKW {expected} (upgrades: {ownedText(
			run.owned
		)})`
	)
	return pad
end

-- A stand-in car that isn't yours, parked on your pad, must not charge there.
local function standInStep(run: HouseRun, plot: MapLayout.Location, pad: BasePart)
	local result, ctx = run.result, run.ctx
	setCurrent(ctx, "parking a stand-in car (not yours) on the home charger")
	if not pause(ctx, SETTINGS.parkGap) then
		return
	end
	script:SetAttribute(PARKED, true)
	local reply, answered = invoke("DevSocial", { action = "parkDummyCar", meetSpotId = plot.id })
	check(result, "DevSocial parks a stand-in on the home charger", accepted(reply), describe(reply, answered))
	if not accepted(reply) then
		return
	end

	local vehicles = Workspace:FindFirstChild(Spawning.vehiclesFolder)
	local found: Model? = nil
	waitFor(ctx, function(): boolean
		for _, car in carsAt(pad.CFrame, pad.Size, 0) do
			if not isMine(car) then
				found = car
				return true
			end
		end
		return false
	end, if vehicles ~= nil then { vehicles.ChildAdded } else {}, SETTINGS.standInTimeout)
	local onPad = found
	check(
		result,
		"the stand-in stands on the home charger",
		onPad ~= nil,
		if onPad ~= nil then onPad:GetFullName() else `no car on the pad in {SETTINGS.standInTimeout} s`
	)
	if onPad == nil then
		return
	end
	local standIn: Model = onPad
	local owner = standIn:GetAttribute(OWNER_ATTRIBUTE)
	check(result, "the stand-in isn't your car", owner ~= Players.LocalPlayer.UserId, `OwnerUserId {tostring(owner)}`)
	-- EnergyService only starts sampling it at its next sample (full), and MeetService lowers it after that, so its
	-- Energy shows up a moment after the car does.
	setCurrent(ctx, "waiting for the stand-in's energy level")
	waitFor(ctx, function(): boolean
		local level = levelOf(standIn)
		return level ~= nil and level < EnergyConfig.charging.startBelow
	end, { standIn:GetAttributeChangedSignal(ENERGY_ATTRIBUTE) }, SETTINGS.setLevelTimeout)
	if cancelRequested(ctx) then
		return
	end
	local startLevel = levelOf(standIn)
	check(
		result,
		"the stand-in has room to charge",
		startLevel ~= nil and startLevel < EnergyConfig.charging.startBelow,
		if startLevel == nil
			then "no Energy attribute (EnergyService isn't sampling it), so not charging proves nothing"
			else `Energy {startLevel}; at or above {EnergyConfig.charging.startBelow} no car charges, so not charging `
				.. "would prove nothing"
	)

	setCurrent(ctx, `watching the stand-in for {SETTINGS.standInWatchSeconds} s`)
	local charged = standIn:GetAttribute(CHARGING_ATTRIBUTE) == true
	local highest = startLevel or 0
	local levelConnection = standIn:GetAttributeChangedSignal(ENERGY_ATTRIBUTE):Connect(function()
		local level = levelOf(standIn)
		if level ~= nil and level > highest then
			highest = level
		end
	end)
	local chargingConnection = standIn:GetAttributeChangedSignal(CHARGING_ATTRIBUTE):Connect(function()
		if standIn:GetAttribute(CHARGING_ATTRIBUTE) == true then
			charged = true
		end
	end)
	local watched = pause(ctx, SETTINGS.standInWatchSeconds)
	levelConnection:Disconnect()
	chargingConnection:Disconnect()
	if not watched then
		return
	end
	local rose = startLevel ~= nil and highest > startLevel + EPSILON
	check(
		result,
		"the stand-in doesn't charge at your home charger",
		not charged and not rose,
		`Charging {if charged then "came on" else "stayed off"}, Energy {tostring(startLevel)} -> {highest} over `
			.. `{SETTINGS.standInWatchSeconds} s`
	)

	if not pause(ctx, SETTINGS.parkGap) then
		return
	end
	local cleared, clearAnswered = invoke("DevSocial", { action = "clearDummies" })
	if accepted(cleared) then
		script:SetAttribute(PARKED, nil)
	end
	check(result, "DevSocial clears the stand-in", accepted(cleared), describe(cleared, clearAnswered))
	local gone = waitFor(ctx, function(): boolean
		return not standIn:IsDescendantOf(Workspace)
	end, { standIn.AncestryChanged }, SETTINGS.clearTimeout)
	check(result, "no stand-in left on the pad", gone, if gone then "" else standIn:GetFullName())
end

-- Your own car on your pad charges at the home rate. Returns the car (left parked on the pad), or nil.
local function ownerChargeStep(run: HouseRun, plot: MapLayout.Location, pad: BasePart): Model?
	local result, ctx = run.result, run.ctx
	local vehicleId = run.options.vehicleId or SETTINGS.batteryCar.vehicleId
	local trimId: string? = run.options.trim
	if trimId == nil then
		if run.options.vehicleId ~= nil then
			local trim = Catalog.defaultTrim(vehicleId)
			trimId = if trim then trim.id else nil
		else
			trimId = SETTINGS.batteryCar.trim
		end
	end
	if
		trimId == nil
		or Catalog.getTrim(vehicleId, trimId) == nil
		or not Energy.isCompatible(vehicleId, PUBLIC_STALL)
	then
		check(result, "a battery car to charge at home", false, `{vehicleId}/{tostring(trimId)} isn't a battery car`)
		return nil
	end
	local trim: string = trimId
	result.vehicle = `{vehicleId}/{trim}`
	local stand = spawnStand(plot, pad, vehicleId, trim)
	if stand == nil then
		check(result, "your car stands on the home charger", false, `no geometry for {result.vehicle}`)
		return nil
	end

	setCurrent(ctx, `spawning {result.vehicle} on the home charger`)
	local car, why = spawnAt(ctx, vehicleId, trim, stand)
	if car == nil then
		check(result, "your car stands on the home charger", false, why or "no car")
		return nil
	end
	local driven: Model = car
	local pivot = driven:GetPivot().Position
	check(
		result,
		"your car stands on the home charger",
		overFootprint(pad.CFrame, pad.Size, pivot, 0),
		`pivot {showVector(pivot)}, pad {showVector(pad.Position)}`
	)

	setCurrent(ctx, `setting the level to {SETTINGS.startLevel * PERCENT} %`)
	local reply, answered = invoke("DevSetEnergy", { level = SETTINGS.startLevel })
	local set = accepted(reply)
		and waitFor(ctx, function(): boolean
			local level = levelOf(driven)
			return level ~= nil
				and level >= SETTINGS.startLevel - SETTINGS.levelTolerance
				and level <= SETTINGS.startLevel + SETTINGS.setLevelSlack
		end, { driven:GetAttributeChangedSignal(ENERGY_ATTRIBUTE) }, SETTINGS.setLevelTimeout)
	check(
		result,
		"DevSetEnergy sets your car's level",
		set,
		`{describe(reply, answered)}; Energy {tostring(levelOf(driven))}`
	)
	if not set then
		return driven
	end

	setCurrent(ctx, "waiting for home charging to start")
	local started = waitFor(ctx, function(): boolean
		return driven:GetAttribute(CHARGING_ATTRIBUTE) == true
	end, { driven:GetAttributeChangedSignal(CHARGING_ATTRIBUTE) }, SETTINGS.chargeStartTimeout)
	check(
		result,
		"home charging starts for your car",
		started,
		`Charging {tostring(driven:GetAttribute(CHARGING_ATTRIBUTE))}, Energy {tostring(levelOf(driven))}`
	)
	if not started then
		return driven
	end

	-- The rate, from the first to the last change of the (rounded) level, so the rounding doesn't skew it. The cost
	-- is what the cash went down by (drive-to-earn may pay out meanwhile, so only drops count).
	local changes: { Change } = {}
	local spent = 0
	local lastCash = cash()
	local levelConnection = driven:GetAttributeChangedSignal(ENERGY_ATTRIBUTE):Connect(function()
		local level = levelOf(driven)
		if level ~= nil then
			table.insert(changes, { time = os.clock(), level = level })
		end
	end)
	local cashConnection = Players.LocalPlayer:GetAttributeChangedSignal(Economy.cashAttribute):Connect(function()
		local now = cash()
		if now < lastCash then
			spent += lastCash - now
		end
		lastCash = now
	end)
	setCurrent(ctx, `measuring the home charge for {SETTINGS.measureSeconds} s`)
	local measured = pause(ctx, SETTINGS.measureSeconds)
	levelConnection:Disconnect()
	cashConnection:Disconnect()
	if not measured then
		return driven
	end
	local first, last = changes[1], changes[#changes]
	local rose = #changes >= 2 and last.level > first.level and last.time > first.time
	check(
		result,
		"your car's level rises at the home charger",
		rose,
		`{#changes} level changes in {SETTINGS.measureSeconds} s`
	)
	if not rose then
		return driven
	end
	local rate = (last.level - first.level) / (last.time - first.time)
	local level = (first.level + last.level) / 2
	result.homeRate = round(rate * PERCENT, 4)

	local serverValue = driven:GetAttribute(CHARGE_RATE_ATTRIBUTE)
	local serverRate = if type(serverValue) == "number" then serverValue else nil
	result.serverRate = if serverRate ~= nil then round(serverRate * PERCENT, 4) else nil
	check(
		result,
		"the measured rate matches the server's ChargeRate",
		serverRate ~= nil and close(rate, serverRate),
		`measured {result.homeRate} %/s, ChargeRate {tostring(result.serverRate)} %/s`
	)

	local kWValue = pad:GetAttribute(Houses.charger.kWAttribute)
	local kW = if type(kWValue) == "number" then kWValue else Houses.chargerKW(run.owned)
	local expected = Energy.chargeRatePerSecond(PUBLIC_STALL, { kW = kW }, vehicleId, trim, level)
	result.expectedRate = round(expected * PERCENT, 4)
	check(
		result,
		`the rate is a {kW} kW charger's`,
		close(rate, expected),
		`measured {result.homeRate} %/s, expected {result.expectedRate} %/s`
	)

	local slowest, fastest = publicRange(vehicleId, trim, level)
	if slowest < math.huge then
		result.publicMinRate = round(slowest * PERCENT, 4)
		result.publicMaxRate = round(fastest * PERCENT, 4)
		local home = serverRate or rate
		check(
			result,
			"the home rate sits between the slowest and the fastest public stall",
			home > slowest + EPSILON and home < fastest - EPSILON,
			`home {round(home * PERCENT, 4)} %/s, public {result.publicMinRate}-{result.publicMaxRate} %/s`
		)
	end

	local added = last.level - first.level
	local price = pad:GetAttribute(Houses.charger.costAttribute)
	local expectedCost = if type(price) == "number"
		then `, about ${round(added * price, 0)} at ${price} a full charge`
		else ""
	note(result, `home charging cost ${spent} while measuring ({round(added * PERCENT, 1)} % added{expectedCost})`)
	return driven
end

-- Moving out: the claim goes, the house comes down, charging stops, and the plot is free for anyone again.
local function releaseStep(run: HouseRun, plot: MapLayout.Location, car: Model?)
	local result, ctx = run.result, run.ctx
	local charging = car ~= nil and car:GetAttribute(CHARGING_ATTRIBUTE) == true
	setCurrent(ctx, "moving out (LeaveHouse)")
	if not pause(ctx, SETTINGS.claimGap) then
		return
	end
	local since = #run.updates
	local reply, answered = invoke("LeaveHouse")
	local left = accepted(reply)
	if left then
		script:SetAttribute(CLAIMED, nil)
	end
	check(result, "LeaveHouse releases the claim", left, describe(reply, answered))
	if not left then
		return
	end
	local update = waitUpdate(run, since, function(payload: any): boolean
		return type(payload) == "table" and payload.plotId == nil
	end)
	check(
		result,
		"HouseUpdate says you have no house",
		update ~= nil,
		if update ~= nil then tostring(update.message) else `none in {SETTINGS.updateTimeout} s`
	)

	setCurrent(ctx, "waiting for the house to come down")
	local down = waitFor(ctx, function(): boolean
		local model = plotModel(plot.id)
		return model == nil or (ownerOf(model) == nil and piecesPresent(model) == 0 and nameShown(model) == nil)
	end, houseSignals(), SETTINGS.houseTimeout)
	local model = plotModel(plot.id)
	check(
		result,
		"the house comes down and the plot shows free",
		down,
		if model ~= nil
			then `owner {tostring(ownerOf(model))}, {piecesPresent(model)} house pieces left, your name ` .. (if nameShown(
					model
				) ~= nil
				then "still on the sign"
				else "off the sign")
			else "the plot's model is gone"
	)

	if car ~= nil and charging then
		local driven: Model = car
		local stopped = waitFor(ctx, function(): boolean
			return driven:GetAttribute(CHARGING_ATTRIBUTE) ~= true
		end, { driven:GetAttributeChangedSignal(CHARGING_ATTRIBUTE) }, SETTINGS.chargeStopTimeout)
		check(
			result,
			"home charging stops once you move out",
			stopped,
			`Charging {tostring(driven:GetAttribute(CHARGING_ATTRIBUTE))}`
		)
	end

	-- Free for anyone: claim it again from its sign (and move out again).
	setCurrent(ctx, "claiming the plot again to show it's free")
	local moved, why = moveTo(ctx, signStand(plot))
	if not moved or not pause(ctx, SETTINGS.claimGap) then
		check(result, "the plot is free again (ClaimHouse takes it)", false, why or "stopped")
		return
	end
	local again, againAnswered = invoke("ClaimHouse", { plotId = plot.id })
	local reclaimed = accepted(again)
	if reclaimed then
		script:SetAttribute(CLAIMED, plot.id)
	end
	check(result, "the plot is free again (ClaimHouse takes it)", reclaimed, describe(again, againAnswered))
	if not reclaimed or not pause(ctx, SETTINGS.claimGap) then
		return
	end
	local back, backAnswered = invoke("LeaveHouse")
	if accepted(back) then
		script:SetAttribute(CLAIMED, nil)
	end
	check(result, "moving out again releases it", accepted(back), describe(back, backAnswered))
end

local function houseSteps(run: HouseRun)
	local result, ctx = run.result, run.ctx
	if not moveOutFirst(run) then
		return
	end
	local plot = claimFree(run)
	if plot == nil then
		if not cancelRequested(ctx) then
			result.reason = "couldn't claim a plot"
		end
		return
	end
	local model = checkHouse(run, plot)
	local pad = if model ~= nil then checkCharger(run, model) else nil
	local car: Model? = nil
	if pad ~= nil and not cancelRequested(ctx) then
		standInStep(run, plot, pad)
		if not cancelRequested(ctx) then
			car = ownerChargeStep(run, plot, pad)
		end
	end
	if not cancelRequested(ctx) then
		releaseStep(run, plot, car)
	end
end

local function houseTest(ctx: Context, options: Options): Result
	local result = newResult("house")
	local started = os.clock()
	for _, text in sweepLeftovers() do
		note(result, `from an earlier run: {text}`)
	end
	ensureNet()
	local run: HouseRun = {
		ctx = ctx,
		result = result,
		options = options,
		updates = {},
		updated = Instance.new("BindableEvent"),
		owned = {},
	}
	local connection = Net.onClientEvent("HouseUpdate", function(payload: any)
		table.insert(run.updates, payload)
		run.updated:Fire()
	end)
	local ok, err = pcall(houseSteps :: any, run) -- (houseSteps returns nothing; `any` keeps the error value typed)
	if not ok then
		result.reason = `error: {tostring(err)}`
		warn(`{LOG} house failed: {err}`)
	end
	connection:Disconnect()
	run.updated:Destroy()
	for _, text in sweepLeftovers() do
		note(result, text)
	end
	if cancelRequested(ctx) and result.reason == "done" then
		result.reason = "stopped"
	end
	return finishResult(result, started)
end

---------------------------------------------------------------------------------------------------------------
-- meet
---------------------------------------------------------------------------------------------------------------

local function spotCars(spot: MapLayout.Location): { Model }
	return carsAt(locationFrame(spot), spot.size, Social.meet.footprintMargin)
end

local function standInsAt(spot: MapLayout.Location): { Model }
	local list: { Model } = {}
	for _, car in spotCars(spot) do
		if car:GetAttribute(Social.dev.dummyAttribute) == true then
			table.insert(list, car)
		end
	end
	return list
end

-- True when the local player's own car stands at the spot (it would count toward the meet).
local function myCarAt(spot: MapLayout.Location): boolean
	for _, car in spotCars(spot) do
		if isMine(car) then
			return true
		end
	end
	return false
end

-- opts.meetSpotId, else Config/Social's default meet spot, else any other one your car isn't parked at.
local function chooseSpot(options: Options): (MapLayout.Location?, string?)
	if options.meetSpotId ~= nil then
		local location = locationsById[options.meetSpotId]
		if location == nil or location.tag ~= Social.meet.spotTag then
			return nil, `no MeetSpot "{options.meetSpotId}" in Config/MapLayout`
		end
		return location, nil
	end
	local ordered: { MapLayout.Location } = {}
	local preferred = locationsById[Social.dev.defaultMeetSpot]
	if preferred ~= nil then
		table.insert(ordered, preferred)
	end
	for _, spot in meetSpots do
		if spot ~= preferred then
			table.insert(ordered, spot)
		end
	end
	for _, spot in ordered do
		if not myCarAt(spot) then
			return spot, nil
		end
	end
	return nil, "your car is parked at every meet spot: drive it away first"
end

-- A FeedUpdate announcing a meet at `spot` (FeedUpdate { id, kind, text, at, meetSpotId, cars }; the backlog a
-- joining player is sent doesn't count).
local function announcesMeet(payload: any, spot: MapLayout.Location): boolean
	return type(payload) == "table"
		and payload.backlog ~= true
		and payload.kind == Social.feed.kinds.meet
		and (payload.meetSpotId == nil or payload.meetSpotId == spot.id)
end

local function meetSteps(
	ctx: Context,
	result: Result,
	spot: MapLayout.Location,
	feed: { FeedEntry },
	fed: BindableEvent
)
	local function meets(): number
		local count = 0
		for _, entry in feed do
			if entry.meet then
				count += 1
			end
		end
		return count
	end
	local function meetAfter(skip: number): FeedEntry?
		local seen = 0
		for _, entry in feed do
			if entry.meet then
				seen += 1
				if seen > skip then
					return entry
				end
			end
		end
		return nil
	end

	setCurrent(ctx, "clearing every stand-in car")
	local cleared, clearAnswered = invoke("DevSocial", { action = "clearDummies" })
	check(result, "DevSocial clears the stand-ins first", accepted(cleared), describe(cleared, clearAnswered))
	if not accepted(cleared) then
		result.reason = "DevSocial refused"
		return
	end
	if not pause(ctx, SETTINGS.settleSeconds) then
		return
	end
	local before = meets()
	if before > 0 then
		note(result, `{before} meet announcement(s) arrived while clearing (from before the test), not counted`)
	end

	local visible = 0
	for count = 1, SETTINGS.meetSize + SETTINGS.extraCars do
		if not pause(ctx, SETTINGS.parkGap) then
			return
		end
		setCurrent(ctx, `parking stand-in {count} at {spot.displayName}`)
		script:SetAttribute(PARKED, true)
		local parkStarted = os.clock()
		local reply, answered = invoke("DevSocial", { action = "parkDummyCar", meetSpotId = spot.id })
		check(result, `DevSocial parks stand-in {count}`, accepted(reply), describe(reply, answered))
		if not accepted(reply) then
			result.reason = "couldn't park a stand-in"
			return
		end
		local counted = if type(reply.count) == "number" then reply.count else nil
		if counted ~= nil then
			check(
				result,
				`MeetService counts {count} car(s) at the spot`,
				counted == count,
				if counted > count
					then `{counted} counted: a player's car is parked there too (move it, or pick another spot)`
					else `{counted} counted`
			)
			if counted > count then
				result.reason = "the meet spot wasn't empty"
				return
			end
		end

		if count == SETTINGS.meetSize - 1 then
			setCurrent(ctx, `{count} parked: listening {SETTINGS.quietSeconds} s for a wrong announcement`)
			if not pause(ctx, SETTINGS.quietSeconds) then
				return
			end
			local early = meetAfter(before)
			check(
				result,
				`no meet announced with {count} cars parked`,
				early == nil,
				if early ~= nil then `"{early.text}"` else `nothing in {SETTINGS.quietSeconds} s`
			)
		elseif count == SETTINGS.meetSize then
			setCurrent(ctx, "waiting for the meet announcement")
			local came = waitFor(ctx, function(): boolean
				return meets() > before
			end, { fed.Event }, SETTINGS.announceTimeout)
			local entry = meetAfter(before)
			if came and entry ~= nil then
				result.announcedAt = count
				result.announceDelay = round(math.max(entry.at - parkStarted, 0), 2)
			end
			check(
				result,
				`the meet is announced with {count} cars parked`,
				came and entry ~= nil,
				if entry ~= nil
					then `"{entry.text}" after {result.announceDelay} s`
					else `no FeedUpdate for a meet in {SETTINGS.announceTimeout} s`
			)
		elseif count > SETTINGS.meetSize then
			setCurrent(ctx, `{count} parked: listening {SETTINGS.repeatSeconds} s for a repeat announcement`)
			if not pause(ctx, SETTINGS.repeatSeconds) then
				return
			end
			check(
				result,
				`announced once (nothing new with {count} cars parked)`,
				meets() == before + 1,
				`{meets() - before} announcement(s) in all`
			)
		end
		visible = math.max(visible, #standInsAt(spot))
	end

	if not pause(ctx, SETTINGS.parkGap) then
		return
	end
	setCurrent(ctx, "clearing the stand-in cars")
	local done, doneAnswered = invoke("DevSocial", { action = "clearDummies" })
	if accepted(done) then
		script:SetAttribute(PARKED, nil)
	end
	check(result, "DevSocial clears the stand-ins afterwards", accepted(done), describe(done, doneAnswered))
	if visible > 0 then
		local gone = waitFor(ctx, function(): boolean
			return #standInsAt(spot) == 0
		end, {}, SETTINGS.clearTimeout)
		check(result, "no stand-in left at the spot", gone, `{#standInsAt(spot)} still there`)
	else
		note(
			result,
			`the stand-ins at {spot.displayName} weren't in view (streaming), so their removal is checked by `
				.. "DevSocial's reply only"
		)
	end
end

local function meetTest(ctx: Context, options: Options): Result
	local result = newResult("meet")
	local started = os.clock()
	for _, text in sweepLeftovers() do
		note(result, `from an earlier run: {text}`)
	end
	ensureNet()
	local spot, why = chooseSpot(options)
	if spot == nil then
		result.reason = why or "no meet spot"
		return finishResult(result, started)
	end
	local chosen: MapLayout.Location = spot
	result.meetSpotId = chosen.id
	local feed: { FeedEntry } = {}
	local fed = Instance.new("BindableEvent")
	local connection = Net.onClientEvent("FeedUpdate", function(payload: any)
		if type(payload) ~= "table" or payload.backlog == true then
			return
		end
		table.insert(feed, {
			at = os.clock(),
			meet = announcesMeet(payload, chosen),
			text = tostring(payload.text),
			cars = if type(payload.cars) == "number" then payload.cars else nil,
		})
		fed:Fire()
	end)
	local ok, err = pcall(meetSteps :: any, ctx, result, chosen, feed, fed) -- (as in houseTest)
	if not ok then
		result.reason = `error: {tostring(err)}`
		warn(`{LOG} meet failed: {err}`)
	end
	connection:Disconnect()
	fed:Destroy()
	for _, text in sweepLeftovers() do
		note(result, text)
	end
	if cancelRequested(ctx) and result.reason == "done" then
		result.reason = "stopped"
	end
	return finishResult(result, started)
end

---------------------------------------------------------------------------------------------------------------
-- Running
---------------------------------------------------------------------------------------------------------------

-- Why a test can't start now, or nil.
local function refusal(): string?
	if not (RunService:IsStudio() and RunService:IsRunning() and RunService:IsClient()) then
		return "studio only"
	elseif script:GetAttribute(STATUS) == "running" then
		return "busy"
	end
	return nil
end

local function refusedResult(name: string, reason: string): Result
	local why = if reason == "busy"
		then "a test is already running; SocialTests.stop() cancels it"
		else "runs only in a Studio playtest (Client datamodel)"
	warn(`{LOG} {name}: {why}`)
	local result = newResult(name)
	result.reason = reason
	return result
end

local function openRun(label: string): Context
	local ctx: Context =
		{ id = HttpService:GenerateGUID(false), label = label, started = os.clock(), keepGoing = false }
	script:SetAttribute(RUN_ID, ctx.id)
	script:SetAttribute(STATUS, "running")
	script:SetAttribute(CANCEL, false)
	script:SetAttribute(RESULT, nil)
	return ctx
end

local function closeRun(ctx: Context, passed: boolean, payload: any)
	if script:GetAttribute(RUN_ID) ~= ctx.id then
		return
	end
	local status = if script:GetAttribute(CANCEL) == true then "stopped" elseif passed then "done" else "failed"
	local ok, encoded = pcall(HttpService.JSONEncode, HttpService, payload)
	script:SetAttribute(RESULT, if ok then encoded else nil)
	script:SetAttribute(CURRENT, nil)
	script:SetAttribute(STATUS, status)
end

local SocialTests = {}
SocialTests.SETTINGS = SETTINGS

-- Claims a free plot, checks the house, the home charger (yours charges, a stand-in doesn't) and moving out.
function SocialTests.house(opts: Options?): Result
	local refused = refusal()
	if refused ~= nil then
		return refusedResult("house", refused)
	end
	local ctx = openRun("house")
	local result = houseTest(ctx, opts or {})
	closeRun(ctx, result.passed, result)
	return result
end

-- Parks stand-ins at a meet spot one by one: announced at the 4th, not at the 3rd, and only once.
function SocialTests.meet(opts: Options?): Result
	local refused = refusal()
	if refused ~= nil then
		return refusedResult("meet", refused)
	end
	local ctx = openRun("meet")
	local result = meetTest(ctx, opts or {})
	closeRun(ctx, result.passed, result)
	return result
end

-- house, then meet.
function SocialTests.all(opts: Options?): AllResult
	local refused = refusal()
	if refused ~= nil then
		local results = { refusedResult("house", refused), refusedResult("meet", refused) }
		return { name = "all", passed = false, reason = refused, results = results, elapsed = 0 }
	end
	local ctx = openRun("all")
	local options = opts or {}
	local results: { Result } = { houseTest(ctx, options) }
	if not cancelRequested(ctx) then
		table.insert(results, meetTest(ctx, options))
	end
	local passed = #results == 2
	for _, result in results do
		passed = passed and result.passed
	end
	local summary: AllResult = {
		name = "all",
		passed = passed,
		reason = if cancelRequested(ctx) then "stopped" else "done",
		results = results,
		elapsed = os.clock() - ctx.started,
	}
	print(`{LOG} all: {if passed then "PASSED" else "FAILED"} in {math.floor(summary.elapsed)} s`)
	closeRun(ctx, passed, summary)
	return summary
end

local STARTERS: { [string]: (opts: Options?) -> any } = {
	house = SocialTests.house,
	meet = SocialTests.meet,
	all = SocialTests.all,
}

-- Starts "house", "meet" or "all" in the background and returns at once. Poll lastResult() or watch the console.
function SocialTests.start(name: TestName, opts: Options?)
	local starter = STARTERS[name]
	if starter == nil then
		warn(`{LOG} unknown test "{name}"; use "house", "meet" or "all"`)
		return
	end
	task.spawn(starter, opts)
end

-- The last finished Result (or AllResult for all), or nil while a test runs (or before any has finished).
function SocialTests.lastResult(): any
	local encoded = script:GetAttribute(RESULT)
	if script:GetAttribute(STATUS) == "running" or type(encoded) ~= "string" then
		return nil
	end
	return HttpService:JSONDecode(encoded)
end

-- "idle", "running", "done", "stopped" or "failed", and what the running test is doing.
function SocialTests.status(): (string, string?)
	local status = script:GetAttribute(STATUS)
	local current = script:GetAttribute(CURRENT)
	return if type(status) == "string" then status else "idle", if type(current) == "string" then current else nil
end

-- Cancels a running test (it cleans up after itself). A moment later it sweeps up anything still left out (a test
-- whose thread died can't) and clears a "running" status that nothing will finish.
function SocialTests.stop()
	if not (RunService:IsStudio() and RunService:IsClient()) then
		return
	end
	script:SetAttribute(CANCEL, true)
	task.delay(SETTINGS.stopGraceSeconds, function()
		sweepLeftovers()
		if script:GetAttribute(STATUS) == "running" then
			script:SetAttribute(STATUS, "stopped")
		end
	end)
end

return SocialTests
