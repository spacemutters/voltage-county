--!strict
-- AutoDriver's route and control math: where the car is on its route, pure-pursuit steering, slowing for corners
-- and the finish, PI speed control that never brakes into reverse, and stuck counting. Pure math; runs in Edit
-- mode (driving a real car is a playtest job).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")

local Harness = require(ReplicatedStorage.Shared.Testing.Harness)

local Client = (StarterPlayer :: any).StarterPlayerScripts.Client
local AutoDriver = require(Client.Dev.AutoDriver)
local M = AutoDriver.Math

local GAINS = {
	speedKp = 0.12,
	speedKi = 0.04,
	integralLimit = 10,
	brakeGain = 0.15,
	brakeDeadbandMph = 2,
	reverseSafeMph = 4,
}

local LIMITS = {
	decel = 20,
	lateralAccel = 20,
	cornerSpan = 40,
	previewMargin = 30,
	minSpeed = 5,
	arriveSpeed = 3,
	arriveRadius = 10,
}

return function(t: Harness.Api)
	t.describe("AutoDriver route", function()
		-- 10 studs east, then 10 studs south (+Z).
		local corner = M.buildPath({ Vector3.new(0, 5, 0), Vector3.new(10, 0, 0), Vector3.new(10, 3, 10) })

		t.it("measures the route on the ground plane", function()
			t.expect(corner.length).toBeNear(20, 1e-9)
			t.expect(corner.along[2]).toBeNear(10, 1e-9)
			t.expect(corner.points[1].Y).toBe(0)
		end)

		t.it("finds how far along the route the car is", function()
			local segment, fraction, along = M.project(corner, Vector3.new(4, 7, 2), 1, 4)
			t.expect(segment).toBe(1)
			t.expect(fraction).toBeNear(0.4, 1e-9)
			t.expect(along).toBeNear(4, 1e-9)
		end)

		t.it("never goes back to an earlier segment", function()
			local segment, _, along = M.project(corner, Vector3.new(2, 0, 0), 2, 4)
			t.expect(segment).toBe(2)
			t.expect(along).toBeNear(10, 1e-9)
		end)

		t.it("finds points along the route, clamped to its ends", function()
			t.expect(M.pointAt(corner, 15)).toBe(Vector3.new(10, 0, 5))
			t.expect(M.pointAt(corner, -5)).toBe(corner.points[1])
			t.expect(M.pointAt(corner, 500)).toBe(corner.points[3])
		end)

		t.it("arrives only near the end of the route", function()
			t.expect(M.arrived(corner, 2, Vector3.new(2, 0, 0), 5)).toBe(false)
			t.expect(M.arrived(corner, 18, Vector3.new(10, 9, 8), 5)).toBe(true)
			-- Close along the route but far from the last point (cut across): not there yet.
			t.expect(M.arrived(corner, 18, Vector3.new(30, 0, 30), 5)).toBe(false)
		end)

		t.it("doesn't finish a closed loop at its start", function()
			-- A square lap that ends where it starts, like DevTrack.skidpadLoop.
			local lap = M.buildPath({
				Vector3.new(0, 0, 0),
				Vector3.new(100, 0, 0),
				Vector3.new(100, 0, 100),
				Vector3.new(0, 0, 100),
				Vector3.new(0, 0, 0),
			})
			t.expect(M.arrived(lap, 0, Vector3.new(0, 0, 0), 10)).toBe(false)
			t.expect(M.arrived(lap, 3, Vector3.new(3, 0, 0), 10)).toBe(false)
			t.expect(M.arrived(lap, 200, Vector3.new(100, 0, 100), 10)).toBe(false)
			t.expect(M.arrived(lap, 395, Vector3.new(0, 0, 5), 10)).toBe(true)
		end)

		t.it("measures how sharply the route turns", function()
			local a, b = Vector3.new(0, 0, 0), Vector3.new(10, 0, 0)
			t.expect(M.turnAngle(a, b, Vector3.new(20, 0, 0))).toBeNear(0, 1e-6)
			t.expect(M.turnAngle(a, b, Vector3.new(10, 0, 10))).toBeNear(math.pi / 2, 1e-6)
			t.expect(M.turnAngle(a, b, Vector3.new(0, 0, 0))).toBeNear(math.pi, 1e-6)
		end)
	end)

	t.describe("AutoDriver steering", function()
		-- Rear axle at the origin facing -Z (forward); +X is the car's right.
		local rear = CFrame.new()
		local maxSteer = math.rad(32)

		t.it("goes straight at a target dead ahead", function()
			local steer, curvature = M.pursuit(rear, Vector3.new(0, 0, -20), 3, maxSteer)
			t.expect(steer).toBeNear(0, 1e-9)
			t.expect(curvature).toBeNear(0, 1e-9)
		end)

		t.it("steers toward the side the target is on", function()
			t.expect((M.pursuit(rear, Vector3.new(4, 0, -20), 3, maxSteer))).toBeGreaterThan(0)
			t.expect((M.pursuit(rear, Vector3.new(-4, 0, -20), 3, maxSteer))).toBeLessThan(0)
		end)

		t.it("turns harder for a closer target at the same angle", function()
			local far = M.pursuit(rear, Vector3.new(2, 0, -20), 3, maxSteer)
			local near = M.pursuit(rear, Vector3.new(1, 0, -10), 3, maxSteer)
			t.expect(near).toBeGreaterThan(far)
		end)

		t.it("uses full lock for a target behind, and never more", function()
			t.expect((M.pursuit(rear, Vector3.new(-1, 0, 10), 3, maxSteer))).toBe(-1)
			t.expect((M.pursuit(rear, Vector3.new(1, 0, 10), 3, maxSteer))).toBe(1)
			t.expect((M.pursuit(rear, Vector3.new(5, 0, -1), 3, maxSteer))).toBe(1)
		end)
	end)

	t.describe("AutoDriver speed planning", function()
		t.it("cruises on a long straight and slows for the finish", function()
			local straight = M.buildPath({ Vector3.new(0, 0, 0), Vector3.new(0, 0, -1000) })
			t.expect(M.planSpeed(straight, 100, 50, LIMITS)).toBe(50)
			t.expect(M.planSpeed(straight, 985, 50, LIMITS)).toBeLessThan(20)
		end)

		t.it("slows before a sharp corner, more the closer it gets", function()
			local path = M.buildPath({
				Vector3.new(0, 0, 0),
				Vector3.new(0, 0, -500),
				Vector3.new(500, 0, -500),
				Vector3.new(500, 0, -1000),
			})
			local farAway = M.planSpeed(path, 300, 50, LIMITS)
			local closer = M.planSpeed(path, 470, 50, LIMITS)
			local closest = M.planSpeed(path, 490, 50, LIMITS)
			t.expect(farAway).toBe(50)
			t.expect(closer).toBeLessThan(50)
			t.expect(closest).toBeLessThan(closer)
		end)

		t.it("takes sharper and tighter corners slower", function()
			t.expect(M.cornerSpeed(0, 40, 20)).toBe(math.huge)
			t.expect(M.cornerSpeed(math.pi / 2, 40, 20)).toBeLessThan(M.cornerSpeed(math.pi / 6, 40, 20))
			t.expect(M.cornerSpeed(math.pi / 2, 10, 20)).toBeLessThan(M.cornerSpeed(math.pi / 2, 40, 20))
		end)
	end)

	t.describe("AutoDriver speed control", function()
		t.it("throttles when below target", function()
			local throttle, brake = M.speedControl({ integral = 0 }, 30, 0, 0.1, GAINS)
			t.expect(throttle).toBe(1)
			t.expect(brake).toBe(0)
		end)

		t.it("brakes when well over target at speed", function()
			local throttle, brake = M.speedControl({ integral = 0 }, 20, 40, 0.1, GAINS)
			t.expect(throttle).toBe(0)
			t.expect(brake).toBeGreaterThan(0)
		end)

		t.it("coasts when only a little over target", function()
			local throttle, brake = M.speedControl({ integral = 0 }, 30, 31, 0.1, GAINS)
			t.expect(throttle).toBe(0)
			t.expect(brake).toBe(0)
		end)

		t.it("never brakes at a crawl, where the brake engages reverse", function()
			local _, brake = M.speedControl({ integral = 0 }, 0, 3, 0.1, GAINS)
			t.expect(brake).toBe(0)
		end)

		t.it("caps the built-up error", function()
			local state = { integral = 0 }
			for _ = 1, 2000 do
				M.speedControl(state, 30, 29.5, 0.1, GAINS)
			end
			t.expect(state.integral).toBeNear(GAINS.integralLimit, 1e-9)
		end)
	end)

	t.describe("AutoDriver stuck detection", function()
		t.it("counts one event per stop longer than the limit", function()
			local state = { timer = 0, counted = false }
			local events = 0
			local function frames(count: number, mph: number)
				for _ = 1, count do
					if M.updateStuck(state, mph, 0.5, 2, 3) then
						events += 1
					end
				end
			end
			frames(5, 0) -- 2.5 s
			t.expect(events).toBe(0)
			frames(1, 0) -- 3.0 s
			t.expect(events).toBe(1)
			frames(20, 1) -- still crawling: the same event
			t.expect(events).toBe(1)
			frames(1, 10) -- moving again
			frames(6, 0)
			t.expect(events).toBe(2)
		end)
	end)
end
