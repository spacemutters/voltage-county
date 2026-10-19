--!strict
-- Animates a car's four visual wheels. Wheels are not physics bodies: each one hangs off the Chassis on a
-- Motor6D named "Motor" (C0 = the hub attachment, at ride height), and only Motor.Transform is written:
-- suspension travel along +Y, then steering yaw about Y (front wheels), then rolling spin about X.
--
-- The owning client's Vehicle/Chassis passes its suspension travel and steering angle each step. For any other
-- car (VehicleVisualsController) call update with no compressions: each wheel then raycasts the ground itself,
-- and steering is inferred from the car's yaw rate (bicycle model), so other players' cars look alive too.
-- Spin always comes from the chassis velocity at each hub. Motor.Transform is local, so nothing replicates.
--
-- trackRayFilter builds the RaycastParams both modules use: exclude the car and everyone seated in it (kept up
-- to date by seat Occupant signals, no polling), respect CanCollide, ignore water.

local Workspace = game:GetService("Workspace")

local Driving = require(script.Parent.Parent.Config.Driving)

-- "FL" | "FR" | "RL" | "RR" (kept a plain string so it can index tables from loops without casts)
export type WheelId = string

-- Wheel order used everywhere (compressions arrays, Chassis wheel state).
local WHEEL_IDS: { WheelId } = { "FL", "FR", "RL", "RR" }
local TWO_PI = 2 * math.pi

type Wheel = {
	id: WheelId,
	slot: number, -- index in WHEEL_IDS (and in compressions arrays)
	motor: Motor6D,
	hub: Vector3, -- rest hub position, chassis space (the motor's C0)
	radius: number,
	front: boolean,
	spin: number, -- radians about the axle, kept in [0, 2π)
}

type State = {
	chassis: BasePart,
	wheels: { Wheel },
	wheelbase: number,
	steer: number, -- inferred steering angle for cars we don't drive, radians (+ = right)
	rayParams: RaycastParams,
	stopFilter: () -> (),
}

local WheelVisuals = {}
WheelVisuals.__index = WheelVisuals
WheelVisuals.WHEEL_IDS = WHEEL_IDS

export type WheelVisuals = typeof(setmetatable({} :: State, WheelVisuals))

-- RaycastParams that exclude `model` and every character seated in it, updated whenever a seat's occupant
-- changes. Returns the params and a function that stops the updates.
function WheelVisuals.trackRayFilter(model: Model): (RaycastParams, () -> ())
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.RespectCanCollide = true -- triggers and zones are not road
	params.IgnoreWater = true -- cars drive on the lake bed, not the surface

	local seats: { Seat } = {}
	local seatFolder = model:FindFirstChild("Seats")
	if seatFolder then
		for _, child in seatFolder:GetChildren() do
			if child:IsA("Seat") then
				table.insert(seats, child)
			end
		end
	end

	local function refresh()
		local excluded: { Instance } = { model }
		for _, seat in seats do
			local occupant = seat.Occupant
			local character = if occupant then occupant.Parent else nil
			if character then
				table.insert(excluded, character)
			end
		end
		params.FilterDescendantsInstances = excluded
	end

	local connections: { RBXScriptConnection } = {}
	for _, seat in seats do
		table.insert(connections, seat:GetPropertyChangedSignal("Occupant"):Connect(refresh))
	end
	refresh()

	local function stop()
		for _, connection in connections do
			connection:Disconnect()
		end
		table.clear(connections)
	end
	return params, stop
end

-- The car's physics body: the model's PrimaryPart, or its part named Chassis.
function WheelVisuals.findChassis(model: Model): BasePart
	local primary = model.PrimaryPart
	if primary then
		return primary
	end
	local named = model:FindFirstChild("Chassis")
	if named and named:IsA("BasePart") then
		return named
	end
	error(`{model:GetFullName()} has no Chassis part`)
end

function WheelVisuals.new(model: Model): WheelVisuals
	local chassis = WheelVisuals.findChassis(model)

	local wheels: { Wheel } = {}
	local folder = model:FindFirstChild("Wheels")
	local frontZ, rearZ = 0, 0
	for slot, id in WHEEL_IDS do
		local part = if folder then folder:FindFirstChild(id) else nil
		local motor = if part then part:FindFirstChild("Motor") else nil
		if part and part:IsA("BasePart") and motor and motor:IsA("Motor6D") then
			local front = string.sub(id, 1, 1) == "F"
			local hub = motor.C0.Position
			-- Wheels are cylinders with the axle along X, so the diameter is the Y (= Z) size.
			table.insert(wheels, {
				id = id,
				slot = slot,
				motor = motor,
				hub = hub,
				radius = math.max(part.Size.Y, part.Size.Z) / 2,
				front = front,
				spin = 0,
			})
			if front then
				frontZ = hub.Z
			else
				rearZ = hub.Z
			end
		end
	end

	local rayParams, stopFilter = WheelVisuals.trackRayFilter(model)
	local self: State = {
		chassis = chassis,
		wheels = wheels,
		wheelbase = math.abs(rearZ - frontZ),
		steer = 0,
		rayParams = rayParams,
		stopFilter = stopFilter,
	}
	return setmetatable(self, WheelVisuals)
end

-- How far a wheel's hub sits above its rest position (+ = compressed), found by casting from the top of the
-- wheel down: at rest the ground is 2 * radius below the cast origin.
local function castOffset(self: WheelVisuals, wheel: Wheel, frame: CFrame): number
	local up = frame.UpVector
	local origin = frame:PointToWorldSpace(wheel.hub) + up * wheel.radius
	local reach = 2 * wheel.radius + Driving.wheelVisuals.maxDroop
	local result = Workspace:Raycast(origin, -up * reach, self.rayParams)
	if result == nil then
		return -Driving.wheelVisuals.maxDroop
	end
	return 2 * wheel.radius - result.Distance
end

-- Steering angle for a car we don't drive, from its yaw rate: a bicycle model turning at yaw rate r with
-- forward speed v has tan(steer) = wheelbase * r / v. Yaw about +Y is counter-clockwise from above, which is a
-- left turn, so the sign flips for our (+ = right) convention.
local function inferSteer(self: WheelVisuals, dt: number, frame: CFrame): number
	local settings = Driving.wheelVisuals
	local forwardSpeed = self.chassis.AssemblyLinearVelocity:Dot(frame.LookVector)
	if math.abs(forwardSpeed) >= settings.inferMinSpeed and self.wheelbase > 0 then
		local yawRate = self.chassis.AssemblyAngularVelocity:Dot(frame.UpVector)
		local maxSteer = math.rad(settings.maxSteerDeg)
		local target = math.clamp(math.atan(-self.wheelbase * yawRate / forwardSpeed), -maxSteer, maxSteer)
		self.steer += (target - self.steer) * math.min(1, settings.steerSmoothing * dt)
	end
	return self.steer
end

-- Poses every wheel for this frame. `compressions` (hub travel above rest per wheel, + = up, in WHEEL_IDS
-- order) and `steerAngle` (radians, + = right) come from the owning chassis; leave them nil for other cars.
function WheelVisuals.update(self: WheelVisuals, dt: number, compressions: { number }?, steerAngle: number?)
	local chassis = self.chassis
	local frame = chassis.CFrame
	local steer = steerAngle or inferSteer(self, dt, frame)
	local linear = chassis.AssemblyLinearVelocity
	local angular = chassis.AssemblyAngularVelocity
	local center = chassis.AssemblyCenterOfMass
	local maxDroop = Driving.wheelVisuals.maxDroop

	for _, wheel in self.wheels do
		local offset = if compressions then compressions[wheel.slot] or 0 else castOffset(self, wheel, frame)
		offset = math.clamp(offset, -maxDroop, wheel.radius)

		-- Yaw about +Y turns the wheel left, so a right steer is a negative yaw.
		local yaw = if wheel.front then -steer else 0
		local heading = frame:VectorToWorldSpace(Vector3.new(-math.sin(yaw), 0, -math.cos(yaw)))
		local hubWorld = frame:PointToWorldSpace(wheel.hub)
		local hubVelocity = linear + angular:Cross(hubWorld - center)
		-- Rolling forward (-Z) turns the wheel's top forward, a negative rotation about X.
		wheel.spin = (wheel.spin - hubVelocity:Dot(heading) / wheel.radius * dt) % TWO_PI

		wheel.motor.Transform = CFrame.new(0, offset, 0) * CFrame.Angles(0, yaw, 0) * CFrame.Angles(wheel.spin, 0, 0)
	end
end

-- Puts every wheel back at rest and stops listening to the seats.
function WheelVisuals.destroy(self: WheelVisuals)
	self.stopFilter()
	for _, wheel in self.wheels do
		wheel.motor.Transform = CFrame.identity
	end
end

return WheelVisuals
