--!strict
-- T10 telescope_tower (docs/city/ARCHETYPES.md §5, T10): an upside-down tower, like a telescope standing on its
-- narrow end. Three glass tiers, each wider and deeper than the one under it, on a glass lobby narrower still. A
-- white soffit wraps the foot of every tier where it steps out, and at night an LED line round each soffit and the
-- roof makes three rings that widen upward. Dark vertical stripes run up the front and the free side of every tier,
-- and white balcony slabs stack up the other side, tucked under each overhang. The roof is a white slab, or (crown 2)
-- a white lid floating over an open top floor with a lit lounge under it.
--
-- What makes it itself: each of its three glass tiers is wider than the one beneath it.
-- Placement, sizes, heights and its budget: Config/CityArchetypes/telescope_tower.
-- Variants: palette (3 glass and stripe sets), crown (1 a white roof slab and a plant room, 2 a lid floating on four
-- columns over an open floor), rhythm (1 the tiers widen evenly all round, 2 they share the back and one side and all
-- of the widening cantilevers to the front and the balcony side), mirror.
--
-- Seen in Studio 2026-10-25, day and night (docs/images/city/telescope_tower-day.jpg, -night.jpg).
-- Preview check: the three steps out read from the street at 70 mph and from far off (the
-- soffit bands catch the sun); rhythm 2's cantilever looks deliberate, not broken; the stripes and balconies give each
-- face two depths; the three rings read at night, widening upward; the floating lid's gap shows sky; nothing pokes
-- past the footprint at 70 and 130 wide, 46 and 53 deep.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local City = require(ReplicatedStorage.Shared.Config.City)
local Kit = require(script.Parent.Parent.Parent.Kit)
local Types = require(script.Parent.Parent.Parent.Types)

local P = City.palettes
local KIT = City.kit
local rgb = Color3.fromRGB

local FRONT, LEFT, RIGHT = Enum.NormalId.Front, Enum.NormalId.Left, Enum.NormalId.Right

-- The recipe, in studs.
local SHAPE = {
	floor = 12,
	lobby = 16, -- the first tier's foot
	sideSpare = 10, -- the top tier is the site's width less this (its balconies reach past one side)...
	width = { 56, 80 }, -- ...between these
	front = 3, -- the top tier's faces from the front and back lines
	back = 2,
	depth = { 40, 80 },
	-- By rhythm: each tier is this share of the top tier's width narrower than the one over it (half each side, or
	-- all on one side): big enough steps that the upside-down stack reads from across downtown.
	stepX = { 0.18, 0.24 },
	stepZ = { 0.18, 6, 10 }, -- and this much shallower (share of the top tier's depth, clamped; 1.5 times in rhythm 2)
	lobbyInset = 4, -- the lobby sits this far in under the first tier
	split = { 0.34, 0.67 }, -- the tiers' breaks, share of the height over the lobby (whole floors)
	soffit = { thick = 3, proud = 0.5 },
	ring = { proud = 0.15, from = 0.6, tall = 0.6 }, -- an LED line round a soffit or the roof, `from` over its foot
	stripes = { 0.25, 0.5, 0.75 }, -- where the dark stripes stand across each face
	stripe = { wide = 3, proud = 0.3 },
	balcony = { every = 24, reach = 3.5, thick = 1.2, first = 12, keep = 6, inset = 1.5 },
	roof = 3, -- the roof slab or the lid...
	roofProud = 1.5, -- ...overhanging this far
	open = 12, -- crown 2: the open floor under the lid
	lid = { column = 0.9, inset = 1.5, lounge = { 10, 8 } }, -- the lounge keeps this far in from the tier's sides
	plant = 8,
}

-- Glass, the dark stripes, the white of soffits, slabs and roof.
local PALETTES = {
	{ glass = P.glass.aqua, stripe = P.frame.charcoal, white = P.frame.white },
	{ glass = P.glass.silver, stripe = rgb(40, 52, 70), white = P.frame.white },
	{ glass = P.glass.blue, stripe = rgb(30, 36, 42), white = P.frame.warm },
}

local RAIL = Kit.look(rgb(214, 236, 242), Enum.Material.Glass, 0.1, KIT.railTransparency)

type Tier = { x0: number, x1: number, z0: number, z1: number, y0: number, y1: number }

local function build(m: Types.Model)
	local site = m.site
	local variant = site.variant
	local pal = PALETTES[math.clamp(variant.palette, 1, #PALETTES)]
	local rhythm = math.clamp(variant.rhythm, 1, 2)
	local rng = Kit.rng(m)
	local W, D, H = site.width, site.depth, site.height
	local hw, hd = W / 2, D / 2
	local F = SHAPE.floor
	local yb = -KIT.bury
	local white = Kit.look(pal.white, Enum.Material.SmoothPlastic)
	local stripe = Kit.look(pal.stripe, Enum.Material.SmoothPlastic)
	local tag = City.signNames.towers[rng:NextInteger(1, #City.signNames.towers)]

	-------------------------------------------------------------------------------------------------------
	-- The tiers: the top one fills the site, each one under it narrower and shallower
	-------------------------------------------------------------------------------------------------------
	local w3 = math.clamp(W - SHAPE.sideSpare, SHAPE.width[1], SHAPE.width[2])
	local zFront, zBack = -hd + SHAPE.front, hd - SHAPE.back
	local d3 = math.clamp(zBack - zFront, SHAPE.depth[1], SHAPE.depth[2])
	local dz = math.clamp(d3 * SHAPE.stepZ[1], SHAPE.stepZ[2], SHAPE.stepZ[3])
	local zc = (zFront + zBack) / 2
	local roofBase = H - SHAPE.roof
	local over = roofBase - SHAPE.lobby
	local y1 = SHAPE.lobby + F * math.round(over * SHAPE.split[1] / F)
	local y2 = SHAPE.lobby + F * math.round(over * SHAPE.split[2] / F)
	local top3 = if variant.crown == 2 then roofBase - SHAPE.open else roofBase
	local feet = { SHAPE.lobby, y1, y2 }
	local heads = { y1, y2, top3 }

	local tiers: { Tier } = {}
	for k = 1, 3 do
		local j = 3 - k -- steps under the top tier
		local t: Tier
		if rhythm == 1 then
			local w, d = w3 - j * SHAPE.stepX[1] * w3, d3 - j * dz
			t = { x0 = -w / 2, x1 = w / 2, z0 = zc - d / 2, z1 = zc + d / 2, y0 = feet[k], y1 = heads[k] }
		else
			local w, d = w3 - j * SHAPE.stepX[2] * w3, d3 - j * 1.5 * dz
			t = { x0 = -w3 / 2, x1 = -w3 / 2 + w, z0 = zBack - d, z1 = zBack, y0 = feet[k], y1 = heads[k] }
		end
		table.insert(tiers, t)
	end

	local sp, st = SHAPE.soffit.proud, SHAPE.soffit.thick
	local rg = SHAPE.ring
	local lines = pal.glass:Lerp(pal.white, 0.45)
	for k, t in tiers do
		-- The glass, a floor to a tile from its top (its foot and head are whole floors apart up to the roof).
		Kit.glass(m, `Tier{k}`, Vector3.new(t.x0, t.y0, t.z0), Vector3.new(t.x1, t.y1, t.z1), pal.glass, {
			image = City.textures.windowFine,
			faces = { FRONT, LEFT, RIGHT },
			u = 6,
			v = F,
			lines = lines,
		})
		-- The white soffit round its foot: the step out reads as a band in the sun.
		Kit.trim(
			m,
			`Soffit{k}`,
			Vector3.new(t.x0 - sp, t.y0 - st, t.z0 - sp),
			Vector3.new(t.x1 + sp, t.y0 + 0.02, t.z1 + sp),
			white
		)
		if k > 1 then
			local e = sp + rg.proud
			Kit.neonStrip(
				m,
				`Ring{k}`,
				Vector3.new(t.x0 - e, t.y0 - st + rg.from, t.z0 - e),
				Vector3.new(t.x1 + e, t.y0 - st + rg.from + rg.tall, t.z1 + e),
				"ledBlue",
				pal.white
			)
		end
		-- Dark stripes up the front and the free (left) side.
		local half = SHAPE.stripe.wide / 2
		local sp2 = SHAPE.stripe.proud
		for i, f in SHAPE.stripes do
			local x = t.x0 + (t.x1 - t.x0) * f
			Kit.trim(
				m,
				`StripeF{k}{i}`,
				Vector3.new(x - half, t.y0 + 0.02, t.z0 - sp2),
				Vector3.new(x + half, t.y1 - 0.02, t.z0 + 0.1),
				stripe
			)
			local z = t.z0 + (t.z1 - t.z0) * f
			Kit.trim(
				m,
				`StripeL{k}{i}`,
				Vector3.new(t.x0 - sp2, t.y0 + 0.02, z - half),
				Vector3.new(t.x0 + 0.1, t.y1 - 0.02, z + half),
				stripe
			)
		end
		-- White balcony slabs up the right side, the lower tiers' tucked under the overhang above.
		local bc = SHAPE.balcony
		local y = t.y0 + bc.first
		local count = 0
		while y + bc.thick <= t.y1 - bc.keep do
			count += 1
			Kit.trim(
				m,
				`Balcony{k}_{count}`,
				Vector3.new(t.x1 - 0.5, y, t.z0 + bc.inset),
				Vector3.new(t.x1 + bc.reach, y + bc.thick, t.z1 - bc.inset),
				white
			)
			y += bc.every
		end
	end

	-------------------------------------------------------------------------------------------------------
	-- The foot: a glass lobby narrower than the first tier, the name on the first soffit, paving and planters
	-------------------------------------------------------------------------------------------------------
	local t1 = tiers[1]
	local li = SHAPE.lobbyInset
	Kit.glass(
		m,
		"Lobby",
		Vector3.new(t1.x0 + li, yb, t1.z0 + li),
		Vector3.new(t1.x1 - li, SHAPE.lobby - st + 0.6, t1.z1 - li),
		rgb(44, 60, 70),
		{
			image = City.textures.windowBold,
			faces = { FRONT, LEFT, RIGHT },
			u = 5,
			v = SHAPE.lobby - st + 1.6,
			lines = pal.white,
			lit = true,
		}
	)
	local cx1 = (t1.x0 + t1.x1) / 2
	local soffitFront = t1.z0 - sp
	Kit.sign(
		m,
		"Name",
		Vector3.new(cx1 - 8, SHAPE.lobby - st + 0.2, soffitFront - 0.4),
		Vector3.new(cx1 + 8, SHAPE.lobby - 0.2, soffitFront - 0.05),
		FRONT,
		tag,
		pal.stripe,
		pal.white,
		City.districtLooks.downtown.font
	)
	local granite = Kit.look(rgb(196, 192, 184), Enum.Material.Granite)
	Kit.detail(m, "Paving", Vector3.new(-hw + 1, 0, -hd + 0.5), Vector3.new(hw - 1, 0.3, hd - 0.5), granite)
	local edge = -hd + 1.2
	Kit.planter(m, "PlanterL", Vector3.new(-hw + 3, 0.3, edge), Vector3.new(-hw + 13, 1.8, edge + 2), white)
	Kit.planter(m, "PlanterR", Vector3.new(hw - 13, 0.3, edge), Vector3.new(hw - 3, 1.8, edge + 2), white)

	-------------------------------------------------------------------------------------------------------
	-- The top: a white roof slab, or a lid floating over an open floor; the third ring round it
	-------------------------------------------------------------------------------------------------------
	local t3 = tiers[3]
	local rf = SHAPE.roofProud
	local cx3, cz3 = (t3.x0 + t3.x1) / 2, (t3.z0 + t3.z1) / 2
	Kit.trim(m, "Roof", Vector3.new(t3.x0 - rf, roofBase, t3.z0 - rf), Vector3.new(t3.x1 + rf, H, t3.z1 + rf), white)
	local e = rf + rg.proud
	Kit.neonStrip(
		m,
		"RingTop",
		Vector3.new(t3.x0 - e, roofBase + 1.2, t3.z0 - e),
		Vector3.new(t3.x1 + e, roofBase + 1.2 + rg.tall, t3.z1 + e),
		"ledBlue",
		pal.white
	)
	if variant.crown == 2 then
		-- The open floor: a glass rail round its edge, a column at each corner, a lit lounge in the middle.
		Kit.detail(
			m,
			"LidRail",
			Vector3.new(t3.x0 + 0.3, top3, t3.z0 + 0.3),
			Vector3.new(t3.x1 - 0.3, top3 + KIT.railHeight, t3.z1 - 0.3),
			RAIL
		)
		local ci = SHAPE.lid.inset
		local col = 0
		for _, x in { t3.x0 + ci, t3.x1 - ci } do
			for _, z in { t3.z0 + ci, t3.z1 - ci } do
				col += 1
				Kit.column(m, `LidColumn{col}`, x, z, top3, roofBase + 0.02, SHAPE.lid.column, white, "trim")
			end
		end
		local lw = (t3.x1 - t3.x0) / 2 - SHAPE.lid.lounge[1]
		local ld = (t3.z1 - t3.z0) / 2 - SHAPE.lid.lounge[2]
		Kit.glass(
			m,
			"Lounge",
			Vector3.new(cx3 - lw, top3, cz3 - ld),
			Vector3.new(cx3 + lw, roofBase - 1, cz3 + ld),
			pal.glass,
			{ lit = true }
		)
	else
		Kit.roofBox(m, "Plant", Vector3.new(cx3 - 8, H, cz3 - 6), Vector3.new(cx3 + 8, H + SHAPE.plant, cz3 + 6))
	end
end

local archetype: Types.Archetype = { id = "telescope_tower", build = build }
return archetype
