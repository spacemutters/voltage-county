# Security

Voltage County is server-authoritative (CLAUDE.md hard rule 1): a client sends intents ("buy this car", "start
this job"), never outcomes ("add $500"). The server looks everything up in its own data and decides.

Every remote is declared once, in `src/shared/Net.luau`, with a payload validator and a per-player rate limit.
Before any handler runs, Net checks each client → server call:

1. **Arguments.** One payload value or none. A call with extra arguments is rejected (`arity`).
2. **Rate limit.** A token bucket per player and remote (`Util/RateLimiter`). "3, 0.5/s" below means 3 calls at
   once, then one more every 2 seconds. Over the limit, the call is rejected (`rate`). Buckets are dropped when the
   player leaves.
3. **Payload.** The validator (`Util/Check`) accepts only the exact shape:
   - tables may not carry undeclared keys;
   - numbers must be finite (no NaN or infinity) and in range; integers must be whole and never `-0`;
   - strings must be valid UTF-8 under a byte cap, with no NUL byte, and not empty: `Check.string(max, min?)`
     defaults to at least 1 byte, so every id, prompt and code field is non-empty. Only `SetPlate.text` takes `""`
     (`Check.string(16, 0)`), which clears the plate;
   - lists (`Check.array`) are refused as soon as they pass their length cap, so a huge one costs no more to check
     than a short one;
   - enums must be one of the listed values.
   Anything else is rejected (`payload`). A validator never throws, whatever it is given.
4. **Direction.** A client firing a server → client remote is rejected (`direction`).

A rejected call never reaches the handler. A rejected RemoteFunction returns nil. Every rejection goes to
AntiExploitService through `Net.onReject`. It logs the player, the count, the remote and the reason, at most once
every `Config/AntiExploit.rejectLogSeconds`. Rejections never kick on their own; kicks come from movement
offenses.

Passing the validator only means the payload has the right shape. The handler still checks ownership, position,
cash, slots, cooldowns and limits against the server's own copy of the player's data.

**Fuzzing.** `tests/NetFuzz.spec` checks every validator in Edit mode with random and hostile payloads (wrong
types, huge and empty strings, NUL bytes, NaN, infinity and `-0`, deep and over-long tables, extra keys).
`src/client/Dev/FuzzTests.luau` sends the same cases through the network in a playtest to every client → server
remote, plus extra arguments and bursts over the rate limit, with `DevFuzz` recording server errors and the
caller's economy around the run (it must show no errors and nothing changed).

**Who may call**, as used in the table:

- **anyone**: any player on the server.
- **owner**: only the owner of the thing named. The uid is looked up in the caller's own saved data, so another
  player's uid is simply "not found".
- **driver**: the caller must sit in the Driver seat of a car they own.
- **admin only**: the UserIds in `Config/Admins`. In Studio everyone counts as an admin while
  `Config/Designer.studioCountsAsAdmin` is on.
- **Studio only**: the handler refuses unless `RunService:IsStudio()` (CLAUDE.md hard rule 8).
- **server → client**: the client only listens.

**Keeping the table complete.** `scripts/check-security-table.ps1` (and `.sh`) is a build gate.
`scripts/check.ps1` and `check.sh` run it as "== security table". It fails when a remote in Net.luau's `REMOTES`
has no row below, or when a row names a remote Net.luau doesn't declare. The Phase 14 contract asked for a spec
(`tests/SecurityDoc.spec.luau`) instead. Specs run inside Studio, which can't read `docs/`, so this gate replaces
it.

## Remotes

Sizes are the caps in Net.luau: ids 40 bytes, uids 64, a design's catalog id 48, a date 10, plate text 16, a
design prompt 800 (the server then counts 200 characters), a report reason 40.

<!-- remotes:start -->
| Remote | Kind, direction | What the validator accepts | Rate limit (burst, per second) | Who may call | Abuse it prevents |
|---|---|---|---|---|---|
| `DevSpawnVehicle` | event, client → server | `{ vehicleId ≤ 48 bytes, trim ≤ 40 }` | 3, 0.5/s | Studio only (VehicleService ignores it elsewhere) | Spawning any car, unreleased or someone else's design, on a live server |
| `VehicleReset` | event, server → client | nothing from clients | none (server only) | server → client (the driver) | A client faking "your car was reset" (rejected and logged) |
| `RedeemCode` | function, client → server | the code as typed: a string ≤ 32 bytes | 3, 0.2/s | anyone | Guessing codes by brute force. Redeeming a code twice or after it expires (one save update applies it and marks it used) |
| `Notify` | event, server → client | nothing from clients | none (server only) | server → client (one player) | Clients sending toasts to other players |
| `BuyVehicle` | function, client → server | `{ vehicleId ≤ 40, trim ≤ 40 }` | 3, 0.5/s | anyone | Buying at a made-up price, without the cash, past the garage limit, or a trim that isn't for sale. The price comes from Config, and the charge re-checks the balance inside the save update, so two buys at once can't both pass |
| `UpgradeVehicle` | function, client → server | `{ uid ≤ 64, trim ≤ 40 }` | 3, 0.5/s | owner | Upgrading someone else's car or skipping the price difference |
| `StartTestDrive` | function, client → server | `{ vehicleId ≤ 40, trim ≤ 40 }` | 2, 0.2/s | anyone standing by that car's display car at the dealership | Free cars: dealership trims only, one test drive at a time, with a cooldown |
| `ClaimStarter` | function, client → server | nothing | 2, 0.2/s | anyone | Claiming the free starter car more than once (`starterClaimed`) |
| `GetUsedLot` | function, client → server | nothing | 4, 1/s | anyone (read only) | Flooding the DataStore with reads |
| `BuyUsed` | function, client → server | `{ slot: whole 1..64, date ≤ 10, maxPrice: whole 0..100,000,000 }` | 3, 0.5/s | anyone | Selling past the global daily supply (atomic UpdateAsync). Charging more than the confirm showed (stale day or higher price is refused, never charged) |
| `SpawnOwned` | function, client → server | `{ uid ≤ 64 }` | 3, 0.5/s | owner | Spawning a car you don't own |
| `DespawnOwned` | function, client → server | nothing | 3, 0.5/s | the caller's own car only | Despawning other players' cars |
| `SellVehicle` | function, client → server | `{ uid ≤ 64 }` | 3, 0.5/s | owner | Selling someone else's car, or one car twice (removal and payout in one save update) |
| `SetFavorite` | event, client → server | `{ uid ≤ 64, favorite: boolean }` | 6, 2/s | owner | Editing other garages. Save spam |
| `UpdateSettings` | event, client → server | `{ units? "mph" or "kph", camera? "chase", "orbit" or "hood", musicVolume? 0..1 }` | 6, 2/s | the caller's own settings | Junk values in the save. Save spam |
| `ProfileSnapshot` | event, server → client | nothing from clients | none (server only) | server → client (the player's own data) | Clients pushing a fake profile to anyone (rejected and logged) |
| `EnergyAlert` | event, server → client | nothing from clients | none (server only) | server → client (the driver) | Clients faking energy alerts |
| `JobAction` | function, client → server | `{ action: "accept", "arrive", "cancel" or "refresh", offerId? ≤ 40, jobId? ≤ 64 }` | 4, 1/s | the caller's own offers and job | Faked arrivals: the server judges the car's position, and an "arrive" far from the stop is rejected and logged. Pay for jobs never driven. Re-rolling offers (`minRefreshSec`) |
| `JobUpdate` | event, server → client | nothing from clients | none (server only) | server → client (the player) | Clients faking job state |
| `BuyCustomization` | function, client → server | `{ uid ≤ 64, changes }`. `changes` takes only known fields: paint, finish, wrap, wheels, caliper and plate-format ids ≤ 40; `customColor { h, s, v }` each 0..1; rideHeight −1..1; tint 0..1; up to 8 extras ids | 3, 0.5/s | owner, driving it inside the Wrap & Tint shop | Free or locked looks: every value is checked against Config/Customization and priced by the server. Changing someone else's car |
| `SetPlate` | function, client → server | `{ uid ≤ 64, text ≤ 16 bytes, "" allowed (clears the plate) }` | 2, 0.2/s | owner, driving it in the shop. Custom text needs the Custom Plates pass | Unfiltered or offensive plates (TextService filter, Config length and characters). Custom text without the pass |
| `JoinLightShow` | function, client → server | `{ meetSpotId ≤ 40 }` | 3, 0.5/s | driver, parked and still in that meet spot | Starting shows from anywhere. Show spam (start cooldown, spot rest time). Pro routines without the pass |
| `LeaveLightShow` | function, client → server | nothing | 3, 0.5/s | anyone (their own car or screen) | Nothing beyond spam (it only affects the caller) |
| `LightShowStart` | event, server → client | nothing from clients | none (server only) | server → client (players near the meet spot) | Clients starting shows on other screens |
| `LightShowEnd` | event, server → client | nothing from clients | none (server only) | server → client (players near the meet spot) | Clients ending shows on other screens |
| `TrailerAction` | function, client → server | `{ action: "couple" or "decouple" }` | 3, 0.5/s | driver. Another player's job trailer is theirs alone | Hitching someone else's job load. Hitching at speed or from far away. Dropping a load anywhere to finish a job (decoupling only at a drop) |
| `BuyLicense` | function, client → server | `{ license: "freight" }` | 2, 0.2/s | anyone | A license without its price |
| `BuyPod` | function, client → server | `{ zone ≤ 40 }` | 3, 0.5/s | anyone (their own fleet) | Pods past the slot limit or without the cash |
| `AssignPod` | function, client → server | `{ uid ≤ 64, zone ≤ 40 }` | 4, 1/s | owner of the pod | Moving others' pods. Gaming earnings by moving pods (earnings are counted up to now first) |
| `CollectFleet` | function, client → server | nothing | 2, 0.5/s | the caller's own fleet | Collecting more often than the cooldown, or twice |
| `SellPod` | function, client → server | `{ uid ≤ 64 }` | 3, 0.5/s | owner of the pod | Selling someone else's pod, or one pod twice (one save update) |
| `HailPod` | function, client → server | `{ destinationId ≤ 40 }` | 2, 0.2/s | anyone, alive and on foot, not on a job | Free fast travel: the fare is charged, and refunded only when the ride fails. Teleporting anywhere: only GPS destinations, and the server picks the drop-off |
| `TrafficRoutes` | event, server → client | nothing from clients | none (server only) | server → client (everyone) | Clients faking traffic routes |
| `HailRide` | event, server → client | nothing from clients | none (server only) | server → client (the rider) | Clients faking a ride |
| `UseAbility` | function, client → server | `{ ability: "boostHop" or "flight" }` | 3, 1/s | driver of a car whose trim has the ability | Flying outside flight zones or in no-fly zones. Skipping cooldowns. Using an ability the car lacks. The server watches the motion, and out of bounds is an anti-exploit strike |
| `DragStripUpdate` | event, server → client | nothing from clients | none (server only) | server → client (the driver) | Clients faking drag times |
| `GetDragLeaderboard` | function, client → server | nothing | 3, 0.5/s | anyone (read only) | DataStore read floods (reads are cached) |
| `DesignCar` | function, client → server | `{ prompt ≤ 800 bytes, classId? ≤ 40 }` | 2, 0.1/s | anyone. Credits are reserved first; the first car is free | Free designs. AI cost floods: one request at a time per player, plus the backend's limits and spend cap. Unfiltered text reaching the AI or other players (TextService before sending and before showing) |
| `ModCar` | function, client → server | `{ uid ≤ 64, prompt ≤ 800 bytes }` | 2, 0.1/s | owner | Modding someone else's car. The same as DesignCar |
| `DesignResult` | event, server → client | nothing from clients | none (server only) | server → client (the requester) | Clients pushing fake designs |
| `DesignChoice` | function, client → server | `{ requestId ≤ 64, choice: "build", "reroll" or "discard" }` | 3, 0.5/s | the player whose design is waiting (the requestId must match theirs) | Building another player's design. Re-rolling past the free one: re-rolls are only ever free and never sold (`noReroll`; docs/COMPLIANCE.md section 2) |
| `ReportDesign` | function, client → server | `{ uid ≤ 64, reason ≤ 40 }` | 2, 0.1/s | anyone | Report spam: once per car per player, a cap per session, known reasons only |
| `HideDesign` | function, client → server | `{ designUid ≤ 64 }` | 3, 0.5/s | admin only | Players hiding other players' designs |
| `DevCredits` | function, client → server | `{ amount: whole 0..10,000 }` | 3, 1/s | Studio only | Free Design Credits on a live server |
| `BuyProduct` | function, client → server | `{ key ≤ 40 }` | 3, 0.5/s | anyone | Getting a product without paying. The client only gets Roblox's purchase prompt, and grants come only from the idempotent ProcessReceipt. Products with id 0 answer "coming soon" |
| `BuyPass` | function, client → server | `{ key ≤ 40 }` | 3, 0.5/s | anyone | The same: a prompt only. Ownership comes from MarketplaceService |
| `JoinClub` | function, client → server | nothing | 2, 0.2/s | anyone | Club perks without a paid subscription cycle |
| `GetStore` | function, client → server | nothing | 3, 0.5/s | anyone (read only) | Price lookup floods (prices are cached) |
| `StoreUpdate` | event, server → client | nothing from clients | none (server only) | server → client (the player) | Clients faking ownership on screen |
| `BuyLimited` | function, client → server | `{ dropId ≤ 40 }` | 2, 0.5/s | anyone | Buying past the supply, outside the drop window, or two serials for one payment. The serial claim is atomic, and `pendingGrants` finishes or refunds an interrupted buy |
| `ClaimStreak` | function, client → server | nothing | 2, 0.2/s | anyone | Claiming twice in one UTC day |
| `ClaimSeasonReward` | function, client → server | `{ tier: whole 1..60, track: "free" or "premium" }` | 4, 1/s | anyone. The premium track needs the Season Pass | Claiming unreached tiers, claiming twice, premium rewards without the pass |
| `WatchAdReward` | function, client → server | nothing | 2, 0.1/s | anyone, while the `rewardedAds` flag is on | More than one ad credit a day. Credits without an ad: the credit comes only from Roblox's reward receipt |
| `EventUpdate` | event, server → client | nothing from clients | none (server only) | server → client (everyone) | Clients faking live events |
| `AdminAction` | function, client → server | `{ action: "kick", "despawn", "logs" or "hideDesign", targetUserId?: whole 1..2^53, ref? ≤ 64 }` | 5, 1/s | admin only. No kicking yourself or another admin | Players kicking others, despawning their cars or reading the logs |
| `DevPurchase` | function, client → server | `{ key ≤ 40, purchaseId? ≤ 64 }` | 5, 2/s | Studio only | Free purchases on a live server |
| `ClaimHouse` | function, client → server | `{ plotId ≤ 40 }` | 3, 0.5/s | anyone standing within reach of the plot's sign | Claiming from across the map. A second plot, or someone else's. Walls appearing over cars or players |
| `LeaveHouse` | function, client → server | nothing | 2, 0.5/s | the caller's own plot | Nothing beyond spam (it only releases the caller's plot) |
| `BuyHouseUpgrade` | function, client → server | `{ upgrade ≤ 40 }` | 3, 0.5/s | anyone (their own upgrades) | Free upgrades. Paying for one twice |
| `HouseUpdate` | event, server → client | nothing from clients | none (server only) | server → client (the owner) | Clients faking house state |
| `FeedUpdate` | event, server → client | nothing from clients | none (server only) | server → client (everyone) | Clients posting to everyone's feed |
| `DevSocial` | function, client → server | `{ action: "parkDummyCar" or "clearDummies", meetSpotId? ≤ 40 }` | 6, 3/s | Studio only | Fake meets and meet announcements on a live server |
| `DevAbility` | function, client → server | `{ action: "resetCooldowns" }` | 5, 2/s | Studio only | Skipping ability cooldowns on a live server |
| `DevFleet` | function, client → server | `{ action: "simulateOffline", hours 0..24 }` | 3, 1/s | Studio only | Free offline fleet earnings |
| `DevJob` | function, client → server | `{ action: "teleportToStop" or "grantLicenseXp" }` | 3, 1/s | Studio only | Teleporting to job stops. Free license XP |
| `DevSetEnergy` | function, client → server | `{ level 0..1 }` | 3, 1/s | Studio only | Free energy |
| `DevSetCash` | function, client → server | `{ amount: whole 0..100,000,000 }` | 3, 1/s | Studio only | Free cash |
| `DevFuzz` | function, client → server | `{ action: "begin" or "finish" }` | 4, 1/s | Studio only: `Services/DevFuzzService` answers `{ ok = false }` and warns outside Studio. In Studio it records the server's error and warning lines, Net rejections and an economy snapshot for the caller between begin and finish; it never writes data | Reading server errors and save changes on a live server |
| `DevPerf` | function, client → server | `{ action: "start" or "stop" }` | 4, 1/s | Studio only: `Services/DevPerfService` answers `{ ok = false }` and warns outside Studio; its sampler stops itself after Config/Perf `dev.maxSampleSeconds` (900 s) and when the player who started it leaves | Sampling the server's frame times on a live server |
| `CarSignal` | event, client → server | `{ action: "hornOn", "hornOff", "headlights", "indicatorLeft", "indicatorRight" or "hazards" }` | 8, 4/s | only the driver of the car (VehicleService checks the caller sits in that car's driver seat); sets attributes on the car that every client reads | Honking or flashing lights on someone else's car; horn spam past the rate limit |
| `GoalsUpdate` | event, server → client | nothing from clients | none (server only) | server → client (the player) | A client faking finished goals (rejected and logged) |
| `ClaimGoal` | function, client → server | `{ goalId ≤ 40 bytes }` | 4, 2/s | the player, for their own goal; the server checks the goal is finished and not yet claimed | Claiming a goal's reward twice or before it is done |
<!-- remotes:end -->

Server → client remotes are declared with `Check.none()` and a limit of 0, 0. They carry no client data. A client
firing one is rejected as `direction` and logged.

## Backend endpoints

The AI Car Designer backend (`backend/`, on Vercel). Only the game server calls it. The game sends only:

- the filtered description;
- the class, or for a mod the car's class and its current spec or look;
- a salted hash of the UserId (never a username, raw UserId or chat);
- the kit version.

| Endpoint | Method | Auth | Validation | Limits | Abuse it prevents |
|---|---|---|---|---|---|
| `/api/design` | POST. Any other method gets 405 | Header `x-api-key` must equal `ROBLOX_SHARED_SECRET`, or `ROBLOX_SHARED_SECRET_PREVIOUS` during a rotation. Compared in constant time on SHA-256 digests. No secret set: 503. Wrong or missing key: 401 | Body ≤ 16 KB (413) and valid JSON (400). zod shape: `kitVersion` must equal the backend's kit (409); `userHash` 16–128 URL-safe characters; `prompt` ≤ 200 characters with at least 8 letters or digits left after cleaning; `classId` a kit class or null. Blocked descriptions (by prompt hash) are refused before the cache or Claude. Claude's answer is validated and clamped against the kit and scanned for real brand names (one stricter retry). Cached answers are re-checked | From `vc_designer_settings`: the on/off switch, 10 per player per hour and 40 per 24 hours, 1200 per hour for everyone, and the daily spend cap ($5, UTC day). Time: 25 s per request, 12 s per Claude call, 4096 output tokens | Anyone but the game calling it and spending money. Runaway cost. Real brands or unsafe text reaching players. Oversized requests. A game and backend on different kits |
| `/api/mod` | POST. Any other method gets 405 | The same | As `/api/design`, plus `kind` ("kit" or "catalog"), `classId`, and `current` ≤ 2048 bytes of canonical JSON | The same (one pool shared with designs) | The same |

Every answer that isn't `{ ok: true, spec }` makes the game refund the player's credits. That includes 429 (the
switch, a limit or the spend cap) and every 4xx and 5xx (`DesignerService.interpretResponse`, CLAUDE.md hard rule
11).

The backend's log lines never contain a key, a prompt or a player hash. The usage table keeps the filtered prompt
and the salted hash, so Davis can block a description (backend/README.md), for 90 days: the backend deletes older
rows itself (`USAGE_RETENTION_DAYS`, `backend/tests/retention.test.ts`).

## Rotating the game password

The "game password" is the shared secret. It proves a request comes from the game. It lives in two places, and
the two must match:

- on Vercel, as `ROBLOX_SHARED_SECRET`;
- in the experience's Secrets store, as `designer_key` (the game reads it with `HttpService:GetSecret`).

A copy for the setup tool's Copy button is kept at `%USERPROFILE%\.voltage-county\designer_shared_secret`.

Change it if it might have leaked (pasted somewhere public, seen on a screen share), and once before going public
(`docs/LAUNCH.md` step 11). Nothing stops working along the way. Each game server reads the password once and keeps
it until it closes, so the backend accepts the old password as well (`ROBLOX_SHARED_SECRET_PREVIOUS`) until the old
servers are gone.

**Rotation support is live** (`backend/lib/handler.ts`, deployed to production 2026-10-21). A Vercel "Redeploy" of
a deployment older than that would rebuild the old code, which ignores the previous password, so always deploy the
current code (the setup tool's buttons do).

The setup tool (`tools\open_designer_setup.bat`) does the Vercel side in two clicks:

1. **One click: Change game password** (setup tool button; or Claude does the same from the terminal). It keeps the current password working as
   `ROBLOX_SHARED_SECRET_PREVIOUS`, saves a new random one as `ROBLOX_SHARED_SECRET` and in the
   `designer_shared_secret` file, and redeploys (about a minute). Both passwords work after that. Clicking it again
   before step 5 only retries, with the same two passwords.
2. **Only you: tell Roblox.** Click **Copy game password**, then **Open Roblox secrets**. Edit `designer_key`, paste
   the new password, keep the domain `voltage-county-designer.vercel.app`, and save.
3. **Only you: tell Studio.** In Studio, open **File > Experience Settings > Security**, **Local Secrets**. Replace
   the password in the `designer_key` line.
4. **Only you: restart the game servers.** In the Creator Dashboard, use the experience's **Restart Servers for
   Updates**. Players move to fresh servers, which read the new password. You can skip this and wait a day instead.
5. **One click: Finish change** (setup tool button; or Claude, who first checks Vercel's logs: the line "a request
   used ROBLOX_SHARED_SECRET_PREVIOUS" should have stopped appearing). It removes `ROBLOX_SHARED_SECRET_PREVIOUS`
   and redeploys. Only the new password works now.
6. **Try it.** Design a car in the game. If every request says the design studio isn't set up yet, or gives the
   credits back, the Roblox secret and Vercel don't match: redo step 2.

Without the setup tool (by hand in Vercel, project **voltage-county-designer**, **Settings > Environment
Variables**, Production): add `ROBLOX_SHARED_SECRET_PREVIOUS` with the current password (from the
`designer_shared_secret` file), set `ROBLOX_SHARED_SECRET` to a new one (in PowerShell:
`$b = New-Object byte[] 32; [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b); -join ($b | % { $_.ToString('x2') })`),
put the new one in the file too, and deploy the current code with `vercel --prod --yes --scope spacemutters-projects`
from `backend/`. Then steps 2 to 4; then delete `ROBLOX_SHARED_SECRET_PREVIOUS` and deploy again. Never put a
password in the repo or a chat.

## Backend review (Phase 14)

Done on 2026-10-21 on branch `phase-14`.

**Secrets in the repo. Nothing found.**

- *What was scanned.* The working tree, and the full history (`git log -p --all`, all 39 commits) for:
  - Anthropic keys and other API keys;
  - Supabase secret and publishable keys;
  - JWTs (service-role keys);
  - private key blocks;
  - GitHub, Vercel and AWS tokens;
  - 64-character hex strings shaped like the shared secret;
  - any value assigned to `ROBLOX_SHARED_SECRET`, `SUPABASE_SERVICE_ROLE_KEY`, `ANTHROPIC_API_KEY` or
    `designer_key`;
  - any `.env` or `.vercel` file ever added.
- *What came back.* The only hits are the published SHA-256 test vectors in `tests/Sha256.spec.luau` (the
  standard digests of "abc" and similar). They are not secrets. No `.env` or `.vercel` file was ever committed.
- *Ignore rules.* The root `.gitignore` covers `.env*` and `.vercel/`. `backend/.gitignore` covers `.env*`,
  `.vercel/` and `.vercel`.
- *Where the secrets are.* The four Vercel environment variables, the Roblox Secrets store, and Davis's laptop
  under `%USERPROFILE%\.voltage-county\`, outside the repo.
- *Not secret.* The Supabase project address in `tools/designer_setup.pyw` and the experience id are not secrets.
  Reading or writing the tables needs the service-role key.

**Shared secret. Rotation added (fixed; live in production since 2026-10-21).**

- *Before.* The backend compared the key in constant time (SHA-256 digests and `timingSafeEqual`), but accepted
  only one value. Changing it meant downtime until every game server restarted.
- *Now.* It also accepts `ROBLOX_SHARED_SECRET_PREVIOUS`, if that is set:
  - both are always compared, in constant time, whether or not a previous value is set;
  - a blank previous value is ignored;
  - the previous value alone never opens the door;
  - a request that used it is logged (without the key), so the old value can be retired when those lines stop.
- *Tests.* `backend/tests/rotation.test.ts`. The steps are under "Rotating the game password" above; the setup
  tool's **Change game password** and **Finish change** buttons do the Vercel side.
- *Not done yet.* The rotation itself needs the Roblox Secrets store, so its two pastes are Davis's
  (`docs/LAUNCH.md` step 11, before going public). The plan's "shared secret rotated" is done only then.

**Limits and the spend cap. Verified; new tests.** `backend/tests/spend.test.ts` runs these on the in-memory
store with the clock moving:

- the per-player daily limit fills over the day and frees up 24 hours after the first request;
- the spend cap stops everyone once today's spend reaches it, even cached designs and mods, until midnight UTC;
- a stopped request answers 429 `{ ok: false }`, which the game refunds, and is neither logged nor sent to
  Claude;
- cache hits cost $0 and never move the cap, but they do count toward a player's request limits;
- tokens spent on a safety refusal or a brand-name retry count toward the cap.

Two known limits, accepted:

- **The cap can be passed slightly.** It is checked before each call, so requests already in flight when it is
  reached still finish. That is about $0.00025 per typical request (at most about $0.005 at the token ceiling)
  per request in flight.
- **Two requests at once can both pass a player limit.** The same check-before-call gap applies. The game sends
  one request at a time per player, and Net limits DesignCar and ModCar to 2 at once, then one every 10 s.

The live settings (read on 2026-10-21): switched on, $5.00 a day, 10 per player per hour, 40 per player per day,
1200 an hour for everyone, and no requests logged yet. Supabase stores the cap in whole cents.

**Supabase. Locked to the service role.** Project `cfgqkyouedwidwoivnpw` is shared with
other apps, so the designer's objects carry the `vc_` prefix. Checked read-only:

- *Tables.* `vc_designer_settings`, `vc_designer_usage`, `vc_designs` and `vc_designer_blocklist` all have row
  level security on, with no policies. `anon` and `authenticated` have no rights on them (select, insert, update,
  delete, truncate, references, trigger). `service_role` does.
- *The stats function.* `vc_designer_usage_stats` is SECURITY INVOKER with a fixed `search_path`. Only
  `service_role` may run it.
- *Advisors.* The security advisors flag only "RLS enabled, no policy" (INFO) on the four tables. That is
  intended: only the backend, with the service-role key, may touch them.
- *Found.* The two id sequences (`vc_designer_usage_id_seq`, `vc_designs_id_seq`) still let `anon` and
  `authenticated` use them, from the project's default grants. No row can be read or written that way, but it
  is wider than needed.
- *The fix.* `backend/supabase/migrations/0002_vc_sequence_privileges.sql` takes it away. Applied 2026-10-21;
  read back the same day: `anon` and `authenticated` have no use of either sequence, `service_role` does.
- *Not ours.* The advisors' other warnings are about other apps in the same project and are left alone here.
