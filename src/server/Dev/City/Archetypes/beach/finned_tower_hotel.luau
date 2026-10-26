--!strict
-- B08 finned_tower_hotel (docs/city/ARCHETYPES.md §6, B08): the beach avenue's all-white mid-century hotel slab. The slab
-- steps down from a full-height centre block to two lower wings (one lower than the other), each wing's top floor set
-- back, its face broken by projecting window bays; the lobby storey sits in under the slab. A tower stands 4 proud up
-- the middle of the front, a glowing window slot running up it, and breaks out above the roof into a square shaft
-- with the name on its face and its signature crown of fins: (crown 1) a thin front blade coming down the tower and
-- two side wings, each sweeping up to a point like a 1940s tail fin; (crown 2) two pairs of fins stepping out sideways
-- from the shaft's front and back corners in three tiers, under a lit ring. A porte-cochère on slim columns, a forecourt with planters.
--
-- What makes it itself: an all-white slab whose central tower breaks out above the roof into a crown of fins.
-- Placement, sizes, heights and its budget: Config/CityArchetypes/finned_tower_hotel.
-- Variants: palette (1 all white, 2 the slot fins and LEDs in sky, 3 warm white with mint), crown (1 swept blade and
-- wings, 2 stepped side fins), rhythm (1 one bay per wing and wings 2 and 3 floors lower, 2 two bays per wing and wings
-- 3 and 5 floors lower), mirror (which wing is the lower one).
--
-- Previewing (the Studio helper): a mid view from about 250 studs and a street view at eye height. Check that the
-- crown reads as fins (crown 1: the side wings' tips point up and outward, the blade's tip forward; crown 2: steps
-- falling outward), that the wings step down unevenly, that the bays stand proud with windows round their sides, and
-- that the slot stops under the blade. At night: the slot and lobby glow, the fin edges (crown 1) or the shaft ring
-- (crown 2) glow cool white, the canopy edge blue, and the wash lights the shaft and the name. Compare with photos of
-- its inspiration (ARCHETYPES.md B08).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local City = require(ReplicatedStorage.Shared.Config.City)
local Kit = require(script.Parent.Parent.Parent.Kit)
local Types = require(script.Parent.Parent.Parent.Types)

local P = City.palettes
local KIT = City.kit
local rgb = Color3.fromRGB

-- The recipe, in studs.
local SHAPE = {
	ground = 16, -- the lobby storey, set in under the slab
	floorMin = 11,
	terrace = 9, -- the forecourt: the slab's face stands this far behind the front line
	sideInset = 1.5,
	lobbyInset = 3, -- the lobby storey sits this far in under the slab's face
	tower = { width = { 0.2, 14, 18 }, proud = 4, back = 2 },
	centre = { 0.22, 13, 20 }, -- the full-height centre block's half width: share of the width, clamped
	steps = { { 2, 3 }, { 3, 5 } }, -- by rhythm: floors the left and the right wing stand lower than the centre
	bays = { 1, 2 }, -- by rhythm: window bays per wing
	setback = 4, -- a wing's top floor sits this far back from its face...
	setbackSide = 3, -- ...and in from its outer side
	bay = { width = 7, proud = 2.2 },
	windowBay = 6,
	cornice = { thick = 1.2, proud = 0.8 },
	slot = { half = 1.6, fin = 0.8, proud = 0.9 },
	shaft = { size = 12, back = 4.5, cap = 1.2 }, -- above the roof; its face this far behind the tower's
	rise = { 33, 32 }, -- by crown: the shaft above the roof
	blade = { half = 0.7, floors = 2, tip = 6, proud = 0.6 }, -- crown 1: comes down the tower this many floors
	wing = { reach = 10, half = 0.7, low = 6, tip = 4 }, -- crown 1: the side wings
	backFin = { reach = 6, low = 8 },
	-- Crown 2: stepped fins reaching out sideways from the shaft's front and back corners, three steps each, stacked:
	-- how far each reaches past the shaft, where its top stands against the shaft's top, and its half thickness (each
	-- step a little thinner than the one under it, so their faces never share a plane).
	finSteps = {
		{ reach = 12, top = -13, half = 0.75 },
		{ reach = 7.5, top = -3, half = 0.66 },
		{ reach = 3.5, top = 5, half = 0.58 },
	},
	finSet = 1.6, -- crown 2: the front pair of fins stands this far behind the shaft's face
	canopy = { y = 12.5, thick = 1.2, past = 6 }, -- reaches this far past the tower each side
	column = 1.2,
	forecourt = 0.4,
	planter = 1.6,
}

-- Body, accent (slot fins, LEDs by day), the name's colour and the wash's.
local PALETTES = {
	{ body = P.frame.white, accent = P.frame.white, text = rgb(150, 162, 176), wash = rgb(170, 200, 255) },
	{ body = P.frame.white, accent = P.deco.sky, text = rgb(70, 150, 196), wash = rgb(140, 190, 255) },
	{ body = rgb(250, 246, 236), accent = P.deco.mint, text = rgb(60, 150, 120), wash = rgb(130, 236, 200) },
}

local function share(size: number, rule: { number }): number
	return math.clamp(size * rule[1], rule[2], rule[3])
end

local function build(m: Types.Model)
	local site = m.site
	local variant = site.variant
	local pal = PALETTES[math.clamp(variant.palette, 1, #PALETTES)]
	local crown = math.clamp(variant.crown, 1, 2)
	local rhythm = math.clamp(variant.rhythm, 1, 2)
	local rng = Kit.rng(m)
	local W, D = site.width, site.depth
	local hw, hd = W / 2, D / 2
	local G = SHAPE.ground
	local up = math.max(6, math.floor((site.height - G) / SHAPE.floorMin))
	local f = (site.height - G) / up
	local H = G + up * f

	local body = Kit.look(pal.body, Enum.Material.SmoothPlastic)
	local accent = Kit.look(pal.accent, Enum.Material.SmoothPlastic)
	local terrazzo = Kit.look(P.deco.terrazzo, Enum.Material.SmoothPlastic)
	local dark = P.window.dark

	local x0, x1 = -hw + SHAPE.sideInset, hw - SHAPE.sideInset
	local zF = -hd + SHAPE.terrace
	local zB = hd - 1
	local tx = share(W, SHAPE.tower.width) / 2
	local cw = math.max(share(W, SHAPE.centre), tx + 4)
	local zT = zF - SHAPE.tower.proud -- the tower's face

	-------------------------------------------------------------------------------------------------------
	-- The lobby storey under the slab, the masses above it: a full-height centre and two stepped wings
	-------------------------------------------------------------------------------------------------------
	local li = SHAPE.lobbyInset
	Kit.box(m, "Base", Vector3.new(x0 + 0.6, -KIT.bury, zF + li), Vector3.new(x1 - 0.6, G + 0.3, zB - 0.6), body)
	Kit.glass(m, "Lobby", Vector3.new(x0 + 3, 0.4, zF + li - 0.12), Vector3.new(x1 - 3, G - 1.5, zF + li + 0.3), dark, {
		image = City.textures.windowBold,
		faces = { Enum.NormalId.Front },
		u = 6,
		v = G - 1.9,
		lines = pal.body,
		lit = true,
	})

	-- Punched walls with their tops on floor lines, so every tile is one window on one floor.
	local walls = { Enum.NormalId.Front, Enum.NormalId.Back, Enum.NormalId.Left, Enum.NormalId.Right }
	Kit.punched(m, "Centre", Vector3.new(-cw, G, zF), Vector3.new(cw, H, zB), pal.body, dark, walls, SHAPE.windowBay, f)
	local cor = SHAPE.cornice
	Kit.trim(
		m,
		"Cornice",
		Vector3.new(-cw - cor.proud, H - cor.thick + 0.06, zF - cor.proud),
		Vector3.new(cw + cor.proud, H + 0.06, zB + cor.proud),
		body
	)

	local steps = SHAPE.steps[rhythm]
	local bays = SHAPE.bays[rhythm]
	local wingTops: { number } = {}
	for i, side in { -1, 1 } do
		local outer = if side < 0 then x0 else x1
		local inner = side * cw
		local wa, wb = math.min(outer, inner), math.max(outer, inner)
		local top = G + (up - steps[i]) * f -- the set-back top floor's roof
		local low = top - f -- the main mass's roof
		wingTops[i] = top
		local outerFace = if side < 0 then Enum.NormalId.Left else Enum.NormalId.Right
		local faces = { Enum.NormalId.Front, Enum.NormalId.Back, outerFace }
		Kit.punched(
			m,
			`Wing{i}`,
			Vector3.new(wa, G, zF),
			Vector3.new(wb, low, zB),
			pal.body,
			dark,
			faces,
			SHAPE.windowBay,
			f
		)
		-- Its top floor set back from the face and in from the outer side.
		local sa = if side < 0 then wa + SHAPE.setbackSide else wa
		local sb = if side < 0 then wb else wb - SHAPE.setbackSide
		Kit.punched(
			m,
			`WingTop{i}`,
			Vector3.new(sa, low, zF + SHAPE.setback),
			Vector3.new(sb, top, zB - 1),
			pal.body,
			dark,
			faces,
			SHAPE.windowBay,
			f
		)
		-- Cornices: the wing's, reaching into the centre block, and the set-back floor's.
		local ca = if side < 0 then wa - cor.proud else wa - 0.5
		local cb = if side < 0 then wb + 0.5 else wb + cor.proud
		Kit.trim(
			m,
			`WingCornice{i}`,
			Vector3.new(ca, low - cor.thick + 0.06, zF - cor.proud),
			Vector3.new(cb, low + 0.06, zB + cor.proud),
			body
		)
		local ta = if side < 0 then sa - cor.proud else sa - 0.5
		local tb = if side < 0 then sb + 0.5 else sb + cor.proud
		Kit.trim(
			m,
			`WingTopCornice{i}`,
			Vector3.new(ta, top - cor.thick + 0.06, zF + SHAPE.setback - cor.proud),
			Vector3.new(tb, top + 0.06, zB - 1 + cor.proud),
			body
		)
		-- Projecting window bays up the wing's face, windows round their sides, stopping a floor under its roof.
		local span = wb - wa
		local bw = math.min(SHAPE.bay.width, span / bays - 1.2)
		for j = 1, bays do
			local bx = wa + span * (j - 0.5) / bays
			Kit.punched(
				m,
				`Bay{i}{j}`,
				Vector3.new(bx - bw / 2, G, zF - SHAPE.bay.proud),
				Vector3.new(bx + bw / 2, low - f, zF + 0.5),
				pal.body,
				dark,
				{ Enum.NormalId.Front, Enum.NormalId.Left, Enum.NormalId.Right },
				bw / 2,
				f
			)
		end
	end
	-- A stair house on the higher wing's roof.
	local hi = if wingTops[1] > wingTops[2] then 1 else 2
	local hx = if hi == 1 then x0 + 6 else x1 - 6
	Kit.roofBox(
		m,
		"Stair",
		Vector3.new(hx - 3, wingTops[hi], zB - 10),
		Vector3.new(hx + 3, wingTops[hi] + 6, zB - 4),
		body
	)

	-------------------------------------------------------------------------------------------------------
	-- The tower up the front: a glowing slot between two fins, the entrance at its foot
	-------------------------------------------------------------------------------------------------------
	Kit.box(m, "Tower", Vector3.new(-tx, -KIT.bury, zT), Vector3.new(tx, H, zF + SHAPE.tower.back), body)
	local bl = SHAPE.blade
	local slotTop = H - 3
	local sh = SHAPE.slot
	Kit.glass(m, "Slot", Vector3.new(-sh.half, G + 2, zT - 0.12), Vector3.new(sh.half, slotTop, zT + 0.3), dark, {
		image = City.textures.windowBold,
		faces = { Enum.NormalId.Front },
		u = 2 * sh.half,
		v = f,
		lines = pal.body,
		lit = true,
	})
	for i, side in { -1, 1 } do
		local a, b = side * sh.half, side * (sh.half + sh.fin)
		Kit.trim(
			m,
			`SlotFin{i}`,
			Vector3.new(math.min(a, b), G + 1, zT - sh.proud),
			Vector3.new(math.max(a, b), slotTop + 1, zT + 0.3),
			accent
		)
	end
	Kit.glass(m, "Door", Vector3.new(-tx + 2, 0.4, zT - 0.12), Vector3.new(tx - 2, 11.6, zT + 0.3), dark, {
		image = City.textures.windowBold,
		faces = { Enum.NormalId.Front },
		u = 2.5,
		v = 11.2,
		lines = pal.body,
		lit = true,
	})

	-------------------------------------------------------------------------------------------------------
	-- The shaft above the roof, the name on its face, and the crown of fins
	-------------------------------------------------------------------------------------------------------
	local rise = SHAPE.rise[crown]
	local sx = SHAPE.shaft.size / 2
	local zS0 = zT + SHAPE.shaft.back -- the shaft's face
	local zS1 = zS0 + SHAPE.shaft.size
	local zSc = (zS0 + zS1) / 2
	local crownTop = H + rise
	Kit.box(m, "Shaft", Vector3.new(-sx, H - 0.3, zS0), Vector3.new(sx, crownTop, zS1), body)
	Kit.trim(
		m,
		"ShaftCap",
		Vector3.new(-sx - 0.6, crownTop, zS0 - 0.6),
		Vector3.new(sx + 0.6, crownTop + SHAPE.shaft.cap, zS1 + 0.6),
		body
	)
	local names = City.signNames.hotels
	-- Crown 1's blade stands on the shaft's front left edge, so the name sits to its right.
	local nameLeft = if crown == 1 then -sx + 2 * bl.half + 0.8 else -sx + 0.8
	Kit.sign(
		m,
		"Name",
		Vector3.new(nameLeft, crownTop - 9, zS0 - 0.4),
		Vector3.new(sx - 0.8, crownTop - 2.5, zS0 - 0.06),
		Enum.NormalId.Front,
		names[rng:NextInteger(1, #names)],
		pal.body,
		pal.text,
		City.districtLooks.beach.font
	)
	if crown == 1 then
		-- The blade: on the shaft's front left edge, down the tower's face for two floors and up past the shaft, its
		-- tip raked up toward the street.
		local bx0, bx1 = -sx, -sx + 2 * bl.half
		local bz0 = zT - bl.proud
		local bladeTop = crownTop - 2
		local bladeFoot = H - bl.floors * f
		Kit.trim(m, "Blade", Vector3.new(bx0, bladeFoot, bz0), Vector3.new(bx1, bladeTop, zS0 + 0.5), body)
		Kit.wedge(
			m,
			"BladeTip",
			Vector3.new(bx0, bladeTop, bz0),
			Vector3.new(bx1, bladeTop + bl.tip, zS0 + 0.5),
			"front",
			body,
			"trim"
		)
		local bxc = (bx0 + bx1) / 2
		Kit.neonStrip(
			m,
			"BladeLed",
			Vector3.new(bxc - 0.3, bladeFoot + 1, bz0 - 0.15),
			Vector3.new(bxc + 0.3, bladeTop - 0.4, bz0 + 0.02),
			"crown",
			pal.accent
		)
		-- The side wings, sweeping up to points over their outer ends.
		local wg = SHAPE.wing
		for i, side in { -1, 1 } do
			local outer = side * (sx + wg.reach)
			local a, b = math.min(outer, side * (sx - 0.3)), math.max(outer, side * (sx - 0.3))
			local wingTop = crownTop - wg.low
			Kit.trim(
				m,
				`Wing{i}Fin`,
				Vector3.new(a, H - 0.3, zSc - wg.half),
				Vector3.new(b, wingTop, zSc + wg.half),
				body
			)
			local toward: Kit.Side = if side < 0 then "left" else "right"
			Kit.wedge(
				m,
				`Wing{i}Tip`,
				Vector3.new(a, wingTop, zSc - wg.half),
				Vector3.new(b, wingTop + wg.low + wg.tip, zSc + wg.half),
				toward,
				body,
				"trim"
			)
			local ea, eb = outer - side * 0.05, outer + side * 0.15
			Kit.neonStrip(
				m,
				`Wing{i}Led`,
				Vector3.new(math.min(ea, eb), H + 1, zSc - 0.3),
				Vector3.new(math.max(ea, eb), wingTop - 0.4, zSc + 0.3),
				"crown",
				pal.accent
			)
		end
		Kit.trim(
			m,
			"BackFin",
			Vector3.new(-bl.half, H - 0.3, zS1 - 0.3),
			Vector3.new(bl.half, crownTop - SHAPE.backFin.low, zS1 + SHAPE.backFin.reach),
			body
		)
	else
		-- Two pairs of stepped fins, one pair at the shaft's front corners and one at its back, each reaching out
		-- sideways in three steps that fall outward like a stepped tail fin (the face stays clear for the name), under a
		-- lit ring round the shaft.
		-- The front pair stands back from the shaft's face, so the face throws a shadow line on it; the back pair sits a
		-- hair inside the shaft's back.
		local first = SHAPE.finSteps[1].half
		for j, zc in { zS0 + first + SHAPE.finSet, zS1 - first - 0.1 } do
			for i, side in { -1, 1 } do
				local y0 = H - 0.3
				for k, step in SHAPE.finSteps do
					local top = crownTop + step.top
					local a, b = side * (sx - 0.3), side * (sx + step.reach)
					Kit.trim(
						m,
						`Fin{j}{i}Step{k}`,
						Vector3.new(math.min(a, b), y0, zc - step.half),
						Vector3.new(math.max(a, b), top, zc + step.half),
						body
					)
					y0 = top - 0.1
				end
			end
		end
		Kit.neonStrip(
			m,
			"CrownRing",
			Vector3.new(-sx - 0.15, crownTop - 1.4, zS0 - 0.15),
			Vector3.new(sx + 0.15, crownTop - 1, zS1 + 0.15),
			"crown",
			pal.accent
		)
	end
	-- A plant room on the centre roof behind the crown.
	Kit.roofBox(m, "Plant", Vector3.new(-cw + 2, H, zS1 + 9), Vector3.new(cw - 2, H + 5, zB - 2), body)

	-------------------------------------------------------------------------------------------------------
	-- The porte-cochère, the forecourt and its planters, the wash
	-------------------------------------------------------------------------------------------------------
	local cp = SHAPE.canopy
	local cwC = tx + cp.past
	Kit.canopy(m, "Canopy", -cwC, cwC, -hd + 1, zT + 0.1, cp.y, cp.thick, body)
	Kit.neonStrip(
		m,
		"CanopyLed",
		Vector3.new(-cwC, cp.y - 0.25, -hd + 0.85),
		Vector3.new(cwC, cp.y - 0.05, -hd + 1.05),
		"ledBlue",
		pal.accent
	)
	for i, side in { -1, 1 } do
		Kit.column(m, `Column{i}`, side * (cwC - 1.2), -hd + 2.2, -KIT.bury, cp.y, SHAPE.column, body)
	end
	Kit.box(
		m,
		"Forecourt",
		Vector3.new(-hw + 0.2, 0, -hd + 0.3),
		Vector3.new(hw - 0.2, SHAPE.forecourt, zF + li + 0.3),
		terrazzo
	)
	for i, side in { -1, 1 } do
		local a, b = side * (cwC + 2), side * (hw - 1.5)
		Kit.planter(
			m,
			`Planter{i}`,
			Vector3.new(math.min(a, b), SHAPE.forecourt, -hd + 0.8),
			Vector3.new(math.max(a, b), SHAPE.forecourt + SHAPE.planter, -hd + 2.6),
			body
		)
	end
	-- On the tower's top ledge beside the blade, washing the shaft, the name and the fins.
	Kit.wash(m, "Wash", 1.2, sx - 0.2, zT + 2, H + 0.02, pal.wash)
end

local archetype: Types.Archetype = { id = "finned_tower_hotel", build = build }
return archetype
