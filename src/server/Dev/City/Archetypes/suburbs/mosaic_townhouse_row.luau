--!strict
-- R08 mosaic_townhouse_row (docs/city/ARCHETYPES.md §7, R08): the new-urbanist island townhouses. A row of four to six
-- crisp white townhouses of different heights, their fronts staggered so each casts a shadow on the next, every one
-- with its own bold hit of colour and no two alike: a coloured box window pushed out of the facade, a coloured
-- balcony slab over a glass wall, a coloured blade running past the roof, or a coloured upper facade with punched
-- windows. Each has a garage door below and a tall glass stair slot; roof stair houses carry thin canopies over roof
-- terraces; on some copies the end unit rises taller in blue-green mosaic tile. A concrete apron and planters.
--
-- What makes it itself: a row of white townhouses of different heights, each with one bold colour panel, and a
-- mosaic-clad end.
-- Placement, sizes, heights and its budget: Config/CityArchetypes/mosaic_townhouse_row.
-- Variants: palette (4: the order of the five colours and the four kinds of colour hit), crown (1 all white, canopies
-- on alternate houses, 2 the mosaic end unit, the tallest by four), rhythm (2 orders of heights and stagger), mirror (the mosaic end left or
-- right).
--
-- Previewing: from the street at eye height and at an angle down the row. Check the units read as separate houses
-- (their fronts 1.6 apart, their tops apart), the colour hits read from a distance without looking like a toy, the
-- mosaic reads as tile (CeramicTiles) and not as plain teal, the canopies seem to hang from their stair houses. At
-- night: the stair slots and the glass glow.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local City = require(ReplicatedStorage.Shared.Config.City)
local Kit = require(script.Parent.Parent.Parent.Kit)
local Types = require(script.Parent.Parent.Parent.Types)

local P = City.palettes
local KIT = City.kit
local rgb = Color3.fromRGB

-- The recipe, in studs.
local SHAPE = {
	side = 2,
	yard = { 0.18, 7, 10 },
	depth = { 0.6, 26, 32 },
	unit = 14, -- a unit's width, about
	units = { 4, 6 },
	floor = 11,
	stagger = 1.6,
	drops = { { 0, 8, 4, 12, 0, 8 }, { 12, 4, 0, 8, 4, 12 } }, -- each unit's roof under the tallest, by rhythm
	mosaicRise = 4, -- crown 2: the mosaic end over the tallest
	garage = { width = 8.4, tall = 8, from = 1 },
	slot = { width = 1.6, from = 1 }, -- from the unit's right edge
	stair = { deep = 4.5, back = 1.5, tall = 3.4 },
	canopy = { deep = 9, thick = 0.4 },
}

-- The five colour hits; a palette starts the row at a different one and with a different kind of hit.
local COLOURS = {
	rgb(244, 197, 66), -- yellow
	rgb(45, 95, 176), -- cobalt
	rgb(240, 138, 60), -- tangerine
	rgb(169, 201, 74), -- lime
	rgb(200, 65, 126), -- magenta
}
local HITS = { "box", "balcony", "blade", "facade" }

local WHITE = rgb(246, 246, 243)
local MOSAIC = rgb(63, 167, 156)
local GARAGE = rgb(196, 200, 204)
local CONCRETE = rgb(226, 222, 214)

local function share(x: number, rule: { number }): number
	return math.clamp(x * rule[1], rule[2], rule[3])
end

local function build(m: Types.Model)
	local site = m.site
	local variant = site.variant
	local p = math.clamp(variant.palette, 1, 4)
	local mosaicEnd = variant.crown == 2
	local drops = SHAPE.drops[math.clamp(variant.rhythm, 1, 2)]
	local W, D, H = site.width, site.depth, site.height
	local hw, hd = W / 2, D / 2
	local F = SHAPE.floor

	local white = Kit.look(WHITE, Enum.Material.SmoothPlastic)
	local glass = P.window.dark
	local front = { Enum.NormalId.Front }
	-- Tall glass gets mullions only: one overlay tile well taller than the glass, so the tile's spandrel (its lower
	-- third) falls past the part's edge. At a floor-tall tile (11) the spandrel is drawn several studs thick and soft, and read as a smudge
	-- across every window in the first preview.
	local function fine(tall: number): Kit.GlassOptions
		return {
			image = City.textures.windowFine,
			faces = front,
			u = 2.4,
			v = tall * 1.6 + 2,
			lines = WHITE,
			lit = true,
		}
	end

	local X0, X1 = -hw + SHAPE.side, hw - SHAPE.side
	local avail = X1 - X0
	local n = math.clamp(math.floor(avail / SHAPE.unit), SHAPE.units[1], SHAPE.units[2])
	local uw = avail / n
	local zF = -hd + share(D, SHAPE.yard)
	local zB = zF + share(D, SHAPE.depth)

	for i = 1, n do
		local ux0, ux1 = X0 + (i - 1) * uw, X0 + i * uw
		local zi = zF + (if (i + variant.rhythm) % 2 == 0 then SHAPE.stagger else 0)
		local mosaic = mosaicEnd and i == n
		local h = if mosaic then H + SHAPE.mosaicRise else H - drops[i]
		local colour = if mosaic then WHITE else COLOURS[(i + p - 2) % #COLOURS + 1]
		local hit = HITS[(i + 2 * p - 3) % #HITS + 1]
		local paint = Kit.look(colour, Enum.Material.SmoothPlastic)

		-- The house, its garage door below, its glass stair slot.
		Kit.box(
			m,
			`Unit{i}`,
			Vector3.new(ux0, -KIT.bury, zi),
			Vector3.new(ux1, h, zB),
			if mosaic then Kit.look(MOSAIC, Enum.Material.CeramicTiles) else white
		)
		local g = SHAPE.garage
		local gx0 = ux0 + g.from
		local door = Kit.trim(
			m,
			`Garage{i}`,
			Vector3.new(gx0, 0, zi - 0.12),
			Vector3.new(gx0 + math.min(g.width, uw - 4.6), g.tall, zi + 0.1),
			Kit.look(GARAGE, Enum.Material.Metal)
		)
		door.textures = {
			{ face = Enum.NormalId.Front, image = City.textures.slabLine, u = 8, v = 1.2, color = rgb(150, 154, 160) },
		}
		local s = SHAPE.slot
		local sx1 = ux1 - s.from
		if hit ~= "blade" then
			Kit.glass(
				m,
				`Slot{i}`,
				Vector3.new(sx1 - s.width, 0, zi - 0.15),
				Vector3.new(sx1, h - 1.6, zi + 0.3),
				glass,
				{
					image = City.textures.windowBold,
					faces = front,
					u = s.width,
					v = h * 1.6 + 2,
					lines = WHITE,
					lit = true,
				}
			)
		end

		-- The colour hit.
		local hx0, hx1 = ux0 + 0.8, sx1 - s.width - 0.6
		if hit == "box" then
			local top = math.min(3 * F - 0.8, h - 1.5)
			Kit.trim(m, `Box{i}`, Vector3.new(hx0, F + 1, zi - 1.6), Vector3.new(hx1, top, zi + 0.3), paint)
			Kit.glass(
				m,
				`BoxGlass{i}`,
				Vector3.new(hx0 + 0.7, F + 1.7, zi - 1.75),
				Vector3.new(hx1 - 0.7, top - 0.7, zi - 1.2),
				glass,
				fine(top - 0.7 - (F + 1.7))
			)
		elseif hit == "balcony" then
			-- A deep coloured balcony: a slab and a solid upstand, so the colour reads as a box and not a stray bar.
			Kit.trim(
				m,
				`Balcony{i}`,
				Vector3.new(ux0 + 0.4, 2 * F - 0.9, zi - 2.6),
				Vector3.new(hx1 + 0.3, 2 * F + 0.4, zi + 0.3),
				paint
			)
			Kit.trim(
				m,
				`BalconyFront{i}`,
				Vector3.new(ux0 + 0.4, 2 * F + 0.4, zi - 2.6),
				Vector3.new(hx1 + 0.3, 2 * F + 3.4, zi - 2.0),
				paint
			)
			Kit.glass(
				m,
				`Wall{i}`,
				Vector3.new(hx0 + 0.2, F + 1, zi - 0.12),
				Vector3.new(hx1, h - 1.6, zi + 0.3),
				glass,
				fine(h - 1.6 - (F + 1))
			)
		elseif hit == "blade" then
			-- A coloured blade up the stair side, past the roof; a glass ribbon beside it.
			Kit.trim(
				m,
				`Blade{i}`,
				Vector3.new(ux1 - 2.6, 0, zi - 1.6),
				Vector3.new(ux1 - 0.6, h + 1.6, zi + 0.3),
				paint
			)
			Kit.glass(
				m,
				`Ribbon{i}`,
				Vector3.new(hx0 + 0.2, F + 1, zi - 0.12),
				Vector3.new(ux1 - 3.2, h - 1.6, zi + 0.3),
				glass,
				fine(h - 1.6 - (F + 1))
			)
		else
			-- The upper facade in colour, punched with windows, a floor a tile.
			Kit.punched(
				m,
				`Facade{i}`,
				Vector3.new(ux0 + 0.1, F, zi - 0.15),
				Vector3.new(hx1 + 0.3, h - 0.04, zi + 0.4),
				colour,
				glass,
				front,
				(hx1 + 0.2 - ux0) / 2,
				F,
				true
			)
		end

		-- A roof stair house with a thin canopy over the roof terrace, on every other house.
		if (i + variant.crown) % 2 == 0 or mosaic then
			local st, c = SHAPE.stair, SHAPE.canopy
			local sz1 = zB - st.back
			local sz0 = sz1 - st.deep
			Kit.box(m, `Stair{i}`, Vector3.new(ux0 + 1, h - 0.05, sz0), Vector3.new(ux1 - 1, h + st.tall, sz1), white)
			Kit.trim(
				m,
				`Canopy{i}`,
				Vector3.new(ux0 + 0.5, h + st.tall, sz0 - c.deep),
				Vector3.new(ux1 - 0.5, h + st.tall + c.thick, sz1 + 0.3),
				white
			)
		end
	end

	-- The lot: a concrete apron across the front, planters at the row's ends.
	Kit.detail(
		m,
		"Apron",
		Vector3.new(X0 - 1, 0.02, -hd + 0.2),
		Vector3.new(X1 + 1, 0.14, zF + SHAPE.stagger - 0.05),
		Kit.look(CONCRETE, Enum.Material.Concrete)
	)
	for i, endX in { X0 + uw, X1 } do
		local sx1 = endX - SHAPE.slot.from
		Kit.planter(m, `Planter{i}`, Vector3.new(sx1 - 2.6, 0, zF - 5), Vector3.new(sx1, 1.2, zF - 2.8), white)
	end
end

local archetype: Types.Archetype = { id = "mosaic_townhouse_row", build = build }
return archetype
