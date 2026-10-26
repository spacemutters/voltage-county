--!strict
-- T01 stacked_cube_supertall (docs/city/ARCHETYPES.md §5, T01): the county's tallest tower, a hotel and residences of
-- nine glass cubes stacked on a ten-storey parking podium. Each cube slides off the one below (three of them also turn
-- a few degrees), so the stack wobbles up into the sky, and the top cube hangs furthest out, over the street. Every
-- cube is its own white-framed glass box: four corner posts, a base frame and a heavy lid. A dark joint is set in
-- between every two, so each cube reads alone in its own shadow.
--
-- What makes it itself: a zig-zag stack of framed glass cubes split by dark joints. At night, nine rings of light.
-- Placement, sizes, heights and its budget: Config/CityArchetypes/stacked_cube_supertall. It is a one-off (weight 0):
-- the planner builds it once at its anchor (Config/City landmarks) with a core claim, about 110 deep.
-- Variants: palette (3: silver, aqua or navy glass, each with its own frame and podium screen); crown (1 a sky pool
-- with a cabana and a mast, 2 a lit glass lantern cube, 3 an open white frame, a tenth cube drawn in outline); rhythm
-- (1 a zig-zag walk, 2 a spiral, each turning its own three cubes); mirror. The seed also flips the walk.
--
-- When previewing: use a deep site (Preview option depth = 110). On a bare 53-deep plot the cubes shrink to fit. From
-- far off (1,500 studs), check that the stack reads as nine shifted cubes, not a ragged column, and that the joints
-- read dark in the sun. Up close, check that a turned cube's corners don't poke through its joint or its neighbours.
-- At night, look for the nine rings and the podium's lines. The cubes' glass stays dark on purpose: lit parts move to
-- the site's light model, and the glass must stay in the still one so the stack keeps its shape when seen from afar.

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
	column = 2.4,
	capThick = 1.6,
	capProud = 0.6, -- past the bands
	screen = 0.5, -- the podium's metal screen covers this share of its front, centred...
	louvre = { every = 5.5, thick = 1.6, proud = 1.5, max = 16 }, -- ...in upright blades over a dark backing
	cubes = 9,
	joint = 6, -- the dark joint under each cube (4.2 read as a hairline from across the city)
	jointInset = 4.5, -- in from the overlap of the two cubes it joins
	base = 1.4, -- a cube's base frame
	lid = 3, -- its lid (the ring of light lies on the lid's face; at 2.2 the rings read as hairlines at night)
	post = 2.4, -- its corner posts
	glassInset = 1.5, -- its glass sits this far behind the frames
	bay = 5.6, -- a window bay
	ring = 0.4, -- the ring of light: this far in from the lid's top and bottom edges
	ringProud = 0.15,
	shift = { 0.12, 3.5, 8 }, -- one step of the walk: share of a cube's height, clamped...
	shiftRoom = 0.09, -- ...and at most this share of the room the podium leaves
	margin = 0.25, -- a cube's reach past its frame (its ring and rounding)
	turn = math.rad(3), -- a turned cube's turn
	front = 24, -- on a deep podium, the stack's front stands at most this far behind the podium's front (the pool deck)
	canopyY = 13,
	canopyThick = 1.6,
	canopyHalf = 15,
	poolDeck = 8, -- the depth a pool deck in front of the stack needs
	poolDepth = 16,
	poolWidth = 44,
	rail = 3.4,
	cabana = 8,
	mast = 26,
	lantern = 0.44, -- crown 2: the lantern cube's side, as a share of the top cube's
	lanternHeight = 16,
	lanternLid = 1.6,
	beam = 2, -- crown 3: the open frame's posts and beams
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
}
local REACH = 1.3 -- the biggest shift in any walk, in steps, on either axis
-- The cubes each walk turns as well as shifts.
local TURNED: { { [number]: boolean } } = {
	{ [3] = true, [6] = true, [8] = true },
	{ [4] = true, [7] = true, [9] = true },
}

-- Glass, frames (posts, lids, crown), the podium's metal screen and its bands.
local PALETTES = {
	{ glass = P.glass.silver, frame = P.frame.white, screen = rgb(214, 200, 168), podium = P.concrete.pale },
	{ glass = P.glass.aqua, frame = P.frame.white, screen = P.frame.silver, podium = P.concrete.pale },
	{ glass = P.glass.navy, frame = P.frame.warm, screen = rgb(150, 122, 92), podium = P.concrete.warm },
}

local RAIL = Kit.look(rgb(214, 236, 242), Enum.Material.Glass, 0.1, KIT.railTransparency)
local METAL = Kit.look(rgb(200, 204, 210), Enum.Material.Metal)
local WALLS = { Enum.NormalId.Front, Enum.NormalId.Back, Enum.NormalId.Left, Enum.NormalId.Right }

-- The box min..max as drawn, turned `yaw` radians about the upright line through `pivot` (a turned cube's pieces).
local function turned(
	m: Types.Model,
	name: string,
	pivot: Vector3,
	yaw: number,
	min: Vector3,
	max: Vector3,
	look: Kit.Look,
	kind: Kit.Kind
): Types.PartSpec
	local lo, hi = min:Min(max), min:Max(max)
	local c = (lo + hi) / 2
	local axis = Vector3.new(pivot.X, c.Y, pivot.Z)
	local cf = CFrame.new(axis) * CFrame.Angles(0, yaw, 0) * CFrame.new(c - axis)
	return Kit.oriented(m, name, "block", cf, hi - lo, look, kind)
end

local function build(m: Types.Model)
	local site = m.site
	local variant = site.variant
	local pal = PALETTES[math.clamp(variant.palette, 1, #PALETTES)]
	local rng = Kit.rng(m)
	local W, D, H = site.width, site.depth, site.height
	local hw, hd = W / 2, D / 2
	local rise = site.maxHeight - H -- what the crown may add
	local frame = Kit.look(pal.frame, Enum.Material.SmoothPlastic)
	local dark = Kit.look(P.concrete.dark, Enum.Material.SmoothPlastic)
	local tag = City.signNames.towers[rng:NextInteger(1, #City.signNames.towers)]

	-------------------------------------------------------------------------------------------------------
	-- Podium: a glass hotel lobby under seven parking levels, a metal screen, a lit cap, a porte-cochère
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
	local columns = math.clamp(math.floor((px1 - px0) / SHAPE.columnEvery), 2, 8)
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
	-- The metal screen over the middle of the garage front, standing clear of the bands: louvres of the screen's metal
	-- over a dark backing, so it reads as a deep screen with a shadow behind every blade (a flat textured panel read as
	-- a blank billboard).
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
		Vector3.new(px0 - cap, podiumTop + 0.45, pz0 - cap - 0.15),
		Vector3.new(px1 + cap, podiumTop + 0.95, pz0 - cap - 0.05),
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
	-- The stack: nine cubes, each a joint, a base frame, four posts, glass, a lid and its ring of light
	-------------------------------------------------------------------------------------------------------
	local c = (H - deck) / SHAPE.cubes -- one cube's height, its joint included
	local room = math.min(px1 - px0, pz1 - pz0)
	local shift = math.min(math.clamp(c * SHAPE.shift[1], SHAPE.shift[2], SHAPE.shift[3]), room * SHAPE.shiftRoom)
	local reach = shift * REACH
	local grow = math.cos(SHAPE.turn) + math.sin(SHAPE.turn) -- a turned square's reach over an upright one's
	-- Cubes as wide as they are tall where the podium has room; a turned, shifted cube still stays over it.
	local h = math.min(c / 2, (room / 2 - reach) / grow - SHAPE.margin)
	local ext = (h + SHAPE.margin) * grow
	local zLo, zHi = pz0 + reach + ext, pz1 - reach - ext
	local zc = math.min((zLo + zHi) / 2, zLo + SHAPE.front)

	local walk = WALKS[math.clamp(variant.rhythm, 1, #WALKS)]
	local turns = TURNED[math.clamp(variant.rhythm, 1, #TURNED)]
	local flip = if rng:NextNumber() < 0.5 then 1 else -1
	local glassLook = Kit.glassLook(pal.glass)
	local lines = pal.glass:Lerp(pal.frame, 0.3)
	local ringLook = Kit.look(pal.frame, Enum.Material.SmoothPlastic)
	local gi = SHAPE.glassInset
	local span = 2 * (h - gi)
	local bays = math.max(1, math.round(span / SHAPE.bay))
	local swing = 2 * h * math.sin(SHAPE.turn) -- how far a turned cube's edge swings past an upright one's
	local prevX, prevZ, prevTurned = 0, zc, false
	local topX, topZ, topYaw = 0, zc, 0

	for k = 1, SHAPE.cubes do
		local step = walk[k]
		local cx, cz = step.X * shift * flip, zc + step.Y * shift
		local isTurned = turns[k] == true
		local yaw = if isTurned then SHAPE.turn * flip * (if k % 2 == 0 then 1 else -1) else 0
		local y0 = deck + (k - 1) * c
		local y1 = if k == SHAPE.cubes then H else deck + k * c
		local yb = y0 + SHAPE.joint -- the cube's foot, over its joint
		local yl = y1 - SHAPE.lid -- its lid's underside
		local pivot = Vector3.new(cx, 0, cz)
		local function piece(name: string, a: Vector3, b: Vector3, look: Kit.Look, kind: Kit.Kind): Types.PartSpec
			return turned(m, `Cube{k}{name}`, pivot, yaw, pivot + a, pivot + b, look, kind)
		end

		-- The joint: dark, set in from where this cube and the one below overlap.
		local ax, az = if k == 1 then cx else prevX, if k == 1 then cz else prevZ
		local inset = SHAPE.jointInset + (if isTurned or prevTurned then swing else 0)
		local jx0, jx1 = math.max(ax, cx) - h + inset, math.min(ax, cx) + h - inset
		local jz0, jz1 = math.max(az, cz) - h + inset, math.min(az, cz) + h - inset
		if jx1 - jx0 > 2 and jz1 - jz0 > 2 then
			Kit.box(m, `Cube{k}Joint`, Vector3.new(jx0, y0 - 0.05, jz0), Vector3.new(jx1, yb + 0.05, jz1), dark)
		end

		-- The frame: a base, a lid and four corner posts, their outer faces one plane per side.
		piece("Base", Vector3.new(-h, yb, -h), Vector3.new(h, yb + SHAPE.base, h), frame, "trim")
		piece("Lid", Vector3.new(-h, yl, -h), Vector3.new(h, y1, h), frame, "trim")
		local p = SHAPE.post
		for i, corner in { { -1, -1 }, { 1, -1 }, { -1, 1 }, { 1, 1 } } do
			local sx, sz = corner[1], corner[2]
			piece(
				`Post{i}`,
				Vector3.new(sx * h, yb + SHAPE.base, sz * h),
				Vector3.new(sx * (h - p), yl, sz * (h - p)),
				frame,
				"trim"
			)
		end

		-- The glass, set in behind the frame, a curtain-wall grid on all four faces.
		local pane = piece(
			"Glass",
			Vector3.new(-h + gi, yb + SHAPE.base - 0.05, -h + gi),
			Vector3.new(h - gi, yl + 0.05, h - gi),
			glassLook,
			"box"
		)
		local paneHeight = yl - yb - SHAPE.base + 0.1
		local floors = math.max(1, math.round(paneHeight / SHAPE.floor))
		local textures: { Types.TextureSpec } = {}
		for _, face in WALLS do
			table.insert(textures, {
				face = face,
				image = City.textures.windowFine,
				u = span / bays,
				v = paneHeight / floors,
				color = lines,
			})
		end
		pane.textures = textures

		-- The ring of light round the lid: white by day like the lid, a cool white line at night.
		local r = h + SHAPE.ringProud
		Kit.lit(
			piece("Ring", Vector3.new(-r, yl + SHAPE.ring, -r), Vector3.new(r, y1 - SHAPE.ring, r), ringLook, "detail"),
			"crown"
		)

		prevX, prevZ, prevTurned = cx, cz, isTurned
		topX, topZ, topYaw = cx, cz, yaw
	end

	-------------------------------------------------------------------------------------------------------
	-- Crown, on the top cube's lid (turned with it)
	-------------------------------------------------------------------------------------------------------
	local topPivot = Vector3.new(topX, 0, topZ)
	local topFrame = CFrame.new(topPivot) * CFrame.Angles(0, topYaw, 0)
	local function onTop(name: string, a: Vector3, b: Vector3, look: Kit.Look, kind: Kit.Kind): Types.PartSpec
		return turned(m, name, topPivot, topYaw, topPivot + a, topPivot + b, look, kind)
	end
	-- A point on the top cube (x, z from its centre, as drawn) in the site's terms.
	local function onTopAt(x: number, z: number): Vector3
		return topFrame * Vector3.new(x, 0, z)
	end
	local function roofRails(edge: number)
		local y0, y1 = H + 0.02, H + SHAPE.rail
		local t = 0.3
		onTop("RoofRailFront", Vector3.new(-edge, y0, -edge), Vector3.new(edge, y1, -edge + t), RAIL, "detail")
		onTop("RoofRailBack", Vector3.new(-edge, y0, edge - t), Vector3.new(edge, y1, edge), RAIL, "detail")
		onTop("RoofRailLeft", Vector3.new(-edge, y0, -edge + t), Vector3.new(-edge + t, y1, edge - t), RAIL, "detail")
		onTop("RoofRailRight", Vector3.new(edge - t, y0, -edge + t), Vector3.new(edge, y1, edge - t), RAIL, "detail")
	end
	local function skyPool(x0: number, z0: number, x1: number, z1: number)
		onTop(
			"SkyPoolEdge",
			Vector3.new(x0 - 0.8, H, z0 - 0.8),
			Vector3.new(x1 + 0.8, H + 0.35, z1 + 0.8),
			Kit.look(P.deco.terrazzo, Enum.Material.SmoothPlastic),
			"detail"
		)
		onTop(
			"SkyPool",
			Vector3.new(x0, H + 0.05, z0),
			Vector3.new(x1, H + 0.45, z1),
			Kit.look(P.water, Enum.Material.Glass, 0.3, 0),
			"detail"
		)
	end

	local crown = math.clamp(variant.crown, 1, 3)
	if crown == 1 then
		-- A sky pool behind a glass rail, a cabana, and a mast on the cabana.
		roofRails(h - 0.4)
		skyPool(-h + 5, -h + 5, h * 0.35, -h * 0.05)
		local cx0, cz0, cx1, cz1 = h * 0.3, h * 0.2, h - 4, h - 4
		onTop("Cabana", Vector3.new(cx0, H - 0.05, cz0), Vector3.new(cx1, H + SHAPE.cabana, cz1), frame, "box")
		local mastAt = onTopAt((cx0 + cx1) / 2, (cz0 + cz1) / 2)
		local tall = math.min(SHAPE.mast, rise - SHAPE.cabana - 2.5)
		Kit.spire(m, "Mast", mastAt.X, mastAt.Z, H + SHAPE.cabana, tall, 1.6, METAL, 2, true)
	elseif crown == 2 then
		-- A lantern: a small glass cube glowing on the roof under a white lid and its ring, a mast on top.
		roofRails(h - 0.4)
		local q = h * SHAPE.lantern
		local lh = SHAPE.lanternHeight
		local lantern = onTop("Lantern", Vector3.new(-q, H - 0.05, -q), Vector3.new(q, H + lh, q), glassLook, "box")
		local textures: { Types.TextureSpec } = {}
		for _, face in WALLS do
			table.insert(textures, { face = face, image = City.textures.windowBold, u = 4, v = lh, color = pal.frame })
		end
		lantern.textures = textures
		Kit.lit(lantern, "window")
		local lidTop = H + lh + SHAPE.lanternLid
		onTop(
			"LanternLid",
			Vector3.new(-q - 1.2, H + lh, -q - 1.2),
			Vector3.new(q + 1.2, lidTop, q + 1.2),
			frame,
			"trim"
		)
		Kit.lit(
			onTop(
				"LanternRing",
				Vector3.new(-q - 1.3, H + lh + 0.4, -q - 1.3),
				Vector3.new(q + 1.3, lidTop - 0.4, q + 1.3),
				ringLook,
				"detail"
			),
			"crown"
		)
		local mastAt = onTopAt(0, 0)
		Kit.spire(
			m,
			"Mast",
			mastAt.X,
			mastAt.Z,
			lidTop,
			math.min(18, rise - lh - SHAPE.lanternLid - 2.5),
			1.4,
			METAL,
			2,
			true
		)
	else
		-- An open frame: the top cube's corner posts rise into a tenth cube drawn in outline, its beams lit at night;
		-- a sky pool inside and a beacon on one post.
		local b = SHAPE.beam
		local f = math.min(h, rise - 4)
		local yt = H + f
		for i, corner in { { -1, -1 }, { 1, -1 }, { -1, 1 }, { 1, 1 } } do
			local sx, sz = corner[1], corner[2]
			onTop(
				`FramePost{i}`,
				Vector3.new(sx * h, H, sz * h),
				Vector3.new(sx * (h - b), yt - b, sz * (h - b)),
				frame,
				"trim"
			)
		end
		onTop("FrameFront", Vector3.new(-h, yt - b, -h), Vector3.new(h, yt, -h + b), frame, "trim")
		onTop("FrameBack", Vector3.new(-h, yt - b, h - b), Vector3.new(h, yt, h), frame, "trim")
		onTop("FrameLeft", Vector3.new(-h, yt - b + 0.02, -h + b), Vector3.new(-h + b, yt - 0.02, h - b), frame, "trim")
		onTop("FrameRight", Vector3.new(h - b, yt - b + 0.02, -h + b), Vector3.new(h, yt - 0.02, h - b), frame, "trim")
		-- A light line along the middle of each beam's outer face (the side ones meet the front and back ones).
		local o = SHAPE.ringProud
		local s0, s1 = yt - b + 0.5, yt - 0.5
		local e0, e1 = -h + b - 0.3, h - b + 0.3
		local lights: { { name: string, a: Vector3, b: Vector3 } } = {
			{ name = "FrameLightFront", a = Vector3.new(-h - o, s0, -h - o), b = Vector3.new(h + o, s1, e0) },
			{ name = "FrameLightBack", a = Vector3.new(-h - o, s0, e1), b = Vector3.new(h + o, s1, h + o) },
			{ name = "FrameLightLeft", a = Vector3.new(-h - o, s0, e0), b = Vector3.new(e0, s1, e1) },
			{ name = "FrameLightRight", a = Vector3.new(e1, s0, e0), b = Vector3.new(h + o, s1, e1) },
		}
		for _, light in lights do
			Kit.lit(onTop(light.name, light.a, light.b, ringLook, "detail"), "crown")
		end
		skyPool(-h + b + 3, -h + b + 3, h - b - 3, -h * 0.1)
		local beaconAt = onTopAt(h - b / 2, h - b / 2)
		Kit.lit(
			Kit.ball(
				m,
				"Beacon",
				Vector3.new(beaconAt.X, yt + 0.6, beaconAt.Z),
				1.2,
				Kit.look(rgb(150, 40, 36), Enum.Material.SmoothPlastic)
			),
			"beacon"
		)
	end

	-------------------------------------------------------------------------------------------------------
	-- The pool deck on the podium, in front of the stack, and its glass rail
	-------------------------------------------------------------------------------------------------------
	local stackFront = zc - reach - ext
	local deckFront, deckBack = pz0 + 2, stackFront - 4
	if deckBack - deckFront >= SHAPE.poolDeck then
		local poolW = math.min(SHAPE.poolWidth, (px1 - px0) * 0.32)
		local poolBack = math.min(deckBack, deckFront + SHAPE.poolDepth)
		Kit.pool(m, "Pool", Vector3.new(px0 + 6, 0, deckFront), Vector3.new(px0 + 6 + poolW, 0, poolBack), deck)
		local plantW = (px1 - px0) * 0.2
		Kit.planter(
			m,
			"PlanterA",
			Vector3.new(px1 - 6 - plantW, deck, pz0 + 1.2),
			Vector3.new(px1 - 6, deck + 1.6, pz0 + 3.4),
			frame
		)
		Kit.planter(
			m,
			"PlanterB",
			Vector3.new(px1 - 6 - plantW, deck, deckBack - 3.2),
			Vector3.new(px1 - 6, deck + 1.6, deckBack - 1),
			frame
		)
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
