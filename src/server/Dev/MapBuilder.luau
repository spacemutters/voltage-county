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
--   Ground (Model, Persistent)   slabs with their top at y = 0 covering ±World.mapHalfExtent: each zone's ground
--                                (MapLayout groundMaterial), the green zones and the open country a patchwork of
--                                grass shades in tiles (groundShades, Config/Environment ground.tile), parks in their
--                                own grass; the lake beds with sloping banks in pale sand, the mesas
--                                (MapLayout.mesas), the grass hills at the edge of the map (MapLayout.hills) and the
--                                jump ramps
--   Water                        the bay (Dev/City/Scenery Water; not solid): thin sheets in bands of colour from the
--                                shore out, a foam line where the bank meets the water, coping on the shores
--   Roads (Model, Persistent)    Segments: one slab per road edge. Intersections: a pad at every node where
--                                3+ roads meet or a road bends or changes grade. Lines: lane lines and medians
--   Sidewalks                    raised kerbed sidewalks on Cedar Bend and Riverside streets and arterials, cut
--                                for a driveway flush with the road in front of every pad
--   Bridges                      railings, supports under raised roads, fill under low raised roads; the lake bridge
--                                as a white causeway (Dev/City/Scenery Causeway): a balustrade with a lit fascia, round
--                                piers, cap beams and arched spans over the water
--   Lots, Buildings              paved lots and buildings along town streets. The city (Dev/City, Config/City;
--                                docs/city/CITY_PLAN.md, ARCHETYPE_GUIDE.md) decides what stands on the plots: its
--                                archetypes where it places them, some merging plots and claiming depth behind them
--                                into the block's empty core (a paved Lots/ClaimB<n>), each site its own Atomic model
--                                Buildings/Tower<n> or Site<n> (LevelOfDetail SLIM, parts named B<n>...) with its night
--                                lights and signs in BuildingLights/<the same name> (Atomic, not SLIM) and a tower's
--                                main masses in the Persistent Skyline model; on a plot no archetype fits, the old facade
--                                (in its block tile's model, Buildings/Block<n>):
--                                where the zone has one (Config/Environment facades) a building is glass set in
--                                from its footprint, under floor bands that stand proud of it and a roof edge, or
--                                past towerFrom a glass tower with corner piers; some carry a plant box on the roof.
--                                Some buildings' glass is split at a floor line, one piece a night light (it glows
--                                from dusk to dawn). Parks (MapLayout.parks) get none
--   Landmarks                    the big buildings MapLayout.landmarks names (Models, Atomic); a landmark with a
--                                signBrand gets the brand's name on a sign on its roof
--   Features/<id>                MapLayout.features (Models, Atomic): the water tower, the diner and its sign, the
--                                bridge's arches
--   Streetlights                 posts along streets and arterials (Dev/City/Scenery Lamps: tall arms on the
--                                avenues, slim heads on town streets, globes round the lake) and acorn lamps along the
--                                causeway; only some of them emit light
--   Streetscape/Tile<x>_<z>      the city's scenery (Dev/City/Scenery; docs/city/SCENERY.md; Models per 500-stud tile,
--                                Atomic): palms in the sidewalks and beside the causeway, the beach (promenade, wall,
--                                coconut palms, dunes, lifeguard stands, umbrellas), Town Square's fountain and palm
--                                allée, bus shelters and crossings; their night lights in StreetscapeLights/Tile<x>_<z>
--   Trees/Tile<x>_<z>            trees (Config/Environment trees; Models per 500-stud tile, Atomic): a trunk that
--                                cars hit and one or two leaf blocks they pass through (or a palm: its trunk and a
--                                crown the build fills from ServerStorage.CityAssets.Palms, Dev/City/Scenery Palms),
--                                planted thick in the parks and in groves over the towns and the open country (thicker
--                                past the County Loop), clear of roads, sidewalks, lots, pads, house plots, props,
--                                landmarks and the scenery. Seeded: every build plants the same trees
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
-- Night lights (Config/Environment nightLights): streetlight heads, lit windows, the diner's neon and windows, the
-- water tower's beacon, the bridge's arches and the Ohm sign's light bar are tagged NightLight with their kind and
-- day colour, built in their day look with their Lights off. Services/DayNightService switches them at dusk and dawn.
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
local City = require(Config.City)
local Dealership = require(Config.Dealership)
local Environment = require(Config.Environment)
local MapLayoutModule = require(Config.MapLayout)
local RoadGraphModule = require(Config.RoadGraph)
local World = require(Config.World)

local CityBuilder = require(script.Parent.City.CityBuilder)
local MapTypes = require(script.Parent.MapTypes)
local Scenery = require(script.Parent.City.Scenery)

---------------------------------------------------------------------------------------------------------------
-- Types
---------------------------------------------------------------------------------------------------------------

-- The data shapes MapBuilder reads (docs/phase-2-contracts.md, "Data"). Only what the builder uses; the extra
-- MapLayout fields (lakes, mesas, hills, parks, features, jump ramps, landmarks, groundHeight) are optional so small
-- fixtures can leave them out.
export type GroundShade = { color: Color3, material: Enum.Material }

export type ZoneData = {
	id: string,
	displayName: string,
	min: Vector2,
	max: Vector2,
	groundColor: Color3,
	groundMaterial: Enum.Material?,
	groundShades: { GroundShade }?,
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
export type LandmarkData = {
	id: string,
	kind: string,
	position: Vector3,
	yaw: number,
	size: Vector3,
	signBrand: string?,
}
-- Parks and features: see Config/MapLayout's Park and Feature.
export type ParkData = {
	id: string,
	min: Vector2,
	max: Vector2,
	hole: { min: Vector2, max: Vector2 }?,
	groundColor: Color3?,
	groundMaterial: Enum.Material?,
}
export type FeatureData = {
	id: string,
	displayName: string,
	kind: string,
	position: Vector3,
	yaw: number,
	size: Vector3,
	sign: string?,
}
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
	hills: { MesaData }?,
	parks: { ParkData }?,
	features: { FeatureData }?,
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

-- The part specs (Dev/MapTypes, shared with the city builder Dev/City): re-exported here.
export type Role = MapTypes.Role
export type LabelSpec = MapTypes.LabelSpec
export type AdUnitSpec = MapTypes.AdUnitSpec
export type LightSpec = MapTypes.LightSpec
export type TextureSpec = MapTypes.TextureSpec
export type PartSpec = MapTypes.PartSpec
export type Container = MapTypes.Container

-- What the city builder did (Dev/City; tests/MapBuilder.spec and Dev/MapCheck report it).
export type CityStats = {
	legacy: { [string]: number }, -- plots left to the old look because no archetype fits, by district ("" for none)
	open: { [string]: number }, -- plots no archetype fits left open instead (Config/City openFallback), by district
	parts: { [string]: number }, -- building parts by district: city sites and old-look fallbacks together
	lights: number, -- building parts that are night lights
	skyline: number, -- parts in the Persistent Skyline model
	claims: number, -- core claims taken behind plots
	unplaced: { string }, -- one-offs (Config/City landmarks) whose archetype exists but that found no site
	missing: { string }, -- one-offs and configs whose archetype isn't ready yet
}

export type Plan = {
	specs: { PartSpec },
	containers: { Container },
	notes: { string }, -- things worth knowing (a road with no room left, a prop that didn't fit...)
	counts: { [string]: number }, -- parts per role
	sites: { CityBuilder.Site }, -- the city's sites built from their archetypes (Dev/City), in plan order
	city: CityStats,
	scenery: Scenery.Report, -- parts the street scenery added, by group (Dev/City/Scenery.plan)
}

---------------------------------------------------------------------------------------------------------------
-- Tuning. A dev tool, so its numbers live here rather than in Shared/Config (like Dev/AutoDriver's TUNING). How many
-- trees, where, the facades per zone, the budgets and the night looks are in Config/Environment.
---------------------------------------------------------------------------------------------------------------

-- A tree species at scale 1: its trunk (width, height) and its leaf blocks (size, the height of their bottom above the
-- ground, a turn in degrees on top of the tree's own). Pines take Config/Environment trees.pineColors.
type LeafShape = { size: Vector3, bottom: number, turn: number }
type TreeShape = { trunk: Vector2, leaves: { LeafShape }, pine: boolean }

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
	-- The lake's bed, banks and water: Config/CityScenery water (Dev/City/Scenery Water).
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
	-- Paved lots and core claims: a warm pale concrete a shade under the downtown ground (roast 2026-10-26 point 1).
	lotColor = Color3.fromRGB(194, 190, 182),
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
	-- A landmark's roof sign (signBrand): a board on two posts, set back from the entrance edge of the roof, the
	-- brand's name on both faces and a light bar under it that glows at night.
	roofSign = {
		widthShare = 0.3, -- of the landmark's width...
		maxWidth = 240, -- ...at most
		height = 28,
		thickness = 1.2,
		post = 1.6,
		postHeight = 10,
		postInset = 12, -- posts stand this far in from the board's ends
		setback = 30, -- from the roof's entrance edge
		lightBar = 1,
		color = Color3.fromRGB(28, 30, 34),
		textColor = Color3.fromRGB(245, 245, 242),
		lightColor = Color3.fromRGB(226, 230, 236),
		pixelsPerStud = 4,
	},

	-- Facades (Config/Environment facades, by zone). Glass stands glassInset inside the footprint, floor bands
	-- bandInset (proud of the glass) and the roof edge on the footprint itself, proud of both.
	glassInset = 0.6,
	bandInset = 0.2,
	parapetHeight = 2.5, -- the roof edge rises this far above the building's height (its roof)
	towerPier = 3, -- a tower's corner piers, square
	towerCrown = 4, -- a tower's roof edge reaches this far down from its height
	podiumBand = 2, -- a tower's band over its ground floor
	rooftopSize = Vector2.new(0.4, 0.35), -- a roof box's share of the building's depth and width
	rooftopHeight = { 4, 8 },
	rooftopEdge = 2, -- a roof box keeps this far inside the roof edge
	rooftopColor = Color3.fromRGB(118, 120, 124),

	-- Hills (MapLayout.hills): built like mesas, in grass (Config/Environment ground.hillShades).

	-- Trees (Config/Environment trees): shapes at scale 1. Plain blocks, 2 or 3 parts each.
	treeSpecies = {
		broadleaf = {
			trunk = Vector2.new(1.4, 9),
			leaves = {
				{ size = Vector3.new(12, 7, 12), bottom = 7, turn = 0 },
				{ size = Vector3.new(8, 5, 8), bottom = 12, turn = 45 },
			},
			pine = false,
		},
		round = {
			trunk = Vector2.new(1.1, 6),
			leaves = { { size = Vector3.new(8, 7, 8), bottom = 4.5, turn = 45 } },
			pine = false,
		},
		pine = {
			trunk = Vector2.new(1.2, 5),
			leaves = {
				{ size = Vector3.new(10, 8, 10), bottom = 3.5, turn = 0 },
				{ size = Vector3.new(6, 9, 6), bottom = 10, turn = 45 },
			},
			pine = true,
		},
		poplar = {
			trunk = Vector2.new(1, 5),
			leaves = { { size = Vector3.new(5, 16, 5), bottom = 4, turn = 45 } },
			pine = false,
		},
		-- A short trunk under two wide, flat canopies: the suburbs' and the country hammocks' shade tree.
		live_oak = {
			trunk = Vector2.new(1.6, 6),
			leaves = {
				{ size = Vector3.new(16, 4.5, 14), bottom = 5.5, turn = 0 },
				{ size = Vector3.new(11, 3.5, 12), bottom = 8.5, turn = 30 },
			},
			pine = false,
		},
		-- A low, round shrub-tree of the beach dunes and the lake ring.
		sea_grape = {
			trunk = Vector2.new(0.9, 2.5),
			leaves = { { size = Vector3.new(9, 5, 9), bottom = 1.5, turn = 45 } },
			pine = false,
		},
		-- Palms are Config/CityScenery palms (Dev/City/Scenery Palms): royal, coconut, sabal.
	} :: { [string]: TreeShape },
	treeTile = 500, -- trees are grouped into Atomic models per tile this many studs square
	treeMargin = 1, -- leaves keep this far clear of what they mustn't touch (a landmark's accent stands proud of it)

	-- Features (MapLayout.features). Water tower: shares of its height and footprint.
	waterTower = {
		legShare = 0.62, -- the legs reach this share of the height (the tank's floor)
		leg = 1.6,
		legInset = 2, -- legs stand this far in from the footprint's corners
		braceShare = 0.45, -- cross braces at this share of the legs
		brace = 0.8,
		tankShare = 0.26,
		tankWidth = 0.9, -- of the footprint
		catwalk = 1.5, -- the walkway under the tank reaches this far past it
		bandHeight = 2,
		bandAt = 0.62, -- the painted band at this share of the tank
		roofHeight = 3,
		roofWidth = 0.72, -- of the tank
		beacon = 1.4,
		tankColor = Color3.fromRGB(200, 208, 214),
		legColor = Color3.fromRGB(118, 122, 128),
		bandColor = Color3.fromRGB(52, 128, 142),
		roofColor = Color3.fromRGB(168, 176, 182),
		beaconColor = Color3.fromRGB(150, 40, 36),
	},
	-- Diner: the building at the back of its site, its car park in front, its sign by the road at the front corner.
	diner = {
		width = 46, -- along the road
		depth = 24,
		base = 3.5, -- stainless base up to the windows
		glass = 6, -- the window band; the roof band fills the rest of the height
		glassInset = 0.5,
		door = Vector3.new(5, 7.5, 0.6),
		stripe = 0.5, -- the neon stripe along the top of the windows
		apron = 0.1, -- the car park's paving
		signPole = Vector2.new(1.2, 18), -- width, height
		signBoard = Vector3.new(0.8, 7, 14), -- across the road's line, up, toward the road
		signInset = 8, -- the pole stands this far in from the site's front corner
		baseColor = Color3.fromRGB(186, 190, 194),
		roofColor = Color3.fromRGB(176, 50, 46),
		glassColor = Color3.fromRGB(86, 118, 128),
		doorColor = Color3.fromRGB(60, 62, 66),
		stripeColor = Color3.fromRGB(60, 160, 170),
		apronColor = Color3.fromRGB(84, 86, 90),
		signColor = Color3.fromRGB(176, 50, 46),
		textColor = Color3.fromRGB(250, 246, 236),
		labelPixelsPerStud = 20,
	},
	-- Bridge arches: one arch each side of the deck, in straight segments, hung from a tie beam along the deck edge
	-- by hangers, standing on piers at its feet, braced across by struts at the crown.
	bridgeArch = {
		segments = 12,
		rib = Vector2.new(1.6, 2.4), -- across, up
		tieTop = 0.5, -- the tie beam's top, above the deck surface (the ribs' feet stand on it)
		tie = Vector2.new(1.6, 2.5), -- across, up
		hangers = 9,
		hanger = 0.4,
		pier = Vector2.new(3, 6), -- across, along
		struts = 3,
		strutSpacing = 0.12, -- of the span, between neighbouring struts
		strut = 1.2,
		-- Colours: Config/CityScenery causeway.arches.
	},

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
	sites: { CityBuilder.Site }, -- the city's sites built so far (addCity)
	city: CityStats,
	-- Lamps that cast light, by grid cell (TUNING.lightEmitSpacing): the streetlights and the causeway's lamps share it.
	lit: { [number]: { Vector2 } },
	host: Scenery.Host?, -- what the scenery planner sees (made once the roads are built)
	scenery: Scenery.Report,
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

-- `lod`: the Model's LevelOfDetail by name (MapTypes Container), for the city's site models.
local function container(
	ctx: Ctx,
	path: string,
	class: "Folder" | "Model",
	streaming: Enum.ModelStreamingMode?,
	lod: string?
)
	if not ctx.containerSet[path] then
		ctx.containerSet[path] = true
		table.insert(ctx.containers, { path = path, class = class, streaming = streaming, lod = lod })
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

local NIGHT = Environment.nightLights

-- Makes a part a night light of `kind` (Config/Environment nightLights): tagged, with its kind and day colour, in its
-- day look, any Light in it built switched off. Services/DayNightService switches it at dusk and dawn.
local function nightLight(spec: PartSpec, kind: string): PartSpec
	local look = NIGHT.kinds[kind]
	spec.tag = NIGHT.tag
	local attributes: { [string]: any } = spec.attributes or {}
	attributes[NIGHT.kindAttribute] = kind
	attributes[NIGHT.dayColorAttribute] = spec.color
	spec.attributes = attributes
	if look then
		spec.material = look.dayMaterial
	end
	local light = spec.light
	if light then
		light.enabled = false
	end
	return spec
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

-- A pillar from under the ground up to `top`: square, or `round` (the causeway's white piers, Dev/City/Scenery
-- Causeway) `size` across.
local function addPillar(
	ctx: Ctx,
	name: string,
	at: Vector2,
	u: Vector2,
	top: number,
	owner: string,
	round: boolean?
): boolean
	local size = if round then Scenery.Causeway.pierSize else TUNING.pillarSize
	local footprint: Rect = { c = at, u = u, ha = size / 2, hc = size / 2 }
	if lowerRoadUnder(ctx, footprint, owner, top) then
		return false
	end
	local bottom = ctx.groundAt(at.X, at.Y) - TUNING.bury
	if round then
		add(ctx, Scenery.Causeway.pier("Bridges", name, at, bottom, top))
	else
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
	end
	gridInsert(ctx.grid, footprint, "support")
	return true
end

-- Raised roads (the bridge and its approaches): railings, and under them a solid fill when they are low or
-- pillars when they are high. Junction pads on raised roads are short; the pillars along the roads carry them.
-- A bridge is the city's white causeway (Dev/City/Scenery Causeway; docs/city/SCENERY.md §4): a balustrade with a
-- lit fascia on each edge, round piers where the pillars stand, and over the water a cap beam on each pier pair and
-- a shallow arch springing from the caps across every span. The deck, its heights and the road stay as they were.
local function addSupports(ctx: Ctx)
	local thickness = TUNING.roadThickness
	local Causeway = Scenery.Causeway
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

		local causeway = edge.kind == "bridge"
		if causeway then
			local length = segment.length - 2 * TUNING.railEndGap
			if length > 1 then
				for _, side in { -1, 1 } do
					local name = `{edge.name}:Rail{if side > 0 then "R" else "L"}`
					local parts, inner, outer, glow =
						Causeway.balustrade("Bridges", name, segment.frame, length, edge.half + edge.sidewalk, side)
					nightLight(glow, Causeway.glowKind)
					for _, part in parts do
						add(ctx, part)
					end
					local c = planAt(edge, edge.trimFrom + segment.run / 2, side * (inner + outer) / 2)
					gridInsert(
						ctx.grid,
						{ c = c, u = edge.u, ha = segment.run / 2, hc = (outer - inner) / 2 },
						"support"
					)
				end
			end
		elseif highest > TUNING.railMinHeight then
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
			local size = if causeway then Causeway.pierSize else TUNING.pillarSize
			local drop = thickness * math.sqrt(1 + slope * slope) + slope * size / 2 + 0.01
			local along = edge.trimFrom + TUNING.pillarSpacing / 2
			local count = 0
			local capped: { Vector2 } = {} -- the causeway's pier stations over the water, in order along the road
			local underside = HUGE
			while along < edge.length - edge.trimTo do
				local center = planAt(edge, along, 0)
				local surface = heightAt(edge, along)
				if surface - ctx.groundAt(center.X, center.Y) > TUNING.supportMinHeight then
					local stood = 0
					for _, lateral in laterals do
						count += 1
						local placed = addPillar(
							ctx,
							`{edge.name}:Pillar{count}`,
							planAt(edge, along, lateral),
							edge.u,
							surface - drop,
							owner,
							causeway
						)
						if placed then
							stood += 1
						end
					end
					-- Over the water a cap beam on the pier pair, under the deck.
					if causeway and stood == #laterals and ctx.groundAt(center.X, center.Y) < 0 then
						add(
							ctx,
							Causeway.cap(
								"Bridges",
								`{edge.name}:Cap{#capped + 1}`,
								center,
								edge.u,
								surface - drop - 0.02,
								2 * edge.half - 1
							)
						)
						table.insert(capped, center)
						underside = math.min(underside, surface - drop)
					end
				end
				along += TUNING.pillarSpacing
			end
			-- And between neighbouring caps a shallow arch at each deck edge (the deck over the water is level).
			for k = 1, #capped - 1 do
				for _, part in
					Causeway.haunches(
						"Bridges",
						`{edge.name}:Arch{k}`,
						capped[k],
						capped[k + 1],
						edge.l,
						edge.half - 0.6,
						underside
					)
				do
					add(ctx, part)
				end
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

-- True when (x, z) is in the park: inside its bounds and not in its hole.
local function insidePark(park: ParkData, x: number, z: number): boolean
	if x < park.min.X or x > park.max.X or z < park.min.Y or z > park.max.Y then
		return false
	end
	local hole = park.hole
	return not (hole and x > hole.min.X and x < hole.max.X and z > hole.min.Y and z < hole.max.Y)
end

type Run = { x0: number, x1: number, z0: number, z1: number, color: Color3, material: Enum.Material }

-- Ground slabs, top at y = 0, covering the whole map except the lakes: the map is cut along every zone, lake and
-- park edge (and, where a zone has grass shades, along the patchwork's tile lines) into cells; each cell takes its
-- park's grass, its zone's ground or, in a zone with shades, its tile's shade; cells that look the same are merged
-- into rectangles, and big rectangles are split.
local function addGround(ctx: Ctx, zones: { ZoneData })
	local half = ctx.half
	local lakes: { LakeData } = ctx.layout.lakes or {}
	local parks: { ParkData } = ctx.layout.parks or {}
	local xs, zs = { -half, half }, { -half, half }
	local function cut(list: { number }, value: number)
		if value > -half and value < half then
			table.insert(list, value)
		end
	end
	local function cutRect(min: Vector2, max: Vector2)
		cut(xs, min.X)
		cut(xs, max.X)
		cut(zs, min.Y)
		cut(zs, max.Y)
	end
	local shaded = false
	for _, zone in zones do
		cutRect(zone.min, zone.max)
		local shades = zone.groundShades
		if shades and #shades > 0 then
			shaded = true
		end
	end
	for _, lake in lakes do
		cutRect(lake.min, lake.max)
	end
	for _, park in parks do
		if park.groundColor then
			cutRect(park.min, park.max)
			local hole = park.hole
			if hole then
				cutRect(hole.min, hole.max)
			end
		end
	end
	local tile = Environment.ground.tile
	if shaded then
		for k = math.ceil(-half / tile), math.floor(half / tile) do
			cut(xs, k * tile)
			cut(zs, k * tile)
		end
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
	-- Outside every zone: the largest zone's ground (the open country), else the default.
	local country: ZoneData? = zones[#zones]
	local seed = ctx.layout.seed

	-- How the ground looks at a cell's centre.
	local function lookAt(cx: number, cz: number): (Color3, Enum.Material)
		for _, park in parks do
			local color = park.groundColor
			if color and insidePark(park, cx, cz) then
				return color, park.groundMaterial or TUNING.groundMaterial
			end
		end
		local zone = zoneAt(zones, Vector2.new(cx, cz)) or country
		if zone == nil then
			return TUNING.countryColor, TUNING.groundMaterial
		end
		local shades = zone.groundShades
		if shades and #shades > 0 then
			local pick = mixSeed(seed, math.floor(cx / tile) + 1000, math.floor(cz / tile) + 1000)
			local shade = shades[pick % #shades + 1]
			return shade.color, shade.material
		end
		return zone.groundColor, zone.groundMaterial or TUNING.groundMaterial
	end

	-- Runs of cells that look the same along each row, then rows of identical runs merged downward.
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
			local color, material = lookAt(cx, cz)
			local last = row[#row]
			if last and last.color == color and last.material == material and math.abs(last.x1 - x0) < 1e-6 then
				last.x1 = x1
			else
				table.insert(row, { x0 = x0, x1 = x1, z0 = z0, z1 = z1, color = color, material = material })
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
					and prior.material == run.material
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
		addSlab(ctx, "Ground", name, run.x0, run.x1, run.z0, run.z1, 0, TUNING.groundThickness, run.color, run.material)
	end
end

-- What the scenery planner (Dev/City/Scenery) sees: the roads as built (their slabs, cut-backs and sidewalks), the
-- lakes and parks, the placement grid's checks and a way to add parts and containers. Made once the road slabs exist.
local function sceneryHost(ctx: Ctx): Scenery.Host
	local made = ctx.host
	if made then
		return made
	end
	local streets: { Scenery.Street } = {}
	for _, edge in ctx.edges do
		if edge.segment == nil then
			continue
		end
		local built = edge
		table.insert(streets, {
			id = edge.id,
			name = edge.name,
			kind = edge.kind,
			fromZone = edge.from.zone,
			toZone = edge.to.zone,
			a = edge.from.plan,
			u = edge.u,
			l = edge.l,
			length = edge.length,
			half = edge.half,
			sidewalk = edge.sidewalk,
			trimFrom = edge.trimFrom,
			trimTo = edge.trimTo,
			fromRoads = #edge.from.roads,
			toRoads = #edge.to.roads,
			surface = function(along: number): number
				return heightAt(built, along)
			end,
		})
	end
	local lakeList: { LakeData } = ctx.layout.lakes or {}
	local parkList: { ParkData } = ctx.layout.parks or {}
	local lakes = {}
	for _, lake in lakeList do
		table.insert(lakes, { id = lake.id, min = lake.min, max = lake.max, waterY = lake.waterY, bedY = lake.bedY })
	end
	local parks = {}
	for _, park in parkList do
		table.insert(parks, { id = park.id, min = park.min, max = park.max, hole = park.hole })
	end
	local host: Scenery.Host = {
		seed = ctx.layout.seed,
		half = ctx.half,
		sidewalkRaise = TUNING.sidewalkRaise,
		lineLift = TUNING.lineLift,
		streets = streets,
		lakes = lakes,
		parks = parks,
		groundAt = ctx.groundAt,
		blocked = function(rect: Rect, kinds: { [string]: boolean }, tolerance: number): boolean
			return gridHits(ctx.grid, rect, kinds, tolerance)
		end,
		reserve = function(rect: Rect, kind: string)
			gridInsert(ctx.grid, rect, kind)
		end,
		add = function(spec: PartSpec)
			add(ctx, spec)
		end,
		container = function(
			path: string,
			class: "Folder" | "Model",
			streaming: Enum.ModelStreamingMode?,
			lod: string?
		)
			container(ctx, path, class, streaming, lod)
		end,
		note = function(text: string)
			note(ctx, text)
		end,
	}
	ctx.host = host
	return host
end

-- Each lake: its bed (ground under water, with banks sloping down from the shore so a car can climb out), in pale
-- sand so the shallows read turquoise, and its water (Dev/City/Scenery Water: bands of colour from the shore out, the
-- foam line, coping on the shores with no beach), which nothing collides with.
local function addLakes(ctx: Ctx)
	local lakes: { LakeData } = ctx.layout.lakes or {}
	local host = sceneryHost(ctx)
	for _, lake in lakes do
		local width, depthZ = lake.max.X - lake.min.X, lake.max.Y - lake.min.Y
		local cx, cz = (lake.min.X + lake.max.X) / 2, (lake.min.Y + lake.max.Y) / 2
		local thickness = TUNING.groundThickness
		local bed = Scenery.Water.bed
		local bedColor = bed.color
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
			bed.material
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
				add(ctx, wedge("Ground", `{lake.id}Bank{i}`, "ground", frame, size, bedColor, bed.material))
			end
		end
		for _, spec in Scenery.Water.plan(lake, host.streets, host.parks) do
			add(ctx, spec)
		end
		gridInsert(ctx.grid, { c = Vector2.new(cx, cz), u = Vector2.xAxis, ha = width / 2, hc = depthZ / 2 }, "lake")
	end
end

-- A mesa (or a hill) is a truncated pyramid: a box for its flat top, a wedge down each side and a corner wedge at
-- each corner (whose sloped faces meet along the diagonal, like MapLayout.groundHeight's max(dx, dz)). Every piece
-- reaches TUNING.bury below the ground along the same slope, so no seam shows at the foot. Its foot goes into the
-- placement grid as `kind`.
local function addFrustums(ctx: Ctx, mesas: { MesaData }, kind: string, looks: { GroundShade })
	local bury = TUNING.bury
	for index, mesa in mesas do
		local h = mesa.height
		local run = (h + bury) / mesa.slope -- horizontal reach of a side, top edge to y = -bury
		local x0, x1, z0, z1 = mesa.topMin.X, mesa.topMax.X, mesa.topMin.Y, mesa.topMax.Y
		local look = looks[(index - 1) % #looks + 1]
		local color, material = look.color, look.material
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
			kind
		)
	end
end

local MESA_LOOK: { GroundShade } = { { color = TUNING.mesaColor, material = Enum.Material.Ground } }

local function addMesas(ctx: Ctx)
	addFrustums(ctx, ctx.layout.mesas or {}, "mesa", MESA_LOOK)
end

-- The grass hills at the edge of the map, each in one of Config/Environment's hill shades. Trees grow on them.
local function addHills(ctx: Ctx)
	addFrustums(ctx, ctx.layout.hills or {}, "hill", Environment.ground.hillShades)
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

		-- The brand's name on a board on the roof, facing out of the entrance, with a light bar under it.
		local brandId = landmark.signBrand
		if brandId then
			local brand = Brands[brandId]
			if brand == nil then
				note(ctx, `landmark {landmark.id}: no brand "{brandId}" for its roof sign`)
			else
				local sign = TUNING.roofSign
				local width = math.min(size.X * sign.widthShare, sign.maxWidth)
				local z = -size.Z / 2 + sign.setback
				local postSize = Vector3.new(sign.post, sign.postHeight, sign.post)
				for i, side in { -1, 1 } do
					local postAt = Vector3.new(side * (width / 2 - sign.postInset), size.Y + sign.postHeight / 2, z)
					part(`SignPost{i}`, postAt, postSize, TUNING.propColor, Enum.Material.Metal)
				end
				local boardAt = Vector3.new(0, size.Y + sign.postHeight + sign.height / 2, z)
				local board = part(
					"Sign",
					boardAt,
					Vector3.new(width, sign.height, sign.thickness),
					sign.color,
					Enum.Material.SmoothPlastic
				)
				board.labels = {
					{
						face = Enum.NormalId.Front,
						text = brand.displayName,
						color = sign.textColor,
						pixelsPerStud = sign.pixelsPerStud,
					},
					{
						face = Enum.NormalId.Back,
						text = brand.displayName,
						color = sign.textColor,
						pixelsPerStud = sign.pixelsPerStud,
					},
				}
				local barAt = Vector3.new(
					0,
					size.Y + sign.postHeight - sign.lightBar / 2,
					z - sign.thickness / 2 - sign.lightBar / 2
				)
				local bar = part(
					"SignLight",
					barAt,
					Vector3.new(width, sign.lightBar, sign.lightBar),
					sign.lightColor,
					Enum.Material.SmoothPlastic
				)
				nightLight(decor(bar), "floodlight")
			end
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
-- Features (MapLayout.features): the water tower, the diner, the bridge's arches
---------------------------------------------------------------------------------------------------------------

-- What a water tower or diner must not stand on (the bridge's arches stand beside their deck by design).
local FEATURE_BLOCKERS: { [string]: boolean } = {
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
	feature = true,
}

-- Adds one part of a feature at `cframe` in the feature's own frame (`base`). Solid parts collide like walls; the
-- rest are decoration that still casts a shadow.
type FeaturePiece = (
	name: string,
	cframe: CFrame,
	size: Vector3,
	color: Color3,
	material: Enum.Material,
	solid: boolean
) -> PartSpec

local function featurePiece(ctx: Ctx, folder: string, base: CFrame): FeaturePiece
	return function(name, cframe, size, color, material, solid)
		local spec = block(folder, name, "feature", base * cframe, size, color, material)
		if not solid then
			decor(spec)
			spec.shadow = true
		end
		add(ctx, spec)
		return spec
	end
end

-- A tank on four legs, braced, with a walkway, a painted band, a roof cap and a red beacon that glows at night.
local function addWaterTower(ctx: Ctx, folder: string, feature: FeatureData, base: CFrame)
	local t = TUNING.waterTower
	local piece = featurePiece(ctx, folder, base)
	local bury = TUNING.bury
	local height = feature.size.Y
	local width = math.min(feature.size.X, feature.size.Z)
	local legTop = height * t.legShare
	local reach = width / 2 - t.legInset
	local legSize = Vector3.new(t.leg, legTop + bury, t.leg)
	for i, corner in { { 1, 1 }, { -1, 1 }, { -1, -1 }, { 1, -1 } } do
		local at = CFrame.new(corner[1] * reach, (legTop - bury) / 2, corner[2] * reach)
		piece(`Leg{i}`, at, legSize, t.legColor, Enum.Material.Metal, true)
	end
	-- Two beams crossing from leg to opposite leg.
	local diagonal = 2 * reach * math.sqrt(2)
	for i, turn in { 45, -45 } do
		local at = CFrame.new(0, legTop * t.braceShare, 0) * CFrame.Angles(0, math.rad(turn), 0)
		piece(`Brace{i}`, at, Vector3.new(diagonal, t.brace, t.brace), t.legColor, Enum.Material.Metal, false)
	end
	-- Upright cylinders (a cylinder part runs along its X axis, so each is turned a quarter about Z).
	local tankWidth = width * t.tankWidth
	local tankHeight = height * t.tankShare
	local function cylinder(name: string, y: number, tall: number, across: number, color: Color3, solid: boolean)
		local at = CFrame.new(0, y, 0) * CFrame.Angles(0, 0, math.rad(90))
		local spec = piece(name, at, Vector3.new(tall, across, across), color, Enum.Material.SmoothPlastic, solid)
		spec.shape = "cylinder"
	end
	cylinder("Catwalk", legTop + 0.25, 0.5, tankWidth + 2 * t.catwalk, t.legColor, false)
	cylinder("Tank", legTop + tankHeight / 2, tankHeight, tankWidth, t.tankColor, true)
	cylinder("Band", legTop + tankHeight * t.bandAt, t.bandHeight, tankWidth + 0.4, t.bandColor, false)
	local roofTop = legTop + tankHeight + t.roofHeight
	cylinder("Roof", roofTop - t.roofHeight / 2, t.roofHeight, tankWidth * t.roofWidth, t.roofColor, false)
	local beaconSize = Vector3.new(t.beacon, t.beacon, t.beacon)
	local at = CFrame.new(0, roofTop + t.beacon / 2, 0)
	nightLight(piece("Beacon", at, beaconSize, t.beaconColor, Enum.Material.SmoothPlastic, false), "beacon")
end

-- A roadside diner: the building at the back of its site (a stainless base, a band of windows that glow at night, a
-- red roof band with the diner's name, a door and a neon stripe), a car park in front and a tall sign by the road.
-- The site faces its road: local -Z is toward it, local X runs along it.
local function addDiner(ctx: Ctx, folder: string, feature: FeatureData, base: CFrame)
	local d = TUNING.diner
	local piece = featurePiece(ctx, folder, base)
	local bury = TUNING.bury
	local site = feature.size
	local back = site.Z / 2
	local front = back - d.depth -- the building's front face
	local middle = back - d.depth / 2
	piece(
		"Base",
		CFrame.new(0, (d.base - bury) / 2, middle),
		Vector3.new(d.width, d.base + bury, d.depth),
		d.baseColor,
		Enum.Material.Metal,
		true
	)
	local glassSize = Vector3.new(d.width - 2 * d.glassInset, d.glass, d.depth - 2 * d.glassInset)
	local glass = piece(
		"Windows",
		CFrame.new(0, d.base + d.glass / 2, middle),
		glassSize,
		d.glassColor,
		Enum.Material.Glass,
		true
	)
	nightLight(glass, "window")
	local roofHeight = site.Y - d.base - d.glass
	local roof = piece(
		"Roof",
		CFrame.new(0, d.base + d.glass + roofHeight / 2, middle),
		Vector3.new(d.width, roofHeight, d.depth),
		d.roofColor,
		Enum.Material.SmoothPlastic,
		true
	)
	roof.labels = {
		{
			face = Enum.NormalId.Front,
			text = string.upper(feature.displayName),
			color = d.textColor,
			pixelsPerStud = d.labelPixelsPerStud,
		},
	}
	local doorAt = CFrame.new(-d.width / 4, d.door.Y / 2, front - d.door.Z / 2)
	piece("Door", doorAt, d.door, d.doorColor, Enum.Material.SmoothPlastic, false)
	local stripeAt = CFrame.new(0, d.base + d.glass - d.stripe / 2, front - 0.2)
	local stripe =
		piece("Neon", stripeAt, Vector3.new(d.width, d.stripe, 0.4), d.stripeColor, Enum.Material.SmoothPlastic, false)
	nightLight(stripe, "sign")
	local apronDepth = front + site.Z / 2
	local apron = piece(
		"CarPark",
		CFrame.new(0, d.apron / 2, (front - site.Z / 2) / 2),
		Vector3.new(site.X, d.apron, apronDepth),
		d.apronColor,
		Enum.Material.Asphalt,
		false
	)
	apron.shadow = false
	-- The sign: a pole at the front corner, its board's faces along the road (both ways of traffic read it).
	local x, z = site.X / 2 - d.signInset, -site.Z / 2 + d.signInset
	local poleSize = Vector3.new(d.signPole.X, d.signPole.Y + bury, d.signPole.X)
	piece(
		"SignPole",
		CFrame.new(x, (d.signPole.Y - bury) / 2, z),
		poleSize,
		TUNING.propColor,
		Enum.Material.Metal,
		true
	)
	local boardAt = CFrame.new(x, d.signPole.Y + d.signBoard.Y / 2, z)
	local board = piece("Sign", boardAt, d.signBoard, d.signColor, Enum.Material.SmoothPlastic, false)
	local words = feature.sign or feature.displayName
	board.labels = {
		{ face = Enum.NormalId.Right, text = words, color = d.textColor, pixelsPerStud = d.labelPixelsPerStud },
		{ face = Enum.NormalId.Left, text = words, color = d.textColor, pixelsPerStud = d.labelPixelsPerStud },
	}
end

-- Steel arches either side of a bridge deck (the feature's frame sits on the deck surface, local Z along the deck):
-- each arch in straight segments that glow at night, hung from a tie beam along the deck edge by hangers, standing
-- on a pier at each foot; struts brace the two arches at the crown. White by day, the causeway's colours
-- (Config/CityScenery causeway.arches); at night each rib glows its own colour of a gradient, cyan at the feet to pink
-- at the crown (its NightColor attribute beats the arch kind's colour, Services/DayNightService).
local function addBridgeArch(ctx: Ctx, folder: string, feature: FeatureData, base: CFrame)
	local a = TUNING.bridgeArch
	local look = Scenery.Causeway.arches
	local colorAttribute = Environment.nightLights.nightColorAttribute
	local piece = featurePiece(ctx, folder, base)
	local span, rise = feature.size.Z, feature.size.Y
	local footY = a.tieTop + a.rib.Y / 2 -- the ribs' centre line at their feet, standing on the tie beams
	local function archPoint(t: number, lateral: number): Vector3
		return Vector3.new(lateral, footY + rise * 4 * t * (1 - t), -span / 2 + span * t)
	end
	for _, side in { -1, 1 } do
		local letter = if side < 0 then "L" else "R"
		local lateral = side * feature.size.X / 2
		for i = 1, a.segments do
			local p, q = archPoint((i - 1) / a.segments, lateral), archPoint(i / a.segments, lateral)
			local size = Vector3.new(a.rib.X, a.rib.Y, (q - p).Magnitude + a.rib.Y) -- overlapped at the joints
			local at = CFrame.lookAt((p + q) / 2, q)
			local rib = nightLight(piece(`Rib{letter}{i}`, at, size, look.ribColor, Enum.Material.Metal, false), "arch")
			local attributes: { [string]: any } = rib.attributes or {}
			attributes[colorAttribute] = Scenery.Causeway.ribColor(i, a.segments)
			rib.attributes = attributes
		end
		for j = 1, a.hangers do
			local top = archPoint(j / (a.hangers + 1), lateral)
			local length = top.Y - a.rib.Y / 2 - a.tieTop
			local at = CFrame.new(lateral, a.tieTop + length / 2, top.Z)
			local size = Vector3.new(a.hanger, length, a.hanger)
			piece(`Hanger{letter}{j}`, at, size, look.hangerColor, Enum.Material.Metal, false)
		end
		local tieAt = CFrame.new(lateral, a.tieTop - a.tie.Y / 2, 0)
		piece(`Tie{letter}`, tieAt, Vector3.new(a.tie.X, a.tie.Y, span), look.ribColor, Enum.Material.Metal, false)
		-- A pier under each foot, from under the tie beam down into the ground (the lake bed).
		for k, z in { -span / 2, span / 2 } do
			local world = base * Vector3.new(lateral, 0, z)
			local bottom = ctx.groundAt(world.X, world.Z) - TUNING.bury - feature.position.Y
			local top = a.tieTop - a.tie.Y
			if top - bottom > 0.1 then
				local at = CFrame.new(lateral, (top + bottom) / 2, z)
				local size = Vector3.new(a.pier.X, top - bottom, a.pier.Y)
				piece(`Pier{letter}{k}`, at, size, look.pierColor, Enum.Material.Concrete, true)
			end
		end
		local strip: Rect = {
			c = flat((base * CFrame.new(lateral, 0, 0)).Position),
			u = flat(base.LookVector).Unit,
			ha = span / 2 + a.pier.Y / 2,
			hc = math.max(a.rib.X, a.pier.X) / 2,
		}
		gridInsert(ctx.grid, strip, "feature")
	end
	for k = 1, a.struts do
		local p = archPoint(0.5 + (k - (a.struts + 1) / 2) * a.strutSpacing, 0)
		local size = Vector3.new(feature.size.X, a.strut, a.strut)
		piece(`Strut{k}`, CFrame.new(0, p.Y, p.Z), size, look.ribColor, Enum.Material.Metal, false)
	end
end

local FEATURE_BUILDERS: { [string]: (Ctx, string, FeatureData, CFrame) -> () } = {
	water_tower = addWaterTower,
	diner = addDiner,
	bridge_arch = addBridgeArch,
}

-- Each feature as a Model under Features. A water tower or diner whose footprint would land on a road, a pad or
-- another thing's ground is left out with a note; lots, buildings, streetlights and trees keep off every footprint.
local function addFeatures(ctx: Ctx)
	local list = ctx.layout.features
	if list == nil or #list == 0 then
		return
	end
	container(ctx, "Features", "Folder")
	for _, feature in list do
		local builder = FEATURE_BUILDERS[feature.kind]
		if builder == nil then
			note(ctx, `feature {feature.id}: no builder for kind "{feature.kind}", left out`)
			continue
		end
		local facing = CFrame.Angles(0, math.rad(feature.yaw), 0)
		local base = CFrame.new(feature.position) * facing
		local footprint: Rect = {
			c = flat(feature.position),
			u = flat(facing.LookVector).Unit,
			ha = feature.size.Z / 2,
			hc = feature.size.X / 2,
		}
		local spansRoad = feature.kind == "bridge_arch"
		if not spansRoad and gridHits(ctx.grid, footprint, FEATURE_BLOCKERS, 0) then
			note(ctx, `feature {feature.id} would stand on a road, a pad or a landmark, left out`)
			continue
		end
		local folder = `Features/{feature.id}`
		container(ctx, folder, "Model", Enum.ModelStreamingMode.Atomic)
		builder(ctx, folder, feature, base)
		if not spansRoad then
			gridInsert(ctx.grid, footprint, "feature")
		end
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
	feature = true,
}

-- Posts at an even spacing along each street and arterial, alternating sides road by road. A post's light
-- only switches on when no other lit post is within TUNING.lightEmitSpacing, so at most one light per 200
-- studs of street actually emits. Every head is a night light (Config/Environment nightLights "streetlight"):
-- built in its day look with its light off, lit from dusk to dawn by Services/DayNightService. Each post goes into
-- the grid as "light", and its arm and head as "lamp", which trees and the scenery keep clear of. What a post looks
-- like is Dev/City/Scenery Lamps' (Config/CityScenery lamps: by zone and kind); the causeway has acorn lamps along
-- its balustrade instead (Dev/City/Scenery Causeway), under the same one-light-in-200-studs rule.
local function addStreetlights(ctx: Ctx)
	local lit = ctx.lit
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
	-- Gives a head its light when no lit head is within the spacing.
	local function maybeLight(head: PartSpec, at: Vector2)
		if nearLit(at) then
			return
		end
		head.light = {
			kind = "spot",
			brightness = TUNING.lightBrightness,
			range = TUNING.lightRange,
			angle = TUNING.lightAngle,
			color = TUNING.lightColor,
			face = Enum.NormalId.Bottom,
		}
		local key = cellKey(math.floor(at.X / cell), math.floor(at.Y / cell))
		lit[key] = lit[key] or {}
		table.insert(lit[key], at)
	end
	local count = 0
	local lamps = 0
	for _, edge in ctx.edges do
		local segment = edge.segment
		if segment == nil then
			continue
		end
		if edge.kind == "bridge" then
			-- The causeway's acorn lamps on the coping, staggered side to side.
			local Causeway = Scenery.Causeway
			local reach = segment.length / 2 - TUNING.railEndGap - 4
			local step = Causeway.lampEvery / 2
			local n = math.floor(2 * reach / step)
			for k = 0, n do
				local t = -reach + (2 * reach - n * step) / 2 + k * step
				local side = if (k + edge.index) % 2 == 0 then 1 else -1
				lamps += 1
				local post, globe = Causeway.lamp(
					"Streetlights",
					`CausewayLamp{lamps}`,
					segment.frame,
					t,
					edge.half + edge.sidewalk,
					side
				)
				local at = flat(globe.cframe.Position)
				maybeLight(globe, at)
				add(ctx, post)
				add(ctx, nightLight(globe, "streetlight"))
				local foot = flat(post.cframe.Position)
				gridInsert(ctx.grid, { c = foot, u = edge.u, ha = 1, hc = 1 }, "light")
				local r = globe.size.X / 2
				gridInsert(ctx.grid, { c = at, u = edge.u, ha = r, hc = r }, "lamp")
			end
			continue
		end
		if not TUNING.lightKinds[edge.kind] then
			continue
		end
		local style = Scenery.Lamps.style(edge.from.zone, edge.kind)
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
			-- The head reaches out over the road edge.
			local toward = -edge.l * side
			if style then
				local post = Scenery.Lamps.post(style, "Streetlights", `Light{count}`, at, base, toward)
				add(ctx, post.pole)
				for _, extra in post.extras do
					add(ctx, extra)
				end
				maybeLight(post.head, post.headPlan)
				add(ctx, nightLight(post.head, "streetlight"))
				gridInsert(ctx.grid, footprint, "light")
				-- The lamp: from the post out to the far end of its head (an arm or a head over the kerb).
				local out = (post.headPlan - at).Magnitude + post.headSize.Y / 2
				local middle = at + toward * (out / 2)
				gridInsert(ctx.grid, { c = middle, u = toward, ha = out / 2, hc = post.headSize.X / 2 }, "lamp")
				continue
			end
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
			local head = TUNING.headSize
			local headAt = lift(at + toward * TUNING.headReach, base + TUNING.postHeight + head.Y / 2)
			local headFrame = CFrame.lookAt(headAt, headAt + lift(toward, 0))
			-- Built in its day look (nightLight below): Neon from dusk to dawn.
			local headSpec = decor(
				block(
					"Streetlights",
					`Light{count}Head`,
					"light",
					headFrame,
					head,
					TUNING.headColor,
					Enum.Material.SmoothPlastic
				)
			)
			local headPlan = flat(headAt)
			maybeLight(headSpec, headPlan)
			add(ctx, nightLight(headSpec, "streetlight"))
			gridInsert(ctx.grid, footprint, "light")
			gridInsert(ctx.grid, { c = headPlan, u = toward, ha = head.Z / 2, hc = head.X / 2 }, "lamp")
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
	park = true,
	feature = true,
}

-- What a city site keeps low beside (Config/City nearSpotRange).
local SPOT_KINDS: { [string]: boolean } = { location = true, access = true }

local function inflate(rect: Rect, by: number): Rect
	return { c = rect.c, u = rect.u, ha = rect.ha + by, hc = rect.hc + by }
end

-- One building on its plot: `c` the centre of its footprint (plan), `u` the way its road runs, `depth` across the
-- road, `width` along it, `height` to its roof. In a zone with a facade (Config/Environment facades) it is glass set
-- in from the footprint with floor bands proud of it and a roof edge on the footprint, or from towerFrom up a
-- glass tower with corner piers and a band over its ground floor; some get a plant box on the roof, and litShare of
-- them a run of floors whose windows glow at night (the glass split at a floor line, hidden behind a band). In a zone
-- without one, a plain block. Its own random numbers come from `shade` and its index, so the plots never reshuffle.
local function addBuilding(
	ctx: Ctx,
	folder: string,
	index: number,
	c: Vector2,
	u: Vector2,
	depth: number,
	width: number,
	height: number,
	color: Color3,
	zone: ZoneData,
	shade: number
)
	local name = `Building{index}`
	local bury = TUNING.bury
	local base = CFrame.lookAt(lift(c, 0), lift(c + u, 0))
	local style = Environment.facades[zone.id]
	if style == nil then
		local frame = base * CFrame.new(0, (height - bury) / 2, 0)
		local size = Vector3.new(depth, height + bury, width)
		add(ctx, block(folder, name, "building", frame, size, color, TUNING.buildingMaterial))
		return
	end
	local rng = Random.new(mixSeed(ctx.layout.seed, shade, index))
	local tint = style.tints[rng:NextInteger(1, #style.tints)]
	local material = style.materials[rng:NextInteger(1, #style.materials)]
	local litRoll, litFloor, litUpper = rng:NextNumber(), rng:NextNumber(), rng:NextNumber()
	local roofRoll, roofX, roofZ, roofTall = rng:NextNumber(), rng:NextNumber(), rng:NextNumber(), rng:NextNumber()

	-- A box from y0 to y1, `inset` inside the footprint on every side.
	local function slab(
		suffix: string,
		y0: number,
		y1: number,
		inset: number,
		partColor: Color3,
		partMaterial: Enum.Material
	)
		local frame = base * CFrame.new(0, (y0 + y1) / 2, 0)
		local size = Vector3.new(depth - 2 * inset, y1 - y0, width - 2 * inset)
		local spec = block(folder, name .. suffix, "building", frame, size, partColor, partMaterial)
		add(ctx, spec)
		return spec
	end

	local tower = style.towerFrom ~= nil and height >= (style.towerFrom :: number)
	local floors = math.clamp(math.round(height / style.floorHeight), 1, style.maxFloors)
	local floor = if tower then style.floorHeight else height / floors
	local band = floor * (1 - style.windowShare) -- a floor band's height, centred on its floor line
	local glassTop = height - (if tower then TUNING.towerCrown else band / 2)
	-- Floor lines below the roof edge: where the glass may split.
	local lines = if tower then math.max(0, math.ceil(glassTop / floor) - 1) else floors - 1

	-- The glass, whole or split at a floor line with one piece lit at night.
	local lit = litRoll < style.litShare
	if lit and lines > 0 then
		local split = floor * (1 + math.floor(litFloor * lines))
		local lower = slab("", -bury, split, TUNING.glassInset, tint, Enum.Material.Glass)
		local upper = slab("Upper", split, glassTop, TUNING.glassInset, tint, Enum.Material.Glass)
		nightLight(if litUpper < 0.5 then lower else upper, "window")
	else
		local glass = slab("", -bury, glassTop, TUNING.glassInset, tint, Enum.Material.Glass)
		if lit then
			nightLight(glass, "window")
		end
	end

	if tower then
		-- Corner piers on the footprint, and a band over the ground floor.
		local pier = TUNING.towerPier
		local pierSize = Vector3.new(pier, glassTop + bury, pier)
		for i, corner in { { 1, 1 }, { -1, 1 }, { -1, -1 }, { 1, -1 } } do
			local offset =
				Vector3.new(corner[1] * (depth - pier) / 2, (glassTop - bury) / 2, corner[2] * (width - pier) / 2)
			add(ctx, block(folder, `{name}Pier{i}`, "building", base * CFrame.new(offset), pierSize, color, material))
		end
		local podium = TUNING.podiumBand
		slab("Band1", floor - podium / 2, floor + podium / 2, TUNING.bandInset, color, material)
	else
		for k = 1, floors - 1 do
			slab(`Band{k}`, k * floor - band / 2, k * floor + band / 2, TUNING.bandInset, color, material)
		end
	end

	-- The roof edge: on the footprint, proud of the bands and the glass, rising past the roof.
	local roof = height + TUNING.parapetHeight
	slab("Top", glassTop, roof, 0, color, material)

	-- A plant box on some roofs, inside the roof edge.
	if style.rooftopShare > 0 and height >= style.rooftopFrom and roofRoll < style.rooftopShare then
		local boxDepth, boxWidth = depth * TUNING.rooftopSize.X, width * TUNING.rooftopSize.Y
		local tall = TUNING.rooftopHeight[1] + roofTall * (TUNING.rooftopHeight[2] - TUNING.rooftopHeight[1])
		local spareX = math.max(0, depth / 2 - boxDepth / 2 - TUNING.rooftopEdge)
		local spareZ = math.max(0, width / 2 - boxWidth / 2 - TUNING.rooftopEdge)
		local offset = Vector3.new((2 * roofX - 1) * spareX, roof + tall / 2, (2 * roofZ - 1) * spareZ)
		local size = Vector3.new(boxDepth, tall, boxWidth)
		add(
			ctx,
			block(
				folder,
				`{name}Roof`,
				"building",
				base * CFrame.new(offset),
				size,
				TUNING.rooftopColor,
				Enum.Material.Metal
			)
		)
	end
end

-- What stands on the built plots (Dev/City/CityBuilder; docs/city/CITY_PLAN.md §4, §5 and §7): the city's archetypes
-- where it places them, each site its own Atomic model (LevelOfDetail SLIM: still parts only) beside a small lights
-- model for its night lights, signs and lights (not SLIM: they change at dusk), and a tower's main masses in the
-- Persistent Skyline model; a plot no archetype fits stays open in a city district (Config/City openFallback), else
-- takes the old facade (addBuilding). A core claim behind a site's
-- plots passes the plots' own clear checks (flat open ground in the map, nothing a lot keeps off within the clearance,
-- the frontage's own plots excepted), is paved like a lot, and keeps later claims and trees off. A site the city
-- builder can't build is left to the old facade with a note.
local function addCity(ctx: Ctx, plots: { CityBuilder.Plot })
	local limit = ctx.half - 1
	local reserved = ctx.layout.reservedWestOfX or -HUGE
	local stats = ctx.city
	local env: CityBuilder.Env = {
		clear = function(center: Vector2, u: Vector2, halfAlong: number, halfAcross: number, frontage: string): boolean
			local rect: Rect = { c = center, u = u, ha = halfAlong, hc = halfAcross }
			local samples = rectCorners(rect)
			table.insert(samples, center)
			table.insert(samples, center + u * halfAlong)
			table.insert(samples, center - u * halfAlong)
			table.insert(samples, center + perp(u) * halfAcross)
			table.insert(samples, center - perp(u) * halfAcross)
			for _, p in samples do
				if math.abs(p.X) > limit or math.abs(p.Y) > limit or p.X < reserved then
					return false
				end
				if math.abs(ctx.groundAt(p.X, p.Y)) > TUNING.maxLevelError then
					return false
				end
			end
			return not gridAny(ctx.grid, inflate(rect, TUNING.clearance), 0, function(shape)
				return LOT_BLOCKERS[shape.kind] == true and not (shape.kind == "lot" and shape.owner == frontage)
			end)
		end,
		claim = function(center: Vector2, u: Vector2, halfAlong: number, halfAcross: number, owner: string)
			gridInsert(ctx.grid, { c = center, u = u, ha = halfAlong, hc = halfAcross }, "lot", `site:{owner}`)
			stats.claims += 1
			local y = TUNING.lotThickness / 2
			local frame = CFrame.lookAt(lift(center, y), lift(center + u, y))
			local size = Vector3.new(2 * halfAcross, TUNING.lotThickness, 2 * halfAlong)
			add(ctx, decor(block("Lots", `Claim{owner}`, "lot", frame, size, TUNING.lotColor, Enum.Material.Concrete)))
		end,
	}
	local placement = CityBuilder.place(plots, ctx.layout.seed, env)
	stats.unplaced = placement.unplaced
	stats.missing = placement.missing

	local legacy: { CityBuilder.Plot } = table.clone(placement.legacy)
	local byIndex: { [number]: CityBuilder.Plot } = {}
	for _, plot in plots do
		byIndex[plot.index] = plot
	end
	local atomic, persistent = Enum.ModelStreamingMode.Atomic, Enum.ModelStreamingMode.Persistent
	local skyline = City.skyline.folder
	for _, site in placement.sites do
		local specs, problem = CityBuilder.build(site)
		if specs then
			container(ctx, site.folder, "Model", atomic, "SLIM")
			for _, spec in specs do
				if spec.folder == site.lightsFolder then
					container(ctx, "BuildingLights", "Folder")
					container(ctx, site.lightsFolder, "Model", atomic, "Disabled")
				elseif spec.folder == skyline then
					container(ctx, skyline, "Model", persistent)
					stats.skyline += 1
				end
				if spec.tag == NIGHT.tag then
					stats.lights += 1
				end
				add(ctx, spec)
			end
			stats.parts[site.district] = (stats.parts[site.district] or 0) + #specs
			table.insert(ctx.sites, site)
		else
			note(ctx, `city: {problem}; the old look stands there`)
			for _, index in site.plots do
				table.insert(legacy, byIndex[index])
			end
		end
	end
	table.sort(legacy, function(a, b)
		return a.index < b.index
	end)
	local zones = ctx.layout.zones
	for _, plot in legacy do
		-- In a city district a plot no archetype fits stays open (Config/City openFallback): the run's paved lot, or
		-- ground for a lone plot, still kept clear of trees.
		local openDistrict = City.districts[plot.zone]
		if City.openFallback and openDistrict ~= nil then
			stats.open[openDistrict] = (stats.open[openDistrict] or 0) + 1
			continue
		end
		container(ctx, plot.folder, "Model", atomic)
		local before = #ctx.specs
		addBuilding(
			ctx,
			plot.folder,
			plot.index,
			plot.center,
			plot.u,
			plot.buildingDepth,
			plot.buildingWidth,
			plot.height,
			plot.color,
			zones[plot.zone],
			plot.shade
		)
		local district = City.districts[plot.zone] or ""
		stats.legacy[district] = (stats.legacy[district] or 0) + 1
		stats.parts[district] = (stats.parts[district] or 0) + #ctx.specs - before
		for k = before + 1, #ctx.specs do
			if ctx.specs[k].tag == NIGHT.tag then
				stats.lights += 1
			end
		end
	end
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
	local plots: { CityBuilder.Plot } = {}

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
				-- An area of Config/City may build more or fewer of its plots (the north shore's hotel row, the beach).
				if zone and roll < CityBuilder.density(zone.id, zone.buildingDensity, plot.c) then
					gridInsert(ctx.grid, plot, "lot", frontage)
					if runStart == nil then
						runStart = along
					end
					runEnd = along + width
					runCount += 1
					-- Group by block, and split big blocks into tiles so each Model stays compact (the old look's tile
					-- models; addCity makes one only when an old-look building stands in it).
					local tile = TUNING.blockTile
					local key = `{face}:{math.floor(plot.c.X / tile)}:{math.floor(plot.c.Y / tile)}`
					local blockName = blockNames[key]
					if blockName == nil then
						blocks += 1
						blockName = `Block{blocks}`
						blockNames[key] = blockName
					end
					buildings += 1
					local height = zone.buildingHeight.min + tall * (zone.buildingHeight.max - zone.buildingHeight.min)
					local c = planAt(edge, along + width / 2, side * (front + setback + depth / 2))
					local colors = zone.buildingColors
					local color = if #colors > 0 then colors[shade % #colors + 1] else TUNING.landmarkDefaultColor
					-- The city builder decides what stands here once the whole pass is done (addCity).
					table.insert(plots, {
						index = buildings,
						frontage = frontage,
						block = face,
						along = along,
						width = width,
						plotDepth = plotDepth,
						frontStart = planAt(edge, along, side * front),
						u = edge.u,
						away = edge.l * side,
						zone = zone.id,
						tall = tall,
						nearSpot = gridHits(ctx.grid, inflate(plot, City.nearSpotRange), SPOT_KINDS, 0),
						shade = shade,
						folder = `Buildings/{blockName}`,
						cornerStart = along - (edge.trimFrom + TUNING.cornerClear) < City.rules.cornerReach,
						cornerEnd = stop - (along + width) < City.rules.cornerReach,
						center = c,
						buildingDepth = depth,
						buildingWidth = width - TUNING.buildingGap,
						height = height,
						color = color,
					})
				else
					closeRun()
				end
				along += width
			end
			closeRun()
		end
	end
	addCity(ctx, plots)
end

---------------------------------------------------------------------------------------------------------------
-- Parks and trees
---------------------------------------------------------------------------------------------------------------

-- A park's ground as rectangles: the whole park, or the bands round its hole.
local function parkRects(park: ParkData): { Rect }
	local rects: { Rect } = {}
	local function rect(x0: number, x1: number, z0: number, z1: number)
		if x1 - x0 > 1e-6 and z1 - z0 > 1e-6 then
			table.insert(rects, {
				c = Vector2.new((x0 + x1) / 2, (z0 + z1) / 2),
				u = Vector2.xAxis,
				ha = (x1 - x0) / 2,
				hc = (z1 - z0) / 2,
			})
		end
	end
	local min, max = park.min, park.max
	local hole = park.hole
	if hole == nil then
		rect(min.X, max.X, min.Y, max.Y)
		return rects
	end
	local hx0, hx1 = math.clamp(hole.min.X, min.X, max.X), math.clamp(hole.max.X, min.X, max.X)
	local hz0, hz1 = math.clamp(hole.min.Y, min.Y, max.Y), math.clamp(hole.max.Y, min.Y, max.Y)
	rect(min.X, max.X, min.Y, hz0)
	rect(min.X, max.X, hz1, max.Y)
	rect(min.X, hx0, hz0, hz1)
	rect(hx1, max.X, hz0, hz1)
	return rects
end

-- Parks keep lots and buildings out (run before addBuildings).
local function addParks(ctx: Ctx)
	for _, park in ctx.layout.parks or {} do
		for _, rect in parkRects(park) do
			gridInsert(ctx.grid, rect, "park")
		end
	end
end

-- What a tree's trunk keeps its distance from (Config/Environment trees.roadClearance or parkRoadClearance)...
local TREE_ROAD_KINDS: { [string]: boolean } = { road = true, sidewalk = true, driveway = true, support = true }
-- ...what its leaves keep off (a park tree's trunk may stand near a road, but its leaves never hang over one)...
local TREE_BLOCKERS: { [string]: boolean } = {
	road = true,
	support = true,
	landmark = true,
	location = true,
	access = true,
	prop = true,
	light = true,
	lamp = true,
	lot = true,
	feature = true,
	ramp = true,
	mesa = true,
	lake = true,
	streetscape = true, -- the city's scenery (Dev/City/Scenery): benches, stands, shelters, the fountain
}
-- ...and what keeps trunks apart.
local TREE_KIND: { [string]: boolean } = { tree = true }

-- The random numbers one tree takes, drawn before anything is checked so a tree that doesn't fit never shifts the
-- next one's.
type TreeRolls = { species: number, scale: number, yaw: number, leaves: number, trunk: number }

local function treeRolls(rng: Random): TreeRolls
	return {
		species = rng:NextNumber(),
		scale = rng:NextNumber(),
		yaw = rng:NextNumber(),
		leaves = rng:NextNumber(),
		trunk = rng:NextNumber(),
	}
end

local function square(c: Vector2, half: number): Rect
	return { c = c, u = Vector2.xAxis, ha = half, hc = half }
end

-- The city's street scenery (Dev/City/Scenery; docs/city/SCENERY.md): the causeway's palms, the beach, Town Square,
-- the avenues' and streets' palms, bus shelters and crossings, after the buildings (so it keeps off every lot) and
-- before the trees (which keep off it).
local function addScenery(ctx: Ctx)
	ctx.scenery = Scenery.plan(sceneryHost(ctx))
end

-- Trees (Config/Environment trees): first the parks, a tree per cell by chance; then the groves, zone by zone in
-- the configured order (the open country last, outskirts groves past outskirtsFrom), each cell of a zone's grid
-- a grove by chance, its trees scattered round a point in the cell and kept inside that zone. A tree goes only
-- where its trunk clears the roads and sidewalks, its leaves clear lots, pads, house plots, props, streetlights,
-- landmarks, features and water, and no other trunk is within `spacing`; never west of reservedWestOfX, never on
-- the lake bed. Planting stops at maxTrees or the tree part budget. Each park cell and each grove has its own seeded
-- random stream, so the same trees grow every build.
local function addTrees(ctx: Ctx, zones: { ZoneData })
	local config = Environment.trees
	local layout = ctx.layout
	local seed = layout.seed
	local reserved = layout.reservedWestOfX or -HUGE
	local inner = ctx.half - config.edgeMargin
	local country = config.countryZone
	local hasCountry = layout.zones[country] ~= nil
	local budget = Environment.budget.treeParts
	local trees, parts = 0, 0
	local tiles: { [string]: string } = {}

	-- The zone a point counts as for the groves (the open land outside every zone is the country's).
	local function regionAt(p: Vector2): string?
		local zone = zoneAt(zones, p)
		if zone then
			return zone.id
		end
		return if hasCountry then country else nil
	end

	local function speciesFor(mixName: string, roll: number): string?
		local list = config.mixes[mixName]
		if list == nil or #list == 0 then
			return nil
		end
		local total = 0
		for _, entry in list do
			total += entry.weight
		end
		local left = roll * total
		for _, entry in list do
			left -= entry.weight
			if left < 0 then
				return entry.species
			end
		end
		return list[#list].species
	end

	local function pick<T>(list: { T }, roll: number): T
		return list[math.clamp(math.floor(roll * #list) + 1, 1, #list)]
	end

	-- The tile model a tree at `p` goes in.
	local function tileOf(p: Vector2): string
		local tile = TUNING.treeTile
		local key = `{math.floor(p.X / tile)}_{math.floor(p.Y / tile)}`
		local folder = tiles[key]
		if folder == nil then
			folder = `Trees/Tile{key}`
			tiles[key] = folder
			-- Still parts only (no night lights), so SLIM may stand in for a far tile (docs/city/TECH.md §6).
			container(ctx, folder, "Model", Enum.ModelStreamingMode.Atomic, "SLIM")
		end
		return folder :: string
	end

	-- Plants one tree at `p` if it fits. True when it did. A palm species (Config/CityScenery palms) is a palm: its
	-- trunk and a crown the build fills from its template (Dev/City/Scenery Palms); the rest are blocks (TUNING).
	local function plant(p: Vector2, rolls: TreeRolls, mixName: string, roadClearance: number): boolean
		local speciesName = speciesFor(mixName, rolls.species)
		local palm = if speciesName then Scenery.Palms.species[speciesName] else nil
		local shape = if speciesName then TUNING.treeSpecies[speciesName] else nil
		if (shape == nil and palm == nil) or trees >= config.maxTrees then
			return false
		end
		if p.X < reserved or math.abs(p.X) > inner or math.abs(p.Y) > inner then
			return false
		end
		local palmRolls = { scale = rolls.scale, yaw = rolls.yaw, lean = rolls.trunk, variant = rolls.leaves }
		local scale, reach, trunkWidth, trunkHeight = 1, 0, 1, 1
		if palm then
			scale = Scenery.Palms.size(palm, palmRolls)
			reach = Scenery.Palms.reach(palm, scale)
			trunkWidth, trunkHeight = palm.collider.X * scale, palm.collider.Y * scale
		elseif shape then
			scale = config.scale[1] + rolls.scale * (config.scale[2] - config.scale[1])
			for _, leaf in shape.leaves do
				reach = math.max(reach, math.sqrt(leaf.size.X * leaf.size.X + leaf.size.Z * leaf.size.Z) / 2)
			end
			reach *= scale
			trunkWidth, trunkHeight = shape.trunk.X * scale, shape.trunk.Y * scale
		end
		if gridHits(ctx.grid, square(p, trunkWidth / 2 + roadClearance), TREE_ROAD_KINDS, 0) then
			return false
		end
		if gridHits(ctx.grid, square(p, reach + TUNING.treeMargin), TREE_BLOCKERS, 0) then
			return false
		end
		local room = square(p, config.spacing / 2)
		if gridHits(ctx.grid, room, TREE_KIND, 0) then
			return false
		end
		local ground = ctx.groundAt(p.X, p.Y)
		if ground < -TUNING.maxLevelError then
			return false -- the lake bed
		end
		local count = if palm then 2 elseif shape then 1 + #shape.leaves else 0
		if parts + count > budget then
			return false
		end
		trees += 1
		parts += count
		gridInsert(ctx.grid, room, "tree")
		local treeFolder = tileOf(p)
		local name = `Tree{trees}`

		if palm and speciesName then
			local trunk, crown = Scenery.Palms.specs(
				treeFolder,
				name,
				"tree",
				speciesName,
				Vector3.new(p.X, ground, p.Y),
				rolls.yaw * TAU,
				palmRolls
			)
			add(ctx, trunk)
			add(ctx, crown)
			return true
		end
		local leafy = shape :: TreeShape
		local turn = CFrame.Angles(0, rolls.yaw * TAU, 0)
		-- The trunk: solid, a little into the ground (it may stand on a slope).
		local bury = TUNING.bury
		local trunk = block(
			treeFolder,
			`{name}Trunk`,
			"tree",
			CFrame.new(p.X, ground + (trunkHeight - bury) / 2, p.Y) * turn,
			Vector3.new(trunkWidth, trunkHeight + bury, trunkWidth),
			pick(config.trunkColors, rolls.trunk),
			Enum.Material.Wood
		)
		trunk.shadow = false
		add(ctx, trunk)
		-- The leaves: cars and players pass through them; they cast a shadow.
		local palette = if leafy.pine then config.pineColors else config.leafColors
		local leafColor = pick(palette, rolls.leaves)
		local leafMaterial = if leafy.pine then Enum.Material.Grass else Enum.Material.LeafyGrass
		for i, leaf in leafy.leaves do
			local size = leaf.size * scale
			local y = ground + leaf.bottom * scale + size.Y / 2
			local frame = CFrame.new(p.X, y, p.Y) * turn * CFrame.Angles(0, math.rad(leaf.turn), 0)
			local spec = decor(block(treeFolder, `{name}Leaves{i}`, "tree", frame, size, leafColor, leafMaterial))
			spec.shadow = true
			add(ctx, spec)
		end
		return true
	end

	-- The parks.
	for parkIndex, park in layout.parks or {} do
		local params = config.parks[park.id] or config.parks.default
		local cell = params.cell
		local nx = math.ceil((park.max.X - park.min.X) / cell)
		local nz = math.ceil((park.max.Y - park.min.Y) / cell)
		for i = 0, nx - 1 do
			for j = 0, nz - 1 do
				local rng = Random.new(mixSeed(seed + 101 * parkIndex, i, j))
				local jx, jz, roll = rng:NextNumber(), rng:NextNumber(), rng:NextNumber()
				local rolls = treeRolls(rng)
				local x = park.min.X + (i + 0.15 + 0.7 * jx) * cell
				local z = park.min.Y + (j + 0.15 + 0.7 * jz) * cell
				if roll < params.chance and insidePark(park, x, z) then
					plant(Vector2.new(x, z), rolls, "park", config.parkRoadClearance)
				end
			end
		end
	end

	-- The groves.
	for groveIndex, grove in config.groves do
		if layout.zones[grove.zone] == nil then
			continue
		end
		local cell = grove.cell
		local cells = math.ceil(2 * ctx.half / cell)
		for i = 0, cells - 1 do
			for j = 0, cells - 1 do
				local rng = Random.new(mixSeed(seed + 7907 * groveIndex, i, j))
				local jx, jz, roll = rng:NextNumber(), rng:NextNumber(), rng:NextNumber()
				local countRoll, radiusRoll = rng:NextNumber(), rng:NextNumber()
				local centre =
					Vector2.new(-ctx.half + (i + 0.2 + 0.6 * jx) * cell, -ctx.half + (j + 0.2 + 0.6 * jz) * cell)
				if regionAt(centre) ~= grove.zone or centre.X < reserved then
					continue
				end
				local outskirts = math.max(math.abs(centre.X), math.abs(centre.Y)) > config.outskirtsFrom
				local chance = if outskirts then grove.outskirtsChance or grove.chance else grove.chance
				if roll >= chance then
					continue
				end
				if gridHits(ctx.grid, square(centre, config.groveRoadClearance), TREE_ROAD_KINDS, 0) then
					continue
				end
				local low, high = grove.trees[1], grove.trees[2]
				local count = math.min(high, low + math.floor(countRoll * (high - low + 1)))
				local radius = grove.radius[1] + radiusRoll * (grove.radius[2] - grove.radius[1])
				local mixName = if outskirts then "outskirts" else grove.species
				for _ = 1, count do
					local angle, distance = rng:NextNumber() * TAU, radius * math.sqrt(rng:NextNumber())
					local rolls = treeRolls(rng)
					local p = centre + Vector2.new(math.cos(angle), math.sin(angle)) * distance
					if regionAt(p) == grove.zone then
						plant(p, rolls, mixName, config.roadClearance)
					end
				end
			end
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
		sites = {},
		city = { legacy = {}, open = {}, parts = {}, lights = 0, skyline = 0, claims = 0, unplaced = {}, missing = {} },
		lit = {},
		host = nil,
		scenery = {},
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
	container(ctx, "Trees", "Folder")

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
	addHills(ctx)
	addJumpRamps(ctx)
	addLandmarks(ctx)
	addLocations(ctx)
	addSpawns(ctx)
	addDisplayPads(ctx)
	addBillboards(ctx)
	addFeatures(ctx)
	addStreetlights(ctx)
	addParks(ctx)
	addBuildings(ctx, zones)
	addScenery(ctx)
	addTrees(ctx, zones)

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
	return {
		specs = ctx.specs,
		containers = ctx.containers,
		notes = notes,
		counts = counts,
		sites = ctx.sites,
		city = ctx.city,
		scenery = ctx.scenery,
	}
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
		plain.Shape = if spec.shape == "cylinder"
			then Enum.PartType.Cylinder
			elseif spec.shape == "ball" then Enum.PartType.Ball
			else Enum.PartType.Block
		part = plain
	end
	part.Name = spec.name
	part.Size = spec.size
	part.CFrame = spec.cframe
	part.Color = spec.color
	part.Material = spec.material
	part.Transparency = spec.transparency
	part.Reflectance = spec.reflectance or 0
	local variant = spec.materialVariant
	if variant then
		part.MaterialVariant = variant -- a name MaterialService may not hold yet: the part then shows its plain material
	end
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
		elseif light.kind == "surface" then
			local surface = Instance.new("SurfaceLight")
			surface.Face = light.face
			surface.Angle = light.angle
			surface.Range = light.range
			instance = surface
		else
			local point = Instance.new("PointLight")
			point.Range = light.range
			instance = point
		end
		instance.Brightness = light.brightness
		instance.Color = light.color
		instance.Shadows = false
		instance.Enabled = light.enabled ~= false
		instance.Parent = part
	end
	local labels: { LabelSpec } = spec.labels or {}
	for i, label in labels do
		local gui = Instance.new("SurfaceGui")
		gui.Name = `Label{i}`
		gui.Face = label.face
		gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
		gui.PixelsPerStud = label.pixelsPerStud or TUNING.labelPixelsPerStud
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
		text.Font = label.font or TUNING.labelFont
		text.TextScaled = true
		text.Parent = gui
	end
	local textures: { TextureSpec } = spec.textures or {}
	for i, look in textures do
		local texture = Instance.new("Texture")
		texture.Name = `Texture{i}`
		texture.Face = look.face
		texture.Texture = look.image
		texture.StudsPerTileU = look.u
		texture.StudsPerTileV = look.v
		texture.OffsetStudsU = look.offsetU or 0
		texture.OffsetStudsV = look.offsetV or 0
		texture.Color3 = look.color
		texture.Transparency = look.transparency or 0
		texture.Parent = part
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

-- One planned part as an instance, unparented (the city previews in docs/city/ARCHETYPE_GUIDE.md build sample sites
-- with it, exactly as build() would).
MapBuilder.createPart = createPart

local building = false
local lodWarned = false

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
				local lod = entry.lod
				if lod then
					-- SLIM needs StreamingEnabled and a place published with Team Create (docs/city/TECH.md §6); a Studio
					-- that doesn't know the setting keeps the model's default.
					local set = pcall(function()
						(model :: any).LevelOfDetail = (Enum.ModelLevelOfDetail :: any)[lod]
					end)
					if not set and not lodWarned then
						lodWarned = true
						warn(
							`[MapBuilder] this Studio can't set Model.LevelOfDetail {lod}; city models keep the default`
						)
					end
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
		local standIns = 0
		for i, spec in plan.specs do
			-- A templated spec (a palm's crown) becomes a clone of its template, or the parts-only stand-in.
			if spec.template then
				local made = Scenery.instantiate(spec, createPart)
				if made:GetAttribute(Scenery.Palms.standInAttribute) then
					standIns += 1
				end
				made.Parent = containers[spec.folder] or generated
				if i % TUNING.partsPerChunk == 0 then
					task.wait()
				end
				continue
			end
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
		if standIns > 0 then
			-- The palm meshes (ServerStorage.CityAssets, Studio-owned) are missing: the map is far over its part budgets
			-- and Dev/MapCheck fails until they are back and the map is rebuilt.
			warn(
				`[MapBuilder] note: {standIns} palms are parts-only stand-ins (no ServerStorage.CityAssets.Palms templates); `
					.. "the map is over its part budgets until the templates are back"
			)
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
