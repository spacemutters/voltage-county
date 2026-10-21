--!strict
-- Light shows at meet spots (PLAN.md Phase 7; docs/phase-7-contracts.md "Light shows").
--
-- Players parked at a MeetSpot (Config/MapLayout) start or join a show there. Services/LightShowService picks a
-- routine and a start time on the server's clock and tells everyone nearby; Controllers/LightShowController runs
-- the routine on every client against workspace:GetServerTimeNow(), so all clients light every car together
-- with no per-frame network traffic.
--
-- A routine is a timeline of cues on its track's beat grid (Config/Audio: bpm, downbeat, length). Each cue says
-- when (in beats from beat 0), what (a lamp group from the model contract's Lights folder, the Doors folder, or
-- the underglow) and how:
--   on / off   a lamp (or the underglow) lights steadily or goes dark
--   pulse      a flash: full brightness at the cue, fading over `beats` back to the lamp's steady state
--   open/close every hinged door swings over `beats` (Doors folder, Hinge motors; cars without doors skip it)
-- `wave` delays the cue by that many beats per car along the line (slot 1 = no delay), so a flash rolls from one
-- end of the row to the other. Slots are numbered left to right across the meet spot by the server.
--
-- Data first, then the pure timeline helpers both sides share (tests/LightShows.spec covers them in Edit mode).

local Audio = require(script.Parent.Audio)

export type Target =
	"head"
	| "headL"
	| "headR"
	| "tail"
	| "tailL"
	| "tailR"
	| "brake"
	| "reverse"
	| "lamps"
	| "doors"
	| "underglow"

export type Action = "on" | "off" | "pulse" | "open" | "close"

-- A cue as written in a routine (all times in beats).
export type CueSpec = {
	beat: number, -- when, in beats from beat 0 (on the Config grid: whole sixteenths)
	target: Target,
	action: Action,
	beats: number?, -- pulse fade or door swing length (defaults: Config cueDefaults)
	wave: number?, -- extra delay per slot along the line (default 0)
}

export type Routine = {
	id: string,
	displayName: string, -- shown to players
	trackId: string, -- a Config/Audio track
	pro: boolean, -- needs the Boombox & Light Show Pro pass (Studio: always available)
	cues: { CueSpec }, -- sorted by beat (ties keep the written order)
}

-- A cue in seconds from the show's start. Show time is the track's own position: the music starts playing from
-- 0 at the show's startAt, so beat b is at downbeat + b * 60 / bpm.
export type Cue = {
	index: number, -- position in the routine's cue list
	time: number,
	target: Target,
	action: Action,
	duration: number, -- seconds (0 for on / off)
	wave: number, -- seconds of delay per slot
}

-- One cue for one car: what the client scheduler walks.
export type Event = {
	at: number, -- seconds from the show's start
	car: number, -- index into the car list given to LightShows.schedule
	cue: Cue,
}

-- A position sample of a car, for LightShows.smoothedSpeed.
export type Sample = { time: number, position: Vector3 }

---------------------------------------------------------------------------------------------------------------
-- Authoring helpers (routines below are written with these)
---------------------------------------------------------------------------------------------------------------

local function cue(beat: number, target: Target, action: Action, beats: number?, wave: number?): CueSpec
	return { beat = beat, target = target, action = action, beats = beats, wave = wave }
end

-- The same cue at fromBeat, fromBeat + step, ... while below toBeat.
local function every(
	fromBeat: number,
	toBeat: number,
	step: number,
	target: Target,
	action: Action,
	beats: number?,
	wave: number?
): { CueSpec }
	local list: { CueSpec } = {}
	local count = math.ceil((toBeat - fromBeat) / step)
	for i = 0, count - 1 do
		table.insert(list, cue(fromBeat + i * step, target, action, beats, wave))
	end
	return list
end

-- A routine from groups of cues (single cues or `every` lists), sorted by beat; equal beats keep the order they
-- were written in.
local function makeRoutine(id: string, displayName: string, trackId: string, pro: boolean, parts: { any }): Routine
	local entries: { { spec: CueSpec, order: number } } = {}
	local function add(spec: CueSpec)
		table.insert(entries, { spec = spec, order = #entries + 1 })
	end
	for _, part in parts do
		if part.beat ~= nil then
			add(part :: CueSpec)
		else
			for _, spec in part :: { CueSpec } do
				add(spec)
			end
		end
	end
	table.sort(entries, function(a, b)
		if a.spec.beat ~= b.spec.beat then
			return a.spec.beat < b.spec.beat
		end
		return a.order < b.order
	end)
	local cues: { CueSpec } = {}
	for _, entry in entries do
		table.insert(cues, entry.spec)
	end
	return { id = id, displayName = displayName, trackId = trackId, pro = pro, cues = cues }
end

---------------------------------------------------------------------------------------------------------------
-- Routines (original choreography; one bar = 4 beats)
---------------------------------------------------------------------------------------------------------------

local routines: { [string]: Routine } = {
	-- Free. A steady heartbeat that builds to a full-row drop at bar 17. 128 beats.
	heartbeat = makeRoutine("heartbeat", "Heartbeat", "midnight_circuit", false, {
		cue(0, "tail", "on"),
		every(0, 8, 2, "head", "pulse", 1),
		cue(8, "tail", "off"),
		every(8, 32, 1, "brake", "pulse", 0.5),
		every(8, 32, 2, "headL", "pulse", 1),
		every(9, 32, 2, "headR", "pulse", 1),
		cue(32, "head", "on"),
		every(32, 64, 0.5, "tail", "pulse", 0.25),
		every(35, 64, 4, "reverse", "pulse", 1),
		cue(64, "head", "off"),
		cue(64, "doors", "open", 4),
		cue(64, "underglow", "on"),
		every(64, 96, 1, "lamps", "pulse", 0.5, 0.5),
		cue(96, "doors", "close", 4),
		cue(96, "underglow", "off"),
		every(96, 120, 2, "underglow", "pulse", 1),
		cue(120, "lamps", "pulse", 2),
		cue(120, "underglow", "pulse", 2),
		cue(124, "head", "pulse", 2),
	}),

	-- Free. Slow flashes that roll along the row, doors rippling open and shut. 120 beats.
	ripple = makeRoutine("ripple", "Ripple", "harbor_lights", false, {
		cue(0, "tail", "on"),
		every(0, 16, 2, "head", "pulse", 2, 1),
		cue(16, "head", "on"),
		every(16, 48, 4, "brake", "pulse", 2, 0.5),
		cue(32, "doors", "open", 4, 1),
		cue(48, "doors", "close", 4, 1),
		every(48, 64, 1, "reverse", "pulse", 0.5, 0.25),
		cue(64, "head", "off"),
		cue(64, "tail", "off"),
		cue(64, "underglow", "on", nil, 1),
		every(64, 96, 2, "lamps", "pulse", 1.5, 1),
		every(96, 112, 1, "headL", "pulse", 0.5),
		every(96.5, 112, 1, "headR", "pulse", 0.5),
		cue(112, "underglow", "off"),
		cue(112, "lamps", "pulse", 4),
	}),

	-- Boombox & Light Show Pro. Fast strobes, left-right tail chases and a doors-up drop. 128 beats.
	strobe = makeRoutine("strobe", "Strobe", "neon_mesa", true, {
		cue(0, "tail", "on"),
		every(0, 16, 0.5, "head", "pulse", 0.25),
		cue(16, "tail", "off"),
		every(16, 32, 1, "tailL", "pulse", 0.5),
		every(16.5, 32, 1, "tailR", "pulse", 0.5),
		cue(32, "lamps", "on"),
		cue(48, "lamps", "off"),
		every(48, 64, 1, "lamps", "pulse", 0.5, 0.25),
		cue(64, "doors", "open", 2),
		cue(64, "underglow", "on"),
		every(64, 96, 0.5, "head", "pulse", 0.25),
		every(64.25, 96, 0.5, "tail", "pulse", 0.25),
		cue(96, "doors", "close", 2),
		cue(96, "underglow", "off"),
		every(96, 120, 1, "reverse", "pulse", 0.75, 0.5),
		every(96.5, 120, 1, "brake", "pulse", 0.5),
		cue(120, "lamps", "on"),
		cue(126, "lamps", "off"),
	}),

	-- Boombox & Light Show Pro. Doors take the lead: long swings in a wave, lamps answering. 120 beats.
	ballet = makeRoutine("ballet", "Door Ballet", "harbor_lights", true, {
		cue(0, "tail", "on"),
		cue(0, "head", "pulse", 4, 2),
		cue(4, "brake", "pulse", 2),
		cue(8, "doors", "open", 8, 2),
		every(16, 32, 1, "brake", "pulse", 1, 0.5),
		cue(32, "doors", "close", 8, 2),
		cue(32, "head", "on"),
		cue(56, "doors", "open", 4),
		every(56, 72, 2, "underglow", "pulse", 2),
		cue(72, "doors", "close", 4),
		every(76, 100, 2, "lamps", "pulse", 1.5, 1),
		cue(104, "head", "off"),
		cue(104, "tail", "off"),
		cue(108, "lamps", "pulse", 6),
		cue(112, "doors", "open", 2),
		cue(116, "doors", "close", 2),
	}),
}

---------------------------------------------------------------------------------------------------------------
-- Tunables
---------------------------------------------------------------------------------------------------------------

local LightShows = {
	routines = routines,
	-- The order routines rotate through at a meet spot (free ones first).
	routineOrder = { "heartbeat", "ripple", "strobe", "ballet" },

	-- Phase 12 pass that unlocks the `pro` routines (MonetizationService.hasPass(player, proPass)). Until
	-- MonetizationService exists, pro routines are played only in Studio.
	proPass = "lightShowPro",

	-- The beat grid every cue sits on: whole sixteenths (4 per beat).
	gridPerBeat = 4,

	-- Cue lengths, in beats, when a cue doesn't give one.
	cueDefaults = {
		pulse = 1,
		open = 2,
		close = 2,
	},

	-- Lamp groups: model contract parts in each car's Lights folder (each holds a Light named "Light").
	lampGroups = {
		head = { "HeadL", "HeadR" },
		headL = { "HeadL" },
		headR = { "HeadR" },
		tail = { "TailL", "TailR" },
		tailL = { "TailL" },
		tailR = { "TailR" },
		brake = { "Brake" },
		reverse = { "Reverse" },
		lamps = { "HeadL", "HeadR", "TailL", "TailR", "Brake", "Reverse" },
	} :: { [string]: { string } },

	-- The server's side of a show.
	show = {
		leadIn = 8, -- seconds from the first join to the start, so others can pull in and join
		joinCutoff = 1, -- joining closes this many seconds before the start (late cars would miss the first cues)
		maxCars = 8, -- cars in one show (every routine must fit its waves into the track for this many)
		endPadding = 1, -- seconds after the music ends before the server ends the show
		restartCooldown = 20, -- seconds a meet spot waits after a show there empties before a new one may start
	},

	-- Who may join: the driver of a car sitting in the meet spot's footprint, nearly still.
	join = {
		stillMph = 2, -- smoothed speed at or under this counts as still
		stillWindow = 0.6, -- seconds of position samples the smoothed speed is taken over
		heightAbove = 6, -- studs the car's pivot may sit above the footprint's surface
		heightBelow = 2, -- and below it
		startCooldown = 30, -- seconds after a player starts a new show before they may start another (anywhere)
	},

	-- While a show runs the server checks its cars and its audience this often (Heartbeat, only while a show
	-- exists).
	watch = {
		interval = 0.5, -- seconds between checks
		leaveMargin = 4, -- studs outside the footprint before a car counts as gone
		audienceRadius = 250, -- studs from the meet spot within which players get the show
		audienceExitFactor = 1.2, -- they lose it beyond radius x this (so the edge doesn't flicker)
		optOutSeconds = 300, -- a watcher who hid a meet spot's show isn't sent shows from that spot for this long
	},

	-- Where cars stand along a meet spot (test cars and slot numbering): side by side across the footprint,
	-- facing its front.
	slots = {
		spacing = 11, -- studs between neighbouring cars' centres
		edgeInset = 5, -- studs kept clear at each end of the row
		takenRadius = 8, -- a slot with a car's pivot within this many studs is taken
	},

	-- Attributes the server sets on every car in a show (the clients' roster survives streaming with them).
	attributes = {
		showId = "LightShowId",
		slot = "LightShowSlot",
		underglow = "LightShowUnderglow", -- true when the car has a light-bar extra
		testCar = "LightShowTestCar", -- Studio test cars (LightShowService.devAddTestCars)
	},

	-- Underglow plays only on cars with one of these kit extras (Config/Customization extras ids).
	underglow = {
		extraIds = { "light_bar" },
		color = Color3.fromRGB(120, 200, 255),
		brightness = 4,
		range = 14, -- studs
		drop = 0.5, -- studs below the chassis' bottom face
	},

	-- How lamps and doors are drawn on the clients.
	look = {
		lightsFolder = "Lights",
		lightName = "Light",
		doorsFolder = "Doors",
		hingeName = "Hinge",
		openAngleAttribute = "OpenAngle", -- degrees, signed per door (Dev/VehicleBuilder)
		-- Art models (Dev/ArtPass): the body mesh draws the closed doors, so the door parts are hidden until they
		-- swing. A door part (or a part on it) with this number attribute shows at that transparency while open.
		doorShowAttribute = "ShowWhenOpen",
		doorShowAmount = 0.02, -- how open (0..1) a door must be before it shows
		onMaterial = Enum.Material.Neon, -- a lit lamp part glows; its own material returns when dark
		minBrightness = 2, -- a lamp's Light shines at least this bright during a show
		glowThreshold = 0.3, -- lamp level (0..1) above which the part glows
		pulseCurve = 2, -- a pulse fades as (1 - t)^pulseCurve
		levelStep = 0.05, -- lamp levels are written only when they change by at least this much
	},

	-- The client's side of a show.
	client = {
		leaveDistance = 6, -- studs a car may move from where it stood when the show reached it before it drops out
		leaveCheckInterval = 0.25, -- seconds between those checks
		promptCheckInterval = 0.5, -- seconds between checks for the "Light show" button while driving
		stillMph = 2, -- the button shows when the car is at or under this speed inside a meet spot
		audioResyncTolerance = 0.15, -- seconds the music may drift from the show clock before it is re-seeked
		audioResyncInterval = 2, -- seconds between drift checks
		rollOffMin = 30, -- studs: full volume inside this distance of the meet spot
		rollOffMax = 300, -- studs: silent beyond this
		lateCatchUp = 0.5, -- seconds: a cue found this late (a hitch, or a car streamed in mid-show) is applied
		-- instantly without its fade or swing
	},

	-- The on-screen button (UI-scale-1 pixels; colors and fonts from UI/Theme).
	button = {
		width = 200,
		gap = 8, -- below the notices band
	},

	messages = {
		started = "Light show at %s starts in %d s.",
		joined = "You're in the light show at %s.",
		unknownSpot = "That isn't a meet spot.",
		notDriving = "Get in the driver's seat of your car first.",
		notInside = "Park inside the meet spot to join its light show.",
		notStill = "Stop the car to join the light show.",
		busy = "A light show is running here. Join the next one when it ends.",
		full = "This light show is full.",
		spotCooling = "A light show just ended here. Try again in %d s.",
		playerCooling = "You can start another light show in %d s.",
		left = "You left the light show.",
		notInShow = "You're not in a light show.",
		buttonJoin = "Light show",
		buttonLeave = "Leave show",
		buttonHide = "Hide show", -- watchers: stop the show on this screen (LeaveLightShow)
	},

	-- Studio-only test support (Dev/LightShowTests; refused outside Studio). A JoinLightShow whose meetSpotId is
	-- `fillPrefix .. "<cars>:" .. <meet spot id>` joins like any other and then fills the show with server-side
	-- test cars up to <cars>.
	dev = {
		fillPrefix = "dev-fill:",
		testVehicles = { "ohm_summit", "ohm_grand", "ohm_spark", "ohm_current" }, -- cycled; summit has doors
		probeFiresPerCar = 3, -- cues per car the client keeps the timing of
		maxSpread = 0.1, -- seconds: PLAN.md Phase 7 acceptance (three cars within 100 ms)
	},
}

---------------------------------------------------------------------------------------------------------------
-- Pure helpers
---------------------------------------------------------------------------------------------------------------

-- Seconds per beat of a track.
function LightShows.beatSeconds(track: Audio.Track): number
	return 60 / track.bpm
end

function LightShows.getRoutine(routineId: string): Routine?
	return routines[routineId]
end

function LightShows.trackOf(routine: Routine): Audio.Track?
	return Audio.tracks[routine.trackId]
end

-- How long a show of this routine lasts: its track's length, in seconds.
function LightShows.length(routine: Routine): number
	local track = Audio.tracks[routine.trackId]
	return if track then track.length else 0
end

-- The routine's cues in show seconds (the track's position), in time order.
function LightShows.compile(routine: Routine): { Cue }
	local track = Audio.tracks[routine.trackId]
	assert(track ~= nil, `LightShows: routine "{routine.id}" uses unknown track "{routine.trackId}"`)
	local spb = LightShows.beatSeconds(track)
	local defaults = LightShows.cueDefaults :: { [string]: number }
	local cues: { Cue } = {}
	for index, spec in routine.cues do
		local beats = spec.beats or defaults[spec.action] or 0
		table.insert(cues, {
			index = index,
			time = track.downbeat + spec.beat * spb,
			target = spec.target,
			action = spec.action,
			duration = if spec.action == "on" or spec.action == "off" then 0 else beats * spb,
			wave = (spec.wave or 0) * spb,
		})
	end
	return cues
end

-- When a cue happens for the car in `slot` (1 = no wave delay).
function LightShows.cueTime(compiled: Cue, slot: number): number
	return compiled.time + compiled.wave * (math.max(slot, 1) - 1)
end

-- Every cue for every car, in the order they happen: one list the client walks with a single cursor. `slots[i]`
-- is car i's slot; ties are broken by car, then by cue order, so the order is the same on every client.
function LightShows.schedule(cues: { Cue }, slots: { number }): { Event }
	local events: { Event } = {}
	for car, slot in slots do
		for _, compiled in cues do
			table.insert(events, { at = LightShows.cueTime(compiled, slot), car = car, cue = compiled })
		end
	end
	table.sort(events, function(a, b)
		if a.at ~= b.at then
			return a.at < b.at
		elseif a.car ~= b.car then
			return a.car < b.car
		end
		return a.cue.index < b.cue.index
	end)
	return events
end

-- The index of the first event after `elapsed` (seconds since the show's start), searching from `cursor`: the
-- events from `cursor` up to (not including) the returned index are due now.
function LightShows.advance(events: { Event }, cursor: number, elapsed: number): number
	local index = math.max(cursor, 1)
	while index <= #events and events[index].at <= elapsed do
		index += 1
	end
	return index
end

-- The events due at `elapsed` when nothing has run yet (a binary search): same as advance(events, 1, elapsed).
function LightShows.cursorAt(events: { Event }, elapsed: number): number
	local low, high = 1, #events + 1
	while low < high do
		local middle = (low + high) // 2
		if events[middle].at <= elapsed then
			low = middle + 1
		else
			high = middle
		end
	end
	return low
end

-- A pulse's brightness (0..1) `since` seconds after it fired, fading over `duration`.
function LightShows.pulseLevel(since: number, duration: number): number
	if since < 0 or duration <= 0 or since >= duration then
		return 0
	end
	return (1 - since / duration) ^ LightShows.look.pulseCurve
end

-- How far open (0..1) a door is `since` seconds into a swing from `from` to `to` lasting `duration` (smooth start
-- and stop).
function LightShows.doorAmount(from: number, to: number, since: number, duration: number): number
	if duration <= 0 or since >= duration then
		return to
	elseif since <= 0 then
		return from
	end
	local t = since / duration
	local eased = t * t * (3 - 2 * t)
	return from + (to - from) * eased
end

-- A MeetSpot location's footprint frame: centred on its position (on the surface), turned to its yaw.
function LightShows.footprintFrame(position: Vector3, yaw: number): CFrame
	return CFrame.new(position) * CFrame.Angles(0, math.rad(yaw), 0)
end

-- True when `point` (a car's pivot: the ground under its chassis) stands on the footprint: within its
-- rectangle grown by `margin` studs, and between heightBelow under its surface and heightAbove over its top.
function LightShows.insideFootprint(frame: CFrame, size: Vector3, point: Vector3, margin: number): boolean
	local localPoint = frame:PointToObjectSpace(point)
	local join = LightShows.join
	return math.abs(localPoint.X) <= size.X / 2 + margin
		and math.abs(localPoint.Z) <= size.Z / 2 + margin
		and localPoint.Y >= -join.heightBelow
		and localPoint.Y <= size.Y + join.heightAbove
end

-- Speed (studs/s) from position samples taken over a short window, robust to the wobble the server sees on a
-- car a client simulates: the mean position of the later half against the mean of the earlier half, over the
-- time between their mean times. nil with fewer than two samples or no time between the halves.
function LightShows.smoothedSpeed(samples: { Sample }): number?
	local count = #samples
	if count < 2 then
		return nil
	end
	local half = count // 2
	local function mean(first: number, last: number): (Vector3, number)
		local position, time = Vector3.zero, 0
		for i = first, last do
			position += samples[i].position
			time += samples[i].time
		end
		local n = last - first + 1
		return position / n, time / n
	end
	local earlyPosition, earlyTime = mean(1, half)
	local latePosition, lateTime = mean(count - half + 1, count)
	local seconds = lateTime - earlyTime
	if seconds <= 0 then
		return nil
	end
	local delta = latePosition - earlyPosition
	return Vector3.new(delta.X, 0, delta.Z).Magnitude / seconds
end

-- Where cars stand along a footprint: side by side across it (left to right as you face its front), each facing
-- its front, pivots on its surface. As many as fit between the insets at `spacing`.
function LightShows.slotFrames(frame: CFrame, size: Vector3): { CFrame }
	local slots = LightShows.slots
	local usable = size.X - 2 * slots.edgeInset
	local count = math.max(1, math.floor(usable / slots.spacing) + 1)
	local frames: { CFrame } = {}
	for i = 1, count do
		local x = (i - (count + 1) / 2) * slots.spacing
		table.insert(frames, frame * CFrame.new(x, size.Y, 0))
	end
	return frames
end

-- Slot numbers for cars at these pivots: left to right across the footprint (local X), so waves roll along the
-- row. Returns a slot per input, 1..#pivots.
function LightShows.slotOrder(frame: CFrame, pivots: { Vector3 }): { number }
	local order: { number } = {}
	for i in pivots do
		table.insert(order, i)
	end
	table.sort(order, function(a, b)
		local ax = frame:PointToObjectSpace(pivots[a]).X
		local bx = frame:PointToObjectSpace(pivots[b]).X
		if ax ~= bx then
			return ax < bx
		end
		return a < b
	end)
	local slots: { number } = {}
	for slot, index in order do
		slots[index] = slot
	end
	return slots
end

-- The routine ids a player may get, in rotation order: every routine with Pro, else only the free ones.
function LightShows.routinesFor(hasPro: boolean): { string }
	local list: { string } = {}
	for _, id in LightShows.routineOrder do
		local entry = routines[id]
		if entry ~= nil and (hasPro or not entry.pro) then
			table.insert(list, id)
		end
	end
	return list
end

-- The next routine in `pool` after `last` (the one played last at this meet spot), wrapping round; the first
-- when `last` is nil or not in the pool.
function LightShows.nextRoutine(pool: { string }, last: string?): string?
	if #pool == 0 then
		return nil
	end
	local index = if last then table.find(pool, last) else nil
	return pool[if index then index % #pool + 1 else 1]
end

-- Everything wrong with a routine, as readable lines (empty when it is fine): unknown track, cue targets or
-- actions, cues out of order, off the beat grid, or running past the track's end for a full show.
function LightShows.problems(routine: Routine): { string }
	local problems: { string } = {}
	local track = Audio.tracks[routine.trackId]
	if track == nil then
		table.insert(problems, `{routine.id}: unknown track "{routine.trackId}"`)
		return problems
	end
	local grid = LightShows.gridPerBeat
	local function onGrid(beats: number): boolean
		local steps = beats * grid
		return math.abs(steps - math.round(steps)) < 1e-6
	end
	local lampActions = { on = true, off = true, pulse = true }
	local doorActions = { open = true, close = true }
	local previous = -math.huge
	for index, spec in routine.cues do
		local where = `{routine.id} cue {index} (beat {spec.beat})`
		if spec.beat < previous then
			table.insert(problems, `{where}: out of order`)
		end
		previous = spec.beat
		if spec.beat < 0 then
			table.insert(problems, `{where}: before beat 0`)
		end
		if not onGrid(spec.beat) or not onGrid(spec.beats or 0) or not onGrid(spec.wave or 0) then
			table.insert(problems, `{where}: off the 1/{grid}-beat grid`)
		end
		if spec.target == "doors" then
			if not doorActions[spec.action] then
				table.insert(problems, `{where}: doors can only open or close`)
			end
		elseif spec.target == "underglow" or LightShows.lampGroups[spec.target] ~= nil then
			if not lampActions[spec.action] then
				table.insert(problems, `{where}: lamps can only go on, off or pulse`)
			end
		else
			table.insert(problems, `{where}: unknown target "{spec.target}"`)
		end
	end
	local maxSlot = LightShows.show.maxCars
	for _, compiled in LightShows.compile(routine) do
		local finish = LightShows.cueTime(compiled, maxSlot) + compiled.duration
		if finish > track.length + 1e-6 then
			table.insert(
				problems,
				`{routine.id} cue {compiled.index}: ends at {finish} s with {maxSlot} cars, after the track's {track.length} s`
			)
		end
	end
	return problems
end

return LightShows
