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
| `TowHitch` | Hitch ball, rear center (vehicles with `towHitch`: Ohm Mesa, Ironwood Brakken, Kestrow and Tolliver, Northline Grapple and Linesman; on the Grapple it is the end of the underlift) | out (back) | Trailers and towing (Phase 8) |
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

Seat layouts: 1 seat is the driver alone; 2 seats sit side by side; 3 seats are 2 in front and 1 behind;
4 seats are two rows of 2; 5 seats are 2 in front and 3 behind; 6 seats are three rows of 2; 7 seats are
2, 2 and 3; 8 seats are 2, 3 and 3. The driver is always on the left of the front row.

The Ohm body styles (the generic greybox each would get without its bespoke silhouette): Spark and Grand
`sedan`, Current and Summit `suv`, Mesa `pickup`, Hauler `semi`, Pod `pod`, Arc `hypercar`.

### 4.1 The other seven brands (launch catalog, Phase 4)

Every name below is original. "Body" is the `bodyStyle` the greybox is built from (section 5.1). Classics
(sold only on the used lot) are marked in section 6.

| Vehicle / trim | Name in game | Body | Body L x W x H | Wheelbase | Track | Wheel radius / width | Ride height | Chassis height | Seats | Features |
|---|---|---|---|---|---|---|---|---|---|---|
| `aldermoor_belcourt` / `standard` | Belcourt | coupe | 16 x 6.4 x 4.5 (4.48 x 1.79 x 1.26 m) | 10 | 5.4 | 1.25 / 0.85 | 0.65 | 2.3 | 4 | none |
| `aldermoor_belcourt` / `touring` | Belcourt Touring | coupe | same as above | 10 | 5.4 | 1.25 / 0.85 | 0.65 | 2.3 | 4 | none |
| `aldermoor_elowen` / `standard` | Elowen | sedan | 16.5 x 6.5 x 4.7 (4.62 x 1.82 x 1.32 m) | 10.6 | 5.5 | 1.3 / 0.9 | 0.7 | 2.4 | 5 | none |
| `aldermoor_elowen` / `long_range` | Elowen Long Range | sedan | same as above | 10.6 | 5.5 | 1.3 / 0.9 | 0.7 | 2.4 | 5 | none |
| `aldermoor_elowen` / `halcrest` | Elowen Halcrest | sedan | same as above | 10.6 | 5.5 | 1.3 / 0.9 | 0.7 | 2.4 | 5 | none |
| `aldermoor_ravelle` / `standard` | Ravelle | suv | 17 x 7 x 5.9 (4.76 x 1.96 x 1.65 m) | 10.8 | 5.9 | 1.45 / 1 | 1 | 2.9 | 5 | none |
| `aldermoor_ravelle` / `seven_seat` | Ravelle Seven | suv | same as above | 10.8 | 5.9 | 1.45 / 1 | 1 | 2.9 | 7 | none |
| `aldermoor_ravelle` / `halcrest` | Ravelle Halcrest | suv | same as above | 10.8 | 5.9 | 1.45 / 1 | 1 | 2.9 | 5 | none |
| `brannock_calder` / `standard` | Calder | muscle | 16 x 6.4 x 4.4 (4.48 x 1.79 x 1.23 m) | 10 | 5.4 | 1.25 / 0.95 | 0.6 | 2.2 | 4 | none |
| `brannock_calder` / `big_block` | Calder Big Block | muscle | same as above | 10 | 5.4 | 1.25 / 0.95 | 0.6 | 2.2 | 4 | none |
| `brannock_halberd` / `standard` | Halberd | muscle | 16 x 6.6 x 4.4 (4.48 x 1.85 x 1.23 m) | 10.2 | 5.6 | 1.3 / 1.05 | 0.6 | 2.2 | 4 | none |
| `brannock_halberd` / `track` | Halberd Track | muscle | same as above | 10.2 | 5.6 | 1.3 / 1.05 | 0.6 | 2.2 | 4 | none |
| `brannock_halberd` / `brute` | Halberd Brute | muscle | same as above | 10.2 | 5.6 | 1.3 / 1.05 | 0.6 | 2.2 | 4 | none |
| `brannock_parlow` / `standard` | Parlow | coupe | 17 x 6.6 x 4.5 (4.76 x 1.85 x 1.26 m) | 10.8 | 5.6 | 1.3 / 0.95 | 0.65 | 2.3 | 5 | none |
| `brannock_parlow` / `custom` | Parlow Custom | coupe | same as above | 10.8 | 5.6 | 1.3 / 0.95 | 0.65 | 2.3 | 5 | none |
| `brannock_rowan` / `standard` | Rowan | muscle | 16.5 x 6.6 x 4.6 (4.62 x 1.85 x 1.29 m) | 10.6 | 5.6 | 1.3 / 1 | 0.6 | 2.3 | 5 | none |
| `brannock_rowan` / `dual_motor` | Rowan Dual Motor | muscle | same as above | 10.6 | 5.6 | 1.3 / 1 | 0.6 | 2.3 | 5 | none |
| `brannock_rowan` / `brawler` | Rowan Brawler | muscle | same as above | 10.6 | 5.6 | 1.3 / 1 | 0.6 | 2.3 | 5 | none |
| `halden_corrin` / `standard` | Corrin | sedan | 14.5 x 6 x 4.7 (4.06 x 1.68 x 1.32 m) | 9.2 | 5 | 1.2 / 0.8 | 0.7 | 2.4 | 5 | none |
| `halden_corrin` / `long_range` | Corrin Long Range | sedan | same as above | 9.2 | 5 | 1.2 / 0.8 | 0.7 | 2.4 | 5 | none |
| `halden_corrin` / `sport` | Corrin Sport | sedan | same as above | 9.2 | 5 | 1.2 / 0.8 | 0.7 | 2.4 | 5 | none |
| `halden_fernlow` / `standard` | Fernlow | wagon | 15.5 x 6 x 4.9 (4.34 x 1.68 x 1.37 m) | 9.8 | 5 | 1.15 / 0.8 | 0.7 | 2.4 | 5 | none |
| `halden_fernlow` / `deluxe` | Fernlow Deluxe | wagon | same as above | 9.8 | 5 | 1.15 / 0.8 | 0.7 | 2.4 | 5 | none |
| `halden_tovi` / `standard` | Tovi | hatch | 12.5 x 5.8 x 4.8 (3.50 x 1.62 x 1.34 m) | 8.2 | 4.9 | 1.1 / 0.75 | 0.7 | 2.4 | 4 | none |
| `halden_tovi` / `long_range` | Tovi Long Range | hatch | same as above | 8.2 | 4.9 | 1.1 / 0.75 | 0.7 | 2.4 | 4 | none |
| `halden_tovi` / `zip` | Tovi Zip | hatch | same as above | 8.2 | 4.9 | 1.1 / 0.75 | 0.7 | 2.4 | 4 | none |
| `halden_wendle` / `standard` | Wendle | minivan | 16 x 6.6 x 6 (4.48 x 1.85 x 1.68 m) | 10.4 | 5.5 | 1.25 / 0.85 | 0.8 | 2.8 | 7 | none |
| `halden_wendle` / `long_range` | Wendle Long Range | minivan | same as above | 10.4 | 5.5 | 1.25 / 0.85 | 0.8 | 2.8 | 7 | none |
| `halden_wendle` / `eight_seat` | Wendle Eight | minivan | same as above | 10.4 | 5.5 | 1.25 / 0.85 | 0.8 | 2.8 | 8 | none |
| `ironwood_brakken` / `standard` | Brakken | pickup | 18.5 x 7 x 6.4 (5.18 x 1.96 x 1.79 m) | 11.8 | 6 | 1.6 / 1.1 | 1.3 | 3 | 5 | tow hitch |
| `ironwood_brakken` / `long_range` | Brakken Long Range | pickup | same as above | 11.8 | 6 | 1.6 / 1.1 | 1.3 | 3 | 5 | tow hitch |
| `ironwood_brakken` / `trail` | Brakken Trail | pickup | same as above | 11.8 | 6 | 1.6 / 1.1 | 1.3 | 3 | 5 | tow hitch |
| `ironwood_kestrow` / `standard` | Kestrow | offroad | 15 x 6.8 x 6.4 (4.20 x 1.90 x 1.79 m) | 9.6 | 5.8 | 1.6 / 1.1 | 1.5 | 2.8 | 4 | tow hitch, adjustable ride height |
| `ironwood_kestrow` / `long_range` | Kestrow Long Range | offroad | same as above | 9.6 | 5.8 | 1.6 / 1.1 | 1.5 | 2.8 | 4 | tow hitch, adjustable ride height |
| `ironwood_kestrow` / `crawler` | Kestrow Crawler | offroad | same as above | 9.6 | 5.8 | 1.6 / 1.1 | 1.5 | 2.8 | 4 | tow hitch, adjustable ride height |
| `ironwood_tolliver` / `standard` | Tolliver | pickup | 20 x 7.4 x 6.8 (5.60 x 2.07 x 1.90 m) | 13 | 6.3 | 1.7 / 1.2 | 1.4 | 3.2 | 2 | tow hitch |
| `ironwood_tolliver` / `crew` | Tolliver Crew | pickup | same as above | 13 | 6.3 | 1.7 / 1.2 | 1.4 | 3.2 | 5 | tow hitch |
| `ironwood_tolliver` / `heavy_duty` | Tolliver Heavy Duty | pickup | same as above | 13 | 6.3 | 1.7 / 1.2 | 1.4 | 3.2 | 5 | tow hitch |
| `kaze_kobi` / `standard` | Kobi | hatch | 13 x 5.9 x 4.5 (3.64 x 1.65 x 1.26 m) | 8.4 | 5 | 1.1 / 0.85 | 0.6 | 2.2 | 4 | none |
| `kaze_kobi` / `sprint` | Kobi Sprint | hatch | same as above | 8.4 | 5 | 1.1 / 0.85 | 0.6 | 2.2 | 4 | none |
| `kaze_kobi` / `attack` | Kobi Attack | hatch | same as above | 8.4 | 5 | 1.1 / 0.85 | 0.6 | 2.2 | 4 | none |
| `kaze_rensa` / `standard` | Rensa | coupe | 14 x 6.2 x 4.1 (3.92 x 1.74 x 1.15 m) | 8.8 | 5.3 | 1.2 / 0.95 | 0.5 | 2 | 4 | none |
| `kaze_rensa` / `club` | Rensa Club | coupe | same as above | 8.8 | 5.3 | 1.2 / 0.95 | 0.5 | 2 | 2 | none |
| `kaze_rensa` / `apex` | Rensa Apex | coupe | same as above | 8.8 | 5.3 | 1.2 / 0.95 | 0.5 | 2 | 2 | none |
| `kaze_rinto` / `standard` | Rinto | coupe | 13.5 x 5.9 x 4 (3.78 x 1.65 x 1.12 m) | 8.6 | 5 | 1.1 / 0.85 | 0.55 | 1.9 | 2 | none |
| `kaze_rinto` / `twin_cam` | Rinto Twin Cam | coupe | same as above | 8.6 | 5 | 1.1 / 0.85 | 0.55 | 1.9 | 2 | none |
| `montevale_alzara` / `standard` | Alzara | exotic | 15.2 x 7 x 3.6 (4.26 x 1.96 x 1.01 m) | 9.2 | 6 | 1.3 / 1.1 | 0.45 | 1.8 | 2 | none |
| `montevale_alzara` / `halo` | Alzara Halo | exotic | same as above | 9.2 | 6 | 1.3 / 1.1 | 0.45 | 1.8 | 2 | none |
| `montevale_corvane` / `standard` | Corvane | exotic | 14.5 x 6.6 x 3.7 (4.06 x 1.85 x 1.04 m) | 8.8 | 5.6 | 1.2 / 1 | 0.5 | 1.8 | 2 | none |
| `montevale_corvane` / `grand` | Corvane Grand | exotic | same as above | 8.8 | 5.6 | 1.2 / 1 | 0.5 | 1.8 | 2 | none |
| `montevale_valtero` / `standard` | Valtero | exotic | 14.8 x 6.8 x 3.7 (4.14 x 1.90 x 1.04 m) | 9 | 5.8 | 1.25 / 1.05 | 0.45 | 1.8 | 2 | none |
| `montevale_valtero` / `circuit` | Valtero Circuit | exotic | same as above | 9 | 5.8 | 1.25 / 1.05 | 0.45 | 1.8 | 2 | none |
| `northline_grapple` / `standard` | Grapple | tow | 20 x 7.4 x 7.6 (5.60 x 2.07 x 2.13 m) | 12.5 | 6.3 | 1.6 / 1.1 | 1.3 | 3.2 | 2 | tow hitch |
| `northline_grapple` / `heavy_lift` | Grapple Heavy Lift | tow | same as above | 12.5 | 6.3 | 1.6 / 1.1 | 1.3 | 3.2 | 2 | tow hitch |
| `northline_linesman` / `standard` | Linesman | pickup | 19 x 7.2 x 7 (5.32 x 2.02 x 1.96 m) | 12 | 6.1 | 1.5 / 1.05 | 1.2 | 3 | 2 | tow hitch |
| `northline_linesman` / `crew` | Linesman Crew | pickup | same as above | 12 | 6.1 | 1.5 / 1.05 | 1.2 | 3 | 5 | tow hitch |
| `northline_longbox` / `standard` | Longbox | van | 20 x 7.6 x 9.2 (5.60 x 2.13 x 2.58 m) | 13 | 6.4 | 1.4 / 1 | 1 | 3.2 | 3 | none |
| `northline_longbox` / `long_range` | Longbox Long Range | van | same as above | 13 | 6.4 | 1.4 / 1 | 1 | 3.2 | 3 | none |
| `northline_longbox` / `extended` | Longbox Extended | van | **23** x 7.6 x 9.2 (6.44 x 2.13 x 2.58 m) | **15** | 6.4 | 1.4 / 1 | 1 | 3.2 | 3 | none |
| `northline_satchel` / `standard` | Satchel | van | 17 x 7 x 8 (4.76 x 1.96 x 2.24 m) | 11 | 6 | 1.3 / 0.9 | 0.9 | 3 | 2 | none |
| `northline_satchel` / `long_range` | Satchel Long Range | van | same as above | 11 | 6 | 1.3 / 0.9 | 0.9 | 3 | 2 | none |
| `northline_satchel` / `crew` | Satchel Crew | van | same as above | 11 | 6 | 1.3 / 0.9 | 0.9 | 3 | 3 | none |

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

### 5.1 Generic greybox bodies (every other brand)

Vehicles outside the Ohm lineup are built by `VehicleBuilder` from their `bodyStyle` and geometry, with the
brand's front face, tail lamps and default paint (section 6). They are placeholders to replace with final art;
the silhouette cues below are what the final art should keep.

| bodyStyle | Greybox silhouette |
|---|---|
| `sedan` | Three-box: raked windshield, roof over two rows, sloped rear glass into a flat trunk lid |
| `hatch` | Short and upright; near-vertical hatch; small roof spoiler |
| `coupe` | Short cabin, long sloping rear glass, ducktail deck |
| `wagon` | Long roof running to the back, roof rails |
| `suv` | Tall; roof rails, dark rocker and arch flares |
| `minivan` | Short hood, tall boxy three-row cabin, sliding-door tracks |
| `muscle` | Long flat hood with a bulge, cabin set back, hip kick over the rear wheels, lip spoiler (no spoiler on classics) |
| `exotic` | Cab-forward wedge, very low nose, side intakes, rear haunches, diffuser, wing on pylons (no wing on classics) |
| `offroad` | Boxy and upright on a tall flat hood; cladding, roof rails, spare wheel on the tailgate, hitch receiver |
| `pickup` | Tall flat hood, cab sized to its seat rows, **open bed** and tailgate, hitch receiver. Service-class pickups (Northline Linesman) carry tall tool boxes, a ladder rack and an amber beacon bar instead of bed walls |
| `van` | Short sloping nose, upright windshield, **tall cargo box**, wide mirrors, cargo-door seam; tall vans get a ladder rack |
| `tow` | Work cab, flat deck with tool boxes, a mast and an angled **boom** with a hook, an underlift that carries the `TowHitch`, amber light bar |
| `semi` | Cab-over tractor (the Hauler's construction scaled to the body height), fifth wheel with the `Kingpin` |
| `pod` | Short rounded body under a glass canopy, no mirrors |
| `hypercar` | The exotic wedge with a glass canopy and two thruster nozzles in the tail |

Classics (used lot only) get bright bumpers. Every generic body stays within the 60-part greybox budget.

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

**Launch lineups and greybox looks.** The greybox paint is only the default color (customization repaints
it); the face is the front lamp layout the generic body uses. Classics are sold only on the used lot.

| Brand | Greybox paint / face | Launch models |
|---|---|---|
| **Ohm Motors** | Neutral silver / light strip | Spark, Current, Mesa, Hauler, Pod, Arc; classics Grand and Summit |
| **Halden** | Soft blue / square lamps over a two-tone bumper | Tovi (economy hatch), Corrin (sedan), Wendle (minivan); classic Fernlow (wagon) |
| **Ironwood** | Olive / stacked lamp pods, big grille | Brakken (pickup), Kestrow (off-roader), Tolliver (fuel work truck) |
| **Aldermoor** | Deep navy / lamp blade with a bright crest | Elowen (luxury sedan), Ravelle (luxury SUV); classic Belcourt (grand-touring coupe) |
| **Kaze** | Signal yellow / slit lamps and splitter | Rensa (sports coupe), Kobi (tuner hatch); classic Rinto (roadster-style coupe) |
| **Brannock** | Red / bar grille with set-in lamps | Halberd (fuel muscle coupe), Rowan (electric four-door muscle); classics Calder (muscle coupe) and Parlow (hardtop coupe) |
| **Montevale** | Burnt orange / slit lamps | Valtero, Alzara (supercars); classic Corvane (wedge supercar) |
| **Northline** | Fleet white with a dark stripe / square lamps, heavy bumper | Satchel (delivery van), Grapple (tow truck), Linesman (utility service truck), Longbox (large work van) |

Shared rules for every brand:

- No text, badges or logos on the car (brand logos come later as decals from `Config/Brands.luau`).
- Lights are separate parts so the light-show system can drive them.
- Paint, trim and glass are separate parts with their tags, so customization can recolor them.
- Keep silhouettes distinct inside a brand as well as across brands.
