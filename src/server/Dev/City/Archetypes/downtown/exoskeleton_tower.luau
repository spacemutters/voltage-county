--!strict
-- T02 exoskeleton_tower (docs/city/ARCHETYPES.md §5, T02): the north peak's landmark. A slender square glass tower is
-- held by a white exoskeleton that stands in front of its glass. On every face two ribs rise from the plaza close to the
-- face's middle and sweep out to the corners. There they merge into one thick corner column, then sweep back in toward
-- the middle under the roof. Each face reads as a long white lens over dark glass, with slab edges behind it every
-- second floor. The lowest floors' corners hang free (terraces cantilever there). Under the roof a pair of branches
-- rises from each face's middle and crosses the ribs' sweep, a web that glows at night. The roof carries a helipad, a
-- sky pool under a folded metal canopy, or a glass lantern, under a ring of light.
--
-- What makes it itself: white ribs fanning from the street to the corners and back in at the crown, a web over glass.
-- Placement, sizes, heights and its budget: Config/CityArchetypes/exoskeleton_tower. It is a one-off (weight 0): the
-- planner builds it once at its anchor (Config/City landmarks) with a core claim, about 110 deep.
-- Variants: palette (3 glass, rib and slab sets); crown (1 a helipad and a beacon mast, 2 a sky pool under a folded
-- metal canopy, 3 a glass lantern under a lit lid); rhythm (1 legs near each face's middle fanning out to the corners,
-- as in the inspiration; 2 a wider stance with short fans; 3 an hourglass, corner legs bowing in toward the middle at
-- mid-height); mirror (symmetric, so it changes nothing visible).
--
-- When previewing: use a deep site (Preview option depth = 110). On a 53-deep plot the core shrinks to 32. Check where
-- two rib segments meet (no gaps, slivers or flicker), and that the legs meet the plaza with no gap. From far off, each
-- face should read as one smooth lens, not a cage of sticks. At night, the crown's branches, the roof ring and the lobby
-- glow; the glass stays dark. The ribs themselves never light, so they stay in the still model and keep the tower's
-- shape when it is seen from afar.

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
	lobby = 16, -- the glass lobby under the core
	lobbyInset = 1.5,
	plaza = 0.35, -- the plaza's paving stands this far over the ground (it hides where the legs meet the ground)
	front = 14, -- on a deep site the tower's front stands at most this far behind the plaza's front
	sideRoom = 1.5,
	core = 66, -- the glass core's side, at most
	reach = 8.5, -- the ribs, legs and corner columns stay within this of the core's faces
	-- A rib's width: share of the core's side, clamped. Bold enough to read as a structure from across the city (the
	-- first preview's 3.6-stud ribs, and then 5.6, read as white outlines round a glass box).
	rib = { 0.12, 4.4, 8 },
	ribDepth = 3.4,
	ribGap = 1.2, -- between the glass and the ribs' backs
	leg = 1.6, -- the lowest segment of a rib is this many ribs wide...
	taper = 1.3, -- ...the one over it this many, so the leg narrows in steps rather than one notch
	corner = 1.15, -- the corner column is this many ribs wide
	overlap = 0.35, -- a segment runs on past its knots by this many of its widths, closing the joints
	web = { from = 0.84, reach = 0.62, segments = 2 }, -- the crown's branches: where they start, how far they fan out
	plate = { every = 24, thick = 1.2, proud = 1 }, -- slab edges, every second floor
	roof = 3,
	roofReach = 8.1, -- the roof slab's reach past the core's faces (over the corner columns, inside `reach`)
	roofRing = 0.9, -- its light line: this far in from its top and bottom
	canopyY = 12,
	canopyThick = 1.2,
	canopyDepth = 9,
	pad = 0.66, -- crown 1: the helipad's diameter, of the core's side...
	padMax = 34, -- ...at most
	mast = 22,
	canopyRise = 9, -- crown 2: the folded canopy's eaves over the roof
	fold = 3, -- its ridge over its eaves
	lantern = 12, -- crown 3: the lantern's height
	lanternLid = 1.6,
}

-- A rib's path up a face: t from 0 at the foot to 1 at the roof, `a` the rib's distance from the face's middle as a
-- share of the way to the corner column (1 is in it).
type Knot = { t: number, a: number }
type Rhythm = { path: { Knot }, corners: { { number } } }

local function smooth(u: number): number
	return u * u * (3 - 2 * u)
end

-- Legs at a0 fanning out to the corner by tb, the corner column up to tt, then a fan back in to a1 at the roof. Each
-- fan starts and ends upright.
local function fanPath(a0: number, tb: number, tt: number, a1: number, n: number): { Knot }
	local knots: { Knot } = {}
	for i = 0, n do
		local u = i / n
		table.insert(knots, { t = tb * u, a = a0 + (1 - a0) * smooth(u) })
	end
	for i = 0, n do
		local u = i / n
		table.insert(knots, { t = tt + (1 - tt) * u, a = 1 - (1 - a1) * smooth(u) })
	end
	return knots
end

-- Legs at the corners bowing in to `waist` at mid-height and back out to the corners at the roof.
local function waistPath(waist: number, n: number): { Knot }
	local knots: { Knot } = {}
	for i = 0, n do
		local t = i / n
		table.insert(knots, { t = t, a = 1 - (1 - waist) * math.sin(math.pi * t) })
	end
	return knots
end

-- Per rhythm: the path and the corner columns' runs (t from, t to).
local RHYTHMS: { Rhythm } = {
	{ path = fanPath(0.16, 0.26, 0.78, 0.34, 4), corners = { { 0.26, 0.78 } } },
	{ path = fanPath(0.46, 0.16, 0.86, 0.5, 4), corners = { { 0.16, 0.86 } } },
	{ path = waistPath(0.3, 8), corners = { { 0, 0.05 }, { 0.95, 1 } } },
}

-- Glass, ribs (and the roof), slab edges and the helipad's deck.
local PALETTES = {
	{ glass = rgb(62, 89, 99), rib = P.frame.white, slab = rgb(232, 230, 224), pad = rgb(58, 62, 68) },
	{ glass = P.glass.smoke, rib = P.frame.white, slab = rgb(226, 228, 230), pad = rgb(52, 56, 62) },
	{ glass = P.glass.teal, rib = P.frame.warm, slab = rgb(236, 230, 218), pad = rgb(60, 58, 56) },
}

-- The four faces: outward normal, the way across it, a name.
local FACES = {
	{ n = Vector3.new(0, 0, -1), e = Vector3.xAxis, name = "F" },
	{ n = Vector3.new(0, 0, 1), e = Vector3.xAxis, name = "B" },
	{ n = Vector3.new(-1, 0, 0), e = Vector3.zAxis, name = "L" },
	{ n = Vector3.new(1, 0, 0), e = Vector3.zAxis, name = "R" },
}

local RAIL = Kit.look(rgb(214, 236, 242), Enum.Material.Glass, 0.1, KIT.railTransparency)
local METAL = Kit.look(rgb(200, 204, 210), Enum.Material.Metal)

-- A straight rib piece from a to b lying in a facade whose outward normal is `normal` (square to a..b): `across` wide
-- in the facade's plane, `thick` out from it.
local function rib(
	m: Types.Model,
	name: string,
	a: Vector3,
	b: Vector3,
	across: number,
	thick: number,
	normal: Vector3,
	look: Kit.Look,
	kind: Kit.Kind
): Types.PartSpec
	local along = b - a
	local l = along.Unit
	local cf = CFrame.fromMatrix((a + b) / 2, normal:Cross(l), normal, l)
	return Kit.oriented(m, name, "block", cf, Vector3.new(across, thick, along.Magnitude), look, kind)
end

local function build(m: Types.Model)
	local site = m.site
	local variant = site.variant
	local pal = PALETTES[math.clamp(variant.palette, 1, #PALETTES)]
	local rhythm = RHYTHMS[math.clamp(variant.rhythm, 1, #RHYTHMS)]
	local rng = Kit.rng(m)
	local W, D, H = site.width, site.depth, site.height
	local hw, hd = W / 2, D / 2
	local rise = site.maxHeight - H
	local ribLook = Kit.look(pal.rib, Enum.Material.SmoothPlastic)
	local slabLook = Kit.look(pal.slab, Enum.Material.SmoothPlastic)
	local tag = City.signNames.towers[rng:NextInteger(1, #City.signNames.towers)]

	-------------------------------------------------------------------------------------------------------
	-- The footprint: a square core, the exoskeleton within SHAPE.reach of it, a plaza in front
	-------------------------------------------------------------------------------------------------------
	local zMin, zMax = -hd + KIT.frontClear, hd - 1
	local room = math.min(hw - SHAPE.sideRoom, (zMax - zMin) / 2)
	local S = math.min(SHAPE.core, 2 * (room - SHAPE.reach))
	local s2 = S / 2
	local E = s2 + SHAPE.reach -- the tower's reach from its centre
	local zc = zMin + E + math.clamp((zMax - zMin) - 2 * E, 0, SHAPE.front)
	local w = math.clamp(S * SHAPE.rib[1], SHAPE.rib[2], SHAPE.rib[3])
	local d = SHAPE.ribDepth
	local plane = s2 + SHAPE.ribGap + d / 2 -- the ribs' centre plane, from the core's centre
	local Hr = H - SHAPE.roof -- the roof slab's underside
	local yFoot, yHead = -KIT.bury, Hr + 0.4
	local function yAt(t: number): number
		return yFoot + t * (yHead - yFoot)
	end

	Kit.box(
		m,
		"Plaza",
		Vector3.new(-hw + 0.3, -0.6, -hd + 0.3),
		Vector3.new(hw - 0.3, SHAPE.plaza, hd - 0.3),
		Kit.look(P.deco.terrazzo, Enum.Material.SmoothPlastic)
	)

	-------------------------------------------------------------------------------------------------------
	-- Core: the lobby, the glass, slab edges every second floor
	-------------------------------------------------------------------------------------------------------
	local li = SHAPE.lobbyInset
	Kit.glass(
		m,
		"Lobby",
		Vector3.new(-s2 + li, -KIT.bury, zc - s2 + li),
		Vector3.new(s2 - li, SHAPE.lobby + 0.4, zc + s2 - li),
		rgb(46, 62, 72),
		{ image = City.textures.windowBold, u = 4.4, v = SHAPE.lobby, lines = pal.rib, lit = true }
	)
	Kit.glass(m, "Core", Vector3.new(-s2, SHAPE.lobby, zc - s2), Vector3.new(s2, Hr + 0.3, zc + s2), pal.glass, {
		image = City.textures.windowFine,
		u = S / math.max(1, math.round(S / 5.5)),
		v = SHAPE.floor,
		lines = pal.glass:Lerp(pal.slab, 0.4),
	})
	local plate = SHAPE.plate
	Kit.plates(
		m,
		"Slab",
		Vector3.new(-s2, 0, zc - s2),
		Vector3.new(s2, 0, zc + s2),
		SHAPE.lobby + plate.every - plate.thick,
		Hr - SHAPE.floor,
		plate.every,
		plate.thick,
		plate.proud,
		plate.proud,
		slabLook
	)

	-------------------------------------------------------------------------------------------------------
	-- The exoskeleton: two ribs a face in straight segments along the rhythm's path, corner columns where they meet
	-------------------------------------------------------------------------------------------------------
	local centre = Vector3.new(0, 0, zc)
	local path = rhythm.path
	-- Legs that start near a face's middle stay clear of each other on a narrow core.
	-- A leg standing at a corner (the hourglass) stays within the tower's reach.
	local legWidth = math.min(w * SHAPE.leg, math.max(w, 2 * path[1].a * plane - 1), 2 * (E - plane) - 0.2)
	for _, face in FACES do
		for s, side in { -1, 1 } do
			local function at(knot: Knot): Vector3
				return centre + face.n * plane + face.e * (side * knot.a * plane) + Vector3.yAxis * yAt(knot.t)
			end
			for i = 1, #path - 1 do
				local k0, k1 = path[i], path[i + 1]
				if k0.a >= 0.999 and k1.a >= 0.999 then
					continue -- inside a corner column
				end
				local a, b = at(k0), at(k1)
				local dir = (b - a).Unit
				local leg = i == 1
				local across = if leg
					then legWidth
					elseif i == 2 then math.max(w, math.min(w * SHAPE.taper, (legWidth + w) / 2))
					else w
				local run = across * SHAPE.overlap
				if leg then
					-- The leg's foot: its centre just high enough that its lower corner meets the ground under the
					-- plaza (the segment leans, so its end is tilted).
					local lean = math.abs(dir:Dot(face.e))
					a = Vector3.new(a.X, yFoot + across / 2 * lean * 1.2 + 0.05, a.Z)
				else
					a -= dir * run
				end
				b += dir * run
				-- Neighbouring segments differ a little in depth, so no two faces lie in one plane where they overlap.
				local thick = if i % 2 == 0 then d + 0.08 else d
				rib(m, `Rib{face.name}{s}_{i}`, a, b, across, thick, face.n, ribLook, if leg then "box" else "trim")
			end
			-- The crown's web: a branch rising from the face's middle and fanning out under the roof, crossing the
			-- ribs' sweep, lit at night. Branches stand a little prouder than the ribs, and the two of a face differ in
			-- depth where they meet.
			local web = SHAPE.web
			for i = 1, web.segments do
				local u0, u1 = (i - 1) / web.segments, i / web.segments
				local a = at({ t = web.from + (1 - web.from) * u0, a = web.reach * math.sin(u0 * math.pi / 2) })
				local b = at({ t = web.from + (1 - web.from) * u1, a = web.reach * math.sin(u1 * math.pi / 2) })
				local dir = (b - a).Unit
				local run = w * SHAPE.overlap
				local thick = d + (if side < 0 then 0.16 else 0.24)
				local spec =
					rib(m, `Web{face.name}{s}_{i}`, a - dir * run, b + dir * run, w, thick, face.n, ribLook, "trim")
				Kit.lit(spec, "crown")
			end
		end
	end
	local cw = w * SHAPE.corner
	for j, span in rhythm.corners do
		local y0 = if span[1] <= 0 then yFoot else yAt(span[1]) - 1.5
		local y1 = if span[2] >= 1 then yHead else yAt(span[2]) + 1.5
		for i, corner in { { -1, -1 }, { 1, -1 }, { -1, 1 }, { 1, 1 } } do
			local cx, cz = corner[1] * plane, zc + corner[2] * plane
			Kit.box(
				m,
				`Corner{j}_{i}`,
				Vector3.new(cx - cw / 2, y0, cz - cw / 2),
				Vector3.new(cx + cw / 2, y1, cz + cw / 2),
				ribLook
			)
		end
	end

	-------------------------------------------------------------------------------------------------------
	-- Roof: a white slab over the rib heads with a light line round it, then the crown
	-------------------------------------------------------------------------------------------------------
	local rr = s2 + SHAPE.roofReach
	Kit.box(m, "Roof", Vector3.new(-rr, Hr, zc - rr), Vector3.new(rr, H, zc + rr), ribLook)
	Kit.neonStrip(
		m,
		"RoofRing",
		Vector3.new(-rr - 0.1, Hr + SHAPE.roofRing, zc - rr - 0.1),
		Vector3.new(rr + 0.1, H - SHAPE.roofRing, zc + rr + 0.1),
		"crown",
		pal.rib
	)

	local crown = math.clamp(variant.crown, 1, 3)
	if crown == 1 then
		-- A helipad: a white ring disc round a dark deck with a white H, a light line round its rim, a beacon mast.
		local pad = math.min(SHAPE.padMax, S * SHAPE.pad)
		Kit.disc(m, "Pad", 0, zc, H + 0.15, pad, 0.5, ribLook)
		Kit.disc(m, "PadDeck", 0, zc, H + 0.175, pad - 3, 0.55, Kit.look(pal.pad, Enum.Material.SmoothPlastic))
		Kit.lit(Kit.disc(m, "PadLights", 0, zc, H + 0.075, pad + 0.5, 0.25, ribLook, "detail"), "crown")
		local hx, hy = pad * 0.12, pad * 0.2
		local mark = Kit.look(pal.rib, Enum.Material.SmoothPlastic)
		Kit.detail(m, "PadMark1", Vector3.new(-hx - 0.9, H + 0.45, zc - hy), Vector3.new(-hx, H + 0.52, zc + hy), mark)
		Kit.detail(m, "PadMark2", Vector3.new(hx, H + 0.45, zc - hy), Vector3.new(hx + 0.9, H + 0.52, zc + hy), mark)
		Kit.detail(m, "PadMark3", Vector3.new(-hx, H + 0.45, zc - 0.45), Vector3.new(hx, H + 0.52, zc + 0.45), mark)
		Kit.spire(m, "Mast", s2 + 2, zc + s2 + 2, H, math.min(SHAPE.mast, rise - 2.5), 1.2, METAL, 2, true)
	elseif crown == 2 then
		-- A sky pool under a folded metal canopy on four posts, a glass rail round the roof.
		Kit.pool(m, "SkyPool", Vector3.new(-s2 + 3, 0, zc - s2 + 3), Vector3.new(s2 - 3, 0, zc - 1), H)
		local eaves = H + SHAPE.canopyRise
		for i, corner in { { -1, -1 }, { 1, -1 }, { -1, 1 }, { 1, 1 } } do
			Kit.column(
				m,
				`CanopyPost{i}`,
				corner[1] * (s2 - 1.5),
				zc + corner[2] * (s2 - 1.5),
				H,
				eaves + 0.05,
				1,
				METAL,
				"trim"
			)
		end
		local f0, f1 = Vector3.new(-s2 - 1, eaves, zc - s2 - 1), Vector3.new(s2 + 1, eaves + SHAPE.fold, zc + s2 + 1)
		Kit.wedge(m, "FoldLeft", f0, Vector3.new(0, f1.Y, f1.Z), "right", METAL, "trim")
		Kit.wedge(m, "FoldRight", Vector3.new(0, f0.Y, f0.Z), f1, "left", METAL, "trim")
		local e, t = rr - 0.4, 0.3
		local y0, y1 = H + 0.02, H + KIT.railHeight + 0.2
		Kit.detail(m, "RoofRailFront", Vector3.new(-e, y0, zc - e), Vector3.new(e, y1, zc - e + t), RAIL)
		Kit.detail(m, "RoofRailBack", Vector3.new(-e, y0, zc + e - t), Vector3.new(e, y1, zc + e), RAIL)
		Kit.detail(m, "RoofRailLeft", Vector3.new(-e, y0, zc - e + t), Vector3.new(-e + t, y1, zc + e - t), RAIL)
		Kit.detail(m, "RoofRailRight", Vector3.new(e - t, y0, zc - e + t), Vector3.new(e, y1, zc + e - t), RAIL)
	else
		-- A glass lantern glowing under a white lid with a ring of light, a mast on the lid.
		local q = s2 - 4
		local top = H + SHAPE.lantern
		local lidTop = top + SHAPE.lanternLid
		Kit.glass(m, "Lantern", Vector3.new(-q, H - 0.05, zc - q), Vector3.new(q, top, zc + q), pal.glass, {
			image = City.textures.windowBold,
			u = 4,
			v = SHAPE.lantern,
			lines = pal.rib,
			lit = true,
		})
		Kit.trim(
			m,
			"LanternLid",
			Vector3.new(-q - 1.5, top, zc - q - 1.5),
			Vector3.new(q + 1.5, lidTop, zc + q + 1.5),
			ribLook
		)
		Kit.neonStrip(
			m,
			"LanternRing",
			Vector3.new(-q - 1.6, top + 0.4, zc - q - 1.6),
			Vector3.new(q + 1.6, lidTop - 0.4, zc + q + 1.6),
			"crown",
			pal.rib
		)
		Kit.spire(m, "Mast", 0, zc, lidTop, math.min(18, rise - (lidTop - H) - 2.5), 1.4, METAL, 2, true)
	end

	-------------------------------------------------------------------------------------------------------
	-- Street: an entrance canopy reaching out from the front ribs with the tower's name, planters on the plaza
	-------------------------------------------------------------------------------------------------------
	local ribFront = zc - plane - (d + 0.16) / 2 - 0.05
	local cz0 = math.max(-hd + 0.6, ribFront - SHAPE.canopyDepth)
	local half = math.min(12, S * 0.3)
	if ribFront - cz0 >= 2 then
		local canopyTop = SHAPE.canopyY + SHAPE.canopyThick
		Kit.canopy(m, "Canopy", -half, half, cz0, ribFront, SHAPE.canopyY, SHAPE.canopyThick, ribLook)
		Kit.sign(
			m,
			"Name",
			Vector3.new(-half * 0.75, canopyTop, cz0 + 0.3),
			Vector3.new(half * 0.75, canopyTop + 2.4, cz0 + 0.8),
			Enum.NormalId.Front,
			tag,
			rgb(40, 44, 50),
			pal.rib,
			City.districtLooks.downtown.font
		)
		Kit.neonStrip(
			m,
			"CanopyLed",
			Vector3.new(-half, SHAPE.canopyY - 0.25, cz0 + 0.1),
			Vector3.new(half, SHAPE.canopyY - 0.05, cz0 + 0.7),
			"ledBlue",
			pal.rib
		)
	end
	-- The wash on the plaza in front of the legs: at night it lights the white legs over the entrance.
	Kit.wash(m, "Wash", -S * 0.42, S * 0.42, math.max(-hd + 1, cz0 - 1.5), SHAPE.plaza, rgb(220, 230, 255))
	if hw - 14 > E + 1 then
		for i, side in { -1, 1 } do
			Kit.planter(
				m,
				`Planter{i}`,
				Vector3.new(side * (hw - 13), SHAPE.plaza, -hd + 2),
				Vector3.new(side * (hw - 3), SHAPE.plaza + 1.6, -hd + 5),
				slabLook
			)
		end
	end
end

local archetype: Types.Archetype = { id = "exoskeleton_tower", build = build }
return archetype
