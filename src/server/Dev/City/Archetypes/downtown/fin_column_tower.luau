--!strict
-- T14 fin_column_tower (docs/city/ARCHETYPES.md §5, T14): a slim bayfront condo tower of clear, nearly mullion-free
-- blue glass, held at its four corners by white blade fins that stand diagonally out of the corners like a yacht's
-- fins, run the full height from the podium and rise past the roof, their tops raked off. Across the front a cascade
-- of white balconies with glass rails steps sideways band by band. Below, a low podium: a glazed lobby under a white
-- eyebrow with the name on it, a white amenity level with a ribbon window, a cap with an LED edge, and a pool deck on
-- top (a lap pool and umbrellas beside the tower on a wide site, a pool in front on a deep one).
--
-- What makes it itself: four white blade fins standing out of the corners, running the full height and raking off
-- past the roof.
-- Placement, sizes, heights and its budget: Config/CityArchetypes/fin_column_tower.
-- Variants: palette (3 fin and glass sets: white fins on clear blue, stone fins on aqua, white on silver), crown (1
-- tall blades highest at their tips over a lit roof slab; 2 low blades sloping down outward over a roof terrace; 3
-- blades holding a floating white ring), rhythm (the cascade: a balcony every 2, 3 or 4 floors, the last on the back
-- face too), mirror (the cascade steps the other way; on a wide site the tower and its pool deck swap sides).
--
-- Preview checklist: the fins must read as blades on the diagonal, thin from the front and deep from the corner view
-- (check SHAPE.fin against the core at 200 and 500 studs); the raked tops against the sky; the balconies must read as
-- a cascade, not random slabs; the glass should look clear and bright in sun, not grey; at night four vertical fin
-- lines, the podium's blue edge and two lit runs.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local City = require(ReplicatedStorage.Shared.Config.City)
local Kit = require(script.Parent.Parent.Parent.Kit)
local Types = require(script.Parent.Parent.Parent.Types)

local P = City.palettes
local KIT = City.kit
local rgb = Color3.fromRGB

-- The recipe, in studs.
local SHAPE = {
	lobby = 16,
	amenity = 14, -- the podium's upper level
	front = 3.5, -- the podium's face behind the front line
	side = 1.5,
	back = 1.5,
	cap = 1.6,
	capProud = 1.2,
	eyebrow = { thick = 0.8, proud = 2.6 },
	lobbyInset = 3,
	fin = { thick = 3.2, long = 12.5, embed = 3.2 }, -- a corner blade along the diagonal, this far into the corner
	coreMax = { 64, 52 },
	coreRatio = 1.6, -- the core's width over its depth, at most
	floor = 12,
	band = { thick = 2.4, proud = 5.2 }, -- the cascade's balconies: deep white slabs that read from the bay
	step = 0.14, -- of the core's width: how far each balcony shifts from the last
	rhythms = {
		-- A long diagonal sweep across the face and back again, a zigzag, or a quick sweep on both faces.
		{ every = 24, share = 0.62, offsets = { -1.5, -0.9, -0.3, 0.3, 0.9, 1.5, 0.9, 0.3, -0.3, -0.9 }, back = false },
		{ every = 36, share = 0.66, offsets = { -1, 0, 1, 0 }, back = false },
		{ every = 48, share = 0.6, offsets = { -1.5, -0.5, 0.5, 1.5 }, back = true },
	},
	topClear = 14, -- no balcony in the top floor
	crowns = {
		{ rise = 30, rake = 16, outward = true },
		{ rise = 18, rake = 10, outward = false },
		{ rise = 26, rake = 12, outward = true },
	},
	ring = { at = 14, thick = 1.4, out = 2.5 }, -- crown 3: the floating ring
	roofRoom = 7,
	pergola = 8,
	litFloors = { 4, 7 },
	sideDeck = 22, -- spare width that puts the pool deck beside the tower
	signWidth = 12,
}

-- Fins, glass: white on clear blue, stone on aqua, white on silver.
local PALETTES = {
	{ fin = P.frame.white, glass = rgb(104, 146, 162) },
	{ fin = rgb(217, 212, 200), glass = P.glass.aqua },
	{ fin = P.frame.white, glass = P.glass.silver },
}

local RAIL = Kit.look(rgb(214, 236, 242), Enum.Material.Glass, 0.1, KIT.railTransparency)
local ROOT2 = math.sqrt(2)

local function build(m: Types.Model)
	local site = m.site
	local variant = site.variant
	local pal = PALETTES[math.clamp(variant.palette, 1, #PALETTES)]
	local rng = Kit.rng(m)
	local W, D, H = site.width, site.depth, site.height
	local hw, hd = W / 2, D / 2
	local x0, x1 = -hw + SHAPE.side, hw - SHAPE.side
	local zP, zB = -hd + SHAPE.front, hd - SHAPE.back
	local cp = SHAPE.capProud
	local G = SHAPE.lobby
	local Hp = G + SHAPE.amenity
	local deckY = Hp + SHAPE.cap
	local crown = SHAPE.crowns[math.clamp(variant.crown, 1, #SHAPE.crowns)]
	local rhythm = SHAPE.rhythms[math.clamp(variant.rhythm, 1, #SHAPE.rhythms)]
	local white = Kit.look(pal.fin, Enum.Material.SmoothPlastic)
	local paving = Kit.look(P.deco.terrazzo, Enum.Material.SmoothPlastic)
	local lobbyColor = rgb(44, 60, 70)
	local lines = pal.glass:Lerp(P.frame.white, 0.35)

	-------------------------------------------------------------------------------------------------------
	-- The core: it keeps the fins' reach from the podium cap's edges, at the back of the deck
	-------------------------------------------------------------------------------------------------------
	local fin = SHAPE.fin
	-- How far a fin (and the light strip on its outer edge) reaches past its corner, along x and along z.
	local reach = ((fin.long / 2 - fin.embed) + (fin.thick + fin.long) / 2) / ROOT2 + 0.2
	local zMin, zMax = zP - cp + reach, zB + cp - reach
	local cd = math.min(SHAPE.coreMax[2], zMax - zMin)
	local cxMin, cxMax = x0 - cp + reach, x1 + cp - reach
	local cw = math.min(SHAPE.coreMax[1], cd * SHAPE.coreRatio, cxMax - cxMin)
	local room = cxMax - cxMin - cw
	local deckSide = room >= SHAPE.sideDeck
	local cx0 = if deckSide then cxMin + math.min(4, room * 0.1) else (cxMin + cxMax - cw) / 2
	local cx1 = cx0 + cw
	local cz1 = zMax
	local cz0 = cz1 - cd
	local ccx = (cx0 + cx1) / 2

	Kit.glass(m, "Core", Vector3.new(cx0, deckY - 0.5, cz0), Vector3.new(cx1, H, cz1), pal.glass, {
		image = City.textures.slabLine,
		u = 12,
		v = SHAPE.floor,
		lines = lines,
		reflectance = 0.2,
	})
	-- Two runs of floors glow at night, one in each half, through skins on the front.
	local floors = math.floor((H - deckY) / SHAPE.floor)
	local halfF = math.floor(floors / 2)
	local function litRun(name: string, a: number, len: number)
		local y0 = deckY + a * SHAPE.floor + 0.3
		local y1 = math.min(deckY + (a + len) * SHAPE.floor - 0.3, H - 1)
		local skin = Kit.detail(
			m,
			name,
			Vector3.new(cx0 + 1, y0, cz0 - 0.18),
			Vector3.new(cx1 - 1, y1, cz0 - 0.06),
			Kit.glassLook(pal.glass, 0.2)
		)
		skin.textures = {
			{ face = Enum.NormalId.Front, image = City.textures.slabLine, u = 12, v = SHAPE.floor, color = lines },
		}
		Kit.lit(skin, "window")
	end
	local len1 = rng:NextInteger(SHAPE.litFloors[1], SHAPE.litFloors[2])
	litRun("LitLow", rng:NextInteger(1, math.max(1, halfF - len1)), len1)
	local len2 = rng:NextInteger(SHAPE.litFloors[1], SHAPE.litFloors[2])
	litRun("LitHigh", rng:NextInteger(halfF + 1, math.max(halfF + 1, floors - len2 - 1)), len2)

	-------------------------------------------------------------------------------------------------------
	-- The fins: a white blade out of each corner on the diagonal, from the podium to past the roof, raked off
	-------------------------------------------------------------------------------------------------------
	local finTop = H + crown.rise
	local bodyTop = finTop - crown.rake
	local stripTop = if crown.outward then finTop - 0.6 else bodyTop - 0.4
	for i, corner in { { -1, -1 }, { 1, -1 }, { -1, 1 }, { 1, 1 } } do
		local sx, sz = corner[1], corner[2]
		local cx = if sx < 0 then cx0 else cx1
		local cz = if sz < 0 then cz0 else cz1
		-- Turned so its own +z (its length) points out along the diagonal (sx, sz): CFrame.Angles(0, yaw, 0) sends +z
		-- to (sin yaw, cos yaw).
		local yaw = sx * (if sz > 0 then math.pi / 4 else 3 * math.pi / 4)
		local along = fin.long / 2 - fin.embed
		local px, pz = cx + sx * along / ROOT2, cz + sz * along / ROOT2
		local turn = CFrame.Angles(0, yaw, 0)
		Kit.oriented(
			m,
			`Fin{i}`,
			"block",
			CFrame.new(px, (Hp - 0.5 + bodyTop) / 2, pz) * turn,
			Vector3.new(fin.thick, bodyTop - Hp + 0.5, fin.long),
			white,
			"trim"
		)
		-- The raked top: highest at the tip (outward) or at the corner.
		local rake = if crown.outward then turn else turn * CFrame.Angles(0, math.pi, 0)
		Kit.oriented(
			m,
			`FinTop{i}`,
			"wedge",
			CFrame.new(px, bodyTop + crown.rake / 2, pz) * rake,
			Vector3.new(fin.thick, crown.rake, fin.long),
			white,
			"trim"
		)
		-- A light strip down the fin's outer edge.
		local strip = Kit.oriented(
			m,
			`FinLight{i}`,
			"block",
			CFrame.new(px, (Hp + 2 + stripTop) / 2, pz) * turn * CFrame.new(0, 0, fin.long / 2 + 0.11),
			Vector3.new(fin.thick - 0.8, stripTop - Hp - 2, 0.1),
			white,
			"detail"
		)
		Kit.lit(strip, "crown")
	end

	-------------------------------------------------------------------------------------------------------
	-- The cascade: white balconies with glass rails across the front, each shifted from the last
	-------------------------------------------------------------------------------------------------------
	local band = SHAPE.band
	local bl = cw * rhythm.share
	local most = 0
	for _, o in rhythm.offsets do
		most = math.max(most, math.abs(o))
	end
	-- Each balcony keeps 3 studs from the core's ends, clear of the fins.
	local stepX = math.min(cw * SHAPE.step, (cw / 2 - 3 - bl / 2) / most)
	local k = 0
	while true do
		k += 1
		local y = deckY + k * rhythm.every
		if y + band.thick > H - SHAPE.topClear then
			break
		end
		local off = rhythm.offsets[(k - 1) % #rhythm.offsets + 1] * stepX
		local faces = if rhythm.back then { -1, 1 } else { -1 }
		for _, face in faces do
			local bx = ccx + face * off
			local plane = if face < 0 then cz0 else cz1
			local tag = if face < 0 then "" else "Back"
			Kit.trim(
				m,
				`Balcony{tag}{k}`,
				Vector3.new(bx - bl / 2, y, plane - 0.5 * face),
				Vector3.new(bx + bl / 2, y + band.thick, plane + face * band.proud),
				white
			)
			Kit.detail(
				m,
				`Rail{tag}{k}`,
				Vector3.new(bx - bl / 2 + 0.2, y + band.thick, plane + face * 0.3),
				Vector3.new(bx + bl / 2 - 0.2, y + band.thick + KIT.railHeight, plane + face * (band.proud - 0.2)),
				RAIL
			)
		end
	end

	-------------------------------------------------------------------------------------------------------
	-- The crown between the fins
	-------------------------------------------------------------------------------------------------------
	local roomLook = Kit.look(pal.fin, Enum.Material.SmoothPlastic)
	if variant.crown == 1 then
		-- A white roof slab overhanging the glass, its underside lit, a roof room.
		Kit.trim(m, "Roof", Vector3.new(cx0 - 1, H - 0.6, cz0 - 1), Vector3.new(cx1 + 1, H + 0.8, cz1 + 1), white)
		Kit.neonStrip(
			m,
			"RoofLed",
			Vector3.new(cx0 - 1.15, H - 1.05, cz0 - 1.15),
			Vector3.new(cx1 + 1.15, H - 0.55, cz1 + 1.15),
			"crown",
			pal.fin
		)
		Kit.roofBox(
			m,
			"RoofRoom",
			Vector3.new(ccx - cw * 0.2, H + 0.8, cz0 + 4),
			Vector3.new(ccx + cw * 0.2, H + 0.8 + SHAPE.roofRoom, cz1 - 4),
			roomLook
		)
	elseif variant.crown == 2 then
		-- A roof terrace: a cornice, a glass rail round the edge, a pool, a pergola.
		Kit.trim(
			m,
			"Cornice",
			Vector3.new(cx0 - 0.8, H - 1, cz0 - 0.8),
			Vector3.new(cx1 + 0.8, H + 0.4, cz1 + 0.8),
			white
		)
		Kit.detail(
			m,
			"RoofRail",
			Vector3.new(cx0 - 0.5, H + 0.4, cz0 - 0.5),
			Vector3.new(cx1 + 0.5, H + 0.4 + KIT.railHeight, cz1 + 0.5),
			RAIL
		)
		Kit.pool(m, "SkyPool", Vector3.new(cx0 + 4, 0, cz0 + 3), Vector3.new(ccx - 2, 0, cz0 + 3 + cd * 0.35), H + 0.4)
		local pz = cz0 + cd * 0.55
		local px0, px1 = ccx + cw * 0.08, cx1 - 5
		Kit.column(m, "PergolaPost1", px0, pz, H + 0.4, H + 0.4 + SHAPE.pergola, 0.8, white, "trim")
		Kit.column(m, "PergolaPost2", px1, pz, H + 0.4, H + 0.4 + SHAPE.pergola, 0.8, white, "trim")
		Kit.trim(
			m,
			"Pergola",
			Vector3.new(px0 - 1, H + 0.4 + SHAPE.pergola, pz - 2),
			Vector3.new(px1 + 1, H + 1.2 + SHAPE.pergola, pz + 4),
			white
		)
	else
		-- A roof slab, and a white ring floating round the top, threaded through the four fins.
		Kit.trim(
			m,
			"Roof",
			Vector3.new(cx0 - 0.8, H - 0.6, cz0 - 0.8),
			Vector3.new(cx1 + 0.8, H + 0.6, cz1 + 0.8),
			white
		)
		local o = SHAPE.ring.out
		Kit.parapet(
			m,
			"Ring",
			Vector3.new(cx0 - o, 0, cz0 - o),
			Vector3.new(cx1 + o, 0, cz1 + o),
			H + SHAPE.ring.at,
			SHAPE.ring.thick,
			SHAPE.ring.thick,
			white
		)
	end

	-------------------------------------------------------------------------------------------------------
	-- The podium: lobby glass under an eyebrow, a white amenity level with a ribbon window, the cap and its LED
	-------------------------------------------------------------------------------------------------------
	local li = SHAPE.lobbyInset
	Kit.box(m, "Paving", Vector3.new(x0, 0, -hd + 0.5), Vector3.new(x1, 0.4, zP + li + 0.3), paving)
	Kit.glass(
		m,
		"Lobby",
		Vector3.new(x0 + li, -KIT.bury, zP + li),
		Vector3.new(x1 - li, G + 0.3, zB - li),
		lobbyColor,
		{
			image = City.textures.windowBold,
			faces = { Enum.NormalId.Front, Enum.NormalId.Left, Enum.NormalId.Right },
			u = 6,
			v = G,
			lines = pal.fin,
		}
	)
	local lobbySkin = Kit.detail(
		m,
		"LobbyLit",
		Vector3.new(x0 + li + 1, 1.4, zP + li - 0.18),
		Vector3.new(x1 - li - 1, G - 2, zP + li - 0.06),
		Kit.glassLook(lobbyColor)
	)
	lobbySkin.textures = {
		{ face = Enum.NormalId.Front, image = City.textures.windowBold, u = 6, v = G, color = pal.fin },
	}
	Kit.lit(lobbySkin, "window")
	Kit.box(m, "Podium", Vector3.new(x0, G, zP), Vector3.new(x1, Hp, zB), white)
	Kit.glass(
		m,
		"Ribbon",
		Vector3.new(x0 + 2, G + 3.5, zP - 0.12),
		Vector3.new(x1 - 2, Hp - 3, zP + 0.4),
		P.window.dark,
		{
			image = City.textures.windowFine,
			faces = { Enum.NormalId.Front },
			u = 4,
			v = Hp - 3 - G - 3.5,
			lines = pal.fin,
		}
	)
	local brow = SHAPE.eyebrow
	Kit.trim(
		m,
		"Eyebrow",
		Vector3.new(x0 - 0.3, G - brow.thick, zP - brow.proud),
		Vector3.new(x1 + 0.3, G + 0.05, zP + 0.5),
		white
	)
	Kit.trim(m, "Cap", Vector3.new(x0 - cp, Hp, zP - cp), Vector3.new(x1 + cp, deckY, zB + cp), white)
	Kit.neonStrip(
		m,
		"CapLed",
		Vector3.new(x0 - cp, Hp - 0.45, zP - cp - 0.15),
		Vector3.new(x1 + cp, Hp + 0.05, zP - cp - 0.05),
		"ledBlue",
		pal.fin
	)
	Kit.detail(
		m,
		"DeckRail",
		Vector3.new(x0 - cp + 0.3, deckY, zP - cp + 0.3),
		Vector3.new(x1 + cp - 0.3, deckY + KIT.railHeight, zP - cp + 0.6),
		RAIL
	)
	local names = City.signNames.towers
	local signW = math.min(SHAPE.signWidth, (x1 - x0) / 2 - 4)
	Kit.sign(
		m,
		"Name",
		Vector3.new(ccx - signW, G + 0.1, zP - brow.proud + 0.2),
		Vector3.new(ccx + signW, G + 2.6, zP - brow.proud + 0.6),
		Enum.NormalId.Front,
		names[rng:NextInteger(1, #names)],
		rgb(40, 44, 50),
		pal.fin,
		City.districtLooks.downtown.font
	)

	-------------------------------------------------------------------------------------------------------
	-- The pool deck: a lap pool and umbrellas beside the tower on a wide site, a pool in front where there's room
	-------------------------------------------------------------------------------------------------------
	if deckSide then
		local sx0 = cx1 + reach + 1
		Kit.pool(m, "LapPool", Vector3.new(sx0 + 1, 0, zP + 2), Vector3.new(sx0 + 6, 0, zB - 3), deckY)
		for i, uz in { zP + 6, zP + 16 } do
			Kit.umbrella(m, `Umbrella{i}`, sx0 + 12, uz, deckY, 6, if i == 1 then pal.fin else P.deco.aqua, true)
		end
	end
	local fz0, fz1 = zP + 1.8, cz0 - 1.8
	if fz1 - fz0 >= 2.5 then
		Kit.pool(m, "Pool", Vector3.new(cx0 + 8, 0, fz0), Vector3.new(cx1 - 8, 0, math.min(fz1, fz0 + 8)), deckY)
	end
end

local archetype: Types.Archetype = { id = "fin_column_tower", build = build }
return archetype
