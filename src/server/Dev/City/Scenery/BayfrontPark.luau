--!strict
-- The bayfront park (Config/CityScenery bayfrontPark): the open lawn between downtown's bay row and the north shore's
-- hotel row, either side of Lake Avenue, dressed as a Miami bayfront park:
--   promenade     a terrazzo walk along its bay (south) side, the park's whole width, royal palms down both sides,
--                 globe lamps on its bay edge, benches facing the bay, and a zebra crossing where Lake Avenue cuts it
--   fountain      a round terrazzo plaza by the avenue (east): the Fountain over a ring that glows cyan at night,
--                 benches on a ring facing it, globe lamps and royal palms on its diagonals
--   amphitheatre  the Bandshell (west), its mouth to the avenue across a lawn of low curved stone terraces, its apron
--                 ringed in pink neon at night, amber footlights at the stage's foot
--   food trucks   three trucks, a market stall and bistro tables on a paved apron at the lawn's corner by the avenue
--                 and the promenade
--   playground    the PlaygroundSet on a soft play surface, benches watching it
--   sculptures    a coral-stone court framed by hedges, SculptureA and SculptureB in a zigzag on it
--   paths         curving paths between them (slabs laid along smooth curves), lit bollards beside them
--   groves        clumps of coconut, sabal and royal palms across the lawns; flowering shrubs round the plazas
-- The props are the city's shared ones (Dev/City/Props: one part each, cloned from ServerStorage.CityAssets.Props, a
-- few plain parts while a template is missing), each with the invisible box the catalogue gives it where a car or a
-- player could hit it. Everything goes through MapBuilder's placement grid: it keeps off roads, lots and claims,
-- gameplay spots and the avenue's palms and lamps, and a spot found taken is left out, never moved. Paving lies flat
-- (a car may drive over it, or onto the grass) and the solid pieces stand well apart, so a car can always drive out.
-- Once dressed, the open lawn is kept from the random trees (Dev/MapBuilder plants them after the scenery).
-- Pure and deterministic (seeded from the map's seed), within its own part budget, in its own folders:
-- BayfrontPark/Tile<x>_<z> (Atomic, SLIM) and BayfrontParkLights/Tile<x>_<z> for its night lights.
--
--   BayfrontPark.plan(host)                       dresses the park into `host` (Dev/MapBuilder's scenery host);
--                                                 returns the parts it added
--   BayfrontPark.prop(folder, name, prop, foot)   a shared prop's specs at the park's scale (and its collider)

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CityScenery = require(ReplicatedStorage.Shared.Config.CityScenery)
local Environment = require(ReplicatedStorage.Shared.Config.Environment)
local Kit = require(script.Parent.Parent.Kit)
local Palms = require(script.Parent.Palms)
local Piece = require(script.Parent.Piece)
local Props = require(script.Parent.Parent.Props)
local Types = require(script.Parent.Types)

type Host = Types.Host
type Ledger = Types.Ledger
type Rect = Types.Rect
type PartSpec = Types.PartSpec
type Kinds = { [string]: boolean }

local PARK = CityScenery.bayfrontPark
local CROSS = CityScenery.crosswalks
local PLANT = CityScenery.furniture.planter.plant
local NIGHT_TAG = Environment.nightLights.tag
local TAU = 2 * math.pi
local QUARTER = math.pi / 2

-- What the park's standing pieces keep off (its own paving they may stand on).
local BLOCKERS: Kinds = {
	road = true,
	sidewalk = true,
	driveway = true,
	support = true,
	location = true,
	access = true,
	prop = true,
	light = true,
	lamp = true,
	landmark = true,
	feature = true,
	lot = true,
	ramp = true,
	mesa = true,
	lake = true,
	park = true,
	tree = true,
	streetscape = true,
}

local function adjust(kinds: Kinds, drop: { string }, add: { string }): Kinds
	local out = table.clone(kinds)
	for _, kind in drop do
		out[kind] = nil
	end
	for _, kind in add do
		out[kind] = true
	end
	return out
end

-- Paving lies flat under the park's own pieces and under lamp heads; it keeps off everything else, trunks included.
local PAVING = adjust(BLOCKERS, { "streetscape", "lamp" }, {})
-- The promenade's samples keep off the park's pieces too (it's laid over the food trucks' apron, which is paving).
local WALK = adjust(BLOCKERS, { "lamp" }, {})
-- Palms, bollards and shrubs keep off the park's paving as well.
local OFF_PAVING = adjust(BLOCKERS, {}, { "parkPath" })
-- A palm's crown never hangs over a road, a building's lot or a landmark.
local CROWN: Kinds = {
	road = true,
	sidewalk = true,
	support = true,
	landmark = true,
	feature = true,
	lot = true,
}
-- The open lawn kept from the random trees: ground clear of roads, lots and gameplay spots.
local OPEN: Kinds = {
	road = true,
	sidewalk = true,
	driveway = true,
	support = true,
	location = true,
	access = true,
	landmark = true,
	feature = true,
	lot = true,
	ramp = true,
	mesa = true,
	lake = true,
	park = true,
}
local NOTHING: Kinds = {}

local BayfrontPark = {}

type Circle = { c: Vector2, r: number }

-- One planning pass: the host, its budget, the names handed out, and what later pieces need to know (where shrubs go,
-- the round plazas the paths stop at, the promenade's runs, the paths' curves).
type Ctx = {
	host: Host,
	ledger: Ledger,
	added: number,
	counts: { [string]: number },
	shrubs: { Vector2 },
	circles: { Circle },
	walk: { { number } },
	curves: { { Vector2 } },
}

local function nameOf(ctx: Ctx, base: string): string
	local n = (ctx.counts[base] or 0) + 1
	ctx.counts[base] = n
	return `{base}{n}`
end

-- The tile model (or lights tile) a plan point stands in.
local function tilePath(x: number, z: number, lights: boolean): string
	local root = if lights then PARK.lightsRoot else PARK.root
	return `{root}/Tile{math.floor(x / PARK.tile)}_{math.floor(z / PARK.tile)}`
end

-- The same, registered with the host: still parts in Atomic SLIM models, night lights in Atomic models that keep their
-- detail (docs/city/TECH.md §6).
local function tile(host: Host, x: number, z: number, lights: boolean): string
	host.container(if lights then PARK.lightsRoot else PARK.root, "Folder")
	local path = tilePath(x, z, lights)
	host.container(path, "Model", Enum.ModelStreamingMode.Atomic, if lights then "Disabled" else "SLIM")
	return path
end

-- Places `specs` (standing round the first rect) when every rect is clear of `kinds` and the budget has room for them:
-- files them as scenery (paint stays paint), night lights in the lights tile, and reserves the rects as `kind`. True
-- when placed.
local function put(ctx: Ctx, rects: { Rect }, kinds: Kinds, specs: { PartSpec }, kind: string): boolean
	local host = ctx.host
	if #specs == 0 or #rects == 0 then
		return false
	end
	for _, rect in rects do
		if host.blocked(rect, kinds, 0) then
			return false
		end
	end
	if not Piece.take(ctx.ledger, #specs) then
		return false
	end
	local at = rects[1].c
	for _, spec in specs do
		if spec.role ~= "line" then
			spec.role = "scenery"
		end
		spec.folder = tile(host, at.X, at.Y, spec.tag == NIGHT_TAG)
		host.add(spec)
	end
	ctx.added += #specs
	for _, rect in rects do
		host.reserve(rect, kind)
	end
	return true
end

-- A ground-level frame at plan point `at`, its front (-Z) turned `facing` degrees (Config/MapLayout's yaw: 0 faces
-- north, 90 west, -90 east, 180 south).
local function frameAt(host: Host, at: Vector2, facing: number): CFrame
	return CFrame.new(at.X, host.groundAt(at.X, at.Y), at.Y) * CFrame.Angles(0, math.rad(facing), 0)
end

-- The plan point at local (x, z) of a frame.
local function planOf(frame: CFrame, x: number, z: number): Vector2
	local p = frame * Vector3.new(x, 0, z)
	return Vector2.new(p.X, p.Z)
end

local function dir(angle: number): Vector2
	return Vector2.new(math.cos(angle), math.sin(angle))
end

-- A disc of radius `r` as the placement grid sees it: two squares inscribed in it, one turned 45 degrees.
local function discRects(c: Vector2, r: number): { Rect }
	local a = r * math.sqrt(0.5)
	return {
		{ c = c, u = Vector2.xAxis, ha = a, hc = a },
		{ c = c, u = Vector2.new(1, 1).Unit, ha = a, hc = a },
	}
end

local function terrazzo(): Kit.Look
	return Kit.look(PARK.paving.color, PARK.paving.material)
end

local function rolls(rng: Random): Palms.Rolls
	return { scale = rng:NextNumber(), yaw = rng:NextNumber(), lean = rng:NextNumber(), variant = rng:NextNumber() }
end

---------------------------------------------------------------------------------------------------------------
-- Pieces
---------------------------------------------------------------------------------------------------------------

-- The specs for the shared prop `prop` (Config/CityProps) standing at `foot` (on the ground, its front -Z the way it
-- faces) at the park's scale (bayfrontPark.propScale), with the invisible box its catalogue entry gives it where a car
-- or a player could hit it; and its footprint. Errors on a prop the catalogue doesn't know.
function BayfrontPark.prop(folder: string, name: string, prop: string, foot: CFrame): ({ PartSpec }, Rect)
	local info = Props.catalog[prop]
	if info == nil then
		error(`BayfrontPark: no prop {prop} in Config/CityProps`, 2)
	end
	local size = info.size * (PARK.propScale[prop] or 1)
	local specs: { PartSpec } = { Props.spec(folder, name, prop, foot * CFrame.new(0, size.Y / 2, 0), size, "scenery") }
	local share = info.collider
	if share then
		local hit = size * share
		local round = PARK.roundColliders[prop] == true
		local across = math.min(hit.X, hit.Z)
		local shape: "block" | "cylinder" = if round then "cylinder" else "block"
		local collider: PartSpec = {
			folder = folder,
			name = `{name}Hit`,
			class = "Part",
			shape = shape,
			role = "scenery",
			size = if round then Vector3.new(hit.Y, across, across) else hit,
			cframe = foot * CFrame.new(0, hit.Y / 2, 0) * (if round
				then CFrame.Angles(0, 0, QUARTER)
				else CFrame.identity),
			color = Color3.fromRGB(200, 200, 200),
			material = Enum.Material.SmoothPlastic,
			collide = true,
			query = true,
			touch = false,
			shadow = false,
			transparency = 1,
		}
		table.insert(specs, collider)
	end
	local footprint =
		Piece.rect(foot, Vector3.new(-size.X / 2, 0, -size.Z / 2), Vector3.new(size.X / 2, size.Y, size.Z / 2))
	return specs, footprint
end

local function placeProp(ctx: Ctx, base: string, prop: string, foot: CFrame): boolean
	local at = foot.Position
	local specs, footprint = BayfrontPark.prop(tilePath(at.X, at.Z, false), nameOf(ctx, base), prop, foot)
	return put(ctx, { footprint }, BLOCKERS, specs, "streetscape")
end

-- A globe lamp at `at`: a white pole and a globe that glows at night. 2 parts.
local function placeLamp(ctx: Ctx, at: Vector2): boolean
	local L = PARK.lamp
	local host = ctx.host
	local m = Piece.model(nameOf(ctx, "ParkLamp"), CFrame.new(at.X, host.groundAt(at.X, at.Y), at.Y), host.seed)
	Kit.column(m, "", 0, 0, -1, L.pole.Y, L.pole.X, Kit.look(L.poleColor, Enum.Material.SmoothPlastic))
	local globe = Kit.ball(
		m,
		"Globe",
		Vector3.new(0, L.pole.Y + L.globe * 0.4, 0),
		L.globe,
		Kit.look(L.globeColor, Enum.Material.SmoothPlastic)
	)
	globe.light = {
		kind = "point",
		brightness = L.light.brightness,
		range = L.light.range,
		angle = 0,
		color = L.light.color,
		face = Enum.NormalId.Top,
		enabled = false,
	}
	Kit.lit(globe, "streetlight")
	return put(ctx, { Piece.square(at, L.globe / 2 + 0.4) }, BLOCKERS, m.specs, "streetscape")
end

-- A bollard at `at` that glows at night, beside a path (never on paving). 1 part.
local function placeBollard(ctx: Ctx, at: Vector2): boolean
	local B = PARK.bollard
	local host = ctx.host
	local m = Piece.model(nameOf(ctx, "ParkBollard"), CFrame.new(at.X, host.groundAt(at.X, at.Y), at.Y), host.seed)
	local post = Kit.column(m, "", 0, 0, -0.5, B.size.Y, B.size.X, Kit.look(B.color, Enum.Material.SmoothPlastic))
	Kit.lit(post, "streetlight")
	return put(ctx, { Piece.square(at, B.size.X / 2 + 0.3) }, OFF_PAVING, m.specs, "streetscape")
end

-- A palm of `species` at `at` (its draws made by the caller, so one that doesn't fit never shifts the next), when its
-- trunk's room is clear of everything and of the park's paving, and its crown hangs over no road, lot or landmark.
-- Two parts: the trunk a car hits and the crown its template fills (Dev/City/Scenery Palms). True when planted.
local function placePalm(ctx: Ctx, at: Vector2, species: string, draws: Palms.Rolls, scale: { number }?): boolean
	local palm = Palms.species[species]
	if palm == nil then
		return false
	end
	local host = ctx.host
	local room = Piece.square(at, palm.collider.X / 2 + 2.5)
	if host.blocked(room, OFF_PAVING, 0) then
		return false
	end
	local size = Palms.size(palm, draws, scale)
	if host.blocked(Piece.square(at, Palms.reach(palm, size)), CROWN, 0) then
		return false
	end
	if not Piece.take(ctx.ledger, 2) then
		return false
	end
	local trunk, crown = Palms.specs(
		tile(host, at.X, at.Y, false),
		nameOf(ctx, "ParkPalm"),
		"scenery",
		species,
		Vector3.new(at.X, host.groundAt(at.X, at.Y), at.Y),
		draws.yaw * TAU,
		draws,
		scale
	)
	host.add(trunk)
	host.add(crown)
	ctx.added += 2
	host.reserve(room, "tree")
	return true
end

-- A shrub at `at`: a clump of palmetto and bird-of-paradise (the planters' mesh, cloned like a palm), its size drawn
-- in shrubs.scale. 1 part.
local function placeShrub(ctx: Ctx, at: Vector2, rng: Random): boolean
	local S = PARK.shrubs
	local host = ctx.host
	local turn, grow = rng:NextNumber(), rng:NextNumber()
	local ground = host.groundAt(at.X, at.Y)
	local scale = S.scale[1] + grow * (S.scale[2] - S.scale[1])
	local spread = S.clump.spread * scale
	local spec = Palms.plant(
		"",
		nameOf(ctx, "ParkShrub"),
		PLANT,
		Vector3.new(at.X, ground, at.Y),
		turn * TAU,
		S.clump.height * scale,
		spread
	)
	return put(ctx, { Piece.square(at, spread / 2) }, OFF_PAVING, { spec }, "streetscape")
end

---------------------------------------------------------------------------------------------------------------
-- The plazas
---------------------------------------------------------------------------------------------------------------

-- The fountain plaza: the Fountain over its glowing ring, benches facing it, lamps and palms on the diagonals, the
-- terrazzo disc under them all, shrub spots round its rim.
local function fountain(ctx: Ctx)
	local F = PARK.fountain
	local host = ctx.host
	local c = F.at
	local r = F.plaza / 2
	if host.blocked(Piece.square(c, r + 2), BLOCKERS, 0) then
		return
	end
	local frame = frameAt(host, c, F.facing)
	local specs, footprint = BayfrontPark.prop(tilePath(c.X, c.Y, false), "ParkFountain", "Fountain", frame)
	-- The low stone step the basin stands on (the old cyan disc spread past the basin like spilt paint).
	local m = Piece.model("ParkFountainStep", frame, host.seed)
	local step = Kit.column(
		m,
		"",
		0,
		0,
		-0.2,
		F.surround.top,
		F.surround.diameter,
		Kit.look(F.surround.color, F.surround.material),
		"detail"
	)
	table.insert(specs, step)
	if not put(ctx, { footprint }, BLOCKERS, specs, "streetscape") then
		return
	end
	-- Benches on a ring, facing the fountain, between the path mouths (north, south, east, west) and the diagonals.
	local centre = Vector3.new(c.X, frame.Y, c.Y)
	for k = 1, F.benches do
		local p = c + dir((k - 0.5) / F.benches * TAU) * F.benchRing
		placeProp(ctx, "ParkBench", "ParkBench", CFrame.lookAt(Vector3.new(p.X, frame.Y, p.Y), centre))
	end
	for k = 0, 3 do
		placeLamp(ctx, c + dir(math.rad(45 + 90 * k)) * F.lampRing)
	end
	local plaza = Piece.model("ParkFountainPlaza", frame, host.seed)
	local slab = Kit.column(plaza, "", 0, 0, -0.3, PARK.plazaTop, F.plaza, terrazzo(), "detail")
	slab.materialVariant = PARK.paving.variant
	if put(ctx, discRects(c, r), PAVING, plaza.specs, "parkPath") then
		table.insert(ctx.circles, { c = c, r = r })
	end
	local rng = Random.new(host.seed * 17 + 3)
	for k = 0, 3 do
		placePalm(ctx, c + dir(math.rad(45 + 90 * k)) * F.palmRing, F.palmSpecies, rolls(rng))
	end
	for k = 0, 7 do
		table.insert(ctx.shrubs, c + dir(math.rad(22.5 + 45 * k)) * F.shrubRing)
	end
end

-- The amphitheatre: the Bandshell, the neon-ringed apron at its stage's front, the curved terraces of its lawn (the lawn
-- kept open: nothing else stands on it), lamps at its front corners, shrub spots beside it.
local function amphitheatre(ctx: Ctx)
	local A = PARK.amphitheatre
	local host = ctx.host
	local info = Props.catalog.Bandshell
	if info == nil then
		return
	end
	local frame = frameAt(host, A.at, A.facing)
	local box = info.size * (PARK.propScale.Bandshell or 1)
	local T = A.terraces
	local radii = T.radii
	local reach = radii[#radii] + T.depth
	local half = math.min(math.rad(T.spread) / 2, QUARTER)
	local across = math.max(box.X / 2, reach * math.sin(half) + T.depth)
	local front = -box.Z / 2
	-- The shell and its whole lawn must be clear.
	local whole = Piece.rect(frame, Vector3.new(-across, 0, front - reach), Vector3.new(across, box.Y, box.Z / 2))
	if host.blocked(whole, BLOCKERS, 0) then
		return
	end
	local specs, footprint = BayfrontPark.prop(tilePath(A.at.X, A.at.Y, false), "ParkBandshell", "Bandshell", frame)
	if not put(ctx, { footprint }, BLOCKERS, specs, "streetscape") then
		return
	end
	-- The apron, ringed in neon, centred on the stage's front edge (its back half under the shell).
	local stage = frame * CFrame.new(0, 0, front)
	local apron = Piece.model("ParkStageApron", stage, host.seed)
	local ring = Kit.column(
		apron,
		"Ring",
		0,
		0,
		-0.25,
		A.ring.top,
		A.ring.diameter,
		Kit.look(A.ring.color, Enum.Material.SmoothPlastic),
		"detail"
	)
	Kit.lit(ring, A.ring.kind)
	local slab = Kit.column(apron, "", 0, 0, -0.3, PARK.plazaTop, A.apron, terrazzo(), "detail")
	slab.materialVariant = PARK.paving.variant
	-- The footlights, set in the apron along the stage's foot.
	local F = A.footlights
	local strip = Kit.detail(
		apron,
		"Footlights",
		Vector3.new(-F.length / 2, -0.2, -F.inset - F.depth / 2),
		Vector3.new(F.length / 2, F.top, -F.inset + F.depth / 2),
		Kit.look(F.color, Enum.Material.SmoothPlastic)
	)
	Kit.lit(strip, F.kind)
	put(ctx, discRects(Vector2.new(stage.X, stage.Z), A.ring.diameter / 2), PAVING, apron.specs, "parkPath")
	-- The terraces: arcs of low stone round the stage's front, each in straight runs about `segment` long.
	local terraces = Piece.model("ParkTerraces", stage, host.seed)
	local stone = Kit.look(T.color, T.material)
	for i, radius in radii do
		local n = math.max(1, math.ceil(radius * 2 * half / T.segment))
		-- Each tier a step higher than the one in front of it.
		local tall = T.height * i
		for j = 0, n - 1 do
			local a0 = -half + j * 2 * half / n
			local a1 = a0 + 2 * half / n
			local p0 = Vector3.new(radius * math.sin(a0), 0, -radius * math.cos(a0))
			local p1 = Vector3.new(radius * math.sin(a1), 0, -radius * math.cos(a1))
			local mid = (p0 + p1) / 2 + Vector3.new(0, (tall - 0.3) / 2, 0)
			Kit.part(
				terraces,
				`{i}_{j}`,
				"block",
				CFrame.lookAt(mid, mid + (p1 - p0)),
				Vector3.new(T.depth, tall + 0.3, (p1 - p0).Magnitude + 0.4),
				stone,
				"trim"
			)
		end
	end
	local near = radii[1] * math.cos(half) - T.depth
	local lawn = Piece.rect(stage, Vector3.new(-across, 0, -reach), Vector3.new(across, T.height * #radii, -near))
	put(ctx, { lawn }, BLOCKERS, terraces.specs, "streetscape")
	for _, at in A.lamps do
		placeLamp(ctx, planOf(frame, at.X, at.Y))
	end
	for _, at in A.shrubs do
		table.insert(ctx.shrubs, planOf(frame, at.X, at.Y))
	end
end

-- The food trucks: three trucks along the apron's bay half, their serving sides to the lawn, a market stall, bistro
-- tables, two lamps, and the paved apron under them all (it runs on under the promenade's edge).
local function foodTrucks(ctx: Ctx)
	local T = PARK.foodTrucks
	local host = ctx.host
	local frame = frameAt(host, T.at, T.facing)
	local hx, hz = T.apron.X / 2, T.apron.Y / 2
	local apronRect = Piece.rect(frame, Vector3.new(-hx, 0, -hz), Vector3.new(hx, 1, hz))
	if host.blocked(apronRect, BLOCKERS, 0) then
		return
	end
	for k, prop in T.trucks do
		local at = T.truckAt[k]
		if at then
			local foot = frame * CFrame.new(at.X, 0, at.Y) * CFrame.Angles(0, math.rad(T.truckTurn), 0)
			placeProp(ctx, "ParkTruck", prop, foot)
		end
	end
	placeProp(ctx, "ParkStall", T.stall.prop, frame * CFrame.new(T.stall.at.X, 0, T.stall.at.Y))
	local rng = Random.new(host.seed * 23 + 5)
	for _, at in T.tables do
		local turn = (rng:NextNumber() - 0.5) * 0.6
		placeProp(ctx, "ParkTable", "BistroPair", frame * CFrame.new(at.X, 0, at.Y) * CFrame.Angles(0, turn, 0))
	end
	for _, at in T.lamps do
		placeLamp(ctx, planOf(frame, at.X, at.Y))
	end
	local m = Piece.model("ParkFoodCourt", frame, host.seed)
	Kit.detail(m, "", Vector3.new(-hx, -0.3, -hz), Vector3.new(hx, PARK.plazaTop, hz), Kit.look(T.color, T.material))
	put(ctx, { apronRect }, PAVING, m.specs, "parkPath")
end

-- The playground: the PlaygroundSet on its soft surface, benches watching it, shrub spots beside it.
local function playground(ctx: Ctx)
	local P = PARK.playground
	local host = ctx.host
	local r = P.surface / 2
	if host.blocked(Piece.square(P.at, r + 2), BLOCKERS, 0) then
		return
	end
	local frame = frameAt(host, P.at, P.facing)
	if not placeProp(ctx, "ParkPlayground", "PlaygroundSet", frame) then
		return
	end
	for _, at in P.benches do
		placeProp(ctx, "ParkBench", "ParkBench", frame * CFrame.new(at.X, 0, at.Y))
	end
	local m = Piece.model("ParkPlaySurface", frame, host.seed)
	Kit.column(m, "", 0, 0, -0.3, PARK.plazaTop, P.surface, Kit.look(P.color, P.material), "detail")
	if put(ctx, discRects(P.at, r), PAVING, m.specs, "parkPath") then
		table.insert(ctx.circles, { c = P.at, r = r })
	end
	for _, at in P.shrubs do
		table.insert(ctx.shrubs, planOf(frame, at.X, at.Y))
	end
end

-- The sculpture garden: the sculptures in a zigzag, the hedges along the court's long sides (a gap in each), benches,
-- lamps, the stone court under them, shrub spots at its corners.
local function sculptures(ctx: Ctx)
	local S = PARK.sculptures
	local host = ctx.host
	local frame = frameAt(host, S.at, S.facing)
	local hx, hz = S.court.X / 2, S.court.Y / 2
	local court = Piece.rect(frame, Vector3.new(-hx, 0, -hz), Vector3.new(hx, 1, hz))
	if host.blocked(court, BLOCKERS, 0) then
		return
	end
	local rng = Random.new(host.seed * 29 + 7)
	for _, piece in S.pieces do
		local turn = rng:NextNumber() * TAU
		placeProp(
			ctx,
			"ParkSculpture",
			piece.prop,
			frame * CFrame.new(piece.at.X, 0, piece.at.Y) * CFrame.Angles(0, turn, 0)
		)
	end
	local H = S.hedge
	local leaves = Kit.look(H.color, H.material)
	for _, side in { -1, 1 } do
		local zc = side * (hz - H.inset - H.width / 2)
		for _, run in { { -hx + H.inset, -H.gap / 2 }, { H.gap / 2, hx - H.inset } } do
			local min = Vector3.new(run[1], -0.3, zc - H.width / 2)
			local max = Vector3.new(run[2], H.height, zc + H.width / 2)
			local m = Piece.model(nameOf(ctx, "ParkHedge"), frame, host.seed)
			Kit.box(m, "", min, max, leaves)
			put(ctx, { Piece.rect(frame, min, max) }, BLOCKERS, m.specs, "streetscape")
		end
	end
	for _, at in S.benches do
		placeProp(ctx, "ParkBench", "ParkBench", frame * CFrame.new(at.X, 0, at.Y))
	end
	for _, at in S.lamps do
		placeLamp(ctx, planOf(frame, at.X, at.Y))
	end
	local m = Piece.model("ParkCourt", frame, host.seed)
	Kit.detail(m, "", Vector3.new(-hx, -0.3, -hz), Vector3.new(hx, PARK.plazaTop, hz), Kit.look(S.color, S.material))
	put(ctx, { court }, PAVING, m.specs, "parkPath")
	for _, at in S.shrubs do
		table.insert(ctx.shrubs, planOf(frame, at.X, at.Y))
	end
end

---------------------------------------------------------------------------------------------------------------
-- The promenade
---------------------------------------------------------------------------------------------------------------

local function walkNear(ctx: Ctx, x0: number, x1: number): boolean
	for _, span in ctx.walk do
		if span[2] >= x0 and span[1] <= x1 then
			return true
		end
	end
	return false
end

-- The walk: long terrazzo runs wherever its line is clear (Lake Avenue cuts it in two), and a zebra crossing where a
-- road cuts it with walk on both sides.
local function promenade(ctx: Ctx)
	local W = PARK.promenade
	local host = ctx.host
	local area = PARK.area
	local samples: { boolean } = {}
	local xs: { number } = {}
	local x = area.min.X + W.step / 2
	while x <= area.max.X do
		table.insert(xs, x)
		local sample: Rect = { c = Vector2.new(x, W.z), u = Vector2.xAxis, ha = W.step / 2, hc = W.width / 2 }
		table.insert(samples, not host.blocked(sample, WALK, 0))
		x += W.step
	end
	local runs: { { number } } = {}
	local open: number? = nil
	for i, ok in samples do
		if ok and open == nil then
			open = xs[i] - W.step / 2
		end
		local closing = (not ok) or i == #samples
		if closing and open then
			local start = open :: number
			local stop = if ok then xs[i] + W.step / 2 else xs[i] - W.step / 2
			-- A part may be at most 2,048 long.
			local pieces = math.ceil((stop - start) / 2000)
			for j = 1, pieces do
				table.insert(runs, { start + (stop - start) * (j - 1) / pieces, start + (stop - start) * j / pieces })
			end
			open = nil
		end
	end
	for k, span in runs do
		if span[2] - span[1] < 12 then
			continue
		end
		local cx = (span[1] + span[2]) / 2
		local half = (span[2] - span[1]) / 2
		local frame = CFrame.new(cx, host.groundAt(cx, W.z), W.z)
		local m = Piece.model(`ParkWalk{k}`, frame, host.seed)
		local slab =
			Kit.detail(m, "", Vector3.new(-half, -0.3, -W.width / 2), Vector3.new(half, W.top, W.width / 2), terrazzo())
		slab.materialVariant = PARK.paving.variant
		local rect: Rect = { c = Vector2.new(cx, W.z), u = Vector2.xAxis, ha = half, hc = W.width / 2 }
		if put(ctx, { rect }, NOTHING, m.specs, "parkPath") then
			table.insert(ctx.walk, span)
		end
	end

	-- The crossing: paint on the road (Config/CityScenery crosswalks' stripes), a hair over its lane lines.
	local image = CROSS.image
	if image == nil then
		return
	end
	for _, street in host.streets do
		if (street.kind ~= "street" and street.kind ~= "arterial") or math.abs(street.u.Y) < 0.7 then
			continue
		end
		local along = (W.z - street.a.Y) / street.u.Y
		if along < street.trimFrom + W.crossing or along > street.length - street.trimTo - W.crossing then
			continue
		end
		local px = street.a.X + street.u.X * along
		local edge = street.half + street.sidewalk
		if px < area.min.X or px > area.max.X then
			continue
		end
		if not (walkNear(ctx, px - edge - 30, px - edge) and walkNear(ctx, px + edge, px + edge + 30)) then
			continue
		end
		local slope = (street.surface(along + 1) - street.surface(along - 1)) / 2
		local centre = Vector3.new(px, street.surface(along) + host.lineLift + 0.045, W.z)
		local frame = CFrame.lookAt(centre, centre + Vector3.new(street.u.X, slope, street.u.Y))
		local width = 2 * street.half - 2 * CROSS.inset
		local size = Vector3.new(width, 0.05, W.crossing)
		if CROSS.turn then
			frame = frame * CFrame.Angles(0, QUARTER, 0)
			size = Vector3.new(W.crossing, 0.05, width)
		end
		local spec: PartSpec = {
			folder = "",
			name = nameOf(ctx, "ParkCrossing"),
			class = "Part",
			shape = "block",
			role = "line",
			size = size,
			cframe = frame,
			color = CROSS.color,
			material = Enum.Material.SmoothPlastic,
			collide = false,
			query = false,
			touch = false,
			shadow = false,
			transparency = 1,
			textures = {
				{ face = Enum.NormalId.Top, image = image, u = CROSS.tile, v = CROSS.tile, color = CROSS.color },
			},
		}
		-- Reserved as scenery, so the parked cars planned after the park keep off it.
		local rect: Rect = { c = Vector2.new(px, W.z), u = street.u, ha = W.crossing / 2, hc = street.half }
		put(ctx, { rect }, NOTHING, { spec }, "streetscape")
	end
end

-- The promenade's royal palms down both sides (staggered), its lamps on the bay edge and benches facing the bay.
local function promenadeDressing(ctx: Ctx)
	local W = PARK.promenade
	local host = ctx.host
	local area = PARK.area
	local P = W.palms
	for row, side in { -1, 1 } do
		local z = W.z + side * (W.width / 2 + P.setback)
		local rng = Random.new(host.seed * 41 + row * 7)
		local px = area.min.X + P.spacing / 2 + (if side > 0 then P.spacing / 2 else 0)
		while px <= area.max.X - 8 do
			placePalm(ctx, Vector2.new(px, z), P.species, rolls(rng), P.scale)
			px += P.spacing
		end
	end
	local function onWalk(at: number): boolean
		for _, span in ctx.walk do
			if at > span[1] + 4 and at < span[2] - 4 then
				return true
			end
		end
		return false
	end
	local lx = area.min.X + W.lampEvery / 2
	while lx < area.max.X do
		if onWalk(lx) then
			placeLamp(ctx, Vector2.new(lx, W.z + W.width / 2 - 0.9))
		end
		lx += W.lampEvery
	end
	local bx = area.min.X + W.benchEvery
	local bz = W.z - W.width / 2 + 1.6
	while bx < area.max.X do
		if onWalk(bx) then
			-- On the walk's land edge, facing south over the bay.
			local foot = CFrame.new(bx, host.groundAt(bx, bz) + W.top, bz) * CFrame.Angles(0, math.pi, 0)
			placeProp(ctx, "ParkBench", "ParkBench", foot)
		end
		bx += W.benchEvery
	end
end

---------------------------------------------------------------------------------------------------------------
-- Paths, groves, bollards, shrubs
---------------------------------------------------------------------------------------------------------------

-- A smooth curve through `points` (a Catmull-Rom spline, its ends held), as points about `step` apart.
function BayfrontPark.curve(points: { Vector2 }, step: number): { Vector2 }
	local out: { Vector2 } = { points[1] }
	for i = 1, #points - 1 do
		local p0 = points[math.max(i - 1, 1)]
		local p1, p2 = points[i], points[i + 1]
		local p3 = points[math.min(i + 2, #points)]
		local n = math.max(1, math.ceil((p2 - p1).Magnitude / step))
		for k = 1, n do
			local t = k / n
			local t2, t3 = t * t, t * t * t
			local p = (p1 * 2 + (p2 - p0) * t + (p0 * 2 - p1 * 5 + p2 * 4 - p3) * t2 + (p1 * 3 - p0 - p2 * 3 + p3) * t3)
				* 0.5
			table.insert(out, p)
		end
	end
	return out
end

local function inCircle(ctx: Ctx, p: Vector2): boolean
	for _, circle in ctx.circles do
		if (p - circle.c).Magnitude < circle.r - 1 then
			return true
		end
	end
	return false
end

-- The curving paths: slabs along each route's curve, every other one a hair higher, none inside a round plaza.
local function paths(ctx: Ctx)
	local P = PARK.paths
	local host = ctx.host
	local look = Kit.look(P.color, P.material)
	for r, route in P.routes do
		if #route < 2 then
			continue
		end
		local points = BayfrontPark.curve(route, P.step)
		table.insert(ctx.curves, points)
		for i = 1, #points - 1 do
			local a, b = points[i], points[i + 1]
			local mid = (a + b) / 2
			local length = (b - a).Magnitude
			if length < 0.5 or inCircle(ctx, mid) then
				continue
			end
			local u = (b - a) / length
			local top = P.top + (if (i + r) % 2 == 0 then 0.01 else 0)
			local pos = Vector3.new(mid.X, host.groundAt(mid.X, mid.Y), mid.Y)
			local frame = CFrame.lookAt(pos, pos + Vector3.new(u.X, 0, u.Y))
			local half = length / 2 + P.overlap
			local min, max = Vector3.new(-P.width / 2, -0.3, -half), Vector3.new(P.width / 2, top, half)
			local m = Piece.model(`ParkPath{r}_{i}`, frame, host.seed)
			Kit.detail(m, "", min, max, look)
			put(ctx, { Piece.rect(frame, min, max) }, PAVING, m.specs, "parkPath")
		end
	end
end

-- The palm groves: each palm's species drawn by weight, leaning any way; shrub spots at each grove's foot.
local function groves(ctx: Ctx)
	local host = ctx.host
	local weights = PARK.groveSpecies
	local total = 0
	for _, entry in weights do
		total += entry.weight
	end
	for g, grove in PARK.groves do
		local rng = Random.new((host.seed * 53 + g * 977) % 2147483647)
		for _ = 1, grove.count do
			local angle, distance = rng:NextNumber() * TAU, grove.radius * math.sqrt(rng:NextNumber())
			local pick = rng:NextNumber() * total
			local draws = rolls(rng)
			local species = weights[#weights].species
			for _, entry in weights do
				pick -= entry.weight
				if pick < 0 then
					species = entry.species
					break
				end
			end
			placePalm(ctx, grove.at + dir(angle) * distance, species, draws)
		end
		for _ = 1, grove.shrubs do
			local angle, distance = rng:NextNumber() * TAU, grove.radius * 0.7 * math.sqrt(rng:NextNumber())
			table.insert(ctx.shrubs, grove.at + dir(angle) * distance)
		end
	end
end

-- Lit bollards beside the paths, every `every` studs along each, alternating sides.
local function bollards(ctx: Ctx)
	local B = PARK.bollard
	local offset = PARK.paths.width / 2 + B.offset
	local side = 1
	for _, points in ctx.curves do
		local travelled = 0
		local nextAt = B.every / 2
		for i = 1, #points - 1 do
			local a, b = points[i], points[i + 1]
			local length = (b - a).Magnitude
			if length < 1e-6 then
				continue
			end
			local u = (b - a) / length
			local normal = Vector2.new(-u.Y, u.X)
			while nextAt <= travelled + length do
				local p = a + u * (nextAt - travelled)
				if not inCircle(ctx, p) then
					placeBollard(ctx, p + normal * (side * offset))
					side = -side
				end
				nextAt += B.every
			end
			travelled += length
		end
	end
end

local function shrubs(ctx: Ctx)
	local rng = Random.new(ctx.host.seed * 61 + 13)
	for _, at in ctx.shrubs do
		placeShrub(ctx, at, rng)
	end
end

-- The open lawn left over, kept from the random trees (reserved in squares as scenery, which trees keep clear of).
local function fence(ctx: Ctx)
	local host = ctx.host
	local area = PARK.area
	local cell = PARK.fenceCell
	local nx = math.ceil((area.max.X - area.min.X) / cell)
	local nz = math.ceil((area.max.Y - area.min.Y) / cell)
	for i = 0, nx - 1 do
		for j = 0, nz - 1 do
			local x0, z0 = area.min.X + i * cell, area.min.Y + j * cell
			local x1, z1 = math.min(x0 + cell, area.max.X), math.min(z0 + cell, area.max.Y)
			local rect: Rect = {
				c = Vector2.new((x0 + x1) / 2, (z0 + z1) / 2),
				u = Vector2.xAxis,
				ha = (x1 - x0) / 2,
				hc = (z1 - z0) / 2,
			}
			if not host.blocked(rect, OPEN, 0) then
				host.reserve(rect, "streetscape")
			end
		end
	end
end

-- Dresses the park into `host`, most important first, within Config/CityScenery bayfrontPark.budget: the plazas and
-- their props, the promenade, its palms, lamps and benches, the paths, the groves, the bollards, the shrubs. Then keeps
-- its open lawn from the random trees. Returns the parts added.
function BayfrontPark.plan(host: Host): number
	local ctx: Ctx = {
		host = host,
		ledger = { used = 0, limit = PARK.budget },
		added = 0,
		counts = {},
		shrubs = {},
		circles = {},
		walk = {},
		curves = {},
	}
	fountain(ctx)
	amphitheatre(ctx)
	foodTrucks(ctx)
	promenade(ctx)
	sculptures(ctx)
	playground(ctx)
	promenadeDressing(ctx)
	paths(ctx)
	groves(ctx)
	bollards(ctx)
	shrubs(ctx)
	fence(ctx)
	return ctx.added
end

return BayfrontPark
