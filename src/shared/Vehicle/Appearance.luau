--!strict
-- Sets a car model's look from an owned car's customization (docs/phase-7-contracts.md "Appearance"). Used by
-- the server when a car spawns or a purchase lands, and by the Wrap & Tint shop for its client-only preview.
--
--   Appearance.apply(model, look)   paint, finish, wrap, wheels, ride height, tint, calipers, extras, plates
--   Appearance.lookOf(model)        the look last applied to the model (the shop reverts a preview with it)
--   Appearance.findExtra(model, id) an extra's Model (light shows look for the light bar's PointLight)
--
-- Works on any model that follows the vehicle model contract (docs/phase-1-contracts.md): Body parts tagged
-- Paint, Trim and Glass, Wheels FL/FR/RL/RR, Lights, optional Doors, and the PlateFront, PlateRear and Mount_*
-- attachments on the Chassis. Options and their numbers come from Config/Customization.
--
-- What it changes, and what it never touches:
--   * Paint-tagged parts take the paint color and the finish's material and reflectance. The "factory" paint
--     (the default) puts back each part's own brand color as built.
--   * Trim-tagged parts take the wrap's trim color, or go back to their own.
--   * Glass-tagged parts take the tint level's transparency and darkening.
--   * Ride height moves only the visual body (Body and Lights parts, and door hinges) up or down. The Chassis,
--     the wheels' hub attachments and Motors, the seats and the suspension never change, so handling and the
--     server's checks are the same at any stance.
--   * Everything it builds (wrap vinyl, rim parts, extras, plates) is tagged Config/Customization.lookTag,
--     massless, non-colliding, untouchable and invisible to raycasts, and welded to the Chassis (or to its
--     wheel, so rims spin and steer with it). Applying again removes them first, so applying the same look
--     twice leaves exactly the same instances.
--   * Physics never changes: no Chassis property, no mass, no collision.
--
-- The first apply records each part's factory state in attributes (LookBase, LookBaseColor, ...), so every
-- later apply works from the factory state and never drifts. Plate text: `look.plateText` must already be
-- filtered by the server (Services/CustomizationService); it is shown exactly as given. nil shows the plate
-- format's standard number and "" a blank plate.

local CollectionService = game:GetService("CollectionService")
local HttpService = game:GetService("HttpService")

local Catalog = require(script.Parent.Catalog)
local Customization = require(script.Parent.Parent.Config.Customization)

export type Look = Customization.Look

local Appearance = {}

-- Model structure names (vehicle model contract).
local WHEEL_NAMES = { "FL", "FR", "RL", "RR" }
local PLATE_POINTS = { "PlateFront", "PlateRear" }
local LOOK_FOLDER = "Look" -- holds the wrap vinyl, extras and plates this module builds
local HINGE_NAME = "Hinge" -- door Motor6D (VehicleBuilder)
local STOCK_RIM_PARTS = { Rim = true, Spoke = true } -- VehicleBuilder's plain wheel face, replaced by a style

-- Attributes recording a part's factory state (set on the first apply) and the applied look on the model.
local BASE_CFRAME = "LookBase" -- part CFrame relative to the Chassis
local BASE_C0 = "LookBaseC0" -- door hinge Motor6D C0
local BASE_COLOR = "LookBaseColor"
local BASE_TRANSPARENCY = "LookBaseTransparency"
local LOOK_DATA = "LookData" -- JSON of the applied look (Appearance.lookOf)
local EXTRA_ID = "ExtraId" -- on each extra's Model

-- Numerical slack: Vector3 and CFrame are 32-bit floats.
local ALIGNED = 0.999 -- a part axis this parallel to a chassis axis counts as aligned with it
local MOVE_EPSILON = 1e-4 -- studs: a part this close to its target isn't moved again
local BLACK = Color3.new(0, 0, 0)

type Box = { min: Vector3, max: Vector3 } -- chassis-space bounding box
type Panel = { part: BasePart, box: Box, rel: CFrame, aligned: boolean }

-- Everything apply needs, resolved from the look with defaults for anything missing or unknown.
type Resolved = {
	look: Look,
	paint: Color3, -- for the factory paint: the car's own color (extras painted to match)
	factoryPaint: boolean, -- Paint parts go back to the color they were built in
	finish: Customization.Finish,
	wrap: Customization.Wrap,
	wheel: Customization.Wheel,
	caliper: Customization.Caliper,
	tint: Customization.TintLevel,
	plateFormat: Customization.PlateFormat,
	offset: number, -- ride height body offset, studs
	class: string?,
	bodyStyle: string?, -- Config/Vehicles bodyStyle (some extras fit only some bodies)
}

----------------------------------------------------------------------------------------------------------------
-- Resolving a look
----------------------------------------------------------------------------------------------------------------

local function catalogEntry(model: Model)
	local vehicleId = model:GetAttribute("VehicleId")
	if type(vehicleId) ~= "string" then
		return nil
	end
	return Catalog.getVehicle(vehicleId)
end

local function classOf(model: Model): string?
	local vehicle = catalogEntry(model)
	return if vehicle then vehicle.class else nil
end

local function bodyStyleOf(model: Model): string?
	local vehicle = catalogEntry(model)
	return if vehicle then vehicle.bodyStyle else nil
end

local function stringOr(value: any, fallback: string): string
	return if type(value) == "string" then value else fallback
end

local function numberOr(value: any, fallback: number): number
	return if type(value) == "number" and value == value then value else fallback
end

-- A complete look from whatever was passed (an OwnedVehicle, a preview look, an old save missing v5 fields).
local function complete(look: Look): Look
	local defaults = Customization.defaults
	local raw = look :: any
	local extras: { string } = {}
	if type(raw.extras) == "table" then
		for _, id in raw.extras do
			if type(id) == "string" and not table.find(extras, id) then
				table.insert(extras, id)
			end
		end
	end
	return {
		uid = stringOr(raw.uid, ""),
		paint = stringOr(raw.paint, defaults.paint),
		finish = stringOr(raw.finish, defaults.finish),
		wrap = stringOr(raw.wrap, defaults.wrap),
		wheels = stringOr(raw.wheels, defaults.wheels),
		rideHeight = numberOr(raw.rideHeight, defaults.rideHeight),
		tint = numberOr(raw.tint, defaults.tint),
		caliper = stringOr(raw.caliper, defaults.caliper),
		extras = extras,
		plateFormat = stringOr(raw.plateFormat, defaults.plateFormat),
		plateText = if type(raw.plateText) == "string" then raw.plateText else nil,
	}
end

-- A catalog entry that must exist (the defaults in Config/Customization always do).
local function need<T>(value: T?, what: string): T
	if value == nil then
		error(`Config/Customization has no default {what}`, 2)
	end
	return value
end

local baseColor: (part: BasePart) -> Color3

-- The color the car was built in: its first Paint part's factory color (nil without Paint parts).
local function factoryColor(model: Model): Color3?
	for _, descendant in model:GetDescendants() do
		if
			descendant:IsA("BasePart")
			and not CollectionService:HasTag(descendant, Customization.lookTag)
			and CollectionService:HasTag(descendant, "Paint")
		then
			return baseColor(descendant)
		end
	end
	return nil
end

local function resolve(model: Model, look: Look): Resolved
	local defaults = Customization.defaults
	local full = complete(look)
	local class = classOf(model)
	-- An unknown paint id shows the default (the factory color).
	local paintId = if Customization.paintColor(full.paint) ~= nil then full.paint else defaults.paint
	local factoryPaint = Customization.isFactoryPaint(paintId)
	local swatch = need(Customization.paintColor(paintId), "paint")
	return {
		look = full,
		paint = if factoryPaint then factoryColor(model) or swatch else swatch,
		factoryPaint = factoryPaint,
		finish = need(Customization.getFinish(full.finish) or Customization.getFinish(defaults.finish), "finish"),
		wrap = need(Customization.getWrap(full.wrap) or Customization.getWrap(defaults.wrap), "wrap"),
		wheel = need(Customization.getWheel(full.wheels) or Customization.getWheel(defaults.wheels), "wheels"),
		caliper = need(Customization.getCaliper(full.caliper) or Customization.getCaliper(defaults.caliper), "caliper"),
		tint = Customization.nearestTintLevel(full.tint),
		plateFormat = need(
			Customization.getPlateFormat(full.plateFormat) or Customization.getPlateFormat(defaults.plateFormat),
			"plateFormat"
		),
		offset = Customization.rideOffset(full.rideHeight, class),
		class = class,
		bodyStyle = bodyStyleOf(model),
	}
end

----------------------------------------------------------------------------------------------------------------
-- Building helpers
----------------------------------------------------------------------------------------------------------------

local function isLookPart(instance: Instance): boolean
	return CollectionService:HasTag(instance, Customization.lookTag)
end

-- A visual part per the model contract: massless, unanchored, and invisible to collisions, touches and
-- raycasts. Positioned, welded to `anchor`, tagged, and parented.
local function newPart(
	className: "Part" | "WedgePart",
	name: string,
	size: Vector3,
	cframe: CFrame,
	color: Color3,
	material: Enum.Material,
	anchor: BasePart,
	parent: Instance
): BasePart
	local part: BasePart = Instance.new(className) :: any
	part.Name = name
	part.Size = size
	part.CFrame = cframe
	part.Color = color
	part.Material = material
	part.Anchored = false
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.Massless = true
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	CollectionService:AddTag(part, Customization.lookTag)
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = anchor
	weld.Part1 = part
	weld.Parent = part
	part.Parent = parent
	return part
end

-- A cylinder running along the parent frame's X axis (wheels' axles run along X).
local function newDisc(
	name: string,
	width: number,
	diameter: number,
	cframe: CFrame,
	color: Color3,
	material: Enum.Material,
	anchor: BasePart,
	parent: Instance
): BasePart
	local part = newPart("Part", name, Vector3.new(width, diameter, diameter), cframe, color, material, anchor, parent);
	(part :: Part).Shape = Enum.PartType.Cylinder
	return part
end

local function lookFolder(model: Model): Folder
	local existing = model:FindFirstChild(LOOK_FOLDER)
	if existing and existing:IsA("Folder") then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = LOOK_FOLDER
	folder.Parent = model
	return folder
end

-- Every BasePart under the named folders of the model, skipping anything this module built.
local function partsIn(model: Model, folderNames: { string }): { BasePart }
	local parts: { BasePart } = {}
	for _, folderName in folderNames do
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

-- Removes everything a previous apply built, and VehicleBuilder's plain wheel face (a wheel style replaces it).
local function clear(model: Model)
	local doomed: { Instance } = {}
	for _, descendant in model:GetDescendants() do
		if isLookPart(descendant) then
			table.insert(doomed, descendant)
		end
	end
	local wheels = model:FindFirstChild("Wheels")
	if wheels then
		for _, name in WHEEL_NAMES do
			local wheel = wheels:FindFirstChild(name)
			if wheel == nil then
				continue
			end
			for _, child in wheel:GetChildren() do
				if child:IsA("BasePart") and STOCK_RIM_PARTS[child.Name] then
					table.insert(doomed, child)
				end
			end
		end
	end
	for _, instance in doomed do
		instance:Destroy()
	end
end

----------------------------------------------------------------------------------------------------------------
-- Ride height
----------------------------------------------------------------------------------------------------------------

-- Records a part's factory CFrame (relative to the Chassis) the first time, and returns it.
local function baseCFrame(part: BasePart, chassis: BasePart): CFrame
	local stored = part:GetAttribute(BASE_CFRAME)
	if typeof(stored) == "CFrame" then
		return stored
	end
	local base = chassis.CFrame:ToObjectSpace(part.CFrame)
	part:SetAttribute(BASE_CFRAME, base)
	return base
end

-- The body offset with any lowering cut short so the lowest Body part's factory bottom stays
-- Config/Customization rideHeight.minClearance above the ground under the wheels (chassis space: each Wheel*
-- hub attachment minus its wheel's radius). Body parts don't collide, so without this a low car's chin and skirts
-- would sink into the road when the suspension compresses. Raising is never limited.
local function clampLowering(model: Model, chassis: BasePart, offset: number): number
	if offset >= 0 then
		return offset
	end
	local wheels = model:FindFirstChild("Wheels")
	local ground = math.huge
	for _, name in WHEEL_NAMES do
		local hub = chassis:FindFirstChild("Wheel" .. name)
		local wheel = if wheels then wheels:FindFirstChild(name) else nil
		if hub and hub:IsA("Attachment") and wheel and wheel:IsA("BasePart") then
			ground = math.min(ground, hub.Position.Y - math.min(wheel.Size.Y, wheel.Size.Z) / 2)
		end
	end
	local lowest = math.huge
	for _, part in partsIn(model, { "Body" }) do
		local base = baseCFrame(part, chassis)
		local half = part.Size / 2
		local reach = math.abs(base.XVector.Y) * half.X
			+ math.abs(base.YVector.Y) * half.Y
			+ math.abs(base.ZVector.Y) * half.Z
		lowest = math.min(lowest, base.Position.Y - reach)
	end
	if ground == math.huge or lowest == math.huge then
		return offset
	end
	local room = math.max(0, lowest - ground - Customization.rideHeight.minClearance)
	return math.max(offset, -room)
end

-- Moves the visual body `offset` studs along the Chassis's up axis from its factory position. Welds to the moved
-- parts are switched off while everything moves and back on after, so each weld records the new offset (moving
-- a welded part with its weld on would drag the whole car along).
local function setRideHeight(model: Model, chassis: BasePart, offset: number)
	local lift = CFrame.new(0, offset, 0) -- chassis space
	local moves: { { part: BasePart, target: CFrame } } = {}
	for _, part in partsIn(model, { "Body", "Lights" }) do
		local target = chassis.CFrame * lift * baseCFrame(part, chassis)
		if (target.Position - part.CFrame.Position).Magnitude > MOVE_EPSILON then
			table.insert(moves, { part = part, target = target })
		end
	end

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
	for _, weld in paused do
		weld.Enabled = true
	end

	-- Doors hang on hinge Motor6Ds whose C0 is in chassis space: shift the hinge and the door follows.
	local doors = model:FindFirstChild("Doors")
	if doors then
		for _, descendant in doors:GetDescendants() do
			if descendant:IsA("Motor6D") and descendant.Name == HINGE_NAME and descendant.Part0 == chassis then
				local stored = descendant:GetAttribute(BASE_C0)
				local base: CFrame = if typeof(stored) == "CFrame" then stored else descendant.C0
				descendant:SetAttribute(BASE_C0, base)
				descendant.C0 = lift * base
			end
		end
	end
end

----------------------------------------------------------------------------------------------------------------
-- Paint, finish, trim and tint
----------------------------------------------------------------------------------------------------------------

-- A part's factory color (and glass transparency), recorded the first time.
function baseColor(part: BasePart): Color3
	local stored = part:GetAttribute(BASE_COLOR)
	if typeof(stored) == "Color3" then
		return stored
	end
	part:SetAttribute(BASE_COLOR, part.Color)
	return part.Color
end

local function baseTransparency(part: BasePart): number
	local stored = part:GetAttribute(BASE_TRANSPARENCY)
	if type(stored) == "number" then
		return stored
	end
	part:SetAttribute(BASE_TRANSPARENCY, part.Transparency)
	return part.Transparency
end

local function paintBody(model: Model, r: Resolved)
	local trimColor = r.wrap.trimColor
	for _, descendant in model:GetDescendants() do
		if not descendant:IsA("BasePart") or isLookPart(descendant) then
			continue
		end
		if CollectionService:HasTag(descendant, "Paint") then
			-- Recorded on every apply, so the first look (whatever paint it has) saves the brand color to go back to.
			local factory = baseColor(descendant)
			descendant.Color = if r.factoryPaint then factory else r.paint
			descendant.Material = r.finish.material
			descendant.Reflectance = r.finish.reflectance
		end
		if CollectionService:HasTag(descendant, "Trim") then
			local factory = baseColor(descendant)
			descendant.Color = trimColor or factory
		end
		if CollectionService:HasTag(descendant, "Glass") then
			local factory, factoryTransparency = baseColor(descendant), baseTransparency(descendant)
			-- The factory level keeps the glass exactly as built; darker levels set their own transparency.
			local factoryLevel = r.tint.darken == 0
			descendant.Transparency = if factoryLevel then factoryTransparency else r.tint.transparency
			descendant.Color = factory:Lerp(BLACK, r.tint.darken)
		end
	end
end

----------------------------------------------------------------------------------------------------------------
-- Wrap vinyl
----------------------------------------------------------------------------------------------------------------

local function isAligned(rel: CFrame): boolean
	for _, axis in { rel.XVector, rel.YVector, rel.ZVector } do
		if math.max(math.abs(axis.X), math.abs(axis.Y), math.abs(axis.Z)) < ALIGNED then
			return false
		end
	end
	return true
end

-- A part's bounding box in chassis space, its CFrame relative to the Chassis, and whether its axes line up
-- with the Chassis's (only aligned boxes have flat faces along the car).
local function panelOf(part: BasePart, chassisCFrame: CFrame): Panel
	local rel = chassisCFrame:ToObjectSpace(part.CFrame)
	local half = part.Size / 2
	local x, y, z = rel.XVector, rel.YVector, rel.ZVector
	local extent = Vector3.new(
		math.abs(x.X) * half.X + math.abs(y.X) * half.Y + math.abs(z.X) * half.Z,
		math.abs(x.Y) * half.X + math.abs(y.Y) * half.Y + math.abs(z.Y) * half.Z,
		math.abs(x.Z) * half.X + math.abs(y.Z) * half.Y + math.abs(z.Z) * half.Z
	)
	return {
		part = part,
		box = { min = rel.Position - extent, max = rel.Position + extent },
		rel = rel,
		aligned = isAligned(rel),
	}
end

-- Removes [cut0, cut1] from a list of disjoint intervals.
local function subtract(intervals: { { number } }, cut0: number, cut1: number): { { number } }
	local result: { { number } } = {}
	for _, span in intervals do
		local a, b = span[1], span[2]
		if cut1 <= a or cut0 >= b then
			table.insert(result, span)
		else
			if cut0 > a then
				table.insert(result, { a, cut0 })
			end
			if cut1 < b then
				table.insert(result, { cut1, b })
			end
		end
	end
	return result
end

-- The stretches of [z0, z1] not covered by another part that contains `probe` in x and y (z is ignored).
local function openSpans(panels: { Panel }, own: BasePart, probe: Vector3, z0: number, z1: number): { { number } }
	local spans: { { number } } = { { z0, z1 } }
	for _, other in panels do
		if other.part == own then
			continue
		end
		local box = other.box
		if probe.X >= box.min.X and probe.X <= box.max.X and probe.Y >= box.min.Y and probe.Y <= box.max.Y then
			spans = subtract(spans, box.min.Z, box.max.Z)
		end
	end
	return spans
end

type WrapBuild = {
	chassis: BasePart,
	folder: Folder,
	count: number,
}

local function addVinyl(build: WrapBuild, size: Vector3, relCFrame: CFrame, color: Color3)
	if build.count >= Customization.wrapMaxParts then
		return
	end
	build.count += 1
	newPart(
		"Part",
		"Wrap",
		size,
		build.chassis.CFrame * relCFrame,
		color,
		Customization.wrapMaterial,
		build.chassis,
		build.folder
	)
end

-- Lays the wrap's bands on the painted panels of the body.
local function buildWrap(model: Model, chassis: BasePart, folder: Folder, wrap: Customization.Wrap)
	if #wrap.bands == 0 then
		return
	end
	local chassisCFrame = chassis.CFrame
	local thickness, proud = Customization.wrapThickness, Customization.wrapProud
	local minWidth, minLength = Customization.wrapMinWidth, Customization.wrapMinSegment
	local probe = Customization.wrapCoverProbe

	-- Panels: painted body parts take vinyl; everything on the body can cover a face. Doors swing, so vinyl
	-- (welded to the Chassis) never goes on them, but they still cover what is under them.
	local body = model:FindFirstChild("Body")
	local covers: { Panel } = {}
	local painted: { Panel } = {}
	local glass: { Panel } = {}
	for _, part in partsIn(model, { "Body", "Lights", "Doors" }) do
		local panel = panelOf(part, chassisCFrame)
		table.insert(covers, panel)
		if body and part:IsDescendantOf(body) and CollectionService:HasTag(part, "Paint") then
			table.insert(painted, panel)
		elseif body and part:IsDescendantOf(body) and CollectionService:HasTag(part, "Glass") then
			table.insert(glass, panel)
		end
	end
	if #painted == 0 then
		return
	end

	-- The roof line: the top of the windows (the lowest top among the glass parts; a glass roof sits above it).
	-- Roof bands (minHeight) go only on parts standing on it, painted or glass (a glass roof takes the vinyl as a
	-- film), so a hood or a ducktail that happens to be high on the body never turns into a roof.
	local roofLine: number? = nil
	for _, panel in glass do
		roofLine = math.min(roofLine or math.huge, panel.box.max.Y)
	end
	local roofPanels: { Panel } = {}
	if roofLine ~= nil then
		for _, list in { painted, glass } do
			for _, panel in list do
				if panel.box.min.Y >= roofLine - Customization.wrapRoofSlack then
					table.insert(roofPanels, panel)
				end
			end
		end
	end

	-- The body's extent from its painted panels: bands are placed in shares of it.
	local bottom, top, halfWidth = math.huge, -math.huge, 0
	for _, panel in painted do
		bottom = math.min(bottom, panel.box.min.Y)
		top = math.max(top, panel.box.max.Y)
		halfWidth = math.max(halfWidth, math.abs(panel.box.min.X), math.abs(panel.box.max.X))
	end
	local height = top - bottom
	if height <= 0 or halfWidth <= 0 then
		return
	end

	local build: WrapBuild = { chassis = chassis, folder = folder, count = 0 }
	for _, band in wrap.bands do
		local roofBand = band.face == "top" and band.minHeight ~= nil and roofLine ~= nil
		for _, panel in if roofBand then roofPanels else painted do
			local part, box = panel.part, panel.box
			if band.face == "top" then
				-- Without windows to find the roof by, a roof band falls back to a share of the body height.
				if not roofBand and (box.max.Y - bottom) / height < (band.minHeight or 0) then
					continue
				end
				local center, width = band.center * halfWidth, band.width * 2 * halfWidth
				local x0 = math.max(center - width / 2, box.min.X)
				local x1 = math.min(center + width / 2, box.max.X)
				if x1 - x0 < minWidth then
					continue
				end
				if part:IsA("WedgePart") then
					-- A slope facing up (hood, nose, ducktail): one stripe the length of the slope. The wedge's
					-- slope runs from its bottom front edge to its top back edge, through its center.
					local rel = panel.rel
					local size = part.Size
					local normal = rel:VectorToWorldSpace(Vector3.new(0, size.Z, -size.Y).Unit)
					if math.abs(rel.XVector.X) < ALIGNED or normal.Y < Customization.wrapSlopeMinUp then
						continue
					end
					local localX = ((x0 + x1) / 2 - rel.Position.X) * rel.XVector.X
					local slopeLength = math.sqrt(size.Y * size.Y + size.Z * size.Z)
					local tilt = -math.atan2(size.Y, size.Z)
					local onSlope = rel
						* CFrame.new(localX, 0, 0)
						* CFrame.Angles(tilt, 0, 0)
						* CFrame.new(0, proud + thickness / 2, 0)
					addVinyl(build, Vector3.new(x1 - x0, thickness, slopeLength), onSlope, band.color)
				elseif panel.aligned and part:IsA("Part") and part.Shape == Enum.PartType.Block then
					local y = box.max.Y
					local spans =
						openSpans(covers, part, Vector3.new((x0 + x1) / 2, y + probe, 0), box.min.Z, box.max.Z)
					for _, span in spans do
						local length = span[2] - span[1]
						if length >= minLength then
							local at = CFrame.new((x0 + x1) / 2, y + proud + thickness / 2, (span[1] + span[2]) / 2)
							addVinyl(build, Vector3.new(x1 - x0, thickness, length), at, band.color)
						end
					end
				end
			elseif panel.aligned and part:IsA("Part") and part.Shape == Enum.PartType.Block then
				-- Side bands run along both flanks at a height.
				local center, width = bottom + band.center * height, band.width * height
				local y0 = math.max(center - width / 2, box.min.Y)
				local y1 = math.min(center + width / 2, box.max.Y)
				if y1 - y0 < minWidth then
					continue
				end
				for _, side in { -1, 1 } do
					local x = if side > 0 then box.max.X else box.min.X
					if x * side < Customization.wrapSideShare * halfWidth then
						continue
					end
					local spans =
						openSpans(covers, part, Vector3.new(x + side * probe, (y0 + y1) / 2, 0), box.min.Z, box.max.Z)
					for _, span in spans do
						local length = span[2] - span[1]
						if length >= minLength then
							local at =
								CFrame.new(x + side * (proud + thickness / 2), (y0 + y1) / 2, (span[1] + span[2]) / 2)
							addVinyl(build, Vector3.new(thickness, y1 - y0, length), at, band.color)
						end
					end
				end
			end
		end
	end
end

----------------------------------------------------------------------------------------------------------------
-- Wheels and calipers
----------------------------------------------------------------------------------------------------------------

-- Rebuilds a wheel's face for the style: rim lip, caliper-colored brake disc, spokes and center cap, each a
-- layer prouder of the tire faces than the last. The wheel part and its Motor stay as they are; the new parts
-- are welded to the wheel, so they spin and steer with it. The disc is round, so its color reads the same at
-- any spin.
local function buildWheel(wheel: BasePart, style: Customization.Wheel, caliper: Customization.Caliper)
	local layers = Customization.wheelLayers
	local diameter = math.min(wheel.Size.Y, wheel.Size.Z)
	local width = wheel.Size.X
	local cframe = wheel.CFrame
	local material = style.material
	newDisc("Rim", width + 2 * layers.rim, diameter * style.rim, cframe, style.rimColor, material, wheel, wheel)
	newDisc(
		"Caliper",
		width + 2 * layers.brake,
		diameter * style.brake,
		cframe,
		caliper.color,
		Enum.Material.SmoothPlastic,
		wheel,
		wheel
	)

	local count = style.spokes
	if count > 0 then
		local spokeWidth = diameter * style.spokeWidth
		local depth = width + 2 * layers.spokes
		local length = diameter * style.spokeLength
		local step = 2 * math.pi / count
		if count % 2 == 0 then
			-- Even counts: bars through the center, each one two opposite spokes.
			for i = 0, count / 2 - 1 do
				local at = cframe * CFrame.Angles(i * step, 0, 0)
				newPart(
					"Part",
					"Spoke",
					Vector3.new(depth, length, spokeWidth),
					at,
					style.spokeColor,
					material,
					wheel,
					wheel
				)
			end
		else
			local radial = length / 2
			for i = 0, count - 1 do
				local at = cframe * CFrame.Angles(i * step, 0, 0) * CFrame.new(0, radial / 2, 0)
				newPart(
					"Part",
					"Spoke",
					Vector3.new(depth, radial, spokeWidth),
					at,
					style.spokeColor,
					material,
					wheel,
					wheel
				)
			end
		end
	end

	newDisc("Cap", width + 2 * layers.cap, diameter * style.cap, cframe, style.capColor, material, wheel, wheel)
end

local function buildWheels(model: Model, r: Resolved)
	local wheels = model:FindFirstChild("Wheels")
	if wheels == nil then
		return
	end
	for _, name in WHEEL_NAMES do
		local wheel = wheels:FindFirstChild(name)
		if wheel and wheel:IsA("BasePart") then
			buildWheel(wheel, r.wheel, r.caliper)
		end
	end
end

----------------------------------------------------------------------------------------------------------------
-- Extras
----------------------------------------------------------------------------------------------------------------

-- The color and material of an extra's piece.
local function pieceLook(color: Customization.ExtraColor, r: Resolved): (Color3, Enum.Material, number)
	local colors = Customization.extraColors
	if color == "paint" then
		return r.paint, r.finish.material, r.finish.reflectance
	elseif color == "trim" then
		return r.wrap.trimColor or colors.trim, Enum.Material.SmoothPlastic, 0
	elseif color == "metal" then
		return colors.metal, Enum.Material.Metal, 0
	elseif color == "lamp" then
		return colors.lamp, Enum.Material.SmoothPlastic, 0
	end
	return colors.dark, Enum.Material.SmoothPlastic, 0
end

-- The height (chassis space) of the highest upright body surface under `point` that is not above it: the top of a
-- block, or the slope of a wedge. nil when no body part lies under it.
local function surfaceUnder(panels: { Panel }, point: Vector3): number?
	local best: number? = nil
	for _, panel in panels do
		local part, rel = panel.part, panel.rel
		if rel.YVector.Y < ALIGNED then
			continue
		end
		local size = part.Size
		local localPoint = rel:PointToObjectSpace(point)
		if math.abs(localPoint.X) > size.X / 2 or math.abs(localPoint.Z) > size.Z / 2 then
			continue
		end
		local y
		if part:IsA("WedgePart") then
			y = localPoint.Z * size.Y / size.Z -- the slope rises from the bottom front edge to the top back edge
		elseif part:IsA("Part") and part.Shape == Enum.PartType.Block then
			y = size.Y / 2
		else
			continue
		end
		local surface = rel:PointToWorldSpace(Vector3.new(localPoint.X, y, localPoint.Z)).Y
		if surface <= point.Y and (best == nil or surface > best) then
			best = surface
		end
	end
	return best
end

-- A foot piece (Config ExtraPiece.foot) keeps its top and reaches down to the body under it, up to
-- Customization.extraFootReach studs, so a rack or light bar on a sloped roof never floats.
local function footFrame(panels: { Panel }, chassis: BasePart, at: CFrame, pieceSize: Vector3): (CFrame, Vector3)
	local rel = chassis.CFrame:ToObjectSpace(at)
	if rel.YVector.Y < ALIGNED then
		return at, pieceSize
	end
	local top = rel.Position + Vector3.yAxis * (pieceSize.Y / 2)
	local surface = surfaceUnder(panels, top)
	local bottom = top.Y - pieceSize.Y
	if surface == nil or surface >= bottom or top.Y - surface > pieceSize.Y + Customization.extraFootReach then
		return at, pieceSize
	end
	local height = top.Y - surface
	local centre = CFrame.new(0, (pieceSize.Y - height) / 2, 0) -- down from the recipe centre, top unchanged
	return at * centre, Vector3.new(pieceSize.X, height, pieceSize.Z)
end

local function buildExtras(model: Model, chassis: BasePart, folder: Folder, r: Resolved)
	local class = r.class
	if class == nil then
		return -- not a catalog car (a player design): extras are sized by class, so none fit yet
	end
	local lift = CFrame.new(0, r.offset, 0) -- extras ride with the body
	local placed = 0
	-- The body as it stands now (after the ride height moved it), for feet to reach down to.
	local panels: { Panel }? = nil
	for _, id in r.look.extras do
		local extra = Customization.getExtra(id)
		local size = if extra then Customization.extraSize(extra, class, r.bodyStyle) else nil
		local mount = chassis:FindFirstChild(if extra then extra.mount else "")
		if extra == nil or size == nil or mount == nil or not mount:IsA("Attachment") then
			continue
		end
		if placed >= Customization.maxExtras then
			break
		end
		placed += 1
		local mountCFrame = chassis.CFrame * lift * mount.CFrame
		local holder = Instance.new("Model")
		holder.Name = `Extra_{extra.id}`
		holder:SetAttribute(EXTRA_ID, extra.id)
		CollectionService:AddTag(holder, Customization.lookTag)
		for _, piece in extra.pieces do
			local color, material, reflectance = pieceLook(piece.color, r)
			local at = mountCFrame * CFrame.new(piece.center * size)
			local pieceSize = piece.size * size
			if piece.foot then
				if panels == nil then
					local list: { Panel } = {}
					for _, bodyPart in partsIn(model, { "Body" }) do
						table.insert(list, panelOf(bodyPart, chassis.CFrame))
					end
					panels = list
				end
				at, pieceSize = footFrame(panels :: { Panel }, chassis, at, pieceSize)
			end
			local part = newPart(
				if piece.shape == "wedge" then "WedgePart" else "Part",
				piece.name,
				pieceSize,
				at,
				color,
				material,
				chassis,
				holder
			)
			part.Reflectance = reflectance
			if piece.shape == "cylinder" then
				(part :: Part).Shape = Enum.PartType.Cylinder
			end
			if piece.light then
				local settings = Customization.extraLight
				local light = Instance.new("PointLight")
				light.Name = "Light"
				light.Enabled = false
				light.Color = settings.color
				light.Brightness = settings.brightness
				light.Range = settings.range
				light.Shadows = false
				light.Parent = part
			end
		end
		holder.Parent = folder
	end
end

----------------------------------------------------------------------------------------------------------------
-- Plates
----------------------------------------------------------------------------------------------------------------

local function plateLabel(name: string, text: string, font: Enum.Font, color: Color3, top: number, height: number)
	local label = Instance.new("TextLabel")
	label.Name = name
	label.BackgroundTransparency = 1
	label.Position = UDim2.fromScale(0, top)
	label.Size = UDim2.fromScale(1, height)
	label.Font = font
	label.Text = text
	label.TextColor3 = color
	label.TextScaled = true
	return label
end

local function buildPlates(chassis: BasePart, folder: Folder, r: Resolved)
	local rules = Customization.plate
	local format = r.plateFormat
	-- Only text the server already filtered ever reaches a plate (see the header); nil = the standard number.
	local text = r.look.plateText or Customization.standardPlateText(format.id, r.look.uid)
	local lift = CFrame.new(0, r.offset, 0)
	for _, pointName in PLATE_POINTS do
		local point = chassis:FindFirstChild(pointName)
		if point == nil or not point:IsA("Attachment") then
			continue
		end
		-- The attachment looks out of the bumper; the plate's front face (-Z) does too, its back on the bumper.
		local at = chassis.CFrame * lift * point.CFrame * CFrame.new(0, 0, -rules.size.Z / 2)
		local plate =
			newPart("Part", pointName, rules.size, at, format.background, Enum.Material.SmoothPlastic, chassis, folder)
		plate.CastShadow = false

		local gui = Instance.new("SurfaceGui")
		gui.Name = "PlateGui"
		gui.Face = Enum.NormalId.Front
		gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
		gui.PixelsPerStud = rules.pixelsPerStud
		gui.LightInfluence = 1
		plateLabel("Caption", format.caption, rules.captionFont, format.text, 0, rules.captionShare).Parent = gui
		plateLabel("Number", text, rules.font, format.text, rules.captionShare, 1 - rules.captionShare).Parent = gui
		gui.Parent = plate
	end
end

----------------------------------------------------------------------------------------------------------------
-- API
----------------------------------------------------------------------------------------------------------------

-- Sets `model`'s look. Safe to call again with the same or another look: the result depends only on the
-- model's factory state and `look`. Does nothing to a model without a Chassis.
function Appearance.apply(model: Model, look: Look)
	local chassis = model:FindFirstChild("Chassis")
	if chassis == nil or not chassis:IsA("BasePart") then
		return
	end
	local r = resolve(model, look)
	r.offset = clampLowering(model, chassis, r.offset)

	clear(model)
	setRideHeight(model, chassis, r.offset)
	paintBody(model, r)

	local folder = lookFolder(model)
	buildWrap(model, chassis, folder, r.wrap)
	buildWheels(model, r)
	buildExtras(model, chassis, folder, r)
	buildPlates(chassis, folder, r)

	model:SetAttribute(LOOK_DATA, HttpService:JSONEncode(r.look))
end

-- The body offset (studs) a ride height gives on this model: Config/Customization.rideOffset for its class,
-- with lowering cut short where the car would lose its ground clearance (see clampLowering).
function Appearance.bodyOffset(model: Model, rideHeight: number): number
	local offset = Customization.rideOffset(rideHeight, classOf(model))
	local chassis = model:FindFirstChild("Chassis")
	if chassis == nil or not chassis:IsA("BasePart") then
		return offset
	end
	return clampLowering(model, chassis, offset)
end

-- The look last applied to `model` (complete, with defaults filled in), or nil if none was. The shop's preview
-- reverts with Appearance.apply(model, Appearance.lookOf(model)). Plate text in it is already filtered.
function Appearance.lookOf(model: Model): Look?
	local data = model:GetAttribute(LOOK_DATA)
	if type(data) ~= "string" then
		return nil
	end
	local ok, decoded = pcall(function()
		return HttpService:JSONDecode(data)
	end)
	if not ok or type(decoded) ~= "table" then
		return nil
	end
	return complete(decoded :: any)
end

-- The Model an extra was built as on `model` (its parts, and a PointLight named Light on lamp pieces), or nil
-- when the car doesn't have that extra.
function Appearance.findExtra(model: Model, extraId: string): Model?
	local folder = model:FindFirstChild(LOOK_FOLDER)
	local holder = if folder then folder:FindFirstChild(`Extra_{extraId}`) else nil
	return if holder and holder:IsA("Model") then holder else nil
end

return Appearance
