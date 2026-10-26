--!strict
-- B12 arcade_village_street (docs/city/ARCHETYPES.md §6, B12): the beach's Mediterranean shop street. A two- or
-- three-storey row in warm stucco (peach, rose or buttercream) under a low hipped roof of red barrel tile with deep
-- eaves; a cream belt course over the shop storey, cream quoins, paired windows, little iron balconies on the top floor.
-- The shop storey is (rhythm 1) an arcade, square piers carrying cream arch heads with shops set back in its shade, or
-- (rhythm 2) a stucco wall of arched shop windows; either way a striped awning hangs in every arch and café lights run
-- along it. At one end (crown 1) a belvedere tower rises through the roof: an oculus, an open loggia of arches on its
-- top (a warm glow behind them at night), a tiled pyramid roof and a finial; or (crown 2) a round-topped gable with an
-- oculus stands over the middle of the row. Market umbrellas and a hanging blade sign on the pavement.
--
-- What makes it itself: a warm stucco row of arches with a striped awning in each, iron balconies, red tile and a
-- belvedere.
-- Placement, sizes, heights and its budget: Config/CityArchetypes/arcade_village_street.
-- Variants: palette (1 peach with coral awnings, 2 rose with teal, 3 buttercream with green), crown (1 the belvedere
-- tower at one end, 2 the round-topped gable over the middle), rhythm (1 the open arcade, 2 arched shop windows in a
-- wall), mirror (the tower's end).
--
-- Previewing (the Studio helper): street view at eye height from the pavement, and a three-quarter view. Check that
-- the arch heads read as arches between the piers (cream haunches cut at 45 degrees), that every awning's stripes slope
-- down toward the street from the arch's springing, that the hipped roof's eaves overhang the walls all round with no
-- gap at the corners (four corner wedges and two slopes), that the tower's loggia reads open (piers, haunches, the core
-- set back) under a pyramid that points up, and that the iron rails show their bars (a see-through part with a bar
-- texture). At night: the café lights and the shops glow warm, the loggia glows amber, the wash lights the upper floors.
-- Compare with photos of its inspiration (ARCHETYPES.md B12).

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
	sideInset = 1.7, -- the eaves overhang the side walls, so the walls keep this far in
	bodyDepth = 34,
	arcade = 5, -- rhythm 1: the shops sit this far in behind the arcade's piers
	shopSet = 0.6, -- rhythm 2: the shop storey's face sits this far behind the upper floors'
	bay = 10, -- target bay width
	bays = { 3, 6 },
	pier = { width = 1.8, proud = 0.5 },
	arch = 0.36, -- the arch heads' haunches: share of an opening's width
	shopArch = { width = 8, margin = 1, head = 1 }, -- rhythm 2: the arched windows, at most this wide, their heads this
	-- far under the belt
	awning = { stripes = 3, reach = 2.6, drop = 2.6 }, -- out from the arch's springing, falling this far
	belt = { thick = 0.8, proud = 0.5 },
	quoin = 1.4,
	roof = { rise = 6, overhang = 1.4, thick = 0.6 }, -- the hipped tile roof over the row
	balcony = { width = 6, proud = 2.2, thick = 0.6, rail = 3, bars = 0.7, max = 4 },
	window = 3.4, -- a punched window's tile: two to a bay on the row, one a floor on the tower
	tower = {
		width = { 0.16, 11, 14 },
		proud = 1,
		rise = 7, -- its shaft over the row's eave line
		stage = 8, -- the loggia
		post = 0.24, -- the loggia's corner piers: share of the tower's width
		core = 1.6, -- the loggia's core sits this far in from its piers' faces
		eave = 0.8,
		cap = 5,
		overhang = 1.2,
		oculus = 2.6,
	},
	door = { width = 4.4, spring = 7.5 },
	gable = { width = 12, rise = 6.5, oculus = 2.6 }, -- crown 2
	lights = 0.35, -- the café lights' tube
	pavement = 0.3,
	umbrella = 5,
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
local CORE = Kit.look(rgb(92, 72, 60), Enum.Material.SmoothPlastic)

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
	local stripes = {
		Kit.look(pal.awning[1], Enum.Material.SmoothPlastic),
		Kit.look(pal.awning[2], Enum.Material.SmoothPlastic),
	}

	local x0, x1 = -hw + SHAPE.sideInset, hw - SHAPE.sideInset
	local zF = -hd + SHAPE.front
	local zB = math.min(hd - 0.2 - SHAPE.roof.overhang, zF + SHAPE.bodyDepth) -- the eaves overhang the back too
	local tw = math.clamp(W * SHAPE.tower.width[1], SHAPE.tower.width[2], SHAPE.tower.width[3])
	-- The row runs to the tower's far side (into it), or to the site's end.
	local rowEnd = if hasTower then x1 - tw else x1 -- where the row's front shows to
	local rowX1 = if hasTower then x1 - tw + 0.6 else x1
	local shopFace = if arcade then zF + SHAPE.arcade else zF + SHAPE.shopSet

	-- A striped awning across x0..x1, hung on the plane z at height y and falling toward the street.
	local function awning(name: string, ax0: number, ax1: number, z: number, y: number)
		local aw = SHAPE.awning
		local sw = (ax1 - ax0) / aw.stripes
		for j = 1, aw.stripes do
			Kit.wedge(
				m,
				`{name}x{j}`,
				Vector3.new(ax0 + (j - 1) * sw, y - aw.drop, z - aw.reach),
				Vector3.new(ax0 + j * sw, y, z),
				"back",
				stripes[(j - 1) % 2 + 1],
				"trim"
			)
		end
	end

	-------------------------------------------------------------------------------------------------------
	-- The row: the upper floors' stucco (their windows come with the bays, below), the shop storey, the belt course,
	-- the quoins, the hipped tile roof
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
	local n = math.clamp(math.round(span / SHAPE.bay), SHAPE.bays[1], SHAPE.bays[2])
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
	local rf = SHAPE.roof
	Kit.hipRoof(m, "Roof", Vector3.new(x0, H, zF), Vector3.new(rowX1, H + rf.rise, zB), rf.overhang, rf.thick, TILE)

	-------------------------------------------------------------------------------------------------------
	-- The shop storey: an arcade (rhythm 1) or arched shop windows in a wall (rhythm 2), a striped awning in every arch
	-------------------------------------------------------------------------------------------------------
	local pierW = SHAPE.pier.width
	local step = (span - pierW) / n
	local pierXs: { number } = {} -- the left edge of every pier (rhythm 2: of every bay's dividing line)
	for i = 0, n do
		table.insert(pierXs, x0 + i * step)
	end
	local yLights: number
	if arcade then
		local pr = SHAPE.pier
		Kit.glass(
			m,
			"ShopGlass",
			Vector3.new(x0 + 1, SHAPE.pavement, shopFace - 0.12),
			Vector3.new(rowEnd - 1, G - 2.2, shopFace + 0.3),
			dark,
			{
				image = City.textures.windowBold,
				faces = { Enum.NormalId.Front },
				u = step / 2,
				v = G - 2.2 - SHAPE.pavement,
				lines = pal.trim,
				lit = true,
			}
		)
		for i, px in pierXs do
			Kit.box(
				m,
				`Pier{i - 1}`,
				Vector3.new(px, -KIT.bury, zF - pr.proud),
				Vector3.new(px + pr.width, G + 0.2, zF + 1.4),
				wall
			)
		end
		local rise = (step - pierW) * SHAPE.arch
		for k = 1, n do
			local ox0, ox1 = pierXs[k] + pierW, pierXs[k + 1]
			Kit.archHead(m, `Arch{k}`, ox0, ox1, G, zF - pr.proud - 0.05, zF + 1.4, rise, trim)
			awning(`Awning{k}`, ox0 + 0.2, ox1 - 0.2, zF - pr.proud + 0.4, G - rise)
		end
		-- The loggia's ceiling.
		Kit.trim(
			m,
			"Soffit",
			Vector3.new(x0 + 0.1, G - 0.2, zF + 0.6),
			Vector3.new(rowEnd - 0.1, G + 0.1, shopFace + 0.1),
			trim
		)
		yLights = G - rise - 0.5
	else
		local sa = SHAPE.shopArch
		local spring = G - bt.thick / 2 - sa.head
		for k = 1, n do
			local cx = (pierXs[k] + pierXs[k + 1] + pierW) / 2
			-- As wide as the bay leaves, and no wider than its head can rise under the belt.
			local w = math.min(sa.width, step - pierW - 2 * sa.margin, 2 * (spring - SHAPE.pavement - 3))
			local s = spring - w / 2
			Kit.archWindow(m, `ShopWindow{k}`, cx - w / 2, cx + w / 2, SHAPE.pavement, s, shopFace, dark, {
				image = City.textures.windowBold,
				faces = { Enum.NormalId.Front },
				u = w / 2,
				v = s - SHAPE.pavement,
				lines = pal.trim,
				lit = true,
			})
			awning(`Awning{k}`, cx - w / 2 - 0.3, cx + w / 2 + 0.3, shopFace - 0.2, s + 0.4)
		end
		yLights = G + 0.9
	end
	-- Café lights strung along the shop storey.
	local lz = zF - (if arcade then SHAPE.pier.proud else bt.proud) - 0.25
	Kit.neon(
		m,
		"Lights",
		Vector3.new(x0 + 1, yLights, lz),
		Vector3.new(rowEnd - 1, yLights, lz),
		"neonAmber",
		WARM,
		SHAPE.lights
	)

	-------------------------------------------------------------------------------------------------------
	-- Windows: a pair over every bay on every upper floor, plenty of stucco between (one punched strip per bay, its top
	-- on the roof line so the tiles fall per floor)
	-------------------------------------------------------------------------------------------------------
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
		local tcx, tzc = (tx0 + tx1) / 2, (tz0 + tz1) / 2
		local shaftTop = H + tr.rise
		Kit.box(m, "Tower", Vector3.new(tx0, -KIT.bury, tz0), Vector3.new(tx1, shaftTop, tz1), wall)
		-- One window a floor up its front and up its street side.
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
		-- An oculus on the shaft's front, over the row's roof.
		Kit.porthole(m, "Oculus", tcx, H + tr.rise * 0.55, tz0, tr.oculus, dark, trim)
		-- The loggia: corner piers round a dim core set back behind them, arch haunches over the front and street-side
		-- openings, all under a cream eave.
		local stageTop = shaftTop + tr.stage
		local p = tw * tr.post
		local ci = tr.core
		for i, c in { { 0, 0 }, { 1, 0 }, { 0, 1 }, { 1, 1 } } do
			local px0 = if c[1] == 0 then tx0 else tx1 - p
			local pz0 = if c[2] == 0 then tz0 else tz1 - p
			Kit.box(
				m,
				`LoggiaPier{i}`,
				Vector3.new(px0, shaftTop - 0.1, pz0),
				Vector3.new(px0 + p, stageTop + 0.1, pz0 + p),
				wall
			)
		end
		Kit.lit(
			Kit.box(
				m,
				"LoggiaCore",
				Vector3.new(tx0 + ci, shaftTop - 0.05, tz0 + ci),
				Vector3.new(tx1 - ci, stageTop + 0.05, tz1 - ci),
				CORE
			),
			"neonAmber"
		)
		local rise = (tw - 2 * p) * 0.4
		Kit.archHead(m, "LoggiaArch", tx0 + p, tx1 - p, stageTop, tz0 - 0.05, tz0 + ci, rise, wall)
		Kit.corbel(
			m,
			"LoggiaSideF",
			Vector3.new(tx1 - ci, stageTop - rise, tz0 + p),
			Vector3.new(tx1 + 0.05, stageTop, tz0 + p + rise),
			"front",
			wall
		)
		Kit.corbel(
			m,
			"LoggiaSideB",
			Vector3.new(tx1 - ci, stageTop - rise, tz1 - p - rise),
			Vector3.new(tx1 + 0.05, stageTop, tz1 - p),
			"back",
			wall
		)
		Kit.trim(
			m,
			"TowerEave",
			Vector3.new(tx0 - 0.3, stageTop, tz0 - 0.3),
			Vector3.new(tx1 + 0.3, stageTop + tr.eave, tz1 + 0.3),
			trim
		)
		local roofBase = stageTop + tr.eave
		Kit.hipRoof(
			m,
			"TowerRoof",
			Vector3.new(tx0 + 0.2, roofBase, tz0 + 0.2),
			Vector3.new(tx1 - 0.2, roofBase + tr.cap, tz1 - 0.2),
			tr.overhang,
			0.6,
			TILE
		)
		Kit.ball(m, "Finial", Vector3.new(tcx, roofBase + tr.cap + 0.5, tzc), 1, trim)
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
	-- The pavement: terrazzo, a market umbrella, a hanging blade sign, and the wash
	-------------------------------------------------------------------------------------------------------
	Kit.box(
		m,
		"Pavement",
		Vector3.new(-hw + 0.2, 0, -hd + 0.3),
		Vector3.new(hw - 0.2, SHAPE.pavement, shopFace + 0.3),
		terrazzo
	)
	Kit.umbrella(m, "Umbrella", -0.45 * hw, -hd + 2.8, SHAPE.pavement, SHAPE.umbrella, pal.awning[1], true)
	local bd = SHAPE.blade
	local bx = pierXs[2] + pierW / 2 -- on the second pier (or bay line)
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
