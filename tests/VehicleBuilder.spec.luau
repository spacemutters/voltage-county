--!strict
-- Every greybox model VehicleBuilder makes follows the vehicle model contract, and check() catches a model
-- that does not. Builds in memory only (assemble), so it never writes to ServerStorage.VehicleModels.
--
-- Phase 11 moved the generic bodies, wheels, seats, lamps and the contract check into Vehicle/BodyKit; every
-- catalog model must come out exactly as before. "matches its stored model" compares a fingerprint of each fresh
-- build (every instance's path, class, size, CFrame from the pivot, color, material, joints, attachments, lights,
-- tags and attributes) with the greybox model of the same name already in ServerStorage.VehicleModels (read only),
-- which the builder made before the move, or, for a trim whose stored model is final art, its greybox reference in
-- ServerStorage.GreyboxReference (the greybox Dev/ArtPass fitted it to). After a deliberate change to the greybox
-- art or Config/Vehicles geometry, rebuild the stored models (VehicleBuilder.buildAll, which rebuilds the
-- references too) and this keeps checking that they are up to date.

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")

local Catalog = require(ReplicatedStorage.Shared.Vehicle.Catalog)
local Harness = require(ReplicatedStorage.Shared.Testing.Harness)
local VehicleBuilder = require(ServerScriptService.Server.Dev.VehicleBuilder)

local MODELS_FOLDER = "VehicleModels" -- where VehicleBuilder.build stores the models (Dev/VehicleBuilder)
local GREYBOX_ATTRIBUTE = "Greybox" -- set on every model VehicleBuilder builds
local MAX_SHOWN = 8 -- differing fingerprint lines printed per model
local PRECISION = 1000 -- fingerprint numbers are kept to thousandths (Vector3 and CFrame are 32-bit floats)

-- Fingerprints -----------------------------------------------------------------------------------------------

-- A number to PRECISION, never "-0".
local function num(value: number): string
	return string.format("%d", math.round(value * PRECISION) + 0)
end

local function vec(value: Vector3): string
	return `{num(value.X)},{num(value.Y)},{num(value.Z)}`
end

local function frame(value: CFrame): string
	local parts = {}
	for _, component in { value:GetComponents() } do
		table.insert(parts, num(component))
	end
	return table.concat(parts, ",")
end

local function valueText(value: any): string
	local kind = typeof(value)
	if kind == "number" then
		return num(value)
	elseif kind == "Vector3" then
		return vec(value)
	elseif kind == "CFrame" then
		return frame(value)
	elseif kind == "Color3" then
		return value:ToHex()
	end
	return tostring(value)
end

local function pathIn(model: Model, instance: Instance?): string
	if instance == nil then
		return "-"
	end
	local names: { string } = {}
	local node: Instance? = instance
	while node ~= nil and node ~= model do
		table.insert(names, 1, node.Name)
		node = node.Parent
	end
	return if node == model then table.concat(names, "/") else `(outside){instance.Name}`
end

local function attributesOf(instance: Instance): string
	local attributes = instance:GetAttributes()
	local keys: { string } = {}
	for key in attributes do
		table.insert(keys, key)
	end
	table.sort(keys)
	local parts: { string } = {}
	for _, key in keys do
		table.insert(parts, `{key}={valueText(attributes[key])}`)
	end
	return table.concat(parts, ";")
end

local function tagsOf(instance: Instance): string
	local tags = CollectionService:GetTags(instance)
	table.sort(tags)
	return table.concat(tags, ";")
end

-- One sorted line per instance in the model (and one for the model itself). Equal lists mean the same build.
local function fingerprint(model: Model): { string }
	local pivot = model:GetPivot()
	local lines: { string } = {
		`{model.Name}|Model|{pathIn(model, model.PrimaryPart)}|{model.ModelStreamingMode.Name}|{attributesOf(model)}`,
	}
	for _, item in model:GetDescendants() do
		local detail = ""
		if item:IsA("BasePart") then
			local shape = if item:IsA("Part") then item.Shape.Name else "-"
			detail = table.concat({
				vec(item.Size),
				frame(pivot:ToObjectSpace(item.CFrame)),
				item.Color:ToHex(),
				item.Material.Name,
				num(item.Transparency),
				shape,
				`{item.Anchored}/{item.CanCollide}/{item.CanTouch}/{item.CanQuery}/{item.Massless}`,
			}, "|")
		elseif item:IsA("Attachment") then
			detail = frame(item.CFrame)
		elseif item:IsA("Motor6D") then
			detail = `{pathIn(model, item.Part0)}>{pathIn(model, item.Part1)}|{frame(item.C0)}|{frame(item.C1)}`
		elseif item:IsA("WeldConstraint") then
			detail = `{pathIn(model, item.Part0)}>{pathIn(model, item.Part1)}`
		elseif item:IsA("SpotLight") then
			detail =
				`{item.Enabled}|{item.Color:ToHex()}|{num(item.Brightness)}|{num(item.Range)}|{num(item.Angle)}|{item.Face.Name}`
		end
		table.insert(lines, `{pathIn(model, item)}|{item.ClassName}|{detail}|{attributesOf(item)}|{tagsOf(item)}`)
	end
	table.sort(lines)
	return lines
end

-- Lines of `a` that `b` lacks (counting repeats), at most `limit`.
local function linesMissing(a: { string }, b: { string }, limit: number): { string }
	local left: { [string]: number } = {}
	for _, line in b do
		left[line] = (left[line] or 0) + 1
	end
	local missing: { string } = {}
	for _, line in a do
		local count = left[line] or 0
		if count > 0 then
			left[line] = count - 1
		else
			table.insert(missing, line)
			if #missing >= limit then
				break
			end
		end
	end
	return missing
end

type Stored = { vehicleId: string, trimId: string, model: Model }

-- The greybox models stored for current catalog trims: in ServerStorage.VehicleModels, or for a trim whose model
-- there is final art, its greybox reference in ServerStorage.GreyboxReference (Dev/ArtPass.fit,
-- VehicleBuilder.storeReference).
local function storedModels(): { Stored }
	local stored: { Stored } = {}
	local folders: { Instance } = {}
	for _, name in { MODELS_FOLDER, VehicleBuilder.referenceFolder } do
		local folder = ServerStorage:FindFirstChild(name)
		if folder ~= nil then
			table.insert(folders, folder)
		end
	end
	for _, vehicleId in Catalog.vehicleIds() do
		local vehicle = Catalog.getVehicle(vehicleId)
		if vehicle == nil then
			continue
		end
		for _, trim in vehicle.trims do
			for _, folder in folders do
				local model = folder:FindFirstChild(Catalog.modelName(vehicleId, trim.id))
				if model ~= nil and model:IsA("Model") and model:GetAttribute(GREYBOX_ATTRIBUTE) == true then
					table.insert(stored, { vehicleId = vehicleId, trimId = trim.id, model = model })
					break
				end
			end
		end
	end
	return stored
end

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

		t.it("builds identical instances every time (fingerprints)", function()
			local differences: { string } = {}
			for _, vehicleId in { "ohm_summit", "ohm_hauler", "aldermoor_elowen", "northline_grapple" } do
				local trim = Catalog.defaultTrim(vehicleId)
				assert(trim, `no trim for {vehicleId}`)
				local first = VehicleBuilder.assemble(vehicleId, trim.id)
				local second = VehicleBuilder.assemble(vehicleId, trim.id)
				local a, b = fingerprint(first), fingerprint(second)
				first:Destroy()
				second:Destroy()
				for _, line in linesMissing(a, b, MAX_SHOWN) do
					table.insert(differences, `{vehicleId}: {line}`)
				end
				for _, line in linesMissing(b, a, MAX_SHOWN) do
					table.insert(differences, `{vehicleId}: {line}`)
				end
			end
			t.expect(differences).toEqual({})
		end)
	end)

	-- Phase 11 (see the header): the body kit move leaves every catalog model as it was.
	t.describe("VehicleBuilder after the body kit move", function()
		local stored = storedModels()
		if #stored == 0 then
			t.it("has no stored greybox models (VehicleModels, GreyboxReference) to check (nothing checked)", function()
				print("  VehicleBuilder.spec: no stored greybox models, so the before/after comparison did not run")
			end)
		end
		for _, entry in stored do
			local name = entry.model.Name
			t.it(`builds {name} exactly like its stored model`, function()
				local built = VehicleBuilder.assemble(entry.vehicleId, entry.trimId)
				local now = fingerprint(built)
				built:Destroy()
				local was = fingerprint(entry.model)
				local storedOnly = linesMissing(was, now, MAX_SHOWN)
				local builtOnly = linesMissing(now, was, MAX_SHOWN)
				for _, line in storedOnly do
					print(`  {name} stored only: {line}`)
				end
				for _, line in builtOnly do
					print(`  {name} built only:  {line}`)
				end
				t.expect(#storedOnly + #builtOnly).toBe(0)
			end)
		end
	end)
end
