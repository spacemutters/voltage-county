--!strict
-- Layout of the dev test track (PLAN.md Phase 1: "Workspace.DevTrack (straight, skidpad, bumps)").
-- server/Dev/DevTrackBuilder builds it in Edit mode from these numbers. Dev/AutoDriver and the specs drive to
-- the waypoints at the bottom, which are derived from the layout, so moving a section moves its waypoints too.
--
-- Where it sits (Phase 2): out in the open country west of the County Loop, so the county map never touches
-- it. Every position is an offset from ORIGIN, the track's reference point on the ground just south of the
-- straight (where the Phase 1 spawn stood); move ORIGIN to move the whole track. tests/DevTrack.spec checks the
-- track stays inside World.mapHalfExtent, at least 300 studs clear of the County Loop road and outside every
-- MapLayout zone.
--
-- All lengths are in studs; north is -Z (the way a car faces with no rotation) and the county ground top is
-- y = 0. Seen from above with north up, the three sections sit side by side and run north from about 60 studs
-- past ORIGIN: the bumps lane on the west (ORIGIN.X - 60), the long straight in the middle (ORIGIN.X) and the
-- skidpad on the east, centered 200 studs east and 300 north of ORIGIN. The whole track spans roughly
-- x = -4,480..-4,060 and z = +1,440..-1,570, with the loop road about 3,400 studs out from the county centre.

local World = require(script.Parent.World)

-- The track's reference point (see the header). Y is the ground top under it.
local ORIGIN = Vector3.new(-4400, 0, 1500)

-- Top of every driving surface: just above the county ground, so the two never z-fight.
local SURFACE_Y = ORIGIN.Y + 0.1

local straight = {
	centerX = ORIGIN.X,
	nearZ = ORIGIN.Z - 60, -- the end nearest ORIGIN; the straight runs toward -Z from here
	length = 3000, -- at least 2,400 (Phase 1): long enough for the Arc to pass 60 mph and settle
	lanes = 3,
	laneWidth = World.laneWidth,
	width = 3 * World.laneWidth, -- 36
	segmentLength = 500, -- a single part can be at most 2,048 studs long
	startFromNear = 40, -- start line, measured from the near end
	finishFromStart = 2600, -- finish line, measured from the start line; past it is run-off
	dashLength = 12, -- lane dividers
	dashGap = 18,
	lineWidth = 0.6,
	edgeInset = 1, -- edge lines sit this far inside the asphalt edge
	checkerSize = 3, -- start and finish lines are two rows of checker squares
	boardEvery = 400, -- distance boards (studs from the start line) stand along the right-hand side
	boardOffset = 6, -- boards and gantry posts stand this far outside the asphalt
	barrierHeight = 6, -- wall across the far end of the run-off
	barrierThickness = 4,
}

local skidpad = {
	centerX = ORIGIN.X + 200, -- east of the straight, clear of it by more than 40 studs
	centerZ = ORIGIN.Z - 300,
	lineRadius = 120, -- the painted circle cars follow (skidpadRadius below)
	innerRadius = 100, -- the asphalt ring runs from innerRadius to outerRadius
	outerRadius = 140,
	lineWidth = 1.2,
	loopPoints = 12, -- waypoints around the painted circle (skidpadLoop below)
	markerInset = 4, -- a marker post stands on the infield this far inside the ring, opposite each loop point
	markerDiameter = 1.2,
	markerHeight = 2.5,
}

local bumps = {
	centerX = ORIGIN.X - 60, -- west of the straight
	nearZ = ORIGIN.Z - 60,
	length = 940, -- the Phase 1 length (it had to fit on the old 2,048-stud baseplate)
	width = 2 * World.laneWidth,
	segmentLength = 470,
	waypointInset = 40, -- bumpsStart and bumpsEnd sit this far inside each end of the lane
	-- Rounded speed humps: a circular arc `height` tall and `chord` long, laid across the lane. Sized to be
	-- crossed at 40 mph by every Ohm car: the height stays under the lowest ride height (the Arc's 0.45), so
	-- the chassis box clears a hump even when the hump is between the axles.
	height = 0.3,
	chord = 12,
	at = { 300, 370, 440, 510, 580, 650 }, -- hump centers, measured from the near end (a 300-stud run-up)
	signMph = 40,
}

-- Start and finish gantries span the straight. Their boards clear the tallest Ohm vehicle (the Hauler, 12.5).
local gantry = {
	height = 18,
	postSize = 1.5,
	beamHeight = 1.5,
	boardWidth = 16,
	boardHeight = 4,
	boardThickness = 0.4,
}

-- Distance boards and the bumps-lane sign.
local signs = {
	postSize = 0.8,
	postHeight = 6,
	boardWidth = 8,
	boardHeight = 3,
	boardThickness = 0.4,
	pixelsPerStud = 40, -- SurfaceGui resolution
}

local colors = {
	asphalt = Color3.fromRGB(54, 56, 60),
	paint = Color3.fromRGB(236, 236, 230),
	checkerDark = Color3.fromRGB(24, 24, 26),
	infield = Color3.fromRGB(86, 122, 70),
	bump = Color3.fromRGB(232, 186, 48),
	barrier = Color3.fromRGB(190, 52, 46),
	post = Color3.fromRGB(70, 72, 78),
	board = Color3.fromRGB(28, 30, 34),
	text = Color3.fromRGB(245, 245, 240),
	marker = Color3.fromRGB(240, 120, 36),
}

-- Points around a circle at y = SURFACE_Y, starting on the west side (nearest the straight) and running
-- clockwise seen from above with north up. The first point is repeated at the end so a run closes the lap.
local function loop(centerX: number, centerZ: number, radius: number, count: number): { Vector3 }
	local points = {}
	for i = 0, count do
		local angle = math.pi + i * 2 * math.pi / count
		table.insert(
			points,
			Vector3.new(centerX + radius * math.cos(angle), SURFACE_Y, centerZ + radius * math.sin(angle))
		)
	end
	return points
end

local startZ = straight.nearZ - straight.startFromNear

local DevTrack = {
	origin = ORIGIN,
	-- Where to put a character to test on the track: above ORIGIN, facing north up the straight. A character's
	-- pivot (its root part) sits about 3 studs above its feet, so this is 4 up and the character drops onto the
	-- ground. In a playtest: character:PivotTo(DevTrack.arrival), then spawn a car from the dev menu.
	arrival = CFrame.new(ORIGIN + Vector3.new(0, 4, 0)),

	surfaceY = SURFACE_Y,
	surfaceThickness = 1, -- driving surfaces are slabs this thick, sunk into the ground below their top
	paintRaise = 0.03, -- each paint layer sits this far above the one below it (avoids z-fighting)
	paintThickness = 0.05,
	partsPerChunk = 25, -- the builder yields (task.wait) after this many parts so Studio stays responsive

	straight = straight,
	skidpad = skidpad,
	bumps = bumps,
	gantry = gantry,
	signs = signs,
	colors = colors,

	-- Waypoints (all on the driving surface). The straight runs from straightStart toward straightEnd (-Z).
	straightStart = Vector3.new(straight.centerX, SURFACE_Y, startZ), -- start line, middle lane
	straightEnd = Vector3.new(straight.centerX, SURFACE_Y, startZ - straight.finishFromStart), -- finish line
	skidpadCenter = Vector3.new(skidpad.centerX, SURFACE_Y, skidpad.centerZ),
	skidpadRadius = skidpad.lineRadius,
	skidpadLoop = loop(skidpad.centerX, skidpad.centerZ, skidpad.lineRadius, skidpad.loopPoints),
	bumpsStart = Vector3.new(bumps.centerX, SURFACE_Y, bumps.nearZ - bumps.waypointInset),
	bumpsEnd = Vector3.new(bumps.centerX, SURFACE_Y, bumps.nearZ - bumps.length + bumps.waypointInset),
}

return DevTrack
