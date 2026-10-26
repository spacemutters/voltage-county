--!strict
-- Shop fronts and café terraces at street level (Config/CityStreet frontage; Davis, 2026-10-26: "fill the streets:
-- cafés, parked cars, shop fronts..."). Dev/City/CityBuilder.build hands it each site it has built (CityBuilder.dress);
-- it reads the site's street front (Street/FrontageScan) and returns the pieces that dress it (Street/FrontageParts),
-- filed in the site's own models as scenery. Pure and deterministic: the same site gives the same pieces.
--
-- Which sites: those facing their road, of the archetypes whose ground floor can be a shop street (not frontage.skip),
-- in a district frontage.districts lists (the district of the zone a site stands in, so a beach type on River Avenue
-- takes the suburbs' look). A roll on the site's seed dresses about the district's `share` of them.
--
-- What a dressed site gets, all of it on its own forecourt between its front line and its wall, so every sidewalk keeps
-- its whole width and no road, crosswalk, pad, gameplay spot or house plot is touched:
--   shop fronts     on the runs of wall its ground floor shows the street (a bare opaque wall, or a glass lobby that
--                   reads as no shop yet), 12..22 studs wide each, the middle ones first, up to the district's count. On
--                   a bare wall a shop window that glows in its trade's colour at night (glass under a frame of
--                   mullions, a stall riser and a transom); over it an awning in the district's palette (sloped,
--                   striped or a flat canopy); a fascia board over the awning with an invented name in its trade's
--                   font; and, for a look with one, a tall blade standing out at the shop's end with the trade's word
--                   stacked down it, lit in neon at night. A planter stands in front of the pier between two shops.
--                   Neighbouring shops never share a look or a name: both are picked by where a shop stands along its
--                   road (frontage.lookStep), whichever site it is on
--   a café terrace  a tidy row of café sets (a table, chairs and an umbrella) on the forecourt where the street can see
--                   it (never behind a name wall: terrace.sight), or of bistro pairs under a roof or where
--                   an umbrella won't fit or the building already has umbrellas of its own (the beach hotels' terraces:
--                   added to, never doubled); one invisible box round the row that cars and players bump into; string
--                   lights on two posts swagging over the row, warm at night (NightLight); a planter at each end
-- Every piece is tried against every part already there, the building's and the pieces placed before it, and a piece
-- in the way is left out: a shop needs its awning, its fascia and its window (on glass, no window); a row needs two
-- tables.
-- Nothing new collides except the box round a row.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local City = require(ReplicatedStorage.Shared.Config.City)
local CityStreet = require(ReplicatedStorage.Shared.Config.CityStreet)
local FrontageParts = require(script.Parent.FrontageParts)
local FrontageScan = require(script.Parent.FrontageScan)
local Props = require(script.Parent.Parent.Props)
local Types = require(script.Parent.Parent.Types)

type PartSpec = Types.PartSpec
type Site = Types.Site
type Scan = FrontageScan.Scan
type Wall = FrontageScan.Wall
type Maker = FrontageParts.Maker
type FrontDistrict = CityStreet.FrontDistrict
type ShopLook = CityStreet.ShopLook
type ShopKind = CityStreet.ShopKind

local F = CityStreet.frontage
local SCAN = F.scan
local SHOP = F.shop
local TERRACE = F.terrace
local SALT = 7121 -- the frontage's own random stream off a site's seed

-- A shop slot on a run of wall: x0..x1, the run it is on and its place in it.
type Slot = { wall: Wall, run: number, index: number, x0: number, x1: number }

-- What one shop is: its look, trade and name.
export type Pick = { look: ShopLook, kind: ShopKind, kindName: string, name: string }

local Parts = FrontageParts
local Frontage = {}

-- The district whose street front a site takes: its zone's, else its archetype's.
function Frontage.district(site: Site): string
	return City.districts[site.zone] or site.district
end

-- Whether the frontage may dress a site at all (before its roll).
function Frontage.eligible(site: Site): boolean
	return site.face == "road" and not F.skip[site.archetype] and F.districts[Frontage.district(site)] ~= nil
end

-- What the shop standing at x (site frame) on a site is: its look, trade and name, picked by where it stands along its
-- road (in lookStep studs) and by its frontage (a number every site on one side of one road shares), so two shops side
-- by side differ whichever sites they are on.
function Frontage.pick(site: Site, x: number): Pick
	local d = F.districts[Frontage.district(site)]
	local at = site.frame * Vector3.new(x, 0, 0)
	local front = site.frame * Vector3.new(0, 0, -site.depth / 2)
	local k = math.floor(at:Dot(site.frame.RightVector) / F.lookStep)
	local salt = math.round(front:Dot(site.frame.LookVector))
	local look = d.looks[(k + salt) % #d.looks + 1]
	local kindName = d.kinds[(k * 3 + salt) % #d.kinds + 1]
	local kind = F.kinds[kindName]
	-- 7 and 3 share no factor with a trade's 4 or 5 names, so its shops along one road take turns at all of them.
	local name = kind.names[(k * 7 + salt * 3) % #kind.names + 1]
	return { look = look, kind = kind, kindName = kindName, name = name }
end

---------------------------------------------------------------------------------------------------------------
-- Shop fronts
---------------------------------------------------------------------------------------------------------------

-- The shop slots, 12..22 studs wide, the middle ones first: on every run of wall, within the stretches whose front is
-- clear from the floor to over a sign (shop.clear) and out as far as an awning reaches (so a colonnade's columns, a
-- planter or an entrance canopy splits a run into bays instead of ruling it out).
local function slots(scan: Scan): { Slot }
	local w = SHOP.width
	local out: { Slot } = {}
	local run = 0
	for _, wall in FrontageScan.walls(scan) do
		local y0, y1 = SCAN.floorTop, SCAN.floorTop + SHOP.clear
		local z0, z1 = wall.z - SHOP.awning.depth, wall.z - 0.05
		for _, span in FrontageScan.openings(scan, wall.x0, wall.x1, y0, y1, z0, z1) do
			local usable = span.Y - span.X - 2 * SHOP.margin
			if usable < w.min then
				continue
			end
			run += 1
			local n = math.max(1, math.round((usable + SHOP.gap) / (w.target + SHOP.gap)))
			local width = (usable - (n - 1) * SHOP.gap) / n
			while width > w.max do
				n += 1
				width = (usable - (n - 1) * SHOP.gap) / n
			end
			while n > 1 and width < w.min do
				n -= 1
				width = (usable - (n - 1) * SHOP.gap) / n
			end
			for i = 1, n do
				local x0 = span.X + SHOP.margin + (i - 1) * (width + SHOP.gap)
				table.insert(out, { wall = wall, run = run, index = i, x0 = x0, x1 = x0 + width })
			end
		end
	end
	table.sort(out, function(a: Slot, b: Slot): boolean
		local ca, cb = math.abs(a.x0 + a.x1), math.abs(b.x0 + b.x1)
		if math.abs(ca - cb) > 1e-6 then
			return ca < cb
		end
		return a.x0 < b.x0
	end)
	return out
end

-- Tries one shop on `slot` as the n-th; adds its pieces and returns true when it fits.
local function shop(m: Maker, slot: Slot, n: number): boolean
	local site = m.site
	local scan = m.scan
	local wall = slot.wall
	local z = wall.z
	local aw = SHOP.awning
	local depth = math.min(aw.depth, z - (-scan.hd + SCAN.front))
	if depth < aw.minDepth then
		return false
	end
	local floor = FrontageScan.floor(scan, slot.x0, slot.x1, z - depth, z)
	if wall.top < floor + SHOP.top then
		return false
	end
	-- Nothing may hang low over the awning: a porch roof or an entrance canopy is shelter enough.
	local airLo = Vector3.new(slot.x0, floor + aw.high, z - depth)
	local airHi = Vector3.new(slot.x1, floor + aw.air, z - 0.6)
	if not FrontageScan.free(scan, airLo, airHi) then
		return false
	end
	local pick = Frontage.pick(site, (slot.x0 + slot.x1) / 2)
	local look, kind = pick.look, pick.kind
	local tag = `Shop{n}`

	-- On a bare wall, the shop window first: without it the wall isn't a shop.
	local window: PartSpec? = nil
	if not wall.glass then
		local w = SHOP.window
		local glass = Parts.window(
			m,
			`{tag}Glass`,
			Vector3.new(slot.x0 + w.inset, floor + w.sill, z - w.proud),
			Vector3.new(slot.x1 - w.inset, floor + w.head, z + w.embed),
			look,
			kind
		)
		if not Parts.fits(m, glass, z) then
			return false
		end
		window = glass
	end

	-- The awning and the signs: the name on a fascia board over the awning, and when the look has a blade (and the wall
	-- rises past it) the trade's word on a blade at the shop's end, the awning and the board stopping short of it. When
	-- the blade is in the way, the fascia over a full-width awning.
	local b = SHOP.blade
	local options: { string } = { "fascia" }
	if look.sign == "blade" and #kind.word <= b.maxWord and wall.top >= floor + b.high then
		options = { "blade", "fascia" }
	end
	local chosen: { PartSpec }? = nil
	for _, option in options do
		local x1 = if option == "blade" then slot.x1 - b.room else slot.x1
		local pieces = {
			Parts.awning(m, `{tag}Awning`, slot.x0, x1, z, floor, depth, look),
			Parts.fascia(m, `{tag}Sign`, slot.x0, x1, z, floor, pick.name, look, kind),
		}
		if option == "blade" then
			table.insert(pieces, Parts.blade(m, `{tag}Blade`, slot.x1 - b.room / 2, z, floor, kind.word, look, kind))
		end
		local fit = true
		for _, piece in pieces do
			if not Parts.fits(m, piece, z) then
				fit = false
				break
			end
		end
		if fit then
			chosen = pieces
			break
		end
	end
	if chosen == nil then
		return false
	end
	if window then
		Parts.add(m, window)
	end
	for _, piece in chosen :: { PartSpec } do
		Parts.add(m, piece)
	end
	return true
end

-- A planter in front of the pier between two neighbouring shops on one wall.
local function pier(m: Maker, a: Slot, b: Slot, n: number, color: Color3)
	local p = SHOP.planter
	local x = (a.x1 + b.x0) / 2
	local z = a.wall.z - p.out - p.size.Z / 2
	local floor = FrontageScan.floor(m.scan, x - p.size.X / 2, x + p.size.X / 2, z - p.size.Z / 2, z + p.size.Z / 2)
	local box, plant = Parts.planter(m, `Pier{n}`, x, z, floor, p.size, p.plant, color)
	if Parts.fits(m, box) and Parts.fits(m, plant) then
		Parts.add(m, box)
		Parts.add(m, plant)
	end
end

-- Every shop a site gets, and the planters between them. Returns how many shops.
local function shops(m: Maker, d: FrontDistrict): number
	local placed: { Slot } = {}
	for _, slot in slots(m.scan) do
		if #placed >= d.shops then
			break
		end
		if shop(m, slot, #placed + 1) then
			table.insert(placed, slot)
		end
	end
	table.sort(placed, function(a: Slot, b: Slot): boolean
		return a.x0 < b.x0
	end)
	local piers = 0
	for i = 1, #placed - 1 do
		local a, b = placed[i], placed[i + 1]
		if a.run == b.run and b.index == a.index + 1 then
			piers += 1
			pier(m, a, b, piers, d.planter)
		end
	end
	return #placed
end

---------------------------------------------------------------------------------------------------------------
-- The café terrace
---------------------------------------------------------------------------------------------------------------

-- Whether the street sees a table of width `w` at x on a row whose front edge is at `zFront`: the band in front of it
-- (terrace.sight) is clear across at least `open` of its width.
local function seen(scan: Scan, x: number, w: number, zFront: number): boolean
	local s = TERRACE.sight
	local z0 = -scan.hd
	if zFront - z0 <= SCAN.front + SCAN.eps then
		return true
	end
	local open = 0
	for _, span in FrontageScan.openings(scan, x - w / 2, x + w / 2, s.low, s.high, z0, zFront - SCAN.eps) do
		open += span.Y - span.X
	end
	return open >= s.open * w - 1e-6
end

-- The row of `prop` (a Config/CityProps name) the forecourt holds best: the row line z (its centre) and the tables'
-- x, or nil. Rows are tried from the front line back; a table the street can't see (seen) doesn't count; the most
-- tables wins, then a row far enough back for its box (collider.front), then the frontmost.
local function bestRow(m: Maker, prop: string): (number?, { number })
	local scan = m.scan
	local size = Props.catalog[prop].size
	local w, h, depth = size.X, size.Y, size.Z
	local x0, x1 = -scan.hw + SCAN.side, scan.hw - SCAN.side
	local front = -scan.hd + SCAN.front
	local bestZ: number? = nil
	local bestXs: { number } = {}
	local bestScore = -1
	local z = front + depth / 2
	while z + depth / 2 <= -scan.hd + TERRACE.depth + 1e-6 do
		local xs: { number } = {}
		for _, span in FrontageScan.openings(scan, x0, x1, 0, SCAN.floorTop + h, z - depth / 2, z + depth / 2) do
			local long = span.Y - span.X
			local count = math.floor((long + TERRACE.gap) / (w + TERRACE.gap) + 1e-6)
			if count >= 1 then
				local used = count * w + (count - 1) * TERRACE.gap
				local first = span.X + (long - used) / 2 + w / 2
				for i = 0, count - 1 do
					local x = first + i * (w + TERRACE.gap)
					if seen(scan, x, w, z - depth / 2) then
						table.insert(xs, x)
					end
				end
			end
		end
		if #xs >= TERRACE.count.min then
			local boxed = z - depth / 2 >= -scan.hd + TERRACE.collider.front
			local score = math.min(#xs, TERRACE.count.max) * 2 + (if boxed then 1 else 0)
			if score > bestScore then
				bestScore, bestZ, bestXs = score, z, xs
			end
		end
		z += TERRACE.step
	end
	if bestZ == nil then
		return nil, {}
	end
	-- At most count.max neighbouring tables, the run of them nearest the site's middle.
	table.sort(bestXs)
	local count = math.min(#bestXs, TERRACE.count.max)
	local start, off = 1, math.huge
	for s = 1, #bestXs - count + 1 do
		local mid = math.abs(bestXs[s] + bestXs[s + count - 1])
		if mid < off - 1e-6 then
			start, off = s, mid
		end
	end
	return bestZ, table.move(bestXs, start, start + count - 1, 1, {})
end

-- String lights over a row: a post past each end and two strings swagging from the posts' tops to a low point over
-- the row's middle. All or nothing.
local function lights(m: Maker, z: number, first: number, last: number, floor: number, w: number, h: number)
	local l = TERRACE.lights
	local xa, xb = first - w / 2 - l.out, last + w / 2 + l.out
	local top = floor + l.top
	local low = math.max(top - l.sag, floor + h + l.over) -- the swag's low point, clear of the tables
	if low >= top - 0.25 then
		return
	end
	local a = Vector3.new(xa, top - 0.15, z)
	local b = Vector3.new(xb, top - 0.15, z)
	local mid = Vector3.new((xa + xb) / 2, low, z)
	local pieces = {
		Parts.post(m, "Post1", xa, z, floor, l.top),
		Parts.post(m, "Post2", xb, z, floor, l.top),
		Parts.string(m, "String1", a, mid),
		Parts.string(m, "String2", mid, b),
	}
	-- The swag casts warm light on the tables at night (the street-level roast, 2026-10-26, point 9: terraces vanished
	-- in the dark): one point light, on the first string, switched with it (Services/DayNightService).
	local glow = l.glow
	pieces[3].light = {
		kind = "point",
		brightness = glow.brightness,
		range = glow.range,
		angle = 0,
		color = glow.color,
		face = Enum.NormalId.Top,
		enabled = false,
	}
	for _, piece in pieces do
		if not Parts.fits(m, piece) then
			return
		end
	end
	for _, piece in pieces do
		Parts.add(m, piece)
	end
end

-- The café terrace (see the header). Returns how many tables it set out.
local function terrace(m: Maker, d: FrontDistrict, specs: { PartSpec }): number
	local scan = m.scan
	-- A building with umbrellas of its own has its café: only bistro pairs are added, under no new umbrella.
	local umbrellas = false
	for _, spec in specs do
		if string.find(spec.name, "Umbrella", 1, true) then
			umbrellas = true
			break
		end
	end
	local choices: { string } = { TERRACE.bistro }
	if not umbrellas then
		local cafe = d.cafes[(m.site.seed // 7) % #d.cafes + 1]
		choices = { cafe, TERRACE.bistro }
	end
	for _, prop in choices do
		local z, xs = bestRow(m, prop)
		if z == nil then
			continue
		end
		local rowZ = z :: number
		local size = Props.catalog[prop].size
		local w, h, depth = size.X, size.Y, size.Z
		-- Each table on its own floor (a terrace's slab may run under some of them), each checked once more.
		local tables: { { x: number, floor: number } } = {}
		local rowFloor = SCAN.ground
		for _, x in xs do
			local floor = FrontageScan.floor(scan, x - w / 2, x + w / 2, rowZ - depth / 2, rowZ + depth / 2)
			local lo = Vector3.new(x - w / 2, floor + TERRACE.collider.lift, rowZ - depth / 2)
			local hi = Vector3.new(x + w / 2, floor + h, rowZ + depth / 2)
			if FrontageScan.inside(scan, lo, hi, m.site.maxHeight) and FrontageScan.free(scan, lo, hi) then
				table.insert(tables, { x = x, floor = floor })
				rowFloor = math.max(rowFloor, floor)
			end
		end
		if #tables < TERRACE.count.min then
			continue
		end
		-- Under a colonnade's roof or an overhang an umbrella is pointless: café sets there give way to bistro pairs.
		if prop ~= TERRACE.bistro then
			local covered = 0
			for _, t in tables do
				local lo = Vector3.new(t.x - w / 2, t.floor + h, rowZ - depth / 2)
				local hi = Vector3.new(t.x + w / 2, m.site.maxHeight, rowZ + depth / 2)
				if not FrontageScan.free(scan, lo, hi) then
					covered += 1
				end
			end
			if covered * 2 > #tables then
				continue
			end
		end
		local first, last = tables[1].x, tables[#tables].x
		-- The box round the row, when nothing stands between the tables and it is far enough back.
		local c = TERRACE.collider
		local box: PartSpec? = nil
		if rowZ - depth / 2 >= -scan.hd + c.front - 1e-6 then
			local candidate = Parts.collider(
				m,
				"Tables",
				Vector3.new(first - w / 2, rowFloor + c.lift, rowZ - depth / 2),
				Vector3.new(last + w / 2, rowFloor + c.top, rowZ + depth / 2)
			)
			if Parts.fits(m, candidate) then
				box = candidate
			end
		end
		for i, t in tables do
			Parts.add(m, Parts.prop(m, `Table{i}`, prop, t.x, rowZ, t.floor))
		end
		if box then
			Parts.add(m, box)
		end
		lights(m, rowZ, first, last, rowFloor, w, h)
		-- A planter at each end, past the posts.
		local p = TERRACE.planter
		local reach = w / 2 + TERRACE.lights.out + TERRACE.lights.post / 2 + p.gap + p.size.X / 2
		for k, x in { first - reach, last + reach } do
			local floor =
				FrontageScan.floor(scan, x - p.size.X / 2, x + p.size.X / 2, rowZ - p.size.Z / 2, rowZ + p.size.Z / 2)
			local pot, plant = Parts.planter(m, `End{k}`, x, rowZ, floor, p.size, p.plant, d.planter)
			if Parts.fits(m, pot) and Parts.fits(m, plant) then
				Parts.add(m, pot)
				Parts.add(m, plant)
			end
		end
		return #tables
	end
	return 0
end

---------------------------------------------------------------------------------------------------------------
-- A site
---------------------------------------------------------------------------------------------------------------

-- What dressing one site added: its shops and tables, and the pieces (night lights among them).
export type Report = { shops: number, tables: number, pieces: number, lights: number }

-- The pieces that dress `site` (built and filed as `specs`, which it reads and never changes), filed in the site's own
-- models. `force` skips the site's roll (previews and specs); an ineligible site gets nothing either way.
function Frontage.dress(site: Site, specs: { PartSpec }, force: boolean?): ({ PartSpec }, Report)
	local report: Report = { shops = 0, tables = 0, pieces = 0, lights = 0 }
	if not Frontage.eligible(site) then
		return {}, report
	end
	local d = F.districts[Frontage.district(site)]
	local rng = Random.new((site.seed + SALT) % 2147483647)
	local dressed = rng:NextNumber() < d.share
	local cafe = rng:NextNumber() < d.terraces
	if not dressed and not force then
		return {}, report
	end
	local m = Parts.new(site, FrontageScan.new(site, specs))
	report.shops = shops(m, d)
	if cafe or force then
		report.tables = terrace(m, d, specs)
	end
	report.pieces = #m.out
	for _, piece in m.out do
		if piece.tag ~= nil then
			report.lights += 1
		end
	end
	return m.out, report
end

return Frontage
