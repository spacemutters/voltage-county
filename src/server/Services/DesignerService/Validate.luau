--!strict
-- Re-validates everything the AI Car Designer's backend sends before the game uses it (CLAUDE.md hard rule 11: AI
-- output is untrusted; docs/phase-11-contracts.md "Server"). Read by Services/DesignerService (every reply),
-- Services/VehicleService (saved specs and the plain look of a hidden design) and the specs.
--
--   Validate.design(raw, kit)          -> (spec?, reasons)  a design spec (PLAN.md "Design spec")
--   Validate.mod(raw, kit, kind)       -> (modSpec?, reasons)  a mod spec (PLAN.md "Mod spec"), kind "kit"|"catalog"
--   Validate.forClass(spec, classId, kit)   the spec moved to another designable class (template and energy fixed)
--   Validate.plain(spec, kit)          the plain look of a hidden design: same class, template, energy and
--                                      personality (so the same stats), base parts, neutral paint, generic name
--   Validate.keepMod(kit) / mergeMods(old, new, kit) / withMods(spec, mods, kit) / isEmptyMod(mod, kit)
--   Validate.statsInBand(stats, classId)    built stats inside the class band (Config/Classes)
--   Validate.prompt(raw, limit) / visibleChars(text) / clientSpec(spec)
--
-- The rules: every enum is checked against the kit (an unknown class, template, part, finish, stripe, extra or
-- personality rejects the spec), every number must be a finite number and is clamped to the kit's range, every
-- string must be valid UTF-8, loses control characters and runs of spaces, and is cut to the kit's limit, and
-- unknown fields are dropped (the result is built from scratch, never copied). A design whose JSON is larger than
-- kit.limits.specBytes is rejected. A spec carrying a non-empty `refusal` is never a spec.
--
-- Mod specs: every field may be the kit's "keep" word. A number field is either a number, "keep", or
-- { change = boolean, value = number }; a block with `change = false` keeps all its numbers. The result is always
-- canonical: strings are an id or "keep", numbers are { change, value } (value clamped; 0 pulled into range when
-- kept), extras are "keep" or a non-empty list of kit extra ids (each once, one per mount point, at most
-- kit.limits.maxExtras). An empty extras list is "keep", as the backend means it ("mount nothing new"), so a mod
-- that doesn't mention extras never takes off the ones an earlier mod put on. What a mod may touch comes from
-- kit.mod: on a catalog car only paint, stance, the wheels and extras (anything else is turned into "keep"); on
-- kit-built and designed cars everything but the body template, which always stays "keep" because ModBuilder
-- never touches the Chassis (so the seats and chassis box a template sets can't change). accessoryPrompt is
-- always "none": nothing builds a generated accessory yet, so one must never count as a change the player pays for.
--
-- Pure: HttpService is used only for JSONEncode (to measure a spec), so specs run it in Edit mode.

local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Classes = require(ReplicatedStorage.Shared.Config.Classes)
local Designer = require(ReplicatedStorage.Shared.Config.Designer)

export type Body = {
	template: string,
	length: number,
	height: number,
	roofline: number,
	noseSlope: number,
	flare: number,
}
export type Parts = { frontBumper: string, rearBumper: string, spoiler: string, lights: string, wheels: string }
export type Paint = { primary: string, secondary: string, finish: string, stripe: string }
export type Stance = { rideHeight: number, wheelSize: number }

export type Spec = {
	name: string,
	tagline: string,
	class: string,
	energy: string,
	personality: string,
	meshPrompt: string,
	body: Body,
	parts: Parts,
	paint: Paint,
	stance: Stance,
}

-- A mod's number field: `change = false` keeps the car's value.
export type Change = { change: boolean, value: number }

export type ModSpec = {
	summary: string,
	body: {
		template: string,
		length: Change,
		height: Change,
		roofline: Change,
		noseSlope: Change,
		flare: Change,
	},
	parts: Parts, -- each an id or "keep"
	paint: Paint, -- each a value or "keep"
	stance: { rideHeight: Change, wheelSize: Change },
	extras: { string } | string, -- a non-empty list of kit extra ids, or "keep"
	accessoryPrompt: string, -- always "none" (generated accessories aren't built yet)
}

-- What SpecBuilder.stats returns (the fields a Config/Vehicles trim has).
export type Stats = {
	topSpeedMph: number,
	zeroToSixtySec: number,
	handling: number,
	energyMinutes: number,
	seats: number,
	drive: string,
}

export type Kind = "kit" | "catalog"

local Validate = {}

local BODY_NUMBERS = { "length", "height", "roofline", "noseSlope", "flare" }
local PART_FIELDS = { "frontBumper", "rearBumper", "spoiler", "lights", "wheels" }
local PAINT_COLORS = { "primary", "secondary" }
local STANCE_NUMBERS = { "rideHeight", "wheelSize" }
local MIDDLE = 0.5 -- the neutral value of a 0..1 body number
local NO_ACCESSORY = "none"
local HIDDEN_CHAR = "#" -- what TextService puts in place of filtered characters

-- Helpers ---------------------------------------------------------------------------------------------------

local function isFiniteNumber(value: any): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function clampTo(value: number, range: { min: number, max: number }): number
	return math.clamp(value, range.min, range.max)
end

local function contains(list: any, value: any): boolean
	return type(list) == "table" and table.find(list, value) ~= nil
end

-- Text with control characters turned into spaces, runs of whitespace collapsed and the ends trimmed, cut to
-- `limit` characters. nil when the value isn't a string or isn't valid UTF-8.
local function cleanText(value: any, limit: number): string?
	if type(value) ~= "string" or utf8.len(value) == nil then
		return nil
	end
	local text = string.gsub(value, "[%c]", " ")
	text = string.gsub(text, "%s+", " ")
	text = string.match(text, "^%s*(.-)%s*$") or ""
	local count = utf8.len(text) or 0
	if count > limit then
		local cut = utf8.offset(text, limit + 1)
		if cut ~= nil then
			text = string.sub(text, 1, cut - 1)
		end
		text = string.match(text, "^(.-)%s*$") or ""
	end
	return text
end

local function hexColor(value: any): string?
	if type(value) ~= "string" or string.match(value, "^#%x%x%x%x%x%x$") == nil then
		return nil
	end
	return string.upper(value)
end

local function hasRefusal(raw: { [string]: any }): boolean
	local refusal = raw.refusal
	return type(refusal) == "string" and string.match(refusal, "%S") ~= nil
end

local function jsonBytes(value: any): number?
	local ok, json = pcall(HttpService.JSONEncode, HttpService, value)
	return if ok then #json else nil
end

local function block(raw: { [string]: any }, name: string): { [string]: any }?
	local value = raw[name]
	return if type(value) == "table" then value else nil
end

-- Public helpers --------------------------------------------------------------------------------------------

-- How many characters of filtered text survived: everything but spaces and the filter's "#" marks.
function Validate.visibleChars(text: string): number
	if type(text) ~= "string" or utf8.len(text) == nil then
		return 0
	end
	local count = 0
	for _, code in utf8.codes(text) do
		local char = utf8.char(code)
		if char ~= HIDDEN_CHAR and string.match(char, "^%s$") == nil then
			count += 1
		end
	end
	return count
end

-- A player's prompt as it will be filtered and sent: cleaned like any text, never cut. Returns the text, or nil
-- and why ("empty", "tooLong" or "badText").
function Validate.prompt(raw: any, limit: number): (string?, string?)
	if type(raw) ~= "string" or utf8.len(raw) == nil then
		return nil, "badText"
	end
	local text = cleanText(raw, math.huge) :: string
	if text == "" then
		return nil, "empty"
	end
	if (utf8.len(text) or 0) > limit then
		return nil, "tooLong"
	end
	return text, nil
end

-- True when every built stat sits inside the class band (Config/Classes). Unknown classes and missing or broken
-- numbers are never in band.
function Validate.statsInBand(stats: any, classId: string): boolean
	local class = Classes[classId]
	if class == nil or type(stats) ~= "table" then
		return false
	end
	local function inside(value: any, range: Classes.Range): boolean
		return isFiniteNumber(value) and value >= range.min and value <= range.max
	end
	return inside(stats.topSpeedMph, class.topSpeedMph)
		and inside(stats.zeroToSixtySec, class.zeroToSixtySec)
		and inside(stats.handling, class.handling)
		and inside(stats.energyMinutes, class.energyMinutes)
		and inside(stats.seats, class.seats)
end

-- A designable class the kit knows (hypercar, heavy and service are never in the kit).
local function designableClass(classId: any, kit: any): boolean
	return type(classId) == "string"
		and type(kit.classes[classId]) == "table"
		and Classes[classId] ~= nil
		and Classes[classId].designable
end

-- Design specs ----------------------------------------------------------------------------------------------

function Validate.design(raw: any, kit: any): (Spec?, { string })
	local reasons: { string } = {}
	local function problem(message: string)
		table.insert(reasons, message)
	end
	if type(raw) ~= "table" then
		return nil, { "spec: not an object" }
	end
	if hasRefusal(raw) then
		return nil, { "refusal" }
	end
	local limits = kit.limits

	local name = cleanText(raw.name, limits.name)
	if name == nil or name == "" then
		problem("name: missing or not text")
	end
	local tagline = cleanText(raw.tagline, limits.tagline)
	if tagline == nil then
		problem("tagline: missing or not text")
	end
	local meshPrompt = cleanText(raw.meshPrompt, limits.meshPrompt)
	if meshPrompt == nil then
		problem("meshPrompt: missing or not text")
	end

	local classId = raw.class
	local classKit: any = nil
	if designableClass(classId, kit) then
		classKit = kit.classes[classId]
	else
		problem(`class: "{tostring(classId)}" is not a designable class`)
	end
	if classKit ~= nil and not contains(classKit.energy, raw.energy) then
		problem(`energy: "{tostring(raw.energy)}" is not allowed for {classId}`)
	end
	if type(raw.personality) ~= "string" or kit.personalities[raw.personality] == nil then
		problem(`personality: "{tostring(raw.personality)}" is unknown`)
	end

	local body: Body = {
		template = "",
		length = MIDDLE,
		height = MIDDLE,
		roofline = MIDDLE,
		noseSlope = MIDDLE,
		flare = MIDDLE,
	}
	local rawBody = block(raw, "body")
	if rawBody == nil then
		problem("body: missing")
	else
		local template = rawBody.template
		if type(template) ~= "string" or kit.templates[template] == nil then
			problem(`body.template: "{tostring(template)}" is unknown`)
		elseif classKit ~= nil and not contains(classKit.templates, template) then
			problem(`body.template: "{template}" is not a {classId} template`)
		else
			body.template = template
		end
		for _, field in BODY_NUMBERS do
			local value = rawBody[field]
			if isFiniteNumber(value) then
				(body :: any)[field] = clampTo(value, kit.ranges.body)
			else
				problem(`body.{field}: not a number`)
			end
		end
	end

	local parts = {} :: { [string]: string }
	local rawParts = block(raw, "parts")
	if rawParts == nil then
		problem("parts: missing")
	else
		for _, field in PART_FIELDS do
			local value = rawParts[field]
			if contains(kit.parts[field], value) then
				parts[field] = value
			else
				problem(`parts.{field}: "{tostring(value)}" is unknown`)
			end
		end
	end

	local paint = {} :: { [string]: string }
	local rawPaint = block(raw, "paint")
	if rawPaint == nil then
		problem("paint: missing")
	else
		for _, field in PAINT_COLORS do
			local color = hexColor(rawPaint[field])
			if color == nil then
				problem(`paint.{field}: not a #RRGGBB color`)
			else
				paint[field] = color
			end
		end
		if contains(kit.finishes, rawPaint.finish) then
			paint.finish = rawPaint.finish
		else
			problem(`paint.finish: "{tostring(rawPaint.finish)}" is unknown`)
		end
		if contains(kit.stripes, rawPaint.stripe) then
			paint.stripe = rawPaint.stripe
		else
			problem(`paint.stripe: "{tostring(rawPaint.stripe)}" is unknown`)
		end
	end

	local stance: Stance = { rideHeight = 0, wheelSize = MIDDLE }
	local rawStance = block(raw, "stance")
	if rawStance == nil then
		problem("stance: missing")
	else
		if isFiniteNumber(rawStance.rideHeight) then
			stance.rideHeight = clampTo(rawStance.rideHeight, kit.ranges.rideHeight)
		else
			problem("stance.rideHeight: not a number")
		end
		if isFiniteNumber(rawStance.wheelSize) then
			stance.wheelSize = clampTo(rawStance.wheelSize, kit.ranges.wheelSize)
		else
			problem("stance.wheelSize: not a number")
		end
	end

	if #reasons > 0 then
		return nil, reasons
	end
	local spec: Spec = {
		name = name :: string,
		tagline = tagline :: string,
		class = classId,
		energy = raw.energy,
		personality = raw.personality,
		meshPrompt = meshPrompt :: string,
		body = body,
		parts = parts :: any,
		paint = paint :: any,
		stance = stance,
	}
	local size = jsonBytes(spec)
	if size == nil or size > limits.specBytes then
		return nil, { `spec: larger than {limits.specBytes} bytes` }
	end
	return spec, reasons
end

-- A deep copy of a validated spec (specs are plain tables of strings and numbers).
local function copySpec(spec: Spec): Spec
	return {
		name = spec.name,
		tagline = spec.tagline,
		class = spec.class,
		energy = spec.energy,
		personality = spec.personality,
		meshPrompt = spec.meshPrompt,
		body = table.clone(spec.body),
		parts = table.clone(spec.parts),
		paint = table.clone(spec.paint),
		stance = table.clone(spec.stance),
	}
end

-- The spec moved into `classId` (a designable class in the kit): the body template and energy are kept when the
-- class allows them, else the class's first. nil when the class isn't designable.
function Validate.forClass(spec: Spec, classId: string, kit: any): Spec?
	if not designableClass(classId, kit) then
		return nil
	end
	local classKit = kit.classes[classId]
	local moved = copySpec(spec)
	moved.class = classId
	if not contains(classKit.templates, moved.body.template) then
		moved.body.template = classKit.templates[1]
	end
	if not contains(classKit.energy, moved.energy) then
		moved.energy = classKit.energy[1]
	end
	return moved
end

-- What a hidden design looks like: its class, template, energy and personality (so the same stats and the same
-- chassis), the middle of every body range, each part's first (base) option, the neutral Config/Designer
-- plainLook paint, no generation prompt and a generic name ("Custom <class display name>").
function Validate.plain(spec: Spec, kit: any): Spec
	local class = Classes[spec.class]
	local className = if class ~= nil then class.displayName else spec.class
	local look = Designer.plainLook
	local parts = {} :: { [string]: string }
	for _, field in PART_FIELDS do
		parts[field] = kit.parts[field][1]
	end
	return {
		name = string.format(Designer.messages.hiddenName, className),
		tagline = "",
		class = spec.class,
		energy = spec.energy,
		personality = spec.personality,
		meshPrompt = "",
		body = {
			template = spec.body.template,
			length = MIDDLE,
			height = MIDDLE,
			roofline = MIDDLE,
			noseSlope = MIDDLE,
			flare = MIDDLE,
		},
		parts = parts :: any,
		paint = {
			primary = look.primary,
			secondary = look.secondary,
			finish = look.finish,
			stripe = look.stripe,
		},
		stance = { rideHeight = 0, wheelSize = MIDDLE },
	}
end

-- The spec as the client may see it: everything but the generation prompt (AI text nobody needs to read).
function Validate.clientSpec(spec: Spec): { [string]: any }
	local copy: { [string]: any } = copySpec(spec) :: any
	copy.meshPrompt = nil
	return copy
end

-- Mod specs -------------------------------------------------------------------------------------------------

local function kept(range: { min: number, max: number }): Change
	return { change = false, value = clampTo(0, range) }
end

-- True when a mod of `kind` may touch `section` (and, for parts, `field`), per kit.mod.
local function allowed(kit: any, kind: Kind, section: string, field: string?): boolean
	local list = if kind == "catalog" then kit.mod.catalogAllowed else kit.mod.kitAllowed
	if contains(list, section) then
		return true
	end
	return field ~= nil and contains(list, `{section}.{field}`)
end

-- A mod's number field as { change, value }. `blockChange` is the block's own `change` flag, if it has one.
-- Returns nil for a value that is neither a number, "keep", nor a well-formed { change, value }.
local function parseChange(value: any, blockChange: any, range: { min: number, max: number }, keep: string): Change?
	if value == nil or value == keep or blockChange == false then
		return kept(range)
	end
	if isFiniteNumber(value) then
		return { change = true, value = clampTo(value, range) }
	end
	if type(value) == "table" then
		if value.change == false then
			return kept(range)
		end
		if value.change == true and isFiniteNumber(value.value) then
			return { change = true, value = clampTo(value.value, range) }
		end
	end
	return nil
end

-- A mod that changes nothing: every field "keep" (and no generated accessory).
function Validate.keepMod(kit: any): ModSpec
	local keep = kit.mod.keep
	local bodyRange = kit.ranges.body
	return {
		summary = "",
		body = {
			template = keep,
			length = kept(bodyRange),
			height = kept(bodyRange),
			roofline = kept(bodyRange),
			noseSlope = kept(bodyRange),
			flare = kept(bodyRange),
		},
		parts = {
			frontBumper = keep,
			rearBumper = keep,
			spoiler = keep,
			lights = keep,
			wheels = keep,
		},
		paint = { primary = keep, secondary = keep, finish = keep, stripe = keep },
		stance = { rideHeight = kept(kit.ranges.rideHeight), wheelSize = kept(kit.ranges.wheelSize) },
		extras = keep,
		accessoryPrompt = NO_ACCESSORY,
	}
end

-- Extras as a list of kit ids: each once, the first per mount point, at most kit.limits.maxExtras. nil (with a
-- reason) when an id isn't in the kit.
local function parseExtras(value: any, kit: any): ({ string }?, string?)
	if type(value) ~= "table" then
		return nil, "extras: not a list"
	end
	local list: { string } = {}
	local mounts: { [string]: boolean } = {}
	for _, item in value do
		local id = if type(item) == "table" then item.id else item
		local extra = if type(id) == "string" then kit.extras[id] else nil
		if extra == nil then
			return nil, `extras: "{tostring(id)}" is unknown`
		end
		if not mounts[extra.mount] and #list < kit.limits.maxExtras then
			mounts[extra.mount] = true
			table.insert(list, id)
		end
	end
	return list, nil
end

function Validate.mod(raw: any, kit: any, kind: Kind): (ModSpec?, { string })
	local reasons: { string } = {}
	local function problem(message: string)
		table.insert(reasons, message)
	end
	if type(raw) ~= "table" then
		return nil, { "mod: not an object" }
	end
	if hasRefusal(raw) then
		return nil, { "refusal" }
	end
	if kind ~= "kit" and kind ~= "catalog" then
		return nil, { `mod: unknown kind "{tostring(kind)}"` }
	end
	local keep = kit.mod.keep
	local mod = Validate.keepMod(kit)

	local summary = cleanText(raw.summary, kit.limits.summary)
	if summary == nil then
		problem("summary: missing or not text")
	else
		mod.summary = summary
	end

	-- body: the template always stays (see the header); numbers only where the kind allows the body.
	local rawBody = raw.body
	if type(rawBody) == "table" and allowed(kit, kind, "body") then
		for _, field in BODY_NUMBERS do
			local change = parseChange(rawBody[field], rawBody.change, kit.ranges.body, keep)
			if change == nil then
				problem(`body.{field}: not a number, "keep" or a change`)
			else
				(mod.body :: any)[field] = change
			end
		end
	elseif rawBody ~= nil and rawBody ~= keep and type(rawBody) ~= "table" then
		problem("body: not an object")
	end

	local rawParts = raw.parts
	if type(rawParts) == "table" then
		for _, field in PART_FIELDS do
			local value = rawParts[field]
			if value == nil or value == keep or not allowed(kit, kind, "parts", field) then
				continue
			end
			if contains(kit.parts[field], value) then
				(mod.parts :: any)[field] = value
			else
				problem(`parts.{field}: "{tostring(value)}" is unknown`)
			end
		end
	elseif rawParts ~= nil and rawParts ~= keep then
		problem("parts: not an object")
	end

	local rawPaint = raw.paint
	if type(rawPaint) == "table" and allowed(kit, kind, "paint") then
		for _, field in PAINT_COLORS do
			local value = rawPaint[field]
			if value ~= nil and value ~= keep then
				local color = hexColor(value)
				if color == nil then
					problem(`paint.{field}: not a #RRGGBB color or "keep"`)
				else
					(mod.paint :: any)[field] = color
				end
			end
		end
		local finish = rawPaint.finish
		if finish ~= nil and finish ~= keep then
			if contains(kit.finishes, finish) then
				mod.paint.finish = finish
			else
				problem(`paint.finish: "{tostring(finish)}" is unknown`)
			end
		end
		local stripe = rawPaint.stripe
		if stripe ~= nil and stripe ~= keep then
			if contains(kit.stripes, stripe) then
				mod.paint.stripe = stripe
			else
				problem(`paint.stripe: "{tostring(stripe)}" is unknown`)
			end
		end
	elseif rawPaint ~= nil and rawPaint ~= keep and type(rawPaint) ~= "table" then
		problem("paint: not an object")
	end

	local rawStance = raw.stance
	if type(rawStance) == "table" and allowed(kit, kind, "stance") then
		for _, field in STANCE_NUMBERS do
			local change = parseChange(rawStance[field], rawStance.change, kit.ranges[field], keep)
			if change == nil then
				problem(`stance.{field}: not a number, "keep" or a change`)
			else
				(mod.stance :: any)[field] = change
			end
		end
	elseif rawStance ~= nil and rawStance ~= keep and type(rawStance) ~= "table" then
		problem("stance: not an object")
	end

	local rawExtras = raw.extras
	if rawExtras ~= nil and rawExtras ~= keep and allowed(kit, kind, "extras") then
		local extras, why = parseExtras(rawExtras, kit)
		if extras == nil then
			problem(why or "extras: invalid")
		elseif #extras > 0 then
			mod.extras = extras
		end -- an empty list mounts nothing new: "keep"
	end

	-- accessoryPrompt stays "none" whatever the reply says (see the header): it must still be text when sent.
	local accessory = raw.accessoryPrompt
	if accessory ~= nil and cleanText(accessory, kit.limits.accessoryPrompt) == nil then
		problem("accessoryPrompt: not text")
	end

	if #reasons > 0 then
		return nil, reasons
	end
	return mod, reasons
end

-- True when the mod changes nothing at all.
function Validate.isEmptyMod(mod: ModSpec, kit: any): boolean
	local keep = kit.mod.keep
	if mod.body.template ~= keep or mod.extras ~= keep or mod.accessoryPrompt ~= NO_ACCESSORY then
		return false
	end
	for _, field in BODY_NUMBERS do
		if (mod.body :: any)[field].change then
			return false
		end
	end
	for _, field in PART_FIELDS do
		if (mod.parts :: any)[field] ~= keep then
			return false
		end
	end
	for _, value in mod.paint :: any do
		if value ~= keep then
			return false
		end
	end
	for _, field in STANCE_NUMBERS do
		if (mod.stance :: any)[field].change then
			return false
		end
	end
	return true
end

local function copyMod(mod: ModSpec): ModSpec
	local body: any = { template = mod.body.template }
	for _, field in BODY_NUMBERS do
		body[field] = table.clone((mod.body :: any)[field])
	end
	return {
		summary = mod.summary,
		body = body,
		parts = table.clone(mod.parts),
		paint = table.clone(mod.paint),
		stance = {
			rideHeight = table.clone(mod.stance.rideHeight),
			wheelSize = table.clone(mod.stance.wheelSize),
		},
		extras = if type(mod.extras) == "table" then table.clone(mod.extras) else mod.extras,
		accessoryPrompt = mod.accessoryPrompt,
	}
end

-- A car's mods after a new one: everything the new mod changes replaces what was there, everything it keeps
-- stays as the older mods left it. `old` may be nil (the car's first mod) or a damaged save (re-validated as a
-- kit mod first; anything unusable counts as no mods). The summary and accessory are the new mod's.
function Validate.mergeMods(old: any, new: ModSpec, kit: any): ModSpec
	local keep = kit.mod.keep
	local base = Validate.keepMod(kit)
	if type(old) == "table" then
		local checked = Validate.mod(old, kit, "kit")
		if checked ~= nil then
			base = checked
		end
	end
	local merged = copyMod(base)
	for _, field in BODY_NUMBERS do
		local change = (new.body :: any)[field]
		if change.change then
			(merged.body :: any)[field] = table.clone(change)
		end
	end
	for _, field in PART_FIELDS do
		local value = (new.parts :: any)[field]
		if value ~= keep then
			(merged.parts :: any)[field] = value
		end
	end
	for field, value in new.paint :: any do
		if value ~= keep then
			(merged.paint :: any)[field] = value
		end
	end
	for _, field in STANCE_NUMBERS do
		local change = (new.stance :: any)[field]
		if change.change then
			(merged.stance :: any)[field] = table.clone(change)
		end
	end
	if new.extras ~= keep then
		merged.extras = if type(new.extras) == "table" then table.clone(new.extras) else new.extras
	end
	merged.summary = new.summary
	merged.accessoryPrompt = new.accessoryPrompt
	return merged
end

-- A design spec with a car's mods applied (the body template never changes). For the backend's view of a
-- designed car's current look; extras aren't part of a design spec.
function Validate.withMods(spec: Spec, mods: ModSpec?, kit: any): Spec
	local result = copySpec(spec)
	if mods == nil then
		return result
	end
	local keep = kit.mod.keep
	for _, field in BODY_NUMBERS do
		local change = (mods.body :: any)[field]
		if change.change then
			(result.body :: any)[field] = change.value
		end
	end
	for _, field in PART_FIELDS do
		local value = (mods.parts :: any)[field]
		if value ~= keep then
			(result.parts :: any)[field] = value
		end
	end
	for field, value in mods.paint :: any do
		if value ~= keep then
			(result.paint :: any)[field] = value
		end
	end
	for _, field in STANCE_NUMBERS do
		local change = (mods.stance :: any)[field]
		if change.change then
			(result.stance :: any)[field] = change.value
		end
	end
	return result
end

return Validate
