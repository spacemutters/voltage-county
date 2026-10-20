--!strict
-- Light shows (Config/LightShows and Config/Audio; docs/phase-7-contracts.md "Light shows"): every shipped routine
-- is sorted, on the beat grid and fits its track with a full row of cars; the placeholder tracks no-op (assetId 0)
-- and hold whole bars; compiling beats to seconds; wave delays per slot; the scheduler's merged event list and
-- which events are due at a given show time (including a frame-by-frame walk that fires each event once, never
-- early); pulse and door curves; the meet-spot footprint test, smoothed stillness, slot numbering and routine
-- rotation. Pure logic on fixtures: runs in Edit mode.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Audio = require(ReplicatedStorage.Shared.Config.Audio)
local Harness = require(ReplicatedStorage.Shared.Testing.Harness)
local LightShows = require(ReplicatedStorage.Shared.Config.LightShows)
local MapLayout = require(ReplicatedStorage.Shared.Config.MapLayout)

local EPSILON = 1e-6
local FLOAT = 1e-3 -- Vector3 maths is 32-bit
local BEATS_PER_BAR = 4

-- A tiny fixture routine on a fixture-friendly shipped track (120 bpm: half a second per beat).
local FIXTURE_TRACK = "midnight_circuit"

local function fixtureRoutine(): LightShows.Routine
	return {
		id = "fixture",
		displayName = "Fixture",
		trackId = FIXTURE_TRACK,
		pro = false,
		cues = {
			{ beat = 0, target = "tail", action = "on" },
			{ beat = 1, target = "head", action = "pulse", beats = 0.5, wave = 1 },
			{ beat = 2, target = "doors", action = "open" },
			{ beat = 2, target = "brake", action = "pulse" },
		},
	}
end

local function isLamp(target: string): boolean
	return target ~= "doors" and target ~= "underglow"
end

return function(t: Harness.Api)
	t.describe("Config/Audio", function()
		t.it("has placeholder tracks that play nothing, with a tempo, length and whole bars", function()
			for _, id in Audio.trackOrder do
				local track = Audio.tracks[id]
				t.expect(track ~= nil).toBe(true)
				t.expect(track.assetId).toBe(0) -- the lead fills real ids after picking tracks
				t.expect(track.bpm).toBeGreaterThan(0)
				t.expect(track.length).toBeGreaterThan(0)
				t.expect(#track.displayName).toBeGreaterThan(0)
				local beats = (track.length - track.downbeat) * track.bpm / 60
				t.expect(math.abs(beats / BEATS_PER_BAR - math.round(beats / BEATS_PER_BAR)) < EPSILON).toBe(true)
			end
		end)
	end)

	t.describe("shipped routines", function()
		t.it("are all in the rotation, with free and Pro ones", function()
			local free, pro = 0, 0
			for id, routine in LightShows.routines do
				t.expect(table.find(LightShows.routineOrder, id) ~= nil).toBe(true)
				t.expect(routine.id).toBe(id)
				if routine.pro then
					pro += 1
				else
					free += 1
				end
			end
			t.expect(#LightShows.routineOrder).toBe(free + pro)
			t.expect(free).toBeGreaterThan(1)
			t.expect(pro).toBeGreaterThan(0)
		end)

		t.it("have no problems: known targets, sorted, on the grid, inside the track with a full row", function()
			for _, id in LightShows.routineOrder do
				local routine = LightShows.getRoutine(id) :: LightShows.Routine
				t.expect(LightShows.problems(routine)).toEqual({})
			end
		end)

		t.it("compile to cues sorted in time that end before the music does", function()
			for _, id in LightShows.routineOrder do
				local routine = LightShows.getRoutine(id) :: LightShows.Routine
				local cues = LightShows.compile(routine)
				t.expect(#cues).toBe(#routine.cues)
				local length = LightShows.length(routine)
				for index, compiled in cues do
					if index > 1 then
						t.expect(compiled.time >= cues[index - 1].time).toBe(true)
					end
					t.expect(compiled.time >= 0).toBe(true)
					local last = LightShows.cueTime(compiled, LightShows.show.maxCars) + compiled.duration
					t.expect(last <= length + EPSILON).toBe(true)
				end
			end
		end)

		t.it("land every cue on the beat grid of its track", function()
			for _, id in LightShows.routineOrder do
				local routine = LightShows.getRoutine(id) :: LightShows.Routine
				local track = LightShows.trackOf(routine) :: Audio.Track
				local spb = LightShows.beatSeconds(track)
				for _, compiled in LightShows.compile(routine) do
					local steps = (compiled.time - track.downbeat) / spb * LightShows.gridPerBeat
					t.expect(math.abs(steps - math.round(steps)) < EPSILON).toBe(true)
					local waveSteps = compiled.wave / spb * LightShows.gridPerBeat
					t.expect(math.abs(waveSteps - math.round(waveSteps)) < EPSILON).toBe(true)
				end
			end
		end)

		t.it("open with lamp cues, so every car in a show runs its first cues (the sync test times those)", function()
			for _, id in LightShows.routineOrder do
				local routine = LightShows.getRoutine(id) :: LightShows.Routine
				for index = 1, LightShows.dev.probeFiresPerCar do
					t.expect(isLamp(routine.cues[index].target)).toBe(true)
				end
			end
		end)
	end)

	t.describe("LightShows.problems", function()
		t.it("catches cues out of order, off the grid, past the end and with unknown targets or actions", function()
			local routine = fixtureRoutine()
			t.expect(LightShows.problems(routine)).toEqual({})
			routine.cues = {
				{ beat = 4, target = "tail", action = "on" },
				{ beat = 3, target = "tail", action = "off" }, -- out of order
				{ beat = 5.1, target = "head", action = "pulse" }, -- off the grid
				{ beat = 6, target = "doors", action = "pulse" }, -- doors don't pulse
				{ beat = 7, target = "head", action = "open" }, -- lamps don't open
				{ beat = 126, target = "lamps", action = "pulse", beats = 1, wave = 1 }, -- past the end with 8 cars
			}
			t.expect(#LightShows.problems(routine)).toBe(5)
			routine.cues = { { beat = 0, target = "wing" :: any, action = "on" } }
			t.expect(#LightShows.problems(routine)).toBe(1)
			routine.trackId = "missing"
			t.expect(#LightShows.problems(routine)).toBe(1)
		end)
	end)

	t.describe("compile and schedule", function()
		t.it("turns beats into seconds with the default lengths", function()
			local cues = LightShows.compile(fixtureRoutine())
			local spb = 60 / Audio.tracks[FIXTURE_TRACK].bpm
			t.expect(cues[1].time).toBeNear(0, EPSILON)
			t.expect(cues[1].duration).toBe(0)
			t.expect(cues[2].time).toBeNear(spb, EPSILON)
			t.expect(cues[2].duration).toBeNear(0.5 * spb, EPSILON)
			t.expect(cues[2].wave).toBeNear(spb, EPSILON)
			t.expect(cues[3].duration).toBeNear(LightShows.cueDefaults.open * spb, EPSILON)
			t.expect(cues[4].duration).toBeNear(LightShows.cueDefaults.pulse * spb, EPSILON)
		end)

		t.it("delays a wave cue by one wave per slot", function()
			local cues = LightShows.compile(fixtureRoutine())
			local spb = 60 / Audio.tracks[FIXTURE_TRACK].bpm
			t.expect(LightShows.cueTime(cues[2], 1)).toBeNear(spb, EPSILON)
			t.expect(LightShows.cueTime(cues[2], 3)).toBeNear(3 * spb, EPSILON)
			t.expect(LightShows.cueTime(cues[1], 5)).toBeNear(0, EPSILON) -- no wave: same for every car
		end)

		t.it("merges every car's cues into one list in time order, ties by car then cue", function()
			local cues = LightShows.compile(fixtureRoutine())
			local events = LightShows.schedule(cues, { 1, 2, 3 })
			t.expect(#events).toBe(#cues * 3)
			for index = 2, #events do
				local previous, current = events[index - 1], events[index]
				t.expect(current.at >= previous.at).toBe(true)
				if current.at == previous.at then
					local ordered = previous.car < current.car
						or (previous.car == current.car and previous.cue.index < current.cue.index)
					t.expect(ordered).toBe(true)
				end
			end
			-- The first three events are the three cars' tail lamps at 0.
			for car = 1, 3 do
				t.expect(events[car].at).toBe(0)
				t.expect(events[car].car).toBe(car)
				t.expect(events[car].cue.target).toBe("tail")
			end
		end)

		t.it("says which events are due at a show time (a cue exactly at its time is due)", function()
			local cues = LightShows.compile(fixtureRoutine())
			local events = LightShows.schedule(cues, { 1, 2 })
			local spb = 60 / Audio.tracks[FIXTURE_TRACK].bpm
			-- Before the start nothing is due.
			t.expect(LightShows.cursorAt(events, -1)).toBe(1)
			-- At 0: both tail cues.
			t.expect(LightShows.cursorAt(events, 0)).toBe(3)
			-- At one beat: car 1's head pulse too (car 2's waves a beat later).
			local cursor = LightShows.advance(events, 3, spb)
			t.expect(cursor).toBe(4)
			t.expect(events[3].car).toBe(1)
			t.expect(events[3].cue.target).toBe("head")
			-- Just before two beats nothing more; at two beats car 2's head plus both cars' doors and brakes.
			t.expect(LightShows.advance(events, cursor, 2 * spb - 0.001)).toBe(4)
			t.expect(LightShows.advance(events, cursor, 2 * spb)).toBe(#events + 1)
			-- advance from the start agrees with the binary search everywhere.
			for _, at in { -1, 0, 0.2, spb, 1.5 * spb, 2 * spb, 100 } do
				t.expect(LightShows.advance(events, 1, at)).toBe(LightShows.cursorAt(events, at))
			end
		end)

		t.it("fires every event exactly once, never early and within one frame, walking frame by frame", function()
			local routine = LightShows.getRoutine("ripple") :: LightShows.Routine
			local events = LightShows.schedule(LightShows.compile(routine), { 1, 2, 3 })
			local frame = 1 / 60
			local fired = 0
			local cursor = 1
			local elapsed = -0.5 -- the lead-in's last half second
			local worstLate = 0
			while elapsed <= LightShows.length(routine) + frame do
				local nextCursor = LightShows.advance(events, cursor, elapsed)
				for index = cursor, nextCursor - 1 do
					local late = elapsed - events[index].at
					t.expect(late >= 0).toBe(true)
					worstLate = math.max(worstLate, late)
					fired += 1
				end
				cursor = nextCursor
				elapsed += frame
			end
			t.expect(fired).toBe(#events)
			t.expect(worstLate < frame + EPSILON).toBe(true)
		end)
	end)

	t.describe("curves", function()
		t.it("fades a pulse from full to nothing over its length", function()
			t.expect(LightShows.pulseLevel(0, 1)).toBe(1)
			t.expect(LightShows.pulseLevel(1, 1)).toBe(0)
			t.expect(LightShows.pulseLevel(-0.1, 1)).toBe(0)
			t.expect(LightShows.pulseLevel(0.5, 0)).toBe(0)
			local half = LightShows.pulseLevel(0.5, 1)
			t.expect(half > 0 and half < 1).toBe(true)
			t.expect(LightShows.pulseLevel(0.25, 1) > LightShows.pulseLevel(0.75, 1)).toBe(true)
		end)

		t.it("swings a door smoothly from where it was to where it goes", function()
			t.expect(LightShows.doorAmount(0, 1, 0, 2)).toBe(0)
			t.expect(LightShows.doorAmount(0, 1, 2, 2)).toBe(1)
			t.expect(LightShows.doorAmount(0, 1, 1, 2)).toBeNear(0.5, EPSILON)
			t.expect(LightShows.doorAmount(1, 0, 5, 2)).toBe(0)
			t.expect(LightShows.doorAmount(0.4, 1, 1, 0)).toBe(1) -- instant
		end)
	end)

	t.describe("meet spots", function()
		local spot: MapLayout.Location? = nil
		for _, location in MapLayout.locations do
			if location.tag == "MeetSpot" then
				spot = location
				break
			end
		end

		t.it("exist in the map", function()
			t.expect(spot ~= nil).toBe(true)
		end)

		t.it("tell a car on the footprint from one beside it, turned with the spot", function()
			local location = spot :: MapLayout.Location
			local frame = LightShows.footprintFrame(location.position, location.yaw)
			local size = location.size
			local top = Vector3.yAxis * size.Y
			t.expect(LightShows.insideFootprint(frame, size, frame.Position + top, 0)).toBe(true)
			local nearEdge = frame:PointToWorldSpace(Vector3.new(size.X / 2 - 1, size.Y, size.Z / 2 - 1))
			t.expect(LightShows.insideFootprint(frame, size, nearEdge, 0)).toBe(true)
			local beside = frame:PointToWorldSpace(Vector3.new(size.X / 2 + 2, size.Y, 0))
			t.expect(LightShows.insideFootprint(frame, size, beside, 0)).toBe(false)
			t.expect(LightShows.insideFootprint(frame, size, beside, 3)).toBe(true) -- inside the leave margin
			local above = frame.Position + Vector3.yAxis * (size.Y + LightShows.join.heightAbove + 1)
			t.expect(LightShows.insideFootprint(frame, size, above, 0)).toBe(false)
		end)

		t.it("put every slot on the footprint, numbered left to right", function()
			local location = spot :: MapLayout.Location
			local frame = LightShows.footprintFrame(location.position, location.yaw)
			local frames = LightShows.slotFrames(frame, location.size)
			t.expect(#frames >= 3).toBe(true)
			local pivots: { Vector3 } = {}
			for _, slotFrame in frames do
				t.expect(LightShows.insideFootprint(frame, location.size, slotFrame.Position, 0)).toBe(true)
				t.expect(slotFrame.LookVector:Dot(frame.LookVector)).toBeNear(1, FLOAT)
				table.insert(pivots, 1, slotFrame.Position) -- reversed: right to left
			end
			local slots = LightShows.slotOrder(frame, pivots)
			for index, slot in slots do
				t.expect(slot).toBe(#pivots - index + 1)
			end
		end)
	end)

	t.describe("stillness", function()
		t.it("reads a wobbling parked car as still and a creeping car as moving", function()
			local wobble: { LightShows.Sample } = {}
			local creep: { LightShows.Sample } = {}
			for i = 0, 35 do
				local time = i / 60
				local jitter = if i % 2 == 0 then 0.3 else -0.3 -- the server's view of a client-driven car
				table.insert(wobble, { time = time, position = Vector3.new(jitter, 0, -jitter) })
				table.insert(creep, { time = time, position = Vector3.new(10 * time, 0, 0) })
			end
			local still = LightShows.smoothedSpeed(wobble) :: number
			t.expect(still < 1).toBe(true)
			t.expect(LightShows.smoothedSpeed(creep) :: number).toBeNear(10, 0.01)
			t.expect(LightShows.smoothedSpeed({})).toBe(nil)
		end)
	end)

	t.describe("routine choice", function()
		t.it("offers Pro routines only with the pass and rotates through what is offered", function()
			local free = LightShows.routinesFor(false)
			local all = LightShows.routinesFor(true)
			t.expect(#all).toBe(#LightShows.routineOrder)
			for _, id in free do
				t.expect((LightShows.getRoutine(id) :: LightShows.Routine).pro).toBe(false)
			end
			t.expect(#free < #all).toBe(true)
			t.expect(LightShows.nextRoutine(free, nil)).toBe(free[1])
			t.expect(LightShows.nextRoutine(free, free[1])).toBe(free[2])
			t.expect(LightShows.nextRoutine(free, free[#free])).toBe(free[1])
			t.expect(LightShows.nextRoutine(free, "strobe")).toBe(free[1]) -- a Pro routine isn't in the free pool
			t.expect(LightShows.nextRoutine({}, nil)).toBe(nil)
		end)
	end)
end
