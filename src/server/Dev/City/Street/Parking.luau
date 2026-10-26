--!strict
-- Parked cars (Config/CityStreet parking; docs/city/SCENERY.md). Pure, like the rest of the plan: it reads the plan as
-- Dev/MapBuilder holds it so far (the sites, their parts, the placement grid through the scenery Host) and adds
-- PartSpecs. Edit-mode only (CLAUDE.md hard rule 9). Every car is two parts:
--   Car<x>_<z>     the space the car fills, carrying a template (Dev/MapTypes TemplateSpec): the build clones
--                  ServerStorage.CityAssets.Cars.<shape>_<colour> there (Parking.instantiate), at its own proportions
--                  inside the shape's box (Parking.sizeOf, Config/CityStreet parking.templateSizes). While no
--                  template of that shape is there it puts up a parts-only stand-in instead, marked
--                  with standInAttribute, and Dev/MapCheck fails (as it does for the palms): the budgets count two
--                  parts a car
--   Car<x>_<z>Box  the invisible solid box a car or a player bumps into (the mesh itself collides with nothing)
--
-- Where cars park (Parking.plan, most important first, within budget.planParts):
--   drop-offs  a car pulled up along the front of a beach-row hotel (its forecourt, under the porte-cochère when there
--              is one), nose the way traffic runs on that side, and on any round drop-off drive (a disc named "Drive")
--   car parks  nose-in along the building in a feature's "CarPark" apron (the diner), the way to its door kept clear
--   drives     a site's "Drive" (the suburb villas): nose to the garage or backed in, as deep as the house allows
--   kerbs      along quiet streets only where the shoulder outside the lanes holds a whole car (none today)
-- Parking.fillStalls fills the striped stalls the lot pass hands over. The dealership's and the used lot's spaces are
-- all sale or spawn pads, so no car ever stands there.
--
-- Every car keeps Config/CityStreet clearance from every part of its site (it stands only on flat paving, under a
-- canopy at most) and, through the grid, off every road, sidewalk, driveway cut, pad, gameplay spot and its way to the
-- road, streetlight, palm and piece of scenery; it reserves its own footprint ("streetscape") so later scenery and the
-- trees keep off it. Nothing it adds stands in a lane, so the traffic pods' routes stay clear.
--
-- The template's contract (for whoever makes the meshes in Studio): a MeshPart (or a Model) in
-- ServerStorage.CityAssets.Cars named <shape>_<colour> (Config/CityStreet parking.order and colours), or in a folder
-- <shape>; upright, its nose along its -Z (or along +X when it is longer in X; parking.templateTurn turns them all).
-- Any size: the build scales it into the shape's box and stands its bottom on the ground; measure a new or remade one
-- into parking.templateSizes so its solid box fits it. A missing colour falls back to the next one of that shape that
-- is there.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local City = require(ReplicatedStorage.Shared.Config.City)
local CityStreet = require(ReplicatedStorage.Shared.Config.CityStreet)
local RoadGraph = require(ReplicatedStorage.Shared.Config.RoadGraph)
local CityTypes = require(script.Parent.Parent.Types)
local Kit = require(script.Parent.Parent.Kit)
local Piece = require(script.Parent.Parent.Scenery.Piece)
local Types = require(script.Parent.Parent.Scenery.Types)

type PartSpec = Types.PartSpec
type Role = Types.Role
type TemplateSpec = Types.TemplateSpec
type Host = Types.Host
type Rect = Types.Rect
type Ledger = Types.Ledger
type Site = CityTypes.Site
type CarShape = CityStreet.CarShape
type Mix = CityStreet.Mix

local PARKING = CityStreet.parking
local SHAPES = PARKING.shapes
local COLOURS = PARKING.colours
local CLEAR = PARKING.clearance
local DROP = PARKING.dropOff
local DRIVES = PARKING.drives
local PARKS = PARKING.carParks
local CURB = PARKING.curb
local STALLS = PARKING.stalls
local QUARTER = math.pi / 2
local EPS = 1e-6

-- Salts for each kind of place's random streams, so two never share numbers.
local SALT = { dropOff = 11, carPark = 23, drive = 37, curb = 41, stall = 53 }

-- What a car in a site (a drive, a forecourt) keeps off in the placement grid. Its own plot is a "lot", so lots
-- don't count.
local SITE_BLOCKERS: { [string]: boolean } = {
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
	ramp = true,
	mesa = true,
	lake = true,
	park = true,
	tree = true,
	streetscape = true,
}
-- ...in a feature's car park (which is the feature's own ground)...
local CAR_PARK_BLOCKERS: { [string]: boolean } = {}
for kind in SITE_BLOCKERS do
	if kind ~= "feature" then
		CAR_PARK_BLOCKERS[kind] = true
	end
end
-- ...at the kerb (on the road's shoulder: the road itself and the lamps' arms over it don't count, the junctions are
-- kept clear by distance)...
local CURB_BLOCKERS: { [string]: boolean } = {
	driveway = true,
	support = true,
	location = true,
	access = true,
	prop = true,
	light = true,
	landmark = true,
	feature = true,
	ramp = true,
	mesa = true,
	lake = true,
	tree = true,
	streetscape = true,
}
-- ...and in a lot's stall (the lot pass has its own paint and furniture there).
local STALL_BLOCKERS: { [string]: boolean } = {
	road = true,
	sidewalk = true,
	driveway = true,
	support = true,
	location = true,
	access = true,
	prop = true,
	light = true,
	landmark = true,
	ramp = true,
	mesa = true,
	lake = true,
}

local Parking = {}

-- The attribute a stand-in car's Model carries (Dev/MapCheck fails a map that holds any).
Parking.standInAttribute = "ParkedCarStandIn"
Parking.ROOT = PARKING.root

-- One stall of a surface lot, as the lot pass hands it over: its centre on the paving (y = the paving's top), turned
-- so its LookVector runs from the aisle into the stall (the way a car parked nose-in points); its size (width across,
-- length; default stalls.size); and the container its car goes in (default its ParkedCars tile).
export type Stall = { cframe: CFrame, size: Vector2?, folder: string? }

-- Cars placed, by kind of place, plus `cars` and `parts` in all.
export type Report = { [string]: number }

---------------------------------------------------------------------------------------------------------------
-- Draws
---------------------------------------------------------------------------------------------------------------

-- Integer seed mixing for deterministic per-thing random streams (as Dev/MapBuilder's).
local function mixSeed(seed: number, a: number, b: number): number
	local modulus = 2147483647
	local h = math.floor(seed) % modulus
	h = (h * 16807 + math.floor(a) * 7919 + 13) % modulus
	h = (h * 16807 + math.floor(b) * 104729 + 17) % modulus
	return h
end

-- A random stream for the thing at plan point `p`, so a car's draws never shift when another car comes or goes.
local function streamAt(seed: number, salt: number, p: Vector3): Random
	return Random.new(mixSeed(mixSeed(seed, salt, 0), math.floor(p.X * 4 + 0.5), math.floor(p.Z * 4 + 0.5)))
end

-- The shape `mix` draws for `roll` (0..1), walking parking.order.
function Parking.pick(mix: Mix, roll: number): string?
	local total = 0
	for _, name in PARKING.order do
		total += mix[name] or 0
	end
	if total <= 0 then
		return nil
	end
	local left = roll * total
	local last: string? = nil
	for _, name in PARKING.order do
		local weight = mix[name] or 0
		if weight > 0 then
			last = name
			left -= weight
			if left < 0 then
				return name
			end
		end
	end
	return last
end

-- The shapes to try when `drawn` may not fit: it first, then the mix's shorter ones, longest first.
local function shapesToTry(mix: Mix, drawn: string): { string }
	local length = SHAPES[drawn].size.Z
	local shorter: { string } = {}
	for _, name in PARKING.order do
		local shape = SHAPES[name]
		if name ~= drawn and (mix[name] or 0) > 0 and shape and shape.size.Z < length then
			table.insert(shorter, name)
		end
	end
	table.sort(shorter, function(a: string, b: string): boolean
		local la, lb = SHAPES[a].size.Z, SHAPES[b].size.Z
		if la ~= lb then
			return la > lb
		end
		return a < b
	end)
	table.insert(shorter, 1, drawn)
	return shorter
end

-- The paint (an index into parking.colours) for `roll` (0..1).
function Parking.paint(roll: number): number
	local total = 0
	for _, colour in COLOURS do
		total += colour.weight
	end
	local left = roll * total
	for i, colour in COLOURS do
		left -= colour.weight
		if left < 0 then
			return i
		end
	end
	return #COLOURS
end

-- The size (width, height, length) a template of `native` size is built at inside a space of `box`: scaled evenly
-- until it meets the box, then stretched along its length by at most parking.templateStretch toward the box's length.
-- A template longer in X than in Z has X for its length.
function Parking.fitSize(native: Vector3, box: Vector3): Vector3
	local w, h, l = native.X, native.Y, native.Z
	if w > l then
		w, l = l, w
	end
	if w <= 0 or h <= 0 or l <= 0 then
		return box
	end
	local s = math.min(box.X / w, box.Y / h, box.Z / l)
	local stretch = math.clamp(box.Z / (l * s), 1, PARKING.templateStretch)
	return Vector3.new(w * s, h * s, l * s * stretch)
end

-- The size a car of `shapeName` in paint `colour` is built at: its template's measured size (parking.templateSizes;
-- a missing paint takes the next one's, as Parking.findTemplate does) fit to the shape's box, else the box itself.
function Parking.sizeOf(shapeName: string, colour: number): Vector3
	local box = SHAPES[shapeName].size
	local n = #COLOURS
	local start = math.clamp(colour, 1, n)
	for k = 0, n - 1 do
		local measured = PARKING.templateSizes[`{shapeName}_{COLOURS[(start - 1 + k) % n + 1].name}`]
		if measured then
			return Parking.fitSize(measured, box)
		end
	end
	return box
end

---------------------------------------------------------------------------------------------------------------
-- One car
---------------------------------------------------------------------------------------------------------------

-- The ParkedCars tile a plan point stands in.
function Parking.tilePath(x: number, z: number): string
	return `{PARKING.root}/Tile{math.floor(x / PARKING.tile)}_{math.floor(z / PARKING.tile)}`
end

-- The tile, registered with the host when there is one.
local function tileIn(host: Host?, x: number, z: number): string
	local path = Parking.tilePath(x, z)
	if host then
		host.container(PARKING.root, "Folder")
		host.container(path, "Model", Enum.ModelStreamingMode.Atomic, "SLIM")
	end
	return path
end

local function nameAt(p: Vector3): string
	return `Car{math.round(p.X)}_{math.round(p.Z)}`
end

-- The two parts of one car of `shapeName` in paint `colour` in the space of its shape's box at `pivot` (the box's
-- footprint's middle on the surface it stands on, its LookVector the way the nose points), filed in `folder` as
-- `name`: the space its mesh fills (Parking.sizeOf, carrying the template) and the invisible box a car or a player
-- bumps into. A car shorter than the box stands at its `anchor` end: 1 the nose's, -1 the tail's, 0 (default) the
-- middle.
function Parking.car(
	folder: string,
	name: string,
	space: CFrame,
	shapeName: string,
	colour: number,
	role: Role?,
	anchor: number?
): (PartSpec, PartSpec)
	local shape = SHAPES[shapeName]
	if shape == nil then
		error(`Parking: no car shape {shapeName} in Config/CityStreet parking`, 2)
	end
	local paint = COLOURS[math.clamp(colour, 1, #COLOURS)]
	local size = Parking.sizeOf(shapeName, colour)
	-- The nose is the pivot's -Z end. Each part's frame is one step from `space`, to keep CFrame rounding small.
	local shift = -(anchor or 0) * math.max(0, shape.size.Z - size.Z) / 2
	local pivot = space * CFrame.new(0, 0, shift)
	local root = PARKING.templateRoot
	local body: PartSpec = {
		folder = folder,
		name = name,
		class = "Part",
		shape = "block",
		role = role or "scenery",
		size = size,
		cframe = space * CFrame.new(0, size.Y / 2, shift),
		color = paint.color,
		material = Enum.Material.SmoothPlastic,
		collide = false,
		query = false,
		touch = false,
		shadow = false,
		transparency = 1,
		template = {
			path = { root[1], root[2], `{shapeName}_{paint.name}` },
			pivot = pivot,
			height = size.Y,
			variant = math.clamp(colour, 1, #COLOURS),
			fallback = shapeName,
			seat = true,
		},
	}
	-- Should the build ever hand the spec to the props' path (Dev/City/Scenery Palms.instantiate) instead of
	-- Parking.instantiate, it still stands it by its box and puts up this stand-in.
	local template = body.template :: TemplateSpec
	template.standIn = Parking.fallback(template, folder, name, size)
	local b = PARKING.box
	local tall = size.Y * b.top - b.lift
	local box: PartSpec = {
		folder = folder,
		name = `{name}Box`,
		class = "Part",
		shape = "block",
		role = role or "scenery",
		size = Vector3.new(size.X - 2 * b.inset, tall, size.Z - 2 * b.inset),
		cframe = space * CFrame.new(0, b.lift + tall / 2, shift),
		color = paint.color,
		material = Enum.Material.SmoothPlastic,
		collide = true,
		query = true,
		touch = false,
		shadow = false,
		transparency = 1,
	}
	return body, box
end

-- The plan rectangle a car at `pivot` covers, `pad` studs bigger all round.
local function rectOf(pivot: CFrame, shape: CarShape, pad: number): Rect
	local look = Vector2.new(pivot.LookVector.X, pivot.LookVector.Z)
	local u = if look.Magnitude > EPS then look.Unit else Vector2.yAxis
	return { c = Vector2.new(pivot.X, pivot.Z), u = u, ha = shape.size.Z / 2 + pad, hc = shape.size.X / 2 + pad }
end

-- Adds a car in the space of its shape's box at `pivot` (standing at its `anchor` end: Parking.car) when the grid has
-- room for the box (keeping clear of `kinds`) and the ledger has its two parts: its specs, and the box's footprint
-- reserved as scenery. True when it did.
local function place(
	host: Host,
	ledger: Ledger,
	pivot: CFrame,
	shapeName: string,
	colour: number,
	kinds: { [string]: boolean },
	anchor: number?
): boolean
	local shape = SHAPES[shapeName]
	if host.blocked(rectOf(pivot, shape, CLEAR), kinds, 0) then
		return false
	end
	if not Piece.take(ledger, 2) then
		return false
	end
	local at = pivot.Position
	local body, box = Parking.car(tileIn(host, at.X, at.Z), nameAt(at), pivot, shapeName, colour, nil, anchor)
	host.add(body)
	host.add(box)
	host.reserve(rectOf(pivot, shape, 0), "streetscape")
	return true
end

---------------------------------------------------------------------------------------------------------------
-- Room in a frame: the boxes of what stands round a spot, and where a car can stand among them
---------------------------------------------------------------------------------------------------------------

-- A part's box in a frame's own coordinates; `floor` when it is flat paving a car may stand on.
type Box = { lo: Vector3, hi: Vector3, floor: boolean }

-- Paving: no higher than `floorTop`, not a light or a template's box, and either opaque and not glass (water is
-- glass), or wholly see-through with paint on it (lines and patterns laid on the paving).
local function isFloor(spec: PartSpec, hi: Vector3, floorTop: number): boolean
	if hi.Y > floorTop or spec.tag ~= nil or spec.template ~= nil then
		return false
	end
	if spec.transparency == 0 then
		return spec.material ~= Enum.Material.Glass
	end
	local paint = spec.textures
	return spec.transparency >= 1 and paint ~= nil and #paint > 0
end

-- The boxes of `list` in `frame`, keeping those that reach into x0..x1, z0..z1; paving up to `floorTop` (default
-- parking.floorTop) is floor.
local function boxesOf(
	frame: CFrame,
	list: { PartSpec },
	x0: number,
	x1: number,
	z0: number,
	z1: number,
	floorTop: number?
): { Box }
	local top = floorTop or PARKING.floorTop
	local out: { Box } = {}
	for _, spec in list do
		local lo, hi = Kit.localBounds(frame, spec)
		if hi.X >= x0 and lo.X <= x1 and hi.Z >= z0 and lo.Z <= z1 then
			table.insert(out, { lo = lo, hi = hi, floor = isFloor(spec, hi, top) })
		end
	end
	return out
end

-- The height (in the frame) a car `hx` by `hz` (half sizes along the frame's x and z) and `tall` high stands at with
-- its middle at (x, z): on the highest paving under it (wholly on it when that is higher than flatStep), clear by
-- `clearance` of everything else that stands between that and `headroom` over its roof. Nil when it doesn't fit.
local function standAt(boxes: { Box }, x: number, z: number, hx: number, hz: number, tall: number): number?
	local base = PARKING.groundLift
	local top: Box? = nil
	for _, b in boxes do
		if
			b.floor
			and b.hi.Y > base
			and b.lo.X < x + hx
			and b.hi.X > x - hx
			and b.lo.Z < z + hz
			and b.hi.Z > z - hz
		then
			base = b.hi.Y
			top = b
		end
	end
	if top and base > PARKING.flatStep then
		local under = top :: Box
		if under.lo.X > x - hx or under.hi.X < x + hx or under.lo.Z > z - hz or under.hi.Z < z + hz then
			return nil
		end
	end
	local roof = base + tall + PARKING.headroom
	for _, b in boxes do
		if
			not b.floor
			and b.hi.Y > base + 0.05
			and b.lo.Y < roof
			and b.lo.X < x + hx + CLEAR
			and b.hi.X > x - hx - CLEAR
			and b.lo.Z < z + hz + CLEAR
			and b.hi.Z > z - hz - CLEAR
		then
			return nil
		end
	end
	return base
end

-- The box a car placed at (x, z) now fills, so the next one keeps clear of it.
local function carBox(x: number, z: number, hx: number, hz: number, base: number, tall: number): Box
	return { lo = Vector3.new(x - hx, base, z - hz), hi = Vector3.new(x + hx, base + tall, z + hz), floor = false }
end

-- Whether something over (x, z) is a canopy for a car whose roof (and headroom) reaches `above`.
local function covered(boxes: { Box }, x: number, z: number, above: number): boolean
	for _, b in boxes do
		if
			not b.floor
			and b.lo.Y >= above
			and b.lo.Y <= DROP.canopyTop
			and b.lo.X <= x
			and b.hi.X >= x
			and b.lo.Z <= z
			and b.hi.Z >= z
		then
			return true
		end
	end
	return false
end

-- Pulls a car of `shapeName` up sideways (along the frame's x, nose toward +x: on a road's side of the frame's -z,
-- that is the way the near lane's traffic runs) somewhere with its middle in x0..x1, z0..z1: under a canopy first, then
-- nearest `prefer`. Adds it and returns its box, or nil when nowhere fits.
local function pullUp(
	host: Host,
	ledger: Ledger,
	frame: CFrame,
	boxes: { Box },
	x0: number,
	x1: number,
	z0: number,
	z1: number,
	prefer: Vector2,
	shapeName: string,
	colour: number
): Box?
	local size = SHAPES[shapeName].size
	local hx, hz, tall = size.Z / 2, size.X / 2, size.Y
	x0, x1, z0, z1 = x0 + hx, x1 - hx, z0 + hz, z1 - hz
	if x1 < x0 or z1 < z0 then
		return nil
	end
	local above = PARKING.groundLift + tall + PARKING.headroom
	local spots: { { x: number, z: number, score: number } } = {}
	local stepX, stepZ = DROP.step, DROP.step / 2
	local nx, nz = math.floor((x1 - x0) / stepX + EPS), math.floor((z1 - z0) / stepZ + EPS)
	for i = 0, nx do
		local x = x0 + i * stepX
		for j = 0, nz do
			local z = z0 + j * stepZ
			local score = math.abs(x - prefer.X) + 0.5 * math.abs(z - prefer.Y)
			if not covered(boxes, x, z, above) then
				score += 1e6
			end
			table.insert(spots, { x = x, z = z, score = score })
		end
	end
	table.sort(spots, function(a, b): boolean
		if a.score ~= b.score then
			return a.score < b.score
		end
		if a.x ~= b.x then
			return a.x < b.x
		end
		return a.z < b.z
	end)
	for _, spot in spots do
		local base = standAt(boxes, spot.x, spot.z, hx, hz, tall)
		if base then
			local pivot = frame * CFrame.new(spot.x, base, spot.z) * CFrame.Angles(0, -QUARTER, 0)
			if place(host, ledger, pivot, shapeName, colour, SITE_BLOCKERS) then
				return carBox(spot.x, spot.z, hx, hz, base, tall)
			end
		end
	end
	return nil
end

---------------------------------------------------------------------------------------------------------------
-- The plan's parts, by site
---------------------------------------------------------------------------------------------------------------

type Index = {
	byFolder: { [string]: { PartSpec } },
	skyline: { [string]: { PartSpec } }, -- a tower's main masses in the Skyline model, by its site's id
}

local function index(specs: { PartSpec }): Index
	local byFolder: { [string]: { PartSpec } } = {}
	local skyline: { [string]: { PartSpec } } = {}
	local skylineFolder = City.skyline.folder
	for _, spec in specs do
		local folder = spec.folder
		if folder == skylineFolder then
			local id = string.match(spec.name, "^(B%d+)")
			if id then
				local list = skyline[id]
				if list == nil then
					list = {}
					skyline[id] = list
				end
				table.insert(list, spec)
			end
		elseif
			string.sub(folder, 1, 10) == "Buildings/"
			or string.sub(folder, 1, 15) == "BuildingLights/"
			or string.sub(folder, 1, 9) == "Features/"
		then
			local list = byFolder[folder]
			if list == nil then
				list = {}
				byFolder[folder] = list
			end
			table.insert(list, spec)
		end
	end
	return { byFolder = byFolder, skyline = skyline }
end

-- Every part of a site: its model's, its lights model's, and its masses in the Skyline model.
local function partsOf(ix: Index, site: Site): { PartSpec }
	local list: { PartSpec } = {}
	for _, folder in { site.folder, site.lightsFolder } do
		local own = ix.byFolder[folder]
		if own then
			table.move(own, 1, #own, #list + 1, list)
		end
	end
	local masses = ix.skyline[site.id]
	if masses then
		table.move(masses, 1, #masses, #list + 1, list)
	end
	return list
end

-- The site's drives (parts named <id>Drive): `round` when the drive is a disc (a drop-off under a canopy).
local function drivesOf(ix: Index, site: Site): { { spec: PartSpec, round: boolean } }
	local found: { { spec: PartSpec, round: boolean } } = {}
	local wanted = `{site.id}Drive`
	local own: { PartSpec } = ix.byFolder[site.folder] or {}
	for _, spec in own do
		if spec.name == wanted then
			table.insert(found, { spec = spec, round = spec.shape == "cylinder" })
		end
	end
	return found
end

---------------------------------------------------------------------------------------------------------------
-- The passes
---------------------------------------------------------------------------------------------------------------

-- Drop-off bays: the beach row's hotels, and every round drop-off drive.
local function dropOffs(host: Host, ledger: Ledger, ix: Index, sites: { Site }): number
	local placed = 0
	local mix = PARKING.mixes.hotel
	for _, site in sites do
		local hotel = DROP.zones[site.zone] == true and DROP.archetypes[site.archetype] == true and site.face == "road"
		local rounds: { PartSpec } = {}
		for _, drive in drivesOf(ix, site) do
			if drive.round then
				table.insert(rounds, drive.spec)
			end
		end
		if not hotel and #rounds == 0 then
			continue
		end
		local frame = site.frame
		local hw, hd = site.width / 2, site.depth / 2
		local parts = partsOf(ix, site)
		local rng = Random.new(mixSeed(site.seed, SALT.dropOff, 1))
		local take, second = rng:NextNumber(), rng:NextNumber()
		local shapes = { Parking.pick(mix, rng:NextNumber()), Parking.pick(mix, rng:NextNumber()) }
		local paints = { Parking.paint(rng:NextNumber()), Parking.paint(rng:NextNumber()) }
		if take >= DROP.share then
			continue
		end
		if hotel then
			local front = -hd
			local x0, x1 = -hw + DROP.margin, hw - DROP.margin
			local z0, z1 = front - DROP.overhang, front + DROP.depth
			local boxes = boxesOf(frame, parts, x0 - 2, x1 + 2, z0 - 2, z1 + 2)
			local wanted = if site.width >= DROP.second.width and second < DROP.second.share then 2 else 1
			for k = 1, wanted do
				local shapeName = shapes[k]
				if shapeName == nil then
					break
				end
				local colour = paints[k]
				if k == 2 and paints[1] == colour then
					colour = colour % #COLOURS + 1
				end
				local made = pullUp(host, ledger, frame, boxes, x0, x1, z0, z1, Vector2.new(0, z0), shapeName, colour)
				if made == nil then
					break
				end
				table.insert(boxes, made)
				placed += 1
			end
		end
		for k, disc in rounds do
			local shapeName = shapes[1]
			if shapeName == nil then
				break
			end
			local lo, hi = Kit.localBounds(frame, disc)
			local c = (lo + hi) / 2
			local r = math.max(hi.X - lo.X, hi.Z - lo.Z) / 2
			local reach = SHAPES[shapeName].size.Z
			-- The disc may stand on a raised lawn or plinth: whatever is no higher than it is paving here.
			local floorTop = math.max(PARKING.floorTop, hi.Y + 0.01)
			local boxes =
				boxesOf(frame, parts, c.X - r - reach, c.X + r + reach, c.Z - r - reach, c.Z + r + reach, floorTop)
			-- The middle of the car anywhere within half the disc's radius of its middle (plus the car's own size).
			local size = SHAPES[shapeName].size
			local x0, x1 = c.X - r / 2 - size.Z / 2, c.X + r / 2 + size.Z / 2
			local z0, z1 = c.Z - r / 2 - size.X / 2, c.Z + r / 2 + size.X / 2
			local colour = (paints[1] + k - 2) % #COLOURS + 1
			if pullUp(host, ledger, frame, boxes, x0, x1, z0, z1, Vector2.new(c.X, c.Z), shapeName, colour) then
				placed += 1
			end
		end
	end
	return placed
end

-- Feature car parks (the diner's apron): a row of nose-in spaces along the building.
local function carParks(host: Host, ledger: Ledger, ix: Index, specs: { PartSpec }): number
	local placed = 0
	local mix = PARKING.mixes.carPark
	for _, apron in specs do
		if apron.role ~= "feature" or not PARKS.names[apron.name] then
			continue
		end
		local frame = apron.cframe * CFrame.new(0, -apron.size.Y / 2, 0)
		local hw, hd = apron.size.X / 2, apron.size.Z / 2
		local own: { PartSpec } = ix.byFolder[apron.folder] or {}
		local boxes = boxesOf(frame, own, -hw - 2, hw + 2, -hd - 2, hd + 30)
		-- The way to every door stays clear: its box grown out toward the apron and to either side.
		local gap = PARKS.doorGap
		for _, spec in own do
			if string.sub(spec.name, -4) == "Door" then
				local lo, hi = Kit.localBounds(frame, spec)
				local grown = { lo = lo - Vector3.new(gap, 0, gap), hi = hi + Vector3.new(gap, 0, 0), floor = false }
				grown.lo = Vector3.new(grown.lo.X, 0, grown.lo.Z)
				grown.hi = Vector3.new(grown.hi.X, math.max(grown.hi.Y, 8), grown.hi.Z)
				table.insert(boxes, grown)
			end
		end
		local run = 2 * hw - 2 * PARKS.margin
		local count = math.floor(run / PARKS.pitch + EPS)
		local first = -hw + PARKS.margin + (run - count * PARKS.pitch) / 2 + PARKS.pitch / 2
		local lastPaint: number? = nil
		for i = 1, count do
			local x = first + (i - 1) * PARKS.pitch
			local rng = streamAt(host.seed, SALT.carPark, frame * Vector3.new(x, 0, 0))
			local take, shapeRoll, paintRoll = rng:NextNumber(), rng:NextNumber(), rng:NextNumber()
			if take >= PARKS.share then
				lastPaint = nil
				continue
			end
			local shapeName = Parking.pick(mix, shapeRoll)
			if shapeName == nil then
				break
			end
			local colour = Parking.paint(paintRoll)
			if colour == lastPaint then
				colour = colour % #COLOURS + 1
			end
			local size = SHAPES[shapeName].size
			local hx, hz = size.X / 2, size.Z / 2
			-- Nose in as far as the building lets it, sliding back toward the road until it fits (at most `slide`
			-- studs out of line with the row, else the space stays empty).
			local z = hd - hz
			local bottom = math.max(-hd + hz, z - PARKS.slide)
			local done = false
			while z >= bottom - EPS and not done do
				local base = standAt(boxes, x, z, hx, hz, size.Y)
				if base then
					local pivot = frame * CFrame.new(x, base, z) * CFrame.Angles(0, math.pi, 0)
					if place(host, ledger, pivot, shapeName, colour, CAR_PARK_BLOCKERS, 1) then
						table.insert(boxes, carBox(x, z, hx, hz, base, size.Y))
						placed += 1
						lastPaint = colour
					end
					done = true
				end
				z -= 0.5
			end
		end
	end
	return placed
end

-- Driveways: a car on a site's drive, nose to the garage (or backed in), as deep as the house allows.
local function drives(host: Host, ledger: Ledger, ix: Index, sites: { Site }): number
	local placed = 0
	local mix = PARKING.mixes.drive
	for _, site in sites do
		local frame = site.frame
		for k, drive in drivesOf(ix, site) do
			if drive.round then
				continue
			end
			local lo, hi = Kit.localBounds(frame, drive.spec)
			if hi.Z - lo.Z < hi.X - lo.X then
				continue -- not a drive in from the street
			end
			local rng = Random.new(mixSeed(site.seed, SALT.drive, k))
			local take, noseOut, shapeRoll, paintRoll =
				rng:NextNumber(), rng:NextNumber(), rng:NextNumber(), rng:NextNumber()
			local drawn = Parking.pick(mix, shapeRoll)
			if take >= DRIVES.share or drawn == nil then
				continue
			end
			local colour = Parking.paint(paintRoll)
			local yaw = if noseOut < DRIVES.noseOut then 0 else math.pi
			local x = (lo.X + hi.X) / 2
			local width = hi.X - lo.X
			local back = math.min(hi.Z + DRIVES.beyond, site.depth / 2 - CLEAR)
			local boxes = boxesOf(frame, partsOf(ix, site), x - 6, x + 6, lo.Z - 3, back + 3)
			local done = false
			for _, shapeName in shapesToTry(mix, drawn) do
				local size = SHAPES[shapeName].size
				if size.X > width + 1 then
					continue
				end
				local hx, hz = size.X / 2, size.Z / 2
				local z = back - hz
				local bottom = lo.Z - DRIVES.overhang + hz
				while z >= bottom - EPS do
					local base = standAt(boxes, x, z, hx, hz, size.Y)
					if base then
						local pivot = frame * CFrame.new(x, base, z) * CFrame.Angles(0, yaw, 0)
						-- The garage is the drive's far (+z) end: nosed to it (yaw pi) the nose stands there, backed in
						-- the tail does.
						local anchor = if yaw == 0 then -1 else 1
						if place(host, ledger, pivot, shapeName, colour, SITE_BLOCKERS, anchor) then
							placed += 1
							done = true
							break
						end
					end
					z -= DRIVES.step
				end
				if done then
					break
				end
			end
		end
	end
	return placed
end

-- How wide a strip a road of `kind` has outside its outermost lane (studs): the most room a car at its kerb has
-- without standing in a lane.
function Parking.curbRoom(kind: string): number
	local style = (RoadGraph.styles :: any)[kind]
	return if style then style.shoulder else 0
end

-- Kerbside cars, only where the shoulder holds a whole car with its lane left clear.
local function kerbs(host: Host, ledger: Ledger): number
	local placed = 0
	local mix = PARKING.mixes.curb
	for _, street in host.streets do
		if not CURB.kinds[street.kind] then
			continue
		end
		local room = Parking.curbRoom(street.kind)
		local from = street.trimFrom + CURB.junction
		local to = street.length - street.trimTo - CURB.junction
		local along = from + CURB.spacing / 2
		local k = 0
		while along <= to do
			for _, side in { 1, -1 } do
				k += 1
				local rng = Random.new(mixSeed(host.seed, SALT.curb, street.id * 4096 + k))
				local take, shapeRoll, paintRoll = rng:NextNumber(), rng:NextNumber(), rng:NextNumber()
				local shapeName = Parking.pick(mix, shapeRoll)
				if take >= CURB.share or shapeName == nil then
					continue
				end
				local size = SHAPES[shapeName].size
				-- The lane stays wholly clear: the car and its gap to the kerb fit in the shoulder.
				if size.X + CURB.kerbGap > room then
					continue
				end
				local lateral = street.half - CURB.kerbGap - size.X / 2
				local p = street.a + street.u * along + street.l * (side * lateral)
				local y = street.surface(along)
				-- Traffic keeps right: a car on the +l side faces along +u.
				local way = street.u * side
				local at = Vector3.new(p.X, y, p.Y)
				local pivot = CFrame.lookAt(at, at + Vector3.new(way.X, 0, way.Y))
				if place(host, ledger, pivot, shapeName, Parking.paint(paintRoll), CURB_BLOCKERS) then
					placed += 1
				end
			end
			along += CURB.spacing
		end
	end
	return placed
end

-- The stalls each site's archetype lists (a lot archetype's stalls(site): Dev/City/Archetypes/lots), in site order.
local function stallsOf(sites: { Site }): { { site: Site, stalls: { Stall } } }
	-- Required here, not at the top: the archetypes load the kit and the props, which may come to need the scenery.
	local archetypes = (require :: any)(script.Parent.Parent.Archetypes.Index)
	local found: { { site: Site, stalls: { Stall } } } = {}
	for _, site in sites do
		local archetype = archetypes.byId[site.archetype]
		local list = if archetype then archetype.stalls else nil
		if type(list) == "function" then
			table.insert(found, { site = site, stalls = list(site) })
		end
	end
	return found
end

-- The box (in `frame`'s coordinates) a car's solid box fills when the car stands at `pivot`.
local function solidIn(frame: CFrame, pivot: CFrame, shape: CarShape): (Vector3, Vector3)
	local b = PARKING.box
	local size = shape.size
	local tall = size.Y * b.top - b.lift
	local half = Vector3.new(size.X / 2 - b.inset, tall / 2, size.Z / 2 - b.inset)
	local centre = frame:ToObjectSpace(pivot * CFrame.new(0, b.lift + tall / 2, 0))
	local lo, hi = Vector3.one * math.huge, -Vector3.one * math.huge
	for _, sx in { -1, 1 } do
		for _, sy in { -1, 1 } do
			for _, sz in { -1, 1 } do
				local p = centre * Vector3.new(sx * half.X, sy * half.Y, sz * half.Z)
				lo, hi = lo:Min(p), hi:Max(p)
			end
		end
	end
	return lo, hi
end

-- Cars in the surface lots' stalls, within budget.lotParts: every lot takes the same share (stalls.share, lowered for
-- all when that would pass the budget), and a car whose solid box would meet a part of its lot (a lamp's pole, the
-- booth, the hedge: anything but the paving, its paint and the wheel stops under it) is left out. Adds them to `host`
-- and returns the parts added.
local function lotsPass(host: Host, ix: Index, sites: { Site }): number
	local lots = stallsOf(sites)
	local total = 0
	for _, lot in lots do
		total += #lot.stalls
	end
	if total == 0 then
		return 0
	end
	local ledger: Ledger = { used = 0, limit = PARKING.budget.lotParts }
	local share = math.min(STALLS.share, ledger.limit / 2 / total)
	local tolerance = 0.05
	for _, lot in lots do
		local frame = lot.site.frame
		local boxes: { Box } = {}
		for _, spec in partsOf(ix, lot.site) do
			local lo, hi = Kit.localBounds(frame, spec)
			table.insert(boxes, { lo = lo, hi = hi, floor = false })
		end
		local options: StallOptions = {
			host = host,
			ledger = ledger,
			share = share,
			fits = function(pivot: CFrame, shapeName: string): boolean
				local lo, hi = solidIn(frame, pivot, SHAPES[shapeName])
				for _, b in boxes do
					if
						b.lo.X < hi.X - tolerance
						and b.hi.X > lo.X + tolerance
						and b.lo.Y < hi.Y - tolerance
						and b.hi.Y > lo.Y + tolerance
						and b.lo.Z < hi.Z - tolerance
						and b.hi.Z > lo.Z + tolerance
					then
						return false
					end
				end
				return true
			end,
		}
		for _, spec in Parking.fillStalls(lot.stalls, lot.site.seed, options) do
			host.add(spec)
		end
	end
	return ledger.used
end

---------------------------------------------------------------------------------------------------------------
-- The plan
---------------------------------------------------------------------------------------------------------------

-- Places the parked cars into `host` (Dev/MapBuilder's scenery host): `sites` are the city's sites built so far and
-- `specs` every part planned so far (read, never changed). Returns the cars by kind of place (dropOffs, carParks,
-- drives, kerbs, lots), `cars` and `parts`.
function Parking.plan(host: Host, sites: { Site }, specs: { PartSpec }): Report
	local ledger: Ledger = { used = 0, limit = PARKING.budget.planParts }
	local ix = index(specs)
	local report: Report = {}
	report.dropOffs = dropOffs(host, ledger, ix, sites)
	report.carParks = carParks(host, ledger, ix, specs)
	report.drives = drives(host, ledger, ix, sites)
	report.kerbs = kerbs(host, ledger)
	local lotParts = lotsPass(host, ix, sites)
	report.lots = lotParts // 2
	report.cars = report.dropOffs + report.carParks + report.drives + report.kerbs + report.lots
	report.parts = ledger.used + lotParts
	return report
end

-- What a fillStalls caller may add (all optional):
--   host    Dev/MapBuilder's scenery host: the ParkedCars tiles are registered with it, a stall the grid has something
--           in stays empty, and each car's footprint is reserved
--   ledger  caps the parts, shared across calls (default: stalls.budgetParts for this call)
--   folder  the container every car goes in (a lot's own model) instead of its stall's folder or its ParkedCars tile
--   prefix  put before every part's name (a site's id, so the cars pass as the site's parts: Dev/City CityBuilder.check)
--   role    the parts' role (default "scenery"; "building" when they are filed in a site's model)
--   share   the share of stalls taken (default stalls.share)
--   fits    a last say on each car (where it stands, its shape): false leaves its stall empty
export type StallOptions = {
	host: Host?,
	ledger: Ledger?,
	folder: string?,
	prefix: string?,
	role: Role?,
	share: number?,
	fits: ((pivot: CFrame, shapeName: string) -> boolean)?,
}

-- Cars for a lot's striped stalls (the lot pass's): `share` of them taken, each its own shape and paint, nose-in or
-- backed in, aligned to its stall and pulled to its head. Returns the specs; never adds them. A car goes in
-- options.folder, else its stall's folder, else its ParkedCars tile (registered when there is a host; otherwise the
-- caller registers Parking.tilePath's or re-files the specs). Deterministic: a stall's car depends only on `seed` and
-- the stall's position.
function Parking.fillStalls(stalls: { Stall }, seed: number, options: StallOptions?): { PartSpec }
	local given: StallOptions = options or {}
	local host = given.host
	local budget: Ledger = given.ledger or { used = 0, limit = STALLS.budgetParts }
	local out: { PartSpec } = {}
	local mix = PARKING.mixes.lot
	local last: { shape: string, colour: number, at: Vector3 }? = nil
	for _, stall in stalls do
		local size = stall.size or STALLS.size
		local at = stall.cframe.Position
		local rng = streamAt(seed, SALT.stall, at)
		local take, backIn, side, turn = rng:NextNumber(), rng:NextNumber(), rng:NextNumber(), rng:NextNumber()
		local shapeRoll, paintRoll = rng:NextNumber(), rng:NextNumber()
		if take >= (given.share or STALLS.share) then
			continue
		end
		local drawn = Parking.pick(mix, shapeRoll)
		if drawn == nil then
			break
		end
		local shapeName: string? = nil
		for _, name in shapesToTry(mix, drawn) do
			local s = SHAPES[name].size
			if s.Z + STALLS.noseGap <= size.Y and s.X + 2 * CLEAR <= size.X then
				shapeName = name
				break
			end
		end
		if shapeName == nil then
			continue
		end
		local shape = SHAPES[shapeName]
		local colour = Parking.paint(paintRoll)
		-- Neighbours never share a paint (white and silver already read alike from above).
		local prior = last
		if prior and prior.colour == colour and (prior.at - at).Magnitude < 2 * size.X then
			colour = colour % #COLOURS + 1
		end
		-- Pulled to the stall's head (local -Z), set off a little across it and turned a hair.
		local forward = size.Y / 2 - STALLS.noseGap - shape.size.Z / 2
		local slack = math.max(0, (size.X - shape.size.X) / 2 - CLEAR)
		local across = (side * 2 - 1) * math.min(STALLS.jitter.side, slack)
		local yaw = math.rad((turn * 2 - 1) * STALLS.jitter.yaw) + (if backIn < STALLS.noseOut then math.pi else 0)
		local pivot = stall.cframe * CFrame.new(across, 0, -forward) * CFrame.Angles(0, yaw, 0)
		local fits = given.fits
		if fits and not fits(pivot, shapeName) then
			continue
		end
		if host and host.blocked(rectOf(pivot, shape, 0), STALL_BLOCKERS, 0) then
			continue
		end
		if not Piece.take(budget, 2) then
			break
		end
		local folder = given.folder or stall.folder
		if host then
			folder = folder or tileIn(host, pivot.X, pivot.Z)
		end
		local name = (given.prefix or "") .. nameAt(pivot.Position)
		local where = folder or Parking.tilePath(pivot.X, pivot.Z)
		-- Nose (or, backed in, tail) to the stall's head.
		local anchor = if backIn < STALLS.noseOut then -1 else 1
		local body, box = Parking.car(where, name, pivot, shapeName, colour, given.role, anchor)
		table.insert(out, body)
		table.insert(out, box)
		if host then
			host.reserve(rectOf(pivot, shape, 0), "streetscape")
		end
		last = { shape = shapeName, colour = colour, at = at }
	end
	return out
end

---------------------------------------------------------------------------------------------------------------
-- The build: a template's clone, or the stand-in
---------------------------------------------------------------------------------------------------------------

-- Whether a templated spec is a parked car's (Dev/City/Scenery.instantiate hands those here).
function Parking.owns(spec: PartSpec): boolean
	local t = spec.template
	if t == nil then
		return false
	end
	local root = PARKING.templateRoot
	return t.path[1] == root[1] and t.path[2] == root[2]
end

-- The parked cars in `specs` whose middle stands over no parking surface (Config/CityStreet parking.surfaces: a part
-- whose name ends in one of them, a site's drive, a car park apron, a lot's asphalt): their names. Dev/MapCheck fails
-- the map on any (the street-level roast, 2026-10-26: cars stood on forecourts and lawns no car could reach).
function Parking.offSurface(specs: { PartSpec }): { string }
	local surfaces: { PartSpec } = {}
	local cars: { PartSpec } = {}
	for _, spec in specs do
		if Parking.owns(spec) then
			table.insert(cars, spec)
			continue
		end
		for _, suffix in PARKING.surfaces do
			if string.sub(spec.name, -#suffix) == suffix then
				table.insert(surfaces, spec)
				break
			end
		end
	end
	local out: { string } = {}
	for _, car in cars do
		local p = car.cframe.Position
		local on = false
		for _, surface in surfaces do
			local rel = surface.cframe:PointToObjectSpace(p)
			local half = surface.size / 2
			-- Over its footprint, standing on it (the car's middle at most a car's height over its top).
			if
				math.abs(rel.X) <= half.X + EPS
				and math.abs(rel.Z) <= half.Z + EPS
				and rel.Y >= -half.Y - 1
				and rel.Y <= half.Y + 8
			then
				on = true
				break
			end
		end
		if not on then
			table.insert(out, car.name)
		end
	end
	return out
end

local function usable(item: Instance?): boolean
	if item == nil then
		return false
	end
	return item:IsA("BasePart") or item:IsA("Model")
end

-- The template for a car of `shapeName` in paint `colour`: <shape>_<colour> in ServerStorage.CityAssets.Cars (or in
-- its <shape> folder), else the next paint of that shape that is there, else a lone <shape>, else the first of a
-- <shape> folder by name. Nil when that shape has none.
function Parking.findTemplate(shapeName: string, colour: number): Instance?
	local node: Instance? = ServerStorage
	for _, step in PARKING.templateRoot do
		if node == nil then
			return nil
		end
		node = (node :: Instance):FindFirstChild(step)
	end
	if node == nil then
		return nil
	end
	local cars = node :: Instance
	local folder = cars:FindFirstChild(shapeName)
	local n = #COLOURS
	local start = math.clamp(colour, 1, n)
	for k = 0, n - 1 do
		local name = `{shapeName}_{COLOURS[(start - 1 + k) % n + 1].name}`
		local found = cars:FindFirstChild(name)
		if not usable(found) and folder then
			found = folder:FindFirstChild(name)
		end
		if usable(found) then
			return found
		end
	end
	if folder == nil then
		return nil
	end
	if usable(folder) then
		return folder
	end
	local variants: { Instance } = {}
	for _, child in folder:GetChildren() do
		if usable(child) then
			table.insert(variants, child)
		end
	end
	table.sort(variants, function(a: Instance, b: Instance): boolean
		return a.Name < b.Name
	end)
	return variants[1]
end

-- Scenery, not a wall: the box beside it is what collides. Anchored; raycasts and touches pass through.
local function decorate(part: BasePart)
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = true
end

-- Scales a template's clone to `size` (the car's width, height and length: Parking.sizeOf, so never past its shape's
-- box; Parking.fitSize stretches a mesh along its length, a Model only scales evenly), turns its nose to the pivot's
-- LookVector and stands its bottom on the pivot.
function Parking.fit(clone: Instance, t: TemplateSpec, size: Vector3)
	local turn = math.rad(PARKING.templateTurn)
	if clone:IsA("BasePart") then
		local part = clone :: BasePart
		local native = part.Size
		local fitted = Parking.fitSize(native, size)
		if native.X > native.Z then
			turn += QUARTER -- its +X end to the nose
			part.Size = Vector3.new(fitted.Z, fitted.Y, fitted.X)
		else
			part.Size = fitted
		end
		part.CFrame = t.pivot * CFrame.Angles(0, turn, 0) * CFrame.new(0, part.Size.Y / 2, 0)
		decorate(part)
	elseif clone:IsA("Model") then
		local model = clone :: Model
		local _, native = model:GetBoundingBox()
		local w, l = math.min(native.X, native.Z), math.max(native.X, native.Z)
		if w > 0 and l > 0 and native.Y > 0 then
			model:ScaleTo(model:GetScale() * math.min(size.X / w, size.Y / native.Y, size.Z / l))
		end
		local box, scaled = model:GetBoundingBox()
		if scaled.X > scaled.Z then
			turn += QUARTER
		end
		local foot = box * CFrame.new(0, -scaled.Y / 2, 0)
		model:PivotTo(t.pivot * CFrame.Angles(0, turn, 0) * foot:ToObjectSpace(model:GetPivot()))
		for _, descendant in model:GetDescendants() do
			if descendant:IsA("BasePart") then
				decorate(descendant)
			end
		end
	end
end

-- The parts-only stand-in for a car whose template is missing: its body, its cabin's dark glass and two axles of
-- wheels, `carSize` big (default its shape's box). Decor that casts shadows (the car's box does the colliding).
function Parking.fallback(t: TemplateSpec, folder: string, name: string, carSize: Vector3?): { PartSpec }
	local shape = SHAPES[t.fallback]
	if shape == nil then
		return {}
	end
	local paint = COLOURS[math.clamp(t.variant, 1, #COLOURS)]
	local look = PARKING.standIn
	local size = carSize or shape.size
	local w, h, l = size.X, size.Y, size.Z
	local wheel = math.min(shape.wheel, h * shape.body)
	local bodyTop = h * shape.body
	local bodyBottom = wheel * 0.35
	local out: { PartSpec } = {}
	local function piece(
		suffix: string,
		form: "block" | "cylinder",
		cf: CFrame,
		dims: Vector3,
		color: Color3,
		material: Enum.Material,
		reflectance: number?
	)
		table.insert(out, {
			folder = folder,
			name = `{name}{suffix}`,
			class = "Part",
			shape = form,
			role = "scenery",
			size = dims,
			cframe = t.pivot * cf,
			color = color,
			material = material,
			collide = false,
			query = false,
			touch = false,
			shadow = true,
			transparency = 0,
			reflectance = reflectance,
		})
	end
	piece(
		"Body",
		"block",
		CFrame.new(0, (bodyTop + bodyBottom) / 2, 0),
		Vector3.new(w, bodyTop - bodyBottom, l),
		paint.color,
		Enum.Material.SmoothPlastic,
		0.1
	)
	local cabinLength = l * shape.cabin.X
	piece(
		"Cabin",
		"block",
		CFrame.new(0, (bodyTop + h) / 2, -shape.cabin.Y * l),
		Vector3.new(w - 0.5, h - bodyTop, cabinLength),
		look.glass,
		Enum.Material.SmoothPlastic,
		0.2
	)
	for i, z in { -(l / 2 - wheel * 0.95), l / 2 - wheel * 0.95 } do
		piece(
			`Wheels{i}`,
			"cylinder",
			CFrame.new(0, wheel / 2, z),
			Vector3.new(w - 0.1, wheel, wheel),
			look.tyre,
			Enum.Material.SmoothPlastic
		)
	end
	return out
end

local warned = false

-- What the build puts in a parked car's place: its template's clone, or a Model of the stand-in's parts made with
-- `makePart` (Dev/MapBuilder createPart), marked with standInAttribute (warned once per session). Named after the
-- spec.
function Parking.instantiate(spec: PartSpec, makePart: (PartSpec) -> BasePart): Instance
	local t = spec.template
	if t == nil then
		return makePart(spec)
	end
	local shape = SHAPES[t.fallback]
	local source = if shape then Parking.findTemplate(t.fallback, t.variant) else nil
	if source and shape then
		local clone = source:Clone()
		Parking.fit(clone, t, spec.size)
		clone.Name = spec.name
		return clone
	end
	if not warned then
		warned = true
		warn(
			`[Parking] no car template at ServerStorage.{table.concat(PARKING.templateRoot, ".")}.{t.fallback}_<colour>: `
				.. "building parts-only stand-in cars, more parts than the budgets count (Dev/MapCheck fails while any stand)"
		)
	end
	local model = Instance.new("Model")
	model.Name = spec.name
	model:SetAttribute(Parking.standInAttribute, true)
	for _, part in Parking.fallback(t, spec.folder, spec.name, spec.size) do
		makePart(part).Parent = model
	end
	return model
end

return Parking
