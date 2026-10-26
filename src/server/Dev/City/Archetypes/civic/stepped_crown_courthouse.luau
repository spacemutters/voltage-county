--!strict
-- C02 stepped_crown_courthouse (docs/city/ARCHETYPES.md §9, C02): the old city's grey stone courthouse, the crown of
-- downtown before the glass. A rusticated granite ground storey with steps and bronze doors; over it a colossal
-- colonnade in a portico between two end pavilions, an entablature carrying the court's name, a deep cornice. From
-- the base a square stone tower rises in two stages: windows recessed between proud piers, a ledge at the setback.
-- On top, a colonnade storey round a lit core, then the signature: a stepped pyramid, each step ringed with warm
-- light at night, and a lantern.
--
-- What makes it itself: a stone tower ending in a temple of columns under a stepped pyramid.
-- Placement, sizes, heights and its budget: Config/CityArchetypes/stepped_crown_courthouse.
-- Variants: palette (1 pale limestone and granite, 2 warm buff terracotta with a gilded pyramid, 3 white stone, dark
-- granite and a copper-green pyramid), crown (1 six steps and a lantern, 2 eight shallower steps, a lantern and a
-- spire with a beacon), rhythm (1 four bays a face and single columns, 2 three bays a face and paired columns),
-- mirror (the flagpoles' side of the plaza).
--
-- Previewing (Studio helper): Preview.build("stepped_crown_courthouse", { width = 124, depth = 100 }) for the full
-- look (the planner's core claim gives it that depth); width 84, depth 53 is the plain-plot fallback (a 30-stud
-- tower). Check: the pyramid's steps read as steps against the sky from the street, the colonnade's columns stand
-- clear of the portico glass, the piers read proud of the windows; at night the step rings glow warm, the colonnade
-- core and lantern are lit, and the wash lights the big columns.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local City = require(ReplicatedStorage.Shared.Config.City)
local Kit = require(script.Parent.Parent.Parent.Kit)
local Types = require(script.Parent.Parent.Parent.Types)

local P = City.palettes
local KIT = City.kit
local rgb = Color3.fromRGB

-- The recipe, in studs.
local SHAPE = {
	plaza = 10, -- paving and steps between the front line and the granite ground storey
	sideInset = 2.4, -- the cornice and the ground storey's cornice stand proud of the walls
	backInset = 1.5,
	baseMax = 124,
	podium = 15, -- the granite ground storey
	podiumCornice = { thick = 1.2, proud = 1.2 },
	baseTop = 72,
	floor = 12,
	portico = 5.5, -- the colonnade stands this deep in front of the portico wall
	colonnade = { share = 0.62, min = 30, max = 84, every = 8.5, most = 12, column = 3.6, top = 58, pairGap = 4.6 },
	entablature = { top = 64.5, proud = 0.45 },
	cornice = { thick = 2.4, proud = 1.8 },
	pavilionMin = 8, -- each end pavilion at least this wide, or the colonnade narrows
	pavilionWindow = { width = 4.6, sill = 4, head = 4 },
	doors = { share = 0.5, max = 30, height = 11.4 },
	shaft = { share = 0.4, max = 48, min = 12, stage2 = { share = 0.13, min = 24, max = 34 }, step = 4 },
	-- Corner piers reach `corner` onto each face and stand `cornerProud` out past it (so they never cover a window);
	-- the piers between bays are `wide` and stand `proud`.
	pier = { corner = 0.4, cornerProud = 2.0, wide = 2.6, proud = 1.0 },
	-- The window columns on the tower: `perBay` windows across, set `proud` out of the stone core (the piers stand
	-- further out), `margin` of stone either side between them and the piers, from `sill` over a stage's foot to
	-- `head` under its top.
	strip = { perBay = 2, proud = 0.12, margin = 1.3, sill = 1.5, head = 2 },
	ledge = { thick = 1.4, proud = 1.4 },
	towerCornice = { thick = 1.4, proud = 1.4 },
	peristyle = { height = 16, perSide = 5, inset = 1.6, core = 2.2, entablature = 3 },
	pyramid = {
		{ steps = 6, rise = 6.4, inset = 3.2 }, -- crown 1
		{ steps = 8, rise = 4.6, inset = 2.6 }, -- crown 2
	},
	ring = { thick = 1.1, proud = 0.15, under = 0.5 }, -- the light band round each pyramid step
	lantern = { width = 3.4, height = 4 },
	spire = { height = 9, diameter = 0.9 },
	flags = { count = 3, height = 22, every = 4, flag = Vector3.new(4.2, 2.6, 0.12) },
	font = Enum.Font.Merriweather,
}

-- Stone (walls, piers, columns), granite (the ground storey), the pyramid, the doors' bronze and the wash.
local PALETTES = {
	{
		stone = rgb(204, 198, 186),
		trim = rgb(222, 216, 204),
		granite = rgb(204, 200, 192),
		spandrel = rgb(190, 184, 172),
		pyramid = Kit.look(rgb(214, 208, 196), Enum.Material.Limestone),
		bronze = rgb(92, 72, 50),
		wash = rgb(255, 222, 180),
	},
	{
		stone = rgb(220, 204, 178),
		trim = rgb(234, 222, 200),
		granite = rgb(190, 176, 156),
		spandrel = rgb(206, 190, 164),
		pyramid = Kit.look(rgb(222, 190, 128), Enum.Material.Limestone),
		bronze = rgb(110, 80, 46),
		wash = rgb(255, 210, 150),
	},
	{
		stone = rgb(232, 228, 218),
		trim = rgb(244, 240, 232),
		granite = rgb(112, 112, 114),
		spandrel = rgb(214, 210, 200),
		pyramid = Kit.look(rgb(98, 146, 126), Enum.Material.SmoothPlastic),
		bronze = rgb(70, 64, 56),
		wash = rgb(255, 232, 200),
	},
}

local DARK = P.window.deep
local FLAG_COLORS = { rgb(40, 84, 156), rgb(246, 244, 238), rgb(38, 132, 118) }

local function build(m: Types.Model)
	local site = m.site
	local variant = site.variant
	local pal = PALETTES[math.clamp(variant.palette, 1, #PALETTES)]
	local rng = Kit.rng(m)
	local W, D, H = site.width, site.depth, site.height
	local hw, hd = W / 2, D / 2
	local rhythm = math.clamp(variant.rhythm, 1, 2)
	local stone = Kit.look(pal.stone, Enum.Material.Limestone)
	local trimLook = Kit.look(pal.trim, Enum.Material.SmoothPlastic)
	-- Concrete, not Granite: the Granite material reads dark and blotchy at this scale; the base is pale granite.
	local granite = Kit.look(pal.granite, Enum.Material.Concrete)

	-------------------------------------------------------------------------------------------------------
	-- Layout
	-------------------------------------------------------------------------------------------------------
	local bw = math.min(W - 2 * SHAPE.sideInset, SHAPE.baseMax)
	local bx0, bx1 = -bw / 2, bw / 2
	local zF, zB = -hd + SHAPE.plaza, hd - SHAPE.backInset
	local zP = zF + SHAPE.portico -- the portico wall behind the columns
	local col = SHAPE.colonnade
	local cw = math.clamp(bw * col.share, col.min, col.max)
	cw = math.min(cw, bw - 2 * SHAPE.pavilionMin)
	local podiumTop = SHAPE.podium
	local pc = SHAPE.podiumCornice
	local floorY = podiumTop + pc.thick -- the colonnade's floor
	local baseTop = SHAPE.baseTop

	-------------------------------------------------------------------------------------------------------
	-- Plaza, steps, the granite ground storey and its doors
	-------------------------------------------------------------------------------------------------------
	local paving = Kit.look(rgb(206, 202, 194), Enum.Material.Granite)
	Kit.box(m, "Plaza", Vector3.new(-hw + 0.3, 0, -hd + 0.3), Vector3.new(hw - 0.3, 0.25, zF + 0.6), paving)
	local dw = math.min(cw * SHAPE.doors.share, SHAPE.doors.max)
	local sw = dw + 8
	Kit.box(m, "Step1", Vector3.new(-sw / 2, 0.25, zF - 6.5), Vector3.new(sw / 2, 0.75, zF - 0.5), granite)
	Kit.box(m, "Step2", Vector3.new(-sw / 2 + 1.5, 0.75, zF - 4), Vector3.new(sw / 2 - 1.5, 1.25, zF - 0.5), granite)
	Kit.box(
		m,
		"Podium",
		Vector3.new(bx0 - 0.6, -KIT.bury, zF - 0.6),
		Vector3.new(bx1 + 0.6, podiumTop, zB - 0.4),
		granite
	)
	Kit.trim(
		m,
		"PodiumCornice",
		Vector3.new(bx0 - pc.proud, podiumTop, zF - pc.proud),
		Vector3.new(bx1 + pc.proud, floorY, zB - 0.3),
		trimLook
	)
	Kit.glass(
		m,
		"Doors",
		Vector3.new(-dw / 2, 1.25, zF - 0.68),
		Vector3.new(dw / 2, SHAPE.doors.height, zF - 0.4),
		pal.bronze,
		{
			image = City.textures.windowBold,
			faces = { Enum.NormalId.Front },
			u = dw / 6,
			v = SHAPE.doors.height - 1.25,
			lines = pal.trim,
			lit = true,
			reflectance = 0.04,
		}
	)

	-------------------------------------------------------------------------------------------------------
	-- The base: punched stone sides, end pavilions, the portico glass behind a colossal colonnade
	-------------------------------------------------------------------------------------------------------
	Kit.punched(
		m,
		"Base",
		Vector3.new(bx0, podiumTop - 1, zP),
		Vector3.new(bx1, baseTop, zB),
		pal.stone,
		DARK,
		{ Enum.NormalId.Left, Enum.NormalId.Right, Enum.NormalId.Back },
		6,
		SHAPE.floor
	)
	Kit.glass(
		m,
		"Portico",
		Vector3.new(-cw / 2, floorY - 0.05, zP - 0.08),
		Vector3.new(cw / 2, baseTop - 0.5, zP + 0.3),
		DARK,
		{
			image = City.textures.windowBold,
			faces = { Enum.NormalId.Front },
			u = 4.2,
			v = SHAPE.floor,
			lines = pal.stone,
			lit = rng:NextNumber() < 0.5,
			reflectance = 0.12,
		}
	)
	local pv = SHAPE.pavilionWindow
	for i, side in { -1, 1 } do
		local outer = if side < 0 then bx0 - 0.3 else bx1 + 0.3
		local inner = side * (cw / 2 - 0.2)
		Kit.box(
			m,
			`Pavilion{i}`,
			Vector3.new(math.min(outer, inner), podiumTop - 1, zF),
			Vector3.new(math.max(outer, inner), baseTop - 0.04, zP + 0.6),
			stone
		)
		-- Two tall window columns in each pavilion's front.
		for k = 1, 2 do
			local x = inner + (outer - inner) * (k == 1 and 0.32 or 0.68)
			Kit.glass(
				m,
				`PavilionWindows{i}{k}`,
				Vector3.new(x - pv.width / 2, floorY + pv.sill, zF - 0.08),
				Vector3.new(x + pv.width / 2, baseTop - pv.head, zF + 0.3),
				DARK,
				{
					image = City.textures.windowBold,
					faces = { Enum.NormalId.Front },
					u = pv.width / 2,
					v = SHAPE.floor,
					lines = pal.stone,
					reflectance = 0.12,
				}
			)
		end
	end
	-- The colonnade: single columns evenly spaced (rhythm 1) or pairs (rhythm 2).
	local cx0, cx1 = -cw / 2 + 3, cw / 2 - 3
	local xs: { number } = {}
	if rhythm == 2 then
		local pairs = math.clamp(math.floor(cw / 17) + 1, 2, col.most // 2)
		for k = 1, pairs do
			local x = if pairs == 1
				then 0
				else cx0 + col.pairGap / 2 + (cx1 - cx0 - col.pairGap) * (k - 1) / (pairs - 1)
			table.insert(xs, x - col.pairGap / 2)
			table.insert(xs, x + col.pairGap / 2)
		end
	else
		local n = math.clamp(math.floor(cw / col.every) + 1, 4, col.most)
		for k = 1, n do
			table.insert(xs, cx0 + (cx1 - cx0) * (k - 1) / (n - 1))
		end
	end
	local columnZ = zF + 0.6 + col.column / 2
	for k, x in xs do
		Kit.column(m, `Column{k}`, x, columnZ, floorY - 0.05, col.top + 0.05, col.column, trimLook, "trim")
	end
	local en = SHAPE.entablature
	Kit.trim(
		m,
		"Entablature",
		Vector3.new(-cw / 2 + 0.05, col.top, zF + 0.6 - en.proud),
		Vector3.new(cw / 2 - 0.05, en.top, zP + 0.4),
		trimLook
	)
	local signW = math.min(cw - 10, 64)
	Kit.sign(
		m,
		"Name",
		Vector3.new(-signW / 2, col.top + 1.6, zF + 0.6 - en.proud - 0.12),
		Vector3.new(signW / 2, en.top - 1.4, zF + 0.6 - en.proud - 0.04),
		Enum.NormalId.Front,
		"VOLTAGE COUNTY COURTHOUSE",
		pal.trim,
		rgb(62, 58, 52),
		SHAPE.font
	)
	local co = SHAPE.cornice
	Kit.trim(
		m,
		"Cornice",
		Vector3.new(bx0 - co.proud, baseTop - co.thick + 0.08, zF - co.proud),
		Vector3.new(bx1 + co.proud, baseTop + 0.08, zB - 0.3),
		trimLook
	)
	-- At night a wash on the ground storey's cornice lights the columns.
	Kit.wash(m, "Wash", cx0, cx1, zF - pc.proud + 0.5, floorY, pal.wash)

	-------------------------------------------------------------------------------------------------------
	-- The tower: two stages of windows between proud stone piers, a ledge at the setback
	-------------------------------------------------------------------------------------------------------
	local sh = SHAPE.shaft
	local S1 = math.max(sh.min, math.min(sh.max, W * sh.share, zB - zP - 4))
	local tcz = (zP + zB) / 2
	local stage2 = math.clamp(H * sh.stage2.share, sh.stage2.min, sh.stage2.max)
	local y1 = H - stage2 -- the setback
	local S2 = math.max(sh.min * 0.7, S1 - 2 * sh.step)
	local pr = SHAPE.pier
	-- One stage: a stone core, a column of windows and spandrels in each bay of each face (the courthouse's vertical
	-- lines, stone showing between them), corner piers and `bays - 1` proud piers a face.
	local function stage(name: string, side: number, y0: number, yTop: number, bays: number, lit: boolean)
		local s = side / 2
		local pitch = side / bays
		Kit.box(m, name, Vector3.new(-s, y0, tcz - s), Vector3.new(s, yTop, tcz + s), stone)
		local st = SHAPE.strip
		local floors = math.max(1, math.floor((yTop - y0 - st.sill - st.head) / SHAPE.floor))
		local wTop = yTop - st.head
		local wBottom = wTop - floors * SHAPE.floor
		local cw2 = pitch - pr.wide - 2 * st.margin -- each bay's strip, centred between its piers
		for f, face in { "front", "back", "left", "right" } do
			local normal = if face == "front"
				then Enum.NormalId.Front
				elseif face == "back" then Enum.NormalId.Back
				elseif face == "left" then Enum.NormalId.Left
				else Enum.NormalId.Right
			for b = 1, bays do
				local c = -s + pitch * (b - 0.5)
				local lo: Vector3, hi: Vector3
				if face == "front" then
					lo, hi =
						Vector3.new(c - cw2 / 2, wBottom, tcz - s - st.proud),
						Vector3.new(c + cw2 / 2, wTop, tcz - s + 0.3)
				elseif face == "back" then
					lo, hi =
						Vector3.new(c - cw2 / 2, wBottom, tcz + s - 0.3),
						Vector3.new(c + cw2 / 2, wTop, tcz + s + st.proud)
				elseif face == "left" then
					lo, hi =
						Vector3.new(-s - st.proud, wBottom, tcz + c - cw2 / 2),
						Vector3.new(-s + 0.3, wTop, tcz + c + cw2 / 2)
				else
					lo, hi =
						Vector3.new(s - 0.3, wBottom, tcz + c - cw2 / 2),
						Vector3.new(s + st.proud, wTop, tcz + c + cw2 / 2)
				end
				Kit.glass(m, `{name}Windows{f}{b}`, lo, hi, DARK, {
					image = City.textures.windowBold,
					faces = { normal },
					u = cw2 / st.perBay,
					v = SHAPE.floor,
					lines = pal.spandrel,
					lit = lit and f <= 2,
					reflectance = 0.05,
				})
			end
		end
		for i, c in { { -1, -1 }, { 1, -1 }, { -1, 1 }, { 1, 1 } } do
			local cx, cz = c[1] * s, tcz + c[2] * s
			Kit.trim(
				m,
				`{name}Corner{i}`,
				Vector3.new(cx - c[1] * pr.corner, y0 + 0.02, cz - c[2] * pr.corner),
				Vector3.new(cx + c[1] * pr.cornerProud, yTop - 0.02, cz + c[2] * pr.cornerProud),
				stone
			)
		end
		for k = 1, bays - 1 do
			local a = -s + pitch * k
			local w = pr.wide / 2
			Kit.trim(
				m,
				`{name}PierF{k}`,
				Vector3.new(a - w, y0 + 0.04, tcz - s - pr.proud),
				Vector3.new(a + w, yTop - 0.04, tcz + s + pr.proud),
				stone
			)
			Kit.trim(
				m,
				`{name}PierS{k}`,
				Vector3.new(-s - pr.proud, y0 + 0.06, tcz + a - w),
				Vector3.new(s + pr.proud, yTop - 0.06, tcz + a + w),
				stone
			)
		end
	end

	local bays1 = if rhythm == 1 then 4 else 3
	local bays2 = if rhythm == 1 then 2 else 3
	stage("Shaft", S1, baseTop - 1, y1, bays1, false)
	local lg = SHAPE.ledge
	Kit.trim(
		m,
		"Ledge",
		Vector3.new(-S1 / 2 - lg.proud, y1 - lg.thick / 2, tcz - S1 / 2 - lg.proud),
		Vector3.new(S1 / 2 + lg.proud, y1 + lg.thick / 2, tcz + S1 / 2 + lg.proud),
		trimLook
	)
	local tc = SHAPE.towerCornice
	stage("Upper", S2, y1 + lg.thick / 2 - 0.1, H - tc.thick, bays2, false)
	Kit.trim(
		m,
		"TowerCornice",
		Vector3.new(-S2 / 2 - tc.proud, H - tc.thick, tcz - S2 / 2 - tc.proud),
		Vector3.new(S2 / 2 + tc.proud, H, tcz + S2 / 2 + tc.proud),
		trimLook
	)

	-------------------------------------------------------------------------------------------------------
	-- The crown: a colonnade storey round a lit core, its entablature, the stepped pyramid and a lantern
	-------------------------------------------------------------------------------------------------------
	local ps = SHAPE.peristyle
	local q = S2 / 2 - ps.inset
	local cd = math.clamp(S2 * 0.06, 1.4, 3)
	local pTop = H + ps.height
	Kit.glass(
		m,
		"CrownCore",
		Vector3.new(-q + ps.core, H, tcz - q + ps.core),
		Vector3.new(q - ps.core, pTop, tcz + q - ps.core),
		DARK,
		{ lit = true, reflectance = 0.1 }
	)
	local n = ps.perSide
	local k = 0
	for i = 0, n - 1 do
		for j = 0, n - 1 do
			if i == 0 or j == 0 or i == n - 1 or j == n - 1 then
				k += 1
				local x = -q + 2 * q * i / (n - 1)
				local z = tcz - q + 2 * q * j / (n - 1)
				Kit.column(m, `Peristyle{k}`, x, z, H - 0.05, pTop + 0.05, cd, trimLook, "trim")
			end
		end
	end
	local eTop = pTop + ps.entablature
	Kit.trim(
		m,
		"CrownEntablature",
		Vector3.new(-S2 / 2 - 0.6, pTop, tcz - S2 / 2 - 0.6),
		Vector3.new(S2 / 2 + 0.6, eTop, tcz + S2 / 2 + 0.6),
		trimLook
	)
	local py = SHAPE.pyramid[math.clamp(variant.crown, 1, #SHAPE.pyramid)]
	local w0 = S2 - 0.5
	local inset = math.min(py.inset, (w0 - 5) / (2 * py.steps))
	local tiers: { { width: number, depth: number, height: number } } = {}
	for t = 1, py.steps do
		local w = w0 - 2 * inset * (t - 1)
		table.insert(tiers, { width = w, depth = w, height = py.rise })
	end
	local _, top = Kit.steppedCrown(m, "Pyramid", 0, tcz, eTop - 0.02, tiers, pal.pyramid)
	-- A band of warm light round the top of each step's riser: a pale stone moulding by day. Thick enough to read
	-- from across downtown (the kit's own ring is a 0.4 sliver).
	local ring = SHAPE.ring
	for t, tier in tiers do
		local half = tier.width / 2 + ring.proud
		local ry = eTop - 0.02 + t * py.rise - ring.under
		Kit.neonStrip(
			m,
			`PyramidRing{t}`,
			Vector3.new(-half, ry - ring.thick, tcz - half),
			Vector3.new(half, ry, tcz + half),
			"neonAmber",
			pal.trim
		)
	end
	local la = SHAPE.lantern
	local lw = la.width / 2
	Kit.glass(
		m,
		"Lantern",
		Vector3.new(-lw, top - 0.05, tcz - lw),
		Vector3.new(lw, top + la.height, tcz + lw),
		DARK,
		{ lit = true, reflectance = 0.1 }
	)
	local capTop = top + la.height + 0.8
	Kit.trim(
		m,
		"LanternCap",
		Vector3.new(-lw - 0.5, top + la.height, tcz - lw - 0.5),
		Vector3.new(lw + 0.5, capTop, tcz + lw + 0.5),
		pal.pyramid
	)
	local room = site.maxHeight - capTop - 1.4
	if variant.crown == 2 and room > 2 then
		Kit.spire(
			m,
			"Spire",
			0,
			tcz,
			capTop,
			math.min(SHAPE.spire.height, room),
			SHAPE.spire.diameter,
			Kit.look(rgb(196, 198, 200), Enum.Material.Metal),
			2,
			true
		)
	else
		Kit.ball(m, "Finial", Vector3.new(0, capTop + 0.9, tcz), 2, pal.pyramid, "detail")
	end

	-------------------------------------------------------------------------------------------------------
	-- Flagpoles on one side of the plaza (the mirror's side)
	-------------------------------------------------------------------------------------------------------
	local fl = SHAPE.flags
	local metal = Kit.look(rgb(206, 208, 210), Enum.Material.Metal)
	local fx0 = -sw / 2 - 4
	for i = 1, fl.count do
		local x = fx0 - (i - 1) * fl.every
		if x - fl.flag.X < -hw + 0.5 then
			break
		end
		local z = -hd + 3
		Kit.column(m, `Flagpole{i}`, x, z, 0.25, 0.25 + fl.height, 0.4, metal, "detail")
		Kit.detail(
			m,
			`Flag{i}`,
			Vector3.new(x - fl.flag.X - 0.2, fl.height - fl.flag.Y - 0.6, z - fl.flag.Z / 2),
			Vector3.new(x - 0.2, fl.height - 0.6, z + fl.flag.Z / 2),
			Kit.look(FLAG_COLORS[(i - 1) % #FLAG_COLORS + 1], Enum.Material.Fabric)
		)
	end
end

local archetype: Types.Archetype = { id = "stepped_crown_courthouse", build = build }
return archetype
