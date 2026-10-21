# Phase 14 contracts

Performance, security, soft launch (PLAN.md "Phase 14" is the spec). Read `CLAUDE.md` and every earlier contract.
This phase mostly audits and hardens what exists; new gameplay is out of scope.

## Security (owner: security helper)
- `docs/SECURITY.md`: one table row per remote in `src/shared/Net.luau` and per backend endpoint — direction, payload
  validator, rate limit, who may call it (anyone / owner / admin / Studio only) and the abuse it prevents. A spec
  (`tests/SecurityDoc.spec.luau`) fails when a remote in Net.luau has no row.
- `src/client/Dev/FuzzTests.luau` + a server-side counterpart: fire every client → server remote with random and
  hostile payloads (wrong types, huge strings, NaN/inf, nested tables, extra args, bursts over the rate limit) and
  check the server logs no errors and state is unchanged where it should be. Studio only.
- Fix what the fuzzing finds.

## Backend review (owner: security helper)
No secrets in the repo (scan the history too), the shared secret rotation procedure written down, limits and the
spend cap verified with the in-memory store tests, Supabase tables RLS-on and service-role only.

## Data safety (owner: data helper)
Every migration from v1 to the current version runs on a fixture profile of each version (spec); ProfileStore session
locks reviewed (no double-load); `pendingGrants` recovery; credit reservations cleared on join; `receipts` capped;
nothing drops a player-owned field.

## Performance (owner: perf helper)
- Budgets: 60 fps desktop, 30+ fps mid-range phone; greybox cars ≤ 60 parts (a spec over every built model and every
  designer template); generated meshes ≤ 20k triangles at the top LOD (GeneratedAdapter rejects bigger).
- Streaming: `StreamingMinRadius`, `StreamingTargetRadius` and `StreamOutBehavior` tuned for the highway; these are
  not scriptable, so the lead sets them in Studio and records the values (Workspace properties).
- A Studio perf driver (`src/client/Dev/PerfTests.luau`): drives the County Loop at highway speed with traffic on and
  reports frame time (mean / p95), memory and instance counts; and a server heartbeat sampler.

## Compliance and launch (owner: launch helper)
- Compliance pass over the code: all player and AI text filtered, no paid random items, no off-platform links,
  audio only from licensed/owned sources (asset 0 placeholders stay silent), the store shows exactly what a credit
  buys, the AI disclosure before the first request.
- `docs/LAUNCH.md`: Davis's checklist in plain numbered steps — icon and thumbnails, a title and description with no
  real brand names, the maturity questionnaire, Managed Pricing, DevEx account and tax form, a privacy page (what the
  designer sends to the AI provider; a COPPA statement), creating every pass/product/subscription and pasting the
  ids, the backend secrets, a private beta with friends, then public.
- A plain-language privacy page draft (`docs/privacy.html`) for Davis to host.
