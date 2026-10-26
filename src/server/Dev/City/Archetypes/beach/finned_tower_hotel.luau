--!strict
-- B08 finned_tower_hotel (docs/city/ARCHETYPES.md §6, B08): the beach avenue's all-white mid-century hotel tower. A
-- symmetric slab that steps up like a wedding cake: two outer wings, two shoulders a floor higher, and a centre tower
-- standing proud of them all, full height, a white spine rib running up the middle of its face. Its windows come in
-- tall strips with white piers between (each strip standing out of the wall, so every pier throws a shadow line), and
-- corner windows stand proud at the wings' outer corners. Over the roof the centre breaks out into a square shaft with
-- the name on its face, a cap and a mast, and its signature: tall white fins at the shaft's edges that rise from the
-- roof, flare out and end in sharp horns over the cap, like a 1940s rocket's tail. The lobby storey sits in under the
-- slab behind a porch whose two piers carry the tower; a flat canopy on round columns runs out to the street over a
-- forecourt with planters.
--
-- What makes it itself: an all-white stepped slab whose spined centre tower breaks out above the roof into a crown of
-- flared fins.
-- Placement, sizes, heights and its budget: Config/CityArchetypes/finned_tower_hotel.
-- Variants: palette (1 all white with a cool white spine, 2 white with sky trim and a blue spine, 3 warm white with
-- mint), crown (1 four fins in an X on the shaft's corners, seen from every side; 2 two bigger fins in the facade
-- plane, seen whole from the street, and a stepped cap), rhythm (1 windows in pairs, wings two floors down; 2 single
-- windows in more, narrower strips, wings three floors down), mirror (one wing stands a floor lower than the other:
-- which one).
--
-- Previewing (the Studio helper): a mid view from about 250 studs and a street view at eye height. Check that each fin
-- reads as one shape (blade, flare and horn meeting with no gaps or slivers; the flare widening upward; the horn's
-- point outermost and highest; crown 1's fins on the diagonals, crown 2's in the facade plane), that the slab steps
-- down symmetrically from the centre (one wing a floor lower), that the window strips' tiles fall one window a floor
-- (no window cut by a floor line), that the spine stands proud up the centre and stops at the roof, and that the porch
-- piers carry the tower's front. At night: the centre tower's window strips and the lobby glow, the spine glows white
-- (blue for palette 2, cyan for 3), the ring under the cap and the canopy edge glow, and the wash lights the shaft, the
-- name and the fins' roots. Compare with photos of its inspiration (ARCHETYPES.md B08).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local City = require(ReplicatedStorage.Shared.Config.City)
local Kit = require(script.Parent.Parent.Parent.Kit)
local Types = require(script.Parent.Parent.Parent.Types)

local P = City.palettes
local KIT = City.kit
local rgb = Color3.fromRGB

-- The recipe, in studs.
local SHAPE = {
	ground = 16, -- the lobby storey, set in under the slab
	floorMin = 11,
	minFloors = 9,
	terrace = 9, -- the wings' faces stand this far behind the front line
	sideInset = 1.5,
	lobbyInset = 2.5, -- the lobby glass sits this far behind the wings' faces
	centre = { 0.16, 10, 16 }, -- the centre tower's half width: share of the site's width, clamped
	shoulder = { 0.12, 8, 13 }, -- each shoulder's width
	proud = { centre = 3, shoulder = 1.4 }, -- their faces stand this far in front of the wings'
	drops = { { 1, 2, 3 }, { 1, 3, 4 } }, -- by rhythm: floors the shoulders, the left and the right wing stand lower
	-- Window strips by rhythm: a window's tile, windows per strip, the white pier between strips, and how far a strip
	-- stands out of its wall (the centre tower's lit strips sit flush, so their glowing sides never show).
	strips = { { tile = 3.2, tiles = 2, gap = 5, proud = 0.6 }, { tile = 3.4, tiles = 1, gap = 4, proud = 0.6 } },
	pier = 1, -- a strip keeps at least this much wall either side
	sideTile = 4, -- windows on the sides and back
	cornice = { thick = 0.9, proud = 0.8 },
	cornerBay = { width = 6.5, proud = 1.4 }, -- corner windows standing out at the wings' outer corners
	rib = { half = 0.9, proud = 3, neon = 0.25 },
	shaft = { half = 8, inset = 2.5, back = 2, depth = 14 }, -- over the roof: half width at most, in from the tower's
	-- sides at least, its face this far behind the tower's
	rise = { 33, 31 }, -- by crown: the shaft over the roof
	cap = { thick = 1.1, proud = 0.8, step = 0.9, inset = 1.6 },
	-- The fins: the blade's width, where the flare starts (share of the shaft's rise), its reach at the cap and the
	-- horn's height over the cap, by crown.
	fin = { thick = 1.2, base = 2, flare = 0.4, reach = { 9, 11.5 }, tip = { 7, 9 } },
	ring = { drop = 1.6, thick = 0.45 }, -- the crown's ring under the cap
	mast = { diameter = 0.9, rise = 1.2 }, -- the beacon's ball tops it
	porch = { y = 12.5, thick = 1.2, past = 4, column = 1.6, pier = 1.8 },
	forecourt = 0.4,
	planter = 1.6,
	name = { height = 5.4, below = 2.6 }, -- on the shaft's face, its top this far under the cap (big: it reads from the beach)
}

-- Body, accent (the canopy edge and the spine by day), the spine's night kind, the name's colour and the wash's.
local PALETTES = {
	{
		body = P.frame.white,
		accent = rgb(232, 238, 246),
		spine = "crown",
		text = rgb(120, 136, 156),
		wash = rgb(190, 210, 255),
	},
	{
		body = P.frame.white,
		accent = P.deco.sky,
		spine = "neonBlue",
		text = rgb(60, 140, 190),
		wash = rgb(140, 190, 255),
	},
	{
		body = rgb(250, 246, 236),
		accent = P.deco.mint,
		spine = "sign",
		text = rgb(50, 140, 110),
		wash = rgb(150, 236, 210),
	},
}

type Strips = { tile: number, tiles: number, gap: number, proud: number }

local function share(size: number, rule: { number }): number
	return math.clamp(size * rule[1], rule[2], rule[3])
end

-- Window strips across a block's face from x = a to b, on the face at zFace, from y0 up to `top` (both floor lines, so
-- every tile is one window on one floor): evenly spaced, each `tiles` windows wide (narrower when the block is), white
-- wall between. Flush and lit, or standing `proud` out. 1 part each.
local function strips(
	m: Types.Model,
	name: string,
	a: number,
	b: number,
	zFace: number,
	y0: number,
	top: number,
	f: number,
	r: Strips,
	wall: Color3,
	lit: boolean
)
	local span = b - a
	local w = math.min(r.tile * r.tiles, span - 2 * SHAPE.pier)
	if w < 2 then
		return
	end
	local n = math.max(1, math.round(span / (w + r.gap)))
	local pitch = span / n
	local out = if lit then 0.06 else r.proud
	for k = 1, n do
		local cx = a + pitch * (k - 0.5)
		Kit.punched(
			m,
			`{name}{k}`,
			Vector3.new(cx - w / 2, y0, zFace - out),
			Vector3.new(cx + w / 2, top, zFace + 0.3),
			wall,
			P.window.dark,
			{ Enum.NormalId.Front },
			w / r.tiles,
			f,
			lit
		)
	end
end

-- One fin in the upright plane through the shaft's edge at (cx, cz), running out along `e` (a level unit vector): a
-- blade up the edge from y0 to the cap at yS, a flare from yM widening to `reach` at yS, and a horn over the cap whose
-- point is the fin's outermost, highest corner and whose top edge falls back to the shaft. 3 parts.
local function fin(
	m: Types.Model,
	name: string,
	cx: number,
	cz: number,
	e: Vector3,
	y0: number,
	yM: number,
	yS: number,
	reach: number,
	tip: number,
	look: Kit.Look
)
	local f = SHAPE.fin
	local up = Vector3.yAxis
	local across = up:Cross(e) -- the fin's thickness
	local root = Vector3.new(cx, 0, cz)
	local function at(u: number, y: number): Vector3
		return root + e * u + up * y
	end
	local b = f.base
	-- A wedge's right angle is its own bottom back edge; each frame below puts it where the fin needs it: the flare's at
	-- (base, yS), its slope falling to (base, yM); the horn's at (reach, yS), its slope falling back to the shaft.
	Kit.oriented(
		m,
		name .. "Blade",
		"block",
		CFrame.fromMatrix(at((b - 1) / 2, (y0 + yS) / 2), across, up, e),
		Vector3.new(f.thick, yS - y0, b + 1),
		look,
		"trim"
	)
	Kit.oriented(
		m,
		name .. "Flare",
		"wedge",
		CFrame.fromMatrix(at((b + reach) / 2, (yM + yS) / 2), across, -up, -e),
		Vector3.new(f.thick, yS - yM, reach - b),
		look,
		"trim"
	)
	Kit.oriented(
		m,
		name .. "Horn",
		"wedge",
		CFrame.fromMatrix(at((reach - 1) / 2, yS + tip / 2), across, up, e),
		Vector3.new(f.thick, tip, reach + 1),
		look,
		"trim"
	)
end

local function build(m: Types.Model)
	local site = m.site
	local variant = site.variant
	local pal = PALETTES[math.clamp(variant.palette, 1, #PALETTES)]
	local crown = math.clamp(variant.crown, 1, 2)
	local rhythm = math.clamp(variant.rhythm, 1, 2)
	local rng = Kit.rng(m)
	local W, D = site.width, site.depth
	local hw, hd = W / 2, D / 2
	local G = SHAPE.ground
	local up = math.max(SHAPE.minFloors, math.floor((site.height - G) / SHAPE.floorMin))
	local f = (site.height - G) / up
	local H = G + up * f

	local body = Kit.look(pal.body, Enum.Material.SmoothPlastic)
	local terrazzo = Kit.look(P.deco.terrazzo, Enum.Material.SmoothPlastic)
	local dark = P.window.dark
	local drops = SHAPE.drops[rhythm]
	local rs = SHAPE.strips[rhythm]
	local tile = SHAPE.sideTile

	local x0, x1 = -hw + SHAPE.sideInset, hw - SHAPE.sideInset
	local zF = -hd + SHAPE.terrace -- the wings' faces
	local zB = hd - 1
	local cT = share(W, SHAPE.centre) -- the centre tower's half width
	local cS = cT + share(W, SHAPE.shoulder) -- the shoulders' outer sides
	local zT = zF - SHAPE.proud.centre -- the tower's face
	local zM = zF - SHAPE.proud.shoulder -- the shoulders' faces
	local li = SHAPE.lobbyInset
	local cor = SHAPE.cornice
	local rb = SHAPE.rib

	-------------------------------------------------------------------------------------------------------
	-- The lobby storey under the slab, its glass across the front
	-------------------------------------------------------------------------------------------------------
	Kit.box(m, "Base", Vector3.new(x0 + 0.6, -KIT.bury, zF + li), Vector3.new(x1 - 0.6, G + 0.3, zB - 0.6), body)
	Kit.glass(m, "Lobby", Vector3.new(x0 + 2, 0.4, zF + li - 0.12), Vector3.new(x1 - 2, G - 1.4, zF + li + 0.3), dark, {
		image = City.textures.windowBold,
		faces = { Enum.NormalId.Front },
		u = 4,
		v = G - 1.8,
		lines = pal.body,
		lit = true,
	})

	-------------------------------------------------------------------------------------------------------
	-- The slab: wings, shoulders and the centre tower, each a stucco block whose top is a floor line, stepping up
	-- toward the centre, each with its cornice; windows in strips across their faces and in thin punched skins on the
	-- sides and the back that show (every skin's top and foot on floor lines, so its tiles fall one window a floor)
	-------------------------------------------------------------------------------------------------------
	local shoulderTop = H - drops[1] * f
	local wingTops = { H - drops[2] * f, H - drops[3] * f }
	local cb2 = SHAPE.cornerBay
	Kit.box(m, "Tower", Vector3.new(-cT, G, zT), Vector3.new(cT, H, zB), body)
	for i, side in { -1, 1 } do
		-- The tower's sides over the shoulders.
		local face = if side < 0 then Enum.NormalId.Left else Enum.NormalId.Right
		local sa, sb = side * (cT - 0.3), side * (cT + 0.06)
		Kit.punched(
			m,
			`TowerSide{i}`,
			Vector3.new(math.min(sa, sb), shoulderTop, zT + 1),
			Vector3.new(math.max(sa, sb), H, zB - 1),
			pal.body,
			dark,
			{ face },
			tile,
			f
		)
	end
	-- The back, across the whole slab up to the lower wing's roof.
	Kit.punched(
		m,
		"Back",
		Vector3.new(x0 + 0.6, G, zB - 0.3),
		Vector3.new(x1 - 0.6, math.min(wingTops[1], wingTops[2]), zB + 0.06),
		pal.body,
		dark,
		{ Enum.NormalId.Back },
		tile,
		f
	)
	Kit.trim(
		m,
		"TowerCornice",
		Vector3.new(-cT - cor.proud, H - cor.thick + 0.06, zT - cor.proud),
		Vector3.new(cT + cor.proud, H + 0.06, zB + cor.proud * 0.5),
		body
	)
	-- The centre tower's two strips, either side of the spine, glow at night: a lit column up the middle of the slab.
	strips(m, "TowerWindowsL", -cT, -rb.half, zT, G, H, f, rs, pal.body, true)
	strips(m, "TowerWindowsR", rb.half, cT, zT, G, H, f, rs, pal.body, true)

	for i, side in { -1, 1 } do
		-- A shoulder, reaching a little into the tower so no faces meet in one plane.
		local sa, sb = side * (cT - 0.5), side * cS
		local sLo, sHi = math.min(sa, sb), math.max(sa, sb)
		Kit.box(m, `Shoulder{i}`, Vector3.new(sLo, G, zM), Vector3.new(sHi, shoulderTop, zB - 0.04), body)
		local ca = if side < 0 then sLo - cor.proud else sLo
		local cb = if side < 0 then sHi else sHi + cor.proud
		Kit.trim(
			m,
			`ShoulderCornice{i}`,
			Vector3.new(ca, shoulderTop - cor.thick + 0.06, zM - cor.proud),
			Vector3.new(cb, shoulderTop + 0.06, zB + cor.proud * 0.5),
			body
		)
		strips(
			m,
			`ShoulderWindows{i}`,
			math.min(sb, side * cT),
			math.max(sb, side * cT),
			zM,
			G,
			shoulderTop,
			f,
			rs,
			pal.body,
			false
		)
		-- The wing, out to the site's side.
		local wingTop = wingTops[i]
		local outer = if side < 0 then x0 else x1
		local wa, wb = side * (cS - 0.5), outer
		local wLo, wHi = math.min(wa, wb), math.max(wa, wb)
		Kit.box(m, `Wing{i}`, Vector3.new(wLo, G, zF), Vector3.new(wHi, wingTop, zB - 0.08), body)
		-- Its outer side, behind the corner windows.
		local outerFace = if side < 0 then Enum.NormalId.Left else Enum.NormalId.Right
		local ka, kb = outer - side * 0.3, outer + side * 0.06
		Kit.punched(
			m,
			`WingSide{i}`,
			Vector3.new(math.min(ka, kb), G, zF + cb2.width + 0.6),
			Vector3.new(math.max(ka, kb), wingTop, zB - 0.6),
			pal.body,
			dark,
			{ outerFace },
			tile,
			f
		)
		local wca = if side < 0 then wLo - cor.proud else wLo
		local wcb = if side < 0 then wHi else wHi + cor.proud
		Kit.trim(
			m,
			`WingCornice{i}`,
			Vector3.new(wca, wingTop - cor.thick + 0.06, zF - cor.proud),
			Vector3.new(wcb, wingTop + 0.06, zB + cor.proud * 0.5),
			body
		)
		-- Strips between the shoulder and the corner windows.
		local ia, ib = side * cS, outer - side * cb2.width
		strips(m, `WingWindows{i}`, math.min(ia, ib), math.max(ia, ib), zF, G, wingTop, f, rs, pal.body, false)
		-- Corner windows standing out at the wing's outer front corner, stopping a floor under its roof.
		local ba, bb = outer - side * cb2.width, outer + side * (cb2.proud - 0.25)
		Kit.punched(
			m,
			`CornerBay{i}`,
			Vector3.new(math.min(ba, bb), G, zF - cb2.proud),
			Vector3.new(math.max(ba, bb), wingTop - f, zF + cb2.width),
			pal.body,
			dark,
			{ Enum.NormalId.Front, outerFace },
			cb2.width / 2,
			f
		)
		Kit.trim(
			m,
			`CornerCap{i}`,
			Vector3.new(math.min(ba, bb) - 0.3, wingTop - f, zF - cb2.proud - 0.3),
			Vector3.new(math.max(ba, bb) + (if side > 0 then 0.25 else 0.3), wingTop - f + 0.8, zF + cb2.width + 0.3),
			body
		)
	end
	-- A stair house on the higher wing's roof.
	local hi = if wingTops[1] >= wingTops[2] then 1 else 2
	local hx = if hi == 1 then x0 + 7 else x1 - 7
	Kit.roofBox(
		m,
		"Stair",
		Vector3.new(hx - 3.5, wingTops[hi], zB - 11),
		Vector3.new(hx + 3.5, wingTops[hi] + 6.5, zB - 4),
		body
	)

	-------------------------------------------------------------------------------------------------------
	-- The spine: a white rib up the middle of the tower's face, lit along its edge at night
	-------------------------------------------------------------------------------------------------------
	local pr = SHAPE.porch
	local ribTop = H + 1.2
	Kit.trim(
		m,
		"Spine",
		Vector3.new(-rb.half, pr.y + pr.thick, zT - rb.proud),
		Vector3.new(rb.half, ribTop, zT + 0.3),
		body
	)
	Kit.neonStrip(
		m,
		"SpineNeon",
		Vector3.new(-rb.neon, pr.y + pr.thick + 1, zT - rb.proud - 0.15),
		Vector3.new(rb.neon, ribTop - 0.6, zT - rb.proud + 0.05),
		pal.spine,
		pal.accent
	)

	-------------------------------------------------------------------------------------------------------
	-- The porch under the tower: two piers carry its front, a flat canopy on round columns runs out to the street
	-------------------------------------------------------------------------------------------------------
	for i, side in { -1, 1 } do
		local px = side * (cT - 1.2)
		Kit.box(
			m,
			`Pier{i}`,
			Vector3.new(px - pr.pier / 2, -KIT.bury, zT + 0.3),
			Vector3.new(px + pr.pier / 2, G + 0.05, zT + 0.3 + pr.pier),
			body
		)
	end
	local cw = cT + pr.past
	local zC = -hd + 1
	Kit.canopy(m, "Canopy", -cw, cw, zC, zT + 0.6, pr.y, pr.thick, body)
	Kit.neonStrip(
		m,
		"CanopyLed",
		Vector3.new(-cw, pr.y + 0.3, zC - 0.15),
		Vector3.new(cw, pr.y + 0.75, zC + 0.05),
		"ledBlue",
		pal.accent
	)
	for i, side in { -1, 1 } do
		Kit.column(m, `Column{i}`, side * (cw - 1.3), zC + 1.3, -KIT.bury, pr.y, pr.column, body)
	end
	local names = City.signNames.hotels
	local name = names[rng:NextInteger(1, #names)]
	local sw = math.min(cw * 0.8, 13)
	Kit.sign(
		m,
		"CanopySign",
		Vector3.new(-sw, pr.y + pr.thick, zC + 0.4),
		Vector3.new(sw, pr.y + pr.thick + 2.2, zC + 0.8),
		Enum.NormalId.Front,
		name,
		pal.body,
		pal.text,
		City.districtLooks.beach.font
	)
	Kit.box(
		m,
		"Forecourt",
		Vector3.new(-hw + 0.2, 0, -hd + 0.3),
		Vector3.new(hw - 0.2, SHAPE.forecourt, zF + li + 0.3),
		terrazzo
	)
	for i, side in { -1, 1 } do
		local a, b = side * (cw + 2.5), side * (hw - 1.5)
		Kit.planter(
			m,
			`Planter{i}`,
			Vector3.new(math.min(a, b), SHAPE.forecourt, -hd + 0.8),
			Vector3.new(math.max(a, b), SHAPE.forecourt + SHAPE.planter, -hd + 2.6),
			body
		)
	end

	-------------------------------------------------------------------------------------------------------
	-- The crown: the shaft over the centre, its name, a cap with a lit ring under it, a mast, and the fins
	-------------------------------------------------------------------------------------------------------
	local sh = SHAPE.shaft
	local sx = math.min(sh.half, cT - sh.inset)
	local zS0 = zT + sh.back
	local zS1 = math.min(zS0 + sh.depth, zB - 2)
	local zSc = (zS0 + zS1) / 2
	local yS = H + SHAPE.rise[crown] -- the shaft's top: the cap sits on it
	Kit.box(m, "Shaft", Vector3.new(-sx, H - 0.3, zS0), Vector3.new(sx, yS, zS1), body)
	local cp = SHAPE.cap
	Kit.trim(
		m,
		"Cap",
		Vector3.new(-sx - cp.proud, yS - 0.05, zS0 - cp.proud),
		Vector3.new(sx + cp.proud, yS + cp.thick, zS1 + cp.proud),
		body
	)
	local capTop = yS + cp.thick
	if crown == 2 then
		Kit.trim(
			m,
			"CapStep",
			Vector3.new(-sx + cp.inset, capTop - 0.05, zS0 + cp.inset),
			Vector3.new(sx - cp.inset, capTop + cp.step, zS1 - cp.inset),
			body
		)
		capTop += cp.step
	end
	local rg = SHAPE.ring
	Kit.neonStrip(
		m,
		"CrownRing",
		Vector3.new(-sx - 0.15, yS - rg.drop - rg.thick, zS0 - 0.15),
		Vector3.new(sx + 0.15, yS - rg.drop, zS1 + 0.15),
		"crown",
		pal.accent
	)
	local nm = SHAPE.name
	Kit.sign(
		m,
		"Name",
		Vector3.new(-sx + 1.2, yS - nm.below - nm.height, zS0 - 0.45),
		Vector3.new(sx - 1.2, yS - nm.below, zS0 - 0.08),
		Enum.NormalId.Front,
		name,
		pal.body,
		pal.text,
		City.districtLooks.beach.font
	)
	-- The mast: as high as the crown room allows, its beacon's ball on top.
	local mastTop = site.maxHeight - SHAPE.mast.rise - 0.2
	Kit.spire(
		m,
		"Mast",
		0,
		zSc,
		capTop - 0.1,
		mastTop - capTop + 0.1,
		SHAPE.mast.diameter,
		Kit.look(rgb(214, 218, 224), Enum.Material.Metal),
		2,
		true
	)
	-- The fins: from the roof up the shaft's edges, flaring out from a share of the way up to their reach at the cap,
	-- then a horn over the cap.
	local fn = SHAPE.fin
	local reach, tip = fn.reach[crown], fn.tip[crown]
	local yM = H + (yS - H) * fn.flare
	if crown == 1 then
		local r = math.sqrt(0.5)
		for i, c in { { -1, -1 }, { 1, -1 }, { -1, 1 }, { 1, 1 } } do
			local cz = if c[2] < 0 then zS0 else zS1
			fin(m, `Fin{i}`, c[1] * sx, cz, Vector3.new(c[1] * r, 0, c[2] * r), H - 0.3, yM, yS, reach, tip, body)
		end
	else
		for i, side in { -1, 1 } do
			fin(m, `Fin{i}`, side * sx, zSc, Vector3.new(side, 0, 0), H - 0.3, yM, yS, reach, tip, body)
		end
	end
	-- On the tower's roof between its face and the shaft, washing the shaft, the name and the fins' roots.
	Kit.wash(m, "Wash", -sx + 1, sx - 1, (zT + zS0) / 2, H + 0.08, pal.wash)
end

local archetype: Types.Archetype = { id = "finned_tower_hotel", build = build }
return archetype
