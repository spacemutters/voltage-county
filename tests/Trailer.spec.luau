--!strict
-- Vehicle/Trailer's pure parts (docs/phase-8-contracts.md "Tests"): the spring and damper clamps, the hitch's
-- share of the weight, the sideways grip cap, the anti-jackknife yaw damping (it opposes the hitch's swing and
-- never reverses it), frame-rate invariance of the per-step impulses on a fixture, the brake input and the
-- articulation angle. Then Config/Trailers' own sanity, and every trailer Dev/TrailerBuilder builds following
-- the trailer contract with its kingpin at the Hauler's fifth-wheel height. Builds in memory only (assemble),
-- so it never touches ServerStorage.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local Catalog = require(ReplicatedStorage.Shared.Vehicle.Catalog)
local Driving = require(ReplicatedStorage.Shared.Config.Driving)
local Harness = require(ReplicatedStorage.Shared.Testing.Harness)
local Trailer = require(ReplicatedStorage.Shared.Vehicle.Trailer)
local Trailers = require(ReplicatedStorage.Shared.Config.Trailers)
local Tuning = require(ReplicatedStorage.Shared.Vehicle.Tuning)
local Types = require(ReplicatedStorage.Shared.Types)
local TrailerBuilder = require(ServerScriptService.Server.Dev.TrailerBuilder)
local VehicleBuilder = require(ServerScriptService.Server.Dev.VehicleBuilder)

local FRAME_RATES = { 30, 60, 144 } -- the frame rates physics must be stable and identical at
local SAME = 1e-6 -- plain number math
local NEAR = 1e-3 -- Vector3 / CFrame math is 32-bit
local MASSES = { 40, 1000, 25000 } -- any mass behaves the same
local MIN_SHARE = Driving.suspension.minLoadShare

-- A fixture trailer: a box-trailer-sized body (chassis space: front -Z), its hitch 22 studs ahead of the center
-- of mass and a tandem 7 behind it.
local FIXTURE = {
	mass = 1000,
	size = Vector3.new(8.5, 7.9, 28.8),
	hitchZ = -22.4,
	axleZ = 6.9,
	tractorMass = 1700,
	tractorSize = Vector3.new(8.5, 5.5, 24),
}

local function controls(throttle: number, brake: number): Types.Controls
	return { throttle = throttle, brake = brake, steer = 0, handbrake = false }
end

local function telemetry(speed: number, reversing: boolean): Types.Telemetry
	return {
		speed = speed,
		mph = 0,
		gear = if reversing then "R" else "D",
		mode = "standard",
		regen = "standard",
		throttle = 0,
		wheelsGrounded = 4,
		tractionActive = false,
		reversing = reversing,
	}
end

-- Ground-space height of an attachment on a model built at the origin (the pivot is the ground point).
local function heightOf(model: Model, attachment: Instance?): number
	assert(attachment and attachment:IsA("Attachment"), `{model.Name}: missing attachment`)
	return model:GetPivot():PointToObjectSpace(attachment.WorldPosition).Y
end

return function(t: Harness.Api)
	t.describe("Trailer physics", function()
		t.it("holds up exactly the trailer's weight at rest, at any mass and frame rate", function()
			local gravity = Workspace.Gravity
			for _, mass in MASSES do
				for _, share in { MIN_SHARE, 0.25, 0.5, 1 - MIN_SHARE } do
					for _, fps in FRAME_RATES do
						local dt = 1 / fps
						local stiffDt = math.min(dt, Driving.maxStepDt)
						-- Two axles, two sides: the hitch's share at the hitch, the rest on the four springs at rest.
						local total = Trailer.hitchSupportImpulse(mass, share, 1, gravity, dt)
						for _ = 1, 4 do
							local load = Trailer.wheelLoad(mass, share, 2, 0.5)
							total += Trailer.springImpulse(load, 0, gravity, dt, stiffDt)
						end
						t.expect(total / (mass * gravity * dt)).toBeNear(1, SAME)
					end
				end
			end
		end)

		t.it("splits the weight between hitch and axles by the center of mass, within bounds", function()
			local hitchZ, axleZ = -20, 10
			t.expect(Trailer.hitchShare(hitchZ, hitchZ, axleZ, MIN_SHARE)).toBeNear(1 - MIN_SHARE, SAME)
			t.expect(Trailer.hitchShare(axleZ, hitchZ, axleZ, MIN_SHARE)).toBeNear(MIN_SHARE, SAME)
			t.expect(Trailer.hitchShare(-5, hitchZ, axleZ, MIN_SHARE)).toBeNear(0.5, SAME)
			t.expect(Trailer.hitchShare(40, hitchZ, axleZ, MIN_SHARE)).toBeNear(MIN_SHARE, SAME)
			t.expect(Trailer.hitchShare(-60, hitchZ, axleZ, MIN_SHARE)).toBeNear(1 - MIN_SHARE, SAME)
		end)

		t.it("springs push in proportion to compression, stiffen on the bump stop and never pull", function()
			local gravity, dt = Workspace.Gravity, 1 / 60
			local omegaSquared = (2 * math.pi * 2) ^ 2
			local load, travel = 100, 1
			local soft = Trailer.springStiffness(0.5, omegaSquared, travel, 1)
			t.expect(soft).toBeNear(omegaSquared * 0.5, SAME)
			-- Past the bump stop the spring is stiffer than the plain spring would be.
			local stop = Trailer.springStiffness(1.5, omegaSquared, travel, 1)
			t.expect(stop).toBeGreaterThan(omegaSquared * 1.5)
			t.expect(Trailer.springStiffness(1.5, omegaSquared, travel, 0)).toBeNear(omegaSquared * 1.5, SAME)
			-- Fully extended (past its free length) a spring gives nothing, never a pull.
			local free = Trailer.springStiffness(-10, omegaSquared, travel, 1)
			t.expect(Trailer.springImpulse(load, free, gravity, dt, dt)).toBe(0)
			t.expect(Trailer.springImpulse(load, soft, gravity, dt, dt)).toBeGreaterThan(load * gravity * dt)
		end)

		t.it("dampers oppose the motion, stop at most their own share and never out-pull the spring", function()
			local load, stiffDt = 250, 1 / 60
			local huge = 1e9 -- a damping coefficient far past critical
			for _, relative in { -30, -1, 1, 30 } do
				local impulse = Trailer.damperImpulse(load, relative, huge, stiffDt, math.huge)
				t.expect(impulse * relative).toBeLessThan(0)
				t.expect(math.abs(impulse)).toBeLessThan(load * math.abs(relative) + SAME)
			end
			-- Extending fast with a weak spring: the damper may not pull down harder than the spring pushes up.
			local spring = 5
			t.expect(Trailer.damperImpulse(load, 30, huge, stiffDt, spring)).toBeNear(-spring, SAME)
			-- Gentle motion with real damping: exactly -c * v * dt.
			local damping = 2 * 0.6 * load * (2 * math.pi * 2)
			t.expect(Trailer.damperImpulse(load, 0.01, damping, stiffDt, math.huge))
				.toBeNear(-0.01 * damping * stiffDt, SAME)
		end)

		t.it("sideways grip opposes sliding, never reverses it and respects the friction limit", function()
			for _, fps in FRAME_RATES do
				local response = Trailer.lateralResponse(18, 1 / fps)
				t.expect(response).toBeGreaterThan(0)
				t.expect(response).toBeLessThan(Driving.tires.maxLateralCancel + SAME)
				for _, sideSpeed in { -12, -0.5, 0.5, 12 } do
					local impulse = Trailer.lateralImpulse(300, sideSpeed, response, math.huge)
					t.expect(impulse * sideSpeed).toBeLessThan(0)
					t.expect(math.abs(impulse)).toBeLessThan(300 * math.abs(sideSpeed) + SAME)
					t.expect(math.abs(Trailer.lateralImpulse(300, sideSpeed, response, 2))).toBeLessThan(2 + SAME)
				end
			end
		end)

		t.it("caps sideways grip at the effective mass, which cancels the axle's sliding exactly", function()
			local mass = FIXTURE.mass
			local inertia = Trailer.boxInertia(mass, FIXTURE.size)
			t.expect(Trailer.effectiveMass(mass, inertia.Y, 0)).toBeNear(mass, NEAR)
			local lever = FIXTURE.axleZ
			local effective = Trailer.effectiveMass(mass, inertia.Y, lever)
			t.expect(effective).toBeLessThan(mass)
			-- A free body sliding sideways at 10 studs/s at the axle: an impulse of effective mass x that speed at
			-- the axle stops the axle's sliding (center slides less, body turns), no more, no less.
			local sliding = 10
			local impulse = Trailer.lateralImpulse(effective, sliding, 1, math.huge)
			local axleChange = impulse / mass + impulse * lever * lever / inertia.Y
			t.expect(sliding + axleChange).toBeNear(0, NEAR)
		end)

		t.it("damps the hitch's swing against the tractor and never reverses it", function()
			local trailerInertia = Trailer.boxInertia(FIXTURE.mass, FIXTURE.size).Y
			local tractorInertia = Trailer.boxInertia(FIXTURE.tractorMass, FIXTURE.tractorSize).Y
			local reduced = Trailer.reducedInertia(trailerInertia, tractorInertia)
			t.expect(reduced).toBeLessThan(math.min(trailerInertia, tractorInertia))
			local rate = Trailers.trailers.box_trailer.yawDampingRate
			for _, relative in { -2, -0.1, 0.1, 2 } do
				for _, fps in FRAME_RATES do
					local impulse = Trailer.yawDampingImpulse(relative, reduced, rate, 1 / fps)
					t.expect(impulse * relative).toBeLessThan(0) -- opposes the swing
					-- Trailer gets +impulse, tractor -impulse: the swing changes by impulse * (1/I1 + 1/I2), never
					-- more than the whole swing; the pinned hitch only adds inertia, so real bodies change less.
					local change = impulse * (1 / trailerInertia + 1 / tractorInertia)
					t.expect(math.abs(change)).toBeLessThan(math.abs(relative) + SAME)
					t.expect((relative + change) * relative).toBeGreaterThan(0)
				end
			end
		end)

		t.it("gives the same result over a second at 30, 60 and 144 fps (fixture)", function()
			local gravity = Workspace.Gravity
			local mass = FIXTURE.mass
			local trailerInertia = Trailer.boxInertia(mass, FIXTURE.size).Y
			local tractorInertia = Trailer.boxInertia(FIXTURE.tractorMass, FIXTURE.tractorSize).Y
			local reduced = Trailer.reducedInertia(trailerInertia, tractorInertia)
			local rate = Trailers.trailers.box_trailer.yawDampingRate
			local lateralRate = Trailers.trailers.box_trailer.lateralGripRate
			local spec = Trailers.trailers.box_trailer

			local results: { { support: number, swing: number, sliding: number, speed: number } } = {}
			for _, fps in FRAME_RATES do
				local dt = 1 / fps
				local support, swing, sliding = 0, 1, 1 -- weight held, hitch swing rate, sideways sliding
				local speed = 30 -- studs/s under full brake
				for _ = 1, fps do
					support += Trailer.hitchSupportImpulse(mass, 0.3, 1, gravity, dt) + Trailer.springImpulse(
						mass * 0.7,
						0,
						gravity,
						dt,
						math.min(dt, Driving.maxStepDt)
					)
					local yaw = Trailer.yawDampingImpulse(swing, reduced, rate, dt)
					swing += yaw * (1 / trailerInertia + 1 / tractorInertia)
					sliding += Trailer.lateralImpulse(
						mass,
						sliding,
						Trailer.lateralResponse(lateralRate, dt),
						math.huge
					) / mass
					local brake = math.min(mass * Trailer.brakeDecel(1, spec.brakeDecel, speed, nil) * dt, mass * speed)
					speed -= brake / mass
				end
				table.insert(results, { support = support, swing = swing, sliding = sliding, speed = speed })
			end
			for _, result in results do
				-- A second of weight support is the trailer's weight times a second.
				t.expect(result.support / (mass * gravity)).toBeNear(1, SAME)
				-- The hitch's swing and the tires' sliding decay exponentially: the same at every frame rate.
				t.expect(result.swing / math.exp(-rate)).toBeNear(1, SAME)
				t.expect(result.sliding / math.exp(-lateralRate)).toBeNear(1, SAME)
				-- Full brake stops the trailer from 30 studs/s inside the second, at zero, never reversed.
				t.expect(result.speed).toBe(0)
			end
		end)

		t.it("keeps the stiffest suspension mode stable on slow frames", function()
			local omegaSquared = (2 * math.pi * Trailers.trailers.box_trailer.suspensionFrequency) ^ 2
			for _, modeRatio in { 1, 3, 8 } do
				local springScale = Trailer.stiffnessScales(omegaSquared, modeRatio, Driving.maxStepDt)
				local step = omegaSquared * springScale * modeRatio * Driving.maxStepDt ^ 2
				t.expect(step).toBeLessThan(Driving.suspension.maxModeStep + SAME)
			end
			-- At 60 fps the box trailer's springs are untouched.
			local atSixty = Trailer.stiffnessScales(omegaSquared, 3, 1 / 60)
			t.expect(atSixty).toBe(1)
		end)

		t.it("brakes with the tractor's slowing pedal, holds at a standstill and coasts gently", function()
			local decel = Trailers.trailers.box_trailer.brakeDecel
			local powertrain = Driving.powertrain
			local liftOff = Trailer.liftOffDecel("battery", "standard", "standard")
			t.expect(Trailer.brakeInput(controls(0, 0.7), telemetry(30, false), decel, liftOff)).toBeNear(0.7, SAME)
			-- In reverse the throttle slows the rig and the brake pedal drives it backwards.
			t.expect(Trailer.brakeInput(controls(0.6, 0), telemetry(-5, true), decel, liftOff)).toBeNear(0.6, SAME)
			t.expect(Trailer.brakeInput(controls(0, 0.8), telemetry(-5, true), decel, liftOff)).toBe(0)
			t.expect(Trailer.brakeInput(controls(1, 0), telemetry(30, false), decel, liftOff)).toBe(0)
			-- Off both pedals: the hold brake at a standstill (also with no telemetry yet)...
			t.expect(Trailer.brakeInput(controls(0, 0), telemetry(0, false), decel, liftOff))
				.toBeNear(powertrain.holdBrakeFraction, SAME)
			t.expect(Trailer.brakeInput(controls(0, 0), nil, decel, liftOff))
				.toBeNear(powertrain.holdBrakeFraction, SAME)
			-- ...and a coast brake while rolling: the tractor's lift-off plus the margin, fading out at low speed
			-- and in as the drive pedal comes up, like the tractor's own.
			local coast = liftOff + Trailers.coastMargin
			local fast = powertrain.liftOffFullSpeed * 2
			t.expect(Trailer.brakeInput(controls(0, 0), telemetry(fast, false), decel, liftOff))
				.toBeNear(coast / decel, SAME)
			local slow = powertrain.liftOffFullSpeed / 2
			t.expect(Trailer.brakeInput(controls(0, 0), telemetry(slow, false), decel, liftOff))
				.toBeNear(coast / 2 / decel, SAME)
			local feather = powertrain.regenFadePedal / 2
			t.expect(Trailer.brakeInput(controls(feather, 0), telemetry(fast, false), decel, liftOff))
				.toBeNear(coast / 2 / decel, SAME)
		end)

		t.it("coasts at least as hard as the tractor's lift-off at every regen level and mode", function()
			for mode, shaping in Driving.modes do
				for level, regen in Driving.powertrain.regenDecel do
					local liftOff = Trailer.liftOffDecel("battery", mode :: any, level :: any)
					t.expect(liftOff).toBeNear(regen * shaping.regenScale, SAME)
				end
			end
			t.expect(Trailer.liftOffDecel("fuel", "sport", "high")).toBe(Driving.powertrain.engineBrakeDecel)
		end)

		t.it("brakes harder than every tractor that can pull it, so it never pushes", function()
			t.expect(Trailers.brakeRatio).toBeGreaterThan(1)
			t.expect(Trailer.brakeDecelFor(Trailers.towed, nil)).toBe(Trailers.towed.brakeDecel)
			t.expect(Trailer.brakeDecelFor(Trailers.towed, 100)).toBeNear(100 * Trailers.brakeRatio, SAME)
			local checked = 0
			for _, vehicleId in Catalog.vehicleIds() do
				local vehicle = Catalog.getVehicle(vehicleId)
				if vehicle == nil then
					continue
				end
				local specs: { Trailer.Spec } = {}
				if table.find(vehicle.features, "towHitch") ~= nil then
					table.insert(specs, Trailers.towed)
				end
				if table.find(vehicle.features, "kingpin") ~= nil then
					for _, spec in Trailers.trailers do
						table.insert(specs, spec)
					end
				end
				for _, trim in vehicle.trims do
					local tuning = Tuning.forTrim(vehicleId, trim.id)
					if tuning == nil then
						continue
					end
					for _, spec in specs do
						-- Even the spec's own floor out-brakes the stock truck.
						t.expect(spec.brakeDecel).toBeGreaterThan(tuning.brakeDecel)
						t.expect(Trailer.brakeDecelFor(spec, tuning.brakeDecel)).toBeGreaterThan(tuning.brakeDecel)
						checked += 1
					end
				end
			end
			t.expect(checked).toBeGreaterThan(0)
		end)

		t.it("brakes harder above the tractor's top speed", function()
			local gain = Driving.powertrain.overspeedBrakeGain
			t.expect(Trailer.brakeDecel(0, 38, 100, 90)).toBeNear(gain * 10, SAME)
			t.expect(Trailer.brakeDecel(0, 38, 80, 90)).toBe(0)
			t.expect(Trailer.brakeDecel(1, 38, 80, nil)).toBeNear(38, SAME)
			t.expect(Trailer.brakeDecel(2, 38, 80, nil)).toBeNear(38, SAME) -- input clamps to 0..1
		end)

		t.it("measures articulation as the heading angle in the tractor's ground plane", function()
			local tractor = CFrame.new(10, 2, -4)
			t.expect(Trailer.articulation(tractor, tractor)).toBeNear(0, NEAR)
			local quarter = tractor * CFrame.Angles(0, math.rad(90), 0)
			t.expect(math.deg(Trailer.articulation(tractor, quarter))).toBeNear(90, NEAR)
			-- Pitch and roll between the two don't count.
			local pitched = tractor * CFrame.Angles(math.rad(20), 0, math.rad(10))
			t.expect(math.deg(Trailer.articulation(tractor, pitched))).toBeNear(0, NEAR)
			local jackknifed = tractor * CFrame.Angles(0, math.rad(Trailers.jackknifeAngle + 5), 0)
			local turning = tractor * CFrame.Angles(0, math.rad(Trailers.jackknifeAngle - 15), 0)
			t.expect(Trailer.isJackknifed(tractor, jackknifed)).toBe(true)
			t.expect(Trailer.isJackknifed(tractor, turning)).toBe(false)
		end)

		t.it("picks the spec and hitch settings from the model's attributes", function()
			local towed = Instance.new("Model")
			towed:SetAttribute(Trailers.towedAttribute, true)
			local trailer = Instance.new("Model")
			trailer:SetAttribute(Trailers.idAttribute, "tanker_trailer")
			local named = Instance.new("Model")
			named.Name = "flatbed_trailer"
			local other = Instance.new("Model")
			t.expect(rawequal(Trailer.specFor(towed), Trailers.towed)).toBe(true)
			t.expect(rawequal(Trailer.specFor(trailer), Trailers.trailers.tanker_trailer)).toBe(true)
			t.expect(rawequal(Trailer.specFor(named), Trailers.trailers.flatbed_trailer)).toBe(true)
			t.expect(Trailer.specFor(other)).toBe(nil)
			t.expect(rawequal(Trailer.hitchSettingsFor(towed), Trailers.towed.hitch)).toBe(true)
			t.expect(rawequal(Trailer.hitchSettingsFor(trailer), Trailers.hitch)).toBe(true)
			for _, model in { towed, trailer, named, other } do
				model:Destroy()
			end
		end)
	end)

	t.describe("Config/Trailers", function()
		t.it("lets the hitch swing a little past a jackknife, and pitch both ways", function()
			t.expect(Trailers.hitch.upperAngle).toBeGreaterThan(Trailers.jackknifeAngle)
			t.expect(Trailers.hitch.upperAngle).toBeLessThan(90)
			for _, hitch in { Trailers.hitch, Trailers.towed.hitch } do
				t.expect(hitch.limitsEnabled).toBe(true)
				t.expect(hitch.twistLimitsEnabled).toBe(true)
				t.expect(hitch.twistLowerAngle).toBeLessThan(0)
				t.expect(hitch.twistUpperAngle).toBeGreaterThan(0)
			end
		end)

		t.it("describes every trailer consistently", function()
			for id, spec in Trailers.trailers do
				t.expect(spec.id).toBe(id)
				t.expect(spec.hitchAttachment).toBe("Kingpin")
				t.expect(#spec.groundWheels).toBe(2 * #spec.axles)
				for _, axle in spec.axles do
					t.expect(table.find(spec.groundWheels, axle.id .. "L") ~= nil).toBe(true)
					t.expect(table.find(spec.groundWheels, axle.id .. "R") ~= nil).toBe(true)
					t.expect(axle.fromBack).toBeGreaterThan(spec.wheelRadius)
				end
				t.expect(spec.massRatio).toBeGreaterThan(0)
				t.expect(spec.track / 2 + spec.wheelWidth / 2).toBeLessThan(spec.width / 2)
				-- The deck clears the tires.
				t.expect(Trailers.kingpinHeight).toBeGreaterThan(2 * spec.wheelRadius)
			end
		end)

		t.it("starts a trailer's physics box clear of the Hauler's at any articulation", function()
			local reference = Trailers.referenceTractor
			local hauler = VehicleBuilder.assemble(reference.vehicleId, reference.trimId)
			local chassis = hauler:FindFirstChild("Chassis") :: Part
			local kingpin = chassis:FindFirstChild("Kingpin") :: Attachment
			local half = chassis.Size / 2
			-- The Hauler's box reaches farthest from its kingpin at its rear corners; a trailer box that starts
			-- farther than that behind the kingpin can't touch it however the hitch turns.
			local farthest = 0
			for _, x in { -half.X, half.X } do
				for _, y in { -half.Y, half.Y } do
					farthest = math.max(farthest, (Vector3.new(x, y, half.Z) - kingpin.Position).Magnitude)
				end
			end
			hauler:Destroy()
			t.expect(Trailers.chassisGap).toBeGreaterThan(farthest)
		end)

		t.it("puts every car's TowPoint below every TowHitch, so towing lifts its front wheels", function()
			local lowestHitch = math.huge
			for _, vehicleId in Catalog.vehicleIds() do
				local vehicle = Catalog.getVehicle(vehicleId)
				if vehicle == nil or table.find(vehicle.features, "towHitch") == nil then
					continue
				end
				local model = VehicleBuilder.assemble(vehicleId, vehicle.trims[1].id)
				lowestHitch = math.min(lowestHitch, heightOf(model, (model :: any).Chassis:FindFirstChild("TowHitch")))
				model:Destroy()
			end
			t.expect(lowestHitch).toBeLessThan(math.huge)
			t.expect(lowestHitch).toBeGreaterThan(Trailers.towed.towPointHeight)
		end)
	end)

	t.describe("TrailerBuilder", function()
		local reference = Trailers.referenceTractor
		for id in Trailers.trailers do
			t.it(`builds {id} to the trailer contract, coupling level with the Hauler`, function()
				local model = TrailerBuilder.assemble(id)
				local problems = TrailerBuilder.check(model)
				for _, message in problems do
					print(`  contract: {message}`)
				end
				t.expect(#problems).toBe(0)

				local hauler = VehicleBuilder.assemble(reference.vehicleId, reference.trimId)
				local haulerChassis = (hauler :: any).Chassis :: Part
				local chassis = (model :: any).Chassis :: Part
				local haulerKingpin = heightOf(hauler, haulerChassis:FindFirstChild("Kingpin"))
				t.expect(haulerKingpin).toBeNear(Trailers.kingpinHeight, NEAR)
				t.expect(heightOf(model, chassis:FindFirstChild("Kingpin"))).toBeNear(haulerKingpin, NEAR)
				t.expect(chassis:GetMass() / haulerChassis:GetMass()).toBeNear(Trailers.trailers[id].massRatio, NEAR)
				hauler:Destroy()
				model:Destroy()
			end)
		end

		t.it("gives every car a TowPoint ahead of its front, low and facing back", function()
			local model = VehicleBuilder.assemble("ohm_spark", "standard")
			local chassis = (model :: any).Chassis :: Part
			local point = chassis:FindFirstChild("TowPoint")
			t.expect(heightOf(model, point)).toBeNear(Trailers.towed.towPointHeight, NEAR)
			local pose = (point :: Attachment).CFrame
			t.expect(pose.Position.Z).toBeNear(-chassis.Size.Z / 2 - Trailers.towed.towPointAhead, NEAR)
			t.expect(pose.LookVector.Z).toBeNear(1, NEAR) -- faces back, like a TowHitch
			model:Destroy()
		end)
	end)
end
