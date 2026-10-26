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
--   water        the bay as parts (terrain water waits on Davis's call): a pale sandy bed, bands of colour from the
--                shore out, a foam line and a stone coping on the shores without a beach
--   causeway     the lake bridge (C09): round white piers with caps, shallow arched spans, a white balustrade with a lit
--                fascia, acorn lamps along it, the steel arches white by day and in a colour gradient at night
--   lamps        streetlight styles by road
--   furniture    bus shelters, benches and planters
--   crosswalks   zebra crossings at the junctions of the avenues
--   townSquare   the downtown square's fountain, its palm allée and benches
--   budget       how many parts the scenery may add, and the phone's in-view gate
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
	fallback: PalmFallback,
}

-- Palms in the sidewalks and verges of one kind of road in one zone (a road matches when either end node is in the
-- zone). Each side gets a palm every `spacing` studs, `offset` studs out from the kerb (the road's edge), or `verge`
-- studs out where the road has no sidewalk; `stagger` shifts one side by half a spacing; `sides` "lake" plants only
-- the side facing Cedar Lake. A bridge's palms stand on the ground beside its deck, only off the water.
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
		-- front (-Z). Every copy is a Clone() of it, so one mesh draws as one instanced call.
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
				crown = 26,
				crownFrom = 0.66,
				crownTo = 1.04,
				collider = Vector2.new(1.8, 12),
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
			-- Curved, leaning trunks: the beach, the lake ring, pool edges, leaning toward the water.
			coconut = {
				height = 34,
				scale = { 0.85, 1.15 },
				lean = { 0, 8 },
				baseLean = 12,
				crown = 24,
				crownFrom = 0.68,
				crownTo = 1.08,
				collider = Vector2.new(1.6, 10),
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
				crown = 15,
				crownFrom = 0.62,
				crownTo = 1.06,
				collider = Vector2.new(1.7, 10),
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
			-- The lake ring: coconut palms on the lake side of the shore roads, full-grown so their crowns clear the road by
			-- 20 studs.
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
			},
			-- The causeway approaches: royal palms in rows either side, on the ground beside the deck, far enough out that
			-- their crowns don't hang over it.
			{
				zone = "lakefront",
				kind = "bridge",
				species = "royal",
				spacing = 40,
				offset = 14,
				verge = 14,
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
		-- A row of coconut palms on the lawn along the promenade's land side (negative: north of the band's edge).
		lawn = { at = -9, every = 46 },
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
			canopy = 7,
			loungers = { 2.2, 1.1, 6 }, -- across, back height, long
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
		deck = 7, -- the platform's top above the sand
		platform = Vector3.new(14, 0.6, 12),
		hut = Vector3.new(10, 8.5, 7), -- across, tall, deep
		legs = 0.8,
		ramp = { width = 2.6, length = 14 },
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
		bed = { color = rgb(214, 200, 164), material = Enum.Material.Sand }, -- the lake bed and banks: pale sand
		-- From the shore out: each band reaches `width` studs from the lake's edge (the last fills the middle). The first
		-- six studs lie under the sand bank, where it meets the water. Small steps of colour and clearness, so the bay
		-- shades from pale turquoise over the sand to deep blue without a hard line.
		bands = {
			{ width = 24, color = rgb(96, 212, 206), transparency = 0.5 }, -- the shallows: turquoise over pale sand
			{ width = 50, color = rgb(66, 194, 198), transparency = 0.42 },
			{ width = 90, color = rgb(46, 170, 186), transparency = 0.32 },
			{ width = 150, color = rgb(34, 140, 170), transparency = 0.24 },
			{ width = math.huge, color = rgb(24, 106, 150), transparency = 0.16 }, -- the deep bay
		},
		material = Enum.Material.Glass,
		reflectance = 0.12,
		-- An optional overlay image on the water's top (glinting ripples), tiled `textureTile` studs: nil until it is
		-- uploaded (assets/city/water_ripple.png, drawn by tools/draw_scenery_overlays.py).
		texture = nil :: string?,
		textureTile = 24,
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
		balustradeImage = nil :: string?,
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
		planter = { size = Vector3.new(4.5, 2, 4.5), color = rgb(226, 220, 206), leaf = rgb(70, 120, 60) },
	},

	crosswalks = {
		zones = { cedar_bend = true, lakefront = true } :: { [string]: boolean },
		-- A junction gets crossings on every road into it when one of them is one of these kinds.
		kinds = { arterial = true } :: { [string]: boolean },
		gap = 1.5, -- from the road's cut end (the junction pad)
		depth = 6, -- along the road
		inset = 1.2, -- in from each road edge
		-- One see-through part with a stripe image on its top. Until the zebra image is uploaded
		-- (assets/city/crosswalk_zebra.png, drawn by tools/draw_scenery_overlays.py) the city's slab-line image draws thin
		-- bars. `turn` swaps which way the image runs across the part.
		image = nil :: string?,
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
	},

	-- Parts the scenery adds (tests/CityScenery.spec): Dev/City/Scenery stops placing the less important pieces first when
	-- a budget runs out (the beach and the causeway, then the avenues, then the streets).
	budget = {
		streetscapeParts = 2900, -- every Streetscape and StreetscapeLights part: street palms, furniture, the beach
		bridgeParts = 420, -- Bridges (role support) on raised roads: the balustrade, piers, caps, arches, fills
		waterParts = 40,
		-- The phone's in-view gate covers the scenery too: Config/Environment budget.inViewParts.
	},
}

return CityScenery
