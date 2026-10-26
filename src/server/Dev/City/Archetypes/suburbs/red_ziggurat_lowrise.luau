--!strict
-- R05 red_ziggurat_lowrise (docs/city/ARCHETYPES.md §7, R05): the bright red stepped pyramid of apartments. Five red
-- blocks in a row, each a few floors taller than the last up to a six-storey peak and down again, so in section the
-- building is a staircase up and down. Every riser (the face a block shows over its lower neighbour) is ribbon
-- windows in red, stacked bands of light at night; white tube rails run along the terrace edges; and the long faces
-- carry white ship-like balcony decks with tube rails, floor over floor, as long as the blocks behind them are tall.
-- It steps along the road on a wide site (the street sees the pyramid) and back from it on a narrow one (the street
-- sees the stepped end, the decks run down the sides). A white entrance canopy, a lift house on the peak.
--
-- What makes it itself: a bright red stepped pyramid of apartments, in section a staircase up and down.
-- Placement, sizes, heights and its budget: Config/CityArchetypes/red_ziggurat_lowrise.
-- Variants: palette (1 red, 2 deep blue: still one strong colour), crown (1 the even pyramid 2-4-6-4-2 floors, 2 a
-- lopsided staircase 1-2-4-6-3), rhythm (1 a deck at every floor, 2 at every second), mirror.
--
-- Previewing: from the street, square on and from a corner, on a narrow (36) and a wide (80) site. Check the riser
-- windows' floor lines meet each block's top (Kit.punched counts tiles from the top), the decks stop short of each
-- step, the terrace rails sit on the right edges, and the red reads as red in the sky light. At night: the risers and
-- the long faces glow in bands.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local City = require(ReplicatedStorage.Shared.Config.City)
local Kit = require(script.Parent.Parent.Parent.Kit)
local Types = require(script.Parent.Parent.Parent.Types)

local KIT = City.kit
local rgb = Color3.fromRGB

-- The recipe, in studs.
local SHAPE = {
	floors = 6, -- at the peak
	profiles = { { 2, 4, 6, 4, 2 }, { 1, 2, 4, 6, 3 } }, -- floors per block, by crown (one peak each)
	end0 = 4, -- the row's first end from its site edge (room for the canopy on a narrow site)
	end1 = 1.5,
	sideRoom = 5, -- the long faces from the site's edges: the decks reach 3 into it
	deck = { proud = 3, thick = 0.9, inset = 0.8 },
	rail = { height = 3.2, inset = 0.6 }, -- white rails: square bars under a top rail (a Texture on an invisible part)
	-- Riser ribbon windows: one tile a pane. Under about 3 the overlay's tiles shrink below a pixel at street distance
	-- and the texture's mip levels smear the red bands into a pink haze (seen in the first preview at 1.3).
	bay = 3.2,
	sideBay = 4.4,
	canopy = { y = 8, thick = 0.6, proud = 3.4, half = 4.5 },
	lift = { half = 2.6, tall = 3.6 },
}

local PALETTES = {
	{ body = rgb(204, 46, 40), glass = rgb(46, 34, 40) },
	{ body = rgb(44, 76, 140), glass = rgb(30, 40, 58) },
}

local WHITE = rgb(250, 250, 248)
local RAIL = rgb(240, 242, 244)

local function build(m: Types.Model)
	local site = m.site
	local variant = site.variant
	local pal = PALETTES[math.clamp(variant.palette, 1, #PALETTES)]
	local profile = SHAPE.profiles[math.clamp(variant.crown, 1, 2)]
	local every = if variant.rhythm == 2 then 2 else 1
	local W, D, H = site.width, site.depth, site.height
	local hw, hd = W / 2, D / 2
	local f = H / SHAPE.floors

	local red = Kit.look(pal.body, Enum.Material.SmoothPlastic)
	local white = Kit.look(WHITE, Enum.Material.SmoothPlastic)
	-- A white rail panel facing `face`.
	local function rail(name: string, min: Vector3, max: Vector3, face: Enum.NormalId)
		local spec = Kit.detail(m, name, min, max, Kit.look(RAIL, Enum.Material.Metal, 0, 1))
		spec.textures = {
			{ face = Kit.face(m, face), image = City.textures.punched, u = 1.1, v = 6, color = RAIL },
		}
	end

	-------------------------------------------------------------------------------------------------------
	-- The frame: `a` runs along the row of blocks, `c` across it. Along the road when the site is wide, so the
	-- street sees the pyramid; back from it when narrow. at(a, y, c) is a point in the site's own x, y, z.
	-------------------------------------------------------------------------------------------------------
	local alongX = W >= D + 6
	local a0 = if alongX then -hw + SHAPE.end1 else -hd + SHAPE.end0
	local a1 = if alongX then hw - SHAPE.end1 else hd - SHAPE.end1
	local c0 = if alongX then -hd + SHAPE.sideRoom else -hw + SHAPE.sideRoom
	local c1 = if alongX then hd - SHAPE.sideRoom else hw - SHAPE.sideRoom
	local function at(a: number, y: number, c: number): Vector3
		return if alongX then Vector3.new(a, y, c) else Vector3.new(c, y, a)
	end
	-- The faces toward a0, a1, c0 and c1. On a wide site c0 is the street side.
	local faceA0 = if alongX then Enum.NormalId.Left else Enum.NormalId.Front
	local faceA1 = if alongX then Enum.NormalId.Right else Enum.NormalId.Back
	local faceC0 = if alongX then Enum.NormalId.Front else Enum.NormalId.Left
	local faceC1 = if alongX then Enum.NormalId.Back else Enum.NormalId.Right

	local n = #profile
	local L = (a1 - a0) / n
	local function blockA(k: number): (number, number)
		return a0 + (k - 1) * L, a0 + k * L
	end
	local function top(k: number): number
		return if k < 1 or k > n then 0 else profile[k] * f
	end

	-------------------------------------------------------------------------------------------------------
	-- The blocks, their risers and the terrace rails
	-------------------------------------------------------------------------------------------------------
	for k = 1, n do
		local ka0, ka1 = blockA(k)
		local h = top(k)
		Kit.box(m, `Block{k}`, at(ka0, -KIT.bury, c0), at(ka1, h, c1), red)
		-- A riser on each end that stands over its neighbour (or the ground): ribbon windows, whole floors from the top.
		local below0, below1 = top(k - 1), top(k + 1)
		if h > below0 then
			Kit.punched(
				m,
				`RiserA{k}`,
				at(ka0 - 0.06, below0, c0 + 0.6),
				at(ka0 + 0.4, h - 0.04, c1 - 0.6),
				pal.body,
				pal.glass,
				{ faceA0 },
				SHAPE.bay,
				f,
				true
			)
			local r = SHAPE.rail
			rail(`EdgeRailA{k}`, at(ka0 + 0.3, h, c0 + r.inset), at(ka0 + 0.45, h + r.height, c1 - r.inset), faceA0)
		end
		if h > below1 then
			Kit.punched(
				m,
				`RiserB{k}`,
				at(ka1 - 0.4, below1, c0 + 0.6),
				at(ka1 + 0.06, h - 0.04, c1 - 0.6),
				pal.body,
				pal.glass,
				{ faceA1 },
				SHAPE.bay,
				f,
				true
			)
			local r = SHAPE.rail
			rail(`EdgeRailB{k}`, at(ka1 - 0.45, h, c0 + r.inset), at(ka1 - 0.3, h + r.height, c1 - r.inset), faceA1)
		end
	end

	-- The blocks at least `floors` tall: one unbroken run, since the profile has one peak.
	local function run(floors: number): (number?, number?)
		local first: number?, last: number? = nil, nil
		for k = 1, n do
			if profile[k] >= floors then
				first = first or k
				last = k
			end
		end
		return first, last
	end

	-------------------------------------------------------------------------------------------------------
	-- The long faces: windows in bands (one per step of the skyline) and the ship-deck balconies
	-------------------------------------------------------------------------------------------------------
	local levels: { number } = { 0 }
	for _, floors in profile do
		if not table.find(levels, floors) then
			table.insert(levels, floors)
		end
	end
	table.sort(levels)
	for j = 2, #levels do
		local first, last = run(levels[j])
		if first and last then
			local fa0 = blockA(first)
			local _, fa1 = blockA(last)
			local y0, y1 = levels[j - 1] * f, levels[j] * f - 0.04
			for side, c in { c0, c1 } do
				local out = if side == 1 then -1 else 1
				Kit.punched(
					m,
					`Side{j}{side}`,
					at(fa0 + 0.5, y0 + (if j == 2 then 0.4 else 0), c - out * 0.4),
					at(fa1 - 0.5, y1, c + out * 0.06),
					pal.body,
					pal.glass,
					{ if side == 1 then faceC0 else faceC1 },
					SHAPE.sideBay,
					f,
					true
				)
			end
		end
	end
	local deck = SHAPE.deck
	for floor = 1, SHAPE.floors - 1, every do
		local first, last = run(floor + 1)
		if first and last then
			local fa0 = blockA(first)
			local _, fa1 = blockA(last)
			local y = floor * f
			for side, c in { c0, c1 } do
				local out = if side == 1 then -1 else 1
				Kit.trim(
					m,
					`Deck{floor}{side}`,
					at(fa0 + deck.inset, y - deck.thick / 2, c - out * 0.3),
					at(fa1 - deck.inset, y + deck.thick / 2, c + out * deck.proud),
					white
				)
				local r = SHAPE.rail
				local ry = y + deck.thick / 2
				rail(
					`DeckRail{floor}{side}`,
					at(fa0 + deck.inset + 0.1, ry, c + out * (deck.proud - 0.3)),
					at(fa1 - deck.inset - 0.1, ry + r.height, c + out * (deck.proud - 0.15)),
					if side == 1 then faceC0 else faceC1
				)
			end
		end
	end

	-------------------------------------------------------------------------------------------------------
	-- The way in: a white canopy over a glass door on the street face of the first block; the lift house on the peak
	-------------------------------------------------------------------------------------------------------
	local c = SHAPE.canopy
	local ka0, ka1 = blockA(1)
	if alongX then
		-- The street face is c0; the door in the middle of the first block, under the first deck.
		local mid = (ka0 + ka1) / 2
		Kit.trim(
			m,
			"Canopy",
			Vector3.new(mid - c.half, c.y, c0 - c.proud),
			Vector3.new(mid + c.half, c.y + c.thick, c0 + 0.3),
			white
		)
		Kit.glass(
			m,
			"Door",
			Vector3.new(mid - 2.4, 0, c0 - 0.2),
			Vector3.new(mid + 2.4, c.y - 0.6, c0 + 0.3),
			pal.glass,
			{
				lit = true,
			}
		)
	else
		-- The street face is the first block's riser (a0).
		Kit.canopy(m, "Canopy", -c.half, c.half, ka0 - c.proud, ka0 + 0.3, c.y, c.thick, white)
		Kit.glass(
			m,
			"Door",
			Vector3.new(-2.4, 0, ka0 - 0.25),
			Vector3.new(2.4, c.y - 0.6, ka0 + 0.3),
			pal.glass,
			{ lit = true }
		)
	end
	local peak = 1
	for k = 2, n do
		if profile[k] > profile[peak] then
			peak = k
		end
	end
	local pa0, pa1 = blockA(peak)
	local pa, pc = (pa0 + pa1) / 2, (c0 + c1) / 2
	local l = SHAPE.lift
	Kit.roofBox(m, "Lift", at(pa - l.half, H - 0.05, pc - l.half), at(pa + l.half, H + l.tall, pc + l.half), white)
end

local archetype: Types.Archetype = { id = "red_ziggurat_lowrise", build = build }
return archetype
