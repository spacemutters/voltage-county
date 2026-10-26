--!strict
-- The Miami city (docs/city/CITY_PLAN.md, docs/city/ARCHETYPES.md, docs/city/ARCHETYPE_GUIDE.md). Dev/City reads it
-- and Dev/MapBuilder builds what it plans:
--   districts   which city district each MapLayout zone is (zones keep their in-game names)
--   archetypes  every building type the city builder may place: where, how often, how big, how tall, and its part
--               budget. Each one is a module in src/server/Dev/City/Archetypes (listed in its Index). The shapes
--               themselves live in those modules; what decides where and how many lives here.
--   kit         numbers every archetype shares (Dev/City/Kit): how far glass sits in, how far trim stands proud...
--   textures    the window-grid and slab-line images drawn for the city (docs/city/TECH.md §8, Davis's account)
--   palettes    colours by family, tested under the game's day light (docs/city/SCENERY.md §8)
--   signNames   invented names for hotel and tower signs: never a real building, brand or business
--
-- Real buildings are inspiration only. Their names stay in docs/city and never appear here, in code, in instance
-- names or on signs.

-- A building type's placement and limits. Sizes are studs; `width` runs along the road, `depth` away from it.
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
	ownModel: boolean, -- its own Atomic model (towers), or the block tile's model (low buildings)
}

-- A district's shared look.
export type DistrictConfig = {
	floor: number, -- floor-to-floor height (studs)
	legacyWeight: number, -- the old facade's weight among the candidates while the district's set is incomplete
	font: Enum.Font, -- signs
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
		downtown = { floor = 12, legacyWeight = 6, font = Enum.Font.Michroma },
		beach = { floor = 11, legacyWeight = 3, font = Enum.Font.JosefinSans },
		suburbs = { floor = 11, legacyWeight = 1, font = Enum.Font.Merriweather },
		arts = { floor = 16, legacyWeight = 1, font = Enum.Font.PermanentMarker },
		quarry = { floor = 12, legacyWeight = 1, font = Enum.Font.Michroma },
	} :: { [string]: DistrictConfig },

	-- Ids are docs/city/ARCHETYPES.md's (T01..T18, B01..B12, R01..R08, W01..W05, C01..C09). Each archetype's placement
	-- and limits live in their own module, Config/CityArchetypes/<id>.luau (filled in below), so the modules for many
	-- archetypes can be written side by side.
	archetypes = {} :: { [string]: ArchetypeConfig },

	-- The skyline (CITY_PLAN §2): the most a site may rise, by where it stands. Downtown is a 6 x 6 grid of 300-stud
	-- blocks from (-900, -900), rows north to south, columns west to east (block "d4" is grid[4][4]); 0 keeps a block
	-- clear (Town Square, the auto mall). Outside the grid each side has its own cap: the motel row north, the
	-- storefronts west, garages and lofts east, the bay row south. An archetype whose lowest height is over a site's cap
	-- doesn't stand there. Districts without a table have no cap beyond their archetypes' heights.
	heightCaps = {
		downtown = {
			origin = Vector2.new(-900, -900),
			cell = 300,
			grid = {
				{ 130, 150, 200, 300, 220, 160 },
				{ 120, 180, 240, 340, 300, 220 },
				{ 110, 170, 0, 360, 320, 240 },
				{ 120, 180, 260, 380, 340, 240 },
				{ 100, 150, 240, 220, 60, 70 },
				{ 110, 180, 300, 340, 220, 0 },
			},
			north = 60,
			west = 54,
			east = 96,
			south = 200,
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

	-- Sites as tall as this or taller get their own Atomic model (Buildings/Tower<n>) whatever their archetype says, so
	-- a tower streams as one piece.
	towerModelFrom = 160,

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
		-- Tower glass, cool blues and teals (Glass, reflectance kit.glassReflectance): bright blue in sun to
		-- Brickell-dark navy.
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
		},
		towers = { "ONE CURRENT", "THE ARC", "KILOWATT BAY", "CIRCUIT PLACE", "THE GRID" },
	},
}

-- Every Config/CityArchetypes/<id> module, keyed by its name.
for _, module in script.Parent.CityArchetypes:GetChildren() do
	if module:IsA("ModuleScript") then
		City.archetypes[module.Name] = (require :: any)(module) :: ArchetypeConfig
	end
end

return City
