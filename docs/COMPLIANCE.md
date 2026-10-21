# Compliance pass (Phase 14)

Checked on 2026-10-21 against the code on branch `phase-14` and Roblox's pages as published that week (sources at
the end). Each check has the evidence (file:line) and a verdict:

- **passes**: the code already does it.
- **fixed**: changed in this pass (user-facing words in `src/client/UI` only).
- **needs the fixer**: a change outside the UI is listed under "For the fixer" at the end, with the exact change.
- **needs Davis**: something only the owner can do; it is a step in `docs/LAUNCH.md`.

This is a reading of Roblox's and the AI provider's published rules, not legal advice.

**Fixer pass (2026-10-21).** Every "needs the fixer" item below is now done in the repo (status under "For the
fixer" at the end). Section 2's row on AI designs was wrong: a redesign skips the design service's cache and can
change the stats, so a paid redesign would have been a paid draw. Paid redesigns are gone (section 2, "Decision").
Two things are written but not live until the lead ships them: the design service update (the 90-day cleanup, the
hosted privacy page) and the next game publish (the new AI notice and messages).

## Summary

| # | Check | Verdict | What's left |
|---|---|---|---|
| 1 | Player and AI text other players can see goes through Roblox's filter | passes | one live check in the private beta (players whose Roblox chat is off) |
| 2 | No paid random items | passes, fixed | redesigns are free only and never sold; one call for Davis: the free redesign that comes with a paid design |
| 3 | No links or pointers to buying anything outside Roblox | passes | none |
| 4 | Audio only from Roblox's licensed library or Davis's own tracks | passes | every id is 0 (silent); a Studio check for sounds in Studio-owned parts |
| 5 | The store and the designer show what a credit buys before purchase | passes | none |
| 6 | The AI notice shows before the first design request | passes, fixed | none (in the game from the next publish) |
| 7 | Paid AI generation fits Roblox's rules | allowed, on conditions | questionnaire answers (Davis, LAUNCH step 4); the 90-day cleanup is live (deployed 2026-10-21) |
| 8 | Privacy: what is kept, for how long, and deletion requests | fixed, needs Davis | the 90-day cleanup and the hosted page are live (2026-10-21); the deletion templates (Davis, LAUNCH step 7) |

## 1. Text other players can see

Roblox: "you are responsible for filtering any displayed text that you don't have explicit control over", including
text typed by players, text fetched from an external web server and text loaded back from data stores. The method
for text everyone sees is `TextService:FilterStringAsync` then `GetNonChatStringForBroadcastAsync` (Text filtering
page). That is what the game uses.

| Text | Written by | Evidence | Verdict |
|---|---|---|---|
| Custom plate | player | Sent as `SetPlate` (`src/shared/Net.luau:244`). Filtered for everyone (`src/server/Services/CustomizationService.luau:424-434`); text the filter changes is refused when it is set (`:639`); filtered again every time the car comes out, blank until the filter answers (`:484-497`); the raw text never leaves the server (`:32-37`, `src/server/Services/ProfileSyncService.luau:5-7`). | passes |
| Design and mod description | player | Never shown to anyone else. Filtered before it leaves Roblox and refused when too little survives (`src/server/Services/DesignerService/init.luau`, `filterPrompt` and `filterAs`). | passes |
| Design name and tagline | AI | Brand check, then filtered; a name the filter changes becomes "Custom &lt;class&gt;", a changed tagline is dropped (`DesignerService/init.luau`, `designPipeline`). | passes |
| Mod summary | AI | Brand check, filtered, replaced by "Mod applied" if changed (`DesignerService/init.luau`, `modPipeline`). | passes |
| Refusal message | AI | Shown only to the player who asked; still brand-checked and filtered, else the plain refusal (`DesignerService/init.luau`, `shownRefusal`). | passes |
| Saved AI text | AI | Checked again on every join, before the design is published to other players (`DesignerService/init.luau`, `recheckSavedText`). | passes |
| Generated body prompt | AI | Never shown; sent only to Roblox's own GenerationService, which moderates its inputs and outputs (`src/shared/Vehicle/GeneratedAdapter.luau`: the header's prompt note and `GeneratedAdapter.generate`); brand-checked first (`DesignerService/init.luau`, `designPipeline`). | passes |
| Chat | player | Roblox's own TextChatService with its defaults; nothing custom sends or rewrites messages (`src/server/Services/SocialSetupService.luau:8-12`). The VIP tag is fixed text from config (`src/shared/Config/Monetization.luau:268-271`). | passes |
| Nametag titles | config | Job titles from Config/Jobs, never from a player (`SocialSetupService.luau:4-7`). | passes |
| Feed entries | config | Config words plus a car count (`src/server/Services/MeetService.luau:200-201`). | passes |
| Drag strip board | Roblox | Roblox display names, already moderated by Roblox (`src/server/Services/DragStripService.luau:40`). | passes |
| Event names and banners | Davis | Config/Events plus the LiveOps DataStore key, which only Davis writes (`src/server/Services/EventService.luau:2-4`). Developer text he controls. Never paste anything there from a player. | passes |
| Report reasons, codes | player | Reasons are fixed ids from config; codes are never shown to others (`Net.luau:75`). | passes |

Open risk (needs a live check): Roblox's pages don't say how the filter treats players whose Roblox chat is off
(chat now needs an age check). If their text comes back as all `#`, the designer refuses them with "Not enough of
that description could be used" (no charge) and their plates stay blank, but they could still buy credits they
can't use. `docs/LAUNCH.md` step 12 has a friend without the age check try it. If it fails, the fixer should
tell those players before they buy credits (see "For the fixer", item 6).

Note on Roblox's generative AI page: its example says AI "text inputs and outputs must go through TextChatService".
That example is about chatting with an AI. Nothing here is chat; the names, taglines and summaries are signs-style
text, which the Text filtering page says to filter with `FilterStringAsync` and `GetNonChatStringForBroadcastAsync`.

## 2. No paid random items

Roblox counts anything bought directly or indirectly with Robux (including a currency bought with Robux) whose
outcome is random, including "re-roll tokens"; such items need every outcome's odds shown before purchase
(Paid random items page; Creator Terms "Random Virtual Items"). Every paid path:

| Paid path | Evidence | Verdict |
|---|---|---|
| Credit packs, cash packs, custom slot, Starter Pack | Fixed grants (`src/shared/Config/Monetization.luau:125-135`); "Nothing sold here is random" (`:11-13`). | passes |
| Passes | Fixed perks; a perk line goes in only once the feature ships (`Monetization.luau:161-200`). | passes |
| Voltage Club | Fixed monthly credits, slots and wrap (`Monetization.luau:211-228`). | passes |
| Season Pass | One fixed reward per tier (`src/shared/Config/Season.luau`). | passes |
| Limited drops and limited cosmetics | The next serial number, never random (`src/shared/Config/Limiteds.luau:1-11`, `src/server/Services/LimitedService.luau:32`). | passes |
| Rewarded video | 1 credit, once a day; "Rewards may never be random" (`src/shared/Config/Ads.luau:16, 136`). | passes |
| Daily streak | Free, and fixed anyway: cash daily, a credit on day 7 (`Season.luau:119-128`). | passes |
| Robotaxi pods (bought with in-game cash) | A known item; its earnings vary a little each hour around the rate the phone shows (`src/server/Services/FleetService/Earnings.luau:6-9`, `src/client/UI/Phone/FleetApp.luau:11-13`). Income from something you own, not an item draw. | passes |
| AI designs and mods (credits) | The player describes the car and picks the class (or lets the AI pick it from the words). A paid design or mod always goes through the design service's cache: the same words and class give the same car (`backend/lib/handler.ts`, `getCached` / `putCached`, keyed by description and class; `backend/supabase/migrations/0001_designer.sql`, `vc_designs`). A redesign skips that cache (`reroll`, `handler.ts`) and is a fresh answer from the AI, which also picks the personality, and the personality sets the stats inside the class band (`src/shared/Vehicle/SpecBuilder.luau`, `stats`; `DesignKit.json` personalities: "track" totals 2.75, "efficient" 1.85). So a redesign is a new draw for looks and stats. That is why it is never sold (Decision below). Stats never leave the class band (`DesignerService/init.luau`, `designPipeline`). No pool, no rarities. | passes, fixed |
| Paid item trading | None (trading is post-launch). | passes |

What was fixed in wording: two words made the designer read like a loot box. "Re-roll" is now "Redesign" and
"Surprise me" is now "AI picks", in the UI (`src/client/UI/Designer/DesignerStyle.luau`, `src/client/UI/Store/StoreStyle.luau`)
and in the server's messages (`src/shared/Config/Designer.luau`, `messages`: fixer item 2, done).

**Decision (option a, made by the fixer on 2026-10-21; the alternative was a paid redesign only with Roblox's
written OK).** Before this pass, once a design's free redesign was used, another redesign reserved 2 credits for a
fresh, uncached answer from the same words: a paid draw, which is what Roblox's policy calls a "re-roll token".
Renaming it didn't change how it worked. Now:

- a redesign is only ever free: `DesignChoice` "reroll" is refused as `noReroll` once the design's free one is used,
  and nothing is reserved (`DesignerService.canReroll`, `onDesignChoice`; the paid branch and its reservation are
  gone, `tests/Credits.spec` "Re-rolls");
- the result card shows **Free redesign** only while one is left. After that the note says "Want something else?
  Discard this one and change your words. A new design is 2 credits." (`DesignerStyle.luau` `changeWords`,
  `StudioSheet.result`). A new design from new words is the player's own new request; the same words again hit the
  cache and give the same car, so paying again can't buy a different draw.

**Davis's call: the free redesign that comes with a paid design.** A paid design comes with one free redesign
(`Config/Designer` `prices.rerollsPaid = 1`; the free first car comes with none, `rerollsFree = 0`). Roblox counts
anything got "directly or indirectly" with Robux, so that redesign is indirectly paid: for the same credits the
player gets a second draw from the same words and keeps the one they like. Two readings:

1. It is part of what the design buys, the store says so before purchase ("a brand-new car the AI designs for you,
   with a free redesign"), and there is no pool or rarity: keep it.
2. It is a bundled re-roll: set `prices.rerollsPaid = 0` (one line; the Redesign button then never shows, and the
   store line drops "with a free redesign"; `tests/Credits.spec` checks the 1 and changes with it).

Recommendation: 2 if there's any doubt. It costs players little (they can still change their words), and it takes
the question off the table with a young audience. Until Davis decides, 1 ships.

Tidy-up (fixer item 3, done): when "AI picks" comes back with a class the player can't design, the game server used
to pick one of the surprise classes at random. It now takes the first one in `kit.surpriseClasses` order the player
may design (`DesignerService.surpriseClass`). It couldn't fire anyway (every surprise class is designable without
owning one, and the design service already turns a stray class into a fixed one from the words:
`backend/lib/schema.ts`), but a paid path now has no dice in it at all.

## 3. No links or pointers to buying anything outside Roblox

A search of `src/` for `http`, `www.`, `.com`, `.gg`, `.io`, `.dev`, `.app`, discord, patreon, paypal, venmo,
cash app, twitter, youtube, tiktok, instagram, guilded, ko-fi, website and merch finds:

- `src/shared/Config/Designer.luau:27`: the design service's address. A server-to-server address that needs the
  secret key; never shown to players and not a place to buy anything.
- `src/server/Vendor/ProfileStore.luau:195-196`: two code comments in the vendored save library. Not shown.
- Nothing else. "Get Roblox Plus" (`StoreStyle.luau:143`) and "Invite friends" (`:138`) use Roblox's own prompts.

Verdict: passes. Roblox allows social links only on the game's page, never inside the game (Social media links page);
the game has none, and the privacy page is not linked from inside the game (see `docs/LAUNCH.md` step 7).

## 4. Audio

Every sound id in `src/` and Config:

| Id | Where | Value |
|---|---|---|
| Light show track "Midnight Circuit" | `src/shared/Config/Audio.luau:47` | 0 |
| Light show track "Harbor Lights" | `Audio.luau:56` | 0 |
| Light show track "Neon Mesa" | `Audio.luau:65` | 0 |
| Thruster hiss | `Audio.luau:77` | 0 |

Only two places make sounds, and both stay silent at 0: `src/client/Controllers/LightShowController.luau:460`
and `src/client/Controllers/AbilityController.luau:767`. The design preview strips any sound from what it shows
(`src/client/UI/Designer/Preview.luau:29`).

Verdict: passes. No non-zero id exists, so there is nothing for Davis to confirm today. When tracks are picked, each
id must be audio published by Roblox in its licensed library, or Davis's own original track (`Audio.luau:5-8`).
Studio owns Workspace and the car models, which the repo can't see: the lead's Studio check lists any Sound there.

## 5. What a credit buys, shown before purchase

- The Store's Credits tab lists "What credits buy" from the designer's real prices: "1 credit: an AI mod on a car
  you own", "2 credits: a brand-new car the AI designs for you, with a free redesign" (`src/client/UI/Store/StoreModel.luau:631-641`,
  `StoreCards.luau:379-385`), each pack's bonus (`StoreModel.luau:622-628`) and "They never make a car faster
  than its class" (`StoreStyle.luau:96`).
- The Design Studio shows the cost before every request: "Your first car is free." or "This uses 2 credits."
  (`src/client/UI/Designer/DesignerModel.luau:286-292`), and the Out of credits sheet says what is needed
  (`DesignerStyle.luau:198-206`).
- Prices are read from Roblox, never written in code (`Monetization.luau:11-13`, `tests/NoRobuxPrices.spec.luau`).
- The Voltage Club card shows "<price> a month" and "Cancel any time in your Roblox settings" (`StoreStyle.luau:123-127`),
  as Roblox's subscription rules ask (price and duration).
- The Starter Pack lists everything in it and says it can be bought once (`StoreStyle.luau:99-101`).

Verdict: passes. One honest extra the lead may want: a paid design's credits are spent when the design comes back,
even if the player then discards it. The cost line could say so, but its exact words are checked by
`tests/DesignerUi.spec.luau:137`, so it is left as is.

## 6. The AI notice before the first request

- Before the first design or mod, the "Before you start" card shows and must be acknowledged
  (`src/client/Controllers/DesignerController.luau:581, 619, 660`; `DesignerModel.luau:335-337`).
- Every request screen repeats it in small print (`src/client/UI/Designer/StudioSheet.luau:499, 692`).
- Roblox's Creator Terms ("AI Technologies & AI Tools", "Your Responsibilities") ask creators using third-party
  AI to tell users that the AI is not human, that what it makes is AI-made and not a person's views, and that it
  may be inaccurate. The AI provider's rules for products minors use also require telling users they are dealing
  with an AI.

The notice the game shows is `Config/Designer.disclosure` (`src/shared/Config/Designer.luau`). It now says all three:
"An AI designs these cars, not a person ... It can get things wrong, so your car may not match every word", plus
"Never type personal info like your real name or address" (the privacy page says the game reminds players of that).

- fixed: the fallback notice and both small-print lines (`DesignerStyle.luau`, `disclosureBody`, `finePrint`,
  `modFinePrint`).
- fixed: `Config/Designer.disclosure` (fixer item 1, done), which replaces the fallback. In the game from the next
  publish.

## 7. Paid AI generation and Roblox's rules

Verdict: allowed. Nothing in Roblox's Terms of Use, Community Standards or monetization pages forbids charging Robux
(through developer products and Design Credits) for a feature that calls an outside AI service. The Creator Terms
expressly cover creators who use "other Third-Party Services that include AI technologies" and set the conditions.
How the game meets each one:

1. Clear AI notices (not human, AI-made, may be wrong): fixed, in the UI and in `Config/Designer.disclosure`.
2. The creator answers for what the AI makes. Outputs must meet the Community Standards and the game's maturity
   rating and must not get around Roblox's safety tools: the reply is validated and clamped twice (design service
   and game), brand-checked twice, filtered by Roblox, checked again on every join, and players can report a car
   for a moderator to hide (`DesignerService/init.luau`, the header). passes.
3. Follow the AI service's own terms. For products minors use, it requires telling users they're dealing with an
   AI (item 1) and following child-privacy law, stated publicly (the privacy page, `docs/privacy.html`; served at
   /privacy by the design service from its next deploy, `backend/public/privacy.html`; LAUNCH step 7). It may supply a
   child-safety instruction; the design service has an empty slot ready for it (`backend/lib/prompt.ts`). passes
   once the page is hosted.
4. Disclose it in the Maturity & Compliance questionnaire: "Does your game allow users to interact with generative
   AI components?" Yes; type: limited interactions. It is not "extended": there is no chat with an AI and no
   memory of earlier requests. Each request sends only the filtered description, the class and, for a mod, the
   car as it is now (`backend/lib/prompt.ts:100-117`). needs Davis (LAUNCH step 4).
5. Not a paid random item: section 2. passes. Decision a: a redesign is only ever free and never sold, so no credit
   buys a second draw from the same words; the free redesign bundled with a paid design is Davis's call (section 2).
6. Player data: the Creator Terms say a creator won't disclose user data to a third party except as the Creator
   Terms allow, and never sells or shares personal information. Only the filtered description, the class or the
   car's spec, a salted one-way hash of the player id and the kit version leave Roblox (`DesignerService/init.luau`:
   the request bodies in `designPipeline` and `modPipeline`, the hash in `hashFor`; the request headers carry only
   the key, `callBackend`). The AI service gets only the task text, never the hash (`backend/lib/claude.ts`). passes.
   The design service's request log (hash, filtered description, result) used to have no end date; it now keeps 90
   days (`backend/lib/handler.ts` `pruneUsage`, `USAGE_RETENTION_DAYS` in `backend/lib/limits.ts`,
   `backend/tests/retention.test.ts`; fixer item 4, done), live with the next design service deploy.
7. Credits deliver what they say, and every failure gives them back (`src/shared/Config/Designer.luau:72-81`). passes.
8. Nothing is sold outside Roblox (section 3). passes.

## 8. Privacy: what is kept, how long, and deletion requests

Kept in Roblox's own storage:

| Store | Key | What | Evidence |
|---|---|---|---|
| PlayerData | `Player_<UserId>` | the save: cash, cars, looks, plates, credits, designs, house, jobs, season, streak, the last 100 purchase ids | `src/shared/Config/Data.luau:14, 18` |
| AdRewards | `ad_<UserId>` | the day of the last ad reward | `src/shared/Config/Ads.luau:141-145` |
| LimitedSerials | one key per drop | which player id holds which serial number | `src/shared/Config/Limiteds.luau:111`, `LimitedService.luau:5` |
| DragStripWeek_&lt;week&gt; | player id | best time that week | `src/shared/Config/DragStrip.luau:114-118` |
| DesignerHidden, DesignerSalt, LiveOps, UsedLotSupply | not per player | hidden design ids, the hash salt, events and flags, stock counters | `Config/Designer.luau:70, 125` |

Kept by the design service (outside Roblox): `vc_designer_usage` (the salted hash, filtered description, result,
cost and time of each request) and `vc_designs` (finished designs by description, with no player link)
(`backend/supabase/migrations/0001_designer.sql:22-53`).

- fixed: design-service log rows older than 90 days are deleted (item 4). `docs/privacy.html` says 90 days, so the
  page is hosted by the same deploy that ships the cleanup (`backend/public/privacy.html`, a copy that
  `backend/tests/privacy.test.ts` keeps identical).
- needs Davis: Roblox sends a daily message when a player asks Roblox to delete their account. Deletion templates
  can do PlayerData (`Player_{UserId}`) and AdRewards (`ad_{UserId}`) automatically (LAUNCH step 7).
- fixed: the drag strip boards (a new store name every week), the serial ledger (the id sits inside a shared value)
  and the design service's rows can't be templated, so `src/server/Dev/ForgetPlayer.luau` does them for one player id
  (item 5, done; `tests/ForgetPlayer.spec`). Davis forwards the message, Claude runs it (LAUNCH step 7). It also
  deletes the save for a request that comes without an account deletion. Not yet tried against real DataStores:
  the lead's Studio check.
- The privacy page's "How long things are kept" covers the drag strip times (until removed on request) and the
  serial ledger (kept so each number stays unique; the id is replaced on deletion).

## For the fixer

Status after the fixer pass (2026-10-21):

| # | Status |
|---|---|
| 1 | done |
| 2 | done |
| 3 | done |
| 4 | done and live (`npm test` passes; deployed to production 2026-10-21) |
| 5 | done: `src/server/Dev/ForgetPlayer.luau` (Edit-mode helper; LAUNCH step 7) and `tests/ForgetPlayer.spec` |
| 6 | waits on the beta check (LAUNCH step 12); nothing to do unless it fails |
| 7 | done and live with the same deploy as item 4 (https://voltage-county-designer.vercel.app/privacy) |

The original items, as handed over:

1. `src/shared/Config/Designer.luau:137-139`, `disclosure`: replace with
   `"An AI designs these cars, not a person. Describe your idea and the AI turns it into an original car. "`
   `.. "It can get things wrong, so your car may not match every word. "`
   `.. "What you type is checked for safety first and sent to our design service without your name. "`
   `.. "Never type personal info like your real name or address. Designs are always original: no real car brands."`
2. `src/shared/Config/Designer.luau` `messages`: `pendingChoice = "Build, redesign or discard your last design first."`,
   `rerolling = "Redesigning your car..."`, `noReroll = "There's no free redesign left for this design."`,
   `rerollFailed = "The redesign didn't work, so here's your design again. Your free redesign is still there."`
   (player-facing words only; keys and the `reroll` choice stay).
3. `src/server/Services/DesignerService/init.luau:349-360`, `surpriseClass`: drop the `Random`; return the first
   class in `kit.surpriseClasses` order that `canDesign` allows (else `kit.surpriseClasses[1]`), so a paid
   request never lands on a class by chance. Remove the `rng` parameter, its caller's argument (`:859`) and the
   now-unused `random` (`:230`), and update the comment at `:348`. No spec calls `surpriseClass` today.
4. `backend/`: keep the request log 90 days. Add `USAGE_RETENTION_DAYS = 90` to `lib/limits.ts`; a
   `pruneUsage(before: Date)` on the Store (`lib/store.ts`: Supabase `delete from vc_designer_usage where
   created_at < before`, which the `vc_designer_usage_time` index covers; the memory store filters its array);
   call it from `lib/handler.ts` at most once an hour per warm instance, after the reply is decided, never failing
   a request (log and carry on). A test in `backend/tests/` that rows older than 90 days go and newer ones stay. Add
   "How long records are kept" to `backend/README.md`. Then the usual: `npm test`, deploy to production.
5. Later (not blocking the beta): a small "forget this player" helper for Roblox's daily deletion message. Given a
   UserId it removes the player's drag strip entries, swaps their id in `LimitedSerials` owners for a placeholder
   (serials stay unique), and deletes their design-service rows by hash (the salt is in the `DesignerSalt`
   DataStore). Open Cloud or a Studio command; Davis forwards the message to Claude.
6. Only if the beta check fails (players with chat off get all `#`): in the Design Studio, before the credit
   store, tell those players the designer needs Roblox chat on (for example with `TextChatService:CanUserChatAsync`),
   and keep the plate shop's custom text hidden for them.
7. Host the privacy page once item 4 is live (the page promises 90 days): copy `docs/privacy.html` to
   `backend/public/privacy.html`, add `"cleanUrls": true` to `backend/vercel.json` so
   https://voltage-county-designer.vercel.app/privacy answers, and deploy. `docs/LAUNCH.md` step 7 gives Davis
   that address.

## Sources

- Roblox, Games with Generative AI (updated 2026-10-20): https://create.roblox.com/docs/en-us/generative-AI
- Roblox, Content maturity and compliance (updated 2026-10-20): https://create.roblox.com/docs/en-us/production/promotion/content-maturity
- Roblox, Paid random items policy guidelines: https://create.roblox.com/docs/production/monetization/paid-random-items
- Roblox, Text filtering (updated 2026-10-20): https://create.roblox.com/docs/en-us/ui/text-filtering
- Roblox, Terms of Use including the Creator Terms (updated 2026-10-07): https://en.help.roblox.com/hc/en-us/articles/115004647846-Roblox-Terms-of-Use
  (sections "AI Technologies & AI Tools", "Privacy", "Random Virtual Items")
- Roblox, Social media links: https://create.roblox.com/docs/en-us/production/promotion/social-media-links
- Roblox, Subscriptions (guidelines): https://create.roblox.com/docs/en-us/production/monetization/subscriptions
- Roblox, RTBF and creators: https://create.roblox.com/docs/en-us/production/publishing/RTBF-and-creators
- Roblox, Data store right to be forgotten: https://create.roblox.com/docs/en-us/cloud-services/data-stores/right-to-be-forgotten
- Roblox, Immersive ads (publisher eligibility): https://create.roblox.com/docs/en-us/production/monetization/immersive-ads
- Roblox, Create and publish games (release requirements): https://create.roblox.com/docs/en-us/production/publishing/publish-games-and-places
- Roblox, Roblox Kids and Select: https://create.roblox.com/docs/en-us/production/publishing/kids-and-select
- Anthropic, Guidelines for organizations serving minors (2026-03-16): https://support.claude.com/en/articles/9307344-responsible-use-of-anthropic-s-models-guidelines-for-organizations-serving-minors
- Anthropic, How long do you store my organization's data: https://privacy.claude.com/en/articles/7996866-how-long-do-you-store-my-organization-s-data
