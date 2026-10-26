--!strict
-- C09 causeway_bridge (docs/city/ARCHETYPES.md §9 C09; docs/city/SCENERY.md §4; Config/CityScenery causeway): the lake
-- bridge restyled as a white causeway, without moving its deck, its heights or its road. Dev/MapBuilder keeps planning
-- where everything goes (its supports, pillars and streetlights, at the same places and through the same checks) and
-- asks this module for the pieces on the bridge's edges:
--   balustrade  each deck edge: a white plinth that drops below the slab as the fascia, a panel (a pierced X pattern
--               once its image exists; until then a solid panel set in), a coping on top, a sea-blue line along the
--               fascia and under it a strip that glows icy blue at night (the bridge-at-night look)
--   pier        round white piers in place of the square pillars
--   cap, haunches  over the water each pier pair carries a cap beam under the deck, and every span springs a shallow
--               arch from the caps (two haunches a side), so the bay sees a row of white arches
--   lamp        acorn lamps on the coping, staggered along both sides
--   ribColor    the steel arches' night gradient, cyan at the feet to pink at the crown
-- Every piece is a support (Bridges) or a light (Streetlights), as the bridge's pieces always were.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CityScenery = require(ReplicatedStorage.Shared.Config.CityScenery)
local Types = require(script.Parent.Types)

type PartSpec = Types.PartSpec

local C = CityScenery.causeway
local PALETTE = CityScenery.palette
local QUARTER = math.pi / 2

local Causeway = {}

local function spec(
	folder: string,
	name: string,
	role: "support" | "light",
	shape: "block" | "wedge" | "cylinder" | "ball",
	cframe: CFrame,
	size: Vector3,
	color: Color3,
	material: Enum.Material,
	solid: boolean
): PartSpec
	return {
		folder = folder,
		name = name,
		class = if shape == "wedge" then "WedgePart" else "Part",
		shape = shape,
		role = role,
		size = size,
		cframe = cframe,
		color = color,
		material = material,
		collide = solid,
		query = solid,
		touch = false,
		shadow = true,
		transparency = 0,
	}
end

-- The balustrade on one side (`side` +1 right, -1 left) of a raised road whose top runs along `frame` (centred on the
-- surface, looking along the road, right vector level) for `length` studs, `half` studs either side of its centre line.
-- Returns its parts, how far in and out from the centre line they reach (for the placement grid), and the glow strip
-- among them (MapBuilder makes it a night light of `Causeway.glowKind`).
function Causeway.balustrade(
	folder: string,
	name: string,
	frame: CFrame,
	length: number,
	half: number,
	side: number
): ({ PartSpec }, number, number, PartSpec)
	local out: { PartSpec } = {}
	local function piece(
		suffix: string,
		x0: number,
		x1: number,
		y0: number,
		y1: number,
		color: Color3,
		material: Enum.Material,
		solid: boolean
	): PartSpec
		local cx = side * (half + (x0 + x1) / 2)
		local p = spec(
			folder,
			`{name}{suffix}`,
			"support",
			"block",
			frame * CFrame.new(cx, (y0 + y1) / 2, 0),
			Vector3.new(x1 - x0, y1 - y0, length),
			color,
			material,
			solid
		)
		table.insert(out, p)
		return p
	end
	local plinth, panel, coping = C.plinth, C.panel, C.coping
	local white = PALETTE.concrete
	piece("", 0, plinth.thick, -plinth.drop, plinth.top, white, Enum.Material.Concrete, true)
	local inset = (plinth.thick - panel.thick) / 2
	local pane = piece(
		"Panel",
		inset,
		inset + panel.thick,
		plinth.top,
		panel.top,
		if C.balustradeImage then white else Color3.fromRGB(222, 220, 214),
		Enum.Material.SmoothPlastic,
		true
	)
	local image = C.balustradeImage
	if image then
		-- The pierced pattern: the panel itself turns see-through and shows the image on both faces (it still stops a car).
		pane.transparency = 1
		pane.shadow = false
		local tile = C.balustradeTile
		pane.textures = {
			{ face = Enum.NormalId.Left, image = image, u = tile, v = panel.top - plinth.top, color = white },
			{ face = Enum.NormalId.Right, image = image, u = tile, v = panel.top - plinth.top, color = white },
		}
	end
	local overhang = (coping.thick - plinth.thick) / 2
	piece("Coping", -overhang, plinth.thick + overhang, panel.top, coping.top, white, Enum.Material.Concrete, true)
	-- The fascia's sea-blue line and the glow strip under it.
	local line = piece(
		"Line",
		plinth.thick,
		plinth.thick + 0.06,
		C.accent.from,
		C.accent.to,
		PALETTE.seaBlue,
		Enum.Material.SmoothPlastic,
		false
	)
	line.shadow = false
	local glow = piece(
		"Glow",
		plinth.thick,
		plinth.thick + C.glow.thick,
		-plinth.drop,
		-plinth.drop + C.glow.tall,
		Color3.fromRGB(232, 232, 228),
		Enum.Material.SmoothPlastic,
		false
	)
	glow.shadow = false
	return out, half - overhang, half + plinth.thick + C.glow.thick, glow
end

-- A round pier from `bottom` up to `top` at plan point `at`.
function Causeway.pier(folder: string, name: string, at: Vector2, bottom: number, top: number): PartSpec
	local tall = top - bottom
	return spec(
		folder,
		name,
		"support",
		"cylinder",
		CFrame.new(at.X, (top + bottom) / 2, at.Y) * CFrame.Angles(0, 0, QUARTER),
		Vector3.new(tall, C.pier, C.pier),
		PALETTE.concrete,
		Enum.Material.Concrete,
		true
	)
end

-- The cap beam across a pier pair, its top at `top` (just under the deck), `width` across the road (along `l`), at plan
-- point `at` on a road running along `u`.
function Causeway.cap(folder: string, name: string, at: Vector2, u: Vector2, top: number, width: number): PartSpec
	local centre = Vector3.new(at.X, top - C.cap.Y / 2, at.Y)
	return spec(
		folder,
		name,
		"support",
		"block",
		CFrame.lookAt(centre, centre + Vector3.new(u.X, 0, u.Y)),
		Vector3.new(width, C.cap.Y, C.cap.X),
		PALETTE.concrete,
		Enum.Material.Concrete,
		true
	)
end

-- The haunches of one span between two capped pier stations `p0` and `p1` (plan) under a level deck whose underside
-- is at `underside`: at each deck edge (`lateral` studs either side of the centre line, `l` the right-hand normal)
-- a wedge from each cap's face, `rise` deep at the cap and thinning to nothing `reach` of the span out. 4 parts.
function Causeway.haunches(
	folder: string,
	name: string,
	p0: Vector2,
	p1: Vector2,
	l: Vector2,
	lateral: number,
	underside: number
): { PartSpec }
	local out: { PartSpec } = {}
	local span = (p1 - p0).Magnitude
	local u = (p1 - p0).Unit
	local arch = C.arch
	local start = C.cap.X / 2
	local reach = math.max(1, arch.reach * span - start)
	local top = underside - 0.03
	for _, side in { -1, 1 } do
		for k, ends in { { p0, u }, { p1, -u } } do
			local origin, away = ends[1], ends[2]
			local mid = origin + away * (start + reach / 2) + l * (side * lateral)
			local centre = Vector3.new(mid.X, top - arch.rise / 2, mid.Y)
			-- The wedge's square corner at its top back: its back (+Z) face to the cap, its slope falling away from it.
			local frame = CFrame.lookAt(centre, centre + Vector3.new(away.X, 0, away.Y)) * CFrame.Angles(0, 0, math.pi)
			table.insert(
				out,
				spec(
					folder,
					`{name}{if side < 0 then "L" else "R"}{k}`,
					"support",
					"wedge",
					frame,
					Vector3.new(arch.thick, arch.rise, reach),
					PALETTE.concrete,
					Enum.Material.Concrete,
					false
				)
			)
		end
	end
	return out
end

-- An acorn lamp standing on the coping `along` studs from the middle of a raised road's segment (`frame` as for the
-- balustrade), on `side`. Returns its post and its globe (the night light; MapBuilder lights some of them).
function Causeway.lamp(
	folder: string,
	name: string,
	frame: CFrame,
	along: number,
	half: number,
	side: number
): (PartSpec, PartSpec)
	local lamp = C.lamps
	local x = side * (half + C.plinth.thick / 2)
	local foot = frame * Vector3.new(x, C.coping.top, -along)
	local post = spec(
		folder,
		name,
		"light",
		"cylinder",
		CFrame.new(foot + Vector3.yAxis * (lamp.post.Y / 2)) * CFrame.Angles(0, 0, QUARTER),
		Vector3.new(lamp.post.Y, lamp.post.X, lamp.post.X),
		lamp.postColor,
		Enum.Material.Metal,
		false
	)
	local globe = spec(
		folder,
		`{name}Head`,
		"light",
		"ball",
		CFrame.new(foot + Vector3.yAxis * (lamp.post.Y + lamp.globe * 0.42)),
		Vector3.one * lamp.globe,
		lamp.globeColor,
		Enum.Material.SmoothPlastic,
		false
	)
	globe.shadow = false
	return post, globe
end

-- Rib `i` of `n` (from one foot to the other) in the arches' night gradient: the first colour at the feet, the last at
-- the crown.
function Causeway.ribColor(i: number, n: number): Color3
	local colors = C.arches.gradient
	local t = math.abs((i - 0.5) / n - 0.5) * 2 -- 0 at the crown, 1 at the feet
	local u = math.clamp(1 - t, 0, 1) * (#colors - 1)
	local k = math.clamp(math.floor(u) + 1, 1, #colors - 1)
	return colors[k]:Lerp(colors[k + 1], u - (k - 1))
end

-- The arches' day colours (MapBuilder addBridgeArch), the piers' size, the glow strip's night kind and the lamps'
-- spacing.
Causeway.arches = C.arches
Causeway.pierSize = C.pier
Causeway.glowKind = C.glowKind
Causeway.lampEvery = C.lamps.every

return Causeway
