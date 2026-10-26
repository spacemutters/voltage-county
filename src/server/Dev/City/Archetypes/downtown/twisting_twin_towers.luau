--!strict
-- T11 twisting_twin_towers (docs/city/ARCHETYPES.md §5, T11): two slim condo towers side by side in a garden, each a
-- stack of deep white floor plates that turn a few degrees more every floor, so the pair wrings itself like two
-- towels twisting opposite ways. Every plate stands 4 studs past its glass on every side (a balcony all round, and the
-- shade that keeps the glass dark), and the glass turns with it. The lowest plates and the top ones hold their turn;
-- an ice-blue LED ring under every third plate draws the twist in light at night. On the ground: a glazed lobby under
-- each tower's first plate, a lawn, a round drop-off canopy with a green roof between the towers carrying the name,
-- a reflecting pool behind it and planters on the paved front strip.
--
-- What makes it itself: two towers of white plates twisting opposite ways, side by side.
-- Placement, sizes, heights and its budget: Config/CityArchetypes/twisting_twin_towers.
-- Variants: palette (4 glass and frame sets), crown (1 roof terrace: glass rail, pool and a glass pavilion under a
-- white lid; 2 a glass penthouse under a floating white cap with a lit underside; 3 a green roof under a white
-- pergola), rhythm (the twist from bottom to top: 30, 38 or 45 degrees), mirror (the pair twists the other way).
--
-- Preview checklist: from the street and from 300 studs the plates must read as one smooth twist, not a ragged
-- sawtooth (if they do, lower SHAPE.twist or raise holdLow/holdHigh); the glass corners must stay hidden behind the
-- plates (a glass run spans two floors and follows the middle plate); the canopy tucks under the first plates
-- without touching the lobby glass; the top plates' corners stay clear of the neighbours; at night the LED rings and
-- one or two lit runs per tower, nothing else.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local City = require(ReplicatedStorage.Shared.Config.City)
local Kit = require(script.Parent.Parent.Parent.Kit)
local Types = require(script.Parent.Parent.Parent.Types)

type PartSpec = Types.PartSpec

local P = City.palettes
local KIT = City.kit
local rgb = Color3.fromRGB

-- The recipe, in studs (angles in degrees).
local SHAPE = {
	lobby = 16, -- the glazed ground floor under the first plate
	floor = 12, -- a floor, nominal: fitted so the roof lands on the site's height
	minFloors = 8,
	front = 4.5, -- the plates, at their most turned, keep this far behind the front line...
	back = 1.5, -- ...this far from the back line...
	side = 2, -- ...and from the sides
	gap = 16, -- the two towers' outlines stand at least this far apart...
	spread = 8, -- ...and up to this much further on a wide site (the rest is lawn)
	plateRatio = 0.7, -- a plate's depth as a share of its length
	plateMax = 60,
	plateThick = 1.2,
	roofThick = 2.2,
	inset = 4, -- the glass sits this far inside the plates on every side: the balcony all round
	lobbyInset = 4.5, -- the lobby glass, under the first plate
	twist = { 30, 38, 45 }, -- from the lowest plates to the highest, by rhythm
	holdLow = 2, -- plates over the first that keep the starting turn
	holdHigh = 3, -- plates under the roof that keep the final turn
	ringEvery = 3, -- an LED ring under every third plate
	litRuns = 2, -- glass runs per tower that glow at night (at most)
	bay = 5.5, -- a window bay on the glass
	plinth = 0.8, -- the lawn's height
	forecourt = 3, -- the paved strip along the front line
	canopyY = 10.5, -- the drop-off canopy's underside
	canopyThick = 1.2,
	canopyMax = 17, -- its radius, at most
	post = 1.3,
	signHeight = 2.4,
	planter = { 7, 1.5, 2.2 }, -- width, height, depth
	pool = { 8, 4 }, -- the reflecting pool between the towers: half its width at most, its depth at least
	pavilion = 7, -- crown 1
	cap = 8, -- crown 2: the floating cap's underside over the roof
	capThick = 1.4,
	pergola = 8, -- crown 3
}

-- Glass and frame sets: blue-green, teal under warm white, silver, navy.
local PALETTES = {
	{ glass = rgb(82, 124, 138), frame = P.frame.white },
	{ glass = P.glass.teal, frame = P.frame.warm },
	{ glass = P.glass.silver, frame = P.frame.white },
	{ glass = P.glass.navy, frame = P.frame.white },
}

local RAIL = Kit.look(rgb(214, 236, 242), Enum.Material.Glass, 0.1, KIT.railTransparency)

-- Half the size, along x and along z, of the box round an `sx` by `sz` footprint turned `yaw`.
local function reach(sx: number, sz: number, yaw: number): (number, number)
	local c, s = math.abs(math.cos(yaw)), math.abs(math.sin(yaw))
	return (sx * c + sz * s) / 2, (sx * s + sz * c) / 2
end

local function build(m: Types.Model)
	local site = m.site
	local variant = site.variant
	local pal = PALETTES[math.clamp(variant.palette, 1, #PALETTES)]
	local rng = Kit.rng(m)
	local W, D, H = site.width, site.depth, site.height
	local hw, hd = W / 2, D / 2
	local G = SHAPE.lobby
	local n = math.max(SHAPE.minFloors, math.round((H - G) / SHAPE.floor))
	local f = (H - G) / n
	local twist = math.rad(SHAPE.twist[math.clamp(variant.rhythm, 1, #SHAPE.twist)])
	local half = twist / 2
	-- The kit flips a mirrored site's plan, which alone would give the same pair back; flipping the sense of the
	-- twist as well makes a mirrored copy wring the other way.
	local sense = if variant.mirror then -1 else 1
	local crown = variant.crown

	local frame = Kit.look(pal.frame, Enum.Material.SmoothPlastic)
	local glass = Kit.glassLook(pal.glass)
	local lobbyGlass = Kit.glassLook(rgb(44, 60, 70))
	local lawn = Kit.look(P.leaf, Enum.Material.Grass)
	local paving = Kit.look(P.deco.terrazzo, Enum.Material.SmoothPlastic)
	local water = Kit.look(P.water, Enum.Material.Glass, 0.3, 0)
	local lines = pal.glass:Lerp(pal.frame, 0.45)
	local function grid(image: string, u: number, v: number, color: Color3): { Types.TextureSpec }
		return { { face = Kit.face(m, Enum.NormalId.Front), image = image, u = u, v = v, color = color } }
	end

	-- A block turned `yaw` about the vertical through `center` (site terms: the kit mirrors it), and the point that
	-- lies `offset` from `center` in such a block's own frame.
	local function turned(
		name: string,
		center: Vector3,
		size: Vector3,
		yaw: number,
		look: Kit.Look,
		kind: Kit.Kind?
	): PartSpec
		return Kit.oriented(m, name, "block", CFrame.new(center) * CFrame.Angles(0, yaw, 0), size, look, kind)
	end
	local function at(center: Vector3, yaw: number, offset: Vector3): Vector3
		return center + CFrame.Angles(0, yaw, 0):VectorToWorldSpace(offset)
	end

	-------------------------------------------------------------------------------------------------------
	-- The plates: as large as the site allows with both towers at their most turned, the gap and the margins
	-------------------------------------------------------------------------------------------------------
	local r = SHAPE.plateRatio
	local c, s = math.cos(half), math.sin(half)
	local zF, zB = -hd + SHAPE.front, hd - SHAPE.back
	local wAvail = (W - 2 * SHAPE.side - SHAPE.gap) / 2
	local L = math.min(SHAPE.plateMax, wAvail / (c + r * s), (zB - zF) / (s + r * c))
	local S = L * r
	local outX, outZ = reach(L, S, half)
	local xc = math.min(hw - SHAPE.side - outX, SHAPE.gap / 2 + outX + SHAPE.spread)
	-- A deep site keeps its spare depth in front (the lawn and the drop-off), a little behind.
	local zc = zF + outZ + (zB - zF - 2 * outZ) * 0.6
	local gL, gS = L - 2 * SHAPE.inset, S - 2 * SHAPE.inset
	local lL, lS = L - 2 * SHAPE.lobbyInset, S - 2 * SHAPE.lobbyInset
	local lobbyX = reach(lL, lS, half)

	-- Plate k (1..n) is floor k's floor, the first one the lobby's ceiling; plate n + 1 is the roof. Each turns from
	-- -half to +half between the held plates at the bottom and the top.
	local steps = math.max(1, n - SHAPE.holdLow - SHAPE.holdHigh)
	local function turnOf(k: number): number
		return -half + twist * math.clamp((k - 1 - SHAPE.holdLow) / steps, 0, 1)
	end
	local function bottom(k: number): number
		return if k <= n then G + (k - 1) * f else H - SHAPE.roofThick
	end
	local function top(k: number): number
		return if k <= n then G + (k - 1) * f + SHAPE.plateThick else H
	end
	local runs = math.ceil(n / 2)

	for _, tower in { { tag = "A", x = -xc, sense = sense }, { tag = "B", x = xc, sense = -sense } } do
		local t, x = tower.tag, tower.x
		local function yawOf(k: number): number
			return tower.sense * turnOf(k)
		end

		-- A deep white plate a floor, each turned a little more than the one under it, an LED ring under every third.
		for k = 1, n + 1 do
			local y0, y1 = bottom(k), top(k)
			local yaw = yawOf(k)
			turned(`{t}Plate{k}`, Vector3.new(x, (y0 + y1) / 2, zc), Vector3.new(L, y1 - y0, S), yaw, frame, "trim")
			if k % SHAPE.ringEvery == 0 and k <= n then
				-- A hair bigger than the plate and sunk in its middle, so only its edge shows: a lit line round the plate's
				-- edge, never a glowing underside.
				local ring = turned(
					`{t}Ring{k}`,
					Vector3.new(x, (y0 + y1) / 2, zc),
					Vector3.new(L + 0.3, 0.5, S + 0.3),
					yaw,
					frame,
					"detail"
				)
				Kit.lit(ring, "ledEdge")
			end
		end

		-- The glass: one run every two floors, turned as the plate across its middle (the plates above and below differ
		-- by one step, well inside the balcony's depth). One or two runs glow at night through a skin on their fronts.
		local lit: { [number]: boolean } = {}
		for _ = 1, SHAPE.litRuns do
			lit[rng:NextInteger(1, runs)] = true
		end
		for j = 1, runs do
			local y0 = top(2 * j - 1) - 0.3
			local y1 = bottom(math.min(2 * j + 1, n + 1)) + 0.3
			local yaw = yawOf(math.min(2 * j, n + 1))
			local center = Vector3.new(x, (y0 + y1) / 2, zc)
			local pane = turned(`{t}Glass{j}`, center, Vector3.new(gL, y1 - y0, gS), yaw, glass)
			pane.textures = grid(City.textures.windowFine, SHAPE.bay, f, lines)
			if lit[j] then
				local skin = turned(
					`{t}Lit{j}`,
					at(center, yaw, Vector3.new(0, 0, -(gS / 2 + 0.12))),
					Vector3.new(gL - 1, y1 - y0 - 0.8, 0.12),
					yaw,
					glass,
					"detail"
				)
				skin.textures = grid(City.textures.windowFine, SHAPE.bay, f, lines)
				Kit.lit(skin, "window")
			end
		end

		-- The lobby: glass under the first plate, its front glowing at night.
		local yaw1 = yawOf(1)
		local lobbyC = Vector3.new(x, (G + 0.3 - KIT.bury) / 2, zc)
		local lobby = turned(`{t}Lobby`, lobbyC, Vector3.new(lL, G + 0.3 + KIT.bury, lS), yaw1, lobbyGlass)
		lobby.textures = {
			{
				face = Kit.face(m, Enum.NormalId.Front),
				image = City.textures.windowBold,
				u = 6,
				v = G,
				color = pal.frame,
			},
			{
				face = Kit.face(m, Enum.NormalId.Back),
				image = City.textures.windowBold,
				u = 6,
				v = G,
				color = pal.frame,
			},
		}
		local lobbySkin = turned(
			`{t}LobbyLit`,
			at(lobbyC, yaw1, Vector3.new(0, 0.6, -(lS / 2 + 0.12))),
			Vector3.new(lL - 2, G - 3, 0.12),
			yaw1,
			lobbyGlass,
			"detail"
		)
		lobbySkin.textures = grid(City.textures.windowBold, 6, G, pal.frame)
		Kit.lit(lobbySkin, "window")

		-- The crown, on the roof plate.
		local yawR = yawOf(n + 1)
		local roofC = Vector3.new(x, H, zc)
		if crown == 1 then
			-- A roof terrace: a glass rail round the edge, a pool at the front, a glass pavilion under a white lid.
			turned(
				`{t}Rail`,
				at(roofC, yawR, Vector3.new(0, KIT.railHeight / 2, 0)),
				Vector3.new(L - 1, KIT.railHeight, S - 1),
				yawR,
				RAIL,
				"detail"
			)
			local poolC = at(roofC, yawR, Vector3.new(-L * 0.18, 0, -S * 0.12))
			turned(
				`{t}PoolEdge`,
				poolC + Vector3.new(0, 0.175, 0),
				Vector3.new(L * 0.4 + 1.6, 0.35, S * 0.34 + 1.6),
				yawR,
				paving,
				"detail"
			)
			turned(
				`{t}Pool`,
				poolC + Vector3.new(0, 0.25, 0),
				Vector3.new(L * 0.4, 0.4, S * 0.34),
				yawR,
				water,
				"detail"
			)
			turned(
				`{t}Pavilion`,
				at(roofC, yawR, Vector3.new(L * 0.24, SHAPE.pavilion / 2, S * 0.14)),
				Vector3.new(L * 0.3, SHAPE.pavilion, S * 0.42),
				yawR,
				glass
			)
			turned(
				`{t}PavilionLid`,
				at(roofC, yawR, Vector3.new(L * 0.24, SHAPE.pavilion + 0.2, S * 0.14)),
				Vector3.new(L * 0.3 + 2.4, 1.2, S * 0.42 + 2.4),
				yawR,
				frame,
				"trim"
			)
		elseif crown == 2 then
			-- A glass penthouse set in under a floating white cap whose underside glows at night.
			turned(
				`{t}Penthouse`,
				at(roofC, yawR, Vector3.new(0, SHAPE.cap / 2 + 0.1, 0)),
				Vector3.new(L * 0.62, SHAPE.cap + 0.2, S * 0.6),
				yawR,
				glass
			)
			turned(
				`{t}Cap`,
				at(roofC, yawR, Vector3.new(0, SHAPE.cap + SHAPE.capThick / 2, 0)),
				Vector3.new(L * 0.8, SHAPE.capThick, S * 0.8),
				yawR,
				frame,
				"trim"
			)
			local glow = turned(
				`{t}CapLed`,
				at(roofC, yawR, Vector3.new(0, SHAPE.cap - 0.2, 0)),
				Vector3.new(L * 0.8 + 0.3, 0.5, S * 0.8 + 0.3),
				yawR,
				frame,
				"detail"
			)
			Kit.lit(glow, "crown")
		else
			-- A green roof under a white pergola.
			turned(
				`{t}Green`,
				at(roofC, yawR, Vector3.new(0, 0.3, 0)),
				Vector3.new(L - 3, 0.6, S - 3),
				yawR,
				lawn,
				"detail"
			)
			for i, sx in { -1, 1 } do
				local p = at(roofC, yawR, Vector3.new(sx * L * 0.22, 0, S * 0.18))
				Kit.column(m, `{t}Post{i}`, p.X, p.Z, H, H + SHAPE.pergola, 0.9, frame, "trim")
			end
			turned(
				`{t}Pergola`,
				at(roofC, yawR, Vector3.new(0, SHAPE.pergola + 0.4, S * 0.18)),
				Vector3.new(L * 0.44 + 2, 0.8, S * 0.36),
				yawR,
				frame,
				"trim"
			)
		end
	end

	-------------------------------------------------------------------------------------------------------
	-- The garden: a lawn, a paved front strip, the drop-off canopy, the name, a reflecting pool, planters
	-------------------------------------------------------------------------------------------------------
	Kit.box(
		m,
		"Lawn",
		Vector3.new(-hw + 0.5, 0, -hd + SHAPE.forecourt),
		Vector3.new(hw - 0.5, SHAPE.plinth, hd - 0.5),
		lawn
	)
	Kit.box(
		m,
		"Forecourt",
		Vector3.new(-hw + 0.5, 0, -hd + 0.5),
		Vector3.new(hw - 0.5, SHAPE.plinth + 0.06, -hd + SHAPE.forecourt + 0.4),
		paving
	)

	-- A round drop-off canopy between the towers, tucked under their first plates, its roof planted.
	local R = math.clamp(xc - lobbyX - 1.5, 6, SHAPE.canopyMax)
	local zp = -hd + R + 0.6
	local cy = SHAPE.canopyY
	local canopyTop = cy + SHAPE.canopyThick
	Kit.disc(m, "Drive", 0, zp, SHAPE.plinth + 0.08, 2 * R + 1, 0.2, paving, "detail")
	Kit.disc(m, "Canopy", 0, zp, cy + SHAPE.canopyThick / 2, 2 * R, SHAPE.canopyThick, frame, "trim")
	Kit.disc(m, "CanopyGreen", 0, zp, canopyTop + 0.2, 2 * R - 1.6, 0.5, lawn, "detail")
	for i, sx in { -1, 1 } do
		Kit.column(m, `Post{i}`, sx * R * 0.45, zp + R * 0.3, -KIT.bury, cy + 0.1, SHAPE.post, frame)
	end
	local names = City.signNames.towers
	local signW = math.min(R * 0.6, 9)
	local signZ = zp - R * 0.72
	Kit.sign(
		m,
		"Name",
		Vector3.new(-signW, canopyTop + 0.4, signZ),
		Vector3.new(signW, canopyTop + 0.4 + SHAPE.signHeight, signZ + 0.4),
		Enum.NormalId.Front,
		names[rng:NextInteger(1, #names)],
		rgb(40, 44, 50),
		pal.frame,
		City.districtLooks.downtown.font
	)

	-- A reflecting pool between the towers, behind the canopy.
	local poolHalf = math.min(SHAPE.pool[1], xc - lobbyX - 2.5)
	local pz0, pz1 = zp + R + 1.5, math.min(hd - 2, zp + R + 31.5)
	if poolHalf >= 2 and pz1 - pz0 >= SHAPE.pool[2] then
		Kit.pool(m, "Pool", Vector3.new(-poolHalf, 0, pz0), Vector3.new(poolHalf, 0, pz1), SHAPE.plinth)
	end

	-- Planters on the paved strip at both ends.
	local pw, ph, pd = SHAPE.planter[1], SHAPE.planter[2], SHAPE.planter[3]
	local paved = SHAPE.plinth + 0.06
	for i, sx in { -1, 1 } do
		local xa, xb = sx * (hw - 1), sx * (hw - 1 - pw)
		Kit.planter(
			m,
			`Planter{i}`,
			Vector3.new(math.min(xa, xb), paved, -hd + 0.8),
			Vector3.new(math.max(xa, xb), paved + ph, -hd + 0.8 + pd),
			frame
		)
	end
end

local archetype: Types.Archetype = { id = "twisting_twin_towers", build = build }
return archetype
