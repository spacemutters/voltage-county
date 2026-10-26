--!strict
-- The city's street life (Dev/City/Street; Config/CityStreet). Pure: builds nothing. One describe per section.
--
-- Frontage (Street/Frontage: shop fronts and café terraces on the commercial sites' forecourts):
--   * Config/CityStreet frontage makes sense: every district's trades, looks (at least 7, each awning its own colour),
--     café props, neon kinds and fonts exist; shop names are invented, upper case, short enough for a board and never
--     shared between trades; the lot types and homes are skipped
--   * every archetype it may dress, on sample sites: the same pieces every time; every piece fit to build, scenery,
--     named after its site, inside its footprint and height (so behind its front line: no sidewalk is touched), filed
--     in the site's model (night lights and signs in its lights model), nothing solid but the box round a row of tables
--     and that box clear of the building; every shop has its awning and its sign
--   * shops side by side never share a look or a name, whichever site each stands on
--   * the county: within the frontage's part and night-light budgets, every piece inside its site, every row's box clear
--     of the building's parts, neighbouring shops on one road different; counts by district printed

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local City = require(ReplicatedStorage.Shared.Config.City)
local CityProps = require(ReplicatedStorage.Shared.Config.CityProps)
local CityStreet = require(ReplicatedStorage.Shared.Config.CityStreet)
local Environment = require(ReplicatedStorage.Shared.Config.Environment)
local Harness = require(ReplicatedStorage.Shared.Testing.Harness)

local Dev = ServerScriptService.Server.Dev
local CityBuilder = require(Dev.City.CityBuilder)
local CityTypes = require(Dev.City.Types)
local Frontage = require(Dev.City.Street.Frontage)
local FrontageParts = require(Dev.City.Street.FrontageParts)
local Kit = require(Dev.City.Kit)
local MapBuilder = require(Dev.MapBuilder)

type PartSpec = MapBuilder.PartSpec
type Site = CityTypes.Site
type Variant = CityTypes.Variant

local F = CityStreet.frontage
local NIGHT = Environment.nightLights
local TOLERANCE = 0.05
local DEPTH = 53 -- a plot's depth
local SEEDS = { 11, 4242 }
-- Fonts Davis has banned everywhere (~/.claude/banned-fonts.json), as Roblox names them.
local BANNED_FONTS: { [string]: boolean } = {
	Arial = true,
	ArialBold = true,
	Roboto = true,
	RobotoCondensed = true,
	RobotoMono = true,
	Nunito = true,
	FredokaOne = true,
	Montserrat = true,
}

local function report(t: Harness.Api, label: string, problems: { string })
	if #problems > 0 then
		local shown = table.move(problems, 1, math.min(#problems, 8), 1, {})
		print(`  CityStreet.spec {label}: {#problems} problems, e.g. {table.concat(shown, "; ")}`)
	end
	t.expect(#problems).toBe(0)
end

-- How deep two boxes (site frame, lo..hi) overlap: the least overlap over the three axes, 0 when apart.
local function overlap(alo: Vector3, ahi: Vector3, blo: Vector3, bhi: Vector3): number
	local x = math.min(ahi.X, bhi.X) - math.max(alo.X, blo.X)
	local y = math.min(ahi.Y, bhi.Y) - math.max(alo.Y, blo.Y)
	local z = math.min(ahi.Z, bhi.Z) - math.max(alo.Z, blo.Z)
	return math.max(0, math.min(x, y, z))
end

-- Everything wrong with `pieces`, the frontage of `site` built on `own` (its archetype's parts).
local function problemsOf(site: Site, own: { PartSpec }, pieces: { PartSpec }): { string }
	local problems: { string } = {}
	local hw, hd = site.width / 2 + TOLERANCE, site.depth / 2 + TOLERANCE
	local names: { [string]: boolean } = {}
	local signs: { [string]: boolean } = {}
	local awnings: { [string]: boolean } = {}
	for _, piece in pieces do
		local label = `{site.id} {site.archetype} {piece.name}`
		local problem = Kit.problem(piece)
		if problem then
			table.insert(problems, `{site.id} {problem}`)
		end
		if not FrontageParts.owns(piece) or string.sub(piece.name, 1, #site.id + 6) ~= site.id .. "Street" then
			table.insert(problems, `{label}: not named and tagged as {site.id}'s street front`)
		end
		if names[piece.name] then
			table.insert(problems, `{label}: twice`)
		end
		names[piece.name] = true
		local lit = piece.tag == NIGHT.tag or piece.labels ~= nil or piece.light ~= nil
		local want = if lit then site.lightsFolder else site.folder
		if piece.folder ~= want then
			table.insert(problems, `{label}: filed in {piece.folder}, not {want}`)
		end
		-- The one Light the street front has: a café row's swag casts warm light on its tables at night (the
		-- street-level roast, 2026-10-26, point 9): a point light on its first string, off by day.
		local light = piece.light
		if light and (string.sub(piece.name, -7) ~= "String1" or light.kind ~= "point" or light.enabled ~= false) then
			table.insert(problems, `{label}: a Light other than a café row's swag (a point light, off by day)`)
		end
		local lo, hi = Kit.localBounds(site.frame, piece)
		if lo.X < -hw or hi.X > hw or lo.Z < -hd or hi.Z > hd then
			table.insert(problems, `{label}: outside its site's footprint (past the front line or the sides)`)
		end
		if lo.Y < -TOLERANCE or hi.Y > site.maxHeight + TOLERANCE then
			table.insert(problems, `{label}: from y {lo.Y} to {hi.Y}`)
		end
		local tables = string.sub(piece.name, -#"StreetTables") == "StreetTables"
		if piece.collide and not tables then
			table.insert(problems, `{label}: solid`)
		end
		if tables then
			if not piece.collide or piece.transparency < 1 then
				table.insert(problems, `{label}: a row's box that isn't an invisible solid`)
			end
			for _, spec in own do
				local blo, bhi = Kit.localBounds(site.frame, spec)
				local deep = overlap(lo, hi, blo, bhi)
				if deep > TOLERANCE then
					table.insert(problems, `{label}: {string.format("%.2f", deep)} into {spec.name}`)
				end
			end
		end
		local shop = string.match(piece.name, "Street(Shop%d+)Sign$")
		if shop then
			signs[shop] = true
			if piece.labels == nil or #piece.labels == 0 or piece.labels[1].text == "" then
				table.insert(problems, `{label}: a sign with no name`)
			end
		end
		local roof = string.match(piece.name, "Street(Shop%d+)Awning$")
		if roof then
			awnings[roof] = true
		end
	end
	for shop in signs do
		if not awnings[shop] then
			table.insert(problems, `{site.id} {shop}: a sign with no awning`)
		end
	end
	for shop in awnings do
		if not signs[shop] then
			table.insert(problems, `{site.id} {shop}: an awning with no sign`)
		end
	end
	return problems
end

-- A sample site of `id`, a plot deep (or its archetype's least depth, if deeper), its front facing south, in its own
-- district.
local function sample(id: string, width: number, height: number, variant: Variant, seed: number, at: Vector3?): Site
	local here = at or Vector3.new(0, 0, 4000)
	local frame = CFrame.lookAt(here, here + Vector3.zAxis)
	local depth = math.max(DEPTH, City.archetypes[id].minDepth)
	return CityBuilder.sampleSite(id, frame, width, depth, height, variant, seed)
end

-- The archetype's own parts of a built site (its street front left out).
local function ownParts(specs: { PartSpec }): { PartSpec }
	local own: { PartSpec } = {}
	for _, spec in specs do
		if not FrontageParts.owns(spec) then
			table.insert(own, spec)
		end
	end
	return own
end

-- Every archetype the frontage may dress, sorted.
local function dressable(): { string }
	local ids: { string } = {}
	for id, config in City.archetypes do
		if F.skip[id] or City.notOnPlots[id] or F.districts[config.district] == nil then
			continue
		end
		if config.minWidth > config.maxWidth or config.maxWidth <= 0 then
			continue
		end
		table.insert(ids, id)
	end
	table.sort(ids)
	return ids
end

---------------------------------------------------------------------------------------------------------------
-- Parked cars (Street/Parking; Config/CityStreet parking). Its own describes, run from parkedCarSpecs at the end:
--   * Config/CityStreet parking makes sense: every shape a mix draws exists and has a size, every paint a name and a
--     weight, the solid box sits inside every shape, the hotel archetypes and kerb road kinds exist, a stall holds a car
--   * a car is two parts: the space its template fills (decor, its template under ServerStorage.CityAssets.Cars) and the
--     invisible box a car bumps into; the stand-in for a missing template is decor, fit to build, inside the car
--   * the lots' stalls: the same cars every time, each inside its stall and pulled to its head, the share and the ledger
--     held, two cars side by side never the same shape and paint, the options for filing in a site's model
--   * the planner on a small hand-made county (a villa with a drive, a hotel under a porte-cochère, a diner): a car on the
--     drive nosed to the garage, one under the hotel's canopy along the road on its forecourt, the diner's row nosed in
--     with its door kept clear; the same cars every time; none in a road, a sidewalk or any part; the budget held
--   * the county: cars within budget, each two parts in an Atomic SLIM tile; none in a lane, on a pad, a gameplay spot,
--     a house plot or the way out of one; no car's box in any other part
---------------------------------------------------------------------------------------------------------------

local MapLayout = require(ReplicatedStorage.Shared.Config.MapLayout)
local RoadGraph = require(ReplicatedStorage.Shared.Config.RoadGraph)
local World = require(ReplicatedStorage.Shared.Config.World)
local Parking = require(Dev.City.Street.Parking)
local SceneryTypes = require(Dev.City.Scenery.Types)

type ParkRect = SceneryTypes.Rect

local PARKING = CityStreet.parking

-- Whether two plan rectangles overlap deeper than `tolerance` (separating axes).
local function parkRectsOverlap(a: ParkRect, b: ParkRect, tolerance: number): boolean
	local function reach(r: ParkRect, axis: Vector2): number
		local l = Vector2.new(-r.u.Y, r.u.X)
		return math.abs(r.u:Dot(axis)) * r.ha + math.abs(l:Dot(axis)) * r.hc
	end
	for _, axis in { a.u, Vector2.new(-a.u.Y, a.u.X), b.u, Vector2.new(-b.u.Y, b.u.X) } do
		if reach(a, axis) + reach(b, axis) - math.abs((b.c - a.c):Dot(axis)) <= tolerance then
			return false
		end
	end
	return true
end

-- A car's plan footprint (its body spec's box from above).
local function parkFootprint(spec: PartSpec): ParkRect
	local look = Vector2.new(spec.cframe.LookVector.X, spec.cframe.LookVector.Z)
	local u = if look.Magnitude > 1e-6 then look.Unit else Vector2.yAxis
	return { c = Vector2.new(spec.cframe.X, spec.cframe.Z), u = u, ha = spec.size.Z / 2, hc = spec.size.X / 2 }
end

-- Every part as its whole oriented box, and how deep two of them overlap (0 when apart).
type ParkBox = { spec: PartSpec, centre: Vector3, axes: { Vector3 }, half: { number }, min: Vector2, max: Vector2 }

local function parkBoxOf(spec: PartSpec): ParkBox
	local cf, s = spec.cframe, spec.size / 2
	local axes = { cf.RightVector, cf.UpVector, cf.LookVector }
	local half = { s.X, s.Y, s.Z }
	local reachX = math.abs(axes[1].X) * half[1] + math.abs(axes[2].X) * half[2] + math.abs(axes[3].X) * half[3]
	local reachZ = math.abs(axes[1].Z) * half[1] + math.abs(axes[2].Z) * half[2] + math.abs(axes[3].Z) * half[3]
	local c = cf.Position
	return {
		spec = spec,
		centre = c,
		axes = axes,
		half = half,
		min = Vector2.new(c.X - reachX, c.Z - reachZ),
		max = Vector2.new(c.X + reachX, c.Z + reachZ),
	}
end

local function parkDepth(a: ParkBox, b: ParkBox): number
	local function extent(box: ParkBox, axis: Vector3): number
		return math.abs(box.axes[1]:Dot(axis)) * box.half[1]
			+ math.abs(box.axes[2]:Dot(axis)) * box.half[2]
			+ math.abs(box.axes[3]:Dot(axis)) * box.half[3]
	end
	local axes: { Vector3 } = {}
	for _, axis in a.axes do
		table.insert(axes, axis)
	end
	for _, axis in b.axes do
		table.insert(axes, axis)
	end
	for _, p in a.axes do
		for _, q in b.axes do
			local c = p:Cross(q)
			if c.Magnitude > 1e-6 then
				table.insert(axes, c.Unit)
			end
		end
	end
	local least = math.huge
	local d = b.centre - a.centre
	for _, axis in axes do
		local over = extent(a, axis) + extent(b, axis) - math.abs(d:Dot(axis))
		if over <= 0 then
			return 0
		end
		least = math.min(least, over)
	end
	return least
end

-- Every pair of a box in `list` and one in `others` overlapping deeper than TOLERANCE, as "a x b depth".
local function parkOverlaps(list: { ParkBox }, others: { ParkBox }): { string }
	local cell = 64
	local grid: { [number]: { ParkBox } } = {}
	for _, box in others do
		for x = math.floor(box.min.X / cell), math.floor(box.max.X / cell) do
			for z = math.floor(box.min.Y / cell), math.floor(box.max.Y / cell) do
				local key = x * 65536 + z
				local bucket = grid[key]
				if bucket == nil then
					bucket = {}
					grid[key] = bucket
				end
				table.insert(bucket, box)
			end
		end
	end
	local found: { string } = {}
	for _, box in list do
		local seen: { [ParkBox]: boolean } = {}
		for x = math.floor(box.min.X / cell), math.floor(box.max.X / cell) do
			for z = math.floor(box.min.Y / cell), math.floor(box.max.Y / cell) do
				for _, other in grid[x * 65536 + z] or {} :: { ParkBox } do
					if not seen[other] and other ~= box then
						seen[other] = true
						local deep = parkDepth(box, other)
						if deep > TOLERANCE then
							local a, b = box.spec, other.spec
							table.insert(
								found,
								`{a.folder}/{a.name} x {b.folder}/{b.name} {string.format("%.2f", deep)}`
							)
						end
					end
				end
			end
		end
	end
	return found
end

-- Sets config numbers for the time `body` runs (`set` writes them, returning a function that puts them back).
local function parkWith(set: () -> () -> (), body: () -> ())
	local restore = set()
	local ok, err = pcall(function(): any
		body()
		return nil
	end)
	restore()
	if not ok then
		error(err, 0)
	end
end

-- Every stall taken, every hotel and drive given its car.
local function everyStall(): () -> ()
	local drives, drops, parks = PARKING.drives.share, PARKING.dropOff.share, PARKING.carParks.share
	PARKING.drives.share, PARKING.dropOff.share, PARKING.carParks.share = 1, 1, 1
	return function()
		PARKING.drives.share, PARKING.dropOff.share, PARKING.carParks.share = drives, drops, parks
	end
end

-- A small hand-made county for the planner: three roads (a suburb street with sidewalks, the beach road, the diner's
-- road), a villa with a drive and a garage south of the first, a hotel with a porte-cochère over its forecourt north of
-- the second, and a diner (its car park, building, door and sign) west of the third.
type ParkFixture = {
	host: SceneryTypes.Host,
	added: { PartSpec },
	containers: { [string]: MapBuilder.Container },
	shapes: { { rect: ParkRect, kind: string } },
	sites: { Site },
	parts: { PartSpec },
	villa: Site,
	hotel: Site,
	apron: PartSpec,
}

local function parkStreet(id: number, zone: string, a: Vector2, b: Vector2, sidewalk: number): SceneryTypes.Street
	local u = (b - a).Unit
	return {
		id = id,
		name = `S{id}`,
		kind = "street",
		fromZone = zone,
		toZone = zone,
		a = a,
		u = u,
		l = Vector2.new(-u.Y, u.X),
		length = (b - a).Magnitude,
		half = 15,
		sidewalk = sidewalk,
		trimFrom = 10,
		trimTo = 10,
		fromRoads = 4,
		toRoads = 4,
		surface = function(_along: number): number
			return 0.2
		end,
	}
end

-- A site of `archetype` whose footprint's middle is `centre`, its front toward `toward` (its road).
local function parkSite(
	id: string,
	archetype: string,
	zone: string,
	centre: Vector3,
	toward: Vector3,
	width: number
): Site
	return {
		id = id,
		archetype = archetype,
		district = "test",
		zone = zone,
		frame = CFrame.lookAt(centre, centre + toward),
		width = width,
		depth = DEPTH,
		height = 30,
		maxHeight = 40,
		seed = 900 + #zone,
		variant = { palette = 1, crown = 1, rhythm = 1, mirror = false },
		folder = `Buildings/Site{id}`,
		lightsFolder = `BuildingLights/Site{id}`,
		plots = {},
		block = 0,
		band = "L",
		face = "road",
		claim = 0,
		corner = { left = false, right = false },
		landmark = false,
		skyline = false,
	}
end

local function parkFeaturePart(name: string, cframe: CFrame, size: Vector3, solid: boolean): PartSpec
	return {
		folder = "Features/test_diner",
		name = name,
		class = "Part",
		shape = "block",
		role = "feature",
		size = size,
		cframe = cframe,
		color = Color3.fromRGB(180, 180, 180),
		material = if name == "CarPark" then Enum.Material.Asphalt else Enum.Material.Metal,
		collide = solid,
		query = solid,
		touch = false,
		shadow = true,
		transparency = 0,
	}
end

local function parkFixture(): ParkFixture
	local shapes: { { rect: ParkRect, kind: string } } = {}
	local added: { PartSpec } = {}
	local containers: { [string]: MapBuilder.Container } = {}
	local streets = {
		parkStreet(1, "riverside", Vector2.new(-300, 0), Vector2.new(300, 0), 8),
		parkStreet(2, "lakefront", Vector2.new(-300, 1500), Vector2.new(300, 1500), 0),
		parkStreet(3, "lakefront", Vector2.new(1150, 300), Vector2.new(1150, 700), 0),
	}
	for _, s in streets do
		local mid = s.a + s.u * (s.length / 2)
		table.insert(shapes, { rect = { c = mid, u = s.u, ha = s.length / 2, hc = s.half }, kind = "road" })
		if s.sidewalk > 0 then
			for _, side in { -1, 1 } do
				local c = mid + s.l * (side * (s.half + s.sidewalk / 2))
				table.insert(
					shapes,
					{ rect = { c = c, u = s.u, ha = s.length / 2, hc = s.sidewalk / 2 }, kind = "sidewalk" }
				)
			end
		end
	end
	local wall = Kit.look(Color3.fromRGB(236, 230, 214), Enum.Material.Plaster)
	local paving = Kit.look(Color3.fromRGB(200, 184, 150), Enum.Material.Brick)

	-- The villa: south of the suburb street, its front line 25 studs from the centre line (half, sidewalk, 2).
	local villa = parkSite("B1", "mediterranean_villa", "riverside", Vector3.new(0, 0, 51.5), -Vector3.zAxis, 40)
	local v = Kit.model(villa)
	Kit.detail(v, "Drive", Vector3.new(6, 0.02, -26.3), Vector3.new(15, 0.14, -10.05), paving)
	Kit.box(v, "Garage", Vector3.new(5, -0.5, -10), Vector3.new(16, 9, 6), wall)
	Kit.box(v, "House", Vector3.new(-19, -0.5, -14), Vector3.new(4, 14, 20), wall)
	Kit.box(v, "GardenWall", Vector3.new(-19, -0.5, -25.8), Vector3.new(2, 2, -25.1), wall)

	-- The hotel: north of the beach road, its forecourt under a porte-cochère on two piers, planters at the corners.
	local hotel = parkSite("B2", "domed_cupola_hotel", "lakefront", Vector3.new(0, 0, 1456.5), Vector3.zAxis, 60)
	local h = Kit.model(hotel)
	Kit.detail(h, "Forecourt", Vector3.new(-29.5, 0, -26.5), Vector3.new(29.5, 0.4, -16.5), paving)
	Kit.box(h, "Body", Vector3.new(-29.5, -0.5, -16.5), Vector3.new(29.5, 30, 26.5), wall)
	Kit.trim(h, "Canopy", Vector3.new(-12, 10, -26), Vector3.new(12, 11, -16.5), wall)
	Kit.box(h, "PierL", Vector3.new(-12, -0.5, -26), Vector3.new(-10.5, 10, -24.5), wall)
	Kit.box(h, "PierR", Vector3.new(10.5, -0.5, -26), Vector3.new(12, 10, -24.5), wall)
	Kit.box(h, "PlanterL", Vector3.new(-29, 0, -26.3), Vector3.new(-20, 1.5, -24.5), wall)
	Kit.box(h, "PlanterR", Vector3.new(20, 0, -26.3), Vector3.new(29, 1.5, -24.5), wall)

	-- The diner: its site faces the third road (its local -Z toward it), the car park in front of the building.
	local base = CFrame.new(1100, 0, 500) * CFrame.Angles(0, math.rad(-90), 0)
	local apron = parkFeaturePart("CarPark", base * CFrame.new(0, 0.05, -12), Vector3.new(60, 0.1, 32), false)
	local parts: { PartSpec } = {
		apron,
		parkFeaturePart("Base", base * CFrame.new(0, 6.5, 16), Vector3.new(46, 13, 24), true),
		parkFeaturePart("Door", base * CFrame.new(-11.5, 3.75, 3.7), Vector3.new(5, 7.5, 0.6), false),
		parkFeaturePart("SignPole", base * CFrame.new(22, 9, -20), Vector3.new(1.2, 18, 1.2), true),
	}
	table.move(v.specs, 1, #v.specs, #parts + 1, parts)
	table.move(h.specs, 1, #h.specs, #parts + 1, parts)
	-- The plots and the diner's footprint, as MapBuilder's grid holds them.
	for _, site in { villa, hotel } do
		local look = site.frame.LookVector
		table.insert(shapes, {
			rect = {
				c = Vector2.new(site.frame.X, site.frame.Z),
				u = Vector2.new(look.X, look.Z),
				ha = site.depth / 2,
				hc = site.width / 2,
			},
			kind = "lot",
		})
	end
	table.insert(
		shapes,
		{ rect = { c = Vector2.new(1100, 500), u = Vector2.xAxis, ha = 28, hc = 30 }, kind = "feature" }
	)

	local host: SceneryTypes.Host = {
		seed = 1887,
		half = 5000,
		sidewalkRaise = 0.5,
		lineLift = 0.02,
		streets = streets,
		lakes = {},
		parks = {},
		groundAt = function(_x: number, _z: number): number
			return 0
		end,
		blocked = function(rect: ParkRect, kinds: { [string]: boolean }, tolerance: number): boolean
			for _, shape in shapes do
				if kinds[shape.kind] and parkRectsOverlap(rect, shape.rect, tolerance) then
					return true
				end
			end
			return false
		end,
		reserve = function(rect: ParkRect, kind: string)
			table.insert(shapes, { rect = rect, kind = kind })
		end,
		add = function(spec: PartSpec)
			table.insert(added, spec)
		end,
		container = function(
			path: string,
			class: "Folder" | "Model",
			streaming: Enum.ModelStreamingMode?,
			lod: string?
		)
			containers[path] = { path = path, class = class, streaming = streaming, lod = lod }
		end,
		note = function(text: string)
			error(`parking left a note: {text}`)
		end,
	}
	return {
		host = host,
		added = added,
		containers = containers,
		shapes = shapes,
		sites = { villa, hotel },
		parts = parts,
		villa = villa,
		hotel = hotel,
		apron = apron,
	}
end

-- The parked cars' bodies (their template's specs) in `list`, each with its box.
local function parkPairs(list: { PartSpec }): ({ PartSpec }, { [PartSpec]: PartSpec }, { string })
	local bodies: { PartSpec } = {}
	local boxOf: { [PartSpec]: PartSpec } = {}
	local byName: { [string]: PartSpec } = {}
	local problems: { string } = {}
	for _, spec in list do
		byName[`{spec.folder}/{spec.name}`] = spec
	end
	for _, spec in list do
		if spec.template then
			table.insert(bodies, spec)
			local box = byName[`{spec.folder}/{spec.name}Box`]
			if box == nil then
				table.insert(problems, `{spec.name}: no box`)
			else
				boxOf[spec] = box
			end
		end
	end
	return bodies, boxOf, problems
end

-- A car's middle in `frame`'s coordinates, its half sizes there (it is square to the frame), and where its feet are.
local function parkLocal(frame: CFrame, body: PartSpec): (Vector3, Vector3)
	local rel = frame:ToObjectSpace(body.cframe)
	local half = body.size / 2
	local lo, hi = Vector3.one * math.huge, -Vector3.one * math.huge
	for _, sx in { -1, 1 } do
		for _, sy in { -1, 1 } do
			for _, sz in { -1, 1 } do
				local p = rel * Vector3.new(sx * half.X, sy * half.Y, sz * half.Z)
				lo, hi = lo:Min(p), hi:Max(p)
			end
		end
	end
	return lo, hi
end

local function parkedCarSpecs(t: Harness.Api)
	t.describe("Parked cars: Config/CityStreet parking", function()
		t.it(
			"draws shapes that exist, paints with names, a box inside every car, real hotels and road kinds",
			function()
				local problems: { string } = {}
				local listed: { [string]: boolean } = {}
				for _, name in PARKING.order do
					listed[name] = true
					local shape = PARKING.shapes[name]
					if shape == nil then
						table.insert(problems, `order: no shape {name}`)
						continue
					end
					local s = shape.size
					if s.X <= 0 or s.Y <= 0 or s.Z <= s.X then
						table.insert(problems, `{name}: size {s}`)
					end
					if not (shape.body > 0 and shape.body < 1 and shape.cabin.X > 0 and shape.cabin.X < 1) then
						table.insert(problems, `{name}: body or cabin share`)
					end
					if shape.wheel <= 0 or shape.wheel >= s.Y then
						table.insert(problems, `{name}: wheel`)
					end
					local box = PARKING.box
					if box.lift >= s.Y * box.top or 2 * box.inset >= s.X then
						table.insert(problems, `{name}: the solid box doesn't fit`)
					end
				end
				for name in PARKING.shapes do
					if not listed[name] then
						table.insert(problems, `shapes: {name} is not in order`)
					end
				end
				for mixName, mix in PARKING.mixes do
					local total = 0
					for name, weight in mix do
						if not listed[name] then
							table.insert(problems, `mixes.{mixName}: no shape {name}`)
						end
						total += weight
					end
					if total <= 0 then
						table.insert(problems, `mixes.{mixName}: draws nothing`)
					end
				end
				local names: { [string]: boolean } = {}
				for i, colour in PARKING.colours do
					if colour.name == "" or names[colour.name] or colour.weight <= 0 then
						table.insert(problems, `colours[{i}]: name or weight`)
					end
					names[colour.name] = true
				end
				for archetype in PARKING.dropOff.archetypes do
					if City.archetypes[archetype] == nil then
						table.insert(problems, `dropOff: no archetype {archetype}`)
					end
				end
				for kind in PARKING.curb.kinds do
					if (RoadGraph.styles :: any)[kind] == nil then
						table.insert(problems, `curb: no road kind {kind}`)
					end
				end
				local stall = PARKING.stalls.size
				local fits = false
				for name in PARKING.mixes.lot do
					local s = PARKING.shapes[name].size
					if s.Z + PARKING.stalls.noseGap <= stall.Y and s.X + 2 * PARKING.clearance <= stall.X then
						fits = true
					end
				end
				if not fits then
					table.insert(problems, "stalls: no lot shape fits a stall")
				end
				report(t, "parking config", problems)
			end
		)

		t.it("draws shapes in order and paints by weight, and measures the room outside the lanes", function()
			local mix = { ParkedSedan = 1, ParkedVan = 1 }
			t.expect(Parking.pick(mix, 0)).toBe("ParkedSedan")
			t.expect(Parking.pick(mix, 0.999)).toBe("ParkedVan")
			t.expect(Parking.pick({}, 0.5)).toBe(nil)
			t.expect(Parking.paint(0)).toBe(1)
			t.expect(Parking.paint(0.9999)).toBe(#PARKING.colours)
			for kind, style in RoadGraph.styles :: any do
				t.expect(Parking.curbRoom(kind)).toBe(style.shoulder)
			end
		end)
	end)

	t.describe("Parked cars: one car", function()
		local pivot = CFrame.new(40, 0.14, -60) * CFrame.Angles(0, 0.4, 0)
		t.it("is the space its template fills and an invisible box a car bumps into", function()
			for colour, paint in PARKING.colours do
				for _, shapeName in PARKING.order do
					local body, box = Parking.car("ParkedCars/Tile0_-1", "Car40_-60", pivot, shapeName, colour)
					local template = body.template :: SceneryTypes.TemplateSpec
					t.expect(template ~= nil).toBe(true)
					t.expect(template.path[1]).toBe(PARKING.templateRoot[1])
					t.expect(template.path[2]).toBe(PARKING.templateRoot[2])
					t.expect(template.path[3]).toBe(`{shapeName}_{paint.name}`)
					t.expect(template.fallback).toBe(shapeName)
					t.expect(template.variant).toBe(colour)
					t.expect(Parking.owns(body)).toBe(true)
					t.expect(Parking.owns(box)).toBe(false)
					t.expect(body.collide or body.query or body.touch).toBe(false)
					t.expect(body.transparency).toBe(1)
					t.expect(box.collide and box.query).toBe(true)
					t.expect(box.transparency).toBe(1)
					t.expect(box.name).toBe("Car40_-60Box")
					t.expect(Kit.problem(body)).toBe(nil)
					t.expect(Kit.problem(box)).toBe(nil)
					-- The box inside the car, lifted off the ground.
					local lo, hi = parkLocal(pivot, box)
					local size = PARKING.shapes[shapeName].size
					t.expect(lo.Y).toBeNear(PARKING.box.lift, 1e-4)
					t.expect(hi.Y <= size.Y + 1e-4 and math.abs(lo.X) < size.X / 2 and math.abs(lo.Z) < size.Z / 2)
						.toBe(true)
					-- The body stands on the pivot.
					local blo = parkLocal(pivot, body)
					t.expect(blo.Y).toBeNear(0, 1e-4)
				end
			end
			local _, asBuilding = Parking.car("Buildings/Site9", "B9Car", pivot, "ParkedSUV", 1, "building")
			t.expect(asBuilding.role).toBe("building")
		end)

		t.it("stands in as decor, fit to build and inside the car, while its template is missing", function()
			for _, shapeName in PARKING.order do
				local body = Parking.car("ParkedCars/Tile0_-1", "Car40_-60", pivot, shapeName, 2)
				local template = body.template :: SceneryTypes.TemplateSpec
				local parts = Parking.fallback(template, body.folder, body.name)
				t.expect(#parts).toBe(4)
				local size = PARKING.shapes[shapeName].size
				for _, part in parts do
					t.expect(Kit.problem(part)).toBe(nil)
					t.expect(part.collide or part.query or part.touch).toBe(false)
					local lo, hi = parkLocal(pivot, part)
					local inside = lo.Y >= -1e-3
						and hi.Y <= size.Y + 1e-3
						and lo.X >= -size.X / 2 - 1e-3
						and hi.X <= size.X / 2 + 1e-3
						and lo.Z >= -size.Z / 2 - 1e-3
						and hi.Z <= size.Z / 2 + 1e-3
					t.expect(inside).toBe(true)
				end
			end
			t.expect(Parking.findTemplate("NoSuchCar", 1)).toBe(nil)
		end)

		t.it("is built at its template's proportions inside its shape's box, at the end it is anchored to", function()
			local problems: { string } = {}
			for colour, paint in PARKING.colours do
				for _, shapeName in PARKING.order do
					local box = PARKING.shapes[shapeName].size
					local size = Parking.sizeOf(shapeName, colour)
					if size.X > box.X + 1e-4 or size.Y > box.Y + 1e-4 or size.Z > box.Z + 1e-4 then
						table.insert(problems, `{shapeName}_{paint.name}: {size} past its box {box}`)
					end
					local measured = PARKING.templateSizes[`{shapeName}_{paint.name}`]
					if measured then
						-- Even scale across, at most templateStretch along.
						local across = size.X / measured.X
						local along = size.Z / measured.Z
						if
							math.abs(size.Y / measured.Y - across) > 1e-3
							or along < across - 1e-3
							or along > across * PARKING.templateStretch + 1e-3
						then
							table.insert(problems, `{shapeName}_{paint.name}: not its template's proportions`)
						end
					end
					-- Nose-anchored: its nose at the box's front; tail-anchored: its tail at the box's back.
					for _, anchor in { 1, -1 } do
						local body, box2 =
							Parking.car("ParkedCars/Tile0_-1", "Car40_-60", pivot, shapeName, colour, nil, anchor)
						local lo, hi = parkLocal(pivot, body)
						local blo, bhi = parkLocal(pivot, box2)
						local front, back = -box.Z / 2, box.Z / 2
						local nose = if anchor == 1 then lo.Z else hi.Z
						local want = if anchor == 1 then front else back
						if math.abs(nose - want) > 1e-3 or lo.Z < front - 1e-3 or hi.Z > back + 1e-3 then
							table.insert(problems, `{shapeName}_{paint.name}: anchored {anchor} at {lo.Z}..{hi.Z}`)
						end
						if blo.Z < lo.Z - 1e-3 or bhi.Z > hi.Z + 1e-3 or bhi.Y > hi.Y + 1e-3 then
							table.insert(problems, `{shapeName}_{paint.name}: its solid box outside the car`)
						end
					end
				end
			end
			report(t, "car sizes", problems)
		end)
	end)

	t.describe("Parked cars: the lots' stalls", function()
		local stalls: { Parking.Stall } = {}
		for i = 1, 12 do
			local centre = Vector3.new(200 + i * 9.8, 0.3, 300)
			table.insert(
				stalls,
				{ cframe = CFrame.lookAt(centre, centre + Vector3.zAxis), size = Vector2.new(9.8, 19.5) }
			)
		end
		local function stallOf(body: PartSpec): Parking.Stall
			local best, found = math.huge, stalls[1]
			for _, stall in stalls do
				local d = (stall.cframe.Position - body.cframe.Position).Magnitude
				if d < best then
					best, found = d, stall
				end
			end
			return found
		end

		t.it("parks the same cars every time, each inside its stall and pulled to its head", function()
			local a = Parking.fillStalls(stalls, 7, { share = 1 })
			local b = Parking.fillStalls(stalls, 7, { share = 1 })
			t.expect(#a).toBe(24)
			t.expect(#b).toBe(#a)
			local problems: { string } = {}
			for i, spec in a do
				if spec.name ~= b[i].name or (spec.cframe.Position - b[i].cframe.Position).Magnitude > 1e-6 then
					table.insert(problems, `{spec.name}: differs between two runs`)
				end
			end
			local bodies, _, missing = parkPairs(a)
			table.move(missing, 1, #missing, #problems + 1, problems)
			local gap = PARKING.stalls.noseGap
			for _, body in bodies do
				local stall = stallOf(body)
				local size = stall.size :: Vector2
				local lo, hi = parkLocal(stall.cframe, body)
				if lo.X < -size.X / 2 or hi.X > size.X / 2 or lo.Z < -size.Y / 2 or hi.Z > size.Y / 2 then
					table.insert(problems, `{body.name}: outside its stall`)
				end
				-- The stall's head is its local -Z end.
				if math.abs(lo.Z - (-size.Y / 2 + gap)) > 0.25 then
					table.insert(problems, `{body.name}: {lo.Z + size.Y / 2} from its stall's head`)
				end
				if Kit.problem(body) then
					table.insert(problems, Kit.problem(body) :: string)
				end
			end
			-- Two cars side by side are never the same shape and paint.
			for i = 2, #bodies do
				local p, q = bodies[i - 1], bodies[i]
				local tp, tq = p.template :: SceneryTypes.TemplateSpec, q.template :: SceneryTypes.TemplateSpec
				local near = (p.cframe.Position - q.cframe.Position).Magnitude < 2 * 9.8
				if near and tp.fallback == tq.fallback and tp.variant == tq.variant then
					table.insert(problems, `{p.name} and {q.name}: the same car side by side`)
				end
			end
			report(t, "stalls", problems)
		end)

		t.it("keeps to its share and its ledger, and files cars in a site's model when asked", function()
			local some = Parking.fillStalls(stalls, 7)
			t.expect(#some <= 24 and #some % 2 == 0).toBe(true)
			local ledger = { used = 0, limit = 6 }
			local capped = Parking.fillStalls(stalls, 7, { share = 1, ledger = ledger })
			t.expect(#capped).toBe(6)
			t.expect(ledger.used).toBe(6)
			t.expect(#Parking.fillStalls(stalls, 7, { share = 0 })).toBe(0)
			local filed = Parking.fillStalls(stalls, 7, {
				share = 1,
				folder = "Buildings/Site9",
				prefix = "B9",
				role = "building",
			})
			for _, spec in filed do
				t.expect(spec.folder).toBe("Buildings/Site9")
				t.expect(string.sub(spec.name, 1, 2)).toBe("B9")
				t.expect(spec.role).toBe("building")
			end
		end)
	end)

	t.describe("Parked cars: the planner on a small hand-made county", function()
		t.it("parks a car on the drive, one under the hotel's canopy and a row at the diner", function()
			parkWith(everyStall, function()
				local f = parkFixture()
				local result = Parking.plan(f.host, f.sites, f.parts)
				print(
					`  CityStreet.spec parking fixture: {result.cars} cars ({result.drives} drives, {result.dropOffs} `
						.. `drop-offs, {result.carParks} car park, {result.kerbs} kerbs, {result.lots} lots)`
				)
				local bodies, _, problems = parkPairs(f.added)
				t.expect(#bodies).toBe(result.cars)
				t.expect(result.parts).toBe(#f.added)
				t.expect(result.kerbs).toBe(0) -- a street's shoulder holds no car
				local onDrive, atHotel, atDiner = 0, 0, 0
				for _, body in bodies do
					local entry = f.containers[body.folder]
					if entry == nil or entry.lod ~= "SLIM" or entry.streaming ~= Enum.ModelStreamingMode.Atomic then
						table.insert(problems, `{body.folder}: not a registered Atomic SLIM tile`)
					end
					local look = body.cframe.LookVector
					-- The villa's drive runs x 6..15 back to the garage at z -10 (site coordinates).
					local lo, hi = parkLocal(f.villa.frame, body)
					if math.abs(lo.X) < f.villa.width and math.abs(lo.Z) < DEPTH then
						onDrive += 1
						local middle = (lo.X + hi.X) / 2
						if math.abs(middle - 10.5) > 0.01 then
							table.insert(problems, `drive car off the drive's middle ({middle})`)
						end
						-- 1e-3: CFrames are single precision.
						if hi.Z > -10 - PARKING.clearance + 1e-3 or hi.Z < -11.2 then
							table.insert(problems, `drive car not pulled up to the garage (its far end at {hi.Z})`)
						end
						if math.abs(math.abs(look:Dot(f.villa.frame.LookVector)) - 1) > 1e-4 then
							table.insert(problems, "drive car not square to the drive")
						end
						if math.abs(lo.Y - 0.14) > 1e-3 then
							table.insert(problems, `drive car not on the drive's paving ({lo.Y})`)
						end
					end
					-- The hotel's canopy spans x -12..12 and z -26..-16.5; its forecourt is 0.4 high to z -16.5.
					lo, hi = parkLocal(f.hotel.frame, body)
					if math.abs(lo.X) < f.hotel.width and math.abs(lo.Z) < DEPTH then
						atHotel += 1
						local x, z = (lo.X + hi.X) / 2, (lo.Z + hi.Z) / 2
						if x < -12 or x > 12 or z < -26 or z > -16.5 then
							table.insert(problems, `hotel car not under the canopy ({x}, {z})`)
						end
						if lo.Z < -26.5 - 1e-3 or hi.Z > -16.5 - PARKING.clearance + 1e-3 then
							table.insert(problems, "hotel car not wholly on the forecourt")
						end
						if look:Dot(f.hotel.frame.RightVector) < 1 - 1e-4 then
							table.insert(problems, "hotel car not along the road the way its lane runs")
						end
						if math.abs(lo.Y - 0.4) > 1e-3 then
							table.insert(problems, `hotel car not on the forecourt ({lo.Y})`)
						end
					end
					-- The diner's car park: apron coordinates, the building's front at z 16, its door at x -14..-9.
					local apronFrame = f.apron.cframe * CFrame.new(0, -f.apron.size.Y / 2, 0)
					lo, hi = parkLocal(apronFrame, body)
					if math.abs(lo.X) < 40 and math.abs(lo.Z) < 40 then
						atDiner += 1
						if hi.X > -18 + PARKING.clearance and lo.X < -5 - PARKING.clearance then
							table.insert(problems, `diner car in the way to the door ({(lo.X + hi.X) / 2})`)
						end
						if
							hi.Z > 16 - PARKING.clearance + 1e-3
							or hi.Z < 16 - PARKING.clearance - PARKING.carParks.slide
						then
							table.insert(problems, `diner car not nosed in ({hi.Z})`)
						end
						if look:Dot(-apronFrame.LookVector) < 1 - 1e-4 then
							table.insert(problems, "diner car not nosed toward the diner")
						end
					end
				end
				t.expect(onDrive).toBe(1)
				t.expect(atHotel).toBe(1)
				t.expect(atDiner).toBe(3)
				-- Nothing solid of a car in any part, nor a car on a road or sidewalk.
				local cars: { ParkBox } = {}
				local others: { ParkBox } = {}
				for _, spec in f.added do
					if spec.collide then
						table.insert(cars, parkBoxOf(spec))
					end
				end
				for _, spec in f.parts do
					table.insert(others, parkBoxOf(spec))
				end
				local inParts = parkOverlaps(cars, others)
				table.move(inParts, 1, #inParts, #problems + 1, problems)
				for _, body in bodies do
					for _, shape in f.shapes do
						if
							(shape.kind == "road" or shape.kind == "sidewalk")
							and parkRectsOverlap(parkFootprint(body), shape.rect, 0)
						then
							table.insert(problems, `{body.name}: on a {shape.kind}`)
						end
					end
				end
				report(t, "fixture", problems)
			end)
		end)

		t.it("parks the same cars every time and keeps to its budget", function()
			local a, b = parkFixture(), parkFixture()
			Parking.plan(a.host, a.sites, a.parts)
			Parking.plan(b.host, b.sites, b.parts)
			t.expect(#a.added).toBe(#b.added)
			for i, spec in a.added do
				t.expect(spec.name).toBe(b.added[i].name)
				t.expect((spec.cframe.Position - b.added[i].cframe.Position).Magnitude < 1e-6).toBe(true)
			end
			parkWith(function(): () -> ()
				local limit = PARKING.budget.planParts
				PARKING.budget.planParts = 2
				local undo = everyStall()
				return function()
					undo()
					PARKING.budget.planParts = limit
				end
			end, function()
				local c = parkFixture()
				local result = Parking.plan(c.host, c.sites, c.parts)
				t.expect(result.parts <= 2).toBe(true)
				t.expect(#c.added <= 2).toBe(true)
			end)
		end)
	end)

	t.describe("Parked cars: the county", function()
		-- Planned once for every case below (a county plan takes a while in Edit mode).
		local plan = MapBuilder.county()
		local mine: { PartSpec } = {}
		local root = `^{PARKING.root}/`
		for _, spec in plan.specs do
			if string.find(spec.folder, root) then
				table.insert(mine, spec)
			end
		end
		local bodies, _, unpaired = parkPairs(mine)

		t.it("parks cars within budget, each two parts fit to build in an Atomic SLIM tile", function()
			print(
				`  CityStreet.spec: {#bodies} parked cars ({#mine} parts); plan.scenery.parkedCars = {plan.scenery.parkedCars}`
			)
			local problems: { string } = table.clone(unpaired)
			t.expect(#bodies).toBeGreaterThan(0)
			t.expect(#mine).toBe(2 * #bodies)
			t.expect(#mine <= PARKING.budget.planParts + PARKING.budget.lotParts).toBe(true)
			local kinds: { [string]: MapBuilder.Container } = {}
			for _, entry in plan.containers do
				kinds[entry.path] = entry
			end
			for _, spec in mine do
				local problem = Kit.problem(spec)
				if problem then
					table.insert(problems, problem)
				end
				local entry = kinds[spec.folder]
				if entry == nil or entry.lod ~= "SLIM" or entry.streaming ~= Enum.ModelStreamingMode.Atomic then
					table.insert(problems, `{spec.folder}: not a registered Atomic SLIM tile`)
				end
				if spec.tag or spec.light or spec.labels then
					table.insert(problems, `{spec.name}: a light or a sign in a SLIM tile`)
				end
			end
			report(t, "county cars", problems)
		end)

		t.it("never parks in a lane, on a pad, a gameplay spot, a house plot or the way out of one", function()
			local keepOff: { { rect: ParkRect, what: string } } = {}
			local byId: { [string]: Vector3 } = {}
			for _, node in RoadGraph.nodes do
				byId[node.id] = node.position
			end
			-- Every lane: the carriageway less its shoulders.
			for _, edge in RoadGraph.edges do
				local a3, b3 = byId[edge.from], byId[edge.to]
				local a, b = Vector2.new(a3.X, a3.Z), Vector2.new(b3.X, b3.Z)
				if (b - a).Magnitude > 1e-3 then
					table.insert(keepOff, {
						rect = {
							c = (a + b) / 2,
							u = (b - a).Unit,
							ha = (b - a).Magnitude / 2,
							hc = edge.lanes * World.laneWidth / 2,
						},
						what = `the lanes of {edge.from}-{edge.to}`,
					})
				end
			end
			-- Every gameplay spot and pad (house plots included), and the way from it to its road.
			local volumes = { FlightZone = true, NoFlyZone = true, DragStripGate = true }
			for _, location in MapLayout.locations do
				if volumes[location.tag] then
					continue
				end
				local c = Vector2.new(location.position.X, location.position.Z)
				local facing = CFrame.Angles(0, math.rad(location.yaw), 0).LookVector
				local u = Vector2.new(facing.X, facing.Z).Unit
				table.insert(keepOff, {
					rect = { c = c, u = u, ha = location.size.Z / 2, hc = location.size.X / 2 },
					what = location.id,
				})
				local best, road = math.huge, c
				for _, edge in RoadGraph.edges do
					local a3, b3 = byId[edge.from], byId[edge.to]
					local a, b = Vector2.new(a3.X, a3.Z), Vector2.new(b3.X, b3.Z)
					local length = (b - a).Magnitude
					if length > 1e-3 then
						local along = math.clamp((c - a):Dot((b - a) / length), 0, length)
						local point = a + (b - a) / length * along
						if (point - c).Magnitude < best then
							best, road = (point - c).Magnitude, point
						end
					end
				end
				if best > 1 then
					table.insert(keepOff, {
						rect = { c = (c + road) / 2, u = (road - c).Unit, ha = best / 2, hc = location.size.X / 2 },
						what = `the way out of {location.id}`,
					})
				end
			end
			-- The dealership's and used lot's sale pads.
			local pads: { CFrame } = table.clone(MapLayout.usedLot.pads)
			for _, section in MapLayout.dealership.sections do
				table.move(section.pads, 1, #section.pads, #pads + 1, pads)
			end
			for i, pad in pads do
				local size = MapLayout.dealership.padSize
				local look = Vector2.new(pad.LookVector.X, pad.LookVector.Z).Unit
				table.insert(keepOff, {
					rect = { c = Vector2.new(pad.X, pad.Z), u = look, ha = size.Z / 2, hc = size.X / 2 },
					what = `sale pad {i}`,
				})
			end
			local problems: { string } = {}
			for _, body in bodies do
				local footprint = parkFootprint(body)
				for _, item in keepOff do
					if parkRectsOverlap(footprint, item.rect, TOLERANCE) then
						table.insert(problems, `{body.folder}/{body.name}: on {item.what}`)
					end
				end
			end
			report(t, "county keep-off", problems)
		end)

		t.it("never puts a car's solid box into another part", function()
			local cars: { ParkBox } = {}
			for _, spec in mine do
				if spec.collide then
					table.insert(cars, parkBoxOf(spec))
				end
			end
			local listed: { [PartSpec]: boolean } = {}
			for _, spec in mine do
				listed[spec] = true
			end
			local roles: { [string]: boolean } = {
				building = true,
				feature = true,
				prop = true,
				sign = true,
				landmark = true,
				displayPad = true,
				location = true,
				spawn = true,
				billboard = true,
			}
			local others: { ParkBox } = {}
			for _, spec in plan.specs do
				if not listed[spec] and spec.role ~= "ground" and (spec.collide or roles[spec.role]) then
					table.insert(others, parkBoxOf(spec))
				end
			end
			report(t, "county solid", parkOverlaps(cars, others))
		end)
	end)
end

return function(t: Harness.Api)
	t.describe("Frontage: Config/CityStreet frontage", function()
		t.it("names districts, trades, looks, café props, neon kinds and fonts that exist", function()
			local problems: { string } = {}
			for district, d in F.districts do
				if #d.looks < 7 then
					table.insert(problems, `{district}: {#d.looks} looks, fewer than 7`)
				end
				local colours: { [string]: boolean } = {}
				for i, look in d.looks do
					local key = tostring(look.awning)
					if colours[key] then
						table.insert(problems, `{district} look {i}: an awning colour another look has`)
					end
					colours[key] = true
					if NIGHT.kinds[look.neon] == nil then
						table.insert(problems, `{district} look {i}: neon kind {look.neon} unknown`)
					end
					if look.cut ~= "slope" and look.cut ~= "striped" and look.cut ~= "flat" then
						table.insert(problems, `{district} look {i}: cut {look.cut}`)
					end
					if look.sign ~= "fascia" and look.sign ~= "blade" then
						table.insert(problems, `{district} look {i}: sign {look.sign}`)
					end
				end
				for _, kind in d.kinds do
					if F.kinds[kind] == nil then
						table.insert(problems, `{district}: no trade {kind}`)
					end
				end
				for _, cafe in d.cafes do
					if CityProps.props[cafe] == nil then
						table.insert(problems, `{district}: no café prop {cafe} in Config/CityProps`)
					end
				end
				if d.share < 0 or d.share > 1 or d.terraces < 0 or d.terraces > 1 or d.shops < 0 then
					table.insert(problems, `{district}: share, terraces or shops out of range`)
				end
			end
			if CityProps.props[F.terrace.bistro] == nil then
				table.insert(problems, `no bistro prop {F.terrace.bistro} in Config/CityProps`)
			end
			if NIGHT.kinds[F.terrace.lights.kind] == nil then
				table.insert(problems, `string lights: kind {F.terrace.lights.kind} unknown`)
			end
			local owner: { [string]: string } = {}
			for kind, info in F.kinds do
				if BANNED_FONTS[info.font.Name] then
					table.insert(problems, `{kind}: font {info.font.Name} is banned`)
				end
				if #info.names == 0 then
					table.insert(problems, `{kind}: no names`)
				end
				local word = info.word
				if string.upper(word) ~= word or #word < 2 or #word > F.shop.blade.maxWord then
					table.insert(
						problems,
						`{kind}: blade word "{word}" (upper case, 2 to {F.shop.blade.maxWord} letters)`
					)
				end
				for _, name in info.names do
					if string.upper(name) ~= name or #name > 18 or #name < 3 then
						table.insert(problems, `{kind}: name "{name}" (upper case, 3 to 18 characters)`)
					end
					if owner[name] and owner[name] ~= kind then
						table.insert(problems, `"{name}": a name of {owner[name]} and {kind}`)
					end
					owner[name] = kind
				end
			end
			for id in F.skip do
				if City.archetypes[id] == nil then
					table.insert(problems, `skip: no archetype {id}`)
				end
			end
			report(t, "config", problems)
		end)

		t.it("keeps its look step under the closest two shops can stand", function()
			-- Two shops on one wall stand width.min + gap apart at least; two on neighbouring sites further.
			t.expect(F.lookStep < F.shop.width.min + F.shop.gap).toBe(true)
			t.expect(F.shop.width.min <= F.shop.width.target and F.shop.width.target <= F.shop.width.max).toBe(true)
		end)
	end)

	t.describe("Frontage: sample sites", function()
		local ids = dressable()

		t.it("dresses every archetype it may within its site, filed and fit to build, the same every time", function()
			local problems: { string } = {}
			local shops, rows, sites = 0, 0, 0
			local lines: { string } = {}
			for _, id in ids do
				local config = City.archetypes[id]
				local width = math.min(config.maxWidth, math.max(config.minWidth, 60))
				local height = (config.heights.min + config.heights.max) / 2
				local seen = 0
				for n, seed in SEEDS do
					local variant: Variant =
						{ palette = n % config.palettes + 1, crown = 1, rhythm = 1, mirror = n == 2 }
					local site = sample(id, width, height, variant, seed)
					local built, why = CityBuilder.build(site)
					if built == nil then
						table.insert(problems, `{id}: {why}`)
						continue
					end
					local own = ownParts(built)
					local a, ra = Frontage.dress(site, own, true)
					local b = Frontage.dress(site, own, true)
					if #a ~= #b then
						table.insert(problems, `{id} seed {seed}: {#a} then {#b} pieces`)
					else
						for i, piece in a do
							if b[i].name ~= piece.name or b[i].cframe ~= piece.cframe or b[i].size ~= piece.size then
								table.insert(problems, `{id} seed {seed}: {piece.name} differs between two runs`)
								break
							end
						end
					end
					for _, problem in problemsOf(site, own, a) do
						table.insert(problems, problem)
					end
					sites += 1
					shops += ra.shops
					rows += if ra.tables > 0 then 1 else 0
					seen += #a
				end
				table.insert(lines, `{id} {seen}`)
			end
			print(
				`  CityStreet.spec frontage samples: {sites} sites, {shops} shops, {rows} café rows; pieces by type: `
			)
			print(`    {table.concat(lines, ", ")}`)
			report(t, "samples", problems)
			-- The street front has to show up somewhere: shops on some sample, a row of tables on another.
			t.expect(shops).toBeGreaterThan(0)
			t.expect(rows).toBeGreaterThan(0)
		end)

		t.it("never dresses a site facing away from its road, a skipped archetype or a lot", function()
			local problems: { string } = {}
			local variant: Variant = { palette = 1, crown = 1, rhythm = 1, mirror = false }
			for id in F.skip do
				local config = City.archetypes[id]
				if config == nil then
					continue
				end
				local site = sample(id, config.minWidth, config.heights.min, variant, 7)
				if Frontage.eligible(site) then
					table.insert(problems, `{id}: eligible`)
				end
			end
			if #ids > 0 then
				local config = City.archetypes[ids[1]]
				local site = sample(ids[1], config.minWidth, config.heights.min, variant, 7)
				site.face = "back"
				local pieces = Frontage.dress(site, {}, true)
				if #pieces > 0 then
					table.insert(problems, `{ids[1]} facing back: {#pieces} pieces`)
				end
			end
			report(t, "eligible", problems)
		end)

		t.it("never puts the same look or name on two shops side by side", function()
			local problems: { string } = {}
			local variant: Variant = { palette = 1, crown = 1, rhythm = 1, mirror = false }
			local closest = F.shop.width.min + F.shop.gap
			for district in F.districts do
				-- A site of that district's own (any archetype of it), turned four ways and moved along its road.
				local id: string? = nil
				for _, candidate in ids do
					if City.archetypes[candidate].district == district then
						id = candidate
						break
					end
				end
				if id == nil then
					continue
				end
				for turn = 0, 3 do
					local here = Vector3.new(137 * turn - 300, 0, 4000 + 53 * turn)
					local facing = CFrame.Angles(0, turn * math.pi / 2, 0).LookVector
					local frame = CFrame.lookAt(here, here + facing)
					local site = CityBuilder.sampleSite(id :: string, frame, 60, DEPTH, 40, variant, 3)
					for _, spacing in { closest, closest + 6.3, 40, 59 } do
						local last: Frontage.Pick? = nil
						for i = 0, 30 do
							local pick = Frontage.pick(site, -200 + i * spacing)
							if last then
								local before = last :: Frontage.Pick
								if before.look == pick.look then
									table.insert(problems, `{district} turn {turn}, {spacing} apart: one look twice`)
								end
								if before.name == pick.name then
									table.insert(
										problems,
										`{district} turn {turn}, {spacing} apart: "{pick.name}" twice`
									)
								end
							end
							last = pick
						end
					end
				end
			end
			report(t, "neighbours", problems)
		end)
	end)

	t.describe("Frontage: the county", function()
		-- Planned once for every case below (a county plan takes a while in Edit mode).
		local plan = MapBuilder.county()
		local byId: { [string]: Site } = {}
		for _, site in plan.sites do
			byId[site.id] = site
		end
		local own: { [string]: { PartSpec } } = {}
		local pieces: { PartSpec } = {}
		for _, spec in plan.specs do
			if FrontageParts.owns(spec) then
				table.insert(pieces, spec)
			elseif spec.role == "building" then
				local id = string.match(spec.name, "^B%d+")
				if id then
					local list = own[id] or {}
					table.insert(list, spec)
					own[id] = list
				end
			end
		end

		t.it("keeps to its budgets, every piece on its own site", function()
			local problems: { string } = {}
			local bySite: { [string]: { PartSpec } } = {}
			local lights = 0
			for _, piece in pieces do
				local id = string.match(piece.name, "^B%d+") or ""
				if byId[id] == nil then
					table.insert(problems, `{piece.name}: no site {id}`)
					continue
				end
				local list = bySite[id] or {}
				table.insert(list, piece)
				bySite[id] = list
				if piece.tag == NIGHT.tag then
					lights += 1
				end
			end
			local counts: { [string]: { sites: number, shops: number, rows: number, pieces: number } } = {}
			for id, list in bySite do
				local site = byId[id]
				for _, problem in problemsOf(site, own[id] or {}, list) do
					table.insert(problems, problem)
				end
				local district = Frontage.district(site)
				local c = counts[district] or { sites = 0, shops = 0, rows = 0, pieces = 0 }
				c.sites += 1
				c.pieces += #list
				for _, piece in list do
					if string.match(piece.name, "StreetShop%d+Sign$") then
						c.shops += 1
					elseif string.match(piece.name, "StreetTable1$") then
						c.rows += 1
					end
				end
				counts[district] = c
			end
			local lines: { string } = {}
			for district, c in counts do
				table.insert(
					lines,
					`{district} {c.sites} sites, {c.shops} shops, {c.rows} café rows, {c.pieces} pieces`
				)
			end
			table.sort(lines)
			print(
				`  CityStreet.spec frontage: {#pieces} pieces of {F.budget.parts}, {lights} night lights of `
					.. `{F.budget.nightLights}; {table.concat(lines, "; ")}`
			)
			if #pieces > F.budget.parts then
				table.insert(problems, `{#pieces} pieces, over frontage.budget.parts {F.budget.parts}`)
			end
			if lights > F.budget.nightLights then
				table.insert(problems, `{lights} night lights, over frontage.budget.nightLights {F.budget.nightLights}`)
			end
			report(t, "county", problems)
			t.expect(#pieces).toBeGreaterThan(0)
		end)

		t.it("never puts the same look or name on neighbouring shops along a road", function()
			-- Each shop by its sign: its frontage (the side of the road its site faces, as a line), where it stands along
			-- the road, its awning's colour and its name.
			type Shop = { line: string, along: number, colour: string, name: string, id: string }
			local awnings: { [string]: PartSpec } = {}
			for _, piece in pieces do
				local key = string.match(piece.name, "^(B%d+StreetShop%d+)Awning$")
				if key then
					awnings[key] = piece
				end
			end
			local lines: { [string]: { Shop } } = {}
			for _, piece in pieces do
				local key = string.match(piece.name, "^(B%d+StreetShop%d+)Sign$")
				local awning = key and awnings[key]
				if key == nil or awning == nil or piece.labels == nil then
					continue
				end
				local site = byId[string.match(piece.name, "^B%d+") or ""]
				if site == nil then
					continue
				end
				local r, l = site.frame.RightVector, site.frame.LookVector
				local front = site.frame * Vector3.new(0, 0, -site.depth / 2)
				local line = `{math.round(r.X * 100)}:{math.round(r.Z * 100)}:{math.round(front:Dot(l))}`
				local list = lines[line] or {}
				table.insert(list, {
					line = line,
					along = awning.cframe.Position:Dot(r),
					colour = tostring(awning.color),
					name = piece.labels[1].text,
					id = key,
				})
				lines[line] = list
			end
			local problems: { string } = {}
			for _, list in lines do
				table.sort(list, function(a: Shop, b: Shop): boolean
					return a.along < b.along
				end)
				for i = 2, #list do
					local a, b = list[i - 1], list[i]
					if b.along - a.along <= 60 then
						if a.colour == b.colour then
							table.insert(problems, `{a.id} and {b.id}: one awning colour`)
						end
						if a.name == b.name then
							table.insert(problems, `{a.id} and {b.id}: both "{a.name}"`)
						end
					end
				end
			end
			report(t, "county neighbours", problems)
		end)
	end)

	parkedCarSpecs(t)
end
