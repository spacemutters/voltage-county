--!strict
-- The bay (docs/city/SCENERY.md §3; Config/CityScenery water). Terrain water would read best, but it changes what
-- happens when a car goes in, which is Davis's call, so the bay stays parts that nothing collides with, as the lake's
-- water always was, made to read as Miami water:
--   bands    thin sheets at the water line in bands of colour from the shore out: turquoise over the pale sandy bank
--            in the shallows, teal, then the deep blue of the open bay. Each band is a ring of four sheets round the
--            next (the last one sheet in the middle), so no two see-through sheets lie in one line of sight
--   foam     where the bank meets the water a crisp white foam line, and on the beach shore a paler wash off it
--   coping   a flush coral-stone edge on the shores without a beach (broken where a bridge comes ashore)
-- Dev/MapBuilder builds the lake bed and its banks (in the bed's sand) and asks for these.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CityScenery = require(ReplicatedStorage.Shared.Config.CityScenery)
local Types = require(script.Parent.Types)

type PartSpec = Types.PartSpec
type Lake = Types.Lake
type Street = Types.Street

local WATER = CityScenery.water
local SHEET = 0.6 -- a band's thickness, down from the water line
local MAX_PART = 2048

local Water = {}

Water.bed = WATER.bed

local function sheet(name: string, x0: number, x1: number, z0: number, z1: number, y0: number, y1: number): PartSpec
	return {
		folder = "Water",
		name = name,
		class = "Part",
		shape = "block",
		role = "water",
		size = Vector3.new(x1 - x0, y1 - y0, z1 - z0),
		cframe = CFrame.new((x0 + x1) / 2, (y0 + y1) / 2, (z0 + z1) / 2),
		color = Color3.new(1, 1, 1),
		material = Enum.Material.SmoothPlastic,
		collide = false,
		query = false,
		touch = false,
		shadow = false,
		transparency = 0,
	}
end

-- Which sides of `lake` have a beach: a side the beach park (Config/CityScenery beach.park) lies along.
function Water.beachSides(lake: Lake, parks: { Types.Park }): { [string]: boolean }
	local sides: { [string]: boolean } = {}
	for _, park in parks do
		if park.id ~= CityScenery.beach.park then
			continue
		end
		local overlapX = park.min.X < lake.max.X and park.max.X > lake.min.X
		local overlapZ = park.min.Y < lake.max.Y and park.max.Y > lake.min.Y
		if overlapX and math.abs(park.max.Y - lake.min.Y) < 1 then
			sides.north = true
		elseif overlapX and math.abs(park.min.Y - lake.max.Y) < 1 then
			sides.south = true
		elseif overlapZ and math.abs(park.max.X - lake.min.X) < 1 then
			sides.west = true
		elseif overlapZ and math.abs(park.min.X - lake.max.X) < 1 then
			sides.east = true
		end
	end
	return sides
end

-- Where the bridges cross a straight shore line from `a` to `b` (plan): the distance along it of each crossing.
local function crossings(streets: { Street }, a: Vector2, b: Vector2): { number }
	local out: { number } = {}
	local d = b - a
	local length = d.Magnitude
	for _, street in streets do
		if street.kind ~= "bridge" then
			continue
		end
		local p, r = street.a, street.u * street.length
		local denom = r.X * d.Y - r.Y * d.X
		if math.abs(denom) < 1e-9 then
			continue
		end
		local q = a - p
		local t = (q.X * d.Y - q.Y * d.X) / denom -- along the street, 0..1
		local s = (q.X * r.Y - q.Y * r.X) / denom -- along the shore, 0..1
		if t >= 0 and t <= 1 and s >= 0 and s <= 1 then
			table.insert(out, s * length)
		end
	end
	table.sort(out)
	return out
end

-- Every water part for `lake`.
function Water.plan(lake: Lake, streets: { Street }, parks: { Types.Park }): { PartSpec }
	local out: { PartSpec } = {}
	local x0, x1, z0, z1 = lake.min.X, lake.max.X, lake.min.Y, lake.max.Y
	local top = lake.waterY
	local y0 = top - SHEET
	local limit = math.min(x1 - x0, z1 - z0) / 2
	local function band(
		name: string,
		look: { color: Color3, transparency: number },
		a: number,
		b: number,
		middle: boolean
	)
		local pieces: { PartSpec } = {}
		if middle then
			-- Split along x if it is longer than a part may be.
			local n = math.ceil((x1 - x0 - 2 * a) / MAX_PART)
			for i = 1, n do
				local ax = x0 + a + (x1 - x0 - 2 * a) * (i - 1) / n
				local bx = x0 + a + (x1 - x0 - 2 * a) * i / n
				table.insert(pieces, sheet(if n > 1 then `{name}_{i}` else name, ax, bx, z0 + a, z1 - a, y0, top))
			end
		else
			table.insert(pieces, sheet(`{name}N`, x0 + a, x1 - a, z0 + a, z0 + b, y0, top))
			table.insert(pieces, sheet(`{name}S`, x0 + a, x1 - a, z1 - b, z1 - a, y0, top))
			table.insert(pieces, sheet(`{name}W`, x0 + a, x0 + b, z0 + b, z1 - b, y0, top))
			table.insert(pieces, sheet(`{name}E`, x1 - b, x1 - a, z0 + b, z1 - b, y0, top))
		end
		for _, piece in pieces do
			piece.color = look.color
			piece.transparency = look.transparency
			piece.material = WATER.material
			piece.reflectance = WATER.reflectance
			local texture = WATER.texture
			if texture then
				piece.textures = {
					{
						face = Enum.NormalId.Top,
						image = texture,
						u = WATER.textureTile,
						v = WATER.textureTile,
						color = Color3.new(1, 1, 1),
						transparency = 0.6,
					},
				}
			end
			table.insert(out, piece)
		end
	end
	local inner = 0
	for i, look in WATER.bands do
		local outer = math.min(look.width, limit)
		local last = i == #WATER.bands or outer >= limit
		band(`{lake.id}Band{i}`, look, inner, outer, last)
		if last then
			break
		end
		inner = outer
	end

	-- The foam where the bank meets the water, and the wash off it on the beach.
	local foam = WATER.foam
	local beach = Water.beachSides(lake, parks)
	local at = foam.at
	local sides = {
		{ key = "north", a = Vector2.new(x0 + at, z0 + at), b = Vector2.new(x1 - at, z0 + at), inward = Vector2.yAxis },
		{
			key = "south",
			a = Vector2.new(x0 + at, z1 - at),
			b = Vector2.new(x1 - at, z1 - at),
			inward = -Vector2.yAxis,
		},
		{ key = "west", a = Vector2.new(x0 + at, z0 + at), b = Vector2.new(x0 + at, z1 - at), inward = Vector2.xAxis },
		{ key = "east", a = Vector2.new(x1 - at, z0 + at), b = Vector2.new(x1 - at, z1 - at), inward = -Vector2.xAxis },
	}
	local function strip(
		name: string,
		a: Vector2,
		b: Vector2,
		inward: Vector2,
		from: number,
		width: number,
		lift: number,
		color: Color3
	)
		local p, q = a + inward * (from + width / 2), b + inward * (from + width / 2)
		local lo, hi = p:Min(q), p:Max(q)
		local alongX = math.abs(b.X - a.X) > math.abs(b.Y - a.Y)
		local hx = if alongX then (hi.X - lo.X) / 2 else width / 2
		local hz = if alongX then width / 2 else (hi.Y - lo.Y) / 2
		local c = (lo + hi) / 2
		local piece = sheet(name, c.X - hx, c.X + hx, c.Y - hz, c.Y + hz, top - 0.03, top + lift)
		piece.color = color
		table.insert(out, piece)
	end
	for _, side in sides do
		strip(`{lake.id}Foam{side.key}`, side.a, side.b, side.inward, -foam.line / 2, foam.line, 0.05, foam.lineColor)
		if beach[side.key] then
			strip(
				`{lake.id}Wash{side.key}`,
				side.a,
				side.b,
				side.inward,
				foam.line / 2,
				foam.wash,
				0.03,
				foam.washColor
			)
		end
	end

	-- The coping on the shores without a beach, broken where a bridge comes ashore.
	local coping = WATER.coping
	local edges = {
		{ key = "north", a = Vector2.new(x0, z0), b = Vector2.new(x1, z0), out = -Vector2.yAxis },
		{ key = "south", a = Vector2.new(x0, z1), b = Vector2.new(x1, z1), out = Vector2.yAxis },
		{ key = "west", a = Vector2.new(x0, z0), b = Vector2.new(x0, z1), out = -Vector2.xAxis },
		{ key = "east", a = Vector2.new(x1, z0), b = Vector2.new(x1, z1), out = Vector2.xAxis },
	}
	for _, edge in edges do
		if beach[edge.key] then
			continue
		end
		local length = (edge.b - edge.a).Magnitude
		local dir = (edge.b - edge.a) / length
		-- The north and south runs reach round the corners; the west and east ones stop at them (no overlap).
		local extend = if edge.key == "north" or edge.key == "south" then coping.width else 0
		local runs: { { number } } = {}
		local start = -extend
		for _, s in crossings(streets, edge.a, edge.b) do
			table.insert(runs, { start, s - WATER.bridgeGap })
			start = s + WATER.bridgeGap
		end
		table.insert(runs, { start, length + extend })
		for k, run in runs do
			if run[2] - run[1] < 4 then
				continue
			end
			local p = edge.a + dir * run[1] + edge.out * (coping.width / 2)
			local q = edge.a + dir * run[2] + edge.out * (coping.width / 2)
			local lo, hi = p:Min(q), p:Max(q)
			local alongX = math.abs(dir.X) > 0.5
			local hx = if alongX then (hi.X - lo.X) / 2 else coping.width / 2
			local hz = if alongX then coping.width / 2 else (hi.Y - lo.Y) / 2
			local c = (lo + hi) / 2
			local piece =
				sheet(`{lake.id}Coping{edge.key}{k}`, c.X - hx, c.X + hx, c.Y - hz, c.Y + hz, 0.01, coping.rise)
			piece.role = "scenery"
			piece.color = coping.color
			piece.material = coping.material
			piece.shadow = true
			table.insert(out, piece)
		end
	end
	return out
end

return Water
