--!strict
-- How the county looks beyond its roads (docs/roast-2026-10-24.md, point 3: "the county is still a grey block-out"):
--   dayNight     the day/night cycle Services/DayNightService runs: how long a day lasts, how much of it is night,
--                when a new server starts, the sky's colours through the day (Lighting, its Atmosphere and its bloom),
--                and the scene switches set once at server start (lighting style, tone mapper, shadows, latitude: the
--                subtropical beach-city look of docs/city/TECH.md §1 and docs/city/SCENERY.md §9)
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
	-- Lighting.ColorShift_Top: a tint added to the light on faces turned to the sun or moon (black = none). Kept small:
	-- it adds to the sun, so a strong one washes white walls out.
	colorShiftTop: Color3,
	exposure: number, -- Lighting.ExposureCompensation (-5..5, 0 = none), before the tone mapper
	-- The bloom effect (dayNight.scene.bloom): how strongly bright colours glow, and how bright a colour must be to glow.
	-- A high threshold by day keeps white stucco from glowing; a lower one at night lets neon and crowns halo.
	bloomIntensity: number,
	bloomThreshold: number,
}

-- The shape of a day: what DayNightService's clock maths reads (tests/DayNight.spec also passes its own).
export type Cycle = {
	dayLengthMinutes: number, -- a full day, dawn to dawn, in real minutes
	nightShare: number, -- 0..1: the share of it from dusk to dawn
	duskClock: number, -- hours
	dawnClock: number, -- hours
}

-- How one kind of night light looks: by day its own colour (the part's DayColor attribute) in dayMaterial; at night
-- nightColor in nightMaterial, with any Light inside it switched on. A part's own NightColor attribute
-- (nightLights.nightColorAttribute) beats the kind's colour, so one kind can run a gradient (a bridge's ribs).
--   keepDayColor  at night the part glows in its own day colour (stained glass); nightColor is only a fallback
--   showColors    a light show: on showShare of the game's nights the kind glows in one of these, picked per night
--                 (the same colour for every part of the kind that night); on the other nights in nightColor
--   guiBrightness SurfaceGui.Brightness of the part's sign text at night (dayGuiBrightness by day), so lettering on a
--                 neon board glows with it; nil leaves its text alone
export type NightLook = {
	dayMaterial: Enum.Material,
	nightMaterial: Enum.Material,
	nightColor: Color3,
	keepDayColor: boolean?,
	showColors: { Color3 }?,
	showShare: number?,
	guiBrightness: number?,
}

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

-- The sky by day, the same from mid-morning to late afternoon: a high, hard subtropical sun, a saturated cyan sky and a
-- slightly warm sun tint (docs/city/SCENERY.md §9). The fill light is kept low so the sun, the shadows and the sky's
-- reflections give the shapes their edges (2026-10-25: a brighter fill washed every model flat). The bloom threshold
-- stays above sunlit white stucco, so by day only glints and the sun glow.
local DAY: Keyframe = {
	clock = 0,
	ambient = rgb(58, 60, 68),
	outdoorAmbient = rgb(116, 118, 126),
	fogColor = rgb(190, 212, 232),
	atmosphereColor = rgb(192, 212, 232),
	atmosphereDecay = rgb(98, 118, 142),
	brightness = 2.8,
	colorShiftTop = rgb(24, 18, 8),
	exposure = 0,
	bloomIntensity = 0.6,
	bloomThreshold = 2.2,
}

-- The sky by night: a deep electric blue (never black), with as much fill light as before so a road and a car still
-- read on a phone, a touch of exposure, and a lower bloom threshold so neon signs and tower crowns halo.
local NIGHT: Keyframe = {
	clock = 0,
	ambient = rgb(28, 34, 62),
	outdoorAmbient = rgb(56, 66, 112),
	fogColor = rgb(20, 24, 48),
	atmosphereColor = rgb(48, 58, 110),
	atmosphereDecay = rgb(28, 34, 84),
	brightness = 1.4,
	colorShiftTop = rgb(0, 6, 18),
	exposure = 0.2,
	bloomIntensity = 1,
	bloomThreshold = 1.8,
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
				-- Before dawn: the blue night turning violet.
				clock = 5.75,
				ambient = rgb(50, 48, 80),
				outdoorAmbient = rgb(88, 84, 124),
				fogColor = rgb(80, 76, 118),
				atmosphereColor = rgb(112, 100, 150),
				atmosphereDecay = rgb(66, 58, 110),
				brightness = 1.6,
				colorShiftTop = rgb(8, 4, 16),
				exposure = 0.15,
				bloomIntensity = 0.95,
				bloomThreshold = 1.85,
			},
			{
				-- Dawn: low pink-orange light.
				clock = 6.75,
				ambient = rgb(78, 66, 66),
				outdoorAmbient = rgb(146, 118, 108),
				fogColor = rgb(226, 168, 146),
				atmosphereColor = rgb(240, 180, 160),
				atmosphereDecay = rgb(204, 120, 116),
				brightness = 2.1,
				colorShiftTop = rgb(60, 30, 14),
				exposure = 0.05,
				bloomIntensity = 0.8,
				bloomThreshold = 2,
			},
			{
				-- The morning golden hour, warming into day.
				clock = 7.75,
				ambient = rgb(66, 62, 66),
				outdoorAmbient = rgb(130, 120, 116),
				fogColor = rgb(216, 200, 186),
				atmosphereColor = rgb(222, 206, 194),
				atmosphereDecay = rgb(150, 128, 124),
				brightness = 2.5,
				colorShiftTop = rgb(40, 26, 10),
				exposure = 0,
				bloomIntensity = 0.7,
				bloomThreshold = 2.1,
			},
			at(9, DAY),
			at(16, DAY),
			{
				-- The evening golden hour: pink-orange light on the white towers.
				clock = 17.25,
				ambient = rgb(80, 66, 64),
				outdoorAmbient = rgb(156, 120, 106),
				fogColor = rgb(236, 170, 142),
				atmosphereColor = rgb(240, 170, 150),
				atmosphereDecay = rgb(210, 110, 120),
				brightness = 2.4,
				colorShiftTop = rgb(72, 34, 18),
				exposure = 0,
				bloomIntensity = 0.8,
				bloomThreshold = 2,
			},
			{
				-- Dusk: violet, the neon just on (duskClock 18).
				clock = 18.75,
				ambient = rgb(64, 56, 86),
				outdoorAmbient = rgb(100, 86, 124),
				fogColor = rgb(90, 70, 112),
				atmosphereColor = rgb(132, 102, 150),
				atmosphereDecay = rgb(90, 60, 120),
				brightness = 1.7,
				colorShiftTop = rgb(20, 8, 24),
				exposure = 0.1,
				bloomIntensity = 0.95,
				bloomThreshold = 1.85,
			},
			at(19.75, NIGHT),
		} :: { Keyframe },
		-- Lighting's Atmosphere: the one already there, or one named `name`, given these values at server start (only
		-- its Color and Decay then follow the clock). A thinner haze than before keeps the far skyline across the bay in
		-- view; a little glare gives the sun a hot halo (glare needs haze above 0).
		atmosphere = {
			name = "DayNightAtmosphere",
			density = 0.26,
			offset = 0.25,
			glare = 0.25,
			haze = 0.8,
		},
		-- Set once when the server starts (DayNightService). The place ran the flat retro look: Soft lighting style, the
		-- Retro tone mapper, bloom at 0 (so Neon never glowed), shadows off and no sky reflections (docs/city/TECH.md
		-- §1, 2026-10-25). Lighting.Technology isn't scriptable, but the engine's docs say LightingStyle and
		-- PrioritizeLightingQuality supersede it, and both are.
		scene = {
			lightingStyle = Enum.LightingStyle.Realistic, -- the naturalistic look (Soft is the stylized, flat one)
			-- When a phone has to drop quality, keep shadows and good shaders close by and give up view distance first.
			prioritizeLightingQuality = true,
			geographicLatitude = 25.8, -- degrees north: a high sun with short, crisp shadows
			globalShadows = true,
			shadowSoftness = 0.1, -- 0 = razor-sharp, 1 = blurry
			environmentSpecularScale = 1, -- sky reflections on paint, glass and metal
			environmentDiffuseScale = 1, -- light from the sky itself
			-- The tone mapper on every ColorGradingEffect under Lighting (one named `name` is made when there is none).
			-- Default, not Retro: Retro imitates pre-2019 lighting, less saturated and less contrast (TECH §1, tested).
			toneMapper = { name = "SceneGrading", preset = Enum.TonemapperPreset.Default },
			-- Lighting's BloomEffect (the one already there, or one named `name`). Its intensity and threshold follow the
			-- clock (the keyframes' bloomIntensity and bloomThreshold); size is the glow's radius in pixels.
			bloom = { name = "SceneBloom", size = 24 },
			-- Effects made under Lighting when missing (one already there with the same name is set to these values).
			colorCorrection = {
				name = "SceneColor",
				contrast = 0.1,
				saturation = 0.15, -- pastel colour without grey, now that the Default tone mapper is on
				brightness = 0,
				tintColor = rgb(255, 250, 244),
			},
			sunRays = { name = "SceneSunRays", intensity = 0.05, spread = 0.8 },
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
		-- Color3, optional, on a night light: its own night colour, beating its kind's (a gradient along a bridge, one
		-- building's neon in another shade).
		nightColorAttribute = "NightColor",
		-- SurfaceGui.Brightness of sign text by day (Roblox's default) on kinds that brighten it at night.
		dayGuiBrightness = 1,
		-- Salt for a light show's pick of the night's colour (NightLook.showColors); change it to reshuffle the shows.
		showSeed = 7919,
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
				-- A soft, lived-in glow: Neon's brightness follows its colour. rgb(118, 90, 54) read as strong amber over
				-- whole towers, rgb(70, 54, 34) as dim brown (docs/city/TECH.md §4); this sits between, less saturated,
				-- and is meant to stay under the night bloom threshold, so lit floors glow without haloing into slabs
				-- (TECH's proposal: not yet seen in a playtest).
				nightColor = rgb(100, 88, 68),
			},
			sign = {
				dayMaterial = Enum.Material.SmoothPlastic,
				nightMaterial = Enum.Material.Neon,
				nightColor = rgb(96, 226, 236),
				guiBrightness = 2.5,
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
			-- The beach city's neon (docs/city/ARCHETYPES.md §11, colours tested in docs/city/SCENERY.md §8; the
			-- archetype docs spell these neon_pink, led_edge and so on). By day each is its part's own colour in
			-- SmoothPlastic, a pastel moulding; at night a saturated tube, and lettering on it glows too. Never white
			-- Neon: it blows out under the bloom.
			neonPink = {
				dayMaterial = Enum.Material.SmoothPlastic,
				nightMaterial = Enum.Material.Neon,
				nightColor = rgb(255, 90, 170),
				guiBrightness = 2.5,
			},
			neonViolet = {
				dayMaterial = Enum.Material.SmoothPlastic,
				nightMaterial = Enum.Material.Neon,
				nightColor = rgb(170, 90, 255),
				guiBrightness = 2.5,
			},
			neonAmber = {
				dayMaterial = Enum.Material.SmoothPlastic,
				nightMaterial = Enum.Material.Neon,
				nightColor = rgb(255, 170, 60),
				guiBrightness = 2.5,
			},
			neonBlue = {
				dayMaterial = Enum.Material.SmoothPlastic,
				nightMaterial = Enum.Material.Neon,
				nightColor = rgb(61, 123, 255),
				guiBrightness = 2.5,
			},
			neonCyan = {
				dayMaterial = Enum.Material.SmoothPlastic,
				nightMaterial = Enum.Material.Neon,
				nightColor = rgb(70, 230, 255),
				guiBrightness = 2.5,
			},
			-- Tower crowns, fins and lanterns: a cool white that stays under the blow-out.
			crown = {
				dayMaterial = Enum.Material.SmoothPlastic,
				nightMaterial = Enum.Material.Neon,
				nightColor = rgb(170, 200, 236),
			},
			-- A crown that puts on a show: the crown's cool white most nights; on showShare of them one colour from the
			-- list for the whole night (red, green, blue, pink, amber), the same on every tier.
			crownShow = {
				dayMaterial = Enum.Material.SmoothPlastic,
				nightMaterial = Enum.Material.Neon,
				nightColor = rgb(170, 200, 236),
				showColors = {
					rgb(224, 69, 75),
					rgb(63, 163, 107),
					rgb(61, 123, 255),
					rgb(236, 150, 180),
					rgb(255, 180, 74),
				},
				showShare = 0.4,
			},
			-- LED strips on balcony and podium edges: a saturated blue.
			ledBlue = {
				dayMaterial = Enum.Material.SmoothPlastic,
				nightMaterial = Enum.Material.Neon,
				nightColor = rgb(60, 130, 255),
			},
			-- LED strips on slab edges, soffits, garage strips and roof edges: a pale ice blue.
			ledEdge = {
				dayMaterial = Enum.Material.SmoothPlastic,
				nightMaterial = Enum.Material.Neon,
				nightColor = rgb(143, 205, 230),
			},
			-- Coloured glass that glows in its own colour at night (a glass annex's panels): give it saturated, mid-bright
			-- colours, since a pale one turns white-hot Neon. nightColor is only a fallback.
			stained = {
				dayMaterial = Enum.Material.Glass,
				nightMaterial = Enum.Material.Neon,
				nightColor = rgb(120, 150, 200),
				keepDayColor = true,
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
	-- building shells do, like any wall). Trees, buildings and features sit in Atomic models that stream (only Ground,
	-- Roads and the city's small Skyline model are Persistent; city buildings are SLIM, so far ones stay as cheap
	-- stand-ins), so a phone holds what lies inside the 2,048-stud streaming target radius (about 13 % of the map) and
	-- drops the far models first when short of memory. Leaves and trunks are plain blocks (12 triangles), not balls.
	-- The perf drive and Davis's real-phone check decide whether these hold (Config/Perf); inViewParts is the gate a
	-- phone meets first, and these numbers are the lever if it doesn't.
	budget = {
		-- The whole of Workspace.Map.Generated. 2026-10-25, the lead's decision L4 (docs/city/CITY_PLAN.md §9): up from
		-- 16,000 for the hand-modelled city, about 27,400 planned.
		mapParts = 30000,
		-- The phone gate (CITY_PLAN §9): the most parts a player can have streamed in at once, every Persistent part
		-- (the ground, the roads, the Skyline) plus every part within Perf.streaming.targetRadius of the worst road
		-- node (downtown's centre). tests/MapBuilder.spec and Dev/MapCheck hold the county to it; Davis's phone check
		-- after the downtown step decides whether it holds.
		inViewParts = 20000,
		-- Trunks and leaves: about 1,400 trees at 2 or 3 parts each (a palm is 2: its trunk and its crown, whose mesh the
		-- build clones; Dev/City/Scenery Palms). The street and beach palms are scenery (Config/CityScenery budget).
		treeParts = 4400,
		-- Every building part: the city's sites (Dev/City, about 40..150 parts each) and the old facade on the plots no
		-- archetype fits. Per district in Config/City budgets (14,120 together).
		buildingParts = 15000,
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
		maxTrees = 1600,
		minTrees = 1100,
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
			-- The lake ring: palms and sea grape round the bay (the "park" mix below).
			lakefront_park = { cell = 30, chance = 0.3 },
			-- The sand band split from Lakefront Park (CITY_PLAN §6): none at random. Dev/City/Scenery Beach plants its
			-- coconut palms by hand, in clumps behind the dunes, leaning out to sea, clear of the stands and boardwalks.
			lakefront_beach = { cell = 30, chance = 0 },
			-- Town Square: shade trees between its palm allée and fountain (Dev/City/Scenery Square).
			town_square = { cell = 30, chance = 0.25 },
		} :: { [string]: { cell: number, chance: number } },
		-- Groves, planted in this order (the outskirts last, so a cap trims them first).
		groves = {
			{
				zone = "riverside",
				cell = 260,
				chance = 0.55,
				trees = { 2, 6 },
				radius = { 25, 55 },
				species = "suburbs",
			},
			{
				zone = "lakefront",
				cell = 300,
				chance = 0.45,
				trees = { 3, 7 },
				radius = { 30, 70 },
				species = "beach",
			},
			{
				zone = "the_plant",
				cell = 420,
				chance = 0.3,
				trees = { 2, 5 },
				radius = { 25, 50 },
				species = "arts",
			},
			{
				-- The open country keeps its broadleaf woods, a little thinner than before.
				zone = "county_loop",
				cell = 420,
				chance = 0.46,
				outskirtsChance = 0.62,
				trees = { 4, 9 },
				radius = { 50, 120 },
				species = "country",
			},
		} :: { Grove },
		-- Species mixes in a fixed order; weights add up to 1. A species is a palm (Config/CityScenery palms: royal,
		-- coconut, sabal) or a block tree (Dev/MapBuilder TUNING.treeSpecies). The towns are mostly palms
		-- (docs/city/SCENERY.md §1, CITY_PLAN §6); the country keeps its broadleaf woods, and the outskirts lean to pines.
		mixes = {
			park = {
				mix("coconut", 0.3),
				mix("sabal", 0.25),
				mix("royal", 0.1),
				mix("sea_grape", 0.15),
				mix("broadleaf", 0.2),
			},
			suburbs = { mix("live_oak", 0.35), mix("sabal", 0.25), mix("royal", 0.2), mix("broadleaf", 0.2) },
			beach = { mix("coconut", 0.45), mix("sabal", 0.25), mix("sea_grape", 0.3) },
			arts = { mix("sabal", 0.4), mix("royal", 0.3), mix("live_oak", 0.3) },
			country = {
				mix("broadleaf", 0.35),
				mix("live_oak", 0.15),
				mix("round", 0.15),
				mix("pine", 0.25),
				mix("poplar", 0.05),
				mix("sabal", 0.05),
			},
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
