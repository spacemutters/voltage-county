--!strict
-- Greybox vehicle builder (PLAN.md §6, docs/phase-1-contracts.md "Vehicle model contract"). Builds one
-- original, untextured model per trim into ServerStorage.VehicleModels, sized from Config/Vehicles through
-- Vehicle/Catalog. Final art replaces these models later without code changes, as long as it keeps the same
-- contract (docs/ART_BRIEF.md has it as a checklist).
--
-- Edit-mode tool only (CLAUDE.md hard rule 9). Run it from the Studio command bar or MCP execute_luau
-- (Edit datamodel):
--   require(game.ServerScriptService.Server.Dev.VehicleBuilder).buildAll()
--
-- API
--   buildAll(): {string}               rebuilds every trim's model; returns the names built
--   build(vehicleId, trimId, options?)  rebuilds one model and returns it
--   assemble(vehicleId, trimId)         builds a model without parenting it anywhere (for specs)
--   assembleGeneric(vehicleId, trimId)  same, but always the generic body for the vehicle's bodyStyle
--   bodyStyles(): {string}              every bodyStyle with a generic body
--   check(model): {string}              lists every way a model breaks the contract (empty = good)
--
-- Bodies: the eight Ohm vehicles keep their bespoke silhouettes (SHAPES). Every other vehicle gets a generic
-- body built from its bodyStyle and geometry (STYLE_BUILDERS, Phase 4), with its brand's face, tail lamps and
-- default paint (BRAND_LOOKS).
--
-- Building is idempotent: a rebuild replaces the old model and produces the same instances every time. Models
-- built here carry the attribute Greybox = true. A model without it (artist-made) is never overwritten unless
-- build() is called with { replaceArt = true }. Every model is checked against the contract before it is
-- stored, so a broken shape fails the build instead of reaching the game.
--
-- Shapes are authored in "ground space": the origin is the point on the ground under the chassis center,
-- +X is right, +Y is up and the front of the car is -Z (the chassis LookVector). The model's pivot is that
-- ground point, so model:PivotTo(groundCFrame) parks the car at ride height. The numbers inside each shape
-- function are the greybox art itself (panel positions in studs), not gameplay tunables.

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")

local Catalog = require(ReplicatedStorage.Shared.Vehicle.Catalog)
local Driving = require(ReplicatedStorage.Shared.Config.Driving)
local Trailers = require(ReplicatedStorage.Shared.Config.Trailers)
local Vehicles = require(ReplicatedStorage.Shared.Config.Vehicles)

local MODELS_FOLDER = "VehicleModels"
local GREYBOX_ATTRIBUTE = "Greybox" -- marks models this builder owns; artist models never carry it
local MAX_PARTS = 60 -- greybox budget per model (PLAN.md Phase 14)

-- Chassis surface (model contract). The suspension is raycast, so the box only touches the world in a crash or
-- a rollover. Its density comes from Config/Driving.chassisDensity.
local CHASSIS_FRICTION = 0.3
local CHASSIS_ELASTICITY = 0

-- Wheel arches: the opening runs this far past the tire front and back, and this far above its top.
local ARCH_CLEARANCE = 0.25
local ARCH_TOP_CLEARANCE = 0.06
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

-- Gull-wing doors (feature "gullwing"): hinged near the roof centerline, opened by rotating the Hinge motor.
local GULLWING = {
	hingeFromCenter = 0.5, -- hinge line distance from the car's centerline
	openAngle = 75, -- degrees; stored signed on each door as the OpenAngle attribute
	halfLength = 1.25, -- door half-length along the car, centered on the second seat row
	archGap = 0.05, -- the door's back edge stops this far ahead of the rear wheel arch
	thickness = 0.2,
	sillLift = 0.45, -- door bottom above the body bottom
	windowInset = 0.18, -- window edge inset from the door edge, front/back
	windowMargin = 0.12, -- window edge inset from the beltline and roof
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

type Look =
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
type Facing = "forward" | "back" | "left" | "right" | "down"
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

type WheelSpec = { name: string, side: number, axle: number }
local WHEELS: { WheelSpec } = {
	{ name = "FL", side = -1, axle = -1 },
	{ name = "FR", side = 1, axle = -1 },
	{ name = "RL", side = -1, axle = 1 },
	{ name = "RR", side = 1, axle = 1 },
}

local SIDES = { { sign = -1, suffix = "L" }, { sign = 1, suffix = "R" } }

type Point = { position: Vector3, facing: Facing } -- ground space
type Seating = {
	y: number, -- seat surface height above the ground
	rows: { number }, -- z of each seat row, front row first
	spread2: number, -- seat x offset in a two-across row (a one-seat row uses the left position)
	spread3: number, -- x offset of the outer seats in a three-across row
}
type Shape = { seating: Seating, points: { [string]: Point } }

type Ctx = {
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
}

-- Lengthwise landmarks every silhouette is built around.
type Frame = {
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

local VehicleBuilder = {}

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
-- Sedan family: Spark, Current, Grand and Summit share one construction and differ by profile.
----------------------------------------------------------------------------------------------------------------

type Profile = {
	bodyBottom: number, -- bottom of the body panels
	chin: number, -- height of the chamfered chin under the nose
	noseTop: number, -- top of the vertical nose face, where the nose chamfer starts
	hoodFront: number, -- hood height over the front arch (raised to the arch top if lower)
	belt: number, -- beltline: hood height at the windshield base, and the side-window sill
	cowl: number, -- windshield base, studs back from the front end
	roofFront: number, -- roof front edge, studs back from the front end
	roofRear: number, -- roof rear edge, studs forward of the back end
	rearGlassBase: number, -- where the rear glass meets the deck, studs forward of the back end
	deckTop: number, -- deck height at the back end
	ducktail: boolean, -- the deck rises toward the tail (a wedge) instead of being a flat lid
	roofThickness: number,
	roofDrop: number, -- roof top sits this far below the body height (room for roof rails)
	roofLook: Look,
	glassInset: number, -- the greenhouse is this much narrower than the body on each side
	rows: { number }, -- seat rows, studs back from the roof front edge
	spread2: number,
	spread3: number,
	bPillar: number?, -- B-pillar position, studs back from the roof front edge (nil: none)
}

-- What a sedan-family build leaves for a vehicle's own extras.
type Cabin = {
	frame: Frame,
	bodyBottom: number,
	belt: number,
	cowlZ: number,
	roofTop: number,
	roofBottom: number,
	roofFrontZ: number,
	roofRearZ: number,
	rearGlassZ: number,
	roofHalfWidth: number,
}

local function sedanFamily(ctx: Ctx, p: Profile): (Shape, Cabin)
	local g = ctx.g
	local f = frameOf(g)
	local hw, front, back = f.halfWidth, f.front, f.back
	local af0, af1, ar0, ar1 = f.frontArchFront, f.frontArchBack, f.rearArchFront, f.rearArchBack
	local bb, belt = p.bodyBottom, p.belt
	local hoodFront = math.max(p.hoodFront, f.archTop) -- the hood must clear the front tires
	local cowlZ = front + p.cowl
	local roofFrontZ = front + p.roofFront
	local roofRearZ = back - p.roofRear
	local rearGlassZ = back - p.rearGlassBase
	local roofTop = g.height - p.roofDrop
	local roofBottom = roofTop - p.roofThickness
	local glassHalf = hw - p.glassInset
	local roofHalf = glassHalf - DETAIL.roofInset
	local P = DETAIL.proud
	assert(cowlZ >= af1, `{ctx.model.Name}: the windshield must start behind the front wheel arch`)
	assert(
		cowlZ < roofFrontZ and roofFrontZ < roofRearZ and roofRearZ <= rearGlassZ,
		`{ctx.model.Name}: windshield, roof and rear glass must run front to back`
	)

	-- Lower body: panels around open wheel arches, with a dark well block between the wheels.
	box(ctx, "WheelWells", "dark", -f.wellHalfWidth, f.wellHalfWidth, bb + DETAIL.wellLift, f.archTop, af0, ar1)
	local inset = DETAIL.inset
	wedge(ctx, "Chin", "trim", "underFront", -hw + inset, hw - inset, bb, bb + p.chin, front + inset, af0)
	box(ctx, "Nose", "paint", -hw, hw, bb + p.chin, p.noseTop, front, af0)
	wedge(ctx, "NoseCap", "paint", "riseBack", -hw, hw, p.noseTop, hoodFront, front, af0)
	wedge(ctx, "Hood", "paint", "riseBack", -hw, hw, hoodFront, belt, af0, cowlZ)
	box(ctx, "SideMid", "paint", -hw, hw, bb, belt, af1, ar0)
	box(ctx, "FenderR", "paint", -hw, hw, f.archTop, belt, ar0, ar1)
	box(ctx, "Tail", "paint", -hw, hw, bb + p.chin, belt, ar1, back)
	local bumperTop = bb + DETAIL.bumperHeight
	box(ctx, "RearBumper", "trim", -hw - P, hw + P, bb, bumperTop, back - DETAIL.bumperDepth, back + P)

	-- Greenhouse: raked windshield, side glass, roof, rear glass and deck.
	wedge(ctx, "Windshield", "glass", "riseBack", -glassHalf, glassHalf, belt, roofBottom, cowlZ, roofFrontZ)
	box(ctx, "SideGlass", "glass", -glassHalf, glassHalf, belt, roofBottom, roofFrontZ, roofRearZ)
	local overhang = DETAIL.roofOverhang
	box(ctx, "Roof", p.roofLook, -roofHalf, roofHalf, roofBottom, roofTop, roofFrontZ - overhang, roofRearZ + overhang)
	wedge(ctx, "RearGlass", "glass", "riseFront", -glassHalf, glassHalf, belt, roofBottom, roofRearZ, rearGlassZ)
	if p.ducktail then
		wedge(ctx, "Deck", "paint", "riseBack", -hw, hw, belt, p.deckTop, rearGlassZ, back)
	else
		box(ctx, "Deck", "paint", -hw, hw, belt, p.deckTop, rearGlassZ, back)
	end
	if p.bPillar then
		local z = roofFrontZ + p.bPillar
		local half = DETAIL.pillarWidth / 2
		pairBox(ctx, "PillarB", "trim", glassHalf, glassHalf + P, belt, roofBottom, z - half, z + half)
	end
	local mirrorZ, mirrorY = cowlZ + DETAIL.mirrorBack, belt + DETAIL.mirrorLift
	local mirrorTop, mirrorBack = mirrorY + DETAIL.mirrorHeight, mirrorZ + DETAIL.mirrorDepth
	pairBox(ctx, "Mirror", "trim", hw, hw + DETAIL.mirrorReach, mirrorY, mirrorTop, mirrorZ, mirrorBack)

	-- Front: slim headlamps joined by a full-width running-light strip (the Ohm light signature), and a dark
	-- intake low in the nose.
	local lampTop = p.noseTop - 0.02
	local lampInner = hw - DETAIL.lampWidth
	pairLamp(ctx, "Head", "head", lampInner, hw - inset, lampTop - DETAIL.lampHeight, lampTop, front - P, front + P)
	local stripTop = lampTop - 0.03
	box(ctx, "RunningLight", "neon", -lampInner, lampInner, stripTop - DETAIL.stripHeight, stripTop, front - P, front)
	local intakeHalf = hw * DETAIL.intakeWidthRatio
	local intakeBottom = bb + p.chin + DETAIL.intakeLift
	local intakeTop = intakeBottom + DETAIL.intakeHeight
	box(ctx, "Intake", "trim", -intakeHalf, intakeHalf, intakeBottom, intakeTop, front - P, front + 0.02)

	-- Rear: tail lamps at the corners joined by a full-width brake strip; the reverse lamp sits over the bumper.
	local tailTop = belt - 0.1
	local tailBottom = tailTop - DETAIL.tailHeight
	local tailInner = hw - DETAIL.tailWidth
	pairLamp(ctx, "Tail", "tail", tailInner, hw - 0.08, tailBottom, tailTop, back - 0.02, back + P)
	local brakeTop = tailTop - 0.08
	lamp(ctx, "Brake", "brake", -tailInner, tailInner, brakeTop - DETAIL.brakeHeight, brakeTop, back - 0.02, back + P)
	local reverseBottom = bumperTop + DETAIL.reverseLift
	local reverseTop = reverseBottom + DETAIL.reverseHeight
	local reverseHalf = DETAIL.reverseHalfWidth
	lamp(ctx, "Reverse", "reverse", -reverseHalf, reverseHalf, reverseBottom, reverseTop, back - 0.02, back + P)

	local rows = {}
	for _, offset in p.rows do
		table.insert(rows, roofFrontZ + offset)
	end

	local function hoodAt(z: number): number
		return hoodFront + (belt - hoodFront) * (z - af0) / (cowlZ - af0)
	end
	local hoodCamZ = cowlZ - DETAIL.hoodCamBack
	local midHoodZ = (af0 + cowlZ) / 2
	local sideY = (bb + belt) / 2

	local shape: Shape = {
		seating = { y = roofBottom - SEATED_HEAD_ROOM, rows = rows, spread2 = p.spread2, spread3 = p.spread3 },
		points = {
			PlateFront = at(0, (intakeBottom + intakeTop) / 2, front - P, "forward"),
			PlateRear = at(0, (reverseTop + tailBottom) / 2, back + 0.02, "back"),
			CameraHood = at(0, hoodAt(hoodCamZ) + DETAIL.hoodCamHeight, hoodCamZ),
			Mount_Roof = at(0, roofTop, (roofFrontZ + roofRearZ) / 2),
			Mount_Hood = at(0, hoodAt(midHoodZ), midHoodZ),
			Mount_Spoiler = at(0, p.deckTop, back - DETAIL.spoilerInset),
			Mount_FrontBumper = at(0, bb + p.chin, front, "forward"),
			Mount_RearBumper = at(0, (bb + bumperTop) / 2, back + P, "back"),
			Mount_SideL = at(-hw, sideY, 0, "left"),
			Mount_SideR = at(hw, sideY, 0, "right"),
		},
	}
	local cabin: Cabin = {
		frame = f,
		bodyBottom = bb,
		belt = belt,
		cowlZ = cowlZ,
		roofTop = roofTop,
		roofBottom = roofBottom,
		roofFrontZ = roofFrontZ,
		roofRearZ = roofRearZ,
		rearGlassZ = rearGlassZ,
		roofHalfWidth = roofHalf,
	}
	return shape, cabin
end

-- Roof rails along both sides of the roof (crossover and SUV cue).
local function roofRails(ctx: Ctx, cabin: Cabin)
	local half = cabin.roofHalfWidth
	local z0 = cabin.roofFrontZ + DETAIL.railEndInset
	local z1 = cabin.roofRearZ - DETAIL.railEndInset
	pairBox(ctx, "Rail", "trim", half - DETAIL.railInner, half - DETAIL.railOuter, cabin.roofTop, ctx.g.height, z0, z1)
end

----------------------------------------------------------------------------------------------------------------
-- Silhouettes, one per Ohm vehicle. All original, generic shapes.
----------------------------------------------------------------------------------------------------------------

-- Ohm Spark: a sleek, low sedan with a long fastback rear glass ending in a small ducktail, and a glass roof.
local function spark(ctx: Ctx): Shape
	local shape = sedanFamily(ctx, {
		bodyBottom = 0.55,
		chin = 0.3,
		noseTop = 1.75,
		hoodFront = 2.5,
		belt = 2.8,
		cowl = 4.7,
		roofFront = 7.2,
		roofRear = 3.8,
		rearGlassBase = 1.4,
		deckTop = 3.05,
		ducktail = true,
		roofThickness = 0.3,
		roofDrop = 0,
		roofLook = "glass",
		glassInset = 0.35,
		rows = { 0.4, 2.8 },
		spread2 = 1.2,
		spread3 = 1.55,
		bPillar = 1.9,
	})
	return shape
end

-- Ohm Current: a taller crossover with an upright hatch, dark cladding and arch flares, and roof rails. The
-- long-body trim stretches everything from its own geometry and fills a third seat row.
local function current(ctx: Ctx): Shape
	local shape, cabin = sedanFamily(ctx, {
		bodyBottom = 0.8,
		chin = 0.3,
		noseTop = 2.15,
		hoodFront = 2.85,
		belt = 3.2,
		cowl = 4.8,
		roofFront = 6.8,
		roofRear = 1.5,
		rearGlassBase = 0.4,
		deckTop = 3.45,
		ducktail = false,
		roofThickness = 0.2,
		roofDrop = 0.15,
		roofLook = "glass",
		glassInset = 0.3,
		rows = { 0.7, 3.6, 6.3 },
		spread2 = 1.3,
		spread3 = 1.7,
		bPillar = 2.3,
	})
	local f = cabin.frame
	local hw, bb = f.halfWidth, cabin.bodyBottom
	local P = DETAIL.proud
	box(ctx, "Rocker", "trim", -hw - P, hw + P, bb, bb + 0.6, f.frontArchBack, f.rearArchFront)
	-- Arch flares: one per wheel, a little longer than the arch and standing out from the side.
	local flareBottom, flareTop = f.archTop - 0.05, f.archTop + 0.25
	local inner, outer, reach = hw - 0.25, hw + 0.06, 0.15
	local front0, front1 = f.frontArchFront - reach, f.frontArchBack + reach
	local rear0, rear1 = f.rearArchFront - reach, f.rearArchBack + reach
	pairBox(ctx, "FlareF", "trim", inner, outer, flareBottom, flareTop, front0, front1)
	pairBox(ctx, "FlareR", "trim", inner, outer, flareBottom, flareTop, rear0, rear1)
	roofRails(ctx, cabin)
	return shape
end

-- Ohm Grand: a long, low flagship sedan: long hood, a cabin set back, a sloping liftback into a flat trunk lid,
-- a painted roof and a trim line along the beltline.
local function grand(ctx: Ctx): Shape
	local shape, cabin = sedanFamily(ctx, {
		bodyBottom = 0.55,
		chin = 0.25,
		noseTop = 1.95,
		hoodFront = 2.7,
		belt = 2.95,
		cowl = 5.8,
		roofFront = 8.0,
		roofRear = 4.4,
		rearGlassBase = 1.8,
		deckTop = 3.15,
		ducktail = false,
		roofThickness = 0.25,
		roofDrop = 0,
		roofLook = "paint",
		glassInset = 0.4,
		rows = { 0.5, 3.1 },
		spread2 = 1.25,
		spread3 = 1.65,
		bPillar = 2.0,
	})
	local hw = cabin.frame.halfWidth
	local belt = cabin.belt
	pairBox(ctx, "BeltLine", "trim", hw, hw + DETAIL.proud, belt - 0.12, belt - 0.03, cabin.cowlZ, cabin.rearGlassZ)
	return shape
end

-- Ohm Summit: a tall SUV with a panoramic windshield that runs far back over the front seats, nearly vertical
-- sides, roof rails, three seat rows and two gull-wing doors over the middle row.
local function summit(ctx: Ctx): Shape
	local shape, cabin = sedanFamily(ctx, {
		bodyBottom = 0.8,
		chin = 0.3,
		noseTop = 2.3,
		hoodFront = 2.95,
		belt = 3.3,
		cowl = 4.85,
		roofFront = 7.95,
		roofRear = 1.55,
		rearGlassBase = 0.35,
		deckTop = 3.5,
		ducktail = false,
		roofThickness = 0.2,
		roofDrop = 0.15,
		roofLook = "glass",
		glassInset = 0.15,
		rows = { 0.3, 2.9, 5.3 },
		spread2 = 1.35,
		spread3 = 1.75,
		bPillar = nil,
	})
	roofRails(ctx, cabin)

	local hw = cabin.frame.halfWidth
	local P = DETAIL.proud
	-- Centered on the middle row, but never reaching over the rear wheel arch.
	local z1 = math.min(shape.seating.rows[2] + GULLWING.halfLength, cabin.frame.rearArchFront - GULLWING.archGap)
	local z0 = z1 - 2 * GULLWING.halfLength
	local doorZ = (z0 + z1) / 2
	local doorBottom = cabin.bodyBottom + GULLWING.sillLift
	for _, side in SIDES do
		local s = side.sign
		local door = newBlock(
			`GullWing{side.suffix}`,
			"paint",
			s * (hw + P - GULLWING.thickness),
			s * (hw + P),
			doorBottom,
			cabin.roofBottom,
			z0,
			z1
		)
		local window = newBlock(
			"Window",
			"glass",
			s * (hw + P - 0.01),
			s * (hw + 2 * P),
			cabin.belt + GULLWING.windowMargin,
			cabin.roofBottom - GULLWING.windowMargin,
			z0 + GULLWING.windowInset,
			z1 - GULLWING.windowInset
		)
		weld(door, window)
		window.Parent = door
		-- Positive angles about +Z swing a right-hand door up; the left door opens the other way.
		local hinge = Vector3.new(s * GULLWING.hingeFromCenter, cabin.roofTop, doorZ)
		hang(ctx, door, hinge, s * GULLWING.openAngle)
	end
	return shape
end

-- Ohm Mesa: an angular wedge pickup. One straight line runs from the nose up to a roof peak over the front
-- seats; another runs from the peak down to the tail along two sail panels that frame an open bed.
local function mesa(ctx: Ctx): Shape
	local g = ctx.g
	local f = frameOf(g)
	local hw, front, back = f.halfWidth, f.front, f.back
	local af0, af1, ar0, ar1 = f.frontArchFront, f.frontArchBack, f.rearArchFront, f.rearArchBack
	local P, inset = DETAIL.proud, DETAIL.inset
	local bb = 1.2 -- body bottom
	local chinTop = 1.6
	local deck = 3.6 -- top of the lower body; the bed floor sits here
	local apex = g.height -- roof peak, at z = 0
	local apexZ = 0
	local tailTop = 4.7 -- bed rail height at the tail
	local cowlZ = front + 5.8 -- windshield base
	local cabBack = 2.6 -- the cab's back wall; the open bed runs from here to the tail
	local wall = 0.35 -- bed wall and sail thickness
	local glassHalf = hw - 0.2

	local function rising(z: number): number
		return deck + (apex - deck) * (z - front) / (apexZ - front)
	end
	local function falling(z: number): number
		return apex + (tailTop - apex) * (z - apexZ) / (back - apexZ)
	end
	local belt = rising(cowlZ) -- hood top at the windshield base and the side-glass sill
	local sill = falling(cabBack) -- roof line at the cab's back wall

	box(ctx, "WheelWells", "dark", -f.wellHalfWidth, f.wellHalfWidth, bb + DETAIL.wellLift, f.archTop, af0, ar1)
	wedge(ctx, "Chin", "trim", "underFront", -hw + inset, hw - inset, bb, chinTop, front + inset, af0)
	box(ctx, "Nose", "paint", -hw, hw, chinTop, deck, front, af0)
	box(ctx, "FenderF", "paint", -hw, hw, f.archTop, deck, af0, af1)
	box(ctx, "SideMid", "paint", -hw, hw, bb, deck, af1, ar0)
	box(ctx, "FenderR", "paint", -hw, hw, f.archTop, deck, ar0, ar1)
	box(ctx, "Tail", "paint", -hw, hw, chinTop, deck, ar1, back)

	-- Cab: the hood and windshield follow the rising line; the roof cap follows the falling one.
	wedge(ctx, "Hood", "paint", "riseBack", -hw, hw, deck, belt, front, cowlZ)
	box(ctx, "Cab", "paint", -hw, hw, deck, belt, cowlZ, cabBack)
	wedge(ctx, "Windshield", "glass", "riseBack", -glassHalf, glassHalf, belt, apex, cowlZ, apexZ)
	box(ctx, "SideGlass", "glass", -glassHalf, glassHalf, belt, sill, apexZ, cabBack)
	wedge(ctx, "RoofCap", "paint", "riseFront", -glassHalf - 0.05, glassHalf + 0.05, sill, apex, apexZ, cabBack)

	-- Open bed between two sails that carry the roof line down to the tail.
	wedge(ctx, "SailL", "paint", "riseFront", -hw, -hw + wall, tailTop, sill, cabBack, back)
	wedge(ctx, "SailR", "paint", "riseFront", hw - wall, hw, tailTop, sill, cabBack, back)
	pairBox(ctx, "BedWall", "paint", hw - wall, hw, deck, tailTop, cabBack, back)
	box(ctx, "BedFloor", "trim", -hw + wall, hw - wall, deck - 0.1, deck + 0.05, cabBack, back - 0.25)
	box(ctx, "Tailgate", "paint", -hw + wall, hw - wall, deck, tailTop, back - 0.25, back)

	-- Off-road cues: chunky bumpers, a hitch receiver, dark rocker and angular arch flares.
	box(ctx, "FrontBumper", "trim", -hw + 0.05, hw - 0.05, 1.5, 2.4, front - 0.15, front + 0.4)
	box(ctx, "RearBumper", "trim", -hw + 0.05, hw - 0.05, 1.5, 2.3, back - 0.4, back + 0.2)
	box(ctx, "Hitch", "trim", -0.25, 0.25, 1.6, 1.9, back + 0.2, back + 0.75)
	box(ctx, "Rocker", "trim", -hw - 0.06, hw + 0.06, bb, bb + 0.7, af1, ar0)
	local flareBottom, flareTop = f.archTop - 0.04, f.archTop + 0.28
	box(ctx, "FlareF", "trim", -hw - 0.12, hw + 0.12, flareBottom, flareTop, af0 - 0.2, af1 + 0.2)
	box(ctx, "FlareR", "trim", -hw - 0.12, hw + 0.12, flareBottom, flareTop, ar0 - 0.2, ar1 + 0.2)
	pairBox(ctx, "Mirror", "trim", hw, hw + 0.4, belt - 0.3, belt + 0.05, cowlZ + 0.3, cowlZ + 0.7)

	-- Lamps: a full-width light bar across the nose with headlamps under its ends; vertical tail lamps on the
	-- bed walls and a brake strip across the tailgate.
	box(ctx, "LightBar", "neon", -hw + 0.4, hw - 0.4, deck - 0.18, deck - 0.08, front - P, front + 0.02)
	pairLamp(ctx, "Head", "head", hw - 0.85, hw - 0.05, deck - 0.5, deck - 0.22, front - P, front + 0.02)
	pairLamp(ctx, "Tail", "tail", hw - wall + 0.03, hw - 0.02, deck + 0.2, tailTop - 0.1, back - 0.02, back + P)
	local brakeHalf = hw - wall - 0.05
	lamp(ctx, "Brake", "brake", -brakeHalf, brakeHalf, tailTop - 0.22, tailTop - 0.1, back - 0.02, back + P)
	lamp(ctx, "Reverse", "reverse", -0.4, 0.4, 2.0, 2.2, back + 0.18, back + 0.24)

	local hoodCamZ = cowlZ - DETAIL.hoodCamBack
	return {
		seating = { y = sill - SEATED_HEAD_ROOM, rows = { -0.5, 1.9 }, spread2 = 1.4, spread3 = 1.85 },
		points = {
			PlateFront = at(0, 2.0, front - 0.15, "forward"),
			PlateRear = at(0, 2.95, back + 0.02, "back"),
			CameraHood = at(0, rising(hoodCamZ) + DETAIL.hoodCamHeight, hoodCamZ),
			Mount_Roof = at(0, falling(0.3), 0.3),
			Mount_Hood = at(0, rising(front + 3), front + 3),
			Mount_Spoiler = at(0, tailTop, back - 0.12),
			Mount_FrontBumper = at(0, 1.6, front - 0.15, "forward"),
			Mount_RearBumper = at(0, 2.1, back + 0.2, "back"),
			Mount_SideL = at(-hw, 2.6, 0, "left"),
			Mount_SideR = at(hw, 2.6, 0, "right"),
			TowHitch = at(0, 1.75, back + 0.7, "back"),
		},
	}
end

-- Ohm Hauler: a cab-over semi tractor. A tall flat-fronted cab sits over the front axle under a roof fairing;
-- behind it the frame carries side skirts, mudguards and a fifth-wheel plate (Kingpin) over the rear axle.
local function hauler(ctx: Ctx): Shape
	local g = ctx.g
	local f = frameOf(g)
	local hw, front, back = f.halfWidth, f.front, f.back
	local af0, af1, ar0, ar1 = f.frontArchFront, f.frontArchBack, f.rearArchFront, f.rearArchBack
	local P = DETAIL.proud
	local frameBottom = 1.9
	local cabBack = front + 8
	local cabTop = 10.4
	local glassBottom, glassTop = 7.2, 9.9
	local fairingFront, fairingBack = front + 0.6, cabBack - 0.4
	local kingpinZ = g.wheelbase / 2 - 0.6 -- just ahead of the rear axle
	local plateBottom = f.archTop + 0.45 -- fifth-wheel plate sits on a mount block on the frame
	local plateThickness = 0.35
	local plateTop = plateBottom + plateThickness

	box(ctx, "Frame", "dark", -f.wellHalfWidth, f.wellHalfWidth, frameBottom, f.archTop, af0, back - 0.1)
	box(ctx, "Bumper", "trim", -hw, hw, 1.8, f.archTop, front - 0.25, af0)
	box(ctx, "Cab", "paint", -hw, hw, f.archTop, cabTop, front, cabBack)
	box(ctx, "Windshield", "glass", -hw + 0.35, hw - 0.35, glassBottom, glassTop, front - 0.08, front + 0.05)
	box(ctx, "SideGlass", "glass", -hw - 0.05, hw + 0.05, glassBottom, glassTop, front + 0.4, front + 3.6)
	box(ctx, "Grille", "trim", -hw + 0.85, hw - 0.85, 4.5, 6.75, front - 0.07, front + 0.05)
	box(ctx, "LightBar", "neon", -hw + 0.35, hw - 0.35, 6.9, 7.05, front - 0.07, front + 0.03)
	wedge(ctx, "Fairing", "paint", "riseBack", -hw + 0.25, hw - 0.25, cabTop, g.height, fairingFront, fairingBack)
	box(ctx, "SideSkirts", "paint", -hw + 0.1, hw - 0.1, frameBottom, f.archTop, af1, ar0)
	box(ctx, "Fenders", "trim", -hw + 0.1, hw - 0.1, f.archTop + 0.04, f.archTop + 0.29, ar0 - 0.2, ar1 + 0.2)
	box(ctx, "FifthWheelBase", "trim", -1.8, 1.8, f.archTop, plateBottom, kingpinZ - 1.4, kingpinZ + 1.6)
	local plateCenter = Vector3.new(0, plateBottom + plateThickness / 2, kingpinZ)
	cylinder(ctx, "FifthWheel", "trim", "y", plateCenter, 4.2, plateThickness)
	pairBox(ctx, "Mudflap", "trim", f.wellHalfWidth + 0.05, hw - 0.1, 1.7, f.archTop - 0.06, ar1 + 0.25, ar1 + 0.4)
	box(ctx, "RearGuard", "trim", -hw + 0.15, hw - 0.15, 1.8, 3.7, back - 0.4, back)
	pairBox(ctx, "Mirror", "trim", hw + 0.05, hw + 0.7, 7.4, 9.4, front + 0.25, front + 0.65)

	pairLamp(ctx, "Head", "head", hw - 0.8, hw - 0.12, 4.6, 5.3, front - 0.09, front + P)
	pairLamp(ctx, "Tail", "tail", hw - 0.95, hw - 0.2, 3.0, 3.5, back - 0.02, back + P)
	lamp(ctx, "Brake", "brake", -hw + 1.05, hw - 1.05, 3.25, 3.45, back - 0.02, back + P)
	lamp(ctx, "Reverse", "reverse", -0.5, 0.5, 2.55, 2.8, back - 0.02, back + P)

	local function fairingAt(z: number): number
		return cabTop + (g.height - cabTop) * (z - fairingFront) / (fairingBack - fairingFront)
	end
	local roofZ = fairingBack - 1.5
	return {
		seating = { y = 6.0, rows = { front + 3 }, spread2 = 2.0, spread3 = 2.6 },
		points = {
			PlateFront = at(0, 2.6, front - 0.25, "forward"),
			PlateRear = at(0, 2.15, back, "back"),
			CameraHood = at(0, glassTop + 0.2, front - 0.15),
			Mount_Roof = at(0, fairingAt(roofZ), roofZ),
			Mount_Hood = at(0, cabTop, front + 0.3),
			Mount_Spoiler = at(0, g.height, fairingBack),
			Mount_FrontBumper = at(0, 2.9, front - 0.25, "forward"),
			Mount_RearBumper = at(0, 2.6, back, "back"),
			Mount_SideL = at(-hw, 6.0, front + 4, "left"),
			Mount_SideR = at(hw, 6.0, front + 4, "right"),
			Kingpin = at(0, plateTop, kingpinZ),
		},
	}
end

-- Ohm Pod: a short, rounded two-seat robotaxi. Wheels sit out at the corners, rounded rolls form the front and
-- rear edges, and a big glass canopy (two half-cylinders joined by a block) covers both seats. A roof sensor
-- marks it as autonomous. No driver seat.
local function pod(ctx: Ctx): Shape
	local g = ctx.g
	local f = frameOf(g)
	local hw, front, back = f.halfWidth, f.front, f.back
	local af0, af1, ar0, ar1 = f.frontArchFront, f.frontArchBack, f.rearArchFront, f.rearArchBack
	local P = DETAIL.proud
	local bb, belt = 0.6, 2.9
	local sensorHeight = 0.3
	local canopyRadius = g.height - belt - sensorHeight + 0.05 -- the sensor sits on the canopy crown
	local canopyHalf = 2.0 -- canopy half-width (inside the wheel wells)
	local canopyEnds = 1.0 -- the two rounded ends of the canopy are centered this far ahead of and behind center
	local roll = 1.1 -- diameter of the rounded front and rear top edges
	local crown = belt + canopyRadius

	box(ctx, "WheelWells", "dark", -f.wellHalfWidth, f.wellHalfWidth, bb + DETAIL.wellLift, f.archTop, af0, ar1)
	box(ctx, "SideMid", "paint", -hw, hw, bb, belt, af1, ar0)
	box(ctx, "FenderF", "paint", -hw, hw, f.archTop, belt, front, af1)
	box(ctx, "FenderR", "paint", -hw, hw, f.archTop, belt, ar0, back)
	box(ctx, "BumperF", "trim", -f.wellHalfWidth, f.wellHalfWidth, bb + 0.15, f.archTop, front - 0.08, af0 + 0.15)
	box(ctx, "BumperR", "trim", -f.wellHalfWidth, f.wellHalfWidth, bb + 0.15, f.archTop, ar1 - 0.15, back + 0.08)
	cylinder(ctx, "NoseRoll", "paint", "x", Vector3.new(0, belt, front + roll / 2), roll, 2 * hw)
	cylinder(ctx, "TailRoll", "paint", "x", Vector3.new(0, belt, back - roll / 2), roll, 2 * hw)
	cylinder(ctx, "CanopyFront", "glass", "x", Vector3.new(0, belt, -canopyEnds), 2 * canopyRadius, 2 * canopyHalf)
	box(ctx, "CanopyMid", "glass", -canopyHalf, canopyHalf, belt, crown, -canopyEnds, canopyEnds)
	cylinder(ctx, "CanopyRear", "glass", "x", Vector3.new(0, belt, canopyEnds), 2 * canopyRadius, 2 * canopyHalf)
	cylinder(ctx, "Sensor", "trim", "y", Vector3.new(0, crown - 0.05 + sensorHeight / 2, 0), 1.0, sensorHeight)
	pairBox(ctx, "Lidar", "trim", 2.35, 2.75, belt, belt + 0.3, front + 1.0, front + 1.4)
	box(ctx, "RunningLight", "neon", -1.9, 1.9, 2.5, 2.58, front - P, front + 0.02)

	pairLamp(ctx, "Head", "head", f.wellHalfWidth + 0.05, hw - 0.05, 2.35, 2.75, front - P, front + 0.02)
	pairLamp(ctx, "Tail", "tail", f.wellHalfWidth + 0.05, hw - 0.05, 2.35, 2.75, back - 0.02, back + P)
	lamp(ctx, "Brake", "brake", -1.9, 1.9, 2.45, 2.57, back - 0.02, back + P)
	lamp(ctx, "Reverse", "reverse", -0.4, 0.4, 1.3, 1.5, back + 0.06, back + 0.12)

	return {
		seating = { y = crown - SEATED_HEAD_ROOM, rows = { 0 }, spread2 = 1.1, spread3 = 1.4 },
		points = {
			PlateFront = at(0, 1.5, front - 0.08, "forward"),
			PlateRear = at(0, 1.85, back + 0.08, "back"),
			CameraHood = at(0, belt + 0.6, front + 1.6),
			Mount_Roof = at(0, crown, -canopyEnds),
			Mount_Hood = at(0, belt + roll / 2, front + roll / 2),
			Mount_Spoiler = at(0, belt + roll / 2, back - roll / 2),
			Mount_FrontBumper = at(0, 1.2, front - 0.08, "forward"),
			Mount_RearBumper = at(0, 1.2, back + 0.08, "back"),
			Mount_SideL = at(-hw, 1.8, 0, "left"),
			Mount_SideR = at(hw, 1.8, 0, "right"),
		},
	}
end

-- Ohm Arc: a very low, wide hypercar. A low nose between fender pods that carry the headlamps, an all-glass
-- cockpit canopy, rear haunches, a center-pylon wing, side intakes and two thruster nozzles in the tail.
local function arc(ctx: Ctx): Shape
	local g = ctx.g
	local f = frameOf(g)
	local hw, front, back = f.halfWidth, f.front, f.back
	local af0, af1, ar0, ar1 = f.frontArchFront, f.frontArchBack, f.rearArchFront, f.rearArchBack
	local P = DETAIL.proud
	local bb = 0.35
	local sill = 1.2 -- nose top, and the top of the floor between the wheels
	local belt = 2.3 -- cockpit sill
	local podTop = 2.95 -- fender pods and haunches over the wheels
	local podInner = g.track / 2 - g.wheelWidth / 2 -- pods start at the tires' inner faces
	local canopyFront, canopyBack = -2.6, 3.7 -- windshield base and back-glass base
	local roofFront, roofBack = -0.2, 1.1
	local glassHalf = 2.05
	local glassTop = g.height - 0.2
	local nozzleX, nozzleY = 2.8, 1.75
	local tailBottom = 0.75

	box(ctx, "WheelWells", "dark", -f.wellHalfWidth, f.wellHalfWidth, bb + DETAIL.wellLift, sill, af0, ar1)
	box(ctx, "Splitter", "trim", -hw + 0.1, hw - 0.1, bb, bb + 0.12, front - 0.2, af0)
	box(ctx, "Nose", "paint", -hw, hw, bb + 0.12, sill, front, af0)
	wedge(ctx, "Hood", "paint", "riseBack", -podInner, podInner, sill, belt, front, canopyFront)
	pairBox(ctx, "FenderF", "paint", podInner, hw, f.archTop, podTop, af0 - 0.25, af1 + 0.25)
	box(ctx, "SideMid", "paint", -hw, hw, bb, belt, af1, ar0)
	box(ctx, "Intake", "trim", -hw - 0.03, hw + 0.03, 0.9, 1.9, ar0 - 1.9, ar0 - 0.05)

	wedge(ctx, "Windshield", "glass", "riseBack", -glassHalf, glassHalf, belt, glassTop, canopyFront, roofFront)
	box(ctx, "CabinGlass", "glass", -glassHalf, glassHalf, belt, glassTop, roofFront, roofBack)
	local roofHalf, backHalf = glassHalf - 0.15, glassHalf - 0.05
	box(ctx, "Roof", "glass", -roofHalf, roofHalf, glassTop, g.height, roofFront - 0.15, roofBack + 0.05)
	wedge(ctx, "BackGlass", "glass", "riseFront", -backHalf, backHalf, belt, glassTop, roofBack, canopyBack)

	box(ctx, "RearDeck", "paint", -podInner, podInner, sill, belt + 0.05, ar0, back)
	box(ctx, "Tail", "paint", -hw, hw, tailBottom, f.archTop, ar1, back)
	wedge(ctx, "Diffuser", "trim", "underBack", -hw + 0.3, hw - 0.3, bb, tailBottom, ar1, back + 0.15)
	pairBox(ctx, "Haunch", "paint", podInner, hw, f.archTop, podTop, ar0 - 0.25, back)
	box(ctx, "Wing", "trim", -hw + 0.3, hw - 0.3, 3.0, 3.15, back - 1.05, back + 0.05)
	box(ctx, "Pylon", "trim", -0.15, 0.15, belt + 0.05, 3.0, back - 0.75, back - 0.3)
	for _, side in SIDES do
		local center = Vector3.new(side.sign * nozzleX, nozzleY, back + 0.05)
		cylinder(ctx, `Nozzle{side.suffix}`, "trim", "z", center, 0.8, 0.4)
	end
	box(ctx, "RunningLight", "neon", -2.2, 2.2, sill - 0.1, sill - 0.02, front - P, front + 0.02)
	box(ctx, "FrontIntake", "trim", -1.8, 1.8, 0.55, 0.95, front - P, front + 0.02)
	local mirrorZ = canopyFront + 0.3
	pairBox(ctx, "Mirror", "trim", podInner, podInner + 0.45, belt + 0.15, belt + 0.35, mirrorZ, mirrorZ + 0.35)

	-- Headlamps sit on the front faces of the fender pods.
	local podFront = af0 - 0.25
	local headBottom, headTop = f.archTop + 0.06, podTop - 0.1
	pairLamp(ctx, "Head", "head", podInner + 0.1, hw - 0.1, headBottom, headTop, podFront - P, podFront + 0.03)
	pairLamp(ctx, "Tail", "tail", podInner + 0.05, hw - 0.02, f.archTop + 0.09, podTop - 0.07, back - 0.02, back + P)
	lamp(ctx, "Brake", "brake", -podInner + 0.1, podInner - 0.1, belt - 0.15, belt, back - 0.02, back + P)
	lamp(ctx, "Reverse", "reverse", -0.35, 0.35, 1.3, 1.5, back - 0.02, back + P)

	local function hoodAt(z: number): number
		return sill + (belt - sill) * (z - front) / (canopyFront - front)
	end
	local hoodCamZ = canopyFront - 0.5
	local thrusterZ = back + 0.25
	return {
		seating = { y = 0.45, rows = { 0.25 }, spread2 = 0.95, spread3 = 1.3 },
		points = {
			PlateFront = at(0, 0.75, front - P, "forward"),
			PlateRear = at(0, 1.05, back + P, "back"),
			CameraHood = at(0, hoodAt(hoodCamZ) + 0.3, hoodCamZ),
			Mount_Roof = at(0, g.height, (roofFront + roofBack) / 2),
			Mount_Hood = at(0, hoodAt(front + 2.25), front + 2.25),
			Mount_Spoiler = at(0, 3.15, back - 0.5),
			Mount_FrontBumper = at(0, bb + 0.12, front - 0.2, "forward"),
			Mount_RearBumper = at(0, 0.6, back + 0.15, "back"),
			Mount_SideL = at(-hw, 1.4, -0.5, "left"),
			Mount_SideR = at(hw, 1.4, -0.5, "right"),
			Thruster_L = at(-nozzleX, nozzleY, thrusterZ, "back"),
			Thruster_R = at(nozzleX, nozzleY, thrusterZ, "back"),
			Thruster_Down = at(0, bb, 0.5, "down"),
		},
	}
end

-- Bespoke silhouettes by vehicle id (the Ohm lineup). Every other vehicle gets the generic body for its
-- bodyStyle (STYLE_BUILDERS, below).
local SHAPES: { [string]: (Ctx) -> Shape } = {
	ohm_spark = spark,
	ohm_current = current,
	ohm_mesa = mesa,
	ohm_hauler = hauler,
	ohm_pod = pod,
	ohm_arc = arc,
	ohm_grand = grand,
	ohm_summit = summit,
}

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

local function addFront(ctx: Ctx, look: BrandLook, i: FrontInfo): FrontResult
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

local function addRear(ctx: Ctx, look: BrandLook, r: RearInfo): RearResult
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
	local hoodFront = hoodFrontAt(f, belt, style.hoodRise)
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
	if not isClassic(ctx) then
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
	if not isClassic(ctx) then
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
	local hoodFront = hoodFrontAt(f, belt, WORK.hoodRise)
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
	local hoodFront = hoodFrontAt(f, belt, VAN.hoodRise)
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

-- The body builder for a vehicle: its bespoke silhouette, or the generic body for its bodyStyle. `generic`
-- skips the bespoke silhouette (specs use it to build every style). nil when there is neither.
local function shapeFor(vehicleId: string, vehicle: Vehicles.Vehicle, generic: boolean): ((Ctx) -> Shape)?
	local bespoke = SHAPES[vehicleId]
	if bespoke and not generic then
		return bespoke
	end
	local builder = STYLE_BUILDERS[vehicle.bodyStyle]
	if builder == nil then
		return nil
	end
	return function(ctx: Ctx): Shape
		return withFeatureDefaults(ctx, builder(ctx))
	end
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

-- Lists every way `model` breaks the vehicle model contract. An empty list means it follows it. Works on any
-- model (greybox or artist-made) whose VehicleId and Trim attributes name a catalog trim.
function VehicleBuilder.check(model: Model): { string }
	local problems: { string } = {}
	local function problem(message: string)
		table.insert(problems, `{model.Name}: {message}`)
	end

	local vehicleId, trimId = model:GetAttribute("VehicleId"), model:GetAttribute("Trim")
	if type(vehicleId) ~= "string" or type(trimId) ~= "string" then
		problem("missing VehicleId or Trim attribute")
		return problems
	end
	local vehicle = Catalog.getVehicle(vehicleId)
	local trim = Catalog.getTrim(vehicleId, trimId)
	local g = Catalog.geometry(vehicleId, trimId)
	if vehicle == nil or trim == nil or g == nil then
		problem(`{vehicleId}/{trimId} is not in the catalog`)
		return problems
	end
	if model.Name ~= Catalog.modelName(vehicleId, trimId) then
		problem(`must be named {Catalog.modelName(vehicleId, trimId)}`)
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
-- Building
----------------------------------------------------------------------------------------------------------------

local function requireStudio()
	if not RunService:IsStudio() then
		error("VehicleBuilder is a Studio-only tool", 3)
	end
end

local function requireEditMode()
	requireStudio()
	if RunService:IsRunning() then
		error("VehicleBuilder runs in Edit mode only; stop the playtest first", 3)
	end
end

local function newFolder(name: string, parent: Instance): Folder
	local folder = Instance.new("Folder")
	folder.Name = name
	folder.Parent = parent
	return folder
end

-- Builds a trim's model and checks it against the contract, without parenting it anywhere. Errors if the
-- vehicle has no shape or the result breaks the contract. `generic` builds the bodyStyle's generic body even
-- for a vehicle with a bespoke silhouette.
local function assembleModel(vehicleId: string, trimId: string, generic: boolean): Model
	requireStudio()
	local vehicle = Catalog.getVehicle(vehicleId)
	local trim = Catalog.getTrim(vehicleId, trimId)
	local g = Catalog.geometry(vehicleId, trimId)
	if vehicle == nil or trim == nil or g == nil then
		error(`unknown vehicle or trim: {vehicleId}/{trimId}`, 3)
	end
	local shapeOf = shapeFor(vehicleId, vehicle, generic)
	if shapeOf == nil then
		error(`no greybox shape for {vehicleId}: unknown bodyStyle "{vehicle.bodyStyle}"`, 3)
	end

	local name = Catalog.modelName(vehicleId, trimId)
	local model = Instance.new("Model")
	model.Name = name
	model.ModelStreamingMode = Enum.ModelStreamingMode.Atomic
	model:SetAttribute("BrandId", vehicle.brandId)
	model:SetAttribute("VehicleId", vehicleId)
	model:SetAttribute("Trim", trimId)
	model:SetAttribute(GREYBOX_ATTRIBUTE, true)

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
	tintPaint(model, vehicle.brandId)

	local problems = VehicleBuilder.check(model)
	if #problems > 0 then
		model:Destroy()
		error(`{name} breaks the vehicle model contract:\n  {table.concat(problems, "\n  ")}`, 3)
	end
	return model
end

-- Builds a trim's model (its bespoke silhouette, or the generic body for its bodyStyle) and checks it against
-- the contract, without parenting it anywhere.
function VehicleBuilder.assemble(vehicleId: string, trimId: string): Model
	return assembleModel(vehicleId, trimId, false)
end

-- Like assemble, but always builds the generic body for the vehicle's bodyStyle, even for an Ohm vehicle with
-- a bespoke silhouette. Specs use it so every bodyStyle is built and checked.
function VehicleBuilder.assembleGeneric(vehicleId: string, trimId: string): Model
	return assembleModel(vehicleId, trimId, true)
end

-- Every bodyStyle with a generic body, sorted.
function VehicleBuilder.bodyStyles(): { string }
	local styles = {}
	for style in STYLE_BUILDERS do
		table.insert(styles, style)
	end
	table.sort(styles)
	return styles
end

export type BuildOptions = {
	replaceArt: boolean?, -- also replace a model that was not built here (artist-made)
}

local function modelsFolder(): Folder
	local existing = ServerStorage:FindFirstChild(MODELS_FOLDER)
	if existing then
		if existing:IsA("Folder") then
			return existing
		end
		error(`ServerStorage.{MODELS_FOLDER} must be a Folder`, 0)
	end
	return newFolder(MODELS_FOLDER, ServerStorage)
end

-- Rebuilds one trim's model in ServerStorage.VehicleModels and returns it. The old model is replaced only
-- after the new one passes the contract check, so a failed build leaves the old one in place.
function VehicleBuilder.build(vehicleId: string, trimId: string, options: BuildOptions?): Model
	requireEditMode()
	local folder = modelsFolder()
	local name = Catalog.modelName(vehicleId, trimId)
	local existing = folder:FindFirstChild(name)
	local replaceArt = options ~= nil and options.replaceArt == true
	if existing and existing:GetAttribute(GREYBOX_ATTRIBUTE) ~= true and not replaceArt then
		error(`{name} is not a greybox model (artist-made?); pass \{ replaceArt = true } to overwrite it`, 2)
	end
	local model = VehicleBuilder.assemble(vehicleId, trimId)
	if existing then
		existing:Destroy()
	end
	model.Parent = folder
	return model
end

-- Rebuilds every trim of every catalog vehicle and removes greybox models whose trim no longer exists.
-- Artist-made models and vehicles without a shape are skipped with a warning. Returns the names built.
function VehicleBuilder.buildAll(): { string }
	requireEditMode()
	local folder = modelsFolder()
	local wanted: { [string]: boolean } = {}
	local built: { string } = {}

	for _, vehicleId in Catalog.vehicleIds() do
		local vehicle = Catalog.getVehicle(vehicleId)
		if vehicle == nil then
			continue
		end
		for _, trim in vehicle.trims do
			local name = Catalog.modelName(vehicleId, trim.id)
			wanted[name] = true
			local existing = folder:FindFirstChild(name)
			if existing and existing:GetAttribute(GREYBOX_ATTRIBUTE) ~= true then
				warn(`[VehicleBuilder] kept {name}: it is not a greybox model`)
			elseif shapeFor(vehicleId, vehicle, false) == nil then
				warn(`[VehicleBuilder] skipped {name}: no greybox shape for {vehicleId} ({vehicle.bodyStyle})`)
			else
				VehicleBuilder.build(vehicleId, trim.id)
				table.insert(built, name)
			end
		end
	end

	for _, child in folder:GetChildren() do
		if not wanted[child.Name] and child:GetAttribute(GREYBOX_ATTRIBUTE) == true then
			child:Destroy()
		end
	end

	print(`[VehicleBuilder] built {#built} models in ServerStorage.{MODELS_FOLDER}`)
	return built
end

return VehicleBuilder
