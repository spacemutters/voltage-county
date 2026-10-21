--!strict
-- The game re-checks every spec the designer backend sends (CLAUDE.md hard rule 11: AI output is untrusted; PLAN.md
-- Phase 11 acceptance: "Forged or tampered specs sent to the game server are rejected, and built stats always land
-- inside the class band, mods included"). Checks Services/DesignerService/Validate against Config/DesignKit.json:
--   Validate.design(raw, kit) and Validate.mod(raw, kit, "kit" | "catalog") -> (spec?, reasons)
--   * valid specs pass with their values kept (every designable class, template, energy and personality)
--   * unknown enums, wrong types, missing fields and bad colors are rejected (nil and at least one reason)
--   * out-of-range numbers are clamped to the kit ranges, exactly
--   * over-long text is cut to the kit limits (a prefix, whole UTF-8 characters)
--   * unknown fields are dropped, stat fields included, so text can never carry a stat
--   * a catalog mod never changes what the kit keeps for kit cars (body, body parts): rejected, or kept
--   * more than limits.maxExtras extras, or a spec over limits.specBytes: rejected, or cut to fit
--   * stats (Vehicle/SpecBuilder.stats) sit inside the class band for every class, template, personality and
--     energy, below the band's best, and come only from class and personality
--   * mods never touch the chassis, the wheel hubs or the car's identity (Vehicle/ModBuilder.apply), so a modded
--     car keeps its design's stats
--
-- Where the contract leaves the outcome open (NaN numbers, too many extras, a catalog mod touching the body, a spec
-- over specBytes) the spec accepts either safe outcome and checks the one that matters: nothing unsafe gets through.
--
-- Read by the harness in Edit mode (ServerStorage.Tests). Pure apart from the two model checks at the end, which
-- build in memory only (SpecBuilder.build, VehicleBuilder.assemble) and destroy what they build.

local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Catalog = require(ReplicatedStorage.Shared.Vehicle.Catalog)
local Classes = require(ReplicatedStorage.Shared.Config.Classes)
local Customization = require(ReplicatedStorage.Shared.Config.Customization)
local Harness = require(ReplicatedStorage.Shared.Testing.Harness)
local ModBuilder: any = require(ReplicatedStorage.Shared.Vehicle.ModBuilder)
local SpecBuilder: any = require(ReplicatedStorage.Shared.Vehicle.SpecBuilder)
local Validate: any = require(ServerScriptService.Server.Services.DesignerService.Validate)
local VehicleBuilder = require(ServerScriptService.Server.Dev.VehicleBuilder)

local kit: any = require(ReplicatedStorage.Shared.Config.DesignKit)

local KEEP: string = kit.mod.keep
local LIMITS = kit.limits

-- The top-level fields of each spec (PLAN.md Phase 11 "Design spec" and "Mod spec") and of their blocks.
local DESIGN_FIELDS =
	{ "refusal", "name", "tagline", "class", "energy", "personality", "meshPrompt", "body", "parts", "paint", "stance" }
local MOD_FIELDS = { "refusal", "summary", "body", "parts", "paint", "stance", "extras", "accessoryPrompt" }
local BLOCK_FIELDS: { [string]: { string } } = {
	body = { "template", "length", "height", "roofline", "noseSlope", "flare" },
	parts = { "frontBumper", "rearBumper", "spoiler", "lights", "wheels" },
	paint = { "primary", "secondary", "finish", "stripe" },
	stance = { "rideHeight", "wheelSize" },
}
local BODY_NUMBERS = { "length", "height", "roofline", "noseSlope", "flare" }
local STANCE_NUMBERS = { "rideHeight", "wheelSize" } -- each clamped to the kit range of the same name
-- Band fields of a stats table (the fields a Config/Vehicles trim has) and where Config/Classes keeps each band.
local BAND_FIELDS = { "topSpeedMph", "zeroToSixtySec", "handling", "energyMinutes", "seats" }
local LOWER_IS_BETTER: { [string]: boolean } = { zeroToSixtySec = true }
local HEX_COLOR = "^#%x%x%x%x%x%x$"
local WHEEL_HUBS = { "WheelFL", "WheelFR", "WheelRL", "WheelRR" }
local WHEELS = { "FL", "FR", "RL", "RR" }
local TOLERANCE = 1e-4 -- studs; Vector3 and CFrame are 32-bit
local EPSILON = 1e-9
local REMOVE = table.freeze({}) -- a tamper value meaning "leave this field out"

-- Helpers ---------------------------------------------------------------------------------------------------

local function deepCopy(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local copy = {}
	for key, item in value do
		copy[key] = deepCopy(item)
	end
	return copy
end

local function getPath(root: any, path: { string }): any
	local node = root
	for _, key in path do
		if type(node) ~= "table" then
			return nil
		end
		node = node[key]
	end
	return node
end

-- A copy of `spec` with the field at `path` set to `value` (REMOVE leaves it out).
local function tamper(spec: { [string]: any }, path: { string }, value: any): { [string]: any }
	local copy = deepCopy(spec)
	local node = copy
	for i = 1, #path - 1 do
		node = node[path[i]]
	end
	node[path[#path]] = if value == REMOVE then nil else deepCopy(value)
	return copy
end

local function sortedKeys(map: { [any]: any }): { string }
	local keys: { string } = {}
	for key in map do
		table.insert(keys, tostring(key))
	end
	table.sort(keys)
	return keys
end

local function show(value: any): string
	if type(value) == "string" then
		return string.format("%q", if #value > 40 then string.sub(value, 1, 40) .. "..." else value)
	elseif type(value) == "table" then
		return if next(value) == nil then "an empty table" else "a table"
	end
	return tostring(value)
end

-- The keys of `map` that aren't in `allowed`.
local function unexpectedKeys(map: any, allowed: { string }): { string }
	local extra: { string } = {}
	if type(map) ~= "table" then
		return extra
	end
	for key in map do
		if type(key) ~= "string" or table.find(allowed, key) == nil then
			table.insert(extra, tostring(key))
		end
	end
	table.sort(extra)
	return extra
end

-- Every designable class id, sorted.
local function classIds(): { string }
	return sortedKeys(kit.classes)
end

local function personalities(): { string }
	return sortedKeys(kit.personalities)
end

-- A valid design spec (PLAN.md shape) for a class, template, personality and energy (defaults: the class's first).
local function validDesign(
	classId: string?,
	template: string?,
	personality: string?,
	energy: string?
): { [string]: any }
	local id = classId or "sedan"
	local class = kit.classes[id]
	return {
		name = "Test Runner",
		tagline = "A tidy little test car",
		class = id,
		energy = energy or class.energy[1],
		personality = personality or "balanced",
		meshPrompt = "a rounded compact car with short overhangs and a tall glasshouse",
		body = {
			template = template or class.templates[1],
			length = 0.5,
			height = 0.5,
			roofline = 0.5,
			noseSlope = 0.5,
			flare = 0.5,
		},
		parts = {
			frontBumper = kit.parts.frontBumper[1],
			rearBumper = kit.parts.rearBumper[1],
			spoiler = kit.parts.spoiler[1],
			lights = kit.parts.lights[1],
			wheels = kit.parts.wheels[1],
		},
		paint = { primary = "#3366CC", secondary = "#F2F2F2", finish = kit.finishes[1], stripe = kit.stripes[1] },
		stance = { rideHeight = 0, wheelSize = 0.5 },
	}
end

-- Mod number fields. PLAN.md: every mod field also accepts "keep", and "number fields use a change flag instead".
-- This spec reads that as { change = boolean, value = number } for each number field. If Validate settles on another
-- shape, only changeTo, unchanged and readNumber need to follow it.
local function changeTo(value: any): { [string]: any }
	return { change = true, value = value }
end

local function unchanged(): { [string]: any }
	return { change = false, value = 0.5 }
end

-- Whether a mod number field changes anything, and to what. "keep", nil and change = false change nothing.
local function readNumber(field: any): (boolean, number?)
	if type(field) == "number" then
		return true, field
	elseif type(field) == "table" and field.change == true then
		return true, if type(field.value) == "number" then field.value else nil
	end
	return false, nil
end

-- A valid catalog mod: paint, wheels, stance and extras only; everything else kept.
local function validMod(): { [string]: any }
	return {
		summary = "Lifted, desert tan, trail tires",
		body = {
			template = KEEP,
			length = unchanged(),
			height = unchanged(),
			roofline = unchanged(),
			noseSlope = unchanged(),
			flare = unchanged(),
		},
		parts = { frontBumper = KEEP, rearBumper = KEEP, spoiler = KEEP, lights = KEEP, wheels = "trail" },
		paint = { primary = "#C2A27A", secondary = KEEP, finish = "matte", stripe = KEEP },
		stance = { rideHeight = changeTo(0.75), wheelSize = changeTo(0.8) },
		extras = { "roof_rack", "bull_bar" }, -- on different mounts (Validate keeps one extra per mount point)
		accessoryPrompt = "none",
	}
end

-- A valid kit mod that re-proportions the body and swaps body parts too.
local function validKitMod(): { [string]: any }
	local mod = validMod()
	mod.body.length = changeTo(0.8)
	mod.body.flare = changeTo(0.9)
	mod.parts.frontBumper = "sport"
	mod.parts.spoiler = "wing"
	return mod
end

local function design(raw: any): (any, { string })
	local spec, reasons = Validate.design(raw, kit)
	return spec, if type(reasons) == "table" then reasons else {}
end

local function mod(raw: any, kind: string): (any, { string })
	local spec, reasons = Validate.mod(raw, kit, kind)
	return spec, if type(reasons) == "table" then reasons else {}
end

-- Expects Validate to have refused: no spec and at least one reason.
local function expectRejected(t: Harness.Api, spec: any, reasons: { string })
	if spec ~= nil then
		print("  accepted a spec it should have rejected")
	end
	t.expect(spec).toBe(nil)
	t.expect(#reasons > 0).toBe(true)
end

-- Expects Validate to have accepted; prints its reasons when it didn't.
local function expectAccepted(t: Harness.Api, spec: any, reasons: { string })
	if spec == nil then
		print(`  rejected: {table.concat(reasons, "; ")}`)
	end
	t.expect(spec ~= nil).toBe(true)
end

local function charCount(text: any): number?
	return if type(text) == "string" then utf8.len(text) else nil
end

-- Whether `cut` is a whole-character prefix of `original` no longer than `limit` characters.
local function isCut(cut: any, original: string, limit: number): boolean
	local count = charCount(cut)
	return count ~= nil and count > 0 and count <= limit and string.sub(original, 1, #cut) == cut
end

-- The fields of a mod that change something a catalog car must keep: anything outside kit.mod.catalogAllowed.
local function catalogAllowed(block: string, field: string): boolean
	local allowed = kit.mod.catalogAllowed
	return table.find(allowed, block) ~= nil or table.find(allowed, `{block}.{field}`) ~= nil
end

local function disallowedOnCatalog(spec: any): { string }
	local touched: { string } = {}
	for _, block in { "body", "parts", "paint", "stance" } do
		local fields = if type(spec) == "table" then spec[block] else nil
		if type(fields) == "table" and not catalogAllowed(block, "") then
			for _, field in BLOCK_FIELDS[block] do
				local value = fields[field]
				local changes = if type(value) == "string" then value ~= KEEP else (readNumber(value))
				if changes and not catalogAllowed(block, field) then
					table.insert(touched, `{block}.{field}`)
				end
			end
		end
	end
	return touched
end

local function band(classId: string, field: string): Classes.Range
	return (Classes[classId] :: any)[field]
end

-- Stats outside their class band, as readable lines (empty when every stat is inside).
local function outOfBand(classId: string, stats: any, label: string): { string }
	local problems: { string } = {}
	if type(stats) ~= "table" then
		return { `{label}: no stats` }
	end
	for _, field in BAND_FIELDS do
		local value = stats[field]
		local range = band(classId, field)
		if type(value) ~= "number" or value ~= value or value < range.min - EPSILON or value > range.max + EPSILON then
			table.insert(problems, `{label}: {field} {tostring(value)} outside {range.min}..{range.max}`)
		end
	end
	return problems
end

-- What decides how a car drives: the chassis box and its physical properties, the wheel hubs and motors, its mass
-- and the identity its stats are looked up by (VehicleId, Trim).
type Physics = {
	size: Vector3,
	density: number,
	friction: number,
	elasticity: number,
	mass: number,
	hubs: { [string]: Vector3 },
	motors: { [string]: CFrame },
	vehicleId: any,
	trim: any,
}

local function physicsOf(model: Model): Physics
	local chassis = model.PrimaryPart
	assert(chassis ~= nil, "the model has no PrimaryPart (Chassis)")
	local properties = chassis.CurrentPhysicalProperties
	local mass = 0
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") and not descendant.Massless then
			mass += descendant:GetMass()
		end
	end
	local hubs: { [string]: Vector3 } = {}
	for _, name in WHEEL_HUBS do
		local hub = chassis:FindFirstChild(name)
		if hub ~= nil and hub:IsA("Attachment") then
			hubs[name] = hub.Position
		end
	end
	local motors: { [string]: CFrame } = {}
	local wheels = model:FindFirstChild("Wheels")
	for _, name in WHEELS do
		local wheel = if wheels then wheels:FindFirstChild(name) else nil
		local motor = if wheel then wheel:FindFirstChild("Motor") else nil
		if motor ~= nil and motor:IsA("Motor6D") then
			motors[name] = motor.C0
		end
	end
	return {
		size = chassis.Size,
		density = properties.Density,
		friction = properties.Friction,
		elasticity = properties.Elasticity,
		mass = mass,
		hubs = hubs,
		motors = motors,
		vehicleId = model:GetAttribute("VehicleId"),
		trim = model:GetAttribute("Trim"),
	}
end

local function sameCFrame(a: CFrame, b: CFrame): boolean
	return a.Position:FuzzyEq(b.Position, TOLERANCE)
		and a.LookVector:FuzzyEq(b.LookVector, TOLERANCE)
		and a.UpVector:FuzzyEq(b.UpVector, TOLERANCE)
end

-- How `after` differs from `before`, as readable lines (empty when the physics are the same).
local function physicsChanges(before: Physics, after: Physics): { string }
	local changes: { string } = {}
	if not before.size:FuzzyEq(after.size, TOLERANCE) then
		table.insert(changes, `chassis size {before.size} -> {after.size}`)
	end
	for _, field in { "density", "friction", "elasticity", "mass" } do
		local a, b = (before :: any)[field], (after :: any)[field]
		if math.abs(a - b) > TOLERANCE * math.max(1, math.abs(a)) then
			table.insert(changes, `{field} {a} -> {b}`)
		end
	end
	for _, name in WHEEL_HUBS do
		local a, b = before.hubs[name], after.hubs[name]
		if a == nil or b == nil or not a:FuzzyEq(b, TOLERANCE) then
			table.insert(changes, `hub {name} {tostring(a)} -> {tostring(b)}`)
		end
	end
	for _, name in WHEELS do
		local a, b = before.motors[name], after.motors[name]
		if a == nil or b == nil or not sameCFrame(a, b) then
			table.insert(changes, `wheel {name} motor C0 changed`)
		end
	end
	if before.vehicleId ~= after.vehicleId or before.trim ~= after.trim then
		table.insert(
			changes,
			`identity {tostring(before.vehicleId)}/{tostring(before.trim)} -> `
				.. `{tostring(after.vehicleId)}/{tostring(after.trim)}`
		)
	end
	return changes
end

-- Parts other than the Chassis that would take part in physics (the contract: massless and non-colliding).
local function physicalExtras(model: Model): { string }
	local chassis = model.PrimaryPart
	local problems: { string } = {}
	for _, descendant in model:GetDescendants() do
		if
			descendant:IsA("BasePart")
			and descendant ~= chassis
			and (not descendant.Massless or descendant.CanCollide)
		then
			table.insert(problems, descendant:GetFullName())
		end
	end
	table.sort(problems)
	return problems
end

-- A drivable catalog vehicle and trim to mod (the first by id).
local function catalogCar(): (string, string)
	for _, vehicleId in Catalog.vehicleIds() do
		local vehicle = Catalog.getVehicle(vehicleId)
		if vehicle ~= nil and vehicle.playerDrivable and #vehicle.trims > 0 then
			return vehicleId, vehicle.trims[1].id
		end
	end
	error("the catalog has no drivable vehicle")
end

return function(t: Harness.Api)
	t.describe("Validate.design", function()
		t.describe("valid specs", function()
			t.it("pass for every designable class, template, energy and personality", function()
				local refused: { string } = {}
				for _, classId in classIds() do
					local class = kit.classes[classId]
					for _, template in class.templates do
						for _, energy in class.energy do
							for _, personality in personalities() do
								local spec, reasons = design(validDesign(classId, template, personality, energy))
								if spec == nil then
									table.insert(
										refused,
										`{classId}/{template}/{energy}/{personality}: {table.concat(reasons, "; ")}`
									)
								end
							end
						end
					end
				end
				t.expect(refused).toEqual({})
			end)

			t.it("come back with every value kept", function()
				local raw = validDesign("sports", "coupe", "track", "fuel")
				raw.body.length = 0.37
				raw.stance.rideHeight = -0.42
				local spec, reasons = design(raw)
				expectAccepted(t, spec, reasons)
				for _, field in { "name", "tagline", "class", "energy", "personality", "meshPrompt" } do
					t.expect(spec[field]).toBe(raw[field])
				end
				for block, fields in BLOCK_FIELDS do
					for _, field in fields do
						local want, got = raw[block][field], spec[block][field]
						if type(want) == "number" then
							t.expect(got).toBeNear(want, EPSILON)
						elseif block == "paint" and (field == "primary" or field == "secondary") then
							t.expect(string.upper(got)).toBe(string.upper(want))
						else
							t.expect(got).toBe(want)
						end
					end
				end
			end)

			t.it("accept lowercase hex colors", function()
				local spec, reasons = design(tamper(validDesign(), { "paint", "primary" }, "#a1b2c3"))
				expectAccepted(t, spec, reasons)
				t.expect(string.match(spec.paint.primary, HEX_COLOR) ~= nil).toBe(true)
			end)
		end)

		t.describe("unknown enums are rejected", function()
			local cases: { { path: { string }, value: any } } = {
				{ path = { "class" }, value = "hypercar" }, -- never designable
				{ path = { "class" }, value = "service" }, -- a real class, not designable
				{ path = { "class" }, value = "spaceship" },
				{ path = { "energy" }, value = "steam" },
				{ path = { "personality" }, value = "rocket" },
				{ path = { "body", "template" }, value = "tank" },
				{ path = { "body", "template" }, value = "wedge" }, -- a kit template, but not one a sedan may use
				{ path = { "parts", "frontBumper" }, value = "spikes" },
				{ path = { "parts", "rearBumper" }, value = "exhaust" },
				{ path = { "parts", "spoiler" }, value = "jet" },
				{ path = { "parts", "lights" }, value = "laser" },
				{ path = { "parts", "wheels" }, value = "spinners" },
				{ path = { "parts", "wheels" }, value = KEEP }, -- "keep" belongs to mods only
				{ path = { "paint", "finish" }, value = "chrome" },
				{ path = { "paint", "stripe" }, value = "flames" },
			}
			for _, case in cases do
				t.it(`{table.concat(case.path, ".")} = {show(case.value)}`, function()
					local spec, reasons = design(tamper(validDesign("sedan", "sedan"), case.path, case.value))
					expectRejected(t, spec, reasons)
				end)
			end
		end)

		t.describe("out-of-range numbers are clamped", function()
			local cases: { { path: { string }, value: number, expected: number } } = {
				{ path = { "body", "length" }, value = 7, expected = kit.ranges.body.max },
				{ path = { "body", "height" }, value = -4, expected = kit.ranges.body.min },
				{ path = { "body", "roofline" }, value = 1.5, expected = kit.ranges.body.max },
				{ path = { "body", "noseSlope" }, value = -0.01, expected = kit.ranges.body.min },
				{ path = { "body", "flare" }, value = 1e9, expected = kit.ranges.body.max },
				{ path = { "stance", "rideHeight" }, value = 3, expected = kit.ranges.rideHeight.max },
				{ path = { "stance", "rideHeight" }, value = -3, expected = kit.ranges.rideHeight.min },
				{ path = { "stance", "wheelSize" }, value = -2, expected = kit.ranges.wheelSize.min },
				{ path = { "stance", "wheelSize" }, value = 9, expected = kit.ranges.wheelSize.max },
			}
			for _, case in cases do
				t.it(`{table.concat(case.path, ".")} = {case.value} -> {case.expected}`, function()
					local spec, reasons = design(tamper(validDesign(), case.path, case.value))
					expectAccepted(t, spec, reasons)
					t.expect(getPath(spec, case.path)).toBeNear(case.expected, EPSILON)
				end)
			end

			-- JSON can't carry these, but a forged table can: never let one through as a number.
			local odd: { { name: string, value: number } } = {
				{ name = "NaN", value = 0 / 0 },
				{ name = "infinity", value = math.huge },
				{ name = "minus infinity", value = -math.huge },
			}
			for _, case in odd do
				t.it(`body.length and stance.rideHeight = {case.name}: rejected or clamped into range`, function()
					for _, path in { { "body", "length" }, { "stance", "rideHeight" } } do
						local spec = design(tamper(validDesign(), path, case.value))
						if spec ~= nil then
							local range = if path[1] == "body" then kit.ranges.body else kit.ranges.rideHeight
							local value = getPath(spec, path)
							t.expect(type(value) == "number" and value == value).toBe(true)
							t.expect(value >= range.min and value <= range.max).toBe(true)
						end
					end
				end)
			end
		end)

		t.describe("over-long text is cut to the kit limits", function()
			-- Long, but the whole spec stays well under specBytes, so these test cutting and not the size limit.
			local cases: { { field: string, text: string, limit: number } } = {
				{ field = "name", text = string.rep("A", 100), limit = LIMITS.name },
				{ field = "tagline", text = string.rep("b", 200), limit = LIMITS.tagline },
				{ field = "meshPrompt", text = string.rep("c", 600), limit = LIMITS.meshPrompt },
				{ field = "name", text = string.rep("\u{E9}", 40), limit = LIMITS.name }, -- 2-byte characters
				{ field = "tagline", text = string.rep("\u{1F697}", 70), limit = LIMITS.tagline }, -- 4-byte
			}
			for _, case in cases do
				t.it(`{case.field}: {utf8.len(case.text)} characters -> at most {case.limit}`, function()
					local raw = tamper(validDesign(), { case.field }, case.text)
					t.expect(#HttpService:JSONEncode(raw) < LIMITS.specBytes).toBe(true) -- the case's own premise
					local spec, reasons = design(raw)
					expectAccepted(t, spec, reasons)
					t.expect(isCut(spec[case.field], case.text, case.limit)).toBe(true)
				end)
			end
		end)

		t.describe("unknown fields are dropped", function()
			t.it("at the top and in every block, stat fields included", function()
				local raw = validDesign()
				raw.topSpeedMph = 999
				raw.zeroToSixtySec = 0.1
				raw.stats = { topSpeedMph = 999, handling = 1 }
				raw.cash = 1e9
				raw.vehicleId = "ohm_spark"
				raw.trim = "design"
				raw.designUid = "forged"
				raw.hidden = false
				raw.body.turbo = true
				raw.parts.engine = "huge"
				raw.paint.glow = "#FF0000"
				raw.stance.hover = 5
				local spec, reasons = design(raw)
				expectAccepted(t, spec, reasons)
				t.expect(unexpectedKeys(spec, DESIGN_FIELDS)).toEqual({})
				for block, fields in BLOCK_FIELDS do
					t.expect(unexpectedKeys(spec[block], fields)).toEqual({})
				end
			end)
		end)

		t.describe("wrong types are rejected", function()
			local cases: { { path: { string }, value: any } } = {
				{ path = { "name" }, value = 42 },
				{ path = { "tagline" }, value = { "a", "b" } },
				{ path = { "class" }, value = 7 },
				{ path = { "energy" }, value = true },
				{ path = { "personality" }, value = 1 },
				{ path = { "meshPrompt" }, value = false },
				{ path = { "body" }, value = "wide" },
				{ path = { "body", "length" }, value = "0.5" },
				{ path = { "body", "template" }, value = 3 },
				{ path = { "parts" }, value = { "clean", "clean", "none", "slim", "stock" } },
				{ path = { "parts", "wheels" }, value = 5 },
				{ path = { "paint" }, value = "red" },
				{ path = { "paint", "primary" }, value = 16711680 },
				{ path = { "stance" }, value = true },
				{ path = { "stance", "rideHeight" }, value = "1" },
			}
			for _, case in cases do
				t.it(`{table.concat(case.path, ".")} = {show(case.value)}`, function()
					local spec, reasons = design(tamper(validDesign(), case.path, case.value))
					expectRejected(t, spec, reasons)
				end)
			end

			-- `value` is left out (nil) in the first case.
			local wholes: { { label: string, value: any } } = {
				{ label = "nothing" },
				{ label = "a string", value = "spec" },
				{ label = "a number", value = 42 },
				{ label = "a boolean", value = true },
				{ label = "an empty table", value = {} },
			}
			for _, case in wholes do
				t.it(`a whole spec of {case.label}`, function()
					local spec, reasons = design(case.value)
					expectRejected(t, spec, reasons)
				end)
			end
		end)

		t.describe("missing fields are rejected", function()
			local paths: { { string } } = {
				{ "name" },
				{ "tagline" },
				{ "class" },
				{ "energy" },
				{ "personality" },
				{ "meshPrompt" },
				{ "body" },
				{ "parts" },
				{ "paint" },
				{ "stance" },
				{ "body", "template" },
				{ "body", "flare" },
				{ "parts", "lights" },
				{ "paint", "secondary" },
				{ "paint", "stripe" },
				{ "stance", "wheelSize" },
			}
			for _, path in paths do
				t.it(table.concat(path, "."), function()
					local spec, reasons = design(tamper(validDesign(), path, REMOVE))
					expectRejected(t, spec, reasons)
				end)
			end
		end)

		t.describe("bad colors are rejected", function()
			for _, color in { "red", "#12345", "#1234567", "#GG0000", "123456", "" } do
				t.it(`paint.primary = {show(color)}`, function()
					local spec, reasons = design(tamper(validDesign(), { "paint", "primary" }, color))
					expectRejected(t, spec, reasons)
				end)
			end
		end)

		t.describe("specs over specBytes", function()
			t.it("are rejected, or come back within specBytes", function()
				local raw = validDesign()
				for i = 1, 6 do
					raw[`padding{i}`] = string.rep("x", math.ceil(LIMITS.specBytes / 4))
				end
				t.expect(#HttpService:JSONEncode(raw) > LIMITS.specBytes).toBe(true) -- the case's own premise
				local spec = design(raw)
				if spec ~= nil then
					t.expect(#HttpService:JSONEncode(spec) <= LIMITS.specBytes).toBe(true)
				end
			end)

			t.it("with one huge text are rejected, or cut and within specBytes", function()
				local text = string.rep("m", LIMITS.specBytes * 2)
				local spec = design(tamper(validDesign(), { "meshPrompt" }, text))
				if spec ~= nil then
					t.expect(isCut(spec.meshPrompt, text, LIMITS.meshPrompt)).toBe(true)
					t.expect(#HttpService:JSONEncode(spec) <= LIMITS.specBytes).toBe(true)
				end
			end)
		end)
	end)

	t.describe("stats", function()
		t.it("sit inside the class band for every class, template, personality and energy", function()
			local problems: { string } = {}
			for _, classId in classIds() do
				local class = kit.classes[classId]
				for _, template in class.templates do
					for _, energy in class.energy do
						for _, personality in personalities() do
							local label = `{classId}/{template}/{energy}/{personality}`
							local spec = design(validDesign(classId, template, personality, energy))
							if spec == nil then
								table.insert(problems, `{label}: rejected`)
							else
								for _, line in outOfBand(classId, SpecBuilder.stats(spec, kit), label) do
									table.insert(problems, line)
								end
							end
						end
					end
				end
			end
			t.expect(problems).toEqual({})
		end)

		-- Config/DesignKit bandCeiling: a design never matches the band's best catalog trims.
		t.it("stay below the band's best for every class and personality", function()
			local problems: { string } = {}
			for _, classId in classIds() do
				for _, personality in personalities() do
					local spec = design(validDesign(classId, nil, personality))
					local stats = if spec ~= nil then SpecBuilder.stats(spec, kit) else nil
					for _, field in { "topSpeedMph", "zeroToSixtySec", "handling", "energyMinutes" } do
						local range = band(classId, field)
						local best = if LOWER_IS_BETTER[field] then range.min else range.max
						local value = if type(stats) == "table" then stats[field] else nil
						if type(value) ~= "number" or math.abs(value - best) <= EPSILON then
							table.insert(problems, `{classId}/{personality}: {field} {tostring(value)} is the best`)
						end
					end
				end
			end
			t.expect(problems).toEqual({})
		end)

		t.it("come only from class and personality, never from text, body, parts, paint or stance", function()
			local plain = validDesign("muscle", "fastback", "torquey", "fuel")
			local loud = validDesign("muscle", "fastback", "torquey", "fuel")
			loud.name = "FASTEST CAR EVER"
			loud.tagline = "999 mph, 0-60 in 0.1 s, infinite range"
			loud.meshPrompt = "the fastest record-breaking land speed car in the world"
			for _, field in BODY_NUMBERS do
				loud.body[field] = 1
			end
			loud.parts = {
				frontBumper = "aero",
				rearBumper = "diffuser",
				spoiler = "wing",
				lights = "bar",
				wheels = "aero",
			}
			loud.paint = { primary = "#FF0000", secondary = "#000000", finish = "metallic", stripe = "center" }
			loud.stance = { rideHeight = -1, wheelSize = 1 }
			loud.topSpeedMph = 999
			loud.stats = { topSpeedMph = 999, zeroToSixtySec = 0.1, handling = 1, energyMinutes = 999 }
			local plainSpec, plainReasons = design(plain)
			local loudSpec, loudReasons = design(loud)
			expectAccepted(t, plainSpec, plainReasons)
			expectAccepted(t, loudSpec, loudReasons)
			local a, b = SpecBuilder.stats(plainSpec, kit), SpecBuilder.stats(loudSpec, kit)
			for _, field in { "topSpeedMph", "zeroToSixtySec", "handling", "energyMinutes" } do
				t.expect({ field = field, value = b[field] }).toEqual({ field = field, value = a[field] })
			end
			t.expect(outOfBand("muscle", b, "loud")).toEqual({})
		end)
	end)

	t.describe("Validate.mod", function()
		t.it("passes a valid catalog mod with its values kept", function()
			local raw = validMod()
			local spec, reasons = mod(raw, "catalog")
			expectAccepted(t, spec, reasons)
			t.expect(string.upper(spec.paint.primary)).toBe(string.upper(raw.paint.primary))
			t.expect(spec.paint.finish).toBe(raw.paint.finish)
			t.expect(spec.parts.wheels).toBe(raw.parts.wheels)
			local changes, value = readNumber(spec.stance.rideHeight)
			t.expect(changes).toBe(true)
			t.expect(value).toBeNear(0.75, EPSILON)
			t.expect(spec.extras).toEqual(raw.extras)
		end)

		t.it("passes a valid kit mod that re-proportions the body and swaps body parts", function()
			local spec, reasons = mod(validKitMod(), "kit")
			expectAccepted(t, spec, reasons)
			local changes, value = readNumber(spec.body.length)
			t.expect(changes).toBe(true)
			t.expect(value).toBeNear(0.8, EPSILON)
			t.expect(spec.parts.frontBumper).toBe("sport")
			t.expect(spec.parts.spoiler).toBe("wing")
		end)

		t.it("passes a mod that keeps everything, on either kind of car", function()
			local raw = validMod()
			raw.parts.wheels = KEEP
			raw.paint = { primary = KEEP, secondary = KEEP, finish = KEEP, stripe = KEEP }
			raw.stance = { rideHeight = unchanged(), wheelSize = unchanged() }
			raw.extras = {}
			for _, kind in { "catalog", "kit" } do
				local spec, reasons = mod(raw, kind)
				expectAccepted(t, spec, reasons)
			end
		end)

		-- PLAN.md: on catalog cars a mod is limited to paint, finish, stripes, wheels, stance and mount extras.
		t.it("never changes the body or body parts of a catalog car", function()
			local raw = validKitMod()
			raw.body.template = "wedge"
			raw.parts.frontBumper = "rugged"
			raw.parts.lights = "bar"
			local spec = mod(raw, "catalog")
			if spec ~= nil then
				t.expect(disallowedOnCatalog(spec)).toEqual({})
				-- Kept, not thrown away: what a catalog car may change still comes through.
				t.expect(getPath(spec, { "parts", "wheels" })).toBe(raw.parts.wheels)
			end
		end)

		-- The template sets the chassis box and the seats, which no mod may change (ModBuilder never touches the
		-- Chassis), so on either kind of car a template in a mod is rejected or kept, never applied.
		for _, kind in { "kit", "catalog" } do
			t.it(`never changes the body template of a {kind} car`, function()
				for _, template in { "wedge", "tank" } do
					local spec = mod(tamper(validKitMod(), { "body", "template" }, template), kind)
					if spec ~= nil then
						local kept = getPath(spec, { "body", "template" })
						t.expect(kept == nil or kept == KEEP).toBe(true)
					end
				end
			end)
		end

		t.describe("unknown enums are rejected", function()
			local cases: { { path: { string }, value: any } } = {
				{ path = { "parts", "wheels" }, value = "spinners" },
				{ path = { "parts", "frontBumper" }, value = "spikes" },
				{ path = { "paint", "finish" }, value = "chrome" },
				{ path = { "paint", "stripe" }, value = "flames" },
				{ path = { "extras" }, value = { "roof_rack", "rocket_booster" } },
			}
			for _, case in cases do
				t.it(`{table.concat(case.path, ".")} = {show(case.value)}`, function()
					local spec, reasons = mod(tamper(validMod(), case.path, case.value), "kit")
					expectRejected(t, spec, reasons)
				end)
			end
		end)

		t.describe("out-of-range numbers are clamped", function()
			local cases: { { path: { string }, value: number, expected: number } } = {
				{ path = { "stance", "rideHeight" }, value = 5, expected = kit.ranges.rideHeight.max },
				{ path = { "stance", "rideHeight" }, value = -5, expected = kit.ranges.rideHeight.min },
				{ path = { "stance", "wheelSize" }, value = 3, expected = kit.ranges.wheelSize.max },
				{ path = { "body", "flare" }, value = -2, expected = kit.ranges.body.min },
				{ path = { "body", "length" }, value = 4, expected = kit.ranges.body.max },
			}
			for _, case in cases do
				t.it(`{table.concat(case.path, ".")} = {case.value} -> {case.expected}`, function()
					local spec, reasons = mod(tamper(validKitMod(), case.path, changeTo(case.value)), "kit")
					expectAccepted(t, spec, reasons)
					local changes, value = readNumber(getPath(spec, case.path))
					t.expect(changes).toBe(true)
					t.expect(value).toBeNear(case.expected, EPSILON)
				end)
			end
		end)

		t.it(`allows at most {LIMITS.maxExtras} extras: more are rejected or cut`, function()
			local raw = validMod()
			raw.extras = sortedKeys(kit.extras) -- every kit extra, more than the limit
			t.expect(#raw.extras > LIMITS.maxExtras).toBe(true) -- the case's own premise
			local spec = mod(raw, "kit")
			if spec ~= nil then
				t.expect(type(spec.extras) == "table" and #spec.extras <= LIMITS.maxExtras).toBe(true)
				for _, extraId in spec.extras do
					t.expect(kit.extras[extraId] ~= nil).toBe(true)
				end
			end
		end)

		t.it("drops unknown fields, so no stat, class or personality rides along", function()
			local raw = validMod()
			raw.class = "hypercar"
			raw.personality = "track"
			raw.energy = "fuel"
			raw.topSpeedMph = 999
			raw.zeroToSixtySec = 0.1
			raw.stats = { topSpeedMph = 999 }
			raw.vehicleId = "ohm_spark"
			raw.trim = "design"
			raw.designUid = "forged"
			raw.credits = 1000
			raw.stance.hover = changeTo(1)
			raw.paint.glow = "#FFFFFF"
			for _, kind in { "catalog", "kit" } do
				local spec, reasons = mod(raw, kind)
				expectAccepted(t, spec, reasons)
				t.expect(unexpectedKeys(spec, MOD_FIELDS)).toEqual({})
				for block, fields in BLOCK_FIELDS do
					t.expect(unexpectedKeys(spec[block], fields)).toEqual({})
				end
			end
		end)

		t.it("cuts the summary to the kit limit and never keeps an accessory prompt", function()
			local summary = string.rep("s", 200)
			local accessory = string.rep("a", 400)
			local raw = validMod()
			raw.summary = summary
			raw.accessoryPrompt = accessory
			t.expect(#HttpService:JSONEncode(raw) < LIMITS.specBytes).toBe(true) -- the case's own premise
			local spec, reasons = mod(raw, "kit")
			expectAccepted(t, spec, reasons)
			t.expect(isCut(spec.summary, summary, LIMITS.summary)).toBe(true)
			-- Nothing builds a generated accessory yet, so it is never kept (it would be paid for and never seen).
			t.expect(spec.accessoryPrompt).toBe("none")
		end)

		-- The backend sends `extras = {}` for "mount nothing new" on every mod that doesn't ask for extras.
		t.it("reads an empty extras list as keep", function()
			local raw = validMod()
			raw.extras = {}
			for _, kind in { "catalog", "kit" } do
				local spec, reasons = mod(raw, kind)
				expectAccepted(t, spec, reasons)
				t.expect(spec.extras).toBe(KEEP)
			end
		end)

		t.it("keeps an earlier mod's extras when a later mod doesn't mention any", function()
			local first = mod(validMod(), "kit")
			local paintOnly = validMod()
			paintOnly.parts.wheels = KEEP
			paintOnly.stance = { rideHeight = unchanged(), wheelSize = unchanged() }
			paintOnly.paint = { primary = "#2255AA", secondary = KEEP, finish = KEEP, stripe = KEEP }
			paintOnly.extras = {}
			local second = mod(paintOnly, "kit")
			t.expect(first ~= nil and second ~= nil).toBe(true)
			local merged = Validate.mergeMods(first, second, kit)
			t.expect(merged.extras).toEqual(first.extras)
			t.expect(merged.paint.primary).toBe("#2255AA")
		end)

		t.it("calls a backend-shaped mod that only keeps (empty extras, an accessory) empty", function()
			local raw = validMod()
			raw.parts.wheels = KEEP
			raw.paint = { primary = KEEP, secondary = KEEP, finish = KEEP, stripe = KEEP }
			raw.stance = { rideHeight = unchanged(), wheelSize = unchanged() }
			raw.extras = {}
			raw.accessoryPrompt = "a surfboard on the roof"
			raw.body.template = "pickup" -- a template swap is never applied either
			for _, kind in { "catalog", "kit" } do
				local spec, reasons = mod(raw, kind)
				expectAccepted(t, spec, reasons)
				t.expect(Validate.isEmptyMod(spec, kit)).toBe(true)
			end
		end)

		t.describe("wrong types are rejected", function()
			local cases: { { path: { string }, value: any } } = {
				{ path = { "summary" }, value = 12 },
				{ path = { "extras" }, value = "roof_rack" },
				{ path = { "extras" }, value = { 1, 2 } },
				{ path = { "body" }, value = "long" },
				{ path = { "stance" }, value = 5 },
				{ path = { "stance", "rideHeight" }, value = "up" },
				{ path = { "paint", "primary" }, value = 123 },
				{ path = { "parts", "wheels" }, value = false },
			}
			for _, case in cases do
				t.it(`{table.concat(case.path, ".")} = {show(case.value)}`, function()
					local spec, reasons = mod(tamper(validMod(), case.path, case.value), "kit")
					expectRejected(t, spec, reasons)
				end)
			end

			-- `value` is left out (nil) in the first case.
			local wholes: { { label: string, value: any } } = {
				{ label = "nothing" },
				{ label = "a string", value = "mod" },
				{ label = "a number", value = 7 },
			}
			for _, case in wholes do
				t.it(`a whole mod of {case.label}`, function()
					local spec, reasons = mod(case.value, "catalog")
					expectRejected(t, spec, reasons)
				end)
			end
		end)

		t.it("rejects a mod over specBytes, or returns it within specBytes", function()
			local raw = validMod()
			for i = 1, 6 do
				raw[`padding{i}`] = string.rep("x", math.ceil(LIMITS.specBytes / 4))
			end
			t.expect(#HttpService:JSONEncode(raw) > LIMITS.specBytes).toBe(true) -- the case's own premise
			local spec = mod(raw, "kit")
			if spec ~= nil then
				t.expect(#HttpService:JSONEncode(spec) <= LIMITS.specBytes).toBe(true)
			end
		end)
	end)

	-- A car's stats come from its catalog entry, found by VehicleId and Trim; a design's entry comes from
	-- SpecBuilder.stats (checked above). So a mod keeps stats in band as long as it never touches the chassis, the
	-- hubs or that identity, and adds nothing that takes part in physics.
	t.describe("mods never touch physics, so stats stay in band", function()
		t.it("on a designed car, after a kit mod at the extremes", function()
			local spec, reasons = design(validDesign("sports", "coupe", "track"))
			expectAccepted(t, spec, reasons)
			local raw = validKitMod()
			for _, field in BODY_NUMBERS do
				raw.body[field] = changeTo(kit.ranges.body.max)
			end
			for _, field in STANCE_NUMBERS do
				raw.stance[field] = changeTo(kit.ranges[field].min)
			end
			raw.parts =
				{ frontBumper = "aero", rearBumper = "diffuser", spoiler = "wing", lights = "split", wheels = "aero" }
			raw.extras = { "wing_spoiler", "front_splitter", "rear_diffuser" }
			local modSpec, modReasons = mod(raw, "kit")
			expectAccepted(t, modSpec, modReasons)

			local model: Model = SpecBuilder.build(spec, kit)
			local before = physicsOf(model)
			ModBuilder.apply(model, modSpec, kit, "kit")
			local after = physicsOf(model)
			local changes = physicsChanges(before, after)
			local physical = physicalExtras(model)
			model:Destroy()
			t.expect(changes).toEqual({})
			t.expect(physical).toEqual({})
			t.expect(outOfBand("sports", SpecBuilder.stats(spec, kit), "sports/coupe/track")).toEqual({})
		end)

		t.it("on a catalog car, after a catalog mod", function()
			local vehicleId, trimId = catalogCar()
			local modSpec, reasons = mod(validMod(), "catalog")
			expectAccepted(t, modSpec, reasons)

			local model = VehicleBuilder.assemble(vehicleId, trimId)
			local before = physicsOf(model)
			ModBuilder.apply(model, modSpec, kit, "catalog")
			local after = physicsOf(model)
			local changes = physicsChanges(before, after)
			local physical = physicalExtras(model)
			model:Destroy()
			t.expect(changes).toEqual({})
			t.expect(physical).toEqual({})
		end)
	end)

	-- A hidden design is published under the same catalog id, so its geometry (body numbers and stance) must not move.
	t.describe("Validate.plain", function()
		t.it(
			"keeps the class, stats, body numbers and stance (the same chassis); plain parts, paint and name",
			function()
				local raw = validDesign("muscle", "fastback", "torquey", "fuel")
				for index, field in BODY_NUMBERS do
					raw.body[field] = index / (#BODY_NUMBERS + 1)
				end
				raw.stance = { rideHeight = -0.6, wheelSize = 0.9 }
				raw.parts.spoiler = "wing"
				local spec, reasons = design(raw)
				expectAccepted(t, spec, reasons)
				local plain = Validate.plain(spec, kit)
				t.expect(plain.body).toEqual(spec.body)
				t.expect(plain.stance).toEqual(spec.stance)
				t.expect({ class = plain.class, energy = plain.energy, personality = plain.personality })
					.toEqual({ class = spec.class, energy = spec.energy, personality = spec.personality })
				t.expect(SpecBuilder.geometry(plain, kit)).toEqual(SpecBuilder.geometry(spec, kit))
				t.expect(SpecBuilder.stats(plain, kit)).toEqual(SpecBuilder.stats(spec, kit))
				for field, value in plain.parts do
					t.expect({ field = field, value = value }).toEqual({ field = field, value = kit.parts[field][1] })
				end
				t.expect(plain.meshPrompt).toBe("")
				t.expect(plain.tagline).toBe("")
				t.expect(plain.body == spec.body).toBe(false) -- a copy, never the saved spec's own table
			end
		)
	end)

	-- PLAN.md: extras go on mount points, and Config/Customization says which cars each extra fits.
	t.describe("extras a car can carry", function()
		t.it("lists only the extras that fit the class and body style", function()
			local problems: { string } = {}
			for _, classId in classIds() do
				for _, template in kit.classes[classId].templates do
					local style = kit.templates[template].style
					local fits = Validate.extrasThatFit(kit, classId, style)
					for _, id in sortedKeys(kit.extras) do
						local listed = table.find(fits, id) ~= nil
						if listed ~= Customization.extraAllowed(id, classId, style) then
							table.insert(
								problems,
								`{classId}/{template}: {id} {if listed then "listed" else "missing"}`
							)
						end
					end
				end
			end
			t.expect(problems).toEqual({})
		end)

		t.it("leaves off extras the car can't carry and keeps the rest", function()
			local raw = validMod()
			raw.extras = { "roof_rack", "wing_spoiler" } -- a sports coupe takes a wing, never a roof rack
			local modSpec, reasons = mod(raw, "catalog")
			expectAccepted(t, modSpec, reasons)
			local fitted, dropped = Validate.fitExtras(modSpec, kit, "sports", "coupe")
			t.expect(fitted.extras).toEqual({ "wing_spoiler" })
			t.expect(dropped).toEqual({ "roof_rack" })
			t.expect(modSpec.extras).toEqual({ "roof_rack", "wing_spoiler" }) -- the mod given is never changed
			local same, none = Validate.fitExtras(modSpec, kit, "pickup", "pickup")
			t.expect(same.extras).toEqual({ "roof_rack" })
			t.expect(none).toEqual({ "wing_spoiler" })
		end)

		t.it("turns extras that all don't fit into keep, so an extras-only mod is empty", function()
			local raw = validMod()
			raw.parts.wheels = KEEP
			raw.paint = { primary = KEEP, secondary = KEEP, finish = KEEP, stripe = KEEP }
			raw.stance = { rideHeight = unchanged(), wheelSize = unchanged() }
			raw.extras = { "roof_rack", "light_bar" }
			local modSpec, reasons = mod(raw, "catalog")
			expectAccepted(t, modSpec, reasons)
			t.expect(Validate.isEmptyMod(modSpec, kit)).toBe(false)
			local fitted, dropped = Validate.fitExtras(modSpec, kit, "sports", "coupe")
			t.expect(fitted.extras).toBe(KEEP)
			t.expect(#dropped).toBe(1) -- one per mount point: Validate.mod kept only the roof rack
			t.expect(Validate.isEmptyMod(fitted, kit)).toBe(true)
		end)
	end)
end
