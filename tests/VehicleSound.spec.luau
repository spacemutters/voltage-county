--!strict
-- Car sounds (roast fixes, 2026-10-24): Controllers/VehicleSoundController's pure parts. The fuel engine revs
-- through the chassis's own automatic (Config/Driving powertrain.fuel) and its pitch drops on every upshift; the
-- electric whine rises with speed; the throttle read from another car's acceleration; tyre squeal past the slip
-- threshold; wind at highway speed; which cars get engines (nearest first); and sane Config/Audio values (every loop
-- a fuel car can pick exists, every id whole). Pure logic: runs in Edit mode.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")

local Harness = require(ReplicatedStorage.Shared.Testing.Harness)
local Audio = require(ReplicatedStorage.Shared.Config.Audio)
local Catalog = require(ReplicatedStorage.Shared.Vehicle.Catalog)
local Driving = require(ReplicatedStorage.Shared.Config.Driving)
local Tuning = require(ReplicatedStorage.Shared.Vehicle.Tuning)
local Vehicles = require(ReplicatedStorage.Shared.Config.Vehicles)

local VehicleSoundController = require(StarterPlayer.StarterPlayerScripts.Client.Controllers.VehicleSoundController)

local car = Audio.car
local fuel = Driving.powertrain.fuel
local GEARS = { 20, 35, 50, 70, 95 } -- studs/s, a made-up five-speed (each gear's top)
local DT = 1 / 60

-- Accelerates a gearbox evenly from a standstill to `top` (studs/s) over `seconds`, returning every frame's gear and
-- revs.
local function runUp(gears: { number }, top: number, seconds: number): ({ number }, { number })
	local box = VehicleSoundController.newGearbox()
	local gearsSeen: { number } = {}
	local revsSeen: { number } = {}
	local frames = math.round(seconds / DT)
	for frame = 0, frames do
		local revs = VehicleSoundController.stepGearbox(box, gears, top * frame / frames, DT)
		table.insert(gearsSeen, box.gear)
		table.insert(revsSeen, revs)
	end
	return gearsSeen, revsSeen
end

-- A fuel trim from the real catalog (the first fuel vehicle's first trim).
local function fuelTuning(): Tuning.Tuning?
	for _, id in Catalog.vehicleIds() do
		local vehicle = Vehicles[id]
		if vehicle.energy == "fuel" and vehicle.playerDrivable then
			return Tuning.forTrim(id, vehicle.trims[1].id)
		end
	end
	return nil
end

return function(t: Harness.Api)
	t.describe("Car sounds", function()
		t.describe("the gearbox", function()
			t.it("climbs through every gear on the way up", function()
				local gears = runUp(GEARS, GEARS[#GEARS], 10)
				t.expect(gears[1]).toBe(1)
				t.expect(gears[#gears]).toBe(#GEARS)
				local upshifts = 0
				for index = 2, #gears do
					t.expect(gears[index] >= gears[index - 1]).toBe(true) -- never down while speeding up
					if gears[index] > gears[index - 1] then
						upshifts += 1
					end
				end
				t.expect(upshifts).toBe(#GEARS - 1)
			end)

			t.it("drops the revs on every upshift and climbs them in between", function()
				local gears, revs = runUp(GEARS, GEARS[#GEARS], 10)
				for index = 2, #gears do
					if gears[index] > gears[index - 1] then
						t.expect(revs[index]).toBeLessThan(revs[index - 1])
					else
						t.expect(revs[index] >= revs[index - 1] - 1e-9).toBe(true)
					end
				end
			end)

			t.it("shifts up where the chassis does", function()
				local box = VehicleSoundController.newGearbox()
				VehicleSoundController.stepGearbox(box, GEARS, GEARS[1] * fuel.upshiftAt - 0.01, DT)
				t.expect(box.gear).toBe(1)
				VehicleSoundController.stepGearbox(box, GEARS, GEARS[1] * fuel.upshiftAt, DT)
				t.expect(box.gear).toBe(2)
			end)

			t.it("dips for the shift, then comes back", function()
				local box = VehicleSoundController.newGearbox()
				local _, shifting = VehicleSoundController.stepGearbox(box, GEARS, GEARS[1], DT)
				t.expect(shifting).toBe(true)
				local frames = math.ceil(fuel.shiftTime / DT) + 1
				for _ = 1, frames do
					_, shifting = VehicleSoundController.stepGearbox(box, GEARS, GEARS[1], DT)
				end
				t.expect(shifting).toBe(false)
			end)

			t.it("shifts down as the car slows", function()
				local box = VehicleSoundController.newGearbox()
				VehicleSoundController.stepGearbox(box, GEARS, GEARS[#GEARS], DT)
				t.expect(box.gear).toBe(#GEARS)
				VehicleSoundController.stepGearbox(box, GEARS, GEARS[2] * fuel.downshiftAt - 0.01, DT)
				t.expect(box.gear).toBe(2)
				VehicleSoundController.stepGearbox(box, GEARS, 0, DT)
				t.expect(box.gear).toBe(1)
			end)

			t.it("settles straight into the right gear for a car first heard at speed, either way", function()
				local box = VehicleSoundController.newGearbox()
				local revs = VehicleSoundController.stepGearbox(box, GEARS, -60, DT)
				t.expect(box.gear).toBe(4)
				t.expect(revs).toBeNear(60 / GEARS[4], 1e-9)
			end)

			t.it("follows the local driver's own gear", function()
				local box = VehicleSoundController.newGearbox()
				local revs, shifting = VehicleSoundController.followGear(box, GEARS, "3", 40, DT)
				t.expect(box.gear).toBe(3)
				t.expect(revs).toBeNear(40 / GEARS[3], 1e-9)
				t.expect(shifting).toBe(true) -- up from first
				VehicleSoundController.followGear(box, GEARS, "R", 5, DT)
				t.expect(box.gear).toBe(1)
				local _, again = VehicleSoundController.followGear(box, GEARS, "1", 5, fuel.shiftTime + DT)
				t.expect(again).toBe(false)
			end)

			t.it("revs a real fuel car up through its gears with a drop at each shift", function()
				local tuning = fuelTuning()
				t.expect(tuning ~= nil).toBe(true)
				if tuning == nil then
					return
				end
				local engine = car.engines[car.defaultEngine]
				local gears, revs = runUp(tuning.gearSpeeds, tuning.topSpeed, 20)
				local drops = 0
				for index = 2, #revs do
					local before = VehicleSoundController.engineSound(engine, revs[index - 1], 1, false)
					local after = VehicleSoundController.engineSound(engine, revs[index], 1, false)
					if gears[index] > gears[index - 1] then
						t.expect(after).toBeLessThan(before)
						drops += 1
					end
				end
				t.expect(drops).toBe(#tuning.gearSpeeds - 1)
			end)
		end)

		t.describe("engine and whine", function()
			t.it("pitches a fuel engine from idle to redline", function()
				for _, engine in car.engines do
					local idle = VehicleSoundController.engineSound(engine, 0, 0, false)
					local top = VehicleSoundController.engineSound(engine, 1, 0, false)
					local middle = VehicleSoundController.engineSound(engine, 0.5, 0, false)
					t.expect(idle).toBeNear(engine.idlePitch, 1e-9)
					t.expect(top).toBeNear(engine.redlinePitch, 1e-9)
					t.expect(middle > idle and middle < top).toBe(true)
				end
			end)

			t.it("is louder on the throttle and dips for a shift", function()
				local engine = car.engines[car.defaultEngine]
				local _, off = VehicleSoundController.engineSound(engine, 0.5, 0, false)
				local _, on = VehicleSoundController.engineSound(engine, 0.5, 1, false)
				local _, shifting = VehicleSoundController.engineSound(engine, 0.5, 1, true)
				t.expect(on).toBeGreaterThan(off)
				t.expect(on <= 1).toBe(true)
				t.expect(shifting).toBeNear(on * car.shiftDip, 1e-9)
			end)

			t.it("whines higher and louder as an electric car speeds up", function()
				local restPitch, restVolume = VehicleSoundController.evSound(0, 0)
				local halfPitch, halfVolume = VehicleSoundController.evSound(0.5, 0)
				local topPitch, topVolume = VehicleSoundController.evSound(1, 0)
				t.expect(restPitch).toBeNear(car.ev.minPitch, 1e-9)
				t.expect(topPitch).toBeNear(car.ev.maxPitch, 1e-9)
				t.expect(halfPitch > restPitch and halfPitch < topPitch).toBe(true)
				t.expect(halfVolume).toBeGreaterThan(restVolume)
				t.expect(topVolume).toBeGreaterThan(halfVolume)
				local _, pushed = VehicleSoundController.evSound(1, 1)
				t.expect(pushed <= 1).toBe(true)
				local _, past = VehicleSoundController.evSound(3, 0) -- past top speed (downhill) clamps
				t.expect(past).toBeNear(topVolume, 1e-9)
			end)

			t.it("reads another car's throttle from its acceleration", function()
				t.expect(VehicleSoundController.loadFrom(0, 0)).toBe(0)
				t.expect(VehicleSoundController.loadFrom(car.load.fullAccel, 0)).toBe(1)
				t.expect(VehicleSoundController.loadFrom(-50, 0)).toBe(0) -- braking
				t.expect(VehicleSoundController.loadFrom(0, 1)).toBeNear(car.load.cruiseLoad, 1e-9) -- holding top speed
			end)
		end)

		t.describe("tyres and wind", function()
			t.it("squeals only past the slip threshold", function()
				local tyre = car.tyre
				local speed = tyre.minSpeedMph + 20
				t.expect(VehicleSoundController.squealAmount(tyre.slipStartMph, speed)).toBe(0)
				t.expect(VehicleSoundController.squealAmount(tyre.slipStartMph - 1, speed)).toBe(0)
				t.expect(VehicleSoundController.squealAmount(tyre.slipFullMph, speed)).toBe(1)
				local middle = VehicleSoundController.squealAmount((tyre.slipStartMph + tyre.slipFullMph) / 2, speed)
				t.expect(middle > 0 and middle < 1).toBe(true)
			end)

			t.it("never squeals for a car barely moving", function()
				local tyre = car.tyre
				t.expect(VehicleSoundController.squealAmount(tyre.slipFullMph, tyre.minSpeedMph - 1)).toBe(0)
			end)

			t.it("grows the wind from town speed to highway speed", function()
				local wind = car.wind
				t.expect(VehicleSoundController.windAmount(wind.startMph)).toBe(0)
				t.expect(VehicleSoundController.windAmount(0)).toBe(0)
				t.expect(VehicleSoundController.windAmount(wind.fullMph)).toBe(1)
				local middle = VehicleSoundController.windAmount((wind.startMph + wind.fullMph) / 2)
				t.expect(middle > 0 and middle < 1).toBe(true)
			end)
		end)

		t.describe("which cars play", function()
			t.it("picks the nearest cars first", function()
				local picked = VehicleSoundController.nearest({ a = 50, b = 10, c = 30, d = 200 }, 2)
				t.expect(picked).toEqual({ b = true, c = true })
			end)

			t.it("picks every car when there are fewer than the cap", function()
				t.expect(VehicleSoundController.nearest({ a = 5 }, 6)).toEqual({ a = true })
				t.expect(VehicleSoundController.nearest({}, 6)).toEqual({})
			end)

			t.it("caps the engines and the distance", function()
				t.expect(car.maxEngines >= 1 and car.maxEngines <= 12).toBe(true)
				t.expect(car.maxDistance).toBeGreaterThan(0)
				t.expect(car.rankInterval).toBeGreaterThan(0)
			end)
		end)

		t.describe("Config/Audio", function()
			t.it("gives every fuel car an engine loop that exists", function()
				for _, id in Catalog.vehicleIds() do
					local vehicle = Vehicles[id]
					if vehicle.energy == "fuel" then
						local engineId = VehicleSoundController.engineFor(id, vehicle.class)
						local engine = car.engines[engineId]
						t.expect(`{id}: {engine ~= nil}`).toBe(`{id}: true`)
						if engine ~= nil then
							t.expect(`{id}: {Audio.loops[engine.loop] ~= nil}`).toBe(`{id}: true`)
						end
					end
				end
			end)

			t.it("falls back to the default engine for a class it doesn't list", function()
				t.expect(VehicleSoundController.engineFor("nobody", "not_a_class")).toBe(car.defaultEngine)
				t.expect(VehicleSoundController.engineFor("nobody", nil)).toBe(car.defaultEngine)
				t.expect(VehicleSoundController.engineFor("nobody", "muscle")).toBe("rumble")
				t.expect(VehicleSoundController.engineFor("nobody", "exotic")).toBe("high")
			end)

			t.it("names only loops and sounds that exist", function()
				for _, loopId in { car.ev.loop, car.tyre.loop, car.wind.loop, car.horn.loop } do
					t.expect(`{loopId}: {Audio.loops[loopId] ~= nil}`).toBe(`{loopId}: true`)
				end
				t.expect(Audio.sfx[car.indicatorTick.sfx] ~= nil).toBe(true)
				t.expect(car.engines[car.defaultEngine] ~= nil).toBe(true)
			end)

			t.it("keeps every loop's numbers sane", function()
				for id, loop in Audio.loops do
					t.expect(`{id} id whole: {loop.assetId >= 0 and loop.assetId % 1 == 0}`).toBe(`{id} id whole: true`)
					t.expect(loop.volume > 0 and loop.volume <= 1).toBe(true)
					t.expect(loop.rollOffMinDistance < loop.rollOffMaxDistance).toBe(true)
				end
				for _, engine in car.engines do
					t.expect(engine.idlePitch < engine.redlinePitch).toBe(true)
					t.expect(engine.idleVolume + engine.loadVolume <= 1 + 1e-9).toBe(true)
				end
				t.expect(car.ev.minPitch < car.ev.maxPitch).toBe(true)
				t.expect(car.tyre.slipStartMph < car.tyre.slipFullMph).toBe(true)
				t.expect(car.wind.startMph < car.wind.fullMph).toBe(true)
				t.expect(car.shiftDip > 0 and car.shiftDip < 1).toBe(true)
			end)
		end)
	end)
end
