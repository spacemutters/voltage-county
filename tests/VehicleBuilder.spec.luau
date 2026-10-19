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
