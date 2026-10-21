# Phase 12 contracts

Monetization, credit sales, limited drops, live-ops (PLAN.md "Phase 12" is the spec; PLAN.md §4 and §11 hold the
numbers). Read `CLAUDE.md` (hard rule 6 above all) and the earlier contracts (`docs/phase-1..11-contracts.md`).

## Ground rules for every helper
- Every pass, product and subscription id lives in `Config/Monetization` and starts at `0` / `""`: **0 means not
  created yet and must no-op safely** (no Marketplace call, the button hidden or "coming soon", nothing granted).
  Davis creates them in the Creator Dashboard and pastes the ids.
- **No Robux price is ever written in code or config.** Prices shown come from
  `MarketplaceService:GetProductInfoAsync` / `GetDeveloperProductsAsync` / subscription info (cached), so Managed
  Pricing can change them. A spec greps the source for hard-coded Robux amounts.
- No paid random items. Credits buy looks, never progression.
- `ProcessReceipt` is idempotent: record the `PurchaseId` in `receipts` (keep the last 100) in the same profile
  update that grants, before returning `PurchaseGranted`.
- Everything time-based takes an injectable clock so specs can use a fake one.

## Monetization core (owner: monetization helper)
- `Config/Monetization.luau`: `passes = { vip, fleetManager, garagePlus, lightShowPro, customPlates, seasonPass }`,
  `products = { credits5, credits15, credits40, starterPack, customSlot, cash1, cash2, cash3, cash4 }` plus the
  limited-cosmetic products (added by the liveops helper through `Config/Limiteds`), `subscriptions = { club = "" }`,
  and what each grants (credits per pack with bonus, cash per pack, perks per pass) — grants are config, prices are
  not.
- `src/server/Services/MonetizationService.luau`: `ProcessReceipt` (dispatch by product key; credit packs →
  `CreditsService.grant`; Starter Pack once, `offersSeen`; custom slot; cash packs), `hasPass(player, key)` (cached
  `UserOwnsGamePassAsync`, refreshed on `PromptGamePassPurchaseFinished`), `onPassChanged(key, listener)`, and the
  pass effects wired where they live: VIP +20 % job pay (JobService's VIP hook), Fleet Manager (FleetService already
  calls `MonetizationService.hasPass` when it exists), Garage+ (+10 garage, +2 custom slots), Custom Plates
  (CustomizationService's gate), Light Show Pro.
- **Voltage Club** (§11): `PromptSubscriptionPurchase`; status on join and on `Players.UserSubscriptionStatusChanged`;
  the monthly credits once per billing month (tracked in `club.lastGrantMonth`); perks off when it lapses.
- Net (declared by the lead): `BuyProduct { key }`, `BuyPass { key }`, `JoinClub`, `GetStore` (→ prices and what each
  item grants, from MarketplaceService, cached), `StoreUpdate` (server → client after a purchase).
- Specs: the same receipt 3× grants once (credit packs included); Club credits once per billing month across
  rejoins and stop after it lapses; the Starter Pack once and the offer never again; ids of 0 no-op.

## Store UI (owner: store-ui helper)
Credit store (pack cards with MarketplaceService prices, what one credit buys, your balance), wiring the Phase 11
"Out of credits" sheet to it; a passes page; the Starter Pack offer sheet (shown after the first free design and the
first job payout, never after it's bought); the Voltage Club card; private servers with the "Plus members get free
private servers" prompt (`PromptRobloxSubscriptionPurchase`); daily streak rewards UI and an "Invite your crew"
button (Share Links / `SocialService:PromptGameInvite`); event banners and countdowns. Mobile-first, the phone's
kit, every price from the server's `GetStore`.

## Live-ops (owner: liveops helper)
- **Limited drops** (`Config/Limiteds`): vehicle/trim, UTC window, supply, in-game price; serials assigned atomically
  with DataStore `UpdateAsync` on a per-drop key; a failed profile grant leaves a `pendingGrants` entry retried on
  the next join; Arc Flight ships only this way. **Limited cosmetics for Robux**: serial-numbered wraps and plate
  frames sold in a fixed window (never random). Spec with a mock store: 200 concurrent attempts on a supply of 50
  sell exactly 50 serials, 1–50, no duplicates.
- **Events** (`Config/Events`): UTC schedule, banners, featured dealership pad, earnings multipliers (through
  EconomyService's boost path), bonus-credit weekends, countdowns; switch on without a restart (re-read on a slow
  timer); spec under a fake clock.
- **Live feature flags**: `Config/FeatureFlags` defaults overridden by a DataStore key read every 60 s
  (`FeatureFlagService.isOn(name)`); the designer, ads, drops and events each check theirs.
- **Season Pass v1** (`Config/Season`, `SeasonService`): 30 tiers, free and premium tracks, XP from driving and
  jobs, claim rewards, premium via the season pass, 6–8 weeks.
- **Login streak**: daily rewards (cash, an occasional credit) in `streak`.

## Ads, analytics, admin (owner: ops helper)
- **Highway billboards** (`AdsService`): AdGui units along the County Loop and at the charging plaza (new
  `Billboard` locations in `Config/MapLayout`, built by `Dev/MapBuilder`), sized within Roblox's limits, with
  in-game brand posters when no ad is served. **Rewarded video**: code ready, switched off by flag, offered only
  when `AdService:GetAdAvailabilityNowAsync` says an ad can show ("watch an ad for 1 credit a day"). Check both APIs
  on the Roblox docs before relying on names.
- **Analytics** (`AnalyticsService`, verify the current API): the onboarding, designer and revenue funnels,
  economy sources/sinks, job progression, ability and light-show use (PLAN.md list).
- **Admin tools** (`Config/Admins`): kick, despawn a vehicle, view recent logs, hide a design or mod; grants of cash
  and credits only in Studio.
- `docs/DROP_TEMPLATE.md`: the ship-a-new-trim-in-a-day checklist.

## Net (declared by the lead before the build)
`BuyProduct { key }`, `BuyPass { key }`, `JoinClub`, `GetStore` (functions; the store's prices come from
MarketplaceService), `StoreUpdate` (server → client), `BuyLimited { dropId }`, `ClaimStreak`,
`ClaimSeasonReward { tier, track }`, `WatchAdReward` (off by flag), `EventUpdate` (server → all clients),
`AdminAction { action, targetUserId?, ref? }` (admins only), and Studio-only `DevPurchase { key, purchaseId? }`, which
runs the real ProcessReceipt path with a made-up PurchaseId so the store can be tested before any product exists.
