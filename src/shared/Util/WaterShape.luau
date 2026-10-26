--!strict
-- The county's open water and the seabed under it (Config/Water; docs/city/SCENERY.md §3). Pure and deterministic:
-- Dev/WaterBuilder writes it into Workspace.Terrain, Services/WaterRescueService asks how deep the water is under a
-- car, and Dev/MapCheck and tests/Water.spec check that no road or gameplay spot stands in it.
--
-- An area is one Config/MapLayout lake: water from its edges up to its waterY. Each of its four shores is a beach (the
-- park Config/CityScenery beach.park lies along it) or a wall (a seawall with a stone coping). The seabed under a
-- point is the shallowest of the four shores' profiles at the point's distance from each (Config/Water
-- seabed.shores), so it rises to the ground at every edge and deepens offshore, and it never goes below the lake's
-- bedY. Past each edge the seabed runs on for seabed.lip studs under the ground, dry.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = ReplicatedStorage.Shared.Config
local CityScenery = require(Config.CityScenery)
local MapLayout = require(Config.MapLayout)
local Water = require(Config.Water)

export type ShoreKind = "beach" | "wall"
export type Side = "north" | "south" | "west" | "east"
export type Lake = { id: string, min: Vector2, max: Vector2, waterY: number, bedY: number }
export type ParkRect = { id: string, min: Vector2, max: Vector2 }

export type Area = {
	id: string,
	min: Vector2, -- X and Z bounds of the water
	max: Vector2,
	waterY: number, -- the water line
	bedY: number, -- the seabed never goes below this
	shores: { [Side]: ShoreKind },
}

-- What stands at one point (x, z) of an area or of its lip.
export type Column = {
	seabed: number, -- the seabed's top
	wet: boolean, -- water stands over it, up to the area's waterY
	inside: boolean, -- inside the area's edges (false on the lip): the water's level runs on under the sand here
	material: Enum.Material,
	shore: ShoreKind, -- the shore whose profile sets the seabed here
	distance: number, -- studs from that shore (0 on the lip)
}

local SIDES: { Side } = { "north", "south", "west", "east" }
local SEABED = Water.seabed

local WaterShape = {}

WaterShape.sides = SIDES

-- Which sides of the rectangle min..max (X and Z) a park with id `beachPark` (default Config/CityScenery beach.park)
-- lies along, sharing that edge. North is the min Z edge.
function WaterShape.beachSides(min: Vector2, max: Vector2, parks: { ParkRect }, beachPark: string?): { [Side]: boolean }
	local id = beachPark or CityScenery.beach.park
	local sides: { [Side]: boolean } = {}
	for _, park in parks do
		if park.id ~= id then
			continue
		end
		local overlapX = park.min.X < max.X and park.max.X > min.X
		local overlapZ = park.min.Y < max.Y and park.max.Y > min.Y
		if overlapX and math.abs(park.max.Y - min.Y) < 1 then
			sides.north = true
		elseif overlapX and math.abs(park.min.Y - max.Y) < 1 then
			sides.south = true
		elseif overlapZ and math.abs(park.max.X - min.X) < 1 then
			sides.west = true
		elseif overlapZ and math.abs(park.min.X - max.X) < 1 then
			sides.east = true
		end
	end
	return sides
end

-- The water area of one lake: a beach on every side the beach park lies along, a wall on the others.
function WaterShape.area(lake: Lake, parks: { ParkRect }): Area
	local beach = WaterShape.beachSides(lake.min, lake.max, parks)
	local shores: { [Side]: ShoreKind } = {}
	for _, side in SIDES do
		shores[side] = if beach[side] then "beach" else "wall"
	end
	return {
		id = lake.id,
		min = lake.min,
		max = lake.max,
		waterY = lake.waterY,
		bedY = lake.bedY,
		shores = shores,
	}
end

function WaterShape.areasFrom(lakes: { Lake }, parks: { ParkRect }): { Area }
	local out: { Area } = {}
	for _, lake in lakes do
		table.insert(out, WaterShape.area(lake, parks))
	end
	return out
end

local county: { Area }? = nil

-- The county's water areas (Config/MapLayout lakes and parks), made once.
function WaterShape.areas(): { Area }
	local made = county
	if made then
		return made
	end
	local parks: { ParkRect } = {}
	for _, park in MapLayout.parks do
		table.insert(parks, { id = park.id, min = park.min, max = park.max })
	end
	local lakes: { Lake } = {}
	for _, lake in MapLayout.lakes do
		table.insert(lakes, { id = lake.id, min = lake.min, max = lake.max, waterY = lake.waterY, bedY = lake.bedY })
	end
	local areas = WaterShape.areasFrom(lakes, parks)
	county = areas
	return areas
end

local function shoreOf(kind: ShoreKind): Water.Shore
	local shore = SEABED.shores[kind]
	assert(shore ~= nil, `Config/Water seabed.shores has no "{kind}"`)
	return shore
end

-- The water depth (studs below the water line; negative where the seabed stands above it) `distance` studs out from
-- a shore of `kind`, for water at `waterY`: from the edge, where the seabed meets the ground at seabed.rimY, along the
-- shore's profile, and level past its last point.
function WaterShape.profileDepth(kind: ShoreKind, distance: number, waterY: number): number
	local fromDistance, fromDepth = 0, waterY - SEABED.rimY
	for _, point in shoreOf(kind).profile do
		if distance <= point.X then
			local span = point.X - fromDistance
			if span <= 0 then
				return point.Y
			end
			local t = math.clamp((distance - fromDistance) / span, 0, 1)
			return fromDepth + (point.Y - fromDepth) * t
		end
		fromDistance, fromDepth = point.X, point.Y
	end
	return fromDepth
end

local function materialOf(kind: ShoreKind, distance: number): Enum.Material
	local shore = shoreOf(kind)
	local stone, reach = shore.stone, shore.stoneReach
	if stone ~= nil and reach ~= nil and distance < reach then
		return stone
	end
	return shore.material
end

-- What stands at (x, z) of `area`: inside it the seabed of its shallowest shore profile (never below bedY) under
-- water to waterY where it is lower; on the lip (up to seabed.lip studs past an edge) dry seabed at rimY; nil further
-- out.
function WaterShape.column(area: Area, x: number, z: number): Column?
	local gaps: { [Side]: number } = {
		north = z - area.min.Y,
		south = area.max.Y - z,
		west = x - area.min.X,
		east = area.max.X - x,
	}
	local inside = true
	for _, side in SIDES do
		local gap = gaps[side]
		if gap < -SEABED.lip then
			return nil
		elseif gap < 0 then
			inside = false
		end
	end
	if not inside then
		local shore: ShoreKind = "wall"
		for _, side in SIDES do
			if gaps[side] < 0 then
				shore = area.shores[side]
				break
			end
		end
		return {
			seabed = SEABED.rimY,
			wet = false,
			inside = false,
			material = materialOf(shore, 0),
			shore = shore,
			distance = 0,
		}
	end
	local best, shore, distance = math.huge, "wall" :: ShoreKind, 0
	for _, side in SIDES do
		local kind = area.shores[side]
		local depth = WaterShape.profileDepth(kind, gaps[side], area.waterY)
		if depth < best then
			best, shore, distance = depth, kind, gaps[side]
		end
	end
	local depth = math.min(best, area.waterY - area.bedY)
	return {
		seabed = area.waterY - depth,
		wet = depth > 0,
		inside = true,
		material = materialOf(shore, distance),
		shore = shore,
		distance = distance,
	}
end

-- The area whose water covers (x, z) (strictly inside its edges), or nil.
function WaterShape.areaAt(x: number, z: number, areas: { Area }?): Area?
	for _, area in areas or WaterShape.areas() do
		if x > area.min.X and x < area.max.X and z > area.min.Y and z < area.max.Y then
			return area
		end
	end
	return nil
end

-- The water line over (x, z), or nil where there is no water.
function WaterShape.surfaceAt(x: number, z: number, areas: { Area }?): number?
	local area = WaterShape.areaAt(x, z, areas)
	if area == nil then
		return nil
	end
	local column = WaterShape.column(area, x, z)
	if column == nil or not column.wet then
		return nil
	end
	return area.waterY
end

-- How deep the water is at (x, z), surface to seabed (0 where there is none).
function WaterShape.depthAt(x: number, z: number, areas: { Area }?): number
	local area = WaterShape.areaAt(x, z, areas)
	if area == nil then
		return 0
	end
	local column = WaterShape.column(area, x, z)
	if column == nil or not column.wet then
		return 0
	end
	return area.waterY - column.seabed
end

return WaterShape
