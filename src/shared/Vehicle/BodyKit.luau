--!strict
-- The greybox body kit (PLAN.md §6, docs/phase-1-contracts.md "Vehicle model contract", docs/phase-11-contracts.md
-- "Kit"): the generic bodies by bodyStyle (STYLE_BUILDERS), wheels, seats, lamps, the contract attachments and the
-- contract check, as a runtime module. Read by Dev/VehicleBuilder (the catalog's greybox models, built in Edit mode,
-- with the Ohm cars' bespoke silhouettes on top of these helpers), Vehicle/SpecBuilder (player designs, built at
-- runtime on the server and on clients for previews) and Vehicle/ModBuilder (AI mods).
--
-- API
--   assemble(vehicle, trim, geometry, options)       a contract model, not parented and not checked
--   check(model, vehicle, trim, geometry, name)       every way a model breaks the contract (empty = good)
--   genericShape(bodyStyle), bodyStyles()             the generic body builders
--   tintPaint(model, brandId)                         a brand's default greybox paint
--   paint(model, primary, secondary, finish?)         a design's two-tone paint (secondary: roof panels)
--   addSpoiler(model, variant), addStripes(model, kind, color, budget?)
--                                                     the kit's spoiler and stripe parts, on any contract model
--   readGeometry(model)                               the physics geometry a built model has (chassis and wheels)
--   the part helpers the bespoke silhouettes use (box, wedge, lamp, ...) and DETAIL, SIDES, SEATED_HEAD_ROOM
--
-- Catalog cars never pass `design` to assemble, so their bodies are exactly the brand builds: the design variants
-- (Config/DesignKit.json parts: bumpers, lamps, nose slope) only run for player designs. Nothing here is Studio-only.
--
-- Shapes are authored in "ground space": the origin is the point on the ground under the chassis center, +X is
-- right, +Y is up and the front of the car is -Z (the chassis LookVector). The model's pivot is that ground point,
-- so model:PivotTo(groundCFrame) parks the car at ride height. The numbers inside each shape function are the
-- greybox art itself (panel positions in studs), not gameplay tunables.

local CollectionService = game:GetService("CollectionService")

local Shared = script.Parent.Parent
local Driving = require(Shared.Config.Driving)
local Trailers = require(Shared.Config.Trailers)
local Vehicles = require(Shared.Config.Vehicles)

local MAX_PARTS = require(Shared.Config.Perf).parts.model -- the part budget per model (Config/Perf)

-- Chassis surface (model contract). The suspension is raycast, so the box only touches the world in a crash or
-- a rollover. Its density comes from Config/Driving.chassisDensity.
local CHASSIS_FRICTION = 0.3
local CHASSIS_ELASTICITY = 0

-- Wheel arches: the opening runs this far past the tire front and back, and this far above its top.
local ARCH_CLEARANCE = 0.25
local ARCH_TOP_CLEARANCE = 0.06
-- Every generic body needs at least this much height over the arch tops for a beltline, glass and a roof (it
-- asserts so). Vehicle/SpecBuilder never makes a design lower than this.
local MIN_ROOM_OVER_ARCHES = 0.8
-- The dark wheel-well block between the wheels stops this far inside the tires' inner faces.
local WELL_GAP = 0.05

-- Each wheel is a tire (the wheel part itself) carrying a lighter rim disc and one dark spoke bar, so spin is
-- visible. Both are welded to the wheel, so they spin and steer with it.
local RIM_RATIO = 0.62 -- rim diameter / tire diameter
local SPOKE_RATIO = 0.56 -- spoke length / tire diameter
local SPOKE_THICKNESS_RATIO = 0.18 -- spoke thickness / tire radius
local HUB_PROUD = 0.03 -- rim and spoke stand this far out of each tire face

local SEAT_SIZE = Vector3.new(1.7, 0.2, 1.7)
-- Seat surface to the top of a seated default avatar's head. Cabins put the seat this far under the roof.
local SEATED_HEAD_ROOM = 3.3
-- How many seats go in each row, front to back, for a given seat count. The first seat is the left front.
local ROW_PLANS: { [number]: { number } } = {
	[1] = { 1 },
	[2] = { 2 },
	[3] = { 2, 1 },
	[4] = { 2, 2 },
	[5] = { 2, 3 },
	[6] = { 2, 2, 2 },
	[7] = { 2, 2, 3 },
	[8] = { 2, 3, 3 },
}

-- Small details shared by every silhouette, in studs.
local DETAIL = {
	proud = 0.04, -- trim, lamps and strips stand this far proud of the panel they sit on
	inset = 0.1, -- chins and similar trim sit this far inside the body outline
	wellLift = 0.1, -- wheel-well block bottom above the body bottom
	bumperHeight = 0.6,
	bumperDepth = 0.5,
	lampWidth = 1.0, -- headlamp width (the running-light strip spans between the headlamps)
	lampHeight = 0.28,
	tailWidth = 0.95, -- tail lamp width (the brake strip spans between the tail lamps)
	tailHeight = 0.32,
	stripHeight = 0.08, -- neon running-light strip
	brakeHeight = 0.12,
	reverseHalfWidth = 0.35,
	reverseHeight = 0.2,
	reverseLift = 0.08, -- reverse lamp bottom above the bumper top
	intakeWidthRatio = 0.7, -- lower front intake width / body width
	intakeLift = 0.12, -- intake bottom above the chin top
	intakeHeight = 0.38,
	mirrorReach = 0.35,
	mirrorHeight = 0.3,
	mirrorDepth = 0.35,
	mirrorLift = 0.08, -- mirror bottom above the beltline
	mirrorBack = 0.2, -- mirror front edge behind the windshield base
	pillarWidth = 0.24,
	roofInset = 0.1, -- roof panel inset from the greenhouse sides
	roofOverhang = 0.1, -- roof panel overhang past the glass, front and back
	railInner = 0.45, -- roof rails run between these insets from the roof edge
	railOuter = 0.25,
	railEndInset = 0.25,
	hoodCamBack = 0.8, -- CameraHood sits this far ahead of the windshield base...
	hoodCamHeight = 0.45, -- ...and this far above the hood
	spoilerInset = 0.4, -- Mount_Spoiler sits this far forward of the back end
}

export type Look =
	"paint"
	| "trim"
	| "glass"
	| "dark"
	| "neon"
	| "seat"
	| "tire"
	| "rim"
	| "spoke"
	| "headLamp"
	| "tailLamp"
	| "brakeLamp"
	| "reverseLamp"
	| "bright"
	| "beacon"

type LookStyle = { color: Color3, material: Enum.Material, transparency: number, tag: string? }

local SMOOTH = Enum.Material.SmoothPlastic

local LOOKS: { [Look]: LookStyle } = {
	-- Body color: a neutral light silver until customization (Phase 7) repaints everything tagged Paint.
	paint = { color = Color3.fromRGB(198, 202, 207), material = SMOOTH, transparency = 0, tag = "Paint" },
	-- Accents (bumpers, cladding, mirrors, pillars): customization recolors everything tagged Trim.
	trim = { color = Color3.fromRGB(40, 42, 46), material = SMOOTH, transparency = 0, tag = "Trim" },
	-- Windows: customization sets the tint of everything tagged Glass.
	glass = { color = Color3.fromRGB(26, 34, 44), material = Enum.Material.Glass, transparency = 0.35, tag = "Glass" },
	dark = { color = Color3.fromRGB(18, 18, 20), material = SMOOTH, transparency = 0 }, -- wheel wells, frame
	neon = { color = Color3.fromRGB(226, 240, 255), material = Enum.Material.Neon, transparency = 0 }, -- strips only
	seat = { color = Color3.fromRGB(46, 48, 54), material = SMOOTH, transparency = 0 },
	tire = { color = Color3.fromRGB(28, 28, 30), material = SMOOTH, transparency = 0 },
	rim = { color = Color3.fromRGB(150, 154, 160), material = SMOOTH, transparency = 0 },
	spoke = { color = Color3.fromRGB(64, 66, 72), material = SMOOTH, transparency = 0 },
	headLamp = { color = Color3.fromRGB(234, 236, 228), material = SMOOTH, transparency = 0 },
	tailLamp = { color = Color3.fromRGB(112, 14, 18), material = SMOOTH, transparency = 0 },
	brakeLamp = { color = Color3.fromRGB(140, 16, 22), material = SMOOTH, transparency = 0 },
	reverseLamp = { color = Color3.fromRGB(214, 216, 220), material = SMOOTH, transparency = 0 },
	-- Bright metal trim: classic bumpers and Aldermoor's front crest (generic bodies only).
	bright = { color = Color3.fromRGB(212, 216, 220), material = Enum.Material.Metal, transparency = 0 },
	-- Amber beacon bars on Northline work trucks (generic bodies only).
	beacon = { color = Color3.fromRGB(255, 168, 40), material = Enum.Material.Neon, transparency = 0 },
}

type LampKind = "head" | "tail" | "brake" | "reverse"

type LampStyle = {
	look: Look,
	color: Color3,
	face: Enum.NormalId,
	brightness: number,
	range: number,
	angle: number,
}

-- Every lamp holds a SpotLight named Light, off until DriveController (or night lighting) turns it on.
local LAMPS: { [LampKind]: LampStyle } = {
	head = {
		look = "headLamp",
		color = Color3.fromRGB(255, 248, 232),
		face = Enum.NormalId.Front,
		brightness = 3,
		range = 45,
		angle = 70,
	},
	tail = {
		look = "tailLamp",
		color = Color3.fromRGB(255, 36, 36),
		face = Enum.NormalId.Back,
		brightness = 1,
		range = 8,
		angle = 120,
	},
	brake = {
		look = "brakeLamp",
		color = Color3.fromRGB(255, 30, 30),
		face = Enum.NormalId.Back,
		brightness = 3,
		range = 12,
		angle = 120,
	},
	reverse = {
		look = "reverseLamp",
		color = Color3.fromRGB(245, 245, 255),
		face = Enum.NormalId.Back,
		brightness = 2,
		range = 16,
		angle = 90,
	},
}

local LIGHT_NAMES = { "HeadL", "HeadR", "TailL", "TailR", "Brake", "Reverse" }

-- A WedgePart with no rotation is tall at the back (+Z) with its slope facing forward and up. The other three
-- slopes are half-turns of it, so a wedge's local size always matches the ground-space box it fills.
type Slope = "riseBack" | "riseFront" | "underFront" | "underBack"
local SLOPES: { [Slope]: CFrame } = {
	riseBack = CFrame.identity, -- low at the front, high at the back: hoods, windshields
	riseFront = CFrame.Angles(0, math.pi, 0), -- high at the front, low at the back: rear glass, sails
	underFront = CFrame.Angles(0, 0, math.pi), -- flat top, underside rising toward the front: chins
	underBack = CFrame.Angles(math.pi, 0, 0), -- flat top, underside rising toward the back: diffusers
}

-- Cylinders run along their local X axis; these turn them to run along Y or Z instead.
type Axis = "x" | "y" | "z"
local AXES: { [Axis]: CFrame } = {
	x = CFrame.identity,
	y = CFrame.Angles(0, 0, math.pi / 2),
	z = CFrame.Angles(0, math.pi / 2, 0),
}

-- Attachment orientations. Plates, bumper and side mounts and thrusters look out of the surface they sit on
-- (a thruster looks the way its exhaust leaves); everything else keeps the chassis orientation.
export type Facing = "forward" | "back" | "left" | "right" | "down"
local FACINGS: { [Facing]: CFrame } = {
	forward = CFrame.identity,
	back = CFrame.Angles(0, math.pi, 0),
	left = CFrame.Angles(0, math.pi / 2, 0),
	right = CFrame.Angles(0, -math.pi / 2, 0),
	down = CFrame.Angles(-math.pi / 2, 0, 0),
}

-- Attachments every model has, plus the ones a vehicle feature adds (model contract). TowPoint (Phase 8,
-- docs/phase-8-contracts.md) is where a pickup's or tow truck's TowHitch lifts the car when it is towed; the
-- shapes don't place it, towPointOf does, the same way for every car.
local TOW_POINT = "TowPoint"
local REQUIRED_POINTS = {
	"PlateFront",
	"PlateRear",
	"CameraHood",
	"Mount_Roof",
	"Mount_Hood",
	"Mount_Spoiler",
	"Mount_FrontBumper",
	"Mount_RearBumper",
	"Mount_SideL",
	"Mount_SideR",
	TOW_POINT,
}
local FEATURE_POINTS: { [string]: { string } } = {
	towHitch = { "TowHitch" },
	kingpin = { "Kingpin" },
	thrusters = { "Thruster_L", "Thruster_R", "Thruster_Down" },
}
-- The attachments that only place visual things (plates, the hood camera, extras), which a kit mod may move to a
-- re-proportioned body (Vehicle/ModBuilder). The rest (wheel hubs, TowPoint, feature points) are physics.
local VISUAL_POINTS = {
	"PlateFront",
	"PlateRear",
	"CameraHood",
	"Mount_Roof",
	"Mount_Hood",
	"Mount_Spoiler",
	"Mount_FrontBumper",
	"Mount_RearBumper",
	"Mount_SideL",
	"Mount_SideR",
}

type WheelSpec = { name: string, side: number, axle: number }
local WHEELS: { WheelSpec } = {
	{ name = "FL", side = -1, axle = -1 },
	{ name = "FR", side = 1, axle = -1 },
	{ name = "RL", side = -1, axle = 1 },
	{ name = "RR", side = 1, axle = 1 },
}

local SIDES = { { sign = -1, suffix = "L" }, { sign = 1, suffix = "R" } }

export type Point = { position: Vector3, facing: Facing } -- ground space
export type Seating = {
	y: number, -- seat surface height above the ground
	rows: { number }, -- z of each seat row, front row first
	spread2: number, -- seat x offset in a two-across row (a one-seat row uses the left position)
	spread3: number, -- x offset of the outer seats in a three-across row
}
export type Shape = { seating: Seating, points: { [string]: Point } }

-- A player design's choices a generic body builds with (Vehicle/SpecBuilder; Config/DesignKit.json "parts" ids).
-- Catalog cars never have one.
export type Design = {
	frontBumper: string, -- "clean" | "sport" | "rugged" | "aero"
	rearBumper: string, -- "clean" | "sport" | "rugged" | "diffuser"
	lights: string, -- "slim" | "round" | "bar" | "split"
	noseSlope: number, -- 0 a blunt upright nose .. 0.5 the style's own .. 1 a long sloped hood
}

export type Ctx = {
	vehicle: Vehicles.Vehicle,
	trim: Vehicles.Trim,
	g: Vehicles.Geometry,
	model: Model,
	chassis: Part,
	chassisY: number, -- ground-space height of the chassis center
	body: Folder,
	wheels: Folder,
	seats: Folder,
	lights: Folder,
	doors: Folder?, -- created on demand: only vehicles with doors get the folder
	design: Design?, -- a player design (SpecBuilder); nil builds the brand look
}

-- Lengthwise landmarks every silhouette is built around.
export type Frame = {
	front: number, -- z of the front end
	back: number, -- z of the back end
	halfWidth: number,
	frontArchFront: number, -- wheel arch openings along z
	frontArchBack: number,
	rearArchFront: number,
	rearArchBack: number,
	archTop: number, -- top of the arch openings
	wellHalfWidth: number, -- half-width of the dark wheel-well block between the wheels
}

local BodyKit = {}

----------------------------------------------------------------------------------------------------------------
-- Part helpers
----------------------------------------------------------------------------------------------------------------

local function frameOf(g: Vehicles.Geometry): Frame
	local archHalf = g.wheelRadius + ARCH_CLEARANCE
	local frontAxle, rearAxle = -g.wheelbase / 2, g.wheelbase / 2
	return {
		front = -g.length / 2,
		back = g.length / 2,
		halfWidth = g.width / 2,
		frontArchFront = frontAxle - archHalf,
		frontArchBack = frontAxle + archHalf,
		rearArchFront = rearAxle - archHalf,
		rearArchBack = rearAxle + archHalf,
		archTop = 2 * g.wheelRadius + ARCH_TOP_CLEARANCE,
		wellHalfWidth = g.track / 2 - g.wheelWidth / 2 - WELL_GAP,
	}
end

-- Applies a look plus the contract's rules for visual parts: massless, unanchored, and invisible to
-- collisions, touches and raycasts. Only the chassis is a physics body.
local function dress(part: BasePart, look: Look)
	local style = LOOKS[look]
	part.Color = style.color
	part.Material = style.material
	part.Transparency = style.transparency
	part.Anchored = false
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.Massless = true
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	if style.tag then
		CollectionService:AddTag(part, style.tag)
	end
end

local function weld(anchor: BasePart, part: BasePart)
	local joint = Instance.new("WeldConstraint")
	joint.Part0 = anchor
	joint.Part1 = part
	joint.Parent = part
end

-- The center and size of a ground-space box given by its extents on each axis (in either order).
local function region(x0: number, x1: number, y0: number, y1: number, z0: number, z1: number): (CFrame, Vector3)
	local center = CFrame.new((x0 + x1) / 2, (y0 + y1) / 2, (z0 + z1) / 2)
	return center, Vector3.new(math.abs(x1 - x0), math.abs(y1 - y0), math.abs(z1 - z0))
end

-- A dressed block filling a ground-space box. Not welded or parented.
local function newBlock(
	name: string,
	look: Look,
	x0: number,
	x1: number,
	y0: number,
	y1: number,
	z0: number,
	z1: number
): Part
	local part = Instance.new("Part")
	local cframe, size = region(x0, x1, y0, y1, z0, z1)
	part.Name = name
	part.Size = size
	part.CFrame = cframe
	dress(part, look)
	return part
end

-- A body block welded to the chassis.
local function box(
	ctx: Ctx,
	name: string,
	look: Look,
	x0: number,
	x1: number,
	y0: number,
	y1: number,
	z0: number,
	z1: number
): Part
	local part = newBlock(name, look, x0, x1, y0, y1, z0, z1)
	weld(ctx.chassis, part)
	part.Parent = ctx.body
	return part
end

-- A mirrored pair of body blocks: <name>L spans x from -outer to -inner, <name>R from inner to outer.
local function pairBox(
	ctx: Ctx,
	name: string,
	look: Look,
	inner: number,
	outer: number,
	y0: number,
	y1: number,
	z0: number,
	z1: number
)
	box(ctx, name .. "L", look, -outer, -inner, y0, y1, z0, z1)
	box(ctx, name .. "R", look, inner, outer, y0, y1, z0, z1)
end

-- A body wedge filling a ground-space box, sloped one of the four ways in SLOPES.
local function wedge(
	ctx: Ctx,
	name: string,
	look: Look,
	slope: Slope,
	x0: number,
	x1: number,
	y0: number,
	y1: number,
	z0: number,
	z1: number
): WedgePart
	local part = Instance.new("WedgePart")
	local cframe, size = region(x0, x1, y0, y1, z0, z1)
	part.Name = name
	part.Size = size
	part.CFrame = cframe * SLOPES[slope]
	dress(part, look)
	weld(ctx.chassis, part)
	part.Parent = ctx.body
	return part
end

-- A body cylinder running along `axis`.
local function cylinder(
	ctx: Ctx,
	name: string,
	look: Look,
	axis: Axis,
	center: Vector3,
	diameter: number,
	length: number
): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Shape = Enum.PartType.Cylinder
	part.Size = Vector3.new(length, diameter, diameter)
	part.CFrame = CFrame.new(center) * AXES[axis]
	dress(part, look)
	weld(ctx.chassis, part)
	part.Parent = ctx.body
	return part
end

-- A lamp in the Lights folder, holding a disabled SpotLight named Light.
local function lamp(
	ctx: Ctx,
	name: string,
	kind: LampKind,
	x0: number,
	x1: number,
	y0: number,
	y1: number,
	z0: number,
	z1: number
): Part
	local style = LAMPS[kind]
	local part = box(ctx, name, style.look, x0, x1, y0, y1, z0, z1)
	part.Parent = ctx.lights
	local light = Instance.new("SpotLight")
	light.Name = "Light"
	light.Enabled = false
	light.Color = style.color
	light.Brightness = style.brightness
	light.Range = style.range
	light.Angle = style.angle
	light.Face = style.face
	light.Shadows = false
	light.Parent = part
	return part
end

-- A mirrored pair of lamps: <name>L and <name>R.
local function pairLamp(
	ctx: Ctx,
	name: string,
	kind: LampKind,
	inner: number,
	outer: number,
	y0: number,
	y1: number,
	z0: number,
	z1: number
)
	lamp(ctx, name .. "L", kind, -outer, -inner, y0, y1, z0, z1)
	lamp(ctx, name .. "R", kind, inner, outer, y0, y1, z0, z1)
end

local function doorsFolder(ctx: Ctx): Folder
	local existing = ctx.doors
	if existing then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = "Doors"
	folder.Parent = ctx.model
	ctx.doors = folder
	return folder
end

-- Hangs a door on the chassis with a Motor6D named Hinge: C0 is the hinge in chassis space and C1 the same
-- point in the door's space, both aligned with the chassis axes, so the hinge line runs along Z. Opening is
--   door.Hinge.Transform = CFrame.Angles(0, 0, math.rad(door:GetAttribute("OpenAngle")) * t)   -- t = 0..1
local function hang(ctx: Ctx, door: BasePart, hinge: Vector3, openAngle: number)
	local motor = Instance.new("Motor6D")
	motor.Name = "Hinge"
	motor.Part0 = ctx.chassis
	motor.Part1 = door
	motor.C0 = CFrame.new(hinge - Vector3.new(0, ctx.chassisY, 0))
	motor.C1 = door.CFrame:ToObjectSpace(CFrame.new(hinge))
	motor.Parent = door
	door:SetAttribute("OpenAngle", openAngle)
	door.Parent = doorsFolder(ctx)
end

local function at(x: number, y: number, z: number, facing: Facing?): Point
	return { position = Vector3.new(x, y, z), facing = facing or "forward" }
end

----------------------------------------------------------------------------------------------------------------
-- Generic bodies by bodyStyle (Phase 4). Every vehicle without a bespoke silhouette is built from its
-- bodyStyle and geometry, with its brand's face, tail lamps and default paint, so styles and brands read apart
-- at a glance. Proportions are shares of the vehicle's own geometry, so one builder fits every size.
----------------------------------------------------------------------------------------------------------------

-- Proportions shared by the generic bodies, in studs unless noted.
local GENERIC = {
	skirtDrop = 0.15, -- the body's bottom edge hangs this far below the chassis box
	minBodyBottom = 0.3,
	chin = 0.3, -- chamfered chin under the nose
	noseCap = 0.7, -- the vertical nose face stops this far below the hood front; a chamfer covers the rest
	minNose = 0.4, -- the vertical nose face is at least this tall
	minBeltAboveArch = 0.3, -- the beltline clears the wheel-arch tops by at least this much
	hoodClear = 0.05, -- the hood front clears the arch tops by this much
	cowlGap = 0.05, -- the windshield base sits at least this far behind the front arch
	minRake = 0.8, -- the windshield is at least this long, front to back
	minRearGlass = 0.3, -- the rear glass is at least this long, front to back
	minCabin = 1.0, -- the roof is at least this long
	roofThickness = 0.25,
	railRoom = 0.15, -- roof drop that leaves room for roof rails
	rackRoom = 0.35, -- roof drop that leaves room for a ladder rack
	firstRowBack = 0.4, -- the first seat row sits this far behind the roof front edge
	rowSpacing = 2.6, -- seat rows are this far apart when the cabin is long enough...
	minRowSpacing = 1.4, -- ...and never closer than this
	rowRoofMargin = 0.2, -- the last row stays this far ahead of the roof's rear edge
	seatBelowBelt = 0.3, -- seats sit at least this far under the beltline (tall vehicles)
	seatAboveBottom = 0.15, -- and at least this far above the body bottom (low ones)
	spread2Ratio = 0.2, -- seat x offset in a two-across row, as a share of the body width
	spread3Ratio = 0.27, -- outer seat x offset in a three-across row, as a share of the body width
}

-- Front faces (lamp and grille layouts). Every face makes HeadL and HeadR.
type Face = "strip" | "rounded" | "stacked" | "blade" | "slit" | "grille" | "utility"

type BrandLook = {
	paint: Color3, -- default color of everything tagged Paint (customization repaints it later)
	face: Face,
	tailWidth: number, -- tail lamp size, studs
	tailHeight: number,
}

-- Each brand's greybox look (docs/ART_BRIEF.md §6). Ohm keeps the neutral silver its silhouettes always had.
local BRAND_LOOKS: { [string]: BrandLook } = {
	ohm = { paint = LOOKS.paint.color, face = "strip", tailWidth = DETAIL.tailWidth, tailHeight = DETAIL.tailHeight },
	-- Soft blue; friendly square lamps over a two-tone bumper.
	halden = { paint = Color3.fromRGB(148, 178, 206), face = "rounded", tailWidth = 0.8, tailHeight = 0.55 },
	-- Olive; tall stacked lamp pods, a big grille, vertical tail lamps.
	ironwood = { paint = Color3.fromRGB(92, 108, 80), face = "stacked", tailWidth = 0.45, tailHeight = 1.0 },
	-- Deep navy; one slim lamp blade with a bright crest, slim vertical tail lamps.
	aldermoor = { paint = Color3.fromRGB(48, 56, 76), face = "blade", tailWidth = 0.3, tailHeight = 0.85 },
	-- Signal yellow; thin angular lamps, a splitter.
	kaze = { paint = Color3.fromRGB(232, 194, 60), face = "slit", tailWidth = 1.1, tailHeight = 0.24 },
	-- Muscle red; a wide bar grille with the lamps set in its ends, big simple tail lamps.
	brannock = { paint = Color3.fromRGB(168, 38, 34), face = "grille", tailWidth = 1.2, tailHeight = 0.45 },
	-- Burnt orange; slit lamps, very thin tail lamps.
	montevale = { paint = Color3.fromRGB(214, 104, 28), face = "slit", tailWidth = 1.4, tailHeight = 0.14 },
	-- Fleet white with a dark livery stripe; square lamps, tall corner tail lamps.
	northline = { paint = Color3.fromRGB(236, 236, 228), face = "utility", tailWidth = 0.45, tailHeight = 1.1 },
}
-- A brand with no entry yet (a newly licensed brand) builds in plain silver with rounded lamps.
local DEFAULT_LOOK: BrandLook = { paint = LOOKS.paint.color, face = "rounded", tailWidth = 0.8, tailHeight = 0.5 }

local function brandLook(brandId: string): BrandLook
	return BRAND_LOOKS[brandId] or DEFAULT_LOOK
end

-- Classics (sold on the used lot) get bright bumpers and no modern aero pieces.
local function isClassic(ctx: Ctx): boolean
	return ctx.vehicle.trims[1].acquisition == "usedLot"
end

local function bodyBottom(g: Vehicles.Geometry): number
	return math.max(GENERIC.minBodyBottom, g.rideHeight - GENERIC.skirtDrop)
end

-- The beltline: `share` of the way from the arch tops up to the roof's underside, always clearing the arches.
local function beltAt(f: Frame, roofBottom: number, share: number): number
	return f.archTop + math.max(GENERIC.minBeltAboveArch, share * (roofBottom - f.archTop))
end

-- The hood's height over the front arch: `rise` of the way from just over the arch tops up to the beltline.
local function hoodFrontAt(f: Frame, belt: number, rise: number): number
	local low = f.archTop + GENERIC.hoodClear
	return low + rise * math.max(0, belt - low)
end

-- A style's hood rise for this car. A design's noseSlope moves it from fully raised (0, a blunt upright nose)
-- through the style's own (0.5) to fully dropped (1, a long sloped hood); catalog cars keep the style's own.
local function hoodRiseFor(ctx: Ctx, rise: number): number
	local design = ctx.design
	if design == nil then
		return rise
	end
	local slope = math.clamp(design.noseSlope, 0, 1)
	if slope < 0.5 then
		return rise + (1 - rise) * (0.5 - slope) * 2
	end
	return rise * (1 - (slope - 0.5) * 2)
end

local function noseTopAt(chinTop: number, hoodFront: number): number
	return math.max(chinTop + GENERIC.minNose, hoodFront - GENERIC.noseCap)
end

-- The hood surface height at z: a straight slope from the front arch up to the windshield base.
local function hoodLine(af0: number, cowlZ: number, hoodFront: number, belt: number): (number) -> number
	return function(z: number): number
		return hoodFront + (belt - hoodFront) * math.clamp((z - af0) / (cowlZ - af0), 0, 1)
	end
end

local function rowCount(ctx: Ctx): number
	local plan = ROW_PLANS[ctx.trim.seats]
	return if plan then #plan else 1 -- addSeats reports a seat count with no layout
end

-- Seat rows from `first` toward `last`, rowSpacing apart, squeezed (down to minRowSpacing) to fit.
local function seatRows(first: number, last: number, count: number): { number }
	local spacing = GENERIC.rowSpacing
	if count > 1 then
		spacing = math.clamp((last - first) / (count - 1), GENERIC.minRowSpacing, GENERIC.rowSpacing)
	end
	local rows = {}
	for index = 0, count - 1 do
		table.insert(rows, first + index * spacing)
	end
	return rows
end

-- Seats put a seated avatar's head just under the roof, but never sink below the body or perch over the belt.
local function seatingFor(ctx: Ctx, bb: number, belt: number, roofBottom: number, first: number, last: number): Seating
	local y =
		math.max(bb + GENERIC.seatAboveBottom, math.min(roofBottom - SEATED_HEAD_ROOM, belt - GENERIC.seatBelowBelt))
	local width = ctx.g.width
	return {
		y = y,
		rows = seatRows(first, last, rowCount(ctx)),
		spread2 = width * GENERIC.spread2Ratio,
		spread3 = width * GENERIC.spread3Ratio,
	}
end

-- A slim beam between two ground-space points that share an x (a tow boom), welded to the chassis. It is
-- pitched about X so its length runs along its local Z axis (rotating Z by `pitch` gives (0, -sin, cos)).
local function strut(ctx: Ctx, name: string, look: Look, from: Vector3, to: Vector3, thickness: number): Part
	local span = to - from
	local part = Instance.new("Part")
	part.Name = name
	part.Size = Vector3.new(thickness, thickness, span.Magnitude)
	part.CFrame = CFrame.new((from + to) / 2) * CFrame.Angles(math.atan2(-span.Y, span.Z), 0, 0)
	dress(part, look)
	weld(ctx.chassis, part)
	part.Parent = ctx.body
	return part
end

local function mirrorPair(ctx: Ctx, hw: number, y0: number, y1: number, z: number, reach: number)
	pairBox(ctx, "Mirror", "trim", hw, hw + reach, y0, y1, z, z + DETAIL.mirrorDepth)
end

-- The front of every generic body: the wheel-well block, chin, vertical nose face, a chamfer up to the hood
-- front, a front fender over the arch when the hood stands above it, and the hood sloping up to the beltline.
local function noseAndHood(
	ctx: Ctx,
	f: Frame,
	bb: number,
	chinTop: number,
	noseTop: number,
	hoodFront: number,
	belt: number,
	cowlZ: number
)
	local hw, front, af0, af1 = f.halfWidth, f.front, f.frontArchFront, f.frontArchBack
	local inset = DETAIL.inset
	box(
		ctx,
		"WheelWells",
		"dark",
		-f.wellHalfWidth,
		f.wellHalfWidth,
		bb + DETAIL.wellLift,
		f.archTop,
		af0,
		f.rearArchBack
	)
	wedge(ctx, "Chin", "trim", "underFront", -hw + inset, hw - inset, bb, chinTop, front + inset, af0)
	box(ctx, "Nose", "paint", -hw, hw, chinTop, noseTop, front, af0)
	wedge(ctx, "NoseCap", "paint", "riseBack", -hw, hw, noseTop, hoodFront, front, af0)
	if hoodFront > f.archTop + 2 * GENERIC.hoodClear then
		box(ctx, "FenderF", "paint", -hw, hw, f.archTop, hoodFront, af0, af1)
	end
	wedge(ctx, "Hood", "paint", "riseBack", -hw, hw, hoodFront, belt, af0, cowlZ)
end

-- Front faces ------------------------------------------------------------------------------------------------

local FACE = {
	bumperRise = 0.3, -- bumper top above the chin top
	bumperReach = 0.2, -- bumper front face ahead of the nose (work faces reach further)
	workReach = 0.3,
	bumperDepth = 0.5, -- the bumper runs this far back into the nose
	lampGap = 0.08, -- lamps keep this far from the bumper top and the nose top
	cornerInset = 0.12, -- lamps stop this far inside the body sides
}

type FrontInfo = { z: number, hw: number, bb: number, chinTop: number, noseTop: number, classic: boolean }
type FrontResult = { y: number, z: number, plateY: number, plateZ: number } -- bumper center and face; plate

-- Design fronts (Phase 11): a design's frontBumper and lights variants in place of a brand face. Each makes HeadL
-- and HeadR and at most three more body parts, so a design stays inside the part budget.
type FrontBumper = {
	look: Look?, -- the bumper box; nil for none ("aero": a splitter under a big intake)
	rise: number, -- bumper top above the chin top (kept low enough to leave the lamps room)
	reach: number, -- bumper face (or splitter tip) ahead of the nose
	depth: number, -- how far it runs back into the nose
	detail: "slot" | "intake" | "skid" | "splitter",
}
local DESIGN_FRONTS: { [string]: FrontBumper } = {
	clean = { look = "paint", rise = 0.32, reach = 0.1, depth = 0.5, detail = "slot" },
	sport = { look = "trim", rise = 0.28, reach = 0.2, depth = 0.5, detail = "intake" },
	rugged = { look = "trim", rise = 0.5, reach = 0.35, depth = 0.6, detail = "skid" },
	aero = { look = nil, rise = 0, reach = 0.3, depth = 0.8, detail = "splitter" },
}
local DESIGN_FRONT_DETAIL = {
	slotShare = 0.45, -- clean: a narrow dark slot across the bumper face (share of the half-width)...
	slotHeight = 0.14,
	intakeShare = 0.75, -- sport: a wide dark intake low on the bumper face...
	intakeLift = 0.06,
	intakeHeight = 0.32,
	skidShare = 0.6, -- rugged: a bright skid plate along the bumper's foot, reaching past its face...
	skidHeight = 0.14,
	skidReach = 0.12,
	skidDepth = 0.6,
	splitterInset = 0.1, -- aero: a thin splitter inside the body sides...
	splitterHeight = 0.12,
	aeroIntakeShare = 0.6, -- ...under a big dark intake on the nose face
	aeroIntakeLift = 0.08,
	aeroIntakeHeight = 0.4,
	aeroIntakeMin = 0.06,
}
-- Lamp variants: headlamp width and greatest height, tail lamp size, and the one extra part some add ("strip": a
-- running-light strip between the lamps; "bar": a light bar across the top of the nose over them; "grille": a
-- grille between tall narrow lamps).
type LampVariant = {
	width: number,
	height: number,
	extra: "strip" | "bar" | "grille" | "none",
	tailWidth: number,
	tailHeight: number,
}
local DESIGN_LAMPS: { [string]: LampVariant } = {
	slim = { width = 1.3, height = 0.2, extra = "strip", tailWidth = 1.3, tailHeight = 0.16 },
	round = { width = 0.6, height = 0.55, extra = "none", tailWidth = 0.6, tailHeight = 0.55 },
	bar = { width = 0.7, height = 0.3, extra = "bar", tailWidth = 0.6, tailHeight = 0.3 },
	split = { width = 0.35, height = 0.75, extra = "grille", tailWidth = 0.35, tailHeight = 0.95 },
}
local DESIGN_LAMP = {
	minHeight = 0.12,
	minInner = 0.3, -- the two headlamps never come nearer the centerline than this
	stripHeight = 0.08,
	stripDrop = 0.05, -- the strip's top sits this far under the lamps' top
	barHeight = 0.1,
	barGap = 0.04, -- between the light bar and the lamps under it
	grilleInset = 0.15, -- the grille stops this far inside the lamps
}

local function designFront(ctx: Ctx, design: Design, i: FrontInfo): FrontResult
	local P = DETAIL.proud
	local z, hw, bb = i.z, i.hw, i.bb
	local bumper = DESIGN_FRONTS[design.frontBumper] or DESIGN_FRONTS.clean
	local lamps = DESIGN_LAMPS[design.lights] or DESIGN_LAMPS.slim
	local d = DESIGN_FRONT_DETAIL
	-- The lamps need at least this much nose face over whatever sits under them.
	local lampRoom = 2 * FACE.lampGap + DESIGN_LAMP.minHeight
	local result: FrontResult
	local low: number -- top of what sits under the lamps
	local look: Look? = bumper.look
	if look ~= nil then
		local top = math.max(i.chinTop, math.min(i.chinTop + bumper.rise, i.noseTop - lampRoom))
		local face = z - bumper.reach
		box(ctx, "FrontBumper", look, -hw - P, hw + P, bb, top, face, z + bumper.depth)
		local y = (bb + top) / 2
		if bumper.detail == "slot" then
			local half = hw * d.slotShare
			box(ctx, "Intake", "dark", -half, half, y - d.slotHeight / 2, y + d.slotHeight / 2, face - P, face + 0.02)
		elseif bumper.detail == "intake" then
			local half = hw * d.intakeShare
			local y0 = bb + d.intakeLift
			local y1 = math.max(y0 + d.aeroIntakeMin, math.min(y0 + d.intakeHeight, top - d.intakeLift))
			box(ctx, "Intake", "dark", -half, half, y0, y1, face - P, face + 0.02)
		else
			local half = hw * d.skidShare
			box(ctx, "Skid", "bright", -half, half, bb, bb + d.skidHeight, face - d.skidReach, face + d.skidDepth)
		end
		result = { y = y, z = face, plateY = y, plateZ = face - P }
		low = top
	else
		local inset = d.splitterInset
		local tip = z - bumper.reach
		box(ctx, "Splitter", "trim", -hw + inset, hw - inset, bb, bb + d.splitterHeight, tip, z + bumper.depth)
		local half = hw * d.aeroIntakeShare
		local y0 = i.chinTop + d.aeroIntakeLift
		local y1 = math.max(y0 + d.aeroIntakeMin, math.min(y0 + d.aeroIntakeHeight, i.noseTop - lampRoom))
		box(ctx, "Intake", "dark", -half, half, y0, y1, z - P, z + 0.02)
		result = { y = bb + d.splitterHeight / 2, z = tip, plateY = (y0 + y1) / 2, plateZ = z - P }
		low = y1
	end

	-- Headlamps in the nose face between that and the nose top, at the corners.
	local outer = hw - FACE.cornerInset
	local inner = math.max(DESIGN_LAMP.minInner, outer - lamps.width)
	local bottom, high = low + FACE.lampGap, i.noseTop - FACE.lampGap
	local lampZ0, lampZ1 = z - P, z + P
	if lamps.extra == "bar" and high - bottom >= DESIGN_LAMP.barHeight + DESIGN_LAMP.barGap + DESIGN_LAMP.minHeight then
		box(ctx, "LightBar", "neon", -outer, outer, high - DESIGN_LAMP.barHeight, high, z - P, z + 0.02)
		high -= DESIGN_LAMP.barHeight + DESIGN_LAMP.barGap
	end
	local height = math.max(DESIGN_LAMP.minHeight, math.min(lamps.height, high - bottom))
	pairLamp(ctx, "Head", "head", inner, outer, high - height, high, lampZ0, lampZ1)
	if lamps.extra == "strip" then
		local top = high - DESIGN_LAMP.stripDrop
		box(ctx, "RunningLight", "neon", -inner, inner, top - DESIGN_LAMP.stripHeight, top, z - P, z)
	elseif lamps.extra == "grille" and inner > DESIGN_LAMP.grilleInset then
		local half = inner - DESIGN_LAMP.grilleInset
		box(ctx, "Grille", "trim", -half, half, high - height, high, z - P, z + 0.02)
	end
	return result
end

local function addFront(ctx: Ctx, look: BrandLook, i: FrontInfo): FrontResult
	local design = ctx.design
	if design ~= nil then
		return designFront(ctx, design, i)
	end
	local P = DETAIL.proud
	local z, hw = i.z, i.hw
	local lampZ0, lampZ1 = z - P, z + P
	local outer = hw - FACE.cornerInset
	local face = look.face

	if face == "strip" then
		-- Ohm: slim lamps joined by a running-light strip, and a dark intake low in the nose.
		local top = i.noseTop - 0.02
		local inner = hw - DETAIL.lampWidth
		pairLamp(ctx, "Head", "head", inner, hw - DETAIL.inset, top - DETAIL.lampHeight, top, lampZ0, lampZ1)
		local stripTop = top - 0.03
		box(ctx, "RunningLight", "neon", -inner, inner, stripTop - DETAIL.stripHeight, stripTop, z - P, z)
		local intakeHalf = hw * DETAIL.intakeWidthRatio
		local intakeBottom = i.chinTop + DETAIL.intakeLift
		local intakeTop = intakeBottom + DETAIL.intakeHeight
		box(ctx, "Intake", "trim", -intakeHalf, intakeHalf, intakeBottom, intakeTop, z - P, z + 0.02)
		return { y = i.chinTop, z = z, plateY = (intakeBottom + intakeTop) / 2, plateZ = z - P }
	elseif face == "slit" then
		-- Kaze and Montevale: thin angular lamps, a splitter and a wide intake instead of a bumper.
		local top = i.noseTop - 0.05
		pairLamp(ctx, "Head", "head", outer - 1.3, outer, top - 0.18, top, lampZ0, lampZ1)
		box(ctx, "Splitter", "trim", -hw + 0.1, hw - 0.1, i.bb, i.bb + 0.12, z - 0.25, z + 0.8)
		local intakeHalf = hw * 0.55
		local intakeBottom = i.chinTop + 0.08
		local intakeTop = math.max(intakeBottom + 0.15, math.min(intakeBottom + 0.4, top - 0.3))
		box(ctx, "Intake", "trim", -intakeHalf, intakeHalf, intakeBottom, intakeTop, z - P, z + 0.02)
		return { y = i.bb + 0.06, z = z - 0.25, plateY = (intakeBottom + intakeTop) / 2, plateZ = z - P }
	end

	-- Every other face sits over a full-width bumper (bright on classics).
	local bumperTop = i.chinTop + FACE.bumperRise
	local bumperLook: Look = if i.classic then "bright" else "trim"
	local reach = if face == "stacked" or face == "utility" then FACE.workReach else FACE.bumperReach
	box(ctx, "FrontBumper", bumperLook, -hw - P, hw + P, i.bb, bumperTop, z - reach, z + FACE.bumperDepth)
	local low, high = bumperTop + FACE.lampGap, i.noseTop - FACE.lampGap
	local room = high - low
	if face == "rounded" then
		-- Halden: soft square lamps with a slim grille slot between them.
		local height = math.min(0.55, room)
		local inner = outer - 1.0
		pairLamp(ctx, "Head", "head", inner, outer, high - height, high, lampZ0, lampZ1)
		box(ctx, "Grille", "trim", -inner + 0.3, inner - 0.3, high - height * 0.7, high - height * 0.2, z - P, z + 0.02)
	elseif face == "stacked" then
		-- Ironwood: tall stacked lamp pods either side of a big grille.
		local height = math.min(1.1, room)
		local inner = outer - 0.5
		pairLamp(ctx, "Head", "head", inner, outer, high - height, high, lampZ0, lampZ1)
		box(ctx, "Grille", "trim", -inner + 0.15, inner - 0.15, low, high, z - P, z + 0.02)
	elseif face == "blade" then
		-- Aldermoor: one slim lamp blade across the nose, split by a bright crest.
		pairLamp(ctx, "Head", "head", 0.45, outer, high - 0.16, high, lampZ0, lampZ1)
		box(ctx, "Crest", "bright", -0.4, 0.4, math.max(low, high - 0.6), high + 0.02, z - P, z + 0.02)
	elseif face == "grille" then
		-- Brannock: a wide bar grille with the lamps set into its ends.
		box(ctx, "Grille", "trim", -outer, outer, low, high, z - P, z + 0.02)
		local height = math.max(0.15, math.min(0.45, room - 0.1))
		local middle = (low + high) / 2
		pairLamp(
			ctx,
			"Head",
			"head",
			outer - 0.75,
			outer - 0.12,
			middle - height / 2,
			middle + height / 2,
			z - 2 * P,
			z
		)
	else
		-- Northline (utility) and unknown brands: square lamps at the corners, a grille block between them.
		local height = math.min(0.6, room)
		local inner = outer - 0.9
		pairLamp(ctx, "Head", "head", inner, outer, high - height, high, lampZ0, lampZ1)
		box(ctx, "Grille", "trim", -inner + 0.2, inner - 0.2, low, high, z - P, z + 0.02)
	end
	local y = (i.bb + bumperTop) / 2
	return { y = y, z = z - reach, plateY = y, plateZ = z - reach - P }
end

-- Rear: bumper, reverse lamp, the brand's tail lamps at the corners and a brake strip between them.
local REAR = {
	belowBelt = 0.08, -- car tail lamps top out this far under the beltline
	cornerInset = 0.08, -- tail lamps stop this far inside the body sides
	minGap = 0.3, -- tail lamps keep this far outside the reverse lamp
	clearance = 0.15, -- tail lamps keep this far above the reverse lamp
	minHeight = 0.12,
	brakeDrop = 0.08, -- the brake strip's top sits this far under the tail lamps' top
	plateLift = 0.35, -- rear plate center above the reverse lamp's top
}

type RearInfo = { z: number, hw: number, bb: number, tailTop: number, classic: boolean, brakeTop: number? }
type RearResult = { plateY: number, bumperY: number, bumperZ: number }

-- Design rears (Phase 11): a design's rearBumper variant and its lights variant's tail lamps in place of a brand
-- tail. Each makes the four rear lamps and at most two body parts.
type RearBumper = {
	look: Look,
	lift: number, -- bumper bottom above the body bottom (the detail fills the gap)
	height: number,
	reach: number, -- bumper face behind the tail
	depth: number, -- how far it runs forward into the tail
	detail: "none" | "valance" | "step" | "diffuser",
}
local DESIGN_REARS: { [string]: RearBumper } = {
	clean = { look = "paint", lift = 0, height = 0.6, reach = 0.04, depth = 0.5, detail = "none" },
	sport = { look = "trim", lift = 0.12, height = 0.5, reach = 0.04, depth = 0.5, detail = "valance" },
	rugged = { look = "trim", lift = 0, height = 0.8, reach = 0.25, depth = 0.6, detail = "step" },
	diffuser = { look = "trim", lift = 0.18, height = 0.45, reach = 0.04, depth = 0.5, detail = "diffuser" },
}
local DESIGN_REAR_DETAIL = {
	valanceShare = 0.7, -- sport: a dark lip under the raised bumper (share of the half-width)...
	valanceReach = 0.14,
	valanceDepth = 0.3,
	stepHalf = 0.7, -- rugged: a bright step plate on the bumper top...
	stepHeight = 0.06,
	stepDepth = 0.35,
	diffuserInset = 0.3, -- diffuser: a dark diffuser wedge under the raised bumper
	diffuserDepth = 0.8,
	diffuserReach = 0.15,
}

local function designRear(ctx: Ctx, design: Design, r: RearInfo): RearResult
	local P = DETAIL.proud
	local z, hw, bb = r.z, r.hw, r.bb
	local bumper = DESIGN_REARS[design.rearBumper] or DESIGN_REARS.clean
	local lamps = DESIGN_LAMPS[design.lights] or DESIGN_LAMPS.slim
	local d = DESIGN_REAR_DETAIL
	local bumperBottom = bb + bumper.lift
	local bumperTop = bumperBottom + bumper.height
	box(ctx, "RearBumper", bumper.look, -hw - P, hw + P, bumperBottom, bumperTop, z - bumper.depth, z + bumper.reach)
	if bumper.detail == "valance" then
		local half = hw * d.valanceShare
		box(ctx, "Valance", "dark", -half, half, bb, bumperBottom, z - d.valanceDepth, z + d.valanceReach)
	elseif bumper.detail == "step" then
		local half = d.stepHalf
		box(ctx, "Step", "bright", -half, half, bumperTop, bumperTop + d.stepHeight, z - d.stepDepth, z + bumper.reach)
	elseif bumper.detail == "diffuser" then
		local half = hw - d.diffuserInset
		wedge(
			ctx,
			"Diffuser",
			"dark",
			"underBack",
			-half,
			half,
			bb,
			bumperBottom,
			z - d.diffuserDepth,
			z + d.diffuserReach
		)
	end

	-- The reverse lamp over the bumper, tail lamps at the corners and a brake strip between them (as addRear).
	local reverseHalf = DETAIL.reverseHalfWidth
	local reverseBottom = bumperTop + DETAIL.reverseLift
	local reverseTop = reverseBottom + DETAIL.reverseHeight
	lamp(ctx, "Reverse", "reverse", -reverseHalf, reverseHalf, reverseBottom, reverseTop, z - 0.02, z + P)
	local outer = hw - REAR.cornerInset
	local inner = math.max(outer - lamps.tailWidth, reverseHalf + REAR.minGap)
	local height = math.max(REAR.minHeight, math.min(lamps.tailHeight, r.tailTop - reverseTop - REAR.clearance))
	pairLamp(ctx, "Tail", "tail", inner, outer, r.tailTop - height, r.tailTop, z - 0.02, z + P)
	local brakeTop = r.brakeTop or r.tailTop - REAR.brakeDrop
	local brakeHalf = inner - 0.02
	lamp(ctx, "Brake", "brake", -brakeHalf, brakeHalf, brakeTop - DETAIL.brakeHeight, brakeTop, z - 0.02, z + P)
	return {
		plateY = reverseTop + REAR.plateLift,
		bumperY = (bumperBottom + bumperTop) / 2,
		bumperZ = z + bumper.reach,
	}
end

local function addRear(ctx: Ctx, look: BrandLook, r: RearInfo): RearResult
	local design = ctx.design
	if design ~= nil then
		return designRear(ctx, design, r)
	end
	local P = DETAIL.proud
	local z, hw = r.z, r.hw
	local bumperTop = r.bb + DETAIL.bumperHeight
	local bumperLook: Look = if r.classic then "bright" else "trim"
	box(ctx, "RearBumper", bumperLook, -hw - P, hw + P, r.bb, bumperTop, z - DETAIL.bumperDepth, z + P)
	local reverseHalf = DETAIL.reverseHalfWidth
	local reverseBottom = bumperTop + DETAIL.reverseLift
	local reverseTop = reverseBottom + DETAIL.reverseHeight
	lamp(ctx, "Reverse", "reverse", -reverseHalf, reverseHalf, reverseBottom, reverseTop, z - 0.02, z + P)
	local outer = hw - REAR.cornerInset
	local inner = math.max(outer - look.tailWidth, reverseHalf + REAR.minGap)
	local height = math.max(REAR.minHeight, math.min(look.tailHeight, r.tailTop - reverseTop - REAR.clearance))
	pairLamp(ctx, "Tail", "tail", inner, outer, r.tailTop - height, r.tailTop, z - 0.02, z + P)
	local brakeTop = r.brakeTop or r.tailTop - REAR.brakeDrop
	local brakeHalf = inner - 0.02
	lamp(ctx, "Brake", "brake", -brakeHalf, brakeHalf, brakeTop - DETAIL.brakeHeight, brakeTop, z - 0.02, z + P)
	return { plateY = reverseTop + REAR.plateLift, bumperY = (r.bb + bumperTop) / 2, bumperZ = z + P }
end

-- Northline's livery stripe: a dark band around the body between two lengthwise positions.
local function liveryStripe(ctx: Ctx, hw: number, y: number, z0: number, z1: number)
	if brandLook(ctx.vehicle.brandId).face == "utility" then
		local P = DETAIL.proud
		box(ctx, "Stripe", "trim", -hw - P, hw + P, y, y + 0.25, z0, z1)
	end
end

-- Cars: sedan, hatch, coupe, wagon, SUV, minivan, muscle, exotic, off-road, pod and hypercar bodies all share
-- one construction (the Ohm sedan family's, with brand faces) and differ by profile and a few extras.
-- Lengthwise positions are shares of the body length; heights are shares of the space over the wheel arches.
type CarStyle = {
	cowl: number, -- windshield base, share of the length behind the front end
	roofFront: number, -- roof front edge, share of the length behind the front end
	roofRear: number, -- roof rear edge, share of the length ahead of the back end
	rearGlass: number, -- rear glass base, share of the length ahead of the back end
	beltShare: number, -- beltline height (see beltAt)
	hoodRise: number, -- hood front height (see hoodFrontAt): 0 is a low nose, 1 a flat hood at the beltline
	deckRise: number, -- deck top above the beltline at the back end
	ducktail: boolean, -- the deck rises toward the tail (a wedge) instead of being a flat lid
	glassInset: number, -- the greenhouse is this much narrower than the body on each side
	roofLook: Look,
	rails: boolean, -- roof rails
	cladding: boolean, -- dark rocker and arch flares
	mirrors: boolean,
}

local CAR_STYLES: { [string]: CarStyle } = {
	sedan = {
		cowl = 0.34,
		roofFront = 0.5,
		roofRear = 0.27,
		rearGlass = 0.12,
		beltShare = 0.2,
		hoodRise = 0.35,
		deckRise = 0.2,
		ducktail = false,
		glassInset = 0.35,
		roofLook = "paint",
		rails = false,
		cladding = false,
		mirrors = true,
	},
	-- Upright, short overhangs, a near-vertical hatch.
	hatch = {
		cowl = 0.3,
		roofFront = 0.44,
		roofRear = 0.1,
		rearGlass = 0.03,
		beltShare = 0.22,
		hoodRise = 0.4,
		deckRise = 0.08,
		ducktail = false,
		glassInset = 0.3,
		roofLook = "paint",
		rails = false,
		cladding = false,
		mirrors = true,
	},
	-- A short cabin, long sloping rear glass and a ducktail.
	coupe = {
		cowl = 0.36,
		roofFront = 0.5,
		roofRear = 0.33,
		rearGlass = 0.12,
		beltShare = 0.18,
		hoodRise = 0.3,
		deckRise = 0.22,
		ducktail = true,
		glassInset = 0.4,
		roofLook = "paint",
		rails = false,
		cladding = false,
		mirrors = true,
	},
	-- The roof runs all the way back; roof rails.
	wagon = {
		cowl = 0.32,
		roofFront = 0.45,
		roofRear = 0.05,
		rearGlass = 0.015,
		beltShare = 0.2,
		hoodRise = 0.35,
		deckRise = 0.05,
		ducktail = false,
		glassInset = 0.35,
		roofLook = "paint",
		rails = true,
		cladding = false,
		mirrors = true,
	},
	suv = {
		cowl = 0.3,
		roofFront = 0.42,
		roofRear = 0.07,
		rearGlass = 0.025,
		beltShare = 0.25,
		hoodRise = 0.55,
		deckRise = 0.12,
		ducktail = false,
		glassInset = 0.3,
		roofLook = "paint",
		rails = true,
		cladding = true,
		mirrors = true,
	},
	-- A short hood and a long, tall, boxy cabin.
	minivan = {
		cowl = 0.24,
		roofFront = 0.33,
		roofRear = 0.05,
		rearGlass = 0.02,
		beltShare = 0.25,
		hoodRise = 0.4,
		deckRise = 0.08,
		ducktail = false,
		glassInset = 0.25,
		roofLook = "paint",
		rails = false,
		cladding = false,
		mirrors = true,
	},
	-- Long flat hood, cabin set back, short deck, high beltline.
	muscle = {
		cowl = 0.42,
		roofFront = 0.58,
		roofRear = 0.24,
		rearGlass = 0.13,
		beltShare = 0.3,
		hoodRise = 0.8,
		deckRise = 0.2,
		ducktail = false,
		glassInset = 0.45,
		roofLook = "paint",
		rails = false,
		cladding = false,
		mirrors = true,
	},
	-- Cab-forward wedge: a low nose, a short canopy, a long engine deck.
	exotic = {
		cowl = 0.3,
		roofFront = 0.46,
		roofRear = 0.36,
		rearGlass = 0.2,
		beltShare = 0.15,
		hoodRise = 0,
		deckRise = 0.2,
		ducktail = true,
		glassInset = 0.5,
		roofLook = "paint",
		rails = false,
		cladding = false,
		mirrors = true,
	},
	-- Boxy and upright on a tall, flat hood; cladding, roof rails.
	offroad = {
		cowl = 0.3,
		roofFront = 0.37,
		roofRear = 0.06,
		rearGlass = 0.02,
		beltShare = 0.3,
		hoodRise = 0.85,
		deckRise = 0.1,
		ducktail = false,
		glassInset = 0.2,
		roofLook = "paint",
		rails = true,
		cladding = true,
		mirrors = true,
	},
	-- A short rounded robotaxi with a glass canopy and no mirrors.
	pod = {
		cowl = 0.3,
		roofFront = 0.4,
		roofRear = 0.25,
		rearGlass = 0.08,
		beltShare = 0.2,
		hoodRise = 0.3,
		deckRise = 0.1,
		ducktail = false,
		glassInset = 0.45,
		roofLook = "glass",
		rails = false,
		cladding = false,
		mirrors = false,
	},
	-- The exotic wedge with a glass canopy (thruster nozzles are added on top).
	hypercar = {
		cowl = 0.3,
		roofFront = 0.45,
		roofRear = 0.38,
		rearGlass = 0.2,
		beltShare = 0.12,
		hoodRise = 0,
		deckRise = 0.18,
		ducktail = true,
		glassInset = 0.55,
		roofLook = "glass",
		rails = false,
		cladding = false,
		mirrors = true,
	},
}

-- What carBody leaves for a style's extras (ground space).
type CarBody = {
	frame: Frame,
	bb: number,
	chinTop: number,
	belt: number,
	cowlZ: number,
	roofTop: number,
	roofFrontZ: number,
	roofRearZ: number,
	roofHalf: number,
	deckTop: number,
	hoodAt: (number) -> number,
}

local function carBody(ctx: Ctx, style: CarStyle): (Shape, CarBody)
	local g = ctx.g
	local f = frameOf(g)
	local look = brandLook(ctx.vehicle.brandId)
	local classic = isClassic(ctx)
	local hw, front, back, length = f.halfWidth, f.front, f.back, g.length
	local af0, af1, ar0, ar1 = f.frontArchFront, f.frontArchBack, f.rearArchFront, f.rearArchBack
	local P = DETAIL.proud

	local bb = bodyBottom(g)
	local chinTop = bb + GENERIC.chin
	local roofTop = g.height - (if style.rails then GENERIC.railRoom else 0)
	local roofBottom = roofTop - GENERIC.roofThickness
	local belt = beltAt(f, roofBottom, style.beltShare)
	local hoodFront = hoodFrontAt(f, belt, hoodRiseFor(ctx, style.hoodRise))
	local noseTop = noseTopAt(chinTop, hoodFront)
	local cowlZ = math.max(front + style.cowl * length, af1 + GENERIC.cowlGap)
	local roofFrontZ = math.max(front + style.roofFront * length, cowlZ + GENERIC.minRake)
	local rearGlassZ = back - style.rearGlass * length
	local roofRearZ = math.min(back - style.roofRear * length, rearGlassZ - GENERIC.minRearGlass)
	local deckTop = belt + style.deckRise
	local name = ctx.model.Name
	assert(belt < roofBottom, `{name}: the body is too low for its wheels`)
	assert(roofRearZ - roofFrontZ >= GENERIC.minCabin, `{name}: the cabin is too short for this geometry`)

	-- Lower body: the nose and hood, sides around open wheel arches, the tail.
	noseAndHood(ctx, f, bb, chinTop, noseTop, hoodFront, belt, cowlZ)
	box(ctx, "SideMid", "paint", -hw, hw, bb, belt, af1, ar0)
	box(ctx, "FenderR", "paint", -hw, hw, f.archTop, belt, ar0, ar1)
	box(ctx, "Tail", "paint", -hw, hw, chinTop, belt, ar1, back)

	-- Greenhouse: raked windshield, side glass, roof, rear glass and deck.
	local glassHalf = hw - style.glassInset
	local roofHalf = glassHalf - DETAIL.roofInset
	local overhang = DETAIL.roofOverhang
	wedge(ctx, "Windshield", "glass", "riseBack", -glassHalf, glassHalf, belt, roofBottom, cowlZ, roofFrontZ)
	box(ctx, "SideGlass", "glass", -glassHalf, glassHalf, belt, roofBottom, roofFrontZ, roofRearZ)
	box(
		ctx,
		"Roof",
		style.roofLook,
		-roofHalf,
		roofHalf,
		roofBottom,
		roofTop,
		roofFrontZ - overhang,
		roofRearZ + overhang
	)
	wedge(ctx, "RearGlass", "glass", "riseFront", -glassHalf, glassHalf, belt, roofBottom, roofRearZ, rearGlassZ)
	if style.ducktail then
		wedge(ctx, "Deck", "paint", "riseBack", -hw, hw, belt, deckTop, rearGlassZ, back)
	else
		box(ctx, "Deck", "paint", -hw, hw, belt, deckTop, rearGlassZ, back)
	end

	if style.mirrors then
		local mirrorY = belt + DETAIL.mirrorLift
		mirrorPair(ctx, hw, mirrorY, mirrorY + DETAIL.mirrorHeight, cowlZ + DETAIL.mirrorBack, DETAIL.mirrorReach)
	end
	if style.rails then
		local z0, z1 = roofFrontZ + DETAIL.railEndInset, roofRearZ - DETAIL.railEndInset
		pairBox(
			ctx,
			"Rail",
			"trim",
			roofHalf - DETAIL.railInner,
			roofHalf - DETAIL.railOuter,
			roofTop,
			g.height,
			z0,
			z1
		)
	end
	if style.cladding then
		box(ctx, "Rocker", "trim", -hw - P, hw + P, bb, bb + 0.6, af1, ar0)
		local flareBottom, flareTop = f.archTop - 0.04, f.archTop + 0.28
		box(ctx, "FlareF", "trim", -hw - 0.12, hw + 0.12, flareBottom, flareTop, af0 - 0.2, af1 + 0.2)
		box(ctx, "FlareR", "trim", -hw - 0.12, hw + 0.12, flareBottom, flareTop, ar0 - 0.2, ar1 + 0.2)
	end

	local bumper = addFront(ctx, look, {
		z = front,
		hw = hw,
		bb = bb,
		chinTop = chinTop,
		noseTop = noseTop,
		classic = classic,
	})
	local rear = addRear(ctx, look, { z = back, hw = hw, bb = bb, tailTop = belt - REAR.belowBelt, classic = classic })

	local hoodAt = hoodLine(af0, cowlZ, hoodFront, belt)
	local hoodCamZ = math.max(af0, cowlZ - DETAIL.hoodCamBack)
	local midHoodZ = (af0 + cowlZ) / 2
	local sideY = (bb + belt) / 2
	local first = roofFrontZ + GENERIC.firstRowBack
	local shape: Shape = {
		seating = seatingFor(ctx, bb, belt, roofBottom, first, roofRearZ - GENERIC.rowRoofMargin),
		points = {
			PlateFront = at(0, bumper.plateY, bumper.plateZ, "forward"),
			PlateRear = at(0, rear.plateY, back + 0.02, "back"),
			CameraHood = at(0, hoodAt(hoodCamZ) + DETAIL.hoodCamHeight, hoodCamZ),
			Mount_Roof = at(0, roofTop, (roofFrontZ + roofRearZ) / 2),
			Mount_Hood = at(0, hoodAt(midHoodZ), midHoodZ),
			Mount_Spoiler = at(0, deckTop, back - DETAIL.spoilerInset),
			Mount_FrontBumper = at(0, bumper.y, bumper.z, "forward"),
			Mount_RearBumper = at(0, rear.bumperY, rear.bumperZ, "back"),
			Mount_SideL = at(-hw, sideY, 0, "left"),
			Mount_SideR = at(hw, sideY, 0, "right"),
		},
	}
	local body: CarBody = {
		frame = f,
		bb = bb,
		chinTop = chinTop,
		belt = belt,
		cowlZ = cowlZ,
		roofTop = roofTop,
		roofFrontZ = roofFrontZ,
		roofRearZ = roofRearZ,
		roofHalf = roofHalf,
		deckTop = deckTop,
		hoodAt = hoodAt,
	}
	return shape, body
end

-- A car style with no extras.
local function plainCar(styleId: string): (Ctx) -> Shape
	return function(ctx: Ctx): Shape
		local shape = carBody(ctx, CAR_STYLES[styleId])
		return shape
	end
end

-- Hatch: a small roof spoiler over the hatch.
local function hatchBody(ctx: Ctx): Shape
	local shape, body = carBody(ctx, CAR_STYLES.hatch)
	local half = body.roofHalf
	local z = body.roofRearZ
	box(ctx, "RoofWing", "trim", -half, half, body.roofTop - 0.05, body.roofTop + 0.08, z - 0.35, z + 0.25)
	return shape
end

-- Minivan: sliding-door tracks along the sides under the windows.
local function minivanBody(ctx: Ctx): Shape
	local shape, body = carBody(ctx, CAR_STYLES.minivan)
	local f = body.frame
	local z0, z1 = body.roofFrontZ + 1.2, f.rearArchFront - 0.3
	if z1 > z0 then
		local hw = f.halfWidth
		pairBox(ctx, "DoorTrack", "trim", hw, hw + DETAIL.proud, body.belt - 0.12, body.belt - 0.04, z0, z1)
	end
	return shape
end

-- Muscle: a hood bulge, a hip kick over the rear wheels and (modern cars only) a lip spoiler.
local function muscleBody(ctx: Ctx): Shape
	local shape, body = carBody(ctx, CAR_STYLES.muscle)
	local f = body.frame
	local hw = f.halfWidth
	local midHoodZ = (f.frontArchFront + body.cowlZ) / 2
	local bulgeBottom = body.hoodAt(midHoodZ) - 0.1
	box(ctx, "HoodBulge", "paint", -0.65, 0.65, bulgeBottom, body.belt + 0.15, midHoodZ, body.cowlZ - 0.1)
	pairBox(
		ctx,
		"Haunch",
		"paint",
		hw - 0.05,
		hw + 0.12,
		f.archTop,
		body.belt + 0.05,
		f.rearArchFront - 0.4,
		f.back - 0.3
	)
	-- A design's own spoiler choice replaces the style's (SpecBuilder builds it on Mount_Spoiler).
	if not isClassic(ctx) and ctx.design == nil then
		box(ctx, "Spoiler", "trim", -hw + 0.3, hw - 0.3, body.deckTop, body.deckTop + 0.12, f.back - 0.5, f.back - 0.1)
	end
	return shape
end

-- Exotic: deep side intakes, rear haunches, a diffuser and (modern cars only) a wing on two pylons.
local function exoticBody(ctx: Ctx, style: CarStyle): (Shape, CarBody)
	local shape, body = carBody(ctx, style)
	local f = body.frame
	local hw, back, ar0 = f.halfWidth, f.back, f.rearArchFront
	box(ctx, "SideIntake", "trim", -hw - 0.03, hw + 0.03, body.bb + 0.45, body.belt - 0.1, ar0 - 1.6, ar0 - 0.1)
	pairBox(ctx, "Haunch", "paint", hw - 0.7, hw + 0.06, f.archTop, body.belt + 0.25, ar0 - 0.3, back - 0.1)
	wedge(
		ctx,
		"Diffuser",
		"trim",
		"underBack",
		-hw + 0.3,
		hw - 0.3,
		body.bb,
		body.chinTop + 0.15,
		f.rearArchBack,
		back + 0.15
	)
	if not isClassic(ctx) and ctx.design == nil then
		local wingBottom = body.deckTop + 0.3
		box(ctx, "Wing", "trim", -hw + 0.35, hw - 0.35, wingBottom, wingBottom + 0.12, back - 1.0, back - 0.05)
		pairBox(ctx, "Pylon", "trim", 0.9, 1.1, body.deckTop, wingBottom, back - 0.75, back - 0.35)
	end
	return shape, body
end

-- Hypercar: the exotic wedge with a glass canopy and two thruster nozzles in the tail.
local function hypercarBody(ctx: Ctx): Shape
	local shape, body = exoticBody(ctx, CAR_STYLES.hypercar)
	local f = body.frame
	local x = f.halfWidth * 0.42
	local y = (body.chinTop + body.belt) / 2
	for _, side in SIDES do
		cylinder(ctx, `Nozzle{side.suffix}`, "trim", "z", Vector3.new(side.sign * x, y, f.back + 0.05), 0.8, 0.4)
	end
	shape.points.Thruster_L = at(-x, y, f.back + 0.25, "back")
	shape.points.Thruster_R = at(x, y, f.back + 0.25, "back")
	shape.points.Thruster_Down = at(0, body.bb, 0.5, "down")
	return shape
end

-- Off-road: a spare wheel on the tailgate and a hitch receiver under it.
local function offroadBody(ctx: Ctx): Shape
	local shape, body = carBody(ctx, CAR_STYLES.offroad)
	local g = ctx.g
	local back = body.frame.back
	local spareY = (body.chinTop + body.belt) / 2 + 0.3
	local spareCenter = Vector3.new(0, spareY, back + g.wheelWidth / 2 + 0.05)
	cylinder(ctx, "Spare", "tire", "z", spareCenter, 2 * g.wheelRadius * 0.85, g.wheelWidth)
	local hitchY = body.bb + 0.3
	box(ctx, "Hitch", "trim", -0.25, 0.25, hitchY - 0.15, hitchY + 0.15, back + DETAIL.proud, back + 0.55)
	shape.points.TowHitch = at(0, hitchY, back + 0.5, "back")
	return shape
end

-- Work trucks (pickups, service and tow trucks): a tall flat hood, a cab sized to its seat rows, and the frame
-- behind it left for a bed, tool boxes or a tow deck.
local WORK = {
	beltShare = 0.35,
	hoodRise = 0.85,
	cowl = 0.3, -- windshield base, share of the length behind the front end
	rake = 1.4, -- windshield length, front to back
	cabTail = 1.0, -- the cab's back wall sits this far behind the last seat row
	floorAboveArch = 0.15, -- the bed or deck floor sits this far over the rear arch tops
	minBed = 3, -- at least this much length behind the cab
	wall = 0.35, -- bed wall thickness
	gate = 0.25, -- tailgate thickness
	glassInset = 0.2,
	mirrorReach = 0.45,
	hitchLift = 0.3, -- hitch receiver height above the body bottom
}

type WorkCab = {
	frame: Frame,
	bb: number,
	belt: number,
	roofTop: number,
	roofFrontZ: number,
	cabBack: number,
	bedFloor: number,
}

local function workCab(ctx: Ctx, roofTop: number): (WorkCab, Shape)
	local g = ctx.g
	local f = frameOf(g)
	local look = brandLook(ctx.vehicle.brandId)
	local hw, front, back = f.halfWidth, f.front, f.back
	local af0, af1, ar0, ar1 = f.frontArchFront, f.frontArchBack, f.rearArchFront, f.rearArchBack
	local bb = bodyBottom(g)
	local chinTop = bb + GENERIC.chin
	local roofBottom = roofTop - GENERIC.roofThickness
	local belt = beltAt(f, roofBottom, WORK.beltShare)
	local hoodFront = hoodFrontAt(f, belt, hoodRiseFor(ctx, WORK.hoodRise))
	local noseTop = noseTopAt(chinTop, hoodFront)
	local cowlZ = math.max(front + WORK.cowl * g.length, af1 + GENERIC.cowlGap)
	local roofFrontZ = cowlZ + WORK.rake
	local first = roofFrontZ + GENERIC.firstRowBack
	local last = first + (rowCount(ctx) - 1) * GENERIC.rowSpacing
	local cabBack = last + WORK.cabTail
	local bedFloor = f.archTop + WORK.floorAboveArch
	local name = ctx.model.Name
	assert(belt < roofBottom, `{name}: the cab is too low for its wheels`)
	assert(cabBack < ar0 and cabBack <= back - WORK.minBed, `{name}: the cab leaves no room behind it`)

	noseAndHood(ctx, f, bb, chinTop, noseTop, hoodFront, belt, cowlZ)
	box(ctx, "CabSide", "paint", -hw, hw, bb, belt, af1, cabBack)
	local glassHalf = hw - WORK.glassInset
	local roofHalf = glassHalf - DETAIL.roofInset
	wedge(ctx, "Windshield", "glass", "riseBack", -glassHalf, glassHalf, belt, roofBottom, cowlZ, roofFrontZ)
	box(ctx, "CabGlass", "glass", -glassHalf, glassHalf, belt, roofBottom, roofFrontZ, cabBack)
	box(ctx, "Roof", "paint", -roofHalf, roofHalf, roofBottom, roofTop, roofFrontZ - DETAIL.roofOverhang, cabBack)
	box(ctx, "BedBase", "paint", -hw, hw, bb, bedFloor, cabBack, ar0)
	box(ctx, "FenderR", "paint", -hw, hw, f.archTop, bedFloor, ar0, ar1)
	box(ctx, "TailBase", "paint", -hw, hw, chinTop, bedFloor, ar1, back)
	local mirrorY = belt + DETAIL.mirrorLift
	mirrorPair(ctx, hw, mirrorY, mirrorY + 2 * DETAIL.mirrorHeight, cowlZ + DETAIL.mirrorBack, WORK.mirrorReach)
	liveryStripe(ctx, hw, (bb + belt) / 2, af1, cabBack)

	local bumper = addFront(ctx, look, {
		z = front,
		hw = hw,
		bb = bb,
		chinTop = chinTop,
		noseTop = noseTop,
		classic = isClassic(ctx),
	})
	local hoodAt = hoodLine(af0, cowlZ, hoodFront, belt)
	local hoodCamZ = math.max(af0, cowlZ - DETAIL.hoodCamBack)
	local midHoodZ = (af0 + cowlZ) / 2
	local sideY = (bb + belt) / 2
	local shape: Shape = {
		seating = seatingFor(ctx, bb, belt, roofBottom, first, last),
		points = {
			PlateFront = at(0, bumper.plateY, bumper.plateZ, "forward"),
			CameraHood = at(0, hoodAt(hoodCamZ) + DETAIL.hoodCamHeight, hoodCamZ),
			Mount_Roof = at(0, roofTop, (roofFrontZ + cabBack) / 2),
			Mount_Hood = at(0, hoodAt(midHoodZ), midHoodZ),
			Mount_FrontBumper = at(0, bumper.y, bumper.z, "forward"),
			Mount_SideL = at(-hw, sideY, 0, "left"),
			Mount_SideR = at(hw, sideY, 0, "right"),
			-- PlateRear, Mount_Spoiler, Mount_RearBumper and TowHitch come from the rear the caller builds.
		},
	}
	local cab: WorkCab = {
		frame = f,
		bb = bb,
		belt = belt,
		roofTop = roofTop,
		roofFrontZ = roofFrontZ,
		cabBack = cabBack,
		bedFloor = bedFloor,
	}
	return cab, shape
end

-- Pickup: an open bed between two walls and a tailgate, with a hitch receiver. Service-class pickups (utility
-- trucks) trade the bed walls for tall tool boxes and carry a ladder rack and an amber beacon bar.
local function pickupBody(ctx: Ctx): Shape
	local g = ctx.g
	local service = ctx.vehicle.class == "service"
	local cab, shape = workCab(ctx, g.height - (if service then GENERIC.rackRoom else 0))
	local f = cab.frame
	local hw, back = f.halfWidth, f.back
	local floor, belt = cab.bedFloor, cab.belt
	local P = DETAIL.proud
	local gateHalf
	if service then
		local boxWidth = 1.0
		local boxTop = belt + 0.5
		pairBox(ctx, "ToolBox", "paint", hw - boxWidth, hw, floor, boxTop, cab.cabBack + 0.1, back - 0.05)
		local railInner, railOuter = hw - 0.55, hw - 0.35
		pairBox(ctx, "Rack", "trim", railInner, railOuter, cab.roofTop, g.height, cab.roofFrontZ + 0.3, back - 0.3)
		pairBox(ctx, "RackPost", "trim", railInner, railOuter, boxTop, cab.roofTop, back - 0.5, back - 0.3)
		local beaconZ = cab.roofFrontZ + 0.3
		box(ctx, "Beacon", "beacon", -0.8, 0.8, cab.roofTop, cab.roofTop + 0.22, beaconZ, beaconZ + 0.4)
		gateHalf = hw - boxWidth
	else
		pairBox(ctx, "BedWall", "paint", hw - WORK.wall, hw, floor, belt, cab.cabBack, back)
		gateHalf = hw - WORK.wall
	end
	box(ctx, "BedFloor", "trim", -gateHalf, gateHalf, floor - 0.1, floor + 0.05, cab.cabBack, back - WORK.gate)
	box(ctx, "Tailgate", "paint", -gateHalf, gateHalf, floor, belt, back - WORK.gate, back)
	local hitchY = cab.bb + WORK.hitchLift
	box(ctx, "Hitch", "trim", -0.25, 0.25, hitchY - 0.15, hitchY + 0.15, back + P, back + 0.75)

	local look = brandLook(ctx.vehicle.brandId)
	local tailTop = belt - REAR.belowBelt
	local rear = addRear(ctx, look, { z = back, hw = hw, bb = cab.bb, tailTop = tailTop, classic = isClassic(ctx) })
	local points = shape.points
	points.PlateRear = at(0, rear.plateY, back + 0.02, "back")
	points.Mount_Spoiler = at(0, belt, back - WORK.gate / 2)
	points.Mount_RearBumper = at(0, rear.bumperY, rear.bumperZ, "back")
	points.TowHitch = at(0, hitchY, back + 0.7, "back")
	return shape
end

-- Tow truck: a flat deck with tool boxes, a mast and an angled boom with a hook, an underlift that carries the
-- TowHitch, and an amber light bar on the cab.
local TOW = {
	mastAboveCab = 1.0, -- the boom mast rises this far over the cab roof
	boxLength = 2.4, -- side tool boxes behind the cab
	boomThickness = 0.45,
	underliftReach = 1.2, -- the underlift reaches this far behind the body
}

local function towBody(ctx: Ctx): Shape
	local g = ctx.g
	local cab, shape = workCab(ctx, g.height - TOW.mastAboveCab)
	local f = cab.frame
	local hw, back = f.halfWidth, f.back
	local floor, belt, bb = cab.bedFloor, cab.belt, cab.bb
	box(ctx, "Deck", "trim", -hw, hw, floor - 0.1, floor + 0.1, cab.cabBack, back)
	pairBox(ctx, "ToolBox", "paint", hw - 0.9, hw, floor + 0.1, belt, cab.cabBack + 0.1, cab.cabBack + TOW.boxLength)
	local mastZ = cab.cabBack + 0.7
	local mastTop = g.height - 0.1
	box(ctx, "Mast", "trim", -0.45, 0.45, floor + 0.1, mastTop, mastZ - 0.4, mastZ + 0.4)
	local tip = Vector3.new(0, belt + 0.6, back + 0.5)
	strut(ctx, "Boom", "trim", Vector3.new(0, mastTop - 0.3, mastZ), tip, TOW.boomThickness)
	local hookY = (bb + belt) / 2 + 0.3
	box(ctx, "Cable", "dark", -0.04, 0.04, hookY, tip.Y - 0.2, tip.Z - 0.04, tip.Z + 0.04)
	box(ctx, "Hook", "trim", -0.15, 0.15, hookY - 0.35, hookY, tip.Z - 0.15, tip.Z + 0.15)
	local liftY = bb + 0.25
	local reach = back + TOW.underliftReach
	box(ctx, "Underlift", "trim", -0.4, 0.4, liftY - 0.15, liftY + 0.15, back - 0.2, reach)
	box(ctx, "Crossbar", "trim", -1.5, 1.5, liftY - 0.15, liftY + 0.15, reach - 0.3, reach)
	local barZ = cab.roofFrontZ + 0.3
	box(ctx, "LightBar", "beacon", -hw + 0.6, hw - 0.6, cab.roofTop, cab.roofTop + 0.22, barZ, barZ + 0.4)

	local look = brandLook(ctx.vehicle.brandId)
	local rear = addRear(ctx, look, { z = back, hw = hw, bb = bb, tailTop = floor - 0.15, classic = false })
	local points = shape.points
	points.PlateRear = at(0, rear.plateY, back + 0.02, "back")
	points.Mount_Spoiler = at(0, floor + 0.1, back - 0.3)
	points.Mount_RearBumper = at(0, rear.bumperY, rear.bumperZ, "back")
	points.TowHitch = at(0, liftY, reach - 0.15, "back")
	return shape
end

-- Vans: a short sloping nose, an upright windshield, a cab sized to its seats and a tall cargo box behind it.
-- Vans tall enough carry a ladder rack.
local VAN = {
	beltShare = 0.3,
	hoodRise = 0.5,
	cowl = 0.2, -- windshield base, share of the length behind the front end (kept behind the front arch)
	rake = 1.4, -- windshield length, front to back
	firstRow = 0.3, -- the first seat row sits this far behind the windshield top
	cabTail = 1.2, -- the cab ends this far behind the last seat row
	minCargo = 2, -- at least this much cargo box behind the cab
	glassInset = 0.1,
	mirrorReach = 0.6,
	mirrorHeight = 0.8,
	tailRise = 1.0, -- tail lamps top out this far over the beltline (on the cargo doors)
	rackMinHeight = 8.5, -- vans at least this tall carry a ladder rack
}

local function vanBody(ctx: Ctx): Shape
	local g = ctx.g
	local f = frameOf(g)
	local look = brandLook(ctx.vehicle.brandId)
	local hw, front, back = f.halfWidth, f.front, f.back
	local af0, af1, ar0, ar1 = f.frontArchFront, f.frontArchBack, f.rearArchFront, f.rearArchBack
	local P = DETAIL.proud
	local rack = g.height >= VAN.rackMinHeight
	local bb = bodyBottom(g)
	local chinTop = bb + GENERIC.chin
	local roofTop = g.height - (if rack then GENERIC.rackRoom else 0)
	local roofBottom = roofTop - GENERIC.roofThickness
	local belt = beltAt(f, roofBottom, VAN.beltShare)
	local hoodFront = hoodFrontAt(f, belt, hoodRiseFor(ctx, VAN.hoodRise))
	local noseTop = noseTopAt(chinTop, hoodFront)
	local cowlZ = math.max(front + VAN.cowl * g.length, af1 + GENERIC.cowlGap)
	local glassTopZ = cowlZ + VAN.rake
	local first = glassTopZ + VAN.firstRow
	local last = first + (rowCount(ctx) - 1) * GENERIC.rowSpacing
	local cabBack = last + VAN.cabTail
	assert(cabBack <= back - VAN.minCargo, `{ctx.model.Name}: the cab leaves no room for the cargo box`)

	noseAndHood(ctx, f, bb, chinTop, noseTop, hoodFront, belt, cowlZ)
	box(ctx, "SideMid", "paint", -hw, hw, bb, belt, af1, ar0)
	box(ctx, "FenderR", "paint", -hw, hw, f.archTop, belt, ar0, ar1)
	box(ctx, "Tail", "paint", -hw, hw, chinTop, belt, ar1, back)
	local glassHalf = hw - VAN.glassInset
	wedge(ctx, "Windshield", "glass", "riseBack", -glassHalf, glassHalf, belt, roofBottom, cowlZ, glassTopZ)
	box(ctx, "CabGlass", "glass", -glassHalf, glassHalf, belt, roofBottom, glassTopZ, cabBack)
	box(ctx, "CabRoof", "paint", -hw, hw, roofBottom, roofTop, glassTopZ - DETAIL.roofOverhang, cabBack)
	box(ctx, "CargoBox", "paint", -hw, hw, belt, roofTop, cabBack, back)
	box(ctx, "DoorSeam", "trim", -0.03, 0.03, belt, roofTop - 0.4, back, back + P)
	local mirrorY = belt + 0.1
	mirrorPair(ctx, hw, mirrorY, mirrorY + VAN.mirrorHeight, cowlZ + DETAIL.mirrorBack, VAN.mirrorReach)
	if rack then
		pairBox(ctx, "Rack", "trim", hw - 0.6, hw - 0.4, roofTop, g.height, cabBack - 1.0, back - 0.4)
	end
	liveryStripe(ctx, hw, belt + 0.3, cabBack, back + P)

	local bumper = addFront(ctx, look, {
		z = front,
		hw = hw,
		bb = bb,
		chinTop = chinTop,
		noseTop = noseTop,
		classic = isClassic(ctx),
	})
	-- Tall tail lamps up the cargo doors and a high brake strip across the top of the rear.
	local rear = addRear(ctx, look, {
		z = back,
		hw = hw,
		bb = bb,
		tailTop = belt + VAN.tailRise,
		classic = false,
		brakeTop = roofTop - 0.25,
	})

	local hoodAt = hoodLine(af0, cowlZ, hoodFront, belt)
	local hoodCamZ = math.max(af0, cowlZ - DETAIL.hoodCamBack)
	local midHoodZ = (af0 + cowlZ) / 2
	local sideY = (bb + belt) / 2
	return {
		seating = seatingFor(ctx, bb, belt, roofBottom, first, last),
		points = {
			PlateFront = at(0, bumper.plateY, bumper.plateZ, "forward"),
			PlateRear = at(0, rear.plateY, back + 0.02, "back"),
			CameraHood = at(0, hoodAt(hoodCamZ) + DETAIL.hoodCamHeight, hoodCamZ),
			Mount_Roof = at(0, roofTop, (cabBack + back) / 2),
			Mount_Hood = at(0, hoodAt(midHoodZ), midHoodZ),
			Mount_Spoiler = at(0, roofTop, back - DETAIL.spoilerInset),
			Mount_FrontBumper = at(0, bumper.y, bumper.z, "forward"),
			Mount_RearBumper = at(0, rear.bumperY, rear.bumperZ, "back"),
			Mount_SideL = at(-hw, sideY, 0, "left"),
			Mount_SideR = at(hw, sideY, 0, "right"),
		},
	}
end

-- Semi tractor (generic): the Hauler's cab-over construction with its heights as shares of the body height,
-- so it fits any tractor size. Its fifth-wheel plate carries the Kingpin attachment.
local SEMI = {
	frameLift = 0.3, -- frame bottom above the chassis bottom
	cabShare = 1 / 3, -- cab length, share of the body length
	cabTop = 0.832, -- heights below are shares of the body height
	glassBottom = 0.576,
	glassTop = 0.792,
	grilleBottom = 0.36,
	grilleTop = 0.54,
	stripBottom = 0.552,
	stripTop = 0.564,
	headBottom = 0.368,
	headTop = 0.424,
	mirrorBottom = 0.592,
	mirrorTop = 0.752,
	seat = 0.48,
	sideGlassShare = 0.15, -- side windows run this share of the length back from the front
	kingpinAhead = 0.6, -- the kingpin sits this far ahead of the rear axle
	plateLift = 0.45, -- fifth-wheel plate bottom above the arch tops
	plateThickness = 0.35,
	plateDiameterShare = 0.5, -- of the body width
}

local function semiBody(ctx: Ctx): Shape
	local g = ctx.g
	local f = frameOf(g)
	local h = g.height
	local hw, front, back = f.halfWidth, f.front, f.back
	local af0, af1, ar0, ar1 = f.frontArchFront, f.frontArchBack, f.rearArchFront, f.rearArchBack
	local P = DETAIL.proud
	local frameBottom = g.rideHeight + SEMI.frameLift
	local cabBack = front + g.length * SEMI.cabShare
	local cabTop = h * SEMI.cabTop
	local glassBottom, glassTop = h * SEMI.glassBottom, h * SEMI.glassTop
	local fairingFront, fairingBack = front + 0.6, cabBack - 0.4
	local kingpinZ = g.wheelbase / 2 - SEMI.kingpinAhead
	local plateBottom = f.archTop + SEMI.plateLift
	local plateTop = plateBottom + SEMI.plateThickness

	box(ctx, "Frame", "dark", -f.wellHalfWidth, f.wellHalfWidth, frameBottom, f.archTop, af0, back - 0.1)
	box(ctx, "Bumper", "trim", -hw, hw, frameBottom - 0.1, f.archTop, front - 0.25, af0)
	box(ctx, "Cab", "paint", -hw, hw, f.archTop, cabTop, front, cabBack)
	box(ctx, "Windshield", "glass", -hw + 0.35, hw - 0.35, glassBottom, glassTop, front - 0.08, front + 0.05)
	local sideGlassBack = front + g.length * SEMI.sideGlassShare
	box(ctx, "SideGlass", "glass", -hw - 0.05, hw + 0.05, glassBottom, glassTop, front + 0.4, sideGlassBack)
	box(
		ctx,
		"Grille",
		"trim",
		-hw + 0.85,
		hw - 0.85,
		h * SEMI.grilleBottom,
		h * SEMI.grilleTop,
		front - 0.07,
		front + 0.05
	)
	box(
		ctx,
		"LightBar",
		"neon",
		-hw + 0.35,
		hw - 0.35,
		h * SEMI.stripBottom,
		h * SEMI.stripTop,
		front - 0.07,
		front + 0.03
	)
	wedge(ctx, "Fairing", "paint", "riseBack", -hw + 0.25, hw - 0.25, cabTop, h, fairingFront, fairingBack)
	box(ctx, "SideSkirts", "paint", -hw + 0.1, hw - 0.1, frameBottom, f.archTop, af1, ar0)
	box(ctx, "Fenders", "trim", -hw + 0.1, hw - 0.1, f.archTop + 0.04, f.archTop + 0.29, ar0 - 0.2, ar1 + 0.2)
	box(ctx, "FifthWheelBase", "trim", -1.8, 1.8, f.archTop, plateBottom, kingpinZ - 1.4, kingpinZ + 1.6)
	local plateCenter = Vector3.new(0, plateBottom + SEMI.plateThickness / 2, kingpinZ)
	cylinder(ctx, "FifthWheel", "trim", "y", plateCenter, g.width * SEMI.plateDiameterShare, SEMI.plateThickness)
	local flapBottom = frameBottom - 0.2
	pairBox(
		ctx,
		"Mudflap",
		"trim",
		f.wellHalfWidth + 0.05,
		hw - 0.1,
		flapBottom,
		f.archTop - 0.06,
		ar1 + 0.25,
		ar1 + 0.4
	)
	box(ctx, "RearGuard", "trim", -hw + 0.15, hw - 0.15, frameBottom - 0.1, frameBottom + 1.8, back - 0.4, back)
	mirrorPair(ctx, hw + 0.05, h * SEMI.mirrorBottom, h * SEMI.mirrorTop, front + 0.25, 0.65)

	pairLamp(ctx, "Head", "head", hw - 0.8, hw - 0.12, h * SEMI.headBottom, h * SEMI.headTop, front - 0.09, front + P)
	pairLamp(ctx, "Tail", "tail", hw - 0.95, hw - 0.2, frameBottom + 1.1, frameBottom + 1.6, back - 0.02, back + P)
	lamp(ctx, "Brake", "brake", -hw + 1.05, hw - 1.05, frameBottom + 1.35, frameBottom + 1.55, back - 0.02, back + P)
	lamp(ctx, "Reverse", "reverse", -0.5, 0.5, frameBottom + 0.65, frameBottom + 0.9, back - 0.02, back + P)

	local function fairingAt(z: number): number
		return cabTop + (h - cabTop) * (z - fairingFront) / (fairingBack - fairingFront)
	end
	local roofZ = (fairingFront + fairingBack) / 2
	local seatRow = front + g.length * SEMI.cabShare / 2 - 1
	local sideY = (glassBottom + f.archTop) / 2
	return {
		seating = {
			y = h * SEMI.seat,
			rows = seatRows(seatRow, cabBack - 1, rowCount(ctx)),
			spread2 = g.width * GENERIC.spread2Ratio,
			spread3 = g.width * GENERIC.spread3Ratio,
		},
		points = {
			PlateFront = at(0, (frameBottom + f.archTop) / 2, front - 0.25, "forward"),
			PlateRear = at(0, frameBottom + 0.35, back, "back"),
			CameraHood = at(0, glassTop + 0.2, front - 0.15),
			Mount_Roof = at(0, fairingAt(roofZ), roofZ),
			Mount_Hood = at(0, cabTop, front + 0.3),
			Mount_Spoiler = at(0, h, fairingBack),
			Mount_FrontBumper = at(0, (frameBottom + f.archTop) / 2 + 0.3, front - 0.25, "forward"),
			Mount_RearBumper = at(0, frameBottom + 0.8, back, "back"),
			Mount_SideL = at(-hw, sideY, front + g.length / 6, "left"),
			Mount_SideR = at(hw, sideY, front + g.length / 6, "right"),
			Kingpin = at(0, plateTop, kingpinZ),
		},
	}
end

-- One generic builder per bodyStyle (Config/Vehicles BodyStyle).
local STYLE_BUILDERS: { [string]: (Ctx) -> Shape } = {
	sedan = plainCar("sedan"),
	hatch = hatchBody,
	coupe = plainCar("coupe"),
	wagon = plainCar("wagon"),
	suv = plainCar("suv"),
	pickup = pickupBody,
	van = vanBody,
	minivan = minivanBody,
	muscle = muscleBody,
	exotic = function(ctx: Ctx): Shape
		local shape = exoticBody(ctx, CAR_STYLES.exotic)
		return shape
	end,
	offroad = offroadBody,
	tow = towBody,
	semi = semiBody,
	pod = plainCar("pod"),
	hypercar = hypercarBody,
}

-- Feature attachments a generic body has no special place for fall back to these spots.
local function withFeatureDefaults(ctx: Ctx, shape: Shape): Shape
	local g = ctx.g
	local f = frameOf(g)
	local bb = bodyBottom(g)
	local nozzleX, nozzleY = f.halfWidth * 0.42, (bb + f.archTop) / 2
	local defaults: { [string]: Point } = {
		TowHitch = at(0, bb + WORK.hitchLift, f.back + 0.5, "back"),
		Kingpin = at(0, f.archTop + SEMI.plateLift + SEMI.plateThickness, g.wheelbase / 2 - SEMI.kingpinAhead),
		Thruster_L = at(-nozzleX, nozzleY, f.back + 0.25, "back"),
		Thruster_R = at(nozzleX, nozzleY, f.back + 0.25, "back"),
		Thruster_Down = at(0, bb, 0.5, "down"),
	}
	for name, point in defaults do
		if shape.points[name] == nil then
			shape.points[name] = point
		end
	end
	return shape
end

-- Brand-tinted default paint: every part tagged Paint takes the brand's greybox color (Ohm keeps its silver).
local function tintPaint(model: Model, brandId: string)
	local color = brandLook(brandId).paint
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") and CollectionService:HasTag(descendant, "Paint") then
			descendant.Color = color
		end
	end
end

----------------------------------------------------------------------------------------------------------------
-- Wheels, seats and attachments (the same for every silhouette)
----------------------------------------------------------------------------------------------------------------

-- Hub center in chassis space at static ride height: x = +-track/2, z = -+wheelbase/2 (front is -Z),
-- y = wheelRadius - (rideHeight + chassisHeight / 2).
local function hubCFrame(g: Vehicles.Geometry, wheel: WheelSpec): CFrame
	local y = g.wheelRadius - (g.rideHeight + g.chassisHeight / 2)
	return CFrame.new(wheel.side * g.track / 2, y, wheel.axle * g.wheelbase / 2)
end

local function addWheels(ctx: Ctx)
	local g = ctx.g
	local diameter = 2 * g.wheelRadius
	for _, spec in WHEELS do
		local hub = hubCFrame(g, spec)
		local attachment = Instance.new("Attachment")
		attachment.Name = "Wheel" .. spec.name
		attachment.CFrame = hub
		attachment.Parent = ctx.chassis

		-- The tire is the wheel: a cylinder whose axle runs along X, so spinning is a rotation about X.
		local wheel = Instance.new("Part")
		wheel.Name = spec.name
		wheel.Shape = Enum.PartType.Cylinder
		wheel.Size = Vector3.new(g.wheelWidth, diameter, diameter)
		wheel.CFrame = ctx.chassis.CFrame * hub
		dress(wheel, "tire")

		-- Wheels move only through Motor.Transform: Part1 = Part0 * C0 * Transform * C1:Inverse().
		local motor = Instance.new("Motor6D")
		motor.Name = "Motor"
		motor.Part0 = ctx.chassis
		motor.Part1 = wheel
		motor.C0 = hub
		motor.C1 = CFrame.identity
		motor.Parent = wheel

		local rim = Instance.new("Part")
		rim.Name = "Rim"
		rim.Shape = Enum.PartType.Cylinder
		rim.Size = Vector3.new(g.wheelWidth + 2 * HUB_PROUD, diameter * RIM_RATIO, diameter * RIM_RATIO)
		rim.CFrame = wheel.CFrame
		dress(rim, "rim")
		weld(wheel, rim)
		rim.Parent = wheel

		local spoke = Instance.new("Part")
		spoke.Name = "Spoke"
		spoke.Size =
			Vector3.new(g.wheelWidth + 4 * HUB_PROUD, diameter * SPOKE_RATIO, g.wheelRadius * SPOKE_THICKNESS_RATIO)
		spoke.CFrame = wheel.CFrame
		dress(spoke, "spoke")
		weld(wheel, spoke)
		spoke.Parent = wheel

		wheel.Parent = ctx.wheels
	end
end

-- Seat names in seating order: Driver first when the vehicle has one, then Passenger1..N.
local function seatNames(vehicle: Vehicles.Vehicle, count: number): { string }
	local names = {}
	local hasDriver = vehicle.playerDrivable
	for i = 1, count do
		if hasDriver then
			table.insert(names, if i == 1 then "Driver" else `Passenger{i - 1}`)
		else
			table.insert(names, `Passenger{i}`)
		end
	end
	return names
end

local function addSeats(ctx: Ctx, seating: Seating)
	local count = ctx.trim.seats
	local plan = ROW_PLANS[count]
	if plan == nil then
		error(`{ctx.model.Name}: no seat layout for {count} seats`, 0)
	end
	if #seating.rows < #plan then
		error(`{ctx.model.Name}: {count} seats need {#plan} rows; the shape has {#seating.rows}`, 0)
	end
	local names = seatNames(ctx.vehicle, count)
	local index = 0
	for row, inRow in plan do
		local xs = if inRow == 1
			then { -seating.spread2 }
			elseif inRow == 2 then { -seating.spread2, seating.spread2 }
			else { -seating.spread3, 0, seating.spread3 }
		for _, x in xs do
			index += 1
			local seat = Instance.new("Seat")
			seat.Name = names[index]
			seat.Size = SEAT_SIZE
			seat.CFrame = CFrame.new(x, seating.y - SEAT_SIZE.Y / 2, seating.rows[row]) -- faces forward (-Z)
			dress(seat, "seat")
			seat.Disabled = false -- CanTouch is off, so walking into the car never sits anyone down
			weld(ctx.chassis, seat)
			seat.Parent = ctx.seats
		end
	end
end

-- Every attachment name a vehicle's model must have, in a stable order.
local function pointNames(vehicle: Vehicles.Vehicle): { string }
	local names = table.clone(REQUIRED_POINTS)
	for _, feature in vehicle.features do
		local extra = FEATURE_POINTS[feature]
		if extra then
			for _, name in extra do
				table.insert(names, name)
			end
		end
	end
	return names
end

-- Every car can be towed (Phase 8): its TowPoint sits Config/Trailers.towed.towPointAhead in front of the
-- Chassis' front face and towPointHeight above the ground, facing back like the TowHitch it mates with (so the
-- hitch's limits read zero with the two in line). Every TowHitch is higher, so coupling lifts the front wheels.
local function towPointOf(g: Vehicles.Geometry): Point
	local towed = Trailers.towed
	return at(0, towed.towPointHeight, -g.length / 2 - towed.towPointAhead, "back")
end

local function addPoints(ctx: Ctx, points: { [string]: Point })
	local lift = Vector3.new(0, ctx.chassisY, 0) -- ground space to chassis space
	for _, name in pointNames(ctx.vehicle) do
		local point = points[name]
		if point == nil then
			error(`{ctx.model.Name}: the shape has no {name} point`, 0)
		end
		local attachment = Instance.new("Attachment")
		attachment.Name = name
		attachment.CFrame = CFrame.new(point.position - lift) * FACINGS[point.facing]
		attachment.Parent = ctx.chassis
	end
end

----------------------------------------------------------------------------------------------------------------
-- Contract check
----------------------------------------------------------------------------------------------------------------

local TOLERANCE = 1e-3

local function nearVector(a: Vector3, b: Vector3): boolean
	return (a - b).Magnitude <= TOLERANCE
end

local function nearCFrame(a: CFrame, b: CFrame): boolean
	return nearVector(a.Position, b.Position)
		and nearVector(a.LookVector, b.LookVector)
		and nearVector(a.UpVector, b.UpVector)
end

-- The part a visual part is jointed to (through a WeldConstraint or Motor6D it holds), if any.
local function jointTarget(part: BasePart): BasePart?
	for _, child in part:GetChildren() do
		if child:IsA("WeldConstraint") or child:IsA("Motor6D") then
			local joint = child :: any -- both classes have Part0 and Part1
			if joint.Part1 == part then
				return joint.Part0
			end
		end
	end
	return nil
end

-- Lists every way `model` breaks the vehicle model contract for this vehicle, trim and geometry, named `name`. An
-- empty list means it follows it. Works on any model, greybox or artist-made (Dev/VehicleBuilder.check looks the
-- entry up in the catalog from the model's attributes; Vehicle/SpecBuilder passes a design's own entry).
function BodyKit.check(
	model: Model,
	vehicle: Vehicles.Vehicle,
	trim: Vehicles.Trim,
	g: Vehicles.Geometry,
	modelName: string
): { string }
	local problems: { string } = {}
	local function problem(message: string)
		table.insert(problems, `{model.Name}: {message}`)
	end

	if model:GetAttribute("VehicleId") ~= vehicle.id or model:GetAttribute("Trim") ~= trim.id then
		problem(`VehicleId and Trim attributes must be {vehicle.id} and {trim.id}`)
	end
	if model.Name ~= modelName then
		problem(`must be named {modelName}`)
	end
	if model:GetAttribute("BrandId") ~= vehicle.brandId then
		problem("BrandId attribute does not match the catalog")
	end
	if model.ModelStreamingMode ~= Enum.ModelStreamingMode.Atomic then
		problem("ModelStreamingMode must be Atomic")
	end

	local chassis = model:FindFirstChild("Chassis")
	if chassis == nil or not chassis:IsA("Part") then
		problem("has no Chassis part")
		return problems
	end
	if model.PrimaryPart ~= chassis then
		problem("PrimaryPart must be Chassis")
	end
	if not nearVector(chassis.Size, Vector3.new(g.width, g.chassisHeight, g.length)) then
		problem("Chassis size must be (width, chassisHeight, length)")
	end
	local restCFrame = CFrame.new(0, g.rideHeight + g.chassisHeight / 2, 0)
	if not nearCFrame(model:GetPivot():ToObjectSpace(chassis.CFrame), restCFrame) then
		problem("pivot must be the ground point under the chassis center, facing forward")
	end
	if chassis.Transparency ~= 1 or not chassis.CanCollide or chassis.Massless then
		problem("Chassis must be invisible, collide, and carry the mass")
	end
	if chassis.CustomPhysicalProperties == nil then
		problem("Chassis needs CustomPhysicalProperties")
	end

	for _, name in { "Body", "Wheels", "Seats", "Lights" } do
		local folder = model:FindFirstChild(name)
		if folder == nil or not folder:IsA("Folder") then
			problem(`missing {name} folder`)
		end
	end

	local wheels = model:FindFirstChild("Wheels")
	for _, spec in WHEELS do
		local expected = hubCFrame(g, spec)
		local hub = chassis:FindFirstChild("Wheel" .. spec.name)
		if hub == nil or not hub:IsA("Attachment") then
			problem(`missing attachment Wheel{spec.name}`)
		elseif not nearCFrame(hub.CFrame, expected) then
			problem(`Wheel{spec.name} must sit at the hub center at ride height`)
		end
		local wheel = if wheels then wheels:FindFirstChild(spec.name) else nil
		if wheel == nil or not wheel:IsA("Part") then
			problem(`missing wheel {spec.name}`)
			continue
		end
		local diameter = 2 * g.wheelRadius
		if
			wheel.Shape ~= Enum.PartType.Cylinder
			or not nearVector(wheel.Size, Vector3.new(g.wheelWidth, diameter, diameter))
		then
			problem(`wheel {spec.name} must be a cylinder sized (wheelWidth, 2 * wheelRadius, 2 * wheelRadius)`)
		end
		local motor = wheel:FindFirstChild("Motor")
		if motor == nil or not motor:IsA("Motor6D") then
			problem(`wheel {spec.name} needs a Motor6D named Motor`)
		elseif
			motor.Part0 ~= chassis
			or motor.Part1 ~= wheel
			or not nearCFrame(motor.C0, expected)
			or not nearCFrame(motor.C1, CFrame.identity)
		then
			problem(`wheel {spec.name}: Motor must join Chassis to the wheel with C0 = hub and C1 = identity`)
		end
	end

	local seats = model:FindFirstChild("Seats")
	local seatCount = 0
	if seats then
		for _, child in seats:GetChildren() do
			if child:IsA("Seat") then
				seatCount += 1
				if child.CanTouch or child.Disabled then
					problem(`seat {child.Name} must have CanTouch = false and Disabled = false`)
				end
			end
		end
	end
	if seatCount ~= trim.seats then
		problem(`has {seatCount} seats; the trim has {trim.seats}`)
	end
	local expectedSeats = seatNames(vehicle, trim.seats)
	for _, name in expectedSeats do
		local seat = if seats then seats:FindFirstChild(name) else nil
		if seat == nil or not seat:IsA("Seat") then
			problem(`missing seat {name}`)
		elseif name == "Driver" and chassis.CFrame:PointToObjectSpace(seat.Position).X >= 0 then
			problem("Driver seat must be on the left")
		end
	end
	if not vehicle.playerDrivable and seats and seats:FindFirstChild("Driver") then
		problem("must not have a Driver seat (not player-drivable)")
	end

	local lights = model:FindFirstChild("Lights")
	for _, name in LIGHT_NAMES do
		local lampPart = if lights then lights:FindFirstChild(name) else nil
		local light = if lampPart then lampPart:FindFirstChild("Light") else nil
		if light == nil or not (light:IsA("SpotLight") or light:IsA("SurfaceLight")) then
			problem(`lamp {name} needs a SpotLight or SurfaceLight named Light`)
		elseif (light :: any).Enabled then
			problem(`lamp {name} must start with its Light disabled`)
		end
	end

	for _, name in pointNames(vehicle) do
		local point = chassis:FindFirstChild(name)
		if point == nil or not point:IsA("Attachment") then
			problem(`missing attachment {name} on Chassis`)
		end
	end
	-- The towed car's hitch point (Phase 8): at the front, facing back like a TowHitch.
	local towPoint = chassis:FindFirstChild(TOW_POINT)
	if towPoint and towPoint:IsA("Attachment") then
		if towPoint.Position.Z > -g.length / 2 + TOLERANCE then
			problem(`{TOW_POINT} must sit at or ahead of the Chassis' front face`)
		end
		if not nearVector(towPoint.CFrame.LookVector, Vector3.zAxis) then
			problem(`{TOW_POINT} must face back, like the TowHitch it mates with`)
		end
	end

	local partCount, paintCount, glassCount = 0, 0, 0
	for _, descendant in model:GetDescendants() do
		if not descendant:IsA("BasePart") then
			continue
		end
		partCount += 1
		if CollectionService:HasTag(descendant, "Paint") then
			paintCount += 1
		end
		if CollectionService:HasTag(descendant, "Glass") then
			glassCount += 1
		end
		if descendant == chassis then
			continue
		end
		if
			not descendant.Massless
			or descendant.Anchored
			or descendant.CanCollide
			or descendant.CanTouch
			or descendant.CanQuery
		then
			problem(`{descendant.Name} must be Massless and unanchored, with CanCollide, CanTouch and CanQuery off`)
		end
		-- Joined to the chassis, or riding on the wheel or door it is parented to.
		local target = jointTarget(descendant)
		if target == nil or (target ~= chassis and target ~= descendant.Parent) then
			problem(`{descendant.Name} must be welded to Chassis (or to the wheel or door it sits on)`)
		end
	end
	if partCount > MAX_PARTS then
		problem(`has {partCount} parts; the greybox budget is {MAX_PARTS}`)
	end
	if paintCount == 0 or glassCount == 0 then
		problem("needs parts tagged Paint and Glass")
	end

	return problems
end

----------------------------------------------------------------------------------------------------------------
-- Assembly
----------------------------------------------------------------------------------------------------------------

-- The generic body builder for a bodyStyle (with the feature attachments a generic body falls back to), or nil for
-- a style without one.
function BodyKit.genericShape(bodyStyle: string): ((Ctx) -> Shape)?
	local builder = STYLE_BUILDERS[bodyStyle]
	if builder == nil then
		return nil
	end
	return function(ctx: Ctx): Shape
		return withFeatureDefaults(ctx, builder(ctx))
	end
end

-- Every bodyStyle with a generic body, sorted.
function BodyKit.bodyStyles(): { string }
	local styles = {}
	for style in STYLE_BUILDERS do
		table.insert(styles, style)
	end
	table.sort(styles)
	return styles
end

export type AssembleOptions = {
	name: string, -- the model's name
	shape: ((Ctx) -> Shape)?, -- a bespoke silhouette; nil builds the generic body for vehicle.bodyStyle
	design: Design?, -- a player design's parts (Vehicle/SpecBuilder); nil for catalog cars
}

local function newFolder(name: string, parent: Instance): Folder
	local folder = Instance.new("Folder")
	folder.Name = name
	folder.Parent = parent
	return folder
end

-- Builds a trim's model at geometry `g`: the chassis, the body, wheels, seats, lamps and the contract attachments,
-- with the pivot (the ground point under the chassis center) at the origin. Not parented, painted or checked: the
-- caller tints or paints it and runs check(). Errors when the shape can't be built at this geometry.
function BodyKit.assemble(
	vehicle: Vehicles.Vehicle,
	trim: Vehicles.Trim,
	g: Vehicles.Geometry,
	options: AssembleOptions
): Model
	local shapeOf: ((Ctx) -> Shape)? = options.shape or BodyKit.genericShape(vehicle.bodyStyle)
	if shapeOf == nil then
		error(`no greybox shape for {vehicle.id}: unknown bodyStyle "{vehicle.bodyStyle}"`, 2)
	end

	local model = Instance.new("Model")
	model.Name = options.name
	model.ModelStreamingMode = Enum.ModelStreamingMode.Atomic
	model:SetAttribute("BrandId", vehicle.brandId)
	model:SetAttribute("VehicleId", vehicle.id)
	model:SetAttribute("Trim", trim.id)

	-- The chassis box: the only physics body. Its bottom face sits rideHeight above the ground point.
	local chassisY = g.rideHeight + g.chassisHeight / 2
	local chassis = Instance.new("Part")
	chassis.Name = "Chassis"
	chassis.Size = Vector3.new(g.width, g.chassisHeight, g.length)
	chassis.CFrame = CFrame.new(0, chassisY, 0)
	chassis.Transparency = 1
	chassis.CanCollide = true
	chassis.CastShadow = false
	chassis.Material = SMOOTH
	chassis.TopSurface = Enum.SurfaceType.Smooth
	chassis.BottomSurface = Enum.SurfaceType.Smooth
	chassis.Anchored = true -- stored parked; VehicleService unanchors it when the owner takes the wheel
	chassis.CustomPhysicalProperties =
		PhysicalProperties.new(Driving.chassisDensity, CHASSIS_FRICTION, CHASSIS_ELASTICITY)
	-- With a PrimaryPart, the model's pivot is PrimaryPart.CFrame * PivotOffset: the ground under the center.
	chassis.PivotOffset = CFrame.new(0, -chassisY, 0)
	chassis.Parent = model
	model.PrimaryPart = chassis

	local ctx: Ctx = {
		vehicle = vehicle,
		trim = trim,
		g = g,
		model = model,
		chassis = chassis,
		chassisY = chassisY,
		body = newFolder("Body", model),
		wheels = newFolder("Wheels", model),
		seats = newFolder("Seats", model),
		lights = newFolder("Lights", model),
		doors = nil,
		design = options.design,
	}

	local ok, err = pcall(function()
		local shape = shapeOf(ctx)
		if shape.points[TOW_POINT] == nil then
			shape.points[TOW_POINT] = towPointOf(g)
		end
		addWheels(ctx)
		addSeats(ctx, shape.seating)
		addPoints(ctx, shape.points)
	end)
	if not ok then
		model:Destroy()
		error(err, 0)
	end
	return model
end

-- Every BasePart in a model (the contract's part budget counts these).
function BodyKit.partCount(model: Model): number
	local count = 0
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			count += 1
		end
	end
	return count
end

-- The height of the wheel-arch tops above the ground for a geometry (where the body's sides open over the tires).
function BodyKit.archTop(g: Vehicles.Geometry): number
	return 2 * g.wheelRadius + ARCH_TOP_CLEARANCE
end

-- The physics geometry of a built contract model, read back from it: the Chassis box, the wheels' hub attachments
-- and the front-left tire. `height` is the top of its Body. nil for a model without those.
function BodyKit.readGeometry(model: Model): Vehicles.Geometry?
	local chassis = model:FindFirstChild("Chassis")
	local wheels = model:FindFirstChild("Wheels")
	if chassis == nil or not chassis:IsA("BasePart") or wheels == nil then
		return nil
	end
	local front, right, rear =
		chassis:FindFirstChild("WheelFL"), chassis:FindFirstChild("WheelFR"), chassis:FindFirstChild("WheelRL")
	local tire = wheels:FindFirstChild("FL")
	if
		front == nil
		or not front:IsA("Attachment")
		or right == nil
		or not right:IsA("Attachment")
		or rear == nil
		or not rear:IsA("Attachment")
		or tire == nil
		or not tire:IsA("BasePart")
	then
		return nil
	end
	local size = chassis.Size
	local radius = tire.Size.Y / 2
	local rideHeight = radius - size.Y / 2 - front.Position.Y
	local centerY = rideHeight + size.Y / 2
	local top = size.Y / 2
	local body = model:FindFirstChild("Body")
	if body then
		for _, part in body:GetDescendants() do
			if part:IsA("BasePart") then
				local rel = chassis.CFrame:ToObjectSpace(part.CFrame)
				local half = part.Size / 2
				local reach = math.abs(rel.XVector.Y) * half.X
					+ math.abs(rel.YVector.Y) * half.Y
					+ math.abs(rel.ZVector.Y) * half.Z
				top = math.max(top, rel.Position.Y + reach)
			end
		end
	end
	return {
		length = size.Z,
		width = size.X,
		height = centerY + top,
		wheelbase = math.abs(rear.Position.Z - front.Position.Z),
		track = math.abs(right.Position.X - front.Position.X),
		wheelRadius = radius,
		wheelWidth = tire.Size.X,
		rideHeight = rideHeight,
		chassisHeight = size.Y,
	}
end

----------------------------------------------------------------------------------------------------------------
-- Design paint, spoilers and stripes (Phase 11). They work on any contract model, so Vehicle/SpecBuilder uses them
-- on a new design and Vehicle/ModBuilder on any car a mod changes.
----------------------------------------------------------------------------------------------------------------

export type Finish = { material: Enum.Material, reflectance: number }

-- Painted panels that take a design's secondary color (a two-tone roof).
local ROOF_PANELS: { [string]: boolean } = { Roof = true, CabRoof = true, RoofCap = true }

-- The CollectionService tag parts in a look carry ("paint" -> Paint, "glass" -> Glass).
local function tagOf(look: Look): string
	return LOOKS[look].tag or ""
end

-- Paints every Paint-tagged part `primary` (roof panels `secondary`), with the finish's material when given.
function BodyKit.paint(model: Model, primary: Color3, secondary: Color3, finish: Finish?)
	local tag = tagOf("paint")
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") and CollectionService:HasTag(descendant, tag) then
			descendant.Color = if ROOF_PANELS[descendant.Name] then secondary else primary
			if finish then
				descendant.Material = finish.material
				descendant.Reflectance = finish.reflectance
			end
		end
	end
end

-- Spoiler variants (DesignKit parts.spoiler) on the Mount_Spoiler attachment. Pieces are in mount space (+Y up,
-- -Z forward; a wedge is tall at the back): `center` and `size` in studs, except x, which is a share of the body's
-- half-width for centers and of its width for sizes. "none" has no pieces.
type SpoilerPiece = { name: string, look: Look, wedge: boolean, center: Vector3, size: Vector3 }
local SPOILERS: { [string]: { SpoilerPiece } } = {
	none = {},
	lip = {
		{
			name = "SpoilerLip",
			look = "paint",
			wedge = true,
			center = Vector3.new(0, 0.07, 0.1),
			size = Vector3.new(0.82, 0.14, 0.5),
		},
	},
	ducktail = {
		{
			name = "Ducktail",
			look = "paint",
			wedge = true,
			center = Vector3.new(0, 0.15, 0.05),
			size = Vector3.new(0.9, 0.3, 0.9),
		},
	},
	wing = {
		{
			name = "WingPostL",
			look = "dark",
			wedge = false,
			center = Vector3.new(-0.55, 0.28, 0.15),
			size = Vector3.new(0.03, 0.56, 0.3),
		},
		{
			name = "WingPostR",
			look = "dark",
			wedge = false,
			center = Vector3.new(0.55, 0.28, 0.15),
			size = Vector3.new(0.03, 0.56, 0.3),
		},
		{
			name = "WingBlade",
			look = "trim",
			wedge = false,
			center = Vector3.new(0, 0.62, 0.2),
			size = Vector3.new(0.86, 0.1, 0.7),
		},
	},
}

-- Builds a spoiler variant on the model's Mount_Spoiler (welded to the Chassis, in Body). Returns how many parts
-- it added: 0 for "none", an unknown variant or a model without the mount.
function BodyKit.addSpoiler(model: Model, variant: string): number
	local pieces = SPOILERS[variant]
	local chassis = model:FindFirstChild("Chassis")
	local body = model:FindFirstChild("Body")
	local mount = if chassis then chassis:FindFirstChild("Mount_Spoiler") else nil
	if
		pieces == nil
		or chassis == nil
		or not chassis:IsA("BasePart")
		or body == nil
		or mount == nil
		or not mount:IsA("Attachment")
	then
		return 0
	end
	local width = chassis.Size.X
	local base = chassis.CFrame * mount.CFrame
	for _, piece in pieces do
		local part: BasePart = if piece.wedge then Instance.new("WedgePart") else Instance.new("Part")
		part.Name = piece.name
		part.Size = Vector3.new(piece.size.X * width, piece.size.Y, piece.size.Z)
		part.CFrame = base * CFrame.new(piece.center.X * width / 2, piece.center.Y, piece.center.Z)
		dress(part, piece.look)
		weld(chassis, part)
		part.Parent = body
	end
	return #pieces
end

-- Stripes (DesignKit paint.stripe): thin bands in a design's secondary color on any contract model's painted
-- panels. "center" runs along the top (nose, hood, roof, deck), "side" along both flanks between the wheel tops and
-- the window line. They sit in Body (so ride height carries them), are never tagged Paint (a repaint keeps them) and
-- carry STRIPE.tag, so clearStripes can take them off again. Sizes in studs unless noted.
local STRIPE = {
	tag = "DesignStripe",
	name = "PaintStripe",
	thickness = 0.03,
	proud = 0.01, -- off the panel face
	centerShare = 0.16, -- center stripe width, share of the body width
	sideHeight = 0.16,
	sideMargin = 0.08, -- the side stripe keeps this far from the wheel tops and the window line
	minLength = 0.3, -- shorter pieces are dropped
	probe = 0.03, -- a part this close past a panel face covers it
	joinGap = 0.02, -- side pieces this close end to end (and as far out) become one
	aligned = 0.999, -- an axis this parallel to the chassis's counts as aligned with it
	minUp = 0.3, -- a sloped panel takes the center stripe when its slope faces at least this much upward
	flankShare = 0.9, -- a face this share of the body's half-width out (or more) is a flank
	maxParts = 8, -- per car
}

type Panel = { part: BasePart, rel: CFrame, min: Vector3, max: Vector3 }

-- A part's chassis-space CFrame and bounding box.
local function panelOf(part: BasePart, chassisCFrame: CFrame): Panel
	local rel = chassisCFrame:ToObjectSpace(part.CFrame)
	local half = part.Size / 2
	local x, y, z = rel.XVector, rel.YVector, rel.ZVector
	local extent = Vector3.new(
		math.abs(x.X) * half.X + math.abs(y.X) * half.Y + math.abs(z.X) * half.Z,
		math.abs(x.Y) * half.X + math.abs(y.Y) * half.Y + math.abs(z.Y) * half.Z,
		math.abs(x.Z) * half.X + math.abs(y.Z) * half.Y + math.abs(z.Z) * half.Z
	)
	return { part = part, rel = rel, min = rel.Position - extent, max = rel.Position + extent }
end

-- An upright block whose axes line up with the chassis's (its faces run along the car).
local function isAlignedBlock(panel: Panel): boolean
	local part = panel.part
	return part:IsA("Part")
		and part.Shape == Enum.PartType.Block
		and panel.rel.YVector.Y >= STRIPE.aligned
		and math.abs(panel.rel.XVector.X) >= STRIPE.aligned
end

local function contains(panel: Panel, point: Vector3): boolean
	return point.X >= panel.min.X
		and point.X <= panel.max.X
		and point.Y >= panel.min.Y
		and point.Y <= panel.max.Y
		and point.Z >= panel.min.Z
		and point.Z <= panel.max.Z
end

-- Removes [cut0, cut1] from a list of disjoint spans.
local function subtract(spans: { { number } }, cut0: number, cut1: number): { { number } }
	local result: { { number } } = {}
	for _, span in spans do
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

type StripeBuild = {
	chassis: BasePart,
	body: Instance,
	color: Color3,
	panels: { Panel }, -- every part directly in Body and Lights (covers)
	painted: { Panel }, -- Paint-tagged Body parts (take stripes)
	count: number,
	budget: number,
}

local function addStripe(build: StripeBuild, size: Vector3, rel: CFrame)
	if build.count >= build.budget then
		return
	end
	build.count += 1
	local part = Instance.new("Part")
	part.Name = STRIPE.name
	part.Size = size
	part.CFrame = build.chassis.CFrame * rel
	dress(part, "dark") -- untagged: no repaint, wrap or tint ever recolors a stripe
	part.Color = build.color
	CollectionService:AddTag(part, STRIPE.tag)
	weld(build.chassis, part)
	part.Parent = build.body
end

local function centerStripes(build: StripeBuild)
	local half = build.chassis.Size.X * STRIPE.centerShare / 2
	local lift = STRIPE.proud + STRIPE.thickness / 2
	for _, panel in build.painted do
		local part, rel = panel.part, panel.rel
		if panel.min.X > -half or panel.max.X < half then
			continue
		end
		local size = part.Size
		if part:IsA("WedgePart") then
			-- A slope facing up (nose, hood, ducktail): one stripe the length of the slope, which runs from the
			-- wedge's bottom front edge to its top back edge through its center.
			if math.abs(rel.XVector.X) < STRIPE.aligned then
				continue
			end
			local normal = rel:VectorToWorldSpace(Vector3.new(0, size.Z, -size.Y).Unit)
			local slope = math.sqrt(size.Y * size.Y + size.Z * size.Z)
			if normal.Y < STRIPE.minUp or slope < STRIPE.minLength then
				continue
			end
			local localX = -rel.Position.X * rel.XVector.X
			local tilt = -math.atan2(size.Y, size.Z)
			local onSlope = rel * CFrame.new(localX, 0, 0) * CFrame.Angles(tilt, 0, 0) * CFrame.new(0, lift, 0)
			addStripe(build, Vector3.new(2 * half, STRIPE.thickness, slope), onSlope)
		elseif isAlignedBlock(panel) then
			local length = panel.max.Z - panel.min.Z
			local z = (panel.min.Z + panel.max.Z) / 2
			local top = panel.max.Y
			if length < STRIPE.minLength then
				continue
			end
			-- Only a top nothing sits on (a roof or deck, not a sill under the windows).
			local probe = Vector3.new(0, top + STRIPE.probe, z)
			local covered = false
			for _, other in build.panels do
				if other.part ~= part and contains(other, probe) then
					covered = true
					break
				end
			end
			if not covered then
				addStripe(build, Vector3.new(2 * half, STRIPE.thickness, length), CFrame.new(0, top + lift, z))
			end
		end
	end
end

local function sideStripes(build: StripeBuild, wheelTop: number)
	-- The band runs between the wheel tops and the window line (the lowest glass).
	local windows = math.huge
	for _, panel in build.panels do
		if CollectionService:HasTag(panel.part, tagOf("glass")) then
			windows = math.min(windows, panel.min.Y)
		end
	end
	local low, high = wheelTop + STRIPE.sideMargin, windows - STRIPE.sideMargin
	local height = math.min(STRIPE.sideHeight, high - low)
	if windows == math.huge or height <= 0 then
		return
	end
	local y = (low + high) / 2
	local y0, y1 = y - height / 2, y + height / 2
	local halfWidth = 0
	for _, panel in build.painted do
		halfWidth = math.max(halfWidth, math.abs(panel.min.X), math.abs(panel.max.X))
	end

	for _, side in SIDES do
		local s = side.sign
		-- Open stretches of every flank face that spans the band, as { z0, z1, x }.
		local pieces: { { number } } = {}
		for _, panel in build.painted do
			if not isAlignedBlock(panel) or panel.min.Y > y0 or panel.max.Y < y1 then
				continue
			end
			local x = if s > 0 then panel.max.X else panel.min.X
			if x * s < STRIPE.flankShare * halfWidth then
				continue
			end
			local probe = x + s * STRIPE.probe
			local open: { { number } } = { { panel.min.Z, panel.max.Z } }
			for _, other in build.panels do
				if
					other.part ~= panel.part
					and probe >= other.min.X
					and probe <= other.max.X
					and y1 > other.min.Y
					and y0 < other.max.Y
				then
					open = subtract(open, other.min.Z, other.max.Z)
				end
			end
			for _, span in open do
				table.insert(pieces, { span[1], span[2], x })
			end
		end
		table.sort(pieces, function(a, b)
			return a[1] < b[1]
		end)
		-- Join pieces that meet end to end at the same depth, so a flank is one stripe where it can be.
		local joined: { { number } } = {}
		for _, piece in pieces do
			local last = joined[#joined]
			if
				last ~= nil
				and piece[1] <= last[2] + STRIPE.joinGap
				and math.abs(piece[3] - last[3]) <= STRIPE.joinGap
			then
				last[2] = math.max(last[2], piece[2])
			else
				table.insert(joined, { piece[1], piece[2], piece[3] })
			end
		end
		for _, piece in joined do
			local length = piece[2] - piece[1]
			if length >= STRIPE.minLength then
				local x = piece[3] + s * (STRIPE.proud + STRIPE.thickness / 2)
				addStripe(
					build,
					Vector3.new(STRIPE.thickness, height, length),
					CFrame.new(x, y, (piece[1] + piece[2]) / 2)
				)
			end
		end
	end
end

-- Lays a stripe kind ("center" or "side"; "none" or anything else lays nothing) on the model, at most `budget`
-- parts (default STRIPE.maxParts). Returns how many parts it added.
function BodyKit.addStripes(model: Model, kind: string, color: Color3, budget: number?): number
	local chassis = model:FindFirstChild("Chassis")
	local body = model:FindFirstChild("Body")
	if chassis == nil or not chassis:IsA("BasePart") or body == nil or (kind ~= "center" and kind ~= "side") then
		return 0
	end
	local paintTag = tagOf("paint")
	local build: StripeBuild = {
		chassis = chassis,
		body = body,
		color = color,
		panels = {},
		painted = {},
		count = 0,
		budget = math.min(budget or STRIPE.maxParts, STRIPE.maxParts),
	}
	-- The body itself: the parts directly in Body and Lights. Anything grouped inside them (a mod's extras, built as
	-- Models by Vehicle/Appearance) is not body, so stripes come out the same with or without extras on the car.
	for _, folderName in { "Body", "Lights" } do
		local folder = model:FindFirstChild(folderName)
		if folder == nil then
			continue
		end
		for _, part in folder:GetChildren() do
			if not part:IsA("BasePart") or CollectionService:HasTag(part, STRIPE.tag) then
				continue
			end
			local panel = panelOf(part, chassis.CFrame)
			table.insert(build.panels, panel)
			if folderName == "Body" and CollectionService:HasTag(part, paintTag) then
				table.insert(build.painted, panel)
			end
		end
	end
	if kind == "center" then
		centerStripes(build)
	else
		local wheelTop = -math.huge
		local wheels = model:FindFirstChild("Wheels")
		if wheels then
			for _, wheel in wheels:GetChildren() do
				if wheel:IsA("BasePart") then
					local rel = chassis.CFrame:ToObjectSpace(wheel.CFrame)
					wheelTop = math.max(wheelTop, rel.Position.Y + math.min(wheel.Size.Y, wheel.Size.Z) / 2)
				end
			end
		end
		if wheelTop > -math.huge then
			sideStripes(build, wheelTop)
		end
	end
	return build.count
end

-- Removes every stripe addStripes laid on the model.
function BodyKit.clearStripes(model: Model)
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") and CollectionService:HasTag(descendant, STRIPE.tag) then
			descendant:Destroy()
		end
	end
end

-- The stripe parts on a model (for tests and recoloring).
function BodyKit.stripes(model: Model): { BasePart }
	local list: { BasePart } = {}
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") and CollectionService:HasTag(descendant, STRIPE.tag) then
			table.insert(list, descendant)
		end
	end
	return list
end

----------------------------------------------------------------------------------------------------------------
-- Exports for the bespoke silhouettes (Dev/VehicleBuilder) and the design builders
----------------------------------------------------------------------------------------------------------------

BodyKit.MAX_PARTS = MAX_PARTS
BodyKit.DETAIL = DETAIL
BodyKit.SIDES = SIDES
BodyKit.SEATED_HEAD_ROOM = SEATED_HEAD_ROOM
BodyKit.HUB_PROUD = HUB_PROUD
BodyKit.LIGHT_NAMES = LIGHT_NAMES
BodyKit.MIN_ROOM_OVER_ARCHES = MIN_ROOM_OVER_ARCHES
BodyKit.VISUAL_POINTS = VISUAL_POINTS
BodyKit.ROOF_PANELS = ROOF_PANELS

BodyKit.frameOf = frameOf
BodyKit.dress = dress
BodyKit.weld = weld
BodyKit.newBlock = newBlock
BodyKit.box = box
BodyKit.pairBox = pairBox
BodyKit.wedge = wedge
BodyKit.cylinder = cylinder
BodyKit.lamp = lamp
BodyKit.pairLamp = pairLamp
BodyKit.hang = hang
BodyKit.at = at
BodyKit.hubCFrame = hubCFrame
BodyKit.tintPaint = tintPaint

return BodyKit
