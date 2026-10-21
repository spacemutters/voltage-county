--!strict
-- Art pass (docs/art-pass-contracts.md): puts the generated, high-detail drafts in ServerStorage.ArtPassDrafts on
-- the vehicle model contract in place of the greybox, without changing anything that drives. Original designs only
-- (CLAUDE.md hard rule 4): the drafts were generated from generic prompts, with no logos, badges or text.
--
-- Edit-mode tool only (CLAUDE.md hard rules 8 and 9), like Dev/VehicleBuilder. From the command bar or MCP
-- execute_luau (Edit datamodel):
--   require(game.ServerScriptService.Server.Dev.ArtPass).fitAll()
--
-- API
--   fitAll(): Report                    every catalog vehicle (all trims) and trailer that has a draft
--   fit(vehicleId): { Model }           every trim of one vehicle, stored in ServerStorage.VehicleModels
--   fitTrailer(trailerId): Model        one trailer, stored in ServerStorage.TrailerModels
--   assemble(vehicleId, trimId)         one trim's art model, checked but not stored (Edit mode only)
--   assembleTrailer(trailerId)          the same for a trailer
--   checkArt(model): { string }         the art pass's own rules, on top of the contract check (empty = good)
--   draftOf(id): Model?                 the draft a fit uses (the latest regenerated <id>_vN wins over <id>)
--   noteOf(modelName): Note?            what the last fit of a model did (scales, wheel pairing, lamps, arches)
--   pure parts (tests/ArtPass.spec): frontAxis, carFrame, boxBounds, fitAxes, mapPoint, lengthFit, scaleSize,
--   isSingleWheel, assignWheels
--
-- How a model is made, from a fresh greybox build (VehicleBuilder.assemble, TrailerBuilder.assemble):
--   * Frame. A draft's bounding box may be yawed, so everything is worked out in its frame. The front is the end
--     the headlights mesh sits at (a trailer's: the end away from its wheels), snapped to the nearest bounding-box
--     axis. The generator's wheel labels are often wrong, so they are never read: wheels pair up by position.
--   * Body. The greybox Body parts go (but the functional pieces in KEEP); the draft's body, window and light
--     meshes go in, scaled per axis so their combined bounds match the greybox body's bounds (length, width, and
--     height from the body's lowest point) and centered on it, welded to the Chassis like the greybox parts.
--     Lengthwise the fit may give up to LENGTH_FIT.maxEndShift studs at either end to bring the draft's wheel
--     arches over the hubs (ArtPass.lengthFit), since generated cars come with their own wheelbase. A
--     car's painted mesh loses its texture and takes the Paint tag (brand color, the default finish); its windows
--     take Glass; the light meshes keep their textures. Trailers keep every texture (nothing repaints them).
--   * Wheels. Each wheel part keeps its Motor and size and turns invisible; the draft wheel on its side and in its
--     place front to back is welded inside it as Appearance.artWheelName, centered on the hub and scaled to the
--     wheel's diameter and width. Where a side's draft wheels don't pair up one to one, the best-shaped draft wheel
--     stands in for that side, turned round when it comes from the other side so its face still looks out.
--   * Lamps. Every Lights part becomes a glow overlay (Controls.lamps.overlayAttribute: see-through until lit,
--     DriveController and LightShowController). Each side's head and tail lamp is that side's half of the head- or
--     tail-light mesh, a little larger (cut out with solid modeling), so the glow takes the lamp's own shape, the
--     lamp's Light shines from its own side and a light show's left-then-right cues stay apart. The brake lamp is
--     the whole tail-light mesh. Where that mesh is missing or not at its end of the car, and for the reverse
--     lamp, the greybox lamp keeps its size and place across the car and moves onto the art's surface.
--   * Mount points. Mount_*, the plates and CameraHood move onto the art body's surface (raycasts against the
--     fitted meshes, at full collision detail while the fit runs, from their greybox places and the nearest places
--     around them), each stamped ON_ART. Physics attachments (wheel hubs, TowPoint, TowHitch, Kingpin, thrusters),
--     the Chassis and the seats never move.
--   * Kept pieces (KEEP: hitch, underlift, fifth wheel, thruster nozzles, landing-gear tubes) stretch from their
--     outer end until they meet the art's surface (KEEP_REACH), so none floats off a curved tail or sinks under a
--     shorter one, and are stamped ON_ART. Their outer ends, where the physics points sit, stay put.
--   * Trailers. The art never hangs below the kingpin plane over the front, where a coupled tractor's fifth wheel
--     and rear swing under it: the vertical fit puts the art's lowest point there on the Kingpin's height and keeps
--     its top (anchorOnKingpin); the clearance it measured is stamped on the model (KINGPIN_CLEARANCE).
--   * Doors (the Summit's gull-wings). The body mesh draws them shut, so the door parts hide until a light show
--     swings them open (LightShows.look.doorShowAttribute).
-- The result carries Greybox = false and Art = true, passes VehicleBuilder.check (TrailerBuilder.check) and
-- checkArt, and replaces the stored model of the same name; VehicleBuilder.buildAll keeps it from then on. fit()
-- also stores the greybox each trim was fitted to in ServerStorage.GreyboxReference (VehicleBuilder.storeReference),
-- so tests/VehicleBuilder.spec keeps comparing the builder's output with a stored build.

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")
local Workspace = game:GetService("Workspace")

local Appearance = require(ReplicatedStorage.Shared.Vehicle.Appearance)
local BodyKit = require(ReplicatedStorage.Shared.Vehicle.BodyKit)
local Catalog = require(ReplicatedStorage.Shared.Vehicle.Catalog)
local Controls = require(ReplicatedStorage.Shared.Config.Controls)
local Customization = require(ReplicatedStorage.Shared.Config.Customization)
local LightShows = require(ReplicatedStorage.Shared.Config.LightShows)
local Trailers = require(ReplicatedStorage.Shared.Config.Trailers)
local TrailerBuilder = require(script.Parent.TrailerBuilder)
local VehicleBuilder = require(script.Parent.VehicleBuilder)

local DRAFTS_FOLDER = "ArtPassDrafts"
local MODELS_FOLDER = "VehicleModels" -- Config/Spawning.modelsFolder (Dev/VehicleBuilder)
local GREYBOX_ATTRIBUTE = "Greybox"
local MESH_SUFFIX = "_geom" -- the generator names each part's mesh "<part>_geom"
local REGENERATED_MARK = "_v" -- <id>_v2, <id>_v3...: a draft made again because the last was unusable (draftOf)
-- Stamped true on each mount point and kept piece the fit put on the art's surface (checkArt requires it).
local ON_ART = "OnArt"
-- Stamped on a trailer: studs from the Kingpin's height up to the art's lowest point over the front (checkArt).
local KINGPIN_CLEARANCE = "KingpinClearance"

-- The art itself (colors, studs and shares, like the greybox shapes' numbers), not gameplay tunables.
local ART = {
	glass = { color = Color3.fromRGB(30, 38, 48), material = Enum.Material.Glass, transparency = 0.3 },
	-- Glow copies of a light mesh are this much larger than it, so they cover it when lit (the brake over the tail).
	grow = { head = 1.03, tail = 1.03, brake = 1.05 },
	lampProud = 0.02, -- a box lamp stands this far off the surface it moves onto
	lampStep = 0.25, -- ...found at its own height, or the nearest height in these steps...
	lampSearch = 1.5, -- ...up to this far up or down
	minTube = 0.3, -- a landing-gear tube reaches up to the art's underside when that is at least this far up...
	tubeSink = 0.1, -- ...and this far into it
	lightZone = 0.35, -- a light mesh is front (rear) lamps when its center is this share of the length from that end
	lightMinWidth = 0.3, -- ...and it is at least this share of the body's width
	lampCut = 0.05, -- a side's lamp is cut out with this much room around it
	castReach = 4, -- raycasts start this far outside the body
	hoodCamHeight = BodyKit.DETAIL.hoodCamHeight, -- CameraHood stands this far above the hood surface
	-- A mount point no raycast finds a surface for at its greybox place tries the nearest places around it, in these
	-- steps, up to this far away.
	mountStep = 0.25,
	mountSearch = 2,
	keepReach = 4, -- a kept piece reaches at most this far past its inner end to meet the art (a hitch under a bumper)
	keepSink = 0.1, -- ...and this far into it
	-- Trailers: the art keeps clear of the kingpin plane from its front to this far behind the kingpin (the greybox
	-- frame rails start there too: Dev/TrailerBuilder), sampled every kingpinStep studs at these shares of its width.
	kingpinZone = 3.5,
	kingpinStep = 0.5,
	kingpinAcross = { -0.45, -0.25, 0, 0.25, 0.45 },
	-- checkArt: how far (studs) a stored model may be off these rules (Vector3 and CFrame are 32-bit floats).
	wheelFit = 0.05, -- a wheel mesh's center off its hub, or its size off the tire's
	kingpinSlack = 0.05,
}

-- Kept pieces (KEEP) that must meet the art: the ways (ground space) each reaches toward the body, tried in order
-- until one finds it. Rear pieces reach forward, or else up into a bumper above them; the fifth-wheel base reaches
-- down onto the frame. Each keeps its outer end (where its physics point sits) and stretches the inner one.
local KEEP_REACH: { [string]: { Vector3 } } = {
	Hitch = { Vector3.new(0, 0, -1), Vector3.new(0, 1, 0) },
	Underlift = { Vector3.new(0, 0, -1), Vector3.new(0, 1, 0) },
	NozzleL = { Vector3.new(0, 0, -1), Vector3.new(0, 1, 0) },
	NozzleR = { Vector3.new(0, 0, -1), Vector3.new(0, 1, 0) },
	FifthWheelBase = { Vector3.new(0, -1, 0) },
}

-- What a draft wheel mesh must look like to stand for one wheel (ArtPass.isSingleWheel), as shares of its diameter;
-- and how close (studs) two draft wheels are when they are the same wheel made twice.
local WHEEL_SHAPE = { maxWidth = 0.8, minRound = 0.75, samePlace = 0.5 }

-- The lengthwise fit (ArtPass.lengthFit): how much a paired wheel counts against a body end, and how far (studs) a
-- body end may move off the greybox end to line the arches up with the hubs.
local LENGTH_FIT = { axleWeight = 3, maxEndShift = 1 }

-- Greybox Body parts that stay on the art: functional pieces a physics attachment or a mechanism sits on.
local KEEP: { [string]: boolean } = {
	Hitch = true, -- hitch receivers (TowHitch vehicles): a coupled trailer's ball sits on it
	Underlift = true, -- the tow truck's underlift carries its TowHitch
	FifthWheel = true, -- the semi's coupling plate carries its Kingpin (it sits on FifthWheelBase, which meets the art)
	FifthWheelBase = true,
	NozzleL = true, -- the hypercar's cold-gas thruster nozzles (Thruster_L / Thruster_R)
	NozzleR = true,
	TubeL = true, -- a trailer's landing gear: the tubes its legs (on their own Motor6Ds) slide in (fitGear)
	TubeR = true,
}

-- What each lamp of the model contract (and the trailer contract) becomes. A `sided` lamp is its side's half of the
-- light mesh (the side its greybox lamp is on); the others cover the whole mesh.
type LampKind = "head" | "tail" | "brake" | "reverse"
type LampLook = { kind: LampKind, mesh: "head" | "tail" | nil, color: Color3, front: boolean, sided: boolean }
local LAMPS: { [string]: LampLook } = {
	HeadL = { kind = "head", mesh = "head", color = Color3.fromRGB(255, 250, 236), front = true, sided = true },
	HeadR = { kind = "head", mesh = "head", color = Color3.fromRGB(255, 250, 236), front = true, sided = true },
	TailL = { kind = "tail", mesh = "tail", color = Color3.fromRGB(214, 24, 30), front = false, sided = true },
	TailR = { kind = "tail", mesh = "tail", color = Color3.fromRGB(214, 24, 30), front = false, sided = true },
	Brake = { kind = "brake", mesh = "tail", color = Color3.fromRGB(255, 34, 40), front = false, sided = false },
	Reverse = { kind = "reverse", mesh = nil, color = Color3.fromRGB(240, 242, 255), front = false, sided = false },
}
-- Lamp pairs checkArt keeps on their own sides of the centerline (left first: the contract's left is -X).
local LAMP_PAIRS = { { "HeadL", "HeadR" }, { "TailL", "TailR" } }

-- Body mesh names in the art model.
local NAMES = { paint = "BodyShell", glass = "Windows", head = "HeadlightMesh", tail = "TaillightMesh" }

local ArtPass = {}

----------------------------------------------------------------------------------------------------------------
-- Pure parts (tests/ArtPass.spec)
----------------------------------------------------------------------------------------------------------------

export type Bounds = { min: Vector3, max: Vector3 }
export type Box = { cframe: CFrame, size: Vector3 }
-- Per-axis fit: a point p maps to offset + scale * p on each axis.
export type Fit = { scale: Vector3, offset: Vector3 }
-- A draft wheel paired with its wheel part: the draft wheel's z (car frame) and its hub's z (ground space).
export type AxlePair = { from: number, to: number }
export type Slot = { id: string, position: Vector3 } -- a wheel part, ground space
export type WheelMesh = { key: string, position: Vector3 } -- a draft wheel, car frame

local function sign(value: number): number
	return if value < 0 then -1 else 1
end

-- The draft's front as a unit axis of its bounding-box frame: `delta` runs from the body's center to the front
-- marker (the headlights), and the front is whichever of +-X and +-Z it points along most. Height is ignored.
function ArtPass.frontAxis(delta: Vector3): Vector3
	if math.abs(delta.Z) >= math.abs(delta.X) then
		return Vector3.new(0, 0, if delta.Z > 0 then 1 else -1)
	end
	return Vector3.new(sign(delta.X), 0, 0)
end

-- The car frame of a draft: the bounding box's center and up, looking along `forward` (a frontAxis result in the
-- box's own frame). In it the front is -Z and right is +X, like the model contract's ground space.
function ArtPass.carFrame(box: CFrame, forward: Vector3): CFrame
	local look = box:VectorToWorldSpace(forward).Unit
	local up = box.UpVector
	local right = look:Cross(up).Unit
	return CFrame.fromMatrix(box.Position, right, up)
end

-- The axis-aligned bounds, in `frame`, of a set of boxes (parts). nil for none.
function ArtPass.boxBounds(boxes: { Box }, frame: CFrame): Bounds?
	local low: Vector3? = nil
	local high: Vector3? = nil
	for _, box in boxes do
		local rel = frame:ToObjectSpace(box.cframe)
		local half = box.size / 2
		local x, y, z = rel.XVector, rel.YVector, rel.ZVector
		local extent = Vector3.new(
			math.abs(x.X) * half.X + math.abs(y.X) * half.Y + math.abs(z.X) * half.Z,
			math.abs(x.Y) * half.X + math.abs(y.Y) * half.Y + math.abs(z.Y) * half.Z,
			math.abs(x.Z) * half.X + math.abs(y.Z) * half.Y + math.abs(z.Z) * half.Z
		)
		local a, b = rel.Position - extent, rel.Position + extent
		low = if low then low:Min(a) else a
		high = if high then high:Max(b) else b
	end
	if low == nil or high == nil then
		return nil
	end
	return { min = low, max = high }
end

-- The per-axis fit that maps `source` bounds exactly onto `target` bounds.
function ArtPass.fitAxes(source: Bounds, target: Bounds): Fit
	local from, to = source.max - source.min, target.max - target.min
	local function ratio(a: number, b: number): number
		return if a > 1e-6 then b / a else 1
	end
	local scale = Vector3.new(ratio(from.X, to.X), ratio(from.Y, to.Y), ratio(from.Z, to.Z))
	return { scale = scale, offset = target.min - scale * source.min }
end

function ArtPass.mapPoint(fit: Fit, point: Vector3): Vector3
	return fit.offset + fit.scale * point
end

-- The lengthwise (z) fit, as (scale, offset): z' = scale * z + offset. It starts from the bounds fit (the draft
-- body's ends onto the greybox body's ends) and moves toward the fit that also lines the draft's wheels up with the
-- hubs (weighted least squares over both ends, weight 1, and every paired wheel, weight LENGTH_FIT.axleWeight), as
-- far as keeps each body end within LENGTH_FIT.maxEndShift studs of the greybox end. A draft whose wheels already
-- sit where the hubs are keeps the bounds fit; one whose arches are off gets them closer at the cost of a slightly
-- longer or shorter body.
function ArtPass.lengthFit(
	fromMin: number,
	fromMax: number,
	toMin: number,
	toMax: number,
	axles: { AxlePair }
): (number, number)
	local boundsScale = if fromMax - fromMin > 1e-6 then (toMax - toMin) / (fromMax - fromMin) else 1
	local boundsOffset = toMin - boundsScale * fromMin
	if #axles == 0 then
		return boundsScale, boundsOffset
	end
	local points: { { x: number, y: number, w: number } } = {
		{ x = fromMin, y = toMin, w = 1 },
		{ x = fromMax, y = toMax, w = 1 },
	}
	for _, axle in axles do
		table.insert(points, { x = axle.from, y = axle.to, w = LENGTH_FIT.axleWeight })
	end
	local sw, sx, sy = 0, 0, 0
	for _, p in points do
		sw += p.w
		sx += p.w * p.x
		sy += p.w * p.y
	end
	local mx, my = sx / sw, sy / sw
	local sxx, sxy = 0, 0
	for _, p in points do
		sxx += p.w * (p.x - mx) ^ 2
		sxy += p.w * (p.x - mx) * (p.y - my)
	end
	if sxx <= 1e-9 then
		return boundsScale, boundsOffset
	end
	local fitScale = sxy / sxx
	local fitOffset = my - fitScale * mx
	-- How far each end moves at the full least-squares fit; the blend moves them in proportion.
	local worst = math.max(
		math.abs((fitScale - boundsScale) * fromMin + (fitOffset - boundsOffset)),
		math.abs((fitScale - boundsScale) * fromMax + (fitOffset - boundsOffset))
	)
	local t = if worst > LENGTH_FIT.maxEndShift then LENGTH_FIT.maxEndShift / worst else 1
	return boundsScale + t * (fitScale - boundsScale), boundsOffset + t * (fitOffset - boundsOffset)
end

-- A part's new Size when the frame it sits in is scaled per axis by `scale`; `rel` is the part's CFrame in that
-- frame. Each local axis stretches by how much the scale stretches its direction (exact when the part's axes line
-- up with the frame's, as the drafts' meshes do).
function ArtPass.scaleSize(size: Vector3, rel: CFrame, scale: Vector3): Vector3
	local function stretch(axis: Vector3): number
		local scaled = axis * scale
		return scaled.Magnitude
	end
	return Vector3.new(size.X * stretch(rel.XVector), size.Y * stretch(rel.YVector), size.Z * stretch(rel.ZVector))
end

-- Whether a draft wheel mesh's size in the car frame (x across the car) is one wheel: round from the side and no
-- wider than a tire, not a whole axle or a wheel with the fender around it.
function ArtPass.isSingleWheel(size: Vector3): boolean
	local diameter = math.max(size.Y, size.Z)
	if diameter <= 0 then
		return false
	end
	return size.X <= WHEEL_SHAPE.maxWidth * diameter and math.min(size.Y, size.Z) >= WHEEL_SHAPE.minRound * diameter
end

-- Pairs wheel parts with draft wheels by position, never by name: on each side (left is -X, front is -Z, in both
-- spaces) the slots and the meshes are ordered front to back and paired in order. Meshes at the same place along
-- the car (one wheel made twice, or a dual tire's inner and outer wheel) count once. Returns slot id -> mesh key for the sides that pair up one to
-- one, and the slot ids on sides that don't (a side with more or fewer meshes than wheels), sorted.
function ArtPass.assignWheels(slots: { Slot }, meshes: { WheelMesh }): ({ [string]: string }, { string })
	local assigned: { [string]: string } = {}
	local unmatched: { string } = {}
	for _, side in { -1, 1 } do
		local sideSlots: { Slot } = {}
		local sideMeshes: { WheelMesh } = {}
		for _, slot in slots do
			if sign(slot.position.X) == side then
				table.insert(sideSlots, slot)
			end
		end
		for _, mesh in meshes do
			if sign(mesh.position.X) ~= side then
				continue
			end
			local duplicate = false
			for _, kept in sideMeshes do
				if math.abs(kept.position.Z - mesh.position.Z) <= WHEEL_SHAPE.samePlace then
					duplicate = true
				end
			end
			if not duplicate then
				table.insert(sideMeshes, mesh)
			end
		end
		table.sort(sideSlots, function(a: Slot, b: Slot): boolean
			return a.position.Z < b.position.Z
		end)
		table.sort(sideMeshes, function(a: WheelMesh, b: WheelMesh): boolean
			return a.position.Z < b.position.Z
		end)
		if #sideSlots == #sideMeshes then
			for i, slot in sideSlots do
				assigned[slot.id] = sideMeshes[i].key
			end
		else
			for _, slot in sideSlots do
				table.insert(unmatched, slot.id)
			end
		end
	end
	table.sort(unmatched)
	return assigned, unmatched
end

----------------------------------------------------------------------------------------------------------------
-- Drafts
----------------------------------------------------------------------------------------------------------------

type Kind = "car" | "trailer"
type Role = "paint" | "glass" | "head" | "tail" | "wheel" | "gear"

type Draft = {
	id: string,
	frame: CFrame, -- the car frame: bounding-box center, front along -Z
	paint: MeshPart,
	glass: MeshPart?,
	head: MeshPart?,
	tail: MeshPart?,
	gear: MeshPart?,
	wheels: { MeshPart },
}

local function roleOf(meshName: string): Role?
	-- Some generations keep list punctuation in their part names ('["painted body panels"_geom'): letters, digits,
	-- spaces and underscores only.
	local name = string.gsub(string.lower(meshName), "[^%w _]", "")
	if string.sub(name, -#MESH_SUFFIX) == MESH_SUFFIX then
		name = string.sub(name, 1, -#MESH_SUFFIX - 1)
	end
	if string.find(name, "wheel", 1, true) then
		return "wheel"
	elseif name == "windows" then
		return "glass"
	elseif name == "headlights" then
		return "head"
	elseif name == "tail lights" then
		return "tail"
	elseif name == "landing gear" then
		return "gear"
	elseif string.sub(name, 1, 7) == "painted" or name == "body" then
		return "paint"
	end
	return nil
end

local function boxOf(part: BasePart): Box
	return { cframe = part.CFrame, size = part.Size }
end

local function draftsFolder(): Instance
	return ServerStorage:FindFirstChild(DRAFTS_FOLDER) or error(`ServerStorage.{DRAFTS_FOLDER} is missing`, 0)
end

-- A vehicle's or trailer's draft: the latest regenerated one (<id>_v2, <id>_v3...: made when the one before was
-- unusable; earlier drafts stay as they were) wins over <id>.
function ArtPass.draftOf(id: string): Model?
	local folder = draftsFolder()
	local prefix = id .. REGENERATED_MARK
	local best: Model? = nil
	local bestVersion = 0
	for _, child in folder:GetChildren() do
		local version: number? = nil
		if child.Name == id then
			version = 1
		elseif string.sub(child.Name, 1, #prefix) == prefix then
			version = tonumber(string.sub(child.Name, #prefix + 1))
		end
		if child:IsA("Model") and version ~= nil and version > bestVersion then
			best, bestVersion = child, version
		end
	end
	return best
end

-- Reads a draft's meshes by role and finds its car frame.
local function readDraft(id: string, kind: Kind): Draft
	local model = ArtPass.draftOf(id)
	if model == nil then
		error(`no draft for {id} in ServerStorage.{DRAFTS_FOLDER}`, 0)
	end
	local found: { [Role]: MeshPart } = {}
	local wheels: { MeshPart } = {}
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("MeshPart") then
			local role = roleOf(descendant.Name)
			if role == "wheel" then
				table.insert(wheels, descendant)
			elseif role ~= nil and found[role] == nil then
				found[role] = descendant
			end
		end
	end
	local paint = found.paint
	if paint == nil then
		error(`{id}: the draft has no painted body mesh`, 0)
	end
	if #wheels == 0 then
		error(`{id}: the draft has no wheel meshes`, 0)
	end
	if kind == "car" and (found.glass == nil or found.head == nil) then
		error(`{id}: the draft needs separate windows and headlights meshes (regenerate it with the 8 parts)`, 0)
	end
	table.sort(wheels, function(a: MeshPart, b: MeshPart): boolean
		return a.Name < b.Name
	end)

	local box = model:GetBoundingBox()
	local center = box:PointToObjectSpace(paint.Position)
	local delta: Vector3
	if kind == "car" then
		delta = box:PointToObjectSpace((found.head :: MeshPart).Position) - center
	else
		-- A semi trailer's wheels are grouped at its back, so its front is the end away from them (its landing gear
		-- and tail lights are often mislabeled or span the whole underside).
		local sum = Vector3.zero
		for _, wheel in wheels do
			sum += box:PointToObjectSpace(wheel.Position)
		end
		delta = center - sum / #wheels
	end
	return {
		id = id,
		frame = ArtPass.carFrame(box, ArtPass.frontAxis(delta)),
		paint = paint,
		glass = found.glass,
		head = found.head,
		tail = found.tail,
		gear = found.gear,
		wheels = wheels,
	}
end

----------------------------------------------------------------------------------------------------------------
-- Building
----------------------------------------------------------------------------------------------------------------

-- What a fit did, for the report.
export type Note = {
	name: string,
	scale: Vector3, -- draft to greybox body, per axis
	wheels: string, -- "position" or "template:<slots>"
	lamps: { [string]: string }, -- lamp -> "mesh" | "surface" | "kept"
	archOffset: number, -- largest distance along the car between a draft wheel (mapped) and its hub, studs
	mounts: number, -- mount points moved onto the art surface
}

-- The contract's rules for visual parts (BodyKit.dress): massless, unanchored, no collisions, touches or raycasts.
local function dressVisual(part: BasePart)
	part.Anchored = false
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.Massless = true
end

local function weld(anchor: BasePart, part: BasePart)
	local joint = Instance.new("WeldConstraint")
	joint.Part0 = anchor
	joint.Part1 = part
	joint.Parent = part
end

-- Moves (and resizes) a part that is already welded in a model standing in the world: its welds are switched off
-- while it moves, or setting its CFrame would drag the whole car along (Vehicle/Appearance does the same).
local function moveWelded(part: BasePart, cframe: CFrame, size: Vector3?)
	local paused: { WeldConstraint } = {}
	for _, joint in part:GetJoints() do
		if joint:IsA("WeldConstraint") and joint.Enabled then
			joint.Enabled = false
			table.insert(paused, joint)
		end
	end
	if size then
		part.Size = size
	end
	part.CFrame = cframe
	for _, joint in paused do
		joint.Enabled = true
	end
end

-- The face of `part` that looks most along `direction` (a lamp's Light shines out of it).
local function faceToward(part: BasePart, direction: Vector3): Enum.NormalId
	local best, bestDot = Enum.NormalId.Front, -math.huge
	for _, item in Enum.NormalId:GetEnumItems() do
		local face = item :: Enum.NormalId
		local dot = part.CFrame:VectorToWorldSpace(Vector3.FromNormalId(face)):Dot(direction)
		if dot > bestDot then
			best, bestDot = face, dot
		end
	end
	return best
end

-- The draft wheel that looks most like one round wheel: a square side view, not wider than a tire.
local function bestWheel(draft: Draft): MeshPart
	local best, bestScore = draft.wheels[1], math.huge
	for _, mesh in draft.wheels do
		local bounds = ArtPass.boxBounds({ boxOf(mesh) }, draft.frame) :: Bounds
		local size = bounds.max - bounds.min
		local diameter = math.max(size.Y, size.Z)
		local score = math.abs(size.Y - size.Z) / diameter + math.max(0, size.X / diameter - 0.7)
		if score < bestScore then
			best, bestScore = mesh, score
		end
	end
	return best
end

type Ctx = {
	kind: Kind,
	model: Model,
	draft: Draft,
	pivot: CFrame, -- ground space (the model's pivot)
	chassis: BasePart,
	body: Folder,
	target: Bounds, -- the greybox body's bounds, ground space
	fit: Fit,
	sources: { [string]: MeshPart }, -- the draft's body meshes by role
	meshes: { [string]: MeshPart }, -- the fitted body meshes by role
	wheels: { BasePart }, -- the wheel parts
	pairing: { [string]: MeshPart }, -- wheel part name -> its draft wheel, where the sides paired up (by position)
	unmatched: { string }, -- wheel parts whose side didn't pair up: they take the best-shaped draft wheel
	note: Note,
}

-- Pairs the wheel parts with the draft's wheels by position (ArtPass.assignWheels).
local function pairWheels(ctx: Ctx)
	local draft = ctx.draft
	local wheelsFolder = ctx.model:FindFirstChild("Wheels") :: Folder
	local slots: { Slot } = {}
	for _, wheel in wheelsFolder:GetChildren() do
		if wheel:IsA("BasePart") then
			table.insert(ctx.wheels, wheel)
			table.insert(slots, { id = wheel.Name, position = ctx.pivot:PointToObjectSpace(wheel.Position) })
		end
	end
	-- Only meshes shaped like one wheel take part (some generations make one mesh of a whole axle).
	local meshes: { WheelMesh } = {}
	for i, mesh in draft.wheels do
		local bounds = ArtPass.boxBounds({ boxOf(mesh) }, draft.frame) :: Bounds
		if ArtPass.isSingleWheel(bounds.max - bounds.min) then
			table.insert(meshes, { key = tostring(i), position = draft.frame:PointToObjectSpace(mesh.Position) })
		end
	end
	local assigned, unmatched = ArtPass.assignWheels(slots, meshes)
	for slotId, key in assigned do
		ctx.pairing[slotId] = draft.wheels[tonumber(key) :: number]
	end
	ctx.unmatched = unmatched
	ctx.note.wheels = if #unmatched == 0 then "position" else `template:{table.concat(unmatched, ",")}`
end

-- Casts against the fitted body meshes. Ground-space origin and direction in, ground-space hit point out.
local function castOn(ctx: Ctx, origin: Vector3, direction: Vector3): Vector3?
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	local targets: { Instance } = {}
	for _, mesh in ctx.meshes do
		table.insert(targets, mesh)
	end
	params.FilterDescendantsInstances = targets
	local result = Workspace:Raycast(ctx.pivot * origin, ctx.pivot:VectorToWorldSpace(direction), params)
	return if result then ctx.pivot:PointToObjectSpace(result.Position) else nil
end

-- The art surface's height under (x, z), from above.
local function surfaceDown(ctx: Ctx, x: number, z: number): number?
	local top, bottom = ctx.target.max.Y + ART.castReach, ctx.target.min.Y - ART.castReach
	local hit = castOn(ctx, Vector3.new(x, top, z), Vector3.new(0, bottom - top, 0))
	return if hit then hit.Y else nil
end

-- The art surface's z at (x, y), seen from the front or the back.
local function surfaceAlong(ctx: Ctx, x: number, y: number, front: boolean): number?
	local from = if front then ctx.target.min.Z - ART.castReach else ctx.target.max.Z + ART.castReach
	local to = if front then ctx.target.max.Z else ctx.target.min.Z
	local hit = castOn(ctx, Vector3.new(x, y, from), Vector3.new(0, 0, to - from))
	return if hit then hit.Z else nil
end

-- The art surface's x at (y, z), seen from the left or the right.
local function surfaceSide(ctx: Ctx, y: number, z: number, left: boolean): number?
	local from = if left then ctx.target.min.X - ART.castReach else ctx.target.max.X + ART.castReach
	local hit = castOn(ctx, Vector3.new(from, y, z), Vector3.new(-2 * from, 0, 0))
	return if hit then hit.X else nil
end

-- Where a draft body mesh goes under the current fit: its CFrame and size in the model.
local function placeOf(ctx: Ctx, source: MeshPart): (CFrame, Vector3)
	local rel = ctx.draft.frame:ToObjectSpace(source.CFrame)
	local cframe = ctx.pivot * CFrame.new(ArtPass.mapPoint(ctx.fit, rel.Position)) * rel.Rotation
	return cframe, ArtPass.scaleSize(source.Size, rel, ctx.fit.scale)
end

-- Puts every fitted body mesh where the current fit has it (after a refit: anchorOnKingpin).
local function placeAll(ctx: Ctx)
	for role, copy in ctx.meshes do
		local cframe, size = placeOf(ctx, ctx.sources[role])
		moveWelded(copy, cframe, size)
	end
end

-- Swaps the greybox body for the draft's meshes, fitted to the greybox body's bounds.
local function fitBody(ctx: Ctx)
	local draft = ctx.draft
	local sources: { [string]: MeshPart } = { paint = draft.paint }
	if draft.glass then
		sources.glass = draft.glass
	end
	if draft.head then
		sources.head = draft.head
	end
	if draft.tail then
		sources.tail = draft.tail
	end
	ctx.sources = sources
	local sourceBoxes: { Box } = {}
	for _, mesh in sources do
		table.insert(sourceBoxes, boxOf(mesh))
	end
	local source = ArtPass.boxBounds(sourceBoxes, draft.frame) :: Bounds
	local fit = ArtPass.fitAxes(source, ctx.target)
	-- Lengthwise, the paired wheels pull the arches toward the hubs (ArtPass.lengthFit).
	local axles: { AxlePair } = {}
	for _, wheel in ctx.wheels do
		local mesh = ctx.pairing[wheel.Name]
		if mesh then
			local from = draft.frame:PointToObjectSpace(mesh.Position).Z
			table.insert(axles, { from = from, to = ctx.pivot:PointToObjectSpace(wheel.Position).Z })
		end
	end
	local zScale, zOffset = ArtPass.lengthFit(source.min.Z, source.max.Z, ctx.target.min.Z, ctx.target.max.Z, axles)
	ctx.fit = {
		scale = Vector3.new(fit.scale.X, fit.scale.Y, zScale),
		offset = Vector3.new(fit.offset.X, fit.offset.Y, zOffset),
	}
	ctx.note.scale = ctx.fit.scale

	for role, mesh in sources do
		local copy = mesh:Clone()
		copy:ClearAllChildren()
		copy.Name = (NAMES :: any)[role]
		local cframe, size = placeOf(ctx, mesh)
		copy.Size = size
		copy.CFrame = cframe
		dressVisual(copy)
		weld(ctx.chassis, copy)
		copy.Parent = ctx.body
		ctx.meshes[role] = copy
	end

	if ctx.kind == "car" then
		local paint = ctx.meshes.paint
		local finish = Customization.getFinish(Customization.defaults.finish)
		paint.TextureID = ""
		if finish then
			paint.Material = finish.material
			paint.Reflectance = finish.reflectance
		end
		CollectionService:AddTag(paint, "Paint")
		local glass = ctx.meshes.glass
		if glass then
			glass.TextureID = ""
			glass.Color = ART.glass.color
			glass.Material = ART.glass.material
			glass.Transparency = ART.glass.transparency
			CollectionService:AddTag(glass, "Glass")
		end
	end
end

-- Puts a draft wheel inside each wheel part (see the header).
local function fitWheels(ctx: Ctx)
	local draft = ctx.draft
	local template = bestWheel(draft)
	local templateSide = sign(draft.frame:PointToObjectSpace(template.Position).X)
	local archOffset = 0
	for _, wheel in ctx.wheels do
		local paired = ctx.pairing[wheel.Name]
		local hub = ctx.pivot:PointToObjectSpace(wheel.Position)
		local mesh = paired or template
		local rel = draft.frame:ToObjectSpace(mesh.CFrame).Rotation
		if paired == nil and sign(hub.X) ~= templateSide then
			rel = CFrame.Angles(0, math.pi, 0) * rel -- turned round: its outer face looks out on this side too
		end
		if paired ~= nil then
			local mapped = ArtPass.mapPoint(ctx.fit, draft.frame:PointToObjectSpace(mesh.Position))
			archOffset = math.max(archOffset, math.abs(mapped.Z - hub.Z))
		end
		local bounds = ArtPass.boxBounds({ boxOf(mesh) }, draft.frame) :: Bounds
		local extent = bounds.max - bounds.min
		local diameter = math.min(wheel.Size.Y, wheel.Size.Z)
		local scale = Vector3.new(wheel.Size.X / extent.X, diameter / extent.Y, diameter / extent.Z)
		local copy = mesh:Clone()
		copy:ClearAllChildren()
		copy.Name = Appearance.artWheelName
		copy.Size = ArtPass.scaleSize(mesh.Size, rel, scale)
		copy.CFrame = wheel.CFrame * rel
		dressVisual(copy)
		weld(wheel, copy)
		for _, child in wheel:GetChildren() do
			if child:IsA("BasePart") then
				child:Destroy() -- the greybox rim and spoke: the wheel mesh is the stock face
			end
		end
		copy.Parent = wheel
		wheel.Transparency = 1
	end
	ctx.note.archOffset = archOffset
end

-- Whether a fitted light mesh sits where its lamps go: near its end of the car and wide enough to be the lamps.
local function lampMeshFits(ctx: Ctx, mesh: MeshPart?, front: boolean): boolean
	if mesh == nil then
		return false
	end
	local bounds = ArtPass.boxBounds({ boxOf(mesh) }, ctx.pivot) :: Bounds
	local center = (bounds.min + bounds.max) / 2
	local length = ctx.target.max.Z - ctx.target.min.Z
	local width = ctx.target.max.X - ctx.target.min.X
	local zone = ART.lightZone * length
	local atEnd = if front then center.Z <= ctx.target.min.Z + zone else center.Z >= ctx.target.max.Z - zone
	return atEnd and bounds.max.X - bounds.min.X >= ART.lightMinWidth * width
end

local function overlay(part: BasePart, color: Color3)
	part.Color = color
	part.Material = Enum.Material.SmoothPlastic
	part.Transparency = 1
	part.CastShadow = false
	part:SetAttribute(Controls.lamps.overlayAttribute, true)
end

-- The part of `source` (a MeshPart standing in the world) inside the ground-space box from `low` to `high`, as a new
-- part whose CFrame is the box's center (solid modeling keeps the first operand's frame), or nil when the box holds
-- none of it. The cut box is temporary.
local function cutOut(ctx: Ctx, source: BasePart, low: Vector3, high: Vector3): BasePart?
	local box = Instance.new("Part")
	box.Anchored = true
	box.CanCollide = false
	box.Size = high - low
	box.CFrame = ctx.pivot * CFrame.new((low + high) / 2)
	box.Parent = ctx.model
	local ok, result = pcall(function(): Instance
		return box:IntersectAsync({ source }, Enum.CollisionFidelity.Box, Enum.RenderFidelity.Precise)
	end)
	box:Destroy()
	if not ok or result == nil or not result:IsA("BasePart") then
		return nil
	end
	local piece = result :: BasePart
	if piece.Size.Magnitude < 1e-3 then
		piece:Destroy()
		return nil
	end
	return piece
end

-- One side's lamp (`side` -1 left, 1 right) cut out of a light mesh grown by `grow` (see the header): first that
-- half of the car, then again tightly round what the first cut found, so the piece's CFrame (where its Light
-- shines from) is the lamp's own center. nil when that side of the mesh is empty.
local function lampPiece(ctx: Ctx, mesh: MeshPart, side: number, grow: number): BasePart?
	local grown = mesh:Clone()
	grown:ClearAllChildren()
	grown.Size = mesh.Size * grow
	grown.CFrame = mesh.CFrame
	grown.Anchored = true
	grown.Parent = ctx.model
	local bounds = ArtPass.boxBounds({ boxOf(grown) }, ctx.pivot) :: Bounds
	local m = ART.lampCut
	local outer = if side < 0 then bounds.min.X - m else bounds.max.X + m
	local function across(a: number, b: number): (number, number)
		return math.min(a, b), math.max(a, b)
	end
	local x0, x1 = across(0, outer)
	local first = cutOut(
		ctx,
		grown,
		Vector3.new(x0, bounds.min.Y - m, bounds.min.Z - m),
		Vector3.new(x1, bounds.max.Y + m, bounds.max.Z + m)
	)
	if first == nil then
		grown:Destroy()
		return nil
	end
	-- The first cut's real extents (its geometry sits off its CFrame, at the lamp).
	first.Parent = ctx.model
	local center = ctx.pivot:PointToObjectSpace(first.ExtentsCFrame.Position)
	local half = first.ExtentsSize / 2 + Vector3.one * m
	local low, high = center - half, center + half
	-- Never across the centerline: the other side's lamp is the other half.
	if side < 0 then
		high = Vector3.new(math.min(high.X, 0), high.Y, high.Z)
	else
		low = Vector3.new(math.max(low.X, 0), low.Y, low.Z)
	end
	local piece = cutOut(ctx, grown, low, high)
	grown:Destroy()
	if piece == nil then
		piece = first
	else
		first:Destroy()
	end
	return piece
end

-- Turns a lamp part into its overlay `glow` (a light-mesh copy or a cut-out side): it takes the lamp's name and
-- Light, shining out of its face toward `direction`, and the lamp goes.
local function replaceLamp(ctx: Ctx, lamp: BasePart, glow: BasePart, look: LampLook, direction: Vector3)
	glow.Name = lamp.Name
	if glow:IsA("MeshPart") then
		glow.TextureID = ""
		glow.CollisionFidelity = Enum.CollisionFidelity.Box
	end
	overlay(glow, look.color)
	dressVisual(glow)
	weld(ctx.chassis, glow)
	local light = lamp:FindFirstChild("Light")
	if light then
		light.Parent = glow
		if light:IsA("SpotLight") or light:IsA("SurfaceLight") then
			(light :: any).Face = faceToward(glow, direction)
		end
	end
	glow.Parent = lamp.Parent
	lamp:Destroy()
end

-- Turns every lamp into a glow overlay (see the header).
local function fitLamps(ctx: Ctx)
	local lights = ctx.model:FindFirstChild("Lights") :: Folder
	local useMesh = {
		head = lampMeshFits(ctx, ctx.meshes.head, true),
		tail = lampMeshFits(ctx, ctx.meshes.tail, false),
	}
	for _, lamp in lights:GetChildren() do
		local look = LAMPS[lamp.Name]
		if look == nil or not lamp:IsA("BasePart") then
			continue
		end
		local direction = if look.front then ctx.pivot.LookVector else -ctx.pivot.LookVector
		local meshRole = look.mesh
		local mesh = if meshRole ~= nil and useMesh[meshRole] then ctx.meshes[meshRole] else nil
		local grow = (ART.grow :: any)[look.kind] :: number
		local glow: BasePart? = nil
		local how = "mesh"
		if mesh ~= nil and look.sided then
			glow = lampPiece(ctx, mesh, sign(ctx.pivot:PointToObjectSpace(lamp.Position).X), grow)
			how = "side"
		elseif mesh ~= nil then
			local copy = mesh:Clone()
			copy:ClearAllChildren()
			copy.Size = mesh.Size * grow
			copy.CFrame = mesh.CFrame
			glow = copy
		end
		if glow ~= nil then
			ctx.note.lamps[look.kind .. ":" .. lamp.Name] = how
			replaceLamp(ctx, lamp, glow, look, direction)
		else
			-- The greybox lamp keeps its size and place across the car and moves onto the art's surface.
			-- Where the art has nothing at the greybox lamp's height (an open bed, a cut-away bumper), the nearest
			-- height that has a surface, up to lampSearch studs away.
			local rel = ctx.pivot:ToObjectSpace(lamp.CFrame)
			local at = rel.Position
			local surface: number? = nil
			local y = at.Y
			local step = 0
			while surface == nil and step * ART.lampStep <= ART.lampSearch do
				for _, updown in (if step == 0 then { 1 } else { -1, 1 }) :: { number } do
					local tryY = at.Y + updown * step * ART.lampStep
					local hit = if surface == nil then surfaceAlong(ctx, at.X, tryY, look.front) else nil
					if hit ~= nil then
						surface, y = hit, tryY
					end
				end
				step += 1
			end
			if surface ~= nil then
				local depth = lamp.Size.Z / 2 + ART.lampProud
				local z = if look.front then surface - depth else surface + depth
				moveWelded(lamp, ctx.pivot * CFrame.new(at.X, y, z) * rel.Rotation)
			end
			overlay(lamp, look.color)
			ctx.note.lamps[look.kind .. ":" .. lamp.Name] = if surface ~= nil then "surface" else "kept"
		end
	end
end

-- Offsets to try a search at, nearest first: 0, then a step either way, two steps... up to ART.mountSearch.
local function nearby(): { number }
	local list = { 0 }
	for i = 1, math.floor(ART.mountSearch / ART.mountStep + 0.5) do
		table.insert(list, i * ART.mountStep)
		table.insert(list, -i * ART.mountStep)
	end
	return list
end

-- Moves the visual mount points onto the art body's surface (see the header).
local function fitMounts(ctx: Ctx)
	local chassis = ctx.chassis
	local moved = 0
	local offsets = nearby()
	local function ground(name: string): Vector3?
		local point = chassis:FindFirstChild(name)
		if point == nil or not point:IsA("Attachment") then
			return nil
		end
		return ctx.pivot:PointToObjectSpace(point.WorldPosition)
	end
	local function place(name: string, at: Vector3)
		local point = chassis:FindFirstChild(name) :: Attachment
		point.Position = chassis.CFrame:PointToObjectSpace(ctx.pivot * at)
		point:SetAttribute(ON_ART, true)
		moved += 1
	end
	-- The first place `find` finds a surface for: at `at`, then ever further along each axis in turn.
	local function seek(find: (Vector3) -> Vector3?, at: Vector3, axes: { Vector3 }): Vector3?
		for _, axis in axes do
			for _, offset in offsets do
				local found = find(at + axis * offset)
				if found ~= nil then
					return found
				end
			end
		end
		return nil
	end
	local function onTop(name: string, lift: number)
		local at = ground(name)
		local found = if at
			then seek(function(p: Vector3): Vector3?
				local y = surfaceDown(ctx, p.X, p.Z)
				return if y then Vector3.new(p.X, y + lift, p.Z) else nil
			end, at, { Vector3.zAxis, Vector3.xAxis })
			else nil
		if found then
			place(name, found)
		end
	end
	local function onEnd(name: string, front: boolean)
		local at = ground(name)
		local found = if at
			then seek(function(p: Vector3): Vector3?
				local z = surfaceAlong(ctx, p.X, p.Y, front)
				return if z then Vector3.new(p.X, p.Y, z) else nil
			end, at, { Vector3.yAxis, Vector3.xAxis })
			else nil
		if found then
			place(name, found)
		end
	end
	local function onSide(name: string, left: boolean)
		local at = ground(name)
		local found = if at
			then seek(function(p: Vector3): Vector3?
				local x = surfaceSide(ctx, p.Y, p.Z, left)
				return if x then Vector3.new(x, p.Y, p.Z) else nil
			end, at, { Vector3.yAxis, Vector3.zAxis })
			else nil
		if found then
			place(name, found)
		end
	end

	-- The roof: the higher of the surface under the greybox roof point and over the middle of the windows (a
	-- pickup's cab or a van's box, never its bed or hood).
	local roof = ground("Mount_Roof")
	if roof then
		local best: Vector3? = nil
		local zs = { roof.Z }
		local glass = ctx.meshes.glass
		if glass then
			table.insert(zs, ctx.pivot:PointToObjectSpace(glass.Position).Z)
		end
		for _, z in zs do
			local y = surfaceDown(ctx, 0, z)
			if y and (best == nil or y > best.Y) then
				best = Vector3.new(0, y, z)
			end
		end
		if best == nil then
			best = seek(function(p: Vector3): Vector3?
				local y = surfaceDown(ctx, 0, p.Z)
				return if y then Vector3.new(0, y, p.Z) else nil
			end, roof, { Vector3.zAxis })
		end
		if best then
			place("Mount_Roof", best)
		end
	end
	onTop("Mount_Hood", 0)
	onTop("Mount_Spoiler", 0)
	onTop("CameraHood", ART.hoodCamHeight)
	onEnd("Mount_FrontBumper", true)
	onEnd("PlateFront", true)
	onEnd("Mount_RearBumper", false)
	onEnd("PlateRear", false)
	onSide("Mount_SideL", true)
	onSide("Mount_SideR", false)
	ctx.note.mounts = moved
end

-- A trailer's landing gear: the greybox legs stay (Vehicle/Trailer cranks them on their Motor6Ds), and the tubes
-- they slide in now reach up to the art's underside instead of the greybox beam (gone with the greybox body).
local function fitGear(ctx: Ctx)
	for _, name in { "TubeL", "TubeR" } do
		local tube = ctx.body:FindFirstChild(name)
		if tube == nil or not tube:IsA("BasePart") then
			continue
		end
		local at = ctx.pivot:PointToObjectSpace(tube.Position)
		local bottom = at.Y - tube.Size.Y / 2
		local reach = ctx.target.max.Y - bottom + ART.castReach
		local hit = castOn(ctx, Vector3.new(at.X, bottom, at.Z), Vector3.new(0, reach, 0))
		if hit and hit.Y > bottom + ART.minTube then
			local top = hit.Y + ART.tubeSink
			local size = Vector3.new(tube.Size.X, top - bottom, tube.Size.Z)
			moveWelded(tube, ctx.pivot * CFrame.new(at.X, (bottom + top) / 2, at.Z), size)
		end
		if hit then
			tube:SetAttribute(ON_ART, true) -- it reaches the art (or already stood up inside it)
		end
	end
end

-- Stretches a kept piece along `direction` (ground space, from the piece toward the body) until it meets the art:
-- its outer end stays, its inner end goes ART.keepSink into the first surface within ART.keepReach. True when the
-- piece meets the art (already, or stretched); false when there is nothing that way.
local function reachArt(ctx: Ctx, piece: BasePart, direction: Vector3): boolean
	local rel = ctx.pivot:ToObjectSpace(piece.CFrame)
	local axes = { rel.XVector, rel.YVector, rel.ZVector }
	local sizes = { piece.Size.X, piece.Size.Y, piece.Size.Z }
	local axis, best = 1, 0
	for i, vector in axes do
		local along = math.abs(vector:Dot(direction))
		if along > best then
			axis, best = i, along
		end
	end
	local length = sizes[axis]
	local outer = rel.Position - direction * (length / 2)
	local hit = castOn(ctx, outer, direction * (length + ART.keepReach))
	if hit == nil then
		return false
	end
	local depth = (hit - outer):Dot(direction)
	if depth <= length then
		return true -- the art already starts inside the piece
	end
	sizes[axis] = depth + ART.keepSink
	local center = outer + direction * (sizes[axis] / 2)
	moveWelded(piece, ctx.pivot * CFrame.new(center) * rel.Rotation, Vector3.new(sizes[1], sizes[2], sizes[3]))
	return true
end

-- The last resort for a rear piece that is behind and below the art (a hitch under the back of a bumper that
-- ends before it): the piece grows forward, a step at a time up to ART.keepReach, until the art's underside is
-- above it within reach, and up to meet that underside, as one block from its outer end and its bottom. True when it
-- found the underside.
local function reachUnder(ctx: Ctx, piece: BasePart): boolean
	local rel = ctx.pivot:ToObjectSpace(piece.CFrame)
	local bounds = ArtPass.boxBounds({ boxOf(piece) }, ctx.pivot) :: Bounds
	local x = (bounds.min.X + bounds.max.X) / 2
	local reach = bounds.max.Y - bounds.min.Y + ART.keepReach
	local z = bounds.min.Z
	while z >= bounds.min.Z - ART.keepReach do
		local hit = castOn(ctx, Vector3.new(x, bounds.min.Y, z), Vector3.new(0, reach, 0))
		if hit then
			local low = Vector3.new(bounds.min.X, bounds.min.Y, z - ART.mountStep)
			local high = Vector3.new(bounds.max.X, hit.Y + ART.keepSink, bounds.max.Z)
			-- In the piece's own axes (it stands square to the car: a box or a cylinder along the car).
			local size = rel.Rotation:Inverse() * (high - low)
			size = Vector3.new(math.abs(size.X), math.abs(size.Y), math.abs(size.Z))
			moveWelded(piece, ctx.pivot * CFrame.new((low + high) / 2) * rel.Rotation, size)
			return true
		end
		z -= ART.mountStep
	end
	return false
end

-- Makes every kept piece that must meet the art meet it (see the header) and stamps it ON_ART.
local function fitKept(ctx: Ctx)
	for _, piece in ctx.body:GetChildren() do
		local ways = KEEP_REACH[piece.Name]
		if ways == nil or not piece:IsA("BasePart") then
			continue
		end
		local met = false
		for _, direction in ways do
			if reachArt(ctx, piece, direction) then
				met = true
				break
			end
		end
		if not met and ways[1].Z < 0 then
			met = reachUnder(ctx, piece)
		end
		if met then
			piece:SetAttribute(ON_ART, true)
		end
	end
end

-- The lowest point (ground-space height) of the art over a trailer's front: from the front of the body to
-- ART.kingpinZone behind the kingpin, across its width (rays from below). nil when nothing is there.
local function lowestOverFront(ctx: Ctx, kingpinZ: number): number?
	local width = ctx.target.max.X - ctx.target.min.X
	local middle = (ctx.target.max.X + ctx.target.min.X) / 2
	local from, reach = ctx.target.min.Y - ART.castReach, ctx.target.max.Y - ctx.target.min.Y + 2 * ART.castReach
	local lowest: number? = nil
	local z = ctx.target.min.Z
	while z <= kingpinZ + ART.kingpinZone do
		for _, share in ART.kingpinAcross do
			local hit = castOn(ctx, Vector3.new(middle + share * width, from, z), Vector3.new(0, reach, 0))
			if hit and (lowest == nil or hit.Y < lowest) then
				lowest = hit.Y
			end
		end
		z += ART.kingpinStep
	end
	return lowest
end

-- A trailer's art clears the kingpin plane over its front (see the header): when the art's lowest point there is
-- below the Kingpin, the vertical fit is redone to put that point on the Kingpin's height with the top where it
-- was. Stamps the clearance it ends with on the model (KINGPIN_CLEARANCE).
local function anchorOnKingpin(ctx: Ctx)
	local spec = Trailers.trailers[ctx.model.Name]
	local kingpin = if spec then ctx.chassis:FindFirstChild(spec.hitchAttachment) else nil
	if kingpin == nil or not kingpin:IsA("Attachment") then
		return
	end
	local plane = ctx.pivot:PointToObjectSpace(kingpin.WorldPosition)
	local lowest = lowestOverFront(ctx, plane.Z)
	if lowest ~= nil and lowest < plane.Y then
		local scale, offset = ctx.fit.scale, ctx.fit.offset
		local low = (lowest - offset.Y) / scale.Y -- draft space
		local top = (ctx.target.max.Y - offset.Y) / scale.Y
		local y = (ctx.target.max.Y - plane.Y) / (top - low)
		ctx.fit = {
			scale = Vector3.new(scale.X, y, scale.Z),
			offset = Vector3.new(offset.X, plane.Y - y * low, offset.Z),
		}
		ctx.note.scale = ctx.fit.scale
		placeAll(ctx)
		lowest = lowestOverFront(ctx, plane.Z)
	end
	if lowest ~= nil then
		ctx.model:SetAttribute(KINGPIN_CLEARANCE, lowest - plane.Y)
	end
end

-- The Summit's gull-wing doors: hidden until a light show opens them (see the header).
local function hideDoors(model: Model)
	local doors = model:FindFirstChild("Doors")
	if doors == nil then
		return
	end
	for _, part in doors:GetDescendants() do
		if part:IsA("BasePart") then
			part:SetAttribute(LightShows.look.doorShowAttribute, part.Transparency)
			part.Transparency = 1
			-- A hidden window must not take the tint (Appearance sets Glass transparency).
			CollectionService:RemoveTag(part, "Glass")
		end
	end
end

-- Lists every way an art model breaks the art pass's own rules (empty = good). The contract itself is
-- VehicleBuilder.check / TrailerBuilder.check.
function ArtPass.checkArt(model: Model): { string }
	local problems: { string } = {}
	local function problem(message: string)
		table.insert(problems, `{model.Name}: {message}`)
	end
	local trailer = model:GetAttribute(Trailers.idAttribute) ~= nil
	if model:GetAttribute(Appearance.artAttribute) ~= true or model:GetAttribute(GREYBOX_ATTRIBUTE) ~= false then
		problem("must carry Art = true and Greybox = false")
	end
	local body = model:FindFirstChild("Body")
	local paintMesh, glassMesh = false, false
	if body then
		for _, part in body:GetDescendants() do
			if not part:IsA("BasePart") then
				continue
			end
			if part:IsA("MeshPart") then
				if CollectionService:HasTag(part, "Paint") and part.TextureID == "" then
					paintMesh = true
				end
				if CollectionService:HasTag(part, "Glass") then
					glassMesh = true
				end
			elseif not KEEP[part.Name] then
				problem(`greybox part {part.Name} is still in Body`)
			elseif
				(KEEP_REACH[part.Name] or part.Name == "TubeL" or part.Name == "TubeR")
				and part:GetAttribute(ON_ART) ~= true
			then
				problem(`kept piece {part.Name} must meet the art body (no {ON_ART} stamp)`)
			end
		end
	else
		problem("has no Body folder")
	end
	if not trailer and not (paintMesh and glassMesh) then
		problem("needs an untextured body mesh tagged Paint and a window mesh tagged Glass")
	end
	local wheels = model:FindFirstChild("Wheels")
	for _, wheel in if wheels then wheels:GetChildren() else {} do
		if not wheel:IsA("BasePart") then
			continue
		end
		local art = wheel:FindFirstChild(Appearance.artWheelName)
		if art == nil or not art:IsA("MeshPart") then
			problem(`wheel {wheel.Name} has no {Appearance.artWheelName} mesh`)
			continue
		elseif wheel.Transparency ~= 1 then
			problem(`wheel {wheel.Name} must be invisible under its wheel mesh`)
		end
		-- Centered on the hub and the tire's size: the tire's width across, its diameter up and along.
		local offset = wheel.CFrame:PointToObjectSpace(art.Position)
		local bounds = ArtPass.boxBounds({ boxOf(art :: BasePart) }, wheel.CFrame) :: Bounds
		local diameter = math.min(wheel.Size.Y, wheel.Size.Z)
		local wanted = Vector3.new(wheel.Size.X, diameter, diameter)
		local off = (bounds.max - bounds.min) - wanted
		if offset.Magnitude > ART.wheelFit then
			problem(`wheel {wheel.Name}'s mesh is {string.format("%.2f", offset.Magnitude)} studs off its hub`)
		end
		if math.max(math.abs(off.X), math.abs(off.Y), math.abs(off.Z)) > ART.wheelFit then
			problem(`wheel {wheel.Name}'s mesh is not the tire's size ({bounds.max - bounds.min} for {wanted})`)
		end
	end
	local lights = model:FindFirstChild("Lights")
	for _, lamp in if lights then lights:GetChildren() else {} do
		if lamp:IsA("BasePart") then
			if lamp:GetAttribute(Controls.lamps.overlayAttribute) ~= true or lamp.Transparency ~= 1 then
				problem(`lamp {lamp.Name} must be a see-through glow overlay`)
			end
		end
	end
	-- Each side's lamp on its own side, so one-side light-show cues light one side.
	local pivot = model:GetPivot()
	for _, pair in LAMP_PAIRS do
		local left = if lights then lights:FindFirstChild(pair[1]) else nil
		local right = if lights then lights:FindFirstChild(pair[2]) else nil
		if left and right and left:IsA("BasePart") and right:IsA("BasePart") then
			local leftX = pivot:PointToObjectSpace(left.Position).X
			local rightX = pivot:PointToObjectSpace(right.Position).X
			if not (leftX < 0 and rightX > 0) then
				problem(`lamps {pair[1]} and {pair[2]} must be on their own sides (x {leftX}, {rightX})`)
			end
		end
	end
	if trailer then
		local clearance = model:GetAttribute(KINGPIN_CLEARANCE)
		if type(clearance) ~= "number" then
			problem(`has no {KINGPIN_CLEARANCE} stamp (the art over its front was never measured)`)
		elseif clearance < -ART.kingpinSlack then
			problem(`its art hangs {string.format("%.2f", -clearance)} studs below the kingpin plane over the front`)
		end
	else
		local chassis = model:FindFirstChild("Chassis")
		for _, name in BodyKit.VISUAL_POINTS do
			local point = if chassis then chassis:FindFirstChild(name) else nil
			if point and point:IsA("Attachment") and point:GetAttribute(ON_ART) ~= true then
				problem(`mount point {name} is not on the art body (no {ON_ART} stamp)`)
			end
		end
	end
	return problems
end

local function requireStudio()
	if not RunService:IsStudio() then
		error("ArtPass is a Studio-only tool", 3)
	end
end

local function requireEditMode()
	requireStudio()
	if RunService:IsRunning() then
		error("ArtPass runs in Edit mode only; stop the playtest first", 3)
	end
end

-- Puts the draft's art on a fresh greybox `model` (see the header). The model stands in Workspace while its
-- surfaces are raycast and is unparented again before this returns, whatever happens.
local function dressModel(model: Model, draft: Draft, kind: Kind): Note
	local chassis = model.PrimaryPart :: BasePart
	local body = model:FindFirstChild("Body") :: Folder
	local pivot = model:GetPivot()
	local note: Note = { name = model.Name, scale = Vector3.one, wheels = "", lamps = {}, archOffset = 0, mounts = 0 }

	local targetBoxes: { Box } = {}
	for _, part in body:GetChildren() do
		if part:IsA("BasePart") then
			if KEEP[part.Name] then
				continue
			end
			table.insert(targetBoxes, boxOf(part))
			part:Destroy()
		end
	end
	local target = ArtPass.boxBounds(targetBoxes, pivot)
	if target == nil then
		error(`{model.Name}: the greybox has no body to fit to`, 0)
	end

	local ctx: Ctx = {
		kind = kind,
		model = model,
		draft = draft,
		pivot = pivot,
		chassis = chassis,
		body = body,
		target = target,
		fit = ArtPass.fitAxes(target, target),
		sources = {},
		meshes = {},
		wheels = {},
		pairing = {},
		unmatched = {},
		note = note,
	}
	local ok, err = pcall(function()
		pairWheels(ctx)
		fitBody(ctx)
		fitWheels(ctx)
		-- Raycasts (and solid modeling) need the model in the world and its meshes queryable, for a moment, with
		-- collision shapes that follow the meshes closely (they are rebuilt by the next frame).
		model.Parent = Workspace
		for _, mesh in ctx.meshes do
			mesh.CanQuery = true
			mesh.CollisionFidelity = Enum.CollisionFidelity.PreciseConvexDecomposition
		end
		task.wait()
		if kind == "trailer" then
			anchorOnKingpin(ctx)
		end
		fitLamps(ctx)
		if kind == "car" then
			fitMounts(ctx)
		else
			fitGear(ctx)
		end
		fitKept(ctx)
	end)
	-- Nothing collides with or queries the visual meshes, so they keep the simplest collision shape.
	for _, mesh in ctx.meshes do
		mesh.CanQuery = false
		mesh.CollisionFidelity = Enum.CollisionFidelity.Box
	end
	model.Parent = nil
	if not ok then
		error(err, 0)
	end

	if kind == "car" then
		hideDoors(model)
		BodyKit.tintPaint(model, model:GetAttribute("BrandId") :: string)
	end
	model:SetAttribute(GREYBOX_ATTRIBUTE, false)
	model:SetAttribute(Appearance.artAttribute, true)
	return note
end

local notes: { [string]: Note } = {} -- the last fit of each model (fitAll's report)

-- What the last fit of a model did (nil if it hasn't been fitted in this session).
function ArtPass.noteOf(modelName: string): Note?
	return notes[modelName]
end

local function failIfBroken(model: Model, problems: { string })
	for _, item in ArtPass.checkArt(model) do
		table.insert(problems, item)
	end
	if #problems > 0 then
		local name = model.Name
		model:Destroy()
		error(`{name} breaks the model contract:\n  {table.concat(problems, "\n  ")}`, 0)
	end
end

-- One trim's art model, checked against the contract and the art rules, not parented anywhere. Edit mode only: the
-- fit stands the model in Workspace for a moment.
function ArtPass.assemble(vehicleId: string, trimId: string): Model
	requireEditMode()
	local draft = readDraft(vehicleId, "car")
	local model = VehicleBuilder.assemble(vehicleId, trimId)
	notes[model.Name] = dressModel(model, draft, "car")
	failIfBroken(model, VehicleBuilder.check(model))
	return model
end

-- A trailer's art model, checked like assemble's, not parented anywhere. Edit mode only, like assemble.
function ArtPass.assembleTrailer(trailerId: string): Model
	requireEditMode()
	local draft = readDraft(trailerId, "trailer")
	local model = TrailerBuilder.assemble(trailerId)
	notes[model.Name] = dressModel(model, draft, "trailer")
	failIfBroken(model, TrailerBuilder.check(model))
	return model
end

local function store(model: Model, folderName: string)
	local folder = ServerStorage:FindFirstChild(folderName)
	if folder == nil then
		local fresh = Instance.new("Folder")
		fresh.Name = folderName
		fresh.Parent = ServerStorage
		folder = fresh
	end
	local existing = (folder :: Instance):FindFirstChild(model.Name)
	if existing then
		existing:Destroy()
	end
	model.Parent = folder
end

-- Fits every trim of a vehicle and stores the models in ServerStorage.VehicleModels (replacing the greybox).
function ArtPass.fit(vehicleId: string): { Model }
	requireEditMode()
	local vehicle = Catalog.getVehicle(vehicleId)
	if vehicle == nil then
		error(`unknown vehicle {vehicleId}`, 2)
	end
	local built: { Model } = {}
	local ok, err = pcall(function()
		for _, trim in vehicle.trims do
			table.insert(built, ArtPass.assemble(vehicleId, trim.id))
		end
	end)
	if not ok then
		for _, model in built do
			model:Destroy()
		end
		error(err, 0)
	end
	-- Stored only once every trim built, so a failure leaves the vehicle's old models in place. Each trim's greybox
	-- (the one it was fitted to) goes to ServerStorage.GreyboxReference for tests/VehicleBuilder.spec.
	for _, model in built do
		store(model, MODELS_FOLDER)
		VehicleBuilder.storeReference(vehicleId, model:GetAttribute("Trim") :: string)
	end
	return built
end

-- Fits a trailer and stores it in ServerStorage.TrailerModels (replacing the greybox).
function ArtPass.fitTrailer(trailerId: string): Model
	requireEditMode()
	local model = ArtPass.assembleTrailer(trailerId)
	store(model, Trailers.modelsFolder)
	return model
end

export type Report = {
	fitted: { string }, -- model names
	failed: { [string]: string }, -- vehicle or trailer id -> why
	notes: { Note },
}

-- Fits every catalog vehicle and trailer with a draft. A vehicle that fails keeps its old models and is listed.
function ArtPass.fitAll(): Report
	requireEditMode()
	local report: Report = { fitted = {}, failed = {}, notes = {} }
	local function attempt(id: string, run: () -> { Model })
		task.wait() -- one vehicle at a time, so Studio stays responsive through all of them
		local ok, result = pcall(run)
		if not ok then
			report.failed[id] = tostring(result)
			warn(`[ArtPass] {id}: {result}`)
			return
		end
		for _, model in result :: { Model } do
			table.insert(report.fitted, model.Name)
			local note = notes[model.Name]
			if note then
				table.insert(report.notes, note)
			end
		end
	end
	for _, vehicleId in Catalog.vehicleIds() do
		if ArtPass.draftOf(vehicleId) then
			attempt(vehicleId, function()
				return ArtPass.fit(vehicleId)
			end)
		else
			report.failed[vehicleId] = "no draft"
		end
	end
	local trailerIds: { string } = {}
	for id in Trailers.trailers do
		table.insert(trailerIds, id)
	end
	table.sort(trailerIds)
	for _, trailerId in trailerIds do
		if ArtPass.draftOf(trailerId) then
			attempt(trailerId, function()
				return { ArtPass.fitTrailer(trailerId) }
			end)
		else
			report.failed[trailerId] = "no draft"
		end
	end
	local failures = 0
	for _ in report.failed do
		failures += 1
	end
	print(`[ArtPass] fitted {#report.fitted} models; {failures} vehicles or trailers not fitted`)
	return report
end

return ArtPass
