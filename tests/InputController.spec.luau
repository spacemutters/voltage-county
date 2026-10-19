--!strict
-- Driving input (Controllers/InputController) and the controls config: gamepad deadzones, the keyboard and
-- touch steering ramp, merging input sources, the AutoDriver override, the shared signal, and the touch
-- layout's 44 px minimum. Pure logic: runs in Edit mode with no character.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")

local Controls = require(ReplicatedStorage.Shared.Config.Controls)
local Harness = require(ReplicatedStorage.Shared.Testing.Harness)
local Types = require(ReplicatedStorage.Shared.Types)
local InputController = require(StarterPlayer.StarterPlayerScripts.Client.Controllers.InputController)

local EPSILON = 1e-6
local NEUTRAL: Types.Controls = { throttle = 0, brake = 0, steer = 0, handbrake = false }

return function(t: Harness.Api)
	t.describe("InputController", function()
		t.describe("applyDeadzone", function()
			t.it("reads stick noise inside the deadzone as zero", function()
				t.expect(InputController.applyDeadzone(0.1, 0.15)).toBe(0)
				t.expect(InputController.applyDeadzone(-0.15, 0.15)).toBe(0)
			end)

			t.it("rescales the rest to the full range and keeps the sign", function()
				t.expect(InputController.applyDeadzone(1, 0.15)).toBeNear(1, EPSILON)
				t.expect(InputController.applyDeadzone(-1, 0.15)).toBeNear(-1, EPSILON)
				t.expect(InputController.applyDeadzone(0.575, 0.15)).toBeNear(0.5, EPSILON)
			end)

			t.it("shapes the response with a curve without reducing full lock", function()
				t.expect(InputController.applyDeadzone(0.575, 0.15, 2)).toBeNear(0.25, EPSILON)
				t.expect(InputController.applyDeadzone(-1, 0.15, 2)).toBeNear(-1, EPSILON)
			end)
		end)

		t.describe("rampSteer", function()
			local RAMP, RETURN = 4, 8

			-- Steps the ramp at a fixed frame rate for a whole number of frames.
			local function run(from: number, target: number, frames: number, fps: number): number
				local value = from
				for _ = 1, frames do
					value = InputController.rampSteer(value, target, 1 / fps, RAMP, RETURN)
				end
				return value
			end

			t.it("steers out at the ramp rate and stops at full lock", function()
				t.expect(InputController.rampSteer(0, 1, 0.1, RAMP, RETURN)).toBeNear(0.4, EPSILON)
				t.expect(InputController.rampSteer(0, -1, 0.1, RAMP, RETURN)).toBeNear(-0.4, EPSILON)
				t.expect(InputController.rampSteer(0.9, 1, 1, RAMP, RETURN)).toBe(1)
			end)

			t.it("returns to center at the faster return rate", function()
				t.expect(InputController.rampSteer(1, 0, 0.1, RAMP, RETURN)).toBeNear(0.2, EPSILON)
				t.expect(InputController.rampSteer(-1, 0, 1, RAMP, RETURN)).toBe(0)
			end)

			t.it("counter-steers through center, then ramps out the other way", function()
				-- 0.4 back to center takes 0.05 s at 8/s; the other 0.05 s ramps out at 4/s.
				t.expect(InputController.rampSteer(0.4, -1, 0.1, RAMP, RETURN)).toBeNear(-0.2, EPSILON)
			end)

			t.it("eases back to a smaller target on the same side without passing it", function()
				t.expect(InputController.rampSteer(1, 0.5, 0.05, RAMP, RETURN)).toBeNear(0.6, EPSILON)
				t.expect(InputController.rampSteer(1, 0.5, 1, RAMP, RETURN)).toBe(0.5)
			end)

			t.it("gives the same result at 30, 60, 120 and 240 fps", function()
				for _, fps in { 30, 60, 120, 240 } do
					-- 0.2 s in every case: steering out, then a full counter-steer from right lock.
					local frames = fps / 5
					t.expect(run(0, 1, frames, fps)).toBeNear(0.8, EPSILON)
					t.expect(run(1, -1, frames, fps)).toBeNear(-0.3, EPSILON)
				end
			end)
		end)

		t.describe("merge", function()
			t.it("takes the stronger pedal, the larger steer and either handbrake", function()
				local keys: Types.Controls = { throttle = 1, brake = 0, steer = -0.3, handbrake = false }
				local pad: Types.Controls = { throttle = 0.4, brake = 0.6, steer = 0.7, handbrake = true }
				t.expect(InputController.merge(keys, pad)).toEqual({
					throttle = 1,
					brake = 0.6,
					steer = 0.7,
					handbrake = true,
				})
			end)

			t.it("clamps out-of-range values", function()
				local wild: Types.Controls = { throttle = 3, brake = -1, steer = -5, handbrake = false }
				t.expect(InputController.merge(wild, NEUTRAL)).toEqual({
					throttle = 1,
					brake = 0,
					steer = -1,
					handbrake = false,
				})
			end)
		end)

		t.describe("getControls", function()
			t.it("is neutral while nothing is held", function()
				t.expect(InputController.getControls()).toEqual(NEUTRAL)
			end)

			t.it("lets the AutoDriver override win, and hands control back when cleared", function()
				local wanted: Types.Controls = { throttle = 0.3, brake = 0, steer = -0.5, handbrake = true }
				InputController.setOverride(wanted)
				wanted.throttle = 1 -- the override keeps its own copy
				t.expect(InputController.getControls()).toEqual({
					throttle = 0.3,
					brake = 0,
					steer = -0.5,
					handbrake = true,
				})
				InputController.setOverride(nil)
				t.expect(InputController.getControls()).toEqual(NEUTRAL)
			end)

			t.it("clamps touch pedal values", function()
				InputController.setTouchState({ throttle = 2, brake = -1, handbrake = true })
				local controls = InputController.getControls()
				InputController.setTouchState({ throttle = 0, brake = 0, steer = 0, handbrake = false })
				t.expect(controls.throttle).toBe(1)
				t.expect(controls.brake).toBe(0)
				t.expect(controls.handbrake).toBe(true)
			end)
		end)

		t.describe("actions", function()
			t.it("ignores one-shot actions while the player isn't driving", function()
				local fired = 0
				local connection = InputController.onCycleMode:Connect(function()
					fired += 1
				end)
				InputController.trigger("mode")
				connection:Disconnect()
				t.expect(InputController.isEnabled()).toBe(false)
				t.expect(fired).toBe(0)
			end)
		end)

		t.describe("signals", function()
			t.it("accepts listeners in every documented style and disconnects them", function()
				local signal = InputController.newSignal()
				local calls: { string } = {}
				local connection = signal:Connect(function(value: string)
					table.insert(calls, "connect:" .. value)
				end)
				signal.Event:Connect(function(value: string)
					table.insert(calls, "event:" .. value)
				end)
				table.insert(signal :: any, function(value: string)
					table.insert(calls, "list:" .. value)
				end)
				signal:Fire("a")
				connection:Disconnect()
				signal:Fire("b")
				t.expect(calls).toEqual({ "connect:a", "event:a", "list:a", "event:b", "list:b" })
			end)
		end)

		t.describe("hints", function()
			t.it("names the first bound key of each action", function()
				local keyboard = InputController.getHints("keyboard")
				t.expect(keyboard[1]).toEqual({ keys = "W/S", label = "Drive" })
				t.expect(#keyboard).toBe(#Controls.hints.keyboard)
				local gamepad = InputController.getHints("gamepad")
				t.expect(gamepad[1]).toEqual({ keys = "RT/LT", label = "Drive" })
				t.expect(#gamepad).toBe(#Controls.hints.gamepad)
			end)
		end)
	end)

	t.describe("Config/Controls", function()
		t.it("keeps every touch target at least 44 px", function()
			local touch = Controls.touch
			t.expect(touch.minTarget >= 44).toBe(true)
			for _, size in { touch.steerSize, touch.gasSize, touch.brakeSize, touch.handbrakeSize, touch.buttonSize } do
				t.expect(math.min(size.X, size.Y) >= touch.minTarget).toBe(true)
			end
			t.expect(Controls.devMenu.rowHeight >= touch.minTarget).toBe(true)
		end)

		t.it("never shrinks the UI below its laid-out size", function()
			t.expect(Controls.hud.maxScale >= 1).toBe(true)
		end)

		t.it("binds every keyboard action, and no key to two actions", function()
			local owner: { [Enum.KeyCode]: string } = {}
			for action, keys in Controls.keyboard :: { [string]: { Enum.KeyCode } } do
				t.expect(#keys > 0).toBe(true)
				for _, key in keys do
					t.expect(owner[key]).toBe(nil)
					owner[key] = action
				end
			end
		end)

		t.it("has deadzones inside 0..1 and ramp rates above zero", function()
			for _, deadzone in { Controls.deadzones.stick, Controls.deadzones.trigger } do
				t.expect(deadzone >= 0 and deadzone < 1).toBe(true)
			end
			t.expect(Controls.steerRamp.rampRate).toBeGreaterThan(0)
			t.expect(Controls.steerRamp.returnRate).toBeGreaterThan(0)
		end)

		t.it("starts in a drive mode and regen level that are in their cycles", function()
			t.expect(table.find(Controls.modeCycle, Controls.defaultMode) ~= nil).toBe(true)
			t.expect(table.find(Controls.regenCycle, Controls.defaultRegen) ~= nil).toBe(true)
		end)
	end)
end
