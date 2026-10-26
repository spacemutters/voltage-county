--!strict
-- L5 construction_site (Config/CityLots; Config/CityArchetypes/construction_site): the next tower going up, very
-- Miami. The idea: a painted hoarding along the street with the project's name and its (invented) developer, a raw
-- concrete frame a few floors high round its core, and a yellow tower crane over it all. The core also has a site
-- cabin with lit windows. While its part allowance lasts it adds the dirt floor, the frame's columns, the lower floor
-- slabs, rebar sticking up from the top slab, a red beacon on the core, a second cabin stacked on the first and a
-- portable toilet.
-- Variants: palette (white hoarding with teal lettering, navy with white, peach with white), crown (the crane's jib
-- one way or the other), rhythm (the frame at the -x end with the cabins at +x, or the other way round), mirror.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local City = require(ReplicatedStorage.Shared.Config.City)
local CityLots = require(ReplicatedStorage.Shared.Config.CityLots)
local Kit = require(script.Parent.Parent.Parent.Kit)
local LotKit = require(script.Parent.Parent.Parent.LotKit)
local Types = require(script.Parent.Parent.Parent.Types)

local P = City.palettes
local rgb = Color3.fromRGB

-- The recipe, in studs.
local SHAPE = {
	hoarding = { front = 0.4, thick = 0.8, height = 8, side = 0.4 },
	labelCanvas = 1800, -- pixels: the hoarding's lettering canvas, at most this wide
	frame = { side = 3, front = 6, back = 8, maxWidth = 64, maxDepth = 34, room = 19 }, -- room: kept for the yard
	floor = 12, -- floor to floor
	slab = 0.8,
	core = 8, -- the lift and stair core, square, at the frame's back corner...
	coreInset = 0.3, -- ...this far inside the slabs' edges
	columns = 8, -- the frame's columns stand this far apart (drawn as a grid on a see-through box)
	rebar = { height = 3, bar = 0.6 },
	-- The crane rises `over` past the frame's core, within the site's crown. The build scales its mesh to that height
	-- (its jib comes out as long as the mesh has it), so keep it modest: a jib at this height clears the towers' podiums.
	-- depth: the crane's box's depth for each stud of its height (its mesh is about 0.12 as deep as it is tall), so the
	-- box, which the crane is fitted inside (Config/CityProps TowerCrane contain), only ever limits it by the site's width.
	crane = { side = 0.4, minHeight = 60, over = 45, depth = 0.12 },
	cabin = { w = 10, d = 5, height = 6, side = 3, back = 3 },
	toilet = Vector3.new(3, 7, 3),
	beacon = 1.2,
}

local PALETTES = {
	{ hoarding = rgb(246, 244, 238), text = rgb(40, 150, 160), cabin = rgb(250, 250, 248) },
	{ hoarding = rgb(30, 44, 70), text = rgb(246, 244, 238), cabin = rgb(255, 210, 130) },
	{ hoarding = rgb(255, 170, 120), text = rgb(246, 244, 238), cabin = rgb(246, 244, 238) },
}
local CONCRETE = rgb(196, 192, 184)
local CORE = rgb(176, 172, 164)
local DIRT = rgb(150, 126, 98)
local REBAR = rgb(120, 70, 50)
local TOILET = rgb(40, 96, 170)
local BEACON = rgb(200, 40, 36)

local function build(m: Types.Model)
	local site = m.site
	local v = site.variant
	local pal = LotKit.pick(PALETTES, v.palette)
	local limit = LotKit.allowance(site)
	local hw, hd = site.width / 2, site.depth / 2
	local H = site.height
	local top = LotKit.top
	local rng = Kit.rng(m, 5)

	-- The frame's footprint: at the -x end (rhythm 1) or the +x end, leaving the yard for the crane's foot and cabins.
	local f = SHAPE.frame
	local fw = math.min(site.width - 2 * f.side - f.room, f.maxWidth)
	local fd = math.min(site.depth - f.front - f.back, f.maxDepth)
	local fx0 = if v.rhythm == 2 then hw - f.side - fw else -hw + f.side
	local fx1 = fx0 + fw
	local fz0 = -hd + f.front
	local fz1 = fz0 + fd
	-- The yard: the other end's middle (the cabins at its back).
	local yardX = if v.rhythm == 2 then (-hw + fx0) / 2 else (fx1 + hw) / 2

	-- The core: the hoarding with its name, the frame's core and top slab, the crane, a cabin.
	local h = SHAPE.hoarding
	local hoarding = Kit.box(
		m,
		"Hoarding",
		Vector3.new(-hw + h.side, -0.5, -hd + h.front),
		Vector3.new(hw - h.side, h.height, -hd + h.front + h.thick),
		Kit.look(pal.hoarding, Enum.Material.SmoothPlastic)
	)
	local project = LotKit.pick(City.signNames.towers, rng:NextInteger(1, #City.signNames.towers))
	local developer = LotKit.pick(CityLots.names.developers, rng:NextInteger(1, #CityLots.names.developers))
	local look = City.districtLooks[site.district]
	hoarding.labels = {
		{
			face = Kit.face(m, Enum.NormalId.Front),
			text = `{project}  -  COMING SOON  -  {developer}`,
			color = pal.text,
			font = if look then look.font else Enum.Font.Michroma,
			size = Vector2.new(0.92, 0.5),
			-- A long hoarding at the sign's full sharpness drew past the largest canvas a SurfaceGui gets, and the name
			-- was cut off at both ends (the street-level roast, 2026-10-26, point 10): the canvas stays within
			-- SHAPE.labelCanvas pixels across.
			pixelsPerStud = math.min(City.kit.signPixelsPerStud, SHAPE.labelCanvas / (2 * hw - 2 * h.side)),
		},
	}
	-- The core stands a little inside the slabs' outline, so their edges read proud of it.
	local c = SHAPE.core
	local inset = SHAPE.coreInset
	local coreX = if v.rhythm == 2 then fx1 - inset - c / 2 else fx0 + inset + c / 2
	local coreZ = fz1 - inset - c / 2
	Kit.box(
		m,
		"Core",
		Vector3.new(coreX - c / 2, -0.5, coreZ - c / 2),
		Vector3.new(coreX + c / 2, H, coreZ + c / 2),
		Kit.look(CORE, Enum.Material.Concrete)
	)
	local floors = math.max(1, math.floor((H - 2) / SHAPE.floor))
	local slabTop = floors * SHAPE.floor
	local concrete = Kit.look(CONCRETE, Enum.Material.Concrete)
	Kit.trim(m, `Slab{floors}`, Vector3.new(fx0, slabTop - SHAPE.slab, fz0), Vector3.new(fx1, slabTop, fz1), concrete)
	local cr = SHAPE.crane
	local craneTall = math.max(cr.minHeight, math.min(H + cr.over, site.maxHeight - top - 0.2))
	local craneBox = Vector3.new(site.width - 2 * cr.side, craneTall, math.max(10, craneTall * cr.depth))
	LotKit.prop(m, "Crane", "TowerCrane", 0, (fz0 + fz1) / 2, if v.crown == 2 then 180 else 0, craneBox)
	local k = SHAPE.cabin
	local cabinLook = pal.cabin
	local function cabin(name: string, y0: number, color: Color3, lit: boolean)
		local cx0 = math.clamp(yardX - k.w / 2, -hw + k.side, hw - k.side - k.w)
		Kit.punched(
			m,
			name,
			Vector3.new(cx0, y0, hd - k.back - k.d),
			Vector3.new(cx0 + k.w, y0 + k.height, hd - k.back),
			color,
			P.window.dark,
			{ Enum.NormalId.Front, Enum.NormalId.Left, Enum.NormalId.Right },
			3.2,
			k.height + 0.5,
			lit
		)
	end
	cabin("Cabin", -0.5, cabinLook, true)

	-- The extras, in order, while the allowance lasts.
	if LotKit.fits(m, limit, 1) then
		LotKit.floor(m, "Dirt", -hw, -hd, hw, hd, Kit.look(DIRT, Enum.Material.Ground), top - 0.15)
	end
	if LotKit.fits(m, limit, 1) then
		-- The columns, beams and upstands: a see-through box over the frame with the punched-wall image on its sides
		-- (one open bay per tile, its tiles starting at the top slab, so the beams sit under the slabs). The curtain-wall
		-- grid it had read as a finished glass pavilion, not a concrete frame going up (2026-10-26).
		local cage = Kit.detail(
			m,
			"Frame",
			Vector3.new(fx0 + 0.05, 0, fz0 + 0.05),
			Vector3.new(fx1 - 0.05, slabTop - 0.05, fz1 - 0.05),
			Kit.look(CONCRETE, Enum.Material.Concrete, 0, 1)
		)
		LotKit.texture(
			m,
			cage,
			LotKit.images.punched,
			SHAPE.columns,
			SHAPE.floor,
			CONCRETE,
			{ Enum.NormalId.Front, Enum.NormalId.Back, Enum.NormalId.Left, Enum.NormalId.Right }
		)
	end
	for n = floors - 1, 1, -1 do
		if LotKit.fits(m, limit, 1) then
			local y = n * SHAPE.floor
			Kit.trim(m, `Slab{n}`, Vector3.new(fx0, y - SHAPE.slab, fz0), Vector3.new(fx1, y, fz1), concrete)
		end
	end
	if LotKit.fits(m, limit, 1) then
		local r = SHAPE.rebar
		Kit.railing(
			m,
			"Rebar",
			Vector3.new(fx0 + 1, slabTop, fz0 + 1),
			Vector3.new(fx1 - 1, slabTop + r.height, fz1 - 1),
			{ Enum.NormalId.Front, Enum.NormalId.Back, Enum.NormalId.Left, Enum.NormalId.Right },
			REBAR,
			r.bar
		)
	end
	if LotKit.fits(m, limit, 1) then
		local beacon = Kit.ball(
			m,
			"Beacon",
			Vector3.new(coreX, H + SHAPE.beacon / 2, coreZ),
			SHAPE.beacon,
			Kit.look(BEACON, Enum.Material.SmoothPlastic),
			"detail"
		)
		Kit.lit(beacon, "beacon")
	end
	if LotKit.fits(m, limit, 1) then
		cabin("Cabin2", k.height - 0.45, P.deco.white, false)
	end
	if LotKit.fits(m, limit, 1) then
		local t = SHAPE.toilet
		local tx = math.clamp(yardX + k.w / 2 + 3, -hw + t.X, hw - t.X)
		Kit.box(
			m,
			"Toilet",
			Vector3.new(tx - t.X / 2, -0.5, hd - k.back - t.Z),
			Vector3.new(tx + t.X / 2, t.Y, hd - k.back),
			Kit.look(TOILET, Enum.Material.SmoothPlastic)
		)
	end
end

local archetype: Types.Archetype = { id = "construction_site", build = build }
return archetype
