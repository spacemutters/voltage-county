--!strict
-- Every greybox model VehicleBuilder makes follows the vehicle model contract, and check() catches a model
-- that does not. Builds in memory only (assemble), so it never touches ServerStorage.VehicleModels.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Catalog = require(ReplicatedStorage.Shared.Vehicle.Catalog)
local Harness = require(ReplicatedStorage.Shared.Testing.Harness)
local VehicleBuilder = require(ServerScriptService.Server.Dev.VehicleBuilder)

return function(t: Harness.Api)
	t.describe("VehicleBuilder", function()
		for _, vehicleId in Catalog.vehicleIds() do
			local vehicle = Catalog.getVehicle(vehicleId)
			if vehicle == nil then
				continue
			end
			for _, trim in vehicle.trims do
				t.it(`builds {vehicleId}/{trim.id} to the model contract`, function()
					-- assemble() itself errors when check() finds a problem; check again to print any.
					local model = VehicleBuilder.assemble(vehicleId, trim.id)
					local problems = VehicleBuilder.check(model)
					model:Destroy()
					for _, message in problems do
						print(`  contract: {message}`)
					end
					t.expect(#problems).toBe(0)
				end)
			end
		end

		-- The Ohm vehicles have bespoke silhouettes, so their own bodyStyles (semi, pod, hypercar...) are only
		-- exercised here: build each Ohm vehicle's generic body too.
		for _, vehicleId in Catalog.vehicleIds() do
			local vehicle = Catalog.getVehicle(vehicleId)
			if vehicle == nil or vehicle.brandId ~= "ohm" then
				continue
			end
			local trim = vehicle.trims[1]
			t.it(`builds the generic {vehicle.bodyStyle} body for {vehicleId}/{trim.id}`, function()
				local model = VehicleBuilder.assembleGeneric(vehicleId, trim.id)
				local problems = VehicleBuilder.check(model)
				model:Destroy()
				for _, message in problems do
					print(`  contract: {message}`)
				end
				t.expect(#problems).toBe(0)
			end)
		end

		t.it("has a generic body for every bodyStyle in the catalog", function()
			local known: { [string]: boolean } = {}
			for _, style in VehicleBuilder.bodyStyles() do
				known[style] = true
			end
			local missing: { string } = {}
			for _, vehicleId in Catalog.vehicleIds() do
				local vehicle = Catalog.getVehicle(vehicleId)
				if vehicle and not known[vehicle.bodyStyle] then
					table.insert(missing, `{vehicleId}: {vehicle.bodyStyle}`)
				end
			end
			t.expect(missing).toEqual({})
		end)

		t.it("gives tow trucks a boom and a TowHitch, pickups an open bed, vans a tall box", function()
			local tow = VehicleBuilder.assemble("northline_grapple", "standard") :: any
			local pickup = VehicleBuilder.assemble("ironwood_brakken", "standard") :: any
			local van = VehicleBuilder.assemble("northline_longbox", "standard") :: any
			local vanGeometry = Catalog.geometry("northline_longbox", "standard")
			assert(vanGeometry, "van geometry")
			local boom = tow.Body:FindFirstChild("Boom")
			local towHitch = tow.Chassis:FindFirstChild("TowHitch")
			local bed = pickup.Body:FindFirstChild("BedFloor")
			local pickupHitch = pickup.Chassis:FindFirstChild("TowHitch")
			local cargo = van.Body:FindFirstChild("CargoBox")
			-- Height above the ground point the model is built on (its pivot).
			local cargoTop = if cargo then cargo.CFrame.Y + cargo.Size.Y / 2 - van:GetPivot().Y else 0
			local cargoHeight = if cargo then cargo.Size.Y else 0
			tow:Destroy()
			pickup:Destroy()
			van:Destroy()
			t.expect(boom ~= nil and towHitch ~= nil).toBe(true)
			t.expect(bed ~= nil and pickupHitch ~= nil).toBe(true)
			t.expect(cargoTop).toBeGreaterThan(vanGeometry.height * 0.9)
			t.expect(cargoHeight).toBeGreaterThan(vanGeometry.height * 0.4)
		end)

		t.it("tints each brand's default paint differently", function()
			local colors: { [string]: string } = {}
			local seen: { [string]: string } = {}
			local clashes: { string } = {}
			for _, vehicleId in Catalog.vehicleIds() do
				local vehicle = Catalog.getVehicle(vehicleId)
				if vehicle == nil or colors[vehicle.brandId] ~= nil then
					continue
				end
				local model = VehicleBuilder.assemble(vehicleId, vehicle.trims[1].id)
				local color: string? = nil
				for _, part in model:GetDescendants() do
					if part:IsA("BasePart") and part:HasTag("Paint") then
						color = tostring(part.Color)
						break
					end
				end
				model:Destroy()
				assert(color, `{vehicleId} has a Paint part`)
				colors[vehicle.brandId] = color
				if seen[color] then
					table.insert(clashes, `{vehicle.brandId} = {seen[color]}`)
				end
				seen[color] = vehicle.brandId
			end
			t.expect(clashes).toEqual({})
		end)

		t.it("builds the same instances every time", function()
			local first = VehicleBuilder.assemble("ohm_summit", "standard")
			local second = VehicleBuilder.assemble("ohm_summit", "standard")
			local firstCount, secondCount = #first:GetDescendants(), #second:GetDescendants()
			first:Destroy()
			second:Destroy()
			t.expect(firstCount).toBe(secondCount)
		end)

		t.it("puts the pivot on the ground under the chassis", function()
			local model = VehicleBuilder.assemble("ohm_spark", "standard")
			local geometry = Catalog.geometry("ohm_spark", "standard")
			assert(geometry, "geometry exists")
			local chassis = model.PrimaryPart
			assert(chassis, "has a PrimaryPart")
			local bottom = chassis.Position.Y - chassis.Size.Y / 2 - model:GetPivot().Position.Y
			model:Destroy()
			t.expect(bottom).toBeNear(geometry.rideHeight, 1e-3)
		end)

		t.it("gives the Pod no driver seat and the Arc Flight a single seat", function()
			local podModel = VehicleBuilder.assemble("ohm_pod", "standard") :: any
			local flight = VehicleBuilder.assemble("ohm_arc", "flight") :: any
			local podDriver = podModel.Seats:FindFirstChild("Driver")
			local flightSeats = #flight.Seats:GetChildren()
			podModel:Destroy()
			flight:Destroy()
			t.expect(podDriver).toBe(nil)
			t.expect(flightSeats).toBe(1)
		end)

		t.it("check() catches a broken model", function()
			local model = VehicleBuilder.assemble("ohm_spark", "standard") :: any
			model.Wheels.FL.Motor:Destroy()
			model.Lights.Brake.Light.Enabled = true
			model.Body.Roof.CanCollide = true
			local problems = VehicleBuilder.check(model)
			model:Destroy()
			t.expect(#problems).toBeGreaterThan(2) -- the lost Motor counts twice: no motor, no joint
		end)
	end)
end
