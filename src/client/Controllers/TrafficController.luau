--!strict
-- Ambient pods on this client (PLAN.md Phase 9; docs/phase-9-contracts.md "Ambient pods = ambient traffic").
--
-- The server publishes routes, never physics (Services/TrafficService): Net TrafficRoutes buffers of route records
-- (Road/TrafficPath.decode). This client builds the same lane line and speed profile from each record
-- (TrafficPath.plan) and puts each pod where its profile says it is at workspace:GetServerTimeNow(), so every
-- player sees the same pods in the same places with nothing sent per frame. A pod keeps the routes after its current
-- one (the server sends each a few seconds early) and moves on to the next where the last one ends; if a route ends
-- before the next one is here, the pod waits there.
--
-- Drawing: one RenderStepped connection. A pod within Config/Traffic render.distance of the camera borrows a copy of
-- ReplicatedStorage.TrafficModels.ohm_pod from a pool (a plain box if that model hasn't arrived after
-- render.modelWaitSeconds). A copy lives only on this client, in Workspace.TrafficPods: its Chassis is anchored and
-- every other part hangs off it on the model's own welds and wheel Motors (anything loose gets welded on), and no
-- part collides, takes queries or touches. So one CFrame write moves it, and its wheels turn by Motor.Transform
-- alone. Each frame it is placed by its distance along the route: on the lane line, facing along it (the heading
-- across render.headingSpan studs, then smoothed), leaning a little out of turns, wheels spun by its speed and the
-- front ones steered by its turn rate (the bicycle model Vehicle/WheelVisuals uses for other players' cars). A pod
-- out of range gives its copy back to the pool and is only looked at every render.hiddenCheckSeconds, so a frame
-- costs O(drawn pods). A drawn pod beyond render.farDistance moves on every render.farInterval-th frame only.
--
-- Yielding, on this client only: a drawn pod with a player's car (CollectionService Config/Spawning vehicleTag)
-- ahead in its lane within yield.lookAhead slows to keep yield.gap behind it by running its own clock slower (a
-- per-pod delay behind the server's schedule). With the road clear it runs up to yield.catchUp faster than the
-- schedule until the delay is gone. A pod held almost still for yield.maxHoldSeconds drives on through (pods never
-- collide with anything). The server never hears about it.
--
-- TrafficController.stats() is for Dev/TrafficTests: every pod's route and progress, how many are drawn, and a ring
-- of recent step times (os.clock around the whole step). In Studio a BindableFunction "Bridge" under this module
-- forwards stats() and setRenderAll() from another copy of the module (MCP's execute_luau gets its own) to the
-- running one, as Dev/AutoDriver does.

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local Driving = require(Shared.Config.Driving)
local Graph = require(Shared.Road.Graph)
local Net = require(Shared.Net)
local Spawning = require(Shared.Config.Spawning)
local Traffic = require(Shared.Config.Traffic)
local TrafficPath = require(Shared.Road.TrafficPath)
local WheelVisuals = require(Shared.Vehicle.WheelVisuals)
local World = require(Shared.Config.World)

local LOG = "[TrafficController]"
local BRIDGE_NAME = "Bridge"
local REMOTE = "TrafficRoutes"
local CHASSIS = "Chassis" -- vehicle model contract
local WHEELS_FOLDER = "Wheels"
local WHEEL_MOTOR = "Motor"
local STANDARD_GRAVITY = 9.80665 -- m/s²
local TWO_PI = 2 * math.pi
local MS_PER_SECOND = 1000
local EPSILON = 1e-6

-- One pod as stats() reports it.
export type PodStats = {
	index: number,
	seq: number, -- the route being driven (-1 before the first arrives)
	distance: number, -- studs along it
	length: number, -- studs, the whole route
	speed: number, -- studs/s as drawn (the schedule's speed x the yield)
	delay: number, -- seconds behind the server's schedule
	yielding: boolean, -- slowing for a player's car
	waiting: boolean, -- at the end of its last route, waiting for the next
	visible: boolean,
	routes: number, -- routes held: the one driven and any after it
}

export type Stats = {
	pods: number, -- pods with a route
	visible: number, -- pods drawn in the last step
	steps: number, -- steps run so far
	stepTimes: { number }, -- the most recent step times in ms, oldest first (at most render.statRing)
	podStats: { PodStats },
	renderAll: boolean,
}

type Route = {
	seq: number,
	startAt: number,
	endAt: number,
	plan: TrafficPath.Plan,
}

type Wheel = { motor: Motor6D, radius: number, front: boolean, spin: number }

type Body = {
	model: Model,
	root: BasePart,
	offset: CFrame, -- the root's CFrame relative to the model's pivot (the ground under its centre)
	wheels: { Wheel },
	wheelbase: number,
}

type Pod = {
	index: number,
	routes: { Route }, -- in start order; routes[1] is the one being driven
	delay: number,
	rate: number, -- how fast its clock runs now (1 = on schedule)
	yielding: boolean,
	waiting: boolean,
	holdTime: number, -- seconds held almost still behind a car
	passUntil: number, -- os.clock() until which it ignores cars (driving on through one)
	seq: number,
	distance: number,
	length: number,
	speed: number,
	pathHint: number,
	profileHint: number,
	visible: boolean,
	body: Body?,
	look: Vector3?, -- the smoothed heading drawn last frame
	bank: number, -- radians, + = leaning left
	steer: number, -- front wheel yaw, radians, + = left
	lastUpdate: number, -- os.clock()
	nextCheck: number, -- os.clock() at which a pod that isn't drawn is looked at again
	rangeSquared: number, -- squared studs from the camera at its last update (render.farDistance)
}

local render = Traffic.render
local yieldConfig = Traffic.yield
local wheelConfig = Driving.wheelVisuals
local G_PER_STUD_ACCEL = World.metersPerStud / STANDARD_GRAVITY -- g per stud/s²

local TrafficController = {}

local pods: { [number]: Pod } = {}
local nodeCount = #Graph.nodes()
local folder: Folder? = nil
local template: Model? = nil
local modelResolved = false -- the template has arrived, or this client gave up waiting and draws boxes
local pool: { Body } = {}
local renderAll = false -- Studio only (setRenderAll): draw every pod wherever the camera is
local isHost = false -- this copy runs the game's pods and serves the bridge

-- Players' cars this frame (gathered once, only when some pod is drawn).
local cars: { [Model]: boolean } = {}
local carPositions: { Vector3 } = {}
local carVelocities: { Vector3 } = {}
local carCount = 0
local carsGathered = false

local visibleCount = 0
local stepTimes: { number } = table.create(render.statRing, 0)
local stepCount = 0

-- Pod copies ------------------------------------------------------------------------------------------------------

local function quiet(part: BasePart)
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
end

-- Anchors only `root` and makes every other part hang off it: the model's own welds and Motors where they reach
-- it, a new weld for any part nothing holds. No part collides, takes queries or touches.
local function holdTogether(model: Model, root: BasePart)
	local links: { [BasePart]: { BasePart } } = {}
	local function link(a: BasePart?, b: BasePart?)
		if a and b then
			links[a] = links[a] or {}
			links[b] = links[b] or {}
			table.insert(links[a], b)
			table.insert(links[b], a)
		end
	end
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("JointInstance") then
			local joint = descendant :: JointInstance
			link(joint.Part0, joint.Part1)
		elseif descendant:IsA("WeldConstraint") then
			local weld = descendant :: WeldConstraint
			link(weld.Part0, weld.Part1)
		end
	end
	local held: { [BasePart]: boolean } = { [root] = true }
	local queue: { BasePart } = { root }
	while #queue > 0 do
		local part = table.remove(queue) :: BasePart
		for _, other in links[part] or {} do
			if not held[other] then
				held[other] = true
				table.insert(queue, other)
			end
		end
	end
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			local part = descendant :: BasePart
			quiet(part)
			part.Anchored = part == root
			if not held[part] then
				local weld = Instance.new("WeldConstraint")
				weld.Part0 = root
				weld.Part1 = part
				weld.Parent = part
			end
		end
	end
end

local function wheelsOf(model: Model): ({ Wheel }, number)
	local wheels: { Wheel } = {}
	local wheelsFolder = model:FindFirstChild(WHEELS_FOLDER)
	local frontZ, rearZ = 0, 0
	for _, id in WheelVisuals.WHEEL_IDS do
		local part = if wheelsFolder then wheelsFolder:FindFirstChild(id) else nil
		local motor = if part then part:FindFirstChild(WHEEL_MOTOR) else nil
		if part and part:IsA("BasePart") and motor and motor:IsA("Motor6D") then
			local front = string.sub(id, 1, 1) == "F"
			-- Wheels are cylinders with the axle along X, so the diameter is the Y (= Z) size.
			table.insert(wheels, {
				motor = motor,
				radius = math.max(part.Size.Y, part.Size.Z) / 2,
				front = front,
				spin = 0,
			})
			if front then
				frontZ = motor.C0.Position.Z
			else
				rearZ = motor.C0.Position.Z
			end
		end
	end
	return wheels, math.abs(rearZ - frontZ)
end

local function boxBody(): Body
	local box = Instance.new("Part")
	box.Name = CHASSIS
	box.Size = Traffic.fallback.size
	box.Color = Traffic.fallback.color
	box.Material = Traffic.fallback.material
	box.TopSurface = Enum.SurfaceType.Smooth
	box.BottomSurface = Enum.SurfaceType.Smooth
	box.Anchored = true
	quiet(box)
	local model = Instance.new("Model")
	model.Name = Traffic.models.modelName
	model:SetAttribute(Traffic.models.podAttribute, true)
	box.Parent = model
	model.PrimaryPart = box
	return {
		model = model,
		root = box,
		offset = CFrame.new(0, Traffic.fallback.size.Y / 2, 0),
		wheels = {},
		wheelbase = 0,
	}
end

-- The part a copy moves by: its PrimaryPart, else its Chassis, else any part.
local function rootOf(model: Model): BasePart?
	local primary = model.PrimaryPart
	if primary then
		return primary
	end
	local named = model:FindFirstChild(CHASSIS)
	if named and named:IsA("BasePart") then
		return named
	end
	return model:FindFirstChildWhichIsA("BasePart", true) :: BasePart?
end

local function newBody(): Body
	local source = template
	if source then
		local model = source:Clone()
		local root = rootOf(model)
		if root then
			holdTogether(model, root)
			local wheels, wheelbase = wheelsOf(model)
			return {
				model = model,
				root = root,
				offset = model:GetPivot():ToObjectSpace(root.CFrame),
				wheels = wheels,
				wheelbase = wheelbase,
			}
		end
		model:Destroy()
	end
	return boxBody()
end

-- A copy to draw a pod with, or nil while the model is still on its way.
local function acquire(): Body?
	if not modelResolved or folder == nil then
		return nil
	end
	local body = table.remove(pool) or newBody()
	body.model.Parent = folder
	return body
end

local function release(body: Body)
	body.model.Parent = nil
	table.insert(pool, body)
end

-- Waits (in its own thread) for the server's pod model, or gives up and settles for boxes.
local function resolveModel()
	local holder = ReplicatedStorage:WaitForChild(Traffic.models.folderName, render.modelWaitSeconds)
	local found = if holder then holder:WaitForChild(Traffic.models.modelName, render.modelWaitSeconds) else nil
	if found and found:IsA("Model") then
		template = found
	else
		warn(`{LOG} no pod model arrived; drawing plain boxes`)
	end
	modelResolved = true
end

-- Routes ----------------------------------------------------------------------------------------------------------

local function newPod(index: number): Pod
	return {
		index = index,
		routes = {},
		delay = 0,
		rate = 1,
		yielding = false,
		waiting = false,
		holdTime = 0,
		passUntil = 0,
		seq = -1,
		distance = 0,
		length = 0,
		speed = 0,
		pathHint = 1,
		profileHint = 1,
		visible = false,
		body = nil,
		look = nil,
		bank = 0,
		steer = 0,
		lastUpdate = os.clock(),
		nextCheck = 0,
		rangeSquared = 0,
	}
end

local function addRoute(record: TrafficPath.Record)
	local pod = pods[record.pod]
	if pod == nil then
		pod = newPod(record.pod)
		pods[record.pod] = pod
	end
	for _, route in pod.routes do
		if route.seq == record.seq then
			return -- already here (a joiner's full set and a broadcast can cross)
		end
	end
	local plan = TrafficPath.plan(Graph, record.nodes, record.scale, record.lead)
	if plan == nil then
		warn(`{LOG} pod {record.pod} got a route this road graph can't follow`)
		return
	end
	local route: Route = {
		seq = record.seq,
		startAt = record.startAt,
		endAt = record.startAt + plan.duration,
		plan = plan,
	}
	local at = #pod.routes + 1
	while at > 1 and pod.routes[at - 1].startAt > route.startAt do
		at -= 1
	end
	table.insert(pod.routes, at, route)
	while #pod.routes > render.maxRoutes do
		table.remove(pod.routes, 1)
		pod.pathHint, pod.profileHint = 1, 1
	end
	pod.nextCheck = 0 -- look at it on the next step, drawn or not
end

local function onRoutes(payload: any)
	local records = TrafficPath.decode(payload, nodeCount)
	if records == nil then
		warn(`{LOG} ignored a route message it couldn't read`)
		return
	end
	for _, record in records do
		addRoute(record)
	end
end

-- Players' cars ---------------------------------------------------------------------------------------------------

local function trackCar(instance: Instance)
	if instance:IsA("Model") then
		cars[instance] = true
	end
end

local function untrackCar(instance: Instance)
	if instance:IsA("Model") then
		cars[instance] = nil
	end
end

-- Every car near enough to a drawn pod to matter (all of them with renderAll), once per step.
local function gatherCars(origin: Vector3?)
	carsGathered = true
	carCount = 0
	local reach = render.distance + render.hysteresis + yieldConfig.lookAhead
	local reachSquared = reach * reach
	for model in cars do
		local root = model.PrimaryPart
		if root then
			local position = root.Position
			local near = renderAll or origin == nil
			if not near and origin then
				local dx, dz = position.X - origin.X, position.Z - origin.Z
				near = dx * dx + dz * dz <= reachSquared
			end
			if near then
				carCount += 1
				carPositions[carCount] = position
				carVelocities[carCount] = root.AssemblyLinearVelocity
			end
		end
	end
end

-- The rate a drawn pod's clock should run at (1 = on schedule) and whether that is yielding to a car ahead in its
-- lane. `scheduled` is the schedule's speed now (studs/s), `heading` the way the pod faces.
local function yieldRate(
	pod: Pod,
	position: Vector3,
	heading: Vector3,
	scheduled: number,
	clock: number
): (number, boolean)
	local free = if pod.delay > 0 then 1 + yieldConfig.catchUp else 1
	if pod.waiting or scheduled <= EPSILON or clock < pod.passUntil or carCount == 0 then
		return free, false
	end
	local fx, fz = heading.X, heading.Z
	local size = math.sqrt(fx * fx + fz * fz)
	if size < EPSILON then
		return free, false
	end
	fx, fz = fx / size, fz / size
	local nearest, carSpeed = math.huge, 0
	for i = 1, carCount do
		local p = carPositions[i]
		local rx, ry, rz = p.X - position.X, p.Y - position.Y, p.Z - position.Z
		local along = rx * fx + rz * fz
		if
			along > 0
			and along < yieldConfig.lookAhead
			and along < nearest
			and math.abs(ry) < yieldConfig.heightReach
		then
			-- Sideways distance: the offset across the pod's right vector (-fz, 0, fx).
			if math.abs(rz * fx - rx * fz) < yieldConfig.laneHalfWidth then
				nearest = along
				local velocity = carVelocities[i]
				carSpeed = velocity.X * fx + velocity.Z * fz
			end
		end
	end
	if nearest == math.huge then
		return free, false
	end
	local allowed = math.max(carSpeed, 0) + math.max(nearest - yieldConfig.gap, 0) * yieldConfig.followGain
	if allowed >= scheduled then
		return free, false
	end
	return allowed / scheduled, true
end

-- Drawing ---------------------------------------------------------------------------------------------------------

-- Places a drawn pod's copy and turns its wheels for this frame.
local function pose(pod: Pod, body: Body, position: Vector3, direction: Vector3, speed: number, dt: number)
	local previous = pod.look
	local look = direction
	if previous then
		local blended = previous:Lerp(direction, 1 - math.exp(-render.yawResponse * dt))
		look = if blended.Magnitude > EPSILON then blended.Unit else direction
	end
	pod.look = look

	-- Turn rate about +Y (+ = turning left), from the heading drawn last frame to this one.
	local yawRate = 0
	if previous and dt > 0 then
		local cross = previous.Z * look.X - previous.X * look.Z
		local dot = previous.X * look.X + previous.Z * look.Z
		yawRate = math.atan2(cross, dot) / dt
	end

	-- Lean out of the turn: a left turn (yawRate > 0) rolls the body right, a negative roll about its back axis.
	local lateralG = speed * yawRate * G_PER_STUD_ACCEL
	local bankTarget = -math.rad(math.clamp(lateralG * render.bankDegPerG, -render.maxBankDeg, render.maxBankDeg))
	pod.bank += (bankTarget - pod.bank) * (1 - math.exp(-render.bankResponse * dt))

	local ground = CFrame.lookAt(position, position + look) * CFrame.Angles(0, 0, pod.bank)
	body.root.CFrame = ground * body.offset

	if #body.wheels == 0 then
		return
	end
	-- Steering from the turn rate (bicycle model: tan(yaw) = wheelbase x turn rate / speed), as WheelVisuals does.
	local steerTarget = 0
	if speed >= wheelConfig.inferMinSpeed and body.wheelbase > 0 then
		local maxSteer = math.rad(wheelConfig.maxSteerDeg)
		steerTarget = math.clamp(math.atan(body.wheelbase * yawRate / speed), -maxSteer, maxSteer)
	end
	pod.steer += (steerTarget - pod.steer) * math.min(1, wheelConfig.steerSmoothing * dt)
	for _, wheel in body.wheels do
		-- Rolling forward (-Z) turns the top of the wheel forward, a negative rotation about X.
		wheel.spin = (wheel.spin - speed / wheel.radius * dt) % TWO_PI
		wheel.motor.Transform = if wheel.front
			then CFrame.Angles(0, pod.steer, 0) * CFrame.Angles(wheel.spin, 0, 0)
			else CFrame.Angles(wheel.spin, 0, 0)
	end
end

local function show(pod: Pod): boolean
	local body = acquire()
	if body == nil then
		return false
	end
	pod.body = body
	pod.look = nil
	pod.bank = 0
	pod.steer = 0
	pod.visible = true
	return true
end

local function hide(pod: Pod)
	local body = pod.body
	if body then
		release(body)
		pod.body = nil
	end
	pod.visible = false
end

-- Moves one pod's clock on, finds where its route puts it, and draws it if it is in range.
local function updatePod(pod: Pod, now: number, clock: number, origin: Vector3?)
	local dt = math.max(clock - pod.lastUpdate, 0)
	pod.lastUpdate = clock
	-- Its clock ran at pod.rate since the last update: slower builds a delay, faster wins it back.
	pod.delay = math.max(pod.delay + dt * (1 - pod.rate), 0)
	if not pod.visible and pod.delay > yieldConfig.maxDelay then
		pod.delay = 0 -- nobody here can see it jump
	end

	local routes = pod.routes
	local time = now - pod.delay
	while #routes >= 2 and time >= routes[2].startAt do
		table.remove(routes, 1)
		pod.pathHint, pod.profileHint = 1, 1
	end
	local route = routes[1]
	if route == nil then
		return
	end
	pod.waiting = false
	if time > route.endAt and #routes == 1 then
		-- The next route isn't here yet: hold at the end (the delay grows) and carry on from here when it comes.
		pod.delay = now - route.endAt
		time = route.endAt
		pod.waiting = true
	end
	local plan = route.plan
	local distance, scheduled, profileHint = TrafficPath.distanceAt(plan.profile, time - route.startAt, pod.profileHint)
	local position, pathHint = TrafficPath.positionAt(plan.path, distance, pod.pathHint)
	pod.profileHint, pod.pathHint = profileHint, pathHint
	pod.seq, pod.distance, pod.length = route.seq, distance, plan.length

	local inRange = renderAll
	if origin then
		local offset = position - origin
		pod.rangeSquared = offset:Dot(offset)
		if not inRange then
			local limit = render.distance + (if pod.visible then render.hysteresis else 0)
			inRange = pod.rangeSquared <= limit * limit
		end
	end
	if inRange and not pod.visible then
		show(pod)
	elseif not inRange and pod.visible then
		hide(pod)
	end
	local body = pod.body
	if not pod.visible or body == nil then
		pod.rate = if pod.delay > 0 then 1 + yieldConfig.catchUp else 1
		pod.yielding = false
		pod.holdTime = 0
		pod.speed = if pod.waiting then 0 else scheduled * pod.rate
		pod.nextCheck = clock + render.hiddenCheckSeconds
		return
	end

	visibleCount += 1
	if not carsGathered then
		gatherCars(origin)
	end
	local direction = TrafficPath.directionAt(plan.path, distance, render.headingSpan, pathHint)
	local target, yielding = yieldRate(pod, position, pod.look or direction, scheduled, clock)
	local response = if target < pod.rate then yieldConfig.brakeResponse else yieldConfig.releaseResponse
	pod.rate += (target - pod.rate) * (1 - math.exp(-response * dt))
	pod.yielding = yielding
	if yielding and pod.rate < yieldConfig.holdRate then
		pod.holdTime += dt
		if pod.holdTime >= yieldConfig.maxHoldSeconds then
			pod.passUntil = clock + yieldConfig.passSeconds
			pod.holdTime = 0
		end
	else
		pod.holdTime = 0
	end
	local speed = if pod.waiting then 0 else scheduled * pod.rate
	pod.speed = speed
	pose(pod, body, position, direction, speed, dt)
end

local function step()
	local clock = os.clock()
	if next(pods) ~= nil then
		local camera = Workspace.CurrentCamera
		local origin = if camera then camera.CFrame.Position else nil
		local now = Workspace:GetServerTimeNow()
		carsGathered = false
		visibleCount = 0
		local farSquared = render.farDistance * render.farDistance
		for _, pod in pods do
			if pod.visible and pod.rangeSquared > farSquared and (stepCount + pod.index) % render.farInterval ~= 0 then
				visibleCount += 1 -- a far pod's off frame: it stays where it was drawn
			elseif pod.visible or renderAll or clock >= pod.nextCheck then
				updatePod(pod, now, clock, origin)
			end
		end
	end
	stepCount += 1
	stepTimes[(stepCount - 1) % render.statRing + 1] = (os.clock() - clock) * MS_PER_SECOND
end

-- Stats and the Studio bridge -------------------------------------------------------------------------------------

local function statsHere(): Stats
	local podStats: { PodStats } = {}
	local withRoutes = 0
	for index, pod in pods do
		if #pod.routes > 0 then
			withRoutes += 1
		end
		table.insert(podStats, {
			index = index,
			seq = pod.seq,
			distance = pod.distance,
			length = pod.length,
			speed = pod.speed,
			delay = pod.delay,
			yielding = pod.yielding,
			waiting = pod.waiting,
			visible = pod.visible,
			routes = #pod.routes,
		})
	end
	table.sort(podStats, function(a, b)
		return a.index < b.index
	end)
	local kept = math.min(stepCount, render.statRing)
	local times: { number } = table.create(kept)
	for back = kept - 1, 0, -1 do
		table.insert(times, stepTimes[(stepCount - 1 - back) % render.statRing + 1])
	end
	return {
		pods = withRoutes,
		visible = visibleCount,
		steps = stepCount,
		stepTimes = times,
		podStats = podStats,
		renderAll = renderAll,
	}
end

local function setRenderAllHere(on: boolean)
	renderAll = RunService:IsStudio() and on == true
end

local COMMANDS: { [string]: (...any) -> ...any } = {
	stats = statsHere,
	setRenderAll = setRenderAllHere,
}

-- Runs `command` here, or in the running copy when this one isn't it and a bridge is up (Studio only).
local function dispatch(command: string, ...: any): ...any
	if not isHost and RunService:IsStudio() then
		local bridge = script:FindFirstChild(BRIDGE_NAME)
		if bridge and bridge:IsA("BindableFunction") then
			return bridge:Invoke(command, ...)
		end
	end
	return COMMANDS[command](...)
end

local function serve()
	local old = script:FindFirstChild(BRIDGE_NAME)
	if old then
		old:Destroy()
	end
	local bridge = Instance.new("BindableFunction")
	bridge.Name = BRIDGE_NAME
	bridge.OnInvoke = function(command: string, ...: any): ...any
		local handler = COMMANDS[command]
		if handler == nil then
			error(`TrafficController: unknown command "{command}"`)
		end
		return handler(...)
	end
	bridge.Parent = script
end

-- Every pod's state, how many are drawn, and recent step times (see Stats).
function TrafficController.stats(): Stats
	return dispatch("stats")
end

-- Studio only: draw every pod wherever the camera is (Dev/TrafficTests measures the frame cost that way).
function TrafficController.setRenderAll(on: boolean)
	if RunService:IsStudio() then
		dispatch("setRenderAll", on)
	end
end

function TrafficController:Start()
	isHost = true
	local drawn = Instance.new("Folder")
	drawn.Name = render.folderName
	drawn.Parent = Workspace
	folder = drawn
	task.spawn(resolveModel)

	CollectionService:GetInstanceAddedSignal(Spawning.vehicleTag):Connect(trackCar)
	CollectionService:GetInstanceRemovedSignal(Spawning.vehicleTag):Connect(untrackCar)
	for _, instance in CollectionService:GetTagged(Spawning.vehicleTag) do
		trackCar(instance)
	end

	Net.onClientEvent(REMOTE, onRoutes)
	RunService.RenderStepped:Connect(step)
	if RunService:IsStudio() then
		serve()
	end
end

return TrafficController
