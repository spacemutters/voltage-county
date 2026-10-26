--!strict
-- The day/night cycle and the city's lighting look (docs/roast-2026-10-24.md point 3, docs/city/TECH.md §1):
-- Services/DayNightService's pure maths and Config/Environment's values. The scene asks for the Realistic look (lighting
-- style, Default tone mapper, shadows, sky light, a subtropical latitude); the clock runs a full day in the configured
-- minutes (24 by default), dawn to dawn, the night taking its share; clockAt and secondsAt undo each other; the clock
-- only ever moves forward; the night line (dusk on, dawn off) is crossed exactly twice a cycle; the sky blends between
-- keyframes and round midnight, nights stay readable on a phone and bloom more than days; and a night light's look by
-- day and by night, with its own colour, a stained kind's day colour, a light show's colour per night and a sign's
-- text brightness (tests/MapBuilder.spec and tests/City.spec check the builders' night lights all carry a kind the
-- service knows). Pure: runs in Edit mode.

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

-- How bright a colour looks (Rec. 709 luminance, 0..1).
local function luminance(color: Color3): number
	return 0.2126 * color.R + 0.7152 * color.G + 0.0722 * color.B
end

-- The spread between a colour's strongest and weakest channel (0..255): 0 is grey or white, more is more saturated.
local function spread(color: Color3): number
	return (math.max(color.R, color.G, color.B) - math.min(color.R, color.G, color.B)) * 255
end

local function keyframe(clock: number, value: number, brightness: number): Environment.Keyframe
	local color = Color3.new(value, value, value)
	return {
		clock = clock,
		ambient = color,
		outdoorAmbient = color,
		fogColor = color,
		atmosphereColor = color,
		atmosphereDecay = color,
		brightness = brightness,
		colorShiftTop = color,
		exposure = value,
		bloomIntensity = value,
		bloomThreshold = brightness,
	}
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
					-- Exposure is a nudge, not a second brightness; bloom glows without washing the frame out.
					t.expect(math.abs(frame.exposure)).toBeLessThan(1)
					t.expect(frame.bloomIntensity).toBeGreaterThan(0)
					t.expect(frame.bloomIntensity).toBeLessThan(1.5)
					t.expect(frame.bloomThreshold).toBeGreaterThan(1.5)
					-- The sun tint adds to the sun: kept small, so white walls never wash out.
					t.expect(luminance(frame.colorShiftTop)).toBeLessThan(0.3)
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

		t.describe("the scene", function()
			local scene = DAY_NIGHT.scene

			t.it("asks for the realistic look, lighting quality first", function()
				t.expect(scene.lightingStyle).toBe(Enum.LightingStyle.Realistic)
				t.expect(scene.prioritizeLightingQuality).toBe(true)
				t.expect(scene.toneMapper.preset).toBe(Enum.TonemapperPreset.Default)
				t.expect(#scene.toneMapper.name).toBeGreaterThan(0)
			end)

			t.it("puts the sun over a subtropical city, with crisp shadows and sky light", function()
				t.expect(scene.geographicLatitude).toBeNear(25.8, 0.5)
				t.expect(scene.globalShadows).toBe(true)
				t.expect(scene.shadowSoftness).toBeLessThan(0.2)
				t.expect(scene.environmentSpecularScale).toBe(1)
				t.expect(scene.environmentDiffuseScale).toBe(1)
			end)

			t.it("gives the bloom a radius, and the atmosphere a glare it can show", function()
				t.expect(scene.bloom.size).toBeGreaterThan(0)
				t.expect(#scene.bloom.name).toBeGreaterThan(0)
				local air = DAY_NIGHT.atmosphere
				t.expect(air.density).toBeGreaterThan(0)
				t.expect(air.density).toBeLessThan(0.4) -- the far skyline stays in view
				t.expect(air.glare == 0 or air.haze > 0).toBe(true) -- glare needs haze
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
			local frames: { Environment.Keyframe } = { keyframe(6, 0, 1), keyframe(18, 1, 3) }
			frames[2].outdoorAmbient = Color3.new(1, 0, 0)
			frames[2].fogColor = Color3.new(0, 1, 0)

			t.it("matches a keyframe on its clock", function()
				local look = DayNightService.lookAt(18, frames)
				t.expect(look.ambient).toBe(Color3.new(1, 1, 1))
				t.expect(look.brightness).toBe(3)
				t.expect(look.bloomThreshold).toBe(3)
				local real = DAY_NIGHT.keyframes[1]
				local first = DayNightService.lookAt(real.clock)
				t.expect(first.ambient).toBe(real.ambient)
				t.expect(first.atmosphereDecay).toBe(real.atmosphereDecay)
				t.expect(first.colorShiftTop).toBe(real.colorShiftTop)
				t.expect(first.exposure).toBe(real.exposure)
				t.expect(first.bloomIntensity).toBe(real.bloomIntensity)
			end)

			t.it("blends halfway between two keyframes", function()
				local look = DayNightService.lookAt(12, frames)
				t.expect(look.brightness).toBeNear(2, 1e-9)
				t.expect(look.ambient.R).toBeNear(0.5, 1e-6)
				t.expect(look.outdoorAmbient.R).toBeNear(0.5, 1e-6)
				t.expect(look.fogColor.G).toBeNear(0.5, 1e-6)
				t.expect(look.colorShiftTop.B).toBeNear(0.5, 1e-6)
				t.expect(look.exposure).toBeNear(0.5, 1e-9)
				t.expect(look.bloomIntensity).toBeNear(0.5, 1e-9)
				t.expect(look.bloomThreshold).toBeNear(2, 1e-9)
			end)

			t.it("blends round midnight from the last keyframe to the first", function()
				-- 18 -> 6 is 12 hours; midnight is halfway, 3 a.m. three quarters.
				t.expect(DayNightService.lookAt(0, frames).brightness).toBeNear(2, 1e-9)
				t.expect(DayNightService.lookAt(3, frames).brightness).toBeNear(1.5, 1e-9)
				t.expect(DayNightService.lookAt(21, frames).brightness).toBeNear(2.5, 1e-9)
				t.expect(DayNightService.lookAt(3, frames).exposure).toBeNear(0.25, 1e-9)
			end)

			t.it("is darker at midnight than at noon", function()
				local noon, midnight = DayNightService.lookAt(12), DayNightService.lookAt(0)
				t.expect(midnight.brightness).toBeLessThan(noon.brightness)
				t.expect(luminance(midnight.outdoorAmbient)).toBeLessThan(luminance(noon.outdoorAmbient))
				t.expect(luminance(midnight.ambient)).toBeLessThan(luminance(noon.ambient))
			end)

			t.it("keeps the night light enough to drive by on a phone, and blue rather than black", function()
				local midnight = DayNightService.lookAt(0)
				t.expect(midnight.brightness).toBeGreaterThan(1)
				t.expect(luminance(midnight.outdoorAmbient)).toBeGreaterThan(0.24)
				t.expect(luminance(midnight.ambient)).toBeGreaterThan(0.12)
				t.expect(midnight.exposure >= 0).toBe(true)
				for _, color in { midnight.outdoorAmbient, midnight.atmosphereColor } do
					t.expect(color.B).toBeGreaterThan(color.R)
					t.expect(color.B).toBeGreaterThan(color.G)
				end
			end)

			t.it("makes neon glow at night and keeps white walls from glowing by day", function()
				local noon, midnight = DayNightService.lookAt(12), DayNightService.lookAt(0)
				t.expect(noon.bloomThreshold).toBeGreaterThan(2 - 1e-9)
				t.expect(midnight.bloomThreshold).toBeLessThan(noon.bloomThreshold)
				t.expect(midnight.bloomIntensity).toBeGreaterThan(noon.bloomIntensity)
			end)

			t.it("lights the golden hour warm: redder than noon", function()
				local noon, golden = DayNightService.lookAt(12), DayNightService.lookAt(17.25)
				local function warmth(color: Color3): number
					return color.R - color.B
				end
				t.expect(warmth(golden.atmosphereColor)).toBeGreaterThan(warmth(noon.atmosphereColor))
				t.expect(warmth(golden.outdoorAmbient)).toBeGreaterThan(warmth(noon.outdoorAmbient))
				t.expect(warmth(golden.colorShiftTop)).toBeGreaterThan(warmth(noon.colorShiftTop))
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
				t.expect(DayNightService.signBrightness("disco", true)).toBe(nil)
			end)

			t.it("knows every kind the city's archetypes light", function()
				for _, kind in
					{
						"window",
						"sign",
						"streetlight",
						"floodlight",
						"beacon",
						"arch",
						"neonPink",
						"neonViolet",
						"neonAmber",
						"neonBlue",
						"neonCyan",
						"crown",
						"crownShow",
						"ledBlue",
						"ledEdge",
						"uplight",
						"stained",
					}
				do
					t.expect(`{kind}: {LIGHTS.kinds[kind] ~= nil}`).toBe(`{kind}: true`)
				end
			end)

			t.it("lights windows in a soft, lived-in glow, not an orange slab", function()
				local glow = LIGHTS.kinds.window.nightColor
				t.expect(math.max(glow.R, glow.G, glow.B) * 255).toBeLessThan(121)
				t.expect(spread(glow)).toBeLessThan(41)
				t.expect(glow.R >= glow.G and glow.G >= glow.B).toBe(true) -- warm
			end)

			t.it("keeps the neon and LEDs saturated and the crowns under white-hot", function()
				for kind, look in LIGHTS.kinds do
					local family = string.sub(kind, 1, 4)
					if family == "neon" or string.sub(kind, 1, 3) == "led" then
						t.expect(`{kind}: {spread(look.nightColor) >= 80}`).toBe(`{kind}: true`)
					end
					if string.sub(kind, 1, 5) == "crown" then
						local colors = { look.nightColor }
						for _, color in look.showColors or {} do
							table.insert(colors, color)
						end
						for _, color in colors do
							local weakest = math.min(color.R, color.G, color.B) * 255
							t.expect(`{kind}: {weakest <= 180}`).toBe(`{kind}: true`)
						end
					end
				end
			end)

			t.it("glows in a part's own night colour when it has one, by night only", function()
				local dayColor = Color3.fromRGB(240, 240, 236)
				local own = Color3.fromRGB(150, 80, 255)
				local material, color = DayNightService.nightLook("arch", true, dayColor, 3, own)
				t.expect(material).toBe(Enum.Material.Neon)
				t.expect(color).toBe(own)
				material, color = DayNightService.nightLook("arch", false, dayColor, 3, own)
				t.expect(material).toBe(LIGHTS.kinds.arch.dayMaterial)
				t.expect(color).toBe(dayColor)
			end)

			t.it("lights stained glass in its own colour", function()
				local panel = Color3.fromRGB(40, 90, 200)
				local material, color = DayNightService.nightLook("stained", true, panel, 1)
				t.expect(material).toBe(Enum.Material.Neon)
				t.expect(color).toBe(panel)
				material, color = DayNightService.nightLook("stained", false, panel, 1)
				t.expect(material).toBe(Enum.Material.Glass)
				t.expect(color).toBe(panel)
			end)

			t.it("puts on a light show some nights, one colour a night, the crown's white the rest", function()
				local show = LIGHTS.kinds.crownShow
				local colors = show.showColors or {}
				local share = show.showShare or 0
				t.expect(#colors).toBeGreaterThan(2)
				t.expect(share > 0 and share < 1).toBe(true)
				local nights, shown = 2000, 0
				local seen: { [Color3]: boolean } = {}
				for n = 1, nights do
					local color = DayNightService.showColor(show, n)
					t.expect(DayNightService.showColor(show, n)).toBe(color) -- the same all night
					local _, onPart = DayNightService.nightLook("crownShow", true, Color3.new(), n)
					t.expect(onPart).toBe(color) -- every part of the kind agrees
					if color ~= show.nightColor then
						shown += 1
						seen[color] = true
						t.expect(table.find(colors, color) ~= nil).toBe(true)
					end
				end
				t.expect(shown / nights).toBeNear(share, 0.06)
				for _, color in colors do
					t.expect(seen[color] == true).toBe(true)
				end
				-- A kind with no show is always its own colour.
				t.expect(DayNightService.showColor(LIGHTS.kinds.crown, 7)).toBe(LIGHTS.kinds.crown.nightColor)
			end)

			t.it("brightens a neon sign's lettering at night and puts it back by day", function()
				local night = DayNightService.signBrightness("sign", true)
				t.expect(night ~= nil and night > LIGHTS.dayGuiBrightness).toBe(true)
				t.expect(DayNightService.signBrightness("sign", false)).toBe(LIGHTS.dayGuiBrightness)
				t.expect(DayNightService.signBrightness("neonPink", true) ~= nil).toBe(true)
				t.expect(DayNightService.signBrightness("window", true)).toBe(nil)
			end)
		end)
	end)
end
