--!strict
-- B06 corner_spire_hotel (docs/city/ARCHETYPES.md §6, B06): the nautical corner hotel, a landlocked liner. Its street
-- corner is a round bay: the upper floors' glass wraps it as rings under deep eyebrow discs, and on the ground it
-- stands open over a loggia of round columns round a lit glass lobby drum, under a canopy that rings the corner. Over
-- the roof the drum steps up and carries the signature: a slim finned sign tower like a ship's funnel, its blade on
-- the corner's diagonal lettered with the name down both faces, a crossing fin, a glowing ball on top and a needle
-- spire. The fronts are white bands of ribbon windows under eyebrows that run on round the corner and down the side
-- street, a row of portholes along each parapet, three speed lines round the drum, and the name on the canopy over a
-- café terrace that opens toward the corner.
--
-- What makes it itself: a finned funnel of a sign tower on the round corner, topped by a needle spire, the name down
-- its blade, over an open corner loggia.
-- Placement, sizes, heights and its budget: Config/CityArchetypes/corner_spire_hotel. A corner archetype (Config/City
-- cornerArchetypes): it draws its round corner at the +x end and placement mirrors it onto the block corner.
-- Variants: palette (4: canopy and speed-line colour, trim, the tower's neon and the portholes' neon), crown (1 the
-- slim finned sign tower and needle, 2 a fat smokestack with funnel bands, the named fin standing out of it and a
-- mast), rhythm (1 a drum 14 across, 2 a fatter one 17 across), mirror (set by placement: the corner it stands on).
--
-- Round 3 (2026-10-26, from photos and a 1950 postcard of the inspiration): the slim finned tower on a stepped drum
-- (the old full-width smokestack is now crown 2), the open loggia with columns under the round bay, eyebrows and
-- portholes down the side street, three speed lines, the name on the canopy, the letters on sleeves. Preview check:
-- the blade's letters face both streets (front-left and back-right faces; mirrored, front-right and back-left), the
-- loggia's columns and lobby drum read under the round bay from the corner, the side eyebrows line up with the side's
-- punched windows, and the tower's top stays inside the site's height (crownMax 48).
-- Round 4 (2026-10-26, seen in Studio): crown 1's lettered blade ran along the diagonal, so the corner saw only its
-- edge; it is now a panel square across the diagonal facing the corner, its name toward the intersection as on the
-- inspiration, with two return fins and neon up its edges. Stacked names are one word.

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
	parapet = 4.2, -- at least: room for the portholes and the speed lines
	floorMin = 10.3,
	floorMax = 11.6,
	floors = { 2, 2 },
	terrace = 9,
	bodyDepth = 40,
	sideInset = 3.6, -- the canopy's disc and the side eyebrows reach round the corner
	radius = { 7, 8.5 }, -- the round bay, by rhythm
	recess = 1.4, -- the ground floor's wall, behind the upper floors' face
	sill = 2.4,
	head = 1.5,
	lintel = 2.4,
	eyebrow = { thick = 0.6, proud = 2.6 },
	canopy = { thick = 1, proud = 3 }, -- the band over the ground floor, and round the corner over the loggia
	cornice = { thick = 0.9, proud = 1.4 },
	loggia = { column = 1.3, inset = 0.9, lobby = 3 }, -- columns on the bay's rim; the lobby drum this far inside it
	porthole = { d = 2.6, every = 7.5, min = 3, max = 5, side = 2 },
	speed = { 0.8, 1.6, 2.4 }, -- the speed lines round the drum, over the top floor line
	step = { rise = 2.4, inset = 1.2 }, -- the drum steps up over the roof
	-- Crown 1: the sign tower: a base drum (a share of the bay's width), a slim shaft, the lettered panel square across
	-- the diagonal in front of it (`panel` wide, `panelThick` deep), a fin returning `finBack` from each of its edges and
	-- stopping `finDrop` under its top, a ball on top, the needle's tip over the roof.
	tower = {
		base = 0.55,
		baseRise = 4,
		shaft = 3.4,
		rise = 24,
		panel = 6.2,
		panelThick = 1.4,
		fin = 0.6,
		finBack = 4,
		finDrop = 3,
		ball = 3.6,
	},
	needle = 46,
	-- Crown 2: the smokestack (a share of the bay's width) to `rise` over the roof, its funnel bands, the fin out of it
	-- (out of the stack, into it, over its top) and the mast's top over the roof.
	stack = { share = 0.72, rise = 16, bands = { 4.5, 9.5 }, band = 1 },
	fin = { thick = 1.4, out = 4.5, sunk = 2, over = 6 },
	mast = 40,
	sign = { width = 16, height = 1.8 }, -- the name standing on the canopy
	sideBay = 6.5,
	terraceTop = 0.9,
	balustrade = 2.2,
	umbrella = 7.5,
}

-- The canopy band and speed lines, the trim (cornice, funnel bands, porthole rims), the tower's neon and its day
-- colour, the portholes' neon, the letters and the wash.
local PALETTES = {
	{
		band = P.deco.lemon,
		trim = rgb(46, 127, 160),
		spireKind = "neonPink",
		spire = rgb(250, 200, 222),
		portKind = "neonAmber",
		letters = rgb(236, 62, 140),
		wash = rgb(255, 140, 200),
	},
	{
		band = P.deco.mint,
		trim = rgb(40, 84, 150),
		spireKind = "neonBlue",
		spire = rgb(200, 216, 250),
		portKind = "neonAmber",
		letters = rgb(46, 90, 200),
		wash = rgb(140, 180, 255),
	},
	{
		band = P.deco.peach,
		trim = rgb(30, 140, 150),
		spireKind = "neonCyan",
		spire = rgb(200, 240, 244),
		portKind = "neonPink",
		letters = rgb(20, 130, 150),
		wash = rgb(255, 170, 150),
	},
	{
		band = P.deco.sky,
		trim = rgb(110, 84, 176),
		spireKind = "neonViolet",
		spire = rgb(224, 210, 250),
		portKind = "neonAmber",
		letters = rgb(110, 84, 176),
		wash = rgb(200, 150, 255),
	},
}

local FRONT, BACK, LEFT, RIGHT = Enum.NormalId.Front, Enum.NormalId.Back, Enum.NormalId.Left, Enum.NormalId.Right
-- The corner's diagonal, out of the drum toward the front-right corner: (+1, -1) / root 2.
local DIAGONAL = math.sqrt(0.5)
local ALONG = CFrame.Angles(0, math.pi / 4, 0) -- a part's x along the diagonal
local ACROSS = CFrame.Angles(0, -math.pi / 4, 0) -- a part's x across it

-- Upper floors and their height for a roof at `height`: whole floors, the parapet taking up the rest.
local function storeys(height: number): (number, number)
	local room = height - SHAPE.ground - SHAPE.parapet
	local up = math.clamp(math.floor(room / SHAPE.floorMin + 1e-6), SHAPE.floors[1], SHAPE.floors[2])
	return up, math.min(room / up, SHAPE.floorMax)
end

-- A hotel name for the blade, short enough to stack (the leading "THE " dropped): its letters one per line, and the
-- name in full for the canopy.
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
	local bandLook = Kit.look(pal.band, Enum.Material.SmoothPlastic)
	local trim = Kit.look(pal.trim, Enum.Material.SmoothPlastic)
	local spireLook = Kit.look(pal.spire, Enum.Material.SmoothPlastic)
	local metal = Kit.look(rgb(220, 224, 228), Enum.Material.Metal)
	local ringGlass = Kit.glassLook(P.window.dark, 0.2)

	local R = SHAPE.radius[math.clamp(variant.rhythm, 1, 2)]
	local x0, x1 = -hw + SHAPE.sideInset, hw - SHAPE.sideInset
	local zF = -hd + SHAPE.terrace
	local zB = math.min(hd - 1, zF + SHAPE.bodyDepth)
	local cx, cz = x1 - R, zF + R -- the round bay's centre, at the corner end (+x)
	local corners = { fr = true }
	local bodyMin, bodyMax = Vector3.new(x0, 0, zF), Vector3.new(x1, 0, zB)
	-- A point `r` out of the drum's centre along the corner's diagonal, at height y.
	local function out(r: number, y: number): Vector3
		return Vector3.new(cx + r * DIAGONAL, y, cz - r * DIAGONAL)
	end
	local stacked, fullName = pickName(rng)

	-------------------------------------------------------------------------------------------------------
	-- Body: the block, the upper floors' front, the set-back ground floor, the round bay over its loggia
	-------------------------------------------------------------------------------------------------------
	Kit.box(m, "Core", Vector3.new(x0, -KIT.bury, cz), Vector3.new(x1, H, zB), white)
	Kit.box(m, "Upper", Vector3.new(x0 - 0.05, G, zF), Vector3.new(cx, H - 0.03, cz + 0.4), white)
	Kit.box(
		m,
		"Ground",
		Vector3.new(x0 - 0.05, -KIT.bury, zF + SHAPE.recess),
		Vector3.new(cx - R + 0.5, G, cz + 0.4),
		white
	)
	Kit.box(m, "Pier", Vector3.new(x0 - 0.1, -KIT.bury, zF), Vector3.new(x0 + 3, G, zF + SHAPE.recess + 0.3), white)
	Kit.glass(
		m,
		"Shop",
		Vector3.new(x0 + 3, SHAPE.terraceTop - 0.3, zF + SHAPE.recess - 0.3),
		Vector3.new(cx - R - 0.5, G - SHAPE.lintel, zF + SHAPE.recess + 0.2),
		P.window.dark,
		{
			image = City.textures.windowBold,
			faces = { FRONT },
			u = 4,
			v = G - SHAPE.lintel - SHAPE.terraceTop + 0.3,
			lines = P.deco.white,
			lit = true,
		}
	)
	-- The round bay from the first floor up; under it the loggia: a terrazzo floor a step up, columns on the rim
	-- facing both streets, and the lobby, a lit glass drum.
	-- A hair over the first floor line, so its underside never shares a plane with the upper floors' (both show from
	-- the loggia).
	Kit.column(m, "Drum", cx, cz, G + 0.02, H - 0.02, 2 * R, white)
	local lg = SHAPE.loggia
	Kit.column(
		m,
		"LoggiaFloor",
		cx,
		cz,
		0,
		SHAPE.terraceTop + 0.04,
		2 * R + 1,
		Kit.look(P.deco.terrazzo, Enum.Material.SmoothPlastic)
	)
	local rr = R - lg.inset
	for i, angle in { 0, 45, 90 } do
		local a = math.rad(angle)
		Kit.column(
			m,
			`Column{i}`,
			cx + rr * math.sin(a),
			cz - rr * math.cos(a),
			SHAPE.terraceTop - 0.2,
			G + 0.15,
			lg.column,
			white
		)
	end
	local lobby = Kit.column(m, "Lobby", cx, cz, SHAPE.terraceTop, G + 0.15, 2 * (R - lg.lobby), ringGlass)
	Kit.lit(lobby, "window")
	local cp = SHAPE.canopy
	Kit.band(m, "Canopy", bodyMin, bodyMax, R, corners, G, cp.thick, cp.proud, bandLook, "front")
	-- The name standing on the canopy along the front, beside the round bay.
	local sg = SHAPE.sign
	local signRight = cx - R - 1
	local signLeft = math.max(x0 + 1.5, signRight - sg.width)
	Kit.sign(
		m,
		"Sign",
		Vector3.new(signLeft, G + cp.thick / 2 - 0.05, zF - cp.proud + 0.35),
		Vector3.new(signRight, G + cp.thick / 2 + sg.height, zF - cp.proud + 0.6),
		FRONT,
		fullName,
		pal.band,
		pal.letters,
		FONT
	)

	-------------------------------------------------------------------------------------------------------
	-- The floors: ribbons, glass rings round the bay, eyebrows round it and down the side street
	-------------------------------------------------------------------------------------------------------
	local brow = SHAPE.eyebrow
	for k = 1, up do
		local y0 = G + (k - 1) * f + SHAPE.sill
		local y1 = G + k * f - SHAPE.head
		Kit.glass(m, `Ribbon{k}`, Vector3.new(x0 + 1.6, y0, zF - 0.12), Vector3.new(cx, y1, zF + 0.4), P.window.dark, {
			image = City.textures.windowFine,
			faces = { FRONT },
			u = 2.2,
			v = y1 - y0,
			lines = P.deco.white,
			reflectance = 0.2,
		})
		Kit.column(m, `Ring{k}`, cx, cz, y0, y1, 2 * R + 0.1, ringGlass)
		local y = y1 + 0.4
		Kit.band(m, `Brow{k}`, bodyMin, bodyMax, R, corners, y, brow.thick, brow.proud, white, "front")
		-- Down the side street from where the disc round the bay meets the wall; a hair thinner than the disc, so the
		-- two never share a top or bottom face where they overlap.
		Kit.trim(
			m,
			`SideBrow{k}`,
			Vector3.new(x1 - 0.5, y - brow.thick / 2 + 0.02, cz),
			Vector3.new(x1 + brow.proud, y + brow.thick / 2 - 0.02, zB - 1),
			white
		)
	end
	local cn = SHAPE.cornice
	Kit.band(m, "Cornice", bodyMin, bodyMax, R, corners, H - cn.thick / 2 + 0.06, cn.thick, cn.proud, trim, "front")
	for i, side in { -1, 1 } do
		local wallX = if side < 0 then x0 else x1
		Kit.punched(
			m,
			`Side{i}`,
			Vector3.new(wallX - side * 0.4, G, cz + 0.6),
			Vector3.new(wallX + side * 0.06, T, zB - 0.6),
			P.deco.white,
			P.window.dark,
			{ if side < 0 then LEFT else RIGHT },
			SHAPE.sideBay,
			f
		)
	end
	-- Three speed lines round the bay between the top floor and the cornice.
	for j, rise in SHAPE.speed do
		Kit.disc(m, `Speed{j}`, cx, cz, T + rise, 2 * R + 0.6, 0.3, bandLook, "trim")
	end

	-- A row of portholes along the front's parapet, centred, and a shorter one along the side street's.
	local ph = SHAPE.porthole
	local py = T + (H - cn.thick - T) / 2
	local px0, px1 = x0 + 2.5, cx - R - 2
	local count = math.clamp(math.floor((px1 - px0) / ph.every) + 1, ph.min, ph.max)
	local spacing = math.min(ph.every, (px1 - px0) / (count - 1))
	local start = (px0 + px1) / 2 - spacing * (count - 1) / 2
	for i = 1, count do
		Kit.porthole(m, `Port{i}`, start + (i - 1) * spacing, py, zF, ph.d, P.window.deep, trim, pal.portKind)
	end
	local sz0 = cz + R + 2
	for i = 1, ph.side do
		local z = sz0 + (i - 1) * ph.every
		if z > zB - 3 then
			break
		end
		Kit.tube(m, `SidePortRim{i}`, Vector3.new(x1 - 0.3, py, z), Vector3.new(x1 + 0.4, py, z), ph.d, trim, "trim")
		local pane = Kit.tube(
			m,
			`SidePort{i}`,
			Vector3.new(x1 + 0.3, py, z),
			Vector3.new(x1 + 0.5, py, z),
			ph.d * 0.72,
			Kit.glassLook(P.window.deep, 0.25),
			"detail"
		)
		Kit.lit(pane, pal.portKind)
	end
	Kit.roofBox(m, "Stair", Vector3.new(x0 + 4, H, zB - 10), Vector3.new(x0 + 11, H + 6, zB - 3), white)

	-------------------------------------------------------------------------------------------------------
	-- Over the roof: the drum steps up, then the sign tower (crown 1) or the smokestack (crown 2)
	-------------------------------------------------------------------------------------------------------
	local st = SHAPE.step
	local Hd = H + st.rise -- the step's top
	Kit.column(m, "DrumStep", cx, cz, H - 0.02, Hd, 2 * (R - st.inset), white)
	-- A blade standing out of the tower along the corner's diagonal, from r0 to r1 out of the drum's centre and from
	-- y0 to y1, `thick` across. The name is stacked on a sleeve a hair proud of its faces over the part from `free`
	-- out (clear of the shaft or stack it stands out of), so the letters are never inside it and the blade itself stays
	-- with the still parts (a labelled part files with the lights).
	local function blade(name: string, r0: number, r1: number, y0: number, y1: number, thick: number, free: number)
		local ym = (y0 + y1) / 2
		Kit.oriented(
			m,
			name,
			"block",
			CFrame.new(out((r0 + r1) / 2, ym)) * ALONG,
			Vector3.new(r1 - r0, y1 - y0, thick),
			white,
			"trim"
		)
		local s0, s1 = free, r1 - 0.4
		local sleeve = Kit.oriented(
			m,
			name .. "Letters",
			"block",
			CFrame.new(out((s0 + s1) / 2, ym)) * ALONG,
			Vector3.new(s1 - s0, y1 - y0 - 2.4, thick + 0.12),
			white,
			"detail"
		)
		local labels: { MapTypes.LabelSpec } = {}
		-- Turned along the diagonal, the blade's Front face looks along the front street, its Back face down the
		-- side one (mirrored, the same faces look the other way round, onto the mirrored streets).
		for _, face in { FRONT, BACK } do
			table.insert(labels, {
				face = face,
				text = stacked,
				color = pal.letters,
				font = FONT,
				size = Vector2.new(0.76, 0.94),
				pixelsPerStud = KIT.signPixelsPerStud,
			})
		end
		sleeve.labels = labels
	end
	if crown == 1 then
		local tw = SHAPE.tower
		local baseTop = Hd + tw.baseRise
		local top = H + tw.rise + st.rise + tw.baseRise -- the shaft's top
		Kit.column(m, "TowerBase", cx, cz, Hd - 0.02, baseTop, 2 * R * tw.base, white)
		Kit.column(m, "Shaft", cx, cz, baseTop - 0.02, top, tw.shaft, white)
		-- The sign panel stands square across the corner's diagonal in front of the shaft, its face (and the name
		-- stacked down it) toward the corner, as on the inspiration: a blade along the diagonal showed the corner only
		-- its edge. Two fins return from its edges into the shaft, stopping short of the panel's top.
		local pt = tw.panelThick
		local pr = tw.shaft / 2 + pt / 2 - 0.3 -- the panel's centre, out of the drum's centre
		local py0, py1 = baseTop - 0.02, top - 1
		local ym = (py0 + py1) / 2
		Kit.oriented(
			m,
			"Panel",
			"block",
			CFrame.new(out(pr, ym)) * ACROSS,
			Vector3.new(tw.panel, py1 - py0, pt),
			white,
			"trim"
		)
		local sleeve = Kit.oriented(
			m,
			"PanelLetters",
			"block",
			CFrame.new(out(pr, ym)) * ACROSS,
			Vector3.new(tw.panel - 1.2, py1 - py0 - 2.4, pt + 0.12),
			white,
			"detail"
		)
		-- The oriented part's Front face is the one toward the corner, mirrored or not.
		sleeve.labels = {
			{
				face = FRONT,
				text = stacked,
				color = pal.letters,
				font = FONT,
				size = Vector2.new(0.8, 0.94),
				pixelsPerStud = KIT.signPixelsPerStud,
			},
		}
		local fy1 = py1 - tw.finDrop
		for i, side in { -1, 1 } do
			-- Across the diagonal is (+1, +1) / root 2 in x and z; a fin at each edge of the panel, along the diagonal.
			-- A hair outside the panel's side and behind its face, so no face of the two is shared.
			local across = side * (tw.panel / 2 - tw.fin / 2 + 0.08)
			local r = pr + pt / 2 - 0.12 - tw.finBack / 2
			local c = out(r, (py0 + fy1) / 2) + Vector3.new(across * DIAGONAL, 0, across * DIAGONAL)
			Kit.oriented(
				m,
				`Fin{i}`,
				"block",
				CFrame.new(c) * ALONG,
				Vector3.new(tw.finBack, fy1 - py0, tw.fin),
				trim, -- in the trim colour: an all-white tower read flat against the sky
				"trim"
			)
			-- Neon up the panel's two front edges.
			local edge = side * (tw.panel / 2 - 0.15)
			local ez = Vector3.new(edge * DIAGONAL, 0, edge * DIAGONAL)
			Kit.neon(
				m,
				`PanelNeon{i}`,
				out(pr + pt / 2 + 0.15, py0 + 0.6) + ez,
				out(pr + pt / 2 + 0.15, py1 - 0.6) + ez,
				pal.spireKind,
				pal.spire
			)
		end
		Kit.lit(Kit.ball(m, "Cap", Vector3.new(cx, top, cz), tw.ball, spireLook, "trim"), pal.spireKind)
		local tip = H + SHAPE.needle
		Kit.column(m, "Needle", cx, cz, top + tw.ball / 2 - 0.3, tip, 0.4, metal, "detail")
		Kit.lit(Kit.ball(m, "Tip", Vector3.new(cx, tip + 0.6, cz), 1.2, spireLook), pal.spireKind)
	else
		local sk = SHAPE.stack
		local rs = R * sk.share
		local Hs = H + sk.rise
		Kit.column(m, "Stack", cx, cz, Hd - 0.02, Hs, 2 * rs, white)
		for i, rise in sk.bands do
			Kit.disc(m, `Funnel{i}`, cx, cz, H + rise, 2 * rs + 0.8, sk.band, trim, "trim")
		end
		Kit.disc(m, "StackCap", cx, cz, Hs + 0.3, 2 * rs + 1.2, 1, white, "trim")
		local fn = SHAPE.fin
		local inner, outer = rs - fn.sunk, rs + fn.out
		local fy0, fy1 = Hd + 0.6, Hs + fn.over
		blade("Fin", inner, outer, fy0, fy1, fn.thick, rs + 0.2)
		Kit.neon(m, "FinNeon", out(outer + 0.3, fy0 + 0.6), out(outer + 0.3, fy1 - 0.6), pal.spireKind, pal.spire)
		local mast = H + SHAPE.mast
		Kit.column(m, "Mast", cx, cz, Hs + 0.78, mast, 0.5, metal, "detail")
		Kit.lit(Kit.ball(m, "Tip", Vector3.new(cx, mast + 0.6, cz), 1.2, spireLook), pal.spireKind)
	end

	-------------------------------------------------------------------------------------------------------
	-- The café terrace, open toward the corner loggia; umbrellas; the wash on the canopy at the corner
	-------------------------------------------------------------------------------------------------------
	local tTop = SHAPE.terraceTop
	Kit.box(
		m,
		"Terrace",
		Vector3.new(-hw + 0.2, 0, -hd + 0.3),
		Vector3.new(hw - 0.2, tTop, zF + SHAPE.recess + 0.2),
		Kit.look(P.deco.terrazzo, Enum.Material.SmoothPlastic)
	)
	local railTop = tTop + SHAPE.balustrade
	local a, c = -hw + 0.6, cx - R - 1
	Kit.box(m, "Balustrade", Vector3.new(a, tTop, -hd + 0.6), Vector3.new(c, railTop, -hd + 1.3), white)
	Kit.detail(
		m,
		"Coping",
		Vector3.new(a - 0.1, railTop, -hd + 0.5),
		Vector3.new(c + 0.1, railTop + 0.35, -hd + 1.4),
		bandLook
	)
	local tz = (-hd + 1.4 + zF) / 2
	local room = math.min(SHAPE.umbrella, (zF - 0.4 - tz) * 2, (tz + hd - 1.4) * 2)
	local len = c - a - 1.6
	local umbrellas = math.clamp(math.floor(len / (room + 3)), 0, 3)
	for j = 1, umbrellas do
		local x = a + 0.8 + len * (j - 0.5) / umbrellas
		local color = if j % 2 == 1 then pal.band else P.deco.white
		Kit.umbrella(m, `Umbrella{j}`, x, tz, tTop, math.min(room, len / umbrellas - 1), color)
	end
	Kit.wash(m, "Wash", cx - R - 4, cx + 2, zF - 1.8, G + cp.thick / 2, pal.wash)
end

local archetype: Types.Archetype = { id = "corner_spire_hotel", build = build }
return archetype
