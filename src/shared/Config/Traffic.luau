--!strict
-- Tunables for the ambient pods, which double as ambient traffic (PLAN.md Phase 9; docs/phase-9-contracts.md
-- "Ambient pods = ambient traffic"):
--   pods      how many pods drive the county, how far apart they start, and the server's random seed
--   route     how the server picks each pod's next route and when it publishes it (Services/TrafficService)
--   speed     each route's speed profile: under every road's limit and slower through bends (Road/TrafficPath)
--   lane      where on the road a pod drives (Road/TrafficPath)
--   yield     how a pod slows behind a player's car on one client and catches up after (Controllers/TrafficController)
--   render    which pods a client draws, and how (Controllers/TrafficController)
--   models    the pod model the server publishes for every client (Services/TrafficService, TrafficController and
--             Controllers/HailController)
--   fallback  the plain box a client draws when that model never arrives
--
-- Speeds are mph and accelerations are in g; Road/TrafficPath turns them into studs with Util/Units and Config/World.
-- A pod never drives over a road's limit: speed.byKind x speed.scaleMax x (1 + yield.catchUp) stays under 1 for
-- every kind of road (tests/Traffic.spec checks it).

local RoadGraph = require(script.Parent.RoadGraph)

local Traffic = {
	pods = {
		count = 12, -- ambient pods on every server (at most 255: the route payload numbers them in a byte)
		-- Studs between any two pods' first start nodes, when the server can find room (it tries route.tries nodes).
		spacing = 300,
		-- The server's Random seed. 0 picks a new one each server (printed in Studio, so a run can be repeated).
		seed = 0,
	},

	route = {
		-- A route's length along the road, in studs. Shorter or longer paths are used only when route.tries random
		-- destinations found nothing in the band.
		minLength = 1500,
		maxLength = 4500,
		tries = 16, -- random destinations tried for each route
		-- Seconds before a pod's route ends that the server picks and publishes its next one, so every client has it
		-- in hand before the pod gets there. Shorter than the quickest route.
		sendAhead = 6,
		-- A destination whose fastest path starts straight back the way the pod came counts as this many studs
		-- outside the length band (the pod would turn round where it stopped).
		uTurnPenalty = 2000,
		-- Pods never head for a node on a road of these kinds (they still cross them when that is the fastest way).
		avoidKinds = { "dirt" } :: { RoadGraph.Kind },
		-- ...nor for a dead end: a destination needs at least this many roads meeting there.
		minRoads = 2,
		-- Seconds a pod rests where each route starts (a rider getting out and the next one in).
		dwellSeconds = 2,
		-- Seconds before trying again when no route could be found from where a pod stands.
		retrySeconds = 5,
	},

	speed = {
		-- Cruise speed on each kind of road, as a fraction of the road's limit.
		byKind = {
			highway = 0.85,
			arterial = 0.88,
			street = 0.88,
			ramp = 0.8,
			bridge = 0.85,
			dirt = 0.7,
		} :: { [RoadGraph.Kind]: number },
		otherKinds = 0.8, -- a road kind added later and not listed above
		-- Each route's speeds are scaled by a random factor in this range, so pods don't all drive alike.
		scaleMin = 0.92,
		scaleMax = 1,
		accelG = 0.12, -- pulling away and speeding up
		decelG = 0.2, -- slowing for a bend or a stop
		lateralG = 0.25, -- the most cornering a pod allows itself
		-- A bend may start at most this many studs before its node (and end as far after it), however long the roads
		-- either side: a turn at a junction is taken as tight as a junction, not as a sweeping curve.
		cornerSpan = 60,
		minCornerMph = 4, -- the slowest any bend is taken (a U-turn)
	},

	lane = {
		-- Pods drive on the right, this many lane widths (Config/World) right of a road's centre line: the middle of
		-- the nearest right-hand lane.
		offsetLanes = 0.5,
		-- Where the road turns back harder than this (the cosine of the angle between the two directions), the lane
		-- line crosses straight over to the other side instead of mitring the corner (a U-turn). -0.5 = 120 degrees.
		sharpTurnDot = -0.5,
	},

	yield = {
		lookAhead = 45, -- studs ahead of a drawn pod that a player's car makes it slow down
		laneHalfWidth = 7, -- a car whose centre is within this many studs either side of the pod's line is in its lane
		heightReach = 8, -- ...and within this many studs above or below it (not on a bridge overhead)
		gap = 14, -- studs (centre to centre) a pod keeps behind a car
		-- Speed allowed behind a car: the car's own speed plus this many studs/s for every stud of room past `gap`.
		followGain = 0.8,
		brakeResponse = 5, -- 1/s: how quickly a pod slows when it has to
		releaseResponse = 1.5, -- 1/s: how quickly it picks up again
		-- Running behind its schedule, a pod drives this much faster than the schedule until it is back on it.
		catchUp = 0.1,
		-- Held almost still (under holdRate of its scheduled speed) behind a car for maxHoldSeconds, a pod drives on
		-- through it for passSeconds (it never collides with anything).
		holdRate = 0.05,
		maxHoldSeconds = 8,
		passSeconds = 4,
		-- A pod nobody here can see that is more than this many seconds behind its schedule drops back onto it.
		maxDelay = 30,
	},

	render = {
		folderName = "TrafficPods", -- Workspace.<folderName>: this client's pod copies (never replicated)
		distance = 700, -- studs from the camera within which a pod is drawn
		hysteresis = 60, -- ...and it stays drawn until this much farther
		hiddenCheckSeconds = 0.25, -- how often a pod that isn't drawn is looked at
		-- A drawn pod farther than farDistance studs from the camera moves on every farInterval-th frame only (each
		-- on its own frame, by pod number): at that range the steps can't be seen, and most drawn pods are that far.
		farDistance = 300,
		farInterval = 2,
		-- A pod faces along its lane line from this many studs behind it to as many ahead (so it turns through a
		-- bend rather than snapping at the node), then its heading is smoothed at yawResponse (1/s).
		headingSpan = 4,
		yawResponse = 10,
		-- It leans out of a turn by bankDegPerG degrees for each g of cornering, at most maxBankDeg, smoothed at
		-- bankResponse (1/s).
		bankDegPerG = 6,
		maxBankDeg = 3,
		bankResponse = 4,
		maxRoutes = 4, -- routes a client keeps per pod (the one driven and those after it)
		statRing = 600, -- recent step times kept for TrafficController.stats()
		modelWaitSeconds = 15, -- how long a client waits for the pod model before it draws plain boxes
	},

	models = {
		folderName = "TrafficModels", -- ReplicatedStorage.<folderName>, made by the server at start
		modelName = "ohm_pod", -- the pod model in it
		-- Cloned from this trim's greybox in ServerStorage.<Config/Spawning modelsFolder> (Vehicle/Catalog.modelName).
		vehicleId = "ohm_pod",
		trimId = "standard",
		podAttribute = "TrafficPod", -- set true on the model, so nothing mistakes a pod for a car
		-- Every part of a drawn pod moves every frame, and the cost grows with the part count (12 pods drawn at once
		-- in Studio: the full 34-part greybox took ~0.68 ms a frame to move, these trimmed ~19 parts ~0.43 ms). The
		-- template drops the small details nobody reads on passing traffic (by part name) and every light.
		dropParts = { "Sensor", "LidarL", "LidarR", "Rim", "Spoke", "Brake", "Reverse", "HeadL", "HeadR" },
		dropLights = true,
	},

	fallback = {
		size = Vector3.new(6, 5.2, 10), -- studs: about the Ohm Pod's width, height and length
		color = Color3.fromRGB(205, 210, 218),
		material = Enum.Material.SmoothPlastic,
	},
}

return Traffic
