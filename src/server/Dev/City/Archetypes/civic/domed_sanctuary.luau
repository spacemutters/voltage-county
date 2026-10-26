--!strict
-- C05 domed_sanctuary (docs/city/ARCHETYPES.md §9, C05): the beach district's domed sanctuary, Byzantine forms made
-- smooth in the Deco manner. A pale smooth block on a low plinth under a stepped cornice; on its front a tall arched
-- portal of stained glass in a stone frame, flanked by two short square towers with stepped tops and small domes;
-- tall arched windows down the sides. On the roof the signature: a tall rotunda drum ringed with a band of lit windows
-- between ribs, and one big round dome with a lantern standing about ten storeys over the street, washed with light at
-- night.
--
-- What makes it itself: a smooth pale block under one big round dome.
-- Placement, sizes, heights and its budget: Config/CityArchetypes/domed_sanctuary.
-- Variants: palette (1 cream and copper-green, 2 white and silver, 3 sand and bronze), crown (1 a round drum under a
-- full dome, 2 a taller octagonal drum, a smaller dome and a long finial), rhythm (1 three tall windows a side, 2 four
-- narrower ones), mirror (the lower school wing's side, on a wide site).
--
-- Previewing (Studio helper): Preview.build("domed_sanctuary", { width = 82, depth = 53 }) for the full look (with the
-- school wing); width 58 is the smallest. Check: the dome sits on the drum with no gap and reads round from the
-- street, the dome dominating the block (about 95 studs to the finial); the portal's arch reads as an arch (the glass
-- half-disc over the glass, a stone ring round it); at night the wash lights the dome, the drum band, the portal (a
-- deep stained-glass colour, not a blown-out one) and side windows glow, the lantern is amber.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local City = require(ReplicatedStorage.Shared.Config.City)
local Kit = require(script.Parent.Parent.Parent.Kit)
local Types = require(script.Parent.Parent.Parent.Types)

local P = City.palettes
local KIT = City.kit
local rgb = Color3.fromRGB

-- The recipe, in studs.
local SHAPE = {
	sideInset = 2,
	forecourt = 9, -- the steps and the paving in front
	backInset = 1.5,
	baseMax = 76,
	annex = { min = 16, height = 24, bay = 5.5, floor = 11 }, -- the school wing, when the site is that much wider
	plinth = { height = 2.4, proud = 0.4 },
	cornice = { thick = 1.6, proud = 1.0, step = 0.8 },
	portal = { share = 0.34, min = 14, max = 24, top = 30, frame = 2.2, proud = 1.6 },
	tower = { width = 10, out = 2, over = 6, steps = 2, rise = 2, inset = 1.2 },
	windows = {
		byRhythm = {
			{ count = 3, width = 4.6 }, -- rhythm 1
			{ count = 4, width = 3.4 }, -- rhythm 2
		},
		sill = 6,
		head = 6, -- under the cornice
		edge = 5, -- from the front and back corners
	},
	drum = {
		byCrown = {
			{ share = 0.58, max = 44, height = 26 }, -- crown 1: a tall rotunda drum (the dome stands ten storeys high)
			{ share = 0.52, max = 38, height = 29 }, -- crown 2
		},
		band = { from = 6, to = 18 }, -- the rotunda's ring of tall windows
		-- Wide stucco piers round the band, so it reads as a ring of tall windows, not a glass belt.
		ribs = 12,
		rib = 5.2,
	},
	lantern = { diameter = 4, height = 4.5 },
	finial = { 3, 8 }, -- by crown
}

-- Walls, trim, the dome, the stained glass, the lantern's day colour, the wash.
local PALETTES = {
	-- `glass` is the side and drum windows: dark, tinted (Glass renders far brighter than its colour, so a mid blue
	-- reads as blue plastic by day). `stained` is the portal: a deep jewel tone that glows in its own colour at night.
	{
		wall = rgb(240, 228, 204),
		trim = rgb(216, 198, 164),
		dome = Kit.look(rgb(111, 158, 142), Enum.Material.SmoothPlastic),
		glass = rgb(40, 58, 76),
		stained = rgb(18, 36, 76),
		lantern = rgb(236, 214, 160),
		wash = rgb(255, 214, 170),
	},
	{
		wall = rgb(246, 244, 238),
		trim = rgb(214, 216, 214),
		dome = Kit.look(rgb(201, 205, 208), Enum.Material.Foil),
		glass = rgb(38, 56, 72),
		stained = rgb(14, 48, 66),
		lantern = rgb(226, 228, 230),
		wash = rgb(200, 220, 255),
	},
	{
		wall = rgb(236, 222, 196),
		trim = rgb(206, 186, 150),
		dome = Kit.look(rgb(160, 122, 72), Enum.Material.Metal),
		glass = rgb(52, 46, 66),
		stained = rgb(44, 24, 70),
		lantern = rgb(246, 220, 150),
		wash = rgb(255, 200, 150),
	},
}

local DARK = P.window.deep
local BRONZE = Kit.look(rgb(92, 72, 50), Enum.Material.Metal)

local function build(m: Types.Model)
	local site = m.site
	local variant = site.variant
	local pal = PALETTES[math.clamp(variant.palette, 1, #PALETTES)]
	local crown = math.clamp(variant.crown, 1, 2)
	local rhythm = math.clamp(variant.rhythm, 1, 2)
	local W, D, H = site.width, site.depth, site.height
	local hw, hd = W / 2, D / 2
	local wall = Kit.look(pal.wall, Enum.Material.SmoothPlastic)
	local trim = Kit.look(pal.trim, Enum.Material.SmoothPlastic)

	-------------------------------------------------------------------------------------------------------
	-- Layout: the block (and the school wing beside it on a wide site)
	-------------------------------------------------------------------------------------------------------
	local avail = W - 2 * SHAPE.sideInset
	local bw = math.min(avail, SHAPE.baseMax)
	local annexW = avail - bw
	if annexW < SHAPE.annex.min then
		annexW = 0
	end
	local left = -(bw + annexW) / 2
	local bx0, bx1 = left, left + bw
	local bcx = (bx0 + bx1) / 2
	local zF, zB = -hd + SHAPE.forecourt, hd - SHAPE.backInset
	local zc = (zF + zB) / 2 + 1.5

	-------------------------------------------------------------------------------------------------------
	-- The block: smooth walls on a plinth, a stepped cornice, tall arched windows down the sides
	-------------------------------------------------------------------------------------------------------
	Kit.box(m, "Block", Vector3.new(bx0, -KIT.bury, zF), Vector3.new(bx1, H - SHAPE.cornice.thick, zB), wall)
	local pl = SHAPE.plinth
	Kit.trim(
		m,
		"Plinth",
		Vector3.new(bx0 - pl.proud, -KIT.bury, zF - pl.proud),
		Vector3.new(bx1 + (if annexW > 0 then -0.05 else pl.proud), pl.height, zB - 0.3),
		trim
	)
	local co = SHAPE.cornice
	Kit.trim(
		m,
		"Cornice",
		Vector3.new(bx0 - co.proud, H - co.thick, zF - co.proud),
		Vector3.new(bx1 + co.proud, H, zB + 0.0),
		trim
	)
	Kit.trim(
		m,
		"CorniceStep",
		Vector3.new(bx0 - co.proud - co.step, H - co.thick - 0.7, zF - co.proud - co.step),
		Vector3.new(bx1 + co.proud + co.step, H - co.thick + 0.02, zF + 4),
		trim
	)
	local wn = SHAPE.windows
	local ws = wn.byRhythm[rhythm]
	local glassLook = Kit.glassLook(pal.glass, 0.15)
	local sides: { { x: number, out: number, face: Enum.NormalId } } =
		{ { x = bx0, out = -1, face = Enum.NormalId.Left } }
	if annexW == 0 then
		table.insert(sides, { x = bx1, out = 1, face = Enum.NormalId.Right })
	end
	local wTop = H - co.thick - wn.head
	local wSpring = wTop - ws.width / 2
	for i, side in sides do
		for k = 1, ws.count do
			local z = zF + wn.edge + (zB - zF - 2 * wn.edge) * (k - 0.5) / ws.count
			local xo = side.x + side.out * 0.08 -- the glass stands this far proud
			local xi = side.x - side.out * 0.3
			Kit.glass(
				m,
				`Window{i}{k}`,
				Vector3.new(math.min(xo, xi), wn.sill, z - ws.width / 2),
				Vector3.new(math.max(xo, xi), wSpring, z + ws.width / 2),
				pal.glass,
				{ lit = true, reflectance = 0.15 }
			)
			Kit.tube(
				m,
				`WindowArch{i}{k}`,
				Vector3.new(side.x + side.out * 0.05, wSpring, z),
				Vector3.new(side.x - side.out * 0.3, wSpring, z),
				ws.width,
				glassLook,
				"detail"
			)
		end
	end

	-------------------------------------------------------------------------------------------------------
	-- The portal: stained glass in a tall arch, a stone ring, bronze doors, steps
	-------------------------------------------------------------------------------------------------------
	local po = SHAPE.portal
	local tw = SHAPE.tower.width
	local pw = math.clamp(bw * po.share, po.min, po.max)
	pw = math.min(pw, bw - 2 * tw - 2 * po.frame - 8)
	local pTop = math.min(po.top, H - co.thick - 3)
	local spring = pTop - pw / 2
	local f0 = zF - po.proud -- the frame's face
	local fx = pw / 2 + po.frame
	Kit.box(m, "Frame", Vector3.new(bcx - fx, 0.2, f0), Vector3.new(bcx + fx, pTop + po.frame, zF + 0.3), trim)
	Kit.tube(
		m,
		"ArchRing",
		Vector3.new(bcx, spring, f0 - 0.3),
		Vector3.new(bcx, spring, f0 + 0.1),
		pw + 3,
		wall,
		"trim"
	)
	-- Stained glass: small leaded panes, glowing in its own colour at night.
	Kit.lit(
		Kit.glass(
			m,
			"Portal",
			Vector3.new(bcx - pw / 2, 0.9, f0 - 0.45),
			Vector3.new(bcx + pw / 2, spring, f0 + 0.1),
			pal.stained,
			{
				image = City.textures.windowBold,
				faces = { Enum.NormalId.Front },
				u = pw / 8,
				v = pw / 8,
				lines = pal.trim,
				reflectance = 0.05,
			}
		),
		"stained"
	)
	Kit.lit(
		Kit.tube(
			m,
			"PortalArch",
			Vector3.new(bcx, spring, f0 - 0.4),
			Vector3.new(bcx, spring, f0 + 0.1),
			pw,
			Kit.glassLook(pal.stained, 0.05),
			"detail"
		),
		"stained"
	)
	local dw = pw * 0.5
	Kit.box(m, "Doors", Vector3.new(bcx - dw / 2, 0.9, f0 - 0.6), Vector3.new(bcx + dw / 2, 9.5, f0 - 0.4), BRONZE)
	Kit.box(m, "Step1", Vector3.new(bcx - fx - 3, 0.2, f0 - 6), Vector3.new(bcx + fx + 3, 0.55, f0 - 0.3), trim)
	Kit.box(m, "Step2", Vector3.new(bcx - fx - 1.5, 0.55, f0 - 3.5), Vector3.new(bcx + fx + 1.5, 0.9, f0 - 0.3), trim)
	Kit.box(
		m,
		"Paving",
		Vector3.new(-hw + 0.3, 0, -hd + 0.3),
		Vector3.new(hw - 0.3, 0.2, zF + 0.5),
		Kit.look(P.deco.terrazzo, Enum.Material.SmoothPlastic)
	)
	for i, side in { -1, 1 } do
		local px = bcx + side * (fx + tw + 6)
		if math.abs(px - bcx) + 3 < bw / 2 + 2 then
			Kit.planter(
				m,
				`Planter{i}`,
				Vector3.new(px - 2.5, 0.2, zF - 5.5),
				Vector3.new(px + 2.5, 1.8, zF - 2.5),
				trim
			)
		end
	end

	-------------------------------------------------------------------------------------------------------
	-- The two towers flanking the portal: stepped tops, small domes, a slit window
	-------------------------------------------------------------------------------------------------------
	local to = SHAPE.tower
	for i, side in { -1, 1 } do
		local tx = bcx + side * (fx + tw / 2 + 0.5)
		local t0 = Vector3.new(tx - tw / 2, -KIT.bury, zF - to.out)
		local t1 = Vector3.new(tx + tw / 2, H + to.over, zF - to.out + tw)
		Kit.box(m, `Tower{i}`, t0, t1, wall)
		local steps: { { rise: number, inset: number } } = {}
		for _ = 1, to.steps do
			table.insert(steps, { rise = to.rise, inset = to.inset })
		end
		local _, top = Kit.setbacks(m, `TowerStep{i}`, t0, t1, steps, trim)
		local cap = tw - 2 * to.inset * to.steps - 0.6
		Kit.ball(m, `TowerDome{i}`, Vector3.new(tx, top, zF - to.out + tw / 2), cap, pal.dome, "trim")
		Kit.glass(
			m,
			`TowerSlit{i}`,
			Vector3.new(tx - 0.9, H - 10, zF - to.out - 0.08),
			Vector3.new(tx + 0.9, H + to.over - 3, zF - to.out + 0.3),
			DARK,
			{ reflectance = 0.15 }
		)
	end

	-------------------------------------------------------------------------------------------------------
	-- The drum, its window band between ribs, the dome, the lantern and the finial; the wash on the roof
	-------------------------------------------------------------------------------------------------------
	local dr = SHAPE.drum.byCrown[crown]
	local band = SHAPE.drum.band
	local dd = math.min(dr.max, bw * dr.share, (zB - zF) * 0.9)
	local dTop = H + dr.height
	local ribLook = trim
	if crown == 2 then
		Kit.octagon(m, "Drum", bcx, zc, H - 0.3, dTop, dd, wall)
		-- A lit window on each of the eight faces.
		for k = 0, 7 do
			local a = k * math.pi / 4
			local r = dd / 2 + 0.06
			local cf = CFrame.new(bcx + r * math.sin(a), H + (band.from + band.to + 2) / 2, zc - r * math.cos(a))
				* CFrame.Angles(0, -a, 0)
			Kit.lit(
				Kit.oriented(
					m,
					`DrumWindow{k + 1}`,
					"block",
					cf,
					Vector3.new(dd * 0.22, band.to + 2 - band.from, 0.3),
					Kit.glassLook(pal.glass, 0.15),
					"detail"
				),
				"window"
			)
		end
		Kit.octagon(m, "DrumCornice", bcx, zc, dTop - 0.6, dTop + 0.8, dd + 1.6, trim, "trim")
	else
		Kit.column(m, "Drum", bcx, zc, H - 0.3, dTop, dd, wall)
		Kit.lit(
			Kit.column(m, "DrumBand", bcx, zc, H + band.from, H + band.to, dd + 0.3, Kit.glassLook(pal.glass, 0.15)),
			"window"
		)
		for k = 0, SHAPE.drum.ribs - 1 do
			local a = k * 2 * math.pi / SHAPE.drum.ribs
			local r = dd / 2 + 0.3
			local cf = CFrame.new(bcx + r * math.sin(a), H + (band.from + band.to) / 2, zc - r * math.cos(a))
				* CFrame.Angles(0, -a, 0)
			Kit.oriented(
				m,
				`Rib{k + 1}`,
				"block",
				cf,
				Vector3.new(SHAPE.drum.rib, band.to - band.from + 2, 1.2),
				ribLook,
				"trim"
			)
		end
		Kit.disc(m, "DrumCornice", bcx, zc, dTop + 0.1, dd + 2, 1.4, trim)
	end
	local domeD = if crown == 2 then dd * 1.0 else dd * 1.04
	local domeY = dTop + 0.4
	Kit.ball(m, "Dome", Vector3.new(bcx, domeY, zc), domeD, pal.dome, "trim")
	local domeTop = domeY + domeD / 2
	local la = SHAPE.lantern
	local lTop = math.min(domeTop + la.height, site.maxHeight - 3)
	Kit.lit(
		Kit.column(
			m,
			"Lantern",
			bcx,
			zc,
			domeTop - 1,
			lTop,
			la.diameter,
			Kit.look(pal.lantern, Enum.Material.SmoothPlastic),
			"detail"
		),
		"neonAmber"
	)
	Kit.disc(m, "LanternCap", bcx, zc, lTop + 0.3, la.diameter + 1.2, 0.6, pal.dome, "detail")
	local finial = math.min(SHAPE.finial[crown], site.maxHeight - lTop - 1)
	if finial > 0.5 then
		Kit.column(m, "Finial", bcx, zc, lTop + 0.5, lTop + 0.5 + finial, 0.5, pal.dome, "detail")
	end
	Kit.wash(m, "Wash", bcx - dd * 0.3, bcx + dd * 0.3, zc - dd / 2 - 2.5, H + 0.05, pal.wash)

	-------------------------------------------------------------------------------------------------------
	-- The school wing beside the block on a wide site
	-------------------------------------------------------------------------------------------------------
	if annexW > 0 then
		local an = SHAPE.annex
		local ax0, ax1 = bx1, bx1 + annexW
		local az0 = zF + 6
		Kit.punched(
			m,
			"School",
			Vector3.new(ax0 - 0.5, -KIT.bury, az0),
			Vector3.new(ax1, an.height, zB),
			pal.wall,
			DARK,
			{ Enum.NormalId.Front, Enum.NormalId.Right, Enum.NormalId.Back },
			an.bay,
			an.floor
		)
		Kit.trim(
			m,
			"SchoolCornice",
			Vector3.new(ax0 + 0.1, an.height - 1, az0 - 0.8),
			Vector3.new(ax1 + 0.8, an.height + 0.05, zB + 0.6),
			trim
		)
	end
end

local archetype: Types.Archetype = { id = "domed_sanctuary", build = build }
return archetype
