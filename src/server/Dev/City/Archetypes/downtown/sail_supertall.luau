--!strict
-- T04 sail_supertall (docs/city/ARCHETYPES.md §5, T04): the bay row's sail, a residential supertall shaped like a boat's
-- sail. In plan it is a lens: a strongly convex glass face toward its front (the water, when the planner turns it to
-- the lake) and a flatter one behind, meeting at two sharp tips, each held by a slim white spine. The leading spine
-- rises past the roof, and the roof rakes down from it to the trailing tip, the sail's head. White slab bands follow the
-- convex face's curve. A deep band wraps the lobby, and near the top a cantilevered lip carries the sky lounge behind a
-- glass rail. A short garage stands behind the sail. At night a light line runs up the leading edge, and the lip and
-- the lobby band glow blue.
--
-- What makes it itself: a curved glass blade, convex toward the water, whose leading edge sweeps up into a raked tip.
-- Placement, sizes, heights and its budget: Config/CityArchetypes/sail_supertall. It is a one-off (weight 0): the
-- planner builds it once on the bay row (Config/City landmarks), turned to face the lake, with a core claim.
-- Variants: palette (3: front and back glass, white or warm white); crown (1 the leading spine runs on into a beacon
-- mast, 2 the raked head drawn in light along the front, 3 a raked white blade standing on the roof); rhythm (1 a band
-- every two floors; 2 every three floors, thicker and deeper); mirror (which tip leads).
--
-- No CSG: the lens is 8 flat glass facets on the front and 4 behind, each topped by a wedge that follows the rake. Each
-- band is 4 straight strips, one per two facets, embedded in the glass, so it stands 1 to 3 studs proud along the
-- curve.
-- When previewing: use a deep site (Preview option depth = 110). From the front at mid distance, check that the facets
-- read as one smooth curve and the bands as continuous lines with no notches where strips meet. From the side, check
-- that the rake reads as a sail's head. At the tips, check that no facet corner pokes out past a spine. At night, look
-- for the leading-edge line, the lip, the lobby band and the crown.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local City = require(ReplicatedStorage.Shared.Config.City)
local Kit = require(script.Parent.Parent.Parent.Kit)
local Types = require(script.Parent.Parent.Parent.Types)

local P = City.palettes
local KIT = City.kit
local rgb = Color3.fromRGB

-- The recipe, in studs.
local SHAPE = {
	floor = 12,
	lobby = 16, -- the lobby band's height
	length = { 0.84, 70, 112 }, -- the lens's length along the road: share of the site's width, clamped
	tipRoom = 7.2, -- from a tip to the site's side, at least (the spine, the lip's and the bands' ends)
	thick = 0.46, -- the lens's thickness, as a share of its length, at most
	bulge = 0.68, -- the convex front's share of the thickness (the back's is the rest)
	front = 8, -- the front apex stands at least this far behind the front line (the lip stands out in front of it)
	deep = 16, -- on a deep site, at most this much further back
	backRoom = 1, -- between the lens and the site's back
	facets = 8, -- glass facets on the convex front (two to a band strip)
	backFacets = 4,
	skin = 2.2, -- a facet's thickness
	bay = 5.5, -- a window bay
	spine = 5.4, -- the white spines at the two tips: diameter
	-- The roof's fall from the leading tip to the trailing one: share of the height, clamped. The first preview's 53
	-- read as a sloped roof; about 70 reads as a sail's head.
	rake = { 0.13, 50, 76 },
	bands = { -- by rhythm (36 apart read as hoops round a drum; balconies want 24)
		{ every = 24, thick = 1.6, proud = 3.4, led = 6 }, -- led: every this many rows a band is lit at night
		{ every = 36, thick = 2.4, proud = 4.4, led = 4 },
	},
	embed = 1.5, -- a band strip reaches this far into the glass at its ends
	joint = 0.6, -- strips run on this far past their ends, closing the joints
	lobbyBand = { thick = 1.8, proud = 5 },
	lip = { share = 0.8, thick = 2.6, proud = 7 }, -- the sky lounge's lip: its level as a share of the height
	led = 0.5, -- the light strips under the lobby band and the lip
	rail = 3.4,
	headRoom = 8, -- the top band stays this far under the roof's low end
	levels = 4, -- the garage behind the sail
	level = 10,
	garageInset = 1.5,
	garageGap = 2, -- the garage's front behind the lens's middle line
	garageMin = 8, -- the garage needs this much depth
	slot = 3.2,
	bandProud = 0.5,
	capThick = 1.6,
	plaza = 0.35,
	line = 18, -- the light line up the leading edge starts this high
	mast = 26, -- crown 1
	spineRise = { 8, 12, 4 }, -- by crown: the leading spine over the roof
	headLight = 1.1, -- crown 2: the light line under the raked head (its centre this far under the rake)
	blade = { tall = 12, sunk = 1, thick = 1.2, inset = 3 }, -- crown 3: the blade, its foot sunk under the rake
}

-- Front glass, back glass, the whites (spines, bands, lip), the garage.
local PALETTES = {
	{ front = P.glass.aqua, back = P.glass.silver, white = P.frame.white, garage = P.concrete.pale },
	{ front = P.glass.blue, back = P.glass.navy, white = P.frame.white, garage = P.concrete.pale },
	{ front = P.glass.teal, back = P.glass.silver, white = P.frame.warm, garage = P.concrete.warm },
}

local RAIL = Kit.look(rgb(214, 236, 242), Enum.Material.Glass, 0.1, KIT.railTransparency)
local METAL = Kit.look(rgb(200, 204, 210), Enum.Material.Metal)
local UP = Vector3.new(0, 1, 0)

local function build(m: Types.Model)
	local site = m.site
	local variant = site.variant
	local pal = PALETTES[math.clamp(variant.palette, 1, #PALETTES)]
	local band = SHAPE.bands[math.clamp(variant.rhythm, 1, #SHAPE.bands)]
	local crown = math.clamp(variant.crown, 1, 3)
	local rng = Kit.rng(m)
	local W, D, H = site.width, site.depth, site.height
	local hw, hd = W / 2, D / 2
	local rise = site.maxHeight - H
	local white = Kit.look(pal.white, Enum.Material.SmoothPlastic)
	local dark = Kit.look(P.concrete.dark, Enum.Material.SmoothPlastic)
	local tag = City.signNames.towers[rng:NextInteger(1, #City.signNames.towers)]
	local yFoot = -KIT.bury

	-------------------------------------------------------------------------------------------------------
	-- The lens: its length, thickness and place; the rake over it
	-------------------------------------------------------------------------------------------------------
	local L = math.min(math.clamp(W * SHAPE.length[1], SHAPE.length[2], SHAPE.length[3]), W - 2 * SHAPE.tipRoom)
	local room = D - SHAPE.front - SHAPE.backRoom
	local T = math.min(L * SHAPE.thick, room)
	local bf = T * SHAPE.bulge -- the front's bulge past the middle line
	local bb = T - bf -- the back's
	local z0 = -hd + SHAPE.front + bf + math.clamp(room - T, 0, SHAPE.deep) -- the middle line, tip to tip
	local apex = z0 - bf
	local drop = math.clamp(H * SHAPE.rake[1], SHAPE.rake[2], SHAPE.rake[3])
	local function rakeY(x: number): number
		return H - drop * (x + L / 2) / L
	end

	local N, M = SHAPE.facets, SHAPE.backFacets
	local front: { Vector3 } = {}
	for i = 0, N do
		local x = -L / 2 + L * i / N
		local u = 2 * x / L
		table.insert(front, Vector3.new(x, 0, z0 - bf * (1 - u * u)))
	end
	local back: { Vector3 } = {}
	for j = 0, M do
		local x = -L / 2 + L * j / M
		local u = 2 * x / L
		table.insert(back, Vector3.new(x, 0, z0 + bb * (1 - u * u)))
	end

	-------------------------------------------------------------------------------------------------------
	-- The skin: one glass facet per chord, from the ground to the rake (a block, then a wedge rising to the leading
	-- end), a curtain-wall grid on its outer face
	-------------------------------------------------------------------------------------------------------
	local function facet(name: string, p: Vector3, q: Vector3, out: Vector3, color: Color3)
		local chord = q - p
		local len = chord.Magnitude
		local along = chord / len
		local mid = (p + q) / 2 - out * (SHAPE.skin / 2)
		local look = Kit.glassLook(color)
		local yLow, yHigh = rakeY(q.X), rakeY(p.X)
		-- Its outer face is its Front: local z points in, local x along the chord.
		local blockFrame = CFrame.fromMatrix(Vector3.new(mid.X, (yFoot + yLow) / 2, mid.Z), UP:Cross(-out), UP, -out)
		local block =
			Kit.oriented(m, name, "block", blockFrame, Vector3.new(len, yLow - yFoot, SHAPE.skin), look, "box")
		block.textures = {
			{
				face = Enum.NormalId.Front,
				image = City.textures.windowFine,
				u = len / math.max(1, math.round(len / SHAPE.bay)),
				v = SHAPE.floor,
				color = color:Lerp(pal.white, 0.28), -- 0.45 read as a checkerboard from afar
			},
		}
		-- The head: a wedge whose high edge (its local +z) is at the leading end.
		local headFrame = CFrame.fromMatrix(Vector3.new(mid.X, (yLow + yHigh) / 2, mid.Z), UP:Cross(-along), UP, -along)
		Kit.oriented(m, name .. "Head", "wedge", headFrame, Vector3.new(SHAPE.skin, yHigh - yLow, len), look, "trim")
	end
	for i = 1, N do
		local along = (front[i + 1] - front[i]).Unit
		facet(`Front{i}`, front[i], front[i + 1], Vector3.new(along.Z, 0, -along.X), pal.front)
	end
	for j = 1, M do
		local along = (back[j + 1] - back[j]).Unit
		facet(`Back{j}`, back[j], back[j + 1], Vector3.new(-along.Z, 0, along.X), pal.back)
	end
	-- Inside: a dark core (it closes the lens and stands for it in the always-loaded skyline) and a lid under the rake.
	local cz0, cz1 = z0 - 0.75 * bf + SHAPE.skin + 0.3, z0 + 0.75 * bb - SHAPE.skin - 0.3
	local coreTop = H - drop * 0.75 - 1
	local coreLook = Kit.look(P.glass.smoke, Enum.Material.SmoothPlastic)
	Kit.box(m, "Core", Vector3.new(-L / 4, SHAPE.lobby, cz0), Vector3.new(L / 4, coreTop, cz1), coreLook)
	Kit.wedge(
		m,
		"Lid",
		Vector3.new(-L / 4, coreTop, cz0),
		Vector3.new(L / 4, rakeY(-L / 4) - 0.4, cz1),
		"left",
		coreLook,
		"trim"
	)

	-------------------------------------------------------------------------------------------------------
	-- The spines at the tips, the light line up the leading edge
	-------------------------------------------------------------------------------------------------------
	local sr = SHAPE.spine / 2
	local leadTop = H + SHAPE.spineRise[crown]
	Kit.column(m, "SpineLead", -L / 2, z0, yFoot, leadTop, SHAPE.spine, white)
	Kit.column(m, "SpineTrail", L / 2, z0, yFoot, H - drop + 1.5, SHAPE.spine, white)
	Kit.neonStrip(
		m,
		"EdgeLight",
		Vector3.new(-L / 2 - sr - 0.35, SHAPE.line, z0 - 1),
		Vector3.new(-L / 2 - sr + 0.6, leadTop - 3, z0 + 1),
		"crown",
		pal.white
	)

	-------------------------------------------------------------------------------------------------------
	-- Bands along the convex face: straight strips, one per two facets, stood out of the glass
	-------------------------------------------------------------------------------------------------------
	local function strip(j: number): (Vector3, Vector3, number, Vector3)
		local p, q = front[2 * j - 1], front[2 * j + 1]
		local chord = q - p
		local along = chord.Unit
		return (p + q) / 2, along, chord.Magnitude, Vector3.new(along.Z, 0, -along.X)
	end
	local function bandRow(name: string, y: number, thick: number, proud: number, led: boolean, rail: boolean)
		for j = 1, N // 2 do
			local mid, along, len, out = strip(j)
			-- Neighbouring strips differ by a hair in height, so their tops never share a plane where they overlap.
			local hair = if j % 2 == 0 then 0.03 else 0
			local centre = mid + out * ((proud - SHAPE.embed) / 2)
			Kit.oriented(
				m,
				`{name}{j}`,
				"block",
				CFrame.fromMatrix(Vector3.new(centre.X, y + thick / 2, centre.Z), along, Vector3.yAxis, -out),
				Vector3.new(len + 2 * SHAPE.joint, thick + 2 * hair, proud + SHAPE.embed),
				white,
				"trim"
			)
			if led then
				local edge = mid + out * (proud - 0.35)
				local spec = Kit.oriented(
					m,
					`{name}Led{j}`,
					"block",
					CFrame.fromMatrix(Vector3.new(edge.X, y - hair - SHAPE.led / 2, edge.Z), along, Vector3.yAxis, -out),
					Vector3.new(len + SHAPE.joint, SHAPE.led, 0.5),
					white,
					"detail"
				)
				Kit.lit(spec, "ledBlue")
			end
			if rail then
				local edge = mid + out * (proud - 0.4)
				Kit.oriented(
					m,
					`{name}Rail{j}`,
					"block",
					CFrame.fromMatrix(
						Vector3.new(edge.X, y + thick + hair + 0.02 + SHAPE.rail / 2, edge.Z),
						along,
						Vector3.yAxis,
						-out
					),
					Vector3.new(len + 0.4, SHAPE.rail, 0.3),
					RAIL,
					"detail"
				)
			end
		end
	end
	local lobbyBand, lip = SHAPE.lobbyBand, SHAPE.lip
	bandRow("LobbyBand", SHAPE.lobby, lobbyBand.thick, lobbyBand.proud, true, false)
	local topBand = H - drop - SHAPE.headRoom
	local rows = math.max(0, math.floor((topBand - band.thick - SHAPE.lobby) / band.every))
	local lipRow = math.clamp(math.round((H * lip.share - SHAPE.lobby) / band.every), 1, math.max(1, rows))
	for n = 1, rows do
		local y = SHAPE.lobby + n * band.every
		if n == lipRow then
			bandRow("Lip", y, lip.thick, lip.proud, true, true)
		else
			-- Every few rows a band carries a light line too, so the sail keeps rings of light up its height at night.
			bandRow(`Band{n}_`, y, band.thick, band.proud, n % band.led == 0, false)
		end
	end

	-------------------------------------------------------------------------------------------------------
	-- Crown
	-------------------------------------------------------------------------------------------------------
	if crown == 1 then
		-- The leading spine runs on into a beacon mast.
		Kit.spire(
			m,
			"Mast",
			-L / 2,
			z0,
			leadTop,
			math.min(SHAPE.mast, rise - SHAPE.spineRise[1] - 2.5),
			2,
			METAL,
			2,
			true
		)
	elseif crown == 2 then
		-- The raked head drawn in light along the convex face, a beacon on the spine.
		for i = 1, N do
			local p, q = front[i], front[i + 1]
			local along = (q - p).Unit
			local out = Vector3.new(along.Z, 0, -along.X)
			local a = p + out * 0.35 + Vector3.yAxis * (rakeY(p.X) - SHAPE.headLight)
			local b = q + out * 0.35 + Vector3.yAxis * (rakeY(q.X) - SHAPE.headLight)
			local l = (b - a).Unit
			local spec = Kit.oriented(
				m,
				`HeadLight{i}`,
				"block",
				CFrame.fromMatrix((a + b) / 2, out:Cross(l), out, l),
				Vector3.new(1.6, 0.6, (b - a).Magnitude),
				white,
				"detail"
			)
			Kit.lit(spec, "crown")
		end
		Kit.lit(
			Kit.ball(
				m,
				"Beacon",
				Vector3.new(-L / 2, leadTop + 0.6, z0),
				1.2,
				Kit.look(rgb(150, 40, 36), Enum.Material.SmoothPlastic)
			),
			"beacon"
		)
	else
		-- A raked white blade standing on the roof along the middle line, its top edge lit, a beacon at its peak.
		local blade = SHAPE.blade
		local x0, x1 = -L / 2 + blade.inset, L / 2 - blade.inset
		local mid = blade.tall / 2 - blade.sunk -- the blade's centre line over the rake
		local a = Vector3.new(x0, rakeY(x0) + mid, z0)
		local b = Vector3.new(x1, rakeY(x1) + mid, z0)
		local l = (b - a).Unit
		local n = Vector3.zAxis
		Kit.oriented(
			m,
			"Blade",
			"block",
			CFrame.fromMatrix((a + b) / 2, n:Cross(l), n, l),
			Vector3.new(blade.tall, blade.thick, (b - a).Magnitude),
			white,
			"trim"
		)
		-- Its top edge: the line half its height above its centre line, square to it in the blade's plane.
		local up = n:Cross(l)
		local lift = up * (blade.tall / 2 - 0.4) * (if up.Y < 0 then -1 else 1)
		local spec = Kit.oriented(
			m,
			"BladeLight",
			"block",
			CFrame.fromMatrix((a + b) / 2 + lift, n:Cross(l), n, l),
			Vector3.new(0.6, blade.thick + 0.2, (b - a).Magnitude - 0.6),
			white,
			"detail"
		)
		Kit.lit(spec, "crown")
		local peak = a + lift + l * 0.6
		Kit.lit(
			Kit.ball(
				m,
				"Beacon",
				Vector3.new(peak.X, peak.Y + 0.9, peak.Z),
				1.2,
				Kit.look(rgb(150, 40, 36), Enum.Material.SmoothPlastic)
			),
			"beacon"
		)
	end

	-------------------------------------------------------------------------------------------------------
	-- The garage behind the sail, the plaza, the name on the lobby band, the wash on the convex face
	-------------------------------------------------------------------------------------------------------
	local gz0, gz1 = z0 + SHAPE.garageGap, hd - SHAPE.garageInset
	if gz1 - gz0 >= SHAPE.garageMin then
		local gx0, gx1 = -hw + SHAPE.garageInset, hw - SHAPE.garageInset
		local top = SHAPE.lobby + SHAPE.levels * SHAPE.level
		Kit.glass(
			m,
			"Shops",
			Vector3.new(gx0 + 3, yFoot, gz0 + 3),
			Vector3.new(gx1 - 3, SHAPE.lobby + 0.5, gz1 - 3),
			rgb(44, 60, 70),
			{
				image = City.textures.windowBold,
				faces = { Enum.NormalId.Left, Enum.NormalId.Right, Enum.NormalId.Back },
				u = 5,
				v = SHAPE.lobby,
				lines = pal.white,
				lit = true,
			}
		)
		Kit.podium(
			m,
			"Garage",
			Vector3.new(gx0, SHAPE.lobby, gz0),
			Vector3.new(gx1, top, gz1),
			SHAPE.levels,
			SHAPE.slot,
			SHAPE.bandProud,
			Kit.look(pal.garage, Enum.Material.Concrete),
			dark
		)
		local cap = SHAPE.bandProud + 0.4
		Kit.trim(
			m,
			"GarageCap",
			Vector3.new(gx0 - cap, top, gz0 - cap),
			Vector3.new(gx1 + cap, top + SHAPE.capThick, gz1 + cap),
			white
		)
	end
	Kit.box(
		m,
		"Plaza",
		Vector3.new(-hw + 0.3, -0.6, -hd + 0.3),
		Vector3.new(hw - 0.3, SHAPE.plaza, hd - 0.3),
		Kit.look(P.deco.terrazzo, Enum.Material.SmoothPlastic)
	)
	-- The name stands on the lobby band at the apex, between the glass and the band's edge.
	local signY = SHAPE.lobby + lobbyBand.thick + 0.05
	Kit.sign(
		m,
		"Name",
		Vector3.new(-6, signY, apex - 2.4),
		Vector3.new(6, signY + 2.4, apex - 1.9),
		Enum.NormalId.Front,
		tag,
		rgb(40, 44, 50),
		pal.white,
		City.districtLooks.downtown.font
	)
	Kit.wash(m, "Wash", -L * 0.2, L * 0.2, apex - lobbyBand.proud - 1.5, SHAPE.plaza, rgb(170, 220, 255))
	if hw - 12 > L / 2 + SHAPE.tipRoom then
		for i, side in { -1, 1 } do
			Kit.planter(
				m,
				`Planter{i}`,
				Vector3.new(side * (hw - 12), SHAPE.plaza, -hd + 2),
				Vector3.new(side * (hw - 3), SHAPE.plaza + 1.6, -hd + 5),
				white
			)
		end
	end
end

local archetype: Types.Archetype = { id = "sail_supertall", build = build }
return archetype
