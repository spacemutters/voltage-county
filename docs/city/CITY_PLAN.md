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

One-offs are exempt. An asterisk means the block holds a one-off or a gameplay spot (section 5). Updated 2026-10-25
for the heights in ARCHETYPES.md: the repeatable towers there are 260..490 studs, so the tower blocks are capped at
300..520 (d4 stays at 380 under the twin ribbon towers by the spawn street). The live numbers are
`Config/City.heightCaps`.

```
          a        b        c         d          e           f
row 1   M 140    H 200    T 300     S 420      T 320       H 200
row 2   H 160    T 260    S 440     S 500*     S 460       T 320*
row 3   M 150    T 300    (park)    S 520*     S 480       T 360
row 4   H 160    T 320    S 460     T 380*     S 480*      T 340
row 5   M 130    H 220    T 400*    S 420      L 60* spawn L 70* showroom
row 6   M 140    T 260    S 420     S 460*     T 260       (auto mall)
outer   north L 60 (motel row) | west L 54 (bright storefront row) | east M 96 (garages, lofts) |
        south: the bay row, H 240 between its one-offs
```

Rules on top of the caps (all in `Dev/City/CityBuilder`):

- **Tower slots** (`City.slots`). A block whose cap reaches band T holds one repeatable tower (band T); a one-off that
  tall takes that slot. A downtown block holds at most two H sites. Once a slot is taken, the rest of the block is
  capped under that band.
- **Low near gameplay spots.** A site within 40 studs of a MapLayout location's footprint is capped at 160
  (`nearSpotCap`). This keeps the charging plaza, the used lot, the fuel station and the depots open to the eye.
- **Tower site in a run.** Each tower slot takes the window of free plots nearest a skyline peak (`City.towers.peaks`:
  Main and Commerce, and the north peak). The rest of its run steps down to at most 60 % of the tower
  (`rules.stepDown`).
- **No twin heights.** No two T or S buildings within 600 studs of each other are within 24 studs (two floors) of the
  same height. Later ones move inside their own height range (`rules.twinRange`, `twinGap`).

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

Which building types stand where (updated 2026-10-25). The building types and their ids are `ARCHETYPES.md`'s
(T01..T18, B01..B12, R01..R08, W01..W05, C01..C09); the older ids this plan used first (balcony_stack, fin_tower,
motel_pylon, deco_three_part, med_villa, sawtooth_hall...) are retired. Placement and the live
numbers are in `Config/City` (`areas`, `landmarks`, `heightCaps`) and `Config/CityArchetypes/<id>` (each type's
sizes, heights, copies and budget).

- Each district draws its own types (an archetype's `district`). An **area** (`City.areas`) can mix in other
  districts' low and mid-rise types, weight by weight, so a low block is never an old box: downtown borrows motels,
  garden apartments, townhouse rows, arcades and garages.
- One-offs (section 5) are placed first at their anchors, then one repeatable tower per tower block, then the rest.
- Every archetype composes the shared kit (section 8.4).

### 3.1 Downtown: Brickell and Downtown Miami

Identity: big glass towers on street podiums. White balcony slabs stack up blue-green glass. Fins catch the sun.
Pool-deck crowns, lit tops at night. At street level, shops and palms. On the edges, mid-century motels and bright
storefronts.

**Types (ARCHETYPES.md ids)**

| Where | Types |
|---|---|
| Tower slots (band T, one per tower block) | T06 standard_glass_slab, T07 flatiron_wedge_tower (corners only), T10 telescope_tower, T13 cantilever_slab_tower, T14 fin_column_tower, T15 parallelogram_void_tower, T17 car_lift_cylinder_tower |
| H sites (two per block) | T08 sky_court_slab, T09 stair_wing_slab, T11 twisting_twin_towers, and the lower copies of the tower types |
| Mid and low (the rest of a block, area `downtown`) | T18 tiled_mural_midrise; mixed in: R05 red_ziggurat_lowrise, W04 sculpted_car_park, W03 collage_parking_garage, R08 mosaic_townhouse_row, R07 mimo_garden_apartment, B11 mimo_truss_motel, B12 arcade_village_street |
| North outer frontage (area `downtown_north`, cap 60) | B11 mimo_truss_motel (the Biscayne Boulevard motel row), R07, B12, R08 |
| West outer frontage (area `downtown_west`, cap 54) | B12 arcade_village_street, R08, R07, W01 mural_warehouse (the Little Havana storefronts and murals) |
| East outer frontage (area `downtown_east`, cap 96) | W03 collage_parking_garage, W04 sculpted_car_park, W01, W02 faceted_gallery |
| Bay row (area `bay_row`, cap 240) | the bay-row one-offs (section 5.1), then H towers and R05 between them |
| One-offs | T01, T02, T03, T04, T05, T12, T16, C01, C02 (section 5.1) |

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
- **Neon at night:** tower crowns (crown), LED balcony edges on some glass towers (ledBlue, ledMagenta),
  blade signs on storefronts and motels (neonPink, sign cyan, neonAmber).

### 3.2 Beach: South Beach, Ocean Drive, the bay, the causeway

Identity: the north shore road (Lakeshore Drive North, z = 1500) is Ocean Drive. A continuous row of pastel Art Deco
hotels on the land side faces south across the road to a palm park, a sand beach and the bay (the lake). At the lake's
two north corners stand big mid-century resorts. The west road holds waterfront villas, the east road
mid-century motels and the diner, and the south shore a small cluster of slender condo towers.

**Plot sides** (areas in `Config/City.areas`)

- **Land side** (north of the road, z 1422..1478, area `shore_hotel_row`, cap 200): hotels. Its occupancy is raised to
  0.95 (decision L2). Plots stay where they are; only more of them get a building.
- **Beach side** (south of the road, z 1517..1578, area `ocean_beach`): nothing built (density 0), so the hotels look
  over the sand to the water. (The pavilions this plan first wanted have no archetype in ARCHETYPES.md; the
  lifeguard stands, C08, stand on the beach itself.)
- **West road** (x = -1150, area `lake_west`, cap 60): waterfront villas, R06 tropical_modern_villa first, R04, R01,
  R03 and some beach types.
- **East road** (x = 1150, area `lake_east`, cap 60): B11 mimo_truss_motel, R07 and beach types; the diner; B10 at the
  north end (a one-off).
- **South shore and the south avenue** (z = 2850 and beyond, area `south_shore`, cap 480, two tower slots): T13
  cantilever_slab_tower, T17 car_lift_cylinder_tower and T14 (the Collins Avenue towers), R07 and R08 low pastel
  apartments.

**Types (ARCHETYPES.md ids)**

| Where | Types |
|---|---|
| The hotel row (land side) | B01 deco_stripe_hotel, B02 neon_fin_hotel, B03 sign_tower_prow_hotel, B05 streamline_round_corner (prefers corners), B06 corner_spire_hotel and B07 lighthouse_corner_hotel (corners only), B08 finned_tower_hotel, B09 domed_cupola_hotel, B11 mimo_truss_motel, B12 arcade_village_street |
| One-offs | B04 deco_porthole_highrise (the tallest deco hotel), B07 at the north-west corner, C05 domed_sanctuary, B10 curved_resort_slab (section 5.2) |
| Scenery, not on plots (`City.notOnPlots`) | C08 lifeguard_stand, C06 folded_roof_lake_stadium, C09 causeway_bridge |

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

**Types (ARCHETYPES.md ids)**

| Where | Types |
|---|---|
| River Avenue (area `river_avenue`, cap 60) | B12 arcade_village_street (the Miracle Mile arcades), R08 mosaic_townhouse_row, R07 mimo_garden_apartment, a few houses |
| The side streets and Willow Bend (area `suburbs`, cap 50) | R01 mediterranean_villa, R02 coral_rock_cottage, R03 veranda_raised_house, R04 pink_layered_house, R06 tropical_modern_villa, R07, R08 |
| Kept downtown | R05 red_ziggurat_lowrise (weight 0 here) |
| Scenery | C07 lighthouse_water_tower restyles the water tower feature (not on plots) |

The suburb one-offs this plan first listed (the bell-towered hotel, the colonnade hall, the mission church) have no
type in ARCHETYPES.md yet; their anchors are kept in section 5.2 for when they do.

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

**Types (ARCHETYPES.md ids)**

| Where | Types |
|---|---|
| Plant Avenue (z = 0, area `plant_avenue`, cap 120) | W02 faceted_gallery, W04 sculpted_car_park, W03 collage_parking_garage, T18 tiled_mural_midrise, W01 |
| The other streets (area `arts`, cap 96) | W01 mural_warehouse (with its sawtooth and barrel roof variants) and the rest of the district's types |
| One-offs | W03 at the garage anchor, W02 by the Plant Gate, W05 port_crane_yard by the freight depot (section 5.2) |

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

- **Hangars**: the 6 plots draw W01 mural_warehouse in its barrel-roof variant (area `quarry`, cap 40); a hangar type
  after the Opa-locka airfield hangars has no ARCHETYPES.md entry yet.
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
- **Not this round (decision L5):** a canal along the outside of the south straight (a thin MapLayout lake, about
  x -2400..2400, z 3480..3540), for the causeway-beside-water feel. The lake system already gives it banks.
- **Not this round (decision L5):** four overhead sign gantries before the interchanges, with original destination names (the zone
  display names). Posts outside the shoulders, the beam above 20 studs.

## 4. Placement rules: the planner

Built 2026-10-25 in `src/server/Dev/City/CityBuilder.luau` (`place`), with every number in `Config/City`. Inputs:

- the plot list from the plot pass (section 8.2), each plot with its block face and whether it stands on a block
  corner (within `rules.cornerReach`, 30 studs, of its frontage's cut end)
- an Env from Dev/MapBuilder with the clear checks a core claim needs (the plots' own grid test)
- `City.landmarks`, `City.areas`, `City.heightCaps` and every `Config/CityArchetypes/<id>`

Output: the sites, each with an archetype, a height, a variant, its footprint (plots and any core claim), its face
and corner flags; the plots no archetype fits (the old look); the one-offs that found no site (`unplaced`) and the
ones whose archetype isn't written yet (`missing`). Everything is pure and seeded from `MapLayout.seed`.

### 4.1 Occupancy

A plot gets a building when its roll is under its density: its area's `density` if it has one (the hotel row's land
side 0.95, the beach side 0), else the zone's. The roll is drawn either way, so no plot moves.

### 4.2 Runs

A run is the occupied plots of one frontage (edge id and side), in one zone, with no gap. A site is a window of a run's
free plots: its width is their span less the 5-stud gap (2.5 at each end), its depth a plot's (53) or more with a core
claim.

### 4.3 Three passes

1. **One-offs** (`City.landmarks`, in order). Each takes the window of free plots within its radius of its anchor that
   its archetype fits (`minWidth..maxWidth`, `maxPlots`), scored by distance to the anchor plus how far it falls short
   of the width and depth it asks for, with a core claim behind its plots when it wants more depth than a plot. It
   keeps its archetype's tallest height (or the one it gives); caps don't apply. A one-off with no site is reported
   (`plan.city.unplaced`), and tests/MapBuilder.spec and Dev/MapCheck fail on it.
2. **Tower slots.** Every downtown block whose cap reaches band T holds one repeatable tower; an area with `towers`
   (the south shore) holds that many. Each takes the free window nearest a skyline peak whose plots' caps reach band
   T, draws among the tower archetypes that fit it, claims depth back into the block's core (`towers.claimDepth`, 100,
   stepping down to what the archetype needs), and stands between band T and its cap, at least `towers.rise` (65 %) of
   the way up.
3. **The rest**, run by run. On each free plot, its own random stream draws among the archetypes its area mixes in
   that fit the plots from it on, taking the widest fit `rules.wideShare` (60 %) of the time (fewer, bigger
   buildings). A plot nothing fits stays open (`City.openFallback`, set at integration on 2026-10-26: the run's
   paved lot, or ground for a lone plot); with the flag off it keeps the old look, alone. Filling every plot with
   archetypes measured about 21,200 building parts and 25,100 in view at once, far past both budgets.

### 4.4 Core claims

A site that wants more depth than a plot reaches back from its plots into its block's empty core, up to
`claims.maxDepth` (110 from the front line; a one-off may ask for more, such as the bay-row arena's 180 into the open
land behind). The claim is a rectangle as wide as the site. It passes the same clear checks a plot does: inside the map,
flat ground (`maxLevelError`), and clear by the plots' 2-stud clearance of everything a lot keeps off (`LOT_BLOCKERS`:
roads, sidewalks, driveways, supports, landmarks, ramps, mesas, water, locations and their access corridors, props,
streetlights, parks, features, and every other frontage's plots and earlier claims). A claim that doesn't fit is tried
`claims.step` (10) shallower, down to what the archetype needs. A taken claim is paved (`Lots/ClaimB<n>`) and put in the
grid as a lot, so later claims and trees keep off. The core-square rule this plan first had (never in another
frontage's plot band, even an empty one) was dropped: by the time claims run every plot is placed, so the grid test is
enough, and it lets a tower take an empty corner.

### 4.5 Rules on every pass

- **Caps.** A repeatable's cap is the lowest of its plots' block caps (section 2), its area's cap, 160 beside a
  gameplay spot, band H once its block's T slot is taken, band M once its two H slots are, and 60 % of its run's tower.
- **Neighbours.** Two sites whose footprints come within `rules.neighbourGap` (90 studs) of each other are neighbours:
  beside, across a street or an avenue, round the corner. Neighbours never share an archetype. As the last resort
  (nothing else fits), the same archetype may stand across the street (another block), a palette apart and at least
  25 % taller or lower.
- **Repeats.** An archetype stands at most `min(perBlock, rules.perBlock)` (2) times in a block, `maxCopies` times in the
  map, and `minSpacing` from its other copies.
- **A repeat looks different.** Every copy draws a look (palette, crown, rhythm) no other copy has while one is left,
  plus its own height and mirror.
- **Corners.** `City.cornerArchetypes`: flatiron_wedge_tower, corner_spire_hotel and lighthouse_corner_hotel stand only
  on a block corner; streamline_round_corner is three times as likely there. Each is mirrored so its corner is at its
  drawn +x end (`site.corner.right`).
- **No twin heights.** One-offs and the tower pass draw each tower's height clear of every tower already placed
  within 600 studs (24 studs apart at least); a tower option whose whole range twins one is passed over. A last pass
  moves any other tower to the nearest free height in its own range (or below band T when its archetype goes that
  low).

### 4.6 Heights

- One-offs: their listed height, or their archetype's tallest.
- Towers: between band T and their cap, at least 65 % of the way up.
- The rest: their archetype's range under their cap, by the plot's height roll.

### 4.7 Determinism

- Runs are processed in the plot pass's order; one-offs in their list order.
- Each plot's random stream is `mixSeed(seed, shade, index)`, as before; the tower pass uses a salted one.
- Building the map twice gives the same parts. MapCheck compares the instance counts of two builds, and
  tests/MapBuilder.spec and tests/City.spec compare two plans.

## 5. One-off landmarks

These are listed in `City.landmarks` (updated 2026-10-25 to ARCHETYPES.md's ids). Each entry names its archetype
(`id`), an anchor (x, z) and optionally a search radius (default `landmarkRadius`, 160), the width and depth it would
like (a depth past a plot's 53 is a core claim), a face (`back` turns its front away from its road, to the bay or the
spawn), a corner flag and a height (default its archetype's tallest). An archetype whose `maxCopies` is 1 stands only
here; one with more copies (sky_court_slab, stair_wing_slab...) has its first copy here and the rest placed as
repeatables. A one-off whose module isn't written yet is skipped (`plan.city.missing`).

The anchors are today's real runs; the run centre and width were measured on 2026-10-25. A site's width is its
plots' span less 5 studs, so a 202-stud run gives at most 197. The widths needed come from each archetype's
`minWidth` (Config/CityArchetypes); the widest runs downtown are on the bay row (236 and 200).

### 5.1 Downtown

| Id (ARCHETYPES.md) | Inspiration (docs only) | Anchor (x, z) and run | Depth | Notes |
|---|---|---|---|---|
| T01 stacked_cube_supertall | Waldorf Astoria Hotel & Residences | (150, -65): block d3's south frontage on Commerce Ave, 5 plots, 202 wide | 110 | the peak, 660..700 tall; was "spire" |
| T03 tiered_curve_crown_tower | Miami Tower | (468, 60): block e4's north frontage on Commerce Ave, 4 plots, 170 wide | 110 | face back, toward the spawn and the bay; was "tiered_tower" |
| T02 exoskeleton_tower | One Thousand Museum | (64, -447): block d2's west frontage on Main Ave, 4 plots, 129 wide | 110 | the north peak; was "exoskeleton" |
| T05 sawtooth_office_tower | Southeast Financial Center | (732, -347): block f2's south frontage, 5 plots, 208 wide | 110 | was "sawtooth_tower" (needs 140 wide) |
| T16 ribbon_canopy_towers | Brickell City Centre | (130, 251): block d4's south frontage, 5 plots, 172 wide, near the spawn street | 110 | was "ribbon_mall" |
| T09 stair_wing_slab | The Palace | (115, 856): block d6's south frontage, 4 plots, 153 wide | 120 | its stairs step down toward the bridge; first copy (reuse 2); takes the "crown_tower" anchor (Four Seasons has no type) |
| C01 cupola_bell_tower | Freedom Tower | (66, -190): block d3's west frontage on Main Ave, facing Town Square | 90 | was "cupola_tower" |
| C02 stepped_crown_courthouse | Miami-Dade County Courthouse | (-66, 530): block c5's east frontage on Main Ave, beside the Courthouse hotspot | 110 | was "courthouse" |
| T12 triple_tower_podium | Icon Brickell | (-451, 940): the bay row, 6 plots, 241 wide | 110 | face back, to the lake; needs 170 wide, so it takes the widest run (the old "staircase" anchor) |
| T04 sail_supertall | Aston Martin Residences | (783, 950): bay row, 4 plots, 155 wide | 110 | face back, the sail to the lake; was "sail" |
| T08 sky_court_slab | The Atlantis | (-164, 945): bay row, 5 plots, 205 wide | 70 | face back; first copy (reuse 2); was "sky_court" |
| R05 red_ziggurat_lowrise | Babylon | (119, 943): bay row, 4 plots, 147 wide | plot | first copy (reuse 3); was "ziggurat" |
| C04 bayfront_arena | Kaseya Center | (450, 950), radius 260: the bay row between the ziggurat and the sail | 180 | face back, claims into the open land behind the bay row |
| C03 harbor_market_pavilions | Bayside Marketplace | (-740, 950), radius 220: the bay row's west end | 160 | face back; replaces "market_hall" |

No type in ARCHETYPES.md yet, so not placed: "theatre" (Olympia Theater, (525, -548)), "led_hotel" (InterContinental,
(741, -58)) and "crown_tower" (Four Seasons). Their anchors are free for future one-offs.

### 5.2 Beach, suburbs, arts

| Id (ARCHETYPES.md) | Inspiration | Anchor (x, z) | Depth | Notes |
|---|---|---|---|---|
| B10 curved_resort_slab | Fontainebleau | (1195, 1650), radius 260: the east road's north end | 140 | claims east into the open land; was "curve_resort" |
| B04 deco_porthole_highrise | The Tides | (620, 1460): the hotel row's land side | plot | first copy (reuse 3); was "tall_deco_one" |
| B07 lighthouse_corner_hotel | Waldorf Towers | the corner plot nearest (-1000, 1460), radius 200 | plot | corner only; first copy; was "lighthouse_corner" |
| C05 domed_sanctuary | Temple Emanu-El | (-414, 1460): the hotel row's land side | plot | takes the "courtyard_mansion" anchor (Casa Casuarina has no type) |
| W03 collage_parking_garage | Museum Garage | (2352, 53): Plant Avenue's south side, 6 plots, 216 wide | 80 | first copy (reuse 2); was "art_garage_stack" |
| W02 faceted_gallery | ICA Miami | (2015, -56): Plant Avenue's north side, 4 plots, 143 wide, east of the Plant Gate | plot | first copy (reuse 3); takes the "mural_court" anchor |
| W05 port_crane_yard | PortMiami cranes | (2515, 600), radius 420: by the freight depot | 140 | clear of the depot's yards and trailer spots (they are locations) |

No type yet, so not placed: "sign_slab_resort" ((-1188, 1500)), "lifeguard_hq" ((98, 1541), now open beach),
"bell_tower_hotel" ((-2363, -65)), "colonnade_hall" ((-1918, -62)) and "mission_church" ((-1580, 445)).

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

Budget: at most 2,200 night-light parts in all (about 1,950 built on 2026-10-26, 238 sites). DayNightService flips 200
per frame, so dusk takes about 11 frames.

### 7.2 SLIM-safe structure

SLIM (Model.LevelOfDetail = SLIM) keeps a building visible past the streaming radius as a cheap composite. It also
cuts draw calls up close. But it **breaks on models whose parts change at runtime**, and night lights change material
and colour at dusk.

Built 2026-10-25 (`Dev/MapBuilder` addCity, `CityBuilder.file`):

- **Still models: SLIM.** Every city site is its own Atomic model, `Buildings/Tower<n>` (160 studs and up, or an
  archetype with `ownModel`) or `Buildings/Site<n>`, with `LevelOfDetail` SLIM. It holds no NightLight-tagged part, no
  SurfaceGui label, no Light and no AdGui.
- **Light models: not SLIM.** Each site's night lights, signs and lights go in `BuildingLights/<the same name>`
  (Atomic, `LevelOfDetail` Disabled): a handful of parts each.
- The old look's block tiles (`Buildings/Block<n>`, only where no archetype fits) keep their lit glass and get no
  level of detail.
- `Container.lod` names the level of detail; `MapBuilder.build` sets it when the Studio knows it, and warns once if not.
- tests/MapBuilder.spec and Dev/MapCheck fail on a light inside a SLIM model.

### 7.3 The Skyline model

`Skyline` is a Persistent Model of at most 200 parts (`City.budgets.skyline`). For each site of band T and up,
tallest first while the budget lasts (4 parts a site, so up to 50 towers), it holds the site's 3 biggest solid masses
that rise past 40 % of its height and its crown light (a night light in its top 15 %), moved there by
`CityBuilder.file`. The details (fins, slabs, podiums) stream with the tower's own model.

Built 2026-10-25. It stays even though SLIM can now be used (Team Create is on and the place is published): SLIM shows
far towers in their day look and drops their lights models past the streaming radius, so without the Skyline the
skyline would go dark from the beach at night. T01 at the peak is about 2,240 studs from the middle of the bridge, past
the 2,048-stud streaming target.

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

As built (2026-10-25):

| File | What it is |
|---|---|
| `src/shared/Config/City.luau` | districts by zone, district looks, bands, block caps, areas (mixes, caps, densities, tower counts), the one-offs (`landmarks`), claims, tower slots, placement rules, corner archetypes, the Skyline, budgets, the kit's numbers, textures, palettes, sign names |
| `src/shared/Config/CityArchetypes/<id>.luau` | one per archetype: its district, weight, copies, sizes, heights, crown room, part budget and variant counts (optional `claimDepth`, `corner`) |
| `src/server/Dev/City/CityBuilder.luau` | the planner (section 4: `place`), and building, checking and filing a site (`build`, `check`, `file`) |
| `src/server/Dev/City/Types.luau` | `Plot`, `Site`, `Env`, `Variant`, `Model`, `Archetype` |
| `src/server/Dev/City/Kit.luau` | pure shape helpers that emit PartSpecs (8.4) |
| `src/server/Dev/City/Archetypes/<district>/<id>.luau` | one module per archetype: `{ id, build(m) }`, found by `Archetypes/Index` |
| `src/server/Dev/City/Scenery/` | street palms, furniture, the beach, the causeway (the scenery step) |
| `src/server/Dev/MapTypes.luau` | the PartSpec and Container types MapBuilder and the city share (`Container.lod`) |

### 8.2 The hook

`addBuildings` keeps its loop: the same draws, `usable()`, grid inserts and paved lots. It differs in three places:

- the density test reads `CityBuilder.density` (an area's density, else the zone's)
- where it called `addBuilding`, it appends a Plot record (with `cornerStart` and `cornerEnd`)
- block tile models are made only for the old-look buildings that stand in them

At the end `addCity` hands the plots and an Env (the clear check and the claim, on MapBuilder's grid) to
`CityBuilder.place`, builds every site, files its parts in its model, its lights model and the Skyline, builds the old
look on the plots no archetype fits, and fills `plan.city` (fallbacks and parts by district, lights, Skyline, claims,
unplaced and missing one-offs).

```lua
export type Plot = {
	index: number, -- MapBuilder's building number (stable)
	frontage: string, -- "<edge id>:<side>"
	block: number, -- block face from findBlocks
	along: number, width: number, plotDepth: number, -- along the road; 53 deep
	frontStart: Vector2, u: Vector2, away: Vector2, -- its corner on the front line, the road's way, into the plot
	zone: string, tall: number, nearSpot: boolean, shade: number,
	folder: string, cornerStart: boolean?, cornerEnd: boolean?,
	center: Vector2, buildingDepth: number, buildingWidth: number, height: number, color: Color3, -- the old look
}
```

### 8.3 What an archetype gets

```lua
export type Site = {
	id: string, -- "B<index>" of its first plot; part names start with it
	archetype: string, district: string, zone: string,
	frame: CFrame, -- footprint centre on the ground; local X along the road, local -Z toward its front
	width: number, depth: number, -- its plots, plus its core claim (`claim` studs of the depth)
	height: number, maxHeight: number, band: string, -- "L", "M", "H", "T" or "S"
	seed: number, variant: { palette: number, crown: number, rhythm: number, mirror: boolean },
	folder: string, -- Buildings/Tower<n> or Site<n> (Atomic, SLIM)
	lightsFolder: string, -- BuildingLights/<the same name> (Atomic, not SLIM)
	plots: { number }, block: number,
	face: "road" | "back", -- its front looks at its road, or away from it
	claim: number,
	corner: { left: boolean, right: boolean }, -- open to a cross street at that end, as drawn (after the mirror)
	landmark: boolean, skyline: boolean,
}
```

Every site is its own Model, so it streams and switches detail as one piece (TECH §6).

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
| Buildings/Tower<n>, Buildings/Site<n> (city sites) | Atomic | SLIM |
| BuildingLights/Tower<n>, BuildingLights/Site<n> | Atomic | Disabled |
| Buildings/Block<n> (the old look, only where no archetype fits) | Atomic | — |
| Lots (plots and `ClaimB<n>` core claims) | Folder | — |

The scenery step's folders (Trees, Streetscape and their lights) are that step's.

Supporting changes (built): `Container` has `lod: string?`, and `build()` sets `Model.LevelOfDetail` from it. SLIM needs
the place published with Team Create on (decision D1: on as of 2026-10-25).

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

Night-light parts (at most 2,200; about 1,950 built) sit inside their district budgets.

As built (2026-10-25), `Config/Environment.budget` and `Config/City.budgets`:

| Key | Value | Where |
|---|---|---|
| mapParts | 30,000 | Environment.budget |
| **inViewParts** | **20,000** | Environment.budget |
| buildingParts | 15,000 (city sites and old-look fallbacks) | Environment.budget |
| treeParts, featureParts, groundParts | unchanged (the scenery step tunes them) | Environment.budget |
| districts | downtown 8,000, beach 2,300, suburbs 3,300, arts 1,100, quarry 120: each district's share of buildingParts (printed, not a gate; rebalanced at integration to the built 7,573 / 2,099 / 3,051 / 813 / 106) | City.budgets |
| skyline | 200 | City.budgets |
| nightLights | 2,200 (building night-light parts; raised from 1,400 at integration, 2026-10-26) | City.budgets |

The streetscape and restyled-landmark budgets are the scenery and landmark steps' to add.

**inViewParts** is the phone gate: the most parts a player can have streamed in at once. It is the parts within
`Perf.streaming.targetRadius` (2,048) of any road node, plus every Persistent part (`MapCheck.inView`, binned in
128-stud cells; tests/MapBuilder.spec and Dev/MapCheck fail over it). The worst place is downtown's
centre, where the whole of downtown and about 40 % of each neighbouring district are in range. The estimate is about
19,500, against the 5,100..5,550 the phase 14 perf drive measured at a steady 60 fps on desktop. That is why the
budget leans on four levers:

1. SLIM composites, which cut draw calls inside the radius too
2. decor parts that never collide, take a raycast or cast a shadow
3. Opportunistic stream-out (already set)
4. this gate failing the build before a phone does

Davis's real-phone check after the downtown step decides whether 20,000 holds.

2026-10-26, street life (cafés, shop fronts, parked cars, the open plots' lots, the bayfront park): 20,758 near
(-900, 300). The gate stayed at 20,000 (the desktop perf drive ran under 60 fps), and the lane paint left the
Persistent Roads model for its own streamed folder `RoadLines` (-602) while the downtown lots' budget went from 900 to
700 (-195): 19,963 as built.

## 10. What the checks keep checking

Dev/MapCheck must pass: two builds give the same count, no road overlaps, every location built with its tag and
attributes within reach, every node reachable, routes under 5 ms, night-light kinds known, every feature built, the
tree count noted, Ground and Roads Persistent. Step 7 (built 2026-10-25) adds the city: it notes the sites, core
claims, old-look fallbacks and building parts by district, the Skyline count and the archetypes not written yet, and
fails on a one-off that found no site, on more parts in view at once than `budget.inViewParts`, on a night light,
sign, light or ad unit inside a SLIM model, and on a Skyline that isn't Persistent or is over budget.

tests/MapBuilder.spec keeps:

- road surfaces flush, no gaps or lips, no road overlaps
- every part under the size limit and inside the map
- buildings and lots (claims included) off roads, junction pads, sidewalks, locations and landmarks
- the auto mall block clear of buildings
- every pad's way to its road with nothing a car can't drive over
- no buildings or lots in parks (the beach park included)
- hills and features where MapLayout puts them
- every location with one part, its tag, DisplayName and Zone
- at most one emitting streetlight per 200 studs
- night lights tagged with known kinds, built in their day look with their lights off

Changed or new in tests/MapBuilder.spec (built 2026-10-25):

1. Budgets: mapParts, buildingParts, the Skyline and the building night lights fail when over; each district's share
   of buildingParts is printed, with any district past its share; and the inViewParts gate.
2. Every city site re-checks clean (inside its footprint and height, within budget, named and filed as its), has
   glass, reaches its roof, and has the band of its height; every archetype placement may draw stands at least once,
   within its copies.
3. Every one-off whose archetype is written stands once, near its anchor, and none is unplaced.
4. No two neighbouring sites share an archetype (except the across-the-street last resort), no look is used twice
   while its archetype has looks left, no two towers within 600 studs are within 24 of one height, and at least 40 % of
   sites light up at night.
5. No SLIM model holds a night light, a sign, a light or an ad unit; every site is an Atomic SLIM model; the Skyline is
   Persistent.
6. The old look's buildings (only where no archetype fits) still have glass and a roof edge; their count is printed
   by district.
7. Containers: Buildings/, BuildingLights/, Trees/ and Features/ are Atomic.

tests/City.spec (the kit and archetype step's) covers the pure planner with small fixtures: the same plan twice,
site carving, the repeat and neighbour rules, the caps, and each archetype on sample sites.

The name gate (decision L6, built): the inspiration names that are not everyday words are in
`scripts/banned-city-names.txt`, which the brand-name step of `scripts/check.ps1` and `check.sh` reads with
`scripts/banned-names.txt`, so the gate refuses them in `src/` and `tests/`. They are kept out of `banned-names.txt`
itself because that list is also the AI Car Designer's brand check (Util/BrandNames must cover it, and the backend
keeps a copy that `npm run sync-kit` syncs and production serves); a building or neighbourhood name in a player's car
design is not a brand problem. Everyday-word names (Atlantis, Palace, Babylon, Colony, Tides, Avalon, Panorama) are kept
out by neutral ids, and by review.

## 11. Work order for the build steps

Each step lands green on tests/MapBuilder.spec and Dev/MapCheck.

| Step | Work |
|---|---|
| 1 | `City.luau`, `MapParts`, Planner, Kit and CityBuilder, with the `legacy` archetype. No visual change. Budgets and new checks wired. |
| 2 | Downtown one-offs: T01, T03, T02 and T09 first (the spawn view and the bridge view), then the rest of section 5.1. |
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
| D1 | Turn on Team Create and publish the place. SLIM (distant buildings stay visible as cheap stand-ins) needs both. Without it, the plan still works: the tall towers' main shapes stay loaded, but distant details vanish. | Done (on and published, 2026-10-25) |
| D2 | Keep the zone names (Cedar Bend, Riverside, The Plant, Lakefront, Mesa Test Site) or rename them to new Miami-flavoured ones. Renaming changes GPS and place names players see. | Keep for now |
| D3 | Allow a handful of original images (window grids, real mural art) uploaded to his Roblox account, for sharper facades and real murals. | Not needed for this pass; parts only by default |
| D4 | The tallest tower is 560 studs (about 46 floors). Taller is a number change. | 560 (note: ARCHETYPES.md compresses its inspiration to 700, and T01's config is 660..700 today) |
| D5 | Hotel and sign names are invented EV puns (VOLTAMAR, THE AMPERE, SEAVOLT...). | Keep; veto any he dislikes |
| D6 | Restyle the claimable houses (Mediterranean and modern tropical) in a later step. Their garage door and home charger stay where they are. | Yes, as a separate step after the buildings |

### For the lead (not Davis)

All decided 2026-10-25:

| | Decision |
|---|---|
| L1 | Towers merge neighbouring plots of one run and the tallest claim part of their block's empty core. No plot moves; every claim passes the same clear-checks. Built (section 4.4). |
| L2 | Occupancy on the north shore road's land side (Ocean Drive) goes to 0.95, for a continuous hotel row: area `shore_hotel_row`'s `density`. Built; the beach side was also set to 0 (area `ocean_beach`), so the hotels see the water. |
| L3 | MapLayout.parks: Lakefront Park split into `lakefront_beach` (sand, x -1050..1050, z 1650..1800) and `lakefront_park` (the rest of the ring). Built. |
| L4 | mapParts 30,000 and the inViewParts phone gate at 20,000. Built. |
| L5 | No canal and no sign gantries this round. |
| L6 | The inspiration names go in the name gate. Built as `scripts/banned-city-names.txt`, read by the same gate step (section 10). |
| L7 | Team Create is on and the place is published, so SLIM is used: night lights live in small separate models. Built (section 7.2). |
| L8 | Terrain water is not used this round (it changes what happens when a car goes in the water; Davis decides): the bay stays parts. Superseded 2026-10-26 (Davis: "also yes the water should be real water"): the bay is terrain water, and cars left in deep water go back to the road (SCENERY.md §3). |
| L9 | No decorative traffic signals. |

Decided at integration, 2026-10-26:

| | Decision |
|---|---|
| L10 | A plot no archetype fits stays open (`City.openFallback`), not the old glass box. Filling every plot measured about 21,200 building parts and 25,100 in view at once; the repeatables' copies were raised instead until the gates held (238 sites, 13,642 building parts, 18,792 in view). About 475 plots stay open: paved lots between buildings, lawn for a lone plot. |
| L11 | The name gate treats `_` and `-` as word separators, so a banned name joined into an identifier is caught. The area `ocean_drive` became `shore_hotel_row` and the archetype `folded_roof_marine_stadium` became `folded_roof_lake_stadium`. |
| L12 | The bay-row arena sits on the d7..e7 run (147 studs; its minWidth went to 140) and faces the road, as does the harbour market; the red ziggurat takes the short run east of it; the corner sign-tower hotel is a one-off at the hotel row's x = 56 corner. |
| L13 | Towers draw a height clear of every tower placed within 600 studs as they are placed, not only in a pass afterwards. Building night lights: budget 2,200 (about 1,950 built). |

Decided in the roast-fix step, 2026-10-26 (the roast of the integrated city; details in docs/PROGRESS.md):

| | Decision |
|---|---|
| L14 | Downtown's ground is pale concrete (206,202,194) and every paved lot and core claim a shade under it, not grey asphalt; Town Square keeps its grass. The open lots of L10 now read as plazas and pool decks rather than parking. |
| L15 | The sky: per-hour colour grade and atmosphere haze (`Config/Environment` keyframes `tint`, `density`, `haze`, `glare`), a Sky made at start when the place has none (without it the night is black), latitude 50 (TECH.md §1). |
| L16 | Tower glass uses ARCHETYPES.md's pale tokens (aqua, silver, sea-green, sky, charcoal, smoke) at reflectance 0.27; towers 160 studs and up keep floor lines only above 40 studs (no mullion checkerboard); lit window runs take one of three tints and about a third of the upper runs stay dark. |
| L17 | Pale or pastel SmoothPlastic walls are built in Plaster (Kit.part), so sunlit stucco reads warm instead of mirroring the sky. |
| L18 | The bay: darker green-teal bands, no glint texture, reflectance 0.07 (at 0.18 the seam between two sheets showed), wet-sand bed. Lifeguard decks at 11 studs. No broadleaf box trees in the city mixes. MapCheck fails on any old box building downtown or on the beach. |
