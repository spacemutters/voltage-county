--!strict
-- Client driving logic that needs no car or character: drive-mode and regen cycling (DriveController), the UI
-- scale rule (HudController), and the brake lamps other players see, inferred from replicated speed
-- (VehicleVisualsController). Pure logic: runs in Edit mode.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")

local Controls = require(ReplicatedStorage.Shared.Config.Controls)
local Harness = require(ReplicatedStorage.Shared.Testing.Harness)
local ControllersFolder = StarterPlayer.StarterPlayerScripts.Client.Controllers
local DriveController = require(ControllersFolder.DriveController)
local HudController = require(ControllersFolder.HudController)
local VehicleVisualsController = require(ControllersFolder.VehicleVisualsController)

-- Fixed settings so the brake-lamp cases don't move when Config/Controls is tuned.
local BRAKE: VehicleVisualsController.BrakeSettings = {
	onDecel = 14,
	offDecel = 7,
	filterTime = 0.12,
	confirmTime = 0.08,
	minOnTime = 0.3,
	minSpeed = 3,
}

-- Drives a brake state through `seconds` of constant deceleration (studs/s^2, speed stops at zero) at `fps`.
-- Returns the speed reached, whether the lamp is lit at the end, and when it first lit (nil if it never did).
local function simulate(
	state: VehicleVisualsController.BrakeState,
	startSpeed: number,
	decel: number,
	seconds: number,
	fps: number
): (number, boolean, number?)
	local dt = 1 / fps
	local speed = startSpeed
	local firstLit: number? = nil
	local on = false
	for frame = 1, math.round(seconds * fps) do
		speed = math.max(speed - decel * dt, 0)
		on = VehicleVisualsController.updateBrakeState(state, speed, dt, BRAKE)
		if on and firstLit == nil then
			firstLit = frame * dt
		end
	end
	return speed, on, firstLit
end

return function(t: Harness.Api)
	t.describe("DriveController", function()
		t.it("cycles drive modes comfort, standard, sport and back", function()
			t.expect(DriveController.nextMode("comfort")).toBe("standard")
			t.expect(DriveController.nextMode("standard")).toBe("sport")
			t.expect(DriveController.nextMode("sport")).toBe("comfort")
		end)

		t.it("cycles regen levels low, standard, high and back", function()
			t.expect(DriveController.nextRegen("low")).toBe("standard")
			t.expect(DriveController.nextRegen("standard")).toBe("high")
			t.expect(DriveController.nextRegen("high")).toBe("low")
		end)

		t.it("starts from the first entry when the current value is unknown", function()
			t.expect(DriveController.nextMode("ludicrous" :: any)).toBe(Controls.modeCycle[1])
		end)

		t.it("is not driving in Edit mode", function()
			t.expect(DriveController.getCar()).toBe(nil)
			t.expect(DriveController.getTelemetry()).toBe(nil)
		end)
	end)

	t.describe("HudController.scaleFor", function()
		t.it("keeps a phone at scale 1", function()
			t.expect(HudController.scaleFor(Vector2.new(844, 390))).toBe(1)
		end)

		t.it("never scales below 1 on a tiny screen (touch targets stay 44 px)", function()
			t.expect(HudController.scaleFor(Vector2.new(568, 280))).toBe(1)
			t.expect(HudController.scaleFor(Vector2.zero)).toBe(1)
		end)

		t.it("scales up on bigger screens, capped at the configured maximum", function()
			local mid = HudController.scaleFor(Vector2.new(800, 460))
			t.expect(mid).toBeGreaterThan(1)
			t.expect(mid).toBeLessThan(Controls.hud.maxScale + 1e-9)
			t.expect(HudController.scaleFor(Vector2.new(1920, 1080))).toBe(Controls.hud.maxScale)
		end)
	end)

	t.describe("other cars' brake lamps", function()
		t.it("stay dark at a steady speed", function()
			local _, on, firstLit = simulate(VehicleVisualsController.newBrakeState(), 60, 0, 2, 60)
			t.expect(on).toBe(false)
			t.expect(firstLit).toBe(nil)
		end)

		t.it("light within a quarter second of hard braking, at 30, 60 and 144 fps", function()
			for _, fps in { 30, 60, 144 } do
				local _, on, firstLit = simulate(VehicleVisualsController.newBrakeState(), 60, 30, 0.5, fps)
				t.expect(on).toBe(true)
				t.expect(firstLit or math.huge).toBeLessThan(0.25)
			end
		end)

		t.it("stay dark while coasting or under light regen", function()
			local _, on, firstLit = simulate(VehicleVisualsController.newBrakeState(), 60, 4, 3, 60)
			t.expect(on).toBe(false)
			t.expect(firstLit).toBe(nil)
		end)

		t.it("ignore a one-frame speed dip from network jitter", function()
			for _, fps in { 30, 60, 144 } do
				local state = VehicleVisualsController.newBrakeState()
				local dt = 1 / fps
				local lit = false
				local speeds = { 60, 60, 60, 55, 60, 60, 60, 60, 60, 60 }
				for _, speed in speeds do
					lit = VehicleVisualsController.updateBrakeState(state, speed, dt, BRAKE) or lit
				end
				t.expect(lit).toBe(false)
			end
		end)

		t.it("go out after braking ends, but not before their minimum on-time", function()
			local state = VehicleVisualsController.newBrakeState()
			local speed, on = simulate(state, 60, 30, 0.5, 60)
			t.expect(on).toBe(true)
			-- One frame after letting go it is still lit; well after the filter settles it is dark.
			local _, stillOn = simulate(state, speed, 0, 1 / 60, 60)
			t.expect(stillOn).toBe(true)
			local _, laterOn = simulate(state, speed, 0, 0.5, 60)
			t.expect(laterOn).toBe(false)
		end)

		t.it("never light for a car that is barely moving", function()
			local _, on, firstLit = simulate(VehicleVisualsController.newBrakeState(), 2.5, 30, 0.5, 60)
			t.expect(on).toBe(false)
			t.expect(firstLit).toBe(nil)
		end)

		t.it("forget their history on reset", function()
			local state = VehicleVisualsController.newBrakeState()
			simulate(state, 60, 30, 0.5, 60)
			VehicleVisualsController.resetBrakeState(state)
			t.expect(state).toEqual(VehicleVisualsController.newBrakeState())
		end)
	end)
end
