--!strict
-- Tunables for the Phase 2 "GPS, spawn flow, notices" section (docs/phase-2-contracts.md):
--   route, marker, tracking   the GPS route line and how it follows the player (Controllers/GpsController)
--   panel                     the GPS button, route chip and destination list (UI/GpsPanel)
--   toast                     short on-screen notices (Controllers/NotifyController, UI/Toast)
--   spawnFlow                 the "Claim your free car" stub at the used lot (Services/SpawnFlowService)
--
-- GUI sizes are pixels at UI scale 1 (a landscape phone, Config/Controls `hud.referenceShortSide`). The UI only
-- ever scales up from there, so every touch target listed here stays at least `panel.minTarget`.

local Controls = require(script.Parent.Controls)

local touch = Controls.touch

local Gps = {
	-- The route line: flat Beams between Attachments, drawn on the client only (Workspace.GpsRoute).
	route = {
		folderName = "GpsRoute", -- Workspace.<folderName>, created by the client, never replicated
		carrierName = "Carrier", -- the invisible anchored part that holds the route's attachments
		color = Controls.theme.accent, -- one clean color, the same accent as the driving HUD
		width = 3.5, -- studs across; a 12-stud lane keeps clear road on both sides
		heightAboveRoad = 0.35, -- studs above the road surface, clear of lane lines
		-- Studs the line is drawn toward the camera, so a distant road never pokes through it.
		zOffset = 0.25,
		transparency = 0.15,
		-- Unlit: the line looks the same color by day and by night.
		lightEmission = 0,
		lightInfluence = 0,
		-- At most this many route points are drawn (so this many minus one beams). The rest of a long route is
		-- drawn as the player gets closer to it.
		maxPointsDrawn = 160,
		-- Points closer than this (studs) to the straight line between their neighbours are dropped before
		-- drawing, so straight roads made of many short edges draw as one beam.
		simplifyTolerance = 0.5,
	},

	-- The marker at the end of the route: a soft light pillar standing on a flat disc.
	marker = {
		pillarHeight = 40, -- studs
		pillarWidth = 3,
		pillarTransparency = { bottom = 0.25, top = 1 }, -- fades out toward the top
		discDiameter = 14,
		discThickness = 0.2,
		discTransparency = 0.45,
	},

	-- How the route follows the player. Checks run on Heartbeat with an accumulator, only while a destination
	-- is set.
	tracking = {
		checkRateHz = 5, -- route checks per second (trim, distance left, off-route, arrival)
		-- Farther than this (studs) from the route counts as off it and asks for a new route.
		offRouteDistance = 45,
		-- Within this many studs of the route's end, or of the destination itself, counts as arrived.
		arriveRadius = 40,
		-- How far ahead along the route (studs) the player's position is looked for each check. A later
		-- stretch of the route that passes close by is never mistaken for the one the player is on.
		searchAhead = 600,
		-- Re-routes need the player to have moved this far (studs) and this long (seconds) since the last
		-- route was made, so a player standing off-road far from any street is not re-routed over and over.
		rerouteMinMove = 30,
		rerouteMinSeconds = 2,
	},

	-- The GPS button (top right, below the touch driving buttons), the active-route chip beside it, and the
	-- destination list that opens in the middle of the screen. Placement is derived from Config/Controls so
	-- the GPS never covers the touch pedals, the touch buttons or the speed panel.
	panel = {
		displayOrder = 1, -- above the driving HUD (0), below notices
		minTarget = 44, -- smallest allowed touch target in either direction, px (Gps.spec checks the sizes)
		margin = touch.margin, -- from the right safe-area edge, lined up with the touch Exit button
		top = touch.margin + touch.buttonSize.Y + touch.gap, -- just below the touch Mode / Camera / Exit row
		gap = touch.gap,
		buttonSize = Vector2.new(68, 52), -- the GPS button
		chipWidth = 220, -- the active-route chip to the left of the button (same height as the button)
		chipPadding = 12,
		chipNameTextSize = 15,
		chipDistanceTextSize = 13,
		endButtonSize = Vector2.new(56, 44), -- ends the active route
		sheetWidth = 340, -- the destination list
		headerHeight = 52,
		closeButtonSize = Vector2.new(72, 44),
		rowHeight = 48,
		sectionHeight = 30,
		maxListHeight = 260,
		listInset = 6, -- space around the rows inside the list
		rowPadding = 14, -- text inset inside a row
		rowCornerRadius = 10,
		cornerRadius = 14,
		scrollBarThickness = 4,
		titleTextSize = 17,
		textSize = 15,
		sectionTextSize = 12,
		buttonTextSize = 15,
		labels = {
			button = "GPS",
			title = "Where to?",
			close = "Close",
			endRoute = "End",
			empty = "No destinations yet.",
			distanceLeft = "%s left", -- %s is the distance, e.g. "1.2 mi"
			markedSpot = "Marked spot", -- a destination given as a point rather than a place
		},
		-- Distance left is shown in miles with this many decimals, and never below `minMiles`.
		milesFormat = "%.1f mi",
		minMiles = 0.1,
	},

	-- What the GPS says (through NotifyController). %s is the destination's name.
	messages = {
		arrived = "You've arrived at %s.",
		noRoute = "Can't find a road to %s from here.",
	},

	-- Short notices at the top centre of the screen, one at a time, queued.
	toast = {
		displayOrder = 10, -- above the HUD and the GPS
		margin = 12, -- from the top safe-area edge
		maxTextWidth = 380, -- px; longer notices wrap
		padding = Vector2.new(16, 12), -- inside the toast (sides, top and bottom)
		gap = 10, -- between the kind dot and the text
		dotSize = 8,
		cornerRadius = 14,
		textSize = 15,
		maxChars = 160, -- longer notices are cut short
		visibleSeconds = 3.5, -- how long a notice stays fully shown
		busyVisibleSeconds = 2, -- the same, when more notices are waiting
		fadeInSeconds = 0.18,
		fadeOutSeconds = 0.35,
		slideOffset = 10, -- px a toast drops in from (and rises out to)
		maxQueued = 4, -- notices waiting beyond this drop the oldest waiting one
		defaultKind = "info",
		-- The dot beside the text shows the kind; the text itself is always the theme's white on a dark panel.
		kindColors = {
			info = Controls.theme.accent,
			success = Color3.fromRGB(96, 214, 150),
			warning = Color3.fromRGB(255, 196, 84),
			error = Color3.fromRGB(255, 112, 112),
		} :: { [string]: Color3 },
	},

	-- Phase 2 stub of the new-player flow (the real claim and saving land in Phase 4).
	spawnFlow = {
		-- Where the map's location parts live (MapBuilder owns Workspace.Map.Generated).
		mapPath = { "Map", "Generated", "Locations" },
		mapWaitSeconds = 10, -- how long the server waits for the map at start before warning
		usedLotTag = "UsedLot", -- CollectionService tags from PLAN.md §5
		spawnPadTag = "SpawnPad",
		vehicleId = "ohm_spark", -- the temporary car: a used Ohm Spark
		trimId = "used",
		seatDriver = true, -- sit the player in the driver seat once the car is out
		cooldownSeconds = 20, -- per player, between claims
		-- A pad counts as taken while another player's car stands within this many studs of its centre; the
		-- nearest free pad to the lot is used (or the nearest pad when all are taken).
		padClearRadius = 12,
		prompt = {
			name = "ClaimCarPrompt",
			attachmentName = "ClaimCarPromptAttachment",
			actionText = "Claim your free car",
			objectText = "Used lot", -- used when the lot part has no DisplayName attribute
			holdSeconds = 0.4,
			maxDistance = 14, -- studs at which the prompt shows
			height = 3, -- studs above the lot surface
			-- The prompt sits on the edge of the lot nearest the player spawns, this far in from the edge.
			edgeInset = 4,
			-- The server re-checks the distance on a trigger, allowing this much extra for lag.
			reachSlack = 6,
		},
		messages = {
			claimed = "Here's a used %s for a test drive. It's yours to try until the garage opens.",
			cooldown = "You just got a car. You can get another in %d seconds.",
			failed = "Your car isn't ready yet. Please try again in a moment.",
		},
	},
}

return Gps
