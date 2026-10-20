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
-- tests/RoadGraph.spec checks the locations, lake, mesas, ramps and landmarks against the road graph.

export type Zone = {
	id: string,
	displayName: string,
	min: Vector2, -- X and Z bounds of the zone on the ground
	max: Vector2,
	groundColor: Color3,
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

export type MapLayout = {
	seed: number,
	zones: { [string]: Zone },
	zoneOrder: { string },
	locations: { Location },
	playerSpawns: { CFrame },
	lakes: { Lake },
	mesas: { Mesa },
	jumpRamps: { JumpRamp },
	landmarks: { Landmark },
	dealership: DealershipLayout,
	usedLot: UsedLotLayout,
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
		groundColor = Color3.fromRGB(132, 128, 118),
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
		groundColor = Color3.fromRGB(112, 138, 90),
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
		groundColor = Color3.fromRGB(122, 150, 96),
		buildingColors = {
			Color3.fromRGB(220, 214, 200),
			Color3.fromRGB(176, 196, 206),
			Color3.fromRGB(196, 178, 150),
		},
		buildingHeight = { min = 12, max = 40 },
		buildingDensity = 0.2,
	},
	-- The ring highway. Its bounds are the ring's outer box and its ground colour is the open
	-- country between the zones; Graph.zoneAt finds it by road (highway and ramp edges), not by bounds.
	county_loop = {
		id = "county_loop",
		displayName = "County Loop",
		min = Vector2.new(-3450, -3450),
		max = Vector2.new(3450, 3450),
		groundColor = Color3.fromRGB(152, 148, 104),
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
		bedY = -12,
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

-- Top of the ground at (x, z): the lake bed in a lake, the mesa surface on a mesa, 0 elsewhere.
local function groundHeight(x: number, z: number): number
	for _, lake in lakes do
		if x >= lake.min.X and x <= lake.max.X and z >= lake.min.Y and z <= lake.max.Y then
			return lake.bedY
		end
	end
	local height = 0
	for _, mesa in mesas do
		-- How far outside the flat top, along X and along Z (0 on the top).
		local dx = math.max(mesa.topMin.X - x, 0, x - mesa.topMax.X)
		local dz = math.max(mesa.topMin.Y - z, 0, z - mesa.topMax.Y)
		height = math.max(height, mesa.height - mesa.slope * math.max(dx, dz))
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
	-- The dev test track's ground (Config/DevTrack): nothing of the county but the County Loop west of this x.
	reservedWestOfX = -3700,
	-- Pads stay at least this many studs clear of every road and its sidewalks.
	padClearance = 1,
	groundHeight = groundHeight,
}

return MapLayout
