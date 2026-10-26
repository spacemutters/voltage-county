--!strict
-- T03 tiered_curve_crown_tower (docs/city/ARCHETYPES.md §5, T03): downtown's banded office tower on a ten-storey city
-- garage, the one a new player sees straight ahead from the spawn. A pale tower striped by continuous glass ribbons
-- steps back three times on its show face. Each tier ends in a curved glass cap, a quarter round rising from the tier's
-- front edge back to the face of the tier above. Seen from the side the top is a stack of three quarter-moons; seen from
-- the front it is three curved bands climbing back. At night the three caps glow (the light-show kind crownShow): cool
-- white most nights, and on some nights all three in one colour, the city's colour show. The back is squared off, and
-- the garage roof in front of the tower is an office terrace. Pale pilasters run up the garage front over the shop
-- columns, so the garage reads as a colonnade.
--
-- What makes it itself: three curved tiers stepping back toward the sky, glowing as one at night.
-- Placement, sizes, heights and its budget: Config/CityArchetypes/tiered_curve_crown_tower. It is a one-off (weight
-- 0): the planner builds it once at its anchor (Config/City landmarks), turned to face the spawn, with a core claim.
-- Variants: palette (5 facade, glass and garage sets); crown (1 a plant room, 2 a beacon mast on it, 3 the tower's
-- corner piers in the show's light too); rhythm (1 a pale band and a glass ribbon every two floors, 2 every floor);
-- mirror (symmetric but for the canopy's sign).
--
-- When previewing: use a deep site (Preview option depth = 110). On a 53-deep plot the tower is only about 40 deep and
-- its caps' radius only about 10. From the side, check that the caps read as quarter rounds rising to the next face,
-- with no flicker where a cap meets a tier, and that the caps' flat ends sit just inside the tower's sides. At night,
-- the caps should glow and nothing else in the show's light except the crown-3 piers (try a show night too). Compare
-- with night photos of the inspiration.

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
	skyLobby = 14, -- the glass sky lobby on the garage roof, under the tower
	skyInset = 2,
	towerShare = 0.46, -- the tower's width: a share of the garage's...
	towerWidth = { 56, 100 }, -- ...clamped
	towerDepth = 68, -- at most
	towerBack = 3, -- from the garage's back
	towerFront = 4, -- at least this much garage roof in front of it
	terrace = 30, -- on a deep garage, the roof terrace in front of the tower is at most this deep
	-- The caps' radius (each tier steps back by it), at most... (14 read as a ledge from the front; 18 reads as a curve)
	radius = 18,
	radiusShare = 0.27, -- ...a share of the tower's depth (the roof behind the top cap needs the rest)
	tiers = { 0.72, 0.86 }, -- tier 1's and tier 2's tops, as shares of the main roof
	minTier = 24, -- a tier shows at least this much over the cap below it
	stripes = { { pale = 14, glass = 10 }, { pale = 7, glass = 5 } }, -- by rhythm: a pale band, then a glass ribbon
	stripeProud = 0.8, -- the bands stand this far out of the glass
	capInset = 0.9, -- the caps' flat ends sit this far in from the tower's sides (inside the glass)
	capShell = 0.05, -- the light shell over each cap: this much bigger all round
	pier = 1.6,
	pierProud = 0.3,
	canopyY = 12,
	canopyThick = 1.4,
	canopyHalf = 16,
	terraceMin = 8, -- planters on the terrace need this much depth...
	umbrellasMin = 16, -- ...umbrellas this much
	plant = 8, -- the plant room's height
	mast = 18,
}

-- The caps: pale, sky-lit glass by day; by night the light show (Config/Environment nightLights.kinds.crownShow). The
-- garage's light lines are the pale edge kind, so they never compete with it.
local CAP_DAY = rgb(168, 192, 210) -- a shade under the pale bands, so the caps read as glass crowns by day
local SHOW = "crownShow"
local EDGE = "ledEdge"
-- The facade's pale bands, the glass and the garage.
local PALETTES = {
	{ pale = rgb(233, 233, 230), glass = P.glass.blue, garage = P.concrete.pale },
	{ pale = rgb(233, 233, 230), glass = P.glass.teal, garage = P.concrete.pale },
	{ pale = P.frame.silver, glass = P.glass.navy, garage = P.concrete.warm },
	{ pale = P.frame.warm, glass = P.glass.aqua, garage = P.concrete.warm },
	{ pale = rgb(233, 233, 230), glass = P.glass.silver, garage = P.concrete.pale },
}

local RAIL = Kit.look(rgb(214, 236, 242), Enum.Material.Glass, 0.1, KIT.railTransparency)
local METAL = Kit.look(rgb(200, 204, 210), Enum.Material.Metal)

local function build(m: Types.Model)
	local site = m.site
	local variant = site.variant
	local pal = PALETTES[math.clamp(variant.palette, 1, #PALETTES)]
	local rng = Kit.rng(m)
	local W, D, H = site.width, site.depth, site.height
	local hw, hd = W / 2, D / 2
	local rise = site.maxHeight - H
	local pale = Kit.look(pal.pale, Enum.Material.SmoothPlastic)
	local dark = Kit.look(P.concrete.dark, Enum.Material.SmoothPlastic)
	local tag = City.signNames.towers[rng:NextInteger(1, #City.signNames.towers)]
	local crown = math.clamp(variant.crown, 1, 3)

	-------------------------------------------------------------------------------------------------------
	-- The garage: shops under eight parking levels, a lit cap, the tower's entrance canopy
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
	-- The tower: its plan, its three tiers' tops
	-------------------------------------------------------------------------------------------------------
	local Wt =
		math.min(math.clamp((px1 - px0) * SHAPE.towerShare, SHAPE.towerWidth[1], SHAPE.towerWidth[2]), px1 - px0 - 8)
	local tx = Wt / 2
	local zb = pz1 - SHAPE.towerBack
	local Dt = math.min(SHAPE.towerDepth, zb - (pz0 + SHAPE.towerFront))
	local zf1 = math.min(zb - Dt, pz0 + SHAPE.terrace)
	zb = zf1 + Dt
	local r = math.min(SHAPE.radius, Dt * SHAPE.radiusShare)

	local base = deck + SHAPE.skyLobby -- tier 1's foot
	local function snap(y: number): number
		return base + math.round((y - base) / SHAPE.floor) * SHAPE.floor
	end
	local y3 = H - r -- the top tier's roof (its cap rises to the main roof)
	local y2 = math.min(snap(H * SHAPE.tiers[2]), y3 - r - SHAPE.minTier)
	local y1 = math.min(snap(H * SHAPE.tiers[1]), y2 - r - SHAPE.minTier)
	local feet = { base, y1, y2 }
	local tops = { y1, y2, y3 }

	Kit.glass(
		m,
		"SkyLobby",
		Vector3.new(-tx + SHAPE.skyInset, deck - 0.05, zf1 + SHAPE.skyInset),
		Vector3.new(tx - SHAPE.skyInset, base + 0.05, zb - SHAPE.skyInset),
		rgb(44, 60, 70),
		{ image = City.textures.windowBold, u = 5, v = SHAPE.skyLobby, lines = pal.pale, lit = true }
	)

	-------------------------------------------------------------------------------------------------------
	-- The tiers: glass inside pale bands, front corner piers, and a curved cap on each
	-------------------------------------------------------------------------------------------------------
	local stripe = SHAPE.stripes[math.clamp(variant.rhythm, 1, #SHAPE.stripes)]
	local period = stripe.pale + stripe.glass
	local sp = SHAPE.stripeProud
	local pier, pp = SHAPE.pier, SHAPE.pierProud
	local lines = pal.pale:Lerp(pal.glass, 0.35)
	local capLook = Kit.look(CAP_DAY, Enum.Material.SmoothPlastic)
	local function pierAt(name: string, side: number, z0: number, z1: number, from: number, to: number)
		local spec = Kit.trim(
			m,
			name,
			Vector3.new(side * (tx - pier + pp), from, z0),
			Vector3.new(side * (tx + pp), to, z1),
			pale
		)
		if crown == 3 then
			Kit.lit(spec, SHOW)
		end
	end
	for k = 1, 3 do
		local zf = zf1 + (k - 1) * r
		local y0, yt = feet[k], tops[k]
		Kit.glass(
			m,
			`Tier{k}`,
			Vector3.new(-tx + sp, y0, zf + sp),
			Vector3.new(tx - sp, yt - 0.05, zb - sp),
			pal.glass,
			{
				image = City.textures.windowFine,
				u = 4.8,
				v = SHAPE.floor,
				lines = lines,
			}
		)
		-- Pale bands from a glass ribbon under the cap down, each wrapping all four sides; the glass shows between them.
		-- The dark ribbon right under each cap sets the cap off from the bands, so the tiers read from the front too.
		local j, top = 0, yt - stripe.glass
		while top - stripe.pale >= y0 - 0.01 do
			j += 1
			Kit.trim(m, `Tier{k}Band{j}`, Vector3.new(-tx, top - stripe.pale, zf), Vector3.new(tx, top, zb), pale)
			top -= period
		end
		for i, side in { -1, 1 } do
			pierAt(`Tier{k}Pier{i}`, side, zf - pp, zf + pier - pp, y0, yt)
		end
		-- The cap: a cylinder lying along the tier's top edge, its axis on the face of the tier above, so only its
		-- front upper quarter shows (the rest sits inside the two tiers, or the roof behind the top cap). A still
		-- cylinder holds its shape; a shell a hair larger carries the night's light, so the cap keeps its shape in the
		-- site's still model whatever happens to its light model far away.
		local a = Vector3.new(-tx + SHAPE.capInset, yt, zf + r)
		local b = Vector3.new(tx - SHAPE.capInset, yt, zf + r)
		Kit.tube(m, `Cap{k}`, a, b, 2 * r, capLook, "trim")
		local shell = SHAPE.capShell
		Kit.lit(
			Kit.tube(
				m,
				`Cap{k}Light`,
				a - Vector3.xAxis * shell,
				b + Vector3.xAxis * shell,
				2 * (r + shell),
				capLook,
				"detail"
			),
			SHOW
		)
	end
	-- The roof behind the top cap, holding its back half (a hair over the main roof, so the cap's light shell never
	-- shows over it), and the back corner piers, one each from the garage up.
	local zr = zf1 + 3 * r
	Kit.box(m, "Roof", Vector3.new(-tx, y3, zr), Vector3.new(tx, H + SHAPE.capShell * 2, zb), pale)
	for i, side in { -1, 1 } do
		pierAt(`BackPier{i}`, side, zb - pier + pp, zb + pp, base, H)
	end

	-------------------------------------------------------------------------------------------------------
	-- Crown: a plant room on the roof, a beacon mast (crown 2)
	-------------------------------------------------------------------------------------------------------
	local plantZ0, plantZ1 = zr + 3, zb - 3
	if plantZ1 - plantZ0 >= 3 then
		Kit.roofBox(
			m,
			"Plant",
			Vector3.new(-tx * 0.5, H - 0.05, plantZ0),
			Vector3.new(tx * 0.5, H + SHAPE.plant, plantZ1),
			pale
		)
		if crown == 2 then
			local tall = math.min(SHAPE.mast, rise - SHAPE.plant - 2.5)
			Kit.spire(m, "Mast", 0, (plantZ0 + plantZ1) / 2, H + SHAPE.plant, tall, 1.2, METAL, 2, true)
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
