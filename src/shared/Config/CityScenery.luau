--!strict
-- The beach city's scenery (docs/city/SCENERY.md; docs/city/CITY_PLAN.md §3.2, §6 and §9; docs/city/ARCHETYPES.md
-- C08 and C09). Dev/City/Scenery plans it and Dev/MapBuilder builds it, through the same placement grid that keeps the
-- trees off the roads, so nothing here moves a road, lot, pad or gameplay spot:
--   palms        the three palm species: the template each one clones (ServerStorage.CityAssets.Palms.<species>), the
--                size it is scaled to, the trunk a car hits, and the parts-only stand-in built while a template is missing
--   streetPalms  palms in the sidewalks and on the verges, by road kind and zone
--   beach        the sand band of Lakefront Park (MapLayout park `beach.park`): the promenade and its low wavy wall,
--                coconut palms, dunes, lifeguard stands, boardwalks, umbrellas and loungers, showers, nets, benches and
--                globe lamps
--   lifeguard    the lifeguard stands (C08): sizes and colour schemes
--   water        the stone coping on the shores without a beach; and the bay's old part look (a pale sandy bed, bands
--                of colour from the shore out, a foam line), built only while Config/Water.terrain is off
--   causeway     the lake bridge (C09): round white piers with caps, shallow arched spans, a white balustrade with a lit
--                fascia, acorn lamps along it, the steel arches white by day and in a colour gradient at night
--   lamps        streetlight styles by road
--   furniture    bus shelters, benches and planters
--   crosswalks   zebra crossings at the junctions of the avenues
--   townSquare   the downtown square's fountain, its palm allée and benches
--   budget       how many parts the scenery may add, and the phone's in-view gate
--   bayfrontPark the park on the lawn between downtown and the beach: promenade, fountain plaza, bandshell lawn,
--                playground, sculpture garden, food trucks, curving paths, palm groves, lamps (its own budget)
-- Real places are inspiration only: their names stay in docs/city.

local rgb = Color3.fromRGB

-- The parts-only stand-in for a palm (built while its template is missing; docs/city/SCENERY.md §1 says why a mesh
-- reads better). Shares of the palm's height, studs at scale 1.
export type PalmFallback = {
	trunk: { diameter: number, foot: number, top: number, color: Color3, material: Enum.Material },
	shaft: { diameter: number, top: number, color: Color3 }?, -- a royal palm's green crownshaft
	head: { diameter: number, color: Color3 }?, -- a sabal's round fan crown, on top of its trunk
	fronds: {
		count: number,
		length: number,
		width: number,
		thick: number,
		pitch: number, -- degrees above the horizontal (negative droops)
		color: Color3,
	},
}

export type PalmSpecies = {
	height: number, -- studs tall at scale 1: the template is scaled to it, whatever size it was made at
	scale: { number }, -- each palm drawn between these
	lean: { number }, -- degrees of extra tilt drawn per palm, on top of the template's own shape
	baseLean: number, -- degrees: how far the template's trunk itself leans (the collider and the stand-in follow it)
	crown: number, -- the crown's spread at scale 1
	crownFrom: number, -- share of the height where the crown's box starts...
	crownTo: number, -- ...and ends
	collider: Vector2, -- the trunk a car hits: diameter, height (cars pass through the crown)
	sink: number?, -- how far the foot stands into the ground (palms.sink when nil)
	fallback: PalmFallback,
}

-- Palms in the sidewalks and verges of one kind of road in one zone (a road matches when either end node is in the
-- zone). Each side gets a palm every `spacing` studs, `offset` studs out from the kerb (the road's edge), or `verge`
-- studs out where the road has no sidewalk; `stagger` shifts one side by half a spacing; `sides` "lake" plants only
-- the side facing Cedar Lake. A bridge's palms stand on the ground beside its deck, only off the water. `leanOut`
-- turns each palm's lean away from the road (give or take `leanSpread` degrees), so a leaning crown hangs over the verge
-- and the water instead of the carriageway.
export type StreetPalmRule = {
	zone: string,
	kind: string,
	species: string,
	spacing: number,
	offset: number,
	verge: number,
	stagger: boolean,
	sides: "both" | "lake",
	scale: { number }?,
	leanOut: boolean?,
	leanSpread: number?,
}

-- One lifeguard stand's colours: its body, an accent (roof, stripe, ramp rail) and a trim.
export type StandScheme = { body: Color3, accent: Color3, trim: Color3 }

-- A streetlight style (Dev/MapBuilder addStreetlights): a pole, an optional arm out over the road and a head (a
-- night light). `globe` makes the head a ball on top of the pole.
export type LampStyle = {
	pole: Vector2, -- diameter, height
	poleColor: Color3,
	poleMaterial: Enum.Material,
	arm: Vector3?, -- across, up, out over the road
	head: Vector3, -- across, up, along its reach (a globe uses X as its diameter)
	headColor: Color3,
	reach: number, -- the head's centre stands this far out from the pole, toward the road
	globe: boolean,
}

-- A clump of palms on the bayfront park's lawns: `count` palms tried within `radius` of `at`, and `shrubs` flowering
-- shrubs at its foot.
export type ParkGrove = { at: Vector2, count: number, radius: number, shrubs: number }

local CityScenery = {
	-- Colours shared by the pieces below (docs/city/SCENERY.md §8, pushed past the paint chip so the sky light
	-- doesn't grey them).
	palette = {
		white = rgb(246, 244, 238),
		concrete = rgb(236, 234, 228), -- the causeway's white concrete
		coral = rgb(214, 196, 160), -- coral stone: walls, coping
		terrazzo = rgb(236, 226, 212),
		wood = rgb(176, 136, 96),
		seaBlue = rgb(60, 150, 190),
		pink = rgb(255, 160, 172),
		mint = rgb(140, 224, 196),
		aqua = rgb(120, 200, 232),
		butter = rgb(255, 210, 130),
		lilac = rgb(190, 160, 236),
		peach = rgb(255, 170, 120),
		teal = rgb(40, 150, 160),
		dark = rgb(48, 52, 58),
		glass = rgb(40, 70, 86),
	},

	palms = {
		-- ServerStorage.CityAssets.Palms.<species>: a MeshPart or a Model (or a Folder of them, one per variant), made
		-- in Studio. Its pivot is the centre of the trunk's foot on the ground, +Y up, and a leaning palm leans toward its
		-- front (-Z). Every copy is a Clone() of it, so one mesh draws as one instanced call. The three in the place
		-- (docs/city/SCENERY.md §1 has their asset ids) are generated meshes wearing a SurfaceAppearance whose colour
		-- map's alpha cuts the broad generated leaves into feathery leaflets; the sizes below are measured off them.
		templateRoot = { "CityAssets", "Palms" },
		variants = 2, -- variants a palm draws from (a template with fewer repeats them)
		sink = 0.4, -- the foot stands this far into the ground
		species = {
			-- Tall, straight, pale grey column trunks with a green crownshaft: the avenues, the causeway approaches,
			-- the downtown square.
			royal = {
				height = 50,
				scale = { 0.88, 1.12 },
				lean = { 0, 2 },
				baseLean = 0,
				crown = 30,
				crownFrom = 0.56,
				crownTo = 1.0,
				collider = Vector2.new(2.6, 12),
				fallback = {
					trunk = {
						diameter = 2.1,
						foot = 3,
						top = 0.72,
						color = rgb(200, 196, 186),
						material = Enum.Material.Concrete,
					},
					shaft = { diameter = 1.8, top = 0.84, color = rgb(104, 150, 84) },
					fronds = {
						count = 8,
						length = 13,
						width = 2.4,
						thick = 0.25,
						pitch = -14,
						color = rgb(66, 122, 60),
					},
				},
			} :: PalmSpecies,
			-- Curved, leaning trunks: the beach, the lake ring, pool edges, leaning toward the water. The template's
			-- trunk leans about 30 degrees at its foot and curves up, its drooping crown hanging out over the lean;
			-- `lean` stands some of them up a little straighter and tips others further.
			coconut = {
				height = 34,
				scale = { 0.85, 1.15 },
				lean = { -8, 4 },
				baseLean = 33,
				crown = 25,
				crownFrom = 0.36,
				crownTo = 1.15,
				collider = Vector2.new(2.4, 10),
				sink = 1.2, -- deep enough to bury the slanted cut of its leaning foot
				fallback = {
					trunk = {
						diameter = 1.6,
						foot = 2.2,
						top = 0.97,
						color = rgb(150, 128, 98),
						material = Enum.Material.Wood,
					},
					fronds = {
						count = 8,
						length = 11.5,
						width = 2.2,
						thick = 0.25,
						pitch = -32,
						color = rgb(78, 132, 58),
					},
				},
			} :: PalmSpecies,
			-- Shorter, rough "boot" trunks under a round fan crown: the suburbs, clusters, medians of green.
			sabal = {
				height = 26,
				scale = { 0.85, 1.2 },
				lean = { 0, 4 },
				baseLean = 0,
				crown = 19,
				crownFrom = 0.4,
				crownTo = 1.02,
				collider = Vector2.new(2.6, 10),
				fallback = {
					trunk = {
						diameter = 1.9,
						foot = 2.4,
						top = 0.8,
						color = rgb(126, 110, 88),
						material = Enum.Material.Wood,
					},
					head = { diameter = 7, color = rgb(80, 122, 64) },
					fronds = {
						count = 6,
						length = 6,
						width = 3.6,
						thick = 0.3,
						pitch = 22,
						color = rgb(84, 128, 66),
					},
				},
			} :: PalmSpecies,
		} :: { [string]: PalmSpecies },
	},

	streetPalms = {
		-- A street palm's crown may hang over a road only this far above it (docs/city/CITY_PLAN.md §10, check 7;
		-- tests/CityScenery.spec): the rules' sizes and offsets keep to it.
		frondClearance = 20,
		rules = {
			-- The downtown avenues: royal palms in rows on both sidewalks, the palm boulevard (no raised medians: a kerb
			-- in the carriageway would change the driving, docs/city/SCENERY.md §5).
			{
				zone = "cedar_bend",
				kind = "arterial",
				species = "royal",
				spacing = 36,
				offset = 2.8,
				verge = 6,
				stagger = false,
				sides = "both",
				scale = { 0.95, 1.1 },
			},
			-- Downtown streets: a royal palm every so often, alternating sides.
			{
				zone = "cedar_bend",
				kind = "street",
				species = "royal",
				spacing = 120,
				offset = 2.6,
				verge = 6,
				stagger = true,
				sides = "both",
			},
			-- The suburbs: royal palms on the avenue and, further apart, on the streets (a sabal's crown would hang over
			-- the road under 20 studs up).
			{
				zone = "riverside",
				kind = "arterial",
				species = "royal",
				spacing = 54,
				offset = 2.8,
				verge = 6,
				stagger = false,
				sides = "both",
			},
			{
				zone = "riverside",
				kind = "street",
				species = "royal",
				spacing = 130,
				offset = 2.6,
				verge = 6,
				stagger = true,
				sides = "both",
			},
			-- The lake ring: coconut palms on the lake side of the shore roads, leaning out over the water so their drooping
			-- crowns keep off the road.
			{
				zone = "lakefront",
				kind = "street",
				species = "coconut",
				spacing = 58,
				offset = 2.8,
				verge = 5,
				stagger = false,
				sides = "lake",
				scale = { 1, 1.15 },
				leanOut = true,
				leanSpread = 30,
			},
			-- The causeway approaches: royal palms in rows either side, on the ground beside the deck, far enough out that
			-- their crowns (up to about 17 studs across a half, at the largest scale) don't hang over it.
			{
				zone = "lakefront",
				kind = "bridge",
				species = "royal",
				spacing = 40,
				offset = 18,
				verge = 18,
				stagger = false,
				sides = "both",
				scale = { 1, 1.12 },
			},
		} :: { StreetPalmRule },
		endGap = 22, -- no palm within this of a road's cut ends (the junction corners and their crosswalks)
		lightClear = 2.5, -- a trunk keeps this far from a streetlight post and from under its head
		trunkClear = 1, -- the trunk's square grows by this for the checks
	},

	beach = {
		park = "lakefront_beach", -- the MapLayout park that is the sand band (its north edge is the lawn, its south the bay)
		margin = 10, -- nothing within this of the band's ends
		-- The promenade: a terrazzo walk along the lawn edge of the sand (a MaterialVariant on Marble once one exists).
		promenade = {
			from = 2, -- studs south of the band's north edge
			width = 10,
			thick = 0.14,
			color = rgb(236, 226, 212),
			material = Enum.Material.Marble,
			variant = "Terrazzo",
		},
		-- The low wavy coral-stone wall on the sand side of the walk, a zigzag of short runs (decor: the beach stays
		-- open to cars as it is today).
		wall = {
			from = 14, -- its middle line, south of the band's north edge
			amplitude = 2.2, -- the zigzag swings this far either side
			run = 34, -- one straight piece
			height = 1.6,
			thick = 1.1,
			gap = 9, -- an opening this wide at every boardwalk and shower
		},
		-- A row of coconut palms on the lawn along the promenade's land side (negative: north of the band's edge), each
		-- leaning seaward give or take `spread` degrees.
		lawn = { at = -9, every = 46, spread = 70 },
		-- Coconut palms in clumps on the sand behind the dunes, leaning toward the water.
		palms = {
			from = 22,
			to = 40, -- the band's strip they stand in (south of its north edge)
			every = 56, -- a clump every this many studs
			clump = { 1, 3 },
			leanToward = 40, -- degrees either side of straight out to sea
		},
		-- Dunes: low sand ridges (two wedges back to back) with dune grass on top.
		dunes = {
			count = 14,
			at = 48, -- the ridge line, south of the band's north edge
			length = { 14, 24 },
			height = { 1.8, 2.8 },
			depth = 5, -- each slope's run
			color = rgb(232, 218, 186),
			grass = rgb(124, 146, 78),
		},
		standsAt = 92, -- lifeguard stands' centres, south of the band's north edge (their ramps run back toward the dunes)
		stands = 10,
		standSpread = 210, -- studs between neighbouring stands, centred on the band
		bridgeClear = 70, -- nothing but the walk within this of the causeway's centre line
		-- Umbrella-and-lounger sets on the open sand near the water.
		sets = {
			perGap = 3, -- sets between two stands (fewer where they don't fit)
			from = 112,
			to = 136, -- the strip they stand in
			standClear = 30, -- studs from a stand's centre
			canopy = 8, -- the umbrella's span
			height = 7.4, -- its canopy's height up the pole
			tilt = 9, -- degrees each umbrella may tip toward or away from the sea
			loungers = { 2.2, 1.6, 6 }, -- across, how high the backrest rises over the bed, long
		},
		showers = 4,
		nets = 2, -- beach volleyball nets
		benchEvery = 84, -- benches along the walk, facing the sea
		lampEvery = 120, -- globe lamps along the walk (they glow at night; no light of their own)
		boardwalk = { width = 5, thick = 0.3, color = rgb(168, 128, 88) },
		sand = rgb(232, 216, 178), -- the band's ground (Config/MapLayout parks lakefront_beach; tests/CityScenery.spec)
		umbrellas = {
			rgb(255, 160, 172),
			rgb(120, 200, 232),
			rgb(255, 210, 130),
			rgb(246, 244, 238),
			rgb(140, 224, 196),
		},
		loungers = { rgb(246, 244, 238), rgb(60, 150, 190), rgb(255, 170, 120) },
	},

	lifeguard = {
		-- Shapes in turn along the beach, each a different silhouette (docs/city/ARCHETYPES.md C08): a Deco hut with a
		-- rounded sea front and a stepped parapet; a swooping roof of three tilted slabs; a sunburst of fins over a pitched
		-- roof; a round capsule with a dome.
		shapes = { "deco", "swoop", "sunburst", "capsule" },
		-- The platform's top above the sand: 11, up from 7, so the hut stands high on its legs like a real Miami one's
		-- (roast 2026-10-26 point 7: at 7 they read as birdhouses on short posts), with a longer ramp to match.
		deck = 11,
		platform = Vector3.new(14, 0.6, 12),
		hut = Vector3.new(10, 8.5, 7), -- across, tall, deep
		legs = 0.9,
		ramp = { width = 2.6, length = 21 },
		schemes = {
			{ body = rgb(244, 154, 193), accent = rgb(246, 160, 77), trim = rgb(108, 192, 139) },
			{ body = rgb(43, 179, 177), accent = rgb(44, 85, 184), trim = rgb(183, 217, 76) },
			{ body = rgb(150, 110, 200), accent = rgb(200, 182, 226), trim = rgb(248, 199, 163) },
			{ body = rgb(247, 212, 76), accent = rgb(240, 121, 106), trim = rgb(246, 244, 238) },
			{ body = rgb(120, 206, 214), accent = rgb(246, 244, 238), trim = rgb(44, 85, 184) },
			{ body = rgb(190, 160, 236), accent = rgb(140, 224, 196), trim = rgb(246, 244, 238) },
			{ body = rgb(255, 170, 120), accent = rgb(40, 150, 160), trim = rgb(246, 244, 238) },
			{ body = rgb(246, 244, 238), accent = rgb(255, 120, 160), trim = rgb(255, 210, 90) },
		} :: { StandScheme },
		window = rgb(34, 52, 64),
		flag = rgb(236, 64, 52),
	},

	water = {
		-- The lake bed and banks: wet sand, a shade darker than the dry beach, so the bank at the water line reads wet
		-- (roast 2026-10-26 point 6).
		bed = { color = rgb(198, 182, 148), material = Enum.Material.Sand },
		-- The shallows off the beach, from the sand out: each strip reaches `width` studs from the lake's edge (the first
		-- six studs lie under the sand bank, where it meets the water), and each fades into the next through `ramp`. The
		-- last band is the open bay over everything else, deep blue right up to the stone-edged shores. Tested in Studio
		-- (docs/images/city/scenery-*): a see-through Glass sheet read as a swimming pool; nearly solid SmoothPlastic
		-- with a little sky reflection reads as the sea.
		bands = {
			-- Only the first is see-through (the sand shows under the shallows): a see-through strip after it would show
			-- a seam where the solid end of the ramp before it meets it.
			-- 2026-10-26 roast point 6: the old cyan-to-cobalt bands read as a swimming pool; a real Miami bay is green-teal
			-- darkening with depth. Darker than the colour wanted on screen: the high sun and the sky's reflection lift
			-- a water sheet about a third brighter and bluer (seen in Studio).
			{ width = 24, color = rgb(70, 150, 142), transparency = 0.3 }, -- the shallows: green-teal over sand
			{ width = 52, color = rgb(46, 124, 126), transparency = 0 },
			{ width = 90, color = rgb(32, 102, 112), transparency = 0 },
			{ width = 150, color = rgb(22, 80, 98), transparency = 0 },
			{ width = math.huge, color = rgb(16, 60, 82), transparency = 0 }, -- the open bay
		},
		material = Enum.Material.SmoothPlastic,
		-- Low: the engine reflects the sky per part, so at 0.18 the seam between two of the bay's sheets showed as a
		-- straight line across the water (roast point 6, seen again in the 2026-10-26 playtest); 0.07 keeps a sheen.
		reflectance = 0.07,
		-- Sun glints on a light chop tiled over every sheet, `textureTile` studs a tile (nil for none), and the ramp that
		-- blends one shallows strip into the next: assets/city/water_glints.png and water_ramp.png, drawn by
		-- tools/draw_scenery_overlays.py and uploaded.
		-- None since 2026-10-26: tiled over open water the glints read as a pool's caustics (roast point 6). The image
		-- was rbxassetid://127637677152735.
		texture = nil :: string?,
		textureTile = 16,
		textureTransparency = 0.25,
		ramp = "rbxassetid://99210103644499" :: string?,
		-- Where the bank meets the water a crisp foam line, and a paler wash just off it (both opaque: one see-through
		-- layer per sightline).
		foam = { at = 6, line = 1.2, wash = 3.4, lineColor = rgb(248, 250, 248), washColor = rgb(204, 238, 232) },
		-- The shores without sand get a flush stone coping along the edge.
		coping = { width = 3, rise = 0.25, color = rgb(214, 196, 160), material = Enum.Material.Limestone },
		bridgeGap = 46, -- the coping stops this far either side of a bridge's centre line
	},

	causeway = {
		pier = 5, -- round piers this wide, at the old pillars' places
		-- Over the water each pier pair carries a cap beam under the deck, and the spans between piers spring shallow arches
		-- from the caps (two haunches a side).
		cap = Vector2.new(3.5, 2.6), -- along, tall
		arch = { rise = 6, reach = 0.3, thick = 1 }, -- a haunch rises this far at the pier and reaches this share of the span
		-- The balustrade on each deck edge: a plinth that drops below the slab as its fascia, a panel and a coping. With
		-- `balustradeImage` (a pierced X pattern: assets/city/balustrade_x.png, drawn by tools/draw_scenery_overlays.py)
		-- the panel turns see-through and shows the image on both faces; without, it is a solid white panel set in
		-- between plinth and coping.
		plinth = { thick = 0.9, top = 0.9, drop = 1.6 },
		panel = { thick = 0.5, top = 2.7 },
		coping = { thick = 1.1, top = 3.2 },
		balustradeImage = "rbxassetid://110677524796128" :: string?,
		balustradeTile = 3, -- studs per X
		-- A sea-blue line along the fascia and the glow strip under it (night kind `arch`, its own icy blue).
		accent = { from = -0.7, to = -0.35 },
		glow = { thick = 0.3, tall = 0.35 },
		glowKind = "arch",
		-- Acorn lamps on the coping, staggered along both sides (night kind streetlight; at most one in 200 studs casts
		-- light, like the streetlights).
		lamps = {
			every = 50,
			post = Vector2.new(0.4, 8.5), -- diameter, height above the coping
			globe = 1.5,
			postColor = rgb(45, 58, 51),
			globeColor = rgb(255, 243, 214),
		},
		-- The steel arches: white by day; at night each rib in its own colour, cyan at the feet through blue and violet to
		-- pink at the crown (the NightColor attribute beats the arch kind's own colour).
		arches = {
			ribColor = rgb(242, 242, 238),
			hangerColor = rgb(236, 238, 240),
			pierColor = rgb(236, 234, 228),
			gradient = { rgb(70, 230, 255), rgb(70, 160, 255), rgb(150, 100, 255), rgb(255, 90, 190) },
		},
	},

	lamps = {
		-- The avenues and the bridge approaches: tall poles with an arm over the road and a flat head.
		avenue = {
			pole = Vector2.new(0.5, 22),
			poleColor = rgb(70, 72, 76),
			poleMaterial = Enum.Material.Metal,
			arm = Vector3.new(0.35, 0.35, 6),
			head = Vector3.new(1.2, 0.35, 2.4),
			headColor = rgb(236, 236, 230),
			reach = 6,
			globe = false,
		} :: LampStyle,
		-- Town streets: a slim pole and an elongated head reaching over the kerb.
		street = {
			pole = Vector2.new(0.45, 17),
			poleColor = rgb(70, 72, 76),
			poleMaterial = Enum.Material.Metal,
			head = Vector3.new(1, 0.4, 3.4),
			headColor = rgb(236, 236, 230),
			reach = 1.6,
			globe = false,
		} :: LampStyle,
		-- The streets round the lake: white poles under frosted globes.
		globe = {
			pole = Vector2.new(0.4, 12),
			poleColor = rgb(246, 244, 238),
			poleMaterial = Enum.Material.SmoothPlastic,
			head = Vector3.new(1.6, 1.6, 1.6),
			headColor = rgb(252, 250, 244),
			reach = 0,
			globe = true,
		} :: LampStyle,
		-- Which style each road gets: by zone (MapLayout zone of the road's `from` node), then by kind.
		byZone = { lakefront = { street = "globe" } } :: { [string]: { [string]: string } },
		byKind = { arterial = "avenue", street = "street" } :: { [string]: string },
	},

	furniture = {
		-- Bus shelters on the outer half of the sidewalk (or the verge), open to the road, beside and never on a stop or
		-- gameplay spot. One every `every` studs along a matching road, alternating sides.
		shelters = {
			{ zone = "cedar_bend", kind = "arterial", every = 430 },
			{ zone = "lakefront", kind = "street", every = 520 },
		},
		shelter = {
			roof = Vector3.new(10, 0.4, 4.4),
			height = 8,
			post = 0.35,
			glass = rgb(178, 210, 220),
			bench = Vector3.new(8, 0.4, 1.4),
		},
		bench = { seat = Vector3.new(6, 0.4, 1.6), back = Vector3.new(6, 1.6, 0.3), height = 1.6 },
		-- A concrete planter box with a clump of palmetto and bird-of-paradise in it: a mesh in ServerStorage at `plant`
		-- (its pivot the clump's foot), scaled to `plantHeight` and cloned like the palms; nothing grows in the box while
		-- the mesh is missing.
		planter = {
			size = Vector3.new(4.5, 2, 4.5),
			color = rgb(226, 220, 206),
			leaf = rgb(70, 120, 60),
			plant = { "CityAssets", "Plants", "clump" },
			plantHeight = 3.8,
		},
	},

	crosswalks = {
		zones = { cedar_bend = true, lakefront = true } :: { [string]: boolean },
		-- A junction gets crossings on every road into it when one of them is one of these kinds.
		kinds = { arterial = true } :: { [string]: boolean },
		gap = 1.5, -- from the road's cut end (the junction pad)
		depth = 6, -- along the road
		inset = 1.2, -- in from each road edge
		-- One see-through part with a stripe image on its top: assets/city/crosswalk_zebra.png, drawn by
		-- tools/draw_scenery_overlays.py and uploaded (with `image` nil the city's slab-line image draws thin bars).
		-- `turn` swaps which way the image runs across the part.
		image = "rbxassetid://83119463084846" :: string?,
		tile = 3, -- studs per bar and gap
		turn = false,
		color = rgb(244, 244, 238),
	},

	townSquare = {
		park = "town_square",
		allee = { inset = 14, spacing = 34, species = "royal" },
		fountain = {
			basin = Vector2.new(34, 1.4), -- diameter, rim height
			pool = rgb(80, 200, 214),
			pedestal = Vector2.new(4, 6),
			bowl = Vector2.new(12, 0.8),
			jet = Vector2.new(1.2, 5),
			stone = rgb(236, 230, 218),
		},
		benches = 8,
		benchRing = 30, -- benches stand on a ring this far from the fountain's centre
		-- A terrazzo plaza round the fountain and paths out along the diagonals to the corners, flat on the lawn (Studio
		-- showed the square as a bare lawn round a lone fountain). The paths stop `pathEnd` studs short of each corner.
		plaza = {
			diameter = 80,
			path = 10,
			pathEnd = 30,
			lift = 0.06,
			color = rgb(236, 226, 212),
			material = Enum.Material.Marble,
			variant = "Terrazzo",
		},
	},

	-- Parts the scenery adds (tests/CityScenery.spec): Dev/City/Scenery stops placing the less important pieces first when
	-- a budget runs out (the beach and the causeway, then the avenues, then the streets).
	budget = {
		streetscapeParts = 2900, -- every Streetscape and StreetscapeLights part: street palms, furniture, the beach
		bridgeParts = 420, -- Bridges (role support) on raised roads: the balustrade, piers, caps, arches, fills
		waterParts = 40,
		-- The phone's in-view gate covers the scenery too: Config/Environment budget.inViewParts.
	},

	-- The bayfront park on the lawn between downtown's bay row and the north shore's hotel row (Dev/City/Scenery
	-- BayfrontPark; tests/CityScenery.spec "The bayfront park"). Plan x, z throughout: Lake Avenue (x = 0) runs down its
	-- middle and the bay lies south, past the hotel row. Pieces and paths are placed where the placement grid says the
	-- ground is clear, so a spot that turns out taken is left out rather than moved. Its own folders
	-- (Generated/BayfrontPark/Tile<x>_<z>, night lights in BayfrontParkLights/Tile<x>_<z>) and its own budget, so the
	-- streetscape's above doesn't pay for it.
	bayfrontPark = {
		-- The lawn it dresses: open county ground from the backs of the bay row's lots and the one-offs' deep claims
		-- (z 1,000..1,105) to the hotel row's plots along Lake Avenue (from z 1,300). Once dressed, its open lawn is
		-- kept free of the random trees (the park plants its own palms).
		area = { min = Vector2.new(-990, 1010), max = Vector2.new(990, 1298) },
		-- Parts (every one counts in the map's and the phone's budgets): about 390 planned. When it runs out the least
		-- important pieces drop first: the shrubs, then the bollards, the groves, the paths, the promenade's lamps and
		-- palms; the plazas and their props come first.
		budget = 400,
		root = "BayfrontPark",
		lightsRoot = "BayfrontParkLights",
		tile = 500, -- studs per tile model
		fenceCell = 40, -- the open lawn is kept from the random trees in squares this big
		plazaTop = 0.09, -- the plazas', aprons' and courts' paving tops above the ground (the promenade lies over them)
		-- The plazas' and the promenade's paving: cream stone pavers. The place's "Terrazzo" material variant reads as
		-- beach sand with starfish and fist-sized pebbles at this scale (the street-level roast, 2026-10-26, point 6), so
		-- the park uses plain Pavement (square slabs with joints) and no variant.
		paving = { color = rgb(232, 222, 204), material = Enum.Material.Pavement, variant = nil :: string? },

		-- The shared props it places (Config/CityProps, Dev/City/Props: one part each, cloned from
		-- ServerStorage.CityAssets.Props.<name>, a few plain parts while that's missing) at this many times their
		-- catalogue size (1 when not listed): the park's fountain and shell are bigger than a square's. Where the
		-- catalogue gives a prop a collider, the park adds that invisible box too.
		propScale = {
			Fountain = 2.1, -- about 34 across, 17 tall
			Bandshell = 2, -- 60 across, 36 tall, 40 deep
			PlaygroundSet = 1.25,
			SculptureA = 1.25,
			SculptureB = 1.4,
			MarketStall = 1.1,
			BistroPair = 1.2,
		} :: { [string]: number },
		-- Props whose collider is a round drum (as wide as the box's narrower side) rather than a box.
		roundColliders = { Fountain = true } :: { [string]: boolean },

		-- Globe lamps (2 parts: a white pole, a globe that glows at night) and lit bollards beside the paths (1 part each,
		-- glowing at night), both of the streetlight kind. Neither casts light of its own.
		lamp = {
			pole = Vector2.new(0.4, 12),
			globe = 2, -- 1.6 read as a pinprick across the lawn at night
			poleColor = rgb(246, 244, 238),
			globeColor = rgb(252, 250, 244),
			-- Each globe casts a warm light at night (the park was black but for its globes: the street-level roast,
			-- 2026-10-26, point 9). A PointLight, no shadows.
			light = { brightness = 1.8, range = 30, color = rgb(255, 214, 160) },
		},
		bollard = { size = Vector2.new(0.9, 3.2), color = rgb(246, 244, 238), every = 90, offset = 1.4 },

		-- The promenade along the bay (south) side, the park's whole width either side of Lake Avenue: a terrazzo walk
		-- (`z` its middle line) lined with royal palms on both sides (staggered, `setback` outside its edges), globe
		-- lamps on its bay edge and benches on its land edge facing the bay, and a zebra crossing `crossing` deep
		-- (Config/CityScenery crosswalks' look) where a road cuts it.
		promenade = {
			z = 1284,
			width = 14,
			top = 0.1,
			step = 4, -- sampled this often along it: a taken sample breaks the walk there
			palms = { species = "royal", spacing = 96, setback = 4, scale = { 1, 1.12 } },
			lampEvery = 144,
			benchEvery = 144,
			crossing = 10,
		},

		-- The fountain plaza by Lake Avenue (east): a paved disc `plaza` across, the Fountain on a low stone step
		-- (`surround`: just wider than its basin; the cyan disc it stood on read as water painted on the plaza: the
		-- street-level roast, 2026-10-26, point 7), benches on a ring facing it (between the four path mouths and the
		-- diagonals), globe lamps and royal palms on the diagonals, flowering shrubs round its rim.
		fountain = {
			at = Vector2.new(190, 1185),
			facing = 0,
			plaza = 96,
			surround = { diameter = 23, top = 0.5, color = rgb(214, 204, 184), material = Enum.Material.Limestone },
			benches = 8,
			benchRing = 34,
			lampRing = 45,
			palmRing = 57,
			palmSpecies = "royal",
			shrubRing = 53,
		},

		-- The amphitheatre lawn (west): the Bandshell, its mouth facing east across the lawn to Lake Avenue, a terrazzo
		-- apron at the stage's front ringed in neon, and low curved stone terraces (decor: a car drives over them) on
		-- `radii` from the stage's front, `spread` degrees wide. Lamps and shrubs in the shell's own frame (x across
		-- it, z back from its centre: its front edge is at -20).
		amphitheatre = {
			at = Vector2.new(-330, 1160),
			facing = -90,
			apron = 46,
			ring = { diameter = 49, top = 0.07, color = rgb(255, 160, 172), kind = "neonPink" },
			-- Footlights: a strip set in the apron along the stage's foot (`inset` out from the shell's front edge), cream
			-- by day, a warm amber glow at night (1 part).
			footlights = {
				length = 34,
				depth = 0.8,
				top = 0.14,
				inset = 5, -- clear of the stage's rounded lip (at 1.5 it hid the middle and left two dashes)
				color = rgb(244, 232, 210),
				kind = "neonAmber",
			},
			-- Seating steps: each terrace `height` higher than the one in front of it (the first `height` high), `depth`
			-- deep, so the lawn rises in tiers away from the stage (as ankle-high curbs at one height they read as kerbs
			-- on the grass: the street-level roast, 2026-10-26, point 5).
			terraces = {
				radii = { 36, 50, 64 },
				spread = 100,
				segment = 14, -- 22 showed the arcs' corners from the lawn
				height = 0.9,
				depth = 3.2,
				color = rgb(214, 196, 160),
				material = Enum.Material.Limestone,
			},
			lamps = { Vector2.new(-35, -22), Vector2.new(35, -22) },
			shrubs = { Vector2.new(-36, 4), Vector2.new(36, 4), Vector2.new(-20, 23), Vector2.new(20, 23) },
		},

		-- Food trucks at the lawn's corner by Lake Avenue and the promenade (west): a paved apron reaching the walk, three
		-- trucks along its bay half turned `truckTurn` so their right sides (the serving hatches) face the lawn, a
		-- market stall, bistro tables on its lawn half and two lamps. Places in the apron's frame (x along it, z back
		-- from its front; its front faces the lawn, north).
		foodTrucks = {
			at = Vector2.new(-150, 1251),
			facing = 0,
			apron = Vector2.new(124, 54),
			color = rgb(214, 208, 196),
			material = Enum.Material.Concrete,
			trucks = { "FoodTruckA", "FoodTruckB", "FoodTruckA" },
			truckAt = { Vector2.new(-30, 12), Vector2.new(6, 12), Vector2.new(42, 12) },
			truckTurn = 90,
			stall = { prop = "MarketStall", at = Vector2.new(-50, 12) },
			tables = { Vector2.new(-46, -12), Vector2.new(-15, -12), Vector2.new(16, -12), Vector2.new(47, -12) },
			lamps = { Vector2.new(-59, -24), Vector2.new(59, -24) },
		},

		-- The playground (west): the PlaygroundSet on a soft teal surface, benches watching it. Places in its frame (its
		-- front faces south, to the promenade).
		playground = {
			at = Vector2.new(-600, 1200),
			facing = 180,
			surface = 46,
			-- A poured rubber surface: matte (smooth plastic in this teal read as a neon disc under the Realistic light).
			color = rgb(72, 150, 152),
			material = Enum.Material.Rubber,
			benches = { Vector2.new(-16, 30), Vector2.new(16, 30) },
			shrubs = { Vector2.new(-30, 16), Vector2.new(30, 16) },
		},

		-- The sculpture garden (east): a coral-stone court framed by hedges on its long sides (each broken by a gap in
		-- the middle), SculptureA and SculptureB in a zigzag on it, benches, lamps, shrubs at its corners. Places in its
		-- frame (x along it, z back from its front, north).
		sculptures = {
			at = Vector2.new(470, 1175),
			facing = 0,
			court = Vector2.new(100, 64),
			color = rgb(226, 212, 184),
			material = Enum.Material.Limestone,
			pieces = {
				{ prop = "SculptureA", at = Vector2.new(-32, -12) },
				{ prop = "SculptureB", at = Vector2.new(-10, 12) },
				{ prop = "SculptureA", at = Vector2.new(12, -12) },
				{ prop = "SculptureB", at = Vector2.new(34, 12) },
			},
			-- Clipped hedges in Grass: LeafyGrass read near black under the Realistic light, whatever its colour.
			hedge = {
				height = 2.8,
				width = 2.6,
				gap = 14,
				inset = 1.5,
				color = rgb(92, 138, 70),
				material = Enum.Material.Grass,
			},
			benches = { Vector2.new(-30, 24), Vector2.new(30, 24) },
			lamps = { Vector2.new(-46, -26), Vector2.new(46, -26) },
			shrubs = { Vector2.new(-55, -37), Vector2.new(55, -37), Vector2.new(-55, 37), Vector2.new(55, 37) },
		},

		-- Curving paths: each route a smooth curve through its points (a Catmull-Rom spline), laid as slabs about `step`
		-- long that run on `overlap` past their ends to close the bends, every other one a hair higher so the overlaps
		-- never flicker. A slab whose middle falls inside a round plaza is left out (the plaza is the way there), and
		-- lit bollards stand beside them.
		paths = {
			width = 8,
			top = 0.06,
			step = 44, -- 34 cost 10 more slabs for no visible gain; they went to two more groves
			overlap = 1,
			color = rgb(228, 216, 192),
			material = Enum.Material.Limestone,
			routes = {
				-- East: Lake Avenue to the fountain; the fountain to the promenade and to the sculpture court; on round the
				-- east lawn and down to the promenade.
				{ Vector2.new(44, 1185), Vector2.new(144, 1185) },
				{ Vector2.new(196, 1231), Vector2.new(210, 1256), Vector2.new(228, 1279) },
				{ Vector2.new(236, 1185), Vector2.new(290, 1204), Vector2.new(350, 1190), Vector2.new(421, 1175) },
				{
					Vector2.new(519, 1175),
					Vector2.new(590, 1150),
					Vector2.new(680, 1166),
					Vector2.new(770, 1142),
					Vector2.new(860, 1160),
					Vector2.new(930, 1202),
					Vector2.new(955, 1250),
					Vector2.new(962, 1279),
				},
				-- West: Lake Avenue along the lawn's north side, behind the shell and on to the playground; on from it round
				-- the west lawn to the promenade; the promenade to the shell's south flank.
				{
					Vector2.new(-44, 1060),
					Vector2.new(-130, 1068),
					Vector2.new(-220, 1060),
					Vector2.new(-290, 1076),
					Vector2.new(-345, 1104),
					Vector2.new(-380, 1140),
					Vector2.new(-440, 1180),
					Vector2.new(-510, 1198),
					Vector2.new(-578, 1200),
				},
				{
					Vector2.new(-622, 1200),
					Vector2.new(-700, 1186),
					Vector2.new(-790, 1204),
					Vector2.new(-880, 1180),
					Vector2.new(-945, 1225),
					Vector2.new(-965, 1279),
				},
				{ Vector2.new(-262, 1279), Vector2.new(-290, 1245), Vector2.new(-330, 1222), Vector2.new(-345, 1198) },
			} :: { { Vector2 } },
		},

		-- Palm groves breaking up the lawns, each palm drawn from `groveSpecies` by weight, leaning any way.
		groves = {
			{ at = Vector2.new(330, 1100), count = 4, radius = 28, shrubs = 2 },
			{ at = Vector2.new(620, 1232), count = 3, radius = 22, shrubs = 2 },
			{ at = Vector2.new(740, 1095), count = 4, radius = 28, shrubs = 2 },
			{ at = Vector2.new(880, 1236), count = 3, radius = 22, shrubs = 1 },
			{ at = Vector2.new(935, 1075), count = 3, radius = 24, shrubs = 1 },
			{ at = Vector2.new(-470, 1085), count = 4, radius = 26, shrubs = 2 },
			{ at = Vector2.new(-480, 1246), count = 3, radius = 22, shrubs = 1 },
			{ at = Vector2.new(-760, 1135), count = 4, radius = 26, shrubs = 2 },
			{ at = Vector2.new(-830, 1250), count = 3, radius = 22, shrubs = 1 },
			{ at = Vector2.new(-950, 1092), count = 3, radius = 24, shrubs = 1 },
			-- The two widest bare stretches of lawn (seen from above in Studio, 2026-10-26).
			{ at = Vector2.new(560, 1080), count = 3, radius = 26, shrubs = 1 },
			{ at = Vector2.new(-590, 1122), count = 3, radius = 26, shrubs = 1 },
		} :: { ParkGrove },
		groveSpecies = {
			{ species = "coconut", weight = 0.5 },
			{ species = "sabal", weight = 0.3 },
			{ species = "royal", weight = 0.2 },
		},

		-- Shrubs: clumps of palmetto and bird-of-paradise (the planters' mesh, Config/CityScenery furniture.planter.plant),
		-- each `height` and `spread` scaled by a draw in `scale`. The bougainvillea mounds (half-sunk magenta balls) are
		-- gone: they read as magenta half-spheres (the street-level roast, 2026-10-26, point 5).
		shrubs = {
			clump = { height = 4.6, spread = 5.5 },
			scale = { 0.75, 1.3 },
		},
	},
}

return CityScenery
