--!strict
-- B03 sign_tower_prow_hotel (docs/city/ARCHETYPES.md §6, B03): the beach strip's ship-bow hotel. Two white wings of
-- three storeys, their windows under coloured eyebrows that wrap the front and both sides with crisp square corners,
-- over a full-width porch: the upper floors overhang a lit lobby on square posts behind a café terrace. Between the
-- wings stands the signature: a sign tower pushing out of the facade as a pointed ship's bow, both faces of the bow
-- in the hotel's colour carrying the name stacked in white, a pale ridge down its point, and the tower's shoulders
-- stepping down either side of it like a ziggurat, each striped with a racing line. Speed-line panels of two colours
-- flank the tower on the wings, a flat sun deck cantilevers from each shoulder at roof level over white pipe rails
-- along the wings' roofs, the name runs across the tower's foot over a coloured door canopy, and the bow climbs far
-- over the roof to a needle or turned tiers.
--
-- What makes it itself: a ship's-bow sign tower, its two coloured faces lettered, pushing out of the middle of a low
-- banded hotel and stepping up far over its roof.
-- Placement, sizes, heights and its budget: Config/CityArchetypes/sign_tower_prow_hotel.
-- Variants: palette (4: the bow and eyebrow colour, the stripe colour, the letters, the two neons), crown (1 a tall
-- needle with a lit ball on the bow's flat top, 2 the bow climbing on in three shrinking turned tiers to a short
-- mast), rhythm (1 the tower centred, 2 the tower off-centre toward the left), mirror (the off-centre tower and the
-- stair house change sides).
--
-- Round 3 (2026-10-26, from photos of the inspiration): the bow's faces coloured with white letters, the stepped
-- shoulders, the two-colour speed-line panels, coloured eyebrows, the porch on posts, the sun decks and the name over
-- the door. Preview check: the letters sit on the bow's two street faces (the sleeve's Front and Right faces), the
-- shoulders read as two steps down from the bow, the speed-line panels read as stripes of two colours, the sun decks'
-- posts land on the roof, and at night the ridge, the racing lines and the cornice line show only two neon colours.
-- Round 4 (2026-10-26, seen in Studio): one-word names only on the bow (a two-word one left a gap in the stack).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local City = require(ReplicatedStorage.Shared.Config.City)
local Kit = require(script.Parent.Parent.Parent.Kit)
local MapTypes = require(script.Parent.Parent.Parent.Parent.MapTypes)
local Types = require(script.Parent.Parent.Parent.Types)

local P = City.palettes
local KIT = City.kit
local FONT = City.districtLooks.beach.font
local rgb = Color3.fromRGB

-- The recipe, in studs.
local SHAPE = {
	ground = 14,
	parapet = 3.4, -- at least
	floorMin = 10.3,
	floorMax = 12,
	floors = { 2, 2 },
	terrace = 10,
	bodyDepth = 38,
	sideInset = 3.2, -- the eyebrows wrap the sides, so the walls keep this far in
	porch = 4, -- the lobby's wall, behind the upper floors' face: a porch on posts
	pier = 2.2, -- the porch's end walls
	post = 1.4, -- the porch posts, square
	posts = 2, -- per wing
	skinMargin = 0.6, -- stucco left at the ends of the windowed front
	bay = 6.5, -- a window bay (about)
	eyebrow = { thick = 0.6, proud = 2.6 },
	canopy = { thick = 0.9, proud = 2.6 },
	cornice = { thick = 1, proud = 1.4 },
	-- The tower: wide enough that shoulders show either side of the bow. The bow's half-width is a share of the
	-- tower's width (its point stands as far out of the tower); with the tower `proud` of the facade and the terrace
	-- 10 deep, the bow's cap stays inside the front line at the widest tower.
	tower = { share = 0.26, min = 16, max = 22, proud = 2.8, deep = 12 },
	prow = 0.26,
	ridge = 1.1, -- the pale ridge down the bow's point
	stripe = 1.2, -- the racing line on each shoulder
	-- The tower's top over the roof, by crown: about half the wings' height again, so it reads as the sign tower from
	-- down the strip. Its shoulders step down: the full tower to `shoulders[1]` of that rise, then halfway in toward
	-- the bow's core to `shoulders[2]`; the core (the bow and a margin) goes on to the top.
	rise = { 22, 24 },
	shoulders = { 0.38, 0.7 },
	speed = { width = 3.4, every = 1.2 }, -- the speed-line panels beside the tower
	deck = { out = 7, deep = 6.5, over = 6.4, thick = 0.6, post = 0.5 }, -- the sun decks off the shoulders
	needle = 40, -- crown 1: the needle's top over the roof
	mast = 40, -- crown 2: the mast's top over the roof
	tiers = { { share = 0.78, rise = 3.4 }, { share = 0.56, rise = 3 }, { share = 0.34, rise = 2.6 } },
	door = { canopyUnder = 3.2, thick = 0.8, out = 4, wider = 2.5, margin = 2.4 },
	offset = 0.2, -- rhythm 2: the tower this share of the width off centre (as far as fits)
	sideBay = 6.5,
	terraceTop = 0.9,
	balustrade = 2.2,
	umbrella = 7.5,
}

-- The bow and eyebrow colour (the hotel's), its neon on the ridge; the racing lines' and speed lines' second colour
-- and its neon; the bow's letters and the ridge's day colour; the wash.
local PALETTES = {
	{
		bow = rgb(46, 90, 172),
		ridge = rgb(246, 244, 238),
		bowKind = "neonBlue",
		stripe = P.deco.lemon,
		stripeKind = "neonAmber",
		letters = rgb(250, 248, 240),
		wash = rgb(150, 180, 255),
	},
	{
		bow = rgb(240, 118, 100),
		ridge = P.deco.sky,
		bowKind = "neonPink",
		stripe = P.deco.sky,
		stripeKind = "neonCyan",
		letters = rgb(250, 248, 240),
		wash = rgb(255, 150, 160),
	},
	{
		bow = rgb(118, 84, 190),
		ridge = P.deco.mint,
		bowKind = "neonViolet",
		stripe = P.deco.mint,
		stripeKind = "neonCyan",
		letters = rgb(250, 248, 240),
		wash = rgb(200, 150, 255),
	},
	{
		bow = rgb(28, 140, 150),
		ridge = P.deco.pink,
		bowKind = "neonCyan",
		stripe = P.deco.pink,
		stripeKind = "neonPink",
		letters = rgb(250, 248, 240),
		wash = rgb(255, 140, 200),
	},
}

local FRONT, LEFT, RIGHT = Enum.NormalId.Front, Enum.NormalId.Left, Enum.NormalId.Right
local TURN = CFrame.Angles(0, math.pi / 4, 0) -- a square turned to a diamond: one corner points at the street
local ROOT2 = math.sqrt(2)

-- Upper floors and their height for a roof at `height`: whole floors, the parapet taking up the rest.
local function storeys(height: number): (number, number)
	local room = height - SHAPE.ground - SHAPE.parapet
	local up = math.clamp(math.floor(room / SHAPE.floorMin + 1e-6), SHAPE.floors[1], SHAPE.floors[2])
	return up, math.min(room / up, SHAPE.floorMax)
end

-- A hotel name for the bow: one word short enough to stack (the leading "THE " dropped), its letters one per line;
-- and the name in full for the board over the door.
local function pickName(rng: Random): (string, string)
	local short: { string } = {}
	for _, name in City.signNames.hotels do
		local word = string.gsub(name, "^THE ", "")
		if #word <= 9 and not string.find(word, " ", 1, true) then
			table.insert(short, name)
		end
	end
	local list = if #short > 0 then short else City.signNames.hotels
	local name = list[rng:NextInteger(1, #list)]
	local word = string.gsub(name, "^THE ", "")
	local letters: { string } = {}
	for i = 1, #word do
		table.insert(letters, string.sub(word, i, i))
	end
	return table.concat(letters, "\n"), name
end

local function build(m: Types.Model)
	local site = m.site
	local variant = site.variant
	local pal = PALETTES[math.clamp(variant.palette, 1, #PALETTES)]
	local crown = math.clamp(variant.crown, 1, 2)
	local rng = Kit.rng(m)
	local W, D = site.width, site.depth
	local hw, hd = W / 2, D / 2
	local G = SHAPE.ground
	local H = site.height
	local up, f = storeys(H)
	local T = G + up * f -- the top floor line

	local white = Kit.look(P.deco.white, Enum.Material.SmoothPlastic)
	local bowLook = Kit.look(pal.bow, Enum.Material.SmoothPlastic)
	local stripeLook = Kit.look(pal.stripe, Enum.Material.SmoothPlastic)

	local x0, x1 = -hw + SHAPE.sideInset, hw - SHAPE.sideInset
	local zF = -hd + SHAPE.terrace -- the upper floors' face
	local zB = math.min(hd - 1, zF + SHAPE.bodyDepth)
	local zWall = zF + SHAPE.porch -- the lobby's wall, at the back of the porch

	-- The tower: centred, or (rhythm 2) toward the left as far as leaves both wings room.
	local tower = SHAPE.tower
	local tw = math.clamp(W * tower.share, tower.min, tower.max)
	local tx = 0
	if variant.rhythm == 2 then
		tx = -math.clamp(W * SHAPE.offset, 0, (x1 - x0) / 2 - tw / 2 - 8)
	end
	local zT = zF - tower.proud -- the tower's face
	local rise = SHAPE.rise[crown]
	local tTop = H + rise
	local d = tw * SHAPE.prow -- the bow's half-width and how far its point stands out of the tower
	local zTip = zT - d

	-------------------------------------------------------------------------------------------------------
	-- The wings: body, the upper floors over the porch, punched windows, coloured eyebrows round three sides
	-------------------------------------------------------------------------------------------------------
	Kit.box(m, "Body", Vector3.new(x0, -KIT.bury, zWall), Vector3.new(x1, H, zB), white)
	Kit.box(m, "Upper", Vector3.new(x0 - 0.05, G, zF), Vector3.new(x1 + 0.05, H - 0.04, zWall + 0.4), white)
	for i, side in { -1, 1 } do
		local outer = if side < 0 then x0 - 0.05 else x1 + 0.05
		local inner = if side < 0 then x0 + SHAPE.pier else x1 - SHAPE.pier
		Kit.box(m, `Pier{i}`, Vector3.new(outer, -KIT.bury, zF + 0.05), Vector3.new(inner, G, zWall + 0.3), white)
	end
	Kit.glass(
		m,
		"Shop",
		Vector3.new(x0 + SHAPE.pier, SHAPE.terraceTop - 0.3, zWall - 0.3),
		Vector3.new(x1 - SHAPE.pier, G - 0.6, zWall + 0.2),
		P.window.dark,
		{
			image = City.textures.windowBold,
			faces = { FRONT },
			u = 4,
			v = G - 0.3 - SHAPE.terraceTop,
			lines = P.deco.white,
			lit = true,
		}
	)
	-- The porch posts, set in a little from the upper floors' face, evenly along each wing.
	local wings = { { x0 + SHAPE.pier, tx - tw / 2 }, { tx + tw / 2, x1 - SHAPE.pier } }
	local postZ = zF + 0.9
	for i, wing in wings do
		local a, b = wing[1], wing[2]
		local count = if b - a < 10 then 1 else SHAPE.posts -- a short wing (the tower off-centre) gets one
		for j = 1, count do
			local px = a + (b - a) * j / (count + 1)
			local h = SHAPE.post / 2
			Kit.box(
				m,
				`Post{i}{j}`,
				Vector3.new(px - h, SHAPE.terraceTop - 0.2, postZ - h),
				Vector3.new(px + h, G + 0.02, postZ + h),
				white
			)
		end
	end
	local sx0, sx1 = x0 + SHAPE.skinMargin, x1 - SHAPE.skinMargin
	local bays = math.max(2, math.round((sx1 - sx0) / SHAPE.bay))
	Kit.punched(
		m,
		"Skin",
		Vector3.new(sx0, G, zF - 0.06),
		Vector3.new(sx1, T, zF + 0.3),
		P.deco.white,
		P.window.dark,
		{ FRONT },
		(sx1 - sx0) / bays,
		f
	)
	for i, side in { -1, 1 } do
		local wallX = if side < 0 then x0 else x1
		Kit.punched(
			m,
			`Side{i}`,
			Vector3.new(wallX - side * 0.4, G, zWall + 0.6),
			Vector3.new(wallX + side * 0.06, T, zB - 0.6),
			P.deco.white,
			P.window.dark,
			{ if side < 0 then LEFT else RIGHT },
			SHAPE.sideBay,
			f
		)
	end

	-- An eyebrow is one slab round the front and both sides (square corners), its back end short of the back wall.
	local function wrap(name: string, y: number, thick: number, proud: number, look: Kit.Look)
		Kit.trim(
			m,
			name,
			Vector3.new(x0 - proud, y - thick / 2, zF - proud),
			Vector3.new(x1 + proud, y + thick / 2, zB - 0.5),
			look
		)
	end
	wrap("Canopy", G, SHAPE.canopy.thick, SHAPE.canopy.proud, white)
	for k = 1, up do
		-- The punched windows top out 12 % of a floor under the floor line; the eyebrow sits just over them.
		local brow = SHAPE.eyebrow
		wrap(`Brow{k}`, G + k * f - 0.12 * f + brow.thick / 2 + 0.1, brow.thick, brow.proud, bowLook)
	end
	local cn = SHAPE.cornice
	wrap("Cornice", H - cn.thick / 2 + 0.06, cn.thick, cn.proud, white)
	-- A neon line in the cornice's shadow.
	Kit.neon(
		m,
		"CorniceNeon",
		Vector3.new(x0 + 0.3, H - cn.thick - 0.35, zF - 0.45),
		Vector3.new(x1 - 0.3, H - cn.thick - 0.35, zF - 0.45),
		pal.stripeKind,
		pal.stripe
	)
	-- Speed lines beside the tower: a panel in the stripe colour under the punched overlay tinted the bow's colour,
	-- one opening a tile, so it reads as bars of the two colours.
	local sp = SHAPE.speed
	for i, side in { -1, 1 } do
		local a = tx + side * tw / 2
		local b = a + side * sp.width
		local panel = Kit.detail(
			m,
			`Speed{i}`,
			Vector3.new(math.min(a, b), G + 0.6, zF - 0.2),
			Vector3.new(math.max(a, b), T + 0.4 * (H - T), zF + 0.1),
			stripeLook
		)
		panel.textures = {
			{ face = Kit.face(m, FRONT), image = City.textures.punched, u = sp.width, v = sp.every, color = pal.bow },
		}
	end

	-------------------------------------------------------------------------------------------------------
	-- The sign tower: stepped shoulders, the bow with the name, the ridge, the racing lines, the door, the sun decks
	-------------------------------------------------------------------------------------------------------
	local core = d + 1.2 -- the core's half-width: the bow and a margin
	local yS1 = H + rise * SHAPE.shoulders[1]
	local yS2 = H + rise * SHAPE.shoulders[2]
	Kit.box(m, "Tower", Vector3.new(tx - tw / 2, -KIT.bury, zT), Vector3.new(tx + tw / 2, yS1, zT + tower.deep), white)
	local inner = (tw / 2 + core) / 2
	Kit.box(
		m,
		"TowerMid",
		Vector3.new(tx - inner, yS1 - 0.04, zT + 0.02),
		Vector3.new(tx + inner, yS2, zT + tower.deep - 0.6),
		white
	)
	Kit.box(
		m,
		"TowerCore",
		Vector3.new(tx - core, yS2 - 0.04, zT + 0.04),
		Vector3.new(tx + core, tTop, zT + tower.deep - 1.2),
		white
	)

	local s = d * ROOT2 -- the turned square's side
	local py0, py1 = G + 0.6, tTop - 0.05
	Kit.oriented(
		m,
		"Prow",
		"block",
		CFrame.new(tx, (py0 + py1) / 2, zT) * TURN,
		Vector3.new(s, py1 - py0, s),
		bowLook,
		"box"
	)
	-- The letters ride on a sleeve a hair proud of the bow's two street faces (its Front and Right once turned), so
	-- the bow itself stays with the building's still parts; Kit.face keeps those faces when mirrored.
	local stacked, fullName = pickName(rng)
	local sleeve = Kit.oriented(
		m,
		"ProwLetters",
		"block",
		CFrame.new(tx, (py0 + py1) / 2, zT) * TURN,
		Vector3.new(s + 0.12, py1 - py0 - 3, s + 0.12),
		bowLook,
		"detail"
	)
	local labels: { MapTypes.LabelSpec } = {}
	for _, face in { FRONT, RIGHT } do
		table.insert(labels, {
			face = Kit.face(m, face),
			text = stacked,
			color = pal.letters,
			font = FONT,
			size = Vector2.new(0.7, 0.94),
			pixelsPerStud = KIT.signPixelsPerStud,
		})
	end
	sleeve.labels = labels
	Kit.oriented(
		m,
		"ProwCap",
		"block",
		CFrame.new(tx, tTop + 0.45, zT) * TURN,
		Vector3.new(s + 1.2, 1, s + 1.2),
		white,
		"trim"
	)
	local k = SHAPE.ridge
	local ky0, ky1 = G + 1.2, tTop - 0.6
	local ridge = Kit.oriented(
		m,
		"Ridge",
		"block",
		CFrame.new(tx, (ky0 + ky1) / 2, zTip + k / ROOT2 - 0.3) * TURN,
		Vector3.new(k, ky1 - ky0, k),
		Kit.look(pal.ridge, Enum.Material.SmoothPlastic),
		"detail"
	)
	Kit.lit(ridge, pal.bowKind)
	-- A racing line up each shoulder, from the door canopy to just under the shoulder's step.
	local dr = SHAPE.door
	local shoulder = (d + tw / 2) / 2
	local sw = math.min(SHAPE.stripe, tw / 2 - d - 0.5)
	for i, side in { -1, 1 } do
		local cx = tx + side * shoulder
		local line = Kit.detail(
			m,
			`Racing{i}`,
			Vector3.new(cx - sw / 2, G - dr.canopyUnder + dr.thick + 0.4, zT - 0.3),
			Vector3.new(cx + sw / 2, yS1 - 0.8, zT + 0.2),
			stripeLook
		)
		Kit.lit(line, pal.stripeKind)
	end
	local doorTop = G - dr.canopyUnder
	Kit.glass(
		m,
		"Door",
		Vector3.new(tx - tw / 2 + dr.margin, SHAPE.terraceTop - 0.3, zT - 0.25),
		Vector3.new(tx + tw / 2 - dr.margin, doorTop, zT + 0.3),
		P.window.dark,
		{
			image = City.textures.windowBold,
			faces = { FRONT },
			u = (tw - 2 * dr.margin) / 2,
			v = doorTop - SHAPE.terraceTop + 0.3,
			lines = P.deco.white,
			lit = true,
		}
	)
	Kit.canopy(
		m,
		"DoorCanopy",
		tx - tw / 2 - dr.wider,
		tx + tw / 2 + dr.wider,
		zT - dr.out,
		zT + 0.5,
		doorTop,
		dr.thick,
		bowLook
	)
	-- The name across the tower's foot, standing on the door canopy under the bow.
	Kit.sign(
		m,
		"Sign",
		Vector3.new(tx - tw / 2 + 0.6, doorTop + dr.thick + 0.15, zT - 0.3),
		Vector3.new(tx + tw / 2 - 0.6, G + 0.3, zT - 0.05),
		FRONT,
		fullName,
		P.deco.white,
		pal.bow,
		FONT
	)
	-- A white pipe rail along each wing's roof edge, set in behind the cornice.
	for i, side in { -1, 1 } do
		local a = if side < 0 then x0 + 0.8 else tx + tw / 2 + 0.3
		local b = if side < 0 then tx - tw / 2 - 0.3 else x1 - 0.8
		if b - a > 2 then
			Kit.railing(
				m,
				`Rail{i}`,
				Vector3.new(a, H + 0.08, zF + 0.6),
				Vector3.new(b, H + 3.2, zF + 0.8),
				{ FRONT },
				P.deco.white,
				1.4
			)
		end
	end
	-- The sun decks: a flat slab off each shoulder at roof level, held at its outer front corner by one post.
	local dk = SHAPE.deck
	for i, side in { -1, 1 } do
		local a = tx + side * (tw / 2 - 0.3)
		local room = if side < 0 then (tx - tw / 2) - x0 else x1 - (tx + tw / 2)
		local out = math.min(dk.out, room - 1.5)
		if out < 3 then
			continue
		end
		local b = tx + side * (tw / 2 + out)
		local y = H + dk.over
		Kit.trim(
			m,
			`Deck{i}`,
			Vector3.new(math.min(a, b), y, zF - 0.6),
			Vector3.new(math.max(a, b), y + dk.thick, zF - 0.6 + dk.deep),
			white
		)
		local px = b - side * (dk.post / 2 + 0.4)
		Kit.column(m, `DeckPost{i}`, px, zF + 0.2, H - 0.1, y + 0.02, dk.post, white, "trim")
	end

	-- The top: a needle on the bow's flat top (crown 1), or the bow climbing on in shrinking turned tiers (crown 2).
	local chrome = Kit.look(rgb(220, 224, 228), Enum.Material.Metal)
	if crown == 1 then
		local base = tTop + 0.95
		local needle = H + SHAPE.needle
		Kit.spire(m, "Needle", tx, zT, base, needle - base, 1.6, chrome, 3, false)
		Kit.lit(Kit.ball(m, "Ball", Vector3.new(tx, needle + 0.5, zT), 1.2, stripeLook), pal.stripeKind)
	else
		local y = tTop + 0.93
		for i, tier in SHAPE.tiers do
			local side = s * tier.share
			Kit.oriented(
				m,
				`Tier{i}`,
				"block",
				CFrame.new(tx, y + tier.rise / 2, zT) * TURN,
				Vector3.new(side, tier.rise, side),
				if i % 2 == 1 then white else bowLook,
				"box"
			)
			y += tier.rise - 0.02
		end
		local mast = H + SHAPE.mast
		Kit.column(m, "Mast", tx, zT, y, mast, 0.5, chrome, "detail")
		Kit.lit(Kit.ball(m, "Ball", Vector3.new(tx, mast + 0.6, zT), 1.2, bowLook), pal.bowKind)
	end
	Kit.roofBox(m, "Stair", Vector3.new(x1 - 11, H, zB - 10), Vector3.new(x1 - 4, H + 6, zB - 3), white)

	-------------------------------------------------------------------------------------------------------
	-- The café terrace, open in front of the tower, with market umbrellas on the wings; the wash on the canopy
	-------------------------------------------------------------------------------------------------------
	local tTopY = SHAPE.terraceTop
	Kit.box(
		m,
		"Terrace",
		Vector3.new(-hw + 0.2, 0, -hd + 0.3),
		Vector3.new(hw - 0.2, tTopY, zWall + 0.2),
		Kit.look(P.deco.terrazzo, Enum.Material.SmoothPlastic)
	)
	local railTop = tTopY + SHAPE.balustrade
	-- The umbrellas may reach under the porch canopy's edge (they top out well under it), not past the posts.
	local front = zF - 0.4
	local tz = (-hd + 1.4 + front) / 2
	local room = math.min(SHAPE.umbrella, (front - 0.4 - tz) * 2, (tz + hd - 1.4) * 2)
	local segments = { { -hw + 0.6, tx - tw / 2 - 1 }, { tx + tw / 2 + 1, hw - 0.6 } }
	for i, seg in segments do
		local a, b = seg[1], seg[2]
		if b - a < 1 then
			continue
		end
		Kit.box(m, `Balustrade{i}`, Vector3.new(a, tTopY, -hd + 0.6), Vector3.new(b, railTop, -hd + 1.3), white)
		Kit.detail(
			m,
			`Coping{i}`,
			Vector3.new(a - 0.1, railTop, -hd + 0.5),
			Vector3.new(b + 0.1, railTop + 0.35, -hd + 1.4),
			stripeLook
		)
		local len = b - a - 1.6
		local count = math.clamp(math.floor(len / (room + 3)), 0, 2)
		for j = 1, count do
			local x = a + 0.8 + len * (j - 0.5) / count
			local color = if (i + j) % 2 == 0 then pal.stripe else P.deco.white
			Kit.umbrella(m, `Umbrella{i}{j}`, x, tz, tTopY, math.max(2, math.min(room, len / count - 1)), color, true)
		end
	end
	-- On the door canopy, washing the bow.
	Kit.wash(m, "Wash", tx - tw / 2 - 1.5, tx + tw / 2 + 1.5, zT - 2, doorTop + dr.thick, pal.wash)
end

local archetype: Types.Archetype = { id = "sign_tower_prow_hotel", build = build }
return archetype
