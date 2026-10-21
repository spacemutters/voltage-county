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
--   storeReference(vehicleId, trimId)   builds a trim's greybox into ServerStorage.GreyboxReference (art trims)
--   bodyStyles(): {string}              every bodyStyle with a generic body
--   check(model): {string}              lists every way a model breaks the contract (empty = good)
--
-- Bodies: the eight Ohm vehicles keep their bespoke silhouettes (SHAPES, below). Every other vehicle gets a
-- generic body built from its bodyStyle and geometry, with its brand's face, tail lamps and default paint. The
-- generic bodies, wheels, seats, lamps, attachments and the contract check live in Vehicle/BodyKit (Phase 11), so
-- player designs (Vehicle/SpecBuilder) build at runtime from the same code; this module keeps the Edit-mode API,
-- the Ohm silhouettes and the storage.
--
-- Building is idempotent: a rebuild replaces the old model and produces the same instances every time. Models
-- built here carry the attribute Greybox = true. A model without it (artist-made) is never overwritten unless
-- build() is called with { replaceArt = true }. Every model is checked against the contract before it is
-- stored, so a broken shape fails the build instead of reaching the game.
--
-- Shapes are authored in "ground space": the origin is the point on the ground under the chassis center, +X is
-- right, +Y is up and the front of the car is -Z (the chassis LookVector). The numbers inside each shape
-- function are the greybox art itself (panel positions in studs), not gameplay tunables.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")

local BodyKit = require(ReplicatedStorage.Shared.Vehicle.BodyKit)
local Catalog = require(ReplicatedStorage.Shared.Vehicle.Catalog)
local Vehicles = require(ReplicatedStorage.Shared.Config.Vehicles)

local MODELS_FOLDER = "VehicleModels"
local GREYBOX_ATTRIBUTE = "Greybox" -- marks models this builder owns; artist models never carry it
-- Where the greybox of a trim whose stored model is art (Dev/ArtPass) is kept, for tests/VehicleBuilder.spec.
local REFERENCE_FOLDER = "GreyboxReference"

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

-- The body kit's shared details and part helpers (Vehicle/BodyKit), under the names the silhouettes use.
local DETAIL = BodyKit.DETAIL
local SIDES = BodyKit.SIDES
local SEATED_HEAD_ROOM = BodyKit.SEATED_HEAD_ROOM
local frameOf = BodyKit.frameOf
local weld = BodyKit.weld
local newBlock = BodyKit.newBlock
local box = BodyKit.box
local pairBox = BodyKit.pairBox
local wedge = BodyKit.wedge
local cylinder = BodyKit.cylinder
local lamp = BodyKit.lamp
local pairLamp = BodyKit.pairLamp
local hang = BodyKit.hang
local at = BodyKit.at

type Look = BodyKit.Look
type Shape = BodyKit.Shape
type Ctx = BodyKit.Ctx
type Frame = BodyKit.Frame

local VehicleBuilder = {}

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
-- bodyStyle (Vehicle/BodyKit).
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

-- The body builder for a vehicle: its bespoke silhouette, or the generic body for its bodyStyle (Vehicle/BodyKit).
-- `generic` skips the bespoke silhouette (specs use it to build every style). nil when there is neither.
local function shapeFor(vehicleId: string, vehicle: Vehicles.Vehicle, generic: boolean): ((Ctx) -> Shape)?
	local bespoke = SHAPES[vehicleId]
	if bespoke and not generic then
		return bespoke
	end
	return BodyKit.genericShape(vehicle.bodyStyle)
end

----------------------------------------------------------------------------------------------------------------
-- Contract check
----------------------------------------------------------------------------------------------------------------

-- Lists every way `model` breaks the vehicle model contract. An empty list means it follows it. Works on any
-- model (greybox or artist-made) whose VehicleId and Trim attributes name a catalog trim (Vehicle/Catalog, so a
-- published player design too). The rules themselves are BodyKit.check.
function VehicleBuilder.check(model: Model): { string }
	local vehicleId, trimId = model:GetAttribute("VehicleId"), model:GetAttribute("Trim")
	if type(vehicleId) ~= "string" or type(trimId) ~= "string" then
		return { `{model.Name}: missing VehicleId or Trim attribute` }
	end
	local vehicle = Catalog.getVehicle(vehicleId)
	local trim = Catalog.getTrim(vehicleId, trimId)
	local g = Catalog.geometry(vehicleId, trimId)
	if vehicle == nil or trim == nil or g == nil then
		return { `{model.Name}: {vehicleId}/{trimId} is not in the catalog` }
	end
	return BodyKit.check(model, vehicle, trim, g, Catalog.modelName(vehicleId, trimId))
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
	local model = BodyKit.assemble(vehicle, trim, g, { name = name, shape = shapeOf })
	model:SetAttribute(GREYBOX_ATTRIBUTE, true)
	BodyKit.tintPaint(model, vehicle.brandId)

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
	return BodyKit.bodyStyles()
end

export type BuildOptions = {
	replaceArt: boolean?, -- also replace a model that was not built here (artist-made)
}

local function folderNamed(name: string): Folder
	local existing = ServerStorage:FindFirstChild(name)
	if existing then
		if existing:IsA("Folder") then
			return existing
		end
		error(`ServerStorage.{name} must be a Folder`, 0)
	end
	return newFolder(name, ServerStorage)
end

local function modelsFolder(): Folder
	return folderNamed(MODELS_FOLDER)
end

VehicleBuilder.referenceFolder = REFERENCE_FOLDER

-- Builds one trim's greybox into ServerStorage.GreyboxReference (replacing the one there) and returns it: the
-- greybox a trim's art model was fitted to (Dev/ArtPass.fit), which tests/VehicleBuilder.spec compares fresh
-- builds with, as it does the greybox models in VehicleModels.
function VehicleBuilder.storeReference(vehicleId: string, trimId: string): Model
	requireEditMode()
	local folder = folderNamed(REFERENCE_FOLDER)
	local model = VehicleBuilder.assemble(vehicleId, trimId)
	local existing = folder:FindFirstChild(model.Name)
	if existing then
		existing:Destroy()
	end
	model.Parent = folder
	return model
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
-- Artist-made models and vehicles without a shape are skipped with a warning; an art model's greybox reference
-- (ServerStorage.GreyboxReference) is rebuilt instead, so a deliberate builder change is taken into the stored
-- builds as it is for greybox models (tests/ArtPass.spec then says whether the art needs fitting again). Returns
-- the names built.
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
			local shaped = shapeFor(vehicleId, vehicle, false) ~= nil
			if existing and existing:GetAttribute(GREYBOX_ATTRIBUTE) ~= true then
				if shaped then
					VehicleBuilder.storeReference(vehicleId, trim.id)
				end
				warn(`[VehicleBuilder] kept {name}: it is not a greybox model (its greybox reference was rebuilt)`)
			elseif not shaped then
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
	local references = ServerStorage:FindFirstChild(REFERENCE_FOLDER)
	for _, child in if references then references:GetChildren() else {} do
		if not wanted[child.Name] then
			child:Destroy()
		end
	end

	print(`[VehicleBuilder] built {#built} models in ServerStorage.{MODELS_FOLDER}`)
	return built
end

return VehicleBuilder
