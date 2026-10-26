--!strict
-- T17 car_lift_cylinder_tower (docs/city/ARCHETYPES.md §5, T17): a round tower of near-black glass, ringed by silver
-- balcony discs, with a glass car-lift shaft running its full height up one side and past the roof. The shaft stands
-- on a white spine half sunk into the drum (the rings end in it); in front of a pale backdrop panel, cars sit on lift
-- platforms at different heights, one waiting in the drive-in bay at the street. At night the backdrop glows ice
-- blue, so the shaft is a vertical light line with the cars in silhouette, every sixth ring glows and a few seeded
-- floors glow warm as bands between the rings. A recessed
-- glass lobby drum under the first ring, a round plinth, the name on the first ring; on wide sites a drive-in court
-- with a round mushroom canopy and a low glass pavilion.
--
-- What makes it itself: a dark cylinder with a lit glass lift up its side, cars parked in the air.
-- Placement, sizes, heights and its budget: Config/CityArchetypes/car_lift_cylinder_tower.
-- Variants: palette (1 black glass and silver rings, 2 bronze glass and champagne rings with amber LEDs, 3 navy glass
-- and white rings), crown (1 a metal band round the top with a lit line under it, 2 two stepped drums with a lit rim,
-- 3 a lit glass top floor under a wide overhanging cap), rhythm (1 a ring every second floor with glass rails, 2 a ring
-- every floor, 3 every third floor with rails), mirror (which side the shaft stands on).
--
-- Previewing, check: the cars read as cars through the shaft glass from the street (body, cabin, wheels) and sit on
-- their platforms; the rings stop cleanly in the spine and never show inside the shaft; the shaft glass is see-through
-- but not invisible; the lobby reads as recessed under ring 0; at night the backdrop is one clean blue light line (no
-- white bloom bar) and the cars show dark against it, the lit floors read as thin warm bands, never a lit tube; the
-- drum is not too thin for its height on 46-deep sites.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local City = require(ReplicatedStorage.Shared.Config.City)
local Environment = require(ReplicatedStorage.Shared.Config.Environment)
local Kit = require(script.Parent.Parent.Parent.Kit)
local Types = require(script.Parent.Parent.Parent.Types)

local P = City.palettes
local KIT = City.kit
local NIGHT = Environment.nightLights
local rgb = Color3.fromRGB

-- The recipe, in studs.
local SHAPE = {
	floor = 12,
	lobby = 16, -- the double-height ground floor
	frontClear = 4.5, -- the drum stands this far behind the front line (its rings 1)
	depthLeft = 9, -- the drum is as wide as the site is deep, less this (rings and clearances)
	sideRoom = 10.1, -- the drum is at most the site's width less the shaft and this (rings, spine, margins)
	diameter = { 34, 64 },
	lobbyInset = 5, -- the lobby drum is this much narrower each side
	ring = { proud = 3.5, thick = 1.2, ledEvery = 6 },
	-- Lit floors at night: how many (seeded floors, repeats skipped), their gap under and over the floor's rings, and
	-- how far they stand proud of the drum.
	litFloor = { count = { 3, 6 }, gap = 0.5, proud = 0.15 },
	spine = { into = 3, past = 0.6, wider = 0.5 }, -- into the drum; past the rings' edge; past the shaft's sides
	shaft = { length = { 0.2, 20, 24 }, depth = { 0.26, 10, 12 }, post = 1.4, overrun = 8, cap = 2, edge = 1.5 },
	glassReflectance = 0.08, -- the drum's: low, so it reads near-black, not a mirror of the sky
	cars = 4, -- up the shaft, one in each quarter of its height (and one in the street bay)
	car = {
		length = 16,
		width = 7,
		clearance = 0.9, -- the body's underside over the platform
		body = 2.6,
		cabin = 1.9,
		cabinLength = 7.5,
		cabinBack = 3.6, -- the cabin starts this far from the car's back
		wheel = 2.2,
		axle = 3, -- the axles stand this far in from the car's ends
		platform = 0.6,
	},
	court = 26, -- a site with this much room beside the tower gets the drive-in court
	canopy = { y = 12.5, thick = 1, diameter = { 16, 28 }, post = 1.6 },
	pavilion = 13,
	crownBand = 10,
	crownSteps = 20,
	crownCap = 14,
}

-- Drum glass, ring and spine colour, the rings' LED kind, the shaft's backdrop by day (dark, so the cars' paint shows
-- through the shaft glass; it glows cool white at night and the cars turn to silhouettes).
local PALETTES = {
	{ glass = rgb(24, 28, 34), ring = rgb(206, 212, 218), led = "ledEdge", backdrop = rgb(52, 58, 66) },
	{ glass = rgb(52, 42, 34), ring = rgb(218, 202, 170), led = "neonAmber", backdrop = rgb(70, 60, 50) },
	{ glass = rgb(26, 38, 54), ring = P.frame.white, led = "ledBlue", backdrop = rgb(48, 60, 76) }, -- a bluer night
}

local RHYTHMS = {
	{ every = 24, rails = true },
	{ every = 12, rails = false },
	{ every = 36, rails = true },
}

-- Paint for the cars in the shaft (original shapes, no make).
local CARS = {
	rgb(196, 44, 40),
	rgb(240, 240, 236),
	rgb(238, 190, 40),
	rgb(176, 182, 190),
	rgb(26, 28, 32),
	rgb(40, 96, 170),
}

local RAIL = Kit.look(rgb(214, 236, 242), Enum.Material.Glass, 0.1, KIT.railTransparency)
local SHAFT_GLASS = Kit.look(rgb(200, 226, 236), Enum.Material.Glass, 0.15, KIT.railTransparency)
local SHAFT_NIGHT = rgb(88, 124, 168) -- the backdrop's night colour: a mid ice blue, under the bloom
local FRONT, LEFT = Enum.NormalId.Front, Enum.NormalId.Left

local function build(m: Types.Model)
	local site = m.site
	local variant = site.variant
	local pal = PALETTES[math.clamp(variant.palette, 1, #PALETTES)]
	local rhythm = RHYTHMS[math.clamp(variant.rhythm, 1, #RHYTHMS)]
	local crown = math.clamp(variant.crown, 1, 3)
	local rng = Kit.rng(m)
	local W, D, H = site.width, site.depth, site.height
	local hw, hd = W / 2, D / 2
	local white = P.frame.white
	local ringLook = Kit.look(pal.ring, Enum.Material.SmoothPlastic)
	local frameLook = Kit.look(white, Enum.Material.SmoothPlastic)
	local glassLook = Kit.glassLook(pal.glass, SHAPE.glassReflectance)
	local tag = City.signNames.towers[rng:NextInteger(1, #City.signNames.towers)]

	-------------------------------------------------------------------------------------------------------
	-- Layout: the drum and the shaft beside it, right-aligned; the room left over is a court, or they centre
	-------------------------------------------------------------------------------------------------------
	local sh = SHAPE.shaft
	local sp = SHAPE.spine
	local rp = SHAPE.ring.proud
	local L = math.clamp(W * sh.length[1], sh.length[2], sh.length[3])
	local d = math.clamp(math.min(D - SHAPE.depthLeft, W - L - SHAPE.sideRoom), SHAPE.diameter[1], SHAPE.diameter[2])
	local R = d / 2
	local xs1 = hw - sh.edge -- the shaft's outer end
	local xs0 = xs1 - L
	local xc = xs0 - sp.past - rp - R
	local leftover = (xc - R - rp) - (-hw + 1)
	local court = leftover >= SHAPE.court
	if not court then
		local shift = leftover / 2
		xc -= shift
		xs0 -= shift
		xs1 -= shift
	end
	local zc = -hd + SHAPE.frontClear + R + math.max(0, D - SHAPE.depthLeft - d) * 0.35
	local sd = math.clamp(d * sh.depth[1], sh.depth[2], sh.depth[3])
	local sz0, sz1 = zc - sd / 2, zc + sd / 2

	-- The body's top under each crown.
	local Ht = if crown == 1 then H - SHAPE.crownBand elseif crown == 2 then H - SHAPE.crownSteps else H - SHAPE.crownCap

	-------------------------------------------------------------------------------------------------------
	-- Base: a round plinth, the recessed lobby drum, the first ring as its canopy with the name on it
	-------------------------------------------------------------------------------------------------------
	local stone = Kit.look(rgb(222, 218, 210), Enum.Material.Limestone)
	Kit.column(m, "Plinth", xc, zc, -KIT.bury, 0.6, d + 2, stone)
	local lobby = Kit.column(
		m,
		"Lobby",
		xc,
		zc,
		-KIT.bury,
		SHAPE.lobby,
		d - 2 * SHAPE.lobbyInset,
		Kit.glassLook(rgb(44, 60, 70), 0.2)
	)
	Kit.lit(lobby, "window")
	local sw = math.min(8, R * 0.4)
	Kit.sign(
		m,
		"Name",
		Vector3.new(xc - sw, SHAPE.lobby + SHAPE.ring.thick + 0.1, zc - R - 1.6),
		Vector3.new(xc + sw, SHAPE.lobby + SHAPE.ring.thick + 2.5, zc - R - 1.1),
		FRONT,
		tag,
		rgb(30, 32, 36),
		pal.ring,
		City.districtLooks.downtown.font
	)

	-------------------------------------------------------------------------------------------------------
	-- The drum: one run of dark glass; a few seeded floors glow warm at night as bands just proud of it (a
	-- cylinder can't carry the window grid, so a whole lit run read as a flat orange tube)
	-------------------------------------------------------------------------------------------------------
	local every = rhythm.every
	Kit.column(m, "Drum", xc, zc, SHAPE.lobby - 0.5, Ht, d, glassLook)
	local lf = SHAPE.litFloor
	local floors = math.floor((Ht - SHAPE.lobby) / SHAPE.floor)
	local taken: { [number]: boolean } = {}
	for b = 1, rng:NextInteger(lf.count[1], lf.count[2]) do
		local fl = rng:NextInteger(1, math.max(1, floors - 2))
		if not taken[fl] then
			taken[fl] = true
			local y0 = SHAPE.lobby + fl * SHAPE.floor
			local band = Kit.column(
				m,
				`LitFloor{b}`,
				xc,
				zc,
				y0 + SHAPE.ring.thick + lf.gap,
				y0 + SHAPE.floor - lf.gap,
				d + 2 * lf.proud,
				glassLook,
				"detail"
			)
			Kit.lit(band, "window")
		end
	end

	-- Ring balconies: discs every `every` studs from the lobby's top, glass rail pucks on them, every sixth one lit.
	local k = 0
	local y = SHAPE.lobby
	while y + SHAPE.ring.thick <= Ht - 4 do
		local ring = Kit.disc(m, `Ring{k}`, xc, zc, y + SHAPE.ring.thick / 2, d + 2 * rp, SHAPE.ring.thick, ringLook)
		if k % SHAPE.ring.ledEvery == 3 then
			Kit.lit(ring, pal.led)
		end
		if rhythm.rails and k > 0 then
			local r0 = y + SHAPE.ring.thick
			Kit.column(m, `Rail{k}`, xc, zc, r0, r0 + KIT.railHeight, d + 2 * rp - 0.3, RAIL, "detail")
		end
		k += 1
		y += every
	end

	-------------------------------------------------------------------------------------------------------
	-- Crowns
	-------------------------------------------------------------------------------------------------------
	local lineLook = Kit.look(white, Enum.Material.SmoothPlastic)
	if crown == 1 then
		-- A metal band round the top, a lit line under its edge.
		Kit.column(m, "Band", xc, zc, Ht, H, d + 1.2, Kit.look(pal.ring, Enum.Material.Metal))
		Kit.lit(Kit.disc(m, "BandLine", xc, zc, Ht - 0.5, d + 1.6, 0.4, lineLook, "detail"), "crown")
	elseif crown == 2 then
		-- Two drums stepping in over a terrace, a lit rim between them.
		Kit.disc(m, "Terrace", xc, zc, Ht + 0.6, d + 2, 1.2, ringLook)
		Kit.column(m, "Tier1", xc, zc, Ht + 1.2, H - 9, d - 8, glassLook)
		Kit.lit(Kit.disc(m, "Tier2Rim", xc, zc, H - 8.7, d - 4, 0.6, lineLook), "crown")
		Kit.column(m, "Tier2", xc, zc, H - 8.4, H, d - 18, ringLook)
	else
		-- A lit glass top floor under a wide cap, its rim lit.
		Kit.disc(m, "Ledge", xc, zc, Ht + 0.6, d + 2, 1.2, ringLook)
		Kit.lit(Kit.column(m, "TopFloor", xc, zc, Ht + 1.2, H - 2, d - 6, glassLook), "window")
		Kit.column(m, "Cap", xc, zc, H - 2, H, d + 6, ringLook)
		Kit.lit(Kit.disc(m, "CapLine", xc, zc, H - 2.3, d + 6.4, 0.4, lineLook, "detail"), "crown")
	end

	-------------------------------------------------------------------------------------------------------
	-- The lift shaft: spine, see-through glass, corner posts, a backdrop that glows, a machine room on top
	-------------------------------------------------------------------------------------------------------
	local Hs = H + sh.overrun
	local post = sh.post
	Kit.box(
		m,
		"Spine",
		Vector3.new(xc + R - sp.into, -KIT.bury, sz0 - sp.wider),
		Vector3.new(xs0, Hs, sz1 + sp.wider),
		ringLook
	)
	local shaft = Kit.box(m, "Shaft", Vector3.new(xs0, 0, sz0), Vector3.new(xs1, Hs, sz1), SHAFT_GLASS)
	shaft.shadow = false
	for i, z in { sz0, sz1 } do
		Kit.trim(
			m,
			`ShaftPost{i}`,
			Vector3.new(xs1 - post / 2, -KIT.bury, z - post / 2),
			Vector3.new(xs1 + post / 2, Hs, z + post / 2),
			ringLook
		)
	end
	local backdrop = Kit.neonStrip(
		m,
		"Backdrop",
		Vector3.new(xs0 + 0.3, 0.6, sz1 - 0.45),
		Vector3.new(xs1 - 0.6, Hs - 1, sz1 - 0.15),
		"crown",
		pal.backdrop
	)
	-- Its own, dimmer night colour: the crown's cool white on a panel this big blew out to a flat white bar that hid
	-- the cars; this reads as a lit glass shaft with the cars dark against it.
	local attributes: { [string]: any } = backdrop.attributes or {}
	attributes[NIGHT.nightColorAttribute] = SHAFT_NIGHT
	backdrop.attributes = attributes
	Kit.box(
		m,
		"ShaftCap",
		Vector3.new(xc + R - sp.into, Hs, sz0 - sp.wider - 0.2),
		Vector3.new(xs1 + post / 2 + 0.2, Hs + sh.cap, sz1 + sp.wider + 0.2),
		ringLook
	)

	-- Cars on their platforms: one in the drive-in bay, one up the shaft in each quarter of its height at a seeded floor.
	local c = SHAPE.car
	local floorsUp = math.max(SHAPE.cars * 2, math.floor((Ht - SHAPE.lobby - 24) / SHAPE.floor))
	local stops: { number } = { 0.2 }
	local band = floorsUp / SHAPE.cars
	for q = 1, SHAPE.cars do
		local lo = math.max(2, math.floor((q - 1) * band) + 1)
		local hi = math.max(lo, math.floor(q * band) - 1)
		table.insert(stops, SHAPE.lobby + rng:NextInteger(lo, hi) * SHAPE.floor + 0.2)
	end
	local platformLook = Kit.look(rgb(54, 58, 64), Enum.Material.Metal)
	local tyre = Kit.look(rgb(24, 24, 26), Enum.Material.SmoothPlastic)
	local cabin = Kit.glassLook(P.glass.smoke, 0.3)
	for i, at in stops do
		Kit.detail(
			m,
			`Platform{i}`,
			Vector3.new(xs0 + 0.4, at, sz0 + 0.4),
			Vector3.new(xs1 - 0.4, at + c.platform, sz1 - 0.6),
			platformLook
		)
		local base = at + c.platform
		local cx = (xs0 + xs1) / 2 + (rng:NextNumber() - 0.5)
		local half = c.length / 2
		local paint = Kit.look(CARS[rng:NextInteger(1, #CARS)], Enum.Material.SmoothPlastic, 0.15)
		local bodyTop = base + c.clearance + c.body
		Kit.detail(
			m,
			`Car{i}`,
			Vector3.new(cx - half, base + c.clearance, zc - c.width / 2),
			Vector3.new(cx + half, bodyTop, zc + c.width / 2),
			paint
		)
		Kit.detail(
			m,
			`Cabin{i}`,
			Vector3.new(cx - half + c.cabinBack, bodyTop, zc - c.width / 2 + 0.5),
			Vector3.new(cx - half + c.cabinBack + c.cabinLength, bodyTop + c.cabin, zc + c.width / 2 - 0.5),
			cabin
		)
		for j, wx in { cx - half + c.axle, cx + half - c.axle } do
			Kit.tube(
				m,
				`Wheel{i}{j}`,
				Vector3.new(wx, base + c.wheel / 2, zc - c.width / 2 - 0.15),
				Vector3.new(wx, base + c.wheel / 2, zc + c.width / 2 + 0.15),
				c.wheel,
				tyre
			)
		end
	end

	-------------------------------------------------------------------------------------------------------
	-- The drive-in court on wide sites: a mushroom canopy on one post, a low lit glass pavilion behind it
	-------------------------------------------------------------------------------------------------------
	if court then
		local cv = SHAPE.canopy
		local cz0, cz1 = -hw + 1.5, xc - R - rp - 1.5
		local cd = math.clamp(math.min(cz1 - cz0 - 2, D - 24), cv.diameter[1], cv.diameter[2])
		local ccx, ccz = (cz0 + cz1) / 2, -hd + 1 + cd / 2
		Kit.column(m, "CanopyPost", ccx, ccz, -KIT.bury, cv.y, cv.post, frameLook, "trim")
		Kit.disc(m, "Canopy", ccx, ccz, cv.y + cv.thick / 2, cd, cv.thick, frameLook)
		local pv0, pv1 = math.max(zc - R * 0.4, ccz + cd / 2 + 2), hd - 2.5
		if pv1 - pv0 >= 8 then
			Kit.glass(
				m,
				"Pavilion",
				Vector3.new(cz0 + 1, -KIT.bury, pv0),
				Vector3.new(cz1 - 1, SHAPE.pavilion, pv1),
				rgb(44, 60, 70),
				{
					image = City.textures.windowBold,
					faces = { FRONT, LEFT },
					u = 5,
					v = SHAPE.pavilion + KIT.bury,
					lines = white,
					lit = true,
				}
			)
			Kit.trim(
				m,
				"PavilionRoof",
				Vector3.new(cz0, SHAPE.pavilion - 0.2, pv0 - 1.5),
				Vector3.new(cz1, SHAPE.pavilion + 1, pv1 + 1.5),
				frameLook
			)
		end
	end
end

local archetype: Types.Archetype = { id = "car_lift_cylinder_tower", build = build }
return archetype
