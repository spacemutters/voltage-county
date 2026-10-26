--!strict
-- T18 tiled_mural_midrise (docs/city/ARCHETYPES.md §5, T18): a crisp, Mies-like office block of dark tinted glass that
-- floats over a recessed glass lobby on white pilotis. Its two end walls are solid and covered full height in
-- blue-and-white tiles: a giant mural (an original pattern, a stylised flowering tree or a stack of chevron waves under
-- a sun) standing in relief on a tiled field. The long faces are glass with metal mullion fins, under a thin white roof
-- slab; the name sits on the white band under the block. Beside it, on the plaza, a box of stained glass (a mosaic of
-- amber, ruby, cobalt and green panes of different sizes in leaded frames) is held high on a single stem; at night each
-- pane glows in its own colour.
--
-- What makes it itself: a glass block whose ends are giant blue-and-white tile murals, beside a stained-glass box on a
-- stem.
-- Placement, sizes, heights and its budget: Config/CityArchetypes/tiled_mural_midrise.
-- Variants: palette (1 azulejo blue, 2 sea green tiles), crown (1 the stained-glass box on its stem, 2 no box: the
-- block centred on a plaza with a reflecting pool and planters), rhythm (1 the flowering-tree mural and a fin every 6
-- studs, 2 the chevron-wave mural and a fin every 8.5), mirror (which side the box stands).
--
-- Previewing, check: the murals read from the road as blue-and-white tile walls with a clear figure (shapes stand in
-- relief, nothing flickers where shapes overlap); the block reads as floating (the lobby dark and recessed under the
-- white band); the fins give the glass a vertical rhythm with shadow; the CeramicTiles read as tiles, not noise; the
-- stained-glass box reads as a mosaic of coloured glass under its leaded overlay by day (never as flag stripes) and
-- glows in four colours at night without
-- blowing out (darken a colour if one turns white-hot); the box's stem looks strong enough.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local City = require(ReplicatedStorage.Shared.Config.City)
local Kit = require(script.Parent.Parent.Parent.Kit)
local Types = require(script.Parent.Parent.Parent.Types)

local P = City.palettes
local KIT = City.kit
local rgb = Color3.fromRGB

-- The recipe, in studs.
local SHAPE = {
	lobby = 16, -- the recessed ground floor; the block floats over it
	floor = 12,
	roof = 1.4, -- the roof slab...
	roofProud = 0.5, -- ...past the end walls
	plaza = 0.6,
	recess = 5, -- the lobby glass sits this far in under the block
	towerWidth = { 50, 72 },
	towerDepth = { 28, 40 },
	towerBack = 4,
	plazaSide = 30, -- with no box, the block leaves at least this much plaza, half each side
	sideRoom = 6, -- with the box: room left at the site's ends for the murals and the box's slabs
	wall = 2.2, -- the tile end walls' thickness...
	wallProud = 0.9, -- ...past the long faces
	soffit = 1.4, -- the white band under the block, below its floor line
	column = 2.2,
	columnIn = 7, -- the pilotis stand this far in from the block's ends
	fin = { thick = 0.5, proud = 1.3 },
	finEvery = { 6, 8.5 }, -- by rhythm
	-- The mural, proud of the wall's face: the blue field, the white figure, the blue hearts; everything reaches `back`
	-- into the wall. `inset` is the white border left round the field.
	mural = { inset = 1.4, field = 0.15, back = 0.2, stem = 0.28, shape = 0.3, leaf = 0.32, dot = 0.45, chevron = 2.2 },
	annex = {
		share = 0.3,
		width = { 28, 40 },
		gap = 10,
		height = 28,
		under = 50,
		core = 10,
		post = 0.45,
		skin = 0.12,
		-- The mosaic on each face: where its two rows split (share of the box's height, seeded) and the widths of a
		-- row's three panes (shares of the face, a different cut on each row and face).
		mosaic = {
			split = { 0.38, 0.62 },
			cuts = { { 0.46, 0.3, 0.24 }, { 0.22, 0.42, 0.36 }, { 0.3, 0.24, 0.46 } },
		},
		paneGap = 0.4, -- the dark mullion between panes
	},
	plantRoom = 6,
}

local PALETTES = {
	{ tile = rgb(44, 93, 168), white = rgb(242, 244, 247), glass = rgb(47, 60, 69), mullion = rgb(170, 176, 182) },
	{ tile = rgb(46, 140, 126), white = rgb(242, 245, 240), glass = rgb(44, 62, 64), mullion = rgb(176, 182, 178) },
}

-- The box's glass: amber, ruby, cobalt and green, saturated and deep, since Neon's brightness follows its colour: each
-- glows in its own colour at night (night kind `stained`) without turning into a lime or yellow LED sign.
local STAINED = { rgb(196, 128, 36), rgb(150, 34, 48), rgb(40, 66, 156), rgb(36, 112, 70) }
local STAINED_REFLECTANCE = 0.08
local LEAD = rgb(30, 30, 34) -- the leading round the panes
local TILE_GRID = 3 -- studs: the tile joints drawn over the mural's field, so it reads as tiles from the road

local FRONT, BACK = Enum.NormalId.Front, Enum.NormalId.Back
local LEFT, RIGHT = Enum.NormalId.Left, Enum.NormalId.Right

local function build(m: Types.Model)
	local site = m.site
	local variant = site.variant
	local pal = PALETTES[math.clamp(variant.palette, 1, #PALETTES)]
	local rhythm = math.clamp(variant.rhythm, 1, 2)
	local annexOn = variant.crown ~= 2
	local rng = Kit.rng(m)
	local W, D, H = site.width, site.depth, site.height
	local hw, hd = W / 2, D / 2
	local white = P.frame.white
	local whiteLook = Kit.look(white, Enum.Material.SmoothPlastic)
	local tileWhite = Kit.look(pal.white, Enum.Material.CeramicTiles)
	local tileBlue = Kit.look(pal.tile, Enum.Material.CeramicTiles)
	local tag = City.signNames.towers[rng:NextInteger(1, #City.signNames.towers)]

	-------------------------------------------------------------------------------------------------------
	-- Layout: the block (with the box beside it, the pair centred) and its floors
	-------------------------------------------------------------------------------------------------------
	local an = SHAPE.annex
	local aw = math.clamp(W * an.share, an.width[1], an.width[2])
	local tw: number, x0: number
	if annexOn then
		tw = math.clamp(W - aw - an.gap - SHAPE.sideRoom, SHAPE.towerWidth[1], SHAPE.towerWidth[2])
		x0 = -(tw + an.gap + aw) / 2
	else
		tw = math.clamp(W - SHAPE.plazaSide, SHAPE.towerWidth[1], SHAPE.towerWidth[2])
		x0 = -tw / 2
	end
	local x1 = x0 + tw
	local td = math.clamp(D - 16, SHAPE.towerDepth[1], SHAPE.towerDepth[2])
	local tz1 = hd - SHAPE.towerBack
	local tz0 = tz1 - td
	local yb = SHAPE.lobby -- the block's floor line
	local yr = H - SHAPE.roof -- the glass's top, the roof slab's underside
	local n = math.clamp(math.floor((yr - yb) / SHAPE.floor), 6, 9)
	local f = (yr - yb) / n
	local wz0, wz1 = tz0 - SHAPE.wallProud, tz1 + SHAPE.wallProud
	local wy0, wy1 = yb - SHAPE.soffit - 0.2, yr + 0.3

	-------------------------------------------------------------------------------------------------------
	-- The plaza, the recessed lobby, the pilotis and the white band the block floats on
	-------------------------------------------------------------------------------------------------------
	Kit.box(
		m,
		"Plaza",
		Vector3.new(-hw + 0.3, -KIT.bury, -hd + 0.3),
		Vector3.new(hw - 0.3, SHAPE.plaza, hd - 0.3),
		Kit.look(rgb(226, 220, 208), Enum.Material.Limestone)
	)
	local rc = SHAPE.recess
	local lobbyTop = yb - SHAPE.soffit + 0.2
	Kit.glass(
		m,
		"Lobby",
		Vector3.new(x0 + rc, 0, tz0 + rc),
		Vector3.new(x1 - rc, lobbyTop, tz1 - rc),
		rgb(44, 60, 70),
		{
			image = City.textures.windowBold,
			faces = { FRONT, BACK, LEFT, RIGHT },
			u = 4,
			v = lobbyTop,
			lines = white,
			lit = true,
		}
	)
	for i, x in { x0 + SHAPE.columnIn, (x0 + x1) / 2, x1 - SHAPE.columnIn } do
		Kit.column(m, `Column{i}`, x, tz0 + 2.5, -KIT.bury, yb - SHAPE.soffit + 0.2, SHAPE.column, whiteLook)
	end
	Kit.trim(
		m,
		"Soffit",
		Vector3.new(x0 + SHAPE.wall - 0.3, yb - SHAPE.soffit, tz0 - 0.6),
		Vector3.new(x1 - SHAPE.wall + 0.3, yb + 0.3, tz1 + 0.6),
		whiteLook
	)
	local xm = (x0 + x1) / 2
	local sw = math.min(12, tw * 0.22)
	Kit.sign(
		m,
		"Name",
		Vector3.new(xm - sw, yb - SHAPE.soffit + 0.15, tz0 - 0.95),
		Vector3.new(xm + sw, yb + 0.15, tz0 - 0.65),
		FRONT,
		tag,
		rgb(246, 246, 242),
		pal.tile,
		City.districtLooks.downtown.font
	)

	-------------------------------------------------------------------------------------------------------
	-- The block: tile end walls, glass between them (one run may glow), mullion fins, the roof slab
	-------------------------------------------------------------------------------------------------------
	Kit.box(m, "WallL", Vector3.new(x0, wy0, wz0), Vector3.new(x0 + SHAPE.wall, wy1, wz1), tileWhite)
	Kit.box(m, "WallR", Vector3.new(x1 - SHAPE.wall, wy0, wz0), Vector3.new(x1, wy1, wz1), tileWhite)
	local every = SHAPE.finEvery[rhythm]
	local inner = (x1 - SHAPE.wall) - (x0 + SHAPE.wall)
	local count = math.max(2, math.floor(inner / every) - 1)
	local bay = inner / (count + 1)
	local litRoll = rng:NextNumber()
	local split = yb + math.round(n / 2) * f
	local function glassRun(name: string, y0: number, y1: number, isLit: boolean)
		Kit.glass(
			m,
			name,
			Vector3.new(x0 + SHAPE.wall - 0.3, y0, tz0),
			Vector3.new(x1 - SHAPE.wall + 0.3, y1, tz1),
			pal.glass,
			{
				image = City.textures.windowFine,
				faces = { FRONT, BACK },
				u = bay / 2,
				v = f,
				lines = pal.mullion,
				lit = isLit,
				reflectance = 0.2,
			}
		)
	end
	glassRun("Glass", yb, split, litRoll < 0.4)
	glassRun("GlassUpper", split, yr, litRoll >= 0.4 and litRoll < 0.7)
	Kit.fins(
		m,
		"Fin",
		"front",
		tz0,
		x0 + SHAPE.wall + bay,
		x1 - SHAPE.wall - bay,
		count,
		yb + 0.3,
		yr + 0.2,
		SHAPE.fin.proud,
		SHAPE.fin.thick,
		Kit.look(pal.mullion, Enum.Material.Metal)
	)
	local rp = SHAPE.roofProud
	Kit.box(m, "Roof", Vector3.new(x0 - rp, yr, wz0 - rp), Vector3.new(x1 + rp, H, wz1 + rp), whiteLook)
	Kit.roofBox(
		m,
		"Plant",
		Vector3.new(x0 + tw * 0.32, H, tz0 + td * 0.3),
		Vector3.new(x1 - tw * 0.32, H + SHAPE.plantRoom, tz1 - td * 0.2)
	)

	-------------------------------------------------------------------------------------------------------
	-- The murals: the same figure on both end walls, in relief on a blue tile field
	-------------------------------------------------------------------------------------------------------
	local mu = SHAPE.mural
	local zm = (wz0 + wz1) / 2
	local wz = wz1 - wz0
	local fy0, fy1 = wy0 + mu.inset, yr - mu.inset
	local fh = fy1 - fy0
	local hwz = wz / 2 - mu.inset
	for _, wall in { { side = "L", face = x0, out = -1 }, { side = "R", face = x1, out = 1 } } do
		local function px(proud: number): number
			return wall.face + wall.out * proud
		end
		-- A box from `back` inside the wall to `proud` out of it, u along the wall (z from its middle), v up the field.
		local function plaque(
			name: string,
			u0: number,
			v0: number,
			u1: number,
			v1: number,
			look: Kit.Look,
			proud: number
		): Types.PartSpec
			return Kit.detail(
				m,
				name .. wall.side,
				Vector3.new(px(proud), fy0 + v0, zm + u0),
				Vector3.new(px(-mu.back), fy0 + v1, zm + u1),
				look
			)
		end
		local function disc(name: string, u: number, v: number, diameter: number, look: Kit.Look, proud: number)
			Kit.tube(
				m,
				name .. wall.side,
				Vector3.new(px(-mu.back), fy0 + v, zm + u),
				Vector3.new(px(proud), fy0 + v, zm + u),
				diameter,
				look,
				"detail"
			)
		end
		-- A bar on the wall from (u0, v0) to (u1, v1), `thick` across: diamonds (a square turned 45) and chevrons.
		local function bar(
			name: string,
			u0: number,
			v0: number,
			u1: number,
			v1: number,
			thick: number,
			look: Kit.Look,
			proud: number
		)
			local x = px((proud - mu.back) / 2)
			Kit.strut(
				m,
				name .. wall.side,
				Vector3.new(x, fy0 + v0, zm + u0),
				Vector3.new(x, fy0 + v1, zm + u1),
				thick,
				look,
				"detail",
				proud + mu.back
			)
		end
		local field = plaque("Field", -hwz, 0, hwz, fh, tileBlue, mu.field)
		field.textures = {
			{
				face = Kit.face(m, if wall.out < 0 then LEFT else RIGHT),
				image = City.textures.windowFine,
				u = TILE_GRID,
				v = TILE_GRID,
				color = pal.tile:Lerp(pal.white, 0.45),
			},
		}
		if rhythm == 1 then
			-- A flowering tree: a ground line, a stem, three blooms with blue hearts, two leaves.
			plaque("Ground", -hwz + 1.2, 0.05 * fh, hwz - 1.2, 0.09 * fh, tileWhite, mu.shape)
			plaque("Stem", -0.06 * wz, 0.09 * fh, 0.06 * wz, 0.72 * fh, tileWhite, mu.stem)
			for j, bloom in { { 0, 0.8, 0.52 }, { -0.28, 0.52, 0.34 }, { 0.28, 0.36, 0.34 } } do
				local u, v, size = bloom[1] * wz, bloom[2] * fh, bloom[3] * wz
				disc(`Bloom{j}`, u, v, size, tileWhite, mu.shape)
				disc(`Heart{j}`, u, v, size * 0.42, tileBlue, mu.dot)
			end
			for j, leaf in { { 0.2, 0.62 }, { -0.2, 0.25 } } do
				local q = 0.2 * wz
				local h = q / (2 * math.sqrt(2))
				local u, v = leaf[1] * wz, leaf[2] * fh
				bar(`Leaf{j}`, u - h, v - h, u + h, v + h, q, tileWhite, mu.leaf)
			end
		else
			-- Waves: three chevrons stacked up the wall under a sun with a blue heart.
			local dip = 0.18 * wz
			local reach = hwz - 1.6
			for j, at in { 0.2, 0.42, 0.64 } do
				local v = at * fh
				bar(`WaveL{j}`, -reach, v + dip, 0, v, mu.chevron, tileWhite, mu.shape)
				bar(`WaveR{j}`, 0, v, reach, v + dip, mu.chevron, tileWhite, mu.leaf)
			end
			disc("Sun", 0, 0.9 * fh, 0.3 * wz, tileWhite, mu.shape)
			disc("SunHeart", 0, 0.9 * fh, 0.13 * wz, tileBlue, mu.dot)
		end
	end

	-------------------------------------------------------------------------------------------------------
	-- Crown 1: the stained-glass box held high on one stem. Crown 2: a plaza with a reflecting pool
	-------------------------------------------------------------------------------------------------------
	if annexOn then
		local ax0 = x1 + an.gap
		local ax1 = ax0 + aw
		local axm = (ax0 + ax1) / 2
		local ad = math.min(aw, D - 12)
		local azm = math.clamp((tz0 + tz1) / 2, -hd + 5 + ad / 2, hd - 2 - ad / 2)
		local az0, az1 = azm - ad / 2, azm + ad / 2
		local ya = math.min(an.under, H - an.height - 18)
		local yt = ya + an.height
		local c = an.core / 2
		Kit.box(
			m,
			"BoxStem",
			Vector3.new(axm - c, -KIT.bury, azm - c),
			Vector3.new(axm + c, ya + 1, azm + c),
			Kit.look(rgb(236, 234, 228), Enum.Material.SmoothPlastic)
		)
		Kit.trim(
			m,
			"BoxFloor",
			Vector3.new(ax0 - 0.6, ya - 1.2, az0 - 0.6),
			Vector3.new(ax1 + 0.6, ya, az1 + 0.6),
			whiteLook
		)
		Kit.box(m, "Box", Vector3.new(ax0, ya, az0), Vector3.new(ax1, yt, az1), Kit.glassLook(rgb(40, 44, 50), 0.2))
		Kit.box(
			m,
			"BoxRoof",
			Vector3.new(ax0 - 0.6, yt, az0 - 0.6),
			Vector3.new(ax1 + 0.6, yt + 1.4, az1 + 0.6),
			whiteLook
		)
		local p = an.post
		for i, corner in { { ax0, az0 }, { ax1, az0 }, { ax0, az1 }, { ax1, az1 } } do
			Kit.trim(
				m,
				`BoxPost{i}`,
				Vector3.new(corner[1] - p, ya, corner[2] - p),
				Vector3.new(corner[1] + p, yt, corner[2] + p),
				whiteLook
			)
		end
		-- Each face a mosaic of coloured glass in a leaded frame (the fine overlay, near-black): two rows split at a
		-- seeded height, each row cut into panes of different widths, so the box reads as one abstract composition of
		-- coloured glass, never as stripes. Neighbouring panes are never the same colour, round the corners too.
		local shift = rng:NextInteger(0, 3)
		local mo = an.mosaic
		local faces = {
			{ face = FRONT, a0 = ax0, a1 = ax1, plane = az0, out = -1, alongX = true },
			{ face = RIGHT, a0 = az0, a1 = az1, plane = ax1, out = 1, alongX = false },
			{ face = BACK, a0 = ax0, a1 = ax1, plane = az1, out = 1, alongX = true },
			{ face = LEFT, a0 = az0, a1 = az1, plane = ax0, out = -1, alongX = false },
		}
		for fi, side in faces do
			local o0, o1 = side.plane - side.out * 0.1, side.plane + side.out * an.skin
			local rowSplit = ya + 0.3 + (yt - ya - 0.6) * (mo.split[1] + rng:NextNumber() * (mo.split[2] - mo.split[1]))
			local rows = { { ya + 0.3, rowSplit - an.paneGap / 2 }, { rowSplit + an.paneGap / 2, yt - 0.3 } }
			for r, row in rows do
				local cuts = mo.cuts[(fi + r) % #mo.cuts + 1]
				local span = side.a1 - side.a0 - 1 - (#cuts - 1) * an.paneGap
				local s0 = side.a0 + 0.5
				for j, share in cuts do
					local s1 = s0 + span * share
					local color = STAINED[(fi + 2 * r + j + shift) % #STAINED + 1]
					local lo = if side.alongX then Vector3.new(s0, row[1], o0) else Vector3.new(o0, row[1], s0)
					local hi = if side.alongX then Vector3.new(s1, row[2], o1) else Vector3.new(o1, row[2], s1)
					local panel = Kit.detail(m, `Pane{fi}{r}{j}`, lo, hi, Kit.glassLook(color, STAINED_REFLECTANCE))
					panel.textures = {
						{
							face = Kit.face(m, side.face),
							image = City.textures.windowFine,
							u = 2.4,
							v = 3,
							color = LEAD,
						},
					}
					Kit.lit(panel, "stained")
					s0 = s1 + an.paneGap
				end
			end
		end
	else
		Kit.pool(m, "Pool", Vector3.new(x0 + 4, 0, -hd + 3), Vector3.new(x1 - 4, 0, wz0 - 3), SHAPE.plaza)
		for i, side in { -1, 1 } do
			local near = if side < 0 then x0 - 4 else x1 + 4
			local far = near + side * 8
			Kit.planter(
				m,
				`Planter{i}`,
				Vector3.new(math.min(near, far), SHAPE.plaza, tz0),
				Vector3.new(math.max(near, far), SHAPE.plaza + 1.6, tz0 + 8),
				whiteLook
			)
		end
	end
end

local archetype: Types.Archetype = { id = "tiled_mural_midrise", build = build }
return archetype
