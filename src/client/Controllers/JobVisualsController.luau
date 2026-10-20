--!strict
-- What a job looks like in the world, on this client only (docs/phase-6-contracts.md "Client"; PLAN.md Phase 6).
-- Everything here is decoration: the server decides every stop from where it sees the car.
--
--   fares     rideshare: a person waits at the pickup, one arm up to hail the car, and someone waits at the
--             drop-off. Both stand at the road edge of their spot facing the road. The pickup figure fades away
--             once the passenger is picked up (the job moves past that stop).
--   parcels   delivery: a small parcel box floats and gently bobs over a soft ring at each drop still to do, at
--             the front of the house plot, and fades once that drop is done.
--
-- The figures are original, simple blocky people built from Parts (no Creator Store models), dressed from a small
-- palette picked by the job id, so each fare looks different but stays the same for the whole job. Everything
-- lives in Workspace.JobVisuals, a folder this client makes (never replicated): anchored, with no collisions,
-- touches or raycasts, so it never gets in the car's way. It is cleared when the job ends or another starts.
--
-- Where things stand: a stop at a MapLayout location's footprint (hotspots, house plots, most GPS places) uses
-- that location's top surface and facing (pads beside a road face it); any other point stands beside the
-- nearest road (Road/Graph), back past its sidewalk, facing it. These parts are local to this client, so
-- streaming never removes them. Driven by JobController.onChanged only; the bobbing is a looping tween, not a
-- loop of ours. The placement math is pure and exposed for tests/JobClient.spec.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Controls = require(ReplicatedStorage.Shared.Config.Controls)
local Graph = require(ReplicatedStorage.Shared.Road.Graph)
local MapLayout = require(ReplicatedStorage.Shared.Config.MapLayout)
local RoadGraph = require(ReplicatedStorage.Shared.Config.RoadGraph)
local JobController = require(script.Parent.JobController)

local FOLDER_NAME = "JobVisuals"
local EPSILON = 1e-6

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

-- One thing to show at a stop.
export type Marker = { index: number, look: Look }

-- A stop as this module needs it (JobController.Stop has more).
export type StopPoint = { position: Vector3, kind: string }

type Built = { model: Model, tweens: { Tween } }

local JobVisualsController = {}
JobVisualsController.look = LOOK

local folder: Folder? = nil
local shownJobId: string? = nil
local built: { [number]: Built } = {} -- by stop index, for the shown job
local done: { [number]: boolean } = {} -- stops of the shown job whose marker has gone (never rebuilt)

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

-- A blocky person standing at `base` (feet on the ground, looking along its LookVector). `hailing` raises the
-- right arm.
local function buildFigure(name: string, base: CFrame, hailing: boolean, random: Random): Model
	local look = LOOK.figure
	local model = Instance.new("Model")
	model.Name = name
	local skin = pick(random, look.skin)
	local shirt = pick(random, look.shirts)
	local trousers = pick(random, look.trousers)
	local hair = pick(random, look.hair)

	local leg = look.legSize
	local torso = look.torsoSize
	local arm = look.armSize
	local head = look.headSize
	local legX = (leg.X + look.legGap) / 2
	decor("LeftLeg", leg, trousers, base * CFrame.new(-legX, leg.Y / 2, 0), model)
	decor("RightLeg", leg, trousers, base * CFrame.new(legX, leg.Y / 2, 0), model)

	local hip = leg.Y
	local torsoPart = decor("Torso", torso, shirt, base * CFrame.new(0, hip + torso.Y / 2, 0), model)
	model.PrimaryPart = torsoPart

	-- Arms hang from the shoulders at the top of the torso; the right one swings up and out to hail.
	local shoulderY = hip + torso.Y
	local armX = torso.X / 2 + look.armGap + arm.X / 2
	decor("LeftArm", arm, shirt, base * CFrame.new(-armX, shoulderY - arm.Y / 2, 0), model)
	local shoulder = base * CFrame.new(armX, shoulderY - arm.X / 2, 0)
	local raise = if hailing then math.rad(look.hailAngle) else 0
	decor(
		"RightArm",
		arm,
		shirt,
		shoulder * CFrame.Angles(0, 0, raise) * CFrame.new(0, -arm.Y / 2 + arm.X / 2, 0),
		model
	)

	local headY = shoulderY + look.neck + head.Y / 2
	local headCFrame = base * CFrame.new(0, headY, 0)
	decor("Head", head, skin, headCFrame, model)
	decor(
		"Hair",
		Vector3.new(head.X + 2 * look.hairOverhang, look.hairHeight, head.Z + 2 * look.hairOverhang),
		hair,
		headCFrame * CFrame.new(0, head.Y / 2 + look.hairHeight / 2 - look.hairOverhang, 0),
		model
	)
	-- Two dark eyes on the front of the head (the front is -Z, the way the figure looks).
	local eyeZ = -(head.Z / 2 + look.eyeSize.Z / 2)
	for side = -1, 1, 2 do
		local eyeName = if side < 0 then "LeftEye" else "RightEye"
		local offset = CFrame.new(side * look.eyeSpacing / 2, look.eyeHeight, eyeZ)
		decor(eyeName, look.eyeSize, look.eyeColor, headCFrame * offset, model)
	end
	return model
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

-- Removes everything shown for the last job at once.
local function clearAll()
	for _, entry in built do
		stopTweens(entry)
		entry.model:Destroy()
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
		entry = { model = model, tweens = tweens }
	else
		local random = Random.new(hash(`{job.id}#{marker.index}`))
		entry = { model = buildFigure(name, base, marker.look == "hailing", random), tweens = {} }
	end
	entry.model.Parent = container
	built[marker.index] = entry
end

-- Brings the world in line with the job: a new job clears the old one's markers; stops the job has moved past
-- fade away; stops still ahead get theirs (once).
local function sync(view: JobController.View)
	local job = view.job
	if job == nil then
		if shownJobId ~= nil then
			clearAll()
		end
		return
	end
	if job.id ~= shownJobId then
		clearAll()
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
			fadeOut(entry)
		end
	end
	for index, marker in wanted do
		if built[index] == nil and not done[index] then
			build(job, marker)
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
