--!strict
-- The Arc's thrusters on the server (PLAN.md Phase 10; docs/phase-10-contracts.md "Abilities, server").
--
--   UseAbility { ability }  (function) the caller asks for "boostHop" or "flight". decide() holds every rule: the
--            caller must sit in the Driver seat of a car they own (OwnerUserId) that AntiExploit tracks (driven,
--            not parked); its trim must have the ability (Config/Abilities.byTrim); that ability must be off
--            cooldown and no ability (nor its landing and settle) may be running on the car; the chassis must be
--            outside every NoFlyZone and, for flight, inside a FlightZone (the Config/MapLayout volumes, turned
--            to their yaw); the hop needs the server's smoothed speed (AntiExploitService.groundSpeed) of at
--            least Config boostHop.minSpeedMph. Replies { ok, message, startsAt?, endsAt?, readyAt? }.
--   the run  on success the car gets AbilityStartsAt, AbilityEndsAt (start + durationSeconds), <ability>ReadyAt
--            (start + cooldownSeconds) and then Ability. The owner's client pushes the car inside the window
--            (Controllers/AbilityController) and every client shows the plumes while Ability is set. AntiExploit
--            gets an allowance for the window, the landing and the settle (allowanceFor: the hop's speed gain and
--            the climb), and the server watches the chassis's server-side position all that time against the
--            Config bounds (watchBounds and judge): the climb, and for flight also the fall, the height over the
--            ground and, during the window only, the speed across the ground (landingBounds drops it after the
--            window, when the car may be back on its wheels). Out of bounds is an offense through
--            AntiExploitService.flag: a strike, and the car goes back to the last pose the watch passed (or, when
--            AntiExploit's limits say it couldn't have got there, AntiExploit's own last legal pose). Ability clears at
--            AbilityEndsAt (task.delay), or early (Ability first, then AbilityEndsAt moved to that moment) when the
--            driver gets out, the server moves the car or the watch catches an offense.
--   unstuck  settleSeconds after the landing the server checks the car is upright (UpVector.Y >= uprightDot) and
--            its chassis box (shrunk by unstuck.probeInset) overlaps no collidable part of Workspace.Map. If not,
--            VehicleService.resetCar puts it in the right-hand lane of the nearest road (roadPose; reason
--            "unstuck") and the player is told. A car is never left inside geometry or on its roof.
--   cooldown kept on the server by UserId until it runs out, so neither despawning the car nor leaving and
--            rejoining clears it, and mirrored on the car's <ability>ReadyAt attributes, also on a car the player
--            spawns later.
--   DevAbility { action = "resetCooldowns" }  (function) Studio only: clears the caller's cooldowns.
--
-- Server-authoritative (CLAUDE.md hard rule 1): the client only names the ability. No polling: one Heartbeat
-- connection, alive only while some car's ability is being watched, samples every Config watch.sampleInterval;
-- the rest is task.delay and events. A run ends when the car leaves the world or its owner leaves.
--
-- Pure helpers for tests/Ability.spec: decide, insideVolume, zonesAt, allowanceFor, watchBounds, landingBounds,
-- newWatch, judge, isUpright, rightLaneOffset and roadPose.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local Abilities = require(Shared.Config.Abilities)
local AntiExploit = require(Shared.Config.AntiExploit)
local Graph = require(Shared.Road.Graph)
local MapLayout = require(Shared.Config.MapLayout)
local Net = require(Shared.Net)
local Spawning = require(Shared.Config.Spawning)
local Units = require(Shared.Util.Units)
local World = require(Shared.Config.World)
local AntiExploitService = require(script.Parent.AntiExploitService)
local MotionGuard = require(script.Parent.AntiExploitService.MotionGuard)
local VehicleService = require(script.Parent.VehicleService)

-- What decide() looks at, gathered on the server (never taken from the client).
export type Facts = {
	hasCar: boolean, -- the caller sits in a car or has one out
	isOwner: boolean, -- its OwnerUserId is the caller's
	isDriver: boolean, -- the caller sits in its Driver seat
	tracked: boolean, -- AntiExploit tracks it: being driven, not parked
	vehicleId: string?,
	trimId: string?,
	readyAt: { [string]: number }, -- server time each ability is usable again (missing: ready)
	running: boolean, -- an ability, or its landing and settle, is still running on the car
	position: Vector3?, -- the chassis's server-side position
	speed: number?, -- the server's smoothed speed across the ground, studs/s (nil: not measured yet)
}

export type Reply = { ok: boolean, message: string, startsAt: number?, endsAt: number?, readyAt: number? }

-- What the watch holds a car to, in studs/s (maxHeight in studs over the ground). nil: not judged here.
export type Bounds = {
	maxUpSpeed: number,
	maxDownSpeed: number?,
	maxHorizontalSpeed: number?,
	maxHeight: number?,
}

-- One car's watch: the last sample that passed and the catch-up credit banked in each direction (studs).
export type Watch = {
	position: Vector3,
	time: number,
	upCredit: number,
	downCredit: number,
	horizontalCredit: number,
}

-- "ok", or what was out of bounds: climbing too fast, coming down too fast, too fast across the ground, too high.
export type Verdict = "ok" | "climb" | "fall" | "speed" | "height"

-- One ability running on a car, from its start to the settle check.
type Run = {
	model: Model,
	chassis: BasePart,
	player: Player,
	ability: string,
	bounds: Bounds, -- while the window is open
	landing: Bounds, -- after it (landingBounds)
	watch: Watch,
	-- The car's pivot at the last sample the watch passed (or where the run or a server move left it), and when
	-- (os.clock()): where an offense puts it back (AntiExploitService.flag).
	goodPose: CFrame,
	goodAt: number,
	judging: boolean, -- the watch samples this car (until the settle check, an offense, or the driver got out)
	windowOpen: boolean, -- the car's Ability attribute is set
	endTimer: thread?, -- clears Ability at AbilityEndsAt
	finishTimer: thread?, -- the settle check
	connections: { RBXScriptConnection },
}

local LOG = "[AbilityService]"
local ALLOWANCE_KEY = "ability" -- AntiExploitService.setAllowance key
local OFFENSE_VERDICT = "ability" -- AntiExploitService.flag verdict (also the VehicleReset reason)
local UNSTUCK_REASON = "unstuck" -- VehicleReset reason for the settle check's move
local RESET_COOLDOWNS = "resetCooldowns" -- the one DevAbility action
local OWNER_ATTRIBUTE = "OwnerUserId"
local VEHICLE_ID_ATTRIBUTE = "VehicleId"
local TRIM_ATTRIBUTE = "Trim"
local SEATS_FOLDER = "Seats" -- vehicle model contract
local DRIVER_SEAT = "Driver"
local MAP_FOLDER = "Map" -- Workspace.Map: the county's geometry (MapBuilder)
local PROBE_NAME = "AbilityUnstuckProbe"
local MIN_DIRECTION = 1e-3 -- horizontal vectors shorter than this (studs) have no usable direction

local messages = Abilities.messages
local attributes = Abilities.attributes

local AbilityService = {}

local runs: { [Model]: Run } = {}
-- Server time each ability is usable again, by UserId. Kept after the player leaves until every one has run out
-- (liveCooldowns drops those that have), so rejoining doesn't reset them.
local cooldowns: { [number]: { [string]: number } } = {}
local heartbeat: RBXScriptConnection? = nil
local sinceSample = 0

-- The FlightZone and NoFlyZone volumes.
local flightZones: { MapLayout.Location } = {}
local noFlyZones: { MapLayout.Location } = {}
for _, location in MapLayout.locations do
	if location.tag == Abilities.zones.flightTag then
		table.insert(flightZones, location)
	elseif location.tag == Abilities.zones.noFlyTag then
		table.insert(noFlyZones, location)
	end
end

local function isFinite(value: number): boolean
	return value == value and value > -math.huge and value < math.huge
end

local function flat(vector: Vector3): Vector3
	return Vector3.new(vector.X, 0, vector.Z)
end

local function isAbility(value: any): boolean
	return type(value) == "string" and table.find(Abilities.ids, value :: Abilities.AbilityId) ~= nil
end

-- Pure helpers ----------------------------------------------------------------------------------------------

-- Whether `position` is inside a volume location: its footprint turned to its yaw, from its surface (its
-- position.Y) up to size.Y above it.
function AbilityService.insideVolume(location: MapLayout.Location, position: Vector3): boolean
	local frame = CFrame.new(location.position) * CFrame.Angles(0, math.rad(location.yaw), 0)
	local localPoint = frame:PointToObjectSpace(position)
	local size = location.size
	return math.abs(localPoint.X) <= size.X / 2
		and math.abs(localPoint.Z) <= size.Z / 2
		and localPoint.Y >= 0
		and localPoint.Y <= size.Y
end

-- Whether `position` is inside any FlightZone, and inside any NoFlyZone.
function AbilityService.zonesAt(position: Vector3): (boolean, boolean)
	local inFlight, inNoFly = false, false
	for _, zone in flightZones do
		if AbilityService.insideVolume(zone, position) then
			inFlight = true
			break
		end
	end
	for _, zone in noFlyZones do
		if AbilityService.insideVolume(zone, position) then
			inNoFly = true
			break
		end
	end
	return inFlight, inNoFly
end

-- Whether the caller may use the ability `request.ability` now (server time), and what to tell them. Checked in
-- this order: a real ability id; a car, owned, driven from the Driver seat, not parked; the trim has the
-- ability; nothing running on the car; off cooldown; not in a no-fly zone; flight only inside a flight zone; the
-- hop only at the minimum speed. Nothing else in the request counts.
function AbilityService.decide(request: any, facts: Facts, now: number): (boolean, string)
	local ability = if type(request) == "table" then request.ability else nil
	if not isAbility(ability) then
		return false, messages.unknown
	elseif not facts.hasCar then
		return false, messages.noCar
	elseif not facts.isOwner then
		return false, messages.notOwner
	elseif not facts.isDriver then
		return false, messages.notDriver
	elseif not facts.tracked then
		return false, messages.notDriving
	end
	local vehicleId, trimId = facts.vehicleId, facts.trimId
	if vehicleId == nil or trimId == nil or not Abilities.has(vehicleId, trimId, ability) then
		return false, messages.noAbility[ability]
	elseif facts.running then
		return false, messages.busy
	end
	local readyAt = facts.readyAt[ability]
	if readyAt ~= nil and now < readyAt then
		return false, string.format(messages.recharging, math.ceil(readyAt - now))
	end
	local position = facts.position
	if position == nil then
		return false, messages.notDriving
	end
	local inFlight, inNoFly = AbilityService.zonesAt(position)
	if inNoFly then
		return false, messages.noFlyZone
	elseif ability == "flight" and not inFlight then
		return false, messages.flightZone
	elseif ability == "boostHop" then
		local speed = facts.speed
		if speed == nil or not (speed >= Units.mphToStuds(Abilities.boostHop.minSpeedMph)) then
			return false, string.format(messages.tooSlow, Abilities.boostHop.minSpeedMph)
		end
	end
	return true, messages.started[ability]
end

-- The AntiExploit allowance for an ability's window, landing and settle: the hop may add its speed gain on top
-- of the car's speed cap, and either may climb at its bound on top of what driving itself may.
function AbilityService.allowanceFor(ability: string): AntiExploitService.Allowance
	local driving = AntiExploit.verticalSpeedAllowance
	if ability == "flight" then
		return { extraSpeed = 0, riseSpeed = Abilities.bounds.flight.maxUpSpeed + driving }
	end
	local hop = Abilities.bounds.boostHop
	return { extraSpeed = hop.maxSpeedGain, riseSpeed = hop.maxUpSpeed + driving }
end

-- What the watch holds a car to for an ability, given the server's smoothed speed when it started (studs/s).
-- Both climb at most at their bound plus what driving itself may (ramps, bumps). Flight also has a fall bound, a
-- height over the ground and a speed across the ground (its bound, or the take-off speed plus headroom when that
-- was faster). The hop's speed across the ground is AntiExploit's, widened by the allowance.
function AbilityService.watchBounds(ability: string, startSpeed: number?): Bounds
	local driving = AntiExploit.verticalSpeedAllowance
	if ability == "flight" then
		local flight = Abilities.bounds.flight
		local takeOff = if startSpeed ~= nil and isFinite(startSpeed) then math.max(startSpeed, 0) else 0
		return {
			maxUpSpeed = flight.maxUpSpeed + driving,
			maxDownSpeed = flight.maxDownSpeed,
			maxHorizontalSpeed = math.max(flight.maxHorizontalSpeed, takeOff + Abilities.watch.startSpeedHeadroom),
			maxHeight = flight.maxHeight,
		}
	end
	return { maxUpSpeed = Abilities.bounds.boostHop.maxUpSpeed + driving }
end

-- The bounds after the window, through the landing and the settle: the same, but speed across the ground is
-- AntiExploit's alone again, since a car back on its wheels may drive off as fast as it can.
function AbilityService.landingBounds(bounds: Bounds): Bounds
	return {
		maxUpSpeed = bounds.maxUpSpeed,
		maxDownSpeed = bounds.maxDownSpeed,
		maxHorizontalSpeed = nil,
		maxHeight = bounds.maxHeight,
	}
end

-- A fresh watch from `position` at `time` (os.clock()), with the full catch-up credit banked.
function AbilityService.newWatch(position: Vector3, time: number, bounds: Bounds): Watch
	local catchUp = Abilities.watch.catchUpSeconds
	return {
		position = position,
		time = time,
		upCredit = bounds.maxUpSpeed * catchUp,
		downCredit = (bounds.maxDownSpeed or 0) * catchUp,
		horizontalCredit = (bounds.maxHorizontalSpeed or 0) * catchUp,
	}
end

-- Studs used in one direction against `bound` x dt plus the banked credit: whether it fits, and the credit left
-- (up to catchUpSeconds at the bound). A nil bound always fits.
local function spend(used: number, bound: number?, dt: number, credit: number): (boolean, number)
	if bound == nil then
		return true, credit
	end
	local budget = bound * dt + credit
	if used > budget then
		return false, 0
	end
	return true, math.min(bound * Abilities.watch.catchUpSeconds, budget - used)
end

-- Judges the chassis's move to `position` at `time` (os.clock()) against the watch's last sample. `height` is
-- the chassis's height over the ground there (only judged when the bounds have maxHeight). On "ok" the watch
-- moves on to this sample and keeps the credit left; otherwise it is left as it was. The measurement is for the
-- log (AntiExploitService.flag).
function AbilityService.judge(
	watch: Watch,
	position: Vector3,
	time: number,
	height: number?,
	bounds: Bounds
): (Verdict, MotionGuard.Measurement)
	local delta = position - watch.position
	local dt = time - watch.time
	local horizontal = flat(delta).Magnitude
	local rise = math.max(delta.Y, 0)
	local drop = math.max(-delta.Y, 0)
	local measured: MotionGuard.Measurement = {
		horizontal = horizontal,
		rise = rise,
		horizontalSpeed = if dt > 0 then horizontal / dt else 0,
		riseSpeed = if dt > 0 then rise / dt else 0,
		credit = 0,
	}
	-- A NaN or infinite position can only come from a forged move.
	if not isFinite(horizontal) or not isFinite(delta.Y) then
		return "speed", measured
	end
	if not (dt > 0) then
		return "ok", measured -- no time between samples: nothing to judge yet
	end

	local upFits, upCredit = spend(rise, bounds.maxUpSpeed, dt, watch.upCredit)
	if not upFits then
		return "climb", measured
	end
	local downFits, downCredit = spend(drop, bounds.maxDownSpeed, dt, watch.downCredit)
	if not downFits then
		return "fall", measured
	end
	local acrossFits, horizontalCredit = spend(horizontal, bounds.maxHorizontalSpeed, dt, watch.horizontalCredit)
	if not acrossFits then
		return "speed", measured
	end
	local maxHeight = bounds.maxHeight
	if maxHeight ~= nil and height ~= nil and not (height <= maxHeight) then
		return "height", measured
	end

	watch.position = position
	watch.time = time
	watch.upCredit = upCredit
	watch.downCredit = downCredit
	watch.horizontalCredit = horizontalCredit
	return "ok", measured
end

-- Whether a car at `cframe` (its chassis) is upright enough (Config uprightDot).
function AbilityService.isUpright(cframe: CFrame): boolean
	return cframe.UpVector.Y >= Abilities.uprightDot
end

-- Distance from a road's centre line to the middle of the lanes heading one way (studs), as the dev route tests
-- drive: a road with an odd number of lanes shares its middle lane; a one-lane road has no sides.
function AbilityService.rightLaneOffset(lanes: number, laneWidth: number): number
	local eachWay = math.floor(lanes / 2)
	if eachWay < 1 then
		return 0
	end
	return (lanes - eachWay) * laneWidth / 2
end

-- Where an unstuck car goes: in the right-hand lane of the road nearest `position`, on its surface, facing along
-- it the way closest to `heading`. nil when there is no road at all.
function AbilityService.roadPose(position: Vector3, heading: Vector3): CFrame?
	local edgeIndex, _, _, point = Graph.nearestEdge(position)
	if edgeIndex == nil then
		return nil
	end
	local edge = Graph.edges()[edgeIndex]
	local from, to = Graph.node(edge.from), Graph.node(edge.to)
	if from == nil or to == nil then
		return nil
	end
	local along = flat(to.position - from.position)
	if along.Magnitude < MIN_DIRECTION then
		return CFrame.new(point)
	end
	local forward = along.Unit
	if forward:Dot(flat(heading)) < 0 then
		forward = -forward
	end
	local right = Vector3.new(-forward.Z, 0, forward.X)
	local spot = point + right * AbilityService.rightLaneOffset(edge.lanes, World.laneWidth)
	return CFrame.lookAt(spot, spot + forward)
end

-- Helpers -----------------------------------------------------------------------------------------------------

local function serverNow(): number
	return Workspace:GetServerTimeNow()
end

local function notify(player: Player, text: string, kind: string)
	if player.Parent == Players then
		Net.fireClient("Notify", player, { text = text, kind = kind })
	end
end

-- A player's cooldowns still running at server time `now` (those that have run out are dropped), or nil when
-- none is.
local function liveCooldowns(userId: number, now: number): { [string]: number }?
	local entry = cooldowns[userId]
	if entry == nil then
		return nil
	end
	for ability, readyAt in entry do
		if readyAt <= now then
			entry[ability] = nil
		end
	end
	if next(entry) == nil then
		cooldowns[userId] = nil
		return nil
	end
	return entry
end

local function stringAttribute(model: Model, name: string): string?
	local value = model:GetAttribute(name)
	return if type(value) == "string" then value else nil
end

-- The spawned car `instance` belongs to (its nearest ancestor with the vehicle tag), or nil.
local function carAround(instance: Instance): Model?
	local current = instance.Parent
	while current ~= nil do
		if current:IsA("Model") and current:HasTag(Spawning.vehicleTag) then
			return current
		end
		current = current.Parent
	end
	return nil
end

local function driverSeatOf(model: Model): Seat?
	local seats = model:FindFirstChild(SEATS_FOLDER)
	local seat = if seats ~= nil then seats:FindFirstChild(DRIVER_SEAT) else nil
	return if seat ~= nil and seat:IsA("Seat") then seat else nil
end

-- The player's living humanoid, or nil.
local function humanoidOf(player: Player): Humanoid?
	local character = player.Character
	local humanoid = if character ~= nil then character:FindFirstChildOfClass("Humanoid") else nil
	if humanoid == nil or humanoid.Health <= 0 then
		return nil
	end
	return humanoid
end

-- decide()'s facts about the car the player sits in (or else their car out), gathered on the server.
local function gatherFacts(player: Player): (Facts, Model?)
	local humanoid = humanoidOf(player)
	local seat = if humanoid ~= nil then humanoid.SeatPart else nil
	local model = if seat ~= nil then carAround(seat) else nil
	if model == nil then
		model = VehicleService.getCar(player)
	end
	local facts: Facts = {
		hasCar = model ~= nil,
		isOwner = false,
		isDriver = false,
		tracked = false,
		vehicleId = nil,
		trimId = nil,
		readyAt = liveCooldowns(player.UserId, serverNow()) or {},
		running = false,
		position = nil,
		speed = nil,
	}
	if model == nil then
		return facts, nil
	end
	local driverSeat = driverSeatOf(model)
	local chassis = model.PrimaryPart
	facts.isOwner = model:GetAttribute(OWNER_ATTRIBUTE) == player.UserId
	facts.isDriver = humanoid ~= nil and driverSeat ~= nil and driverSeat.Occupant == humanoid
	facts.tracked = AntiExploitService.isTracked(model)
	facts.vehicleId = stringAttribute(model, VEHICLE_ID_ATTRIBUTE)
	facts.trimId = stringAttribute(model, TRIM_ATTRIBUTE)
	facts.running = runs[model] ~= nil
	facts.position = if chassis ~= nil then chassis.Position else nil
	facts.speed = AntiExploitService.groundSpeed(model)
	return facts, model
end

-- Whether the chassis box (shrunk by unstuck.probeInset) overlaps any collidable part of Workspace.Map that
-- the chassis collides with. Uses a throwaway query part for one call.
local function insideMap(chassis: BasePart): boolean
	local map = Workspace:FindFirstChild(MAP_FOLDER)
	if map == nil then
		return false
	end
	local inset = Abilities.unstuck.probeInset
	local size = chassis.Size
	local probe = Instance.new("Part")
	probe.Name = PROBE_NAME
	probe.Anchored = true
	probe.CanCollide = false
	probe.CanTouch = false
	probe.CanQuery = false
	probe.Transparency = 1
	probe.Size = Vector3.new(
		math.max(size.X - 2 * inset, inset),
		math.max(size.Y - 2 * inset, inset),
		math.max(size.Z - 2 * inset, inset)
	)
	probe.CFrame = chassis.CFrame
	probe.Parent = Workspace
	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { map }
	params.RespectCanCollide = true
	params.CollisionGroup = chassis.CollisionGroup
	local hits = Workspace:GetPartsInPart(probe, params)
	probe:Destroy()
	return #hits > 0
end

-- Runs ----------------------------------------------------------------------------------------------------------

local onHeartbeat: (dt: number) -> () -- the watch's sampler, below

-- Heartbeat runs only while some run is being watched.
local function updateHeartbeat()
	local watching = false
	for _, run in runs do
		if run.judging then
			watching = true
			break
		end
	end
	if watching then
		if heartbeat == nil then
			sinceSample = 0
			heartbeat = RunService.Heartbeat:Connect(onHeartbeat)
		end
		return
	end
	local connection = heartbeat
	if connection ~= nil then
		connection:Disconnect()
		heartbeat = nil
	end
end

local function cancelTimer(timer: thread?)
	if timer ~= nil and timer ~= coroutine.running() then
		task.cancel(timer)
	end
end

-- Clears the car's Ability: at AbilityEndsAt from the timer, or early. Early, Ability clears first (so the
-- owner's client sees it go well before the old AbilityEndsAt and stops at once, without a landing) and then
-- AbilityEndsAt moves to now, so anything that reads only the times stops pushing too.
local function endWindow(run: Run, early: boolean?)
	if not run.windowOpen then
		return
	end
	run.windowOpen = false
	local timer = run.endTimer
	run.endTimer = nil
	run.model:SetAttribute(attributes.ability, nil)
	if early then
		cancelTimer(timer)
		run.model:SetAttribute(attributes.endsAt, serverNow())
	end
end

-- Ends a run for good: the window, the timers, the listeners, the allowance and the watch.
local function stop(run: Run)
	if runs[run.model] == run then
		runs[run.model] = nil
	end
	endWindow(run, true)
	run.judging = false
	local finishTimer = run.finishTimer
	run.finishTimer = nil
	cancelTimer(finishTimer)
	for _, connection in run.connections do
		connection:Disconnect()
	end
	table.clear(run.connections)
	AntiExploitService.setAllowance(run.model, ALLOWANCE_KEY, nil)
	updateHeartbeat()
end

-- The settle check: upright and clear of the map, or moved to the nearest road and the player told.
local function settle(run: Run)
	local model, chassis = run.model, run.chassis
	if not model:IsDescendantOf(Workspace) or not chassis:IsDescendantOf(model) then
		return
	end
	local upright = AbilityService.isUpright(chassis.CFrame)
	if upright and not insideMap(chassis) then
		return
	end
	local pose = AbilityService.roadPose(chassis.Position, chassis.CFrame.LookVector)
	if pose == nil then
		warn(`{LOG} {model:GetFullName()} is stuck but there is no road to move it to`)
		return
	end
	VehicleService.resetCar(model, pose, UNSTUCK_REASON)
	notify(run.player, messages.unstuck, "info")
end

local function finish(run: Run)
	run.finishTimer = nil
	if runs[run.model] ~= run then
		return
	end
	stop(run)
	settle(run)
end

-- After an offense or a server move nothing more is judged; the settle check comes settleSeconds from now.
local function settleSoon(run: Run)
	local timer = run.finishTimer
	run.finishTimer = task.delay(Abilities.settleSeconds, finish, run)
	cancelTimer(timer)
end

-- One watch sample of a run's car. Out of bounds: the window closes, AntiExploit counts the offense (a strike,
-- and the car goes back to the last pose the watch passed), the allowance goes, and the car is settled soon.
local function sample(run: Run, clock: number)
	local chassis = run.chassis
	if not run.model:IsDescendantOf(Workspace) or not chassis:IsDescendantOf(run.model) then
		stop(run)
		return
	end
	local position = chassis.Position
	local bounds = if run.windowOpen then run.bounds else run.landing
	local height = if bounds.maxHeight ~= nil then position.Y - MapLayout.groundHeight(position.X, position.Z) else nil
	local verdict, measured = AbilityService.judge(run.watch, position, clock, height, bounds)
	if verdict == "ok" then
		run.goodPose = run.model:GetPivot()
		run.goodAt = clock
		return
	end
	run.judging = false
	endWindow(run, true)
	warn(`{LOG} {run.player.Name} ({run.player.UserId}) {run.ability} out of bounds: {verdict}`)
	-- Flag first: the offense re-baselines AntiExploit on the pose it puts the car back at, so removing the
	-- allowance after it doesn't judge the same move twice. AntiExploit's own last legal pose was judged under
	-- its much wider limits, so it may already be past the point the watch rejected: the watch's is sent instead.
	AntiExploitService.flag(run.model, OFFENSE_VERDICT, measured, run.goodPose, run.goodAt)
	AntiExploitService.setAllowance(run.model, ALLOWANCE_KEY, nil)
	settleSoon(run)
end

function onHeartbeat(dt: number)
	sinceSample += dt
	if sinceSample < Abilities.watch.sampleInterval then
		return
	end
	sinceSample = 0
	local clock = os.clock()
	-- Snapshot first: an offense changes the runs mid-pass.
	local due: { Run } = {}
	for _, run in runs do
		if run.judging then
			table.insert(due, run)
		end
	end
	for _, run in due do
		if runs[run.model] == run and run.judging then
			sample(run, clock)
		end
	end
	updateHeartbeat()
end

-- Starts an ability decide() allowed on the player's car.
local function begin(player: Player, model: Model, ability: string, startSpeed: number?): Reply
	local timing = Abilities.timing(ability) :: Abilities.Timing
	local chassis = model.PrimaryPart :: BasePart -- decide() had its position
	local startsAt = serverNow()
	local endsAt = startsAt + timing.durationSeconds
	local readyAt = startsAt + timing.cooldownSeconds

	local playerCooldowns = cooldowns[player.UserId]
	if playerCooldowns == nil then
		playerCooldowns = {}
		cooldowns[player.UserId] = playerCooldowns
	end
	(playerCooldowns :: { [string]: number })[ability] = readyAt
	model:SetAttribute(attributes.readyAt[ability], readyAt)
	-- The times first, so a client that sees Ability change already has them.
	model:SetAttribute(attributes.startsAt, startsAt)
	model:SetAttribute(attributes.endsAt, endsAt)
	model:SetAttribute(attributes.ability, ability)

	AntiExploitService.setAllowance(model, ALLOWANCE_KEY, AbilityService.allowanceFor(ability))
	local bounds = AbilityService.watchBounds(ability, startSpeed)
	local clock = os.clock()
	local run: Run = {
		model = model,
		chassis = chassis,
		player = player,
		ability = ability,
		bounds = bounds,
		landing = AbilityService.landingBounds(bounds),
		watch = AbilityService.newWatch(chassis.Position, clock, bounds),
		goodPose = model:GetPivot(),
		goodAt = clock,
		judging = true,
		windowOpen = true,
		endTimer = nil,
		finishTimer = nil,
		connections = {},
	}
	runs[model] = run

	-- The driver getting out parks the car: the push stops and there is nothing left to judge.
	local seat = driverSeatOf(model)
	local driver = humanoidOf(player)
	if seat ~= nil then
		table.insert(
			run.connections,
			seat:GetPropertyChangedSignal("Occupant"):Connect(function()
				if seat.Occupant ~= driver and run.judging then
					run.judging = false
					endWindow(run, true)
					updateHeartbeat()
				end
			end)
		)
	end
	table.insert(
		run.connections,
		model.AncestryChanged:Connect(function()
			if not model:IsDescendantOf(Workspace) then
				stop(run)
			end
		end)
	)
	run.endTimer = task.delay(timing.durationSeconds, endWindow, run)
	run.finishTimer = task.delay(timing.durationSeconds + timing.landingSeconds + Abilities.settleSeconds, finish, run)
	updateHeartbeat()
	return { ok = true, message = messages.started[ability], startsAt = startsAt, endsAt = endsAt, readyAt = readyAt }
end

-- The server moved a car (a reset, an unstuck, a dev teleport): its push stops, and the watch starts over from
-- where it is now.
local function onServerMove(model: Model)
	local run = runs[model]
	if run == nil then
		return
	end
	endWindow(run, true)
	if run.judging then
		local clock = os.clock()
		run.watch = AbilityService.newWatch(run.chassis.Position, clock, run.landing)
		run.goodPose = model:GetPivot()
		run.goodAt = clock
	end
end

-- A car the player spawns while a cooldown runs shows it too.
local function stampCooldowns(instance: Instance)
	if not instance:IsA("Model") then
		return
	end
	local ownerId = instance:GetAttribute(OWNER_ATTRIBUTE)
	local playerCooldowns = if type(ownerId) == "number" then liveCooldowns(ownerId, serverNow()) else nil
	if playerCooldowns == nil then
		return
	end
	for ability, readyAt in playerCooldowns do
		local name = attributes.readyAt[ability]
		if name ~= nil then
			instance:SetAttribute(name, readyAt)
		end
	end
end

-- A player left: their cooldowns stay until they run out (rejoining finds them), then are dropped.
local function keepCooldowns(userId: number)
	local left = liveCooldowns(userId, serverNow())
	if left == nil then
		return
	end
	local last = 0
	for _, readyAt in left do
		last = math.max(last, readyAt)
	end
	task.delay(math.max(last - serverNow(), 0), function()
		liveCooldowns(userId, serverNow())
	end)
end

-- Remotes ---------------------------------------------------------------------------------------------------

-- Net UseAbility.
function AbilityService.useAbility(player: Player, payload: any): Reply
	local facts, model = gatherFacts(player)
	local now = serverNow()
	local ok, message = AbilityService.decide(payload, facts, now)
	local ability = if type(payload) == "table" then payload.ability else nil
	if not ok or model == nil or not isAbility(ability) then
		local readyAt = if isAbility(ability) then facts.readyAt[ability] else nil
		return { ok = false, message = message, readyAt = if readyAt ~= nil and readyAt > now then readyAt else nil }
	end
	return begin(player, model, ability, facts.speed)
end

-- Net DevAbility (Studio only): clears the caller's cooldowns, on the server and on their car.
function AbilityService.devAbility(player: Player, payload: any): Reply
	if not RunService:IsStudio() then
		warn(`{LOG} DevAbility refused outside Studio ({player.Name})`)
		return { ok = false, message = messages.devOnly }
	end
	if type(payload) ~= "table" or payload.action ~= RESET_COOLDOWNS then
		return { ok = false, message = messages.unknown }
	end
	cooldowns[player.UserId] = nil
	local model = VehicleService.getCar(player)
	if model ~= nil then
		for _, name in attributes.readyAt do
			model:SetAttribute(name, nil)
		end
	end
	return { ok = true, message = messages.cooldownsReset }
end

-- Boot ------------------------------------------------------------------------------------------------------

function AbilityService:Start()
	Net.onServerInvoke("UseAbility", AbilityService.useAbility)
	-- Always listen, so the remote never queues up; the handler itself refuses outside Studio.
	Net.onServerInvoke("DevAbility", AbilityService.devAbility)
	AntiExploitService.onServerMove(onServerMove)
	CollectionService:GetInstanceAddedSignal(Spawning.vehicleTag):Connect(stampCooldowns)
	Players.PlayerRemoving:Connect(function(leaving: Player)
		keepCooldowns(leaving.UserId)
		for _, run in table.clone(runs) do
			if run.player == leaving then
				stop(run)
			end
		end
	end)
end

return AbilityService
