--!strict
-- Thrusters on the server (docs/phase-10-contracts.md "Abilities, server"): every rule in AbilityService.decide
-- and the forged requests it refuses, the FlightZone and NoFlyZone volumes, the AntiExploit allowance
-- (MotionGuard.widen), the watch's bounds and judging (catch-up credit, free falls, take-off speed, height), the
-- unstuck tests and the pose on the nearest road, and sane Config/Abilities numbers that match PLAN.md. Pure
-- logic: runs in Edit mode.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local Abilities = require(ReplicatedStorage.Shared.Config.Abilities)
local AntiExploit = require(ReplicatedStorage.Shared.Config.AntiExploit)
local Catalog = require(ReplicatedStorage.Shared.Vehicle.Catalog)
local Graph = require(ReplicatedStorage.Shared.Road.Graph)
local Harness = require(ReplicatedStorage.Shared.Testing.Harness)
local MapLayout = require(ReplicatedStorage.Shared.Config.MapLayout)
local Units = require(ReplicatedStorage.Shared.Util.Units)
local World = require(ReplicatedStorage.Shared.Config.World)
local Services = ServerScriptService.Server.Services
local AbilityService = require(Services.AbilityService)
local MotionGuard = require(Services.AntiExploitService.MotionGuard)

local TOLERANCE = 1e-3 -- Vector3 components are 32-bit floats
local NOW = 1000 -- server time in the decide cases
local PLAN_HOVER_HEIGHT = 25 -- PLAN.md Phase 10: "Hover up to 25 studs"
local DOWNTOWN = Vector3.new(0, 2, 0) -- Cedar Bend, outside every volume
local CLIMB = Vector3.new(0, 2, 0) -- a chassis centre sits about this far over its footprint

local messages = Abilities.messages

-- The first location with `tag`, or nil.
local function firstWithTag(tag: string): MapLayout.Location?
	for _, location in MapLayout.locations do
		if location.tag == tag then
			return location
		end
	end
	return nil
end

local flightField = firstWithTag(Abilities.zones.flightTag)
local noFlyZone = firstWithTag(Abilities.zones.noFlyTag)
local FLIGHT_FIELD = if flightField then flightField.position + CLIMB else DOWNTOWN
local NO_FLY = if noFlyZone then noFlyZone.position + CLIMB else DOWNTOWN

-- The owner driving Arc Boost through town at 40 mph, nothing running, no cooldowns.
local function hopFacts(): AbilityService.Facts
	return {
		hasCar = true,
		isOwner = true,
		isDriver = true,
		tracked = true,
		vehicleId = "ohm_arc",
		trimId = "boost",
		readyAt = {},
		running = false,
		position = DOWNTOWN,
		speed = Units.mphToStuds(40),
	}
end

-- The owner driving Arc Flight slowly over the Flight Field.
local function flightFacts(): AbilityService.Facts
	local facts = hopFacts()
	facts.trimId = "flight"
	facts.position = FLIGHT_FIELD
	facts.speed = Units.mphToStuds(10)
	return facts
end

-- Every string in a (nested) messages table.
local function allStrings(value: any, out: { string })
	if type(value) == "string" then
		table.insert(out, value)
	elseif type(value) == "table" then
		for _, child in value do
			allStrings(child, out)
		end
	end
end

local function isFinitePositive(value: number): boolean
	return value == value and value > 0 and value < math.huge
end

-- Judges a straight run of samples every sampleInterval from `from` at `velocity` (studs/s) for `seconds`.
-- Returns the first verdict that isn't "ok" (or "ok").
local function runAt(bounds: AbilityService.Bounds, from: Vector3, velocity: Vector3, seconds: number): string
	local step = Abilities.watch.sampleInterval
	local watch = AbilityService.newWatch(from, 0, bounds)
	local time = 0
	while time < seconds do
		time += step
		local position = from + velocity * time
		local verdict = AbilityService.judge(watch, position, time, nil, bounds)
		if verdict ~= "ok" then
			return verdict
		end
	end
	return "ok"
end

return function(t: Harness.Api)
	t.describe("Config/Abilities", function()
		t.it("matches PLAN.md: a ~2 s hop every 20 s above 20 mph, up to 4 s of flight every 45 s", function()
			local hop, flight = Abilities.boostHop, Abilities.flight
			t.expect(hop.durationSeconds >= 1.5 and hop.durationSeconds <= 2.5).toBe(true)
			t.expect(hop.cooldownSeconds).toBe(20)
			t.expect(hop.minSpeedMph).toBe(20)
			t.expect(flight.durationSeconds > 0 and flight.durationSeconds <= 4).toBe(true)
			t.expect(flight.durationSeconds).toBe(4)
			t.expect(flight.cooldownSeconds).toBe(45)
		end)

		t.it("gives the hop to Arc Boost and Arc Flight and flight to Arc Flight only", function()
			t.expect(Abilities.byTrim).toEqual({
				["ohm_arc/boost"] = { "boostHop" },
				["ohm_arc/flight"] = { "boostHop", "flight" },
			})
			t.expect(Abilities.has("ohm_arc", "boost", "boostHop")).toBe(true)
			t.expect(Abilities.has("ohm_arc", "boost", "flight")).toBe(false)
			t.expect(Abilities.has("ohm_arc", "flight", "flight")).toBe(true)
			t.expect(Abilities.has("ohm_arc", "performance", "boostHop")).toBe(false)
		end)

		t.it("names real trims and real abilities, and nothing else in the catalog has any", function()
			for key, list in Abilities.byTrim do
				local vehicleId, trimId = string.match(key, "^([^/]+)/([^/]+)$")
				t.expect(vehicleId ~= nil and trimId ~= nil).toBe(true)
				t.expect(Catalog.getTrim(vehicleId :: string, trimId :: string) ~= nil).toBe(true)
				for _, ability in list do
					t.expect(table.find(Abilities.ids, ability) ~= nil).toBe(true)
				end
			end
			for _, vehicleId in Catalog.vehicleIds() do
				local vehicle = Catalog.getVehicle(vehicleId)
				if vehicle ~= nil then
					for _, trim in vehicle.trims do
						if Abilities.byTrim[`{vehicleId}/{trim.id}`] == nil then
							t.expect(#Abilities.forTrim(vehicleId, trim.id)).toBe(0)
						end
					end
				end
			end
		end)

		t.it("has a timing for every ability id and none for anything else", function()
			for _, ability in Abilities.ids do
				t.expect(Abilities.timing(ability) ~= nil).toBe(true)
			end
			t.expect(Abilities.timing("teleport")).toBe(nil)
		end)

		t.it("is over (window, landing and settle) well before the same ability is ready again", function()
			t.expect(isFinitePositive(Abilities.settleSeconds)).toBe(true)
			for _, ability in Abilities.ids do
				local timing = Abilities.timing(ability) :: Abilities.Timing
				t.expect(isFinitePositive(timing.durationSeconds)).toBe(true)
				t.expect(isFinitePositive(timing.landingSeconds)).toBe(true)
				local busy = timing.durationSeconds + timing.landingSeconds + Abilities.settleSeconds
				t.expect(timing.cooldownSeconds).toBeGreaterThan(busy)
			end
		end)

		t.it("keeps every bound and watch number positive and finite", function()
			local hop, flight = Abilities.bounds.boostHop, Abilities.bounds.flight
			for _, value in { hop.maxUpSpeed, hop.maxSpeedGain } do
				t.expect(isFinitePositive(value)).toBe(true)
			end
			for _, value in { flight.maxUpSpeed, flight.maxDownSpeed, flight.maxHorizontalSpeed, flight.maxHeight } do
				t.expect(isFinitePositive(value)).toBe(true)
			end
			local watch = Abilities.watch
			t.expect(isFinitePositive(watch.sampleInterval)).toBe(true)
			t.expect(isFinitePositive(watch.catchUpSeconds)).toBe(true)
			t.expect(watch.startSpeedHeadroom >= 0).toBe(true)
			-- Several samples land inside even the hop's window.
			t.expect(watch.sampleInterval * 4 <= Abilities.boostHop.durationSeconds).toBe(true)
			t.expect(Abilities.unstuck.probeInset >= 0).toBe(true)
		end)

		t.it("keeps the hop's speed gain inside AntiExploit's headroom at every hop trim's top speed", function()
			local gain = Abilities.bounds.boostHop.maxSpeedGain
			for key, list in Abilities.byTrim do
				if table.find(list, "boostHop") ~= nil then
					local vehicleId, trimId = string.match(key, "^([^/]+)/([^/]+)$")
					local trim = Catalog.getTrim(vehicleId :: string, trimId :: string)
					t.expect(trim ~= nil).toBe(true)
					if trim ~= nil then
						local topSpeed = Units.mphToStuds(trim.topSpeedMph)
						-- Once the allowance ends, a car that hopped at top speed is still under the normal cap.
						local limits = MotionGuard.limits(topSpeed, AntiExploit)
						t.expect(topSpeed + gain <= limits.maxHorizontalSpeed).toBe(true)
					end
				end
			end
		end)

		t.it("hovers at PLAN.md's 25 studs and leaves room above it", function()
			t.expect(Abilities.flight.hoverHeight).toBe(PLAN_HOVER_HEIGHT)
			t.expect(Abilities.bounds.flight.maxHeight).toBeGreaterThan(Abilities.flight.hoverHeight)
		end)

		t.it("keeps the contract's thruster tunables positive and finite, and the landing within its bounds", function()
			local hop, flight = Abilities.boostHop, Abilities.flight
			for _, value in { hop.upAccel, hop.forwardAccel, hop.landingDescentRate } do
				t.expect(isFinitePositive(value)).toBe(true)
			end
			for _, value in { flight.hoverHeight, flight.rollRate, flight.flipRate, flight.landingDescentRate } do
				t.expect(isFinitePositive(value)).toBe(true)
			end
			t.expect(flight.landingDescentRate <= Abilities.bounds.flight.maxDownSpeed).toBe(true)
		end)

		t.it("tests upright as a real tilt", function()
			t.expect(Abilities.uprightDot).toBeGreaterThan(0)
			t.expect(Abilities.uprightDot).toBeLessThan(1)
		end)

		t.it("uses the attribute names in the contract", function()
			local attributes = Abilities.attributes
			t.expect(attributes.ability).toBe("Ability")
			t.expect(attributes.startsAt).toBe("AbilityStartsAt")
			t.expect(attributes.endsAt).toBe("AbilityEndsAt")
			t.expect(attributes.readyAt.boostHop).toBe("boostHopReadyAt")
			t.expect(attributes.readyAt.flight).toBe("flightReadyAt")
		end)

		t.it("words every message in plain language", function()
			local all: { string } = {}
			allStrings(messages, all)
			for _, text in all do
				t.expect(#text).toBeGreaterThan(0)
			end
			for _, ability in Abilities.ids do
				t.expect(type(messages.noAbility[ability])).toBe("string")
				t.expect(type(messages.started[ability])).toBe("string")
			end
			t.expect(string.format(messages.recharging, 12)).toBe("Recharging: 12 s")
			t.expect(string.format(messages.tooSlow, Abilities.boostHop.minSpeedMph)).toBe("Boost needs 20 mph.")
		end)
	end)

	t.describe("AbilityService.decide", function()
		t.it("lets the owner hop from the driver's seat at speed", function()
			local ok, message = AbilityService.decide({ ability = "boostHop" }, hopFacts(), NOW)
			t.expect(ok).toBe(true)
			t.expect(message).toBe(messages.started.boostHop)
		end)

		t.it("lets Arc Flight fly over the Flight Field, and hop too", function()
			local ok, message = AbilityService.decide({ ability = "flight" }, flightFacts(), NOW)
			t.expect(ok).toBe(true)
			t.expect(message).toBe(messages.started.flight)
			local hop = flightFacts()
			hop.speed = Units.mphToStuds(30)
			t.expect((AbilityService.decide({ ability = "boostHop" }, hop, NOW))).toBe(true)
		end)

		t.it("refuses a request that isn't an ability", function()
			local requests: { any } = { "boostHop", 5, {}, { ability = "teleport" }, { ability = 5 } }
			for _, request in requests do
				local ok, message = AbilityService.decide(request, hopFacts(), NOW)
				t.expect(ok).toBe(false)
				t.expect(message).toBe(messages.unknown)
			end
			local none, noneMessage = AbilityService.decide(nil, hopFacts(), NOW)
			t.expect(none).toBe(false)
			t.expect(noneMessage).toBe(messages.unknown)
			local ok = AbilityService.decide({ ability = "BoostHop" }, hopFacts(), NOW)
			t.expect(ok).toBe(false)
		end)

		t.it("refuses without a car", function()
			local facts = hopFacts()
			facts.hasCar = false
			local ok, message = AbilityService.decide({ ability = "boostHop" }, facts, NOW)
			t.expect(ok).toBe(false)
			t.expect(message).toBe(messages.noCar)
		end)

		t.it("refuses a car the caller doesn't own, even from its driver's seat", function()
			local facts = hopFacts()
			facts.isOwner = false
			local ok, message = AbilityService.decide({ ability = "boostHop" }, facts, NOW)
			t.expect(ok).toBe(false)
			t.expect(message).toBe(messages.notOwner)
		end)

		t.it("refuses the owner when they aren't in the driver's seat", function()
			local facts = hopFacts()
			facts.isDriver = false
			local ok, message = AbilityService.decide({ ability = "boostHop" }, facts, NOW)
			t.expect(ok).toBe(false)
			t.expect(message).toBe(messages.notDriver)
		end)

		t.it("refuses a car that isn't being driven (parked, not tracked)", function()
			local facts = hopFacts()
			facts.tracked = false
			local ok, message = AbilityService.decide({ ability = "boostHop" }, facts, NOW)
			t.expect(ok).toBe(false)
			t.expect(message).toBe(messages.notDriving)
			local lost = hopFacts()
			lost.position = nil
			t.expect((AbilityService.decide({ ability = "boostHop" }, lost, NOW))).toBe(false)
		end)

		t.it("refuses a trim without the ability", function()
			local base = hopFacts()
			base.trimId = "performance"
			local ok, message = AbilityService.decide({ ability = "boostHop" }, base, NOW)
			t.expect(ok).toBe(false)
			t.expect(message).toBe(messages.noAbility.boostHop)

			local boost = hopFacts()
			boost.position = FLIGHT_FIELD
			ok, message = AbilityService.decide({ ability = "flight" }, boost, NOW)
			t.expect(ok).toBe(false)
			t.expect(message).toBe(messages.noAbility.flight)

			local other = hopFacts()
			other.vehicleId = "ohm_grand"
			t.expect((AbilityService.decide({ ability = "boostHop" }, other, NOW))).toBe(false)
			local unknown = hopFacts()
			unknown.vehicleId = nil
			unknown.trimId = nil
			t.expect((AbilityService.decide({ ability = "boostHop" }, unknown, NOW))).toBe(false)
		end)

		t.it("refuses while another ability, or its landing and settle, is running", function()
			local facts = flightFacts()
			facts.running = true
			for _, ability in Abilities.ids do
				local ok, message = AbilityService.decide({ ability = ability }, facts, NOW)
				t.expect(ok).toBe(false)
				t.expect(message).toBe(messages.busy)
			end
		end)

		t.it("refuses on cooldown and says how long, until the moment it is ready", function()
			local facts = hopFacts()
			facts.readyAt = { boostHop = NOW + 12 }
			local ok, message = AbilityService.decide({ ability = "boostHop" }, facts, NOW)
			t.expect(ok).toBe(false)
			t.expect(message).toBe("Recharging: 12 s")
			facts.readyAt = { boostHop = NOW + 11.2 }
			ok, message = AbilityService.decide({ ability = "boostHop" }, facts, NOW)
			t.expect(message).toBe("Recharging: 12 s")
			facts.readyAt = { boostHop = NOW + 0.01 }
			ok, message = AbilityService.decide({ ability = "boostHop" }, facts, NOW)
			t.expect(ok).toBe(false)
			t.expect(message).toBe("Recharging: 1 s")
			facts.readyAt = { boostHop = NOW }
			t.expect((AbilityService.decide({ ability = "boostHop" }, facts, NOW))).toBe(true)
		end)

		t.it("keeps each ability's cooldown its own", function()
			local facts = flightFacts()
			facts.speed = Units.mphToStuds(30)
			facts.readyAt = { flight = NOW + 30 }
			t.expect((AbilityService.decide({ ability = "flight" }, facts, NOW))).toBe(false)
			t.expect((AbilityService.decide({ ability = "boostHop" }, facts, NOW))).toBe(true)
		end)

		t.it("ignores anything else a forged request carries", function()
			local forged = {
				ability = "boostHop",
				readyAt = 0,
				speed = 999,
				owner = true,
				position = DOWNTOWN,
				zone = "ms_flight_field",
			}
			local cooling = hopFacts()
			cooling.readyAt = { boostHop = NOW + 5 }
			t.expect((AbilityService.decide(forged, cooling, NOW))).toBe(false)
			local slow = hopFacts()
			slow.speed = 0
			t.expect((AbilityService.decide(forged, slow, NOW))).toBe(false)
			local stranger = hopFacts()
			stranger.isOwner = false
			t.expect((AbilityService.decide(forged, stranger, NOW))).toBe(false)
			local grounded = hopFacts()
			grounded.trimId = "flight"
			local fly = table.clone(forged)
			fly.ability = "flight"
			t.expect((AbilityService.decide(fly, grounded, NOW))).toBe(false) -- downtown, outside the Flight Field
		end)

		t.it("refuses both abilities inside a NoFlyZone", function()
			t.expect(noFlyZone ~= nil).toBe(true)
			local hop = hopFacts()
			hop.position = NO_FLY
			local ok, message = AbilityService.decide({ ability = "boostHop" }, hop, NOW)
			t.expect(ok).toBe(false)
			t.expect(message).toBe(messages.noFlyZone)
			local flight = flightFacts()
			flight.position = NO_FLY
			ok, message = AbilityService.decide({ ability = "flight" }, flight, NOW)
			t.expect(ok).toBe(false)
			t.expect(message).toBe(messages.noFlyZone)
		end)

		t.it("refuses flight outside every FlightZone", function()
			local facts = flightFacts()
			facts.position = DOWNTOWN
			local ok, message = AbilityService.decide({ ability = "flight" }, facts, NOW)
			t.expect(ok).toBe(false)
			t.expect(message).toBe(messages.flightZone)
			-- Above the Flight Field's volume counts as outside it.
			if flightField ~= nil then
				facts.position = flightField.position + Vector3.yAxis * (flightField.size.Y + 5)
				t.expect((AbilityService.decide({ ability = "flight" }, facts, NOW))).toBe(false)
			end
		end)

		t.it("refuses a hop below 20 mph by the server's smoothed speed", function()
			local facts = hopFacts()
			for _, speed in { Units.mphToStuds(19.9), 0, 0 / 0 } do
				facts.speed = speed
				local ok, message = AbilityService.decide({ ability = "boostHop" }, facts, NOW)
				t.expect(ok).toBe(false)
				t.expect(message).toBe("Boost needs 20 mph.")
			end
			facts.speed = nil
			t.expect((AbilityService.decide({ ability = "boostHop" }, facts, NOW))).toBe(false)
			facts.speed = Units.mphToStuds(Abilities.boostHop.minSpeedMph)
			t.expect((AbilityService.decide({ ability = "boostHop" }, facts, NOW))).toBe(true)
		end)

		t.it("lets flight take off standing still", function()
			local facts = flightFacts()
			facts.speed = nil
			t.expect((AbilityService.decide({ ability = "flight" }, facts, NOW))).toBe(true)
		end)
	end)

	t.describe("AbilityService zones", function()
		t.it("finds the Flight Field and a no-fly zone on the map, apart", function()
			t.expect(flightField ~= nil).toBe(true)
			t.expect(noFlyZone ~= nil).toBe(true)
			local inFlight, inNoFly = AbilityService.zonesAt(FLIGHT_FIELD)
			t.expect(inFlight).toBe(true)
			t.expect(inNoFly).toBe(false)
			inFlight, inNoFly = AbilityService.zonesAt(NO_FLY)
			t.expect(inFlight).toBe(false)
			t.expect(inNoFly).toBe(true)
			inFlight, inNoFly = AbilityService.zonesAt(DOWNTOWN)
			t.expect(inFlight).toBe(false)
			t.expect(inNoFly).toBe(false)
		end)

		t.it("turns a volume to its yaw", function()
			local volume: MapLayout.Location = {
				id = "spec_volume",
				displayName = "Spec volume",
				tag = "FlightZone",
				zone = "mesa_test_site",
				position = Vector3.zero,
				yaw = 90, -- its X axis (100 studs long) runs north-south
				size = Vector3.new(100, 10, 20),
			}
			t.expect(AbilityService.insideVolume(volume, Vector3.new(0, 1, 40))).toBe(true)
			t.expect(AbilityService.insideVolume(volume, Vector3.new(40, 1, 0))).toBe(false)
			volume.yaw = 0
			t.expect(AbilityService.insideVolume(volume, Vector3.new(0, 1, 40))).toBe(false)
			t.expect(AbilityService.insideVolume(volume, Vector3.new(40, 1, 0))).toBe(true)
		end)

		t.it("runs from the volume's surface up to its height", function()
			local volume: MapLayout.Location = {
				id = "spec_volume",
				displayName = "Spec volume",
				tag = "NoFlyZone",
				zone = "mesa_test_site",
				position = Vector3.new(0, 10, 0),
				yaw = 0,
				size = Vector3.new(20, 30, 20),
			}
			t.expect(AbilityService.insideVolume(volume, Vector3.new(0, 11, 0))).toBe(true)
			t.expect(AbilityService.insideVolume(volume, Vector3.new(0, 39, 0))).toBe(true)
			t.expect(AbilityService.insideVolume(volume, Vector3.new(0, 9, 0))).toBe(false)
			t.expect(AbilityService.insideVolume(volume, Vector3.new(0, 41, 0))).toBe(false)
		end)
	end)

	t.describe("AntiExploit allowance", function()
		t.it("gives the hop its speed gain and both abilities their climb on top of driving's", function()
			local driving = AntiExploit.verticalSpeedAllowance
			local hop = AbilityService.allowanceFor("boostHop")
			t.expect(hop.extraSpeed).toBe(Abilities.bounds.boostHop.maxSpeedGain)
			t.expect(hop.riseSpeed).toBe(Abilities.bounds.boostHop.maxUpSpeed + driving)
			local flight = AbilityService.allowanceFor("flight")
			t.expect(flight.extraSpeed).toBe(0)
			t.expect(flight.riseSpeed).toBe(Abilities.bounds.flight.maxUpSpeed + driving)
		end)

		t.it("widens a car's limits and never narrows them", function()
			local limits = MotionGuard.limits(100, AntiExploit)
			local wide = MotionGuard.widen(limits, 40, 0, AntiExploit)
			t.expect(wide.maxHorizontalSpeed).toBeNear(limits.maxHorizontalSpeed + 40, TOLERANCE)
			t.expect(wide.maxRiseSpeed).toBeNear(limits.maxRiseSpeed + 40, TOLERANCE)
			t.expect(wide.maxCredit).toBeNear(wide.maxHorizontalSpeed * AntiExploit.catchUpSeconds, TOLERANCE)
			t.expect(wide.teleportDistance).toBe(limits.teleportDistance)

			local climb = MotionGuard.widen(limits, 0, limits.maxRiseSpeed + 500, AntiExploit)
			t.expect(climb.maxHorizontalSpeed).toBe(limits.maxHorizontalSpeed)
			t.expect(climb.maxRiseSpeed).toBe(limits.maxRiseSpeed + 500)

			local none = MotionGuard.widen(limits, -50, 1, AntiExploit)
			t.expect(none.maxHorizontalSpeed).toBe(limits.maxHorizontalSpeed)
			t.expect(none.maxRiseSpeed).toBe(limits.maxRiseSpeed)
		end)
	end)

	t.describe("AbilityService watch", function()
		t.it("holds the hop to its climb only, and flight to every bound", function()
			local driving = AntiExploit.verticalSpeedAllowance
			local hop = AbilityService.watchBounds("boostHop", 100)
			t.expect(hop.maxUpSpeed).toBe(Abilities.bounds.boostHop.maxUpSpeed + driving)
			t.expect(hop.maxDownSpeed).toBe(nil)
			t.expect(hop.maxHorizontalSpeed).toBe(nil)
			t.expect(hop.maxHeight).toBe(nil)

			local flight = Abilities.bounds.flight
			local still = AbilityService.watchBounds("flight", 0)
			t.expect(still.maxUpSpeed).toBe(flight.maxUpSpeed + driving)
			t.expect(still.maxDownSpeed).toBe(flight.maxDownSpeed)
			t.expect(still.maxHeight).toBe(flight.maxHeight)
			t.expect(still.maxHorizontalSpeed)
				.toBe(math.max(flight.maxHorizontalSpeed, Abilities.watch.startSpeedHeadroom))
			local fast = AbilityService.watchBounds("flight", 300)
			t.expect(fast.maxHorizontalSpeed).toBe(300 + Abilities.watch.startSpeedHeadroom)
			t.expect(AbilityService.watchBounds("flight", nil).maxHorizontalSpeed).toBe(still.maxHorizontalSpeed)
			for _, broken in { 0 / 0, math.huge, -50 } do
				local bounds = AbilityService.watchBounds("flight", broken)
				t.expect(bounds.maxHorizontalSpeed).toBe(still.maxHorizontalSpeed)
			end
		end)

		t.it("stops judging speed across the ground once the window is over", function()
			local window = AbilityService.watchBounds("flight", 0)
			local landing = AbilityService.landingBounds(window)
			t.expect(landing.maxHorizontalSpeed).toBe(nil)
			t.expect(landing.maxUpSpeed).toBe(window.maxUpSpeed)
			t.expect(landing.maxDownSpeed).toBe(window.maxDownSpeed)
			t.expect(landing.maxHeight).toBe(window.maxHeight)
			-- Back on its wheels after landing, an Arc may floor it.
			local fast = Vector3.new(Units.mphToStuds(200), 0, 0)
			t.expect(runAt(landing, Vector3.zero, fast, 3)).toBe("ok")
			t.expect(runAt(window, Vector3.zero, fast, 3)).toBe("speed")
		end)

		t.it("passes a climb at the bound and catches one well over it", function()
			local bounds = AbilityService.watchBounds("boostHop", 0)
			local up = Vector3.yAxis * bounds.maxUpSpeed
			t.expect(runAt(bounds, Vector3.zero, up, 3)).toBe("ok")
			t.expect(runAt(bounds, Vector3.zero, up * 2, 1)).toBe("climb")
		end)

		t.it("banks credit for a stall in the server's view and its catch-up", function()
			local bounds = AbilityService.watchBounds("flight", 0)
			local step = Abilities.watch.sampleInterval
			local rate = bounds.maxUpSpeed
			local watch = AbilityService.newWatch(Vector3.zero, 0, bounds)
			t.expect((AbilityService.judge(watch, Vector3.new(0, rate * step, 0), step, 0, bounds))).toBe("ok")
			-- Stalled for a sample, then caught up in one.
			t.expect((AbilityService.judge(watch, Vector3.new(0, rate * step, 0), 2 * step, 0, bounds))).toBe("ok")
			t.expect((AbilityService.judge(watch, Vector3.new(0, rate * step * 3, 0), 3 * step, 0, bounds))).toBe("ok")
		end)

		t.it("lets a flying car drop from its highest allowed point in a free fall", function()
			local bounds = AbilityService.watchBounds("flight", 0)
			local top = Abilities.bounds.flight.maxHeight
			local gravity = Workspace.Gravity
			local step = Abilities.watch.sampleInterval
			local watch = AbilityService.newWatch(Vector3.new(0, top, 0), 0, bounds)
			local time = 0
			while time < 3 do
				time += step
				local y = math.max(top - 0.5 * gravity * time * time, 0)
				t.expect((AbilityService.judge(watch, Vector3.new(0, y, 0), time, y, bounds))).toBe("ok")
			end
		end)

		t.it("catches a dive much faster than the fall bound", function()
			local bounds = AbilityService.watchBounds("flight", 0)
			local down = Vector3.yAxis * -(bounds.maxDownSpeed :: number) * 3
			t.expect(runAt(bounds, Vector3.new(0, 40, 0), down, 1)).toBe("fall")
		end)

		t.it("leaves a hop's fall and its speed across the ground to AntiExploit", function()
			local bounds = AbilityService.watchBounds("boostHop", 0)
			t.expect(runAt(bounds, Vector3.zero, Vector3.new(900, -300, 0), 1)).toBe("ok")
		end)

		t.it("lets a flying car keep its take-off speed but catches a gain", function()
			local bounds = AbilityService.watchBounds("flight", 200)
			t.expect(runAt(bounds, Vector3.zero, Vector3.new(200, 0, 0), 4)).toBe("ok")
			t.expect(runAt(bounds, Vector3.zero, Vector3.new(0, 0, -400), 2)).toBe("speed")
			local still = AbilityService.watchBounds("flight", 0)
			t.expect(runAt(still, Vector3.zero, Vector3.new(still.maxHorizontalSpeed :: number, 0, 0), 4)).toBe("ok")
			t.expect(runAt(still, Vector3.zero, Vector3.new((still.maxHorizontalSpeed :: number) * 2, 0, 0), 2))
				.toBe("speed")
		end)

		t.it("catches a flying car above its highest allowed point", function()
			local bounds = AbilityService.watchBounds("flight", 0)
			local top = Abilities.bounds.flight.maxHeight
			local step = Abilities.watch.sampleInterval
			local watch = AbilityService.newWatch(Vector3.new(0, top, 0), 0, bounds)
			t.expect((AbilityService.judge(watch, Vector3.new(0, top, 0), step, top, bounds))).toBe("ok")
			local verdict = AbilityService.judge(watch, Vector3.new(0, top + 1, 0), 2 * step, top + 1, bounds)
			t.expect(verdict).toBe("height")
			-- The hop has no height bound.
			local hop = AbilityService.watchBounds("boostHop", 0)
			local hopWatch = AbilityService.newWatch(Vector3.new(0, top, 0), 0, hop)
			t.expect((AbilityService.judge(hopWatch, Vector3.new(0, top + 1, 0), step, top + 1000, hop))).toBe("ok")
		end)

		t.it("catches a forged position and keeps the last good sample after an offense", function()
			local bounds = AbilityService.watchBounds("flight", 0)
			local watch = AbilityService.newWatch(Vector3.zero, 0, bounds)
			local nan = 0 / 0
			t.expect((AbilityService.judge(watch, Vector3.new(nan, 0, 0), 0.25, 0, bounds))).toBe("speed")
			t.expect((AbilityService.judge(watch, Vector3.new(0, 1e6, 0), 0.5, 0, bounds))).toBe("climb")
			t.expect(watch.position).toBe(Vector3.zero)
			t.expect(watch.time).toBe(0)
		end)
	end)

	t.describe("AbilityService unstuck", function()
		t.it("calls a car upright on its wheels and not on its side or roof", function()
			t.expect(AbilityService.isUpright(CFrame.new())).toBe(true)
			t.expect(AbilityService.isUpright(CFrame.Angles(math.rad(30), 0, math.rad(10)))).toBe(true)
			t.expect(AbilityService.isUpright(CFrame.Angles(0, 0, math.rad(90)))).toBe(false)
			t.expect(AbilityService.isUpright(CFrame.Angles(math.rad(180), 0, 0))).toBe(false)
		end)

		t.it("keeps right by half the lanes each way", function()
			local lane = World.laneWidth
			t.expect(AbilityService.rightLaneOffset(1, lane)).toBe(0)
			t.expect(AbilityService.rightLaneOffset(2, lane)).toBe(lane / 2)
			t.expect(AbilityService.rightLaneOffset(3, lane)).toBe(lane)
			t.expect(AbilityService.rightLaneOffset(4, lane)).toBe(lane)
		end)

		t.it("puts a stuck car in the right-hand lane of the nearest road, facing along it", function()
			for _, from in { FLIGHT_FIELD, NO_FLY, DOWNTOWN, Vector3.new(1100, 32, -2400) } do
				local edgeIndex, _, _, point = Graph.nearestEdge(from)
				t.expect(edgeIndex ~= nil).toBe(true)
				if edgeIndex == nil then
					continue
				end
				local edge = Graph.edges()[edgeIndex]
				local a, b = Graph.node(edge.from), Graph.node(edge.to)
				if a == nil or b == nil then
					continue
				end
				local along = Vector3.new(b.position.X - a.position.X, 0, b.position.Z - a.position.Z).Unit
				for _, heading in { along, -along } do
					local pose = AbilityService.roadPose(from, heading)
					t.expect(pose ~= nil).toBe(true)
					if pose == nil then
						continue
					end
					t.expect(Graph.isOnRoad(pose.Position)).toBe(true)
					t.expect(pose.UpVector.Y).toBeNear(1, TOLERANCE)
					t.expect(pose.LookVector:Dot(heading)).toBeNear(1, TOLERANCE)
					-- Right of the centre line, looking the way it faces.
					local right = Vector3.new(-pose.LookVector.Z, 0, pose.LookVector.X)
					local offset = AbilityService.rightLaneOffset(edge.lanes, World.laneWidth)
					t.expect((pose.Position - point):Dot(right)).toBeNear(offset, TOLERANCE * 100)
				end
			end
		end)
	end)
end
