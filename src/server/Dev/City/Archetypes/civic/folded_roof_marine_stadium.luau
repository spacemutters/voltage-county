--!strict
-- C06 folded_roof_marine_stadium (docs/city/ARCHETYPES.md §9, C06): the lake stadium. A raked concrete grandstand,
-- its front lip on piers over a dark void at the water's edge, white bench lines on every tier and stair aisles up
-- the rake. From a concourse behind the top tier a row of slanted columns leans out toward the water, tied by one long
-- beam, and from that beam the signature: a long, thin roof of folded concrete plates cantilevered far out over the
-- seats, its zig-zag front edge lit at night. The stadium's name on the back wall, a stair tower at one end.
--
-- What makes it itself: a long white roof of folded concrete wings floating out over a grandstand by the water.
-- Placement, sizes, heights and its budget: Config/CityArchetypes/folded_roof_marine_stadium. NOTE: its front (-z)
-- faces the WATER (the stands look out over the lake), its back (+z) the road.
-- Variants: palette (1 white concrete and white benches, 2 weathered concrete covered in graffiti panels, 3 warm
-- concrete with aqua benches), crown (1 the roof rising toward its tip with shallow folds, 2 a level roof with deep
-- folds), rhythm (1 eight plates on nine columns, 2 six wider plates on seven), mirror (the stair tower's end).
--
-- Previewing (Studio helper): Preview.build("folded_roof_marine_stadium", { width = 210, depth = 53 }) and look from
-- the front (the water side: Preview faces fronts south). Check: the roof's front edge reads as a zig-zag of folds and
-- its plates meet cleanly at the ridges and valleys; the columns lean toward the water and meet the beam; the piers
-- carry the stands' lip; at night the folds' front edges glow in a zig-zag line.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local City = require(ReplicatedStorage.Shared.Config.City)
local Kit = require(script.Parent.Parent.Parent.Kit)
local Types = require(script.Parent.Parent.Parent.Types)

local KIT = City.kit
local rgb = Color3.fromRGB

-- The recipe, in studs.
local SHAPE = {
	sideInset = 2,
	apron = 4, -- the walkway at the water's edge, in front of the stands
	backInset = 1.5,
	tiers = 6,
	tier = { rise = 4.1, depth = { 4.5, 7.5 } }, -- each tier's height, and its depth (fitted to the site)
	lip = 4, -- the stands' front stands on piers this high, over a dark void
	pier = { wide = 2.4, every = 28 },
	concourse = 3, -- the walkway wall over the top tier
	aisles = 4,
	plates = { 8, 6 }, -- by rhythm
	roof = {
		thick = 0.8,
		fold = { 5, 7.5 }, -- by crown: ridge to valley (deep folds: the roof's look)
		lift = { 4, 0 }, -- by crown: how much the front edge rises over the back
		front = 3, -- the roof's tip reaches this far past the stands' front
		back = 6, -- and this far behind the beam
	},
	column = { thick = 3.2, wide = 2.6, lean = 12, base = 3 }, -- base: in from the back line
	beam = { height = 2.4, depth = 3 },
	led = { thick = 0.4, deep = 0.6 },
	tower = { width = 12, depth = 14 },
	booth = { height = 5, depth = 4.5 },
	flag = 7,
}

-- Concrete, the bench lines, the void, graffiti panels (palette 2 only).
local PALETTES = {
	{ concrete = rgb(230, 228, 222), bench = rgb(250, 250, 248), graffiti = false },
	{ concrete = rgb(208, 206, 198), bench = rgb(236, 234, 228), graffiti = true },
	{ concrete = rgb(226, 218, 204), bench = rgb(120, 206, 214), graffiti = false },
}
local GRAFFITI = {
	rgb(255, 79, 154),
	rgb(45, 107, 255),
	rgb(255, 210, 63),
	rgb(65, 211, 166),
	rgb(255, 122, 47),
	rgb(123, 77, 255),
}
local VOID = Kit.look(rgb(36, 40, 46), Enum.Material.SmoothPlastic)

local function build(m: Types.Model)
	local site = m.site
	local variant = site.variant
	local pal = PALETTES[math.clamp(variant.palette, 1, #PALETTES)]
	local crown = math.clamp(variant.crown, 1, 2)
	local rhythm = math.clamp(variant.rhythm, 1, 2)
	local W, D, H = site.width, site.depth, site.height
	local hw, hd = W / 2, D / 2
	local concrete = Kit.look(pal.concrete, Enum.Material.Concrete)
	local smooth = Kit.look(pal.concrete, Enum.Material.SmoothPlastic)
	local bench = Kit.look(pal.bench, Enum.Material.SmoothPlastic)

	-------------------------------------------------------------------------------------------------------
	-- Layout (front = the water)
	-------------------------------------------------------------------------------------------------------
	local Wr = W - 2 * SHAPE.sideInset - 2 -- the roof's width
	local sx = Wr / 2 - 2 -- the stands' half-width
	local zF = -hd
	local zB = hd - SHAPE.backInset
	local zS0 = zF + SHAPE.apron -- the stands' front
	local T = SHAPE.tiers
	local td = math.clamp((zB - zS0 - 6) / T, SHAPE.tier.depth[1], SHAPE.tier.depth[2])
	local zSB = zS0 + T * td -- the stands' back
	local lip = SHAPE.lip
	local tr = SHAPE.tier.rise
	local topY = lip + T * tr

	-------------------------------------------------------------------------------------------------------
	-- The waterside apron and its rail; the void and piers under the stands' lip
	-------------------------------------------------------------------------------------------------------
	Kit.box(m, "Apron", Vector3.new(-hw + 0.5, -KIT.bury, zF + 0.3), Vector3.new(hw - 0.5, 0.4, zS0 + 0.5), concrete)
	Kit.detail(m, "Rail", Vector3.new(-hw + 0.8, 0.4, zF + 0.5), Vector3.new(hw - 0.8, 3.6, zF + 0.8), bench)
	Kit.box(m, "Void", Vector3.new(-sx, -KIT.bury, zS0 + 3), Vector3.new(sx, lip + 0.02, zSB), VOID)
	local pw = SHAPE.pier.wide
	local piers = math.clamp(math.floor(2 * sx / SHAPE.pier.every) + 1, 4, 9)
	for k = 1, piers do
		local x = -sx + pw / 2 + (2 * sx - pw) * (k - 1) / (piers - 1)
		Kit.box(
			m,
			`Pier{k}`,
			Vector3.new(x - pw / 2, 0.3, zS0 + 0.4),
			Vector3.new(x + pw / 2, lip + 0.04, zS0 + 0.4 + pw),
			concrete
		)
	end

	-------------------------------------------------------------------------------------------------------
	-- The stands: stacked tiers, a white bench line on each, stair aisles up the rake, the concourse at the back
	-------------------------------------------------------------------------------------------------------
	for k = 1, T do
		local z0 = zS0 + (k - 1) * td
		local y1 = lip + k * tr
		Kit.box(m, `Tier{k}`, Vector3.new(-sx, lip, z0), Vector3.new(sx, y1, zSB + 0.02 * k), concrete)
		Kit.detail(
			m,
			`Bench{k}`,
			Vector3.new(-sx + 0.2, y1 - tr + 0.5, z0 - 0.08),
			Vector3.new(sx - 0.2, y1 - 0.3, z0 + 0.3),
			bench
		)
	end
	-- Stair aisles: a band lying on the tiers' nosings, front to top.
	for k = 1, SHAPE.aisles do
		local x = -sx + 2 * sx * k / (SHAPE.aisles + 1)
		Kit.strut(
			m,
			`Aisle{k}`,
			Vector3.new(x, lip + tr + 0.3, zS0 + 0.1),
			Vector3.new(x, lip + T * tr + 0.3, zS0 + (T - 1) * td + 0.1),
			0.6,
			bench,
			"detail",
			3
		)
	end
	local cTop = topY + SHAPE.concourse
	Kit.box(m, "Concourse", Vector3.new(-sx, -KIT.bury, zSB - 0.6), Vector3.new(sx, cTop, zB), concrete)
	Kit.trim(m, "Coping", Vector3.new(-sx - 0.4, cTop, zSB - 1), Vector3.new(sx + 0.4, cTop + 0.6, zB + 0.4), smooth)

	-------------------------------------------------------------------------------------------------------
	-- The roof: folded plates cantilevered from a beam on slanted columns
	-------------------------------------------------------------------------------------------------------
	local rf = SHAPE.roof
	local n = SHAPE.plates[rhythm]
	local fold = rf.fold[crown]
	local lift = rf.lift[crown]
	local co = SHAPE.column
	local zColBase = zB - co.base
	local zBeam = zColBase - co.lean
	local zR0 = zS0 - rf.front -- the roof's tip (toward the water)
	local zR1 = math.min(zBeam + rf.back, zB) -- its back edge
	local yRidgeFront, yRidgeBack = H, H - lift
	local function ridgeY(z: number): number
		return yRidgeBack + (yRidgeFront - yRidgeBack) * (zR1 - z) / (zR1 - zR0)
	end
	local plate = Wr / n
	local along = Vector3.new(0, yRidgeFront - yRidgeBack, zR0 - zR1)
	local alongLen = along.Magnitude
	local ledKind = "ledBlue"
	for k = 0, n - 1 do
		local xr = -Wr / 2 + k * plate -- this plate's left ridge
		for h, dir in { 1, -1 } do
			-- h 1: the left half, ridge down to the valley; h 2: the valley back up to the next ridge.
			local across = Vector3.new(plate / 2, -fold * dir, 0)
			local vX = across.Unit
			local vZ = (along - vX * along:Dot(vX)).Unit
			local vY = vZ:Cross(vX)
			local cx = xr + plate / 4 + (h - 1) * plate / 2
			local cy = (ridgeY(zR0) + ridgeY(zR1)) / 2 - fold / 2
			local centre = Vector3.new(cx, cy, (zR0 + zR1) / 2)
			local cf = CFrame.fromMatrix(centre, vX, vY, vZ)
			local width = across.Magnitude + 0.3
			Kit.oriented(m, `Plate{k + 1}{h}`, "block", cf, Vector3.new(width, rf.thick, alongLen), smooth, "trim")
			-- The plate's front edge, lit at night: the zig-zag line along the roof's tip.
			local edge = centre
				+ vZ * (alongLen / 2 - SHAPE.led.deep / 2 - 0.05)
				- vY * (rf.thick / 2 + SHAPE.led.thick / 2)
			Kit.lit(
				Kit.oriented(
					m,
					`Edge{k + 1}{h}`,
					"block",
					CFrame.fromMatrix(edge, vX, vY, vZ),
					Vector3.new(width - 0.2, SHAPE.led.thick, SHAPE.led.deep),
					bench,
					"detail"
				),
				ledKind
			)
		end
	end
	-- The beam under the roof's back, and the columns leaning out to it from behind the stands.
	local beamTop = ridgeY(zBeam) - fold - rf.thick / 2 - 0.1
	local bm = SHAPE.beam
	Kit.trim(
		m,
		"Beam",
		Vector3.new(-Wr / 2, beamTop - bm.height, zBeam - bm.depth / 2),
		Vector3.new(Wr / 2, beamTop, zBeam + bm.depth / 2),
		smooth
	)
	for k = 0, n do
		local x = -Wr / 2 + k * plate
		x = math.clamp(x, -Wr / 2 + co.thick, Wr / 2 - co.thick)
		Kit.strut(
			m,
			`Column{k + 1}`,
			Vector3.new(x, 0.2, zColBase),
			Vector3.new(x, beamTop - bm.height + 0.4, zBeam),
			co.thick,
			concrete,
			"box",
			co.wide
		)
	end

	-- The announcers' booth on the concourse, between two columns, its glass looking out over the water.
	local bw = plate * 0.7
	local bx = -Wr / 2 + plate * (math.floor(n / 2) + 0.5)
	local booth = SHAPE.booth
	Kit.glass(
		m,
		"Booth",
		Vector3.new(bx - bw / 2, cTop + 0.6, zSB - 0.5),
		Vector3.new(bx + bw / 2, cTop + 0.6 + booth.height, zSB - 0.5 + booth.depth),
		rgb(44, 64, 78),
		{
			image = City.textures.windowBold,
			faces = { Enum.NormalId.Front },
			u = bw / 6,
			v = booth.height,
			lines = pal.concrete,
			lit = true,
		}
	)
	Kit.trim(
		m,
		"BoothRoof",
		Vector3.new(bx - bw / 2 - 0.8, cTop + 0.6 + booth.height, zSB - 1.6),
		Vector3.new(bx + bw / 2 + 0.8, cTop + 1.4 + booth.height, zSB - 0.5 + booth.depth + 0.4),
		smooth
	)

	-------------------------------------------------------------------------------------------------------
	-- The back: the stadium's name, a stair tower at one end, graffiti on palette 2
	-------------------------------------------------------------------------------------------------------
	local signW = math.min(70, 2 * sx * 0.45)
	Kit.sign(
		m,
		"Name",
		Vector3.new(-signW / 2, cTop - 7.5, zB + 0.05),
		Vector3.new(signW / 2, cTop - 2, zB + 0.45),
		Enum.NormalId.Back,
		"LAKE STADIUM",
		pal.concrete,
		rgb(40, 96, 150),
		City.districtLooks.downtown.font,
		"sign"
	)
	local to = SHAPE.tower
	local tx0, tx1 = sx + 0.5, math.min(sx + 0.5 + to.width, hw - 0.5)
	if tx1 - tx0 > 4 then
		Kit.box(m, "StairTower", Vector3.new(tx0, -KIT.bury, zB - to.depth), Vector3.new(tx1, cTop + 2, zB), concrete)
		Kit.strut(
			m,
			"Ramp",
			Vector3.new((tx0 + tx1) / 2, 0.4, zB - to.depth - 0.2 - 8),
			Vector3.new((tx0 + tx1) / 2, topY * 0.5, zB - to.depth - 0.2),
			0.8,
			smooth,
			"box",
			tx1 - tx0 - 1
		)
		Kit.column(
			m,
			"Flagpole",
			(tx0 + tx1) / 2,
			zB - to.depth / 2,
			cTop + 2,
			math.min(cTop + 2 + SHAPE.flag + 20, site.maxHeight - 0.2),
			0.35,
			Kit.look(rgb(206, 208, 210), Enum.Material.Metal),
			"detail"
		)
	end
	if pal.graffiti then
		local rng = Kit.rng(m, 5)
		for k = 1, 6 do
			local w = 8 + rng:NextNumber() * 10
			local x = -sx + 4 + (2 * sx - 8 - w) * (k - 1) / 5
			local y0 = 1 + rng:NextNumber() * 4
			Kit.detail(
				m,
				`Tag{k}`,
				Vector3.new(x, y0, zB + 0.05),
				Vector3.new(x + w, y0 + 3 + rng:NextNumber() * 5, zB + 0.25),
				Kit.look(GRAFFITI[(k - 1) % #GRAFFITI + 1], Enum.Material.SmoothPlastic)
			)
		end
	end
end

local archetype: Types.Archetype = { id = "folded_roof_marine_stadium", build = build }
return archetype
