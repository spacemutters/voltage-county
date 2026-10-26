--!strict
-- T03 tiered_curve_crown_tower (docs/city/ARCHETYPES.md §5, T03): downtown's banded office tower on a ten-storey city
-- garage, the one a new player sees straight ahead from the spawn. In plan the tower is a D: flat back and sides, and a
-- show face that is a convex arc. It rises in three tiers; each tier's arc steps back from the one below, so the show
-- face climbs as three stacked curved drums, while the flat sides run straight to the top. Where arc meets side, every
-- tier has a dark notched corner. The whole skin is pale aluminium pinstriped with a dark glass ribbon every floor
-- (black-and-white bars, so the tower reads pale from across the city), and the top floors of each tier are its light
-- band: by day a dark glazed crown band that marks the tier, at night a band of
-- light in the city's show colour (crownShow: cool white most nights, one colour on show nights), so after dark the
-- tower is three glowing curved rings climbing back. A glass sky lobby stands on the garage under the first tier, the
-- garage roof in front of it is an office terrace, and pale pilasters run up the garage front over the shop columns.
--
-- What makes it itself: three curved tiers stepping back toward the sky, glowing as one at night.
-- Placement, sizes, heights and its budget: Config/CityArchetypes/tiered_curve_crown_tower. It is a one-off (weight
-- 0): the planner builds it once at its anchor (Config/City landmarks), turned to face the spawn, with a core claim.
-- Variants: palette (5 facade, glass and garage sets); crown (1 a plant room, 2 twin beacon masts on it, 3 a crown
-- screen rising over the top tier's arc, lit with the show); rhythm (1 a tall first tier and pinstripes a floor apart,
-- 2 three even tiers and pinstripes half a floor apart); mirror (symmetric but for the canopy's sign).
--
-- When previewing: use a deep site (Preview option depth = 110). On a 53-deep plot the tower is about 40 deep and the
-- setbacks only about 5. From the front, check that the arcs read as smooth curves (8 facets a tier) with their
-- pinstripes lining up across the facets, that each tier's arc steps back cleanly and that the notches read dark.
-- At night the three light bands should glow all round their tiers and nothing else in the show's light but crown 3's
-- screen (try a show night too). Compare with night photos of the inspiration.
-- Seen in Studio 2026-10-26 (docs/images/city/tiered_curve_crown_tower-*.jpg): the first cut, blue glass with white
-- pinstripes, 12-stud setbacks and tiers 6 % narrower, read as a generic glass condo; hence the pale skin, the dark
-- crown bands, 16-stud setbacks and tiers 10 % narrower.

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
	lobby = 16, -- the shops under the garage
	level = 10, -- a parking level
	levels = 8,
	frontSetback = 4,
	sideInset = 1.5,
	backInset = 1.5,
	slot = 3.2,
	bandProud = 0.5,
	lobbyInset = 3,
	columnEvery = 20,
	columnsMax = 10,
	column = 2.2,
	capThick = 1.6,
	capProud = 0.9, -- past the bands (and over the pilasters' faces); keeps the cap inside sideInset
	pilaster = 1.8, -- pale pilasters up the garage front over the shop columns: width...
	pilasterProud = 0.8, -- ...and how far they stand past the bands
	skyLobby = 14, -- the glass sky lobby on the garage roof, under the first tier
	skyInset = 2, -- from the tower's back
	skyShare = 0.7, -- its half-width, a share of the arc's
	skyBulge = 0.35, -- its front stands this share of the arc's bulge in front of the shoulder line
	-- The tower is wider than deep with a gentle arc, as in the inspiration (a 75 x 72 plan with a 0.62 bulge read as
	-- a round drum, a wedding cake, in the Studio preview).
	towerShare = 0.56, -- the tower's width: a share of the garage's...
	towerWidth = { 56, 100 }, -- ...clamped
	towerDepth = 64, -- at most
	towerBack = 3, -- from the garage's back
	towerFront = 4, -- at least this much garage roof in front of it
	terrace = 30, -- on a deep garage, the roof terrace in front of the tower is at most this deep
	bulge = 0.35, -- the arc's bulge past its ends, as a share of its half-width...
	bulgeDepth = 0.5, -- ...and at most this share of the tower's depth
	facets = 8, -- solid facets on each tier's arc
	setback = 16, -- each tier's arc stands this far behind the one below, at most (12 barely read)...
	flatMin = 10, -- ...leaving the top tier at least this much flat side behind its arc
	notch = { 0.12, 6 }, -- the notches where arc meets side: across, a share of the half-width (at most 6)...
	notchDeep = { 0.25, 6 }, -- ...and deep, a share of the top tier's flat side (at most 6)
	notchShadow = 0.45, -- the notch's dark recess fills this share of it from the inside
	narrow = 0.1, -- each tier is this share of the first's width narrower than the one below (0.06 barely read)
	-- By rhythm: tier 1's and tier 2's tops as shares of the tower over the garage, and the pinstripes' spacing.
	rhythms = {
		{ tiers = { 0.62, 0.81 }, stripe = 12 },
		{ tiers = { 0.5, 0.75 }, stripe = 6 },
	},
	minTier = 24, -- a tier stands at least this much over the one below
	band = 20, -- each tier's light band, at most...
	bandShare = 0.3, -- ...and at most this share of the tier
	stripeU = 16, -- the pinstripe overlay's tile across a flat face (its mullion lines)
	terraceMin = 8, -- planters on the terrace need this much depth...
	umbrellasMin = 16, -- ...umbrellas this much
	plant = 8, -- the plant room's height
	mast = 16,
	screen = { rise = 10, thick = 1.2, embed = 1.5, joint = 0.5 }, -- crown 3: the crown screen over the top arc
	canopyY = 12,
	canopyThick = 1.4,
	canopyHalf = 16,
}

-- The light bands and crown 3's screen are the light show (Config/Environment nightLights.kinds.crownShow). The garage's
-- light lines are the pale edge kind, so they never compete with it.
local SHOW = "crownShow"
local EDGE = "ledEdge"
-- The facade's pale aluminium (the skin, pilasters, terrace), its glass ribbons, the light bands' dark glass by day,
-- and the garage. Every set keeps the inspiration's look, a pale tower of black-and-white bars (a blue tower with
-- white pinstripes read as any glass condo in the Studio preview); the ribbons' tint changes.
local PALETTES = {
	{ pale = rgb(233, 233, 230), glass = rgb(46, 58, 70), garage = P.concrete.pale },
	{ pale = rgb(233, 233, 230), glass = P.glass.teal, garage = P.concrete.pale },
	{ pale = P.frame.silver, glass = P.glass.navy, garage = P.concrete.warm },
	{ pale = P.frame.warm, glass = P.glass.aqua, garage = P.concrete.warm },
	{ pale = rgb(233, 233, 230), glass = P.glass.blue, garage = P.concrete.pale },
}

local RAIL = Kit.look(rgb(214, 236, 242), Enum.Material.Glass, 0.1, KIT.railTransparency)
local METAL = Kit.look(rgb(200, 204, 210), Enum.Material.Metal)
local UP = Vector3.yAxis

-- The arc of a tier's show face, left to right: from (-half, zs) through its apex (0, zs - bulge) to (half, zs), on a
-- circle, in n facets (n + 1 points).
local function arcPoints(half: number, bulge: number, zs: number, n: number): { Vector3 }
	local r = (half * half + bulge * bulge) / (2 * bulge)
	local theta = math.asin(math.clamp(half / r, -1, 1))
	local apex = zs - bulge
	local points: { Vector3 } = {}
	for i = 0, n do
		local a = -theta + 2 * theta * i / n
		table.insert(points, Vector3.new(r * math.sin(a), 0, apex + r - r * math.cos(a)))
	end
	return points
end

local function build(m: Types.Model)
	local site = m.site
	local variant = site.variant
	local pal = PALETTES[math.clamp(variant.palette, 1, #PALETTES)]
	local rhythm = SHAPE.rhythms[math.clamp(variant.rhythm, 1, #SHAPE.rhythms)]
	local rng = Kit.rng(m)
	local W, D, H = site.width, site.depth, site.height
	local hw, hd = W / 2, D / 2
	local rise = site.maxHeight - H
	local pale = Kit.look(pal.pale, Enum.Material.SmoothPlastic)
	local dark = Kit.look(P.concrete.dark, Enum.Material.SmoothPlastic)
	local tag = City.signNames.towers[rng:NextInteger(1, #City.signNames.towers)]
	local crown = math.clamp(variant.crown, 1, 3)

	-------------------------------------------------------------------------------------------------------
	-- The garage: shops under eight parking levels, pilasters, a lit cap, the tower's entrance canopy
	-------------------------------------------------------------------------------------------------------
	local podiumTop = SHAPE.lobby + SHAPE.levels * SHAPE.level
	local deck = podiumTop + SHAPE.capThick
	local px0, px1 = -hw + SHAPE.sideInset, hw - SHAPE.sideInset
	local pz0, pz1 = -hd + SHAPE.frontSetback, hd - SHAPE.backInset
	local li = SHAPE.lobbyInset

	Kit.glass(
		m,
		"Shops",
		Vector3.new(px0 + li, -KIT.bury, pz0 + li),
		Vector3.new(px1 - li, SHAPE.lobby + 0.5, pz1 - li),
		rgb(44, 60, 70),
		{
			image = City.textures.windowBold,
			faces = { Enum.NormalId.Front, Enum.NormalId.Left, Enum.NormalId.Right },
			u = 5,
			v = SHAPE.lobby,
			lines = pal.pale,
			lit = true,
		}
	)
	local columns = math.clamp(math.floor((px1 - px0) / SHAPE.columnEvery), 2, SHAPE.columnsMax)
	for i = 1, columns do
		local x = px0 + 2 + (px1 - px0 - 4) * (i - 1) / (columns - 1)
		Kit.column(m, `Column{i}`, x, pz0 + 1.3, -KIT.bury, SHAPE.lobby + 0.5, SHAPE.column, pale)
		-- Each column runs on up the garage front as a pale pilaster, standing past the bands, under the cap: the
		-- garage reads as a colonnade, not a blank striped wall.
		local half = SHAPE.pilaster / 2
		Kit.trim(
			m,
			`Pilaster{i}`,
			Vector3.new(x - half, SHAPE.lobby - 0.3, pz0 - SHAPE.bandProud - SHAPE.pilasterProud),
			Vector3.new(x + half, podiumTop, pz0 + 0.3),
			pale
		)
	end
	Kit.podium(
		m,
		"Garage",
		Vector3.new(px0, SHAPE.lobby, pz0),
		Vector3.new(px1, podiumTop, pz1),
		SHAPE.levels,
		SHAPE.slot,
		SHAPE.bandProud,
		Kit.look(pal.garage, Enum.Material.Concrete),
		dark
	)
	local cap = SHAPE.bandProud + SHAPE.capProud
	Kit.trim(
		m,
		"GarageCap",
		Vector3.new(px0 - cap, podiumTop, pz0 - cap),
		Vector3.new(px1 + cap, deck, pz1 + cap),
		pale
	)
	Kit.neonStrip(
		m,
		"GarageLed",
		Vector3.new(px0 - cap, podiumTop + 0.45, pz0 - cap - 0.15),
		Vector3.new(px1 + cap, podiumTop + 0.95, pz0 - cap - 0.05),
		EDGE,
		pal.pale
	)
	local cw = math.min(SHAPE.canopyHalf, (px1 - px0) / 2 - 4)
	local canopyTop = SHAPE.canopyY + SHAPE.canopyThick
	Kit.canopy(m, "Canopy", -cw, cw, -hd + 0.5, pz0 + li + 0.5, SHAPE.canopyY, SHAPE.canopyThick, pale)
	for i, side in { -1, 1 } do
		Kit.column(m, `CanopyPost{i}`, side * (cw - 1.5), -hd + 2, -KIT.bury, SHAPE.canopyY + 0.05, 1.2, METAL)
	end
	Kit.sign(
		m,
		"Name",
		Vector3.new(-cw * 0.7, canopyTop, -hd + 0.8),
		Vector3.new(cw * 0.7, canopyTop + 2.8, -hd + 1.3),
		Enum.NormalId.Front,
		tag,
		rgb(40, 44, 50),
		pal.pale,
		City.districtLooks.downtown.font
	)
	Kit.neonStrip(
		m,
		"CanopyLed",
		Vector3.new(-cw, SHAPE.canopyY - 0.25, -hd + 0.6),
		Vector3.new(cw, SHAPE.canopyY - 0.05, -hd + 1.2),
		EDGE,
		pal.pale
	)
	Kit.wash(m, "Wash", -cw * 0.8, cw * 0.8, -hd + 3.4, canopyTop, rgb(220, 226, 255))

	-------------------------------------------------------------------------------------------------------
	-- The tower's plan (a D: its arc to the front) and its three tiers' heights
	-------------------------------------------------------------------------------------------------------
	local Wt =
		math.min(math.clamp((px1 - px0) * SHAPE.towerShare, SHAPE.towerWidth[1], SHAPE.towerWidth[2]), px1 - px0 - 8)
	local tx = Wt / 2
	local zb = pz1 - SHAPE.towerBack
	local Dt = math.min(SHAPE.towerDepth, zb - (pz0 + SHAPE.towerFront))
	local zf1 = math.min(zb - Dt, pz0 + SHAPE.terrace) -- the first tier's apex
	zb = zf1 + Dt
	local nw = math.min(tx * SHAPE.notch[1], SHAPE.notch[2])
	local ta = tx - nw -- the arc's half-width (the notches take the rest)
	local bulge = math.min(ta * SHAPE.bulge, Dt * SHAPE.bulgeDepth)
	local zs1 = zf1 + bulge -- the first tier's shoulder line, where its arc ends
	local step = math.max(0, math.min(SHAPE.setback, (zb - zs1 - SHAPE.flatMin) / 2))
	local nd = math.min((zb - zs1 - 2 * step) * SHAPE.notchDeep[1], SHAPE.notchDeep[2])

	local base = deck + SHAPE.skyLobby -- the first tier's foot
	local function snap(y: number): number
		return base + math.round((y - base) / SHAPE.floor) * SHAPE.floor
	end
	local y2 = math.min(snap(base + (H - base) * rhythm.tiers[2]), H - SHAPE.minTier)
	local y1 = math.min(snap(base + (H - base) * rhythm.tiers[1]), y2 - SHAPE.minTier)
	local feet = { base, y1, y2 }
	local tops = { y1, y2, H }

	-- The sky lobby: set in under the first tier, so the arc's middle stays inside the arc above it and the arc
	-- cantilevers past it at the sides.
	Kit.glass(
		m,
		"SkyLobby",
		Vector3.new(-ta * SHAPE.skyShare, deck - 0.05, zs1 - bulge * SHAPE.skyBulge),
		Vector3.new(ta * SHAPE.skyShare, base + 0.05, zb - SHAPE.skyInset),
		rgb(44, 60, 70),
		{ image = City.textures.windowBold, u = 5, v = SHAPE.skyLobby, lines = pal.pale, lit = true }
	)

	-------------------------------------------------------------------------------------------------------
	-- The tiers: each a flat back block, a bridge to its arc, eight solid arc facets, two dark notches, and its top
	-- floors cut off as the light band
	-------------------------------------------------------------------------------------------------------
	local stripe = rhythm.stripe
	-- The skin: pale aluminium with a glass ribbon (the overlay's spandrel band, a quarter of each stripe) and a thin
	-- transom line per stripe, and a ribbon-coloured mullion at every facet's edge, so the arcs show their facets.
	local skinLook = Kit.look(pal.pale, Enum.Material.SmoothPlastic)
	-- The light bands by day: the ribbons' glass, a shade darker, ruled pale every floor: each tier ends in a dark
	-- glazed crown band, so the three tiers read by day too; at night they are the show.
	local bandLook = Kit.look(pal.glass:Lerp(Color3.new(0, 0, 0), 0.12), Enum.Material.SmoothPlastic)
	local function overlay(spec: Types.PartSpec, faces: { Enum.NormalId }, u: number, band: boolean?)
		local textures: { Types.TextureSpec } = {}
		for _, face in faces do
			table.insert(textures, {
				face = Kit.face(m, face),
				image = if band then City.textures.windowFine else City.textures.windowBold,
				u = if band then math.min(u, 4) else u,
				v = if band then SHAPE.floor else stripe,
				color = if band then pal.pale else pal.glass,
			})
		end
		spec.textures = textures
	end
	-- A solid facet of an arc: its outer face on the chord p..q (its Front, outward), reaching back past the line z =
	-- toZ, from lo up to hi.
	local function facet(
		name: string,
		p: Vector3,
		q: Vector3,
		toZ: number,
		lo: number,
		hi: number,
		look: Kit.Look,
		band: boolean
	)
		local chord = q - p
		local len = chord.Magnitude
		local along = chord / len
		local inward = Vector3.new(-along.Z, 0, along.X) -- toward the tower (the arc runs left to right)
		local depth = math.max(1, (toZ - p.Z) / inward.Z, (toZ - q.Z) / inward.Z)
		local at = (p + q) / 2 + inward * (depth / 2) + UP * ((lo + hi) / 2)
		local spec = Kit.oriented(
			m,
			name,
			"block",
			CFrame.fromMatrix(at, along, UP),
			Vector3.new(len, hi - lo, depth),
			look,
			"box"
		)
		-- A facet is one tile wide (its mullions mark its edges); a band facet's grid is a few studs.
		local u = if band then len / math.max(1, math.round(len / 4)) else len
		spec.textures = {
			{
				face = Enum.NormalId.Front,
				image = if band then City.textures.windowFine else City.textures.windowBold,
				u = u,
				v = if band then SHAPE.floor else stripe,
				color = if band then pal.pale else pal.glass,
			},
		}
		return spec
	end
	local SIDES = { Enum.NormalId.Left, Enum.NormalId.Right, Enum.NormalId.Back }
	local topArc: { Vector3 } = {}
	local topHalf = tx
	for k = 1, 3 do
		-- Each tier a little narrower than the one below (its arc's bulge in proportion), so the steps read from the
		-- front as well as from the side.
		local narrow = 1 - SHAPE.narrow * (k - 1)
		local tk = tx * narrow
		local nwk = math.min(tk * SHAPE.notch[1], SHAPE.notch[2])
		local tak = tk - nwk
		local bk = bulge * narrow
		local zs = zs1 + (k - 1) * step
		local y0, yt = feet[k], tops[k]
		local yc = yt - math.min(SHAPE.band, (yt - y0) * SHAPE.bandShare) -- the light band's foot
		-- The flat block behind the arc and its notches, full width: glass below, the light band above.
		local fz0 = zs + nd
		overlay(
			Kit.box(m, `Tier{k}`, Vector3.new(-tk, y0, fz0), Vector3.new(tk, yc, zb), skinLook),
			SIDES,
			SHAPE.stripeU
		)
		local band = Kit.box(m, `Tier{k}Band`, Vector3.new(-tk, yc, fz0), Vector3.new(tk, yt, zb), bandLook)
		overlay(band, SIDES, SHAPE.stripeU, true)
		Kit.lit(band, SHOW)
		-- The bridge from the block to the arc, between the notches.
		local bz0, bz1 = zs - 0.05, fz0 + 0.05
		overlay(
			Kit.box(m, `Tier{k}Bridge`, Vector3.new(-tak, y0, bz0), Vector3.new(tak, yc, bz1), skinLook),
			{ Enum.NormalId.Left, Enum.NormalId.Right },
			nd + 0.1
		)
		local bridgeBand =
			Kit.box(m, `Tier{k}BridgeBand`, Vector3.new(-tak, yc, bz0), Vector3.new(tak, yt, bz1), bandLook)
		overlay(bridgeBand, { Enum.NormalId.Left, Enum.NormalId.Right }, nd + 0.1, true)
		Kit.lit(bridgeBand, SHOW)
		-- The notches' dark recesses, so each notch reads as a deep slot from any side.
		local deep = nwk * SHAPE.notchShadow
		for i, side in { -1, 1 } do
			Kit.box(
				m,
				`Tier{k}Notch{i}`,
				Vector3.new(side * (tak - 0.05), y0 + 0.05, zs + nd * SHAPE.notchShadow),
				Vector3.new(side * (tak + nwk - deep), yt - 0.05, fz0 + 0.05),
				dark
			)
		end
		-- The arc: solid facets, glass below the band and lit above.
		local arc = arcPoints(tak, bk, zs, SHAPE.facets)
		local toZ = zs + 1
		for i = 1, SHAPE.facets do
			facet(`Tier{k}Arc{i}`, arc[i], arc[i + 1], toZ, y0, yc, skinLook, false)
			Kit.lit(facet(`Tier{k}ArcBand{i}`, arc[i], arc[i + 1], toZ, yc, yt, bandLook, true), SHOW)
		end
		topArc = arc
		topHalf = tk
	end

	-------------------------------------------------------------------------------------------------------
	-- Crown
	-------------------------------------------------------------------------------------------------------
	local zs3 = zs1 + 2 * step
	local plantZ0, plantZ1 = zs3 + nd + 3, zb - 3
	if crown == 3 then
		-- A crown screen standing on the top tier's arc: pale louvres by day, lit with the show at night. Straight
		-- strips, one per two facets, reaching a little into the arc at their ends.
		local sc = SHAPE.screen
		local tall = math.min(sc.rise, rise - 1)
		for j = 1, SHAPE.facets // 2 do
			local p, q = topArc[2 * j - 1], topArc[2 * j + 1]
			local chord = q - p
			local along = chord.Unit
			local inward = Vector3.new(-along.Z, 0, along.X)
			-- Neighbouring strips differ by a hair in height and depth, so they share no plane where they overlap.
			local hair = if j % 2 == 0 then 0.04 else 0
			local at = (p + q) / 2 + inward * (sc.embed - sc.thick / 2) + UP * (H - 0.5 + (tall + hair) / 2)
			local spec = Kit.oriented(
				m,
				`CrownScreen{j}`,
				"block",
				CFrame.fromMatrix(at, along, UP),
				Vector3.new(chord.Magnitude + 2 * sc.joint, tall + 0.5 + hair, sc.thick + hair),
				pale,
				"trim"
			)
			spec.textures = {
				{ face = Enum.NormalId.Front, image = City.textures.slabLine, u = 4, v = 2, color = pal.glass },
			}
			Kit.lit(spec, SHOW)
		end
	end
	if plantZ1 - plantZ0 >= 3 then
		Kit.roofBox(
			m,
			"Plant",
			Vector3.new(-topHalf * 0.5, H - 0.05, plantZ0),
			Vector3.new(topHalf * 0.5, H + SHAPE.plant, plantZ1),
			pale
		)
		if crown == 2 then
			local tall = math.min(SHAPE.mast, rise - SHAPE.plant - 2.5)
			local mz = (plantZ0 + plantZ1) / 2
			Kit.spire(m, "MastA", -topHalf * 0.3, mz, H + SHAPE.plant, tall, 1.2, METAL, 2, true)
			Kit.spire(m, "MastB", topHalf * 0.3, mz, H + SHAPE.plant, tall * 0.7, 1.2, METAL, 2, true)
		end
	end

	-------------------------------------------------------------------------------------------------------
	-- The office terrace on the garage roof, in front of the tower
	-------------------------------------------------------------------------------------------------------
	local terrace = zf1 - pz0
	if terrace >= SHAPE.terraceMin then
		local plantW = math.min(14, (px1 - px0) * 0.12)
		for i, side in { -1, 1 } do
			Kit.planter(
				m,
				`Planter{i}`,
				Vector3.new(side * (tx - plantW), deck, pz0 + 1.2),
				Vector3.new(side * tx, deck + 1.6, pz0 + 3.4),
				pale
			)
		end
		if terrace >= SHAPE.umbrellasMin then
			local uz = (pz0 + 3.4 + zf1) / 2
			for i, side in { -1, 1 } do
				Kit.umbrella(m, `Umbrella{i}`, side * tx * 0.45, uz, deck, 7, P.deco.white)
			end
		end
	end
	Kit.detail(
		m,
		"DeckRail",
		Vector3.new(px0 - cap + 0.3, deck + 0.02, pz0 - cap + 0.3),
		Vector3.new(px1 + cap - 0.3, deck + KIT.railHeight + 0.2, pz0 - cap + 0.6),
		RAIL
	)
end

local archetype: Types.Archetype = { id = "tiered_curve_crown_tower", build = build }
return archetype
