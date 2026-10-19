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
--   check(model): {string}              lists every way a model breaks the contract (empty = good)
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

-- Attachments every model has, plus the ones a vehicle feature adds (model contract).
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

-- One silhouette per vehicle id. A new catalog vehicle needs an entry here before it can be built.
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
-- vehicle has no shape or the result breaks the contract.
function VehicleBuilder.assemble(vehicleId: string, trimId: string): Model
	requireStudio()
	local vehicle = Catalog.getVehicle(vehicleId)
	local trim = Catalog.getTrim(vehicleId, trimId)
	local g = Catalog.geometry(vehicleId, trimId)
	if vehicle == nil or trim == nil or g == nil then
		error(`unknown vehicle or trim: {vehicleId}/{trimId}`, 2)
	end
	local shapeOf = SHAPES[vehicleId]
	if shapeOf == nil then
		error(`no greybox shape for {vehicleId}; add one to SHAPES in VehicleBuilder`, 2)
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
		addWheels(ctx)
		addSeats(ctx, shape.seating)
		addPoints(ctx, shape.points)
	end)
	if not ok then
		model:Destroy()
		error(err, 0)
	end

	local problems = VehicleBuilder.check(model)
	if #problems > 0 then
		model:Destroy()
		error(`{name} breaks the vehicle model contract:\n  {table.concat(problems, "\n  ")}`, 2)
	end
	return model
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
			elseif SHAPES[vehicleId] == nil then
				warn(`[VehicleBuilder] skipped {name}: no greybox shape for {vehicleId}`)
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
