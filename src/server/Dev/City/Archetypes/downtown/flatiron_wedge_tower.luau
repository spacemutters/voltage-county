--!strict
-- T07 flatiron_wedge_tower (docs/city/ARCHETYPES.md §5, T07): a glass tower on a three-cornered plan with rounded
-- corners, its nose pointing at the street and its two long faces running back from it. White balcony slabs wrap
-- the nose and both long faces every second floor, swelling and shrinking floor by floor like wind on water, with a
-- white floor line on the glass between them; the flat back face carries vertical fins. It stands on a podium of the
-- same plan clad in perforated metal, with a glass shopfront wrapping the nose under a curved canopy, and its crown
-- sweeps up toward the nose.
--
-- What makes it itself: a rounded prow at the street, striped with swelling white balcony lines, rising to a swept
-- crown.
-- Placement, sizes, heights and its budget: Config/CityArchetypes/flatiron_wedge_tower.
-- Variants: palette (3 glass, metal and crown sets), crown (1 a champagne metal screen sweeping up both long faces to
-- a glowing nose, 2 two white rounded lobes at different heights over the nose and a back corner), rhythm (1 the nose
-- on the site's middle, 2 the nose swung toward one side), mirror.
--
-- Seen in Studio 2026-10-25, day and night (docs/images/city/flatiron_wedge_tower-day.jpg, -night.jpg).
-- Preview check: the plan reads as a wedge from the street at 45 degrees; the rounded corners
-- are smooth (a column each) with no seam where the long-face skins meet them; the balcony slabs' square ends at the
-- back corners look clean; the wave of the slabs reads as movement, not noise (tune SHAPE.proud); the prisms' sloped
-- faces never show (they are inside the skins); the crown screens emerge from the roof cleanly; nothing pokes past the
-- footprint at 70 and 130 wide, 46 and 53 deep.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local City = require(ReplicatedStorage.Shared.Config.City)
local Kit = require(script.Parent.Parent.Parent.Kit)
local Types = require(script.Parent.Parent.Parent.Types)

local P = City.palettes
local KIT = City.kit
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
	skew = { 0, 0.7 }, -- by rhythm: how far the nose swings toward one side, share of the room it has
	skewKeep = 4, -- the nose's centre keeps this far inside the back corners' centres
	level = 10, -- a podium level
	podiumShare = 0.1, -- the podium's height, share of the tower's (whole levels)...
	levels = { 3, 5 }, -- ...between these
	podiumGrow = 1.5, -- the podium stands this far out of the tower's outline
	hair = 0.02, -- so no two of a body's pieces share a top or a bottom
	slab = 1.2, -- balcony slab thickness
	every = 24, -- a balcony slab every second floor
	proud = { 2.6, 1.4 }, -- the slabs' reach past the glass: mean and swing
	wave = 0.8, -- radians of swing from one slab to the next
	tuck = 1.5, -- the slabs reach this far back into the glass
	firstSlab = 18, -- the lowest slab stands at least this far over the podium
	canopy = { reach = 3.5, thick = 1.2, share = 0.5 }, -- share: how far along the long faces it wraps
	shopShare = 0.45, -- how far along the long faces the shopfront wraps
	cap = 1.2, -- the podium cap's reach past the podium
	crownRise = 26, -- crown 1: the crown's height over the roof at the nose
	crownSink = 12, -- the crown's columns start this far under the roof
	screen = 1.2, -- crown 1: the screens' thickness
	screenSink = 6, -- the screens' low ends start this far under the roof
	lobes = { 16, 4 }, -- crown 2: the nose lobe's and the back lobe's tops over the roof...
	lobeLid = { thick = 1.4, over = 1.2 }, -- ...each under a lid this thick, overhanging this far
	finEvery = 9, -- studs between the back face's fins
	fins = { 3, 7 },
	finProud = 3,
}

-- Glass, slabs and fins, the podium's metal and its perforation lines, the crown's champagne and its night kind.
local PALETTES = {
	{
		glass = P.glass.aqua,
		slab = P.frame.white,
		podium = rgb(188, 184, 174),
		lines = rgb(232, 230, 224),
		crown = rgb(196, 176, 136),
		neon = "crown",
	},
	{
		glass = P.glass.silver,
		slab = P.frame.white,
		podium = rgb(168, 170, 172),
		lines = rgb(222, 224, 226),
		crown = rgb(182, 160, 118),
		neon = "neonAmber",
	},
	{
		glass = P.glass.blue,
		slab = P.frame.warm,
		podium = rgb(196, 190, 178),
		lines = rgb(236, 232, 224),
		crown = rgb(204, 186, 148),
		neon = "crown",
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
	-- Tower: glass on the plan with a white floor line every floor, swelling balcony slabs every second floor
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
		ring(`Slab{count}`, y + SHAPE.slab / 2 - 0.1, r - SHAPE.tuck, r + p, SHAPE.slab, 1)
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
		-- A champagne screen sweeping up both long faces from nothing at the back corners to a glowing nose.
		local rise = SHAPE.crownRise
		local nose = Kit.column(
			m,
			"CrownNose",
			A.X,
			A.Z,
			H - SHAPE.crownSink,
			H + rise,
			dn,
			Kit.look(pal.crown, Enum.Material.SmoothPlastic),
			"trim"
		)
		Kit.lit(nose, pal.neon)
		local metal = Kit.look(pal.crown, Enum.Material.Metal)
		local base = H - SHAPE.screenSink
		local tall = rise + SHAPE.screenSink
		for _, side in sides do
			local n = side.normal
			local low = side.corner + n * (r + 0.3)
			local high = A + n * (r + 0.3)
			local d = high - low
			local c = (low + high) / 2 + Vector3.new(0, base + tall / 2, 0)
			-- A WedgePart is tallest at its back (+Z): look toward the low end.
			Kit.oriented(
				m,
				"Screen" .. side.key,
				"wedge",
				CFrame.lookAt(c, c - d),
				Vector3.new(SHAPE.screen, tall, d.Magnitude),
				metal,
				"trim"
			)
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
