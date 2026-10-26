--!strict
-- W04 sculpted_car_park (docs/city/ARCHETYPES.md §8, W04): a car park as a civic sculpture, all muscle and no
-- cloth. Six bare concrete slabs stacked at uneven heights (one a tall double-height floor), none of their edges in
-- line: each reaches a little further or less far over the street and past the sides. No walls: between the slabs,
-- thin concrete blade columns stand just behind the slab edges, where the street sees them: every other one faces
-- the street and leans across its floor, the next the other way (a zigzag up the facade), the rest stand upright
-- turned at odd angles in plan, and in the tallest floor pairs of them lean together into Vs. Ramps cross the open
-- floors as diagonals, a stair zigzags up one end in front of everything, glass shop boxes stand under the first
-- slab and a glass boutique in the tall floor, and a few cars stand parked side-on on the open decks. A fine cable
-- rail (four steel lines drawn on one see-through part) runs along every open edge, the only thing between the decks
-- and the air. On top, a glass penthouse or a floating event canopy, planters, and a ragged curtain of greenery
-- spilling over the top edge; a neon number on the top slab.
--
-- What makes it itself: bare floors floating at uneven heights on thin blades set at odd angles.
-- Night: a pale LED line under every slab's front edge (floors floating in light), the lit shops, boutique and
-- penthouse, the neon number.
-- Placement, sizes, heights and its budget: Config/City archetypes.sculpted_car_park.
-- Variants: palette (3 concretes, glass tints and neon colours), crown (1 glass penthouse under a roof slab, 2 a
-- floating event canopy on blades), rhythm (3 sequences of floor heights: where the tall floor falls), mirror.
--
-- Previewing: from a corner, so the slab edges' uneven reach and the blades' angles both read; at night from 150
-- studs. Check no blade pokes through a slab's top or out of the footprint, the Vs meet under the slab, the ramps
-- and the stair cross the floors as clean diagonals, and the ground floor still reads as shops (not a parking hole).
-- The cable rails: their lines should read as thin cables (top one about 3.4 over each deck), stop short of the stair,
-- and not shimmer at 150 studs (if they do, raise rail.every). The greenery should read as hanging plants with a
-- ragged bottom edge, not as green boards.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local City = require(ReplicatedStorage.Shared.Config.City)
local Kit = require(script.Parent.Parent.Parent.Kit)
local Types = require(script.Parent.Parent.Parent.Types)

local P = City.palettes
local rgb = Color3.fromRGB

-- The recipe, in studs.
local SHAPE = {
	front = 5.5, -- the slabs' nominal front edge this far behind the front line
	sideInset = 2,
	bodyDepth = 56, -- at most
	slab = 2.2, -- a thick, bare edge: the slabs are the building
	-- Clear heights of the six floors, bottom up (the ground floor holds the shops), scaled to the site's height.
	gaps = {
		{ 14, 9, 11, 16, 9, 22 },
		{ 16, 10, 18, 9, 12, 20 },
		{ 13, 20, 9, 11, 16, 10 },
	},
	-- How far each slab's front edge and side edges sit from the nominal ones (negative: nearer the street).
	reach = { 0, -1.5, 0.8, -2.5, 1, -1.2 },
	left = { 0, 1.2, -0.8, 1.6, -1, 0.6 },
	right = { 0.8, -1, 1.4, 0, 1.2, -0.6 },
	blade = {
		wide = 5.5,
		thick = 1.3,
		every = 40,
		max = 3,
		margin = 7,
		front = 3.5, -- a blade's foot this far behind the slabs' nominal front edge, so it reads from the street...
		jitter = 2, -- ...give or take this much
		face = 12, -- a leaning blade faces the street, give or take this many degrees, and leans across its floor...
		lean = 0.32, -- ...by this share of the floor's height, the next one the other way: the facade's zigzag
		yaws = { 18, -30, 42, -12, 28, -46 }, -- the others stand upright, turned at odd angles
		shade = 0.18, -- how much darker than the slabs
	},
	vee = 0.5, -- in the tallest floor, a V's blades meet this share of the floor's height across
	ramp = { wide = 12, slope = math.rad(14), from = 8 },
	stair = { wide = 4.2, thick = 1.3, run = { 1.4, 22, 0.28 }, flights = 4 }, -- a flight runs 1.4 x its rise, at most
	-- 22 and 0.28 of the width
	shop = { set = 3, deep = 15, share = 0.42 },
	led = 0.3,
	penthouse = { tall = 9, roof = 0.8, over = 2 }, -- crown 1
	canopy = { rise = 10, thick = 1, blades = 3 }, -- crown 2
	-- The greenery over the top edge: strands across each planter's width (shares), hanging this many studs times
	-- their (shuffled) lengths under the top slab, give or take `jitter`; alternate strands stand `out` further out.
	vine = {
		widths = { 0.3, 0.2, 0.28, 0.22 },
		lengths = { 1, 0.55, 0.85, 0.4 },
		long = 9,
		jitter = 1.5,
		overlap = 0.3,
		out = 0.25,
		greens = { P.leaf, Color3.fromRGB(46, 96, 52), Color3.fromRGB(88, 142, 72) },
	},
	-- A cable rail along each slab's open front edge: one see-through part with the slab-line image tinted steel
	-- on its street face, a cable every `every` studs (the top one about 3.4 over the deck), standing `back` behind
	-- the slab's edge.
	rail = { tall = 4.3, every = 0.9, back = 0.35, color = Color3.fromRGB(150, 154, 158) },
	parked = { count = 4, long = 13, deep = 5, z = 8.5 }, -- cars on the open decks, this far behind the front edge
}

type Palette = { concrete: Color3, glass: Color3, sign: Color3, neon: string }
local PALETTES: { Palette } = {
	-- Raw board-formed concrete, a step darker than paint white so the slab edges and blades hold their shading in
	-- full sun.
	{ concrete = rgb(184, 180, 172), glass = rgb(44, 60, 70), sign = rgb(255, 79, 154), neon = "neonPink" },
	{ concrete = rgb(172, 170, 164), glass = rgb(58, 88, 104), sign = rgb(255, 79, 154), neon = "neonPink" },
	{ concrete = rgb(190, 182, 170), glass = rgb(62, 72, 78), sign = rgb(255, 176, 70), neon = "neonAmber" },
}

local NUMBERS = { "1220", "808", "2440", "350", "1616", "707" }
local CAR_COLOURS = {
	rgb(196, 40, 44),
	rgb(30, 30, 34),
	rgb(234, 234, 230),
	rgb(40, 84, 160),
	rgb(150, 152, 156),
}

local function build(m: Types.Model)
	local site = m.site
	local variant = site.variant
	local pal = PALETTES[math.clamp(variant.palette, 1, #PALETTES)]
	local rng = Kit.rng(m)
	local W, D, H = site.width, site.depth, site.height
	local hw, hd = W / 2, D / 2
	local x0, x1 = -hw + SHAPE.sideInset, hw - SHAPE.sideInset
	local zF = -hd + SHAPE.front
	local zB = math.min(hd - 1.5, zF + SHAPE.bodyDepth)
	local t = SHAPE.slab
	local concrete = Kit.look(pal.concrete, Enum.Material.Concrete)
	local smooth = Kit.look(pal.concrete, Enum.Material.SmoothPlastic)
	-- The blades a shade darker than the slabs: in the sky's flat light the two would merge, and the building is the
	-- blades holding the slabs apart.
	local bladeLook = Kit.look(pal.concrete:Lerp(Color3.new(0, 0, 0), SHAPE.blade.shade), Enum.Material.Concrete)

	-- The floors: each slab's top, bottom up, scaled so the last is the roof.
	local gaps = SHAPE.gaps[math.clamp(variant.rhythm, 1, #SHAPE.gaps)]
	local sum = 0
	for _, g in gaps do
		sum += g
	end
	local scale = (H - #gaps * t) / sum
	local tops: { number } = {}
	local y = 0
	local tallest = 2
	for k, g in gaps do
		y += g * scale + t
		tops[k] = y
		if k >= 2 and g > gaps[tallest] then
			tallest = k
		end
	end
	tops[#gaps] = H

	-------------------------------------------------------------------------------------------------------
	-- The slabs, their edges out of line, an LED line under each front edge
	-------------------------------------------------------------------------------------------------------
	local edges: { { x0: number, x1: number, z0: number } } = {}
	for k = 1, #gaps do
		local e = { x0 = x0 - SHAPE.left[k], x1 = x1 + SHAPE.right[k], z0 = zF + SHAPE.reach[k] }
		edges[k] = e
		Kit.box(m, `Slab{k}`, Vector3.new(e.x0, tops[k] - t, e.z0), Vector3.new(e.x1, tops[k], zB), concrete)
		Kit.neonStrip(
			m,
			`Led{k}`,
			Vector3.new(e.x0 + 0.5, tops[k] - t - SHAPE.led, e.z0 + 0.1),
			Vector3.new(e.x1 - 0.5, tops[k] - t + 0.02, e.z0 + 0.7),
			"ledEdge",
			pal.concrete
		)
	end
	local function floor(k: number): number -- the top of the floor under storey k (0 for the ground)
		return if k <= 1 then 0 else tops[k - 1]
	end

	-------------------------------------------------------------------------------------------------------
	-- Blade columns: turned in plan, some leaning; in the tallest floor they lean together in pairs
	-------------------------------------------------------------------------------------------------------
	local bl = SHAPE.blade
	local span = x1 - x0
	local yawAt = rng:NextInteger(0, #bl.yaws - 1)
	local function blade(name: string, bx: number, bz: number, y0: number, y1: number, yaw: number, shift: number)
		local h = y1 - y0
		local turn = CFrame.Angles(0, yaw, 0)
		local centre = (CFrame.new(bx, y0, bz) * turn) * Vector3.new(shift / 2, h / 2, 0)
		local lean = -math.atan(shift / h)
		local long = math.sqrt(shift * shift + h * h) + 0.4
		Kit.oriented(
			m,
			name,
			"block",
			CFrame.new(centre) * turn * CFrame.Angles(0, 0, lean),
			Vector3.new(bl.wide, long, bl.thick),
			bladeLook,
			"box"
		)
	end
	-- The stair's run, worked out here: the blades keep clear of the end it climbs.
	local st = SHAPE.stair
	local stairRun = math.min(st.run[2], span * st.run[3])
	local bx0, bx1 = x0 + bl.margin, x1 - 6 - stairRun - bl.margin * 0.5
	local bspan = bx1 - bx0
	local count = math.clamp(math.round(bspan / bl.every) + 1, 2, bl.max)
	for k = 1, #gaps do
		local y0, y1 = floor(k), tops[k] - t
		local h = y1 - y0
		if k == 1 then
			-- The shop floor: one blade between the two shop boxes (the boxes hold the rest of the first slab).
			blade("Blade1", x0 + span * SHAPE.shop.share + 3, zF + 9, y0, y1, math.rad(bl.yaws[yawAt + 1]), 0)
		elseif k == tallest then
			-- Vs at the front edge: two blades from apart at the foot to together at the head.
			local vees = math.max(1, math.floor(count / 2 + 0.5))
			for p = 1, vees do
				local half = h * SHAPE.vee / 2
				local px = bx0 + half + (bspan - 2 * half) * (p - 0.5) / vees
				local pz = zF + bl.front + rng:NextNumber() * bl.jitter
				local yaw = math.rad(rng:NextNumber() * 16 - 8)
				blade(`Vee{p}a`, px - half, pz, y0, y1, yaw, half - 0.6)
				blade(`Vee{p}b`, px + half, pz, y0, y1, yaw, -(half - 0.6))
			end
		else
			for j = 1, count do
				local bx = bx0 + bspan * (j - 0.5) / count + (rng:NextNumber() * 2 - 1) * 2
				local bz = zF + bl.front + rng:NextNumber() * bl.jitter
				local yaw, shift
				if (j + k) % 2 == 0 then
					yaw = math.rad((rng:NextNumber() * 2 - 1) * bl.face)
					shift = (if (j + k) % 4 == 0 then 1 else -1) * h * bl.lean
				else
					yaw = math.rad(bl.yaws[(yawAt + k + j) % #bl.yaws + 1])
					shift = 0
				end
				blade(`Blade{k}_{j}`, bx, bz, y0, y1, yaw, shift)
			end
		end
	end

	-- A few cars parked side-on on the open decks (never in the boutique's floor): the car park's scale.
	local pk = SHAPE.parked
	local parked = 0
	for k = 1, #gaps - 1 do
		if k + 1 ~= tallest and parked < pk.count then
			parked += 1
			local cx = bx0 + pk.long / 2 + rng:NextNumber() * math.max(0, bspan - pk.long)
			local deck = tops[k]
			local cz = zF + pk.z
			local paint = Kit.look(CAR_COLOURS[rng:NextInteger(1, #CAR_COLOURS)], Enum.Material.SmoothPlastic)
			Kit.trim(
				m,
				`Parked{k}`,
				Vector3.new(cx - pk.long / 2, deck + 0.7, cz),
				Vector3.new(cx + pk.long / 2, deck + 3.1, cz + pk.deep),
				paint
			)
			Kit.trim(
				m,
				`ParkedCabin{k}`,
				Vector3.new(cx - pk.long * 0.28, deck + 3.05, cz + 0.4),
				Vector3.new(cx + pk.long * 0.22, deck + 4.9, cz + pk.deep - 0.4),
				Kit.look(Color3.fromRGB(40, 48, 56), Enum.Material.Glass)
			)
		end
	end

	-------------------------------------------------------------------------------------------------------
	-- Ramps across the open floors, and the stair zigzagging up the front of one end
	-------------------------------------------------------------------------------------------------------
	local rp = SHAPE.ramp
	local rz = math.max(zF + 20, zB - rp.wide / 2 - 3)
	for i, k in { 1, 3 } do
		local ya, yb = tops[k], tops[k + 1]
		local run = math.min((yb - ya) / math.tan(rp.slope), span - 2 * rp.from)
		local xa = if i == 1 then x0 + rp.from else x1 - rp.from
		local xb = if i == 1 then xa + run else xa - run
		Kit.strut(m, `Ramp{i}`, Vector3.new(xa, ya, rz), Vector3.new(xb, yb, rz), 1.2, concrete, "box", rp.wide)
	end
	local flights = math.min(st.flights, #gaps - 1)
	local sx = x1 - 4 - stairRun / 2
	local sz = zF + 1.2
	for k = 1, flights do
		local ya, yb = floor(k), tops[k]
		local run = math.min(stairRun, (yb - ya) * st.run[1])
		local left = k % 2 == 1
		local a = Vector3.new(if left then sx - run / 2 else sx + run / 2, ya, sz)
		local b = Vector3.new(if left then sx + run / 2 else sx - run / 2, yb, sz)
		-- Board-formed like the slabs (a smooth stair read as a bright white brace across the end).
		Kit.strut(m, `Stair{k}`, a, b, st.thick, concrete, "trim", st.wide)
	end
	-- Cable rails along the open front edges (on the floors the stair reaches, they stop short of it).
	local rl = SHAPE.rail
	local stairEnd = x1 - 6 - stairRun - 1
	for k, e in edges do
		local r1 = if k <= flights then math.min(e.x1 - 0.6, stairEnd) else e.x1 - 0.6
		local rail = Kit.detail(
			m,
			`Rail{k}`,
			Vector3.new(e.x0 + 0.6, tops[k] + 0.05, e.z0 + rl.back),
			Vector3.new(r1, tops[k] + rl.tall, e.z0 + rl.back + 0.2),
			Kit.look(rl.color, Enum.Material.SmoothPlastic, nil, 1)
		)
		rail.textures = {
			{
				face = Kit.face(m, Enum.NormalId.Front),
				image = City.textures.slabLine,
				u = r1 - e.x0 - 0.6,
				v = rl.every,
				color = rl.color,
			},
		}
	end

	-------------------------------------------------------------------------------------------------------
	-- Glass: shop boxes under the first slab, a boutique in the tall floor, a paved plaza
	-------------------------------------------------------------------------------------------------------
	local sh = SHAPE.shop
	local glassOptions: Kit.GlassOptions = {
		image = City.textures.windowBold,
		faces = { Enum.NormalId.Front, Enum.NormalId.Left, Enum.NormalId.Right },
		u = 5,
		v = tops[1] - t - 0.2,
		lines = rgb(70, 74, 78),
		lit = true,
	}
	local shopTop = tops[1] - t - 0.02
	local mid = x0 + span * sh.share
	Kit.glass(
		m,
		"ShopA",
		Vector3.new(x0 + 3, 0.2, zF + sh.set),
		Vector3.new(mid, shopTop, zF + sh.set + sh.deep),
		pal.glass,
		glassOptions
	)
	local shopEnd = x1 - 6 - stairRun
	if shopEnd - (mid + 6) >= 8 then
		Kit.glass(
			m,
			"ShopB",
			Vector3.new(mid + 6, 0.2, zF + sh.set + 2),
			Vector3.new(shopEnd, shopTop, zF + sh.set + sh.deep),
			pal.glass,
			glassOptions
		)
	end
	-- The boutique stands back in the tall floor, behind its Vs and in front of the ramps.
	local by0, by1 = floor(tallest), tops[tallest] - t
	Kit.glass(
		m,
		"Boutique",
		Vector3.new(x0 + 3, by0, zF + 13),
		Vector3.new(x0 + 3 + span * 0.3, by1 - 0.02, zF + 22),
		pal.glass,
		{
			image = City.textures.windowBold,
			faces = { Enum.NormalId.Front, Enum.NormalId.Left, Enum.NormalId.Right },
			u = 4,
			v = by1 - by0,
			lines = rgb(70, 74, 78),
			lit = true,
		}
	)
	Kit.box(m, "Plaza", Vector3.new(-hw + 0.3, -0.6, -hd + 0.3), Vector3.new(hw - 0.3, 0.2, zB), concrete)

	-------------------------------------------------------------------------------------------------------
	-- The top: a neon number on the top slab, planters and hanging greenery, a penthouse or a canopy
	-------------------------------------------------------------------------------------------------------
	local top = edges[#gaps]
	local signX = x0 + 4
	Kit.sign(
		m,
		"Number",
		Vector3.new(signX, H - t - 3.4, top.z0 - 0.45),
		Vector3.new(signX + 13, H - t - 0.02, top.z0 - 0.15),
		Enum.NormalId.Front,
		NUMBERS[rng:NextInteger(1, #NUMBERS)],
		rgb(36, 38, 42),
		pal.sign,
		Enum.Font.Michroma
	)
	Kit.neon(
		m,
		"NumberNeon",
		Vector3.new(signX + 0.5, H - t - 4.1, top.z0 - 0.5),
		Vector3.new(signX + 12.5, H - t - 4.1, top.z0 - 0.5),
		pal.neon,
		pal.sign
	)
	-- Greenery spilling over the top edge from two planters: each a curtain of strands of uneven width and length in
	-- three greens, alternate strands a little further out, so the bottom edge is ragged and the curtain has depth.
	local vn = SHAPE.vine
	for i, at in { { 0.42, 0.58 }, { 0.7, 0.84 } } do
		local va, vb = x0 + span * at[1], x0 + span * at[2]
		local lengths = table.clone(vn.lengths)
		for k = #lengths, 2, -1 do
			local j = rng:NextInteger(1, k)
			lengths[k], lengths[j] = lengths[j], lengths[k]
		end
		local total = 0
		for _, w in vn.widths do
			total += w
		end
		local cursor = va
		for j, w in vn.widths do
			local wide = (vb - va) * w / total
			local s0 = math.max(va, cursor - vn.overlap)
			local s1 = math.min(vb, cursor + wide + vn.overlap)
			local out = if j % 2 == 1 then vn.out else 0
			local drop = vn.long * lengths[j] + rng:NextNumber() * vn.jitter
			Kit.detail(
				m,
				`Vine{i}_{j}`,
				Vector3.new(s0, H - t - drop, top.z0 - 0.3 - out),
				Vector3.new(s1, H + 0.2 + out * 0.5, top.z0 - 0.05 - out * 0.5),
				Kit.look(vn.greens[(i + j) % #vn.greens + 1], Enum.Material.Grass)
			)
			cursor += wide
		end
		Kit.planter(m, `Planter{i}`, Vector3.new(va, H, top.z0 + 1), Vector3.new(vb, H + 1.4, top.z0 + 3), smooth)
	end
	if variant.crown == 2 then
		-- A floating event canopy on three blades: one more slab, higher up.
		local cn = SHAPE.canopy
		local c0, c1 = top.z0 + 5, zB - 4
		Kit.trim(
			m,
			"Canopy",
			Vector3.new(x0 + 6, H + cn.rise, c0),
			Vector3.new(x1 - 6, H + cn.rise + cn.thick, c1),
			smooth
		)
		for j = 1, cn.blades do
			local bx = x0 + 10 + (span - 20) * (j - 1) / (cn.blades - 1)
			local yaw = math.rad(bl.yaws[(yawAt + j) % #bl.yaws + 1])
			blade(`CanopyBlade{j}`, bx, (c0 + c1) / 2, H, H + cn.rise, yaw, (j - 2) * 2)
		end
	else
		-- A glass penthouse under an overhanging roof slab.
		local ph = SHAPE.penthouse
		local px0, px1 = x0 + span * 0.5, x1 - 4
		local pz0, pz1 = top.z0 + 8, zB - 5
		Kit.glass(m, "Penthouse", Vector3.new(px0, H, pz0), Vector3.new(px1, H + ph.tall, pz1), pal.glass, {
			image = City.textures.windowBold,
			faces = { Enum.NormalId.Front, Enum.NormalId.Left, Enum.NormalId.Right },
			u = 4,
			v = ph.tall,
			lines = rgb(70, 74, 78),
			lit = true,
		})
		Kit.trim(
			m,
			"PenthouseRoof",
			Vector3.new(px0 - ph.over, H + ph.tall, pz0 - ph.over),
			Vector3.new(px1 + 1, H + ph.tall + ph.roof, pz1 + 1),
			smooth
		)
	end
end

local archetype: Types.Archetype = { id = "sculpted_car_park", build = build }
return archetype
