--!strict
-- T06 standard_glass_slab (docs/city/ARCHETYPES.md §5, T06): the city's standard condo tower, the one downtown
-- reuses most, done well. A parking podium over a glass lobby, a pool deck on the podium, then a glass slab striped
-- by white balcony plates, broken by one or two deep sky decks, under a crisp crown.
--
-- What makes it itself: crisp white balcony lines over blue glass, a deep sky-deck notch, a white overhanging crown.
-- Placement, sizes, heights and its budget: Config/City archetypes.standard_glass_slab.
-- Variants: palette (4 glass and frame sets), crown (1 overhang and spire, 2 lit blades, 3 sky pool), rhythm (1 a
-- balcony every second floor with rails, 2 every floor, 3 every floor in staggered half plates), mirror.

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
	lobby = 16, -- the double-height ground floor
	level = 10, -- a parking level
	podiumShare = 0.14, -- of the height, the podium (in whole levels)...
	levels = { 3, 6 }, -- ...between these
	frontSetback = 4, -- the podium's face behind the front line
	sideInset = 1,
	backInset = 1.5,
	slot = 3.6, -- the dark slot at the top of each parking level
	bandProud = 0.4, -- the pale band under it stands this far out
	lobbyInset = 3, -- the glass lobby sits this far in under the podium
	columnEvery = 18, -- round columns along the podium's front edge
	column = 2.2,
	capThick = 1.4,
	capProud = 0.5, -- past the bands
	towerMargin = 13, -- each side of the tower, at least, to the podium's edge
	towerWidth = { 50, 90 },
	towerDepth = { 26, 32 },
	towerBack = 5.5, -- the tower's back face from the back line
	plateThick = 1.8,
	plateEnds = 1.2, -- a balcony plate past the tower's ends...
	plateFaces = 4.5, -- ...and past its long faces
	stagger = 4, -- rhythm 3: a half plate reaches this far past the middle
	pier = 1.6, -- corner piers
	fin = 1.4,
	finFaces = 5.2, -- a long face's centre fin stands out past the balconies
	finEnds = 3, -- an end's fin
	deck = 2.4, -- a sky deck's slab
	deckProud = 5.5,
	skyDeckOver = 250, -- a shaft taller than this gets two sky decks
	lantern = 14, -- crown 1: the glass lantern's height under its roof slab
	roof = 4, -- crown 1: the roof slab, overhanging...
	roofProud = 3, -- ...this far
	spire = { 40, 60 },
	blade = 24, -- crown 2: the frame rises this far over the roof
	canopyY = 12.5,
	canopyThick = 1.4,
	canopyHalf = 14,
}

-- Colour sets: glass, frames (plates, piers, fins, crown), the podium's screen and its bands.
local PALETTES = {
	{ glass = P.glass.aqua, frame = P.frame.white, screen = P.deco.aqua, podium = P.concrete.pale },
	{ glass = P.glass.blue, frame = P.frame.white, screen = rgb(238, 128, 108), podium = P.concrete.warm },
	{ glass = P.glass.silver, frame = P.frame.silver, screen = P.frame.charcoal, podium = P.concrete.pale },
	{ glass = P.glass.navy, frame = P.frame.white, screen = P.deco.lemon, podium = P.concrete.warm },
}

local RAIL = Kit.look(rgb(214, 236, 242), Enum.Material.Glass, 0.1, KIT.railTransparency)
local RHYTHM = { 24, 12, 12 } -- studs between balcony plates
local RAILS = { true, false, false }

local function build(m: Types.Model)
	local site = m.site
	local variant = site.variant
	local pal = PALETTES[math.clamp(variant.palette, 1, #PALETTES)]
	local rng = Kit.rng(m)
	local W, D, H = site.width, site.depth, site.height
	local hw, hd = W / 2, D / 2
	local frameLook = Kit.look(pal.frame, Enum.Material.SmoothPlastic)
	local dark = P.concrete.dark
	local tag = City.signNames.towers[rng:NextInteger(1, #City.signNames.towers)]

	-------------------------------------------------------------------------------------------------------
	-- Podium: glass lobby, colonnade, parking levels, screen, cap, pool deck
	-------------------------------------------------------------------------------------------------------
	local levels = math.clamp(math.round(H * SHAPE.podiumShare / SHAPE.level), SHAPE.levels[1], SHAPE.levels[2])
	local podiumTop = SHAPE.lobby + levels * SHAPE.level
	local px0, px1 = -hw + SHAPE.sideInset, hw - SHAPE.sideInset
	local pz0, pz1 = -hd + SHAPE.frontSetback, hd - SHAPE.backInset
	local li = SHAPE.lobbyInset

	Kit.glass(
		m,
		"Lobby",
		Vector3.new(px0 + li, -KIT.bury, pz0 + li),
		Vector3.new(px1 - li, SHAPE.lobby + 0.5, pz1),
		rgb(44, 60, 70),
		{
			image = City.textures.windowBold,
			faces = { Enum.NormalId.Front, Enum.NormalId.Left, Enum.NormalId.Right },
			u = 6,
			v = SHAPE.lobby,
			lines = pal.frame,
			lit = true,
		}
	)
	local columns = math.max(2, math.floor((px1 - px0) / SHAPE.columnEvery))
	for i = 1, columns do
		local x = px0 + 2 + (px1 - px0 - 4) * (i - 1) / (columns - 1)
		Kit.column(m, `Column{i}`, x, pz0 + 1.4, -KIT.bury, SHAPE.lobby + 0.5, SHAPE.column, frameLook)
	end
	Kit.podium(
		m,
		"Podium",
		Vector3.new(px0, SHAPE.lobby, pz0),
		Vector3.new(px1, podiumTop, pz1),
		levels,
		SHAPE.slot,
		SHAPE.bandProud,
		Kit.look(pal.podium, Enum.Material.Concrete),
		Kit.look(dark, Enum.Material.SmoothPlastic)
	)
	-- The art screen over part of the garage face: a coloured perforated panel standing clear of the bands.
	local screenFront = pz0 - SHAPE.bandProud
	local screen = Kit.trim(
		m,
		"Screen",
		Vector3.new(px0 + 4, SHAPE.lobby + 2, screenFront - 1.3),
		Vector3.new(px0 + 4 + (px1 - px0) * 0.42, podiumTop - 1.5, screenFront - 0.4),
		Kit.look(pal.screen, Enum.Material.SmoothPlastic)
	)
	screen.textures = {
		{
			face = Enum.NormalId.Front,
			image = City.textures.windowBold,
			u = 2.4,
			v = 2.4,
			color = pal.frame,
		},
	}
	local cap = SHAPE.bandProud + SHAPE.capProud
	local deckY = podiumTop + SHAPE.capThick
	Kit.trim(
		m,
		"PodiumCap",
		Vector3.new(px0 - cap, podiumTop, pz0 - cap),
		Vector3.new(px1 + cap, deckY, pz1 + cap),
		frameLook
	)
	Kit.neonStrip(
		m,
		"PodiumLed",
		Vector3.new(px0 - cap, podiumTop + 0.35, pz0 - cap - 0.15),
		Vector3.new(px1 + cap, podiumTop + 0.75, pz0 - cap - 0.05),
		"ledBlue",
		pal.frame
	)

	-- The entrance: a cantilevered canopy, the tower's name standing on its front edge, an LED line under it.
	local cw = math.min(SHAPE.canopyHalf, (px1 - px0) / 2 - 4)
	local canopyTop = SHAPE.canopyY + SHAPE.canopyThick
	Kit.canopy(m, "Canopy", -cw, cw, -hd + 0.5, pz0 + li + 0.5, SHAPE.canopyY, SHAPE.canopyThick, frameLook)
	Kit.sign(
		m,
		"Name",
		Vector3.new(-cw * 0.75, canopyTop, -hd + 0.8),
		Vector3.new(cw * 0.75, canopyTop + 2.6, -hd + 1.3),
		Enum.NormalId.Front,
		tag,
		rgb(40, 44, 50),
		pal.frame,
		City.districtLooks.downtown.font
	)
	Kit.neonStrip(
		m,
		"CanopyLed",
		Vector3.new(-cw, SHAPE.canopyY - 0.25, -hd + 0.6),
		Vector3.new(cw, SHAPE.canopyY - 0.05, -hd + 1.2),
		"ledBlue",
		pal.frame
	)

	-------------------------------------------------------------------------------------------------------
	-- Tower
	-------------------------------------------------------------------------------------------------------
	local tw = math.clamp(W - 2 * SHAPE.towerMargin, SHAPE.towerWidth[1], SHAPE.towerWidth[2])
	tw = math.min(tw, W - 2 * (SHAPE.deckProud + 0.5))
	local td = math.clamp(D - 23, SHAPE.towerDepth[1], SHAPE.towerDepth[2])
	local tz1 = hd - SHAPE.towerBack
	local tz0 = tz1 - td
	local tx = tw / 2
	local crown = variant.crown
	local top = if crown == 1 then H - SHAPE.roof - SHAPE.lantern else H - SHAPE.roof
	local yb = deckY

	-- Sky decks on whole floors, a third or a half of the way up the shaft.
	local shaft = top - yb
	local decks: { number } = {}
	local count = if shaft > SHAPE.skyDeckOver then 2 else 1
	for k = 1, count do
		local y = yb + shaft * k / (count + 1)
		table.insert(decks, yb + math.round((y - yb) / SHAPE.floor) * SHAPE.floor)
	end

	-- The glass, split at the first sky deck (the split hides under its slab): one half glows at night.
	local litRoll, litWhich = rng:NextNumber(), rng:NextNumber()
	local lit = litRoll < 0.6
	-- Mullions a little lighter than the glass, not white: the white belongs to the balcony lines.
	local grid = {
		image = City.textures.windowFine,
		u = 9,
		v = SHAPE.floor,
		lines = pal.glass:Lerp(pal.frame, 0.45),
	}
	local function glassRun(name: string, y0: number, y1: number, isLit: boolean)
		Kit.glass(m, name, Vector3.new(-tx, y0, tz0), Vector3.new(tx, y1, tz1), pal.glass, {
			image = grid.image,
			u = grid.u,
			v = grid.v,
			lines = grid.lines,
			lit = isLit,
		})
	end
	glassRun("Core", yb - 0.5, decks[1], lit and litWhich < 0.5)
	glassRun("CoreUpper", decks[1], top, lit and litWhich >= 0.5)

	-- Sky decks: a deep slab grown out on every side over a recessed dark floor, an LED line on its front.
	local smoke = Kit.glassLook(P.glass.smoke, 0.1)
	for k, y in decks do
		Kit.trim(
			m,
			`SkyRecess{k}`,
			Vector3.new(-tx - 0.06, y - SHAPE.floor, tz0 - 0.06),
			Vector3.new(tx + 0.06, y, tz1 + 0.06),
			smoke
		)
		local g = SHAPE.deckProud
		Kit.trim(
			m,
			`SkyDeck{k}`,
			Vector3.new(-tx - g, y, tz0 - g),
			Vector3.new(tx + g, y + SHAPE.deck, tz1 + g),
			frameLook
		)
		Kit.neonStrip(
			m,
			`SkyLed{k}`,
			Vector3.new(-tx - g, y + 0.7, tz0 - g - 0.15),
			Vector3.new(tx + g, y + 1.3, tz0 - g - 0.05),
			"ledBlue",
			pal.frame
		)
	end

	-- Balcony plates between the sky decks: rhythm 1 every second floor with glass rails, 2 every floor, 3 every floor
	-- in half-width plates swapping sides floor by floor (a staggered, zig-zag face).
	local rhythm = math.clamp(variant.rhythm, 1, #RHYTHM)
	local every = RHYTHM[rhythm]
	local railLook = if RAILS[rhythm] then RAIL else nil
	local bounds = { yb }
	for _, y in decks do
		table.insert(bounds, y)
	end
	table.insert(bounds, top)
	local core0, core1 = Vector3.new(-tx, 0, tz0), Vector3.new(tx, 0, tz1)
	for k = 1, #bounds - 1 do
		local from = bounds[k] + every
		local to = bounds[k + 1] - (if k < #bounds - 1 then SHAPE.floor + 1 else 2)
		local name = `Plate{string.char(64 + k)}`
		if rhythm == 3 then
			local n, y = 0, from
			while y + SHAPE.plateThick <= to do
				n += 1
				local left = n % 2 == 1
				local x0 = if left then -tx - SHAPE.plateEnds else -SHAPE.stagger
				local x1 = if left then SHAPE.stagger else tx + SHAPE.plateEnds
				Kit.trim(
					m,
					`{name}{n}`,
					Vector3.new(x0, y, tz0 - SHAPE.plateFaces),
					Vector3.new(x1, y + SHAPE.plateThick, tz1 + SHAPE.plateFaces),
					frameLook
				)
				y += every
			end
		else
			Kit.plates(
				m,
				name,
				core0,
				core1,
				from,
				to,
				every,
				SHAPE.plateThick,
				SHAPE.plateEnds,
				SHAPE.plateFaces,
				frameLook,
				railLook
			)
		end
	end

	-- Corner piers and a fin down the middle of every face: the crisp verticals against the plates.
	local p = SHAPE.pier
	for i, corner in { { -1, -1 }, { 1, -1 }, { -1, 1 }, { 1, 1 } } do
		local cx = corner[1] * tx
		local cz = if corner[2] < 0 then tz0 else tz1
		Kit.trim(
			m,
			`Pier{i}`,
			Vector3.new(cx - corner[1] * (p - 0.3), yb, cz - corner[2] * (p - 0.3)),
			Vector3.new(cx + corner[1] * 0.3, top, cz + corner[2] * 0.3),
			frameLook
		)
	end
	local finTop = top
	local half = SHAPE.fin / 2
	Kit.trim(
		m,
		"FinFront",
		Vector3.new(-half, yb, tz0 - SHAPE.finFaces),
		Vector3.new(half, finTop, tz0 + 0.3),
		frameLook
	)
	Kit.trim(
		m,
		"FinBack",
		Vector3.new(-half, yb, tz1 - 0.3),
		Vector3.new(half, finTop, tz1 + SHAPE.finFaces),
		frameLook
	)
	local zc = (tz0 + tz1) / 2
	for i, side in { -1, 1 } do
		Kit.trim(
			m,
			`FinEnd{i}`,
			Vector3.new(side * tx - (if side > 0 then 0.3 else SHAPE.finEnds), yb, zc - half),
			Vector3.new(side * tx + (if side > 0 then SHAPE.finEnds else 0.3), top, zc + half),
			frameLook
		)
	end

	-------------------------------------------------------------------------------------------------------
	-- Crown
	-------------------------------------------------------------------------------------------------------
	local rp = SHAPE.roofProud
	if crown == 1 then
		-- A glass lantern under a deep white overhang, a lit soffit, a plant room and a spire.
		Kit.glass(
			m,
			"Lantern",
			Vector3.new(-tx + 1.5, top, tz0 + 1.5),
			Vector3.new(tx - 1.5, H - SHAPE.roof, tz1 - 1.5),
			pal.glass,
			{
				lit = true,
			}
		)
		Kit.trim(
			m,
			"Roof",
			Vector3.new(-tx - rp, H - SHAPE.roof, tz0 - rp),
			Vector3.new(tx + rp, H, tz1 + rp),
			frameLook
		)
		Kit.neonStrip(
			m,
			"CrownRing",
			Vector3.new(-tx - rp + 0.4, H - SHAPE.roof - 0.45, tz0 - rp + 0.4),
			Vector3.new(tx + rp - 0.4, H - SHAPE.roof - 0.05, tz1 + rp - 0.4),
			"crown",
			pal.frame
		)
		Kit.roofBox(m, "Plant", Vector3.new(-tw * 0.2, H, tz0 + 5), Vector3.new(tw * 0.2, H + 6, tz1 - 5))
		if rng:NextNumber() < 0.6 then
			local tall = SHAPE.spire[1] + rng:NextNumber() * (SHAPE.spire[2] - SHAPE.spire[1])
			Kit.spire(m, "Spire", 0, zc, H + 6, tall, 1.8, Kit.look(rgb(200, 204, 210), Enum.Material.Metal), 2, true)
		end
	elseif crown == 2 then
		-- A white open frame over the roof: the end walls rise past it and two beams join them, lit along the front.
		Kit.trim(m, "Roof", Vector3.new(-tx - 1.5, top, tz0 - 1.5), Vector3.new(tx + 1.5, H, tz1 + 1.5), frameLook)
		local fz0, fz1 = tz0 - 2, tz1 + 2
		local beamY = H + SHAPE.blade
		for i, sx in { -1, 1 } do
			Kit.trim(
				m,
				`FrameWall{i}`,
				Vector3.new(sx * (tx - 1.5), top, fz0),
				Vector3.new(sx * (tx + 2.2), beamY, fz1),
				frameLook
			)
		end
		Kit.trim(
			m,
			"FrameBeamFront",
			Vector3.new(-tx - 2.2, beamY - 3, fz0),
			Vector3.new(tx + 2.2, beamY, fz0 + 3),
			frameLook
		)
		Kit.trim(
			m,
			"FrameBeamBack",
			Vector3.new(-tx - 2.2, beamY - 3, fz1 - 3),
			Vector3.new(tx + 2.2, beamY, fz1),
			frameLook
		)
		Kit.neonStrip(
			m,
			"CrownRing",
			Vector3.new(-tx + 1.6, beamY - 3.4, fz0 + 0.4),
			Vector3.new(tx - 1.6, beamY - 2.95, fz0 + 2.6),
			"crown",
			pal.frame
		)
		Kit.roofBox(m, "Plant", Vector3.new(-tw * 0.25, H, tz0 + 6), Vector3.new(tw * 0.25, H + 8, tz1 - 6))
	else
		-- A sky pool: the roof a pool deck with a glass rail and a pergola.
		Kit.trim(m, "Roof", Vector3.new(-tx - rp, top, tz0 - rp), Vector3.new(tx + rp, H, tz1 + rp), frameLook)
		Kit.detail(
			m,
			"RoofRail",
			Vector3.new(-tx - rp + 0.2, H, tz0 - rp + 0.2),
			Vector3.new(tx + rp - 0.2, H + 3.4, tz0 - rp + 0.5),
			RAIL
		)
		Kit.pool(m, "SkyPool", Vector3.new(-tx + 3, 0, tz0 + 2), Vector3.new(tx * 0.35, 0, zc), H)
		local beam = Kit.look(pal.frame, Enum.Material.SmoothPlastic)
		local gx0, gx1 = tx * 0.5, tx - 3
		Kit.column(m, "PergolaPost1", gx0, zc + 4, H, H + 9, 0.8, beam, "trim")
		Kit.column(m, "PergolaPost2", gx1, zc + 4, H, H + 9, 0.8, beam, "trim")
		Kit.trim(m, "Pergola", Vector3.new(gx0 - 1, H + 9, zc - 2), Vector3.new(gx1 + 1, H + 9.8, zc + 6), beam)
		Kit.neonStrip(
			m,
			"CrownRing",
			Vector3.new(-tx - rp + 0.4, top - 0.45, tz0 - rp + 0.4),
			Vector3.new(tx + rp - 0.4, top - 0.05, tz1 + rp - 0.4),
			"crown",
			pal.frame
		)
	end

	-------------------------------------------------------------------------------------------------------
	-- Pool deck on the podium, in front of the tower
	-------------------------------------------------------------------------------------------------------
	local deckFront, deckBack = pz0 + 1.8, tz0 - SHAPE.plateFaces - 1.5
	if deckBack - deckFront >= 3 then
		local poolW = (px1 - px0) * 0.36
		Kit.pool(m, "Pool", Vector3.new(px0 + 5, 0, deckFront), Vector3.new(px0 + 5 + poolW, 0, deckBack), deckY)
		Kit.planter(
			m,
			"Planter",
			Vector3.new(px1 - 6 - (px1 - px0) * 0.25, deckY, pz0 + 1.2),
			Vector3.new(px1 - 6, deckY + 1.6, pz0 + 3.2),
			frameLook
		)
	end
	Kit.detail(
		m,
		"DeckRail",
		Vector3.new(px0 - cap + 0.3, deckY, pz0 - cap + 0.3),
		Vector3.new(px1 + cap - 0.3, deckY + 3.4, pz0 - cap + 0.6),
		RAIL
	)
end

local archetype: Types.Archetype = { id = "standard_glass_slab", build = build }
return archetype
