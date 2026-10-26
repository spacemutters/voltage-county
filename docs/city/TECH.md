# Making the Miami city read sharp in Roblox (TECH)

For the helpers who build the new buildings and scenery (Dev builders under `src/server/Dev`, looks in
`src/shared/Config`). Written 2026-10-25 for the `miami-city` branch.

Sources: Roblox's own docs (create.roblox.com, read from the `Roblox/creator-docs` source) and tests in Studio on
the Voltage County place the same evening. Everything marked **tested** was built in Studio at z ≈ 4,000-4,400 and
photographed; the pictures are in `docs/city/img/`. Everything else is from the docs or is a proposal, and says so.
The place was put back exactly as it was after the tests: lighting, terrain, MaterialService and the camera.

Scenery (palms, beach, water, bridge, street furniture, palettes, the lighting look) is in `docs/city/SCENERY.md`.

---

## 0. What the tests showed, in one screen

1. **The lighting settings are half the problem, and three of them are switches.** The place runs
   `Lighting.LightingStyle = Soft` ("a flat, retro-Roblox look") and a `ColorGradingEffect` with
   `TonemapperPreset = Retro` ("less saturated, less contrast"), and its `Bloom` has `Intensity = 0`, so Neon never
   glows. With Default tone mapping and sky light on, the same pastel walls went from mud to pastel
   (`img/tech-01-...` vs `img/tech-02-...`). All of these can be set from a script (section 1).
2. **Shape gives sharpness, more than texture does.** Anything that stands 0.5-3 studs proud of a wall (slab edges,
   balconies, eyebrows, fins, cornices) throws a shadow line, and that line is what reads as a crisp, real building.
   Flat boxes with painted windows read as toys whatever the texture.
3. **Windows: our own drawn overlay texture on Glass is crisp up close and still reads at 180 studs.** A generated
   window-grid material reads as a real curtain wall from 100+ studs but its lines wobble up close. A one-line "slab
   edge" texture is the cheapest way to show floors (section 4).
4. **Smooth Plastic is the best pastel stucco.** The generated stucco materials came out dark and blotchy because
   they multiply the part's colour. The generated **terrazzo is excellent**. Travertine came out as a checkerboard
   and the coral stone as rubble.
5. **The Deco recipe works with 25 parts:** a rounded corner (two boxes and a cylinder), ribbon windows, eyebrows
   that wrap the corner, a fin, a stepped parapet and a neon tube. At night one `SurfaceLight` washing the front pink
   is what makes it look like Ocean Drive (`img/tech-12-...`).
6. **Round balcony towers are 2 parts a floor** (a cylinder slab and a glass "puck" rail) and look right straight
   away (`img/tech-10-...`).
7. **Palms built from parts look like toys. A generated mesh palm reads as a palm** at 1,200-2,000 triangles,
   1 part (`img/scenery-01-...`). See SCENERY.md.
8. **Terrain water beats part water** for the bay: moving waves, sparkle and see-through to a sandy bed
   (`img/scenery-05-...`). It needs its own builder and one gameplay check (SCENERY.md).
9. **SLIM** is Roblox's new level-of-detail system, and it replaces the old `StreamingMesh` impostors. It keeps
   far towers visible as cheap merged meshes past the streaming radius. It needs the place published with Team
   Create on, and buildings that never change at runtime, so night lights must live in their own model (section 6).

---

## 1. Before modelling: the lighting switches that decide whether anything reads sharp

These belong to whoever owns lighting (`Config/Environment` `dayNight.scene`, applied once by
`Services/DayNightService.applyScene`). They're listed first because every model below was judged with them on.

| Setting | Now (read from the place) | Set to | Why |
|---|---|---|---|
| `Lighting.LightingStyle` | `Soft` | `Realistic` | Soft is "a flat, retro-Roblox look with softer lights and shadows" (enum docs). Scriptable (security None). |
| `Lighting.PrioritizeLightingQuality` | `false` | `true` | When a phone drops quality, keep shadows and good shaders close by and give up view distance first. Scriptable. |
| `ColorGrading.TonemapperPreset` (the `ColorGradingEffect` already under Lighting) | `Retro` | `Default` | Retro imitates pre-2019 Roblox: "less saturated, less contrast". **Tested:** the biggest single colour change. |
| `Bloom` (already under Lighting) | Intensity 0, Size 24, Threshold 0.95 | start at Intensity 1, Size 24, Threshold 2 (Studio's defaults) and tune in a playtest | With Intensity 0, Neon never glows. Bloom didn't show in Edit-mode screenshots even at Intensity 1 / Threshold 0.8, so tune it in a playtest. A low threshold makes white stucco glow by day. |
| `Lighting.GeographicLatitude` | 41.7 | 50 (was 25.8) | The engine always draws the midsummer sun, so at Miami's real 25.8 it passed nearly overhead and south faces (the whole Ocean Drive row) stood in blue shade all day. At 50 the noon sun is 63 degrees up and a little south (2026-10-26 roast fixes). |
| `GlobalShadows`, `EnvironmentSpecularScale`, `EnvironmentDiffuseScale` | false, 0, 0 in Edit mode | true, 1, 1 | Already in `dayNight.scene` (set at runtime). Shadows and sky reflections are what show bevels and glass. |

**About Technology = Future.** The docs say `Lighting.Technology` "has been superseded by `LightingStyle` ... and
`PrioritizeLightingQuality`". Technology isn't scriptable, but those two are. `Realistic` with
`PrioritizeLightingQuality = true` is the modern way to ask for the best lighting. So `DayNightService` can set
them from Config, and Davis's manual Studio step may not be needed. Check what Studio's Properties panel shows
after the switch.

**Tested in Edit mode:** switching `LightingStyle` to Realistic alone changed nothing visible with shadows off.
Turning on shadows, sky light (`EnvironmentDiffuseScale` 1), sky reflections and the Default tone mapper changed a
lot (`img/tech-01` → `img/tech-02`).

**A side effect to plan for:** with sky light on, the blue sky tints every wall. Pale pastels (for example
`244,190,196`) read as lavender-white, and yellows lean green. The palette in SCENERY.md §8 was picked under these
settings to correct for that.

The MaterialVariant docs add: "For the most realistic reflections, setting EnvironmentSpecularScale and
EnvironmentDiffuseScale to 1, and Ambient and OutdoorAmbient to (0,0,0) is recommended." Zero ambient is too dark
for phones at night, but it is a reason to keep the day ambient low (it is already: `56,60,70` / `112,116,126`).

---

## 2. Shape: what makes an edge read sharp

**Proud elements make shadow lines.** A wall with nothing on it reads flat even in Realistic lighting. Give every
building at least one of these:
- slab edges and balconies 2-4 studs proud, 0.8-1.2 thick
- eyebrows (sun shades over Deco windows) 2.5 deep, 0.5 thick
- vertical fins 2-3 wide and 1.5-2.5 proud
- a cornice band 0.8-1.2 proud
- windows set 0.5-1 back from the wall face, or glass 0.05 proud in a darker colour

Each one throws a shadow onto the wall under it, and that is the crispness Davis is asking for.

**Primitives and when to use them:**
- `Part` Block: walls, slabs, fins, trim.
- `Part` with `Shape = Cylinder`: rounded corners, drums, round towers, round slabs, columns, palm trunks, neon
  tubes. **Tested:** it renders perfectly smooth, unlike a union. Its axis is the part's X axis. To stand one up, use
  `CFrame * CFrame.Angles(0, 0, math.pi / 2)` and make `Size = (height, diameter, diameter)`. `MapBuilder`'s
  `createPart` already makes cylinders (`shape = "cylinder"`).
- `Part` with `Shape = Ball`: finials, globe streetlights, domes (half buried). A Ball is always round (all three
  sizes equal).
- `WedgePart`: chamfers, sloped roofs, ramps, stair-stepped crowns seen from the side.
- `CornerWedgePart`: pyramid tops and hip-roof corners.
- **CSG (unions):** only for shapes the primitives can't make, such as a hollow ring rail, an arch opening, a round
  window or a porthole. **Tested:** `GeometryService:SubtractAsync` made a hollow glass ring rail (a cylinder minus a
  cylinder) in 0.03 s in Edit mode (`img/tech-14-...`). Its edge is visibly faceted where a cylinder part is smooth.
  Docs facts:
  - more than 20,000 triangles get simplified
  - UVs are box-mapped, so textures can stretch
  - `SmoothingAngle` 30-70 keeps edges crisp; 90-180 causes shading artifacts
  - use `CollisionFidelity = Box` for decoration
  - SLIM "might not render" some unions correctly; if one breaks, put it in its own model
  Make each union shape once in the builder and `Clone()` it; don't call `UnionAsync` per building. Never at
  runtime (hard rule 9).

**Avoid coplanar faces.** Two faces in the same plane flicker (z-fighting), and SLIM's docs list it as a known
cause: "Move overlapping parts slightly apart (even 0.01 studs is sufficient)." Make trim at least 0.05 proud, and
never put a part exactly flush with another part's face.

**Bury the bottom.** `TUNING.bury` (1 stud) already sinks building shells into the ground, which hides the seam at
the foot. Keep doing it for walls and columns, but not for floor slabs.

---

## 3. Materials that read well (tested, with the game's day lighting)

| Material | How it read | Use for |
|---|---|---|
| `SmoothPlastic` | Exactly the colour you give it, clean. **Best pastel stucco.** | Deco and MiMo walls, white trim, slabs, eyebrows |
| `Plastic` | Almost the same as SmoothPlastic, with a faint grain up close | Alternative stucco |
| `Plaster` (built-in, new) | A soft grain; its default colour is 204,142,105 | Older Mediterranean walls |
| `Concrete` | Speckled grey | Podiums, parking decks, bridge piers |
| `Glass`, Transparency 0, Reflectance 0.1-0.15 | Shiny, reflects the sky: bright in sun, dark navy in shade | Tower bodies and curtain walls |
| `Glass`, Transparency 0.55 | Reads as a glass balustrade | Balcony rails only (see overdraw, §6) |
| `Neon` | Its colour is its brightness. A 0.3-stud strip barely reads; a 0.6 cylinder tube reads well. | Neon tubes, lit windows, crown rings |
| `Metal` | Brushed grey with reflections | Spires, mullion fins, rails, lamp posts |
| `Marble`, `Limestone`, `Granite`, `Slate` | Stone accents | Lobbies and plinths |
| `ClayRoofTiles` (new) | Barrel tiles | Mediterranean revival roofs |
| `CeramicTiles` (new) | Square tiles | Pool decks |
| Generated **terrazzo** (MaterialVariant on Marble) | **Excellent**: cream with pink, green and grey chips (`img/tech-05`) | Plazas, promenades, lobby floors |
| Generated window grid (MaterialVariant on Metal) | A real curtain wall from 100+ studs; the lines wobble up close (`img/tech-07`) | Background towers; set `StudsPerTile` 24 |
| Generated stucco (on Plaster) | Dark and blotchy: the texture multiplies the part's colour | Don't use |
| Generated travertine (on Limestone) | A loud checkerboard of tiles | Don't use as made; regenerate with "large panels, low contrast" |
| Generated coral stone (on Limestone) | Rubble wall, not keystone | Don't use as made |

**MaterialVariant facts (docs and tests):**
- A MaterialVariant only works as a descendant of `MaterialService`. Parts point at it by name through
  `part.MaterialVariant = "Name"`, and `part.Material` must equal its base material. Names must be unique.
- **Tested:** `Glass` and `Neon` can't be the base material; the variant silently falls back to Plastic.
  `SmoothPlastic`, `Metal` and `Plaster` work. **So a window grid can't be a Glass variant.** It is a Metal or
  SmoothPlastic variant whose roughness and metalness maps make the panes shiny.
- `ColorMap`, `NormalMap`, `RoughnessMap` and `MetalnessMap` are plugin-security. **Tested:** an Edit-mode script
  (`execute_luau`, or a Dev builder) can set them. A runtime script can't, so variants must be built in Edit mode
  and saved in the place.
- The ColorMap's alpha is not used, so a variant can't have holes. Use a `Texture` for overlays with holes.
- There is one `StudsPerTile` per variant, and its tiling can't be offset per part, so floor lines won't land
  exactly on a part's edges. Make one variant per scale you need.
- Docs: "Built-in materials use far less memory than custom textures." Keep custom variants to a short list, about
  6-8.

**Studio's AI generators (tested):**
- `generate_material` takes about 1-2 minutes and makes **four variants per call** (`Name`, `Name1`-`Name3`) under
  `MaterialService.AssistantMaterials`. Each has four maps (colour, normal, roughness, metalness) uploaded as
  ordinary `rbxassetid://` images. Those are **persistent assets in Davis's account**: a builder can rebuild the
  variant later from the IDs alone. `StudsPerTile` starts at 10.
- `generate_texture` only re-textures a MeshPart or a model of meshes, and replaces the source. It does nothing for
  Part buildings. It could be useful for re-skinning a palm or a statue mesh. Not tested.
- `generate_mesh` (for palms): see SCENERY.md §1.

**Better than generated for anything with straight lines: draw the maps ourselves.** A window grid, slab lines and
a crosswalk are exact geometric patterns. A small Python/Pillow script draws them pixel-exact, and the Studio MCP
`upload_image` tool uploads them from a localhost URL (tested; the script is in the appendix). New uploads showed
blank for a few minutes before they rendered, so allow for moderation.

---

## 4. Windows: four ways, tested

| Way | Instances | Up close | At 140-180 studs | Night |
|---|---|---|---|---|
| **A. Overlay `Texture` on a Glass part** (our PNG: white mullions and spandrels, transparent panes, tinted by `Texture.Color3`) | 1 part + 1 Texture per face | Crisp, exact bay and floor grid (`img/tech-06`) | Reads; best on the shaded side (`img/tech-08`, `tech-09`) | On a Neon part it reads as **lit floors with mullions** (`img/tech-13`) |
| **B. Window-grid MaterialVariant** on the whole tower | 1 part | Panes reflect; AI lines wobble (`img/tech-07`) | Reads as a curtain wall | Can't glow (not Neon) |
| **C. Slab-line `Texture`** (white band at the bottom of each floor) | 1 part + 1 Texture per face | Plain | Reads clearly as floors (`img/tech-08`, left tower) | Dark |
| **D. Real mullion parts** | 1 part per mullion | Best | Too small to see | — |

**Use them like this:**
- Hero towers (the 6-10 unique landmarks):
  - A on the faces that face streets
  - real slabs or balconies as parts
  - real fins on the first 2-3 floors (D)
- Mid-rise and background towers: B (a variant drawn by us, not generated), or C plus real slab parts every 2-3
  floors.
- Any building with lit windows at night: keep the Texture overlay on its Neon "lit run" part too, so lit floors
  show mullions instead of a flat orange slab.

**Texture numbers (tested):**
- Bay `StudsPerTileU` = 5-6. Floor `StudsPerTileV` = 12 downtown (`facades.cedar_bend.floorHeight`).
- `Texture.Color3` silver `236,240,244` for light frames, or about `60,64,70` for dark bronze frames.
- Glass body colours tested: `64,96,118` (bright blue in sun), `52,86,104`, `40,84,100`, `34,64,82` (dark navy-teal).
  Reflectance 0.15.
- Align the spandrel to the floor line with `OffsetStudsV`. The origin corner wasn't checked, so set it by eye
  once. The same value works for every part whose height is a whole number of floors.

**Lit windows (tested):**
- The current `nightLights.kinds.window.nightColor` `118,90,54` read as strong amber on Neon. `70,54,34` read dim
  brown.
- Something in between, less saturated (about `100,88,68`), is the next thing to try. That value is a proposal,
  not tested.

---

## 5. Recipes (with numbers)

All sizes in studs. "Decor" means anchored with `CanCollide`, `CanQuery` and `CanTouch` off, which is MapBuilder's
`decor()`. `CanQuery` only takes effect when `CanCollide` is false. `CastShadow` off is noted where it matters.

### 5.1 Glass curtain wall (tested: towers A and H)
- **Body:** one `Part`, `Glass`, Transparency 0, Reflectance 0.15, e.g. 40 × 90 × 40. Make the width a whole number
  of bays and the height a whole number of floors.
- **Overlay:** a `Texture` on Front, Back, Left and Right.
  - fine `rbxassetid://107027263614936` or bold `rbxassetid://86379885232472`
  - `StudsPerTileU` 5-6, `StudsPerTileV` 12
- **Corner fins:** 4 × (0.6 × height × 0.6) SmoothPlastic white, 0.1 proud of each corner. Decor, `CastShadow`
  off. They give the box a crisp outline against the sky.
- **Podium:**
  - 46 × 13 × 46 in Concrete or white SmoothPlastic, plus a cap slab 48 × 1 × 48 white
  - not the generated travertine, which reads as a checkerboard (`img/tech-09`)
  - a shopfront band of dark glass 0.05 proud on the street side
- **Parts:** about 6 + 4 Textures, before the crown.

### 5.2 Balcony bands with glass rail (tested: towers C and D, `img/tech-10`)
- **Core:** Glass, colour `52,86,104`, e.g. 30 × 84 × 22, with the slab-line or bold overlay Texture if wanted.
- **Every floor (10 studs):**
  - slab: SmoothPlastic `250,250,248`, 0.8-1.0 thick, 3 studs proud all round (36 × 0.8 × 28 on that core)
  - rail: Glass `178,210,220`, Transparency 0.55, 3.4 tall, sitting on the slab. Decor, `CastShadow` off.
  - either 4 thin rails (0.2 thick) or **one rail box** (35.8 × 3.4 × 27.8) round the core
  - the two read the same from the street, so use the box (1 part) and thin rails only on the top floor, where
    the box's lid shows from above
- **Round tower:**
  - core: cylinder (e.g. 24 across)
  - slab: cylinder 0.8 thick, 7 studs wider than the core
  - rail: a glass cylinder "puck" 3.4 tall, 0.2 narrower than the slab
  - if it must look right from above (seen from a jump), use the CSG ring from §2 instead of the puck, cloned per
    floor
- **Parts:** 2 per floor. A 20-floor tower is about 45 parts.
- **Variety without new parts:** stagger the slab size per floor (wave-like condo edges), cut the slab short on one
  side, or alternate puck and slab colours.
- **Far version:** the slab-line Texture alone (`rbxassetid://127561142232255`, `StudsPerTileV` = floor height) on
  the core. That is 1 part, and it reads as floors at 180 studs.

### 5.3 Rounded Deco corner with eyebrows (tested: 3-storey hotel, 25 parts, `img/tech-11`)
Footprint W 36 × D 28, front face +Z, corner radius R 6, height H 30, floors 9.
- **Body:**
  - `A` box (W−R) × H × D, centred −R/2 in X
  - `B` box R × H × (D−R) at the corner side
  - `Drum` cylinder (H, 2R, 2R) at (W/2−R, H/2, D/2−R), standing up
  - SmoothPlastic, pink `255,168,180`
- **Plinth:** (W+0.4) × 1 × (D+0.4), white.
- **Each upper floor (2 here):**
  - ribbon glass, dark `40,70,86`, 4.6 tall, 0.2 thick, 0.05 proud, on the front and on the side
  - a glass cylinder of radius R+0.05, 4.6 tall, round the drum, so the band turns the corner
- **Eyebrows over each ribbon:**
  - a slab 0.5 thick, 2.6 deep, on the front and on the side
  - a cylinder disc of radius R+2.6, 0.5 thick, at the drum: the hidden half sits inside the building, so it wraps
    the corner with no gap
  - white `252,252,248`, decor
- **Cornice at the parapet:** a 0.8 × 1.2 band plus a cylinder of radius R+1.2 at the drum, accent aqua
  `120,206,214`.
- **The Deco signature:**
  - a vertical fin 3 wide × (H+14) × 2.4 deep, 1.2 proud, white
  - behind it a stepped parapet: 16 × 4 × 3, then 10 × 4 × 3
  - a Neon line 0.4 wide on the fin's face, pink `255,90,170`
- **Neon tube:** a cylinder 0.6 across under the cornice, 0.7 proud, cyan `70,230,255`, decor, `CastShadow` off.
  Tested: reads at night; a 0.3 square strip barely does.
- **Night wash:** this is what makes it Ocean Drive (`img/tech-12`).
  - one fixture part 28 × 0.4 × 0.6, 0.6 in front of the plinth
  - a `SurfaceLight`: Face Top, Angle 50, Range 32, Brightness 3, Colour `255,120,200`, `Shadows = false`
  - lit at night only (a night-light kind, see §6)
- **Not in the test, add it:** a ground-floor shopfront (dark glass 0.6 back from the wall) and a flat awning slab
  1.5 deep over it.

### 5.4 Neon stripe
- **Tube:** `Neon` cylinder 0.5-0.6 across, at least 0.3 proud of the wall, decor, `CastShadow` off.
- **Colours tested:** pink `255,90,170`, cyan `70,230,255`, sky `120,230,255`. Saturated colours read; white blows
  out.
- **By day:** keep the existing `sign` night-light kind, which is SmoothPlastic in the day colour and Neon at night,
  so a tube reads as a pastel moulding in daylight.
- Neon gives no light onto the wall. For light on the wall use a `SurfaceLight` (5.3), one per facade, not one per
  tube.

### 5.5 Stepped crown with lights (tested: tower A, `img/tech-09`)
On a 40 × 40 tower:
- **Tiers:** 36 × 6 × 36, then 28 × 6 × 28, then 18 × 8 × 18, SmoothPlastic `246,246,242`.
- **One ring per tier:** a single Neon slab (tier width + 0.3) × 0.4 × (tier width + 0.3), 0.8 below the tier's top.
  It shows as a lit band on all four sides from one part. Decor, `CastShadow` off.
- **Spire:** Metal cylinder 16 tall × 1.2 across. Add the existing `beacon` night-light kind at its tip if wanted.
- **Parts:** 7. Variations: round tiers (cylinders), a pyramid tip (CornerWedges), or a "lantern" glass box on top
  with a Neon slab inside.

### 5.6 Palm trunks and fronds from parts (tested: don't)
- **Royal:**
  - 2 trunk cylinders (2.8 then 2.2 across, 16 + 20 tall)
  - a green crownshaft cylinder
  - 7 fronds of 2 blades each (0.15 thick, 2.6 then 1.8 wide, 7 + 8 long, rising 28° then drooping 55°)
  - 17 parts
- **Coconut:** 4 leaning trunk drums (6-20° lean) plus 8 fronds; 21 parts.
- **Result:** both look like toy umbrellas next to a generated mesh palm (`img/scenery-01`). Use meshes:
  SCENERY.md §1.

---

## 6. Performance

**Where we are (measured today in Studio):**
- `Workspace.Map.Generated` holds 16,464 instances.
- Parts by folder: Buildings 5,496 (in 169 models), Trees 4,581, Roads 2,361, Streetlights 1,200, Sidewalks 850,
  Locations 297, Ground 241.
- `Config/Environment budget.mapParts` is 16,000.
- The phase 14 drive measured 60 fps on desktop at 7,493 server parts.
- `Config/Perf`: a phone should hold 30 fps (mean 34 ms, p95 40 ms) in 1,000 MB.

**What actually costs on a phone (Roblox's performance docs):**
- **Draw calls** matter most. The docs' example baseline device stays "below 1,000 draw calls and 1,000,000
  triangles".
  - Parts that share a material batch well.
  - Identical meshes with the same `MeshId` and `TextureID` are instanced into one draw call.
  - "Decals, textures, and particles don't batch well and introduce additional draw calls."
  - **So a Texture on every building face is the expensive way.** Keep overlay Textures to hero towers and to the
    faces that face streets, and use a MaterialVariant (no extra instance or draw call) for the rest.
- **Transparency:** "Avoid transparency values other than 0 and 1." Partial transparency overdraws.
  - Tower glass stays Transparency 0.
  - Only balcony rails are translucent, and never put one translucent part behind another in the same line of
    sight (a rail box *inside* another rail box, for example).
- **Shadows:** the docs suggest turning off `CastShadow` on small parts "where shadows are unlikely to be visible",
  with the caveat that it "might result in visual artifacts".
  - Off: mullion fins, rails, neon, signs, lamp heads, trim under about 0.5 studs.
  - **On:** slabs, balconies, eyebrows, fins, crowns, because their shadows are the look.
- **Lights:** each `SurfaceLight`, `SpotLight` and `PointLight` costs.
  - `Shadows = false` always, keep Range at 32 or less, and use few of them (one wash per hero facade, about 20-40
    in the city).
  - Switch them through the night-light system (`Light.Enabled` at dusk), as streetlights already do.
- **Collisions:** "For parts that do not need collisions, disable their collisions by setting CanCollide, CanTouch
  and CanQuery to false." Building shells collide; all trim is decor. Meshes take `CollisionFidelity = Box`, or no
  collision plus a simple collider part.
- **Meshes:**
  - `RenderFidelity = Automatic` drops a mesh's detail past 250 and 500 studs (docs table), so a 2,000-triangle
    palm is cheap at a distance.
  - Upload or generate each mesh once and **clone** it. A different `MeshId` per copy breaks instancing.
- **Instances and memory:** every Texture, Light and SurfaceGui is an instance that streams in and costs memory.
  Built-in materials cost far less memory than custom maps.

**Streaming (all from the docs):**
- `ModelStreamingMode`:
  - `Atomic`: the model and all its parts arrive and leave together. Keep buildings Atomic, as now.
  - `Persistent`: never streams out. "Not intended to circumvent streaming." Keep it to Ground and Roads, as now.
  - `Nonatomic` (the default) and `PersistentPerPlayer` aren't needed here.
- `Workspace.ModelStreamingBehavior = Improved` and `StreamOutBehavior = Opportunistic` are the recommended values.
  Opportunistic is already in `Config/Perf`. `ModelStreamingBehavior` can't be read or set from a script (tried),
  so it is one more value for Davis's Properties-panel step (`docs/LAUNCH.md` step 10) and for
  `default.project.json`.
- The docs suggest "smaller modular models" for streaming and level of detail. **Make one Model per building**
  (not per 500-stud block tile as now), so a building streams and swaps level of detail as a unit. About 600-700
  models is fine.

**Level of detail for far towers: SLIM (new), not StreamingMesh (legacy).**
- `Model.LevelOfDetail = StreamingMesh` draws "a colored, coarse mesh that wraps around all child parts". It
  doesn't support textures, and the docs now call it legacy.
- `Model.LevelOfDetail = SLIM`: "players often cannot distinguish a SLIM mesh from the fully streamed-in original".
  - It merges a model's parts into fewer draw calls at several levels of detail.
  - It stays visible past the streaming radius.
  - It supports Part, MeshPart, Decal, Texture, SurfaceAppearance and unions.
  - It can be set from an Edit-mode builder (plugin capability).
- SLIM requirements:
  1. StreamingEnabled (on).
  2. The place is **saved to Roblox and Team Create is on**. The transcoding runs in the cloud on publish or play,
     so it can't be tested locally. **This is Davis's step:** he turns on Team Create and publishes.
  3. **Static models only:** "Adding or removing parts, changing materials, or modifying geometry at runtime
     prevents SLIM from rendering the model correctly." DayNightService changes the Material and Colour of
     NightLight parts at dusk. **So put each building's night lights (lit-window runs, neon, washes, signs) in a
     sibling Model** (`Building123Lights`: Atomic, `LevelOfDetail = Disabled`), and its static shell in
     `Building123` (Atomic, `LevelOfDetail = SLIM`).
  4. No coplanar faces (§2). Some unions may misrender, so give them their own model if so.
- **What it buys:** the skyline stays visible across the bay without streaming whole towers in. The streaming
  owner could then try `Perf.streaming.targetRadius` 1,024 (the docs' recommended default, half today's 2,048) to
  save phone memory. That is a decision for the perf owner after Davis's phone check, not part of this step.

**Part budgets per building (proposal, to keep the map near today's 16,000 parts):**
- Hero landmark (one of about 10): up to about 120 parts plus up to 8 Textures and 1-2 lights.
- Standard tower or Deco block: 15-45 parts. A Deco hotel is about 25; a 20-floor balcony tower about 45.
- Background filler: 4-10 parts (body, a crown, a slab-line or grid variant, a podium).
- Palms: 2 parts each (a mesh and a trunk collider), down from 2-3 today.
- If the building pass needs more than `buildingParts` 5,600, take it from trees (fewer, better palms) or measure
  first. The perf drive and Davis's phone are the judges (`Config/Perf`).

---

## 7. Fitting this into the builders (for whoever codes it)

- **`PartSpec` (MapBuilder) can't express most of this yet.** It has no `reflectance`, no `materialVariant`, no
  `textures`, no `SurfaceLight`, and no `ball` shape. Proposed additions:
  - `reflectance: number?`
  - `materialVariant: string?`
  - `textures: { { face: Enum.NormalId, id: string, u: number, v: number, offsetV: number?, color: Color3 } }?`
  - `LightSpec.kind = "surface"`
  - `shape = "ball"`
  - `Container.levelOfDetail: Enum.ModelLevelOfDetail?`
- **MaterialVariants need their own Edit-mode builder** (for example `Dev/MaterialBuilder`). Hard rule 9 says
  MapBuilder owns only `Workspace.Map.Generated`. The new builder should:
  - own one folder, e.g. `MaterialService.VoltageCounty`
  - make each variant from asset IDs kept in Config (a `materials` block in `Config/Environment`, or a new
    `Config/Materials.luau`), with names, base material, the four map IDs and `StudsPerTile`
  - be documented like MapBuilder
- **Meshes (palms, umbrellas, boats):**
  - `AssetService:CreateMeshPartAsync(Content.fromUri(id))` works in Edit mode (tested: 0.3 s).
  - Make one MeshPart per species with it, set its `TextureID`, then `Clone()` it for every copy.
- **Signs:** text on a `SurfaceGui`, as MapBuilder already does.
  - Edit-mode screenshots don't show SurfaceGui text. **Tested:** the map's own Ohm roof sign showed blank too, so
    check signs in a playtest.
  - Fonts: see SCENERY.md §7.
- **Names:** no real building, brand or business names in instance names, strings or signs. Inspirations stay in
  docs.

---

## 8. Asset IDs made during these tests (persistent, in Davis's account)

**Overlays we drew** (white with alpha, tinted with `Texture.Color3`):

| Image | Asset | Drawing |
|---|---|---|
| curtain wall, fine | `rbxassetid://107027263614936` | 512 px, mullion 2.7 % at each side edge, spandrel the bottom 16 %, transom at 12 % |
| curtain wall, bold | `rbxassetid://86379885232472` | 256 px, mullion 3.9 %, spandrel 24 %, transom at 10 % |
| slab line | `rbxassetid://127561142232255` | 512 px, white band the bottom 10 % |
| punched window | `rbxassetid://77733097138973` | 512 px, opaque, one opening 88 % × 56 % (not tried on a part) |

**Generated MaterialVariants:** the variants were deleted from the place; their maps remain as assets.

| Material | Base | Maps |
|---|---|---|
| Stucco (not recommended) | Plaster | Colour `132036543882465`, Normal `132234763495340`, Roughness `95094441790917`, Metalness `96475414371647` |
| Terrazzo (recommended) | Marble, Organic | Colour maps of the four variants: `108879435548622`, `89027079111839`, `85693564521693`, `117376901460668`. Their other maps weren't recorded: pair a colour map with Roblox's own Marble normal `9439431240` and roughness `9439431383` (IDs from the materials docs), or regenerate. |
| Window grid | Metal | Colour maps `102602149650051` (the one tested), `104874044982226`, `94163191450535`, `95139460653558` |
| Travertine | Limestone | Colour `71092777774877` (+ `96516096122039`, `123300579954406`, `76589635019536`) |
| Coral stone | Limestone, Organic | Colour `81444625536096` (+ `87922476876395`, `97021340869203`, `109011021627494`) |

**Roblox's own base-material maps** (documented, reusable in our own variants), as colour / normal / roughness:

| Material | Colour | Normal | Roughness |
|---|---|---|---|
| Plaster | `14108671255` | `14108671870` | `14108672378` |
| Concrete | `9920484153` | `9466554006` | `9466554186` |
| Marble | `9439430596` | `9439431240` | `9439431383` |
| Limestone | `9920561437` | `9439415191` | `9439415495` |

---

## Appendix: drawing an overlay

```python
# make_overlay.py: white mullions and spandrel, transparent panes; one tile = one bay x one floor
from PIL import Image, ImageDraw
N = 256
img = Image.new("RGBA", (N, N), (0, 0, 0, 0))
d = ImageDraw.Draw(img)
half = 5                                   # half a mullion at each side edge, so tiles join into one
d.rectangle([0, 0, half - 1, N - 1], fill=(255, 255, 255, 255))
d.rectangle([N - half, 0, N - 1, N - 1], fill=(255, 255, 255, 255))
d.rectangle([0, int(N * 0.76), N - 1, N - 1], fill=(255, 255, 255, 255))   # spandrel: bottom 24 %
d.rectangle([0, int(N * 0.10), N - 1, int(N * 0.10) + 2], fill=(255, 255, 255, 255))  # transom
img.save("overlay.png")
```

Serve the folder with `python -m http.server 8766 --bind 127.0.0.1`, call the Studio MCP `upload_image` with
`http://127.0.0.1:8766/overlay.png`, and keep the returned `rbxassetid://` in Config. Write the script with the
Write tool, not a Bash heredoc (the Bash tool strips backslashes on this machine).

## Docs read
- create.roblox.com/docs/workspace/streaming/slim and /workspace/streaming/techniques
- create.roblox.com/docs/performance-optimization/improve and /performance-optimization/design
- create.roblox.com/docs/parts/materials, /parts/solid-modeling, /parts/textures-decals, /parts/terrain
- create.roblox.com/docs/environment/lighting, /environment/post-processing-effects, /environment/atmosphere
- Engine reference: Lighting (Technology, LightingStyle, PrioritizeLightingQuality, ShadowSoftness), Technology,
  LightingStyle, ColorGradingEffect, TonemapperPreset, MaterialVariant, Texture, Model (LevelOfDetail,
  ModelStreamingMode), ModelLevelOfDetail, RenderFidelity, BasePart (Reflectance, Transparency, CastShadow,
  CanQuery), SurfaceAppearance, GeometryService, Terrain (water)
