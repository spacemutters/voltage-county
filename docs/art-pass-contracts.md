# Art pass: realistic, high-detail cars

Davis, 2026-10-20: "we want these cars as good and real looking and like teslas and real cars but we want high poly
models". Read `CLAUDE.md` (hard rule 4: original designs only — no real carmaker or model names, logos, badges or
signature shapes) and the vehicle model contract (PLAN.md §6, `docs/ART_BRIEF.md`). Final art replaces greybox
**without code changes to driving**: the Chassis, wheel hubs, seats and attachments stay exactly as the greybox
builder made them; only what you see changes.

## What exists
- `ServerStorage.ArtPassDrafts.<vehicleId>` — one generated model per catalog vehicle (32), made in Studio with the
  mesh generator: 8 textured MeshParts named `painted body panels_geom`, `windows_geom`, `headlights_geom`,
  `tail lights_geom`, `front left wheel_geom`, `front right wheel_geom`, `rear left wheel_geom`, `rear right
  wheel_geom` (some drafts are the earlier 5-part kind: `body_geom` + 4 wheels — handle both). Each mesh ≤ 20,000
  triangles, real asset ids (they persist). Drafts come out at their own proportions (often shorter than the car).
  Also `test_*` drafts: ignore them.
- `ServerStorage.ArtPassDrafts.box_trailer | flatbed_trailer | tanker_trailer` — the same for the three trailers
  (7 parts: the painted body, landing gear, tail lights and 4 axle-side wheel sets). Fit them onto
  `ServerStorage.TrailerModels` the same way (`Dev/TrailerBuilder` builds the greybox; keep its Chassis, Kingpin and
  wheel parts).
- `ServerStorage.VehicleModels.<vehicleId>_<trim>` — the greybox contract models (80), built by
  `src/server/Dev/VehicleBuilder.luau` (it never overwrites a model whose `Greybox` attribute isn't true).

## `src/server/Dev/ArtPass.luau` (Edit-mode tool, like VehicleBuilder)
`ArtPass.fit(vehicleId)` / `ArtPass.fitAll()`: for every trim of the vehicle, starting from a fresh greybox build
(`VehicleBuilder.assemble`), produce the art model and store it in `ServerStorage.VehicleModels` (attributes
`Greybox = false`, `Art = true`, everything else as the greybox):
- **Body:** the greybox `Body` parts go; the draft's body/windows/lights meshes go in, scaled per axis so their
  combined bounds match the greybox body's bounds (length, width, height from the greybox body's lowest point), and
  centred on it. Every body part Massless, CanCollide/CanQuery/CanTouch false, Anchored like the greybox parts, welded
  the way the greybox body is.
- **Paint:** the paint mesh gets the `Paint` tag, its `TextureID` cleared and `Material` per finish, so the Wrap & Tint
  colour applies (tested 2026-10-20: a red recolour looks right). Windows get `Glass` (tint works). Head and tail
  light meshes keep their textures.
- **Wheels:** each `Wheels/FL|FR|RL|RR` part keeps its Motor6D and size (the wheel visuals spin it); it becomes
  invisible and the matching draft wheel mesh is welded to it, centred on the hub, scaled to the wheel's diameter and
  width, axle along X, mirrored correctly for the right side.
- **Lights:** the `Lights` folder's lamp parts keep their light instances and their sides. Brake and reverse still
  light up: map them so the brake lamp glow is visible on the tail-light mesh (e.g. a thin Neon overlay part the
  lamp logic already toggles, sized to the tail-light mesh's rear face) — read `VehicleVisualsController` and
  `DriveController` lamp code first. As built: every lamp is a glow overlay (see-through until lit); HeadL/HeadR and
  TailL/TailR are each their own side's half of the light mesh (cut out with solid modeling, the Light at that
  lamp), so light-show left/right cues stay apart; Brake is the whole tail mesh; Reverse (and any lamp whose mesh is
  missing or misplaced) is the greybox box moved onto the art surface.
- **Mount points:** recompute `Mount_Roof` (top of the body mesh), `Mount_Hood`, `Mount_Spoiler`, bumpers, plates and
  `CameraHood` from the mesh bounds so extras, plates and the hood camera sit on the real body. As built: raycasts at
  full collision detail from the greybox place and the nearest places around it; each point the fit placed is
  stamped `OnArt`, and `checkArt` fails a model with an unstamped one.
- **Kept pieces:** Hitch, Underlift, FifthWheel(Base), the Arc's nozzles and a trailer's landing-gear tubes stay
  (physics points sit on them) and stretch from their outer end until they meet the art surface (stamped `OnArt`).
- **Trailers:** the art never hangs below the kingpin plane over the front (from the front to 3.5 studs behind the
  kingpin), where a coupled tractor's fifth wheel and rear swing under it; the measured clearance is stamped
  `KingpinClearance` and checked.
- **Greybox reference:** `fit` stores each trim's greybox in `ServerStorage.GreyboxReference` (and
  `VehicleBuilder.buildAll` rebuilds those for art trims), so `VehicleBuilder.spec` keeps comparing fresh builds with
  stored ones.
- **Contract:** `VehicleBuilder.check` (or `BodyKit.check`) passes on every art model; ≤ 60 parts; nothing but the
  Chassis takes part in physics.

## Customization on art models
`Vehicle/Appearance`: paint, finish, tint, calipers, plates and kit extras must all work on art models.
- Wheels: the art wheel meshes are the stock look. Choosing a Phase 7 wheel style in Wrap & Tint hides the art wheel
  and builds that style's wheel faces on the wheel part, as today; "stock" brings the art wheel back.
- Wraps and stripes are parts laid on greybox panels and won't sit on a mesh body. On art models, hide the wrap
  options that can't apply (paint-only), unless a clean projection onto the mesh bounds is possible. As built:
  every exclusive look paints the whole body of any car in its `artColor` and wears its own finish (chrome, brushed
  metal or pearl coat), plus a pearl colour shift, coloured glass or underglow (`Config/Customization` `effectsOf`);
  stripes still go only on banded bodies. Shop wraps with stripes are hidden there and `CustomizationService`
  refuses them unpaid; AI mods on an art car leave off stripes and the secondary color before anything is charged
  (`Validate.fitPaint`), and the backend is told (`paintOnly`).
- Chrome and brushed metal set `Reflectance` and `Material` on the Paint-tagged body mesh, and the body colour sets
  its `Color`. That works because `Dev/ArtPass` clears the body's `TextureID` and adds no `SurfaceAppearance`. If a
  later art pass keeps the surface detail in a `SurfaceAppearance` (roast 2026-10-24 point 1), all three are
  ignored: `Vehicle/Appearance` must then tint through `SurfaceAppearance.Color` instead, in the same change.
- Specs cover all of it, including a full look on a copy of one stored art car per brand.

## Checks (lead runs them in Studio)
- `ArtPass.fitAll()` builds all 80 trims; the spec harness passes; `MapBuilder` showrooms/dealership pads show art.
- Driving is unchanged: a sample of cars from every class runs the Phase 1 checks (settle, bumps, 0–60 within ±15 %)
  through `DesignerTests`-style or `RouteTests` drivers; the semi still tows; the Arc still hops.
- Screenshots of every brand's lineup for Davis.
