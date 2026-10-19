--!strict
-- Driving camera: frame-rate independent smoothing, angle wrapping, speed-scaled field of view, the rule that
-- keeps the camera out of the car, and sane Config/Camera values. Pure math; runs in Edit mode.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")

local CameraConfig = require(ReplicatedStorage.Shared.Config.Camera)
local Harness = require(ReplicatedStorage.Shared.Testing.Harness)

local Client = (StarterPlayer :: any).StarterPlayerScripts.Client
local CameraMath = require(Client.Controllers.CameraController).Math

local TOLERANCE = 1e-9

return function(t: Harness.Api)
	t.describe("CameraController math", function()
		t.it("smooths the same at 30 and 144 fps", function()
			local function afterOneSecond(fps: number): number
				local value = 0
				for _ = 1, fps do
					value = CameraMath.approach(value, 1, CameraMath.smoothing(4, 1 / fps))
				end
				return value
			end
			t.expect(afterOneSecond(30)).toBeNear(afterOneSecond(144), TOLERANCE)
			t.expect(afterOneSecond(30)).toBeNear(1 - math.exp(-4), TOLERANCE)
		end)

		t.it("does not move on a zero or negative frame", function()
			t.expect(CameraMath.smoothing(5, 0)).toBe(0)
			t.expect(CameraMath.smoothing(5, -1)).toBe(0)
		end)

		t.it("wraps angles into [-pi, pi)", function()
			t.expect(CameraMath.wrapAngle(1.5 * math.pi)).toBeNear(-0.5 * math.pi, TOLERANCE)
			t.expect(CameraMath.wrapAngle(-1.5 * math.pi)).toBeNear(0.5 * math.pi, TOLERANCE)
			t.expect(CameraMath.wrapAngle(0.5)).toBeNear(0.5, TOLERANCE)
		end)

		t.it("turns the short way round across +-pi", function()
			-- From 3 rad to -3 rad is 0.28 rad through pi, not 6 rad the long way.
			local halfway = CameraMath.approachAngle(3, -3, 0.5)
			t.expect(math.abs(CameraMath.wrapAngle(halfway - math.pi))).toBeLessThan(1e-6)
		end)

		t.it("reads the heading back from a look direction", function()
			for _, yaw in { 0, 0.7, -2.1, 3 } do
				local look = CFrame.fromEulerAnglesYXZ(0, yaw, 0).LookVector
				t.expect(CameraMath.headingOf(look, 99)).toBeNear(yaw, 1e-6)
			end
			t.expect(CameraMath.headingOf(Vector3.yAxis, 1.25)).toBe(1.25)
		end)

		t.it("widens the field of view with speed, either direction", function()
			local range = { min = 70, max = 90, fullAtMph = 100 }
			t.expect(CameraMath.fovForSpeed(0, range)).toBe(70)
			t.expect(CameraMath.fovForSpeed(50, range)).toBeNear(80, TOLERANCE)
			t.expect(CameraMath.fovForSpeed(-50, range)).toBeNear(80, TOLERANCE)
			t.expect(CameraMath.fovForSpeed(250, range)).toBe(90)
		end)

		t.it("keeps the camera outside the car's clearance sphere", function()
			local center = Vector3.new(10, 2, 0)
			local inside = CameraMath.keepClear(center + Vector3.new(0, 0, 3), center, 8)
			t.expect((inside - center).Magnitude).toBeNear(8, 1e-6)
			t.expect(inside.Z).toBeGreaterThan(0)
			local outside = center + Vector3.new(0, 4, 12)
			t.expect(CameraMath.keepClear(outside, center, 8)).toBe(outside)
			t.expect(CameraMath.keepClear(center, center, 8)).toBe(center + Vector3.yAxis * 8)
		end)

		t.it("ignores small stick movements and still reaches full tilt", function()
			t.expect(CameraMath.applyDeadzone(Vector2.new(0.1, 0), 0.15)).toBe(Vector2.zero)
			t.expect(CameraMath.applyDeadzone(Vector2.new(0, 1), 0.15).Magnitude).toBeNear(1, 1e-6)
			t.expect(CameraMath.applyDeadzone(Vector2.new(0.2, 0), 0.15).X).toBeLessThan(0.1)
		end)

		t.it("scales distances with car length, within limits", function()
			t.expect(CameraMath.sizeScale(CameraConfig.referenceLength)).toBeNear(1, TOLERANCE)
			t.expect(CameraMath.sizeScale(1)).toBe(CameraConfig.minSizeScale)
			t.expect(CameraMath.sizeScale(1000)).toBe(CameraConfig.maxSizeScale)
		end)
	end)

	t.describe("Config/Camera", function()
		t.it("cycles through each view once", function()
			local seen = {}
			for _, mode in CameraConfig.modes do
				t.expect(mode == "chase" or mode == "orbit" or mode == "hood").toBe(true)
				t.expect(seen[mode]).toBe(nil)
				seen[mode] = true
			end
			t.expect(#CameraConfig.modes).toBeGreaterThan(0)
		end)

		t.it("has field of view ranges that make sense", function()
			for _, range in { CameraConfig.chase.fov, CameraConfig.hood.fov } do
				t.expect(range.min).toBeGreaterThan(0)
				t.expect(range.max).toBeLessThan(120)
				t.expect(range.max >= range.min).toBe(true)
				t.expect(range.fullAtMph).toBeGreaterThan(0)
			end
		end)

		t.it("keeps the orbit's resting pitch inside its limits", function()
			local orbit = CameraConfig.orbit
			t.expect(orbit.defaultPitch).toBeGreaterThan(orbit.minPitch)
			t.expect(orbit.defaultPitch).toBeLessThan(orbit.maxPitch)
			t.expect(orbit.maxPitch).toBeLessThan(90)
		end)

		t.it("places the chase camera outside a reference car", function()
			-- The Spark's body is about 14 x 6 x 4.6 studs (PLAN.md §5); its bounding sphere plus the clearance
			-- must sit closer than the chase camera, or the camera would be pushed every frame.
			local sphere = Vector3.new(6, 4.6, 14).Magnitude / 2 + CameraConfig.collision.carClearance
			local chase = CameraConfig.chase
			t.expect(Vector2.new(chase.distance, chase.height).Magnitude).toBeGreaterThan(sphere)
		end)
	end)
end
