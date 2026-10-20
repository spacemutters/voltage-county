# Phase 3 contracts

Data, economy, drive-to-earn (PLAN.md §4 and "Phase 3"). Read `CLAUDE.md` (hard rules 1, 3, 7 and 8 matter
most here), `docs/phase-1-contracts.md` and `docs/phase-2-contracts.md` (still in force). Implement exactly the
names below; anything not written here is the owner's choice. Phases 1 and 2 are done and checked: change them
only where this document says so.

## The place

The game is published (private, universe 10772006656). Studio access to API services is **on**, so Studio
playtests read and write real DataStores. To keep Studio tests from touching live player data, Studio uses a
separate store name (below).

## Player data (owner: data helper)

### `Types.luau` — schema version 2
Phase 3 adds timed earnings boosts (from codes) to `PlayerData`, which is a schema change (hard rule 7):

```lua
export type Boost = { id: string, factor: number, endsAt: number } -- endsAt = os.time() seconds
-- PlayerData gains:  boosts: { Boost },   and version becomes 2
```

### `Config/Data.luau`
`storeName = "PlayerData"`, `studioStoreName = "PlayerData_Studio"` (used whenever `RunService:IsStudio()`),
`schemaVersion = 2`, autosave is ProfileStore's own, `maxReceipts = 100`, and the default template values
(starting cash and slots come from `Config/Economy`).

### `src/server/Services/DataService/init.luau` + `Template.luau` + `Migrations.luau`
- Uses the vendored ProfileStore (`script.Parent.Parent.Vendor.ProfileStore`, i.e. `ServerScriptService.Server.Vendor`).
  `ProfileStore.New(storeName, template)`; on join `StartSessionAsync("Player_" .. userId, { Cancel = ... })`,
  `AddUserId`, `Reconcile`, run migrations, kick with a plain message if the session can't start, end the
  session on leave, and kick if the session ends elsewhere (`OnSessionEnd`).
- **In-memory mock when API access is off:** if DataStores aren't reachable (Studio with access off, or
  `ProfileStore.DataStoreState ~= "Access"`), use `store.Mock`; log once which mode is active.
- `Template.luau`: `Template.new(): Types.PlayerData` — a fresh profile at `schemaVersion`.
- `Migrations.luau`: an ordered list; `Migrations.run(data): (data, fromVersion)` upgrades any older version to
  `schemaVersion` step by step and never drops a player-owned field. Version 1 → 2 adds `boosts = {}`.
  Pure (no Roblox services) so a spec can test it.
- API:
  - `DataService.get(player): Types.PlayerData?` — nil until loaded. Treat as read-only outside DataService.
  - `DataService.update(player, fn: (data: Types.PlayerData) -> ()): boolean` — the only way to change data;
    false if not loaded or the session isn't active.
  - `DataService.waitFor(player, timeout: number?): Types.PlayerData?`
  - `DataService.onLoaded(fn: (player, data) -> ())` (fires for players already loaded too).
- Sets the player attribute `DataLoaded = true` once loaded.

## Economy and codes (owner: economy helper)

### `Config/Economy.luau` (extend, keep the existing fields)
The §4 targets as data: `startingCash`, slots, `playerTransfers = false`, and an `activities` table of target
average $/min for mid-skill play (`freeDrive = 300`, `rideshare = 1000`, `rideshareXL = 1250`,
`delivery = 1000`, `deliveryVehicleBonus = 0.2`, `towing = 1600`, `freight = 3000`, `robotaxiPerPod = 60`,
`robotaxiOfflineRate = 0.25`, `robotaxiOfflineCapHours = 8`), `vipJobPayBonus = 0.2`, `freightLicensePrice
= 25000`, `maxCash` (a sanity cap), and the time-to-milestone targets from §4 for EconSim to compare against.

### `src/server/Services/EconomyService.luau`
- `EconomyService.add(player, amount: number, reason: string): boolean` and
  `EconomyService.trySpend(player, amount: number, reason: string): boolean`. Amounts are positive integers
  (round down); `trySpend` never lets cash go below 0. `getCash(player): number`.
- `EconomyService.earningsMultiplier(player): number` — 1 plus active boosts (expired boosts are dropped);
  earning code paths (drive-to-earn now, jobs later) multiply by it.
- Every change goes through `DataService.update` and is logged with
  `AnalyticsService:LogEconomyEvent` (source for add, sink for spend; currency "Cash"; the reason as the
  transaction type, mapped to the Enum.AnalyticsEconomyTransactionType closest to it, with the reason as the
  item SKU). Check the current API with WebFetch on create.roblox.com before writing it; wrap it in pcall so a
  failure never blocks the economy.
- Mirrors cash to the player attribute `Cash` (server-set, for the HUD) whenever it changes and on load.
- Studio only: `EconomyService.devGrant(player, amount)` refuses outside `RunService:IsStudio()`.

### Codes: `Config/Codes.luau` + `src/server/Services/CodeService.luau`
- `Config/Codes.luau` keys are upper-case codes → `{ expiresAtUtc: number, effect }` with
  `effect = { kind = "cash", amount = n }` or `{ kind = "multiplier", factor = f, minutes = m }`. Ship two
  launch codes (one cash, one 2× boost for 30 minutes) with a far-future expiry, plus one already-expired code
  for the spec.
- Remote `RedeemCode` (declared in Net, client → server function, payload the code string): trims, upper-cases,
  checks it exists, isn't expired (UTC `os.time()`), and wasn't redeemed by this player (`codesRedeemed`); then
  applies it in one `DataService.update` and returns `{ ok: boolean, message: string }` — friendly messages for
  unknown, expired, already used and success. A pure `CodeService.evaluate(code, codes, now, redeemed)` does the
  decision so a spec can test expiry and one-per-player without Roblox services.

### HUD cash readout
Add the player's cash (from the `Cash` attribute, formatted `$12,345`) to the existing HUD so it shows at all
times, not just while driving. Owner: economy helper, who may edit `src/client/UI/Hud.luau` and
`src/client/Controllers/HudController.luau` for this only. A tiny "Codes" entry (a button that opens a text box
and calls `RedeemCode`, showing the message as a toast via NotifyController) also lives here until Phase 4's
phone takes it over.

## Drive-to-earn (owner: drive-to-earn helper)

### `Config/DriveEarn.luau`
Sample interval (1 s), pay interval (60 s), $ per stud on roads (calibrated so ordinary driving lands near
`Economy.activities.freeDrive` = $300/min), a per-minute cap, the on-road margin, AFK window (120 s) and the
"meaningful movement" distance, loop-farming window (120 s) and the minimum bounding-box size.

### `src/server/Services/DriveEarnService/init.luau` + `Earnings.luau`
- Server-only. Samples each car that has a driver once per `sampleInterval` with a Heartbeat accumulator (no
  loops), using server-observed chassis positions (never anything the client sends) and `Road/Graph.isOnRoad`.
- Counts horizontal distance only for samples where both ends are on a road, ignores jumps longer than the car's
  top speed allows (AntiExploit handles cheaters; earnings simply skip the sample).
- Every `payInterval` it pays `min(cap, distance × rate) × EconomyService.earningsMultiplier(player)`, rounded
  down, with reason "drive", and fires `Notify` ("+$123 for driving") — **nothing** when:
  - the car hasn't moved more than the meaningful distance within the last 120 s (AFK), or
  - the bounding box of its positions over the last 120 s is smaller than the minimum (loop farming).
- `Earnings.luau` is pure: the per-minute decision from a list of samples (positions, on-road flags, times) and
  the config. A spec covers normal driving, parked, circling in a lot, off-road, and teleport jumps.
- Reads who's driving from VehicleService (Phase 1: `getCar(player)` and the Driver seat's `Occupant`) without
  creating a require cycle (VehicleService must not require DriveEarnService).

### Studio tests: `src/client/Dev/EarnTests.luau`
Like RouteTests (uses `Dev/AutoDriver` through its Bridge): `EarnTests.drive(seconds)` drives a route on the
county roads (Road/Pathfind between two far-apart GPS destinations) and reports cash before/after,
`EarnTests.park(seconds)`, `EarnTests.circle(seconds)` (tight circles in an open lot or the used-lot area), and
`EarnTests.start(name)` / `lastResult()` for long runs. Each returns `{ name, seconds, earned, perMinute }`.

### `src/server/Dev/EconSim.luau` (Edit mode or playtest, via MCP)
PLAN.md §4 deliverable. Simulates three profiles (casual, mid, grinder), each with and without VIP: what they do
each minute (free driving, then jobs as they unlock: rideshare after the first car, delivery, towing with a
pickup, freight with a semi plus the license), what they buy in order (new Spark → crossover or pickup → semi
→ Arc → Arc Boost), and charging costs as a small sink. Prints and returns time-to-milestone in hours for each
profile, next to the §4 targets, using only `Config/Economy` and `Vehicle/Catalog` prices. Pure apart from
printing.

## Net (already declared by the lead)
- `RedeemCode`: function, client → server, `Check.string(32)`, burst 3, 0.2/s.
