--!strict
-- T09 stair_wing_slab (docs/city/ARCHETYPES.md §5, T09): a plain white slab with a giant orange staircase climbing
-- out of it. The slab is white stucco punched with dark windows and ribbed top to bottom by white fins standing proud
-- of its street face, with a white ledge every fourth floor and a cornice. The staircase is a run of orange blocks in
-- front of the slab's end, each a step lower, a step further along the road and further toward the street, down to
-- three floors at the far end of the site (on a deep site it comes right out to the street). Every step is a terrace:
-- capped in white with a glass rail along its edge, planters on every second one, and its top floor a band of glass
-- that glows at night, so after dark the stair is a flight of lit treads. A glass shopfront and canopy on the slab's
-- free front, a warm wash up the white face, and a crown of a glass penthouse or white steps echoing the stair.
--
-- What makes it itself: a giant orange staircase climbing out of a plain white slab.
-- Placement, sizes, heights and its budget: Config/CityArchetypes/stair_wing_slab.
-- Variants: palette (3 wing colours: orange, terracotta, sunshine yellow), crown (1 a green glass penthouse and a
-- plant room, 2 three white steps rising away from the stair), rhythm (1 eight steps a floor apart, 2 six steps two
-- floors apart), mirror (the stair runs down to the left or the right).
--
-- Preview check (the Studio step): the stair reads as a stair from the street at 70 mph and from across downtown
-- (steps tall and deep enough, white caps and rails catching the sun, each step's shadow on the next); the orange
-- blocks' windows line up floor by floor (every step's top is a whole floor); the fins read as crisp white ribs with
-- shadow between them, and the stair's first steps sit cleanly in front of them with no flicker; the risers glow at
-- night as lit treads and the wash lights the white face; on its 120-deep landmark site the stair comes forward to the
-- street without looking detached from the slab; nothing pokes past the footprint at 130 and 220 wide, 46, 53 and
-- 120 deep.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local City = require(ReplicatedStorage.Shared.Config.City)
local Kit = require(script.Parent.Parent.Parent.Kit)
local Types = require(script.Parent.Parent.Parent.Types)

local P = City.palettes
local KIT = City.kit
local rgb = Color3.fromRGB

local FRONT, BACK = Enum.NormalId.Front, Enum.NormalId.Back
local LEFT, RIGHT = Enum.NormalId.Left, Enum.NormalId.Right

-- The recipe, in studs.
local SHAPE = {
	floor = 12,
	edge = 2, -- the slab's free end and the stair's last step from the site's ends
	slabShare = 0.52, -- the slab's width, share of the site's...
	slabWidth = { 70, 112 }, -- ...between these
	slabDepth = { 0.5, 26, 40 }, -- share of the site's depth, clamped
	back = 2,
	bay = 5, -- a punched window a bay and a floor
	finEvery = 9, -- studs between the white ribs (whole numbers of them across)...
	fins = { 7, 13 }, -- ...between these many
	fin = { wide = 1.4, proud = 2.2 },
	ledgeEvery = 4, -- floors between the white ledges
	ledge = { thick = 1, proud = 1.4 },
	cornice = { thick = 1.6, proud = 0.8 },
	steps = { 8, 6 }, -- by rhythm
	drop = { 12, 24 }, -- by rhythm: each step this much lower than the last (whole floors)
	lowest = 36, -- the last step's top
	wingStart = { 0.35, 20, 36 }, -- the stair starts this far in front of the slab's end (share of its width, clamped)
	wingFront = 6, -- the first step stands this far in front of the slab
	frontClear = 4, -- the last step's face from the front line
	cap = { thick = 1.4, proud = 0.8, over = 0.5 }, -- over: how far the cap stands above its step
	riser = { inset = 0.6, foot = 2.5, proud = 0.25 }, -- the lit glass band across each step's top floor
	rail = 3,
	planter = { inset = 1.5, deep = 2, tall = 1.4 },
	shop = 14,
	canopy = { y = 12.6, thick = 1.4, reach = 6, inset = 4 },
	penthouse = { share = 0.42, tall = 14, roof = 1.2 },
	steppedCrown = { rise = 6, count = 3 },
}

-- The wing's colour, its windows (a dark warm matte, so the sky's blue in glass doesn't drown the orange), the wash
-- that lights the white slab at night.
local PALETTES = {
	{ wing = rgb(236, 112, 40), windows = rgb(78, 44, 30), wash = rgb(255, 170, 110) },
	{ wing = rgb(204, 82, 52), windows = rgb(72, 36, 28), wash = rgb(255, 160, 120) },
	{ wing = rgb(246, 196, 40), windows = rgb(84, 66, 34), wash = rgb(255, 210, 140) },
}

local RAIL = Kit.look(rgb(214, 236, 242), Enum.Material.Glass, 0.1, KIT.railTransparency)

local function build(m: Types.Model)
	local site = m.site
	local variant = site.variant
	local pal = PALETTES[math.clamp(variant.palette, 1, #PALETTES)]
	local rhythm = math.clamp(variant.rhythm, 1, 2)
	local rng = Kit.rng(m)
	local W, D, H = site.width, site.depth, site.height
	local hw, hd = W / 2, D / 2
	local F = SHAPE.floor
	local yb = -KIT.bury
	local stucco = rgb(246, 244, 238)
	local white = Kit.look(stucco, Enum.Material.SmoothPlastic)
	local tag = City.signNames.towers[rng:NextInteger(1, #City.signNames.towers)]

	-------------------------------------------------------------------------------------------------------
	-- The slab: white, punched with dark windows, ribbed with white fins, a ledge every few floors, a cornice
	-------------------------------------------------------------------------------------------------------
	local sw = math.clamp(W * SHAPE.slabShare, SHAPE.slabWidth[1], SHAPE.slabWidth[2])
	local sx0 = -hw + SHAPE.edge
	local sx1 = sx0 + sw
	local sd = math.clamp(D * SHAPE.slabDepth[1], SHAPE.slabDepth[2], SHAPE.slabDepth[3])
	local zB = hd - SHAPE.back
	local zS = zB - sd
	Kit.punched(
		m,
		"Slab",
		Vector3.new(sx0, yb, zS),
		Vector3.new(sx1, H, zB),
		stucco,
		P.window.dark,
		{ FRONT, LEFT, RIGHT, BACK },
		SHAPE.bay,
		F
	)
	local fin = SHAPE.fin
	local cr = SHAPE.cornice
	local finTop = H - cr.thick + 0.1
	local fins = math.clamp(math.floor(sw / SHAPE.finEvery) + 1, SHAPE.fins[1], SHAPE.fins[2])
	Kit.fins(
		m,
		"Fin",
		"front",
		zS,
		sx0 + fin.wide / 2,
		sx1 - fin.wide / 2,
		fins,
		yb,
		finTop,
		fin.proud,
		fin.wide,
		white
	)
	-- Ledges every few floors, under the fins' faces: the ribs stand past them.
	local lg = SHAPE.ledge
	local every = F * SHAPE.ledgeEvery
	local n = 0
	local y = H - every
	while y > SHAPE.shop + F do
		n += 1
		Kit.trim(
			m,
			`Ledge{n}`,
			Vector3.new(sx0 - 0.3, y - lg.thick / 2, zS - lg.proud),
			Vector3.new(sx1 + 0.3, y + lg.thick / 2, zS + 0.3),
			white
		)
		y -= every
	end
	Kit.trim(
		m,
		"Cornice",
		Vector3.new(sx0 - cr.proud, H - cr.thick + 0.06, zS - fin.proud - cr.proud),
		Vector3.new(sx1 + cr.proud, H + 0.06, zB + cr.proud),
		white
	)

	-------------------------------------------------------------------------------------------------------
	-- The stair: n orange blocks from in front of the slab's end down to the site's far end, each a drop lower, a
	-- run further along and further toward the street; every step a terrace with a cap, a rail and a lit riser
	-------------------------------------------------------------------------------------------------------
	local count = SHAPE.steps[rhythm]
	local drop = SHAPE.drop[rhythm]
	local ws = SHAPE.wingStart
	local wx0 = sx1 - math.clamp(sw * ws[1], ws[2], ws[3])
	local wx1 = hw - SHAPE.edge
	local run = (wx1 - wx0) / count
	local zFirst = zS - SHAPE.wingFront
	local zLast = math.min(zFirst, -hd + SHAPE.frontClear)
	local cp = SHAPE.cap
	local rs = SHAPE.riser
	local planter = SHAPE.planter
	local windows = Kit.look(pal.windows, Enum.Material.SmoothPlastic)
	for i = 1, count do
		local x0, x1 = wx0 + (i - 1) * run, wx0 + i * run
		local z0 = zFirst + (zLast - zFirst) * (i - 1) / math.max(1, count - 1)
		local top = SHAPE.lowest + (count - i) * drop
		local beyond = x0 >= sx1 -- clear of the slab: its back shows (left plain: overlays cost draw calls)
		-- Every step stands further toward the street than the one before, so its left side shows in front of that one
		-- (Studio round 1: left bare, those sides showed the dark window colour as brown slots between the steps).
		local faces: { Enum.NormalId } = { FRONT, LEFT, RIGHT }
		-- The step: punched orange, its windows dark matte.
		local step = Kit.box(m, `Step{i}`, Vector3.new(x0, yb, z0), Vector3.new(x1, top, zB - 1), windows)
		local overlays: { Types.TextureSpec } = {}
		for _, face in faces do
			table.insert(
				overlays,
				{ face = Kit.face(m, face), image = City.textures.punched, u = SHAPE.bay, v = F, color = pal.wing }
			)
		end
		step.textures = overlays
		-- The riser: the step's top floor is a band of glass under the cap, lit at night (a lit tread).
		local capBottom = top - cp.thick + cp.over
		Kit.glass(
			m,
			`Riser{i}`,
			Vector3.new(x0 + rs.inset, top - F + rs.foot, z0 - rs.proud),
			Vector3.new(x1 - rs.inset, capBottom - 0.05, z0 + 0.3),
			P.window.dark,
			{
				image = City.textures.windowBold,
				faces = { FRONT },
				u = SHAPE.bay,
				v = capBottom - 0.05 - (top - F + rs.foot),
				lines = pal.wing,
				lit = true,
			}
		)
		-- A white cap: it wraps the riser and the front (and the free left side of the first), tucked into the taller
		-- step on its left.
		local capTop = top + cp.over
		Kit.trim(
			m,
			`Cap{i}`,
			Vector3.new(x0 - (if i == 1 then cp.proud else 0.3), capBottom, z0 - cp.proud),
			Vector3.new(x1 + cp.proud, capTop, zB - 1 + (if beyond then cp.proud else 0)),
			white
		)
		-- The terrace's glass rail along its front edge.
		Kit.detail(
			m,
			`Rail{i}`,
			Vector3.new(x0 + 0.3, capTop, z0 - cp.proud + 0.15),
			Vector3.new(x1 + cp.proud - 0.15, capTop + SHAPE.rail, z0 - cp.proud + 0.45),
			RAIL
		)
		if i % 2 == 0 then
			Kit.planter(
				m,
				`Planter{i}`,
				Vector3.new(x0 + planter.inset, capTop, z0 + 0.6),
				Vector3.new(x1 - planter.inset, capTop + planter.tall, z0 + 0.6 + planter.deep),
				white
			)
		end
	end

	-------------------------------------------------------------------------------------------------------
	-- The slab's free front: a shopfront, a canopy with the name on it, a wash up the white face
	-------------------------------------------------------------------------------------------------------
	local cn = SHAPE.canopy
	local shopFront = zS - fin.proud - 0.05
	Kit.glass(
		m,
		"Shop",
		Vector3.new(sx0 + 1.8, 0.2, zS - 0.3),
		Vector3.new(wx0 - 1, SHAPE.shop, zS + 0.05),
		rgb(44, 60, 70),
		{
			image = City.textures.windowBold,
			faces = { FRONT },
			u = 5,
			v = SHAPE.shop - 0.2,
			lines = stucco,
			lit = true,
		}
	)
	local cx0, cx1 = sx0 + cn.inset, wx0 - cn.inset
	Kit.canopy(m, "Canopy", cx0, cx1, zS - cn.reach - fin.proud, shopFront + 0.5, cn.y, cn.thick, white)
	local canopyTop = cn.y + cn.thick
	local cmid, chalf = (cx0 + cx1) / 2, math.min(14, (cx1 - cx0) / 2 - 2)
	local signZ = zS - cn.reach - fin.proud
	Kit.sign(
		m,
		"Name",
		Vector3.new(cmid - chalf, canopyTop, signZ + 0.3),
		Vector3.new(cmid + chalf, canopyTop + 2.4, signZ + 0.8),
		FRONT,
		tag,
		pal.wing,
		stucco,
		City.districtLooks.downtown.font
	)
	Kit.wash(m, "Wash", cx0 + 1, cx1 - 1, signZ + 1.5, canopyTop, pal.wash)

	-------------------------------------------------------------------------------------------------------
	-- Crown
	-------------------------------------------------------------------------------------------------------
	local roof = H + 0.06
	if variant.crown == 1 then
		-- A green glass penthouse at the slab's free end, a white roof over it, a plant room toward the stair.
		local pt = SHAPE.penthouse
		local px1 = sx0 + sw * pt.share
		Kit.glass(
			m,
			"Penthouse",
			Vector3.new(sx0 + 3, roof, zS + 3),
			Vector3.new(px1, roof + pt.tall, zB - 3),
			rgb(70, 130, 128),
			{
				image = City.textures.windowFine,
				faces = { FRONT, LEFT },
				u = 4,
				v = pt.tall,
				lines = stucco,
				lit = true,
			}
		)
		Kit.trim(
			m,
			"PenthouseRoof",
			Vector3.new(sx0 + 1.8, roof + pt.tall, zS + 1.8),
			Vector3.new(px1 + 1.2, roof + pt.tall + pt.roof, zB - 1.8),
			white
		)
		Kit.roofBox(m, "Plant", Vector3.new(sx1 - 22, roof, zS + 5), Vector3.new(sx1 - 6, roof + 8, zB - 5), white)
	else
		-- Three white steps rising away from the stair, a lit band under the top one.
		local sc = SHAPE.steppedCrown
		local span = (sw - 6) / sc.count
		for j = 1, sc.count do
			Kit.box(
				m,
				`CrownStep{j}`,
				Vector3.new(sx0 + 3, roof + (j - 1) * sc.rise, zS + 3 + (j - 1) * 0.02),
				Vector3.new(sx1 - 3 - (j - 1) * span, roof + j * sc.rise, zB - 3 - (j - 1) * 0.02),
				white
			)
		end
		local topX1 = sx1 - 3 - (sc.count - 1) * span
		Kit.neonStrip(
			m,
			"CrownLed",
			Vector3.new(sx0 + 2.85, roof + sc.count * sc.rise - 1.6, zS + 2.85),
			Vector3.new(topX1 + 0.15, roof + sc.count * sc.rise - 1.1, zB - 2.85),
			"crown",
			stucco
		)
	end
end

local archetype: Types.Archetype = { id = "stair_wing_slab", build = build }
return archetype
