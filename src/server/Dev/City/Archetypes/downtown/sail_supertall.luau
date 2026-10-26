--!strict
-- T04 sail_supertall (docs/city/ARCHETYPES.md §5, T04): the bay row's sail, a residential supertall shaped like a boat's
-- sail. In plan it is a teardrop: a round glass bow at its leading end, two convex faces (the front, toward the water
-- when the planner turns it to the lake, fuller than the back) tapering to a slim white spine at the tail. White
-- balcony bands wrap it every two or three floors, round the bow and along both faces, over glass ruled with a white
-- line every floor, so the whole tower reads pale and striped. Three quarters of the way up the bow stops at a dark
-- lip, the sky lounge's deck, and the top of the sail, the head, rises behind it with its leading edge raked forward:
-- each floor of the head reaches further out over the lip, its white soffit showing under a dark raked edge. A short
-- garage stands behind the sail. At night a light line runs up the bow, the lip and the lobby band glow blue, and every
-- fourth row of bands is a pale ring of light, so the sail keeps its stripes after dark.
--
-- What makes it itself: a pale banded teardrop of glass whose head leans out over a dark lip, like a sail's head.
-- Placement, sizes, heights and its budget: Config/CityArchetypes/sail_supertall. It is a one-off (weight 0): the
-- planner builds it once on the bay row (Config/City landmarks), turned to face the lake, with a core claim.
-- Variants: palette (3: front and back glass, white or warm white, the lip's dark); crown (1 the tail spine runs on
-- into a beacon mast, 2 the raked edges drawn in light with a beacon at the head's tip, 3 a raked white blade on the
-- roof); rhythm (1 a band every two floors, slim; 2 every three floors, thicker and deeper); mirror (which way the bow
-- points).
--
-- No CSG: the faces are solid glass facets (8 on the front, 4 behind), each reaching back to the sail's middle line, so
-- the cut under the head and every roof read solid; the bow is a glass cylinder. Each band is straight strips, one per
-- two facets, embedded in the glass, and a disc round the bow.
-- When previewing: use a deep site (Preview option depth = 110). From the front at mid distance, check that the
-- facets read as one smooth curve, the bands as continuous lines round the bow, and that the head's soffit reads as
-- one smooth slope under the dark raked edge (no steps or flicker between facets). From the side, check the head
-- leans out over the lip. At the tail, check that no strip pokes out past the spine. At night, look for the bow's
-- light line, the lip, the lobby band, the rings of light and the crown.
-- Seen in Studio 2026-10-26 (docs/images/city/sail_supertall-*.jpg): the per-facet soffits left dark slivers under the
-- head (now one soffit plane of wedges along the sail's axis), and the sail read blue (paler glass and bolder bands in
-- palette 1).

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
	lobby = 16, -- the lobby band's height
	length = { 0.84, 70, 112 }, -- the sail's length along the road: share of the site's width, clamped
	tipRoom = 7.2, -- from either end to the site's side, at least (the lip and the bands stand out past the ends)
	thick = 0.44, -- the sail's thickness (the bow's diameter), as a share of its length, at most
	front = 8, -- the bow stands at least this far behind the front line (the lip reaches 6 out in front of it)...
	deep = 16, -- ...and on a deep site at most this much further back
	backRoom = 7, -- between the sail and the site's back (the lip and bands)
	facets = 8, -- solid glass facets on the front face, closer toward the tail where it turns
	backFacets = 4,
	bay = 7, -- a window bay
	spine = 5.4, -- the white spine at the tail: diameter
	lip = { share = 0.8, thick = 2.6, proud = 4, led = 0.5 }, -- the bow stops at the lip: its height, a share of H
	-- The head's raked leading edge: at the lip it meets the faces this share of the length from the bow's tip, and at
	-- the roof this share (never past the bow's centre), so each floor of the head reaches further out. 2026-10-26
	-- roast point 8: at 0.56 the head overhung half the sail and read torn off, a white sliver over a ledge; now it
	-- leans out a little over a shorter head, its underside glass, so the head reads as the sail running on.
	head = { foot = 0.32, top = 0.16 },
	-- By rhythm. Bold enough that the sail reads pale and striped from across the bay (1.4 thick read as hairlines).
	bands = {
		{ every = 24, thick = 2, proud = 3.5, embed = 1.5 },
		{ every = 36, thick = 2.8, proud = 4.2, embed = 1.5 },
	},
	-- The head's underside and core: this many soffit wedges along the sail, each with a block over it to the roof, this
	-- far inside the faces at its thinner end, behind glass skins this thick.
	soffit = { segments = 4, inset = 0.3, skin = 3 },
	joint = 0.6, -- strips run on this far past their ends, closing the joints
	glowEvery = 4, -- every this many rows of bands is a ring of light at night
	headRoom = 6, -- the bands stay this far under the lip and the roof
	lobbyBand = { thick = 1.8, proud = 5 },
	led = 0.5, -- the light strips under the lobby band
	rail = 3.4,
	edge = { thick = 1.4, proud = 0.5 }, -- the dark raked edges along the head's leading edge (their centre line out)
	line = 20, -- the light line up the bow starts this high
	levels = 4, -- the garage behind the sail
	level = 10,
	garageInset = 1.5,
	garageGap = 2, -- the garage's front behind the sail's middle line
	garageMin = 8, -- the garage needs this much depth
	slot = 3.2,
	bandProud = 0.5,
	capThick = 1.6,
	plaza = 0.35,
	mast = 26, -- crown 1
	-- Crown 3: the blade's height at its lead, its thickness, its ends in from the head's lead and the spine, and its
	-- light stopping this far short of its tail (where the blade is too low to carry it).
	blade = { tall = 14, thick = 1.2, inset = 4, light = 8 },
}

-- Front glass, back glass, the whites (spine, bands, soffits), the lip and raked edges' dark, the garage. The first
-- is the inspiration's: pale silver glass behind white balconies, so the sail reads nearly white.
local PALETTES = {
	{
		-- Paler than the city's silver glass: with it the sail still read blue in the Studio preview.
		front = rgb(150, 174, 188),
		back = rgb(128, 156, 172),
		white = P.frame.white,
		dark = rgb(40, 44, 50),
		garage = P.concrete.pale,
	},
	{
		front = P.glass.blue,
		back = P.glass.navy,
		white = P.frame.white,
		dark = rgb(30, 34, 40),
		garage = P.concrete.pale,
	},
	{
		front = P.glass.teal,
		back = P.glass.silver,
		white = P.frame.warm,
		dark = rgb(56, 52, 48),
		garage = P.concrete.warm,
	},
}

-- A band strip: a straight run along a chord of two facets, standing out of the glass.
type Strip = { mid: Vector3, along: Vector3, out: Vector3, len: number, x0: number, x1: number }

local RAIL = Kit.look(rgb(214, 236, 242), Enum.Material.Glass, 0.1, KIT.railTransparency)
local METAL = Kit.look(rgb(200, 204, 210), Enum.Material.Metal)
local BEACON = Kit.look(rgb(150, 40, 36), Enum.Material.SmoothPlastic)
local UP = Vector3.yAxis

-- A chord p..q of a face, walked with the outside on its left (the front left to right, the back right to left): its
-- length, its direction, and the way in (to its right).
local function chordOf(p: Vector3, q: Vector3): (number, Vector3, Vector3)
	local chord = q - p
	local len = chord.Magnitude
	local along = chord / len
	return len, along, Vector3.new(-along.Z, 0, along.X)
end

-- How deep a solid facet on chord p..q must reach (along `inward`) to pass the line z = toZ everywhere.
local function depthTo(p: Vector3, q: Vector3, inward: Vector3, toZ: number): number
	return math.max(1, (toZ - p.Z) / inward.Z, (toZ - q.Z) / inward.Z)
end

local function build(m: Types.Model)
	local site = m.site
	local variant = site.variant
	local pal = PALETTES[math.clamp(variant.palette, 1, #PALETTES)]
	local band = SHAPE.bands[math.clamp(variant.rhythm, 1, #SHAPE.bands)]
	local crown = math.clamp(variant.crown, 1, 3)
	local rng = Kit.rng(m)
	local W, D, H = site.width, site.depth, site.height
	local hw, hd = W / 2, D / 2
	local rise = site.maxHeight - H
	local white = Kit.look(pal.white, Enum.Material.SmoothPlastic)
	local darkLook = Kit.look(pal.dark, Enum.Material.SmoothPlastic)
	local concreteDark = Kit.look(P.concrete.dark, Enum.Material.SmoothPlastic)
	local tag = City.signNames.towers[rng:NextInteger(1, #City.signNames.towers)]
	local yFoot = -KIT.bury

	-------------------------------------------------------------------------------------------------------
	-- The plan: a teardrop from the bow (a circle at xb) to the tail (the spine at xt), the front fuller
	-------------------------------------------------------------------------------------------------------
	local L = math.min(math.clamp(W * SHAPE.length[1], SHAPE.length[2], SHAPE.length[3]), W - 2 * SHAPE.tipRoom)
	local room = D - SHAPE.front - SHAPE.backRoom
	local T = math.min(L * SHAPE.thick, room)
	local rb = T / 2 -- the bow's radius
	local rt = SHAPE.spine / 2 -- the tail's
	local z0 = -hd + SHAPE.front + rb + math.clamp(room - T, 0, SHAPE.deep) -- the middle line, bow to tail
	local xb, xt = -L / 2 + rb, L / 2 - rt
	local span = xt - xb
	local function frontAt(u: number): Vector3
		return Vector3.new(xb + u * span, 0, z0 - (rt + (rb - rt) * math.sqrt(math.max(0, 1 - u * u))))
	end
	local function backAt(u: number): Vector3
		return Vector3.new(xb + u * span, 0, z0 + (rt + (rb - rt) * (1 - u * u)))
	end
	-- The front's points close up toward the tail, where it turns; the back's are even. The back is walked from the
	-- tail to the bow, so both faces have the outside on the left.
	local N, M = SHAPE.facets, SHAPE.backFacets
	local front: { Vector3 } = {}
	for i = 0, N do
		table.insert(front, frontAt(math.sin(math.pi / 2 * i / N)))
	end
	local back: { Vector3 } = {}
	for j = M, 0, -1 do
		table.insert(back, backAt(j / M))
	end

	-- Heights: the lip, and the head's raked cut from (xh0 at the lip) to (xh1 at the roof).
	local yLip = math.floor((H * SHAPE.lip.share) / SHAPE.floor) * SHAPE.floor
	local xh0 = -L / 2 + L * SHAPE.head.foot
	local xh1 = math.max(-L / 2 + L * SHAPE.head.top, xb + 1)
	local function cutY(x: number): number
		return math.clamp(yLip + (H - yLip) * (xh0 - x) / (xh0 - xh1), yLip, H)
	end
	-- The head stands where x is past the cut at that height.
	local function cutX(y: number): number
		return xh0 + (xh1 - xh0) * (y - yLip) / (H - yLip)
	end

	-------------------------------------------------------------------------------------------------------
	-- The skin: solid glass facets from the ground; under the head's cut, a facet stops at the lip and its head part
	-- stands on the white soffit, wedges along the sail that follow the rake
	-------------------------------------------------------------------------------------------------------
	local frontLines = pal.white
	local function facetPart(
		name: string,
		p: Vector3,
		q: Vector3,
		toZ: number,
		lo: number,
		hi: number,
		color: Color3,
		textured: boolean,
		thick: number?
	)
		local len, along, inward = chordOf(p, q)
		local depth = thick or depthTo(p, q, inward, toZ)
		local at = (p + q) / 2 + inward * (depth / 2) + UP * ((lo + hi) / 2)
		local spec = Kit.oriented(
			m,
			name,
			"block",
			CFrame.fromMatrix(at, along, UP),
			Vector3.new(len, hi - lo, depth),
			Kit.glassLook(color, 0.18),
			"box"
		)
		if textured then
			spec.textures = {
				{
					face = Enum.NormalId.Front,
					image = City.textures.windowFine,
					u = len / math.max(1, math.round(len / SHAPE.bay)),
					v = SHAPE.floor,
					color = frontLines,
				},
			}
		end
	end
	-- One face's facets. `toZ` is the middle line, a stud past it.
	local function skin(face: string, points: { Vector3 }, toZ: number, color: Color3)
		for i = 1, #points - 1 do
			local p, q = points[i], points[i + 1]
			local x0, x1 = math.min(p.X, q.X), math.max(p.X, q.X)
			local name = `{face}{i}`
			if x0 >= xh0 then
				-- Wholly behind the cut: one facet from the ground to the roof.
				facetPart(name, p, q, toZ, yFoot, H, color, true)
				continue
			end
			facetPart(name, p, q, toZ, yFoot, yLip, color, true)
			if x1 <= xh1 then
				continue -- wholly in front of the cut: it stops at the lip
			end
			-- The head part: the chord clipped to x >= xh1, a glass skin (the head's core fills behind it) standing on
			-- the cut where its highest corner meets it. A skin reaching the middle line, the first cut, ran inward
			-- toward the bow, where the cut is higher, and hung glass under the soffit.
			local function clip(a: Vector3, b: Vector3): Vector3
				if a.X >= xh1 then
					return a
				end
				return a + (b - a) * ((xh1 - a.X) / (b.X - a.X))
			end
			local hp, hq = clip(p, q), clip(q, p)
			local _, _, inward = chordOf(hp, hq)
			local d = SHAPE.soffit.skin
			local top = cutY(math.min(hp.X, hq.X, hp.X + inward.X * d, hq.X + inward.X * d))
			if H - top > 0.5 then
				facetPart(`{name}Head`, hp, hq, toZ, top, H, color, true, d)
			end
		end
	end
	skin("Front", front, z0 + 1, pal.front)
	skin("Back", back, z0 - 1, pal.back)
	-- The soffit under the head: wedges hung upside down along the sail's axis, their slopes exactly the raked cut (the
	-- cut is level across the sail), so they make one smooth plane. Each spans the sail's thickness at its thinner end,
	-- a hair in, so its sides stay inside the faces. (Wedges along each facet's chord, the first cut, sloped along the
	-- chord, not the axis, and left dark slivers between them.)
	local n = SHAPE.soffit.segments
	-- The underside in the front glass, so the head reads as the sail leaning out, not a white slab over a ledge.
	local soffitLook = Kit.glassLook(pal.front)
	for i = 1, n do
		local xa = xh1 + (xh0 - xh1) * (i - 1) / n -- the higher end
		local xz = xh1 + (xh0 - xh1) * i / n -- the lower end, nearer the tail and thinner
		local u = math.clamp((xz - xb) / span, 0, 1)
		local zf, zk = frontAt(u).Z + SHAPE.soffit.inset, backAt(u).Z - SHAPE.soffit.inset
		local lo, hi = cutY(xz), cutY(xa)
		-- A WedgePart hung upside down: its flat face on top, its upright face at the lower end (its local +Z, here +x).
		Kit.oriented(
			m,
			`Soffit{i}`,
			"wedge",
			CFrame.fromMatrix(
				Vector3.new((xa + xz) / 2, (lo + hi) / 2, (zf + zk) / 2),
				Vector3.zAxis,
				-UP,
				Vector3.xAxis
			),
			Vector3.new(zk - zf, hi - lo, xz - xa),
			soffitLook,
			"trim"
		)
		-- The head's core over it, up to a hair under the roof (the skins' tops are the roof's edge).
		if H - hi > 0.5 then
			Kit.trim(m, `HeadCore{i}`, Vector3.new(xa, hi, zf), Vector3.new(xz, H - 0.05, zk), white)
		end
	end
	-- Behind the skins of the facets that straddle the cut's foot, the core runs on from the lip to the roof as far as
	-- they reach (past them, the facets are solid to the middle line).
	local xEnd = xh0
	for _, points in { front, back } do
		for i = 1, #points - 1 do
			local a, b = points[i].X, points[i + 1].X
			if math.min(a, b) < xh0 and math.max(a, b) > xh0 then
				xEnd = math.max(xEnd, a, b)
			end
		end
	end
	if xEnd - xh0 > 0.5 then
		local u = math.clamp((xEnd - xb) / span, 0, 1)
		Kit.trim(
			m,
			"HeadCoreTail",
			Vector3.new(xh0, yLip, frontAt(u).Z + SHAPE.soffit.inset),
			Vector3.new(xEnd, H - 0.05, backAt(u).Z - SHAPE.soffit.inset),
			white
		)
	end
	-- The bow: a glass drum up to the lip.
	Kit.column(m, "Bow", xb, z0, yFoot, yLip, 2 * rb, Kit.glassLook(pal.front, 0.18))
	-- The spine at the tail, to the roof (crown 1 runs it on as a mast).
	Kit.column(m, "Spine", xt, z0, yFoot, H + (if crown == 1 then 0 else 1.5), SHAPE.spine, white)

	-------------------------------------------------------------------------------------------------------
	-- Bands: straight strips, one per two facets, stood out of the glass; a disc round the bow
	-------------------------------------------------------------------------------------------------------
	local strips: { Strip } = {}
	local function addStrips(points: { Vector3 })
		local count = #points - 1
		local j = 1
		while j <= count do
			local k = math.min(j + 1, count)
			local p, q = points[j], points[k + 1]
			local len, along, inward = chordOf(p, q)
			table.insert(strips, {
				mid = (p + q) / 2,
				along = along,
				out = -inward,
				len = len,
				x0 = math.min(p.X, q.X),
				x1 = math.max(p.X, q.X),
			})
			j = k + 1
		end
	end
	addStrips(front)
	addStrips(back)

	-- A row of bands at y. `lit` adds a light line under the bow's disc; `glow` makes the bands themselves a ring of
	-- light at night (white by day, like the rest).
	local function bandRow(
		name: string,
		y: number,
		thick: number,
		proud: number,
		bow: boolean,
		lit: string?,
		glow: string?
	)
		for j, s in strips do
			local mid, len = s.mid, s.len + 2 * SHAPE.joint
			local xc = if y > yLip then cutX(y) + 1 else -math.huge
			if s.x1 <= xc + 2 then
				continue -- wholly in front of the head's cut at this height
			elseif s.x0 < xc then
				-- Cut short at the head's raked edge: the strip keeps its line and its joint at the far end only.
				local a, b = s.mid - s.along * (s.len / 2), s.mid + s.along * (s.len / 2)
				local low, high = if a.X < b.X then a else b, if a.X < b.X then b else a
				local cut = low + (high - low) * ((xc - low.X) / (high.X - low.X))
				local run = (high - cut).Magnitude
				mid = (cut + high) / 2 + (high - cut).Unit * (SHAPE.joint / 2)
				len = run + SHAPE.joint
			end
			-- Neighbouring strips differ by a hair in height, so their tops never share a plane where they overlap.
			local hair = if j % 2 == 0 then 0.03 else 0
			local centre = mid + s.out * ((proud - band.embed) / 2)
			local spec = Kit.oriented(
				m,
				`{name}{j}`,
				"block",
				CFrame.fromMatrix(Vector3.new(centre.X, y + thick / 2, centre.Z), s.along, UP),
				Vector3.new(len, thick + 2 * hair, proud + band.embed),
				white,
				"trim"
			)
			if glow then
				Kit.lit(spec, glow)
			end
		end
		if bow then
			local disc = Kit.disc(m, `{name}Bow`, xb, z0, y + thick / 2, 2 * (rb + proud), thick, white)
			if glow then
				Kit.lit(disc, glow)
			end
			if lit then
				Kit.lit(
					Kit.disc(
						m,
						`{name}Led`,
						xb,
						z0,
						y - SHAPE.led / 2,
						2 * (rb + proud - 0.3),
						SHAPE.led,
						white,
						"detail"
					),
					lit
				)
			end
		end
	end
	local lobbyBand = SHAPE.lobbyBand
	bandRow("LobbyBand", SHAPE.lobby, lobbyBand.thick, lobbyBand.proud, true, "ledBlue")
	local row = 0
	local y = SHAPE.lobby + band.every
	while y <= H - SHAPE.headRoom - band.thick do
		local nearLip = y > yLip - SHAPE.headRoom - band.thick and y < yLip + SHAPE.headRoom
		if not nearLip then
			row += 1
			local glow = if row % SHAPE.glowEvery == 0 then "ledEdge" else nil
			bandRow(`Band{row}_`, y, band.thick, band.proud, y < yLip, nil, glow)
		end
		y += band.every
	end

	-------------------------------------------------------------------------------------------------------
	-- The lip: a dark deck over the bow and the cut's foot, its light line, a glass rail round the bow
	-------------------------------------------------------------------------------------------------------
	local lip = SHAPE.lip
	Kit.disc(m, "Lip", xb, z0, yLip + lip.thick / 2, 2 * (rb + lip.proud), lip.thick, darkLook)
	Kit.lit(
		Kit.disc(m, "LipLed", xb, z0, yLip - lip.led / 2, 2 * (rb + lip.proud - 0.4), lip.led, white, "detail"),
		"ledBlue"
	)
	Kit.column(
		m,
		"LipRail",
		xb,
		z0,
		yLip + lip.thick,
		yLip + lip.thick + SHAPE.rail,
		2 * (rb + lip.proud - 0.4),
		RAIL,
		"detail"
	)
	-- Over the facets that stop at the lip, the deck runs on as dark caps standing out past the glass.
	local function lipCaps(face: string, points: { Vector3 }, toZ: number)
		for i = 1, #points - 1 do
			local p, q = points[i], points[i + 1]
			if math.min(p.X, q.X) < xh0 then
				local len, along, inward = chordOf(p, q)
				local depth = depthTo(p, q, inward, toZ) + lip.proud
				local at = (p + q) / 2 + inward * (depth / 2 - lip.proud) + UP * (yLip + lip.thick / 2 - 0.02)
				Kit.oriented(
					m,
					`Lip{face}{i}`,
					"block",
					CFrame.fromMatrix(at, along, UP),
					Vector3.new(len + 0.4, lip.thick - 0.04, depth),
					darkLook,
					"trim"
				)
			end
		end
	end
	lipCaps("Front", front, z0 + 1)
	lipCaps("Back", back, z0 - 1)

	-- The dark raked edges: a strut up each face along the head's leading edge, standing just proud of the glass.
	local function surfaceZ(x: number, isFront: boolean): number
		local u = math.clamp((x - xb) / span, 0, 1)
		return if isFront then frontAt(u).Z else backAt(u).Z
	end
	local edge = SHAPE.edge
	for i, isFront in { true, false } do
		local s = if isFront then -1 else 1
		local a = Vector3.new(xh0, yLip + lip.thick - 0.5, surfaceZ(xh0, isFront) + s * edge.proud)
		local b = Vector3.new(xh1, H, surfaceZ(xh1, isFront) + s * edge.proud)
		local spec = Kit.strut(m, `RakeEdge{i}`, a, b, edge.thick, darkLook, "trim")
		if crown == 2 then
			Kit.lit(spec, "crown")
		end
	end

	-- The light line up the bow's leading edge.
	local lead = xb - rb
	Kit.neonStrip(
		m,
		"BowLight",
		Vector3.new(lead - 0.35, SHAPE.line, z0 - 0.6),
		Vector3.new(lead + 0.4, yLip - 3, z0 + 0.6),
		"crown",
		pal.white
	)

	-------------------------------------------------------------------------------------------------------
	-- Crown
	-------------------------------------------------------------------------------------------------------
	if crown == 1 then
		-- The tail's spine runs on into a beacon mast.
		Kit.spire(m, "Mast", xt, z0, H, math.min(SHAPE.mast, rise - 2.5), 2, METAL, 2, true)
	elseif crown == 2 then
		-- A beacon at the head's leading tip (the raked edges are lit above).
		Kit.lit(Kit.ball(m, "Beacon", Vector3.new(xh1 + 1.5, H + 0.7, z0), 1.2, BEACON), "beacon")
	else
		-- A white blade along the middle line on the roof, a wedge whose top edge rakes down from the head's lead to
		-- the tail, lit along that edge, a beacon at its peak.
		local blade = SHAPE.blade
		local x0, x1 = xh1 + blade.inset, xt - blade.inset
		local foot = H - 0.5
		local function slope(x: number): number
			return foot + (H + blade.tall - foot) * (x1 - x) / (x1 - x0)
		end
		Kit.wedge(
			m,
			"Blade",
			Vector3.new(x0, foot, z0 - blade.thick / 2),
			Vector3.new(x1, H + blade.tall, z0 + blade.thick / 2),
			"left",
			white,
			"trim"
		)
		local a = Vector3.new(x0 + 0.5, slope(x0 + 0.5), z0)
		local b = Vector3.new(x1 - blade.light, slope(x1 - blade.light), z0)
		Kit.lit(Kit.strut(m, "BladeLight", a, b, 0.5, white, "detail", blade.thick + 0.2), "crown")
		Kit.lit(Kit.ball(m, "Beacon", Vector3.new(x0 + 0.6, slope(x0 + 0.6) + 0.5, z0), 1.2, BEACON), "beacon")
	end

	-------------------------------------------------------------------------------------------------------
	-- The garage behind the sail, the plaza, the name on the lobby band, the wash on the bow
	-------------------------------------------------------------------------------------------------------
	local gz0, gz1 = z0 + SHAPE.garageGap, hd - SHAPE.garageInset
	if gz1 - gz0 >= SHAPE.garageMin then
		local gx0, gx1 = -hw + SHAPE.garageInset, hw - SHAPE.garageInset
		local top = SHAPE.lobby + SHAPE.levels * SHAPE.level
		Kit.glass(
			m,
			"Shops",
			Vector3.new(gx0 + 3, yFoot, gz0 + 3),
			Vector3.new(gx1 - 3, SHAPE.lobby + 0.5, gz1 - 3),
			rgb(44, 60, 70),
			{
				image = City.textures.windowBold,
				faces = { Enum.NormalId.Left, Enum.NormalId.Right, Enum.NormalId.Back },
				u = 5,
				v = SHAPE.lobby,
				lines = pal.white,
				lit = true,
			}
		)
		Kit.podium(
			m,
			"Garage",
			Vector3.new(gx0, SHAPE.lobby, gz0),
			Vector3.new(gx1, top, gz1),
			SHAPE.levels,
			SHAPE.slot,
			SHAPE.bandProud,
			Kit.look(pal.garage, Enum.Material.Concrete),
			concreteDark
		)
		local cap = SHAPE.bandProud + 0.4
		Kit.trim(
			m,
			"GarageCap",
			Vector3.new(gx0 - cap, top, gz0 - cap),
			Vector3.new(gx1 + cap, top + SHAPE.capThick, gz1 + cap),
			white
		)
	end
	Kit.box(
		m,
		"Plaza",
		Vector3.new(-hw + 0.3, -0.6, -hd + 0.3),
		Vector3.new(hw - 0.3, SHAPE.plaza, hd - 0.3),
		Kit.look(P.deco.terrazzo, Enum.Material.SmoothPlastic)
	)
	-- The name stands on the lobby band in front of the bow's widest point, between the glass and the band's edge.
	local apex = z0 - rb
	local signY = SHAPE.lobby + lobbyBand.thick + 0.05
	Kit.sign(
		m,
		"Name",
		Vector3.new(xb - 6, signY, apex - 2.4),
		Vector3.new(xb + 6, signY + 2.4, apex - 1.9),
		Enum.NormalId.Front,
		tag,
		rgb(40, 44, 50),
		pal.white,
		City.districtLooks.downtown.font
	)
	Kit.wash(m, "Wash", xb - rb * 0.5, xb + rb * 1.2, apex - lobbyBand.proud - 1.5, SHAPE.plaza, rgb(170, 220, 255))
	if hw - 12 > L / 2 + SHAPE.tipRoom then
		for i, side in { -1, 1 } do
			Kit.planter(
				m,
				`Planter{i}`,
				Vector3.new(side * (hw - 12), SHAPE.plaza, -hd + 2),
				Vector3.new(side * (hw - 3), SHAPE.plaza + 1.6, -hd + 5),
				white
			)
		end
	end
end

local archetype: Types.Archetype = { id = "sail_supertall", build = build }
return archetype
