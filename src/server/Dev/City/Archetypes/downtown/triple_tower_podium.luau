--!strict
-- T12 triple_tower_podium (docs/city/ARCHETYPES.md §5, T12): a one-off condo and hotel complex. Three slim towers
-- of dark glass under a fine white grid stand in a row on one huge glass podium: two identical twins at full height
-- and a shorter hotel tower. Each tower is two interlocking slabs, one taller than the other and slid a few studs
-- forward or back of it, white piers on their corners, and on the tall slab a white vertical down the middle of its
-- front and a thicker white band every ten floors (the supergrid); over every slab (crown 1) or the tall ones (crown
-- 2) the white grid runs on past the roof as an open lattice frame against the sky. The podium is glass
-- under white bands with a pool deck on top, facing the water (the front); at the street (its road side, the back
-- when the site faces the lake) it is lifted over a drive lined with giant dark stone monoliths, each a tall slab with
-- a sloping head and two eye slots that glow amber at night.
--
-- What makes it itself: three slim grid towers of stepped twin slabs with open lattice tops, on one podium, over a row
-- of monoliths with glowing eyes.
-- Placement, sizes, heights and its budget: Config/CityArchetypes/triple_tower_podium.
-- Variants: palette (3 glass and stone sets), crown (1 open lattice frames over all six slabs with ice-blue rings; 2
-- lattice frames over the three tall slabs with a coloured light-show ring each, white caps on the short ones),
-- rhythm (1 the short slabs step forward and stop four floors under the tall ones; 2 they step back and stop six
-- floors under), mirror (the hotel tower stands at the other end).
--
-- Studio pass 2026-10-26 (docs/images/city/triple_tower_podium-*.jpg): the lattice wore the window texture and read
-- as pale glass, so it wears the punched texture (white bars round see-through cells) and now reads as an open frame;
-- the monoliths read as posts under a 20-stud drive, so the drive is 30 high and each monolith bigger, with a nose
-- ridge between the eyes; the towers' glass mirrors little sky (SHAPE.sheen) so the white grid reads first. The
-- landmark case (site.face "back") puts the drive, monoliths and name on the road side behind, the deck in front.

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
	arcade = 30, -- the drive's clear height under the podium (and the lobby's): tall enough for giant heads
	level = 10, -- a podium level
	levels = { 4, 6 },
	podiumShare = 0.17, -- of the height, the podium (in whole levels, between `levels`)
	street = 3, -- the podium's street face behind the site's line on that side...
	edge = 1.5, -- ...and on the others
	drive = 14, -- the lobby glass stands this far in from the podium's street face
	lobbyIn = 3, -- and this far in from its other faces
	bandProud = 0.6,
	cap = { thick = 1.6, proud = 1 },
	tower = { margin = 6, gap = 14, max = 66, depth = { 26, 42 } },
	deckMin = 10, -- the pool deck in front of the towers, at least
	slabA = 0.6, -- the tall slab's share of its tower's width...
	slabB = 0.5, -- ...and the short one's (they overlap by the rest)
	shift = 4.5, -- the short slab stands this far forward of (or back from) the tall one
	steps = { 4, 6 }, -- floors the short slab stops under the tall one, by rhythm
	hotelShare = 0.82, -- the hotel tower's height, of the main roof
	minFloors = 12,
	grid = { 3.6, 3.2 }, -- the white grid's bay on the tall and the short slabs: fine, like rows of balconies
	pier = 1.3,
	midFin = 1.1, -- the white vertical down the middle of a tall slab's front (0.45 proud: between pier and band)
	band = { every = 10, thick = 1.6, proud = 0.7 }, -- a band every ten floors on the tall slabs
	lattice = { 14, 10 }, -- the open frame over the tall and the short slabs
	plate = { thick = 1, proud = 0.5 }, -- the frame's top
	whiteCap = 1.4, -- crown 2: the short slabs' caps
	litShare = 0.3, -- of a tall slab's height, its lit run
	sheen = 0.04, -- the towers' glass mirrors little of the sky: dark glass under the white grid, as on the real towers
	monolith = { width = 8, depth = 6, head = 6, clear = 1.5, spacing = 26, max = 7, inset = 2.5 },
	eye = { width = 2.4, height = 1, gap = 1.6, below = 2.6 },
	nose = { width = 1.3, length = 6, proud = 0.9 }, -- a ridge down the face from between the eyes
	pool = { 4, 12 }, -- its depth, between these
	umbrella = 6,
	signHeight = 5,
}

-- Glass, the short slabs' glass, the grid and frame white, the podium glass, the stone.
local PALETTES = {
	{ glass = rgb(50, 64, 76), short = rgb(58, 74, 86), frame = P.frame.white, stone = rgb(112, 108, 100) },
	{ glass = P.glass.navy, short = P.glass.teal, frame = P.frame.white, stone = rgb(96, 94, 90) },
	{ glass = rgb(60, 76, 88), short = P.glass.blue, frame = P.frame.warm, stone = rgb(124, 116, 104) },
}

local RAIL = Kit.look(rgb(214, 236, 242), Enum.Material.Glass, 0.1, KIT.railTransparency)
-- Nothing but its texture: an open grid against the sky.
local AIR = Kit.look(P.frame.white, Enum.Material.SmoothPlastic, 0, 1)
local WALLS = { Enum.NormalId.Front, Enum.NormalId.Back, Enum.NormalId.Left, Enum.NormalId.Right }

local function build(m: Types.Model)
	local site = m.site
	local variant = site.variant
	local pal = PALETTES[math.clamp(variant.palette, 1, #PALETTES)]
	local rng = Kit.rng(m)
	local W, D, H = site.width, site.depth, site.height
	local hw, hd = W / 2, D / 2
	local rhythm = math.clamp(variant.rhythm, 1, #SHAPE.steps)
	local crown = math.clamp(variant.crown, 1, 2)
	local A = SHAPE.arcade

	local frame = Kit.look(pal.frame, Enum.Material.SmoothPlastic)
	local stone = Kit.look(pal.stone, Enum.Material.Slate)
	local ridge = Kit.look(pal.stone:Lerp(Color3.new(1, 1, 1), 0.12), Enum.Material.Slate)
	local paving = Kit.look(P.deco.terrazzo, Enum.Material.SmoothPlastic)
	local lobbyGlass = rgb(44, 60, 70)

	-- The street side: the front, or the back when the site's front looks at the lake (a bay-row landmark). The pool
	-- deck always faces the front; the drive and its monoliths face the street.
	local sd = if site.face == "back" then 1 else -1
	local x0, x1 = -hw + SHAPE.edge, hw - SHAPE.edge
	local zP0 = -hd + (if sd < 0 then SHAPE.street else SHAPE.edge)
	local zP1 = hd - (if sd > 0 then SHAPE.street else SHAPE.edge)
	local zs = if sd < 0 then zP0 else zP1
	-- A z `d` studs in from the podium's street face.
	local function inward(d: number): number
		return zs - sd * d
	end

	local levels = math.clamp(math.round((H * SHAPE.podiumShare - A) / SHAPE.level), SHAPE.levels[1], SHAPE.levels[2])
	local Hp = A + levels * SHAPE.level
	local cap = SHAPE.cap
	local deckY = Hp + cap.thick

	-------------------------------------------------------------------------------------------------------
	-- The ground: paving, the lobby set in under the podium, a wash over the drive
	-------------------------------------------------------------------------------------------------------
	Kit.box(m, "Paving", Vector3.new(-hw + 0.5, 0, -hd + 0.5), Vector3.new(hw - 0.5, 0.3, hd - 0.5), paving)
	local li = SHAPE.lobbyIn
	local lobbyStreet = inward(SHAPE.drive)
	local lobbyFar = if sd < 0 then zP1 - li else zP0 + li
	Kit.glass(
		m,
		"Lobby",
		Vector3.new(x0 + li, -KIT.bury, lobbyStreet),
		Vector3.new(x1 - li, A + 0.3, lobbyFar),
		lobbyGlass,
		{
			image = City.textures.windowBold,
			u = 6,
			v = A,
			lines = pal.frame,
			lit = true,
		}
	)
	Kit.wash(m, "Wash", x0 + 8, x1 - 8, inward(10), 0.3, rgb(255, 196, 150))

	-------------------------------------------------------------------------------------------------------
	-- The podium: glass under a white grid, white bands every two levels, a fascia round its underside, the cap
	-------------------------------------------------------------------------------------------------------
	Kit.glass(m, "Podium", Vector3.new(x0, A, zP0), Vector3.new(x1, Hp, zP1), pal.glass, {
		image = City.textures.windowBold,
		u = 6,
		v = SHAPE.level,
		lines = pal.frame,
	})
	local bp = SHAPE.bandProud
	Kit.trim(m, "Fascia", Vector3.new(x0 - bp, A - 0.8, zP0 - bp), Vector3.new(x1 + bp, A + 0.6, zP1 + bp), frame)
	for j = 1, math.floor((levels - 1) / 2) do
		local y = A + 2 * j * SHAPE.level
		Kit.trim(
			m,
			`PodiumBand{j}`,
			Vector3.new(x0 - bp, y - 0.6, zP0 - bp),
			Vector3.new(x1 + bp, y + 0.6, zP1 + bp),
			frame
		)
	end
	Kit.trim(
		m,
		"PodiumCap",
		Vector3.new(x0 - cap.proud, Hp, zP0 - cap.proud),
		Vector3.new(x1 + cap.proud, deckY, zP1 + cap.proud),
		frame
	)
	Kit.neonStrip(
		m,
		"CapLed",
		Vector3.new(x0 - cap.proud, Hp + 0.4, zP0 - cap.proud - 0.15),
		Vector3.new(x1 + cap.proud, Hp + 0.9, zP0 - cap.proud - 0.05),
		"ledEdge",
		pal.frame
	)
	Kit.detail(
		m,
		"DeckRail",
		Vector3.new(x0 - cap.proud + 0.3, deckY, zP0 - cap.proud + 0.3),
		Vector3.new(x1 + cap.proud - 0.3, deckY + KIT.railHeight, zP0 - cap.proud + 0.6),
		RAIL
	)
	-- The name, on the podium's street face over the drive.
	local names = City.signNames.towers
	local signW = math.min(34, (x1 - x0) * 0.22)
	local signFace = if sd < 0 then Enum.NormalId.Front else Enum.NormalId.Back
	Kit.sign(
		m,
		"Name",
		Vector3.new(x0 + 8, A + 4, zs + sd * 0.1),
		Vector3.new(x0 + 8 + signW, A + 4 + SHAPE.signHeight, zs + sd * 0.5),
		signFace,
		names[rng:NextInteger(1, #names)],
		rgb(40, 44, 50),
		pal.frame,
		City.districtLooks.downtown.font
	)

	-------------------------------------------------------------------------------------------------------
	-- The monoliths: dark stone slabs along the drive under the podium's edge, a sloping head, two eye slots
	-------------------------------------------------------------------------------------------------------
	local mo, eye = SHAPE.monolith, SHAPE.eye
	local span = x1 - x0 - 20
	local count = math.clamp(math.floor(span / mo.spacing) + 1, 4, mo.max)
	-- Close enough to read as one colonnade on a wide site: centred, at most a little over their spacing apart.
	local pitch = math.min(span / (count - 1), mo.spacing * 1.15)
	local first = (x0 + x1) / 2 - pitch * (count - 1) / 2
	local headTop = A - mo.clear
	local headFoot = headTop - mo.head
	local faceZ = inward(mo.inset) -- the street face of every monolith
	local backZ = inward(mo.inset + mo.depth)
	-- The head rises away from the street, so the face leans back at the top like a brow.
	local away: Kit.Side = if sd < 0 then "back" else "front"
	for i = 1, count do
		local cx = first + pitch * (i - 1)
		local a, b = cx - mo.width / 2, cx + mo.width / 2
		Kit.box(m, `Monolith{i}`, Vector3.new(a, -KIT.bury, faceZ), Vector3.new(b, headFoot, backZ), stone)
		Kit.wedge(m, `Head{i}`, Vector3.new(a, headFoot, faceZ), Vector3.new(b, headTop, backZ), away, stone)
		local ey1 = headFoot - eye.below
		local nose = SHAPE.nose
		Kit.trim(
			m,
			`Nose{i}`,
			Vector3.new(cx - nose.width / 2, ey1 - nose.length, faceZ),
			Vector3.new(cx + nose.width / 2, ey1 + 0.2, faceZ + sd * nose.proud),
			ridge
		)
		for j, side in { -1, 1 } do
			local ex = cx + side * (eye.gap / 2 + eye.width / 2)
			Kit.neonStrip(
				m,
				`Eye{i}{j}`,
				Vector3.new(ex - eye.width / 2, ey1 - eye.height, faceZ + sd * 0.1),
				Vector3.new(ex + eye.width / 2, ey1, faceZ - sd * 0.05),
				"neonAmber",
				rgb(40, 38, 36)
			)
		end
	end

	-------------------------------------------------------------------------------------------------------
	-- The towers: the hotel at one end, the twins beside it; each a tall slab and a short one, interlocked
	-------------------------------------------------------------------------------------------------------
	local T = SHAPE.tower
	local tspan = x1 - x0 - 2 * T.margin
	local tw = math.min(T.max, (tspan - 2 * T.gap) / 3)
	local gapT = (tspan - 3 * tw) / 2
	local zt1 = zP1 - 2
	local shift = SHAPE.shift
	local td = math.clamp(zt1 - (zP0 + SHAPE.deckMin) - shift, T.depth[1], T.depth[2])
	local zt0 = zt1 - td - shift -- the forward slab's front
	local step = SHAPE.steps[rhythm] * SHAPE.floor
	local wa, wb = tw * SHAPE.slabA, tw * SHAPE.slabB
	local hotelTop = deckY
		+ math.max(SHAPE.minFloors, math.round((H * SHAPE.hotelShare - deckY) / SHAPE.floor)) * SHAPE.floor
	hotelTop = math.min(hotelTop, H - step - SHAPE.floor)
	local la, lb = SHAPE.lattice[1], SHAPE.lattice[2]
	local plate = SHAPE.plate
	local band = SHAPE.band
	local xs: { number } = {}

	-- One slab: glass under the white grid, its corner piers (those not buried in the taller slab), and its top.
	type Slab = { x0: number, x1: number, z0: number, z1: number, top: number }
	local function slab(name: string, s: Slab, tall: boolean, other: Slab?)
		local grid = if tall then SHAPE.grid[1] else SHAPE.grid[2]
		Kit.glass(
			m,
			name,
			Vector3.new(s.x0, deckY - 0.5, s.z0),
			Vector3.new(s.x1, s.top, s.z1),
			if tall then pal.glass else pal.short,
			{
				image = City.textures.windowBold,
				u = grid,
				v = SHAPE.floor,
				lines = pal.frame,
				reflectance = SHAPE.sheen,
			}
		)
		local lattice = tall or crown == 1
		local lh = if tall then la else lb
		local crest = if lattice then s.top + lh + plate.thick else s.top + SHAPE.whiteCap
		local p = SHAPE.pier
		for i, corner in { { -1, -1 }, { 1, -1 }, { -1, 1 }, { 1, 1 } } do
			local cx = if corner[1] < 0 then s.x0 else s.x1
			local cz = if corner[2] < 0 then s.z0 else s.z1
			local o = other
			if o and cx > o.x0 and cx < o.x1 and cz > o.z0 and cz < o.z1 then
				continue -- inside the taller slab all the way up
			end
			Kit.trim(
				m,
				`{name}Pier{i}`,
				Vector3.new(cx - corner[1] * (p - 0.35), deckY, cz - corner[2] * (p - 0.35)),
				Vector3.new(cx + corner[1] * 0.35, crest - 0.05, cz + corner[2] * 0.35),
				frame
			)
		end
		if lattice then
			-- The open frame: a transparent box wearing the white grid on its four sides, under a thin white plate.
			local air = Kit.detail(
				m,
				`{name}Lattice`,
				Vector3.new(s.x0 + 0.05, s.top - 0.05, s.z0 + 0.05),
				Vector3.new(s.x1 - 0.05, s.top + lh, s.z1 - 0.05),
				AIR
			)
			-- The punched texture is a white wall with a see-through window per tile: on an invisible part, white bars
			-- round open cells.
			local textures: { Types.TextureSpec } = {}
			for _, face in WALLS do
				table.insert(textures, {
					face = Kit.face(m, face),
					image = City.textures.punched,
					u = grid,
					v = lh / 2,
					color = pal.frame,
				})
			end
			air.textures = textures
			Kit.trim(
				m,
				`{name}Plate`,
				Vector3.new(s.x0 - plate.proud, s.top + lh, s.z0 - plate.proud),
				Vector3.new(s.x1 + plate.proud, s.top + lh + plate.thick, s.z1 + plate.proud),
				frame
			)
			if tall then
				-- A lit line under the plate's edge (crown 2: a light show, a colour on some nights).
				Kit.neonStrip(
					m,
					`{name}Ring`,
					Vector3.new(s.x0 - plate.proud + 0.2, s.top + lh - 0.45, s.z0 - plate.proud + 0.2),
					Vector3.new(s.x1 + plate.proud - 0.2, s.top + lh - 0.05, s.z1 + plate.proud - 0.2),
					if crown == 2 then "crownShow" else "ledEdge",
					pal.frame
				)
			end
		else
			Kit.trim(
				m,
				`{name}Cap`,
				Vector3.new(s.x0 - 0.6, s.top, s.z0 - 0.6),
				Vector3.new(s.x1 + 0.6, s.top + SHAPE.whiteCap, s.z1 + 0.6),
				frame
			)
		end
		if tall then
			-- The supergrid: a white vertical down the middle of the front, up through the lattice into the plate...
			local mid = (s.x0 + s.x1) / 2
			local fw = SHAPE.midFin / 2
			Kit.trim(
				m,
				`{name}Mid`,
				Vector3.new(mid - fw, deckY, s.z0 - 0.45),
				Vector3.new(mid + fw, s.top + lh + plate.thick / 2, s.z0 + 0.3),
				frame
			)
			-- ...and a white band every ten floors (none in the top three floors).
			local j = 1
			while deckY + j * band.every * SHAPE.floor < s.top - 3 * SHAPE.floor do
				local y = deckY + j * band.every * SHAPE.floor
				Kit.trim(
					m,
					`{name}Band{j}`,
					Vector3.new(s.x0 - band.proud, y - band.thick / 2, s.z0 - band.proud),
					Vector3.new(s.x1 + band.proud, y + band.thick / 2, s.z1 + band.proud),
					frame
				)
				j += 1
			end
		end
	end

	for k = 1, 3 do
		local xl = x0 + T.margin + (k - 1) * (tw + gapT)
		table.insert(xs, xl)
		local topA = if k == 1 then hotelTop else H
		local topB = topA - step
		-- The hotel and the first twin keep their tall slab on the right, the second twin on the left: the twins' tall
		-- slabs stand together in the middle of the pair.
		local tallLeft = k == 3
		local ax0 = if tallLeft then xl else xl + tw - wa
		local bx0 = if tallLeft then xl + tw - wb else xl
		-- Rhythm 1 brings the short slab forward, rhythm 2 the tall one.
		local az0, bz0 = zt0 + shift, zt0
		if rhythm == 2 then
			az0, bz0 = zt0, zt0 + shift
		end
		local tall: Slab = { x0 = ax0, x1 = ax0 + wa, z0 = az0, z1 = az0 + td, top = topA }
		local short: Slab = { x0 = bx0, x1 = bx0 + wb, z0 = bz0, z1 = bz0 + td, top = topB }
		slab(`T{k}A`, tall, true, nil)
		slab(`T{k}B`, short, false, tall)

		-- A lit run on the tall slab's front: a few floors' windows glowing.
		local runSpan = topA - deckY - 3 * SHAPE.floor
		local run0 = deckY + SHAPE.floor + rng:NextNumber() * runSpan * (1 - SHAPE.litShare)
		local skin = Kit.detail(
			m,
			`T{k}Lit`,
			Vector3.new(tall.x0 + 1, run0, tall.z0 - 0.18),
			Vector3.new(tall.x1 - 1, run0 + runSpan * SHAPE.litShare, tall.z0 - 0.06),
			Kit.glassLook(pal.glass)
		)
		skin.textures = {
			{
				face = Kit.face(m, Enum.NormalId.Front),
				image = City.textures.windowBold,
				u = SHAPE.grid[1],
				v = SHAPE.floor,
				color = pal.frame,
			},
		}
		Kit.lit(skin, "window")
	end

	-------------------------------------------------------------------------------------------------------
	-- The pool deck in front of the towers: a long pool before the twins, umbrellas before the hotel, planters
	-------------------------------------------------------------------------------------------------------
	local d0 = zP0 - cap.proud + 1.2
	local d1 = zt0 - 1.5
	local deck = d1 - d0
	local pd = math.min(math.clamp(deck * 0.3, SHAPE.pool[1], SHAPE.pool[2]), deck - 4.6)
	if pd >= 2 then
		local pz0 = d0 + math.max(1.2, (deck - pd) / 2)
		Kit.pool(m, "Pool", Vector3.new(xs[2] + 2, 0, pz0), Vector3.new(xs[3] + tw - 2, 0, pz0 + pd), deckY)
	end
	if deck >= 6.4 then
		local uz = math.clamp(d0 + deck / 2, d0 + 3.2, d1 - 3.2)
		for i, at in { 0.2, 0.5, 0.8 } do
			Kit.umbrella(
				m,
				`Umbrella{i}`,
				xs[1] + tw * at,
				uz,
				deckY,
				SHAPE.umbrella,
				if i == 2 then P.deco.aqua else pal.frame,
				true
			)
		end
	end
	local gx0, gx1 = xs[1] + tw + 2, xs[2] - 2
	if gx1 - gx0 >= 4 then
		Kit.planter(m, "Planter1", Vector3.new(gx0, deckY, d0), Vector3.new(gx1, deckY + 1.4, d0 + 2.4), frame)
	end
	local ex0, ex1 = xs[3] + tw + 2, x1 - 1
	if ex1 - ex0 >= 4 then
		Kit.planter(m, "Planter2", Vector3.new(ex0, deckY, d0), Vector3.new(ex1, deckY + 1.4, d0 + 2.4), frame)
	end
end

local archetype: Types.Archetype = { id = "triple_tower_podium", build = build }
return archetype
