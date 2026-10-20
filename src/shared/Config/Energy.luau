--!strict
-- Energy tunables (PLAN.md §3.3 and Phase 5; docs/phase-5-contracts.md "Model"): how fast a battery or tank
-- drains, how fast chargers and pumps fill it and what that costs, the low-energy alerts and limp mode, the
-- charging-plaza hangout bonus, and how often the server samples. Vehicle/Energy (pure, covered by
-- tests/Energy.spec) turns these into rates; Services/EnergyService applies them to spawned cars.
--
-- Levels are fractions 0..1 of a full charge or tank. Speeds the model reads are studs/s, accelerations
-- studs/s² and climbs studs/s (vertical speed, positive up), the same units as Vehicle/Tuning and
-- Vehicle/Powertrain. Pure data: no requires and no Roblox types, so any module can read it.
--
-- Cruise calibration. The catalog's energyMinutes ("a full charge lasts about N minutes of driving") is
-- defined at `cruiseMph` on the flat: at that steady speed a car drains exactly 1 / (energyMinutes × 60) of a
-- full charge per second, so a full charge lasts the catalog's minutes. 45 mph is the county's arterial speed
-- limit (Config/RoadGraph), sits between Cedar Bend's 30-35 mph grid and the County Loop's 70 mph, is close to
-- the 40 mph average a mid-skill driver keeps (Config/DriveEarn), every class can hold it (the slowest, heavy,
-- tops out at 60-80 mph), and it is the AutoDriver's default cruise, so Dev/EnergyTests can check it directly.
--
-- Drain shape. Every other term is relative to that cruise rate (a "load" of 1 = cruising):
--   load = idle share
--        + speed load       (1 - idle share) × (linear share × x + (1 - linear share) × x²), x = speed / cruise,
--                           capped at maxSpeedLoad; at cruise this and the idle share add up to exactly 1
--        + launch load      k × speed × accel, with k set so one flat 0→60 mph launch costs launchCruiseSeconds
--                           of cruising (kinetic energy ∝ speed², so the cost per second is ∝ speed × accel)
--        + climb load       climbCruiseSecondsPerStud × climb (potential energy ∝ height)
-- Accelerations smaller than accelDeadband count as steady driving (sample-to-sample jitter is not a launch).
-- Slowing down and descending give a negative launch or climb load. That first pays for the speed load (a car
-- coasting or rolling downhill isn't pushed by its engine or motor, so the drag it loses speed to isn't billed
-- twice), but never below the idle share. What is left past that is braking: battery cars get regenEfficiency
-- of it back below idle (regen); fuel cars get nothing back. The total is clamped to 0..maxLoad, so a car never
-- gains energy by driving and a glitchy sample cannot empty a battery at once.
--
-- Costs are a sink, not a wall (PLAN.md §4). A full charge at a stall costs $300 (a 10→80 % top-up $210):
-- about one minute of free driving ($300/min) and well under a minute of any job ($1,000-$3,000/min), while
-- the 18-55 minutes of driving it buys earn thousands. Starting cash ($2,500) covers about eight full
-- charges, so a new player is never stranded. Fuel costs a little more per % than a stall ($400 a tank)
-- because pumps fill about three times faster, which keeps chargers (and the plaza hangouts) the default
-- (§3.3: EV-majority). The truck charger costs the most per % ($500) since only the semi uses it and freight
-- pays $3,000/min. EnergyService bills for the energy actually added, in whole dollars (cents carry over within
-- a stop); each cost per full is a multiple of 100, so every % costs whole dollars.

export type StationKind = "ChargerStall" | "TruckCharger" | "FuelPump"

-- One point on the charger curve: a stall of `kW` takes `tenToEightySeconds` to go from 10 % to 80 %.
export type ChargePoint = { kW: number, tenToEightySeconds: number }

local Energy = {
	-- Reference cruise speed for the catalog's energyMinutes (see the calibration above). mph.
	cruiseMph = 45,

	drain = {
		-- Share of the cruise rate a car uses standing still (lights and electronics). Tiny: a parked 25-minute
		-- car would take about 21 hours to empty.
		idleShare = 0.02,
		-- Share of the moving load that grows with speed (rolling and drivetrain); the rest grows with speed²
		-- (air). At 70 mph a car drains about 1.9× its cruise rate (about 1.2× per mile).
		linearShare = 0.6,
		-- The speed load never exceeds this many times the cruise rate, so a hypercar flat out still gets a
		-- few minutes of driving (and miles of range) rather than seconds.
		maxSpeedLoad = 5,
		-- One flat 0→60 mph launch costs as much as this many seconds of cruising.
		launchCruiseSeconds = 15,
		-- Each stud of climbing costs this many seconds of cruising (a 100-stud climb ≈ 30 s; a 10 % grade at
		-- cruise roughly triples the drain).
		climbCruiseSecondsPerStud = 0.3,
		-- Share of the launch and climb energy a battery car gets back when it slows down or goes downhill.
		-- Fuel cars get none.
		regenEfficiency = 0.6,
		-- The total load is clamped to this many times the cruise rate.
		maxLoad = 20,
		-- Speeding up or slowing down by less than this (studs/s², about 0.13 g; a real launch is 10-50) counts as
		-- holding speed: the server's view of a steady car wobbles, and that wobble must not add up to extra
		-- drain. Measured in Studio: before smoothing and this band, a steady 45 mph cruise drained 2.8× too fast.
		accelDeadband = 4,
		-- Climbing or descending slower than this (studs/s; a 10 % grade at cruise is about 7) counts as flat,
		-- for the same reason (suspension bounce shows up as tiny climbs).
		climbDeadband = 0.75,
	},

	-- Low-energy alerts (fractions): a notice at each, once per drop below it. The HUD turns amber under
	-- warningLevel and red under criticalLevel.
	warningLevel = 0.2,
	criticalLevel = 0.1,

	-- Limp mode: at 0 the car is held to this speed (mph) until it is charged above limpClearLevel.
	limpMph = 15,
	limpClearLevel = 0.02,
	-- A car that runs dry while driving gets this long (seconds) to slow to the limp speed before AntiExploit
	-- judges it by that speed (sooner once it is at the limp speed). The client brakes an over-speed car back
	-- under its cap in about a second (Config/Driving overspeedBrakeGain), so this is generous.
	limpCapGraceSeconds = 4,

	-- Which station kinds fill which energy kind, and which classes may use the truck charger.
	stationEnergy = {
		ChargerStall = "battery",
		TruckCharger = "battery",
		FuelPump = "fuel",
	} :: { [StationKind]: "battery" | "fuel" },
	truckChargerClasses = { "heavy" },

	charging = {
		-- Charger power (the station's `kW` attribute, Config/MapLayout) → seconds from 10 % to 80 %. Linear
		-- between points, clamped at the ends. The county's stalls are 150, 250 and 350 kW: the 350 kW stalls
		-- do 10→80 % in 65 s, 250 kW in 75 s, 150 kW in 85 s, inside PLAN.md's 60-90 s with room for the
		-- server's sampling steps. The 750 kW truck chargers do it in 40 s, faster than any stall. The time
		-- does not depend on the car: what players compare is the stall.
		curve = {
			{ kW = 150, tenToEightySeconds = 85 },
			{ kW = 350, tenToEightySeconds = 65 },
			{ kW = 750, tenToEightySeconds = 40 },
		} :: { ChargePoint },
		-- Used when a station has no valid kW attribute.
		defaultKW = {
			ChargerStall = 150,
			TruckCharger = 750,
		} :: { [StationKind]: number },
		-- Above taperStart the rate falls linearly to taperFloor × the full rate at 100 % (batteries only).
		-- At the fastest stall 80→100 % then takes about 26 s instead of 17 s.
		taperStart = 0.8,
		taperFloor = 0.4,
		-- A stop only starts charging or fueling at or below this level (at least a whole % missing). A car
		-- left sitting on a pad after a full charge loses a sliver to the idle drain; that alone never starts a
		-- new stop.
		startBelow = 0.99,
	},

	fueling = {
		-- A pump's `rate` attribute is percent of the tank per second (Config/MapLayout: 4, so 10→100 % in
		-- 22.5 s). rateScale multiplies it; defaultRate is used when the attribute is missing or invalid.
		rateScale = 1,
		defaultRate = 4,
	},

	-- $ for a full 0→1 charge or tank by station kind (see "Costs" above). Multiples of 100: whole $ per %.
	costPerFull = {
		ChargerStall = 300,
		TruckCharger = 500,
		FuelPump = 400,
	} :: { [StationKind]: number },

	-- The charging-plaza hangout bonus: while at least minPlayers players charge at stalls with the same
	-- `plaza` attribute, each earns cashPerMinute for the time they charge together, paid every interval
	-- seconds (EconomyService.add, reason "hangout"). A small trickle: a 60-90 s top-up earns back a quarter to
	-- a third of its cost, and it stops at full.
	hangout = {
		minPlayers = 3,
		cashPerMinute = 50,
		interval = 60,
	},

	sampling = {
		-- Seconds between EnergyService samples of every spawned car (a Heartbeat accumulator).
		interval = 0.25,
		-- Time constant (seconds) of the smoothing EnergyService puts on speed and climb before billing drain.
		smoothingSeconds = 2,
		-- Write a driven car's level back to its owned vehicle at most this often (seconds); also on put-away
		-- and on leaving.
		saveInterval = 60,
		-- The `Energy` attribute is rounded to this step.
		attributeStep = 0.001,
		-- A car counts as parked at a station below this speed (mph).
		stationStillMph = 2,
		-- The car's replicated velocity sets its speed (and acceleration) while it is within this many studs/s
		-- of the ground speed the server measures from positions; otherwise the ground speed does. Covers the
		-- ground speed's lag behind a hard launch (it is averaged over AntiExploit's sample interval) and the
		-- jitter in when positions arrive, and bounds what a client can claim with its velocity.
		speedAgreement = 8,
		-- A chassis that moved less than this (studs) since the last sample counts as not having moved (for
		-- spotting the server's view of a car stalling and then catching up).
		stillDistance = 0.05,
		-- When the server's view of a car stalls and then jumps ahead farther than the car could drive in one
		-- sample, the jump is billed as travel spread over the stall, but over no more than this many seconds
		-- (a longer stall is billed at a faster speed). AntiExploit resets a car whose jump is longer than its
		-- own teleportDistance plus catch-up allows, which bounds how long a stall can be held anyway.
		catchUpSeconds = 5,
	},
}

return Energy
