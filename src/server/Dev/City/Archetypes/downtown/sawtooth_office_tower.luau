--!strict
-- T05 sawtooth_office_tower (docs/city/ARCHETYPES.md §5, T05): downtown's one-off stone office tower. A pale granite
-- tower gridded with square dark windows, one front corner cut into a staircase of teeth that climbs from the
-- street to the sky: every tooth is set back a step from the next in plan and tops out a few floors lower, so the
-- corner reads as a zig-zag from the plaza and the roofline as a staircase from across downtown. A dark V-notch runs
-- down the middle of the street face with a light in its crease and the entrance at its foot, over a granite
-- colonnade. Beside it, across a granite plaza under a white space-frame canopy, a stone parking annex with stair
-- towers, joined to the tower by a glass skybridge.
--
-- What makes it itself: the zig-zag corner climbing to a stepped top, and the glowing notch.
-- Placement, sizes, heights and its budget: Config/CityArchetypes/sawtooth_office_tower.
-- Variants: palette (3 stone and glass sets), crown (1 a plant room and a mast with a red light, 2 a glass saw-roof on
-- every tooth), rhythm (1 four wide teeth dropping three floors each, 2 six narrow ones dropping two), mirror (which
-- end takes the annex and which the tower).
--
-- Preview check (the Studio step): from the street and from the plaza side the teeth read as a staircase both in
-- plan (alternating sun and shade, a white pier on every tooth's corner) and against the sky; the window grid lines
-- up floor by floor across the teeth (every top is a whole number of floors under the roof); the notch is a dark
-- crease with its strip lit at night; the teeth's windows glow at night as a lit staircase; the colonnade's piers
-- stand clear under the stone fascia; the space frame reads as a white grid from under it and its wash lights it at
-- night; the skybridge meets a tooth's face (not air) at 46 and 110 deep; nothing pokes past the footprint at 140 and
-- 240 wide, 46, 53 and 110 deep. Compare with photos of the real tower's sawtooth corner.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local City = require(ReplicatedStorage.Shared.Config.City)
local Kit = require(script.Parent.Parent.Parent.Kit)
local Types = require(script.Parent.Parent.Parent.Types)

local P = City.palettes
local KIT = City.kit
local rgb = Color3.fromRGB

local FRONT, BACK = Enum.NormalId.Front, Enum.NormalId.Back
local LEFT, RIGHT = Enum.NormalId.Left, Enum.NormalId.Right

-- The recipe, in studs.
local SHAPE = {
	floor = 12,
	lobby = 16, -- the colonnade under the main block
	edge = 1.5, -- the site's ends to the annex and the tower
	towerShare = 0.42, -- the tower's width, share of the site's...
	towerWidth = { 72, 100 }, -- ...between these
	annexShare = 0.22,
	annexWidth = { 30, 56 },
	gap = 3, -- the plaza's sides to the annex and the tower
	towerBack = 2, -- the tower's back face from the back line
	frontRoom = 12, -- a forecourt at least this deep
	towerDepth = { 34, 80 },
	teeth = { 4, 6 }, -- by rhythm
	tooth = { 0.11, 0.075 }, -- a tooth's width (and set-back), share of the tower's width, by rhythm...
	toothWidth = { 4, 10 }, -- ...between these
	toothKeep = 14, -- the outermost tooth keeps at least this deep (when there is room)
	-- Each tooth tops out this share of the height (whole floors) under the next: the staircase takes the top quarter
	-- or so, as the real tower's setbacks do (Studio round 1: 0.075 and 0.05 read as a leaning ramp from afar; round 2:
	-- 0.04 rounded six narrow teeth down to a floor each, too faint to see).
	dropShare = { 0.065, 0.045 },
	notchHalf = 4, -- the V-notch: 8 wide at the face...
	notchDeep = 8, -- ...and 8 deep
	bay = 7.6, -- one square window a bay and a floor (the punched tile's opening is 88 % by 56 %)
	cap = { thick = 1.6, proud = 0.9 },
	ringDrop = 0.5, -- the LED ring sits this far under a cap
	pier = { wide = 1.8, proud = 0.6 }, -- white stone piers on the free corners
	fascia = { thick = 2.4, proud = 0.8 }, -- the stone band over the colonnade
	colonnade = { column = 2.2, every = 16 },
	lobbyInset = 4, -- the lobby glass sits this far in under the main block
	canopy = { y = 12.6, thick = 1.4, half = 10, reach = 7 },
	frame = { height = 31, rim = 2.2, depth = 40, beam = 0.8 }, -- the plaza's space-frame canopy
	column = 1.6,
	saw = 0.6, -- crown 2: a tooth's glass saw-roof rises this share of the drop
	plant = 9, -- the main roof's plant room
	mast = 34,
	level = 10, -- a parking level
	slots = 3, -- garage openings across the annex's front
	annexShareH = 0.28, -- the annex's height, share of the tower's (whole levels)...
	annexHeight = { 70, 150 }, -- ...between these
	annexFront = 4, -- the annex's face behind the front line
	stairTower = { wide = 8, proud = 2, over = 6 }, -- the annex's corner stair towers
	bridge = { y0 = 17, y1 = 25, deep = 10, back = 3 }, -- the skybridge to the tower
}

-- Stone, window glass, white trim, the annex's openings. The first is the photos' silver-grey granite with windows
-- that hold the sky's blue (Studio round 1: near-white stone and navy windows read as a white office grid).
local PALETTES = {
	{ stone = rgb(212, 210, 204), glass = rgb(62, 88, 116), trim = rgb(246, 244, 238), annex = P.concrete.dark },
	{ stone = rgb(214, 204, 186), glass = P.glass.navy, trim = rgb(240, 234, 222), annex = rgb(44, 40, 38) },
	{ stone = rgb(234, 236, 236), glass = rgb(70, 96, 118), trim = P.frame.white, annex = rgb(52, 60, 68) },
}

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
	local stone = Kit.look(pal.stone, Enum.Material.SmoothPlastic)
	local trim = Kit.look(pal.trim, Enum.Material.SmoothPlastic)
	local granite = Kit.look(pal.stone:Lerp(rgb(150, 146, 140), 0.25), Enum.Material.Granite)
	local white = Kit.look(P.frame.white, Enum.Material.SmoothPlastic)
	local tag = City.signNames.towers[rng:NextInteger(1, #City.signNames.towers)]

	-- Stone with square punched windows: tiles count down from each part's top, so every top is a floor line.
	local function stoneGrid(name: string, min: Vector3, max: Vector3, faces: { Enum.NormalId }, lit: boolean?)
		return Kit.punched(m, name, min, max, pal.stone, pal.glass, faces, SHAPE.bay, F, lit)
	end

	-------------------------------------------------------------------------------------------------------
	-- The plan, along the road: annex | plaza | tower. The tower's front-left corner (toward the plaza) is the
	-- staircase of teeth; the main block stands to its right
	-------------------------------------------------------------------------------------------------------
	local tw = math.clamp(W * SHAPE.towerShare, SHAPE.towerWidth[1], SHAPE.towerWidth[2])
	local aw = math.clamp(W * SHAPE.annexShare, SHAPE.annexWidth[1], SHAPE.annexWidth[2])
	local ax0 = -hw + SHAPE.edge
	local ax1 = ax0 + aw
	local tx1 = hw - SHAPE.edge
	local tx0 = tx1 - tw
	local px0, px1 = ax1 + SHAPE.gap, tx0 - SHAPE.gap -- the plaza
	local zB = hd - SHAPE.towerBack
	local td = math.clamp(D - SHAPE.frontRoom, SHAPE.towerDepth[1], SHAPE.towerDepth[2])
	local zF = zB - td

	local N = SHAPE.teeth[rhythm]
	local s = math.clamp(
		math.min(tw * SHAPE.tooth[rhythm], (td - SHAPE.toothKeep) / N),
		SHAPE.toothWidth[1],
		SHAPE.toothWidth[2]
	)
	local mx0 = tx0 + N * s -- the main block's left side, where the staircase ends
	local drop = F * math.max(1, math.round(H * SHAPE.dropShare[rhythm] / F))
	local nh, nd = SHAPE.notchHalf, SHAPE.notchDeep
	local xn = (mx0 + tx1) / 2 -- the notch's crease
	local L = SHAPE.lobby

	-------------------------------------------------------------------------------------------------------
	-- The main block: two stone halves either side of the V-notch and a spine behind it, over a colonnade
	-------------------------------------------------------------------------------------------------------
	stoneGrid("MainL", Vector3.new(mx0, L, zF), Vector3.new(xn - nh, H, zB), { FRONT, LEFT, BACK })
	stoneGrid("MainR", Vector3.new(xn + nh, L, zF), Vector3.new(tx1, H, zB), { FRONT, RIGHT, BACK })
	stoneGrid("Spine", Vector3.new(xn - nh, L, zF + nd), Vector3.new(xn + nh, H, zB), { BACK })
	-- The V: two dark glass prisms meeting in a crease, from the fascia to the roof.
	local smoke = Kit.glassLook(P.glass.smoke, 0.2)
	Kit.prism(m, "NotchL", Vector3.new(xn - nh, L, zF), Vector3.new(xn, H, zF + nd), "bl", smoke)
	Kit.prism(m, "NotchR", Vector3.new(xn, L, zF), Vector3.new(xn + nh, H, zF + nd), "br", smoke)
	-- The light in the crease: white by day, a cool glow at night, standing out of both glass faces.
	local ct, cp = SHAPE.cap.thick, SHAPE.cap.proud
	Kit.neonStrip(
		m,
		"NotchLight",
		Vector3.new(xn - 0.5, L + SHAPE.fascia.thick + 1, zF + nd - 1.7),
		Vector3.new(xn + 0.5, H - ct - 1, zF + nd - 0.1),
		"crown",
		pal.trim
	)

	-- White stone piers on the main block's free corners: crisp edges against the sky.
	local pw, pp = SHAPE.pier.wide, SHAPE.pier.proud
	local pierTop = H - ct + 0.1
	Kit.trim(m, "PierML", Vector3.new(mx0 - pp, L, zF - pp), Vector3.new(mx0 + pw - pp, pierTop, zF + pw - pp), trim)
	Kit.trim(m, "PierMR", Vector3.new(tx1 - pw + pp, L, zF - pp), Vector3.new(tx1 + pp, pierTop, zF + pw - pp), trim)
	Kit.trim(m, "PierBR", Vector3.new(tx1 - pw + pp, L, zB - pw + pp), Vector3.new(tx1 + pp, pierTop, zB + pp), trim)

	-------------------------------------------------------------------------------------------------------
	-- The street level: a lit glass lobby set in under the main block, granite piers along its front, a stone
	-- fascia over them, the entrance at the foot of the notch with a canopy and the name
	-------------------------------------------------------------------------------------------------------
	local li = SHAPE.lobbyInset
	local lobbyGlass = rgb(44, 60, 70)
	Kit.glass(m, "Lobby", Vector3.new(mx0 + 2, yb, zF + li), Vector3.new(tx1 - 3, L + 0.3, zB - 3), lobbyGlass, {
		image = City.textures.windowBold,
		faces = { FRONT, LEFT, RIGHT },
		u = 5,
		v = L + 1.3,
		lines = pal.trim,
		lit = true,
	})
	local fa = SHAPE.fascia
	Kit.trim(
		m,
		"Fascia",
		Vector3.new(mx0 - 0.3, L - 0.06, zF - fa.proud),
		Vector3.new(tx1 + fa.proud, L + fa.thick, zB + fa.proud),
		stone
	)
	-- Granite piers: the main block's corners, either side of the entrance, and one in each half when there's room.
	local cc = SHAPE.colonnade
	local spots = { mx0 + 1.2, xn - nh - 1.4, xn + nh + 1.4, tx1 - 1.2 }
	if xn - nh - mx0 > 2 * cc.every then
		table.insert(spots, (mx0 + xn - nh) / 2)
	end
	if tx1 - xn - nh > 2 * cc.every then
		table.insert(spots, (xn + nh + tx1) / 2)
	end
	for i, x in spots do
		local h = cc.column / 2
		Kit.box(
			m,
			`Colonnade{i}`,
			Vector3.new(x - h, yb, zF + 0.1),
			Vector3.new(x + h, L + 0.05, zF + 0.1 + cc.column),
			granite
		)
	end
	local cn = SHAPE.canopy
	local canopyFront = zF - cn.reach
	Kit.canopy(m, "Canopy", xn - cn.half, xn + cn.half, canopyFront, zF + li - 0.4, cn.y, cn.thick, trim)
	local canopyTop = cn.y + cn.thick
	Kit.sign(
		m,
		"Name",
		Vector3.new(xn - cn.half * 0.7, canopyTop, canopyFront + 0.3),
		Vector3.new(xn + cn.half * 0.7, canopyTop + 2.4, canopyFront + 0.8),
		FRONT,
		tag,
		rgb(40, 44, 50),
		pal.trim,
		City.districtLooks.downtown.font
	)
	Kit.neonStrip(
		m,
		"CanopyLed",
		Vector3.new(xn - cn.half, cn.y - 0.25, canopyFront + 0.1),
		Vector3.new(xn + cn.half, cn.y - 0.05, canopyFront + 0.7),
		"ledBlue",
		pal.trim
	)

	-------------------------------------------------------------------------------------------------------
	-- The staircase: N teeth, each set back a tooth from the next in plan and topping out a drop lower; their windows
	-- glow at night, a lit zig-zag up the corner
	-------------------------------------------------------------------------------------------------------
	local ringY = ct + SHAPE.ringDrop
	-- A cap and an LED ring on a mass from x0 (its free left side) to x1 (against a taller neighbour), its front at z0.
	local function capAndRing(name: string, x0: number, x1: number, z0: number, top: number)
		Kit.trim(
			m,
			name .. "Cap",
			Vector3.new(x0 - cp, top - ct + 0.06, z0 - cp),
			Vector3.new(x1 + 0.3, top + 0.06, zB + cp),
			trim
		)
		Kit.neonStrip(
			m,
			name .. "Ring",
			Vector3.new(x0 - 0.15, top - ringY - 0.4, z0 - 0.15),
			Vector3.new(x1 + 0.15, top - ringY, zB + 0.15),
			"ledEdge",
			pal.trim
		)
	end

	local glassRoof = Kit.glassLook(P.glass.silver, 0.25)
	local toothFront: { number } = {}
	for k = 0, N - 1 do
		-- Tooth 1 is the outermost (the lowest, at the tower's left face); tooth N stands against the main block.
		local x0, x1 = tx0 + k * s, tx0 + (k + 1) * s
		local z0 = zF + (N - k) * s
		local top = H - (N - k) * drop
		local name = `Tooth{k + 1}`
		toothFront[k + 1] = z0
		stoneGrid(name, Vector3.new(x0, yb, z0), Vector3.new(x1, top, zB), { FRONT, LEFT }, true)
		Kit.trim(
			m,
			name .. "Pier",
			Vector3.new(x0 - pp, yb, z0 - pp),
			Vector3.new(x0 + pw - pp, top - ct + 0.1, z0 + pw - pp),
			trim
		)
		capAndRing(name, x0, x1, z0, top)
		if variant.crown == 2 then
			-- A glass saw-roof rising toward the taller neighbour: the stepped top becomes a row of saw teeth.
			Kit.wedge(
				m,
				name .. "Saw",
				Vector3.new(x0, top + 0.06, z0),
				Vector3.new(x1, top + 0.06 + SHAPE.saw * drop, zB),
				"right",
				glassRoof,
				"trim"
			)
		end
	end
	capAndRing("Main", mx0, tx1 + cp - 0.3, zF, H)

	-- The main roof: a plant room, and with crown 1 a mast with a red light.
	local plantTop = H + 0.06 + SHAPE.plant
	local mw = tx1 - mx0
	Kit.roofBox(
		m,
		"Plant",
		Vector3.new(mx0 + 5, H + 0.06, zF + nd + 4),
		Vector3.new(tx1 - 5, plantTop, zB - 5),
		Kit.look(pal.stone:Lerp(rgb(170, 170, 170), 0.3), Enum.Material.SmoothPlastic)
	)
	if variant.crown == 1 then
		Kit.spire(
			m,
			"Mast",
			(mx0 + tx1) / 2 + math.min(6, mw / 2 - 6),
			(zF + nd + 4 + zB - 5) / 2,
			plantTop,
			SHAPE.mast,
			1.4,
			Kit.look(rgb(196, 200, 206), Enum.Material.Metal),
			2,
			true
		)
	end

	-------------------------------------------------------------------------------------------------------
	-- The parking annex: stone punched with wide garage openings, two stone stair towers at its front corners, a
	-- granite base, a white cap with an LED line, and a lit glass skybridge to the outermost tooth
	-------------------------------------------------------------------------------------------------------
	local lv = SHAPE.level
	local ah = math.clamp(lv * math.round(H * SHAPE.annexShareH / lv), SHAPE.annexHeight[1], SHAPE.annexHeight[2])
	local az0, az1 = -hd + SHAPE.annexFront, hd - 1.5
	Kit.punched(
		m,
		"Annex",
		Vector3.new(ax0, yb, az0),
		Vector3.new(ax1, ah, az1),
		pal.stone,
		pal.annex,
		{ FRONT, LEFT, RIGHT },
		aw / SHAPE.slots,
		lv
	)
	Kit.trim(m, "AnnexBase", Vector3.new(ax0 - 0.5, yb, az0 - 0.5), Vector3.new(ax1 + 0.5, lv, az1 + 0.5), granite)
	Kit.trim(
		m,
		"AnnexCap",
		Vector3.new(ax0 - 0.6, ah - 0.6, az0 - 0.6),
		Vector3.new(ax1 + 0.6, ah + 1, az1 + 0.6),
		trim
	)
	Kit.neonStrip(
		m,
		"AnnexLed",
		Vector3.new(ax0 + 0.5, ah - 1.3, az0 - 0.3),
		Vector3.new(ax1 - 0.5, ah - 0.8, az0 + 0.1),
		"ledBlue",
		pal.trim
	)
	local st = SHAPE.stairTower
	Kit.box(
		m,
		"StairL",
		Vector3.new(ax0, yb, az0 - st.proud),
		Vector3.new(ax0 + st.wide, ah + st.over, az0 + st.wide),
		stone
	)
	Kit.box(
		m,
		"StairR",
		Vector3.new(ax1 - st.wide, yb, az0 - st.proud),
		Vector3.new(ax1, ah + st.over, az0 + st.wide),
		stone
	)
	-- The skybridge meets the outermost tooth's side behind its front (never air), over the plaza's back.
	local br = SHAPE.bridge
	local bz1 = zB - br.back
	local bz0 = math.max(bz1 - br.deep, toothFront[1] + 1)
	local bridged = bz1 - bz0 >= 4 and bz0 >= az0 + 1
	if bridged then
		Kit.glass(
			m,
			"Skybridge",
			Vector3.new(ax1 - 0.5, br.y0, bz0),
			Vector3.new(tx0 + 0.5, br.y1, bz1),
			P.glass.smoke,
			{
				image = City.textures.windowBold,
				faces = { FRONT, BACK },
				u = 3,
				v = br.y1 - br.y0,
				lines = pal.trim,
				lit = true,
			}
		)
	end

	-------------------------------------------------------------------------------------------------------
	-- The plaza: granite paving, a white space frame on columns (a glass sheet gridded both ways under a rim and
	-- chords), lit from below at night by one wash; planters along the forecourt
	-------------------------------------------------------------------------------------------------------
	Kit.detail(m, "Paving", Vector3.new(ax1 + 0.2, 0, -hd + 0.5), Vector3.new(hw - 0.5, 0.3, hd - 0.5), granite)
	local fr = SHAPE.frame
	local fx0, fx1 = px0 + 1, px1 - 1
	local fz0 = -hd + 2
	-- In front of the skybridge, so no column stands in its way.
	local fz1 = math.min(hd - 2, fz0 + fr.depth, if bridged then bz0 - 2 else math.huge)
	local fy = fr.height
	Kit.glass(
		m,
		"FrameGlass",
		Vector3.new(fx0 + 0.6, fy - 0.9, fz0 + 0.6),
		Vector3.new(fx1 - 0.6, fy - 0.6, fz1 - 0.6),
		P.glass.silver,
		{ image = City.textures.windowBold, faces = { Enum.NormalId.Bottom, Enum.NormalId.Top }, u = 5, v = 5 }
	)
	Kit.parapet(m, "Frame", Vector3.new(fx0, 0, fz0), Vector3.new(fx1, 0, fz1), fy - fr.rim, fr.rim, 1, white)
	-- The frame's depth: chords under the glass, two along z and one along x.
	local fb = fr.beam / 2
	for i = 1, 2 do
		local x = fx0 + (fx1 - fx0) * i / 3
		Kit.trim(
			m,
			`Chord{i}`,
			Vector3.new(x - fb, fy - fr.rim - 0.4, fz0 + 1),
			Vector3.new(x + fb, fy - 0.9, fz1 - 1),
			white
		)
	end
	local zm = (fz0 + fz1) / 2
	Kit.trim(
		m,
		"Chord3",
		Vector3.new(fx0 + 1, fy - fr.rim - 0.4, zm - fb),
		Vector3.new(fx1 - 1, fy - 0.9, zm + fb),
		white
	)
	local col = 0
	for _, x in { fx0 + 1.5, (fx0 + fx1) / 2, fx1 - 1.5 } do
		for _, z in { fz0 + 2.6, fz1 - 1.5 } do
			col += 1
			Kit.column(m, `Column{col}`, x, z, yb, fy - fr.rim, SHAPE.column, white)
		end
	end
	Kit.wash(m, "Wash", fx0 + 4, fx1 - 4, zm + 4, 0.3, rgb(220, 232, 255))
	-- Planters along the forecourt's front, either side of the entrance.
	local planter = Kit.look(pal.stone, Enum.Material.SmoothPlastic)
	local edge = -hd + 1.2
	Kit.planter(m, "PlanterL", Vector3.new(mx0 + 2, 0.3, edge), Vector3.new(mx0 + 11, 1.9, edge + 2), planter)
	Kit.planter(m, "PlanterR", Vector3.new(tx1 - 11, 0.3, edge), Vector3.new(tx1 - 2, 1.9, edge + 2), planter)
end

local archetype: Types.Archetype = { id = "sawtooth_office_tower", build = build }
return archetype
