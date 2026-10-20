--!strict
-- Phase 10 on the client (docs/phase-10-contracts.md "Abilities, client"; PLAN.md Phase 10): the Arc's thrusters.
-- The server decides everything (Services/AbilityService: whose car, which trim, cooldowns, zones, speed); this
-- controller asks it, runs the thrusters on the car this client drives while the server's window is open, and
-- shows them.
--
--   press      Q on keyboard and L3 on gamepad (Config/Controls ability, bound only while driving a car whose trim
--              has an ability in Config/Abilities.byTrim) and the touch Boost / Fly button (HudController.onAbility)
--              send Net UseAbility, one request at a time. Which ability (pick): flight when the trim has it and
--              the car is inside a FlightZone volume (the CollectionService tag, or Config/MapLayout's volumes when
--              none has streamed in), else the boost-hop; when that one is recharging and the other is ready, the
--              other. A refusal's message ("Boost needs 20 mph", "Recharging: 12 s") shows as a notice. Presses
--              while a window or a landing runs are ignored.
--   thrusters  while workspace:GetServerTimeNow() is inside [AbilityStartsAt, AbilityEndsAt] of the window the
--              server opened (the car's Ability attributes, or the yes reply, whichever arrives first), each
--              RunService.PreSimulation adds Vehicle/Thrusters' velocity changes to the car, only on the car this
--              player drives and owns (OwnerUserId). The hop's lift and glide are timed from this client's first
--              push (hopElapsed), not from AbilityStartsAt, so ping never cuts the lift short. A hop ends once it
--              is back on its wheels after leaving the ground. After the window: the controlled landing after
--              flight (and a soft one after a hop still in the air) until Config/Thrusters.landedWheels touch or
--              Vehicle/Thrusters.landingTimeout passes (within Config/Abilities' landingSeconds). In flight steer
--              rolls and throttle / brake pitch the car, each only once it has been let go since takeoff (holding
--              the throttle into a flight never flips the car). Everything stops at once when the player leaves the
--              seat, the car goes away, the server moves it (Net VehicleReset) or clears Ability well before the
--              window ends.
--   plumes     on every client, for every car (Config/Spawning.vehicleTag) whose Ability attribute is set:
--              cold-gas ParticleEmitters at Thruster_L, Thruster_R and Thruster_Down (Config/Thrusters.plume),
--              lit from AbilityStartsAt until AbilityEndsAt or the attribute clears, and a short hiss (Config/Audio
--              sfx; nothing at all at asset 0). Removed once their last particles fade, or when the car goes away.
--   HUD        the ability chip and the touch button (HudController.setAbility): what a press does now, the ring
--              filling from <ability>ReadyAt over Config/Abilities' cooldown, and Boosting / Flying / Landing while
--              one runs. Redrawn on the car's attribute signals, and from a Heartbeat accumulator
--              (Config/Controls.hud.refreshHz) connected only while driving such a car and something changes by
--              itself: a ring filling, a window running, or the Flight Field's edge for a Flight trim.
--
-- The pure helpers (abilitiesFor, pick, insideBox, chipFor, hopElapsed, readReply) are exposed for
-- tests/Thrusters.spec; request() and active() for Dev/AbilityTests, whose input bridge this starts in Studio
-- (serve()).

local CollectionService = game:GetService("CollectionService")
local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Abilities = require(ReplicatedStorage.Shared.Config.Abilities)
local Audio = require(ReplicatedStorage.Shared.Config.Audio)
local Controls = require(ReplicatedStorage.Shared.Config.Controls)
local MapLayout = require(ReplicatedStorage.Shared.Config.MapLayout)
local Net = require(ReplicatedStorage.Shared.Net)
local Spawning = require(ReplicatedStorage.Shared.Config.Spawning)
local ThrusterConfig = require(ReplicatedStorage.Shared.Config.Thrusters)
local Thrusters = require(ReplicatedStorage.Shared.Vehicle.Thrusters)
local Tuning = require(ReplicatedStorage.Shared.Vehicle.Tuning)
local WheelVisuals = require(ReplicatedStorage.Shared.Vehicle.WheelVisuals)
local DriveController = require(script.Parent.DriveController)
local HudController = require(script.Parent.HudController)
local InputController = require(script.Parent.InputController)
local NotifyController = require(script.Parent.NotifyController)

local PhoneConfig = require(script.Parent.Parent.UI.Phone.PhoneConfig)

export type AbilityId = Thrusters.Ability
export type Chip = HudController.AbilityChip

local REMOTE_USE = "UseAbility"
local ACTION_NAME = "VoltageAbility" -- ContextActionService

-- Config/Abilities, read loosely: it is the ability-server helper's file and only the contract's names are shared.
local rules: any = Abilities
local attributeNames: any = if type(rules.attributes) == "table" then rules.attributes else {}
local zoneNames: any = if type(rules.zones) == "table" then rules.zones else {}

-- Names from docs/phase-10-contracts.md "Shared names" (as Config/Abilities lists them, when it does) and the
-- vehicle model contract (PLAN.md §6).
local ABILITY_ATTRIBUTE: string = attributeNames.ability or "Ability" -- the running ability's id, or nil
local STARTS_ATTRIBUTE: string = attributeNames.startsAt or "AbilityStartsAt" -- server times of its window
local ENDS_ATTRIBUTE: string = attributeNames.endsAt or "AbilityEndsAt"
local FLIGHT_ZONE_TAG: string = zoneNames.flightTag or "FlightZone"
local OWNER_ATTRIBUTE = "OwnerUserId"
local VEHICLE_ATTRIBUTE = "VehicleId"
local TRIM_ATTRIBUTE = "Trim"
local CHASSIS = "Chassis"
local HUB_ATTACHMENT = "WheelFL" -- its height under the chassis centre gives the car's rest height
local ABILITY_ORDER: { AbilityId } = { "boostHop", "flight" }

-- The attribute holding the server time `id` is usable again: boostHopReadyAt, flightReadyAt.
local function readyAttribute(id: AbilityId): string
	local names = attributeNames.readyAt
	local name = if type(names) == "table" then names[id] else nil
	return if type(name) == "string" then name else id .. "ReadyAt"
end

-- What chipFor needs to know about the car right now.
export type ChipFacts = {
	active: AbilityId?, -- the ability running now (its window is open, or this client is landing after it)
	landing: boolean, -- this client is landing the car after the window
	readyAt: number?, -- server time the shown ability is usable again (nil: ready)
	now: number, -- workspace:GetServerTimeNow()
	busy: boolean, -- a UseAbility request is with the server
}

-- One window of thrust on the car this client drives.
type Session = {
	car: Model,
	part: BasePart,
	ability: AbilityId,
	startsAt: number,
	endsAt: number,
	restHeight: number,
	startSpeed: number?, -- the hop's speed across the ground when its window opened, studs/s
	pushStartedAt: number?, -- server time of this client's first hop push (hopElapsed times the hop from it)
	airborne: boolean, -- every wheel has left the ground since the window opened
	landing: boolean, -- past AbilityEndsAt: the controlled landing
	armed: { steer: boolean, pitch: boolean }, -- flight input counts once let go since takeoff
	rayParams: RaycastParams,
	stopFilter: () -> (),
	connection: RBXScriptConnection?,
}

-- Plumes on one car (any player's).
type PlumeEntry = {
	connections: { RBXScriptConnection },
	emitters: { ParticleEmitter },
	showing: string?, -- "<ability>@<startsAt>" while lit
	startTask: thread?,
	stopTask: thread?,
}

local AbilityController = {}

local car: Model? = nil -- the car being driven, while it is this player's and its trim has an ability
local carAbilities: { AbilityId } = {}
local carRestHeight = ThrusterConfig.fallbackRestHeight
local carConnections: { RBXScriptConnection } = {}
local inZone = false -- the driven car is inside a FlightZone (checked only for a trim with flight)
local busy = false
local bound = false
local ticker: RBXScriptConnection? = nil
local session: Session? = nil
local finishedWindow: string? = nil -- "<ability>@<startsAt>" of the last window that ended here: never reopened
local plumes: { [Model]: PlumeEntry } = {}

-- Pure helpers ---------------------------------------------------------------------------------------------------

local function isAbility(value: any): boolean
	return value == "boostHop" or value == "flight"
end

-- The abilities a trim has (Config/Abilities.byTrim["<vehicleId>/<trimId>"]), boost-hop first; {} for none.
function AbilityController.abilitiesFor(vehicleId: any, trimId: any): { AbilityId }
	local found: { AbilityId } = {}
	if type(vehicleId) ~= "string" or type(trimId) ~= "string" then
		return found
	end
	local byTrim = rules.byTrim
	local list = if type(byTrim) == "table" then byTrim[`{vehicleId}/{trimId}`] else nil
	if type(list) ~= "table" then
		return found
	end
	for _, id in ABILITY_ORDER do
		if table.find(list, id) ~= nil then
			table.insert(found, id)
		end
	end
	return found
end

-- Which ability a press asks for: flight when the trim has it and the car is inside a FlightZone, else the
-- boost-hop; but when that one is recharging (readyAt after now) and another this car can use here is ready,
-- that one. With nothing usable here (a flight-only trim outside the field) the trim's first, so the server's
-- reply says why. nil when the trim has none.
function AbilityController.pick(
	abilities: { AbilityId },
	inFlightZone: boolean,
	readyAt: { [string]: number? },
	now: number
): AbilityId?
	local usable: { AbilityId } = {}
	if inFlightZone and table.find(abilities, "flight") ~= nil then
		table.insert(usable, "flight")
	end
	if table.find(abilities, "boostHop") ~= nil then
		table.insert(usable, "boostHop")
	end
	if #usable == 0 then
		return abilities[1]
	end
	for _, id in usable do
		local at = readyAt[id]
		if at == nil or at <= now then
			return id :: AbilityId -- the cast keeps the old type solver from widening the id to string
		end
	end
	return usable[1]
end

-- True when `point` lies inside the box of `size` centred at `frame` (a zone volume part).
function AbilityController.insideBox(frame: CFrame, size: Vector3, point: Vector3): boolean
	local offset = frame:PointToObjectSpace(point)
	return math.abs(offset.X) <= size.X / 2 and math.abs(offset.Y) <= size.Y / 2 and math.abs(offset.Z) <= size.Z / 2
end

-- Seconds an ability takes to recharge (Config/Abilities), 0 if unknown.
local function cooldownOf(id: AbilityId): number
	local rule = rules[id]
	local value = if type(rule) == "table" then rule.cooldownSeconds else nil
	return if type(value) == "number" and value > 0 then value else 0
end

-- What the ability chip and the touch button show for `shown` (the ability a press asks for, or the one running).
function AbilityController.chipFor(shown: AbilityId, facts: ChipFacts): Chip
	local text = Controls.hud.abilityChip
	local label = text.labels[shown] or shown
	if facts.active ~= nil or facts.landing then
		return {
			label = label,
			status = if facts.landing then text.landing else text.activeLabels[shown] or label,
			state = "active",
			fill = 1,
			seconds = nil,
			busy = facts.busy,
		}
	end
	local readyAt = facts.readyAt
	if readyAt ~= nil and readyAt > facts.now then
		local left = readyAt - facts.now
		local cooldown = cooldownOf(shown)
		local fill = if cooldown > 0 then math.clamp(1 - left / cooldown, 0, 1) else 0
		return {
			label = label,
			status = text.recharging,
			state = "recharging",
			fill = math.floor(fill * text.ringSteps) / text.ringSteps,
			seconds = math.ceil(left),
			busy = facts.busy,
		}
	end
	return { label = label, status = text.ready, state = "ready", fill = 1, seconds = nil, busy = facts.busy }
end

-- Seconds into the hop's push at server time `now`, timed from this client's first push (`firstPush`, nil
-- before it) rather than from AbilityStartsAt, and that first push's time. The client hears of the window a
-- network delay after the server opened it; timing the lift from the server's start would cut it short by that
-- delay (no lift at all past Config/Thrusters hop.liftSeconds of it). The window still ends at AbilityEndsAt,
-- and what is left of the arc after it lands inside the server's landing allowance.
function AbilityController.hopElapsed(firstPush: number?, now: number): (number, number)
	local started = firstPush or now
	return math.max(now - started, 0), started
end

-- A UseAbility reply: { ok, message, startsAt?, endsAt?, readyAt? }. ok is nil when there was no answer (Net turned
-- the request away: too many in a row); message is nil when the reply has no words; the times only on a yes.
function AbilityController.readReply(reply: any): (boolean?, string?, number?, number?)
	if type(reply) ~= "table" then
		return nil, nil, nil, nil
	end
	local message = reply.message
	local startsAt = reply.startsAt
	local endsAt = reply.endsAt
	return reply.ok == true,
		if type(message) == "string" and message ~= "" then message else nil,
		if type(startsAt) == "number" then startsAt else nil,
		if type(endsAt) == "number" then endsAt else nil
end

-- The car ---------------------------------------------------------------------------------------------------------

local function chassisOf(model: Model): BasePart?
	local part = model.PrimaryPart or model:FindFirstChild(CHASSIS)
	return if part ~= nil and part:IsA("BasePart") then part else nil
end

local function readyAtOf(model: Model, id: AbilityId): number?
	local value = model:GetAttribute(readyAttribute(id))
	return if type(value) == "number" then value else nil
end

-- Studs from the chassis centre down to the ground when the car stands on its wheels: the front-left hub sits
-- wheelRadius above the ground (model contract), so it is wheelRadius minus the hub's height in chassis space.
local function restHeightOf(model: Model): number
	local vehicleId = model:GetAttribute(VEHICLE_ATTRIBUTE)
	local trimId = model:GetAttribute(TRIM_ATTRIBUTE)
	local tuning = if type(vehicleId) == "string" and type(trimId) == "string"
		then Tuning.forTrim(vehicleId, trimId)
		else nil
	local chassis = chassisOf(model)
	if tuning == nil or chassis == nil then
		return ThrusterConfig.fallbackRestHeight
	end
	local hub = chassis:FindFirstChild(HUB_ATTACHMENT)
	local hubY = if hub ~= nil and hub:IsA("Attachment") then hub.Position.Y else tuning.hubs.FL.Y
	return math.max(tuning.wheelRadius - hubY, 0)
end

-- Config/MapLayout's FlightZone volumes (the map is built from it), for when no zone part has streamed in.
local layoutZones: { { frame: CFrame, size: Vector3 } }? = nil

local function layoutFlightZones(): { { frame: CFrame, size: Vector3 } }
	local cached = layoutZones
	if cached ~= nil then
		return cached
	end
	local zones: { { frame: CFrame, size: Vector3 } } = {}
	for _, location in MapLayout.locations do
		if location.tag == FLIGHT_ZONE_TAG then
			-- As MapBuilder places it: the volume's bottom face on the surface at `position`, turned by `yaw`.
			local frame = CFrame.new(location.position + Vector3.yAxis * (location.size.Y / 2))
				* CFrame.Angles(0, math.rad(location.yaw), 0)
			table.insert(zones, { frame = frame, size = location.size })
		end
	end
	layoutZones = zones
	return zones
end

-- True when `point` is inside a FlightZone. The server decides for real.
local function inFlightZone(point: Vector3): boolean
	local anyPart = false
	for _, instance in CollectionService:GetTagged(FLIGHT_ZONE_TAG) do
		if instance:IsA("BasePart") then
			anyPart = true
			if AbilityController.insideBox(instance.CFrame, instance.Size, point) then
				return true
			end
		end
	end
	if anyPart then
		return false
	end
	for _, zone in layoutFlightZones() do
		if AbilityController.insideBox(zone.frame, zone.size, point) then
			return true
		end
	end
	return false
end

local function updateZone()
	local current = car
	if current == nil or table.find(carAbilities, "flight") == nil then
		inZone = false
		return
	end
	local chassis = chassisOf(current)
	inZone = chassis ~= nil and inFlightZone(chassis.Position)
end

-- The HUD -----------------------------------------------------------------------------------------------------------

local refresh: () -> ()

-- What the chip shows now, or nil when not driving a car with an ability.
local function currentChip(now: number): Chip?
	local current = car
	if current == nil or #carAbilities == 0 then
		return nil
	end
	local readyAt: { [string]: number? } = {}
	for _, id in carAbilities do
		readyAt[id] = readyAtOf(current, id :: AbilityId)
	end
	local active: AbilityId? = nil
	local landing = false
	local running = session
	if running ~= nil and now >= running.startsAt then
		active = running.ability
		landing = running.landing
	else
		-- Another client's view lags a little: the attribute alone counts only inside its window.
		local id = current:GetAttribute(ABILITY_ATTRIBUTE)
		local endsAt = current:GetAttribute(ENDS_ATTRIBUTE)
		if isAbility(id) and (type(endsAt) ~= "number" or now <= endsAt) then
			active = id :: AbilityId
		end
	end
	local shown = active or AbilityController.pick(carAbilities, inZone, readyAt, now)
	if shown == nil then
		return nil
	end
	return AbilityController.chipFor(shown :: AbilityId, {
		active = active,
		landing = landing,
		readyAt = readyAt[shown],
		now = now,
		busy = busy,
	})
end

local function stopTicker()
	if ticker ~= nil then
		ticker:Disconnect()
		ticker = nil
	end
end

-- The redraw ticker runs only while something on the chip changes by itself.
local function updateTicker(chip: Chip?)
	local needed = chip ~= nil and (chip.state ~= "ready" or table.find(carAbilities, "flight") ~= nil)
	if not needed then
		stopTicker()
		return
	end
	if ticker ~= nil then
		return
	end
	local interval = 1 / Controls.hud.refreshHz
	local elapsed = 0
	ticker = RunService.Heartbeat:Connect(function(dt: number)
		elapsed += dt
		if elapsed >= interval then
			elapsed = 0
			refresh()
		end
	end)
end

refresh = function()
	updateZone()
	local chip = currentChip(Workspace:GetServerTimeNow())
	HudController.setAbility(chip)
	updateTicker(chip)
end

-- Thrusters on the driven car -----------------------------------------------------------------------------------

local function finishSession()
	local current = session
	if current == nil then
		return
	end
	session = nil
	finishedWindow = `{current.ability}@{current.startsAt}`
	local connection = current.connection
	if connection ~= nil then
		connection:Disconnect()
	end
	current.stopFilter()
	refresh()
end

-- The car as Vehicle/Thrusters sees it: its axes and velocities, and the ground straight below its chassis.
local function readBody(current: Session): Thrusters.Body
	local part = current.part
	local frame = part.CFrame
	local hit = Workspace:Raycast(part.Position, Vector3.new(0, -ThrusterConfig.rayLength, 0), current.rayParams)
	return {
		up = frame.UpVector,
		forward = frame.LookVector,
		linear = part.AssemblyLinearVelocity,
		angular = part.AssemblyAngularVelocity,
		gravity = Workspace.Gravity,
		groundDistance = if hit then hit.Distance else nil,
		restHeight = current.restHeight,
	}
end

-- This step's flight input. Each axis counts once it has been let go since takeoff.
local function flightInput(current: Session): Thrusters.Input
	local controls = InputController.getControls()
	local deadzone = ThrusterConfig.flight.inputDeadzone
	local armed = current.armed
	if math.abs(controls.steer) <= deadzone then
		armed.steer = true
	end
	if math.abs(controls.brake - controls.throttle) <= deadzone then
		armed.pitch = true
	end
	return {
		steer = if armed.steer then controls.steer else 0,
		throttle = if armed.pitch then controls.throttle else 0,
		brake = if armed.pitch then controls.brake else 0,
	}
end

local function stepSession(dt: number)
	local current = session
	if current == nil then
		return
	end
	local part = current.part
	if part.Parent == nil or part.Anchored or current.car ~= DriveController.getCar() then
		finishSession()
		return
	end
	local now = Workspace:GetServerTimeNow()
	if now < current.startsAt then
		return
	end
	local telemetry = DriveController.getTelemetry()
	local grounded = if telemetry ~= nil then telemetry.wheelsGrounded else 0
	if grounded == 0 then
		current.airborne = true
	end
	local landed = current.airborne and grounded >= ThrusterConfig.landedWheels
	local body = readBody(current)

	local change: Thrusters.Change
	if now <= current.endsAt then
		if current.ability == "boostHop" then
			if landed then
				finishSession() -- back on its wheels: the hop is over
				return
			end
			local startSpeed = current.startSpeed or Vector3.new(body.linear.X, 0, body.linear.Z).Magnitude
			current.startSpeed = startSpeed
			local elapsed, firstPush = AbilityController.hopElapsed(current.pushStartedAt, now)
			current.pushStartedAt = firstPush
			change = Thrusters.hopStep(dt, body, elapsed, startSpeed)
		else
			change = Thrusters.flightStep(dt, body, flightInput(current), false)
		end
	else
		if not current.landing then
			current.landing = true
			refresh()
		end
		local onWheels = grounded >= ThrusterConfig.landedWheels
		if onWheels or now - current.endsAt >= Thrusters.landingTimeout(current.ability) then
			finishSession()
			return
		end
		change = Thrusters.landingStep(dt, body, current.ability)
	end
	-- Velocity changes: the linear one as an impulse of mass x change (like Vehicle/Chassis), the angular one set
	-- directly, so both are exact at any mass.
	part:ApplyImpulse(change.linear * part.AssemblyMass)
	part.AssemblyAngularVelocity += change.angular
end

-- Opens (or updates) the thrust window `ability` [startsAt, endsAt] on the driven car.
local function beginSession(ability: AbilityId, startsAt: number, endsAt: number)
	local current = car
	if current == nil or current ~= DriveController.getCar() then
		return
	end
	local now = Workspace:GetServerTimeNow()
	if now > endsAt + Thrusters.landingTimeout(ability) or finishedWindow == `{ability}@{startsAt}` then
		return -- long over (a late attribute), or a window that already ended here (a hop back on its wheels)
	end
	local existing = session
	if existing ~= nil then
		if existing.ability == ability and existing.startsAt == startsAt then
			existing.endsAt = endsAt
			return
		end
		finishSession()
	end
	local part = chassisOf(current)
	if part == nil then
		return
	end
	local rayParams, stopFilter = WheelVisuals.trackRayFilter(current)
	local opened: Session = {
		car = current,
		part = part,
		ability = ability,
		startsAt = startsAt,
		endsAt = endsAt,
		restHeight = carRestHeight,
		startSpeed = nil,
		pushStartedAt = nil,
		airborne = false,
		landing = false,
		armed = { steer = false, pitch = false },
		rayParams = rayParams,
		stopFilter = stopFilter,
		connection = nil,
	}
	session = opened
	opened.connection = RunService.PreSimulation:Connect(stepSession)
	refresh()
end

-- Follows the driven car's Ability attributes: a window opening starts the thrusters, a clear well before its
-- end cancels them (a clear at the end leaves the landing running).
local function syncSession()
	local current = car
	if current == nil then
		return
	end
	local id = current:GetAttribute(ABILITY_ATTRIBUTE)
	local startsAt = current:GetAttribute(STARTS_ATTRIBUTE)
	local endsAt = current:GetAttribute(ENDS_ATTRIBUTE)
	if isAbility(id) and type(startsAt) == "number" and type(endsAt) == "number" then
		beginSession(id :: AbilityId, startsAt, endsAt)
		return
	end
	local running = session
	if
		running ~= nil
		and not isAbility(id)
		and Workspace:GetServerTimeNow() < running.endsAt - ThrusterConfig.cancelGraceSeconds
	then
		finishSession()
	end
end

-- Requests ----------------------------------------------------------------------------------------------------------

-- Asks the server for an ability: `ability`, or by default the one a press picks now. Yields until it answers;
-- returns whether it worked, or nil when nothing was sent (not driving a car with an ability, a request already
-- waiting, or a window or landing still running).
function AbilityController.request(ability: AbilityId?): boolean?
	local current = car
	if busy or current == nil or #carAbilities == 0 or session ~= nil then
		return nil
	end
	updateZone()
	local now = Workspace:GetServerTimeNow()
	local readyAt: { [string]: number? } = {}
	for _, id in carAbilities do
		readyAt[id] = readyAtOf(current, id :: AbilityId)
	end
	local chosen = ability or AbilityController.pick(carAbilities, inZone, readyAt, now)
	if chosen == nil then
		return nil
	end
	busy = true
	refresh()
	local called, reply = pcall(Net.invokeServer, REMOTE_USE, { ability = chosen })
	busy = false
	local ok, message, startsAt, endsAt = AbilityController.readReply(if called then reply else nil)
	if not called then
		NotifyController.show(PhoneConfig.labels.failed, "error")
	elseif ok == nil then
		NotifyController.show(PhoneConfig.labels.tryLater, "warning")
	elseif not ok then
		NotifyController.show(message or PhoneConfig.labels.failed, "warning")
	elseif startsAt ~= nil and endsAt ~= nil and car == current then
		beginSession(chosen :: AbilityId, startsAt, endsAt)
	end
	refresh()
	return ok == true
end

-- What runs on the driven car now: the ability whose window or landing is running (nil: none), and whether it is
-- the landing. For Dev/AbilityTests and the HUD.
function AbilityController.active(): (AbilityId?, boolean)
	local current = session
	if current == nil then
		return nil, false
	end
	return current.ability, current.landing
end

-- Q / L3: one request per press. Typing in the chat or a text box never fires it.
local function onAbilityInput(_name: string, state: Enum.UserInputState, _input: InputObject): Enum.ContextActionResult
	if UserInputService:GetFocusedTextBox() ~= nil then
		return Enum.ContextActionResult.Pass
	end
	if state == Enum.UserInputState.Begin then
		task.spawn(AbilityController.request)
	end
	return Enum.ContextActionResult.Sink
end

local function bindKeys()
	if bound then
		return
	end
	local keys: { Enum.KeyCode } = table.clone(Controls.keyboard.ability)
	table.move(Controls.gamepad.ability, 1, #Controls.gamepad.ability, #keys + 1, keys)
	if #keys == 0 then
		return
	end
	ContextActionService:BindActionAtPriority(
		ACTION_NAME,
		onAbilityInput,
		false,
		Controls.actionPriority,
		table.unpack(keys)
	)
	bound = true
end

local function unbindKeys()
	if bound then
		ContextActionService:UnbindAction(ACTION_NAME)
		bound = false
	end
end

-- The driven car ------------------------------------------------------------------------------------------------

local function stopWatching()
	finishSession()
	for _, connection in carConnections do
		connection:Disconnect()
	end
	table.clear(carConnections)
	unbindKeys()
	stopTicker()
	car = nil
	carAbilities = {}
	inZone = false
	busy = false
	HudController.setAbility(nil)
end

-- Starts watching a car the player now drives, if it is theirs and its trim has an ability.
local function startWatching(model: Model)
	if model:GetAttribute(OWNER_ATTRIBUTE) ~= Players.LocalPlayer.UserId then
		return
	end
	local abilities =
		AbilityController.abilitiesFor(model:GetAttribute(VEHICLE_ATTRIBUTE), model:GetAttribute(TRIM_ATTRIBUTE))
	if #abilities == 0 then
		return -- no thrusters: no key, no chip, no button
	end
	car = model
	carAbilities = abilities
	carRestHeight = restHeightOf(model)

	local function onWindowChanged()
		syncSession()
		refresh()
	end
	for _, name in { ABILITY_ATTRIBUTE, STARTS_ATTRIBUTE, ENDS_ATTRIBUTE } do
		table.insert(carConnections, model:GetAttributeChangedSignal(name):Connect(onWindowChanged))
	end
	for _, id in abilities do
		table.insert(carConnections, model:GetAttributeChangedSignal(readyAttribute(id :: AbilityId)):Connect(refresh))
	end
	bindKeys()
	syncSession()
	refresh()
end

local function onDrivingChanged(driving: boolean, model: Model?)
	stopWatching()
	if driving then
		local current = model or DriveController.getCar()
		if current ~= nil then
			startWatching(current)
		end
	end
end

-- Plumes (every car) -----------------------------------------------------------------------------------------------

local function newEmitter(attachment: Attachment, rate: number): ParticleEmitter
	local plume = ThrusterConfig.plume
	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = plume.emitterName
	emitter.Texture = plume.texture
	emitter.Color = ColorSequence.new(plume.colorStart, plume.colorEnd)
	emitter.LightEmission = plume.lightEmission
	emitter.Transparency = NumberSequence.new(plume.transparencyStart, plume.transparencyEnd)
	emitter.Size = NumberSequence.new(plume.sizeStart, plume.sizeEnd)
	emitter.Lifetime = plume.lifetime
	emitter.Speed = plume.speed
	emitter.SpreadAngle = Vector2.new(plume.spreadDegrees, plume.spreadDegrees)
	emitter.Drag = plume.drag
	-- An emitter on an attachment shoots along the attachment's look: the way a thruster's gas leaves.
	emitter.EmissionDirection = Enum.NormalId.Front
	emitter.Rate = rate
	emitter.Parent = attachment
	return emitter
end

-- The short hiss from the car's chassis (Config/Audio sfx). Nothing at all while its asset id is 0.
local function playHiss(model: Model)
	local sfx = Audio.sfx[ThrusterConfig.hissSound]
	if sfx == nil or sfx.assetId <= 0 then
		return
	end
	local chassis = chassisOf(model)
	if chassis == nil then
		return
	end
	local sound = Instance.new("Sound")
	sound.Name = ThrusterConfig.hissSound
	sound.SoundId = `rbxassetid://{sfx.assetId}`
	sound.Volume = sfx.volume
	sound.PlaybackSpeed = sfx.playbackSpeed
	sound.RollOffMaxDistance = sfx.rollOffMaxDistance
	sound.Parent = chassis
	sound.Ended:Once(function()
		sound:Destroy()
	end)
	task.delay(sfx.maxSeconds, function()
		if sound.Parent ~= nil then
			sound:Destroy()
		end
	end)
	sound:Play()
end

-- Turns a car's plumes off and removes them once their last particles fade.
local function stopPlume(entry: PlumeEntry)
	entry.showing = nil
	if #entry.emitters == 0 then
		return
	end
	local emitters = entry.emitters
	entry.emitters = {}
	for _, emitter in emitters do
		emitter.Enabled = false
	end
	task.delay(ThrusterConfig.plume.lifetime.Max, function()
		for _, emitter in emitters do
			emitter:Destroy()
		end
	end)
end

local function startPlume(model: Model, entry: PlumeEntry, ability: AbilityId, key: string)
	local plume = ThrusterConfig.plume
	local rates = plume.rates[ability]
	if rates == nil then
		return
	end
	entry.showing = key
	local function light(names: { string }, rate: number)
		for _, name in names do
			local attachment = model:FindFirstChild(name, true)
			if attachment ~= nil and attachment:IsA("Attachment") then
				table.insert(entry.emitters, newEmitter(attachment, rate))
			end
		end
	end
	light(plume.rearNozzles, rates.rear)
	light(plume.downNozzles, rates.down)
	if #entry.emitters > 0 then
		playHiss(model)
	end
end

-- Cancels a waiting delayed task (not one that is running right now: it is the caller).
local function cancelTask(thread: thread?)
	if thread ~= nil and coroutine.status(thread) == "suspended" then
		task.cancel(thread)
	end
end

local function cancelTasks(entry: PlumeEntry)
	cancelTask(entry.startTask)
	cancelTask(entry.stopTask)
	entry.startTask = nil
	entry.stopTask = nil
end

-- Lights or puts out a car's plumes from its Ability attributes: lit from AbilityStartsAt to AbilityEndsAt.
local function updatePlume(model: Model)
	local entry = plumes[model]
	if entry == nil then
		return
	end
	cancelTasks(entry)
	local id = model:GetAttribute(ABILITY_ATTRIBUTE)
	local startsAt = model:GetAttribute(STARTS_ATTRIBUTE)
	local endsAt = model:GetAttribute(ENDS_ATTRIBUTE)
	local now = Workspace:GetServerTimeNow()
	if not isAbility(id) or type(endsAt) ~= "number" or now >= endsAt then
		stopPlume(entry)
		return
	end
	local starts = if type(startsAt) == "number" then startsAt else now
	if starts > now then
		stopPlume(entry)
		entry.startTask = task.delay(starts - now, updatePlume, model)
		return
	end
	local key = `{id}@{starts}`
	if entry.showing ~= key then
		stopPlume(entry)
		startPlume(model, entry, id :: AbilityId, key)
	end
	entry.stopTask = task.delay(endsAt - now, updatePlume, model)
end

local function watchPlumes(instance: Instance)
	if not instance:IsA("Model") or plumes[instance] ~= nil then
		return
	end
	local model = instance :: Model
	local entry: PlumeEntry = { connections = {}, emitters = {}, showing = nil, startTask = nil, stopTask = nil }
	plumes[model] = entry
	local function onChanged()
		updatePlume(model)
	end
	for _, name in { ABILITY_ATTRIBUTE, STARTS_ATTRIBUTE, ENDS_ATTRIBUTE } do
		table.insert(entry.connections, model:GetAttributeChangedSignal(name):Connect(onChanged))
	end
	updatePlume(model)
end

local function unwatchPlumes(instance: Instance)
	local model = instance :: Model
	local entry = plumes[model]
	if entry == nil then
		return
	end
	plumes[model] = nil
	for _, connection in entry.connections do
		connection:Disconnect()
	end
	cancelTasks(entry)
	stopPlume(entry)
end

-- Boot ---------------------------------------------------------------------------------------------------------------

-- Studio only: lets Dev/AbilityTests, run from MCP execute_luau, send its flight input into the game's own
-- InputController (see its header), as CameraController does for Dev/AutoDriver. Live servers never reach it.
local function serveAbilityTests()
	if not RunService:IsStudio() then
		return
	end
	local dev = script.Parent.Parent:FindFirstChild("Dev")
	local tests = if dev then dev:FindFirstChild("AbilityTests") else nil
	if tests == nil or not tests:IsA("ModuleScript") then
		return
	end
	local ok, err = pcall(function()
		(require :: any)(tests).serve()
	end)
	if not ok then
		warn(`[AbilityController] AbilityTests.serve failed: {err}`)
	end
end

function AbilityController:Start()
	task.spawn(serveAbilityTests)

	HudController.onAbility:Connect(function()
		task.spawn(AbilityController.request)
	end)

	-- The server moved the car (anti-exploit reset or unstuck): no thrust on top of that.
	Net.onClientEvent("VehicleReset", function(_payload: any)
		finishSession()
	end)

	local tag = Spawning.vehicleTag
	CollectionService:GetInstanceAddedSignal(tag):Connect(watchPlumes)
	CollectionService:GetInstanceRemovedSignal(tag):Connect(unwatchPlumes)
	for _, instance in CollectionService:GetTagged(tag) do
		watchPlumes(instance)
	end

	DriveController.onDrivingChanged:Connect(onDrivingChanged)
	local current = DriveController.getCar()
	if current ~= nil then
		onDrivingChanged(true, current)
	end
end

return AbilityController
