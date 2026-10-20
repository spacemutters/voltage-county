--!strict
-- Physics for a coupled trailer or towed car (PLAN.md Phase 8, docs/phase-8-contracts.md "Trailers and towed
-- cars"). Controllers/TrailerController runs it on the client that drives the tractor: the server couples the
-- two with a BallSocketConstraint and gives that client network ownership of both, so the trailer is simulated
-- right beside its tractor. Read Vehicle/Chassis first: the suspension and tires here are its formulas and
-- clamps, minus steering and drive.
--
-- The trailer's invisible Chassis is its only physics body. Each step:
--
--   1. One ray per ground wheel, from the top of the wheel down the chassis' -Y (excluding the trailer and its
--      tractor).
--   2. The weight splits between the hitch and the axles by where the center of mass sits between them. The
--      hitch's share is held up by an upward impulse at the hitch (Config/Trailers explains why the tractor never
--      carries it). Each wheel's spring is sized from its share of the assembly mass and a natural frequency, so
--      the trailer rests at ride height whatever it weighs; anti-roll bars per axle; dampers on the step's
--      average velocity, each capped at what stops its own share of the motion.
--   3. Tires: sideways grip that stops the contact patch sliding at the tire's rate, up to the friction limit,
--      and never more than the trailer's effective mass at the axles (it slides and turns about its center of
--      mass), so one step can't swing it past straight. Brakes from the tractor's brake input, at least
--      Config/Trailers.brakeRatio x the tractor's own brake (Trailer.brakeDecelFor), plus an overspeed
--      brake above the tractor's top speed (a heavy trailer must not push its tractor past the anti-exploit
--      limit downhill). No drive force.
--   4. Rolling resistance on the trailer's whole weight, pitch and roll damping like a car body's, and the
--      anti-jackknife yaw damping: the trailer's yaw rate relative to the tractor decays at the spec's
--      yawDampingRate through a pair of equal and opposite angular impulses on trailer and tractor (a damper in
--      the hitch, so it never turns the rig as a whole). The pair is sized with both bodies' free yaw inertias,
--      the smallest they can have (the hitch pin only adds to them), so it never reverses the swing.
--
-- Every force is the trailer's AssemblyMass (or a share of it) times an acceleration, so it behaves the same at
-- any mass. Like Vehicle/Chassis it is frame-rate stable from 30 to 144 fps: weight support and brakes use the
-- real frame time (up to Config/Driving.maxFrameDt); springs and dampers use at most maxStepDt and are softened
-- on slow frames (suspension.maxModeStep, here also counting the trailer's pitch about the hitch); impulses
-- that cancel a velocity are capped at what cancels it; grip and yaw damping are exponential rates.
--
-- A towed car runs the same code with Config/Trailers.towed: its rear wheels (the WheelRL/RR attachments) are
-- the ground wheels and its front wheels hang in the lift. Wheels and trailer landing legs are posed through
-- their Motor6Ds (Transform only) by Trailer.newVisuals, which TrailerController also uses for other players'
-- trailers and towed cars (Config/Trailers.tag and towedTag); a model tagged as a player's car
-- (Config/Spawning.vehicleTag) is left to VehicleVisualsController instead.
--
-- The pure helpers below (springImpulse, damperImpulse, lateralImpulse, yawDampingImpulse, articulation,
-- brakeInput, ...) are what tests/Trailer.spec covers.

local Workspace = game:GetService("Workspace")

local Shared = script.Parent.Parent
local Driving = require(Shared.Config.Driving)
local Spawning = require(Shared.Config.Spawning)
local Trailers = require(Shared.Config.Trailers)
local Types = require(Shared.Types)
local WheelVisuals = require(script.Parent.WheelVisuals)

local TWO_PI = 2 * math.pi
local BOX_INERTIA_DIVISOR = 12 -- a solid box's moment of inertia is mass * (a² + b²) / 12
local EPSILON = 1e-6
-- Model contract names: the Wheels folder, each wheel's Motor6D and the hub attachments on the Chassis
-- (docs/phase-1-contracts.md for cars; Dev/TrailerBuilder gives trailers the same).
local WHEELS_FOLDER = "Wheels"
local WHEEL_MOTOR = "Motor"
local HUB_PREFIX = "Wheel"
local LEFT_SIDE = "L"
local RIGHT_SIDE = "R"

export type Spec = Trailers.Physics

type Wheel = {
	id: string,
	left: boolean,
	hub: Vector3, -- rest hub position, chassis space
	radius: number,

	-- Filled in every step
	grounded: boolean,
	compression: number, -- studs above the rest position (+ = compressed)
	contact: Vector3,
	normal: Vector3,
	groundVelocity: Vector3,
	load: number, -- mass this wheel carries: assembly mass * its share
	spring: number, -- spring + anti-roll impulse this step, >= 0
	support: number, -- total suspension impulse this step (spring + damper), >= 0
}

type AxlePair = { left: Wheel, right: Wheel }

type VisualWheel = {
	id: string,
	motor: Motor6D,
	hub: Vector3, -- rest hub position, chassis space (the motor's C0)
	radius: number,
	lifted: boolean,
	spin: number, -- radians about the axle, kept in [0, 2π)
}

type VisualsState = {
	part: BasePart,
	wheels: { VisualWheel },
	legs: { Motor6D },
	legsUp: boolean?, -- what the legs were last posed as (nil until the first update)
	rayParams: RaycastParams,
}

local Visuals = {}
Visuals.__index = Visuals

export type Visuals = typeof(setmetatable({} :: VisualsState, Visuals))

type State = {
	model: Model,
	part: BasePart,
	spec: Spec,
	tractor: BasePart?, -- the tractor's Chassis (yaw damping, articulation), if known
	hitch: Vector3, -- the hitch attachment's position, chassis space
	wheels: { Wheel },
	pairs: { AxlePair }, -- left/right wheels on the same axle (anti-roll bars)
	axleCount: number,
	axleZ: number, -- mean ground-wheel hub Z: where the axles carry their share
	leftX: number,
	rightX: number,
	bumpTravel: number, -- compression where the bump stop starts
	rayParams: RaycastParams,
	visuals: Visuals?,
	compressions: { [string]: number }, -- handed to the visuals each step
	speedCap: number?, -- studs/s; the overspeed brake holds the trailer under it
	brakeDecel: number, -- full-brake deceleration, studs/s² (Trailer.brakeDecelFor; the spec's until told)
	articulation: number, -- radians, last step
	wheelsGrounded: number,
	destroyed: boolean,
}

local Trailer = {}
Trailer.__index = Trailer

export type Trailer = typeof(setmetatable({} :: State, Trailer))

local function sign(value: number): number
	return if value > 0 then 1 elseif value < 0 then -1 else 0
end

-- Unit vector of `vector` in the plane with normal `normal` (falls back to `vector` if they are parallel).
local function flatten(vector: Vector3, normal: Vector3): Vector3
	local flat = vector - normal * vector:Dot(normal)
	return if flat.Magnitude > EPSILON then flat.Unit else vector
end

----------------------------------------------------------------------------------------------------------------
-- Pure helpers (tests/Trailer.spec)
----------------------------------------------------------------------------------------------------------------

-- Moments of inertia of a solid box of `size` about its own X (pitch), Y (yaw) and Z (roll) axes.
function Trailer.boxInertia(mass: number, size: Vector3): Vector3
	return Vector3.new(
		mass * (size.Y * size.Y + size.Z * size.Z),
		mass * (size.X * size.X + size.Z * size.Z),
		mass * (size.X * size.X + size.Y * size.Y)
	) / BOX_INERTIA_DIVISOR
end

-- Share of the weight resting on the hitch, from where the center of mass sits between the hitch and the axles
-- (chassis Z; the hitch is in front of the axles). The rest rides on the axles. Never below `minShare` or above
-- 1 - minShare.
function Trailer.hitchShare(comZ: number, hitchZ: number, axleZ: number, minShare: number): number
	local span = axleZ - hitchZ
	if math.abs(span) < EPSILON then
		return 1 - minShare
	end
	return math.clamp((axleZ - comZ) / span, minShare, 1 - minShare)
end

-- Mass one ground wheel carries: the axles share what the hitch doesn't, equally (a tandem equalizes), and each
-- axle splits it by `sideShare` (this wheel's side's share).
function Trailer.wheelLoad(mass: number, hitchShare: number, axleCount: number, sideShare: number): number
	return mass * (1 - hitchShare) / math.max(axleCount, 1) * sideShare
end

-- Upward impulse at the hitch that holds up the weight resting there for one frame of `dt`.
function Trailer.hitchSupportImpulse(
	mass: number,
	hitchShare: number,
	support: number,
	gravity: number,
	dt: number
): number
	return mass * hitchShare * support * gravity * dt
end

-- Spring stiffness per unit mass (1/s²) at `compression` (studs above rest): omega² * x, plus a bump stop that
-- multiplies it past `bumpTravel` (scaled down on slow frames by `bumpScale`).
function Trailer.springStiffness(
	compression: number,
	omegaSquared: number,
	bumpTravel: number,
	bumpScale: number
): number
	local stiffness = omegaSquared * compression
	if compression > bumpTravel then
		local stop = Driving.suspension.bumpStopStiffness
		stiffness += omegaSquared * stop * bumpScale * (compression - bumpTravel)
	end
	return stiffness
end

-- One step's spring impulse for a wheel carrying `load`: its weight over the real frame (gravity * dt) plus the
-- stiffness over the (capped) stiffness step. At zero compression it is exactly the weight, so the trailer
-- rests at ride height at any mass and frame rate. Never negative: a spring can't pull the trailer down.
function Trailer.springImpulse(load: number, stiffness: number, gravity: number, dt: number, stiffDt: number): number
	return load * math.max(0, gravity * dt + stiffness * stiffDt)
end

-- One step's damper impulse along the ground normal for a wheel carrying `load`, moving at `relative` studs/s
-- along the normal (the step's average; + = extending). It opposes the motion, is capped at what stops the
-- wheel's own share of it (load * |relative|), and never pulls down by more than the spring pushes up.
function Trailer.damperImpulse(load: number, relative: number, damping: number, stiffDt: number, spring: number): number
	local cap = load * math.abs(relative)
	local impulse = math.clamp(-relative * damping * stiffDt, -cap, cap)
	return math.max(impulse, -spring)
end

-- Share of a contact patch's sideways sliding the tire cancels in one step of `dt`: exponential decay at `rate`
-- (so it feels the same at any frame rate), never more than Config/Driving.tires.maxLateralCancel.
function Trailer.lateralResponse(rate: number, dt: number): number
	return math.min(Driving.tires.maxLateralCancel, 1 - math.exp(-rate * dt))
end

-- Sideways tire impulse that cancels `response` of `sideSpeed` for `mass`, within +-`limit` (the friction
-- limit). Opposes the sliding; never reverses it while response <= 1.
function Trailer.lateralImpulse(mass: number, sideSpeed: number, response: number, limit: number): number
	return math.clamp(-mass * sideSpeed * response, -limit, limit)
end

-- The mass a sideways impulse `lever` studs (along the trailer) from the center of mass acts on: the body both
-- slides and turns, so 1 / m_eff = 1 / m + lever² / I_yaw. Less than `mass` everywhere but at the center.
function Trailer.effectiveMass(mass: number, yawInertia: number, lever: number): number
	return 1 / (1 / mass + lever * lever / yawInertia)
end

-- The inertia two bodies turning against each other share: a * b / (a + b).
function Trailer.reducedInertia(a: number, b: number): number
	return a * b / (a + b)
end

-- Angular impulse (about the trailer's up axis) for the trailer; the tractor takes the opposite one. It makes the
-- relative yaw rate decay exponentially at `rate`, so the decay over a second is the same at any frame rate,
-- and with `reducedInertia` no larger than the bodies' real one it can only slow the swing, never reverse it.
function Trailer.yawDampingImpulse(relativeYawRate: number, reducedInertia: number, rate: number, dt: number): number
	return -relativeYawRate * reducedInertia * (1 - math.exp(-rate * dt))
end

-- Brake deceleration (studs/s²) for brake input 0..1, plus the overspeed brake above `speedCap` (the tractor's
-- top speed): Config/Driving.powertrain.overspeedBrakeGain per stud/s over it, like the tractor's powertrain.
function Trailer.brakeDecel(brake: number, brakeDecel: number, speed: number, speedCap: number?): number
	local decel = math.clamp(brake, 0, 1) * brakeDecel
	if speedCap ~= nil and speed > speedCap then
		decel = math.max(decel, Driving.powertrain.overspeedBrakeGain * (speed - speedCap))
	end
	return decel
end

-- How much of the springs' stiffness a step of `stiffDt` may use. Explicit springs blow up once (omega * dt)²
-- passes 2 for the stiffest way the body can spring (modeRatio: the stiffest mode's stiffness over bounce's);
-- like Vehicle/Chassis, slow frames soften the bump stops first, then the springs, to stay under
-- Config/Driving.suspension.maxModeStep. Returns the spring scale and the bump-stop scale, both 0..1.
function Trailer.stiffnessScales(omegaSquared: number, modeRatio: number, stiffDt: number): (number, number)
	local suspension = Driving.suspension
	local modeStep = math.max(omegaSquared * modeRatio * stiffDt * stiffDt, EPSILON)
	local springScale = math.min(1, suspension.maxModeStep / modeStep)
	local bumpScale =
		math.clamp((suspension.maxModeStep / (modeStep * springScale) - 1) / suspension.bumpStopStiffness, 0, 1)
	return springScale, bumpScale
end

-- The hitch's articulation: the angle (radians, 0..π) between the tractor's and the trailer's headings, measured
-- in the tractor's ground plane, so pitch and roll between them don't count. Dev/FreightTests compares it with
-- Config/Trailers.jackknifeAngle.
function Trailer.articulation(tractorFrame: CFrame, trailerFrame: CFrame): number
	local up = tractorFrame.UpVector
	local tractorHeading = flatten(tractorFrame.LookVector, up)
	local trailerHeading = flatten(trailerFrame.LookVector, up)
	return math.acos(math.clamp(tractorHeading:Dot(trailerHeading), -1, 1))
end

-- True when the rig has folded past Config/Trailers.jackknifeAngle.
function Trailer.isJackknifed(tractorFrame: CFrame, trailerFrame: CFrame): boolean
	return Trailer.articulation(tractorFrame, trailerFrame) > math.rad(Trailers.jackknifeAngle)
end

-- A trailer's full-brake deceleration (studs/s²) behind a tractor that brakes at `tractorBrakeDecel` (its
-- Vehicle/Tuning brakeDecel; nil: unknown): Config/Trailers.brakeRatio times it, never less than the spec's own,
-- so under braking the trailer always pulls back on the hitch and never pushes.
function Trailer.brakeDecelFor(spec: Spec, tractorBrakeDecel: number?): number
	if tractorBrakeDecel == nil then
		return spec.brakeDecel
	end
	return math.max(spec.brakeDecel, Trailers.brakeRatio * tractorBrakeDecel)
end

-- The tractor's lift-off deceleration at full lift (studs/s²), as Vehicle/Powertrain applies it: regen at
-- `regen` scaled by drive mode `mode` for a battery car, engine braking for a fuel car.
function Trailer.liftOffDecel(energy: string?, mode: Types.DriveMode?, regen: Types.RegenLevel?): number
	local powertrain = Driving.powertrain
	if energy ~= "battery" then
		return powertrain.engineBrakeDecel
	end
	local shaping = if mode ~= nil then Driving.modes[mode] else nil
	local level = if regen ~= nil then powertrain.regenDecel[regen] else nil
	return (level or powertrain.regenDecel.standard) * (if shaping then shaping.regenScale else 1)
end

-- The trailer's brake input (0..1) for this frame from the driver's controls and the tractor's telemetry:
--   * the pedal that slows the tractor: the brake, or in reverse the throttle (Vehicle/Powertrain swaps them);
--   * off both pedals near a standstill: the hold brake (like the tractor's);
--   * otherwise a coast brake of the tractor's lift-off `liftOffDecel` (Trailer.liftOffDecel) plus
--     Config/Trailers.coastMargin, faded in as the drive pedal comes up (below regenFadePedal) and out below
--     liftOffFullSpeed exactly like the tractor's, so the trailer never shoves it. With the drive pedal down
--     there is none (in reverse the brake pedal drives, so the trailer doesn't fight it).
-- `brakeDecel` is the trailer's full-brake deceleration (Trailer.brakeDecelFor), which the coast brake is a
-- share of.
function Trailer.brakeInput(
	controls: Types.Controls,
	telemetry: Types.Telemetry?,
	brakeDecel: number,
	liftOffDecel: number
): number
	local powertrain = Driving.powertrain
	local threshold = powertrain.pedalThreshold
	local reversing = telemetry ~= nil and telemetry.reversing
	local slowing = if reversing then controls.throttle else controls.brake
	local driving = math.clamp(if reversing then controls.brake else controls.throttle, 0, 1)
	if slowing > threshold then
		return math.clamp(slowing, 0, 1)
	end
	local speed = if telemetry then math.abs(telemetry.speed) else 0
	if driving <= threshold and speed < powertrain.holdSpeed then
		return math.clamp(powertrain.holdBrakeFraction, 0, 1)
	end
	local liftShare = math.clamp(1 - driving / powertrain.regenFadePedal, 0, 1)
	if liftShare <= 0 then
		return 0
	end
	local fade = math.min(1, speed / powertrain.liftOffFullSpeed)
	local coast = (liftOffDecel + Trailers.coastMargin) * liftShare * fade
	return math.clamp(coast / math.max(brakeDecel, EPSILON), 0, 1)
end

----------------------------------------------------------------------------------------------------------------
-- Models
----------------------------------------------------------------------------------------------------------------

-- The physics spec for a model: Config/Trailers.towed for a towed car (Towed = true), else the trailer named by
-- its TrailerId attribute (or its name). nil when it is neither.
function Trailer.specFor(model: Model): Spec?
	if model:GetAttribute(Trailers.towedAttribute) == true then
		return Trailers.towed
	end
	local id = model:GetAttribute(Trailers.idAttribute)
	local spec = if type(id) == "string" then Trailers.trailers[id] else nil
	return spec or Trailers.trailers[model.Name]
end

-- The ball-socket settings for coupling `target`: Config/Trailers.towed.hitch for a towed car, else
-- Config/Trailers.hitch (a semi trailer).
function Trailer.hitchSettingsFor(target: Model): Trailers.HitchSettings
	if target:GetAttribute(Trailers.towedAttribute) == true then
		return Trailers.towed.hitch
	end
	return Trailers.hitch
end

-- Applies hitch settings to a coupling's BallSocketConstraint (Services/HitchService).
function Trailer.configureHitch(constraint: BallSocketConstraint, settings: Trailers.HitchSettings)
	constraint.LimitsEnabled = settings.limitsEnabled
	constraint.UpperAngle = settings.upperAngle
	constraint.TwistLimitsEnabled = settings.twistLimitsEnabled
	constraint.TwistLowerAngle = settings.twistLowerAngle
	constraint.TwistUpperAngle = settings.twistUpperAngle
	constraint.Restitution = settings.restitution
	constraint.MaxFrictionTorque = settings.maxFrictionTorque
end

local function wheelPart(model: Model, id: string): BasePart?
	local folder = model:FindFirstChild(WHEELS_FOLDER)
	local wheel = if folder then folder:FindFirstChild(id) else nil
	return if wheel and wheel:IsA("BasePart") then wheel else nil
end

local function wheelMotor(wheel: BasePart?): Motor6D?
	local motor = if wheel then wheel:FindFirstChild(WHEEL_MOTOR) else nil
	return if motor and motor:IsA("Motor6D") then motor else nil
end

-- A wheel's rest hub in chassis space: its Wheel<id> attachment, else its motor's C0.
local function hubOf(part: BasePart, motor: Motor6D?, id: string): Vector3?
	local attachment = part:FindFirstChild(HUB_PREFIX .. id)
	if attachment and attachment:IsA("Attachment") then
		return attachment.Position
	end
	return if motor then motor.C0.Position else nil
end

-- Wheels are cylinders with the axle along X, so the diameter is the Y (= Z) size.
local function radiusOf(wheel: BasePart): number
	return math.max(wheel.Size.Y, wheel.Size.Z) / 2
end

-- True once everything Trailer.new needs has reached this client: the Chassis, the hitch attachment and every
-- ground wheel with its Motor. (Models stream atomically, but the tractor's Towing value can point at one a
-- moment before it arrives.)
function Trailer.isReady(model: Model, spec: Spec): boolean
	local part = model.PrimaryPart or model:FindFirstChild("Chassis")
	if part == nil or not part:IsA("BasePart") then
		return false
	end
	local hitch = part:FindFirstChild(spec.hitchAttachment)
	if hitch == nil or not hitch:IsA("Attachment") then
		return false
	end
	for _, id in spec.groundWheels do
		if wheelMotor(wheelPart(model, id)) == nil then
			return false
		end
	end
	return true
end

----------------------------------------------------------------------------------------------------------------
-- Visuals: wheels and landing legs, posed through their Motor6Ds
----------------------------------------------------------------------------------------------------------------

-- Wheel and leg posing for a trailer or towed car. Missing wheels or legs are skipped. Trailer:step feeds it the
-- suspension's compressions; with none (other players' trailers) each ground wheel raycasts for itself.
function Trailer.newVisuals(model: Model, spec: Spec): Visuals
	local part = WheelVisuals.findChassis(model)
	local wheels: { VisualWheel } = {}
	local function add(id: string, lifted: boolean)
		local wheel = wheelPart(model, id)
		local motor = wheelMotor(wheel)
		if wheel and motor then
			table.insert(wheels, {
				id = id,
				motor = motor,
				hub = motor.C0.Position,
				radius = radiusOf(wheel),
				lifted = lifted,
				spin = 0,
			})
		end
	end
	for _, id in spec.groundWheels do
		add(id, false)
	end
	for _, id in spec.liftedWheels do
		add(id, true)
	end

	local legs: { Motor6D } = {}
	local gear = model:FindFirstChild(Trailers.landingGearFolder)
	if gear then
		for _, leg in gear:GetChildren() do
			local motor = leg:FindFirstChild(Trailers.landingGearMotor)
			if motor and motor:IsA("Motor6D") then
				table.insert(legs, motor)
			end
		end
	end

	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.FilterDescendantsInstances = { model }
	rayParams.RespectCanCollide = true -- triggers and zones are not road
	rayParams.IgnoreWater = true

	local self: VisualsState = {
		part = part,
		wheels = wheels,
		legs = legs,
		legsUp = nil,
		rayParams = rayParams,
	}
	return setmetatable(self, Visuals)
end

-- How far a wheel's hub sits above its rest position (+ = compressed), cast from the top of the wheel down.
local function castOffset(self: Visuals, wheel: VisualWheel, frame: CFrame): number
	local up = frame.UpVector
	local maxDroop = Driving.wheelVisuals.maxDroop
	local origin = frame:PointToWorldSpace(wheel.hub) + up * wheel.radius
	local result = Workspace:Raycast(origin, -up * (2 * wheel.radius + maxDroop), self.rayParams)
	if result == nil then
		return -maxDroop
	end
	return 2 * wheel.radius - result.Distance
end

-- Poses every wheel for this frame (suspension travel along +Y, then spin about X; lifted wheels hang still at
-- full droop) and cranks the legs up while the trailer is unanchored (coupled) and down while it is parked.
-- `compressions` (studs above rest per wheel id) come from Trailer:step; leave nil to raycast.
function Visuals.update(self: Visuals, dt: number, compressions: { [string]: number }?)
	local part = self.part
	local frame = part.CFrame
	local heading = frame.LookVector
	local linear = part.AssemblyLinearVelocity
	local angular = part.AssemblyAngularVelocity
	local center = part.AssemblyCenterOfMass
	local maxDroop = Driving.wheelVisuals.maxDroop

	for _, wheel in self.wheels do
		local offset: number
		if wheel.lifted then
			offset = -maxDroop
		elseif compressions then
			offset = compressions[wheel.id] or 0
		else
			offset = castOffset(self, wheel, frame)
		end
		offset = math.clamp(offset, -maxDroop, wheel.radius)
		if not wheel.lifted then
			-- Rolling forward (-Z) turns the wheel's top forward, a negative rotation about X.
			local hubWorld = frame:PointToWorldSpace(wheel.hub)
			local hubVelocity = linear + angular:Cross(hubWorld - center)
			wheel.spin = (wheel.spin - hubVelocity:Dot(heading) / wheel.radius * dt) % TWO_PI
		end
		wheel.motor.Transform = CFrame.new(0, offset, 0) * CFrame.Angles(wheel.spin, 0, 0)
	end

	local legsUp = not part.Anchored
	if legsUp ~= self.legsUp then
		self.legsUp = legsUp
		local lift = if legsUp then CFrame.new(0, Trailers.landingGear.retract, 0) else CFrame.identity
		for _, motor in self.legs do
			motor.Transform = lift
		end
	end
end

-- Puts every wheel and leg back at rest.
function Visuals.destroy(self: Visuals)
	for _, wheel in self.wheels do
		wheel.motor.Transform = CFrame.identity
	end
	for _, motor in self.legs do
		motor.Transform = CFrame.identity
	end
	self.legsUp = nil
end

----------------------------------------------------------------------------------------------------------------
-- The trailer
----------------------------------------------------------------------------------------------------------------

-- Sets up a coupled trailer or towed car. `spec` is its Config/Trailers spec (Trailer.specFor); `tractor` is the
-- car pulling it, for the anti-jackknife yaw damping and the articulation (without it there is no yaw damping).
-- Errors when the model is missing its Chassis, hitch attachment or a ground wheel (see Trailer.isReady).
function Trailer.new(model: Model, spec: Spec, tractor: Model?): Trailer
	local part = WheelVisuals.findChassis(model)
	local hitch = part:FindFirstChild(spec.hitchAttachment)
	if hitch == nil or not hitch:IsA("Attachment") then
		error(`{model:GetFullName()} has no {spec.hitchAttachment} attachment on its Chassis`)
	end
	local tractorPart = if tractor then WheelVisuals.findChassis(tractor) else nil

	local wheels: { Wheel } = {}
	local byAxle: { [string]: { left: Wheel?, right: Wheel? } } = {}
	local axleCount = 0
	local axleZ, leftX, rightX, lefts, rights = 0, 0, 0, 0, 0
	for _, id in spec.groundWheels do
		local wheel = wheelPart(model, id)
		local hub = hubOf(part, wheelMotor(wheel), id)
		if wheel == nil or hub == nil then
			error(`{model:GetFullName()} is missing ground wheel {id}`)
		end
		local side = string.sub(id, -1)
		local left = side == LEFT_SIDE
		local state: Wheel = {
			id = id,
			left = left,
			hub = hub,
			radius = radiusOf(wheel),
			grounded = false,
			compression = 0,
			contact = Vector3.zero,
			normal = Vector3.yAxis,
			groundVelocity = Vector3.zero,
			load = 0,
			spring = 0,
			support = 0,
		}
		table.insert(wheels, state)
		axleZ += hub.Z
		if left then
			leftX += hub.X
			lefts += 1
		elseif side == RIGHT_SIDE then
			rightX += hub.X
			rights += 1
		end
		-- The axle is the id without its side letter ("A1L" -> "A1", "RL" -> "R").
		local axle = string.sub(id, 1, -2)
		local pair = byAxle[axle]
		if pair == nil then
			pair = {}
			byAxle[axle] = pair
			axleCount += 1
		end
		if left then
			pair.left = state
		else
			pair.right = state
		end
	end
	if #wheels == 0 then
		error(`{model:GetFullName()}: the spec has no ground wheels`)
	end
	local axlePairs: { AxlePair } = {}
	for _, pair in byAxle do
		local left, right = pair.left, pair.right
		if left and right then
			table.insert(axlePairs, { left = left, right = right })
		end
	end

	-- Ride height: the chassis' bottom above the ground at rest (a wheel's hub sits its radius above the ground).
	local first = wheels[1]
	local rideHeight = first.radius - first.hub.Y - part.Size.Y / 2

	-- Rays skip the trailer and its tractor.
	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.FilterDescendantsInstances = if tractor then { model, tractor } else { model }
	rayParams.RespectCanCollide = true
	rayParams.IgnoreWater = true

	local visuals: Visuals? = nil
	if not model:HasTag(Spawning.vehicleTag) then
		visuals = Trailer.newVisuals(model, spec)
	end

	local self: State = {
		model = model,
		part = part,
		spec = spec,
		tractor = tractorPart,
		hitch = hitch.Position,
		wheels = wheels,
		pairs = axlePairs,
		axleCount = axleCount,
		axleZ = axleZ / #wheels,
		leftX = if lefts > 0 then leftX / lefts else 0,
		rightX = if rights > 0 then rightX / rights else 0,
		bumpTravel = spec.bumpTravel or rideHeight * Driving.suspension.bumpStopFraction,
		rayParams = rayParams,
		visuals = visuals,
		compressions = {},
		speedCap = nil,
		brakeDecel = spec.brakeDecel,
		articulation = 0,
		wheelsGrounded = 0,
		destroyed = false,
	}
	return setmetatable(self, Trailer)
end

-- Casts every ground wheel's ray and records what it found.
local function castWheels(self: Trailer, frame: CFrame, droop: number)
	local up = frame.UpVector
	for _, wheel in self.wheels do
		local radius = wheel.radius
		-- From the top of the wheel down: the ground is 2 * radius below the origin at rest, and the ray reaches
		-- the spring's free length (droop) further, where its force reaches zero.
		local origin = frame:PointToWorldSpace(wheel.hub) + up * radius
		local result = Workspace:Raycast(origin, -up * (2 * radius + droop), self.rayParams)
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

-- Holds the trailer under `cap` studs/s with the overspeed brake (the tractor's top speed, or its limp speed);
-- nil turns it off.
function Trailer.setSpeedCap(self: Trailer, cap: number?)
	self.speedCap = cap
end

-- Sets the full-brake deceleration (studs/s²; Trailer.brakeDecelFor with the tractor's own brake).
function Trailer.setBrakeDecel(self: Trailer, decel: number)
	self.brakeDecel = decel
end

-- The full-brake deceleration the trailer brakes with (studs/s²).
function Trailer.getBrakeDecel(self: Trailer): number
	return self.brakeDecel
end

-- One physics step: `brake` is the trailer's brake input 0..1 (Trailer.brakeInput). Call from
-- RunService.PreSimulation on the client that owns the rig.
function Trailer.step(self: Trailer, rawDt: number, brake: number)
	local part = self.part
	if self.destroyed or part.Anchored then
		return
	end
	local dt = math.min(rawDt, Driving.maxFrameDt)
	local stiffDt = math.min(dt, Driving.maxStepDt)
	local mass = part.AssemblyMass
	if dt <= 0 or mass <= 0 then
		return
	end

	local spec = self.spec
	local suspension = Driving.suspension
	local gravity = Workspace.Gravity

	-- Snapshot of the body. Every velocity below comes from it, so this step's impulses don't feed each other.
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
	local inertia = Trailer.boxInertia(mass, part.Size)
	local comLocal = frame:PointToObjectSpace(center)
	local wheels = self.wheels

	-- Loads ------------------------------------------------------------------------------------------------
	local minShare = suspension.minLoadShare
	local hitchShare = Trailer.hitchShare(comLocal.Z, self.hitch.Z, self.axleZ, minShare)
	local sideSpan = self.rightX - self.leftX
	local leftShare = if math.abs(sideSpan) > EPSILON
		then math.clamp((self.rightX - comLocal.X) / sideSpan, minShare, 1 - minShare)
		else 0.5
	for _, wheel in wheels do
		local sideShare = if wheel.left then leftShare else 1 - leftShare
		wheel.load = Trailer.wheelLoad(mass, hitchShare, self.axleCount, sideShare)
	end

	-- Suspension -------------------------------------------------------------------------------------------
	-- Per wheel with load m and natural frequency w: spring force = m * (g + w² * x), damper = -2 * zeta * m * w
	-- * v (softer in bump). Stability: the stiffest way the body can spring is roll (with the anti-roll bars),
	-- pitch about the center of mass, or pitch about the hitch (the tractor holds the nose); slow frames soften
	-- the springs to keep it under maxModeStep (Trailer.stiffnessScales).
	local omega = TWO_PI * spec.suspensionFrequency
	local omegaSquared = omega * omega
	local rollLeverage, pitchLeverage, hitchLeverage = 0, 0, 0
	for _, wheel in wheels do
		local lever = wheel.hub - comLocal
		local arm = wheel.hub.Z - self.hitch.Z
		rollLeverage += wheel.load * lever.X * lever.X
		pitchLeverage += wheel.load * lever.Z * lever.Z
		hitchLeverage += wheel.load * arm * arm
	end
	local hitchArm = comLocal - self.hitch
	local hitchPitchInertia = inertia.X + mass * (hitchArm.Y * hitchArm.Y + hitchArm.Z * hitchArm.Z)
	local modeRatio = math.max(
		1,
		rollLeverage * (1 + 2 * spec.antiRollRatio) / inertia.Z,
		pitchLeverage / inertia.X,
		hitchLeverage / hitchPitchInertia
	)
	local springScale, bumpScale = Trailer.stiffnessScales(omegaSquared, modeRatio, stiffDt)
	local stepOmegaSquared = omegaSquared * springScale
	-- The spring's free length (where its impulse reaches zero): g / omega² at normal frame rates.
	local droop = gravity * dt / (stepOmegaSquared * stiffDt)

	castWheels(self, frame, droop)

	local grounded, groundedLoad = 0, 0
	for _, wheel in wheels do
		if wheel.grounded then
			grounded += 1
			groundedLoad += wheel.load
			local stiffness = Trailer.springStiffness(wheel.compression, stepOmegaSquared, self.bumpTravel, bumpScale)
			wheel.spring = Trailer.springImpulse(wheel.load, stiffness, gravity, dt, stiffDt)
		else
			wheel.spring = 0
		end
	end

	-- Anti-roll bars: push up the more compressed side of an axle and unload the other, only with both down.
	for _, pair in self.pairs do
		local left, right = pair.left, pair.right
		if left.grounded and right.grounded then
			local bar = (left.load + right.load) / 2 * stepOmegaSquared * spec.antiRollRatio * stiffDt
			local transfer = bar * (left.compression - right.compression)
			left.spring = math.max(0, left.spring + transfer)
			right.spring = math.max(0, right.spring - transfer)
		end
	end

	-- The hitch's share of the weight, held up at the hitch while the trailer stands on its wheels (in the air it
	-- hangs off its tractor like any load).
	if grounded > 0 then
		local support = Trailer.hitchSupportImpulse(mass, hitchShare, spec.hitchSupport, gravity, dt)
		part:ApplyImpulseAtPosition(Vector3.yAxis * support, frame:PointToWorldSpace(self.hitch))
	end

	-- Springs push along the ground normal at the contact patch. Dampers work on the step's average velocity
	-- (measured + gravity along the normal * dt / 2, since our impulse lands at the start of the step), each
	-- capped at what stops its own share; the sum is split into bounce, pitch and roll and each is capped at
	-- what stops that motion (Vehicle/Chassis explains why), then applied at the center of mass.
	local zeta = spec.dampingRatio
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
			local impulse = Trailer.damperImpulse(wheel.load, relative, damping, stiffDt, wheel.spring)
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
	local pitchStopped, rollStopped = false, false
	if grounded > 0 then
		-- Only the wheels' share of the mass bounces on them (the hitch holds the rest).
		local bounce = (linear - groundVelocitySum / grounded):Dot(up) + gravityAlongNormals / grounded * dt / 2
		local bounceImpulse = damperLinear:Dot(up)
		if bounceImpulse * bounce < 0 and math.abs(bounceImpulse) > groundedLoad * math.abs(bounce) then
			damperLinear *= groundedLoad * math.abs(bounce) / math.abs(bounceImpulse)
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
	local lateralResponse = Trailer.lateralResponse(spec.lateralGripRate, dt)
	local gravityStep = Vector3.yAxis * (-gravity * dt) -- what gravity adds to every velocity this step
	-- A sideways impulse at the axles slides and turns the trailer, so it moves less mass than the wheels carry:
	-- grip cancels at most what that effective mass needs, so a step can't swing the tail past straight.
	local effective = Trailer.effectiveMass(mass, inertia.Y, self.axleZ - comLocal.Z)
	local lateralScale = if groundedLoad > EPSILON then math.min(1, effective / groundedLoad) else 1
	local brakeImpulse = mass * Trailer.brakeDecel(brake, self.brakeDecel, speed, self.speedCap) * dt

	for _, wheel in wheels do
		if not wheel.grounded or wheel.support <= 0 then
			continue
		end
		local normal = wheel.normal
		local heading = flatten(forward, normal)
		local side = heading:Cross(normal) -- the wheel's right, in the ground plane
		local slip = velocityAt(wheel.contact) - wheel.groundVelocity
		-- Work on how the patch will be moving at the end of the step, once gravity has pulled on it, so a trailer
		-- held on a slope stays put instead of creeping down it.
		local sideSpeed = slip:Dot(side) + gravityStep:Dot(side)
		local rollSpeed = slip:Dot(heading) + gravityStep:Dot(heading)

		local friction = spec.grip * wheel.support -- the most impulse this tire can transmit this step
		local lateral = Trailer.lateralImpulse(wheel.load * lateralScale, sideSpeed, lateralResponse, friction)

		-- Along the wheel: what's left of the friction circle. Brakes oppose the rolling and stop it, never
		-- reverse it; the trailer's whole mass brakes, shared over the grounded wheels by load.
		local available = math.sqrt(math.max(0, friction * friction - lateral * lateral))
		local braking = math.min(brakeImpulse * wheel.load / groundedLoad, wheel.load * math.abs(rollSpeed))
		local longitudinal = math.clamp(-sign(rollSpeed) * braking, -available, available)

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

	-- Rolling resistance, body damping, yaw damping -------------------------------------------------------
	-- Rolling resistance on the whole trailer (its weight rides on tires either way), never more than stops it.
	if grounded > 0 and speed > EPSILON then
		local rolling = math.min(Driving.resistance.rollingCoefficient * gravity * dt, speed) * mass
		part:ApplyImpulse(-forward * (sign(forwardSpeed) * rolling))
	end
	-- Pitch and roll damping: exponential decay at the body's rates, skipped where the dampers already stopped it.
	local body = Driving.body
	local pitchRate = if grounded > 0 then body.pitchDampingRate else body.airborneDampingRate
	local rollRate = if grounded > 0 then body.rollDampingRate else body.airborneDampingRate
	local pitchDamping = if pitchStopped then 0 else 1 - math.exp(-pitchRate * dt)
	local rollDamping = if rollStopped then 0 else 1 - math.exp(-rollRate * dt)
	part:ApplyAngularImpulse(
		frame:VectorToWorldSpace(Vector3.new(-spin.X * inertia.X * pitchDamping, 0, -spin.Z * inertia.Z * rollDamping))
	)

	-- Anti-jackknife: damp the hitch's swing (the yaw rate relative to the tractor) with equal and opposite
	-- angular impulses on the two bodies.
	local tractor = self.tractor
	if tractor and tractor.Parent and not tractor.Anchored then
		local tractorMass = tractor.AssemblyMass
		if tractorMass > 0 then
			local relative = (angular - tractor.AssemblyAngularVelocity):Dot(up)
			local tractorInertia = Trailer.boxInertia(tractorMass, tractor.Size)
			local reduced = Trailer.reducedInertia(inertia.Y, tractorInertia.Y)
			local impulse = Trailer.yawDampingImpulse(relative, reduced, spec.yawDampingRate, dt)
			if impulse ~= 0 then
				part:ApplyAngularImpulse(up * impulse)
				tractor:ApplyAngularImpulse(up * -impulse)
			end
		end
		self.articulation = Trailer.articulation(tractor.CFrame, frame)
	end

	-- Wheels -------------------------------------------------------------------------------------------------
	self.wheelsGrounded = grounded
	local visuals = self.visuals
	if visuals then
		local compressions = self.compressions
		for _, wheel in wheels do
			compressions[wheel.id] = wheel.compression
		end
		visuals:update(dt, compressions)
	end
end

-- The hitch's articulation at the last step (radians; Trailer.articulation), 0 without a tractor.
function Trailer.getArticulation(self: Trailer): number
	return self.articulation
end

-- How many ground wheels touched the ground at the last step.
function Trailer.getWheelsGrounded(self: Trailer): number
	return self.wheelsGrounded
end

-- Stops stepping and puts the wheels and legs back at rest.
function Trailer.destroy(self: Trailer)
	if self.destroyed then
		return
	end
	self.destroyed = true
	local visuals = self.visuals
	if visuals then
		visuals:destroy()
		self.visuals = nil
	end
end

return Trailer
