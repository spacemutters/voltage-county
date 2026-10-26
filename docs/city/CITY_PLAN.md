# Voltage County city plan: the Miami rebuild

Branch `miami-city`, 2026-10-25. This is the district and placement plan the build steps work from. It covers what
goes where, which building type stands on which plot, how repeats vary, the one-off landmarks, the street-level
scenery, how the new city builder plugs into Dev/MapBuilder, and the part budgets.

Davis's brief, 2026-10-25: redo the buildings and the scenery, hand-modelled, each building with its own real-building
inspiration, "less Greenville, more Miami", big and unique, sharp. Keep the gameplay and mechanics.

## 0. Ground rules

What stays exactly as it is:

- The road network and Config/RoadGraph.
- Every MapLayout location, pad and gameplay spot: dealership and used-lot pads, chargers, pumps, depots, spawns,
  meet spots, hotspots, house plots, billboards, the drag strip and the dev track.
- The seeded plot pass in `addBuildings`. Every plot keeps its place: the same random draws, the same order, the same
  clear-checks (`usable`, `LOT_BLOCKERS`). New buildings stand on those plots.
- Dev/MapCheck: no road overlaps, every location built and within reach of a road, every node reachable, routes
  under 5 ms. It must still pass.

What changes: what buildings, landmarks, trees, paving, street furniture, the beach and the water edge look like.

Hard rules for every build step:

- `--!strict` at the top of every file.
- Tunables live in `src/shared/Config/City.luau`.
- Builders are Edit-mode only, under `src/server/Dev/City/`.
- **Real names stay out of the game.** Real buildings are inspiration only. Their names (and real business, brand and
  neighbourhood names) appear in `docs/city/` and nowhere in `src/` or `tests/`: not in code, comments, instance
  names, signs or strings. In code, district and archetype ids are neutral (`downtown`, `beach`, `sky_court`), and
  sign text is invented (section 7.3).
- No real carmaker names (existing rule).

## 1. What is there today

All figures below were measured from `MapBuilder.county()` in Studio on 2026-10-25. The planner is pure; no instances
were made.

### Parts by role (15,485 total)

| Role | Parts | Role | Parts |
|---|---|---|---|
| building | 5,496 | lot | 214 |
| tree | 4,581 | prop | 185 |
| light (streetlights) | 1,200 | location | 112 |
| pad (junctions) | 1,123 | feature | 70 |
| sidewalk | 850 | displayPad | 60 |
| line | 821 | support | 44 |
| road | 417 | billboard | 30 |
| ground | 237 | landmark / sign / spawn / ramp / water | 20 / 16 / 4 / 4 / 1 |

### Building plots per zone (916 built today)

| Zone | Buildings | Block models | Footprint width | Depth | Height today | Faces a street / an arterial |
|---|---|---|---|---|---|---|
| cedar_bend | 600 | 73 | 21..47 (median 33) | 20..44 (median 32) | 40..159 (median 101) | 532 / 68 |
| the_plant | 147 | 35 | 21..47 (34) | 20..44 (32) | 24..60 (40) | 21 / 126 |
| riverside | 109 | 31 | 21..47 (33) | 21..44 (33) | 14..24 (18) | 84 / 25 |
| lakefront | 54 | 25 | 21..45 (32) | 21..44 (34) | 14..39 (27) | 50 / 4 |
| mesa_test_site | 6 | 5 | 21..41 | 21..41 | 9..16 | 3 / 3 |

Every plot faces the road it was cut from. A plot runs back from the frontage line, `half + sidewalk + 2` studs from
the road's centre line, for 53 studs (setback up to 9, plus depth up to 44). That puts the plot band at:

- 25..78 studs from a downtown street's centre line
- 40..93 from an arterial's
- 17..70 on lakefront roads, which have no sidewalk

Plots are 26..52 studs wide along the road. Each building is 5 studs narrower than its plot.

### Runs: neighbouring plots on one frontage, with no gap

| Zone | Runs | Runs by length (1, 2, 3, 4, 5, 6+ plots) | Runs ≥ 90 studs wide | Widest |
|---|---|---|---|---|
| cedar_bend | 240 | 102, 46, 28, 22, 21, 21 | 94 | 241 |
| the_plant | 91 | 58, 20, 8, 3, 0, 2 | 13 | 295 |
| riverside | 81 | 60, 15, 5, 1, 0, 0 | 6 | 161 |
| lakefront | 39 | 27, 9, 3, 0, 0, 0 | 3 | 124 |
| mesa_test_site | 6 | 6 singles | 0 | 41 |

### Downtown blocks

Buildings per block. A block is named after its north-west node: columns a..f run west to east, rows 1..6 north to
south.

```
        a    b    c    d    e    f
row 1   14   16   16   17   16   17
row 2   15   15   15   17   11   14
row 3   14   15    0   15   14   15      c3 = Town Square (park)
row 4   11   14   11   15   12   13
row 5   17   10   14   12    6    8      e5 = used lot (spawn), f5 = showroom
row 6   15   15   16   13   14    0      f6 = dealership auto mall
outside the grid: 128 (outer sides of the edge streets, and the four avenues leaving town)
```

Three facts drive the plan:

1. **Plots are townhouse-sized.** A 33 x 32 footprint is about 9 x 9 m at the game's 0.28 m per stud. A real
   Brickell tower needs 3 to 5 times that.
2. **Block interiors are empty.** Between the four plot bands, a 300-stud downtown block has an empty core about
   144 x 144 studs (129 beside an arterial).
3. **Wide runs exist.** 94 downtown runs are at least 90 studs wide.

So towers merge neighbouring plots of one run, and the tallest also reach back into their block's empty core
(section 4.4). Nothing moves.

Trees today: 1,692 in all. That is 1,289 in the open country, 265 in Lakefront, 100 in Riverside, 34 in Town Square
and 4 in The Plant.

Scale reference (Config/World): 0.28 m per stud, a 5-stud avatar, 12-stud lanes. A street is 30 studs wide with 8-stud
sidewalks; an arterial is 56 with 10-stud sidewalks. The plan uses 12-stud floors downtown (about 3.4 m).

## 2. The skyline

### Height bands

| Band | Studs | Floors at 12 | Used for |
|---|---|---|---|
| L (low) | 24..84 | 2..7 | storefronts, motels, deco hotels, warehouses, villas |
| M (mid) | 84..160 | 7..13 | mid-rise offices, condos, tall deco hotels, lofts |
| H (high) | 160..260 | 13..21 | high-rise condos and offices |
| T (tall) | 260..400 | 21..33 | Brickell towers |
| S (supertall) | 420..560 | 35..46 | four one-off landmarks only |

The tallest building is 560 studs, about 157 m in game metres. That is 112 avatar heights, and it is a tunable
(`City.bands`).

### Shape

Downtown rises from the bay row (the south edge, facing the lake) to a peak at Main and Commerce Avenues. It dips at
Town Square, then rises to a second peak in the north.

- The peak sits in blocks d3, d4 and e4, around the centre crossing.
- The second peak sits in d2 and f2.
- The dip is row 3, with the Town Square park at c3.
- Blocks step down to mid-rise at the west (a) and east (f) columns.
- The outer frontages facing open country are low.
- The south outer frontage, facing the lake, is the exception: it is the bay row of iconic shapes.

From the Cedar Lake Bridge, looking north, a driver sees the bay row in front, the d6 crown tower behind it, the d4/e4
cluster, the 560-stud spire, and the north peak.

### Block caps for repeatable buildings

One-offs are exempt. An asterisk means the block holds a one-off or a gameplay spot (section 5).

```
          a        b        c         d          e           f
row 1   M 130    M 150    H 200     T 300      H 220       M 160
row 2   M 120    H 180    H 240     T 340*     T 300*      H 220*
row 3   M 110    H 170    (park)    T 360*     T 320       H 240*
row 4   M 120*   H 180    H 260     T 380*     T 340*      H 240
row 5   M 100    M 150*   H 240*    H 220*     L 60* spawn L 70* showroom
row 6   M 110    H 180    T 300     T 340*     H 220       (auto mall)
outer   north L 60 (motel row) | west L 54 (bright storefront row) | east M 96 (garages, lofts) |
        south: the bay row, H 200 between its one-offs
```

Rules on top of the caps:

- **Tower slots.** In a T-cap block, at most one repeatable tower (band T); a one-off takes that slot. In an H-cap
  block, at most two H sites. Everything else in the block is M or L.
- **Low near gameplay spots.** A site within 40 studs of a MapLayout location's footprint is capped at M. This keeps
  the charging plaza, the used lot, the fuel station and the depots open to the eye.
- **Tower site in a run.** In a run that gets a tower, the tower takes the end nearest the block's peak corner (the
  corner nearest Main and Commerce, or the north peak for rows 1..2). The rest of the run steps down: podium sites at
  30..60 % of the tower's height.
- **No twin heights.** No two T or S buildings within 600 studs of each other are within 24 studs (two floors) of the
  same height.

## 3. Districts

Code ids are neutral, and in-game zone names stay as they are (decision D2):

| Zone | Code district | Look |
|---|---|---|
| cedar_bend | `downtown` | Brickell and Downtown Miami |
| lakefront | `beach` | South Beach and Ocean Drive; the lake as the bay; the bridge as a causeway |
| riverside | `suburbs` | Coral Gables and the Miami suburbs |
| the_plant | `arts` | Wynwood and the Design District |
| mesa_test_site | `quarry` | a coral-rock limestone quarry and airfield proving ground |
| county_loop | `loop` | Florida expressway and sawgrass country |

How the archetype tables work:

- Each archetype names the real buildings it takes after (docs only).
- "Fits" is the smallest site, width along the road by depth.
- "Parts" is the target per building, and the builder holds it under that.
- Every archetype composes the shared kit (section 8.4): podium, glass core, slab bands, fins, rounded corners,
  crowns, awnings, eyebrows, signs.

### 3.1 Downtown: Brickell and Downtown Miami

Identity: big glass towers on street podiums. White balcony slabs stack up blue-green glass. Fins catch the sun.
Pool-deck crowns, lit tops at night. At street level, shops and palms. On the edges, mid-century motels and bright
storefronts.

**Repeatable archetypes**

| Id | Inspiration | Band | Fits | Parts | Silhouette idea | Variation knobs |
|---|---|---|---|---|---|---|
| balcony_stack | Brickell condo towers with white wrap-around balcony slabs (Icon Brickell, Echo Brickell, Paramount Miami Worldcenter) | H, T | 45x40 (H), 70x60 (T) | 30..55 | white slab edges every 1 to 3 floors over tinted glass, pool-deck crown with cabana and pergola | glass tint, slab rhythm (1/2/3 floors), square or rounded corners, crown (cabana, pergola, lit fins), mirror |
| fin_tower | glass towers with vertical fins (Panorama Tower, Brickell World Plaza, 1450 Brickell) | H, T | 60x50 | 25..45 | fin rhythm on glass, notched corners, lit lantern top | fin spacing 8/10/12, fin colour, lantern height, podium screen pattern |
| rounded_tower | rounded glass towers (Brickell Flatiron) | H, T | 55x50 | 20..35 | vertical cylinders at the corners make a rounded prism; curved crown | corner radius, band interval, crown |
| shifted_plates | towers of shifted floor blocks (One River Point, the "stacked box" condos) | T | 70x60 | 30..45 | blocks of 4..6 floors shifted alternately | shift 4..8 studs, block height, tint |
| twin_slab | twin slender towers on one podium with a sky bridge (Brickell Heights; Rise and Reach) | T | 120x60 | 45..60 | two slabs, a sky bridge, one podium | height ratio, bridge floor, tint |
| podium_tower | towers on parking podiums with art screens (the SLS Lux Brickell podium mural) | H | 70x50 | 25..40 | colourful podium screen under a slim tower | screen pattern and palette, tower offset |
| office_box | Brickell office slabs with ribbon windows and stepped tops (Brickell Bay Office Tower, 701 Brickell) | M, H | 45x40 | 15..30 | horizontal spandrel bands, stepped lit top | band colour, step count |
| setback_tower | 1920s-30s Miami stepped towers (Dade Commonwealth Building, Alfred I. duPont Building) | M | 40x35 | 15..25 | limestone setbacks, vertical piers | stone colour, setbacks |
| hotel_tower | bayfront hotel slabs with lit edges and a top band (JW Marriott Marquis, the Biscayne Boulevard hotels) | H | 55x45 | 25..35 | slab with LED edge strips and a top band | strip colour (night kind), band |
| art_garage | city garages with art screens | L, M | 45x40 | 10..20 | perforated screens or angled fins in colour | pattern, palette |
| storefront_low | historic 2-4 storey retail (Flagler Street) | L | 26x20 | 8..14 | arcade or awnings, cornice, blade sign | awning colour, cornice, sign |
| motel_pylon | Biscayne Boulevard mid-century motels (cheese-hole walls, angled pylons, boomerang canopies) | L | 30x25 | 10..16 | pylon sign, cheese-hole screen | palette, pylon side |
| bright_storefront | Little Havana storefronts (Calle Ocho stucco, murals, neon) | L | 26x20 | 8..14 | coloured stucco, mural panel, neon | palette, mural |

**Where they go**

- T-cap blocks: balcony_stack, fin_tower, shifted_plates, twin_slab, rounded_tower for the tower slot. office_box,
  podium_tower and hotel_tower for H podiums. storefront_low between them.
- H-cap blocks: balcony_stack (H), rounded_tower (H), podium_tower, office_box, hotel_tower.
- M-cap blocks: office_box, setback_tower, art_garage, storefront_low.
- Outer frontages:
  - north: motel_pylon and storefront_low
  - west: bright_storefront and storefront_low
  - east: art_garage, office_box (M) and storefront_low
  - south (the bay row): rounded_tower and balcony_stack at H between the one-offs

**Palettes**

- Glass: blue-green (64,110,128), teal (52,104,112), grey-blue (70,88,104), bronze (96,82,66), silver-blue
  (110,140,160), smoke (34,44,54).
- Frames: white (236,236,232), warm white (232,226,214), silver (176,182,188), charcoal (48,52,58).
- Stone: limestone (214,206,186).
- Accents for one-offs only: red (196,44,40), yellow (238,190,40), grid blue (40,96,170).

**Materials**

- Glass with Future-lighting sky reflections.
- Concrete or SmoothPlastic slabs.
- Metal fins.
- Limestone for stone.
- Plaster for stucco at the edges.

**Street level**

- **Royal palms along Main Avenue and Commerce Avenue**, in sidewalk tree pits every 48 studs on both sides, with
  crowns above the road at 30+ studs.
- **Town Square** becomes a bayfront-park plaza: a royal-palm allée round the lawn, a central fountain (basin and jet
  ring, a cyan neon ring at night) and flush paver paths in an X.
- **Block cores** left over after tower claims get a pool deck (CeramicTiles deck, turquoise pool, two or four palms)
  or a parking deck. That is 4..8 parts per block, seen from towers and on approach.
- **Sidewalks** go pale concrete (206,202,194, Concrete) with a lighter kerb. This changes colour only; kerb heights
  and driveway cuts stay.
- **Furniture:** bus shelters on the arterials every ~500 studs, benches, café sets outside storefront_low, two
  kiosks, and ladder crosswalks at the 14 Main and Commerce crossings.
- **Neon at night:** tower crowns (crown), LED balcony edges on some balcony_stack towers (ledBlue, ledMagenta),
  blade signs on storefronts and motels (neonPink, sign cyan, neonAmber).

### 3.2 Beach: South Beach, Ocean Drive, the bay, the causeway

Identity: the north shore road (Lakeshore Drive North, z = 1500) is Ocean Drive. A continuous row of pastel Art Deco
hotels on the land side faces south across the road to a palm park, a sand beach and the bay (the lake). At the lake's
two north corners stand big mid-century resorts. The west road holds waterfront villas, the east road
mid-century motels and the diner, and the south shore a small cluster of slender condo towers.

**Plot sides**

- **Land side** (north of the road, z 1422..1478): hotels. Raise this frontage's occupancy to 0.95 (decision L2).
  Plots stay where they are; only more of them get a building. That gives about 50 hotels instead of about 10.
- **Beach side** (south of the road, z 1517..1578, between the road and the beach): pavilions and kiosks capped at 16
  studs, so the hotels see the water.
- **West road** (x = -1150): waterfront villas.
- **East road** (x = 1150): motels, the diner, the Overlook.
- **South shore and the south avenue** (z = 2850 and beyond): towers up to 240 and low pastel apartments.

**Archetypes**

| Id | Inspiration | Band | Fits | Parts | Silhouette idea | Variation knobs |
|---|---|---|---|---|---|---|
| deco_three_part | symmetric deco hotels with a centre fin rising over a stepped parapet, eyebrow ledges (The Carlyle, The Leslie, The Cavalier) | L 36..54 | 30x25 | 18..24 | three-part facade, centre fin, eyebrows over every window band | pastel body, trim colour, fin height, parapet steps, porch |
| deco_blade | deco hotels with a vertical neon name fin (The Colony, The Breakwater, The Winter Haven) | L 36..54 | 28x25 | 16..22 | blade sign tower with the hotel's name, canopy | body and trim, blade side, sign text, neon kind |
| streamline_corner | Streamline Moderne corner hotels with rounded corners, speed stripes and a corner tower (The Cardozo, The Avalon, Waldorf Towers) | L 36..60 | corner sites, 35x30 | 18..26 | rounded corner (cylinder), three speed stripes, lighthouse cupola | cupola or not, stripe colour, body |
| nautical | nautical deco (Essex House, the beach lifeguard headquarters) | L | 30x25 | 16..22 | porthole windows, mast spire, ship rails | portholes, mast, body |
| tall_deco | the tall deco hotels (The Tides, The Netherland, The Raleigh) | M 96..130 | 40x35 | 22..30 | 8-10 floors in white limestone, vertical fins, setback top with a sign | fins, top, stone tone |
| resort_slab | mid-century resort slabs with a rooftop sign and a swoosh canopy (Deauville, Seagull, Eden Roc) | M 100..150 | 50x40 | 22..30 | slab, folded-plate canopy, rooftop name sign | slab tint, canopy, sign |
| beach_pavilion | beach pavilions, deco kiosks and shower towers (Lummus Park) | ≤ 16 | 20x15 | 6..12 | low pastel kiosk with eyebrows and umbrellas | colour, shape (round, box, porthole) |
| waterfront_villa | island mansions: white modern boxes with pools and palms (Star Island, Venetian Islands) | L 24..36 | 35x30 | 14..20 | stacked white boxes, glass, slat screen, pool | massing mirror, slats, pool side |
| motel_pylon | Collins Avenue mid-century motels (shared with downtown) | L | 30x25 | 10..16 | | |
| pointe_tower | South Pointe condo towers (Continuum, Murano at Portofino) | H 160..240 | 55x45 | 25..35 | slender white tower, bowed glass front, sky deck | bow, tint, crown |
| shore_apartments | South of Fifth low pastel apartments | L 24..36 | 26x22 | 10..14 | catwalk balconies, jalousie bands | palette, catwalk side |

**Palettes**

- Pastel stucco (Plaster): flamingo pink (240,170,180), seafoam (160,220,200), lemon (246,226,140), lavender
  (196,176,226), peach (248,196,160), sky (170,210,236), deco white (244,242,236).
- Trims: teal (40,150,160), coral (236,110,96), violet (120,90,180), deep blue (40,80,150), mint (110,200,170).
- Pairing rule: every hotel is one body colour and one trim colour, and neighbours never share either.

**The beach and the bay**

- **Split the park (decision L3).** Lakefront Park splits into `lakefront_beach`, the north band
  (x -1050..1050, z 1650..1800), and `lakefront_park`, the rest of the ring round the lake.
  - `lakefront_beach` gets Sand ground (232,216,178).
  - The rest stays grass, with palms.
  - The hotspot "Lakefront Park" and every location stay put.
- **Lake as bay.** The water goes turquoise ((64,170,184), transparency 0.35) over a pale sand bed ((214,200,164)
  instead of mud brown), so the shallows read as Biscayne-bay blue.
- **Promenade.** A flush serpentine paver walk runs along the top of the beach (z ≈ 1660), with the low wavy
  coral-stone wall Lummus Park is known for. Both are 0.1-stud decor slabs, nothing a car meets.
- **Ocean Drive walk.** These roads have no raised sidewalk, and adding one would move every lakefront plot 8 studs,
  which is not allowed. Instead each site paves its own front, flush, from 0.5 studs off the road edge to its
  facade, in pastel terrazzo, with café sets on the hotel side. It reads as Ocean Drive's sidewalk with no kerb.
- **Lifeguard stands.** Ten along the beach at z ≈ 1720, about 200 studs apart: 3 shapes (a box hut with a porthole
  and ramp, a round capsule, a boomerang-roof hut) times 10 colourways, each different. Inspired by South Beach's
  lifeguard towers. 10..14 parts each.
- **Beach dressing:** forty umbrella-and-lounger sets near the stands.
- **Seawall:** a coral-stone coping and white rail on the west, east and south shores.
- **Optional marina:** a few piers and four anchored yachts on the south shore.

**The causeway**

The Cedar Lake Bridge and its approaches get the causeway look:

- the arches go white, with their arch night-light kept
- white balustrade railings
- deco lamp posts on the rails, not on the road
- royal palms on both sides of Main Avenue's run south from downtown (z 900..1500) and round both bridge heads

**Palms:** coconut palms, leaning, thick in the beach park (cell 30, chance 0.45). Sabal palms and sea grape in the
rest of the ring.

**Neon at night:** this is the brightest district. Every hotel has a sign or neon trim (neonPink, sign cyan,
neonViolet, neonAmber), plus warm uplights on the parapets (uplight).

### 3.3 Suburbs: Coral Gables and the Miami suburbs

Identity:

- **River Avenue** is the shopping street: low arcaded shops under clay-tile roofs.
- **The side streets and Willow Bend** hold Mediterranean villas, some modern tropical houses and low pastel
  garden apartments.
- **Over the rooftops** rises a bell-towered hotel.
- **Throughout:** live oaks and royal palms, ficus hedges, coral-rock walls.

**Archetypes**

| Id | Inspiration | Band | Fits | Parts | Silhouette idea | Variation knobs |
|---|---|---|---|---|---|---|
| arcade_shops | Miracle Mile arcaded shopfronts | L 20..30 | 26x20 | 10..14 | arcade of arches (dark insets), clay-tile roof edge, awnings | stucco colour, arch count, awning |
| med_villa | Coral Gables Mediterranean revival villas | L 20..30 | 30x25 | 12..18 | hipped ClayRoofTiles roof (wedges), arched loggia, small tower, iron balcony | tower or not, stucco, loggia side |
| tropical_modern | contemporary Miami houses | L 18..26 | 30x25 | 10..14 | white boxes, wood slat screens, flat roof with a deep overhang | massing mirror, slats |
| garden_apartments | 1950s mid-century garden apartments | L 24..36 | 35x25 | 12..16 | exterior catwalks, breeze-block screen, jalousie bands | pastel, screen pattern |
| gables_mixed | Ponce de Leon Boulevard mixed-use: 4-6 storeys, arcades, tile roofs | M 48..72 | 40x35 | 16..22 | arcade base, tile roof, corner tower | colour, tower |

**Where they go**

- River Avenue (arterial): arcade_shops, with gables_mixed on runs of 2+ plots.
- Main Street and Orchard Lane: gables_mixed and arcade_shops.
- Elm Street, Sycamore Lane and Willow Bend: med_villa (55 %), tropical_modern (25 %), garden_apartments (20 %).
- Heights: up to 36 studs, except the one-offs.

**Palettes**

- Stucco (Plaster): cream (236,224,196), ochre (214,180,120), terracotta (196,120,84), rose (226,182,170), sage
  (176,190,160).
- Roof tile (ClayRoofTiles): (176,84,56) and (160,96,64).
- Iron: (40,40,40).
- Coral rock: (210,198,170).

**Street level**

- Royal palms on River Avenue every 48 studs.
- Live oak and sabal groves on the side streets.
- Ficus hedges (long low green blocks) and coral-rock walls along some plot fronts.
- A palm cluster and a small fountain on each cul-de-sac island.
- Buff paver sidewalks (200,184,150). This changes colour only.

**The houses on HousePlots are not part of this pass.** Services/HouseService builds them at runtime from
Config/Houses, with a garage bay and home charger that are gameplay. Restyling them (Mediterranean or modern
tropical) is a separate, later step that keeps every functional offset (decision D6).

### 3.4 Arts: Wynwood and the Design District

Identity: low concrete and brick warehouses covered in murals, sawtooth roofs, a few new loft blocks, sleek boutique
fronts on Plant Avenue, and the Ohm plant with the biggest mural in the county.

**Archetypes**

| Id | Inspiration | Band | Fits | Parts | Silhouette idea | Variation knobs |
|---|---|---|---|---|---|---|
| mural_warehouse | Wynwood Walls warehouses | L 20..32 | 30x25 | 10..18 | concrete-block box, parapet, roll-up door; a geometric mural of 4..8 colour panels on the road face and the sides | mural pattern (stripes, chevrons, discs, blocks), palette, roof |
| sawtooth_hall | north-light factory halls, Wynwood's old garment factories | L 24..36 | 40x35 | 10..14 | three sawtooth roof teeth (wedges and glass), brick base | teeth count, brick or concrete |
| gallery_box | warehouse galleries with a glass-box addition (Rubell Museum, de la Cruz Collection) | L 24..40 | 35x30 | 12..16 | blank box plus a cantilevered glass box | addition side, cladding |
| boutique_screen | Design District boutiques with patterned screen facades (Paradise Plaza) | L 24..40 | 30x25 | 12..18 | glossy white or black box behind a patterned screen of fins | screen rhythm, colour |
| loft_block | new Wynwood mid-rise lofts | M 60..96 | 45x35 | 18..26 | balconies over a mural base | balcony rhythm, mural |
| brick_shop | old brick shopfronts with roll-up doors and tags | L 18..26 | 26x20 | 8..12 | brick box, roll-up doors, painted tags | doors, colour |

**Where they go**

- Plant Avenue (z = 0): boutique_screen, gallery_box, loft_block on runs of 2+ plots.
- North Road, Foundry Road, Assembly Way, Depot Road and South Road: mural_warehouse (40 %), sawtooth_hall (25 %),
  brick_shop (20 %), gallery_box (15 %).
- North Road's 7-plot, 295-stud run at (2301, -750) is the mural row: alternating mural_warehouse and sawtooth_hall,
  each with a different mural, facing the Mesa road.
- Farm Road and Harbor Road: mural_warehouse and brick_shop.
- Height cap 96, set in `City.districts.arts`, up from the zone's 60.

**Murals are part-built**: flat colour panels 0.2 studs proud of the wall, decor only. The patterns come from a
seeded catalogue (stripes, chevrons, a big disc made of a flat cylinder, blocky shapes, a sunburst made of wedges).

- Palette: hot pink (250,60,150), electric blue (40,120,250), yellow (255,214,0), orange (255,120,30), purple
  (130,60,220), cyan (0,210,220), lime (150,230,40), white, black.
- No two murals in a row share a pattern and palette pair.
- Image murals would need uploaded images (decision D3).

**Street level**

- Brick or cobble pavers on the paved lots.
- String lights over 20 lot runs (neonAmber dots).
- Six food-truck props near the Plant Gate.
- A few date palms and sabals, kept sparse (industrial).

### 3.5 Quarry: the Mesa Test Site

Identity: Miami's limestone quarry country west of the city, with an old airfield. The mesas stay exactly as they are
(they are trails, ramps and the summit meet spot), recoloured from desert tan to pale oolite limestone (214,206,184),
with darker bench lines. The ground stays sandy.

- **hangar**: barrel-vault hangars after the Opa-locka airfield hangars. L 20..30, 8..12 parts, on the 6 plots.
- **Mesa Control** (the control_tower landmark) becomes a Moorish revival control building after Opa-locka City Hall:
  white walls, crenellations, two minaret towers and a teal dome over the glass control cab (section 5.3). Its
  footprint and the no-fly volume stay.
- **Drag strip grandstand** (optional), inspired by the Homestead-Miami Speedway stands: one low covered stand beside
  the staging area, clear of the gates and their gantries.
- **Trees:** slash pines and sabal palms in sparse clumps (a new grove for this zone, cell 420, chance 0.2).

### 3.6 Loop: the County Loop and the open country

Identity: a Florida expressway through flat sawgrass country with tree islands.

- **Royal and sabal palm rows** on the loop's inner verge for 600 studs either side of each of the four
  interchanges, every 60 studs (about 80 palms in all).
- **Sound walls.** Tan precast walls with a relief band, on the inner side between 400 and 1,000 studs from each
  interchange and along the Loop Stop's service road. They stay off ramps, pads and billboards, with 60 studs clear
  round each billboard. About 60 parts.
- **Open country.** Fewer trees, grouped in hammocks (about 650 trees instead of 1,289): live oaks, sabals and slash
  pines; no poplars or broadleaf pines.
- **Ground:** the grass shades go a little more yellow-green, toward sawgrass. The edge hills stay, retinted as
  hammock green.
- **Optional (decision L5):** a canal along the outside of the south straight (a thin MapLayout lake, about
  x -2400..2400, z 3480..3540), for the causeway-beside-water feel. The lake system already gives it banks.
- **Optional:** four overhead sign gantries before the interchanges, with original destination names (the zone
  display names). Posts outside the shoulders, the beam above 20 studs.

## 4. Placement rules: the planner

Inputs:

- the plot list from the plot pass (section 8.2)
- MapLayout locations, parks and landmarks
- `City.landmarks` (the one-offs)
- the grid

Output: a list of sites, each with an archetype, a height, a variant and its claimed rects. Everything is pure and
seeded from `MapLayout.seed`.

### 4.1 Occupancy

Today a plot gets a building when its roll is under the zone's density. `City.densityOverrides` may raise or lower
that threshold inside a rect, for example the Ocean Drive land side to 0.95. The roll is drawn either way, so no plot
moves and no later plot changes.

### 4.2 Runs

A run is the occupied plots of one frontage (edge id and side) with no gap. Each run knows:

- its block face (from `findBlocks`)
- its band cap (section 2)
- whether its first or last plot is a block corner: within 30 studs of the frontage's cut end

### 4.3 One-offs first

For each `City.landmarks` entry, in order:

1. Take the run whose centre is nearest the anchor, within its search radius, that is wide enough.
2. Carve the plots nearest the anchor into one site of at least `minWidth`.
3. Mark those plots used.

A one-off that finds no run leaves a note, and notes fail tests/MapBuilder.spec. Anchors below are today's runs.

### 4.4 Sites

The rest of each run is cut into sites by its cap:

| Site | Plots merged | Width | Depth |
|---|---|---|---|
| Tower (T) | 2..4 | ≥ 70 | ≥ 60 with the core claim |
| H | 2 | ≥ 50 | |
| M and L | 1, or 2 when one plot is narrower than 30 | | |

Other rules:

- **Footprint.** A site's buildable rect is the union of its plots' rects: full plot band, front line to 53 studs
  back. Solid masses stand at least 3 studs behind the front line. Entrance canopies and terraces may reach the front
  line.
- **Gaps.** Where two sites meet inside a run, each keeps 2.5 studs back, which keeps today's 5-stud gap.
- **Core claim (deep sites only).** A T or S site may claim a rect behind it, into its block's empty core, up to 110
  studs back from the front line. The claim stays inside the core square: never inside another frontage's plot band.
  It passes the same `LOT_BLOCKERS` grid test plus a 2-stud clearance, and is inserted into the grid (kind `lot`,
  owner = the site) so trees and later claims keep off. If the claim fails, the site falls back to its plot rects and
  a lower band.
- **Corners.** A corner site prefers corner archetypes (streamline_corner, rounded_tower, setback_tower) and may face
  both streets.

### 4.5 Archetype choice

Candidates are the district's archetypes whose band includes the site's band and whose "Fits" the site meets. Each
candidate gets a weight from `City.weights[district][band]`, and the planner draws one from the site's own stream.
Then the rules below apply.

**Neighbours.** A site's neighbours are:

- the sites beside it on the same frontage
- the site directly across the street (the opposite frontage, overlapping along the road)
- the first site round each corner

Two neighbours never share an archetype. Across the street, the same archetype is allowed only with a different
palette and a height at least 25 % different.

**Repeats**

- An archetype appears at most twice in a block.
- A tower archetype (T) appears at most 6 times in the whole map.
- An archetype appears at most 18 % of its district's sites, or 6, whichever is larger.

**A repeat must look different.** Every built site has a look key: archetype, palette, crown, rhythm. A look key is
never used twice in the map. Each repeat changes the palette and at least one more knob:

- height ±10..25 %
- mirror (flip along the road)
- crown variant (each archetype has 3..4)
- rhythm (fin spacing or balcony interval)
- podium variant (storefront, arcade, screen)
- corner treatment

**Relaxing.** When nothing fits, the rules relax in this order, and a note is left after the third step:

1. palette
2. crown
3. allow the same archetype across the street
4. a plain fallback for the band

### 4.6 Heights

- Draw a height within the site's band, under its block cap, scaled by its place in the run (the tower end tallest).
- Snap to the district's floor height: 12 downtown, 12 beach (16-stud ground floor), 11 suburbs, 14..18 arts.
- Push T and S heights apart to meet the no-twin rule.
- One-offs use their listed height.

### 4.7 Determinism

- Sites are processed in a stable order: edge index, side, position along the road.
- Each site's random stream is `mixSeed(seed, shade, index)` of its first plot, as today.
- Building the map twice gives the same parts. MapCheck compares the instance counts of two builds, and
  tests/MapBuilder.spec compares two plans.

## 5. One-off landmarks

These are built once each and listed in `City.landmarks`. Each entry has an id (also the model name), an archetype
module, an anchor (x, z) with a search radius of 120, minWidth, minDepth, height, and an optional "show face": the
side its feature faces when that differs from its road, such as the spawn or the bay.

The anchors below are today's real runs; the run centre and width were measured on 2026-10-25.

### 5.1 Downtown

| Id | Inspiration (docs only) | Anchor (x, z) and run | Height | Model notes |
|---|---|---|---|---|
| spire | Panorama Tower | (150, -65): block d3's south frontage on Commerce Ave, 5 plots, 202 wide, plus a core claim into d3 | 560 | the tallest; slab with blue glass and white vertical fins on the long faces, slab bands every 4 floors, notched corners, glass podium with a canopy, lit crown; 40..55 parts |
| tiered_tower | Miami Tower (stepped semicircular tiers lit in colours) | (468, 60): block e4's north frontage on Commerce Ave, 4 plots, 170 wide, plus core claim | 440 | show face south, toward the spawn and the bay: three half-cylinder tiers stepping back, each tier's rim a different neon colour at night (ledBlue, neonPink, ledTeal), a mast; 28..36 parts. It is straight ahead of a new player at the spawn, about 300 studs away |
| exoskeleton | One Thousand Museum (curving white exoskeleton) | (64, -447): block d2's west frontage on Main Ave, 4 plots, 129 wide, plus core claim | 500 | the north peak; glass core with four white corner piers that fork at the base and curve in at the crown, made of tapered wedge runs; 40..50 parts |
| crown_tower | Four Seasons Hotel Miami | (115, 856): block d6's south frontage, 4 plots, 153 wide, plus core claim | 470 | slender, chamfered corners, a stepped crown of four lit fins and a mast; the first tall tower seen from the bridge; 35..45 parts |
| sky_court | The Atlantis (sky-court hole with a palm, red spiral stair, red triangle, yellow triangular balconies, blue grid) | (-164, 945): the bay row (south outer frontage), 5 plots, 205 wide | 230 | long slab facing the lake; a square hole through it at mid-height with a palm and a red spiral stair inside, a blue grid facade, yellow triangular balconies on one end, a red triangle on the roof; 35..45 parts |
| staircase | The Palace (stepped staircase slab) | (-451, 940): bay row, 6 plots, 241 wide | 260 | slab whose top steps down in 8..10 stairs toward one end, with a contrasting low block cutting through its base; 20..28 parts |
| ziggurat | Babylon (red stepped condo) | (119, 943): bay row, 4 plots, 147 wide | 130 | six red stepped tiers with glass bands; 14..18 parts. Sits right in front of crown_tower |
| sail | Aston Martin Residences (sail-shaped tower) | (783, 950): bay row, 4 plots, 155 wide | 400 | plan-view lens of faceted glass slabs, a white spine, a tapering top; 30..40 parts |
| cupola_tower | Freedom Tower (Mediterranean revival, buff stucco, ornate cupola) | (66, -190): block d3's west frontage on Main Ave, facing Town Square across the avenue | 170 | buff Plaster tower, arched dark window insets, tiered cupola with a lantern, two low wings with tile roofs, floodlit; 30..38 parts |
| courthouse | Miami-Dade County Courthouse (limestone tower with a stepped pyramid top) | (-66, 530): block c5's east frontage on Main Ave, beside the Courthouse hotspot (-48, 450) | 270 | limestone setbacks to a stepped pyramid with a beacon, a colonnade base; 30..38 parts |
| theatre | Olympia Theater and Tower Theater (palazzo with a vertical blade marquee) | (525, -548): block e2's north frontage, east of the Theater Row hotspot (450, -567) | 70 | palazzo box, arched entry, a vertical blade sign reading THE CIRCUIT, a marquee canopy with lights; 18..24 parts |
| market_hall | Bayside Marketplace (two-storey open-air arcade with a big sign) | (-548, -370): block b2's west frontage, north of the Market Street hotspot (-567, -450) | 36 | two-storey arcade of columns, roof terrace, a big sign reading CEDAR BEND MARKET; 22..28 parts |
| led_hotel | InterContinental Miami (a facade that becomes a giant light display at night) | (741, -58): block f3's south frontage on Commerce Ave, 4 plots, 165 wide | 300 | slab whose road face carries an LED palm-and-wave picture in neon parts at night, seen arriving from The Plant; 30..40 parts |
| ribbon_mall | Brickell City Centre (two slanting towers over a shopping podium under a woven "climate ribbon") | (130, 251): block d4's south frontage, 5 plots, 172 wide, near the spawn street | 330 and 300 | three-storey shop podium, a ribbon canopy of 8..10 angled slats over its courtyard (inside its own site, never over a road), two towers slanted by stepped offsets; 55..70 parts |
| sawtooth_tower | Southeast Financial Center (dark glass, sawtooth stepped top, glass atrium) | (732, -347): block f2's south frontage, 5 plots, 208 wide, plus core claim | 380 | dark glass, a sawtooth crown of stepped wedges, a glass atrium with a steel frame and palms; 28..36 parts |

That is 4 supertalls (560, 500, 470, 440) and 8 talls (400, 380, 330 and 300 as one twin, 300, 270, 260, 230).

### 5.2 Beach, suburbs, arts

| Id | Inspiration | Anchor (x, z) | Height | Notes |
|---|---|---|---|---|
| curve_resort | Fontainebleau (curved mid-century slab) | (1106, 1569): the two east-road plots at the lake's north-east corner | 150 | a slab in 5..6 facets following a quarter curve, cabanas, a swoosh canopy, a rooftop name sign |
| sign_slab_resort | Eden Roc and Deauville | (-1188, 1500): the plots round the lake's north-west corner | 120 | slab with a big rooftop name sign, folded-plate porte-cochère |
| courtyard_mansion | Casa Casuarina (the Versace mansion) | (-414, 1460): Ocean Drive's land side | 40 | three-storey stone villa round a courtyard, a corner tower, barrel tile roofs, a mosaic pool deck |
| lifeguard_hq | the beach lifeguard headquarters (a streamline building shaped like a ship) | (98, 1541): beach side, east of the bridge head | 20 | ship-like curved pavilion, portholes, a mast with flags |
| tall_deco_one | The Tides | (620, 1460): Ocean Drive's land side | 120 | the tallest deco hotel on the strip |
| lighthouse_corner | Waldorf Towers | the land-side corner plot nearest (-1000, 1460) | 54 | round corner tower with a lighthouse cupola |
| bell_tower_hotel | Biltmore Hotel (Giralda-style tower over a long Mediterranean hotel) | (-2363, -65): River Avenue's north side, rv_main to rv_ave_w, 3 plots, 110 wide | 130 | long tile-roofed hotel wings and a stepped bell tower with a lantern, floodlit; seen across the suburbs |
| colonnade_hall | Coral Gables City Hall (semicircular colonnade and clock tower) | (-1918, -62): River Avenue's north side, rv_ave_e to rv_main, 3 plots, 109 wide, just west of the Riverside Market hotspot (-1800, -48) | 60 | curved colonnade front (columns on an arc), clock tower |
| mission_church | Coral Gables Congregational Church (Spanish mission bell tower) | (-1580, 445): Elm Street's south side, 2 plots, 82 wide (the north side holds house plots) | 70 | mission facade with a curved gable and a bell tower |
| art_garage_stack | Museum Garage (each facade by a different designer) | (2352, 53): Plant Avenue's south side, pl_depot to pl_assembly, 6 plots, 216 wide | 72 | four facade panels side by side, each wildly different: a car-stack cut-out, puzzle blocks, a cartoon panel, a coloured fin field |
| mural_court | Wynwood Walls (an open courtyard of mural walls) | (2015, -56): Plant Avenue's north side, pl_foundry to pl_depot, 4 plots, 143 wide, east of the Plant Gate hotspot | 24 | a low entry building and 4..6 freestanding mural walls round a courtyard, with string lights |

### 5.3 Restyled MapLayout landmarks

The footprint, yaw and position stay. The parts stay inside the MapLayout footprint (signs and domes may rise above
it). Grid inserts stay as they are.

| Landmark | New look, after |
|---|---|
| dealership_showroom (Cedar Bend Motors, 140x100x30) | a luxury car pavilion: full-height glass under a floating white roof slab, a palm courtyard, and a glass display tower of stacked platforms at one corner (after the car-lift tower idea of Miami's Design District showrooms) |
| used_lot_office (60x30x14) | a Googie car-lot office: butterfly roof, angled pylon sign reading USED LOT, neon at night |
| ohm_factory (900x450x60) | a white metal EV plant: sawtooth roof rows with glass, solar strips on the roof, a glass visitor corner, truck docks, and a 900-stud mural on the face toward Plant Avenue (the south face, z = -125, 125 studs from the avenue). Its roof sign (signBrand) stays |
| design_studio (300x250x40) | ICA Miami: a faceted metal facade of triangulated panels (wedges) over a glass ground floor, with a sculpture garden |
| freight_warehouse (360x330x36) | a mural warehouse with loading docks |
| tow_yard_shop (120x100x24) | a tagged garage with roll-up doors and a neon TOW sign |
| mesa_control (300x80x24) | the Moorish control building of section 3.5 |

### 5.4 Restyled features

- The Overlook Diner becomes a 1940s stainless railcar diner, after the 11th Street Diner: a long barrel roof (a
  cylinder half sunk into the roof), a neon stripe, the DINER sign kept.
- The water tower gets suburb colours.
- The bridge arches go white.
- New scenery, built from `City.scenery` with grid checks, not MapLayout:
  - the suburb gateway pillars, after the coral-rock Granada and Douglas entrances, beside River Avenue at its east
    end (about x -1530)
  - the Town Square fountain
  - the lifeguard stands

## 6. Trees and palms

New species shapes go in MapBuilder's TUNING:

- A trunk may be a cylinder, with a lean, in one or two segments.
- Leaves get a pitch and an offset, so fronds droop.

| Species | Shape | Parts | Where |
|---|---|---|---|
| royal_palm | smooth grey-white column trunk, green crownshaft, 4 arching fronds | 6 | downtown and suburb avenues, Town Square allée, the causeway, loop interchanges |
| coconut_palm | slender leaning trunk in 2 segments, 3 crossed drooping fronds | 5 | the beach park, Ocean Drive, the lake ring |
| sabal_palm | rough trunk, a round fan crown of 2 crossed blocks | 3 | the suburbs, the country, the quarry, the loop |
| date_palm | thick trunk, big round crown | 5 | plazas, landmark entries, the arts district |
| live_oak | short trunk, two wide flat canopies | 3 | the suburbs, the country hammocks |
| slash_pine | tall thin trunk, two flat high canopies | 3 | the country, the quarry |
| sea_grape | low round shrub-tree | 2 | the beach dunes, the lake ring |

Street palms are the palms in sidewalk pits and on verges. They are a new role, `streetscape`:

- Their trunks may stand on a sidewalk's outer half.
- Their fronds may hang over the road above 20 studs.

Grove trees keep today's rules (16 studs from a road edge or sidewalk).

The parks get layouts:

- town_square: an allée grid of royal palms round the fountain lawn
- lakefront_beach: coconut palms, cell 30, chance 0.45
- lakefront_park: mixed palms and sea grape, cell 30, chance 0.3

| Grove | Cell | Chance | Mix |
|---|---|---|---|
| suburbs | 240 | 0.55 | live oak 0.4, royal 0.25, sabal 0.2, date 0.15 |
| beach | 260 | 0.5 | coconut 0.5, sea grape 0.3, sabal 0.2 |
| arts | 400 | 0.25 | date 0.4, sabal 0.3, live oak 0.3 |
| quarry (new) | 420 | 0.2 | slash pine 0.5, sabal 0.5 |
| loop | 420 | 0.35 (0.45 past 3,500) | sabal 0.4, live oak 0.3, slash pine 0.3 |

Count rules: `minTrees` goes to 1,100 and `maxTrees` to 1,600, for about 1,350 trees. Planting still stops at the tree
budget, filling parks and towns first and the country last.

## 7. Night look

### 7.1 New night-light kinds

These go in `Environment.nightLights.kinds`. DayNightService already looks up any kind there, so no service change is
needed.

| Kind | Night colour | Used for |
|---|---|---|
| neonPink | (255, 64, 160) | deco signs, motel pylons |
| neonViolet | (150, 80, 255) | deco trim, beach signs |
| neonAmber | (255, 160, 48) | storefront blades, arts district string lights |
| crown | (236, 240, 255) | tower crowns and lanterns |
| ledBlue | (60, 130, 255) | balcony edge strips, tiered_tower tier |
| ledMagenta | (230, 50, 210) | balcony edge strips, led_hotel picture |
| ledTeal | (50, 220, 200) | tiered_tower tier, fountain |
| uplight | (255, 220, 170) | warm parapet washes on deco hotels, cupola_tower, courthouse |

The existing kinds stay (streetlight, window, sign, floodlight, beacon, arch). Lit windows keep today's split-glass
trick.

Rule: neon only. Buildings add no new PointLight or SpotLight instances; only streetlights carry Lights.

Budget: at most about 1,400 night-light parts in all. DayNightService flips 200 per frame, so dusk takes about 7
frames.

### 7.2 SLIM-safe structure

SLIM (Model.LevelOfDetail = SLIM) keeps a building visible past the streaming radius as a cheap composite. It also
cuts draw calls up close. But it **breaks on models whose parts change at runtime**, and night lights change material
and colour at dusk.

So every model is one of two kinds:

- **Still models: SLIM.** Plain geometry only: Buildings/... and Landmarks/..., plus Trees and Streetscape tiles. They
  hold no NightLight-tagged part, no SurfaceGui labels, no AdGui and no Light.
- **Light models: not SLIM.** Everything that switches or carries text goes here: lit glass, neon strips, signs.
  Folders are `BuildingLights/<district>/Tile<x>_<z>` and `LandmarkLights/<id>`, Atomic. The landmark roof sign and
  its light bar move here.

### 7.3 The Skyline model

`Skyline` is a Persistent Model of at most 200 parts. It holds the main masses (glass core and crown) of every S and T
building and the bay-row one-offs, with their crown neon. The details (fins, slabs, podiums) stream as usual.

This keeps the skyline visible from the bridge and the lake even without SLIM. The spire, for example, is 2,240 studs
from the middle of the bridge, past the 2,048-stud streaming target, and would otherwise vanish. With SLIM the whole
tower shows.

### 7.4 Sign text and fonts

Sign text is invented and on-theme. Pool in `City.signNames`:

| Use | Names |
|---|---|
| Hotels | VOLTAMAR, THE AMPERE, SEAVOLT, CORAL CURRENT, OHMHAVEN, LUMEN BAY, THE DYNAMO, TIDEWATT, PALMVOLT, SOLMAR, AZURE AMP, THE CAPACITOR |
| Motels | WATTS END, SPARK MOTEL, THE ROTOR |
| Landmarks | THE CIRCUIT (theatre), CEDAR BEND MARKET, USED LOT, TOW, DINER |

Davis may veto any name (decision D5).

Fonts, none on the banned list:

- JosefinSans for beach deco
- Michroma for downtown
- Merriweather for the suburbs
- PermanentMarker for the arts district

LabelSpec gains a `font` field.

## 8. Integration with Dev/MapBuilder

### 8.1 Modules

| File | What it is |
|---|---|
| `src/shared/Config/City.luau` | districts by zone, bands, block caps, density overrides, palettes and materials, archetype weights and repeat limits, `landmarks` (the one-offs), `scenery` (fountain, gateway, lifeguard stands, sound walls), sign names, budgets |
| `src/server/Dev/City/Planner.luau` | pure: plots in, sites out (sections 4.1..4.7) |
| `src/server/Dev/City/Kit.luau` | pure shape helpers that emit PartSpecs (8.4) |
| `src/server/Dev/City/Archetypes/<district>/<id>.luau` | one module per archetype or one-off: `{ id, district, bands, minWidth, minDepth, corner, budget, crowns, build(site, kit) }` |
| `src/server/Dev/City/Streetscape.luau` | street palms, furniture, block-core decks, the beach, promenade, seawall, lifeguard stands, sound walls, the Town Square layout |
| `src/server/Dev/City/CityBuilder.luau` | runs the planner, calls each site's archetype, places the Skyline masses, checks every site's parts against its budget and its rects |
| `src/server/Dev/MapParts.luau` | MapBuilder's part helpers moved out so the city modules can use them without a circular require: `block`, `wedge`, `cylinder`, `decor`, `nightLight`, `add`, `container`, `note`, `mixSeed`, `lift`, `planAt` |

### 8.2 The hook

`addBuildings` keeps its loop line for line: the same draws, `usable()`, grid inserts and paved lots. It differs only
in two places:

- the density test reads `City.densityOverrides`
- where it called `addBuilding`, it appends a Plot record

At the end it calls `CityBuilder.addSites(ctx, plots)`.

```lua
export type Plot = {
	index: number, -- today's building number (stable)
	edgeId: number, side: number, frontage: string, face: number, -- block face from findBlocks
	along: number, width: number, -- plot start and width along the road
	setback: number, depth: number, tall: number, shade: number, -- today's draws, kept for fallbacks
	zone: ZoneData, rect: Rect, -- the full plot rect (front line to plotDepth back)
	u: Vector2, front: number, -- road direction and front line offset
}
```

Order in `planWith`: addLandmarks (now restyled through CityBuilder's landmark archetypes), ..., addParks,
addBuildings (plots, then sites), **addStreetscape**, then addTrees, so trees keep off furniture and core claims.

### 8.3 What an archetype gets

```lua
export type Site = {
	id: string, -- "B<index>" of its first plot; part names start with it
	district: string, zone: ZoneData,
	frame: CFrame, -- footprint centre on the ground; local X along the road, local -Z toward the road
	width: number, depth: number, -- buildable size in that frame (plots ∪ core claim)
	rects: { Rect }, -- what it may build on: its plot rects and any core claim
	height: number, band: "L" | "M" | "H" | "T" | "S",
	roadKind: string, corner: { left: boolean, right: boolean }, -- open to a cross street at that end
	face: number, -- block face, for neighbour rules
	seed: number, -- mixSeed(layout.seed, shade, index): its own random stream
	variant: { palette: string, crown: number, rhythm: number, mirror: boolean, podium: number },
	folder: string, -- still geometry: Buildings/<district>/Block<n> or Tower<id> (SLIM, Atomic)
	lightsFolder: string, -- BuildingLights/<district>/Tile<x>_<z> (Atomic, not SLIM)
	skyline: boolean, -- S and T: main masses go to Skyline (Persistent)
	budget: number, -- parts it may use
}
```

Buildings in band H and up get their own Model (`Tower<id>`), so all of a tower switches detail together under SLIM.
Low and mid sites share block-tile Models, as today.

### 8.4 The kit

The kit is pure. Every helper takes the site frame and local coordinates (front at -Z) and returns PartSpecs:

- `slab(y0, y1, inset)`
- `litGlass` (today's split-glass night light)
- `bands(every, proud)`
- `fins(face, spacing, depth)`
- `roundedPrism(radius)`, built from 2 boxes and 4 corner cylinders
- `tiers(steps)`
- `halfCylinderBay`
- `taperRun` (a wedge sequence)
- `hipRoof(tileMaterial)` (wedges and corner wedges)
- `archRow` (dark insets with arched heads)
- `awning`, `eyebrow`, `canopy`
- `bladeSign(text, font, kind)`
- `neonStrip(kind)`
- `muralPanels(pattern, palette)`
- `roofClutter`, `poolDeck`, `frontPaving`

**Sharpness rules the kit enforces:**

1. **No coplanar faces.** Every flush face is offset at least 0.05 studs; glass is set in 0.6, bands stand 0.2..1.5
   proud. Coplanar faces z-fight, in SLIM too.
2. **A plinth.** Every building has a 1..2-stud plinth or dark base band, so it never floats.
3. **An entrance.** Every building has a recessed entrance with a canopy on its road face.
4. **Real proportions.** Floor heights from the district (12 studs), fins every 8..12 studs, mullions never thinner
   than 0.4.
5. **Masses and decor.** Masses collide and cast shadows. Decor under 2 studs thick (fins, slab edges, trims,
   murals, fronds) is `decor()`: no collide, no raycast, no touch, no shadow.
6. **Inside the rects.** Every part's box, turned, stays inside the site's rects. A canopy may reach the front line,
   never past it.
7. **One silhouette idea per archetype**, readable at 70 mph: a crown, a notch, a curve, a hole, a step.

### 8.5 What stays from today's facade code

| Today | Becomes |
|---|---|
| plot pass, `usable`, `LOT_BLOCKERS`, `inflate`, `findBlocks`, block tiling | kept as is |
| paved lots under runs | kept, coloured per district |
| `addBuilding`'s slab helper | `Kit.slab` |
| the lit-glass split | `Kit.litGlass` |
| the roof box | `Kit.roofClutter` |
| TUNING insets (glassInset, bandInset, parapetHeight, towerPier, bury) | kit constants in `City.kit` |
| `Environment.facades` | retired; floor heights and lit shares move to `City.districts` |
| `addBuilding` | removed. A temporary `legacy` archetype rebuilds today's facade exactly, so step 1 can land with no visual change and the specs green |

### 8.6 Folders and streaming

| Folder | Kind | LOD |
|---|---|---|
| Ground, Roads | Persistent | — |
| Skyline | Persistent, ≤ 200 parts | — |
| Buildings/<district>/Block<n>, Tower<id>, <oneOffId> | Atomic | SLIM |
| Landmarks/<id> | Atomic | SLIM |
| Trees/Tile<x>_<z>, Streetscape/Tile<x>_<z> | Atomic | SLIM |
| BuildingLights/..., LandmarkLights/<id>, Features/<id> | Atomic | — |

Supporting changes:

- `Container` gains `lod: Enum.ModelLevelOfDetail?`, and `build()` sets it.
- SLIM needs the place published with Team Create on (decision D1). Without that, SLIM quietly falls back to normal
  streaming and the Skyline model carries the skyline.

## 9. Budgets

| Group | Today | Plan |
|---|---|---|
| Roads, junctions, paint (Persistent) | 2,361 | 2,361 |
| Ground and water | 238 | ~280 (beach split, sand) |
| Sidewalks | 850 | 850 (recoloured) |
| Bridges | 44 | ~60 (balustrade, lamps) |
| Locations, props, display pads, signs, spawns, billboards | 407 | 407 |
| Streetlights | 1,200 | 1,200 (restyled, same posts) |
| Paved lots | 214 | ~260 |
| Features | 70 | ~150 |
| MapLayout landmarks (restyled) | 20 | 700 |
| Downtown one-offs | — | 1,200 |
| Downtown repeatables | 4,358 | 7,600 |
| Beach | 220 | 2,100 |
| Suburbs | 339 | 1,500 |
| Arts | 565 | 1,600 |
| Quarry | 14 | 120 |
| Trees (role tree) | 4,581 | 4,200 |
| Streetscape (street palms ~1,000, furniture, beach, decks, sound walls) | — | 2,600 |
| Skyline masses (Persistent) | — | 200 |
| **Total** | **15,485** | **≈ 27,400** (hard cap 30,000) |

Night-light parts (about 1,400) sit inside their district budgets.

New `Environment.budget`, replacing the single `buildingParts`:

| Key | Value |
|---|---|
| mapParts | 30,000 |
| treeParts | 4,200 |
| streetscapeParts | 2,600 |
| skylineParts | 200 |
| districts | downtown 8,800, beach 2,100, suburbs 1,500, arts 1,600, quarry 120 |
| landmarkParts | 700 |
| featureParts | 200 |
| groundParts | 700 |
| nightLightParts | 1,400 |
| **inViewParts** | **20,000** |

**inViewParts** is the phone gate: the most parts a player can have streamed in at once. It is the parts within
`Perf.streaming.targetRadius` (2,048) of any road node, plus every Persistent part. The worst place is downtown's
centre, where the whole of downtown and about 40 % of each neighbouring district are in range. The estimate is about
19,500, against the 5,100..5,550 the phase 14 perf drive measured at a steady 60 fps on desktop. That is why the
budget leans on four levers:

1. SLIM composites, which cut draw calls inside the radius too
2. decor parts that never collide, take a raycast or cast a shadow
3. Opportunistic stream-out (already set)
4. this gate failing the build before a phone does

Davis's real-phone check after the downtown step decides whether 20,000 holds.

## 10. What the checks keep checking

Dev/MapCheck is unchanged and must pass: two builds give the same count, no road overlaps, every location built with
its tag and attributes within reach, every node reachable, routes under 5 ms, night-light kinds known, every feature
built, the tree count noted, Ground and Roads Persistent. It also notes parts per district and the Skyline count.

tests/MapBuilder.spec keeps:

- road surfaces flush, no gaps or lips, no road overlaps
- every part under the size limit and inside the map
- buildings, lots and streetscape off roads, junction pads, sidewalks (streetscape excepted), locations, landmarks and
  display pads
- the auto mall block clear of buildings
- every pad's way to its road with nothing a car can't drive over
- no buildings or lots in parks (the beach park included)
- hills and features where MapLayout puts them
- every location with one part, its tag, DisplayName and Zone
- at most one emitting streetlight per 200 studs
- night lights tagged with known kinds, built in their day look with their lights off

Changed or new checks in tests/MapBuilder.spec:

1. Budgets: every key of the new `Environment.budget`, including the inViewParts gate.
2. Every building site is a known archetype with:
   - at least one Glass part (warehouses and hangars may use window insets instead)
   - a roof or crown part
   - its parts inside its rects
   - a height inside its band
   - a part count within its archetype's budget

   At least 40 % of sites have lit windows. This replaces "glass, floor bands or piers and a roof edge".
3. Every `City.landmarks` one-off is built exactly once, and the plan leaves no notes.
4. No two neighbouring sites share an archetype, and no look key is used twice.
5. No SLIM container holds a NightLight-tagged part, a label, an ad unit or a Light.
6. Skyline is Persistent and within its budget.
7. Streetscape stays off carriageways, junction pads, driveway cuts and pad exits. Street-palm fronds over a road are
   at least 20 studs above it. No streetscape item stands within 2 studs of a streetlight post.
8. Trees: the new species. Trunks collide; fronds and leaves never collide, take a raycast or a touch.
9. Containers: Buildings/, Trees/, Features/, Streetscape/, BuildingLights/ and LandmarkLights/ are Atomic.

New tests/City.spec covers the pure planner with small fixtures:

- the same plan twice
- runs and site carving
- core claims staying inside the core
- one-off claims finding their runs
- the repeat and neighbour rules
- heights in band and the no-twin rule
- each archetype built on a sample site within its budget and rects

The name gate: append the inspiration names that are not everyday words to `scripts/banned-names.txt` under a new
header. Candidates:

> Fontainebleau, Eden Roc, Carlyle, Cardozo, Biltmore, Versace, Casa Casuarina, Freedom Tower, Brickell, Wynwood,
> Coral Gables, Ocean Drive, South Beach, Opa-locka, Lummus, InterContinental, Four Seasons, Aston Martin, Hadid,
> Arquitectonica, Bayside, Miracle Mile

That way `scripts/check` refuses them in `src/` and `tests/`. Everyday-word names (Atlantis, Palace, Babylon, Colony,
Tides, Avalon, Panorama) are kept out by using neutral ids, and by review.

## 11. Work order for the build steps

Each step lands green on tests/MapBuilder.spec and Dev/MapCheck.

| Step | Work |
|---|---|
| 1 | `City.luau`, `MapParts`, Planner, Kit and CityBuilder, with the `legacy` archetype. No visual change. Budgets and new checks wired. |
| 2 | Downtown one-offs: spire, tiered_tower, exoskeleton and crown_tower first (the spawn view and the bridge view), then the rest of section 5.1. |
| 3 | Downtown repeatables, block caps, core claims, the Skyline model, street palms on Main and Commerce, Town Square, block-core decks, sidewalk colour. |
| 4 | Beach: park split, sand, water colour, promenade, Ocean Drive paving and density, hotels and one-offs, lifeguard stands, causeway dressing, diner restyle. |
| 5 | Suburbs: archetypes, one-offs, gateway, hedges and walls, River Avenue palms. |
| 6 | Arts: archetypes, murals, Ohm plant and the other MapLayout landmark restyles, art_garage_stack, mural_court. |
| 7 | Quarry and loop: hangars, Mesa Control, mesa recolour, palm rows, sound walls, country hammocks, the new tree species. |
| 8 | Night pass: new kinds and neon, SLIM flags, the inViewParts gate tuned. Then the roast. |

## 12. Decisions

### For Davis

| | Decision | Recommendation |
|---|---|---|
| D1 | Turn on Team Create and publish the place. SLIM (distant buildings stay visible as cheap stand-ins) needs both. Without it, the plan still works: the tall towers' main shapes stay loaded, but distant details vanish. | Yes |
| D2 | Keep the zone names (Cedar Bend, Riverside, The Plant, Lakefront, Mesa Test Site) or rename them to new Miami-flavoured ones. Renaming changes GPS and place names players see. | Keep for now |
| D3 | Allow a handful of original images (window grids, real mural art) uploaded to his Roblox account, for sharper facades and real murals. | Not needed for this pass; parts only by default |
| D4 | The tallest tower is 560 studs (about 46 floors). Taller is a number change. | 560 |
| D5 | Hotel and sign names are invented EV puns (VOLTAMAR, THE AMPERE, SEAVOLT...). | Keep; veto any he dislikes |
| D6 | Restyle the claimable houses (Mediterranean and modern tropical) in a later step. Their garage door and home charger stay where they are. | Yes, as a separate step after the buildings |

### For the lead (not Davis)

| | Decision |
|---|---|
| L1 | Towers merge neighbouring plots of one run and the tallest claim part of their block's empty core. No plot moves; every claim passes the same clear-checks. This is the only way to give Brickell towers real girth. |
| L2 | `City.densityOverrides` raises occupancy on Ocean Drive's land side to 0.95, for a continuous hotel row. The same plots, just more of them built. |
| L3 | MapLayout.parks: split Lakefront Park into a sand beach band and the rest of the ring. |
| L4 | Environment budgets: mapParts goes from 16,000 to 30,000. Tree count goes from about 1,700 to about 1,350, with fewer in the open country and more palms in town. inViewParts 20,000 is the new phone gate. |
| L5 | The optional canal along the south straight (a MapLayout lake) and the optional loop sign gantries. |
| L6 | Extend `scripts/banned-names.txt` with the inspiration names (section 10). |
