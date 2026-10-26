--!strict
-- The bay as terrain water (Config/Water; Util/WaterShape; Dev/WaterBuilder; Services/WaterRescueService;
-- docs/city/SCENERY.md §3). Pure: writes no terrain and moves no car.
--   * Config/Water makes sense: the look within the engine's ranges, every shore's profile deepening outward
--   * the county's bay: a beach on the shore the beach park lies along, seawalls on the others; the seabed meets the
--     ground at every edge, the beach shelves into wide shallows, the walls drop off, the bay deepens offshore and never
--     goes below the lake's bedY; the point queries
--   * the voxels: grid-aligned and under the engine's limit, water only under the water line and never in a voxel the
--     seabed fills, the lip dry, the same voxels every time, and the whole-voxel fallback
--   * dry ground: no road or gameplay spot in the water (so traffic, jobs and the GPS, which only follow the road
--     graph, never route into it), and a road or spot laid through a test bay is caught
--   * the rescue rules: wading and the bridge never count; deep water after `seconds`; on its roof after
--     flippedSeconds; stuck in any water after stuckSeconds; a car left in the water comes out; leaving the water
--     stops the clock; a car pulled out lands on a dry road
--   * the county plan: no part water, lake bed or banks while terrain water is on; the coping stays

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Graph = require(ReplicatedStorage.Shared.Road.Graph)
local Harness = require(ReplicatedStorage.Shared.Testing.Harness)
local MapLayout = require(ReplicatedStorage.Shared.Config.MapLayout)
local Water = require(ReplicatedStorage.Shared.Config.Water)
local WaterShape = require(ReplicatedStorage.Shared.Util.WaterShape)

local Dev = ServerScriptService.Server.Dev
local Services = ServerScriptService.Server.Services
local AbilityService = require(Services.AbilityService)
local MapBuilder = require(Dev.MapBuilder)
local Rescue = require(Services.WaterRescueService.Rescue)
local WaterBuilder = require(Dev.WaterBuilder)

local VOXEL = 4
local VOXEL_LIMIT = 4194304 -- the most voxels one Terrain read or write may cover
local RESCUE = Water.rescue
local EPSILON = 1e-6

local function report(t: Harness.Api, label: string, problems: { string })
	if #problems > 0 then
		local shown = table.move(problems, 1, math.min(#problems, 8), 1, {})
		print(`  Water.spec {label}: {#problems} problems, e.g. {table.concat(shown, "; ")}`)
	end
	t.expect(#problems).toBe(0)
end

local function aligned(v: Vector3): boolean
	return v.X % VOXEL == 0 and v.Y % VOXEL == 0 and v.Z % VOXEL == 0
end

-- The water depth at (x, z) of `area` (negative: dry seabed above the water line).
local function depthIn(area: WaterShape.Area, x: number, z: number): number
	local column = WaterShape.column(area, x, z)
	assert(column, `({x}, {z}) is in {area.id} or its lip`)
	return area.waterY - column.seabed
end

return function(t: Harness.Api)
	local areas = WaterShape.areas()
	local bay = areas[1]

	t.describe("Config/Water", function()
		t.it("keeps the water look within the engine's ranges", function()
			local look = Water.look
			t.expect(look.transparency >= 0 and look.transparency <= 1).toBe(true)
			t.expect(look.reflectance >= 0 and look.reflectance <= 1).toBe(true)
			t.expect(look.waveSize >= 0 and look.waveSize <= 1).toBe(true)
			t.expect(look.waveSpeed >= 0 and look.waveSpeed <= 100).toBe(true)
		end)

		t.it("deepens every shore outward from an edge just under the ground's top", function()
			local seabed = Water.seabed
			t.expect(seabed.rimY < 0 and seabed.rimY > -1).toBe(true)
			t.expect(seabed.shores.beach ~= nil and seabed.shores.wall ~= nil).toBe(true)
			for kind, shore in seabed.shores do
				t.expect(#shore.profile > 0).toBe(true)
				local lastDistance, lastDepth = 0, -math.huge
				for _, point in shore.profile do
					if point.X <= lastDistance or point.Y < lastDepth then
						print(`  Water.spec: shore {kind}'s profile goes back at {point}`)
					end
					t.expect(point.X > lastDistance).toBe(true)
					t.expect(point.Y >= lastDepth).toBe(true)
					lastDistance, lastDepth = point.X, point.Y
				end
			end
			t.expect(RESCUE.flippedSeconds <= RESCUE.seconds).toBe(true)
			t.expect(RESCUE.depth > 0 and RESCUE.interval > 0).toBe(true)
		end)
	end)

	t.describe("The county's bay", function()
		t.it("makes one area per lake, a beach where the beach park lies and seawalls elsewhere", function()
			t.expect(#areas).toBe(#MapLayout.lakes)
			t.expect(bay.shores.north).toBe("beach")
			t.expect(bay.shores.south).toBe("wall")
			t.expect(bay.shores.west).toBe("wall")
			t.expect(bay.shores.east).toBe("wall")
		end)

		t.it("meets the ground at every edge, deepens offshore and never goes below the lake's bed", function()
			local problems: { string } = {}
			local mid = (bay.min + bay.max) / 2
			-- Lines from the middle of each side straight in to the bay's middle.
			local lines = {
				{ Vector2.new(mid.X, bay.min.Y), Vector2.new(0, 1) },
				{ Vector2.new(mid.X, bay.max.Y), Vector2.new(0, -1) },
				{ Vector2.new(bay.min.X, mid.Y), Vector2.new(1, 0) },
				{ Vector2.new(bay.max.X, mid.Y), Vector2.new(-1, 0) },
			}
			for _, line in lines do
				local edge, inward = line[1], line[2]
				local reach = math.abs((mid - edge):Dot(inward))
				local rim = WaterShape.column(bay, edge.X + inward.X * 0.01, edge.Y + inward.Y * 0.01)
				if rim == nil or math.abs(rim.seabed - Water.seabed.rimY) > 0.05 then
					table.insert(problems, `edge at {edge}: the seabed doesn't meet the ground`)
				end
				local last = -math.huge
				local d = 0.5
				while d <= reach do
					local p = edge + inward * d
					local depth = depthIn(bay, p.X, p.Y)
					if depth < last - EPSILON then
						table.insert(problems, `from {edge}: shallower again {d} studs out`)
					end
					if bay.waterY - depth < bay.bedY - EPSILON then
						table.insert(problems, `from {edge}: below the bed {d} studs out`)
					end
					last = depth
					d += 7
				end
			end
			report(t, "seabed", problems)
			-- The middle is the deepest the lake goes.
			t.expect(depthIn(bay, mid.X, mid.Y)).toBeNear(bay.waterY - bay.bedY, 0.01)
		end)

		t.it("shelves the beach into wide shallows, and drops off at the seawalls", function()
			local x = (bay.min.X + bay.max.X) / 2 + 300 -- clear of the bridge and the corners
			-- The water line close to the edge, then a stud to a few deep for the first 80 studs.
			t.expect(depthIn(bay, x, bay.min.Y + 2) <= 0).toBe(true)
			t.expect(depthIn(bay, x, bay.min.Y + 14) > 0).toBe(true)
			for _, d in { 20, 40, 60, 80 } do
				local depth = depthIn(bay, x, bay.min.Y + d)
				t.expect(depth > 0.2 and depth < 3.5).toBe(true)
			end
			-- A seawall's foot is deep water.
			t.expect(depthIn(bay, x, bay.max.Y - 14) >= 9).toBe(true)
			t.expect(depthIn(bay, bay.min.X + 14, (bay.min.Y + bay.max.Y) / 2) >= 9).toBe(true)
		end)

		t.it("answers where the water is and how deep", function()
			local mid = (bay.min + bay.max) / 2
			t.expect(WaterShape.areaAt(mid.X, mid.Y)).toBe(bay)
			t.expect(WaterShape.surfaceAt(mid.X, mid.Y)).toBe(bay.waterY)
			t.expect(WaterShape.depthAt(mid.X, mid.Y)).toBeNear(bay.waterY - bay.bedY, 0.01)
			-- Outside the water, and on the dry sand at the beach's edge.
			t.expect(WaterShape.surfaceAt(mid.X, bay.min.Y - 50)).toBe(nil)
			t.expect(WaterShape.depthAt(mid.X, bay.min.Y - 50)).toBe(0)
			t.expect(WaterShape.surfaceAt(mid.X + 300, bay.min.Y + 1)).toBe(nil)
			-- The lip runs on under the ground, dry; nothing past it.
			local lip = WaterShape.column(bay, mid.X, bay.min.Y - Water.seabed.lip / 2)
			t.expect(lip ~= nil and not lip.wet).toBe(true)
			t.expect(WaterShape.column(bay, mid.X, bay.min.Y - Water.seabed.lip - 1)).toBe(nil)
			-- A seawall's bank is stone, the floor sand.
			local bank = WaterShape.column(bay, mid.X, bay.max.Y - 4)
			t.expect(bank ~= nil and bank.material == Water.seabed.shores.wall.stone).toBe(true)
			local floor = WaterShape.column(bay, mid.X, mid.Y)
			t.expect(floor ~= nil and floor.material == Water.seabed.shores.wall.material).toBe(true)
		end)
	end)

	t.describe("The voxels", function()
		local low, high = WaterBuilder.region(bay)

		t.it("covers the bay and its lip on the voxel grid, a strip within the engine's limit", function()
			t.expect(aligned(low) and aligned(high)).toBe(true)
			local lip = Water.seabed.lip
			t.expect(low.X <= bay.min.X - lip and high.X >= bay.max.X + lip).toBe(true)
			t.expect(low.Z <= bay.min.Y - lip and high.Z >= bay.max.Y + lip).toBe(true)
			t.expect(low.Y <= bay.bedY - Water.seabed.under and high.Y >= bay.waterY).toBe(true)
			local strip = Water.build.stripColumns * ((high.Y - low.Y) / VOXEL) * ((high.Z - low.Z) / VOXEL)
			t.expect(strip <= VOXEL_LIMIT).toBe(true)
		end)

		-- A strip across the whole bay, north to south, through the bridge's line.
		local from = Vector3.new(-32, low.Y, low.Z)
		local to = Vector3.new(32, high.Y, high.Z)
		local channels = WaterBuilder.voxels(bay, from, to)

		t.it(
			"puts water only under the water line, never where the seabed fills a voxel, and none on the lip",
			function()
				local nx, ny, nz = (to.X - from.X) / VOXEL, (to.Y - from.Y) / VOXEL, (to.Z - from.Z) / VOXEL
				t.expect(#channels.SolidMaterial).toBe(nx)
				local problems: { string } = {}
				local wet, solid = 0, 0
				for i = 1, nx do
					t.expect(#channels.SolidMaterial[i]).toBe(ny)
					for j = 1, ny do
						t.expect(#channels.SolidMaterial[i][j]).toBe(nz)
						local y0 = from.Y + VOXEL * (j - 1)
						for k = 1, nz do
							local z = from.Z + VOXEL * (k - 0.5)
							local material = channels.SolidMaterial[i][j][k]
							local s = channels.SolidOccupancy[i][j][k]
							local l = channels.LiquidOccupancy[i][j][k]
							local where = `voxel {i},{j},{k}`
							if s < 0 or s > 1 or l < 0 or l > 1 then
								table.insert(problems, `{where}: occupancy out of range`)
							end
							if (s > 0) ~= (material ~= Enum.Material.Air) then
								table.insert(problems, `{where}: material and solid occupancy disagree`)
							end
							if l > 0 and y0 >= bay.waterY then
								table.insert(problems, `{where}: water above the water line`)
							end
							if l > 0 and s >= 1 then
								table.insert(problems, `{where}: water in a full seabed voxel`)
							end
							if l > 0 and (z < bay.min.Y or z > bay.max.Y) then
								table.insert(problems, `{where}: water on the lip`)
							end
							if l > 0 then
								wet += 1
							end
							if s > 0 then
								solid += 1
							end
						end
					end
				end
				report(t, "voxels", problems)
				t.expect(wet).toBeGreaterThan(0)
				t.expect(solid).toBeGreaterThan(0)
			end
		)

		t.it("writes the same voxels every time", function()
			local again = WaterBuilder.voxels(bay, from, to)
			local same = true
			for i, plane in channels.SolidOccupancy do
				for j, row in plane do
					for k, value in row do
						if again.SolidOccupancy[i][j][k] ~= value then
							same = false
						end
						if again.LiquidOccupancy[i][j][k] ~= channels.LiquidOccupancy[i][j][k] then
							same = false
						end
						if again.SolidMaterial[i][j][k] ~= channels.SolidMaterial[i][j][k] then
							same = false
						end
					end
				end
			end
			t.expect(same).toBe(true)
		end)

		-- The engine draws a solid voxel's surface half a voxel above its occupancy level (Config/Water build.solidLift,
		-- seen in Studio), so each column's seabed is written that much lower than Util/WaterShape's to stand at it.
		t.it(
			"writes each column's seabed solidLift studs under WaterShape's, so it stands where WaterShape says",
			function()
				local lift = Water.build.solidLift
				local problems: { string } = {}
				local ny, nz = (to.Y - from.Y) / VOXEL, (to.Z - from.Z) / VOXEL
				local x = from.X + VOXEL / 2
				local checked = 0
				for k = 1, nz do
					local z = from.Z + VOXEL * (k - 0.5)
					local column = WaterShape.column(bay, x, z)
					if column == nil then
						continue
					end
					local total = 0
					for j = 1, ny do
						total += channels.SolidOccupancy[1][j][k]
					end
					local top = from.Y + total * VOXEL
					local want = column.seabed - lift
					if math.abs(top - want) > 0.05 then
						table.insert(problems, string.format("z %.0f: written at %.2f, want %.2f", z, top, want))
					end
					checked += 1
				end
				report(t, "lift", problems)
				t.expect(checked).toBeGreaterThan(0)
				t.expect(low.Y < bay.bedY - lift).toBe(true)
			end
		)

		t.it("falls back to whole voxels: seabed where there is any, else water", function()
			local materials, occupancy = WaterBuilder.fallback(channels)
			local problems: { string } = {}
			for i, plane in channels.SolidOccupancy do
				for j, row in plane do
					for k, s in row do
						local l = channels.LiquidOccupancy[i][j][k]
						local material, value = materials[i][j][k], occupancy[i][j][k]
						local want = if s > 0
							then channels.SolidMaterial[i][j][k]
							elseif l > 0 then Enum.Material.Water
							else Enum.Material.Air
						local wantValue = if s > 0 then s elseif l > 0 then l else 0
						if material ~= want or value ~= wantValue then
							table.insert(
								problems,
								`voxel {i},{j},{k}: {material.Name} {value}, want {want.Name} {wantValue}`
							)
						end
					end
				end
			end
			report(t, "fallback", problems)
		end)
	end)

	t.describe("Dry ground", function()
		t.it("keeps every road and gameplay spot of the county out of the water", function()
			report(t, "county", WaterBuilder.dryProblems())
		end)

		t.it("catches a road or a spot laid through the water, and lets a bridge over it pass", function()
			local test: WaterShape.Area = {
				id = "test_bay",
				min = Vector2.new(0, 0),
				max = Vector2.new(100, 100),
				waterY = -2,
				bedY = -12,
				shores = { north = "wall", south = "wall", west = "wall", east = "wall" },
			}
			local zone = MapLayout.zoneOrder[1]
			local function road(y: number): Graph.Api
				return Graph.fromData({
					{ id = "a", position = Vector3.new(-60, y, 50), zone = zone },
					{ id = "b", position = Vector3.new(160, y, 50), zone = zone },
				}, {
					{ from = "a", to = "b", lanes = 2, speedLimitMph = 25, surface = "asphalt", kind = "street" },
				})
			end
			local spot: WaterBuilder.Spot = { name = "a spot", position = Vector3.new(50, 0, 50), reach = 5 }
			local through = WaterBuilder.dryProblems({ test }, road(0.2), { spot })
			local roads, spots = 0, 0
			for _, problem in through do
				if string.find(problem, "^road") then
					roads += 1
				elseif string.find(problem, "^a spot") then
					spots += 1
				end
			end
			t.expect(roads).toBeGreaterThan(0)
			t.expect(spots).toBe(1)
			report(t, "bridge", WaterBuilder.dryProblems({ test }, road(20.2), {}))
		end)
	end)

	t.describe("The rescue rules", function()
		local mid = (bay.min + bay.max) / 2
		local deep = CFrame.new(mid.X + 200, bay.bedY + 2, mid.Y)
		local wading = CFrame.new(mid.X + 300, bay.waterY - 1.2, bay.min.Y + 30)

		t.it("never counts a car on the bridge or wading in the shallows", function()
			local bridge = Rescue.read(CFrame.new(0, 21.5, mid.Y), RESCUE)
			t.expect(bridge.wet).toBe(false)
			local shallow = Rescue.read(wading, RESCUE)
			t.expect(shallow.wet).toBe(true)
			t.expect(shallow.deep).toBe(false)
			local watch: Rescue.Watch = {}
			for now = 0, 60, 5 do
				t.expect(Rescue.step(watch, shallow, now, RESCUE)).toBe(false)
			end
			t.expect(Rescue.read(CFrame.new(mid.X, 0, bay.min.Y - 40), RESCUE).wet).toBe(false)
		end)

		t.it("pulls a car out after its time in deep water, not before", function()
			local reading = Rescue.read(deep, RESCUE)
			t.expect(reading.wet and reading.deep and not reading.flipped).toBe(true)
			local watch: Rescue.Watch = {}
			t.expect(Rescue.step(watch, reading, 10, RESCUE)).toBe(false)
			t.expect(Rescue.step(watch, reading, 10 + RESCUE.seconds - 0.1, RESCUE)).toBe(false)
			t.expect(Rescue.step(watch, reading, 10 + RESCUE.seconds, RESCUE)).toBe(true)
			-- A car floating at the surface over deep water counts too.
			local floating = Rescue.read(CFrame.new(deep.X, bay.waterY + 0.5, deep.Z), RESCUE)
			t.expect(floating.wet and floating.deep).toBe(true)
		end)

		t.it("pulls a car on its roof out sooner, even in the shallows", function()
			local reading = Rescue.read(wading * CFrame.Angles(math.pi, 0, 0), RESCUE)
			t.expect(reading.wet and reading.flipped).toBe(true)
			local watch: Rescue.Watch = {}
			t.expect(Rescue.step(watch, reading, 0, RESCUE)).toBe(false)
			t.expect(Rescue.step(watch, reading, RESCUE.flippedSeconds, RESCUE)).toBe(true)
		end)

		t.it("pulls a car stuck in any water out after stuckSeconds, never one that is moving", function()
			local stuck = Rescue.read(wading, RESCUE, nil, RESCUE.stuckSpeed / 2)
			t.expect(stuck.wet and stuck.stuck and not stuck.deep).toBe(true)
			local watch: Rescue.Watch = {}
			t.expect(Rescue.step(watch, stuck, 0, RESCUE)).toBe(false)
			t.expect(Rescue.step(watch, stuck, RESCUE.stuckSeconds - 0.1, RESCUE)).toBe(false)
			t.expect(Rescue.step(watch, stuck, RESCUE.stuckSeconds, RESCUE)).toBe(true)
			-- Wading on through the shallows, or a speed the server doesn't know yet, never counts.
			local moving = Rescue.read(wading, RESCUE, nil, RESCUE.stuckSpeed * 4)
			local unknown = Rescue.read(wading, RESCUE, nil, nil)
			t.expect(moving.stuck or unknown.stuck).toBe(false)
			local still: Rescue.Watch = {}
			for now = 0, 60, 5 do
				t.expect(Rescue.step(still, moving, now, RESCUE)).toBe(false)
			end
			-- In deep water the shorter allowance holds.
			t.expect(Rescue.allowance(Rescue.read(deep, RESCUE, nil, 0), RESCUE))
				.toBe(math.min(RESCUE.seconds, RESCUE.stuckSeconds))
			-- Stopped on dry ground is no business of the rescue.
			t.expect(Rescue.read(CFrame.new(mid.X, 0.5, bay.min.Y - 40), RESCUE, nil, 0).stuck).toBe(false)
		end)

		t.it("brings out a car its driver leaves in the water, never one parked ashore or on the bridge", function()
			t.expect(Rescue.leftInWater(CFrame.new(deep.X, bay.waterY, deep.Z), RESCUE)).toBe(true)
			t.expect(Rescue.leftInWater(CFrame.new(deep.X, bay.bedY, deep.Z), RESCUE)).toBe(true)
			t.expect(Rescue.leftInWater(CFrame.new(0, 20.2, mid.Y), RESCUE)).toBe(false)
			t.expect(Rescue.leftInWater(CFrame.new(mid.X, 0.3, bay.min.Y - 40), RESCUE)).toBe(false)
		end)

		t.it("stops the clock when the car gets out of the water", function()
			local inside = Rescue.read(deep, RESCUE)
			local out = Rescue.read(CFrame.new(mid.X, 0.5, bay.min.Y - 40), RESCUE)
			local watch: Rescue.Watch = {}
			t.expect(Rescue.step(watch, inside, 0, RESCUE)).toBe(false)
			t.expect(Rescue.step(watch, out, RESCUE.seconds - 0.5, RESCUE)).toBe(false)
			t.expect(watch.since).toBe(nil)
			t.expect(Rescue.step(watch, inside, RESCUE.seconds, RESCUE)).toBe(false)
			t.expect(Rescue.step(watch, inside, 2 * RESCUE.seconds - 0.1, RESCUE)).toBe(false)
			t.expect(Rescue.step(watch, inside, 2 * RESCUE.seconds, RESCUE)).toBe(true)
		end)

		t.it("puts a pulled-out car on a dry road", function()
			local problems: { string } = {}
			for _, x in { bay.min.X + 60, mid.X - 250, mid.X + 20, mid.X + 400, bay.max.X - 60 } do
				for _, z in { bay.min.Y + 40, mid.Y, bay.max.Y - 40 } do
					local from = Vector3.new(x, bay.bedY + 2, z)
					local pose = AbilityService.roadPose(from, Vector3.xAxis)
					if pose == nil then
						table.insert(problems, `from {from}: no road`)
						continue
					end
					local p = pose.Position
					local surface = WaterShape.surfaceAt(p.X, p.Z)
					if surface ~= nil and p.Y < surface + Water.dry.clearance then
						table.insert(problems, `from {from}: put in the water at {p}`)
					end
					if not Graph.isOnRoad(p) then
						table.insert(problems, `from {from}: put off the road at {p}`)
					end
				end
			end
			report(t, "pulled out", problems)
		end)
	end)

	t.describe("The county plan", function()
		t.it("builds no part water, lake bed or banks while terrain water is on, and keeps the coping", function()
			if not Water.terrain then
				print("  Water.spec: Config/Water.terrain is off; the part water is in the plan")
				return
			end
			local plan = MapBuilder.county()
			local problems: { string } = {}
			local coping = 0
			for _, spec in plan.specs do
				local name = spec.name
				if spec.role == "water" then
					table.insert(problems, `{spec.folder}/{name}: part water`)
				end
				for _, lake in MapLayout.lakes do
					if
						name == `{lake.id}Bed`
						or string.find(name, `^{lake.id}Bed_`)
						or string.find(name, `^{lake.id}Bank`)
					then
						table.insert(problems, `{spec.folder}/{name}: a lake bed part`)
					end
					if string.find(name, `^{lake.id}Coping`) then
						coping += 1
					end
				end
			end
			report(t, "plan", problems)
			t.expect(coping).toBeGreaterThan(0)
		end)
	end)
end
