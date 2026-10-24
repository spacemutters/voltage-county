--!strict
-- The day/night cycle (docs/roast-2026-10-24.md point 3): Services/DayNightService's pure maths and Config/Environment's
-- values. The clock runs a full day in the configured minutes (24 by default), dawn to dawn, the night taking its
-- share; clockAt and secondsAt undo each other; the clock only ever moves forward; the night line (dusk on, dawn off)
-- is crossed exactly twice a cycle; the sky blends between keyframes and round midnight; and a night light's look by
-- day and by night (tests/MapBuilder.spec checks Dev/MapBuilder's night lights all carry a kind the service knows, on
-- the county plan it makes once). Pure: runs in Edit mode.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Environment = require(ReplicatedStorage.Shared.Config.Environment)
local Harness = require(ReplicatedStorage.Shared.Testing.Harness)
local DayNightService = require(ServerScriptService.Server.Services.DayNightService)

local DAY_NIGHT = Environment.dayNight
local LIGHTS = Environment.nightLights
local CLOCK_TOLERANCE = 1e-6 -- hours
local SECONDS_TOLERANCE = 1e-6

-- A made-up cycle with a long night, so the maths is checked on more than one shape.
local SHORT: Environment.Cycle = { dayLengthMinutes = 10, nightShare = 0.5, duskClock = 20, dawnClock = 5 }

-- How far the clock moved forward from a to b (hours), round midnight.
local function forward(a: number, b: number): number
	return (b - a) % 24
end

-- Hours between two clock readings either way round (23.9999 and 0 are close).
local function clockGap(a: number, b: number): number
	return math.min(forward(a, b), forward(b, a))
end

return function(t: Harness.Api)
	t.describe("Day and night", function()
		t.describe("config", function()
			t.it("runs a 24-minute day by default", function()
				t.expect(DAY_NIGHT.dayLengthMinutes).toBe(24)
				t.expect(DayNightService.cycleSeconds()).toBe(24 * 60)
			end)

			t.it("has a night shorter than the day, dusk in the evening and dawn in the morning", function()
				t.expect(DAY_NIGHT.nightShare).toBeGreaterThan(0)
				t.expect(DAY_NIGHT.nightShare).toBeLessThan(0.5)
				t.expect(DAY_NIGHT.duskClock).toBeGreaterThan(16.5)
				t.expect(DAY_NIGHT.duskClock).toBeLessThan(20.5)
				t.expect(DAY_NIGHT.dawnClock).toBeGreaterThan(4.5)
				t.expect(DAY_NIGHT.dawnClock).toBeLessThan(8)
				t.expect(DAY_NIGHT.stepSeconds).toBeGreaterThan(0)
				t.expect(DAY_NIGHT.stepSeconds).toBeLessThan(2)
			end)

			t.it("starts a new server in daylight", function()
				t.expect(DayNightService.isNight(DAY_NIGHT.startClock)).toBe(false)
			end)

			t.it("lists the sky's keyframes in clock order, within the day", function()
				local frames = DAY_NIGHT.keyframes
				t.expect(#frames).toBeGreaterThan(3)
				for i, frame in frames do
					t.expect(frame.clock >= 0 and frame.clock < 24).toBe(true)
					if i > 1 then
						t.expect(frame.clock).toBeGreaterThan(frames[i - 1].clock)
					end
					t.expect(frame.brightness).toBeGreaterThan(0)
				end
			end)

			t.it("gives every night light kind a day and a night material", function()
				local kinds = 0
				for _, look in LIGHTS.kinds do
					kinds += 1
					t.expect(typeof(look.dayMaterial)).toBe("EnumItem")
					t.expect(look.nightMaterial).toBe(Enum.Material.Neon)
				end
				t.expect(kinds).toBeGreaterThan(1)
				t.expect(LIGHTS.flipPerStep).toBeGreaterThan(0)
			end)
		end)

		t.describe("the clock", function()
			t.it("starts the cycle at dawn and reaches dusk after the day's share", function()
				for _, cycle in { DAY_NIGHT :: any, SHORT } do
					local total = DayNightService.cycleSeconds(cycle)
					local day = total * (1 - cycle.nightShare)
					local dawn, dusk = cycle.dawnClock, cycle.duskClock
					t.expect(clockGap(DayNightService.clockAt(0, cycle), dawn)).toBeLessThan(CLOCK_TOLERANCE)
					t.expect(clockGap(DayNightService.clockAt(day, cycle), dusk)).toBeLessThan(CLOCK_TOLERANCE)
					t.expect(clockGap(DayNightService.clockAt(total, cycle), dawn)).toBeLessThan(CLOCK_TOLERANCE)
					t.expect(clockGap(DayNightService.clockAt(-total, cycle), dawn)).toBeLessThan(CLOCK_TOLERANCE)
				end
			end)

			t.it("goes once round the clock per cycle, always forward", function()
				for _, cycle in { DAY_NIGHT :: any, SHORT } do
					local total = DayNightService.cycleSeconds(cycle)
					local steps = 1440
					local moved = 0
					local previous = DayNightService.clockAt(0, cycle)
					for i = 1, steps do
						local clock = DayNightService.clockAt(total * i / steps, cycle)
						local step = forward(previous, clock)
						t.expect(step).toBeLessThan(1) -- no jumps
						moved += step
						previous = clock
					end
					t.expect(moved).toBeNear(24, 1e-3)
				end
			end)

			t.it("spends the night's share of the cycle between dusk and dawn", function()
				for _, cycle in { DAY_NIGHT :: any, SHORT } do
					local total = DayNightService.cycleSeconds(cycle)
					local dusk = DayNightService.secondsAt(cycle.duskClock, cycle)
					local dawn = DayNightService.secondsAt(cycle.dawnClock, cycle)
					t.expect(dawn).toBeNear(0, SECONDS_TOLERANCE)
					t.expect(total - dusk).toBeNear(total * cycle.nightShare, SECONDS_TOLERANCE)
				end
				-- With the defaults: 8 of the 24 minutes are night.
				local total = DayNightService.cycleSeconds()
				local night = total - DayNightService.secondsAt(DAY_NIGHT.duskClock)
				t.expect(night).toBeNear(8 * 60, SECONDS_TOLERANCE)
			end)

			t.it("finds the seconds for any clock (secondsAt undoes clockAt)", function()
				for _, cycle in { DAY_NIGHT :: any, SHORT } do
					local total = DayNightService.cycleSeconds(cycle)
					for i = 0, 95 do
						local seconds = total * i / 96
						local clock = DayNightService.clockAt(seconds, cycle)
						t.expect(DayNightService.secondsAt(clock, cycle)).toBeNear(seconds, 1e-6 * total)
					end
					for clock = 0, 23.75, 0.25 do
						local seconds = DayNightService.secondsAt(clock, cycle)
						t.expect(seconds >= 0 and seconds < total).toBe(true)
						t.expect(clockGap(DayNightService.clockAt(seconds, cycle), clock)).toBeLessThan(CLOCK_TOLERANCE)
					end
				end
			end)
		end)

		t.describe("the night line", function()
			t.it("turns the lights on at dusk and off at dawn", function()
				local dusk, dawn = DAY_NIGHT.duskClock, DAY_NIGHT.dawnClock
				t.expect(DayNightService.isNight(dusk)).toBe(true)
				t.expect(DayNightService.isNight(dusk - 0.01)).toBe(false)
				t.expect(DayNightService.isNight(dawn)).toBe(false)
				t.expect(DayNightService.isNight(dawn - 0.01)).toBe(true)
				t.expect(DayNightService.isNight(0)).toBe(true)
				t.expect(DayNightService.isNight(12)).toBe(false)
				t.expect(DayNightService.isNight(23.99)).toBe(true)
				t.expect(DayNightService.isNight(24 + 12)).toBe(false) -- clocks wrap
			end)

			t.it("crosses the line exactly twice a cycle, at dusk then at dawn", function()
				for _, cycle in { DAY_NIGHT :: any, SHORT } do
					local total = DayNightService.cycleSeconds(cycle)
					local crossings: { boolean } = {}
					local previous = DayNightService.isNight(DayNightService.clockAt(0, cycle), cycle)
					for second = 1, total do
						local now = DayNightService.isNight(DayNightService.clockAt(second, cycle), cycle)
						if now ~= previous then
							table.insert(crossings, now)
						end
						previous = now
					end
					t.expect(crossings).toEqual({ true, false })
				end
			end)
		end)

		t.describe("the sky", function()
			local frames: { Environment.Keyframe } = {
				{
					clock = 6,
					ambient = Color3.new(0, 0, 0),
					outdoorAmbient = Color3.new(0, 0, 0),
					fogColor = Color3.new(0, 0, 0),
					atmosphereColor = Color3.new(0, 0, 0),
					atmosphereDecay = Color3.new(0, 0, 0),
					brightness = 1,
				},
				{
					clock = 18,
					ambient = Color3.new(1, 1, 1),
					outdoorAmbient = Color3.new(1, 0, 0),
					fogColor = Color3.new(0, 1, 0),
					atmosphereColor = Color3.new(0, 0, 1),
					atmosphereDecay = Color3.new(1, 1, 0),
					brightness = 3,
				},
			}

			t.it("matches a keyframe on its clock", function()
				local look = DayNightService.lookAt(18, frames)
				t.expect(look.ambient).toBe(Color3.new(1, 1, 1))
				t.expect(look.brightness).toBe(3)
				local real = DAY_NIGHT.keyframes[1]
				local first = DayNightService.lookAt(real.clock)
				t.expect(first.ambient).toBe(real.ambient)
				t.expect(first.atmosphereDecay).toBe(real.atmosphereDecay)
			end)

			t.it("blends halfway between two keyframes", function()
				local look = DayNightService.lookAt(12, frames)
				t.expect(look.brightness).toBeNear(2, 1e-9)
				t.expect(look.ambient.R).toBeNear(0.5, 1e-6)
				t.expect(look.outdoorAmbient.R).toBeNear(0.5, 1e-6)
				t.expect(look.fogColor.G).toBeNear(0.5, 1e-6)
			end)

			t.it("blends round midnight from the last keyframe to the first", function()
				-- 18 -> 6 is 12 hours; midnight is halfway, 3 a.m. three quarters.
				t.expect(DayNightService.lookAt(0, frames).brightness).toBeNear(2, 1e-9)
				t.expect(DayNightService.lookAt(3, frames).brightness).toBeNear(1.5, 1e-9)
				t.expect(DayNightService.lookAt(21, frames).brightness).toBeNear(2.5, 1e-9)
			end)

			t.it("is darker at midnight than at noon", function()
				local noon, midnight = DayNightService.lookAt(12), DayNightService.lookAt(0)
				t.expect(midnight.brightness).toBeLessThan(noon.brightness)
				local function light(color: Color3): number
					return color.R + color.G + color.B
				end
				t.expect(light(midnight.outdoorAmbient)).toBeLessThan(light(noon.outdoorAmbient))
				t.expect(light(midnight.ambient)).toBeLessThan(light(noon.ambient))
			end)
		end)

		t.describe("night lights", function()
			t.it("glow in the kind's night look and go back to their own colour by day", function()
				local dayColor = Color3.fromRGB(10, 20, 30)
				local look = LIGHTS.kinds.streetlight
				local material, color = DayNightService.nightLook("streetlight", true, dayColor)
				t.expect(material).toBe(look.nightMaterial)
				t.expect(color).toBe(look.nightColor)
				material, color = DayNightService.nightLook("streetlight", false, dayColor)
				t.expect(material).toBe(look.dayMaterial)
				t.expect(color).toBe(dayColor)
				local window = LIGHTS.kinds.window
				t.expect((DayNightService.nightLook("window", false, dayColor))).toBe(window.dayMaterial)
			end)

			t.it("leaves a kind it doesn't know alone", function()
				local material, color = DayNightService.nightLook("disco", true, Color3.new())
				t.expect(material).toBe(nil)
				t.expect(color).toBe(nil)
			end)
		end)
	end)
end
