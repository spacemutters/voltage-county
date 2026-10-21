--!strict
-- MapBuilder: builds the greybox county, Workspace.Map.Generated, from Config/MapLayout and Config/RoadGraph
-- (PLAN.md §5 and Phase 2; docs/phase-2-contracts.md, "Map builder").
--
-- Edit-mode tool only (CLAUDE.md hard rule 9). Run it from MCP execute_luau (Edit datamodel) or the command bar:
--   require(game.ServerScriptService.Server.Dev.MapBuilder).build()
-- It owns only Workspace.Map.Generated (and creates the Workspace.Map folder if it is missing).
--
-- Two steps, like Dev/DevTrackBuilder. plan() is pure and deterministic (building placement is seeded by
-- MapLayout.seed): it returns every part the build makes as a PartSpec, so specs and Dev/MapCheck can inspect
-- the county without building it. build() replaces Generated with those parts, yielding between chunks so
-- Studio stays responsive. Building twice gives the same instances.
--
-- What it builds, under Generated:
--   Ground (Model, Persistent)   zone-tinted slabs with their top at y = 0 covering ±World.mapHalfExtent, the lake
--                                beds with sloping banks, the mesas (MapLayout.mesas) and the jump ramps
--   Water                        the lake surfaces (not solid)
--   Roads (Model, Persistent)    Segments: one slab per road edge. Intersections: a pad at every node where
--                                3+ roads meet or a road bends or changes grade. Lines: lane lines and medians
--   Sidewalks                    raised kerbed sidewalks on Cedar Bend and Riverside streets and arterials, cut
--                                for a driveway flush with the road in front of every pad
--   Bridges                      railings, supports under raised roads, fill under low raised roads
--   Lots, Buildings              paved lots and block buildings along town streets (Models per block, Atomic)
--   Landmarks                    the big buildings MapLayout.landmarks names (Models, Atomic)
--   Streetlights                 posts along streets and arterials; only some of them emit light
--   Locations                    one part per MapLayout location (tag, attributes, DisplayName, Zone), with
--                                small props parented to it (charger posts, pumps, signs, gate gantries, the
--                                Wrap & Tint shops' garage doors...); Phase 8's TrailerSpawn, TowDrop and
--                                Breakdown spots get a painted bay only (trailers and cars stand on them)
--   Dealership/<brandId>         Phase 4: a low platform per MapLayout.dealership pad (tag DealershipPad,
--                                attributes BrandId and Index) and the section's brand sign behind its pads
--   UsedLot                      Phase 4: a numbered platform per MapLayout.usedLot pad (tag UsedLotPad,
--                                attribute Index)
--   Billboards                   Phase 12: a panel on two posts per MapLayout billboard (tag Config/Ads.billboards
--                                .tag, attributes BillboardId, BrandId, Zone): an AdGui on its Front face, built
--                                switched off (Services/AdsService decides at runtime), and the brand's poster
--                                painted on its Back face (AdsService copies it to the front while no ads are served)
--   PlayerSpawns                 SpawnLocations at MapLayout.playerSpawns
--
-- Display pads keep buildings, lots, streetlights and props off themselves and off the rectangle round each
-- group of them (so a block given over to the dealership is cleared of buildings), and a note is left if one
-- lands on a road, sidewalk, landmark or location.
--
-- How the roads fit together. A road edge is a straight slab whose top runs between its two nodes' surface
-- heights. Where roads meet, each one is cut back ("trimmed") until it clears its neighbours, and the space
-- between the cut ends is filled flush by a junction pad: a thin flat slab at the node's height, made of
-- blocks and right-angled wedges (two wedges make any triangle). Dev/MapCheck compares road parts as whole
-- boxes, and a wedge's box is twice its triangle, so each pad is a Model (parts in one model are not compared
-- with each other) and every road is cut back a little further by a "throat" block until no pad part's box
-- reaches its slab. Pads are thin so a road climbing into one never digs into it more than TUNING.padMaxDig.
-- Every road surface part is flush with its neighbours: no gaps, no lips, no overlaps beyond a few hundredths of
-- a stud (tests/MapBuilder.spec checks exactly, wedges included).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Config = ReplicatedStorage.Shared.Config
local Ads = require(Config.Ads)
local Brands = require(Config.Brands)
local Dealership = require(Config.Dealership)
local MapLayoutModule = require(Config.MapLayout)
local RoadGraphModule = require(Config.RoadGraph)
local World = require(Config.World)

---------------------------------------------------------------------------------------------------------------
-- Types
---------------------------------------------------------------------------------------------------------------

-- The data shapes MapBuilder reads (docs/phase-2-contracts.md, "Data"). Only what the builder uses; the extra
-- MapLayout fields (lakes, mesas, jump ramps, landmarks, groundHeight) are optional so small fixtures can leave
-- them out.
export type ZoneData = {
	id: string,
	displayName: string,
	min: Vector2,
	max: Vector2,
	groundColor: Color3,
	buildingColors: { Color3 },
	buildingHeight: { min: number, max: number },
	buildingDensity: number,
}

export type LocationData = {
	id: string,
	displayName: string,
	tag: string,
	zone: string,
	position: Vector3,
	yaw: number,
	size: Vector3,
	attributes: { [string]: any }?,
	gps: boolean?,
}

export type LakeData = { id: string, min: Vector2, max: Vector2, waterY: number, bedY: number }
export type MesaData = { id: string, topMin: Vector2, topMax: Vector2, height: number, slope: number }
export type RampData = { id: string, position: Vector3, yaw: number, size: Vector3 }
export type LandmarkData = { id: string, kind: string, position: Vector3, yaw: number, size: Vector3 }
-- Display pads (Phase 4): each pad's CFrame is the centre of its footprint on the ground, facing the way the car
-- on it points; every pad of a layout is padSize.
export type DealershipData = { padSize: Vector3, sections: { { brandId: string, pads: { CFrame } } } }
export type UsedLotData = { padSize: Vector3, pads: { CFrame } }
-- Billboards (Phase 12): see Config/MapLayout's Billboard.
export type BillboardData = {
	id: string,
	zone: string,
	position: Vector3,
	yaw: number,
	size: Vector3,
	clearance: number,
	brandId: string,
}

export type LayoutData = {
	seed: number,
	zones: { [string]: ZoneData },
	zoneOrder: { string },
	locations: { LocationData },
	playerSpawns: { CFrame },
	lakes: { LakeData }?,
	mesas: { MesaData }?,
	jumpRamps: { RampData }?,
	landmarks: { LandmarkData }?,
	dealership: DealershipData?,
	usedLot: UsedLotData?,
	billboards: { BillboardData }?,
	reservedWestOfX: number?, -- nothing but the County Loop west of this x (the dev track's ground)
	groundHeight: ((x: number, z: number) -> number)?,
}

export type NodeData = { id: string, position: Vector3, zone: string }
export type EdgeData = {
	from: string,
	to: string,
	lanes: number,
	speedLimitMph: number,
	surface: string,
	kind: string,
}
export type StyleData = { shoulder: number, sidewalk: number, color: Color3, lineColor: Color3 }
export type GraphData = { nodes: { NodeData }, edges: { EdgeData }, styles: { [string]: StyleData } }

-- What a part is for. Specs and MapCheck group parts by it.
export type Role =
	"road" -- a road segment slab (Roads/Segments)
	| "pad" -- a junction pad piece (Roads/Intersections)
	| "line" -- paint
	| "sidewalk"
	| "ground"
	| "water"
	| "ramp" -- a jump ramp
	| "lot"
	| "building"
	| "landmark"
	| "light" -- streetlight post or head
	| "support" -- bridge railings, pillars and fill
	| "location" -- a MapLayout location's tagged part
	| "prop" -- small things on a location
	| "spawn"
	| "displayPad" -- a dealership or used-lot display platform
	| "sign" -- a dealership brand sign (post and board)
	| "billboard" -- a billboard's panel or one of its posts (Phase 12)

-- Text painted on one face of a part (a SurfaceGui with one TextLabel). `center` and `size` are fractions of the
-- face (defaults: centred, TUNING.labelSize).
export type LabelSpec = { face: Enum.NormalId, text: string, color: Color3, center: Vector2?, size: Vector2? }

-- An AdGui on one face of a part (a billboard's ad unit; Config/Ads). Built switched off: Services/AdsService turns it
-- on at runtime only when ads may be served. `fallbackImage` "" leaves Roblox's default.
export type AdUnitSpec = { name: string, face: Enum.NormalId, enableVideoAds: boolean, fallbackImage: string }

export type LightSpec = {
	kind: "point" | "spot",
	brightness: number,
	range: number,
	angle: number,
	color: Color3,
	face: Enum.NormalId,
}

-- One part of the build. `folder` is the container path below Generated ("Roads/Segments"); every container on
-- it is listed in Plan.containers. A part with `parent` set is parented to the part of that name in `folder`
-- (location props hang under their location part).
export type PartSpec = {
	folder: string,
	parent: string?,
	name: string,
	class: "Part" | "WedgePart" | "CornerWedgePart" | "SpawnLocation",
	shape: "block" | "wedge" | "cornerWedge" | "cylinder",
	role: Role,
	size: Vector3,
	cframe: CFrame,
	color: Color3,
	material: Enum.Material,
	collide: boolean,
	query: boolean,
	touch: boolean,
	shadow: boolean,
	transparency: number,
	tag: string?,
	attributes: { [string]: any }?,
	light: LightSpec?,
	labels: { LabelSpec }?,
	adUnit: AdUnitSpec?,
}

export type Container = { path: string, class: "Folder" | "Model", streaming: Enum.ModelStreamingMode? }

export type Plan = {
	specs: { PartSpec },
	containers: { Container },
	notes: { string }, -- things worth knowing (a road with no room left, a prop that didn't fit...)
	counts: { [string]: number }, -- parts per role
}

---------------------------------------------------------------------------------------------------------------
-- Tuning. A dev tool, so its numbers live here rather than in Shared/Config (like Dev/AutoDriver's TUNING).
---------------------------------------------------------------------------------------------------------------

local TUNING = {
	partsPerChunk = 120, -- build() yields (task.wait) after this many parts
	maxPartSize = 2048, -- Roblox's part size limit per axis

	-- Roads
	roadThickness = 1, -- every road segment is a slab this thick under its surface (contracts)
	padThickness = 0.2, -- junction pads: thin, flat, sitting on the ground when the road is at ground level
	padMaxDig = 0.04, -- studs a road climbing into a pad may dig into its underside (MapCheck allows 0.05)
	miterLimit = 3, -- an outer junction corner comes to a point unless it is this many road half-widths out
	bendTolerance = 0.02, -- two roads meeting at a node overlap by less than this: no pad needed
	crestTolerance = 0.02, -- same, for the bottoms of two slabs meeting over a crest
	throatMin = 1, -- shortest throat block (studs); throats only exist where a pad part needs the room
	throatMargin = 0.1, -- extra throat beyond what a pad part's box needs
	riseSafety = 1.3, -- a climbing road's throat also clears its slab's tilted end by this factor
	minSegment = 0.5, -- shortest road segment slab
	cornerTolerance = 1e-4, -- cosine below which an angle counts as square
	pointTolerance = 1e-3, -- studs; polygon points closer than this are one point
	minSliver = 1e-3, -- twice the area (studs²) of the smallest pad triangle worth a part

	-- Paint (Roads/Lines)
	lineThickness = 0.05,
	lineLift = 0.02, -- gap between the road top and the bottom of its paint
	laneLineWidth = 0.5,
	centerLineWidth = 0.7,
	medianWidth = 1.4, -- highway centre line
	lineEndGap = 0.5, -- paint stops this far from each end of a segment
	centerLineColor = Color3.fromRGB(226, 184, 70),

	-- Sidewalks (contracts: streets and arterials in Cedar Bend and Riverside, raised 0.5, with a kerb)
	sidewalkKinds = { street = true, arterial = true } :: { [string]: boolean },
	sidewalkZones = { cedar_bend = true, riverside = true } :: { [string]: boolean },
	sidewalkRaise = 0.5,
	sidewalkThickness = 1,
	kerbWidth = 0.6,
	minSidewalk = 1, -- shortest sidewalk strip worth a part
	sidewalkMiterTurn = math.rad(45), -- outside a gentler bend the sidewalks run on and overlap; sharper, a
	-- corner piece fills between them
	sidewalkOverlap = 0.05,
	sidewalkCornerLimit = 60, -- no corner piece reaching further than this from the road corner
	sidewalkColor = Color3.fromRGB(176, 172, 164),
	kerbColor = Color3.fromRGB(204, 200, 190),
	-- Driveways: the sidewalk stops in front of every pad and a flush apron at road height fills the gap, so a
	-- car on the pad never meets a kerb taller than its ride height (the lowest car rides 0.45 above the ground).
	drivewayFlare = 4, -- the cut reaches this far past each side of the pad (and is at least accessWidth wide)
	drivewayReach = 12, -- only a pad whose front edge is within this of a sidewalk's outer edge gets a cut
	drivewayColor = Color3.fromRGB(150, 148, 142),

	-- Raised roads (bridge decks and their approaches)
	fillMaxHeight = 6, -- a raised road no higher than this above the ground gets a solid fill under it...
	fillMinHeight = 0.6, -- ...if it is at least this high
	supportMinHeight = 3, -- contracts: supports under any road more than 3 studs above the ground
	pillarSpacing = 80,
	pillarSize = 4,
	pillarPairWidth = 40, -- roads wider than this stand on two pillars, inset this far from each edge:
	pillarInset = 8,
	railMinHeight = 3, -- railings on bridges and on any road higher than this above the ground
	railHeight = 3, -- above the road surface
	railThickness = 0.8,
	railEndGap = 1, -- railings stop this far from each end of a segment
	bury = 1, -- fills, pillars, mesas and buildings reach this far below the ground
	supportColor = Color3.fromRGB(150, 148, 142),
	railColor = Color3.fromRGB(182, 180, 172),

	-- Ground and water
	groundThickness = 8,
	groundMaterial = Enum.Material.Grass,
	countryColor = Color3.fromRGB(152, 148, 104), -- outside every zone
	mesaColor = Color3.fromRGB(178, 142, 102),
	bankRun = 3, -- lake banks slope down this many studs per stud of depth
	waterColor = Color3.fromRGB(70, 118, 150),
	waterTransparency = 0.3,
	lakeBedColor = Color3.fromRGB(116, 104, 82),
	rampColor = Color3.fromRGB(160, 120, 84),

	-- Streetlights (contracts: posts along streets and arterials; at most one emitting light per 200 studs)
	lightKinds = { street = true, arterial = true } :: { [string]: boolean },
	lightInterval = 110,
	lightEmitSpacing = 200,
	lightEndGap = 14, -- no post within this of a segment's ends (junction corners)
	lightVerge = 3, -- without a sidewalk, posts stand this far outside the road edge...
	lightSidewalkInset = 1.2, -- ...with one, this far inside the sidewalk's outer edge
	postSize = 0.6,
	postHeight = 16,
	headSize = Vector3.new(1.4, 0.5, 3),
	headReach = 1.6, -- the head hangs this far toward the road
	lightRange = 48,
	lightBrightness = 2,
	lightAngle = 120,
	lightColor = Color3.fromRGB(255, 222, 170),
	postColor = Color3.fromRGB(70, 72, 76),
	headColor = Color3.fromRGB(255, 236, 196),

	-- Lots and buildings
	buildingKinds = { street = true, arterial = true } :: { [string]: boolean },
	frontageGap = 2, -- lots start this far outside the sidewalk (or the road edge)
	lotMin = 26,
	lotMax = 52,
	setbackMin = 3,
	setbackMax = 9,
	depthMin = 20,
	depthMax = 44,
	buildingGap = 5, -- between neighbouring buildings
	cornerClear = 12, -- lots stop this far from a segment's cut ends
	clearance = 2, -- studs kept between a lot and any road, sidewalk, pad or prop
	locationMargin = 10, -- lots keep this far from a location's footprint...
	accessWidth = 30, -- ...and out of a corridor this wide from it to its road
	blockTile = 500, -- a block's buildings are split into Models no wider than this
	lotThickness = 0.1,
	minLotRow = 2, -- buildings in a row before they get a paved lot
	lotColor = Color3.fromRGB(150, 148, 142),
	buildingMaterial = Enum.Material.SmoothPlastic,
	maxLevelError = 0.05, -- lots and buildings only stand where the ground is flat at y = 0

	-- Landmarks: an accent part by kind on the side the landmark faces
	landmarkColors = {
		showroom = Color3.fromRGB(214, 214, 210),
		office = Color3.fromRGB(176, 166, 150),
		factory = Color3.fromRGB(168, 172, 176),
		studio = Color3.fromRGB(226, 226, 222),
		warehouse = Color3.fromRGB(150, 154, 158),
		garage = Color3.fromRGB(160, 140, 112),
		control_tower = Color3.fromRGB(196, 190, 176),
	} :: { [string]: Color3 },
	landmarkDefaultColor = Color3.fromRGB(180, 176, 168),
	glassColor = Color3.fromRGB(120, 160, 186),
	doorColor = Color3.fromRGB(84, 86, 90),
	accentDepth = 0.6, -- how far an accent stands proud of the facade

	-- Locations
	volumeTags = { FlightZone = true, NoFlyZone = true } :: { [string]: boolean },
	padTransparency = 0.85,
	tagColors = {
		SpawnPad = Color3.fromRGB(120, 200, 140),
		ChargerStall = Color3.fromRGB(90, 170, 230),
		TruckCharger = Color3.fromRGB(60, 130, 210),
		FuelPump = Color3.fromRGB(230, 170, 70),
		Dealership = Color3.fromRGB(200, 200, 210),
		UsedLot = Color3.fromRGB(190, 190, 150),
		DesignStudio = Color3.fromRGB(200, 150, 220),
		JobDepot = Color3.fromRGB(220, 140, 80),
		RideshareHotspot = Color3.fromRGB(240, 210, 80),
		HousePlot = Color3.fromRGB(170, 200, 130),
		MeetSpot = Color3.fromRGB(230, 110, 110),
		FlightZone = Color3.fromRGB(120, 200, 240),
		NoFlyZone = Color3.fromRGB(240, 90, 90),
		DragStripGate = Color3.fromRGB(240, 240, 240),
		CustomShop = Color3.fromRGB(150, 110, 230),
		-- Phase 8: freight trailer spots, tow drops and breakdown shoulders.
		TrailerSpawn = Color3.fromRGB(200, 120, 70),
		TowDrop = Color3.fromRGB(230, 190, 60),
		Breakdown = Color3.fromRGB(240, 120, 40),
	} :: { [string]: Color3 },
	defaultTagColor = Color3.fromRGB(200, 200, 200),
	markingInset = 0.6, -- painted outline inset inside a pad's footprint
	markingThickness = 0.05,
	markingLift = 0.03,
	propGap = 1, -- props stand this far behind a pad's back edge
	chargerPost = Vector3.new(1.4, 5, 1),
	truckChargerPost = Vector3.new(2, 8, 1.4),
	fuelPump = Vector3.new(2.4, 5, 1.4),
	signPost = Vector3.new(0.8, 12, 0.8),
	signBoard = Vector3.new(14, 5, 0.6),
	hotspotPost = Vector3.new(0.6, 8, 0.6),
	housePadInset = 0.75, -- a house pad covers this fraction of its plot
	housePadThickness = 0.3,
	overlookRailHeight = 3,
	overlookRailThickness = 0.8,
	gatePostSize = 1.6,
	gateClearHeight = 16, -- the gantry beam's underside (cars and the tallest truck pass under)
	gateBeamHeight = 1.6,
	gatePostGap = 2, -- posts stand at least this far outside the road
	gatePostSearch = 40, -- ...and slide out up to this far looking for clear ground
	-- A Wrap & Tint shop (CustomShop, Phase 7): a closed roll-up garage door behind its bay, between two posts,
	-- under a header in the shop's tag colour.
	garageDoor = Vector3.new(16, 10, 0.6),
	garageDoorPost = Vector3.new(1.6, 12, 1.6),
	garageDoorHeader = 2.5, -- the header's height; it spans the door and both posts
	garageDoorColor = Color3.fromRGB(196, 198, 200),
	propColor = Color3.fromRGB(70, 74, 80),
	railPropColor = Color3.fromRGB(190, 186, 176),

	-- Display pads (dealership and used lot; their sizes and places come from MapLayout)
	displayPadColor = Color3.fromRGB(228, 228, 224),
	displayPadMaterial = Enum.Material.SmoothPlastic,
	displayPadMargin = 4, -- lots, buildings and streetlights keep this far from each pad...
	displayAreaMargin = 8, -- ...and this far from the rectangle round each group of pads facing one way
	brandSignGap = 2, -- a section's sign stands this far behind its pads' back edge
	brandSignPost = Vector3.new(0.8, 9, 0.8), -- up to the board's bottom edge, over the tallest display car
	brandSignBoard = Vector3.new(24, 5, 0.6),
	brandSignColor = Color3.fromRGB(34, 36, 40),
	brandSignTextColor = Color3.fromRGB(245, 245, 242),
	padNumberColor = Color3.fromRGB(70, 72, 76),
	labelPixelsPerStud = 30, -- SurfaceGui resolution on signs and pad numbers
	labelFont = Enum.Font.BuilderSansBold,
	labelSize = Vector2.new(0.86, 0.7), -- a sign's name fills this much of the board
	-- A used-lot space's number is painted across its front edge, clear of the car standing in the middle.
	padNumberCenter = Vector2.new(0.5, 0.08),
	padNumberSize = Vector2.new(0.4, 0.12),

	-- Billboards (Phase 12; where, how big and whose poster come from MapLayout.billboards, the ad unit's limits
	-- and the poster look from Config/Ads): the panel stands on two square posts as tall as its clearance.
	billboardPostWidth = 1.2,
	billboardPostInset = 3, -- each post stands this far in from its end of the panel
	billboardPostColor = Color3.fromRGB(70, 72, 76),

	-- Player spawns
	spawnSize = Vector3.new(6, 0.2, 6),
	spawnTransparency = 0.6,
	spawnColor = Color3.fromRGB(120, 200, 140),

	-- Spatial grid for the placement checks
	gridCell = 64,
}

local TAU = 2 * math.pi
local UP = Vector3.yAxis
local HUGE = math.huge

local MapBuilder = {}
MapBuilder.TUNING = TUNING

---------------------------------------------------------------------------------------------------------------
-- Plan-view geometry. Plan points are Vector2(x, z). Angles are math.atan2(z, x), and "counter-clockwise" in
-- this file means increasing angle in that x-z sense (which is clockwise on a north-up map, because north is
-- -Z). perp(u) = (-u.Y, u.X) is a quarter turn that way: the right-hand side of a road heading along u, and the
-- RightVector of a CFrame looking along u.
---------------------------------------------------------------------------------------------------------------

type Rect = { c: Vector2, u: Vector2, ha: number, hc: number } -- centre, unit axis, half along, half across
type Tri = { r: Vector2, p: Vector2, q: Vector2 } -- a right triangle, the right angle at r

local function flat(v: Vector3): Vector2
	return Vector2.new(v.X, v.Z)
end

local function lift(p: Vector2, y: number): Vector3
	return Vector3.new(p.X, y, p.Y)
end

local function perp(u: Vector2): Vector2
	return Vector2.new(-u.Y, u.X)
end

local function cross2(a: Vector2, b: Vector2): number
	return a.X * b.Y - a.Y * b.X
end

-- The point p with p . la = ha and p . lb = hb (where two offset lines cross), or nil when they are parallel.
local function intersect(la: Vector2, ha: number, lb: Vector2, hb: number): Vector2?
	local det = la.X * lb.Y - la.Y * lb.X
	if math.abs(det) < 1e-9 then
		return nil
	end
	return Vector2.new((ha * lb.Y - la.Y * hb) / det, (la.X * hb - ha * lb.X) / det)
end

local function rectCorners(r: Rect): { Vector2 }
	local along, across = r.u * r.ha, perp(r.u) * r.hc
	return { r.c + along + across, r.c - along + across, r.c - along - across, r.c + along - across }
end

-- How deep two plan rectangles overlap (separating-axis test); 0 when they are apart or only touch.
local function rectOverlap(a: Rect, b: Rect): number
	local ca, cb = rectCorners(a), rectCorners(b)
	local depth = HUGE
	for _, axis in { a.u, perp(a.u), b.u, perp(b.u) } do
		local minA, maxA, minB, maxB = HUGE, -HUGE, HUGE, -HUGE
		for _, p in ca do
			local d = p:Dot(axis)
			minA, maxA = math.min(minA, d), math.max(maxA, d)
		end
		for _, p in cb do
			local d = p:Dot(axis)
			minB, maxB = math.min(minB, d), math.max(maxB, d)
		end
		local overlap = math.min(maxA, maxB) - math.max(minA, minB)
		if overlap <= 0 then
			return 0
		end
		depth = math.min(depth, overlap)
	end
	return depth
end

-- The plan rectangle a wedge part fills as a whole box: twice its right triangle.
local function triRect(t: Tri): Rect
	local leg = t.p - t.r
	return { c = (t.p + t.q) / 2, u = leg.Unit, ha = leg.Magnitude / 2, hc = (t.q - t.r).Magnitude / 2 }
end

local function polygonArea(poly: { Vector2 }): number
	local area = 0
	for i, p in poly do
		area += cross2(p, poly[i % #poly + 1])
	end
	return area / 2
end

-- Drops repeated points and points on a straight run, so every corner is a real corner.
local function cleanPolygon(points: { Vector2 }): { Vector2 }
	local out: { Vector2 } = {}
	for _, p in points do
		if #out == 0 or (p - out[#out]).Magnitude > TUNING.pointTolerance then
			table.insert(out, p)
		end
	end
	while #out > 1 and (out[1] - out[#out]).Magnitude <= TUNING.pointTolerance do
		table.remove(out)
	end
	local changed = true
	while changed and #out >= 3 do
		changed = false
		for i = 1, #out do
			local a, b, c = out[(i - 2) % #out + 1], out[i], out[i % #out + 1]
			local ab, bc = b - a, c - b
			if math.abs(cross2(ab, bc)) <= 1e-6 * math.max(1, ab.Magnitude * bc.Magnitude) and ab:Dot(bc) > 0 then
				table.remove(out, i)
				changed = true
				break
			end
		end
	end
	return out
end

local function segmentsCross(p1: Vector2, p2: Vector2, p3: Vector2, p4: Vector2): boolean
	local d1, d2 = cross2(p4 - p3, p1 - p3), cross2(p4 - p3, p2 - p3)
	local d3, d4 = cross2(p2 - p1, p3 - p1), cross2(p2 - p1, p4 - p1)
	return ((d1 > 1e-9 and d2 < -1e-9) or (d1 < -1e-9 and d2 > 1e-9))
		and ((d3 > 1e-9 and d4 < -1e-9) or (d3 < -1e-9 and d4 > 1e-9))
end

local function isSimplePolygon(poly: { Vector2 }): boolean
	local n = #poly
	for i = 1, n do
		for j = i + 1, n do
			local adjacent = j == i + 1 or (i == 1 and j == n)
			if not adjacent and segmentsCross(poly[i], poly[i % n + 1], poly[j], poly[j % n + 1]) then
				return false
			end
		end
	end
	return true
end

local function pointInTriangle(p: Vector2, a: Vector2, b: Vector2, c: Vector2): boolean
	return cross2(b - a, p - a) >= -1e-9 and cross2(c - b, p - b) >= -1e-9 and cross2(a - c, p - c) >= -1e-9
end

-- Ear-clipping triangulation of a simple counter-clockwise polygon (nil if it gets stuck).
local function earClip(poly: { Vector2 }): { { Vector2 } }?
	local index: { number } = {}
	for i = 1, #poly do
		index[i] = i
	end
	local triangles: { { Vector2 } } = {}
	local guard = 0
	while #index > 3 do
		guard += 1
		if guard > 1000 then
			return nil
		end
		local found = false
		for k = 1, #index do
			local ia, ib, ic = index[(k - 2) % #index + 1], index[k], index[k % #index + 1]
			local a, b, c = poly[ia], poly[ib], poly[ic]
			if cross2(b - a, c - b) > 1e-9 then
				local ear = true
				for _, m in index do
					if m ~= ia and m ~= ib and m ~= ic and pointInTriangle(poly[m], a, b, c) then
						ear = false
						break
					end
				end
				if ear then
					table.insert(triangles, { a, b, c })
					table.remove(index, k)
					found = true
					break
				end
			end
		end
		if not found then
			return nil
		end
	end
	if #index == 3 then
		table.insert(triangles, { poly[index[1]], poly[index[2]], poly[index[3]] })
	end
	return triangles
end

-- Every way to cut a triangle into right triangles (one wedge or two): itself if it has a square corner, else
-- the altitude from any corner whose foot lands inside the opposite side.
local function splitOptions(a: Vector2, b: Vector2, c: Vector2): { { Tri } }
	if math.abs(cross2(b - a, c - a)) < TUNING.minSliver then
		return { {} } -- a sliver with no area worth a part
	end
	local corners = { { a, b, c }, { b, c, a }, { c, a, b } }
	for _, corner in corners do
		local r, p, q = corner[1], corner[2], corner[3]
		local e1, e2 = p - r, q - r
		if e1.Magnitude < 1e-6 or e2.Magnitude < 1e-6 then
			return { {} }
		end
		if math.abs(e1:Dot(e2)) <= TUNING.cornerTolerance * e1.Magnitude * e2.Magnitude then
			return { { { r = r, p = p, q = q } } }
		end
	end
	local options: { { Tri } } = {}
	for _, corner in corners do
		local x, b1, b2 = corner[1], corner[2], corner[3]
		local side = b2 - b1
		local t = (x - b1):Dot(side) / side:Dot(side)
		local foot = b1 + side * t
		local shortest = math.min((x - foot).Magnitude, (b1 - foot).Magnitude, (b2 - foot).Magnitude)
		if t > 0 and t < 1 and shortest > TUNING.pointTolerance then
			table.insert(options, { { r = foot, p = x, q = b1 }, { r = foot, p = x, q = b2 } })
		end
	end
	return options
end

-- Candidate triangulations of a junction polygon: ear clipping from every starting corner, and a fan from the
-- node (the origin) when every fan triangle turns the right way.
local function triangulations(poly: { Vector2 }): { { { Vector2 } } }
	local out: { { { Vector2 } } } = {}
	local n = #poly
	for start = 1, n do
		local rotated: { Vector2 } = {}
		for i = 0, n - 1 do
			table.insert(rotated, poly[(start - 1 + i) % n + 1])
		end
		local triangles = earClip(rotated)
		if triangles then
			table.insert(out, triangles)
		end
	end
	local fan: { { Vector2 } } = {}
	for i = 1, n do
		local a, b = poly[i], poly[i % n + 1]
		local turn = cross2(a, b)
		if turn < -1e-9 then
			return out
		elseif turn > 1e-9 then
			table.insert(fan, { Vector2.zero, a, b })
		end
	end
	if #fan > 0 then
		table.insert(out, fan)
	end
	return out
end

-- Keeps the part of a convex polygon where f(p) <= 0 (Sutherland-Hodgman).
local function clipPolygon(poly: { Vector2 }, f: (Vector2) -> number): { Vector2 }
	local out: { Vector2 } = {}
	for i, a in poly do
		local b = poly[i % #poly + 1]
		local fa, fb = f(a), f(b)
		if fa <= 0 then
			table.insert(out, a)
		end
		if (fa < 0 and fb > 0) or (fb < 0 and fa > 0) then
			table.insert(out, a + (b - a) * (fa / (fa - fb)))
		end
	end
	return out
end

-- How far along a road (direction u, half-width h, from the origin) a convex shape reaches while it is inside
-- the road's band; -HUGE when it never enters it.
local function reachInto(points: { Vector2 }, u: Vector2, h: number): number
	local l = perp(u)
	local inside = clipPolygon(points, function(p)
		return p:Dot(l) - h
	end)
	inside = clipPolygon(inside, function(p)
		return -p:Dot(l) - h
	end)
	if #inside < 3 then
		return -HUGE
	end
	local reach = -HUGE
	for _, p in inside do
		reach = math.max(reach, p:Dot(u))
	end
	return reach
end

local function isRectangle(poly: { Vector2 }): boolean
	if #poly ~= 4 then
		return false
	end
	for i = 1, 4 do
		local a, b, c = poly[(i - 2) % 4 + 1], poly[i], poly[i % 4 + 1]
		local e1, e2 = a - b, c - b
		if math.abs(e1:Dot(e2)) > TUNING.cornerTolerance * e1.Magnitude * e2.Magnitude then
			return false
		end
	end
	return true
end

---------------------------------------------------------------------------------------------------------------
-- 3D placement helpers
---------------------------------------------------------------------------------------------------------------

-- The frame of a WedgePart whose right-angled cross-section has its square corner at r, one leg toward p (the
-- part's Y axis, its tall back face) and the other toward q (its bottom face, running to the low front edge).
-- The part's X axis is the extrusion, centred on the triangle's plane. Returns the frame and the Y and Z sizes.
local function wedgeFrame(r: Vector3, p: Vector3, q: Vector3): (CFrame, number, number)
	local yAxis = (p - r).Unit
	local zAxis = (r - q).Unit
	return CFrame.fromMatrix((p + q) / 2, yAxis:Cross(zAxis), yAxis, zAxis), (p - r).Magnitude, (q - r).Magnitude
end

-- Integer seed mixing for deterministic per-thing random streams.
local function mixSeed(seed: number, a: number, b: number): number
	local modulus = 2147483647
	local h = math.floor(seed) % modulus
	h = (h * 16807 + math.floor(a) * 7919 + 13) % modulus
	h = (h * 16807 + math.floor(b) * 104729 + 17) % modulus
	return h
end

---------------------------------------------------------------------------------------------------------------
-- Placement grid: plan rectangles by kind, for "is this spot clear?" checks.
---------------------------------------------------------------------------------------------------------------

-- owner: which road (or other thing) put it there; top: its highest surface, for "is that road under me?".
type Shape = {
	rect: Rect,
	kind: string,
	owner: string?,
	top: number?,
	minX: number,
	maxX: number,
	minZ: number,
	maxZ: number,
}
type Grid = { cell: number, cells: { [number]: { Shape } } }

local function newGrid(cell: number): Grid
	return { cell = cell, cells = {} }
end

local function cellKey(x: number, z: number): number
	return x * 65536 + z
end

local function shapeOf(rect: Rect, kind: string, owner: string?, top: number?): Shape
	local minX, maxX, minZ, maxZ = HUGE, -HUGE, HUGE, -HUGE
	for _, p in rectCorners(rect) do
		minX, maxX = math.min(minX, p.X), math.max(maxX, p.X)
		minZ, maxZ = math.min(minZ, p.Y), math.max(maxZ, p.Y)
	end
	return { rect = rect, kind = kind, owner = owner, top = top, minX = minX, maxX = maxX, minZ = minZ, maxZ = maxZ }
end

local function gridInsert(grid: Grid, rect: Rect, kind: string, owner: string?, top: number?)
	local shape = shapeOf(rect, kind, owner, top)
	local c = grid.cell
	for x = math.floor(shape.minX / c), math.floor(shape.maxX / c) do
		for z = math.floor(shape.minZ / c), math.floor(shape.maxZ / c) do
			local key = cellKey(x, z)
			local list = grid.cells[key]
			if list == nil then
				list = {}
				grid.cells[key] = list
			end
			table.insert(list, shape)
		end
	end
end

-- True when `rect` overlaps (deeper than `tolerance`) a shape that `accept` says counts.
local function gridAny(grid: Grid, rect: Rect, tolerance: number, accept: (Shape) -> boolean): boolean
	local probe = shapeOf(rect, "")
	local c = grid.cell
	for x = math.floor(probe.minX / c), math.floor(probe.maxX / c) do
		for z = math.floor(probe.minZ / c), math.floor(probe.maxZ / c) do
			local list = grid.cells[cellKey(x, z)]
			if list then
				for _, shape in list do
					if
						shape.minX < probe.maxX
						and shape.maxX > probe.minX
						and shape.minZ < probe.maxZ
						and shape.maxZ > probe.minZ
						and accept(shape)
						and rectOverlap(shape.rect, rect) > tolerance
					then
						return true
					end
				end
			end
		end
	end
	return false
end

-- True when `rect` overlaps (deeper than `tolerance`) a shape of one of `kinds`.
local function gridHits(grid: Grid, rect: Rect, kinds: { [string]: boolean }, tolerance: number): boolean
	return gridAny(grid, rect, tolerance, function(shape)
		return kinds[shape.kind] == true
	end)
end

---------------------------------------------------------------------------------------------------------------
-- The road network, prepared
---------------------------------------------------------------------------------------------------------------

-- One road leaving a node: the edge, its direction away from the node, half-width and how steeply it climbs
-- toward the node (rise per run, + when the node is the higher end).
type Road = {
	edge: number,
	atFrom: boolean, -- the node is the edge's `from` end
	u: Vector2,
	l: Vector2,
	h: number,
	rise: number,
	length: number,
	angle: number,
}

type Gap = {
	kind: "inner" | "outer" | "clip" | "bevel" | "straight",
	point: Vector2?, -- inner: where the facing road edges cross; outer: the outer corner
	clipA: Vector2?, -- clip: the clipped outer corner (two points)
	clipB: Vector2?,
	phi: number, -- angle from this road to the next, counter-clockwise
}

type Piece = { kind: "block", rect: Rect } | { kind: "wedge", tri: Tri }

-- A node's junction. Arrays are indexed like `roads` (sorted counter-clockwise); everything is relative to the
-- node (the node is at the origin).
type Joint = {
	roads: { Road },
	t: { number }, -- minimal cut-back of each road so it clears its neighbours
	throat: { number }, -- extra cut-back filled by a throat block
	gaps: { Gap }, -- gaps[i] lies between roads[i] and roads[i % k + 1]
	pad: boolean,
	pieces: { Piece },
	thickness: number,
}

type Node = {
	id: string,
	data: NodeData,
	plan: Vector2,
	y: number,
	zone: string,
	roads: { Road },
	joint: Joint?,
}

type Segment = {
	a: Vector3, -- top of the slab at its start (the `from` end) and end
	b: Vector3,
	frame: CFrame, -- centred on the top surface, looking from a to b; RightVector is horizontal (+l)
	length: number,
	run: number, -- plan length
	slope: number, -- rise per plan stud, from a to b
}

type Edge = {
	id: number, -- position in ctx.edges (what Road.edge points at)
	index: number, -- position in the graph data
	name: string, -- the segment part's name
	data: EdgeData,
	kind: string,
	style: StyleData,
	from: Node,
	to: Node,
	half: number,
	u: Vector2, -- plan direction from `from` to `to`
	l: Vector2,
	length: number, -- plan length
	fromIndex: number, -- this edge's index in each end's sorted road list
	toIndex: number,
	trimFrom: number, -- total cut-back at each end (minimal + throat)
	trimTo: number,
	sidewalk: number, -- sidewalk width each side (0 = none)
	segment: Segment?,
}

-- A stretch along a road edge, in plan studs from its `from` node.
type Span = { from: number, to: number }

type Ctx = {
	layout: LayoutData,
	graph: GraphData,
	specs: { PartSpec },
	containers: { Container },
	containerSet: { [string]: boolean },
	notes: { string },
	nodes: { Node },
	nodeById: { [string]: Node },
	edges: { Edge },
	grid: Grid,
	groundAt: (x: number, z: number) -> number,
	half: number, -- the map's half extent
	driveways: { [string]: { Span } }, -- by `{edge.id}:{side}`: stretches (along the edge) with no sidewalk
}

local DEFAULT_STYLE: StyleData = {
	shoulder = 0,
	sidewalk = 0,
	color = Color3.fromRGB(70, 72, 76),
	lineColor = Color3.fromRGB(236, 236, 228),
}

local function note(ctx: Ctx, text: string)
	table.insert(ctx.notes, text)
end

local function container(ctx: Ctx, path: string, class: "Folder" | "Model", streaming: Enum.ModelStreamingMode?)
	if not ctx.containerSet[path] then
		ctx.containerSet[path] = true
		table.insert(ctx.containers, { path = path, class = class, streaming = streaming })
	end
end

-- A plain anchored block; callers change what differs.
local function block(
	folder: string,
	name: string,
	role: Role,
	cframe: CFrame,
	size: Vector3,
	color: Color3,
	material: Enum.Material
): PartSpec
	return {
		folder = folder,
		name = name,
		class = "Part",
		shape = "block",
		role = role,
		size = size,
		cframe = cframe,
		color = color,
		material = material,
		collide = true,
		query = true,
		touch = false,
		shadow = true,
		transparency = 0,
	}
end

local function wedge(
	folder: string,
	name: string,
	role: Role,
	cframe: CFrame,
	size: Vector3,
	color: Color3,
	material: Enum.Material
): PartSpec
	local spec = block(folder, name, role, cframe, size, color, material)
	spec.class = "WedgePart"
	spec.shape = "wedge"
	return spec
end

-- Paint and decoration: no collisions, no raycasts, no shadows.
local function decor(spec: PartSpec): PartSpec
	spec.collide = false
	spec.query = false
	spec.touch = false
	spec.shadow = false
	return spec
end

local function add(ctx: Ctx, spec: PartSpec)
	table.insert(ctx.specs, spec)
end

local function surfaceMaterial(surface: string): Enum.Material
	if surface == "dirt" then
		return Enum.Material.Ground
	elseif surface == "concrete" then
		return Enum.Material.Concrete
	end
	return Enum.Material.Asphalt
end

local function prepare(ctx: Ctx)
	for _, data in ctx.graph.nodes do
		if ctx.nodeById[data.id] then
			note(ctx, `node {data.id} is listed twice; the first one is used`)
		else
			local node: Node = {
				id = data.id,
				data = data,
				plan = flat(data.position),
				y = data.position.Y,
				zone = data.zone,
				roads = {},
				joint = nil,
			}
			table.insert(ctx.nodes, node)
			ctx.nodeById[data.id] = node
		end
	end
	for index, data in ctx.graph.edges do
		local from, to = ctx.nodeById[data.from], ctx.nodeById[data.to]
		if from == nil or to == nil or from == to then
			note(ctx, `edge {index} ({data.from}-{data.to}) has a missing or repeated end; skipped`)
			continue
		end
		local delta = to.plan - from.plan
		local length = delta.Magnitude
		if length < TUNING.minSegment then
			note(ctx, `edge {data.from}-{data.to} is too short to build; skipped`)
			continue
		end
		local style = ctx.graph.styles[data.kind]
		if style == nil then
			note(ctx, `edge {data.from}-{data.to}: no style for kind {data.kind}`)
			style = DEFAULT_STYLE
		end
		local styleData = style :: StyleData
		local u = delta / length
		local half = (data.lanes * World.laneWidth + 2 * styleData.shoulder) / 2
		local sidewalk = 0
		if TUNING.sidewalkKinds[data.kind] and TUNING.sidewalkZones[from.zone] and TUNING.sidewalkZones[to.zone] then
			sidewalk = styleData.sidewalk
		end
		local edge: Edge = {
			id = #ctx.edges + 1,
			index = index,
			name = `{data.from}-{data.to}`,
			data = data,
			kind = data.kind,
			style = styleData,
			from = from,
			to = to,
			half = half,
			u = u,
			l = perp(u),
			length = length,
			fromIndex = 0,
			toIndex = 0,
			trimFrom = 0,
			trimTo = 0,
			sidewalk = sidewalk,
			segment = nil,
		}
		table.insert(ctx.edges, edge)
		local rise = (from.y - to.y) / length -- climbing toward `from`
		table.insert(from.roads, {
			edge = #ctx.edges,
			atFrom = true,
			u = u,
			l = perp(u),
			h = half,
			rise = rise,
			length = length,
			angle = math.atan2(u.Y, u.X),
		})
		table.insert(to.roads, {
			edge = #ctx.edges,
			atFrom = false,
			u = -u,
			l = perp(-u),
			h = half,
			rise = -rise,
			length = length,
			angle = math.atan2(-u.Y, -u.X),
		})
	end
	for _, node in ctx.nodes do
		table.sort(node.roads, function(a, b)
			if a.angle ~= b.angle then
				return a.angle < b.angle
			end
			return a.edge < b.edge
		end)
		for i, road in node.roads do
			local edge = ctx.edges[road.edge]
			if road.atFrom then
				edge.fromIndex = i
			else
				edge.toIndex = i
			end
		end
	end
end

---------------------------------------------------------------------------------------------------------------
-- Junctions
---------------------------------------------------------------------------------------------------------------

-- Works out a node's junction: how far each road is cut back, and the pad that fills the space between the
-- cut ends. `room` (per road) is how much throat each road can spare; nil means plenty.
local function solveJoint(ctx: Ctx, node: Node, room: { number }?): Joint
	local roads = node.roads
	local k = #roads
	local t: { number } = table.create(k, 0)
	local throat: { number } = table.create(k, 0)
	local joint: Joint = {
		roads = roads,
		t = t,
		throat = throat,
		gaps = {},
		pad = false,
		pieces = {},
		thickness = TUNING.padThickness,
	}
	if k < 2 then
		return joint
	end

	-- Where each pair of neighbouring roads' facing edges cross. Inside corners (less than half a turn
	-- between the roads) set how far both roads must be cut back to clear each other. When the edges only
	-- cross behind one of the roads (nearly opposite roads of different widths), each road just has to clear
	-- the other's cut end, and the corner is bevelled.
	local points: { Vector2? } = {}
	local phis: { number } = {}
	local behind: { boolean } = {}
	for i = 1, k do
		local j = i % k + 1
		local a, b = roads[i], roads[j]
		local phi = (b.angle - a.angle) % TAU
		if phi < 1e-6 then
			phi = if k == 2 then TAU else 1e-6
		end
		local point = intersect(a.l, a.h, b.l, -b.h)
		phis[i], points[i], behind[i] = phi, point, false
		if phi < math.pi - 1e-4 and point then
			local alongA, alongB = point:Dot(a.u), point:Dot(b.u)
			if alongA >= -1e-6 and alongB >= -1e-6 then
				t[i] = math.max(t[i], alongA)
				t[j] = math.max(t[j], alongB)
			else
				behind[i] = true
				t[i] = math.max(t[i], b.h * math.sin(phi))
				t[j] = math.max(t[j], a.h * math.sin(phi))
			end
		end
	end
	for i = 1, k do
		local j = i % k + 1
		local a, b = roads[i], roads[j]
		local phi, point = phis[i], points[i]
		local gap: Gap = { kind = "straight", phi = phi }
		if point and phi < math.pi - 1e-4 and behind[i] then
			gap = { kind = "bevel", phi = phi }
		elseif point and phi < math.pi - 1e-4 then
			gap = { kind = "inner", point = point, phi = phi }
		elseif point and phi > math.pi + 1e-4 then
			local limit = TUNING.miterLimit * math.max(a.h, b.h)
			if point.Magnitude > limit and phi >= 1.5 * math.pi then
				-- A hairpin: follow both outer edges back to a little behind the node and cut across.
				local reach = math.max(a.h, b.h)
				gap = { kind = "clip", clipA = -a.u * reach + a.l * a.h, clipB = -b.u * reach - b.l * b.h, phi = phi }
			elseif point.Magnitude <= limit and point:Dot(a.u) <= t[i] + 1e-6 and point:Dot(b.u) <= t[j] + 1e-6 then
				gap = { kind = "outer", point = point, phi = phi }
			else
				gap = { kind = "bevel", phi = phi }
			end
		end
		joint.gaps[i] = gap
	end

	-- A pad where three or more roads meet, or where two meet at an angle or over a crest (otherwise their
	-- slabs would overlap by more than the tolerances).
	if k == 2 then
		local turn = math.abs(math.pi - phis[1])
		local bend = math.max(roads[1].h, roads[2].h) * math.sin(turn)
		local convex = math.atan(roads[1].rise) + math.atan(roads[2].rise)
		local crest = TUNING.roadThickness * math.sin(convex)
		if bend <= TUNING.bendTolerance and crest <= TUNING.crestTolerance then
			t[1], t[2] = 0, 0
			return joint
		end
	end
	joint.pad = true

	-- The core polygon: each road's cut end, joined round the node by the corner points.
	local corners: { Vector2 } = {}
	for i, road in roads do
		table.insert(corners, road.u * t[i] - road.l * road.h)
		table.insert(corners, road.u * t[i] + road.l * road.h)
		local gap = joint.gaps[i]
		if gap.kind == "inner" or gap.kind == "outer" then
			table.insert(corners, gap.point :: Vector2)
		elseif gap.kind == "clip" then
			table.insert(corners, gap.clipA :: Vector2)
			table.insert(corners, gap.clipB :: Vector2)
		end
	end
	local poly = cleanPolygon(corners)

	-- How far into each road a set of pieces' whole boxes reach past its cut end.
	local function needsOf(pieces: { Tri }, need: { number }): { number }
		local out = table.clone(need)
		for _, piece in pieces do
			local box = rectCorners(triRect(piece))
			for j, road in roads do
				out[j] = math.max(out[j], reachInto(box, road.u, road.h) - t[j])
			end
		end
		return out
	end
	-- Ranks a choice: throat beyond the room first, then parts (wedges and throat blocks), then throat length.
	local function cost(need: { number }, wedges: number): { number }
		local over, parts, total = 0, wedges, 0
		for j, road in roads do
			local spare = if room then room[j] else HUGE
			over += math.max(0, need[j] - spare)
			if need[j] > 1e-3 or road.rise > 1e-4 then
				parts += 1
			end
			total += math.max(0, need[j])
		end
		return { over, parts, total }
	end
	local function better(a: { number }, b: { number }?): boolean
		if b == nil then
			return true
		end
		for i = 1, 3 do
			if math.abs(a[i] - b[i]) > 1e-6 then
				return a[i] < b[i]
			end
		end
		return false
	end

	local need: { number } = table.create(k, 0)
	if #poly >= 3 and polygonArea(poly) > 1e-3 then
		if not isSimplePolygon(poly) then
			note(ctx, `junction {node.id}: its pad outline crosses itself; check the roads there`)
		end
		if isRectangle(poly) then
			local a, b, c = poly[1], poly[2], poly[3]
			local side = b - a
			table.insert(joint.pieces, {
				kind = "block",
				rect = { c = (a + c) / 2, u = side.Unit, ha = side.Magnitude / 2, hc = (c - b).Magnitude / 2 },
			})
		else
			-- Try every triangulation and every way of cutting each triangle into wedges; keep the one that
			-- needs the least throat (and the fewest parts).
			local best: { Tri }? = nil
			local bestCost: { number }? = nil
			local bestNeed: { number }? = nil
			for _, triangles in triangulations(poly) do
				local chosen: { Tri } = {}
				local running: { number } = table.create(k, 0)
				for _, tri in triangles do
					local pick: { Tri }? = nil
					local pickCost: { number }? = nil
					local pickNeed: { number }? = nil
					for _, option in splitOptions(tri[1], tri[2], tri[3]) do
						local optionNeed = needsOf(option, running)
						local optionCost = cost(optionNeed, #chosen + #option)
						if better(optionCost, pickCost) then
							pick, pickCost, pickNeed = option, optionCost, optionNeed
						end
					end
					if pick then
						for _, piece in pick do
							table.insert(chosen, piece)
						end
						running = pickNeed :: { number }
					end
				end
				local total = cost(running, #chosen)
				if better(total, bestCost) then
					best, bestCost, bestNeed = chosen, total, running
				end
			end
			if best == nil then
				note(ctx, `junction {node.id}: could not fill its pad`)
			else
				for _, piece in best do
					table.insert(joint.pieces, { kind = "wedge", tri = piece })
				end
				need = bestNeed :: { number }
			end
		end
	end

	-- Throats: the extra cut-back each road needs so no pad part's box reaches its slab, and so a road
	-- climbing into the pad keeps its tilted slab end clear of its neighbours.
	for i, road in roads do
		local length = math.max(0, need[i] + TUNING.throatMargin)
		if need[i] <= 1e-3 then
			length = 0
		end
		if road.rise > 1e-4 then
			length = math.max(length, TUNING.roadThickness * road.rise * TUNING.riseSafety + TUNING.throatMargin)
		end
		if length > 0 then
			length = math.max(length, TUNING.throatMin)
			throat[i] = length
			table.insert(joint.pieces, {
				kind = "block",
				rect = { c = road.u * (t[i] + length / 2), u = road.u, ha = length / 2, hc = road.h },
			})
		end
	end
	return joint
end

-- Solves every junction, then gives each road its cut-back at both ends. Where a short road has no room left
-- between its two ends' cut-backs, the junctions at its ends are solved again with the throat each road there
-- can spare.
local function solveJunctions(ctx: Ctx)
	for _, node in ctx.nodes do
		node.joint = solveJoint(ctx, node, nil)
	end
	local function assign()
		for _, edge in ctx.edges do
			local fromJoint, toJoint = edge.from.joint :: Joint, edge.to.joint :: Joint
			edge.trimFrom = fromJoint.t[edge.fromIndex] + fromJoint.throat[edge.fromIndex]
			edge.trimTo = toJoint.t[edge.toIndex] + toJoint.throat[edge.toIndex]
		end
	end
	assign()
	local cramped: { [Node]: boolean } = {}
	for _, edge in ctx.edges do
		if edge.length - edge.trimFrom - edge.trimTo < TUNING.minSegment then
			cramped[edge.from], cramped[edge.to] = true, true
		end
	end
	for _, node in ctx.nodes do
		if cramped[node] then
			local joint = node.joint :: Joint
			local room: { number } = {}
			for i, road in node.roads do
				local edge = ctx.edges[road.edge]
				local other = if road.atFrom then edge.trimTo else edge.trimFrom
				room[i] = math.max(0, edge.length - other - TUNING.minSegment - joint.t[i])
			end
			node.joint = solveJoint(ctx, node, room)
		end
	end
	assign()
end

local function fmt(value: number): string
	return string.format("%.1f", value)
end

-- A plan point beside a road: `along` studs from its `from` node, `lateral` studs to its right (+, along +l) or
-- left (-), facing from `from` to `to`.
local function planAt(edge: Edge, along: number, lateral: number): Vector2
	return edge.from.plan + edge.u * along + edge.l * lateral
end

-- The road's surface height `along` studs (plan) from its `from` node, following its slab (extended past the
-- slab's ends where sidewalks run on toward a junction).
local function heightAt(edge: Edge, along: number): number
	local segment = edge.segment :: Segment
	return segment.a.Y + (along - edge.trimFrom) * segment.slope
end

---------------------------------------------------------------------------------------------------------------
-- Roads: segments, paint, pads, supports
---------------------------------------------------------------------------------------------------------------

type Line = { x: number, width: number, color: Color3 }

local function addLines(ctx: Ctx, edge: Edge)
	local segment = edge.segment :: Segment
	local length = segment.length - 2 * TUNING.lineEndGap
	if edge.kind == "dirt" or length <= 0 then
		return
	end
	local lanes = edge.data.lanes
	local carriage = lanes * World.laneWidth
	local twoWay = lanes >= 2 and lanes % 2 == 0
	local lines: { Line } = {}
	if twoWay then
		local width = if edge.kind == "highway" then TUNING.medianWidth else TUNING.centerLineWidth
		table.insert(lines, { x = 0, width = width, color = TUNING.centerLineColor })
	end
	for k = 1, lanes - 1 do
		if not (twoWay and k * 2 == lanes) then
			local x = -carriage / 2 + k * World.laneWidth
			table.insert(lines, { x = x, width = TUNING.laneLineWidth, color = edge.style.lineColor })
		end
	end
	if edge.kind == "highway" then
		for _, side in { -1, 1 } do
			table.insert(lines, { x = side * carriage / 2, width = TUNING.laneLineWidth, color = edge.style.lineColor })
		end
	end
	for i, line in lines do
		local frame = segment.frame * CFrame.new(line.x, TUNING.lineLift + TUNING.lineThickness / 2, 0)
		local size = Vector3.new(line.width, TUNING.lineThickness, length)
		add(
			ctx,
			decor(block("Roads/Lines", `{edge.name}:{i}`, "line", frame, size, line.color, Enum.Material.SmoothPlastic))
		)
	end
end

-- One slab per road edge, between its cut ends. Its top runs from one node's height to the other's.
local function addSegments(ctx: Ctx)
	local used: { [string]: boolean } = {}
	for _, edge in ctx.edges do
		if used[edge.name] then
			edge.name = `{edge.name}#{edge.index}`
		end
		used[edge.name] = true
		local run = edge.length - edge.trimFrom - edge.trimTo
		if run < TUNING.minSegment then
			note(ctx, `road {edge.name}: its junctions leave {fmt(run)} studs, so it has no slab`)
			continue
		end
		local a = lift(edge.from.plan + edge.u * edge.trimFrom, edge.from.y)
		local b = lift(edge.to.plan - edge.u * edge.trimTo, edge.to.y)
		local middle = (a + b) / 2
		local frame = CFrame.lookAt(middle, b)
		local segment: Segment = {
			a = a,
			b = b,
			frame = frame,
			length = (b - a).Magnitude,
			run = run,
			slope = (b.Y - a.Y) / run,
		}
		edge.segment = segment
		local thickness = TUNING.roadThickness
		local spec = block(
			"Roads/Segments",
			edge.name,
			"road",
			frame * CFrame.new(0, -thickness / 2, 0),
			Vector3.new(2 * edge.half, thickness, segment.length),
			edge.style.color,
			surfaceMaterial(edge.data.surface)
		)
		spec.attributes = { Kind = edge.kind } -- MapCheck tells bridges by this
		add(ctx, spec)
		gridInsert(
			ctx.grid,
			{ c = flat(middle), u = edge.u, ha = run / 2, hc = edge.half },
			"road",
			`edge{edge.id}`,
			math.max(a.Y, b.Y)
		)
		addLines(ctx, edge)
	end
end

-- Pads are thin, and thinner still where a steep road climbs into one, so the tilted end of its slab never
-- digs more than padMaxDig into the pad's underside.
local function setPadThickness(ctx: Ctx)
	local rise: { [Node]: number } = {}
	for _, edge in ctx.edges do
		local segment = edge.segment
		if segment then
			rise[edge.to] = math.max(rise[edge.to] or 0, segment.slope)
			rise[edge.from] = math.max(rise[edge.from] or 0, -segment.slope)
		end
	end
	for _, node in ctx.nodes do
		local steepest = rise[node] or 0
		if steepest > 1e-6 then
			local joint = node.joint :: Joint
			joint.thickness = math.min(TUNING.padThickness, TUNING.padMaxDig / math.sin(math.atan(steepest)))
		end
	end
end

local function addPads(ctx: Ctx)
	for _, node in ctx.nodes do
		local joint = node.joint :: Joint
		if not joint.pad or #joint.pieces == 0 then
			continue
		end
		-- The widest road sets the pad's colour and surface.
		local widest = ctx.edges[joint.roads[1].edge]
		for _, road in joint.roads do
			local edge = ctx.edges[road.edge]
			if edge.half > widest.half then
				widest = edge
			end
		end
		local color, material = widest.style.color, surfaceMaterial(widest.data.surface)
		local thickness = joint.thickness
		local y = node.y - thickness / 2
		-- One part: named after the node. Several: a Model named after the node (MapCheck never compares two
		-- parts of one model, whose wedges' boxes overlap by design).
		local single = #joint.pieces == 1
		local folder = if single then "Roads/Intersections" else `Roads/Intersections/{node.id}`
		if not single then
			container(ctx, folder, "Model", Enum.ModelStreamingMode.Persistent)
		end
		for i, piece in joint.pieces do
			local name = if single then node.id else `Pad{i}`
			local box: Rect
			if piece.kind == "block" then
				local rect = piece.rect
				local c = node.plan + rect.c
				box = { c = c, u = rect.u, ha = rect.ha, hc = rect.hc }
				local frame = CFrame.lookAt(lift(c, y), lift(c + rect.u, y))
				add(
					ctx,
					block(folder, name, "pad", frame, Vector3.new(2 * rect.hc, thickness, 2 * rect.ha), color, material)
				)
			else
				local tri = piece.tri
				local frame, sizeY, sizeZ =
					wedgeFrame(lift(node.plan + tri.r, y), lift(node.plan + tri.p, y), lift(node.plan + tri.q, y))
				add(ctx, wedge(folder, name, "pad", frame, Vector3.new(thickness, sizeY, sizeZ), color, material))
				local rect = triRect(tri)
				box = { c = node.plan + rect.c, u = rect.u, ha = rect.ha, hc = rect.hc }
			end
			gridInsert(ctx.grid, box, "road", `node{node.id}`, node.y)
		end
	end
end

-- Is a road other than `owner` (or a sidewalk) under this footprint, lower than `top`? A pillar must not stand
-- on it. (Raised roads have no sidewalks, so any sidewalk there belongs to a road below.)
local function lowerRoadUnder(ctx: Ctx, rect: Rect, owner: string, top: number): boolean
	return gridAny(ctx.grid, rect, 0, function(shape)
		if shape.kind == "sidewalk" then
			return true
		end
		return shape.kind == "road" and shape.owner ~= owner and (shape.top or HUGE) < top - 1
	end)
end

local function addPillar(ctx: Ctx, name: string, at: Vector2, u: Vector2, top: number, owner: string): boolean
	local size = TUNING.pillarSize
	local footprint: Rect = { c = at, u = u, ha = size / 2, hc = size / 2 }
	if lowerRoadUnder(ctx, footprint, owner, top) then
		return false
	end
	local bottom = ctx.groundAt(at.X, at.Y) - TUNING.bury
	local center = lift(at, (top + bottom) / 2)
	local frame = CFrame.lookAt(center, center + lift(u, 0))
	add(
		ctx,
		block(
			"Bridges",
			name,
			"support",
			frame,
			Vector3.new(size, top - bottom, size),
			TUNING.supportColor,
			Enum.Material.Concrete
		)
	)
	gridInsert(ctx.grid, footprint, "support")
	return true
end

-- Raised roads (the bridge and its approaches): railings, and under them a solid fill when they are low or
-- pillars when they are high. Junction pads on raised roads are short; the pillars along the roads carry them.
local function addSupports(ctx: Ctx)
	local thickness = TUNING.roadThickness
	for _, edge in ctx.edges do
		local segment = edge.segment
		if segment == nil then
			continue
		end
		local owner = `edge{edge.id}`
		local steps = math.max(2, math.ceil(segment.run / 10))
		local highest = -HUGE
		for i = 0, steps do
			local along = edge.trimFrom + segment.run * i / steps
			local p = planAt(edge, along, 0)
			highest = math.max(highest, heightAt(edge, along) - ctx.groundAt(p.X, p.Y))
		end

		if edge.kind == "bridge" or highest > TUNING.railMinHeight then
			local length = segment.length - 2 * TUNING.railEndGap
			if length > 1 then
				local railing = TUNING.railThickness
				for _, side in { -1, 1 } do
					local offset = edge.half + edge.sidewalk + railing / 2
					local height = thickness + TUNING.railHeight
					local frame = segment.frame * CFrame.new(side * offset, TUNING.railHeight - height / 2, 0)
					local name = `{edge.name}:Rail{if side > 0 then "R" else "L"}`
					local size = Vector3.new(railing, height, length)
					add(ctx, block("Bridges", name, "support", frame, size, TUNING.railColor, Enum.Material.Concrete))
					local c = planAt(edge, edge.trimFrom + segment.run / 2, side * offset)
					gridInsert(ctx.grid, { c = c, u = edge.u, ha = segment.run / 2, hc = railing / 2 }, "support")
				end
			end
		end

		if highest >= TUNING.fillMinHeight and highest <= TUNING.fillMaxHeight then
			-- A solid fill from the slab down past the ground, tilted with the road.
			local depth = highest - thickness + TUNING.bury
			local frame = segment.frame * CFrame.new(0, -thickness - depth / 2, 0)
			local size = Vector3.new(2 * edge.half, depth, segment.length)
			add(
				ctx,
				block(
					"Bridges",
					`{edge.name}:Fill`,
					"support",
					frame,
					size,
					TUNING.supportColor,
					Enum.Material.Concrete
				)
			)
		elseif highest > TUNING.fillMaxHeight then
			local laterals: { number } = if 2 * edge.half > TUNING.pillarPairWidth
				then { -(edge.half - TUNING.pillarInset), edge.half - TUNING.pillarInset }
				else { 0 }
			-- From the road top down to under the slab's lowest corner over the pillar (the slab tilts).
			local slope = math.abs(segment.slope)
			local drop = thickness * math.sqrt(1 + slope * slope) + slope * TUNING.pillarSize / 2 + 0.01
			local along = edge.trimFrom + TUNING.pillarSpacing / 2
			local count = 0
			while along < edge.length - edge.trimTo do
				local center = planAt(edge, along, 0)
				local surface = heightAt(edge, along)
				if surface - ctx.groundAt(center.X, center.Y) > TUNING.supportMinHeight then
					for _, lateral in laterals do
						count += 1
						addPillar(
							ctx,
							`{edge.name}:Pillar{count}`,
							planAt(edge, along, lateral),
							edge.u,
							surface - drop,
							owner
						)
					end
				end
				along += TUNING.pillarSpacing
			end
		end
	end
end

---------------------------------------------------------------------------------------------------------------
-- Sidewalks
---------------------------------------------------------------------------------------------------------------

-- Where a road's sidewalk on one side starts, in studs from the node along the road. `ccw` picks the side
-- facing the next road counter-clockwise. Inside a corner the sidewalk runs as close to the junction as it can
-- without touching the neighbouring road (the two sidewalks overlap there); outside a bend it runs on past the
-- corner until its outer edge meets the neighbour's sidewalk.
local function sidewalkStart(ctx: Ctx, node: Node, index: number, ccw: boolean, width: number): number
	local joint = node.joint :: Joint
	local roads = joint.roads
	local k = #roads
	if k < 2 then
		return 0
	end
	local road = roads[index]
	local gapIndex = if ccw then index else (index - 2) % k + 1
	local other = roads[if ccw then index % k + 1 else (index - 2) % k + 1]
	local gap = joint.gaps[gapIndex]
	local sign = if ccw then 1 else -1
	if gap.kind == "inner" then
		local start = (gap.point :: Vector2):Dot(road.u)
		-- At a sharp corner the neighbour's edge cuts across the sidewalk: start where it leaves the outer edge.
		local outer = intersect(road.l, sign * (road.h + width), other.l, -sign * other.h)
		if outer then
			start = math.max(start, outer:Dot(road.u))
		end
		return start
	elseif gap.kind == "outer" then
		local start = (gap.point :: Vector2):Dot(road.u)
		local otherWidth = ctx.edges[other.edge].sidewalk
		if otherWidth > 0 and gap.phi - math.pi < TUNING.sidewalkMiterTurn then
			local far = intersect(road.l, sign * (road.h + width), other.l, -sign * (other.h + otherWidth))
			if far then
				start = math.min(start, far:Dot(road.u)) - TUNING.sidewalkOverlap
			end
		end
		return start
	elseif gap.kind == "straight" and math.abs(road.h - other.h) < 0.01 then
		return 0
	end
	return joint.t[index]
end

-- A strip beside a road from `from` to `to` (along it) and `inner` to `outer` (out from its centre line) on
-- `side`, its top `raise` above the road surface and tilted with it.
local function addSidewalkStrip(
	ctx: Ctx,
	edge: Edge,
	name: string,
	from: number,
	to: number,
	inner: number,
	outer: number,
	side: number,
	color: Color3,
	raise: number,
	kind: string
)
	local segment = edge.segment :: Segment
	local middle = (from + to) / 2
	local centerPlan = planAt(edge, middle, side * (inner + outer) / 2)
	local center = lift(centerPlan, heightAt(edge, middle) + raise)
	local direction = Vector3.new(edge.u.X, segment.slope, edge.u.Y)
	local frame = CFrame.lookAt(center, center + direction) * CFrame.new(0, -TUNING.sidewalkThickness / 2, 0)
	local length = (to - from) * math.sqrt(1 + segment.slope * segment.slope)
	local size = Vector3.new(outer - inner, TUNING.sidewalkThickness, length)
	local material = if kind == "driveway" then Enum.Material.Concrete else Enum.Material.SmoothPlastic
	add(ctx, block("Sidewalks", name, "sidewalk", frame, size, color, material))
	gridInsert(ctx.grid, { c = centerPlan, u = edge.u, ha = (to - from) / 2, hc = (outer - inner) / 2 }, kind)
end

-- The road edge whose centre line passes nearest `p` (plan): the edge and how far along it.
local function nearestEdge(ctx: Ctx, p: Vector2): (Edge?, number)
	local best: Edge? = nil
	local bestAlong, bestDistance = 0, HUGE
	for _, edge in ctx.edges do
		local along = math.clamp((p - edge.from.plan):Dot(edge.u), 0, edge.length)
		local distance = (edge.from.plan + edge.u * along - p).Magnitude
		if distance < bestDistance then
			best, bestAlong, bestDistance = edge, along, distance
		end
	end
	return best, bestAlong
end

-- A location's footprint on the ground, as its part stands.
local function locationRect(location: LocationData): Rect
	local look = flat(CFrame.Angles(0, math.rad(location.yaw), 0).LookVector).Unit
	return { c = flat(location.position), u = look, ha = location.size.Z / 2, hc = location.size.X / 2 }
end

-- Where the sidewalks stop for driveways (ctx.driveways): in front of every pad beside a sidewalked road, from
-- the pad's sides plus drivewayFlare, and at least accessWidth wide. Cuts on one side of a road are sorted and
-- merged. Locations that span the road (drag-strip gates) and volumes get none.
local function planDriveways(ctx: Ctx)
	for _, location in ctx.layout.locations do
		if TUNING.volumeTags[location.tag] then
			continue
		end
		local corners = rectCorners(locationRect(location))
		for _, edge in ctx.edges do
			if edge.sidewalk <= 0 or edge.segment == nil then
				continue
			end
			local low, high = HUGE, -HUGE
			local inside, outside = HUGE, -HUGE -- the footprint's nearest and farthest signed offsets across
			for _, corner in corners do
				local offset = corner - edge.from.plan
				local along, across = offset:Dot(edge.u), offset:Dot(edge.l)
				low, high = math.min(low, along), math.max(high, along)
				inside, outside = math.min(inside, across), math.max(outside, across)
			end
			local spans = inside < 0 and outside > 0
			local front = math.min(math.abs(inside), math.abs(outside))
			local beside = high > 0 and low < edge.length
			if spans or not beside or front > edge.half + edge.sidewalk + TUNING.drivewayReach then
				continue
			end
			local side = if outside > 0 then 1 else -1
			local middle = (low + high) / 2
			local reach = math.max((high - low) / 2 + TUNING.drivewayFlare, TUNING.accessWidth / 2)
			local key = `{edge.id}:{side}`
			local list = ctx.driveways[key]
			if list == nil then
				list = {}
				ctx.driveways[key] = list
			end
			table.insert(list, { from = middle - reach, to = middle + reach })
		end
	end
	for key, list in ctx.driveways do
		table.sort(list, function(a: Span, b: Span): boolean
			return a.from < b.from
		end)
		local merged: { Span } = {}
		for _, span in list do
			local last = merged[#merged]
			if last and span.from <= last.to then
				last.to = math.max(last.to, span.to)
			else
				table.insert(merged, { from = span.from, to = span.to })
			end
		end
		ctx.driveways[key] = merged
	end
end

-- The stretches of from..to left once the (sorted, merged) driveway cuts are taken out, each at least
-- minSidewalk long.
local function withoutDriveways(from: number, to: number, cuts: { Span }): { Span }
	local pieces: { Span } = {}
	local start = from
	for _, cut in cuts do
		if cut.from >= to then
			break
		end
		if cut.to > start then
			if cut.from - start >= TUNING.minSidewalk then
				table.insert(pieces, { from = start, to = cut.from })
			end
			start = cut.to
		end
	end
	if to - start >= TUNING.minSidewalk then
		table.insert(pieces, { from = start, to = to })
	end
	return pieces
end

local function addSidewalks(ctx: Ctx)
	for _, edge in ctx.edges do
		local width = edge.sidewalk
		if width <= 0 or edge.segment == nil then
			continue
		end
		for _, side in { 1, -1 } do
			-- The edge's +l side (its right, facing from `from` to `to`) is the counter-clockwise side at its
			-- `from` node and the clockwise side at its `to` node.
			-- On a slope the strip's tilted end leans toward the junction: pull both ends back by that much.
			local lean = TUNING.sidewalkThickness * math.abs((edge.segment :: Segment).slope) * 1.1
			local from = sidewalkStart(ctx, edge.from, edge.fromIndex, side == 1, width) + lean
			local to = edge.length - sidewalkStart(ctx, edge.to, edge.toIndex, side == -1, width) - lean
			if to - from >= TUNING.minSidewalk then
				local base = `{edge.name}:{if side == 1 then "R" else "L"}`
				local kerb = math.min(TUNING.kerbWidth, width)
				local cuts = ctx.driveways[`{edge.id}:{side}`] or {}
				-- The sidewalk, in pieces between the driveways.
				for i, piece in withoutDriveways(from, to, cuts) do
					local suffix = if i == 1 then "" else tostring(i)
					addSidewalkStrip(
						ctx,
						edge,
						`{base}Kerb{suffix}`,
						piece.from,
						piece.to,
						edge.half,
						edge.half + kerb,
						side,
						TUNING.kerbColor,
						TUNING.sidewalkRaise,
						"sidewalk"
					)
					if width > kerb then
						addSidewalkStrip(
							ctx,
							edge,
							`{base}Walk{suffix}`,
							piece.from,
							piece.to,
							edge.half + kerb,
							edge.half + width,
							side,
							TUNING.sidewalkColor,
							TUNING.sidewalkRaise,
							"sidewalk"
						)
					end
				end
				-- The driveways: flush with the road, from its edge to the sidewalk's outer edge.
				for i, cut in cuts do
					local a, b = math.max(cut.from, from), math.min(cut.to, to)
					if b - a >= TUNING.minSidewalk then
						addSidewalkStrip(
							ctx,
							edge,
							`{base}Drive{i}`,
							a,
							b,
							edge.half,
							edge.half + width,
							side,
							TUNING.drivewayColor,
							0,
							"driveway"
						)
					end
				end
			end
		end
	end

	-- Corner pieces where two sidewalks meet at a junction.
	for _, node in ctx.nodes do
		local joint = node.joint :: Joint
		local roads = joint.roads
		local k = #roads
		if k < 2 then
			continue
		end
		local y = node.y + TUNING.sidewalkRaise - TUNING.sidewalkThickness / 2
		local count = 0
		local function corner(tri: Tri)
			count += 1
			local r, p, q = lift(node.plan + tri.r, y), lift(node.plan + tri.p, y), lift(node.plan + tri.q, y)
			local frame, sizeY, sizeZ = wedgeFrame(r, p, q)
			local size = Vector3.new(TUNING.sidewalkThickness, sizeY, sizeZ)
			local name = `{node.id}:Corner{count}`
			add(
				ctx,
				wedge("Sidewalks", name, "sidewalk", frame, size, TUNING.sidewalkColor, Enum.Material.SmoothPlastic)
			)
			local rect = triRect(tri)
			gridInsert(ctx.grid, { c = node.plan + rect.c, u = rect.u, ha = rect.ha, hc = rect.hc }, "sidewalk")
		end
		for i = 1, k do
			local j = i % k + 1
			local a, b = roads[i], roads[j]
			local wa, wb = ctx.edges[a.edge].sidewalk, ctx.edges[b.edge].sidewalk
			local gap = joint.gaps[i]
			if gap.kind == "inner" then
				-- Inside a corner the two sidewalks overlap, except at a sharp corner, where each one stops short
				-- of the neighbouring road: fill from its end to the corner.
				local point = gap.point :: Vector2
				if wa > 0 then
					local start = sidewalkStart(ctx, node, i, true, wa)
					if start > point:Dot(a.u) + 0.01 then
						corner({ r = a.u * start + a.l * a.h, p = point, q = a.u * start + a.l * (a.h + wa) })
					end
				end
				if wb > 0 then
					local start = sidewalkStart(ctx, node, j, false, wb)
					if start > point:Dot(b.u) + 0.01 then
						corner({ r = b.u * start - b.l * b.h, p = point, q = b.u * start - b.l * (b.h + wb) })
					end
				end
			elseif gap.kind == "outer" and wa > 0 and wb > 0 and gap.phi - math.pi >= TUNING.sidewalkMiterTurn then
				-- Outside a sharp bend: both sidewalks stop at the outer corner; fill the wedge between them.
				local point = gap.point :: Vector2
				local far = intersect(a.l, a.h + wa, b.l, -(b.h + wb))
				if far and (far - point).Magnitude < TUNING.sidewalkCornerLimit then
					corner({ r = point + a.l * wa, p = point, q = far })
					corner({ r = point - b.l * wb, p = point, q = far })
				end
			end
		end
	end
end

---------------------------------------------------------------------------------------------------------------
-- Zones
---------------------------------------------------------------------------------------------------------------

-- Zones from smallest to largest, so the first one holding a point is the most specific (the County Loop's
-- bounds hold every other zone).
local function zonesBySize(layout: LayoutData): { ZoneData }
	local list: { ZoneData } = {}
	for _, id in layout.zoneOrder do
		local zone = layout.zones[id]
		if zone then
			table.insert(list, zone)
		end
	end
	for id, zone in layout.zones do
		if not table.find(layout.zoneOrder, id) then
			table.insert(list, zone)
		end
	end
	local function area(zone: ZoneData): number
		return (zone.max.X - zone.min.X) * (zone.max.Y - zone.min.Y)
	end
	table.sort(list, function(a, b)
		if area(a) ~= area(b) then
			return area(a) < area(b)
		end
		return a.id < b.id
	end)
	return list
end

local function zoneAt(zones: { ZoneData }, p: Vector2): ZoneData?
	for _, zone in zones do
		if p.X >= zone.min.X and p.X <= zone.max.X and p.Y >= zone.min.Y and p.Y <= zone.max.Y then
			return zone
		end
	end
	return nil
end

---------------------------------------------------------------------------------------------------------------
-- Ground, lakes, mesas, jump ramps
---------------------------------------------------------------------------------------------------------------

-- Splits a box into pieces no bigger than the part size limit along X and Z and adds them.
local function addSlab(
	ctx: Ctx,
	folder: string,
	name: string,
	x0: number,
	x1: number,
	z0: number,
	z1: number,
	top: number,
	thickness: number,
	color: Color3,
	material: Enum.Material
)
	local limit = TUNING.maxPartSize
	local nx, nz = math.ceil((x1 - x0) / limit), math.ceil((z1 - z0) / limit)
	for i = 0, nx - 1 do
		for j = 0, nz - 1 do
			local ax, bx = x0 + (x1 - x0) * i / nx, x0 + (x1 - x0) * (i + 1) / nx
			local az, bz = z0 + (z1 - z0) * j / nz, z0 + (z1 - z0) * (j + 1) / nz
			local pieceName = if nx * nz > 1 then `{name}_{i + 1}_{j + 1}` else name
			local frame = CFrame.new((ax + bx) / 2, top - thickness / 2, (az + bz) / 2)
			add(
				ctx,
				block(folder, pieceName, "ground", frame, Vector3.new(bx - ax, thickness, bz - az), color, material)
			)
		end
	end
end

local function insideLake(lakes: { LakeData }, x: number, z: number): boolean
	for _, lake in lakes do
		if x > lake.min.X and x < lake.max.X and z > lake.min.Y and z < lake.max.Y then
			return true
		end
	end
	return false
end

type Run = { x0: number, x1: number, z0: number, z1: number, color: Color3 }

-- Zone-tinted ground slabs, top at y = 0, covering the whole map except the lakes: the map is cut along every
-- zone and lake edge into cells, cells of one colour are merged into rectangles, and big rectangles are split.
local function addGround(ctx: Ctx, zones: { ZoneData })
	local half = ctx.half
	local lakes: { LakeData } = ctx.layout.lakes or {}
	local xs, zs = { -half, half }, { -half, half }
	local function cut(list: { number }, value: number)
		if value > -half and value < half then
			table.insert(list, value)
		end
	end
	for _, zone in zones do
		cut(xs, zone.min.X)
		cut(xs, zone.max.X)
		cut(zs, zone.min.Y)
		cut(zs, zone.max.Y)
	end
	for _, lake in lakes do
		cut(xs, lake.min.X)
		cut(xs, lake.max.X)
		cut(zs, lake.min.Y)
		cut(zs, lake.max.Y)
	end
	local function unique(list: { number }): { number }
		table.sort(list)
		local out: { number } = {}
		for _, value in list do
			if #out == 0 or value - out[#out] > 1e-6 then
				table.insert(out, value)
			end
		end
		return out
	end
	xs, zs = unique(xs), unique(zs)
	-- Outside every zone: the largest zone's colour (the open country), else the default.
	local country = if #zones > 0 then zones[#zones].groundColor else TUNING.countryColor

	-- Runs of same-coloured cells along each row, then rows of identical runs merged downward.
	local done: { Run } = {}
	local open: { Run } = {}
	for j = 1, #zs - 1 do
		local z0, z1 = zs[j], zs[j + 1]
		local row: { Run } = {}
		for i = 1, #xs - 1 do
			local x0, x1 = xs[i], xs[i + 1]
			local cx, cz = (x0 + x1) / 2, (z0 + z1) / 2
			if insideLake(lakes, cx, cz) then
				continue
			end
			local zone = zoneAt(zones, Vector2.new(cx, cz))
			local color = if zone then zone.groundColor else country
			local last = row[#row]
			if last and last.color == color and math.abs(last.x1 - x0) < 1e-6 then
				last.x1 = x1
			else
				table.insert(row, { x0 = x0, x1 = x1, z0 = z0, z1 = z1, color = color })
			end
		end
		local nextOpen: { Run } = {}
		for _, run in row do
			local merged = false
			for k, prior in open do
				if
					math.abs(prior.x0 - run.x0) < 1e-6
					and math.abs(prior.x1 - run.x1) < 1e-6
					and prior.color == run.color
					and math.abs(prior.z1 - run.z0) < 1e-6
				then
					prior.z1 = run.z1
					table.insert(nextOpen, prior)
					table.remove(open, k)
					merged = true
					break
				end
			end
			if not merged then
				table.insert(nextOpen, run)
			end
		end
		for _, prior in open do
			table.insert(done, prior)
		end
		open = nextOpen
	end
	for _, prior in open do
		table.insert(done, prior)
	end
	for i, run in done do
		local name = `Ground{i}`
		addSlab(
			ctx,
			"Ground",
			name,
			run.x0,
			run.x1,
			run.z0,
			run.z1,
			0,
			TUNING.groundThickness,
			run.color,
			TUNING.groundMaterial
		)
	end
end

-- Each lake: its bed (ground under water, with banks sloping down from the shore so a car can climb out) and
-- its water surface, which nothing collides with.
local function addLakes(ctx: Ctx)
	local lakes: { LakeData } = ctx.layout.lakes or {}
	for _, lake in lakes do
		local width, depthZ = lake.max.X - lake.min.X, lake.max.Y - lake.min.Y
		local cx, cz = (lake.min.X + lake.max.X) / 2, (lake.min.Y + lake.max.Y) / 2
		local thickness = TUNING.groundThickness
		local bedColor = TUNING.lakeBedColor
		addSlab(
			ctx,
			"Ground",
			`{lake.id}Bed`,
			lake.min.X,
			lake.max.X,
			lake.min.Y,
			lake.max.Y,
			lake.bedY,
			thickness,
			bedColor,
			Enum.Material.Mud
		)
		local depth = -lake.bedY
		if depth > 0 then
			local run = math.min(depth * TUNING.bankRun, width / 2, depthZ / 2)
			local banks = {
				{ edge = Vector3.new(cx, 0, lake.min.Y), inward = Vector3.zAxis, length = width },
				{ edge = Vector3.new(cx, 0, lake.max.Y), inward = -Vector3.zAxis, length = width },
				{ edge = Vector3.new(lake.min.X, 0, cz), inward = Vector3.xAxis, length = depthZ },
				{ edge = Vector3.new(lake.max.X, 0, cz), inward = -Vector3.xAxis, length = depthZ },
			}
			for i, bank in banks do
				local r = bank.edge + UP * lake.bedY
				local frame, sizeY, sizeZ = wedgeFrame(r, bank.edge, r + bank.inward * run)
				local size = Vector3.new(bank.length, sizeY, sizeZ)
				add(ctx, wedge("Ground", `{lake.id}Bank{i}`, "ground", frame, size, bedColor, Enum.Material.Mud))
			end
		end
		local water = decor(
			block(
				"Water",
				lake.id,
				"water",
				CFrame.new(cx, (lake.bedY + lake.waterY) / 2, cz),
				Vector3.new(width, lake.waterY - lake.bedY, depthZ),
				TUNING.waterColor,
				Enum.Material.SmoothPlastic
			)
		)
		water.transparency = TUNING.waterTransparency
		add(ctx, water)
		gridInsert(ctx.grid, { c = Vector2.new(cx, cz), u = Vector2.xAxis, ha = width / 2, hc = depthZ / 2 }, "lake")
	end
end

-- A mesa is a truncated pyramid: a box for its flat top, a wedge down each side and a corner wedge at each
-- corner (whose sloped faces meet along the diagonal, like MapLayout.groundHeight's max(dx, dz)). Every piece
-- reaches TUNING.bury below the ground along the same slope, so no seam shows at the foot.
local function addMesas(ctx: Ctx)
	local bury = TUNING.bury
	local mesas: { MesaData } = ctx.layout.mesas or {}
	for _, mesa in mesas do
		local h = mesa.height
		local run = (h + bury) / mesa.slope -- horizontal reach of a side, top edge to y = -bury
		local x0, x1, z0, z1 = mesa.topMin.X, mesa.topMax.X, mesa.topMin.Y, mesa.topMax.Y
		local color, material = TUNING.mesaColor, Enum.Material.Ground
		local topFrame = CFrame.new((x0 + x1) / 2, (h - bury) / 2, (z0 + z1) / 2)
		add(
			ctx,
			block(
				"Ground",
				`{mesa.id}Top`,
				"ground",
				topFrame,
				Vector3.new(x1 - x0, h + bury, z1 - z0),
				color,
				material
			)
		)
		local sides = {
			{ edge = Vector3.new((x0 + x1) / 2, h, z0), out = -Vector3.zAxis, length = x1 - x0, name = "North" },
			{ edge = Vector3.new((x0 + x1) / 2, h, z1), out = Vector3.zAxis, length = x1 - x0, name = "South" },
			{ edge = Vector3.new(x0, h, (z0 + z1) / 2), out = -Vector3.xAxis, length = z1 - z0, name = "West" },
			{ edge = Vector3.new(x1, h, (z0 + z1) / 2), out = Vector3.xAxis, length = z1 - z0, name = "East" },
		}
		for _, side in sides do
			local r = side.edge - UP * (h + bury)
			local frame, sizeY, sizeZ = wedgeFrame(r, side.edge, r + side.out * run)
			local size = Vector3.new(side.length, sizeY, sizeZ)
			add(ctx, wedge("Ground", `{mesa.id}{side.name}`, "ground", frame, size, color, material))
		end
		-- A CornerWedgePart's peak is over its (+X, -Z) bottom corner and it slopes down toward -X and +Z. For
		-- each corner pick the two outward directions a, b with b = (a.Z, 0, -a.X), so (-a, up, b) is a right-
		-- handed frame: the peak sits on the mesa's top corner and the slopes fall away outward.
		for _, corner in { { x1, z0, 1, -1 }, { x0, z1, -1, 1 }, { x0, z0, -1, -1 }, { x1, z1, 1, 1 } } do
			local cx, cz, sx, sz = corner[1], corner[2], corner[3], corner[4]
			local outX, outZ = Vector3.new(sx, 0, 0), Vector3.new(0, 0, sz)
			local a, b = outX, outZ
			if sz ~= -sx then
				a, b = outZ, outX
			end
			local center = Vector3.new(cx + sx * run / 2, (h - bury) / 2, cz + sz * run / 2)
			local spec = block(
				"Ground",
				`{mesa.id}Corner{if sx > 0 then "E" else "W"}{if sz > 0 then "S" else "N"}`,
				"ground",
				CFrame.fromMatrix(center, -a, UP, b),
				Vector3.new(run, h + bury, run),
				color,
				material
			)
			spec.class = "CornerWedgePart"
			spec.shape = "cornerWedge"
			add(ctx, spec)
		end
		local foot = Vector2.new(x1 - x0, z1 - z0) / 2 + Vector2.new(run, run)
		gridInsert(
			ctx.grid,
			{ c = Vector2.new((x0 + x1) / 2, (z0 + z1) / 2), u = Vector2.xAxis, ha = foot.X, hc = foot.Y },
			"mesa"
		)
	end
end

-- Jump ramps: a wedge rising toward the way the ramp faces, its lip at the front.
local function addJumpRamps(ctx: Ctx)
	local ramps: { RampData } = ctx.layout.jumpRamps or {}
	for _, ramp in ramps do
		-- A WedgePart rises toward its back (+Z), so turn it half round from the ramp's facing.
		local facing = CFrame.Angles(0, math.rad(ramp.yaw), 0)
		local frame = CFrame.new(ramp.position + UP * (ramp.size.Y / 2)) * facing * CFrame.Angles(0, math.pi, 0)
		add(ctx, wedge("Ground", ramp.id, "ramp", frame, ramp.size, TUNING.rampColor, Enum.Material.Concrete))
		local look = flat(facing.LookVector).Unit
		gridInsert(ctx.grid, { c = flat(ramp.position), u = look, ha = ramp.size.Z / 2, hc = ramp.size.X / 2 }, "ramp")
	end
end

---------------------------------------------------------------------------------------------------------------
-- Landmarks
---------------------------------------------------------------------------------------------------------------

local function addLandmarks(ctx: Ctx)
	local landmarks: { LandmarkData } = ctx.layout.landmarks or {}
	for _, landmark in landmarks do
		local folder = `Landmarks/{landmark.id}`
		container(ctx, folder, "Model", Enum.ModelStreamingMode.Atomic)
		local size = landmark.size
		local facing = CFrame.Angles(0, math.rad(landmark.yaw), 0)
		local base = CFrame.new(landmark.position) * facing -- on the ground, looking out of its entrance
		local color = TUNING.landmarkColors[landmark.kind] or TUNING.landmarkDefaultColor
		local bury = TUNING.bury
		local function part(
			name: string,
			offset: Vector3,
			partSize: Vector3,
			partColor: Color3,
			material: Enum.Material
		): PartSpec
			local spec = block(folder, name, "landmark", base * CFrame.new(offset), partSize, partColor, material)
			add(ctx, spec)
			return spec
		end
		part(
			"Body",
			Vector3.new(0, (size.Y - bury) / 2, 0),
			Vector3.new(size.X, size.Y + bury, size.Z),
			color,
			Enum.Material.Concrete
		)

		-- One accent on the entrance side (local -Z) or the roof says what the building is.
		local front = -size.Z / 2 - TUNING.accentDepth / 2
		local kind = landmark.kind
		if kind == "showroom" or kind == "studio" or kind == "office" then
			local band = Vector3.new(size.X * 0.8, size.Y * 0.55, TUNING.accentDepth)
			local glass =
				part("Glass", Vector3.new(0, 1 + band.Y / 2, front), band, TUNING.glassColor, Enum.Material.Glass)
			glass.transparency = 0.2
		elseif kind == "warehouse" or kind == "garage" then
			local door = Vector3.new(size.X * 0.6, math.min(size.Y * 0.6, 18), TUNING.accentDepth)
			part("Doors", Vector3.new(0, door.Y / 2, front), door, TUNING.doorColor, Enum.Material.DiamondPlate)
		elseif kind == "factory" then
			local roof = Vector3.new(size.X * 0.8, size.Y * 0.15, size.Z * 0.25)
			part("Roof", Vector3.new(0, size.Y + roof.Y / 2, 0), roof, color, Enum.Material.Concrete)
			local stack = Vector3.new(10, size.Y * 0.8, 10)
			local stackAt = Vector3.new(size.X * 0.4, size.Y + stack.Y / 2, size.Z * 0.3)
			part("Stack", stackAt, stack, TUNING.doorColor, Enum.Material.Concrete)
		elseif kind == "control_tower" then
			local width = math.min(size.Z * 0.5, 30)
			local tower = Vector3.new(width, size.Y, width)
			local towerAt = Vector3.new(size.X / 2 - width / 2, size.Y + tower.Y / 2, 0)
			part("Tower", towerAt, tower, color, Enum.Material.Concrete)
			local cab = Vector3.new(width * 1.4, 8, width * 1.4)
			local cabAt = Vector3.new(towerAt.X, size.Y * 2 + cab.Y / 2, 0)
			local glass = part("Cab", cabAt, cab, TUNING.glassColor, Enum.Material.Glass)
			glass.transparency = 0.2
		end
		local look = flat(facing.LookVector).Unit
		gridInsert(ctx.grid, { c = flat(landmark.position), u = look, ha = size.Z / 2, hc = size.X / 2 }, "landmark")
	end
end

---------------------------------------------------------------------------------------------------------------
-- Locations, their props, and the player spawns
---------------------------------------------------------------------------------------------------------------

local ATTRIBUTE_TYPES: { [string]: boolean } = {
	string = true,
	number = true,
	boolean = true,
	Vector2 = true,
	Vector3 = true,
	Color3 = true,
	CFrame = true,
	UDim = true,
	UDim2 = true,
	BrickColor = true,
	NumberRange = true,
	EnumItem = true,
}

-- The nearest point on any road centre line (plan), for keeping the way from a location to its road clear.
local function nearestRoadPoint(ctx: Ctx, p: Vector2): Vector2?
	local edge, along = nearestEdge(ctx, p)
	return if edge then edge.from.plan + edge.u * along else nil
end

local ROAD_KINDS: { [string]: boolean } = { road = true, sidewalk = true, support = true }

-- Props stand behind a pad (its back is away from the road it faces), parented to the location's part.
local function addProps(ctx: Ctx, location: LocationData, frame: CFrame)
	local size = location.size
	local floor = -size.Y / 2 -- the pad's bottom face, on the surface, in the part's own frame
	local back = size.Z / 2 + TUNING.propGap
	local look = flat(frame.LookVector).Unit
	local count = 0
	local function propFootprint(offset: Vector3, propSize: Vector3): Rect
		local cframe = frame * CFrame.new(offset)
		return { c = flat(cframe.Position), u = look, ha = propSize.Z / 2, hc = propSize.X / 2 }
	end
	local function prop(
		offset: Vector3,
		propSize: Vector3,
		color: Color3,
		material: Enum.Material,
		solid: boolean,
		check: boolean
	): PartSpec?
		local cframe = frame * CFrame.new(offset)
		local footprint = propFootprint(offset, propSize)
		if check and gridHits(ctx.grid, footprint, ROAD_KINDS, 0) then
			note(ctx, `location {location.id}: a prop would stand on a road, left out`)
			return nil
		end
		count += 1
		local spec = block("Locations", `{location.tag}Prop{count}`, "prop", cframe, propSize, color, material)
		spec.parent = location.id
		if not solid then
			decor(spec)
		end
		add(ctx, spec)
		gridInsert(ctx.grid, footprint, "prop")
		return spec
	end
	local function marking()
		local inset = TUNING.markingInset
		local markingSize = Vector3.new(size.X - 2 * inset, TUNING.markingThickness, size.Z - 2 * inset)
		if markingSize.X > 0 and markingSize.Z > 0 then
			local color = TUNING.tagColors[location.tag] or TUNING.defaultTagColor
			local y = floor + TUNING.markingLift + TUNING.markingThickness / 2
			prop(Vector3.new(0, y, 0), markingSize, color, Enum.Material.SmoothPlastic, false, false)
		end
	end
	local function standing(postSize: Vector3, x: number, solid: boolean): PartSpec?
		return prop(
			Vector3.new(x, floor + postSize.Y / 2, back + postSize.Z / 2),
			postSize,
			TUNING.propColor,
			Enum.Material.SmoothPlastic,
			solid,
			true
		)
	end
	-- A closed garage door behind the pad, facing the bay: two posts (checked against roads; no door unless both
	-- stand clear), the door panel between them and a header across their tops.
	local function garageDoor()
		local door, post = TUNING.garageDoor, TUNING.garageDoorPost
		local spread = door.X / 2 + post.X / 2
		local z = back + post.Z / 2
		-- Check both posts before building either, so a blocked side never leaves a lone post behind.
		for _, side in { -1, 1 } do
			local footprint = propFootprint(Vector3.new(side * spread, floor + post.Y / 2, z), post)
			if gridHits(ctx.grid, footprint, ROAD_KINDS, 0) then
				note(ctx, `location {location.id}: a garage door would stand on a road, left out`)
				return
			end
		end
		for _, side in { -1, 1 } do
			standing(post, side * spread, true)
		end
		prop(Vector3.new(0, floor + door.Y / 2, z), door, TUNING.garageDoorColor, Enum.Material.Metal, true, false)
		local header = Vector3.new(door.X + 2 * post.X, TUNING.garageDoorHeader, post.Z)
		prop(
			Vector3.new(0, floor + post.Y + header.Y / 2, z),
			header,
			TUNING.tagColors[location.tag] or TUNING.defaultTagColor,
			Enum.Material.SmoothPlastic,
			true,
			false
		)
	end
	local function sign()
		local post, board = TUNING.signPost, TUNING.signBoard
		local x = size.X / 2 - board.X / 2
		if standing(post, x, false) then
			local y = floor + post.Y + board.Y / 2
			local color = TUNING.tagColors[location.tag] or TUNING.defaultTagColor
			prop(Vector3.new(x, y, back + post.Z / 2), board, color, Enum.Material.SmoothPlastic, false, false)
		end
	end

	local tag = location.tag
	if tag == "SpawnPad" or tag == "TrailerSpawn" or tag == "TowDrop" or tag == "Breakdown" then
		-- A painted bay only. Cars (and Phase 8's trailers and broken-down cars) stand on these, so nothing is
		-- built there that they could hit.
		marking()
	elseif tag == "ChargerStall" then
		marking()
		standing(TUNING.chargerPost, 0, false)
	elseif tag == "TruckCharger" then
		marking()
		standing(TUNING.truckChargerPost, 0, false)
	elseif tag == "FuelPump" then
		marking()
		standing(TUNING.fuelPump, 0, false)
	elseif tag == "Dealership" or tag == "UsedLot" or tag == "DesignStudio" or tag == "JobDepot" then
		marking()
		sign()
	elseif tag == "CustomShop" then
		marking()
		garageDoor()
	elseif tag == "RideshareHotspot" then
		marking()
		standing(TUNING.hotspotPost, size.X / 2 - TUNING.hotspotPost.X, false)
	elseif tag == "HousePlot" then
		local inset = TUNING.housePadInset
		local padSize = Vector3.new(size.X * inset, TUNING.housePadThickness, size.Z * inset)
		local color = TUNING.tagColors.HousePlot or TUNING.defaultTagColor
		prop(Vector3.new(0, floor + padSize.Y / 2, 0), padSize, color, Enum.Material.Concrete, false, false)
	elseif tag == "MeetSpot" then
		marking()
		local rail = Vector3.new(size.X, TUNING.overlookRailHeight, TUNING.overlookRailThickness)
		prop(
			Vector3.new(0, floor + rail.Y / 2, back + rail.Z / 2),
			rail,
			TUNING.railPropColor,
			Enum.Material.Concrete,
			true,
			true
		)
	elseif tag == "DragStripGate" then
		-- A gantry across the strip: posts beside the road (slid outward until clear), a beam overhead.
		local post = TUNING.gatePostSize
		local postSize = Vector3.new(post, TUNING.gateClearHeight + TUNING.gateBeamHeight, post)
		local spread = size.X / 2 + TUNING.gatePostGap + post / 2
		local placed = false
		while spread <= size.X / 2 + TUNING.gatePostSearch and not placed do
			local clear = true
			for _, side in { -1, 1 } do
				local at = frame * CFrame.new(side * spread, 0, 0)
				local footprint: Rect = { c = flat(at.Position), u = look, ha = post / 2, hc = post / 2 }
				if gridHits(ctx.grid, footprint, ROAD_KINDS, 0) then
					clear = false
				end
			end
			if clear then
				placed = true
			else
				spread += post
			end
		end
		if placed then
			for _, side in { -1, 1 } do
				prop(
					Vector3.new(side * spread, floor + postSize.Y / 2, 0),
					postSize,
					TUNING.propColor,
					Enum.Material.Metal,
					true,
					false
				)
			end
			local beam = Vector3.new(2 * spread + post, TUNING.gateBeamHeight, post)
			local beamY = floor + TUNING.gateClearHeight + beam.Y / 2
			prop(
				Vector3.new(0, beamY, 0),
				beam,
				TUNING.tagColors.DragStripGate or TUNING.defaultTagColor,
				Enum.Material.SmoothPlastic,
				false,
				false
			)
		else
			note(ctx, `location {location.id}: no clear ground beside the road for the gate posts`)
		end
	end
end

local function addLocations(ctx: Ctx)
	for _, location in ctx.layout.locations do
		local facing = CFrame.Angles(0, math.rad(location.yaw), 0)
		-- The part's bottom face sits on the surface at location.position.
		local frame = CFrame.new(location.position + UP * (location.size.Y / 2)) * facing
		local volume = TUNING.volumeTags[location.tag] == true
		local color = TUNING.tagColors[location.tag] or TUNING.defaultTagColor
		local spec =
			block("Locations", location.id, "location", frame, location.size, color, Enum.Material.SmoothPlastic)
		spec.collide = false
		spec.query = false -- wheel raycasts and spawn raycasts go straight through to the road or ground
		spec.touch = not volume -- pads can sense a car arriving; volumes are checked by position
		spec.shadow = false
		spec.transparency = if volume then 1 else TUNING.padTransparency
		spec.tag = location.tag
		local attributes: { [string]: any } = { DisplayName = location.displayName, Zone = location.zone }
		local given: { [string]: any } = location.attributes or {}
		for key, value in given do
			if ATTRIBUTE_TYPES[typeof(value)] then
				attributes[key] = value
			else
				note(ctx, `location {location.id}: attribute {key} is a {typeof(value)}, which parts can't hold`)
			end
		end
		spec.attributes = attributes
		add(ctx, spec)

		local look = flat(facing.LookVector).Unit
		local center = flat(location.position)
		local margin = if volume then 0 else TUNING.locationMargin
		local footprint: Rect =
			{ c = center, u = look, ha = location.size.Z / 2 + margin, hc = location.size.X / 2 + margin }
		gridInsert(ctx.grid, footprint, "location")
		if not volume then
			-- Keep the way from the pad to its road clear of buildings.
			local road = nearestRoadPoint(ctx, center)
			if road and (road - center).Magnitude > 1 then
				local way = road - center
				local corridor: Rect =
					{ c = (center + road) / 2, u = way.Unit, ha = way.Magnitude / 2, hc = TUNING.accessWidth / 2 }
				gridInsert(ctx.grid, corridor, "access")
			end
		end
		addProps(ctx, location, frame)
	end
end

local function addSpawns(ctx: Ctx)
	for i, at in ctx.layout.playerSpawns do
		local size = TUNING.spawnSize
		local spec = block(
			"PlayerSpawns",
			`PlayerSpawn{i}`,
			"spawn",
			at + UP * (size.Y / 2),
			size,
			TUNING.spawnColor,
			Enum.Material.SmoothPlastic
		)
		spec.class = "SpawnLocation"
		spec.collide = false -- a character spawns on top and settles onto the ground; cars drive over it
		spec.query = false
		spec.shadow = false
		spec.transparency = TUNING.spawnTransparency
		add(ctx, spec)
	end
end

---------------------------------------------------------------------------------------------------------------
-- Display pads: the dealership's brand sections and the used lot's numbered spaces (Phase 4)
---------------------------------------------------------------------------------------------------------------

-- What a display pad must not stand on. Roads, sidewalks and driveways would put a car in the street; landmarks,
-- locations (with their margins) and props are other things' ground.
local PAD_BLOCKERS: { [string]: boolean } = {
	road = true,
	sidewalk = true,
	driveway = true,
	support = true,
	landmark = true,
	location = true,
	prop = true,
	ramp = true,
	mesa = true,
	lake = true,
}

-- A pad's footprint, grown by `grow` on every side.
local function padRect(pad: CFrame, size: Vector3, grow: number): Rect
	local look = flat(pad.LookVector).Unit
	return { c = flat(pad.Position), u = look, ha = size.Z / 2 + grow, hc = size.X / 2 + grow }
end

-- The rectangle round pads that share pads[1]'s heading, grown by `grow` (nil with no pads).
local function areaRect(pads: { CFrame }, size: Vector3, grow: number): Rect?
	if #pads == 0 then
		return nil
	end
	local first = pads[1]
	local u = flat(first.LookVector).Unit
	local l = perp(u)
	local minA, maxA, minC, maxC = HUGE, -HUGE, HUGE, -HUGE
	for _, pad in pads do
		for _, corner in rectCorners(padRect(pad, size, 0)) do
			local along, across = corner:Dot(u), corner:Dot(l)
			minA, maxA = math.min(minA, along), math.max(maxA, along)
			minC, maxC = math.min(minC, across), math.max(maxC, across)
		end
	end
	local c = u * ((minA + maxA) / 2) + l * ((minC + maxC) / 2)
	return { c = c, u = u, ha = (maxA - minA) / 2 + grow, hc = (maxC - minC) / 2 + grow }
end

-- One platform; `name` within `folder`. Notes a pad that would stand on something it mustn't.
local function addDisplayPad(
	ctx: Ctx,
	folder: string,
	name: string,
	pad: CFrame,
	size: Vector3,
	tag: string,
	attributes: { [string]: any },
	label: string?
)
	if gridHits(ctx.grid, padRect(pad, size, 0), PAD_BLOCKERS, 0) then
		note(ctx, `display pad {folder}/{name} stands on a road, sidewalk, landmark or location`)
	end
	local spec = block(
		folder,
		name,
		"displayPad",
		pad * CFrame.new(0, size.Y / 2, 0),
		size,
		TUNING.displayPadColor,
		TUNING.displayPadMaterial
	)
	spec.shadow = false
	spec.tag = tag
	spec.attributes = attributes
	if label then
		spec.labels = {
			{
				face = Enum.NormalId.Top,
				text = label,
				color = TUNING.padNumberColor,
				center = TUNING.padNumberCenter,
				size = TUNING.padNumberSize,
			},
		}
	end
	add(ctx, spec)
end

-- Keeps lots, buildings and streetlights off a group of pads: each pad, and the rectangle round all of them that
-- face the same way (so nothing stands between the rows).
local function reservePads(ctx: Ctx, pads: { CFrame }, size: Vector3)
	for _, pad in pads do
		gridInsert(ctx.grid, padRect(pad, size, TUNING.displayPadMargin), "location")
	end
	local byHeading: { [string]: { CFrame } } = {}
	local order: { string } = {}
	for _, pad in pads do
		local look = flat(pad.LookVector).Unit
		local key = `{math.round(look.X * 1000)}:{math.round(look.Y * 1000)}`
		if byHeading[key] == nil then
			byHeading[key] = {}
			table.insert(order, key)
		end
		table.insert(byHeading[key], pad)
	end
	for _, key in order do
		local area = areaRect(byHeading[key], size, TUNING.displayAreaMargin)
		if area then
			gridInsert(ctx.grid, area, "location")
		end
	end
end

-- A brand's name board on a post, centred behind a section's pads and facing the way they do, its name on both
-- sides.
local function addBrandSign(ctx: Ctx, folder: string, brandId: string, pads: { CFrame }, size: Vector3)
	if #pads == 0 then
		return
	end
	local first = pads[1]
	local sum = Vector3.zero
	for _, pad in pads do
		sum += pad.Position
	end
	local centre = CFrame.new(sum / #pads) * first.Rotation
	local post, board = TUNING.brandSignPost, TUNING.brandSignBoard
	local back = size.Z / 2 + TUNING.brandSignGap + post.Z / 2 -- behind the pads is local +Z
	local postFrame = centre * CFrame.new(0, post.Y / 2, back)
	local footprint: Rect =
		{ c = flat(postFrame.Position), u = flat(first.LookVector).Unit, ha = board.Z / 2, hc = board.X / 2 }
	if gridHits(ctx.grid, footprint, ROAD_KINDS, 0) then
		note(ctx, `the {brandId} brand sign would stand on a road, left out`)
		return
	end
	local brand = Brands[brandId]
	local text = if brand then brand.displayName else brandId
	local postSpec = block(folder, "SignPost", "sign", postFrame, post, TUNING.propColor, Enum.Material.Metal)
	postSpec.shadow = false
	add(ctx, postSpec)
	local boardFrame = centre * CFrame.new(0, post.Y + board.Y / 2, back)
	local boardSpec =
		block(folder, "Sign", "sign", boardFrame, board, TUNING.brandSignColor, Enum.Material.SmoothPlastic)
	boardSpec.labels = {
		{ face = Enum.NormalId.Front, text = text, color = TUNING.brandSignTextColor },
		{ face = Enum.NormalId.Back, text = text, color = TUNING.brandSignTextColor },
	}
	add(ctx, boardSpec)
	gridInsert(ctx.grid, footprint, "prop")
end

local function addDisplayPads(ctx: Ctx)
	local pads = Dealership.pads
	local dealership = ctx.layout.dealership
	if dealership then
		container(ctx, "Dealership", "Folder")
		for _, section in dealership.sections do
			local folder = `Dealership/{section.brandId}`
			container(ctx, folder, "Folder")
			for i, pad in section.pads do
				local attributes: { [string]: any } =
					{ [pads.brandAttribute] = section.brandId, [pads.indexAttribute] = i }
				addDisplayPad(ctx, folder, `Pad{i}`, pad, dealership.padSize, pads.dealershipTag, attributes, nil)
			end
		end
		-- Reserve after placing every pad, so one section's margins never count against its neighbour's pads, and
		-- all sections together, so the rows facing one way clear their whole block.
		local all: { CFrame } = {}
		for _, section in dealership.sections do
			table.move(section.pads, 1, #section.pads, #all + 1, all)
		end
		reservePads(ctx, all, dealership.padSize)
		for _, section in dealership.sections do
			addBrandSign(ctx, `Dealership/{section.brandId}`, section.brandId, section.pads, dealership.padSize)
		end
	end
	local usedLot = ctx.layout.usedLot
	if usedLot then
		container(ctx, "UsedLot", "Folder")
		for i, pad in usedLot.pads do
			local attributes: { [string]: any } = { [pads.indexAttribute] = i }
			addDisplayPad(ctx, "UsedLot", `Space{i}`, pad, usedLot.padSize, pads.usedLotTag, attributes, tostring(i))
		end
		reservePads(ctx, usedLot.pads, usedLot.padSize)
	end
end

---------------------------------------------------------------------------------------------------------------
-- Billboards (Phase 12)
---------------------------------------------------------------------------------------------------------------

-- What a billboard must not stand on or over: roads and their sidewalks, other things' ground and the way from a
-- pad to its road.
local BILLBOARD_BLOCKERS: { [string]: boolean } = {
	road = true,
	sidewalk = true,
	driveway = true,
	support = true,
	landmark = true,
	location = true,
	access = true,
	prop = true,
	ramp = true,
	mesa = true,
	lake = true,
}

-- True when the ad face (width x height) is inside Roblox's ad unit limits (Config/Ads.billboards).
local function adFaceFits(size: Vector3): boolean
	local limits = Ads.billboards
	return size.X >= limits.minFace.X
		and size.Y >= limits.minFace.Y
		and size.X <= limits.maxFace.X
		and size.Y <= limits.maxFace.Y
end

-- Each billboard: a panel (its Front face, toward `yaw`, carries the AdGui; its Back face the brand's poster) on two
-- posts, the posts parented to the panel. Lots, buildings and streetlights keep off its footprint. A billboard whose
-- footprint would land on a road or another thing's ground, or whose face is outside the ad limits, is left out with
-- a note.
local function addBillboards(ctx: Ctx)
	local list = ctx.layout.billboards
	if list == nil or #list == 0 then
		return
	end
	local config = Ads.billboards
	container(ctx, "Billboards", "Folder")
	for _, data in list do
		local size = data.size
		if not adFaceFits(size) then
			note(ctx, `billboard {data.id}: its {size.X} x {size.Y} face is outside the ad unit limits, left out`)
			continue
		end
		local poster = config.posters[data.brandId]
		local brand = Brands[data.brandId]
		if poster == nil or brand == nil then
			note(ctx, `billboard {data.id}: no brand or poster for "{data.brandId}", left out`)
			continue
		end
		local width = TUNING.billboardPostWidth
		local facing = CFrame.Angles(0, math.rad(data.yaw), 0)
		local base = CFrame.new(data.position) * facing
		local footprint: Rect = {
			c = flat(data.position),
			u = flat(facing.LookVector).Unit,
			ha = math.max(size.Z, width) / 2,
			hc = size.X / 2,
		}
		if gridHits(ctx.grid, footprint, BILLBOARD_BLOCKERS, 0) then
			note(ctx, `billboard {data.id} would stand on a road, a location or a prop, left out`)
			continue
		end
		local panel = block(
			"Billboards",
			data.id,
			"billboard",
			base * CFrame.new(0, data.clearance + size.Y / 2, 0),
			size,
			poster.background,
			Enum.Material.SmoothPlastic
		)
		panel.tag = config.tag
		panel.attributes = {
			[config.idAttribute] = data.id,
			[config.brandAttribute] = data.brandId,
			Zone = data.zone,
		}
		panel.labels = {
			{
				face = config.posterFace,
				text = brand.displayName,
				color = poster.title,
				center = config.titleCenter,
				size = config.titleSize,
			},
			{
				face = config.posterFace,
				text = poster.tagline,
				color = poster.text,
				center = config.taglineCenter,
				size = config.taglineSize,
			},
		}
		panel.adUnit = {
			name = config.adUnitName,
			face = config.adFace,
			enableVideoAds = config.enableVideoAds,
			fallbackImage = poster.image,
		}
		add(ctx, panel)
		local postSize = Vector3.new(width, data.clearance, width)
		for i, side in { -1, 1 } do
			local post = block(
				"Billboards",
				`Post{i}`,
				"billboard",
				base * CFrame.new(side * (size.X / 2 - TUNING.billboardPostInset), data.clearance / 2, 0),
				postSize,
				TUNING.billboardPostColor,
				Enum.Material.Metal
			)
			post.parent = data.id
			post.shadow = false
			add(ctx, post)
		end
		gridInsert(ctx.grid, footprint, "prop")
	end
end

---------------------------------------------------------------------------------------------------------------
-- Streetlights
---------------------------------------------------------------------------------------------------------------

local LIGHT_BLOCKERS: { [string]: boolean } = {
	road = true,
	support = true,
	location = true,
	landmark = true,
	prop = true,
	ramp = true,
	lake = true,
	light = true,
	driveway = true,
}

-- Posts at an even spacing along each street and arterial, alternating sides road by road. A post's light
-- only switches on when no other lit post is within TUNING.lightEmitSpacing, so at most one light per 200
-- studs of street actually emits.
local function addStreetlights(ctx: Ctx)
	local lit: { [number]: { Vector2 } } = {}
	local cell = TUNING.lightEmitSpacing
	local function nearLit(p: Vector2): boolean
		local cx, cz = math.floor(p.X / cell), math.floor(p.Y / cell)
		for x = cx - 1, cx + 1 do
			for z = cz - 1, cz + 1 do
				local nearby: { Vector2 } = lit[cellKey(x, z)] or {}
				for _, other in nearby do
					if (other - p).Magnitude < cell then
						return true
					end
				end
			end
		end
		return false
	end
	local count = 0
	for _, edge in ctx.edges do
		local segment = edge.segment
		if segment == nil or not TUNING.lightKinds[edge.kind] then
			continue
		end
		local side = if edge.index % 2 == 0 then 1 else -1
		local first = edge.trimFrom + TUNING.lightEndGap
		local last = edge.length - edge.trimTo - TUNING.lightEndGap
		if last < first then
			continue
		end
		local posts = math.floor((last - first) / TUNING.lightInterval) + 1
		for i = 0, posts - 1 do
			local along = if posts == 1 then (first + last) / 2 else first + (last - first) * i / (posts - 1)
			-- On the sidewalk near its outer edge, or on the verge beside the road.
			local onSidewalk = edge.sidewalk > 0
			local lateral = if onSidewalk
				then edge.half + edge.sidewalk - TUNING.lightSidewalkInset
				else edge.half + TUNING.lightVerge
			local at = planAt(edge, along, side * lateral)
			local base = if onSidewalk then heightAt(edge, along) + TUNING.sidewalkRaise else ctx.groundAt(at.X, at.Y)
			local size = TUNING.postSize
			local footprint: Rect = { c = at, u = edge.u, ha = size / 2 + 0.5, hc = size / 2 + 0.5 }
			if gridHits(ctx.grid, footprint, LIGHT_BLOCKERS, 0) then
				continue
			end
			count += 1
			local postCenter = lift(at, base + TUNING.postHeight / 2)
			local postFrame = CFrame.lookAt(postCenter, postCenter + lift(edge.u, 0))
			local postSize = Vector3.new(size, TUNING.postHeight, size)
			add(
				ctx,
				block(
					"Streetlights",
					`Light{count}`,
					"light",
					postFrame,
					postSize,
					TUNING.postColor,
					Enum.Material.Metal
				)
			)
			-- The head hangs out over the road edge.
			local toward = -edge.l * side
			local head = TUNING.headSize
			local headAt = lift(at + toward * TUNING.headReach, base + TUNING.postHeight + head.Y / 2)
			local headFrame = CFrame.lookAt(headAt, headAt + lift(toward, 0))
			local headSpec = decor(
				block(
					"Streetlights",
					`Light{count}Head`,
					"light",
					headFrame,
					head,
					TUNING.headColor,
					Enum.Material.Neon
				)
			)
			local headPlan = flat(headAt)
			if not nearLit(headPlan) then
				headSpec.light = {
					kind = "spot",
					brightness = TUNING.lightBrightness,
					range = TUNING.lightRange,
					angle = TUNING.lightAngle,
					color = TUNING.lightColor,
					face = Enum.NormalId.Bottom,
				}
				local key = cellKey(math.floor(headPlan.X / cell), math.floor(headPlan.Y / cell))
				lit[key] = lit[key] or {}
				table.insert(lit[key], headPlan)
			end
			add(ctx, headSpec)
			gridInsert(ctx.grid, footprint, "light")
		end
	end
end

---------------------------------------------------------------------------------------------------------------
-- Lots and buildings
---------------------------------------------------------------------------------------------------------------

-- The faces of the road map (the city blocks), found by walking round each block with it on the walk's +l
-- side: at every node, turn onto the next road clockwise (decreasing angle) from the one just arrived on.
-- faces[id * 2 + 0] is the block on the +l side of edge `id` going from `from` to `to`; faces[id * 2 + 1] the
-- block on its other side.
local function findBlocks(ctx: Ctx): { [number]: number }
	local faces: { [number]: number } = {}
	local count = 0
	for _, start in ctx.edges do
		for direction = 0, 1 do
			if faces[start.id * 2 + direction] then
				continue
			end
			count += 1
			local id, dir = start.id, direction
			local guard = 0
			while faces[id * 2 + dir] == nil and guard < 100000 do
				guard += 1
				faces[id * 2 + dir] = count
				local edge = ctx.edges[id]
				local node = if dir == 0 then edge.to else edge.from
				local index = if dir == 0 then edge.toIndex else edge.fromIndex
				local nextRoad = node.roads[(index - 2) % #node.roads + 1]
				id = nextRoad.edge
				dir = if nextRoad.atFrom then 0 else 1
			end
		end
	end
	return faces
end

local LOT_BLOCKERS: { [string]: boolean } = {
	road = true,
	sidewalk = true,
	driveway = true,
	support = true,
	landmark = true,
	ramp = true,
	mesa = true,
	lake = true,
	location = true,
	access = true,
	prop = true,
	light = true,
	lot = true,
}

local function inflate(rect: Rect, by: number): Rect
	return { c = rect.c, u = rect.u, ha = rect.ha + by, hc = rect.hc + by }
end

-- Lots along both sides of every town street and arterial, each one a plot from the sidewalk back to a fixed
-- depth. The zone's density decides whether a plot gets a building, and it does when the plot is inside that
-- zone, on flat open ground and clear of everything else. Neighbouring built plots share one paved lot. Every
-- random number is drawn whether or not it is used, so one blocked plot never reshuffles the rest.
local function addBuildings(ctx: Ctx, zones: { ZoneData })
	local layout = ctx.layout
	local faces = findBlocks(ctx)
	local blockNames: { [string]: string } = {}
	local blocks, lots, buildings = 0, 0, 0
	local reserved = layout.reservedWestOfX or -HUGE
	local limit = ctx.half - 1
	local plotDepth = TUNING.setbackMax + TUNING.depthMax

	local function usable(plot: Rect, frontage: string): ZoneData?
		local zone = zoneAt(zones, plot.c)
		if zone == nil or zone.buildingDensity <= 0 then
			return nil
		end
		for _, p in rectCorners(plot) do
			if p.X < zone.min.X or p.X > zone.max.X or p.Y < zone.min.Y or p.Y > zone.max.Y then
				return nil
			end
			if math.abs(p.X) > limit or math.abs(p.Y) > limit or p.X < reserved then
				return nil
			end
			if math.abs(ctx.groundAt(p.X, p.Y)) > TUNING.maxLevelError then
				return nil
			end
		end
		-- Clear of everything, except this frontage's own plots (they line up edge to edge).
		local blocked = gridAny(ctx.grid, inflate(plot, TUNING.clearance), 0, function(shape)
			return LOT_BLOCKERS[shape.kind] == true and not (shape.kind == "lot" and shape.owner == frontage)
		end)
		return if blocked then nil else zone
	end

	for _, edge in ctx.edges do
		if edge.segment == nil or not TUNING.buildingKinds[edge.kind] then
			continue
		end
		for _, side in { 1, -1 } do
			local rng = Random.new(mixSeed(layout.seed, edge.index, if side == 1 then 1 else 2))
			local front = edge.half + edge.sidewalk + TUNING.frontageGap
			local face = faces[edge.id * 2 + (if side == 1 then 0 else 1)] or 0
			local along = edge.trimFrom + TUNING.cornerClear
			local stop = edge.length - edge.trimTo - TUNING.cornerClear
			local runStart: number? = nil
			local runEnd = 0
			local runCount = 0
			-- A paved lot under each row of two or more neighbouring buildings (a lone one stands on the ground).
			local function closeRun()
				local start = runStart
				local count = runCount
				runStart, runCount = nil, 0
				if start == nil or count < TUNING.minLotRow then
					return
				end
				lots += 1
				local c = planAt(edge, (start + runEnd) / 2, side * (front + plotDepth / 2))
				local y = TUNING.lotThickness / 2
				local frame = CFrame.lookAt(lift(c, y), lift(c + edge.u, y))
				local size = Vector3.new(plotDepth, TUNING.lotThickness, runEnd - start)
				add(ctx, decor(block("Lots", `Lot{lots}`, "lot", frame, size, TUNING.lotColor, Enum.Material.Concrete)))
			end
			while along + TUNING.lotMin <= stop do
				local width = math.min(rng:NextNumber(TUNING.lotMin, TUNING.lotMax), stop - along)
				local setback = rng:NextNumber(TUNING.setbackMin, TUNING.setbackMax)
				local depth = rng:NextNumber(TUNING.depthMin, TUNING.depthMax)
				local roll = rng:NextNumber()
				local tall = rng:NextNumber()
				local shade = rng:NextInteger(1, 1000000)
				if width < TUNING.lotMin then
					break
				end
				local plot: Rect = {
					c = planAt(edge, along + width / 2, side * (front + plotDepth / 2)),
					u = edge.u,
					ha = width / 2,
					hc = plotDepth / 2,
				}
				local frontage = `{edge.id}:{side}`
				local zone = usable(plot, frontage)
				if zone and roll < zone.buildingDensity then
					gridInsert(ctx.grid, plot, "lot", frontage)
					if runStart == nil then
						runStart = along
					end
					runEnd = along + width
					runCount += 1
					-- Group by block, and split big blocks into tiles so each Model stays compact.
					local tile = TUNING.blockTile
					local key = `{face}:{math.floor(plot.c.X / tile)}:{math.floor(plot.c.Y / tile)}`
					local blockName = blockNames[key]
					if blockName == nil then
						blocks += 1
						blockName = `Block{blocks}`
						blockNames[key] = blockName
						container(ctx, `Buildings/{blockName}`, "Model", Enum.ModelStreamingMode.Atomic)
					end
					buildings += 1
					local height = zone.buildingHeight.min + tall * (zone.buildingHeight.max - zone.buildingHeight.min)
					local c = planAt(edge, along + width / 2, side * (front + setback + depth / 2))
					local y = (height - TUNING.bury) / 2
					local frame = CFrame.lookAt(lift(c, y), lift(c + edge.u, y))
					local size = Vector3.new(depth, height + TUNING.bury, width - TUNING.buildingGap)
					local colors = zone.buildingColors
					local color = if #colors > 0 then colors[shade % #colors + 1] else TUNING.landmarkDefaultColor
					local spec = block(
						`Buildings/{blockName}`,
						`Building{buildings}`,
						"building",
						frame,
						size,
						color,
						TUNING.buildingMaterial
					)
					add(ctx, spec)
				else
					closeRun()
				end
				along += width
			end
			closeRun()
		end
	end
end

---------------------------------------------------------------------------------------------------------------
-- The plan
---------------------------------------------------------------------------------------------------------------

-- Every part of the county built from the given data, plus notes and counts. Pure: creates no instances.
function MapBuilder.planWith(layout: LayoutData, graph: GraphData): Plan
	local ctx: Ctx = {
		layout = layout,
		graph = graph,
		specs = {},
		containers = {},
		containerSet = {},
		notes = {},
		nodes = {},
		nodeById = {},
		edges = {},
		grid = newGrid(TUNING.gridCell),
		groundAt = layout.groundHeight or function(_x: number, _z: number): number
			return 0
		end,
		half = World.mapHalfExtent,
		driveways = {},
	}
	local persistent = Enum.ModelStreamingMode.Persistent
	container(ctx, "Ground", "Model", persistent)
	container(ctx, "Water", "Folder")
	container(ctx, "Roads", "Model", persistent)
	container(ctx, "Roads/Segments", "Folder")
	container(ctx, "Roads/Intersections", "Folder")
	container(ctx, "Roads/Lines", "Folder")
	container(ctx, "Sidewalks", "Folder")
	container(ctx, "Bridges", "Folder")
	container(ctx, "Landmarks", "Folder")
	container(ctx, "Locations", "Folder")
	container(ctx, "PlayerSpawns", "Folder")
	container(ctx, "Streetlights", "Folder")
	container(ctx, "Lots", "Folder")
	container(ctx, "Buildings", "Folder")

	local zones = zonesBySize(layout)
	prepare(ctx)
	solveJunctions(ctx)
	addSegments(ctx)
	setPadThickness(ctx)
	addPads(ctx)
	planDriveways(ctx)
	addSidewalks(ctx)
	addSupports(ctx)
	addGround(ctx, zones)
	addLakes(ctx)
	addMesas(ctx)
	addJumpRamps(ctx)
	addLandmarks(ctx)
	addLocations(ctx)
	addSpawns(ctx)
	addDisplayPads(ctx)
	addBillboards(ctx)
	addStreetlights(ctx)
	addBuildings(ctx, zones)

	-- Notes once each, in order.
	local seen: { [string]: boolean } = {}
	local notes: { string } = {}
	for _, text in ctx.notes do
		if not seen[text] then
			seen[text] = true
			table.insert(notes, text)
		end
	end
	local counts: { [string]: number } = {}
	for _, spec in ctx.specs do
		counts[spec.role] = (counts[spec.role] or 0) + 1
	end
	return { specs = ctx.specs, containers = ctx.containers, notes = notes, counts = counts }
end

-- The county's full plan from Config/MapLayout and Config/RoadGraph.
function MapBuilder.county(): Plan
	return MapBuilder.planWith(MapLayoutModule :: any, RoadGraphModule :: any)
end

-- Every part the build makes (docs/phase-2-contracts.md). Pure and deterministic.
function MapBuilder.plan(): { PartSpec }
	return MapBuilder.county().specs
end

---------------------------------------------------------------------------------------------------------------
-- The build
---------------------------------------------------------------------------------------------------------------

local function createPart(spec: PartSpec): BasePart
	local part: BasePart
	if spec.class == "WedgePart" then
		part = Instance.new("WedgePart")
	elseif spec.class == "CornerWedgePart" then
		part = Instance.new("CornerWedgePart")
	elseif spec.class == "SpawnLocation" then
		local spawn = Instance.new("SpawnLocation")
		spawn.Neutral = true
		spawn.Duration = 0 -- no spawn force field
		spawn.AllowTeamChangeOnTouch = false
		spawn.Enabled = true
		part = spawn
	else
		local plain = Instance.new("Part")
		plain.Shape = if spec.shape == "cylinder" then Enum.PartType.Cylinder else Enum.PartType.Block
		part = plain
	end
	part.Name = spec.name
	part.Size = spec.size
	part.CFrame = spec.cframe
	part.Color = spec.color
	part.Material = spec.material
	part.Transparency = spec.transparency
	part.Anchored = true
	part.CanCollide = spec.collide
	part.CanQuery = spec.query
	part.CanTouch = spec.touch
	part.CastShadow = spec.shadow
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	local tag = spec.tag
	if tag then
		part:AddTag(tag)
	end
	local attributes: { [string]: any } = spec.attributes or {}
	for key, value in attributes do
		part:SetAttribute(key, value)
	end
	local light = spec.light
	if light then
		local instance: Light
		if light.kind == "spot" then
			local spot = Instance.new("SpotLight")
			spot.Face = light.face
			spot.Angle = light.angle
			spot.Range = light.range
			instance = spot
		else
			local point = Instance.new("PointLight")
			point.Range = light.range
			instance = point
		end
		instance.Brightness = light.brightness
		instance.Color = light.color
		instance.Shadows = false
		instance.Parent = part
	end
	local labels: { LabelSpec } = spec.labels or {}
	for i, label in labels do
		local gui = Instance.new("SurfaceGui")
		gui.Name = `Label{i}`
		gui.Face = label.face
		gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
		gui.PixelsPerStud = TUNING.labelPixelsPerStud
		gui.LightInfluence = 0 -- readable by night too
		gui.Parent = part
		local center = label.center or Vector2.new(0.5, 0.5)
		local size = label.size or TUNING.labelSize
		local text = Instance.new("TextLabel")
		text.Name = "Text"
		text.AnchorPoint = Vector2.new(0.5, 0.5)
		text.Position = UDim2.fromScale(center.X, center.Y)
		text.Size = UDim2.fromScale(size.X, size.Y)
		text.BackgroundTransparency = 1
		text.Text = label.text
		text.TextColor3 = label.color
		text.Font = TUNING.labelFont
		text.TextScaled = true
		text.Parent = gui
	end
	local adUnit = spec.adUnit
	if adUnit then
		-- Built switched off: Services/AdsService turns it on at runtime only when ads may be served.
		local made, unit = pcall(Instance.new, "AdGui")
		if made then
			local ad: any = unit
			local set = pcall(function()
				ad.Name = adUnit.name
				ad.Face = adUnit.face
				ad.AdShape = Enum.AdShape.HorizontalRectangle
				ad.EnableVideoAds = adUnit.enableVideoAds
				if adUnit.fallbackImage ~= "" then
					ad.FallbackImage = adUnit.fallbackImage
				end
				ad.Enabled = false
			end)
			if set then
				ad.Parent = part
			else
				ad:Destroy()
				warn(`[MapBuilder] couldn't set up the AdGui on {spec.name}; add one by hand (Config/Ads)`)
			end
		else
			warn(`[MapBuilder] couldn't create an AdGui on {spec.name}; add one by hand (Config/Ads): {unit}`)
		end
	end
	return part
end

local building = false

-- Rebuilds Workspace.Map.Generated from the plan. Returns the number of instances under Generated.
function MapBuilder.build(): number
	if not RunService:IsStudio() then
		error("MapBuilder is a Studio-only tool", 2)
	end
	if RunService:IsRunning() then
		error("MapBuilder runs in Edit mode only; stop the playtest first", 2)
	end
	if building then
		error("MapBuilder is already building", 2)
	end
	building = true

	local ok, result = pcall(function(): number
		local plan = MapBuilder.county()

		local map = Workspace:FindFirstChild("Map")
		if map == nil then
			local folder = Instance.new("Folder")
			folder.Name = "Map"
			folder.Parent = Workspace
			map = folder
		end
		local mapFolder = map :: Instance
		local old = mapFolder:FindFirstChild("Generated")
		if old then
			old:Destroy()
		end
		local generated = Instance.new("Folder")
		generated.Name = "Generated"
		generated:SetAttribute("BuiltBy", "MapBuilder")
		generated.Parent = mapFolder

		-- Containers first, each parented as soon as it is made (parents are listed before children).
		local containers: { [string]: Instance } = { [""] = generated }
		for _, entry in plan.containers do
			local slash = string.find(entry.path, "/[^/]*$")
			local parentPath = if slash then string.sub(entry.path, 1, slash - 1) else ""
			local name = if slash then string.sub(entry.path, slash + 1) else entry.path
			local instance: Instance
			if entry.class == "Model" then
				local model = Instance.new("Model")
				if entry.streaming then
					model.ModelStreamingMode = entry.streaming
				end
				instance = model
			else
				instance = Instance.new("Folder")
			end
			instance.Name = name
			instance.Parent = containers[parentPath] or generated
			containers[entry.path] = instance
		end

		-- Parts in chunks: each part goes straight into its (already parented) container, so every flush is
		-- one small part, and Studio gets a frame between chunks.
		local byName: { [string]: { [string]: BasePart } } = {}
		for i, spec in plan.specs do
			local part = createPart(spec)
			local parent: Instance = containers[spec.folder] or generated
			if spec.parent then
				local holders = byName[spec.folder]
				local holder = holders and holders[spec.parent]
				if holder then
					parent = holder
				end
			end
			part.Parent = parent
			if spec.parent == nil then
				local holders = byName[spec.folder]
				if holders == nil then
					holders = {}
					byName[spec.folder] = holders
				end
				holders[spec.name] = part
			end
			if i % TUNING.partsPerChunk == 0 then
				task.wait()
			end
		end

		local summary: { string } = {}
		for role, count in plan.counts do
			table.insert(summary, `{role} {count}`)
		end
		table.sort(summary)
		print(`[MapBuilder] {#plan.specs} parts: {table.concat(summary, ", ")}`)
		for _, text in plan.notes do
			print(`[MapBuilder] note: {text}`)
		end
		return #generated:GetDescendants()
	end)

	building = false
	if not ok then
		error(result, 0)
	end
	print(`[MapBuilder] built Workspace.Map.Generated: {result} instances`)
	return result
end

return MapBuilder
