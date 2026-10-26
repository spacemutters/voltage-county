--!strict
-- T15 parallelogram_void_tower (docs/city/ARCHETYPES.md §5, T15): a tall tower of clear, slightly blue glass made of
-- two slabs locked side by side, the shorter one standing a few studs nearer the street (an L in plan). Both tops are
-- raked, so in elevation the tower is a stack of parallelograms with a white coping and a lit line along each cut. The
-- taller slab is cut right through by a six-storey void: you see the sky through the tower, a lap pool runs through it
-- on a white tray that pushes out toward the street with a glass rail, and at night the void's ceiling and walls glow.
-- White balconies wrap the tall slab's front and outer end; the short slab carries slab edges every four floors that
-- run out to a white grid frame standing up its outer front corner and past its roof, lit at night like a beacon.
-- Below: a garage podium wrapped in a metal mesh screen, a lit glass lobby, a porte-cochere canopy with the name, a
-- pool deck.
--
-- What makes it itself: a slot of sky through a glass tower, glowing at night, under raked parallelogram tops.
-- Placement, sizes, heights and its budget: Config/CityArchetypes/parallelogram_void_tower.
-- Variants: palette (3 sets of glass, void glow and mesh), crown (1 both tops raked the same way: a staircase of
-- parallel cuts; 2 the tops raked toward each other: a crystal peak; 3 the tall top raked, the short one flat with a
-- roof terrace, a pool and a pergola, and a taller frame), rhythm (1 balconies every second floor with glass rails and
-- the void low over the podium, as built; 2 a white slab edge every floor and the void a third of the way up; 3
-- balconies every third floor with rails and the void high), mirror.
--
-- Previewing, check: the void reads as a hole of sky from the street at every rhythm (not a dark recess), its white
-- head, jambs and sill stand proud and the pool tray and rail sit clear in front of it; the rakes read as sharp cuts
-- against the sky and the copings sit on the edges (no gap, no float); the frame's front post lines up with the short
-- slab's edges; the mesh screen reads as a screen over the garage bands; at night the void glows on three sides and the
-- rake lines and the frame show as thin lines, no more than two neon colours.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local City = require(ReplicatedStorage.Shared.Config.City)
local Kit = require(script.Parent.Parent.Parent.Kit)
local Types = require(script.Parent.Parent.Parent.Types)

local P = City.palettes
local KIT = City.kit
local rgb = Color3.fromRGB

-- The recipe, in studs.
local SHAPE = {
	floor = 12,
	lobby = 16, -- the double-height ground floor
	level = 10, -- a parking level
	podiumShare = 0.11, -- of the height, the podium (in whole levels)...
	levels = { 3, 5 }, -- ...between these
	frontSetback = 4, -- the podium's face behind the front line
	sideInset = 1.5,
	backInset = 1.5,
	slot = 3.6, -- the dark slot at the top of each parking level
	bandProud = 0.4,
	lobbyInset = 3,
	capThick = 1.4,
	capProud = 0.8, -- past the bands, so the cap also clears the mesh screen
	mesh = { thick = 0.6, clear = 0.1, gap = { 0.12, 8, 16 } }, -- the mesh screen, and the gap over the entrance
	towerMargin = 9, -- each side of the tower group, at least, to the site's sides
	towerWidth = { 60, 116 },
	towerDepth = { 26, 42 },
	towerBack = 3.5, -- the tall slab's back face from the back line
	tall = 0.58, -- the tall slab's share of the tower's width
	lock = { 2, 6 }, -- the short slab stands this far in front of the tall one...
	deckClear = 8, -- ...leaving at least this much pool deck in front of it
	rake = { 20, 30 }, -- degrees, drawn per copy
	drop = { 0.1, 32, 64 }, -- the short slab's high point under the tall one's: share of the height, clamped
	plate = { thick = 1.4, front = 4, side = 3.5 }, -- the tall slab's balconies, wrapping its front and outer end
	edge = { thick = 1.2, proud = 1.4, every = 48, lift = 0.3 }, -- the short slab's slab edges
	frame = { post = 2.2, out = 4.4, span = 14, rise = 24, riseFlat = 34 },
	void = { floors = 6, leg = { 0.16, 5, 8 }, tray = 6, pool = { 0.34, 8, 12 }, head = 1.4, jamb = 1.2 },
	coping = { thick = 1.0, wide = 1.8 },
	canopyY = 12.5,
	canopyThick = 1.2,
	canopyHalf = 16,
	canopyPost = 1.3,
	deepDeck = 16, -- a pool deck in front of the slabs once the podium deck is this deep (sites with a core claim)
}

-- Glass, the void's glow (its night kind and the void's inner walls by day: a pale tint, so by day the void reads as
-- a clean white-framed hole) and the podium's mesh and concrete.
local PALETTES = {
	{
		glass = rgb(118, 156, 176),
		glow = "neonViolet",
		glowDay = rgb(226, 220, 242),
		mesh = rgb(198, 204, 210),
		podium = P.concrete.pale,
	},
	{
		glass = P.glass.aqua,
		glow = "crown",
		glowDay = P.frame.white,
		mesh = rgb(214, 198, 168),
		podium = P.concrete.warm,
	},
	{
		glass = rgb(84, 120, 146),
		glow = "neonBlue",
		glowDay = rgb(214, 230, 244),
		mesh = rgb(128, 136, 146),
		podium = P.concrete.pale,
	},
}

-- Balcony interval, glass rails, and how far up the void sits (0 = two floors over the deck, as built).
local RHYTHMS = {
	{ every = 24, rails = true, void = 0 },
	{ every = 12, rails = false, void = 0.32 },
	{ every = 36, rails = true, void = 0.55 },
}

local RAIL = Kit.look(rgb(214, 236, 242), Enum.Material.Glass, 0.1, KIT.railTransparency)
local FRONT, BACK = Enum.NormalId.Front, Enum.NormalId.Back
local LEFT, RIGHT = Enum.NormalId.Left, Enum.NormalId.Right

local function build(m: Types.Model)
	local site = m.site
	local variant = site.variant
	local pal = PALETTES[math.clamp(variant.palette, 1, #PALETTES)]
	local rhythm = RHYTHMS[math.clamp(variant.rhythm, 1, #RHYTHMS)]
	local crown = math.clamp(variant.crown, 1, 3)
	local rng = Kit.rng(m)
	local W, D, H = site.width, site.depth, site.height
	local hw, hd = W / 2, D / 2
	local f = SHAPE.floor
	local white = P.frame.white
	local frameLook = Kit.look(white, Enum.Material.SmoothPlastic)
	local glassLook = Kit.glassLook(pal.glass, 0.2)
	local grid = pal.glass:Lerp(white, 0.5)
	local tag = City.signNames.towers[rng:NextInteger(1, #City.signNames.towers)]

	-------------------------------------------------------------------------------------------------------
	-- Podium: glass lobby, garage levels in a mesh screen, cap, porte-cochere
	-------------------------------------------------------------------------------------------------------
	local levels = math.clamp(math.round(H * SHAPE.podiumShare / SHAPE.level), SHAPE.levels[1], SHAPE.levels[2])
	local podiumTop = SHAPE.lobby + levels * SHAPE.level
	local deckY = podiumTop + SHAPE.capThick
	local px0, px1 = -hw + SHAPE.sideInset, hw - SHAPE.sideInset
	local pz0, pz1 = -hd + SHAPE.frontSetback, hd - SHAPE.backInset
	local li = SHAPE.lobbyInset

	Kit.glass(
		m,
		"Lobby",
		Vector3.new(px0 + li, -KIT.bury, pz0 + li),
		Vector3.new(px1 - li, SHAPE.lobby + 0.5, pz1),
		rgb(44, 60, 70),
		{
			image = City.textures.windowBold,
			faces = { FRONT, LEFT, RIGHT },
			u = 6,
			v = SHAPE.lobby,
			lines = white,
			lit = true,
		}
	)
	Kit.podium(
		m,
		"Podium",
		Vector3.new(px0, SHAPE.lobby, pz0),
		Vector3.new(px1, podiumTop, pz1),
		levels,
		SHAPE.slot,
		SHAPE.bandProud,
		Kit.look(pal.podium, Enum.Material.Concrete),
		Kit.look(P.concrete.dark, Enum.Material.SmoothPlastic)
	)
	-- The mesh: two metal screens over the garage face, a gap over the entrance where the bands show.
	local gapHalf = math.clamp(W * SHAPE.mesh.gap[1], SHAPE.mesh.gap[2], SHAPE.mesh.gap[3])
	local meshBack = pz0 - SHAPE.bandProud - SHAPE.mesh.clear
	local meshLook = Kit.look(pal.mesh, Enum.Material.Metal)
	for i, span in { { px0 + 2, -gapHalf }, { gapHalf, px1 - 2 } } do
		local screen = Kit.trim(
			m,
			`Mesh{i}`,
			Vector3.new(span[1], SHAPE.lobby + 0.8, meshBack - SHAPE.mesh.thick),
			Vector3.new(span[2], podiumTop - 0.6, meshBack),
			meshLook
		)
		screen.textures = {
			{
				face = FRONT,
				image = City.textures.windowBold,
				u = 1.6,
				v = 1.6,
				color = pal.mesh:Lerp(P.concrete.dark, 0.55),
			},
		}
	end
	local cap = SHAPE.bandProud + SHAPE.capProud
	Kit.trim(
		m,
		"PodiumCap",
		Vector3.new(px0 - cap, podiumTop, pz0 - cap),
		Vector3.new(px1 + cap, deckY, pz1 + cap),
		frameLook
	)
	Kit.neonStrip(
		m,
		"PodiumLed",
		Vector3.new(px0 - cap, podiumTop + 0.35, pz0 - cap - 0.15),
		Vector3.new(px1 + cap, podiumTop + 0.75, pz0 - cap - 0.05),
		pal.glow,
		white
	)

	-- The porte-cochere: a slab on two slim posts over the drop-off, the name standing on its front edge.
	local cw = math.min(SHAPE.canopyHalf, gapHalf + 2)
	local canopyTop = SHAPE.canopyY + SHAPE.canopyThick
	Kit.canopy(m, "Canopy", -cw, cw, -hd + 0.5, pz0 + li + 0.5, SHAPE.canopyY, SHAPE.canopyThick, frameLook)
	for i, sx in { -1, 1 } do
		Kit.column(
			m,
			`CanopyPost{i}`,
			sx * (cw - 1.4),
			-hd + 2,
			-KIT.bury,
			SHAPE.canopyY,
			SHAPE.canopyPost,
			frameLook,
			"trim"
		)
	end
	Kit.sign(
		m,
		"Name",
		Vector3.new(-cw * 0.75, canopyTop, -hd + 0.8),
		Vector3.new(cw * 0.75, canopyTop + 2.6, -hd + 1.3),
		FRONT,
		tag,
		rgb(40, 44, 50),
		white,
		City.districtLooks.downtown.font
	)

	-------------------------------------------------------------------------------------------------------
	-- The two slabs: A (tall, left, the void) and B (short, right, nearer the street)
	-------------------------------------------------------------------------------------------------------
	local tw = math.min(
		math.clamp(W - 2 * SHAPE.towerMargin, SHAPE.towerWidth[1], SHAPE.towerWidth[2]),
		W - 2 * (SHAPE.frame.out + 0.6)
	)
	local tx = tw / 2
	local a = math.round(tw * SHAPE.tall)
	local b = tw - a
	local xs = -tx + a -- where the slabs meet
	local td = math.clamp(D - 20, SHAPE.towerDepth[1], SHAPE.towerDepth[2])
	local tz1 = hd - SHAPE.towerBack
	local tz0 = tz1 - td
	local lock = math.clamp(tz0 - pz0 - SHAPE.deckClear - SHAPE.edge.proud, SHAPE.lock[1], SHAPE.lock[2])
	local bz0, bz1 = tz0 - lock, tz1 - lock

	local angle = math.rad(SHAPE.rake[1] + rng:NextNumber() * (SHAPE.rake[2] - SHAPE.rake[1]))
	local rA = a * math.tan(angle)
	local yA = H - rA -- the tall slab's glass top; its rake rises to H
	local drop = math.clamp(H * SHAPE.drop[1], SHAPE.drop[2], SHAPE.drop[3])
	local bHigh = H - drop
	local flatB = crown == 3
	local rB = if flatB then 0 else b * math.tan(angle)
	local yB = bHigh - rB
	local riseA: Kit.Side = if crown == 2 then "right" else "left"

	-- The void: six floors through the tall slab's depth, on the floor grid, at least two floors clear of the deck and
	-- of the rake.
	local vh = SHAPE.void.floors * f
	local highest = math.floor((yA - vh - 2 * f - deckY) / f)
	local k = math.clamp(math.round((yA - deckY) * rhythm.void / f), 2, math.max(2, highest))
	local vb = deckY + k * f
	local vt = vb + vh
	local leg = math.clamp(a * SHAPE.void.leg[1], SHAPE.void.leg[2], SHAPE.void.leg[3])
	local vx0, vx1 = -tx + leg, xs - leg

	-- Glass: one run of floors glows warm at night on some copies. Its splits hide under balconies and the void.
	local litRoll, litWhich = rng:NextNumber(), rng:NextNumber()
	local lit = litRoll < 0.65
	local function run(name: string, min: Vector3, max: Vector3, faces: { Enum.NormalId }, isLit: boolean)
		Kit.glass(m, name, min, max, pal.glass, {
			image = City.textures.windowFine,
			faces = faces,
			u = 6,
			v = f,
			lines = grid,
			lit = isLit,
			reflectance = 0.2,
		})
	end
	local ym = vt + math.max(f, math.floor((yA - vt) / 2 / f) * f)
	run("Lower", Vector3.new(-tx, deckY - 0.5, tz0), Vector3.new(xs, vb, tz1), { FRONT, BACK, LEFT }, false)
	run("LegL", Vector3.new(-tx, vb, tz0), Vector3.new(vx0, vt, tz1), { FRONT, BACK, LEFT, RIGHT }, false)
	run("LegR", Vector3.new(vx1, vb, tz0), Vector3.new(xs, vt, tz1), { FRONT, BACK, LEFT }, false)
	run("Upper", Vector3.new(-tx, vt, tz0), Vector3.new(xs, ym, tz1), { FRONT, BACK, LEFT }, lit and litWhich < 0.5)
	run("Top", Vector3.new(-tx, ym, tz0), Vector3.new(xs, yA, tz1), { FRONT, BACK, LEFT, RIGHT }, false)
	local bm = deckY + math.max(f, math.floor((yB - deckY) / 2 / f) * f)
	run("ShortLower", Vector3.new(xs, deckY - 0.5, bz0), Vector3.new(tx, bm, bz1), { FRONT, BACK, RIGHT }, false)
	run(
		"ShortUpper",
		Vector3.new(xs, bm, bz0),
		Vector3.new(tx, yB, bz1),
		{ FRONT, BACK, RIGHT },
		lit and litWhich >= 0.5
	)

	-------------------------------------------------------------------------------------------------------
	-- The rakes: a glass wedge on each slab, a white coping half sunk along its front edge and a lit line under it
	-------------------------------------------------------------------------------------------------------
	local function rake(
		name: string,
		x0: number,
		x1: number,
		y0: number,
		r: number,
		rise: Kit.Side,
		z0: number,
		z1: number
	)
		Kit.wedge(m, name, Vector3.new(x0, y0, z0), Vector3.new(x1, y0 + r, z1), rise, glassLook)
		local lowX, highX = if rise == "left" then x1 else x0, if rise == "left" then x0 else x1
		local function along(t: number, below: number, z: number): Vector3
			return Vector3.new(lowX + (highX - lowX) * t, y0 + r * t - below, z)
		end
		Kit.strut(
			m,
			name .. "Coping",
			along(0, 0, z0 + 0.3),
			along(1, 0, z0 + 0.3),
			SHAPE.coping.thick,
			frameLook,
			"trim",
			SHAPE.coping.wide
		)
		local line = Kit.strut(
			m,
			name .. "Line",
			along(0.05, 1.7, z0 - 0.45),
			along(0.95, 1.7, z0 - 0.45),
			0.6,
			Kit.look(white, Enum.Material.SmoothPlastic),
			"detail",
			0.4
		)
		Kit.lit(line, "crown")
	end
	rake("RakeA", -tx, xs, yA, rA, riseA, tz0, tz1)
	if not flatB then
		rake("RakeB", xs, tx, yB, rB, "left", bz0, bz1)
	end

	-------------------------------------------------------------------------------------------------------
	-- The void: a white head, jambs and sill tray framing it, a lap pool through it, lit ceiling and walls
	-------------------------------------------------------------------------------------------------------
	local vd = SHAPE.void
	local tray = vd.tray
	-- The head (its underside is the void's ceiling) and the jambs are white by day and glow at night, so the void
	-- reads as a lit frame from every side; the tray under the pool stays white.
	Kit.lit(
		Kit.trim(
			m,
			"VoidHead",
			Vector3.new(vx0 - 1, vt - 1.6, tz0 - vd.head),
			Vector3.new(vx1 + 1, vt + 0.4, tz1 + 0.6),
			frameLook
		),
		pal.glow
	)
	Kit.trim(
		m,
		"VoidTray",
		Vector3.new(vx0 - 1, vb - 1.6, tz0 - tray),
		Vector3.new(vx1 + 1, vb + 0.4, tz1 + 0.6),
		frameLook
	)
	-- The jambs reach 0.8 into the legs and 0.6 into the void; a lit panel lines each leg's face inside the void.
	for i, x in { vx0, vx1 } do
		local inward = if i == 1 then 1 else -1
		local jamb = Kit.trim(
			m,
			`VoidJamb{i}`,
			Vector3.new(x - inward * 0.8, vb + 0.3, tz0 - vd.jamb),
			Vector3.new(x + inward * 0.6, vt - 1.5, tz0 + 1),
			frameLook
		)
		Kit.lit(jamb, pal.glow)
		Kit.neonStrip(
			m,
			`VoidWall{i}`,
			Vector3.new(x + inward * 0.05, vb + 1.2, tz0 + 1.3),
			Vector3.new(x + inward * 0.3, vt - 2.2, tz1 - 1),
			pal.glow,
			pal.glowDay
		)
	end
	local pw = math.clamp((vx1 - vx0) * vd.pool[1], vd.pool[2], vd.pool[3])
	local pc = (vx0 + vx1) / 2
	Kit.pool(m, "Pool", Vector3.new(pc - pw / 2, 0, tz0 - tray + 1.4), Vector3.new(pc + pw / 2, 0, tz1 - 1.2), vb + 0.4)
	Kit.detail(
		m,
		"TrayRail",
		Vector3.new(vx0 - 0.8, vb + 0.4, tz0 - tray + 0.2),
		Vector3.new(vx1 + 0.8, vb + 0.4 + KIT.railHeight, tz0 - tray + 0.5),
		RAIL
	)

	-------------------------------------------------------------------------------------------------------
	-- Balconies: the tall slab's wrap its front and outer end; never across the void
	-------------------------------------------------------------------------------------------------------
	local pl = SHAPE.plate
	local railLook = if rhythm.rails then RAIL else nil
	local n = 0
	local y = deckY + rhythm.every
	while y + pl.thick <= yA - 3 do
		if y < vb - 2 or y > vt + 2 then
			n += 1
			local lo = Vector3.new(-tx - pl.side, y, tz0 - pl.front)
			Kit.trim(m, `Plate{n}`, lo, Vector3.new(xs, y + pl.thick, bz1 - 0.5), frameLook)
			if railLook then
				Kit.detail(
					m,
					`Rail{n}`,
					Vector3.new(lo.X + 0.15, y + pl.thick, lo.Z + 0.15),
					Vector3.new(xs - 0.15, y + pl.thick + KIT.railHeight, bz1 - 0.65),
					railLook
				)
			end
		end
		y += rhythm.every
	end

	-------------------------------------------------------------------------------------------------------
	-- The short slab's edges every four floors, running out to the grid frame up its outer front corner
	-------------------------------------------------------------------------------------------------------
	local e = SHAPE.edge
	local fr = SHAPE.frame
	local fx0, fx1 = tx + fr.out - fr.post, tx + fr.out
	k = 0
	y = deckY + e.every + e.lift
	while y + e.thick <= yB - 6 do
		k += 1
		-- From 0.3 past the slabs' seam, so its end never lies in the plane of the short slab's side.
		Kit.trim(
			m,
			`Edge{k}`,
			Vector3.new(xs - 0.3, y, bz0 - e.proud),
			Vector3.new(fx1 - 0.2, y + e.thick, bz1 + e.proud),
			frameLook
		)
		y += e.every
	end
	local postFront = bz0 - e.proud
	local span = math.min(fr.span, bz1 - bz0 - 2 - fr.post)
	local frameTop = bHigh + (if flatB then fr.riseFlat else fr.rise)
	for i, z in { postFront, postFront + span } do
		Kit.trim(m, `Post{i}`, Vector3.new(fx0, deckY - 0.2, z), Vector3.new(fx1, frameTop, z + fr.post), frameLook)
	end
	Kit.trim(
		m,
		"FrameHead",
		Vector3.new(fx0 - 0.1, frameTop - fr.post, postFront - 0.1),
		Vector3.new(fx1 + 0.1, frameTop + 0.1, postFront + span + fr.post + 0.1),
		frameLook
	)
	Kit.neon(
		m,
		"FrameLine",
		Vector3.new((fx0 + fx1) / 2, deckY + 2, postFront - 0.45),
		Vector3.new((fx0 + fx1) / 2, frameTop - 2, postFront - 0.45),
		"crown",
		white
	)

	-- Crown 3: the short slab's flat roof is a terrace with a pool and a pergola.
	if flatB then
		Kit.trim(
			m,
			"RoofB",
			Vector3.new(xs - 0.3, yB - 1.2, bz0 - 1.2),
			Vector3.new(tx + 1.2, yB + 0.4, bz1 + 1.2),
			frameLook
		)
		Kit.detail(
			m,
			"RoofRail",
			Vector3.new(xs + 0.4, yB + 0.4, bz0 - 1),
			Vector3.new(tx + 1, yB + 0.4 + KIT.railHeight, bz0 - 0.7),
			RAIL
		)
		local poolW = math.clamp(b - 10, 6, 16)
		Kit.pool(m, "SkyPool", Vector3.new(xs + 3, 0, bz0 + 3), Vector3.new(xs + 3 + poolW, 0, bz0 + 10), yB + 0.4)
		local gx = tx - 4
		Kit.column(m, "PergolaPost1", gx, bz0 + 13, yB + 0.4, yB + 9, 0.8, frameLook, "trim")
		Kit.column(m, "PergolaPost2", gx, bz1 - 3, yB + 0.4, yB + 9, 0.8, frameLook, "trim")
		Kit.trim(m, "Pergola", Vector3.new(gx - 3, yB + 9, bz0 + 11), Vector3.new(gx + 2, yB + 9.8, bz1 - 1), frameLook)
	end

	-------------------------------------------------------------------------------------------------------
	-- The pool deck on the podium, in front of the slabs
	-------------------------------------------------------------------------------------------------------
	local pfw = math.clamp((px1 - px0) * 0.18, 8, 20)
	Kit.planter(
		m,
		"PlanterL",
		Vector3.new(px0 + 3, deckY, pz0 + 1.2),
		Vector3.new(px0 + 3 + pfw, deckY + 1.6, pz0 + 3.2),
		frameLook
	)
	Kit.planter(
		m,
		"PlanterR",
		Vector3.new(px1 - 3 - pfw, deckY, pz0 + 1.2),
		Vector3.new(px1 - 3, deckY + 1.6, pz0 + 3.2),
		frameLook
	)
	Kit.detail(
		m,
		"DeckRail",
		Vector3.new(px0 - cap + 0.3, deckY, pz0 - cap + 0.3),
		Vector3.new(px1 + cap - 0.3, deckY + 3.4, pz0 - cap + 0.6),
		RAIL
	)
	-- On a deep site (a core claim) the deck in front of the slabs is long: a pool in front of the tall slab, umbrellas
	-- in front of the short one.
	local deckFront, deckBack = pz0 + 5, bz0 - SHAPE.edge.proud - 2
	if deckBack - deckFront >= SHAPE.deepDeck then
		local poolW = math.clamp(a * 0.6, 14, 30)
		local poolZ = math.min(deckBack - 3, deckFront + 2 + SHAPE.deepDeck * 1.6)
		Kit.pool(m, "DeckPool", Vector3.new(-tx + 2, 0, deckFront + 2), Vector3.new(-tx + 2 + poolW, 0, poolZ), deckY)
		local uz = (deckFront + deckBack) / 2
		for i, ux in { tx - 8, tx - 18 } do
			Kit.umbrella(m, `Umbrella{i}`, ux, uz, deckY, 7, P.umbrella[i + 1])
		end
	end
end

local archetype: Types.Archetype = { id = "parallelogram_void_tower", build = build }
return archetype
