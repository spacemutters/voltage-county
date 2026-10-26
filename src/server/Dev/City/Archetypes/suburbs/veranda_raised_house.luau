--!strict
-- R03 veranda_raised_house (docs/city/ARCHETYPES.md §7, R03): the Old Florida bay house, lifted onto a new ground
-- storey. A clapboard upper storey stands inside a deep veranda deck that runs all round it, the deck and the eaves
-- carried on tall white posts from the ground; a white balustrade (square bars under a top rail) round the deck; a deep
-- white frieze ties the posts' heads under the eaves (the veranda's ceiling); a steep hipped roof, almost a pyramid,
-- over the whole deck, crowned by a square louvred cupola under its own little hip (the chimney-stack vent that cools
-- the house) or a slender finial spike. Under the deck the ground storey sits back in the shade with its door and
-- windows; tall French doors and shuttered windows open onto the veranda above. A shell drive under the deck, a walk
-- to the door, a sea-grape hedge.
--
-- What makes it itself: a wooden house with a deep veranda all round its upper floor under a steep, dark, pointed
-- roof.
-- Placement, sizes, heights and its budget: Config/CityArchetypes/veranda_raised_house.
-- Variants: palette (3: white clapboard under dark shingles with green shutters, butter clapboard under a silver tin
-- roof, sea-green clapboard under dark shingles with white shutters), crown (1 the louvred cupola and ball finial, 2 a
-- slender finial spike), rhythm (1 four posts a side, 2 five), mirror (the drive and the odd post bay swap sides).
--
-- Previewing: from the street at eye height and from a front corner. Check the hip roof's corner wedges meet in a
-- clean point, the clapboard lines (a slab-line Texture) read as siding and not as stripes, the balustrade shows on all
-- four sides with the posts just outside it, the frieze reads as a white band under the eaves, the cupola's louvres
-- show and its cap clears the roof, the roof reads steep. At night: the French doors and windows glow behind the rail,
-- the ground storey's windows too, and the lamp by the door is warm.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local City = require(ReplicatedStorage.Shared.Config.City)
local Kit = require(script.Parent.Parent.Parent.Kit)
local Types = require(script.Parent.Parent.Parent.Types)

local P = City.palettes
local KIT = City.kit
local rgb = Color3.fromRGB

-- The recipe, in studs.
local SHAPE = {
	side = 2, -- the deck's edge from the site's sides, at least (the eaves reach 1.4 past it)
	yard = { 0.2, 7, 12 },
	-- The deck's width, clamped. Kept to 30 so the roof over it (rising 11..15 from the eaves) pitches about 40 degrees
	-- and reads as the steep pointed roof of the old bay houses, not a low suburban hip.
	deck = { 26, 30 },
	deckDepth = { 0.53, 22, 27 },
	groundIn = 3, -- the ground storey under the deck, set in
	upperIn = 4, -- the upper storey inside the veranda
	deckY = 10.4,
	deckThick = 1.4, -- a deep white deck edge: the veranda's line from the street
	eave = 21.2,
	frieze = 1.3, -- the white band under the eaves, round the posts' heads
	overhang = 1.4,
	roofThick = 0.5,
	post = 0.9,
	postIn = 0.1, -- the posts' outer faces this far in from the deck edge (just outside the rail)
	rail = 3,
	railIn = 0.2,
	posts = { 4, 5 }, -- along the front and the back, by rhythm
	clapboard = 0.9, -- one board's height
	cupola = { size = 3.4, tall = 2.8, cap = 1.3 },
	spike = 4, -- crown 2: the finial's height from just under the point
}

-- Siding, roof (and its material), shutters.
local PALETTES = {
	{
		siding = rgb(240, 236, 226),
		roof = rgb(84, 88, 86),
		roofMaterial = Enum.Material.RoofShingles,
		shutter = rgb(58, 102, 84),
	},
	{
		siding = rgb(244, 226, 164),
		roof = rgb(176, 182, 186),
		roofMaterial = Enum.Material.Metal,
		shutter = rgb(46, 86, 70),
	},
	{
		siding = rgb(186, 220, 200),
		roof = rgb(80, 84, 84),
		roofMaterial = Enum.Material.RoofShingles,
		shutter = rgb(246, 244, 238),
	},
}
local TRIM = rgb(246, 244, 238)
local SHELL = rgb(226, 220, 206)
local GRAPE = rgb(92, 140, 66) -- darker greens read as black boxes in the game's light
local LANTERN = rgb(255, 214, 160)

local WALLS = { Enum.NormalId.Front, Enum.NormalId.Back, Enum.NormalId.Left, Enum.NormalId.Right }

local function share(x: number, rule: { number }): number
	return math.clamp(x * rule[1], rule[2], rule[3])
end

local function build(m: Types.Model)
	local site = m.site
	local variant = site.variant
	local pal = PALETTES[math.clamp(variant.palette, 1, #PALETTES)]
	local W, D, H = site.width, site.depth, site.height
	local hw, hd = W / 2, D / 2

	local trim = Kit.look(TRIM, Enum.Material.SmoothPlastic)
	local roof = Kit.look(pal.roof, pal.roofMaterial)
	local shutter = Kit.look(pal.shutter, Enum.Material.SmoothPlastic)
	local glass = P.window.dark
	local front = { Enum.NormalId.Front }
	-- Clapboard: painted boards, a shadow line under each (a slab-line overlay a shade darker than the paint).
	local lines = pal.siding:Lerp(Color3.new(0, 0, 0), 0.22)
	local function clapboard(name: string, min: Vector3, max: Vector3): Types.PartSpec
		local spec = Kit.box(m, name, min, max, Kit.look(pal.siding, Enum.Material.SmoothPlastic))
		local textures: { Types.TextureSpec } = {}
		for _, face in WALLS do
			table.insert(textures, {
				face = Kit.face(m, face),
				image = City.textures.slabLine,
				u = 8,
				v = SHAPE.clapboard,
				color = lines,
			})
		end
		spec.textures = textures
		return spec
	end

	-------------------------------------------------------------------------------------------------------
	-- The plan: the deck centred on the site, the house inside it
	-------------------------------------------------------------------------------------------------------
	local dw = math.clamp(W - 2 * SHAPE.side, SHAPE.deck[1], SHAPE.deck[2])
	local dx = dw / 2
	local z0 = -hd + share(D, SHAPE.yard) -- the deck's front edge
	local z1 = z0 + share(D, SHAPE.deckDepth)
	local zc = (z0 + z1) / 2
	local dY = SHAPE.deckY
	local floorY = dY + SHAPE.deckThick -- the upper floor
	local eave = SHAPE.eave

	-- The roof's soffit: Kit.hipRoof's flat underside, which hangs below the eaves line by the overhang's drop. The
	-- frieze runs just under it, so the whole band shows.
	local roofHalf = math.min(dw, z1 - z0) / 2
	local roofPitch = math.max(0.05, H - eave - SHAPE.roofThick) / roofHalf
	local soffit = H - roofPitch * (roofHalf + SHAPE.overhang)
	local fy = soffit - SHAPE.frieze -- the frieze's foot: the posts' and the upper walls' heads

	-- The ground storey in the shade under the deck, the deck, the upper storey, the frieze over the veranda.
	local gi, ui = SHAPE.groundIn, SHAPE.upperIn
	clapboard("Ground", Vector3.new(-dx + gi, -KIT.bury, z0 + gi), Vector3.new(dx - gi, dY, z1 - gi))
	Kit.box(m, "Deck", Vector3.new(-dx, dY, z0), Vector3.new(dx, floorY, z1), trim)
	clapboard("Upper", Vector3.new(-dx + ui, floorY, z0 + ui), Vector3.new(dx - ui, fy + 0.02, z1 - ui))
	Kit.trim(m, "Frieze", Vector3.new(-dx - 0.1, fy, z0 - 0.1), Vector3.new(dx + 0.1, soffit + 0.05, z1 + 0.1), trim)

	-- The posts, from the ground to the frieze, round the deck's edge.
	local n = SHAPE.posts[math.clamp(variant.rhythm, 1, 2)]
	local inner = dx - SHAPE.postIn - SHAPE.post / 2 -- a post's centre from the middle
	local pz0, pz1 = z0 + SHAPE.postIn + SHAPE.post / 2, z1 - SHAPE.postIn - SHAPE.post / 2
	local spots: { Vector2 } = {}
	for i = 1, n do
		local x = -inner + 2 * inner * (i - 1) / (n - 1)
		table.insert(spots, Vector2.new(x, pz0))
		table.insert(spots, Vector2.new(x, pz1))
	end
	table.insert(spots, Vector2.new(-inner, zc))
	table.insert(spots, Vector2.new(inner, zc))
	local half = SHAPE.post / 2
	for i, p in spots do
		Kit.box(
			m,
			`Post{i}`,
			Vector3.new(p.X - half, -KIT.bury, p.Y - half),
			Vector3.new(p.X + half, fy + 0.02, p.Y + half),
			trim
		)
	end

	-- The balustrade: one invisible box round the deck, square bars under a top rail on its four faces.
	local ri = SHAPE.railIn
	Kit.railing(
		m,
		"Rail",
		Vector3.new(-dx + ri, floorY, z0 + ri),
		Vector3.new(dx - ri, floorY + SHAPE.rail, z1 - ri),
		WALLS,
		TRIM,
		0.9
	)

	-- The steep hipped roof over the whole deck.
	Kit.hipRoof(m, "Roof", Vector3.new(-dx, eave, z0), Vector3.new(dx, H, z1), SHAPE.overhang, SHAPE.roofThick, roof)

	-------------------------------------------------------------------------------------------------------
	-- The top: a square louvred cupola under a little hip (crown 1) or a slender finial spike (crown 2)
	-------------------------------------------------------------------------------------------------------
	if variant.crown ~= 2 then
		local c = SHAPE.cupola
		local s = c.size / 2
		-- Its foot sinks well into the steep slopes, so no gap shows under its sides.
		local cupola = Kit.box(m, "Cupola", Vector3.new(-s, H - 2.4, zc - s), Vector3.new(s, H + c.tall, zc + s), trim)
		local louvres: { Types.TextureSpec } = {}
		for _, face in WALLS do
			table.insert(louvres, {
				face = Kit.face(m, face),
				image = City.textures.slabLine,
				u = c.size,
				v = 0.45,
				color = pal.roof:Lerp(Color3.new(0, 0, 0), 0.3),
			})
		end
		cupola.textures = louvres
		Kit.hipRoof(
			m,
			"CupolaCap",
			Vector3.new(-s, H + c.tall, zc - s),
			Vector3.new(s, H + c.tall + c.cap, zc + s),
			0.5,
			0.3,
			roof
		)
		Kit.ball(m, "Finial", Vector3.new(0, H + c.tall + c.cap + 0.3, zc), 0.7, trim, "trim")
	else
		-- A slender finial spike over the point, the "pointed" roof of the old bay houses.
		Kit.spire(m, "Spike", 0, zc, H - 0.5, SHAPE.spike, 0.7, trim, 2)
		Kit.ball(m, "Finial", Vector3.new(0, H + 1.2, zc), 1.2, trim, "trim")
	end

	-------------------------------------------------------------------------------------------------------
	-- Openings: French doors and shuttered windows onto the veranda, the ground storey's door and windows
	-------------------------------------------------------------------------------------------------------
	local fz = z0 + ui -- the upper storey's front
	local tall = math.min(7.6, fy - floorY - 0.8)
	Kit.trim(
		m,
		"FrenchFrame",
		Vector3.new(-2.1, floorY, fz - 0.12),
		Vector3.new(2.1, floorY + tall + 0.5, fz + 0.1),
		trim
	)
	Kit.glass(m, "FrenchDoor", Vector3.new(-1.6, floorY, fz - 0.25), Vector3.new(1.6, floorY + tall, fz + 0.1), glass, {
		image = City.textures.windowBold,
		faces = front,
		u = 1.6,
		v = tall * 1.25,
		lines = TRIM,
		lit = true,
	})
	local wx = (dx - ui) * 0.58
	for i, sx in { -1, 1 } do
		local x = sx * wx
		Kit.detail(
			m,
			`Shutters{i}`,
			Vector3.new(x - 2.4, floorY + 1.3, fz - 0.12),
			Vector3.new(x + 2.4, floorY + tall, fz + 0.1),
			shutter
		)
		Kit.glass(
			m,
			`Window{i}`,
			Vector3.new(x - 1.2, floorY + 1.4, fz - 0.25),
			Vector3.new(x + 1.2, floorY + tall - 0.1, fz + 0.1),
			glass,
			{ image = City.textures.windowBold, faces = front, u = 1.2, v = 3, lines = TRIM, lit = true }
		)
	end
	for i, sx in { -1, 1 } do
		local face = if sx < 0 then Enum.NormalId.Left else Enum.NormalId.Right
		local wallX = sx * (dx - ui)
		Kit.glass(
			m,
			`SideWindow{i}`,
			Vector3.new(wallX - sx * 0.3, floorY + 1.4, zc - 1.2),
			Vector3.new(wallX + sx * 0.2, floorY + tall - 0.1, zc + 1.2),
			glass,
			{ image = City.textures.windowBold, faces = { face }, u = 1.2, v = 3, lines = TRIM }
		)
	end

	-- The front door sits in the middle of a post bay (an odd number of posts puts one in the middle).
	local bay = 2 * inner / (n - 1)
	local doorX = if n % 2 == 0 then 0 else -bay / 2
	local gz = z0 + gi -- the ground storey's front
	Kit.trim(m, "DoorFrame", Vector3.new(doorX - 1.85, 0, gz - 0.1), Vector3.new(doorX + 1.85, 7.8, gz + 0.1), trim)
	Kit.trim(m, "Door", Vector3.new(doorX - 1.4, 0, gz - 0.25), Vector3.new(doorX + 1.4, 7.2, gz + 0.1), shutter)
	local gx = dx - gi
	for i, span in { { -gx + 1.4, doorX - 2.8 }, { doorX + 2.8, gx - 1.4 } } do
		if span[2] - span[1] >= 2.4 then
			Kit.glass(
				m,
				`GroundWindow{i}`,
				Vector3.new(span[1], 2.4, gz - 0.2),
				Vector3.new(span[2], 7.4, gz + 0.1),
				glass,
				{ image = City.textures.windowBold, faces = front, u = 1.6, v = 2.5, lines = TRIM, lit = i == 2 }
			)
		end
	end
	local lamp = Kit.detail(
		m,
		"Lamp",
		Vector3.new(doorX + 2.1, 6.2, gz - 0.7),
		Vector3.new(doorX + 2.8, 7.4, gz + 0.05),
		Kit.look(LANTERN, Enum.Material.SmoothPlastic)
	)
	Kit.lit(lamp, "neonAmber") -- warm: a pale kind turns white-hot Neon

	-------------------------------------------------------------------------------------------------------
	-- The lot: a crushed-shell drive under the deck, a walk to the door, a sea-grape hedge
	-------------------------------------------------------------------------------------------------------
	local shell = Kit.look(SHELL, Enum.Material.Pavement)
	local driveX = inner - bay / 2 -- the middle of the last post bay
	local driveHalf = math.min(4, bay / 2 - 0.6)
	Kit.detail(
		m,
		"Drive",
		Vector3.new(driveX - driveHalf, 0.02, -hd + 0.2),
		Vector3.new(driveX + driveHalf, 0.14, gz - 0.2),
		shell
	)
	Kit.detail(m, "Walk", Vector3.new(doorX - 1.5, 0.02, -hd + 0.2), Vector3.new(doorX + 1.5, 0.14, gz - 0.3), shell)
	local hedgeEnd = math.min(doorX - 2.2, driveX - driveHalf - 1)
	if hedgeEnd - (-hw + 1) >= 2 then
		Kit.trim(
			m,
			"Hedge",
			Vector3.new(-hw + 1, 0, -hd + 1),
			Vector3.new(hedgeEnd, 2.8, -hd + 3),
			Kit.look(GRAPE, Enum.Material.Grass)
		)
	end
end

local archetype: Types.Archetype = { id = "veranda_raised_house", build = build }
return archetype
