# Progress log

Newest first. Each entry: what shipped, how to try it in Studio, open issues.

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

**Not checked yet.** No Studio was open, so the playtest boot lines and the harness run have not been seen.
Under Davis's ship-first rule, he checks:
- Press Play: `[Server] booted 0 services`, `[Client] booted 0 controllers`, no errors.
- Command bar: `TESTS: passed=11 failed=0`.

**Open issues**
- Studio may cache required modules between command-bar runs. The harness re-requires each spec from a fresh
  copy, but if a changed module seems stale, run the harness inside a playtest instead.
