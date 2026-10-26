--!strict
-- R01 mediterranean_villa (docs/city/ARCHETYPES.md §7, R01): the suburbs' Mediterranean Revival villa, a cluster of
-- stucco volumes under low red barrel tiles. A two-storey main block under a side-gabled tile roof (stucco gable ends,
-- only a thin tile edge on the rakes, a moulded cornice under the front eave); a front-facing gabled bay pushed out
-- toward the street with a tall round-arched window in a cast-stone surround, an iron Juliet balcony over it and a
-- clay vent in its gable; beside it a recessed arcade of two or three arches (haunched heads, a tiled terrace, lit
-- French doors at the back) under a balcony with a stepped edge, iron rail and arched door; a square stair tower at
-- the block's corner rising past the roof under a tile pyramid, the front door in a stone surround at its foot with a
-- lantern; a one-storey garage wing with a tile visor (or a garden wall with an arched carriage gate). A Spanish
-- chimney with a little tile roof, a low garden wall with a hedge, a bougainvillea and a reflecting fountain.
--
-- What makes it itself: light stucco under low red barrel-tile roofs, an arched loggia and a square stair tower.
-- Placement, sizes, heights and its budget: Config/CityArchetypes/mediterranean_villa.
-- Variants: palette (4 sets of wall, tile, shutters and stone: white, cream, rose, ochre), crown (1 a tower with one
-- arched window, 2 a taller tower with a mirador of twin arches over a sill course and a ball finial), rhythm (1 the
-- garage wing, 2 a garden wall with an arched carriage gate), mirror (tower and drive left or right). The arcade has
-- three arches on the widest sites, two on the rest.
--
-- Previewing: from the street at eye height and from the drive's corner, on a 36 and a 47 site. Check the bay's gable
-- roof meets the main roof's front slope in a clean valley (its ridge must sink into the main roof before the main
-- ridge: no stucco triangle showing behind), the arcade's haunches read as arches at 70 mph (widen SHAPE.haunch if
-- not), the balcony rail and the Juliet rail show (punched Texture on invisible parts), the tower window clears the
-- main roof, the fountain's water shows over its rim. At night: the arched bay window, the loggia doors, the balcony
-- door and the tower window glow, and the lantern is warm.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local City = require(ReplicatedStorage.Shared.Config.City)
local Kit = require(script.Parent.Parent.Parent.Kit)
local Types = require(script.Parent.Parent.Parent.Types)

local P = City.palettes
local KIT = City.kit
local rgb = Color3.fromRGB

-- The recipe, in studs.
local SHAPE = {
	side = 1.8, -- the walls from the site's sides
	yard = { 0.25, 9, 13 }, -- the front garden, to the bay's face: share of the depth, clamped
	mainDepth = { 0.38, 16, 20 }, -- the main block behind the loggia
	mainMax = 28,
	wing = { 10.5, 15 }, -- the width beside the main block (the tower's outer half and the wing)
	rise = { 0.2, 3.6, 5.4 }, -- the main roof's rise: share of the height, clamped (a low Mediterranean pitch)
	overhang = 1.6,
	roofThick = 0.6,
	cornice = { thick = 0.8, proud = 0.7 },
	bay = { 0.33, 7.5, 9 }, -- the front bay's width: share of the main block, clamped
	bayIn = 2.2, -- from the main block's far end, so its eaves stay over the main walls
	bayOut = 3, -- how far it stands out past the arcade
	bayPitch = 0.6,
	loggia = 6, -- the arcade's depth to the French doors
	arcadeWall = 1.4,
	pier = 1.3,
	haunch = 0.4, -- an arch's haunches: share of its opening
	crownDrop = 1.1, -- the arches' crowns under the upper floor
	terrace = 0.6,
	tower = 7,
	towerOut = 1.8, -- its front past the arcade (clear of the main roof's eave)
	towerRise = { 3.5, 5.5 }, -- over the ridge, by crown
	capRise = { 2.6, 3.2 },
	balcony = { proud = 2.2, thick = 0.5, max = 6.5 },
	wingBack = 1.5, -- the wing's front behind the arcade
	wingDepth = { 0.32, 14, 17 },
	wingTop = 11,
	gate = 8, -- rhythm 2: the garden wall's height
	gateHaunch = 2.4,
	chimney = 1.8, -- over the ridge
	stairWindow = { width = 1.5, from = 1.4, tall = 2.6 }, -- the tower's stair light, over the upper floor
	garden = { wall = 1.9, hedge = 4.1 }, -- the garden wall's top and the hedge's over it
}

-- Wall, tile, shutters and cast stone. Pushed a little past the paint chips so the sky light doesn't grey them.
local PALETTES = {
	{ wall = rgb(246, 241, 230), tile = rgb(184, 86, 56), shutter = rgb(52, 104, 78), stone = rgb(226, 214, 190) },
	{ wall = rgb(242, 222, 182), tile = rgb(196, 104, 62), shutter = rgb(40, 84, 112), stone = rgb(250, 244, 228) },
	{ wall = rgb(240, 186, 168), tile = rgb(170, 78, 52), shutter = rgb(54, 96, 76), stone = rgb(248, 236, 222) },
	{ wall = rgb(230, 186, 118), tile = rgb(176, 90, 56), shutter = rgb(98, 64, 42), stone = rgb(246, 234, 206) },
}

local IRON = rgb(38, 38, 40)
local WOOD = rgb(108, 70, 44)
local PAVER = rgb(212, 186, 152)
local TERRACOTTA = rgb(184, 104, 74)
local HEDGE = rgb(86, 138, 64) -- (54, 102, 52) read as a black box in the game's light
local BLOOM = rgb(214, 48, 136) -- bougainvillea
local LANTERN = rgb(255, 214, 160)
local VENT = rgb(120, 58, 40)

local function share(x: number, rule: { number }): number
	return math.clamp(x * rule[1], rule[2], rule[3])
end

local function build(m: Types.Model)
	local site = m.site
	local variant = site.variant
	local pal = PALETTES[math.clamp(variant.palette, 1, #PALETTES)]
	local crown = math.clamp(variant.crown, 1, 2)
	local rng = Kit.rng(m)
	local W, D, H = site.width, site.depth, site.height
	local hw, hd = W / 2, D / 2

	local wall = Kit.look(pal.wall, Enum.Material.Plaster)
	local stone = Kit.look(pal.stone, Enum.Material.SmoothPlastic)
	local tile = Kit.look(pal.tile, Enum.Material.ClayRoofTiles)
	local shutter = Kit.look(pal.shutter, Enum.Material.SmoothPlastic)
	local wood = Kit.look(WOOD, Enum.Material.WoodPlanks)
	local front = { Enum.NormalId.Front }
	local window = function(lit: boolean): Kit.GlassOptions
		return { image = City.textures.windowBold, faces = front, u = 1.2, lines = pal.stone, lit = lit }
	end

	-------------------------------------------------------------------------------------------------------
	-- The plan, drawn with the tower and the drive on the right (the kit mirrors it)
	-------------------------------------------------------------------------------------------------------
	local X0, X1 = -hw + SHAPE.side, hw - SHAPE.side
	local avail = X1 - X0
	local Ww = math.clamp(avail - 22, SHAPE.wing[1], SHAPE.wing[2])
	local Wm = math.min(SHAPE.mainMax, avail - Ww)
	local mx0, mx1 = X0, X0 + Wm
	local zF = -hd + share(D, SHAPE.yard) -- the bay's face
	local zA = zF + SHAPE.bayOut -- the arcade's face (and the main roof's front wall line)
	local zL = zA + SHAPE.loggia -- the loggia's back wall
	local zM = zL + share(D, SHAPE.mainDepth)
	local zc = (zA + zM) / 2 -- the main ridge
	local rise = share(H, SHAPE.rise)
	local E = H - rise -- the top of the walls
	local G = E / 2 -- the upper floor
	local yc = G - SHAPE.crownDrop -- the arches' crowns

	-------------------------------------------------------------------------------------------------------
	-- The main block under its side-gabled roof
	-------------------------------------------------------------------------------------------------------
	-- The walls stop exactly at the roof's foot (its gable wedges sit on them), so no slit shows under the eaves.
	Kit.box(m, "Main", Vector3.new(mx0, -KIT.bury, zL), Vector3.new(mx1, E, zM), wall)
	Kit.box(m, "Upper", Vector3.new(mx0, yc, zA), Vector3.new(mx1, E, zL + 0.1), wall)
	Kit.gableRoof(
		m,
		"Roof",
		Vector3.new(mx0, E, zA),
		Vector3.new(mx1, H, zM),
		"x",
		SHAPE.overhang,
		SHAPE.roofThick,
		tile,
		wall
	)
	local cp = SHAPE.cornice.proud
	Kit.trim(
		m,
		"Cornice",
		Vector3.new(mx0 + 0.02, E - SHAPE.cornice.thick, zA - cp),
		Vector3.new(mx1, E - 0.02, zA + 0.5),
		stone
	)

	-------------------------------------------------------------------------------------------------------
	-- The front bay: a gabled two-storey block out toward the street, an arched window in a cast-stone surround,
	-- a Juliet balcony over it, a clay vent in the gable
	-------------------------------------------------------------------------------------------------------
	local Bw = share(Wm, SHAPE.bay)
	local bx0 = mx0 + SHAPE.bayIn
	local bx1 = bx0 + Bw
	local bc = (bx0 + bx1) / 2
	if bx0 - mx0 > 0.05 then
		-- The ground floor's end, between the main block's end and the bay.
		Kit.box(m, "End", Vector3.new(mx0, -KIT.bury, zA), Vector3.new(bx0, yc + 0.02, zL + 0.1), wall)
	end
	Kit.box(m, "Bay", Vector3.new(bx0, -KIT.bury, zF), Vector3.new(bx1, E, zL + 0.2), wall)
	-- Its roof's ridge sinks into the main roof's front slope well before the main ridge (Hb under H - rise / 2).
	local riseB = math.clamp(Bw / 2 * SHAPE.bayPitch, 2, rise - 1.2)
	local Hb = E + 0.5 + riseB
	Kit.gableRoof(m, "BayRoof", Vector3.new(bx0, E, zF), Vector3.new(bx1, Hb, zc), "z", 0.9, 0.5, tile, wall)
	Kit.tube(
		m,
		"BayVent",
		Vector3.new(bc, E + riseB * 0.42, zF - 0.15),
		Vector3.new(bc, E + riseB * 0.42, zF + 0.2),
		math.min(1.3, riseB * 0.5),
		Kit.look(VENT, Enum.Material.SmoothPlastic),
		"detail"
	)
	Kit.trim(
		m,
		"BayBand",
		Vector3.new(bx0 - 0.3, E - 0.55, zF - 0.4),
		Vector3.new(bx1 + 0.3, E - 0.02, zF + 0.6),
		stone
	)
	-- The arched window: a round-headed cast-stone surround with the glass on its face, a sill under it.
	local gw = math.min(Bw - 3.2, 5)
	local spring = math.max(1.6 + gw / 2 + 1.2, G - 1.5 - gw / 2)
	Kit.trim(
		m,
		"BaySurround",
		Vector3.new(bc - gw / 2 - 0.55, 1.2, zF - 0.25),
		Vector3.new(bc + gw / 2 + 0.55, spring, zF + 0.3),
		stone
	)
	Kit.tube(
		m,
		"BaySurroundHead",
		Vector3.new(bc, spring, zF - 0.23),
		Vector3.new(bc, spring, zF + 0.3),
		gw + 1.1,
		stone,
		"trim"
	)
	Kit.archWindow(m, "BayWindow", bc - gw / 2, bc + gw / 2, 1.6, spring, zF - 0.25, P.window.dark, {
		image = City.textures.windowBold,
		faces = front,
		u = gw / 3,
		v = (spring - 1.6) * 1.6 + 2,
		lines = pal.stone,
		lit = true,
	})
	Kit.trim(
		m,
		"BaySill",
		Vector3.new(bc - gw / 2 - 0.85, 0.95, zF - 0.75),
		Vector3.new(bc + gw / 2 + 0.85, 1.25, zF + 0.3),
		stone
	)
	-- The upper window: shutters open either side, a Juliet balcony at its foot.
	local uw = 2.4
	local uy0 = G + 0.9
	local uy1 = math.min(E - 1.4, uy0 + 5.4)
	local board =
		Kit.detail(m, "BayShutters", Vector3.new(bc - uw, uy0, zF - 0.12), Vector3.new(bc + uw, uy1, zF + 0.1), shutter)
	board.textures = {
		{
			face = Enum.NormalId.Front,
			image = City.textures.slabLine,
			u = 2 * uw,
			v = 0.45,
			color = pal.shutter:Lerp(Color3.new(0, 0, 0), 0.35),
		},
	}
	Kit.glass(
		m,
		"BayUpper",
		Vector3.new(bc - uw / 2, uy0, zF - 0.25),
		Vector3.new(bc + uw / 2, uy1, zF + 0.1),
		P.window.dark,
		window(rng:NextNumber() < 0.6)
	)
	Kit.trim(m, "Juliet", Vector3.new(bc - 1.9, uy0 - 0.45, zF - 1.2), Vector3.new(bc + 1.9, uy0, zF + 0.3), stone)
	Kit.railing(
		m,
		"JulietRail",
		Vector3.new(bc - 1.75, uy0, zF - 1.05),
		Vector3.new(bc + 1.75, uy0 + 2.6, zF - 0.3),
		{ Enum.NormalId.Front, Enum.NormalId.Left, Enum.NormalId.Right },
		IRON
	)

	-------------------------------------------------------------------------------------------------------
	-- The arcade between the bay and the tower: haunched arches on piers, a tiled terrace, lit French doors
	-------------------------------------------------------------------------------------------------------
	local tw = SHAPE.tower
	local tx0, tx1 = mx1 - tw / 2, mx1 + tw / 2
	local lx0, lx1 = bx1, tx0
	local S = lx1 - lx0
	local n = if S >= 12.5 then 3 elseif S >= 6.5 then 2 else 1
	local pier = SHAPE.pier
	local w = (S - (n - 1) * pier) / n
	for k = 1, n - 1 do
		local x0 = lx0 + k * w + (k - 1) * pier
		Kit.box(
			m,
			`Pier{k}`,
			Vector3.new(x0, -KIT.bury, zA - 0.2),
			Vector3.new(x0 + pier, yc + 0.02, zA + SHAPE.arcadeWall),
			wall
		)
	end
	for b = 1, n do
		local x0 = lx0 + (b - 1) * (w + pier)
		Kit.archHead(m, `Arch{b}`, x0, x0 + w, yc, zA, zA + SHAPE.arcadeWall, SHAPE.haunch * w, wall)
	end
	Kit.box(
		m,
		"Terrace",
		Vector3.new(lx0, -KIT.bury, zA - 1.4),
		Vector3.new(lx1, SHAPE.terrace, zL + 0.2),
		Kit.look(TERRACOTTA, Enum.Material.CeramicTiles)
	)
	Kit.glass(
		m,
		"Doors",
		Vector3.new(lx0 + 0.6, SHAPE.terrace, zL - 0.2),
		Vector3.new(lx1 - 0.6, yc - 1.2, zL + 0.15),
		P.window.dark,
		{
			image = City.textures.windowBold,
			faces = front,
			u = 1.6,
			v = (yc - 1.2 - SHAPE.terrace) * 1.6 + 2,
			lines = pal.stone,
			lit = true,
		}
	)

	-- The balcony over the arcade: a stepped edge, an iron rail, an arched door.
	local cx = (lx0 + lx1) / 2
	local bwid = math.min(S - 1.2, SHAPE.balcony.max)
	local bp = SHAPE.balcony.proud
	Kit.trim(
		m,
		"Balcony",
		Vector3.new(cx - bwid / 2, G - SHAPE.balcony.thick, zA - bp),
		Vector3.new(cx + bwid / 2, G + 0.12, zA + 0.4),
		stone
	)
	Kit.trim(
		m,
		"BalconyBed",
		Vector3.new(cx - bwid / 2 + 0.4, G - SHAPE.balcony.thick - 0.35, zA - bp + 0.5),
		Vector3.new(cx + bwid / 2 - 0.4, G - SHAPE.balcony.thick + 0.02, zA + 0.4),
		stone
	)
	Kit.railing(
		m,
		"BalconyRail",
		Vector3.new(cx - bwid / 2 + 0.15, G + 0.12, zA - bp + 0.15),
		Vector3.new(cx + bwid / 2 - 0.15, G + 3, zA - 0.06),
		{ Enum.NormalId.Front, Enum.NormalId.Left, Enum.NormalId.Right },
		IRON
	)
	local dw = math.clamp(bwid - 2.6, 2.4, 3.6)
	local dSpring = math.min(E - 1.5 - dw / 2, G + 6.2)
	Kit.archWindow(m, "BalconyDoor", cx - dw / 2, cx + dw / 2, G + 0.12, dSpring, zA + 0.15, P.window.dark, {
		image = City.textures.windowBold,
		faces = front,
		u = dw / 2,
		v = (dSpring - G) * 1.6 + 2,
		lines = pal.stone,
	})

	-------------------------------------------------------------------------------------------------------
	-- The stair tower at the main block's corner, past the roof under a tile pyramid; the front door at its foot
	-------------------------------------------------------------------------------------------------------
	local tz0 = zA - SHAPE.towerOut
	local tz1 = tz0 + tw
	local T = H + SHAPE.towerRise[crown]
	local capRise = SHAPE.capRise[crown]
	Kit.box(m, "Tower", Vector3.new(tx0, -KIT.bury, tz0), Vector3.new(tx1, T - 0.03, tz1), wall)
	Kit.trim(
		m,
		"TowerCornice",
		Vector3.new(tx0 - 0.5, T - 0.75, tz0 - 0.5),
		Vector3.new(tx1 + 0.5, T, tz1 + 0.5),
		stone
	)
	Kit.hipRoof(m, "TowerCap", Vector3.new(tx0, T, tz0), Vector3.new(tx1, T + capRise, tz1), 0.9, 0.45, tile)
	local mirador = crown == 2
	local ww = if mirador then 1.7 else 2.1
	for i, dx in (if mirador then { -1.4, 1.4 } else { 0 }) :: { number } do
		Kit.archWindow(
			m,
			`TowerWindow{i}`,
			mx1 + dx - ww / 2,
			mx1 + dx + ww / 2,
			T - 5.4,
			T - 1.8 - ww / 2,
			tz0,
			P.window.dark,
			{ lit = i == 1 }
		)
	end
	-- The stair's light halfway up: a slim round-headed window, so the tower's face isn't a blank shaft.
	local sw = SHAPE.stairWindow
	Kit.archWindow(
		m,
		"StairWindow",
		mx1 - sw.width / 2,
		mx1 + sw.width / 2,
		G + sw.from,
		G + sw.from + sw.tall,
		tz0,
		P.window.dark,
		{ image = City.textures.windowBold, faces = front, u = sw.width, v = sw.tall * 1.6 + 2, lines = pal.stone }
	)
	if mirador then
		Kit.trim(
			m,
			"TowerSill",
			Vector3.new(tx0 - 0.3, T - 6.0, tz0 - 0.3),
			Vector3.new(tx1 + 0.3, T - 5.45, tz1 + 0.3),
			stone
		)
		Kit.ball(m, "Finial", Vector3.new(mx1, T + capRise + 0.35, (tz0 + tz1) / 2), 0.9, stone, "trim")
	end
	-- The front door: round-headed wood in a cast-stone surround, a lantern beside it.
	local doorSpring = 5.6
	Kit.trim(
		m,
		"DoorSurround",
		Vector3.new(mx1 - 2.05, 0, tz0 - 0.2),
		Vector3.new(mx1 + 2.05, doorSpring + 2.3, tz0 + 0.3),
		stone
	)
	Kit.trim(m, "Door", Vector3.new(mx1 - 1.3, 0, tz0 - 0.4), Vector3.new(mx1 + 1.3, doorSpring, tz0 + 0.1), wood)
	Kit.tube(
		m,
		"DoorHead",
		Vector3.new(mx1, doorSpring, tz0 - 0.38),
		Vector3.new(mx1, doorSpring, tz0 + 0.1),
		2.6,
		wood,
		"trim"
	)
	local lantern = Kit.detail(
		m,
		"Lantern",
		Vector3.new(mx1 + 2.45, 6.2, tz0 - 0.9),
		Vector3.new(mx1 + 3.05, 7.4, tz0 + 0.05),
		Kit.look(LANTERN, Enum.Material.SmoothPlastic)
	)
	Kit.lit(lantern, "neonAmber") -- warm: a pale kind turns white-hot Neon

	-------------------------------------------------------------------------------------------------------
	-- Beside the tower: the garage wing (rhythm 1) or a garden wall with an arched carriage gate (rhythm 2)
	-------------------------------------------------------------------------------------------------------
	local zW = zA + SHAPE.wingBack
	local gx0, gx1 = tx1 + 0.7, X1 - 0.7 -- the garage door or the gate
	if variant.rhythm ~= 2 then
		local zWB = math.min(zW + share(D, SHAPE.wingDepth), hd - 1.5)
		local top = SHAPE.wingTop
		Kit.box(m, "Wing", Vector3.new(tx1 - 0.2, -KIT.bury, zW), Vector3.new(X1, top, zWB), wall)
		-- A short tile visor along the parapet, the Spanish way of roofing a flat wing.
		Kit.wedge(
			m,
			"WingVisor",
			Vector3.new(tx1 + 0.05, top - 1.7, zW - 1.4),
			Vector3.new(X1 + 0.6, top + 0.3, zW + 1.2),
			"back",
			tile
		)
		local garage = Kit.trim(m, "GarageDoor", Vector3.new(gx0, 0, zW - 0.15), Vector3.new(gx1, 8.2, zW + 0.1), wood)
		garage.textures = {
			{
				face = Enum.NormalId.Front,
				image = City.textures.slabLine,
				u = gx1 - gx0,
				v = 1.4,
				color = WOOD:Lerp(Color3.new(0, 0, 0), 0.4),
			},
		}
	else
		local top = SHAPE.gate
		local crownY = top - 1.2
		local thick = 1.2
		Kit.box(m, "GateWallL", Vector3.new(tx1 - 0.1, -KIT.bury, zW), Vector3.new(gx0, top, zW + thick), wall)
		Kit.box(m, "GateWallR", Vector3.new(gx1, -KIT.bury, zW), Vector3.new(X1, top, zW + thick), wall)
		Kit.box(m, "GateLintel", Vector3.new(gx0, crownY, zW), Vector3.new(gx1, top - 0.02, zW + thick), wall)
		Kit.archHead(m, "GateArch", gx0, gx1, crownY, zW, zW + thick, SHAPE.gateHaunch, wall)
		Kit.railing(
			m,
			"Gate",
			Vector3.new(gx0 + 0.05, 0, zW + 0.5),
			Vector3.new(gx1 - 0.05, crownY - 0.05, zW + 0.7),
			front,
			IRON
		)
		Kit.trim(
			m,
			"GateCoping",
			Vector3.new(tx1, top, zW - 0.3),
			Vector3.new(X1 + 0.3, top + 0.5, zW + thick + 0.3),
			tile
		)
	end

	-------------------------------------------------------------------------------------------------------
	-- The Spanish chimney on the far gable end (a little tile roof on its cap), windows down that side
	-------------------------------------------------------------------------------------------------------
	local cz = zM - 3.2
	local cTop = H + SHAPE.chimney
	Kit.box(m, "Chimney", Vector3.new(mx0 - 1.3, -KIT.bury, cz - 1.1), Vector3.new(mx0 + 0.9, cTop, cz + 1.1), wall)
	Kit.trim(
		m,
		"ChimneyCap",
		Vector3.new(mx0 - 1.6, cTop, cz - 1.4),
		Vector3.new(mx0 + 1.2, cTop + 0.4, cz + 1.4),
		stone
	)
	Kit.gableRoof(
		m,
		"ChimneyTile",
		Vector3.new(mx0 - 1.3, cTop + 0.4, cz - 1.1),
		Vector3.new(mx0 + 0.9, cTop + 1.4, cz + 1.1),
		"z",
		0.3,
		0.25,
		tile
	)
	local sideLength = cz - 1.6 - (zL + 0.5)
	if sideLength > 3 then
		local bays = math.max(1, math.floor(sideLength / 4.5))
		Kit.punched(
			m,
			"Side",
			Vector3.new(mx0 - 0.06, 0.4, zL + 0.5),
			Vector3.new(mx0 + 0.4, E - 0.95, cz - 1.6),
			pal.wall,
			P.window.dark,
			{ Enum.NormalId.Left },
			sideLength / bays,
			(E - 1.35) / 2
		)
	end

	-------------------------------------------------------------------------------------------------------
	-- The lot: paver drive and walk, a low garden wall and coping with a hedge behind, a bougainvillea, and a round
	-- reflecting fountain in front of the bay
	-------------------------------------------------------------------------------------------------------
	local paver = Kit.look(PAVER, Enum.Material.Brick)
	if variant.rhythm ~= 2 then
		Kit.detail(m, "Drive", Vector3.new(gx0 - 0.6, 0.02, -hd + 0.2), Vector3.new(gx1 + 0.6, 0.14, zW - 0.05), paver)
	end
	Kit.detail(m, "Walk", Vector3.new(mx1 - 1.7, 0.02, -hd + 0.2), Vector3.new(mx1 + 1.7, 0.14, tz0 - 0.45), paver)
	local gardenEnd = mx1 - 2.3
	local garden = SHAPE.garden
	Kit.box(
		m,
		"GardenWall",
		Vector3.new(-hw + 0.6, -KIT.bury, -hd + 1),
		Vector3.new(gardenEnd, garden.wall, -hd + 1.7),
		wall
	)
	Kit.trim(
		m,
		"Coping",
		Vector3.new(-hw + 0.48, garden.wall, -hd + 0.88),
		Vector3.new(gardenEnd + 0.12, garden.wall + 0.35, -hd + 1.82),
		stone
	)
	local hedge = Kit.look(HEDGE, Enum.Material.Grass)
	-- A knee wall with the hedge standing well over it (the first preview's 2.6 wall hid the hedge and read as a blank
	-- slab), still low enough that the arched window and the arcade show over it from the street at eye height.
	Kit.trim(
		m,
		"Hedge",
		Vector3.new(-hw + 0.8, 0, -hd + 1.75),
		Vector3.new(gardenEnd - 0.2, garden.hedge, -hd + 3.3),
		hedge
	)
	Kit.ball(
		m,
		"Bloom",
		Vector3.new(gardenEnd - 0.9, garden.hedge - 0.2, -hd + 2.5),
		3.2,
		Kit.look(BLOOM, Enum.Material.LeafyGrass),
		"trim"
	)
	local fz = (-hd + 3.3 + zF) / 2
	if zF - (-hd + 3.3) >= 5.2 then
		Kit.column(m, "Fountain", bc, fz, -KIT.bury, 0.9, 3.6, stone)
		Kit.column(m, "FountainWater", bc, fz, 0.8, 0.97, 3.0, Kit.look(P.water, Enum.Material.Glass, 0.3, 0), "detail")
		Kit.column(m, "FountainJet", bc, fz, 0.9, 2.4, 0.7, stone, "trim")
	end
end

local archetype: Types.Archetype = { id = "mediterranean_villa", build = build }
return archetype
