--!strict
-- Tunables for hailing a pod (PLAN.md Phase 9; docs/phase-9-contracts.md "Hail a pod"): fast travel from the
-- phone's GPS app to any GPS destination in an Ohm Pod.
--
-- Read by Services/HailService (the fare it charges, the ride time, the cooldown, where the rider is let off and
-- what players are told), Controllers/HailController (the fare estimates in the GPS app and the ride cutscene)
-- and UI/Phone/GpsApp (through HailController). The fare and ride-time math lives here as two pure functions,
-- fareFor and secondsFor, so the server's charge and the client's estimate are always worked out the same way;
-- the server's charge is the truth. Distances are studs of road along the shared Pathfind route.

local Gps = require(script.Parent.Gps)
local World = require(script.Parent.World)

local Hail = {
	-- The fare: baseFare + farePerStud x the route's studs of road, rounded to whole dollars. A ride across
	-- Cedar Bend (~1,500 studs) is about $90; one across the county (~8,000 studs) about $350, well under what a
	-- minute of any job pays (Config/Economy activities).
	baseFare = 30,
	farePerStud = 0.04,
	-- A place closer than this (studs of road) is a walk, not a ride: the server says you're already there.
	minStuds = 200,

	-- How long the ride takes: secondsPerStud x the route's studs, kept within minSeconds..maxSeconds.
	minSeconds = 5,
	maxSeconds = 12,
	secondsPerStud = 0.0015,

	-- Seconds after a ride ends at its destination before the player can hail again. A refunded ride starts none.
	cooldownSeconds = 15,

	-- The HailRide route: the Pathfind polyline cut down to at most this many points (the start kept as it is).
	routeMaxPoints = 64,

	-- EconomyService reasons: the fare is a sink, a refund gives it back.
	economyReason = "hail",
	refundReason = "refund",

	-- Where the rider is let off: beside the road nearest the destination, on the destination's side.
	dropOff = {
		-- A road with no sidewalk (highway, ramp, bridge, trail): stand on its shoulder, this far in from the
		-- road's edge (never off a bridge). Roads with a sidewalk let you off in the middle of it.
		shoulderInset = 1.5,
		-- The ground under the drop-off point is found with a ray from this far above the road down to this far
		-- below it (the sidewalk sits a little above the road surface).
		probeUp = 8,
		probeDown = 24,
		-- Studs along the road either side of the drop-off point that set which way the road runs there.
		headingStuds = 6,
		-- The area around the drop-off point is streamed to the rider's client from the start of the ride. If it
		-- still isn't in when the ride ends, the rider stays anchored at the drop-off point until it is, for at
		-- most this many seconds, so they can't fall through ground that hasn't loaded. Keep it no longer than
		-- cutscene.arriveTimeoutSeconds, so the black screen covers the wait.
		streamWaitSeconds = 4,
	},

	-- Fare estimates on the client (the GPS app's Hail buttons) are worked out again once the character has
	-- moved this far (studs) since the last time.
	quote = {
		refreshStuds = 40,
	},

	-- The ride cutscene on the rider's client (Controllers/HailController).
	cutscene = {
		-- The LocalPlayer attribute that is true while a cutscene plays: the HUD, touch controls and phone hide.
		attribute = "Cutscene",
		-- The pod: a local clone of ReplicatedStorage.<templateFolder>.<templateName> (TrafficService puts it
		-- there), or a plain box of the pod's size (Config/Vehicles ohm_pod geometry) when it is missing.
		templateFolder = "TrafficModels",
		templateName = "ohm_pod",
		vehicleId = "ohm_pod",
		fallbackColor = Color3.fromRGB(232, 236, 240),
		-- The box's size (X across, Y up, Z front to back) only if Config/Vehicles has no geometry for vehicleId.
		fallbackSize = Vector3.new(6, 5, 10),
		folderName = "HailRide", -- Workspace.<folderName> holds the pod, on this client only
		-- The glide: up to glideSpeed studs/s (slower on a short route, so it never runs past the end), reached
		-- smoothly over accelSeconds, in the right-hand lane (laneOffset studs right of the centre line).
		glideSpeed = 70,
		accelSeconds = 1.2,
		laneOffset = World.laneWidth / 2,
		-- Studs of route either side of the pod that set which way it faces, so it turns smoothly at corners.
		headingStuds = 8,
		-- The camera: behind and above the pod (pod space: +Y up, +Z behind), looking at a point ahead of it,
		-- easing toward that spot (closes 1 - exp(-cameraStiffness x dt) of the gap each frame).
		cameraOffset = Vector3.new(0, 7, 20),
		lookAhead = 14,
		lookHeight = 2,
		cameraStiffness = 5,
		fov = 62,
		-- The fade: it starts fadeOutSeconds before the ride's end, stays black at least minBlackSeconds and
		-- until the character has arrived (within arriveRadius studs of the drop-off point, and no longer held
		-- anchored there) or arriveTimeoutSeconds past the ride's end, then fades back in over fadeInSeconds.
		fadeOutSeconds = 0.6,
		fadeInSeconds = 0.6,
		minBlackSeconds = 0.3,
		arriveRadius = 16,
		arriveTimeoutSeconds = 4,
		-- The glide always gets at least this long, however short the ride.
		minGlideSeconds = 2,
		-- The black screen sits above the HUD, GPS, phone and shop, and below notices (Theme displayOrder), so
		-- "Pod's on its way" stays readable.
		fadeDisplayOrder = 9,
		fadeColor = Color3.fromRGB(0, 0, 0),
	},

	-- What players are told. %s is a place's name or an amount of cash ($125); %d is seconds.
	messages = {
		onTheWay = "Pod's on its way. The ride is %s.",
		arrived = Gps.messages.arrived, -- the GPS's own words, so arriving at a routed place shows one notice
		refunded = "Your ride was cancelled, so you got your %s back.",
		onFoot = "You can hail a pod on foot. Get out of the car first.",
		notReady = "You can hail a pod once you're back on your feet.",
		inJob = "Finish or cancel your job before you hail a pod.",
		riding = "You're already on your way.",
		cooldown = "You can hail another pod in %d seconds.",
		unknownPlace = "That place isn't on the map.",
		noRoute = "No pod can get to %s from here.",
		alreadyThere = "You're already at %s.",
		cantAfford = "You need %s for this ride.",
		failed = "Couldn't reach a pod. Try again in a moment.",
	},
}

-- A route length the math can use: a finite number of studs, 0 for anything else (negative, NaN, infinite).
local function cleanStuds(studs: number): number
	if studs ~= studs or studs <= 0 or studs == math.huge then
		return 0
	end
	return studs
end

-- The fare in whole dollars for a route of `studs` studs of road (never below baseFare).
function Hail.fareFor(studs: number): number
	return math.floor(Hail.baseFare + Hail.farePerStud * cleanStuds(studs) + 0.5)
end

-- The ride's length in seconds for a route of `studs` studs of road, within minSeconds..maxSeconds.
function Hail.secondsFor(studs: number): number
	return math.clamp(cleanStuds(studs) * Hail.secondsPerStud, Hail.minSeconds, Hail.maxSeconds)
end

return Hail
