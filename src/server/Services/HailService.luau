--!strict
-- Hail a pod: fast travel to a GPS destination (PLAN.md Phase 9; docs/phase-9-contracts.md "Hail a pod").
--
--   HailPod     Net function { destinationId }: a MapLayout location with gps = true. Refused unless the player
--               is alive, on foot (not sitting in any seat), not on a job (JobService.hasActiveJob), not already
--               riding and off cooldown. The server routes from the character to the destination with the shared
--               Pathfind, prices the ride with Config/Hail fareFor (base + per stud of road; a place closer than
--               Hail.minStuds is refused as "already there") and charges it with EconomyService.trySpend (reason
--               "hail"). Replies { ok, message, fare?, seconds? } (seconds from Config/Hail secondsFor, kept within
--               minSeconds..maxSeconds).
--   the ride    Net HailRide { from, to, seconds, route } goes to the rider: from = where the route joins the road,
--               to = where they will be let off, route = the Pathfind polyline cut to Hail.routeMaxPoints (thinRoute)
--               for the client's cutscene (Controllers/HailController). Meanwhile the character's root part is
--               anchored where it stands, so it can't wander off or be pushed. After `seconds` (one task.delay) the
--               character is stood on the destination's side of the road nearest it (the middle of the sidewalk,
--               or the shoulder of a road with none), facing the place, with character:PivotTo, then let go.
--   streaming   the place streams instances (default.project.json StreamingEnabled) and the rider's root stays at
--               the pickup during the ride, so the area around the drop-off isn't sent to their client by itself: the ride
--               asks for it at once (Player:RequestStreamAroundAsync, one task.spawn), and at arrival the rider is
--               held, anchored, until it is in, for at most Hail.dropOff.streamWaitSeconds, so they can't fall
--               through ground that hasn't loaded. They have arrived by then: nothing is refunded during that wait.
--   refunds     the fare comes back (EconomyService.add, reason "refund"), with a notice, and no cooldown starts,
--               when mid-ride the character dies, is replaced, sits down, or is gone at arrival time; and when the
--               player leaves or the server closes (DataService.beforeRelease, so the refund is saved).
--   cooldown    Hail.cooldownSeconds from the moment a ride ends at its destination.
--
-- AntiExploitService watches cars only, so moving a character here needs no allowTeleport. Server-authoritative
-- (CLAUDE.md hard rule 1): the client only names a place; the server decides the route, the fare, the ride time
-- and where the character ends up. No polling: one task.delay per ride plus the character's own events.
--
-- The decisions are pure helpers for tests/Hail.spec: eligibility, thinRoute and sideOffset.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local Economy = require(Shared.Config.Economy)
local Graph = require(Shared.Road.Graph)
local Hail = require(Shared.Config.Hail)
local MapLayout = require(Shared.Config.MapLayout)
local Net = require(Shared.Net)
local Pathfind = require(Shared.Road.Pathfind)
local RoadGraph = require(Shared.Config.RoadGraph)
local Spawning = require(Shared.Config.Spawning)

-- The services this one calls are required in Init rather than here, so tests/Hail.spec can require this module
-- in Edit mode for its pure helpers without loading DataService (ProfileStore talks to DataStores at once).
type DataServiceModule = typeof(require(script.Parent.DataService))
type EconomyServiceModule = typeof(require(script.Parent.EconomyService))
type JobServiceModule = typeof(require(script.Parent.JobService))

-- Why a hail is refused before any route is made (nil: it may go ahead).
export type Reason = "riding" | "notReady" | "onFoot" | "inJob" | "cooldown"

-- What eligibility looks at. cooldownLeft is in seconds (0 or less: none).
export type Status = {
	riding: boolean, -- a ride of theirs is already under way
	alive: boolean, -- a character with a living Humanoid and a root part
	onFoot: boolean, -- not sitting in any seat
	inJob: boolean,
	cooldownLeft: number,
}

export type Reply = { ok: boolean, message: string, fare: number?, seconds: number? }

-- One ride under way.
type Ride = {
	player: Player,
	character: Model,
	humanoid: Humanoid,
	root: BasePart,
	fare: number,
	place: string, -- the destination's display name
	ground: Vector3, -- where the rider is let off, on the surface
	facing: Vector3, -- the way they face there
	wasAnchored: boolean, -- the root part's Anchored before the ride
	connections: { RBXScriptConnection },
	timer: thread?, -- the arrival delay, then (after arrival) the longest wait for the drop-off to stream in
	streamed: boolean, -- the stream request around the drop-off has finished (or failed)
	arrived: boolean, -- stood at the destination: the ride is paid for and can no longer be refunded
}

local REMOTE = "HailPod"
local RIDE_EVENT = "HailRide"
local VEHICLES_FOLDER = Spawning.vehiclesFolder
local MIN_DIRECTION = 1e-3 -- horizontal vectors shorter than this (studs) have no usable direction

local HailService = {}

local DataService: DataServiceModule? = nil
local EconomyService: EconomyServiceModule? = nil
local JobService: JobServiceModule? = nil

local rides: { [Player]: Ride } = {}
local cooldownUntil: { [Player]: number } = {} -- os.clock() when each player may hail again

-- Every GPS destination by id (MapLayout locations with gps = true).
local destinations: { [string]: MapLayout.Location } = {}
for _, location in MapLayout.locations do
	if location.gps then
		destinations[location.id] = location
	end
end

-- Pure helpers ----------------------------------------------------------------------------------------------

-- Why a hail can't go ahead, checked in this order (nil: it can): already riding, no living character, sitting
-- in a seat (a car), on a job, on cooldown.
function HailService.eligibility(status: Status): Reason?
	if status.riding then
		return "riding"
	elseif not status.alive then
		return "notReady"
	elseif not status.onFoot then
		return "onFoot"
	elseif status.inJob then
		return "inJob"
	elseif status.cooldownLeft > 0 then
		return "cooldown"
	end
	return nil
end

-- At most `maxPoints` (at least 2) of a route's points, for the HailRide payload: the first and the last always,
-- the first half of the budget as they are (the cutscene glides along the start of the route), then evenly
-- spaced picks from the rest, in order. A route that already fits comes back as a copy.
function HailService.thinRoute(points: { Vector3 }, maxPoints: number): { Vector3 }
	local count = #points
	local budget = math.max(math.floor(maxPoints), 2)
	if count <= budget then
		return table.clone(points)
	end
	local head = budget // 2
	local thinned: { Vector3 } = table.create(budget)
	table.move(points, 1, head, 1, thinned)
	-- `slots` picks from points[head + 1 .. count - 1]; there are more of those than slots, so the picks never repeat.
	local slots = budget - head - 1
	local restCount = count - 1 - head
	for i = 1, slots do
		table.insert(thinned, points[head + 1 + math.floor((i - 1) * restCount / slots)])
	end
	table.insert(thinned, points[count])
	return thinned
end

-- How far from a road's centre line (studs) a rider is let off: the middle of the sidewalk, or on a road with no
-- sidewalk, on the shoulder Hail.dropOff.shoulderInset in from the road's edge. `roadWidth` is the carriageway
-- with its shoulders (Graph.edgeWidth); sidewalks are outside it.
function HailService.sideOffset(roadWidth: number, sidewalk: number): number
	local half = math.max(roadWidth, 0) / 2
	if sidewalk > 0 then
		return half + sidewalk / 2
	end
	return math.max(half - Hail.dropOff.shoulderInset, 0)
end

-- Where riders are let off --------------------------------------------------------------------------------------

local function flat(vector: Vector3): Vector3
	return Vector3.new(vector.X, 0, vector.Z)
end

-- Everything a ray for the ground should pass through: players' characters and spawned cars.
local function groundParams(): RaycastParams
	local ignore: { Instance } = {}
	for _, other in Players:GetPlayers() do
		if other.Character ~= nil then
			table.insert(ignore, other.Character)
		end
	end
	local vehicles = Workspace:FindFirstChild(VEHICLES_FOLDER)
	if vehicles ~= nil then
		table.insert(ignore, vehicles)
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = ignore
	return params
end

-- Where a rider bound for a place at `target` is let off: the road nearest it, out to the place's side by
-- sideOffset (the right-hand side looking along the road when the place is on the road itself), on whatever
-- surface is there. Returns that ground point and the horizontal direction to face (toward the place).
local function dropSpot(target: Vector3): (Vector3, Vector3)
	local edge, t, _, point = Graph.nearestEdge(target)
	if edge == nil then
		return target, -Vector3.zAxis
	end
	local drop = Hail.dropOff
	local length = Graph.edgeLength(edge)
	local step = if length > 0 then drop.headingStuds / length else 0
	local along = flat(Graph.pointOnEdge(edge, t + step) - Graph.pointOnEdge(edge, t - step))
	local outward = flat(target - point)
	if outward.Magnitude < MIN_DIRECTION then
		outward = if along.Magnitude >= MIN_DIRECTION then along:Cross(Vector3.yAxis) else Vector3.xAxis
	end
	outward = outward.Unit

	local style = RoadGraph.styles[Graph.edges()[edge].kind]
	local sidewalk = if style ~= nil then style.sidewalk else 0
	local spot = point + outward * HailService.sideOffset(Graph.edgeWidth(edge), sidewalk)
	local origin = spot + Vector3.yAxis * drop.probeUp
	local hit = Workspace:Raycast(origin, Vector3.yAxis * -(drop.probeUp + drop.probeDown), groundParams())
	local ground = if hit ~= nil then hit.Position else spot

	local facing = flat(target - ground)
	if facing.Magnitude < MIN_DIRECTION then
		facing = if along.Magnitude >= MIN_DIRECTION then along else outward
	end
	return ground, facing.Unit
end

-- Stands a character on `ground`, feet down, facing `facing` (like VehicleService's step out of a car).
local function standAt(character: Model, humanoid: Humanoid, root: BasePart, ground: Vector3, facing: Vector3)
	local exit = Spawning.exit
	local legs = if humanoid.RigType == Enum.HumanoidRigType.R6 then exit.r6LegHeight else humanoid.HipHeight
	local stand = ground + Vector3.yAxis * (legs + root.Size.Y / 2 + exit.clearance)
	local rootPose = CFrame.lookAt(stand, stand + facing)
	character:PivotTo(rootPose * root.CFrame:ToObjectSpace(character:GetPivot()))
end

-- Rides -------------------------------------------------------------------------------------------------------

local function notify(player: Player, text: string, kind: string)
	if player.Parent == Players then
		Net.fireClient("Notify", player, { text = text, kind = kind })
	end
end

local function reply(ok: boolean, message: string): Reply
	return { ok = ok, message = message }
end

-- The player's character, its living Humanoid and its root part, or nils.
local function aliveCharacter(player: Player): (Model?, Humanoid?, BasePart?)
	local character = player.Character
	if character == nil then
		return nil, nil, nil
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local root = character:FindFirstChild("HumanoidRootPart")
	if humanoid == nil or humanoid.Health <= 0 or root == nil or not root:IsA("BasePart") then
		return nil, nil, nil
	end
	return character, humanoid, root
end

-- Ends a ride's hold on the character: listeners, the arrival timer and the anchor. The character is handed back
-- to the player's client for physics.
local function release(ride: Ride)
	if rides[ride.player] == ride then
		rides[ride.player] = nil
	end
	for _, connection in ride.connections do
		connection:Disconnect()
	end
	table.clear(ride.connections)
	local timer = ride.timer
	ride.timer = nil
	if timer ~= nil and timer ~= coroutine.running() and coroutine.status(timer) == "suspended" then
		task.cancel(timer)
	end
	local root = ride.root
	if root.Parent ~= nil then
		root.Anchored = ride.wasAnchored
		if not root.Anchored and root:IsDescendantOf(Workspace) then
			pcall(function()
				if root:CanSetNetworkOwnership() then
					root:SetNetworkOwner(ride.player)
				end
			end)
		end
	end
end

-- Calls a ride off and gives the fare back. `tell` says whether to send the rider a notice (not while they leave).
local function cancel(ride: Ride, tell: boolean)
	if rides[ride.player] ~= ride then
		return -- already over
	end
	release(ride)
	if ride.arrived then
		return -- already let off at the destination (only waiting for the ground there): nothing to give back
	end
	local economy = EconomyService
	local refunded = economy ~= nil and economy.add(ride.player, ride.fare, Hail.refundReason)
	if not refunded then
		warn(`[HailService] Couldn't refund {ride.player.Name}'s {ride.fare} ride fare`)
	end
	if tell and refunded then
		notify(ride.player, string.format(Hail.messages.refunded, Economy.formatCash(ride.fare)), "info")
	end
end

-- The ride's time is up: stand the rider at the destination, or refund them if their character can't go.
local function arrive(ride: Ride)
	if rides[ride.player] ~= ride then
		return
	end
	local player = ride.player
	local character, humanoid, root = aliveCharacter(player)
	if
		character ~= ride.character
		or humanoid ~= ride.humanoid
		or root ~= ride.root
		or ride.humanoid.SeatPart ~= nil
	then
		cancel(ride, true)
		return
	end
	-- Move while still anchored, so the rider's client can't fight the move.
	standAt(ride.character, ride.humanoid, ride.root, ride.ground, ride.facing)
	ride.arrived = true
	cooldownUntil[player] = os.clock() + Hail.cooldownSeconds
	notify(player, string.format(Hail.messages.arrived, ride.place), "success")
	if ride.streamed then
		release(ride)
	else
		-- The ground there may not have reached the rider's client yet: keep them anchored until it has
		-- (streamDropOff lets go), or for at most streamWaitSeconds.
		ride.timer = task.delay(Hail.dropOff.streamWaitSeconds, release, ride)
	end
end

-- Asks for the area around the drop-off point to be sent to the rider's client (Player:RequestStreamAroundAsync
-- yields until it is in or the time runs out), then lets go of a rider who has already arrived and was waiting.
local function streamDropOff(ride: Ride, seconds: number)
	local player = ride.player
	local ok, err = pcall(function()
		player:RequestStreamAroundAsync(ride.ground, seconds + Hail.dropOff.streamWaitSeconds)
	end)
	if not ok and player.Parent == Players then
		warn(`[HailService] Couldn't stream the drop-off point for {player.Name}: {err}`)
	end
	ride.streamed = true
	if ride.arrived and rides[player] == ride then
		release(ride)
	end
end

-- Takes hold of the character for a paid ride and starts its clock.
local function beginRide(
	player: Player,
	character: Model,
	humanoid: Humanoid,
	root: BasePart,
	fare: number,
	location: MapLayout.Location,
	ground: Vector3,
	facing: Vector3,
	seconds: number
): Ride
	local ride: Ride = {
		player = player,
		character = character,
		humanoid = humanoid,
		root = root,
		fare = fare,
		place = location.displayName,
		ground = ground,
		facing = facing,
		wasAnchored = root.Anchored,
		connections = {},
		timer = nil,
		streamed = false,
		arrived = false,
	}
	rides[player] = ride
	root.Anchored = true
	task.spawn(streamDropOff, ride, seconds)
	table.insert(
		ride.connections,
		humanoid.Died:Connect(function()
			cancel(ride, true)
		end)
	)
	table.insert(
		ride.connections,
		humanoid.Seated:Connect(function(active: boolean)
			if active then
				cancel(ride, true)
			end
		end)
	)
	table.insert(
		ride.connections,
		player.CharacterRemoving:Connect(function()
			cancel(ride, true)
		end)
	)
	ride.timer = task.delay(seconds, arrive, ride)
	return ride
end

local function refusal(reason: Reason, cooldownLeft: number): string
	local messages = Hail.messages
	if reason == "cooldown" then
		return string.format(messages.cooldown, math.max(math.ceil(cooldownLeft), 1))
	elseif reason == "riding" then
		return messages.riding
	elseif reason == "onFoot" then
		return messages.onFoot
	elseif reason == "inJob" then
		return messages.inJob
	end
	return messages.notReady
end

local function onHailPod(player: Player, payload: any): Reply
	local messages = Hail.messages
	local location = destinations[payload.destinationId]
	if location == nil then
		return reply(false, messages.unknownPlace)
	end

	local character, humanoid, root = aliveCharacter(player)
	local jobService = JobService
	local cooldownLeft = (cooldownUntil[player] or 0) - os.clock()
	local reason = HailService.eligibility({
		riding = rides[player] ~= nil,
		alive = character ~= nil,
		onFoot = humanoid ~= nil and humanoid.SeatPart == nil,
		inJob = jobService ~= nil and jobService.hasActiveJob(player),
		cooldownLeft = cooldownLeft,
	})
	if reason ~= nil then
		return reply(false, refusal(reason, cooldownLeft))
	end
	if character == nil or humanoid == nil or root == nil then
		return reply(false, messages.notReady)
	end

	local target = location.gpsTarget or location.position
	local routed, route = pcall(Pathfind.route, root.Position, target)
	if not routed then
		warn(`[HailService] Pathfind.route failed: {route}`)
		return reply(false, messages.failed)
	end
	if route == nil or #route.points == 0 then
		return reply(false, string.format(messages.noRoute, location.displayName))
	end
	if route.length < Hail.minStuds then
		return reply(false, string.format(messages.alreadyThere, location.displayName))
	end

	local fare = Hail.fareFor(route.length)
	local seconds = Hail.secondsFor(route.length)
	local economy = EconomyService
	if economy == nil then
		return reply(false, messages.failed)
	end
	local ground, facing = dropSpot(target)
	if not economy.trySpend(player, fare, Hail.economyReason) then
		return reply(false, string.format(messages.cantAfford, Economy.formatCash(fare)))
	end

	beginRide(player, character, humanoid, root, fare, location, ground, facing, seconds)
	Net.fireClient(RIDE_EVENT, player, {
		from = route.points[1],
		to = ground,
		seconds = seconds,
		route = HailService.thinRoute(route.points, Hail.routeMaxPoints),
	})
	return {
		ok = true,
		message = string.format(messages.onTheWay, Economy.formatCash(fare)),
		fare = fare,
		seconds = seconds,
	}
end

-- Boot ------------------------------------------------------------------------------------------------------

function HailService:Init()
	DataService = require(script.Parent.DataService)
	EconomyService = require(script.Parent.EconomyService)
	-- JobService only answers "is this player on a job": a broken JobService must not take hailing down with it.
	local ok, result = pcall(require :: any, script.Parent.JobService)
	if ok then
		JobService = result :: any
	else
		warn(`[HailService] JobService didn't load, so hailing won't check for jobs: {result}`)
	end
end

function HailService:Start()
	Net.onServerInvoke(REMOTE, onHailPod)
	-- A rider who leaves (or a server that closes) mid-ride gets the fare back while their data can still be saved.
	local dataService = DataService
	if dataService ~= nil then
		dataService.beforeRelease(function(player: Player)
			local ride = rides[player]
			if ride ~= nil then
				cancel(ride, false)
			end
		end)
	end
	Players.PlayerRemoving:Connect(function(player: Player)
		local ride = rides[player]
		if ride ~= nil then
			-- Only when this runs before DataService's own PlayerRemoving (beforeRelease ends the ride otherwise):
			-- the data is still loaded, so the refund still saves.
			cancel(ride, false)
		end
		cooldownUntil[player] = nil
	end)
end

return HailService
