--!strict
-- C01 cupola_bell_tower (docs/city/ARCHETYPES.md §9, C01): downtown's Spanish Renaissance bell tower, a pale stucco
-- shaft among the glass. A four-storey base with a two-storey arched portal under a broken pediment, a lower press
-- wing under a clay-tile roof, then the square shaft, mostly wall as a bell tower is: stone corner piers, narrow
-- columns of windows, stone belt courses, a frieze and a deep cornice. On top an open belvedere, three arches a side
-- round a lit core, corner obelisks, then an octagonal cupola with arched windows, a copper dome, a gilded lantern and
-- a weather vane.
--
-- What makes it itself: a pale bell tower ending in an open arcade, an octagonal cupola and a green copper dome.
-- Placement, sizes, heights and its budget: Config/CityArchetypes/cupola_bell_tower.
-- Variants: palette (1 cream and copper, 2 ochre and bronze, 3 white and deep teal), crown (1 one octagonal stage with
-- arched windows under a full dome, 2 two stepped octagonal stages with corner urns under a smaller dome), rhythm (1
-- three bays a face, a paired window column between two single ones, and three belts; 2 two paired columns a face,
-- five belts and iron balconies on the front), mirror (the press wing's side).
--
-- Previewing (Studio helper): Preview.build("cupola_bell_tower", { width = 104, depth = 60 }) for the full look
-- (wing, 36-stud tower); also width 64, depth 40 (the smallest: no wing, a 26-stud tower). Check: the shaft reads
-- as pale stucco with narrow window columns (not an office grid), the corner piers proud; the belvedere's
-- arches read as arches (dark half-discs over the openings) from the street, the cupola reads as an octagon, not a
-- star; the dome sits in the cornice disc with no gap; at night the belvedere and the portal glow warm, the lantern
-- amber, and the wash lights the belvedere front.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local City = require(ReplicatedStorage.Shared.Config.City)
local Kit = require(script.Parent.Parent.Parent.Kit)
local Types = require(script.Parent.Parent.Parent.Types)

local P = City.palettes
local KIT = City.kit
local rgb = Color3.fromRGB
local COS8 = math.cos(math.pi / 8) -- an octagon's corner reaches across / (2 cos 22.5)

-- The recipe, in studs.
local SHAPE = {
	sideInset = 1.5,
	forecourt = 9, -- paving between the front line and the base's face
	backInset = 1.5,
	ground = 14, -- the base's ground floor...
	floor = 11, -- ...and its three upper floors
	upper = 3,
	baseMax = 86, -- the base's widest...
	baseDepth = 60, -- ...and deepest (a deeper site keeps paving behind it)
	baseBay = 5.5,
	parapet = 2.6,
	baseCornice = { thick = 1.8, proud = 1.3 },
	plinth = { height = 13, proud = 0.5 }, -- the rusticated stone ground storey
	frontWindows = {
		edge = 3, -- from the base's ends...
		gap = 2.5, -- ...and the portal's surround
		every = 8, -- one column of windows per this much front, at most `most` a side
		most = 2,
		width = 5.4,
		sill = 2.2, -- over the stone ground storey
		head = 2.6, -- under the base's cornice
		ground = { width = 4.4, sill = 2.4, spring = 8.6 },
	},
	wing = { from = 96, share = 0.28, min = 26, max = 36, back = 4, floors = 2, roof = 7, eave = 1.4, bay = 5 },
	tower = { share = 0.42, min = 26, max = 36, setBack = 1.5 },
	towerFloor = 12,
	pier = { wide = 3.2, proud = 0.7 }, -- corner piers
	-- Window columns on the shaft, as shares of their bay: a bell tower is mostly wall, so the windows are narrow.
	-- Rhythm 1: a paired column in the middle bay, single ones either side; rhythm 2: two paired columns.
	strip = { centre = 0.46, side = 0.22, pair = 0.36, max = 9, head = 1.0, litShare = 0.22 },
	belt = { thick = 1.4, proud = 1.1 },
	frieze = 4, -- the ornament band under the cornice
	cornice = { thick = 2.2, proud = 2.0 },
	belvedere = {
		height = 22,
		inset = 1.6, -- from the shaft's faces
		corner = 4.6, -- corner piers, at most this or 18 % of the side
		post = 1.8,
		-- The lit core sits this far behind the arches: deep enough for a shadow, shallow enough that the posts' sides
		-- don't pinch the openings into keyholes under the arch discs when seen from an angle.
		core = 1.5,
		lintel = 5.5,
		openings = 3,
		entablature = { thick = 1.6, proud = 1.2 },
		obelisk = 6.5,
	},
	cupola = { inset = 4.5, height = 14, window = 0.24, cornice = 1.1 },
	stages = { first = 11, second = 8, shrink = 0.66 }, -- crown 2
	lantern = { height = 4.5, share = 0.2, min = 2.6, max = 4.4 },
	vane = 6,
	portal = { share = 0.5, min = 12, max = 16, spring = 20, surround = 3, pediment = 4.2 },
	planter = { wide = 5, deep = 3, high = 1.6 },
	balcony = { deep = 1.6, rail = 1.4 },
}

-- Walls (stucco), ornament (cast stone), the dome, the lantern's day colour, roof tiles and the wash.
local PALETTES = {
	{
		wall = rgb(238, 219, 180),
		stone = rgb(222, 203, 166),
		dome = Kit.look(rgb(94, 143, 123), Enum.Material.SmoothPlastic),
		lantern = rgb(236, 214, 160),
		tile = rgb(181, 88, 58),
		wash = rgb(255, 214, 160),
	},
	{
		wall = rgb(234, 206, 156),
		stone = rgb(244, 234, 212),
		dome = Kit.look(rgb(150, 116, 70), Enum.Material.Metal),
		lantern = rgb(246, 220, 150),
		tile = rgb(170, 80, 54),
		wash = rgb(255, 200, 140),
	},
	{
		wall = rgb(246, 242, 232),
		stone = rgb(214, 196, 160),
		dome = Kit.look(rgb(46, 118, 126), Enum.Material.SmoothPlastic),
		lantern = rgb(232, 220, 176),
		tile = rgb(190, 96, 62),
		wash = rgb(255, 226, 190),
	},
}

local IRON = Kit.look(rgb(42, 42, 42), Enum.Material.Metal)
local DARK = P.window.deep

type Face = "front" | "back" | "left" | "right"

-- A disc standing on a face: on the front (-z) or back (+z) a tube along z, on the left (-x) or right (+x) one along x,
-- from `inner` behind the face plane to `outer` in front of it.
local function faceDisc(
	m: Types.Model,
	name: string,
	face: Face,
	plane: number,
	along: number,
	y: number,
	diameter: number,
	outer: number,
	inner: number,
	look: Kit.Look
): Types.PartSpec
	if face == "front" then
		return Kit.tube(
			m,
			name,
			Vector3.new(along, y, plane - outer),
			Vector3.new(along, y, plane + inner),
			diameter,
			look,
			"detail"
		)
	elseif face == "back" then
		return Kit.tube(
			m,
			name,
			Vector3.new(along, y, plane - inner),
			Vector3.new(along, y, plane + outer),
			diameter,
			look,
			"detail"
		)
	elseif face == "left" then
		return Kit.tube(
			m,
			name,
			Vector3.new(plane - outer, y, along),
			Vector3.new(plane + inner, y, along),
			diameter,
			look,
			"detail"
		)
	end
	return Kit.tube(
		m,
		name,
		Vector3.new(plane - inner, y, along),
		Vector3.new(plane + outer, y, along),
		diameter,
		look,
		"detail"
	)
end

-- A flat panel standing on a face, `a0..a1` along it, y0..y1, from `inner` behind the plane to `outer` in front.
local function facePanel(
	face: Face,
	plane: number,
	a0: number,
	a1: number,
	y0: number,
	y1: number,
	outer: number,
	inner: number
): (Vector3, Vector3)
	if face == "front" then
		return Vector3.new(a0, y0, plane - outer), Vector3.new(a1, y1, plane + inner)
	elseif face == "back" then
		return Vector3.new(a0, y0, plane - inner), Vector3.new(a1, y1, plane + outer)
	elseif face == "left" then
		return Vector3.new(plane - outer, y0, a0), Vector3.new(plane + inner, y1, a1)
	end
	return Vector3.new(plane - inner, y0, a0), Vector3.new(plane + outer, y1, a1)
end

local FACES: { Face } = { "front", "right", "back", "left" }
local NORMAL: { [Face]: Enum.NormalId } = {
	front = Enum.NormalId.Front,
	back = Enum.NormalId.Back,
	left = Enum.NormalId.Left,
	right = Enum.NormalId.Right,
}

local function build(m: Types.Model)
	local site = m.site
	local variant = site.variant
	local pal = PALETTES[math.clamp(variant.palette, 1, #PALETTES)]
	local W, D, H = site.width, site.depth, site.height
	local hw, hd = W / 2, D / 2
	local wall = Kit.look(pal.wall, Enum.Material.SmoothPlastic)
	local stone = Kit.look(pal.stone, Enum.Material.Limestone)
	local tile = Kit.look(pal.tile, Enum.Material.ClayRoofTiles)
	local rhythm = math.clamp(variant.rhythm, 1, 2)

	-------------------------------------------------------------------------------------------------------
	-- Layout: the base (and the press wing beside it when the site is wide), the tower over the base's middle
	-------------------------------------------------------------------------------------------------------
	local avail = W - 2 * SHAPE.sideInset
	local wingW = 0
	if avail >= SHAPE.wing.from then
		wingW = math.clamp(avail * SHAPE.wing.share, SHAPE.wing.min, SHAPE.wing.max)
	end
	local bw = math.min(avail - wingW, SHAPE.baseMax)
	local left = -(bw + wingW) / 2
	local bx0, bx1 = left, left + bw
	local zF = -hd + SHAPE.forecourt
	local zB = math.min(hd - SHAPE.backInset, zF + SHAPE.baseDepth)
	local tcx = (bx0 + bx1) / 2
	local baseTop = SHAPE.ground + SHAPE.upper * SHAPE.floor

	local T = math.clamp(W * SHAPE.tower.share, SHAPE.tower.min, SHAPE.tower.max)
	T = math.min(T, zB - zF - 2.5, bw - 8)
	local tx0, tx1 = tcx - T / 2, tcx + T / 2
	local tz0 = zF + SHAPE.tower.setBack
	local tz1 = tz0 + T
	local tzc = (tz0 + tz1) / 2

	-------------------------------------------------------------------------------------------------------
	-- Base: stucco over a rusticated stone ground storey, a stone cornice and a parapet. The sides are punched; the
	-- front gets its own stucco face with columns of paired windows and arched ground-floor windows (below, after
	-- the portal); the forecourt and planters
	-------------------------------------------------------------------------------------------------------
	local baseFaces = { Enum.NormalId.Left, Enum.NormalId.Back }
	if wingW == 0 then
		table.insert(baseFaces, Enum.NormalId.Right)
	end
	Kit.punched(
		m,
		"Base",
		Vector3.new(bx0, -KIT.bury, zF),
		Vector3.new(bx1, baseTop, zB),
		pal.wall,
		DARK,
		baseFaces,
		SHAPE.baseBay,
		SHAPE.floor,
		true
	)
	Kit.box(
		m,
		"BaseFront",
		Vector3.new(bx0 + 0.02, 1, zF - 0.06),
		Vector3.new(bx1 - 0.02, baseTop - 0.02, zF + 0.5),
		wall
	)
	local pp = SHAPE.plinth.proud
	local plinthTop = SHAPE.plinth.height
	Kit.trim(
		m,
		"Plinth",
		Vector3.new(bx0 - pp, -KIT.bury, zF - pp),
		Vector3.new(bx1 + (if wingW > 0 then -0.05 else pp), plinthTop, zB - 0.4),
		stone
	)
	local bc = SHAPE.baseCornice
	Kit.trim(
		m,
		"BaseCornice",
		Vector3.new(bx0 - bc.proud, baseTop - bc.thick + 0.06, zF - bc.proud),
		Vector3.new(bx1 + bc.proud, baseTop + 0.06, zB - 0.3),
		stone
	)
	Kit.box(
		m,
		"BaseParapet",
		Vector3.new(bx0 + 0.4, baseTop + 0.06, zF + 0.4),
		Vector3.new(bx1 - 0.4, baseTop + SHAPE.parapet, zB - 0.8),
		wall
	)

	-- The forecourt: stone paving to the front line, two planters flanking the steps.
	local paving = Kit.look(rgb(226, 216, 196), Enum.Material.Limestone)
	Kit.box(m, "Forecourt", Vector3.new(-hw + 0.3, 0, -hd + 0.3), Vector3.new(hw - 0.3, 0.25, zF + 0.6), paving)

	-------------------------------------------------------------------------------------------------------
	-- The portal: a two-storey arch in a stone surround, a broken pediment, steps
	-------------------------------------------------------------------------------------------------------
	local po = SHAPE.portal
	local pw = math.clamp(T * po.share, po.min, po.max)
	local spring = po.spring
	local surroundTop = spring + pw / 2 + 3.5
	local sx0, sx1 = tcx - pw / 2 - po.surround, tcx + pw / 2 + po.surround
	Kit.trim(m, "Surround", Vector3.new(sx0, 0.2, zF - 1.0), Vector3.new(sx1, surroundTop, zF + 0.3), stone)
	Kit.tube(
		m,
		"ArchRing",
		Vector3.new(tcx, spring, zF - 1.35),
		Vector3.new(tcx, spring, zF - 1.0),
		pw + 3,
		stone,
		"trim"
	)
	Kit.glass(
		m,
		"Doors",
		Vector3.new(tcx - pw / 2, 1.0, zF - 1.45),
		Vector3.new(tcx + pw / 2, spring, zF - 1.0),
		DARK,
		{
			image = City.textures.windowBold,
			faces = { Enum.NormalId.Front },
			u = pw / 4,
			v = 6,
			lines = pal.stone,
			lit = true,
		}
	)
	Kit.lit(
		Kit.tube(
			m,
			"DoorsArch",
			Vector3.new(tcx, spring, zF - 1.4),
			Vector3.new(tcx, spring, zF - 1.0),
			pw,
			Kit.glassLook(DARK, 0.1),
			"detail"
		),
		"window"
	)
	local ped = po.pediment
	Kit.wedge(
		m,
		"PedimentL",
		Vector3.new(sx0 - 0.6, surroundTop, zF - 1.2),
		Vector3.new(tcx - 1.6, surroundTop + ped, zF + 0.3),
		"right",
		stone,
		"trim"
	)
	Kit.wedge(
		m,
		"PedimentR",
		Vector3.new(tcx + 1.6, surroundTop, zF - 1.2),
		Vector3.new(sx1 + 0.6, surroundTop + ped, zF + 0.3),
		"left",
		stone,
		"trim"
	)
	Kit.box(m, "Step1", Vector3.new(sx0 - 1, 0.25, zF - 5.2), Vector3.new(sx1 + 1, 0.6, zF - 0.95), stone)
	Kit.box(m, "Step2", Vector3.new(sx0, 0.6, zF - 3.4), Vector3.new(sx1, 1.0, zF - 0.95), stone)
	-- The base's front either side of the portal: arched windows in the stone ground storey, and over them columns
	-- of paired windows through the three upper floors.
	local fw = SHAPE.frontWindows
	local archGlass = Kit.glassLook(DARK, 0.12)
	for side, range in { { bx0 + fw.edge, sx0 - fw.gap }, { sx1 + fw.gap, bx1 - fw.edge } } do
		local a0, a1 = range[1], range[2]
		local count = math.clamp(math.floor((a1 - a0) / fw.every), 0, fw.most)
		for k = 1, count do
			local x = a0 + (a1 - a0) * (k - 0.5) / count
			Kit.glass(
				m,
				`Upper{side}{k}`,
				Vector3.new(x - fw.width / 2, plinthTop + fw.sill, zF - 0.14),
				Vector3.new(x + fw.width / 2, baseTop - fw.head, zF + 0.2),
				DARK,
				{
					image = City.textures.windowBold,
					faces = { Enum.NormalId.Front },
					u = fw.width / 2,
					v = SHAPE.floor,
					lines = pal.wall,
					reflectance = 0.12,
				}
			)
			local g = fw.ground
			Kit.glass(
				m,
				`Ground{side}{k}`,
				Vector3.new(x - g.width / 2, g.sill, zF - pp - 0.08),
				Vector3.new(x + g.width / 2, g.spring, zF - pp + 0.3),
				DARK,
				{ reflectance = 0.12 }
			)
			Kit.tube(
				m,
				`GroundArch{side}{k}`,
				Vector3.new(x, g.spring, zF - pp - 0.05),
				Vector3.new(x, g.spring, zF - pp + 0.3),
				g.width,
				archGlass,
				"detail"
			)
		end
	end
	local pl = SHAPE.planter
	for i, side in { -1, 1 } do
		local px = tcx + side * (pw / 2 + po.surround + 5 + pl.wide / 2)
		Kit.planter(
			m,
			`Planter{i}`,
			Vector3.new(px - pl.wide / 2, 0.25, zF - 2 - pl.deep),
			Vector3.new(px + pl.wide / 2, 0.25 + pl.high, zF - 2),
			stone
		)
	end

	-------------------------------------------------------------------------------------------------------
	-- The press wing: three plain storeys under a clay-tile gable
	-------------------------------------------------------------------------------------------------------
	if wingW > 0 then
		local wg = SHAPE.wing
		local wx0, wx1 = bx1, bx1 + wingW
		local wz0 = zF + wg.back
		local wingTop = SHAPE.ground + wg.floors * SHAPE.floor
		Kit.punched(
			m,
			"Wing",
			Vector3.new(wx0 - 0.5, -KIT.bury, wz0),
			Vector3.new(wx1, wingTop, zB),
			pal.wall,
			DARK,
			{ Enum.NormalId.Front, Enum.NormalId.Right, Enum.NormalId.Back },
			wg.bay,
			SHAPE.floor
		)
		Kit.trim(
			m,
			"WingCornice",
			Vector3.new(wx0 + 0.1, wingTop - 1.2, wz0 - 1),
			Vector3.new(wx1 + 1, wingTop + 0.05, zB - 0.2),
			stone
		)
		local e = wg.eave
		local zMid = (wz0 + zB) / 2
		local ridge = wingTop + wg.roof
		Kit.wedge(
			m,
			"WingRoofF",
			Vector3.new(wx0 + 0.15, wingTop + 0.05, wz0 - e),
			Vector3.new(wx1 + e, ridge, zMid),
			"back",
			tile,
			"trim"
		)
		Kit.wedge(
			m,
			"WingRoofB",
			Vector3.new(wx0 + 0.15, wingTop + 0.05, zMid),
			Vector3.new(wx1 + e, ridge - 0.04, math.min(zB + e, hd - 0.05)),
			"front",
			tile,
			"trim"
		)
	end

	-------------------------------------------------------------------------------------------------------
	-- The shaft: stucco, stone corner piers, columns of windows, belts, a frieze and the cornice
	-------------------------------------------------------------------------------------------------------
	local co = SHAPE.cornice
	local shaftTop = H - co.thick
	local pTop = shaftTop - SHAPE.frieze -- the stucco's top, under the frieze
	Kit.box(m, "Shaft", Vector3.new(tx0, baseTop - 2, tz0), Vector3.new(tx1, pTop + 0.05, tz1), wall)
	local pr, pw2 = SHAPE.pier.proud, SHAPE.pier.wide
	for i, c in { { -1, -1 }, { 1, -1 }, { -1, 1 }, { 1, 1 } } do
		local cx = if c[1] < 0 then tx0 else tx1
		local cz = if c[2] < 0 then tz0 else tz1
		Kit.trim(
			m,
			`Pier{i}`,
			Vector3.new(cx - c[1] * (pw2 - pr), baseTop + SHAPE.parapet - 0.5, cz - c[2] * (pw2 - pr)),
			Vector3.new(cx + c[1] * pr, shaftTop - 0.02, cz + c[2] * pr),
			stone
		)
	end
	-- A column of windows in each bay between the piers, whole floors down from under the frieze, the stucco showing
	-- wide between them: a paired column in the middle bay and single ones either side (rhythm 1), or two paired
	-- columns (rhythm 2). A few glow at night.
	local ws = SHAPE.strip
	local bays = if rhythm == 1 then 3 else 2
	local inner = pw2 - pr -- the piers reach this far onto each face
	local bayW = (T - 2 * inner) / bays
	local sTop = pTop - ws.head
	local nFloors = math.max(1, math.floor((sTop - baseTop - SHAPE.parapet - 1) / SHAPE.towerFloor))
	local sBottom = sTop - nFloors * SHAPE.towerFloor
	local litRng = Kit.rng(m, 3)
	local stripXs: { { x: number, w: number } } = {}
	for f, face in FACES do
		local front = face == "front" or face == "back"
		local s0 = (if front then tx0 else tz0) + inner
		local plane = if face == "front" then tz0 elseif face == "back" then tz1 elseif face == "left" then tx0 else tx1
		for b = 1, bays do
			local a = s0 + bayW * (b - 0.5)
			local share = if rhythm == 2 then ws.pair elseif b == 2 then ws.centre else ws.side
			local panes = if rhythm == 1 and b ~= 2 then 1 else 2
			local sw = math.min(bayW * share, ws.max)
			if face == "front" then
				table.insert(stripXs, { x = a, w = sw })
			end
			local lo, hi = facePanel(face, plane, a - sw / 2, a + sw / 2, sBottom, sTop, 0.08, 0.3)
			Kit.glass(m, `Windows{f}{b}`, lo, hi, DARK, {
				image = City.textures.windowBold,
				faces = { NORMAL[face] },
				u = sw / panes,
				v = SHAPE.towerFloor,
				lines = pal.wall,
				lit = litRng:NextNumber() < ws.litShare,
				reflectance = 0.04,
			})
		end
	end
	-- Belt courses on floor lines, standing over the windows.
	local belts = if rhythm == 1 then 3 else 5
	local bt = SHAPE.belt
	local beltYs: { number } = {}
	for j = 1, belts do
		local k = math.clamp(math.round(nFloors * j / (belts + 1)), 1, math.max(1, nFloors - 1))
		local y = sTop - SHAPE.towerFloor * k
		table.insert(beltYs, y)
		Kit.trim(
			m,
			`Belt{j}`,
			Vector3.new(tx0 - bt.proud, y - bt.thick / 2, tz0 - bt.proud),
			Vector3.new(tx1 + bt.proud, y + bt.thick / 2, tz1 + bt.proud),
			stone
		)
	end
	if rhythm == 2 then
		-- Wrought-iron balconies under the front's windows on the top two belts.
		local bl = SHAPE.balcony
		for j = math.max(1, belts - 1), belts do
			local y = beltYs[j]
			for b, strip in stripXs do
				local x, sw = strip.x, strip.w
				Kit.detail(
					m,
					`Balcony{j}{b}`,
					Vector3.new(x - sw / 2 - 0.5, y + bt.thick / 2, tz0 - bt.proud - bl.deep),
					Vector3.new(x + sw / 2 + 0.5, y + bt.thick / 2 + bl.rail, tz0 - bt.proud + 0.2),
					IRON
				)
			end
		end
	end
	Kit.trim(
		m,
		"Frieze",
		Vector3.new(tx0 - 0.35, pTop, tz0 - 0.35),
		Vector3.new(tx1 + 0.35, shaftTop, tz1 + 0.35),
		stone
	)
	Kit.trim(
		m,
		"Cornice",
		Vector3.new(tx0 - co.proud, shaftTop, tz0 - co.proud),
		Vector3.new(tx1 + co.proud, H, tz1 + co.proud),
		stone
	)

	-------------------------------------------------------------------------------------------------------
	-- The belvedere: an open arcade, three arches a side round a lit core, under an entablature
	-------------------------------------------------------------------------------------------------------
	local bv = SHAPE.belvedere
	local vx0, vx1 = tx0 + bv.inset, tx1 - bv.inset
	local vz0, vz1 = tz0 + bv.inset, tz1 - bv.inset
	local vS = vx1 - vx0
	local vTop = H + bv.height
	local c = math.min(bv.corner, vS * 0.18)
	local ow = (vS - 2 * c - (bv.openings - 1) * bv.post) / bv.openings
	local archSpring = vTop - bv.lintel
	Kit.trim(m, "Balustrade", Vector3.new(vx0 - 0.3, H, vz0 - 0.3), Vector3.new(vx1 + 0.3, H + 1.2, vz1 + 0.3), stone)
	Kit.glass(
		m,
		"Loggia",
		Vector3.new(vx0 + bv.core, H + 0.05, vz0 + bv.core),
		Vector3.new(vx1 - bv.core, vTop - 0.05, vz1 - bv.core),
		DARK,
		{ lit = true, reflectance = 0.1 }
	)
	for i, cc in { { -1, -1 }, { 1, -1 }, { -1, 1 }, { 1, 1 } } do
		local x0 = if cc[1] < 0 then vx0 else vx1 - c
		local z0 = if cc[2] < 0 then vz0 else vz1 - c
		Kit.box(m, `Corner{i}`, Vector3.new(x0, H + 0.02, z0), Vector3.new(x0 + c, vTop, z0 + c), wall)
	end
	Kit.box(
		m,
		"Lintel",
		Vector3.new(vx0 + 0.1, archSpring, vz0 + 0.1),
		Vector3.new(vx1 - 0.1, vTop - 0.02, vz1 - 0.1),
		wall
	)
	local archLook = Kit.glassLook(DARK, 0.1)
	for f, face in FACES do
		local front = face == "front" or face == "back"
		local s0 = if front then vx0 else vz0
		local plane = if face == "front" then vz0 elseif face == "back" then vz1 elseif face == "left" then vx0 else vx1
		for k = 1, bv.openings do
			local a = s0 + c + (k - 1) * (ow + bv.post) + ow / 2
			Kit.lit(faceDisc(m, `Arch{f}{k}`, face, plane, a, archSpring, ow, -0.04, 0.3, archLook), "window")
			if k < bv.openings then
				local p0 = s0 + c + k * ow + (k - 1) * bv.post
				local lo, hi = facePanel(face, plane, p0, p0 + bv.post, H + 0.02, archSpring + 0.02, 0, bv.core + 0.2)
				Kit.box(m, `Post{f}{k}`, lo, hi, wall)
			end
		end
	end
	local en = bv.entablature
	local eTop = vTop + en.thick
	Kit.trim(
		m,
		"Entablature",
		Vector3.new(vx0 - en.proud, vTop - 0.02, vz0 - en.proud),
		Vector3.new(vx1 + en.proud, eTop, vz1 + en.proud),
		stone
	)
	for i, cc in { { -1, -1 }, { 1, -1 }, { -1, 1 }, { 1, 1 } } do
		local ox = if cc[1] < 0 then vx0 + c / 2 else vx1 - c / 2
		local oz = if cc[2] < 0 then vz0 + c / 2 else vz1 - c / 2
		Kit.column(m, `Obelisk{i}`, ox, oz, eTop - 0.1, eTop + bv.obelisk, 2.4, stone, "trim")
	end

	-------------------------------------------------------------------------------------------------------
	-- The cupola: octagonal stages, a dome, a gilded lantern and the vane
	-------------------------------------------------------------------------------------------------------
	local cu = SHAPE.cupola
	local A = vS - 2 * cu.inset
	local y = eTop - 0.3
	local domeAcross: number
	if variant.crown == 2 then
		-- Two stepped octagons with tall windows, corner urns on the first cornice, a smaller dome.
		local st = SHAPE.stages
		local o1 = y + st.first
		Kit.octagon(m, "Stage", tcx, tzc, y, o1, A, wall)
		for f, face in FACES do
			local plane = if face == "front"
				then tzc - A / 2
				elseif face == "back" then tzc + A / 2
				elseif face == "left" then tcx - A / 2
				else tcx + A / 2
			local mid = if face == "front" or face == "back" then tcx else tzc
			local ww = A * cu.window
			local lo, hi = facePanel(face, plane, mid - ww / 2, mid + ww / 2, y + 2.4, o1 - 2.2, 0.08, 0.2)
			Kit.glass(m, `StageWindow{f}`, lo, hi, DARK, { lit = true, reflectance = 0.1 })
		end
		Kit.disc(m, "StageCornice", tcx, tzc, o1 + 0.1, A / COS8 + 1.2, cu.cornice, stone)
		for i, cc in { { -1, -1 }, { 1, -1 }, { -1, 1 }, { 1, 1 } } do
			local r = A * 0.36
			Kit.ball(
				m,
				`Urn{i}`,
				Vector3.new(tcx + cc[1] * r, o1 + cu.cornice / 2 + 1, tzc + cc[2] * r),
				2,
				stone,
				"trim"
			)
		end
		local A2 = A * st.shrink
		local s2 = o1 + cu.cornice / 2 + 0.1
		local o2 = s2 + st.second
		Kit.octagon(m, "Drum", tcx, tzc, s2 - 0.05, o2, A2, wall)
		Kit.disc(m, "DrumCornice", tcx, tzc, o2 - 0.2, A2 / COS8 + 1, cu.cornice, stone)
		y = o2
		domeAcross = A2 * 0.98
	else
		-- One octagon with an arched window on each axis face, under a full dome.
		local cTop = y + cu.height
		Kit.octagon(m, "Cupola", tcx, tzc, y, cTop, A, wall)
		local ww = A * cu.window
		local wSpring = y + cu.height * 0.62
		for f, face in FACES do
			local plane = if face == "front"
				then tzc - A / 2
				elseif face == "back" then tzc + A / 2
				elseif face == "left" then tcx - A / 2
				else tcx + A / 2
			local mid = if face == "front" or face == "back" then tcx else tzc
			local lo, hi = facePanel(face, plane, mid - ww / 2, mid + ww / 2, y + 2, wSpring, 0.08, 0.2)
			Kit.glass(m, `CupolaWindow{f}`, lo, hi, DARK, { lit = true, reflectance = 0.1 })
			Kit.lit(faceDisc(m, `CupolaArch{f}`, face, plane, mid, wSpring, ww, 0.04, 0.2, archLook), "window")
		end
		Kit.disc(m, "CupolaCornice", tcx, tzc, cTop - 0.2, A / COS8 + 1.4, cu.cornice, stone)
		y = cTop
		domeAcross = A * 0.98
	end
	Kit.ball(m, "Dome", Vector3.new(tcx, y + 0.3, tzc), domeAcross, pal.dome, "trim")
	local domeTop = y + 0.3 + domeAcross / 2

	local la = SHAPE.lantern
	local ld = math.clamp(A * la.share, la.min, la.max)
	local lTop = domeTop + la.height
	Kit.lit(
		Kit.column(
			m,
			"Lamp",
			tcx,
			tzc,
			domeTop - 1.2,
			lTop,
			ld,
			Kit.look(pal.lantern, Enum.Material.SmoothPlastic),
			"detail"
		),
		"neonAmber"
	)
	Kit.ball(m, "LampCap", Vector3.new(tcx, lTop + 0.2, tzc), ld + 0.8, pal.dome, "detail")
	local capTop = lTop + 0.2 + (ld + 0.8) / 2
	local vaneTop = math.min(capTop + SHAPE.vane, site.maxHeight - 0.2)
	if vaneTop - capTop > 2 then
		Kit.column(m, "VanePole", tcx, tzc, capTop - 0.3, vaneTop, 0.35, IRON, "detail")
		Kit.detail(
			m,
			"Vane",
			Vector3.new(tcx + 0.2, vaneTop - 2.2, tzc - 0.08),
			Vector3.new(tcx + 2.8, vaneTop - 0.8, tzc + 0.08),
			IRON
		)
	end

	-- At night a wash on the cornice lights the belvedere and the cupola from below.
	Kit.wash(m, "Wash", vx0 + c, vx1 - c, tz0 - co.proud + 0.6, H, pal.wash)
end

local archetype: Types.Archetype = { id = "cupola_bell_tower", build = build }
return archetype
