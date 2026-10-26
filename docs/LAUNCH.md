# Launch checklist

Davis, this is everything between now and opening Voltage County to everyone, in order. Each step says who does it:

- **Only you**: it needs your Roblox account, your ID, your money or your answers, so Claude can't do it.
- **Claude**: say the word in chat and Claude does it.
- **Together**: Claude prepares it, you click the last button.

Anything that costs Robux says so and the price, and waits for your yes. The Creator Dashboard is
https://create.roblox.com/dashboard/creations. Click **Voltage County** there to reach every page named below.

## 1. Get your Roblox account ready (Only you, 10 minutes)

Needed to let players under 16 in, to show billboard ads and to price the Voltage Club in dollars.

1. On roblox.com open **Settings > Account Info**. Under your birthday click **Continue with ID** and follow the
   steps with your driver's license or passport. If you're under 18, Roblox asks for a quick face age check
   instead of an ID.
2. In **Settings > Security**, turn on **2-Step Verification**.
3. In **Settings > Account Info**, check your email shows as verified. Cashing out needs it.

## 2. Icon and thumbnails (Claude makes them, you upload)

1. Say "make the icon and thumbnails". Claude takes them from the game itself: the Arc in mid-air and a
   player-designed car, plus the highway, the dealership and a car meet. You get one square icon (512 x 512) and up
   to 10 wide pictures (1920 x 1080) to pick from.
2. They must be original: no real car brands or logos, nothing from other games, and nothing the game doesn't have.
3. To upload: **Configurations > Places**, click the place with the star, then change the icon (set it to
   **Image**, click **Change**) and add the thumbnails on the same page.

## 3. Title and description (Only you, copy and paste)

Where: the same place page as step 2, or **File > Publish** in Studio. Pick the genre **Simulation > Vehicle Sim**.

Title: **Voltage County**

Description (no real brands, no links, which Roblox doesn't allow anyway):

> Drive, work and design your own car in Voltage County! Cruise the County Loop highway, earn cash on rideshare,
> delivery and freight jobs, and buy cars from eight made-up brands at the dealership. Describe your dream car and
> an AI designs it for you, then mod it, paint it and show it off at car meets with light shows. Claim a house, run
> a robotaxi fleet and boost-hop over traffic in the Arc. Every car and brand in the game is original.
>
> Privacy: the AI Car Designer only gets your checked description, never your name.

Don't use the word "hangout" in the title or description: Roblox then treats the game as a social hangout and limits
it to players 16 and over.

## 4. Maturity questionnaire (Only you, 10 minutes)

Roblox needs this before it will show billboard ads, and before players under 16 can find the game.

1. Go to **Publish settings > Content rating** and click **Start**.
2. Answer from what's in the game. What the game has today:

   | Question | Answer |
   |---|---|
   | Violence, blood, fear, crude humor | No (cars bump into each other; nobody is hurt) |
   | Gambling, strong language, romance, alcohol | No |
   | Is it a social hangout? | No (it's driving and jobs) |
   | Free-form user creation | No (plates are typed text Roblox filters first; designs are built from car parts) |
   | Sensitive issues | No |
   | Paid random items | No |
   | Trading paid items | No |
   | Sharing media, endless feeds, content from other games | No |
   | Can players use generative AI? | **Yes** |
   | What kind? | **Limited interactions** (no chatting with an AI, and it doesn't remember earlier requests) |

3. Check the preview, then click **Submit**. Expect the lowest rating, **Minimal**.
4. If the game ever changes these answers (say, a weapon or a chat with an AI), the questionnaire has to be redone.

## 5. Managed Pricing (Only you, 5 minutes)

It lets Roblox test prices and set fair prices in each country.

1. Go to **Monetization > Managed Pricing** and finish the one-time opt-in.
2. If it says it found prices written into the game, tell Claude. It shouldn't: the game reads every price from
   Roblox.
3. Items you create later (step 8) join automatically. Price tests start only once the game sells a lot (about
   60,000 sales a month), so expect nothing to happen for a while. Country pricing works straight away.

You can do this after step 8 if you'd rather see your items in the list.

## 6. Cashing out and the tax form (Only you, later)

Roblox only opens your cash-out account after your first cash-out, and that needs 30,000 earned Robux.

1. When you have 30,000 earned Robux: Creator Hub, **Finances**, then the **Cash Out** button (top right). Use your
   legal name.
2. Roblox emails you (from no-reply@roblox.com) an invite to the DevEx Portal. Within one week, open it, pick how
   you get paid and fill in the W-9 tax form.
3. If you already have a DevEx Portal account from another game, Roblox asks everyone to review their tax details
   there before November 1, 2026. (That's Roblox's notice, not tax advice.)

## 7. Privacy page and deletion requests (Claude hosts it; one setting for you)

The page is `docs/privacy.html`: what the game saves, what the AI Car Designer sends, how long records are kept,
and that the game follows the rules for children's data.

1. **Done (2026-10-21)**: it's online at the design service's address
   (https://voltage-county-designer.vercel.app/privacy). What it promises:
   - the design service deletes its records after 90 days (live since the same day);
   - the AI notice before the first design tells players not to type personal info (in the game from your next
     **File > Publish**, so publish before you share the page);
   - deletion requests are handled (step 4 below; Claude tried the helper in Studio on 2026-10-21).
2. Roblox doesn't allow website links in the game or its description, so the description carries the one-line
   privacy note from step 3. Keep the address handy for anyone who asks (Roblox, a parent).
3. **Only you**: when a player deletes their Roblox account, Roblox lists it in a daily message. Two templates make
   Roblox delete their save for you. Go to **Configurations > Data stores manager**, the **RTBF Deletion** tab,
   **Create Template**, and add:
   - Type **Standard Key**, data store `PlayerData`, key `Player_{UserId}`
   - Type **Standard Key**, data store `AdRewards`, key `ad_{UserId}`
4. **You forward, Claude does the rest**: send Claude each of those daily messages, and any request from a player or
   a parent to delete their game data (ask them for their Roblox username). With Studio open, Claude:
   - runs the "forget this player" helper (`src/server/Dev/ForgetPlayer.luau`) for each player id. It takes their
     times off every weekly drag strip board and their player id off any limited serial number (the number stays
     used, so no one else gets it). For a request that didn't come with an account deletion, it also deletes their
     save, since no template runs then;
   - deletes the design service's records for that player, with the database command the helper prints;
   - tells you when it's done. Nothing goes back to the player through the game.

## 8. Create the store items and send Claude the ids (Only you creates them; Claude pastes the ids)

The prices below are only a starting point. Managed Pricing adjusts them later. Claude can make the 512 x 512 item
pictures too.

**Passes**: **Monetization > Passes > Create pass**. Any category is fine. Use the description shown.

| Name | Description | Suggested price |
|---|---|---|
| VIP | +20% pay from every job, and a VIP tag on your chat messages. | 199 Robux |
| Fleet Manager | +5 robotaxi pod slots, and fleet earnings collect themselves. | 249 Robux |
| Garage+ | +10 garage spaces and +2 custom car slots. | 149 Robux |
| Light Show Pro | Every Pro light show routine at car meets. | 99 Robux |
| Custom Plates | Write your own plate text. | 49 Robux |
| Season Pass | The premium reward track for Season 1: Lift Off. | 299 Robux |

**Developer products**: **Monetization > Developer Products > Create developer product**.

| Name | Description | Suggested price |
|---|---|---|
| 5 Design Credits | 5 credits for the AI Car Designer. | 99 Robux |
| 15 Design Credits | 15 credits plus 3 bonus. | 249 Robux |
| 40 Design Credits | 40 credits plus 12 bonus. | 549 Robux |
| Starter Pack | 5 credits, $25,000 in game cash, 1 more custom car slot and the Starter Spark wrap. One per player. | 149 Robux |
| Extra Custom Car Slot | 1 more custom car slot, kept for good. | 79 Robux |
| Cash Stack | $10,000 in game cash. | 25 Robux |
| Cash Bag | $35,000 in game cash. | 75 Robux |
| Cash Case | $100,000 in game cash. | 199 Robux |
| Cash Vault | $300,000 in game cash. | 499 Robux |
| Launch Week Wrap | A numbered Launch Week wrap, sold Jan 15 to 22, 2027 only. | 99 Robux |

Don't create the Launch Week plate frame or the ad reward yet. The frame waits until plate frames are in the game;
the ad reward waits until Roblox lets the game show reward ads.

**Voltage Club**: **Monetization > Subscriptions > Create Subscription**.

- Name **Voltage Club**. Description: "10 Design Credits every month, +2 custom car slots while you're a member,
  and the members-only Voltage Club wrap."
- Choose **Subscribers pay local currency**, **$4.99** a month (needs step 1). Product type **Currency**.
- Local-currency prices can't be changed later without deleting it and refunding members, so pick carefully.

**Private servers**: **Audience > Access Settings**, turn on **Allow private servers**. Turn on **Requires Robux**
and enter a monthly price, for example 99. Changing that price later cancels everyone's private servers.

**Send Claude the ids.** For each pass and product: hover its picture, click **...**, then **Copy Asset ID**. For the
Voltage Club, copy its id (it starts with `EXP-`). Paste the list into chat as "name: id". Claude puts them where the
game reads them (`src/shared/Config/Monetization.luau` for passes, products and the club;
`src/shared/Config/Limiteds.luau` for the Launch Week wrap) and publishes the update. Until an id is in, that item
shows "Coming soon" and can't be bought.

Each new season: create a new Season Pass and send Claude its id.

## 9. The AI Car Designer's keys (Only you, 5 minutes)

1. In File Explorer, open `C:\Users\space\projects\voltage-county\tools` and double-click
   `open_designer_setup.bat`. A small window opens.
2. Click **Open database keys**. Copy the **Secret key** and paste it into the box in the window.
3. Click **Save and go live** and wait about a minute for "Done".
4. Click **Copy game password**, then **Open Roblox secrets**. Click **Create Secret**: name `designer_key`, paste the
   password, domain `voltage-county-designer.vercel.app`. Save.
5. For testing in Studio: **File > Experience Settings > Security**, **Local Secrets**: add the same name, password
   and domain.

If the window says your Claude key isn't saved, run `open_key_window.bat` in the same folder first.

## 10. Streaming and chat settings (Only you, in Studio, 3 minutes)

These decide how much of the county loads around a driver. Roblox doesn't let any script or plugin set them (Rojo
can't either), so they are typed in once by hand, and the place keeps them from then on.

1. In Studio, click **Workspace** in the Explorer.
2. In Properties, set:

   | Property | Value |
   |---|---|
   | StreamingEnabled | ticked (it already is) |
   | StreamingMinRadius | 512 |
   | StreamingTargetRadius | 2048 |
   | StreamOutBehavior | Opportunistic |
   | StreamingIntegrityMode | Disabled |

   They come from the `streaming` section of `src/shared/Config/Perf.luau`. The build check keeps the project file
   the same as that section, so if these ever change, Claude tells you the new values.
3. Click **TextChatService** in the Explorer. In Properties, set **ChatVersion** to **TextChatService** (the place
   still says LegacyChatService; Roblox's newer chat is the one the game is built for, and scripts can't switch it).
   Leave **CreateDefaultTextChannels** ticked.
4. Click **Lighting** in the Explorer. **LightingStyle** should read **Realistic** and **PrioritizeLightingQuality**
   should be ticked (Claude set both in the place on 2026-10-26; the game's scripts can't change them while it runs).
5. **File > Publish to Roblox**.

## 11. Change the game password once (Together, 5 minutes, before the beta)

The game password (the `designer_key` secret) was handled a few times during setup, so change it once before
anyone else plays. Nothing stops working along the way. The full steps are in `docs/SECURITY.md`, "Rotating the
game password".

1. **Claude** first puts the design service update live that lets the old and the new password work side by side.
   Until then, don't start.
2. In the setup window (step 9), click **Change game password** and wait about a minute for "New password is live".
3. Click **Copy game password**, then **Open Roblox secrets**. Edit `designer_key`, paste the new password, keep the
   domain `voltage-county-designer.vercel.app`, and save.
4. In Studio: **File > Experience Settings > Security**, **Local Secrets**. Replace the password in the
   `designer_key` line.
5. A day later (or after **Restart Servers for Updates** on the game's page in the Creator Dashboard), click
   **Finish change**. Only the new password works from then on.

## 12. Private beta with friends (Together)

1. In Studio: **File > Invite early testers**, pick up to 10 friends and click **Invite**. Roblox may ask you for an
   age check first. They see a "preview" mark while they play.
2. Ask them to try, and tell Claude what goes wrong:
   - make your free car in the Design Studio and build it. Redesign and discard come with paid designs: Claude
     checks those in Studio with test credits, and in the beta only if someone chooses to buy credits;
   - drive the County Loop, do a job, buy a car, join a car meet;
   - one friend who hasn't done Roblox's age check (their chat is off) tries a design and, if someone has the
     Custom Plates pass, a plate. If every word turns into `#`, tell Claude;
   - someone with the Custom Plates pass sets a plate, and another player checks it shows filtered;
   - play on a real phone: the touch controls, the phone screens, and whether it runs smoothly.
3. Buying anything in the beta costs real Robux (the item's price; most of it comes back to you as earnings when it's
   your own account). Only do it if you want to see a real purchase; purchases can also be tested in Studio for free.

## 13. Open it to everyone (Only you)

1. **Publish settings > Manage Audience > Manage access**, the **Public** tab: turn **Friends** off. **Save Changes**.
2. At first Roblox shows the game only to age-checked players 16 and over. To reach younger players as well:
   - steps 1 and 4 done (ID, 2-Step, rating Minimal);
   - either 2 months in a row of Roblox Plus or Premium, or a one-time 1,000 Robux fee that Roblox refunds later
     (**Audience > Reach**, **Refundable publishing fee**, **Pay**). It costs Robux, so it's your call;
   - then Roblox watches for 250 plays by real, active players within 60 days and reviews the game. Progress shows on
     the **Audience Reach** page.
3. Billboard ads start once the game has about 2,000 visitors a month and the questionnaire is approved. Tell Claude
   when **Monetization > Ads > Eligibility** says yes. Each brand's billboards show ads only once that brand has a
   poster picture, which shows whenever no ad is served, so first:
   - **Claude** makes the 8 brand posters (one per car brand, original art);
   - **you** upload them: in Studio, **View > Asset Manager**, the **Import** button, pick the 8 pictures. Right-click
     each one, **Copy Asset ID**, and send Claude the list as "brand: id" (or say yes and Claude uploads them for
     you);
   - **Claude** puts the ids in `src/shared/Config/Ads.luau` (the `posters`), switches the billboards to real ads
     and publishes the update.
