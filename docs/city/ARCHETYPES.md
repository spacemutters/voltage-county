# City archetypes: the Miami rebuild

Step 1 of the Miami rebuild (branch `miami-city`): the building and scenery types, each from a real Miami building,
and how each becomes blocky-but-sharp Roblox geometry. Nothing here is built yet. The builder steps read this file;
the layout step decides which archetype stands on which site.

Davis, 2026-10-25: "think more Miami ... big, unique buildings. Each building has to have its own unique
inspiration ... models have to be sharp." Gameplay stays: every road, lot, pad and spot in Config/MapLayout and
Config/RoadGraph keeps its place, and Dev/MapCheck must still pass.

**Names rule.** The real names, architects, addresses and links below are for this document only. In the game
(instance names, Config strings, signs, GPS names) an archetype is its generic `id`, and every sign shows an
invented name (list in section 11). No real building, brand or business name goes into the game.

Contents
1. Scale and sharpness rules (all archetypes)
2. Shared kits (built once, used by many archetypes)
3. Where the districts go (proposal)
4. At a glance: all 52 archetypes
5. Downtown towers (T01 to T18)
6. Beach strip: Art Deco and MiMo (B01 to B12)
7. Residential (R01 to R08)
8. Wynwood and industrial (W01 to W05)
9. Civic landmarks and scenery (C01 to C09)
10. Gameplay landmarks: suggested skins
11. Night lights, signs and fonts
12. Part budget
13. Open questions

---

## 1. Scale and sharpness rules

**Units.** 1 stud = 0.28 m (Config/World). A floor is 12 studs (3.4 m). A car is at most 18 x 7 x 6.2 studs, a
player about 5 tall. Tower lobbies are 16 studs (double height); a deco hotel's ground floor is 14.

**Heights.** Real height in studs (metres / 0.28) up to 160 studs; above that, the rest is compressed by 0.55:
`game = min(real, 160) + max(0, real - 160) * 0.55`. So the 1,049 ft supertall is 700 studs, a 700 ft tower about
490, a 225 ft slab about 205, and a three-storey hotel keeps its real 36 to 46. Floors stay 12 studs, so a
compressed tower has fewer floors than its inspiration (the 100-floor supertall has about 55).

**Footprints.** Today's lots (Dev/MapBuilder TUNING) are 26 to 52 studs along the road and 20 to 44 deep, in a
53-stud strip that starts 25 studs from the street's centre line. Downtown blocks are 300 studs on centres, 254 clear
between two streets' sidewalks (a street reaches 23 studs from its centre line, an arterial 38, so 239 next to Main
or Commerce Avenue), and the middle of every block (about 150 x 150) is empty today. Miami needs bigger sites, so the
archetypes use five footprint classes; the layout step has to plan F2 to F5 sites (MapBuilder only makes F1 today):

| Class | Size (along x deep, studs) | Where it comes from | Used by |
|---|---|---|---|
| F1 frontage | 26-52 x 20-44 | one of today's lots | houses, small hotels, warehouses |
| F2 double | 60-104 x 40-60 | two or three neighbouring lots | wide hotels, motels, garden apartments |
| F3 corner | about 110 x 110 | a downtown block's corner, back into the empty middle | most towers |
| F4 half block | about 230 x 110 | one side of a block | slab towers, the curved resort, the garage |
| F5 whole block | about 230 x 230 | a whole block, or a lakefront site | supertalls with plazas, the arena, the marketplace |

Every site keeps MapBuilder's rules: 10 studs from any location's footprint, out of its 30-stud access corridor, 2
studs from roads, sidewalks, pads and props, off the auto-mall block (x 600..900, z 600..900), out of Town Square
(x -277..-38, z -277..-38) and every park, and on flat ground.

**Sharp, not soft.** Davis's complaint is soft, flat, samey boxes. Shadows are now on (Config/Environment
`dayNight.scene`, softness 0.15) and Lighting will be Future, so depth reads if the geometry has it:
- Every facade has at least two depths: glass set 0.6 inside the frame (TUNING.glassInset), and something proud of
  it (slab edges 3 to 6 out, eyebrows 2.5 to 3 out, fins 4 to 14 out). A flat box with a texture is never enough.
- Edges are crisp: SmoothPlastic or Plaster for stucco and slabs, never Plastic. Thin elements are real thickness:
  slab edge 1.0, eyebrow 0.6, mullion 0.3 to 0.5, fin 1 to 4, rail glass 0.3.
- No coplanar faces (z-fighting): anything that sits on a face stands at least 0.05 proud of it.
- Glass is opaque Glass material (Transparency 0) with Reflectance 0.15 to 0.3, so it mirrors the sky under Future
  lighting. Only rails, lift shafts and lanterns are see-through (Transparency 0.5 to 0.6). Overlapping transparent
  parts are expensive on phones: one transparent layer per sightline.
- Curves are either CSG (one part; see below) or facets of 8 to 12 boxes per quarter circle. Rounded corners are
  Cylinder parts standing at the corner, half inside the walls. A dome is a Ball part sunk into its drum.
- Shadows on for big masses, eyebrows, fins and slab edges (their shadow lines are the look). CastShadow off for
  anything under 1 stud thick and under 6 studs long (mullions, rails, lamp heads, small trim).
- Decor never collides: shells and slabs a car can hit keep CanCollide; trim, fins, rails, glass skins, signs and
  roof clutter get CanCollide, CanTouch and CanQuery off. MapBuilder's `decor` also turns shadows off, so eyebrows,
  fins and slab edges need a variant of it that keeps CastShadow on.

**Curves and repeats: CSG.** Builders run in Edit mode through execute_luau, where `GeometryService:UnionAsync`,
`SubtractAsync` and `IntersectAsync` should be available (not tried here yet: check them on one tower before the
whole map relies on them). Two uses:
- **Shapes**: a lens-shaped sail is `IntersectAsync` of two big cylinders; a porthole or a cheese hole is a cylinder
  subtracted from a wall; a curved slab is a ring segment. One part each.
- **Merging repeats** (marked **U** in the entries): a tower's 30 slab edges become one union per material, its
  mullions another. Clone a finished union instead of re-unioning the same shape. Union results get
  CollisionFidelity Box (or CanCollide off) so physics stays cheap.
Each entry gives two part counts: **plain** (separate parts, where a one-part CSG shape such as a lens, a ring
segment, a holed wall or a cloned panel union counts as one) and **U** (with the marked repeats merged as well).

**Streaming and the skyline.** Every building is its own Model, ModelStreamingMode Atomic, grouped in block tiles as
today. Much of the beach strip is 2,000 to 3,000 studs from the downtown towers, past the 2,048-stud streaming target
(Config/Perf), so the skyline would vanish from the beach. Roblox's SLIM level of detail (Model.LevelOfDetail = SLIM)
keeps a light stand-in visible after a model streams out. It needs StreamingEnabled, a place saved to Roblox and Team Create, it works best on
static geometry, and the docs warn that some solid-modelling (union) hierarchies may render wrongly. Night lights
change material at runtime, so a SLIM stand-in would show the day look. Open question 1.

**Seeds.** Every variant choice (height, colour set, mirror, crown) comes from `MapLayout.seed` and the site index, as
today, so the map rebuilds the same every time.

**Unique at a glance.** No archetype stands next to itself; two copies of one archetype stand at least 600 studs apart
downtown and differ in colour set or height; the landmarks (T01 to T04, the civic set) appear once.

**Colours.** Hex below, always with a Roblox material. The shared tokens:

| Token | Hex | Material | Use |
|---|---|---|---|
| white_stucco | #F3F1EA | Plaster | deco and MiMo walls, slab edges |
| bright_white | #F7F7F4 | SmoothPlastic | tower frames, fins, GFRC |
| warm_white | #EDE6D8 | Plaster | Mediterranean walls |
| ivory_stone | #EFE9DC | Limestone | deco high-rise stone |
| coral_rock | #CDBB95 | Limestone | coral-rock walls |
| granite_pale | #BDB8B0 | Granite | office and courthouse bases |
| concrete_raw | #D4D0C8 | Concrete | garages, warehouses |
| glass_aqua | #5E9AA8 | Glass, refl 0.2 | the Miami condo glass |
| glass_blue | #3F6F8E | Glass, refl 0.2 | office glass |
| glass_clear | #8DB3C4 | Glass, refl 0.25 | clear blue-tinted glass |
| glass_silver | #9FB3BF | Glass, refl 0.3 | reflective glass |
| glass_dark | #2C3A44 | Glass, refl 0.2 | window bands in stucco |
| glass_rail | #CFE8EC | Glass, transp 0.55 | balcony rails |
| alu | #C8CDD2 | Metal | screens, louvres |
| chrome | #D9DEE3 | Foil | deco spires, trim |
| terracotta | #B5583A | ClayRoofTiles | barrel tile roofs |
| iron | #2A2A2A | Metal | wrought iron |

Deco pastels (after Leonard Horowitz's 1980s Ocean Drive palette, drawn from sunrise, sunset, the sea and the sand;
[MDPL](https://mdpl.org/?p=5246), [WLRN](https://www.wlrn.org/culture/2013-11-16/meet-the-man-behind-all-those-south-beach-pastels)),
all Plaster: deco_pink #F2B8C6, deco_peach #F6CBA4, deco_mint #B5E3CF, deco_aqua #79D0D2, deco_lemon #F3E39C,
deco_lavender #CDBDE6, deco_coral #EE8F7A, deco_seafoam #8FD1B8, deco_sky #A9D4EE, deco_turquoise #3FB8B6. A deco
building is white with one or two pastels on its stripes, eyebrows or tiers, never a pastel all over.

---

## 2. Shared kits

Standard pieces many archetypes reuse (Davis: "you can use a standard building and then reuse it"). Each is one
builder function with parameters.

**K1 Tower core.** A glass box (one part) with slab edges: a slab 1.0 thick that is the core's footprint grown by the
balcony depth (3 to 6) on chosen faces, one per floor or every second floor (**U**), and a glass rail ring 3.2 tall on
each slab's edge (**U**). Optional corner piers or fins. Ground floor 16 tall, recessed 4 under the first slab, with a
lobby glass box and a door.

**K2 Parking podium.** Miami towers stand on 6 to 12 storeys of garage, and it is part of the look. A concrete box
(10 studs a level) with one screen part per street face (alu or a colour, Metal, set 0.6 proud) and a horizontal slot
per level shown as a dark recessed band (**U**). Optional LED strip at the top edge (night kind `led_edge`). 6 to 10
parts plain, 4 U.

**K3 Deco body.** A stucco box per floor band, glass ribbon inset 0.6 per floor, a parapet that steps up at the
centre, a terrazzo step and a door. 6 to 10 parts.

**K4 Eyebrows.** Continuous sunshades 0.6 thick, 2.5 to 3 deep, one per floor across a facade, wrapping 6 to 8 studs
round a corner. At a rounded corner the eyebrow is a flat cylinder disc. Their shadow lines are the deco look, so they
cast shadows.

**K5 Streamline corner.** A Cylinder (axis vertical) at the corner, the walls stopping at its centre; glass bands
become thinner glass cylinders inset 0.6.

**K6 Screen.** A MiMo breeze-block or louvre screen: a frame (4 parts) with 3 to 6 bars each way (**U**), or a slab
with holes subtracted (one CSG part).

**K7 Tile roof.** Gables from two WedgeParts, hips from wedges plus CornerWedgeParts, terracotta ClayRoofTiles, eaves
1.5 past the walls.

**K8 Crown and lights.** Whatever lights the top: a part tagged for the night lights (section 11) or a hidden lamp
part holding one SpotLight that washes a dome or a tower top (at most one Light per landmark, range 60 or less).

---

## 3. Where the districts go (proposal for the layout step)

| Miami district | Game zone (MapLayout) | Where |
|---|---|---|
| Brickell, Downtown, Edgewater skyline | `cedar_bend` | the 300-stud grid: T01 to T18, C01, C02 |
| Bayfront (Biscayne Boulevard) | `lakefront`, north shore | between Lakeshore Drive north (z = 1,500) and the park: C03, C04 |
| South Beach: Ocean Drive and Collins | `lakefront`, east and west | outer side of Lakeshore Drive (x beyond 1,173 and -1,173), facing the park and the lake across the road, as Ocean Drive faces the beach: B01 to B12, C05 |
| The beach itself | Lakefront Park, the shore | lifeguard stands C08 on the shore; the marine stadium C06 facing the water (needs a park exception) |
| Causeway | Cedar Lake Bridge | C09 restyles the bridge (feature `cedar_lake_bridge_arches`) |
| Coral Gables, Coconut Grove, MiMo suburbs | `riverside` | R01 to R08; C07 replaces the Riverside water tower feature |
| Wynwood, Design District, the port | `the_plant` | W01 to W05 |
| Mesa Test Site, County Loop | unchanged | the Mesa keeps its desert look; section 10 has a skin for Mesa Control |

---

## 4. At a glance

Heights in studs. Reuse is the most copies the map should hold. Parts are plain / U per copy.

| # | id | District | Inspiration (docs only) | Footprint | Height | Reuse | Parts |
|---|---|---|---|---|---|---|---|
| T01 | stacked_cube_supertall | downtown | Waldorf Astoria Hotel & Residences | F5 | 700 | 1 | 120 / 85 |
| T02 | exoskeleton_tower | downtown | One Thousand Museum | F3 | 495 | 1 | 148 / 40 |
| T03 | tiered_curve_crown_tower | downtown | Miami Tower | F4 | 445 | 1 | 110 / 70 |
| T04 | sail_supertall | downtown | Aston Martin Residences | F3 | 560 | 1 | 64 / 22 |
| T05 | sawtooth_office_tower | downtown | Southeast Financial Center | F4 | 530 | 1 | 85 / 46 |
| T06 | standard_glass_slab | downtown | Panorama Tower | F3 | 180-480 | 10 | 60 / 24 |
| T07 | flatiron_wedge_tower | downtown | Brickell Flatiron | F3 corner | 400-490 | 2 | 70 / 18 |
| T08 | sky_court_slab | downtown | Atlantis | F4 | 205 | 2 | 58 / 34 |
| T09 | stair_wing_slab | downtown | The Palace | F4 | 240-310 | 2 | 45 / 26 |
| T10 | telescope_tower | downtown | Elysee | F3 | 400-460 | 2 | 42 / 19 |
| T11 | twisting_twin_towers | downtown | Grove at Grand Bay | F4 | 216-264 | 2 sites | 84 / 12 |
| T12 | triple_tower_podium | downtown | Icon Brickell | F5 | 440 | 1 | 100 / 60 |
| T13 | cantilever_slab_tower | downtown | Jade Signature | F3 | 380-460 | 3 | 120 / 14 |
| T14 | fin_column_tower | downtown | Missoni Baia | F3 | 400-460 | 3 | 48 / 26 |
| T15 | parallelogram_void_tower | downtown | Marquis | F3 | 430-490 | 2 | 52 / 22 |
| T16 | ribbon_canopy_towers | downtown | Brickell City Centre | F5 | 370 | 1 | 95 / 70 |
| T17 | car_lift_cylinder_tower | downtown | Porsche Design Tower | F3 | 360-455 | 2 | 34 / 18 |
| T18 | tiled_mural_midrise | downtown | Bacardi tower and annex | F3 | 104 | 2 | 45 / 36 |
| B01 | deco_stripe_hotel | beach | Carlyle | F1-F2 | 46 | 5 | 40 / 22 |
| B02 | neon_fin_hotel | beach | Colony | F1 | 36 (+fin 50) | 5 | 25 / 20 |
| B03 | sign_tower_prow_hotel | beach | Breakwater | F2 | 36 (+tower 80) | 4 | 27 / 22 |
| B04 | deco_porthole_highrise | beach | The Tides | F2 | 132-160 | 3 | 33 / 18 |
| B05 | streamline_round_corner | beach | Cardozo | F2 corner | 40 | 5 | 40 / 18 |
| B06 | corner_spire_hotel | beach | Essex House | F2 corner | 40 (+spire 84) | 3 | 30 / 16 |
| B07 | lighthouse_corner_hotel | beach | Waldorf Towers | F1 corner | 38 (+light 62) | 3 | 24 / 20 |
| B08 | finned_tower_hotel | beach | Delano | F2 | 168 (+crown 206) | 2 | 26 / 12 |
| B09 | domed_cupola_hotel | beach | National Hotel | F4 | 156 (+dome 196) | 2 | 35 / 21 |
| B10 | curved_resort_slab | beach | Fontainebleau | F4-F5 | 168 | 1 | 55 / 35 |
| B11 | mimo_truss_motel | beach | Vagabond Motel | F2 | 24 (+sign 40) | 4 | 50 / 32 |
| B12 | arcade_village_street | beach | Española Way | F2 | 30-38 | 3 | 50 / 30 |
| R01 | mediterranean_villa | residential | Coral Gables Mediterranean Revival | F1 | 22-28 | 22 | 24 / 20 |
| R02 | coral_rock_cottage | residential | Coral Gables House (Merrick House) | F1 | 18 | 14 | 22 / 20 |
| R03 | veranda_raised_house | residential | The Barnacle | F1 | 30 | 14 | 26 / 16 |
| R04 | pink_layered_house | residential | Spear House (the Pink House) | F1 | 24 | 6 | 16 / 16 |
| R05 | red_ziggurat_lowrise | residential | Babylon Apartments | F2 deep | 72 | 3 | 16 / 16 |
| R06 | tropical_modern_villa | residential | Choeff Levy Fischman houses | F1 | 24 | 20 | 18 / 13 |
| R07 | mimo_garden_apartment | residential | Shore Apartments | F2 | 38 | 12 | 28 / 22 |
| R08 | mosaic_townhouse_row | residential | Aqua, Allison Island | F2 | 36-50 | 8 | 30 / 25 |
| W01 | mural_warehouse | wynwood | Wynwood Walls | F1-F2 | 18-28 | 25 | 20 / 18 |
| W02 | faceted_gallery | wynwood | ICA Miami | F2 | 54 | 3 | 42 / 14 |
| W03 | collage_parking_garage | wynwood | Museum Garage | F4 | 72 | 2 | 58 / 30 |
| W04 | sculpted_car_park | wynwood | 1111 Lincoln Road | F2-F4 | 88 | 2 | 44 / 25 |
| W05 | port_crane_yard | wynwood | PortMiami cranes | F5 | 130 | 1 | 80 / 80 |
| C01 | cupola_bell_tower | downtown civic | Freedom Tower | F3 | 225 | 1 | 48 / 40 |
| C02 | stepped_crown_courthouse | downtown civic | Miami-Dade County Courthouse | F3-F4 | 290 | 1 | 50 / 18 |
| C03 | harbor_market_pavilions | bayfront | Bayside Marketplace | F5 | 30 (+wheel 160) | 1 | 150 / 100 |
| C04 | bayfront_arena | bayfront | Kaseya Center | F5 | 76 | 1 | 75 / 55 |
| C05 | domed_sanctuary | beach civic | Temple Emanu-El | F2 | 36 (+dome 78) | 1 | 25 / 25 |
| C06 | folded_roof_lake_stadium | beach scenery | Miami Marine Stadium | waterside | 52 | 1 | 45 / 45 |
| C07 | lighthouse_water_tower | residential scenery | Alhambra Water Tower | 30 x 30 | 112 | 1 | 22 / 22 |
| C08 | lifeguard_stand | beach scenery | Miami Beach lifeguard towers | 14 x 18 | 22 | 12 | 13 / 13 |
| C09 | causeway_bridge | lake | Venetian Causeway | the bridge | deck 20.2 | 1 | 164 / 90 |

Mix: 18 towers (4 supertall landmarks), 12 beach, 8 residential, 5 Wynwood, 9 civic and scenery (two of them
downtown towers of their own: C01, C02), 52 in all.

---

## 5. Downtown towers

### T01 `stacked_cube_supertall`
Downtown, landmark, reuse 1, F5.

**Inspiration.** Waldorf Astoria Hotel & Residences Miami, 300 Biscayne Boulevard, Downtown. Sieger Suarez Architects
with Carlos Ott. 100 storeys, 1,049 ft (319.7 m), the first supertall in Florida; under construction (concrete past
floor 60 in February 2026, completion now reported for 2028). Nine glass cubes stacked and shifted (one report counts
ten) "to emphasize suspension and height", on a 10-storey parking base.
[Dezeen 2022](https://www.dezeen.com/2022/05/13/sieger-suarez-architects-carlos-ott-supertall-miami-waldorf-astoria/),
[Florida YIMBY 2026](https://floridayimby.com/2026/02/waldorf-astoria-hotel-residences-miami-advances-into-sixth-cube-as-construction-passes-60-floor).

**What makes it itself.** A wobbling stack of identical glass cubes, each slid sideways off the one below, with a dark
shadow joint between every two.

**Massing.** K2 podium 130 x 110 x 80 (8 levels). Nine cubes 66 x 66 x 66 (5.5 floors each) from y = 80 to 674. Each
cube's centre shifts 7 to 10 studs from the one below, alternating in X and Z so the stack zig-zags; cubes 3, 6 and 8
also turn 3 degrees about Y (Ott: "shifting and rotating"). A crown 26 tall on top: pool deck slab and a cabana box.

**Facade.** Each cube: a glass box (glass_silver), 4 bright_white corner posts 1.5 x 1.5 full height, a white top and
bottom frame slab 1.2 thick flush with the posts, and 4 thin floor-line bands 0.3 tall set 0.2 proud (**U** per cube).
Between cubes a recessed joint: a dark box 58 x 2 x 58, #1E2328 SmoothPlastic, so each cube reads alone in shadow.

**Night.** Every cube's top frame slab lights (`crown`): nine white rings up the sky. The top cube's glass glows warm
(`window`). Podium LED strip (`led_edge`). Red aviation beacon on the crown (`beacon`).

**Parts.** Podium 8, cubes 9 x 12 = 108 (bands U), crown 4: 120 plain, 85 U.

**Variants.** One-off. The zig-zag sequence and which cubes turn come from the seed; mirror to suit the site.

**As built (2026-10-26, after the renderings).** The cubes are flush silver glass held by slim metal angles, a base
plate (the soffit under each overhang) and a top band that is the ring of light, not chunky white frames; none turn
(the renderings show them square). Each slides about a sixth of its width (about 12 of 72). One dark core runs up the
stack's axis and shows only in the 6-stud joints. Rhythms: zig-zag, spiral, a lean that snaps back.
*Studio pass (2026-10-26):* the core alone showed sky beside it in every joint, so the cubes looked balanced on a
stalk. Each joint is now a dark slab filling the overlap of the two cubes it joins (2.5 in from both), a full-width
shadow line by day; at night the joints glow (`crown`) instead of the top bands: nine seams of light. 130 to 152 parts.

### T02 `exoskeleton_tower`
Downtown, landmark, reuse 1, F3.

**Inspiration.** One Thousand Museum, Biscayne Boulevard, Downtown. Zaha Hadid Architects (begun by Zaha Hadid; ODP
architect of record). 62 storeys, 707 ft, completed 2019. A curving exoskeleton of about 5,000 glass-fibre reinforced
concrete pieces stands in front of the glass and carries the loads; nicknamed "the Scorpion Tower"; rooftop pool under
a faceted metal ceiling, possibly a helipad.
[Wikipedia](https://en.wikipedia.org/wiki/One_Thousand_Museum),
[Dezeen 2018](https://www.dezeen.com/2018/02/15/one-thousand-museum-tower-amenity-spaces-zaha-hadid-tops-out-miami-florida/).

**What makes it itself.** White curving ribs that sweep from thick corner legs at the street, in toward the middle of
each face, and back out to the corners at the top, like a web over dark glass.

**Massing.** Square glass core 60 x 60 x 495 on a 100 x 100 plaza. No podium: the ribs come straight to the ground.

**Facade.** Per face, two ribs 2.4 x 2.4 in section: each starts at a corner, bows inward along a smooth curve to
within 10 studs of the face centre at mid-height, and returns to the corner at the roof, built as 12 straight segments
each turned in the face's plane (**U** per face). Corner legs at the base flare out to 8 x 8 over the first 40 studs
(3 segments per corner), and the ribs flare out again over the top 40 to carry a roof slab 70 x 70. Slab edges every
second floor sit just behind the ribs (**U**). Ribs bright_white; glass #3E5963, refl 0.2; slab edges #E8E6E0.

**Signature.** A thin helipad ring on the roof (one flat cylinder 34 across, with a 30-across disc in it).

**Night.** The upper four segments of every rib light cool white (`crown`): a glowing web at the top; the glass stays
dark.

**Parts.** Core 1, ribs 4 x 2 x 12 = 96, legs and flares 24, slab edges 20, roof and helipad 4, plaza 3: 148 plain;
40 U (one union per face plus the slabs).

**As built (2026-10-26, after street photos).** Per face a white trunk rises in the middle and splits at a fifth of
the height into two ribs that bow out round a tall eye of dark glass (three fifths of the face at its widest), cross
near the top and sweep out to the corners, which rise into four pointed horns over a concave crown. At the street each
corner stands on a leg; between leg and trunk an arch (haunches cut round its top) shows a grey louvred screen over the
lobby, under a white band. Above it, round balconies wrap each corner every two floors, reaching the ribs, so the
stacks shrink and grow with the eye. About 215 parts.
*Studio pass (2026-10-26):* reads as its inspiration from the street to across the city; the arches' screens had one
texture tile their full height, which blurred into a smear, and now tile in 3-stud louvre rows. 164 to 211 parts.

**Variants.** One-off.

### T03 `tiered_curve_crown_tower`
Downtown, landmark, reuse 1, F4.

**Inspiration.** Miami Tower (formerly CenTrust Tower and Bank of America Tower), Downtown. I.M. Pei & Partners (Pei
Cobb Freed), 1987. 47 storeys, 625 ft, built on the air rights over a 10-storey city parking garage, with the
world's only elevated metro station inside a skyscraper (the Metromover's Knight Center station). It steps back three times along a gently
curved facade that faces southeast to the river and the bay; the other sides are flat facets. Its "three glass tiers"
are lit by LEDs (a $1.5 million system from 2012): white most nights, colours for holidays and game nights.
[Wikipedia](https://en.wikipedia.org/wiki/Miami_Tower),
[Miami New Times](https://www.miaminewtimes.com/arts/miami-icons-the-miami-tower-colorful-chameleon-of-the-skyline-6487910).

**What makes it itself.** Three curved tiers climbing toward the bay like a stepped quarter-wheel, and at night they
glow in one colour.

**Massing.** K2 garage 200 x 110 x 100 (10 levels) filling the site. The tower stands on the garage: plan 90 x 64,
the bay-facing long side a convex arc (8 facets, or one CSG ring segment). Tier 1 runs to y = 330, tier 2 sets back 12
on the curved side to y = 390, tier 3 sets back 12 more to y = 445. Each tier ends in a curved glass cap: a quarter
round that rises from the tier's curved edge back to the next face (from photos; check against a reference image).

**Facade.** Pale facade #E9E9E6 SmoothPlastic with horizontal glass ribbons glass_blue, one per two floors (**U**);
the flat sides are three facets each. A transit guideway stub can enter the garage at level 3 (decor, optional).

**Night.** The three caps are the light show: kind `crown_show`, white by default, the night's colour from a list in
Config (section 11). Garage LED strip.

**Parts.** Garage 10, tiers 3 x (curved face 8 + flat facets 3) = 33, caps 3 x 8 = 24, ribbons 30, crown 3, misc 10:
110 plain, 70 U.

**As built (2026-10-26, after photos).** The photos settle the open point above: the tiers are arcs in **plan**, not
quarter rounds in section. The tower is a D (flat back and sides, a convex arc to the show face); each tier's arc
stands about 12 behind the one below and each tier is a little narrower, so the show face climbs as three stacked
curved drums while the flat sides run up. Notched dark corners where arc meets side. The skin is a pinstripe (a pale
band and a glass ribbon every floor, or half floor); the top floors of each tier are its light band (crownShow), which
by day is a shade paler, so at night the tower is three glowing curved rings. About 111 parts.
*Studio pass (2026-10-26):* blue glass with white pinstripes, a 75 x 72 plan with a deep arc and 12-stud setbacks
read as any round glass condo. Now: a pale aluminium skin with a dark glass ribbon per stripe (sources describe the
shell as "black and white bars"), the light bands dark glass by day (each tier ends in a dark crown band, lit at
night), a 90 x 64 plan with a gentle arc (bulge 0.35 of the half-width), 16-stud setbacks and each tier 10 % narrower.
98 to 110 parts.

**Variants.** One-off.

### T04 `sail_supertall`
Downtown waterfront, landmark, reuse 1, F3.

**Inspiration.** Aston Martin Residences, 300 Biscayne Boulevard Way, Downtown, at the river mouth. BMA (Bodas Miani
Anger) with Revuelta Architecture International. 66 storeys, topped off at 816 ft. A flat, curved envelope likened to
a boat's sail, shaped for hurricane winds and ventilation, with a vertical curve.
[Dezeen 2024](https://www.dezeen.com/2024/05/02/aston-martin-bma-residential-skyscraper-miami/),
[Florida YIMBY](https://floridayimby.com/?p=8634).

**What makes it itself.** A lens-shaped glass blade, convex toward the water and nearly flat behind, whose leading
edge sweeps up into a raked tip.

**Massing.** Plan a lens 100 x 48 (CSG: IntersectAsync of two cylinders of radius 160 whose centres are 270 apart; or
10 facets on the convex face and 4 on the back). Height 520 to the top floor; the top 40 studs rake down from the
leading edge to the trailing edge (the sail's head). Podium K2 110 x 90 x 60 on the city side.

**Facade.** Glass_aqua on the convex face, glass_silver on the back. Balcony slabs every second floor on the convex
face only, each a thin lens matching the face (one CSG slab cloned, **U**), with glass rails (**U**).

**Night.** A thin vertical light line up the leading edge (one part 1 x 480 x 1, `crown`); every fourth balcony slab
edge `led_edge`.

**Parts.** Core 1 (CSG lens), rake 6, slabs 22 (each a CSG lens), rails 22, podium 8, light 1, lobby 4: 64 plain,
22 U. Without CSG the curved slabs alone are over 200 facets, so this one needs CSG.

**Variants.** One-off; mirror to point the sail at the lake.

**As built (2026-10-26, after photos; no CSG).** Plan a teardrop: a round glass bow (a cylinder) and two convex faces
tapering to a white spine at the tail, the front fuller. The faces are solid glass facets reaching the middle line, so
cuts and roofs read solid. White bands every two (or three) floors wrap the bow (a disc) and run along the faces
(straight strips, one per two facets), over glass ruled white every floor; every fourth row is a ring of light. At
three quarters of the height the bow stops at a dark lip deck, and the head rises behind it with its leading edge
raked forward over the lip (white soffit wedges under a dark raked edge), as in the photos. About 195 parts.
*Studio pass (2026-10-26):* the soffit wedges followed each facet's chord, not the sail's axis, so they and the head's
glass (which reached in toward the bow, where the cut is higher) left dark slivers and blue triangles under the head.
Now the soffit is four wedges along the sail's axis, one smooth plane, each with a white core block over it, and the
head's facets are 3-stud glass skins standing on the cut. Palette 1's glass is paler and the bands bolder (2 thick),
so the sail reads pale silver, not blue. 142 to 202 parts.

### T05 `sawtooth_office_tower`
Downtown, reuse 1, F4.

**Inspiration.** Southeast Financial Center, Downtown. Skidmore, Owings & Merrill (Edward Charles Bassett) with Spillis
Candela & Partners, 1984. 55 storeys, 764 ft. A "saw-tooth" northeast corner (up to
16 corner offices a floor), setbacks from the 43rd floor, a V-notch down the middle of the west face that is lit at
night, a 15-storey parking annex, and a steel and glass space-frame canopy over the plaza (removed 2020-21).
[Wikipedia](https://en.wikipedia.org/wiki/Southeast_Financial_Center),
[engineer's page](https://vdassoc.com/?p=554).

**What makes it itself.** One corner cut into a zig-zag of steps from street to sky, a stepped top, and a glowing
vertical notch.

**Massing.** Slab 92 x 70 x 530 at the front of the site, K2 annex 90 x 90 x 150 behind it. The northeast corner is
cut into 4 steps of 8 x 8 for the full height. From y = 410 the top steps back three times (10 studs, 40 tall each)
on the sawtooth side.

**Facade.** Pale stone spandrels granite_pale with dark glass ribbons glass_dark, one ribbon per floor (**U**); stone
and ribbons from photos, check a reference. The V-notch: two boxes meeting at 90 degrees, 6 deep, full height, centred
on the west face, with a 1-stud light strip in its crease.

**Plaza.** A space-frame canopy 60 x 40 at 30 high on 6 columns: 6 + 6 thin bars and a glass sheet.

**Night.** The notch strip (`crown`), and the three top setbacks' edges (`led_edge`).

**Parts.** Slab and steps 8, setbacks 3, ribbons 40, notch 3, annex 8, plaza 19, lobby 4: 85 plain, 46 U.

**Variants.** One-off (a mirrored second copy only if the layout needs more office mass, far from the first).

### T06 `standard_glass_slab`
Downtown, the reusable standard tower, reuse 10, F3.

**Inspiration.** Panorama Tower, Brickell. Kobi Karp design, Moshe Cosicher architect of record, completed 2018. 85
marketed storeys (81 by CTBUH), 868 ft to its spire, the tallest completed tower in Miami's list; glass with
protruding glass balconies, a parking pedestal, an amenity deck about the 48th floor, and roofs that extend outward at
several levels with recessed facades under them.
[Wikipedia](https://en.wikipedia.org/wiki/Panorama_Tower),
[facade contractor](https://pro-bel.com/project-profiles/panorama-tower/).

**What makes it itself.** The clean Brickell condo slab: glass with crisp white balcony lines, broken twice by a deep
"sky deck" overhang, a parking podium below and a needle spire on top. It is the city's background, done well.

**Massing.** K2 podium 100 x 90 x 50-90. Slab 72 x 44 on the podium. Two sky decks at 1/3 and 2/3 of the height: a
slab grown 5 studs on every side, 2 thick, with the floor under it recessed 4 (a darker glass band). Crown: the top
floor overhangs 3, then a spire 2 x 2 x 60 (variant).

**Facade.** K1: slab edges every second floor on the two long faces, 4 deep (**U**), glass rails (**U**); the short
faces are glass with one vertical fin each.

**Colour sets.** (a) glass_aqua and bright_white; (b) glass_blue and bright_white; (c) glass_silver and #D6D8DA;
(d) #2C4E57 and bright_white.

**Night.** By seed, either two runs of floors glow warm (glass split at a sky deck, `window`) or every fourth slab
edge glows (`led_edge`). Spire beacon red.

**Parts.** Podium 8, core 2, sky decks 6, crown 3, spire 2, slab edges 20, rails 20: 60 plain, 24 U.

**Variants.** Height 180 to 480; podium 4 to 9 levels; spire on or off; mirrored; turned 90 degrees on corner sites;
four colour sets. Never two copies side by side.

### T07 `flatiron_wedge_tower`
Downtown, reuse 2, F3 corner sites only.

**Inspiration.** Brickell Flatiron, Brickell, on a triangular lot where South Miami Avenue and SE 1st Avenue diverge.
Luis Revuelta, 2019. About 64 storeys and 700 ft. The plan keeps the triangle but softens it with elliptical curved
balconies; the bay side is "wind-swept, kinetic", the city side flatter and linear; the penthouse and crown facades
were fabricated by Zahner.
[Wikipedia](https://en.wikipedia.org/wiki/Brickell_Flatiron),
[Zahner](https://www.azahner.com/works/brickell-flatiron).

**What makes it itself.** A wedge pointing at the street corner, its rounded nose wrapped in bulging balconies, under a
metal crown.

**Massing.** A right-triangle plan 90 x 90, the hypotenuse facing the street corner (the grid is square, so the long
face looks diagonally across the junction); all three corners rounded (Cylinder r = 8). Height 400 to 490. K2 podium
on the two inner sides.

**Facade.** The hypotenuse face: a curved balcony slab every second floor bulging 6 studs out at the middle (a thin CSG
lens, cloned, **U**) with glass rails. The two flat faces: glass with vertical fins 1 x 3 every 8 studs (**U**).

**Crown.** The top 24 studs: a three-sided metal screen, champagne #B9A684 Metal, rising toward the middle of the
hypotenuse (one sloped panel per side; the slope is from photos).

**Night.** The crown screen glows from inside (`crown`, or `neon_amber` in a warm variant).

**Parts.** Core and rounds 5, slabs 18, rails 18, fins 20, crown 3, podium 6: 70 plain, 18 U.

**Variants.** Mirrored (which inner side is longer); glass_aqua or glass_silver; crown champagne or white.

### T08 `sky_court_slab`
Brickell, reuse 2, F4 along a street.

**Inspiration.** The Atlantis, 2025 Brickell Avenue. Arquitectonica with Hervin Romney, 1980-82. 20 storeys, 223 ft.
A flat blue supergrid wall with an off-centre void: a 37-foot cube cut through the building, a five-storey "sky court"
holding a whirlpool, a red spiral staircase and a palm tree against a waving yellow wall; a red geometric structure on
the roof. The wall and its void became a symbol of Miami and of Arquitectonica.
[Wikipedia](https://en.wikipedia.org/wiki/Atlantis_Condominium),
[Miamism](https://miamism.com/miami-architecture-atlantis/).

**What makes it itself.** A broad blue grid slab with a square hole punched through it, a palm and a red spiral stair
standing in the hole.

**Massing.** Slab 120 x 32 x 205. The void 40 x 40 (37 ft), right through the depth, its floor at y = 110, its
centre 25 studs off the slab's middle. The slab is built round the hole as four boxes (below, above, left, right).

**Facade.** Street face: glass atlantis blue #2F6FB3 (Glass, refl 0.15) with a supergrid of bright_white bars 1 x 1,
6 vertical and 4 horizontal, the squares 4 floors tall (**U**). Back face: balcony bands every floor (**U**). In the
void: walls and soffit #F3E05A (yellow), a waving back wall (3 panels at angles), a red #D3302B spiral stair (a pole
and 8 treads turning 45 degrees each), a palm (trunk and 3 fronds), a whirlpool disc deco_aqua.

**Roof.** A red #D3302B triangular frame 30 wide standing on the roof (three bars, from photos).

**Night.** The void glows: the yellow back wall `neon_amber`, dim. The whole hole lights up at night, the slab around
it stays blue.

**Parts.** Slab 8, grid 10, back bands 16, void 18, roof 3, lobby 3: 58 plain, 34 U.

**Variants.** Mirrored (hole left or right); grid white or lemon; glass atlantis blue or #2E6F8E teal.

### T09 `stair_wing_slab`
Brickell, reuse 2, F4.

**Inspiration.** The Palace, 1541 Brickell Avenue. Arquitectonica, 1979-81. 42 storeys, 400 ft. A conventional main
tower with a bright-orange staircase-shaped extension pushing out of it.
[Wikipedia](https://en.wikipedia.org/wiki/The_Palace_(Miami)),
[Brickell guide](https://melvagarcia.com/blog/3-iconic-buildings-in-brickell).

**What makes it itself.** A plain white slab with a giant orange staircase climbing out of its front.

**Massing.** Slab 100 x 36 x 240-310. The wing: 8 orange blocks in front of the slab, stepping down from 120 tall
against the slab to 24 tall at the street, each step 12 lower and 10 further out (80 out in all), 40 wide.

**Facade.** Slab white_stucco with dark glass ribbons per floor (**U**). Wing #E8722E Plaster with a bright_white
cap trim on each step. Each step's riser is a window band (glass_dark).

**Night.** The eight risers glow warm (`window`): a lit staircase.

**Parts.** Slab 2, ribbons 20, wing 8, risers 8, trims 4, roof 3: 45 plain, 26 U.

**Variants.** Wing orange, terracotta #C4553A or sunshine #F2C230; mirrored; height.

### T10 `telescope_tower`
Edgewater, reuse 2, F3.

**Inspiration.** Elysee, Edgewater. Arquitectonica (Bernardo Fort-Brescia), 2021. 57 storeys, 649 ft. Three tiers
that get wider as they rise, "a retractable telescope standing on its narrow end", each tier a vertical neighbourhood;
the top-heavy form needed a perimeter structure that steps outward.
[Thornton Tomasetti](https://www.thorntontomasetti.com/project/elysee),
[BD+C](https://www.bdcnetwork.com/building-sector-reports/high-rise-construction/news/55160273/three-tiered-57-story-high-rise-development-from-arquitectonica-coming-to-miami).

**What makes it itself.** Upside-down: each of its three glass tiers is wider than the one beneath it.

**Massing.** Tier 1 56 x 56 from y = 16 to 160; tier 2 66 x 66 to 300; tier 3 76 x 76 to 440; roof crown to 460. A
lobby box 50 x 50 x 16 below. Each step out has a white soffit 2 thick underneath.

**Facade.** Glass_aqua per tier, slab edges every second floor 2 deep (**U**), so the tiers read as stacked drums of
lines.

**Night.** The two overhang soffits and the roof edge glow (`led_edge`): three rings, widening upward.

**Parts.** Tiers 3, soffits 3, slab edges 24, crown 3, lobby 3, plaza 6: 42 plain, 19 U.

**Variants.** Widen to one side only (the "bay" side cantilevers, the back stays straight); glass_aqua or glass_silver.

### T11 `twisting_twin_towers`
Coconut Grove style, placed downtown or on the lake's edge, reuse 2 sites (2 towers each), F4.

**Inspiration.** Grove at Grand Bay, Coconut Grove. BIG (Bjarke Ingels Group), 2016. Two 20-storey towers whose
floor plates rotate about 3 ft a floor from the 3rd to the 17th floor, a total twist of about 38 degrees, the top
floors aligned; floor plates extend into balconies and deep overhangs that shade the glass.
[BIG](https://big.dk/projects/the-grove-at-grand-bay-2696),
[Dezeen 2016](https://www.dezeen.com/2016/11/09/big-completes-grove-at-grand-bay-twisting-towers-miami/).

**What makes it itself.** Two towers that twist like wrung towels, toward each other.

**Massing.** Each tower 18 to 22 floors (216 to 264 studs). Every floor is one white slab, a 56 x 40 rectangle with
chamfered corners, and one glass box 48 x 32 x 11 on it, both turned 2.5 degrees more than the floor below between
floors 3 and 17, then held. The two towers stand 40 apart and twist the opposite way (mirrored).

**Facade.** The slabs make the facade: bright_white, 1.2 thick, 4 proud of the glass; glass #7FA7B5.

**Night.** Every third slab edge glows (`led_edge`), so the twist draws itself in light.

**Parts.** Per tower 2 per floor = 40; site 84 with the garden: 84 plain, 12 U (a slab union and a glass union per
tower).

**Variants.** Twist 30 to 45 degrees; height; which way each tower turns.

### T12 `triple_tower_podium`
Brickell, reuse 1, F5.

**Inspiration.** Icon Brickell, 495 Brickell Avenue. Arquitectonica (Bernardo Fort-Brescia and Laurinda Spear),
interiors by YOO with Philippe Starck, topped off 2008. Two identical 58-storey towers (about 588 ft to the roof) and a
50-storey hotel tower on a shared 15-storey podium raised over 100 ft above the waterfront, with pools and a spa on
it; the entrance drive is lined with giant columns modelled on monolithic stone heads, some with lit "eyes".
[Wikipedia](https://en.wikipedia.org/wiki/Icon_Brickell),
[e-architect](https://www.e-architect.com/miami/icon-brickell).

**What makes it itself.** Three slender towers on one huge raised deck, and at the street a colonnade of giant
monoliths with glowing eyes.

**Massing.** Podium 210 x 120 x 84 (K2 screens on the street sides). On it a pool deck (blue slab 40 x 16 and
loungers) and two identical towers 54 x 40 rising 330 above the podium (to 414), and a third 48 x 40 rising 270 (to
354). Each tower's narrow ends are rounded (Cylinder, r = 20).

**Facade.** K1 slab edges every third floor (**U**), glass #4E7D92, bright_white slabs.

**Street.** A porte-cochere along the front: 10 monolith columns 6 x 6 x 28, Slate #77736B, each with a slanted top
and two eye slots (a thin strip near the top). These are abstract monoliths, not copies of any sculpture.

**Night.** The eye slots glow amber (`neon_amber`); every sixth slab edge `led_edge`.

**Parts.** Podium 10, towers 3 x 17 = 51, deck 8, columns 20, misc 11: 100 plain, 60 U.

**Variants.** One-off; the hotel tower can be left out on a smaller F4 site.

### T13 `cantilever_slab_tower`
Collins Avenue style, downtown or beachfront, reuse 3, F3.

**Inspiration.** Jade Signature, Sunny Isles Beach. Herzog & de Meuron, completed 2018. 57 storeys, 192 residences.
Cantilevered floor slabs make a rhythmic facade (the terraces add about 30 % to each home); sculptural hourglass-shaped
concrete columns stand at the ends of the wrap-around balconies; glass railings lean outward to cut reflections.
[Dezeen 2018](https://www.dezeen.com/2018/03/12/herzog-de-meuron-jade-signature-skyscraper-completes-sunny-isles-miami/),
[Field Condition](https://www.fieldcondition.com/blog/2018/3/14/construction-update-jade-signature-herzog-de-meuron).

**What makes it itself.** Deep white floor slabs whose edges ripple in and out up the tower, held at the corners by
stacks of hourglass columns.

**Massing.** Glass core 64 x 46 x 380-460. Slabs every floor (or every second floor without unions), their projection
following a slow wave: 5, 6, 8, 6, 5 studs, repeating every 5 floors.

**Facade.** Concrete white #EDEBE6 SmoothPlastic slabs 1.2 thick; at each corner of each slab an hourglass column one
floor tall (two wedges meeting at a waist 1.6 wide, 4 wide at top and bottom; **U** per face); glass rails leaning 10
degrees out (**U**); glass #5A8A97.

**Night.** Every fifth slab edge `led_edge`.

**Parts.** Plain with slabs every second floor: core 1, slabs 18, columns 72, rails 18, roof 4, lobby 4, podium 3 = 120;
every floor with unions: 14 U.

**Variants.** Wave amplitude; colour of the column concrete (white or warm #E6DED0); height.

### T14 `fin_column_tower`
Edgewater, reuse 3, F3.

**Inspiration.** Missoni Baia, Edgewater, on the bay. Asymptote Architecture (Hani Rashid and Lise Anne Couture),
completed 2023. 57 storeys, 649 ft. Aerodynamic fin-like super-columns at the corners leave the glass nearly
mullion-free (echoing yacht sails and hulls); cascading, sculptural balconies.
[Asymptote](https://asymptote.net/missoni_baia),
[Global Design News](https://globaldesignnews.com/hani-rashids-57-story-luxury-condominium-missoni-baia-tower-on-miamis-biscayne-bay-rises-near-completion/).

**What makes it itself.** Four white blade-like corner fins running the full height and raking off at the top, with a
cascade of balconies stepping across the bay face.

**Massing.** Glass core 64 x 52 x 400-460. At each corner a fin 4 thick and 14 deep, set diagonally, full height, its
top cut at a rake (box plus wedge). K2 podium low (3 levels) behind.

**Facade.** Clear blue glass #7FA9B8 with no mullions. On the bay face, balcony bands every 4 floors whose length
shifts left and right by 12 studs band to band (a cascade), with glass rails (**U**).

**Night.** A light strip on each fin's outer edge (`crown`): four vertical lines.

**Parts.** Core 1, fins 8, strips 4, balconies 12, rails 12, podium 6, crown 2, lobby 3: 48 plain, 26 U.

**Variants.** Fin colour white or #D9D4C8; cascade left or right; height.

### T15 `parallelogram_void_tower`
Downtown on the boulevard, reuse 2, F3.

**Inspiration.** Marquis, Biscayne Boulevard, Downtown. Arquitectonica, 2009. 63 storeys, 702 ft. Interlocking
parallelograms clad entirely in clear, slightly blue glass; an eight-storey opening through the tower, with the lap
pool running through it, projects toward the boulevard and is dramatically lit at night; continuous glass-railed
balconies on two faces.
[Wikipedia](https://en.wikipedia.org/wiki/Marquis_Miami),
[e-architect](https://www.e-architect.com/miami/marquis).

**What makes it itself.** A tall slanted-edged glass tower with a wide glowing slot cut right through it high up.

**Massing.** Two prisms 66 x 44 locked side by side, each with one end cut at 15 degrees (box plus wedge), one 40
taller (tops at 450 and 490). The void: 6 floors (72 tall), 44 wide, right through the depth at y = 300, its floor a
pool slab (deco_aqua) pushing 6 out toward the main street.

**Facade.** Glass_clear; balconies on two faces every second floor (**U**) with rails (**U**).

**Night.** The void's ceiling and back wall glow (`neon_violet` at low brightness, or `crown`).

**Parts.** Prisms 6, void framing 6, pool 2, balconies 16, rails 16, lobby 3, crown 3: 52 plain, 22 U.

**Variants.** Void glow violet or white; mirrored; height.

### T16 `ribbon_canopy_towers`
Brickell, reuse 1, F5.

**Inspiration.** Brickell City Centre. Arquitectonica, with the Climate Ribbon by Hugh Dutton Associés, 2016. Three
high-rises (a hotel and two condo towers, about 500 ft and 45 floors each) over a five-storey shopping centre with
shaded, semi-enclosed concourses; the Climate Ribbon is an undulating, T-shaped canopy of faceted steel, glass and fabric blades between the
buildings that shades the streets, lets the trade winds through and catches rain.
[Wikipedia](https://en.wikipedia.org/wiki/Brickell_City_Centre),
[ENR](https://www.enr.com/articles/38609-builders-wrap-brickell-center-with-a-sustainable-ribbon).

**What makes it itself.** A long white wave of canopy floating over a pedestrian street between glass towers.

**Massing.** Three mall blocks 40 tall around a pedestrian street (not a road) that crosses the site; on them three
glass towers 50 x 50 rising to 330, 350 and 370, each top cut by one chamfer facing a different way.

**Ribbon.** At about y = 50 over the street: 14 thin canopy segments (Fabric #F7F7F4 and glass #CFE3EA alternating),
each turned so the line rises and dips like a wave, 10 fin blades hanging under it, 6 slender supports.

**Facade.** Towers K1 with white frames; mall glass storefronts and alu louvres.

**Night.** The ribbon's underside glows (`led_edge` on the segments); the tower chamfers `crown`.

**Parts.** Mall 12, towers 36, ribbon 30, storefronts 9, misc 8: 95 plain, 70 U.

**Variants.** One-off.

### T17 `car_lift_cylinder_tower`
Collins Avenue style, downtown or beachfront, reuse 2, F3.

**Inspiration.** Porsche Design Tower, Sunny Isles Beach. Sieger Suarez Architects, 2017. About 60 storeys, 641 ft.
A black cylindrical tower with three car elevators in a glass shaft running the full height, delivering residents'
cars to sky garages beside their homes; robotic parking for 284 cars.
[Wikipedia](https://en.wikipedia.org/wiki/Porsche_Design_Tower_(Sunny_Isles_Beach)),
[Designboom](https://www.designboom.com/technology/car-garage-home-residential-design-supercar-towers-miami/).

**What makes it itself.** A black glass cylinder with a lit glass lift shaft up one side, cars visibly parked in it at
different heights. In a driving game, this is the one players will point at.

**Massing.** Cylinder 64 across, 360 to 455 tall (a Cylinder part turned upright). The shaft: a glass box 12 x 12 full
height, half sunk into the front.

**Facade.** Glass black #1C2228, refl 0.3; silver ring balconies every second floor (flat cylinders 66 across, alu,
**U**). In the shaft: two lift platforms with a simple car-shaped block on each (2 boxes, original shape), at seeded
heights.

**Night.** The shaft glows cool white (`crown`): a vertical light line; every sixth ring `led_edge`.

**Parts.** Cylinder 1, rings 18, shaft 1, platforms and cars 6, crown 2, base 6: 34 plain, 18 U.

**Variants.** Black or bronze #3B3128 glass; height; shaft facing the street or the water. (Moving the lifts is a
possible later client-side decor touch, not gameplay.)

### T18 `tiled_mural_midrise`
Biscayne Boulevard (Edgewater), reuse 2, F3.

**Inspiration.** Bacardi Buildings, Biscayne Boulevard (now the National YoungArts Foundation). The 8-storey tower
(Enrique Gutierrez, 1963) has its north and south end walls covered full height in blue-and-white azulejo tile murals
by Francisco Brennand (about 28,000 hand-painted tiles), its east and west faces minimal tinted glass, with a
floating, Mies-like quality. The "Jewel Box" annex (Ignacio Carrera-Justiz, 1973) is a square two-storey box with
walls of coloured glass after a design by Johannes Dietz, hung about 47 ft above its plaza.
[Wikipedia](https://en.wikipedia.org/wiki/Bacardi_Buildings_(Miami)),
[SAH Archipedia](https://sah-archipedia.org/node/24058).

**What makes it itself.** A crisp glass block whose two ends are giant blue-and-white tile walls, beside a stained-glass
cube floating on one stem.

**Massing.** Tower 70 x 40 x 104 (8 floors), the ground floor recessed 6 all round as a glass lobby so the block
floats. Annex: a 40 x 40 x 28 box on a 10 x 10 core, its underside at y = 50.

**Facade.** End walls: CeramicTiles in azulejo blue #2C5DA8 and white #F2F4F7, built as 4 vertical panels per wall plus
8 small square motifs in an original pattern (not a copy of the Brennand murals). Long faces: dark glass #2F3C45 with
thin mullions every 6 (**U**). Annex walls: 8 Glass panels in amber #D9A441, ruby #A8323A, cobalt #2E4FA0 and green
#3E8A5A.

**Night.** The annex panels glow in their own colours (`stained`, section 11); the tower lobby `window`.

**Parts.** Tower core 1, end walls 8, motifs 8, mullions 10, lobby 2, roof 2; annex core 1, panels 8, roof 1, plaza 4:
45 plain, 36 U.

**Variants.** Tile colour blue or sea green #2E8C7E; annex on or off.

---

## 6. Beach strip: Art Deco and MiMo

All hotels front the road with a terrace (a raised slab and 2 to 4 cafe umbrellas: one pole and one flat cylinder
each) and carry an invented name sign (section 11). Deco facades are symmetrical unless noted.

### B01 `deco_stripe_hotel`
Beach, reuse 5, F1 to F2.

**Inspiration.** The Carlyle, 1250 Ocean Drive. Kiehnel & Elliott (Richard Kiehnel), 1939-41. Three wide fluted
columns ("vertical racing stripes") capped with semicircular eyebrows and a ziggurat roofline flank the two centre
bays; the rule of thirds; eyebrows that wrap round the corners.
[MDPL inventory](https://www.ruskinarc.com/mdpl/Ocean-CollinsDistrict/4657-1250%20Ocean%20Dr/view),
[Bluffton survey](https://homepages.bluffton.edu/~SULLIVANM/florida/miami/carlyle/carlyle.html).

**What makes it itself.** Three tall fluted stripes that run up past the roofline, each crowned by a half-moon and a
stepped cap.

**Massing.** K3 body 60 x 40 x 36 (3 floors), parapet 4 more, stepping to 46 over the centre.

**Facade.** Three pilasters 6 wide and 2 proud, from the terrace to 6 above the parapet, each with two dark flute
strips (**U**), a half-disc eyebrow at the top (Cylinder 8 across, 0.6 thick, half sunk) and a two-step cap. Between
them two bays with K4 eyebrows per floor (6) and glass ribbons (**U**); the outer eyebrows wrap 8 round each corner.

**Colours.** Body white_stucco; pilasters and eyebrow edges in one pastel per copy (deco_lemon, deco_mint or
deco_pink); trim deco_turquoise; glass_dark.

**Night.** The flute strips become neon lines (`neon_cyan` or `neon_pink`); the name sign (`sign`).

**Parts.** Body 4, pilasters 3, flutes 6, discs 3, caps 6, eyebrows 10, glass 6, sign 1, terrace 1: 40 plain, 22 U.

**Variants.** Pastel set; 3 or 4 floors; sign name.

### B02 `neon_fin_hotel`
Beach, reuse 5, F1.

**Inspiration.** The Colony Hotel, 736 Ocean Drive. Henry Hohauser, 1935, often called the first Streamline Moderne
building on Ocean Drive (steel corner windows, a neon marquee). Its inverted-T sign, a vertical fin and a boxy marquee
readable from both sides and the beach, glows blue at night; continuous eyebrows and ribbon windows band the three
storeys, picked out in turquoise.
[MDPL inventory](https://www.ruskinarc.com/mdpl/Ocean-CollinsDistrict/4626-736%20Ocean%20Dr/view),
[Miami New Times](https://www.miaminewtimes.com/arts/miami-icons-the-colony-hotel-the-most-famous-art-deco-building-on-ocean-drive-6487550).

**What makes it itself.** A low white three-storey block with one tall neon fin standing up from its marquee: the
classic Ocean Drive postcard.

**Massing.** Body 50 x 40 x 36. Centre: a vertical fin 2 thick, 8 deep, from the marquee to 50 (14 above the parapet);
the marquee a box 30 x 3 x 10 over the door.

**Facade.** Three K4 eyebrows across the front wrapping 6 round each corner; a turquoise stripe under each; glass
ribbons wrap the corners (corner windows); stucco spandrels.

**Colours.** white_stucco, deco_turquoise, glass_dark; fin and marquee white by day with blue letters.

**Night.** Fin and marquee `neon_blue` (#3D7BFF), the name on both faces of the fin and on the marquee.

**Parts.** Body bands 6, eyebrows 9, stripes 3, fin 2, marquee 1, door 1, parapet 1, terrace 2: 25 plain, 20 U.

**Variants.** Stripe colour (turquoise, mint, coral); 3 or 4 floors.

### B03 `sign_tower_prow_hotel`
Beach, reuse 4, F2.

**Inspiration.** The Breakwater, 940 Ocean Drive. Anton Skislewicz, 1939. A projected central sign tower with a
ship-like prow and central vertical racing stripes, crowned by a neon-clad spire.
[MDPL inventory](https://www.ruskinarc.com/mdpl/Ocean-CollinsDistrict/4588-940%20Ocean%20Dr/view),
[MDPL archive](https://mdpl.org/?p=1807).

**What makes it itself.** A ship's bow of a sign tower pushing out of the middle of the facade and rising high above
the roof, striped top to bottom.

**Massing.** Two wings 28 wide x 40 deep x 36; between them a tower 14 wide pushing 6 out in a pointed prow (two
wedges) and rising to 64, with a two-step top and a spire 1.6 across to 80.

**Facade.** Three vertical stripes down the tower front, alternating royal blue #2E5AAC and deco_lemon (the colours from
photos); K4 eyebrows on the wings; the name in letters down the tower.

**Night.** Stripes neon (`neon_blue` and `neon_amber`), spire `neon_cyan`.

**Parts.** Wings 2, eyebrows 6, glass 6, tower 1, prow 2, stripes 3, steps 2, spire 1, sign 1, door 1, terrace 2:
27 plain, 22 U.

**Variants.** Stripe colours (blue and lemon, coral and white, mint and violet).

### B04 `deco_porthole_highrise`
Beach, reuse 3, F2.

**Inspiration.** The Tides, 1220 Ocean Drive. L. Murray Dixon, 1936. Eleven storeys and seven bays, a tripartite
symmetrical facade, a dramatically stepped ziggurat roofline, a projecting three-storey entry stacked with portholes
and rounded eyebrows, stainless steel and ocean-liner curves.
[MDPL inventory](https://www.ruskinarc.com/mdpl/Ocean-CollinsDistrict/4654-1220%20Ocean%20Dr/view),
[Time Out](https://www.timeout.com/miami/hotels/the-tides-south-beach).

**What makes it itself.** The tall stone hotel of the strip: vertical piers rising to a stepped ziggurat crown, and a
porthole entrance.

**Massing.** Body 70 x 40 x 132 (11 floors). The centre bay pushes out 3 and rises 3 steps of 8 above the roof; the
two bays beside it rise 1 step.

**Facade.** Ivory_stone; 6 piers between the 7 bays, full height, 1.5 proud (**U**); window bands per floor between
them (**U**); the entry block 30 x 6 x 36 with 3 portholes (Cylinder 4 across, glass_dark, chrome rim) under half-disc
eyebrows.

**Night.** The ziggurat steps outlined (`crown`); portholes `neon_amber`.

**Parts.** Body 1, piers 6, bands 11, crown 6, entry 1, portholes 3, eyebrows 3, sign 1, terrace 1: 33 plain, 18 U.

**As built (Studio pass, wave 3).** The centre bays are coloured spandrel bands of punched casement windows between
stone margins and piers (one glass run read as an office curtain wall). 68 to 78 parts of 80.

**Variants.** 11 to 13 floors; stone ivory or deco_peach.

### B05 `streamline_round_corner`
Beach, reuse 5, F2 corner.

**Inspiration.** The Cardozo, 1300 Ocean Drive. Henry Hohauser, 1939. A classic of streamline design: rounded building
corners, continuous eyebrows with rounded corners over wrap-around windows, strong horizontality, a tripartite facade,
a stepped parapet, porthole ornament at the third floor and keystone trim.
[MDPL inventory](https://www.ruskinarc.com/mdpl/Ocean-CollinsDistrict/4658-1300%20Ocean%20Dr/view),
[Bluffton survey](https://homepages.bluffton.edu/~SULLIVANM/florida/miami/cardoza/cardoza.html).

**What makes it itself.** Both front corners fully rounded, with three bands of eyebrow and glass wrapping round them
like a car fender.

**Massing.** Body 70 x 44 x 36; both front corners K5 cylinders 16 across. Stepped parapet over the centre to 40.

**Facade.** Per floor: a front eyebrow box plus two corner discs (K4, **U** per floor), glass ribbons wrapping the
cylinders (glass cylinders inset 0.6); two porthole ornaments at the third floor; a keystone base band #D9C4A0
Limestone.

**Colours.** white_stucco with deco_peach or deco_mint eyebrow edges.

**Night.** The top eyebrow's edge `neon_pink`; sign.

**Parts.** Body 3, eyebrows 9, glass 9, parapet 3, portholes 2, base 2, sign 1, door 1, terrace 2, corners 8: 40 plain,
18 U.

**As built (Studio pass, wave 3).** Crown 2 is a flat-topped bay with a name blade standing on each round drum, after
the inspiration's 1948 postcard; the half-round pediment is gone.

**Variants.** Pastel; one or both corners rounded.

### B06 `corner_spire_hotel`
Beach (Collins Avenue), reuse 3, F2 corner sites only.

**Inspiration.** Essex House, 1001 Collins Avenue. Henry Hohauser, 1938. On a corner lot: two facades (not identical),
a corner entrance, and a tall metal spire lit by neon where the street faces meet; nautical streamline with portholes
near the top and a tower like a ship's smokestack ("Nautical Moderne").
[Bluffton survey](https://homepages.bluffton.edu/~SULLIVANM/florida/miami/essex/essex.html),
[MDPL](https://mdpl.org/2020/04/20/1950s-ad-for-the-essex-house-hotel/).

**What makes it itself.** A landlocked ocean liner: a finned smokestack on the corner topped by a needle spire.

**Massing.** L-plan: wings 50 x 30 and 40 x 30, 36 tall, meeting at a round corner (Cylinder 14 across) that rises to
52 with three fins (the smokestack), then a spire in three thinning cylinders to 84.

**Facade.** Window bands per floor (**U**); a row of portholes along the top floor of each wing (5 each, **U**); a
curved canopy disc over the corner door.

**Colours.** white_stucco, deco_lemon band, trim #2E7FA0, spire chrome.

**Night.** The spire `neon_pink` with the name down its fin; portholes `neon_amber`.

**Parts.** Wings 2, bands 6, corner 1, fins 3, spire 3, portholes 10, canopy 1, sign 1, door 1, terrace 2: 30 plain,
16 U.

**As built (Studio pass, wave 3).** Crown 1's lettered panel faces the corner across the diagonal, with two return
fins in the trim colour. In the county it is a one-off at the hotel row's x = 56 corner (the row has few corners 48
studs wide), plus any copies the per-plot draw finds room for.

**Variants.** Which wing is longer (mirror); band colour.

### B07 `lighthouse_corner_hotel`
Beach, reuse 3, F1 corner.

**Inspiration.** Waldorf Towers, 860 Ocean Drive. Albert Anis, 1937. A rounded corner at the junction topped by a
lighthouse-like tower, a ship's crow's nest; "Tropical Deco" nautical motifs.
[MDPL inventory](https://www.ruskinarc.com/mdpl/Ocean-CollinsDistrict/4620-860%20Ocean%20Dr/view),
[Bluffton survey](https://homepages.bluffton.edu/~SULLIVANM/florida/miami/waldorf/waldorf.html).

**What makes it itself.** A little lighthouse with a glass lantern standing on the hotel's rounded corner.

**Massing.** Body 50 x 36 x 36, the street corner a K5 cylinder 16 across rising into a lighthouse: a cylinder 8 across
to 54, a glass lantern 7 across and 5 tall (transparent), a cap 9 across and a ball finial at 62.

**Facade.** K4 eyebrows per floor wrapping the round corner as discs; glass ribbons.

**Colours.** white_stucco with deco_aqua or deco_peach bands.

**Night.** The lantern `neon_amber`, a lighthouse lit over the drive.

**Parts.** Body 3, corner 1, eyebrows 6, glass 3, lighthouse 4, sign 1, door 1, terrace 2, parapet 3: 24 plain, 20 U.

**Variants.** Band colour; lantern colour amber or white.

### B08 `finned_tower_hotel`
Beach (Collins Avenue), reuse 2, F2.

**Inspiration.** The Delano, 1685 Collins Avenue. B. Robert Swartburg, built 1947, opened 1948. 14 storeys plus a
35-foot tower with wings or fins rising above the roofline; white; read as Art Deco or early Miami Modern.
[Wikipedia](https://en.wikipedia.org/wiki/Delano_Miami_Beach_Hotel),
[Bluffton survey](https://homepages.bluffton.edu/~SULLIVANM/florida/miami/delano/delano.html).

**What makes it itself.** An all-white slab with a slotted tower running up its face and breaking out above the roof
into a cross of stepped fins.

**Massing.** Slab 70 x 40 x 168. A tower 16 wide on the front, 4 proud, full height, rising 38 above the roof as a
shaft 10 x 10 with four fins in a cross (1.2 thick, 8 deep, 26 to 36 tall, stepped).

**Facade.** bright_white throughout; window bands glass_dark per floor (**U**); a vertical window slot up the tower.

**Night.** Fin edges `crown`; the tower slot `window`.

**Parts.** Slab 1, bands 14, tower 1, crown 5, slot 1, canopy 2, sign 1, terrace 1: 26 plain, 12 U.

**Variants.** All white, or the slot in deco_sky.

### B09 `domed_cupola_hotel`
Beach (Collins Avenue), reuse 2, F4.

**Inspiration.** The National Hotel, 1677 Collins Avenue. Roy France, 1939-40. A symmetrical tripartite facade, a
domed tower on an elevated base with openings like a church bell tower and an onion-shaped dome on a cupola painted
silver; wings run back toward the ocean.
[Wikipedia](https://en.wikipedia.org/wiki/National_Hotel_(Miami_Beach,_Florida)),
[Bluffton survey](https://homepages.bluffton.edu/~SULLIVANM/florida/miami/national/national.html).

**What makes it itself.** A slim hotel tower with a belfry and a silver onion dome, its wings reaching back to the
water.

**Massing.** Tower 30 x 30 x 156 (13 floors) at the front; two wings 30 wide x 50 deep x 96 running back (a U-plan
round a pool court). Belfry storey 24 tall with two posts per side; onion dome: a Ball 22 across, a neck (small
cylinder), a spike, top at 196.

**Facade.** Cream #F1EADB Plaster; tower window strips vertical (**U**), wing bands horizontal (**U**).

**Night.** A lamp lights the dome (K8 SpotLight); belfry openings `neon_amber`.

**Parts.** Tower 1, wings 2, strips 8, bands 8, belfry 8, dome 3, sign 1, pool 2, terrace 2: 35 plain, 21 U.

**Variants.** Dome silver Foil or gold #C9A74A Foil.

### B10 `curved_resort_slab`
Beach (Collins Avenue), reuse 1, F4 to F5.

**Inspiration.** Fontainebleau, 4441 Collins Avenue. Morris Lapidus, 1954 (Miami Modern). Lapidus bent the blocky
corridor hotel into a sleek curved icon (the quarter-circle tower is from photos); his "Staircase to Nowhere" (the
floating staircase), walls punched with "cheese holes", the vast pool; later towers of 36 and 18 storeys.
[Wikipedia](https://en.wikipedia.org/wiki/Fontainebleau_Miami_Beach),
[Morris Lapidus](https://en.wikipedia.org/wiki/Morris_Lapidus).

**What makes it itself.** A long white hotel bent in a quarter circle round its pool, and a cheese-holed wall at its
foot.

**Massing.** A curved slab 168 tall, 30 deep, bent through 90 degrees at a centreline radius of 120 (one CSG ring
segment, or 10 facets), its concave side toward the lake. A low lobby wing 80 x 30 x 20 with a wavy canopy; a pool
60 x 30 in the curve with a row of cabanas.

**Facade.** Concave side: balcony bands every floor (**U**); convex side: vertical window stripes (**U**). A wall 40 x
16 with 6 round holes (CSG). A floating staircase: 6 treads hanging free in the lobby glass.

**Colours.** bright_white, glass #4C7684, pool #39B6D2, cabanas deco_aqua and white.

**Night.** The invented name across the roof in neon script (`neon_cyan`), the pool glowing.

**Parts.** Slab 1 (CSG) or 10, bands 14, stripes 8, lobby 3, canopy 2, cheese wall 1, stairs 6, pool 2, cabanas 8, sign
1: 55 plain, 35 U.

**Variants.** An optional straight second tower (T06 at 216, bright_white) behind.

### B11 `mimo_truss_motel`
Beach (Biscayne Boulevard MiMo), reuse 4, F2.

**Inspiration.** The Vagabond Motel, 7301 Biscayne Boulevard. Robert Swartburg, 1953 (MiMo; National Register 2014).
An open-air plan, jalousie windows, geometric designs, overhanging roof lines, stone facing and marine-life
sculpture; brightly coloured pylons of angled trusses holding the historic sign; an entrance awning and porte-cochere;
stairs rising to frame a central flat arch; rooms reached by catwalks on light V-shaped steel members.
[Wikipedia](https://en.wikipedia.org/wiki/Vagabond_Motel),
[City of Miami](https://www.historicpreservationmiami.com/vagabond.html).

**What makes it itself.** A two-storey motel round a pool, its upper catwalk on V-struts, and by the road a sign held
up by two leaning, brightly painted lattice pylons.

**Massing.** U-plan: two wings 80 x 24 x 24 and a back wing, round a pool court open to the road. Flat roofs with a
4-stud overhang.

**Facade.** Upper catwalk slab 3 deep along the court face on V-struts every 10 studs (pairs of thin angled bars, **U**),
a thin rail; a stair rising through a flat-arched portal (3 parts); stone panels #B9A88E Sandstone on the end walls;
glass bands with jalousie louvres (**U**); doors in alternating pastels.

**Sign.** Two lattice pylons 26 tall, leaning 12 degrees toward each other (2 rails and 3 cross bars each), in
deco_coral and deco_aqua, holding a board with an invented name; a boomerang porte-cochere (two angled slabs).

**Night.** The sign `neon_pink` and `neon_cyan`; the pool glows.

**Parts.** Wings 3, roofs 3, catwalk 2, struts 16, rail 2, glass 4, portal 3, stair 2, stone 2, pylons 10, sign 1,
canopy 2: 50 plain, 32 U.

**Variants.** Pylon colours; wings L or U.

### B12 `arcade_village_street`
Beach, reuse 3, F2.

**Inspiration.** Española Way, between 14th and 15th Streets, Miami Beach. Robert A. Taylor, 1925 (begun 1922 as
Whitman's Spanish Colony), modelled on Spanish and French coastal towns. A Mediterranean Revival pedestrian street of
peach stucco buildings with striped shades, arcaded porticos, tile roofs, wrought-iron balconies and courtyards.
[MDPL](https://mdpl.org/blog/2023/05/espanola-way-miami-beachs-historic-mediterranean-plaza/),
[City of Miami Beach](https://www.miamibeachfl.gov/architecture/mediterranean-revival/).

**What makes it itself.** A peach-coloured row with a ground-floor arcade, striped awnings and little iron balconies
under red tile.

**Massing.** A row 90 x 40 x 30 (2 to 3 floors) with a corner belvedere tower 12 x 12 to 38.

**Facade.** Ground arcade: 6 square piers, 5 arches (half-disc tops sunk into the lintel); upper floors: 4 small
balconies (slab plus iron rail); 5 striped awnings over the shopfronts, each 4 thin wedges in two alternating colours
(**U**); K7 tile roofs (4 wedges) and a pyramid tile cap on the tower.

**Colours.** Walls deco_peach (variants rose #E8A9A0, buttercream #F2DFA6), trim #F5ECD9, terracotta, iron; awnings
coral and white or teal and white.

**Night.** A string of cafe lights along the arcade (one thin `neon_amber` line) and lit shopfronts (`window`).

**Parts.** Body 3, arcade 11, balconies 8, awnings 20, roofs 6, tower 2, lights 1: 50 plain, 30 U.

**Variants.** Wall colour; with or without the tower.

---

## 7. Residential

Houses stand on F1 lots in Riverside (and fill-in elsewhere), each with a palm or two from the scenery step. The
claimable houses on the 26 HousePlots are built by Services/HouseService from Config/Houses (outside
Workspace.Map.Generated). Since wave 3 they come in four hand-built styles, dealt out in turn by plot order so
next-door houses always differ, each keeping the plot frame, the 16-wide garage bay, the garage door's swing and the
home charger: `tile_tower_villa` (after R01), `tropical_modern` (after R06), `butterfly_modern` (after the 1950s
seaside modern houses of the beach islands, with their butterfly roofs) and `coral_rock_cottage` (after R02). Their
inspirations stay here; no real name is in game code.

### R01 `mediterranean_villa`
Residential (Coral Gables), reuse 22, F1.

**Inspiration.** Coral Gables, George Merrick's 1920s planned Mediterranean town, and Miami Beach's Mediterranean
Revival houses: red or orange terracotta barrel-tile roofs, white or light stucco, round or pointed arches, decorative
ceramic tile, wrought-iron railings, gates and balconies, courtyards and palms.
[City of Miami Beach](https://www.miamibeachfl.gov/architecture/mediterranean-revival/),
[Coral Gables](https://en.wikipedia.org/wiki/Coral_Gables,_Florida).

**What makes it itself.** Light stucco under low red barrel-tile roofs, an arched loggia and a square stair tower.

**Massing.** L-plan: a two-storey block 26 x 18 x 22 and a one-storey wing 16 x 14 x 11; a stair tower 7 x 7 x 28
with a pyramid tile cap; a courtyard wall with a gate.

**Facade.** A three-arch loggia on the main block (4 piers, a lintel, 3 half-disc arches); a wrought-iron balcony over
it; green shutters #3E6B54 (2); a chimney.

**Colours.** Walls white #F4EFE4, cream #EFE0C2, pale pink #EFCFC4 or ochre #E3C188 (Plaster); terracotta roofs; iron.

**Night.** Two windows glow (`window`), a lantern by the door.

**Parts.** Blocks 2, roofs 4, tower 2, loggia 8, balcony 2, shutters 2, chimney 1, wall 2, lights 1: 24 plain, 20 U.

**Variants.** Mirror; wall colour; tower on the left or right; wing behind or beside.

### R02 `coral_rock_cottage`
Residential (Coral Gables), reuse 14, F1.

**Inspiration.** Coral Gables House (the Merrick House), Coral Way. Designed by Althea Merrick, about 1906-10. Rough
oolitic limestone ("coral rock") walls 18 inches thick, one and a half storeys, a multi-gabled roof of coral-coloured
clay tiles, a porch on 22 Doric columns wrapping three sides, a Palladian window in the main gable. Coral Gables has
27 such coral-rock buildings (for example H. George Fink's 1925 houses on Granada Boulevard).
[Wikipedia](https://en.wikipedia.org/wiki/Coral_Gables_House),
[Coral Gables Magazine](https://coralgablesmagazine.com/100-years-of-solicitude/).

**What makes it itself.** A low stone cottage of rough tan coral rock under coral-red gables, with a white-columned
porch.

**Massing.** Body 28 x 20 x 11 plus gables to 18: a main gable and a cross gable (4 wedges); a wraparound porch on
three sides (a lean-to roof of 3 wedges on 8 columns).

**Facade.** Walls coral_rock (Limestone, or Sandstone #D1BE97 as a variant); columns white; an arched Palladian
window in the main gable (glass and a half-disc); a chimney.

**Colours.** coral_rock, roof #C9794E ClayRoofTiles, white trim.

**Parts.** Body 1, roofs 4, porch roof 3, columns 8, floor 1, window 2, chimney 1, door 1, lamp 1: 22 plain, 20 U.

**Variants.** Mirror; porch on 2 or 3 sides.

### R03 `veranda_raised_house`
Residential (Coconut Grove), reuse 14, F1.

**Inspiration.** The Barnacle, Coconut Grove. Ralph Munroe, 1891. A one-storey bungalow raised on wood pilings, with an
octagonal central room, a high-pitched roof thought to look like a barnacle, and porches; in 1908 it was lifted and a
new ground storey built beneath it.
[Wikipedia](https://en.wikipedia.org/wiki/The_Barnacle_Historic_State_Park),
[Florida State Parks](https://www.floridastateparks.org/park-history/The-Barnacle).

**What makes it itself.** An Old Florida wooden house: a deep veranda all round the upper floor under a steep, dark,
pointed roof.

**Massing.** Ground storey 26 x 22 x 11; upper storey 24 x 20 x 10 inside a veranda deck 32 x 28 on 12 posts with a
rail; a steep hip roof (wedges and corner wedges) to 30; a small octagonal vent lantern at the peak (two boxes turned 45
degrees).

**Colours.** Siding #EEE8DC WoodPlanks; roof #5D5F5B RoofShingles; shutters #3F6A5A; posts white.

**Night.** Upper windows `window`.

**Parts.** Storeys 2, deck 1, posts 12, rail 4, roof 4, vent 2, shutters 1: 26 plain, 16 U.

**Variants.** Siding white, pale yellow #F2E6B8 or sea green #CFE3D6.

### R04 `pink_layered_house`
Residential (Miami Shores), reuse 6, F1.

**Inspiration.** The Spear House, "the Pink House", Miami Shores. Arquitectonica (Laurinda Spear with Bernardo
Fort-Brescia; begun as a Spear and Rem Koolhaas competition entry), designed 1976-79. Layered concrete and stucco walls
in five pinks, from near red to pale conch shell, revealed one after another toward the bay; a walled street court
with a 60-foot lap pool seen through a porthole; glass block and inset balconies on the bay side.
[The Modern House](https://www.themodernhouse.com/journal/house-of-the-week-pink-house-in-miami-by-arquitectonica/),
[Alastair Gordon](https://alastairgordonwalltowall.com/2018/04/12/on-pinkness-the-pink-house-and-its-secret-spatial-heart/).

**What makes it itself.** Five flat walls one behind another, each a paler pink and taller than the last, with a round
porthole in the front one.

**Massing.** Five wall planes 1.2 thick across the lot, front to back 12, 16, 20, 22 and 24 tall, each a bit longer;
the house volume behind the last; a lap pool 4 x 30 beside them.

**Facade.** Colours front to back #C6455B, #DB6B7D, #E895A0, #F1B9BE, #F7DCD8 (Plaster). The porthole: a disc of
glass_dark with a white ring, or a CSG hole. The back: frosted glass block wall (#DDE8EC Glass, transparency 0.3) and
an inset balcony.

**Parts.** Walls 5, porthole 2, pool 2, back 3, roof 1, balcony 2, door 1: 16 plain, 16 U.

**Variants.** Pinks, or the same idea in sea greens (#2E8C7E to #CFEAE2).

### R05 `red_ziggurat_lowrise`
Residential (Brickell low-rise), reuse 3, F2 deep lot.

**Inspiration.** The Babylon apartments, Brickell. Arquitectonica's first major project, 1982 (a Progressive
Architecture citation in 1978), demolished 2019. Bright red and stepped like a ziggurat, about six storeys, its form
shaped by a long, narrow lot that it runs back through.
[Docomomo US](https://docomomo-us.org/register/babylon-apartments),
[The Architect's Newspaper](https://www.archpaper.com/2018/01/arquitectonicas-babylon-demolition/).

**What makes it itself.** A bright red stepped pyramid of apartments, in section a staircase up and down.

**Massing.** Five red blocks along the lot, 36 wide: 24, 48, 72, 48 and 24 tall (front to back), each 10 long.

**Facade.** #C8352C Plaster; a dark glass strip on each riser; thin white rails on the terraces.

**Night.** Riser glass `window`: stacked bands of light.

**Parts.** Blocks 5, glass 5, rails 4, door 1, roof 1: 16 plain, 16 U.

**Variants.** Red, or deep blue #2D4E8C (still one strong colour).

### R06 `tropical_modern_villa`
Residential (Miami Beach islands), reuse 20, F1.

**Inspiration.** The "Tropical Modern" houses of Choeff Levy Fischman (for example their Palm Island residence):
white stucco with ipe wood, floor-to-ceiling glass and infinity-edge pools, indoors and outdoors blurred, wide spans on
post-tensioned slabs.
[Home World Design](https://homeworlddesign.com/palm-island-modern-residence-choeff-levy-fischman),
[Dexigner](https://www.dexigner.com/news/33861).

**What makes it itself.** Two crisp white boxes, the upper one sliding out over a pool, under a razor-thin roof, with a
wood screen.

**Massing.** Ground box 30 x 20 x 11, mostly glass; upper box 34 x 18 x 11 shifted 6 toward the pool; a roof slab 0.8
thick overhanging 3 all round; a pool 8 x 0.6 x 22 with a paved deck.

**Facade.** White #F7F7F5 Plaster; an ipe screen of 6 vertical slats #8B5A3C WoodPlanks (**U**) on the upper box;
glass #6E8F99; pool #3BBAD8; deck #E7E1D4 Limestone.

**Night.** The ground glass glows (`window`): the house lit like a lantern.

**Parts.** Boxes 2, glass 2, roof 1, slats 6, pool 2, deck 1, door 1, garage door 1, wall 2: 18 plain, 13 U.

**Variants.** Mirror; slats on the upper or lower box; one or two storeys.

### R07 `mimo_garden_apartment`
Residential (Normandy Isles MiMo), reuse 12, F2.

**Inspiration.** The Shore Apartments, Normandy Isles, Miami Beach. B. Robert Swartburg, 1948-49 (National Register
2008). Three storeys of early MiMo with streamline elements: a keystone-shaped footprint, an open breezeway across a
third of the front showing the patio, round streamline windows and terraces. MiMo's wider vocabulary: breeze blocks,
rounded corners, flat roofs, glass, open-air walkways, symmetrical stairs, boomerang and trapezoid shapes.
[Shore Apartments](https://en.wikipedia.org/wiki/Shore_Apartments),
[Miami Modern architecture](https://en.wikipedia.org/wiki/Miami_Modern_architecture).

**What makes it itself.** A pastel three-storey block with a see-through breezeway, a row of round windows and a
breeze-block stair screen.

**Massing.** Body 60 x 30 x 36, its front edge angled slightly (the keystone plan); the left third of the ground floor
open as a breezeway (the upper floors bridge it); a flat roof slab with a rounded corner (box and disc) overhanging 3.

**Facade.** Three round windows in a row (discs); terraces (3 slabs and rails); a K6 screen on the stair; an outside
stair (2 wedges); the address in metal letters.

**Colours.** Pastels deco_mint, salmon #F2B49B or deco_lemon, with white trim and screen.

**Parts.** Body 3, roof 2, windows 3, terraces 6, screen 8, stair 2, sign 1, door 2, lamp 1: 28 plain, 22 U.

**Variants.** Pastel; breezeway left or right.

### R08 `mosaic_townhouse_row`
Residential (Miami Beach), reuse 8, F2.

**Inspiration.** Aqua, Allison Island, Miami Beach. Master plan by Duany Plater-Zyberk, buildings by 8 to 10 firms
(among them Alison Spear, Walter Chatham and Alex Gorlin), developer Craig Robins (Dacra), 2000s. 46 four-storey
townhouses with crisp white facades and "exuberant hits of colour", no elevation repeated, staggered heights; Spear's
mid-rise is clad in blue-green mosaic.
[DPZ](https://www.dpz.com/projects/aqua),
[Miami New Times](https://www.miaminewtimes.com/arts-culture/futuristic-fusion-6340316/).

**What makes it itself.** A row of white townhouses of different heights, each with one bold colour panel, and a
mosaic-clad end.

**Massing.** Five units 14 wide x 32 deep, 36 to 50 tall (3 to 4 floors), staggered; roof terraces with thin canopies.

**Facade.** White #F6F6F3 Plaster; per unit one colour hit (a framed window box or panel) in yellow #F4C542, cobalt
#2D5FB0, tangerine #F08A3C, lime #A9C94A or magenta #C8417E; the end unit (variant) in mosaic #3FA79C CeramicTiles.

**Parts.** Units 5 x 5 = 25, mosaic 2, base 1, plants 2: 30 plain, 25 U.

**Variants.** Order of heights and colours; mosaic end on or off.

---

## 8. Wynwood and industrial

### W01 `mural_warehouse`
Wynwood, reuse 25, F1 to F2.

**Inspiration.** Wynwood Walls, Wynwood. Created by Tony Goldman, opened 2009: six warehouses whose facades became
canvases for more than 30 large works by artists from around the world, in a district of former manufacturing and
abandoned warehouses. (The low concrete-block warehouse form, flat roof, parapet and roll-up doors, is from photos.)
[ULI case study](https://casestudies.uli.org/?p=30587),
[NPR](https://www.npr.org/2012/12/03/166099114/street-art-brings-life-to-a-miami-neighborhood).

**What makes it itself.** A plain block warehouse whose whole street wall is one giant painting.

**Massing.** 50 to 90 x 40 x 18 to 28; flat roof with a parapet cap; two roll-up doors (alu), a loading dock slab;
roof units. Variant roofs: sawtooth (4 wedges with glass strips) or a barrel.

**Mural.** Original supergraphics, never a copy of a real mural: 4 to 8 thin flat panels (0.2 proud) composed from a
seeded set of shapes (stripes, discs, triangles from wedges, a giant lightning bolt for Voltage County), in hot pink
#FF4F9A, electric blue #2D6BFF, sun yellow #FFD23F, mint #41D3A6, orange #FF7A2F, violet #7B4DFF, black #1B1B1F and
white. The other walls concrete_raw or one flat colour.

**Night.** One neon outline shape on the mural (`neon_pink` or `neon_cyan`).

**Parts.** Body 1, parapet 1, doors 2, dock 1, roof units 2, mural 6, neon 1, door 1, lamp 1, sign 1, bins 2: 20 plain,
18 U (sawtooth variant +8).

**Variants.** Size; roof type; the mural composition and palette (seeded); a rooftop bar deck on some.

### W02 `faceted_gallery`
Design District, reuse 3, F2.

**Inspiration.** ICA Miami (Institute of Contemporary Art), Design District. Aranguren + Gallegos, 2017. The street
(south) facade is clad in geometric aluminium triangles, some recessed so cove lighting (colour-changing) can wash
them at night, alternating with clear panels; the entrance is recessed under an overhang; three double-height gallery
floors, about 37,000 sq ft.
[Dezeen](https://www.dezeen.com/2017/12/05/institute-contemporary-art-ica-miami-opens-permanent-home-metal-faced-building-aranguren-gallegos-design-district/),
[Arquitectura Viva](https://arquitecturaviva.com/works/ica-museum-miami).

**What makes it itself.** A box whose front is a quilt of tilted metal triangles, some glowing.

**Massing.** 90 x 50 x 54 (three floors of 18); the ground floor recessed 6 under the facade as the entrance.

**Facade.** The street face: 6 columns x 3 rows of squares, each split into two thin triangular wedges, tilted 0.5 in or
out alternately (36 parts, **U**); 6 are glass_clear, 6 are light panels; aluminium #BFC4C8 and #A9AEB2 Metal. Other
faces plain concrete_raw.

**Night.** The 6 light panels glow (`neon_violet`, or a slow colour change as an optional client effect).

**Parts.** Body 2, triangles 36, entrance 2, roof 2: 42 plain, 14 U (the 6 glass and 6 light panels stay separate).

**Variants.** Panel metal silver or champagne; light colour.

### W03 `collage_parking_garage`
Design District, reuse 2, F4.

**Inspiration.** Museum Garage, Design District. Curated by Terence Riley, completed 2018: a seven-storey garage for
800 cars with shops below, its facades by five teams who worked without seeing each other's (after the game "exquisite
corpse"): WORKac's Ant Farm (maze-like circulation behind perforated metal), J. MAYER H.'s XOX (big striped puzzle
pieces), Nicolas Buffe's Serious Play (2-D and 3-D cut metal and plastic with four 23-ft caryatids), Clavel
Arquitectos' Urban Jam (45 gold and silver car bodies in a vertical traffic jam) and K/R's Barricades (orange-and-white
traffic barriers turned upright).
[Architizer](https://architizer.com/projects/miami-museum-garage/),
[Arch2O](https://www.arch2o.com/?p=229037).

**What makes it itself.** A parking garage wearing five different outfits side by side, one of them a wall of cars
stuck climbing it.

**Massing.** Decks every 10 studs, 7 levels, 150 x 70 x 72; columns; an internal ramp.

**Facade.** The street face in 5 panels of 30, each its own original system: (1) vertical boards in orange #F26A21 and
white like barriers (10 parts); (2) 6 simple car-shaped blocks (2 boxes each, original shapes) in gold #C9A74A and
silver #C7CCD1 Foil, tilted as if driving up the wall; (3) 4 interlocking puzzle panels in cyan, magenta, yellow and
black stripes; (4) a perforated metal screen #8F969C DiamondPlate with a zig-zag stair showing through; (5) two tall
abstract figure columns. Other faces K2.

**Night.** The barrier boards' edges `neon_amber`; the car blocks' fronts small headlight strips (optional).

**Parts.** Decks 7, columns 8, ramp 2, collage 34, roof 2, shops 5: 58 plain, 30 U.

**Variants.** Panel order; which panels appear (pick 4 of 5).

### W04 `sculpted_car_park`
Lincoln Road style, Wynwood or the beach, reuse 2, F2 to F4.

**Inspiration.** 1111 Lincoln Road, Miami Beach. Herzog & de Meuron, 2008-10. A parking garage of about 300 spaces as a
civic place: a stack of concertina-folded concrete slabs braced by zig-zagging columns, almost no walls, ceiling
heights from 7 to 34 ft; shops at street level and on the fifth floor, a penthouse and event space on top. Jacques
Herzog: "all muscle without cloth".
[Wikipedia](https://en.wikipedia.org/wiki/1111_Lincoln_Road),
[ICON](https://www.iconeye.com/architecture/1111-lincoln-road-by-herzog-de-meuron).

**What makes it itself.** Bare concrete floors floating at uneven heights on thin blade columns set at odd angles.

**Massing.** Six slabs 100 x 60 x 1.5 with gaps of 8, 10, 16, 8, 24 and 10 (top at 88), each slab two or three boxes
at slight angles (the fold); blade columns 1.2 x 12 x gap, three or four per gap, turned 15 degrees one way then the
other; a glass penthouse on top; a ramp; glass shopfronts at the ground.

**Colours.** concrete_raw; glass_clear.

**Night.** A light strip under every slab's front edge (`led_edge`): floors floating in light.

**Parts.** Slabs 12, columns 20, shops 2, penthouse 2, ramp 2, lights 6: 44 plain, 25 U.

**Variants.** Gap sequence; penthouse on or off.

### W05 `port_crane_yard`
The Plant (freight), reuse 1, F5.

**Inspiration.** PortMiami's Super Post-Panamax container cranes. Four fully electric cranes delivered in October 2013
(bringing the port to 13 cranes): 223-ft outreach, 100-ton lift, for ships 23 containers wide, about 25 storeys tall.
[PortMiami](https://www.miamidade.gov/portmiami/post-panamax-cranes.page),
[Maritime Executive](https://www.maritime-executive.com/corporate/Four-New-Super-PostPanamax-Cranes-Heading-to-PortMiami-2013-08-07).

**What makes it itself.** Giant gantry cranes standing over stacks of coloured containers: the working port silhouette.

**Massing.** Two or three cranes at 130 tall (compressed): 4 legs, 2 sill beams, a portal beam, a boom 100 long
(raised or down), a back-reach, an apex frame (2), a machinery house and a cab. Containers 44 x 9 x 9.5 (a 40-ft box)
in stacks of 1 to 4.

**Colours.** Cranes white #EDEDE9 with blue #2E5EA8 bands (an original scheme); containers CorrodedMetal or Metal in
rust #9C3B2E, blue #2F5D8C, green #3E7D4F, orange #D9772B, grey #8A9096 and yellow #D9B53A.

**Night.** Red aviation lights on the apexes (`beacon`), floodlights under the booms (`floodlight`).

**Parts.** Cranes 3 x 16 = 48, containers 30, lights 2: 80 plain, 80 U.

**Placement.** By the freight depot or the freight warehouse, clear of every TrailerSpawn, TowDrop and the depot yards.

---

## 9. Civic landmarks and scenery

### C01 `cupola_bell_tower`
Downtown, reuse 1, F3.

**Inspiration.** Freedom Tower, Biscayne Boulevard, Downtown. Schultze & Weaver (with George A. Fuller), 1925, built for the
Miami News; later the Cuban refugee centre. Spanish Renaissance Revival after the Giralda in Seville: a four-storey
base, a twelve-storey tower and an octagonal cupola with a dome (re-clad in aged copper), a decorative beacon and a
galleon weather vane, 255 ft; stucco and cast-concrete ornament; a flat roof; a plain three-storey press wing.
[Wikipedia](https://en.wikipedia.org/wiki/Freedom_Tower_(Miami)),
[National Register nomination](https://npgallery.nps.gov/pdfhost/docs/NRHP/Text/79000665.pdf).

**What makes it itself.** A Spanish bell tower among the glass: a pale shaft ending in an open belvedere, an octagonal
cupola and a green copper dome.

**Massing.** Base 80 x 60 x 48; press wing 30 x 50 x 36; tower 36 x 36 to 180; belvedere storey 24 tall (three
openings a side, posts and lintels); cupola an octagon (two 28 x 28 boxes turned 45 degrees) 20 tall; dome a Ball 22
across sunk into it; lantern and vane to 225.

**Facade.** Cream #EDE3CC Plaster; ornament #E2D3B5 Limestone: corner piers, 4 belt courses, recessed arched window
panels on the upper floors (**U**); copper #5E8F7B Metal.

**Night.** A lamp lights the cupola (K8); the lantern glows warm (`neon_amber`).

**Parts.** Base 6, wing 3, tower 1, piers 4, belts 4, panels 8, belvedere 12, cupola 2, dome 1, lantern 2, vane 1, lamp
1, plaza 3: 48 plain, 40 U.

### C02 `stepped_crown_courthouse`
Downtown, reuse 1, F3 to F4. Beside the Courthouse rideshare hotspot (`cb_hotspot_courthouse`).

**Inspiration.** Miami-Dade County Courthouse, Downtown. A. Ten Eyck Brown with August Geiger, 1925-28,
once the tallest building south of Baltimore. 28 floors, 361 ft: a broad base faced in Stone Mountain granite, the
floors above sheathed in terra cotta tinted to match, a central tower rising through setbacks to its signature
stepped-pyramid roof. (A colonnade high on the tower is from photos.)
[Wikipedia](https://en.wikipedia.org/wiki/Miami-Dade_County_Courthouse),
[National Register text](https://npgallery.nps.gov/NRHP/GetAsset/NRHP/88002983_text).

**What makes it itself.** A grey stone tower ending in a stepped pyramid, the old city's crown.

**Massing.** Base 120 x 90 x 72; shaft 60 x 60 to 230, set back to 52 x 52 to 260; a colonnade storey with 5 Cylinder
columns per side to 280; a stepped pyramid of 5 boxes, each 8 smaller and 6 tall, and a finial to 290.

**Facade.** Base granite_pale; above, #C8C2B6 Limestone; vertical window strips glass_dark (**U**).

**Night.** The pyramid floodlit warm (K8 SpotLight).

**Parts.** Base 4, shaft 2, strips 12, colonnade 24, pyramid 6, finial 1, lamp 1: 50 plain, 18 U.

### C03 `harbor_market_pavilions`
Bayfront (Lakefront north shore), reuse 1, F5 on the water.

**Inspiration.** Bayside Marketplace, Biscayne Bay. Benjamin Thompson & Associates with Spillis Candela & Partners,
opened 1987 (developer the Rouse Company): an open-air centre of two two-storey pavilions modelled on historical market
sheds, beside the city marina; renovated 2016-18 by Zyscovich with brighter paint and LED-lit roofs; the Skyviews
observation wheel, about 200 ft with 42 gondolas, opened 2020.
[Wikipedia](https://en.wikipedia.org/wiki/Bayside_Marketplace),
[WSVN](https://wsvn.com/entertainment/skyviews-miami-ferris-wheel-opens-at-bayside-marketplace/).

**What makes it itself.** Two long open market halls with bright metal roofs on the waterfront, a boardwalk and a
giant observation wheel.

**Massing.** Two pavilions 140 x 50 x 30 either side of a plaza, open to the water: a ground arcade (14 posts, **U**),
an upper gallery with balconies, gabled metal roofs in 3 sections with a raised clerestory (2 wedges each). A
boardwalk along the shore (WoodPlanks #9C7A55) with bollards. The wheel: 160 tall (compressed), rim in 24 segments, 12
spokes, two A-frame legs, 16 gondolas.

**Colours.** Walls bright_white; roofs teal #2E9C9A and coral #F06E5A Metal; gondolas in pastels.

**Night.** Roof edges `led_edge`; the wheel rim `neon_pink`. A slow wheel turn is an optional client-side tween (no
loop), not gameplay.

**Parts.** Pavilions 2 x 40 = 80, plaza 6, boardwalk 8, wheel 56: 150 plain, 100 U.

### C04 `bayfront_arena`
Bayfront (Lakefront north shore), reuse 1, F5.

**Inspiration.** Kaseya Center (formerly American Airlines Arena), Biscayne Boulevard, on the bay. Arquitectonica with
360 Architecture, opened December 1999. About 19,600 seats; glass facades show the staircases and concourses from
outside; outdoor terraces on each concourse; exterior lighting and graphics were part of the design; a giant aircraft
was painted on the roof for planes landing at the airport.
[Wikipedia](https://en.wikipedia.org/wiki/Kaseya_Center),
[Arquitectonica](https://arquitectonica.com/architecture/?p=398).

**What makes it itself.** A big white oval with glowing glass stair halls at its corners and a giant picture on its
roof, made to be seen from above (here from the towers).

**Massing.** An oval bowl 220 x 170 x 60 from 16 boxes turned round the oval; a low roof of 3 shrinking oval slabs and
a top disc to 76; 4 glass stair halls 30 x 20 x 50 at the corners with 4 diagonal stair slabs inside each; terraces
toward the water.

**Facade.** White bands bright_white (**U**); glass_clear stair halls; roof #D9DCDE Metal with an original graphic in
thin parts: a giant lightning bolt #FFC93C.

**Night.** The stair halls glow warm (`window`); the bolt `neon_amber`; a ring of `led_edge` round the bowl's top.

**Parts.** Bowl 16, bands 8, roof 4, stair halls 24, bolt 3, plaza 10, terraces 10: 75 plain, 55 U.

### C05 `domed_sanctuary`
Beach, reuse 1, F2.

**Inspiration.** Temple Emanu-El, 1701 Washington Avenue, Miami Beach. Charles Greco (one source adds Albert Anis),
1946-48. Byzantine and Moorish forms made smooth and sleek in the Art Deco manner, under a large dome described as
copper (it has also read as silver).
[Synagogues of the South](https://synagoguesofthesouth.charleston.edu/?p=622),
[Clio](https://www.theclio.com/entry/24320).

**What makes it itself.** A smooth pale block crowned by one big round dome, the beach district's domed landmark.

**Massing.** Base 70 x 60 x 36; a front portal 24 wide, 30 tall with a half-disc arch, flanked by two square towers 10
x 10 x 44; a drum (Cylinder 40 across, 16 tall) on the base; a dome (Ball 44 across) sunk into it, top at 78; a small
lantern.

**Colours.** #EFE7D6 Plaster; trim #D9CBB0; dome copper patina #6F9E8E Metal or silver #C9CDD0 Foil.

**Night.** A lamp washes the dome (K8).

**Parts.** Base 2, portal 3, towers 4, drum 1, dome 1, lantern 2, steps 2, lamp 1, plaza 4, windows 5: 25 plain, 25 U.

### C06 `folded_roof_lake_stadium`
Beach scenery, on the lake shore facing the water, reuse 1.

**Inspiration.** Miami Marine Stadium, Virginia Key. Hilario Candela, in his twenties, with engineer Jack Meyer, 1963. A
326-ft cast-concrete roof of eight hyperbolic-paraboloid folded plates, cantilevered 65 ft over the stands and in
places three inches thick, the longest cantilevered concrete span in the world when built; a third of the structure
stands on piers in the water.
[Wikipedia](https://en.wikipedia.org/wiki/Miami_Marine_Stadium),
[Docomomo US](https://docomomo-us.org/register/miami-marine-stadium).

**What makes it itself.** A long white roof of folded concrete wings floating out over a grandstand by the water.

**Massing.** Stands 210 x 50 (compressed from 99 m), 6 raked tiers, the front on 6 piers in the water. Roof: 8 folded
plates, each two shallow triangular wedges meeting in a V, cantilevered 40 over the stands from a back row of 9
slanted columns; roof top at 52.

**Colours.** concrete #E6E4DE; risers white.

**Night.** The roof's front edge `led_edge`.

**Parts.** Stands 8, roof 16, columns 9, piers 6, stairs 4, rails 2: 45 plain, 45 U.

**Placement.** Needs the water in front: the lake shore, so either a park exception or a site on the lake's edge outside
Lakefront Park. It makes a backdrop for the Lakeview Overlook meet spot.

### C07 `lighthouse_water_tower`
Residential scenery, reuse 1. Replaces the look of feature `riverside_water_tower` (footprint 30 x 30, height 112).

**Inspiration.** Alhambra Water Tower, Coral Gables. Designed by Denman Fink (one source adds H. George Fink), about
1923-24, to look like a lighthouse while hiding a steel water tank (concrete over a wood frame round the tank); in
service until 1931, restored in 1993 from 1924 photographs and again in 2011-12.
[Florida historical marker](https://markers.flheritage.com/home/details/497),
[Patch](https://patch.com/florida/coralgables-coconutgrove/alhambra-water-tower-preservation).

**What makes it itself.** A Mediterranean lighthouse in a suburb: an octagonal tapering shaft with a gallery and a
domed lantern.

**Massing.** Three octagonal stages (two square boxes turned 45 degrees each) 24, 20 and 16 across, with a string course
at each step; a gallery slab wider than the shaft with a thin rail; a lantern of 8 thin posts round a glass core; a
domed cap and a finial at 112.

**Colours.** Cream stucco #EFE3C8 Plaster, trim #DCCBA8; cap and lantern details from photos (check a reference).

**Night.** The lantern glows warm (`neon_amber`).

**Parts.** Stages 6, string courses 3, gallery 2, posts 8, cap 2, finial 1: 22 plain, 22 U.

### C08 `lifeguard_stand`
Beach scenery, reuse 12, about 14 x 18 each.

**Inspiration.** The Miami Beach lifeguard towers. William Lane Architect designed five towers in 1995 after Hurricane
Andrew, then six prototypes for 36 new towers (2015-19): huts lifted about 2 m off the sand on a skeleton base, a
protruding roof, playful forms (sunbursts, Googie swoops, Art Deco), wood with bold tropical colours (over 40 schemes).
[Designboom](https://www.designboom.com/architecture/william-lane-architect-miami-beach-eye-catching-lifeguard-towers-04-26-2022/),
[Metropolis](https://metropolismag.com/projects/miami-beach-gets-36-colorful-new-lifeguard-towers/).

**What makes it itself.** A bright little hut on stilts with a funny roof, and a ramp down to the sand.

**Massing.** Hut 12 x 10 x 9 on a deck at 7, on 4 legs; a ramp to the sand; a dark window band; a roof in one of three
shapes: sunburst (an angled roof with 3 fan fins), swoop (3 tilted slabs in a curve), deco (a stepped parapet with a
porthole); a flag pole; an accent stripe.

**Colours.** Schemes: pink #F49AC1, green #6CC08B and orange #F6A04D; teal #2BB3B1, royal blue #2C55B8 and lime
#B7D94C; purple #5E3A87, lavender #C8B6E2 and peach #F8C7A3; yellow #F7D44C and coral #F0796A (WoodPlanks and
Plaster).

**Parts.** Legs 4, deck 1, ramp 1, hut 1, window 1, roof 3, pole 1, stripe 1: 13.

**Placement.** On Lakefront Park's shore every 150 to 200 studs, each a different shape and scheme from its neighbours,
clear of the park's paths and the bridge.

### C09 `causeway_bridge`
The lake, reuse 1. Restyles feature `cedar_lake_bridge_arches` (the Cedar Lake Bridge: deck at y = 20.2, half-width 27,
from z = 1,780 to 2,570, approaches down to the shores).

**Inspiration.** The Venetian Causeway, Biscayne Bay, 1926: twelve bridges (ten fixed, two bascule) with reinforced
concrete guardrails in a pierced geometric pattern (square units with diagonals forming an X, so the bay shows through),
replica acorn lamp posts about 13 ft tall (1996-99), and arched supports; the bridges are being rebuilt higher with the
same look.
[Wikipedia](https://en.wikipedia.org/wiki/Venetian_Causeway),
[City of Miami](https://www.historicpreservationmiami.com/venetian.html).

**What makes it itself.** A white concrete causeway on arches over the water, with X-patterned railings and acorn
lamps, instead of steel arches.

**Massing.** Piers every 60 studs along the deck (pairs, each 4 x 6), with a shallow arch soffit between each pair of
piers (3 segments); balustrades outside the deck edge (|x| from 27 to 28.2) as 60-stud panels: top rail, bottom rail
and 6 X's, built once as a union and cloned (**U**); acorn lamps every 40 studs each side (post and head); two small
bridge-tender huts at mid-span (deco, white with coral trim) standing outside the deck.

**Colours.** Concrete #E9E4D8; lamp posts #2D3A33 Metal; heads #FFF3D6.

**Night.** Lamp heads `streetlight`.

**Parts.** Piers 26, soffits 36, balustrade panels 50 (each one cloned union), lamps 40, huts 12: 164 plain, 90 U
with the soffits and lamp posts merged too. Built from loose parts the panels alone would be 400.

**Rules.** Nothing on the deck or its shoulders; coordinate the piers with MapBuilder's existing bridge supports
(`addSupports`), which hold the deck; the arches' night kind `arch` goes unused if this replaces them.

---

## 10. Gameplay landmarks: suggested skins

The landmarks in Config/MapLayout keep their places, sizes and doors; only their looks change, in the language of an
archetype above.

| Landmark | Size | Skin |
|---|---|---|
| `dealership_showroom` | 140 x 30 x 100 | W04: display floors as floating concrete slabs on blade columns behind full glass, cars inside at two levels |
| `used_lot_office` | 60 x 14 x 30 | B11: the truss-pylon sign by the street and a boomerang canopy, the classic Miami used-car lot |
| `ohm_factory` | 900 x 60 x 450 | W01 at factory scale with a sawtooth roof and a white-and-glass office front; the brand's roof sign stays |
| `design_studio` | 300 x 40 x 250 | W02: the faceted triangle facade, the AI design studio as a gallery |
| `freight_warehouse` | 360 x 36 x 330 | W01 with loading docks, W05's cranes and containers in the yard |
| `tow_yard_shop` | 120 x 24 x 100 | W01 small, with a big painted sign wall |
| `mesa_control` | 300 x 24 x 80 | C08's Googie swoop roof scaled up, a desert control tower with a lifeguard-stand silhouette |
| `overlook_diner` (feature) | 60 x 13 x 56 | a stainless streamline dining car with a neon sign: already close; give it chrome Foil bands and a `neon_pink` stripe |

---

## 11. Night lights, signs and fonts

**New night kinds** for Config/Environment `nightLights.kinds`: day material SmoothPlastic (Glass for `stained`;
MapBuilder's `nightLight` gives a part its kind's day material), night Neon. Neon's brightness follows its colour, so
these are mid-bright, not white-hot:

| Kind | Night colour | Used for |
|---|---|---|
| `crown` | #CFE0F5 | tower crowns, fins, rib tops, the void glows |
| `crown_show` | from a list | T03's tiers: white most nights; on some game nights one of #E0454B, #3FA36B, #3D7BFF, #F2B8C6, #FFB44A (seeded per game day) |
| `led_edge` | #8FCDE6 | balcony slab edges, soffits, garage strips, roof edges |
| `neon_pink` | #FF4FA8 | deco and MiMo neon |
| `neon_blue` | #3D7BFF | the Colony-style fin, stripes |
| `neon_amber` | #FFB44A | portholes, lanterns, string lights, the bolt |
| `neon_violet` | #9D6BFF | the gallery panels, the void |
| `stained` | the part's own colour | coloured glass (T18's annex): needs a NightLook whose nightColor is optional (keep DayColor) |

The existing `sign` (cyan), `window`, `streetlight`, `floodlight` and `beacon` stay. `arch` goes unused if C09 replaces
the steel arches.

**Signs.** Hotel and shop signs show invented names, rendered with SurfaceGui text as today's signs are. Proposed
names (check each with a quick search before use, so none is a real Miami business): Hotel Voltmere, The Amperly,
Hotel Galvanna, The Coulmont, Hotel Wattsley, The Dynamar, Hotel Filamenta, The Halcyra, Hotel Magnetta, The Capacina,
Hotel Seacurrent. Nothing that sounds like a car brand in Config/Brands (no "Ohm-" names). Other signs: "Lakeside
Market" (C03), "Voltage County Arena" (C04), "Lake Stadium" (C06).

**Fonts.** Roblox Enum.Font only; none from the banned list (`~/.claude/banned-fonts.json`, which bans Arial,
Roboto, Nunito, Fredoka and others). For deco neon: JosefinSans or Michroma; for the MiMo script signs: Fondamento;
for plain building numbers: BuilderSansBold (already the game's label font).

---

## 12. Part budget

Today (Config/Environment `budget`): `buildingParts` 5,600 (measured 5,496 for about 620 buildings), `featureParts`
200, `mapParts` 16,000 for the whole of Workspace.Map.Generated (about 15,500 today). The new mix has fewer, bigger
buildings, about 230 sites in place of about 620 buildings, each with more parts.

| Group | Sites | Plain parts | With unions (U) |
|---|---|---|---|
| Downtown towers T01-T18 (45 towers on 39 sites) | 39 | 2,686 | 1,123 |
| Beach B01-B12 | 40 | 1,421 | 869 |
| Residential R01-R08 | 99 | 2,280 | 1,812 |
| Wynwood W01-W05 | 33 | 910 | 682 |
| Civic and scenery C01-C09 (12 lifeguard stands) | 20 | 735 | 551 |
| **All** | **231** | **8,032** | **5,037** |

(Each group is the per-copy count in section 4 times the reuse column.)

So:
- With the marked repeats merged (U), the whole city fits today's building budget (5,037 against 5,600) with room for
  the feature parts, and the map stays near today's 15,500.
- Built plain, it is about 8,000 building parts and the map about 18,000, over `mapParts` (16,000). That needs
  unions, fewer copies (the houses are the biggest lever: 99 of them are 2,280 parts), or a new perf drive and Davis's
  phone check before the budget is raised.
- Trees and palms are not in these numbers (the scenery step owns them).

The tests (tests/MapBuilder.spec) count BaseParts; a union counts as one.

---

## 13. Open questions

1. **Skyline from the beach.** Downtown sits past the 2,048-stud streaming target from most of the lake. SLIM keeps
   distant buildings visible but needs the place saved to Roblox and Team Create (Davis's settings), may render unions
   wrongly, and shows the day look at night. Choices: SLIM on the towers and accept day colours far away; raise the
   streaming target radius (memory on phones); or leave the far skyline out. Needs a test on one tower.
2. **Unions or plain parts.** The budget only fits with unions (section 12). A first builder pass should union one
   tower (T06) in Edit mode, then check part count, triangles, the look under Future lighting, and SLIM.
3. **Site planning.** MapBuilder makes only F1 lots today. F2 to F5 sites (downtown corners, half and whole blocks, the
   lakefront) need a site planner that keeps every location, pad, corridor and park clear (Dev/MapCheck).
4. **Water-side landmarks.** C03, C04 and C06 want the water in front. The lake is ringed by Lakefront Park, where no
   building may stand; they need a park exception or sites at the park's edge.
5. **Night kinds.** Section 11 adds seven kinds to Config/Environment and a NightLook with an optional colour; T03's
   `crown_show` needs a once-a-game-day colour pick in Services/DayNightService.
6. **Unconfirmed details.** Marked "from photos" in the entries (T03's curved caps, T05's stone and glass, T07's crown,
   T08's roof triangle, B03's colours, C02's colonnade, C07's colours, W01's doors): check each against a reference
   image before building.
7. **Sign names.** The invented names in section 11 need a quick search each before they go into Config.
