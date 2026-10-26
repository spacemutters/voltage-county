--!strict
-- T12 triple_tower_podium (docs/city/ARCHETYPES.md §5, T12): a one-off condo and hotel complex. A huge white podium of
-- punched windows lifted over a colonnade, with a pool deck on top; on the deck two identical slim towers and a
-- shorter third, each made of two interlocking glass slabs, one taller and stepped forward or back of the other.
-- The taller slab wears a dense white balcony grid and a real balcony every third (or fourth) floor; the shorter one
-- is plain dark glass under a white cap. Over each main slab, a white lattice screen (or a lit glass tier) finishes
-- the top. At the street, under the podium's edge, a row of giant stone monoliths with slanted heads and two eye
-- slots each, like a line of standing stones guarding the drive; at night their eyes glow amber, and so does one
-- vertical stripe up each tower (the lit lift lobbies).
--
-- What makes it itself: three slim towers of interlocking slabs on one huge podium, and at the street the giant
-- monoliths with glowing eyes.
-- Placement, sizes, heights and its budget: Config/CityArchetypes/triple_tower_podium.
-- Variants: palette (3 glass, frame and podium sets), crown (1 white lattice screens over the main slabs, 2 a lit glass
-- tier with a cornice and a roof slab), rhythm (1 the shorter slabs step forward and a balcony every third floor, 2
-- they step back and a balcony every fourth), mirror (the shorter third tower stands at the other end).
--
-- Preview checklist: the monoliths must read as heads, not posts (head slope, eye height, spacing under the soffit);
-- the two slabs of each tower must read as two, not one box with a notch (check the shift and the plain glass of the
-- second slab from 200 studs); the white grid texture should read as balconies at 300 studs, not as noise; the
-- podium's punched windows; at night the amber eyes and stripes, the blue podium edge, a lit run per tower.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local City = require(ReplicatedStorage.Shared.Config.City)
local Kit = require(script.Parent.Parent.Parent.Kit)
local Types = require(script.Parent.Parent.Parent.Types)

local P = City.palettes
local KIT = City.kit
local rgb = Color3.fromRGB

-- The recipe, in studs.
local SHAPE = {
	arcade = 26, -- the colonnade under the podium: its underside (a two-storey entrance drive)
	level = 10, -- a podium level
	levels = { 5, 7 },
	podiumShare = 0.2, -- of the height, the podium (in whole levels, between `levels`)
	front = 4, -- the podium's face behind the front line
	side = 1.5,
	back = 1.5,
	arcadeDepth = 11, -- the lobby glass stands this far behind the podium's face
	soffit = 0.6, -- the white fascia under the podium's front edge
	cap = 1.4,
	capProud = 0.8,
	-- A giant stone head: a tall face block, its forehead receding (`slant`) to a flat crown under the soffit, a heavy
	-- brow ridge, a long nose standing out of the face, and two eye slots under the brow (one strip, split by the nose).
	monolith = { width = 6, depth = 5.6, slant = 4, spacing = 24, max = 8, clear = 0.8 },
	brow = { height = 1.3, proud = 1.1 },
	nose = { length = 6, proud = 1.7, width = 1.7 },
	eye = { width = 4.6, height = 0.7, below = 0.6 }, -- the strip under the brow; the nose covers its middle
	towerMargin = 6, -- the end towers from the podium's ends
	towerGap = 14, -- between towers, at least
	towerMax = 60, -- a tower's width (both its slabs), at most
	towerDepth = { 24, 40 },
	deck = 12, -- the pool deck in front of the towers, at least
	shift = 4, -- the second slab stands this far forward (or back) of the first
	blockA = 0.64, -- the main slab's share of the tower's width...
	blockB = 0.5, -- ...and the second slab's (they overlap by the rest)
	stepFloors = 4, -- the second slab stops this many floors under the first
	floor = 12,
	hotelShare = 0.86, -- the third tower's height, of the main roof
	plate = { thick = 1.4, ends = 1.2, faces = 3.2 },
	plateEvery = { 36, 48 }, -- by rhythm
	gridBay = 3.2, -- the white balcony grid's bay on the main slabs
	screen = { height = 12, thick = 1 }, -- crown 1
	tier = { inset = 3, height = 10 }, -- crown 2
	stripe = 1.6,
	skinShare = 0.3, -- of a main slab's height, its lit run
	pool = 0.42, -- of the podium's width
	signWidth = 32,
}

-- Glass for the main slabs, darker glass for the second ones, frames, and the podium's stucco.
local PALETTES = {
	{ glass = rgb(66, 88, 104), plain = rgb(46, 62, 74), frame = P.frame.white, podium = P.deco.white },
	{ glass = P.glass.teal, plain = P.glass.smoke, frame = P.frame.white, podium = P.concrete.pale },
	{ glass = P.glass.blue, plain = P.glass.navy, frame = P.frame.warm, podium = rgb(236, 230, 218) },
}

local RAIL = Kit.look(rgb(214, 236, 242), Enum.Material.Glass, 0.1, KIT.railTransparency)
local STONE = Kit.look(rgb(119, 115, 107), Enum.Material.Slate)

local function build(m: Types.Model)
	local site = m.site
	local variant = site.variant
	local pal = PALETTES[math.clamp(variant.palette, 1, #PALETTES)]
	local rng = Kit.rng(m)
	local W, D, H = site.width, site.depth, site.height
	local hw, hd = W / 2, D / 2
	local x0, x1 = -hw + SHAPE.side, hw - SHAPE.side
	local zP, zB = -hd + SHAPE.front, hd - SHAPE.back
	local A = SHAPE.arcade
	local levels = math.clamp(math.round((H * SHAPE.podiumShare - A) / SHAPE.level), SHAPE.levels[1], SHAPE.levels[2])
	local Hp = A + levels * SHAPE.level
	local deckY = Hp + SHAPE.cap
	local frame = Kit.look(pal.frame, Enum.Material.SmoothPlastic)
	local paving = Kit.look(P.deco.terrazzo, Enum.Material.SmoothPlastic)
	local lobbyColor = rgb(44, 60, 70)
	local rhythm = math.clamp(variant.rhythm, 1, #SHAPE.plateEvery)

	-------------------------------------------------------------------------------------------------------
	-- The ground: a paved drive under the colonnade, the lobby glass behind it
	-------------------------------------------------------------------------------------------------------
	local lobbyZ = zP + SHAPE.arcadeDepth
	Kit.box(m, "Drive", Vector3.new(x0, 0, -hd + 0.5), Vector3.new(x1, 0.4, lobbyZ + 0.3), paving)
	local lobbyGrid = {
		image = City.textures.windowBold,
		faces = { Enum.NormalId.Front },
		u = 6,
		v = A,
		lines = pal.frame,
	}
	Kit.glass(
		m,
		"Lobby",
		Vector3.new(x0 + 2, -KIT.bury, lobbyZ),
		Vector3.new(x1 - 2, A + 0.3, zB - 0.5),
		lobbyColor,
		lobbyGrid
	)
	local lobbySkin = Kit.detail(
		m,
		"LobbyLit",
		Vector3.new(x0 + 4, 1.4, lobbyZ - 0.18),
		Vector3.new(x1 - 4, A - 3, lobbyZ - 0.06),
		Kit.glassLook(lobbyColor)
	)
	lobbySkin.textures = {
		{ face = Enum.NormalId.Front, image = City.textures.windowBold, u = 6, v = A, color = pal.frame },
	}
	Kit.lit(lobbySkin, "window")

	-------------------------------------------------------------------------------------------------------
	-- The podium: white stucco with punched windows over the colonnade, a fascia, a cap with an LED edge
	-------------------------------------------------------------------------------------------------------
	Kit.punched(
		m,
		"Podium",
		Vector3.new(x0, A, zP),
		Vector3.new(x1, Hp, zB),
		pal.podium,
		P.window.dark,
		{ Enum.NormalId.Front, Enum.NormalId.Left, Enum.NormalId.Right, Enum.NormalId.Back },
		6,
		SHAPE.level
	)
	Kit.trim(
		m,
		"Soffit",
		Vector3.new(x0 - 0.3, A - SHAPE.soffit, zP - 0.3),
		Vector3.new(x1 + 0.3, A + 0.05, lobbyZ + 0.4),
		frame
	)
	local cp = SHAPE.capProud
	Kit.trim(m, "Cap", Vector3.new(x0 - cp, Hp, zP - cp), Vector3.new(x1 + cp, deckY, zB + cp), frame)
	Kit.neonStrip(
		m,
		"CapLed",
		Vector3.new(x0 - cp, Hp - 0.45, zP - cp - 0.15),
		Vector3.new(x1 + cp, Hp + 0.05, zP - cp - 0.05),
		"ledBlue",
		pal.frame
	)
	Kit.detail(
		m,
		"DeckRail",
		Vector3.new(x0 - cp + 0.3, deckY, zP - cp + 0.3),
		Vector3.new(x1 + cp - 0.3, deckY + KIT.railHeight, zP - cp + 0.6),
		RAIL
	)
	local names = City.signNames.towers
	local signW = math.min(SHAPE.signWidth, (x1 - x0) * 0.3)
	Kit.sign(
		m,
		"Name",
		Vector3.new(x0 + 6, Hp - 8, zP - 0.5),
		Vector3.new(x0 + 6 + signW, Hp - 3, zP - 0.1),
		Enum.NormalId.Front,
		names[rng:NextInteger(1, #names)],
		rgb(40, 44, 50),
		pal.frame,
		City.districtLooks.downtown.font
	)

	-------------------------------------------------------------------------------------------------------
	-- The monoliths: giant stone heads standing under the podium's edge, two eye slots each
	-------------------------------------------------------------------------------------------------------
	local mo, brow, nose, eye = SHAPE.monolith, SHAPE.brow, SHAPE.nose, SHAPE.eye
	local count = math.clamp(math.floor((x1 - x0 - 12) / mo.spacing) + 1, 4, mo.max)
	local crownOf = A - SHAPE.soffit - mo.clear
	local foot = crownOf - mo.slant -- the forehead's foot: the brow's top
	local browLo = foot - brow.height
	local mz0 = zP + 1.8
	local mz1 = mz0 + mo.depth
	for i = 1, count do
		local cx = x0 + 6 + (x1 - x0 - 12) * (i - 1) / (count - 1)
		local a, b = cx - mo.width / 2, cx + mo.width / 2
		Kit.box(m, `Monolith{i}`, Vector3.new(a, -KIT.bury, mz0), Vector3.new(b, foot, mz1), STONE)
		-- The forehead recedes up and back from the brow to the flat crown.
		Kit.wedge(m, `Head{i}`, Vector3.new(a, foot, mz0), Vector3.new(b, crownOf, mz1), "back", STONE)
		Kit.trim(m, `Brow{i}`, Vector3.new(a, browLo, mz0 - brow.proud), Vector3.new(b, foot, mz0 + 0.4), STONE)
		-- The nose: deepest at its foot, running back into the face under the brow.
		Kit.wedge(
			m,
			`Nose{i}`,
			Vector3.new(cx - nose.width / 2, browLo - nose.length, mz0 - nose.proud),
			Vector3.new(cx + nose.width / 2, browLo + 0.05, mz0 + 0.05),
			"back",
			STONE,
			"trim"
		)
		-- The eye slots: one strip under the brow, its middle hidden behind the nose's bridge.
		local eyeTop = browLo - eye.below
		Kit.neonStrip(
			m,
			`Eyes{i}`,
			Vector3.new(cx - eye.width / 2, eyeTop - eye.height, mz0 - 0.06),
			Vector3.new(cx + eye.width / 2, eyeTop, mz0 + 0.02),
			"neonAmber",
			rgb(46, 43, 40)
		)
	end

	-------------------------------------------------------------------------------------------------------
	-- The towers: three in a row on the deck, the shorter third at one end
	-------------------------------------------------------------------------------------------------------
	local span = x1 - x0 - 2 * SHAPE.towerMargin
	local tw = math.min(SHAPE.towerMax, (span - 2 * SHAPE.towerGap) / 3)
	local gapT = (span - 3 * tw) / 2
	local wa, wb = tw * SHAPE.blockA, tw * SHAPE.blockB
	local zu1 = hd - 0.5 - SHAPE.plate.faces -- the back slabs' backs: their balconies just inside the back line
	local tD = math.clamp(zu1 - SHAPE.shift - (zP + SHAPE.deck), SHAPE.towerDepth[1], SHAPE.towerDepth[2])
	local every = SHAPE.plateEvery[rhythm]
	local step = SHAPE.stepFloors * SHAPE.floor
	local front = zu1 - tD - SHAPE.shift -- the forward slabs' fronts
	local mainLines = pal.frame
	local plainLines = pal.plain:Lerp(pal.frame, 0.35)
	local deepGlass = Kit.glassLook(pal.glass)

	for k = 1, 3 do
		local t = `T{k}`
		local xl = x0 + SHAPE.towerMargin + (k - 1) * (tw + gapT)
		local topA = if k == 3 then H * SHAPE.hotelShare else H
		local topB = topA - step
		-- The first and third towers keep their main slab on the left, the second on the right: the twins face each
		-- other across the middle.
		local mainLeft = k ~= 2
		local ax0 = if mainLeft then xl else xl + tw - wa
		local bx0 = if mainLeft then xl + tw - wb else xl
		local ax1, bx1 = ax0 + wa, bx0 + wb
		-- Rhythm 1 steps the second slab forward of the main one, rhythm 2 the main one forward of the second.
		local az0, bz0 = zu1 - tD, front
		if rhythm == 2 then
			az0, bz0 = front, zu1 - tD
		end
		local az1, bz1 = az0 + tD, bz0 + tD

		-- The main slab: glass under a dense white grid, a real balcony every `every`, the lift-lobby stripe.
		Kit.glass(m, `{t}Main`, Vector3.new(ax0, deckY - 0.5, az0), Vector3.new(ax1, topA, az1), pal.glass, {
			image = City.textures.windowBold,
			faces = { Enum.NormalId.Front, Enum.NormalId.Left, Enum.NormalId.Right },
			u = SHAPE.gridBay,
			v = SHAPE.floor,
			lines = mainLines,
		})
		Kit.plates(
			m,
			`{t}Plate`,
			Vector3.new(ax0, 0, az0),
			Vector3.new(ax1, 0, az1),
			deckY + every,
			topA - 10,
			every,
			SHAPE.plate.thick,
			SHAPE.plate.ends,
			SHAPE.plate.faces,
			frame
		)
		-- The stripe stands on the main slab's front beside the second slab (where the two meet, the lift lobby).
		local sx0 = if mainLeft then bx0 - 1 - SHAPE.stripe else bx1 + 1
		Kit.neonStrip(
			m,
			`{t}Stripe`,
			Vector3.new(sx0, deckY + 2, az0 - 0.4),
			Vector3.new(sx0 + SHAPE.stripe, topB - 6, az0 - 0.22),
			"neonAmber",
			pal.frame
		)
		local runSpan = topA - deckY - 16
		local run0 = deckY + 4 + rng:NextNumber() * runSpan * (1 - SHAPE.skinShare)
		local skin = Kit.detail(
			m,
			`{t}Lit`,
			Vector3.new(ax0 + 1, run0, az0 - 0.18),
			Vector3.new(ax1 - 1, run0 + runSpan * SHAPE.skinShare, az0 - 0.06),
			deepGlass
		)
		skin.textures = {
			{
				face = Enum.NormalId.Front,
				image = City.textures.windowBold,
				u = SHAPE.gridBay,
				v = SHAPE.floor,
				color = mainLines,
			},
		}
		Kit.lit(skin, "window")

		-- The second slab: plain dark glass with fine mullions, a white cap.
		Kit.glass(m, `{t}Second`, Vector3.new(bx0, deckY - 0.5, bz0), Vector3.new(bx1, topB, bz1), pal.plain, {
			image = City.textures.windowFine,
			faces = { Enum.NormalId.Front },
			u = 5,
			v = SHAPE.floor,
			lines = plainLines,
		})
		Kit.trim(
			m,
			`{t}SecondCap`,
			Vector3.new(bx0 - 0.6, topB, bz0 - 0.6),
			Vector3.new(bx1 + 0.6, topB + 1.2, bz1 + 0.6),
			frame
		)

		-- The main slab's top.
		if variant.crown == 1 then
			-- A white lattice screen round the roof: the walls are dark glass under the punched overlay in white.
			local sh, th = SHAPE.screen.height, SHAPE.screen.thick
			local lo, hi = topA - 0.05, topA + sh
			local walls = {
				{
					name = "Front",
					a = Vector3.new(ax0 - 0.1, lo, az0 - 0.1),
					b = Vector3.new(ax1 + 0.1, hi, az0 - 0.1 + th),
					face = Enum.NormalId.Front,
				},
				{
					name = "Back",
					a = Vector3.new(ax0 - 0.1, lo, az1 + 0.1 - th),
					b = Vector3.new(ax1 + 0.1, hi, az1 + 0.1),
					face = Enum.NormalId.Back,
				},
				{
					name = "Left",
					a = Vector3.new(ax0 - 0.1, lo + 0.02, az0 - 0.1 + th),
					b = Vector3.new(ax0 - 0.1 + th, hi - 0.02, az1 + 0.1 - th),
					face = Enum.NormalId.Left,
				},
				{
					name = "Right",
					a = Vector3.new(ax1 + 0.1 - th, lo + 0.02, az0 - 0.1 + th),
					b = Vector3.new(ax1 + 0.1, hi - 0.02, az1 + 0.1 - th),
					face = Enum.NormalId.Right,
				},
			}
			-- The long walls are the lattice; the short ends are solid white, the frame's sides.
			for _, wall in walls do
				local lattice = wall.face == Enum.NormalId.Front or wall.face == Enum.NormalId.Back
				local spec = Kit.trim(m, `{t}Screen{wall.name}`, wall.a, wall.b, if lattice then deepGlass else frame)
				if lattice then
					spec.textures = {
						{
							face = wall.face,
							image = City.textures.punched,
							u = SHAPE.gridBay,
							v = sh / 2,
							color = pal.frame,
						},
					}
				end
			end
		else
			-- A lit glass tier set in over a white cornice, under a roof slab.
			local inset, rise = SHAPE.tier.inset, SHAPE.tier.height
			Kit.trim(
				m,
				`{t}Cornice`,
				Vector3.new(ax0 - 0.8, topA - 0.6, az0 - 0.8),
				Vector3.new(ax1 + 0.8, topA + 0.6, az1 + 0.8),
				frame
			)
			local tierA = Vector3.new(ax0 + inset, topA + 0.6, az0 + inset)
			local tierB = Vector3.new(ax1 - inset, topA + 0.6 + rise, az1 - inset)
			Kit.glass(m, `{t}Tier`, tierA, tierB, pal.glass, {
				image = City.textures.windowFine,
				faces = { Enum.NormalId.Front },
				u = 4,
				v = rise,
				lines = mainLines,
			})
			Kit.neonStrip(
				m,
				`{t}TierRing`,
				Vector3.new(tierA.X - 0.15, tierB.Y - 1.6, tierA.Z - 0.15),
				Vector3.new(tierB.X + 0.15, tierB.Y - 1.2, tierB.Z + 0.15),
				"ledBlue", -- amber and blue only: two neon colours a building

				pal.frame
			)
			Kit.trim(
				m,
				`{t}TierRoof`,
				Vector3.new(tierA.X - 1.2, tierB.Y - 0.05, tierA.Z - 1.2),
				Vector3.new(tierB.X + 1.2, tierB.Y + 1.2, tierB.Z + 1.2),
				frame
			)
		end
	end

	-------------------------------------------------------------------------------------------------------
	-- The pool deck in front of the towers: a long pool, two market umbrellas, a planter
	-------------------------------------------------------------------------------------------------------
	local d0 = zP + 1
	local d1 = front - 1.5
	local deck = d1 - d0
	-- The pool grows with the deck (a deep site's deck is a plaza) and sits across its middle.
	local poolDepth = math.min(math.clamp(deck * 0.25, 4, 10), deck - 4.6)
	local px0, px1 = x0 + 6, x0 + 6 + (x1 - x0) * SHAPE.pool
	local pz0 = d0 + math.max(1, (deck - poolDepth) / 2)
	if poolDepth >= 2 then
		Kit.pool(m, "Pool", Vector3.new(px0, 0, pz0), Vector3.new(px1, 0, pz0 + poolDepth), deckY)
	end
	local uz = math.clamp(pz0 + poolDepth / 2, d0 + 3.2, d1 - 3.2)
	for i, ux in { x1 - 10, x1 - 22 } do
		Kit.umbrella(m, `Umbrella{i}`, ux, uz, deckY, 6, if i == 1 then pal.frame else P.deco.aqua, true)
	end
	Kit.planter(m, "Planter", Vector3.new(x1 - 44, deckY, d0 + 0.6), Vector3.new(x1 - 30, deckY + 1.4, d0 + 2.8), frame)
	-- A deep deck: planters along the pool's back edge.
	if deck >= 30 then
		for i, at in { 0.2, 0.7 } do
			local px = px0 + (px1 - px0) * at
			Kit.planter(
				m,
				`PoolPlanter{i}`,
				Vector3.new(px - 6, deckY, pz0 + poolDepth + 2.5),
				Vector3.new(px + 6, deckY + 1.4, pz0 + poolDepth + 4.7),
				frame
			)
		end
	end
end

local archetype: Types.Archetype = { id = "triple_tower_podium", build = build }
return archetype
