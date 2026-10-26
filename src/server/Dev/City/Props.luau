--!strict
-- Shared props (Config/CityProps: café sets, food trucks, market stalls, fountains, sculptures, the tower crane...),
-- each placed as one templated spec (Dev/MapTypes TemplateSpec): the spec stands for the prop's box, for the plan's
-- checks; the build clones ServerStorage.CityAssets.Props.<Name>, scales it to the box's height, stands its bottom
-- centre on the box's floor (`seat`) turned as the box, and while the template is missing puts up the prop's few
-- stand-in parts instead, marked so Dev/MapCheck fails until the template is back (Dev/City/Scenery
-- Palms.instantiate). Pure: it makes specs, never instances.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CityProps = require(ReplicatedStorage.Shared.Config.CityProps)
local MapTypes = require(script.Parent.Parent.MapTypes)

type PartSpec = MapTypes.PartSpec
type Role = MapTypes.Role

local QUARTER = math.pi / 2
local MIN_PIECE = 0.05 -- studs: a stand-in piece is never thinner than this

local Props = {}

Props.catalog = CityProps.props

-- Whether the catalog knows prop `name`.
function Props.known(name: string): boolean
	return CityProps.props[name] ~= nil
end

-- The stand-in parts for prop `prop` in the box `size` at `cframe` (its centre), in world space: a handful of plain
-- parts drawn in the box's own measure (Config/CityProps standIn).
function Props.standIn(
	folder: string,
	name: string,
	prop: string,
	cframe: CFrame,
	size: Vector3,
	role: Role
): { PartSpec }
	local info = CityProps.props[prop]
	local out: { PartSpec } = {}
	if info == nil then
		return out
	end
	for k, piece in info.standIn do
		local lo, hi = piece.from:Min(piece.to), piece.from:Max(piece.to)
		local a = Vector3.new(lo.X * size.X, lo.Y * size.Y - size.Y / 2, lo.Z * size.Z)
		local b = Vector3.new(hi.X * size.X, hi.Y * size.Y - size.Y / 2, hi.Z * size.Z)
		local d = (b - a):Max(Vector3.one * MIN_PIECE)
		local at = cframe * CFrame.new((a + b) / 2)
		local partSize: Vector3
		local shape: "block" | "cylinder" | "ball" = piece.shape
		if shape == "cylinder" then
			local across = math.min(d.X, d.Z)
			partSize = Vector3.new(d.Y, across, across)
			at *= CFrame.Angles(0, 0, QUARTER)
		elseif shape == "ball" then
			partSize = Vector3.one * math.min(d.X, d.Y, d.Z)
		else
			partSize = d
		end
		table.insert(out, {
			folder = folder,
			name = `{name}{k}`,
			class = "Part",
			shape = shape,
			role = role,
			size = partSize,
			cframe = at,
			color = piece.color,
			material = piece.material,
			collide = false,
			query = false,
			touch = false,
			shadow = true,
			transparency = 0,
		})
	end
	return out
end

-- The spec standing for prop `prop` (a Config/CityProps name) in the box `size` whose centre is `cframe`, the prop's
-- front toward the box's -Z. Invisible and decor: the build puts the clone (or the stand-in) in its place. Errors on a
-- prop the catalog doesn't know.
function Props.spec(folder: string, name: string, prop: string, cframe: CFrame, size: Vector3, role: Role): PartSpec
	local info = CityProps.props[prop]
	if info == nil then
		error(`Props: no prop {prop} in Config/CityProps`, 2)
	end
	local floor = cframe * CFrame.new(0, -size.Y / 2, 0) * CFrame.Angles(0, math.rad(info.turn), 0)
	return {
		folder = folder,
		name = name,
		class = "Part",
		shape = "block",
		role = role,
		size = size,
		cframe = cframe,
		color = Color3.fromRGB(200, 200, 200),
		material = Enum.Material.SmoothPlastic,
		collide = false,
		query = false,
		touch = false,
		shadow = false,
		transparency = 1,
		template = {
			path = { CityProps.root[1], CityProps.root[2], prop },
			pivot = floor,
			height = size.Y,
			variant = 1,
			fallback = prop,
			standIn = Props.standIn(folder, name, prop, cframe, size, role),
			seat = true,
			contain = info.contain,
		},
	}
end

return Props
