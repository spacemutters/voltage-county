--!strict
-- Where everything is in Voltage County (PLAN.md §5; docs/phase-2-contracts.md, "Data"): the zones, every
-- tagged location, the player spawns, and the shapes MapBuilder needs for the ground (the lake, the mesas) plus
-- the Mesa's jump ramps and the big landmark buildings. Roads live in Config/RoadGraph.
--
-- Coordinates: X is east, north is -Z, Y is up; the ground top is y = 0 except on the mesas and in the lake.
-- Rough plan, seen from above with north up (each zone's exact bounds are below):
--   Cedar Bend downtown in the middle; Riverside to the west; The Plant to the east; the Mesa Test Site to the
--   north; the Lakefront to the south; the County Loop ring highway 3,400 studs out on every side. The dev test
--   track sits west of the loop (x < -3,700), outside every zone.
--
-- Locations: `position` is the centre of the footprint, on the surface it stands on (Y = that surface's top:
-- the ground, a mesa top, or the road for drag-strip gates). The tagged part sits on it: its bottom face at
-- position.Y, so its centre is position + (0, size.Y / 2, 0). `yaw` is in degrees, 0 faces north (-Z) and 90
-- faces west (-X), i.e. CFrame.Angles(0, math.rad(yaw), 0); `size` is in the part's own axes (X across, Y up,
-- Z front to back). Pads beside a road face it (yaw points at the road), sit clear of its carriageway and
-- sidewalk, and lie within RoadGraph.roadReach of its centre line. Volumes (FlightZone, NoFlyZone) and
-- drag-strip gates may span roads.
--
-- Tags and attributes (PLAN.md §5): ChargerStall { kW, plaza }, TruckCharger { kW }, FuelPump { rate: percent
-- of the tank per second }, JobDepot { jobType: "delivery" | "freight" | "towing" }, DragStripGate { index:
-- 1 = start line, 2 = 330 ft, 3 = 1/8 mile, 4 = 1/4 mile (finish) }, CustomShop (Phase 7, the Wrap & Tint shop:
-- its footprint is the bay a car must stand in to customize; MapBuilder puts a garage door behind it and
-- Services/CustomizationService adds the "Customize" prompt). A HousePlot's display name is its address
-- (delivery drops use it too). A location with gps = true is listed as a GPS destination. One location per
-- group of pads (a plaza's first stall, a station's first pump) carries the group's GPS entry.
--
-- Phase 8 (docs/phase-8-contracts.md, "Map"): three freight depots (JobDepot jobType "freight": The Plant, the
-- Loop Stop and the west interchange, across the County Loop from the other two), each with TrailerSpawn
-- spots { depot: its depot's id, trailer: a ServerStorage.TrailerModels name } where an idle trailer waits
-- (Services/HitchService puts one on each, nose to the road, at Start); TowDrop spots { yard } at the County Tow
-- Yard where a towed car is let go; and Breakdown spots on road shoulders in every zone, where the towing job
-- leaves a broken-down car. Services/HitchService only lets a trailer or towed car go inside a freight depot,
-- the tow yard or a TowDrop footprint. A TrailerSpawn is long enough for a trailer standing on it nose to the
-- road; a Breakdown spot runs along its road with room for the broken-down car and a tow truck.
--
-- The look beyond the roads (docs/roast-2026-10-24.md point 3): each zone's ground material and, for the green ones,
-- grass shades MapBuilder patchworks in tiles (Config/Environment ground.tile); gentle grass hills at the edge of the
-- map (`hills`, outside the County Loop, part of groundHeight); parks (`parks`: no buildings, thick with trees, and
-- their own grass where they say so); and the features MapBuilder builds as landmarks you can tell from the road
-- (`features`: the Riverside water tower, the Overlook Diner by the Lakeview Overlook, the Cedar Lake Bridge's
-- arches). The Ohm Motors Plant carries a rooftop sign (its landmark's signBrand). Trees, windows and the day/night
-- cycle are tuned in Config/Environment.
--
-- tests/RoadGraph.spec checks the locations, lake, mesas, ramps and landmarks against the road graph;
-- tests/MapBuilder.spec checks the hills, parks and features.

-- A shade of ground: one tile of a zone's patchwork.
export type GroundShade = { color: Color3, material: Enum.Material }

export type Zone = {
	id: string,
	displayName: string,
	min: Vector2, -- X and Z bounds of the zone on the ground
	max: Vector2,
	groundColor: Color3,
	groundMaterial: Enum.Material?, -- default Grass
	groundShades: { GroundShade }?, -- when set, each ground tile takes one of these instead of groundColor
	buildingColors: { Color3 },
	buildingHeight: { min: number, max: number }, -- studs
	buildingDensity: number, -- 0..1, how full the city blocks are
}

export type Location = {
	id: string, -- unique; also the part's name
	displayName: string, -- shown to players (GPS, prompts)
	tag: string, -- one CollectionService tag from PLAN.md §5
	zone: string, -- a Zone id
	position: Vector3, -- centre of the footprint, on the surface (Y = surface top)
	yaw: number, -- degrees; 0 faces north (-Z), 90 faces west (-X)
	size: Vector3, -- the tagged part's size
	attributes: { [string]: any }?,
	gps: boolean?, -- true = listed as a GPS destination
	-- Where the GPS leads instead of `position`, when the place players want is elsewhere on the site (the
	-- dealership's cars stand in the auto mall, not at the showroom door).
	gpsTarget: Vector3?,
}

-- A lake: a rectangle of water. The ground under it is the lake bed.
export type Lake = {
	id: string,
	displayName: string,
	zone: string,
	min: Vector2, -- X and Z bounds of the water
	max: Vector2,
	waterY: number, -- water surface
	bedY: number, -- lake bed (top of the ground under the water)
}

-- A mesa: a flat-topped hill with four planar sides (a truncated pyramid: a box for the top, wedges for the
-- sides, corner wedges at the corners). Its foot is the top rectangle grown by height / slope on every side.
export type Mesa = {
	id: string,
	displayName: string,
	zone: string,
	topMin: Vector2, -- X and Z bounds of the flat top
	topMax: Vector2,
	height: number, -- top surface y
	slope: number, -- rise / run of the sides
}

-- A jump ramp: a wedge on the ground rising toward `yaw` (its lip, size.Y high, is at the front).
export type JumpRamp = {
	id: string,
	zone: string,
	position: Vector3, -- centre of the base, on the ground
	yaw: number,
	size: Vector3, -- width, lip height, length
}

-- A landmark building MapBuilder should build here (in place of block filler), clear of roads and pads.
export type Landmark = {
	id: string,
	displayName: string,
	zone: string,
	kind: string, -- "showroom", "office", "factory", "studio", "warehouse", "garage", "control_tower"
	position: Vector3, -- centre of the footprint, on the ground
	yaw: number, -- the side it faces (its entrance)
	size: Vector3,
	signBrand: string?, -- a Config/Brands id: a sign with the brand's name stands on the roof, facing the entrance
}

-- A park: no buildings or lots inside (min..max, less the `hole`), trees planted thick (Config/Environment trees.parks),
-- and its own grass when groundColor is set (else the zone's ground shows).
export type Park = {
	id: string,
	displayName: string,
	zone: string,
	min: Vector2,
	max: Vector2,
	hole: { min: Vector2, max: Vector2 }?, -- left out (the lake inside Lakefront Park)
	groundColor: Color3?,
	groundMaterial: Enum.Material?,
}

-- A feature MapBuilder builds to be told apart from the road (Generated.Features/<id>). `position` is the centre of
-- its footprint on the ground and `size` its footprint (X across, Z front to back) and height, facing `yaw`:
--   water_tower   a tank on four legs, `size.Y` tall, with a red beacon on top
--   diner         a site: the diner at the back (away from the road `yaw` faces), its car park in front and a tall
--                 sign by the road reading `sign`
--   bridge_arch   steel arches either side of a bridge deck: `position` is the middle of the deck on its surface,
--                 size.X the distance between the two arches, size.Y their rise, size.Z the span between their feet
export type Feature = {
	id: string,
	displayName: string,
	zone: string,
	kind: "water_tower" | "diner" | "bridge_arch",
	position: Vector3,
	yaw: number,
	size: Vector3,
	sign: string?,
}

-- Display pads (Phase 4; docs/phase-4-contracts.md "Map: dealership pads and used-lot pads"). A pad's CFrame is
-- the centre of its footprint on the ground (y = the ground top), turned to face the way a car standing on it
-- points its nose. Every pad of a layout is `padSize` (X across, Y the platform's height, Z front to back), so a
-- display car's pivot goes at pad * CFrame.new(0, padSize.Y, 0). MapBuilder builds the platforms (and keeps
-- buildings, lots and props off them); Services/DealershipService and Services/UsedLotService put the cars on.
export type DealershipSection = {
	brandId: string, -- a Config/Brands id; the section's sign shows its displayName
	pads: { CFrame }, -- display order: the cheapest car of the brand stands on pad 1
}

export type DealershipLayout = {
	padSize: Vector3,
	sections: { DealershipSection },
}

export type UsedLotLayout = {
	padSize: Vector3,
	pads: { CFrame }, -- numbered spaces; space N shows the day's used-lot slot N (Config/UsedLot)
}

-- A billboard (Phase 12; docs/phase-12-contracts.md "Ads, analytics, admin"): a panel on two posts beside a road.
-- MapBuilder builds it under Generated.Billboards: the panel is tagged Config/Ads.billboards.tag, carries an AdGui on
-- its Front face (the face `yaw` points at, toward the traffic coming at it) and its brand's poster on the Back face.
-- Its Front face (size.X wide, size.Y tall) stays inside Roblox's ad unit limits (Config/Ads.billboards minFace and
-- maxFace; tests/Ads.spec checks). The panel and its posts keep clear of roads, sidewalks, locations and props
-- (MapBuilder leaves a note, which fails tests/MapBuilder.spec, if one doesn't).
export type Billboard = {
	id: string, -- unique; also the panel part's name
	zone: string, -- a Zone id
	position: Vector3, -- centre of the footprint on the ground (Y = the ground top)
	yaw: number, -- degrees, the way the ad face looks; 0 faces north (-Z), 90 faces west (-X)
	size: Vector3, -- the panel: X its width (the ad's width), Y its height, Z its thickness
	clearance: number, -- studs from the ground to the panel's bottom edge (the posts' height)
	brandId: string, -- the Config/Brands brand whose poster it shows when no ad is served
}

export type MapLayout = {
	seed: number,
	zones: { [string]: Zone },
	zoneOrder: { string },
	locations: { Location },
	playerSpawns: { CFrame },
	lakes: { Lake },
	mesas: { Mesa },
	hills: { Mesa }, -- grass hills at the edge of the map: the mesa shape, gentler
	parks: { Park },
	features: { Feature },
	jumpRamps: { JumpRamp },
	landmarks: { Landmark },
	dealership: DealershipLayout,
	usedLot: UsedLotLayout,
	billboards: { Billboard },
	reservedWestOfX: number,
	padClearance: number,
	groundHeight: (x: number, z: number) -> number,
}

local v3 = Vector3.new

type Place = (
	id: string,
	tag: string,
	displayName: string,
	position: Vector3,
	yaw: number,
	size: Vector3,
	attributes: { [string]: any }?,
	gps: boolean?
) -> Location

-- Makes the Locations of one zone (so the rows below need not repeat it).
local function placer(zone: string): Place
	return function(id, tag, displayName, position, yaw, size, attributes, gps)
		return {
			id = id,
			displayName = displayName,
			tag = tag,
			zone = zone,
			position = position,
			yaw = yaw,
			size = size,
			attributes = attributes,
			gps = gps,
		}
	end
end

-- A location whose GPS route ends at `target` instead of its own position (Location.gpsTarget).
local function withGpsTarget(location: Location, target: Vector3): Location
	location.gpsTarget = target
	return location
end

local cedarBend = placer("cedar_bend")
local riverside = placer("riverside")
local thePlant = placer("the_plant")
local mesaTestSite = placer("mesa_test_site")
local lakefront = placer("lakefront")
local countyLoop = placer("county_loop")

-- Common pad sizes (width along the road, height, depth away from it).
local SPAWN_PAD = v3(16, 1, 24) -- a car's parking space
local STALL = v3(12, 1, 20) -- one charging stall
local PUMP = v3(14, 1, 24) -- one fuel pump's lane
local TRUCK_STALL = v3(24, 1, 40) -- one truck charging bay
local HOTSPOT = v3(30, 1, 16) -- a kerbside pickup spot
local HOUSE = v3(50, 1, 40) -- a house plot
local CUSTOM_SHOP = v3(24, 1, 32) -- a Wrap & Tint shop's bay: one car with room to walk round it
-- Phase 8: freight and towing.
local FREIGHT_DEPOT = v3(80, 1, 36) -- a freight depot's yard in front of its trailer spots
local TRAILER_SPOT = v3(64, 1, 18) -- one idle trailer standing along the road (see the header)
local TOW_DROP = v3(20, 1, 32) -- one towed car let go at the tow yard
local BREAKDOWN = v3(32, 1, 24) -- a shoulder spot: a broken-down car and a tow truck pulled in ahead of it

-- Attributes shared by a group of locations (frozen: one table serves them all).
local CEDAR_PLAZA_250KW = table.freeze({ kW = 250, plaza = "cedar_bend_plaza" })
local CEDAR_PLAZA_150KW = table.freeze({ kW = 150, plaza = "cedar_bend_plaza" })
local FUEL_PUMP = table.freeze({ rate = 4 })
local RIVERSIDE_FUEL_150KW = table.freeze({ kW = 150, plaza = "riverside_fuel" })
local OVERLOOK_150KW = table.freeze({ kW = 150, plaza = "lakeview_overlook" })
local STUDIO_250KW = table.freeze({ kW = 250, plaza = "design_studio" })
local TRUCK_CHARGER_750KW = table.freeze({ kW = 750 })
local MESA_CONTROL_250KW = table.freeze({ kW = 250, plaza = "mesa_control" })
local LOOP_STOP_350KW = table.freeze({ kW = 350, plaza = "loop_stop" })
local FREIGHT = table.freeze({ jobType = "freight" })
local TOW_YARD = table.freeze({ yard = "pl_tow_yard" })

-- A TrailerSpawn's attributes: the depot it belongs to and the trailer model that waits on it.
local function trailerSpot(depot: string, trailer: string): { [string]: any }
	return table.freeze({ depot = depot, trailer = trailer })
end

local zones: { [string]: Zone } = {
	-- Downtown: a 300-stud street grid, the used lot (player spawn), dealership, charging plaza, fuel.
	cedar_bend = {
		id = "cedar_bend",
		displayName = "Cedar Bend",
		min = Vector2.new(-1000, -1000),
		max = Vector2.new(1000, 1000),
		-- Pale Miami concrete, not grey asphalt (roast 2026-10-26 point 1: a Miami condo district's blocks are pale paving, pool decks
		-- and podiums to the kerb; the dark ground read as parking between the towers). Town Square keeps its grass.
		groundColor = Color3.fromRGB(206, 202, 194),
		groundMaterial = Enum.Material.Concrete,
		buildingColors = {
			Color3.fromRGB(152, 108, 88),
			Color3.fromRGB(176, 160, 136),
			Color3.fromRGB(120, 124, 130),
			Color3.fromRGB(196, 186, 166),
			Color3.fromRGB(98, 92, 88),
		},
		buildingHeight = { min = 40, max = 160 },
		buildingDensity = 0.85,
	},
	-- Suburbs: curving streets, cul-de-sacs with house plots (delivery drops), a fuel station.
	riverside = {
		id = "riverside",
		displayName = "Riverside",
		min = Vector2.new(-3100, -1100),
		max = Vector2.new(-1200, 1300),
		groundColor = Color3.fromRGB(106, 134, 82),
		groundShades = {
			{ color = Color3.fromRGB(106, 134, 82), material = Enum.Material.Grass },
			{ color = Color3.fromRGB(98, 128, 76), material = Enum.Material.LeafyGrass },
		},
		buildingColors = {
			Color3.fromRGB(214, 204, 184),
			Color3.fromRGB(186, 170, 150),
			Color3.fromRGB(160, 176, 186),
			Color3.fromRGB(200, 184, 160),
			Color3.fromRGB(150, 140, 124),
		},
		buildingHeight = { min = 14, max = 24 },
		buildingDensity = 0.35,
	},
	-- Industrial park: the EV factory, Design Studio, freight depot, truck chargers, tow yard.
	the_plant = {
		id = "the_plant",
		displayName = "The Plant",
		min = Vector2.new(1200, -1100),
		max = Vector2.new(3100, 1200),
		groundColor = Color3.fromRGB(122, 122, 118),
		groundMaterial = Enum.Material.Concrete,
		buildingColors = {
			Color3.fromRGB(150, 156, 162),
			Color3.fromRGB(118, 124, 132),
			Color3.fromRGB(176, 178, 176),
			Color3.fromRGB(96, 102, 110),
		},
		buildingHeight = { min = 24, max = 60 },
		buildingDensity = 0.5,
	},
	-- Test site: mesas with dirt trails, jump ramps, the drag strip, the flight field.
	mesa_test_site = {
		id = "mesa_test_site",
		displayName = "Mesa Test Site",
		min = Vector2.new(-800, -3100),
		max = Vector2.new(3000, -1300),
		groundColor = Color3.fromRGB(196, 162, 120),
		groundMaterial = Enum.Material.Sand,
		buildingColors = {
			Color3.fromRGB(170, 150, 124),
			Color3.fromRGB(140, 130, 118),
		},
		buildingHeight = { min = 8, max = 20 },
		buildingDensity = 0.03,
	},
	-- Cedar Lake, its raised bridge and the Lakeview Overlook meet spot.
	lakefront = {
		id = "lakefront",
		displayName = "Lakefront",
		min = Vector2.new(-1400, 1300),
		max = Vector2.new(1400, 3100),
		groundColor = Color3.fromRGB(112, 144, 86),
		groundShades = {
			{ color = Color3.fromRGB(112, 144, 86), material = Enum.Material.Grass },
			{ color = Color3.fromRGB(104, 136, 80), material = Enum.Material.LeafyGrass },
		},
		buildingColors = {
			Color3.fromRGB(220, 214, 200),
			Color3.fromRGB(176, 196, 206),
			Color3.fromRGB(196, 178, 150),
		},
		buildingHeight = { min = 12, max = 40 },
		buildingDensity = 0.2,
	},
	-- The ring highway. Its bounds are the ring's outer box and its ground is the open country between the zones
	-- and out to the edge of the map, a patchwork of grass; Graph.zoneAt finds it by road (highway and ramp
	-- edges), not by bounds.
	county_loop = {
		id = "county_loop",
		displayName = "County Loop",
		min = Vector2.new(-3450, -3450),
		max = Vector2.new(3450, 3450),
		groundColor = Color3.fromRGB(108, 136, 78),
		groundShades = {
			{ color = Color3.fromRGB(108, 136, 78), material = Enum.Material.Grass },
			{ color = Color3.fromRGB(98, 128, 72), material = Enum.Material.LeafyGrass },
			{ color = Color3.fromRGB(120, 142, 84), material = Enum.Material.Grass },
			{ color = Color3.fromRGB(92, 120, 70), material = Enum.Material.LeafyGrass },
		},
		buildingColors = {
			Color3.fromRGB(160, 150, 130),
		},
		buildingHeight = { min = 10, max = 20 },
		buildingDensity = 0,
	},
}

-- zone(id, tag, display name, position, yaw, size, attributes, gps)
local locations: { Location } = {
	-- Cedar Bend: the used lot (spawn) with its spawn pads, the dealership, the charging plaza across the
	-- street, the fuel station, the parcel depot and rideshare hotspots.
	cedarBend("used_lot", "UsedLot", "Used Lot", v3(460, 0, 350), 0, v3(120, 1, 50), nil, true),
	cedarBend("used_lot_pad_1", "SpawnPad", "Used Lot", v3(344, 0, 337), 0, SPAWN_PAD),
	cedarBend("used_lot_pad_2", "SpawnPad", "Used Lot", v3(364, 0, 337), 0, SPAWN_PAD),
	cedarBend("used_lot_pad_3", "SpawnPad", "Used Lot", v3(384, 0, 337), 0, SPAWN_PAD),
	withGpsTarget(
		cedarBend("dealership", "Dealership", "Cedar Bend Motors", v3(750, 0, 345), 0, v3(100, 1, 40), nil, true),
		-- The street between the showroom's back (Ohm's pads) and the auto mall's rows (row 6, z = 600), so the
		-- GPS arrives among the display cars rather than 185+ studs from them at the showroom door.
		v3(750, 0, 600)
	),
	cedarBend("dealership_pad", "SpawnPad", "Cedar Bend Motors", v3(860, 0, 337), 0, SPAWN_PAD),
	cedarBend("cb_charger_1", "ChargerStall", "Charging Plaza", v3(335, 0, 265), 180, STALL, CEDAR_PLAZA_250KW, true),
	cedarBend("cb_charger_2", "ChargerStall", "Charging Plaza", v3(349, 0, 265), 180, STALL, CEDAR_PLAZA_250KW),
	cedarBend("cb_charger_3", "ChargerStall", "Charging Plaza", v3(363, 0, 265), 180, STALL, CEDAR_PLAZA_250KW),
	cedarBend("cb_charger_4", "ChargerStall", "Charging Plaza", v3(377, 0, 265), 180, STALL, CEDAR_PLAZA_250KW),
	cedarBend("cb_charger_5", "ChargerStall", "Charging Plaza", v3(391, 0, 265), 180, STALL, CEDAR_PLAZA_150KW),
	cedarBend("cb_charger_6", "ChargerStall", "Charging Plaza", v3(405, 0, 265), 180, STALL, CEDAR_PLAZA_150KW),
	cedarBend("cb_fuel_1", "FuelPump", "Cedar Bend Fuel", v3(-510, 0, 337), 0, PUMP, FUEL_PUMP, true),
	cedarBend("cb_fuel_2", "FuelPump", "Cedar Bend Fuel", v3(-490, 0, 337), 0, PUMP, FUEL_PUMP),
	cedarBend("cb_fuel_3", "FuelPump", "Cedar Bend Fuel", v3(-470, 0, 337), 0, PUMP, FUEL_PUMP),
	cedarBend("cb_fuel_4", "FuelPump", "Cedar Bend Fuel", v3(-450, 0, 337), 0, PUMP, FUEL_PUMP),
	cedarBend(
		"cb_parcel_depot",
		"JobDepot",
		"Parcel Depot",
		v3(-750, 0, 250),
		180,
		v3(100, 1, 50),
		{ jobType = "delivery" },
		true
	),
	cedarBend("cb_hotspot_square", "RideshareHotspot", "Town Square", v3(-150, 0, -48), 180, HOTSPOT),
	cedarBend("cb_hotspot_theater", "RideshareHotspot", "Theater Row", v3(450, 0, -567), 0, HOTSPOT),
	cedarBend("cb_hotspot_market", "RideshareHotspot", "Market Street", v3(-567, 0, -450), 90, HOTSPOT),
	cedarBend("cb_hotspot_courthouse", "RideshareHotspot", "Courthouse", v3(-48, 0, 450), -90, HOTSPOT),
	-- Phase 7: the Wrap & Tint shop, a short drive west of the used lot along the same street, facing it.
	cedarBend("cb_custom_shop", "CustomShop", "Cedar Bend Wrap & Tint", v3(150, 0, 342), 0, CUSTOM_SHOP, nil, true),
	-- Phase 8: breakdown spots on the outer streets of the grid (west edge, south edge).
	cedarBend("cb_breakdown_west", "Breakdown", "West Street shoulder", v3(-936.5, 0, -150), -90, BREAKDOWN),
	cedarBend("cb_breakdown_south", "Breakdown", "South Street shoulder", v3(450, 0, 936.5), 0, BREAKDOWN),
	-- Riverside: the fuel station, a rideshare hotspot, and house plots round the cul-de-sacs and along
	-- Sycamore Lane and Elm Street (delivery drops and, later, claimable homes).
	riverside("rv_fuel_1", "FuelPump", "Riverside Fuel", v3(-2430, 0, 52), 0, PUMP, FUEL_PUMP, true),
	riverside("rv_fuel_2", "FuelPump", "Riverside Fuel", v3(-2450, 0, 52), 0, PUMP, FUEL_PUMP),
	riverside("rv_fuel_3", "FuelPump", "Riverside Fuel", v3(-2470, 0, 52), 0, PUMP, FUEL_PUMP),
	riverside("rv_charger_1", "ChargerStall", "Riverside Fuel", v3(-2510, 0, 50), 0, STALL, RIVERSIDE_FUEL_150KW),
	riverside("rv_charger_2", "ChargerStall", "Riverside Fuel", v3(-2524, 0, 50), 0, STALL, RIVERSIDE_FUEL_150KW),
	riverside("rv_hotspot_market", "RideshareHotspot", "Riverside Market", v3(-1800, 0, -48), 180, HOTSPOT, nil, true),
	riverside("rv_cedar_ct_1", "HousePlot", "1 Cedar Court", v3(-2201.3, 0, -808), -67.5, HOUSE),
	riverside("rv_cedar_ct_2", "HousePlot", "3 Cedar Court", v3(-2201.3, 0, -892), -112.5, HOUSE),
	riverside("rv_cedar_ct_3", "HousePlot", "5 Cedar Court", v3(-2142, 0, -951.3), -157.5, HOUSE, nil, true),
	riverside("rv_cedar_ct_4", "HousePlot", "7 Cedar Court", v3(-2058, 0, -951.3), 157.5, HOUSE),
	riverside("rv_cedar_ct_5", "HousePlot", "9 Cedar Court", v3(-1998.7, 0, -892), 112.5, HOUSE),
	riverside("rv_pecan_ct_1", "HousePlot", "1 Pecan Court", v3(-1476.9, 0, -476.8), -127.5, HOUSE),
	riverside("rv_pecan_ct_2", "HousePlot", "3 Pecan Court", v3(-1404.2, 0, -518.7), -172.5, HOUSE),
	riverside("rv_pecan_ct_3", "HousePlot", "5 Pecan Court", v3(-1323.1, 0, -497), 142.5, HOUSE),
	riverside("rv_pecan_ct_4", "HousePlot", "7 Pecan Court", v3(-1281.1, 0, -424.3), 97.5, HOUSE),
	riverside("rv_pecan_ct_5", "HousePlot", "9 Pecan Court", v3(-1302.9, 0, -343.2), 52.5, HOUSE),
	riverside("rv_willow_ct_1", "HousePlot", "1 Willow Court", v3(-2824.4, 0, -301.3), -7.5, HOUSE),
	riverside("rv_willow_ct_2", "HousePlot", "3 Willow Court", v3(-2897.1, 0, -343.2), -52.5, HOUSE),
	riverside("rv_willow_ct_3", "HousePlot", "5 Willow Court", v3(-2918.9, 0, -424.3), -97.5, HOUSE),
	riverside("rv_willow_ct_4", "HousePlot", "7 Willow Court", v3(-2876.9, 0, -497), -142.5, HOUSE),
	riverside("rv_willow_ct_5", "HousePlot", "9 Willow Court", v3(-2795.8, 0, -518.7), 172.5, HOUSE),
	riverside("rv_magnolia_ct_1", "HousePlot", "1 Magnolia Court", v3(-1998.7, 0, 1078), 112.5, HOUSE),
	riverside("rv_magnolia_ct_2", "HousePlot", "3 Magnolia Court", v3(-1998.7, 0, 1162), 67.5, HOUSE),
	riverside("rv_magnolia_ct_3", "HousePlot", "5 Magnolia Court", v3(-2058, 0, 1221.3), 22.5, HOUSE),
	riverside("rv_magnolia_ct_4", "HousePlot", "7 Magnolia Court", v3(-2142, 0, 1221.3), -22.5, HOUSE),
	riverside("rv_magnolia_ct_5", "HousePlot", "9 Magnolia Court", v3(-2201.3, 0, 1162), -67.5, HOUSE),
	riverside("rv_sycamore_ln_1", "HousePlot", "2 Sycamore Lane", v3(-2230, 0, 845), 0, HOUSE),
	riverside("rv_sycamore_ln_2", "HousePlot", "4 Sycamore Lane", v3(-2310, 0, 845), 0, HOUSE),
	riverside("rv_sycamore_ln_3", "HousePlot", "6 Sycamore Lane", v3(-2390, 0, 845), 0, HOUSE),
	riverside("rv_elm_st_1", "HousePlot", "1 Elm Street", v3(-1950, 0, 355), 180, HOUSE),
	riverside("rv_elm_st_2", "HousePlot", "3 Elm Street", v3(-1800, 0, 355), 180, HOUSE),
	riverside("rv_elm_st_3", "HousePlot", "5 Elm Street", v3(-1650, 0, 355), 180, HOUSE),
	-- Phase 8: breakdown spots on Main Street south of the avenue and on the west road to Sycamore Lane.
	riverside("rv_breakdown_main", "Breakdown", "Main Street shoulder", v3(-2063.5, 0, 200), 90, BREAKDOWN),
	riverside("rv_breakdown_west", "Breakdown", "Sycamore Road shoulder", v3(-2736.5, 0, 300), -90, BREAKDOWN),
	-- Lakefront: the Lakeview Overlook meet spot with chargers, and Lakefront Park.
	lakefront("lk_overlook", "MeetSpot", "Lakeview Overlook", v3(1100, 0, 2175), -90, v3(80, 1, 50), nil, true),
	lakefront("lk_charger_1", "ChargerStall", "Lakeview Overlook", v3(1115, 0, 2075), -90, STALL, OVERLOOK_150KW),
	lakefront("lk_charger_2", "ChargerStall", "Lakeview Overlook", v3(1115, 0, 2089), -90, STALL, OVERLOOK_150KW),
	lakefront("lk_charger_3", "ChargerStall", "Lakeview Overlook", v3(1115, 0, 2103), -90, STALL, OVERLOOK_150KW),
	lakefront("lk_hotspot_park", "RideshareHotspot", "Lakefront Park", v3(-500, 0, 1533), 0, HOTSPOT, nil, true),
	-- Phase 8: breakdown spots on the lake's west road and its south shore road.
	lakefront("lk_breakdown_west", "Breakdown", "Lake West Road shoulder", v3(-1186.5, 0, 2050), -90, BREAKDOWN),
	lakefront("lk_breakdown_south", "Breakdown", "South Shore Road shoulder", v3(450, 0, 2886.5), 0, BREAKDOWN),
	-- The Plant: the Design Studio, freight depot, truck chargers, tow yard and the gate hotspot.
	thePlant("pl_design_studio", "DesignStudio", "Design Studio", v3(1900, 0, 60), 0, v3(60, 1, 40), nil, true),
	thePlant("pl_charger_1", "ChargerStall", "Design Studio", v3(1990, 0, 50), 0, STALL, STUDIO_250KW),
	thePlant("pl_charger_2", "ChargerStall", "Design Studio", v3(2004, 0, 50), 0, STALL, STUDIO_250KW),
	thePlant("pl_freight_depot", "JobDepot", "Plant Freight Depot", v3(2258, 0, 350), 90, FREIGHT_DEPOT, FREIGHT, true),
	-- Phase 8: the Plant depot's trailer spots, beside its yard along the depot road, noses to the road.
	thePlant(
		"pl_trailer_1",
		"TrailerSpawn",
		"Plant Freight Depot",
		v3(2248.5, 0, 425),
		90,
		TRAILER_SPOT,
		trailerSpot("pl_freight_depot", "box_trailer")
	),
	thePlant(
		"pl_trailer_2",
		"TrailerSpawn",
		"Plant Freight Depot",
		v3(2248.5, 0, 491),
		90,
		TRAILER_SPOT,
		trailerSpot("pl_freight_depot", "flatbed_trailer")
	),
	thePlant(
		"pl_trailer_3",
		"TrailerSpawn",
		"Plant Freight Depot",
		v3(2248.5, 0, 557),
		90,
		TRAILER_SPOT,
		trailerSpot("pl_freight_depot", "tanker_trailer")
	),
	thePlant(
		"pl_truck_charger_1",
		"TruckCharger",
		"Truck Charging",
		v3(2450, 0, 640),
		180,
		TRUCK_STALL,
		TRUCK_CHARGER_750KW,
		true
	),
	thePlant(
		"pl_truck_charger_2",
		"TruckCharger",
		"Truck Charging",
		v3(2480, 0, 640),
		180,
		TRUCK_STALL,
		TRUCK_CHARGER_750KW
	),
	thePlant(
		"pl_truck_charger_3",
		"TruckCharger",
		"Truck Charging",
		v3(2510, 0, 640),
		180,
		TRUCK_STALL,
		TRUCK_CHARGER_750KW
	),
	thePlant(
		"pl_tow_yard",
		"JobDepot",
		"County Tow Yard",
		v3(2858, 0, -400),
		90,
		v3(60, 1, 36),
		{ jobType = "towing" },
		true
	),
	-- Phase 8: where towed cars are let go, just south of the tow yard's gate.
	thePlant("pl_tow_drop_1", "TowDrop", "County Tow Yard", v3(2855.5, 0, -452), 90, TOW_DROP, TOW_YARD),
	thePlant("pl_tow_drop_2", "TowDrop", "County Tow Yard", v3(2855.5, 0, -474), 90, TOW_DROP, TOW_YARD),
	-- Phase 8: breakdown spots on the north and south works roads.
	thePlant("pl_breakdown_north", "Breakdown", "North Works Road shoulder", v3(1960, 0, -751.5), 180, BREAKDOWN),
	thePlant("pl_breakdown_south", "Breakdown", "South Works Road shoulder", v3(1900, 0, 751.5), 0, BREAKDOWN),
	thePlant("pl_hotspot_gate", "RideshareHotspot", "Plant Gate", v3(1750, 0, -48), 180, HOTSPOT),
	-- Phase 7: the Plant's Wrap & Tint shop, on the works road east of the Design Studio, facing it.
	thePlant("pl_custom_shop", "CustomShop", "Plant Wrap & Tint", v3(2500, 0, 56), 0, CUSTOM_SHOP, nil, true),
	-- Mesa Test Site: drag-strip gates, the flight field, the no-fly zone round Mesa Control and
	-- its chargers, and the Mesa Summit meet spot on top of Big Mesa.
	mesaTestSite(
		"ms_drag_gate_1",
		"DragStripGate",
		"Drag Strip",
		v3(320, 0.2, -1500),
		-90,
		v3(64, 20, 4),
		{ index = 1 },
		true
	),
	mesaTestSite(
		"ms_drag_gate_2",
		"DragStripGate",
		"Drag Strip gate 2",
		v3(679, 0.2, -1500),
		-90,
		v3(64, 20, 4),
		{ index = 2 }
	),
	mesaTestSite(
		"ms_drag_gate_3",
		"DragStripGate",
		"Drag Strip gate 3",
		v3(1038, 0.2, -1500),
		-90,
		v3(64, 20, 4),
		{ index = 3 }
	),
	mesaTestSite(
		"ms_drag_gate_4",
		"DragStripGate",
		"Drag Strip gate 4",
		v3(1757, 0.2, -1500),
		-90,
		v3(64, 20, 4),
		{ index = 4 }
	),
	mesaTestSite("ms_flight_field", "FlightZone", "Flight Field", v3(2100, 0, -1890), 0, v3(1300, 160, 480), nil, true),
	mesaTestSite("ms_control_nofly", "NoFlyZone", "Mesa Control", v3(-250, 0, -1555), 0, v3(440, 300, 230)),
	mesaTestSite("ms_charger_1", "ChargerStall", "Mesa Control", v3(-250, 0, -1465), 0, STALL, MESA_CONTROL_250KW),
	mesaTestSite("ms_charger_2", "ChargerStall", "Mesa Control", v3(-264, 0, -1465), 0, STALL, MESA_CONTROL_250KW),
	mesaTestSite("ms_summit", "MeetSpot", "Mesa Summit", v3(1100, 30, -2443), 180, v3(80, 1, 50), nil, true),
	-- Phase 8: breakdown spots on the Ridge Road and the strip's return road.
	mesaTestSite("ms_breakdown_ridge", "Breakdown", "Ridge Road shoulder", v3(51.5, 0, -1950), 90, BREAKDOWN),
	mesaTestSite("ms_breakdown_return", "Breakdown", "Return Road shoulder", v3(610, 0, -1676.5), 180, BREAKDOWN),
	-- County Loop: the Loop Stop (fuel, chargers, a truck charger) on its service road.
	countyLoop("loop_fuel_1", "FuelPump", "Loop Stop", v3(3170, 0, 1660), -90, PUMP, FUEL_PUMP, true),
	countyLoop("loop_fuel_2", "FuelPump", "Loop Stop", v3(3170, 0, 1680), -90, PUMP, FUEL_PUMP),
	countyLoop("loop_fuel_3", "FuelPump", "Loop Stop", v3(3170, 0, 1700), -90, PUMP, FUEL_PUMP),
	countyLoop("loop_fuel_4", "FuelPump", "Loop Stop", v3(3170, 0, 1720), -90, PUMP, FUEL_PUMP),
	countyLoop("loop_charger_1", "ChargerStall", "Loop Stop", v3(3172, 0, 1800), -90, STALL, LOOP_STOP_350KW),
	countyLoop("loop_charger_2", "ChargerStall", "Loop Stop", v3(3172, 0, 1814), -90, STALL, LOOP_STOP_350KW),
	countyLoop("loop_charger_3", "ChargerStall", "Loop Stop", v3(3172, 0, 1828), -90, STALL, LOOP_STOP_350KW),
	countyLoop("loop_charger_4", "ChargerStall", "Loop Stop", v3(3172, 0, 1842), -90, STALL, LOOP_STOP_350KW),
	countyLoop(
		"loop_truck_charger",
		"TruckCharger",
		"Loop Stop",
		v3(3162, 0, 2000),
		-90,
		TRUCK_STALL,
		TRUCK_CHARGER_750KW
	),
	-- Phase 8: the Loop Stop's freight depot and trailer spots, across its service road from the pumps.
	countyLoop(
		"loop_freight_depot",
		"JobDepot",
		"Loop Stop Freight",
		v3(3235.5, 0, 1780),
		90,
		FREIGHT_DEPOT,
		FREIGHT,
		true
	),
	countyLoop(
		"loop_trailer_1",
		"TrailerSpawn",
		"Loop Stop Freight",
		v3(3226.5, 0, 1854),
		90,
		TRAILER_SPOT,
		trailerSpot("loop_freight_depot", "box_trailer")
	),
	countyLoop(
		"loop_trailer_2",
		"TrailerSpawn",
		"Loop Stop Freight",
		v3(3226.5, 0, 1920),
		90,
		TRAILER_SPOT,
		trailerSpot("loop_freight_depot", "tanker_trailer")
	),
	countyLoop(
		"loop_trailer_3",
		"TrailerSpawn",
		"Loop Stop Freight",
		v3(3226.5, 0, 1986),
		90,
		TRAILER_SPOT,
		trailerSpot("loop_freight_depot", "flatbed_trailer")
	),
	-- Phase 8: the West Loop freight yard on the far side of the ring, inside the west interchange beside its
	-- north ramp (facing it, so it turns with the ramp: yaw -43.2).
	countyLoop(
		"west_freight_depot",
		"JobDepot",
		"West Loop Freight Yard",
		v3(-3323.5, 0, -179.6),
		-43.2,
		FREIGHT_DEPOT,
		FREIGHT,
		true
	),
	countyLoop(
		"west_trailer_1",
		"TrailerSpawn",
		"West Loop Freight Yard",
		v3(-3167.1, 0, -45.3),
		-43.2,
		TRAILER_SPOT,
		trailerSpot("west_freight_depot", "box_trailer")
	),
	countyLoop(
		"west_trailer_2",
		"TrailerSpawn",
		"West Loop Freight Yard",
		v3(-3215.2, 0, -90.4),
		-43.2,
		TRAILER_SPOT,
		trailerSpot("west_freight_depot", "flatbed_trailer")
	),
	countyLoop(
		"west_trailer_3",
		"TrailerSpawn",
		"West Loop Freight Yard",
		v3(-3263.4, 0, -135.6),
		-43.2,
		TRAILER_SPOT,
		trailerSpot("west_freight_depot", "tanker_trailer")
	),
	-- Phase 8: breakdown spots on the inside shoulders of the ring's south and west sides.
	countyLoop("loop_breakdown_south", "Breakdown", "County Loop south shoulder", v3(-2100, 0, 3354.5), 180, BREAKDOWN),
	countyLoop("loop_breakdown_west", "Breakdown", "County Loop west shoulder", v3(-3354.5, 0, -900), 90, BREAKDOWN),
}

-- Lake bed and mesa shapes, for groundHeight below and for MapBuilder.
local lakes: { Lake } = {
	{
		id = "cedar_lake",
		displayName = "Cedar Lake",
		zone = "lakefront",
		min = Vector2.new(-900, 1800),
		max = Vector2.new(900, 2550),
		waterY = -2,
		-- The deepest the bay gets: the terrain seabed (Config/Water, Dev/WaterBuilder) shelves down to it offshore, and
		-- the bridge's piers stand on it.
		bedY = -24,
	},
}

local mesas: { Mesa } = {
	{
		id = "big_mesa",
		displayName = "Big Mesa",
		zone = "mesa_test_site",
		topMin = Vector2.new(650, -2550),
		topMax = Vector2.new(1250, -2250),
		height = 30,
		slope = 0.2,
	},
	{
		id = "twin_butte",
		displayName = "Twin Butte",
		zone = "mesa_test_site",
		topMin = Vector2.new(1850, -2550),
		topMax = Vector2.new(2250, -2250),
		height = 18,
		slope = 0.15,
	},
	{
		id = "coyote_ridge",
		displayName = "Coyote Ridge",
		zone = "mesa_test_site",
		topMin = Vector2.new(-600, -2500),
		topMax = Vector2.new(-300, -2300),
		height = 12,
		slope = 0.1,
	},
}

-- Grass hills at the edge of the map, outside the County Loop (its outer edge is 3,432 studs out; every foot stays
-- 450+ studs past it) and inside the map (every foot within 4,990 of the centre), none west of reservedWestOfX
-- (the dev track's ground). Each foot is its top grown by (height + 1) / slope; the slopes are gentle enough to
-- drive up.
local function hill(
	id: string,
	displayName: string,
	x0: number,
	x1: number,
	z0: number,
	z1: number,
	height: number,
	slope: number
): Mesa
	return {
		id = id,
		displayName = displayName,
		zone = "county_loop",
		topMin = Vector2.new(x0, z0),
		topMax = Vector2.new(x1, z1),
		height = height,
		slope = slope,
	}
end

local hills: { Mesa } = {
	hill("north_ridge_west", "North Ridge", -2400, -900, -4620, -4520, 45, 0.13),
	hill("north_ridge_east", "Cotton Ridge", 700, 2300, -4600, -4480, 55, 0.16),
	hill("east_ridge_north", "East Ridge", 4500, 4620, -2400, -1000, 50, 0.14),
	hill("east_ridge_south", "Pecan Ridge", 4420, 4560, 700, 2200, 70, 0.18),
	hill("south_ridge_west", "South Ridge", -2600, -800, 4520, 4620, 50, 0.14),
	hill("south_ridge_east", "Lake Ridge", 1200, 2800, 4480, 4600, 65, 0.17),
	hill("northeast_knob", "Signal Hill", 4300, 4500, -4500, -4300, 80, 0.2),
	hill("southeast_knob", "Bluebonnet Hill", 4270, 4500, 4270, 4500, 60, 0.16),
}

-- Parks. Town Square fills the downtown block north-west of Main Avenue and Commerce Avenue (cb_c3..cb_d4) out to the
-- sidewalks (a street's reaches 23 studs from its centre line, an arterial's 38); Lakefront Park rings Cedar Lake,
-- clear of Lakeshore Drive's lots, and its north band between the lake and the north shore road is a sand beach
-- (decision L3 of docs/city/CITY_PLAN.md: the same ground as before, split in two; every location stays put).
local parks: { Park } = {
	{
		id = "town_square",
		displayName = "Town Square",
		zone = "cedar_bend",
		min = Vector2.new(-277, -277),
		max = Vector2.new(-38, -38),
		groundColor = Color3.fromRGB(90, 128, 68),
		groundMaterial = Enum.Material.LeafyGrass,
	},
	{
		id = "lakefront_park",
		displayName = "Lakefront Park",
		zone = "lakefront",
		min = Vector2.new(-1050, 1800),
		max = Vector2.new(1050, 2700),
		hole = { min = lakes[1].min, max = lakes[1].max },
	},
	{
		id = "lakefront_beach",
		displayName = "Lakefront Beach",
		zone = "lakefront",
		min = Vector2.new(-1050, 1650),
		max = Vector2.new(1050, 1800),
		groundColor = Color3.fromRGB(232, 216, 178),
		groundMaterial = Enum.Material.Sand,
	},
}

-- Features (see Feature above). The water tower stands south of River Avenue in Riverside, 72 studs clear of its
-- sidewalk, seen from the avenue and Elm Street. The diner's site is just south of the Lakeview Overlook, between
-- it and Lakeshore Drive's east side (x = 1,150, its edge at 1,135): the site runs x 1,072..1,128, z 2,260..2,320.
-- The bridge's arches stand 3 studs outside its deck (half-width 27) over the water, their feet at the lake's
-- shores (z 1,800 and 2,550).
local features: { Feature } = {
	{
		id = "riverside_water_tower",
		displayName = "Riverside Water Tower",
		zone = "riverside",
		kind = "water_tower",
		position = v3(-1800, 0, 125),
		yaw = 0,
		size = v3(30, 112, 30),
	},
	{
		id = "overlook_diner",
		displayName = "Overlook Diner",
		zone = "lakefront",
		kind = "diner",
		position = v3(1100, 0, 2290),
		yaw = -90,
		size = v3(60, 13, 56),
		sign = "DINER",
	},
	{
		id = "cedar_lake_bridge_arches",
		displayName = "Cedar Lake Bridge",
		zone = "lakefront",
		kind = "bridge_arch",
		position = v3(0, 20.2, 2175),
		yaw = 0,
		size = v3(60, 90, 750),
	},
}

-- Display pads. The dealership is an auto mall on both sides of the street south of Cedar Bend Motors (row 6,
-- z = 600, between columns f and g): Ohm Motors in one row behind the showroom facing that street, and the other
-- seven brands across it, filling the block between x = 600..900 and z = 600..900 (MapBuilder clears its
-- buildings), in four rows facing north. The used lot's numbered spaces stand in a row behind its office, facing
-- it. Every pad sits inside its block, clear of the streets' sidewalks (a street's sidewalk reaches 23 studs from
-- its centre line).
local DISPLAY_PAD = v3(16, 0.4, 28) -- room for the longest catalog body (a semi tractor) with space round it
local PAD_PITCH = 19 -- studs between neighbouring pad centres in a row (a 3-stud gap)

-- `count` pads in a row along X, centred on (centreX, z), every one facing `yaw`. Pad 1 is the westmost.
local function padRow(count: number, centreX: number, z: number, yaw: number): { CFrame }
	local pads: { CFrame } = {}
	local first = centreX - PAD_PITCH * (count - 1) / 2
	for i = 1, count do
		table.insert(pads, CFrame.new(first + PAD_PITCH * (i - 1), 0, z) * CFrame.Angles(0, math.rad(yaw), 0))
	end
	return pads
end

local function section(brandId: string, count: number, centreX: number, z: number, yaw: number): DealershipSection
	return { brandId = brandId, pads = padRow(count, centreX, z, yaw) }
end

-- The mall block's two sections per row: six pads each (a 111-stud row), 20 studs apart, together centred on
-- x = 750. Rows run 60 studs apart, leaving a 32-stud aisle between them.
local MALL_WEST, MALL_EAST, MALL_CENTRE = 684.5, 815.5, 750
local MALL_ROWS = { 652, 712, 772, 832 }

local dealership: DealershipLayout = {
	padSize = DISPLAY_PAD,
	sections = {
		-- Ohm Motors, the hero brand: eight pads behind the showroom (its back wall is at z = 480), facing south.
		section("ohm", 8, MALL_CENTRE, 530, 180),
		-- Across the street: the everyday and tuner brands nearest the showroom, the work fleet at the back.
		section("halden", 6, MALL_WEST, MALL_ROWS[1], 0),
		section("kaze", 6, MALL_EAST, MALL_ROWS[1], 0),
		section("ironwood", 6, MALL_WEST, MALL_ROWS[2], 0),
		section("aldermoor", 6, MALL_EAST, MALL_ROWS[2], 0),
		section("brannock", 6, MALL_WEST, MALL_ROWS[3], 0),
		section("montevale", 6, MALL_EAST, MALL_ROWS[3], 0),
		section("northline", 6, MALL_CENTRE, MALL_ROWS[4], 0),
	},
}

-- Ten numbered spaces behind the used-lot office (its back wall is at z = 415), facing north toward it.
local usedLot: UsedLotLayout = {
	padSize = DISPLAY_PAD,
	pads = padRow(10, 450, 454, 0),
}

-- Billboards (Phase 12). Every panel is 28 x 15.75 studs (16:9, inside Roblox's 8 x 4.5 to 32 x 18 ad limits).
-- County Loop: two per side of the ring, on its straight stretches, inside the ring and square to the highway so
-- one direction of traffic sees the ad face and the other the poster: the panel's near end stands 8 studs past the
-- carriageway's edge (the highway is 64 studs wide, so its edge is 32 from the centre line at ±3,400), which puts
-- the panel's centre 32 + 8 + 14 = 54 studs in from the centre line. Each side's pair faces opposite ways. They keep
-- well away from the interchanges (±300 and the ramps inside them), the corners (from ±2,700), the Loop Stop and the
-- breakdown shoulders. The charging plazas: one behind the Cedar Bend plaza's stalls, facing the street they face,
-- and one behind the Loop Stop's chargers, facing its service road; each stands 18 to 20 studs behind the stalls'
-- back edge, clear of their charger posts and of the 10-stud margin MapBuilder keeps round every pad.
local BILLBOARD = v3(28, 15.75, 1)
local HIGHWAY_CLEARANCE = 12 -- studs from the ground to a highway panel's bottom edge
local PLAZA_CLEARANCE = 10 -- a plaza panel stands lower; people walk under it
local LOOP_IN = 3400 - 54 -- the panels' centre line inside the ring (see above)

local function billboard(
	id: string,
	zone: string,
	x: number,
	z: number,
	yaw: number,
	clearance: number,
	brandId: string
): Billboard
	return {
		id = id,
		zone = zone,
		position = v3(x, 0, z),
		yaw = yaw,
		size = BILLBOARD,
		clearance = clearance,
		brandId = brandId,
	}
end

local billboards: { Billboard } = {
	-- South side (z = 3400): square to the road, so their faces look east or west along it.
	billboard("bb_loop_south_1", "county_loop", -1200, LOOP_IN, 90, HIGHWAY_CLEARANCE, "halden"),
	billboard("bb_loop_south_2", "county_loop", 1500, LOOP_IN, -90, HIGHWAY_CLEARANCE, "kaze"),
	-- North side (z = -3400).
	billboard("bb_loop_north_1", "county_loop", -1500, -LOOP_IN, 90, HIGHWAY_CLEARANCE, "ironwood"),
	billboard("bb_loop_north_2", "county_loop", 1200, -LOOP_IN, -90, HIGHWAY_CLEARANCE, "montevale"),
	-- West side (x = -3400): faces look north or south along it.
	billboard("bb_loop_west_1", "county_loop", -LOOP_IN, -1800, 0, HIGHWAY_CLEARANCE, "aldermoor"),
	billboard("bb_loop_west_2", "county_loop", -LOOP_IN, 1500, 180, HIGHWAY_CLEARANCE, "brannock"),
	-- East side (x = 3400), north of the Loop Stop.
	billboard("bb_loop_east_1", "county_loop", LOOP_IN, -1500, 0, HIGHWAY_CLEARANCE, "northline"),
	billboard("bb_loop_east_2", "county_loop", LOOP_IN, 900, 180, HIGHWAY_CLEARANCE, "ohm"),
	-- The Cedar Bend charging plaza: behind stalls cb_charger_1..6 (x 329..411, back edge z = 255), facing south to
	-- the street.
	billboard("bb_cedar_plaza", "cedar_bend", 370, 255 - 20, 180, PLAZA_CLEARANCE, "ohm"),
	-- The Loop Stop: behind chargers loop_charger_1..4 (z 1794..1848, back edge x = 3162), facing east to the
	-- service road.
	billboard("bb_loop_stop", "county_loop", 3162 - 18, 1821, -90, PLAZA_CLEARANCE, "ironwood"),
}

-- Top of the ground at (x, z): the lake bed in a lake, the mesa or hill surface on a mesa or hill, 0 elsewhere.
local function groundHeight(x: number, z: number): number
	for _, lake in lakes do
		if x >= lake.min.X and x <= lake.max.X and z >= lake.min.Y and z <= lake.max.Y then
			return lake.bedY
		end
	end
	local height = 0
	for _, list in { mesas, hills } do
		for _, mesa in list do
			-- How far outside the flat top, along X and along Z (0 on the top).
			local dx = math.max(mesa.topMin.X - x, 0, x - mesa.topMax.X)
			local dz = math.max(mesa.topMin.Y - z, 0, z - mesa.topMax.Y)
			height = math.max(height, mesa.height - mesa.slope * math.max(dx, dz))
		end
	end
	return height
end

local MapLayout: MapLayout = {
	seed = 1887, -- for deterministic building placement
	zones = zones,
	zoneOrder = { "cedar_bend", "riverside", "the_plant", "mesa_test_site", "lakefront", "county_loop" },
	locations = locations,
	-- SpawnLocations at the used lot, on the ground behind its spawn pads, facing the street (north).
	playerSpawns = {
		CFrame.new(424, 0, 362),
		CFrame.new(448, 0, 362),
		CFrame.new(472, 0, 362),
		CFrame.new(496, 0, 362),
	},
	lakes = lakes,
	mesas = mesas,
	hills = hills,
	parks = parks,
	features = features,
	-- Jump ramps on the Mesa: three in the flight field, one on top of Big Mesa.
	jumpRamps = {
		{ id = "ms_ramp_1", zone = "mesa_test_site", position = v3(1650, 0, -1900), yaw = 0, size = v3(30, 8, 60) },
		{ id = "ms_ramp_2", zone = "mesa_test_site", position = v3(1850, 0, -1790), yaw = 90, size = v3(30, 6, 50) },
		{ id = "ms_ramp_3", zone = "mesa_test_site", position = v3(2400, 0, -1900), yaw = 0, size = v3(40, 10, 80) },
		{ id = "ms_ramp_4", zone = "mesa_test_site", position = v3(800, 30, -2320), yaw = 0, size = v3(30, 6, 50) },
	},
	landmarks = {
		{
			id = "dealership_showroom",
			displayName = "Cedar Bend Motors",
			zone = "cedar_bend",
			kind = "showroom",
			position = v3(750, 0, 430),
			yaw = 0,
			size = v3(140, 30, 100),
		},
		{
			id = "used_lot_office",
			displayName = "Used Lot",
			zone = "cedar_bend",
			kind = "office",
			position = v3(460, 0, 400),
			yaw = 0,
			size = v3(60, 14, 30),
		},
		{
			id = "ohm_factory",
			displayName = "Ohm Motors Plant",
			zone = "the_plant",
			kind = "factory",
			position = v3(2200, 0, -350),
			yaw = 0,
			size = v3(900, 60, 450),
			signBrand = "ohm",
		},
		{
			id = "design_studio",
			displayName = "Design Studio",
			zone = "the_plant",
			kind = "studio",
			position = v3(1900, 0, 250),
			yaw = 0,
			size = v3(300, 40, 250),
		},
		{
			id = "freight_warehouse",
			displayName = "Freight Depot",
			zone = "the_plant",
			kind = "warehouse",
			position = v3(2515, 0, 330),
			yaw = 90,
			size = v3(360, 36, 330),
		},
		{
			id = "tow_yard_shop",
			displayName = "County Tow Yard",
			zone = "the_plant",
			kind = "garage",
			position = v3(2960, 0, -400),
			yaw = -90,
			size = v3(120, 24, 100),
		},
		{
			id = "mesa_control",
			displayName = "Mesa Control",
			zone = "mesa_test_site",
			kind = "control_tower",
			position = v3(-240, 0, -1590),
			yaw = 0,
			size = v3(300, 24, 80),
		},
	},
	dealership = dealership,
	usedLot = usedLot,
	billboards = billboards,
	-- The dev test track's ground (Config/DevTrack): nothing of the county but the County Loop west of this x.
	reservedWestOfX = -3700,
	-- Pads stay at least this many studs clear of every road and its sidewalks.
	padClearance = 1,
	groundHeight = groundHeight,
}

return MapLayout
