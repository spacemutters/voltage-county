--!strict
-- R03 veranda_raised_house (docs/city/ARCHETYPES.md §7, R03): the Old Florida bay house, lifted onto a new ground
-- storey. A wooden upper storey stands inside a deep veranda deck that runs all round it, the deck and the eaves
-- carried on tall white posts from the ground; a white balustrade (square bars under a top rail) round the deck; a
-- steep dark hipped roof, almost a pyramid, over the whole deck, crowned by a louvred octagonal vent lantern (or a
-- slender finial spike). Under the deck, the ground storey sits back in the shade with its door and
-- windows; tall French doors and shuttered windows open onto the veranda above. A shell drive to the deck's edge, a
-- walk to the door, a sea-grape hedge.
--
-- What makes it itself: a wooden house with a deep veranda all round its upper floor under a steep, dark, pointed
-- roof.
-- Placement, sizes, heights and its budget: Config/CityArchetypes/veranda_raised_house.
-- Variants: palette (3 sidings: white, pale yellow, sea green, with dark green shutters), crown (1 the octagonal vent
-- lantern and ball finial, 2 a slender finial spike: a dormer was tried on paper, but at these pitches its ridge would
-- top the main one), rhythm (1 four posts a side, 2 five), mirror (the drive and the odd post bay swap sides).
--
-- Previewing: from the street at eye height and from a front corner. Check the hip roof's corner wedges meet in a
-- clean point (Kit.hipRoof), the balustrade (a punched Texture on one invisible box round the deck) shows on all four
-- sides with the posts standing just outside it, the octagon's louvres read and it sits on the ridge, the roof reads
-- steep and dark (raise heights.min in its Config if not). At night: the French doors and windows glow behind the
-- rail, the ground storey's windows too, and the lamp by the door is warm.

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
	overhang = 1.4,
	roofThick = 0.5,
	post = 0.9,
	postIn = 0.1, -- the posts' outer faces this far in from the deck edge (just outside the rail)
	rail = 3,
	railIn = 0.2,
	posts = { 4, 5 }, -- along the front and the back, by rhythm
	vent = { across = 3.6, tall = 3 },
	spike = 5, -- crown 2: the finial's height from just under the point
}

-- Siding, with white trim, dark roof and green shutters for all.
local SIDINGS = { rgb(238, 232, 220), rgb(242, 226, 170), rgb(196, 222, 204) }
local TRIM = rgb(246, 244, 238)
local ROOF = rgb(93, 95, 91)
local SHUTTER = rgb(63, 106, 90)
local SHELL = rgb(226, 220, 206)
local GRAPE = rgb(70, 112, 58)
local LANTERN = rgb(255, 214, 160)

local function share(x: number, rule: { number }): number
	return math.clamp(x * rule[1], rule[2], rule[3])
end

local function build(m: Types.Model)
	local site = m.site
	local variant = site.variant
	local siding = SIDINGS[math.clamp(variant.palette, 1, #SIDINGS)]
	local W, D, H = site.width, site.depth, site.height
	local hw, hd = W / 2, D / 2

	local wood = Kit.look(siding, Enum.Material.WoodPlanks)
	local trim = Kit.look(TRIM, Enum.Material.SmoothPlastic)
	local roof = Kit.look(ROOF, Enum.Material.RoofShingles)
	local shutter = Kit.look(SHUTTER, Enum.Material.SmoothPlastic)
	local glass = P.window.dark
	local front = { Enum.NormalId.Front }

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

	-- The ground storey in the shade under the deck, the deck, the upper storey.
	local gi, ui = SHAPE.groundIn, SHAPE.upperIn
	Kit.box(m, "Ground", Vector3.new(-dx + gi, -KIT.bury, z0 + gi), Vector3.new(dx - gi, dY, z1 - gi), wood)
	Kit.box(m, "Deck", Vector3.new(-dx, dY, z0), Vector3.new(dx, floorY, z1), trim)
	Kit.box(m, "Upper", Vector3.new(-dx + ui, floorY, z0 + ui), Vector3.new(dx - ui, eave, z1 - ui), wood)

	-- The posts, from the ground to the eaves, round the deck's edge.
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
			Vector3.new(p.X + half, eave, p.Y + half),
			trim
		)
	end

	-- The balustrade: one invisible box round the deck, square bars under a top rail on its four faces.
	local ri = SHAPE.railIn
	local rail = Kit.detail(
		m,
		"Rail",
		Vector3.new(-dx + ri, floorY, z0 + ri),
		Vector3.new(dx - ri, floorY + SHAPE.rail, z1 - ri),
		Kit.look(TRIM, Enum.Material.SmoothPlastic, 0, 1)
	)
	local bars: { Types.TextureSpec } = {}
	for _, face in { Enum.NormalId.Front, Enum.NormalId.Back, Enum.NormalId.Left, Enum.NormalId.Right } do
		table.insert(bars, { face = face, image = City.textures.punched, u = 1, v = 3.4, color = TRIM })
	end
	rail.textures = bars

	-- The steep dark hipped roof over the whole deck.
	Kit.hipRoof(m, "Roof", Vector3.new(-dx, eave, z0), Vector3.new(dx, H, z1), SHAPE.overhang, SHAPE.roofThick, roof)

	-------------------------------------------------------------------------------------------------------
	-- The top: a louvred octagonal vent lantern (crown 1) or a gabled dormer on the front slope (crown 2)
	-------------------------------------------------------------------------------------------------------
	if variant.crown ~= 2 then
		local v = SHAPE.vent
		-- White, so it reads as a louvred lantern on the point and not as a chimney in the siding.
		local vent = Kit.octagon(m, "Vent", 0, zc, H - 0.6, H + v.tall, v.across, trim, "trim")
		-- Louvres on the four square-on faces: the outer (left and right) faces of the octagon's 0 and 90 degree bars.
		for _, k in { 1, 3 } do
			local louvres: { Types.TextureSpec } = {}
			for _, face in { Enum.NormalId.Left, Enum.NormalId.Right } do
				table.insert(louvres, {
					face = face,
					image = City.textures.slabLine,
					u = v.across,
					v = 0.5,
					color = ROOF,
				})
			end
			vent[k].textures = louvres
		end
		Kit.disc(m, "VentCap", 0, zc, H + v.tall + 0.2, v.across + 0.9, 0.4, roof)
		Kit.ball(m, "Finial", Vector3.new(0, H + v.tall + 0.75, zc), 0.8, trim, "trim")
	else
		-- A slender finial spike over the point, the "pointed" roof of the old bay houses.
		Kit.spire(m, "Spike", 0, zc, H - 0.5, SHAPE.spike, 0.7, trim, 2)
		Kit.ball(m, "Finial", Vector3.new(0, H + 1.2, zc), 1.2, trim, "trim")
	end

	-------------------------------------------------------------------------------------------------------
	-- Openings: French doors and shuttered windows onto the veranda, the ground storey's door and windows
	-------------------------------------------------------------------------------------------------------
	local fz = z0 + ui -- the upper storey's front
	Kit.glass(m, "FrenchDoor", Vector3.new(-1.6, floorY, fz - 0.2), Vector3.new(1.6, floorY + 7.4, fz + 0.2), glass, {
		image = City.textures.windowBold,
		faces = front,
		u = 1.6,
		v = 2.4,
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
			Vector3.new(x + 2.4, floorY + 7.5, fz + 0.1),
			shutter
		)
		Kit.glass(
			m,
			`Window{i}`,
			Vector3.new(x - 1.2, floorY + 1.4, fz - 0.25),
			Vector3.new(x + 1.2, floorY + 7.4, fz + 0.1),
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
			Vector3.new(wallX + sx * 0.2, floorY + 7.4, zc + 1.2),
			glass,
			{ image = City.textures.windowBold, faces = { face }, u = 1.2, v = 3, lines = TRIM, lit = true }
		)
	end

	-- The front door sits in the middle of a post bay (an odd number of posts puts one in the middle).
	local bay = 2 * inner / (n - 1)
	local doorX = if n % 2 == 0 then 0 else -bay / 2
	local gz = z0 + gi -- the ground storey's front
	Kit.trim(m, "Door", Vector3.new(doorX - 1.4, 0, gz - 0.15), Vector3.new(doorX + 1.4, 7.2, gz + 0.1), shutter)
	local gx = dx - gi
	for i, span in { { -gx + 1.4, doorX - 2.6 }, { doorX + 2.6, gx - 1.4 } } do
		if span[2] - span[1] >= 2.4 then
			Kit.glass(
				m,
				`GroundWindow{i}`,
				Vector3.new(span[1], 2.4, gz - 0.2),
				Vector3.new(span[2], 7.4, gz + 0.1),
				glass,
				{ image = City.textures.windowBold, faces = front, u = 1.6, v = 2.5, lines = TRIM, lit = true }
			)
		end
	end
	local lamp = Kit.detail(
		m,
		"Lamp",
		Vector3.new(doorX + 1.8, 6.2, gz - 0.7),
		Vector3.new(doorX + 2.5, 7.4, gz + 0.05),
		Kit.look(LANTERN, Enum.Material.SmoothPlastic)
	)
	Kit.lit(lamp, "neonAmber") -- warm: a pale kind turns white-hot Neon

	-------------------------------------------------------------------------------------------------------
	-- The lot: a crushed-shell drive up to the deck, a walk to the door, a sea-grape hedge
	-------------------------------------------------------------------------------------------------------
	local shell = Kit.look(SHELL, Enum.Material.Pavement)
	local driveX = inner - bay / 2 -- the middle of the last post bay
	Kit.detail(m, "Drive", Vector3.new(driveX - 4, 0.02, -hd + 0.2), Vector3.new(driveX + 4, 0.14, z0 - 0.5), shell)
	Kit.detail(m, "Walk", Vector3.new(doorX - 1.5, 0.02, -hd + 0.2), Vector3.new(doorX + 1.5, 0.14, gz - 0.2), shell)
	local hedgeEnd = math.min(doorX - 2.2, driveX - 5)
	if hedgeEnd - (-hw + 1) >= 2 then
		Kit.trim(
			m,
			"Hedge",
			Vector3.new(-hw + 1, 0, -hd + 1),
			Vector3.new(hedgeEnd, 3.4, -hd + 3),
			Kit.look(GRAPE, Enum.Material.LeafyGrass)
		)
	end
end

local archetype: Types.Archetype = { id = "veranda_raised_house", build = build }
return archetype
