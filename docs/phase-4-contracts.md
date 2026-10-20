# Phase 4 contracts

Dealership, used lot, garage, phone UI (PLAN.md "Phase 4"), plus the catalog growing to the launch size the
plan asks for (§3.3: 30–40 base vehicles across the eight brands). Read `CLAUDE.md`, PLAN.md §3, §4 and
Phase 4, and the earlier contracts (`docs/phase-1..3-contracts.md`, still in force). Implement exactly the
names below; anything not written here is the owner's choice. Earlier phases are done and checked: change them
only where this document says so.

## Catalog expansion (owner: catalog helper)

### `Config/Vehicles.luau` — add about 24 vehicles for the seven other brands
- Original names only. Never a real model name or a near-copy (no Mustang, Camaro, Wrangler, Civic, Corolla,
  Supra, Charger, Challenger, Bronco, Tacoma, Silverado, F-series, Model-anything, etc. — when in doubt pick a
  made-up word). The build gate checks brand names; you check model names by hand and list them in your report.
- Every class from `Config/Classes` used at least once across the catalog; every trim inside its class band
  (`Catalog.validate()` must stay empty). 2–4 trims per vehicle.
- Mostly electric (keep the catalog EV-majority, §3.3); `fuel` for muscle cars, classics and a couple of work
  trucks.
- A new required field on every vehicle (Ohm ones too): `bodyStyle` — one of `"sedan" | "hatch" | "coupe" |
  "wagon" | "suv" | "pickup" | "van" | "minivan" | "muscle" | "exotic" | "offroad" | "tow" | "semi" | "pod" |
  "hypercar"` — which greybox body VehicleBuilder makes.
- **Classics for the used lot:** at least 6 vehicles (or trims) with `acquisition = "usedLot"`, mostly Brannock
  and older Halden/Aldermoor designs, priced by class band, alongside the Ohm Grand and Summit.
- Suggested spread (adjust freely): Halden 4 (economy hatch, sedan, minivan, a classic wagon), Ironwood 3
  (pickup, off-roader, a fuel work truck), Aldermoor 3 (luxury sedan, luxury SUV, a classic coupe), Kaze 3
  (light sports, tuner hatch, roadster-style coupe), Brannock 4 (muscle coupes and classics, fuel), Montevale 3
  (exotics), Northline 4 (delivery van, tow truck, utility service truck, a large work van).

### `Dev/VehicleBuilder.luau` — generic greybox bodies by `bodyStyle`
Keep the eight Ohm silhouettes as they are. Every other vehicle gets a body built from its `bodyStyle` and
geometry, to the same model contract (phase-1-contracts), distinct enough to tell styles apart at a glance,
≤ 60 parts, brand-tinted default paint. `buildAll()` then makes every trim of every vehicle. Tow trucks get a
boom and a `TowHitch`; vans a tall box; pickups a bed.

### Specs
`tests/Catalog.spec` grows: at least 30 vehicles, every brand has at least 3, every class used, at least 6
used-lot classics, every vehicle has a known `bodyStyle`; `tests/VehicleBuilder.spec` already covers every trim.

## Data changes (owner: garage helper)

### Schema version 3 (`Types.luau`, `DataService/Migrations.luau`, `DataService/Template.luau`, `Config/Data`)
`OwnedVehicle` gains `favorite: boolean` and `paid: number` (what the player paid; 0 for the free starter).
Migration 2 → 3 sets `favorite = false` and `paid = Catalog.totalPrice(vehicleId, trim) or 0` on every owned
vehicle. Spec it in `tests/Migrations.spec`.

### `DataService` additions
`DataService.onChanged(fn: (player, data) -> ())` — fires after every successful `update` (and on load).
Nothing else in DataService changes.

### `src/server/Services/ProfileSyncService.luau`
Sends each player a sanitized snapshot of their own profile via Net `ProfileSnapshot` on load and after each
change (coalesced to at most a few per second): `{ cash, garageSlots, customSlots, starterClaimed,
vehicles = { { uid, vehicleId, trim, favorite, paid, paint, finish, wheels, acquiredAt } }, settings,
credits = { balance } }`. Never anyone else's data.

### `src/server/Services/GarageService.luau`
- `SpawnOwned { uid }` (function) — spawns that owned car at the `SpawnPad` location nearest the player
  (VehicleService.spawn with the owned vehicle's id/trim, attribute `OwnedUid`), seats them; replaces any car
  they had out. Returns `{ ok, message }`.
- `DespawnOwned` (function, no payload).
- `SetFavorite { uid, favorite }` (event).
- `SellVehicle { uid }` (function): sells back at `Config/Garage.sellBackRate` (0.6) of `paid`, removes it,
  despawns it if out. The free starter can't be sold (friendly message). Never below zero, never twice.
- `UpdateSettings { units?, camera?, musicVolume? }` (event): validated values only.
- Garage capacity: `garageSlots` from data; buying refuses when full (the dealership asks GarageService).
- `GarageService.addVehicle(player, vehicleId, trim, paid): string?` (returns the new uid) and
  `GarageService.hasRoom(player): boolean` for the dealership and used lot.

## Commerce (owner: commerce helper)

### Map: dealership pads and used-lot pads
- `Config/MapLayout` gains `dealership = { sections = { { brandId, pads = { CFrame } } } }` laid out in Cedar
  Bend next to the existing dealership location (clear one or two blocks of buildings for it: MapBuilder must
  not place buildings on pads), one pad per vehicle in the catalog per brand section (room for growth: a few
  spare pads per section), and `usedLot = { pads = { CFrame } }` (at least 8) at the used lot.
- `Dev/MapBuilder` builds the pads (low platforms with a brand sign per section — fictional brand names from
  Config/Brands — and numbered used-lot spaces) under `Generated.Dealership` and `Generated.UsedLot`, tagged
  `DealershipPad` (attributes `BrandId`, `Index`) and `UsedLotPad` (`Index`). MapCheck must still pass.

### `Config/Dealership.luau`, `Config/UsedLot.luau`
Test-drive length (120 s), display rotation speed, prompt distances; used-lot slots per day (= pad count), the
daily pool (every `usedLot` trim), global supply per vehicle per day, price curve (base × (1 + rise × sold /
supply), capped), the DataStore name (`UsedLotSupply`, `UsedLotSupply_Studio` in Studio).

### `src/server/Services/DealershipService.luau`
- On Start: puts an anchored, non-drivable display copy of every dealership vehicle (default trim) on its
  brand's pads (`Workspace.Showroom`), each with a ProximityPrompt "View" carrying attributes `VehicleId`.
  Display cars are tagged `DisplayCar` and excluded from VehicleService, drive-to-earn and anti-exploit.
- `BuyVehicle { vehicleId, trim }` (function): validates the trim exists, is `acquisition = "dealership"`, not
  an upgrade trim; `GarageService.hasRoom`; `EconomyService.trySpend(Catalog.totalPrice)`; then
  `GarageService.addVehicle` and spawns it at the nearest spawn pad. Every rejection is logged with the player
  and reason (a forged buy with too little cash is rejected and logged). Returns `{ ok, message, uid? }`.
- `UpgradeVehicle { uid, trim }` (function): for upgrade trims (Arc Boost): must own the `upgradeFrom` trim;
  charges the upgrade price and changes that vehicle's trim (paid += upgrade).
- `StartTestDrive { vehicleId, trim }` (function): spawns a temporary car (VehicleService.spawn, attribute
  `TestDrive = true`) and seats the player for `testDriveSeconds`; then despawns it and returns them to the
  dealership with a notice. Test-drive cars never earn (DriveEarnService skips cars with `TestDrive` — edit it
  for that only) and don't count against the garage. One at a time per player, with a cooldown.

### `src/server/Services/UsedLotService.luau`
- `ClaimStarter` (function): once per player (`starterClaimed`): adds the used Ohm Spark (`paid = 0`) and spawns
  it. Replaces the Phase 2 stub: SpawnFlowService's "Claim your free car" prompt calls
  `UsedLotService.claimStarter(player)` (edit SpawnFlowService for that only).
- Daily stock: `UsedLotService.stockFor(dateKey: string): { { slot, vehicleId, trim, basePrice, supply } }` —
  pure and deterministic from the UTC date (`os.date("!%Y-%m-%d")`), so every server agrees. Puts display
  copies on the used-lot pads with a "View" prompt (`Slot` attribute).
- `GetUsedLot` (function): today's stock with current price and remaining supply.
- `BuyUsed { slot }` (function): global supply via `DataStore:UpdateAsync` on key `<date>:<slot>` (atomic
  increment only while sold < supply); charge the current price; refund if anything after the charge fails.
  In-memory fallback when DataStores aren't reachable.
- Pure helpers for specs: `UsedLotService.price(base, sold, supply)`.

## Client UI (owners: phone helper, shop helper)

Shared look: `src/client/UI/Theme.luau` (owner: phone helper) — colors, text sizes, corner radii, spacing,
touch-target size, used by every new screen and matching the existing HUD/GPS/Toast look. Mobile-first:
scale with the screen, touch targets ≥ 44 px, readable contrast, works at 375 × 667 portrait and landscape
phones, tablets and desktop. Real brand names never appear.

### `src/client/Controllers/ProfileController.luau` (phone helper)
Caches the latest `ProfileSnapshot`; `ProfileController.get()`, `ProfileController.onChanged` (signal).

### Phone (phone helper): `Controllers/PhoneController.luau`, `UI/Phone/*.luau`
- A phone button (bottom centre on touch, a key `P` on keyboard and a gamepad button) opens a phone sheet with
  an app grid: **GPS** (destinations from MapLayout via GpsController; replaces the standalone GPS list —
  keep GpsController's route drawing), **Garage** (owned cars as cards: name, trim, favorite star, Spawn /
  Put away / Sell with a confirm; sorted favorites first), **Jobs** and **Fleet** (clean "arriving soon"
  screens), **Wallet** (cash, Design Credits balance — 0 for now), **Codes** (moved from the HUD entry; keep
  the HUD cash readout), **Settings** (mph/kph, camera default, music volume → `UpdateSettings`).
- HUD (edit `UI/Hud.luau`/`HudController` for this): speed (mph or kph per settings), an energy bar
  placeholder, cash, an "active job" slot (empty until Phase 6).

### Shops (shop helper): `Controllers/ShopController.luau`, `UI/Shop/*.luau`
- Listens for the "View" prompts on display cars (client-side `ProximityPromptService.PromptTriggered` with the
  prompt's `VehicleId` / `Slot` attributes) and opens the shop sheet:
  - **Dealership:** brand name and segment, vehicle name, trim picker, stat bars (top speed, 0–60, range,
    handling, seats — scaled to the whole catalog's range), price (`Economy.formatCash`), Buy (with a confirm
    showing the price and the cash left after), Test drive, and Upgrade for upgrade trims you can take.
  - **Used lot:** the slot's car, today's price and how many are left, Buy; and the free-starter claim if not
    yet claimed.
- Calls the remotes above and shows replies as toasts (NotifyController).

## Net (declared by the lead before the build)
`BuyVehicle`, `UpgradeVehicle`, `StartTestDrive`, `ClaimStarter`, `GetUsedLot`, `BuyUsed`, `SpawnOwned`,
`DespawnOwned`, `SellVehicle` (functions, client → server); `SetFavorite`, `UpdateSettings` (events, client →
server); `ProfileSnapshot` (server → client); `DevSetCash { amount }` (function, Studio only: DealershipService
handles it only when `RunService:IsStudio()`, setting the caller's cash to exactly `amount` through
EconomyService for the shop tests).

## Studio tests (owner: commerce helper): `src/client/Dev/ShopTests.luau`
Studio-only, like RouteTests: `buyExact(vehicleId, trim)` (uses `EconomyService.devGrant` through a Studio-only
dev path to set cash to exactly the price, buys, checks balance 0, the car saved and spawned), `forgedBuy()`
(fires `BuyVehicle` for the Arc with too little cash; expects a rejection), and `usedLotDeterminism()` (calls
`stockFor` for today twice as two "servers" would and compares). Returns plain tables.
