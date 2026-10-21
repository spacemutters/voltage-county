--!strict
-- Car spawning, seating and parking tunables for Services/VehicleService (PLAN.md Phase 1).

local Spawning = {
	-- Cars a player may have out at once. Spawning another one despawns their oldest first.
	maxCarsPerPlayer = 1,
	-- A parked car that nobody drives is removed after this many minutes.
	despawnAfterMinutes = 10,
	-- Studs between the player and the near end of a car spawned next to them (dev spawn).
	spawnOffset = 6,

	-- Where cars live and how other systems find them.
	vehiclesFolder = "Vehicles", -- Workspace.Vehicles holds every spawned car (created at boot)
	modelsFolder = "VehicleModels", -- ServerStorage.VehicleModels: one model per trim, from Dev/VehicleBuilder
	vehicleTag = "Vehicle", -- CollectionService tag on every spawned car

	-- Seat prompts. Players only get in through these; seats ignore touches (vehicle model contract).
	-- Each client hides the Drive prompt on cars it doesn't own, and every prompt while its character is seated.
	prompt = {
		driveName = "DrivePrompt", -- instance names, so clients can find the prompts
		rideName = "RidePrompt",
		driveText = "Drive", -- on the Driver seat; only the owner can use it
		rideText = "Ride", -- on every passenger seat; anyone can use it
		maxDistance = 10, -- studs at which a prompt shows
		holdSeconds = 0, -- a tap gets you in
	},
	-- When a prompt fires, the server re-checks that the character is at most this many studs from the seat.
	-- A little more than prompt.maxDistance so lag never refuses an honest tap.
	seatReach = 16,
	-- A car swapped out from under its driver leaves the character seated for a moment; the new car's seat waits
	-- for them to be out of the old one, at most this many seconds, before it sits them down.
	reseatTimeoutSeconds = 1,

	-- Getting out: the server stands the character on the ground beside the seat's door (seats sit inside the
	-- collidable chassis box, so standing up in place would shove the character out of it).
	exit = {
		sideGap = 2, -- studs between the chassis side and the character
		r6LegHeight = 2, -- an R6 character's legs below its root part (R15 uses Humanoid.HipHeight)
		clearance = 0.5, -- extra studs above the ground, so the character drops onto it rather than into it
	},

	-- Parking: find the ground under the car and set it down at ride height, keeping its heading.
	park = {
		probeUp = 4, -- start the ground ray this far above the car's pivot (low enough to stay under ceilings)
		probeDown = 200, -- and look this far down for ground; with none, the car parks where it is
		maxGroundTiltDegrees = 30, -- sit flush on slopes up to this steep; on anything steeper, park level
	},
}

return Spawning
