# CLAUDE.md — Voltage County (working title)

An original open-world driving + roleplay game for Roblox, in Greenville's genre (not a copy). It has a multi-brand catalog of original cars and an AI Car Designer (new cars and AI mods, paid with Design Credits) backed by a small Vercel service.
- Build plan: `PLAN.md`
- Progress log: `docs/PROGRESS.md`
- Owner: Davis. He's on Windows and uses PowerShell, and he knows React, TypeScript, Vercel and Supabase.

## Stack
- Luau, with `--!strict` at the top of every new file
- Rojo, partially managed: it syncs `src/` and config only; Studio owns Workspace and `ServerStorage.VehicleModels`
- Tooling: Rokit, Wally, Selene, StyLua, luau-lsp
- Libraries: react-lua for UI; ProfileStore (vendored) for player data
- Tests: the in-repo harness at `src/shared/Testing/Harness.luau`
- Roblox Studio's built-in MCP server, for running Luau, playtests, console output, screenshots and input simulation
- Backend (`backend/`, AI Car Designer only): TypeScript serverless functions on Vercel, the Anthropic TypeScript SDK, Zod, Supabase

## Commands
- Install tools and packages: `rokit install`, `wally install`
- Sync to Studio: `rojo serve` (Davis connects the Rojo plugin in Studio)
- Quality gate, before every commit: `scripts/check.ps1` (StyLua check → Selene → Rojo build)
- Tests: run the harness through Studio MCP `execute_luau` in the Edit datamodel. Expect `TESTS: passed=N failed=0`.
- Backend (from `backend/`):
  - Test: `npm test`
  - After any `DesignKit.json` change: `npm run sync-kit`
  - Deploy: `vercel --prod`, once tests pass

## Layout
- `src/shared` → ReplicatedStorage.Shared (Config, Net, Types, Vehicle, Road, Testing, Util)
- `src/server` → ServerScriptService.Server (Services, Vendor, Dev)
- `src/client` → StarterPlayer.StarterPlayerScripts.Client (Controllers, UI, Dev)
- `tests` → ServerStorage.Tests
- `backend/` → Vercel project for the AI Car Designer (api, lib, supabase migrations, tests)
- `docs/` → PROGRESS, SECURITY, DROP_TEMPLATE, ART_BRIEF

## Hard rules
1. **Server-authoritative.** Clients send intents ("buy X", "start job Y"), never outcomes ("add $500"). The server validates and decides cash, credits, purchases, job steps, ability cooldowns and limited serials.
2. **One network module.** Every RemoteEvent and RemoteFunction is declared in `Shared/Net.luau` with a payload validator and a per-player rate limit. No ad-hoc remotes.
3. **Data-driven.** All tunables live in `Shared/Config/*` (and `DesignKit.json`). No magic numbers in systems.
4. **Brand and IP.**
   - Vehicle names, logos and models come only from `Config/Brands.luau`, `Config/Vehicles.luau`, and models that follow the vehicle model contract (PLAN.md §6).
   - Never put real carmaker or model names in game strings, instance names, badges, the experience title or description, or prompts to generation tools, unless that brand's entry is licensed.
   - Player designs and AI mods follow the same rules.
   - Never copy assets, code, maps or UI from other games.
5. **Text safety.** Player-entered text (plates, names, design prompts) and AI-generated text are filtered with TextService before anyone else sees them.
6. **Fair monetization.**
   - No paid random items, and `ProcessReceipt` is idempotent.
   - Placeholder product IDs (`0`) must no-op safely.
   - Credits buy looks, not progression: stats always come from class bands.
   - Never hard-code Robux prices; read them from MarketplaceService (Managed Pricing changes them).
   - Ads go only through Roblox's ad APIs (AdGui billboards, AdService rewarded video), and only when Roblox says an ad can show.
   - Never point players to buy anything outside Roblox.
7. **Data safety.** A schema change means a `version` bump, a migration and a spec. Never drop player-owned fields without a migration.
8. **Dev tools stay dev.** Cash and credit grants, teleports, AutoDriver and builders run only when `RunService:IsStudio()` is true, and are admin-gated where relevant.
9. **Build scripts run in Edit mode** via `execute_luau`, never at runtime. MapBuilder owns only `Workspace.Map.Generated`.
10. **Performance.**
    - No polling loops for gameplay; use RunService events, caches and CollectionService.
    - UI and controls are mobile-first.
11. **AI Car Designer.**
    - API keys and secrets live only in Vercel env vars and the Roblox Secrets store, never in the repo or game code.
    - Only the filtered description, the class or target car spec, a salted UserId hash and the kit version leave Roblox. Never usernames, raw UserIds or chat.
    - AI output is untrusted: validate and clamp it in the backend and again in the game.
    - Credits are reserved when a request starts, spent only on a successful build, and refunded automatically on refusal, moderation failure or error.
    - Players are told an AI designs the cars before their first request.

## Studio MCP
- Start with `list_roblox_studios`, and pass `studio_id` on every call.
- Edit code in `src/` only; Rojo syncs it. Don't edit synced scripts with MCP script tools.
- Verify with `start_stop_play`, `get_console_output`, `screen_capture`, `user_keyboard_input` and `character_navigation`.
- Check unfamiliar APIs with `http_get` on Roblox docs before relying on them.
- Never `insert_asset` from the Creator Store without Davis's OK.
- If no Studio is connected, do code-only work and list what still needs a playtest.

## Workflow
- Work one phase at a time from PLAN.md, on a branch named `phase-N`.
- For each phase:
  1. sub-plan
  2. implement
  3. quality gate
  4. specs
  5. MCP playtest checks
  6. tick the boxes in PLAN.md
  7. add a `docs/PROGRESS.md` entry
  8. commit `phase N: <summary>`
  9. stop and report
- Backend changes: once tests pass, deploy to production on Vercel (`vercel --prod`). Davis wants changes pushed to the live deployment.
- Ask Davis before:
  - adding a package
  - changing the data schema after launch
  - anything that needs the Creator Dashboard (publishing, passes, products, secrets)
  - anything that needs new accounts or API keys
- Don't read or edit `Packages/` or `src/server/Vendor/` except to bump a pinned version.
- Keep reports short: what works, how to try it in Studio, what's next, and any decision Davis needs to make.
