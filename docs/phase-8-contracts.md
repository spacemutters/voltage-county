# Phase 8 contracts

Pickup towing and semi freight (PLAN.md "Phase 8", §4 rates: towing $1,600/min, freight $3,000/min). Read
`CLAUDE.md` and the earlier contracts (`docs/phase-1..7-contracts.md`, still in force). Implement exactly the names
below; anything not written here is the owner's choice. Earlier phases are done and checked: change them only
where this document says so.

## Trailers and towed cars (owner: trailer-physics helper)

### Models
- `ServerStorage.TrailerModels` (built by `src/server/Dev/TrailerBuilder.luau` in Edit mode, idempotent, greybox
  and original): `box_trailer` (53-ft-style box, two rear axles), `flatbed_trailer`, `tanker_trailer`. Each has an
  invisible `Chassis` box (the only physics body, density from `Config/Trailers`), visual `Body`, `Wheels`
  (named `A1L`, `A1R`, `A2L`, `A2R`, each with a Motor6D `Motor` like cars), a `Kingpin` attachment on the Chassis
  at the front (mates with the semi's `Kingpin` attachment), landing-gear legs (visual) and `Lights`.
- A **towed car** is any catalog car model with the attribute `Towed = true`: the tow point is a new
  `TowPoint` attachment at the front of its Chassis (add it in `Dev/VehicleBuilder` for every model; rebuild all).
  A job's towed car also carries the CollectionService tag `Config/Trailers.towedTag` ("TowedCar"; it is no
  player's car, so it has no `Vehicle` tag), which `TrailerController` watches to pose its wheels for everyone.

### `Config/Trailers.luau`
Trailer specs (mass/density, length, wheel radius, axle positions, suspension frequency and damping, lateral
grip), hitch settings (ball-socket limits: max articulation angle, twist limit, restitution), anti-jackknife
yaw damping, towed-car settings (rear wheels on the ground, front wheels lifted), couple/decouple distances and
speeds.

### `src/shared/Vehicle/Trailer.luau`
Raycast suspension and lateral grip for a trailer (or a towed car's wheels that touch the ground), run on the
client that owns the tractor (the same assembly once coupled), `RunService.PreSimulation`, mass-independent and
frame-rate stable like `Vehicle/Chassis` (read it and reuse its approach and clamps). Rolling resistance and
braking follow the tractor's brake input (passed in). Yaw damping about the hitch resists jackknifing.
`Trailer.new(model, spec)`, `:step(dt, brake: number)`, `:destroy()`. The trailer brakes at
`Trailer.brakeDecelFor(spec, tractorBrakeDecel)` (at least `Config/Trailers.brakeRatio` x the tractor's own,
`:setBrakeDecel`), and off the throttle at the tractor's own lift-off (`Trailer.liftOffDecel(energy, mode, regen)`)
plus `coastMargin`: `Trailer.brakeInput(controls, telemetry, brakeDecel, liftOffDecel)`.

### `src/client/Controllers/TrailerController.luau`
When the local player drives a car that has a coupled trailer or towed car (server sets the attribute
`TowingModel` on the tractor to the model's name and an ObjectValue `Towing` under it), runs `Trailer:step` each
PreSimulation with the driver's brake input; stops when uncoupled.

## Hitching, licenses and depots (owner: hitch helper)

### `src/server/Services/HitchService.luau`
- `couple(player, tractor, target): (boolean, string)` — the target is a trailer (semi only, `Kingpin` within
  `Config/Trailers.coupleDistance` and the semi nearly still) or a towed car (pickup / tow truck `TowHitch`
  within distance), lined up within `Config/Trailers.coupleMaxAngle` of the tractor. Creates a `BallSocketConstraint` between the two attachments with the configured limits,
  unanchors the trailer, sets network ownership of both to the driver, sets the `TowingModel` attribute and
  `Towing` ObjectValue, tells AntiExploit the combination's top speed (`setTopSpeed`).
- `decouple(player, tractor): (boolean, string)` — allowed only inside a depot or yard footprint
  (`JobDepot` with `jobType = "freight"`, the `County Tow Yard`, a `TowDrop` or a `TrailerSpawn` location),
  judged by the **tractor's** hitch (the joint's `Attachment0`; the load is client-simulated and never trusted),
  and only while the load's hitch point is still within `coupleDistance` of it; outside one it **fails
  gracefully** with a clear message and nothing changes. On success: removes the constraint, parks the trailer
  (anchored on its legs at its current spot) or hands the towed car to the job. `droppedAt(target)` then names
  the drop's site (`siteOf(locationId)`: a depot's id for the depot and its `TrailerSpawn`s, the tow yard's for its
  `TowDrop`s); JobService counts a decouple stop by that site (or the job car at the stop), never by the load's
  position.
- Net `TrailerAction { action = "couple" | "decouple" }` (function): uses the nearest valid target / current
  coupling.
- Licenses: Net `BuyLicense { license = "freight" }` (function): needs delivery or towing XP above
  `Config/Jobs.freightLicense.xpRequired` (job level gate) and `Config/Economy.freightLicensePrice` ($25,000)
  through `EconomyService.trySpend`; sets `PlayerData.jobs.licenses.freight = true`. Idempotent.

### Map
`Config/MapLayout` gains freight depots (at least 3: The Plant, the County Loop service stop, and one far side of
the loop), trailer parking spots at each (`TrailerSpawn` tag, where idle trailers wait), tow drop points
(`TowDrop` at the County Tow Yard), and breakdown spots along roads in every zone (`Breakdown`, on the shoulder,
not the carriageway). `Dev/MapBuilder` builds them; MapCheck must pass.

## Jobs (owner: freight-jobs helper)

Two new job types plugged into JobService exactly like Rideshare/Delivery (`src/server/Services/JobService/
Types.luau` interface; edit `init.luau` only to register them):
- `JobService/Towing.luau`: classes `pickup` and `service` with a `TowHitch`. Offer: a broken-down NPC car at a
  `Breakdown` spot (the server spawns a car model with `Towed = true`, anchored until coupled). Stops: the
  breakdown (couple), then the tow yard (decouple). Pay calibrated to `Economy.activities.towing` ($1,600/min)
  for a mid-skill cycle, documented.
- `JobService/Freight.luau`: class `heavy`, needs `licenses.freight`. Offer: a trailer at one depot's
  `TrailerSpawn` to another depot (short run) or around the County Loop (long haul, the longest pay). Stops:
  couple at the origin, decouple at the destination. Pay calibrated to `Economy.activities.freight`
  ($3,000/min), documented. Without a license, offers show why and how to get it.
- `Config/Jobs` gains `towing` and `freight` defs (and `freightLicense.xpRequired`); update its header math.

## Client UI (owner: freight-ui helper)
- Phone Jobs app: towing and freight sections (offers, license status and a Buy License button with the price
  and the XP gate).
- HUD: a small trailer/tow indicator while coupled; "Couple" / "Uncouple" buttons (touch) and a key (`T` on
  keyboard, a free gamepad button from Config/Controls) calling `TrailerAction`; a friendly reply.
- GPS follows freight and towing stops (JobController already routes to the current stop).

## Tests (owner: freight-tests helper)
- Specs: `tests/Trailer.spec.luau` (pure parts of Trailer: spring/damper clamps, yaw damping sign), `tests/
  Hitch.spec.luau` (couple/decouple decisions: distance, class, depot footprint), `tests/FreightJobs.spec.luau`
  (pay math, eligibility, license gate).
- `src/client/Dev/FreightTests.luau` (Studio only, like JobTests): `loop()` — a semi with a coupled box trailer
  drives the whole County Loop at normal highway speed with the AutoDriver; reports completion, max hitch
  articulation angle, and jackknife events (articulation above `Config/Trailers.jackknifeAngle`); passes with zero.
  `decoupleOutside()` — tries to uncouple on an open road and expects a refusal with nothing changed.
  `freight()` and `towing()` — one job each end to end; `rate(type, minutes)` average $/min vs §4.

## Net (declared by the lead before the build)
`TrailerAction { action }` (function), `BuyLicense { license }` (function).
