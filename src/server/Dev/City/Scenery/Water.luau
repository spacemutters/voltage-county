--!strict
-- The bay as parts (docs/city/SCENERY.md §3; Config/CityScenery water): the look the bay had before it became terrain
-- water (Config/Water, Dev/WaterBuilder), kept for when Config/Water.terrain is off. Parts that nothing collides with,
-- as the lake's water always was, made to read as Miami water:
--   shallows  along the beach shore only, strips of colour from the sand out: turquoise over the pale sandy bank,
--             then teal, each strip fading into the next through a ramp image tinted with the next one's colour (no
--             hard line between them)
--   the bay   one deep blue sheet over the rest, right up to the stone-edged shores (a Miami seawall has deep water at
--             its foot, not a beach's bands)
--   glints    sun sparkle on a light chop, an image tiled over every sheet
--   foam      on the beach shore a crisp white foam line where the bank meets the water, and a paler wash off it
--   coping    a flush coral-stone edge on the shores without a beach (broken where a bridge comes ashore)
-- Dev/MapBuilder builds the lake bed and its banks (in the bed's sand) and asks for these. While Config/Water.terrain
-- is on the bay is terrain water (Dev/WaterBuilder) and MapBuilder asks only for the coping (Water.coping).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CityScenery = require(ReplicatedStorage.Shared.Config.CityScenery)
local WaterShape = require(ReplicatedStorage.Shared.Util.WaterShape)
local Types = require(script.Parent.Types)

type PartSpec = Types.PartSpec
type Lake = Types.Lake
type Street = Types.Street
type TextureSpec = Types.TextureSpec

local WATER = CityScenery.water
local SHEET = 0.1 -- a sheet's thickness, down from the water line (thin, so its edges don't draw lines)
local MAX_PART = 2048

local Water = {}

Water.bed = WATER.bed

local function blank(name: string, cframe: CFrame, size: Vector3): PartSpec
	return {
		folder = "Water",
		name = name,
		class = "Part",
		shape = "block",
		role = "water",
		size = size,
		cframe = cframe,
		color = Color3.new(1, 1, 1),
		material = Enum.Material.SmoothPlastic,
		collide = false,
		query = false,
		touch = false,
		shadow = false,
		transparency = 0,
	}
end

local function sheet(name: string, x0: number, x1: number, z0: number, z1: number, y0: number, y1: number): PartSpec
	return blank(name, CFrame.new((x0 + x1) / 2, (y0 + y1) / 2, (z0 + z1) / 2), Vector3.new(x1 - x0, y1 - y0, z1 - z0))
end

-- Which sides of `lake` have a beach: a side the beach park (Config/CityScenery beach.park) lies along (the same rule
-- the terrain water's shores follow, Util/WaterShape).
function Water.beachSides(lake: Lake, parks: { Types.Park }): { [string]: boolean }
	local rects: { WaterShape.ParkRect } = {}
	for _, park in parks do
		table.insert(rects, { id = park.id, min = park.min, max = park.max })
	end
	local sides: { [string]: boolean } = WaterShape.beachSides(lake.min, lake.max, rects) :: any
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

-- The glints every sheet wears (none when Config has no image).
local function glints(): { TextureSpec }
	local image = WATER.texture
	if image == nil then
		return {}
	end
	return {
		{
			face = Enum.NormalId.Top,
			image = image,
			u = WATER.textureTile,
			v = WATER.textureTile,
			color = Color3.new(1, 1, 1),
			transparency = WATER.textureTransparency,
		},
	}
end

-- Every water part for `lake`.
function Water.plan(lake: Lake, streets: { Street }, parks: { Types.Park }): { PartSpec }
	local out: { PartSpec } = {}
	local x0, x1, z0, z1 = lake.min.X, lake.max.X, lake.min.Y, lake.max.Y
	local top = lake.waterY
	local y0 = top - SHEET
	local limit = math.min(x1 - x0, z1 - z0) / 2
	local beach = Water.beachSides(lake, parks)
	local bands = WATER.bands
	local shallow = #bands - 1 -- every band but the last is a shallows strip; the last is the open bay

	local function dress(piece: PartSpec, k: number)
		local band = bands[k]
		piece.color = band.color
		piece.transparency = band.transparency
		piece.material = WATER.material
		piece.reflectance = WATER.reflectance
		piece.textures = glints()
	end

	-- The sides, each with its lake edge (a to b), the way in from it, and how far its shallows reach.
	local sides = {
		{ key = "north", a = Vector2.new(x0, z0), b = Vector2.new(x1, z0), inward = Vector2.yAxis },
		{ key = "south", a = Vector2.new(x0, z1), b = Vector2.new(x1, z1), inward = -Vector2.yAxis },
		{ key = "west", a = Vector2.new(x0, z0), b = Vector2.new(x0, z1), inward = Vector2.xAxis },
		{ key = "east", a = Vector2.new(x1, z0), b = Vector2.new(x1, z1), inward = -Vector2.xAxis },
	}
	local reach: { [string]: number } = { north = 0, south = 0, west = 0, east = 0 }
	if shallow >= 1 then
		for key in beach do
			reach[key] = math.min(bands[shallow].width, limit)
		end
	end

	-- The shallows: strips along each beach shore, from the edge out. The north and south strips run the full length;
	-- the west and east ones stop where those reach (no overlap at the corners).
	for _, side in sides do
		if reach[side.key] <= 0 then
			continue
		end
		local alongX = side.key == "north" or side.key == "south"
		local from = if alongX then 0 else reach.north
		local to = (side.b - side.a).Magnitude - (if alongX then 0 else reach.south)
		local dir = (side.b - side.a).Unit
		local inward3 = Vector3.new(side.inward.X, 0, side.inward.Y)
		local inner = 0
		for k = 1, shallow do
			local outer = math.min(bands[k].width, limit)
			if outer <= inner then
				break
			end
			local width = outer - inner
			local length = to - from
			local pieces = math.ceil(length / MAX_PART)
			for j = 1, pieces do
				local s0 = from + length * (j - 1) / pieces
				local s1 = from + length * j / pieces
				local mid = side.a + dir * ((s0 + s1) / 2) + side.inward * ((inner + outer) / 2)
				-- The part's +X points back to the shore: a Top-face texture's U runs from its +X edge (0) to its -X
				-- edge (1), so the ramp is clear at the shore side and solid at the sea side.
				local frame = CFrame.fromMatrix(Vector3.new(mid.X, (y0 + top) / 2, mid.Y), -inward3, Vector3.yAxis)
				local suffix = if pieces > 1 then `{side.key}{j}` else side.key
				local piece = blank(`{lake.id}Band{k}{suffix}`, frame, Vector3.new(width, SHEET, s1 - s0))
				dress(piece, k)
				local ramp = WATER.ramp
				local nextBand = bands[k + 1]
				if ramp and nextBand then
					-- The ramp first, so the glints draw over it.
					local textures: { TextureSpec } = {
						{
							face = Enum.NormalId.Top,
							image = ramp,
							u = width,
							v = 64,
							color = nextBand.color,
							transparency = nextBand.transparency,
						},
					}
					for _, glint in glints() do
						table.insert(textures, glint)
					end
					piece.textures = textures
				end
				table.insert(out, piece)
			end
			inner = outer
		end
	end

	-- The open bay: one sheet (or a few, if longer than a part may be) over everything the shallows leave.
	local bx0, bx1 = x0 + reach.west, x1 - reach.east
	local bz0, bz1 = z0 + reach.north, z1 - reach.south
	local nx = math.ceil((bx1 - bx0) / MAX_PART)
	local nz = math.ceil((bz1 - bz0) / MAX_PART)
	for i = 1, nx do
		for j = 1, nz do
			local ax = bx0 + (bx1 - bx0) * (i - 1) / nx
			local cx = bx0 + (bx1 - bx0) * i / nx
			local az = bz0 + (bz1 - bz0) * (j - 1) / nz
			local cz = bz0 + (bz1 - bz0) * j / nz
			local name = if nx * nz > 1 then `{lake.id}Band{#bands}_{i}_{j}` else `{lake.id}Band{#bands}`
			local piece = sheet(name, ax, cx, az, cz, y0, top)
			dress(piece, #bands)
			table.insert(out, piece)
		end
	end

	-- The foam where the beach's bank meets the water, and the wash off it.
	local foam = WATER.foam
	local at = foam.at
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
		if not beach[side.key] then
			continue
		end
		-- The water line, `at` in from the lake's edge, running between the neighbouring sides' water lines.
		local dir = (side.b - side.a).Unit
		local a = side.a + side.inward * at + dir * at
		local b = side.b + side.inward * at - dir * at
		strip(`{lake.id}Foam{side.key}`, a, b, side.inward, -foam.line / 2, foam.line, 0.05, foam.lineColor)
		strip(`{lake.id}Wash{side.key}`, a, b, side.inward, foam.line / 2, foam.wash, 0.03, foam.washColor)
	end

	for _, piece in Water.coping(lake, streets, parks) do
		table.insert(out, piece)
	end
	return out
end

-- The coping on the shores of `lake` without a beach, broken where a bridge comes ashore: flush stone strips on the
-- ground just outside the lake's edge (part water and terrain water alike).
function Water.coping(lake: Lake, streets: { Street }, parks: { Types.Park }): { PartSpec }
	local out: { PartSpec } = {}
	local x0, x1, z0, z1 = lake.min.X, lake.max.X, lake.min.Y, lake.max.Y
	local beach = Water.beachSides(lake, parks)
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
