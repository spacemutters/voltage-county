# Voltage County designer backend

The small web service behind the AI Car Designer. The game server sends it a player's (already filtered)
description; it asks Claude for a car design or a mod, checks and clamps the answer, and sends back a design
the game can build, or a friendly "we can't make that one". Only the game server can call it (shared secret).

## Set it up (Davis)

You need: a Supabase project, an Anthropic API key, a Vercel project and the Roblox Creator Dashboard.

1. **Supabase tables.** Open your Supabase project, go to **SQL Editor**, paste all of
   `supabase/migrations/0001_designer.sql` and click **Run**. Then go to **Project Settings > API** and copy the
   **Project URL** and the **service_role** key (the secret one, not the anon key).
2. **Anthropic key.** In the Anthropic Console, create an API key for this game.
3. **Shared secret.** Make one long random password that the game and the backend share. In PowerShell:
   ```powershell
   $b = New-Object byte[] 32; [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b); -join ($b | % { $_.ToString('x2') })
   ```
   Keep it somewhere safe. It never goes in the repo or in game code.
4. **Vercel project.** Create a Vercel project from this repo with **Root Directory** set to `backend` and the
   framework preset **Other**. In **Settings > Environment Variables** add these four for **Production**:
   | Name | Value |
   |---|---|
   | `ANTHROPIC_API_KEY` | the key from step 2 |
   | `SUPABASE_URL` | the Project URL from step 1 |
   | `SUPABASE_SERVICE_ROLE_KEY` | the service_role key from step 1 |
   | `ROBLOX_SHARED_SECRET` | the secret from step 3 |

   Then deploy: from the `backend` folder run `vercel --prod --yes --scope spacemutters-projects` (or press
   **Redeploy** in Vercel). Note the address it gives you, for example `voltage-designer.vercel.app`.
5. **Roblox secret.** In the Creator Dashboard open the experience, go to **Secrets**, click **Create Secret**:
   name `designer_key`, value = the secret from step 3, domain = your Vercel address from step 4 (without
   `https://`). In **Experience Settings > Security**, turn on **Allow HTTP Requests**.
6. **Studio testing.** Studio can't read the Dashboard's secrets. In Studio open **Game Settings > Security** and
   add a local secret in the box there, in this form (your own secret and address):
   ```json
   { "designer_key": ["<the secret from step 3>", "voltage-designer.vercel.app"] }
   ```
7. **Point the game at it.** The game reads the address from `backendUrl` in `src/shared/Config/Designer.luau`;
   it must be your Vercel address from step 4 (with `https://`).

Until step 1 is done the live (Production) deployment answers every request with "The design studio isn't set
up yet" and the game gives the credits back, because without Supabase the daily spend cap and the limits can't
hold. Preview deployments and local runs keep their limits and cache in memory instead (they reset often and
aren't shared between servers). To run Production on memory anyway for a short test, add the environment
variable `DESIGNER_ALLOW_MEMORY_STORE` = `1`, and remove it again afterwards.

## Change limits or switch it off

In Supabase open **Table Editor > vc_designer_settings** and edit the one row. Changes apply on the next request.

| Column | What it does |
|---|---|
| `enabled` | the on/off switch; off = every request gets "taking a short break" |
| `daily_spend_cap_usd` | the most Claude may cost per day (UTC); after that requests stop until midnight UTC |
| `player_hourly_limit` / `player_daily_limit` | designs and mods one player can ask for per hour / per 24 hours |
| `global_hourly_limit` | requests from everyone together per hour |

Players are never charged for a stopped request: the game refunds their credits.

## Block a description

1. In **Table Editor > vc_designer_usage**, find the request (the `prompt` column shows what the player wrote).
2. Copy its `prompt_hash`.
3. In **Table Editor > vc_designer_blocklist**, insert a row with that `prompt_hash` (and a note if you like).

The same words, however they're capitalized or punctuated, are refused from then on.

## Run the prompt suite

The suite sends 90 test prompts (normal cars, real brand names, famous movie cars, offensive requests, tricks,
"fastest car ever", gibberish, other languages) to the **live** backend and checks every answer. It uses real
Claude tokens, well under 10 cents a run, so it only runs when you start it. In PowerShell:

```powershell
cd backend
$env:SUITE_URL = "https://voltage-designer.vercel.app"   # your Vercel address
$env:SUITE_KEY = "<the secret from step 3>"
npm run suite
```

It prints PASS or FAIL for each prompt and ends with `ALL 90 PASSED` or the list that failed. The full answers
are saved in `tests/suite/results/` (not committed).

## For developers

- `npm install`, then `npm test` (unit tests, no network: Claude and Supabase are replaced by fakes) and
  `npm run typecheck`.
- After any change to `src/shared/Config/DesignKit.json` or `scripts/banned-names.txt`, run `npm run sync-kit`;
  a test fails until the copies in `lib/` match.
- Node 24 runs the `.ts` files directly (type stripping), so: `import type` for types, `.ts` extensions in
  relative imports, and no enums, namespaces or parameter properties.
- `lib/prompt.ts` has an empty `ANTHROPIC_CHILD_SAFETY_PROMPT`. If Anthropic gives you a child-safety system
  prompt for products minors use, paste it there exactly; it goes first in the system prompt.

### HTTP contract (the game server is the only caller)

`POST /api/design` and `POST /api/mod`, header `x-api-key: <ROBLOX_SHARED_SECRET>`, JSON body:

- design: `{ kitVersion, userHash, prompt, classId?, reroll? }`. `classId` missing or null = "surprise me".
- mod: `{ kitVersion, userHash, prompt, kind: "kit" | "catalog", classId, current, reroll? }`. `current` is the
  car's design spec (kit cars) or look (catalog cars), at most `limits.specBytes` bytes of JSON.
- `userHash` is the game's salted SHA-256 of the UserId (64 hex characters). `reroll: true` skips the cache so a
  re-roll gets a new design (it isn't cached either).

Replies (the game refunds credits on everything but `ok: true`):

| Status | Body | When |
|---|---|---|
| 200 | `{ ok: true, spec, cached }` | a design or mod spec, already validated and clamped |
| 200 | `{ ok: false, refusal }` | a friendly refusal: unsafe, brand names twice, blocklisted, too little text |
| 400 / 413 | `{ ok: false, refusal }` | a malformed or oversized request |
| 401 | `{ ok: false, refusal }` | wrong or missing `x-api-key` |
| 409 | `{ ok: false, refusal }` | `kitVersion` differs from the backend's kit (deploy after `npm run sync-kit`) |
| 429 | `{ ok: false, refusal }` | the off switch, a player or global limit, or the daily spend cap |
| 502 / 503 / 504 | `{ ok: false, refusal }` | Claude or Supabase failed, setup missing, or too slow |

The backend answers within about 25 seconds; the game should wait at least 30.
