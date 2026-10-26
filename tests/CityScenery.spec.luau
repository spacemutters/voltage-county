--!strict
-- The beach city's scenery (Dev/City/Scenery; docs/city/SCENERY.md; Config/CityScenery). Pure: builds nothing.
--   * Config/CityScenery makes sense: every rule's palm and lamp style exists, the stands' neighbours differ, the
--     beach's sand is the beach park's ground, the bay's bands run from the shore out
--   * palms are two parts (a trunk cars hit, a crown that clones its template), and the stand-in for a missing
--     template is decor fit to build
--   * the lifeguard stands, the causeway's pieces and the bay's water, each on its own
--   * the planner on a small hand-made county: the same parts every time, within its budget, every part fit to build
--     and filed in a registered container, night lights only in the lights tiles
--   * the real county: every group of scenery placed and within budget; scenery a car can hit never stands on a road,
--     a pad, a gameplay spot, a building or the way out of a pad, nor within 2 studs of a streetlight's post; the
--     promenade passes the causeway's piers; the causeway's balustrades, piers and lamps; the arches' gradient; palms
--     among the trees

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local CityScenery = require(ReplicatedStorage.Shared.Config.CityScenery)
local Environment = require(ReplicatedStorage.Shared.Config.Environment)
local Harness = require(ReplicatedStorage.Shared.Testing.Harness)
local MapLayout = require(ReplicatedStorage.Shared.Config.MapLayout)
local RoadGraph = require(ReplicatedStorage.Shared.Config.RoadGraph)

local Dev = ServerScriptService.Server.Dev
local Kit = require(Dev.City.Kit)
local LifeguardStand = require(Dev.City.Scenery.LifeguardStand)
local MapBuilder = require(Dev.MapBuilder)
local Palms = require(Dev.City.Scenery.Palms)
local Piece = require(Dev.City.Scenery.Piece)
local Scenery = require(Dev.City.Scenery)
local Types = require(Dev.City.Scenery.Types)

type PartSpec = MapBuilder.PartSpec
type Rect = Types.Rect

local Causeway = Scenery.Causeway
local Water = Scenery.Water
local NIGHT = Environment.nightLights
local TOLERANCE = 0.05

local function report(t: Harness.Api, label: string, problems: { string })
	if #problems > 0 then
		local shown = table.move(problems, 1, math.min(#problems, 8), 1, {})
		print(`  CityScenery.spec {label}: {#problems} problems, e.g. {table.concat(shown, "; ")}`)
	end
	t.expect(#problems).toBe(0)
end

---------------------------------------------------------------------------------------------------------------
-- Boxes: every part as its whole box (cylinders, balls and wedges too: a conservative check)
---------------------------------------------------------------------------------------------------------------

type Box = { spec: PartSpec, centre: Vector3, axes: { Vector3 }, half: { number }, min: Vector2, max: Vector2 }

local function boxOf(spec: PartSpec): Box
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

local function extent(box: Box, axis: Vector3): number
	return math.abs(box.axes[1]:Dot(axis)) * box.half[1]
		+ math.abs(box.axes[2]:Dot(axis)) * box.half[2]
		+ math.abs(box.axes[3]:Dot(axis)) * box.half[3]
end

-- How deep two boxes overlap (the least overlap over the separating axes), or 0 when they are apart.
local function depth(a: Box, b: Box): number
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
		local overlap = extent(a, axis) + extent(b, axis) - math.abs(d:Dot(axis))
		if overlap <= 0 then
			return 0
		end
		least = math.min(least, overlap)
	end
	return least
end

-- Every pair of a box in `list` and a box in `others` that overlap deeper than TOLERANCE, as "a x b depth".
local function overlaps(list: { Box }, others: { Box }): { string }
	local cell = 64
	local grid: { [number]: { Box } } = {}
	for _, box in others do
		for x = math.floor(box.min.X / cell), math.floor(box.max.X / cell) do
			for z = math.floor(box.min.Y / cell), math.floor(box.max.Y / cell) do
				local key = x * 65536 + z
				grid[key] = grid[key] or {}
				table.insert(grid[key], box)
			end
		end
	end
	local found: { string } = {}
	for _, box in list do
		local seen: { [Box]: boolean } = {}
		for x = math.floor(box.min.X / cell), math.floor(box.max.X / cell) do
			for z = math.floor(box.min.Y / cell), math.floor(box.max.Y / cell) do
				local bucket: { Box } = grid[x * 65536 + z] or {}
				for _, other in bucket do
					if not seen[other] and other ~= box then
						seen[other] = true
						local deep = depth(box, other)
						if deep > TOLERANCE then
							local a, b = box.spec, other.spec
							local shown = string.format("%.2f", deep)
							table.insert(found, `{a.folder}/{a.name} x {b.folder}/{b.name} {shown}`)
						end
					end
				end
			end
		end
	end
	return found
end

---------------------------------------------------------------------------------------------------------------
-- A small hand-made county for the planner
---------------------------------------------------------------------------------------------------------------

local function rectsOverlap(a: Rect, b: Rect, tolerance: number): boolean
	local function axesOf(r: Rect): { Vector2 }
		return { r.u, Vector2.new(-r.u.Y, r.u.X) }
	end
	local function reach(r: Rect, axis: Vector2): number
		local l = Vector2.new(-r.u.Y, r.u.X)
		return math.abs(r.u:Dot(axis)) * r.ha + math.abs(l:Dot(axis)) * r.hc
	end
	local least = math.huge
	for _, list in { axesOf(a), axesOf(b) } do
		for _, axis in list do
			local overlap = reach(a, axis) + reach(b, axis) - math.abs((b.c - a.c):Dot(axis))
			least = math.min(least, overlap)
		end
	end
	return least > tolerance
end

type Fixture = { host: Types.Host, specs: { PartSpec }, containers: { [string]: MapBuilder.Container } }

local function street(
	id: number,
	kind: string,
	zone: string,
	a: Vector2,
	b: Vector2,
	half: number,
	sidewalk: number,
	y: number?
): Types.Street
	local u = (b - a).Unit
	return {
		id = id,
		name = `S{id}`,
		kind = kind,
		fromZone = zone,
		toZone = zone,
		a = a,
		u = u,
		l = Vector2.new(-u.Y, u.X),
		length = (b - a).Magnitude,
		half = half,
		sidewalk = sidewalk,
		trimFrom = 10,
		trimTo = 10,
		fromRoads = 4,
		toRoads = 4,
		surface = function(_along: number): number
			return y or 0.2
		end,
	}
end

local function fixture(): Fixture
	local shapes: { { rect: Rect, kind: string } } = {}
	local specs: { PartSpec } = {}
	local containers: { [string]: MapBuilder.Container } = {}
	local lake: Types.Lake = {
		id = "bay",
		min = Vector2.new(-600, 1800),
		max = Vector2.new(600, 2300),
		waterY = -2,
		bedY = -12,
	}
	local streets = {
		street(1, "arterial", "cedar_bend", Vector2.new(-500, 0), Vector2.new(500, 0), 28, 10),
		street(2, "street", "cedar_bend", Vector2.new(-500, 300), Vector2.new(500, 300), 15, 8),
		street(3, "street", "lakefront", Vector2.new(-700, 1500), Vector2.new(700, 1500), 15, 0),
		street(4, "bridge", "lakefront", Vector2.new(0, 1500), Vector2.new(0, 2500), 27, 0, 20.2),
	}
	-- The roads in the grid, as MapBuilder puts them.
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
	local centre = (lake.min + lake.max) / 2
	local size = lake.max - lake.min
	table.insert(shapes, { rect = { c = centre, u = Vector2.xAxis, ha = size.X / 2, hc = size.Y / 2 }, kind = "lake" })
	local host: Types.Host = {
		seed = 1887,
		half = 5000,
		sidewalkRaise = 0.5,
		lineLift = 0.02,
		streets = streets,
		lakes = { lake },
		parks = {
			{ id = CityScenery.beach.park, min = Vector2.new(-650, 1650), max = Vector2.new(650, 1800) },
			{ id = CityScenery.townSquare.park, min = Vector2.new(-200, 40), max = Vector2.new(40, 260) },
		},
		groundAt = function(x: number, z: number): number
			if x > lake.min.X and x < lake.max.X and z > lake.min.Y and z < lake.max.Y then
				return lake.bedY
			end
			return 0
		end,
		blocked = function(rect: Rect, kinds: { [string]: boolean }, tolerance: number): boolean
			for _, shape in shapes do
				if kinds[shape.kind] and rectsOverlap(rect, shape.rect, tolerance) then
					return true
				end
			end
			return false
		end,
		reserve = function(rect: Rect, kind: string)
			table.insert(shapes, { rect = rect, kind = kind })
		end,
		add = function(spec: PartSpec)
			table.insert(specs, spec)
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
			error(`scenery left a note: {text}`)
		end,
	}
	return { host = host, specs = specs, containers = containers }
end

---------------------------------------------------------------------------------------------------------------
-- Specs
---------------------------------------------------------------------------------------------------------------

return function(t: Harness.Api)
	t.describe("CityScenery config", function()
		t.it("names a real palm and lamp style in every rule, and sizes that make sense", function()
			local problems: { string } = {}
			for name, species in Palms.species do
				if not (species.height > 0 and species.scale[1] > 0 and species.scale[1] <= species.scale[2]) then
					table.insert(problems, `{name}: height or scale`)
				end
				if not (species.crownFrom > 0 and species.crownFrom < species.crownTo) then
					table.insert(problems, `{name}: crown`)
				end
				if species.collider.X <= 0 or species.collider.Y <= 0 or species.crown <= 0 then
					table.insert(problems, `{name}: collider or crown`)
				end
			end
			for i, rule in CityScenery.streetPalms.rules do
				if Palms.species[rule.species] == nil then
					table.insert(problems, `streetPalms rule {i}: no palm {rule.species}`)
				end
				if rule.spacing <= 0 then
					table.insert(problems, `streetPalms rule {i}: spacing`)
				end
			end
			if Palms.species[CityScenery.townSquare.allee.species] == nil then
				table.insert(problems, "townSquare: no palm for the allée")
			end
			for kind, name in CityScenery.lamps.byKind do
				if (CityScenery.lamps :: any)[name] == nil then
					table.insert(problems, `lamps.byKind {kind}: no style {name}`)
				end
			end
			for zone, kinds in CityScenery.lamps.byZone do
				for kind, name in kinds do
					if (CityScenery.lamps :: any)[name] == nil then
						table.insert(problems, `lamps.byZone {zone} {kind}: no style {name}`)
					end
				end
			end
			-- Every tree mix names a palm or a block tree MapBuilder knows.
			for mixName, list in Environment.trees.mixes do
				for _, entry in list do
					local known = Palms.species[entry.species] ~= nil
						or MapBuilder.TUNING.treeSpecies[entry.species] ~= nil
					if not known then
						table.insert(problems, `trees.mixes {mixName}: no species {entry.species}`)
					end
				end
			end
			report(t, "config", problems)
		end)

		t.it("gives neighbouring lifeguard stands different shapes and colours", function()
			local lifeguard = CityScenery.lifeguard
			local count = CityScenery.beach.stands
			for k = 2, count do
				local shapeA = lifeguard.shapes[(k - 2) % #lifeguard.shapes + 1]
				local shapeB = lifeguard.shapes[(k - 1) % #lifeguard.shapes + 1]
				local schemeA = ((k - 2) * 3) % #lifeguard.schemes + 1
				local schemeB = ((k - 1) * 3) % #lifeguard.schemes + 1
				t.expect(shapeA ~= shapeB).toBe(true)
				t.expect(schemeA ~= schemeB).toBe(true)
			end
		end)

		t.it("lays the beach on the beach park's own sand, and runs the bay's bands from the shore out", function()
			for _, park in MapLayout.parks do
				if park.id == CityScenery.beach.park then
					t.expect(park.groundColor).toBe(CityScenery.beach.sand)
				end
			end
			local last = 0
			for _, band in CityScenery.water.bands do
				t.expect(band.width > last).toBe(true)
				t.expect(band.transparency >= 0 and band.transparency < 1).toBe(true)
				last = band.width
			end
		end)
	end)

	t.describe("Palms", function()
		local rolls: Palms.Rolls = { scale = 0.5, yaw = 0.25, lean = 0.5, variant = 0.9 }
		t.it("are a trunk cars hit and a crown that clones its template", function()
			for name in Palms.species do
				local trunk, crown = Palms.specs("Trees/Tile0_0", "P", "tree", name, Vector3.new(10, 0, 20), 1, rolls)
				t.expect(trunk.name).toBe("PTrunk")
				t.expect(trunk.collide and trunk.query).toBe(true)
				t.expect(trunk.transparency).toBe(1)
				t.expect(crown.collide or crown.query or crown.touch).toBe(false)
				local template = crown.template
				t.expect(template ~= nil).toBe(true)
				if template then
					t.expect(template.path[#template.path]).toBe(name)
					t.expect(template.fallback).toBe(name)
					t.expect(template.height).toBeGreaterThan(0)
					t.expect(template.variant >= 1 and template.variant <= CityScenery.palms.variants).toBe(true)
				end
				t.expect(Kit.problem(trunk)).toBe(nil)
				t.expect(Kit.problem(crown)).toBe(nil)
				-- The same draws make the same palm.
				local again = Palms.specs("Trees/Tile0_0", "P", "tree", name, Vector3.new(10, 0, 20), 1, rolls)
				t.expect(again.cframe == trunk.cframe).toBe(true)
			end
		end)

		t.it("stand in as decor fit to build while a template is missing", function()
			for name in Palms.species do
				local _, crown = Palms.specs("Trees/Tile0_0", "P", "tree", name, Vector3.new(0, 0, 0), 0, rolls)
				local template = crown.template :: Types.TemplateSpec
				local parts = Palms.fallback(template, "Trees/Tile0_0", "PCrown")
				t.expect(#parts).toBeGreaterThan(4)
				t.expect(#parts <= 12).toBe(true)
				for _, part in parts do
					t.expect(Kit.problem(part)).toBe(nil)
					t.expect(part.collide or part.query or part.touch).toBe(false)
					local top = part.cframe.Y + part.size.Magnitude / 2
					t.expect(top < template.height * 1.4).toBe(true)
				end
			end
		end)

		t.it("find no template on a path that isn't there", function()
			t.expect(Palms.findTemplate({ "NoSuchFolder", "Palms", "royal" }, 1)).toBe(nil)
		end)
	end)

	t.describe("Lifeguard stands", function()
		t.it("build every shape in every scheme, fit to build, solid where a player stands", function()
			local problems: { string } = {}
			local lifeguard = CityScenery.lifeguard
			for s, shape in lifeguard.shapes do
				for c, scheme in lifeguard.schemes do
					local frame = CFrame.new(100, 0, 200)
					local m = Piece.model(`Guard{s}{c}`, frame, 1)
					LifeguardStand.build(m, shape, scheme, s)
					local glass, deck = false, false
					if #m.specs > 26 then
						table.insert(problems, `{shape}: {#m.specs} parts`)
					end
					for _, spec in m.specs do
						local problem = Kit.problem(spec)
						if problem then
							table.insert(problems, problem)
						end
						glass = glass or spec.material == Enum.Material.Glass
						deck = deck or (string.find(spec.name, "Deck$") ~= nil and spec.collide)
						local lo, hi = Kit.localBounds(frame, spec)
						-- The footprint follows the config: the ramp runs back from the platform's back edge, and the
						-- roofs, fins and flag stand at most 19 over the deck.
						local zMax = lifeguard.platform.Z / 2 + lifeguard.ramp.length + 1
						local yMax = lifeguard.deck + 19
						if lo.X < -8 or hi.X > 8 or lo.Z < -8 or hi.Z > zMax or hi.Y > yMax or lo.Y < -1.01 then
							table.insert(problems, `{shape} {spec.name}: outside the stand's footprint`)
						end
					end
					if not glass or not deck then
						table.insert(problems, `{shape} {c}: no window or no solid deck`)
					end
				end
			end
			report(t, "stands", problems)
		end)
	end)

	t.describe("Causeway pieces", function()
		t.it("make a balustrade that stops a car, with its glow strip", function()
			local parts, inner, outer, glow = Causeway.balustrade("Bridges", "R", CFrame.new(0, 20, 0), 100, 27, 1)
			t.expect(#parts).toBe(5)
			t.expect(inner < 27 and outer > 27).toBe(true)
			local solid = 0
			for _, part in parts do
				t.expect(Kit.problem(part)).toBe(nil)
				if part.collide then
					solid += 1
				end
			end
			t.expect(solid).toBe(3)
			t.expect(table.find(parts, glow) ~= nil).toBe(true)
			t.expect(glow.collide).toBe(false)
		end)

		t.it("run the arches' gradient from the feet to the crown", function()
			local colors = CityScenery.causeway.arches.gradient
			local foot = Causeway.ribColor(1, 12)
			local crown = Causeway.ribColor(6, 12)
			local function far(a: Color3, b: Color3): number
				return math.abs(a.R - b.R) + math.abs(a.G - b.G) + math.abs(a.B - b.B)
			end
			t.expect(far(foot, colors[1]) < far(foot, colors[#colors])).toBe(true)
			t.expect(far(crown, colors[#colors]) < far(crown, colors[1])).toBe(true)
			t.expect(far(Causeway.ribColor(1, 12), Causeway.ribColor(12, 12)) < 1e-6).toBe(true)
		end)

		t.it("spring four haunches per span from the caps", function()
			local parts =
				Causeway.haunches("Bridges", "A", Vector2.new(0, 0), Vector2.new(0, 80), Vector2.xAxis, 26, 19)
			t.expect(#parts).toBe(4)
			for _, part in parts do
				t.expect(Kit.problem(part)).toBe(nil)
				t.expect(part.cframe.Y + part.size.Y / 2 < 19).toBe(true)
			end
		end)
	end)

	t.describe("The bay", function()
		local lake: Types.Lake =
			{ id = "bay", min = Vector2.new(-600, 1800), max = Vector2.new(600, 2300), waterY = -2, bedY = -12 }
		local beach: Types.Park =
			{ id = CityScenery.beach.park, min = Vector2.new(-650, 1650), max = Vector2.new(650, 1800) }
		local bridge = street(9, "bridge", "lakefront", Vector2.new(0, 1500), Vector2.new(0, 2600), 27, 0, 20.2)
		local parts = Water.plan(lake, { bridge }, { beach })

		t.it("lays bands of water at the water line that never overlap, and nothing collides with them", function()
			local sheets: { Box } = {}
			for _, part in parts do
				t.expect(part.collide or part.query or part.touch).toBe(false)
				t.expect(Kit.problem(part)).toBe(nil)
				if part.role == "water" and string.find(part.name, "Band") then
					t.expect(part.cframe.Y + part.size.Y / 2).toBeNear(lake.waterY, 1e-6)
					table.insert(sheets, boxOf(part))
				end
			end
			t.expect(#sheets).toBeGreaterThan(4)
			report(t, "bands", overlaps(sheets, sheets))
		end)

		t.it("puts a wash on the beach shore only and coping on the others, broken at the bridge", function()
			local wash, coping, north = 0, 0, 0
			for _, part in parts do
				if string.find(part.name, "Wash") then
					wash += 1
					t.expect(part.cframe.Z < lake.min.Y + 20).toBe(true)
				elseif string.find(part.name, "Coping") then
					coping += 1
					if part.cframe.Z < lake.min.Y then
						north += 1
					end
					-- Never across the bridge's line.
					local half = part.size.X / 2
					local crosses = math.abs(part.cframe.Z - lake.max.Y) < 5 and math.abs(part.cframe.X) < half
					t.expect(crosses).toBe(false)
				end
			end
			t.expect(wash).toBe(1)
			t.expect(north).toBe(0)
			t.expect(coping).toBe(4) -- west, east, and the south shore in two
		end)
	end)

	t.describe("The planner on a small county", function()
		t.it("plans the same parts every time, within its budget, fit to build and filed", function()
			local a, b = fixture(), fixture()
			local reportA = Scenery.plan(a.host)
			local reportB = Scenery.plan(b.host)
			t.expect(#a.specs).toBe(#b.specs)
			for i, spec in a.specs do
				local other = b.specs[i]
				t.expect(other.name).toBe(spec.name)
				t.expect(other.cframe == spec.cframe).toBe(true)
			end
			t.expect(reportA.total).toBe(reportB.total)
			t.expect(reportA.total <= CityScenery.budget.streetscapeParts).toBe(true)
			print(`  CityScenery.spec fixture: {#a.specs} parts`)
			local problems: { string } = {}
			local names: { [string]: boolean } = {}
			for _, spec in a.specs do
				local problem = Kit.problem(spec)
				if problem then
					table.insert(problems, problem)
				end
				local key = `{spec.folder}/{spec.name}`
				if names[key] then
					table.insert(problems, `{key}: twice`)
				end
				names[key] = true
				local entry = a.containers[spec.folder]
				if entry == nil or entry.streaming ~= Enum.ModelStreamingMode.Atomic then
					table.insert(problems, `{key}: not in an Atomic container`)
				end
				local lights = string.find(spec.folder, "^StreetscapeLights/") ~= nil
				if (spec.tag == NIGHT.tag) ~= lights then
					table.insert(problems, `{key}: a night light outside the lights tiles, or a still part in them`)
				end
				if spec.light then
					table.insert(problems, `{key}: a Light in the scenery`)
				end
			end
			report(t, "fixture", problems)
			t.expect((reportA.beach or 0) > 0 and (reportA.avenuePalms or 0) > 0).toBe(true)
			t.expect((reportA.causewayPalms or 0) > 0 and (reportA.square or 0) > 0).toBe(true)
		end)
	end)

	t.describe("The county's scenery", function()
		-- Planned once for every case below (a county plan takes a while in Edit mode).
		local plan = MapBuilder.county()
		local scenery: { PartSpec } = {}
		for _, spec in plan.specs do
			if spec.role == "scenery" or string.find(spec.folder, "^Streetscape") then
				table.insert(scenery, spec)
			end
		end

		t.it("places every group within its budget", function()
			local groups: { string } = {}
			for group, count in plan.scenery do
				table.insert(groups, `{group} {count}`)
			end
			table.sort(groups)
			print(`  CityScenery.spec: {table.concat(groups, ", ")}`)
			local budget = CityScenery.budget
			local streetscape, water = 0, 0
			for _, spec in plan.specs do
				if string.find(spec.folder, "^Streetscape") then
					streetscape += 1
				elseif spec.folder == "Water" then
					water += 1
				end
			end
			t.expect(streetscape <= budget.streetscapeParts).toBe(true)
			t.expect(water <= budget.waterParts).toBe(true)
			t.expect((plan.counts.support or 0) <= budget.bridgeParts).toBe(true)
			for _, group in
				{ "causewayPalms", "beach", "square", "avenuePalms", "shelters", "crosswalks", "streetPalms" }
			do
				t.expect((plan.scenery[group] or 0) > 0).toBe(true)
			end
		end)

		t.it("makes every scenery part fit to build, its night lights in the lights tiles", function()
			local problems: { string } = {}
			for _, spec in scenery do
				local problem = Kit.problem(spec)
				if problem then
					table.insert(problems, problem)
				end
				if string.find(spec.folder, "^Streetscape/") and (spec.tag == NIGHT.tag or spec.light) then
					table.insert(problems, `{spec.folder}/{spec.name}: a night light in a still tile`)
				end
			end
			report(t, "scenery", problems)
		end)

		t.it("keeps what a car can hit off roads, pads, spots, buildings and the way out of every pad", function()
			local solid: { Box } = {}
			for _, spec in scenery do
				if spec.collide and spec.role ~= "line" then
					table.insert(solid, boxOf(spec))
				end
			end
			local blockers: { Box } = {}
			local kinds: { [string]: boolean } = {
				road = true,
				pad = true,
				location = true,
				displayPad = true,
				building = true,
				landmark = true,
				spawn = true,
				prop = true,
				sign = true,
				billboard = true,
				feature = true,
				support = true,
			}
			for _, spec in plan.specs do
				if kinds[spec.role] then
					table.insert(blockers, boxOf(spec))
				end
			end
			-- The way out of each pad to its road: a box as wide as the pad, from it to the nearest road point.
			local byId: { [string]: Vector3 } = {}
			for _, node in RoadGraph.nodes do
				byId[node.id] = node.position
			end
			local volumes = { FlightZone = true, NoFlyZone = true, DragStripGate = true }
			for _, location in MapLayout.locations do
				if volumes[location.tag] then
					continue
				end
				local c = Vector2.new(location.position.X, location.position.Z)
				local best, road = math.huge, c
				for _, edge in RoadGraph.edges do
					local a3, b3 = byId[edge.from], byId[edge.to]
					local a, b = Vector2.new(a3.X, a3.Z), Vector2.new(b3.X, b3.Z)
					local along = math.clamp((c - a):Dot((b - a).Unit), 0, (b - a).Magnitude)
					local point = a + (b - a).Unit * along
					if (point - c).Magnitude < best then
						best, road = (point - c).Magnitude, point
					end
				end
				if best < 1 then
					continue
				end
				local way = road - c
				local middle = (c + road) / 2
				local centre = Vector3.new(middle.X, location.position.Y + 3.5, middle.Y)
				table.insert(
					blockers,
					boxOf({
						folder = "Exit",
						name = location.id,
						class = "Part",
						shape = "block",
						role = "location",
						size = Vector3.new(location.size.X, 6, way.Magnitude),
						cframe = CFrame.lookAt(centre, centre + Vector3.new(way.X, 0, way.Y)),
						color = Color3.new(),
						material = Enum.Material.SmoothPlastic,
						collide = false,
						query = false,
						touch = false,
						shadow = false,
						transparency = 1,
					})
				)
			end
			report(t, "solid scenery", overlaps(solid, blockers))
		end)

		t.it("keeps every palm's trunk and every street piece 2 studs from a streetlight's post", function()
			local posts: { Box } = {}
			for _, spec in plan.specs do
				if spec.role == "light" and spec.collide then
					local box = boxOf(spec)
					-- Grown by 2 studs across, so a trunk within 2 studs of a post overlaps it.
					box.half = { box.half[1] + 2, box.half[2], box.half[3] + 2 }
					box.min -= Vector2.one * 2.9
					box.max += Vector2.one * 2.9
					table.insert(posts, box)
				end
			end
			local trunks: { Box } = {}
			for _, spec in scenery do
				if spec.collide and spec.role ~= "line" then
					table.insert(trunks, boxOf(spec))
				end
			end
			report(t, "near a streetlight", overlaps(trunks, posts))
		end)

		t.it("hangs no street palm's crown over a road lower than the frond clearance", function()
			-- A crown as a round disc in plan (its spread) from its box's bottom up; a road part as its plan rectangle
			-- and its highest top. A crown over a road must start `clearance` above it.
			local clearance = CityScenery.streetPalms.frondClearance
			type Road = { c: Vector2, u: Vector2, ha: number, hc: number, top: number, spec: PartSpec }
			local roads: { Road } = {}
			for _, spec in plan.specs do
				if spec.role == "road" or spec.role == "pad" then
					local look = Vector2.new(spec.cframe.LookVector.X, spec.cframe.LookVector.Z)
					local rise = math.abs(spec.cframe.LookVector.Y) * spec.size.Z / 2
					table.insert(roads, {
						c = Vector2.new(spec.cframe.X, spec.cframe.Z),
						u = if look.Magnitude > 1e-6 then look.Unit else Vector2.yAxis,
						ha = spec.size.Z / 2,
						hc = spec.size.X / 2,
						top = spec.cframe.Y + spec.size.Y / 2 + rise,
						spec = spec,
					})
				end
			end
			local problems: { string } = {}
			for _, spec in scenery do
				if spec.template == nil then
					continue
				end
				local c = Vector2.new(spec.cframe.X, spec.cframe.Z)
				local r = spec.size.X / 2
				local bottom = spec.cframe.Y - spec.size.Y / 2
				for _, road in roads do
					if (road.c - c).Magnitude > r + road.ha + road.hc then
						continue
					end
					local d = c - road.c
					local l = Vector2.new(-road.u.Y, road.u.X)
					local along = math.clamp(d:Dot(road.u), -road.ha, road.ha)
					local across = math.clamp(d:Dot(l), -road.hc, road.hc)
					local nearest = road.c + road.u * along + l * across
					if (nearest - c).Magnitude < r - TOLERANCE and bottom < road.top + clearance then
						table.insert(
							problems,
							`{spec.folder}/{spec.name} over {road.spec.name} at {math.round(bottom)}`
						)
						break
					end
				end
			end
			report(t, "low crown", problems)
		end)

		t.it("runs the promenade under the causeway clear of its piers", function()
			local walks: { Box } = {}
			local piers: { Box } = {}
			for _, spec in plan.specs do
				if string.find(spec.name, "^BeachWalk") then
					table.insert(walks, boxOf(spec))
				elseif spec.role == "support" and string.find(spec.name, "Pillar") then
					table.insert(piers, boxOf(spec))
				end
			end
			t.expect(#walks).toBeGreaterThan(0)
			report(t, "walk", overlaps(walks, piers))
		end)

		t.it("dresses the causeway: balustrades, round piers, arched spans, lamps and the arches' gradient", function()
			local balustrades, round, haunches, lamps = 0, 0, 0, 0
			local colors: { [string]: boolean } = {}
			local distinct = 0
			for _, spec in plan.specs do
				if spec.role == "support" and string.find(spec.name, ":Rail[LR]Coping$") then
					balustrades += 1
				elseif spec.role == "support" and string.find(spec.name, "Pillar") and spec.shape == "cylinder" then
					round += 1
				elseif spec.role == "support" and string.find(spec.name, ":Arch%d") then
					haunches += 1
				elseif spec.role == "light" and string.find(spec.name, "^CausewayLamp%d+Head$") then
					lamps += 1
				end
				if string.find(spec.folder, "^Features/") and string.find(spec.name, "^Rib") then
					local attributes: { [string]: any } = spec.attributes or {}
					local color = attributes[NIGHT.nightColorAttribute]
					t.expect(typeof(color)).toBe("Color3")
					local key = tostring(color)
					if not colors[key] then
						colors[key] = true
						distinct += 1
					end
				end
			end
			print(
				`  CityScenery.spec causeway: {balustrades} balustrades, {round} piers, {haunches} haunches, {lamps} lamps`
			)
			t.expect(balustrades).toBeGreaterThan(5)
			t.expect(round).toBeGreaterThan(5)
			t.expect(haunches).toBeGreaterThan(8)
			t.expect(lamps).toBeGreaterThan(10)
			t.expect(distinct).toBeGreaterThan(2)
		end)

		t.it("plants palms among the trees, and lines the beach with lifeguard stands", function()
			local palms, stands = 0, 0
			local guards: { [string]: boolean } = {}
			for _, spec in plan.specs do
				if spec.role == "tree" and spec.template then
					palms += 1
				end
				local guard = string.match(spec.name, "^Guard%d+")
				if guard and not guards[guard] then
					guards[guard] = true
					stands += 1
				end
			end
			print(`  CityScenery.spec: {palms} palms among the trees, {stands} lifeguard stands`)
			t.expect(palms).toBeGreaterThan(100)
			t.expect(stands >= CityScenery.beach.stands - 2).toBe(true)
		end)
	end)
end
