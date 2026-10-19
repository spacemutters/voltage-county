--!strict
-- Driving camera tunables, read by Controllers/CameraController (PLAN.md Phase 1, "Camera").
--
-- Units: studs, degrees, mph and seconds. A "stiffness" is a rate per second: each frame a smoothed value closes
-- 1 - exp(-stiffness * dt) of the gap to its target, so the camera feels the same at 30 and 144 fps. Bigger is
-- snappier: 10 is mostly there in about 0.2 s, 2 takes about a second.
--
-- Chase and orbit distances are tuned for a car as long as the Ohm Spark (`referenceLength`) and scale with the
-- length of the car being driven, so a semi tractor gets a camera further back than a two-seat pod.

export type Mode = "chase" | "orbit" | "hood"

export type FovRange = {
	min: number, -- vertical field of view (degrees) when stopped
	max: number, -- field of view at `fullAtMph` and above
	fullAtMph: number,
}

-- The camera button cycles through these in order; the first is the view every drive starts in.
local MODES: { Mode } = { "chase", "orbit", "hood" }

local Camera = {
	modes = MODES,

	-- Car size scaling: chase and orbit distances are multiplied by carLength / referenceLength, clamped.
	referenceLength = 14,
	minSizeScale = 0.8,
	maxSizeScale = 2.8,

	-- A car moving further than this in one frame was teleported or reset: the camera snaps instead of swinging.
	snapDistance = 60,

	-- How quickly the field of view follows its target (all modes).
	fovStiffness = 3,

	chase = {
		distance = 16, -- behind the car's center
		height = 5, -- above the car's center
		lookHeight = 2.5, -- the camera aims this far above the car's center...
		lookAhead = 6, -- ...and this far ahead of it, so the car sits low in the frame with road ahead
		distancePerMph = 0.035, -- pulls back a little as speed builds...
		maxExtraDistance = 5, -- ...up to this much
		distanceStiffness = 2,
		headingStiffness = 5, -- how quickly it swings round behind the car in a turn
		heightStiffness = 8, -- how quickly it follows the car up and down (soaks up bumps)
		maxHeightLag = 3, -- never trails the car vertically by more than this (jumps and drops)
		fov = { min = 70, max = 86, fullAtMph = 130 } :: FovRange,
	},

	orbit = {
		distance = 18,
		defaultPitch = 12, -- degrees above the horizon, looking down at the car; where it returns to
		minPitch = -5,
		maxPitch = 70,
		mouseDegreesPerPixel = 0.3,
		touchDegreesPerPixel = 0.4,
		stickDegreesPerSecond = 180, -- right stick at full tilt
		stickDeadzone = 0.15,
		returnDelay = 2.5, -- seconds without input before it drifts back behind the car
		returnStiffness = 2,
		fov = 70,
		-- Holding either button and moving the mouse orbits (clicks on buttons and menus are left alone).
		mouseButtons = { Enum.UserInputType.MouseButton2, Enum.UserInputType.MouseButton1 },
	},

	hood = {
		offset = Vector3.new(0, 0.3, 0), -- from the car's CameraHood attachment, in the attachment's own space
		pitch = -4, -- degrees; a slight downward tilt shows the road just ahead of the hood
		rotationStiffness = 20, -- light smoothing on body shake; the position stays locked to the car
		-- Without a CameraHood attachment: this fraction of the car's height above its center, and this fraction
		-- of its length ahead of it.
		fallbackHeight = 0.45,
		fallbackForward = 0.15,
		focusDistance = 30, -- studs ahead treated as the point of interest (Camera.Focus, for detail streaming)
		fov = { min = 74, max = 90, fullAtMph = 130 } :: FovRange,
	},

	collision = {
		enabled = true, -- pull the camera in front of walls between it and the car
		margin = 0.6, -- keeps the lens this far off the wall it was pulled in by
		returnStiffness = 4, -- eases back out once the obstacle clears
		carClearance = 1.5, -- stays this far outside the car's bounding sphere, so it never clips into the car
	},
}

return Camera
