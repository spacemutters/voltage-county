# Phase 5 contracts

Energy: charging and fuel (PLAN.md "Phase 5"). Read `CLAUDE.md`, PLAN.md §3.3 (energy) and §4 (sinks), and the
earlier contracts (`docs/phase-1..4-contracts.md`, still in force). Implement exactly the names below; anything
not written here is the owner's choice. Earlier phases are done and checked: change them only where this
document says so.

## Principles
- **Server-authoritative energy.** The server owns each car's energy level and decides drain, charging, costs
  and limp mode from server-observed motion. The client only displays it and obeys the limp limit (and
  AntiExploit enforces that limit on the server).
- Every vehicle is `battery` or `fuel` (Config/Vehicles). Battery cars use `ChargerStall` (and `TruckCharger`
  for the semi); fuel cars use `FuelPump`. A car at the wrong kind of station gets a friendly notice.
- Energy is a fraction 0..1 stored per owned vehicle, so it survives putting a car away and rejoining.

## Model (owner: energy-model helper)

### `Config/Energy.luau`
Reference cruise speed for the catalog's "full charge ≈ minutes of driving" (`energyMinutes`; start at 45 mph
and explain the choice), the drain curve shape (speed, acceleration, climbing terms), regen efficiency for
batteries, idle drain (tiny), low-energy thresholds (0.20, 0.10), limp speed (15 mph), charging and fueling
rates and costs (10→80 % in 60–90 s at a fast stall — rate from the stall's `kW` attribute; 10→100 % in
20–30 s at a pump — rate from its `rate` attribute; truck chargers faster; cost per % small, a sink not a
wall), the hangout bonus ($/min while 3+ players charge at the same plaza), and sampling intervals.

### `src/shared/Vehicle/Energy.luau` (pure)
- `Energy.drainPerSecond(vehicleId, trim, speed: number, accel: number, climb: number): number` — fraction of
  a full charge or tank per second. At constant `Config/Energy.cruiseMph` on the flat it equals
  `1 / (trim.energyMinutes × 60)`, so a full charge lasts the catalog's minutes at cruise. Acceleration and
  climbing add; slowing and descending first offset the speed load (coasting isn't billed twice) down to the
  idle drain; past that, braking on a battery car subtracts (regen), never below zero overall.
- `Energy.rangeMiles(vehicleId, trim, level: number): number` — distance left at cruise.
- `Energy.chargeRatePerSecond(kind: "ChargerStall" | "TruckCharger" | "FuelPump", attributes, vehicleId,
  trim, level): number` — fraction per second (with a gentle taper above 80 % for batteries) and
  `Energy.costPerFraction(kind): number`.
- `Energy.isCompatible(vehicleId, kind): boolean` (battery ↔ chargers, fuel ↔ pumps, TruckCharger only for
  `heavy`).
- `tests/Energy.spec.luau`: cruise drain matches energyMinutes for every drivable trim (within 1 %), climbing
  and acceleration cost more, regen only for batteries, 10→80 % at a fast stall takes 60–90 s, 10→100 % at a
  pump takes 20–30 s, truck charger only for heavy, range is monotonic.

## Server (owner: energy-service helper)

### Schema v4
`OwnedVehicle.energy: number` (0..1). Migration 3 → 4 sets `energy = 1` on every owned vehicle. Update
`Types.luau`, `Config/Data.schemaVersion`, `DataService/Migrations.luau`, `DataService/Template.luau`,
`tests/Migrations.spec.luau`. Temporary cars (test drives, dev spawns) start full and aren't saved.

### `src/server/Services/EnergyService/init.luau` (+ pure helpers as needed)
- Samples every driven or parked spawned car (not display cars) on a Heartbeat accumulator at the Config
  interval; from server-observed chassis motion computes speed, acceleration and climb and drains via
  `Energy.drainPerSecond`.
- Publishes the level on the car as attribute `Energy` (0..1, rounded to 0.001) and `EnergyKind`
  ("battery" | "fuel"); sets attribute `Limp = true` at 0 and clears it when the level rises above a small
  margin.
- Writes the level back to the owned vehicle (`OwnedUid` attribute → `DataService.update`) when the car is
  put away, when the player leaves, and at most once a minute while driving. Leaving and server shutdown use
  `DataService.beforeRelease(fn: (player) -> ())` (added in the Phase 5 fixes): DataService calls it
  synchronously just before it ends a player's session (on leave, and for every loaded player on close), so
  the write lands while the session is still open, whatever order Roblox runs the PlayerRemoving and
  BindToClose handlers in.
- Drains nothing for a move the server made itself (`AntiExploitService.lastServerMove(model): number?`, set
  by `allowTeleport`, which `VehicleService.resetCar` calls); any other jump is billed as the travel it is.
- **Stations:** a car is at a station when its chassis is inside a tagged station part's footprint
  (`ChargerStall`, `TruckCharger`, `FuelPump` under `Workspace.Map.Generated.Locations`) and nearly still,
  with at least a whole % missing (`Config/Energy.charging.startBelow`). Charging/fueling then adds
  `chargeRatePerSecond` each sample and bills the energy added at `costPerFraction` through
  `EconomyService.trySpend` in whole dollars (cents carry over within the stop, so each % costs
  costPerFull / 100); when the player can't pay for more it adds what their cash covers and stops with a
  notice. It stops at full or when the car leaves. Incompatible station → one friendly notice. Dealership
  test drives (temporary, full, never saved) never charge.
- **Hangout bonus:** while 3+ players charge at stalls with the same `plaza` attribute, each earns the Config
  trickle for the time they charge together, paid every minute (`EconomyService.add`, reason "hangout").
- **Alerts:** `Notify` at 20 % and 10 % (once each per drop), and at 0 % a notice plus Net `EnergyAlert`
  `{ level, stationId }` with the nearest compatible station's location id (MapLayout + Pathfind distance).
- **Limp mode:** at 0 % the car is limited to `Config/Energy.limpMph`; tell AntiExploit the car's allowed
  speed changed (add `AntiExploitService.setTopSpeed(model, studsPerSecond)`; restore when it clears) once the
  car has slowed to it, or at the latest `Config/Energy.limpCapGraceSeconds` after limp mode began.
- Pure decision helpers for `tests/EnergyService.spec.luau` (station detection from a footprint and a
  position, charging step with cost and stop rules, hangout eligibility, alert thresholds).

## Client (owner: energy-client helper)

- **Limp:** `Vehicle/Chassis` (or `Powertrain`) reads the car's `Limp` attribute and caps speed at the limp
  speed while it's set (cheap: cache the attribute with a changed signal, don't read it every frame).
- **HUD:** the Phase 4 energy placeholder becomes real: a bar from the car's `Energy` attribute, a battery or
  fuel icon from `EnergyKind`, the % and the estimated range (`Energy.rangeMiles`, in the player's units). Amber
  under 20 %, red under 10 %.
- **Charging card:** while the car is charging/fueling (server sets car attribute `Charging = true` and
  `ChargeRate`), a small card shows the level filling, the rate and the cost per %. Owner: energy-service helper
  sets the attributes; energy-client helper draws the card.
- **EnergyAlert:** sets the GPS destination to the station (`GpsController.setDestination(stationId)`) and
  shows a notice.
- `src/client/Dev/EnergyTests.luau` (Studio only, like EarnTests): `cruise(seconds, mph)` measures drain per
  minute at a steady speed on the County Loop and extrapolates the full-charge minutes; `charge()` parks at the
  nearest fast stall from 10 % (Studio dev path: `DevSetEnergy` remote) and times 10→80 % and the cost;
  `refuel()` the same at a pump with a fuel car (10→100 %); `limpToStation(vehicleId, trim)` teleports to the
  farthest drivable point from every compatible station, sets energy 0, and drives the GPS route to the
  station at limp speed, reporting arrival.

## Net (declared by the lead before the build)
- `EnergyAlert` (server → client) `{ level: number, stationId: string? }`.
- `DevSetEnergy { level: number }` (client → server function, Studio only: EnergyService sets the caller's
  current car's energy, refused outside `RunService:IsStudio()`).
