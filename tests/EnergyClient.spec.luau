--!strict
-- The driver's side of energy (docs/phase-5-contracts.md "Client"), as pure logic: limp mode's speed cap in the
-- powertrain (the car settles at Config/Energy.limpMph and slows to it from speed, forward and in reverse, and
-- the cap lifts cleanly), and EnergyController's HUD view (amber and red thresholds, range in miles or km, the
-- charging card's rate and cost texts, which station a car charges at) plus where HudController puts the
-- charging card on landscape phones, tablets and desktops. Runs in Edit mode and never touches module state.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")

local Catalog = require(ReplicatedStorage.Shared.Vehicle.Catalog)
local Chassis = require(ReplicatedStorage.Shared.Vehicle.Chassis)
local Energy = require(ReplicatedStorage.Shared.Vehicle.Energy)
local EnergyConfig = require(ReplicatedStorage.Shared.Config.Energy)
local Harness = require(ReplicatedStorage.Shared.Testing.Harness)
local MapLayout = require(ReplicatedStorage.Shared.Config.MapLayout)
local Powertrain = require(ReplicatedStorage.Shared.Vehicle.Powertrain)
local Tuning = require(ReplicatedStorage.Shared.Vehicle.Tuning)
local Types = require(ReplicatedStorage.Shared.Types)
local Units = require(ReplicatedStorage.Shared.Util.Units)

local Client = StarterPlayer.StarterPlayerScripts.Client
local EnergyController = require(Client.Controllers.EnergyController)
local HudController = require(Client.Controllers.HudController)
local Layout = require(Client.UI.Phone.Layout)

local DT = 1 / 60
local SETTLE_SECONDS = 20 -- long enough for any car to reach (and settle at) the limp speed
local CAP_TOLERANCE = 0.02 -- settles within 2 % of the limp speed
local SLOW_DOWN_SECONDS = 6 -- from the catalog top speed to under the cap's anti-exploit allowance
local ANTI_EXPLOIT_SLACK = 1.15 -- Config/AntiExploit's speed tolerance over the allowed speed

type TrimRef = { name: string, vehicleId: string, trimId: string }

local function drivableTrims(): { TrimRef }
	local list: { TrimRef } = {}
	for _, vehicleId in Catalog.vehicleIds() do
		local vehicle = Catalog.getVehicle(vehicleId)
		if vehicle and vehicle.playerDrivable then
			for _, trim in vehicle.trims do
				table.insert(list, { name = `{vehicleId}/{trim.id}`, vehicleId = vehicleId, trimId = trim.id })
			end
		end
	end
	return list
end

local function controls(throttle: number, brake: number): Types.Controls
	return { throttle = throttle, brake = brake, steer = 0, handbrake = false }
end

-- 1-D run on flat ground, like Powertrain.simulateTopSpeed but from `startSpeed` with the given pedals, through
-- `powertrain` as it is (cap included). Returns the speed after `seconds` and the fastest speed seen after
-- `ignoreFirst` seconds.
local function simulate(
	powertrain: Powertrain.Powertrain,
	tuning: Tuning.Tuning,
	startSpeed: number,
	pedals: Types.Controls,
	seconds: number,
	ignoreFirst: number?
): (number, number)
	local cap = Powertrain.tractionCap(tuning, "standard")
	local speed, fastest = startSpeed, 0
	for step = 1, math.ceil(seconds / DT) do
		local output = powertrain:update(DT, pedals, speed, "standard", "standard")
		local drive = math.clamp(output.driveAccel, -cap, cap)
		local resistance = Powertrain.resistance(tuning, math.abs(speed))
		local direction = if speed >= 0 then 1 else -1
		speed += (drive - direction * (resistance + output.brakeAccel)) * DT
		if step * DT >= (ignoreFirst or 0) then
			fastest = math.max(fastest, math.abs(speed))
		end
	end
	return speed, fastest
end

local function newScreen(width: number, height: number): Vector2
	return Vector2.new(width, height)
end

-- Landscape phones (the game is landscape-only on phones), a tablet and a desktop, in UI-scale-1 pixels. The small
-- heights are phones with the Roblox top bar taken off (ScreenInsets.CoreUISafeInsets).
local SCREENS: { { name: string, size: Vector2 } } = {
	{ name = "landscape phone 844x390", size = newScreen(844, 390) },
	{ name = "notched phone without the top bar 750x332", size = newScreen(750, 332) },
	{ name = "small landscape phone 667x375", size = newScreen(667, 375) },
	{ name = "small phone without the top bar 667x317", size = newScreen(667, 317) },
	{ name = "tablet 819x614", size = newScreen(819, 614) },
	{ name = "desktop 1229x691", size = newScreen(1229, 691) },
}

-- A Spark's attributes as the server would publish them; a field left out is an attribute not set yet.
local function attributes(fields: {
	vehicleId: string?,
	energy: number?,
	kind: string?,
	limp: boolean?,
	charging: boolean?,
	chargeRate: number?,
}): EnergyController.Attributes
	return {
		vehicleId = fields.vehicleId or "ohm_spark",
		trim = "standard",
		energy = fields.energy,
		kind = fields.kind,
		limp = fields.limp == true,
		charging = fields.charging == true,
		chargeRate = fields.chargeRate,
	}
end

-- The first MapLayout location with this tag.
local function firstLocation(tag: string): MapLayout.Location
	local found: MapLayout.Location? = nil
	for _, location in MapLayout.locations do
		if location.tag == tag then
			found = location
			break
		end
	end
	assert(found, `no {tag} in MapLayout`)
	return found
end

local function firstHeavyBattery(): string?
	for _, vehicleId in Catalog.vehicleIds() do
		local vehicle = Catalog.getVehicle(vehicleId)
		if
			vehicle
			and vehicle.playerDrivable
			and vehicle.energy == "battery"
			and Energy.isCompatible(vehicleId, "TruckCharger")
		then
			return vehicleId
		end
	end
	return nil
end

local function firstFuelCar(): string?
	for _, vehicleId in Catalog.vehicleIds() do
		local vehicle = Catalog.getVehicle(vehicleId)
		if vehicle and vehicle.playerDrivable and vehicle.energy == "fuel" then
			return vehicleId
		end
	end
	return nil
end

return function(t: Harness.Api)
	t.describe("Limp mode", function()
		local limp = Chassis.limpSpeed()

		t.it("uses Config/Energy's limp speed", function()
			t.expect(limp).toBeNear(Units.mphToStuds(EnergyConfig.limpMph), 1e-9)
			t.expect(limp).toBeGreaterThan(0)
		end)

		t.it("settles every drivable trim at the limp speed at full throttle", function()
			local problems: { string } = {}
			for _, ref in drivableTrims() do
				local tuning = Tuning.forTrim(ref.vehicleId, ref.trimId)
				assert(tuning, `no tuning for {ref.name}`)
				local powertrain = Powertrain.new(tuning)
				powertrain:setSpeedCap(limp)
				local speed, fastest = simulate(powertrain, tuning, 0, controls(1, 0), SETTLE_SECONDS)
				if math.abs(speed - limp) > limp * CAP_TOLERANCE or fastest > limp * (1 + CAP_TOLERANCE) then
					table.insert(
						problems,
						`{ref.name}: settles at {Units.studsToMph(speed)} mph, peak {Units.studsToMph(fastest)} mph`
					)
				end
			end
			t.expect(problems).toEqual({})
		end)

		t.it("slows a car at top speed to the limp speed within seconds, throttle held", function()
			local problems: { string } = {}
			for _, ref in drivableTrims() do
				local tuning = Tuning.forTrim(ref.vehicleId, ref.trimId)
				assert(tuning, `no tuning for {ref.name}`)
				local powertrain = Powertrain.new(tuning)
				powertrain:setSpeedCap(limp)
				local _, fastest = simulate(
					powertrain,
					tuning,
					tuning.topSpeed,
					controls(1, 0),
					SLOW_DOWN_SECONDS + 1,
					SLOW_DOWN_SECONDS
				)
				if fastest > limp * ANTI_EXPLOIT_SLACK then
					table.insert(
						problems,
						`{ref.name}: still {Units.studsToMph(fastest)} mph after {SLOW_DOWN_SECONDS} s`
					)
				end
			end
			t.expect(problems).toEqual({})
		end)

		t.it("caps reverse too, never above the trim's own reverse limit", function()
			local tuning = Tuning.forTrim("ohm_spark", "standard")
			assert(tuning, "spark tuning")
			local powertrain = Powertrain.new(tuning)
			powertrain:setSpeedCap(limp)
			t.expect(powertrain:topSpeedNow(true)).toBe(math.min(tuning.reverseTopSpeed, limp))
			t.expect(powertrain:topSpeedNow(false)).toBe(math.min(tuning.topSpeed, limp))
		end)

		t.it("lifts the cap with nil and gives the car its top speed back", function()
			local tuning = Tuning.forTrim("ohm_spark", "standard")
			assert(tuning, "spark tuning")
			local powertrain = Powertrain.new(tuning)
			powertrain:setSpeedCap(limp)
			powertrain:setSpeedCap(nil)
			t.expect(powertrain:getSpeedCap()).toBe(nil)
			t.expect(powertrain:topSpeedNow(false)).toBe(tuning.topSpeed)
			local speed = simulate(powertrain, tuning, 0, controls(1, 0), SETTLE_SECONDS)
			t.expect(speed).toBeGreaterThan(limp * 2)
		end)

		t.it("keeps the cap through a reset and ignores nonsense caps", function()
			local tuning = Tuning.forTrim("ohm_spark", "standard")
			assert(tuning, "spark tuning")
			local powertrain = Powertrain.new(tuning)
			powertrain:setSpeedCap(limp)
			powertrain:reset()
			t.expect(powertrain:getSpeedCap()).toBe(limp)
			powertrain:setSpeedCap(0)
			powertrain:setSpeedCap(-5)
			powertrain:setSpeedCap(math.huge)
			powertrain:setSpeedCap(0 / 0)
			t.expect(powertrain:getSpeedCap()).toBe(limp)
		end)

		t.it("leaves the uncapped powertrain exactly as before", function()
			local tuning = Tuning.forTrim("ohm_spark", "standard")
			assert(tuning, "spark tuning")
			local capped = Powertrain.new(tuning)
			capped:setSpeedCap(tuning.topSpeed * 10) -- far above the top speed: no effect
			local plain = Powertrain.new(tuning)
			local a = simulate(capped, tuning, 0, controls(1, 0), SETTLE_SECONDS)
			local b = simulate(plain, tuning, 0, controls(1, 0), SETTLE_SECONDS)
			t.expect(a).toBe(b)
		end)
	end)

	t.describe("Energy HUD view", function()
		t.it("turns amber under the warning level and red under the critical level", function()
			t.expect(EnergyController.alertFor(nil)).toBe("normal")
			t.expect(EnergyController.alertFor(1)).toBe("normal")
			t.expect(EnergyController.alertFor(EnergyConfig.warningLevel)).toBe("normal")
			t.expect(EnergyController.alertFor(EnergyConfig.warningLevel - 0.001)).toBe("low")
			t.expect(EnergyController.alertFor(EnergyConfig.criticalLevel)).toBe("low")
			t.expect(EnergyController.alertFor(EnergyConfig.criticalLevel - 0.001)).toBe("critical")
			t.expect(EnergyController.alertFor(0)).toBe("critical")
		end)

		t.it("shows the range in miles, or kilometres for km/h players, rounded down", function()
			t.expect(EnergyController.rangeText(48.9, "mph")).toBe("48 mi")
			t.expect(EnergyController.rangeText(4.29, "mph")).toBe("4.2 mi")
			t.expect(EnergyController.rangeText(4, "mph")).toBe("4 mi")
			t.expect(EnergyController.rangeText(0, "mph")).toBe("0 mi")
			t.expect(EnergyController.rangeText(-3, "mph")).toBe("0 mi")
			t.expect(EnergyController.rangeText(0 / 0, "mph")).toBe("0 mi")
			-- 30 miles is 48.28 km.
			t.expect(EnergyController.rangeText(30, "kph")).toBe("48 km")
			t.expect(EnergyController.rangeText(2, "kph")).toBe("3.2 km")
		end)

		t.it("steps the shown level down to half a percent, never above what's left", function()
			t.expect(EnergyController.shownLevel(1)).toBe(1)
			t.expect(EnergyController.shownLevel(0)).toBe(0)
			t.expect(EnergyController.shownLevel(0.1999)).toBeNear(0.195, 1e-9)
			t.expect(EnergyController.shownLevel(0.7)).toBeNear(0.7, 1e-9)
			t.expect(EnergyController.shownLevel(1.5)).toBe(1)
			t.expect(EnergyController.shownLevel(-1)).toBe(0)
		end)

		t.it("writes the charge rate and the cost per %", function()
			t.expect(EnergyController.rateText(0.0093)).toBe("+0.9% a sec")
			t.expect(EnergyController.rateText(0.04)).toBe("+4.0% a sec")
			t.expect(EnergyController.rateText(-1)).toBe("+0.0% a sec")
			t.expect(EnergyController.costText(300)).toBe("$3 per %")
			t.expect(EnergyController.costText(150)).toBe("$1.50 per %")
			t.expect(EnergyController.costText(0)).toBe(nil)
			t.expect(EnergyController.costText(Energy.costPerFraction("ChargerStall"))).toBeTruthy()
		end)

		t.it("knows which station a car is charging at", function()
			local stall = firstLocation("ChargerStall")
			local pump = firstLocation("FuelPump")
			local truck = firstLocation("TruckCharger")
			t.expect(EnergyController.stationKindAt(stall.position, "ohm_spark")).toBe("ChargerStall")
			-- A battery car is never "at" a pump: the nearest station it may use is a charger.
			t.expect(EnergyController.stationKindAt(pump.position, "ohm_spark")).toBe("ChargerStall")
			local fuelCar = firstFuelCar()
			assert(fuelCar, "a drivable fuel car")
			t.expect(EnergyController.stationKindAt(pump.position, fuelCar)).toBe("FuelPump")
			local semi = firstHeavyBattery()
			assert(semi, "a drivable heavy battery vehicle")
			t.expect(EnergyController.stationKindAt(truck.position, semi)).toBe("TruckCharger")
			t.expect(EnergyController.stationKindAt(stall.position, "not_a_real_car")).toBe(nil)
		end)

		t.it("shows nothing for an unknown car and a quiet bar before the level arrives", function()
			local unknown = EnergyController.viewFor(
				attributes({ vehicleId = "not_a_real_car", energy = 0.5, kind = "" }),
				"mph",
				nil
			)
			t.expect(unknown.energy).toBe(nil)
			t.expect(unknown.charging).toBe(nil)

			local waiting = EnergyController.viewFor(attributes({}), "mph", nil)
			local energy = waiting.energy
			assert(energy, "an energy view")
			t.expect(energy.kind).toBe("battery") -- from the catalog until the server says
			t.expect(energy.level).toBe(nil)
			t.expect(energy.rangeText).toBe(nil)
			t.expect(energy.alert).toBe("normal")
		end)

		t.it("shows the level, kind, range and alert from the car's attributes", function()
			local view = EnergyController.viewFor(attributes({ energy = 0.15, kind = "fuel" }), "kph", nil)
			local energy = view.energy
			assert(energy, "an energy view")
			t.expect(energy.kind).toBe("fuel")
			t.expect(energy.level).toBeNear(0.15, 1e-9)
			t.expect(energy.alert).toBe("low")
			t.expect(energy.limp).toBe(false)
			local expected = EnergyController.rangeText(Energy.rangeMiles("ohm_spark", "standard", 0.15), "kph")
			t.expect(energy.rangeText).toBe(expected)
			t.expect(view.charging).toBe(nil)

			local empty = EnergyController.viewFor(attributes({ energy = 0, limp = true }), "mph", nil)
			assert(empty.energy, "an energy view")
			t.expect(empty.energy.limp).toBe(true)
			t.expect(empty.energy.alert).toBe("critical")
		end)

		t.it("shows the charging card only while Charging is set, with the station's cost", function()
			local view = EnergyController.viewFor(
				attributes({ energy = 0.42, charging = true, chargeRate = 0.01 }),
				"mph",
				"ChargerStall"
			)
			local charging = view.charging
			assert(charging, "a charging card")
			t.expect(charging.kind).toBe("battery")
			t.expect(charging.level).toBeNear(0.42, 1e-9)
			t.expect(charging.rateText).toBe(EnergyController.rateText(0.01))
			t.expect(charging.costText).toBe(EnergyController.costText(Energy.costPerFraction("ChargerStall")))

			local unknownStation = EnergyController.viewFor(attributes({ energy = 0.5, charging = true }), "mph", nil)
			assert(unknownStation.charging, "a charging card")
			t.expect(unknownStation.charging.costText).toBe(nil)
			t.expect(unknownStation.charging.rateText).toBe(EnergyController.rateText(0))

			local notCharging = EnergyController.viewFor(attributes({ energy = 0.5, chargeRate = 0.01 }), "mph", nil)
			t.expect(notCharging.charging).toBe(nil)

			local noLevel = EnergyController.viewFor(attributes({ charging = true }), "mph", nil)
			t.expect(noLevel.charging).toBe(nil)
		end)
	end)

	t.describe("Charging card placement", function()
		local function check(context: Layout.Context): { string }
			local problems: { string } = {}
			for _, screen in SCREENS do
				local rect = HudController.chargingCardRect(screen.size, context)
				if not Layout.contains(Layout.screen(screen.size), rect) then
					table.insert(problems, `{screen.name}: off screen`)
				end
				for index, blocker in HudController.chargingCardBlockers(screen.size, context) do
					if Layout.overlaps(rect, blocker) then
						table.insert(problems, `{screen.name}: covers blocker {index}`)
					end
				end
			end
			return problems
		end

		t.it("stays clear of the touch controls, phone button, cash, GPS chip and notices on touch", function()
			t.expect(check({ driving = true, touch = true, hints = false })).toEqual({})
		end)

		t.it("stays clear of the speed panel and phone button with a keyboard or gamepad", function()
			t.expect(check({ driving = true, touch = false, hints = true })).toEqual({})
		end)

		t.it("sits just above the speed panel on a roomy landscape phone", function()
			local screen = SCREENS[1].size
			local context: Layout.Context = { driving = true, touch = true, hints = false }
			local rect = HudController.chargingCardRect(screen, context)
			local cluster = Layout.cluster(screen, false)
			t.expect(rect.bottom).toBeLessThan(cluster.top + 1e-6)
			t.expect(cluster.top - rect.bottom).toBeLessThan(20)
			t.expect((rect.left + rect.right) / 2).toBeNear((cluster.left + cluster.right) / 2, 1e-6)
		end)
	end)
end
