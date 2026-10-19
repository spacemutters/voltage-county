--!strict
-- Layout of the dev test track (PLAN.md Phase 1: "Workspace.DevTrack (straight, skidpad, bumps)").
-- server/Dev/DevTrackBuilder builds it in Edit mode from these numbers. Dev/AutoDriver and the specs drive to
-- the waypoints at the bottom, which are derived from the layout, so moving a section moves its waypoints too.
--
-- All lengths are in studs. The SpawnLocation sits at the origin and the baseplate top is y = 0. Every section
-- starts about 60 studs from the spawn and runs north (north is -Z, the way a car faces with no rotation).
-- Parts may run past the edge of the 2048-stud baseplate, but everything stays within World.mapHalfExtent of
-- the origin.
--
-- Seen from above with north up, the three sections sit side by side just north of the spawn: the bumps lane
-- on the west (x = -60), the long straight in the middle (x = 0) and the skidpad on the east, centered at
-- (200, -300).

local World = require(script.Parent.World)

-- Top of every driving surface: just above the baseplate top, so the two never z-fight.
local SURFACE_Y = 0.1

local straight = {
	centerX = 0,
	nearZ = -60, -- the end nearest the spawn; the straight runs toward -Z from here
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
	centerX = 200, -- east of the straight, clear of it by more than 40 studs
	centerZ = -300,
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
	centerX = -60, -- west of the straight
	nearZ = -60,
	length = 940, -- stays on the baseplate (its edge is at z = -1024)
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
	surfaceY = SURFACE_Y,
	surfaceThickness = 1, -- driving surfaces are slabs this thick, sunk into the baseplate below their top
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
