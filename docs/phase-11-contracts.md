# Phase 11 contracts

AI Car Designer and AI mods (PLAN.md "Phase 11": read it whole, it is the spec; this document only fixes names,
owners and the decisions taken). Read `CLAUDE.md` (hard rules 4, 5, 6, 7, 11) and the earlier contracts
(`docs/phase-1..10-contracts.md`, still in force).

## Decisions already taken
- **Generated looks:** the Phase 1 spike found generated meshes have no asset id and can't come back after a rejoin.
  Davis chose "AI look + saved kit car": a new design shows its generated body (`GeneratedAdapter`) in the session
  it was made when generation succeeds within the time budget; the saved car always rebuilds from its kit spec
  (`SpecBuilder`). Mods are kit-only (the optional generated accessory follows the same session-only rule).
- **Model:** `claude-haiku-5-5` with structured outputs (`output_config.format` JSON schema built from the kit),
  prompt caching on the static system prompt.
- **Secrets:** never in the repo or game code. The backend reads `ANTHROPIC_API_KEY`, `SUPABASE_URL`,
  `SUPABASE_SERVICE_ROLE_KEY` and `ROBLOX_SHARED_SECRET` from Vercel env vars; the game reads the shared secret
  with `HttpService:GetSecret("designer_key")` and sends it in the `x-api-key` header. Davis enters every secret.
- **Store:** Supabase (tables below). Until the project exists the backend runs its limits and cache through an
  in-memory store behind the same `Store` interface (tests use it too), so everything but the live deploy can be
  built and tested.

## Kit (owner: kit helper)

### `src/shared/Config/DesignKit.json` (kitVersion 1) — single source of truth, **written by the lead**
Every helper builds against it as it is; a helper who needs a change describes it in their report (the fixer
applies it and bumps nothing else). What it holds:
- `limits` (text lengths, max extras, spec bytes, minFilteredChars), `ranges` (the spec's numeric ranges) and
  `proportions` (how each 0..1 body/stance number maps to geometry scale factors, per field).
- `classes`: the designable classes (`Config/Classes.designable`), each with its body templates and tier rules
  (exotic needs an owned exotic; hypercar is never designable).
  (`requiresOwnedClass` for exotic), `surpriseClasses` for "surprise me".
- `templates`: body template id → the generic body `style` it builds on (`VehicleBuilder` STYLE_BUILDERS keys), seat
  count and base `geometry` (the same fields as `Config/Vehicles` geometry).
- `parts`: frontBumper, rearBumper, spoiler, lights variant ids, and wheels (the Phase 7 `Config/Customization` wheel
  style ids); `extras`: the Phase 7 kit extras with their mount point.
- `finishes`, `stripes`, `energy`; `personalities` as positions inside the class band (× `bandCeiling` 0.85, so a
  design never matches the band's best catalog trims); `mod` (the `"keep"` word and what a mod may touch on catalog
  vs kit cars).
- Rojo serves the JSON as a ModuleScript (`require` returns the table). `backend/lib/kit.json` is a copy
  (`npm run sync-kit`); a backend test fails when they differ.

### Shared body building (`src/shared/Vehicle/BodyKit.luau`)
The generic-body machinery moves out of `src/server/Dev/VehicleBuilder.luau` into this runtime module (no Studio
or Edit-mode guards): the STYLE_BUILDERS, wheels, seats, lights, points (attachments, mounts) and the contract
check. `VehicleBuilder` keeps its Edit-mode API, its bespoke Ohm SHAPES and storage, and calls `BodyKit` for the
rest; **every catalog model must come out exactly as before** (tests/VehicleBuilder.spec.luau keeps passing).

### `src/shared/Vehicle/SpecBuilder.luau`
`SpecBuilder.build(spec, kit): Model` — a contract model (`custom_<designUid>` naming via attributes `VehicleId =
"custom"`, `DesignUid`) from a validated design spec: geometry from the class band × template proportions × the
spec's body numbers, parts variants, paint/finish/stripe, stance. ≤ 60 parts. Deterministic.
`SpecBuilder.stats(spec, kit): Stats` — top speed, 0–60, handling, energy range from the class band and
personality only (text can never push stats outside the band).

### `src/shared/Vehicle/ModBuilder.luau`
`ModBuilder.apply(model, modSpec, kit, kind: "kit" | "catalog")` — kit and designed cars: swap parts, re-proportion
within ranges; catalog cars: paint, finish, stripes, wheels, stance and mount extras only. Up to 4 extras on mount
points. Never touches the Chassis or physics.

## Server (owner: designer-server helper)

### `src/server/Services/CreditsService.luau`
Balance, the one free new car, reserve → spend / refund (by reservation id), stale reservations cleared on join,
nothing below zero; Studio-only grants (`DevCredits`). Purchases plug in in Phase 12 (`CreditsService.grant(player,
amount, reason)`).

### `src/server/Services/DesignerService/init.luau` (+ `Validate.luau` pure)
The PLAN's 7 steps for new cars and mods. Calls the backend with `HttpService:RequestAsync` (URL from
`Config/Designer.backendUrl`, secret via `HttpService:GetSecret`), timeout, one retry on a network error. Sends
only the filtered text, the class (or the target car's class + current spec), a salted UserId hash
(`HashLib`/`HttpService` SHA-256 of salt .. UserId; the salt is a second secret `designer_salt`) and the kit version.
`Validate.design(spec, kit)` / `Validate.mod(spec, kit, kind)` re-validate and clamp everything (the backend isn't
trusted). Filters name/tagline/summary with TextService. New cars: save to `designs` (≤ 2 KB JSON) and add an
`OwnedVehicle { vehicleId = "custom", designUid }`; mods: save to that car's `mods`. Re-roll: once free per paid
design. Moderation: `ReportDesign` and an admin `HideDesign` (Config/Admins), hidden → plain kit/stock look.

### `src/shared/Vehicle/GeneratedAdapter.luau` (server-side use)
`GenerationService:GenerateModelAsync` with the `Car5` schema and the spec's `meshPrompt`, scaled ~7× to the class
size, mapped onto the contract (Chassis from bounds, hubs from the wheel centres, seats/lights/mounts from class
templates). Any error or > `Config/Designer.generationTimeoutSeconds` → `SpecBuilder`. The generated look is
session-only (attribute `GeneratedLook = true`); the saved car is always the kit build. Check the API on the Roblox
docs (`http_get`-able) before relying on names.

### Vehicle spawning
`VehicleService` spawns `vehicleId = "custom"` cars by building from the design spec (cached per design uid per
server) instead of cloning from `ServerStorage.VehicleModels`; mods applied with `ModBuilder` on spawn; chassis
tuning from `SpecBuilder.stats`.

### `src/shared/Config/Designer.luau`
backendUrl, timeouts, prices (new car 2 credits, mod 1, one free re-roll, first car free — read PLAN §4), slot
rules, generation budget, plain-language messages, the AI disclosure text.

## Backend (owner: backend helper) — `backend/`
TypeScript on Vercel (Node runtime). Runtime packages exactly as PLAN.md's stack lists them: `@anthropic-ai/sdk`,
`zod`, `@supabase/supabase-js`; dev only `typescript` and `@types/node` (for `npm run typecheck`). Tests use Node's
built-in runner (`node --test`, Node 24 runs `.ts` directly), so no test framework is added. Add nothing else
without asking Davis.
- `api/design.ts`, `api/mod.ts` exactly as PLAN.md Phase 11 "Tasks: backend" (shared secret in `x-api-key`, limits,
  spend cap and on/off switch in `designer_settings`, cache by normalized prompt (+ car for mods), Claude call with
  structured outputs + prompt caching, Zod validation + clamping, log, friendly refusal).
- `lib/prompt.ts` with every rule in PLAN.md "system prompt rules" (player text is data, original designs only,
  brand/model/franchise → original vibe, general-audience safety, kit enums only).
- `lib/schema.ts` (JSON schema and Zod built from `lib/kit.json`), `lib/limits.ts`, `lib/store.ts` (`Store`
  interface: Supabase implementation + in-memory implementation), `lib/brands.ts` (the blocklist: reuse
  `scripts/banned-names.txt`, copied by `sync-kit`).
- `supabase/migrations/0001_designer.sql`: `designer_settings` (enabled, daily_spend_cap_usd, per-player and
  global limits), `designer_usage` (hash, kind, prompt_hash, tokens, cost, created_at), `designs` (prompt_hash,
  kind, car_key, spec jsonb, created_at; the cache), `designer_blocklist` (prompt_hash). RLS on, service role only.
- `tests/`: unit tests (`node --test`; auth, limits, clamping, cache, refusal paths) with the Anthropic client
  mocked, and
  `tests/suite/` — the 60 new-car + 30 mod adversarial prompt suite as data, plus a runner (`npm run suite`) that
  calls the live deployment; it is **not** part of `npm test` (it costs real tokens) and runs only on Davis's yes.
- `package.json` scripts: `test`, `sync-kit`, `suite`; `vercel.json`; `README.md` (setup steps for Davis).

## Client (owner: designer-ui helper)
react-lua, reusing the phone and shop kits: the **Design Studio** (at the `DesignStudio` location and, after the
first visit, the phone's Designer app): prompt box with a 200-character counter, class picker or "surprise me",
credit cost, the AI disclosure shown before the first request, progress screen, result card (build, re-roll,
discard). **"Mod with AI"** on each car in the Garage with before/after preview and cost. **Out of credits** sheet
(store stub until Phase 12). A **Report** button on custom and modded cars.

## Net (declared by the lead before the build)
`DesignCar { prompt, classId? }` (function → `{ ok, message, requestId? }`), `ModCar { uid, prompt }` (function),
`DesignResult` (server → client `{ requestId, ok, message, design?, preview? }`), `DesignChoice { requestId,
choice = "build" | "reroll" | "discard" }` (function), `ReportDesign { uid, reason }` (function),
`HideDesign { designUid }` (function, admins only), `DevCredits { amount }` (function, Studio only).

## Tests (owner: designer-tests helper)
Specs: `tests/DesignKit.spec.luau` (kit sanity, JSON ↔ Luau ranges), `tests/SpecBuilder.spec.luau` (every template
builds a contract-valid model ≤ 60 parts; stats inside the class band for every personality; forged/out-of-range
specs clamped), `tests/ModBuilder.spec.luau`, `tests/Credits.spec.luau` (the free car exactly once; reserve/spend/
refund on success, refusal, error and timeout; free re-roll once; never below zero), `tests/DesignerValidate.spec.luau`
(forged and tampered specs rejected; stats always in band, mods included). Studio driver
`src/client/Dev/DesignerTests.luau`: builds a design from a fixed spec through the dev path (no backend), spawns it,
and runs the Phase 1 driving checks (settles, crosses the bumps without flipping, 0–60 inside its class band with the
AutoDriver on the dev track); `all()` does every template.
