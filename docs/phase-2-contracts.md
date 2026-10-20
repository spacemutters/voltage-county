# Phase 2 contracts

The shared agreement for Phase 2 (greybox county, road graph, GPS). Read `PLAN.md` §5 and "Phase 2",
`CLAUDE.md`, and `docs/phase-1-contracts.md` (still in force for everything it covers). Implement exactly the
names below; anything not written here is the owner's choice. Phase 1 code is done and checked: change it only
where this document says so.

## Coordinates and the county at a glance

- X is east, **north is -Z** (the way an unrotated car faces), Y is up. Everything within ±5,000 studs of the
  origin (`Config/World.mapHalfExtent`).
- Ground top is **y = 0** everywhere except where the Mesa's hills and the Lakefront bridge rise.
- A road node's `position.Y` is the **road surface top** at that node. Flat roads sit at y = 0.2 (a 1-stud
  slab whose top is 0.2 above the ground, so ground and road never z-fight).
- Lanes are `Config/World.laneWidth` (12) wide.

Rough layout (the county designer owns the exact numbers):

| Zone id | Display name | Where (x range, z range) | What's there |
|---|---|---|---|
| `cedar_bend` | Cedar Bend | centre, about x −900..900, z −900..900 | street grid; used lot (player spawn), dealership, charging plaza, fuel station, rideshare hotspots |
| `riverside` | Riverside | west, about x −3000..−1300, z −1000..1500 | curving suburban streets; house plots, delivery drops, fuel station |
| `the_plant` | The Plant | east, about x 1300..3000, z −1000..1200 | wide industrial roads; EV factory, Design Studio, freight depot, truck chargers |
| `mesa_test_site` | Mesa Test Site | north, about x −800..2600, z −3100..−1400 | hills, ramps, a drag strip with gates, an open flight zone, a no-fly zone around buildings |
| `lakefront` | Lakefront | south, about x −1400..1400, z 1400..3100 | a lake, a raised bridge, the scenic meet spot |
| `county_loop` | County Loop | a ring highway about 3,400 studs out (rounded square or many-sided polygon) | 4 lanes, 70 mph, on/off ramps to an avenue in each direction, a fuel and charging stop |

- Four avenues run out of downtown (north, south, east, west), through their zone, to a loop interchange.
- The **dev test track** moves out of the way: west of the loop, around x ≈ −4,300 (see "World settings and
  test tooling").
- The Studio-owned `Workspace.Baseplate` and the origin `SpawnLocation` are removed by the lead after the
  map is built. MapBuilder never touches anything outside `Workspace.Map.Generated`.

## Data (owner: county designer)

### `Config/MapLayout.luau`

```lua
export type Zone = {
	id: string, displayName: string,
	min: Vector2, max: Vector2, -- X and Z bounds of the zone on the ground
	groundColor: Color3,
	buildingColors: { Color3 },
	buildingHeight: { min: number, max: number }, -- studs
	buildingDensity: number, -- 0..1, how full the city blocks are
}
export type Location = {
	id: string, -- unique, e.g. "used_lot", "charger_plaza_1"
	displayName: string, -- shown to players (GPS, prompts)
	tag: string, -- one CollectionService tag from PLAN.md §5 (see list below)
	zone: string, -- a Zone id
	position: Vector3, -- centre of the footprint, on the driving surface (Y = surface top). The tagged
	-- part's BOTTOM face sits at position.Y; its centre (part.Position) is at position.Y + size.Y / 2.
	yaw: number, -- degrees; 0 faces north (-Z)
	size: Vector3, -- the tagged part's size (volumes for zones, pads for stalls)
	attributes: { [string]: any }?, -- e.g. { kW = 250 }, { rate = 5 }, { jobType = "delivery" }, { index = 1 }
	gps: boolean?, -- true = listed as a GPS destination
}
local MapLayout = {
	seed = 0, -- for deterministic building placement
	zones = { [string]: Zone }, -- keyed by id
	zoneOrder = { string }, -- display order
	locations = { Location },
	playerSpawns = { CFrame }, -- SpawnLocations for players (at the used lot)
}
```

Tags (PLAN.md §5), every one used at least once:
`SpawnPad`, `ChargerStall` (`kW`), `TruckCharger`, `FuelPump` (`rate`), `Dealership`, `UsedLot`,
`DesignStudio`, `JobDepot` (`jobType`), `RideshareHotspot`, `HousePlot`, `MeetSpot`, `FlightZone`,
`NoFlyZone`, `DragStripGate` (`index`).

Every location must be reachable by car: within `roadReach` (Config/RoadGraph) studs of a road edge.

### `Config/RoadGraph.luau`

```lua
export type Kind = "highway" | "arterial" | "street" | "ramp" | "bridge" | "dirt"
export type Node = { id: string, position: Vector3, zone: string }
export type Edge = {
	from: string, to: string, -- node ids; every edge is two-way
	lanes: number, -- total lanes, both directions
	speedLimitMph: number,
	surface: "asphalt" | "dirt" | "concrete",
	kind: Kind,
}
export type Style = {
	shoulder: number, -- extra width each side beyond the lanes, studs
	sidewalk: number, -- sidewalk width each side (0 = none)
	color: Color3,
	lineColor: Color3,
}
local RoadGraph = {
	nodes = { Node },
	edges = { Edge },
	styles = { [Kind]: Style },
	roadReach = 60, -- studs: how far from a road edge a location may sit and still count as reachable
	loopNodeIds = { string }, -- the County Loop's nodes in driving order (for the AutoDriver loop test)
}
```

Rules (a spec checks them):
- Node ids unique; every edge's ends exist; no duplicate edges; the graph is **connected**.
- Edges never cross each other except at a shared node. The only exception is a `bridge` edge passing over
  another edge with at least 15 studs of height between them.
- Edges are straight segments; curves are a chain of short edges. Grade (rise / run) at most 0.12 on roads,
  0.25 on Mesa `dirt` trails. Edges at most 1,800 studs long (one part is at most 2,048).
- The County Loop is a closed cycle of `highway` edges (`loopNodeIds` in order).
- Road width is `lanes * World.laneWidth + 2 * styles[kind].shoulder`.

## Road modules (owner: county designer)

### `Road/Graph.luau`
Built once from Config/RoadGraph at first require (precomputed adjacency and a uniform-grid spatial index).
- `Graph.node(id): Node?`, `Graph.nodes(): {Node}`, `Graph.edges(): {Edge}`
- `Graph.neighbors(id): { { node: string, edge: number } }` (edge = index into edges())
- `Graph.edgeWidth(edgeIndex): number`, `Graph.edgeLength(edgeIndex): number`
- `Graph.nearestNode(position: Vector3): (string?, number)` (id, distance)
- `Graph.nearestEdge(position: Vector3): (number?, number, number, Vector3)` (edge index, t along it 0..1,
  horizontal distance, closest point on the centreline)
- `Graph.isOnRoad(position: Vector3, margin: number?): boolean` (within half the road width + margin of a
  centreline, and within a few studs vertically of the surface)
- `Graph.zoneAt(position: Vector3): string?` (from MapLayout zone bounds; the loop by road proximity)

### `Road/Pathfind.luau`
A* over the graph; edge cost = length / speed limit (fastest route), heuristic = straight distance / the
fastest speed limit (admissible).
- `Pathfind.findPath(fromNode: string, toNode: string): { string }?`
- `Pathfind.route(from: Vector3, to: Vector3, heading: Vector3?): Route?` where
  `Route = { points: { Vector3 }, length: number, nodes: { string } }` — starts at the closest point on the
  road nearest `from`, follows the path, ends at the closest point on the road nearest `to` (joins mid-edge,
  no detour to a node behind you). `points` are on the road surface. With `heading` (the car's facing), the
  route leaves the start edge by the end ahead and never turns straight back down it there (no U-turn on a
  narrow street); if that leaves no way (a dead end), it routes as if no heading were given.
- Each `route` call takes **under 5 ms** on the full county (a spec times all GPS destinations).

## Map builder (owner: map builder)

### `src/server/Dev/MapBuilder.luau`
Edit mode only (`RunService:IsStudio()` and not `RunService:IsRunning()`), via MCP execute_luau. Owns only
`Workspace.Map.Generated` (creates `Workspace.Map` as a Folder if missing). Idempotent: running it twice gives
the same instance count. Builds in chunks with `task.wait()` between them (Studio freezes otherwise).
- `MapBuilder.build(): number` — rebuilds everything, returns the instance count of Generated.
- `MapBuilder.plan(): { PartSpec }` — the pure part list (positions, sizes, colors, folder names) the build
  makes, so specs and MapCheck can inspect it without building. Export `PartSpec`.
- Structure under `Generated`:
  - `Ground` (Model, `ModelStreamingMode = Persistent`): zone-tinted slabs, top at y = 0, ≤ 2,048 per axis,
    covering ±5,000 (Mesa hills and the lake shaped from wedges/parts).
  - `Roads` (Model, `Persistent`): `Segments` (one slab per edge, trimmed at both ends so it never overlaps an
    intersection pad or another segment), `Intersections` (one pad per node with ≥ 3 edges or a sharp turn),
    lane lines, highway median. Cars drive on these, so they must never be streamed out.
  - `Sidewalks` (streets and arterials in Cedar Bend and Riverside; raised 0.5, kerb).
  - `Lots` and `Buildings`: block buildings in the space between roads, colored and sized by zone, never on
    a road, a sidewalk or a location footprint. Buildings are grouped into Models per block
    (`ModelStreamingMode = Atomic`).
  - `Streetlights`: posts along streets and arterials at an interval (Neon head, at most one light per
    200 studs actually emitting).
  - `Locations`: one anchored Part per MapLayout location, named by its `id`, sized `size`, with its
    CollectionService tag and attributes plus `DisplayName` and `Zone` attributes. Pads are
    `CanCollide = false`, `Transparency` high, with a visible marking or prop; volumes (`FlightZone`,
    `NoFlyZone`) are invisible boxes. Readable props: charger posts, fuel pumps, a dealership showroom, a
    used-lot sign, the factory, the studio, depots, house pads, a meet-spot overlook, drag-strip gate gantries.
  - `PlayerSpawns`: `SpawnLocation`s at `MapLayout.playerSpawns` (Neutral, Duration 0).
  - `Water`, `Bridges`, `Mesa` as needed (bridge decks are road segments; supports under raised roads).
- Greybox but tidy: muted zone palettes, SmoothPlastic/Concrete/Asphalt-like materials, no real brands, no
  text signs naming real places.

## GPS, spawn flow, notices (owner: GPS helper)

### `Config/Gps.luau`
Route color and width, height above the road, off-route distance, re-route check rate, arrive radius,
max points drawn.

### `src/client/Controllers/GpsController.luau`
- `GpsController.setDestination(target: string | Vector3 | nil)` — a MapLayout location id or a point;
  nil clears. Routes with `Pathfind.route(from, to)` client-side (the graph is shared data, so streaming
  never hides a destination).
- Draws the route with Beams between Attachments in a client-only folder (`Workspace.GpsRoute`, created on the
  client), floating just above the road. Re-routes when the player (or their car) is farther than the
  off-route distance from the route, checked a few times a second with a Heartbeat accumulator. Clears on
  arrival and shows a notice.
- `GpsController.getRoute(): Pathfind.Route?`, `GpsController.remaining(): number?` (studs along the route),
  `GpsController.onChanged` (signal).
- Mounts `UI/GpsPanel.luau` in its own ScreenGui: a GPS button that opens a list of destinations
  (MapLayout locations with `gps = true`, grouped by zone in `zoneOrder`), the active destination with
  distance left in miles (Util/Units) and a clear button. Mobile-first, touch targets ≥ 44 px, consistent
  with the Phase 1 HUD look.

### `src/server/Services/SpawnFlowService.luau`
- Players spawn at the used lot (the `PlayerSpawns` SpawnLocations do that by themselves).
- Adds a ProximityPrompt "Claim your free car" to the `UsedLot` location part (find it under
  `Workspace.Map.Generated.Locations`; warn clearly if the map isn't built).
- Phase 2 stub (the real claim and saving land in Phase 4): Triggered → spawn a temporary used Ohm Spark at the
  nearest `SpawnPad` location via `VehicleService.spawn(player, "ohm_spark", "used", padCFrame)`, then
  `Net.fireClient("Notify", player, { text = "...", kind = "info" })` saying it's a test drive until the
  garage opens. Rate-limit per player with a cooldown from Config.
- No polling: ProximityPrompt.Triggered and Players events only.

### `src/client/Controllers/NotifyController.luau` + `src/client/UI/Toast.luau`
Listens to `Net "Notify"` and shows a short toast (top centre, fades out, queues if several), react-lua, own
ScreenGui. `NotifyController.show(text: string, kind: string?)` for client-side notices (GPS arrival).

## World settings and test tooling (owner: test-tooling helper)

- `default.project.json`: Workspace streaming via `$properties` on a `Workspace` node that has **no `$path`**
  (so Rojo leaves Studio-owned children alone): `StreamingEnabled = true`, a `StreamingMinRadius` and
  `StreamingTargetRadius` suited to cars at highway speed, `StreamOutBehavior`. Roads and ground are
  Persistent models (above), vehicles Atomic (Phase 1), so fast cars never drive off the streamed world.
- `Config/DevTrack.luau`: move the whole dev track west of the County Loop (around x ≈ −4,300, straight still
  running north, everything within ±5,000 and clear of the loop's road by ≥ 300 studs). Keep the same field
  names and waypoints. Update `DevTrackBuilder.luau` only if it hard-codes positions, and `tests/DevTrack.spec`
  for the new clearance rule (clear of the loop and of every map zone instead of the origin).
- `src/server/Dev/MapCheck.luau` (Edit mode): `MapCheck.run(): Report` —
  1. build twice and compare instance counts (must match);
  2. no two road parts (Segments and Intersections) overlap in volume beyond 0.05 studs (spatial query or box
     math), except a bridge over another road;
  3. every MapLayout location has its part, tag and attributes, and is within `roadReach` of a road;
  4. every node is reachable from the used lot's nearest node;
  5. times `Pathfind.route` from the player spawn to every GPS destination (max and mean ms).
  Returns `{ ok: boolean, counts: {number}, overlaps: {string}, missing: {string}, unreachable: {string},
  routeMs: { max: number, mean: number }, notes: {string} }`.
- `src/client/Dev/RouteTests.luau` (Studio only, run from MCP execute_luau in the Client datamodel after the
  player sits in a car, like AutoDriver): `RouteTests.countyLoop(opts?)` drives the whole loop
  (`RoadGraph.loopNodeIds`, closed) with `AutoDriver.drive`, and `RouteTests.zones(opts?)` routes from the
  player spawn into each zone (to one GPS destination per zone) with `Pathfind.route` + `AutoDriver.drive`.
  Both return per-run `{ name, completed, stuckEvents, elapsed, maxMph }` and a total. Use the AutoDriver
  bridge exactly as AutoDriver documents it.
