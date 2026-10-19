--!strict
-- The powertrain, in the pure 1-D simulation: every drivable trim hits its catalog 0-60 and top speed in
-- Standard, drive modes only ever soften a car, and the pedals, reverse, regen and gearbox behave.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Catalog = require(ReplicatedStorage.Shared.Vehicle.Catalog)
local Driving = require(ReplicatedStorage.Shared.Config.Driving)
local Harness = require(ReplicatedStorage.Shared.Testing.Harness)
local Powertrain = require(ReplicatedStorage.Shared.Vehicle.Powertrain)
local Tuning = require(ReplicatedStorage.Shared.Vehicle.Tuning)
local Types = require(ReplicatedStorage.Shared.Types)
local Units = require(ReplicatedStorage.Shared.Util.Units)

local TOLERANCE = 0.03 -- the simulation must land within 3% of the catalog
local SAME = 1e-6 -- seconds; "not faster" allows for float noise only
local DT = 1 / 60

type TrimRef = { name: string, vehicleId: string, trimId: string, zeroToSixty: number, topSpeedMph: number }

local function drivableTrims(): { TrimRef }
	local list: { TrimRef } = {}
	for _, vehicleId in Catalog.vehicleIds() do
		local vehicle = Catalog.getVehicle(vehicleId)
		if vehicle and vehicle.playerDrivable then
			for _, trim in vehicle.trims do
				table.insert(list, {
					name = `{vehicleId}/{trim.id}`,
					vehicleId = vehicleId,
					trimId = trim.id,
					zeroToSixty = trim.zeroToSixtySec,
					topSpeedMph = trim.topSpeedMph,
				})
			end
		end
	end
	return list
end

local function tuningFor(ref: TrimRef): Tuning.Tuning
	local tuning = Tuning.forTrim(ref.vehicleId, ref.trimId)
	assert(tuning, `no tuning for {ref.name}`)
	return tuning
end

local function controls(throttle: number, brake: number): Types.Controls
	return { throttle = throttle, brake = brake, steer = 0, handbrake = false }
end

local function round(value: number): number
	return math.floor(value * 1000 + 0.5) / 1000
end

return function(t: Harness.Api)
	t.describe("Powertrain", function()
		t.it("hits the catalog 0-60 in Standard for every drivable trim", function()
			local problems: { string } = {}
			for _, ref in drivableTrims() do
				local seconds = Powertrain.simulateZeroToSixty(tuningFor(ref), "standard")
				if math.abs(seconds - ref.zeroToSixty) > ref.zeroToSixty * TOLERANCE then
					table.insert(problems, `{ref.name}: {round(seconds)} s, catalog {ref.zeroToSixty} s`)
				end
			end
			t.expect(problems).toEqual({})
		end)

		t.it("is slower in Comfort and never faster in Sport", function()
			local problems: { string } = {}
			for _, ref in drivableTrims() do
				local tuning = tuningFor(ref)
				local standard = Powertrain.simulateZeroToSixty(tuning, "standard")
				local comfort = Powertrain.simulateZeroToSixty(tuning, "comfort")
				local sport = Powertrain.simulateZeroToSixty(tuning, "sport")
				if comfort <= standard then
					table.insert(
						problems,
						`{ref.name}: comfort {round(comfort)} s is not slower than {round(standard)} s`
					)
				end
				if sport < standard - SAME then
					table.insert(problems, `{ref.name}: sport {round(sport)} s beats standard {round(standard)} s`)
				end
			end
			t.expect(problems).toEqual({})
		end)

		t.it("settles at the catalog top speed in Standard and never above it in any mode", function()
			local problems: { string } = {}
			for _, ref in drivableTrims() do
				local tuning = tuningFor(ref)
				local standard = Units.studsToMph(Powertrain.simulateTopSpeed(tuning, "standard"))
				if math.abs(standard - ref.topSpeedMph) > ref.topSpeedMph * TOLERANCE then
					table.insert(problems, `{ref.name}: settles at {round(standard)} mph, catalog {ref.topSpeedMph}`)
				end
				local comfort = Units.studsToMph(Powertrain.simulateTopSpeed(tuning, "comfort"))
				local sport = Units.studsToMph(Powertrain.simulateTopSpeed(tuning, "sport"))
				local ceiling = ref.topSpeedMph * (1 + TOLERANCE)
				if comfort > ceiling or sport > ceiling then
					table.insert(problems, `{ref.name}: comfort {round(comfort)} / sport {round(sport)} mph`)
				end
			end
			t.expect(problems).toEqual({})
		end)

		t.it("engages reverse only after the brake is held at a standstill, and leaves it on the throttle", function()
			local tuning = Tuning.forTrim("ohm_spark", "standard")
			assert(tuning, "spark tuning")
			local powertrain = Powertrain.new(tuning)

			local first = powertrain:update(DT, controls(0, 1), 0, "standard", "standard")
			t.expect(first.reversing).toBe(false)
			t.expect(first.driveAccel).toBe(0)

			local output = first
			for _ = 1, 60 do
				output = powertrain:update(DT, controls(0, 1), 0, "standard", "standard")
			end
			t.expect(output.reversing).toBe(true)
			t.expect(output.gear).toBe("R")
			t.expect(output.driveAccel).toBeLessThan(0)

			-- Throttle while rolling backwards brakes; at a standstill it shifts back to drive.
			local braking = powertrain:update(DT, controls(1, 0), -5, "standard", "standard")
			t.expect(braking.reversing).toBe(true)
			t.expect(braking.brakeAccel).toBeGreaterThan(0)
			local forward = powertrain:update(DT, controls(1, 0), 0, "standard", "standard")
			t.expect(forward.reversing).toBe(false)
			t.expect(forward.gear).toBe("D")
		end)

		t.it("does not engage reverse while braking from speed", function()
			local tuning = Tuning.forTrim("ohm_spark", "standard")
			assert(tuning, "spark tuning")
			local powertrain = Powertrain.new(tuning)
			local output = powertrain:update(DT, controls(0, 1), 40, "standard", "standard")
			for _ = 1, 120 do
				output = powertrain:update(DT, controls(0, 1), 40, "standard", "standard")
			end
			t.expect(output.reversing).toBe(false)
			t.expect(output.brakeAccel).toBeNear(tuning.brakeDecel, 1e-9)
		end)

		t.it("regenerates more on lift-off at a higher regen level", function()
			local tuning = Tuning.forTrim("ohm_spark", "standard")
			assert(tuning, "spark tuning")
			local function liftOff(level: Types.RegenLevel): number
				return Powertrain.new(tuning):update(DT, controls(0, 0), 60, "standard", level).brakeAccel
			end
			t.expect(liftOff("low")).toBeGreaterThan(0)
			t.expect(liftOff("standard")).toBeGreaterThan(liftOff("low"))
			t.expect(liftOff("high")).toBeGreaterThan(liftOff("standard"))
		end)

		t.it("fades lift-off regen in with the pedal instead of switching it", function()
			local tuning = Tuning.forTrim("ohm_spark", "standard")
			assert(tuning, "spark tuning")
			local function brakeAt(pedal: number): number
				return Powertrain.new(tuning):update(DT, controls(pedal, 0), 60, "standard", "standard").brakeAccel
			end
			local full = brakeAt(0)
			t.expect(full).toBeGreaterThan(0)
			-- Either side of the "pressed" threshold the regen barely differs.
			local threshold = Driving.powertrain.pedalThreshold
			t.expect(math.abs(brakeAt(threshold - 0.001) - brakeAt(threshold + 0.001))).toBeLessThan(full * 0.05)
			t.expect(brakeAt(Driving.powertrain.regenFadePedal)).toBe(0)
		end)

		t.it("keeps every drivable trim under 1.1x top speed on a 30-degree downhill", function()
			-- Anti-exploit resets anything over 1.15x top speed (Config/AntiExploit.speedTolerance).
			local slope = Workspace.Gravity * math.sin(math.rad(30))
			local problems: { string } = {}
			for _, ref in drivableTrims() do
				local tuning = tuningFor(ref)
				for _, mode in { "comfort", "standard", "sport" } :: { Types.DriveMode } do
					for _, throttle in { 0, 1 } do
						local powertrain = Powertrain.new(tuning)
						local speed = tuning.topSpeed
						for _ = 1, 60 / DT do
							-- "low" regen brakes least, so it is the worst case.
							local output = powertrain:update(DT, controls(throttle, 0), speed, mode, "low")
							local accel = output.driveAccel
								- Powertrain.resistance(tuning, speed)
								- output.brakeAccel
								+ slope
							speed = math.max(0, speed + accel * DT)
						end
						if speed > tuning.topSpeed * 1.1 then
							table.insert(
								problems,
								`{ref.name} {mode} throttle {throttle}: {round(speed / tuning.topSpeed)}x top speed`
							)
						end
					end
				end
			end
			t.expect(problems).toEqual({})
		end)

		t.it("holds a stopped car when no pedal is pressed", function()
			local tuning = Tuning.forTrim("ohm_spark", "standard")
			assert(tuning, "spark tuning")
			local output = Powertrain.new(tuning):update(DT, controls(0, 0), 0, "standard", "standard")
			t.expect(output.brakeAccel).toBeGreaterThan(0)
			t.expect(output.driveAccel).toBe(0)
		end)

		t.it("shifts a fuel car up through readable gears", function()
			local electric = Tuning.forTrim("ohm_spark", "standard")
			assert(electric, "spark tuning")
			-- A fuel version of the same car (no fuel car is in the catalog yet).
			local spec: Powertrain.Spec = table.clone(electric)
			spec.energy = "fuel"
			spec.gearSpeeds = {}
			for _, fraction in Driving.powertrain.fuel.gearSpeedFractions do
				table.insert(spec.gearSpeeds, electric.topSpeed * Driving.powertrain.topSpeedHeadroom * fraction)
			end

			local powertrain = Powertrain.new(spec)
			local speed = 0
			local seen: { [string]: boolean } = {}
			for _ = 1, 30 * 60 do
				local output = powertrain:update(DT, controls(1, 0), speed, "standard", "standard")
				seen[output.gear] = true
				speed += (output.driveAccel - Powertrain.resistance(spec, speed) - output.brakeAccel) * DT
			end
			t.expect(seen["1"]).toBe(true)
			t.expect(seen["2"]).toBe(true)
			t.expect(seen["3"]).toBe(true)
			t.expect(seen.D).toBe(nil)
			t.expect(Powertrain.simulateZeroToSixty(spec, "standard")).toBeLessThan(math.huge)
		end)
	end)
end
