--!strict
-- Greybox trailer builder (PLAN.md Phase 8, docs/phase-8-contracts.md "Trailers and towed cars"). Builds one
-- original, untextured model per Config/Trailers spec into ServerStorage.TrailerModels: box_trailer,
-- flatbed_trailer and tanker_trailer, sized for the Ohm Hauler (Config/Trailers.referenceTractor).
--
-- Edit-mode tool only (CLAUDE.md hard rule 9). Run it from the Studio command bar or MCP execute_luau (Edit
-- datamodel):
--   require(game.ServerScriptService.Server.Dev.TrailerBuilder).buildAll()
--
-- API
--   buildAll(): {string}          rebuilds every trailer; returns the names built
--   build(trailerId, options?)    rebuilds one trailer and returns it
--   assemble(trailerId)           builds a trailer without parenting it anywhere (for specs)
--   check(model): {string}        lists every way a model breaks the trailer contract (empty = good)
--
-- The trailer model contract (Vehicle/Trailer and Services/HitchService rely on it):
--   * Model named after its id, PrimaryPart = Chassis, ModelStreamingMode = Atomic, attributes TrailerId and
--     Greybox, CollectionService tag Config/Trailers.tag. Pivot = the ground point under the middle of the
--     body, facing forward (-Z): model:PivotTo(groundCFrame) parks it level on its wheels and landing legs.
--   * Chassis: invisible Part, CanCollide, the only physics body, CustomPhysicalProperties with a density that
--     makes its mass Config/Trailers massRatio x the reference tractor's chassis mass. Anchored (stored parked;
--     HitchService unanchors it when coupling). It is the deck and load behind Config/Trailers.chassisGap past
--     the kingpin, so a coupled tractor's chassis box swings under the front overhang without touching it.
--   * Kingpin attachment on the Chassis at the kingpin (Config/Trailers.kingpinSetback behind the front edge,
--     kingpinHeight above the ground at rest), oriented like the Chassis, like the Hauler's own Kingpin.
--   * Wheels folder: the spec's ground wheels (A1L, A1R, A2L, A2R), cylinders with the axle along X, each with a
--     Motor6D "Motor" (Part0 = Chassis, Part1 = wheel, C0 = the hub, C1 = identity) and a matching hub
--     attachment Wheel<id> on the Chassis at ride height. Animated only through Motor.Transform.
--   * LandingGear folder: legs on Motor6Ds named Config/Trailers.landingGearMotor (Part0 = Chassis), feet on the
--     ground at rest; Vehicle/Trailer cranks them up while the trailer is coupled.
--   * Body folder (visual parts), Lights folder: TailL, TailR, Brake, Reverse, each holding a disabled SpotLight
--     named Light (DriveController's lamp switching works on them).
--   * Every part but the Chassis is Massless, unanchored, CanCollide/CanTouch/CanQuery off, and welded to the
--     Chassis or to the wheel or leg it is parented to. At most Config/Perf parts.model parts.
--
-- Building is idempotent: a rebuild replaces the old model and produces the same instances every time. A model
-- without the Greybox attribute (artist-made) is never overwritten unless build() gets { replaceArt = true }.
-- Every model is checked before it is stored, so a broken one fails the build instead of reaching the game.
--
-- Shapes are authored in "ground space": the origin is the ground point under the middle of the body, +X is
-- right, +Y is up and the front is -Z. The numbers inside the shape functions are the greybox art itself (panel
-- positions in studs), not gameplay tunables; everything physics depends on comes from Config/Trailers.

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")

local Catalog = require(ReplicatedStorage.Shared.Vehicle.Catalog)
local Driving = require(ReplicatedStorage.Shared.Config.Driving)
local Trailers = require(ReplicatedStorage.Shared.Config.Trailers)

local GREYBOX_ATTRIBUTE = "Greybox" -- marks models this builder owns; artist models never carry it
local MAX_PARTS = require(ReplicatedStorage.Shared.Config.Perf).parts.model -- the part budget per model (Config/Perf)
local TOLERANCE = 1e-3

-- Chassis surface, like a car's (Dev/VehicleBuilder).
local CHASSIS_FRICTION = 0.3
local CHASSIS_ELASTICITY = 0

-- Wheels: a tire carrying a lighter rim disc and one dark spoke bar (so spin is visible), welded to the tire.
local RIM_RATIO = 0.6 -- rim diameter / tire diameter
local SPOKE_RATIO = 0.55 -- spoke length / tire diameter
local SPOKE_THICKNESS_RATIO = 0.18 -- spoke thickness / tire radius
local HUB_PROUD = 0.03 -- rim and spoke stand this far out of each tire face

-- Underframe and running gear shared by every style, in studs.
local FLOOR_THICKNESS = 0.45 -- the floor slab on top of the kingpin plane; bodies start on top of it
local FRAME = {
	halfWidth = 2.2, -- the dark frame rails under the floor
	depth = 0.5,
	behindKingpin = 3.5, -- they start this far behind the kingpin (clear of the tractor's fifth wheel)
	sillDepth = 0.4, -- the rear sill (lamps) is this deep, front to back
}
local GEAR = {
	sideX = 3.0, -- legs stand this far either side of the centerline
	outer = 0.5, -- outer tube width
	inner = 0.36, -- inner leg width
	outerBottom = 1.9, -- the outer tubes end this high above the ground
	innerTop = 2.3, -- the inner legs reach up inside the tubes to here (at rest)
	pad = 1.0, -- foot pad width
	padHeight = 0.25,
	mountDepth = 0.7, -- the cross beam the legs hang from
}
local MUDFLAP_GAP = 0.4 -- behind the rear tires
local MARKER = { length = 0.3, height = 0.2, lift = 0.12, inset = 1.2 } -- amber side markers on the floor edge

local SMOOTH = Enum.Material.SmoothPlastic

type Look =
	"body"
	| "accent"
	| "trim"
	| "dark"
	| "steel"
	| "deck"
	| "crate"
	| "strap"
	| "placard"
	| "tire"
	| "rim"
	| "spoke"
	| "marker"
	| "tailLamp"
	| "brakeLamp"
	| "reverseLamp"

type LookStyle = { color: Color3, material: Enum.Material, transparency: number }

local LOOKS: { [Look]: LookStyle } = {
	body = { color = Color3.fromRGB(226, 228, 224), material = SMOOTH, transparency = 0 }, -- van walls and doors
	accent = { color = Color3.fromRGB(34, 108, 118), material = SMOOTH, transparency = 0 }, -- the van's stripe
	trim = { color = Color3.fromRGB(58, 62, 68), material = SMOOTH, transparency = 0 },
	dark = { color = Color3.fromRGB(20, 20, 22), material = SMOOTH, transparency = 0 }, -- frame, mudflaps
	steel = { color = Color3.fromRGB(184, 188, 194), material = Enum.Material.Metal, transparency = 0 }, -- tank
	deck = { color = Color3.fromRGB(112, 84, 58), material = Enum.Material.WoodPlanks, transparency = 0 },
	crate = { color = Color3.fromRGB(168, 132, 86), material = Enum.Material.Wood, transparency = 0 },
	strap = { color = Color3.fromRGB(214, 164, 40), material = Enum.Material.Fabric, transparency = 0 },
	placard = { color = Color3.fromRGB(232, 122, 34), material = SMOOTH, transparency = 0 },
	tire = { color = Color3.fromRGB(28, 28, 30), material = SMOOTH, transparency = 0 },
	rim = { color = Color3.fromRGB(160, 164, 170), material = SMOOTH, transparency = 0 },
	spoke = { color = Color3.fromRGB(64, 66, 72), material = SMOOTH, transparency = 0 },
	marker = { color = Color3.fromRGB(255, 164, 40), material = Enum.Material.Neon, transparency = 0 },
	tailLamp = { color = Color3.fromRGB(112, 14, 18), material = SMOOTH, transparency = 0 },
	brakeLamp = { color = Color3.fromRGB(140, 16, 22), material = SMOOTH, transparency = 0 },
	reverseLamp = { color = Color3.fromRGB(214, 216, 220), material = SMOOTH, transparency = 0 },
}

type LampKind = "tail" | "brake" | "reverse"
type LampStyle = { look: Look, color: Color3, brightness: number, range: number, angle: number }

-- Every lamp holds a SpotLight named Light facing back, off until DriveController lights it.
local LAMPS: { [LampKind]: LampStyle } = {
	tail = { look = "tailLamp", color = Color3.fromRGB(255, 36, 36), brightness = 1, range = 8, angle = 120 },
	brake = { look = "brakeLamp", color = Color3.fromRGB(255, 30, 30), brightness = 3, range = 12, angle = 120 },
	reverse = { look = "reverseLamp", color = Color3.fromRGB(245, 245, 255), brightness = 2, range = 16, angle = 90 },
}
local LIGHT_NAMES = { "TailL", "TailR", "Brake", "Reverse" }

-- Cylinders run along their local X axis; these turn them to run along Y or Z instead.
type Axis = "x" | "y" | "z"
local AXES: { [Axis]: CFrame } = {
	x = CFrame.identity,
	y = CFrame.Angles(0, 0, math.pi / 2),
	z = CFrame.Angles(0, math.pi / 2, 0),
}

local SIDES = { { sign = -1, suffix = "L" }, { sign = 1, suffix = "R" } }

-- Where everything physics depends on sits, in ground space, from a spec and Config/Trailers.
type Layout = {
	front: number, -- z of the front edge
	back: number, -- z of the back edge
	halfWidth: number,
	deck: number, -- the kingpin plane: the floor's underside
	kingpinZ: number,
	chassisCenter: Vector3,
	chassisSize: Vector3,
	hubs: { [string]: Vector3 }, -- wheel id -> hub center at rest
	axleZ: { [string]: number }, -- axle id -> z
	legZ: number,
}

type Ctx = {
	spec: Trailers.TrailerSpec,
	layout: Layout,
	model: Model,
	chassis: Part,
	body: Folder,
	wheels: Folder,
	lights: Folder,
	gear: Folder,
}

local TrailerBuilder = {}

----------------------------------------------------------------------------------------------------------------
-- Layout
----------------------------------------------------------------------------------------------------------------

local function layoutOf(spec: Trailers.TrailerSpec): Layout
	local front, back = -spec.length / 2, spec.length / 2
	local deck = Trailers.kingpinHeight
	local kingpinZ = front + Trailers.kingpinSetback
	local chassisFront = kingpinZ + Trailers.chassisGap
	local chassisSize = Vector3.new(spec.width, spec.chassisHeight, back - chassisFront)
	local hubs: { [string]: Vector3 } = {}
	local axleZ: { [string]: number } = {}
	for _, axle in spec.axles do
		local z = back - axle.fromBack
		axleZ[axle.id] = z
		for _, side in SIDES do
			hubs[axle.id .. side.suffix] = Vector3.new(side.sign * spec.track / 2, spec.wheelRadius, z)
		end
	end
	return {
		front = front,
		back = back,
		halfWidth = spec.width / 2,
		deck = deck,
		kingpinZ = kingpinZ,
		chassisCenter = Vector3.new(0, deck + spec.chassisHeight / 2, (chassisFront + back) / 2),
		chassisSize = chassisSize,
		hubs = hubs,
		axleZ = axleZ,
		legZ = kingpinZ + Trailers.landingGear.behindKingpin,
	}
end

-- The Chassis density that gives the trailer massRatio x the reference tractor's chassis mass.
local function densityOf(spec: Trailers.TrailerSpec, layout: Layout): number
	local reference = Trailers.referenceTractor
	local g = Catalog.geometry(reference.vehicleId, reference.trimId)
	if g == nil then
		error(`Config/Trailers.referenceTractor {reference.vehicleId}/{reference.trimId} is not in the catalog`, 0)
	end
	local tractorMass = Driving.chassisDensity * g.width * g.chassisHeight * g.length
	local size = layout.chassisSize
	return spec.massRatio * tractorMass / (size.X * size.Y * size.Z)
end

-- Ground space to chassis space.
local function toChassis(layout: Layout, point: Vector3): CFrame
	return CFrame.new(point - layout.chassisCenter)
end

----------------------------------------------------------------------------------------------------------------
-- Part helpers
----------------------------------------------------------------------------------------------------------------

-- Applies a look plus the contract's rules for visual parts: massless, unanchored, and invisible to collisions,
-- touches and raycasts. Only the Chassis is a physics body.
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
	part.CastShadow = true
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
end

local function weld(anchor: BasePart, part: BasePart)
	local joint = Instance.new("WeldConstraint")
	joint.Part0 = anchor
	joint.Part1 = part
	joint.Parent = part
end

-- A dressed block filling a ground-space box given by its extents on each axis (in either order).
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
	part.Name = name
	part.Size = Vector3.new(math.abs(x1 - x0), math.abs(y1 - y0), math.abs(z1 - z0))
	part.CFrame = CFrame.new((x0 + x1) / 2, (y0 + y1) / 2, (z0 + z1) / 2)
	dress(part, look)
	return part
end

-- A body block welded to `anchor` (the Chassis unless given) and parented to `parent` (Body unless given).
local function box(
	ctx: Ctx,
	name: string,
	look: Look,
	x0: number,
	x1: number,
	y0: number,
	y1: number,
	z0: number,
	z1: number,
	anchor: BasePart?,
	parent: Instance?
): Part
	local part = newBlock(name, look, x0, x1, y0, y1, z0, z1)
	weld(anchor or ctx.chassis, part)
	part.Parent = parent or ctx.body
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

-- A lamp in the Lights folder (on the rear face), holding a disabled SpotLight named Light.
local function lamp(ctx: Ctx, name: string, kind: LampKind, x0: number, x1: number, y0: number, y1: number)
	local style = LAMPS[kind]
	local back = ctx.layout.back
	local part = box(ctx, name, style.look, x0, x1, y0, y1, back - 0.02, back + 0.04, nil, ctx.lights)
	local light = Instance.new("SpotLight")
	light.Name = "Light"
	light.Enabled = false
	light.Color = style.color
	light.Brightness = style.brightness
	light.Range = style.range
	light.Angle = style.angle
	light.Face = Enum.NormalId.Back
	light.Shadows = false
	light.Parent = part
end

----------------------------------------------------------------------------------------------------------------
-- Running gear (every style)
----------------------------------------------------------------------------------------------------------------

local function addWheels(ctx: Ctx)
	local spec, layout = ctx.spec, ctx.layout
	local diameter = 2 * spec.wheelRadius
	for _, id in spec.groundWheels do
		local hubGround: Vector3? = layout.hubs[id]
		if hubGround == nil then
			error(`{spec.id}: ground wheel {id} is not on any of the spec's axles`, 0)
		end
		local hub = toChassis(layout, hubGround)
		local attachment = Instance.new("Attachment")
		attachment.Name = "Wheel" .. id
		attachment.CFrame = hub
		attachment.Parent = ctx.chassis

		local wheel = Instance.new("Part")
		wheel.Name = id
		wheel.Shape = Enum.PartType.Cylinder
		wheel.Size = Vector3.new(spec.wheelWidth, diameter, diameter)
		wheel.CFrame = CFrame.new(hubGround)
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
		rim.Size = Vector3.new(spec.wheelWidth + 2 * HUB_PROUD, diameter * RIM_RATIO, diameter * RIM_RATIO)
		rim.CFrame = wheel.CFrame
		dress(rim, "rim")
		weld(wheel, rim)
		rim.Parent = wheel

		local spoke = Instance.new("Part")
		spoke.Name = "Spoke"
		spoke.Size = Vector3.new(
			spec.wheelWidth + 4 * HUB_PROUD,
			diameter * SPOKE_RATIO,
			spec.wheelRadius * SPOKE_THICKNESS_RATIO
		)
		spoke.CFrame = wheel.CFrame
		dress(spoke, "spoke")
		weld(wheel, spoke)
		spoke.Parent = wheel

		wheel.Parent = ctx.wheels
	end
end

-- Two landing legs: fixed outer tubes hanging from a cross beam, and inner legs with foot pads on Motor6Ds, so
-- Vehicle/Trailer can crank them up into the tubes while the trailer is coupled.
local function addLandingGear(ctx: Ctx)
	local layout = ctx.layout
	local deck, z = layout.deck, layout.legZ
	local beamBottom = deck - GEAR.mountDepth
	box(
		ctx,
		"GearMount",
		"dark",
		-GEAR.sideX - GEAR.outer,
		GEAR.sideX + GEAR.outer,
		beamBottom,
		deck - 0.05,
		z - 0.35,
		z + 0.35
	)
	local outerHalf, innerHalf, padHalf = GEAR.outer / 2, GEAR.inner / 2, GEAR.pad / 2
	for _, side in SIDES do
		local x = side.sign * GEAR.sideX
		box(
			ctx,
			`Tube{side.suffix}`,
			"trim",
			x - outerHalf,
			x + outerHalf,
			GEAR.outerBottom,
			beamBottom,
			z - outerHalf,
			z + outerHalf
		)

		local leg = newBlock(
			`Leg{side.suffix}`,
			"trim",
			x - innerHalf,
			x + innerHalf,
			GEAR.padHeight,
			GEAR.innerTop,
			z - innerHalf,
			z + innerHalf
		)
		local motor = Instance.new("Motor6D")
		motor.Name = Trailers.landingGearMotor
		motor.Part0 = ctx.chassis
		motor.Part1 = leg
		motor.C0 = ctx.chassis.CFrame:ToObjectSpace(leg.CFrame)
		motor.C1 = CFrame.identity
		motor.Parent = leg
		leg.Parent = ctx.gear
		box(ctx, "Pad", "dark", x - padHalf, x + padHalf, 0, GEAR.padHeight, z - padHalf, z + padHalf, leg, leg)
	end
	-- The crank handle on the right tube.
	local crankX = GEAR.sideX + GEAR.outer / 2
	box(ctx, "Crank", "dark", crankX, crankX + 0.5, beamBottom - 0.5, beamBottom - 0.35, z - 0.08, z + 0.08)
end

-- Floor slab, frame rails, rear sill with its lamps, underride bar, mudflaps, side markers and the kingpin pin.
local function addUnderframe(ctx: Ctx, floorLook: Look)
	local spec, layout = ctx.spec, ctx.layout
	local hw, front, back, deck = layout.halfWidth, layout.front, layout.back, layout.deck
	local floorTop = deck + FLOOR_THICKNESS
	box(ctx, "Floor", floorLook, -hw, hw, deck, floorTop, front, back)
	local frameBottom = deck - FRAME.depth
	local sillFront = back - FRAME.sillDepth
	box(
		ctx,
		"Frame",
		"dark",
		-FRAME.halfWidth,
		FRAME.halfWidth,
		frameBottom,
		deck,
		layout.kingpinZ + FRAME.behindKingpin,
		sillFront
	)
	box(ctx, "RearSill", "trim", -hw, hw, frameBottom, deck, sillFront, back)
	cylinder(ctx, "KingpinPin", "dark", "y", Vector3.new(0, deck - 0.15, layout.kingpinZ), 0.5, 0.3)

	-- Underride bar on two posts behind the rear tires.
	local barTop = 2.0
	box(ctx, "Underride", "trim", -hw + 0.4, hw - 0.4, barTop - 0.5, barTop, back - 0.35, back - 0.05)
	pairBox(ctx, "UnderridePost", "trim", 2.0, 2.3, barTop, frameBottom, back - 0.35, back - 0.1)

	-- Mudflaps behind the rearmost axle.
	local lastAxle = spec.axles[#spec.axles]
	local flapZ = layout.axleZ[lastAxle.id] + spec.wheelRadius + MUDFLAP_GAP
	local inner, outer = spec.track / 2 - spec.wheelWidth / 2, spec.track / 2 + spec.wheelWidth / 2
	pairBox(ctx, "Mudflap", "dark", inner, outer, 0.5, frameBottom, flapZ, flapZ + 0.12)

	-- Amber markers along the floor edge, front and rear, each side.
	local y0 = deck + MARKER.lift
	for _, side in SIDES do
		local x0, x1 = side.sign * hw, side.sign * (hw + 0.04)
		local frontZ, rearZ = front + MARKER.inset, back - MARKER.inset
		box(ctx, `Marker{side.suffix}F`, "marker", x0, x1, y0, y0 + MARKER.height, frontZ, frontZ + MARKER.length)
		box(ctx, `Marker{side.suffix}R`, "marker", x0, x1, y0, y0 + MARKER.height, rearZ - MARKER.length, rearZ)
	end

	-- Lamps on the rear sill: tail lamps at the corners, a brake strip in the middle, the reverse lamp beside it.
	local lampTop, lampBottom = deck - 0.12, deck - 0.36
	lamp(ctx, "TailL", "tail", -hw + 0.15, -hw + 0.95, lampBottom, lampTop)
	lamp(ctx, "TailR", "tail", hw - 0.95, hw - 0.15, lampBottom, lampTop)
	lamp(ctx, "Brake", "brake", -0.9, 0.9, lampBottom + 0.04, lampTop - 0.04)
	lamp(ctx, "Reverse", "reverse", 1.25, 1.85, lampBottom + 0.04, lampTop - 0.04)
end

----------------------------------------------------------------------------------------------------------------
-- Bodies, one per style. All original, generic shapes.
----------------------------------------------------------------------------------------------------------------

-- A dry van: one tall box with a darker front cap, roof rail and rear door frame, swing doors with lock rods, a
-- stripe along both sides and aero skirts between the legs and the axles.
local function boxBody(ctx: Ctx)
	local spec, layout = ctx.spec, ctx.layout
	local hw, front, back = layout.halfWidth, layout.front, layout.back
	local floorTop = layout.deck + FLOOR_THICKNESS
	local top = spec.height
	local cap, roofRail = 0.25, 0.15
	addUnderframe(ctx, "trim")
	box(ctx, "Box", "body", -hw, hw, floorTop, top - roofRail, front + cap, back - cap)
	box(ctx, "FrontCap", "trim", -hw, hw, floorTop, top - roofRail, front, front + cap)
	box(ctx, "RearFrame", "trim", -hw, hw, floorTop, top - roofRail, back - cap, back)
	box(ctx, "RoofRail", "trim", -hw - 0.02, hw + 0.02, top - roofRail, top, front, back)
	box(ctx, "Stripe", "accent", -hw - 0.02, hw + 0.02, floorTop + 1.8, floorTop + 2.4, front + 1.5, back - 1.5)
	local doorBottom, doorTop = floorTop + 0.15, top - roofRail - 0.2
	pairBox(ctx, "Door", "body", 0.03, hw - 0.3, doorBottom, doorTop, back, back + 0.05)
	local rodX = hw / 2
	pairBox(ctx, "LockRod", "trim", rodX - 0.06, rodX + 0.06, doorBottom + 0.2, doorTop - 0.2, back + 0.05, back + 0.1)
	local firstAxle = spec.axles[1]
	local skirtFront = layout.legZ + 1.2
	local skirtBack = layout.axleZ[firstAxle.id] - spec.wheelRadius - 0.6
	pairBox(ctx, "Skirt", "body", hw - 0.1, hw, layout.deck - 1.9, layout.deck, skirtFront, skirtBack)
end

-- A flatbed: a wooden deck with a steel headboard, carrying two strapped crates.
local function flatbedBody(ctx: Ctx)
	local spec, layout = ctx.spec, ctx.layout
	local hw, front = layout.halfWidth, layout.front
	local floorTop = layout.deck + FLOOR_THICKNESS
	local top = spec.height
	addUnderframe(ctx, "deck")
	box(ctx, "Headboard", "trim", -hw, hw, floorTop, top, front, front + 0.4)
	-- Two crates and a strap over each.
	local crates = {
		{ name = "A", half = hw - 0.5, top = top - 0.3, z0 = front + 2.5, z1 = front + 13 },
		{ name = "B", half = hw - 0.8, top = top - 1.3, z0 = front + 15, z1 = front + 26 },
	}
	for _, crate in crates do
		box(ctx, `Crate{crate.name}`, "crate", -crate.half, crate.half, floorTop, crate.top, crate.z0, crate.z1)
		local z = (crate.z0 + crate.z1) / 2
		local reach = crate.half + 0.05
		box(ctx, `Strap{crate.name}`, "strap", -reach, reach, floorTop, crate.top + 0.05, z - 0.15, z + 0.15)
	end
end

-- A tanker: a round steel tank on saddles, dished end caps, a walkway with rails and two hatches on top, a
-- ladder at the back and orange placards on the sides.
local function tankerBody(ctx: Ctx)
	local spec, layout = ctx.spec, ctx.layout
	local front, back = layout.front, layout.back
	local floorTop = layout.deck + FLOOR_THICKNESS
	local saddleGap = 0.25
	local diameter = spec.height - floorTop - saddleGap
	local radius = diameter / 2
	local centerY = floorTop + saddleGap + radius
	local tankFront, tankBack = front + 1.2, back - 0.8
	local tankZ = (tankFront + tankBack) / 2
	addUnderframe(ctx, "trim")
	cylinder(ctx, "Tank", "steel", "z", Vector3.new(0, centerY, tankZ), diameter, tankBack - tankFront)
	cylinder(ctx, "EndCapF", "steel", "z", Vector3.new(0, centerY, tankFront - 0.2), diameter * 0.9, 0.4)
	cylinder(ctx, "EndCapR", "steel", "z", Vector3.new(0, centerY, tankBack + 0.2), diameter * 0.9, 0.4)
	local length = tankBack - tankFront
	for index, share in { -1 / 3, 0, 1 / 3 } do
		local z = tankZ + share * length
		box(ctx, `Saddle{index}`, "trim", -2.6, 2.6, floorTop, floorTop + saddleGap + 1.0, z - 0.4, z + 0.4)
	end
	local tankTop = centerY + radius
	local walkFront, walkBack = tankFront + 3, tankBack - 3
	box(ctx, "Walkway", "trim", -0.6, 0.6, tankTop - 0.05, tankTop + 0.12, walkFront, walkBack)
	pairBox(ctx, "Rail", "trim", 0.62, 0.7, tankTop + 0.9, tankTop + 1.0, walkFront, walkBack)
	for index, share in { -1 / 4, 1 / 4 } do
		cylinder(ctx, `Hatch{index}`, "steel", "y", Vector3.new(0, tankTop + 0.1, tankZ + share * length), 1.4, 0.4)
	end
	box(ctx, "Ladder", "dark", 1.0, 1.5, floorTop, tankTop, back - 0.45, back - 0.3)
	local placardZ = tankBack - 4
	pairBox(
		ctx,
		"Placard",
		"placard",
		radius - 0.02,
		radius + 0.04,
		centerY - 0.5,
		centerY + 0.5,
		placardZ - 0.5,
		placardZ + 0.5
	)
end

local STYLE_BUILDERS: { [Trailers.TrailerStyle]: (Ctx) -> () } = {
	box = boxBody,
	flatbed = flatbedBody,
	tanker = tankerBody,
}

----------------------------------------------------------------------------------------------------------------
-- Contract check
----------------------------------------------------------------------------------------------------------------

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

-- Lists every way `model` breaks the trailer contract (see the header). An empty list means it follows it.
-- Works on any model (greybox or artist-made) whose TrailerId attribute names a Config/Trailers spec.
function TrailerBuilder.check(model: Model): { string }
	local problems: { string } = {}
	local function problem(message: string)
		table.insert(problems, `{model.Name}: {message}`)
	end

	local id = model:GetAttribute(Trailers.idAttribute)
	local spec = if type(id) == "string" then Trailers.trailers[id] else nil
	if spec == nil then
		problem(`missing {Trailers.idAttribute} attribute, or it names no Config/Trailers spec`)
		return problems
	end
	local layout = layoutOf(spec)
	if model.Name ~= spec.id then
		problem(`must be named {spec.id}`)
	end
	if model.ModelStreamingMode ~= Enum.ModelStreamingMode.Atomic then
		problem("ModelStreamingMode must be Atomic")
	end
	if not CollectionService:HasTag(model, Trailers.tag) then
		problem(`must be tagged {Trailers.tag}`)
	end

	local chassis = model:FindFirstChild("Chassis")
	if chassis == nil or not chassis:IsA("Part") then
		problem("has no Chassis part")
		return problems
	end
	if model.PrimaryPart ~= chassis then
		problem("PrimaryPart must be Chassis")
	end
	if not nearVector(chassis.Size, layout.chassisSize) then
		problem("Chassis must be the deck and load from Config/Trailers.chassisGap behind the kingpin to the back")
	end
	if not nearCFrame(model:GetPivot():ToObjectSpace(chassis.CFrame), CFrame.new(layout.chassisCenter)) then
		problem("pivot must be the ground point under the middle of the body, facing forward")
	end
	if chassis.Transparency ~= 1 or not chassis.CanCollide or chassis.Massless then
		problem("Chassis must be invisible, collide, and carry the mass")
	end
	if (chassis.CustomPhysicalProperties :: PhysicalProperties?) == nil then
		problem("Chassis needs CustomPhysicalProperties")
	end

	local kingpin = chassis:FindFirstChild(spec.hitchAttachment)
	if kingpin == nil or not kingpin:IsA("Attachment") then
		problem(`missing attachment {spec.hitchAttachment} on Chassis`)
	elseif not nearCFrame(kingpin.CFrame, toChassis(layout, Vector3.new(0, layout.deck, layout.kingpinZ))) then
		problem(`{spec.hitchAttachment} must sit at the kingpin (kingpinHeight up), oriented like the Chassis`)
	end

	for _, name in { "Body", "Wheels", "Lights", Trailers.landingGearFolder } do
		local folder = model:FindFirstChild(name)
		if folder == nil or not folder:IsA("Folder") then
			problem(`missing {name} folder`)
		end
	end

	-- Every axle's two wheels are ground wheels, and every ground wheel is on an axle.
	for _, axle in spec.axles do
		for _, side in SIDES do
			if table.find(spec.groundWheels, axle.id .. side.suffix) == nil then
				problem(`Config/Trailers: wheel {axle.id}{side.suffix} must be in groundWheels`)
			end
		end
	end
	local wheels = model:FindFirstChild("Wheels")
	local diameter = 2 * spec.wheelRadius
	for _, wheelId in spec.groundWheels do
		local hubGround: Vector3? = layout.hubs[wheelId]
		if hubGround == nil then
			problem(`Config/Trailers: ground wheel {wheelId} is not on any axle`)
			continue
		end
		local expected = toChassis(layout, hubGround)
		local hub = chassis:FindFirstChild("Wheel" .. wheelId)
		if hub == nil or not hub:IsA("Attachment") then
			problem(`missing attachment Wheel{wheelId}`)
		elseif not nearCFrame(hub.CFrame, expected) then
			problem(`Wheel{wheelId} must sit at the hub center at rest`)
		end
		local wheel = if wheels then wheels:FindFirstChild(wheelId) else nil
		if wheel == nil or not wheel:IsA("Part") then
			problem(`missing wheel {wheelId}`)
			continue
		end
		if
			wheel.Shape ~= Enum.PartType.Cylinder
			or not nearVector(wheel.Size, Vector3.new(spec.wheelWidth, diameter, diameter))
		then
			problem(`wheel {wheelId} must be a cylinder sized (wheelWidth, 2 * wheelRadius, 2 * wheelRadius)`)
		end
		local motor = wheel:FindFirstChild("Motor")
		if motor == nil or not motor:IsA("Motor6D") then
			problem(`wheel {wheelId} needs a Motor6D named Motor`)
		elseif
			motor.Part0 ~= chassis
			or motor.Part1 ~= wheel
			or not nearCFrame(motor.C0, expected)
			or not nearCFrame(motor.C1, CFrame.identity)
		then
			problem(`wheel {wheelId}: Motor must join Chassis to the wheel with C0 = hub and C1 = identity`)
		end
	end

	local gear = model:FindFirstChild(Trailers.landingGearFolder)
	local legs = 0
	if gear then
		for _, leg in gear:GetChildren() do
			local motor = leg:FindFirstChild(Trailers.landingGearMotor)
			if leg:IsA("BasePart") and motor and motor:IsA("Motor6D") and motor.Part0 == chassis then
				legs += 1
			end
		end
	end
	if legs < #SIDES then
		problem(`needs {#SIDES} landing legs, each on a Motor6D named {Trailers.landingGearMotor} from Chassis`)
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

	local partCount = 0
	for _, descendant in model:GetDescendants() do
		if not descendant:IsA("BasePart") then
			continue
		end
		partCount += 1
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
		-- Joined to the chassis, or riding on the wheel or leg it is parented to.
		local target = jointTarget(descendant)
		if target == nil or (target ~= chassis and target ~= descendant.Parent) then
			problem(`{descendant.Name} must be welded to Chassis (or to the wheel or leg it sits on)`)
		end
	end
	if partCount > MAX_PARTS then
		problem(`has {partCount} parts; the greybox budget is {MAX_PARTS}`)
	end

	return problems
end

----------------------------------------------------------------------------------------------------------------
-- Building
----------------------------------------------------------------------------------------------------------------

local function requireStudio()
	if not RunService:IsStudio() then
		error("TrailerBuilder is a Studio-only tool", 3)
	end
end

local function requireEditMode()
	requireStudio()
	if RunService:IsRunning() then
		error("TrailerBuilder runs in Edit mode only; stop the playtest first", 3)
	end
end

local function newFolder(name: string, parent: Instance): Folder
	local folder = Instance.new("Folder")
	folder.Name = name
	folder.Parent = parent
	return folder
end

-- Builds a trailer and checks it against the contract, without parenting it anywhere. Errors if the spec is
-- unknown or the result breaks the contract.
function TrailerBuilder.assemble(trailerId: string): Model
	requireStudio()
	local spec = Trailers.trailers[trailerId]
	if spec == nil then
		error(`unknown trailer: {trailerId}`, 2)
	end
	local layout = layoutOf(spec)

	local model = Instance.new("Model")
	model.Name = spec.id
	model.ModelStreamingMode = Enum.ModelStreamingMode.Atomic
	model:SetAttribute(Trailers.idAttribute, spec.id)
	model:SetAttribute(GREYBOX_ATTRIBUTE, true)
	CollectionService:AddTag(model, Trailers.tag)

	-- The chassis box: the only physics body (see the header).
	local chassis = Instance.new("Part")
	chassis.Name = "Chassis"
	chassis.Size = layout.chassisSize
	chassis.CFrame = CFrame.new(layout.chassisCenter)
	chassis.Transparency = 1
	chassis.CanCollide = true
	chassis.CastShadow = false
	chassis.Material = SMOOTH
	chassis.TopSurface = Enum.SurfaceType.Smooth
	chassis.BottomSurface = Enum.SurfaceType.Smooth
	chassis.Anchored = true -- stored parked; HitchService unanchors it when a tractor couples
	chassis.CustomPhysicalProperties =
		PhysicalProperties.new(densityOf(spec, layout), CHASSIS_FRICTION, CHASSIS_ELASTICITY)
	-- With a PrimaryPart, the model's pivot is PrimaryPart.CFrame * PivotOffset: the ground under the body's middle.
	chassis.PivotOffset = CFrame.new(-layout.chassisCenter)
	chassis.Parent = model
	model.PrimaryPart = chassis

	local kingpin = Instance.new("Attachment")
	kingpin.Name = spec.hitchAttachment
	kingpin.CFrame = toChassis(layout, Vector3.new(0, layout.deck, layout.kingpinZ))
	kingpin.Parent = chassis

	local ctx: Ctx = {
		spec = spec,
		layout = layout,
		model = model,
		chassis = chassis,
		body = newFolder("Body", model),
		wheels = newFolder("Wheels", model),
		lights = newFolder("Lights", model),
		gear = newFolder(Trailers.landingGearFolder, model),
	}

	local ok, err = pcall(function()
		local builder = STYLE_BUILDERS[spec.style]
		if builder == nil then
			error(`{spec.id}: no greybox body for style "{spec.style}"`, 0)
		end
		builder(ctx)
		addWheels(ctx)
		addLandingGear(ctx)
	end)
	if not ok then
		model:Destroy()
		error(err, 0)
	end

	local problems = TrailerBuilder.check(model)
	if #problems > 0 then
		model:Destroy()
		error(`{spec.id} breaks the trailer model contract:\n  {table.concat(problems, "\n  ")}`, 2)
	end
	return model
end

export type BuildOptions = {
	replaceArt: boolean?, -- also replace a model that was not built here (artist-made)
}

local function modelsFolder(): Folder
	local existing = ServerStorage:FindFirstChild(Trailers.modelsFolder)
	if existing then
		if existing:IsA("Folder") then
			return existing
		end
		error(`ServerStorage.{Trailers.modelsFolder} must be a Folder`, 0)
	end
	return newFolder(Trailers.modelsFolder, ServerStorage)
end

-- Rebuilds one trailer in ServerStorage.TrailerModels and returns it. The old model is replaced only after the
-- new one passes the contract check, so a failed build leaves the old one in place.
function TrailerBuilder.build(trailerId: string, options: BuildOptions?): Model
	requireEditMode()
	local folder = modelsFolder()
	local existing = folder:FindFirstChild(trailerId)
	local replaceArt = options ~= nil and options.replaceArt == true
	if existing and existing:GetAttribute(GREYBOX_ATTRIBUTE) ~= true and not replaceArt then
		error(`{trailerId} is not a greybox model (artist-made?); pass \{ replaceArt = true } to overwrite it`, 2)
	end
	local model = TrailerBuilder.assemble(trailerId)
	if existing then
		existing:Destroy()
	end
	model.Parent = folder
	return model
end

-- Rebuilds every trailer in Config/Trailers and removes greybox trailers whose spec no longer exists. Artist-made
-- models are kept with a warning. Returns the names built, sorted.
function TrailerBuilder.buildAll(): { string }
	requireEditMode()
	local folder = modelsFolder()
	local ids: { string } = {}
	for id in Trailers.trailers do
		table.insert(ids, id)
	end
	table.sort(ids)

	local built: { string } = {}
	for _, id in ids do
		local existing = folder:FindFirstChild(id)
		if existing and existing:GetAttribute(GREYBOX_ATTRIBUTE) ~= true then
			warn(`[TrailerBuilder] kept {id}: it is not a greybox model`)
		else
			TrailerBuilder.build(id)
			table.insert(built, id)
		end
	end

	for _, child in folder:GetChildren() do
		if Trailers.trailers[child.Name] == nil and child:GetAttribute(GREYBOX_ATTRIBUTE) == true then
			child:Destroy()
		end
	end

	print(`[TrailerBuilder] built {#built} trailers in ServerStorage.{Trailers.modelsFolder}`)
	return built
end

return TrailerBuilder
