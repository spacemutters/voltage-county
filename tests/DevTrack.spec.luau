--!strict
-- The dev track layout (Config/DevTrack) and its build plan (Dev/DevTrackBuilder.plan): long enough for the
-- 0-60 runs, crossable by every drivable car, inside the map and clear of the spawn. Pure: builds nothing.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Catalog = require(ReplicatedStorage.Shared.Vehicle.Catalog)
local DevTrack = require(ReplicatedStorage.Shared.Config.DevTrack)
local DevTrackBuilder = require(ServerScriptService.Server.Dev.DevTrackBuilder)
local Harness = require(ReplicatedStorage.Shared.Testing.Harness)
local World = require(ReplicatedStorage.Shared.Config.World)

local MIN_STRAIGHT = 2400 -- PLAN.md Phase 1
local SPAWN_CLEARANCE = 50 -- the track starts about 60 studs from the spawn at the origin
local MAX_PART_SIZE = 2048 -- Roblox's limit per axis

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

		t.it("keeps every part under the size limit, inside the map and clear of the spawn", function()
			local limit = World.mapHalfExtent
			for _, spec in specs do
				t.expect(math.max(spec.size.X, spec.size.Y, spec.size.Z) <= MAX_PART_SIZE).toBe(true)
				local low, high = bounds(spec)
				t.expect(low.X >= -limit and high.X <= limit and low.Z >= -limit and high.Z <= limit).toBe(true)
				-- Horizontal distance from the spawn (the origin) to the nearest point of the part.
				local dx = math.max(low.X, -high.X, 0)
				local dz = math.max(low.Z, -high.Z, 0)
				t.expect(math.sqrt(dx * dx + dz * dz) >= SPAWN_CLEARANCE).toBe(true)
			end
		end)
	end)
end
