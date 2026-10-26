--!strict
-- The beach (docs/city/SCENERY.md §2 and §6; docs/city/CITY_PLAN.md §3.2; Config/CityScenery beach): Lakefront Park's
-- sand band between the north shore road's lawn and the bay, dressed from the land out to the water:
--   the promenade   a terrazzo walk along the lawn edge, in long runs (it passes under the causeway between its piers)
--   the wall        a low wavy coral-stone wall on its sand side, open at every boardwalk and shower
--   lamps, benches  globe lamps and benches along the walk, facing the sea
--   palms           clumps of coconut palms on the sand behind the dunes, leaning toward the water
--   dunes           low sand ridges with dune grass along their crests
--   lifeguard stands  one every `standSpread` studs (Dev/City/Scenery LifeguardStand: four shapes in turn, each stand
--                   its own colours), a boardwalk from the promenade to each one's ramp
--   the open sand   umbrella-and-lounger sets near the water between the stands, showers by the wall, two
--                   volleyball nets
-- Everything keeps clear of the causeway, every gameplay spot and each other through the placement grid, and stays
-- decor except what a player would stand on (the stands, the walk, the boardwalks) and the dunes a car can climb.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CityScenery = require(ReplicatedStorage.Shared.Config.CityScenery)
local Kit = require(script.Parent.Parent.Kit)
local LifeguardStand = require(script.Parent.LifeguardStand)
local Palms = require(script.Parent.Palms)
local Piece = require(script.Parent.Piece)
local Types = require(script.Parent.Types)

type Host = Types.Host
type Ledger = Types.Ledger
type Rect = Types.Rect

local BEACH = CityScenery.beach
local LIFEGUARD = CityScenery.lifeguard
local FURNITURE = CityScenery.furniture
local PALETTE = CityScenery.palette

-- What beach pieces keep off.
local BLOCKERS: { [string]: boolean } = {
	road = true,
	sidewalk = true,
	driveway = true,
	support = true,
	location = true,
	access = true,
	prop = true,
	light = true,
	lamp = true,
	landmark = true,
	feature = true,
	lot = true,
	ramp = true,
	lake = true,
	streetscape = true,
}
-- ...and palms keep off other trees too.
local PALM_BLOCKERS: { [string]: boolean } = table.clone(BLOCKERS)
PALM_BLOCKERS.tree = true
-- The walk only keeps off what stands on the ground (it passes under the causeway's deck).
local WALK_BLOCKERS: { [string]: boolean } = {
	support = true,
	location = true,
	access = true,
	prop = true,
	feature = true,
	landmark = true,
	lot = true,
	light = true,
	ramp = true,
}
local UNDER_DECK: { [string]: boolean } = {
	location = true,
	access = true,
	prop = true,
	feature = true,
	landmark = true,
	lot = true,
}

local Beach = {}

-- The beach's band: its park, the way out to sea along z (+1 or -1) and the z of a depth `d` from its land edge.
local function band(host: Host): (Types.Park?, number, (number) -> number)
	local park: Types.Park? = nil
	for _, p in host.parks do
		if p.id == BEACH.park then
			park = p
		end
	end
	if park == nil then
		return nil, 1, function(d: number): number
			return d
		end
	end
	local found = park :: Types.Park
	local mid = (found.min.Y + found.max.Y) / 2
	local sea = 1
	local nearest = math.huge
	for _, lake in host.lakes do
		local lz = (lake.min.Y + lake.max.Y) / 2
		if math.abs(lz - mid) < nearest then
			nearest = math.abs(lz - mid)
			sea = if lz > mid then 1 else -1
		end
	end
	local land = if sea > 0 then found.min.Y else found.max.Y
	return found, sea, function(d: number): number
		return land + sea * d
	end
end

local function near(x: number, list: { number }, within: number): boolean
	for _, other in list do
		if math.abs(x - other) < within then
			return true
		end
	end
	return false
end

-- Dresses the beach, spending from `ledger`. Returns how many parts it added.
function Beach.plan(host: Host, ledger: Ledger): number
	local park, sea, zAt = band(host)
	if park == nil then
		return 0
	end
	local beach = park :: Types.Park
	local rng = Random.new(host.seed * 31 + 7)
	local added = 0
	local x0, x1 = beach.min.X + BEACH.margin, beach.max.X - BEACH.margin
	local seaward = Vector3.new(0, 0, sea)
	local function frameAt(x: number, d: number, y: number?): CFrame
		local at = Vector3.new(x, y or 0, zAt(d))
		return CFrame.lookAt(at, at + seaward)
	end
	local function clear(rect: Rect, kinds: { [string]: boolean }): boolean
		return not host.blocked(rect, kinds, 0)
	end

	-- Where the causeway crosses the band (its middle line).
	local bridges: { number } = {}
	local midZ = zAt((beach.max.Y - beach.min.Y) / 2)
	for _, street in host.streets do
		if street.kind == "bridge" and math.abs(street.u.Y) > 1e-6 then
			local t = (midZ - street.a.Y) / street.u.Y
			if t >= 0 and t <= street.length then
				table.insert(bridges, street.a.X + street.u.X * t)
			end
		end
	end
	local function free(x: number): boolean
		return x >= x0 and x <= x1 and not near(x, bridges, BEACH.bridgeClear)
	end

	-- A piece drawn with the kit: built by `draw`, kept when its footprint (local min..max) is clear and the ledger has
	-- room, then filed and reserved.
	local function place(
		id: string,
		frame: CFrame,
		min: Vector3,
		max: Vector3,
		kinds: { [string]: boolean },
		draw: (m: any) -> ()
	): boolean
		local rect = Piece.rect(frame, min, max)
		if not clear(rect, kinds) then
			return false
		end
		local m = Piece.model(id, frame, host.seed)
		draw(m)
		if not Piece.take(ledger, #m.specs) then
			return false
		end
		added += Piece.finish(host, m)
		host.reserve(rect, "streetscape")
		return true
	end

	-- The lifeguard stands first (everything else makes room for them), each with its boardwalk's x.
	local promenade = BEACH.promenade
	local walkEdge = promenade.from + promenade.width -- the walk's sea edge
	local stands: { number } = {}
	local boardwalks: { { x: number, d: number } } = {}
	local count = BEACH.stands
	local centre = (beach.min.X + beach.max.X) / 2
	local plat = LIFEGUARD.platform
	local rise = LIFEGUARD.deck - 0.2
	local run = math.sqrt(math.max(1, LIFEGUARD.ramp.length ^ 2 - rise ^ 2))
	local back = plat.Z / 2 + run
	for k = 1, count do
		local x = centre + (k - (count + 1) / 2) * BEACH.standSpread + (rng:NextNumber() - 0.5) * 24
		local d = BEACH.standsAt + (rng:NextNumber() - 0.5) * 8
		if not free(x) then
			continue
		end
		local frame = frameAt(x, d)
		local shapes = LIFEGUARD.shapes
		local schemes = LIFEGUARD.schemes
		local shape = shapes[(k - 1) % #shapes + 1]
		local scheme = schemes[((k - 1) * 3) % #schemes + 1]
		local min = Vector3.new(-plat.X / 2 - 0.5, 0, -plat.Z / 2 - 0.5)
		local max = Vector3.new(plat.X / 2 + 0.5, 22, back + 0.5)
		local ok = place(`Guard{k}`, frame, min, max, BLOCKERS, function(m)
			LifeguardStand.build(m, shape, scheme, k)
		end)
		if ok then
			table.insert(stands, x)
			local foot = frame * Vector3.new(4.4, 0, back)
			table.insert(boardwalks, { x = foot.X, d = d - back })
		end
	end

	-- Boardwalks from the promenade over the dunes to each stand's ramp.
	local gaps: { number } = {}
	for k, walk in boardwalks do
		-- From just over the walk's edge to just short of the stand's ramp (its footprint is the stand's).
		local from, to = walkEdge - 0.5, walk.d - 0.6
		if to - from < 4 then
			continue
		end
		local w = BEACH.boardwalk.width / 2
		local frame = frameAt(walk.x, (from + to) / 2)
		local half = (to - from) / 2
		local min, max = Vector3.new(-w, 0.02, -half), Vector3.new(w, 0.02 + BEACH.boardwalk.thick, half)
		local ok = place(`Boardwalk{k}`, frame, min, max, BLOCKERS, function(m)
			Kit.box(m, "", min, max, Kit.look(BEACH.boardwalk.color, Enum.Material.WoodPlanks))
		end)
		if ok then
			table.insert(gaps, walk.x)
		end
	end

	-- Showers by the wall and volleyball nets on the open sand, in the gaps between stands.
	local between: { number } = {}
	for k = 1, #stands - 1 do
		local x = (stands[k] + stands[k + 1]) / 2
		if free(x) then
			table.insert(between, x)
		end
	end
	local showers = 0
	for k, x in between do
		if showers >= BEACH.showers or k % 2 == 0 then
			continue
		end
		local d = BEACH.wall.from + 4
		local min, max = Vector3.new(-1.4, 0, -1.8), Vector3.new(1.4, 9, 1.4)
		local ok = place(`Shower{k}`, frameAt(x, d), min, max, BLOCKERS, function(m)
			local chrome = Kit.look(Color3.fromRGB(214, 220, 226), Enum.Material.Metal)
			Kit.column(m, "", 0, 0, -1, 8, 0.4, chrome)
			Kit.detail(m, "Head", Vector3.new(-0.2, 7.5, -1.6), Vector3.new(0.2, 7.8, 0.1), chrome)
			Kit.disc(m, "Plate", 0, -0.9, 0.08, 2.6, 0.12, Kit.look(PALETTE.coral, Enum.Material.Limestone), "detail")
		end)
		if ok then
			showers += 1
			table.insert(gaps, x)
		end
	end
	local nets = 0
	for k, x in between do
		if nets >= BEACH.nets or k % 2 == 1 or k == 1 then
			continue
		end
		local min, max = Vector3.new(-14.5, 0, -1), Vector3.new(14.5, 8, 1)
		local ok = place(`Net{k}`, frameAt(x, 66), min, max, BLOCKERS, function(m)
			local white = Kit.look(PALETTE.white, Enum.Material.SmoothPlastic)
			Kit.column(m, "PostL", -14, 0, -1, 8, 0.35, white)
			Kit.column(m, "PostR", 14, 0, -1, 8, 0.35, white)
			Kit.detail(
				m,
				"",
				Vector3.new(-14, 4.6, -0.05),
				Vector3.new(14, 7.4, 0.05),
				Kit.look(Color3.fromRGB(40, 44, 50), Enum.Material.SmoothPlastic, 0, 0.4)
			)
			Kit.detail(m, "Band", Vector3.new(-14, 7.4, -0.08), Vector3.new(14, 7.7, 0.08), white)
		end)
		if ok then
			nets += 1
		end
	end

	-- The promenade: long runs of terrazzo wherever the ground under it is clear.
	local step = 4
	local samples: { boolean } = {}
	local xs: { number } = {}
	local d0, d1 = promenade.from, promenade.from + promenade.width
	local x = x0
	while x <= x1 do
		table.insert(xs, x)
		local rect: Rect = {
			c = Vector2.new(x, (zAt(d0) + zAt(d1)) / 2),
			u = Vector2.xAxis,
			ha = step / 2,
			hc = promenade.width / 2,
		}
		-- Under the causeway the grid's supports are its balustrades high overhead (and its piers, which stand clear of
		-- the walk's strip: tests/CityScenery.spec checks), so there it only keeps off the spots on the ground.
		local kinds = if near(x, bridges, 40) then UNDER_DECK else WALK_BLOCKERS
		table.insert(samples, clear(rect, kinds))
		x += step
	end
	local walkRuns: { { number } } = {}
	local open: number? = nil
	for i, ok in samples do
		if ok and open == nil then
			open = xs[i] - step / 2
		end
		local closing = (not ok) or i == #samples
		if closing and open then
			local stop = if ok then xs[i] + step / 2 else xs[i] - step / 2
			local start = open :: number
			-- A part may be at most 2,048 long: split long runs (and at the causeway, where the walk's two halves meet).
			local cuts = { start }
			for _, bx in bridges do
				if bx > start + 20 and bx < stop - 20 then
					table.insert(cuts, bx)
				end
			end
			table.insert(cuts, stop)
			table.sort(cuts)
			for k = 1, #cuts - 1 do
				local a, b = cuts[k], cuts[k + 1]
				local pieces = math.ceil((b - a) / 2000)
				for j = 1, pieces do
					table.insert(walkRuns, { a + (b - a) * (j - 1) / pieces, a + (b - a) * j / pieces })
				end
			end
			open = nil
		end
	end
	for k, span in walkRuns do
		if span[2] - span[1] < 20 then
			continue
		end
		local cx = (span[1] + span[2]) / 2
		local frame = frameAt(cx, (d0 + d1) / 2)
		local half = (span[2] - span[1]) / 2
		local min = Vector3.new(-half, 0.02, -promenade.width / 2)
		local max = Vector3.new(half, 0.02 + promenade.thick, promenade.width / 2)
		local m = Piece.model(`BeachWalk{k}`, frame, host.seed)
		local slab = Kit.box(m, "", min, max, Kit.look(promenade.color, promenade.material))
		slab.materialVariant = promenade.variant
		if Piece.take(ledger, #m.specs) then
			added += Piece.finish(host, m)
		end
	end
	local function onWalk(at: number): boolean
		for _, span in walkRuns do
			if at > span[1] + 4 and at < span[2] - 4 then
				return true
			end
		end
		return false
	end

	-- Benches on the walk's land edge facing the sea, and globe lamps on its sea edge.
	local wood = Kit.look(PALETTE.wood, Enum.Material.WoodPlanks)
	local stone = Kit.look(PALETTE.terrazzo, Enum.Material.SmoothPlastic)
	local bench = FURNITURE.bench
	local k = 0
	x = x0 + BEACH.benchEvery / 2
	while x < x1 do
		if free(x) and onWalk(x) and not near(x, gaps, 8) then
			k += 1
			local seatW = bench.seat.X / 2
			local min, max = Vector3.new(-seatW, 0, -1), Vector3.new(seatW, 3.6, 1.2)
			place(`Bench{k}`, frameAt(x, d0 + 1.4, 0.16), min, max, BLOCKERS, function(m)
				Beach.drawBench(m, wood, stone)
			end)
		end
		x += BEACH.benchEvery
	end
	k = 0
	x = x0 + BEACH.lampEvery / 3
	while x < x1 do
		if free(x) and onWalk(x) and not near(x, gaps, 6) then
			k += 1
			local min, max = Vector3.new(-0.8, 0, -0.8), Vector3.new(0.8, 12.5, 0.8)
			place(`BeachLamp{k}`, frameAt(x, d1 - 0.8, 0.16), min, max, BLOCKERS, function(m)
				Kit.column(m, "", 0, 0, -1, 11, 0.35, Kit.look(PALETTE.white, Enum.Material.SmoothPlastic))
				local globe = Kit.ball(
					m,
					"Globe",
					Vector3.new(0, 11.5, 0),
					1.3,
					Kit.look(Color3.fromRGB(252, 250, 244), Enum.Material.SmoothPlastic)
				)
				Kit.lit(globe, "streetlight")
			end)
		end
		x += BEACH.lampEvery
	end

	-- The low wavy wall: a zigzag of short runs on the walk's sand side, open at the gaps and the causeway.
	local wall = BEACH.wall
	local points: { Vector2 } = {}
	x = x0
	local flip = 1
	while x <= x1 do
		table.insert(points, Vector2.new(x, zAt(wall.from + flip * wall.amplitude)))
		flip = -flip
		x += wall.run
	end
	local stoneLook = Kit.look(PALETTE.coral, Enum.Material.Limestone)
	for i = 1, #points - 1 do
		local p, q = points[i], points[i + 1]
		local mx = (p.X + q.X) / 2
		if not free(mx) or near(mx, gaps, wall.run / 2 + wall.gap / 2) then
			continue
		end
		local mid = (p + q) / 2
		local length = (q - p).Magnitude + wall.thick
		local at = Vector3.new(mid.X, 0, mid.Y)
		local frame = CFrame.lookAt(at, at + Vector3.new(q.X - p.X, 0, q.Y - p.Y))
		local min = Vector3.new(-wall.thick / 2, -0.4, -length / 2)
		local max = Vector3.new(wall.thick / 2, wall.height - 0.4, length / 2)
		place(`BeachWall{i}`, frame, min, max, BLOCKERS, function(m)
			Kit.trim(m, "", min, max, stoneLook)
		end)
	end

	-- Coconut palms in clumps on the sand behind the dunes, leaning toward the water.
	local palms = BEACH.palms
	local palmCount = 0
	x = x0 + 20
	while x < x1 - 20 do
		local clump = palms.clump[1] + math.floor(rng:NextNumber() * (palms.clump[2] - palms.clump[1] + 1))
		for _ = 1, clump do
			local px = x + (rng:NextNumber() - 0.5) * 18
			local pd = palms.from + rng:NextNumber() * (palms.to - palms.from)
			local rolls: Palms.Rolls = {
				scale = rng:NextNumber(),
				yaw = rng:NextNumber(),
				lean = rng:NextNumber(),
				variant = rng:NextNumber(),
			}
			if not free(px) or near(px, gaps, 7) then
				continue
			end
			local species = Palms.species.coconut
			local trunkAt = Vector2.new(px, zAt(pd))
			local room = Piece.square(trunkAt, species.collider.X / 2 + 3.5)
			if not clear(room, PALM_BLOCKERS) or not Piece.take(ledger, 2) then
				continue
			end
			-- It leans toward its front (-Z): turn its front out to sea, give or take.
			local outward = if sea > 0 then math.pi else 0
			local yaw = outward + math.rad(palms.leanToward) * (2 * rolls.yaw - 1)
			palmCount += 1
			local folder = Piece.tile(host, px, trunkAt.Y)
			local trunk, crown = Palms.specs(
				folder,
				`BeachPalm{palmCount}`,
				"scenery",
				"coconut",
				Vector3.new(px, host.groundAt(px, trunkAt.Y), trunkAt.Y),
				yaw,
				rolls
			)
			host.add(trunk)
			host.add(crown)
			added += 2
			host.reserve(room, "tree")
		end
		x += palms.every
	end

	-- A row of coconut palms on the lawn along the promenade's land side, leaning every which way.
	local lawn = BEACH.lawn
	x = x0 + lawn.every / 2
	while x < x1 do
		local px = x + (rng:NextNumber() - 0.5) * 10
		local pd = lawn.at + (rng:NextNumber() - 0.5) * 3
		local rolls: Palms.Rolls = {
			scale = rng:NextNumber(),
			yaw = rng:NextNumber(),
			lean = rng:NextNumber(),
			variant = rng:NextNumber(),
		}
		x += lawn.every
		if not free(px) then
			continue
		end
		local trunkAt = Vector2.new(px, zAt(pd))
		local room = Piece.square(trunkAt, Palms.species.coconut.collider.X / 2 + 3.5)
		if not clear(room, PALM_BLOCKERS) or not Piece.take(ledger, 2) then
			continue
		end
		palmCount += 1
		local trunk, crown = Palms.specs(
			Piece.tile(host, px, trunkAt.Y),
			`BeachPalm{palmCount}`,
			"scenery",
			"coconut",
			Vector3.new(px, host.groundAt(px, trunkAt.Y), trunkAt.Y),
			rolls.yaw * 2 * math.pi,
			rolls
		)
		host.add(trunk)
		host.add(crown)
		added += 2
		host.reserve(room, "tree")
	end

	-- Dunes: low ridges along the back of the open sand, dune grass on their crests.
	local dunes = BEACH.dunes
	local spread = (x1 - x0) / dunes.count
	for i = 1, dunes.count do
		local dx = x0 + (i - 0.5) * spread + (rng:NextNumber() - 0.5) * spread * 0.4
		local length = dunes.length[1] + rng:NextNumber() * (dunes.length[2] - dunes.length[1])
		local height = dunes.height[1] + rng:NextNumber() * (dunes.height[2] - dunes.height[1])
		local dd = dunes.at + (rng:NextNumber() - 0.5) * 6
		if not free(dx) or near(dx, gaps, length / 2 + 4) then
			continue
		end
		local depth = dunes.depth
		local L = length / 2
		local min, max = Vector3.new(-L, -0.3, -depth), Vector3.new(L, height + 0.6, depth)
		place(`Dune{i}`, frameAt(dx, dd), min, max, BLOCKERS, function(m)
			local sand = Kit.look(dunes.color, Enum.Material.Sand)
			local grass = Kit.look(dunes.grass, Enum.Material.LeafyGrass)
			-- Two slopes back to back: the land side rising toward the sea to the crest, the sea side falling away.
			Kit.wedge(m, "Land", Vector3.new(-L, -0.3, 0), Vector3.new(L, height, depth), "front", sand)
			Kit.wedge(
				m,
				"Sea",
				Vector3.new(-L * 0.9, -0.3, -depth),
				Vector3.new(L * 0.9, height - 0.02, 0),
				"back",
				sand
			)
			Kit.trim(
				m,
				"Grass1",
				Vector3.new(-L * 0.55, height - 0.6, -0.5),
				Vector3.new(L * 0.35, height + 0.5, 1.1),
				grass
			)
			Kit.trim(
				m,
				"Grass2",
				Vector3.new(-L * 0.1, height - 0.9, 0.6),
				Vector3.new(L * 0.65, height + 0.2, 2.2),
				grass
			)
		end)
	end

	-- Umbrella-and-lounger sets on the open sand near the water, between the stands.
	local sets = BEACH.sets
	local edges = { x0 }
	for _, sx in stands do
		table.insert(edges, sx)
	end
	table.insert(edges, x1)
	table.sort(edges)
	local setCount = 0
	for i = 1, #edges - 1 do
		local a, b = edges[i] + sets.standClear, edges[i + 1] - sets.standClear
		if b - a < 12 then
			continue
		end
		local n = math.min(sets.perGap, math.floor((b - a) / 16) + 1)
		for j = 1, n do
			local sx = a + (b - a) * (j - 0.5) / n + (rng:NextNumber() - 0.5) * 8
			local sd = sets.from + rng:NextNumber() * (sets.to - sets.from)
			local colour = BEACH.umbrellas[(setCount % #BEACH.umbrellas) + 1]
			local towel = BEACH.loungers[(setCount % #BEACH.loungers) + 1]
			if not free(sx) then
				continue
			end
			local r = sets.canopy / 2
			local min, max = Vector3.new(-r, 0, -r), Vector3.new(r, 8, r)
			local ok = place(`Sun{setCount + 1}`, frameAt(sx, sd), min, max, BLOCKERS, function(m)
				Kit.column(m, "Pole", 0, 0, -0.6, 7.4, 0.25, Kit.look(PALETTE.white, Enum.Material.Metal), "detail")
				Kit.disc(m, "", 0, 0, 7.2, sets.canopy, 0.35, Kit.look(colour, Enum.Material.SmoothPlastic))
				Kit.ball(
					m,
					"Finial",
					Vector3.new(0, 7.55, 0),
					0.6,
					Kit.look(PALETTE.white, Enum.Material.SmoothPlastic)
				)
				local lounger = sets.loungers
				local look = Kit.look(towel, Enum.Material.SmoothPlastic)
				for s, side in { -1, 1 } do
					local cx = side * (lounger[1] / 2 + 0.5)
					Kit.wedge(
						m,
						`Lounger{s}`,
						Vector3.new(cx - lounger[1] / 2, 0.05, -lounger[3] / 2),
						Vector3.new(cx + lounger[1] / 2, 0.05 + lounger[2], lounger[3] / 2),
						"back",
						look,
						"trim"
					)
				end
			end)
			if ok then
				setCount += 1
			end
		end
	end
	return added
end

-- A bench in its own frame (front -Z, where you face when sitting): a base, a seat and a back. 3 parts.
function Beach.drawBench(m: any, wood: Kit.Look, stone: Kit.Look)
	local bench = FURNITURE.bench
	local w = bench.seat.X / 2
	local h = bench.height
	Kit.box(m, "Base", Vector3.new(-w + 0.6, -0.5, -0.5), Vector3.new(w - 0.6, h - 0.2, 0.5), stone)
	Kit.trim(m, "", Vector3.new(-w, h - 0.2, -bench.seat.Z / 2), Vector3.new(w, h + 0.2, bench.seat.Z / 2), wood)
	Kit.trim(
		m,
		"Back",
		Vector3.new(-w, h + 0.2, bench.seat.Z / 2 - bench.back.Z),
		Vector3.new(w, h + 0.2 + bench.back.Y, bench.seat.Z / 2),
		wood
	)
end

return Beach
