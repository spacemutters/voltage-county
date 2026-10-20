# Progress log

Newest first. Each entry: what shipped, how to try it in Studio, open issues.

## 2026-10-19 — Phase 2: greybox county, road graph, GPS

![Voltage County from above](images/county-topdown-2026-10-19.jpg)

**Shipped**
- **County layout** (`Config/MapLayout`): six zones, 85 tagged locations covering every PLAN §5 tag with its
  attributes, and 18 GPS destinations.
  - Cedar Bend downtown is a 7×7 grid with the used lot (player spawn), dealership, charging plaza and fuel
    station.
  - Riverside has curving streets, four cul-de-sacs and 26 house plots.
  - The Plant has 4-lane concrete roads, the factory, Design Studio, freight depot and truck chargers.
  - The Mesa Test Site has dirt trails over three hills, a quarter-mile drag strip with gates 1–4, a flight
    field with jump ramps and a no-fly zone.
  - Lakefront has Cedar Lake, a bridge deck 22 studs above the water and the meet-spot overlook.
  - The County Loop is a 4-lane, 70 mph ring with an interchange at each avenue and a service stop.
- **Road graph** (`Config/RoadGraph`): 344 nodes and 415 edges, connected and planar except one bridge.
  Grades stay within limits.
- **Road modules:**
  - `Road/Graph`: grid-indexed nearest edge, on-road check, zone lookup.
  - `Road/Pathfind`: fastest-route A* that joins and leaves roads mid-edge.
- **Map builder** (`Dev/MapBuilder`): rebuilds `Workspace.Map.Generated`, about 6,600 instances:
  - ground, roads, intersections, lane lines, sidewalks, bridges
  - zone-colored buildings grouped per block
  - streetlights, tagged locations with props, player spawns
  - roads and ground are Persistent so fast cars never outrun streaming
- **GPS:** a destinations panel, a route line drawn on the road, re-routing when you go off route, and an
  arrival notice. Plus toast notices, and the used-lot "Claim your free car" prompt. The prompt hands out a
  temporary test-drive Spark until Phase 4's garage.
- **Streaming** is on. The dev test track moved west of the County Loop.
- **Fallback sync:** `tools/studio_sync.py` with `tools/StudioSync.luau` pulls the repo's code into Studio
  through the connector when nobody is there to click Rojo's Connect. It touches only the four code folders.
- Built by 4 helpers, then 2 reviewers. They found 6 issues (3 serious, 3 minor), and all were fixed.
  Afterwards I fixed two specs whose tolerances were too tight for Roblox's 32-bit positions, and one spec
  whose "off route" point was actually near the route.

**Checked in Studio** (published place, connector):
- Tests: `TESTS: passed=241 failed=0`.
- MapCheck: two builds both give 6,590 instances, 0 overlapping road parts, every node and location
  reachable. Routes from the spawn to all 18 GPS destinations take at most 0.09 ms (the limit is 5 ms).
- Route test: **13 of 13 drives completed, 0 stuck events.**
  - One route into each zone and back, at about 30 mph.
  - The full County Loop: 26,074 studs in 300 s at up to 55 mph.
- A player spawns at the used lot in Cedar Bend, and the claim prompt is there.

**Davis did:** published the place (now "Voltage County", private, universe 10772006656) and turned on Studio
access to API services. Claude turned on Allow HTTP Requests, which Phase 11's AI Car Designer needs anyway
and the fallback sync uses.

**Open issues**
- Pressing the claim prompt can't be automated from a test script. Davis tries it: walk up and press E.
- Rojo can only set `StreamingEnabled`; Roblox doesn't let plugins write the streaming radii. They need
  setting once in Studio's Properties panel (Workspace): `StreamingMinRadius` 256, `StreamingTargetRadius`
  2048, `StreamOutBehavior` Opportunistic.
- The drag strip has about 990 studs of run-off after the finish, which may be short for the Arc Boost.
  Revisit in Phase 10.
- House-plot pads sit behind the sidewalk kerb with no driveway gap yet (Phase 13).

## 2026-10-19 — Phase 1: chassis, classes, generation spike

**Shipped**
- **Catalog:** 8 fictional brands, 13 classes with tiers and stat bands, and all 8 Ohm vehicles with every
  trim and body geometry. `Vehicle/Catalog.validate()` checks every trim sits inside its class band.
  - Long Range trims get the most range, since that's what the name sells. Straight interpolation from the
    plan would have given them less than Standard.
  - The Hauler Long Range isn't in the plan, so it was filled in.
- **Physics** (`Vehicle/Tuning`, `Powertrain`, `Chassis`, `WheelVisuals`, `Config/Driving`):
  - raycast suspension on one invisible chassis body, mass-independent and frequency-based, with impulse
    clamping for 30–144 fps
  - electric single-speed or fuel 5-gear automatic, regen low/standard/high, Comfort/Standard/Sport,
    traction control, reverse by holding brake, handbrake slides
  - peak acceleration calibrated per trim so 0–60 matches the catalog
  - other players' cars animate their wheels too
- **Server:** `VehicleService` (spawn, Drive/Ride prompts, ownership to the driver, park on exit, 10-minute
  despawn, one car per player, Studio-only dev spawn) and `AntiExploitService` (speed cap at top × 1.15
  and teleport detection on server-observed positions, reset → log → kick with decay; pure `MotionGuard`).
- **Client:**
  - controls: keyboard, gamepad and touch, through ContextActionService (the docs don't recommend the
    newer system over it)
  - the drive loop, chase/orbit/hood camera with speed-scaled FOV, HUD stub (speed, gear, mode)
  - on-screen touch pedals and steering, and a Studio-only spawn menu
- **Dev tools:** `VehicleBuilder` (18 greybox models, one per trim, 36–52 parts each, to the model contract),
  `DevTrackBuilder` (2,400+ stud straight, skidpad, speed-bump lane), `AutoDriver`, `GenerationSpike`.
- `docs/ART_BRIEF.md` for an artist; `docs/phase-1-contracts.md` is the agreement the modules were built to.
- **Network:** two remotes declared in Net (`DevSpawnVehicle`, `VehicleReset`); remotes now carry a direction,
  and a client firing a server-only remote is rejected.
- Built by 5 helpers in parallel, then 2 reviewers. They found 14 issues (3 serious, 11 minor, none
  crashing), and all 14 were fixed.

**Checked in Studio through the connector** (place file open, Rojo connected, not yet published):
- Tests: `TESTS: passed=153 failed=0`.
- Ohm Spark Standard 0–60: **4.99 s** (target 5.0, pass band ±15%). Ohm Arc 0–60: **1.90 s** (target 1.9).
- Spark settles at 0.65 studs of ride height (0.7 configured), upright, client owns its physics.
- Arc (lowest car) over the speed bumps at 40 mph: worst tilt 2.6°, upright, no stuck events.
- Forged 500-stud jump from the client: caught as "teleport" in 0.35 s and moved back.
- Getting out parks the car: anchored, upright, still, held by the server.

**Generation spike** (GenerationService, run in a playtest; results in `ServerStorage.GenerationSpike`)

| Item | Time | Triangles | Size as generated |
|---|---|---|---|
| hatchback (Car5) | 49.9 s | 9,208 | 1.2 × 1.0 × 1.9 studs |
| pickup (Car5) | 52.2 s | 9,428 | 1.3 × 1.3 × 1.9 |
| coupe (Car5) | 49.0 s | 8,674 | 1.0 × 0.6 × 1.9 |
| roof box (Body1) | 17.8 s | 5,776 | 1.1 × 0.7 × 1.9 |
| rear wing (Body1) | 21.1 s | 6,026 | 1.9 × 0.8 × 1.3 |

- All 5 worked with the place unpublished. No setting had to be turned on.
- Each Car5 result has a body and four named wheels with usable centers, so wheel hubs can be mapped onto
  the model contract.
- Every result comes out about 2 studs long and must be scaled up roughly 7×.
- **Not saved:** the meshes have no asset id, so they exist only in that server session. A car can't come
  back as the same generated mesh after a rejoin.
- Cost or quota isn't reported by the API. Check the Creator Dashboard.
- Not tested: driving a generated body on the chassis. That needs `GeneratedAdapter` (Phase 11).

**Recommendation: go, with limits.**
- Use generated bodies as a live "first look" in the session they're made, under 60 s for a car, which
  meets the plan's target.
- Save every design as a kit spec that rebuilds from the DesignKit, as PLAN.md Phase 11 already allows.
- Keep generation out of anything that has to persist until Roblox gives the meshes a saveable asset.
- Davis confirms this before Phase 11 builds it.

**How to try it in Studio**
1. Open the place with `tools\open_in_studio.bat`, or keep the current session (Rojo connected).
2. The cars and track are already built in this place. To rebuild them, run in the command bar:
   `require(game.ServerScriptService.Server.Dev.VehicleBuilder).buildAll()` and
   `require(game.ServerScriptService.Server.Dev.DevTrackBuilder).build()`.
3. Press Play. In the top-left Studio-only menu, pick a car: it spawns in front of you and seats you.
4. Drive with W/A/S/D, Space for the handbrake, M for drive mode, C for camera, R for regen, F to get out.
   The track starts about 60 studs from the spawn: the long straight in the middle, the skidpad on one side,
   the speed-bump lane on the other.

**Open issues**
- Not checked: touch controls at phone size (Claude's screen capture can't see Studio on this laptop).
  Davis checks on a phone, or with Studio's device emulator.
- The Drive prompt shows to every player (only the owner can use it). Hiding it for others needs a client
  tweak.
- Brake-light thresholds for other players' cars are estimates.
- On the low cars, a seated avatar's lower legs can show under the body. That's an art-pass item.
- The Hauler's chassis box encloses the fifth-wheel plate. Phase 8's trailer coupling has to account for
  it.
- The DevTrack sits around the origin. Phase 2's county map may need it moved; only `Config/DevTrack`
  changes.
- The place still has to be published (File > Publish to Roblox) and have Studio access to API services
  turned on. Phase 3 needs both for saving player data.

## 2026-10-19 — Phase 0: repo, toolchain, Studio connection

**Shipped**
- The repo in `projects\voltage-county`, with `.gitignore` and `.gitattributes` (LF line endings).
- Tools pinned with Rokit (`rokit.toml`): Rojo 7.7.1 (same version as the Rojo plugin already in Studio),
  Wally 0.3.2, StyLua 2.6.0, Selene 0.32.0 and luau-lsp 1.70.1. Rokit 1.2.0 itself is in `%USERPROFILE%\.rokit`.
- react-lua 17.2.1 (`jsdotlua/react`, `jsdotlua/react-roblox`) through Wally.
- ProfileStore vendored at commit `9580f7c` (Wally version 1.0.3, Apache 2.0, header kept).
- Quality gate `scripts/check.ps1` and `scripts/check.sh`. Beyond the plan's StyLua → Selene → Rojo build, it
  has two gates that come first:
  - every Luau file must start with `--!strict`
  - no real carmaker or model name in game code (`scripts/banned-names.txt`)

  Both were broken on purpose and both stopped the build.
- Boot: `Util/Loader` runs Init() on every service or controller, then Start() on all, and prints
  `[Server] booted N services` / `[Client] booted N controllers`. A module that fails is reported and skipped.
- `Net.luau`: the one place remotes are declared. Each remote has a payload validator (`Util/Check`) and a
  per-player token-bucket rate limit (`Util/RateLimiter`). Rejected calls are reported through `Net.onReject`
  for AntiExploitService (Phase 1). No remotes are declared yet.
- `Types.luau` holds the PlayerData types from PLAN.md §6. Every Config module exists as a typed stub;
  `World` and `Economy` already carry the numbers the plan gives.
- Test harness `Testing/Harness.luau` (describe, it, beforeEach, expect with toBe, toEqual, toBeNear,
  toThrow, never…). There are 3 specs with 11 tests: the sample spec, the validators and the rate limiter.
- `Sync to Studio.bat` runs `rojo serve`. The README has the one-time Studio setup.

**How to try it in Studio:** follow README.md, "One-time setup" and "Trying it".

**Checked later the same day through the Studio connector:** Play printed `[Server] booted 0 services` and
`[Client] booted 0 controllers` with no errors from our code (Roblox's own menu prints warnings), and the
harness printed `TESTS: passed=18 failed=0` (Phase 0 specs plus the new catalog spec).

**Studio setup that happened:** after today's Studio update, Studio's windows can't be seen by Claude's screen
capture on this laptop (they come out white or black even though they look normal on screen), so Claude
can't drive Studio's dialogs. Instead `tools\open_in_studio.bat` builds the place file and opens it straight
in Studio, and Claude works through the Studio connector. Davis connected Rojo. **Not done yet:** publishing
the experience (File > Publish to Roblox, "Voltage County", private) and turning on Studio access to API
services. Only Roblox's own Publish window can create a new experience; scripts can't.

**Open issues**
- Studio may cache required modules between command-bar runs. The harness re-requires each spec from a fresh
  copy, but if a changed module seems stale, run the harness inside a playtest instead.
