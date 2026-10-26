# Miami scenery (SCENERY)

Palms, the beach, the bay, the causeway, street furniture, lifeguard stands, signs and neon, the colours and the
lighting look. Companion to `docs/city/TECH.md` (how to make things read sharp, and what things cost). Written
2026-10-25 on `miami-city`.

**Tested** means built in Studio on the Voltage County place under the game's day or night settings and
photographed (`docs/images/city/scenery-*` and `tech-*`; `img/` below means that folder). Untested numbers are
proposals and say so.

**Status 2026-10-26 (the scenery Studio step):** the palms, the beach, the bay, the causeway, the lifeguard stands,
the Town Square and the street furniture are built from the code and photographed (`img/scenery-07` to `-24`). The
map itself (`Workspace.Map.Generated`) has not been rebuilt: the photos come from the county's plan built into
`Workspace.CityPreview` over the two areas (the lake and beach; downtown), with the old map's parts there hidden
while the camera ran. `tests/CityScenery.spec` passes (21 of 21). The assets the code clones or shows are in §10.

What stays fixed: the road graph, every lot, pad and gameplay spot in `Config/MapLayout`, and `Dev/MapCheck`.
Scenery is decoration: it keeps off roads, sidewalks, pads, locations, house plots and props through MapBuilder's
placement grid, just as trees do today.

---

## 1. Palms

**Tested: three generated mesh palms against two palms built from parts** (`img/scenery-01`, `-02`, `-03`).

| | Built from parts | Generated mesh (`generate_mesh`) |
|---|---|---|
| Parts | Royal 17 (2 trunk cylinders, a crownshaft, 7 fronds × 2 blades); coconut 21 | 1 MeshPart (+1 trunk collider, see below) |
| Triangles | about 12 per block, a few dozen per cylinder | 1,200 (`maxTriangles` 1200) to 1,998 |
| Look | **Toy umbrella frames.** Flat blades, too few fronds, a fluorescent crownshaft. | **Reads as a palm.** A swollen-base trunk with ring texture, a full crown and good shadows. The leaves are broad paddles rather than feathery fronds. |
| Draw cost | Many small parts, each with its own shadow | Every copy of one mesh is instanced into one draw call (same `MeshId` and `TextureID`), with automatic detail drop past 250 and 500 studs |

**Recommendation: mesh palms, three species, two variants each, cloned.**
- **Species and where they go:**
  - **Royal palm:** a tall, straight, pale grey trunk with a green crownshaft. Lines the grand avenues and the
    causeway approaches in rows. 45-55 studs tall.
  - **Coconut palm:** a curved, leaning trunk. Beach, park and pool edges, leaning toward the water. 30-38 tall.
  - **Sabal (cabbage) palm:** a shorter, rough "boot" trunk with a round fan crown. Suburbs, clusters and medians.
    22-30 tall.
- **Per palm, 2 parts:**
  - the mesh, decor (`CanCollide`, `CanQuery` and `CanTouch` off), `RenderFidelity = Automatic`
  - **plus one trunk collider**: a cylinder about 1.6 across and 12 tall, `Transparency = 1`, `CanCollide = true`,
    `CastShadow = false`
  - why: a mesh's own collision box would be the whole crown, and cars hop and boost into crowns
  - this keeps today's rule that cars hit trunks and pass through leaves (`Config/Environment trees`)
- **Variety without new meshes:** turn each copy to a random yaw, scale it 0.85-1.2, and tilt coconuts 0-8° more.
  Two variants per species is enough.
- **Count:** today's tree budget is 4,800 parts for up to 1,800 trees. With 2 parts per palm the same budget holds
  2,400 palms, so Miami can be palm-heavy and still within budget.
  - Keep broadleaf trees (shade trees, sea grape) in the parks and the country.
  - Turn the `town` and `park` mixes in `Config/Environment trees.mixes` into mostly palms.
  - Add mesh species to `TUNING.treeSpecies` (a `mesh` entry with asset IDs) next to the block ones.
- **How to place them:**
  - `AssetService:CreateMeshPartAsync(Content.fromUri(meshId))` works in Edit mode (tested: 0.3 s).
  - Make one MeshPart per variant, set `TextureID`, and `Clone()` it for every palm. A clone keeps the IDs, and
    that is what makes instancing work.

### What's in the place (built 2026-10-26)

**`ServerStorage.CityAssets.Palms.royal | coconut | sabal`**: one MeshPart each, the templates `Dev/City/Scenery/Palms`
clones (contract in its header). Each is a generated mesh wearing a **SurfaceAppearance whose colour map cuts the
broad generated leaves into feathery leaflets** (`AlphaMode = Transparency`, `MeshPart.Transparency = 0`: a cutout,
opaque and depth-sorted, no blending). `DoubleSided` on, `CollisionFidelity = Box`, anchored, no collisions (the
build adds the trunk collider), `RenderFidelity = Automatic`. Pivot (`PivotOffset`) at the trunk's foot, +Y up; the
coconut's pivot faces its lean (-Z). Pictures: `img/scenery-07` (generated vs cut), `-08`, `-09`, `-10`, `-11`, `-14`.

| Species | MeshId | Generated TextureID | Cut ColorMap (SurfaceAppearance) | Size (studs), tris |
|---|---|---|---|---|
| Royal | `rbxassetid://99825952232024` | `rbxassetid://94679704607440` | `rbxassetid://120193451326426` | 30 × 50.1 × 29.6, 1,998 |
| Coconut | `rbxassetid://97672368748401` | `rbxassetid://109995022838377` | `rbxassetid://131679333735247` | 26 × 33.0 × 25.7, 1,196 |
| Sabal | `rbxassetid://96543920466780` | `rbxassetid://90675858150519` | `rbxassetid://99984926853045` | 15.8 × 21.9 × 16, 1,800 |

- Royal and coconut are the 2026-10-25 test meshes above; the sabal was generated on 10-26 (published model
  103998449735412), replacing the banana-looking one.
- **Why cut leaves and not new meshes:** seven more generations on 10-26 (royal ×3, coconut ×2, sabal ×2, with and
  without "low-poly", with species names, with "not broad leaves, not a banana"): every royal and coconut came back
  with broad paddle leaves and a squat ball of a crown, the "low-poly" ones looked like toys, and only the first sabal
  (narrow stiff blades) was worth keeping. Prompts over about 500 characters fail ("Character limit exceeded"). Meshes can't be uploaded from here (`AssetService:CreateAssetAsync`
  is "not available yet" in this Studio), so hand-built frond cards were out. The generated leaves already are cards,
  so the cut gives them leaflets instead: `tools/palm_leaflets.py` (how it works, and the exact settings for each
  template, are in its header) with `tools/PalmExport.luau`. Re-running both reproduces the three colour maps to the
  pixel.
- The royal mesh had a lumpy orange fruit cluster under its crown; its texels are repainted as the green crownshaft it
  hides (removing it left a gap between trunk and crown).
- Measured off the meshes into `Config/CityScenery palms`: royal crown 30 across from 0.56 of its height; coconut
  trunk leaning 33° at the foot (`baseLean`), its drooping crown from 0.36 of its height and hanging out over the lean,
  sunk 1.2 so the slanted foot is buried; sabal crown 19 from 0.4. Trunk colliders 2.4-2.6 across.
- Street palms that lean (`leanOut`, the lake ring's coconuts) lean away from the road, out over the water; the
  beach's lawn row leans seaward. The causeway rows stand 18 studs off the deck so their crowns never overhang it.

**`ServerStorage.CityAssets.Plants.clump`**: a low clump of palmetto and bird-of-paradise (MeshId
`rbxassetid://98455972711167`, TextureID `rbxassetid://117688722962320`, published model 100654366340171, 5.5 × 5 ×
5.3, pivot at its foot), cloned into the Town Square's planters (`Palms.plant`, `Config/CityScenery furniture.planter`).
Any other planter can take it the same way.

**Variety:** one template per species; each copy draws its own yaw, scale and lean. A second variant per species
would need a second mesh that doesn't look like a banana (see above).

---

## 2. Beach (sand, shoreline, dunes)

**Tested 2026-10-26** (`img/scenery-12`, `-13`, `-14`, `-15`): built as `Dev/City/Scenery/Beach` plans it, on the
Lakefront Beach band. It reads as a South Beach strand: leaning coconut palms on the sand and along the lawn, the
terrazzo promenade with globe lamps and benches, the low coral wall, dunes, ten lifeguard stands with boardwalks,
umbrella sets near the water and the white foam line. Fixed in Studio:
- The umbrellas were a flat disc on a pole (they read as tables, and dark from above) and the loungers a single wedge
  (a ramp): now a tipped pole, a coloured canopy with a white crown disc on it and a finial, and two loungers each
  with a padded bed and a raised backrest (`Beach.drawSet`, 8 parts), in SmoothPlastic (Fabric turned the pastels
  brown).
- The promenade and the plaza use a **Terrazzo** MaterialVariant on Marble now in `MaterialService` (generated: cream
  ground with coral, grey and sea-glass chips; §10).

**Where:** Cedar Lake becomes the bay.
- The water is x −900..900, z 1,800..2,550, at y −2 over a bed at −12.
- Lakefront Park rings it 150 studs deep (x ±1,050, z 1,650..2,700) inside Lakeshore Drive.
- The beach goes on the park ring, inside its existing bounds, so nothing gameplay moves: no lots, pads or
  locations sit in the park.
- Keep clear of the Lakeview Overlook meet spot and the Overlook Diner site (x 1,072..1,128, z 2,260..2,320).

**Layers, from the water out** (colours are proposals, not tested):
1. **Lake bed and banks:**
   - today Mud `116,104,82`; make them Sand, wet `206,190,152`
   - under clear terrain water a pale bed is what turns the water turquoise (§3)
   - the banks are MapBuilder's wedges (`bankRun` 3, so they're 30 studs wide). The water line sits 6 studs
     inside the lake's edge, where the bank passes y −2.
2. **Dry sand:**
   - a band 50-70 studs wide from the lake edge, in the park's ground slabs
   - `Enum.Material.Sand` at `238,226,198`. Roblox's default sand colour `207,203,167` reads grey-green.
3. **Dunes:**
   - a few low mounds along the back of the sand: WedgeParts 2-3 high and 12-20 long, back to back, in the same
     sand colour
   - 2 parts per mound, 10-16 mounds
   - optional sea-oat tufts later as one small mesh
4. **Promenade:**
   - a walk 10 studs wide between sand and lawn, in the generated **terrazzo** material (TECH §3, tested: excellent)
   - or pale pavers: Concrete `226,220,206`
   - 1 part per straight run
5. **Lawn and palms:** what is left of the park, with coconut palms leaning over the sand and royal palms along
   the promenade.

**Beach props:**
- **Lifeguard stands:** §6.
- **Umbrellas:** a cylinder pole plus a cylinder disc canopy 6 across and 0.3 thick, in stripes of the palette, plus
  a small Ball finial. 3 parts. Or one generated mesh, cloned.
- **Loungers:** a thin box 2 × 0.4 × 6 plus a back wedge. 2 parts. In groups under umbrellas.
- **Beach showers, volleyball net** (2 posts and a thin net part), **a rescue flag**. A handful each.
- All decor, kept to the sand, about 150-250 parts for the whole beach.

---

## 3. Water: the lake as a bay

**Part water as built (tested 2026-10-26, `img/scenery-12`, `-15`, `-16`, `-17`, `-18`; terrain water stays Davis's
call):**
- The first version (see-through **Glass** sheets in five concentric rings, a caustic ripple image) read as a
  swimming pool: bright azure, a pool-floor net pattern, and hard-edged rectangular rings that showed off the lake's
  rectangle from the air (`img/scenery-16`).
- Now (`Dev/City/Scenery/Water`, `Config/CityScenery water`): the turquoise shallows run **only along the beach**, in
  four strips that each fade into the next through a ramp image tinted with the next strip's colour (no hard line),
  and one deep blue sheet covers the rest of the bay right up to the stone-edged shores (deep water at a seawall's
  foot, as in Miami). Nearly solid SmoothPlastic with Reflectance 0.22 (only the first strip is see-through, so the
  sand shows under it), sheets 0.1 thick so their edges draw no lines, and a sparse **sun-glint** image instead of the
  ripple net. 11 parts.
- Still flat and still: the glints don't move. A slow client-side scroll of the glint texture's offset would add life
  cheaply (new runtime code: not done).

**Tested: terrain water against part water** (`img/scenery-04`, `-05`).
- Terrain water: animated ripples, sun sparkle, see-through.
- A SmoothPlastic sheet (today's look, `70,118,150` at Transparency 0.3): a flat painted slab.
- A Glass sheet: brighter, still flat.
- **Terrain water is clearly the Miami look.**

**Is it worth its own builder? Yes, with one gameplay check first.**
- **Ownership:** hard rule 9 gives MapBuilder only `Workspace.Map.Generated`, so terrain water needs its own
  Edit-mode builder, for example `Dev/WaterBuilder`. It would:
  - own Terrain water inside `MapLayout.lakes` only
  - clear each lake box, then fill it: `Terrain:FillBlock(CFrame.new(cx, (bedY + waterY) / 2, cz),
    Vector3.new(width, waterY - bedY, depth), Enum.Material.Water)`
  - set the water look (below)
  - **the place has no terrain today** (`Terrain:CountCells()` = 0, checked), so it owns everything it makes
- **MapBuilder:** stop building the `Water` part (the lake bed, banks and park stay its own).
- **Voxel snapping:** terrain is 4-stud voxels. A box from −12 to −2 lands its surface at about −2 through partial
  occupancy. Check the shoreline once by eye.
- **Look** (tested `40,150,160`, Transparency 0.6, Wave Size 0.15: Caribbean turquoise):

  | Property | Value |
  |---|---|
  | `WaterColor` | `30,130,140` (a touch deeper than the test) |
  | `WaterTransparency` | 0.55 |
  | `WaterReflectance` | 1 |
  | `WaterWaveSize` | 0.15 |
  | `WaterWaveSpeed` | 10 |

  These are Workspace-wide Terrain properties, so the builder sets them.
- **The gameplay check (Davis said keep gameplay):**
  - Cars: the chassis and wheel raycasts ignore water (`WheelVisuals.trackRayFilter`, `IgnoreWater = true`), so a
    car still drives on the bed.
  - Terrain water pushes parts up and slows them. The chassis density is 1.5 (`Config/Driving`), so a car still
    sinks, but underwater it weighs about a third and drags.
  - Characters on foot swim instead of walking on the bed.
  - So driving or walking into the bay will feel different. That is probably right for a bay, but it is a change.
    **Playtest a car into the bay before switching, and tell Davis.**
  - If it feels wrong: either keep part water, or make the bay "deep water" with a respawn. The respawn is new
    gameplay, so it is Davis's call.
- **Cost:** a 1,800 × 750 × 10 block is small for terrain, streams like terrain, and draws as one surface.

**Optional:**
- **Moored boats** in a small marina corner: one generated yacht mesh, cloned, decor, no gameplay. About 10.
- **A sandbar or a small island** with three palms in the bay's open water, for the view from the bridge.

---

## 4. Causeway and bridge

**Tested 2026-10-26** (`img/scenery-17`, `-18`, `-23`): round white piers, cap beams and haunches under the deck, the
pierced X balustrade (the image reads well from the deck), acorn lamps, white arches by day and the cyan-to-pink rib
gradient at night, the icy glow strip along the deck edge. `Dev/City/Preview.night` now honours a part's own
`NightColor` the way `DayNightService` does, so the gradient shows in previews. The royal palm rows on the approaches
stand 18 studs off the deck (14 let their crowns hang over it below the frond clearance).

Lake Avenue crosses the bay on the raised Cedar Lake Bridge: a deck at y 20.2, approaches at 5 %, 10 % and 5 %,
steel arches either side (`MapLayout` feature `cedar_lake_bridge_arches`, 60 × 90 × 750). The deck, its height and
the roads stay. Only railings, supports, arches and lights change.

**Inspiration:** Miami's low causeways (long white concrete viaducts with slim round piers, rows of royal palms on
the approaches, street lamps all along, blue water both sides) and its signature bridges lit in colour at night.

- **Supports** (MapBuilder `addSupports`, today 4 × 4 boxes every 80 studs):
  - make them **cylinders 5 across**, in white concrete `236,234,228` (Concrete)
  - over the water, a cap beam on top: a box 4 tall across the deck width
  - 1-2 parts per pier, same spacing and same places, so MapCheck stays happy
- **Railings** (today one 0.8 × 3 grey bar per segment):
  - a **white concrete parapet** 0.8 thick × 2.2 tall
  - **plus a slim top rail** 0.3 × 0.3 at 3.2 high, painted sea-blue `60,150,190` (Metal)
  - 2 parts per segment
- **Deck edge fascia:**
  - a white band 1.5 tall, 0.2 proud, along both deck edges, with a Neon strip under it, cyan `70,230,255`
  - that strip is a night light (the `arch` kind), dark by day
  - this underside glow is the Miami bridge-at-night look
  - 2 parts per segment
- **Arches:**
  - keep the feature and its footprint
  - by day: white ribs `240,240,236` (Metal) with white hangers
  - at night: a colour gradient rib by rib from cyan through violet to pink
  - today the `arch` night kind has one colour, so this needs a small `DayNightService` change: an optional
    `NightColor` attribute that overrides the kind's colour
  - under the 200-part feature budget
- **Lamps:** double-arm lamps on the deck every 60 studs, alternating sides (streetlight recipe A, §5). Royal palms
  in rows on the land approaches, both sides.

---

## 5. Street furniture

**Tested 2026-10-26** (`img/scenery-10`, `-11`, `-21`, `-22`, `-24`): royal palm rows on the downtown avenues, the
three streetlight styles (white globes on the lake ring), bus shelters, and the zebra crossings: the uploaded bars run
the right way (`crosswalks.turn = false`). The Town Square was a bare dark lawn round a lone fountain; it now has a
terrazzo plaza under the fountain and benches, paths out along the diagonals, and the clump planters (§1;
`img/scenery-25`).

Cedar Bend and Riverside streets and arterials have kerbed sidewalks (MapBuilder). Everything here stands on
sidewalks or verges, keeps MapBuilder's existing clearances, and is decor unless it says "collides".

| Item | Recipe | Parts | Notes |
|---|---|---|---|
| **Streetlight A, arterial / downtown** | pole cylinder 0.5 × 22, dark grey `70,72,76` Metal; arm 0.35 × 0.35 × 6 out over the road; flat head 1.2 × 0.35 × 2.4 (`streetlight` night kind with today's SpotLight) | 3 (today 2) | Today: 600 posts, 1 in 2 lights a pool of light (`lightEmitSpacing` 200). +600 parts if all become this; use it on arterials and the bridge only. |
| **Streetlight B, Deco district** | white pole 0.4 × 12; a Ball globe 1.6 (`streetlight` kind) | 2 | Ocean Drive feel on the streets that face the beach. |
| **Traffic signal (mast arm)** | pole cylinder 0.8 × 20; arm box 0.5 × 0.5 × (half the road width); 2 signal heads 1 × 3 × 1 black, with unlit lenses | 4 per pole | **Decorative only:** traffic doesn't stop at signals. Lenses that never change could look odd, so either leave them dark or cycle them on the client later (a new feature: ask Davis). Downtown arterial junctions only, 2 poles per junction. |
| **Bus shelter** | roof slab 10 × 0.4 × 4 white; 2 posts 0.3; back glass 10 × 6 × 0.2 at Transparency 0.4; bench 8 × 0.4 × 1.4 | 5 (back and posts collide) | Beside, never on, job stops and locations (MapBuilder `locationMargin` 10). |
| **Bench** | seat 6 × 0.4 × 1.4 + back 6 × 1.6 × 0.3, slatted wood `150,110,76` (WoodPlanks) or white | 2 | Promenade, parks, shelters. |
| **Planter** | concrete box 4 × 2 × 4 `226,220,206` + a shrub (Ball 3, LeafyGrass `70,120,60`) or a small palm | 2 | Plazas, Deco frontages. |
| **Bin, bollard** | a cylinder each | 1 | Bollards along the promenade every 8 studs, white. |
| **Palms on the street** | royal or sabal mesh palms in tree wells on the sidewalk, 2.5-3 studs from the kerb, every 30-40 studs; the trunk collider stays | 2 | See the medians note below. |
| **Crosswalk** | **one part with `Transparency = 1` and a stripe `Texture` on its Top face.** Tested: a Texture on a fully transparent part still renders (`img/scenery-06`, drawn with the slab-line image, so the stripes there are thin). Lift 0.02 above the road like lane paint. Stripe PNG: white bars of half the tile, `StudsPerTileU` 3 (1.5-stud bars and gaps), drawn and uploaded like TECH's appendix. | 1 part + 1 Texture | Real stripe parts would be about 10 per crosswalk (about 4,000 for the city). This is 2 instances per crosswalk. Downtown and the beach streets first. |

**Medians: no raised ones.** The arterials have no median island today, only paint. A raised, planted median would
put a kerb in the middle of a driving road, which is a gameplay change (lanes, traffic and MapCheck reach). The
"palm boulevard" look comes from palms in rhythm on **both sidewalks** instead. Only add a planted median where a
road is rebuilt as a dual carriageway in the road graph, and that isn't this pass.

---

## 6. Lifeguard stands

**Tested 2026-10-26** (`img/scenery-19`, `-20`): the four shapes (Deco drum, swoop roof, sunburst, capsule) read as
South Beach towers and no two neighbours match. The box huts' window was a flat dark panel; it now sits in a white
frame with two mullions (`LifeguardStand`, up to 25 parts).

The South Beach towers: a raised hut on stilts with a ramp, each painted its own way. Davis wants each to be
unique.

**Recipe (about 14 parts, decor except stilts and platform):**
- 4 stilts: cylinders 0.5 × 6, white.
- Platform: 8 × 0.5 × 8, plus a deck rail on 3 sides (3 thin parts 0.2 × 1.2).
- Hut: a box 6 × 5 × 6 in a bold palette colour, with **one rounded side** (a cylinder 6 across × 5 tall, half
  inside the box, like the Deco corner) facing the sea.
- Roof: a slab 7.5 × 0.4 × 7.5 overhang plus a shallow wedge or a striped canopy.
- Ramp: one thin part 2.4 × 0.3 × 9 at 30°, with 2 rails.
- Details: a porthole (a cylinder disc 1.6 across, 0.1 proud, a contrasting colour), a stripe band (a thin box),
  a flag pole with a small flag part.

**Six to eight of them**, spaced 120-180 studs along the beach. Each a different scheme from the palette (§8):
- pink with a yellow stripe
- aqua with white
- butter with a violet porthole
- lilac with mint
- white with a rainbow stripe band (3 thin parts)
- coral with teal

---

## 7. Signs and neon

- **Names:** no real building, brand or business names in strings, instance names or signs.
  - Inspirations can be named in docs only.
  - Many short generic words are real, famous Miami Beach hotel names (for example Carlyle, Cardozo, Colony,
    Breakwater, Avalon, Majestic, Tides, Leslie, Cavalier, Park Central, Starlite, Delano, National, Raleigh,
    Shelborne, Betsy, Marlin, Crescent, Pelican, Beacon, Netherland, Waldorf, Fontainebleau, Eden Roc).
  - Invent names, e.g. Marisol, Coralina, Vista Mar, Palmetto Arms, Solano, Bayline. **Search each one before use.**
- **Kinds of sign:**
  - **Vertical blade signs** on Deco fins (letters stacked down the fin's face).
  - **Rooftop name signs** on towers (MapBuilder's landmark roof sign pattern: a board on posts, text on both faces,
    a light bar).
  - Neon "VACANCY" and "OPEN" panels on motels and diners (generic words are fine).
  - Billboards stay with `Config/Ads` (Roblox ad APIs only, hard rule 6).
- **Text:**
  - Use a `SurfaceGui` with `LightInfluence = 0`, as MapBuilder does now.
  - For neon lettering at night, raise `SurfaceGui.Brightness` (scales the GUI's light when LightInfluence is 0;
    1 by default, 0 to 1,000) to about 2-4 at night through a night-light kind, and let Bloom halo it.
  - **Not verifiable in Edit mode:** SurfaceGui text doesn't appear in Edit-mode screenshots at all (the map's own
    Ohm roof sign showed blank too). Check signs in a playtest.
- **Neon outlines:** run Neon tubes (TECH §5.4) round the sign board and along the building edges.
- **Fonts** (Roblox `Enum.Font`, the list read in Studio; none on Davis's banned list):

  | Font | Use |
  |---|---|
  | `JosefinSans` | Deco hotel names. It is a geometric 1920s-style sans. |
  | `Michroma` | Wide, modern names on glass towers. |
  | `Bodoni` | Upscale hotel and condo names. |
  | `Sarpanch` | Bold condensed, for diners, motels and neon panels. |
  | `Oswald` | Condensed, for street signage. |

  - Avoid `Arial`, `Roboto` and `Nunito` (banned).
  - Avoid MapBuilder's `BuilderSans`, Roblox's own default, for Miami signage. Leave gameplay labels as they are.

---

## 8. Miami colours

**All tested under the game's day settings** (Config/Environment `DAY` keyframe, sky light on, Default tone
mapper, the `SceneColor` grade), on SmoothPlastic (`img/tech-03`):

| Colour | Use this | Reads as | Too pale (don't) |
|---|---|---|---|
| Flamingo pink | `255,160,172` | Clear pastel pink | `244,190,196` reads lavender-white |
| Seafoam mint | `140,224,196` reads aqua; for a true mint try `150,228,190` (untested) | Aqua-mint | `186,232,214` |
| Sky aqua | `120,200,232` | Clear sky blue | `180,220,236` |
| Butter yellow | `255,214,112` reads lemon with a green lean; try `255,210,130` (untested) | Lemon | `250,232,170` reads cream-green |
| Lilac | `190,160,236` | Lavender | `214,196,236` |
| Peach coral | `255,170,120` | Peach | `250,204,170` |
| Stucco white | `246,244,238` or `255,255,255` | Warm white | — |

**Why the pale ones fail:** sky light adds blue to every wall, so very pale pastels drift to lavender and
grey-white, and yellows to green. Push saturation about a third further than a real paint chip.

**Trim and accents (tested):**
- white trim `252,252,248`
- aqua accent `120,206,214`
- crown and slab white `246,246,242` and `250,250,248`
- **Glass:**
  - `64,96,118`: bright blue in sun
  - `52,86,104` and `40,84,100`: teal
  - `34,64,82`: dark navy-teal, Brickell-style dark glass

**Night neon (tested):**
- hot pink `255,90,170`
- cyan `70,230,255`
- ice blue `120,230,255`
- façade wash light `255,120,200`

Add violet `170,90,255`, mint `80,255,190` and amber `255,170,60` (untested). Never white Neon: it blows out.

**Rules of thumb:**
- One pastel body, white trim, one accent per building.
- Neighbours differ in hue.
- Glass towers stay cool (blue and teal), and the low Deco blocks carry the colour.
- At night, at most two neon colours per building.

---

## 9. The lighting look to aim for

Owned by `Config/Environment dayNight` and `Services/DayNightService`. TECH.md §1 has the switches that matter
most (LightingStyle Realistic, PrioritizeLightingQuality, the Default tone mapper, Bloom, latitude 50: see TECH.md §1 for why not 25.8).

**The look:**
- **Midday:** a high, hard sun with short, crisp shadows; a saturated cyan sky with fair-weather cumulus; bright
  white walls; pastel colour without grey; turquoise water.
- **Golden hour:** pink-orange light on white towers.
- **Night:** a deep blue-violet sky (never black), magenta and cyan neon, lit lobby glass, pools of warm
  streetlight, and the bridge glowing underneath.

**Proposed values** (only the Day row is what the tests ran under; the rest is untested):

| | Ambient | OutdoorAmbient | Brightness | Atmosphere colour / decay | Notes |
|---|---|---|---|---|---|
| Day (8.5-16.25) | `56,60,70` (today) | `112,116,126` (today) | 2.6 → try 3.0 | `199,210,224` / `106,112,125` (today) | `ShadowSoftness` 0.15 → 0.1 for crisper edges; consider `ColorShift_Top` `255,244,226` for warm sun (untested) |
| Golden hour (17.5) | `78,66,62` | `150,120,102` | 2.3 | `240,170,150` / `210,110,120` (pinker than today's `236,182,148` / `204,122,98`) | |
| Dusk (18.75) | `64,56,82` | `98,84,118` | 1.7 | `132,102,150` / `90,60,120` | |
| Night | `30,30,56` | `58,56,100` | 1.4 | `60,54,104` / `38,32,80` (more violet than today's blue) | Bloom stronger at night if the effect is driven by the clock |

- **Atmosphere:** Density 0.25-0.3, Offset 0.25, Haze 0.6-1.
  - A little Glare (0.2-0.3) gives the sun a hot halo. Glare needs Haze above 0.
- **Colour grade:** keep `SceneColor` (contrast 0.1, saturation 0.12, warm tint `255,250,244`), and saturation can go
  to 0.15 once the Default tone mapper is on. **Tested:** with Default tone mapping the grass already reads a
  healthy green and the sky a clean cyan.
- **Clouds (optional, untested):** a `Clouds` object under Workspace.Terrain (Cover about 0.4, Density about 0.5)
  gives Miami's puffy cumulus. It belongs to whichever builder owns Terrain. Check the cost on Davis's phone first.

---

## 10. Assets the scenery uses (in the place and in Davis's account)

All persistent assets in Davis's account, made 2026-10-25/26 from this repo's tools or Studio's generators; none from
the Creator Store. The Studio-owned instances live in the place, not the repo (Rojo leaves them alone).

| What | Where in the place | Asset ids | Made with |
|---|---|---|---|
| Royal, coconut, sabal palms | `ServerStorage.CityAssets.Palms.<species>` (MeshPart + SurfaceAppearance) | §1 table | `generate_mesh`, then `tools/palm_leaflets.py` |
| Planter clump | `ServerStorage.CityAssets.Plants.clump` (MeshPart) | Mesh `98455972711167`, texture `117688722962320` | `generate_mesh` |
| Terrazzo | `MaterialService.Terrazzo` (MaterialVariant, base Marble, 10 studs a tile) | colour `130850450571191`, normal `71254297405545`, roughness `136327940645803`, metalness `97848610436205` | `generate_material` |
| Zebra crossing bars | `Config/CityScenery crosswalks.image` | `83119463084846` | `tools/draw_scenery_overlays.py` |
| Pierced X balustrade | `Config/CityScenery causeway.balustradeImage` | `110677524796128` | same |
| Water glints | `Config/CityScenery water.texture` | `127637677152735` | same |
| Water ramp (band blend) | `Config/CityScenery water.ramp` | `99210103644499` | same |
| Water ripple net (retired: read as a pool) | not used | `113926883458394` | same |

All ids are `rbxassetid://<id>`. The images were uploaded with the Studio connector's `upload_image` from a localhost
server (`python -m http.server` in `assets/city`).
