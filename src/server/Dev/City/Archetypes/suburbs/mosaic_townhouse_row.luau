--!strict
-- R08 mosaic_townhouse_row (docs/city/ARCHETYPES.md §7, R08): the new-urbanist island townhouses. A row of four to six
-- crisp white townhouses of different heights, their fronts staggered so each casts a shadow on the next, each capped
-- with a sharp white coping, and every one with its own bold hit of colour, no two alike: a deep coloured picture-frame
-- window box standing out of the facade with the glass set back in it, a coloured balcony slab and upstand over a glass
-- wall, a coloured blade running past the roof, or a coloured upper facade with punched windows. Each has a garage door
-- below and a tall glass stair slot; roof stair houses carry thin canopies over roof terraces; on some copies the end
-- unit rises taller in blue-green mosaic tile, its front cut by deep loggias staggered floor over floor and its garage
-- set back in the tile. A concrete apron and planters.
--
-- What makes it itself: a row of white townhouses of different heights, each with one bold colour panel, and a
-- mosaic-clad end.
-- Placement, sizes, heights and its budget: Config/CityArchetypes/mosaic_townhouse_row.
-- Variants: palette (4: the order of the five colours and the four kinds of colour hit), crown (1 all white, canopies
-- on alternate houses, 2 the mosaic end unit, the tallest by four), rhythm (2 orders of heights and stagger), mirror
-- (the mosaic end left or right).
--
-- Previewing: from the street at eye height and at an angle down the row. Check the units read as separate houses
-- (their fronts 1.6 apart, their copings at different heights), the picture frames read as deep boxes with a shadow on
-- their glass, the colour hits read from a distance without looking like a toy, the mosaic reads as tile
-- (CeramicTiles) and its loggias as deep cuts, the canopies seem to hang from their stair houses. At night: the stair
-- slots, the framed glass and the loggias glow.

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
	coping = { tall = 0.5, proud = 0.3 },
	garage = { width = 8.4, tall = 8, from = 1 },
	slot = { width = 1.6, from = 1 }, -- from the unit's right edge
	frame = 1.8, -- a picture-frame box's depth out of the facade
	slab = 0.7, -- the white floor edges across a glass wall, out of the facade
	loggia = 2, -- the mosaic end's loggias, cut this deep
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
	-- third) falls past the part's edge. At a floor-tall tile (11) the spandrel is drawn several studs thick and soft,
	-- and read as a smudge across every window in the first preview.
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
	local panes: Kit.GlassOptions = { image = City.textures.windowFine, u = 2.4, lines = WHITE }

	local X0, X1 = -hw + SHAPE.side, hw - SHAPE.side
	local avail = X1 - X0
	local n = math.clamp(math.floor(avail / SHAPE.unit), SHAPE.units[1], SHAPE.units[2])
	local uw = avail / n
	local zF = -hd + share(D, SHAPE.yard)
	local zB = zF + share(D, SHAPE.depth)
	local cp = SHAPE.coping
	local g = SHAPE.garage

	for i = 1, n do
		local ux0, ux1 = X0 + (i - 1) * uw, X0 + i * uw
		local zi = zF + (if (i + variant.rhythm) % 2 == 0 then SHAPE.stagger else 0)
		local mosaic = mosaicEnd and i == n
		local h = if mosaic then H + SHAPE.mosaicRise else H - drops[i]
		local colour = if mosaic then WHITE else COLOURS[(i + p - 2) % #COLOURS + 1]
		local hit = HITS[(i + 2 * p - 3) % #HITS + 1]
		local paint = Kit.look(colour, Enum.Material.SmoothPlastic)
		local gx0 = ux0 + g.from
		local gx1 = gx0 + math.min(g.width, uw - 4.6)

		-- The coping: a crisp white cap round the unit's top, a shadow line under it.
		Kit.trim(
			m,
			`Coping{i}`,
			Vector3.new(ux0 - cp.proud, h - cp.tall, zi - cp.proud),
			Vector3.new(ux1 + cp.proud, h + 0.08, zB + cp.proud),
			white
		)

		if mosaic then
			-------------------------------------------------------------------------------------------------
			-- The mosaic end: the tile skin cut by the garage and two deep loggias, staggered floor over floor
			-------------------------------------------------------------------------------------------------
			local tile = Kit.look(MOSAIC, Enum.Material.CeramicTiles)
			local back = zi + SHAPE.loggia
			Kit.box(m, `Unit{i}`, Vector3.new(ux0, -KIT.bury, back), Vector3.new(ux1, h - cp.tall + 0.02, zB), tile)
			local lw = math.max(4, (uw - 3) * 0.62)
			Kit.skin(m, `Mosaic{i}`, "front", back, ux0, ux1, 0, h - cp.tall + 0.02, SHAPE.loggia, tile, {
				{ a0 = gx0, a1 = gx1, y0 = 0, y1 = g.tall, glass = false },
				{ a0 = ux1 - 1.5 - lw, a1 = ux1 - 1.5, y0 = F + 1.2, y1 = 2 * F - 0.6, lit = true },
				{ a0 = ux0 + 1.5, a1 = ux0 + 1.5 + lw, y0 = 2 * F + 1.2, y1 = 3 * F - 0.6, lit = true },
			}, { panes = panes })
			local door = Kit.trim(
				m,
				`Garage{i}`,
				Vector3.new(gx0, 0, back - 0.15),
				Vector3.new(gx1, g.tall, back + 0.1),
				Kit.look(GARAGE, Enum.Material.Metal)
			)
			door.textures = {
				{
					face = Enum.NormalId.Front,
					image = City.textures.slabLine,
					u = 8,
					v = 1.2,
					color = rgb(150, 154, 160),
				},
			}
		else
			-------------------------------------------------------------------------------------------------
			-- A white house: its garage door, its glass stair slot, its colour hit
			-------------------------------------------------------------------------------------------------
			Kit.box(m, `Unit{i}`, Vector3.new(ux0, -KIT.bury, zi), Vector3.new(ux1, h - cp.tall + 0.02, zB), white)
			local door = Kit.trim(
				m,
				`Garage{i}`,
				Vector3.new(gx0, 0, zi - 0.12),
				Vector3.new(gx1, g.tall, zi + 0.1),
				Kit.look(GARAGE, Enum.Material.Metal)
			)
			door.textures = {
				{
					face = Enum.NormalId.Front,
					image = City.textures.slabLine,
					u = 8,
					v = 1.2,
					color = rgb(150, 154, 160),
				},
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
						lit = i % 2 == 1,
					}
				)
			end

			local hx0, hx1 = ux0 + 0.8, sx1 - s.width - 0.6
			-- A white slab edge across a glass wall at each floor from `from` up, so three storeys of glass read as
			-- floors of a house (unbroken, they read as curtain wall in the first preview).
			local function slabs(name: string, a0: number, a1: number, from: number)
				for floor = from, 4 do
					local y = floor * F
					if y > F + 2 and y < h - 2.5 then
						Kit.trim(
							m,
							`{name}{floor}`,
							Vector3.new(a0, y - 0.3, zi - SHAPE.slab),
							Vector3.new(a1, y + 0.35, zi + 0.3),
							white
						)
					end
				end
			end
			if hit == "box" then
				-- A deep coloured picture frame standing out of the facade, the glass set back in it.
				local top = math.min(3 * F - 0.8, h - 1.5)
				Kit.skin(m, `Box{i}`, "front", zi, hx0, hx1, F + 0.8, top, SHAPE.frame, paint, {
					{ a0 = hx0 + 0.9, a1 = hx1 - 0.9, y0 = F + 1.7, y1 = top - 0.9, lit = true },
				}, { panes = panes })
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
				slabs(`Slab{i}_`, hx0 + 0.2, hx1, 3)
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
				slabs(`Slab{i}_`, hx0 + 0.2, ux1 - 3.2, 2)
			else
				-- The upper facade in colour, punched with windows, a floor a tile.
				Kit.punched(
					m,
					`Facade{i}`,
					Vector3.new(ux0 + 0.1, F, zi - 0.15),
					Vector3.new(hx1 + 0.3, h - cp.tall - 0.04, zi + 0.4),
					colour,
					glass,
					front,
					(hx1 + 0.2 - ux0) / 2,
					F,
					true
				)
			end
		end

		-- A roof stair house with a thin canopy over the roof terrace, on every other house and the mosaic end.
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
