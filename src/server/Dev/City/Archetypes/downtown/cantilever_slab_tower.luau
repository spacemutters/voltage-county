--!strict
-- T13 cantilever_slab_tower (docs/city/ARCHETYPES.md §5, T13): a slim condo tower whose deep white concrete slabs
-- cantilever far past the glass, one every floor, their front, back and end edges reaching out further and pulling
-- back again slab by slab, so the tower's edges ripple in and out up its height (the three waves out of step). At
-- the four corners stand stacked columns that swell and thin: hourglasses one on another, a round shaft with a ball
-- where it passes every third slab. The glass sits deep in the slabs' shade. On the ground a glazed lobby set deep under the first slab, a reflecting pool between the front columns, the
-- name on a low wall at the front, planters.
--
-- What makes it itself: deep white slab edges rippling in and out up the tower, held by swelling corner columns.
-- Placement, sizes, heights and its budget: Config/CityArchetypes/cantilever_slab_tower.
-- Variants: palette (4 concrete and glass sets: white or warm concrete), crown (1 the top tapers: the last floors
-- set in under smaller slabs, a roof room; 2 a deep hat: the roof slab at the widest reach with a lit underside;
-- 3 a sky pool deck with a rail and a pergola), rhythm (the wave: 1 slow and deep, 2 quicker, 3 a stagger of deep
-- and shallow slabs), mirror (the sign wall, the planters and the roof's pool and pergola swap ends).
--
-- Preview checklist: the ripple must read from the street and from 400 studs (if it doesn't, raise the waves' amp;
-- the core keeps at least coreMinDepth); the column joints must read as swellings of one column, not beads on a
-- string (try a bigger knuckle or a thinner rib); the slab edges' shadow lines in the 2 pm sun; at night two lit runs,
-- the lobby, the ice-blue edge lines every fourth slab, and crown 2's lit hat.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local City = require(ReplicatedStorage.Shared.Config.City)
local Kit = require(script.Parent.Parent.Parent.Kit)
local Types = require(script.Parent.Parent.Parent.Types)

local P = City.palettes
local KIT = City.kit
local rgb = Color3.fromRGB

-- The recipe, in studs.
local SHAPE = {
	lobby = 16, -- the ground floor, glazed, under the first slab
	bay = 13, -- slab to slab: a floor
	minBays = 12,
	front = 4, -- the slabs' deepest reach keeps this far behind the front line...
	back = 1.2, -- ...and this far from the back line
	side = 1.5,
	slabThick = 1.8,
	roofThick = 2.4,
	ends = 2.8, -- the slabs reach at least this far past the core's ends...
	endsAmp = 2.4, -- ...and up to this further, on the front wave `endsShift` slabs later
	endsShift = 1,
	base = 4.6, -- and at least this far past its long faces (the glass sits deep in their shade)...
	-- ...and up to `amp` further, slab by slab, after `shape`. The back face runs the same wave `backShift` slabs
	-- later at `backShare` of its depth, so the two faces ripple out of step.
	waves = {
		{ amp = 4.4, shape = { 0, 0.35, 1, 0.35, 0 } },
		{ amp = 3.8, shape = { 0, 0.6, 1, 0.6 } },
		{ amp = 3.4, shape = { 0, 1, 0.3 } },
	},
	backShare = 0.6,
	backShift = 2,
	coreMax = { 64, 46 }, -- width and depth
	coreMinDepth = 22, -- a shallow site calms the wave before the core gets thinner than this
	rib = 2.2, -- the corner columns' waist: a round shaft through every slab...
	knuckle = 4.4, -- ...swelling to this at every third slab (a ball, half above it and half below)
	jointEvery = 3, -- counted down from the top slab (the first slab always has one)
	inset = 2.2, -- the columns stand this far inside the slabs' shallowest corner
	lobbyInset = 5,
	edgeEvery = 5, -- an LED line on the front edge of every fifth slab
	litBays = { 3, 6 }, -- each of the two lit runs spans this many floors
	bayU = 6, -- a window bay on the glass
	plinth = 0.6,
	signWall = { 18, 2.8 }, -- length, height
	planter = 9,
	pool = { 14, 8 }, -- half its width and its depth, at most
	taperBays = 3, -- crown 1: the top floors set in...
	taperInset = 3, -- ...by this on every side
	roofRoom = 7,
	pergola = 9,
}

-- Concrete (slabs and columns) and glass: white with blue-green, warm with aqua, white with silver, warm with blue.
local PALETTES = {
	{ concrete = rgb(237, 235, 230), glass = rgb(90, 138, 151) },
	{ concrete = rgb(230, 222, 208), glass = P.glass.aqua },
	{ concrete = rgb(242, 241, 237), glass = P.glass.silver },
	{ concrete = rgb(230, 222, 208), glass = P.glass.blue },
}

local RAIL = Kit.look(rgb(214, 236, 242), Enum.Material.Glass, 0.1, KIT.railTransparency)

local function build(m: Types.Model)
	local site = m.site
	local variant = site.variant
	local pal = PALETTES[math.clamp(variant.palette, 1, #PALETTES)]
	local rng = Kit.rng(m)
	local W, D, H = site.width, site.depth, site.height
	local hw, hd = W / 2, D / 2
	local G = SHAPE.lobby
	local crown = variant.crown
	local wave = SHAPE.waves[math.clamp(variant.rhythm, 1, #SHAPE.waves)]
	local shape = wave.shape
	local concrete = Kit.look(pal.concrete, Enum.Material.SmoothPlastic)
	local paving = Kit.look(P.deco.terrazzo, Enum.Material.SmoothPlastic)
	local lines = pal.glass:Lerp(P.frame.white, 0.4)
	local lobbyColor = rgb(44, 60, 70)

	-------------------------------------------------------------------------------------------------------
	-- The core: as deep as the site allows once both faces' deepest slabs fit, the spare depth split front and back
	-------------------------------------------------------------------------------------------------------
	local base, share = SHAPE.base, SHAPE.backShare
	local avail = D - SHAPE.front - SHAPE.back
	local amp = wave.amp
	local cd = avail - 2 * base - amp * (1 + share)
	if cd < SHAPE.coreMinDepth then
		amp = math.max(0.5, amp - (SHAPE.coreMinDepth - cd) / (1 + share))
		cd = avail - 2 * base - amp * (1 + share)
	end
	local spare = math.max(0, cd - SHAPE.coreMax[2])
	cd -= spare
	local tx = math.min(SHAPE.coreMax[1], W - 2 * (SHAPE.side + SHAPE.ends + SHAPE.endsAmp)) / 2
	local tz0 = -hd + SHAPE.front + base + amp + spare * 0.5
	local tz1 = tz0 + cd

	-- How far slab i (0 up) reaches past the front and the back faces.
	local function reachFront(i: number): number
		return base + amp * shape[i % #shape + 1]
	end
	local function reachBack(i: number): number
		return base + amp * share * shape[(i + SHAPE.backShift) % #shape + 1]
	end
	-- And past the core's ends: the ends ripple too, so the wave reads from straight in front as well.
	local function reachEnds(i: number): number
		return SHAPE.ends + SHAPE.endsAmp * shape[(i + SHAPE.endsShift) % #shape + 1]
	end

	-- Slab i (0..b - 1) sits at G + i * e, the first on the lobby; the roof slab tops out at H. Crown 1 sets the top
	-- bays in: the columns and the full core stop at slab `last`.
	local b = math.max(SHAPE.minBays, math.round((H - G) / SHAPE.bay))
	local e = (H - G) / b
	local taper = crown == 1
	local last = if taper then b - SHAPE.taperBays else b - 1
	local yT = G + last * e
	local ti = SHAPE.taperInset

	-------------------------------------------------------------------------------------------------------
	-- Glass: the core (and crown 1's set-in top), the lobby under the first slab, two runs that glow at night
	-------------------------------------------------------------------------------------------------------
	local grid = {
		image = City.textures.windowFine,
		u = SHAPE.bayU,
		v = e,
		lines = lines,
	}
	local coreTop = if taper then yT + 0.3 else H - SHAPE.roofThick + 0.3
	Kit.glass(m, "Core", Vector3.new(-tx, G + 0.4, tz0), Vector3.new(tx, coreTop, tz1), pal.glass, grid)
	if taper then
		Kit.glass(
			m,
			"CoreTop",
			Vector3.new(-tx + ti, yT + SHAPE.slabThick - 0.3, tz0 + ti),
			Vector3.new(tx - ti, H - SHAPE.roofThick + 0.3, tz1 - ti),
			pal.glass,
			grid
		)
	end
	local li = SHAPE.lobbyInset
	Kit.glass(
		m,
		"Lobby",
		Vector3.new(-tx + li, -KIT.bury, tz0 + li),
		Vector3.new(tx - li, G + 0.3, tz1 - li),
		lobbyColor,
		{
			image = City.textures.windowBold,
			faces = { Enum.NormalId.Front, Enum.NormalId.Left, Enum.NormalId.Right },
			u = 6,
			v = G,
			lines = pal.concrete,
		}
	)
	local lobbySkin = Kit.detail(
		m,
		"LobbyLit",
		Vector3.new(-tx + li + 1, 1.4, tz0 + li - 0.18),
		Vector3.new(tx - li - 1, G - 2, tz0 + li - 0.06),
		Kit.glassLook(lobbyColor)
	)
	lobbySkin.textures = {
		{ face = Enum.NormalId.Front, image = City.textures.windowBold, u = 6, v = G, color = pal.concrete },
	}
	Kit.lit(lobbySkin, "window")

	-- Two runs of floors glow at night, one in each half of the full core, through skins on its front.
	local function litRun(name: string, j0: number, j1: number)
		local skin = Kit.detail(
			m,
			name,
			Vector3.new(-tx + 1, G + j0 * e + SHAPE.slabThick + 0.2, tz0 - 0.18),
			Vector3.new(tx - 1, math.min(G + j1 * e, coreTop) - 0.2, tz0 - 0.06),
			Kit.glassLook(pal.glass)
		)
		skin.textures = {
			{ face = Enum.NormalId.Front, image = grid.image, u = grid.u, v = grid.v, color = grid.lines },
		}
		Kit.lit(skin, "window")
	end
	local bays = if taper then last else b
	local half = math.floor(bays / 2)
	local n1 = rng:NextInteger(SHAPE.litBays[1], SHAPE.litBays[2])
	local j0 = rng:NextInteger(1, math.max(1, half - n1))
	litRun("LitLow", j0, math.max(j0 + 1, math.min(half, j0 + n1)))
	local n2 = rng:NextInteger(SHAPE.litBays[1], SHAPE.litBays[2])
	local j2 = rng:NextInteger(half + 1, math.max(half + 1, bays - n2))
	litRun("LitHigh", j2, math.max(j2 + 1, math.min(bays, j2 + n2)))

	-------------------------------------------------------------------------------------------------------
	-- The slabs, rippling; the corner columns swelling at each one; an LED line on every fourth slab's edge
	-------------------------------------------------------------------------------------------------------
	local cxk = tx + SHAPE.ends - SHAPE.inset
	local czF, czB = tz0 - (base - SHAPE.inset), tz1 + (base - SHAPE.inset)
	local corners = { Vector2.new(-cxk, czF), Vector2.new(cxk, czF), Vector2.new(-cxk, czB), Vector2.new(cxk, czB) }
	for i = 0, b - 1 do
		local y = G + i * e
		local small = taper and i > last
		local x = if small then tx - ti + SHAPE.ends - 1 else tx + reachEnds(i)
		local zf = if small then tz0 + ti - (base - 1) else tz0 - reachFront(i)
		local zb = if small then tz1 - ti + (base - 1) else tz1 + reachBack(i)
		Kit.trim(m, `Slab{i}`, Vector3.new(-x, y, zf), Vector3.new(x, y + SHAPE.slabThick, zb), concrete)
		if i <= last and (i == 0 or (last - i) % SHAPE.jointEvery == 0) then
			for c, p in corners do
				Kit.ball(
					m,
					`Joint{c}_{i}`,
					Vector3.new(p.X, y + SHAPE.slabThick / 2, p.Y),
					SHAPE.knuckle,
					concrete,
					"trim"
				)
			end
		end
		if i >= 1 and i <= last and (i + 1) % SHAPE.edgeEvery == 0 then
			Kit.neonStrip(
				m,
				`Edge{i}`,
				Vector3.new(-x + 0.3, y + 0.3, zf - 0.15),
				Vector3.new(x - 0.3, y + 0.9, zf - 0.05),
				"ledEdge",
				pal.concrete
			)
		end
	end
	local columnTop = if taper then yT + SHAPE.slabThick / 2 else H - SHAPE.roofThick + 0.3
	for c, p in corners do
		Kit.column(m, `Column{c}`, p.X, p.Y, -KIT.bury, columnTop, SHAPE.rib, concrete)
	end

	-------------------------------------------------------------------------------------------------------
	-- The roof
	-------------------------------------------------------------------------------------------------------
	local roofY = H - SHAPE.roofThick
	if crown == 1 then
		-- The set-in top: a smaller roof slab and a roof room.
		local x = tx - ti + SHAPE.ends - 1
		Kit.trim(
			m,
			"Roof",
			Vector3.new(-x, roofY, tz0 + ti - (base - 1)),
			Vector3.new(x, H, tz1 - ti + (base - 1)),
			concrete
		)
		local rx = (tx - ti) * 0.4
		Kit.roofBox(
			m,
			"RoofRoom",
			Vector3.new(-rx, H, tz0 + ti + 3),
			Vector3.new(rx, H + SHAPE.roofRoom, tz1 - ti - 3),
			concrete
		)
	elseif crown == 2 then
		-- A deep hat: the roof slab at the widest reach all round, a lit line round its edge (sunk in the slab's middle,
		-- so only the edge glows).
		local x = tx + SHAPE.ends + SHAPE.endsAmp
		local zf, zb = tz0 - (base + amp), tz1 + (base + amp * share)
		Kit.trim(m, "Roof", Vector3.new(-x, roofY, zf), Vector3.new(x, H, zb), concrete)
		Kit.neonStrip(
			m,
			"RoofLed",
			Vector3.new(-x - 0.15, roofY + 0.8, zf - 0.15),
			Vector3.new(x + 0.15, roofY + 1.5, zb + 0.15),
			"crown",
			pal.concrete
		)
		Kit.roofBox(
			m,
			"RoofRoom",
			Vector3.new(-tx * 0.3, H, tz0 + 4),
			Vector3.new(tx * 0.3, H + SHAPE.roofRoom, tz1 - 4)
		)
	else
		-- A sky pool deck: a rail along the front, a pool, a pergola.
		local x = tx + SHAPE.ends
		local zf = tz0 - (base + amp * 0.5)
		Kit.trim(m, "Roof", Vector3.new(-x, roofY, zf), Vector3.new(x, H, tz1 + base), concrete)
		Kit.detail(
			m,
			"RoofRail",
			Vector3.new(-x + 0.3, H, zf + 0.2),
			Vector3.new(x - 0.3, H + KIT.railHeight, zf + 0.5),
			RAIL
		)
		Kit.pool(m, "SkyPool", Vector3.new(-tx + 2, 0, tz0 - 1), Vector3.new(tx * 0.2, 0, tz0 + cd * 0.45), H)
		local pz = tz0 + cd * 0.6
		local px0, px1 = tx * 0.45, tx * 0.85
		Kit.column(m, "PergolaPost1", px0, pz, H, H + SHAPE.pergola, 0.8, concrete, "trim")
		Kit.column(m, "PergolaPost2", px1, pz, H, H + SHAPE.pergola, 0.8, concrete, "trim")
		Kit.trim(
			m,
			"Pergola",
			Vector3.new(px0 - 1, H + SHAPE.pergola, pz - 2),
			Vector3.new(px1 + 1, H + SHAPE.pergola + 0.8, pz + 4),
			concrete
		)
	end

	-------------------------------------------------------------------------------------------------------
	-- The ground: paving, a reflecting pool between the front columns, the name on a low wall, planters
	-------------------------------------------------------------------------------------------------------
	local plinth = SHAPE.plinth
	Kit.box(m, "Plinth", Vector3.new(-hw + 0.5, 0, -hd + 0.5), Vector3.new(hw - 0.5, plinth, hd - 0.5), paving)
	local poolHalf = math.min(SHAPE.pool[1], cxk - 3)
	local pz0 = -hd + 4.3
	local pz1 = math.min(pz0 + SHAPE.pool[2], tz0 + li - 1.8)
	if pz1 - pz0 >= 3 then
		Kit.pool(m, "Pool", Vector3.new(-poolHalf, 0, pz0), Vector3.new(poolHalf, 0, pz1), plinth)
	end
	local wl, wh = SHAPE.signWall[1], SHAPE.signWall[2]
	local wx = -hw + 4
	Kit.box(
		m,
		"SignWall",
		Vector3.new(wx, plinth - 0.1, -hd + 1.2),
		Vector3.new(wx + wl, plinth + wh, -hd + 2.4),
		concrete
	)
	local names = City.signNames.towers
	Kit.sign(
		m,
		"Name",
		Vector3.new(wx + 1, plinth + 0.6, -hd + 0.75),
		Vector3.new(wx + wl - 1, plinth + wh - 0.4, -hd + 1.15),
		Enum.NormalId.Front,
		names[rng:NextInteger(1, #names)],
		rgb(40, 44, 50),
		pal.concrete,
		City.districtLooks.downtown.font
	)
	for i, px in { hw - 5 - SHAPE.planter, wx + wl + 4 } do
		Kit.planter(
			m,
			`Planter{i}`,
			Vector3.new(px, plinth, -hd + 1),
			Vector3.new(px + SHAPE.planter, plinth + 1.4, -hd + 3),
			concrete
		)
	end
end

local archetype: Types.Archetype = { id = "cantilever_slab_tower", build = build }
return archetype
