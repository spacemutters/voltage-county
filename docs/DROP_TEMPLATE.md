# Drop template: ship a new trim or vehicle in a day

Copy this list into the drop's task and tick each line. It covers a new trim on an existing car, a new car, and a
limited drop (a serial-numbered car sold in a time window). Plain steps, in order. Anything that needs the Creator
Dashboard or publishing is Davis's (CLAUDE.md, "Ask Davis before").

Allow about a day: steps 1 to 4 in the morning, 5 to 8 after lunch, and steps 9 and 10 at the end of the day.

## 1. Decide what ships

- [ ] Name, brand (`Config/Brands`), class (`Config/Classes`) and whether it is sold at the dealership, used lot or
      only as a limited drop.
- [ ] The name is made up. No real carmaker or model name, and not a near-copy of one (CLAUDE.md hard rule 4).
      `scripts/check.ps1` greps for the banned names, but it can't spot a near-copy.
- [ ] Its stats sit inside its class band. Credits buy looks, never stats, so a limited car never beats its class.

## 2. Config entry (`src/shared/Config/Vehicles.luau`)

- [ ] A new trim goes in the vehicle's `trims`. A new vehicle gets a full entry: brand, class, energy, geometry and
      body style.
- [ ] `acquisition`: `"dealership"` (with `price`), `"usedLot"`, or `"limited"` (no `price`; the drop sets it).
- [ ] Upgrade trims set `upgradeFrom` and use `price` as the upgrade cost.
- [ ] Run the specs: `tests/Catalog.spec` (Catalog.validate checks every stat against its class band) and
      `tests/BrandNames.spec`.

## 3. Model (vehicle model contract, PLAN.md §6)

- [ ] Greybox: in Edit mode, `require(game.ServerScriptService.Server.Dev.VehicleBuilder).build("<vehicleId>",
      "<trimId>")`. It checks the contract before it stores the model in `ServerStorage.VehicleModels`.
- [ ] Final art: the artist's model is named `<vehicleId>_<trimId>`, keeps the contract (Chassis, Body, Wheels,
      Seats, Lights, the attachments; docs/ART_BRIEF.md has the checklist) and has no `Greybox` attribute, so
      rebuilds never overwrite it. Run `VehicleBuilder.check(model)`; it must return an empty list.
- [ ] Drive it: spawn it from the Studio spawn menu, then run the AutoDriver checks. It must settle, cross the bumps
      without flipping, and run 0 to 60 inside its class band.

## 4. Dealership pad (`Config/MapLayout.dealership`)

- [ ] Dealership cars take the next free pad in their brand's section automatically, cheapest first
      (DealershipService.lineups). Count the brand's dealership cars against its pads.
- [ ] If the section is full, add a pad to the brand's `section(...)` row, then rebuild the map in Edit mode
      (`Dev/MapBuilder.build()`) and run `Dev/MapCheck.run()` and `tests/MapBuilder.spec` (no notes).
- [ ] Limited-only and used-lot cars need no dealership pad.

## 5. Limited drop (skip for a normal trim)

- [ ] `Config/Limiteds.drops`: id, name, `vehicleId`, `trim` (acquisition `"limited"`), `startsAtUtc` and
      `endsAtUtc` (UTC Unix seconds), `supply`, and `price` in in-game cash.
- [ ] Serials come from DataStore `UpdateAsync` on the drop's own key, so nothing else needs setting up.
- [ ] Limited cosmetics sold for Robux (wraps, plate frames): a `Config/Limiteds.cosmetics` entry with
      `productId = 0`. Davis creates the developer product and pastes its id. Never write a Robux price anywhere;
      `tests/NoRobuxPrices.spec` fails if you do.
- [ ] `tests/Limiteds.spec` passes.

## 6. Event entry (`Config/Events.schedule`)

- [ ] Add an event for the launch: id, name, banner line, the same UTC window as the drop,
      `featuredVehicleId = "<vehicleId>"` (it gets the dealership spotlight), and an optional `earningsMultiplier`
      or `bonusCredits`.
- [ ] An event can also go live without an update: add it to the live events DataStore key (Config/Events `live`).
      It reaches every server within `live.refreshSeconds`.
- [ ] `tests/Events.spec` passes.

## 7. Season, billboards and flags (optional)

- [ ] Season tie-in: a reward on the current season's track (`Config/Season`), if the drop lines up with it.
- [ ] Billboards: the brand already has a poster (`Config/Ads.billboards.posters`). Once a poster image is uploaded,
      paste its `rbxassetid://` into that brand's `image`.
- [ ] The `drops` and `events` feature flags are on. To pull a drop in a hurry, switch its flag off in the live flags
      DataStore key (Config/FeatureFlags `live`). Every server picks it up within a minute.

## 8. Checks

- [ ] `scripts/check.ps1` passes: strict mode, brand names, StyLua, Selene and the Rojo build.
- [ ] The whole harness in Studio's Edit mode shows `TESTS: passed=N failed=0`.
- [ ] Playtest: buy it, or buy a serial during a test window. It lands in the garage, spawns and drives, and the
      event banner and countdown show.

## 9. Changelog

- [ ] Add a `docs/PROGRESS.md` entry: what shipped, when the drop and event run, the supply and price, and anything
      left for Davis.
- [ ] Write the in-game update note in plain words for the experience's description or social post (Davis posts it).

## 10. Thumbnail and publish (Davis)

- [ ] A new thumbnail or icon variant featuring the car: original art, no real brands or logos, and no text promising
      anything the game doesn't do.
- [ ] Davis uploads the thumbnail and publishes the place in the Creator Dashboard. Products and passes are his to
      create too.
- [ ] After publishing, check that the drop's countdown shows on a live server, and that the drop opens on time.
