# Phase 9 contracts

Robotaxi fleet (tycoon layer + ambient traffic) — PLAN.md "Phase 9", §4 (robotaxi $60/min per pod online,
offline at 25 % capped at 8 h). Read `CLAUDE.md` and the earlier contracts (`docs/phase-1..8-contracts.md`, still
in force). Implement exactly the names below; anything not written here is the owner's choice. Earlier phases
are done and checked: change them only where this document says so.

## Fleet economy (owner: fleet-server helper)

### `Config/Fleet.luau`
Pod price (from `Config/Vehicles` `ohm_pod` trim price — read it, don't copy it), default slots (3), Fleet
Manager pass bonus slots (+5, Phase 12) and auto-collect, zones a pod can serve (MapLayout zone ids) with
`demand` multipliers, rides per hour, average fare, online rate target ($60/min per pod at average demand),
offline rate (0.25) and cap (8 h), the uncollected-earnings cap, collection cooldown.

### `src/server/Services/FleetService/init.luau` + `Earnings.luau` (pure)
- `Earnings.accrue(pods, fromTime, toTime, online: boolean, seed): { total, perPod }` — deterministic for a seed
  and a clock: simulated rides per hour × fare × zone demand, with seeded variation per pod per hour; offline at
  `offlineRate`, capped at `offlineCapHours` past the last time online.
- `FleetService` uses `PlayerData.fleet` (`pods = { { uid, zone } }`, `lastCollectedAt`): accrues while the
  player is online (on a slow timer, no polling loops per frame) and on join for the offline gap (fake clock
  injectable for specs), keeps an `uncollected` amount (schema change: `fleet.uncollected: number`,
  `fleet.lastOnlineAt: number` → **data v6** with a migration and specs), and pays it on collect through
  `EconomyService.add(player, amount, "fleet")`.
- Net: `BuyPod { zone }` (function: slots from `fleet` + pass, price via `EconomyService.trySpend`),
  `AssignPod { uid, zone }` (function), `CollectFleet` (function → amount), `SellPod { uid }` (60 % back, like
  cars). Fleet state goes to the client in the profile snapshot (add `fleet` to `ProfileSyncService`'s snapshot:
  pods, uncollected, rates per zone).
- Specs: `tests/FleetEarnings.spec.luau` (deterministic for a seed and clock, online vs offline rate, the 8 h cap,
  demand multipliers, $60/min per pod at average demand), `tests/Migrations.spec.luau` (v5 → v6).

## Ambient pods = ambient traffic (owner: traffic helper)

### `Config/Traffic.luau`
Pod count (12 by default), speed by road kind (below the limit), spacing, look-ahead for slowing near player
cars, render distance, route length band, re-plan cadence.

### `src/server/Services/TrafficService.luau`
Publishes routes, never physics: for each ambient pod a road-graph path (Pathfind between random nodes, seeded),
a start time on `workspace:GetServerTimeNow()` and a speed profile, as a compact Net `TrafficRoutes` payload
(server → all clients, re-sent to joiners, and a new route per pod when its route ends). Pods don't exist as
server instances at all.

### `src/client/Controllers/TrafficController.luau`
Every client renders the same pods from the routes: a local anchored, non-colliding, non-queryable copy of the
Ohm Pod greybox (from a model the server puts in `ReplicatedStorage.TrafficModels` — the traffic helper adds a
Studio builder step or clones `ServerStorage.VehicleModels.ohm_pod_standard` into ReplicatedStorage at Start),
moved along the route by distance-at-time (CFrame along the polyline, banking/yaw smoothed, wheels spun with
WheelVisuals-like math), only within the render distance. Pods slow down **locally** (a client-side time offset)
when a player car is ahead in their lane and catch up after; they never collide with players. Frame cost:
one RenderStepped connection, O(visible pods).

### Studio test `src/client/Dev/TrafficTests.luau`
`run(minutes = 10)`: watches all 12 pods for the time, counts "stuck" (a pod not advancing along its route for
> 3 s while not yielding to a car), and measures the client frame cost of TrafficController (os.clock around its
step, mean and p95 ms; budget: mean ≤ 0.5 ms, p95 ≤ 1.5 ms). Passes with zero stuck and within budget.

## Hail a pod (owner: hail helper)

### `src/server/Services/HailService.luau`
Net `HailPod { destinationId }` (function; a MapLayout GPS destination id): the player must be on foot (not
driving, not in a job), the fare (`Config/Hail.luau`, owned by the hail helper: base + per stud of the Pathfind
route, ride seconds band, cooldown, cutscene timings) is charged through
`EconomyService.trySpend`, then the server tells the client to play the ride (Net `HailRide { from, to,
seconds, route }`), waits the ride time, and moves the character to the destination's road side
(`AntiExploitService.allowTeleport`-safe for characters, `character:PivotTo` on the server). Refunds if the
character leaves or dies mid-ride. Cooldown.

### Client: the ride
`src/client/Controllers/HailController.luau`: on `HailRide` plays a short cutscene (a local pod model, the camera
inside/behind it, gliding along the first part of the route, then a fade) for the ride's seconds, hides the HUD
during it by setting the LocalPlayer attribute `Cutscene = true` (HudController and the phone hide while it is
true; the fleet-ui helper owns those files and adds that), restores everything after (`Cutscene = nil`). A
**Hail** button in the phone's GPS app (`UI/Phone/GpsApp.luau`, owned by the hail helper) next to each
destination (fare shown).

## Fleet UI (owner: fleet-ui helper)
- The phone's **Fleet** app (replace the "arriving soon" screen): pods with their zone and an Assign picker
  (zone, demand, expected $/hour), uncollected earnings with **Collect**, Buy Pod (price, slots used/total),
  Sell, and the offline rule in plain words ("pods earn a quarter as much while you're away, for up to 8
  hours").
- Dealership: a **Fleet** tab or a "Buy pods" card on the Ohm section that opens the Fleet app.
- HUD: a small "$X ready" fleet chip when uncollected earnings pass a threshold (tap opens the Fleet app).

## Net (declared by the lead before the build)
`BuyPod`, `AssignPod`, `CollectFleet`, `SellPod`, `HailPod` (client → server functions); `TrafficRoutes`,
`HailRide` (server → client). Studio only: `DevFleet { action = "simulateOffline", hours }` (function) —
FleetService refuses it outside Studio; it moves the caller's `fleet.lastOnlineAt` back by `hours` and runs the
join-time offline accrual, so the fleet test can check offline pay without waiting.

## Studio test `src/client/Dev/FleetTests.luau` (owner: fleet-ui helper)
Like JobTests: `buy()` (DevSetCash, BuyPod into a zone, slot count goes up, cash drops by the pod price),
`offline()` (DevFleet simulateOffline 2 h, then CollectFleet pays about 2 h × 0.25 × the online rate for the
player's pods, within a tolerance), `cap()` (simulateOffline 20 h pays no more than 8 h), `sell()` (60 % back).
`start(name)`, `status()`, `lastResult()` like FreightTests.
