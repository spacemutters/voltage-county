--!strict
-- The Miami city builder (Dev/City; docs/city/CITY_PLAN.md, docs/city/ARCHETYPE_GUIDE.md). Pure: builds nothing.
--   * Config/City and the archetype index agree, and every archetype's placement numbers make sense
--   * every Kit primitive makes parts fit to build, where it was asked to, mirrored when the site is, with the
--     right collision and shadow for its kind, and night lights of known kinds
--   * every archetype, on sample sites across its sizes and heights, with several seeds and every variant, stays
--     inside its footprint and height and within its part budget, has glass and reaches its roof, and builds the
--     same parts every time
--   * placement: the same sites every time; sites only merge neighbouring plots of one run, within an archetype's
--     widths and maxPlots; one archetype never stands beside itself; copies, spacing and per-block limits hold;
--     heights follow the downtown block caps and stay low near gameplay spots; zones with no district keep the old
--     look

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local City = require(ReplicatedStorage.Shared.Config.City)
local Environment = require(ReplicatedStorage.Shared.Config.Environment)
local Harness = require(ReplicatedStorage.Shared.Testing.Harness)

local CityFolder = ServerScriptService.Server.Dev.City
local CityBuilder = require(CityFolder.CityBuilder)
local Index = require(CityFolder.Archetypes.Index)
local Kit = require(CityFolder.Kit)
local Types = require(CityFolder.Types)

type PartSpec = Types.PartSpec
type Plot = Types.Plot
type Site = Types.Site
type Variant = Types.Variant

local SEEDS = { 1, 77, 4242 }
local SIDES: { Kit.Side } = { "front", "back", "left", "right" }
local CORNERS: { Kit.PrismCorner } = { "fl", "fr", "bl", "br" }
local DEPTH = 53 -- a full plot (MapBuilder TUNING.setbackMax + depthMax)
local EPS = 0.01

local function report(t: Harness.Api, label: string, problems: { string })
	if #problems > 0 then
		local shown = table.move(problems, 1, math.min(#problems, 8), 1, {})
		print(`  City.spec {label}: {#problems} problems, e.g. {table.concat(shown, "; ")}`)
	end
	t.expect(#problems).toBe(0)
end

local function sample(archetype: string, width: number, depth: number, height: number, variant: Variant, seed: number)
	local frame = CFrame.new(1000, 0, -500) * CFrame.Angles(0, math.rad(30), 0)
	return CityBuilder.sampleSite(archetype, frame, width, depth, height, variant, seed, "Buildings/Sample")
end

-- A plot for placement fixtures: on a road running along +x at z = 0, `side` 1 south of it, -1 north.
local function plot(index: number, frontage: string, along: number, width: number, zone: string, at: Vector2?): Plot
	local origin = at or Vector2.zero
	return {
		index = index,
		frontage = frontage,
		block = 1,
		along = along,
		width = width,
		plotDepth = DEPTH,
		frontStart = origin + Vector2.new(along, 30),
		u = Vector2.xAxis,
		away = Vector2.yAxis,
		zone = zone,
		tall = (index * 37 % 100) / 100,
		nearSpot = false,
		shade = (index * 7919) % 1000000,
		folder = "Buildings/Block1",
		center = origin + Vector2.new(along + width / 2, 60),
		buildingDepth = 30,
		buildingWidth = width - 5,
		height = 40,
		color = Color3.new(1, 1, 1),
	}
end

-- A long frontage of plots `width` wide, all in one run.
local function run(count: number, frontage: string, width: number, zone: string, first: number, at: Vector2?): { Plot }
	local plots: { Plot } = {}
	for i = 1, count do
		table.insert(plots, plot(first + i - 1, frontage, (i - 1) * width, width, zone, at))
	end
	return plots
end

local function concat(...: { Plot }): { Plot }
	local out: { Plot } = {}
	for _, list in { ... } do
		for _, p in list do
			table.insert(out, p)
		end
	end
	return out
end

return function(t: Harness.Api)
	t.describe("City config and archetype index", function()
		t.it("has a module for every Config/City archetype and a Config/City entry for every module", function()
			local problems: { string } = {}
			for id in City.archetypes do
				if Index.byId[id] == nil then
					table.insert(problems, `{id}: no module in Archetypes/Index`)
				end
			end
			for _, archetype in Index.list do
				if City.archetypes[archetype.id] == nil then
					table.insert(problems, `{archetype.id}: no entry in Config/City archetypes`)
				end
			end
			report(t, "index", problems)
		end)

		t.it("gives every archetype placement numbers that make sense", function()
			local districts: { [string]: boolean } = {}
			for _, district in City.districts do
				districts[district] = true
			end
			local problems: { string } = {}
			for id, c in City.archetypes do
				local function need(ok: boolean, what: string)
					if not ok then
						table.insert(problems, `{id}: {what}`)
					end
				end
				need(districts[c.district] == true and City.districtLooks[c.district] ~= nil, "unknown district")
				need(c.weight >= 0 and c.maxCopies >= 1 and c.perBlock >= 1, "weights and copies")
				need(c.minWidth > 0 and c.minWidth <= c.maxWidth, "widths")
				need(c.minDepth > 0 and c.minDepth <= DEPTH, "depth deeper than a plot")
				need(c.maxPlots >= 1, "maxPlots")
				need(c.heights.min > 0 and c.heights.min <= c.heights.max, "heights")
				need(c.crownMax >= 0 and c.budget > 0, "crown or budget")
				need(c.palettes >= 1 and c.crowns >= 1 and c.rhythms >= 1, "variants")
				need(string.match(id, "^[a-z_]+$") ~= nil, "id not snake_case")
			end
			report(t, "config", problems)
		end)
	end)

	t.describe("City Kit", function()
		local function model(mirror: boolean): Types.Model
			local site =
				sample("deco_stripe_hotel", 60, DEPTH, 50, { palette = 1, crown = 1, rhythm = 1, mirror = mirror }, 1)
			return Kit.model(site)
		end
		local white = Kit.look(Color3.new(1, 1, 1), Enum.Material.SmoothPlastic)

		-- Every primitive once, on a model; returns its specs.
		local function everything(m: Types.Model): { PartSpec }
			Kit.box(m, "Box", Vector3.new(-10, -1, -5), Vector3.new(4, 20, 8), white)
			Kit.trim(m, "Trim", Vector3.new(-10, 5, -6), Vector3.new(4, 5.6, -5), white)
			Kit.detail(m, "Detail", Vector3.new(-1, 0, -6), Vector3.new(-0.7, 12, -5.7), white)
			Kit.column(m, "Column", 3, 2, 0, 18, 4, white)
			Kit.disc(m, "Disc", 3, 2, 18.5, 6, 0.5, white)
			Kit.tube(m, "TubeX", Vector3.new(-5, 3, -7), Vector3.new(5, 3, -7), 0.6, white)
			Kit.tube(m, "TubeY", Vector3.new(-5, 3, -7), Vector3.new(-5, 9, -7), 0.6, white)
			Kit.tube(m, "TubeZ", Vector3.new(-5, 3, -7), Vector3.new(-5, 3, 1), 0.6, white)
			Kit.ball(m, "Ball", Vector3.new(0, 25, 0), 2, white)
			for _, rise in SIDES do
				Kit.wedge(m, `Wedge{rise}`, Vector3.new(-4, 20, -4), Vector3.new(2, 23, 4), rise :: Kit.Side, white)
			end
			Kit.neon(m, "Neon", Vector3.new(-3, 10, -6), Vector3.new(3, 10, -6), "neonPink", Color3.new(1, 0.7, 0.8))
			Kit.neonStrip(m, "Strip", Vector3.new(-3, 11, -6.2), Vector3.new(3, 11.4, -6), "ledBlue", white.color)
			Kit.wash(m, "Wash", -6, 6, -9, 1, Color3.new(1, 0.5, 0.8))
			Kit.glass(m, "Glass", Vector3.new(-6, 1, -5.3), Vector3.new(6, 6, -5), Color3.new(0.2, 0.3, 0.4), {
				image = City.textures.windowFine,
				faces = { Enum.NormalId.Front, Enum.NormalId.Left },
				lit = true,
			})
			Kit.punched(
				m,
				"Punched",
				Vector3.new(-10.4, 6, 0),
				Vector3.new(-10, 28, 8),
				Color3.new(1, 1, 1),
				Color3.new(0.2, 0.3, 0.4),
				{ Enum.NormalId.Left },
				6,
				11
			)
			Kit.roundedBox(
				m,
				"Round",
				Vector3.new(-12, 0, 10),
				Vector3.new(12, 10, 20),
				4,
				{ fl = true, br = true },
				white
			)
			Kit.band(
				m,
				"Band",
				Vector3.new(-12, 0, 10),
				Vector3.new(12, 0, 20),
				4,
				{ fl = true, fr = true },
				6,
				0.6,
				2,
				white,
				"front"
			)
			Kit.band(
				m,
				"Ring",
				Vector3.new(-12, 0, 10),
				Vector3.new(12, 0, 20),
				4,
				{ fl = true },
				8,
				0.6,
				2,
				white,
				"around"
			)
			Kit.plates(m, "Plate", Vector3.new(-5, 0, -2), Vector3.new(5, 0, 2), 12, 40, 12, 1, 1, 3, white, white)
			Kit.setbacks(
				m,
				"Step",
				Vector3.new(-6, 0, -6),
				Vector3.new(6, 30, 6),
				{ { rise = 3, inset = 1 }, { rise = 3, inset = 1 } },
				white
			)
			for _, side in SIDES do
				Kit.fins(m, `Fin{side}`, side :: Kit.Side, 0, -4, 4, 3, 0, 10, 2, 0.6, white)
			end
			Kit.porthole(m, "Port", 0, 14, -6, 3, Color3.new(0.1, 0.2, 0.3), white, "neonAmber")
			Kit.parapet(m, "Parapet", Vector3.new(-8, 0, -8), Vector3.new(8, 0, 8), 30, 3, 0.8, white)
			local tiers = { { width = 12, depth = 12, height = 4 }, { width = 8, depth = 8, height = 4 } }
			local _, crownTop =
				Kit.steppedCrown(m, "Crown", 0, 0, 34, tiers, white, { kind = "crown", color = white.color })
			t.expect(crownTop).toBe(42)
			Kit.spire(m, "Spire", 0, 0, 30, 12, 1.2, white, 3, true)
			Kit.sign(
				m,
				"Sign",
				Vector3.new(-4, 15, -6.5),
				Vector3.new(4, 17, -6.1),
				Enum.NormalId.Front,
				"SIGN",
				white.color,
				Color3.new(0, 0, 0),
				Enum.Font.JosefinSans,
				"sign"
			)
			Kit.canopy(m, "Canopy", -5, 5, -26, -18, 12, 0.8, white)
			Kit.pool(m, "Pool", Vector3.new(-5, 0, -4), Vector3.new(5, 0, 4), 20)
			Kit.planter(m, "Planter", Vector3.new(-2, 20, 5), Vector3.new(2, 21.5, 6), white)
			Kit.umbrella(m, "Umbrella", 4, -15, 0.5, 6, Color3.new(1, 0.6, 0.7))
			Kit.umbrella(m, "Market", -4, -15, 0.5, 6, Color3.new(1, 0.6, 0.7), true)
			Kit.roofBox(m, "Roof", Vector3.new(-2, 30, -2), Vector3.new(2, 34, 2))
			Kit.podium(m, "Podium", Vector3.new(-8, 0, -8), Vector3.new(8, 30, 8), 3, 3, 0.4, white, white)
			for _, corner in CORNERS do
				Kit.prism(m, `Prism{corner}`, Vector3.new(-6, 0, 10), Vector3.new(2, 9, 16), corner, white)
				Kit.cornerWedge(m, `CornerWedge{corner}`, Vector3.new(-6, 0, 10), Vector3.new(2, 9, 16), corner, white)
			end
			for _, wall in SIDES do
				Kit.corbel(m, `Corbel{wall}`, Vector3.new(-6, 0, 10), Vector3.new(2, 9, 16), wall, white)
			end
			Kit.hipRoof(m, "Hip", Vector3.new(-10, 20, -6), Vector3.new(10, 26, 6), 1.5, 0.5, white)
			Kit.gableRoof(m, "Gable", Vector3.new(-10, 20, -6), Vector3.new(10, 26, 6), "x", 1.5, 0.5, white, white)
			Kit.archHead(m, "Arch", -3, 3, 9, -6, -4.6, 2.4, white)
			Kit.archWindow(m, "ArchWindow", -2, 2, 12, 16, -6, Color3.new(0.2, 0.3, 0.4), { lit = true })
			return m.specs
		end

		t.it("makes parts fit to build, named, filed and tagged as the site's", function()
			local problems: { string } = {}
			for _, mirror in { false, true } do
				local m = model(mirror)
				for _, spec in everything(m) do
					local problem = Kit.problem(spec)
					if problem then
						table.insert(problems, problem)
					end
					if string.sub(spec.name, 1, 2) ~= "B0" or spec.folder ~= m.folder or spec.role ~= "building" then
						table.insert(problems, `{spec.name}: not the site's`)
					end
				end
				t.expect(#m.specs).toBeGreaterThan(60)
			end
			report(t, "kit", problems)
		end)

		t.it("puts a box where it was asked, and its mirror image when the site is mirrored", function()
			for _, mirror in { false, true } do
				local m = model(mirror)
				local spec = Kit.box(m, "Probe", Vector3.new(-10, -1, -5), Vector3.new(4, 20, 8), white)
				local lo, hi = Kit.localBounds(m.frame, spec)
				local x0, x1 = if mirror then -4 else -10, if mirror then 10 else 4
				t.expect(lo.X).toBeNear(x0, EPS)
				t.expect(hi.X).toBeNear(x1, EPS)
				t.expect(lo.Y).toBeNear(-1, EPS)
				t.expect(hi.Y).toBeNear(20, EPS)
				t.expect(lo.Z).toBeNear(-5, EPS)
				t.expect(hi.Z).toBeNear(8, EPS)
			end
		end)

		t.it("stands columns up, lays tubes along their axis and fills a wedge's box", function()
			local m = model(false)
			local column = Kit.column(m, "C", 3, 2, 0, 18, 4, white)
			local lo, hi = Kit.localBounds(m.frame, column)
			t.expect(hi.Y - lo.Y).toBeNear(18, EPS)
			t.expect(hi.X - lo.X).toBeNear(4, EPS)
			local tube = Kit.tube(m, "T", Vector3.new(-5, 3, -7), Vector3.new(-5, 3, 1), 0.6, white)
			lo, hi = Kit.localBounds(m.frame, tube)
			t.expect(hi.Z - lo.Z).toBeNear(8, EPS)
			for _, rise in SIDES do
				local wedge =
					Kit.wedge(m, `W{rise}`, Vector3.new(-4, 20, -4), Vector3.new(2, 23, 6), rise :: Kit.Side, white)
				lo, hi = Kit.localBounds(m.frame, wedge)
				t.expect(lo.X).toBeNear(-4, EPS)
				t.expect(hi.X).toBeNear(2, EPS)
				t.expect(lo.Z).toBeNear(-4, EPS)
				t.expect(hi.Z).toBeNear(6, EPS)
			end
		end)

		t.it("stands a prism in its box with its square corner where asked, mirrored with the site", function()
			for _, mirror in { false, true } do
				local m = model(mirror)
				for _, corner in CORNERS do
					local spec = Kit.prism(m, `P{corner}`, Vector3.new(-6, 0, 10), Vector3.new(2, 9, 16), corner, white)
					local lo, hi = Kit.localBounds(m.frame, spec)
					t.expect(lo.X).toBeNear(if mirror then -2 else -6, EPS)
					t.expect(hi.X).toBeNear(if mirror then 6 else 2, EPS)
					t.expect(lo.Y).toBeNear(0, EPS)
					t.expect(hi.Y).toBeNear(9, EPS)
					t.expect(lo.Z).toBeNear(10, EPS)
					t.expect(hi.Z).toBeNear(16, EPS)
					-- A WedgePart's square edge runs along its x at (y, z) = (-size.Y / 2, +size.Z / 2).
					local square = m.frame:Inverse() * spec.cframe * Vector3.new(0, -spec.size.Y / 2, spec.size.Z / 2)
					local cx = if string.sub(corner, 2, 2) == "l" then -6 else 2
					t.expect(square.X).toBeNear(if mirror then -cx else cx, EPS)
					t.expect(square.Z).toBeNear(if string.sub(corner, 1, 1) == "f" then 10 else 16, EPS)
				end
			end
		end)

		t.it("lays a triangle flat on a front face, its right angle where asked, tilted out or in", function()
			local corners: { Kit.TriangleCorner } = { "x0y0", "x1y0", "x0y1", "x1y1" }
			for _, mirror in { false, true } do
				local m = model(mirror)
				for _, corner in corners do
					local spec = Kit.triangle(m, `Tri{corner}`, -6, 2, 4, 9, -8, 0.5, corner, white)
					local lo, hi = Kit.localBounds(m.frame, spec)
					t.expect(lo.X).toBeNear(if mirror then -4 else -6, EPS)
					t.expect(hi.X).toBeNear(if mirror then 6 else 4, EPS)
					t.expect(lo.Y).toBeNear(2, EPS)
					t.expect(hi.Y).toBeNear(9, EPS)
					t.expect(lo.Z).toBeNear(-8, EPS)
					t.expect(hi.Z).toBeNear(-7.5, EPS)
					-- The wedge's square edge (local x at y = -size.Y / 2, z = +size.Z / 2) is the right angle.
					local square = m.frame:Inverse() * spec.cframe * Vector3.new(0, -spec.size.Y / 2, spec.size.Z / 2)
					local cx = if string.sub(corner, 1, 2) == "x0" then -6 else 4
					t.expect(square.X).toBeNear(if mirror then -cx else cx, EPS)
					t.expect(square.Y).toBeNear(if string.sub(corner, 3, 4) == "y0" then 2 else 9, EPS)
					t.expect(square.Z).toBeNear(-7.75, EPS)
					for i, tilt in { 0.1, -0.1 } do
						local tilted =
							Kit.triangle(m, `Tilt{corner}{i}`, -6, 2, 4, 9, -8, 0.5, corner, white, "trim", tilt)
						local at = m.frame:Inverse()
							* tilted.cframe
							* Vector3.new(0, -tilted.size.Y / 2, tilted.size.Z / 2)
						t.expect(at.Z < -7.75).toBe(tilt > 0)
					end
				end
			end
		end)

		t.it("stands a corner wedge's peak over the corner asked, mirrored with the site", function()
			for _, mirror in { false, true } do
				local m = model(mirror)
				for _, corner in CORNERS do
					local spec =
						Kit.cornerWedge(m, `CW{corner}`, Vector3.new(-6, 0, 10), Vector3.new(2, 9, 16), corner, white)
					local lo, hi = Kit.localBounds(m.frame, spec)
					t.expect(lo.X).toBeNear(if mirror then -2 else -6, EPS)
					t.expect(hi.X).toBeNear(if mirror then 6 else 2, EPS)
					t.expect(hi.Y).toBeNear(9, EPS)
					t.expect(lo.Z).toBeNear(10, EPS)
					t.expect(hi.Z).toBeNear(16, EPS)
					-- A CornerWedgePart's peak is its (+X, +Y, -Z) corner.
					local peak = m.frame:Inverse() * spec.cframe * (spec.size * Vector3.new(0.5, 0.5, -0.5))
					local cx = if string.sub(corner, 2, 2) == "l" then -6 else 2
					t.expect(peak.X).toBeNear(if mirror then -cx else cx, EPS)
					t.expect(peak.Y).toBeNear(9, EPS)
					t.expect(peak.Z).toBeNear(if string.sub(corner, 1, 1) == "f" then 10 else 16, EPS)
				end
			end
		end)

		t.it("hangs a corbel with its flat face on top and its upright face on the wall side", function()
			for _, mirror in { false, true } do
				local m = model(mirror)
				for _, wall in SIDES do
					local spec = Kit.corbel(m, `C{wall}`, Vector3.new(-6, 0, 10), Vector3.new(2, 9, 16), wall, white)
					local lo, hi = Kit.localBounds(m.frame, spec)
					t.expect(lo.X).toBeNear(if mirror then -2 else -6, EPS)
					t.expect(hi.X).toBeNear(if mirror then 6 else 2, EPS)
					t.expect(lo.Y).toBeNear(0, EPS)
					t.expect(hi.Y).toBeNear(9, EPS)
					-- A WedgePart's square edge (local x at y = -size.Y / 2, z = +size.Z / 2) is the corbel's top
					-- edge against the wall.
					local square = m.frame:Inverse() * spec.cframe * Vector3.new(0, -spec.size.Y / 2, spec.size.Z / 2)
					t.expect(square.Y).toBeNear(9, EPS)
					if wall == "left" or wall == "right" then
						local x = if wall == "left" then -6 else 2
						t.expect(square.X).toBeNear(if mirror then -x else x, EPS)
					else
						t.expect(square.Z).toBeNear(if wall == "front" then 10 else 16, EPS)
					end
				end
			end
		end)

		t.it("covers a hipped or gabled roof's outline past the eaves, up to its ridge", function()
			for _, mirror in { false, true } do
				local m = model(mirror)
				for _, hx in { 10, 6 } do
					local hip =
						Kit.hipRoof(m, `Hip{hx}`, Vector3.new(-hx, 20, -6), Vector3.new(hx, 26, 6), 1.5, 0.5, white)
					t.expect(#hip).toBe(if hx == 6 then 4 else 6)
					local lo, hi = Vector3.one * math.huge, -Vector3.one * math.huge
					for _, spec in hip do
						local a, b = Kit.localBounds(m.frame, spec)
						lo, hi = lo:Min(a), hi:Max(b)
					end
					t.expect(lo.X).toBeNear(-hx - 1.5, EPS)
					t.expect(hi.X).toBeNear(hx + 1.5, EPS)
					t.expect(lo.Z).toBeNear(-7.5, EPS)
					t.expect(hi.Z).toBeNear(7.5, EPS)
					t.expect(hi.Y).toBeNear(26, EPS)
					-- The eaves: 0.5 over the wall top at the wall line, falling on at the same pitch past it.
					t.expect(lo.Y).toBeNear(20.5 - 1.5 * (5.5 / 6), EPS)
				end
				local ridges: { "x" | "z" } = { "x", "z" }
				for _, ridge in ridges do
					local gable = Kit.gableRoof(
						m,
						`Gable{ridge}`,
						Vector3.new(-10, 20, -6),
						Vector3.new(10, 26, 6),
						ridge,
						1.5,
						0.5,
						white,
						white
					)
					t.expect(#gable).toBe(4)
					local lo, hi = Vector3.one * math.huge, -Vector3.one * math.huge
					for _, spec in gable do
						local a, b = Kit.localBounds(m.frame, spec)
						lo, hi = lo:Min(a), hi:Max(b)
					end
					t.expect(hi.Y).toBeNear(26, EPS)
					t.expect(hi.X).toBeNear(if ridge == "x" then 10 else 11.5, EPS)
					t.expect(hi.Z).toBeNear(if ridge == "x" then 7.5 else 6, EPS)
				end
			end
		end)

		t.it("cuts an arch head's corners inside its opening and rounds an arched window's top", function()
			local m = model(true)
			for _, spec in Kit.archHead(m, "AH", -3, 3, 9, -6, -4.6, 2.4, white) do
				local lo, hi = Kit.localBounds(m.frame, spec)
				t.expect(lo.X >= -3 - EPS and hi.X <= 3 + EPS).toBe(true)
				t.expect(lo.Y).toBeNear(6.6, EPS)
				t.expect(hi.Y).toBeNear(9, EPS)
			end
			local window = Kit.archWindow(m, "AW", -2, 2, 12, 16, -6, Color3.new(0.2, 0.3, 0.4), { lit = true })
			t.expect(#window).toBe(2)
			local _, top = Kit.localBounds(m.frame, window[2])
			t.expect(top.Y).toBeNear(18, EPS)
			t.expect(window[2].tag).toBe(Environment.nightLights.tag)
		end)

		t.it("gives masses collisions and shadows, trim shadows only, and detail neither", function()
			local m = model(false)
			local box = Kit.box(m, "B", Vector3.zero, Vector3.one * 4, white)
			local trim = Kit.trim(m, "T", Vector3.zero, Vector3.new(10, 0.6, 3), white)
			local sliver = Kit.trim(m, "S", Vector3.zero, Vector3.new(10, 0.3, 0.3), white)
			local detail = Kit.detail(m, "D", Vector3.zero, Vector3.new(10, 2, 2), white)
			t.expect(box.collide and box.query and box.shadow).toBe(true)
			t.expect(trim.collide or trim.query or trim.touch).toBe(false)
			t.expect(trim.shadow).toBe(true)
			t.expect(sliver.shadow).toBe(false)
			t.expect(detail.collide or detail.query or detail.touch or detail.shadow).toBe(false)
		end)

		t.it("makes night lights of known kinds in their day look, their lights off", function()
			local lights = Environment.nightLights
			local m = model(false)
			local count = 0
			for _, spec in everything(m) do
				if spec.tag == lights.tag then
					count += 1
					local attributes: { [string]: any } = spec.attributes or {}
					local look = lights.kinds[attributes[lights.kindAttribute]]
					t.expect(look ~= nil).toBe(true)
					t.expect(spec.material).toBe(look.dayMaterial)
					t.expect(typeof(attributes[lights.dayColorAttribute])).toBe("Color3")
					local light = spec.light
					if light then
						t.expect(light.enabled).toBe(false)
					end
				end
			end
			t.expect(count).toBeGreaterThan(5)
			t.expect(function()
				Kit.neon(m, "Bad", Vector3.zero, Vector3.xAxis, "noSuchKind", Color3.new())
			end).toThrow("unknown night light kind")
		end)

		t.it("refuses two parts with one name and parts with no size", function()
			local m = model(false)
			Kit.box(m, "Twice", Vector3.zero, Vector3.one, white)
			t.expect(function()
				Kit.box(m, "Twice", Vector3.zero, Vector3.one, white)
			end).toThrow("two parts named")
			t.expect(function()
				Kit.box(m, "Flat", Vector3.zero, Vector3.new(1, 0, 1), white)
			end).toThrow("size")
		end)
	end)

	t.describe("City archetypes on sample sites", function()
		for _, archetype in Index.list do
			local id = archetype.id
			local config = City.archetypes[id]
			if config == nil then
				continue
			end

			t.it(`{id}: inside its footprint and height, within {config.budget} parts, glass and a roof`, function()
				local problems: { string } = {}
				local most, fewest = 0, math.huge
				local widths = { config.minWidth, (config.minWidth + config.maxWidth) / 2, config.maxWidth }
				local depths = { config.minDepth, DEPTH }
				local heights = { config.heights.min, config.heights.max }
				local n = 0
				for _, width in widths do
					for _, depth in depths do
						for _, height in heights do
							for _, seed in SEEDS do
								n += 1
								local variant: Variant = {
									palette = n % config.palettes + 1,
									crown = n % config.crowns + 1,
									rhythm = (n // 2) % config.rhythms + 1,
									mirror = n % 2 == 0,
								}
								local site = sample(id, width, depth, height, variant, seed)
								local specs, problem = CityBuilder.build(site)
								if specs == nil then
									table.insert(problems, `{width}x{depth}x{height} seed {seed}: {problem}`)
									continue
								end
								most, fewest = math.max(most, #specs), math.min(fewest, #specs)
								local glass, top = false, -math.huge
								for _, spec in specs do
									glass = glass or spec.material == Enum.Material.Glass
									local _, hi = Kit.localBounds(site.frame, spec)
									top = math.max(top, hi.Y)
								end
								if not glass then
									table.insert(problems, `{width}x{depth}x{height}: no glass`)
								end
								if top < height - 1 then
									table.insert(problems, `{width}x{depth}x{height}: tops out at {top}`)
								end
							end
						end
					end
				end
				print(`  City.spec {id}: {fewest} to {most} parts over {n} sample sites (budget {config.budget})`)
				report(t, id, problems)
			end)

			t.it(`{id}: builds the same parts every time`, function()
				for _, seed in SEEDS do
					local variant: Variant = { palette = 2, crown = 2, rhythm = 1, mirror = true }
					local height = (config.heights.min + config.heights.max) / 2
					local width = (config.minWidth + config.maxWidth) / 2
					local a: { PartSpec } = CityBuilder.build(sample(id, width, DEPTH, height, variant, seed)) or {}
					local b: { PartSpec } = CityBuilder.build(sample(id, width, DEPTH, height, variant, seed)) or {}
					t.expect(#a).toBeGreaterThan(0)
					t.expect(#b).toBe(#a)
					for i, spec in a do
						t.expect(b[i].name).toBe(spec.name)
						t.expect(b[i].cframe == spec.cframe).toBe(true)
						t.expect(b[i].size == spec.size).toBe(true)
						t.expect(b[i].color == spec.color).toBe(true)
					end
				end
			end)
		end
	end)

	t.describe("City placement", function()
		-- Downtown (cedar_bend) frontages in block d4 (cap 380) and the beach (lakefront), one frontage each side, and a
		-- zone with no district.
		local plots = concat(
			run(40, "1:1", 40, "cedar_bend", 1, Vector2.new(-2000, 0)),
			run(40, "2:1", 50, "lakefront", 41, Vector2.new(0, 400)),
			run(10, "3:1", 40, "county_loop", 81, Vector2.new(0, 900))
		)
		-- Squeeze the downtown run into block d4 for the caps: its plots stand 30..83 from z = 0, x -2000..-400 is
		-- outside the grid (west, cap 54), so move it into the grid instead.
		for _, p in plots do
			if p.zone == "cedar_bend" then
				p.frontStart = Vector2.new(-850 + p.along, 30)
				p.center = p.frontStart + Vector2.new(p.width / 2, 30)
			end
		end
		local seed = 1887

		t.it("plans the same sites every time", function()
			local a = CityBuilder.place(plots, seed)
			local b = CityBuilder.place(plots, seed)
			t.expect(#a.sites).toBe(#b.sites)
			t.expect(#a.legacy).toBe(#b.legacy)
			for i, site in a.sites do
				local other = b.sites[i]
				t.expect(other.id).toBe(site.id)
				t.expect(other.archetype).toBe(site.archetype)
				t.expect(other.frame == site.frame).toBe(true)
				t.expect(other.height).toBe(site.height)
				t.expect(other.variant.palette).toBe(site.variant.palette)
			end
		end)

		t.it("places every plot once, as a site or the old look, and keeps no-district zones old", function()
			local placement = CityBuilder.place(plots, seed)
			local seen: { [number]: number } = {}
			for _, site in placement.sites do
				for _, index in site.plots do
					seen[index] = (seen[index] or 0) + 1
				end
				t.expect(site.zone ~= "county_loop").toBe(true)
			end
			for _, p in placement.legacy do
				seen[p.index] = (seen[p.index] or 0) + 1
			end
			for _, p in plots do
				t.expect(seen[p.index]).toBe(1)
			end
			t.expect(#placement.sites).toBeGreaterThan(0)
		end)

		t.it("merges only neighbouring plots of one run, within the archetype's widths and plots", function()
			local placement = CityBuilder.place(plots, seed)
			local byIndex: { [number]: Plot } = {}
			for _, p in plots do
				byIndex[p.index] = p
			end
			for _, site in placement.sites do
				local config = City.archetypes[site.archetype]
				t.expect(#site.plots <= config.maxPlots).toBe(true)
				t.expect(site.width >= config.minWidth - EPS and site.width <= config.maxWidth + EPS).toBe(true)
				for k = 2, #site.plots do
					local a, b = byIndex[site.plots[k - 1]], byIndex[site.plots[k]]
					t.expect(b.frontage).toBe(a.frontage)
					t.expect(b.along).toBeNear(a.along + a.width, EPS)
				end
				-- The footprint spans its plots, less half the gap at each end.
				local first, last = byIndex[site.plots[1]], byIndex[site.plots[#site.plots]]
				t.expect(site.width).toBeNear(last.along + last.width - first.along - City.siteGap, EPS)
			end
		end)

		t.it("never stands one archetype beside itself, and keeps copies, spacing and blocks", function()
			local placement = CityBuilder.place(plots, seed)
			local last: { [string]: Site } = {}
			local copies: { [string]: { Site } } = {}
			for _, site in placement.sites do
				local frontage = plots[1].frontage
				for _, p in plots do
					if p.index == site.plots[1] then
						frontage = p.frontage
					end
				end
				local before = last[frontage]
				if before and before.plots[#before.plots] + 1 == site.plots[1] then
					t.expect(before.archetype ~= site.archetype).toBe(true)
				end
				last[frontage] = site
				local list = copies[site.archetype] or {}
				table.insert(list, site)
				copies[site.archetype] = list
			end
			for id, list in copies do
				local config = City.archetypes[id]
				t.expect(#list <= config.maxCopies).toBe(true)
				local perBlock: { [number]: number } = {}
				for i, a in list do
					perBlock[a.block] = (perBlock[a.block] or 0) + 1
					for j = i + 1, #list do
						local d = (a.frame.Position - list[j].frame.Position).Magnitude
						t.expect(d >= config.minSpacing - EPS).toBe(true)
					end
				end
				for _, n in perBlock do
					t.expect(n <= config.perBlock).toBe(true)
				end
			end
		end)

		t.it("caps heights by the downtown block grid and near gameplay spots", function()
			t.expect(CityBuilder.heightCap("downtown", Vector2.new(150, 150))).toBe(380) -- d4
			t.expect(CityBuilder.heightCap("downtown", Vector2.new(-150, -150))).toBe(0) -- c3, the park
			t.expect(CityBuilder.heightCap("downtown", Vector2.new(0, -950))).toBe(City.heightCaps.downtown.north)
			t.expect(CityBuilder.heightCap("downtown", Vector2.new(-950, 0))).toBe(City.heightCaps.downtown.west)
			t.expect(CityBuilder.heightCap("downtown", Vector2.new(950, 0))).toBe(City.heightCaps.downtown.east)
			t.expect(CityBuilder.heightCap("downtown", Vector2.new(0, 950))).toBe(City.heightCaps.downtown.south)
			t.expect(CityBuilder.heightCap("beach", Vector2.new(0, 1500))).toBe(math.huge)
			for _, site in CityBuilder.place(plots, seed).sites do
				t.expect(site.height <= CityBuilder.heightCap(site.district, Vector2.new(site.frame.X, site.frame.Z)))
					.toBe(true)
			end
			-- The same frontage next to a gameplay spot: nothing taller than nearSpotCap.
			local near = table.clone(plots)
			for i, p in near do
				local copy = table.clone(p)
				copy.nearSpot = true
				near[i] = copy
			end
			for _, site in CityBuilder.place(near, seed).sites do
				t.expect(site.height <= City.nearSpotCap).toBe(true)
			end
		end)

		t.it("gives every site a fresh look while unused ones are left", function()
			local placement = CityBuilder.place(plots, seed)
			local seen: { [string]: boolean } = {}
			for _, site in placement.sites do
				local config = City.archetypes[site.archetype]
				local v = site.variant
				local key = `{site.archetype}:{v.palette}:{v.crown}:{v.rhythm}`
				if config.palettes * config.crowns * config.rhythms > #placement.sites then
					t.expect(seen[key] == nil).toBe(true)
				end
				seen[key] = true
			end
		end)
	end)
end
