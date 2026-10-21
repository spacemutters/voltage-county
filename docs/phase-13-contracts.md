# Phase 13 contracts

Houses and social roleplay (PLAN.md "Phase 13" is the spec). Read `CLAUDE.md` and the earlier contracts
(`docs/phase-1..12-contracts.md`). The map already has 26 `HousePlot` locations in Riverside (four courts plus
Sycamore Lane and Elm Street; all claimable) and the `MeetSpot`s from Phase 7.

## Houses (owner: house helper)
- `Config/Houses.luau`: the house greybox (built per plot at runtime, outside `Workspace.Map.Generated`), the
  garage door, the home charger (rate above the public Level 2 stalls, below DC fast; read `Config/Energy`), the
  upgrade list (3–5 upgrades: e.g. faster charger, second garage bay, porch lights, mailbox colour) with in-game
  prices, plain messages.
- `src/server/Services/HouseService.luau`: claim a free plot (one per player per server; a `ProximityPrompt` at the
  plot's sign), the house appears with the player's name on the sign (Roblox display names need no filtering), the
  claim is released when the player leaves (house removed, plot free), upgrades bought through
  `EconomyService.trySpend` and saved in `house.upgrades` (they apply to whichever plot the player claims next
  time), the garage door opens for the owner's car. Net (declared by the lead): `ClaimHouse { plotId }`,
  `LeaveHouse`, `BuyHouseUpgrade { upgrade }`, `HouseUpdate` (server → client).
- Home charging: the plot's charger is a `ChargerStall`-like spot that only charges the **owner's** car, at the home
  rate (EnergyService gains the home charger path; nobody else's car charges there).
- Phone: a Home app (claim status, address, upgrades, "Set GPS home").
- Specs: claim/release decisions, one plot per player, the home rate only for the owner at their own plot.

## Social (owner: social helper)
- **Car meets** (`MeetService`): when 4 or more players' cars are parked (still, owner out or seated, inside the
  `MeetSpot` footprint) at one meet spot, announce it once to everyone in the phone's Feed (a new Feed app: recent
  server events, newest first) and a toast; not again for that spot until it drops below 4 and a cooldown passes.
  Counting is event-driven (car park/unpark), not a polling loop. Net: `FeedUpdate` (server → client).
- **Nametags** with job titles: a BillboardGui over each character (display name + the title of their best job level,
  e.g. "Freight Hauler II"), hidden while driving at speed and during cutscenes; titles in `Config/Jobs`.
- **Chat:** TextChatService defaults on (bubble chat), nothing custom that bypasses filtering.
- **Emotes:** an Emotes app in the phone using the default Roblox emotes (`Humanoid:PlayEmote`), on foot only.
- Specs: the meet fires at 4 parked cars and not at 3 (pure counting function), cooldown, title choice.

## Tests (owner: tests helper)
`src/client/Dev/SocialTests.luau` (Studio only, like the other drivers): `house()` claims a plot, checks the house
and sign, charges the owner's car at the home charger and checks a second (dev-spawned, server-owned) car does not
charge there, then leaves the claim and checks the plot is free; `meet()` parks dev cars at a MeetSpot one by one
(dev-only server helper `DevSocial { action = "parkDummyCar" | "clearDummies", meetSpotId }`) and checks the Feed
announcement arrives at the 4th and not the 3rd.

## Net (declared by the lead before the build)
`ClaimHouse { plotId }`, `LeaveHouse`, `BuyHouseUpgrade { upgrade }` (functions), `HouseUpdate` (server → client),
`FeedUpdate` (server → all clients), Studio-only `DevSocial { action = "parkDummyCar" | "clearDummies", meetSpotId? }`.
Emotes need no remote (`Humanoid:PlayEmote` on the client replicates).
