--!strict
-- The horn, headlights and indicators (roast fixes, 2026-10-24; Net CarSignal): Services/CarSignalService's rules
-- (only the driver of a car they own may signal, the horn's hold and its auto-off, the indicator and headlight
-- toggles), the shared helpers in Config/Controls (night, the flash, reading the attributes), which lamps
-- Controllers/VehicleVisualsController lights for each signal (signalLook), and sane Config/Controls values (keys,
-- touch sizes, the touch Horn / Lights row clear of the GPS button). Pure logic: runs in Edit mode.

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local StarterPlayer = game:GetService("StarterPlayer")

local Harness = require(ReplicatedStorage.Shared.Testing.Harness)
local Controls = require(ReplicatedStorage.Shared.Config.Controls)
local Gps = require(ReplicatedStorage.Shared.Config.Gps)
local Spawning = require(ReplicatedStorage.Shared.Config.Spawning)
local CarSignalService = require(ServerScriptService.Server.Services.CarSignalService)

local Client = StarterPlayer.StarterPlayerScripts.Client
local VehicleVisualsController = require(Client.Controllers.VehicleVisualsController)
local PhoneConfig = require(Client.UI.Phone.PhoneConfig)

local OWNER = 1001
local STRANGER = 2002

-- A car as VehicleService spawns it (not parented anywhere): tagged, owned, with Seats/Driver and a passenger seat.
local function newCar(tagged: boolean?): (Model, Seat, Seat)
	local model = Instance.new("Model")
	model.Name = "TestCar"
	model:SetAttribute("VehicleId", "ohm_spark")
	model:SetAttribute("OwnerUserId", OWNER)
	if tagged ~= false then
		CollectionService:AddTag(model, Spawning.vehicleTag)
	end
	local seats = Instance.new("Folder")
	seats.Name = "Seats"
	seats.Parent = model
	local driver = Instance.new("Seat")
	driver.Name = "Driver"
	driver.Parent = seats
	local passenger = Instance.new("Seat")
	passenger.Name = "Passenger1"
	passenger.Parent = seats
	return model, driver, passenger
end

-- Presses `actions` in order on fresh signals (daytime unless `night`).
local function pressAll(actions: { CarSignalService.Action }, night: boolean?): CarSignalService.Signals
	local signals = CarSignalService.newSignals()
	for _, action in actions do
		CarSignalService.apply(signals, action, night == true)
	end
	return signals
end

return function(t: Harness.Api)
	t.describe("Car signals", function()
		t.describe("who may signal", function()
			t.it("lets the owner in the Driver seat signal their car", function()
				local model, driver = newCar()
				t.expect(CarSignalService.carOfDriverSeat(driver, OWNER)).toBe(model)
				model:Destroy()
			end)

			t.it("refuses anyone who doesn't own the car", function()
				local model, driver = newCar()
				t.expect(CarSignalService.carOfDriverSeat(driver, STRANGER)).toBe(nil)
				model:Destroy()
			end)

			t.it("refuses passengers, even the owner in a passenger seat", function()
				local model, _, passenger = newCar()
				t.expect(CarSignalService.carOfDriverSeat(passenger, OWNER)).toBe(nil)
				t.expect(CarSignalService.carOfDriverSeat(passenger, STRANGER)).toBe(nil)
				model:Destroy()
			end)

			t.it("refuses a seat that isn't a spawned car's, and no seat at all", function()
				local model, driver = newCar(false)
				t.expect(CarSignalService.carOfDriverSeat(driver, OWNER)).toBe(nil) -- not tagged as a car
				model:Destroy()
				local loose = Instance.new("Seat")
				loose.Name = "Driver"
				t.expect(CarSignalService.carOfDriverSeat(loose, OWNER)).toBe(nil)
				loose:Destroy()
				t.expect(CarSignalService.carOfDriverSeat(nil, OWNER)).toBe(nil)
				local part = Instance.new("Part")
				part.Name = "Driver"
				t.expect(CarSignalService.carOfDriverSeat(part, OWNER)).toBe(nil)
				part:Destroy()
			end)
		end)

		t.describe("the horn", function()
			t.it("sounds while held and stops when let go", function()
				local signals = CarSignalService.newSignals()
				t.expect(CarSignalService.apply(signals, "hornOn", false)).toBe(true)
				t.expect(signals.horn).toBe(true)
				t.expect(CarSignalService.apply(signals, "hornOff", false)).toBe(true)
				t.expect(signals.horn).toBe(false)
				t.expect(CarSignalService.apply(signals, "hornOff", false)).toBe(false) -- nothing changed
			end)

			t.it("turns itself off when the press that started it times out", function()
				local signals = CarSignalService.newSignals()
				CarSignalService.apply(signals, "hornOn", false)
				local serial = signals.hornSerial
				t.expect(CarSignalService.hornExpired(signals, serial)).toBe(true)
				t.expect(signals.horn).toBe(false)
			end)

			t.it("lets only the latest press's timer stop it", function()
				local signals = CarSignalService.newSignals()
				CarSignalService.apply(signals, "hornOn", false)
				local first = signals.hornSerial
				CarSignalService.apply(signals, "hornOff", false)
				t.expect(CarSignalService.apply(signals, "hornOn", false)).toBe(true)
				t.expect(CarSignalService.hornExpired(signals, first)).toBe(false) -- an old press's timer
				t.expect(signals.horn).toBe(true)
				t.expect(CarSignalService.hornExpired(signals, signals.hornSerial)).toBe(true)
			end)

			t.it("starts a fresh timer when pressed again while sounding", function()
				local signals = CarSignalService.newSignals()
				CarSignalService.apply(signals, "hornOn", false)
				local first = signals.hornSerial
				t.expect(CarSignalService.apply(signals, "hornOn", false)).toBe(false) -- already sounding
				t.expect(signals.hornSerial).toBe(first + 1)
				t.expect(CarSignalService.hornExpired(signals, first)).toBe(false)
			end)

			t.it("has nothing to stop once it was let go", function()
				local signals = CarSignalService.newSignals()
				CarSignalService.apply(signals, "hornOn", false)
				CarSignalService.apply(signals, "hornOff", false)
				t.expect(CarSignalService.hornExpired(signals, signals.hornSerial)).toBe(false)
			end)

			t.it("goes off by itself after a few seconds", function()
				local seconds = Controls.carSignals.hornMaxSeconds
				t.expect(seconds).toBeGreaterThan(1)
				t.expect(seconds).toBeLessThan(30)
			end)
		end)

		t.describe("indicators", function()
			t.it("turns one on, and off again with the same press", function()
				t.expect(pressAll({ "indicatorLeft" }).indicator).toBe("left")
				t.expect(pressAll({ "indicatorLeft", "indicatorLeft" }).indicator).toBe(nil)
				t.expect(pressAll({ "indicatorRight" }).indicator).toBe("right")
				t.expect(pressAll({ "hazards" }).indicator).toBe("hazards")
				t.expect(pressAll({ "hazards", "hazards" }).indicator).toBe(nil)
			end)

			t.it("switches straight from one to another", function()
				t.expect(pressAll({ "indicatorLeft", "indicatorRight" }).indicator).toBe("right")
				t.expect(pressAll({ "indicatorRight", "hazards" }).indicator).toBe("hazards")
				t.expect(pressAll({ "hazards", "indicatorLeft" }).indicator).toBe("left")
			end)

			t.it("leaves the horn and headlights alone", function()
				local signals = pressAll({ "hornOn", "indicatorLeft" })
				t.expect(signals.horn).toBe(true)
				t.expect(signals.headlights).toBe(nil)
			end)
		end)

		t.describe("headlights", function()
			t.it("comes on by day and goes back to automatic on the next press", function()
				t.expect(pressAll({ "headlights" }, false).headlights).toBe("on")
				t.expect(pressAll({ "headlights", "headlights" }, false).headlights).toBe(nil)
			end)

			t.it("goes off at night and back to automatic on the next press", function()
				t.expect(pressAll({ "headlights" }, true).headlights).toBe("off")
				t.expect(pressAll({ "headlights", "headlights" }, true).headlights).toBe(nil)
			end)

			t.it("always flips what shows", function()
				for _, night in { false, true } do
					for _, mode in { "on", "off", "auto" } do
						local current: Controls.HeadlightMode? = if mode == "auto" then nil else mode :: any
						local after = CarSignalService.nextHeadlights(current, night)
						t.expect(Controls.headlightsLit(after, night)).toBe(not Controls.headlightsLit(current, night))
					end
				end
			end)

			t.it("shines in automatic only at night", function()
				t.expect(Controls.headlightsLit(nil, true)).toBe(true)
				t.expect(Controls.headlightsLit(nil, false)).toBe(false)
				t.expect(Controls.headlightsLit("on", false)).toBe(true)
				t.expect(Controls.headlightsLit("off", true)).toBe(false)
			end)
		end)

		t.describe("shared helpers", function()
			t.it("tells night from day by the clock", function()
				local signals = Controls.carSignals
				t.expect(signals.dayStart < signals.dayEnd).toBe(true)
				t.expect(Controls.isNight(12)).toBe(false)
				t.expect(Controls.isNight(3)).toBe(true)
				t.expect(Controls.isNight(23)).toBe(true)
				t.expect(Controls.isNight(signals.dayStart)).toBe(false)
				t.expect(Controls.isNight(signals.dayEnd)).toBe(true)
				t.expect(Controls.isNight(24 + 12)).toBe(false) -- wraps round the day
			end)

			t.it("flashes on for the first share of every period", function()
				local signals = Controls.carSignals
				local period = signals.blinkPeriod
				t.expect(signals.blinkOnShare > 0 and signals.blinkOnShare < 1).toBe(true)
				t.expect(Controls.blinkOn(0)).toBe(true)
				t.expect(Controls.blinkOn(period * signals.blinkOnShare * 0.5)).toBe(true)
				t.expect(Controls.blinkOn(period * (signals.blinkOnShare + 0.01))).toBe(false)
				t.expect(Controls.blinkOn(period * 7)).toBe(true) -- every period the same
			end)

			t.it("reads only the values the server writes", function()
				t.expect(Controls.readHeadlights("on")).toBe("on")
				t.expect(Controls.readHeadlights("off")).toBe("off")
				t.expect(Controls.readHeadlights(true)).toBe(nil)
				t.expect(Controls.readHeadlights(nil)).toBe(nil)
				t.expect(Controls.readIndicator("left")).toBe("left")
				t.expect(Controls.readIndicator("hazards")).toBe("hazards")
				t.expect(Controls.readIndicator("up")).toBe(nil)
				t.expect(Controls.readIndicator(5)).toBe(nil)
			end)
		end)

		t.describe("lamps", function()
			local look = VehicleVisualsController.signalLook

			t.it("lights the head and tail lamps with the headlights", function()
				for _, name in { "HeadL", "HeadR", "TailL", "TailR" } do
					t.expect(look(name, true, nil, false)).toBe("lit")
					t.expect(look(name, false, nil, true)).toBe("off")
				end
				t.expect(look("Brake", true, nil, false)).toBe("off") -- brake lamps are not the headlights'
			end)

			t.it("flashes one side's lamps amber for an indicator", function()
				t.expect(look("HeadL", false, "left", true)).toBe("amber")
				t.expect(look("TailL", false, "left", true)).toBe("amber")
				t.expect(look("HeadR", false, "left", true)).toBe("off")
				t.expect(look("TailR", false, "right", true)).toBe("amber")
				t.expect(look("HeadL", false, "right", true)).toBe("off")
				t.expect(look("HeadL", false, "left", false)).toBe("off") -- the dark half of the flash
			end)

			t.it("flashes both sides for hazards, over lit headlights", function()
				for _, name in { "HeadL", "HeadR", "TailL", "TailR" } do
					t.expect(look(name, false, "hazards", true)).toBe("amber")
					t.expect(look(name, true, "hazards", true)).toBe("litAmber")
					t.expect(look(name, true, "hazards", false)).toBe("lit")
				end
			end)
		end)

		t.describe("controls", function()
			t.it("binds the horn, headlights and indicators to keys", function()
				local keyboard = Controls.keyboard
				t.expect(keyboard.horn[1]).toBe(Enum.KeyCode.H)
				t.expect(keyboard.headlights[1]).toBe(Enum.KeyCode.L)
				for _, keys in { keyboard.indicatorLeft, keyboard.indicatorRight, keyboard.hazards } do
					t.expect(#keys > 0).toBe(true)
				end
			end)

			t.it("puts the gamepad signals on buttons nothing else uses while driving", function()
				local mine =
					{ horn = true, headlights = true, indicatorLeft = true, indicatorRight = true, hazards = true }
				local taken: { [Enum.KeyCode]: boolean } = {}
				for action, keys in Controls.gamepad :: { [string]: { Enum.KeyCode } } do
					if not (mine :: { [string]: boolean })[action] then
						for _, key in keys do
							taken[key] = true
						end
					end
				end
				for _, key in PhoneConfig.keys.gamepad do
					taken[key] = true
				end
				for action in mine do
					for _, key in (Controls.gamepad :: any)[action] :: { Enum.KeyCode } do
						t.expect(`{key.Name} free: {taken[key] == nil}`).toBe(`{key.Name} free: true`)
						t.expect(Controls.gamepadGlyphs[key.Name] ~= nil).toBe(true)
					end
				end
			end)

			t.it("keeps the touch Horn and Lights buttons big enough and below the GPS button", function()
				local touch, panel = Controls.touch, Gps.panel
				t.expect(math.min(touch.signalSize.X, touch.signalSize.Y) >= touch.minTarget).toBe(true)
				-- The row is exactly as wide as the pedal block below it.
				local pedalWidth = touch.gasSize.X + touch.gap + math.max(touch.brakeSize.X, touch.handbrakeSize.X)
				t.expect(2 * touch.signalSize.X + touch.gap).toBe(pedalWidth)
				local pedalHeight = math.max(touch.gasSize.Y, touch.brakeSize.Y + touch.gap + touch.handbrakeSize.Y)
				local rowTop = Controls.hud.referenceShortSide
					- (touch.margin + pedalHeight + touch.gap + touch.signalSize.Y)
				t.expect(panel.top + panel.buttonSize.Y <= rowTop).toBe(true)
			end)

			t.it("names the touch buttons", function()
				t.expect(Controls.touch.labels.horn).toBe("Horn")
				t.expect(Controls.touch.labels.lights).toBe("Lights")
			end)
		end)
	end)
end
