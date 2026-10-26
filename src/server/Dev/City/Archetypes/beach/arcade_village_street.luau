--!strict
-- B12 arcade_village_street (docs/city/ARCHETYPES.md §6, B12): the beach's Mediterranean shop street. A two- or
-- three-storey row in warm stucco (peach, rose or buttercream) with cream trim: a cream belt course over the shop
-- storey, a corner quoin, punched windows, little iron balconies on the top floor, a red tile eave along the front and
-- a flat roof behind it. The shop storey is (rhythm 1) an arcade, square piers and arched heads in front of shops set
-- back in its shade, café lights strung along it; or (rhythm 2) shopfronts between cream pilasters under striped
-- awnings. At one end (crown 1) a belvedere tower: an arched opening under a tiled pyramid roof and a finial; or (crown
-- 2) a round-topped gable with an oculus over the middle of the row. Café umbrellas, bollards and a hanging blade sign
-- on the pavement.
--
-- What makes it itself: a warm stucco row with an arcade or striped awnings, iron balconies and red tile, a belvedere.
-- Placement, sizes, heights and its budget: Config/CityArchetypes/arcade_village_street.
-- Variants: palette (1 peach with coral awnings, 2 rose with teal, 3 buttercream with green), crown (1 the belvedere
-- tower at one end, 2 the round-topped gable in the middle), rhythm (1 the arcade, 2 awnings), mirror (the tower's end).
--
-- Previewing (the Studio helper): street view at eye height from the pavement, and a three-quarter view. Check that the
-- arch heads read as arches between the piers, that the awning stripes slope down toward the street, that the iron
-- rails show their bars (a see-through part with a bar texture), that the tower's pyramid roof points up (four corner
-- wedges) and sits over its eave, and that the tile eave's slope faces the street. At night: the café lights and the
-- shops glow warm, the belvedere's arched window glows, the wash lights the upper floors. Compare with photos of its
-- inspiration (ARCHETYPES.md B12).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local City = require(ReplicatedStorage.Shared.Config.City)
local Kit = require(script.Parent.Parent.Parent.Kit)
local Types = require(script.Parent.Parent.Parent.Types)

local P = City.palettes
local KIT = City.kit
local rgb = Color3.fromRGB

-- The recipe, in studs.
local SHAPE = {
	ground = 12, -- the shop storey
	floorMin = 9, -- upper floors are at least this tall...
	floors = { 2, 3 }, -- ...and this many
	front = 7, -- the pavement: the upper floors' face stands this far behind the front line
	sideInset = 1.2,
	bodyDepth = 34,
	arcade = 5, -- rhythm 1: the shops sit this far in behind the arcade's piers
	shopSet = 0.6, -- rhythm 2: the shop storey's face sits this far behind the upper floors'
	bay = 10, -- target bay width
	bays = { 3, 7 }, -- rhythm 1
	awningBays = { 3, 5 }, -- rhythm 2
	pier = { width = 1.8, proud = 0.5 },
	arch = 0.34, -- the arch heads' haunches: share of an opening's width
	pilaster = { width = 1, proud = 0.4 },
	awning = { stripes = 3, reach = 3.2, low = 4, high = 1.4 },
	belt = { thick = 0.8, proud = 0.5 },
	quoin = 1.4,
	eave = { proud = 1.6, rise = 2.8, back = 4 },
	balcony = { width = 6, proud = 2.2, thick = 0.6, rail = 3, bars = 0.7, max = 4 },
	window = 3.4, -- a punched window's tile: two to a bay on the row, one a floor on the tower
	tower = { width = { 0.16, 11, 14 }, proud = 1, rise = 2, stage = 8, ledge = 0.6, eave = 0.8, cap = 6, overhang = 1 },
	door = { width = 4.4, spring = 7.5 },
	gable = { width = 12, rise = 6, oculus = 2.6 }, -- crown 2
	lights = 0.35, -- the café lights' tube
	pavement = 0.3,
	umbrella = 5,
	bollards = 3,
	bollard = { diameter = 0.7, height = 2.6 },
	blade = { depth = 2.6, height = 3.5 },
}

-- Walls, trim, the awnings' two stripes, the blade sign's letters.
local PALETTES = {
	{
		wall = rgb(255, 184, 146),
		trim = rgb(250, 240, 222),
		awning = { rgb(238, 110, 96), rgb(250, 246, 238) },
		text = rgb(176, 70, 46),
	},
	{
		wall = rgb(236, 162, 156),
		trim = rgb(250, 240, 222),
		awning = { rgb(40, 150, 160), rgb(250, 246, 238) },
		text = rgb(30, 110, 118),
	},
	{
		wall = rgb(250, 220, 150),
		trim = rgb(252, 244, 228),
		awning = { rgb(62, 132, 92), rgb(250, 246, 238) },
		text = rgb(50, 110, 70),
	},
}

-- Ordinary shop words for the hanging sign (never a business's name).
local SHOP_WORDS = { "CAFE", "TAPAS", "GELATO", "LIBROS", "FLORES", "GALERIA" }

local TILE = Kit.look(rgb(181, 88, 58), Enum.Material.ClayRoofTiles)
local IRON = rgb(42, 42, 42)
local WARM = rgb(255, 214, 150)
local WASH = rgb(255, 190, 140)

local function build(m: Types.Model)
	local site = m.site
	local variant = site.variant
	local pal = PALETTES[math.clamp(variant.palette, 1, #PALETTES)]
	local hasTower = variant.crown ~= 2
	local arcade = variant.rhythm ~= 2
	local rng = Kit.rng(m)
	local W, D = site.width, site.depth
	local hw, hd = W / 2, D / 2
	local G = SHAPE.ground
	local up = math.clamp(math.floor((site.height - G) / SHAPE.floorMin), SHAPE.floors[1], SHAPE.floors[2])
	local f = (site.height - G) / up
	local H = G + up * f

	local wall = Kit.look(pal.wall, Enum.Material.SmoothPlastic)
	local trim = Kit.look(pal.trim, Enum.Material.SmoothPlastic)
	local terrazzo = Kit.look(P.deco.terrazzo, Enum.Material.SmoothPlastic)
	local dark = P.window.dark

	local x0, x1 = -hw + SHAPE.sideInset, hw - SHAPE.sideInset
	local zF = -hd + SHAPE.front
	local zB = math.min(hd - 1, zF + SHAPE.bodyDepth)
	local tw = math.clamp(W * SHAPE.tower.width[1], SHAPE.tower.width[2], SHAPE.tower.width[3])
	-- The row runs to the tower's far side (into it), or to the site's end.
	local rowEnd = if hasTower then x1 - tw else x1 -- where the row's front shows to
	local rowX1 = if hasTower then x1 - tw + 0.6 else x1
	local shopFace = if arcade then zF + SHAPE.arcade else zF + SHAPE.shopSet

	-------------------------------------------------------------------------------------------------------
	-- The row: the upper floors' stucco (their windows come with the bays, below), the shop storey, its glass, the belt
	-- course, the quoins, the roof
	-------------------------------------------------------------------------------------------------------
	Kit.box(m, "Upper", Vector3.new(x0, G, zF), Vector3.new(rowX1, H, zB), wall)
	Kit.box(
		m,
		"Shops",
		Vector3.new(x0 + 0.05, -KIT.bury, shopFace),
		Vector3.new(rowX1 - 0.05, G + 0.3, zB - 0.05),
		wall
	)
	local span = rowEnd - x0
	local range = if arcade then SHAPE.bays else SHAPE.awningBays
	local n = math.clamp(math.round(span / SHAPE.bay), range[1], range[2])
	Kit.glass(
		m,
		"ShopGlass",
		Vector3.new(x0 + 1, SHAPE.pavement, shopFace - 0.12),
		Vector3.new(rowEnd - 1, G - 2.2, shopFace + 0.3),
		dark,
		{
			image = City.textures.windowBold,
			faces = { Enum.NormalId.Front },
			u = span / n / 2,
			v = G - 2.2 - SHAPE.pavement,
			lines = pal.trim,
			lit = true,
		}
	)
	local bt = SHAPE.belt
	local beltEnd = if hasTower then rowEnd else x1 + bt.proud
	Kit.trim(
		m,
		"Belt",
		Vector3.new(x0 - bt.proud, G - bt.thick / 2, zF - bt.proud),
		Vector3.new(beltEnd, G + bt.thick / 2, zF + 0.6),
		trim
	)
	Kit.trim(
		m,
		"Quoin",
		Vector3.new(x0 - 0.3, G + bt.thick / 2, zF - 0.3),
		Vector3.new(x0 + SHAPE.quoin, H - 0.7, zF + 1),
		trim
	)
	if not hasTower then
		Kit.trim(
			m,
			"QuoinR",
			Vector3.new(x1 - SHAPE.quoin, G + bt.thick / 2, zF - 0.3),
			Vector3.new(x1 + 0.3, H - 0.7, zF + 1),
			trim
		)
	end
	-- The tile eave along the front, its slope to the street, and the flat roof behind it.
	local ev = SHAPE.eave
	local eaveEnd = if hasTower then rowEnd else x1 + 0.5
	Kit.wedge(
		m,
		"Eave",
		Vector3.new(x0 - 0.5, H - 0.6, zF - ev.proud),
		Vector3.new(eaveEnd, H + ev.rise, zF + ev.back),
		"back",
		TILE,
		"trim"
	)
	Kit.trim(
		m,
		"Roof",
		Vector3.new(x0 - 0.1, H - 0.2, zF + ev.back - 0.05),
		Vector3.new(if hasTower then rowX1 else x1 + 0.1, H + 0.4, zB + 0.1),
		trim
	)

	-------------------------------------------------------------------------------------------------------
	-- The shop storey: an arcade (rhythm 1) or striped awnings between pilasters (rhythm 2)
	-------------------------------------------------------------------------------------------------------
	local pierXs: { number } = {} -- the left edge of every pier or pilaster
	if arcade then
		local pr = SHAPE.pier
		local step = (span - pr.width) / n
		for i = 0, n do
			local px = x0 + i * step
			table.insert(pierXs, px)
			Kit.box(
				m,
				`Pier{i}`,
				Vector3.new(px, -KIT.bury, zF - pr.proud),
				Vector3.new(px + pr.width, G + 0.2, zF + 1.4),
				wall
			)
		end
		for k = 1, n do
			local ox0, ox1 = pierXs[k] + pr.width, pierXs[k + 1]
			Kit.archHead(m, `Arch{k}`, ox0, ox1, G, zF - 0.05, zF + 1.4, (ox1 - ox0) * SHAPE.arch, wall)
		end
		-- The loggia's ceiling, over the punched floor's underside.
		Kit.trim(
			m,
			"Soffit",
			Vector3.new(x0 + 0.1, G - 0.2, zF + 0.6),
			Vector3.new(rowEnd - 0.1, G + 0.1, shopFace + 0.1),
			trim
		)
		-- Café lights strung along the arcade at the arches' springing.
		local yL = G - (step - pr.width) * SHAPE.arch - 0.5
		Kit.neon(
			m,
			"Lights",
			Vector3.new(x0 + 1, yL, zF - pr.proud - 0.25),
			Vector3.new(rowEnd - 1, yL, zF - pr.proud - 0.25),
			"neonAmber",
			WARM,
			SHAPE.lights
		)
	else
		local pl = SHAPE.pilaster
		local step = (span - pl.width) / n
		for i = 0, n do
			local px = x0 + i * step
			table.insert(pierXs, px)
			Kit.trim(
				m,
				`Pilaster{i}`,
				Vector3.new(px, 0, zF - pl.proud),
				Vector3.new(px + pl.width, G - bt.thick / 2, shopFace + 0.3),
				trim
			)
		end
		local aw = SHAPE.awning
		for k = 1, n do
			local ax0, ax1 = pierXs[k] + pl.width + 0.3, pierXs[k + 1] - 0.3
			local sw = (ax1 - ax0) / aw.stripes
			for j = 1, aw.stripes do
				local look = Kit.look(pal.awning[(j - 1) % 2 + 1], Enum.Material.SmoothPlastic)
				Kit.wedge(
					m,
					`Awning{k}x{j}`,
					Vector3.new(ax0 + (j - 1) * sw, G - aw.low, zF - aw.reach),
					Vector3.new(ax0 + j * sw, G - aw.high, shopFace + 0.05),
					"back",
					look,
					"trim"
				)
			end
		end
		-- Café lights along the belt course.
		Kit.neon(
			m,
			"Lights",
			Vector3.new(x0 + 1, G + 0.9, zF - bt.proud - 0.25),
			Vector3.new(rowEnd - 1, G + 0.9, zF - bt.proud - 0.25),
			"neonAmber",
			WARM,
			SHAPE.lights
		)
	end

	-------------------------------------------------------------------------------------------------------
	-- Windows: a pair over every bay on every upper floor, plenty of stucco between (one punched strip per bay, its top
	-- on the roof line so the tiles fall per floor)
	-------------------------------------------------------------------------------------------------------
	local pierW = if arcade then SHAPE.pier.width else SHAPE.pilaster.width
	local pane = SHAPE.window
	for k = 1, n do
		local wx = (pierXs[k] + pierXs[k + 1]) / 2 + pierW / 2
		Kit.punched(
			m,
			`Windows{k}`,
			Vector3.new(wx - pane, G + bt.thick / 2, zF - 0.06),
			Vector3.new(wx + pane, H, zF + 0.3),
			pal.wall,
			dark,
			{ Enum.NormalId.Front },
			pane,
			f,
			k == 2
		)
	end

	-------------------------------------------------------------------------------------------------------
	-- Iron balconies on the top floor, centred on bays
	-------------------------------------------------------------------------------------------------------
	local bc = SHAPE.balcony
	local nb = math.clamp(n - 2, 2, bc.max)
	local yb = G + (up - 1) * f
	local half = bc.width / 2
	for b = 1, nb do
		local k = math.clamp(math.round(b * (n + 1) / (nb + 1)), 1, n)
		local bx = (pierXs[k] + pierXs[k + 1]) / 2 + pierW / 2
		Kit.trim(
			m,
			`Balcony{b}`,
			Vector3.new(bx - half, yb - bc.thick, zF - bc.proud),
			Vector3.new(bx + half, yb, zF + 0.4),
			trim
		)
		local rail = Kit.detail(
			m,
			`Rail{b}`,
			Vector3.new(bx - half + 0.1, yb, zF - bc.proud + 0.05),
			Vector3.new(bx + half - 0.1, yb + bc.rail, zF - bc.proud + 0.25),
			Kit.look(IRON, Enum.Material.Metal, 0, 1)
		)
		rail.textures = {
			{ face = Enum.NormalId.Front, image = City.textures.windowBold, u = bc.bars, v = bc.rail, color = IRON },
		}
	end

	-------------------------------------------------------------------------------------------------------
	-- The belvedere tower at one end (crown 1), or a round-topped gable over the middle (crown 2)
	-------------------------------------------------------------------------------------------------------
	if hasTower then
		local tr = SHAPE.tower
		local tx0, tx1 = x1 - tw, x1
		local tz0 = zF - tr.proud
		local tz1 = math.min(zB, tz0 + tw)
		local tcx = (tx0 + tx1) / 2
		local shaftTop = H + tr.rise
		Kit.box(m, "Tower", Vector3.new(tx0, -KIT.bury, tz0), Vector3.new(tx1, shaftTop, tz1), wall)
		-- One window a floor up its front and up its street side.
		local tzc = (tz0 + tz1) / 2
		local wh = SHAPE.window / 2
		Kit.punched(
			m,
			"TowerWindows",
			Vector3.new(tcx - wh, G + 0.4, tz0 - 0.06),
			Vector3.new(tcx + wh, H, tz0 + 0.3),
			pal.wall,
			dark,
			{ Enum.NormalId.Front },
			SHAPE.window,
			f
		)
		Kit.punched(
			m,
			"TowerSideWindows",
			Vector3.new(tx1 - 0.3, G + 0.4, tzc - wh),
			Vector3.new(tx1 + 0.06, H, tzc + wh),
			pal.wall,
			dark,
			{ Enum.NormalId.Right },
			SHAPE.window,
			f
		)
		local dr = SHAPE.door
		Kit.archWindow(
			m,
			"TowerDoor",
			tcx - dr.width / 2,
			tcx + dr.width / 2,
			SHAPE.pavement,
			dr.spring,
			tz0,
			dark,
			{ lit = true }
		)
		local lg = tr.ledge
		local stageTop = shaftTop + tr.stage
		Kit.box(
			m,
			"Belvedere",
			Vector3.new(tx0 + lg, shaftTop - 0.1, tz0 + lg),
			Vector3.new(tx1 - lg, stageTop, tz1 - lg),
			wall
		)
		local ow = math.min(4.8, tw - 2 * lg - 4)
		Kit.archWindow(
			m,
			"Lookout",
			tcx - ow / 2,
			tcx + ow / 2,
			shaftTop + 1,
			stageTop - ow / 2 - 1,
			tz0 + lg,
			dark,
			{ lit = true }
		)
		Kit.trim(
			m,
			"TowerEave",
			Vector3.new(tx0 - 0.2, stageTop, tz0 - 0.2),
			Vector3.new(tx1 + 0.2, stageTop + tr.eave, tz1 + 0.2),
			trim
		)
		local roofBase = stageTop + tr.eave
		Kit.hipRoof(
			m,
			"TowerRoof",
			Vector3.new(tx0 + lg, roofBase, tz0 + lg),
			Vector3.new(tx1 - lg, roofBase + tr.cap, tz1 - lg),
			tr.overhang,
			0.6,
			TILE
		)
		Kit.ball(m, "Finial", Vector3.new(tcx, roofBase + tr.cap + 0.5, (tz0 + tz1) / 2), 1, trim)
	else
		local gb = SHAPE.gable
		local gx = (x0 + x1) / 2
		local gTop = H + gb.rise
		Kit.box(
			m,
			"Gable",
			Vector3.new(gx - gb.width / 2, H - 0.2, zF - 0.3),
			Vector3.new(gx + gb.width / 2, gTop, zF + 1.2),
			wall
		)
		-- Its round top: a disc whose lower half sinks into the gable, set a hair behind the gable's face.
		Kit.tube(
			m,
			"GableTop",
			Vector3.new(gx, gTop, zF - 0.25),
			Vector3.new(gx, gTop, zF + 1.15),
			gb.width,
			wall,
			"trim"
		)
		Kit.porthole(m, "Oculus", gx, H + gb.rise * 0.6, zF - 0.3, gb.oculus, dark, trim)
		Kit.ball(m, "Finial", Vector3.new(gx, gTop + gb.width / 2 + 0.5, zF + 0.45), 1, trim)
	end

	-------------------------------------------------------------------------------------------------------
	-- The pavement: terrazzo, market umbrellas, bollards, a hanging blade sign, and the wash
	-------------------------------------------------------------------------------------------------------
	Kit.box(
		m,
		"Pavement",
		Vector3.new(-hw + 0.2, 0, -hd + 0.3),
		Vector3.new(hw - 0.2, SHAPE.pavement, shopFace + 0.3),
		terrazzo
	)
	local uz = -hd + 2.8
	for i, at in { -0.45, 0.2 } do
		local color = if i == 1 then pal.awning[1] else pal.trim
		Kit.umbrella(m, `Umbrella{i}`, at * hw, uz, SHAPE.pavement, SHAPE.umbrella, color, true)
	end
	local bl = SHAPE.bollard
	for k = 1, SHAPE.bollards do
		local x = -hw + 3 + (W - 6) * (k - 0.5) / SHAPE.bollards
		Kit.column(m, `Bollard{k}`, x, -hd + 0.9, -0.5, bl.height, bl.diameter, Kit.look(IRON, Enum.Material.Metal))
	end
	local bd = SHAPE.blade
	local bx = pierXs[2] + (if arcade then SHAPE.pier.width else SHAPE.pilaster.width) / 2 -- on the second pier
	Kit.sign(
		m,
		"Blade",
		Vector3.new(bx - 0.15, G - 1 - bd.height, zF - bt.proud - bd.depth),
		Vector3.new(bx + 0.15, G - 1, zF - bt.proud),
		Enum.NormalId.Left,
		SHOP_WORDS[rng:NextInteger(1, #SHOP_WORDS)],
		pal.trim,
		pal.text,
		City.districtLooks.beach.font
	)
	-- On the belt course, washing the upper floors and the balconies.
	Kit.wash(m, "Wash", x0 + 2, rowEnd - 2, zF - 0.2, G + bt.thick / 2 + 0.02, WASH)
end

local archetype: Types.Archetype = { id = "arcade_village_street", build = build }
return archetype
