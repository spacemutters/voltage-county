--!strict
-- T05 sawtooth_office_tower (docs/city/ARCHETYPES.md §5, T05): downtown's one-off office tower. A pale stone tower
-- gridded with square blue windows; one front corner is cut into a staircase of narrow teeth that runs from the
-- street to the sky, each tooth topping out lower than the one before it, so the top steps down into that corner.
-- A dark V-notch runs down the middle of its street face with a light in its crease and the entrance at its foot.
-- Beside it, a stone-clad parking annex joined by a glass skybridge; on the other side, a granite plaza under a white
-- space-frame canopy.
--
-- What makes it itself: the zig-zag corner climbing to a stepped top, and the glowing notch.
-- Placement, sizes, heights and its budget: Config/CityArchetypes/sawtooth_office_tower.
-- Variants: palette (3 stone and glass sets), crown (1 flat steps and a mast on the main roof, 2 a glass saw-roof on
-- every tooth), rhythm (1 four wide teeth, 2 six narrow ones), mirror (which end takes the annex and the plaza).
--
-- Seen in Studio 2026-10-25, day and night (docs/images/city/sawtooth_office_tower-day.jpg, -night.jpg).
-- Preview check: from the street and from the plaza side the teeth read as a staircase both
-- in plan (alternating sun and shade) and at the top; the window grid lines up floor by floor across the teeth (each
-- part's tiles count from its top, and every top is a whole floor below the roof); the notch is a dark crease with
-- its strip lit at night; the space frame reads as a white grid from under it; nothing pokes past the footprint at
-- 140 and 240 wide, 46 and 53 deep. Compare with the reference photos of the real tower's sawtooth corner.

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
	edge = 1.5, -- the site's ends to the annex and to the plaza's far side
	towerShare = 0.42, -- of the site's width...
	towerWidth = { 64, 96 }, -- ...between these
	annexShare = 0.24,
	annexWidth = { 34, 60 },
	annexGap = 3, -- between the annex and the tower
	annexFront = 4, -- the annex's face behind the front line
	annexShareH = 0.3, -- the annex's height, share of the tower's (whole levels)...
	annexHeight = { 70, 150 }, -- ...between these
	level = 10, -- a parking level
	slots = 3, -- garage openings across the annex's front: wide, low slots, not office windows
	towerBack = 2, -- the tower's back face from the back line
	frontRoom = 10, -- a forecourt at least this deep
	towerDepth = { 36, 70 },
	teeth = { 4, 6 }, -- by rhythm
	tooth = { 0.1, 0.075 }, -- a tooth's width, share of the tower's, by rhythm...
	toothWidth = { 4, 10 }, -- ...between these
	toothKeep = 14, -- the outermost tooth stays at least this deep (front to back) less the staircase
	dropShare = { 0.085, 0.055 }, -- each tooth tops out this share of the height (whole floors) under the last
	notchHalf = 3, -- the V-notch: 6 wide at the face...
	notchDeep = 6, -- ...and 6 deep
	notchFrom = 18, -- it starts over the entrance
	bay = 7.6, -- one square window a bay and a floor (the punched tile's opening is 88 % by 56 %)
	cap = { thick = 1.4, proud = 0.8 },
	ringDrop = 0.5, -- the LED ring sits this far under a cap
	pier = 2, -- stone corner piers...
	pierProud = 0.6, -- ...standing this far out
	belt = { y = 16, thick = 1.4, proud = 1.2 }, -- the stone band over the shopfronts
	canopy = { y = 12.6, thick = 1.4, half = 10, reach = 7 },
	frame = { height = 30, rim = 2.2, depth = 40, beam = 0.8 }, -- the plaza's space-frame canopy
	column = 1.6,
	saw = 0.6, -- crown 2: a tooth's glass saw-roof rises this share of the drop
	plant = 9, -- the main roof's plant room
	mast = 34,
	bridge = { y0 = 24, y1 = 33, z0 = 6, z1 = 18 }, -- the skybridge to the annex
}

-- Stone, window glass, white trim, the annex's openings.
local PALETTES = {
	{ stone = rgb(216, 210, 200), glass = rgb(64, 100, 130), trim = rgb(244, 242, 236), annex = P.concrete.dark },
	{ stone = rgb(206, 196, 178), glass = P.glass.navy, trim = rgb(238, 232, 220), annex = P.concrete.dark },
	{ stone = rgb(232, 232, 228), glass = P.glass.silver, trim = P.frame.white, annex = rgb(52, 60, 68) },
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
	local tag = City.signNames.towers[rng:NextInteger(1, #City.signNames.towers)]

	-- Stone with square punched windows: tiles count down from each part's top, so every top is a floor line.
	local function stoneGrid(name: string, min: Vector3, max: Vector3, faces: { Enum.NormalId }): Types.PartSpec
		return Kit.punched(m, name, min, max, pal.stone, pal.glass, faces, SHAPE.bay, F)
	end

	-------------------------------------------------------------------------------------------------------
	-- The plan: annex | tower | plaza along the road; the tower's front-right corner is the staircase
	-------------------------------------------------------------------------------------------------------
	local tw = math.clamp(W * SHAPE.towerShare, SHAPE.towerWidth[1], SHAPE.towerWidth[2])
	local aw = math.clamp(W * SHAPE.annexShare, SHAPE.annexWidth[1], SHAPE.annexWidth[2])
	local ax0 = -hw + SHAPE.edge
	local ax1 = ax0 + aw
	local tx0 = ax1 + SHAPE.annexGap
	local tx1 = tx0 + tw
	local zB = hd - SHAPE.towerBack
	local td = math.clamp(D - SHAPE.frontRoom, SHAPE.towerDepth[1], SHAPE.towerDepth[2])
	local zF = zB - td

	local N = SHAPE.teeth[rhythm]
	local s = math.clamp(
		math.min(tw * SHAPE.tooth[rhythm], (td - SHAPE.toothKeep) / N),
		SHAPE.toothWidth[1],
		SHAPE.toothWidth[2]
	)
	local mx1 = tx1 - N * s -- the main block's right side, where the staircase starts
	local drop = F * math.max(1, math.round(H * SHAPE.dropShare[rhythm] / F))
	local nh, nd = SHAPE.notchHalf, SHAPE.notchDeep
	local xn = (tx0 + mx1) / 2 -- the notch's crease

	-------------------------------------------------------------------------------------------------------
	-- The main block: two stone halves either side of the V-notch, a spine behind it
	-------------------------------------------------------------------------------------------------------
	stoneGrid("MainL", Vector3.new(tx0, yb, zF), Vector3.new(xn - nh, H, zB), { FRONT, LEFT, BACK })
	stoneGrid("MainR", Vector3.new(xn + nh, yb, zF), Vector3.new(mx1, H, zB), { FRONT, RIGHT, BACK })
	stoneGrid("Spine", Vector3.new(xn - nh, yb, zF + nd), Vector3.new(xn + nh, H, zB), { BACK })
	-- The V: two dark glass prisms meeting in a crease, from over the entrance to the roof.
	local smoke = Kit.glassLook(P.glass.smoke, 0.2)
	Kit.prism(m, "NotchL", Vector3.new(xn - nh, SHAPE.notchFrom, zF), Vector3.new(xn, H, zF + nd), "bl", smoke)
	Kit.prism(m, "NotchR", Vector3.new(xn, SHAPE.notchFrom, zF), Vector3.new(xn + nh, H, zF + nd), "br", smoke)
	-- The light in the crease: white by day, a cool glow at night, standing out of both glass faces.
	Kit.neonStrip(
		m,
		"NotchLight",
		Vector3.new(xn - 0.5, SHAPE.notchFrom + 1, zF + nd - 1.6),
		Vector3.new(xn + 0.5, H - SHAPE.cap.thick - 1, zF + nd - 0.1),
		"crown",
		pal.trim
	)

	-- Corner piers: a stone edge standing proud at the main block's free corners.
	local pw, pp = SHAPE.pier, SHAPE.pierProud
	local pierTop = H - SHAPE.cap.thick
	Kit.trim(m, "PierFL", Vector3.new(tx0 - pp, yb, zF - pp), Vector3.new(tx0 + pw - pp, pierTop, zF + pw - pp), stone)
	Kit.trim(m, "PierBL", Vector3.new(tx0 - pp, yb, zB - pw + pp), Vector3.new(tx0 + pw - pp, pierTop, zB + pp), stone)
	Kit.trim(m, "PierFR", Vector3.new(mx1 - pw + pp, yb, zF - pp), Vector3.new(mx1 + pp, pierTop, zF + pw - pp), stone)

	-------------------------------------------------------------------------------------------------------
	-- The street level: shopfronts under a stone belt, the entrance in the foot of the notch, a canopy and a name
	-------------------------------------------------------------------------------------------------------
	local belt = SHAPE.belt
	local lobbyGlass = rgb(44, 60, 70)
	for i, span in { { tx0 + 0.8, xn - nh - 0.8 }, { xn + nh + 0.8, mx1 - 0.8 } } do
		Kit.glass(
			m,
			`Shop{i}`,
			Vector3.new(span[1], 0.2, zF - 0.3),
			Vector3.new(span[2], belt.y - 0.6, zF + 0.05),
			lobbyGlass,
			{
				image = City.textures.windowBold,
				faces = { FRONT },
				u = 5,
				v = belt.y - 0.8,
				lines = pal.trim,
				lit = true,
			}
		)
	end
	Kit.glass(
		m,
		"Entrance",
		Vector3.new(xn - nh + 0.3, 0.2, zF + nd - 0.35),
		Vector3.new(xn + nh - 0.3, SHAPE.notchFrom - 0.4, zF + nd + 0.1),
		lobbyGlass,
		{
			image = City.textures.windowBold,
			faces = { FRONT },
			u = 2,
			v = SHAPE.notchFrom - 0.6,
			lines = pal.trim,
			lit = true,
		}
	)
	Kit.trim(
		m,
		"Belt",
		Vector3.new(tx0 - pp, belt.y, zF - belt.proud),
		Vector3.new(mx1 + pp, belt.y + belt.thick, zF + 0.5),
		stone
	)
	local cn = SHAPE.canopy
	local canopyFront = zF - cn.reach
	Kit.canopy(m, "Canopy", xn - cn.half, xn + cn.half, canopyFront, zF + nd - 0.4, cn.y, cn.thick, trim)
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
	-- The staircase: N teeth, each set back a tooth from the last in plan and topping out a drop lower
	-------------------------------------------------------------------------------------------------------
	local cp, ct = SHAPE.cap.proud, SHAPE.cap.thick
	local ringY = ct + SHAPE.ringDrop
	-- A cap on a mass (x0..x1 back to the back line, its front at z0); `wrapLeft` when its left side is free.
	local function capAndRing(name: string, x0: number, x1: number, z0: number, top: number, wrapLeft: boolean)
		local left = if wrapLeft then cp else 0
		Kit.trim(
			m,
			name .. "Cap",
			Vector3.new(x0 - left, top - ct + 0.06, z0 - cp),
			Vector3.new(x1 + cp, top + 0.06, zB + cp),
			trim
		)
		-- An LED band round the mass just under its cap: a lit line on every free face at night.
		Kit.neonStrip(
			m,
			name .. "Ring",
			Vector3.new(x0 - 0.15, top - ringY - 0.4, z0 - 0.15),
			Vector3.new(x1 + 0.15, top - ringY, zB + 0.15),
			"ledBlue",
			pal.trim
		)
	end
	capAndRing("Main", tx0, mx1, zF, H, true)

	local glassRoof = Kit.glassLook(P.glass.silver, 0.25)
	for k = 0, N - 1 do
		-- Tooth 1 is the outermost (the lowest, at the tower's right face); tooth N stands against the main block.
		local x0, x1 = tx1 - (k + 1) * s, tx1 - k * s
		local z0 = zF + (N - k) * s
		local top = H - (N - k) * drop
		local name = `Tooth{k + 1}`
		stoneGrid(name, Vector3.new(x0, yb, z0), Vector3.new(x1, top, zB), { FRONT, RIGHT })
		capAndRing(name, x0, x1, z0, top, false)
		if variant.crown == 2 then
			-- A glass saw-roof rising toward the taller neighbour: the stepped top becomes a row of saw teeth.
			Kit.wedge(
				m,
				name .. "Saw",
				Vector3.new(x0, top + 0.06, z0),
				Vector3.new(x1, top + 0.06 + SHAPE.saw * drop, zB),
				"left",
				glassRoof,
				"trim"
			)
		end
	end

	-- The main roof: a plant room, and with crown 1 a mast with a red light.
	local plantTop = H + 0.06 + SHAPE.plant
	Kit.roofBox(
		m,
		"Plant",
		Vector3.new(tx0 + 5, H + 0.06, zF + nd + 4),
		Vector3.new(mx1 - 5, plantTop, zB - 5),
		Kit.look(pal.stone:Lerp(rgb(170, 170, 170), 0.3), Enum.Material.SmoothPlastic)
	)
	if variant.crown == 1 then
		Kit.spire(
			m,
			"Mast",
			(tx0 + mx1) / 2 + 6,
			(zF + nd + zB) / 2,
			plantTop,
			SHAPE.mast,
			1.4,
			Kit.look(rgb(196, 200, 206), Enum.Material.Metal),
			2,
			true
		)
	end

	-------------------------------------------------------------------------------------------------------
	-- The parking annex: a stone box punched with garage openings, a base, a cap with an LED line, a skybridge
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
		{ FRONT, LEFT },
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
		Vector3.new(ax0 + 0.5, ah - 1.2, az0 - 0.35),
		Vector3.new(ax1 - 0.5, ah - 0.8, az0 - 0.05),
		"ledBlue",
		pal.trim
	)
	local br = SHAPE.bridge
	Kit.glass(
		m,
		"Skybridge",
		Vector3.new(ax1 - 0.5, br.y0, zF + br.z0),
		Vector3.new(tx0 + 0.5, br.y1, zF + br.z1),
		P.glass.smoke,
		{ image = City.textures.windowBold, faces = { FRONT }, u = 3, v = br.y1 - br.y0, lines = pal.trim, lit = true }
	)

	-------------------------------------------------------------------------------------------------------
	-- The plaza: granite paving from the annex to the far end, a white space frame on columns, planters
	-------------------------------------------------------------------------------------------------------
	local px0, px1 = tx1 + 2, hw - SHAPE.edge
	Kit.detail(m, "Paving", Vector3.new(tx0 - 2.5, 0, -hd + 0.5), Vector3.new(px1, 0.3, hd - 0.5), granite)
	local fr = SHAPE.frame
	local fx0, fx1 = px0 + 2, px1 - 1
	local fz0 = -hd + 2
	local fz1 = math.min(hd - 2, fz0 + fr.depth)
	local fy = fr.height
	local white = Kit.look(P.frame.white, Enum.Material.SmoothPlastic)
	Kit.glass(
		m,
		"FrameGlass",
		Vector3.new(fx0 + 0.6, fy - 0.9, fz0 + 0.6),
		Vector3.new(fx1 - 0.6, fy - 0.6, fz1 - 0.6),
		P.glass.silver,
		{ image = City.textures.windowBold, faces = { Enum.NormalId.Bottom }, u = 5, v = 5 }
	)
	Kit.parapet(m, "Frame", Vector3.new(fx0, 0, fz0), Vector3.new(fx1, 0, fz1), fy - fr.rim, fr.rim, 1, white)
	-- The frame's depth: chords under the glass, three along z and one along x.
	local fb = fr.beam / 2
	for i = 1, 3 do
		local x = fx0 + (fx1 - fx0) * i / 4
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
		"Chord4",
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
	-- Planters along the forecourt's front, either side of the entrance.
	local planter = Kit.look(pal.stone, Enum.Material.SmoothPlastic)
	local edge = -hd + 1.2
	Kit.planter(m, "PlanterL", Vector3.new(tx0 + 2, 0.3, edge), Vector3.new(tx0 + 12, 1.9, edge + 2), planter)
	Kit.planter(m, "PlanterR", Vector3.new(mx1 - 12, 0.3, edge), Vector3.new(mx1 - 2, 1.9, edge + 2), planter)
end

local archetype: Types.Archetype = { id = "sawtooth_office_tower", build = build }
return archetype
