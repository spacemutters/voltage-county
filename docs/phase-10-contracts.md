# Phase 10 contracts

Hypercar and thrusters (PLAN.md "Phase 10"). Read `CLAUDE.md` and the earlier contracts (`docs/phase-1..9-contracts.md`,
still in force). Implement exactly the names below; anything not written here is the owner's choice. Earlier phases
are done and checked: change them only where this document says so.

The map already has what this phase needs: `FlightZone` (`ms_flight_field`) and `NoFlyZone` (`ms_control_nofly`)
volumes, four `DragStripGate` volumes (`index` 1..4) on the Mesa Test Site, and ramps. Every Arc model already has
`Thruster_L`, `Thruster_R` (rear, pointing back) and `Thruster_Down` (under the floor) attachments.

## Shared names (every helper matches these)
- Ability ids: `"boostHop"` and `"flight"`. `Config/Abilities.byTrim` says which trims have which:
  `ohm_arc/boost` → `{ "boostHop" }`, `ohm_arc/flight` → `{ "boostHop", "flight" }`. Nothing else has abilities.
- Car attributes the server sets on the car model (replicated, read by every client):
  - `Ability` — the active ability id, or nil when none is running
  - `AbilityStartsAt`, `AbilityEndsAt` — `workspace:GetServerTimeNow()` times of the active ability
  - `boostHopReadyAt`, `flightReadyAt` — server time each ability is usable again (absent = ready)
- Net (declared by the lead before the build):
  - `UseAbility { ability }` (function) → `{ ok, message, startsAt?, endsAt?, readyAt? }`
  - `DevAbility { action = "resetCooldowns" }` (function, Studio only: AbilityService refuses it elsewhere)
  - `DragStripUpdate` (server → client) `{ state = "armed" | "running" | "finished" | "fault", time?, best?, rank?,
    message? }`
  - `GetDragLeaderboard` (function) → `{ week: string, entries: { { name, time } }, best?, rank? }`

## Abilities, server (owner: ability-server helper)

### `Config/Abilities.luau`
Every tunable: per ability the cooldown (hop 20 s, flight 45 s), duration (hop about 2 s, flight up to 4 s plus the
landing), minimum speed (hop 20 mph), impulse sizes (forward and up, as accelerations so they are mass-independent),
hover height (25 studs), roll/flip rates, landing descent rate, the velocity bounds the server allows during and
after each ability, the settle time after landing, the upright test, and `byTrim`. Plain-language messages
("Boost needs 20 mph", "Flight works only over the Flight Field", "Recharging: 12 s").

### `src/server/Services/AbilityService.luau`
- `UseAbility`: the player must be the driver and owner of the car (`OwnerUserId`), the car's trim must have the
  ability (`byTrim`), the ability must be off cooldown and no ability running, the car must be outside every
  `NoFlyZone` (both abilities) and, for flight, inside a `FlightZone`; the hop needs the server's smoothed speed of
  at least the minimum. On success it sets the car attributes above, widens AntiExploit for the ability's window
  (`setSpeedCap`/`setTopSpeed` and whatever vertical allowance AntiExploit needs; change AntiExploitService only
  as far as that needs), and after the window checks the car's velocity stayed within the configured bounds
  (strike via AntiExploit if not).
- A pure decision function `AbilityService.decide(request, facts, now): (boolean, string)` holds every rule, so
  specs can forge requests (wrong trim, not the owner, on cooldown, during another ability, outside the zone, too
  slow, a NoFlyZone).
- **Unstuck after landing:** once an ability ends and the settle time passes, the server checks the car is upright
  and not inside map geometry (overlap query against `Workspace.Map`); if not, it uses the existing reset path
  (VehicleService/AntiExploit's unstuck to the nearest road, `allowTeleport`) and tells the player. A car is never
  left inside geometry or on its roof.
- `DevAbility resetCooldowns` (Studio only) clears the caller's car's cooldowns, for the 50-run tests.
- Specs: `tests/Ability.spec.luau` (every `decide` rule and forged request; config sanity).

## Abilities, client (owner: ability-client helper)

### `src/shared/Vehicle/Thrusters.luau` (pure)
The forces, like `Vehicle/Chassis` (read it; mass-independent, frame-rate stable, clamped): the hop's forward + up
push over its duration; flight's hover (a damped spring to `hoverHeight` above the ground under the car, raycast),
roll and flip from steer/throttle input, and the controlled landing (descend at the landing rate, level the car).
`Thrusters.hopStep(...)`, `Thrusters.flightStep(...)` return the velocity / angular-velocity changes for one step.

### `src/client/Controllers/AbilityController.luau`
- Binding: `Config/Controls` gains `ability` (keyboard `Q`, a free gamepad button; touch: a **Boost** / **Fly**
  button in `UI/TouchControls`, shown only in a car with abilities). One press asks `UseAbility` (hop on the
  ground; flight when the trim has it and you're over the Flight Field — the reply's message explains a refusal).
- While the local car's `Ability` attribute is set and the time is inside the window, it applies `Thrusters` in
  `RunService.PreSimulation` on the owner's car (the client simulates its own car).
- VFX for every car with an active `Ability` (all clients): white cold-gas plumes (ParticleEmitters, light grey
  and white, no flames or orange) at `Thruster_*`, started and stopped by the attributes; a short hiss SFX through
  `Config/Audio` (asset 0 stays silent safely).
- HUD: a small ability chip with the cooldown ring (from `<ability>ReadyAt`); owned here, added to
  `UI/Hud.luau`/`HudController` with minimal changes.
- Specs: `tests/Thrusters.spec.luau` (mass independence, hover converges to the height, landing levels the car, the
  clamps).

## Arc tuning, drag strip and leaderboard (owner: mesa helper)
- **Arc tuning:** the Arc trims get the best acceleration and grip in the game (Config/Vehicles and the tuning
  path in `Config/Driving`/`Config/Classes`, within the hypercar class band); a spec in `tests/Tuning.spec.luau`
  proves every Arc trim out-accelerates and out-grips every other catalog car.
- **`src/server/Services/DragStripService.luau`:** a run arms when a car stops behind gate 1, starts when it crosses
  gate 1 and finishes at gate 4 (gates 2 and 3 give splits); times come from the server: each crossing is
  interpolated between two server frames from the car's server-side position and velocity across the gate plane
  (sample only while a run is armed or running — no always-on loop). Faults: leaving the strip sideways, a
  teleport or reset, or an ability used mid-run (thrusters don't count on the strip). Sends `DragStripUpdate`.
- **Weekly leaderboard:** `OrderedDataStore` named per ISO week (`Config/DragStrip.storePrefix .. "2026-W43"`),
  best time per player in milliseconds (lower is better), written only on a personal best, read through
  `GetDragLeaderboard` (cached a short time on the server). Names are display names (TextService not needed for
  Roblox names). In-world board at the strip (SurfaceGui: top 10 this week) and the result toast.
- `Config/DragStrip.luau` for every tunable.
- Specs: `tests/DragStrip.spec.luau` (crossing interpolation, week keys, fault rules).

## Tests (owner: mesa helper)
`src/client/Dev/AbilityTests.luau` (Studio only, like FreightTests: `start(name, ...)`, `status()`,
`lastResult()`, `stop()`):
- `hops(n = 50)` — Arc Boost on the strip's return road: build speed, hop, wait for the landing and settle
  (`DevAbility resetCooldowns` between hops); each must end upright, on its wheels, not inside geometry, with no
  anti-exploit strike.
- `flights(n = 50)` — Arc Flight over the Flight Field: fly with scripted roll/flip input, land; same checks.
- `forged()` — asks `UseAbility` on cooldown, outside the Flight Field, inside the No-Fly Zone, below 20 mph and in
  a car without the ability; every one refused with nothing changed.
- `drag()` — an Arc down the drag strip with the AutoDriver; compares the server's time to the client's own
  crossing times on `GetServerTimeNow()`; passes within ±0.05 s.
