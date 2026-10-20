--!strict
-- Driving physics for the car this client drives (the driver's client owns the car's physics). The invisible
-- Chassis part is the only physics body; each wheel is a raycast suspension corner:
--
--   1. One ray per wheel, from the top of the wheel down the chassis' -Y (excluding the car and its occupants).
--   2. A spring sized from the corner's share of the assembly mass and a natural frequency, so the car rests
--      at ride height whatever it weighs; an anti-roll bar between left and right; a damper. The ground pushes
--      along its normal at the contact patch.
--   3. Tires: sideways grip that stops the contact patch sliding, up to the friction limit; drive from
--      Vehicle/Powertrain with traction control; brakes (never locking); the handbrake on the rear wheels.
--   4. Aero drag and rolling resistance (the same curve Vehicle/Tuning calibrates 0-60 against), and modest
--      pitch and roll damping so the body settles and bumps can't flip it.
--
-- Every force is the assembly mass (Chassis.AssemblyMass, seated characters included) times an acceleration,
-- so the car drives the same at any mass. Each step applies forces as impulses (force * dt). Gravity pulls
-- through the whole frame, so weight support, drive, brakes, drag and rolling resistance use the real frame
-- time (up to Config/Driving.maxFrameDt). The impulses that cancel a velocity (dampers, sideways grip,
-- brakes) are capped at what cancels it, so one step can never reverse it; the springs use at most
-- Config/Driving.maxStepDt and are softened on slow frames (suspension.maxModeStep). That keeps the car stable
-- at any frame rate.
--
-- DriveController calls step(dt, controls) from RunService.PreSimulation. Wheels are animated through
-- Vehicle/WheelVisuals. Gravity is read from workspace.Gravity every step.
--
-- Limp mode (Phase 5, docs/phase-5-contracts.md "Client"): while the server sets the car's `Limp` attribute (out
-- of energy), the powertrain's top speed is Config/Energy.limpMph. The attribute is cached from its changed
-- signal, never read per frame; the server's anti-exploit holds the car to the same limit.

local Workspace = game:GetService("Workspace")

local Shared = script.Parent.Parent
local Driving = require(Shared.Config.Driving)
local EnergyConfig = require(Shared.Config.Energy)
local Powertrain = require(script.Parent.Powertrain)
local Tuning = require(script.Parent.Tuning)
local Types = require(Shared.Types)
local Units = require(Shared.Util.Units)
local WheelVisuals = require(script.Parent.WheelVisuals)

local WHEEL_IDS = WheelVisuals.WHEEL_IDS
local TWO_PI = 2 * math.pi
local BOX_INERTIA_DIVISOR = 12 -- a solid box's moment of inertia is mass * (a² + b²) / 12
local EPSILON = 1e-6
-- Car attribute the server (EnergyService) sets while the car has no energy left (docs/phase-5-contracts.md).
local LIMP_ATTRIBUTE = "Limp"

type WheelState = {
	id: WheelVisuals.WheelId,
	hub: Vector3, -- rest hub position, chassis space
	front: boolean,
	left: boolean,
	driveShare: number, -- share of drive force from the drive layout (renormalized over grounded wheels)
	brakeShare: number, -- share of braking from the brake bias (renormalized over grounded wheels)

	-- Filled in every step
	grounded: boolean,
	compression: number, -- studs above the rest position (+ = compressed)
	contact: Vector3,
	normal: Vector3,
	groundVelocity: Vector3, -- velocity of whatever the wheel stands on
	hubWorld: Vector3,
	load: number, -- mass this corner carries: assembly mass * its share
	spring: number, -- spring + anti-roll impulse this step, >= 0
	support: number, -- total suspension impulse this step (spring + damper), >= 0
}

type State = {
	model: Model,
	part: BasePart,
	tuning: Tuning.Tuning,
	powertrain: Powertrain.Powertrain,
	visuals: WheelVisuals.WheelVisuals,
	rayParams: RaycastParams,
	stopFilter: () -> (),
	wheels: { WheelState },
	compressions: { number }, -- handed to WheelVisuals each step, WHEEL_IDS order
	frontZ: number,
	rearZ: number,
	leftX: number,
	rightX: number,
	mode: Types.DriveMode,
	regen: Types.RegenLevel,
	steer: number, -- -1..1, the stick after the mode's steering rate
	steerAngle: number, -- radians, + = right
	telemetry: Types.Telemetry,
	limp: boolean, -- the car's Limp attribute, cached from its changed signal
	limpConnection: RBXScriptConnection?,
	destroyed: boolean,
}

local Chassis = {}
Chassis.__index = Chassis

export type Chassis = typeof(setmetatable({} :: State, Chassis))

local function approach(current: number, target: number, maxStep: number): number
	if current < target then
		return math.min(current + maxStep, target)
	end
	return math.max(current - maxStep, target)
end

local function sign(value: number): number
	return if value > 0 then 1 elseif value < 0 then -1 else 0
end

-- Unit vector of `vector` in the plane with normal `normal` (falls back to `vector` if they are parallel).
local function flatten(vector: Vector3, normal: Vector3): Vector3
	local flat = vector - normal * vector:Dot(normal)
	return if flat.Magnitude > EPSILON then flat.Unit else vector
end

local function newTelemetry(mode: Types.DriveMode, regen: Types.RegenLevel): Types.Telemetry
	return {
		speed = 0,
		mph = 0,
		gear = "D",
		mode = mode,
		regen = regen,
		throttle = 0,
		wheelsGrounded = 0,
		tractionActive = false,
		reversing = false,
	}
end

function Chassis.new(model: Model, tuning: Tuning.Tuning): Chassis
	local part = WheelVisuals.findChassis(model)
	local split = Driving.tires.awdFrontSplit
	local bias = Driving.brakes.frontBias

	local wheels: { WheelState } = {}
	for _, id in WHEEL_IDS do
		local front = string.sub(id, 1, 1) == "F"
		local attachment = part:FindFirstChild(`Wheel{id}`)
		local hub = if attachment and attachment:IsA("Attachment") then attachment.Position else tuning.hubs[id]
		local driveShare = if tuning.drive == "AWD"
			then (if front then split else 1 - split) / 2
			elseif tuning.drive == "RWD" then (if front then 0 else 0.5)
			else (if front then 0.5 else 0)
		table.insert(wheels, {
			id = id,
			hub = hub,
			front = front,
			left = string.sub(id, 2, 2) == "L",
			driveShare = driveShare,
			brakeShare = (if front then bias else 1 - bias) / 2,
			grounded = false,
			compression = 0,
			contact = Vector3.zero,
			normal = Vector3.yAxis,
			groundVelocity = Vector3.zero,
			hubWorld = Vector3.zero,
			load = 0,
			spring = 0,
			support = 0,
		})
	end

	local rayParams, stopFilter = WheelVisuals.trackRayFilter(model)
	local self: State = {
		model = model,
		part = part,
		tuning = tuning,
		powertrain = Powertrain.new(tuning),
		visuals = WheelVisuals.new(model),
		rayParams = rayParams,
		stopFilter = stopFilter,
		wheels = wheels,
		compressions = table.create(#WHEEL_IDS, 0),
		frontZ = (wheels[1].hub.Z + wheels[2].hub.Z) / 2,
		rearZ = (wheels[3].hub.Z + wheels[4].hub.Z) / 2,
		leftX = (wheels[1].hub.X + wheels[3].hub.X) / 2,
		rightX = (wheels[2].hub.X + wheels[4].hub.X) / 2,
		mode = "standard",
		regen = "standard",
		steer = 0,
		steerAngle = 0,
		telemetry = newTelemetry("standard", "standard"),
		limp = false,
		limpConnection = nil,
		destroyed = false,
	}
	local chassis = setmetatable(self, Chassis)

	-- Limp mode: follow the server's Limp attribute (one changed signal, no per-frame reads).
	local function readLimp()
		chassis:setLimp(model:GetAttribute(LIMP_ATTRIBUTE) == true)
	end
	chassis.limpConnection = model:GetAttributeChangedSignal(LIMP_ATTRIBUTE):Connect(readLimp)
	readLimp()
	return chassis
end

-- The limp-mode top speed, studs/s (Config/Energy.limpMph).
function Chassis.limpSpeed(): number
	return Units.mphToStuds(EnergyConfig.limpMph)
end

-- Caps the car at the limp speed (true) or gives it its own top speed back (false). Chassis.new keeps this in
-- step with the car's Limp attribute; exposed for the specs.
function Chassis.setLimp(self: Chassis, limp: boolean)
	self.limp = limp
	self.powertrain:setSpeedCap(if limp then Chassis.limpSpeed() else nil)
end

-- True while the car is held to the limp speed.
function Chassis.isLimp(self: Chassis): boolean
	return self.limp
end

-- Casts every wheel's ray and records what it found.
local function castWheels(self: Chassis, frame: CFrame, droop: number)
	local up = frame.UpVector
	local radius = self.tuning.wheelRadius
	-- From the top of the wheel down: the ground is 2 * radius below the origin at rest, and the ray reaches the
	-- spring's free length (droop) further so the wheel leaves the ground exactly where its force reaches zero.
	local reach = 2 * radius + droop
	for _, wheel in self.wheels do
		wheel.hubWorld = frame:PointToWorldSpace(wheel.hub)
		local result = Workspace:Raycast(wheel.hubWorld + up * radius, -up * reach, self.rayParams)
		if result then
			wheel.grounded = true
			wheel.compression = math.min(2 * radius - result.Distance, 2 * radius)
			wheel.contact = result.Position
			wheel.normal = result.Normal
			local ground = result.Instance
			wheel.groundVelocity = if ground:IsA("BasePart")
				then ground:GetVelocityAtPosition(result.Position)
				else Vector3.zero
		else
			wheel.grounded = false
			wheel.compression = -droop
		end
	end
end

-- Splits the assembly mass over the four corners from where the center of mass sits between the axles and
-- the sides (a passenger on one side loads that side), so every corner's spring holds exactly its share.
local function assignLoads(self: Chassis, frame: CFrame, mass: number, center: Vector3)
	local minShare = Driving.suspension.minLoadShare
	local offset = frame:PointToObjectSpace(center)
	local frontShare = math.clamp((self.rearZ - offset.Z) / (self.rearZ - self.frontZ), minShare, 1 - minShare)
	local leftShare = math.clamp((self.rightX - offset.X) / (self.rightX - self.leftX), minShare, 1 - minShare)
	for _, wheel in self.wheels do
		local axle = if wheel.front then frontShare else 1 - frontShare
		local side = if wheel.left then leftShare else 1 - leftShare
		wheel.load = mass * axle * side
	end
end

-- The front-wheel angle (radians) full steer gives at `speed` (studs/s) in `mode`. Speed-sensitive lock:
-- turning at speed v with steer angle d needs a sideways acceleration of v² * tan(d) / wheelbase; the tires
-- hold grip * gravity, so more lock than atan(grip * gravity * wheelbase / v²) only scrubs speed. The mode's
-- steerGripUse allows a little past it. Dev/AutoDriver steers with this too.
function Chassis.steerLockAt(tuning: Tuning.Tuning, mode: Types.DriveMode, speed: number, gravity: number): number
	local modeSettings = Driving.modes[mode] or Driving.modes.standard
	local gripLock = math.atan(
		modeSettings.steerGripUse * tuning.grip * gravity * tuning.wheelbase / math.max(speed * speed, EPSILON)
	)
	return math.clamp(gripLock, tuning.minSteerLock, tuning.steerLock)
end

function Chassis.step(self: Chassis, rawDt: number, controls: Types.Controls)
	local part = self.part
	if self.destroyed or part.Anchored then
		return
	end
	-- Real frame time for everything that balances gravity over the frame; the stiffness and damping of the
	-- suspension use at most maxStepDt (Config/Driving).
	local dt = math.min(rawDt, Driving.maxFrameDt)
	local stiffDt = math.min(dt, Driving.maxStepDt)
	local mass = part.AssemblyMass
	if dt <= 0 or mass <= 0 then
		return
	end

	local tuning = self.tuning
	local modeSettings = Driving.modes[self.mode]
	local gravity = Workspace.Gravity

	-- Snapshot of the body. Every velocity below comes from this snapshot, so the impulses applied during the
	-- step don't feed into each other.
	local frame = part.CFrame
	local up, forward = frame.UpVector, frame.LookVector
	local center = part.AssemblyCenterOfMass
	local linear = part.AssemblyLinearVelocity
	local angular = part.AssemblyAngularVelocity
	local spin = frame:VectorToObjectSpace(angular) -- X pitch, Y yaw, Z roll rates
	local forwardSpeed = linear:Dot(forward)
	local speed = math.abs(forwardSpeed)
	local function velocityAt(point: Vector3): Vector3
		return linear + angular:Cross(point - center)
	end
	-- Inertia of the chassis box about its own axes (X pitch, Y yaw, Z roll), scaled to the assembly mass.
	local size = part.Size
	local inertia = Vector3.new(
		mass * (size.Y * size.Y + size.Z * size.Z),
		mass * (size.X * size.X + size.Z * size.Z),
		mass * (size.X * size.X + size.Y * size.Y)
	) / BOX_INERTIA_DIVISOR

	-- Powertrain and steering ------------------------------------------------------------------------------
	local output = self.powertrain:update(dt, controls, forwardSpeed, self.mode, self.regen)

	self.steer = approach(self.steer, math.clamp(controls.steer, -1, 1), modeSettings.steerRate * dt)
	self.steerAngle = self.steer * Chassis.steerLockAt(tuning, self.mode, speed, gravity)

	-- Suspension ---------------------------------------------------------------------------------------------
	-- Per corner with load m and natural frequency w = 2 * pi * f:
	--   spring force = m * (g + w² * x), x = compression beyond rest
	-- At x = 0 the corners carry exactly the car's weight, so it rests at ride height at any mass. The force
	-- reaches zero at x = -g / w² (the spring's free length): the ray reaches that far, and the wheel leaves the
	-- ground with no jump in force. Damper force = -c * v with c = 2 * zeta * m * w, softer in bump.
	local omega = TWO_PI * tuning.suspensionFrequency * modeSettings.suspensionFrequencyScale
	local omegaSquared = omega * omega
	local zeta = tuning.dampingRatio * modeSettings.dampingScale
	local suspension = Driving.suspension
	local bumpStopStart = tuning.rideHeight * suspension.bumpStopFraction

	assignLoads(self, frame, mass, center)
	local wheels = self.wheels

	-- Stability. The springs are explicit (their impulse uses this step's compression), which blows up once
	-- (omega * dt)² passes 2 for the stiffest way the body can spring. Roll (with the anti-roll bars) and pitch
	-- are stiffer than bounce by the corners' leverage over the body's inertia, and a bump stop multiplies the
	-- local stiffness again. On slow frames, soften the bump stops and then the springs to stay under
	-- suspension.maxModeStep.
	local comLocal = frame:PointToObjectSpace(center)
	local rollLeverage, pitchLeverage = 0, 0
	for _, wheel in wheels do
		local lever = wheel.hub - comLocal
		rollLeverage += wheel.load * lever.X * lever.X
		pitchLeverage += wheel.load * lever.Z * lever.Z
	end
	local modeRatio = math.max(1, rollLeverage * (1 + 2 * tuning.antiRollRatio) / inertia.Z, pitchLeverage / inertia.X)
	local modeStep = omegaSquared * modeRatio * stiffDt * stiffDt
	local springScale = math.min(1, suspension.maxModeStep / modeStep)
	local bumpScale =
		math.clamp((suspension.maxModeStep / (modeStep * springScale) - 1) / suspension.bumpStopStiffness, 0, 1)
	local stepOmegaSquared = omegaSquared * springScale
	-- The spring's free length: where its impulse reaches zero (see below), so the ray reaches exactly that far
	-- and the wheel leaves the ground with no jump in force. g / omega² at normal frame rates.
	local droop = gravity * dt / (stepOmegaSquared * stiffDt)

	castWheels(self, frame, droop)

	local grounded = 0
	for _, wheel in wheels do
		if wheel.grounded then
			grounded += 1
			local x = wheel.compression
			local stiffness = stepOmegaSquared * x
			if x > bumpStopStart then
				stiffness += stepOmegaSquared * suspension.bumpStopStiffness * bumpScale * (x - bumpStopStart)
			end
			-- Weight support over the real frame, stiffness over the (capped) stiffness step.
			wheel.spring = wheel.load * math.max(0, gravity * dt + stiffness * stiffDt)
		else
			wheel.spring = 0
		end
	end

	-- Anti-roll bars: push up the more compressed side of an axle and unload the other, only with both wheels
	-- down (lifting a wheel already off the ground would only tip the car further).
	for axle = 0, 1 do
		local left, right = wheels[axle * 2 + 1], wheels[axle * 2 + 2]
		if left.grounded and right.grounded then
			local bar = (left.load + right.load) / 2 * stepOmegaSquared * tuning.antiRollRatio * stiffDt
			local transfer = bar * (left.compression - right.compression)
			left.spring = math.max(0, left.spring + transfer)
			right.spring = math.max(0, right.spring - transfer)
		end
	end

	-- The ground pushes along its normal at the contact patch, so that is where the suspension force goes.
	-- (Along the tilted body axis instead, a car squatting under acceleration would push itself backwards with
	-- a slice of its own weight and miss its 0-60.)
	--
	-- Dampers. Our impulse lands at the start of the step while gravity pulls all through it, so a car at rest
	-- starts every step sinking at about g * dt / 2; damping that phantom motion would make ride height depend on
	-- frame rate. Each damper therefore works on the step's average velocity: measured + (gravity along the
	-- normal) * dt / 2. Each corner's impulse is capped at what stops its own share of the motion. The four
	-- corners act on one rigid body, though, and in pitch and roll they add up to more than any one share (a
	-- box's corner is "lighter" in roll than in bounce), so the summed impulse is split into bounce, pitch and
	-- roll and each is capped at what stops that motion. Applying it at the center of mass plus a turning impulse
	-- is the same as applying it at the wheels.
	local damperLinear = Vector3.zero
	local damperTorque = Vector3.zero
	local groundVelocitySum = Vector3.zero
	local gravityAlongNormals = 0
	for _, wheel in wheels do
		if wheel.grounded then
			local normal = wheel.normal
			local gravityAlong = gravity * normal.Y -- workspace gravity points down world Y
			local relative = (velocityAt(wheel.contact) - wheel.groundVelocity):Dot(normal) + gravityAlong * dt / 2
			local scale = if relative < 0 then suspension.bumpDampingScale else suspension.reboundDampingScale
			local damping = 2 * zeta * wheel.load * omega * scale
			local cap = wheel.load * math.abs(relative)
			local impulse = math.clamp(-relative * damping * stiffDt, -cap, cap)
			-- A suspension can push but never pull the car down.
			impulse = math.max(impulse, -wheel.spring)
			wheel.support = wheel.spring + impulse
			damperLinear += normal * impulse
			damperTorque += (wheel.contact - center):Cross(normal * impulse)
			groundVelocitySum += wheel.groundVelocity
			gravityAlongNormals += gravityAlong
			if wheel.spring > 0 then
				part:ApplyImpulseAtPosition(normal * wheel.spring, wheel.contact)
			end
		else
			wheel.support = 0
		end
	end
	-- An axis whose damper already stops all its spin this step gets no body damping on top (that would
	-- reverse the spin, and on slow frames rock the car ever harder).
	local pitchStopped, rollStopped = false, false
	if grounded > 0 then
		local bounce = (linear - groundVelocitySum / grounded):Dot(up) + gravityAlongNormals / grounded * dt / 2
		local bounceImpulse = damperLinear:Dot(up)
		if bounceImpulse * bounce < 0 and math.abs(bounceImpulse) > mass * math.abs(bounce) then
			damperLinear *= mass * math.abs(bounce) / math.abs(bounceImpulse)
		end
		local torque = frame:VectorToObjectSpace(damperTorque)
		local pitch, roll = torque.X, torque.Z
		if pitch * spin.X < 0 and math.abs(pitch) > inertia.X * math.abs(spin.X) then
			pitch = -spin.X * inertia.X
			pitchStopped = true
		end
		if roll * spin.Z < 0 and math.abs(roll) > inertia.Z * math.abs(spin.Z) then
			roll = -spin.Z * inertia.Z
			rollStopped = true
		end
		part:ApplyImpulse(damperLinear)
		part:ApplyAngularImpulse(frame:VectorToWorldSpace(Vector3.new(pitch, torque.Y, roll)))
	end

	-- Tires --------------------------------------------------------------------------------------------------
	local tires = Driving.tires
	local handbrake = controls.handbrake
	local driveTotal, brakeTotal = 0, 0
	for _, wheel in wheels do
		if wheel.grounded then
			brakeTotal += wheel.brakeShare
			if not (handbrake and not wheel.front) then
				driveTotal += wheel.driveShare
			end
		end
	end
	local driveImpulse = mass * output.driveAccel * dt
	local brakeImpulse = mass * output.brakeAccel * dt
	-- Exponential decay, so cornering feels the same at any frame rate.
	local lateralResponse = math.min(tires.maxLateralCancel, 1 - math.exp(-tuning.lateralGripRate * dt))
	local gravityStep = Vector3.yAxis * (-gravity * dt) -- what gravity adds to every velocity this step
	local tractionUse = modeSettings.tractionUse
	local steerLocal = Vector3.new(math.sin(self.steerAngle), 0, -math.cos(self.steerAngle))
	local steeredForward = frame:VectorToWorldSpace(steerLocal)
	local tractionActive = false

	for _, wheel in wheels do
		if not wheel.grounded or wheel.support <= 0 then
			continue
		end
		local normal = wheel.normal
		local heading = flatten(if wheel.front then steeredForward else forward, normal)
		local side = heading:Cross(normal) -- the wheel's right, in the ground plane
		local slip = velocityAt(wheel.contact) - wheel.groundVelocity
		-- Grip and brakes work on how the patch will be moving at the end of the step, once gravity has pulled
		-- on it, so a car held on a slope stays put instead of creeping down it.
		local sideSpeed = slip:Dot(side) + gravityStep:Dot(side)
		local rollSpeed = slip:Dot(heading) + gravityStep:Dot(heading)

		local grip = tuning.grip * (if wheel.front then 1 else tuning.rearGripScale)
		local friction = grip * wheel.support -- the most impulse this tire can transmit this step
		local rearHandbrake = handbrake and not wheel.front

		-- Sideways: cancel the patch's sideways sliding at the tire's rate (capped at its share of the mass so
		-- one step never reverses it), up to the friction limit.
		local lateralLimit = friction * (if rearHandbrake then tires.handbrakeLateralGrip else 1)
		local lateral = math.clamp(-wheel.load * sideSpeed * lateralResponse, -lateralLimit, lateralLimit)

		-- Along the wheel: what's left of the friction circle after cornering.
		local available = math.sqrt(math.max(0, friction * friction - lateral * lateral))
		local drive = 0
		if driveTotal > 0 and not rearHandbrake then
			drive = driveImpulse * wheel.driveShare / driveTotal
			-- Traction control: never ask more of the tire than the mode lets drive use.
			local traction = available * tractionUse
			if math.abs(drive) > traction then
				drive = sign(drive) * traction
				tractionActive = true
			end
		end
		local braking = 0
		if brakeTotal > 0 then
			braking = brakeImpulse * wheel.brakeShare / brakeTotal
		end
		if rearHandbrake then
			braking += friction * tires.handbrakeFriction
		end
		-- Brakes oppose the rolling motion and stop it, never reverse it.
		braking = math.min(braking, wheel.load * math.abs(rollSpeed))
		local longitudinal = math.clamp(drive - sign(rollSpeed) * braking, -available, available)

		-- Apply part of the way up toward the center of mass (less body roll and pitch; see Config/Driving).
		local height = math.max(0, (center - wheel.contact):Dot(normal))
		if lateral ~= 0 then
			part:ApplyImpulseAtPosition(side * lateral, wheel.contact + normal * (height * tires.lateralForceRaise))
		end
		if longitudinal ~= 0 then
			part:ApplyImpulseAtPosition(
				heading * longitudinal,
				wheel.contact + normal * (height * tires.longitudinalForceRaise)
			)
		end
	end

	-- Drag, rolling resistance, body damping ---------------------------------------------------------------
	-- Aero drag (dragCoefficient * speed² against the motion), never more than stops the car.
	local airSpeed = linear.Magnitude
	if airSpeed > EPSILON then
		local drag = math.min(tuning.dragCoefficient * airSpeed * dt, 1) * airSpeed * mass
		part:ApplyImpulse(-linear.Unit * drag)
	end
	-- Rolling resistance while on the ground, never more than stops the car.
	if grounded > 0 and speed > EPSILON then
		local rolling = math.min(tuning.rollingResistance * dt, speed) * mass
		part:ApplyImpulse(-forward * (sign(forwardSpeed) * rolling))
	end
	-- Pitch and roll damping: exponential decay of the spin at the body's rate, skipped on an axis the dampers
	-- already stopped this step.
	local body = Driving.body
	local pitchRate = if grounded > 0 then body.pitchDampingRate else body.airborneDampingRate
	local rollRate = if grounded > 0 then body.rollDampingRate else body.airborneDampingRate
	local pitchDamping = if pitchStopped then 0 else 1 - math.exp(-pitchRate * dt)
	local rollDamping = if rollStopped then 0 else 1 - math.exp(-rollRate * dt)
	part:ApplyAngularImpulse(
		frame:VectorToWorldSpace(Vector3.new(-spin.X * inertia.X * pitchDamping, 0, -spin.Z * inertia.Z * rollDamping))
	)

	-- Wheels and telemetry -----------------------------------------------------------------------------------
	local compressions = self.compressions
	for index, wheel in wheels do
		compressions[index] = wheel.compression
	end
	self.visuals:update(dt, compressions, self.steerAngle)

	local telemetry = self.telemetry
	telemetry.speed = forwardSpeed
	telemetry.mph = Units.studsToMph(speed)
	telemetry.gear = output.gear
	telemetry.mode = self.mode
	telemetry.regen = self.regen
	telemetry.throttle = output.shaping
	telemetry.wheelsGrounded = grounded
	telemetry.tractionActive = tractionActive
	telemetry.reversing = output.reversing
end

function Chassis.setMode(self: Chassis, mode: Types.DriveMode)
	if Driving.modes[mode] then
		self.mode = mode
	end
end

function Chassis.setRegen(self: Chassis, level: Types.RegenLevel)
	if Driving.powertrain.regenDecel[level] then
		self.regen = level
	end
end

-- A copy of this step's numbers, for the HUD, camera and AutoDriver.
function Chassis.getTelemetry(self: Chassis): Types.Telemetry
	return table.clone(self.telemetry)
end

-- Clears the driving state after the server moves the car (it zeroes the velocities itself).
function Chassis.reset(self: Chassis)
	self.steer = 0
	self.steerAngle = 0
	self.powertrain:reset()
	self.telemetry = newTelemetry(self.mode, self.regen)
end

-- Stops driving: no more forces, wheels back at rest, seat listeners disconnected.
function Chassis.destroy(self: Chassis)
	if self.destroyed then
		return
	end
	self.destroyed = true
	local limpConnection = self.limpConnection
	if limpConnection then
		limpConnection:Disconnect()
		self.limpConnection = nil
	end
	self.stopFilter()
	self.visuals:destroy()
end

return Chassis
