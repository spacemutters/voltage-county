--!strict
-- B10 curved_resort_slab (docs/city/ARCHETYPES.md §6, B10): the big mid-century resort on the bay, the beach's one-off.
-- A long hotel slab bent round a court, its concave side to the road and the bay: six glass facets on an arc of up to
-- a quarter circle, striped by continuous white balcony bands (every floor, or every second floor with white fins at
-- the facet joints) under a white roof slab that runs on round the back as a cornice, between two white end blocks,
-- one of them a taller tower with a glowing glass slot. At the foot of the curve a round glass lobby pavilion under a
-- flat white roof with a blue LED edge; in the court the vast pool (it grows with the court, and glows cyan at night)
-- with a row of cabanas (and umbrellas on a deep court), a wavy porte-cochère in front of the lobby, planters either
-- side of its drive and a freestanding wall punched with round holes. On the roof its name, lit at night (crown 1 a board on posts, crown 2 a
-- glass sky lounge with the name on its roof).
--
-- What makes it itself: a long white slab bent in a curve round its pool, striped by balcony bands.
-- Placement, sizes, heights and its budget: Config/CityArchetypes/curved_resort_slab. The arc is fitted to the site:
-- the widest quarter-circle that fits; on a wide shallow site a flatter, longer arc (down to 70 degrees) that uses the
-- width. On a deep site (a core claim) it grows to the site's width.
-- Variants: palette (1 aqua glass, aqua cabanas and a cyan sign; 2 blue glass, coral cabanas and a pink sign), crown
-- (1 a name board on posts, 2 a glass sky lounge), rhythm (1 bands every floor, 2 bands every second floor and fins
-- at the joints), mirror (which end is the tower, and which side of the lobby the pool is on).
--
-- Previewing (the Studio helper): build it at 120 x 53, 200 x 53 and 200 x 140 (its landmark site is about that deep),
-- look from the road about 150 studs out, from a corner, and from above. Check that the facets meet with no gap on the
-- convex back, that the bands and the roof slabs of neighbouring facets meet cleanly at the joints (no flicker; they
-- sit 0.03 apart in height on purpose), that no glass shows on the roof, that the lobby drum sits half in the slab,
-- that the court things (pool, cabanas, canopy, planters, wall) keep clear of the slab and the drum, and that the
-- holes in the wall read as holes. At night: some facets glow, the lobby glows, its roof edge is blue, the pool glows
-- cyan, the name glows, the wash lights the middle of the curve. Compare with photos of its inspiration (ARCHETYPES.md
-- B10).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local City = require(ReplicatedStorage.Shared.Config.City)
local Kit = require(script.Parent.Parent.Parent.Kit)
local Types = require(script.Parent.Parent.Parent.Types)

local P = City.palettes
local KIT = City.kit
local rgb = Color3.fromRGB

-- The recipe, in studs (angles in degrees).
local SHAPE = {
	ground = 14, -- the first balcony band sits a floor over this
	floorMin = 11,
	minFloors = 8,
	facets = 6, -- glass facets along the curve
	litShare = 0.25, -- each facet glows at night with this chance (one always does)
	arc = { 45, 35, 2.5 }, -- the glass arc's half angle: tried from the first down to the second, in steps
	flatter = 4, -- a flatter arc is taken only if it uses at least this much more of the width
	endShare = 0.65, -- an end block spans this share of a facet's angle
	thick = { 0.36, 16, 24 }, -- the slab's thickness: share of the site's depth, clamped
	front = 4, -- the slab's ends stay this far behind the front line
	back = 1.5, -- its back this far in front of the back line
	side = 1.5,
	-- By rhythm: a deep solid balcony front every floor (the white stripes the curve is known by), or a slab every
	-- second floor between fins.
	band = { thick = { 3.2, 1.4 }, proud = 3, embed = 0.4 },
	roofBand = { thick = 2.6, proud = 3.4, back = 0.4 }, -- the roof slab: past the court face, past the back
	endProud = 0.6, -- the end blocks stand proud of the glass on both faces
	endRise = { 12, 3 }, -- over the roof: the tall end (left unmirrored), the low end
	slot = 3, -- the tall end's glass slot
	fin = { width = 1.2, proud = 2.4 }, -- rhythm 2: fins at the facet joints
	court = 1.2, -- things in the court keep this far inside the slab's inner face
	lobby = { height = 18, share = 0.3, min = 9, roof = 2, over = 2 },
	deck = 0.5,
	-- The pool: its width and depth as shares of the court's radius, clamped (the vast pool grows with the site).
	pool = { gap = 3, width = { 0.55, 10, 44 }, depth = { 0.4, 14, 32 } },
	cabana = { size = 5, height = 4.5, gap = 2, roof = 0.6, count = 4 },
	-- Pool umbrellas in front of the pool: how many, their size, their gap to the water, and how far the row keeps
	-- behind the front line (clear of the planters along it).
	umbrella = { count = 3, size = 6, gap = 2.5, front = 4 },
	garden = { length = 14, depth = 2, height = 1.4, gap = 3 }, -- planters either side of the porte-cochere's drive
	cheese = { length = 22, height = 10, thick = 1.2, holes = 5, hole = 2.8, gap = 3 },
	canopy = { length = 26, depth = 10, low = 11.5, high = 14.5, thick = 0.9, column = 1.1 },
	sign = { height = 6, lift = 4, max = 44 },
	lounge = { width = 30, height = 7, depth = 8, roof = 1, over = 1.5 },
}

-- Glass, accent (cabana roofs, the LED edge by day), the sign's neon and its letters, and the wash.
local PALETTES = {
	{
		glass = rgb(76, 118, 132),
		accent = P.deco.aqua,
		neon = "sign",
		text = rgb(24, 70, 84),
		wash = rgb(140, 220, 255),
	},
	{
		glass = P.glass.blue,
		accent = rgb(238, 128, 108),
		neon = "neonPink",
		text = rgb(120, 30, 70),
		wash = rgb(255, 150, 200),
	},
}

-- One piece of the slab in plan: centred at angle `theta` (from the arc's axis, toward +x), spanning `span`, from
-- radius r0 to r1, its length past the outer polygon by `extra` at each end.
type Piece = { theta: number, span: number, r0: number, r1: number, extra: number }

local function share(size: number, rule: { number }): number
	return math.clamp(size * rule[1], rule[2], rule[3])
end

-- The slab's pieces at an outer radius: the glass facets (with the bands that stand in front of them) and the two end
-- blocks.
local function pieces(phi: number, rOut: number, t: number): { Piece }
	local n = SHAPE.facets
	local delta = 2 * phi / n
	local de = delta * SHAPE.endShare
	local rIn = rOut - t
	local list: { Piece } = {}
	for i = 1, n do
		table.insert(list, {
			theta = -phi + (i - 0.5) * delta,
			span = delta,
			r0 = rIn - SHAPE.roofBand.proud,
			r1 = rOut,
			extra = 0.02,
		})
	end
	for _, s in { -1, 1 } do
		table.insert(list, {
			theta = s * (phi + de / 2),
			span = de,
			r0 = rIn - SHAPE.endProud,
			r1 = rOut + SHAPE.endProud,
			extra = 0.6,
		})
	end
	return list
end

-- The plan's bounds with the arc's centre at the origin: the widest |x|, and the nearest and farthest z.
local function extent(list: { Piece }): (number, number, number)
	local xMax, zMin, zMax = 0, math.huge, -math.huge
	for _, p in list do
		local half = p.r1 * math.tan(p.span / 2) + p.extra
		local s, c = math.sin(p.theta), math.cos(p.theta)
		for _, r in { p.r0, p.r1 } do
			for _, k in { -1, 1 } do
				local x = r * s + k * half * c
				local z = r * c - k * half * s
				xMax = math.max(xMax, math.abs(x))
				zMin, zMax = math.min(zMin, z), math.max(zMax, z)
			end
		end
	end
	return xMax, zMin, zMax
end

-- The arc for a site: its half angle and outer radius. For each half angle, the largest radius that fits the width and
-- the depth (bisection: both grow with the radius); a flatter arc wins only if it uses `flatter` more of the width.
local function fit(width: number, depth: number, t: number): (number, number)
	local limitX = width / 2 - SHAPE.side
	local room = depth - SHAPE.front - SHAPE.back
	local function fits(phi: number, r: number): boolean
		local x, z0, z1 = extent(pieces(phi, r, t))
		return x <= limitX and z1 - z0 <= room
	end
	local bestPhi, bestR, bestX = math.rad(SHAPE.arc[2]), t + 10, -math.huge
	local deg = SHAPE.arc[1]
	while deg >= SHAPE.arc[2] - 1e-6 do
		local phi = math.rad(deg)
		local lo, hi = t + 10, 600
		if fits(phi, lo) then
			for _ = 1, 30 do
				local mid = (lo + hi) / 2
				if fits(phi, mid) then
					lo = mid
				else
					hi = mid
				end
			end
			local x = extent(pieces(phi, lo, t))
			if x > bestX + SHAPE.flatter then
				bestPhi, bestR, bestX = phi, lo, x
			end
		end
		deg -= SHAPE.arc[3]
	end
	return bestPhi, bestR
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

	local white = Kit.look(P.frame.white, Enum.Material.SmoothPlastic)
	local accent = Kit.look(pal.accent, Enum.Material.SmoothPlastic)
	local terrazzo = Kit.look(P.deco.terrazzo, Enum.Material.SmoothPlastic)
	local glassLook = Kit.glassLook(pal.glass, 0.2)

	-- The arc, fitted to the site: its centre sits in front of the court, the slab's back on the back line.
	local t = share(D, SHAPE.thick)
	local phi, rOut = fit(W, D, t)
	local _, _, zMax = extent(pieces(phi, rOut, t))
	local zc = hd - SHAPE.back - zMax
	local rIn = rOut - t
	local n = SHAPE.facets
	local delta = 2 * phi / n
	local de = delta * SHAPE.endShare

	-- A frame on the arc: radius r at angle theta, height y, its local x along the arc and its local z outward.
	local function at(r: number, theta: number, y: number): CFrame
		return CFrame.new(r * math.sin(theta), y, zc + r * math.cos(theta)) * CFrame.Angles(0, theta, 0)
	end

	-------------------------------------------------------------------------------------------------------
	-- The slab: glass facets (their outer corners meet, so the convex back closes), the two end blocks
	-------------------------------------------------------------------------------------------------------
	local always = rng:NextInteger(1, n)
	for i = 1, n do
		local theta = -phi + (i - 0.5) * delta
		local top = H - (i % 2) * 0.03 -- neighbours' roofs never share a plane where they overlap
		local spec = Kit.oriented(
			m,
			`Glass{i}`,
			"block",
			at(rIn + t / 2, theta, (top - KIT.bury) / 2),
			Vector3.new(2 * (rOut * math.tan(delta / 2) + 0.02), top + KIT.bury, t),
			glassLook,
			"box"
		)
		spec.textures = {
			{ face = Enum.NormalId.Front, image = City.textures.windowFine, u = 3, v = f, color = P.frame.white },
			{ face = Enum.NormalId.Back, image = City.textures.windowFine, u = 3, v = f, color = P.frame.white },
		}
		if i == always or rng:NextNumber() < SHAPE.litShare then
			Kit.lit(spec, "window")
		end
	end
	for i, s in { -1, 1 } do
		local theta = s * (phi + de / 2)
		local hE = H + SHAPE.endRise[i]
		local len = 2 * ((rOut + SHAPE.endProud) * math.tan(de / 2) + 0.6)
		Kit.oriented(
			m,
			`End{i}`,
			"block",
			at(rIn + t / 2, theta, (hE - KIT.bury) / 2),
			Vector3.new(len, hE + KIT.bury, t + 2 * SHAPE.endProud),
			white,
			"box"
		)
		do
			-- A glass slot up each end's concave face (the tower's to its top, the low end's to its roof).
			local slotTop = hE - 3
			local slot = Kit.oriented(
				m,
				`Slot{i}`,
				"block",
				at(rIn - SHAPE.endProud + 0.09, theta, (G + slotTop) / 2),
				Vector3.new(SHAPE.slot, slotTop - G, 0.42),
				Kit.glassLook(P.window.dark, 0.2),
				"detail"
			)
			slot.textures = {
				{
					face = Enum.NormalId.Front,
					image = City.textures.windowBold,
					u = SHAPE.slot,
					v = f,
					color = P.frame.white,
				},
			}
			Kit.lit(slot, "window")
		end
	end

	-------------------------------------------------------------------------------------------------------
	-- Balcony bands on the concave face (every floor, or every second with fins at the joints), a deeper band at the
	-- roof
	-------------------------------------------------------------------------------------------------------
	local bd = SHAPE.band
	local every = if rhythm == 2 then 2 else 1
	for i = 1, n do
		local theta = -phi + (i - 0.5) * delta
		local yo = (i % 2) * 0.03
		local len = 2 * (rIn + bd.embed) * math.tan(delta / 2) + 0.05
		for k = 1, up - 1 do
			if k % every == 0 then
				Kit.oriented(
					m,
					`Band{i}x{k}`,
					"block",
					at(rIn + (bd.embed - bd.proud) / 2, theta, G + k * f + yo),
					Vector3.new(len, bd.thick[rhythm], bd.proud + bd.embed),
					white,
					"trim"
				)
			end
		end
		-- The roof: a white slab over the whole facet, the deep band on the court side and a cornice on the back (the
		-- glass's own top never shows). As long as the facet's outer edge, so neighbours overlap at the joints, a few
		-- hundredths apart in height.
		local rb = SHAPE.roofBand
		local r0, r1 = rIn - rb.proud, rOut + rb.back
		Kit.oriented(
			m,
			`Band{i}x{up}`,
			"block",
			at((r0 + r1) / 2, theta, H + 0.06 - rb.thick / 2 + yo),
			Vector3.new(2 * r1 * math.tan(delta / 2) + 0.05, rb.thick, r1 - r0),
			white,
			"trim"
		)
	end
	if rhythm == 2 then
		local fin = SHAPE.fin
		local rv = rIn / math.cos(delta / 2) -- the concave face's corner at a joint
		for j = 1, n - 1 do
			Kit.oriented(
				m,
				`Fin{j}`,
				"block",
				at(rv - fin.proud / 2 + 0.3, -phi + j * delta, (G + H - 0.5) / 2),
				Vector3.new(fin.width, H - 0.5 - G, fin.proud + 0.6),
				white,
				"trim"
			)
		end
	end

	-------------------------------------------------------------------------------------------------------
	-- The name on the roof (crown 1 a board on posts, crown 2 a glass sky lounge with the name on its roof)
	-------------------------------------------------------------------------------------------------------
	local rm = rIn + t / 2 -- the slab's middle line
	local zS = zc + rm
	local sg = SHAPE.sign
	-- As long as the roof stays under it: the middle line sags x^2 / 2rm toward the court away from the centre.
	local sw = math.min(sg.max, 2 * math.sqrt(rm * math.max(1, t - 4)) - 2)
	local names = City.signNames.hotels
	local name = names[rng:NextInteger(1, #names)]
	local font = City.districtLooks.beach.font
	if crown == 1 then
		for k, px in { -sw / 3, sw / 3 } do
			Kit.box(
				m,
				`SignPost{k}`,
				Vector3.new(px - 0.5, H - 0.3, zS - 0.5),
				Vector3.new(px + 0.5, H + sg.lift, zS + 0.5),
				white
			)
		end
		Kit.sign(
			m,
			"Name",
			Vector3.new(-sw / 2, H + sg.lift, zS - 0.35),
			Vector3.new(sw / 2, H + sg.lift + sg.height, zS + 0.35),
			Enum.NormalId.Front,
			name,
			P.frame.white,
			pal.text,
			font,
			pal.neon
		)
	else
		local lg = SHAPE.lounge
		local lw = math.min(lg.width, sw)
		local ld = lg.depth / 2
		Kit.glass(
			m,
			"Lounge",
			Vector3.new(-lw / 2, H - 0.3, zS - ld),
			Vector3.new(lw / 2, H + lg.height, zS + ld),
			pal.glass,
			{
				image = City.textures.windowFine,
				faces = { Enum.NormalId.Front, Enum.NormalId.Back },
				u = 3,
				v = lg.height,
				lines = P.frame.white,
				lit = true,
			}
		)
		local over = lg.over
		Kit.trim(
			m,
			"LoungeRoof",
			Vector3.new(-lw / 2 - over, H + lg.height, zS - ld - over),
			Vector3.new(lw / 2 + over, H + lg.height + lg.roof, zS + ld + over),
			white
		)
		Kit.sign(
			m,
			"Name",
			Vector3.new(-lw / 2 + 1, H + lg.height + lg.roof, zS - ld - over + 0.3),
			Vector3.new(lw / 2 - 1, H + lg.height + lg.roof + 4, zS - ld - over + 0.9),
			Enum.NormalId.Front,
			name,
			P.frame.white,
			pal.text,
			font,
			pal.neon
		)
	end

	-------------------------------------------------------------------------------------------------------
	-- The lobby: a round glass pavilion half in the slab at the middle of the curve, a white roof, a blue LED edge
	-------------------------------------------------------------------------------------------------------
	local lb = SHAPE.lobby
	local rl = math.clamp(rIn * lb.share, lb.min, t - lb.over)
	local zl = zc + rIn
	Kit.lit(Kit.column(m, "Lobby", 0, zl, -KIT.bury, lb.height, 2 * rl, Kit.glassLook(P.window.dark, 0.2)), "window")
	Kit.disc(m, "LobbyRoof", 0, zl, lb.height + lb.roof / 2, 2 * (rl + lb.over), lb.roof, white)
	Kit.lit(Kit.disc(m, "LobbyLed", 0, zl, lb.height - 0.2, 2 * (rl + lb.over) - 0.4, 0.4, accent, "detail"), "ledBlue")
	-- On the lobby roof's front edge, washing the middle of the curve.
	Kit.wash(m, "Wash", -0.35 * rl, 0.35 * rl, zl - rl - 0.4, lb.height + lb.roof + 0.02, pal.wash)

	-------------------------------------------------------------------------------------------------------
	-- The court: a terrazzo deck; the pool and cabanas on one side of the lobby, the holed wall on the other, the
	-- wavy porte-cochère in front. Everything keeps clear of the slab: inside a circle round the arc's centre a little
	-- smaller than its concave face, or in front of that centre (the whole slab stands behind it; on a deep site the
	-- centre is inside the site).
	-------------------------------------------------------------------------------------------------------
	local deck = SHAPE.deck
	Kit.box(m, "Deck", Vector3.new(-hw + 0.3, 0, -hd + 0.3), Vector3.new(hw - 0.3, deck, zl), terrazzo)
	local clear = rIn - SHAPE.endProud - SHAPE.court
	local function inCourt(x: number, z: number): boolean
		local dz = z - zc
		local clearOfSlab = dz <= 0 or x * x + dz * dz <= clear * clear
		return clearOfSlab and math.abs(x) <= hw - 0.5 and z >= -hd + 0.5
	end
	-- The court's back edge at x (where the clear circle is).
	local function courtBack(x: number): number
		return zc + math.sqrt(math.max(0, clear * clear - x * x))
	end

	local pl = SHAPE.pool
	local pw = share(clear, pl.width)
	local px0, px1 = -(rl + pl.gap + pw), -(rl + pl.gap)
	local pz1 = courtBack(px0 - 0.8) - 0.8
	local pz0 = math.max(-hd + 2, pz1 - share(clear, pl.depth))
	if pz1 - pz0 >= 5 and inCourt(px0 - 0.8, pz0 - 0.8) then
		-- The water glows cyan at night.
		local pool = Kit.pool(m, "Pool", Vector3.new(px0, 0, pz0), Vector3.new(px1, 0, pz1), deck)
		Kit.lit(pool[2], "sign")
		local cb = SHAPE.cabana
		for k = 1, cb.count do
			local cx1 = px0 - 1.8 - (k - 1) * (cb.size + cb.gap)
			local cx0 = cx1 - cb.size
			local cz0, cz1 = pz0, pz0 + cb.size
			if not inCourt(cx0 - 0.4, cz1 + 0.4) then
				break
			end
			Kit.box(m, `Cabana{k}`, Vector3.new(cx0, deck, cz0), Vector3.new(cx1, deck + cb.height, cz1), white)
			Kit.trim(
				m,
				`CabanaRoof{k}`,
				Vector3.new(cx0 - 0.4, deck + cb.height, cz0 - 0.4),
				Vector3.new(cx1 + 0.4, deck + cb.height + cb.roof, cz1 + 0.4),
				accent
			)
		end
		-- A row of umbrellas on the deck in front of the pool, where the court leaves room clear of the front planters.
		local ub = SHAPE.umbrella
		local uz = pz0 - ub.gap - ub.size / 2
		if uz - ub.size / 2 >= -hd + ub.front then
			for k = 1, ub.count do
				local ux = px0 + (px1 - px0) * (k - 0.5) / ub.count
				if inCourt(ux - ub.size / 2, uz - ub.size / 2) and inCourt(ux + ub.size / 2, uz - ub.size / 2) then
					Kit.umbrella(
						m,
						`Umbrella{k}`,
						ux,
						uz,
						deck,
						ub.size,
						if k % 2 == 1 then pal.accent else P.frame.white
					)
				end
			end
		end
	end

	local ch = SHAPE.cheese
	local wz0, wz1 = -hd + 1.5, -hd + 1.5 + ch.thick
	local wx0 = rl + ch.gap
	local dzw = wz1 - zc
	local reach = if dzw <= 0 then math.huge else math.sqrt(math.max(0, clear * clear - dzw * dzw))
	local len = math.min(ch.length, reach - wx0 - 1, hw - 1 - wx0)
	if len >= 10 then
		local wx1 = wx0 + len
		Kit.box(m, "CheeseWall", Vector3.new(wx0, -KIT.bury, wz0), Vector3.new(wx1, ch.height, wz1), white)
		local holeLook = Kit.look(P.concrete.dark, Enum.Material.SmoothPlastic)
		for k = 1, ch.holes do
			local hx = wx0 + len * (k - 0.5) / ch.holes
			local hy = ch.height * (if k % 2 == 1 then 0.36 else 0.64)
			Kit.tube(
				m,
				`Hole{k}`,
				Vector3.new(hx, hy, wz0 - 0.06),
				Vector3.new(hx, hy, wz1 + 0.06),
				ch.hole,
				holeLook,
				"detail"
			)
		end
	end

	-- The porte-cochère: three planks rising and falling in a wave, on two columns under its low points.
	local cp = SHAPE.canopy
	local L = math.min(cp.length, 2 * rl)
	local cz0 = -hd + 1
	local cz1 = math.min(cz0 + cp.depth, zl - rl - 1)
	if cz1 - cz0 >= 4 and inCourt(-L / 2, cz1) and inCourt(L / 2, cz1) then
		local zm = (cz0 + cz1) / 2
		local xs = { -L / 2, -L / 6, L / 6, L / 2 }
		local ys = { cp.low, cp.high, cp.low, cp.high }
		for k = 1, 3 do
			local a = Vector3.new(xs[k], ys[k], zm)
			local b = Vector3.new(xs[k + 1], ys[k + 1], zm)
			local u = (b - a).Unit * 0.25 -- a little past each joint, so the planks close
			-- A plank: `thick` through, as wide as the canopy is deep (Kit.strut's width lies level, across the plank).
			Kit.strut(m, `Swoosh{k}`, a - u, b + u, cp.thick, white, "trim", cz1 - cz0)
		end
		for k, i in { 1, 3 } do
			local x = xs[i] + (if i == 1 then 1 else 0)
			Kit.column(m, `CanopyColumn{k}`, x, cz0 + 1.2, -KIT.bury, ys[i] - 0.2, cp.column, white)
		end
	end
	-- Planters along the front either side of the drive, where the court has room.
	local gd = SHAPE.garden
	for i, side in { -1, 1 } do
		local a = side * (L / 2 + gd.gap)
		local b = a + side * gd.length
		local z0, z1 = -hd + 0.8, -hd + 0.8 + gd.depth
		if inCourt(b, z1) and inCourt(a, z1) and math.abs(b) <= hw - 1 then
			Kit.planter(
				m,
				`Garden{i}`,
				Vector3.new(math.min(a, b), deck, z0),
				Vector3.new(math.max(a, b), deck + gd.height, z1),
				white
			)
		end
	end
end

local archetype: Types.Archetype = { id = "curved_resort_slab", build = build }
return archetype
