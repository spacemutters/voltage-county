--!strict
-- T02 exoskeleton_tower (docs/city/ARCHETYPES.md §5, T02): the north peak's landmark. A slender square glass tower held
-- by a white exoskeleton that stands in front of its glass. On every face a white trunk rises from the plaza in the
-- face's middle and splits into two ribs. They bow apart round a tall eye of dark glass, close again near the top and
-- cross, then sweep out to the corners, where they rise into four horns over a concave crown. At the street, every
-- corner stands on a white leg; between leg and trunk a big arch, its haunches cut round, holds a grey louvred screen
-- over the lobby. Above the arches the corners between the ribs carry stacked round balconies that wrap the corner and
-- shrink as the ribs sweep out, so the tower's outline is scalloped at its corners and smooth on its faces.
--
-- What makes it itself: white ribs splitting from a trunk into an eye, crossing, and sweeping out to horned corners.
-- Placement, sizes, heights and its budget: Config/CityArchetypes/exoskeleton_tower. It is a one-off (weight 0): the
-- planner builds it once at its anchor (Config/City landmarks) with a core claim, about 110 deep.
-- Variants: palette (3 glass, rib and screen sets); crown (1 a helipad and a beacon mast, 2 a sky pool under a folded
-- metal canopy, 3 a glass lantern under a lit lid; the horns always frame it); rhythm (1 one long eye crossing near the
-- top, as in the inspiration; 2 two eyes, crossing twice; 3 an open tulip, the ribs bowing out and flaring to the
-- horns without crossing); mirror (symmetric, so it changes nothing visible).
--
-- When previewing: use a deep site (Preview option depth = 110), where the core is 66 wide. On a 53-deep plot the
-- core shrinks to about 31 and the ribs get chunky. Check where two rib segments meet (no gaps or flicker), that the
-- trunk splits cleanly and the two ribs cross at the X, that each round balcony meets its rib at the face and wraps the
-- corner without poking out past the next face, and that the arches' haunches sit in the openings' top corners. From
-- far off each face should read as a white eye over dark glass on legs, with horns on top. At night the ribs' top
-- segments, the horn tips, the roof ring and the lobby glow; the glass stays dark, and the ribs stay in the still model.
-- Seen in Studio 2026-10-26 (docs/images/city/exoskeleton_tower-*.jpg): reads as its inspiration from every distance;
-- the arches' screens had one texture tile their full height, which blurred into a smear (now rows of louvres).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local City = require(ReplicatedStorage.Shared.Config.City)
local Kit = require(script.Parent.Parent.Parent.Kit)
local Types = require(script.Parent.Parent.Parent.Types)

local P = City.palettes
local KIT = City.kit
local rgb = Color3.fromRGB

-- The recipe, in studs (and shares of the height for the base's heights).
local SHAPE = {
	floor = 12,
	lobby = 16, -- the glass lobby under the core
	lobbyInset = 1.5,
	plaza = 0.35, -- the plaza's paving stands this far over the ground (it hides where the legs meet the ground)
	front = 14, -- on a deep site the tower's front stands at most this far behind the plaza's front
	sideRoom = 1.5,
	core = 66, -- the glass core's side, at most
	gap = 1.2, -- between the glass and the ribs' backs
	ribDepth = 3.4,
	-- A rib's width: share of the core's side, clamped. Bold enough to read as a structure from across the city.
	rib = { 0.115, 4.4, 8 },
	-- Everything stays within this of the core's faces: the ribs' gap and depth, then the balconies' reach past the
	-- ribs' plane (balcony.proud), the legs' and horns' halves (at most 6 past the ribs' plane).
	reach = 8.9,
	trunk = 1.9, -- the trunk is this many ribs wide
	leg = 1.45, -- the corner legs: this many ribs square...
	legMax = 12, -- ...at most
	horn = 1.2, -- the horns: this many ribs square
	hornRise = 14, -- the horns' tips (the main roof) stand this far over the core's roof
	hornFoot = 16, -- the horns reach this far under the core's roof
	hornTip = 7, -- each horn's pointed tip
	overlap = 0.35, -- a rib segment runs on past its knots by this many of its widths, closing the joints
	arch = 0.12, -- the arches' crowns, as a share of the height
	shoulder = 0.17, -- the white band over the arches reaches up to here
	split = 0.2, -- where the trunk splits into the two ribs
	haunch = 12, -- an arch's haunch, at most
	-- The round corner balconies: every two floors, deep white bowls (thick, so the stacks read white from afar).
	balcony = { every = 24, thick = 2.2, proud = 6, share = 0.4, minZone = 7 },
	screenBay = 2.2, -- the louvres in the arches' screens: this wide...
	screenRow = 3, -- ...in rows this tall (one tile the screen's full height blurred into a smear)
	roof = 2, -- the roof slab over the core
	roofEdge = 0.8, -- its reach past the core's faces
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

-- A rib's path up a face: t from 0 at the foot to 1 at the top, `a` the rib's distance from the face's middle as a
-- share of the way to the corner (1 is the corner).
type Knot = { t: number, a: number }
-- A face: its outward normal and the way across it (to the right, seen from outside), so that n, up and across make
-- a right-handed frame whose Front faces out.
type Face = { n: Vector3, e: Vector3, name: string }

local FACES: { Face } = {
	{ n = Vector3.new(0, 0, -1), e = Vector3.new(1, 0, 0), name = "F" },
	{ n = Vector3.new(0, 0, 1), e = Vector3.new(-1, 0, 0), name = "B" },
	{ n = Vector3.new(-1, 0, 0), e = Vector3.new(0, 0, -1), name = "L" },
	{ n = Vector3.new(1, 0, 0), e = Vector3.new(0, 0, 1), name = "R" },
}
local CORNERS = { { -1, -1 }, { 1, -1 }, { -1, 1 }, { 1, 1 } }
local OUTER: { Kit.Corner } = { "fl", "fr", "bl", "br" } -- each of CORNERS as the kit names it
local UP = Vector3.yAxis

-- Adds n knots along f (u from 1/n to 1) between t0 and t1: the piece before ends where this one starts.
local function curve(knots: { Knot }, t0: number, t1: number, n: number, f: (number) -> number)
	for i = 1, n do
		local u = i / n
		table.insert(knots, { t = t0 + (t1 - t0) * u, a = f(u) })
	end
end

-- The rhythm's path from the split (aS, the two ribs side by side on the trunk) to the corner (aEnd), crossing at aX.
-- Returns the knots and where the crown's light starts (the top segment).
local function pathFor(rhythm: number, aS: number, aX: number, aEnd: number): { Knot }
	local split = SHAPE.split
	local knots: { Knot } = { { t = split, a = aS } }
	-- An eye: from a0 to a1, bowing out to `peak` half way.
	local function eye(t0: number, t1: number, a0: number, a1: number, peak: number, n: number)
		local amp = peak - (a0 + a1) / 2
		curve(knots, t0, t1, n, function(u: number): number
			return a0 + (a1 - a0) * u + amp * math.sin(math.pi * u)
		end)
	end
	-- Out to the corner from a0, arriving there upright.
	local function out(t0: number, t1: number, a0: number, n: number)
		curve(knots, t0, t1, n, function(u: number): number
			return a0 + (aEnd - a0) * math.sin(math.pi / 2 * u)
		end)
	end
	if rhythm == 2 then
		eye(split, 0.55, aS, aX, 0.55, 4)
		eye(0.55, 0.86, aX, aX, 0.5, 4)
		out(0.86, 1, aX, 2)
	elseif rhythm == 3 then
		local bow = 0.6
		curve(knots, split, 0.6, 4, function(u: number): number
			return aS + (bow - aS) * math.sin(math.pi / 2 * u)
		end)
		curve(knots, 0.6, 1, 4, function(u: number): number
			return bow + (aEnd - bow) * (1 - math.cos(math.pi / 2 * u))
		end)
	else
		-- The inspiration's eye spans about three fifths of the face at its widest.
		eye(split, 0.84, aS, aX, 0.62, 6)
		out(0.84, 1, aX, 3)
	end
	return knots
end

-- The rib's `a` at t (the trunk's below the split, the corner's past the top).
local function aAt(knots: { Knot }, t: number): number
	if t <= knots[1].t then
		return knots[1].a
	end
	for i = 2, #knots do
		local k0, k1 = knots[i - 1], knots[i]
		if t <= k1.t then
			return k0.a + (k1.a - k0.a) * (t - k0.t) / (k1.t - k0.t)
		end
	end
	return knots[#knots].a
end

-- Where the crown zone (the glass above the ribs' last crossing) starts, by rhythm, as a share of the height.
local UPPER = { 0.84, 0.86, 0.8 }

-- Glass, ribs (and the roof, legs, horns, balconies), the arches' louvred screens and the helipad's deck.
local PALETTES = {
	{ glass = rgb(62, 89, 99), rib = P.frame.white, screen = rgb(118, 124, 132), pad = rgb(58, 62, 68) },
	{ glass = P.glass.smoke, rib = P.frame.white, screen = rgb(96, 100, 108), pad = rgb(52, 56, 62) },
	{ glass = P.glass.teal, rib = P.frame.warm, screen = rgb(132, 126, 118), pad = rgb(60, 58, 56) },
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
	local rhythm = math.clamp(variant.rhythm, 1, 3)
	local rng = Kit.rng(m)
	local W, D, H = site.width, site.depth, site.height
	local hw, hd = W / 2, D / 2
	local ribLook = Kit.look(pal.rib, Enum.Material.SmoothPlastic)
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
	local Pl = s2 + SHAPE.gap + d / 2 -- the ribs' centre plane, from the core's centre
	local L = math.min(w * SHAPE.leg, SHAPE.legMax)
	local Lh = w * SHAPE.horn
	local wt = w * SHAPE.trunk
	local Hc = H - SHAPE.hornRise -- the core's roof
	local yFoot, yHead = -KIT.bury, H - 1
	local function yAt(t: number): number
		return yFoot + t * (yHead - yFoot)
	end
	local yArch, yShoulder, ySplit = yAt(SHAPE.arch), yAt(SHAPE.shoulder), yAt(SHAPE.split)
	local yUpper = yAt(UPPER[rhythm])
	local centre = Vector3.new(0, 0, zc)

	-- A box in a face's own terms: u across it (from its middle), y up, v out from the tower's centre.
	local function faceBox(
		name: string,
		face: Face,
		u0: number,
		u1: number,
		y0: number,
		y1: number,
		v0: number,
		v1: number,
		look: Kit.Look,
		kind: Kit.Kind
	): Types.PartSpec
		local at = centre + face.e * ((u0 + u1) / 2) + UP * ((y0 + y1) / 2) + face.n * ((v0 + v1) / 2)
		local size = Vector3.new(math.abs(u1 - u0), math.abs(y1 - y0), math.abs(v1 - v0))
		return Kit.oriented(m, name, "block", CFrame.fromMatrix(at, face.e, UP), size, look, kind)
	end
	-- An arch's haunch: a wedge in the face's plane filling the top corner of an opening at the jamb u (the opening
	-- running toward `toward`, +1 or -1), its square corner at (u, y), `r` along both legs, v0..v1 deep.
	local function haunch(
		name: string,
		face: Face,
		u: number,
		y: number,
		r: number,
		toward: number,
		v0: number,
		v1: number
	)
		local at = centre + face.e * (u + toward * r / 2) + UP * (y - r / 2) + face.n * ((v0 + v1) / 2)
		local ax = UP:Cross(face.e) * toward
		local cf = CFrame.fromMatrix(at, ax, -UP, -face.e * toward)
		Kit.oriented(m, name, "wedge", cf, Vector3.new(math.abs(v1 - v0), r, r), ribLook, "trim")
	end

	Kit.box(
		m,
		"Plaza",
		Vector3.new(-hw + 0.3, -0.6, -hd + 0.3),
		Vector3.new(hw - 0.3, SHAPE.plaza, hd - 0.3),
		Kit.look(P.deco.terrazzo, Enum.Material.SmoothPlastic)
	)

	-------------------------------------------------------------------------------------------------------
	-- Core: the lobby, the glass of the eyes, the glass of the crown zone, the roof
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
	Kit.glass(m, "Core", Vector3.new(-s2, SHAPE.lobby, zc - s2), Vector3.new(s2, yUpper, zc + s2), pal.glass, {
		image = City.textures.windowFine,
		u = S / math.max(1, math.round(S / 5.5)),
		v = SHAPE.floor,
		lines = pal.glass:Lerp(pal.rib, 0.35),
	})
	-- The crown zone: the same glass behind close white slats (two lines a floor), the amenity floors.
	local upperTop = Hc - SHAPE.roof + 0.3
	Kit.glass(
		m,
		"CoreUpper",
		Vector3.new(-s2 + 0.05, yUpper - 0.05, zc - s2 + 0.05),
		Vector3.new(s2 - 0.05, upperTop, zc + s2 - 0.05),
		pal.glass,
		{ image = City.textures.slabLine, u = S, v = SHAPE.floor / 2, lines = pal.rib }
	)
	local re = s2 + SHAPE.roofEdge
	Kit.box(m, "Roof", Vector3.new(-re, Hc - SHAPE.roof, zc - re), Vector3.new(re, Hc, zc + re), ribLook)
	Kit.neonStrip(
		m,
		"RoofRing",
		Vector3.new(-re - 0.1, Hc - 1.5, zc - re - 0.1),
		Vector3.new(re + 0.1, Hc - 0.5, zc + re + 0.1),
		"crown",
		pal.rib
	)

	-------------------------------------------------------------------------------------------------------
	-- The exoskeleton: per face a trunk, two ribs along the rhythm's path, the arches' band, haunches and screens
	-------------------------------------------------------------------------------------------------------
	local aS = (wt - w) / 2 / Pl -- the two ribs side by side on the trunk
	local aX = 0.4 * w / Pl -- crossing: the two ribs overlap by a fifth of their width
	local aEnd = 1 - w / 2 / Pl -- at the corner: the rib's outer edge on the corner line
	local path = pathFor(rhythm, aS, aX, aEnd)
	local screenLook = Kit.look(pal.screen, Enum.Material.Metal)
	local openIn, openOut = wt / 2, Pl - L / 2 -- an arch's opening, across the face from its middle
	local rOut = math.max(1, math.min(SHAPE.haunch, (openOut - openIn) * 0.55, (yArch - SHAPE.lobby) * 0.5))
	local rIn = rOut * 0.5
	for _, face in FACES do
		local fn = face.name
		-- The trunk: from under the plaza up past the split, a hair prouder than the ribs and the band.
		faceBox(
			`Trunk{fn}`,
			face,
			-wt / 2,
			wt / 2,
			yFoot,
			ySplit + w,
			Pl - d / 2 - 0.05,
			Pl + d / 2 + 0.05,
			ribLook,
			"box"
		)
		-- The band over the arches, from leg to leg.
		faceBox(
			`Band{fn}`,
			face,
			-(openOut + 0.4),
			openOut + 0.4,
			yArch,
			yShoulder,
			Pl - d / 2,
			Pl + d / 2,
			ribLook,
			"trim"
		)
		-- A louvred screen in front of the glass over the lobby, from leg to leg behind the trunk: the two arches'
		-- openings show it.
		local screen = faceBox(
			`Screen{fn}`,
			face,
			-openOut,
			openOut,
			SHAPE.lobby + 0.5,
			yArch + 0.5,
			s2 + 0.1,
			s2 + 0.7,
			screenLook,
			"trim"
		)
		screen.textures = {
			{
				face = Enum.NormalId.Front,
				image = City.textures.windowBold,
				u = SHAPE.screenBay,
				v = SHAPE.screenRow,
				color = pal.rib,
			},
		}
		for j, toward in { -1, 1 } do
			-- The opening between trunk and leg: haunches cut round its top corners, so it reads as an arch.
			local u0, u1 = toward * openIn, toward * openOut
			haunch(`Haunch{fn}{j}Out`, face, u1, yArch, rOut, -toward, Pl - d / 2, Pl + d / 2)
			haunch(`Haunch{fn}{j}In`, face, u0, yArch, rIn, toward, Pl - d / 2, Pl + d / 2)
		end
		-- The two ribs, in straight segments along the path.
		for s, side in { -1, 1 } do
			local function at(knot: Knot): Vector3
				return centre + face.n * Pl + face.e * (side * knot.a * Pl) + UP * yAt(knot.t)
			end
			for i = 1, #path - 1 do
				local a, b = at(path[i]), at(path[i + 1])
				local dir = (b - a).Unit
				local run = w * SHAPE.overlap
				local last = i == #path - 1
				a -= dir * run
				if not last then
					b += dir * run
				end
				-- Neighbouring segments, and the two ribs where they cross, differ a little in depth, so no two faces lie
				-- in one plane where they overlap.
				local thick = d + (if i % 2 == 0 then 0.08 else 0) + (if side > 0 then 0.04 else 0)
				rib(m, `Rib{fn}{s}_{i}`, a, b, w, thick, face.n, ribLook, "trim")
				if last then
					-- A light line along the top segment's face: the web glows up into the horns at night.
					local lift = face.n * (thick / 2 + 0.1)
					Kit.lit(
						rib(m, `RibLight{fn}{s}`, a + lift, b + lift, w * 0.4, 0.3, face.n, ribLook, "detail"),
						"crown"
					)
				end
			end
		end
	end

	-------------------------------------------------------------------------------------------------------
	-- Corners: the legs under the arches' band, the round balconies over it, the horns at the top
	-------------------------------------------------------------------------------------------------------
	for i, corner in CORNERS do
		local cx, cz = corner[1] * Pl, zc + corner[2] * Pl
		Kit.box(
			m,
			`Leg{i}`,
			Vector3.new(cx - L / 2, yFoot, cz - L / 2),
			Vector3.new(cx + L / 2, yShoulder + 0.5, cz + L / 2),
			ribLook
		)
		-- The horn: a post up to its tip, the tip a corner wedge whose peak stands over the tower's outer corner, so
		-- each horn is a point leaning out; a ring of light under the tip.
		local tip = H - SHAPE.hornTip
		Kit.box(
			m,
			`Horn{i}`,
			Vector3.new(cx - Lh / 2, Hc - SHAPE.hornFoot, cz - Lh / 2),
			Vector3.new(cx + Lh / 2, tip + 0.02, cz + Lh / 2),
			ribLook
		)
		Kit.cornerWedge(
			m,
			`HornTip{i}`,
			Vector3.new(cx - Lh / 2, tip, cz - Lh / 2),
			Vector3.new(cx + Lh / 2, H, cz + Lh / 2),
			OUTER[i],
			ribLook
		)
		Kit.neonStrip(
			m,
			`HornLight{i}`,
			Vector3.new(cx - Lh / 2 - 0.1, tip - 1.6, cz - Lh / 2 - 0.1),
			Vector3.new(cx + Lh / 2 + 0.1, tip - 0.4, cz + Lh / 2 + 0.1),
			"crown",
			pal.rib
		)
	end
	-- A balcony is a disc round a point inside the corner: it reaches the rib along both faces and stands `q` past the
	-- ribs' plane at most, rounding the corner, so the stack follows the ribs' sweep as a scalloped edge. Where the eye
	-- is widest the corners are too narrow for one, and the stack skips that level.
	local bal = SHAPE.balcony
	local level = 0
	local y = yShoulder + bal.every / 2
	while y < Hc - SHAPE.hornFoot do
		local zone = Pl * (1 - aAt(path, (y - yFoot) / (yHead - yFoot))) - w / 2
		if zone >= bal.minZone then
			level += 1
			local q = math.min(bal.proud, zone * bal.share)
			local c = (zone + q) - math.sqrt(2 * q * (zone + q))
			local r = c + q
			for i, corner in CORNERS do
				local bx, bz = corner[1] * (Pl - c), zc + corner[2] * (Pl - c)
				Kit.disc(m, `Balcony{level}_{i}`, bx, bz, y, 2 * r, bal.thick, ribLook, "trim")
			end
		end
		y += bal.every
	end

	-------------------------------------------------------------------------------------------------------
	-- Crown, on the core's roof between the horns
	-------------------------------------------------------------------------------------------------------
	local rise = site.maxHeight - Hc -- what may stand on the core's roof
	local crown = math.clamp(variant.crown, 1, 3)
	if crown == 1 then
		-- A helipad: a white ring disc round a dark deck with a white H, a light line round its rim, a beacon mast.
		local pad = math.min(SHAPE.padMax, S * SHAPE.pad)
		Kit.disc(m, "Pad", 0, zc, Hc + 0.15, pad, 0.5, ribLook)
		Kit.disc(m, "PadDeck", 0, zc, Hc + 0.175, pad - 3, 0.55, Kit.look(pal.pad, Enum.Material.SmoothPlastic))
		Kit.lit(Kit.disc(m, "PadLights", 0, zc, Hc + 0.075, pad + 0.5, 0.25, ribLook, "detail"), "crown")
		local hx, hy = pad * 0.12, pad * 0.2
		local mark = Kit.look(pal.rib, Enum.Material.SmoothPlastic)
		Kit.detail(
			m,
			"PadMark1",
			Vector3.new(-hx - 0.9, Hc + 0.45, zc - hy),
			Vector3.new(-hx, Hc + 0.52, zc + hy),
			mark
		)
		Kit.detail(m, "PadMark2", Vector3.new(hx, Hc + 0.45, zc - hy), Vector3.new(hx + 0.9, Hc + 0.52, zc + hy), mark)
		Kit.detail(m, "PadMark3", Vector3.new(-hx, Hc + 0.45, zc - 0.45), Vector3.new(hx, Hc + 0.52, zc + 0.45), mark)
		local mx = s2 - 3
		Kit.spire(m, "Mast", mx, zc + mx, Hc, math.min(SHAPE.mast, rise - 2.5), 1.2, METAL, 2, true)
	elseif crown == 2 then
		-- A sky pool under a folded metal canopy on four posts, between the horns.
		Kit.pool(m, "SkyPool", Vector3.new(-s2 + 3, 0, zc - s2 + 3), Vector3.new(s2 - 3, 0, zc - 1), Hc)
		local eaves = Hc + SHAPE.canopyRise
		for i, corner in CORNERS do
			Kit.column(
				m,
				`CanopyPost{i}`,
				corner[1] * (s2 - 1.5),
				zc + corner[2] * (s2 - 1.5),
				Hc,
				eaves + 0.05,
				1,
				METAL,
				"trim"
			)
		end
		local f0, f1 =
			Vector3.new(-s2 + 0.5, eaves, zc - s2 + 0.5), Vector3.new(s2 - 0.5, eaves + SHAPE.fold, zc + s2 - 0.5)
		Kit.wedge(m, "FoldLeft", f0, Vector3.new(0, f1.Y, f1.Z), "right", METAL, "trim")
		Kit.wedge(m, "FoldRight", Vector3.new(0, f0.Y, f0.Z), f1, "left", METAL, "trim")
	else
		-- A glass lantern glowing under a white lid with a ring of light, a mast on the lid.
		local q = s2 - 4
		local top = Hc + SHAPE.lantern
		local lidTop = top + SHAPE.lanternLid
		Kit.glass(m, "Lantern", Vector3.new(-q, Hc - 0.05, zc - q), Vector3.new(q, top, zc + q), pal.glass, {
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
		Kit.spire(m, "Mast", 0, zc, lidTop, math.min(18, rise - (lidTop - Hc) - 2.5), 1.4, METAL, 2, true)
	end
	-- A glass rail round the roof.
	local e, t = s2 + 0.4, 0.3
	local y0, y1 = Hc + 0.02, Hc + KIT.railHeight + 0.2
	Kit.detail(m, "RoofRailFront", Vector3.new(-e, y0, zc - e), Vector3.new(e, y1, zc - e + t), RAIL)
	Kit.detail(m, "RoofRailBack", Vector3.new(-e, y0, zc + e - t), Vector3.new(e, y1, zc + e), RAIL)
	Kit.detail(m, "RoofRailLeft", Vector3.new(-e, y0, zc - e + t), Vector3.new(-e + t, y1, zc + e - t), RAIL)
	Kit.detail(m, "RoofRailRight", Vector3.new(e - t, y0, zc - e + t), Vector3.new(e, y1, zc + e - t), RAIL)

	-------------------------------------------------------------------------------------------------------
	-- Street: an entrance canopy through the front trunk with the tower's name, a wash, planters on the plaza
	-------------------------------------------------------------------------------------------------------
	local front = zc - Pl - d / 2 - 0.1
	local cz0 = math.max(-hd + 0.6, front - SHAPE.canopyDepth)
	local half = math.min(12, S * 0.3)
	if front - cz0 >= 2 then
		local canopyTop = SHAPE.canopyY + SHAPE.canopyThick
		Kit.canopy(m, "Canopy", -half, half, cz0, front + 1, SHAPE.canopyY, SHAPE.canopyThick, ribLook)
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
	-- The wash on the plaza in front of the legs: at night it lights the trunk and the arches over the entrance.
	Kit.wash(m, "Wash", -S * 0.42, S * 0.42, math.max(-hd + 1, cz0 - 1.5), SHAPE.plaza, rgb(220, 230, 255))
	if hw - 14 > E + 1 then
		for i, side in { -1, 1 } do
			Kit.planter(
				m,
				`Planter{i}`,
				Vector3.new(side * (hw - 13), SHAPE.plaza, -hd + 2),
				Vector3.new(side * (hw - 3), SHAPE.plaza + 1.6, -hd + 5),
				Kit.look(pal.rib, Enum.Material.SmoothPlastic)
			)
		end
	end
end

local archetype: Types.Archetype = { id = "exoskeleton_tower", build = build }
return archetype
