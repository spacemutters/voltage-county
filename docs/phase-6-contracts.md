# Phase 6 contracts

Jobs framework, rideshare, delivery (PLAN.md "Phase 6", §4 rates). Read `CLAUDE.md` and the earlier contracts
(`docs/phase-1..5-contracts.md`, still in force). Implement exactly the names below; anything not written here
is the owner's choice. Earlier phases are done and checked: change them only where this document says so.

## Principles
- **Server-authoritative jobs.** The client only asks (accept, I'm here, cancel). The server decides every
  step from server-observed car positions, and pays.
- Job eligibility comes from the car's **class** (Config/Classes ids), never its name.
- While a player has an active job, drive-to-earn pays nothing (the job is the earning), so the two never stack.
  Edit `DriveEarnService` for that only.
- Target average $/min for a mid-skill player (Config/Economy.activities): rideshare 1,000, XL 1,250, delivery
  1,000 (+20 % in `van`, `suv`, `pickup`). Pay formulas are calibrated to those with the AutoDriver measuring.

## Config (owner: jobs-core helper)

### `Config/Jobs.luau` (replace the stub)
```lua
export type JobType = "rideshare" | "delivery" -- towing and freight arrive in Phase 8
export type JobDef = {
	id: JobType,
	displayName: string,
	classes: { string }, -- eligible Config/Classes ids
	xlClasses: { string }?, -- rideshare: classes that get XL fares
	bonusClasses: { string }?, -- delivery: classes that get the bonus and more stops
	basePay: number,
	payPerStud: number, -- along the road route
	xp: number, -- per completed job (scaled by length)
	cooldownSec: number, -- after cancelling or failing
	timeLimitPerStud: number, -- seconds allowed per stud of route, plus a fixed grace
	arriveRadius: number, -- studs from a stop that counts as arrived
	stillSpeedMph: number, -- nearly stopped to pick up / drop off
}
-- plus: levels = { { xp = n, payMultiplier = m, unlocks = { string } } } per job type, tipMax (share of pay),
-- smoothness thresholds (hard-brake deceleration, crash speed loss), offer counts and refresh seconds.
```
Rideshare classes: `economy`, `sedan`, `minivan`, `suv`, `luxury`, `sports`, `muscle` (XL: `suv`, `minivan`,
and any trim with ≥ 6 seats). Delivery classes: `van`, `suv`, `pickup`, `minivan`, `sedan`, `economy`
(bonus: `van`, `suv`, `pickup`).

## Server (owners: jobs-core helper, delivery helper)

### `src/server/Services/JobService/init.luau` (jobs-core helper)
- One active job per player. State machine: `offered → accepted → (pickup) → (dropoff …) → complete | failed`.
- Job type modules plug in through one interface (both helpers implement it):
  ```lua
  export type JobType = {
  	id: string,
  	offers: (player: Player, car: Model?, context: Context) -> { Offer }, -- what the phone lists
  	start: (player: Player, offer: Offer, context: Context) -> Job?, -- builds the stops
  	onArrive: (job: Job, stopIndex: number, context: Context) -> StepResult, -- what happens at a stop
  	pay: (job: Job, context: Context) -> PayBreakdown, -- base + distance + class + tip + level
  }
  ```
  `Offer = { id, type, title, subtitle, pay (estimate), distance, stops }`;
  `Job = { id, type, player, stops = { { position: Vector3, locationId: string?, kind: "pickup" | "dropoff" |
  "load" | "drop", label } }, index, startedAt, deadline, route length, carUid?, data }`.
  `Context` gives access to Graph, Pathfind, MapLayout, the car's class and seats, and helpers.
- **Arrival:** the server checks (Heartbeat accumulator, a few times a second) whether the player's car chassis
  is within `arriveRadius` of the current stop and slower than `stillSpeedMph`; if so it advances. The Net
  `JobAction { action = "arrive", jobId }` lets the client ask for an immediate check; it is **rejected and
  logged** when the server sees the car far from the stop (the forged-complete test).
- Fails on time-out, leaving the car for too long, switching car, or the car being destroyed; cancel via
  `JobAction { action = "cancel", jobId }` (cooldown applies).
- Pays through `EconomyService.add(player, amount, "job:" .. type)` × `EconomyService.earningsMultiplier` ×
  level multiplier × `JobService.vipMultiplier(player)` (returns 1 until Phase 12 wires the VIP pass).
- XP per job type in `PlayerData.jobs.xp[type]`; levels from Config/Jobs; level-ups announced with Notify.
- Publishes the player's active job to them via Net `JobUpdate` (server → client): `{ job = { id, type, title,
  stopIndex, stops = { { position, label, kind } }, deadline, estPay } | nil, offers = { Offer }? }`.
- `JobAction { action = "accept", offerId }` starts a job from the player's current offers.
- Studio only: `DevJob { action = "teleportToStop" }` moves the player's car next to the current stop (the
  "dev-only shortcut" for automated tests). Refused outside Studio.
- Smooth-driving tip tracking: server-side samples of the car's speed during passenger legs; hard braking and
  crashes (sudden speed loss) reduce the tip.

### `src/server/Services/JobService/Rideshare.luau` (jobs-core helper)
NPC fares at `RideshareHotspot` locations (MapLayout); a fare's drop-off is another hotspot or a GPS
destination far enough away (route length band from Config). Pay = base + route distance × payPerStud × class
multiplier (XL for XL classes) + tip. Pickup leg (driving to the fare) is unpaid but counted in the time limit.

### `src/server/Services/JobService/Delivery.luau` (delivery helper)
Load at a `JobDepot` with `jobType = "delivery"` (stand still for a few seconds), then 3–6 drops at `HousePlot`
locations (more stops for bonus classes), routed in a sensible order (nearest-next on Pathfind distance). Pay per
drop + distance; +20 % for bonus classes. Return to depot not required.

### XP and levels (delivery helper)
`src/server/Services/JobService/Levels.luau` (pure): level from xp, pay multiplier, unlocks; a spec.

## Client (owner: jobs-client helper)

- **Jobs app** in the phone (replace the "arriving soon" screen): your level and XP per job type, current
  offers for your car's class (from `JobUpdate.offers`; ask with `JobAction { action = "refresh" }`), Accept,
  and the active job with Cancel. If your car's class can't do a job type, say which classes can.
- **HUD active-job slot:** job title, next stop label, distance left and time left, estimated pay.
- **GPS:** sets the destination to the current stop automatically and updates it as stops advance.
- **NPC fares:** client-side figures (simple blocky original characters made from parts, no Creator Store
  models) standing at the pickup and the drop-off; the pickup figure disappears when picked up. Parcels: a
  small box marker at each drop.
- `src/client/Controllers/JobController.luau` caches `JobUpdate`; the UI reads it.

## Tests (owner: jobs-tests helper)
- Pure specs: `tests/Jobs.spec.luau` (state machine transitions, arrival decision, pay formulas, time limits,
  eligibility by class, XL by seats), `tests/Levels.spec.luau` (if the delivery helper doesn't).
- `src/client/Dev/JobTests.luau` (Studio only, like EarnTests; AutoDriver through its Bridge): `rideshare()`
  accepts a rideshare offer and drives it end to end with the AutoDriver (pickup, drop-off) and reports pay,
  time, $/min; `delivery(classId?)` the same for a delivery route; `forgedComplete()` sends `JobAction arrive`
  far from the stop and expects a rejection; `rate(type, minutes)` chains jobs for N minutes (using
  `DevJob teleportToStop` only for the pickup leg if needed) and reports average $/min against §4.

## Net (declared by the lead before the build)
- `JobAction` (client → server function): `{ action: "accept" | "arrive" | "cancel" | "refresh", offerId: string?,
  jobId: string? }` → `{ ok, message }`.
- `JobUpdate` (server → client event).
- `DevJob` (client → server function, Studio only): `{ action: "teleportToStop" }`.
