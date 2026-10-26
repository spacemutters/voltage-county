--!strict
-- How the county looks beyond its roads (docs/roast-2026-10-24.md, point 3: "the county is still a grey block-out"):
--   dayNight     the day/night cycle Services/DayNightService runs: how long a day lasts, how much of it is night,
--                when a new server starts, and the sky's colours through the day (Lighting and its Atmosphere)
--   nightLights  the lamps the server switches at dusk and dawn: parts tagged `tag` (Dev/MapBuilder tags the
--                streetlight heads, lit windows, the diner's neon, the water tower's beacon, the bridge arches and
--                the Ohm sign's light bar), each with its kind and its day colour as attributes; the looks per kind
--   budget       how many parts Dev/MapBuilder may build, and why (tests/MapBuilder.spec holds the map to them)
--   ground       the patchwork tile size of the open land and the grass shades of the hills (zones' own ground
--                colours, materials and shades are in Config/MapLayout, next to their bounds)
--   trees        how many trees, where and how thick (Dev/MapBuilder plants them; their shapes are in its TUNING)
--   facades      windows and roof edges per zone: floor height, glass tints, how many windows light up at night
-- The pure maths (the clock, the night line, the sky colours, a night light's look) is in Services/DayNightService,
-- checked by tests/DayNight.spec.

-- The sky at one time of day. DayNightService blends the two keyframes either side of the clock.
export type Keyframe = {
	clock: number, -- Lighting.ClockTime, hours 0..24
	ambient: Color3, -- Lighting.Ambient
	outdoorAmbient: Color3, -- Lighting.OutdoorAmbient
	fogColor: Color3, -- Lighting.FogColor (an Atmosphere overrides fog; kept for a place without one)
	atmosphereColor: Color3, -- Atmosphere.Color
	atmosphereDecay: Color3, -- Atmosphere.Decay
	brightness: number, -- Lighting.Brightness
}

-- The shape of a day: what DayNightService's clock maths reads (tests/DayNight.spec also passes its own).
export type Cycle = {
	dayLengthMinutes: number, -- a full day, dawn to dawn, in real minutes
	nightShare: number, -- 0..1: the share of it from dusk to dawn
	duskClock: number, -- hours
	dawnClock: number, -- hours
}

-- How one kind of night light looks: by day its own colour (the part's DayColor attribute) in dayMaterial; at night
-- nightColor in nightMaterial, with any Light inside it switched on.
export type NightLook = { dayMaterial: Enum.Material, nightMaterial: Enum.Material, nightColor: Color3 }

-- One zone's facades (Dev/MapBuilder): glass ribbons per floor under floor bands and a roof edge, or from towerFrom
-- studs up a glass tower with corner piers. floorHeight studs per floor (fewer, taller floors past maxFloors);
-- windowShare of each floor is glass; litShare of the buildings have a run of floors whose windows glow at night;
-- rooftopShare of those at least rooftopFrom tall carry a plant box on the roof. Glass in one of `tints`, the bands
-- in the zone's building colour and one of `materials`.
export type Facade = {
	floorHeight: number,
	maxFloors: number,
	towerFrom: number?,
	windowShare: number,
	litShare: number,
	rooftopShare: number,
	rooftopFrom: number,
	tints: { Color3 },
	materials: { Enum.Material },
}

-- Trees in one zone, in groves: the zone is cut in `cell`-stud squares, and each gets a grove with this chance
-- (outskirtsChance past trees.outskirtsFrom on either axis), of trees[1]..trees[2] trees within radius[1]..radius[2]
-- studs of a point in the cell, of the `species` mix.
export type Grove = {
	zone: string,
	cell: number,
	chance: number,
	outskirtsChance: number?,
	trees: { number },
	radius: { number },
	species: string,
}

-- One species' share of a mix.
export type Mix = { species: string, weight: number }

local rgb = Color3.fromRGB

local function mix(species: string, weight: number): Mix
	return { species = species, weight = weight }
end

-- The sky by day, the same from mid-morning to late afternoon. The fill light is kept low so the sun, the shadows and
-- the sky's reflections give the shapes their edges (2026-10-25: a brighter fill washed every model flat).
local DAY: Keyframe = {
	clock = 0,
	ambient = rgb(56, 60, 70),
	outdoorAmbient = rgb(112, 116, 126),
	fogColor = rgb(192, 208, 224),
	atmosphereColor = rgb(199, 210, 224),
	atmosphereDecay = rgb(106, 112, 125),
	brightness = 2.6,
}

-- The sky by night: dark blue, but enough light that a road and a car still read on a phone.
local NIGHT: Keyframe = {
	clock = 0,
	ambient = rgb(30, 34, 52),
	outdoorAmbient = rgb(58, 66, 96),
	fogColor = rgb(22, 26, 42),
	atmosphereColor = rgb(54, 62, 90),
	atmosphereDecay = rgb(32, 38, 62),
	brightness = 1.4,
}

local function at(clock: number, look: Keyframe): Keyframe
	local copy = table.clone(look)
	copy.clock = clock
	return copy
end

local Environment = {
	dayNight = {
		-- One full day, dawn to dawn, in real minutes.
		dayLengthMinutes = 24,
		-- Of those minutes, the share between dusk and dawn (8 of 24): long enough for a light show under the
		-- streetlights, short enough that most of a session is daylight.
		nightShare = 1 / 3,
		-- Lighting.ClockTime (hours) when night starts and ends. Streetlights and lit windows come on at dusk and go
		-- off at dawn (the same line Config/Customization's underglow uses).
		duskClock = 18,
		dawnClock = 6.5,
		-- A new server opens in the morning, so a first session starts in daylight.
		startClock = 9,
		-- The server moves the clock this often (seconds). By day the sun moves about 0.4 game minutes a step.
		stepSeconds = 0.5,
		-- The sky through the day, in clock order (0 <= clock < 24). Between two keyframes the colours blend; after the
		-- last they blend round midnight into the first.
		keyframes = {
			at(0, NIGHT),
			at(4.75, NIGHT),
			{
				clock = 5.75,
				ambient = rgb(58, 54, 76),
				outdoorAmbient = rgb(92, 86, 112),
				fogColor = rgb(96, 88, 116),
				atmosphereColor = rgb(126, 114, 142),
				atmosphereDecay = rgb(74, 66, 100),
				brightness = 1.6,
			},
			{
				-- Dawn: warm and low.
				clock = 6.75,
				ambient = rgb(76, 66, 64),
				outdoorAmbient = rgb(140, 116, 104),
				fogColor = rgb(216, 170, 142),
				atmosphereColor = rgb(228, 184, 156),
				atmosphereDecay = rgb(196, 128, 104),
				brightness = 2.1,
			},
			at(8.5, DAY),
			at(16.25, DAY),
			{
				-- Golden hour.
				clock = 17.5,
				ambient = rgb(78, 66, 62),
				outdoorAmbient = rgb(150, 120, 102),
				fogColor = rgb(228, 172, 134),
				atmosphereColor = rgb(236, 182, 148),
				atmosphereDecay = rgb(204, 122, 98),
				brightness = 2.3,
			},
			{
				-- Dusk.
				clock = 18.75,
				ambient = rgb(64, 56, 82),
				outdoorAmbient = rgb(98, 84, 118),
				fogColor = rgb(92, 72, 106),
				atmosphereColor = rgb(132, 102, 140),
				atmosphereDecay = rgb(82, 60, 104),
				brightness = 1.7,
			},
			at(20, NIGHT),
		} :: { Keyframe },
		-- Lighting gets an Atmosphere named `name` with these values when it has none (one already there is driven as
		-- it is: only its Color and Decay follow the clock).
		atmosphere = {
			name = "DayNightAtmosphere",
			density = 0.3,
			offset = 0.25,
			glare = 0,
			haze = 1,
		},
		-- Set once when the server starts (DayNightService). The place had shadows off and no sky reflections, which
		-- made every model read flat and soft (2026-10-25). Lighting.Technology isn't scriptable: it is set to Future
		-- by hand in Studio (docs/LAUNCH.md step 10).
		scene = {
			globalShadows = true,
			shadowSoftness = 0.15, -- 0 = razor-sharp, 1 = blurry
			environmentSpecularScale = 1, -- sky reflections on paint, glass and metal
			environmentDiffuseScale = 1, -- light from the sky itself
			exposureCompensation = 0,
			-- Effects made under Lighting when missing (one already there with the same name is set to these values).
			colorCorrection = {
				name = "SceneColor",
				contrast = 0.1,
				saturation = 0.12,
				brightness = 0,
				tintColor = rgb(255, 250, 244),
			},
			sunRays = { name = "SceneSunRays", intensity = 0.04, spread = 0.8 },
		},
	},

	nightLights = {
		tag = "NightLight", -- CollectionService tag on every part the server switches
		kindAttribute = "NightKind", -- string: a key of `kinds`
		dayColorAttribute = "DayColor", -- Color3: the part's colour by day (set when missing, the first night)
		-- On Lighting: true from dusk to dawn, false by day (for client effects that follow the night).
		nightAttribute = "IsNight",
		-- Studio only: set this number attribute on Lighting (hours, 0..24) to jump the clock there.
		devClockAttribute = "DevClockTime",
		-- Parts switched per frame at dusk and dawn, so the lights come on across the county over a few frames.
		flipPerStep = 200,
		kinds = {
			streetlight = {
				dayMaterial = Enum.Material.SmoothPlastic,
				nightMaterial = Enum.Material.Neon,
				nightColor = rgb(255, 214, 150),
			},
			window = {
				dayMaterial = Enum.Material.Glass,
				nightMaterial = Enum.Material.Neon,
				-- A dim warm glow: Neon's brightness follows its colour, and a brighter colour turned whole floors into
				-- flat yellow slabs (seen 2026-10-24).
				nightColor = rgb(118, 90, 54),
			},
			sign = {
				dayMaterial = Enum.Material.SmoothPlastic,
				nightMaterial = Enum.Material.Neon,
				nightColor = rgb(96, 226, 236),
			},
			floodlight = {
				dayMaterial = Enum.Material.SmoothPlastic,
				nightMaterial = Enum.Material.Neon,
				nightColor = rgb(236, 240, 255),
			},
			beacon = {
				dayMaterial = Enum.Material.SmoothPlastic,
				nightMaterial = Enum.Material.Neon,
				nightColor = rgb(255, 64, 52),
			},
			arch = {
				dayMaterial = Enum.Material.Metal,
				nightMaterial = Enum.Material.Neon,
				nightColor = rgb(196, 222, 255),
			},
			-- The Miami city's neon (docs/city/CITY_PLAN.md §7.1, colours tested in docs/city/SCENERY.md §8). By day
			-- each is its part's own colour in SmoothPlastic, a pastel moulding; at night a saturated tube. Never white
			-- Neon: it blows out.
			neonPink = {
				dayMaterial = Enum.Material.SmoothPlastic,
				nightMaterial = Enum.Material.Neon,
				nightColor = rgb(255, 90, 170),
			},
			neonViolet = {
				dayMaterial = Enum.Material.SmoothPlastic,
				nightMaterial = Enum.Material.Neon,
				nightColor = rgb(170, 90, 255),
			},
			neonAmber = {
				dayMaterial = Enum.Material.SmoothPlastic,
				nightMaterial = Enum.Material.Neon,
				nightColor = rgb(255, 170, 60),
			},
			neonBlue = {
				dayMaterial = Enum.Material.SmoothPlastic,
				nightMaterial = Enum.Material.Neon,
				nightColor = rgb(61, 123, 255),
			},
			-- Tower crowns and lanterns: a cool white that stays under the blow-out.
			crown = {
				dayMaterial = Enum.Material.SmoothPlastic,
				nightMaterial = Enum.Material.Neon,
				nightColor = rgb(170, 200, 236),
			},
			-- LED strips on balcony and podium edges.
			ledBlue = {
				dayMaterial = Enum.Material.SmoothPlastic,
				nightMaterial = Enum.Material.Neon,
				nightColor = rgb(60, 130, 255),
			},
			-- A facade wash: a small fixture part whose SurfaceLight lights the wall above it at night.
			uplight = {
				dayMaterial = Enum.Material.SmoothPlastic,
				nightMaterial = Enum.Material.Neon,
				nightColor = rgb(255, 196, 150),
			},
		} :: { [string]: NightLook },
	},

	-- Parts Dev/MapBuilder may build (tests/MapBuilder.spec). Why these numbers: the phase 14 perf drive measured 7,493
	-- server parts (the map, houses, cars and traffic) at a steady 60 fps on desktop (client mean 16.67 ms, p95 18.27 ms)
	-- with 5,100 to 5,550 of them streamed in on the client. Everything this pass adds is anchored and still: no physics
	-- body, and leaves, glass bands, trim and the features never collide, take a raycast or a touch (tree trunks and
	-- building shells do, like any wall). Trees, buildings and features sit in Atomic tiles that stream (only Ground
	-- and Roads are Persistent), so a phone holds what lies inside the 2,048-stud streaming target radius (about 13 % of
	-- the map) and drops the far tiles first when short of memory. Leaves and trunks are plain blocks (12 triangles),
	-- not balls. mapParts is about twice the measured count; the perf drive and Davis's real-phone check decide
	-- whether it holds (Config/Perf), and these numbers are the lever if it doesn't.
	budget = {
		mapParts = 16000, -- the whole of Workspace.Map.Generated
		treeParts = 4800, -- trunks and leaves: about 1,750 trees at 2 or 3 parts each
		-- glass, floor bands, roof edges, corner piers and roof boxes of about 620 buildings: measured 5,496 on
		-- 2026-10-24 after capping downtown at 4 floor bands (the whole map stays under mapParts). 2026-10-25: the Miami
		-- city's first two archetypes (Dev/City: standard glass towers and Deco hotels, 45 to 66 parts each, budgets in
		-- Config/City) stand on about 15 of those plots: measured 5,782. Room is left for a little more; the full city
		-- needs the bigger budgets docs/city/CITY_PLAN.md §9 proposes (the lead's decision L4, after a perf drive).
		buildingParts = 6400,
		featureParts = 200, -- the water tower, the diner and the bridge arches
		groundParts = 700, -- the ground patchwork, lake beds and banks, mesas and hills
	},

	ground = {
		-- The open land and the green zones are cut in tiles this many studs square, each in one of the zone's shades
		-- (Config/MapLayout groundShades), so a field never reads as one flat colour.
		tile = 1000,
		-- The hills at the edge of the map (Config/MapLayout hills), one shade each.
		hillShades = {
			{ color = rgb(100, 130, 74), material = Enum.Material.Grass },
			{ color = rgb(92, 122, 70), material = Enum.Material.LeafyGrass },
			{ color = rgb(112, 136, 80), material = Enum.Material.Grass },
		},
	},

	trees = {
		-- How many trees, at most and at least (tests/MapBuilder.spec). Past maxTrees or budget.treeParts the builder
		-- stops planting, so a denser setting never breaks the budget: it fills the parks and towns first and the open
		-- country last.
		maxTrees = 1800,
		minTrees = 1200,
		-- Groves keyed by this zone also cover the open land outside every zone.
		countryZone = "county_loop",
		-- Past this many studs from the centre on either axis (outside the County Loop) a grove is an outskirts grove.
		outskirtsFrom = 3500,
		-- A trunk stands at least this far from a road's edge or its sidewalk (a car on the shoulder never meets one)...
		roadClearance = 16,
		-- ...or this far in a park, where trees line the paths.
		parkRoadClearance = 3,
		-- Trunks at least this far apart.
		spacing = 9,
		-- Leaves stay this far inside the map's edge.
		edgeMargin = 20,
		-- A grove's centre is at least this far from a road's edge.
		groveRoadClearance = 40,
		-- Parks (Config/MapLayout parks): each `cell`-stud square holds a tree with this chance.
		parks = {
			default = { cell = 26, chance = 0.55 },
			lakefront_park = { cell = 30, chance = 0.22 },
		} :: { [string]: { cell: number, chance: number } },
		-- Groves, planted in this order (the outskirts last, so a cap trims them first).
		groves = {
			{
				zone = "riverside",
				cell = 260,
				chance = 0.55,
				trees = { 2, 6 },
				radius = { 25, 55 },
				species = "town",
			},
			{
				zone = "lakefront",
				cell = 300,
				chance = 0.45,
				trees = { 3, 7 },
				radius = { 30, 70 },
				species = "town",
			},
			{
				zone = "the_plant",
				cell = 420,
				chance = 0.3,
				trees = { 2, 5 },
				radius = { 25, 50 },
				species = "town",
			},
			{
				zone = "county_loop",
				cell = 420,
				chance = 0.5,
				outskirtsChance = 0.68,
				trees = { 4, 9 },
				radius = { 50, 120 },
				species = "country",
			},
		} :: { Grove },
		-- Species mixes (Dev/MapBuilder TUNING.treeSpecies names) in a fixed order; weights add up to 1. The outskirts
		-- lean to pines.
		mixes = {
			park = { mix("broadleaf", 0.5), mix("round", 0.3), mix("poplar", 0.2) },
			town = { mix("broadleaf", 0.4), mix("round", 0.3), mix("poplar", 0.2), mix("pine", 0.1) },
			country = { mix("broadleaf", 0.45), mix("round", 0.2), mix("pine", 0.25), mix("poplar", 0.1) },
			outskirts = { mix("broadleaf", 0.3), mix("round", 0.1), mix("pine", 0.5), mix("poplar", 0.1) },
		} :: { [string]: { Mix } },
		-- Each tree is drawn between these sizes (1 = the TUNING shape).
		scale = { 0.8, 1.3 },
		leafColors = { rgb(70, 110, 56), rgb(82, 126, 60), rgb(96, 134, 64), rgb(62, 96, 54), rgb(110, 138, 62) },
		pineColors = { rgb(46, 84, 56), rgb(54, 94, 62), rgb(40, 74, 52) },
		trunkColors = { rgb(96, 74, 56), rgb(110, 86, 64), rgb(84, 66, 52) },
	},

	-- By zone id (Config/MapLayout zones); a zone without one keeps plain block buildings.
	facades = {
		cedar_bend = {
			floorHeight = 12,
			maxFloors = 4,
			towerFrom = 76, -- taller than 76 studs: a glass tower
			windowShare = 0.55,
			litShare = 0.55,
			rooftopShare = 0.35,
			rooftopFrom = 50,
			tints = { rgb(58, 72, 88), rgb(64, 86, 92), rgb(88, 78, 64), rgb(70, 74, 80), rgb(92, 116, 136) },
			materials = { Enum.Material.SmoothPlastic, Enum.Material.Concrete, Enum.Material.Brick },
		},
		riverside = {
			floorHeight = 11,
			maxFloors = 2,
			windowShare = 0.5,
			litShare = 0.6,
			rooftopShare = 0,
			rooftopFrom = 50,
			tints = { rgb(70, 86, 98), rgb(82, 92, 96), rgb(96, 110, 120) },
			materials = { Enum.Material.SmoothPlastic, Enum.Material.Brick, Enum.Material.WoodPlanks },
		},
		lakefront = {
			floorHeight = 11,
			maxFloors = 3,
			windowShare = 0.55,
			litShare = 0.6,
			rooftopShare = 0.2,
			rooftopFrom = 30,
			tints = { rgb(70, 98, 112), rgb(84, 112, 124), rgb(64, 80, 92) },
			materials = { Enum.Material.SmoothPlastic, Enum.Material.Concrete },
		},
		the_plant = {
			floorHeight = 18,
			maxFloors = 3,
			windowShare = 0.4,
			litShare = 0.3,
			rooftopShare = 0.3,
			rooftopFrom = 30,
			tints = { rgb(76, 84, 92), rgb(88, 96, 104) },
			materials = { Enum.Material.Concrete, Enum.Material.Metal, Enum.Material.DiamondPlate },
		},
		mesa_test_site = {
			floorHeight = 10,
			maxFloors = 2,
			windowShare = 0.45,
			litShare = 0.4,
			rooftopShare = 0,
			rooftopFrom = 50,
			tints = { rgb(80, 86, 90) },
			materials = { Enum.Material.Concrete },
		},
	} :: { [string]: Facade },
}

return Environment
