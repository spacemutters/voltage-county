--!strict
-- T14 fin_column_tower (docs/city/ARCHETYPES.md §5, T14): a slim bayfront glass tower held at its four corners by
-- white blade fins. Each fin stands on the diagonal out of its corner like a yacht's keel, lands on the ground beside
-- the lobby and runs the full height past the roof. The front is split down the middle by a smooth blue glass spine
-- (the lift lobbies) standing proud of everything, with a stack of white balcony slabs either side whose ends
-- cascade in and out floor by floor toward the fins, so the corners look carved; the back has a slab every third
-- floor and the sides are plain, nearly mullion-free glass. Low glass amenity wings stand either side on a wide site,
-- a lap pool on one of them, umbrellas and planters on the other.
--
-- What makes it itself: four white blades on the diagonal running past the roof, a blue spine between two balcony
-- stacks.
-- Placement, sizes, heights and its budget: Config/CityArchetypes/fin_column_tower.
-- Variants: palette (3 fin, glass and spine sets: white on aqua with a blue spine, stone on silver with a teal one,
-- white on blue with a navy one), crown (1 the blades tied by an open white frame high over the roof; 2 the blades
-- raked off, highest at their tips, over a lit glass lantern; 3 short raked blades round a roof pool deck), rhythm
-- (the cascade: 1 a slow wave, 2 a quick one, 3 a diagonal: the stacks shift sideways floor by floor), mirror (the
-- cascade runs the other way; the pool wing swaps sides).
--
-- Studio pass 2026-10-26 (docs/images/city/fin_column_tower-*.jpg): the blades read as a white frame round the
-- glass, crown 1's frame open against the sky; the spine read as a bright racing stripe, so it is narrower, darker
-- and mirrors little sky (a dark seam now); the canopy got two posts. At night: four cool lines up the blade tips,
-- one lit run, the lobby, crown 2's lantern.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local City = require(ReplicatedStorage.Shared.Config.City)
local Kit = require(script.Parent.Parent.Parent.Kit)
local Types = require(script.Parent.Parent.Parent.Types)

local P = City.palettes
local KIT = City.kit
local rgb = Color3.fromRGB
local ROOT2 = math.sqrt(2)

-- The recipe, in studs.
local SHAPE = {
	floor = 12, -- a floor, nominal: fitted so the roof lands on the site's height
	lobby = 16, -- the glazed ground floor under the first slab
	minFloors = 14,
	front = 2.2, -- the blades' and spine's reach keeps this far behind the front line...
	back = 1.6, -- ...this far from the back line...
	side = 1.5, -- ...and from the sides
	coreShare = 0.52, -- the core's width as a share of the site's...
	coreWidth = { 40, 64 }, -- ...between these
	coreDepth = { 26, 40 },
	-- A blade: `thick` across, reaching `out` past its corner along the diagonal and `inn` back inside the glass.
	fin = { thick = 2.2, out = 7.5, inn = 3, strip = 0.6 },
	slab = { thick = 1.5, front = 5, back = 3.4, backEvery = 3 },
	spine = { share = 0.16, min = 7, max = 11, proud = 1, rise = 8, cap = 1.2, sheen = 0.06 },
	-- The cascade: how far a slab's end pulls in from its corner at most, and over how many floors (rhythm 3 steps in
	-- one way for `period` floors, then jumps back).
	cascade = { amp = 7, periods = { 10, 5, 6 } },
	roofEdge = { thick = 1.4, proud = 1 },
	crowns = { -- by crown: how far the blades rise past the roof (to the top of their rake), and their rake
		{ rise = 26, rake = 0 },
		{ rise = 26, rake = 12 },
		{ rise = 10, rake = 6 },
	},
	frame = { beam = 3, out = 3 }, -- crown 1: the ring's depth, and how far it stands off the glass
	lantern = { height = 11, inset = 3, roof = 1.4 }, -- crown 2
	wing = { gap = 2, low = 16, high = 12, cap = 1.4, capProud = 0.8, band = 1.2, min = 8 },
	canopy = { y = 11, thick = 1.2, post = 0.9 },
	paving = 0.35,
	signHeight = 2.4,
}

-- Blades and slabs, the core's glass and the spine's.
local PALETTES = {
	{ fin = P.frame.white, glass = P.glass.aqua, spine = rgb(30, 74, 112) },
	{ fin = rgb(217, 212, 200), glass = P.glass.silver, spine = rgb(28, 78, 92) },
	{ fin = P.frame.white, glass = P.glass.blue, spine = rgb(24, 50, 86) },
}

local RAIL = Kit.look(rgb(214, 236, 242), Enum.Material.Glass, 0.1, KIT.railTransparency)

local function build(m: Types.Model)
	local site = m.site
	local variant = site.variant
	local pal = PALETTES[math.clamp(variant.palette, 1, #PALETTES)]
	local rng = Kit.rng(m)
	local W, D, H = site.width, site.depth, site.height
	local hw, hd = W / 2, D / 2
	local crown = math.clamp(variant.crown, 1, #SHAPE.crowns)
	local cr = SHAPE.crowns[crown]
	local rhythm = math.clamp(variant.rhythm, 1, #SHAPE.cascade.periods)
	local G = SHAPE.lobby
	local fin = SHAPE.fin

	local white = Kit.look(pal.fin, Enum.Material.SmoothPlastic)
	local paving = Kit.look(P.deco.terrazzo, Enum.Material.SmoothPlastic)
	local lobbyGlass = rgb(44, 60, 70)

	-------------------------------------------------------------------------------------------------------
	-- The core: its blades reach (out + thick/2)/√2 past each corner both ways; deep sites keep the tower at the back
	-------------------------------------------------------------------------------------------------------
	local e = (fin.out + fin.thick / 2) / ROOT2
	local sp = SHAPE.spine
	local frontReach = math.max(e, SHAPE.slab.front + sp.proud)
	local backReach = math.max(e, SHAPE.slab.back)
	local tx = math.clamp(W * SHAPE.coreShare, SHAPE.coreWidth[1], SHAPE.coreWidth[2]) / 2
	tx = math.min(tx, hw - SHAPE.side - e)
	local room = D - SHAPE.front - SHAPE.back - frontReach - backReach
	local td = math.min(SHAPE.coreDepth[2], room)
	local zG1 = hd - SHAPE.back - backReach
	local zG0 = zG1 - td
	local zc = (zG0 + zG1) / 2

	local n = math.max(SHAPE.minFloors, math.round((H - G) / SHAPE.floor))
	local f = (H - G) / n
	local function slabY(k: number): number
		return G + (k - 1) * f
	end

	-------------------------------------------------------------------------------------------------------
	-- The ground: paving, the lobby, the entrance canopy and name, a wash
	-------------------------------------------------------------------------------------------------------
	Kit.box(m, "Paving", Vector3.new(-hw + 0.5, 0, -hd + 0.5), Vector3.new(hw - 0.5, SHAPE.paving, hd - 0.5), paving)
	local lobbyIn = 2.5
	Kit.glass(
		m,
		"Lobby",
		Vector3.new(-tx + lobbyIn, -KIT.bury, zG0 + lobbyIn),
		Vector3.new(tx - lobbyIn, G + 0.3, zG1 - lobbyIn),
		lobbyGlass,
		{
			image = City.textures.windowBold,
			faces = { Enum.NormalId.Front, Enum.NormalId.Left, Enum.NormalId.Right },
			u = 6,
			v = G,
			lines = pal.fin,
			lit = true,
		}
	)
	local sw = math.clamp(2 * tx * sp.share, sp.min, sp.max)
	local cw = sw / 2 + 4
	local canopyTop = SHAPE.canopy.y + SHAPE.canopy.thick
	-- The canopy reaches the front line, or 16 studs out over a deep site's drive.
	local cz0 = math.max(-hd + 0.8, zG0 - 16)
	Kit.canopy(m, "Canopy", -cw, cw, cz0, zG0 + lobbyIn + 0.4, SHAPE.canopy.y, SHAPE.canopy.thick, white)
	Kit.neonStrip(
		m,
		"CanopyLed",
		Vector3.new(-cw, SHAPE.canopy.y - 0.25, cz0 + 0.1),
		Vector3.new(cw, SHAPE.canopy.y - 0.05, cz0 + 0.7),
		"ledEdge",
		pal.fin
	)
	-- Two slim white posts carry its front corners.
	for i, sx in { -1, 1 } do
		Kit.column(
			m,
			`CanopyPost{i}`,
			sx * (cw - 1.2),
			cz0 + 1.2,
			-KIT.bury,
			SHAPE.canopy.y + 0.1,
			SHAPE.canopy.post,
			white
		)
	end
	local names = City.signNames.towers
	Kit.sign(
		m,
		"Name",
		Vector3.new(-cw * 0.8, canopyTop, cz0 + 0.2),
		Vector3.new(cw * 0.8, canopyTop + SHAPE.signHeight, cz0 + 0.6),
		Enum.NormalId.Front,
		names[rng:NextInteger(1, #names)],
		rgb(40, 44, 50),
		pal.fin,
		City.districtLooks.downtown.font
	)
	Kit.wash(m, "Wash", -tx + 3, tx - 3, zG0 + 1, SHAPE.paving, rgb(200, 220, 255))

	-- A deep site's forecourt: a reflecting pool either side of the drive.
	local forecourt = (zG0 - frontReach) - -hd
	if forecourt >= 24 then
		local pz0, pz1 = -hd + 6, zG0 - frontReach - 6
		local px0, px1 = cw + 3, math.min(tx + e, hw - 2)
		if px1 - px0 >= 6 then
			Kit.pool(m, "Basin", Vector3.new(px0, 0, pz0), Vector3.new(px1, 0, pz1), SHAPE.paving)
			Kit.planter(
				m,
				"BasinPlanter",
				Vector3.new(-px1, SHAPE.paving, pz0),
				Vector3.new(-px0, SHAPE.paving + 1.4, pz0 + 2.4),
				white
			)
		end
	end

	-------------------------------------------------------------------------------------------------------
	-- The core glass (floor lines only: nearly mullion-free) and one lit run on its front
	-------------------------------------------------------------------------------------------------------
	local lines = pal.glass:Lerp(pal.fin, 0.4)
	-- The core stops inside the roof's edge band, so its top is never coplanar with the band's.
	Kit.glass(m, "Core", Vector3.new(-tx, G + 0.2, zG0), Vector3.new(tx, H - 0.3, zG1), pal.glass, {
		image = City.textures.slabLine,
		u = 8,
		v = f,
		lines = lines,
	})
	if rng:NextNumber() < 0.7 then
		local k0 = rng:NextInteger(2, math.max(2, n - 9))
		local y0, y1 = slabY(k0) + SHAPE.slab.thick, slabY(math.min(n, k0 + 7))
		local skin = Kit.detail(
			m,
			"CoreLit",
			Vector3.new(-tx + 1, y0, zG0 - 0.18),
			Vector3.new(tx - 1, y1, zG0 - 0.06),
			Kit.glassLook(pal.glass)
		)
		skin.textures = {
			{
				face = Kit.face(m, Enum.NormalId.Front),
				image = City.textures.slabLine,
				u = 8,
				v = f,
				color = lines,
			},
		}
		Kit.lit(skin, "window")
	end

	-------------------------------------------------------------------------------------------------------
	-- The spine: smooth blue glass standing proud of the balconies, the full height and past the roof
	-------------------------------------------------------------------------------------------------------
	local spineFront = zG0 - SHAPE.slab.front - sp.proud
	local spineTop = H + sp.rise
	Kit.glass(
		m,
		"Spine",
		Vector3.new(-sw / 2, canopyTop + 0.1, spineFront),
		Vector3.new(sw / 2, spineTop, zG0 + 0.3),
		pal.spine,
		{ reflectance = sp.sheen }
	)
	Kit.trim(
		m,
		"SpineCap",
		Vector3.new(-sw / 2 - 0.5, spineTop, spineFront - 0.5),
		Vector3.new(sw / 2 + 0.5, spineTop + sp.cap, zG0 + 2.4),
		white
	)

	-------------------------------------------------------------------------------------------------------
	-- The balconies: a slab a floor across the front, its two ends cascading; a slab every third floor on the back
	-------------------------------------------------------------------------------------------------------
	local period = SHAPE.cascade.periods[rhythm]
	local amp = SHAPE.cascade.amp
	local function pull(k: number): number
		if rhythm == 3 then
			return ((k - 1) % period) / (period - 1)
		end
		return 0.5 - 0.5 * math.cos(2 * math.pi * (k - 1) / period)
	end
	local sl = SHAPE.slab
	for k = 1, n do
		local y0 = slabY(k)
		-- Rhythm 3 shifts the whole stack sideways (the ends move together); the waves pull the ends in out of step.
		local left = amp * pull(k)
		local right = if rhythm == 3 then amp - left else amp * pull(k + math.floor(period / 2))
		Kit.trim(
			m,
			`Slab{k}`,
			Vector3.new(-tx + left, y0, zG0 - sl.front),
			Vector3.new(tx - right, y0 + sl.thick, zG0 + 0.3),
			white
		)
		if k % sl.backEvery == 2 then
			Kit.trim(
				m,
				`Back{k}`,
				Vector3.new(-tx + 0.5, y0, zG1 - 0.3),
				Vector3.new(tx - 0.5, y0 + sl.thick, zG1 + sl.back),
				white
			)
		end
	end
	-- The roof's edge: a crisp white band round the top.
	local re = SHAPE.roofEdge
	Kit.trim(
		m,
		"RoofEdge",
		Vector3.new(-tx - re.proud, H - re.thick, zG0 - re.proud),
		Vector3.new(tx + re.proud, H, zG1 + re.proud),
		white
	)

	-------------------------------------------------------------------------------------------------------
	-- The blades: one on the diagonal out of each corner, from the ground past the roof, a cool line up its tip
	-------------------------------------------------------------------------------------------------------
	local finTop = H + cr.rise - cr.rake
	local length = fin.out + fin.inn
	for i, corner in { { -1, -1 }, { 1, -1 }, { -1, 1 }, { 1, 1 } } do
		local sx, sz = corner[1], corner[2]
		local dir = Vector3.new(sx, 0, sz) / ROOT2
		local cornerAt = Vector3.new(sx * tx, 0, if sz < 0 then zG0 else zG1)
		local mid = cornerAt + dir * ((fin.out - fin.inn) / 2)
		local yaw = math.atan2(sx, sz)
		local turn = CFrame.Angles(0, yaw, 0)
		local y0 = -KIT.bury
		Kit.oriented(
			m,
			`Fin{i}`,
			"block",
			CFrame.new(mid.X, (y0 + finTop) / 2, mid.Z) * turn,
			Vector3.new(fin.thick, finTop - y0, length),
			white,
			"box"
		)
		if cr.rake > 0 then
			-- The rake: a wedge on the blade's top, highest at its tip.
			Kit.oriented(
				m,
				`Rake{i}`,
				"wedge",
				CFrame.new(mid.X, finTop + cr.rake / 2, mid.Z) * turn,
				Vector3.new(fin.thick, cr.rake, length),
				white,
				"trim"
			)
		end
		-- The line runs up the tip from a little over the paving to the very top (the rake's upright face is the tip).
		local tip = cornerAt + dir * (fin.out + 0.05)
		local lineLo, lineHi = SHAPE.paving + 2, finTop + cr.rake
		local strip = Kit.oriented(
			m,
			`FinLine{i}`,
			"block",
			CFrame.new(tip.X, (lineLo + lineHi) / 2, tip.Z) * turn,
			Vector3.new(fin.strip, lineHi - lineLo, 0.3),
			white,
			"detail"
		)
		Kit.lit(strip, "crown")
	end

	-------------------------------------------------------------------------------------------------------
	-- The crown
	-------------------------------------------------------------------------------------------------------
	if crown == 1 then
		-- An open white frame high over the roof, tying the four blades: the sky shows through under it.
		local fr = SHAPE.frame
		local y0, y1 = finTop - fr.beam, finTop
		local ox = tx + fr.out
		local z0, z1 = zG0 - fr.out, zG1 + fr.out
		Kit.trim(m, "FrameFront", Vector3.new(-ox, y0, z0 - 1.1), Vector3.new(ox, y1, z0 + 1.1), white)
		Kit.trim(m, "FrameBack", Vector3.new(-ox, y0, z1 - 1.1), Vector3.new(ox, y1, z1 + 1.1), white)
		for i, sx in { -1, 1 } do
			Kit.trim(
				m,
				`FrameSide{i}`,
				Vector3.new(sx * ox - 1.1, y0 + 0.02, z0 + 1.1),
				Vector3.new(sx * ox + 1.1, y1 - 0.02, z1 - 1.1),
				white
			)
		end
		Kit.neonStrip(
			m,
			"FrameLine",
			Vector3.new(-ox + 1.2, y0 - 0.4, z0 - 0.9),
			Vector3.new(ox - 1.2, y0 - 0.05, z0 + 0.9),
			"crown",
			pal.fin
		)
		Kit.roofBox(
			m,
			"Plant",
			Vector3.new(sw / 2 + 2, H, zc - td * 0.25),
			Vector3.new(tx * 0.7, H + 7, zc + td * 0.3),
			white
		)
	elseif crown == 2 then
		-- A glass lantern set in on the roof under a white lid, glowing at night, a cool line under the lid.
		local la = SHAPE.lantern
		local lx, lz0, lz1 = tx - la.inset, zG0 + la.inset, zG1 - la.inset
		local top = H + la.height
		Kit.glass(m, "Lantern", Vector3.new(-lx, H - 0.2, lz0), Vector3.new(lx, top, lz1), pal.glass, {
			image = City.textures.windowFine,
			u = 4,
			v = la.height,
			lines = lines,
			lit = true,
		})
		Kit.trim(
			m,
			"LanternLid",
			Vector3.new(-lx - 1.5, top, lz0 - 1.5),
			Vector3.new(lx + 1.5, top + la.roof, lz1 + 1.5),
			white
		)
		Kit.neonStrip(
			m,
			"LanternLine",
			Vector3.new(-lx - 1.35, top - 0.4, lz0 - 1.35),
			Vector3.new(lx + 1.35, top - 0.05, lz1 + 1.35),
			"crown",
			pal.fin
		)
	else
		-- A pool deck: a glass rail along the front, the pool, a white pergola beside the spine's top.
		Kit.detail(
			m,
			"RoofRail",
			Vector3.new(-tx - re.proud + 0.2, H, zG0 - re.proud + 0.2),
			Vector3.new(tx + re.proud - 0.2, H + KIT.railHeight, zG0 - re.proud + 0.5),
			RAIL
		)
		Kit.pool(m, "SkyPool", Vector3.new(-tx + 3, 0, zG0 + 4), Vector3.new(-sw / 2 - 3, 0, zG1 - 4), H)
		local gx0, gx1 = sw / 2 + 4, tx - 3
		if gx1 - gx0 >= 4 then
			Kit.column(m, "PergolaPost1", gx0, zc + 4, H, H + 8, 0.8, white, "trim")
			Kit.column(m, "PergolaPost2", gx1, zc + 4, H, H + 8, 0.8, white, "trim")
			Kit.trim(m, "Pergola", Vector3.new(gx0 - 1, H + 8, zc - 3), Vector3.new(gx1 + 1, H + 8.8, zc + 6), white)
		end
		Kit.neonStrip(
			m,
			"RoofLine",
			Vector3.new(-tx - re.proud, H - re.thick + 0.4, zG0 - re.proud - 0.15),
			Vector3.new(tx + re.proud, H - re.thick + 0.9, zG0 - re.proud - 0.05),
			"crown",
			pal.fin
		)
	end

	-------------------------------------------------------------------------------------------------------
	-- The wings: low glass amenity blocks either side of a wide site's tower, a lap pool on one, umbrellas on the other
	-------------------------------------------------------------------------------------------------------
	local wg = SHAPE.wing
	local wx0, wx1 = tx + e + wg.gap, hw - SHAPE.side
	if wx1 - wx0 >= wg.min then
		local wz0, wz1 = -hd + 3, hd - SHAPE.back
		local top = wg.low + wg.high
		local deck = top + wg.cap
		for i, sx in { -1, 1 } do
			local a, b = sx * wx0, sx * wx1
			local x0, x1 = math.min(a, b), math.max(a, b)
			local outer = if sx < 0 then Enum.NormalId.Left else Enum.NormalId.Right
			Kit.glass(m, `Wing{i}`, Vector3.new(x0, -KIT.bury, wz0), Vector3.new(x1, top, wz1), lobbyGlass, {
				image = City.textures.windowBold,
				faces = { Enum.NormalId.Front, outer, Enum.NormalId.Back },
				u = 6,
				v = wg.high,
				lines = pal.fin,
			})
			local cp = wg.capProud
			Kit.trim(
				m,
				`WingBand{i}`,
				Vector3.new(x0 - 0.5, wg.low - wg.band / 2, wz0 - 0.5),
				Vector3.new(x1 + 0.5, wg.low + wg.band / 2, wz1 + 0.5),
				white
			)
			Kit.trim(m, `WingCap{i}`, Vector3.new(x0 - cp, top, wz0 - cp), Vector3.new(x1 + cp, deck, wz1 + cp), white)
			local ww = x1 - x0
			if sx > 0 then
				-- The lap pool runs along the wing, umbrellas beside it on a wide one.
				local pw = math.min(8, ww - 6)
				if pw >= 4 then
					local pxa = x0 + 3
					Kit.pool(m, "LapPool", Vector3.new(pxa, 0, wz0 + 4), Vector3.new(pxa + pw, 0, wz1 - 4), deck)
					if ww - pw - 6 >= 7 then
						local ux = (pxa + pw + x1) / 2
						Kit.umbrella(m, "PoolUmbrella", ux, wz0 + 8, deck, 6, P.deco.aqua, true)
					end
				end
			else
				-- Market umbrellas and planters on the other wing's deck.
				local ux = (x0 + x1) / 2
				local us = math.min(6, ww - 2)
				Kit.umbrella(m, "DeckUmbrella1", ux, wz0 + 6, deck, us, pal.fin, true)
				Kit.umbrella(m, "DeckUmbrella2", ux, wz0 + 6 + us + 3, deck, us, P.deco.aqua, true)
				Kit.planter(
					m,
					"DeckPlanter",
					Vector3.new(x0 + 1, deck, wz1 - 6),
					Vector3.new(x1 - 1, deck + 1.4, wz1 - 3.6),
					white
				)
			end
		end
	end
end

local archetype: Types.Archetype = { id = "fin_column_tower", build = build }
return archetype
