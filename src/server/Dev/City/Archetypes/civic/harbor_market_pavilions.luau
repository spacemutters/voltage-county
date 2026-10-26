--!strict
-- C03 harbor_market_pavilions (docs/city/ARCHETYPES.md §9, C03): the bayfront market. Two long two-storey market halls
-- under big, steep metal roofs, either side of a plaza of market umbrellas behind a lit gateway sign. Each hall is a
-- white frame: a shop arcade under a gallery with a glass rail, slim white posts carrying the eaves, and over it all a
-- hipped roof whose outer end is hipped and whose plaza end is a white gable with a round lit window, a raised glass
-- clerestory riding the ridge. At the back a timber boardwalk with lamps and bollards along the water, and behind the
-- plaza the signature: a giant observation wheel on two braced A-frames, its thick white rim and spokes a ring of neon
-- at night, pastel cabins riding round the outside of it.
--
-- What makes it itself: two bright-roofed market halls showing their gables to a plaza, a giant wheel rising behind.
-- Placement, sizes, heights and its budget: Config/CityArchetypes/harbor_market_pavilions. Front (-z): the road and
-- the gateway; back (+z): the water and the boardwalk (so its landmark entry should face the road; see the config).
-- The wheel stands behind the plaza when the site is deep enough (about 80+, a core claim); on a plain plot it shrinks
-- to fit between the halls.
-- Variants: palette (1 one teal roof and one coral, 2 coral roofs with teal clerestories, 3 sky and mint), crown (1 a
-- pink rim, twelve spoke bars and twelve cabins; 2 a blue rim, eighteen and sixteen), rhythm (1 posts every 12 and a
-- short clerestory, 2 posts every 9 and a long one), mirror (the plaza and the wheel sit off-centre).
--
-- Previewing (Studio helper): Preview.build("harbor_market_pavilions", { width = 210, depth = 120 }) for the full look;
-- width 160, depth 53 is the plain-plot fallback. Check: the roofs read steep and bright, each hall's plaza end a white
-- gable with the round window (the roof's metal showing only as a thin rake along its edges and a fascia under it);
-- the hip corners meet the slopes with no step; the clerestory glass sits down on the ridge with no gap under it; the
-- wheel reads round (24 rim segments) and stands clear of the halls' back eaves, its legs land on the platform and the
-- braces cross each A; at night the rim and spokes glow one colour, the eaves blue, the gables' round windows, the
-- clerestories and shopfronts warm.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local City = require(ReplicatedStorage.Shared.Config.City)
local Kit = require(script.Parent.Parent.Parent.Kit)
local Types = require(script.Parent.Parent.Parent.Types)

local P = City.palettes
local KIT = City.kit
local rgb = Color3.fromRGB

-- The recipe, in studs.
local SHAPE = {
	sideInset = 3.6, -- the hipped ends overhang the halls by 3.2
	forecourt = 7, -- paving between the front line and the halls
	boardwalk = 10, -- along the back line
	deck = 0.6,
	plaza = { share = 0.3, min = 40, max = 76, offset = 0.05 }, -- its width and how far off-centre it sits
	hall = {
		minDepth = 18,
		maxDepth = 46,
		storey = 11, -- the ground floor; the gallery's floor stands on it
		eave = 21, -- the top of the walls: two storeys
		arcade = 6, -- the shops sit this far behind the posts, under the gallery
		overhang = 3.2, -- deep eaves at the front, back and outer end
		-- The ridge rises this much over the eaves at least, and at most this share of the half-depth (about 36
		-- degrees): what is left of the height under the clerestory decides it.
		rise = { min = 5, share = 0.72 },
		post = 1.6,
		postEvery = { 12, 9 }, -- by rhythm
		gallery = 0.8,
		rail = 3,
		gable = { inset = 1.2, proud = 0.12, rake = 0.8 }, -- the plaza gable: how deep, how proud, the metal rake
		oculus = { share = 0.84, rim = 1.4 }, -- the round window: its share of the gable's inscribed circle
		-- The clerestory on the ridge: its length (share of the ridge, by rhythm), depth (share of the hall's), glass
		-- height and cap.
		monitor = { share = { 0.45, 0.75 }, depth = 0.36, glass = 4, cap = 3.5 },
	},
	wheel = {
		max = 140, -- the rim's diameter, at most
		clearance = 11.5, -- the rim's lowest point over the ground (the bottom cabin hangs below it)
		rim = 3, -- thick and deep, so the ring reads as a truss from across the bay
		rimDepth = 4.4,
		segments = 24,
		spokes = { 6, 9 }, -- bars through the hub (each two spokes), by crown
		spoke = 0.7,
		pods = { 12, 16 },
		legZ = 9, -- each A-frame's feet stand this far in front of and behind the hub
		spread = 0.42, -- the feet land this share of the radius either side
		leg = 2.8,
		brace = { at = 0.3, thick = 1.4 }, -- the tie across each A, this share of the way up
		hub = 7,
		hubLength = 7.2,
		platform = 1.2,
	},
	pod = 7.2, -- the cabins: round drums on the outside of the rim...
	podLength = 8.4, -- ...this long across the wheel's plane (the rim is 4.4 deep)
	gate = { pylon = 2.6, height = 17, beam = { 12.5, 16 } },
	umbrella = 7.5,
	stringLights = { count = 3, height = 13, diameter = 0.35 },
	lamp = { height = 12 },
}

-- Roofs (left hall, right hall), clerestory caps, pods.
local PALETTES = {
	{
		roofs = { rgb(46, 156, 154), rgb(240, 110, 90) },
		clerestory = nil :: Color3?, -- nil: the hall's own roof colour
	},
	{
		roofs = { rgb(240, 110, 90), rgb(240, 110, 90) },
		clerestory = rgb(46, 156, 154) :: Color3?,
	},
	{
		roofs = { rgb(96, 172, 222), rgb(110, 204, 170) },
		clerestory = nil :: Color3?,
	},
}
local PODS = { P.deco.pink, P.deco.sky, P.deco.lemon, P.deco.mint, P.deco.lilac, P.deco.peach }
-- The wheel's neon (rim, spokes and the gateway sign's board), by crown: one colour, the eaves' blue the other.
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
	local mon = hl.monitor
	local ov = hl.overhang
	local rimKind = RIMS[crown]

	-------------------------------------------------------------------------------------------------------
	-- Layout: two halls either side of an off-centre plaza, the wheel behind the plaza, the boardwalk at the back
	-------------------------------------------------------------------------------------------------------
	local Wu = W - 2 * SHAPE.sideInset
	local pl = SHAPE.plaza
	local Pw = math.clamp(Wu * pl.share, pl.min, pl.max)
	local pc = Wu * pl.offset -- the plaza's centre
	local zF = -hd + SHAPE.forecourt
	local zBoard = hd - SHAPE.boardwalk
	local pd = math.clamp(zBoard - zF - 26, hl.minDepth, hl.maxDepth)
	pd = math.min(pd, zBoard - zF - 1)
	local zH1 = zF + pd
	local zc = (zF + zH1) / 2 -- the ridges
	local half = pd / 2

	-- The roof's section, from the top down: the clerestory's cap ends at the site's height, its glass sits down on
	-- the ridge, and the ridge rises over the eaves by whatever is left (within the pitch's limits).
	local clerBase = H - mon.cap
	local cd = pd * mon.depth
	local rise = (H - hl.eave + 0.3 - mon.glass - mon.cap) / (1 - mon.depth)
	rise = math.clamp(rise, hl.rise.min, half * hl.rise.share)
	local ridge = hl.eave + rise
	local pitch = rise / half
	local glassBottom = ridge - pitch * cd / 2 - 0.3 -- under the roof's surface at the clerestory's faces
	local y0 = hl.eave - pitch * ov -- the slopes' foot at the eaves' edge
	local hip = half + ov -- each hip corner is this square, so its slopes match the main ones

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
	-- One hall from x0 to x1, its plaza end on the right (+x) or the left.
	local function hall(name: string, x0: number, x1: number, roof: Color3, plazaRight: boolean)
		local L = x1 - x0
		local zS = zF + hl.arcade -- the shopfronts
		local roofLook = Kit.look(roof, Enum.Material.Metal)
		local eave = hl.eave
		local glassWhite = rgb(250, 250, 248)
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
				lines = glassWhite,
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
				lines = glassWhite,
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
				lines = glassWhite,
				reflectance = 0.2,
			}
		)
		-- The end facing the plaza: a lit shopfront across its ground floor.
		local endFace = if plazaRight then Enum.NormalId.Right else Enum.NormalId.Left
		local endX = if plazaRight then x1 - 0.2 else x0 + 0.2
		local ex0, ex1 = endX - 0.3, endX + 0.08
		if not plazaRight then
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
				faces = { endFace },
				u = 4,
				v = hl.storey - 1.3,
				lines = glassWhite,
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
		local postZ = zF + 0.3
		for k = 1, count do
			local x = x0 + 1 + (L - 2) * (k - 1) / (count - 1)
			Kit.box(
				m,
				`{name}Post{k}`,
				Vector3.new(x - hl.post / 2, 0.2, postZ),
				Vector3.new(x + hl.post / 2, eave, postZ + hl.post),
				WHITE
			)
		end

		-- The roof: two long slopes from the hipped outer end to the plaza end, two hip corners at the outer end, and a
		-- white gable infill at the plaza end standing a hair proud of the slopes' ends (their metal shows only as a
		-- thin rake along its edges and a fascia under it).
		local z0, z1 = zF - ov, zH1 + ov
		local xa: number, xb: number -- the slopes' run along x
		if plazaRight then
			xa, xb = x0 - ov + hip, x1
		else
			xa, xb = x0, x1 + ov - hip
		end
		Kit.wedge(m, `{name}RoofF`, Vector3.new(xa, y0, z0), Vector3.new(xb, ridge, zc), "back", roofLook)
		Kit.wedge(m, `{name}RoofB`, Vector3.new(xa, y0, zc), Vector3.new(xb, ridge - 0.04, z1), "front", roofLook)
		if plazaRight then
			local ex = x0 - ov
			Kit.cornerWedge(
				m,
				`{name}HipF`,
				Vector3.new(ex, y0, z0),
				Vector3.new(ex + hip, ridge, z0 + hip),
				"br",
				roofLook
			)
			Kit.cornerWedge(
				m,
				`{name}HipB`,
				Vector3.new(ex, y0, z1 - hip),
				Vector3.new(ex + hip, ridge, z1),
				"fr",
				roofLook
			)
		else
			local ex = x1 + ov
			Kit.cornerWedge(
				m,
				`{name}HipF`,
				Vector3.new(ex - hip, y0, z0),
				Vector3.new(ex, ridge, z0 + hip),
				"bl",
				roofLook
			)
			Kit.cornerWedge(
				m,
				`{name}HipB`,
				Vector3.new(ex - hip, y0, z1 - hip),
				Vector3.new(ex, ridge, z1),
				"fl",
				roofLook
			)
		end
		local gb = hl.gable
		local apex = ridge - gb.rake
		local gx0: number, gx1: number, face: number
		if plazaRight then
			gx0, gx1, face = x1 - gb.inset, x1 + gb.proud, x1 + gb.proud
		else
			gx0, gx1, face = x0 - gb.proud, x0 + gb.inset, x0 - gb.proud
		end
		Kit.wedge(m, `{name}GableF`, Vector3.new(gx0, eave, zF), Vector3.new(gx1, apex, zc), "back", WHITE, "trim")
		Kit.wedge(
			m,
			`{name}GableB`,
			Vector3.new(gx0, eave, zc),
			Vector3.new(gx1, apex - 0.03, zH1),
			"front",
			WHITE,
			"trim"
		)
		-- The gable's round window in a white rim, lit at night: as big as the triangle holds.
		local th = apex - eave
		local inner = half * th / (half + math.sqrt(half * half + th * th))
		local od = 2 * inner * hl.oculus.share
		local oy = eave + inner
		local out = if plazaRight then 1 else -1
		Kit.tube(
			m,
			`{name}OculusRim`,
			Vector3.new(face - out * 0.3, oy, zc),
			Vector3.new(face + out * 0.25, oy, zc),
			od,
			WHITE,
			"trim"
		)
		Kit.lit(
			Kit.tube(
				m,
				`{name}Oculus`,
				Vector3.new(face - out * 0.2, oy, zc),
				Vector3.new(face + out * 0.35, oy, zc),
				od - hl.oculus.rim,
				Kit.glassLook(P.window.dark, 0.2),
				"detail"
			),
			"window"
		)
		-- The blue LED line under the front eave.
		local lx0 = if plazaRight then x0 - ov else x0
		local lx1 = if plazaRight then x1 else x1 + ov
		Kit.neonStrip(
			m,
			`{name}Led`,
			Vector3.new(lx0, y0 - 0.45, z0 - 0.1),
			Vector3.new(lx1, y0 - 0.05, z0 + 0.3),
			"ledBlue",
			roof
		)
		-- The clerestory on the ridge, between the hip and the gable: lit glass under its own small gable cap.
		local r0, r1 = xa + 1.5, xb - 2.5
		local cLen = (r1 - r0) * mon.share[rhythm]
		if cLen > 6 then
			local cm = (r0 + r1) / 2
			local c0, c1 = cm - cLen / 2, cm + cLen / 2
			Kit.glass(
				m,
				`{name}Clerestory`,
				Vector3.new(c0, glassBottom, zc - cd / 2),
				Vector3.new(c1, clerBase, zc + cd / 2),
				P.window.dark,
				{
					image = City.textures.windowBold,
					faces = { Enum.NormalId.Front, Enum.NormalId.Back },
					u = 3,
					v = clerBase - glassBottom,
					lines = glassWhite,
					lit = true,
				}
			)
			local clerLook = Kit.look(pal.clerestory or roof, Enum.Material.Metal)
			Kit.wedge(
				m,
				`{name}ClerRoofF`,
				Vector3.new(c0 - 0.8, clerBase, zc - cd / 2 - 0.8),
				Vector3.new(c1 + 0.8, H, zc),
				"back",
				clerLook,
				"trim"
			)
			Kit.wedge(
				m,
				`{name}ClerRoofB`,
				Vector3.new(c0 - 0.8, clerBase, zc),
				Vector3.new(c1 + 0.8, H - 0.04, zc + cd / 2 + 0.8),
				"front",
				clerLook,
				"trim"
			)
		end
	end

	local px0, px1 = pc - Pw / 2, pc + Pw / 2
	hall("HallL", -Wu / 2, px0, pal.roofs[1], true)
	hall("HallR", px1, Wu / 2, pal.roofs[2], false)

	-------------------------------------------------------------------------------------------------------
	-- The plaza: a lit gateway sign at its mouth, strings of lights, market umbrellas
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
		City.signNames.civic.market,
		pal.roofs[1],
		rgb(250, 250, 248),
		City.districtLooks.beach.font,
		rimKind
	)
	-- Strings of bulbs across the plaza from hall to hall, warm at night.
	local sl = SHAPE.stringLights
	for i = 1, sl.count do
		local z = zF + 0.75 * pd * i / (sl.count + 1) -- the front of the plaza, clear of a squeezed wheel
		local y = sl.height + (i % 2) * 1.2
		Kit.neon(
			m,
			`Lights{i}`,
			Vector3.new(px0 + 0.4, y, z),
			Vector3.new(px1 - 0.4, y, z),
			"streetlight",
			rgb(255, 236, 196),
			sl.diameter
		)
	end
	local umbrellaZ = zF + math.min(pd * 0.25, 12) -- the plaza's front, clear of a squeezed wheel's A-frame
	for i, at in { -0.3, 0, 0.3 } do
		local color = if i == 2 then P.deco.white else pal.roofs[1]
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
	-- The wheel: a thick rim of segments on spokes round a hub, two braced A-frames, cabins
	-------------------------------------------------------------------------------------------------------
	local wh = SHAPE.wheel
	local room = zBoard - zH1
	local free = room >= 2 * wh.legZ + ov + 4
	-- Behind the halls, its front feet clear of their back eaves; else squeezed between them at the back.
	local wz = if free then zH1 + ov + wh.legZ + 2 else zBoard - wh.legZ - 1
	wz = math.clamp(wz, -hd + wh.legZ + 2, hd - wh.legZ - 2)
	local wx = pc
	local podOut = wh.rim / 2 + SHAPE.pod + 0.2 -- the cabins reach this far outside the rim's centre line
	local r = (site.maxHeight - 1 - wh.clearance - podOut) / 2
	r = math.min(r, wh.max / 2, hw - math.abs(wx) - podOut - 2)
	if not free then
		r = math.min(r, Pw / 2 - 1 - podOut) -- squeezed between the halls
	end
	local wy = wh.clearance + r

	Kit.box(
		m,
		"Platform",
		Vector3.new(wx - r * wh.spread - 3, 0.15, wz - wh.legZ - 1.5),
		Vector3.new(wx + r * wh.spread + 3, wh.platform, wz + wh.legZ + 1.5),
		Kit.look(P.concrete.pale, Enum.Material.Concrete)
	)
	-- The rim: segments tangent to the circle, long enough that their outer corners meet.
	local n = wh.segments
	local rc = r * math.cos(math.pi / n)
	local chord = 2 * (rc + wh.rim / 2) * math.tan(math.pi / n) + 0.1
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
		local a = math.pi * (k + 0.5) / bars
		Kit.lit(
			Kit.oriented(
				m,
				`Spoke{k + 1}`,
				"block",
				CFrame.new(wx, wy, wz) * CFrame.Angles(0, 0, a),
				Vector3.new(2 * rc - wh.rim, wh.spoke, wh.spoke),
				WHITE,
				"detail"
			),
			rimKind
		)
	end
	local hubHalf = wh.hubLength / 2
	Kit.tube(m, "Hub", Vector3.new(wx, wy, wz - hubHalf), Vector3.new(wx, wy, wz + hubHalf), wh.hub, WHITE, "trim")
	-- Two A-frames, one in front of the rim and one behind, each two legs from the hub's end to the platform and a
	-- tie across them.
	local br = wh.brace
	for j, sz in { -1, 1 } do
		local top = Vector3.new(wx, wy, wz + sz * (hubHalf - 0.6))
		local feet: { Vector3 } = {}
		for i, sx in { -1, 1 } do
			local foot = Vector3.new(wx + sx * r * wh.spread, wh.platform, wz + sz * wh.legZ)
			table.insert(feet, foot)
			Kit.strut(m, `Leg{j}{i}`, top, foot, wh.leg, WHITE)
		end
		local a = feet[1] + (top - feet[1]) * br.at
		local b = feet[2] + (top - feet[2]) * br.at
		Kit.strut(m, `Brace{j}`, a, b, br.thick, WHITE, "trim")
	end
	-- The cabins: short drums across the rim's plane (a capsule seen from an angle, a round cabin face-on), each
	-- sunk a little into the rim's outer face so it hangs on it, not floating beside it.
	local pods = wh.pods[crown]
	local pr = rc + wh.rim / 2 + SHAPE.pod / 2 - 0.4
	local podHalf = SHAPE.podLength / 2
	for k = 0, pods - 1 do
		local theta = 2 * math.pi * k / pods
		local cx, cy = wx + pr * math.cos(theta), wy + pr * math.sin(theta)
		Kit.tube(
			m,
			`Pod{k + 1}`,
			Vector3.new(cx, cy, wz - podHalf),
			Vector3.new(cx, cy, wz + podHalf),
			SHAPE.pod,
			Kit.look(PODS[k % #PODS + 1], Enum.Material.SmoothPlastic),
			"trim"
		)
	end
end

local archetype: Types.Archetype = { id = "harbor_market_pavilions", build = build }
return archetype
