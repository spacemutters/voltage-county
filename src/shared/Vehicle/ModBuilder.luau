--!strict
-- AI mods (PLAN.md Phase 11 "Mod spec"; docs/phase-11-contracts.md "Kit"): puts a mod spec on a car model that
-- follows the vehicle model contract. Read by Services/VehicleService (a car's saved mods, on a fresh copy before
-- its Wrap & Tint look goes on) and the client's mod screen (the before/after preview, on a copy of the car).
--
--   ModBuilder.apply(model, modSpec, kit, kind, options?)   kind "kit" for designed cars (built by
--                                                 Vehicle/SpecBuilder), "catalog" for catalog cars; options.wheels is
--                                                 the wheel style the car's Wrap & Tint look puts on afterwards
--                                                 (Services/VehicleService passes the owned car's), so the part budget
--                                                 counts the wheel faces the car will really wear
--   ModBuilder.changes(modSpec, kit, kind)        what the mod changes on that kind of car, e.g. { "paint.primary",
--                                                 "extras" } ({} = nothing)
--   ModBuilder.extrasOn(model)                    the extras mods built on the model, by id (Services/VehicleService
--                                                 reads which extras a mod really puts on before it is paid for)
--
-- What each kind may change comes from kit.mod (kitAllowed / catalogAllowed):
--   * kit cars (the model carries SpecBuilder's DesignSpec): the body proportions (length, height, roofline, nose
--     slope, flare), bumpers, lamps, spoiler, wheels, paint, finish, stripes, stance and extras. The body is rebuilt
--     in place from the design spec with the mod folded in, around the car's own wheels and chassis. The template
--     never changes (it sets the seats and the chassis box). A "kit" mod on a model without a DesignSpec gets the
--     catalog rules.
--   * catalog cars: paint (primary on the body, secondary on the roof panels and stripes), finish, stripes,
--     wheels, stance and extras.
--
-- Never touches physics: the Chassis part (size, mass, collision, physical properties), the wheels and their hub
-- attachments and Motors, the seat count and names, TowPoint and the feature attachments stay as they were, the
-- car's VehicleId and Trim never change (its stats come from them), and every part added is massless,
-- non-colliding, untouchable and invisible to raycasts, welded to the Chassis. What moves: the visual body, the
-- seats (into a re-proportioned cabin) and the visual mount points (BodyKit.VISUAL_POINTS: plates, hood camera,
-- Mount_*), so plates and extras stay on the body.
--
-- A mod is the car's factory state, so the Wrap & Tint look (Vehicle/Appearance) layers on top of it:
--   * paint, body, stripes and stance are built into the model (Appearance's recorded factory colors and positions
--     are kept in step when it has already been applied to the model);
--   * the wheel style and finish go on through Appearance with the mod's choices (Services/DesignerService also
--     saves them into the car's look, so a later look keeps them);
--   * extras are built by Appearance's extras builder, then kept as body parts (tagged EXTRA_TAG), so a later look
--     (shop extras included) layers on top instead of removing them;
--   * ride height: kit.proportions.rideHeight studs (-1 = its min, 0 = none, 1 = its max), lowering stopped where
--     the body would come within Config/Customization rideHeight.minClearance of the ground;
--   * wheel size: the wheel faces (rim, spokes, cap) scale inside the tire by kit.proportions.wheelSize relative
--     to the middle of the range; the tire is the physics wheel and never changes. The scale is kept in the
--     model's ModWheelScale attribute (Appearance builds the faces at it when it exports wheelScaleAttribute; see
--     appearanceScalesWheels).
--
-- The part budget (BodyKit.MAX_PARTS, docs/phase-1-contracts.md): a mod never takes the car past it with what this
-- module adds. Once the look is on (its wheel faces and plates count), stripes give way first (from the last one
-- laid), then extras (from the last one asked for). The body itself is never trimmed, so a car whose body and look
-- alone are over the budget (busy wheel styles; docs/PROGRESS.md open issues) keeps no stripes or mod extras.
--
-- A mod spec is read leniently (Services/DesignerService/Validate makes it canonical first): a number field is a
-- number, the kit's "keep" word or { change, value } (a block's own change = false keeps its numbers); ids and
-- colors must be in the kit ("#RRGGBB"); anything else counts as "keep".

local CollectionService = game:GetService("CollectionService")
local HttpService = game:GetService("HttpService")

local Shared = script.Parent.Parent
local Appearance = require(script.Parent.Appearance)
local BodyKit = require(script.Parent.BodyKit)
local Customization = require(Shared.Config.Customization)
local Designer = require(Shared.Config.Designer)
local SpecBuilder = require(script.Parent.SpecBuilder)
local Vehicles = require(Shared.Config.Vehicles)

export type Kind = "kit" | "catalog"

export type ApplyOptions = {
	wheels: string?, -- the Config/Customization wheel style the car's look puts on after the mod
}

local ModBuilder = {}

-- Model attributes and tags this module keeps.
local RIDE_ATTRIBUTE = "ModRideOffset" -- studs the mod moved the body (a later mod moves it from there)
local WHEEL_ATTRIBUTE = "ModWheelScale" -- the wheel faces' scale
local SECONDARY_ATTRIBUTE = "ModSecondary" -- a catalog car's secondary color (for stripes a later mod lays)
local EXTRA_TAG = "ModExtra" -- an extra a mod built, kept as a body part
local EXTRA_ID = "ExtraId" -- set on each extra's Model by Vehicle/Appearance
-- Vehicle/Appearance's factory-state attributes (its header): kept in step when a mod changes the factory state.
local LOOK_BASE = "LookBase"
local LOOK_BASE_C0 = "LookBaseC0"
local LOOK_BASE_COLOR = "LookBaseColor"
local LOOK_DATA = "LookData" -- the look last applied (Appearance.lookOf)
local HINGE_NAME = "Hinge" -- door Motor6D (Vehicle/BodyKit)
local PAINT_TAG = "Paint"

-- A re-proportioned body around a car's own wheels keeps at least this much body past the tires (studs): in front
-- of and behind them, and beside them.
local MIN_OVERHANG = 0.5
local MIN_SIDE = 0.05
local EPSILON = 1e-4

local BODY_NUMBERS = { "length", "height", "roofline", "noseSlope", "flare" }
local PART_FIELDS = { "frontBumper", "rearBumper", "spoiler", "lights", "wheels" }
local PAINT_COLORS = { "primary", "secondary" }
-- Spec fields a kit body is rebuilt for (wheels and finish go on with the look instead).
local REBUILD_PARTS = { "frontBumper", "rearBumper", "spoiler", "lights" }

-- A mod read against the kit: only what it changes (nil = keep).
type Mod = {
	body: { [string]: number },
	parts: { [string]: string },
	primary: string?,
	secondary: string?,
	finish: string?,
	stripe: string?,
	rideHeight: number?,
	wheelSize: number?,
	extras: { string }?,
}

----------------------------------------------------------------------------------------------------------------
-- Reading a mod spec
----------------------------------------------------------------------------------------------------------------

local function isFiniteNumber(value: any): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

-- True when a mod of `kind` may touch `section` (and, for parts, `field`), per kit.mod.
local function allowed(kit: SpecBuilder.Kit, kind: Kind, sectionName: string, field: string?): boolean
	local list = if kind == "kit" then kit.mod.kitAllowed else kit.mod.catalogAllowed
	if table.find(list, sectionName) ~= nil then
		return true
	end
	return field ~= nil and table.find(list, `{sectionName}.{field}`) ~= nil
end

-- A number field's new value, clamped, or nil to keep.
local function changeOf(value: any, blockChange: any, range: SpecBuilder.Range, keep: string): number?
	if value == nil or value == keep or blockChange == false then
		return nil
	end
	if isFiniteNumber(value) then
		return math.clamp(value, range.min, range.max)
	end
	if type(value) == "table" and value.change == true and isFiniteNumber(value.value) then
		return math.clamp(value.value, range.min, range.max)
	end
	return nil
end

local function block(raw: { [string]: any }, name: string): { [string]: any }
	local value = raw[name]
	return if type(value) == "table" then value else {}
end

local function read(rawSpec: any, kit: SpecBuilder.Kit, kind: Kind): Mod
	local raw: { [string]: any } = if type(rawSpec) == "table" then rawSpec else {}
	local keep = kit.mod.keep
	local mod: Mod = { body = {}, parts = {} }

	if allowed(kit, kind, "body") then
		local body = block(raw, "body")
		for _, field in BODY_NUMBERS do
			mod.body[field] = changeOf(body[field], body.change, kit.ranges.body, keep) :: any
		end
	end

	local parts = block(raw, "parts")
	for _, field in PART_FIELDS do
		local value = parts[field]
		if
			type(value) == "string"
			and value ~= keep
			and allowed(kit, kind, "parts", field)
			and table.find(kit.parts[field], value) ~= nil
		then
			mod.parts[field] = value
		end
	end

	if allowed(kit, kind, "paint") then
		local paint = block(raw, "paint")
		for _, field in PAINT_COLORS do
			local value = paint[field]
			if type(value) == "string" and string.match(value, "^#%x%x%x%x%x%x$") ~= nil then
				(mod :: any)[field] = string.upper(value)
			end
		end
		if type(paint.finish) == "string" and table.find(kit.finishes, paint.finish) ~= nil then
			mod.finish = paint.finish
		end
		if type(paint.stripe) == "string" and table.find(kit.stripes, paint.stripe) ~= nil then
			mod.stripe = paint.stripe
		end
	end

	if allowed(kit, kind, "stance") then
		local stance = block(raw, "stance")
		mod.rideHeight = changeOf(stance.rideHeight, stance.change, kit.ranges.rideHeight, keep)
		mod.wheelSize = changeOf(stance.wheelSize, stance.change, kit.ranges.wheelSize, keep)
	end

	-- Extras: kit ids, each once, the first per mount point, at most kit.limits.maxExtras.
	local extras = raw.extras
	if type(extras) == "table" and allowed(kit, kind, "extras") then
		local list: { string } = {}
		local mounts: { [string]: boolean } = {}
		for _, item in extras do
			local id = if type(item) == "table" then item.id else item
			local extra = if type(id) == "string" then kit.extras[id] else nil
			if extra ~= nil and not mounts[extra.mount] and #list < kit.limits.maxExtras then
				mounts[extra.mount] = true
				table.insert(list, id)
			end
		end
		mod.extras = list
	end
	return mod
end

-- The fields a mod changes on a car of `kind`, as "section.field" names (and "extras"). Empty: nothing to do.
function ModBuilder.changes(modSpec: any, kitData: any, kind: Kind): { string }
	local kit: SpecBuilder.Kit = kitData
	local mod = read(modSpec, kit, kind)
	local list: { string } = {}
	for _, field in BODY_NUMBERS do
		if mod.body[field] ~= nil then
			table.insert(list, `body.{field}`)
		end
	end
	for _, field in PART_FIELDS do
		if mod.parts[field] ~= nil then
			table.insert(list, `parts.{field}`)
		end
	end
	for _, field in { "primary", "secondary", "finish", "stripe" } do
		if (mod :: any)[field] ~= nil then
			table.insert(list, `paint.{field}`)
		end
	end
	for _, field in { "rideHeight", "wheelSize" } do
		if (mod :: any)[field] ~= nil then
			table.insert(list, `stance.{field}`)
		end
	end
	if mod.extras ~= nil then
		table.insert(list, "extras")
	end
	return list
end

----------------------------------------------------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------------------------------------------------

local function toColor(value: string): Color3
	local r, g, b = string.match(value, "^#(%x%x)(%x%x)(%x%x)$")
	return Color3.fromRGB(tonumber(r, 16) or 0, tonumber(g, 16) or 0, tonumber(b, 16) or 0)
end

local function isLookPart(instance: Instance): boolean
	return CollectionService:HasTag(instance, Customization.lookTag)
end

-- Moves parts to new CFrames with their WeldConstraints switched off while they move, so each weld records the
-- new offset (moving a welded part with its weld on would drag the whole car along).
local function moveParts(moves: { { part: BasePart, target: CFrame } })
	local paused: { WeldConstraint } = {}
	for _, move in moves do
		for _, joint in move.part:GetJoints() do
			if joint:IsA("WeldConstraint") and joint.Enabled then
				joint.Enabled = false
				table.insert(paused, joint)
			end
		end
	end
	for _, move in moves do
		move.part.CFrame = move.target
	end
	for _, joint in paused do
		joint.Enabled = true
	end
end

-- The visual body's parts: everything under Body and Lights except what the Wrap & Tint look built.
local function bodyParts(model: Model): { BasePart }
	local parts: { BasePart } = {}
	for _, folderName in { "Body", "Lights" } do
		local folder = model:FindFirstChild(folderName)
		if folder == nil then
			continue
		end
		for _, descendant in folder:GetDescendants() do
			if descendant:IsA("BasePart") and not isLookPart(descendant) then
				table.insert(parts, descendant)
			end
		end
	end
	return parts
end

local function setAttachment(chassis: BasePart, name: string, cframe: CFrame)
	local point = chassis:FindFirstChild(name)
	if point ~= nil and point:IsA("Attachment") then
		point.CFrame = cframe
	end
end

----------------------------------------------------------------------------------------------------------------
-- Kit cars: the body rebuilt in place
----------------------------------------------------------------------------------------------------------------

-- The design spec with the mod's body numbers, parts and paint folded in (template and stance stay).
local function merged(spec: SpecBuilder.Spec, mod: Mod, kit: SpecBuilder.Kit): SpecBuilder.Spec
	local raw: any = {
		name = spec.name,
		tagline = spec.tagline,
		class = spec.class,
		energy = spec.energy,
		personality = spec.personality,
		body = table.clone(spec.body),
		parts = table.clone(spec.parts),
		paint = table.clone(spec.paint),
		stance = table.clone(spec.stance),
	}
	for field, value in mod.body do
		raw.body[field] = value
	end
	for field, value in mod.parts do
		raw.parts[field] = value
	end
	for _, field in { "primary", "secondary", "finish", "stripe" } do
		local value = (mod :: any)[field]
		if value ~= nil then
			raw.paint[field] = value
		end
	end
	return SpecBuilder.normalize(raw, kit)
end

-- True when the body itself looks different (wheels and finish go on with the look instead).
local function bodyChanged(a: SpecBuilder.Spec, b: SpecBuilder.Spec): boolean
	for _, field in BODY_NUMBERS do
		if math.abs((a.body :: any)[field] - (b.body :: any)[field]) > EPSILON then
			return true
		end
	end
	for _, field in REBUILD_PARTS do
		if (a.parts :: any)[field] ~= (b.parts :: any)[field] then
			return true
		end
	end
	return a.paint.primary ~= b.paint.primary
		or a.paint.secondary ~= b.paint.secondary
		or a.paint.stripe ~= b.paint.stripe
end

-- The geometry to build a modded body at: the design's proportions, around the car's own wheels, ride height and
-- chassis (`physics`, read from the model), never so short or narrow that the tires stick out.
local function visualGeometry(
	spec: SpecBuilder.Spec,
	kit: SpecBuilder.Kit,
	physics: Vehicles.Geometry
): Vehicles.Geometry
	local g = SpecBuilder.geometry(spec, kit)
	local arches = BodyKit.archTop(physics) + BodyKit.MIN_ROOM_OVER_ARCHES
	return {
		length = math.max(g.length, physics.wheelbase + 2 * (physics.wheelRadius + MIN_OVERHANG)),
		width = math.max(g.width, physics.track + physics.wheelWidth + 2 * MIN_SIDE),
		height = math.max(g.height, arches, physics.rideHeight + physics.chassisHeight),
		wheelbase = physics.wheelbase,
		track = physics.track,
		wheelRadius = physics.wheelRadius,
		wheelWidth = physics.wheelWidth,
		rideHeight = physics.rideHeight,
		chassisHeight = physics.chassisHeight,
	}
end

local function seatCount(model: Model): number
	local seats = model:FindFirstChild("Seats")
	local count = 0
	if seats ~= nil then
		for _, child in seats:GetChildren() do
			if child:IsA("Seat") then
				count += 1
			end
		end
	end
	return count
end

-- Swaps the model's visual body for `scratch`'s: Body and Lights parts (the mod's extras stay), the seats moved to
-- the new cabin and the visual mount points to the new body. The Chassis, wheels and every physics attachment stay.
local function transplant(model: Model, chassis: BasePart, scratch: Model)
	local scratchChassis = scratch.PrimaryPart
	if scratchChassis == nil then
		return
	end
	for _, folderName in { "Body", "Lights" } do
		local target = model:FindFirstChild(folderName)
		if target == nil then
			local created = Instance.new("Folder")
			created.Name = folderName
			created.Parent = model
			target = created
		end
		local into = target :: Instance
		for _, child in into:GetChildren() do
			if not CollectionService:HasTag(child, EXTRA_TAG) then
				child:Destroy()
			end
		end
		local source = scratch:FindFirstChild(folderName)
		if source == nil then
			continue
		end
		for _, child in source:GetChildren() do
			if not child:IsA("BasePart") then
				continue
			end
			local rel = scratchChassis.CFrame:ToObjectSpace(child.CFrame)
			for _, joint in child:GetChildren() do
				if joint:IsA("WeldConstraint") and joint.Part0 == scratchChassis then
					joint:Destroy()
				end
			end
			child.CFrame = chassis.CFrame * rel
			BodyKit.weld(chassis, child)
			child.Parent = into
		end
	end

	local seats, scratchSeats = model:FindFirstChild("Seats"), scratch:FindFirstChild("Seats")
	if seats ~= nil and scratchSeats ~= nil then
		local moves: { { part: BasePart, target: CFrame } } = {}
		for _, seat in seats:GetChildren() do
			local source = scratchSeats:FindFirstChild(seat.Name)
			if seat:IsA("Seat") and source ~= nil and source:IsA("BasePart") then
				local rel = scratchChassis.CFrame:ToObjectSpace(source.CFrame)
				table.insert(moves, { part = seat :: BasePart, target = chassis.CFrame * rel })
			end
		end
		moveParts(moves)
	end

	for _, name in BodyKit.VISUAL_POINTS do
		local source = scratchChassis:FindFirstChild(name)
		if source ~= nil and source:IsA("Attachment") then
			setAttachment(chassis, name, source.CFrame)
		end
	end
end

-- Rebuilds a designed car's body with the mod folded into its spec. Returns true when it rebuilt it (the new body
-- sits at its factory place: no mod ride height yet).
local function rebuildBody(
	model: Model,
	chassis: BasePart,
	spec: SpecBuilder.Spec,
	mod: Mod,
	kit: SpecBuilder.Kit
): boolean
	local target = merged(spec, mod, kit)
	if not bodyChanged(spec, target) then
		SpecBuilder.setSpecOf(model, target) -- wheels or finish only: nothing to rebuild
		return false
	end
	local physics = BodyKit.readGeometry(model)
	if physics == nil then
		return false
	end
	local seats = seatCount(model)
	local ok, scratch = pcall(SpecBuilder.assemble, target, kit, {
		geometry = visualGeometry(target, kit, physics),
		seats = seats,
	})
	if not ok then
		-- The new proportions don't fit around this car's wheels: keep its proportions, change the rest.
		local keepBody = table.clone(target)
		keepBody.body = table.clone(spec.body)
		target = keepBody
		ok, scratch = pcall(SpecBuilder.assemble, target, kit, {
			geometry = visualGeometry(target, kit, physics),
			seats = seats,
		})
		if not ok then
			warn(`[ModBuilder] couldn't rebuild the body of {model.Name}: {scratch}`)
			return false
		end
	end
	local built = scratch :: Model
	transplant(model, chassis, built)
	built:Destroy()
	SpecBuilder.setSpecOf(model, target)
	return true
end

----------------------------------------------------------------------------------------------------------------
-- Catalog cars: paint and stripes in place
----------------------------------------------------------------------------------------------------------------

-- Sets a painted part's color as its factory color (Appearance's recorded one too, when there is one).
local function setFactoryColor(part: BasePart, color: Color3)
	part.Color = color
	if typeof(part:GetAttribute(LOOK_BASE_COLOR)) == "Color3" then
		part:SetAttribute(LOOK_BASE_COLOR, color)
	end
end

local function paintCatalog(model: Model, mod: Mod)
	local primary, secondary = mod.primary, mod.secondary
	if primary ~= nil or secondary ~= nil then
		for _, descendant in model:GetDescendants() do
			if
				not descendant:IsA("BasePart")
				or isLookPart(descendant)
				or not CollectionService:HasTag(descendant, PAINT_TAG)
			then
				continue
			end
			local color = if BodyKit.ROOF_PANELS[descendant.Name] then secondary else primary
			if color ~= nil then
				setFactoryColor(descendant, toColor(color))
			end
		end
	end
	if secondary ~= nil then
		model:SetAttribute(SECONDARY_ATTRIBUTE, secondary)
	end

	local stripeColor = model:GetAttribute(SECONDARY_ATTRIBUTE)
	local color = toColor(if type(stripeColor) == "string" then stripeColor else Designer.plainLook.secondary)
	if mod.stripe ~= nil then
		BodyKit.clearStripes(model)
		BodyKit.addStripes(model, mod.stripe, color)
	elseif secondary ~= nil then
		for _, stripe in BodyKit.stripes(model) do
			stripe.Color = color
		end
	end
end

----------------------------------------------------------------------------------------------------------------
-- Stance
----------------------------------------------------------------------------------------------------------------

-- Studs a mod ride height (-1..1) moves the body: kit.proportions.rideHeight, like a design's stance.
local function rideOffsetOf(value: number, kit: SpecBuilder.Kit): number
	local range = kit.proportions.rideHeight
	return if value >= 0 then value * range.max else -value * range.min
end

-- A lowering cut short so the lowest body part stays Customization.rideHeight.minClearance above the ground under
-- the wheels (the body doesn't collide, so a chin lower than that would go through the road on braking).
local function clampLowering(model: Model, chassis: BasePart, current: number, wanted: number): number
	if wanted >= 0 then
		return wanted
	end
	local wheels = model:FindFirstChild("Wheels")
	local ground = math.huge
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
			if part:IsA("BasePart") and not isLookPart(part) then
				local rel = chassis.CFrame:ToObjectSpace(part.CFrame)
				local half = part.Size / 2
				local reach = math.abs(rel.XVector.Y) * half.X
					+ math.abs(rel.YVector.Y) * half.Y
					+ math.abs(rel.ZVector.Y) * half.Z
				lowest = math.min(lowest, rel.Position.Y - reach)
			end
		end
	end
	if ground == math.huge or lowest == math.huge then
		return wanted
	end
	local factoryLowest = lowest - current
	local room = math.max(0, factoryLowest - ground - Customization.rideHeight.minClearance)
	return math.max(wanted, -room)
end

-- Moves the visual body `delta` studs up the Chassis's up axis, as factory state: Body and Lights parts (with
-- Appearance's recorded positions), door hinges and the visual mount points.
local function moveBody(model: Model, chassis: BasePart, delta: number)
	if math.abs(delta) <= EPSILON then
		return
	end
	local lift = CFrame.new(0, delta, 0) -- chassis space
	local moves: { { part: BasePart, target: CFrame } } = {}
	for _, part in bodyParts(model) do
		table.insert(moves, { part = part, target = chassis.CFrame * lift * chassis.CFrame:ToObjectSpace(part.CFrame) })
		local base = part:GetAttribute(LOOK_BASE)
		if typeof(base) == "CFrame" then
			part:SetAttribute(LOOK_BASE, lift * base)
		end
	end
	moveParts(moves)

	local doors = model:FindFirstChild("Doors")
	if doors ~= nil then
		for _, descendant in doors:GetDescendants() do
			if descendant:IsA("Motor6D") and descendant.Name == HINGE_NAME and descendant.Part0 == chassis then
				descendant.C0 = lift * descendant.C0
				local base = descendant:GetAttribute(LOOK_BASE_C0)
				if typeof(base) == "CFrame" then
					descendant:SetAttribute(LOOK_BASE_C0, lift * base)
				end
			end
		end
	end

	for _, name in BodyKit.VISUAL_POINTS do
		local point = chassis:FindFirstChild(name)
		if point ~= nil and point:IsA("Attachment") then
			point.CFrame = lift * point.CFrame
		end
	end
end

----------------------------------------------------------------------------------------------------------------
-- The look: wheels, finish and extras through Vehicle/Appearance
----------------------------------------------------------------------------------------------------------------

-- The look a car without one starts from: Config/Customization's defaults, with a design's own finish and wheels.
local function startingLook(spec: SpecBuilder.Spec?): Customization.Look
	local defaults = Customization.defaults
	return {
		uid = "",
		paint = defaults.paint,
		finish = if spec ~= nil then spec.paint.finish else defaults.finish,
		wrap = defaults.wrap,
		wheels = if spec ~= nil then spec.parts.wheels else defaults.wheels,
		rideHeight = defaults.rideHeight,
		tint = defaults.tint,
		caliper = defaults.caliper,
		extras = {},
		plateFormat = defaults.plateFormat,
		plateText = nil,
	}
end

-- The extras mods built on the model (their holders in Body), in the order they were put on.
local function extraHolders(model: Model): { Instance }
	local holders: { Instance } = {}
	local body = model:FindFirstChild("Body")
	if body ~= nil then
		for _, child in body:GetChildren() do
			if CollectionService:HasTag(child, EXTRA_TAG) and type(child:GetAttribute(EXTRA_ID)) == "string" then
				table.insert(holders, child)
			end
		end
	end
	return holders
end

-- The extras earlier mods built on the model, by id.
local function modExtras(model: Model): { string }
	local ids: { string } = {}
	for _, holder in extraHolders(model) do
		table.insert(ids, holder:GetAttribute(EXTRA_ID) :: string)
	end
	return ids
end

local function clearModExtras(model: Model)
	local body = model:FindFirstChild("Body")
	if body ~= nil then
		for _, child in body:GetChildren() do
			if CollectionService:HasTag(child, EXTRA_TAG) then
				child:Destroy()
			end
		end
	end
end

-- Puts the mod's wheel style and finish on with Appearance, builds `extras` with Appearance's extras builder and
-- keeps them as body parts. The look's own ride height is left at none: the mod's stance is already in the body.
-- `finalWheels` (ApplyOptions.wheels) is the wheel style the car's own look puts on afterwards; it wins, so the
-- faces counted against the part budget are the ones the car will wear.
local function applyLook(model: Model, mod: Mod, spec: SpecBuilder.Spec?, extras: { string }?, finalWheels: string?)
	local base = Appearance.lookOf(model) or startingLook(spec)
	local look: Customization.Look = table.clone(base)
	if mod.primary ~= nil or mod.secondary ~= nil then
		look.paint = Customization.defaults.paint -- the factory paint: the mod's colors
	end
	look.finish = mod.finish or base.finish
	look.wheels = finalWheels or mod.parts.wheels or base.wheels
	look.rideHeight = Customization.defaults.rideHeight
	look.extras = if extras ~= nil then table.clone(extras) else {}
	if extras ~= nil then
		clearModExtras(model)
	end
	Appearance.apply(model, look)
	if extras == nil then
		return
	end
	local body = model:FindFirstChild("Body")
	if body == nil then
		return
	end
	for _, id in extras do
		local holder = Appearance.findExtra(model, id)
		if holder == nil then
			continue -- the extra doesn't fit this car (Config/Customization classes and body styles)
		end
		CollectionService:RemoveTag(holder, Customization.lookTag)
		for _, descendant in holder:GetDescendants() do
			CollectionService:RemoveTag(descendant, Customization.lookTag)
		end
		CollectionService:AddTag(holder, EXTRA_TAG)
		holder.Parent = body
	end
	-- The extras are body now: the look on record lists none, so re-applying it (Appearance.lookOf, as the shop's
	-- preview does) never builds them a second time.
	local recorded = Appearance.lookOf(model)
	if recorded ~= nil then
		recorded.extras = {}
		model:SetAttribute(LOOK_DATA, HttpService:JSONEncode(recorded))
	end
end

----------------------------------------------------------------------------------------------------------------
-- Wheel faces
----------------------------------------------------------------------------------------------------------------

-- True when Vehicle/Appearance builds the wheel faces at the model's WHEEL_ATTRIBUTE scale itself (it then exports
-- the attribute's name as wheelScaleAttribute), so every later look keeps a mod's wheel size. Until it does, this
-- module scales the faces after Appearance builds them, which a later look (CustomizationService) undoes.
local function appearanceScalesWheels(): boolean
	return (Appearance :: any).wheelScaleAttribute == WHEEL_ATTRIBUTE
end

-- The wheel faces' scale for a mod wheel size (1 at the middle of the kit's range).
local function faceScaleOf(value: number, kit: SpecBuilder.Kit): number
	local range = kit.proportions.wheelSize
	local middle = (kit.ranges.wheelSize.min + kit.ranges.wheelSize.max) / 2
	local reference = range.min + (range.max - range.min) * middle
	return (range.min + (range.max - range.min) * value) / reference
end

-- Scales every part on each wheel (the face Appearance or BodyKit built) about the wheel's axle, in the wheel's
-- plane; the tire itself stays as it is.
local function scaleFaces(model: Model, scale: number)
	if math.abs(scale - 1) <= EPSILON then
		return
	end
	local wheels = model:FindFirstChild("Wheels")
	if wheels == nil then
		return
	end
	local moves: { { part: BasePart, target: CFrame } } = {}
	local sizes: { [BasePart]: Vector3 } = {}
	for _, wheel in wheels:GetChildren() do
		if not wheel:IsA("BasePart") then
			continue
		end
		for _, face in wheel:GetDescendants() do
			if face:IsA("BasePart") then
				local rel = wheel.CFrame:ToObjectSpace(face.CFrame)
				local at = rel.Position
				local scaled = CFrame.new(at.X, at.Y * scale, at.Z * scale) * rel.Rotation
				table.insert(moves, { part = face, target = wheel.CFrame * scaled })
				local size = face.Size
				sizes[face] = Vector3.new(size.X, size.Y * scale, size.Z * scale)
			end
		end
	end
	for part, size in sizes do
		part.Size = size
	end
	moveParts(moves)
end

----------------------------------------------------------------------------------------------------------------
-- The part budget
----------------------------------------------------------------------------------------------------------------

local function partsIn(instance: Instance): number
	local count = if instance:IsA("BasePart") then 1 else 0
	for _, descendant in instance:GetDescendants() do
		if descendant:IsA("BasePart") then
			count += 1
		end
	end
	return count
end

-- Takes the model back inside BodyKit.MAX_PARTS with what mods add (see the header): stripes from the last one laid,
-- then extras from the last one put on. Deterministic, so the same mod always leaves the same car.
local function keepPartBudget(model: Model)
	local over = BodyKit.partCount(model) - BodyKit.MAX_PARTS
	if over <= 0 then
		return
	end
	local stripes = BodyKit.stripes(model)
	for index = #stripes, 1, -1 do
		if over <= 0 then
			return
		end
		stripes[index]:Destroy()
		over -= 1
	end
	local holders = extraHolders(model)
	for index = #holders, 1, -1 do
		if over <= 0 then
			return
		end
		local holder = holders[index]
		over -= partsIn(holder)
		holder:Destroy()
	end
end

----------------------------------------------------------------------------------------------------------------
-- Applying
----------------------------------------------------------------------------------------------------------------

-- The extras mods built on `model`, by id, in the order they went on.
function ModBuilder.extrasOn(model: Model): { string }
	return modExtras(model)
end

-- Puts a mod on a car model (see the header). Safe to call on a fresh copy (VehicleService) or on a copy that
-- already wears a look or earlier mods (previews). Does nothing to a model without a Chassis.
function ModBuilder.apply(model: Model, modSpec: any, kitData: any, kind: Kind, options: ApplyOptions?)
	local kit: SpecBuilder.Kit = kitData
	local chassis = model:FindFirstChild("Chassis")
	if chassis == nil or not chassis:IsA("BasePart") then
		return
	end
	local finalWheels = if options ~= nil then options.wheels else nil
	local spec = if kind == "kit" then SpecBuilder.specOf(model, kit) else nil
	local mod = read(modSpec, kit, if spec ~= nil then "kit" else "catalog")

	-- 1. The body (designed cars) or the paint and stripes (catalog cars).
	local rebuilt = false
	if spec ~= nil then
		rebuilt = rebuildBody(model, chassis, spec, mod, kit)
		spec = SpecBuilder.specOf(model, kit)
	else
		paintCatalog(model, mod)
	end

	-- 2. Ride height: from where the body is now (a rebuilt body starts with none) to where the mod wants it.
	local stored = model:GetAttribute(RIDE_ATTRIBUTE)
	local applied = if type(stored) == "number" then stored else 0
	local current = if rebuilt then 0 else applied
	local wanted = if mod.rideHeight ~= nil then rideOffsetOf(mod.rideHeight, kit) else applied
	local offset = clampLowering(model, chassis, current, wanted)
	moveBody(model, chassis, offset - current)
	if mod.rideHeight ~= nil or type(stored) == "number" then
		model:SetAttribute(RIDE_ATTRIBUTE, offset)
	end

	-- 3. Wheel size, recorded before the look goes on (an Appearance that reads it builds the faces at that size).
	local scaleAttribute = model:GetAttribute(WHEEL_ATTRIBUTE)
	local scale = if mod.wheelSize ~= nil
		then faceScaleOf(mod.wheelSize, kit)
		elseif type(scaleAttribute) == "number" then scaleAttribute
		else 1
	if mod.wheelSize ~= nil or type(scaleAttribute) == "number" then
		model:SetAttribute(WHEEL_ATTRIBUTE, scale)
	end

	-- 4. Wheel style, finish and extras (a rebuilt body gets the earlier mods' extras again, on its new shape).
	local extras = mod.extras
	if extras == nil and rebuilt then
		extras = modExtras(model)
	end
	applyLook(model, mod, spec, extras, finalWheels)

	-- 5. Wheel size on the faces Appearance just built, unless it already built them at that size.
	if not appearanceScalesWheels() then
		scaleFaces(model, scale)
	end

	-- 6. The part budget, with the look's wheel faces and plates on: stripes, then extras give way.
	keepPartBudget(model)
end

return ModBuilder
