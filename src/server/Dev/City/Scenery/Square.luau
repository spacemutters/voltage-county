--!strict
-- The downtown square (docs/city/CITY_PLAN.md §5.4 and §6; Config/CityScenery townSquare): Town Square becomes a
-- palm plaza. An allée of royal palms round its edges, a round fountain at its heart (a stone basin, a pool, a
-- pedestal and a bowl, its jet glowing at night), benches on a ring facing the fountain, and planters at its corners.
-- Shade trees fill between (Config/Environment trees.parks.town_square). Through the placement grid like every piece.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Beach = require(script.Parent.Beach)
local CityScenery = require(ReplicatedStorage.Shared.Config.CityScenery)
local Kit = require(script.Parent.Parent.Kit)
local Palms = require(script.Parent.Palms)
local Piece = require(script.Parent.Piece)
local Types = require(script.Parent.Types)

type Host = Types.Host
type Ledger = Types.Ledger

local SQUARE = CityScenery.townSquare
local FURNITURE = CityScenery.furniture
local PALETTE = CityScenery.palette

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
	streetscape = true,
}
local PALM_BLOCKERS: { [string]: boolean } = table.clone(BLOCKERS)
PALM_BLOCKERS.tree = true

local Square = {}

-- Dresses the square, spending from `ledger`. Returns the parts added.
function Square.plan(host: Host, ledger: Ledger): number
	local park: Types.Park? = nil
	for _, p in host.parks do
		if p.id == SQUARE.park then
			park = p
		end
	end
	if park == nil then
		return 0
	end
	local square = park :: Types.Park
	local added = 0
	local rng = Random.new(host.seed * 13 + 5)
	local centre = (square.min + square.max) / 2
	local function place(id: string, frame: CFrame, min: Vector3, max: Vector3, draw: (m: any) -> ()): boolean
		local rect = Piece.rect(frame, min, max)
		if host.blocked(rect, BLOCKERS, 0) then
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

	-- The fountain.
	local f = SQUARE.fountain
	local stone = Kit.look(f.stone, Enum.Material.SmoothPlastic)
	local pool = Kit.look(f.pool, Enum.Material.Glass, 0.25, 0)
	local r = f.basin.X / 2
	local at = Vector3.new(centre.X, 0, centre.Y)
	place("Fountain", CFrame.new(at), Vector3.new(-r, 0, -r), Vector3.new(r, f.pedestal.Y + f.jet.Y + 1, r), function(m)
		Kit.column(m, "", 0, 0, -0.4, f.basin.Y, f.basin.X, stone)
		-- The pool brims just over the basin's stone, inside a ring of it.
		Kit.column(m, "Pool", 0, 0, f.basin.Y - 0.3, f.basin.Y + 0.08, f.basin.X - 2.6, pool, "detail")
		local top = f.basin.Y - 0.4 + f.pedestal.Y
		Kit.column(m, "Pedestal", 0, 0, f.basin.Y - 0.5, top, f.pedestal.X, stone)
		Kit.disc(m, "Bowl", 0, 0, top + f.bowl.Y / 2, f.bowl.X, f.bowl.Y, stone)
		Kit.column(m, "BowlPool", 0, 0, top + f.bowl.Y - 0.1, top + f.bowl.Y + 0.08, f.bowl.X - 1.4, pool, "detail")
		local jet = Kit.column(
			m,
			"Jet",
			0,
			0,
			top + f.bowl.Y,
			top + f.bowl.Y + f.jet.Y,
			f.jet.X,
			Kit.look(Color3.fromRGB(236, 248, 250), Enum.Material.SmoothPlastic),
			"detail"
		)
		Kit.lit(jet, "sign")
	end)

	-- Benches on a ring round it, facing in.
	local wood = Kit.look(PALETTE.wood, Enum.Material.WoodPlanks)
	local base = Kit.look(PALETTE.terrazzo, Enum.Material.SmoothPlastic)
	local bench = FURNITURE.bench
	for k = 1, SQUARE.benches do
		local angle = (k - 0.5) / SQUARE.benches * 2 * math.pi
		local p = centre + Vector2.new(math.cos(angle), math.sin(angle)) * SQUARE.benchRing
		local pos = Vector3.new(p.X, 0, p.Y)
		local frame = CFrame.lookAt(pos, Vector3.new(centre.X, 0, centre.Y))
		local w = bench.seat.X / 2
		place(`SquareBench{k}`, frame, Vector3.new(-w, 0, -1), Vector3.new(w, 3.6, 1.2), function(m)
			Beach.drawBench(m, wood, base)
		end)
	end

	-- Planters at the corners, inside the allée.
	local planter = FURNITURE.planter
	local inset = SQUARE.allee.inset
	for k, corner in
		{ square.min, Vector2.new(square.max.X, square.min.Y), square.max, Vector2.new(square.min.X, square.max.Y) }
	do
		local toward = (centre - corner).Unit
		local p = corner + toward * (inset * 1.414 + 9)
		local pos = Vector3.new(p.X, 0, p.Y)
		local hx, hz = planter.size.X / 2, planter.size.Z / 2
		place(
			`Planter{k}`,
			CFrame.new(pos),
			Vector3.new(-hx, 0, -hz),
			Vector3.new(hx, planter.size.Y + 1.6, hz),
			function(m)
				Kit.planter(
					m,
					"",
					Vector3.new(-hx, -0.5, -hz),
					Vector3.new(hx, planter.size.Y, hz),
					Kit.look(planter.color, Enum.Material.Concrete)
				)
			end
		)
	end

	-- The allée: royal palms round the edges, `inset` in, one every `spacing`.
	local allee = SQUARE.allee
	local species = Palms.species[allee.species]
	if species == nil then
		return added
	end
	local x0, x1 = square.min.X + inset, square.max.X - inset
	local z0, z1 = square.min.Y + inset, square.max.Y - inset
	local corners = { Vector2.new(x0, z0), Vector2.new(x1, z0), Vector2.new(x1, z1), Vector2.new(x0, z1) }
	local count = 0
	for i = 1, 4 do
		local a, b = corners[i], corners[i % 4 + 1]
		local length = (b - a).Magnitude
		local n = math.max(1, math.floor(length / allee.spacing))
		for j = 0, n - 1 do
			local p = a + (b - a) * (j / n)
			local rolls: Palms.Rolls = {
				scale = rng:NextNumber(),
				yaw = rng:NextNumber(),
				lean = rng:NextNumber(),
				variant = rng:NextNumber(),
			}
			local room = Piece.square(p, species.collider.X / 2 + 2)
			if host.blocked(room, PALM_BLOCKERS, 0) or not Piece.take(ledger, 2) then
				continue
			end
			count += 1
			local folder = Piece.tile(host, p.X, p.Y)
			local trunk, crown = Palms.specs(
				folder,
				`SquarePalm{count}`,
				"scenery",
				allee.species,
				Vector3.new(p.X, host.groundAt(p.X, p.Y), p.Y),
				rolls.yaw * 2 * math.pi,
				rolls
			)
			host.add(trunk)
			host.add(crown)
			added += 2
			host.reserve(Piece.square(p, 4.5), "tree")
		end
	end
	return added
end

return Square
