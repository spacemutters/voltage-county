--!strict
-- T01 stacked_cube_supertall (docs/city/ARCHETYPES.md §5, T01): the county's tallest tower, a hotel and residences of
-- nine sleek glass cubes stacked on a ten-storey podium. Each cube slides a sixth of its width off the one below, so
-- the stack wobbles up into the sky and the top cube hangs out over the street. A cube is a flush box of reflective
-- glass with a fine curtain-wall grid, held at its edges by slim metal angles, a base plate (the soffit you see under
-- each overhang) and a heavier top band. Between every two cubes a deep dark joint: a dark slab set in from both cubes,
-- so each cube reads alone, cut off by a full-width shadow line. One dark core also runs up the middle of the stack
-- (the always-loaded skyline keeps it, so the stack keeps its height from afar).
--
-- What makes it itself: a zig-zag stack of crisp silver-glass cubes split by dark joints. At night the joints glow:
-- nine seams of light, each cube a dark block between them.
-- Placement, sizes, heights and its budget: Config/CityArchetypes/stacked_cube_supertall. It is a one-off (weight 0):
-- the planner builds it once at its anchor (Config/City landmarks) with a core claim, about 110 deep.
-- Variants: palette (3: silver glass in bright metal, aqua glass in white, dark smoke glass in champagne bronze, each
-- with its own podium screen); crown (1 a sky pool with a cabana and a mast, 2 a lit glass lantern cube, 3 an open
-- metal frame, a tenth cube drawn in outline); rhythm (1 a zig-zag, 2 a spiral, 3 a lean that snaps back at the top);
-- mirror. The seed also flips the walk.
--
-- When previewing: use a deep site (Preview option depth = 110), where the cubes are about 75 wide and 62 tall. On a
-- bare 53-deep plot they shrink to about 34. From far off (1,500 studs), check that the stack reads as nine shifted
-- cubes with a dark line between each two, not a ragged column, and that the cubes read as glass, not white cages.
-- Close up, check the soffits under the overhangs and that the frames' corners meet cleanly. At night, look for the
-- nine glowing joints, the lobby and the crown. The cubes' glass stays dark at night on purpose: lit parts move to the
-- site's light model, and the glass stays in the still one, so the stack keeps its shape when seen from afar.
-- Seen in Studio 2026-10-26 (docs/images/city/stacked_cube_supertall-*.jpg).

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
	lobby = 16, -- the double-height hotel lobby under the podium
	level = 10, -- a parking level
	levels = 7, -- with the lobby and the pool deck, a ten-storey base
	frontSetback = 4, -- the podium's face behind the front line
	sideInset = 1.5,
	backInset = 1.5,
	slot = 3.4, -- the dark slot at the top of each parking level
	bandProud = 0.5, -- the pale band under it stands this far out
	lobbyInset = 4, -- the glass lobby sits this far in under the podium
	columnEvery = 22, -- round columns along the podium's front edge
	columnsMax = 8,
	column = 2.4,
	pier = 3, -- the podium's front corner piers...
	pierProud = 1.2, -- ...standing this far past the bands
	capThick = 1.8,
	capProud = 0.6, -- past the bands
	-- The podium's metal screen covers this share of its front, centred, so the hotel's base reads as one screened
	-- block between its two piers, not a striped garage (its sides keep the garage's bands)...
	screen = 0.84,
	louvre = { every = 6, thick = 1.6, proud = 1.5, max = 24 }, -- ...in upright blades over a dark backing
	cubes = 9,
	joint = 6, -- the dark joint under each cube (4.2 read as a hairline from across the city)...
	jointInset = 2.5, -- ...a dark slab filling it, this far inside both cubes it joins (lit at night)
	aspect = 0.56, -- a cube's half-width as a share of its storey: a little wider than tall, as in the inspiration
	shift = 0.17, -- one step of the walk: this share of a cube's width (the inspiration slides about a sixth)
	margin = 0.2, -- room kept round a cube's outline
	base = 1.6, -- a cube's base plate (its soffit where it overhangs)
	top = 2.2, -- its top band (the ring of light at night)
	post = 1.4, -- its corner angles
	proud = 0.5, -- the frame stands this far out of the glass
	bay = 5.8, -- a window bay
	coreInset = 1.5, -- the dark core stays this far inside every cube's footprint
	canopyY = 13,
	canopyThick = 1.6,
	canopyHalf = 15,
	deckSide = 14, -- a side of the pool deck beside the stack needs this much width
	poolWidth = 16,
	poolLength = 44,
	cabana = 8,
	rail = 3.4,
	mast = 26,
	lantern = 0.44, -- crown 2: the lantern cube's side, as a share of the top cube's
	lanternHeight = 16,
	lanternLid = 1.6,
	beam = 1.8, -- crown 3: the open frame's posts and beams
	frameShare = 0.5, -- crown 3: the open frame's height, as a share of the top cube's width
}

-- The walks: each cube's shift off the stack's axis, in steps (x along the road, z away from it). The top cube's is
-- the biggest, toward the street.
local WALKS: { { Vector2 } } = {
	{ -- 1 a zig-zag: left and right seen from the street, in and out seen from the side
		Vector2.new(0, 0),
		Vector2.new(1, 0),
		Vector2.new(1, 1),
		Vector2.new(-0.2, 1),
		Vector2.new(-1, 0.2),
		Vector2.new(-1, -1),
		Vector2.new(0.2, -1),
		Vector2.new(1, -0.2),
		Vector2.new(1.3, -1.3),
	},
	{ -- 2 a spiral round the axis
		Vector2.new(0, 0),
		Vector2.new(0.8, 0),
		Vector2.new(0.8, 0.8),
		Vector2.new(0, 1),
		Vector2.new(-0.9, 0.9),
		Vector2.new(-1, 0),
		Vector2.new(-1, -1),
		Vector2.new(0, -1.1),
		Vector2.new(1.3, -1.3),
	},
	{ -- 3 a lean: the stack drifts one way, swings back, and the top cube snaps out over the street
		Vector2.new(0, 0.3),
		Vector2.new(0.6, 0.3),
		Vector2.new(1.2, 0),
		Vector2.new(0.5, -0.4),
		Vector2.new(-0.3, -0.4),
		Vector2.new(-1.1, 0),
		Vector2.new(-1.2, 0.8),
		Vector2.new(-0.2, 1.1),
		Vector2.new(1.3, -1.3),
	},
}
local REACH = 1.3 -- the biggest shift in any walk, in steps, on either axis

-- Glass, frames (angles, plates, bands, crown), the podium's metal screen and its bands.
local PALETTES = {
	{ glass = P.glass.silver, frame = rgb(226, 230, 234), screen = rgb(214, 200, 168), podium = P.concrete.pale },
	{ glass = P.glass.aqua, frame = P.frame.white, screen = P.frame.silver, podium = P.concrete.pale },
	{ glass = P.glass.smoke, frame = rgb(204, 186, 152), screen = rgb(150, 122, 92), podium = P.concrete.warm },
}

local RAIL = Kit.look(rgb(214, 236, 242), Enum.Material.Glass, 0.1, KIT.railTransparency)
local METAL = Kit.look(rgb(200, 204, 210), Enum.Material.Metal)
local BEACON = Kit.look(rgb(150, 40, 36), Enum.Material.SmoothPlastic)
local WALLS = { Enum.NormalId.Front, Enum.NormalId.Back, Enum.NormalId.Left, Enum.NormalId.Right }
local CORNERS = { { -1, -1 }, { 1, -1 }, { -1, 1 }, { 1, 1 } }

local function build(m: Types.Model)
	local site = m.site
	local variant = site.variant
	local pal = PALETTES[math.clamp(variant.palette, 1, #PALETTES)]
	local rng = Kit.rng(m)
	local W, D, H = site.width, site.depth, site.height
	local hw, hd = W / 2, D / 2
	local rise = site.maxHeight - H -- what the crown may add
	local frame = Kit.look(pal.frame, Enum.Material.SmoothPlastic, 0.08)
	local dark = Kit.look(P.concrete.dark, Enum.Material.SmoothPlastic)
	local tag = City.signNames.towers[rng:NextInteger(1, #City.signNames.towers)]

	-------------------------------------------------------------------------------------------------------
	-- Podium: a glass hotel lobby under seven parking levels, corner piers, a metal screen, a lit cap, a
	-- porte-cochère
	-------------------------------------------------------------------------------------------------------
	local podiumTop = SHAPE.lobby + SHAPE.levels * SHAPE.level
	local deck = podiumTop + SHAPE.capThick
	local px0, px1 = -hw + SHAPE.sideInset, hw - SHAPE.sideInset
	local pz0, pz1 = -hd + SHAPE.frontSetback, hd - SHAPE.backInset
	local li = SHAPE.lobbyInset

	Kit.glass(
		m,
		"Lobby",
		Vector3.new(px0 + li, -KIT.bury, pz0 + li),
		Vector3.new(px1 - li, SHAPE.lobby + 0.5, pz1 - li),
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
	local columns = math.clamp(math.floor((px1 - px0) / SHAPE.columnEvery), 2, SHAPE.columnsMax)
	for i = 1, columns do
		local x = px0 + 2 + (px1 - px0 - 4) * (i - 1) / (columns - 1)
		Kit.column(m, `Column{i}`, x, pz0 + 1.4, -KIT.bury, SHAPE.lobby + 0.5, SHAPE.column, frame)
	end
	Kit.podium(
		m,
		"Podium",
		Vector3.new(px0, SHAPE.lobby, pz0),
		Vector3.new(px1, podiumTop, pz1),
		SHAPE.levels,
		SHAPE.slot,
		SHAPE.bandProud,
		Kit.look(pal.podium, Enum.Material.Concrete),
		dark
	)
	-- Front corner piers from the lobby's head to the cap, standing past the bands: the podium gets two crisp edges.
	for i, side in { -1, 1 } do
		local outer = side * (hw - SHAPE.sideInset + SHAPE.bandProud + 0.4)
		local inner = side * (hw - SHAPE.sideInset - SHAPE.pier)
		Kit.trim(
			m,
			`Pier{i}`,
			Vector3.new(outer, SHAPE.lobby - 0.5, pz0 - SHAPE.bandProud - SHAPE.pierProud),
			Vector3.new(inner, podiumTop, pz0 + SHAPE.pier),
			frame
		)
	end
	-- The metal screen over the middle of the garage front, standing clear of the bands: louvres of the screen's metal
	-- over a dark backing, so it reads as a deep screen with a shadow behind every blade.
	local screenHalf = (px1 - px0) * SHAPE.screen / 2
	local screenFront = pz0 - SHAPE.bandProud
	local sy0, sy1 = SHAPE.lobby + 2, podiumTop - 1.5
	Kit.trim(
		m,
		"Screen",
		Vector3.new(-screenHalf, sy0, screenFront - 1.3),
		Vector3.new(screenHalf, sy1, screenFront - 0.4),
		dark
	)
	local blades = math.clamp(math.floor(2 * screenHalf / SHAPE.louvre.every) + 1, 4, SHAPE.louvre.max)
	Kit.fins(
		m,
		"Louvre",
		"front",
		screenFront - 1.3,
		-screenHalf + SHAPE.louvre.thick / 2,
		screenHalf - SHAPE.louvre.thick / 2,
		blades,
		sy0 - 0.4,
		sy1 + 0.4,
		SHAPE.louvre.proud,
		SHAPE.louvre.thick,
		Kit.look(pal.screen, Enum.Material.Metal)
	)
	local cap = SHAPE.bandProud + SHAPE.capProud
	Kit.trim(
		m,
		"PodiumCap",
		Vector3.new(px0 - cap, podiumTop, pz0 - cap),
		Vector3.new(px1 + cap, deck, pz1 + cap),
		frame
	)
	Kit.neonStrip(
		m,
		"PodiumLed",
		Vector3.new(px0 - cap, podiumTop + 0.5, pz0 - cap - 0.15),
		Vector3.new(px1 + cap, podiumTop + 1.1, pz0 - cap - 0.05),
		"ledBlue",
		pal.frame
	)

	-- The porte-cochère: a deep canopy on two slim posts, the tower's name on its front edge, a light line under it,
	-- and the wash on its top lighting the screen.
	local cw = math.min(SHAPE.canopyHalf, (px1 - px0) / 2 - 4)
	local canopyTop = SHAPE.canopyY + SHAPE.canopyThick
	Kit.canopy(m, "Canopy", -cw, cw, -hd + 0.5, pz0 + li + 0.5, SHAPE.canopyY, SHAPE.canopyThick, frame)
	for i, side in { -1, 1 } do
		Kit.column(m, `CanopyPost{i}`, side * (cw - 1.5), -hd + 2, -KIT.bury, SHAPE.canopyY + 0.05, 1.2, METAL)
	end
	Kit.sign(
		m,
		"Name",
		Vector3.new(-cw * 0.7, canopyTop, -hd + 0.8),
		Vector3.new(cw * 0.7, canopyTop + 2.8, -hd + 1.3),
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
	Kit.wash(m, "Wash", -cw * 0.8, cw * 0.8, -hd + 3.4, canopyTop, rgb(220, 226, 255))

	-------------------------------------------------------------------------------------------------------
	-- The stack: a dark core, then nine cubes, each a base plate, four corner angles, glass and a lit top band
	-------------------------------------------------------------------------------------------------------
	local storey = (H - deck) / SHAPE.cubes -- one cube's height, its joint included
	local room = math.min(px1 - px0, pz1 - pz0)
	-- Cubes a little wider than tall where the podium has room; a shifted cube still stays over it.
	local h = math.min(storey * SHAPE.aspect, (room / 2 - SHAPE.margin) / (1 + 2 * SHAPE.shift * REACH))
	local shift = 2 * h * SHAPE.shift
	local reach = shift * REACH
	local ext = h + SHAPE.margin
	local zc = (pz0 + reach + ext + pz1 - reach - ext) / 2

	-- The core: one dark mass up the stack's axis, inside every cube; it shows only in the joints.
	local cs = math.max(4, h - reach - SHAPE.coreInset)
	Kit.box(m, "Core", Vector3.new(-cs, deck - 0.4, zc - cs), Vector3.new(cs, H - SHAPE.top - 1, zc + cs), dark)

	local walk = WALKS[math.clamp(variant.rhythm, 1, #WALKS)]
	local flip = if rng:NextNumber() < 0.5 then 1 else -1
	local glassLook = Kit.glassLook(pal.glass, 0.22)
	local lines = pal.glass:Lerp(pal.frame, 0.35)
	local g = h - SHAPE.proud -- the glass's half-width
	local bays = math.max(1, math.round(2 * g / SHAPE.bay))
	local topX, topZ = 0, zc
	local ji = SHAPE.jointInset

	for k = 1, SHAPE.cubes do
		local step = walk[k]
		local cx, cz = step.X * shift * flip, zc + step.Y * shift
		local y0 = deck + (k - 1) * storey
		local y1 = if k == SHAPE.cubes then H else deck + k * storey
		local yb = y0 + SHAPE.joint -- the cube's foot, over its joint
		local yp = yb + SHAPE.base -- the base plate's top
		local yt = y1 - SHAPE.top -- the top band's underside

		-- The joint: a dark slab filling the overlap of this cube and the one below (the first, its own footprint on
		-- the deck), set in from both, so every cube reads cut off by a full-width shadow line by day. At night the
		-- joints glow: nine seams of light up the stack, each cube a dark block between them.
		local ax, az = if k == 1 then cx else topX, if k == 1 then cz else topZ
		Kit.lit(
			Kit.trim(
				m,
				`Cube{k}Joint`,
				Vector3.new(math.max(ax, cx) - h + ji, y0 - 0.3, math.max(az, cz) - h + ji),
				Vector3.new(math.min(ax, cx) + h - ji, yb + 0.3, math.min(az, cz) + h - ji),
				dark
			),
			"crown"
		)

		-- The base plate: the cube's soffit where it overhangs the cube below.
		Kit.trim(m, `Cube{k}Base`, Vector3.new(cx - h, yb, cz - h), Vector3.new(cx + h, yp, cz + h), frame)
		-- The corner angles, their outer faces in the plates' planes.
		local p = SHAPE.post
		for i, corner in CORNERS do
			local sx, sz = corner[1], corner[2]
			Kit.trim(
				m,
				`Cube{k}Post{i}`,
				Vector3.new(cx + sx * h, yp, cz + sz * h),
				Vector3.new(cx + sx * (h - p), yt, cz + sz * (h - p)),
				frame
			)
		end
		-- The glass, set in behind the frame, a curtain-wall grid on all four faces. Each cube's glass is a hair wider
		-- than the one below, so the always-loaded Skyline (a site's biggest masses) keeps the top cubes.
		local gk = g + 0.01 * k
		local pane = Kit.box(
			m,
			`Cube{k}Glass`,
			Vector3.new(cx - gk, yp - 0.05, cz - gk),
			Vector3.new(cx + gk, yt + 0.05, cz + gk),
			glassLook
		)
		local paneHeight = yt - yp + 0.1
		local floors = math.max(1, math.round(paneHeight / SHAPE.floor))
		local textures: { Types.TextureSpec } = {}
		for _, face in WALLS do
			table.insert(textures, {
				face = face,
				image = City.textures.windowFine,
				u = 2 * g / bays,
				v = paneHeight / floors,
				color = lines,
			})
		end
		pane.textures = textures
		-- The top band: metal, the cube's crisp top edge against the glowing joint over it at night.
		Kit.trim(m, `Cube{k}Top`, Vector3.new(cx - h, yt, cz - h), Vector3.new(cx + h, y1, cz + h), frame)
		topX, topZ = cx, cz
	end

	-------------------------------------------------------------------------------------------------------
	-- Crown, on the top cube
	-------------------------------------------------------------------------------------------------------
	local function roofRails(edge: number)
		local y0, y1 = H + 0.02, H + SHAPE.rail
		local t = 0.3
		local x0, x1, z0, z1 = topX - edge, topX + edge, topZ - edge, topZ + edge
		Kit.detail(m, "RoofRailFront", Vector3.new(x0, y0, z0), Vector3.new(x1, y1, z0 + t), RAIL)
		Kit.detail(m, "RoofRailBack", Vector3.new(x0, y0, z1 - t), Vector3.new(x1, y1, z1), RAIL)
		Kit.detail(m, "RoofRailLeft", Vector3.new(x0, y0, z0 + t), Vector3.new(x0 + t, y1, z1 - t), RAIL)
		Kit.detail(m, "RoofRailRight", Vector3.new(x1 - t, y0, z0 + t), Vector3.new(x1, y1, z1 - t), RAIL)
	end

	local crown = math.clamp(variant.crown, 1, 3)
	if crown == 1 then
		-- A sky pool behind a glass rail, a cabana, and a mast on the cabana.
		roofRails(h - 0.5)
		Kit.pool(
			m,
			"SkyPool",
			Vector3.new(topX - h + 5, 0, topZ - h + 5),
			Vector3.new(topX + h * 0.35, 0, topZ - h * 0.05),
			H
		)
		local bx0, bz0, bx1, bz1 = topX + h * 0.3, topZ + h * 0.2, topX + h - 4, topZ + h - 4
		Kit.box(m, "Cabana", Vector3.new(bx0, H - 0.05, bz0), Vector3.new(bx1, H + SHAPE.cabana, bz1), frame)
		local tall = math.min(SHAPE.mast, rise - SHAPE.cabana - 2.5)
		Kit.spire(m, "Mast", (bx0 + bx1) / 2, (bz0 + bz1) / 2, H + SHAPE.cabana, tall, 1.6, METAL, 2, true)
	elseif crown == 2 then
		-- A lantern: a small glass cube glowing on the roof under a metal lid and its ring, a mast on top.
		roofRails(h - 0.5)
		local q = h * SHAPE.lantern
		local lh = SHAPE.lanternHeight
		Kit.glass(
			m,
			"Lantern",
			Vector3.new(topX - q, H - 0.05, topZ - q),
			Vector3.new(topX + q, H + lh, topZ + q),
			pal.glass,
			{ image = City.textures.windowBold, u = 4, v = lh, lines = pal.frame, lit = true }
		)
		local lidTop = H + lh + SHAPE.lanternLid
		Kit.trim(
			m,
			"LanternLid",
			Vector3.new(topX - q - 1.2, H + lh, topZ - q - 1.2),
			Vector3.new(topX + q + 1.2, lidTop, topZ + q + 1.2),
			frame
		)
		Kit.neonStrip(
			m,
			"LanternRing",
			Vector3.new(topX - q - 1.3, H + lh + 0.4, topZ - q - 1.3),
			Vector3.new(topX + q + 1.3, lidTop - 0.4, topZ + q + 1.3),
			"crown",
			pal.frame
		)
		Kit.spire(m, "Mast", topX, topZ, lidTop, math.min(18, rise - lh - SHAPE.lanternLid - 2.5), 1.4, METAL, 2, true)
	else
		-- An open frame: the top cube's corner angles rise into a tenth cube drawn in outline, its beams lit at
		-- night; a sky pool inside and a beacon on one post.
		local b = SHAPE.beam
		local f = math.min(2 * h * SHAPE.frameShare, rise - 4)
		local yt = H + f
		for i, corner in CORNERS do
			local sx, sz = corner[1], corner[2]
			Kit.trim(
				m,
				`FramePost{i}`,
				Vector3.new(topX + sx * h, H, topZ + sz * h),
				Vector3.new(topX + sx * (h - b), yt - b, topZ + sz * (h - b)),
				frame
			)
		end
		local x0, x1, z0, z1 = topX - h, topX + h, topZ - h, topZ + h
		Kit.trim(m, "FrameFront", Vector3.new(x0, yt - b, z0), Vector3.new(x1, yt, z0 + b), frame)
		Kit.trim(m, "FrameBack", Vector3.new(x0, yt - b, z1 - b), Vector3.new(x1, yt, z1), frame)
		Kit.trim(m, "FrameLeft", Vector3.new(x0, yt - b + 0.02, z0 + b), Vector3.new(x0 + b, yt - 0.02, z1 - b), frame)
		Kit.trim(m, "FrameRight", Vector3.new(x1 - b, yt - b + 0.02, z0 + b), Vector3.new(x1, yt - 0.02, z1 - b), frame)
		-- A light line along the middle of each beam's outer face (the side ones meet the front and back ones).
		local o = 0.15
		local s0, s1 = yt - b + 0.5, yt - 0.5
		local e0, e1 = z0 + b - 0.3, z1 - b + 0.3
		Kit.neonStrip(
			m,
			"FrameLightFront",
			Vector3.new(x0 - o, s0, z0 - o),
			Vector3.new(x1 + o, s1, e0),
			"crown",
			pal.frame
		)
		Kit.neonStrip(
			m,
			"FrameLightBack",
			Vector3.new(x0 - o, s0, e1),
			Vector3.new(x1 + o, s1, z1 + o),
			"crown",
			pal.frame
		)
		Kit.neonStrip(
			m,
			"FrameLightLeft",
			Vector3.new(x0 - o, s0, e0),
			Vector3.new(x0 + b - 0.3, s1, e1),
			"crown",
			pal.frame
		)
		Kit.neonStrip(
			m,
			"FrameLightRight",
			Vector3.new(x1 - b + 0.3, s0, e0),
			Vector3.new(x1 + o, s1, e1),
			"crown",
			pal.frame
		)
		Kit.pool(m, "SkyPool", Vector3.new(x0 + b + 3, 0, z0 + b + 3), Vector3.new(x1 - b - 3, 0, topZ - h * 0.1), H)
		Kit.lit(Kit.ball(m, "Beacon", Vector3.new(x1 - b / 2, yt + 0.6, z1 - b / 2), 1.2, BEACON), "beacon")
	end

	-------------------------------------------------------------------------------------------------------
	-- The pool deck on the podium beside the stack, a garden terrace on its other side, and the front rail
	-------------------------------------------------------------------------------------------------------
	local stackHalf = reach + ext
	local sideRoom = (px1 - px0) / 2 - stackHalf - 5 -- from the podium's edge to the stack, less a walk
	if sideRoom >= SHAPE.deckSide then
		local poolW = math.min(SHAPE.poolWidth, sideRoom - 6)
		local poolL = math.min(SHAPE.poolLength, pz1 - pz0 - 14)
		local x0 = px0 + 4
		Kit.pool(m, "Pool", Vector3.new(x0, 0, pz0 + 7), Vector3.new(x0 + poolW, 0, pz0 + 7 + poolL), deck)
		if sideRoom - poolW >= 9 then
			local ux = x0 + poolW + 4.5
			Kit.umbrella(m, "UmbrellaA", ux, pz0 + 12, deck, 7, P.deco.white)
			Kit.umbrella(m, "UmbrellaB", ux, pz0 + 7 + poolL - 5, deck, 7, P.deco.white)
		end
		-- The garden side: a cabana against the back and planters along the rail.
		local gx1 = px1 - 4
		local gx0 = math.max(gx1 - 24, gx1 - sideRoom + 2)
		Kit.box(
			m,
			"DeckCabana",
			Vector3.new(gx0, deck - 0.05, pz1 - 16),
			Vector3.new(gx1, deck + SHAPE.cabana, pz1 - 4),
			frame
		)
		Kit.planter(m, "PlanterA", Vector3.new(gx0, deck, pz0 + 1.2), Vector3.new(gx1, deck + 1.6, pz0 + 3.4), frame)
		Kit.planter(m, "PlanterB", Vector3.new(gx0, deck, pz1 - 22), Vector3.new(gx0 + 3, deck + 1.6, pz1 - 18), frame)
	end
	Kit.detail(
		m,
		"DeckRail",
		Vector3.new(px0 - cap + 0.3, deck + 0.02, pz0 - cap + 0.3),
		Vector3.new(px1 + cap - 0.3, deck + SHAPE.rail, pz0 - cap + 0.6),
		RAIL
	)
end

local archetype: Types.Archetype = { id = "stacked_cube_supertall", build = build }
return archetype
