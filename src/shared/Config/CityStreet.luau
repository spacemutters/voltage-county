--!strict
-- The city's street life (Dev/City/Street; docs/city/SCENERY.md; docs/city/CITY_PLAN.md §3), one section per helper:
--   parking   parked cars (Dev/City/Street/Parking): the car shapes and colours the templates in
--             ServerStorage.CityAssets.Cars come in, which shape parks where, and the rules for every place a car may
--             park (driveways, hotel drop-off bays, the diner's car park, kerbs, and the stalls of the surface lots)
--   frontage  shop fronts and café terraces at street level (Dev/City/Street/Frontage): shop windows lit in their
--             trade's colour, awnings, signs with invented names, planters, café sets under string lights
-- Every number here is a tunable; the planners keep to it, and nothing here moves a road, lot, pad or gameplay spot.

local rgb = Color3.fromRGB

---------------------------------------------------------------------------------------------------------------
-- Parking
---------------------------------------------------------------------------------------------------------------

-- One car shape: its template's name in ServerStorage.CityAssets.Cars, and the size it is scaled to (studs; the
-- template keeps its proportions and is scaled to `size.Z`, its length). The rest draws the parts-only stand-in the
-- build puts up while the template is missing.
export type CarShape = {
	size: Vector3, -- width, height, length
	body: number, -- share of the height the body's top stands at (the cabin's glass above it)
	cabin: Vector2, -- the cabin: its length (share of the car's) and how far its middle sits toward the nose (share)
	wheel: number, -- the wheels' diameter
}

-- One paint: the suffix its template variant carries (<shape>_<name>), the stand-in's colour, and how often it is
-- drawn.
export type CarColour = { name: string, color: Color3, weight: number }

-- How often each shape is drawn somewhere (shape name -> weight; a shape left out is never drawn there).
export type Mix = { [string]: number }

local parking = {
	-- Where the templates are: ServerStorage.<templateRoot> holds <shape>_<colour> (or a folder <shape> holding them,
	-- or a lone <shape>). Each is one MeshPart (or a Model), anchored; the build turns off its collisions, raycasts and
	-- touches (the invisible box below is what a car or a player bumps into).
	templateRoot = { "CityAssets", "Cars" },
	-- Degrees every template clone is turned more about its up axis. A template's nose is taken to point along its
	-- -Z (its LookVector), or along +X when it is longer in X than in Z; 180 turns a set whose noses point the other way.
	templateTurn = 0,
	-- The templates' own sizes (width, height, length; measured in Studio 2026-10-26 from ServerStorage.CityAssets.Cars).
	-- The generated cars are shorter for their width than the shapes' boxes, so a car is built at its own proportions:
	-- scaled evenly until it meets its shape's box (Parking.sizeOf), then stretched along its length by at most
	-- `templateStretch` toward the box's length (more and the wheels read oval). Its solid box is that size, and it stands
	-- at the end of its space that matters (nose to a garage, a building or a stall's head). A variant missing here takes
	-- the next paint's size, as the build takes the next paint's template; a shape with none takes its box.
	templateStretch = 1.15,
	templateSizes = {
		ParkedSedan_White = Vector3.new(6.6, 4.14, 10.97),
		ParkedSedan_Black = Vector3.new(6.35, 4.5, 14.2),
		ParkedSedan_Silver = Vector3.new(6.5, 4.47, 12.2),
		ParkedSedan_Red = Vector3.new(6.25, 4.5, 10.26),
		ParkedSedan_Blue = Vector3.new(6.6, 4.43, 11.6),
		ParkedSUV_White = Vector3.new(7, 5.62, 10.9),
		ParkedSUV_Black = Vector3.new(7, 5.84, 11.41),
		ParkedSUV_Silver = Vector3.new(7, 5.57, 12.18),
		ParkedSUV_Red = Vector3.new(7, 5.46, 12.08),
		ParkedSUV_Blue = Vector3.new(7, 5.5, 11.87),
		ParkedHatch_White = Vector3.new(6.4, 4.35, 10.51),
		ParkedHatch_Black = Vector3.new(6.4, 4.37, 10.58),
		ParkedHatch_Silver = Vector3.new(6.32, 5, 9.7),
		ParkedHatch_Red = Vector3.new(6.4, 4.42, 10.16),
		ParkedHatch_Blue = Vector3.new(6.4, 4.84, 10.02),
		ParkedPickup_White = Vector3.new(7, 5.88, 11.54),
		ParkedPickup_Black = Vector3.new(7, 5.68, 10.92),
		ParkedPickup_Silver = Vector3.new(7, 5.98, 14.47),
		ParkedPickup_Red = Vector3.new(7, 5.87, 14.14),
		ParkedPickup_Blue = Vector3.new(7, 6.27, 14.8),
		ParkedCoupe_White = Vector3.new(6.49, 4.2, 9.74),
		ParkedCoupe_Black = Vector3.new(6.6, 4.05, 10.89),
		ParkedCoupe_Silver = Vector3.new(6.6, 4.06, 11.9),
		ParkedCoupe_Red = Vector3.new(6.6, 4.16, 11.76),
		ParkedCoupe_Blue = Vector3.new(6.27, 4.2, 10.65),
		ParkedVan_White = Vector3.new(7, 5.57, 11.77),
		ParkedVan_Black = Vector3.new(7, 5.87, 12.67),
		ParkedVan_Silver = Vector3.new(7, 6.12, 13.34),
		ParkedVan_Red = Vector3.new(7, 5.55, 11.91),
	} :: { [string]: Vector3 },
	-- Where the cars are filed: <root>/Tile<x>_<z>, one Atomic model (SLIM: still parts only) per `tile` studs.
	root = "ParkedCars",
	tile = 500,

	-- The shapes, drawn in this order (a map's order isn't fixed in Luau, so every pick walks this list).
	order = { "ParkedSedan", "ParkedSUV", "ParkedHatch", "ParkedPickup", "ParkedCoupe", "ParkedVan" },
	shapes = {
		ParkedSedan = { size = Vector3.new(6.6, 4.8, 15.4), body = 0.55, cabin = Vector2.new(0.48, -0.04), wheel = 2.4 },
		ParkedSUV = { size = Vector3.new(7, 6.2, 16), body = 0.55, cabin = Vector2.new(0.62, -0.08), wheel = 2.8 },
		ParkedHatch = { size = Vector3.new(6.4, 5, 13.4), body = 0.52, cabin = Vector2.new(0.58, -0.1), wheel = 2.2 },
		ParkedPickup = { size = Vector3.new(7, 6.4, 18), body = 0.55, cabin = Vector2.new(0.3, 0.08), wheel = 3 },
		ParkedCoupe = { size = Vector3.new(6.6, 4.2, 14.8), body = 0.55, cabin = Vector2.new(0.4, -0.06), wheel = 2.4 },
		ParkedVan = { size = Vector3.new(7, 7.2, 17), body = 0.42, cabin = Vector2.new(0.84, -0.06), wheel = 2.6 },
	} :: { [string]: CarShape },
	-- Paints, in the order a missing variant falls back through (the planned one first, then on down the list).
	-- Miami's streets run white, then black and silver, with blue and red the odd ones out. Seen in Studio 2026-10-26:
	-- white and silver read the same in the sun, so at 3.2 / 2.4 / 2.4 / 0.9 / 1 lots looked all white from above;
	-- silver is drawn less and blue and red more, and two neighbours never share a paint (Parking). The street-level
	-- roast (2026-10-26, point 8) still saw mostly white and silver crossovers, so about 40 % of the draws are red or
	-- blue now (a missing variant falls back to the next paint, which takes some of them back to white).
	colours = {
		{ name = "White", color = rgb(236, 238, 236), weight = 2 },
		{ name = "Black", color = rgb(26, 28, 32), weight = 2 },
		{ name = "Silver", color = rgb(170, 176, 182), weight = 1 },
		{ name = "Red", color = rgb(170, 30, 36), weight = 1.6 },
		{ name = "Blue", color = rgb(36, 76, 150), weight = 1.9 },
	} :: { CarColour },
	standIn = { glass = rgb(30, 38, 46), tyre = rgb(24, 24, 26) },

	-- Which shapes park where.
	mixes = {
		drive = {
			ParkedSUV = 3,
			ParkedSedan = 2.5,
			ParkedPickup = 1.2,
			ParkedHatch = 1.2,
			ParkedCoupe = 1,
			ParkedVan = 0.6,
		},
		hotel = { ParkedSedan = 3, ParkedSUV = 3, ParkedCoupe = 2, ParkedVan = 1 },
		carPark = { ParkedPickup = 2, ParkedSedan = 2, ParkedSUV = 2, ParkedHatch = 1.2, ParkedCoupe = 1 },
		lot = { ParkedSedan = 3, ParkedSUV = 3, ParkedHatch = 2, ParkedPickup = 1.4, ParkedCoupe = 1, ParkedVan = 0.8 },
		curb = { ParkedSedan = 3, ParkedHatch = 2, ParkedSUV = 2, ParkedCoupe = 1 },
	} :: { [string]: Mix },

	-- The invisible box a car or a player bumps into: the car's size less `inset` on each side, from `lift` over the
	-- ground to `top` (share of the height), so the mirrors and the roof's curve stay soft. The lift clears a lot's
	-- wheel stops (0.5 high: Dev/City/LotKit stops) where a nose or a tail hangs over them.
	box = { inset = 0.15, lift = 0.6, top = 0.94 },

	-- Room every car keeps: `clearance` studs from anything it could touch, at least (walls, posts, planters, the next
	-- car, the grid's roads and pads). A part over the roof by at least `headroom` is a canopy, not in the way. A flat
	-- opaque part no taller than `floorTop` is paving it may stand on; a car on paving higher than `flatStep` must
	-- stand wholly on it (no wheel off a kerb). `groundLift` is the lowest a car stands: the paved lot's top
	-- (Dev/MapBuilder TUNING.lotThickness).
	clearance = 0.5,
	headroom = 0.6,
	floorTop = 0.45,
	flatStep = 0.2,
	groundLift = 0.1,

	-- Suburb driveways: every "Drive" a site draws (a block on its plot running from the street to its garage). A car
	-- stands on `share` of them, nose to the garage (or backed in, `noseOut` of the time), pulled in as far as the house
	-- lets it (up to `beyond` studs past the drive's end, under a carport or a cantilever), its tail at most `overhang`
	-- past the plot's front line and never on the sidewalk. A drive too short for the drawn shape takes a shorter one.
	drives = { share = 0.72, noseOut = 0.25, beyond = 4, overhang = 1.5, step = 0.5 },

	-- Drop-off bays: a car pulled up along the front of a hotel on the beach row (in these zones, of these
	-- archetypes), nose the way traffic runs on its side of the road, on the forecourt within `depth` studs of the front
	-- line (its side at most `overhang` past it), under the porte-cochère when there is one, else nearest the entrance
	-- (the site's middle). `share` of the hotels get one; a site at least `second.width` wide gets a second car
	-- `second.share` of the time. A café terrace, its balustrade and umbrellas are in the way, so most Deco hotels with a
	-- terrace to the line get none: only those with a forecourt do. Round drop-off drives under a tower's canopy (a
	-- disc named "Drive") take a car the same way, in any zone.
	-- Off since the street-level roast (2026-10-26, point 1): a forecourt and a tower's disc meet the road only across
	-- a kerb, a grass strip and the sidewalk, so the cars there stood where no car could have driven. share 0 parks
	-- none (tests/CityStreet.spec still runs the pass on its fixture); Dev/MapCheck fails any parked car that isn't on
	-- a parking surface (`surfaces` below).
	dropOff = {
		zones = { lakefront = true } :: { [string]: boolean },
		archetypes = {
			deco_stripe_hotel = true,
			neon_fin_hotel = true,
			sign_tower_prow_hotel = true,
			deco_porthole_highrise = true,
			streamline_round_corner = true,
			corner_spire_hotel = true,
			lighthouse_corner_hotel = true,
			finned_tower_hotel = true,
			domed_cupola_hotel = true,
			curved_resort_slab = true,
			mimo_truss_motel = true,
		} :: { [string]: boolean },
		share = 0,
		second = { width = 70, share = 0.45 },
		depth = 16,
		overhang = 1,
		margin = 1, -- studs from the site's sides
		step = 1, -- studs between the spots tried along the front (half of it across)
		canopyTop = 24, -- a canopy over a bay has its underside lower than this
	},

	-- Feature car parks (a MapLayout feature's "CarPark" apron: the diner's): a row of nose-in spaces along the
	-- building, `pitch` studs apart, at least `margin` from the apron's ends, `share` of them taken, each nosed in as
	-- far as the building allows; a space whose car would stand more than `slide` studs out of line stays empty. The way
	-- to a door (a part named "...Door") stays clear `doorGap` studs out from it and either side.
	carParks = {
		names = { CarPark = true } :: { [string]: boolean },
		pitch = 9.5,
		margin = 3,
		share = 0.7,
		slide = 2,
		doorGap = 4,
	},

	-- Kerbside parking, only on these kinds of road (quiet side streets), and only where the shoulder outside the
	-- outermost lane (Config/RoadGraph styles[kind].shoulder) is at least a car's width plus `kerbGap`, so a parked car
	-- leaves its lane wholly clear. No road in the county has that today (a street's shoulder is 3 studs, the narrowest
	-- car 6.4), so this parks none until a road is widened for it. Cars stand every `spacing` studs on `share` of the
	-- spots, `junction` studs clear of either end's junction.
	curb = {
		kinds = { street = true } :: { [string]: boolean },
		kerbGap = 0.4,
		spacing = 24,
		junction = 40,
		share = 0.5,
	},

	-- Surface-lot stalls (a lot archetype's stalls(site), filled by Parking.plan; or handed to Parking.fillStalls): a
	-- stall's default size (width, length), `share` of them taken, `noseOut` of those backed in, each car `noseGap` from
	-- the stall's head and set off a little (`jitter`: studs across, degrees of yaw) so a row doesn't look stamped.
	-- The dealership's and used lot's spaces are not stalls: every one is a sale pad or a spawn pad (gameplay), so they
	-- get none.
	stalls = {
		size = Vector2.new(9.8, 19.5),
		share = 0.6,
		noseOut = 0.2,
		noseGap = 0.8,
		jitter = { side = 0.35, yaw = 3 }, -- the roast (point 8): turned a few degrees each, not stamped
		budgetParts = 400, -- the most parts one fillStalls call adds unless its caller hands it a shared ledger
	},

	-- Parts the parked cars may add (each car is 2: its mesh and its box): Parking.plan's drives, drop-offs, car parks
	-- and kerbs keep to planParts; the lots' stalls to lotParts, the share taken lowered evenly over every lot when
	-- stalls.share of them would pass it (so no lot is left empty for another to be full). Every one counts against
	-- Config/Environment budget.mapParts and the phone's inViewParts gate.
	-- The drop-offs' parts went to the lots (street-level roast, 2026-10-26).
	budget = { planParts = 244, lotParts = 316 },

	-- What a parked car may stand on (Parking.offSurface, Dev/MapCheck): the middle of every car lies over a part whose
	-- name ends in one of these: a site's drive, a feature's car park apron, a lot's asphalt (its striped stalls).
	surfaces = { "Drive", "CarPark", "Asphalt" },
}

---------------------------------------------------------------------------------------------------------------
-- Frontage
---------------------------------------------------------------------------------------------------------------

-- Shop fronts and café terraces at street level (Dev/City/Street/Frontage), on the commercial sites' forecourts:
-- between the front line and the wall their ground floor shows the street. Nothing goes past the front line, so every
-- sidewalk keeps its whole width and no road, crosswalk, pad or gameplay spot is touched.

-- One shop front's look: its awning (colour and cut: a sloped fabric, the same with white stripes, or a flat canopy),
-- its sign (a fascia board over the awning, or a blade standing out from the wall at the shop's end) with its board and
-- letters, the window frame's lines, and the night-light kind a blade glows in.
export type ShopLook = {
	awning: Color3,
	cut: "slope" | "striped" | "flat",
	sign: "fascia" | "blade",
	board: Color3,
	letters: Color3,
	frame: Color3,
	neon: string, -- Config/Environment nightLights.kinds
}

-- A kind of shop: the names its signs draw from (invented: never a real business), their font (none on Davis's banned
-- list), the colour its window glows at night (as dim as the city's lit windows, so it stays under the bloom), and the
-- short trade word a blade sign stacks letter over letter (a plain word, never a business: shop.blade.maxWord at most).
export type ShopKind = { names: { string }, font: Enum.Font, interior: Color3, word: string }

-- A district's street front, chosen by the zone a site stands in (a beach type on River Avenue takes the suburbs').
export type FrontDistrict = {
	share: number, -- of its sites, a roll on each site's seed dresses about this share (the rest stay as drawn)
	terraces: number, -- of the dressed sites, this share also tries a café terrace
	shops: number, -- shop fronts on one site, at most
	kinds: { string }, -- the shop kinds it draws (keys of frontage.kinds)
	looks: { ShopLook }, -- at least 7, so neighbours never share one (frontage.lookStep)
	cafes: { string }, -- the café set props its terraces draw from (Config/CityProps)
	planter: Color3, -- the planters' boxes
}

local white = rgb(250, 250, 246)
local cream = rgb(240, 232, 210)
local iron = rgb(40, 40, 42)

local frontage = {
	-- Archetypes whose ground floor is no shop street keep it as their module drew it: homes, the civic one-offs, the
	-- market and the arena (shops of their own), the port, the motels' pool courts and the resort's drive.
	skip = {
		mosaic_townhouse_row = true,
		mimo_garden_apartment = true,
		red_ziggurat_lowrise = true,
		coral_rock_cottage = true,
		mediterranean_villa = true,
		pink_layered_house = true,
		tropical_modern_villa = true,
		veranda_raised_house = true,
		cupola_bell_tower = true,
		domed_sanctuary = true,
		stepped_crown_courthouse = true,
		bayfront_arena = true,
		harbor_market_pavilions = true,
		port_crane_yard = true,
		lighthouse_water_tower = true,
		folded_roof_lake_stadium = true,
		mimo_truss_motel = true,
		curved_resort_slab = true,
		-- The open plots' lot types (Config/CityLots types): no wall to dress, and the lot pass measures each lot by
		-- building it.
		construction_site = true,
		food_truck_court = true,
		outdoor_market = true,
		pocket_park = true,
		pocket_plaza = true,
		sports_court = true,
		surface_parking = true,
	} :: { [string]: boolean },

	-- Neighbouring shops never share a look: a shop's look is picked by where it stands along its road, in steps of
	-- lookStep studs (less than any two shops' centres are apart), from a district's list of at least 7.
	lookStep = 14,

	kinds = {
		cafe = {
			names = { "CAFE VOLTARA", "THE COPPER COIL", "AMPERINA", "CAFE SOLENOID", "CAFECITO CIRCUIT" },
			font = Enum.Font.JosefinSans,
			interior = rgb(122, 86, 48),
			word = "CAFE",
		},
		juice = {
			names = { "MANGO SURGE", "CITRUS COIL", "PULP & POWER", "GREEN SPARK", "SQUEEZE CURRENT" },
			font = Enum.Font.LuckiestGuy,
			interior = rgb(118, 78, 96),
			word = "JUICE",
		},
		bakery = {
			names = { "PAN DE VOLTIO", "RISING CURRENT", "GUAVA & GRAIN", "THE WARM COIL", "OHM OVEN" },
			font = Enum.Font.Bodoni,
			interior = rgb(126, 100, 56),
			word = "PAN",
		},
		surf = {
			names = { "SWELL & SPARK", "TIDECELL SURF", "OFFSHORE AMP", "SWELLCELL", "LONGBOARD LUMEN" },
			font = Enum.Font.Bangers,
			interior = rgb(54, 110, 122),
			word = "SURF",
		},
		gallery = {
			names = { "GALLERY OHMS", "PRISM ROOM", "CANVAS CURRENT", "GALERIA ARCO", "THE INSULATOR" },
			font = Enum.Font.Michroma,
			interior = rgb(106, 108, 116),
			word = "ART",
		},
		pharmacy = {
			names = { "COUNTY PHARMACY", "BAYLIGHT PHARMACY", "CORAL CROSS RX", "PALMWELL PHARMACY" },
			font = Enum.Font.Oswald,
			interior = rgb(84, 120, 108),
			word = "RX",
		},
		barber = {
			names = { "STATIC CUTS", "BLADE & BOLT", "FADE CIRCUIT", "LIVE WIRE BARBERS" },
			font = Enum.Font.SpecialElite,
			interior = rgb(124, 66, 60),
			word = "BARBER",
		},
		taco = {
			names = { "TACOS VOLTIO", "EL VOLTAJE", "TACO DYNAMO", "TAQUERIA KILOVATIO" },
			font = Enum.Font.PermanentMarker,
			interior = rgb(126, 84, 40),
			word = "TACOS",
		},
		helados = {
			names = { "HELADOS CORRIENTE", "SCOOP SURGE", "COCONUT COIL", "POLAR AMP" },
			font = Enum.Font.Kalam,
			interior = rgb(112, 86, 120),
			word = "HELADO",
		},
		boutique = {
			names = { "LINEN & LUMEN", "MAISON WATT", "CORAL THREAD", "AMPLE & CO" },
			font = Enum.Font.Fondamento,
			interior = rgb(120, 96, 88),
			word = "MODA",
		},
	} :: { [string]: ShopKind },

	districts = {
		-- Crisp and darker downtown: charcoal, navy, teal, white, with coral, lemon and red for punch.
		downtown = {
			share = 0.75,
			terraces = 0.45,
			shops = 2,
			kinds = { "cafe", "juice", "bakery", "pharmacy", "barber", "taco", "boutique", "gallery" },
			cafes = { "CafeSetWhite", "CafeSetMint" },
			planter = rgb(214, 210, 202),
			looks = {
				{
					awning = rgb(52, 56, 62),
					cut = "flat",
					sign = "fascia",
					board = rgb(40, 44, 50),
					letters = white,
					frame = rgb(196, 202, 208),
					neon = "neonCyan",
				},
				{
					awning = rgb(36, 58, 92),
					cut = "slope",
					sign = "blade",
					board = white,
					letters = rgb(36, 58, 92),
					frame = white,
					neon = "neonBlue",
				},
				{
					awning = rgb(40, 140, 150),
					cut = "flat",
					sign = "fascia",
					board = white,
					letters = rgb(28, 104, 112),
					frame = rgb(52, 56, 62),
					neon = "neonCyan",
				},
				{
					awning = rgb(230, 108, 92),
					cut = "slope",
					sign = "fascia",
					board = rgb(230, 108, 92),
					letters = white,
					frame = white,
					neon = "neonPink",
				},
				{
					awning = rgb(246, 246, 242),
					cut = "flat",
					sign = "blade",
					board = rgb(40, 44, 50),
					letters = white,
					frame = rgb(52, 56, 62),
					neon = "neonAmber",
				},
				{
					awning = rgb(236, 192, 72),
					cut = "striped",
					sign = "fascia",
					board = rgb(40, 44, 50),
					letters = rgb(236, 192, 72),
					frame = rgb(52, 56, 62),
					neon = "neonAmber",
				},
				{
					awning = rgb(46, 96, 78),
					cut = "slope",
					sign = "blade",
					board = rgb(46, 96, 78),
					letters = cream,
					frame = white,
					neon = "neonCyan",
				},
				{
					awning = rgb(196, 52, 48),
					cut = "striped",
					sign = "fascia",
					board = white,
					letters = rgb(196, 52, 48),
					frame = rgb(52, 56, 62),
					neon = "neonPink",
				},
			},
		},
		-- The beach's pastels (Config/City palettes.deco), white boards and deep letters.
		beach = {
			share = 0.85,
			terraces = 0.6,
			shops = 2,
			kinds = { "cafe", "surf", "juice", "helados", "taco", "boutique", "pharmacy" },
			cafes = { "CafeSetPink", "CafeSetMint", "CafeSetWhite" },
			planter = rgb(236, 226, 212),
			looks = {
				{
					awning = rgb(255, 160, 172),
					cut = "striped",
					sign = "fascia",
					board = white,
					letters = rgb(214, 84, 120),
					frame = white,
					neon = "neonPink",
				},
				{
					awning = rgb(140, 224, 196),
					cut = "slope",
					sign = "blade",
					board = white,
					letters = rgb(40, 150, 160),
					frame = white,
					neon = "neonCyan",
				},
				{
					awning = rgb(255, 210, 130),
					cut = "striped",
					sign = "fascia",
					board = white,
					letters = rgb(40, 80, 150),
					frame = white,
					neon = "neonAmber",
				},
				{
					awning = rgb(190, 160, 236),
					cut = "slope",
					sign = "fascia",
					board = rgb(190, 160, 236),
					letters = rgb(70, 46, 130),
					frame = white,
					neon = "neonViolet",
				},
				{
					awning = rgb(255, 170, 120),
					cut = "striped",
					sign = "blade",
					board = white,
					letters = rgb(214, 96, 70),
					frame = white,
					neon = "neonPink",
				},
				{
					awning = rgb(120, 200, 232),
					cut = "slope",
					sign = "fascia",
					board = rgb(120, 200, 232),
					letters = rgb(24, 56, 104),
					frame = white,
					neon = "neonCyan",
				},
				{
					awning = rgb(120, 206, 214),
					cut = "flat",
					sign = "blade",
					board = rgb(120, 206, 214),
					letters = rgb(16, 84, 94),
					frame = white,
					neon = "neonCyan",
				},
				{
					awning = rgb(238, 110, 96),
					cut = "striped",
					sign = "fascia",
					board = white,
					letters = rgb(40, 150, 160),
					frame = white,
					neon = "neonPink",
				},
			},
		},
		-- The arts district's loud flats on black and white.
		arts = {
			share = 0.9,
			terraces = 0.5,
			shops = 2,
			kinds = { "gallery", "cafe", "taco", "barber", "boutique", "juice", "bakery" },
			cafes = { "CafeSetPink", "CafeSetWhite" },
			planter = rgb(40, 42, 46),
			looks = {
				{
					awning = rgb(250, 60, 150),
					cut = "flat",
					sign = "fascia",
					board = rgb(24, 24, 28),
					letters = rgb(250, 60, 150),
					frame = rgb(24, 24, 28),
					neon = "neonPink",
				},
				{
					awning = rgb(40, 120, 250),
					cut = "slope",
					sign = "blade",
					board = rgb(255, 214, 0),
					letters = rgb(24, 24, 28),
					frame = rgb(24, 24, 28),
					neon = "neonBlue",
				},
				{
					awning = rgb(255, 214, 0),
					cut = "striped",
					sign = "fascia",
					board = rgb(24, 24, 28),
					letters = rgb(255, 214, 0),
					frame = rgb(24, 24, 28),
					neon = "neonAmber",
				},
				{
					awning = rgb(255, 120, 30),
					cut = "slope",
					sign = "fascia",
					board = white,
					letters = rgb(24, 24, 28),
					frame = rgb(24, 24, 28),
					neon = "neonAmber",
				},
				{
					awning = rgb(130, 60, 220),
					cut = "flat",
					sign = "blade",
					board = white,
					letters = rgb(130, 60, 220),
					frame = white,
					neon = "neonViolet",
				},
				{
					awning = rgb(0, 210, 220),
					cut = "striped",
					sign = "fascia",
					board = rgb(24, 24, 28),
					letters = rgb(0, 210, 220),
					frame = rgb(24, 24, 28),
					neon = "neonCyan",
				},
				{
					awning = rgb(150, 230, 40),
					cut = "slope",
					sign = "blade",
					board = rgb(24, 24, 28),
					letters = rgb(150, 230, 40),
					frame = rgb(24, 24, 28),
					neon = "neonCyan",
				},
				{
					awning = rgb(30, 30, 34),
					cut = "flat",
					sign = "fascia",
					board = rgb(250, 60, 150),
					letters = white,
					frame = rgb(30, 30, 34),
					neon = "neonPink",
				},
			},
		},
		-- River Avenue's Mediterranean: terracotta, sage, ochre, forest, wine, under cream boards and iron frames.
		suburbs = {
			share = 0.8,
			terraces = 0.4,
			shops = 2,
			kinds = { "bakery", "cafe", "pharmacy", "barber", "boutique", "helados", "gallery" },
			cafes = { "CafeSetWhite", "CafeSetMint" },
			planter = rgb(196, 120, 84),
			looks = {
				{
					awning = rgb(196, 120, 84),
					cut = "striped",
					sign = "fascia",
					board = cream,
					letters = rgb(140, 70, 44),
					frame = iron,
					neon = "neonAmber",
				},
				{
					awning = rgb(150, 170, 130),
					cut = "slope",
					sign = "blade",
					board = cream,
					letters = rgb(46, 84, 58),
					frame = iron,
					neon = "neonAmber",
				},
				{
					awning = rgb(214, 180, 120),
					cut = "striped",
					sign = "fascia",
					board = iron,
					letters = cream,
					frame = iron,
					neon = "neonAmber",
				},
				{
					awning = rgb(60, 96, 70),
					cut = "slope",
					sign = "fascia",
					board = cream,
					letters = rgb(46, 84, 58),
					frame = cream,
					neon = "neonAmber",
				},
				{
					awning = rgb(236, 224, 196),
					cut = "flat",
					sign = "blade",
					board = rgb(196, 120, 84),
					letters = cream,
					frame = iron,
					neon = "neonPink",
				},
				{
					awning = rgb(130, 50, 60),
					cut = "striped",
					sign = "fascia",
					board = cream,
					letters = rgb(130, 50, 60),
					frame = iron,
					neon = "neonPink",
				},
				{
					awning = rgb(110, 120, 70),
					cut = "slope",
					sign = "fascia",
					board = cream,
					letters = rgb(70, 78, 40),
					frame = iron,
					neon = "neonAmber",
				},
				{
					awning = rgb(40, 60, 90),
					cut = "striped",
					sign = "blade",
					board = cream,
					letters = rgb(40, 60, 90),
					frame = iron,
					neon = "neonBlue",
				},
			},
		},
	} :: { [string]: FrontDistrict },

	-- Reading a site's street front (Street/FrontageScan): every part as its box in the site's own frame.
	scan = {
		step = 1, -- studs between the samples taken along the front
		ground = 0.1, -- the paved lot's top (Dev/MapBuilder TUNING.lotThickness): the floor where nothing higher is
		floorTop = 1.6, -- a part no higher than this is ground underfoot (a terrace's slab, a plinth), not in the way
		reach = 1.8, -- a wall comes down to within this of the ground
		setback = { min = 2, max = 14 }, -- a wall carries shops this far behind the front line, at least and at most
		jitter = 0.6, -- a run of wall keeps within this of one plane
		side = 1.2, -- shops and terraces keep this far in from the site's sides...
		front = 0.5, -- ...and this far behind its front line
		eps = 0.02, -- two boxes are in each other's way when they overlap by more than this
		-- A low part is ground underfoot only when it is paving: never water or a pool, a lawn, a drive or a ramp (by its
		-- material, or a word in its name). Those stay in the way, so no table stands in a pool or on a drop-off drive.
		notFloor = {
			materials = {
				Enum.Material.Glass,
				Enum.Material.Water,
				Enum.Material.Neon,
				Enum.Material.Grass,
				Enum.Material.LeafyGrass,
				Enum.Material.Ground,
				Enum.Material.Mud,
			},
			names = { "Pool", "Drive", "Ramp", "Lawn", "Water", "Grass" },
		},
	},

	shop = {
		width = { min = 12, target = 16, max = 22 },
		gap = 3.4, -- between two shops on one wall: a pier, with a planter in front of it
		margin = 0.8, -- in from the ends of a run of wall
		top = 12.8, -- a wall rises at least this far over the floor to carry a shop (its sign goes on it)
		clear = 13.2, -- a shop slot keeps the band in front of its wall clear this high over the floor top
		window = {
			sill = 0.6, -- the glass from this over the floor...
			head = 8.4, -- ...to this
			inset = 0.6, -- in from the shop's ends
			proud = 0.3, -- out of the wall...
			embed = 0.15, -- ...and into it, so no seam shows
			pane = 5, -- studs a pane of the frame overlay (City.textures.windowBold: stall riser, transom, mullions)
			glass = rgb(34, 52, 64),
			reflectance = 0.15,
		},
		awning = {
			high = 10.4, -- its top edge on the wall, over the floor...
			drop = 1.4, -- ...falling this much to its front edge
			depth = 3.2, -- out from the wall at most (less on a shallow forecourt, down to minDepth)
			minDepth = 1.6,
			thick = 0.3,
			flat = { y = 9.8, thick = 0.5, depth = 2.6 }, -- a flat canopy: its underside, thickness and reach
			air = 15, -- nothing may hang over an awning lower than this over the floor (a porch roof, a canopy)
			stripes = "rbxassetid://83119463084846", -- white bars half a tile wide (Config/CityScenery crosswalks.image)
			stripeTile = 2.4,
			stripeColor = rgb(250, 250, 246),
		},
		fascia = { low = 10.8, high = 12.8, thick = 0.35, perChar = 0.95, min = 7, inset = 0.6 },
		-- A blade: a tall board standing out at the shop's end, its trade word stacked letter over letter (the Deco beach
		-- row's way; a shop's own name on a 2-stud board would be too small to read), beside a fascia with the name. Only on a
		-- wall that rises past its top.
		blade = { low = 9.4, high = 15.8, out = 2.7, back = 0.3, thick = 0.4, maxWord = 6, room = 1.8 },
		planter = { size = Vector3.new(2.4, 1.8, 2.4), plant = 3.2, out = 0.6 }, -- out: its back off the wall
	},

	terrace = {
		depth = 16, -- a row of tables stands within this of the front line
		step = 0.5, -- studs between the rows tried, front to back
		gap = 1.2, -- between two tables of a row
		count = { min = 2, max = 4 },
		-- A table stands only where the street sees it: in front of it, between `low` and `high` over the ground, at
		-- least `open` of its width is clear (a building's 4-stud name wall would hide a café; a hotel's waist-high
		-- balustrade, 3.5 to its coping, or a column won't).
		sight = { low = 3.6, high = 4.4, open = 0.6 },
		bistro = "BistroPair", -- the small table and two chairs (Config/CityProps), where a café set's umbrella won't go
		-- One invisible box round the row, which a car or a player bumps into: from `lift` over the floor to `top`, and
		-- at least `front` behind the front line (so 2.9 off any streetlight's post).
		collider = { lift = 0.05, top = 3, front = 3 },
		lights = {
			post = 0.35, -- two posts at the row's ends, this thick...
			top = 10.2, -- ...and this tall over the floor
			out = 1, -- past the row's ends
			over = 0.8, -- the strings' lowest point clears the tables by this...
			sag = 2, -- ...and hangs this far under the posts' tops (a swag you can see)
			wire = 0.14, -- thin, so by night it reads as a string of bulbs, not a tube
			kind = "neonAmber", -- warm bulbs at night; a dark cable by day
			cable = rgb(58, 58, 60),
			postColor = rgb(48, 50, 54),
			-- The light the swag casts on the tables at night (a PointLight, no shadows).
			glow = { brightness = 1.6, range = 20, color = rgb(255, 196, 132) },
		},
		planter = { size = Vector3.new(2.6, 1.8, 2.6), plant = 3.4, gap = 0.8 }, -- one at each end, past the posts
	},

	-- Parts all the frontage may add, and night lights (tests/CityStreet.spec holds the county to both; the building
	-- night lights of Config/City budgets count them too).
	budget = { parts = 1000, nightLights = 260 },
}

return {
	parking = parking,
	frontage = frontage,
}
