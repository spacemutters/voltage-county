# Voltage County: vehicle art brief

For the 3D artist (or Davis) making final vehicle art. Everything here is original: no real carmaker or model
names, logos, badges or distinctive design features, anywhere (the build fails on real brand names).

The game already runs on greybox cars that `src/server/Dev/VehicleBuilder.luau` builds from
`src/shared/Config/Vehicles.luau`. Final art replaces a greybox model without any code change, as long as it
keeps the **model contract** below. The dimensions in the tables are the contract: the physics, cameras, seats
and attachments are all built around them.

## 1. What to make (PLAN.md §9)

- **Original designs for every catalog car.** Each brand has its own design language (section 6): grille or
  nose shape, light signature, proportions. In the unlicensed build, don't reproduce any real car's
  distinctive features.
- **Per vehicle:**
  - a body mesh
  - a low-detail interior (seats, dash block, steering wheel where there is a driver)
  - 4 wheels
  - lights as separate parts
  - parts tagged for paint, trim and glass, and the mount attachments in place
- **The DesignKit** (later, for the AI Car Designer): low-poly body templates, bumpers, spoilers, lights,
  wheels and mount extras (roof racks, light bars, bull bars, wings) that scale cleanly, because the designer
  stretches and recombines them.
- **Licensed brands** (only if a license is signed): use the licensor's approved models or artwork, still
  following the contract.
- **Thumbnails and icon:** original art. Feature the Ohm Arc mid-flight and a player-designed car; those are
  the hooks.

### Budgets

- Final car meshes: at most **20,000 triangles** at the highest level of detail (PLAN.md Phase 14).
- Greybox models: at most 60 parts (the builder enforces it).
- Mobile first: 30+ fps on a mid-range phone. Few draw calls (body in 1 to 3 MeshParts, glass separate,
  lamps separate), textures at most 1024 x 1024.

### Scale

- 1 stud = 0.28 m. Avatars are about 5 studs tall. Cars are game-proportioned, a little shorter and wider
  than real cars at that scale, so an avatar fits.
- A seated default avatar needs about **3.3 studs** from the seat surface to the top of its head. Its lower
  legs hang about 1.6 studs below the seat, so give the cabin floor room or accept hidden feet.

## 2. Model contract (checklist)

Source of truth: `docs/phase-1-contracts.md` ("Vehicle model contract") and PLAN.md §6. Directions: the front
of the car is **-Z** (the chassis LookVector), right is +X, up is +Y.

- [ ] A `Model` named `<vehicleId>_<trim>` (for example `ohm_spark_standard`), one per trim, stored in
      `ServerStorage.VehicleModels`.
- [ ] Attributes `BrandId`, `VehicleId`, `Trim`. `ModelStreamingMode = Atomic`. `PrimaryPart = Chassis`.
- [ ] **Chassis**: a `Part`, invisible (`Transparency = 1`), `CanCollide = true`, size exactly
      `(width, chassisHeight, length)` from the table, its bottom face `rideHeight` above the ground. It is the
      **only physics body** (custom physical properties: density from `Config/Driving.chassisDensity`,
      friction 0.3, elasticity 0).
- [ ] **Pivot** on the ground under the chassis center, facing forward, so `model:PivotTo(groundCFrame)` parks
      the car at ride height. (With Chassis as PrimaryPart this is `Chassis.PivotOffset =
      CFrame.new(0, -(rideHeight + chassisHeight / 2), 0)`.)
- [ ] Every other part: `Massless = true`, `CanCollide = false`, `CanTouch = false`, `CanQuery = false`,
      unanchored, joined to Chassis (a `WeldConstraint`, or the Motor6D noted below). Detail that rides on a
      wheel or door is welded to that wheel or door instead.
- [ ] **Body** folder: the visual parts. Tag (CollectionService) body-colored parts `Paint`, accent parts
      `Trim`, windows `Glass`. If a Paint part uses a SurfaceAppearance, leave its color map neutral with
      `AlphaMode = Overlay` so the part's Color (the player's paint) shows through.
- [ ] **Wheels** folder: parts `FL`, `FR`, `RL`, `RR`, each a cylinder with its axle along the part's X axis,
      diameter `2 * wheelRadius`, width `wheelWidth`. Each holds a `Motor6D` named `Motor`: `Part0 = Chassis`,
      `Part1 = the wheel`, `C0 =` the matching `WheelXX` attachment's CFrame, `C1 = identity`. Code moves wheels
      only through `Motor.Transform` (suspension, steering, spin), so tire and rim meshes go on as children
      welded to the wheel part.
- [ ] **Seats** folder: `Driver` (a `Seat`, left side of the front row; none on the Pod) and
      `Passenger1..N`, one `Seat` per seat in the table, facing forward. `CanTouch = false`, `Disabled = false`.
      The top of each seat is where the avatar's hips go.
- [ ] **Lights** folder: parts `HeadL`, `HeadR`, `TailL`, `TailR`, `Brake`, `Reverse`, each holding a
      `SpotLight` or `SurfaceLight` named `Light` with `Enabled = false` (code turns them on). Headlamps face
      forward, the rest face back. The brake lamp is a strip across the rear.
- [ ] **Doors** folder (optional; the Summit's gull-wing doors): each door is a part joined to Chassis by a
      `Motor6D` named `Hinge` whose C0/C1 sit on the hinge line (along Z), with a number attribute
      `OpenAngle` (degrees). Opening is `Hinge.Transform = CFrame.Angles(0, 0, math.rad(OpenAngle) * t)`.
- [ ] **Attachments on Chassis** (section 3), in chassis space.
- [ ] No text, logos or badges on the car. No real carmaker or model names in any instance name.

Check a model in Studio (command bar, Edit mode):

```lua
local model = game.ServerStorage.VehicleModels.ohm_spark_standard
print(require(game.ServerScriptService.Server.Dev.VehicleBuilder).check(model))
```

An empty list means the model follows the contract. Artist models must **not** carry the `Greybox`
attribute: `VehicleBuilder.buildAll()` then leaves them alone instead of rebuilding over them.

## 3. Attachments

All are `Attachment`s parented to Chassis. "Out" means the LookVector points out of the surface the
attachment sits on; "chassis" means it keeps the chassis orientation (looking forward, up is up).

| Name | Where | Orientation | Used for |
|---|---|---|---|
| `WheelFL`, `WheelFR`, `WheelRL`, `WheelRR` | Hub centers at rest: x = +-track/2, z = -+wheelbase/2 (front is -Z), y = wheelRadius - (rideHeight + chassisHeight / 2) | chassis | Suspension, wheel motors |
| `PlateFront`, `PlateRear` | Center of each plate area | out | License plates (Phase 7) |
| `CameraHood` | Just above the hood, in front of the windshield | chassis | Hood camera |
| `Mount_Roof` | Center of the roof | chassis | Roof racks, light bars |
| `Mount_Hood` | Middle of the hood | chassis | Hood scoops and extras |
| `Mount_Spoiler` | Top of the rear deck or tailgate | chassis | Spoilers and wings |
| `Mount_FrontBumper`, `Mount_RearBumper` | Center of each bumper | out | Bull bars, diffusers |
| `Mount_SideL`, `Mount_SideR` | Middle of each side | out | Side extras |
| `TowHitch` | Hitch ball, rear center (vehicles with `towHitch`: Mesa) | out (back) | Trailers (Phase 8) |
| `Kingpin` | Top center of the fifth-wheel plate (vehicles with `kingpin`: Hauler) | chassis | Semi trailer coupling |
| `Thruster_L`, `Thruster_R`, `Thruster_Down` | Thruster nozzles: two in the tail, one under the car (vehicles with `thrusters`: Arc) | the way the exhaust leaves (back, back, down) | Boost-hop and flight effects (Phase 10) |

## 4. Every vehicle and trim

Dimensions in studs (meters in brackets, 1 stud = 0.28 m). The body box is the visual size; the chassis box
is `width x chassisHeight x length`, starting `rideHeight` above the ground. Wheel hubs sit `wheelRadius`
above the ground.

| Vehicle / trim | Name in game | Body L x W x H | Wheelbase | Track | Wheel radius / width | Ride height | Chassis height | Seats | Features |
|---|---|---|---|---|---|---|---|---|---|
| `ohm_spark` / `used` | Spark (used) | 14 x 6 x 4.6 (3.92 x 1.68 x 1.29 m) | 9 | 5 | 1.2 / 0.8 | 0.7 | 2.4 | 5 (driver + 4) | none |
| `ohm_spark` / `standard` | Spark | same as above | 9 | 5 | 1.2 / 0.8 | 0.7 | 2.4 | 5 | none |
| `ohm_spark` / `long_range` | Spark Long Range | same as above | 9 | 5 | 1.2 / 0.8 | 0.7 | 2.4 | 5 | none |
| `ohm_spark` / `performance` | Spark Performance | same as above | 9 | 5 | 1.2 / 0.8 | 0.7 | 2.4 | 5 | none |
| `ohm_current` / `standard` | Current | 15 x 6.4 x 5.4 (4.20 x 1.79 x 1.51 m) | 9.4 | 5.3 | 1.35 / 0.9 | 0.9 | 2.8 | 5 | none |
| `ohm_current` / `long_range` | Current Long Range | same as above | 9.4 | 5.3 | 1.35 / 0.9 | 0.9 | 2.8 | 5 | none |
| `ohm_current` / `performance` | Current Performance | same as above | 9.4 | 5.3 | 1.35 / 0.9 | 0.9 | 2.8 | 5 | none |
| `ohm_current` / `long_body` | Current Long Body | **17** x 6.4 x 5.4 (4.76 x 1.79 x 1.51 m) | **10.8** | 5.3 | 1.35 / 0.9 | 0.9 | 2.8 | **6** (three rows) | none |
| `ohm_mesa` / `standard` | Mesa | 18 x 7 x 6.2 (5.04 x 1.96 x 1.74 m) | 11.5 | 6 | 1.6 / 1.1 | 1.3 | 3 | 5 | tow hitch, adjustable ride height |
| `ohm_mesa` / `performance` | Mesa Performance | same as above | 11.5 | 6 | 1.6 / 1.1 | 1.3 | 3 | 5 | tow hitch, adjustable ride height |
| `ohm_hauler` / `standard` | Hauler | 24 x 8.5 x 12.5 (6.72 x 2.38 x 3.50 m) | 14 | 7 | 2 / 1.2 | 1.6 | 5.5 | 2 | kingpin, truck charger |
| `ohm_hauler` / `long_range` | Hauler Long Range | same as above | 14 | 7 | 2 / 1.2 | 1.6 | 5.5 | 2 | kingpin, truck charger |
| `ohm_pod` / `standard` | Pod | 10 x 6 x 5.2 (2.80 x 1.68 x 1.46 m) | 6.8 | 5 | 1.1 / 0.8 | 0.7 | 2.6 | 2 passengers, **no driver seat** | autonomous only |
| `ohm_arc` / `performance` | Arc | 14.5 x 6.6 x 3.8 (4.06 x 1.85 x 1.06 m) | 8.8 | 5.6 | 1.25 / 1 | 0.45 | 1.9 | 2 | thrusters |
| `ohm_arc` / `boost` | Arc Boost | same as above | 8.8 | 5.6 | 1.25 / 1 | 0.45 | 1.9 | 2 | thrusters |
| `ohm_arc` / `flight` | Arc Flight | same as above | 8.8 | 5.6 | 1.25 / 1 | 0.45 | 1.9 | **1** (driver only) | thrusters |
| `ohm_grand` / `standard` | Grand | 16 x 6.4 x 4.6 (4.48 x 1.79 x 1.29 m) | 10.2 | 5.4 | 1.3 / 0.9 | 0.7 | 2.4 | 5 | none |
| `ohm_summit` / `standard` | Summit | 16.5 x 6.8 x 5.6 (4.62 x 1.90 x 1.57 m) | 10.2 | 5.6 | 1.4 / 1 | 0.9 | 2.9 | 6 (three rows) | gull-wing doors |

Seat layouts: 1 seat is the driver alone; 2 seats sit side by side; 5 seats are 2 in front and 3 behind;
6 seats are three rows of 2. The driver is always on the left of the front row.

If a dimension has to change for the art, change it in `Config/Vehicles.luau` first (the catalog validator
and the physics read it), then rebuild the greybox to compare.

## 5. The Ohm lineup (what the greybox shows, what the final art keeps)

Ohm Motors is the electric hero brand. Every Ohm car is a job; each silhouette has to read instantly at
phone size.

| Vehicle | Silhouette | Keep in the final art |
|---|---|---|
| **Spark** (sedan) | Sleek, low sedan; raked windshield into a long fastback rear glass that ends in a small ducktail; glass roof | The starter car everyone owns: friendly, clean, unmistakably the "base" Ohm |
| **Current** (crossover) | Taller crossover with an upright hatch, dark lower cladding and arch flares, roof rails, glass roof. Long Body stretches it and adds a third seat row | Practical and tall; Long Body must look clearly longer (rideshare XL) |
| **Mesa** (pickup) | Sharp angular wedge: one straight line from the nose up to a roof peak over the front seats, another down to the tail along two sail panels framing an **open bed**; full-width light bar; tow hitch | Faceted, flat-panel, tough; the bed must stay open (towing and cargo jobs) |
| **Hauler** (semi tractor) | Cab-over: tall flat-fronted cab over the front axle, roof fairing, side skirts, mudguards, fifth-wheel plate over the rear axle | Aerodynamic, clean electric truck; the fifth wheel and kingpin point stay exactly where they are |
| **Pod** (robotaxi) | Short, rounded two-seater; wheels at the corners, rounded front and rear edges, a big glass canopy over both seats, a roof sensor; no driver seat, no steering wheel or pedals | Reads as autonomous at a glance: no driver position, sensor visible |
| **Arc** (hypercar) | Very low and wide; low nose between fender pods that carry the headlamps, all-glass cockpit canopy, rear haunches, center-pylon wing, side intakes, two thruster nozzles in the tail | The endgame car and the thumbnail star. Thruster nozzles must look like cold-gas thrusters (white plume, not flames) |
| **Grand** (flagship sedan) | Long, low sedan: long hood, cabin set back, sloping liftback into a flat trunk lid, painted roof, beltline trim | Elegant, collectible, older flagship |
| **Summit** (flagship SUV) | Tall SUV with a panoramic windshield running back over the front seats, three seat rows, roof rails and **two gull-wing doors** over the middle row (hinged near the roof centerline) | The gull-wing doors are its signature and are animated (light shows, Phase 7) |

## 6. Brand design languages (original)

The catalog grows to eight brands. Each needs a language that is recognizable on its own and never borrowed
from a real carmaker.

| Brand | Segment | Design language |
|---|---|---|
| **Ohm Motors** | Electric hero brand | Smooth, grille-less noses; one continuous light strip across the front and another across the rear; glass roofs and canopies; flush surfaces with few, crisp creases; aero wheels. Futuristic but calm. |
| **Halden** | Everyday hatchbacks, sedans, minivans | Friendly rounded-rectangle shapes; upright greenhouses with big windows; short overhangs; two-tone bumpers in a darker plastic; soft-cornered square lamps; small wheels with chunky sidewalls. Cheap and cheerful. |
| **Ironwood** | Trucks and off-road | Slab sides and a tall, flat hood; square wheel arches with bolt-on flares; stacked vertical lamp pods; visible tow points and skid plates; high ground clearance on chunky tires. Built to tow. |
| **Aldermoor** | Luxury sedans and SUVs | Long hood with the cabin set well back; a tall, flat shoulder line; a slim horizontal lamp blade across the front framing a smooth center panel; a bright-trim window outline; slim vertical tail lamps; large, smooth wheels. Quiet and expensive. |
| **Kaze** | Tuner and sports cars | Compact and low with short overhangs; one sharp crease running nose to tail; big arches over wide tires; functional-looking vents; aero pieces (splitter, ducktail, wing) as bolt-on kit parts; angular lamps. Light and mod-friendly. |
| **Brannock** | Muscle cars and classics | Long hood, short deck; a hip kick over the rear wheels; a wide horizontal bar grille with recessed lamps; a hood bulge; bright bumpers on the classics; big simple tail lamps. Loud and retro without copying any real classic. |
| **Montevale** | Exotics and supercars | Mid-engine, cab-forward wedge; very low nose; deep side intakes ahead of the rear wheels; sculpted rear haunches; a wide rear diffuser; thin slit lamps. Conventional or upward-opening doors, never a copy of a real car's door signature. Fast and flashy. |
| **Northline** | Vans, tow trucks, municipal fleet | Boxy and utilitarian; flat panels sized for livery; high-visibility light bars; ladder racks and wide mirrors; steel wheels; a contrasting stripe band. Built to read from a distance. |

Shared rules for every brand:

- No text, badges or logos on the car (brand logos come later as decals from `Config/Brands.luau`).
- Lights are separate parts so the light-show system can drive them.
- Paint, trim and glass are separate parts with their tags, so customization can recolor them.
- Keep silhouettes distinct inside a brand as well as across brands.
