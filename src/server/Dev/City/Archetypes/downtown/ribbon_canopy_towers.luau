--!strict
-- T16 ribbon_canopy_towers (docs/city/ARCHETYPES.md §5, T16): a three-storey open-air shopping podium of pale stone,
-- cut through by a pedestrian street from the front line to the back. Lit shop fronts sit in an arcade under the upper
-- floors, aluminium louvres screen the upper floors, a white band marks the level line and a sign bridges the street's
-- mouth. On the two shop blocks stand two or three glass towers with white slab edges, each topped by a glass chamfer
-- cut a different way, with a white coping and a lit line along the cut. Floating over it all: the ribbon, a long
-- folded canopy of white fabric and glass facets that rolls up and down in waves along the front and turns back over
-- the street on slender posts, lit blades hanging under its crests; at night its glass facets glow.
--
-- What makes it itself: a long white folded canopy floating over a shopping street between glass towers.
-- Placement, sizes, heights and its budget: Config/CityArchetypes/ribbon_canopy_towers (a one-off).
-- Variants: palette (1 aqua glass and white fabric, 2 blue glass, warm fabric and champagne louvres), crown (which way
-- each tower's chamfer is cut and which end holds the tallest tower), rhythm (1 slab edges every third floor and long
-- folds, 2 every second floor and tighter folds), mirror.
--
-- Previewing, check: the ribbon reads as one continuous folded surface (no gaps or steps at the folds, the street arm
-- meets the front arm cleanly) and clears the shop roofs and the towers; its posts land on the roofs or the street
-- paving; the chamfers read as cuts against the sky from the street; the shop arcade is in shadow with the shop glass
-- lit at night; the blades glow as a row of short blue lines under the ribbon at night, no more than two neon colours.

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
	ground = 16, -- the shops' double-height ground floor
	level = 12, -- an upper shop floor...
	levels = 2, -- ...and how many
	frontSetback = 4,
	sideInset = 1,
	backInset = 1.5,
	arcade = 2.5, -- the shop fronts sit this far in under the upper floors (and along the street)
	louvre = { proud = 1, inset = 3, lines = 1.5 },
	band = { thick = 1.2, proud = 1.6 },
	coping = 1.2,
	street = { 0.12, 18, 26 }, -- the pedestrian street's width: share of the site, clamped
	streetShift = 0.05, -- of the width, off the middle, so the two shop blocks differ
	towerDepth = { 26, 50 },
	towerWidth = { 28, 46 },
	towerBack = 2, -- the towers' back face from the shops' back face
	towerEdge = 5, -- a tower keeps this far from the street and the block's ends
	towerGap = 14, -- between two towers on one block
	step = 26, -- each shorter tower is this much lower
	plateEvery = { 36, 24 }, -- by rhythm
	plate = { thick = 1.2, proudX = 1, proudZ = 2.5 },
	chamfer = { 0.65, 18, 30 }, -- the cut's height: share of the tower's width, clamped
	ribbon = {
		lift = 16, -- its mean height over the shop roofs
		wave = { 4, 7 }, -- each fold rises or dips this much from it
		thick = 1.2,
		front = 3.5, -- the front arm reaches this far in front of the shops' face...
		back = 22, -- ...and up to this far back over their roofs (less on a shallow site: it keeps clear of the towers)
		clear = 4, -- from the towers' balconies
		span = { 10, 8.5 }, -- a facet's length, by rhythm (at least: the waves are whole)
		per = 5, -- facets a wave
		streetWave = 0.5, -- the street arm's waves, of the front arm's
		streetSpan = 9,
		streetFacets = { 2, 8 },
		over = 3, -- the street arm overlaps the shop roofs this much each side
		overlap = 0.5, -- each facet runs this far past its folds, so the folds close
	},
	blade = { drop = 5, swing = 1.6, thick = 0.4 },
	post = 1,
	roofGarden = 16, -- a deep site's shop roofs get a pool and a planter once this much roof lies before the towers
}

local PALETTES = {
	{
		glass = P.glass.aqua,
		fabric = rgb(247, 247, 244),
		pane = rgb(207, 227, 234),
		stone = rgb(236, 232, 224),
		louvre = rgb(196, 202, 208),
	},
	{
		glass = P.glass.blue,
		fabric = rgb(244, 240, 232),
		pane = rgb(196, 220, 226),
		stone = rgb(226, 218, 204),
		louvre = rgb(214, 198, 170),
	},
}

-- Which way each tower's top is cut, by crown (tower order along the site).
local CUTS: { { Kit.Side } } = { { "back", "left", "right" }, { "right", "back", "left" } }

local FRONT, LEFT, RIGHT = Enum.NormalId.Front, Enum.NormalId.Left, Enum.NormalId.Right

local function build(m: Types.Model)
	local site = m.site
	local variant = site.variant
	local pal = PALETTES[math.clamp(variant.palette, 1, #PALETTES)]
	local crown = math.clamp(variant.crown, 1, #CUTS)
	local rhythm = math.clamp(variant.rhythm, 1, 2)
	local rng = Kit.rng(m)
	local W, D, H = site.width, site.depth, site.height
	local hw, hd = W / 2, D / 2
	local white = P.frame.white
	local frameLook = Kit.look(white, Enum.Material.SmoothPlastic)
	local lineLook = Kit.look(white, Enum.Material.SmoothPlastic)
	local glassLook = Kit.glassLook(pal.glass, 0.2)
	local tag = City.signNames.towers[rng:NextInteger(1, #City.signNames.towers)]

	-------------------------------------------------------------------------------------------------------
	-- The shops: two blocks either side of the street, arcade, louvres, a level band, a coping
	-------------------------------------------------------------------------------------------------------
	local mallTop = SHAPE.ground + SHAPE.levels * SHAPE.level
	local deck = mallTop + SHAPE.coping
	local mz0, mz1 = -hd + SHAPE.frontSetback, hd - SHAPE.backInset
	local ps = math.clamp(W * SHAPE.street[1], SHAPE.street[2], SHAPE.street[3])
	local pc = W * SHAPE.streetShift
	local blocks = {
		{ x0 = -hw + SHAPE.sideInset, x1 = pc - ps / 2, inner = RIGHT, outer = LEFT },
		{ x0 = pc + ps / 2, x1 = hw - SHAPE.sideInset, inner = LEFT, outer = RIGHT },
	}
	local stone = Kit.look(pal.stone, Enum.Material.SmoothPlastic)
	local louvre = Kit.look(pal.louvre, Enum.Material.Metal)
	local ar = SHAPE.arcade
	for i, blk in blocks do
		local b0, b1 = blk.x0, blk.x1
		Kit.box(m, `Shops{i}Upper`, Vector3.new(b0, SHAPE.ground, mz0), Vector3.new(b1, mallTop, mz1), stone)
		local g0 = if i == 1 then b0 + 1.5 else b0 + ar
		local g1 = if i == 1 then b1 - ar else b1 - 1.5
		Kit.glass(
			m,
			`Shops{i}`,
			Vector3.new(g0, -KIT.bury, mz0 + ar),
			Vector3.new(g1, SHAPE.ground + 0.4, mz1 - 1),
			P.window.dark,
			{
				image = City.textures.windowBold,
				faces = { FRONT, blk.inner, blk.outer },
				u = 5,
				v = SHAPE.ground + KIT.bury + 0.4,
				lines = white,
				lit = true,
			}
		)
		local lv = SHAPE.louvre
		local screen = Kit.trim(
			m,
			`Louvre{i}`,
			Vector3.new(b0 + lv.inset, SHAPE.ground + 1.5, mz0 - lv.proud),
			Vector3.new(b1 - lv.inset, mallTop - 1.5, mz0 - 0.1),
			louvre
		)
		screen.textures = {
			{
				face = FRONT,
				image = City.textures.windowBold,
				u = lv.lines,
				v = mallTop, -- taller than the screen: only the tile's mullions show, as vertical louvres
				color = pal.louvre:Lerp(P.concrete.dark, 0.5),
			},
		}
		local bd = SHAPE.band
		local bandY = SHAPE.ground + SHAPE.level
		Kit.trim(
			m,
			`Band{i}`,
			Vector3.new(b0 - 0.3, bandY - bd.thick / 2, mz0 - bd.proud),
			Vector3.new(b1 + 0.3, bandY + bd.thick / 2, mz0 + 1),
			frameLook
		)
		Kit.trim(
			m,
			`Coping{i}`,
			Vector3.new(b0 - 0.4, mallTop, mz0 - 0.6),
			Vector3.new(b1 + 0.4, deck, mz1 + 0.4),
			frameLook
		)
	end

	-- The street: paving under the arcades, two planters, a sign bridging its mouth at the first floor.
	Kit.box(
		m,
		"Street",
		Vector3.new(pc - ps / 2 - ar, -KIT.bury, -hd + 0.5),
		Vector3.new(pc + ps / 2 + ar, 0.3, mz1),
		Kit.look(P.deco.terrazzo, Enum.Material.SmoothPlastic)
	)
	local zq = (mz0 + mz1) / 2
	for i, side in { -1, 1 } do
		local xa, xb = pc + side * (ps / 2 - 1), pc + side * (ps / 2 - 3.5)
		Kit.planter(
			m,
			`Planter{i}`,
			Vector3.new(math.min(xa, xb), 0.3, zq - 4),
			Vector3.new(math.max(xa, xb), 1.9, zq + 4),
			frameLook
		)
	end
	Kit.sign(
		m,
		"Name",
		Vector3.new(pc - ps / 2 - 0.3, SHAPE.ground + 1.2, mz0 - 0.4),
		Vector3.new(pc + ps / 2 + 0.3, SHAPE.ground + 4.4, mz0 + 0.3),
		FRONT,
		tag,
		rgb(40, 44, 50),
		white,
		City.districtLooks.downtown.font
	)

	-------------------------------------------------------------------------------------------------------
	-- The towers: one on each block, two on the left block when it is wide enough
	-------------------------------------------------------------------------------------------------------
	local td = math.clamp(D - 19, SHAPE.towerDepth[1], SHAPE.towerDepth[2])
	local tw = math.clamp(td, SHAPE.towerWidth[1], SHAPE.towerWidth[2])
	local tz1 = mz1 - SHAPE.towerBack
	local tz0 = tz1 - td
	local e = SHAPE.towerEdge
	local left, right = blocks[1], blocks[2]
	local spots: { number } = {}
	if left.x1 - left.x0 >= 2 * tw + SHAPE.towerGap + 2 * e then
		table.insert(spots, left.x0 + e + tw / 2)
		table.insert(spots, left.x1 - e - tw / 2)
	else
		table.insert(spots, (left.x0 + left.x1) / 2)
	end
	table.insert(spots, (right.x0 + right.x1) / 2)

	local every = SHAPE.plateEvery[rhythm]
	local pl = SHAPE.plate
	local litRoll, litTower, litLow = rng:NextNumber(), rng:NextInteger(1, #spots), rng:NextNumber() < 0.5
	local function run(name: string, min: Vector3, max: Vector3, isLit: boolean)
		Kit.glass(m, name, min, max, pal.glass, {
			image = City.textures.windowFine,
			u = 6,
			v = SHAPE.floor,
			lines = pal.glass:Lerp(white, 0.5),
			lit = isLit,
			reflectance = 0.2,
		})
	end
	for i, x in spots do
		local rank = if crown == 1 then i else #spots + 1 - i -- 1 is the tallest
		local top = H - (rank - 1) * SHAPE.step
		local cut = CUTS[crown][i]
		local x0, x1 = x - tw / 2, x + tw / 2
		local cr = math.clamp(tw * SHAPE.chamfer[1], SHAPE.chamfer[2], SHAPE.chamfer[3])
		local yc = top - cr -- the glass's top, where the cut starts
		local ym = deck + math.max(every, math.floor((yc - deck) / 2 / every) * every)
		local isLit = litRoll < 0.6 and i == litTower
		run(`Tower{i}`, Vector3.new(x0, deck - 0.5, tz0), Vector3.new(x1, ym, tz1), isLit and litLow)
		run(`Tower{i}Upper`, Vector3.new(x0, ym, tz0), Vector3.new(x1, yc, tz1), isLit and not litLow)
		Kit.plates(
			m,
			`Tower{i}Plate`,
			Vector3.new(x0, 0, tz0),
			Vector3.new(x1, 0, tz1),
			deck + every,
			yc - 2,
			every,
			pl.thick,
			pl.proudX,
			pl.proudZ,
			frameLook
		)
		Kit.wedge(m, `Tower{i}Top`, Vector3.new(x0, yc, tz0), Vector3.new(x1, top, tz1), cut, glassLook)
		-- The cut's edge on the street side: a coping half sunk along it, a lit line under it.
		local z = tz0 + 0.3
		local a: Vector3, b: Vector3
		if cut == "back" then
			a, b = Vector3.new(x0, yc, z), Vector3.new(x1, yc, z) -- the slope faces the street; its foot runs level
		elseif cut == "left" then
			a, b = Vector3.new(x1, yc, z), Vector3.new(x0, top, z)
		else
			a, b = Vector3.new(x0, yc, z), Vector3.new(x1, top, z)
		end
		Kit.strut(m, `Tower{i}Coping`, a, b, 1, frameLook, "trim", 1.8)
		local down = Vector3.new(0, -1.7, -0.75)
		local line =
			Kit.strut(m, `Tower{i}Line`, a:Lerp(b, 0.05) + down, a:Lerp(b, 0.95) + down, 0.6, lineLook, "detail", 0.4)
		Kit.lit(line, "crown")
	end

	-------------------------------------------------------------------------------------------------------
	-- The ribbon: a folded canopy along the front, turning back over the street; blades under its high folds
	-------------------------------------------------------------------------------------------------------
	local rb = SHAPE.ribbon
	local base = mallTop + rb.lift
	local fz0 = mz0 - rb.front
	local fz1 = mz0 + math.clamp(tz0 - pl.proudZ - rb.clear - mz0, 6, rb.back)

	-- On a deep site the shop roofs between the ribbon and the towers are a roof garden: a pool, a long planter.
	local gz0, gz1 = fz1 + 3, tz0 - pl.proudZ - 3
	if gz1 - gz0 >= SHAPE.roofGarden then
		local lw = left.x1 - left.x0
		local poolW = math.clamp(lw * 0.4, 12, 30)
		Kit.pool(
			m,
			"RoofPool",
			Vector3.new(left.x0 + 4, 0, gz0),
			Vector3.new(left.x0 + 4 + poolW, 0, math.min(gz1, gz0 + 30)),
			deck
		)
		Kit.planter(
			m,
			"RoofPlanter",
			Vector3.new(right.x0 + 4, deck, gz0),
			Vector3.new(right.x1 - 4, deck + 1.6, gz0 + 3),
			frameLook
		)
	end
	local fzc, fw = (fz0 + fz1) / 2, fz1 - fz0
	local xa, xb = -hw + 3, hw - 3
	-- The front arm samples a sine wave, `per` facets a wave, so it rolls rather than zig-zags; each wave has its own
	-- height and the whole ribbon its own phase.
	local per = rb.per
	local waves = math.max(2, math.floor((xb - xa) / (per * rb.span[rhythm])))
	local nf = waves * per
	local phase = rng:NextNumber() * 2 * math.pi
	local amps: { number } = {}
	for _ = 1, waves + 1 do
		table.insert(amps, rb.wave[1] + rng:NextNumber() * (rb.wave[2] - rb.wave[1]))
	end
	local nodes: { Vector3 } = {}
	for j = 0, nf do
		local amp = amps[j // per + 1]
		local y = base + amp * math.sin(phase + 2 * math.pi * j / per)
		table.insert(nodes, Vector3.new(xa + (xb - xa) * j / nf, y, fzc))
	end
	-- Fabric and frosted glass facets, both opaque and pale, so the folds read as one continuous white surface. The
	-- glass facets are lit from under at night (ledEdge): the wave shows as a row of pale panels over the dark street.
	local fabric = Kit.look(pal.fabric, Enum.Material.SmoothPlastic)
	local pane = Kit.look(pal.pane, Enum.Material.Glass, 0.25, 0)
	local function facet(name: string, from: Vector3, to: Vector3, wide: number, look: Kit.Look)
		local past = (to - from).Unit * rb.overlap
		local spec = Kit.strut(m, name, from - past, to + past, rb.thick, look, "trim", wide)
		if look == pane then
			Kit.lit(spec, "ledEdge")
		end
	end
	for j = 1, nf do
		facet(`Ribbon{j}`, nodes[j], nodes[j + 1], fw, if j % 2 == 1 then fabric else pane)
	end

	-- The front arm's height at x (along its folds).
	local function ribbonY(x: number): number
		for j = 1, nf do
			local p0, p1 = nodes[j], nodes[j + 1]
			if x >= p0.X and x <= p1.X then
				return p0.Y + (p1.Y - p0.Y) * (x - p0.X) / (p1.X - p0.X)
			end
		end
		return base
	end

	-- The street arm starts where the front arm crosses the street's middle.
	local sz0, sz1 = fz1 - 1, mz1 - 1.5
	local np = math.clamp(math.round((sz1 - sz0) / rb.streetSpan), rb.streetFacets[1], rb.streetFacets[2])
	-- The street arm rolls more gently (half the front arm's waves), so it reads as the ribbon turning back.
	local prev = Vector3.new(pc, ribbonY(pc), sz0)
	for k = 1, np do
		local amp = (rb.wave[1] + rng:NextNumber() * (rb.wave[2] - rb.wave[1])) * rb.streetWave
		local node = Vector3.new(pc, base + (if k % 2 == 1 then -amp else amp), sz0 + (sz1 - sz0) * k / np)
		facet(`Street{k}`, prev, node, ps + 2 * rb.over, if k % 2 == 0 then fabric else pane)
		prev = node
	end

	-- Each wave's crest and trough (its highest and lowest fold, never the ribbon's two ends).
	local crests: { number }, troughs: { number } = {}, {}
	for w = 0, waves - 1 do
		local hi, lo = 0, 0
		for j = w * per + 1, (w + 1) * per do
			if j > 1 and j <= nf then
				if hi == 0 or nodes[j].Y > nodes[hi].Y then
					hi = j
				end
				if lo == 0 or nodes[j].Y < nodes[lo].Y then
					lo = j
				end
			end
		end
		table.insert(crests, hi)
		table.insert(troughs, lo)
	end

	-- Lit blades hanging under the crests, posts under the troughs (on the roofs, or down to the street).
	local bl = SHAPE.blade
	for w, j in crests do
		local nd = nodes[j]
		local s = if w % 2 == 0 then 1 else -1
		local blade = Kit.strut(
			m,
			`Blade{w}`,
			Vector3.new(nd.X - s * bl.swing, nd.Y - 0.5, fzc),
			Vector3.new(nd.X + s * bl.swing, nd.Y - bl.drop, fzc),
			bl.thick,
			lineLook,
			"detail",
			fw - 2
		)
		Kit.lit(blade, "ledEdge")
	end
	local steel = Kit.look(rgb(220, 224, 228), Enum.Material.Metal)
	for _, j in troughs do
		local x = nodes[j].X
		local off = x - pc
		if math.abs(off) < ps / 2 + 1.5 then
			-- Never in the street's mouth (it would stand in front of the sign): onto the roof at the street's edge.
			x = pc + (if off < 0 then -1 else 1) * (ps / 2 + 1.5)
		end
		Kit.column(m, `RibbonPost{j}`, x, mz0 + 2, deck, ribbonY(x), SHAPE.post, steel, "trim")
	end
	for i, side in { -1, 1 } do
		Kit.column(m, `StreetPost{i}`, pc + side * (ps / 2 + 1.5), sz1, deck, prev.Y, SHAPE.post, steel, "trim")
	end
end

local archetype: Types.Archetype = { id = "ribbon_canopy_towers", build = build }
return archetype
