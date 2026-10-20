--!strict
-- The AI Car Designer kit (Config/DesignKit.json, kitVersion 1; docs/phase-11-contracts.md "Kit" and "Tests") is
-- sane and agrees with the Luau side of the game:
--   * classes: exactly the classes Config/Classes marks designable (hypercar never), each with templates and
--     energy from the kit; tier rules and "surprise me" name only real, open classes
--   * templates: built on a VehicleBuilder body style, with full, sane geometry at every proportion, and built
--     (Vehicle/SpecBuilder) with a seat count inside the seat band of every class that lists them
--   * parts, finishes and extras: the Wrap & Tint ids (Config/Customization) on the mounts the model contract has
--   * numbers: the ranges PLAN.md states (and Config/Customization's stance range), proportions that scale sanely,
--     and a lowest stance that still clears the dev track's humps (the Phase 1 bump check every design must pass)
--   * limits: fit the remotes (Net DesignCar and ModCar take a full prompt of the widest characters) and the save
--     (the largest design and mod encode within specBytes, which is at most PLAN.md's 2 KB)
--   * personalities: positions inside the band, scaled by a bandCeiling below 1
--   * mod rules: "keep" collides with no id, and catalog mods may touch only part of what kit mods may
--   * ids: plain snake_case, with no real carmaker or model name in any id or text
--
-- Read by the harness in Edit mode (ServerStorage.Tests). The backend copies the kit (backend/lib/kit.json, npm run
-- sync-kit) and checks its copy matches in its own tests.

local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local BrandNames = require(ReplicatedStorage.Shared.Util.BrandNames)
local Classes = require(ReplicatedStorage.Shared.Config.Classes)
local Customization = require(ReplicatedStorage.Shared.Config.Customization)
local DevTrack = require(ReplicatedStorage.Shared.Config.DevTrack)
local Harness = require(ReplicatedStorage.Shared.Testing.Harness)
local Net = require(ReplicatedStorage.Shared.Net)
local SpecBuilder = require(ReplicatedStorage.Shared.Vehicle.SpecBuilder)
local VehicleBuilder = require(ServerScriptService.Server.Dev.VehicleBuilder)

-- Rojo serves the JSON as a ModuleScript returning the decoded table.
local kit: any = require(ReplicatedStorage.Shared.Config.DesignKit)

local KIT_VERSION = 1

-- PLAN.md Phase 11 "Design spec": every number of a spec is clamped to these.
local PLAN_RANGES: { [string]: { min: number, max: number } } = {
	body = { min = 0, max = 1 },
	rideHeight = { min = -1, max = 1 },
	wheelSize = { min = 0, max = 1 },
}
-- PLAN.md Phase 11 "Design spec" enums, sorted.
local PLAN_PERSONALITIES = { "balanced", "efficient", "torquey", "track" }
local PLAN_FINISHES = { "gloss", "matte", "metallic" }
local PLAN_STRIPES = { "center", "none", "side" }
local PLAN_ENERGY = { "battery", "fuel" }
local PLAN_MAX_SPEC_BYTES = 2048 -- "save the spec to designs (≤ 2 KB)"

local GEOMETRY_FIELDS =
	{ "length", "width", "height", "wheelbase", "track", "wheelRadius", "wheelWidth", "rideHeight", "chassisHeight" }
local BODY_FIELDS = { "length", "height", "roofline", "noseSlope", "flare" }
local STANCE_FIELDS = { "rideHeight", "wheelSize" }
local SCALE_FIELDS = { "length", "height", "roofline", "flare", "wheelSize" } -- proportions that multiply a size
local PART_SLOTS = { "frontBumper", "rearBumper", "spoiler", "lights", "wheels" }
local PERSONALITY_FIELDS = { "acceleration", "topSpeed", "handling", "range" }
local LIMIT_FIELDS = {
	"promptChars",
	"modPromptChars",
	"name",
	"tagline",
	"summary",
	"meshPrompt",
	"accessoryPrompt",
	"refusal",
	"maxExtras",
	"specBytes",
	"minFilteredChars",
}
local MOD_BLOCKS = { "body", "parts", "paint", "stance", "extras" } -- what a mod spec may change at all
local NO_SPOILER = "none"

-- Mount attachments on the Chassis (docs/phase-1-contracts.md "Vehicle model contract").
local MOUNTS = {
	Mount_Roof = true,
	Mount_Hood = true,
	Mount_Spoiler = true,
	Mount_FrontBumper = true,
	Mount_RearBumper = true,
	Mount_SideL = true,
	Mount_SideR = true,
}

local MIN_SEATS, MAX_SEATS = 1, 8 -- the seat counts a generic body lays out (VehicleBuilder ROW_PLANS)
local WIDEST_CHARACTER = "\u{1F697}" -- 4 bytes in UTF-8, the most one character of a prompt can take
local ID_PATTERN = "^[a-z][a-z0-9_]*$"
local LONG_DECIMAL = -0.12345678901234568 -- encodes to as many JSON characters as a number can

-- Real carmaker and model names: Util/BrandNames' list (scripts/banned-names.txt written out as whole-word phrases,
-- both spellings where the list allows an optional space or dash), ROT13-encoded so no file trips the repo's own
-- brand-name gate. scripts/check.ps1 keeps it in step with scripts/banned-names.txt.
local BANNED_ROT13: { string } = BrandNames.encoded

-- Helpers ---------------------------------------------------------------------------------------------------

local function sortedKeys(map: { [string]: any }): { string }
	local keys: { string } = {}
	for key in map do
		table.insert(keys, key)
	end
	table.sort(keys)
	return keys
end

local function sortedCopy(list: { string }): { string }
	local copy = table.clone(list)
	table.sort(copy)
	return copy
end

local function isPositive(value: any): boolean
	return type(value) == "number" and value == value and value > 0 and value < math.huge
end

local function isWhole(value: any): boolean
	return type(value) == "number" and value == value and value % 1 == 0
end

-- The entries that appear more than once in a list.
local function duplicates(list: { string }): { string }
	local seen: { [string]: boolean } = {}
	local repeated: { string } = {}
	for _, item in list do
		if seen[item] then
			table.insert(repeated, item)
		end
		seen[item] = true
	end
	return repeated
end

-- Every designable class in Config/Classes, sorted.
local function designableClasses(): { string }
	local ids: { string } = {}
	for id, class in Classes do
		if class.designable then
			table.insert(ids, id)
		end
	end
	table.sort(ids)
	return ids
end

-- The longest string in a list.
local function longest(list: { string }): string
	local best = ""
	for _, item in list do
		if #item > #best then
			best = item
		end
	end
	return best
end

local function rot13(text: string): string
	return (
		string.gsub(text, "%l", function(letter: string): string
			return string.char((string.byte(letter) - string.byte("a") + 13) % 26 + string.byte("a"))
		end)
	)
end

-- Text as space-separated lowercase words with a space at each end, so a phrase matches only whole words:
-- "frontBumper" -> " front bumper ", "lip_spoiler" -> " lip spoiler ", "a-b c" -> " a b c ".
local function words(text: string): string
	local spaced = string.gsub(text, "(%l)(%u)", "%1 %2")
	spaced = string.gsub(string.lower(spaced), "[^%w]+", " ")
	return " " .. spaced .. " "
end

local bannedPhrases: { string } = {}
for _, encoded in BANNED_ROT13 do
	table.insert(bannedPhrases, " " .. rot13(encoded) .. " ")
end

-- Whether text holds a real carmaker or model name as whole words.
local function hasBannedName(text: string): boolean
	local spaced = words(text)
	for _, phrase in bannedPhrases do
		if string.find(spaced, phrase, 1, true) ~= nil then
			return true
		end
	end
	return false
end

-- Every string in the kit: keys and values, at any depth.
local function kitStrings(value: any, into: { string })
	if type(value) == "string" then
		table.insert(into, value)
	elseif type(value) == "table" then
		for key, item in value do
			if type(key) == "string" then
				table.insert(into, key)
			end
			kitStrings(item, into)
		end
	end
end

-- Every id the kit defines or uses (not its notes).
local function kitIds(): { string }
	local ids: { string } = {}
	for classId, class in kit.classes do
		table.insert(ids, classId)
		for _, templateId in class.templates do
			table.insert(ids, templateId)
		end
		for _, energy in class.energy do
			table.insert(ids, energy)
		end
	end
	for _, classId in kit.surpriseClasses do
		table.insert(ids, classId)
	end
	for templateId in kit.templates do
		table.insert(ids, templateId)
	end
	for _, slot in PART_SLOTS do
		for _, partId in kit.parts[slot] do
			table.insert(ids, partId)
		end
	end
	for extraId in kit.extras do
		table.insert(ids, extraId)
	end
	for _, list in { kit.finishes, kit.stripes, kit.energy } do
		for _, id in list do
			table.insert(ids, id)
		end
	end
	for personality in kit.personalities do
		table.insert(ids, personality)
	end
	return ids
end

-- The largest design spec the kit allows: every text at its limit and the longest id in every enum.
local function largestDesign(): { [string]: any }
	local limits = kit.limits
	local classIds = sortedKeys(kit.classes)
	local templateIds = sortedKeys(kit.templates)
	local body: { [string]: any } = { template = longest(templateIds) }
	for _, field in BODY_FIELDS do
		body[field] = LONG_DECIMAL
	end
	local parts: { [string]: any } = {}
	for _, slot in PART_SLOTS do
		parts[slot] = longest(kit.parts[slot])
	end
	return {
		refusal = string.rep("r", limits.refusal),
		name = string.rep("n", limits.name),
		tagline = string.rep("t", limits.tagline),
		class = longest(classIds),
		energy = longest(kit.energy),
		personality = longest(sortedKeys(kit.personalities)),
		meshPrompt = string.rep("m", limits.meshPrompt),
		body = body,
		parts = parts,
		paint = {
			primary = "#FFFFFF",
			secondary = "#FFFFFF",
			finish = longest(kit.finishes),
			stripe = longest(kit.stripes),
		},
		stance = { rideHeight = LONG_DECIMAL, wheelSize = LONG_DECIMAL },
	}
end

-- The largest mod spec: the design blocks with every number as a changed number field, the longest extras, and
-- every text at its limit. (However the mod's number fields are spelt, they are no bigger than this.)
local function largestMod(): { [string]: any }
	local limits = kit.limits
	local spec = largestDesign()
	local function changed(): { [string]: any }
		return { change = true, value = LONG_DECIMAL }
	end
	for _, field in BODY_FIELDS do
		spec.body[field] = changed()
	end
	for _, field in STANCE_FIELDS do
		spec.stance[field] = changed()
	end
	local extraIds = sortedKeys(kit.extras)
	table.sort(extraIds, function(a: string, b: string): boolean
		return #a > #b
	end)
	local extras: { string } = {}
	for i = 1, math.min(limits.maxExtras, #extraIds) do
		table.insert(extras, extraIds[i])
	end
	return {
		refusal = spec.refusal,
		summary = string.rep("s", limits.summary),
		body = spec.body,
		parts = spec.parts,
		paint = spec.paint,
		stance = spec.stance,
		extras = extras,
		accessoryPrompt = string.rep("a", limits.accessoryPrompt),
	}
end

return function(t: Harness.Api)
	t.describe("DesignKit", function()
		t.it(`is kit version {KIT_VERSION}`, function()
			t.expect(kit.kitVersion).toBe(KIT_VERSION)
		end)

		t.describe("classes", function()
			t.it("are exactly the classes Config/Classes marks designable", function()
				t.expect(sortedKeys(kit.classes)).toEqual(designableClasses())
			end)

			t.it("never include the hypercar", function()
				t.expect(kit.classes.hypercar).toBe(nil)
				t.expect(Classes.hypercar.designable).toBe(false)
			end)

			t.it("each list templates and energy from the kit, without repeats", function()
				local problems: { string } = {}
				for _, classId in sortedKeys(kit.classes) do
					local class = kit.classes[classId]
					if type(class.templates) ~= "table" or #class.templates == 0 then
						table.insert(problems, `{classId}: no templates`)
					else
						for _, templateId in class.templates do
							if kit.templates[templateId] == nil then
								table.insert(problems, `{classId}: unknown template {templateId}`)
							end
						end
						for _, repeated in duplicates(class.templates) do
							table.insert(problems, `{classId}: template {repeated} listed twice`)
						end
					end
					if type(class.energy) ~= "table" or #class.energy == 0 then
						table.insert(problems, `{classId}: no energy`)
					else
						for _, energy in class.energy do
							if table.find(kit.energy, energy) == nil then
								table.insert(problems, `{classId}: unknown energy {energy}`)
							end
						end
					end
				end
				t.expect(problems).toEqual({})
			end)

			t.it("name only real classes in their tier rules", function()
				local problems: { string } = {}
				for _, classId in sortedKeys(kit.classes) do
					local required = kit.classes[classId].requiresOwnedClass
					if required ~= nil and Classes[required] == nil then
						table.insert(problems, `{classId}: requires unknown class {tostring(required)}`)
					end
				end
				t.expect(problems).toEqual({})
			end)

			t.it("keep the exotic behind an owned exotic", function()
				t.expect(kit.classes.exotic.requiresOwnedClass).toBe("exotic")
			end)

			t.it("offer 'surprise me' only designable classes open to everyone", function()
				local problems: { string } = {}
				if #kit.surpriseClasses == 0 then
					table.insert(problems, "no surprise classes")
				end
				for _, classId in kit.surpriseClasses do
					local class = kit.classes[classId]
					if class == nil then
						table.insert(problems, `{classId}: not a designable class`)
					elseif class.requiresOwnedClass ~= nil then
						table.insert(problems, `{classId}: needs an owned {class.requiresOwnedClass}`)
					end
				end
				for _, repeated in duplicates(kit.surpriseClasses) do
					table.insert(problems, `{repeated} listed twice`)
				end
				t.expect(problems).toEqual({})
			end)
		end)

		t.describe("templates", function()
			t.it("build on a VehicleBuilder body style", function()
				local styles = VehicleBuilder.bodyStyles()
				local problems: { string } = {}
				for _, templateId in sortedKeys(kit.templates) do
					local style = kit.templates[templateId].style
					if table.find(styles, style) == nil then
						table.insert(problems, `{templateId}: no body style {tostring(style)}`)
					end
				end
				t.expect(problems).toEqual({})
			end)

			t.it("are each used by at least one class", function()
				local used: { [string]: boolean } = {}
				for _, class in kit.classes do
					for _, templateId in class.templates do
						used[templateId] = true
					end
				end
				local unused: { string } = {}
				for _, templateId in sortedKeys(kit.templates) do
					if not used[templateId] then
						table.insert(unused, templateId)
					end
				end
				t.expect(unused).toEqual({})
			end)

			t.it("have full, positive geometry", function()
				local problems: { string } = {}
				for _, templateId in sortedKeys(kit.templates) do
					local geometry = kit.templates[templateId].geometry
					for _, field in GEOMETRY_FIELDS do
						if not isPositive(if type(geometry) == "table" then geometry[field] else nil) then
							table.insert(problems, `{templateId}: geometry.{field} is not a positive number`)
						end
					end
				end
				t.expect(problems).toEqual({})
			end)

			t.it("stay in proportion at every body and stance setting", function()
				local p = kit.proportions
				local problems: { string } = {}
				for _, templateId in sortedKeys(kit.templates) do
					local g = kit.templates[templateId].geometry
					-- Length and wheelbase scale together, as do width and track, so these hold at every setting.
					if g.wheelbase >= g.length then
						table.insert(problems, `{templateId}: wheelbase {g.wheelbase} >= length {g.length}`)
					end
					if g.track >= g.width then
						table.insert(problems, `{templateId}: track {g.track} >= width {g.width}`)
					end
					if g.chassisHeight >= g.height then
						table.insert(problems, `{templateId}: chassisHeight {g.chassisHeight} >= height {g.height}`)
					end
					-- The biggest wheels on the lowest body still fit under it.
					local wheel = 2 * g.wheelRadius * p.wheelSize.max
					local lowest = g.height * p.height.min
					if wheel >= lowest then
						table.insert(problems, `{templateId}: {wheel}-stud wheels on a {lowest}-stud-tall body`)
					end
				end
				t.expect(problems).toEqual({})
			end)

			t.it("seat a whole number of people a generic body can lay out", function()
				local problems: { string } = {}
				for _, templateId in sortedKeys(kit.templates) do
					local seats = kit.templates[templateId].seats
					if not isWhole(seats) or seats < MIN_SEATS or seats > MAX_SEATS then
						table.insert(problems, `{templateId}: {tostring(seats)} seats`)
					end
				end
				t.expect(problems).toEqual({})
			end)

			-- Seats are a stat like any other: a design must sit inside its class band (Config/Classes), as every
			-- catalog trim does (Catalog.validate). A template's own count is its usual one (a two-door coupe seats
			-- two); Vehicle/SpecBuilder keeps it inside the band of the class it is designed in (a coupe designed as
			-- a sedan seats four), so this checks what SpecBuilder builds, and that a generic body can lay it out.
			t.it("build a seat count inside the seat band of every class that lists them", function()
				local problems: { string } = {}
				for _, classId in sortedKeys(kit.classes) do
					local band = Classes[classId] and Classes[classId].seats
					for _, templateId in kit.classes[classId].templates do
						local seats =
							SpecBuilder.stats({ class = classId, body = { template = templateId } }, kit).seats
						if band == nil then
							table.insert(problems, `{classId}: no seat band in Config/Classes`)
						elseif seats < band.min or seats > band.max or seats < MIN_SEATS or seats > MAX_SEATS then
							table.insert(
								problems,
								`{classId} + {templateId}: {seats} seats, band {band.min}..{band.max}`
							)
						end
					end
				end
				t.expect(problems).toEqual({})
			end)
		end)

		t.describe("parts, finishes and extras", function()
			t.it("give every part slot a list of ids without repeats", function()
				local problems: { string } = {}
				for _, slot in PART_SLOTS do
					local list = kit.parts[slot]
					if type(list) ~= "table" or #list == 0 then
						table.insert(problems, `{slot}: no ids`)
					else
						for _, repeated in duplicates(list) do
							table.insert(problems, `{slot}: {repeated} listed twice`)
						end
					end
				end
				t.expect(problems).toEqual({})
			end)

			t.it("let a design have no spoiler", function()
				t.expect(table.find(kit.parts.spoiler, NO_SPOILER) ~= nil).toBe(true)
			end)

			t.it("use only Wrap & Tint wheel styles", function()
				local unknown: { string } = {}
				for _, wheelId in kit.parts.wheels do
					if Customization.getWheel(wheelId) == nil then
						table.insert(unknown, wheelId)
					end
				end
				t.expect(unknown).toEqual({})
			end)

			t.it("use only Wrap & Tint finishes, exactly PLAN.md's", function()
				local unknown: { string } = {}
				for _, finishId in kit.finishes do
					if Customization.getFinish(finishId) == nil then
						table.insert(unknown, finishId)
					end
				end
				t.expect(unknown).toEqual({})
				t.expect(sortedCopy(kit.finishes)).toEqual(PLAN_FINISHES)
			end)

			t.it("use PLAN.md's stripes and energy", function()
				t.expect(sortedCopy(kit.stripes)).toEqual(PLAN_STRIPES)
				t.expect(sortedCopy(kit.energy)).toEqual(PLAN_ENERGY)
			end)

			t.it("use only Wrap & Tint extras, each on its own mount", function()
				local problems: { string } = {}
				for _, extraId in sortedKeys(kit.extras) do
					local mount = kit.extras[extraId].mount
					local extra = Customization.getExtra(extraId)
					if extra == nil then
						table.insert(problems, `{extraId}: not a Wrap & Tint extra`)
					elseif extra.mount ~= mount then
						table.insert(
							problems,
							`{extraId}: kit mount {tostring(mount)}, Wrap & Tint mount {extra.mount}`
						)
					end
					if not MOUNTS[mount] then
						table.insert(problems, `{extraId}: {tostring(mount)} is not a model contract mount`)
					end
				end
				t.expect(problems).toEqual({})
			end)

			t.it("fit at least one designable class with every extra", function()
				local problems: { string } = {}
				for _, extraId in sortedKeys(kit.extras) do
					local extra = Customization.getExtra(extraId)
					local fits = false
					if extra ~= nil then
						for _, classId in extra.classes do
							if kit.classes[classId] ~= nil then
								fits = true
								break
							end
						end
					end
					if not fits then
						table.insert(problems, extraId)
					end
				end
				t.expect(problems).toEqual({})
			end)
		end)

		t.describe("numbers", function()
			t.it("clamp body and stance numbers to the ranges PLAN.md states", function()
				for name, range in PLAN_RANGES do
					t.expect({ name = name, min = kit.ranges[name].min, max = kit.ranges[name].max }).toEqual({
						name = name,
						min = range.min,
						max = range.max,
					})
				end
			end)

			t.it("give stance the same ride height range as the Wrap & Tint shop", function()
				t.expect(kit.ranges.rideHeight.min).toBe(Customization.rideHeight.min)
				t.expect(kit.ranges.rideHeight.max).toBe(Customization.rideHeight.max)
			end)

			t.it("map every body and stance number to a proportion", function()
				local missing: { string } = {}
				for _, field in BODY_FIELDS do
					if type(kit.proportions[field]) ~= "table" then
						table.insert(missing, field)
					end
				end
				for _, field in STANCE_FIELDS do
					if type(kit.proportions[field]) ~= "table" then
						table.insert(missing, field)
					end
				end
				t.expect(missing).toEqual({})
			end)

			t.it("scale sizes by sane, positive factors", function()
				local p = kit.proportions
				local problems: { string } = {}
				for _, field in sortedKeys(p) do
					local range = p[field]
					if type(range.min) ~= "number" or type(range.max) ~= "number" or range.min > range.max then
						table.insert(problems, `{field}: min {tostring(range.min)} max {tostring(range.max)}`)
					end
				end
				for _, field in SCALE_FIELDS do
					if not isPositive(p[field].min) then
						table.insert(problems, `{field}: a scale factor must stay above 0`)
					end
				end
				if p.noseSlope.min < 0 or p.noseSlope.max > 1 then
					table.insert(problems, "noseSlope: must stay within 0..1")
				end
				if not (p.rideHeight.min < 0 and p.rideHeight.max > 0) then
					table.insert(problems, "rideHeight: stance must lower below and raise above the template")
				end
				t.expect(problems).toEqual({})
			end)

			-- Phase 1 bump check (Config/DevTrack.bumps): the humps stay under the lowest ride height so the chassis
			-- box clears one even between the axles. Every design must pass it, so the lowest stance must too.
			t.it("keep every template's lowest stance clear of the dev track's humps", function()
				local lowest = kit.proportions.rideHeight.min
				local problems: { string } = {}
				for _, templateId in sortedKeys(kit.templates) do
					local rideHeight = kit.templates[templateId].geometry.rideHeight + lowest
					if rideHeight <= DevTrack.bumps.height then
						table.insert(
							problems,
							`{templateId}: {rideHeight} studs at the lowest stance, humps are {DevTrack.bumps.height}`
						)
					end
				end
				t.expect(problems).toEqual({})
			end)
		end)

		t.describe("limits", function()
			t.it("are all positive whole numbers", function()
				local problems: { string } = {}
				for _, field in LIMIT_FIELDS do
					local value = kit.limits[field]
					if not isWhole(value) or value <= 0 then
						table.insert(problems, `{field}: {tostring(value)}`)
					end
				end
				t.expect(problems).toEqual({})
			end)

			t.it("ask for fewer filtered characters than a prompt can hold", function()
				t.expect(kit.limits.minFilteredChars < kit.limits.promptChars).toBe(true)
				t.expect(kit.limits.minFilteredChars < kit.limits.modPromptChars).toBe(true)
			end)

			t.it("fit a full prompt of the widest characters through DesignCar and ModCar", function()
				local remotes = Net.declared()
				local prompt = string.rep(WIDEST_CHARACTER, kit.limits.promptChars)
				local longestClass = longest(sortedKeys(kit.classes))
				t.expect(remotes.DesignCar.validate({ prompt = prompt })).toBe(true)
				t.expect(remotes.DesignCar.validate({ prompt = prompt, classId = longestClass })).toBe(true)
				local modPrompt = string.rep(WIDEST_CHARACTER, kit.limits.modPromptChars)
				local uid = HttpService:GenerateGUID(false)
				t.expect(remotes.ModCar.validate({ uid = uid, prompt = modPrompt })).toBe(true)
			end)

			t.it("allow no more extras than the Wrap & Tint shop puts on a car", function()
				t.expect(kit.limits.maxExtras <= Customization.maxExtras).toBe(true)
			end)

			t.it(`keep a saved spec within PLAN.md's {PLAN_MAX_SPEC_BYTES} bytes`, function()
				t.expect(kit.limits.specBytes <= PLAN_MAX_SPEC_BYTES).toBe(true)
			end)

			t.it("fit the largest design within specBytes", function()
				local bytes = #HttpService:JSONEncode(largestDesign())
				t.expect(bytes <= kit.limits.specBytes).toBe(true)
			end)

			t.it("fit the largest mod within specBytes", function()
				local bytes = #HttpService:JSONEncode(largestMod())
				t.expect(bytes <= kit.limits.specBytes).toBe(true)
			end)
		end)

		t.describe("personalities", function()
			t.it("are exactly PLAN.md's four", function()
				t.expect(sortedKeys(kit.personalities)).toEqual(PLAN_PERSONALITIES)
			end)

			t.it("place every stat inside the band (0..1)", function()
				local problems: { string } = {}
				for _, personality in sortedKeys(kit.personalities) do
					for _, field in PERSONALITY_FIELDS do
						local value = kit.personalities[personality][field]
						if type(value) ~= "number" or value ~= value or value < 0 or value > 1 then
							table.insert(problems, `{personality}.{field}: {tostring(value)}`)
						end
					end
				end
				t.expect(problems).toEqual({})
			end)

			t.it("scale by a band ceiling below 1, so a design never matches the band's best", function()
				local ceiling = kit.bandCeiling
				t.expect(type(ceiling) == "number" and ceiling > 0 and ceiling < 1).toBe(true)
			end)
		end)

		t.describe("mod rules", function()
			t.it("spell 'keep' as a word no id uses", function()
				local keep = kit.mod.keep
				t.expect(type(keep) == "string" and #keep > 0).toBe(true)
				t.expect(table.find(kitIds(), keep)).toBe(nil)
			end)

			t.it("let kit mods touch only the design blocks", function()
				local problems: { string } = {}
				for _, path in kit.mod.kitAllowed do
					if table.find(MOD_BLOCKS, path) == nil then
						table.insert(problems, path)
					end
				end
				t.expect(problems).toEqual({})
			end)

			-- PLAN.md: on catalog cars a mod is limited to paint, finish, stripes, wheels, stance and mount extras.
			t.it("let catalog mods touch only part of what kit mods may, and never the body", function()
				local problems: { string } = {}
				for _, path in kit.mod.catalogAllowed do
					local block = string.match(path, "^[^%.]+") or path
					if table.find(kit.mod.kitAllowed, block) == nil then
						table.insert(problems, `{path}: kit mods may not touch {block}`)
					end
					if block == "body" then
						table.insert(problems, `{path}: catalog mods must keep the body`)
					end
					if block == "parts" and path ~= "parts.wheels" then
						table.insert(problems, `{path}: catalog mods may swap only the wheels`)
					end
				end
				t.expect(problems).toEqual({})
			end)
		end)

		t.describe("ids and names", function()
			t.it("are plain snake_case ids", function()
				local bad: { string } = {}
				for _, id in kitIds() do
					if type(id) ~= "string" or string.match(id, ID_PATTERN) == nil then
						table.insert(bad, tostring(id))
					end
				end
				t.expect(bad).toEqual({})
			end)

			-- Prove the name check fires (it must catch a name inside snake_case and camelCase ids and plain text)
			-- before trusting it on the kit.
			t.it("catch a real name inside an id or text", function()
				local name = rot13(BANNED_ROT13[2])
				local capitalized = string.upper(string.sub(name, 1, 1)) .. string.sub(name, 2)
				t.expect(hasBannedName(`fast_{name}_wing`)).toBe(true)
				t.expect(hasBannedName(`fast{capitalized}Wing`)).toBe(true)
				t.expect(hasBannedName(`A {capitalized}-style hatch`)).toBe(true)
				t.expect(hasBannedName(`{name}ish`)).toBe(false) -- whole words only, like scripts/check.ps1
			end)

			t.it("have no real carmaker or model name in any id or text", function()
				local strings: { string } = {}
				kitStrings(kit, strings)
				local hits: { string } = {}
				for _, text in strings do
					if hasBannedName(text) then
						table.insert(hits, text)
					end
				end
				t.expect(hits).toEqual({})
			end)
		end)
	end)
end
