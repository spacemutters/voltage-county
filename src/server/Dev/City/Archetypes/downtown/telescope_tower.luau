--!strict
-- T10 telescope_tower (docs/city/ARCHETYPES.md §5, T10): an upside-down tower, like a telescope standing on its
-- narrow end. Three glass tiers, each a big step wider than the one under it, cantilevering out along the road (on
-- both sides, or all to one side) over a glass lobby narrower still, with a pool on the ground under each overhang.
-- Every tier is striped by white balcony slabs every second floor and framed by white corner piers, so each reads as
-- its own drum of lines, and a thick white soffit closes the underside of every step out. At night an LED line round
-- each soffit and the roof makes four rings that widen upward.
--
-- What makes it itself: each of its three glass tiers is wider than the one beneath it.
-- Placement, sizes, heights and its budget: Config/CityArchetypes/telescope_tower.
-- Variants: palette (3 glass and white sets), crown (1 a white roof slab and a plant room, 2 a lid floating on four
-- columns over an open top floor with a lit lounge), rhythm (1 the tiers widen evenly to both sides, 2 they share
-- one end and all of the widening cantilevers to the other), mirror.
--
-- Preview check (the Studio step): the three steps out read from the street at 70 mph and from across downtown (the
-- soffits catch the sun and throw a deep shadow on the tier below); rhythm 2's one-sided cantilever looks deliberate,
-- not broken; the balcony slabs and corner piers give every face two depths; the pools sit under the overhangs, clear
-- of the lobby; the four rings read at night, widening upward; the floating lid's gap shows sky; nothing pokes past the
-- footprint at 76 and 130 wide, 46, 53 and 100 deep.

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
	sideSpare = 6, -- the top tier is the site's width less this (its slabs reach past its ends)...
	width = { 66, 96 }, -- ...between these
	back = 3, -- the tiers' backs from the back line (the slabs reach out behind)
	depth = { 7, 36, 60 }, -- the tiers' depth: the site's less the first number, clamped
	step = { 0.12, 7, 11 }, -- each step out, each side (share of the top tier's width, clamped); twice that on one side
	lobbyInset = 4, -- the lobby sits this far in under the first tier
	split = { 0.34, 0.67 }, -- the tiers' breaks, share of the height over the lobby (whole floors)
	-- The white frame round every tier is bold, as the real tower's stepped perimeter structure (Studio round 1: 3-thick
	-- soffits, 1.4-wide piers and 1.2 slabs read as hairlines on plain glass boxes from across downtown).
	soffit = { thick = 4.5, proud = 0.6 },
	ring = { proud = 0.15, from = 0.9, tall = 0.7 }, -- an LED line round a soffit or the roof, `from` over its foot
	pier = { wide = 2.6, proud = 1 }, -- white piers on each tier's corners
	plate = { every = 24, first = 12, keep = 6, thick = 1.6, ends = 1.8, faces = 2.8 }, -- balcony slabs
	roof = 3, -- the roof slab or the lid...
	roofProud = 1.5, -- ...overhanging this far
	open = 12, -- crown 2: the open floor under the lid
	lid = { column = 0.9, inset = 1.5, lounge = { 10, 8 } }, -- the lounge keeps this far in from the tier's sides
	plant = 8,
	pool = { side = 2, gap = 1.5, ends = 6, least = 6 }, -- a pool under each overhang
	litTop = 0.5, -- the share of copies whose top tier's glass glows at night
}

-- Glass and the white of slabs, piers, soffits and roof.
local PALETTES = {
	{ glass = P.glass.aqua, white = P.frame.white },
	{ glass = P.glass.silver, white = P.frame.white },
	{ glass = P.glass.blue, white = P.frame.warm },
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
	local tag = City.signNames.towers[rng:NextInteger(1, #City.signNames.towers)]
	local litTop = rng:NextNumber() < SHAPE.litTop

	-------------------------------------------------------------------------------------------------------
	-- The tiers: the top one fills the site's width, each one under it a step narrower on each side (rhythm 1) or
	-- two steps narrower on one side (rhythm 2); all as deep, set toward the back
	-------------------------------------------------------------------------------------------------------
	local w3 = math.clamp(W - SHAPE.sideSpare, SHAPE.width[1], SHAPE.width[2])
	local s = math.clamp(w3 * SHAPE.step[1], SHAPE.step[2], SHAPE.step[3])
	local d = math.clamp(D - SHAPE.depth[1], SHAPE.depth[2], SHAPE.depth[3])
	local z1 = hd - SHAPE.back
	local z0 = z1 - d
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
		local x0, x1
		if rhythm == 1 then
			x0, x1 = -w3 / 2 + j * s, w3 / 2 - j * s
		else
			x0, x1 = -w3 / 2, w3 / 2 - 2 * j * s
		end
		table.insert(tiers, { x0 = x0, x1 = x1, z0 = z0, z1 = z1, y0 = feet[k], y1 = heads[k] })
	end

	local sp, st = SHAPE.soffit.proud, SHAPE.soffit.thick
	local rg = SHAPE.ring
	local pr = SHAPE.pier
	local pl = SHAPE.plate
	local lines = pal.glass:Lerp(pal.white, 0.45)
	for k, t in tiers do
		-- The glass, a floor to a tile from its top (its foot and head are whole floors apart up to the roof).
		Kit.glass(m, `Tier{k}`, Vector3.new(t.x0, t.y0, t.z0), Vector3.new(t.x1, t.y1, t.z1), pal.glass, {
			image = City.textures.windowFine,
			faces = { FRONT, LEFT, RIGHT },
			u = 6,
			v = F,
			lines = lines,
			lit = k == 3 and litTop,
		})
		-- The white soffit closing its underside: the step out reads as a thick band in the sun, and an LED line round
		-- it at night.
		Kit.trim(
			m,
			`Soffit{k}`,
			Vector3.new(t.x0 - sp, t.y0 - st, t.z0 - sp),
			Vector3.new(t.x1 + sp, t.y0 + 0.02, t.z1 + sp),
			white
		)
		local e = sp + rg.proud
		Kit.neonStrip(
			m,
			`Ring{k}`,
			Vector3.new(t.x0 - e, t.y0 - st + rg.from, t.z0 - e),
			Vector3.new(t.x1 + e, t.y0 - st + rg.from + rg.tall, t.z1 + e),
			"ledEdge",
			pal.white
		)
		-- White piers on its four corners: each tier framed like a section of the telescope.
		-- Each corner: x, z and which way is out.
		for i, corner in { { t.x0, t.z0, -1, -1 }, { t.x1, t.z0, 1, -1 }, { t.x0, t.z1, -1, 1 }, { t.x1, t.z1, 1, 1 } } do
			local cx, cz, ox, oz = corner[1], corner[2], corner[3], corner[4]
			local a = Vector3.new(cx + ox * pr.proud, t.y0 + 0.02, cz + oz * pr.proud)
			local b = Vector3.new(cx - ox * (pr.wide - pr.proud), t.y1 - 0.02, cz - oz * (pr.wide - pr.proud))
			Kit.trim(m, `Pier{k}_{i}`, a, b, white)
		end
		-- Balcony slabs every second floor round the tier, the first a floor over its soffit.
		Kit.plates(
			m,
			`Plate{k}_`,
			Vector3.new(t.x0, 0, t.z0),
			Vector3.new(t.x1, 0, t.z1),
			t.y0 + pl.first,
			t.y1 - pl.keep,
			pl.every,
			pl.thick,
			pl.ends,
			pl.faces,
			white
		)
	end

	-------------------------------------------------------------------------------------------------------
	-- The foot: a glass lobby narrower than the first tier, the name on the first soffit, paving, a pool under each
	-- overhang, planters
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
		rgb(40, 44, 50),
		pal.white,
		City.districtLooks.downtown.font
	)
	local granite = Kit.look(rgb(196, 192, 184), Enum.Material.Granite)
	Kit.detail(m, "Paving", Vector3.new(-hw + 1, 0, -hd + 0.5), Vector3.new(hw - 1, 0.3, hd - 0.5), granite)
	local po = SHAPE.pool
	local pz0, pz1 = z0 + po.ends, z1 - po.ends
	local function pool(name: string, a: number, b: number)
		if b - a >= po.least and pz1 - pz0 >= po.least then
			Kit.pool(m, name, Vector3.new(a, 0, pz0), Vector3.new(b, 0, pz1), 0.3)
		end
	end
	if rhythm == 1 then
		pool("PoolL", -w3 / 2 + po.side, t1.x0 - po.gap)
	end
	pool("PoolR", t1.x1 + po.gap, w3 / 2 - po.side)
	local edge = -hd + 1.2
	Kit.planter(m, "PlanterL", Vector3.new(-hw + 3, 0.3, edge), Vector3.new(-hw + 13, 1.8, edge + 2), white)
	Kit.planter(m, "PlanterR", Vector3.new(hw - 13, 0.3, edge), Vector3.new(hw - 3, 1.8, edge + 2), white)

	-------------------------------------------------------------------------------------------------------
	-- The top: a white roof slab, or a lid floating over an open floor; the last ring round it
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
		"ledEdge",
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
