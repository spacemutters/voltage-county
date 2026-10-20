--!strict
-- Vehicle/SpecBuilder (docs/phase-11-contracts.md "Kit" and "Designs in the catalog"; PLAN.md Phase 11 "Design
-- spec") against Config/DesignKit.json:
--   * every template of every designable class, at every personality, builds a model that passes the vehicle model
--     contract inside the part budget, with every parts variant, finish and stripe used along the way, and at the
--     extremes of every number
--   * stats sit inside the class band and at or under its ceiling (kit.bandCeiling), and come only from class and
--     personality
--   * out-of-range, forged and missing numbers clamp to the kit ranges; unknown ids fall back to kit ids
--   * geometry follows kit.templates x kit.proportions; builds and catalog entries are deterministic
--   * the build's name and attributes, paint, stripes, spoilers and bumper variants
--   * a published entry resolves through Vehicle/Catalog as "custom:<uid>" (server only)
-- Builds in memory only and destroys what it builds; the catalog check removes what it publishes. Edit-mode safe.

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local BodyKit = require(ReplicatedStorage.Shared.Vehicle.BodyKit)
local Catalog = require(ReplicatedStorage.Shared.Vehicle.Catalog)
local Classes = require(ReplicatedStorage.Shared.Config.Classes)
local Customization = require(ReplicatedStorage.Shared.Config.Customization)
local Designer = require(ReplicatedStorage.Shared.Config.Designer)
local Garage = require(ReplicatedStorage.Shared.Config.Garage)
local Harness = require(ReplicatedStorage.Shared.Testing.Harness)
local SpecBuilder = require(ReplicatedStorage.Shared.Vehicle.SpecBuilder)

local kit: any = require(ReplicatedStorage.Shared.Config.DesignKit)

local UID = "specbuilder-spec" -- the design uid builds here use
local BODY_NUMBERS = { "length", "height", "roofline", "noseSlope", "flare" }
local PART_FIELDS = { "frontBumper", "rearBumper", "spoiler", "lights", "wheels" }
local UP_STATS = { "topSpeedMph", "handling", "energyMinutes" } -- higher is better
local DRIVES = { "FWD", "RWD", "AWD" }
local STRIPE_TAG = "DesignStripe" -- Vehicle/BodyKit stripes
local GEOMETRY_TOLERANCE = 2e-3 -- SpecBuilder keeps geometry to thousandths
local EPSILON = 1e-6
local PRECISION = 1000 -- fingerprint numbers are kept to thousandths

-- Helpers ---------------------------------------------------------------------------------------------------

local function sortedKeys(map: { [string]: any }): { string }
	local keys: { string } = {}
	for key in map do
		table.insert(keys, key)
	end
	table.sort(keys)
	return keys
end

local function personalities(): { string }
	return sortedKeys(kit.personalities)
end

-- Every designable class with one template it lists, so each template appears at least once.
local function templateClasses(): { { classId: string, template: string } }
	local seen: { [string]: boolean } = {}
	local list: { { classId: string, template: string } } = {}
	for _, classId in sortedKeys(kit.classes) do
		for _, template in kit.classes[classId].templates do
			if not seen[template] then
				seen[template] = true
				table.insert(list, { classId = classId, template = template })
			end
		end
	end
	return list
end

-- A complete, valid design spec (PLAN.md "Design spec"), middle of every range, each list's first id.
local function baseSpec(classId: string, template: string, personality: string?): { [string]: any }
	local class = kit.classes[classId]
	return {
		refusal = nil,
		name = "Spec Runner",
		tagline = "A design the specs build",
		class = classId,
		energy = class.energy[1],
		personality = personality or personalities()[1],
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

-- The list's entry for `index` (1-based, wrapping), so a loop walks through every variant.
local function nth(list: { string }, index: number): string
	return list[(index - 1) % #list + 1]
end

-- Builds the spec and lists everything wrong with the result: a build error, a contract problem, too many parts.
local function buildProblems(spec: any, label: string): { string }
	local ok, result = pcall(SpecBuilder.build, spec, kit, UID)
	if not ok then
		return { `{label}: {result}` }
	end
	local model = result :: Model
	local problems: { string } = {}
	for _, message in SpecBuilder.check(model, spec, kit, UID) do
		table.insert(problems, `{label}: {message}`)
	end
	local count = BodyKit.partCount(model)
	if count > BodyKit.MAX_PARTS then
		table.insert(problems, `{label}: {count} parts (budget {BodyKit.MAX_PARTS})`)
	end
	model:Destroy()
	return problems
end

local function append(into: { string }, from: { string })
	for _, line in from do
		table.insert(into, line)
	end
end

-- Every way the stats leave the class band or pass its ceiling (kit.bandCeiling).
local function statProblems(classId: string, stats: any, label: string): { string }
	local band = Classes[classId]
	local ceiling = kit.bandCeiling
	local problems: { string } = {}
	for _, field in UP_STATS do
		local range = (band :: any)[field]
		local top = range.min + (range.max - range.min) * ceiling
		local value = stats[field]
		if type(value) ~= "number" or value < range.min - EPSILON or value > top + EPSILON then
			table.insert(problems, `{label}: {field} {tostring(value)} outside {range.min}..{top}`)
		end
	end
	local zero = band.zeroToSixtySec
	local best = zero.max - (zero.max - zero.min) * ceiling
	local value = stats.zeroToSixtySec
	if type(value) ~= "number" or value < best - EPSILON or value > zero.max + EPSILON then
		table.insert(problems, `{label}: zeroToSixtySec {tostring(value)} outside {best}..{zero.max}`)
	end
	local seats = stats.seats
	if type(seats) ~= "number" or seats % 1 ~= 0 or seats < band.seats.min or seats > band.seats.max then
		table.insert(problems, `{label}: seats {tostring(seats)} outside {band.seats.min}..{band.seats.max}`)
	end
	if table.find(DRIVES, stats.drive) == nil then
		table.insert(problems, `{label}: drive {tostring(stats.drive)}`)
	end
	return problems
end

local function num(value: number): string
	return string.format("%d", math.round(value * PRECISION) + 0)
end

-- One sorted line per instance: path, class, size, CFrame from the pivot, color, material and attributes.
local function fingerprint(model: Model): { string }
	local pivot = model:GetPivot()
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
			local parts: { string } = {}
			for _, component in { pivot:ToObjectSpace(item.CFrame):GetComponents() } do
				table.insert(parts, num(component))
			end
			local size = item.Size
			detail = `{num(size.X)},{num(size.Y)},{num(size.Z)}|{table.concat(parts, ",")}|{item.Color:ToHex()}|`
				.. item.Material.Name
		elseif item:IsA("Attachment") then
			local position = item.Position
			detail = `{num(position.X)},{num(position.Y)},{num(position.Z)}`
		end
		table.insert(lines, `{table.concat(names, "/")}|{item.ClassName}|{detail}`)
	end
	table.sort(lines)
	return lines
end

local function hexOf(color: Color3): string
	return "#" .. string.upper(color:ToHex())
end

-- Body parts (and their names) in a built model.
local function bodyNames(model: Model): { [string]: boolean }
	local names: { [string]: boolean } = {}
	local body = model:FindFirstChild("Body")
	if body ~= nil then
		for _, part in body:GetDescendants() do
			if part:IsA("BasePart") then
				names[part.Name] = true
			end
		end
	end
	return names
end

local function build(spec: any): Model
	return SpecBuilder.build(spec, kit, UID)
end

-- Specs ------------------------------------------------------------------------------------------------------

return function(t: Harness.Api)
	t.describe("SpecBuilder builds", function()
		t.it("every class, template and personality to the model contract inside the part budget", function()
			local problems: { string } = {}
			local index = 0
			for _, classId in sortedKeys(kit.classes) do
				local class = kit.classes[classId]
				for _, template in class.templates do
					for _, personality in personalities() do
						index += 1
						-- Walk every parts variant, energy, finish and stripe across the builds.
						local spec = baseSpec(classId, template, personality)
						spec.energy = nth(class.energy, index)
						for _, field in PART_FIELDS do
							spec.parts[field] = nth(kit.parts[field], index)
						end
						spec.paint.finish = nth(kit.finishes, index)
						spec.paint.stripe = nth(kit.stripes, index)
						append(problems, buildProblems(spec, `{classId}/{template}/{personality}`))
					end
				end
			end
			t.expect(problems).toEqual({})
		end)

		t.it("every parts variant on every template", function()
			local problems: { string } = {}
			local most = 0
			for _, field in PART_FIELDS do
				most = math.max(most, #kit.parts[field])
			end
			for _, pair in templateClasses() do
				for index = 1, most do
					local spec = baseSpec(pair.classId, pair.template)
					for _, field in PART_FIELDS do
						spec.parts[field] = nth(kit.parts[field], index)
					end
					spec.paint.stripe = nth(kit.stripes, index)
					append(problems, buildProblems(spec, `{pair.template} #{index}`))
				end
			end
			t.expect(problems).toEqual({})
		end)

		t.it("every template at the extremes of every number", function()
			local problems: { string } = {}
			local ranges = kit.ranges
			local corners = {
				{ body = ranges.body.min, ride = ranges.rideHeight.min, wheel = ranges.wheelSize.min, nose = 0 },
				{ body = ranges.body.max, ride = ranges.rideHeight.max, wheel = ranges.wheelSize.max, nose = 1 },
				{ body = ranges.body.min, ride = ranges.rideHeight.max, wheel = ranges.wheelSize.max, nose = 1 },
				{ body = ranges.body.max, ride = ranges.rideHeight.min, wheel = ranges.wheelSize.min, nose = 0 },
			}
			for _, pair in templateClasses() do
				for index, corner in corners do
					local spec = baseSpec(pair.classId, pair.template)
					for _, field in BODY_NUMBERS do
						spec.body[field] = corner.body
					end
					spec.body.noseSlope = corner.nose
					spec.stance.rideHeight = corner.ride
					spec.stance.wheelSize = corner.wheel
					spec.parts.spoiler = "wing"
					spec.paint.stripe = nth(kit.stripes, index + 1)
					append(problems, buildProblems(spec, `{pair.template} corner {index}`))
				end
			end
			t.expect(problems).toEqual({})
		end)

		t.it("a spec with nothing valid in it (normalized to the kit)", function()
			local problems: { string } = {}
			for _, raw in { {}, { body = "tall", parts = 7, paint = false, stance = {} } } :: { any } do
				append(problems, buildProblems(raw, "empty"))
			end
			append(problems, buildProblems(nil, "nil"))
			t.expect(problems).toEqual({})
		end)

		t.it("names the model and sets its attributes", function()
			local spec = baseSpec("sedan", "sedan")
			local model = build(spec)
			local plain = SpecBuilder.build(spec, kit)
			local seen = {
				name = model.Name,
				vehicleId = model:GetAttribute("VehicleId"),
				trim = model:GetAttribute("Trim"),
				uid = model:GetAttribute("DesignUid"),
				kitVersion = model:GetAttribute("KitVersion"),
				plainName = plain.Name,
				plainId = plain:GetAttribute("VehicleId"),
			}
			local specOf = SpecBuilder.specOf(model, kit)
			model:Destroy()
			plain:Destroy()
			t.expect(seen).toEqual({
				name = `{Garage.customVehicleId}_{UID}`,
				vehicleId = Designer.catalogPrefix .. UID,
				trim = Designer.designTrim,
				uid = UID,
				kitVersion = kit.kitVersion,
				plainName = Garage.customVehicleId,
				plainId = Garage.customVehicleId,
			})
			t.expect(specOf).toEqual(SpecBuilder.normalize(spec, kit))
		end)

		t.it("the same spec to the same instances every time", function()
			local spec = baseSpec("muscle", "fastback", "track")
			spec.parts.spoiler = "wing"
			spec.paint.stripe = "center"
			local first, second = build(spec), build(spec)
			local a, b = fingerprint(first), fingerprint(second)
			first:Destroy()
			second:Destroy()
			t.expect(a).toEqual(b)
		end)

		t.it("seats the class's seat count (the template's, kept inside the class band)", function()
			local problems: { string } = {}
			for _, classId in sortedKeys(kit.classes) do
				for _, template in kit.classes[classId].templates do
					local spec = baseSpec(classId, template)
					local model = build(spec)
					local seats = model:FindFirstChild("Seats")
					local count = if seats then #seats:GetChildren() else 0
					model:Destroy()
					local band = Classes[classId].seats
					local wanted = math.clamp(kit.templates[template].seats, band.min, band.max)
					if count ~= wanted or count ~= SpecBuilder.stats(spec, kit).seats then
						table.insert(problems, `{classId}/{template}: {count} seats, wanted {wanted}`)
					end
				end
			end
			t.expect(problems).toEqual({})
		end)
	end)

	t.describe("SpecBuilder stats", function()
		t.it("sit inside the class band and under its ceiling for every class, template and personality", function()
			local problems: { string } = {}
			for _, classId in sortedKeys(kit.classes) do
				for _, template in kit.classes[classId].templates do
					for _, personality in personalities() do
						local label = `{classId}/{template}/{personality}`
						append(
							problems,
							statProblems(
								classId,
								SpecBuilder.stats(baseSpec(classId, template, personality), kit),
								label
							)
						)
					end
				end
			end
			t.expect(problems).toEqual({})
		end)

		t.it("come only from class and personality", function()
			local plain = baseSpec("sports", "coupe", "torquey")
			local loud = baseSpec("sports", "hatch", "torquey")
			loud.name = "FASTEST CAR EVER 999 MPH"
			loud.tagline = "0-60 in 0.1 s, infinite range"
			loud.energy = "fuel"
			for _, field in BODY_NUMBERS do
				loud.body[field] = 1
			end
			loud.parts =
				{ frontBumper = "aero", rearBumper = "diffuser", spoiler = "wing", lights = "bar", wheels = "aero" }
			loud.paint = { primary = "#FF0000", secondary = "#000000", finish = "metallic", stripe = "center" }
			loud.stance = { rideHeight = -1, wheelSize = 1 }
			loud.topSpeedMph = 999
			loud.stats = { topSpeedMph = 999, zeroToSixtySec = 0.1, handling = 1, energyMinutes = 999 }
			local a, b = SpecBuilder.stats(plain, kit), SpecBuilder.stats(loud, kit)
			for _, field in { "topSpeedMph", "zeroToSixtySec", "handling", "energyMinutes", "drive" } do
				t.expect({ field = field, value = (b :: any)[field] })
					.toEqual({ field = field, value = (a :: any)[field] })
			end
		end)

		t.it("follow the personality: quicker with acceleration, longer with range", function()
			local problems: { string } = {}
			local list = personalities()
			for _, classId in sortedKeys(kit.classes) do
				local template = kit.classes[classId].templates[1]
				for _, a in list do
					for _, b in list do
						local pa, pb = kit.personalities[a], kit.personalities[b]
						local sa = SpecBuilder.stats(baseSpec(classId, template, a), kit)
						local sb = SpecBuilder.stats(baseSpec(classId, template, b), kit)
						if pa.acceleration > pb.acceleration and sa.zeroToSixtySec > sb.zeroToSixtySec then
							table.insert(problems, `{classId}: {a} is slower to 60 than {b}`)
						end
						if pa.topSpeed > pb.topSpeed and sa.topSpeedMph < sb.topSpeedMph then
							table.insert(problems, `{classId}: {a} has a lower top speed than {b}`)
						end
						if pa.range > pb.range and sa.energyMinutes < sb.energyMinutes then
							table.insert(problems, `{classId}: {a} has less range than {b}`)
						end
					end
				end
			end
			t.expect(problems).toEqual({})
		end)
	end)

	t.describe("SpecBuilder normalizes", function()
		t.it("clamps out-of-range, forged and missing numbers to the kit ranges", function()
			local ranges = kit.ranges
			local middle = (ranges.body.min + ranges.body.max) / 2
			local raw = baseSpec("sedan", "sedan")
			raw.body.length = 7
			raw.body.height = -3
			raw.body.roofline = 0 / 0
			raw.body.noseSlope = math.huge
			raw.body.flare = "wide"
			raw.stance.rideHeight = 99
			raw.stance.wheelSize = -5
			local s = SpecBuilder.normalize(raw, kit)
			t.expect({
				length = s.body.length,
				height = s.body.height,
				roofline = s.body.roofline,
				noseSlope = s.body.noseSlope,
				flare = s.body.flare,
				rideHeight = s.stance.rideHeight,
				wheelSize = s.stance.wheelSize,
			}).toEqual({
				length = ranges.body.max,
				height = ranges.body.min,
				roofline = middle,
				noseSlope = middle,
				flare = middle,
				rideHeight = ranges.rideHeight.max,
				wheelSize = ranges.wheelSize.min,
			})
		end)

		t.it("builds a forged spec exactly like its clamped one", function()
			local raw = baseSpec("offroad", "offroad")
			raw.body.length = 50
			raw.body.flare = -50
			raw.stance.rideHeight = -40
			raw.stance.wheelSize = 40
			local clamped = baseSpec("offroad", "offroad")
			clamped.body.length = kit.ranges.body.max
			clamped.body.flare = kit.ranges.body.min
			clamped.stance.rideHeight = kit.ranges.rideHeight.min
			clamped.stance.wheelSize = kit.ranges.wheelSize.max
			t.expect(SpecBuilder.geometry(raw, kit)).toEqual(SpecBuilder.geometry(clamped, kit))
			t.expect(SpecBuilder.stats(raw, kit)).toEqual(SpecBuilder.stats(clamped, kit))
			local a, b = build(raw), build(clamped)
			local fa, fb = fingerprint(a), fingerprint(b)
			a:Destroy()
			b:Destroy()
			t.expect(fa).toEqual(fb)
		end)

		t.it("falls back to kit ids for unknown ones and cuts text to the kit limits", function()
			local raw = baseSpec("sedan", "sedan")
			raw.class = "hypercar" -- never designable
			raw.energy = "nuclear"
			raw.personality = "ludicrous"
			raw.body.template = "rocket"
			raw.parts = {
				frontBumper = "ram",
				rearBumper = 4,
				spoiler = "jet_wing",
				lights = "lasers",
				wheels = "chrome_rocket",
			}
			raw.paint = { primary = "red", secondary = "#12345", finish = "sparkly", stripe = "zebra" }
			raw.name = string.rep("N", kit.limits.name + 20)
			raw.tagline = string.rep("T", kit.limits.tagline + 20)
			local s = SpecBuilder.normalize(raw, kit)
			local class = kit.classes[s.class]
			t.expect(class ~= nil).toBe(true)
			t.expect(s.class == "hypercar").toBe(false)
			t.expect(table.find(class.energy, s.energy) ~= nil).toBe(true)
			t.expect(kit.personalities[s.personality] ~= nil).toBe(true)
			t.expect(table.find(class.templates, s.body.template) ~= nil).toBe(true)
			for _, field in PART_FIELDS do
				t.expect({ field = field, value = (s.parts :: any)[field] })
					.toEqual({ field = field, value = kit.parts[field][1] })
			end
			t.expect(s.paint.primary).toBe(string.upper(Designer.plainLook.primary))
			t.expect(s.paint.secondary).toBe(string.upper(Designer.plainLook.secondary))
			t.expect(s.paint.finish).toBe(kit.finishes[1])
			t.expect(s.paint.stripe).toBe(kit.stripes[1])
			t.expect((utf8.len(s.name or ""))).toBe(kit.limits.name)
			t.expect((utf8.len(s.tagline or ""))).toBe(kit.limits.tagline)
		end)

		t.it("keeps a template the class doesn't list out of the class", function()
			local raw = baseSpec("sports", "van") -- van isn't a sports template
			local s = SpecBuilder.normalize(raw, kit)
			t.expect(table.find(kit.classes.sports.templates, s.body.template) ~= nil).toBe(true)
		end)
	end)

	t.describe("SpecBuilder geometry", function()
		t.it("scales the template geometry by kit.proportions", function()
			local problems: { string } = {}
			local p = kit.proportions
			local function near(label: string, value: number, wanted: number)
				if math.abs(value - wanted) > GEOMETRY_TOLERANCE then
					table.insert(problems, `{label}: {value}, wanted {wanted}`)
				end
			end
			for _, pair in templateClasses() do
				local base = kit.templates[pair.template].geometry
				local low, high = baseSpec(pair.classId, pair.template), baseSpec(pair.classId, pair.template)
				for _, field in BODY_NUMBERS do
					low.body[field] = kit.ranges.body.min
					high.body[field] = kit.ranges.body.max
				end
				low.stance = { rideHeight = kit.ranges.rideHeight.min, wheelSize = kit.ranges.wheelSize.min }
				high.stance = { rideHeight = kit.ranges.rideHeight.max, wheelSize = kit.ranges.wheelSize.max }
				for _, case in { { spec = low, side = "min" }, { spec = high, side = "max" } } do
					local g = SpecBuilder.geometry(case.spec, kit)
					local side = case.side
					local label = `{pair.template} {side}`
					near(`{label} length`, g.length, base.length * p.length[side])
					near(`{label} wheelbase`, g.wheelbase, base.wheelbase * p.length[side])
					near(`{label} width`, g.width, base.width * p.flare[side])
					near(`{label} track`, g.track, base.track * p.flare[side])
					near(`{label} chassisHeight`, g.chassisHeight, base.chassisHeight * p.height[side])
					near(`{label} wheelRadius`, g.wheelRadius, base.wheelRadius * p.wheelSize[side])
					near(`{label} wheelWidth`, g.wheelWidth, base.wheelWidth)
					near(`{label} rideHeight`, g.rideHeight, base.rideHeight + p.rideHeight[side])
					-- The body always clears its wheels and holds its chassis (Catalog.validate's rules too).
					if g.height < BodyKit.archTop(g) + BodyKit.MIN_ROOM_OVER_ARCHES - EPSILON then
						table.insert(problems, `{label}: height {g.height} too low over the arches`)
					end
					if g.wheelbase >= g.length or g.track >= g.width or g.rideHeight + g.chassisHeight > g.height then
						table.insert(problems, `{label}: wheels or chassis outside the body`)
					end
				end
			end
			t.expect(problems).toEqual({})
		end)

		t.it("keeps the template's ride height at stance.rideHeight 0", function()
			local problems: { string } = {}
			for _, pair in templateClasses() do
				local base = kit.templates[pair.template].geometry
				local spec = baseSpec(pair.classId, pair.template)
				spec.stance.rideHeight = 0
				local g = SpecBuilder.geometry(spec, kit)
				if math.abs(g.rideHeight - base.rideHeight) > GEOMETRY_TOLERANCE then
					table.insert(problems, `{pair.template}: ride height {g.rideHeight}, template {base.rideHeight}`)
				end
			end
			t.expect(problems).toEqual({})
		end)

		t.it("builds the chassis and wheels at that geometry", function()
			local spec = baseSpec("pickup", "pickup")
			spec.body.length = 1
			spec.stance.wheelSize = 1
			local g = SpecBuilder.geometry(spec, kit)
			local model = build(spec) :: any
			local chassis = model.Chassis.Size
			local wheel = model.Wheels.FL.Size
			model:Destroy()
			t.expect(chassis.Z).toBeNear(g.length, 1e-3)
			t.expect(chassis.X).toBeNear(g.width, 1e-3)
			t.expect(wheel.Y).toBeNear(2 * g.wheelRadius, 1e-3)
		end)
	end)

	t.describe("SpecBuilder catalog entry", function()
		t.it("is custom:<uid> with one design trim carrying stats()", function()
			local spec = baseSpec("suv", "offroad", "track")
			local entry = SpecBuilder.vehicleFor(spec, kit, UID)
			local stats = SpecBuilder.stats(spec, kit)
			local trim = entry.trims[1]
			t.expect({
				id = entry.id,
				class = entry.class,
				bodyStyle = entry.bodyStyle,
				energy = entry.energy,
				playerDrivable = entry.playerDrivable,
				features = #entry.features,
				trims = #entry.trims,
				trimId = trim.id,
				displayName = entry.displayName,
			}).toEqual({
				id = Designer.catalogPrefix .. UID,
				class = "suv",
				bodyStyle = kit.templates.offroad.style,
				energy = spec.energy,
				playerDrivable = true,
				features = 0,
				trims = 1,
				trimId = Designer.designTrim,
				displayName = spec.name,
			})
			t.expect({
				topSpeedMph = trim.topSpeedMph,
				zeroToSixtySec = trim.zeroToSixtySec,
				handling = trim.handling,
				energyMinutes = trim.energyMinutes,
				seats = trim.seats,
				drive = trim.drive,
			}).toEqual(stats)
			t.expect(entry.geometry).toEqual(SpecBuilder.geometry(spec, kit))
			t.expect(SpecBuilder.vehicleFor(spec, kit, UID)).toEqual(entry) -- deterministic
		end)

		t.it("names a design whose name was filtered away after its class", function()
			local spec = baseSpec("muscle", "coupe")
			spec.name = nil
			local entry = SpecBuilder.vehicleFor(spec, kit, UID)
			t.expect(entry.displayName).toBe(string.format(Designer.messages.fallbackName, Classes.muscle.displayName))
		end)

		t.it("resolves through Catalog once published, and not after", function()
			if not RunService:IsServer() then
				print("  SpecBuilder.spec: Catalog.publishDesign runs on the server only; skipped here")
				return
			end
			local spec = baseSpec("sedan", "wagon")
			local id = Catalog.designId(UID)
			local entry = SpecBuilder.vehicleFor(spec, kit, UID)
			local err: any = nil
			local published = xpcall(Catalog.publishDesign, function(message: any)
				err = message
			end, UID, entry)
			local vehicle = Catalog.getVehicle(id)
			local trim = Catalog.getTrim(id, Designer.designTrim)
			local geometry = Catalog.geometry(id, Designer.designTrim)
			local seen = {
				published = published,
				isDesign = Catalog.isDesign(id),
				uid = Catalog.designUidOf(id),
				modelName = Catalog.modelName(id, Designer.designTrim),
				listed = table.find(Catalog.vehicleIds(), id) ~= nil,
				class = if vehicle then vehicle.class else nil,
				trim = if trim then trim.id else nil,
				topSpeedMph = if trim then trim.topSpeedMph else nil,
				length = if geometry then geometry.length else nil,
			}
			pcall(Catalog.unpublishDesign, UID)
			local after = Catalog.getVehicle(id)
			if not published then
				print(`  SpecBuilder.spec: publishDesign failed: {err}`)
			end
			t.expect(seen).toEqual({
				published = true,
				isDesign = true,
				uid = UID,
				modelName = `{Garage.customVehicleId}_{UID}`,
				listed = false,
				class = "sedan",
				trim = Designer.designTrim,
				topSpeedMph = entry.trims[1].topSpeedMph,
				length = entry.geometry.length,
			})
			t.expect(after).toBe(nil)
			t.expect(Catalog.isDesign("ohm_spark")).toBe(false)
			t.expect(Catalog.designUidOf("ohm_spark")).toBe(nil)
		end)
	end)

	t.describe("SpecBuilder looks", function()
		t.it("paints the body primary and the roof secondary, in the finish", function()
			local problems: { string } = {}
			for _, finishId in kit.finishes do
				local spec = baseSpec("sedan", "sedan")
				spec.paint.finish = finishId
				local finish = Customization.getFinish(finishId)
				local model = build(spec)
				for _, part in model:GetDescendants() do
					if not part:IsA("BasePart") or not CollectionService:HasTag(part, "Paint") then
						continue
					end
					local wanted = if BodyKit.ROOF_PANELS[part.Name] then spec.paint.secondary else spec.paint.primary
					if hexOf(part.Color) ~= wanted then
						table.insert(problems, `{finishId} {part.Name}: {hexOf(part.Color)}, wanted {wanted}`)
					end
					if finish ~= nil and part.Material ~= finish.material then
						table.insert(problems, `{finishId} {part.Name}: {part.Material.Name}`)
					end
				end
				model:Destroy()
			end
			t.expect(problems).toEqual({})
		end)

		t.it("lays the stripe kind in the secondary color, never tagged Paint", function()
			local counts: { [string]: number } = {}
			local problems: { string } = {}
			for _, stripe in kit.stripes do
				local spec = baseSpec("sedan", "sedan")
				spec.paint.stripe = stripe
				local model = build(spec)
				local stripes = BodyKit.stripes(model)
				counts[stripe] = #stripes
				for _, part in stripes do
					if hexOf(part.Color) ~= spec.paint.secondary or CollectionService:HasTag(part, "Paint") then
						table.insert(problems, `{stripe}: {part.Name} {hexOf(part.Color)}`)
					end
					if not CollectionService:HasTag(part, STRIPE_TAG) then
						table.insert(problems, `{stripe}: {part.Name} lacks {STRIPE_TAG}`)
					end
				end
				model:Destroy()
			end
			t.expect(problems).toEqual({})
			t.expect(counts.none).toBe(0)
			t.expect(counts.center).toBeGreaterThan(0)
			t.expect(counts.side).toBeGreaterThan(0)
		end)

		t.it("builds each spoiler variant on Mount_Spoiler", function()
			local wanted: { [string]: { string } } = {
				none = {},
				lip = { "SpoilerLip" },
				ducktail = { "Ducktail" },
				wing = { "WingPostL", "WingPostR", "WingBlade" },
			}
			local all = { "SpoilerLip", "Ducktail", "WingPostL", "WingPostR", "WingBlade" }
			local problems: { string } = {}
			for _, variant in kit.parts.spoiler do
				local spec = baseSpec("sedan", "sedan")
				spec.parts.spoiler = variant
				local model = build(spec)
				local names = bodyNames(model)
				model:Destroy()
				local expected = wanted[variant]
				if expected == nil then
					table.insert(problems, `{variant}: the spec doesn't know this variant`)
					continue
				end
				for _, name in all do
					local present = names[name] == true
					if present ~= (table.find(expected, name) ~= nil) then
						table.insert(problems, `{variant}: {name} {if present then "present" else "missing"}`)
					end
				end
			end
			t.expect(problems).toEqual({})
		end)

		t.it("builds the bumper variants", function()
			local cases = {
				{ field = "frontBumper", variant = "aero", present = { "Splitter" }, absent = { "FrontBumper" } },
				{ field = "frontBumper", variant = "rugged", present = { "FrontBumper", "Skid" }, absent = {} },
				{ field = "frontBumper", variant = "clean", present = { "FrontBumper" }, absent = { "Skid" } },
				{ field = "rearBumper", variant = "sport", present = { "RearBumper", "Valance" }, absent = {} },
				{ field = "rearBumper", variant = "rugged", present = { "RearBumper", "Step" }, absent = {} },
				{ field = "rearBumper", variant = "diffuser", present = { "RearBumper", "Diffuser" }, absent = {} },
			}
			local problems: { string } = {}
			for _, case in cases do
				local spec = baseSpec("sedan", "sedan")
				spec.parts[case.field] = case.variant
				local model = build(spec)
				local names = bodyNames(model)
				model:Destroy()
				for _, name in case.present do
					if not names[name] then
						table.insert(problems, `{case.field} {case.variant}: no {name}`)
					end
				end
				for _, name in case.absent do
					if names[name] then
						table.insert(problems, `{case.field} {case.variant}: has {name}`)
					end
				end
			end
			t.expect(problems).toEqual({})
		end)

		t.it("leaves out the body style's own spoiler and wing (the design picks its own)", function()
			local fastback = build(baseSpec("muscle", "fastback"))
			local wedge = build(baseSpec("exotic", "wedge"))
			local a, b = bodyNames(fastback), bodyNames(wedge)
			fastback:Destroy()
			wedge:Destroy()
			t.expect(a.Spoiler == true or b.Wing == true or b.PylonL == true).toBe(false)
		end)

		t.it("dresses the wheels in the design's wheel style colors", function()
			local problems: { string } = {}
			for _, wheelId in kit.parts.wheels do
				local style = Customization.getWheel(wheelId)
				if style == nil then
					table.insert(problems, `{wheelId}: not a Config/Customization wheel style`)
					continue
				end
				local spec = baseSpec("sedan", "sedan")
				spec.parts.wheels = wheelId
				local model = build(spec) :: any
				local rim = model.Wheels.FL:FindFirstChild("Rim")
				local color = if rim then rim.Color else nil
				model:Destroy()
				if color == nil or color:ToHex() ~= style.rimColor:ToHex() then
					table.insert(problems, `{wheelId}: rim color`)
				end
			end
			t.expect(problems).toEqual({})
		end)
	end)
end
