--!strict
-- W05 port_crane_yard (docs/city/ARCHETYPES.md §8, W05): the working port's silhouette. Two giant ship-to-shore
-- container cranes on their rails over a paved yard of coloured containers, stood so the street sees them side-on:
-- the classic profile of four legs on sill beams, a portal braced by ties and diagonals, a long girder carrying the
-- boom out over the stacks (or the boom raised high, parked), an A-frame apex with its fore- and backstays, the
-- machinery house on the back reach, the operator's cab and trolley under the boom. White steel with one colour on
-- the beams and houses (an original scheme). Containers stand in stacks of one to four in a dozen colours: 40-foot
-- boxes in rows on the yard, taller stacks under the boom where a ship would be, 20-foot boxes between the rails.
-- A gatehouse with a barrier and the yard's name, jersey barriers along the street, two light masts.
--
-- What makes it itself: giant gantry cranes standing over stacks of coloured containers.
-- On a deep site (a core claim, Config/City landmarks: depth 140) both cranes stand on one quay, one behind the other
-- on the same rails, as at a real port; on a plot-deep site they stand side by side, each on its own rails.
-- Night: red beacons on every apex and raised boom tip, floodlights under the girders and on the masts, the cabs and
-- the gatehouse lit.
-- Placement, sizes, heights and its budget: Config/City archetypes.port_crane_yard (a one-off by the freight depot,
-- Config/City landmarks).
-- Variants: palette (2 crane colours: white and blue, white and red), crown (1 booms down, 2 booms raised, 3 one of
-- each), rhythm (2 ways of filling the yard: tall stacks, low and mixed), mirror (the booms point the other way).
--
-- Previewing: side-on from the street at 150 to 250 studs (the profile is the point) and from a corner. Check the
-- A-frame's struts meet the apex head, the stays run apex to boom tip and to the back reach, a raised boom stands
-- clear of the apex, the cranes' legs straddle the rails and no container stands on a rail or under a leg, the stacks
-- read as separate boxes (the street row is ribbed), and the beacons show at night.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local City = require(ReplicatedStorage.Shared.Config.City)
local Kit = require(script.Parent.Parent.Parent.Kit)
local Types = require(script.Parent.Parent.Parent.Types)

local KIT = City.kit
local rgb = Color3.fromRGB

-- The recipe, in studs.
local SHAPE = {
	margin = 4, -- the cranes keep this far inside the site's ends
	gauge = 40, -- waterside to landside legs (along x)
	back = 26, -- the back reach past the landside legs
	reach = { 50, 85 }, -- the boom's reach past the waterside legs, as the site allows
	legZ = 15, -- legs this far either side of the crane's centre line (along z: the rails)
	sillZ = 17.5,
	leg = 4,
	girder = { share = 0.6, tall = 6.2, half = 3.8 }, -- its underside at this share of the height: a deep box girder
	raise = math.rad(76), -- a parked boom's angle
	tie = 0.45, -- the portal ties at this share of the girder's height
	frame = { foot = 13, head = 6, thick = 2.8 }, -- the A-frame's struts: half-spread at foot and head (z)
	stay = 0.9,
	beacon = 2.4, -- the red lamps on the apexes and a raised boom's tip: big enough to read as a point at night
	beaconMast = 3, -- the apex's lamp stands on a short mast, clear of the apex beam seen from the street below
	house = { long = 22, tall = 8, half = 5.5 },
	cab = 4.4,
	craneDepth = 38, -- what one crane needs along its rails...
	craneEvery = 44, -- ...and between two on one quay
	yardFront = 10, -- containers keep this far from the front line (the fence and a truck lane)
	box = { long = 44, short = 22, wide = 9, tall = 9.5, gap = 2, rowGap = 1.5 }, -- 40- and 20-foot containers
	ribbed = 8, -- containers in the street row with ribs (textures), at most
	mast = 46,
	gate = { booth = 6, open = 16 },
}

type Palette = { white: Color3, accent: Color3 }
local PALETTES: { Palette } = {
	{ white = rgb(237, 237, 233), accent = rgb(46, 94, 168) },
	{ white = rgb(237, 237, 233), accent = rgb(196, 58, 46) },
}

local BOX_COLOURS = {
	rgb(156, 59, 46),
	rgb(47, 93, 140),
	rgb(62, 125, 79),
	rgb(217, 119, 43),
	rgb(138, 144, 150),
	rgb(217, 181, 58),
	rgb(40, 130, 140),
	rgb(222, 224, 222),
	rgb(120, 40, 60),
}

-- One crane: its waterside legs' x, its centre line's z, a raised boom or not, and the boom's reach.
type Crane = { xw: number, zc: number, up: boolean, reach: number }

local function build(m: Types.Model)
	local site = m.site
	local variant = site.variant
	local pal = PALETTES[math.clamp(variant.palette, 1, #PALETTES)]
	local rng = Kit.rng(m)
	local W, D, H = site.width, site.depth, site.height
	local hw, hd = W / 2, D / 2
	local mg = SHAPE.margin
	local gauge, backReach = SHAPE.gauge, SHAPE.back
	local girderY = math.round(H * SHAPE.girder.share)
	local girderTop = girderY + SHAPE.girder.tall

	local white = Kit.look(pal.white, Enum.Material.SmoothPlastic)
	local accent = Kit.look(pal.accent, Enum.Material.SmoothPlastic)
	local steel = Kit.look(rgb(64, 68, 74), Enum.Material.Metal)
	local yardLook = Kit.look(rgb(92, 94, 98), Enum.Material.Concrete)
	local concrete = Kit.look(City.palettes.concrete.pale, Enum.Material.Concrete)

	-------------------------------------------------------------------------------------------------------
	-- Where the cranes stand
	-------------------------------------------------------------------------------------------------------
	local zMin, zMax = -hd + SHAPE.yardFront, hd - 3
	local zSlots = 1 + math.floor((zMax - zMin - SHAPE.craneDepth) / SHAPE.craneEvery)
	local crown = math.clamp(variant.crown, 1, 3)
	local wants = ({ { false, false }, { true, true }, { true, false } })[crown]
	local function span(up: boolean, reach: number): number -- from the back reach's end to the boom's tip
		return gauge + backReach + (if up then 26 else reach + 1)
	end
	local cranes: { Crane } = {}
	local room = W - 2 * mg
	if zSlots >= 2 then
		-- One quay: both cranes on the same rails, one behind the other.
		local anyDown = not (wants[1] and wants[2])
		local reach = math.clamp(room - gauge - backReach - 2, SHAPE.reach[1], SHAPE.reach[2])
		local xw = if anyDown then hw - mg - reach - 1 else math.min(hw - mg - 26, -hw + mg + gauge + backReach + 30)
		local zMid = (zMin + zMax) / 2
		for i = 1, 2 do
			table.insert(cranes, {
				xw = xw,
				zc = zMid + (i - 1.5) * SHAPE.craneEvery,
				up = wants[i],
				reach = reach,
			})
		end
	else
		-- One crane deep: side by side along the frontage, each on its own rails, if the width allows.
		local zc = (zMin + zMax) / 2
		local reachTwo = math.clamp((room - 8) / 2 - gauge - backReach - 1, SHAPE.reach[1], SHAPE.reach[2])
		local two = span(wants[1], reachTwo) + span(wants[2], reachTwo) + 8 <= room
		if two then
			local first = -hw + mg + gauge + backReach
			table.insert(cranes, { xw = first, zc = zc, up = wants[1], reach = reachTwo })
			local last = if wants[2] then hw - mg - 26 else hw - mg - reachTwo - 1
			table.insert(cranes, { xw = last, zc = zc, up = wants[2], reach = reachTwo })
		else
			local up = crown == 2
			local reach = math.clamp(room - gauge - backReach - 1, SHAPE.reach[1], SHAPE.reach[2])
			local s = span(up, reach)
			table.insert(cranes, { xw = -s / 2 + gauge + backReach, zc = zc, up = up, reach = reach })
		end
	end

	-------------------------------------------------------------------------------------------------------
	-- The yard: paving, rails, the gate and its booth, barriers along the street, light masts
	-------------------------------------------------------------------------------------------------------
	Kit.box(m, "Yard", Vector3.new(-hw + 0.2, -0.6, -hd + 0.2), Vector3.new(hw - 0.2, 0.15, hd - 0.2), yardLook)
	local rails: { number } = {}
	local railKeys: { [number]: boolean } = {}
	for _, c in cranes do
		for _, x in { c.xw - gauge, c.xw } do
			local key = math.round(x * 10)
			if not railKeys[key] then
				railKeys[key] = true
				table.insert(rails, x)
			end
		end
	end
	table.sort(rails)
	for i, x in rails do
		Kit.detail(m, `Rail{i}`, Vector3.new(x - 0.4, 0.15, zMin - 4), Vector3.new(x + 0.4, 0.55, hd - 1), steel)
	end
	local gt = SHAPE.gate
	local gx0, gz0 = -hw + 6, -hd + 3.2
	Kit.box(m, "Booth", Vector3.new(gx0, 0.15, gz0), Vector3.new(gx0 + gt.booth, 4.6, gz0 + 5), white)
	Kit.glass(
		m,
		"BoothGlass",
		Vector3.new(gx0 + 0.6, 2.2, gz0 - 0.15),
		Vector3.new(gx0 + gt.booth - 0.6, 3.9, gz0 + 0.3),
		rgb(44, 60, 70),
		{ lit = true }
	)
	Kit.trim(
		m,
		"BoothRoof",
		Vector3.new(gx0 - 0.8, 4.6, gz0 - 0.8),
		Vector3.new(gx0 + gt.booth + 0.8, 5.2, gz0 + 5.8),
		accent
	)
	Kit.sign(
		m,
		"YardName",
		Vector3.new(gx0 - 0.4, 5.2, gz0 + 1.5),
		Vector3.new(gx0 + gt.booth + 0.4, 7.2, gz0 + 1.9),
		Enum.NormalId.Front,
		"COUNTY PORT",
		pal.accent,
		pal.white,
		Enum.Font.Michroma
	)
	local gateEnd = gx0 + gt.booth + 1 + gt.open
	Kit.detail(
		m,
		"GateArm",
		Vector3.new(gx0 + gt.booth + 1, 3.2, gz0 + 1),
		Vector3.new(gx0 + gt.booth + 1 + gt.open * 0.85, 3.6, gz0 + 1.4),
		Kit.look(rgb(255, 196, 40), Enum.Material.SmoothPlastic)
	)
	Kit.box(m, "Barriers", Vector3.new(gateEnd, 0.15, -hd + 1.2), Vector3.new(hw - 1, 3.2, -hd + 2.6), concrete)
	for i, x in { -hw + 2.5, hw - 2.5 } do
		local mz = -hd + 6
		Kit.column(m, `Mast{i}`, x, mz, 0.15, SHAPE.mast, 0.9, steel, "box")
		local lamp = Kit.detail(
			m,
			`MastLamp{i}`,
			Vector3.new(x - 2, SHAPE.mast, mz - 0.8),
			Vector3.new(x + 2, SHAPE.mast + 0.8, mz + 0.8),
			Kit.look(rgb(220, 224, 228), Enum.Material.SmoothPlastic)
		)
		Kit.lit(lamp, "floodlight")
	end

	-------------------------------------------------------------------------------------------------------
	-- The cranes
	-------------------------------------------------------------------------------------------------------
	local g = SHAPE.girder
	local fr = SHAPE.frame
	for n, c in cranes do
		local xw, xl, zc = c.xw, c.xw - gauge, c.zc
		local p = `Q{n}`
		local half = SHAPE.leg / 2
		-- Sill beams on the rails, the four legs on them, beams across their heads.
		for i, x in { xl, xw } do
			Kit.box(
				m,
				`{p}Sill{i}`,
				Vector3.new(x - 1.8, 0.6, zc - SHAPE.sillZ),
				Vector3.new(x + 1.8, 4.6, zc + SHAPE.sillZ),
				accent
			)
			Kit.trim(
				m,
				`{p}Head{i}`,
				Vector3.new(x - 1.9, girderY - 3, zc - SHAPE.legZ - 1.8),
				Vector3.new(x + 1.9, girderY + 0.02, zc + SHAPE.legZ + 1.8),
				accent
			)
			for j, side in { -1, 1 } do
				local z = zc + side * SHAPE.legZ
				Kit.box(
					m,
					`{p}Leg{i}{j}`,
					Vector3.new(x - half, 4.4, z - half),
					Vector3.new(x + half, girderY - 2.9, z + half),
					white
				)
			end
		end
		-- The portal on each side: a tie between the legs and a diagonal brace above it.
		local tieY = girderY * SHAPE.tie
		for j, side in { -1, 1 } do
			local z = zc + side * SHAPE.legZ
			Kit.trim(
				m,
				`{p}Tie{j}`,
				Vector3.new(xl + half, tieY - 1.3, z - 1.1),
				Vector3.new(xw - half, tieY + 1.3, z + 1.1),
				accent
			)
			Kit.strut(
				m,
				`{p}Brace{j}`,
				Vector3.new(xl + half, girderY - 3.5, z),
				Vector3.new(xw - half, tieY + 1.3, z),
				1.6,
				white,
				"trim"
			)
		end
		-- The girder over the gantry and the back reach, and the boom: out level over the stacks, or raised.
		Kit.trim(
			m,
			`{p}Girder`,
			Vector3.new(xl - backReach, girderY, zc - g.half),
			Vector3.new(xw + 3, girderTop, zc + g.half),
			white
		)
		local tip: Vector3
		if c.up then
			local hinge = Vector3.new(xw + 3, girderY + g.tall / 2, zc)
			tip = hinge + Vector3.new(math.cos(SHAPE.raise), math.sin(SHAPE.raise), 0) * c.reach
			Kit.strut(m, `{p}Boom`, hinge, tip, g.tall - 0.3, white, "trim", 2 * g.half - 0.6)
			Kit.lit(
				Kit.ball(
					m,
					`{p}TipBeacon`,
					tip + Vector3.new(0, 1.6, 0),
					SHAPE.beacon,
					Kit.look(rgb(150, 40, 36), Enum.Material.SmoothPlastic)
				),
				"beacon"
			)
		else
			Kit.trim(
				m,
				`{p}Boom`,
				Vector3.new(xw + 3, girderY + 0.15, zc - g.half + 0.3),
				Vector3.new(xw + c.reach, girderTop - 0.15, zc + g.half - 0.3),
				white
			)
			tip = Vector3.new(xw + c.reach - 1.5, girderTop, zc)
		end
		-- The A-frame: two struts up from the waterside head beam and two from the landside one, to the apex head.
		local apexX = xw - 4
		for j, side in { -1, 1 } do
			Kit.strut(
				m,
				`{p}Front{j}`,
				Vector3.new(xw, girderY - 0.2, zc + side * fr.foot),
				Vector3.new(apexX + 1, H - 3, zc + side * fr.head),
				fr.thick,
				white,
				"trim"
			)
			Kit.strut(
				m,
				`{p}Back{j}`,
				Vector3.new(xl + 1, girderY - 0.2, zc + side * fr.foot),
				Vector3.new(apexX - 1, H - 3, zc + side * fr.head),
				fr.thick,
				white,
				"trim"
			)
		end
		Kit.trim(
			m,
			`{p}Apex`,
			Vector3.new(apexX - 4, H - 3.5, zc - fr.head - 1.5),
			Vector3.new(apexX + 4, H, zc + fr.head + 1.5),
			accent
		)
		Kit.column(m, `{p}BeaconMast`, apexX, zc, H - 0.1, H + SHAPE.beaconMast, 0.4, steel, "detail")
		Kit.lit(
			Kit.ball(
				m,
				`{p}Beacon`,
				Vector3.new(apexX, H + SHAPE.beaconMast + 0.4, zc),
				SHAPE.beacon,
				Kit.look(rgb(150, 40, 36), Enum.Material.SmoothPlastic)
			),
			"beacon"
		)
		-- Stays from the apex: forward to the boom's tip, back to the machinery house's far end.
		local hs = SHAPE.house
		local houseX0 = xl - backReach + 1
		local stayFrom = Vector3.new(apexX, H - 1.8, zc)
		Kit.strut(m, `{p}Forestay`, stayFrom, tip, SHAPE.stay, steel, "trim")
		Kit.strut(
			m,
			`{p}Backstay`,
			stayFrom,
			Vector3.new(houseX0 + 1, girderTop + hs.tall - 0.2, zc),
			SHAPE.stay,
			steel,
			"trim"
		)
		-- The machinery house on the back reach, its crane number on the street side.
		local house = Kit.trim(
			m,
			`{p}House`,
			Vector3.new(houseX0, girderTop - 0.05, zc - hs.half),
			Vector3.new(houseX0 + hs.long, girderTop + hs.tall, zc + hs.half),
			accent
		)
		house.labels = {
			{
				face = Kit.face(m, Enum.NormalId.Front),
				text = `Q{n}`,
				color = pal.white,
				font = Enum.Font.Michroma,
				size = Vector2.new(0.3, 0.7),
				pixelsPerStud = KIT.signPixelsPerStud,
			},
		}
		-- The trolley on the girder and the cab under it, out over the stacks or parked over the gantry.
		local cx = if c.up then xw - 8 else xw + c.reach * 0.45
		local cb = SHAPE.cab
		Kit.trim(
			m,
			`{p}Trolley`,
			Vector3.new(cx - 3, girderTop - 0.05, zc - 3.6),
			Vector3.new(cx + 3, girderTop + 1.9, zc + 3.6),
			steel
		)
		Kit.glass(
			m,
			`{p}Cab`,
			Vector3.new(cx - cb / 2, girderY - cb - 0.2, zc - cb / 2),
			Vector3.new(cx + cb / 2, girderY + 0.25, zc + cb / 2),
			rgb(44, 60, 70),
			{ lit = true }
		)
		-- A floodlight strip under the girder (and the boom), beside the cab.
		local floodTo = if c.up then xw - 2 else xw + c.reach * 0.75
		Kit.lit(
			Kit.detail(
				m,
				`{p}Flood`,
				Vector3.new(xl + 2, girderY - 0.45, zc + 2.6),
				Vector3.new(floodTo, girderY + 0.17, zc + 3.3),
				Kit.look(rgb(220, 224, 228), Enum.Material.SmoothPlastic)
			),
			"floodlight"
		)
	end

	-------------------------------------------------------------------------------------------------------
	-- Containers: rows of stacks on the free ground, front rows first, while the budget lasts
	-------------------------------------------------------------------------------------------------------
	local bx = SHAPE.box
	local config = City.archetypes[site.archetype]
	local allowance = (if config then config.budget else 120) - 2
	-- The free strips of ground between the rails (each rail keeps 3 clear either side).
	local strips: { { a: number, b: number, under: boolean, between: boolean } } = {}
	local from = -hw + 2
	local lastRail = rails[#rails]
	for i, x in rails do
		if x - 3 - from > bx.wide then
			table.insert(strips, { a = from, b = x - 3, under = false, between = i % 2 == 0 })
		end
		from = x + 3
	end
	if hw - 2 - from > bx.wide then
		table.insert(strips, { a = from, b = hw - 2, under = lastRail ~= nil, between = false })
	end
	-- Each strip's slots for one row: 40-foot boxes along x where they fit, else 20-foot boxes along z.
	type Slot = { x0: number, x1: number, along: boolean, low: number, high: number, z: number }
	local slots: { Slot } = {}
	local tall = variant.rhythm ~= 2
	for _, s in strips do
		local width = s.b - s.a
		local low, high = 1, if tall then 3 else 2
		if s.under then
			low, high = 2, if tall then 4 else 3
		elseif s.between then
			low, high = 1, 2
		end
		if width >= bx.long then
			local count = math.floor((width + bx.gap) / (bx.long + bx.gap))
			local spare = width - count * bx.long - (count - 1) * bx.gap
			for k = 1, count do
				local x = s.a + spare / 2 + (k - 1) * (bx.long + bx.gap)
				table.insert(slots, { x0 = x, x1 = x + bx.long, along = true, low = low, high = high, z = zMin })
			end
		else
			local count = math.floor((width + bx.rowGap) / (bx.wide + bx.rowGap))
			local spare = width - count * bx.wide - (count - 1) * bx.rowGap
			for k = 1, count do
				local x = s.a + spare / 2 + (k - 1) * (bx.wide + bx.rowGap)
				table.insert(slots, { x0 = x, x1 = x + bx.wide, along = false, low = low, high = high, z = zMin })
			end
		end
	end
	local ribbed = 0
	local done = false
	local row = 0
	local placed = true
	while not done and placed do
		row += 1
		placed = false
		for k, slot in slots do
			local deep = if slot.along then bx.wide else bx.short
			local z = slot.z
			if z + deep > zMax then
				continue
			end
			placed = true
			slot.z += deep + bx.rowGap
			if rng:NextNumber() < 0.12 then
				continue -- an empty bay now and then
			end
			local levels = rng:NextInteger(slot.low, slot.high)
			local colour = BOX_COLOURS[rng:NextInteger(1, #BOX_COLOURS)]
			local level = 0
			while level < levels do
				-- A run of boxes of one colour, one part.
				local run = 1
				while level + run < levels and rng:NextNumber() < 0.3 do
					run += 1
				end
				if #m.specs >= allowance then
					done = true
					break
				end
				local y0 = 0.15 + level * bx.tall
				local material = if rng:NextNumber() < 0.15 then Enum.Material.CorrodedMetal else Enum.Material.Metal
				local spec = Kit.box(
					m,
					`Box{row}_{k}_{level + 1}`,
					Vector3.new(slot.x0, y0 + 0.02, z),
					Vector3.new(slot.x1, y0 + run * bx.tall, z + deep),
					Kit.look(colour, material)
				)
				if row == 1 and ribbed < SHAPE.ribbed then
					ribbed += 1
					spec.textures = {
						{
							face = Kit.face(m, Enum.NormalId.Front),
							image = City.textures.windowBold,
							u = 1.2,
							v = bx.tall,
							color = colour:Lerp(Color3.new(0, 0, 0), 0.35),
						},
					}
				end
				level += run
				colour = BOX_COLOURS[rng:NextInteger(1, #BOX_COLOURS)]
			end
			if done then
				break
			end
		end
	end
end

local archetype: Types.Archetype = { id = "port_crane_yard", build = build }
return archetype
