--!strict
-- T07 flatiron_wedge_tower (docs/city/ARCHETYPES.md §5, T07): a glass tower on a three-cornered plan with rounded
-- corners, its nose pointing at the street (swung toward the street corner placement puts at its +x end) and its two
-- long faces running back from it. White balcony slabs wrap the nose and both long faces every second floor,
-- swelling and shrinking floor by floor like wind on water, with a white floor line on the glass between them; every
-- fourth one carries a lit edge round the nose, so the prow shows lines of light at night. The flat back face
-- carries vertical fins. It stands on a podium of the same plan clad in perforated metal, with a glass shopfront
-- wrapping the nose under a curved canopy. Its crown is a crest: a row of champagne blades standing on both long
-- faces, tallest at the nose and falling away toward the back, round a champagne drum at the nose; the blades glow
-- at night.
--
-- What makes it itself: a rounded prow at the street, striped with swelling white balcony lines, rising to a crest
-- that sweeps up to the nose.
-- Placement, sizes, heights and its budget: Config/CityArchetypes/flatiron_wedge_tower.
-- Variants: palette (3 glass, metal and crown sets; the crest glows cool white or amber), crown (1 the champagne
-- crest (a stepped screen of panels along both faces) and drum, 2 two white rounded lobes at different heights over
-- the nose and a back corner, as the real tower's top), rhythm (1 the nose
-- a little toward the corner end, 2 swung right out to it), mirror (placement mirrors it to the street corner).
--
-- Preview check (the Studio step): the plan reads as a wedge from the street at 45 degrees; the rounded corners are
-- smooth (a column each) with no seam where the long-face skins meet them; the balcony slabs' square ends at the
-- back corners look clean; the wave of the slabs reads as movement, not noise (tune SHAPE.proud and SHAPE.wave); the
-- prisms' sloped faces never show (they are inside the skins); the crest's panels stand along their faces, step
-- down evenly from the nose and read against the sky from the street and from across downtown, and glow at night
-- with the prow's lit edges under them; nothing pokes past the footprint at 70 and 130 wide, 46, 53 and 100 deep.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local City = require(ReplicatedStorage.Shared.Config.City)
local Kit = require(script.Parent.Parent.Parent.Kit)
local Types = require(script.Parent.Parent.Parent.Types)

local P = City.palettes
local KIT = City.kit
local NIGHT = require(ReplicatedStorage.Shared.Config.Environment).nightLights
local rgb = Color3.fromRGB

local FRONT, BACK = Enum.NormalId.Front, Enum.NormalId.Back

-- The recipe, in studs.
local SHAPE = {
	floor = 12,
	lobby = 15, -- the shopfront glass's top
	front = 6, -- the nose's tip behind the front line (the slabs and the canopy reach past it)
	back = 3.5, -- the back face from the back line (its fins stand out behind it)
	spread = 1.9, -- the base is at most this times the tower's depth (a near right-angled nose, not a pencil)...
	base = { 44, 104 }, -- ...and between these
	sideRoom = 5, -- the base's ends keep this far from the site's sides (the slabs swing out past them)
	radius = { 0.14, 6, 10 }, -- the rounded corners: share of the base, clamped
	skew = { 0.35, 0.8 }, -- by rhythm: how far the nose swings toward the corner end, share of the room it has
	skewKeep = 4, -- the nose's centre keeps this far inside the back corners' centres
	level = 10, -- a podium level
	podiumShare = 0.1, -- the podium's height, share of the tower's (whole levels)...
	levels = { 3, 5 }, -- ...between these
	podiumGrow = 1.5, -- the podium stands this far out of the tower's outline
	hair = 0.02, -- so no two of a body's pieces share a top or a bottom
	slab = 1.6, -- balcony slab thickness (Studio round 1: 1.2 read as hairlines from across downtown)
	every = 24, -- a balcony slab every second floor
	proud = { 3, 1.6 }, -- the slabs' reach past the glass: mean and swing (at most 4.6, under sideRoom)
	wave = 0.7, -- radians of swing from one slab to the next
	tuck = 1.5, -- the slabs reach this far back into the glass
	firstSlab = 18, -- the lowest slab stands at least this far over the podium
	litEvery = 4, -- every this many slabs, a lit edge under the nose's disc
	canopy = { reach = 3.5, thick = 1.2, share = 0.5 }, -- share: how far along the long faces it wraps
	shopShare = 0.45, -- how far along the long faces the shopfront wraps
	cap = 1.2, -- the podium cap's reach past the podium
	crownSink = 12, -- the crown's drum and lobes start this far under the roof
	crest = {
		rise = 28, -- the nose drum's top over the roof
		lid = 1.2, -- the drum's lid
		blades = { 0.13, 0.33, 0.53, 0.73 }, -- where the screen's panels stand along each long face (share from the nose)
		panel = 0.17, -- each panel's width along the face, share of the face (gaps of 0.03 between them)
		low = 6, -- the last panel's top over the roof, beyond the falling line
		sink = 8, -- the panels start this far under the roof
		thick = 1.4, -- across the face
		out = 0.4, -- the panels stand this far out of the glass
	},
	lobes = { 16, 4 }, -- crown 2: the nose lobe's and the back lobe's tops over the roof...
	lobeLid = { thick = 1.4, over = 1.2 }, -- ...each under a lid this thick, overhanging this far
	finEvery = 9, -- studs between the back face's fins
	fins = { 3, 7 },
	finProud = 3,
}

-- Glass, slabs and fins, the podium's metal and its perforation lines, the crown's champagne and its night kind. The
-- glass is deep so the white balcony lines stand out of it as in the photos (Studio round 1: aqua and silver glass
-- mirrored the pale sky and the white lines vanished into it; a sandy podium read olive).
local PALETTES = {
	{
		glass = P.glass.teal,
		slab = P.frame.white,
		podium = rgb(178, 182, 186),
		lines = rgb(226, 228, 230),
		crown = rgb(200, 180, 138),
		neon = "crown",
		crestNight = rgb(112, 132, 160),
	},
	{
		glass = P.glass.blue,
		slab = P.frame.white,
		podium = rgb(150, 156, 162),
		lines = rgb(222, 226, 230),
		crown = rgb(186, 164, 120),
		neon = "neonAmber",
		crestNight = rgb(170, 112, 44),
	},
	{
		glass = P.glass.navy,
		slab = P.frame.warm,
		podium = rgb(204, 194, 176),
		lines = rgb(240, 234, 222),
		crown = rgb(208, 190, 150),
		neon = "crown",
		crestNight = rgb(150, 130, 96),
	},
}

local function build(m: Types.Model)
	local site = m.site
	local variant = site.variant
	local pal = PALETTES[math.clamp(variant.palette, 1, #PALETTES)]
	local rhythm = math.clamp(variant.rhythm, 1, 2)
	local rng = Kit.rng(m)
	local W, D, H = site.width, site.depth, site.height
	local hd = D / 2
	local F = SHAPE.floor
	local white = Kit.look(pal.slab, Enum.Material.SmoothPlastic)
	local tag = City.signNames.towers[rng:NextInteger(1, #City.signNames.towers)]

	-------------------------------------------------------------------------------------------------------
	-- The plan: an inner triangle A (the nose), B (back left), C (back right); the outline is it grown by r
	-------------------------------------------------------------------------------------------------------
	local zN = -hd + SHAPE.front
	local zK = hd - SHAPE.back
	local td = zK - zN
	local bw = math.clamp(math.min(W - 2 * SHAPE.sideRoom, td * SHAPE.spread), SHAPE.base[1], SHAPE.base[2])
	local r = math.clamp(bw * SHAPE.radius[1], SHAPE.radius[2], SHAPE.radius[3])
	local xn = SHAPE.skew[rhythm] * (bw / 2 - r - SHAPE.skewKeep)
	local A = Vector3.new(xn, 0, zN + r)
	local B = Vector3.new(-bw / 2 + r, 0, zK - r)
	local C = Vector3.new(bw / 2 - r, 0, zK - r)
	local G = (A + B + C) / 3

	-- The outward normal of the edge from p to q (in plan).
	local function outward(p: Vector3, q: Vector3): Vector3
		local d = (q - p).Unit
		local n = Vector3.new(d.Z, 0, -d.X)
		return if n:Dot(G - p) > 0 then -n else n
	end
	local nL, nR = outward(A, B), outward(A, C)
	local sides = { { corner = B, normal = nL, key = "L" }, { corner = C, normal = nR, key = "R" } }

	-- Which face of a Kit.strut from p to q looks along n (its local x is (-dz, 0, dx) in plan).
	local function outerFace(p: Vector3, q: Vector3, n: Vector3): Enum.NormalId
		local d = q - p
		return if Vector3.new(-d.Z, 0, d.X):Dot(n) > 0 then Enum.NormalId.Right else Enum.NormalId.Left
	end
	local function overlay(
		spec: Types.PartSpec,
		face: Enum.NormalId,
		image: string,
		u: number,
		v: number,
		color: Color3
	)
		spec.textures = { { face = Kit.face(m, face), image = image, u = u, v = v, color = color } }
	end

	-- The rounded plan grown g past the outline, from y0 to y1: two prisms fill the inner triangle, a column stands at
	-- each corner, a box runs along the back edge and a skin along each long face. 8 parts; returns the left skin, the
	-- right skin and the back box (for their overlays).
	local function body(name: string, y0: number, y1: number, g: number, look: Kit.Look): { Types.PartSpec }
		local hair = SHAPE.hair
		local reach = r + g
		Kit.prism(m, name .. "PrismL", Vector3.new(B.X, y0, A.Z), Vector3.new(A.X, y1, B.Z), "br", look)
		Kit.prism(m, name .. "PrismR", Vector3.new(A.X, y0, A.Z), Vector3.new(C.X, y1, C.Z), "bl", look)
		for i, p in { A, B, C } do
			Kit.column(m, `{name}Round{i}`, p.X, p.Z, y0 + 2 * hair, y1 - 2 * hair, 2 * reach, look)
		end
		local back = Kit.box(
			m,
			name .. "Back",
			Vector3.new(B.X, y0 + hair, B.Z - 0.3),
			Vector3.new(C.X, y1 - hair, B.Z + reach),
			look
		)
		local mid = Vector3.new(0, (y0 + y1) / 2, 0)
		local off = (reach - 0.3) / 2
		local out: { Types.PartSpec } = {}
		for _, side in sides do
			local n = side.normal
			table.insert(
				out,
				Kit.strut(
					m,
					name .. "Skin" .. side.key,
					A + n * off + mid,
					side.corner + n * off + mid,
					y1 - y0 - 2 * hair,
					look,
					"box",
					reach + 0.3
				)
			)
		end
		table.insert(out, back)
		return out
	end

	-------------------------------------------------------------------------------------------------------
	-- Podium: perforated metal on the same plan, a glass shopfront round the nose, a curved canopy, a white cap
	-------------------------------------------------------------------------------------------------------
	local levels = math.clamp(math.round(H * SHAPE.podiumShare / SHAPE.level), SHAPE.levels[1], SHAPE.levels[2])
	local pTop = 16 + levels * SHAPE.level
	local g = SHAPE.podiumGrow
	local pod = body("Podium", -KIT.bury, pTop, g, Kit.look(pal.podium, Enum.Material.Metal))
	for i, side in sides do
		overlay(pod[i], outerFace(A, side.corner, side.normal), City.textures.windowBold, 2.5, 2.5, pal.lines)
	end
	overlay(pod[3], BACK, City.textures.windowBold, 2.5, 2.5, pal.lines)

	local shopGlass = Kit.glassLook(rgb(44, 60, 70), 0.2)
	local lr = r + g + 0.3 -- the shopfront stands 0.3 out of the podium
	Kit.lit(Kit.column(m, "ShopNose", A.X, A.Z, 0.2, SHAPE.lobby, 2 * lr, shopGlass, "trim"), "window")
	local shopMid = Vector3.new(0, (0.2 + SHAPE.lobby) / 2, 0)
	for _, side in sides do
		local n = side.normal
		local to = A + (side.corner - A) * SHAPE.shopShare
		local spec = Kit.strut(
			m,
			"Shop" .. side.key,
			A + n * (lr - 0.25) + shopMid,
			to + n * (lr - 0.25) + shopMid,
			SHAPE.lobby - 0.2,
			shopGlass,
			"trim",
			0.5
		)
		overlay(spec, outerFace(A, side.corner, n), City.textures.windowBold, 5, SHAPE.lobby - 0.2, pal.slab)
		Kit.lit(spec, "window")
	end

	-- A ring of slab round the nose and along both faces: the shape of the plan grown `out`, `inner` to `outer` from
	-- the inner triangle's edges, `thick` thick, centred at y; along `share` of each long face. 3 parts.
	local function ring(name: string, y: number, inner: number, outer: number, thick: number, share: number)
		Kit.disc(m, name .. "Nose", A.X, A.Z, y, 2 * outer, thick, white)
		local at = Vector3.new(0, y, 0)
		local off = (inner + outer) / 2
		for _, side in sides do
			local n = side.normal
			local to = A + (side.corner - A) * share
			Kit.strut(m, name .. side.key, A + n * off + at, to + n * off + at, thick, white, "trim", outer - inner)
		end
	end
	local cn = SHAPE.canopy
	local canopyY = SHAPE.lobby + 0.4 + cn.thick / 2
	local canopyR = r + g + cn.reach
	ring("Canopy", canopyY, r + g - 1, canopyR, cn.thick, cn.share)
	local canopyTop = canopyY + cn.thick / 2
	Kit.sign(
		m,
		"Name",
		Vector3.new(A.X - 5, canopyTop, A.Z - canopyR + 1.6),
		Vector3.new(A.X + 5, canopyTop + 2.4, A.Z - canopyR + 2.1),
		FRONT,
		tag,
		rgb(40, 44, 50),
		pal.slab,
		City.districtLooks.downtown.font
	)
	ring("PodiumCap", pTop + SHAPE.slab / 2, r + g - 1, r + g + SHAPE.cap, SHAPE.slab, 1)

	-------------------------------------------------------------------------------------------------------
	-- Tower: glass on the plan with a white floor line every floor, swelling balcony slabs every second floor, a lit
	-- edge round the nose under every fourth
	-------------------------------------------------------------------------------------------------------
	local tower = body("Tower", pTop - 0.5, H, 0, Kit.glassLook(pal.glass))
	for i, side in sides do
		overlay(tower[i], outerFace(A, side.corner, side.normal), City.textures.slabLine, 8, F, pal.slab)
	end
	overlay(tower[3], BACK, City.textures.windowFine, 6, F, pal.glass:Lerp(pal.slab, 0.45))

	local phase = rng:NextNumber() * 2 * math.pi
	local count = 0
	local y = H - SHAPE.every
	while y >= pTop + SHAPE.firstSlab do
		count += 1
		local p = SHAPE.proud[1] + SHAPE.proud[2] * math.sin(count * SHAPE.wave + phase)
		-- Each slab covers the floor line drawn on the glass at its height.
		local sy = y + SHAPE.slab / 2 - 0.1
		ring(`Slab{count}`, sy, r - SHAPE.tuck, r + p, SHAPE.slab, 1)
		if count % SHAPE.litEvery == 2 then
			-- A lit edge tucked under the nose's disc, a little inside it.
			local edge = Kit.disc(
				m,
				`SlabLed{count}`,
				A.X,
				A.Z,
				sy - SHAPE.slab / 2 - 0.15,
				2 * (r + p) - 0.4,
				0.4,
				white,
				"detail"
			)
			Kit.lit(edge, "ledEdge")
		end
		y -= SHAPE.every
	end

	-- The back face's fins.
	local fins = math.clamp(math.floor((C.X - B.X) / SHAPE.finEvery), SHAPE.fins[1], SHAPE.fins[2])
	Kit.fins(m, "Fin", "back", zK, B.X + 1, C.X - 1, fins, pTop + SHAPE.slab, H - 1, SHAPE.finProud, 1, white)

	-------------------------------------------------------------------------------------------------------
	-- Crown
	-------------------------------------------------------------------------------------------------------
	local dn = 2 * r + 1.2
	if variant.crown == 1 then
		-- The crest: a champagne drum at the nose under a lid, a lit ring round it, and on each long face a row of
		-- blades square to the face, tallest by the nose, falling toward the back; the blades glow at night.
		local cr = SHAPE.crest
		local metal = Kit.look(pal.crown, Enum.Material.Metal)
		local drumTop = H + cr.rise
		Kit.column(m, "CrownDrum", A.X, A.Z, H - SHAPE.crownSink, drumTop, dn, metal, "trim")
		Kit.disc(m, "CrownLid", A.X, A.Z, drumTop + cr.lid / 2, dn + 2, cr.lid, metal)
		Kit.lit(Kit.disc(m, "CrownRing", A.X, A.Z, drumTop - 3, dn + 0.4, 0.8, white, "detail"), pal.neon)
		local bladeLook = Kit.look(pal.crown, Enum.Material.SmoothPlastic)
		local fall = cr.rise - cr.low
		for _, side in sides do
			local n = side.normal
			local run = side.corner - A
			local d = run.Unit
			-- Panels standing along the face, a little out of the glass: a stepped champagne screen falling from the
			-- nose (Studio round 1: blades square to the face read as toothpicks from the street).
			local wide = run.Magnitude * cr.panel
			for i, t in cr.blades do
				local top = H + cr.low + fall * (1 - t)
				local y0 = H - cr.sink
				local foot = A + run * t + n * (r + cr.out + cr.thick / 2)
				local c = foot + Vector3.new(0, (y0 + top) / 2, 0)
				local blade = Kit.oriented(
					m,
					`Blade{side.key}{i}`,
					"block",
					CFrame.fromMatrix(c, d, Vector3.yAxis),
					Vector3.new(wide, top - y0, cr.thick),
					bladeLook,
					"trim"
				)
				Kit.lit(blade, pal.neon)
				-- Its own, dimmer night colour: the kind's colour on panels this big blew out to flat white blocks
				-- (Studio round 2); this reads as champagne metal lit from within.
				local attributes: { [string]: any } = blade.attributes or {}
				attributes[NIGHT.nightColorAttribute] = pal.crestNight
				blade.attributes = attributes
			end
		end
		Kit.trim(m, "ScreenBack", Vector3.new(B.X, H - 2, zK - 1.2), Vector3.new(C.X, H + 5, zK + 0.2), metal)
	else
		-- Two white drums, the nose's taller, each under a crisp overhanging lid, a lit ring round each.
		local lobe = Kit.look(pal.slab, Enum.Material.SmoothPlastic)
		for i, spot in
			{ { at = A, top = SHAPE.lobes[1], key = "Nose" }, { at = C, top = SHAPE.lobes[2], key = "Back" } }
		do
			local p = spot.at
			local lid = SHAPE.lobeLid
			Kit.column(m, `Lobe{spot.key}`, p.X, p.Z, H - SHAPE.crownSink, H + spot.top - lid.thick, dn, lobe)
			Kit.disc(m, `Lobe{spot.key}Top`, p.X, p.Z, H + spot.top - lid.thick / 2, dn + 2 * lid.over, lid.thick, lobe)
			Kit.lit(Kit.disc(m, `LobeRing{i}`, p.X, p.Z, H + 1.5, dn + 0.4, 0.5, lobe, "detail"), "crown")
		end
	end
	Kit.roofBox(m, "Plant", Vector3.new(G.X - 5, H, G.Z - 4), Vector3.new(G.X + 5, H + 7, G.Z + 4))
end

local archetype: Types.Archetype = { id = "flatiron_wedge_tower", build = build }
return archetype
