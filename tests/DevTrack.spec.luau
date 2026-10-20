--!strict
-- The dev track layout (Config/DevTrack) and its build plan (Dev/DevTrackBuilder.plan): long enough for the
-- 0-60 runs, crossable by every drivable car, inside the map, and out of the county's way: at least 300 studs
-- clear of the County Loop road, off every other road and outside every MapLayout zone (Phase 2 contracts,
-- "World settings and test tooling"). Pure: builds nothing. Reads Config/RoadGraph and Config/MapLayout by the
-- contract's shapes.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Catalog = require(ReplicatedStorage.Shared.Vehicle.Catalog)
local DevTrack = require(ReplicatedStorage.Shared.Config.DevTrack)
local DevTrackBuilder = require(ServerScriptService.Server.Dev.DevTrackBuilder)
local Harness = require(ReplicatedStorage.Shared.Testing.Harness)
local MapLayout = require(ReplicatedStorage.Shared.Config.MapLayout)
local RoadGraph = require(ReplicatedStorage.Shared.Config.RoadGraph)
local World = require(ReplicatedStorage.Shared.Config.World)

local MIN_STRAIGHT = 2400 -- PLAN.md Phase 1
local LOOP_CLEARANCE = 300 -- studs from the County Loop road's outer edge (Phase 2 contracts)
local MAX_PART_SIZE = 2048 -- Roblox's limit per axis

-- A planned part's footprint on the ground: world X and Z bounds.
type Footprint = { minX: number, maxX: number, minZ: number, maxZ: number }

-- A stretch of road on the ground: its centre line from a to b (X and Z only) and its half width.
type RoadStrip = { name: string, a: Vector2, b: Vector2, halfWidth: number, loop: boolean }

-- World-space min and max corners of a planned part's box.
local function bounds(spec: DevTrackBuilder.PartSpec): (Vector3, Vector3)
	local half = spec.size / 2
	local cf = spec.cframe
	local function reach(axis: Vector3): number
		return math.abs(cf.RightVector:Dot(axis)) * half.X
			+ math.abs(cf.UpVector:Dot(axis)) * half.Y
			+ math.abs(cf.LookVector:Dot(axis)) * half.Z
	end
	local extent = Vector3.new(reach(Vector3.xAxis), reach(Vector3.yAxis), reach(Vector3.zAxis))
	return cf.Position - extent, cf.Position + extent
end

local function footprintOf(spec: DevTrackBuilder.PartSpec): Footprint
	local low, high = bounds(spec)
	return { minX = low.X, maxX = high.X, minZ = low.Z, maxZ = high.Z }
end

-- Distance from point p to the rectangle (0 inside it).
local function pointRectDistance(p: Vector2, rect: Footprint): number
	local dx = math.max(rect.minX - p.X, 0, p.X - rect.maxX)
	local dz = math.max(rect.minZ - p.Y, 0, p.Y - rect.maxZ)
	return math.sqrt(dx * dx + dz * dz)
end

-- Distance from point p to the segment a-b.
local function pointSegmentDistance(p: Vector2, a: Vector2, b: Vector2): number
	local ab = b - a
	local lengthSquared = ab:Dot(ab)
	local t = if lengthSquared > 0 then math.clamp((p - a):Dot(ab) / lengthSquared, 0, 1) else 0
	return (a + ab * t - p).Magnitude
end

-- True when the segment a-b passes through the rectangle (Liang-Barsky clipping).
local function segmentHitsRect(a: Vector2, b: Vector2, rect: Footprint): boolean
	local t0, t1 = 0, 1
	local d = b - a
	local function clip(p: number, q: number): boolean
		if p == 0 then
			return q >= 0 -- parallel to this edge: inside only if it starts inside
		end
		local r = q / p
		if p < 0 then
			t0 = math.max(t0, r)
		else
			t1 = math.min(t1, r)
		end
		return t0 <= t1
	end
	return clip(-d.X, a.X - rect.minX)
		and clip(d.X, rect.maxX - a.X)
		and clip(-d.Y, a.Y - rect.minZ)
		and clip(d.Y, rect.maxZ - a.Y)
end

-- Shortest distance between the segment a-b and the rectangle (0 when they touch).
local function segmentRectDistance(a: Vector2, b: Vector2, rect: Footprint): number
	if segmentHitsRect(a, b, rect) then
		return 0
	end
	local best = math.min(pointRectDistance(a, rect), pointRectDistance(b, rect))
	for _, corner in
		{
			Vector2.new(rect.minX, rect.minZ),
			Vector2.new(rect.maxX, rect.minZ),
			Vector2.new(rect.minX, rect.maxZ),
			Vector2.new(rect.maxX, rect.maxZ),
		}
	do
		best = math.min(best, pointSegmentDistance(corner, a, b))
	end
	return best
end

-- Every road edge as a strip on the ground, marking the County Loop's edges (consecutive loopNodeIds, closed).
-- The half width counts lanes, shoulders and sidewalks (Phase 2 contracts: road width is
-- lanes * laneWidth + 2 * shoulder; a sidewalk is extra width each side).
local function roadStrips(): { RoadStrip }
	local positions: { [string]: Vector3 } = {}
	for _, node in RoadGraph.nodes do
		positions[node.id] = node.position
	end

	local loopPairs: { [string]: boolean } = {}
	local loopIds = RoadGraph.loopNodeIds
	for i, id in loopIds do
		local nextId = loopIds[i % #loopIds + 1]
		loopPairs[`{id}|{nextId}`] = true
		loopPairs[`{nextId}|{id}`] = true
	end

	local strips: { RoadStrip } = {}
	for _, edge in RoadGraph.edges do
		local from, to = positions[edge.from], positions[edge.to]
		if from and to then
			local style = RoadGraph.styles[edge.kind]
			local shoulder = if style then style.shoulder else 0
			local sidewalk = if style then style.sidewalk else 0
			table.insert(strips, {
				name = `{edge.from}-{edge.to}`,
				a = Vector2.new(from.X, from.Z),
				b = Vector2.new(to.X, to.Z),
				halfWidth = edge.lanes * World.laneWidth / 2 + shoulder + sidewalk,
				loop = loopPairs[`{edge.from}|{edge.to}`] == true,
			})
		end
	end
	return strips
end

local function overlaps(rect: Footprint, zoneMin: Vector2, zoneMax: Vector2): boolean
	return rect.maxX > zoneMin.X and rect.minX < zoneMax.X and rect.maxZ > zoneMin.Y and rect.minZ < zoneMax.Y
end

-- Every drivable trim's geometry.
local function drivableGeometries(): { { rideHeight: number, height: number } }
	local list = {}
	for _, vehicleId in Catalog.vehicleIds() do
		local vehicle = Catalog.getVehicle(vehicleId)
		if vehicle and vehicle.playerDrivable then
			for _, trim in vehicle.trims do
				local geometry = Catalog.geometry(vehicleId, trim.id)
				if geometry then
					table.insert(list, { rideHeight = geometry.rideHeight, height = geometry.height })
				end
			end
		end
	end
	return list
end

return function(t: Harness.Api)
	t.describe("DevTrack layout", function()
		t.it("has at least 2,400 studs between the start and finish lines", function()
			t.expect((DevTrack.straightEnd - DevTrack.straightStart).Magnitude >= MIN_STRAIGHT).toBe(true)
			t.expect(DevTrack.straight.length >= MIN_STRAIGHT).toBe(true)
		end)

		t.it("runs the straight north (toward -Z)", function()
			local run = DevTrack.straightEnd - DevTrack.straightStart
			t.expect(run.Z).toBeLessThan(0)
			t.expect(math.abs(run.X)).toBeNear(0, 1e-6)
		end)

		t.it("puts the loop points on the skidpad circle and closes the lap", function()
			local loop = DevTrack.skidpadLoop
			t.expect(#loop).toBe(DevTrack.skidpad.loopPoints + 1)
			for _, point in loop do
				t.expect((point - DevTrack.skidpadCenter).Magnitude).toBeNear(DevTrack.skidpadRadius, 1e-3)
			end
			t.expect((loop[1] - loop[#loop]).Magnitude).toBeNear(0, 1e-3)
		end)

		t.it("keeps the speed humps lower than every drivable car's ride height", function()
			for _, geometry in drivableGeometries() do
				t.expect(DevTrack.bumps.height).toBeLessThan(geometry.rideHeight)
			end
		end)

		t.it("hangs the gantry boards above the tallest drivable car", function()
			local boardBottom = DevTrack.gantry.height - DevTrack.gantry.boardHeight
			for _, geometry in drivableGeometries() do
				t.expect(boardBottom).toBeGreaterThan(geometry.height)
			end
		end)
	end)

	t.describe("DevTrackBuilder.plan", function()
		local specs = DevTrackBuilder.plan()

		t.it("is the same every time", function()
			local again = DevTrackBuilder.plan()
			t.expect(#again).toBe(#specs)
			for i, spec in specs do
				t.expect(again[i].name).toBe(spec.name)
				t.expect(again[i].cframe == spec.cframe).toBe(true)
			end
		end)

		t.it("names every part uniquely within its section", function()
			local seen: { [string]: boolean } = {}
			for _, spec in specs do
				local key = `{spec.section}/{spec.name}`
				t.expect(seen[key]).toBe(nil)
				seen[key] = true
			end
		end)

		t.it("keeps every part under the size limit and inside the map", function()
			local limit = World.mapHalfExtent
			for _, spec in specs do
				t.expect(math.max(spec.size.X, spec.size.Y, spec.size.Z) <= MAX_PART_SIZE).toBe(true)
				local low, high = bounds(spec)
				t.expect(low.X >= -limit and high.X <= limit and low.Z >= -limit and high.Z <= limit).toBe(true)
			end
		end)

		t.it("keeps every part 300 studs clear of the County Loop road and off every other road", function()
			t.expect(#RoadGraph.loopNodeIds >= 3).toBe(true)
			local strips = roadStrips()
			local loopStrips = 0
			for _, strip in strips do
				if strip.loop then
					loopStrips += 1
				end
			end
			-- Every consecutive pair of loop nodes is joined by an edge, so the whole loop is measured.
			t.expect(loopStrips >= #RoadGraph.loopNodeIds).toBe(true)

			-- Every part lies inside the whole track's footprint, so a road clear of that is clear of every part;
			-- only the roads that come closer are measured part by part.
			local whole: Footprint = { minX = math.huge, maxX = -math.huge, minZ = math.huge, maxZ = -math.huge }
			for _, spec in specs do
				local rect = footprintOf(spec)
				whole.minX, whole.maxX = math.min(whole.minX, rect.minX), math.max(whole.maxX, rect.maxX)
				whole.minZ, whole.maxZ = math.min(whole.minZ, rect.minZ), math.max(whole.maxZ, rect.maxZ)
			end

			for _, strip in strips do
				local needed = if strip.loop then LOOP_CLEARANCE else 0
				if segmentRectDistance(strip.a, strip.b, whole) - strip.halfWidth < needed then
					for _, spec in specs do
						local clearance = segmentRectDistance(strip.a, strip.b, footprintOf(spec)) - strip.halfWidth
						if clearance < needed then
							error(
								`{spec.section}/{spec.name} is {string.format("%.0f", clearance)} studs from road `
									.. `{strip.name} (needs {needed})`
							)
						end
					end
				end
			end
		end)

		t.it("keeps every part outside every MapLayout zone", function()
			local zones = 0
			for id, zone in MapLayout.zones do
				zones += 1
				for _, spec in specs do
					if overlaps(footprintOf(spec), zone.min, zone.max) then
						error(`{spec.section}/{spec.name} is inside zone {id}`)
					end
				end
			end
			t.expect(zones).toBeGreaterThan(0)
		end)
	end)
end
