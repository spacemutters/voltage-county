# Phase 7 contracts

Customization and light shows (PLAN.md "Phase 7"). Read `CLAUDE.md` (text safety and fair monetization matter
here) and the earlier contracts (`docs/phase-1..6-contracts.md`, still in force). Implement exactly the names
below; anything not written here is the owner's choice. Earlier phases are done and checked: change them only
where this document says so.

## Wrap & Tint shop (owner: customization helper)

### `Config/Customization.luau`
- `paints`: a curated palette (16–24 named colors, ids like `"pearl_white"`), plus a constrained custom color
  (hue/saturation/value limits so nothing is pure neon or unreadably dark) and its price.
- `finishes`: `gloss`, `matte`, `metallic` (Material + Reflectance per finish) with prices.
- `wraps`: 6–10 original wrap designs (stripe and panel patterns built from parts or Textures/Decals made in
  code — no uploaded images until Davis approves art), prices; `"none"`.
- `wheels`: 6–8 original wheel styles (rim shape variants for the greybox wheel), prices.
- `rideHeight` (−1..1 mapped to a studs offset per class), `tint` (0..1 window transparency steps), caliper
  colors, kit extras that mount on `Mount_*` attachments (spoilers, roof racks, light bars, bull bars; which
  classes may take each), and plate formats.
- Prices are a money sink (§4), in-game $ only. Nothing here is random or sold for Robux in this phase.

### `src/shared/Vehicle/Appearance.luau` (pure apart from instance edits)
`Appearance.apply(model: Model, look: Look)` sets a car model's look from an `OwnedVehicle`'s fields (paint,
finish, wrap, wheels, rideHeight, tint, caliper, extras, plate) using the model contract's tags (`Paint`, `Trim`,
`Glass`) and mount attachments. Idempotent (re-applying replaces the old extras). Used by the server when a car
spawns and by the client preview.

### Schema v5
`OwnedVehicle` gains `caliper: string`, `extras: { string }` and `plateFormat: string` (migration 4 → 5 with
defaults). Bump `Config/Data.schemaVersion`; update Types, Migrations, Template and their specs.

### `src/server/Services/CustomizationService.luau`
- Net `BuyCustomization { uid, changes = { paint?, customColor?, finish?, wrap?, wheels?, rideHeight?,
  tint?, caliper?, extras?, plateFormat? } }` (function): validates every value against Config (unknown ids,
  out-of-range numbers, extras not allowed on that class are refused), prices the change (only what differs from
  the current look), `EconomyService.trySpend`, saves to the OwnedVehicle, and re-applies the look to the car if
  it's out. Returns `{ ok, message, cost }`.
- Spawned owned cars get their saved look (hook in GarageService / VehicleService spawn path; edit those only
  for that).

### Plates
- Standard formats are free. Custom text needs the Custom Plates pass (Phase 12): `CustomizationService`
  checks `MonetizationService.hasPass(player, "customPlates")` if that exists, else allows custom text **only in
  Studio** (`RunService:IsStudio()`).
- Text (≤ 8 characters, A–Z, 0–9, space, dash) is filtered with `TextService:FilterStringAsync(text, userId,
  Enum.TextFilterContext.PublicChat)` then `GetNonChatStringForBroadcastAsync()` when set, and filtered again
  when a car spawns. Only the filtered text is ever shown on a plate. A failed filter call shows a blank plate.
- Net `SetPlate { uid, text }` (function).

### Client: `Controllers/CustomizationController.luau`, `UI/Customize/*.luau`
A Wrap & Tint shop at a new `CustomShop` location (MapLayout: add one in Cedar Bend and one at The Plant; tag
`CustomShop`; MapBuilder builds a garage-door prop; the commerce/map owner of Phase 4 already did pads — follow
the same pattern). Opening the shop (ProximityPrompt) while in an owned car shows: category tabs (Paint, Finish,
Wrap, Wheels, Stance, Tint, Calipers, Extras, Plate), options as swatches/cards with prices, a **live preview on
the player's own car on the client only** (Appearance.apply on the local model, reverted on cancel), a running
total, and Buy. Mobile-first; Theme only.

## Light shows (owner: light-show helper)

### `Config/Audio.luau` and `Config/LightShows.luau`
- Tracks: Davis allowed **Roblox's own licensed music library** (Creator Store audio published by Roblox; audio
  only, never models or scripts) **or original music made with his ElevenLabs account**. For this phase use
  placeholder entries with `assetId = 0` that no-op safely, plus the track's bpm and length; the lead fills real
  ids after picking tracks. Never insert anything from the Creator Store.
- Show routines: a timeline per track of light cues (headlights, taillights, brake, reverse, door/hood motion on
  the `Doors` folder if present, neon underglow if the car has the light-bar extra), beat-aligned from bpm.

### `src/server/Services/LightShowService.luau`
- Net `JoinLightShow { meetSpotId }` (function): players parked at a `MeetSpot` (car within its footprint,
  still) can start or join a show there. The server picks the routine and a start time
  `workspace:GetServerTimeNow() + leadIn` and fires Net `LightShowStart { showId, routineId, startAt, cars =
  { carModels } }` to everyone near the meet spot.
- `LeaveLightShow`, auto-end at the routine's end. Boombox & Light Show Pro (Phase 12) will unlock extra
  routines: check `MonetizationService.hasPass` if it exists, else Studio-only.

### `src/client/Controllers/LightShowController.luau`
Schedules the cues locally against `workspace:GetServerTimeNow()` so every client runs the show in sync (each
client animates every car in the show; no per-frame network traffic). Plays the track (if `assetId ~= 0`) from
the right offset. Stops cleanly when the show ends or the player drives off.

### Studio test `src/client/Dev/LightShowTests.luau`
`sync(cars = 3)`: spawns three cars at a meet spot (dev path), starts a show, records when each car's first
three cues fire on this client (all scheduled from the same server start time) and reports the spread (must be
≤ 100 ms).

## Net (declared by the lead before the build)
`BuyCustomization`, `SetPlate`, `JoinLightShow`, `LeaveLightShow` (client → server functions);
`LightShowStart`, `LightShowEnd` (server → client).
