--!strict
-- R01 mediterranean_villa (docs/city/ARCHETYPES.md §7, R01): the suburbs' Mediterranean Revival villa. A two-storey
-- stucco block under a low hipped roof of barrel tiles on a corbelled cornice. Its ground floor is a three-arch loggia
-- (pilaster piers, arch heads cut by haunches, a terracotta floor, lit French doors at the back) with an iron balcony
-- and an arched door over the middle arch and green shuttered windows over the others. A square stair tower stands at
-- its corner and rises past the roof under a tile pyramid, the front door and a lantern in its foot. Beside it a
-- one-storey garage wing behind a tile-visored parapet with a carriage door (or a garden wall with an arched gate and
-- an iron gate). A chimney on the far end, a low garden wall with a ficus hedge and a bougainvillea, paver drive and
-- walk.
--
-- What makes it itself: light stucco under low red barrel-tile roofs, an arched loggia and a square stair tower.
-- Placement, sizes, heights and its budget: Config/CityArchetypes/mediterranean_villa.
-- Variants: palette (4 sets of wall, tile, shutters and trim: white, cream, pale rose, ochre), crown (1 a low tower
-- with one arched window, 2 a taller tower with a pair of arched windows, a sill course and a ball finial), rhythm
-- (1 the garage wing, 2 a garden wall with an arched carriage gate), mirror (tower and drive left or right).
--
-- Previewing: from the street at eye height and from the drive's corner. Check the hip roof's corner wedges meet the
-- ridge cleanly (Kit.hipRoof, first use), the ClayRoofTiles run down the slopes, the haunches read as arches at 70 mph
-- (if not, widen SHAPE.haunch), the iron rails show (a punched Texture on an invisible part), the tower window clears
-- the main roof, the front door and lantern sit right of the loggia. At night: the loggia doors, the balcony door and
-- the tower window glow, some upper windows too, and the lantern is warm.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local City = require(ReplicatedStorage.Shared.Config.City)
local Kit = require(script.Parent.Parent.Parent.Kit)
local Types = require(script.Parent.Parent.Parent.Types)

local P = City.palettes
local KIT = City.kit
local rgb = Color3.fromRGB

-- The recipe, in studs.
local SHAPE = {
	side = 2, -- the walls stand this far in from the site's sides (the eaves reach 1.6 past them)
	yard = { 0.26, 9, 14 }, -- the front garden: share of the depth, clamped
	mainDepth = { 0.38, 16, 20 },
	mainMax = 26, -- the main block's width, at most
	wing = { 12, 16 }, -- the garage wing's width
	wingBack = 5, -- its front behind the main front
	wingDepth = { 0.3, 14, 16 },
	wingTop = 11.5,
	rise = { 0.2, 3.5, 5.5 }, -- the main roof's rise: share of the height, clamped (a low Mediterranean pitch)
	overhang = 1.6,
	roofThick = 0.6,
	cornice = { thick = 0.9, proud = 0.7 },
	loggia = 6, -- its depth
	arcade = 1.4, -- the arcade wall's thickness
	pierOuter = 2.2,
	pierInner = 1.5,
	pierProud = 0.2, -- the piers stand out of the wall over them like pilasters
	towerEnd = 3.8, -- the solid end of the arcade in front of the tower
	haunch = 0.42, -- an arch's haunches: share of its opening
	crownDrop = 1.4, -- the arches' crowns this far under the upper floor
	terrace = 0.6,
	tower = 7,
	towerBack = 2, -- the tower's front behind the main front
	towerRise = { 3.5, 5 }, -- over the ridge, by crown
	capRise = { 2.6, 3.4 },
	balconyProud = 2.2,
	gate = 8, -- rhythm 2: the garden wall's height
	gateHaunch = 2.4,
}

-- Wall, tile, shutters and trim. Pushed a little past the paint chips so the sky light doesn't grey them.
local PALETTES = {
	{ wall = rgb(246, 241, 230), tile = rgb(184, 86, 56), shutter = rgb(62, 107, 84), trim = rgb(252, 250, 244) },
	{ wall = rgb(242, 224, 188), tile = rgb(196, 104, 62), shutter = rgb(44, 86, 112), trim = rgb(250, 244, 230) },
	{ wall = rgb(240, 192, 176), tile = rgb(170, 78, 52), shutter = rgb(56, 98, 80), trim = rgb(250, 238, 230) },
	{ wall = rgb(228, 188, 124), tile = rgb(176, 90, 56), shutter = rgb(96, 66, 44), trim = rgb(248, 238, 214) },
}

local IRON = rgb(38, 38, 40)
local WOOD = rgb(112, 74, 48)
local PAVER = rgb(212, 186, 152)
local TERRACOTTA = rgb(184, 104, 74)
local HEDGE = rgb(56, 104, 54)
local BLOOM = rgb(210, 52, 134) -- bougainvillea
local LANTERN = rgb(255, 214, 160)

local function share(x: number, rule: { number }): number
	return math.clamp(x * rule[1], rule[2], rule[3])
end

-- Wrought iron: an invisible part with the punched overlay on `faces`. Tiles taller than the part show only their top
-- band and the bars under it, so it reads as a top rail over square bars.
local function iron(m: Types.Model, name: string, min: Vector3, max: Vector3, faces: { Enum.NormalId }): Types.PartSpec
	local spec = Kit.detail(m, name, min, max, Kit.look(IRON, Enum.Material.Metal, 0, 1))
	local textures: { Types.TextureSpec } = {}
	for _, face in faces do
		table.insert(
			textures,
			{ face = Kit.face(m, face), image = City.textures.punched, u = 1.1, v = 6, color = IRON }
		)
	end
	spec.textures = textures
	return spec
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
	local trim = Kit.look(pal.trim, Enum.Material.SmoothPlastic)
	local tile = Kit.look(pal.tile, Enum.Material.ClayRoofTiles)
	local shutter = Kit.look(pal.shutter, Enum.Material.SmoothPlastic)
	local wood = Kit.look(WOOD, Enum.Material.WoodPlanks)
	local paver = Kit.look(PAVER, Enum.Material.Brick)
	local front = { Enum.NormalId.Front }

	-------------------------------------------------------------------------------------------------------
	-- The plan, drawn with the tower and the drive on the right (the kit mirrors it)
	-------------------------------------------------------------------------------------------------------
	local X0, X1 = -hw + SHAPE.side, hw - SHAPE.side
	local avail = X1 - X0
	local Ww = math.clamp(avail - 20, SHAPE.wing[1], SHAPE.wing[2])
	local Wm = math.min(SHAPE.mainMax, avail - Ww)
	local mx0, mx1 = X0, X0 + Wm
	local zF = -hd + share(D, SHAPE.yard)
	local zM = zF + share(D, SHAPE.mainDepth)
	local zL = zF + SHAPE.loggia -- the loggia's back wall
	local rise = share(H, SHAPE.rise)
	local E = H - rise -- the top of the walls (the cornice's top)
	local G = E / 2 -- the upper floor

	-------------------------------------------------------------------------------------------------------
	-- The main block: walls, the upper floor carried on the arcade, the loggia
	-------------------------------------------------------------------------------------------------------
	Kit.box(m, "Main", Vector3.new(mx0, -KIT.bury, zL), Vector3.new(mx1, E - 0.06, zM), wall)
	local lx0, lx1 = mx0 + SHAPE.pierOuter, mx1 - SHAPE.towerEnd -- the arcade's open span
	local w = (lx1 - lx0 - 2 * SHAPE.pierInner) / 3 -- one arch's opening
	local yc = G - SHAPE.crownDrop -- the arches' crowns
	Kit.box(m, "Upper", Vector3.new(mx0, yc, zF), Vector3.new(mx1, E - 0.04, zL), wall)
	local bay1 = lx0 + w + SHAPE.pierInner -- the middle arch's left jamb
	local piers = {
		{ mx0, lx0 },
		{ lx0 + w, bay1 },
		{ bay1 + w, bay1 + w + SHAPE.pierInner },
		{ lx1, mx1 },
	}
	for i, p in piers do
		Kit.box(
			m,
			`Pier{i}`,
			Vector3.new(p[1], -KIT.bury, zF - SHAPE.pierProud),
			Vector3.new(p[2], yc, zF + SHAPE.arcade),
			wall
		)
	end
	for b = 1, 3 do
		local x0 = lx0 + (b - 1) * (w + SHAPE.pierInner)
		Kit.archHead(m, `Arch{b}`, x0, x0 + w, yc, zF, zF + SHAPE.arcade, SHAPE.haunch * w, wall)
	end
	Kit.box(
		m,
		"Terrace",
		Vector3.new(mx0 + 0.3, -KIT.bury, zF - 1.8),
		Vector3.new(mx1 - 0.3, SHAPE.terrace, zL + 0.3),
		Kit.look(TERRACOTTA, Enum.Material.CeramicTiles)
	)
	-- French doors across the back of the loggia, warm at night.
	Kit.glass(
		m,
		"Doors",
		Vector3.new(lx0 + 0.3, SHAPE.terrace, zL - 0.2),
		Vector3.new(lx1 - 0.3, yc - 1.2, zL + 0.15),
		P.window.dark,
		{
			image = City.textures.windowBold,
			faces = front,
			u = 1.6,
			v = yc - 1.2 - SHAPE.terrace,
			lines = pal.trim,
			lit = true,
		}
	)

	-- The cornice under the eaves, and the low hipped tile roof.
	local cp = SHAPE.cornice.proud
	Kit.trim(
		m,
		"Cornice",
		Vector3.new(mx0 - cp, E - SHAPE.cornice.thick, zF - cp),
		Vector3.new(mx1 + cp, E, zM + cp),
		trim
	)
	Kit.hipRoof(m, "Roof", Vector3.new(mx0, E, zF), Vector3.new(mx1, H, zM), SHAPE.overhang, SHAPE.roofThick, tile)

	-------------------------------------------------------------------------------------------------------
	-- The upper floor's front: an iron balcony and an arched door over the middle arch, shutters either side
	-------------------------------------------------------------------------------------------------------
	local bc = bay1 + w / 2
	local bw = w + 2 * SHAPE.pierInner - 0.2 -- to just inside the piers' outer edges, clear of the shutters
	local bz = zF - SHAPE.balconyProud
	Kit.trim(m, "Balcony", Vector3.new(bc - bw / 2, G - 0.55, bz), Vector3.new(bc + bw / 2, G + 0.15, zF + 0.4), trim)
	iron(
		m,
		"Rail",
		Vector3.new(bc - bw / 2 + 0.15, G + 0.15, bz + 0.12),
		Vector3.new(bc + bw / 2 - 0.15, G + 3.15, zF - 0.06),
		{ Enum.NormalId.Front, Enum.NormalId.Left, Enum.NormalId.Right }
	)
	local dw = math.clamp(w - 0.6, 2.6, 4.2)
	local spring = E - 1.7 - dw / 2
	Kit.archWindow(m, "BalconyDoor", bc - dw / 2, bc + dw / 2, G + 0.15, spring, zF, P.window.dark, {
		image = City.textures.windowBold,
		faces = front,
		u = dw / 2,
		v = spring - G - 0.15,
		lines = pal.trim,
		lit = true,
	})
	local gw = math.clamp(w * 0.5, 1.8, 2.4) -- each shutter leaf; the boards stop at the arches' jambs
	local wy0 = G + 1.6
	local wy1 = wy0 + math.min(5.4, E - G - 3.2)
	for i, cx in { lx0 + w / 2, lx1 - w / 2 } do
		local board = Kit.detail(
			m,
			`Shutters{i}`,
			Vector3.new(cx - gw, wy0, zF - 0.12),
			Vector3.new(cx + gw, wy1, zF + 0.1),
			shutter
		)
		-- Louvres: the slab-line overlay, a shade darker than the shutters.
		board.textures = {
			{
				face = Enum.NormalId.Front,
				image = City.textures.slabLine,
				u = 2 * gw,
				v = 0.45,
				color = pal.shutter:Lerp(Color3.new(0, 0, 0), 0.35),
			},
		}
		Kit.glass(
			m,
			`Window{i}`,
			Vector3.new(cx - gw / 2, wy0 + 0.1, zF - 0.25),
			Vector3.new(cx + gw / 2, wy1 - 0.1, zF + 0.1),
			P.window.dark,
			{
				image = City.textures.windowBold,
				faces = front,
				u = gw / 2,
				v = (wy1 - wy0 - 0.2) / 2,
				lines = pal.trim,
				lit = rng:NextNumber() < 0.6,
			}
		)
	end

	-------------------------------------------------------------------------------------------------------
	-- The stair tower at the main block's corner, past the roof under a tile pyramid; the front door at its foot
	-------------------------------------------------------------------------------------------------------
	local tw = SHAPE.tower
	local tx0, tx1 = mx1 - tw / 2, mx1 + tw / 2
	local tz0, tz1 = zF + SHAPE.towerBack, zF + SHAPE.towerBack + tw
	local T = H + SHAPE.towerRise[crown]
	local capRise = SHAPE.capRise[crown]
	Kit.box(m, "Tower", Vector3.new(tx0, -KIT.bury, tz0), Vector3.new(tx1, T - 0.03, tz1), wall)
	Kit.trim(m, "TowerCornice", Vector3.new(tx0 - 0.5, T - 0.75, tz0 - 0.5), Vector3.new(tx1 + 0.5, T, tz1 + 0.5), trim)
	Kit.hipRoof(m, "TowerCap", Vector3.new(tx0, T, tz0), Vector3.new(tx1, T + capRise, tz1), 0.9, 0.45, tile)
	local pair = crown == 2
	local ww = if pair then 1.6 else 2.0
	for i, dx in (if pair then { -1.35, 1.35 } else { 0 }) :: { number } do
		Kit.archWindow(
			m,
			`TowerWindow{i}`,
			mx1 + dx - ww / 2,
			mx1 + dx + ww / 2,
			T - 5.2,
			T - 2 - ww / 2,
			tz0,
			P.window.dark,
			{ lit = true }
		)
	end
	if pair then
		Kit.trim(
			m,
			"TowerSill",
			Vector3.new(tx0 - 0.3, T - 5.75, tz0 - 0.3),
			Vector3.new(tx1 + 0.3, T - 5.3, tz1 + 0.3),
			trim
		)
		Kit.ball(m, "Finial", Vector3.new(mx1, T + capRise + 0.35, (tz0 + tz1) / 2), 0.9, trim, "trim")
	end
	local dx0, dx1 = mx1 + 0.45, mx1 + 3.0
	local doorSpring = 5.4
	Kit.trim(m, "Door", Vector3.new(dx0, 0, tz0 - 0.15), Vector3.new(dx1, doorSpring, tz0 + 0.2), wood)
	Kit.tube(
		m,
		"DoorHead",
		Vector3.new((dx0 + dx1) / 2, doorSpring, tz0 - 0.13),
		Vector3.new((dx0 + dx1) / 2, doorSpring, tz0 + 0.2),
		dx1 - dx0,
		wood,
		"trim"
	)
	local lantern = Kit.detail(
		m,
		"Lantern",
		Vector3.new((dx0 + dx1) / 2 - 0.35, 7.4, tz0 - 0.85),
		Vector3.new((dx0 + dx1) / 2 + 0.35, 8.5, tz0 + 0.05),
		Kit.look(LANTERN, Enum.Material.SmoothPlastic)
	)
	Kit.lit(lantern, "neonAmber") -- warm: a pale kind turns white-hot Neon

	-------------------------------------------------------------------------------------------------------
	-- Beside the tower: the garage wing (rhythm 1) or a garden wall with an arched carriage gate (rhythm 2)
	-------------------------------------------------------------------------------------------------------
	local wx1 = X1
	local wx0 = wx1 - Ww
	local zW = zF + SHAPE.wingBack
	local gx0, gx1 = tx1 + 0.8, wx1 - 0.8 -- the garage door or the gate
	if variant.rhythm ~= 2 then
		local zWB = math.min(zW + share(D, SHAPE.wingDepth), hd - 1.5)
		Kit.box(m, "Wing", Vector3.new(wx0, -KIT.bury, zW), Vector3.new(wx1, SHAPE.wingTop, zWB), wall)
		-- A short tile visor along the parapet, the Spanish way of roofing a flat wing.
		Kit.wedge(
			m,
			"WingVisor",
			Vector3.new(tx1 + 0.05, SHAPE.wingTop - 1.7, zW - 1.4),
			Vector3.new(wx1 + 0.6, SHAPE.wingTop + 0.3, zW + 1.2),
			"back",
			tile
		)
		Kit.trim(m, "GarageDoor", Vector3.new(gx0, 0, zW - 0.15), Vector3.new(gx1, 8.2, zW + 0.1), wood)
	else
		local top = SHAPE.gate
		local crownY = top - 1.2
		local thick = 1.2
		Kit.box(m, "GateWallL", Vector3.new(tx1 - 0.1, -KIT.bury, zW), Vector3.new(gx0, top, zW + thick), wall)
		Kit.box(m, "GateWallR", Vector3.new(gx1, -KIT.bury, zW), Vector3.new(wx1, top, zW + thick), wall)
		Kit.box(m, "GateLintel", Vector3.new(gx0, crownY, zW), Vector3.new(gx1, top - 0.02, zW + thick), wall)
		Kit.archHead(m, "GateArch", gx0, gx1, crownY, zW, zW + thick, SHAPE.gateHaunch, wall)
		iron(m, "Gate", Vector3.new(gx0 + 0.05, 0, zW + 0.5), Vector3.new(gx1 - 0.05, crownY - 0.05, zW + 0.7), front)
		Kit.trim(
			m,
			"GateCoping",
			Vector3.new(tx1, top, zW - 0.3),
			Vector3.new(wx1 + 0.3, top + 0.5, zW + thick + 0.3),
			tile
		)
	end

	-------------------------------------------------------------------------------------------------------
	-- The chimney on the far end wall
	-------------------------------------------------------------------------------------------------------
	local cz = zM - 3
	Kit.box(m, "Chimney", Vector3.new(mx0 - 1.3, -KIT.bury, cz - 1.1), Vector3.new(mx0 + 0.9, H + 1.6, cz + 1.1), wall)
	Kit.trim(
		m,
		"ChimneyCap",
		Vector3.new(mx0 - 1.65, H + 1.6, cz - 1.45),
		Vector3.new(mx0 + 1.25, H + 2.2, cz + 1.45),
		trim
	)
	-- Windows down that side, ahead of the chimney (one tile a bay and a floor).
	local sideLength = cz - 1.5 - (zL + 0.4)
	if sideLength > 3 then
		local bays = math.max(1, math.floor(sideLength / 4.5))
		Kit.punched(
			m,
			"Side",
			Vector3.new(mx0 - 0.06, 0.4, zL + 0.4),
			Vector3.new(mx0 + 0.4, E - 0.95, cz - 1.5),
			pal.wall,
			P.window.dark,
			{ Enum.NormalId.Left },
			sideLength / bays,
			(E - 1.35) / 2
		)
	end

	-------------------------------------------------------------------------------------------------------
	-- The lot: paver drive and walk, a low garden wall with a ficus hedge behind it, a bougainvillea
	-------------------------------------------------------------------------------------------------------
	Kit.detail(m, "Drive", Vector3.new(gx0 - 0.6, 0.02, -hd + 0.2), Vector3.new(gx1 + 0.6, 0.14, zW - 0.05), paver)
	Kit.detail(m, "Walk", Vector3.new(bc - 1.7, 0.02, -hd + 0.2), Vector3.new(bc + 1.7, 0.14, zF - 1.85), paver)
	local gardenEnd = bc - 2.2
	Kit.box(m, "GardenWall", Vector3.new(X0 - 1.2, -KIT.bury, -hd + 1), Vector3.new(gardenEnd, 2.6, -hd + 1.7), wall)
	Kit.trim(
		m,
		"Coping",
		Vector3.new(X0 - 1.32, 2.6, -hd + 0.88),
		Vector3.new(gardenEnd + 0.12, 2.95, -hd + 1.82),
		trim
	)
	local hedge = Kit.look(HEDGE, Enum.Material.LeafyGrass)
	-- Low enough that the loggia's arches show over it from the street at eye height.
	Kit.trim(m, "Hedge", Vector3.new(X0 - 1, 0, -hd + 1.75), Vector3.new(gardenEnd - 0.2, 3.3, -hd + 3.4), hedge)
	if gx0 - 1.2 - (bc + 2.2) >= 2 then
		Kit.trim(m, "Hedge2", Vector3.new(bc + 2.2, 0, -hd + 1), Vector3.new(gx0 - 1.2, 2.9, -hd + 2.6), hedge)
	end
	Kit.ball(
		m,
		"Bloom",
		Vector3.new(gardenEnd - 0.4, 3.2, -hd + 2.5),
		2.6,
		Kit.look(BLOOM, Enum.Material.LeafyGrass),
		"trim"
	)
end

local archetype: Types.Archetype = { id = "mediterranean_villa", build = build }
return archetype
