--!strict
-- The Arc's thrusters (Vehicle/Thrusters, Config/Thrusters) on a simulated car, and the client pieces around them
-- (Controllers/AbilityController's pure helpers, the ability key and the touch Boost / Fly button). Checks that the
-- pushes move the car the same at any mass and frame rate, a hop that starts late (ping) still gets its whole lift
-- (AbilityController.hopElapsed), the hover settles at its height over the ground the ray
-- finds, the landing descends at the landing rate and ends upright (even from upside down), and every push stays
-- inside the velocity bounds the server checks (Config/Abilities.bounds, read by name). Pure: runs in Edit mode.
--
-- The simulated car is a point with an orientation over flat ground at y = 0: each step it takes the thrusters'
-- change the way AbilityController applies it (an impulse of mass x change, and the spin change), then gravity,
-- then moves. It stands on its wheels with its chassis centre REST_HEIGHT up.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")

local Abilities = require(ReplicatedStorage.Shared.Config.Abilities)
local Controls = require(ReplicatedStorage.Shared.Config.Controls)
local Harness = require(ReplicatedStorage.Shared.Testing.Harness)
local ThrusterConfig = require(ReplicatedStorage.Shared.Config.Thrusters)
local Thrusters = require(ReplicatedStorage.Shared.Vehicle.Thrusters)
local Units = require(ReplicatedStorage.Shared.Util.Units)
local Client = StarterPlayer.StarterPlayerScripts.Client
local AbilityController = require(Client.Controllers.AbilityController)
local PhoneConfig = require(Client.UI.Phone.PhoneConfig)

local rules: any = Abilities

local GRAVITY = 196.2 -- Roblox's default workspace.Gravity
local REST_HEIGHT = 1.4 -- an Arc's chassis centre over the ground on its wheels
local TOLERANCE = 1e-3 -- Vector3 is 32-bit
local FRAME_RATES = { 30, 60, 240 }
local NEUTRAL: Thrusters.Input = { steer = 0, throttle = 0, brake = 0 }

type Sim = {
	position: Vector3, -- the chassis centre
	rotation: CFrame, -- orientation only
	linear: Vector3,
	angular: Vector3,
}

-- A number from Config/Abilities at `path`; fails the spec when the contract's name is missing.
local function rule(t: Harness.Api, ...: string): number
	local value: any = rules
	for _, key in { ... } do
		value = if type(value) == "table" then value[key] else nil
	end
	t.expect(type(value)).toBe("number")
	return value :: number
end

local function newSim(height: number, linear: Vector3?, rotation: CFrame?): Sim
	return {
		position = Vector3.new(0, REST_HEIGHT + height, 0),
		rotation = rotation or CFrame.identity,
		linear = linear or Vector3.zero,
		angular = Vector3.zero,
	}
end

local function heightOf(sim: Sim): number
	return sim.position.Y - REST_HEIGHT
end

local function bodyOf(sim: Sim): Thrusters.Body
	return {
		up = sim.rotation.UpVector,
		forward = sim.rotation.LookVector,
		linear = sim.linear,
		angular = sim.angular,
		gravity = GRAVITY,
		groundDistance = if sim.position.Y <= ThrusterConfig.rayLength then sim.position.Y else nil,
		restHeight = REST_HEIGHT,
	}
end

-- One physics step: the change as AbilityController applies it on a car of `mass`, then gravity, then motion. The
-- ground holds the car at its rest height.
local function advance(sim: Sim, change: Thrusters.Change, dt: number, mass: number?)
	local carMass = mass or 1
	local impulse = change.linear * carMass
	sim.linear += impulse / carMass
	sim.angular += change.angular
	sim.linear -= Vector3.new(0, GRAVITY * dt, 0)
	sim.position += sim.linear * dt
	local spin = sim.angular.Magnitude
	if spin > 1e-9 then
		sim.rotation = CFrame.fromAxisAngle(sim.angular.Unit, spin * dt) * sim.rotation
	end
	if sim.position.Y < REST_HEIGHT then
		sim.position = Vector3.new(sim.position.X, REST_HEIGHT, sim.position.Z)
		if sim.linear.Y < 0 then
			sim.linear = Vector3.new(sim.linear.X, 0, sim.linear.Z)
		end
	end
end

local function horizontalSpeed(v: Vector3): number
	return Vector3.new(v.X, 0, v.Z).Magnitude
end

type HopStats = { peak: number, maxUp: number, maxGain: number, endSpeed: number }

-- Runs a hop's whole window from `sim` at `fps`. The gain is in speed across the ground, as the server judges it.
local function runHop(sim: Sim, seconds: number, fps: number, mass: number?): HopStats
	local dt = 1 / fps
	local startSpeed = horizontalSpeed(sim.linear)
	local stats: HopStats = { peak = 0, maxUp = -math.huge, maxGain = -math.huge, endSpeed = 0 }
	for frame = 1, math.round(seconds * fps) do
		local change = Thrusters.hopStep(dt, bodyOf(sim), (frame - 1) * dt, startSpeed)
		advance(sim, change, dt, mass)
		stats.peak = math.max(stats.peak, heightOf(sim))
		stats.maxUp = math.max(stats.maxUp, sim.linear.Y)
		stats.maxGain = math.max(stats.maxGain, horizontalSpeed(sim.linear) - startSpeed)
	end
	stats.endSpeed = horizontalSpeed(sim.linear)
	return stats
end

type FlightStats = {
	maxUp: number,
	maxDown: number,
	maxHorizontal: number,
	maxGain: number, -- the most one step raised the speed across the ground
	maxHeight: number,
}

-- Runs `seconds` of flight from `sim` at `fps`, with input from `inputAt(seconds since takeoff)`.
local function runFlight(sim: Sim, seconds: number, fps: number, inputAt: ((number) -> Thrusters.Input)?): FlightStats
	local dt = 1 / fps
	local stats: FlightStats = { maxUp = -math.huge, maxDown = 0, maxHorizontal = 0, maxGain = 0, maxHeight = 0 }
	for frame = 1, math.round(seconds * fps) do
		local input = if inputAt then inputAt((frame - 1) * dt) else NEUTRAL
		local before = horizontalSpeed(sim.linear)
		advance(sim, Thrusters.flightStep(dt, bodyOf(sim), input, false), dt)
		local across = horizontalSpeed(sim.linear)
		stats.maxUp = math.max(stats.maxUp, sim.linear.Y)
		stats.maxDown = math.max(stats.maxDown, -sim.linear.Y)
		stats.maxHorizontal = math.max(stats.maxHorizontal, across)
		stats.maxGain = math.max(stats.maxGain, across - before)
		stats.maxHeight = math.max(stats.maxHeight, heightOf(sim))
	end
	return stats
end

type LandingStats = { seconds: number, maxDown: number, cruise: number, touchdown: number }

-- Lands `sim` (landingStep for `ability`) at `fps` until it is down or `limit` seconds pass.
local function runLanding(sim: Sim, ability: Thrusters.Ability, fps: number, limit: number): LandingStats
	local dt = 1 / fps
	local stats: LandingStats = { seconds = limit, maxDown = 0, cruise = 0, touchdown = 0 }
	local flare = ThrusterConfig.landing.flareHeight
	for frame = 1, math.round(limit * fps) do
		local before = -sim.linear.Y
		advance(sim, Thrusters.landingStep(dt, bodyOf(sim), ability), dt)
		local descent = -sim.linear.Y
		stats.maxDown = math.max(stats.maxDown, descent)
		-- The steady descent: well above the flare, once the first second has passed.
		if frame * dt > 1 and heightOf(sim) > flare + 3 then
			stats.cruise = descent
		end
		if heightOf(sim) <= 0 then
			stats.seconds = frame * dt
			stats.touchdown = before
			break
		end
	end
	return stats
end

return function(t: Harness.Api)
	t.describe("Vehicle/Thrusters", function()
		local limits = Thrusters.limits()

		t.it("reads the server's velocity bounds by name and never aims past them", function()
			local margin = ThrusterConfig.boundsMargin
			t.expect(margin > 0 and margin <= 1).toBe(true)
			t.expect(limits.hopUp <= rule(t, "bounds", "boostHop", "maxUpSpeed") * margin + TOLERANCE).toBe(true)
			t.expect(limits.hopSpeedGain <= rule(t, "bounds", "boostHop", "maxSpeedGain") * margin + TOLERANCE)
				.toBe(true)
			t.expect(limits.flightUp <= rule(t, "bounds", "flight", "maxUpSpeed") * margin + TOLERANCE).toBe(true)
			t.expect(limits.flightDown <= rule(t, "bounds", "flight", "maxDownSpeed") * margin + TOLERANCE).toBe(true)
			t.expect(limits.flightHorizontal <= rule(t, "bounds", "flight", "maxHorizontalSpeed") * margin + TOLERANCE)
				.toBe(true)
			t.expect(limits.hoverHeight <= rule(t, "bounds", "flight", "maxHeight") * margin + TOLERANCE).toBe(true)
			t.expect(Thrusters.landingRate() <= limits.flightDown + TOLERANCE).toBe(true)
		end)

		t.it("lets go of the landing before the server's landing allowance ends", function()
			t.expect(Thrusters.landingTimeout("boostHop") <= rule(t, "boostHop", "landingSeconds")).toBe(true)
			t.expect(Thrusters.landingTimeout("flight") <= rule(t, "flight", "landingSeconds")).toBe(true)
			t.expect(Thrusters.landingTimeout("boostHop")).toBeGreaterThan(0)
			t.expect(Thrusters.landingTimeout("flight")).toBeGreaterThan(0)
		end)

		t.it("moves the car the same at any mass", function()
			local seconds = rule(t, "boostHop", "durationSeconds")
			local results: { HopStats } = {}
			for _, mass in { 300, 1500, 9000 } do
				table.insert(results, runHop(newSim(0, Vector3.new(0, 0, -40)), seconds, 60, mass))
			end
			for _, stats in results do
				t.expect(stats.peak).toBeNear(results[1].peak, TOLERANCE)
				t.expect(stats.endSpeed).toBeNear(results[1].endSpeed, TOLERANCE)
			end
		end)

		t.it("hops forward and up inside the server's bounds, at any frame rate", function()
			local seconds = rule(t, "boostHop", "durationSeconds")
			local maxUp = rule(t, "bounds", "boostHop", "maxUpSpeed")
			local maxGain = rule(t, "bounds", "boostHop", "maxSpeedGain")
			local minSpeed = Units.mphToStuds(rule(t, "boostHop", "minSpeedMph"))
			local reference = runHop(newSim(0, Vector3.new(0, 0, -minSpeed)), seconds, 60)
			for _, fps in FRAME_RATES do
				for _, start in { minSpeed, 3 * minSpeed } do
					local stats = runHop(newSim(0, Vector3.new(0, 0, -start)), seconds, fps)
					t.expect(stats.maxUp <= maxUp + TOLERANCE).toBe(true)
					t.expect(stats.maxGain <= maxGain + TOLERANCE).toBe(true)
					t.expect(stats.peak).toBeGreaterThan(4) -- a real hop, clear of another car's roof
					t.expect(stats.endSpeed).toBeGreaterThan(start + 5) -- and a real boost
				end
				local stats = runHop(newSim(0, Vector3.new(0, 0, -minSpeed)), seconds, fps)
				t.expect(stats.peak).toBeNear(reference.peak, 0.5)
			end
		end)

		t.it("gives a hop that starts late (ping) the whole lift, and lands it inside the allowance", function()
			local window = rule(t, "boostHop", "durationSeconds")
			local allowance = rule(t, "boostHop", "landingSeconds")
			local minSpeed = Units.mphToStuds(rule(t, "boostHop", "minSpeedMph"))
			local fps = 60
			local dt = 1 / fps
			local reference = runHop(newSim(0, Vector3.new(0, 0, -minSpeed)), window, fps)
			-- The server opens the window at 0; this client hears of it `late` seconds on and pushes until it ends.
			for _, late in { 0.1, 0.25, 0.4 } do
				local sim = newSim(0, Vector3.new(0, 0, -minSpeed))
				local startSpeed = horizontalSpeed(sim.linear)
				local firstPush: number? = nil
				local peak = 0
				for frame = 1, math.floor((window - late) * fps) do
					local elapsed, started = AbilityController.hopElapsed(firstPush, late + (frame - 1) * dt)
					firstPush = started
					advance(sim, Thrusters.hopStep(dt, bodyOf(sim), elapsed, startSpeed), dt)
					peak = math.max(peak, heightOf(sim))
				end
				t.expect(firstPush).toBe(late)
				t.expect(peak).toBeNear(reference.peak, 0.5)
				-- Whatever is left of the arc after AbilityEndsAt comes down inside the server's landing allowance.
				local landing = runLanding(sim, "boostHop", fps, allowance)
				t.expect(heightOf(sim)).toBeNear(0, TOLERANCE)
				t.expect(landing.seconds).toBeLessThan(allowance)
			end
			-- The first push starts the clock; later ones count from it.
			local first = AbilityController.hopElapsed(nil, 12)
			local later = AbilityController.hopElapsed(12, 12.5)
			t.expect(first).toBe(0)
			t.expect(later).toBe(0.5)
		end)

		t.it("lifts off and settles at the hover height over the ground the ray finds, at any frame rate", function()
			local seconds = rule(t, "flight", "durationSeconds")
			local hover = ThrusterConfig.flight.hoverHeight
			local maxHeight = rule(t, "bounds", "flight", "maxHeight")
			for _, fps in FRAME_RATES do
				local sim = newSim(0)
				local stats = runFlight(sim, seconds, fps)
				t.expect(heightOf(sim)).toBeNear(hover, 1)
				t.expect(math.abs(sim.linear.Y)).toBeLessThan(1)
				t.expect(stats.maxUp <= limits.flightUp + TOLERANCE).toBe(true)
				-- The server measures from the ground to the chassis.
				t.expect(stats.maxHeight + REST_HEIGHT <= maxHeight).toBe(true)
			end
			-- Over a drop (no ground in reach) it comes down, no faster than the descent limit.
			local high = newSim(ThrusterConfig.rayLength + 10)
			local stats = runFlight(high, 2, 60)
			t.expect(heightOf(high)).toBeLessThan(ThrusterConfig.rayLength + 10)
			t.expect(stats.maxDown <= limits.flightDown + TOLERANCE).toBe(true)
		end)

		t.it("keeps flight inside the server's bounds whatever the input", function()
			local maxUp = rule(t, "bounds", "flight", "maxUpSpeed")
			local maxDown = rule(t, "bounds", "flight", "maxDownSpeed")
			local maxHorizontal = rule(t, "bounds", "flight", "maxHorizontalSpeed")
			local seconds = rule(t, "flight", "durationSeconds")
			local function tricks(at: number): Thrusters.Input
				local phase = math.floor(at * 3) % 4
				return {
					steer = if phase == 0 then 1 elseif phase == 2 then -1 else 0,
					throttle = if phase == 1 then 1 else 0,
					brake = if phase == 3 then 1 else 0,
				}
			end
			-- Taking off under the limit across the ground, it stays under it.
			local sim = newSim(0, Vector3.new(0.6 * maxHorizontal, 0, -0.6 * maxHorizontal))
			local stats = runFlight(sim, seconds, 60, tricks)
			t.expect(stats.maxUp <= maxUp + TOLERANCE).toBe(true)
			t.expect(stats.maxDown <= maxDown + TOLERANCE).toBe(true)
			t.expect(stats.maxHorizontal <= maxHorizontal + TOLERANCE).toBe(true)
			t.expect(stats.maxGain <= TOLERANCE).toBe(true)
			-- Taking off faster than flight allows, it never gains and is soon back under the limit.
			local fast = newSim(0, Vector3.new(1.5 * maxHorizontal, 0, -maxHorizontal))
			local fastStats = runFlight(fast, seconds, 60, tricks)
			t.expect(fastStats.maxGain <= TOLERANCE).toBe(true)
			t.expect(horizontalSpeed(fast.linear)).toBeLessThan(maxHorizontal)
			t.expect(fastStats.maxUp <= maxUp + TOLERANCE).toBe(true)
		end)

		t.it("rolls with steer, flips forward with throttle and back with brake", function()
			local hover = ThrusterConfig.flight.hoverHeight
			local function after(input: Thrusters.Input): CFrame
				local sim = newSim(hover)
				runFlight(sim, 0.4, 60, function(_at: number): Thrusters.Input
					return input
				end)
				return sim.rotation
			end
			t.expect(after({ steer = 1, throttle = 0, brake = 0 }).RightVector.Y).toBeLessThan(-0.3)
			t.expect(after({ steer = -1, throttle = 0, brake = 0 }).RightVector.Y).toBeGreaterThan(0.3)
			t.expect(after({ steer = 0, throttle = 1, brake = 0 }).LookVector.Y).toBeLessThan(-0.3)
			t.expect(after({ steer = 0, throttle = 0, brake = 1 }).LookVector.Y).toBeGreaterThan(0.3)
		end)

		t.it("drifts back level in flight with no input", function()
			local sim = newSim(ThrusterConfig.flight.hoverHeight, nil, CFrame.Angles(0, 0, math.rad(50)))
			runFlight(sim, 2, 60)
			t.expect(sim.rotation.UpVector.Y).toBeGreaterThan(0.98)
		end)

		t.it("lands at the landing rate, slows for touchdown and ends upright, even from upside down", function()
			local uprightDot = rule(t, "uprightDot")
			local landing = ThrusterConfig.landing
			local rate = Thrusters.landingRate()
			for _, fps in FRAME_RATES do
				for _, start in { CFrame.identity, CFrame.Angles(0, 0, math.pi), CFrame.Angles(math.rad(130), 0, 0) } do
					local sim = newSim(ThrusterConfig.flight.hoverHeight, Vector3.new(30, 0, 0), start)
					local stats = runLanding(sim, "flight", fps, landing.timeoutSeconds)
					t.expect(heightOf(sim)).toBeNear(0, TOLERANCE)
					t.expect(stats.seconds).toBeLessThan(landing.timeoutSeconds)
					t.expect(stats.maxDown <= rate + TOLERANCE).toBe(true)
					t.expect(stats.cruise).toBeNear(rate, 0.5)
					t.expect(stats.touchdown).toBeLessThan(landing.touchdownSpeed + 1)
					t.expect(sim.rotation.UpVector.Y).toBeGreaterThan(uprightDot)
				end
			end
		end)

		t.it("is down, upright, inside the server's landing allowance", function()
			-- The server keeps its allowance landingSeconds after AbilityEndsAt, then settles and checks the car.
			local allowance = rule(t, "flight", "landingSeconds")
			local sim = newSim(ThrusterConfig.flight.hoverHeight, nil, CFrame.Angles(0, 0, math.pi))
			local stats = runLanding(sim, "flight", 60, allowance)
			t.expect(heightOf(sim)).toBeNear(0, TOLERANCE)
			t.expect(stats.seconds).toBeLessThan(allowance)
			t.expect(sim.rotation.UpVector.Y).toBeGreaterThan(rule(t, "uprightDot"))
		end)

		t.it("lets a hop still in the air after its window fall no faster than its landing rate, upright", function()
			local rate = ThrusterConfig.hop.landingDescentRate
			local sim = newSim(15, Vector3.new(0, -40, -60), CFrame.Angles(0, 0, math.rad(30)))
			local dt = 1 / 60
			advance(sim, Thrusters.landingStep(dt, bodyOf(sim), "boostHop"), dt)
			local stats = runLanding(sim, "boostHop", 60, 3)
			t.expect(-sim.linear.Y <= rate + TOLERANCE).toBe(true)
			t.expect(stats.maxDown <= rate + TOLERANCE).toBe(true)
			t.expect(heightOf(sim)).toBeNear(0, TOLERANCE)
			t.expect(sim.rotation.UpVector.Y).toBeGreaterThan(rule(t, "uprightDot"))
		end)

		t.it("does nothing over a zero step", function()
			local change = Thrusters.flightStep(0, bodyOf(newSim(3)), NEUTRAL, false)
			t.expect(change.linear).toEqual(Vector3.zero)
			t.expect(change.angular).toEqual(Vector3.zero)
		end)
	end)

	t.describe("ability controls", function()
		t.it("binds the ability to Q and to a gamepad button nothing else uses while driving", function()
			t.expect(Controls.keyboard.ability[1]).toBe(Enum.KeyCode.Q)
			local taken: { [Enum.KeyCode]: boolean } = {}
			for action, keys in Controls.gamepad :: { [string]: { Enum.KeyCode } } do
				if action ~= "ability" then
					for _, key in keys do
						taken[key] = true
					end
				end
			end
			for _, key in PhoneConfig.keys.gamepad do
				taken[key] = true
			end
			t.expect(#Controls.gamepad.ability > 0).toBe(true)
			for _, key in Controls.gamepad.ability do
				t.expect(taken[key]).toBe(nil)
				t.expect(Controls.gamepadGlyphs[key.Name] ~= nil).toBe(true)
			end
		end)

		t.it("fits the touch Boost / Fly button above a shorter gas pedal without growing the pedal block", function()
			local touch = Controls.touch
			for _, size in { touch.abilitySize, touch.abilityGasSize } do
				t.expect(math.min(size.X, size.Y) >= touch.minTarget).toBe(true)
			end
			local column = touch.abilityGasSize.Y + touch.gap + touch.abilitySize.Y
			local block = math.max(touch.gasSize.Y, touch.brakeSize.Y + touch.gap + touch.handbrakeSize.Y)
			t.expect(column <= block).toBe(true)
			t.expect(touch.abilityGasSize.X).toBe(touch.gasSize.X)
			t.expect(touch.abilitySize.X <= touch.gasSize.X).toBe(true)
		end)
	end)

	t.describe("AbilityController", function()
		t.it("reads which trims have which ability from Config/Abilities", function()
			t.expect(AbilityController.abilitiesFor("ohm_arc", "boost")).toEqual({ "boostHop" })
			t.expect(AbilityController.abilitiesFor("ohm_arc", "flight")).toEqual({ "boostHop", "flight" })
			t.expect(AbilityController.abilitiesFor("ohm_arc", "performance")).toEqual({})
			t.expect(AbilityController.abilitiesFor(nil, nil)).toEqual({})
		end)

		t.it("asks for flight over the Flight Field, the hop elsewhere, and whichever is ready", function()
			local both: { AbilityController.AbilityId } = { "boostHop", "flight" }
			t.expect(AbilityController.pick(both, true, {}, 100)).toBe("flight")
			t.expect(AbilityController.pick(both, false, {}, 100)).toBe("boostHop")
			t.expect(AbilityController.pick(both, false, { flight = 90 }, 100)).toBe("boostHop")
			t.expect(AbilityController.pick(both, true, { flight = 120 }, 100)).toBe("boostHop")
			-- Both recharging: the one this spot calls for, so the server's reply says how long.
			t.expect(AbilityController.pick(both, true, { flight = 120, boostHop = 110 }, 100)).toBe("flight")
			t.expect(AbilityController.pick({ "boostHop" }, true, {}, 100)).toBe("boostHop")
			t.expect(AbilityController.pick({ "flight" }, false, {}, 100)).toBe("flight")
			t.expect(AbilityController.pick({}, true, {}, 100)).toBe(nil)
		end)

		t.it("finds a point inside a turned zone volume", function()
			local frame = CFrame.new(100, 80, -50) * CFrame.Angles(0, math.rad(90), 0)
			local size = Vector3.new(1300, 160, 480)
			t.expect(AbilityController.insideBox(frame, size, Vector3.new(300, 2, -50))).toBe(true)
			t.expect(AbilityController.insideBox(frame, size, Vector3.new(100, 2, 500))).toBe(true)
			-- Inside the box as if unturned, but outside it turned.
			t.expect(AbilityController.insideBox(frame, size, Vector3.new(400, 2, -50))).toBe(false)
			t.expect(AbilityController.insideBox(frame, size, Vector3.new(100, 200, -50))).toBe(false)
		end)

		t.it("fills the chip's ring as the ability recharges, and says when it runs", function()
			local text = Controls.hud.abilityChip
			local cooldown = rule(t, "boostHop", "cooldownSeconds")
			local half = AbilityController.chipFor("boostHop", {
				active = nil,
				landing = false,
				readyAt = 100 + cooldown / 2,
				now = 100,
				busy = false,
			})
			t.expect(half.state).toBe("recharging")
			t.expect(half.fill).toBeNear(0.5, 1 / text.ringSteps + TOLERANCE)
			t.expect(half.seconds).toBe(math.ceil(cooldown / 2))
			t.expect(half.label).toBe(text.labels.boostHop)

			local ready = AbilityController.chipFor("flight", {
				active = nil,
				landing = false,
				readyAt = 90,
				now = 100,
				busy = true,
			})
			t.expect(ready).toEqual({
				label = text.labels.flight,
				status = text.ready,
				state = "ready",
				fill = 1,
				busy = true,
			})

			local flying = AbilityController.chipFor("flight", {
				active = "flight",
				landing = false,
				readyAt = 140,
				now = 100,
				busy = false,
			})
			t.expect(flying.state).toBe("active")
			t.expect(flying.status).toBe(text.activeLabels.flight)
			local landing = AbilityController.chipFor("flight", {
				active = "flight",
				landing = true,
				readyAt = 140,
				now = 100,
				busy = false,
			})
			t.expect(landing.status).toBe(text.landing)
		end)

		t.it("reads UseAbility replies", function()
			local ok, message, startsAt, endsAt =
				AbilityController.readReply({ ok = true, message = "", startsAt = 5, endsAt = 7, readyAt = 25 })
			t.expect(ok).toBe(true)
			t.expect(message).toBe(nil)
			t.expect(startsAt).toBe(5)
			t.expect(endsAt).toBe(7)
			ok, message, startsAt, endsAt = AbilityController.readReply({ ok = false, message = "Boost needs 20 mph" })
			t.expect(ok).toBe(false)
			t.expect(message).toBe("Boost needs 20 mph")
			t.expect(startsAt).toBe(nil)
			t.expect(endsAt).toBe(nil)
			ok = AbilityController.readReply(nil)
			t.expect(ok).toBe(nil)
		end)
	end)
end
