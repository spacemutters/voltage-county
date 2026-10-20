--!strict
-- Vehicle/Appearance on real greybox models (Dev/VehicleBuilder.assemble, built in memory only, so nothing in
-- ServerStorage.VehicleModels is touched): applying a look is idempotent, paints the body, puts extras on the
-- right mount, rebuilds the wheel faces without touching the wheels' joints, shows the right plate, and never
-- changes a physics property. Edit-mode safe.

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local Appearance = require(ReplicatedStorage.Shared.Vehicle.Appearance)
local Catalog = require(ReplicatedStorage.Shared.Vehicle.Catalog)
local Customization = require(ReplicatedStorage.Shared.Config.Customization)
local Harness = require(ReplicatedStorage.Shared.Testing.Harness)
local VehicleBuilder = require(ServerScriptService.Server.Dev.VehicleBuilder)

-- Bespoke Ohm silhouettes (sedan, pickup, semi, pod, gull-wing SUV, hypercar) and a few generic bodies.
local VEHICLES = {
	"ohm_spark",
	"ohm_mesa",
	"ohm_hauler",
	"ohm_pod",
	"ohm_summit",
	"ohm_arc",
	"aldermoor_elowen",
	"ironwood_kestrow",
	"northline_grapple",
}

local TOLERANCE = 1e-3 -- Vector3 and CFrame are 32-bit floats

local function build(vehicleId: string): Model
	local trim = Catalog.defaultTrim(vehicleId)
	assert(trim, `no trim for {vehicleId}`)
	return VehicleBuilder.assemble(vehicleId, trim.id)
end

local function classOf(vehicleId: string): string
	local vehicle = Catalog.getVehicle(vehicleId)
	assert(vehicle, vehicleId)
	return vehicle.class
end

local function bodyStyleOf(vehicleId: string): string
	local vehicle = Catalog.getVehicle(vehicleId)
	assert(vehicle, vehicleId)
	return vehicle.bodyStyle
end

local function stockLook(): Customization.Look
	local d = Customization.defaults
	return {
		uid = "spec-car",
		paint = d.paint,
		finish = d.finish,
		wrap = d.wrap,
		wheels = d.wheels,
		rideHeight = d.rideHeight,
		tint = d.tint,
		caliper = d.caliper,
		extras = {},
		plateFormat = d.plateFormat,
		plateText = nil,
	}
end

-- A busy look: something in every category, with the first extra (and a second from another group) the class
-- may take.
local function fullLook(class: string, bodyStyle: string?): Customization.Look
	local extras: { string } = {}
	local groups: { [string]: boolean } = {}
	local mounts: { [string]: boolean } = {}
	for _, extra in Customization.extrasFor(class, bodyStyle) do
		local group = extra.group or extra.id
		if not groups[group] and not mounts[extra.mount] and #extras < 2 then
			groups[group] = true
			mounts[extra.mount] = true
			table.insert(extras, extra.id)
		end
	end
	local look = stockLook()
	look.paint = "cobalt"
	look.finish = "metallic"
	look.wrap = "rally"
	look.wheels = "five_star"
	look.rideHeight = -1
	look.tint = 0.75
	look.caliper = "red"
	look.extras = extras
	look.plateFormat = "classic"
	return look
end

-- A sorted list of "<full name>:<class>" for every descendant: equal lists mean the same instances.
local function inventory(model: Model): { string }
	local list = {}
	for _, descendant in model:GetDescendants() do
		table.insert(list, `{descendant:GetFullName()}:{descendant.ClassName}`)
	end
	table.sort(list)
	return list
end

local function near(a: Vector3, b: Vector3): boolean
	return (a - b).Magnitude <= TOLERANCE
end

local function chassisOf(model: Model): BasePart
	local chassis = model:FindFirstChild("Chassis")
	assert(chassis and chassis:IsA("BasePart"), "Chassis")
	return chassis
end

-- Everything physics reads: the chassis, the wheels' joints and hubs, and every other part's flags.
type PhysicsState = {
	chassis: { size: Vector3, cframe: CFrame, collide: boolean, massless: boolean, anchored: boolean, mass: number },
	joints: { [string]: { c0: CFrame, c1: CFrame, part0: Instance?, part1: Instance? } },
	hubs: { [string]: CFrame },
}

local function physicsOf(model: Model): PhysicsState
	local chassis = chassisOf(model)
	local state: PhysicsState = {
		chassis = {
			size = chassis.Size,
			cframe = chassis.CFrame,
			collide = chassis.CanCollide,
			massless = chassis.Massless,
			anchored = chassis.Anchored,
			mass = chassis.Mass,
		},
		joints = {},
		hubs = {},
	}
	local wheels = model:FindFirstChild("Wheels")
	assert(wheels, "Wheels")
	for _, name in { "FL", "FR", "RL", "RR" } do
		local wheel = wheels:FindFirstChild(name)
		local motor = if wheel then wheel:FindFirstChild("Motor") else nil
		assert(motor and motor:IsA("Motor6D"), `{name} Motor`)
		state.joints[name] = { c0 = motor.C0, c1 = motor.C1, part0 = motor.Part0, part1 = motor.Part1 }
		local hub = chassis:FindFirstChild("Wheel" .. name)
		assert(hub and hub:IsA("Attachment"), `Wheel{name}`)
		state.hubs[name] = hub.CFrame
	end
	return state
end

local function sameCFrame(a: CFrame, b: CFrame): boolean
	return near(a.Position, b.Position) and near(a.LookVector, b.LookVector) and near(a.UpVector, b.UpVector)
end

-- Every visual part follows the contract's physics rules (only the chassis is a body).
local function visualRuleBreakers(model: Model): { string }
	local chassis = chassisOf(model)
	local bad = {}
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") and descendant ~= chassis then
			if
				not descendant.Massless
				or descendant.Anchored
				or descendant.CanCollide
				or descendant.CanTouch
				or descendant.CanQuery
			then
				table.insert(bad, descendant:GetFullName())
			end
		end
	end
	return bad
end

-- The first Paint-tagged part in Body (a panel that ride height moves).
local function firstPanel(model: Model): BasePart
	local body = model:FindFirstChild("Body")
	assert(body, "Body")
	for _, descendant in body:GetDescendants() do
		if descendant:IsA("BasePart") and CollectionService:HasTag(descendant, "Paint") then
			return descendant
		end
	end
	error("no Paint part")
end

return function(t: Harness.Api)
	t.describe("Appearance.apply", function()
		for _, vehicleId in VEHICLES do
			local class = classOf(vehicleId)
			local bodyStyle = bodyStyleOf(vehicleId)

			t.it(`is idempotent on {vehicleId}`, function()
				local model = build(vehicleId)
				local look = fullLook(class, bodyStyle)
				Appearance.apply(model, look)
				local first = inventory(model)
				Appearance.apply(model, look)
				local second = inventory(model)
				-- Another look in between still comes back to the same instances.
				Appearance.apply(model, stockLook())
				Appearance.apply(model, look)
				local third = inventory(model)
				model:Destroy()
				t.expect(#second).toBe(#first)
				t.expect(second).toEqual(first)
				t.expect(third).toEqual(first)
			end)

			t.it(`paints, tints and keeps the contract's physics rules on {vehicleId}`, function()
				local model = build(vehicleId)
				local before = physicsOf(model)
				local look = fullLook(class, bodyStyle)
				Appearance.apply(model, look)
				local after = physicsOf(model)
				local paint = Customization.paintColor(look.paint)
				local finish = Customization.getFinish(look.finish)
				local tint = Customization.getTintLevel(look.tint)
				assert(paint and finish and tint, "catalog")

				local painted, wrongPaint, wrongGlass = 0, 0, 0
				for _, descendant in model:GetDescendants() do
					if not descendant:IsA("BasePart") then
						continue
					end
					if CollectionService:HasTag(descendant, "Paint") then
						painted += 1
						if descendant.Color ~= paint or descendant.Material ~= finish.material then
							wrongPaint += 1
						end
					end
					if
						CollectionService:HasTag(descendant, "Glass")
						and math.abs(descendant.Transparency - tint.transparency) > TOLERANCE
					then
						wrongGlass += 1
					end
				end
				local breakers = visualRuleBreakers(model)
				model:Destroy()

				t.expect(painted).toBeGreaterThan(0)
				t.expect(wrongPaint).toBe(0)
				t.expect(wrongGlass).toBe(0)
				for _, name in breakers do
					print(`  physics rule broken: {name}`)
				end
				t.expect(#breakers).toBe(0)
				-- Physics never changes: chassis, wheel joints and hubs are exactly as built.
				t.expect(near(after.chassis.size, before.chassis.size)).toBe(true)
				t.expect(sameCFrame(after.chassis.cframe, before.chassis.cframe)).toBe(true)
				t.expect(after.chassis.collide).toBe(before.chassis.collide)
				t.expect(after.chassis.massless).toBe(before.chassis.massless)
				t.expect(after.chassis.anchored).toBe(before.chassis.anchored)
				t.expect(after.chassis.mass).toBeNear(before.chassis.mass, TOLERANCE)
				for name, joint in before.joints do
					local now = after.joints[name]
					t.expect(sameCFrame(now.c0, joint.c0) and sameCFrame(now.c1, joint.c1)).toBe(true)
					t.expect(now.part0 == joint.part0 and now.part1 == joint.part1).toBe(true)
					t.expect(sameCFrame(after.hubs[name], before.hubs[name])).toBe(true)
				end
			end)

			t.it(`puts extras on their mounts on {vehicleId}`, function()
				local model = build(vehicleId)
				local look = fullLook(class, bodyStyle)
				t.expect(#look.extras).toBeGreaterThan(0)
				look.rideHeight = 0 -- extras ride with the body; at 0 they sit exactly on the mount
				Appearance.apply(model, look)
				local chassis = chassisOf(model)
				for _, extraId in look.extras do
					local extra = Customization.getExtra(extraId)
					assert(extra, extraId)
					local holder = Appearance.findExtra(model, extraId)
					t.expect(holder).toBeTruthy()
					if holder == nil then
						continue
					end
					t.expect(#holder:GetChildren()).toBe(#extra.pieces)
					local mount = chassis:FindFirstChild(extra.mount)
					assert(mount and mount:IsA("Attachment"), extra.mount)
					local size = Customization.extraSize(extra, class, bodyStyle)
					assert(size, "size")
					for _, piece in extra.pieces do
						local part = holder:FindFirstChild(piece.name)
						assert(part and part:IsA("BasePart"), piece.name)
						-- Each piece sits where its recipe puts it relative to the mount, welded to the chassis. A
						-- foot keeps its top there and may reach further down to the body.
						local expected = mount.WorldCFrame * CFrame.new(piece.center * size)
						if piece.foot then
							local top = expected * CFrame.new(0, piece.size.Y * size.Y / 2, 0)
							local partTop = part.CFrame * CFrame.new(0, part.Size.Y / 2, 0)
							t.expect(near(partTop.Position, top.Position)).toBe(true)
							t.expect(part.Size.Y >= piece.size.Y * size.Y - TOLERANCE).toBe(true)
							t.expect(part.Size.Y <= piece.size.Y * size.Y + Customization.extraFootReach + TOLERANCE)
								.toBe(true)
						else
							t.expect(near(part.Position, expected.Position)).toBe(true)
						end
						local weld = part:FindFirstChildOfClass("WeldConstraint")
						t.expect(weld ~= nil and weld.Part0 == chassis and weld.Part1 == part).toBe(true)
					end
				end
				model:Destroy()
			end)
		end

		t.it("leaves out extras the class can't take", function()
			local model = build("ohm_spark")
			local look = stockLook()
			look.extras = { "bull_bar", "lip_spoiler" } -- a sedan can't take a bull bar
			Appearance.apply(model, look)
			t.expect(Appearance.findExtra(model, "bull_bar")).toBe(nil)
			t.expect(Appearance.findExtra(model, "lip_spoiler")).toBeTruthy()
			model:Destroy()
		end)

		t.it("rebuilds each wheel's face and keeps the wheel and its Motor", function()
			local model = build("ohm_mesa")
			local look = stockLook()
			look.wheels = "turbine"
			look.caliper = "yellow"
			local wheels = model:FindFirstChild("Wheels")
			assert(wheels, "Wheels")
			local fl = wheels:FindFirstChild("FL")
			Appearance.apply(model, look)
			local style = Customization.getWheel("turbine")
			local caliper = Customization.getCaliper("yellow")
			assert(style and caliper, "catalog")
			t.expect(wheels:FindFirstChild("FL")).toBe(fl)
			for _, name in { "FL", "FR", "RL", "RR" } do
				local wheel = wheels:FindFirstChild(name)
				assert(wheel, name)
				t.expect(wheel:FindFirstChild("Motor")).toBeTruthy()
				local spokes = 0
				for _, child in wheel:GetChildren() do
					if child.Name == "Spoke" then
						spokes += 1
					end
				end
				-- Turbine has 7 spokes: an odd count is built spoke by spoke.
				t.expect(spokes).toBe(style.spokes)
				local disc = wheel:FindFirstChild("Caliper")
				assert(disc and disc:IsA("BasePart"), "Caliper")
				t.expect(disc.Color).toBe(caliper.color)
				t.expect(wheel:FindFirstChild("Rim")).toBeTruthy()
				t.expect(wheel:FindFirstChild("Cap")).toBeTruthy()
			end
			model:Destroy()
		end)

		t.it("moves only the visual body for ride height, and back", function()
			local model = build("ohm_spark")
			local chassis = chassisOf(model)
			local panel = firstPanel(model)
			local factory = chassis.CFrame:ToObjectSpace(panel.CFrame).Position
			local look = stockLook()
			look.rideHeight = -1
			Appearance.apply(model, look)
			local lowered = chassis.CFrame:ToObjectSpace(panel.CFrame).Position
			local offset = Appearance.bodyOffset(model, -1)
			t.expect(offset <= 0).toBe(true)
			t.expect(offset >= Customization.rideOffset(-1, classOf("ohm_spark")) - TOLERANCE).toBe(true)
			t.expect(lowered.Y - factory.Y).toBeNear(offset, TOLERANCE)
			t.expect(near(Vector3.new(lowered.X, 0, lowered.Z), Vector3.new(factory.X, 0, factory.Z))).toBe(true)

			look.rideHeight = 0
			Appearance.apply(model, look)
			local restored = chassis.CFrame:ToObjectSpace(panel.CFrame).Position
			t.expect(near(restored, factory)).toBe(true)
			model:Destroy()
		end)

		t.it("keeps the minimum ground clearance at the lowest stance", function()
			for _, vehicleId in { "kaze_rensa", "montevale_alzara", "ohm_spark", "ohm_mesa" } do
				local model = build(vehicleId)
				local chassis = chassisOf(model)
				local look = stockLook()
				look.rideHeight = Customization.rideHeight.min
				Appearance.apply(model, look)
				local ground = math.huge
				local wheels = model:FindFirstChild("Wheels")
				for _, name in { "FL", "FR", "RL", "RR" } do
					local hub = chassis:FindFirstChild("Wheel" .. name)
					local wheel = if wheels then wheels:FindFirstChild(name) else nil
					if hub and hub:IsA("Attachment") and wheel and wheel:IsA("BasePart") then
						ground = math.min(ground, hub.Position.Y - math.min(wheel.Size.Y, wheel.Size.Z) / 2)
					end
				end
				local lowest, factoryLowest = math.huge, math.huge
				local body = model:FindFirstChild("Body")
				for _, part in if body then body:GetDescendants() else {} do
					if part:IsA("BasePart") and not CollectionService:HasTag(part, Customization.lookTag) then
						local rel = chassis.CFrame:ToObjectSpace(part.CFrame)
						local half = part.Size / 2
						local reach = math.abs(rel.XVector.Y) * half.X
							+ math.abs(rel.YVector.Y) * half.Y
							+ math.abs(rel.ZVector.Y) * half.Z
						lowest = math.min(lowest, rel.Position.Y - reach)
						local base = part:GetAttribute("LookBase")
						if typeof(base) == "CFrame" then
							factoryLowest = math.min(factoryLowest, base.Position.Y - reach)
						end
					end
				end
				model:Destroy()
				-- Lowered no closer than the minimum (a body already lower than that isn't lowered at all).
				local floor = math.min(factoryLowest - ground, Customization.rideHeight.minClearance)
				t.expect(lowest - ground >= floor - TOLERANCE).toBe(true)
			end
		end)

		t.it("re-welds the lowered body so it moves with the car", function()
			-- Welds only act in the world, so this car goes into the Workspace for the check (and always comes
			-- back out, even if the check fails).
			local model = build("ohm_spark")
			local chassis = chassisOf(model)
			local panel = firstPanel(model)
			local look = stockLook()
			look.rideHeight = -1
			local ok, err = pcall(function()
				model.Parent = Workspace
				Appearance.apply(model, look)
				local lowered = chassis.CFrame:ToObjectSpace(panel.CFrame).Position
				chassis.CFrame = chassis.CFrame * CFrame.new(0, 0, 20) -- moves the whole welded car
				local moved = chassis.CFrame:ToObjectSpace(panel.CFrame).Position
				t.expect(near(moved, lowered)).toBe(true)
			end)
			model:Destroy()
			if not ok then
				error(err, 0)
			end
		end)

		t.it("brings trim and glass back to factory when the look goes back to stock", function()
			local model = build("aldermoor_elowen")
			local function snapshot(): { [string]: { any } }
				local state: { [string]: { any } } = {}
				for _, descendant in model:GetDescendants() do
					if descendant:IsA("BasePart") then
						local tagged = CollectionService:HasTag(descendant, "Trim")
							or CollectionService:HasTag(descendant, "Glass")
						if tagged then
							state[descendant:GetFullName()] = { descendant.Color, descendant.Transparency }
						end
					end
				end
				return state
			end
			Appearance.apply(model, stockLook())
			local stock = snapshot()
			Appearance.apply(model, fullLook(classOf("aldermoor_elowen")))
			Appearance.apply(model, stockLook())
			t.expect(snapshot()).toEqual(stock)
			model:Destroy()
		end)

		t.it("keeps the brand's own paint for the factory default, and brings it back after a repaint", function()
			local model = build("kaze_rensa")
			local function paintColors(): { [string]: Color3 }
				local colors: { [string]: Color3 } = {}
				for _, descendant in model:GetDescendants() do
					if descendant:IsA("BasePart") and CollectionService:HasTag(descendant, "Paint") then
						colors[descendant:GetFullName()] = descendant.Color
					end
				end
				return colors
			end
			local built = paintColors()
			t.expect(Customization.isFactoryPaint(Customization.defaults.paint)).toBe(true)
			local repainted = stockLook()
			repainted.paint = "cobalt"
			Appearance.apply(model, repainted)
			Appearance.apply(model, stockLook())
			local back = paintColors()
			model:Destroy()
			t.expect(next(built) ~= nil).toBe(true)
			t.expect(back).toEqual(built)
		end)

		t.it("lays wrap vinyl on the body, and none for no wrap", function()
			local model = build("ohm_spark")
			local look = stockLook()
			look.wrap = "twin_stripes"
			Appearance.apply(model, look)
			local function vinyl(): number
				local folder = model:FindFirstChild("Look")
				local count = 0
				if folder then
					for _, child in folder:GetChildren() do
						if child.Name == "Wrap" then
							count += 1
						end
					end
				end
				return count
			end
			local striped = vinyl()
			look.wrap = "none"
			Appearance.apply(model, look)
			local plain = vinyl()
			model:Destroy()
			t.expect(striped).toBeGreaterThan(0)
			t.expect(striped <= Customization.wrapMaxParts).toBe(true)
			t.expect(plain).toBe(0)
		end)

		t.it("shows the standard plate, filtered custom text, or a blank plate", function()
			local model = build("ohm_spark")
			local look = stockLook()
			local function plateText(pointName: string): string?
				local folder = model:FindFirstChild("Look")
				local plate = if folder then folder:FindFirstChild(pointName) else nil
				local gui = if plate then plate:FindFirstChild("PlateGui") else nil
				local label = if gui then gui:FindFirstChild("Number") else nil
				return if label and label:IsA("TextLabel") then label.Text else nil
			end
			Appearance.apply(model, look)
			local standard = Customization.standardPlateText(look.plateFormat, look.uid)
			t.expect(plateText("PlateFront")).toBe(standard)
			t.expect(plateText("PlateRear")).toBe(standard)
			look.plateText = "VOLT 24"
			Appearance.apply(model, look)
			t.expect(plateText("PlateRear")).toBe("VOLT 24")
			look.plateText = "" -- a failed filter call: blank
			Appearance.apply(model, look)
			t.expect(plateText("PlateRear")).toBe("")
			model:Destroy()
		end)

		t.it("remembers the applied look for the shop to revert to", function()
			local model = build("ironwood_kestrow")
			local look = fullLook(classOf("ironwood_kestrow"))
			Appearance.apply(model, look)
			local stored = Appearance.lookOf(model)
			model:Destroy()
			assert(stored, "lookOf")
			t.expect(stored.paint).toBe(look.paint)
			t.expect(stored.wheels).toBe(look.wheels)
			t.expect(stored.extras).toEqual(look.extras)
			t.expect(stored.rideHeight).toBe(look.rideHeight)
		end)

		t.it("fills in defaults for an old save missing the new fields", function()
			local model = build("ohm_spark")
			local old = { uid = "old", paint = "plum", finish = "matte", wheels = "stock", rideHeight = 0, tint = 0 }
			Appearance.apply(model, old :: any)
			local stored = Appearance.lookOf(model)
			model:Destroy()
			assert(stored, "lookOf")
			t.expect(stored.caliper).toBe(Customization.defaults.caliper)
			t.expect(stored.plateFormat).toBe(Customization.defaults.plateFormat)
			t.expect(stored.extras).toEqual({})
		end)
	end)
end
