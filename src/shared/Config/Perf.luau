--!strict
-- Performance budgets (PLAN.md Phase 14 "Budgets"; docs/phase-14-contracts.md "Performance"):
--   frame      frame-time budgets (mean and p95, in ms) for desktop, a mid-range phone and the server, which
--              Dev/PerfTests and Services/DevPerfService measure against
--   memory     the client memory target for the real-phone check
--   parts      how many parts a car may have, as built and as a player dresses it (tests/PartBudget.spec)
--   meshes     the triangle budget for generated and art meshes (Vehicle/GeneratedAdapter refuses bigger looks)
--   streaming  the Workspace streaming values for the highway. Only StreamingEnabled is scriptable: no script or
--              plugin (Rojo's live sync included) can set or read the other four, so they are set by hand in Studio's
--              Properties panel (docs/LAUNCH.md step 10). default.project.json holds all five (what rojo build
--              writes) and scripts/check fails when it differs from this block; Dev/PerfTests checks StreamingEnabled
--   dev        the Studio-only server sampler (Services/DevPerfService)
-- Perf.summarize(samples) turns frame times into mean, p95 and max; Perf.meets(summary, budget) judges them.

export type FrameBudget = {
	fps: number, -- the frame rate the budget stands for
	meanMs: number, -- mean frame time at most this
	p95Ms: number, -- 95th percentile frame time at most this
}

export type Summary = { samples: number, meanMs: number, p95Ms: number, maxMs: number }

local Perf = {
	frame = {
		-- 60 fps on desktop: the mean is 1000 / 60 ms plus 2 % for timer jitter; one frame in 20 may take up to 20 ms
		-- (50 fps) for a streaming burst or a garbage collection.
		desktop = { fps = 60, meanMs = 17, p95Ms = 20 } :: FrameBudget,
		-- 30+ fps on a mid-range phone: the mean is 1000 / 30 ms plus 2 %; one frame in 20 may take up to 40 ms.
		phone = { fps = 30, meanMs = 34, p95Ms = 40 } :: FrameBudget,
		-- The server's heartbeat runs at 60 Hz; a server that keeps up holds it there.
		server = { fps = 60, meanMs = 17, p95Ms = 20 } :: FrameBudget,
		percentile = 0.95, -- nearest rank
	},

	memory = {
		-- The client's total on a mid-range phone, read from Roblox's Performance Stats overlay on the phone (Davis's
		-- real-phone check). A working target, not a Roblox limit. Studio's own number includes Studio, so the perf
		-- drive reports it without judging it.
		phoneMb = 1000,
	},

	-- What a car may carry (decided in Phase 14).
	--   model    every car we build and store: the catalog models in ServerStorage.VehicleModels (greybox or art) and
	--            every design the AI Car Designer builds (Vehicle/SpecBuilder). Vehicle/BodyKit's own budget
	--            (BodyKit.MAX_PARTS) must equal it.
	--   dressed  the same car in the fullest Wrap & Tint look a player can buy: the busiest wheel style's faces on all
	--            four wheels, every extra that fits, a caliper disc and both plates.
	--   wrap     what wrap vinyl may add on top of that, on a body that takes bands (designs; art bodies take none).
	--            At least Config/Customization.wrapMaxParts.
	-- Why a dressed car gets its own cap rather than cheaper wheel faces: every part a look adds is welded to the
	-- Chassis or a wheel, weightless, and never collides, touches or takes a raycast, so it adds no physics body and
	-- no collision work. Each is a small block or cylinder (the busiest wheel face is a few hundred triangles; one
	-- art body mesh is up to 20,000). What it costs is a transform each frame while the car moves: at about 1 µs a
	-- part on a phone (Dev/TrafficTests measured about 1.7 µs a part for pods moved from Lua, the slow way), 25 fully
	-- dressed cars in view is about 3 ms of a phone's 33 ms frame. Cheaper faces would mean fewer spokes than the
	-- styles players have already bought show. Dev/PerfTests measures the real frame time.
	parts = {
		model = 60,
		dressed = 120,
		wrap = 48,
	},

	meshes = {
		-- Triangles at the top level of detail. A generated look (Vehicle/GeneratedAdapter): all the meshes it keeps
		-- together (its four generated wheels are dropped; the kit wheels stay). An art mesh (Dev/ArtPass): each piece.
		maxTriangles = 20000,
		-- Whether a generated look whose triangles can't be counted (no readable mesh behind a part) is refused like
		-- a big one (the design then shows its kit build). Off until the counter is proven on real GenerationService
		-- output: a Studio playtest with the real backend and one live-server check. Until then such a look is taken
		-- and the server prints "[DesignerService] ... takes its generated look uncounted (couldn't count ...)";
		-- turn this on once that line never appears (record it in docs/PROGRESS.md).
		rejectUncounted = false,
	},

	-- Workspace streaming for the highway. Cars drive on Workspace.Map.Generated Ground and Roads, which are
	-- Persistent models (Dev/MapBuilder, checked by Dev/MapCheck), so no speed can outrun the road. What streams is
	-- everything else: buildings, streetlights, sidewalks, lots, landmarks, houses and other players' cars. The map is
	-- 10,000 studs across (Config/World mapHalfExtent); the County Loop is a 6,800-stud square ring with 5,400-stud
	-- straights at 70 mph (Config/RoadGraph), 112 studs/s at Config/World's 0.28 m a stud; the fastest class tops out
	-- at 240 mph (Config/Classes hypercar), 383 studs/s.
	streaming = {
		enabled = true,
		-- Always loaded round the player, even when a phone is short of memory, and loaded before the player can
		-- start. 512 is 4.6 s of driving at 70 mph before a building could be missing (time for a streaming request
		-- on a phone connection), 1.3 s at 240 mph. Up from 256 (2.3 s at 70 mph); not more, since this area is held
		-- however short of memory a phone is, and it adds to join time.
		minRadius = 512,
		-- Loaded as memory allows: 18 s of highway ahead at 70 mph and 5.3 s at 240 mph, so a straight's buildings
		-- are there long before you reach them. About 13 % of the map's area; a phone short of memory streams the
		-- far part out first.
		targetRadius = 2048,
		-- Content past the target radius goes even without memory pressure, so a lap of the loop doesn't keep the
		-- whole county in a phone's memory.
		outBehavior = "Opportunistic",
		-- Never pause a driver for missing content: the road under them is persistent anyway.
		integrityMode = "Disabled",
		-- tests/PartBudget.spec: minRadius covers this many seconds at the fastest highway limit, and targetRadius
		-- this many at the fastest class's top speed.
		leadSeconds = 4,
	},

	dev = {
		-- Services/DevPerfService stops sampling by itself after this long (a test that died never leaves it running).
		maxSampleSeconds = 900,
		messages = {
			studioOnly = "Studio only.",
			started = "Sampling the server's frame times.",
			notRunning = "Not sampling: send start first.",
			stopped = "Sampled %d server frames over %.1f s.", -- frames, seconds
		},
	},
}

-- Mean, p95 (nearest rank, Perf.frame.percentile) and max of frame times in ms. Zeros for no samples.
function Perf.summarize(samples: { number }): Summary
	local count = #samples
	if count == 0 then
		return { samples = 0, meanMs = 0, p95Ms = 0, maxMs = 0 }
	end
	local sorted = table.clone(samples)
	table.sort(sorted)
	local total = 0
	for _, value in sorted do
		total += value
	end
	local rank = math.clamp(math.ceil(Perf.frame.percentile * count), 1, count)
	return { samples = count, meanMs = total / count, p95Ms = sorted[rank], maxMs = sorted[count] }
end

-- Whether a summary's mean and its p95 are within a budget (each on its own).
function Perf.meets(summary: Summary, budget: FrameBudget): (boolean, boolean)
	return summary.meanMs <= budget.meanMs, summary.p95Ms <= budget.p95Ms
end

return Perf
