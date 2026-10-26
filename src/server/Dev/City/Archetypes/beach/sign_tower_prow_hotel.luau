--!strict
-- B03 sign_tower_prow_hotel (docs/city/ARCHETYPES.md §6, B03): the beach strip's ship-bow hotel. Two white wings of
-- three storeys, their punched windows under eyebrows that wrap the front and both sides with crisp square corners,
-- the lobby set back under the upper floors behind a café terrace, a neon line under a deep cornice. Between the
-- wings stands the signature: a sign tower pushing out of the facade as a pointed ship's prow (a square turned 45
-- degrees), the name stacked down both of the prow's faces, a coloured keel stripe down its point and two stripes in
-- a second colour on the tower's shoulders, rising far over the roof to a stepped top and a needle with a lit ball.
-- The entrance is in the tower's foot under a coloured canopy, and the wings' parapet steps up toward the tower.
--
-- What makes it itself: a striped ship's-bow sign tower pushing out of the middle of a low hotel and far over its roof.
-- Placement, sizes, heights and its budget: Config/CityArchetypes/sign_tower_prow_hotel.
-- Variants: palette (4 keel and shoulder colour pairs, each with its two neons), crown (1 two setback steps and a tall
-- needle, 2 the prow climbing on in three shrinking turned tiers to a short mast), rhythm (1 the tower centred with
-- the parapet stepping up to it, 2 the tower off-centre with the steps at the far end of the long wing), mirror (the
-- off-centre tower and the stair house change sides).
--
-- Previewed in Studio (2026-10-25, docs/images/city/sign_tower_prow_hotel-*.jpg): the prow, its stacked name and the
-- stripes read; round 2 raised the tower (16 over the roof read as a stair house from down the strip).

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
	porch = 1.2, -- the lobby's wall, behind the upper floors' face
	pier = 2.2, -- the lobby's corner piers
	skinMargin = 0.6, -- stucco left at the ends of the windowed front
	bay = 6.5, -- a window bay (about)
	eyebrow = { thick = 0.6, proud = 2.6 },
	canopy = { thick = 0.9, proud = 2.6 },
	cornice = { thick = 1, proud = 1.4 },
	tower = { share = 0.2, min = 13, max = 17, proud = 2.8, deep = 12 },
	prow = 0.34, -- the prow's half-width, a share of the tower's width (it stands as far out of the tower)
	keel = 1.4,
	stripe = 1.6,
	-- The tower's top over the roof, by crown: about half the wings' height again, so it reads as the sign tower from
	-- down the strip (16 read as a stair house in the preview).
	rise = { 22, 24 },
	steps = { { rise = 3.2, inset = 1.4 }, { rise = 3, inset = 1.4 } },
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

-- The keel colour and its neon, the shoulder stripes' colour and neon, the letters, the wash.
local PALETTES = {
	{
		keel = rgb(46, 90, 172),
		keelKind = "neonBlue",
		stripe = P.deco.lemon,
		stripeKind = "neonAmber",
		letters = rgb(46, 90, 172),
		wash = rgb(150, 180, 255),
	},
	{
		keel = rgb(240, 118, 100),
		keelKind = "neonPink",
		stripe = P.deco.sky,
		stripeKind = "sign",
		letters = rgb(214, 74, 74),
		wash = rgb(255, 150, 160),
	},
	{
		keel = P.deco.lilac,
		keelKind = "neonViolet",
		stripe = P.deco.mint,
		stripeKind = "sign",
		letters = rgb(118, 84, 190),
		wash = rgb(200, 150, 255),
	},
	{
		keel = rgb(40, 168, 176),
		keelKind = "sign",
		stripe = P.deco.pink,
		stripeKind = "neonPink",
		letters = rgb(28, 128, 140),
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

-- A hotel name short enough to stack down the prow, its letters one per line (the leading "THE " dropped).
local function pickName(rng: Random): string
	local short: { string } = {}
	for _, name in City.signNames.hotels do
		if #(string.gsub(name, "^THE ", "")) <= 9 then
			table.insert(short, name)
		end
	end
	local list = if #short > 0 then short else City.signNames.hotels
	local word = string.gsub(list[rng:NextInteger(1, #list)], "^THE ", "")
	local letters: { string } = {}
	for i = 1, #word do
		table.insert(letters, string.sub(word, i, i))
	end
	return table.concat(letters, "\n")
end

-- Text on some faces of a part (SurfaceGuis; Kit.sign's look, on parts that aren't boards).
local function label(
	m: Types.Model,
	spec: Types.PartSpec,
	faces: { Enum.NormalId },
	text: string,
	color: Color3,
	size: Vector2
)
	local labels: { MapTypes.LabelSpec } = spec.labels or {}
	for _, face in faces do
		table.insert(labels, {
			face = Kit.face(m, face),
			text = text,
			color = color,
			font = FONT,
			size = size,
			pixelsPerStud = KIT.signPixelsPerStud,
		})
	end
	spec.labels = labels
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
	local keelLook = Kit.look(pal.keel, Enum.Material.SmoothPlastic)
	local stripeLook = Kit.look(pal.stripe, Enum.Material.SmoothPlastic)

	local x0, x1 = -hw + SHAPE.sideInset, hw - SHAPE.sideInset
	local zF = -hd + SHAPE.terrace -- the upper floors' face
	local zB = math.min(hd - 1, zF + SHAPE.bodyDepth)
	local zWall = zF + SHAPE.porch

	-- The tower: centred, or (rhythm 2) toward the left as far as leaves both wings room.
	local tower = SHAPE.tower
	local tw = math.clamp(W * tower.share, tower.min, tower.max)
	local tx = 0
	if variant.rhythm == 2 then
		tx = -math.clamp(W * SHAPE.offset, 0, (x1 - x0) / 2 - tw / 2 - 8)
	end
	local zT = zF - tower.proud -- the tower's face
	local tTop = H + SHAPE.rise[crown]
	local d = tw * SHAPE.prow -- the prow's half-width and how far its point stands out of the tower
	local zTip = zT - d

	-------------------------------------------------------------------------------------------------------
	-- The wings: body, the upper floors over the set-back lobby, punched windows, eyebrows round three sides
	-------------------------------------------------------------------------------------------------------
	Kit.box(m, "Body", Vector3.new(x0, -KIT.bury, zWall), Vector3.new(x1, H, zB), white)
	Kit.box(m, "Upper", Vector3.new(x0 - 0.05, G, zF), Vector3.new(x1 + 0.05, H - 0.04, zWall + 0.4), white)
	for i, sx in { -1, 1 } do
		local outer = if sx < 0 then x0 - 0.05 else x1 + 0.05
		local inner = if sx < 0 then x0 + SHAPE.pier else x1 - SHAPE.pier
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
	for i, sx in { -1, 1 } do
		local wallX = if sx < 0 then x0 else x1
		Kit.punched(
			m,
			`Side{i}`,
			Vector3.new(wallX - sx * 0.4, G, zWall + 0.6),
			Vector3.new(wallX + sx * 0.06, T, zB - 0.6),
			P.deco.white,
			P.window.dark,
			{ if sx < 0 then LEFT else RIGHT },
			SHAPE.sideBay,
			f
		)
	end

	-- An eyebrow is one slab round the front and both sides (square corners), its back end short of the back wall.
	local function wrap(name: string, y: number, thick: number, proud: number)
		Kit.trim(
			m,
			name,
			Vector3.new(x0 - proud, y - thick / 2, zF - proud),
			Vector3.new(x1 + proud, y + thick / 2, zB - 0.5),
			white
		)
	end
	wrap("Canopy", G, SHAPE.canopy.thick, SHAPE.canopy.proud)
	for k = 1, up do
		-- The punched windows top out 12 % of a floor under the floor line; the eyebrow sits just over them.
		local brow = SHAPE.eyebrow
		wrap(`Brow{k}`, G + k * f - 0.12 * f + brow.thick / 2 + 0.1, brow.thick, brow.proud)
	end
	local cn = SHAPE.cornice
	wrap("Cornice", H - cn.thick / 2 + 0.06, cn.thick, cn.proud)
	-- A neon line in the cornice's shadow.
	Kit.neon(
		m,
		"CorniceNeon",
		Vector3.new(x0 + 0.3, H - cn.thick - 0.35, zF - 0.45),
		Vector3.new(x1 - 0.3, H - cn.thick - 0.35, zF - 0.45),
		pal.stripeKind,
		pal.stripe
	)

	-- The parapet steps: up toward the tower (rhythm 1), or down from the far end of the long wing (rhythm 2).
	if variant.rhythm == 1 then
		local wing = math.min(tx - tw / 2 - x0, x1 - tx - tw / 2)
		local a1, a2 = tw / 2 + wing * 0.45, tw / 2 + wing * 0.2
		Kit.box(m, "Step1", Vector3.new(tx - a1, H - 0.05, zF + 0.4), Vector3.new(tx + a1, H + 3, zF + 4), white)
		Kit.box(m, "Step2", Vector3.new(tx - a2, H + 2.95, zF + 0.9), Vector3.new(tx + a2, H + 5.6, zF + 3.6), white)
	else
		local wing = x1 - (tx + tw / 2)
		local edge = x1 - 0.3
		Kit.box(
			m,
			"Step1",
			Vector3.new(edge - wing * 0.45, H - 0.05, zF + 0.4),
			Vector3.new(edge, H + 3, zF + 4),
			white
		)
		Kit.box(
			m,
			"Step2",
			Vector3.new(edge - wing * 0.22, H + 2.95, zF + 0.9),
			Vector3.new(edge - 0.3, H + 5.6, zF + 3.6),
			white
		)
	end

	-------------------------------------------------------------------------------------------------------
	-- The sign tower: the shaft, the prow with the name, the keel and shoulder stripes, the door and its canopy
	-------------------------------------------------------------------------------------------------------
	Kit.box(m, "Tower", Vector3.new(tx - tw / 2, -KIT.bury, zT), Vector3.new(tx + tw / 2, tTop, zT + tower.deep), white)
	local s = d * ROOT2 -- the turned square's side
	local py0, py1 = G + 0.6, tTop - 0.05
	local prow = Kit.oriented(
		m,
		"Prow",
		"block",
		CFrame.new(tx, (py0 + py1) / 2, zT) * TURN,
		Vector3.new(s, py1 - py0, s),
		white,
		"box"
	)
	-- The turned square's Front and Right faces are the two faces of the bow (Kit.face keeps them so mirrored).
	label(m, prow, { FRONT, RIGHT }, pickName(rng), pal.letters, Vector2.new(0.76, 0.94))
	Kit.oriented(
		m,
		"ProwCap",
		"block",
		CFrame.new(tx, tTop + 0.45, zT) * TURN,
		Vector3.new(s + 1.2, 1, s + 1.2),
		white,
		"trim"
	)
	local k = SHAPE.keel
	local ky0, ky1 = G + 1.6, tTop - 0.6
	local keel = Kit.oriented(
		m,
		"Keel",
		"block",
		CFrame.new(tx, (ky0 + ky1) / 2, zTip + k / ROOT2 - 0.3) * TURN,
		Vector3.new(k, ky1 - ky0, k),
		keelLook,
		"detail"
	)
	Kit.lit(keel, pal.keelKind)
	local dr = SHAPE.door
	local shoulder = (d + tw / 2) / 2
	local sw = math.min(SHAPE.stripe, tw / 2 - d - 0.5)
	for i, sx in { -1, 1 } do
		local cx = tx + sx * shoulder
		local stripe = Kit.detail(
			m,
			`Stripe{i}`,
			Vector3.new(cx - sw / 2, G - dr.canopyUnder + dr.thick, zT - 0.3),
			Vector3.new(cx + sw / 2, tTop - 0.5, zT + 0.2),
			stripeLook
		)
		Kit.lit(stripe, pal.stripeKind)
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
		keelLook
	)

	-- The top: setback steps and a needle (crown 1), or the prow climbing on in shrinking turned tiers (crown 2).
	local chrome = Kit.look(rgb(220, 224, 228), Enum.Material.Metal)
	local zc = zT + tower.deep / 2
	if crown == 1 then
		local _, top = Kit.setbacks(
			m,
			"TowerStep",
			Vector3.new(tx - tw / 2, 0, zT),
			Vector3.new(tx + tw / 2, tTop, zT + tower.deep),
			SHAPE.steps,
			white
		)
		local needle = H + SHAPE.needle
		Kit.spire(m, "Needle", tx, zc, top, needle - top, 1.6, chrome, 3, false)
		Kit.lit(Kit.ball(m, "Ball", Vector3.new(tx, needle + 0.5, zc), 1.2, stripeLook), pal.stripeKind)
	else
		Kit.box(
			m,
			"TowerStep",
			Vector3.new(tx - tw / 2 + 1.4, tTop - 0.02, zT + 1.4),
			Vector3.new(tx + tw / 2 - 1.4, tTop + 2.4, zT + tower.deep - 1.4),
			white
		)
		local y = tTop + 0.93
		for i, tier in SHAPE.tiers do
			local side = s * tier.share
			Kit.oriented(
				m,
				`Tier{i}`,
				"block",
				CFrame.new(tx, y + tier.rise / 2, zT + 1.2) * TURN,
				Vector3.new(side, tier.rise, side),
				white,
				"box"
			)
			y += tier.rise - 0.02
		end
		local mast = H + SHAPE.mast
		Kit.column(m, "Mast", tx, zT + 1.2, y, mast, 0.5, chrome, "detail")
		Kit.lit(Kit.ball(m, "Ball", Vector3.new(tx, mast + 0.6, zT + 1.2), 1.2, keelLook), pal.keelKind)
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
	local tz = (-hd + 1.4 + zF) / 2
	local room = math.min(SHAPE.umbrella, (zF - 0.4 - tz) * 2, (tz + hd - 1.4) * 2)
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
			Kit.umbrella(m, `Umbrella{i}{j}`, x, tz, tTopY, math.min(room, len / count - 1), color, true)
		end
	end
	-- On the door canopy, washing the prow.
	Kit.wash(m, "Wash", tx - tw / 2 - 1.5, tx + tw / 2 + 1.5, zT - 2, doorTop + dr.thick, pal.wash)
end

local archetype: Types.Archetype = { id = "sign_tower_prow_hotel", build = build }
return archetype
