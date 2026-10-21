--!strict
-- Player designs (PLAN.md Phase 11 "Design spec"; docs/phase-11-contracts.md "Kit" and "Designs in the catalog"):
-- builds a car from a design spec and Config/DesignKit.json, and works out its stats and its catalog entry. Read by
-- Services/VehicleService (spawning a design, publishing its catalog entry), Services/DesignerService (stats),
-- Vehicle/ModBuilder (mods on designed cars) and the client's Design Studio (local previews).
--
--   SpecBuilder.build(spec, kit, designUid?)  a contract model (<= BodyKit.MAX_PARTS parts, room kept for its look's
--                                             wheel faces and plates), checked; deterministic.
--                                             With a designUid it is "custom_<uid>" with VehicleId "custom:<uid>",
--                                             Trim "design" and DesignUid; without, "custom" / VehicleId "custom".
--   SpecBuilder.stats(spec, kit)              { topSpeedMph, zeroToSixtySec, handling, energyMinutes, seats, drive }
--   SpecBuilder.geometry(spec, kit)           the body geometry (a Config/Vehicles Geometry)
--   SpecBuilder.vehicleFor(spec, kit, uid)    the synthetic catalog entry "custom:<uid>" with one trim "design"
--   SpecBuilder.lookFields(spec, kit)         { finish, wheels }: the Wrap & Tint fields a new design's car starts with
--   SpecBuilder.normalize(spec, kit)          the complete spec the builder uses (see below)
--   SpecBuilder.check(model, spec, kit, uid?) the model contract check against the design's own entry
--   SpecBuilder.specOf(model)                 the spec a model was built from (its DesignSpec attribute), or nil
--   SpecBuilder.assemble(spec, kit, options?) build without the check, at a given geometry and seat count
--                                             (Vehicle/ModBuilder rebuilds a modded body around a car's own wheels)
--
-- A spec is untrusted wherever it comes from, so everything here works from normalize(): numbers clamped to
-- kit.ranges (missing or not a number: the middle of the range), every id checked against the kit (unknown: the
-- class's or the kit's first), colors "#RRGGBB" (else Config/Designer.plainLook), name and tagline cut to the kit's
-- limits (they must already be filtered: a published entry's displayName is the design's name). Stats come only
-- from the class band (Config/Classes) and the personality (kit.personalities x kit.bandCeiling); no other field
-- can move them, and they stay at or under the band's ceiling.
--
-- How a spec becomes a car: kit.templates[template] gives the generic body style (Vehicle/BodyKit), the seat count
-- (kept inside the class's seat band) and the base geometry; kit.proportions scale it (length: length and
-- wheelbase; height: height and chassis; flare: width and track; roofline: the height over the wheel arches;
-- stance: wheel radius, and ride height in studs from -1 = min to 0 = the template's to 1 = max); the parts pick
-- the bumper, lamp and spoiler variants; the primary color goes on the body and the secondary on the roof and the
-- stripes, in the finish's material (Config/Customization finishes); the wheels get the style's rim colors (the
-- full wheel style goes on with the car's Wrap & Tint look, Vehicle/Appearance, from lookFields). A body is never
-- lower over its wheel arches than BodyKit.MIN_ROOM_OVER_ARCHES, so every spec builds.

local HttpService = game:GetService("HttpService")

local Shared = script.Parent.Parent
local Appearance = require(script.Parent.Appearance)
local BodyKit = require(script.Parent.BodyKit)
local Classes = require(Shared.Config.Classes)
local Customization = require(Shared.Config.Customization)
local Designer = require(Shared.Config.Designer)
local Garage = require(Shared.Config.Garage)
local Vehicles = require(Shared.Config.Vehicles)

export type Range = { min: number, max: number }

-- The parts of Config/DesignKit.json this module reads (docs/phase-11-contracts.md "Kit").
export type Kit = {
	kitVersion: number,
	limits: { [string]: number },
	ranges: { body: Range, rideHeight: Range, wheelSize: Range },
	proportions: { [string]: Range },
	classes: { [string]: { templates: { string }, energy: { string } } },
	surpriseClasses: { string },
	templates: { [string]: { style: string, seats: number, geometry: Vehicles.Geometry } },
	parts: { [string]: { string } },
	extras: { [string]: { mount: string } },
	finishes: { string },
	stripes: { string },
	personalities: { [string]: { acceleration: number, topSpeed: number, handling: number, range: number } },
	bandCeiling: number,
	mod: { keep: string, catalogAllowed: { string }, kitAllowed: { string } },
}

-- A normalized design spec: every field present and valid for the kit.
export type Spec = {
	name: string?,
	tagline: string?,
	class: string,
	energy: string,
	personality: string,
	body: { template: string, length: number, height: number, roofline: number, noseSlope: number, flare: number },
	parts: { frontBumper: string, rearBumper: string, spoiler: string, lights: string, wheels: string },
	paint: { primary: string, secondary: string, finish: string, stripe: string },
	stance: { rideHeight: number, wheelSize: number },
}

export type Drive = "FWD" | "RWD" | "AWD"

export type Stats = {
	topSpeedMph: number,
	zeroToSixtySec: number,
	handling: number,
	energyMinutes: number,
	seats: number,
	drive: Drive,
}

export type AssembleOptions = {
	geometry: Vehicles.Geometry?, -- build at this geometry instead of the spec's
	seats: number?, -- this many seats instead of the template's
}

local SpecBuilder = {}

-- Model attributes (read by Vehicle/ModBuilder and VehicleService).
local SPEC_ATTRIBUTE = "DesignSpec" -- JSON of the normalized spec the body was built from
local UID_ATTRIBUTE = "DesignUid"
local KIT_ATTRIBUTE = "KitVersion"

local BODY_NUMBERS = { "length", "height", "roofline", "noseSlope", "flare" }
local PART_FIELDS = { "frontBumper", "rearBumper", "spoiler", "lights", "wheels" }

local GEOMETRY_STEP = 1e-3 -- geometry is kept to thousandths of a stud (it is published as JSON)
local MIN_RIDE_HEIGHT = 0.2 -- studs; never reached with the kit's ranges (a guard for the physics)
-- Stats are rounded the way the catalog writes them, then kept inside the band under its ceiling.
local STAT_STEPS = { topSpeedMph = 1, zeroToSixtySec = 0.1, handling = 0.01, energyMinutes = 1 }
-- A design's drive is its class's most common one in the catalog; ties go to the first in this order.
local DRIVES: { Drive } = { "FWD" :: Drive, "RWD" :: Drive, "AWD" :: Drive }
-- A design's trim isn't sold, handed out or a classic: Config/Vehicles' "limited" (a one-off) fits it.
local DESIGN_ACQUISITION: Vehicles.Acquisition = "limited"
-- The wheel face a design builds on its tires (the style's colors on the stock rim and spoke): the spoke is never
-- thinner than this share of the tire diameter.
local MIN_SPOKE_SHARE = 0.06

----------------------------------------------------------------------------------------------------------------
-- Normalizing
----------------------------------------------------------------------------------------------------------------

local function isFiniteNumber(value: any): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function sortedKeys(map: { [string]: any }): { string }
	local keys = {}
	for key in map do
		table.insert(keys, key)
	end
	table.sort(keys)
	return keys
end

-- `value` when it is one of `list`, else the list's first entry.
local function pick(value: any, list: { string }): string
	if type(value) == "string" and table.find(list, value) ~= nil then
		return value
	end
	return list[1]
end

-- A number clamped into `range`; anything else is the middle of the range.
local function amount(value: any, range: Range): number
	if isFiniteNumber(value) then
		return math.clamp(value, range.min, range.max)
	end
	return (range.min + range.max) / 2
end

local function hex(value: any, fallback: string): string
	if type(value) == "string" and string.match(value, "^#%x%x%x%x%x%x$") ~= nil then
		return string.upper(value)
	end
	return string.upper(fallback)
end

-- Text cut to `limit` characters (UTF-8 aware); nil for anything that isn't valid UTF-8 text.
local function shortText(value: any, limit: number): string?
	if type(value) ~= "string" or value == "" then
		return nil
	end
	local count = utf8.len(value)
	if count == nil then
		return nil
	end
	if count <= limit then
		return value
	end
	local cut = utf8.offset(value, limit + 1)
	return if cut ~= nil then string.sub(value, 1, cut - 1) else value
end

local function fallbackClass(kit: Kit): string
	for _, classId in kit.surpriseClasses do
		if kit.classes[classId] ~= nil then
			return classId
		end
	end
	return sortedKeys(kit.classes)[1]
end

local function section(raw: { [string]: any }, name: string): { [string]: any }
	local value = raw[name]
	return if type(value) == "table" then value else {}
end

-- The complete, valid spec for any input (see the header). Never errors.
function SpecBuilder.normalize(raw: any, kitData: any): Spec
	local kit: Kit = kitData
	local spec: { [string]: any } = if type(raw) == "table" then raw else {}
	local classId = if type(spec.class) == "string" and kit.classes[spec.class] ~= nil
		then spec.class
		else fallbackClass(kit)
	local class = kit.classes[classId]
	local personalities = sortedKeys(kit.personalities)
	local body, parts, paint, stance =
		section(spec, "body"), section(spec, "parts"), section(spec, "paint"), section(spec, "stance")
	local plain = Designer.plainLook

	local normalized: Spec = {
		name = shortText(spec.name, kit.limits.name),
		tagline = shortText(spec.tagline, kit.limits.tagline),
		class = classId,
		energy = pick(spec.energy, class.energy),
		personality = pick(spec.personality, personalities),
		body = {
			template = pick(body.template, class.templates),
			length = 0,
			height = 0,
			roofline = 0,
			noseSlope = 0,
			flare = 0,
		},
		parts = {
			frontBumper = "",
			rearBumper = "",
			spoiler = "",
			lights = "",
			wheels = "",
		},
		paint = {
			primary = hex(paint.primary, plain.primary),
			secondary = hex(paint.secondary, plain.secondary),
			finish = pick(paint.finish, kit.finishes),
			stripe = pick(paint.stripe, kit.stripes),
		},
		stance = {
			rideHeight = amount(stance.rideHeight, kit.ranges.rideHeight),
			wheelSize = amount(stance.wheelSize, kit.ranges.wheelSize),
		},
	}
	for _, field in BODY_NUMBERS do
		(normalized.body :: any)[field] = amount(body[field], kit.ranges.body)
	end
	for _, field in PART_FIELDS do
		(normalized.parts :: any)[field] = pick(parts[field], kit.parts[field])
	end
	return normalized
end

----------------------------------------------------------------------------------------------------------------
-- Geometry and stats
----------------------------------------------------------------------------------------------------------------

local function lerp(range: Range, t: number): number
	return range.min + (range.max - range.min) * t
end

local function toStep(value: number, step: number): number
	return math.round(value / step) * step
end

local function geometryOf(s: Spec, kit: Kit): Vehicles.Geometry
	local base = kit.templates[s.body.template].geometry
	local p = kit.proportions
	local lengthScale = lerp(p.length, s.body.length)
	local heightScale = lerp(p.height, s.body.height)
	local flareScale = lerp(p.flare, s.body.flare)
	local rooflineScale = lerp(p.roofline, s.body.roofline)
	local wheelScale = lerp(p.wheelSize, s.stance.wheelSize)
	local ride = s.stance.rideHeight
	local rideOffset = if ride >= 0 then ride * p.rideHeight.max else -ride * p.rideHeight.min

	local g: Vehicles.Geometry = {
		length = toStep(base.length * lengthScale, GEOMETRY_STEP),
		width = toStep(base.width * flareScale, GEOMETRY_STEP),
		height = 0,
		wheelbase = toStep(base.wheelbase * lengthScale, GEOMETRY_STEP),
		track = toStep(base.track * flareScale, GEOMETRY_STEP),
		wheelRadius = toStep(base.wheelRadius * wheelScale, GEOMETRY_STEP),
		wheelWidth = toStep(base.wheelWidth, GEOMETRY_STEP),
		rideHeight = toStep(math.max(MIN_RIDE_HEIGHT, base.rideHeight + rideOffset), GEOMETRY_STEP),
		chassisHeight = toStep(base.chassisHeight * heightScale, GEOMETRY_STEP),
	}
	-- The roofline scales the body over the wheel arches (greenhouse and shoulders together).
	local archTop = BodyKit.archTop(g)
	local tall = base.height * heightScale
	local height = archTop + (tall - archTop) * rooflineScale
	g.height =
		toStep(math.max(height, archTop + BodyKit.MIN_ROOM_OVER_ARCHES, g.rideHeight + g.chassisHeight), GEOMETRY_STEP)
	return g
end

function SpecBuilder.geometry(spec: any, kit: any): Vehicles.Geometry
	return geometryOf(SpecBuilder.normalize(spec, kit), kit)
end

-- The template's seats, kept inside the class's seat band (a two-seat body in a four-seat class gets four).
local function seatsOf(s: Spec, kit: Kit): number
	local band = Classes[s.class].seats
	return math.clamp(kit.templates[s.body.template].seats, band.min, band.max)
end

local drives: { [string]: Drive } = {}

-- The class's most common drive among the catalog's trims (cached).
local function driveOf(classId: string): Drive
	local cached: Drive? = drives[classId]
	if cached ~= nil then
		return cached
	end
	local counts: { [string]: number } = {}
	for _, drive in DRIVES do
		counts[drive] = 0
	end
	for _, vehicle in Vehicles do
		if vehicle.class == classId then
			for _, trim in vehicle.trims do
				counts[trim.drive] = (counts[trim.drive] or 0) + 1
			end
		end
	end
	local best: Drive = DRIVES[1]
	for index = 2, #DRIVES do
		local drive: Drive = DRIVES[index]
		if counts[drive] > counts[best] then
			best = drive
		end
	end
	drives[classId] = best
	return best
end

local function statsOf(s: Spec, kit: Kit): Stats
	local band = Classes[s.class]
	local personality = kit.personalities[s.personality]
	local ceiling = kit.bandCeiling
	-- Higher is better: `share` of the way up the band, scaled by the ceiling.
	local function up(range: Range, share: number, step: number): number
		local top = range.min + (range.max - range.min) * ceiling
		return math.clamp(toStep(range.min + (range.max - range.min) * share * ceiling, step), range.min, top)
	end
	-- Lower is better (0-60): `share` of the way down the band, scaled by the ceiling.
	local function down(range: Range, share: number, step: number): number
		local best = range.max - (range.max - range.min) * ceiling
		return math.clamp(toStep(range.max - (range.max - range.min) * share * ceiling, step), best, range.max)
	end
	return {
		topSpeedMph = up(band.topSpeedMph, personality.topSpeed, STAT_STEPS.topSpeedMph),
		zeroToSixtySec = down(band.zeroToSixtySec, personality.acceleration, STAT_STEPS.zeroToSixtySec),
		handling = up(band.handling, personality.handling, STAT_STEPS.handling),
		energyMinutes = up(band.energyMinutes, personality.range, STAT_STEPS.energyMinutes),
		seats = seatsOf(s, kit),
		drive = driveOf(s.class),
	}
end

function SpecBuilder.stats(spec: any, kit: any): Stats
	return statsOf(SpecBuilder.normalize(spec, kit), kit)
end

-- The design's catalog entry under `vehicleId`.
local function entryFor(s: Spec, kit: Kit, vehicleId: string): Vehicles.Vehicle
	local template = kit.templates[s.body.template]
	local stats = statsOf(s, kit)
	local name = s.name or string.format(Designer.messages.fallbackName, Classes[s.class].displayName)
	return {
		id = vehicleId,
		brandId = Garage.customVehicleId,
		displayName = name,
		class = s.class,
		bodyStyle = template.style :: any,
		energy = s.energy :: any,
		playerDrivable = true,
		geometry = geometryOf(s, kit),
		features = {},
		trims = {
			{
				id = Designer.designTrim,
				displayName = name,
				acquisition = DESIGN_ACQUISITION,
				price = nil,
				topSpeedMph = stats.topSpeedMph,
				zeroToSixtySec = stats.zeroToSixtySec,
				energyMinutes = stats.energyMinutes,
				seats = stats.seats,
				handling = stats.handling,
				drive = stats.drive,
			},
		},
	}
end

-- The synthetic catalog entry for a design (docs/phase-11-contracts.md): id "custom:<designUid>", the spec's class,
-- its template's body style, energy and geometry, no features, and one trim "design" with stats().
function SpecBuilder.vehicleFor(spec: any, kit: any, designUid: string): Vehicles.Vehicle
	return entryFor(SpecBuilder.normalize(spec, kit), kit, Designer.catalogPrefix .. designUid)
end

-- The Wrap & Tint fields (Config/Customization ids) a new design's car starts with, so its look keeps the design's
-- own wheel style and finish.
function SpecBuilder.lookFields(spec: any, kit: any): { finish: string, wheels: string }
	local s = SpecBuilder.normalize(spec, kit)
	return { finish = s.paint.finish, wheels = s.parts.wheels }
end

----------------------------------------------------------------------------------------------------------------
-- Building
----------------------------------------------------------------------------------------------------------------

local function toColor(value: string): Color3
	local r, g, b = string.match(value, "^#(%x%x)(%x%x)(%x%x)$")
	return Color3.fromRGB(tonumber(r, 16) or 0, tonumber(g, 16) or 0, tonumber(b, 16) or 0)
end

-- The wheel style's colors on the stock rim and spoke each tire carries (no extra parts: the full style goes on
-- with the car's look). A style without spokes shows its cap instead.
local function dressWheels(model: Model, wheelId: string)
	local style = Customization.getWheel(wheelId)
	local wheels = model:FindFirstChild("Wheels")
	if style == nil or wheels == nil then
		return
	end
	for _, wheel in wheels:GetChildren() do
		if not wheel:IsA("BasePart") then
			continue
		end
		local diameter = math.min(wheel.Size.Y, wheel.Size.Z)
		local rim = wheel:FindFirstChild("Rim")
		if rim ~= nil and rim:IsA("BasePart") then
			rim.Size = Vector3.new(rim.Size.X, diameter * style.rim, diameter * style.rim)
			rim.Color = style.rimColor
			rim.Material = style.material
		end
		local spoke = wheel:FindFirstChild("Spoke")
		if spoke ~= nil and spoke:IsA("BasePart") then
			if style.spokes > 0 then
				local thickness = diameter * math.max(style.spokeWidth, MIN_SPOKE_SHARE)
				spoke.Size = Vector3.new(spoke.Size.X, diameter * style.spokeLength, thickness)
				spoke.Color = style.spokeColor
			else
				local cap = diameter * style.cap
				spoke.Size = Vector3.new(spoke.Size.X, cap, cap)
				spoke.Color = style.capColor
			end
			spoke.Material = style.material
		end
	end
end

local function assembleSpec(
	s: Spec,
	kit: Kit,
	vehicleId: string,
	name: string,
	options: AssembleOptions?
): (Model, Vehicles.Vehicle)
	local vehicle = entryFor(s, kit, vehicleId)
	local trim = vehicle.trims[1]
	if options ~= nil and options.geometry ~= nil then
		vehicle.geometry = options.geometry
	end
	if options ~= nil and options.seats ~= nil then
		trim.seats = options.seats
	end
	local design: BodyKit.Design = {
		frontBumper = s.parts.frontBumper,
		rearBumper = s.parts.rearBumper,
		lights = s.parts.lights,
		noseSlope = lerp(kit.proportions.noseSlope, s.body.noseSlope),
	}
	local model = BodyKit.assemble(vehicle, trim, vehicle.geometry, { name = name, design = design })
	local secondary = toColor(s.paint.secondary)
	BodyKit.addSpoiler(model, s.parts.spoiler)
	BodyKit.paint(model, toColor(s.paint.primary), secondary, Customization.getFinish(s.paint.finish))
	dressWheels(model, s.parts.wheels)
	-- Stripes go on last, inside what is left of the part budget once the car's look goes on (Vehicle/Appearance:
	-- the wheel style's faces in place of the stock rim and spoke, and the plates). A busy wheel style can leave no
	-- room for them.
	local room = BodyKit.MAX_PARTS - BodyKit.partCount(model) - Appearance.addedParts(model, s.parts.wheels)
	BodyKit.addStripes(model, s.paint.stripe, secondary, math.max(room, 0))
	model:SetAttribute(SPEC_ATTRIBUTE, HttpService:JSONEncode(s))
	model:SetAttribute(KIT_ATTRIBUTE, kit.kitVersion)
	return model, vehicle
end

-- Builds the model without the contract check: at `options.geometry` (Vehicle/ModBuilder passes the car's own
-- wheels, ride height and chassis with a modded body around them) and with `options.seats` seats. Errors when the
-- body can't be built at that geometry.
function SpecBuilder.assemble(spec: any, kit: any, options: AssembleOptions?): Model
	local s = SpecBuilder.normalize(spec, kit)
	local model = assembleSpec(s, kit, Garage.customVehicleId, Garage.customVehicleId, options)
	return model
end

local function idsFor(designUid: string?): (string, string)
	if designUid ~= nil and designUid ~= "" then
		return Designer.catalogPrefix .. designUid, `{Garage.customVehicleId}_{designUid}`
	end
	return Garage.customVehicleId, Garage.customVehicleId
end

-- Builds a design's car (see the header). Errors if the result breaks the vehicle model contract (never for a spec
-- the kit can describe: tests/SpecBuilder.spec builds every template and part).
function SpecBuilder.build(spec: any, kit: any, designUid: string?): Model
	local s = SpecBuilder.normalize(spec, kit)
	local vehicleId, name = idsFor(designUid)
	local model, vehicle = assembleSpec(s, kit, vehicleId, name, nil)
	if designUid ~= nil and designUid ~= "" then
		model:SetAttribute(UID_ATTRIBUTE, designUid)
	end
	local problems = BodyKit.check(model, vehicle, vehicle.trims[1], vehicle.geometry, name)
	if #problems > 0 then
		model:Destroy()
		error(`{name} breaks the vehicle model contract:\n  {table.concat(problems, "\n  ")}`, 2)
	end
	return model
end

-- Every way `model` breaks the vehicle model contract as a build of this design (empty = good).
function SpecBuilder.check(model: Model, spec: any, kit: any, designUid: string?): { string }
	local s = SpecBuilder.normalize(spec, kit)
	local vehicleId, name = idsFor(designUid)
	local vehicle = entryFor(s, kit, vehicleId)
	return BodyKit.check(model, vehicle, vehicle.trims[1], vehicle.geometry, name)
end

-- The normalized spec a model was built from (its DesignSpec attribute), or nil for any other model.
function SpecBuilder.specOf(model: Model, kit: any): Spec?
	local source = model:GetAttribute(SPEC_ATTRIBUTE)
	if type(source) ~= "string" then
		return nil
	end
	local ok, decoded = pcall(function()
		return HttpService:JSONDecode(source)
	end)
	if not ok or type(decoded) ~= "table" then
		return nil
	end
	return SpecBuilder.normalize(decoded, kit)
end

-- Records the spec a model's body now shows (Vehicle/ModBuilder, after a mod rebuilt it).
function SpecBuilder.setSpecOf(model: Model, spec: Spec)
	model:SetAttribute(SPEC_ATTRIBUTE, HttpService:JSONEncode(spec))
end

return SpecBuilder
