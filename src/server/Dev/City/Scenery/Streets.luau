--!strict
-- Street scenery (docs/city/SCENERY.md §5; docs/city/CITY_PLAN.md §6; Config/CityScenery streetPalms, furniture and
-- crosswalks):
--   palms       palms in the sidewalks (2.5 to 3 studs from the kerb, in rhythm along both sides: the palm-boulevard
--               look without a raised median, which would change the driving) or on the verges of roads without one,
--               and in rows beside the causeway's approaches on dry land. Never on a driveway, a pad's way out, a
--               gameplay spot or a junction corner, never within a few studs of a streetlight's post or head
--   shelters    bus shelters on the outer half of the avenues' sidewalks, open to the road, lit under the roof at night
--   crosswalks  zebra crossings on every road into a junction of the avenues: one see-through part with a stripe image
--               on its top, lying on the road like its paint
-- Everything goes through the placement grid, so it keeps clear of what MapBuilder already placed and of each other.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local City = require(ReplicatedStorage.Shared.Config.City)
local CityScenery = require(ReplicatedStorage.Shared.Config.CityScenery)
local Kit = require(script.Parent.Parent.Kit)
local Palms = require(script.Parent.Palms)
local Piece = require(script.Parent.Piece)
local Types = require(script.Parent.Types)

type Host = Types.Host
type Ledger = Types.Ledger
type Street = Types.Street
type PartSpec = Types.PartSpec
type Rule = CityScenery.StreetPalmRule

local STREET = CityScenery.streetPalms
local FURNITURE = CityScenery.furniture
local CROSS = CityScenery.crosswalks
local PALETTE = CityScenery.palette

-- What a palm's trunk keeps off (a sidewalk is where a street palm stands)...
local TRUNK_BLOCKERS: { [string]: boolean } = {
	road = true,
	driveway = true,
	support = true,
	location = true,
	access = true,
	prop = true,
	landmark = true,
	feature = true,
	lot = true,
	ramp = true,
	mesa = true,
	lake = true,
	tree = true,
	streetscape = true,
}
-- ...what it keeps a few studs from...
local LIGHT_KINDS: { [string]: boolean } = { light = true, lamp = true }
-- ...and what its crown keeps out of.
local CROWN_KINDS: { [string]: boolean } = { landmark = true, feature = true }

local Streets = {}

-- Shared between calls: how many street palms so far (their names).
export type State = { palms: number }

local function matches(rule: Rule, street: Street): boolean
	return street.kind == rule.kind and (street.fromZone == rule.zone or street.toZone == rule.zone)
end

-- Which sides of `street` face the nearest lake (+1 for its right, -1 for its left).
local function lakeSide(host: Host, street: Street): number?
	local mid = street.a + street.u * (street.length / 2)
	local best: Vector2? = nil
	local nearest = math.huge
	for _, lake in host.lakes do
		local c = (lake.min + lake.max) / 2
		if (c - mid).Magnitude < nearest then
			nearest = (c - mid).Magnitude
			best = c
		end
	end
	if best == nil then
		return nil
	end
	return if ((best :: Vector2) - mid):Dot(street.l) > 0 then 1 else -1
end

-- Plants the palms of every rule `which` accepts (each road takes the first rule that matches it). Returns the parts
-- added.
function Streets.palms(host: Host, ledger: Ledger, state: State, which: (Rule) -> boolean): number
	local added = 0
	local rules: { Rule } = {}
	for _, rule in STREET.rules do
		if which(rule) then
			table.insert(rules, rule)
		end
	end
	for _, street in host.streets do
		local rule: Rule? = nil
		for _, candidate in rules do
			if matches(candidate, street) then
				rule = candidate
				break
			end
		end
		if rule == nil then
			continue
		end
		local r = rule :: Rule
		local species = Palms.species[r.species]
		if species == nil then
			continue
		end
		local onlySide = if r.sides == "lake" then lakeSide(host, street) else nil
		if r.sides == "lake" and onlySide == nil then
			continue
		end
		local bridge = street.kind == "bridge"
		local lateral = street.half + (if street.sidewalk > 0 then r.offset else r.verge)
		local first = street.trimFrom + STREET.endGap
		local last = street.length - street.trimTo - STREET.endGap
		if last < first then
			continue
		end
		local count = math.floor((last - first) / r.spacing)
		local start = first + ((last - first) - count * r.spacing) / 2
		for _, side in { 1, -1 } do
			if onlySide and side ~= onlySide then
				continue
			end
			local rng = Random.new((host.seed * 7 + street.id * 131 + (if side > 0 then 1 else 2)) % 2147483647)
			local shift = if r.stagger and side < 0 then r.spacing / 2 else 0
			local along = start + shift
			while along <= last + 1e-6 do
				local rolls: Palms.Rolls = {
					scale = rng:NextNumber(),
					yaw = rng:NextNumber(),
					lean = rng:NextNumber(),
					variant = rng:NextNumber(),
				}
				local here = along
				along += r.spacing
				local p = street.a + street.u * here + street.l * (side * lateral)
				local ground = host.groundAt(p.X, p.Y)
				if bridge and ground < -0.05 then
					continue -- over the water
				end
				local s = Palms.size(species, rolls, r.scale)
				local trunk = species.collider.X * s / 2
				if host.blocked(Piece.square(p, trunk + STREET.trunkClear, street.u), TRUNK_BLOCKERS, 0) then
					continue
				end
				if host.blocked(Piece.square(p, trunk + STREET.lightClear, street.u), LIGHT_KINDS, 0) then
					continue
				end
				if host.blocked(Piece.square(p, Palms.reach(species, s) * 0.8), CROWN_KINDS, 0) then
					continue
				end
				local base = if street.sidewalk > 0 and not bridge
					then street.surface(here) + host.sidewalkRaise
					else ground
				local trunkSpec, crown = Palms.specs(
					"",
					`StreetPalm{state.palms + 1}`,
					"scenery",
					r.species,
					Vector3.new(p.X, base, p.Y),
					rolls.yaw * 2 * math.pi,
					rolls,
					r.scale
				)
				-- A crown that hangs over the road stays frondClearance above it.
				local overhang = Palms.reach(species, s) > lateral - street.half
				local bottom = crown.cframe.Y - crown.size.Y / 2
				if overhang and bottom < street.surface(here) + STREET.frondClearance then
					continue
				end
				if not Piece.take(ledger, 2) then
					return added
				end
				state.palms += 1
				local folder = Piece.tile(host, p.X, p.Y)
				trunkSpec.folder, crown.folder = folder, folder
				host.add(trunkSpec)
				host.add(crown)
				added += 2
				host.reserve(Piece.square(p, trunk + 1), "tree")
			end
		end
	end
	return added
end

-- What a shelter keeps off, and the streetlights it keeps 2 studs from.
local SHELTER_BLOCKERS: { [string]: boolean } = table.clone(TRUNK_BLOCKERS)

-- Bus shelters along the roads Config/CityScenery furniture.shelters names. Returns the parts added.
function Streets.shelters(host: Host, ledger: Ledger): number
	local added = 0
	local shelter = FURNITURE.shelter
	local roof = shelter.roof
	local h = shelter.height
	local count = 0
	for _, rule in FURNITURE.shelters do
		for _, street in host.streets do
			if street.kind ~= rule.kind or (street.fromZone ~= rule.zone and street.toZone ~= rule.zone) then
				continue
			end
			local first = street.trimFrom + 70
			local last = street.length - street.trimTo - 70
			local along = first + (street.id * 97) % math.max(1, rule.every / 2)
			local k = 0
			while along <= last do
				k += 1
				local side = if (k + street.id) % 2 == 0 then 1 else -1
				local here = along
				along += rule.every
				local lateral = if street.sidewalk > 0
					then street.half + street.sidewalk - roof.Z / 2 - 0.3
					else street.half + 3.5 + roof.Z / 2
				local p = street.a + street.u * here + street.l * (side * lateral)
				local base = if street.sidewalk > 0
					then street.surface(here) + host.sidewalkRaise
					else host.groundAt(p.X, p.Y)
				local at = Vector3.new(p.X, base, p.Y)
				local toRoad = -street.l * side
				local frame = CFrame.lookAt(at, at + Vector3.new(toRoad.X, 0, toRoad.Y))
				local min = Vector3.new(-roof.X / 2, 0, -roof.Z / 2)
				local max = Vector3.new(roof.X / 2, h + roof.Y, roof.Z / 2)
				local rect = Piece.rect(frame, min, max)
				if host.blocked(rect, SHELTER_BLOCKERS, 0) then
					continue
				end
				local wide: Types.Rect = { c = rect.c, u = rect.u, ha = rect.ha + 2, hc = rect.hc + 2 }
				if host.blocked(wide, LIGHT_KINDS, 0) then
					continue
				end
				count += 1
				local m = Piece.model(`Shelter{count}`, frame, host.seed + count)
				Streets.drawShelter(m)
				if not Piece.take(ledger, #m.specs) then
					return added
				end
				added += Piece.finish(host, m)
				host.reserve(rect, "streetscape")
			end
		end
	end
	return added
end

-- A bus shelter in its own frame (front -Z open to the road): a white roof slab, two posts at the back, a glass back
-- wall, a bench, and an LED strip under the roof's front edge that glows at night. 6 parts.
function Streets.drawShelter(m: any)
	local shelter = FURNITURE.shelter
	local roof = shelter.roof
	local h = shelter.height
	local rx, rz = roof.X / 2, roof.Z / 2
	local white = Kit.look(PALETTE.white, Enum.Material.SmoothPlastic)
	local metal = Kit.look(PALETTE.dark, Enum.Material.Metal)
	Kit.trim(m, "", Vector3.new(-rx, h, -rz), Vector3.new(rx, h + roof.Y, rz), white)
	for i, sx in { -1, 1 } do
		Kit.column(m, `Post{i}`, sx * (rx - 0.4), rz - 0.4, -1, h, shelter.post, metal)
	end
	Kit.box(
		m,
		"Glass",
		Vector3.new(-rx + 0.6, 0.6, rz - 0.55),
		Vector3.new(rx - 0.6, h - 0.4, rz - 0.35),
		Kit.look(shelter.glass, Enum.Material.Glass, 0.1, 0.4)
	)
	local bench = shelter.bench
	Kit.trim(
		m,
		"Bench",
		Vector3.new(-bench.X / 2, 1.5, rz - 0.6 - bench.Z),
		Vector3.new(bench.X / 2, 1.5 + bench.Y, rz - 0.6),
		Kit.look(PALETTE.wood, Enum.Material.WoodPlanks)
	)
	Kit.neonStrip(
		m,
		"Glow",
		Vector3.new(-rx + 0.2, h - 0.15, -rz + 0.1),
		Vector3.new(rx - 0.2, h - 0.02, -rz + 0.45),
		"ledBlue",
		PALETTE.white
	)
end

-- One road into a junction, and a junction (a node of the road graph) with the roads into it.
type Leg = { street: Street, atFrom: boolean }
type Node = { roads: number, zone: string, avenue: boolean, legs: { Leg } }

-- Zebra crossings on every road into a junction of the avenues (Config/CityScenery crosswalks). Returns the parts added.
function Streets.crosswalks(host: Host, ledger: Ledger): number
	local nodes: { [string]: Node } = {}
	local order: { string } = {}
	local function key(p: Vector2): string
		return `{math.round(p.X * 10)}_{math.round(p.Y * 10)}`
	end
	local function visit(p: Vector2, roads: number, zone: string, street: Street, atFrom: boolean)
		local k = key(p)
		local node = nodes[k]
		if node == nil then
			node = { roads = roads, zone = zone, avenue = false, legs = {} }
			nodes[k] = node
			table.insert(order, k)
		end
		local n = node :: Node
		n.avenue = n.avenue or CROSS.kinds[street.kind] == true
		table.insert(n.legs, { street = street, atFrom = atFrom })
	end
	for _, street in host.streets do
		visit(street.a, street.fromRoads, street.fromZone, street, true)
		visit(street.a + street.u * street.length, street.toRoads, street.toZone, street, false)
	end
	local image = CROSS.image or City.textures.slabLine
	local added = 0
	local count = 0
	for _, k in order do
		local node = nodes[k]
		if node.roads < 3 or not node.avenue or not CROSS.zones[node.zone] then
			continue
		end
		for _, leg in node.legs do
			local street = leg.street
			if street.kind ~= "street" and street.kind ~= "arterial" then
				continue
			end
			local a = if leg.atFrom
				then street.trimFrom + CROSS.gap
				else street.length - street.trimTo - CROSS.gap - CROSS.depth
			local b = a + CROSS.depth
			if b > street.length - street.trimTo or a < street.trimFrom then
				continue
			end
			if not Piece.take(ledger, 1) then
				return added
			end
			local mid = (a + b) / 2
			local slope = (street.surface(mid + 1) - street.surface(mid - 1)) / 2
			local plan = street.a + street.u * mid
			local centre = Vector3.new(plan.X, street.surface(mid) + host.lineLift + 0.025, plan.Y)
			local frame = CFrame.lookAt(centre, centre + Vector3.new(street.u.X, slope, street.u.Y))
			local width = 2 * street.half - 2 * CROSS.inset
			local size = Vector3.new(width, 0.05, CROSS.depth)
			if CROSS.turn then
				frame = frame * CFrame.Angles(0, math.pi / 2, 0)
				size = Vector3.new(CROSS.depth, 0.05, width)
			end
			count += 1
			local spec: PartSpec = {
				folder = "",
				name = `Crossing{count}`,
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
			added += Piece.file(host, { spec }, plan.X, plan.Y)
		end
	end
	return added
end

return Streets
