--!strict
-- Rules for the Arc's thrusters (PLAN.md Phase 10; docs/phase-10-contracts.md "Abilities, server"): which trims
-- have which ability, the cooldowns, how long each one runs, the hop's minimum speed, the bounds the server holds
-- a car to while an ability runs and settles, the upright test after it, and what players are told.
--
-- It also holds the contract's thruster tunables (docs/phase-10-contracts.md): the push sizes as accelerations,
-- the hover height, the roll and flip rates and the landing descent rates. Config/Thrusters reads them from here
-- and adds the finer feel (the hover spring, levelling, plumes).
--
-- Read by Services/AbilityService (the server decides every rule here), Controllers/AbilityController (which
-- trims get a Boost / Fly button, the cooldown ring), Config/Thrusters and tests/Ability.spec.
-- tests/Thrusters.spec checks the feel stays inside `bounds` here, and tests/Ability.spec checks these numbers
-- fit together and match PLAN.md.

export type AbilityId = "boostHop" | "flight"

-- One ability's timing. Every time is in seconds.
export type Timing = {
	cooldownSeconds: number, -- from the moment it starts until it can be used again
	durationSeconds: number, -- the window the owner's client pushes in: AbilityEndsAt = AbilityStartsAt + this
	-- After the window the car is still coming down (the hop's arc, the flight's controlled landing). The server
	-- keeps the allowance and keeps checking the bounds for this long, then settles. The client's own landing
	-- timeout (Config/Thrusters) must be no longer than this.
	landingSeconds: number,
}

local Abilities = {
	-- Every ability id, in the order the HUD lists them.
	ids = { "boostHop", "flight" } :: { AbilityId },

	-- Which trims have which abilities, keyed "vehicleId/trimId". Nothing else has any.
	byTrim = {
		["ohm_arc/boost"] = { "boostHop" },
		["ohm_arc/flight"] = { "boostHop", "flight" },
	} :: { [string]: { AbilityId } },

	-- Boost-hop: a forward and upward push for about 2 s, only once the car is moving.
	boostHop = {
		cooldownSeconds = 20,
		durationSeconds = 2,
		landingSeconds = 1.5, -- a hop that peaks well under 20 studs is back down in under a second
		-- The car must already be doing this speed (the server's smoothed speed across the ground).
		minSpeedMph = 20,
		-- The push (Vehicle/Thrusters, through Config/Thrusters), as accelerations in studs/s² so it is the same
		-- at any mass: up, on top of holding off gravity, for the first part of the window (Config/Thrusters
		-- hop.liftSeconds), and along the nose for the whole window. Both stop at the bounds below.
		upAccel = 90,
		forwardAccel = 45,
		-- After the window, a hop still in the air falls no faster than this until its wheels touch (studs/s).
		landingDescentRate = 24,
	},

	-- Flight: hover up to the hover height with roll and flip for up to 4 s, then a controlled landing. Only inside
	-- a FlightZone.
	flight = {
		cooldownSeconds = 45,
		durationSeconds = 4,
		landingSeconds = 5, -- the slowest controlled landing from the hover height, with room to spare
		hoverHeight = 25, -- studs above where the car stands on its wheels (under bounds.flight.maxHeight)
		rollRate = 3.5, -- rad/s at full steer
		flipRate = 4, -- rad/s at full throttle or brake (a front or back flip)
		landingDescentRate = 15, -- the controlled landing's descent, studs/s (it slows over the last few studs)
	},

	-- What the server allows while an ability runs and through its landing and settle, in studs/s (maxHeight in
	-- studs). The owner's client pushes the car (Vehicle/Thrusters); its pushes must keep the car inside these.
	bounds = {
		boostHop = {
			-- Upward speed the hop may give the car, on top of what driving itself may (ramps, bumps:
			-- Config/AntiExploit.verticalSpeedAllowance). 80 studs/s peaks about 16 studs up.
			maxUpSpeed = 80,
			-- Speed across the ground the hop may add. AntiExploit's speed cap is raised by this for the window, the
			-- landing and the settle. Keep it inside AntiExploit's own headroom over the slowest ability trim's top
			-- speed, so a car that hopped at top speed is never over the normal cap once the allowance ends.
			maxSpeedGain = 40,
		},
		flight = {
			maxUpSpeed = 50, -- climbing to the hover height takes about a second
			-- Downward speed allowed while flying and landing. Above a free fall from maxHeight with the catch-up
			-- below, so a car the client lets drop never counts; a forced dive through the ground does.
			maxDownSpeed = 100,
			-- The thrusters never push a flying car across the ground faster than this; a car that took off faster
			-- may keep its take-off speed (plus watch.startSpeedHeadroom) but never gain. Judged during the window
			-- only: after it the car may be back on its wheels and driving off.
			maxHorizontalSpeed = 120,
			-- Highest the chassis may be above the ground under it while flying and landing (studs): the 25-stud
			-- flight.hoverHeight above with room for the spring's overshoot.
			maxHeight = 50,
		},
	},

	-- How the server watches a car while an ability runs (Services/AbilityService). It samples the chassis's
	-- server-side position every sampleInterval and judges each move with catch-up credit, like AntiExploit: the
	-- server's view of a client-driven car can stall and then jump ahead, so up to catchUpSeconds of travel at
	-- the bound is banked and may be spent by a later sample.
	watch = {
		sampleInterval = 0.25,
		catchUpSeconds = 0.5,
		-- Speed added to a flight's take-off speed (studs/s) for its across-the-ground bound: the smoothed speed
		-- lags a car that is still speeding up when it asks.
		startSpeedHeadroom = 40,
	},

	-- After the window and the landing, the server waits this long for the car to come to rest, then checks it is
	-- upright and not inside the map. A car that isn't is moved to the nearest road (VehicleService.resetCar).
	settleSeconds = 1.5,
	-- Upright: the chassis's up vector points at least this far up (UpVector.Y; 0.7 is about 45 degrees of tilt).
	uprightDot = 0.7,
	unstuck = {
		-- The overlap test uses the chassis box shrunk by this many studs on every side, so a car resting on the
		-- ground or against a wall doesn't count as inside it.
		probeInset = 0.2,
	},

	-- The map volumes, by their CollectionService tag in Config/MapLayout.
	zones = {
		flightTag = "FlightZone",
		noFlyTag = "NoFlyZone",
	},

	-- Car attributes the server sets (docs/phase-10-contracts.md "Shared names"); every client reads them.
	attributes = {
		ability = "Ability", -- the active ability id, or nil when none is running
		startsAt = "AbilityStartsAt", -- workspace:GetServerTimeNow() times of the active (or last) ability
		endsAt = "AbilityEndsAt",
		-- Server time each ability is usable again (absent = ready).
		readyAt = {
			boostHop = "boostHopReadyAt",
			flight = "flightReadyAt",
		} :: { [string]: string },
	},

	-- What players are told (UseAbility replies and notices).
	messages = {
		unknown = "That isn't something this car can do.",
		noCar = "Get in your car first.",
		notOwner = "Only the owner can use this car's thrusters.",
		notDriver = "Get in the driver's seat first.",
		notDriving = "Start driving first.",
		noAbility = {
			boostHop = "This car has no boost.",
			flight = "This car can't fly.",
		} :: { [string]: string },
		busy = "Wait for the landing first.",
		recharging = "Recharging: %d s", -- whole seconds left
		noFlyZone = "Thrusters are off in a no-fly zone.",
		flightZone = "Flight works only over the Flight Field.",
		tooSlow = "Boost needs %d mph.", -- Abilities.boostHop.minSpeedMph
		started = {
			boostHop = "Boost!",
			flight = "Flying!",
		} :: { [string]: string },
		unstuck = "Your car got stuck, so it was moved to the nearest road.",
		devOnly = "That only works in Studio.",
		cooldownsReset = "Thruster cooldowns cleared.",
	},
}

-- The abilities a trim has (empty for every trim not in byTrim).
function Abilities.forTrim(vehicleId: string, trimId: string): { AbilityId }
	return Abilities.byTrim[`{vehicleId}/{trimId}`] or {}
end

-- Whether a trim has `ability`.
function Abilities.has(vehicleId: string, trimId: string, ability: string): boolean
	return table.find(Abilities.forTrim(vehicleId, trimId), ability :: AbilityId) ~= nil
end

-- The timing of an ability id, or nil for anything else.
function Abilities.timing(ability: string): Timing?
	if ability == "boostHop" then
		return Abilities.boostHop
	elseif ability == "flight" then
		return Abilities.flight
	end
	return nil
end

return Abilities
