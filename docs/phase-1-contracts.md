# Phase 1 contracts

The shared agreement every Phase 1 module is built against. If you own a file listed here, implement exactly
these names and behaviors; if you call into another module, use only what is written here. Anything not
written here is the owner's choice. Read `PLAN.md` §3, §5, §6 and Phase 1, and `CLAUDE.md` hard rules first.

## Already written (do not change without saying so in your report)

| File | What it gives you |
|---|---|
| `src/shared/Config/Brands.luau` | 8 fictional brands |
| `src/shared/Config/Classes.luau` | 13 classes, tiers, stat bands (`Range = {min, max}`) |
| `src/shared/Config/Vehicles.luau` | the 8 Ohm vehicles, trims, `geometry` per vehicle (trim override for `long_body`) |
| `src/shared/Vehicle/Catalog.luau` | `getVehicle`, `getTrim`, `defaultTrim`, `geometry(vehicleId, trim)`, `modelName(vehicleId, trim)` → `"<vehicleId>_<trim>"`, `totalPrice`, `vehicleIds()`, `validate()` |
| `src/shared/Util/Units.luau` | `mphToStuds`, `studsToMph`, `studsToKph`, `studsToMeters` (1 stud = 0.28 m; 60 mph ≈ 95.8 studs/s) |
| `src/shared/Types.luau` | `Controls`, `Telemetry`, `DriveMode` (`comfort`/`standard`/`sport`), `RegenLevel` (`low`/`standard`/`high`) |
| `src/shared/Net.luau` | remotes `DevSpawnVehicle` (client→server `{vehicleId, trim}`) and `VehicleReset` (server→client `{reason: string}`) |
| `src/shared/Util/Loader.luau` | services/controllers: optional `Init()` then `Start()`; modules directly inside `Services/` or `Controllers/` are booted, sorted by name |

Requires use `ReplicatedStorage.Shared.X` (server/client) or `script.Parent...` inside Shared. Never require
a server module from client code. Avoid require cycles: if A requires B, B must not require A.

## Conventions

- Every file starts with `--!strict`, tabs, StyLua formatting (`stylua <your files>`), Selene clean
  (`selene <your files>`). Run both on your own files before finishing. Do not run the whole gate in parallel
  with other writers' edits; do not commit.
- No magic numbers in systems: tunables go in your own Config file (listed under your module).
- Chassis frame: front is the chassis LookVector (-Z local), right is +X, up is +Y.
- Gravity stays at the Roblox default (`workspace.Gravity`, 196.2 studs/s²). Physics must read
  `workspace.Gravity`, never hard-code it.
- Dev-only code (`Dev/` folders, DevSpawnVehicle) checks `RunService:IsStudio()` and does nothing otherwise.
- Real carmaker or model names never appear anywhere (the gate `scripts/banned-names.txt` fails the build).

## Vehicle model contract (built by Dev/VehicleBuilder, used by everyone)

`ServerStorage.VehicleModels.<vehicleId>_<trim>` — a `Model`, one per trim:

- `PrimaryPart = Chassis`. `ModelStreamingMode = Atomic`. Attributes: `BrandId`, `VehicleId`, `Trim`.
- `Chassis`: `Part`, invisible (`Transparency = 1`), `CanCollide = true`, box of
  `(geometry.width, geometry.chassisHeight, geometry.length)`, bottom face at `rideHeight` above the ground when
  the model is placed with its pivot on flat ground. `CustomPhysicalProperties` density from
  `Config/Driving.chassisDensity`, friction 0.3, elasticity 0. **The only physics body**: every other part is
  `Massless = true`, `CanCollide = false`, `CanTouch = false`, `CanQuery = false`, welded to Chassis.
- Model pivot (`WorldPivot`) = the point on the ground under the chassis center, facing forward. So
  `model:PivotTo(groundCFrame)` places the car resting at ride height.
- `Body` (Folder): visual parts. Parts tagged (CollectionService) `Paint`, `Trim`, `Glass`.
- `Wheels` (Folder): parts `FL`, `FR`, `RL`, `RR` (cylinders, axle along X, diameter `2 * wheelRadius`, width
  `wheelWidth`). Each wheel has a `Motor6D` named `Motor` (parented to the wheel): `Part0 = Chassis`,
  `Part1 = wheel`, `C0 = CFrame of the matching hub attachment` (chassis space), `C1 = identity`. Animate
  the wheel only through `Motor.Transform` (suspension offset along +Y in chassis space, then steer yaw about
  Y, then spin about X). Never write wheel CFrames.
- `Seats` (Folder): `Driver` (`Seat`, left side, front row; absent on the Pod) and `Passenger1..N`
  (`Seat`), welded to Chassis, `Massless`. Seats stay `Disabled = false` but have `CanTouch = false`, so
  walking into a car never sits you down; VehicleService seats people with `Seat:Sit(humanoid)`.
- `Lights` (Folder): parts `HeadL`, `HeadR`, `TailL`, `TailR`, `Brake`, `Reverse`, each holding a
  `SpotLight` or `SurfaceLight` named `Light`, `Enabled = false` except headlights/taillights at night later.
- `Doors` (Folder, optional): hinged visual parts; the Summit gets two gull-wing doors.
- Attachments on Chassis (positions in chassis space):
  - `WheelFL/FR/RL/RR`: hub center **at ride height** (static rest). x = ±track/2, z = ∓wheelbase/2
    (front is -Z), y = wheelRadius − (rideHeight + chassisHeight/2).
  - `PlateFront`, `PlateRear`, `CameraHood`, `TowHitch` (vehicles with feature `towHitch`), `Kingpin`
    (feature `kingpin`), `Thruster_L`, `Thruster_R`, `Thruster_Down` (feature `thrusters`).
  - `Mount_Roof`, `Mount_Hood`, `Mount_Spoiler`, `Mount_FrontBumper`, `Mount_RearBumper`, `Mount_SideL`,
    `Mount_SideR`.
- Greybox ≤ 60 parts per model. Original, generic shapes only.

## Shared vehicle modules (owner: physics helper)

### `Config/Driving.luau`
All physics, powertrain, steering, brake, suspension, tire, drive-mode and regen tunables, plus
`chassisDensity`. Drive modes: `comfort` (softer, ~80% force, gentle throttle ramp, more regen), `standard`
(the catalog stats), `sport` (same peak force as standard, sharper throttle, less traction-control
intervention, quicker steering). No mode exceeds the trim's top speed or beats its 0–60.

### `Vehicle/Tuning.luau`
`Tuning.forTrim(vehicleId: string, trimId: string): Tuning?` — mass-independent numbers derived from the
catalog + `Config/Driving`: top speed (studs/s), peak acceleration calibrated so a flat straight-line run in
Standard mode hits 0–60 mph in `trim.zeroToSixtySec`, brake deceleration, grip coefficient and steer limits
from `trim.handling`, suspension frequency/damping, wheel radius, hub positions, drive layout, energy type.
Export the `Tuning` type.

### `Vehicle/Powertrain.luau`
`Powertrain.new(tuning): Powertrain` with
- `:update(dt: number, controls: Types.Controls, forwardSpeed: number, mode: Types.DriveMode, regen:
  Types.RegenLevel) -> PowertrainOutput` where `PowertrainOutput = { driveAccel: number (signed along
  forward, studs/s² per unit mass), brakeAccel: number (≥ 0), gear: string, reversing: boolean,
  shaping: number (throttle after mode shaping) }`.
- Electric: single speed, instant torque, adjustable regen when lifting off. Fuel: simple automatic with
  gears and short shift dips. Reverse: holding brake at (near) standstill engages reverse after a short delay;
  in reverse the brake pedal drives backwards and throttle brakes. Capped reverse speed.
- `Powertrain.simulateZeroToSixty(tuning, mode): number` — a pure 1-D simulation (fixed small dt, same force
  curve, drag and rolling resistance the chassis uses) returning seconds to 60 mph. Used by specs.

### `Vehicle/Chassis.luau` (runs only on the owning client)
- `Chassis.new(model: Model, tuning: Tuning): Chassis`
- `:step(dt: number, controls: Types.Controls)` — called from `RunService.PreSimulation` by DriveController.
  One raycast per wheel (exclude the car and its occupants), spring + damper (mass-independent: use
  `Chassis.AssemblyMass`), lateral grip, drive/brake from the Powertrain, traction control, handbrake on the
  rear wheels, speed-sensitive steering. Apply forces with `ApplyImpulseAtPosition` scaled by `dt`, clamped
  so a single frame can never reverse a wheel's contact velocity (stable from 30 to 144 fps). Animates the
  wheels via `WheelVisuals`.
- `:setMode(mode)`, `:setRegen(level)`, `:getTelemetry(): Types.Telemetry`, `:reset()` (clear internal
  state after the server moves the car), `:destroy()`.

### `Vehicle/WheelVisuals.luau`
`WheelVisuals.new(model): WheelVisuals` with `:update(dt, compressions: {number}?, steerAngle: number?)`.
With no compressions given it raycasts itself and infers spin from the chassis velocity and steering from
angular velocity, so it also animates other players' cars. Writes only `Motor.Transform`.

## Server (owner: server helper)

### `Config/Spawning.luau`
Max cars per player (1), unattended despawn minutes (10), spawn offset from the player, park settings.

### `Config/AntiExploit.luau`
Speed tolerance (1.15 × top speed), sample rate, teleport distance, strikes before log and before kick,
strike decay, vertical speed allowance.

### `Services/VehicleService.luau`
- Requires `Services/AntiExploitService` (never the other way round).
- `VehicleService.spawn(player, vehicleId, trimId, at: CFrame?): Model?` — clones the model, `PivotTo` on
  the ground (raycast down), parents to `Workspace.Vehicles` (create the folder), adds tag `Vehicle` and
  attribute `OwnerUserId`, adds ProximityPrompts (`Drive` on the Driver seat for the owner, `Ride` on
  passenger seats), leaves the car **parked** (anchored). Despawns the player's previous car first.
- Seating: prompt → server checks distance and ownership → `Seat:Sit(humanoid)`. When the owner sits in the
  Driver seat: unanchor, `Chassis:SetNetworkOwner(player)`, start anti-exploit tracking, cancel the despawn
  timer.
- Exit (Driver seat `Occupant` becomes nil): park — judge the car's last move (`AntiExploitService.checkNow`;
  an illegal one parks it at the last legal pose), take server ownership, raycast to the ground, `PivotTo` a
  pose at ride height keeping yaw, zero velocities, anchor, stop tracking, start the 10-minute despawn timer
  (`task.delay`, cancelled on re-entry). Anyone leaving a seat is stood on the ground beside its door. No
  polling loops.
- `VehicleService.despawn(player)`, `getCar(player): Model?`, `seatDriver(player): boolean` (Studio/tests:
  sits the player's character in their car's Driver seat), `park(model)`.
- `resetCar(model, cframe)` used by anti-exploit: server ownership, move, zero velocity,
  `AntiExploitService.allowTeleport`, `Net.fireClient("VehicleReset", driver, {reason = ...})`, then give
  ownership back to the driver after `Config/AntiExploit.resetOwnershipDelay` (so physics the client sent
  before the reset can't undo it).
- Handles `DevSpawnVehicle` only when `RunService:IsStudio()`; validates the vehicle/trim exists and is
  `playerDrivable`.
- Cleans up on `PlayerRemoving` (despawn).

### `Services/AntiExploitService/init.luau` + `MotionGuard.luau`
- `AntiExploitService.track(model, player, { topSpeed: number (studs/s), reset: (lastGood: CFrame, reason:
  string) -> () })`, `untrack(model)`, `allowTeleport(model)` (re-baseline after a legitimate server move),
  `getStrikes(player): number`, `checkNow(model): (boolean, CFrame?)` (judge the current position once,
  counting a strike on an offense; returns false and the last legal pose instead of calling `reset`).
- For `graceSeconds` after `track` or a re-baseline the baseline stays on the server-placed pose: speed is not
  judged, but a teleport away from that pose is (`MotionGuard.checkSettling`).
- Samples tracked cars on `RunService.Heartbeat` with an accumulator (Config sample rate); horizontal speed
  over the sample vs `topSpeed × tolerance`; a single-sample jump over the teleport distance is a teleport.
- First offense: call `reset(lastGood, reason)`. Strikes decay over time; at the log threshold `warn` with
  player, reason and numbers; at the kick threshold `player:Kick(...)` with a plain message.
- Listens to `Net.onReject` and logs (rejects alone don't kick).
- `MotionGuard.luau` is pure (no Roblox services): given previous sample, new sample, dt and limits, return
  `ok` / `"speed"` / `"teleport"`. A spec covers it, including "500 studs in one step is caught".

## Client (owner: client helper)

### `Config/Controls.luau`
Key and gamepad bindings, deadzones, steering ramp speeds, touch layout sizes (touch targets ≥ 44 px).

### `Controllers/InputController.luau`
- ContextActionService bindings (the docs don't recommend the newer input system over it):
  - keyboard: W/Up throttle, S/Down brake/reverse, A/D/Left/Right steer, Space handbrake, F exit, M drive
    mode, C camera, R regen level
  - gamepad: RT throttle, LT brake (analog), left stick X steer, ButtonX handbrake, ButtonB exit, ButtonY
    mode, ButtonR3 camera
  - touch: on-screen pedals and steering from `UI/TouchControls`
- Bind only while driving; sink Space so it doesn't jump the character out.
- Prompts: while the local character is seated anywhere, `ProximityPromptService.Enabled` is false on that
  client (DriveController); the `Drive` prompt stays hidden on cars the local player doesn't own
  (VehicleVisualsController).
- `InputController.getControls(): Types.Controls` (smoothed keyboard steering, analog gamepad).
- `InputController.setOverride(controls: Types.Controls?)` for AutoDriver; while set, it wins.
- Signals (plain callback lists or BindableEvents): `onCycleMode`, `onCycleCamera`, `onCycleRegen`,
  `onExit`. `setTouchState(partial)` for the touch UI.
- Exit = set the local humanoid's `Sit = false` (no remote).

### `Controllers/DriveController.luau`
- Watches the local character's `Humanoid.SeatPart`. If it's a `Seat` named `Driver` inside a model with a
  `VehicleId` attribute: build `Tuning.forTrim`, `Chassis.new`, bind `RunService.PreSimulation` →
  `chassis:step(dt, InputController.getControls())`, local brake and reverse lights. On leaving: unbind,
  `chassis:destroy()`.
- `DriveController.getTelemetry(): Types.Telemetry?`, `getCar(): Model?`, `getMode()`, `setMode()`.
- Listens to `VehicleReset` → `chassis:reset()`.

### `Controllers/VehicleVisualsController.luau`
Animates other players' cars (tag `Vehicle`, within a distance from Config) with `WheelVisuals` each
`RenderStepped`; shows their brake lights when they decelerate hard. Skips the local player's own car.

### `Controllers/HudController.luau` + `UI/Hud.luau`, `UI/TouchControls.luau`, `UI/DevSpawnMenu.luau`
- react-lua (`ReplicatedStorage.Packages.React`, `ReactRoblox`), one ScreenGui, mobile-first, scales from
  phone to desktop.
- HUD stub: speed (mph), gear, drive mode; shown only while driving.
- Touch controls: shown only on touch devices while driving: gas and brake pedals (hold), steering
  (left/right hold zones or a drag slider), handbrake, mode, camera, exit buttons. Writes
  `InputController.setTouchState`.
- Dev spawn menu: Studio only. A small list of every drivable Ohm vehicle and trim; picking one fires
  `DevSpawnVehicle`.

## Camera (owner: camera + dev-tools helper)

### `Config/Camera.luau`
Chase distance/height/stiffness, FOV range scaled by speed, orbit limits and sensitivity, hood offset.

### `Controllers/CameraController.luau`
While driving (`DriveController.getCar()`), take over the camera (`Scriptable`): chase cam (spring follow
behind, FOV widens with speed), orbit cam (mouse drag / right stick / touch drag around the car), hood cam
(`CameraHood` attachment). Cycle with `InputController.onCycleCamera`. Restore the default camera on exit.

## Dev tools (owner: camera + dev-tools helper)

### `src/client/Dev/AutoDriver.luau` (Studio only)
- `AutoDriver.drive(points: {Vector3}, opts: {targetMph: number?, timeout: number?, arriveRadius:
  number?}?): Report` — pure-pursuit steering, speed control, `InputController.setOverride` every frame,
  counts "stuck > 3 s" events. `Report = {completed, elapsed, stuckEvents, maxMph}`.
- `AutoDriver.zeroToSixty(opts: {timeout: number?}?): number?` — full throttle straight ahead from a stop,
  returns seconds to 60 mph (nil on timeout).
- `AutoDriver.holdStill(seconds)`, `AutoDriver.stop()` (clears the override).
- Run from MCP `execute_luau` in the Client datamodel:
  `require(game.Players.LocalPlayer.PlayerScripts.Client.Dev.AutoDriver).zeroToSixty()`.

### `src/server/Dev/GenerationSpike.luau` (Studio only, run in a playtest via MCP, Server datamodel)
Generates 3 original test cars with `GenerationService:GenerateModelAsync(inputs, { PredefinedSchema =
"Car5" })` (parts `body`, `front left wheel`, `front right wheel`, `rear left wheel`, `rear right wheel`) and 2
accessories with `Body1`, generic prompts only. Records latency, triangle counts, wheel positions, and errors;
returns a report table. Stores results under `ServerStorage.GenerationSpike`. Does not run by itself.

## Builders (owner: builder helper)

### `src/server/Dev/VehicleBuilder.luau` (Edit mode, via MCP)
`VehicleBuilder.buildAll(): {string}` and `VehicleBuilder.build(vehicleId, trimId): Model` — rebuilds
`ServerStorage.VehicleModels` idempotently to the model contract above, one model per trim, greybox and
original. Distinct silhouettes: sedan, crossover, wedge pickup with bed, cab-over semi tractor, rounded
two-seat pod (no driver seat), low hypercar, long flagship sedan, tall SUV with gull-wing doors.

### `src/server/Dev/DevTrackBuilder.luau` + `src/shared/Config/DevTrack.luau`
`DevTrackBuilder.build()` rebuilds `Workspace.DevTrack` idempotently (Edit mode): a long straight (long
enough for the Arc to pass 60 mph and settle, ≥ 2,400 studs), a skidpad circle, a bumps lane (speed bumps
crossable at 40 mph), all anchored, starting clear of the spawn at the origin. `Config/DevTrack.luau` holds
the layout numbers and named waypoints (`straightStart`, `straightEnd`, `skidpadCenter`, `skidpadRadius`,
`bumpsStart`, `bumpsEnd`) so AutoDriver and specs can use them.

### `docs/ART_BRIEF.md`
PLAN.md §9, the model contract above, and each vehicle's greybox dimensions (from Config/Vehicles), ready to
hand to an artist.
