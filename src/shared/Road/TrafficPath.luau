--!strict
-- Ambient pod routes as pure math (docs/phase-9-contracts.md "Ambient pods = ambient traffic"). Shared by
-- Services/TrafficService (when a route ends), Controllers/TrafficController (where to draw each pod),
-- Dev/TrafficTests and tests/Traffic.spec; no instances, no clocks.
--
--   Polylines  fromPoints(points) measures a polyline once. positionAt and directionAt give the point and the heading
--              at a distance along it; pass back the segment they returned as the next call's hint and a frame's
--              lookup is O(1) (without one it is a binary search).
--   Lanes      laneLine(points, offset, sharpDot, speeds, lead) moves a centre line sideways into the right-hand
--              lane: mitred at bends, and straight across to the other side at a U-turn. `lead`, the direction a pod
--              arrived from, starts the line exactly where the pod's previous route ended.
--   Profiles   profile(path, cruise, settings) plans the speed along a path: a rest of settings.dwell, then from a
--              standstill at no more than each segment's cruise speed, slower through bends (a bend's speed comes
--              from its angle and the room either side of it, with settings.lateralAccel), speeding up and slowing
--              down at fixed rates, to a standstill at the end. distanceAt(profile, t) is how far along the path the
--              pod is t seconds after its route starts, and its speed then.
--   Routes     plan(graph, nodes, scale, lead) builds a pod's whole route from graph node indices (Graph.nodes()
--              order): the lane line along the nodes, each road's cruise speed (Config/Traffic speed.byKind x its
--              limit x the route's speed scale) and the profile. The server and every client build the same route
--              from the same record, so they agree on where every pod is at every server time.
--   Payload    encode(records) and decode(data) pack route records into the Net TrafficRoutes buffer: a format
--              byte and a record count, then per record the pod (u8), its route number (u32), the start time
--              (f64, workspace:GetServerTimeNow()), the speed scale in thousandths (u16), the lead node (u16, 0 = none),
--              the node count (u16) and the node indices (u16 each): 19 + 2 per node bytes.
--
-- Directions are horizontal unless said otherwise; "right" is the direction of travel crossed with +Y (heading
-- north, -Z, it is east, +X). Pods drive on the right.

local Config = script.Parent.Parent.Config
local Graph = require(script.Parent.Graph)
local Traffic = require(Config.Traffic)
local Units = require(script.Parent.Parent.Util.Units)
local World = require(Config.World)

export type Path = {
	points: { Vector3 },
	along: { number }, -- studs from the first point to each point
	length: number,
}

export type ProfileSettings = {
	accel: number, -- studs/s², speeding up
	decel: number, -- studs/s², slowing down
	lateralAccel: number, -- studs/s² of cornering allowed in a bend
	cornerSpan: number, -- studs: a bend starts at most this far before its point and ends as far after it
	minCornerSpeed: number, -- studs/s: the slowest any bend is taken, and the slowest any segment is cruised
	dwell: number, -- seconds at rest at the start before moving off
}

-- Segment i runs from path point i to point i + 1. On it the pod speeds up from entrySpeed to peakSpeed (accelTime
-- seconds, accelDistance studs), holds peakSpeed (cruiseTime, cruiseDistance), then slows to exitSpeed (brakeTime).
export type Profile = {
	dwell: number,
	duration: number, -- seconds from the route's start to arriving at rest at its end (dwell included)
	length: number, -- studs
	accel: number,
	decel: number,
	startTime: { number }, -- seconds from the route's start that the pod enters each segment (dwell included)
	startDistance: { number },
	entrySpeed: { number },
	peakSpeed: { number },
	exitSpeed: { number },
	accelTime: { number },
	cruiseTime: { number },
	brakeTime: { number },
	accelDistance: { number },
	cruiseDistance: { number },
}

export type Plan = {
	nodes: { number }, -- graph node indices, start to end
	lead: number, -- the node the pod came from into nodes[1] (0 = none)
	scale: number,
	path: Path, -- the lane line
	profile: Profile,
	length: number, -- studs along the lane line
	duration: number, -- seconds, dwell included
}

-- One route as the server publishes it.
export type Record = {
	pod: number, -- 1..255
	seq: number, -- the pod's route number, 0..2^32 - 1 (it wraps)
	startAt: number, -- server time (workspace:GetServerTimeNow()) the route starts: the dwell begins then
	scale: number, -- speed scale, a whole number of thousandths (quantizeScale)
	lead: number, -- graph node index the pod came from into nodes[1] (0 = none: the pod's first route)
	nodes: { number }, -- graph node indices (Graph.nodes() order), start to end, at least two
}

local SAME_POINT = 1e-3 -- studs: points closer than this are one point
local STRAIGHT = 1e-4 -- radians: a bend gentler than this doesn't slow a pod
local STANDARD_GRAVITY = 9.80665 -- m/s², to turn Config/Traffic's g figures into studs/s²
local UP = Vector3.yAxis
local NORTH = Vector3.new(0, 0, -1) -- the heading of a path with no length

local FORMAT = 1
local HEADER_BYTES = 2 -- format, record count
local RECORD_BYTES = 19 -- pod u8, seq u32, startAt f64, scale u16, lead u16, node count u16
local SCALE_STEPS = 1000 -- the speed scale travels in thousandths
local MAX_U8 = 255
local MAX_U16 = 65535
local MAX_U32 = 4294967295

local TrafficPath = {}

-- Helpers --------------------------------------------------------------------------------------------------------

-- The horizontal unit vector along `v`, or nil when `v` is (nearly) vertical or zero.
local function flatUnit(v: Vector3): Vector3?
	local x, z = v.X, v.Z
	local size = math.sqrt(x * x + z * z)
	if size < SAME_POINT then
		return nil
	end
	return Vector3.new(x / size, 0, z / size)
end

local function rightOf(direction: Vector3): Vector3
	return direction:Cross(UP)
end

-- The last index i in 1..last with values[i] <= x (values never decrease), or 1. With a hint (the answer for a
-- nearby x), it walks from there; without one, it bisects.
local function indexAt(values: { number }, last: number, x: number, hint: number?): number
	if last <= 1 then
		return 1
	end
	if hint == nil then
		local low, high = 1, last
		while low < high do
			local middle = (low + high + 1) // 2
			if values[middle] <= x then
				low = middle
			else
				high = middle - 1
			end
		end
		return low
	end
	local i = math.clamp(hint, 1, last)
	while i < last and values[i + 1] <= x do
		i += 1
	end
	while i > 1 and values[i] > x do
		i -= 1
	end
	return i
end

-- Polylines ------------------------------------------------------------------------------------------------------

-- Measures a polyline (at least one point). The points are kept, not copied.
function TrafficPath.fromPoints(points: { Vector3 }): Path
	assert(#points >= 1, "TrafficPath.fromPoints needs at least one point")
	local along: { number } = table.create(#points, 0)
	local total = 0
	for i = 2, #points do
		total += (points[i] - points[i - 1]).Magnitude
		along[i] = total
	end
	return { points = points, along = along, length = total }
end

-- The point `distance` studs along the path (clamped to it), and the segment it is on (pass it back as `hint`).
function TrafficPath.positionAt(path: Path, distance: number, hint: number?): (Vector3, number)
	local points, along = path.points, path.along
	if #points < 2 then
		return points[1], 1
	end
	local d = math.clamp(distance, 0, path.length)
	local i = indexAt(along, #points - 1, d, hint)
	local span = along[i + 1] - along[i]
	local fraction = if span > 0 then math.clamp((d - along[i]) / span, 0, 1) else 1
	return points[i]:Lerp(points[i + 1], fraction), i
end

-- The heading (a unit vector, with any climb in it) at `distance`: from `span` studs behind it to `span` ahead,
-- so it turns smoothly through a bend instead of snapping at the bend's point.
function TrafficPath.directionAt(path: Path, distance: number, span: number, hint: number?): Vector3
	local points = path.points
	if #points < 2 then
		return NORTH
	end
	local behind = TrafficPath.positionAt(path, distance - span, hint)
	local ahead = TrafficPath.positionAt(path, distance + span, hint)
	local delta = ahead - behind
	if delta.Magnitude >= SAME_POINT then
		return delta.Unit
	end
	local _, i = TrafficPath.positionAt(path, distance, hint)
	local segment = points[i + 1] - points[i]
	return if segment.Magnitude >= SAME_POINT then segment.Unit else NORTH
end

-- Lanes ----------------------------------------------------------------------------------------------------------

-- Moves a centre line `offset` studs to the right of its direction of travel, keeping each point's height.
-- `speeds` has one value per segment of `points`; the result has one per segment of the new line (a crossing at a
-- U-turn takes the slower of the two roads). Where the line turns back harder than `sharpDot` (the cosine of the
-- angle between the two directions) it gets two points, one each side of the road; elsewhere one mitred point.
-- `lead` is the direction the pod arrived at points[1] from: the line then starts where a line along that
-- direction ended (offset to its right), crossing over first if the turn from it is sharp. Points that would come
-- out on top of the previous one are dropped with their segment.
function TrafficPath.laneLine(
	points: { Vector3 },
	offset: number,
	sharpDot: number,
	speeds: { number },
	lead: Vector3?
): ({ Vector3 }, { number })
	local out: { Vector3 } = {}
	local outSpeeds: { number } = {}
	local count = #points
	if count == 0 then
		return out, outSpeeds
	end

	local function add(point: Vector3, speed: number)
		if #out > 0 and (point - out[#out]).Magnitude < SAME_POINT then
			return
		end
		table.insert(out, point)
		if #out > 1 then
			table.insert(outSpeeds, speed)
		end
	end

	local leadDirection = if lead then flatUnit(lead) else nil
	-- Each segment's direction; a vertical one (never on a road) borrows the one before it.
	local directions: { Vector3 } = table.create(math.max(count - 1, 0))
	local previous = leadDirection or NORTH
	for i = 1, count - 1 do
		local direction = flatUnit(points[i + 1] - points[i]) or previous
		directions[i] = direction
		previous = direction
	end
	if count == 1 then
		add(points[1] + rightOf(leadDirection or NORTH) * offset, 0)
		return out, outSpeeds
	end

	if leadDirection then
		add(points[1] + rightOf(leadDirection) * offset, 0)
		if leadDirection:Dot(directions[1]) < sharpDot then
			add(points[1] + rightOf(directions[1]) * offset, speeds[1])
		end
	else
		add(points[1] + rightOf(directions[1]) * offset, 0)
	end
	for i = 2, count - 1 do
		local before, after = directions[i - 1], directions[i]
		local rightBefore, rightAfter = rightOf(before), rightOf(after)
		if before:Dot(after) < sharpDot then
			add(points[i] + rightBefore * offset, speeds[i - 1])
			add(points[i] + rightAfter * offset, math.min(speeds[i - 1], speeds[i]))
		else
			-- The mitre: halfway between the two right vectors, pushed out so both lanes keep their width.
			local mitre = (rightBefore + rightAfter).Unit
			add(points[i] + mitre * (offset / mitre:Dot(rightBefore)), speeds[i - 1])
		end
	end
	add(points[count] + rightOf(directions[count - 1]) * offset, speeds[count - 1])
	return out, outSpeeds
end

-- Profiles -------------------------------------------------------------------------------------------------------

local function settingsFromConfig(): ProfileSettings
	local speed = Traffic.speed
	local g = STANDARD_GRAVITY / World.metersPerStud
	return {
		accel = speed.accelG * g,
		decel = speed.decelG * g,
		lateralAccel = speed.lateralG * g,
		cornerSpan = speed.cornerSpan,
		minCornerSpeed = Units.mphToStuds(speed.minCornerMph),
		dwell = Traffic.route.dwellSeconds,
	}
end

local DEFAULT_SETTINGS = settingsFromConfig()

-- Config/Traffic's profile settings in studs and seconds (a copy).
function TrafficPath.settings(): ProfileSettings
	return table.clone(DEFAULT_SETTINGS)
end

-- Plans the speed along `path`. `cruise` has each segment's cruise speed (studs/s); a segment is never cruised
-- slower than settings.minCornerSpeed.
function TrafficPath.profile(path: Path, cruise: { number }, settings: ProfileSettings): Profile
	local points, along = path.points, path.along
	local segments = math.max(#points - 1, 0)
	local accel, decel = settings.accel, settings.decel
	local profile: Profile = {
		dwell = settings.dwell,
		duration = settings.dwell,
		length = path.length,
		accel = accel,
		decel = decel,
		startTime = table.create(segments, 0),
		startDistance = table.create(segments, 0),
		entrySpeed = table.create(segments, 0),
		peakSpeed = table.create(segments, 0),
		exitSpeed = table.create(segments, 0),
		accelTime = table.create(segments, 0),
		cruiseTime = table.create(segments, 0),
		brakeTime = table.create(segments, 0),
		accelDistance = table.create(segments, 0),
		cruiseDistance = table.create(segments, 0),
	}
	if segments == 0 then
		return profile
	end

	local cruiseOf: { number } = table.create(segments, 0)
	for i = 1, segments do
		cruiseOf[i] = math.max(cruise[i] or 0, settings.minCornerSpeed)
	end

	-- The fastest a pod may pass each point: at rest at both ends, no faster than either road at a node, and no
	-- faster than its bend allows. A bend of angle a with room r either side is an arc of radius r / tan(a / 2).
	local limit: { number } = table.create(segments + 1, 0)
	for i = 2, segments do
		local cap = math.min(cruiseOf[i - 1], cruiseOf[i])
		local before = flatUnit(points[i] - points[i - 1])
		local after = flatUnit(points[i + 1] - points[i])
		if before and after then
			local angle = math.acos(math.clamp(before:Dot(after), -1, 1))
			if angle > STRAIGHT then
				local room = math.min((along[i] - along[i - 1]) / 2, (along[i + 1] - along[i]) / 2, settings.cornerSpan)
				local radius = room / math.tan(angle / 2)
				cap = math.min(cap, math.max(math.sqrt(settings.lateralAccel * radius), settings.minCornerSpeed))
			end
		end
		limit[i] = cap
	end
	-- Then what speeding up from the point before and slowing for the point after allow.
	for i = 2, segments + 1 do
		local reach = math.sqrt(limit[i - 1] * limit[i - 1] + 2 * accel * (along[i] - along[i - 1]))
		limit[i] = math.min(limit[i], reach)
	end
	for i = segments, 1, -1 do
		local reach = math.sqrt(limit[i + 1] * limit[i + 1] + 2 * decel * (along[i + 1] - along[i]))
		limit[i] = math.min(limit[i], reach)
	end

	-- Each segment: speed up toward its cruise speed, hold it, slow for its end. The peak is where the speeding-up
	-- and slowing-down curves meet, unless the cruise speed caps it first.
	local time = settings.dwell
	for i = 1, segments do
		local length = along[i + 1] - along[i]
		local entry, exit = limit[i], limit[i + 1]
		local meet =
			math.sqrt((2 * accel * decel * length + decel * entry * entry + accel * exit * exit) / (accel + decel))
		local peak = math.max(math.min(meet, cruiseOf[i]), entry, exit)
		local accelDistance = (peak * peak - entry * entry) / (2 * accel)
		local brakeDistance = (peak * peak - exit * exit) / (2 * decel)
		local cruiseDistance = math.max(length - accelDistance - brakeDistance, 0)
		local accelTime = (peak - entry) / accel
		local brakeTime = (peak - exit) / decel
		local cruiseTime = if peak > 0 then cruiseDistance / peak else 0

		profile.startTime[i] = time
		profile.startDistance[i] = along[i]
		profile.entrySpeed[i] = entry
		profile.peakSpeed[i] = peak
		profile.exitSpeed[i] = exit
		profile.accelTime[i] = accelTime
		profile.cruiseTime[i] = cruiseTime
		profile.brakeTime[i] = brakeTime
		profile.accelDistance[i] = accelDistance
		profile.cruiseDistance[i] = cruiseDistance
		time += accelTime + cruiseTime + brakeTime
	end
	profile.duration = time
	return profile
end

-- How far along the path (studs) and how fast (studs/s) the pod is `t` seconds after its route starts, and the
-- segment it is on (pass it back as `hint`). At rest at 0 through the dwell, and at the end from `duration` on.
function TrafficPath.distanceAt(profile: Profile, t: number, hint: number?): (number, number, number)
	local starts = profile.startTime
	local segments = #starts
	if segments == 0 or t <= profile.dwell then
		return 0, 0, 1
	end
	if t >= profile.duration then
		return profile.length, 0, segments
	end
	local i = indexAt(starts, segments, t, hint)
	local tau = t - starts[i]
	local entry, peak = profile.entrySpeed[i], profile.peakSpeed[i]
	local accelTime, cruiseTime = profile.accelTime[i], profile.cruiseTime[i]
	local distance, speed
	if tau <= accelTime then
		distance = entry * tau + 0.5 * profile.accel * tau * tau
		speed = entry + profile.accel * tau
	elseif tau <= accelTime + cruiseTime then
		distance = profile.accelDistance[i] + peak * (tau - accelTime)
		speed = peak
	else
		local u = math.min(tau - accelTime - cruiseTime, profile.brakeTime[i])
		distance = profile.accelDistance[i] + profile.cruiseDistance[i] + peak * u - 0.5 * profile.decel * u * u
		speed = math.max(peak - profile.decel * u, 0)
	end
	return math.min(profile.startDistance[i] + distance, profile.length), speed, i
end

-- Routes ---------------------------------------------------------------------------------------------------------

-- The speed scale as it travels in a record: a whole number of thousandths. The server plans with this value so
-- its timing matches every client's to the bit.
function TrafficPath.quantizeScale(scale: number): number
	return math.floor(scale * SCALE_STEPS + 0.5) / SCALE_STEPS
end

-- A pod's cruise speed (studs/s) on a road: its kind's fraction of the limit, times the route's scale.
function TrafficPath.cruiseSpeed(edge: Graph.Edge, scale: number): number
	local fraction = Traffic.speed.byKind[edge.kind] or Traffic.speed.otherKinds
	return Units.mphToStuds(edge.speedLimitMph) * fraction * scale
end

-- The index of an edge joining two nodes (the first listed, when two do), or nil.
local function edgeBetween(graph: Graph.Api, fromId: string, toId: string): number?
	for _, neighbor in graph.neighbors(fromId) do
		if neighbor.node == toId then
			return neighbor.edge
		end
	end
	return nil
end

-- Builds a route from graph node indices: the lane line, each road's cruise speed and the profile. nil when the
-- nodes aren't a path on `graph` (two neighbours not joined by a road, an unknown index, fewer than two nodes).
function TrafficPath.plan(
	graph: Graph.Api,
	nodes: { number },
	scale: number,
	lead: number?,
	settings: ProfileSettings?
): Plan?
	local list = graph.nodes()
	local edges = graph.edges()
	local count = #nodes
	if count < 2 or not (scale > 0) then
		return nil
	end
	local centre: { Vector3 } = table.create(count)
	local cruise: { number } = table.create(count - 1)
	local previousId = ""
	for i, index in nodes do
		local node = list[index]
		if node == nil then
			return nil
		end
		centre[i] = node.position
		if i > 1 then
			local edgeIndex = edgeBetween(graph, previousId, node.id)
			if edgeIndex == nil then
				return nil
			end
			cruise[i - 1] = TrafficPath.cruiseSpeed(edges[edgeIndex], scale)
		end
		previousId = node.id
	end

	local leadIndex = lead or 0
	local leadDirection: Vector3? = nil
	if leadIndex ~= 0 then
		local from = list[leadIndex]
		if from == nil then
			return nil
		end
		leadDirection = centre[1] - from.position
	end

	local offset = Traffic.lane.offsetLanes * World.laneWidth
	local points, speeds = TrafficPath.laneLine(centre, offset, Traffic.lane.sharpTurnDot, cruise, leadDirection)
	local path = TrafficPath.fromPoints(points)
	local profile = TrafficPath.profile(path, speeds, settings or DEFAULT_SETTINGS)
	return {
		nodes = nodes,
		lead = leadIndex,
		scale = scale,
		path = path,
		profile = profile,
		length = path.length,
		duration = profile.duration,
	}
end

-- Payload --------------------------------------------------------------------------------------------------------

local function isWhole(value: number, low: number, high: number): boolean
	return value == math.floor(value) and value >= low and value <= high
end

-- Packs route records into one buffer (at most 255 records; split bigger sets). Errors on a record out of range.
function TrafficPath.encode(records: { Record }): buffer
	assert(#records <= MAX_U8, "TrafficPath.encode: at most 255 records per buffer")
	local size = HEADER_BYTES
	for _, record in records do
		size += RECORD_BYTES + 2 * #record.nodes
	end
	local data = buffer.create(size)
	buffer.writeu8(data, 0, FORMAT)
	buffer.writeu8(data, 1, #records)
	local at = HEADER_BYTES
	for _, record in records do
		local steps = math.floor(record.scale * SCALE_STEPS + 0.5)
		assert(isWhole(record.pod, 1, MAX_U8), "TrafficPath.encode: pod must be 1..255")
		assert(isWhole(record.seq, 0, MAX_U32), "TrafficPath.encode: seq must be a whole number under 2^32")
		assert(isWhole(steps, 1, MAX_U16), "TrafficPath.encode: scale out of range")
		assert(isWhole(record.lead, 0, MAX_U16), "TrafficPath.encode: lead must be 0..65535")
		assert(#record.nodes >= 2 and #record.nodes <= MAX_U16, "TrafficPath.encode: a route needs 2..65535 nodes")
		buffer.writeu8(data, at, record.pod)
		buffer.writeu32(data, at + 1, record.seq)
		buffer.writef64(data, at + 5, record.startAt)
		buffer.writeu16(data, at + 13, steps)
		buffer.writeu16(data, at + 15, record.lead)
		buffer.writeu16(data, at + 17, #record.nodes)
		at += RECORD_BYTES
		for _, node in record.nodes do
			assert(isWhole(node, 1, MAX_U16), "TrafficPath.encode: node indices must be 1..65535")
			buffer.writeu16(data, at, node)
			at += 2
		end
	end
	return data
end

-- Unpacks an encode() buffer, or nil if `data` is not one (wrong type or format, cut short or too long, a pod 0,
-- fewer than two nodes, a node or lead index over `nodeCount` when it is given).
function TrafficPath.decode(data: any, nodeCount: number?): { Record }?
	if typeof(data) ~= "buffer" then
		return nil
	end
	local size = buffer.len(data)
	if size < HEADER_BYTES or buffer.readu8(data, 0) ~= FORMAT then
		return nil
	end
	local maxNode = nodeCount or MAX_U16
	local count = buffer.readu8(data, 1)
	local records: { Record } = table.create(count)
	local at = HEADER_BYTES
	for _ = 1, count do
		if at + RECORD_BYTES > size then
			return nil
		end
		local pod = buffer.readu8(data, at)
		local seq = buffer.readu32(data, at + 1)
		local startAt = buffer.readf64(data, at + 5)
		local steps = buffer.readu16(data, at + 13)
		local lead = buffer.readu16(data, at + 15)
		local length = buffer.readu16(data, at + 17)
		at += RECORD_BYTES
		if pod == 0 or steps == 0 or length < 2 or lead > maxNode or startAt ~= startAt or at + 2 * length > size then
			return nil
		end
		local nodes: { number } = table.create(length)
		for i = 1, length do
			local node = buffer.readu16(data, at)
			at += 2
			if node == 0 or node > maxNode then
				return nil
			end
			nodes[i] = node
		end
		table.insert(records, {
			pod = pod,
			seq = seq,
			startAt = startAt,
			scale = steps / SCALE_STEPS,
			lead = lead,
			nodes = nodes,
		})
	end
	if at ~= size then
		return nil
	end
	return records
end

return TrafficPath
