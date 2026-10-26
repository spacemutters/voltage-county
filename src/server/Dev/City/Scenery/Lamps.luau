--!strict
-- Streetlights (docs/city/SCENERY.md §5; Config/CityScenery lamps). Dev/MapBuilder addStreetlights keeps every post where
-- it always stood (the same spacing, sides and clear checks, and at most one in 200 studs casting light) and asks this
-- module what each one looks like:
--   avenue  the arterials: a tall pole, an arm out over the road and a flat head under its end (3 parts)
--   street  town streets: a slim pole and an elongated head reaching over the kerb (2 parts)
--   globe   the streets round the lake: a white pole under a frosted globe (2 parts)
-- The pole is the post a car hits (role light, it collides); the arm and head are decor; the head is the night light
-- (MapBuilder makes it one and gives the lit ones their SpotLight).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CityScenery = require(ReplicatedStorage.Shared.Config.CityScenery)
local Types = require(script.Parent.Types)

type PartSpec = Types.PartSpec
export type Style = CityScenery.LampStyle

local LAMPS = CityScenery.lamps
local QUARTER = math.pi / 2

local Lamps = {}

-- The style a road gets: by the zone of its `from` node, then by its kind (nil keeps MapBuilder's plain post).
function Lamps.style(zone: string, kind: string): Style?
	local byZone = LAMPS.byZone[zone]
	local name = (byZone and byZone[kind]) or LAMPS.byKind[kind]
	if name == nil then
		return nil
	end
	return (LAMPS :: any)[name] :: Style
end

local function part(
	folder: string,
	name: string,
	shape: "block" | "cylinder" | "ball",
	cframe: CFrame,
	size: Vector3,
	color: Color3,
	material: Enum.Material,
	solid: boolean
): PartSpec
	return {
		folder = folder,
		name = name,
		class = "Part",
		shape = shape,
		role = "light",
		size = size,
		cframe = cframe,
		color = color,
		material = material,
		collide = solid,
		query = solid,
		touch = false,
		shadow = solid,
		transparency = 0,
	}
end

export type Post = {
	pole: PartSpec, -- the post a car hits
	extras: { PartSpec }, -- an arm
	head: PartSpec, -- the night light
	headPlan: Vector2, -- the head's centre in plan
	headSize: Vector2, -- its footprint: across, along its reach
}

-- One streetlight of `style` named `name`, its pole's foot at plan point `at` on `base`, its head reaching `toward`
-- (a unit plan direction, over the road).
function Lamps.post(style: Style, folder: string, name: string, at: Vector2, base: number, toward: Vector2): Post
	local poleH = style.pole.Y
	local poleD = style.pole.X
	local foot = Vector3.new(at.X, base, at.Y)
	local facing = Vector3.new(toward.X, 0, toward.Y)
	local pole = part(
		folder,
		name,
		"cylinder",
		CFrame.new(foot + Vector3.yAxis * (poleH / 2)) * CFrame.Angles(0, 0, QUARTER),
		Vector3.new(poleH, poleD, poleD),
		style.poleColor,
		style.poleMaterial,
		true
	)
	local extras: { PartSpec } = {}
	local head: PartSpec
	local headAt: Vector3
	if style.globe then
		local d = style.head.X
		headAt = foot + Vector3.yAxis * (poleH + d * 0.42)
		head = part(
			folder,
			`{name}Head`,
			"ball",
			CFrame.new(headAt),
			Vector3.one * d,
			style.headColor,
			Enum.Material.SmoothPlastic,
			false
		)
	else
		local arm = style.arm
		local headY = poleH + style.head.Y / 2
		if arm then
			-- The arm leaves the pole just under its top and reaches out over the road; the head hangs under its end.
			local armY = poleH - 0.3 - arm.Y / 2
			local armAt = foot + facing * (arm.Z / 2) + Vector3.yAxis * armY
			table.insert(
				extras,
				part(
					folder,
					`{name}Arm`,
					"block",
					CFrame.lookAt(armAt, armAt + facing),
					Vector3.new(arm.X, arm.Y, arm.Z + poleD / 2),
					style.poleColor,
					style.poleMaterial,
					false
				)
			)
			headY = armY - arm.Y / 2 - style.head.Y / 2 + 0.02
		end
		headAt = foot + facing * style.reach + Vector3.yAxis * headY
		head = part(
			folder,
			`{name}Head`,
			"block",
			CFrame.lookAt(headAt, headAt + facing),
			style.head,
			style.headColor,
			Enum.Material.SmoothPlastic,
			false
		)
	end
	return {
		pole = pole,
		extras = extras,
		head = head,
		headPlan = Vector2.new(headAt.X, headAt.Z),
		headSize = Vector2.new(style.head.X, style.head.Z),
	}
end

return Lamps
