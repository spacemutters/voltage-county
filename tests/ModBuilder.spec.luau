--!strict
-- Vehicle/ModBuilder (docs/phase-11-contracts.md "Kit"; PLAN.md Phase 11 "Mod spec") against Config/DesignKit.json,
-- on designed cars (Vehicle/SpecBuilder.build) and catalog cars (Dev/VehicleBuilder.assemble):
--   * a mod never touches physics: the Chassis (size, place, physical properties), the wheels (size, Motors, hub
--     attachments), the seat count and names, TowPoint and the feature attachments, the car's VehicleId and Trim;
--     everything it adds is massless, non-colliding and welded on
--   * catalog cars: only paint, finish, stripes, wheels, stance and extras change; the body shape never does, even
--     when the mod asks (as "catalog", or as "kit" on a car without a design spec)
--   * designed cars: the body re-proportions and swaps bumpers, lamps and spoiler around the same chassis and
--     wheels; the template (so the seats) never changes
--   * "keep" leaves everything; at most kit.limits.maxExtras extras, one per mount point, kept through a later look
--   * ride height moves only the visual body, never closer to the ground than Config/Customization allows; wheel
--     size scales only the wheel faces
--   * applying the same mod twice gives the same car as applying it once
-- Builds in memory only and destroys what it builds. Edit-mode safe.

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Appearance = require(ReplicatedStorage.Shared.Vehicle.Appearance)
local BodyKit = require(ReplicatedStorage.Shared.Vehicle.BodyKit)
local Catalog = require(ReplicatedStorage.Shared.Vehicle.Catalog)
local Customization = require(ReplicatedStorage.Shared.Config.Customization)
local Harness = require(ReplicatedStorage.Shared.Testing.Harness)
local ModBuilder = require(ReplicatedStorage.Shared.Vehicle.ModBuilder)
local SpecBuilder = require(ReplicatedStorage.Shared.Vehicle.SpecBuilder)
local VehicleBuilder = require(ServerScriptService.Server.Dev.VehicleBuilder)

local kit: any = require(ReplicatedStorage.Shared.Config.DesignKit)

local KEEP: string = kit.mod.keep
local BODY_NUMBERS = { "length", "height", "roofline", "noseSlope", "flare" }
local PART_FIELDS = { "frontBumper", "rearBumper", "spoiler", "lights", "wheels" }
local WHEELS = { "FL", "FR", "RL", "RR" }
-- What ModBuilder leaves on a model (its header).
local EXTRA_TAG = "ModExtra"
local RIDE_ATTRIBUTE = "ModRideOffset"
local WHEEL_ATTRIBUTE = "ModWheelScale"
local STRIPE_TAG = "DesignStripe" -- Vehicle/BodyKit stripes
-- Catalog cars across the body kit: bespoke Ohm silhouettes (gull-wing doors, a semi, a pickup) and generic bodies.
local CATALOG_CARS =
	{ "halden_corrin", "ohm_summit", "ohm_hauler", "ohm_mesa", "ironwood_kestrow", "northline_grapple" }
local PAINT_CAR = "halden_corrin" -- a sedan: a roof panel, and several extras fit it
local TOLERANCE = 2e-3 -- studs; Vector3 and CFrame are 32-bit
local PRECISION = 1000 -- fingerprint numbers are kept to thousandths

-- Helpers ---------------------------------------------------------------------------------------------------

local function change(value: number): { [string]: any }
	return { change = true, value = value }
end

-- A mod that keeps everything (PLAN.md "Mod spec": every field "keep").
local function keepMod(): { [string]: any }
	local mod: { [string]: any } = {
		refusal = nil,
		summary = "Nothing changes",
		accessoryPrompt = "none",
		body = { template = KEEP },
		parts = {},
		paint = { primary = KEEP, secondary = KEEP, finish = KEEP, stripe = KEEP },
		stance = { rideHeight = KEEP, wheelSize = KEEP },
		extras = KEEP,
	}
	for _, field in BODY_NUMBERS do
		mod.body[field] = KEEP
	end
	for _, field in PART_FIELDS do
		mod.parts[field] = KEEP
	end
	return mod
end

-- A mod that asks for every change the kit knows (each kind then takes only what it may).
local function everythingMod(): { [string]: any }
	local mod = keepMod()
	mod.body.template = "van"
	for _, field in BODY_NUMBERS do
		mod.body[field] = change(kit.ranges.body.max)
	end
	mod.parts = { frontBumper = "rugged", rearBumper = "diffuser", spoiler = "wing", lights = "bar", wheels = "trail" }
	mod.paint = { primary = "#AA2233", secondary = "#101820", finish = "matte", stripe = "center" }
	mod.stance = { rideHeight = change(0.5), wheelSize = change(kit.ranges.wheelSize.max) }
	mod.extras = { "lip_spoiler", "roof_rack", "rear_diffuser" }
	return mod
end

-- A complete, valid design spec, middle of every range, each list's first id.
local function designSpec(classId: string, template: string): { [string]: any }
	return {
		refusal = nil,
		name = "Mod Runner",
		tagline = "A design the specs mod",
		class = classId,
		energy = kit.classes[classId].energy[1],
		personality = "balanced",
		meshPrompt = "a rounded original test car",
		body = { template = template, length = 0.5, height = 0.5, roofline = 0.5, noseSlope = 0.5, flare = 0.5 },
		parts = {
			frontBumper = kit.parts.frontBumper[1],
			rearBumper = kit.parts.rearBumper[1],
			spoiler = kit.parts.spoiler[1],
			lights = kit.parts.lights[1],
			wheels = kit.parts.wheels[1],
		},
		paint = { primary = "#3366CC", secondary = "#202428", finish = kit.finishes[1], stripe = kit.stripes[1] },
		stance = { rideHeight = 0, wheelSize = 0.5 },
	}
end

local function designCar(classId: string?, template: string?): Model
	return SpecBuilder.build(designSpec(classId or "sedan", template or "sedan"), kit)
end

local function catalogCar(vehicleId: string): Model
	local trim = Catalog.defaultTrim(vehicleId)
	assert(trim, `no trim for {vehicleId}`)
	return VehicleBuilder.assemble(vehicleId, trim.id)
end

local function num(value: number): string
	return string.format("%d", math.round(value * PRECISION) + 0)
end

local function vec(value: Vector3): string
	return `{num(value.X)},{num(value.Y)},{num(value.Z)}`
end

local function frame(value: CFrame): string
	local parts: { string } = {}
	for _, component in { value:GetComponents() } do
		table.insert(parts, num(component))
	end
	return table.concat(parts, ",")
end

local function chassisOf(model: Model): BasePart
	local chassis = model:FindFirstChild("Chassis")
	assert(chassis ~= nil and chassis:IsA("BasePart"), `{model.Name} has no Chassis`)
	return chassis
end

local function isLookPart(instance: Instance): boolean
	return CollectionService:HasTag(instance, Customization.lookTag)
end

-- True for a mod extra or anything inside one.
local function inModExtra(instance: Instance): boolean
	local node: Instance? = instance
	while node ~= nil do
		if CollectionService:HasTag(node, EXTRA_TAG) then
			return true
		end
		node = node.Parent
	end
	return false
end

-- Everything that decides how the car drives, as sorted lines: equal lists mean equal physics.
local function physicsLines(model: Model): { string }
	local chassis = chassisOf(model)
	local lines: { string } = {}
	local properties = chassis.CustomPhysicalProperties
	table.insert(
		lines,
		table.concat({
			"chassis",
			vec(chassis.Size),
			frame(model:GetPivot():ToObjectSpace(chassis.CFrame)),
			if properties
				then `{num(properties.Density)},{num(properties.Friction)},{num(properties.Elasticity)}`
				else "-",
			`{chassis.Anchored}/{chassis.CanCollide}/{chassis.Massless}/{num(chassis.Transparency)}`,
		}, " ")
	)
	for _, child in chassis:GetChildren() do
		if child:IsA("Attachment") and table.find(BodyKit.VISUAL_POINTS, child.Name) == nil then
			table.insert(lines, `attachment {child.Name} {frame(child.CFrame)}`)
		end
	end
	local wheels = model:FindFirstChild("Wheels")
	for _, name in WHEELS do
		local wheel = if wheels then wheels:FindFirstChild(name) else nil
		local motor = if wheel then wheel:FindFirstChild("Motor") else nil
		if wheel == nil or not wheel:IsA("BasePart") or motor == nil or not motor:IsA("Motor6D") then
			table.insert(lines, `wheel {name} missing`)
			continue
		end
		local joined = motor.Part0 == chassis and motor.Part1 == wheel
		table.insert(lines, `wheel {name} {vec(wheel.Size)} {frame(motor.C0)} {frame(motor.C1)} {joined}`)
	end
	local seats = model:FindFirstChild("Seats")
	if seats ~= nil then
		for _, seat in seats:GetChildren() do
			if seat:IsA("Seat") then
				table.insert(lines, `seat {seat.Name}`)
			end
		end
	end
	local mass = 0
	for _, part in model:GetDescendants() do
		if part:IsA("BasePart") and not part.Massless then
			mass += part:GetMass()
		end
	end
	table.insert(lines, `mass {num(mass)}`)
	for _, name in { "VehicleId", "Trim", "BrandId" } do
		table.insert(lines, `{name} {tostring(model:GetAttribute(name))}`)
	end
	table.sort(lines)
	return lines
end

-- Every visual part that breaks the contract's rules: massless, unanchored, no collision, touch or raycast, and
-- welded to the Chassis (or to the wheel or door it sits on).
local function visualProblems(model: Model): { string }
	local chassis = chassisOf(model)
	local problems: { string } = {}
	for _, part in model:GetDescendants() do
		if not part:IsA("BasePart") or part == chassis then
			continue
		end
		if not part.Massless or part.Anchored or part.CanCollide or part.CanTouch or part.CanQuery then
			table.insert(problems, `{part:GetFullName()}: takes part in physics`)
		end
		local target: Instance? = nil
		for _, child in part:GetChildren() do
			if child:IsA("WeldConstraint") or child:IsA("Motor6D") then
				local joint = child :: any -- both classes have Part0 and Part1
				if joint.Part1 == part then
					target = joint.Part0
				end
			end
		end
		if target == nil or (target ~= chassis and target ~= part.Parent) then
			table.insert(problems, `{part:GetFullName()}: not welded on`)
		end
	end
	return problems
end

-- The body's shape: every Body and Lights part (not the look's, a stripe or a mod extra) by name, class, size and
-- place on the Chassis, sorted.
local function bodyShape(model: Model): { string }
	local chassis = chassisOf(model)
	local lines: { string } = {}
	for _, folderName in { "Body", "Lights" } do
		local folder = model:FindFirstChild(folderName)
		if folder == nil then
			continue
		end
		for _, part in folder:GetDescendants() do
			if
				part:IsA("BasePart")
				and not isLookPart(part)
				and not CollectionService:HasTag(part, STRIPE_TAG)
				and not inModExtra(part)
			then
				local at = chassis.CFrame:ToObjectSpace(part.CFrame)
				table.insert(lines, `{folderName}/{part.Name} {part.ClassName} {vec(part.Size)} {frame(at)}`)
			end
		end
	end
	table.sort(lines)
	return lines
end

-- Every instance by path, class, size, place on the Chassis and color, sorted (the whole car as built).
local function wholeCar(model: Model): { string }
	local chassis = chassisOf(model)
	local lines: { string } = {}
	for _, item in model:GetDescendants() do
		local names: { string } = {}
		local node: Instance? = item
		while node ~= nil and node ~= model do
			table.insert(names, 1, node.Name)
			node = node.Parent
		end
		local detail = ""
		if item:IsA("BasePart") then
			local at = chassis.CFrame:ToObjectSpace(item.CFrame)
			detail = `{vec(item.Size)} {frame(at)} {item.Color:ToHex()} {item.Material.Name}`
		elseif item:IsA("Attachment") then
			detail = frame(item.CFrame)
		end
		table.insert(lines, `{table.concat(names, "/")} {item.ClassName} {detail}`)
	end
	table.sort(lines)
	return lines
end

-- The chassis-space height of each visual body part (not the look's or a mod extra), by name.
local function bodyHeights(model: Model): { [string]: number }
	local chassis = chassisOf(model)
	local heights: { [string]: number } = {}
	for _, folderName in { "Body", "Lights" } do
		local folder = model:FindFirstChild(folderName)
		if folder == nil then
			continue
		end
		for _, part in folder:GetDescendants() do
			if part:IsA("BasePart") and not isLookPart(part) and not inModExtra(part) then
				heights[`{folderName}/{part:GetFullName()}`] = chassis.CFrame:ToObjectSpace(part.CFrame).Y
			end
		end
	end
	return heights
end

-- Chassis-space heights of the ground under the wheels and of the lowest visual body part.
local function groundAndLowest(model: Model): (number, number)
	local chassis = chassisOf(model)
	local ground = math.huge
	local wheels = model:FindFirstChild("Wheels")
	if wheels ~= nil then
		for _, wheel in wheels:GetChildren() do
			local hub = chassis:FindFirstChild("Wheel" .. wheel.Name)
			if wheel:IsA("BasePart") and hub ~= nil and hub:IsA("Attachment") then
				ground = math.min(ground, hub.Position.Y - math.min(wheel.Size.Y, wheel.Size.Z) / 2)
			end
		end
	end
	local lowest = math.huge
	local body = model:FindFirstChild("Body")
	if body ~= nil then
		for _, part in body:GetDescendants() do
			if part:IsA("BasePart") and not isLookPart(part) and not inModExtra(part) then
				local rel = chassis.CFrame:ToObjectSpace(part.CFrame)
				local half = part.Size / 2
				local reach = math.abs(rel.XVector.Y) * half.X
					+ math.abs(rel.YVector.Y) * half.Y
					+ math.abs(rel.ZVector.Y) * half.Z
				lowest = math.min(lowest, rel.Position.Y - reach)
			end
		end
	end
	return ground, lowest
end

-- The extras a mod left on the model (their holders, tagged EXTRA_TAG in Body).
local function modExtras(model: Model): { Instance }
	local list: { Instance } = {}
	local body = model:FindFirstChild("Body")
	if body ~= nil then
		for _, child in body:GetChildren() do
			if CollectionService:HasTag(child, EXTRA_TAG) then
				table.insert(list, child)
			end
		end
	end
	return list
end

-- The z extent of the painted body (front to back), in chassis space.
local function paintedLength(model: Model): number
	local chassis = chassisOf(model)
	local front, back = math.huge, -math.huge
	for _, part in model:GetDescendants() do
		if part:IsA("BasePart") and CollectionService:HasTag(part, "Paint") and not isLookPart(part) then
			local rel = chassis.CFrame:ToObjectSpace(part.CFrame)
			local half = part.Size / 2
			local reach = math.abs(rel.XVector.Z) * half.X
				+ math.abs(rel.YVector.Z) * half.Y
				+ math.abs(rel.ZVector.Z) * half.Z
			front = math.min(front, rel.Position.Z - reach)
			back = math.max(back, rel.Position.Z + reach)
		end
	end
	return back - front
end

local function bodyNames(model: Model): { [string]: boolean }
	local names: { [string]: boolean } = {}
	local body = model:FindFirstChild("Body")
	if body ~= nil then
		for _, part in body:GetDescendants() do
			if part:IsA("BasePart") and not isLookPart(part) and not inModExtra(part) then
				names[part.Name] = true
			end
		end
	end
	return names
end

local function hexOf(color: Color3): string
	return "#" .. string.upper(color:ToHex())
end

-- Lines that differ between two sorted lists (either side), labelled.
local function differences(label: string, before: { string }, after: { string }): { string }
	local count: { [string]: number } = {}
	for _, line in before do
		count[line] = (count[line] or 0) + 1
	end
	for _, line in after do
		count[line] = (count[line] or 0) - 1
	end
	local lines: { string } = {}
	for line, left in count do
		if left ~= 0 then
			table.insert(lines, `{label}: {if left > 0 then "lost" else "gained"} {line}`)
		end
	end
	table.sort(lines)
	return lines
end

local function append(into: { string }, from: { string })
	for _, line in from do
		table.insert(into, line)
	end
end

-- Specs ------------------------------------------------------------------------------------------------------

return function(t: Harness.Api)
	t.describe("ModBuilder.changes", function()
		t.it("is empty for a mod that keeps everything", function()
			t.expect(ModBuilder.changes(keepMod(), kit, "kit")).toEqual({})
			t.expect(ModBuilder.changes(keepMod(), kit, "catalog")).toEqual({})
		end)

		t.it("lets a catalog car change only paint, stance, wheels and extras", function()
			local problems: { string } = {}
			local changes = ModBuilder.changes(everythingMod(), kit, "catalog")
			for _, field in changes do
				local allowed = string.sub(field, 1, 6) == "paint."
					or string.sub(field, 1, 7) == "stance."
					or field == "parts.wheels"
					or field == "extras"
				if not allowed then
					table.insert(problems, field)
				end
			end
			t.expect(problems).toEqual({})
			for _, field in { "paint.primary", "paint.stripe", "stance.rideHeight", "parts.wheels", "extras" } do
				t.expect({ field = field, listed = table.find(changes, field) ~= nil })
					.toEqual({ field = field, listed = true })
			end
		end)

		t.it("lets a designed car change its body and parts too, never the template", function()
			local changes = ModBuilder.changes(everythingMod(), kit, "kit")
			for _, field in { "body.length", "body.noseSlope", "parts.frontBumper", "parts.spoiler", "paint.primary" } do
				t.expect({ field = field, listed = table.find(changes, field) ~= nil })
					.toEqual({ field = field, listed = true })
			end
			t.expect(table.find(changes, "body.template")).toBe(nil)
		end)

		t.it("keeps at most maxExtras extras, one per mount point, kit ids only", function()
			local mod = keepMod()
			-- More than maxExtras, several per mount, and one the kit doesn't have.
			mod.extras = {
				"roof_rack",
				"roof_box",
				"light_bar",
				"made_up",
				"bull_bar",
				"front_splitter",
				"wing_spoiler",
				"rear_diffuser",
				"lip_spoiler",
			}
			local model = catalogCar(PAINT_CAR)
			ModBuilder.apply(model, mod, kit, "catalog")
			local holders = modExtras(model)
			local mounts: { [string]: boolean } = {}
			local problems: { string } = {}
			for _, holder in holders do
				local id = holder:GetAttribute("ExtraId")
				local extra = if type(id) == "string" then kit.extras[id] else nil
				if extra == nil then
					table.insert(problems, `unknown extra {tostring(id)}`)
				elseif mounts[extra.mount] then
					table.insert(problems, `two extras on {extra.mount}`)
				else
					mounts[extra.mount] = true
				end
			end
			model:Destroy()
			t.expect(problems).toEqual({})
			t.expect(#holders <= kit.limits.maxExtras).toBe(true)
		end)
	end)

	t.describe("ModBuilder on catalog cars", function()
		t.it("never changes physics, even with everything asked", function()
			local problems: { string } = {}
			for _, vehicleId in CATALOG_CARS do
				local model = catalogCar(vehicleId)
				local before = physicsLines(model)
				ModBuilder.apply(model, everythingMod(), kit, "catalog")
				append(problems, differences(vehicleId, before, physicsLines(model)))
				append(problems, visualProblems(model))
				model:Destroy()
			end
			t.expect(problems).toEqual({})
		end)

		t.it("never changes the body shape, as a catalog mod or as a kit mod", function()
			local problems: { string } = {}
			local kinds: { ModBuilder.Kind } = { "catalog", "kit" }
			for index = 1, #kinds do
				local kind: ModBuilder.Kind = kinds[index]
				for _, vehicleId in CATALOG_CARS do
					local mod = everythingMod()
					mod.stance.rideHeight = KEEP -- ride height moves the body as a whole (checked below)
					local model = catalogCar(vehicleId)
					local before = bodyShape(model)
					ModBuilder.apply(model, mod, kit, kind)
					append(problems, differences(`{vehicleId} {kind}`, before, bodyShape(model)))
					model:Destroy()
				end
			end
			t.expect(problems).toEqual({})
		end)

		t.it("paints primary and roof secondary, lays stripes in secondary, and takes them off again", function()
			local mod = keepMod()
			mod.paint = { primary = "#AA2233", secondary = "#101820", finish = KEEP, stripe = "center" }
			local model = catalogCar(PAINT_CAR)
			ModBuilder.apply(model, mod, kit, "catalog")
			local problems: { string } = {}
			local roofs = 0
			for _, part in model:GetDescendants() do
				if not part:IsA("BasePart") or isLookPart(part) or not CollectionService:HasTag(part, "Paint") then
					continue
				end
				local roof = BodyKit.ROOF_PANELS[part.Name] == true
				if roof then
					roofs += 1
				end
				local wanted = if roof then mod.paint.secondary else mod.paint.primary
				if hexOf(part.Color) ~= wanted then
					table.insert(problems, `{part.Name}: {hexOf(part.Color)}, wanted {wanted}`)
				end
			end
			local stripes = BodyKit.stripes(model)
			for _, stripe in stripes do
				if hexOf(stripe.Color) ~= mod.paint.secondary then
					table.insert(problems, `stripe {hexOf(stripe.Color)}`)
				end
			end
			local laid = #stripes
			local off = keepMod()
			off.paint.stripe = "none"
			ModBuilder.apply(model, off, kit, "catalog")
			local left = #BodyKit.stripes(model)
			model:Destroy()
			t.expect(problems).toEqual({})
			t.expect(roofs).toBeGreaterThan(0)
			t.expect(laid).toBeGreaterThan(0)
			t.expect(left).toBe(0)
		end)

		t.it("builds extras that fit the car and keeps them through a later look", function()
			local mod = keepMod()
			mod.extras = { "lip_spoiler", "roof_rack", "front_splitter", "rear_diffuser" }
			local model = catalogCar(PAINT_CAR)
			local vehicle = Catalog.getVehicle(PAINT_CAR)
			assert(vehicle, PAINT_CAR)
			ModBuilder.apply(model, mod, kit, "catalog")
			local placed = #modExtras(model)
			local problems: { string } = {}
			for _, holder in modExtras(model) do
				local id = holder:GetAttribute("ExtraId")
				if type(id) ~= "string" or not Customization.extraAllowed(id, vehicle.class, vehicle.bodyStyle) then
					table.insert(problems, `{tostring(id)} doesn't fit {PAINT_CAR}`)
				end
			end
			-- Re-applying the look on record (the Wrap & Tint preview does) keeps them, and never builds them twice.
			local look = Appearance.lookOf(model)
			if look ~= nil then
				Appearance.apply(model, look)
			end
			local kept = #modExtras(model)
			for _, id in mod.extras do
				if Appearance.findExtra(model, id) ~= nil then
					table.insert(problems, `{id} built a second time by the look`)
				end
			end
			model:Destroy()
			t.expect(problems).toEqual({})
			t.expect(placed).toBeGreaterThan(0)
			t.expect(kept).toBe(placed)
		end)

		t.it("raises only the visual body, and lowers it no nearer the ground than allowed", function()
			local raise = keepMod()
			raise.stance.rideHeight = change(kit.ranges.rideHeight.max)
			local model = catalogCar(PAINT_CAR)
			local factory = bodyHeights(model)
			local _, factoryLowest = groundAndLowest(model)
			local physics = physicsLines(model)
			ModBuilder.apply(model, raise, kit, "catalog")
			local raised = bodyHeights(model)
			local raisedBy = model:GetAttribute(RIDE_ATTRIBUTE)
			local problems: { string } = {}
			local lift = kit.proportions.rideHeight.max
			for name, y in factory do
				local now = raised[name]
				if now == nil or math.abs(now - y - lift) > TOLERANCE then
					table.insert(problems, `{name}: raised {if now then now - y else "gone"}, wanted {lift}`)
				end
			end

			local lower = keepMod()
			lower.stance.rideHeight = change(kit.ranges.rideHeight.min)
			ModBuilder.apply(model, lower, kit, "catalog")
			local ground, lowest = groundAndLowest(model)
			local loweredBy = model:GetAttribute(RIDE_ATTRIBUTE)
			append(problems, differences("physics", physics, physicsLines(model)))
			model:Destroy()
			t.expect(problems).toEqual({})
			t.expect(raisedBy).toBeNear(lift, TOLERANCE)
			t.expect(type(loweredBy) == "number").toBe(true)
			t.expect(loweredBy :: number >= kit.proportions.rideHeight.min - TOLERANCE).toBe(true)
			t.expect(loweredBy :: number <= TOLERANCE).toBe(true)
			local floor = math.min(factoryLowest, ground + Customization.rideHeight.minClearance)
			t.expect(lowest >= floor - TOLERANCE).toBe(true)
		end)

		t.it("scales only the wheel faces for wheel size", function()
			local big = keepMod()
			big.stance.wheelSize = change(kit.ranges.wheelSize.max)
			local plain = catalogCar(PAINT_CAR)
			local scaled = catalogCar(PAINT_CAR)
			ModBuilder.apply(plain, keepMod(), kit, "catalog")
			local physics = physicsLines(scaled)
			ModBuilder.apply(scaled, big, kit, "catalog")
			local scale = scaled:GetAttribute(WHEEL_ATTRIBUTE)
			local function rimOf(model: Model): number
				local wheels = model:FindFirstChild("Wheels")
				local wheel = if wheels then wheels:FindFirstChild("FL") else nil
				local rim = if wheel then wheel:FindFirstChild("Rim") else nil
				return if rim ~= nil and rim:IsA("BasePart") then rim.Size.Y else 0
			end
			local plainRim, scaledRim = rimOf(plain), rimOf(scaled)
			local changes = differences("physics", physics, physicsLines(scaled))
			plain:Destroy()
			scaled:Destroy()
			t.expect(changes).toEqual({})
			t.expect(type(scale) == "number" and scale > 1).toBe(true)
			t.expect(plainRim).toBeGreaterThan(0)
			t.expect(scaledRim / plainRim).toBeNear(scale :: number, TOLERANCE)
		end)

		t.it("gives the same car when the same mod goes on twice", function()
			local mod = everythingMod()
			local once = catalogCar(PAINT_CAR)
			local twice = catalogCar(PAINT_CAR)
			ModBuilder.apply(once, mod, kit, "catalog")
			ModBuilder.apply(twice, mod, kit, "catalog")
			ModBuilder.apply(twice, mod, kit, "catalog")
			local changes = differences("twice", wholeCar(once), wholeCar(twice))
			once:Destroy()
			twice:Destroy()
			t.expect(changes).toEqual({})
		end)
	end)

	t.describe("ModBuilder on designed cars", function()
		t.it("re-proportions the body and swaps its parts around the same chassis and wheels", function()
			local mod = keepMod()
			mod.body.length = change(kit.ranges.body.max)
			mod.parts.frontBumper = "rugged"
			mod.parts.rearBumper = "diffuser"
			mod.parts.spoiler = "wing"
			local model = designCar()
			local physics = physicsLines(model)
			local lengthBefore = paintedLength(model)
			ModBuilder.apply(model, mod, kit, "kit")
			local names = bodyNames(model)
			local spec = SpecBuilder.specOf(model, kit)
			local problems = differences("physics", physics, physicsLines(model))
			append(problems, visualProblems(model))
			local lengthAfter = paintedLength(model)
			model:Destroy()
			t.expect(problems).toEqual({})
			t.expect(spec ~= nil).toBe(true)
			if spec ~= nil then
				t.expect(spec.body.length).toBe(kit.ranges.body.max)
				t.expect(spec.parts.frontBumper).toBe("rugged")
				t.expect(spec.parts.rearBumper).toBe("diffuser")
				t.expect(spec.parts.spoiler).toBe("wing")
			end
			t.expect(names.Skid == true and names.Diffuser == true and names.WingBlade == true).toBe(true)
			t.expect(lengthAfter).toBeGreaterThan(lengthBefore)
		end)

		t.it("never changes physics at the extremes of every number, template by template", function()
			local problems: { string } = {}
			local seen: { [string]: boolean } = {}
			local classIds: { string } = {}
			for classId in kit.classes do
				table.insert(classIds, classId)
			end
			table.sort(classIds)
			for _, classId in classIds do
				for _, template in kit.classes[classId].templates do
					if seen[template] then
						continue
					end
					seen[template] = true
					for _, value in { kit.ranges.body.min, kit.ranges.body.max } do
						local mod = everythingMod()
						for _, field in BODY_NUMBERS do
							mod.body[field] = change(value)
						end
						mod.stance.rideHeight = change(if value > 0 then 1 else -1)
						local model = designCar(classId, template)
						local before = physicsLines(model)
						ModBuilder.apply(model, mod, kit, "kit")
						append(problems, differences(`{template} {value}`, before, physicsLines(model)))
						append(problems, visualProblems(model))
						model:Destroy()
					end
				end
			end
			t.expect(problems).toEqual({})
		end)

		t.it("keeps the template, so the seats, whatever the mod asks", function()
			local mod = everythingMod() -- asks for the van template
			local model = designCar()
			ModBuilder.apply(model, mod, kit, "kit")
			local spec = SpecBuilder.specOf(model, kit)
			model:Destroy()
			t.expect(spec ~= nil and spec.body.template).toBe("sedan")
		end)

		t.it("leaves the design as it was for a mod that keeps everything", function()
			local model = designCar()
			local shape = bodyShape(model)
			local physics = physicsLines(model)
			local specBefore = SpecBuilder.specOf(model, kit)
			ModBuilder.apply(model, keepMod(), kit, "kit")
			local problems = differences("body", shape, bodyShape(model))
			append(problems, differences("physics", physics, physicsLines(model)))
			local specAfter = SpecBuilder.specOf(model, kit)
			model:Destroy()
			t.expect(problems).toEqual({})
			t.expect(specAfter).toEqual(specBefore)
		end)

		t.it("gives the same car when the same mod goes on twice", function()
			local mod = everythingMod()
			local once = designCar("suv", "suv")
			local twice = designCar("suv", "suv")
			ModBuilder.apply(once, mod, kit, "kit")
			ModBuilder.apply(twice, mod, kit, "kit")
			ModBuilder.apply(twice, mod, kit, "kit")
			local changes = differences("twice", wholeCar(once), wholeCar(twice))
			once:Destroy()
			twice:Destroy()
			t.expect(changes).toEqual({})
		end)
	end)
end
