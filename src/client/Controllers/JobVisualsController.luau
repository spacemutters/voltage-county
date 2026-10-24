--!strict
-- What a job looks like in the world, on this client only (docs/phase-6-contracts.md "Client"; PLAN.md Phase 6; the
-- passenger who rides along from the roast fixes, 2026-10-24, docs/roast-2026-10-24.md point 6). Everything here is
-- decoration: the server decides every stop from where it sees the car.
--
--   fares     rideshare: a person waits at the pickup, one arm up to hail the car, and someone waits at the
--             drop-off. Both stand at the road edge of their spot facing the road. When the car stands nearly still
--             at the pickup, the rider walks to its nearest free passenger seat (a door's width outside the car's
--             chassis, on the ground) and, once the server says they are picked up, sits in it: welded to the seat,
--             massless and touching nothing, so they ride along with the car, a little smaller if the cabin needs it
--             (seatedScale). If the car leaves before the pickup counts, they walk back to their spot. When the job
--             ends they get out by their door and walk to the drop-off (or, far from it, to the nearest kerb), then
--             fade away. If the car goes away under them, they go too.
--   parcels   delivery: a small parcel box floats and gently bobs over a soft ring at each drop still to do, at
--             the front of the house plot, and fades once that drop is done.
--
-- The figures are original, simple blocky people built from Parts (no Creator Store models), dressed from a small
-- palette picked by the job id, so each fare looks different but stays the same for the whole job. Everything
-- lives in Workspace.JobVisuals, a folder this client makes (never replicated): no collisions, touches or raycasts,
-- so it never gets in the car's way. What a job showed fades when the job ends or another starts.
--
-- Where things stand: a stop at a MapLayout location's footprint (hotspots, house plots, most GPS places) uses
-- that location's top surface and facing (pads beside a road face it); any other point stands beside the
-- nearest road (Road/Graph), back past its sidewalk, facing it. These parts are local to this client, so
-- streaming never removes them. Driven by JobController.onChanged only; the bobbing is a looping tween and each walk
-- is one tween, not a loop of ours. The placement and pose math is pure and exposed for tests/JobClient.spec and
-- tests/Goals.spec (figureFrames, seatedScale, doorSide).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local BodyKit = require(ReplicatedStorage.Shared.Vehicle.BodyKit)
local Controls = require(ReplicatedStorage.Shared.Config.Controls)
local Graph = require(ReplicatedStorage.Shared.Road.Graph)
local Jobs = require(ReplicatedStorage.Shared.Config.Jobs)
local MapLayout = require(ReplicatedStorage.Shared.Config.MapLayout)
local RoadGraph = require(ReplicatedStorage.Shared.Config.RoadGraph)
local DriveController = require(script.Parent.DriveController)
local JobController = require(script.Parent.JobController)

local FOLDER_NAME = "JobVisuals"
local EPSILON = 1e-6
local SEATS_FOLDER = "Seats" -- vehicle model contract
local DRIVER_SEAT = "Driver"
local RIDESHARE = "rideshare"

-- How the figures and parcels look and where they stand (studs, seconds, degrees).
local LOOK = {
	-- A stop within this many studs (horizontally) of a MapLayout location's position is that location.
	matchRadius = 1,
	-- How far in from the road-side edge of a location's footprint a figure stands, or a parcel sits.
	edgeInset = 2,
	-- A stop that isn't a location: the figure stands at least this far past the road's sidewalk.
	kerbMargin = 2,
	-- A stop closer than this to a road's centre line counts as on it (either side will do).
	centreTolerance = 0.01,
	fadeSeconds = 0.4,

	-- A blocky person about 5 studs tall (PLAN.md §5 scale), parts built up from the feet.
	figure = {
		legSize = Vector3.new(0.85, 2.1, 0.9),
		legGap = 0.2, -- between the legs
		torsoSize = Vector3.new(2, 1.9, 1),
		armSize = Vector3.new(0.65, 1.85, 0.7),
		armGap = 0.05, -- between an arm and the torso
		headSize = Vector3.new(1.15, 1.15, 1.15),
		neck = 0.05, -- between the torso and the head
		hairHeight = 0.3, -- the cap of hair on top of the head
		hairOverhang = 0.05, -- each side
		eyeSize = Vector3.new(0.14, 0.18, 0.05),
		eyeSpacing = 0.36, -- between the eyes' centres
		eyeHeight = 0.12, -- above the head's centre
		eyeColor = Color3.fromRGB(30, 30, 36),
		hailAngle = 150, -- the pickup figure's raised arm, degrees out from hanging down
		skin = {
			Color3.fromRGB(255, 219, 172),
			Color3.fromRGB(241, 194, 125),
			Color3.fromRGB(224, 172, 105),
			Color3.fromRGB(198, 134, 66),
			Color3.fromRGB(141, 85, 36),
			Color3.fromRGB(94, 58, 30),
		},
		shirts = {
			Color3.fromRGB(64, 120, 196),
			Color3.fromRGB(214, 84, 72),
			Color3.fromRGB(80, 160, 110),
			Color3.fromRGB(236, 190, 70),
			Color3.fromRGB(150, 98, 186),
			Color3.fromRGB(236, 236, 230),
			Color3.fromRGB(46, 50, 58),
		},
		trousers = {
			Color3.fromRGB(44, 56, 84),
			Color3.fromRGB(58, 58, 62),
			Color3.fromRGB(112, 92, 70),
			Color3.fromRGB(30, 30, 34),
			Color3.fromRGB(86, 104, 120),
		},
		hair = {
			Color3.fromRGB(28, 24, 22),
			Color3.fromRGB(78, 52, 34),
			Color3.fromRGB(150, 104, 58),
			Color3.fromRGB(222, 190, 120),
			Color3.fromRGB(160, 160, 164),
		},
	},

	-- The rideshare passenger getting in and out (roast fixes 2026-10-24).
	passenger = {
		walkSpeed = 9, -- studs a second
		minWalkSeconds = 0.6,
		maxWalkSeconds = 3, -- a longer way is walked faster
		stepsPerSecond = 2.4, -- leg swings while walking
		swingDegrees = 28, -- each leg's swing either way
		doorGap = 1.2, -- studs outside the chassis' side where they stand to get in or out
		armRestDegrees = 40, -- seated: forearms forward over the lap
		headroomMargin = 0.15, -- studs kept clear under the roof when seated
		minScale = 0.7, -- never shrunk past this to fit a cabin
		maxDropoffWalk = 60, -- studs: farther from the drop-off than this, they walk to the nearest kerb instead
		besideWaiting = 3, -- studs to the side of the drop-off's waiting figure, so they don't stand in each other
		groundProbe = 8, -- studs above and below the door point looked through for the ground
	},

	-- A cardboard parcel floating over a ring at each drop.
	parcel = {
		size = Vector3.new(1.6, 1.2, 1.6),
		color = Color3.fromRGB(184, 140, 92),
		tapeColor = Color3.fromRGB(226, 208, 168),
		tapeWidth = 0.3,
		tapeThickness = 0.04, -- how far the tape stands proud of the box
		hover = 2.2, -- studs from the ground to the box's centre, at rest
		bob = 0.5, -- studs it rises and falls
		bobSeconds = 1.1, -- one rise (or one fall)
		ringDiameter = 5,
		ringThickness = 0.15,
		ringTransparency = 0.45,
		ringColor = Controls.theme.accent, -- the same accent as the GPS route
	},
}

export type Look = "hailing" | "waiting" | "parcel"

-- How a figure holds itself: standing, hailing (right arm up), mid-stride, or sitting on a seat.
export type Stance = "stand" | "hail" | "walk" | "sit"

-- One thing to show at a stop.
export type Marker = { index: number, look: Look }

-- A stop as this module needs it (JobController.Stop has more).
export type StopPoint = { position: Vector3, kind: string }

-- A figure's parts and how it stands now. `base` is its feet on the ground (or the seat top when sitting).
type Rig = { model: Model, parts: { [string]: BasePart }, base: CFrame, scale: number }

type Built = { model: Model, tweens: { Tween }, rig: Rig? }

-- waiting at the stop, walking to the car, waiting at its door, getting in (picked up mid-walk), seated, walking
-- back to the stop (the car left), or gone (out of the car, or dismissed).
type Phase = "waiting" | "walking" | "atDoor" | "boarding" | "seated" | "returning" | "leaving"

type Walk = { tween: Tween, value: NumberValue, connection: RBXScriptConnection }

-- The shown fare's passenger.
type Rider = {
	rig: Rig,
	index: number, -- the pickup stop's index
	stand: CFrame, -- where they waited
	dropoff: CFrame?, -- where they walk to after the ride
	stillMph: number, -- the job type's "nearly still" (Config/Jobs stillSpeedMph)
	phase: Phase,
	pickedUp: boolean, -- the server has moved past the pickup
	car: Model?,
	seat: Seat?,
	seatScale: number,
	welds: { WeldConstraint },
	walk: Walk?,
	carWatch: RBXScriptConnection?,
}

local JobVisualsController = {}
JobVisualsController.look = LOOK

local folder: Folder? = nil
local shownJobId: string? = nil
local built: { [number]: Built } = {} -- by stop index, for the shown job
local done: { [number]: boolean } = {} -- stops of the shown job whose marker has gone (never rebuilt)
local rider: Rider? = nil

-- Pure helpers ----------------------------------------------------------------------------------------------------

local LOOKS: { [string]: Look } = {
	pickup = "hailing",
	dropoff = "waiting",
	drop = "parcel",
}

-- What shows for a job: a figure at the pickup until it's picked up and at the drop-off, and a parcel at each
-- drop still to do. Stops before the current one show nothing; a depot ("load") shows nothing (the GPS marker
-- is there).
function JobVisualsController.markersFor(stops: { StopPoint }, stopIndex: number): { Marker }
	local list: { Marker } = {}
	for index = math.max(stopIndex, 1), #stops do
		local look = LOOKS[stops[index].kind]
		if look ~= nil then
			local marker: Marker = { index = index, look = look :: Look }
			table.insert(list, marker)
		end
	end
	return list
end

local function flat(vector: Vector3): Vector3
	return Vector3.new(vector.X, 0, vector.Z)
end

-- The MapLayout location whose footprint centre is at `position` (within LOOK.matchRadius), or nil. A stop at a
-- location's GPS target (the dealership's display cars) isn't its footprint, so it reads as a plain point.
function JobVisualsController.locationAt(position: Vector3): MapLayout.Location?
	for _, location in MapLayout.locations do
		if flat(location.position - position).Magnitude <= LOOK.matchRadius then
			return location
		end
	end
	return nil
end

-- Where a figure or parcel stands for a stop at `position`: a CFrame on the ground, looking at the road.
--   * A MapLayout location (pads beside a road face it): on its top surface, LOOK.edgeInset in from the edge
--     that faces the road, facing the way the location faces.
--   * Anything else: at the stop, facing the nearest road's centre line; moved back to LOOK.kerbMargin past the
--     road's sidewalk if the stop is on the road or its sidewalk, so nothing stands in the car's way.
function JobVisualsController.standFor(position: Vector3): CFrame
	local location = JobVisualsController.locationAt(position)
	if location ~= nil then
		local facing = CFrame.Angles(0, math.rad(location.yaw), 0)
		local top = location.position + Vector3.yAxis * location.size.Y
		local forward = math.max(location.size.Z / 2 - LOOK.edgeInset, 0)
		return CFrame.new(top) * facing * CFrame.new(0, 0, -forward)
	end

	local edgeIndex, _, distance, road = Graph.nearestEdge(position)
	if edgeIndex == nil then
		return CFrame.new(position)
	end
	local edge = Graph.edges()[edgeIndex]
	local style = RoadGraph.styles[edge.kind]
	local clearance = Graph.edgeWidth(edgeIndex) / 2 + (if style then style.sidewalk else 0) + LOOK.kerbMargin
	local stand = position
	if distance < clearance then
		-- Straight out sideways from the road, on the stop's side of it (the right-hand side for a stop right on
		-- the centre line).
		local along = flat(Graph.pointOnEdge(edgeIndex, 1) - Graph.pointOnEdge(edgeIndex, 0))
		local across = if along.Magnitude > EPSILON then Vector3.new(-along.Z, 0, along.X).Unit else Vector3.xAxis
		local side = across:Dot(flat(position - road))
		local direction = if side < -LOOK.centreTolerance then -across else across
		stand = Vector3.new(road.X, position.Y, road.Z) + direction * clearance
	end
	local toRoad = flat(road - stand)
	if toRoad.Magnitude <= EPSILON then
		return CFrame.new(stand)
	end
	-- Turned about the vertical only, so the figure stands upright: yaw 0 looks north (-Z), 90 west (-X).
	return CFrame.new(stand) * CFrame.Angles(0, math.atan2(-toRoad.X, -toRoad.Z), 0)
end

-- Every part of a figure in `stance`, at UI scale 1, as an offset from its base (feet on the ground, looking along
-- -Z; or, sitting, the top of the seat): legs and arms hang from the hips and shoulders, `swing` (radians) swings
-- them while walking (each leg with the opposite arm). Sitting, the legs stick out forward from the hips and the
-- forearms rest forward over the lap.
function JobVisualsController.figureFrames(stance: Stance, swing: number): { [string]: CFrame }
	local look = LOOK.figure
	local leg, torso, arm, head = look.legSize, look.torsoSize, look.armSize, look.headSize
	local legX = (leg.X + look.legGap) / 2
	local armX = torso.X / 2 + look.armGap + arm.X / 2
	local frames: { [string]: CFrame } = {}
	local sitting = stance == "sit"
	local legSwing = if stance == "walk" then swing else 0

	local hip: number
	if sitting then
		hip = leg.Z / 2 -- the thighs lie on the seat
		local forward = CFrame.Angles(math.rad(90), 0, 0) -- turns a hanging limb's -Y to point forward (-Z)
		frames.LeftLeg = CFrame.new(-legX, hip, 0) * forward * CFrame.new(0, -leg.Y / 2, 0)
		frames.RightLeg = CFrame.new(legX, hip, 0) * forward * CFrame.new(0, -leg.Y / 2, 0)
		frames.Torso = CFrame.new(0, torso.Y / 2, 0)
	else
		hip = leg.Y
		frames.LeftLeg = CFrame.new(-legX, hip, 0) * CFrame.Angles(legSwing, 0, 0) * CFrame.new(0, -leg.Y / 2, 0)
		frames.RightLeg = CFrame.new(legX, hip, 0) * CFrame.Angles(-legSwing, 0, 0) * CFrame.new(0, -leg.Y / 2, 0)
		frames.Torso = CFrame.new(0, hip + torso.Y / 2, 0)
	end

	local shoulderY = (if sitting then 0 else hip) + torso.Y
	local armSwing = if sitting then math.rad(LOOK.passenger.armRestDegrees) else -legSwing
	frames.LeftArm = CFrame.new(-armX, shoulderY, 0) * CFrame.Angles(armSwing, 0, 0) * CFrame.new(0, -arm.Y / 2, 0)
	if stance == "hail" then
		local shoulder = CFrame.new(armX, shoulderY - arm.X / 2, 0)
		frames.RightArm = shoulder
			* CFrame.Angles(0, 0, math.rad(look.hailAngle))
			* CFrame.new(0, -arm.Y / 2 + arm.X / 2, 0)
	else
		local rightSwing = if sitting then armSwing else legSwing
		frames.RightArm = CFrame.new(armX, shoulderY, 0)
			* CFrame.Angles(rightSwing, 0, 0)
			* CFrame.new(0, -arm.Y / 2, 0)
	end

	local headFrame = CFrame.new(0, shoulderY + look.neck + head.Y / 2, 0)
	frames.Head = headFrame
	frames.Hair = headFrame * CFrame.new(0, head.Y / 2 + look.hairHeight / 2 - look.hairOverhang, 0)
	-- Two dark eyes on the front of the head (the front is -Z, the way the figure looks).
	local eyeZ = -(head.Z / 2 + look.eyeSize.Z / 2)
	frames.LeftEye = headFrame * CFrame.new(-look.eyeSpacing / 2, look.eyeHeight, eyeZ)
	frames.RightEye = headFrame * CFrame.new(look.eyeSpacing / 2, look.eyeHeight, eyeZ)
	return frames
end

-- How tall a seated figure is above its seat, at scale 1 (to the top of its hair).
local function seatedHeight(): number
	local look = LOOK.figure
	return look.torsoSize.Y + look.neck + look.headSize.Y + look.hairHeight - look.hairOverhang
end

-- The scale a seated passenger takes so their head stays under the roof: `headroom` studs above the seat's top
-- (less LOOK.passenger.headroomMargin), never above 1 and never below minScale.
function JobVisualsController.seatedScale(headroom: number): number
	local passenger = LOOK.passenger
	local room = headroom - passenger.headroomMargin
	return math.clamp(room / seatedHeight(), passenger.minScale, 1)
end

-- Which side of the car a seat's door is on: 1 for the right (+X in the chassis' space), -1 for the left.
function JobVisualsController.doorSide(chassis: CFrame, seatPosition: Vector3): number
	return if chassis:PointToObjectSpace(seatPosition).X >= 0 then 1 else -1
end

-- A whole number from a string (FNV-1a), for picking colors that stay the same for a job.
local function hash(text: string): number
	local value = 2166136261
	for index = 1, #text do
		value = bit32.bxor(value, string.byte(text, index))
		value = (value * 16777619) % 4294967296
	end
	return value
end

-- Building -------------------------------------------------------------------------------------------------------

-- An anchored part that no physics, touch or raycast ever sees.
local function decor(name: string, size: Vector3, color: Color3, cframe: CFrame, parent: Instance): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.Color = color
	part.Material = Enum.Material.SmoothPlastic
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Anchored = true
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.Locked = true
	part.CFrame = cframe
	part.Parent = parent
	return part
end

local function pick(random: Random, list: { Color3 }): Color3
	return list[random:NextInteger(1, #list)]
end

-- Each part's size at scale 1.
local function partSizes(): { [string]: Vector3 }
	local look = LOOK.figure
	local head = look.headSize
	return {
		LeftLeg = look.legSize,
		RightLeg = look.legSize,
		Torso = look.torsoSize,
		LeftArm = look.armSize,
		RightArm = look.armSize,
		Head = head,
		Hair = Vector3.new(head.X + 2 * look.hairOverhang, look.hairHeight, head.Z + 2 * look.hairOverhang),
		LeftEye = look.eyeSize,
		RightEye = look.eyeSize,
	}
end
local SIZES = partSizes()

-- Puts every part of `rig` where `stance` puts it, at `base` and the rig's scale.
local function pose(rig: Rig, base: CFrame, stance: Stance, swing: number)
	rig.base = base
	local scale = rig.scale
	for name, offset in JobVisualsController.figureFrames(stance, swing) do
		local part = rig.parts[name]
		if part then
			part.Size = SIZES[name] * scale
			part.CFrame = base * CFrame.new(offset.Position * scale) * offset.Rotation
		end
	end
end

-- A blocky person standing at `base` (feet on the ground, looking along its LookVector), hailing or not.
local function buildFigure(name: string, base: CFrame, hailing: boolean, random: Random): Rig
	local look = LOOK.figure
	local model = Instance.new("Model")
	model.Name = name
	local skin = pick(random, look.skin)
	local shirt = pick(random, look.shirts)
	local trousers = pick(random, look.trousers)
	local hair = pick(random, look.hair)
	local colors: { [string]: Color3 } = {
		LeftLeg = trousers,
		RightLeg = trousers,
		Torso = shirt,
		LeftArm = shirt,
		RightArm = shirt,
		Head = skin,
		Hair = hair,
		LeftEye = look.eyeColor,
		RightEye = look.eyeColor,
	}
	local parts: { [string]: BasePart } = {}
	for partName, size in SIZES do
		parts[partName] = decor(partName, size, colors[partName], base, model)
	end
	model.PrimaryPart = parts.Torso
	local rig: Rig = { model = model, parts = parts, base = base, scale = 1 }
	pose(rig, base, if hailing then "hail" else "stand", 0)
	return rig
end

-- A parcel over a ring at `base`, bobbing. Returns the model and its tweens (stopped on removal).
local function buildParcel(name: string, base: CFrame): (Model, { Tween })
	local look = LOOK.parcel
	local model = Instance.new("Model")
	model.Name = name
	local size = look.size
	local ring = decor(
		"Ring",
		Vector3.new(look.ringThickness, look.ringDiameter, look.ringDiameter),
		look.ringColor,
		base * CFrame.new(0, look.ringThickness / 2, 0) * CFrame.Angles(0, 0, math.pi / 2), -- a cylinder's axis is X
		model
	)
	ring.Shape = Enum.PartType.Cylinder
	ring.Material = Enum.Material.Neon
	ring.Transparency = look.ringTransparency
	ring.CastShadow = false

	local center = base * CFrame.new(0, look.hover, 0)
	local proud = 2 * look.tapeThickness
	local parts = {
		decor("Box", size, look.color, center, model),
		-- Two bands of tape crossing over the top and down the sides.
		decor("TapeA", Vector3.new(look.tapeWidth, size.Y + proud, size.Z + proud), look.tapeColor, center, model),
		decor("TapeB", Vector3.new(size.X + proud, size.Y + proud, look.tapeWidth), look.tapeColor, center, model),
	}
	model.PrimaryPart = parts[1]

	local info = TweenInfo.new(look.bobSeconds, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true)
	local tweens: { Tween } = {}
	for _, part in parts do
		local tween = TweenService:Create(part, info, { CFrame = part.CFrame + Vector3.yAxis * look.bob })
		tween:Play()
		table.insert(tweens, tween)
	end
	return model, tweens
end

-- Showing and hiding ---------------------------------------------------------------------------------------------

local function stopTweens(entry: Built)
	for _, tween in entry.tweens do
		tween:Cancel()
	end
end

-- Fades a marker out and then removes it.
local function fadeOut(entry: Built)
	stopTweens(entry)
	local info = TweenInfo.new(LOOK.fadeSeconds, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	for _, descendant in entry.model:GetDescendants() do
		if descendant:IsA("BasePart") then
			TweenService:Create(descendant, info, { Transparency = 1 }):Play()
		end
	end
	local model = entry.model
	task.delay(LOOK.fadeSeconds, function()
		model:Destroy()
	end)
end

-- The passenger ---------------------------------------------------------------------------------------------------

local function carStill(stillMph: number): boolean
	local telemetry = DriveController.getTelemetry()
	return telemetry ~= nil and telemetry.mph <= stillMph
end

local function groundParams(car: Model?): RaycastParams
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local ignore: { Instance } = {}
	if car ~= nil then
		table.insert(ignore, car)
	end
	if folder ~= nil then
		table.insert(ignore, folder)
	end
	local character = Players.LocalPlayer.Character
	if character ~= nil then
		table.insert(ignore, character)
	end
	params.FilterDescendantsInstances = ignore
	return params
end

-- Where someone stands to get in or out of `seat`: a door's width outside the chassis' side, on the ground, facing
-- the car. nil when the car has no chassis.
local function doorFrame(car: Model, seat: BasePart): CFrame?
	local chassis = car.PrimaryPart
	if chassis == nil then
		return nil
	end
	local frame = chassis.CFrame
	local seatLocal = frame:PointToObjectSpace(seat.Position)
	local side = JobVisualsController.doorSide(frame, seat.Position)
	local out = side * (chassis.Size.X / 2 + LOOK.passenger.doorGap)
	local point = frame:PointToWorldSpace(Vector3.new(out, seatLocal.Y, seatLocal.Z))
	local probe = LOOK.passenger.groundProbe
	local hit = Workspace:Raycast(point + Vector3.yAxis * probe, Vector3.yAxis * -(2 * probe), groundParams(car))
	local groundY = if hit ~= nil then hit.Position.Y else chassis.Position.Y - chassis.Size.Y / 2
	local feet = Vector3.new(point.X, groundY, point.Z)
	local toward = flat(seat.Position - feet)
	if toward.Magnitude <= EPSILON then
		return CFrame.new(feet)
	end
	return CFrame.lookAt(feet, feet + toward)
end

-- The car's free passenger seat whose door is nearest `from`, or nil.
local function nearestSeat(car: Model, from: Vector3): Seat?
	local seats = car:FindFirstChild(SEATS_FOLDER)
	if seats == nil then
		return nil
	end
	local best: Seat? = nil
	local bestDistance = math.huge
	for _, child in seats:GetChildren() do
		if child:IsA("Seat") and child.Name ~= DRIVER_SEAT and child.Occupant == nil then
			local door = doorFrame(car, child)
			local distance = if door ~= nil then flat(door.Position - from).Magnitude else math.huge
			if distance < bestDistance then
				best = child
				bestDistance = distance
			end
		end
	end
	return best
end

local function stopWalk(current: Rider)
	local walk = current.walk
	current.walk = nil
	if walk ~= nil then
		walk.tween:Cancel()
		walk.connection:Disconnect()
		walk.value:Destroy()
	end
end

local function unweld(current: Rider)
	for _, weld in current.welds do
		weld:Destroy()
	end
	table.clear(current.welds)
	for _, part in current.rig.parts do
		part.Anchored = true
	end
	if current.carWatch ~= nil then
		current.carWatch:Disconnect()
		current.carWatch = nil
	end
end

-- Takes the passenger away at once (fading).
local function dismiss(current: Rider)
	stopWalk(current)
	unweld(current)
	current.phase = "leaving"
	if rider == current then
		rider = nil
	end
	fadeOut({ model = current.rig.model, tweens = {} })
end

-- Walks the passenger to `target()` (asked again every step, so a door follows its car) over a time set by the
-- distance, growing or shrinking to `toScale` on the way, then calls `arrived`.
local function walk(current: Rider, target: () -> CFrame?, toScale: number, arrived: () -> ())
	stopWalk(current)
	local first = target()
	if first == nil then
		arrived()
		return
	end
	local passenger = LOOK.passenger
	local rig = current.rig
	local start = rig.base
	local fromScale = rig.scale
	local distance = flat(first.Position - start.Position).Magnitude
	local seconds = math.clamp(distance / passenger.walkSpeed, passenger.minWalkSeconds, passenger.maxWalkSeconds)
	local value = Instance.new("NumberValue")
	local connection = value.Changed:Connect(function(alpha: number)
		local goal = target() or first
		local position = start.Position:Lerp(goal.Position, alpha)
		local heading = flat(goal.Position - start.Position)
		local facing = if alpha >= 1
			then goal
			elseif heading.Magnitude > EPSILON then CFrame.lookAt(position, position + heading)
			else CFrame.new(position) * start.Rotation
		local swing = math.sin(alpha * seconds * passenger.stepsPerSecond * math.pi) * math.rad(passenger.swingDegrees)
		rig.scale = fromScale + (toScale - fromScale) * alpha
		pose(rig, facing, if alpha >= 1 then "stand" else "walk", swing)
	end)
	local tween = TweenService:Create(value, TweenInfo.new(seconds, Enum.EasingStyle.Linear), { Value = 1 })
	current.walk = { tween = tween, value = value, connection = connection }
	tween.Completed:Connect(function(state: Enum.PlaybackState)
		local active = current.walk
		if active == nil or active.tween ~= tween then
			return
		end
		stopWalk(current)
		if state == Enum.PlaybackState.Completed then
			arrived()
		end
	end)
	tween:Play()
end

-- Sits the passenger in their seat, welded to it so they ride with the car.
local function sit(current: Rider)
	if current.phase == "seated" or current.phase == "leaving" then
		return
	end
	stopWalk(current)
	local car, seat = current.car, current.seat
	if car == nil or seat == nil or not seat:IsDescendantOf(Workspace) then
		dismiss(current)
		return
	end
	local rig = current.rig
	rig.scale = current.seatScale
	pose(rig, seat.CFrame * CFrame.new(0, seat.Size.Y / 2, 0), "sit", 0)
	for _, part in rig.parts do
		local weld = Instance.new("WeldConstraint")
		weld.Part0 = seat
		weld.Part1 = part
		weld.Parent = part
		table.insert(current.welds, weld)
		part.Massless = true
		part.Anchored = false
	end
	current.phase = "seated"
	-- If the car goes (put away, despawned), the passenger goes with it.
	current.carWatch = car.AncestryChanged:Connect(function()
		if not car:IsDescendantOf(Workspace) then
			dismiss(current)
		end
	end)
end

-- The car waits nearly still at the pickup: the passenger walks to its nearest free passenger door.
local function walkToCar(current: Rider)
	local car = DriveController.getCar()
	local seat = if car ~= nil then nearestSeat(car, current.rig.base.Position) else nil
	if car == nil or seat == nil then
		return
	end
	current.car = car
	current.seat = seat
	-- Seats sit BodyKit.SEATED_HEAD_ROOM under the roof (their centre), so that, less half the seat, is the room above.
	current.seatScale = JobVisualsController.seatedScale(BodyKit.SEATED_HEAD_ROOM - seat.Size.Y / 2)
	current.phase = "walking"
	walk(
		current,
		function(): CFrame?
			if current.pickedUp and not carStill(current.stillMph) then
				-- Picked up and already driving off: in they get.
				if current.phase == "walking" then
					current.phase = "boarding"
					task.defer(sit, current)
				end
				return nil
			end
			return doorFrame(car, seat)
		end,
		current.seatScale,
		function()
			if current.pickedUp then
				sit(current)
			else
				current.phase = "atDoor"
			end
		end
	)
end

-- The car left before the pickup counted: back to their spot, hailing again.
local function walkBack(current: Rider)
	current.phase = "returning"
	walk(
		current,
		function(): CFrame?
			return current.stand
		end,
		1,
		function()
			current.phase = "waiting"
			current.car = nil
			current.seat = nil
			pose(current.rig, current.stand, "hail", 0)
		end
	)
end

-- The server says the passenger is aboard.
local function board(current: Rider)
	current.pickedUp = true
	if current.phase == "atDoor" then
		sit(current)
	elseif current.phase == "waiting" or current.phase == "returning" then
		walkToCar(current) -- picked up before the walk began (it sits them when it arrives)
		local after: Phase = current.phase -- walkToCar may have moved it on
		if after ~= "walking" and after ~= "seated" then
			dismiss(current) -- no car or seat to get into
		end
	end
end

-- The ride is over: out by their door, a walk to the drop-off (or the nearest kerb), then they fade.
local function getOut(current: Rider)
	if current.phase ~= "seated" then
		dismiss(current)
		return
	end
	local car, seat = current.car, current.seat
	local door = if car ~= nil and seat ~= nil then doorFrame(car, seat) else nil
	unweld(current)
	if door == nil then
		dismiss(current)
		return
	end
	current.phase = "leaving"
	if rider == current then
		rider = nil
	end
	pose(current.rig, door, "stand", 0)
	local dropoff = current.dropoff
	local target = if dropoff ~= nil
			and flat(dropoff.Position - door.Position).Magnitude <= LOOK.passenger.maxDropoffWalk
		then dropoff
		else JobVisualsController.standFor(door.Position)
	walk(
		current,
		function(): CFrame?
			return target
		end,
		current.rig.scale,
		function()
			fadeOut({ model = current.rig.model, tweens = {} })
		end
	)
end

-- The job's ride: its pickup and drop-off stops, when it is a rideshare fare.
local function fareStops(job: JobController.Job): (number?, number?)
	if job.type ~= RIDESHARE then
		return nil, nil
	end
	local pickup, dropoff = nil, nil
	for index, stop in job.stops do
		if stop.kind == "pickup" and pickup == nil then
			pickup = index
		elseif stop.kind == "dropoff" then
			dropoff = index
		end
	end
	return pickup, dropoff
end

-- Syncing ---------------------------------------------------------------------------------------------------------

-- The shown job is over (or another started): its passenger gets out, everything else it showed fades.
local function endShownJob()
	local current = rider
	if current ~= nil then
		rider = nil
		getOut(current)
	end
	for _, entry in built do
		if entry.rig == nil or current == nil or entry.rig ~= current.rig then
			fadeOut(entry)
		end
	end
	table.clear(built)
	table.clear(done)
	shownJobId = nil
end

local function build(job: JobController.Job, marker: Marker)
	local container = folder
	if container == nil then
		return
	end
	local stop = job.stops[marker.index]
	local base = JobVisualsController.standFor(stop.position)
	local name = `Stop{marker.index}`
	local entry: Built
	if marker.look == "parcel" then
		local model, tweens = buildParcel(name, base)
		entry = { model = model, tweens = tweens, rig = nil }
	else
		local random = Random.new(hash(`{job.id}#{marker.index}`))
		local rig = buildFigure(name, base, marker.look == "hailing", random)
		entry = { model = rig.model, tweens = {}, rig = rig }
		local pickup, dropoff = fareStops(job)
		if marker.index == pickup and rider == nil then
			local dropoffStand = if dropoff ~= nil
				then JobVisualsController.standFor(job.stops[dropoff].position) * CFrame.new(
					LOOK.passenger.besideWaiting,
					0,
					0
				)
				else nil
			local def = Jobs.types[job.type]
			rider = {
				rig = rig,
				index = marker.index,
				stand = base,
				dropoff = dropoffStand,
				stillMph = if def ~= nil then def.stillSpeedMph else 0,
				phase = "waiting",
				pickedUp = false,
				car = nil,
				seat = nil,
				seatScale = 1,
				welds = {},
				walk = nil,
				carWatch = nil,
			}
		end
	end
	entry.model.Parent = container
	built[marker.index] = entry
end

-- Brings the world in line with the job: a new job ends the old one's showing; stops the job has moved past fade
-- away (the pickup's rider gets in instead); stops still ahead get theirs (once); the rider walks to the car while it
-- waits at the pickup.
local function sync(view: JobController.View)
	local job = view.job
	if job == nil then
		if shownJobId ~= nil then
			endShownJob()
		end
		return
	end
	if job.id ~= shownJobId then
		endShownJob()
		shownJobId = job.id
	end
	local wanted: { [number]: Marker } = {}
	for _, marker in JobVisualsController.markersFor(job.stops, job.stopIndex) do
		wanted[marker.index] = marker
	end
	for index, entry in built do
		if wanted[index] == nil then
			built[index] = nil
			done[index] = true
			local current = rider
			if current ~= nil and current.index == index then
				board(current)
			else
				fadeOut(entry)
			end
		end
	end
	for index, marker in wanted do
		if built[index] == nil and not done[index] then
			build(job, marker)
		end
	end

	local current = rider
	if current ~= nil and not current.pickedUp then
		local waitingHere = job.stopIndex == current.index and view.near
		local idle = current.phase == "waiting" or current.phase == "returning"
		if idle and waitingHere and carStill(current.stillMph) then
			walkToCar(current)
		elseif not view.near and (current.phase == "walking" or current.phase == "atDoor") then
			walkBack(current)
		end
	end
end

function JobVisualsController:Start()
	local stale = Workspace:FindFirstChild(FOLDER_NAME)
	if stale ~= nil then
		stale:Destroy()
	end
	local created = Instance.new("Folder")
	created.Name = FOLDER_NAME
	created.Parent = Workspace
	folder = created

	JobController.onChanged:Connect(sync)
	sync(JobController.get())
end

return JobVisualsController
