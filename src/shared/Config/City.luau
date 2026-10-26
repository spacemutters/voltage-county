--!strict
-- The Miami city (docs/city/CITY_PLAN.md, docs/city/ARCHETYPES.md, docs/city/ARCHETYPE_GUIDE.md). Dev/City reads it
-- and Dev/MapBuilder builds what it plans:
--   districts   which city district each MapLayout zone is (zones keep their in-game names)
--   archetypes  every building type the city builder may place: where, how often, how big, how tall, and its part
--               budget. Each one is a module in src/server/Dev/City/Archetypes (listed in its Index). The shapes
--               themselves live in those modules; what decides where and how many lives here.
--   heightCaps  the skyline: the most a site may rise, block by block downtown
--   areas       parts of a zone with their own mix of archetypes, height cap, plot density and tower count (Ocean
--               Drive's hotel row, the beach kept open to the water, the lake roads, the south shore...)
--   landmarks   the one-offs, each at its anchor (CITY_PLAN §5)
--   claims, towers, slots, rules, cornerArchetypes, notOnPlots, skyline
--               how the planner (Dev/City/CityBuilder) cuts sites: core claims, tower slots, neighbours, repeats
--   budgets     parts per district, the always-loaded skyline and the building night lights (tests/MapBuilder.spec)
--   kit         numbers every archetype shares (Dev/City/Kit): how far glass sits in, how far trim stands proud...
--   textures    the window-grid and slab-line images drawn for the city (docs/city/TECH.md §8, Davis's account)
--   palettes    colours by family, tested under the game's day light (docs/city/SCENERY.md §8)
--   signNames   invented names for hotel, motel, tower and civic signs: never a real building, brand or business
--
-- Real buildings are inspiration only. Their names stay in docs/city and never appear here, in code, in instance
-- names or on signs.

-- A building type's placement and limits. Sizes are studs; `width` runs along the road, `depth` away from it.
-- A site deeper than a plot (53 studs) reaches back into its block's empty core with a claim (Config/City claims):
-- `minDepth` over 53 makes the claim a must, `claimDepth` asks for one when there is room.
export type ArchetypeConfig = {
	district: string, -- the district it belongs to (a value of `districts`)
	weight: number, -- relative chance among the district's candidates for a site (the old look's weight included)
	maxCopies: number, -- at most this many in the whole map
	perBlock: number, -- at most this many in one city block
	minSpacing: number, -- studs between the centres of two copies, at least
	minWidth: number, -- the narrowest site it is built on...
	maxWidth: number, -- ...and the widest (wider runs are cut into more sites)
	minDepth: number, -- the shallowest site
	maxPlots: number, -- neighbouring plots of one frontage it may merge into one site
	heights: { min: number, max: number }, -- its main roof, drawn per site
	crownMax: number, -- how far crowns, spires, signs and flagpoles may rise above the main roof
	budget: number, -- parts per site, at most (Dev/City/CityBuilder refuses a site over it)
	palettes: number, -- colour sets the module knows (variant.palette is 1..palettes)
	crowns: number, -- crown variants (variant.crown)
	rhythms: number, -- rhythm variants (variant.rhythm): balcony interval, fin spacing...
	ownModel: boolean, -- named a tower's model (Buildings/Tower<n>) even when low; every site has its own model
	claimDepth: number?, -- the depth it would like with a core claim, when its block has room (towers: towers.claimDepth)
	corner: ("only" | "prefer")?, -- block corners only, or preferred there (also set by cornerArchetypes below)
}

-- A district's shared look.
export type DistrictConfig = {
	floor: number, -- floor-to-floor height (studs)
	legacyWeight: number, -- the old facade's weight among the candidates (0: only where no archetype fits)
	font: Enum.Font, -- signs
}

-- A part of a zone with its own rules (the first area holding a plot's centre wins). `mix` weighs the archetypes that
-- may stand there: by archetype id first, then by the archetype's district; anything it doesn't name stays out. With
-- no area, a plot draws its own district's archetypes at weight 1.
export type AreaConfig = {
	id: string,
	zone: string, -- a MapLayout zone id
	min: Vector2, -- plan x, z
	max: Vector2,
	mix: { [string]: number },
	cap: number?, -- the most a site rises here
	density: number?, -- the plot pass builds this share of its plots here instead of the zone's buildingDensity
	towers: number?, -- repeatable towers (band T) the area may hold, placed like downtown's tower slots
}

-- A one-off (CITY_PLAN §5): its archetype at the window of free plots nearest `at`, built once.
export type LandmarkConfig = {
	id: string, -- the archetype (Config/CityArchetypes/<id>)
	at: Vector2, -- the anchor, plan x, z: the middle of the plots it should take
	radius: number?, -- plots this far from the anchor are tried (default landmarkRadius)
	width: number?, -- the width it would like (default its archetype's maxWidth)
	depth: number?, -- the depth it would like: a core claim behind its plots when deeper than a plot
	face: ("road" | "back")?, -- its front looks at its road (default) or away from it (the bay, the spawn)
	corner: boolean?, -- on a block corner
	height: number?, -- its main roof (default its archetype's tallest)
}

local rgb = Color3.fromRGB

local City = {
	-- MapLayout zone id -> district id (CITY_PLAN §3). A zone not listed keeps the old look everywhere.
	districts = {
		cedar_bend = "downtown",
		lakefront = "beach",
		riverside = "suburbs",
		the_plant = "arts",
		mesa_test_site = "quarry",
	} :: { [string]: string },

	districtLooks = {
		-- Fonts: none on the banned list (docs/city/SCENERY.md §7). Michroma is wide and modern for towers;
		-- JosefinSans is geometric 1920s for the beach; Merriweather for the suburbs; PermanentMarker for the arts.
		-- legacyWeight 0 everywhere: the old box look stands only on a site no archetype fits (tests/MapBuilder.spec
		-- prints how many, by district).
		downtown = { floor = 12, legacyWeight = 0, font = Enum.Font.Michroma },
		beach = { floor = 11, legacyWeight = 0, font = Enum.Font.JosefinSans },
		suburbs = { floor = 11, legacyWeight = 0, font = Enum.Font.Merriweather },
		arts = { floor = 16, legacyWeight = 0, font = Enum.Font.PermanentMarker },
		quarry = { floor = 12, legacyWeight = 0, font = Enum.Font.Michroma },
	} :: { [string]: DistrictConfig },

	-- Ids are docs/city/ARCHETYPES.md's (T01..T18, B01..B12, R01..R08, W01..W05, C01..C09). Each archetype's placement
	-- and limits live in their own module, Config/CityArchetypes/<id>.luau (filled in below), so the modules for many
	-- archetypes can be written side by side.
	archetypes = {} :: { [string]: ArchetypeConfig },

	-- The skyline (CITY_PLAN §2): the most a repeatable site may rise, by where it stands (one-offs keep their own
	-- heights). Downtown is a 6 x 6 grid of 300-stud blocks from (-900, -900), rows north to south, columns west to east
	-- (block "d4" is grid[4][4]); 0 keeps a block clear (Town Square, the auto mall). It peaks round Main and Commerce
	-- Avenues (columns d and e, rows 2..4, where the towers of docs/city/ARCHETYPES.md reach 400..490; d4 stays at 380
	-- under the twin ribbon towers by the spawn street), dips at Town Square, steps down to the west (a, b) and stays low
	-- at the spawn (e5) and the showroom (f5). Outside the grid each
	-- side has its own cap: the motel row north, the storefronts west, garages and lofts east, the bay row south. An
	-- archetype whose lowest height is over a site's cap doesn't stand there. Districts without a table have no cap
	-- beyond their archetypes' heights and their areas'.
	heightCaps = {
		downtown = {
			origin = Vector2.new(-900, -900),
			cell = 300,
			grid = {
				{ 140, 200, 300, 420, 320, 200 },
				{ 160, 260, 440, 500, 460, 320 },
				{ 150, 300, 0, 520, 480, 360 },
				{ 160, 320, 460, 380, 480, 340 },
				{ 130, 220, 400, 420, 60, 70 },
				{ 140, 260, 420, 460, 260, 0 },
			},
			north = 60,
			west = 54,
			east = 96,
			south = 240,
		},
	} :: {
		[string]: {
			origin: Vector2,
			cell: number,
			grid: { { number } },
			north: number,
			west: number,
			east: number,
			south: number,
		},
	},

	-- A site within nearSpotRange studs of a gameplay location (charging plaza, used lot, fuel, depots...) rises no
	-- higher than this, so those spots stay open to the eye (CITY_PLAN §2 "low near gameplay spots").
	nearSpotRange = 40,
	nearSpotCap = 160,

	-- Neighbouring buildings stand this far apart (Dev/MapBuilder TUNING.buildingGap): a site keeps half of it at each
	-- end of its plots.
	siteGap = 5,

	-- Every site is its own Atomic model, so it streams and swaps its level of detail as one piece (docs/city/TECH.md
	-- §6): Buildings/Tower<n> for sites this tall or taller (or ownModel), Buildings/Site<n> for the rest.
	towerModelFrom = 160,

	-- Height bands (CITY_PLAN §2), each band's lowest roof: L below M, M (mid-rise), H (high-rise), T (the towers, one
	-- per downtown block), S (the supertall one-offs).
	bands = { M = 84, H = 160, T = 260, S = 420 },

	-- Repeatable towers per downtown block: one band T, two band H (one-offs taller than T take the T slot).
	slots = { T = 1, H = 2 },

	-- Core claims (decision L1): a site that wants more depth than a plot reaches back from its plots into its block's
	-- empty core. A claim passes the same clear checks a plot does (flat open ground, clear of roads, sidewalks,
	-- locations and their corridors, landmarks, parks, other plots and claims), and is paved and kept clear of trees.
	claims = {
		maxDepth = 110, -- from the front line, for repeatable sites (a one-off may ask for more: landmarks[].depth)
		step = 10, -- a claim that doesn't fit is tried this much shallower, down to what its archetype needs
	},

	-- The tower pass (CITY_PLAN §2 "tower slots"): each slot takes the window of free plots nearest a peak.
	towers = {
		claimDepth = 100, -- a tower's depth with its claim, when its block has room
		minWidth = 60, -- windows narrower than this are not tried
		maxPlots = 5,
		peaks = { Vector2.new(0, 0), Vector2.new(300, -450) }, -- Main and Commerce Avenues; the north peak (d2..e2)
		rise = 0.65, -- a tower stands at least this share of the way from band T to its cap
	},

	-- Placement rules (CITY_PLAN §4.5).
	rules = {
		neighbourGap = 90, -- sites this close, footprint to footprint, are neighbours: beside, across, round the corner
		perBlock = 2, -- an archetype stands at most this many times in one block (and its own perBlock)
		acrossHeight = 0.25, -- the last resort: the same archetype across the street, a palette apart and this much
		-- taller or lower
		twinRange = 600, -- two towers (band T and up) this close...
		twinGap = 24, -- ...differ by at least this in height (two floors)
		wideShare = 0.6, -- a site takes the widest fit this often (fewer, bigger buildings), else a random one
		stepDown = 0.6, -- the rest of a run with a tower rises at most this share of the tower (its podium blocks)
		cornerReach = 30, -- a plot this near its frontage's cut end stands on a block corner
	},

	-- Corner archetypes (CITY_PLAN §4.4): "only" stands on block corners, "prefer" is three times as likely there.
	-- Placement mirrors each copy so the corner is at its +x end as drawn (site.corner.right).
	cornerArchetypes = {
		flatiron_wedge_tower = "only",
		corner_spire_hotel = "only",
		lighthouse_corner_hotel = "only",
		streamline_round_corner = "prefer",
	} :: { [string]: "only" | "prefer" },
	cornerPreference = 3,

	-- Archetypes built somewhere other than a plot (the scenery and the restyled features): never placed on plots.
	notOnPlots = {
		lifeguard_stand = true,
		causeway_bridge = true,
		lighthouse_water_tower = true,
		folded_roof_marine_stadium = true,
	} :: { [string]: boolean },

	-- Areas (see AreaConfig), the first holding a plot's centre wins. Downtown's outer frontages and blocks borrow the
	-- low and mid-rise types of the other districts (motels, garden apartments, garages), so a low block is never an
	-- old box; the beach is a hotel row on the north shore road's land side, open sand on its beach side, villas on the
	-- west road, motels on the east road and a few slender towers on the south shore.
	areas = {
		{
			id = "downtown_north", -- the motel row past the north edge street
			zone = "cedar_bend",
			min = Vector2.new(-1000, -1000),
			max = Vector2.new(1000, -905),
			mix = {
				downtown = 1,
				mimo_truss_motel = 1.5,
				mimo_garden_apartment = 1,
				arcade_village_street = 0.8,
				mosaic_townhouse_row = 0.6,
			},
		},
		{
			id = "downtown_west", -- bright storefronts
			zone = "cedar_bend",
			min = Vector2.new(-1000, -905),
			max = Vector2.new(-905, 905),
			mix = {
				downtown = 1,
				arcade_village_street = 1.5,
				mosaic_townhouse_row = 1,
				mimo_garden_apartment = 0.8,
				mural_warehouse = 0.8,
			},
		},
		{
			id = "downtown_east", -- garages and lofts toward The Plant
			zone = "cedar_bend",
			min = Vector2.new(905, -905),
			max = Vector2.new(1000, 905),
			mix = {
				downtown = 1,
				collage_parking_garage = 1.5,
				sculpted_car_park = 1.5,
				mural_warehouse = 1,
				faceted_gallery = 0.6,
			},
		},
		{
			id = "bay_row", -- past the south edge street, facing the lake: the one-offs and H towers between them
			zone = "cedar_bend",
			min = Vector2.new(-1000, 905),
			max = Vector2.new(1000, 1000),
			mix = { downtown = 1, red_ziggurat_lowrise = 1 },
		},
		{
			id = "downtown",
			zone = "cedar_bend",
			min = Vector2.new(-905, -905),
			max = Vector2.new(905, 905),
			mix = {
				downtown = 1,
				red_ziggurat_lowrise = 0.8,
				sculpted_car_park = 0.6,
				collage_parking_garage = 0.5,
				mosaic_townhouse_row = 0.5,
				mimo_garden_apartment = 0.4,
				mimo_truss_motel = 0.3,
				arcade_village_street = 0.3,
			},
		},
		{
			id = "ocean_drive", -- the north shore road's land side: a continuous hotel row (decision L2)
			zone = "lakefront",
			min = Vector2.new(-1135, 1300),
			max = Vector2.new(1135, 1496),
			mix = { beach = 1 },
			cap = 200,
			density = 0.95,
		},
		{
			id = "ocean_beach", -- its beach side: nothing built, so the hotels look over the sand to the water
			zone = "lakefront",
			min = Vector2.new(-1080, 1504),
			max = Vector2.new(1080, 1640),
			mix = {},
			cap = 0,
			density = 0,
		},
		{
			id = "lake_west", -- waterfront villas
			zone = "lakefront",
			min = Vector2.new(-1400, 1500),
			max = Vector2.new(-1080, 3100),
			mix = {
				tropical_modern_villa = 1.5,
				pink_layered_house = 0.8,
				mediterranean_villa = 0.6,
				veranda_raised_house = 0.5,
				beach = 0.3,
			},
			cap = 60,
		},
		{
			id = "lake_east", -- motels and the diner
			zone = "lakefront",
			min = Vector2.new(1080, 1500),
			max = Vector2.new(1400, 3100),
			mix = { mimo_truss_motel = 1.5, mimo_garden_apartment = 0.5, beach = 0.6 },
			cap = 60,
		},
		{
			id = "south_shore", -- slender towers and low pastel apartments across the lake
			zone = "lakefront",
			min = Vector2.new(-1080, 2700),
			max = Vector2.new(1080, 3100),
			mix = {
				cantilever_slab_tower = 1,
				car_lift_cylinder_tower = 1,
				fin_column_tower = 0.6,
				mimo_garden_apartment = 1,
				mosaic_townhouse_row = 1,
				beach = 0.4,
			},
			cap = 480,
			towers = 2,
		},
		{
			id = "river_avenue", -- the suburbs' shopping street: arcades under tile roofs
			zone = "riverside",
			min = Vector2.new(-3100, -110),
			max = Vector2.new(-1200, 110),
			mix = {
				arcade_village_street = 1.5,
				mosaic_townhouse_row = 0.8,
				mimo_garden_apartment = 0.8,
				suburbs = 0.25,
			},
			cap = 60,
		},
		{
			id = "suburbs",
			zone = "riverside",
			min = Vector2.new(-3100, -1100),
			max = Vector2.new(-1200, 1300),
			mix = { suburbs = 1, red_ziggurat_lowrise = 0 },
			cap = 50,
		},
		{
			id = "plant_avenue", -- galleries and sculpted garages on the arts district's avenue
			zone = "the_plant",
			min = Vector2.new(1200, -110),
			max = Vector2.new(3100, 110),
			mix = {
				faceted_gallery = 1.5,
				sculpted_car_park = 1.2,
				collage_parking_garage = 1,
				tiled_mural_midrise = 0.6,
				arts = 0.6,
			},
			cap = 120,
		},
		{
			id = "arts",
			zone = "the_plant",
			min = Vector2.new(1200, -1100),
			max = Vector2.new(3100, 1200),
			mix = { arts = 1 },
			cap = 96,
		},
		{
			id = "quarry", -- warehouses with barrel roofs stand in for hangars
			zone = "mesa_test_site",
			min = Vector2.new(-800, -3100),
			max = Vector2.new(3000, -1300),
			mix = { quarry = 1, mural_warehouse = 1 },
			cap = 40,
		},
	} :: { AreaConfig },

	-- The one-offs (CITY_PLAN §5, with docs/city/ARCHETYPES.md's ids), placed first, in this order, each at the window of
	-- free plots nearest its anchor (anchors are today's runs, measured 2026-10-25). A one-off whose archetype module
	-- isn't written yet is skipped; one that finds no site fails tests/MapBuilder.spec. Heights are the archetypes'
	-- tallest unless given; their caps don't apply.
	landmarkRadius = 160,
	landmarks = {
		-- Downtown: the peak at Main and Commerce, the spawn view, the north peak, the bridge view.
		{ id = "stacked_cube_supertall", at = Vector2.new(150, -65), depth = 110 }, -- d3 on Commerce Avenue
		{ id = "tiered_curve_crown_tower", at = Vector2.new(468, 60), depth = 110, face = "back" }, -- e4, to the spawn
		{ id = "exoskeleton_tower", at = Vector2.new(64, -447), depth = 110 }, -- d2 on Main Avenue
		{ id = "sawtooth_office_tower", at = Vector2.new(732, -347), depth = 110 }, -- f2
		{ id = "ribbon_canopy_towers", at = Vector2.new(130, 251), depth = 110 }, -- d4, by the spawn street
		{ id = "stair_wing_slab", at = Vector2.new(115, 856), depth = 120 }, -- d6, its stairs down toward the bridge
		{ id = "cupola_bell_tower", at = Vector2.new(66, -190), depth = 90 }, -- d3 on Main Avenue, facing Town Square
		{ id = "stepped_crown_courthouse", at = Vector2.new(-66, 530), depth = 110 }, -- c5, by the Courthouse hotspot
		-- The bay row (the widest runs downtown: 236 and 200 studs), faces to the lake.
		{ id = "triple_tower_podium", at = Vector2.new(-451, 940), depth = 110, face = "back" },
		{ id = "sail_supertall", at = Vector2.new(783, 950), depth = 110, face = "back" },
		{ id = "sky_court_slab", at = Vector2.new(-164, 945), depth = 70, face = "back" },
		{ id = "red_ziggurat_lowrise", at = Vector2.new(119, 943) },
		{ id = "bayfront_arena", at = Vector2.new(450, 950), radius = 260, depth = 180, face = "back" },
		{ id = "harbor_market_pavilions", at = Vector2.new(-740, 950), radius = 220, depth = 160, face = "back" },
		-- The beach.
		{ id = "curved_resort_slab", at = Vector2.new(1195, 1650), radius = 260, depth = 140 }, -- the east road
		{ id = "deco_porthole_highrise", at = Vector2.new(620, 1460) }, -- the hotel row's tallest deco hotel
		{ id = "lighthouse_corner_hotel", at = Vector2.new(-1000, 1460), radius = 200, corner = true },
		{ id = "domed_sanctuary", at = Vector2.new(-414, 1460) },
		-- The arts district.
		{ id = "collage_parking_garage", at = Vector2.new(2352, 53), depth = 80 }, -- Plant Avenue
		{ id = "faceted_gallery", at = Vector2.new(2015, -56) }, -- Plant Avenue, east of the Plant Gate
		{ id = "port_crane_yard", at = Vector2.new(2515, 600), radius = 420, depth = 140 }, -- by the freight depot
	} :: { LandmarkConfig },

	-- The Skyline model (CITY_PLAN §7.3): Persistent, so the towers' silhouettes and crown lights stay in view from the
	-- bridge and the beach past the streaming radius, whatever SLIM does. It holds, for each site of band T and up
	-- (tallest first, while budgets.skyline lasts), its biggest masses that rise past massFrom of its height and its
	-- crown light. Everything else of the tower streams as usual.
	skyline = {
		folder = "Skyline",
		masses = 3,
		massFrom = 0.4,
		crowns = 1,
		crownFrom = 0.85,
	},

	-- Parts (CITY_PLAN §9): each district's share of Environment budget.buildingParts (city sites and old-look fallbacks
	-- together; tests/MapBuilder.spec prints any district past its share); the Skyline model and the night-light parts
	-- of all the buildings (both held: DayNightService flips night lights 200 a frame at dusk).
	budgets = {
		districts = { downtown = 8800, beach = 2100, suburbs = 1500, arts = 1600, quarry = 120 } :: { [string]: number },
		skyline = 200,
		nightLights = 1400,
	},

	-- Shared numbers for Dev/City/Kit (docs/city/TECH.md §2 and §5; CITY_PLAN §8.4 "sharpness rules").
	kit = {
		bury = 1, -- walls and columns reach this far below the ground (hides the seam at the foot)
		minProud = 0.05, -- anything laid on a face stands at least this far proud of it (no coplanar faces)
		glassInset = 0.6, -- glass sits this far inside its frame
		frontClear = 3, -- solid masses stand at least this far behind the site's front line
		glassReflectance = 0.15, -- tower glass mirrors the sky
		railTransparency = 0.55, -- balcony glass rails, the only see-through glass
		railHeight = 3.2,
		trimShadowMin = 1, -- trim thinner than this in both directions casts no shadow
		neonDiameter = 0.6, -- a neon tube reads at night from this thick (a 0.3 strip barely does)
		washBrightness = 3, -- a facade wash's SurfaceLight (one per hero facade, lit at night only)
		washRange = 32,
		washAngle = 50,
		signPixelsPerStud = 12,
	},

	-- Overlay images drawn for the city (white lines on transparent, tinted by the Texture's colour).
	textures = {
		windowFine = "rbxassetid://107027263614936", -- curtain wall: thin mullions, a spandrel per tile
		windowBold = "rbxassetid://86379885232472", -- the same, bolder lines (screens, small windows)
		slabLine = "rbxassetid://127561142232255", -- one white band at the bottom of each tile (floor lines)
		-- A wall with one window per tile (88 % wide, 56 % tall, 12 % below the tile's top; tiles start at the face's
		-- top edge): tinted to the wall's colour over a dark glass part, it makes a punched stucco wall from one part.
		punched = "rbxassetid://77733097138973",
	},

	palettes = {
		-- Tower glass, cool blues and teals (Glass, reflectance kit.glassReflectance): bright blue in sun to a deep
		-- harbour navy.
		glass = {
			aqua = rgb(64, 110, 128),
			blue = rgb(52, 86, 112),
			teal = rgb(40, 84, 100),
			navy = rgb(34, 64, 82),
			silver = rgb(110, 140, 160),
			smoke = rgb(38, 48, 58),
		},
		-- Frames, slab edges and fins.
		frame = {
			white = rgb(250, 250, 248),
			warm = rgb(238, 234, 224),
			silver = rgb(196, 202, 208),
			charcoal = rgb(52, 56, 62),
		},
		-- Concrete and podium tones.
		concrete = {
			pale = rgb(214, 210, 202),
			warm = rgb(204, 196, 182),
			dark = rgb(40, 44, 50), -- garage slots, recesses, shadow joints
		},
		-- Art Deco stucco and accents, pushed a third past the paint chip so the sky light doesn't grey them.
		deco = {
			white = rgb(246, 244, 238),
			pink = rgb(255, 160, 172),
			mint = rgb(140, 224, 196),
			lemon = rgb(255, 210, 130),
			lilac = rgb(190, 160, 236),
			peach = rgb(255, 170, 120),
			sky = rgb(120, 200, 232),
			aqua = rgb(120, 206, 214),
			terrazzo = rgb(236, 222, 210),
		},
		-- Window glass in stucco (dark, so the windows read against white).
		window = {
			dark = rgb(40, 70, 86),
			deep = rgb(34, 52, 64),
		},
		water = rgb(70, 196, 210),
		leaf = rgb(62, 120, 64),
		umbrella = { rgb(246, 244, 238), rgb(255, 160, 172), rgb(120, 200, 232), rgb(255, 210, 130) },
	},

	-- Invented names, on-theme for an electric county (CITY_PLAN §7.4; Davis may veto any, decision D5).
	signNames = {
		hotels = {
			"THE AMPERE",
			"SEAVOLT",
			"TIDEWATT",
			"LUMEN BAY",
			"CORAL CURRENT",
			"PALMVOLT",
			"AZURE AMP",
			"THE DYNAMO",
			"VOLTMERE",
			"THE AMPERLY",
			"GALVANNA",
			"WATTSLEY",
			"FILAMENTA",
			"MAGNETTA",
		},
		motels = { "WATTS END", "SPARK MOTEL", "THE ROTOR", "TWIN COIL", "STARTER INN" },
		towers = { "ONE CURRENT", "THE ARC", "KILOWATT BAY", "CIRCUIT PLACE", "THE GRID" },
		-- The arts district: studios, bars and galleries in the warehouses (W01..W04).
		arts = {
			"FUSE HALL",
			"COIL HOUSE",
			"ARC LIGHT ROOM",
			"VOLT CO-OP",
			"AMP ROOM",
			"WATT SHED",
			"HIGH TENSION",
			"LIVE CIRCUIT",
		},
		shops = { "CORAL ARCADE", "VOLT ROW", "THE SWITCHYARD", "AMP ALLEY", "CURRENT MARKET" },
		-- One-offs with a name of their own.
		civic = {
			market = "LAKESIDE MARKET",
			arena = "VOLTAGE COUNTY ARENA",
			stadium = "LAKE STADIUM",
			theatre = "THE CIRCUIT",
			courthouse = "COUNTY COURTHOUSE",
		} :: { [string]: string },
	},
}

-- Every Config/CityArchetypes/<id> module, keyed by its name.
for _, module in script.Parent.CityArchetypes:GetChildren() do
	if module:IsA("ModuleScript") then
		City.archetypes[module.Name] = (require :: any)(module) :: ArchetypeConfig
	end
end

return City
