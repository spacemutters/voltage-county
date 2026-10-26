--!strict
-- C03 harbor_market_pavilions (docs/city/ARCHETYPES.md §9, C03): the bayfront market. Two long open market halls,
-- white posts and a glass-railed gallery over a shop arcade, under bright metal gable roofs with a raised lit
-- clerestory, either side of a plaza of market umbrellas behind a lit gateway sign. At the back a timber boardwalk
-- with lamps and bollards along the water, and behind the plaza the signature: a giant observation wheel on two
-- A-frames, its rim a ring of neon at night and pastel cabins riding round the outside of it.
--
-- What makes it itself: two bright-roofed market sheds on the water with a giant wheel rising between them.
-- Placement, sizes, heights and its budget: Config/CityArchetypes/harbor_market_pavilions. Front (-z): the road;
-- back (+z): the water. The wheel stands in the plaza behind the halls when the site is deep enough (about 90+);
-- on a shallower site it shrinks to fit between the halls.
-- Variants: palette (1 one teal roof and one coral, 2 coral roofs with teal clerestories, 3 sky and mint), crown (1 a
-- pink rim, twelve spokes and twelve pods; 2 a blue rim, eighteen spokes and sixteen pods), rhythm (1 posts every 12
-- and a short clerestory, 2 posts every 9 and a long one), mirror (the plaza and the wheel sit off-centre).
--
-- Previewing (Studio helper): Preview.build("harbor_market_pavilions", { width = 210, depth = 100 }) for the full
-- look; width 160, depth 53 is the plain-plot fallback. Check: the wheel reads round (20 rim segments) and stands
-- clear of the halls' roofs, its legs land on the platform, the pods ride outside the rim; the clerestories sit on the
-- ridges; at night the rim glows, the clerestories and shopfronts glow, the gateway sign is lit.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local City = require(ReplicatedStorage.Shared.Config.City)
local Kit = require(script.Parent.Parent.Parent.Kit)
local Types = require(script.Parent.Parent.Parent.Types)

local P = City.palettes
local KIT = City.kit
local rgb = Color3.fromRGB

-- The recipe, in studs.
local SHAPE = {
	sideInset = 3.6, -- the roofs overhang the halls by 3.2
	forecourt = 7, -- paving between the front line and the halls
	boardwalk = 10, -- along the back line
	deck = 0.6,
	plaza = { share = 0.3, min = 40, max = 76, offset = 0.05 }, -- its width and how far off-centre it sits
	hall = {
		minDepth = 18,
		maxDepth = 46,
		storey = 11, -- the ground floor; the gallery's floor stands on it
		arcade = 6, -- the shops sit this far behind the posts, under the gallery
		ridge = 7, -- eave to the main ridge
		overhang = 3.2, -- deep eaves: the roofs are the halls' look
		post = 1.4,
		postEvery = { 12, 9 }, -- by rhythm
		gallery = 0.8,
		rail = 3,
		clerestory = { share = { 0.4, 0.66 }, glass = 4.5, depth = 0.4, roof = 3.5 },
	},
	wheelZone = 22, -- between the halls' backs and the boardwalk, for the wheel's legs
	wheel = {
		max = 140,
		clearance = 11.5, -- the rim's lowest point over the ground (the bottom pod hangs below it)
		rim = 2.2,
		rimDepth = 3.2, -- deep, so the ring reads as a truss
		segments = 20,
		spokes = { 6, 9 }, -- bars through the hub (each two spokes), by crown
		pods = { 12, 16 },
		legZ = 9,
		spread = 0.42, -- the legs land this share of the radius either side
		leg = 1.8,
		hub = 5,
		platform = 1.2,
	},
	pod = 7.6, -- the gondolas: round cabins on the outside of the rim
	gate = { pylon = 2.6, height = 17, beam = { 12.5, 16 } },
	umbrella = 7.5,
	stringLights = { count = 3, height = 13, diameter = 0.35 },
	lamp = { height = 12, every = 0.3 },
}

-- Roofs (left hall, right hall), clerestory roofs, the gateway board, pods.
local PALETTES = {
	{
		roofs = { rgb(46, 156, 154), rgb(240, 110, 90) },
		clerestory = nil :: Color3?, -- nil: the hall's own roof colour
		board = rgb(46, 156, 154),
	},
	{
		roofs = { rgb(240, 110, 90), rgb(240, 110, 90) },
		clerestory = rgb(46, 156, 154) :: Color3?,
		board = rgb(240, 110, 90),
	},
	{
		roofs = { rgb(96, 172, 222), rgb(110, 204, 170) },
		clerestory = nil :: Color3?,
		board = rgb(62, 132, 196),
	},
}
local PODS = { P.deco.pink, P.deco.sky, P.deco.lemon, P.deco.mint, P.deco.lilac, P.deco.peach }
local RIMS = { "neonPink", "neonBlue" }
local WHITE = Kit.look(rgb(250, 250, 248), Enum.Material.SmoothPlastic)
local RAIL = Kit.look(rgb(214, 236, 242), Enum.Material.Glass, 0.1, KIT.railTransparency)
local IRON = Kit.look(rgb(44, 48, 52), Enum.Material.Metal)

local function build(m: Types.Model)
	local site = m.site
	local variant = site.variant
	local pal = PALETTES[math.clamp(variant.palette, 1, #PALETTES)]
	local crown = math.clamp(variant.crown, 1, 2)
	local rhythm = math.clamp(variant.rhythm, 1, 2)
	local W, D, H = site.width, site.depth, site.height
	local hw, hd = W / 2, D / 2
	local hl = SHAPE.hall
	local cl = hl.clerestory

	-------------------------------------------------------------------------------------------------------
	-- Layout: two halls either side of an off-centre plaza, the wheel behind the plaza, the boardwalk at the back
	-------------------------------------------------------------------------------------------------------
	local Wu = W - 2 * SHAPE.sideInset
	local pl = SHAPE.plaza
	local Pw = math.clamp(Wu * pl.share, pl.min, pl.max)
	local pc = Wu * pl.offset -- the plaza's centre
	local zF = -hd + SHAPE.forecourt
	local zBoard = hd - SHAPE.boardwalk
	local pd = math.clamp(zBoard - zF - SHAPE.wheelZone, hl.minDepth, hl.maxDepth)
	pd = math.min(pd, zBoard - zF - 1)
	local zH1 = zF + pd
	local zMid = (zF + zH1) / 2
	local clerBase = H - cl.roof
	local mainRidge = clerBase - cl.glass + 1.5
	local eave = mainRidge - hl.ridge

	-- The paving under everything: the forecourt, the plaza, round the wheel.
	Kit.box(
		m,
		"Paving",
		Vector3.new(-hw + 0.3, 0, -hd + 0.3),
		Vector3.new(hw - 0.3, 0.2, zBoard + 0.3),
		Kit.look(P.deco.terrazzo, Enum.Material.Concrete)
	)

	-------------------------------------------------------------------------------------------------------
	-- The halls
	-------------------------------------------------------------------------------------------------------
	local function hall(name: string, x0: number, x1: number, roof: Color3, innerFace: Enum.NormalId)
		local L = x1 - x0
		local xm = (x0 + x1) / 2
		local zS = zF + hl.arcade -- the shopfronts
		local roofLook = Kit.look(roof, Enum.Material.Metal)
		Kit.box(m, `{name}Core`, Vector3.new(x0 + 0.2, -KIT.bury, zS), Vector3.new(x1 - 0.2, eave, zH1), WHITE)
		Kit.glass(
			m,
			`{name}Shops`,
			Vector3.new(x0 + 1.5, 0.3, zS - 0.08),
			Vector3.new(x1 - 1.5, hl.storey - 1, zS + 0.3),
			P.window.dark,
			{
				image = City.textures.windowBold,
				faces = { Enum.NormalId.Front },
				u = 4,
				v = hl.storey - 1.3,
				lines = rgb(250, 250, 248),
				lit = true,
			}
		)
		Kit.glass(
			m,
			`{name}Upper`,
			Vector3.new(x0 + 1.5, hl.storey + 1.8, zS - 0.08),
			Vector3.new(x1 - 1.5, eave - 1.6, zS + 0.3),
			P.window.dark,
			{
				image = City.textures.windowFine,
				faces = { Enum.NormalId.Front },
				u = 3,
				v = eave - 1.6 - hl.storey - 1.8,
				lines = rgb(250, 250, 248),
				reflectance = 0.2,
			}
		)
		Kit.glass(
			m,
			`{name}Back`,
			Vector3.new(x0 + 1.5, 1.2, zH1 - 0.3),
			Vector3.new(x1 - 1.5, eave - 1.6, zH1 + 0.08),
			P.window.dark,
			{
				image = City.textures.windowFine,
				faces = { Enum.NormalId.Back },
				u = 3,
				v = hl.storey - 0.6,
				lines = rgb(250, 250, 248),
				reflectance = 0.2,
			}
		)
		-- The end facing the plaza: a lit shopfront across its ground floor.
		local endX = if innerFace == Enum.NormalId.Right then x1 - 0.2 else x0 + 0.2
		local ex0, ex1 = endX - 0.3, endX + 0.08
		if innerFace == Enum.NormalId.Left then
			ex0, ex1 = endX - 0.08, endX + 0.3
		end
		Kit.glass(
			m,
			`{name}End`,
			Vector3.new(ex0, 0.3, zS + 1.5),
			Vector3.new(ex1, hl.storey - 1, zH1 - 1.5),
			P.window.dark,
			{
				image = City.textures.windowBold,
				faces = { innerFace },
				u = 4,
				v = hl.storey - 1.3,
				lines = rgb(250, 250, 248),
				lit = true,
			}
		)
		-- The gallery over the arcade, its glass rail, and the posts carrying the eave.
		Kit.trim(
			m,
			`{name}Gallery`,
			Vector3.new(x0, hl.storey, zF + 0.2),
			Vector3.new(x1, hl.storey + hl.gallery, zS + 0.4),
			WHITE
		)
		Kit.detail(
			m,
			`{name}Rail`,
			Vector3.new(x0 + 0.2, hl.storey + hl.gallery, zF + 0.3),
			Vector3.new(x1 - 0.2, hl.storey + hl.gallery + hl.rail, zF + 0.6),
			RAIL
		)
		local count = math.clamp(math.floor(L / hl.postEvery[rhythm]) + 1, 3, 9)
		for k = 1, count do
			local x = x0 + 0.9 + (L - 1.8) * (k - 1) / (count - 1)
			Kit.box(
				m,
				`{name}Post{k}`,
				Vector3.new(x - hl.post / 2, 0.2, zF + 0.3),
				Vector3.new(x + hl.post / 2, eave, zF + 0.3 + hl.post),
				WHITE
			)
		end
		-- The gable roof, its lit front eave, and the clerestory on the ridge.
		local ov = hl.overhang
		Kit.wedge(
			m,
			`{name}RoofF`,
			Vector3.new(x0 - ov, eave, zF - ov),
			Vector3.new(x1 + ov, mainRidge, zMid),
			"back",
			roofLook
		)
		Kit.wedge(
			m,
			`{name}RoofB`,
			Vector3.new(x0 - ov, eave, zMid),
			Vector3.new(x1 + ov, mainRidge - 0.04, zH1 + ov),
			"front",
			roofLook
		)
		Kit.neonStrip(
			m,
			`{name}Led`,
			Vector3.new(x0 - ov, eave - 0.5, zF - ov - 0.1),
			Vector3.new(x1 + ov, eave - 0.1, zF - ov + 0.3),
			"ledBlue",
			roof
		)
		local cLen = L * cl.share[rhythm]
		local cd = pd * cl.depth
		Kit.glass(
			m,
			`{name}Clerestory`,
			Vector3.new(xm - cLen / 2, mainRidge - 1.5, zMid - cd / 2),
			Vector3.new(xm + cLen / 2, clerBase, zMid + cd / 2),
			P.window.dark,
			{
				image = City.textures.windowBold,
				faces = { Enum.NormalId.Front, Enum.NormalId.Back },
				u = 3,
				v = cl.glass,
				lines = rgb(250, 250, 248),
				lit = true,
			}
		)
		local clerLook = Kit.look(pal.clerestory or roof, Enum.Material.Metal)
		Kit.wedge(
			m,
			`{name}ClerRoofF`,
			Vector3.new(xm - cLen / 2 - 0.8, clerBase, zMid - cd / 2 - 0.8),
			Vector3.new(xm + cLen / 2 + 0.8, H, zMid),
			"back",
			clerLook,
			"trim"
		)
		Kit.wedge(
			m,
			`{name}ClerRoofB`,
			Vector3.new(xm - cLen / 2 - 0.8, clerBase, zMid),
			Vector3.new(xm + cLen / 2 + 0.8, H - 0.04, zMid + cd / 2 + 0.8),
			"front",
			clerLook,
			"trim"
		)
	end

	local px0, px1 = pc - Pw / 2, pc + Pw / 2
	hall("HallL", -Wu / 2, px0, pal.roofs[1], Enum.NormalId.Right)
	hall("HallR", px1, Wu / 2, pal.roofs[2], Enum.NormalId.Left)

	-------------------------------------------------------------------------------------------------------
	-- The plaza: a lit gateway sign at its mouth, market umbrellas
	-------------------------------------------------------------------------------------------------------
	local g = SHAPE.gate
	local gx = Pw / 2 - 3
	for i, side in { -1, 1 } do
		local x = pc + side * gx
		Kit.box(
			m,
			`Pylon{i}`,
			Vector3.new(x - g.pylon / 2, 0.2, zF - 0.6),
			Vector3.new(x + g.pylon / 2, g.height, zF - 0.6 + g.pylon),
			WHITE
		)
	end
	Kit.sign(
		m,
		"Gateway",
		Vector3.new(pc - gx + g.pylon / 2, g.beam[1], zF - 0.3),
		Vector3.new(pc + gx - g.pylon / 2, g.beam[2], zF - 0.6 + g.pylon - 0.3),
		Enum.NormalId.Front,
		"LAKESIDE MARKET",
		pal.board,
		rgb(250, 250, 248),
		City.districtLooks.beach.font,
		"sign"
	)
	-- Strings of lights across the plaza from hall to hall, amber at night.
	local sl = SHAPE.stringLights
	for i = 1, sl.count do
		local z = zF + pd * i / (sl.count + 1)
		local y = sl.height + (i % 2) * 1.2
		Kit.neon(
			m,
			`Lights{i}`,
			Vector3.new(px0 + 0.4, y, z),
			Vector3.new(px1 - 0.4, y, z),
			"neonAmber",
			rgb(255, 236, 196),
			sl.diameter
		)
	end
	local umbrellaZ = zF + math.min(pd * 0.4, 12)
	for i, at in { -0.32, -0.11, 0.11, 0.32 } do
		local color = if i % 2 == 1 then pal.roofs[1] else P.deco.white
		Kit.umbrella(m, `Umbrella{i}`, pc + at * Pw, umbrellaZ, 0.2, SHAPE.umbrella, color, true)
	end

	-------------------------------------------------------------------------------------------------------
	-- The boardwalk along the water: timber deck, rail, bollards, lamps
	-------------------------------------------------------------------------------------------------------
	local deckTop = 0.2 + SHAPE.deck
	Kit.box(
		m,
		"Boardwalk",
		Vector3.new(-hw + 0.5, 0.15, zBoard),
		Vector3.new(hw - 0.5, deckTop, hd - 0.3),
		Kit.look(rgb(156, 122, 85), Enum.Material.WoodPlanks)
	)
	Kit.detail(
		m,
		"WaterRail",
		Vector3.new(-hw + 0.8, deckTop, hd - 1.1),
		Vector3.new(hw - 0.8, deckTop + 3, hd - 0.8),
		WHITE
	)
	for i, at in { -0.42, -0.14, 0.14, 0.42 } do
		Kit.column(m, `Bollard{i}`, at * W, hd - 2.4, deckTop - 0.05, deckTop + 1.6, 1.1, IRON, "detail")
	end
	local lp = SHAPE.lamp
	for i, at in { -0.36, 0, 0.36 } do
		local x = at * W
		Kit.column(m, `LampPost{i}`, x, zBoard + 2, deckTop - 0.05, deckTop + lp.height, 0.45, IRON, "detail")
		Kit.lit(
			Kit.ball(
				m,
				`Lamp{i}`,
				Vector3.new(x, deckTop + lp.height + 0.5, zBoard + 2),
				1.3,
				Kit.look(rgb(255, 243, 214), Enum.Material.SmoothPlastic)
			),
			"streetlight"
		)
	end

	-------------------------------------------------------------------------------------------------------
	-- The wheel: a ring of rim segments on spokes round a hub, two A-frames, pods
	-------------------------------------------------------------------------------------------------------
	local wh = SHAPE.wheel
	local room = zBoard - zH1
	local free = room >= 2 * wh.legZ + 2
	local wz = if free then zH1 + wh.legZ + 4 else zBoard - wh.legZ - 1
	wz = math.clamp(wz, -hd + wh.legZ + 1, hd - wh.legZ - 1)
	local wx = pc
	local out = wh.rim / 2 + SHAPE.pod + 0.2 -- the pods reach this far outside the rim's centre line
	local r = (site.maxHeight - 1 - wh.clearance - out) / 2
	r = math.min(r, wh.max / 2, hw - math.abs(wx) - out - 2)
	if not free then
		r = math.min(r, Pw / 2 - 1 - out) -- squeezed between the halls
	end
	local wy = wh.clearance + r
	local rimKind = RIMS[crown]

	Kit.box(
		m,
		"Platform",
		Vector3.new(wx - r * wh.spread - 3, 0.15, wz - wh.legZ - 1.5),
		Vector3.new(wx + r * wh.spread + 3, wh.platform, wz + wh.legZ + 1.5),
		Kit.look(P.concrete.pale, Enum.Material.Concrete)
	)
	local n = wh.segments
	local rc = r * math.cos(math.pi / n)
	local chord = 2 * r * math.sin(math.pi / n) + 0.3
	for k = 0, n - 1 do
		local phi = 2 * math.pi * (k + 0.5) / n
		local cf = CFrame.new(wx + rc * math.cos(phi), wy + rc * math.sin(phi), wz)
			* CFrame.Angles(0, 0, phi + math.pi / 2)
		Kit.lit(
			Kit.oriented(m, `Rim{k + 1}`, "block", cf, Vector3.new(chord, wh.rim, wh.rimDepth), WHITE, "trim"),
			rimKind
		)
	end
	local bars = wh.spokes[crown]
	for k = 0, bars - 1 do
		local a = math.pi * k / bars
		Kit.oriented(
			m,
			`Spoke{k + 1}`,
			"block",
			CFrame.new(wx, wy, wz) * CFrame.Angles(0, 0, a),
			Vector3.new(2 * r - 1, 0.5, 0.5),
			WHITE,
			"detail"
		)
	end
	Kit.tube(m, "Hub", Vector3.new(wx, wy, wz - 3.2), Vector3.new(wx, wy, wz + 3.2), wh.hub, WHITE, "trim")
	for i, s in { { -1, -1 }, { 1, -1 }, { -1, 1 }, { 1, 1 } } do
		Kit.strut(
			m,
			`Leg{i}`,
			Vector3.new(wx, wy, wz + s[2] * 3),
			Vector3.new(wx + s[1] * r * wh.spread, wh.platform, wz + s[2] * wh.legZ),
			wh.leg,
			WHITE
		)
	end
	local pods = wh.pods[crown]
	for k = 0, pods - 1 do
		local theta = 2 * math.pi * k / pods
		local pr = r + wh.rim / 2 + SHAPE.pod / 2 + 0.2
		local centre = Vector3.new(wx + pr * math.cos(theta), wy + pr * math.sin(theta), wz)
		Kit.ball(m, `Pod{k + 1}`, centre, SHAPE.pod, Kit.look(PODS[k % #PODS + 1], Enum.Material.SmoothPlastic), "trim")
	end
end

local archetype: Types.Archetype = { id = "harbor_market_pavilions", build = build }
return archetype
