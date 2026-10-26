--!strict
-- The city builder (docs/city/CITY_PLAN.md §2, §4, §5 and §8; docs/city/ARCHETYPE_GUIDE.md). Pure: plots in, sites and
-- part specs out. Dev/MapBuilder's plot pass (addBuildings) hands it every built plot in order, and an Env with the
-- clear checks core claims need; it decides which archetype stands where, builds each site with its archetype module,
-- checks it and files its parts. A plot no archetype fits keeps the old facade (Dev/MapBuilder addBuilding).
--
-- Placement (place) works on runs: neighbouring plots of one frontage, in one zone, with no gap. Three passes:
--   1. one-offs (Config/City landmarks), in order: each takes the window of free plots near its anchor that its
--      archetype fits, nearest the anchor and closest to the width and depth it asks for, with a core claim behind its
--      plots when it wants more depth than a plot. A one-off whose archetype isn't written yet is listed in `missing`,
--      one that finds no site in `unplaced` (tests/MapBuilder.spec fails on those). Only with an Env (the county)
--   2. towers: every downtown block holds one repeatable band-T tower (slots.T; a one-off that tall takes the slot),
--      and an area with `towers` that many: each on the window nearest a skyline peak (towers.peaks) whose cap reaches
--      band T, its depth claimed back into the block's empty core when there is room (towers.claimDepth)
--   3. the rest, run by run: each plot's own random stream draws among the archetypes its area mixes in (Config/City
--      areas; its own district's at weight 1 without one) that fit the free plots from it on, taking the widest fit
--      most of the time (rules.wideShare) so the city is fewer, bigger buildings
-- On every pass: a repeatable's cap is its block's (heightCaps), its area's, nearSpotCap beside a gameplay spot, band
-- H below the T slot once it is taken (and band M once a downtown block's two H slots are), and stepDown of its run's
-- tower. Neighbours (footprints within rules.neighbourGap: beside it, across the street, round the corner) never share
-- an archetype; only as a last resort may one stand across the street from itself, a palette apart and acrossHeight
-- taller or lower. An archetype stands at most perBlock times in a block (and rules.perBlock), maxCopies in the map and
-- minSpacing from its other copies; every copy draws a look (palette, crown, rhythm) no other copy has while one is
-- left; corner archetypes stand on block corners (cornerArchetypes), mirrored so the corner is at their drawn +x end.
-- Then no two towers (band T and up) within rules.twinRange stand within twinGap of one height (later ones move, inside
-- their own range), and the tallest get places in the Skyline model. Deterministic: the same plots give the same city.
--
-- Building (build): the archetype writes its parts through Dev/City/Kit; check() holds them to the site (inside the
-- footprint, between y = -kit.bury and maxHeight, within budget, fit to build, named and filed as its); file() moves
-- its night lights, signs and lights into its lights model (SLIM breaks on parts that change at runtime) and, for a
-- skyline site, its biggest masses and crown light into the Persistent Skyline model.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local City = require(ReplicatedStorage.Shared.Config.City)
local Environment = require(ReplicatedStorage.Shared.Config.Environment)
local Index = require(script.Parent.Archetypes.Index)
local Kit = require(script.Parent.Kit)
local Types = require(script.Parent.Types)

type PartSpec = Types.PartSpec
type Variant = Types.Variant
type Config = City.ArchetypeConfig
type Area = City.AreaConfig
export type Plot = Types.Plot
export type Site = Types.Site
export type Env = Types.Env

export type Placement = {
	sites: { Site }, -- in the order of their first plots
	legacy: { Plot }, -- plots no archetype fits: the old look builds them
	unplaced: { string }, -- one-offs whose archetype exists but that found no site near their anchor
	missing: { string }, -- one-offs (and configs) whose archetype module or Config/City entry isn't ready yet
}

-- A plan rectangle: its centre, the way its length runs, half its length and half its depth.
type Box = { c: Vector2, u: Vector2, ha: number, hc: number }

-- One frontage's run of neighbouring plots in one zone.
type Run = { plots: { Plot }, index: number, district: string?, block: number }

-- A window of a run's free plots, plots[i..j].
type Window = { run: Run, i: number, j: number, width: number, depth: number, cap: number, score: number }

-- One archetype that may stand on a window: its weight, the window's end, width, depth and the height range open.
type Option = { id: string, weight: number, j: number, width: number, depth: number, low: number, top: number }

-- What placement keeps about each site while it plans.
type Info = { box: Box, low: number, top: number, config: Config }

type State = {
	seed: number,
	env: Env?,
	ids: { string }, -- every archetype placement may draw, sorted
	sites: { Site },
	info: { [Site]: Info },
	used: { [number]: boolean }, -- plot index -> taken by a site or the old look
	copies: { [string]: { Vector2 } },
	perBlock: { [string]: number },
	looks: { [string]: boolean },
	slotsT: { [string]: number }, -- towers per slot group (a downtown block "b<n>" or an area "a<id>")
	slotsH: { [string]: number },
	runTower: { [number]: number }, -- run index -> the height of the tower standing on it
	oneOff: { [string]: boolean }, -- archetypes only the one-off pass places (a landmark with maxCopies 1)
	caps: { [number]: number }, -- plot index -> its cap (block, area and gameplay spot)
}

local CityBuilder = {}

local TOLERANCE = 0.01 -- studs a part may reach past its site's footprint (rounding)
local EPS = 1e-6
local NIGHT_TAG = Environment.nightLights.tag
local BANDS = City.bands
local RULES = City.rules

-- Integer seed mixing for deterministic per-thing random streams (the same mix as Dev/MapBuilder's).
local function mixSeed(seed: number, a: number, b: number): number
	local modulus = 2147483647
	local h = math.floor(seed) % modulus
	h = (h * 16807 + math.floor(a) * 7919 + 13) % modulus
	h = (h * 16807 + math.floor(b) * 104729 + 17) % modulus
	return h
end
CityBuilder.mixSeed = mixSeed

-- A config placement can use: every number it reads is there (half-written modules are left out, not fatal).
local function complete(config: any): boolean
	if type(config) ~= "table" or type(config.district) ~= "string" or type(config.heights) ~= "table" then
		return false
	end
	for _, key in
		{
			"weight",
			"maxCopies",
			"perBlock",
			"minSpacing",
			"minWidth",
			"maxWidth",
			"minDepth",
			"maxPlots",
			"crownMax",
			"budget",
			"palettes",
			"crowns",
			"rhythms",
		}
	do
		if type(config[key]) ~= "number" then
			return false
		end
	end
	return type(config.heights.min) == "number"
		and type(config.heights.max) == "number"
		and config.heights.min <= config.heights.max
		and config.palettes >= 1
		and config.crowns >= 1
		and config.rhythms >= 1
end

-- Archetype ids placement may draw, in a fixed order, so every plan draws the same way.
local function sortedIds(): { string }
	local ids: { string } = {}
	for id, config in City.archetypes do
		if complete(config) and Index.byId[id] ~= nil and not City.notOnPlots[id] then
			table.insert(ids, id)
		end
	end
	table.sort(ids)
	return ids
end

-- The band a height falls in (Config/City bands).
function CityBuilder.bandOf(height: number): string
	if height >= BANDS.S then
		return "S"
	elseif height >= BANDS.T then
		return "T"
	elseif height >= BANDS.H then
		return "H"
	elseif height >= BANDS.M then
		return "M"
	end
	return "L"
end

-- The area (Config/City areas) holding plan point `at` in zone `zone`, or nil.
function CityBuilder.area(zone: string, at: Vector2): Area?
	for _, area in City.areas do
		if
			area.zone == zone
			and at.X >= area.min.X
			and at.X <= area.max.X
			and at.Y >= area.min.Y
			and at.Y <= area.max.Y
		then
			return area
		end
	end
	return nil
end

-- The share of plots the plot pass builds at `at` in zone `zone`: its area's density, else the zone's `base`
-- (decision L2: the north shore road's land side at 0.95, its beach side open). The roll is drawn either way, so no
-- plot moves.
function CityBuilder.density(zone: string, base: number, at: Vector2): number
	local area = CityBuilder.area(zone, at)
	if area and area.density ~= nil then
		return area.density :: number
	end
	return base
end

-- Plots in runs: neighbours of one frontage, in one zone, with no gap between them, in the order the plot pass made
-- them.
function CityBuilder.runs(plots: { Plot }): { { Plot } }
	local runs: { { Plot } } = {}
	local current: { Plot }? = nil
	local last: Plot? = nil
	for _, plot in plots do
		local joined = last ~= nil
			and current ~= nil
			and last.frontage == plot.frontage
			and last.zone == plot.zone
			and math.abs(last.along + last.width - plot.along) < 1e-3
		if joined and current then
			table.insert(current, plot)
		else
			current = { plot }
			table.insert(runs, current :: { Plot })
		end
		last = plot
	end
	return runs
end

-- The site plots run[i..j] make, `depth` deep (default a plot's): its frame, width and depth (the gap between
-- neighbours kept at both ends). `back` turns its front away from the road.
function CityBuilder.footprint(
	run: { Plot },
	i: number,
	j: number,
	depth: number?,
	back: boolean?
): (CFrame, number, number)
	local first, last = run[i], run[j]
	local half = City.siteGap / 2
	local from = first.along + half
	local to = last.along + last.width - half
	local d = depth or first.plotDepth
	local center = first.frontStart + first.u * ((from + to) / 2 - first.along) + first.away * (d / 2)
	local at = Vector3.new(center.X, 0, center.Y)
	local frame = CFrame.lookAt(at, at - Vector3.new(first.away.X, 0, first.away.Y))
	if back then
		frame *= CFrame.Angles(0, math.pi, 0)
	end
	return frame, to - from, d
end

-- The width of the site run[i..j] makes (footprint's, without the frame).
local function spanWidth(plots: { Plot }, i: number, j: number): number
	return plots[j].along + plots[j].width - plots[i].along - City.siteGap
end

-- The middle of run[i..j]'s plot band (plan).
local function windowCentre(run: Run, i: number, j: number): Vector2
	local first, last = run.plots[i], run.plots[j]
	local middle = (first.along + last.along + last.width) / 2
	return first.frontStart + first.u * (middle - first.along) + first.away * (first.plotDepth / 2)
end

local function plotCentre(p: Plot): Vector2
	return p.frontStart + p.u * (p.width / 2) + p.away * (p.plotDepth / 2)
end

-- The most a site in `district` centred at `at` (plan x, z) may rise (Config/City heightCaps), or math.huge.
function CityBuilder.heightCap(district: string, at: Vector2): number
	local caps = City.heightCaps[district]
	if caps == nil then
		return math.huge
	end
	local cells = #caps.grid
	local col = math.floor((at.X - caps.origin.X) / caps.cell) + 1
	local row = math.floor((at.Y - caps.origin.Y) / caps.cell) + 1
	if row < 1 then
		return caps.north
	elseif row > cells then
		return caps.south
	elseif col < 1 then
		return caps.west
	elseif col > #caps.grid[row] then
		return caps.east
	end
	return caps.grid[row][col]
end

-- Inside a district's block grid (downtown)?
local function inGrid(district: string, at: Vector2): boolean
	local caps = City.heightCaps[district]
	if caps == nil then
		return false
	end
	local rows, cols = #caps.grid, #caps.grid[1]
	return at.X >= caps.origin.X
		and at.X < caps.origin.X + cols * caps.cell
		and at.Y >= caps.origin.Y
		and at.Y < caps.origin.Y + rows * caps.cell
end

-- A plot's own cap: its block's, its area's and, beside a gameplay spot, nearSpotCap.
local function plotCap(s: State, p: Plot, district: string): number
	local cached = s.caps[p.index]
	if cached then
		return cached
	end
	local c = plotCentre(p)
	local cap = CityBuilder.heightCap(district, c)
	local area = CityBuilder.area(p.zone, c)
	if area and area.cap ~= nil then
		cap = math.min(cap, area.cap :: number)
	end
	if p.nearSpot then
		cap = math.min(cap, City.nearSpotCap)
	end
	s.caps[p.index] = cap
	return cap
end

-- The tower slot group a plot belongs to and how many repeatable towers it holds: its downtown block, or its area.
local function slotGroup(p: Plot, district: string): (string?, number)
	local c = plotCentre(p)
	if inGrid(district, c) then
		return `b{p.block}`, City.slots.T
	end
	local area = CityBuilder.area(p.zone, c)
	if area and area.towers ~= nil and (area.towers :: number) > 0 then
		return `a{area.id}`, area.towers :: number
	end
	return nil, 0
end

-- The most a repeatable on run[i..j] may rise: its plots' caps, the slots its group has left, its run's tower.
local function windowCap(s: State, run: Run, i: number, j: number, district: string): number
	local cap = math.huge
	for k = i, j do
		cap = math.min(cap, plotCap(s, run.plots[k], district))
	end
	local group, slots = slotGroup(run.plots[i], district)
	if group then
		if (s.slotsT[group] or 0) >= slots then
			cap = math.min(cap, BANDS.T - 1)
		end
		if string.sub(group, 1, 1) == "b" and (s.slotsH[group] or 0) >= City.slots.H then
			cap = math.min(cap, BANDS.H - 1)
		end
	end
	local tower = s.runTower[run.index]
	if tower then
		cap = math.min(cap, tower * RULES.stepDown)
	end
	return cap
end

---------------------------------------------------------------------------------------------------------------
-- Neighbours: plan rectangles and the gap between two of them
---------------------------------------------------------------------------------------------------------------

local function boxOf(frame: CFrame, width: number, depth: number): Box
	local r = frame.RightVector
	return { c = Vector2.new(frame.X, frame.Z), u = Vector2.new(r.X, r.Z).Unit, ha = width / 2, hc = depth / 2 }
end

local function corners(b: Box): { Vector2 }
	local along, across = b.u * b.ha, Vector2.new(-b.u.Y, b.u.X) * b.hc
	return { b.c + along + across, b.c - along + across, b.c - along - across, b.c + along - across }
end

-- Whether two convex quads overlap (separating axes: their edge normals).
local function overlapping(ca: { Vector2 }, cb: { Vector2 }, a: Box, b: Box): boolean
	for _, axis in { a.u, Vector2.new(-a.u.Y, a.u.X), b.u, Vector2.new(-b.u.Y, b.u.X) } do
		local minA, maxA, minB, maxB = math.huge, -math.huge, math.huge, -math.huge
		for _, p in ca do
			local d = p:Dot(axis)
			minA, maxA = math.min(minA, d), math.max(maxA, d)
		end
		for _, p in cb do
			local d = p:Dot(axis)
			minB, maxB = math.min(minB, d), math.max(maxB, d)
		end
		if maxA <= minB or maxB <= minA then
			return false
		end
	end
	return true
end

local function toSegment(p: Vector2, a: Vector2, b: Vector2): number
	local ab = b - a
	local t = math.clamp((p - a):Dot(ab) / math.max(ab:Dot(ab), EPS), 0, 1)
	return (a + ab * t - p).Magnitude
end

-- The gap between two plan rectangles (0 when they touch or overlap). Far apart, a cheap lower bound.
local function gap(a: Box, b: Box): number
	local reach = math.sqrt(a.ha * a.ha + a.hc * a.hc) + math.sqrt(b.ha * b.ha + b.hc * b.hc)
	local apart = (a.c - b.c).Magnitude - reach
	if apart > 0 then
		return apart
	end
	local ca, cb = corners(a), corners(b)
	if overlapping(ca, cb, a, b) then
		return 0
	end
	local best = math.huge
	for k = 1, 4 do
		local a0, a1 = ca[k], ca[k % 4 + 1]
		local b0, b1 = cb[k], cb[k % 4 + 1]
		for n = 1, 4 do
			best = math.min(best, toSegment(cb[n], a0, a1), toSegment(ca[n], b0, b1))
		end
	end
	return best
end

-- The gap between two sites' footprints (tests/MapBuilder.spec checks neighbours with it).
function CityBuilder.gapBetween(a: Site, b: Site): number
	return gap(boxOf(a.frame, a.width, a.depth), boxOf(b.frame, b.width, b.depth))
end

-- The archetypes near `box` (within rules.neighbourGap): same[id] when a copy stands in `block` (beside it or round
-- the corner), across[id] the copies standing in other blocks (across the street).
local function neighbours(s: State, box: Box, block: number): ({ [string]: boolean }, { [string]: { Site } })
	local same: { [string]: boolean } = {}
	local across: { [string]: { Site } } = {}
	for _, site in s.sites do
		if gap(box, s.info[site].box) <= RULES.neighbourGap then
			if site.block == block then
				same[site.archetype] = true
			else
				local list = across[site.archetype] or {}
				table.insert(list, site)
				across[site.archetype] = list
			end
		end
	end
	return same, across
end

---------------------------------------------------------------------------------------------------------------
-- Rules shared by the passes
---------------------------------------------------------------------------------------------------------------

local function cornerKind(id: string, config: Config): ("only" | "prefer")?
	return config.corner or City.cornerArchetypes[id]
end

-- Its weight on a plot of `district` in `area`: the area's mix by id, then by the archetype's district.
local function weightOf(id: string, config: Config, district: string, area: Area?): number
	local mix: number? = nil
	if area then
		mix = area.mix[id] or area.mix[config.district]
	elseif config.district == district then
		mix = 1
	end
	return (mix or 0) * config.weight
end

-- Too many copies, or a copy closer than minSpacing to `at`.
local function crowded(s: State, id: string, config: Config, at: Vector2): boolean
	local placed = s.copies[id]
	if placed == nil then
		return false
	end
	if #placed >= config.maxCopies then
		return true
	end
	for _, other in placed do
		if (other - at).Magnitude < config.minSpacing then
			return true
		end
	end
	return false
end

local function blockFull(s: State, id: string, config: Config, block: number): boolean
	return (s.perBlock[`{id}:{block}`] or 0) >= math.min(config.perBlock, RULES.perBlock)
end

-- The claim behind run[i..j] for a site `depth` deep: its centre, the road's way, half its length and depth.
local function claimRect(run: Run, i: number, j: number, depth: number): (Vector2, Vector2, number, number)
	local first, last = run.plots[i], run.plots[j]
	local half = City.siteGap / 2
	local from, to = first.along + half, last.along + last.width - half
	local extra = depth - first.plotDepth
	local c = first.frontStart + first.u * ((from + to) / 2 - first.along) + first.away * (first.plotDepth + extra / 2)
	return c, first.u, (to - from) / 2, extra / 2
end

-- The deepest site from `want` down to `need` (claims.step at a time) that run[i..j] can take: a plot's depth needs
-- no claim; deeper needs a clear claim (and an Env). Nil when not even `need` fits.
local function deepest(s: State, run: Run, i: number, j: number, need: number, want: number): number?
	local plot = run.plots[i].plotDepth
	local depths: { number } = {}
	local d = math.max(want, need)
	while d > need + EPS do
		table.insert(depths, d)
		d -= City.claims.step
	end
	table.insert(depths, need)
	for _, depth in depths do
		if depth <= plot + EPS then
			return plot
		end
		local env = s.env
		if env then
			local c, u, ha, hc = claimRect(run, i, j, depth)
			if env.clear(c, u, ha, hc, run.plots[i].frontage) then
				return depth
			end
		end
	end
	return nil
end

-- A look (palette, crown, rhythm) from `rng`, walked on to one no copy has while one is left (taken by makeSite).
local function drawVariant(s: State, id: string, config: Config, rng: Random): Variant
	local variant: Variant = {
		palette = rng:NextInteger(1, config.palettes),
		crown = rng:NextInteger(1, config.crowns),
		rhythm = rng:NextInteger(1, config.rhythms),
		mirror = rng:NextNumber() < 0.5,
	}
	for _ = 1, config.palettes * config.crowns * config.rhythms do
		if not s.looks[`{id}:{variant.palette}:{variant.crown}:{variant.rhythm}`] then
			break
		end
		variant.palette = variant.palette % config.palettes + 1
		if variant.palette == 1 then
			variant.crown = variant.crown % config.crowns + 1
			if variant.crown == 1 then
				variant.rhythm = variant.rhythm % config.rhythms + 1
			end
		end
	end
	return variant
end

type Spot = {
	run: Run,
	i: number,
	j: number,
	id: string,
	config: Config,
	depth: number,
	height: number,
	low: number,
	top: number,
	back: boolean,
	landmark: boolean,
	variant: Variant,
	district: string,
}

-- Puts a site on its plots (and takes its claim) and books it against every limit.
local function makeSite(s: State, spot: Spot): Site
	local run, i, j, config = spot.run, spot.i, spot.j, spot.config
	local first = run.plots[i]
	local frame, width, depth = CityBuilder.footprint(run.plots, i, j, spot.depth, spot.back)
	local claim = math.max(0, depth - first.plotDepth)
	local env = s.env
	if claim > EPS and env then
		local c, u, ha, hc = claimRect(run, i, j, depth)
		env.claim(c, u, ha, hc, `B{first.index}`)
	end

	-- Corners, as the archetype draws them: drawn +x is the frame's +x, or its -x when mirrored. A corner archetype is
	-- mirrored so its one corner is at drawn +x.
	local variant = spot.variant
	local startCorner, endCorner = first.cornerStart == true, run.plots[j].cornerEnd == true
	local r = frame.RightVector
	local plusIsEnd = Vector2.new(r.X, r.Z):Dot(first.u) > 0
	local plusCorner = if plusIsEnd then endCorner else startCorner
	local minusCorner = if plusIsEnd then startCorner else endCorner
	if cornerKind(spot.id, config) and plusCorner ~= minusCorner then
		variant.mirror = minusCorner
	end
	local corner = if variant.mirror
		then { left = plusCorner, right = minusCorner }
		else { left = minusCorner, right = plusCorner }
	s.looks[`{spot.id}:{variant.palette}:{variant.crown}:{variant.rhythm}`] = true

	local height = spot.height
	local name = if config.ownModel or height >= City.towerModelFrom then `Tower{first.index}` else `Site{first.index}`
	local plotIds: { number } = {}
	for k = i, j do
		table.insert(plotIds, run.plots[k].index)
		s.used[run.plots[k].index] = true
	end
	local site: Site = {
		id = `B{first.index}`,
		archetype = spot.id,
		district = spot.district,
		zone = first.zone,
		frame = frame,
		width = width,
		depth = depth,
		height = height,
		maxHeight = height + config.crownMax,
		seed = mixSeed(s.seed, first.index, first.shade),
		variant = variant,
		folder = `Buildings/{name}`,
		lightsFolder = `BuildingLights/{name}`,
		plots = plotIds,
		block = first.block,
		band = CityBuilder.bandOf(height),
		face = if spot.back then "back" else "road",
		claim = claim,
		corner = corner,
		landmark = spot.landmark,
		skyline = false,
	}
	table.insert(s.sites, site)
	s.info[site] = { box = boxOf(frame, width, depth), low = spot.low, top = spot.top, config = config }

	local at = Vector2.new(frame.X, frame.Z)
	local placed = s.copies[spot.id] or {}
	table.insert(placed, at)
	s.copies[spot.id] = placed
	local key = `{spot.id}:{first.block}`
	s.perBlock[key] = (s.perBlock[key] or 0) + 1
	local group = slotGroup(first, run.district or spot.district)
	if group then
		if height >= BANDS.T then
			s.slotsT[group] = (s.slotsT[group] or 0) + 1
		elseif height >= BANDS.H and not spot.landmark then
			s.slotsH[group] = (s.slotsH[group] or 0) + 1
		end
	end
	if height >= BANDS.T then
		s.runTower[run.index] = math.max(s.runTower[run.index] or 0, height)
	end
	return site
end

-- Whether placement may draw `id` on plots in passes 2 and 3.
local function drawable(s: State, id: string): boolean
	return not s.oneOff[id]
end

---------------------------------------------------------------------------------------------------------------
-- Pass 1: the one-offs
---------------------------------------------------------------------------------------------------------------

local function placeLandmarks(s: State, runs: { Run }, unplaced: { string }, missing: { string })
	for _, entry in City.landmarks do
		local config = City.archetypes[entry.id]
		if not complete(config) or Index.byId[entry.id] == nil then
			table.insert(missing, entry.id)
			continue
		end
		if City.notOnPlots[entry.id] then
			continue
		end
		local placed = s.copies[entry.id]
		if placed and #placed >= config.maxCopies then
			continue
		end
		local radius = entry.radius or City.landmarkRadius
		local wantWidth = math.min(entry.width or config.maxWidth, config.maxWidth)
		local wantDepth = math.max(entry.depth or config.minDepth, config.minDepth)
		local best: Window? = nil
		for _, run in runs do
			local plots = run.plots
			-- A run's plots lie within a few hundred studs of its first one.
			if run.district == nil or (plotCentre(plots[1]) - entry.at).Magnitude > radius + 800 then
				continue
			end
			for i = 1, #plots do
				if s.used[plots[i].index] then
					continue
				end
				for j = i, math.min(#plots, i + config.maxPlots - 1) do
					if s.used[plots[j].index] then
						break
					end
					local width = spanWidth(plots, i, j)
					if width > config.maxWidth + EPS then
						break
					end
					if width < config.minWidth - EPS then
						continue
					end
					local dist = (windowCentre(run, i, j) - entry.at).Magnitude
					if dist > radius then
						continue
					end
					if entry.corner and not (plots[i].cornerStart or plots[j].cornerEnd) then
						continue
					end
					local base = dist + 0.5 * math.max(0, wantWidth - width)
					if best and base >= best.score - EPS then
						continue
					end
					local depth = deepest(s, run, i, j, config.minDepth, wantDepth)
					if depth then
						local score = base + 0.5 * math.max(0, wantDepth - depth)
						if best == nil or score < best.score - EPS then
							best = {
								run = run,
								i = i,
								j = j,
								width = width,
								depth = depth,
								cap = math.huge,
								score = score,
							}
						end
					end
				end
			end
		end
		local chosen = best
		if chosen == nil then
			table.insert(unplaced, entry.id)
			continue
		end
		local first = chosen.run.plots[chosen.i]
		local rng = Random.new(mixSeed(s.seed, first.shade, first.index))
		makeSite(s, {
			run = chosen.run,
			i = chosen.i,
			j = chosen.j,
			id = entry.id,
			config = config,
			depth = chosen.depth,
			height = math.clamp(entry.height or config.heights.max, config.heights.min, config.heights.max),
			low = config.heights.min,
			top = config.heights.max,
			back = entry.face == "back",
			landmark = true,
			variant = drawVariant(s, entry.id, config, rng),
			district = chosen.run.district :: string,
		})
	end
end

---------------------------------------------------------------------------------------------------------------
-- Pass 2: the tower slots
---------------------------------------------------------------------------------------------------------------

-- Draws one option by `x` (0..total): the option it lands in, then every other in order (to try when a claim
-- doesn't fit).
local function drawOrder(options: { Option }, x: number): { Option }
	local pick = #options
	for k, option in options do
		x -= option.weight
		if x < 0 then
			pick = k
			break
		end
	end
	local order: { Option } = { options[pick] }
	for k, option in options do
		if k ~= pick then
			table.insert(order, option)
		end
	end
	return order
end

-- One more tower in slot group `runs`, on the free window nearest a peak that some tower archetype fits.
local function towerIn(s: State, runs: { Run }): boolean
	local windows: { Window } = {}
	for _, run in runs do
		local plots, district = run.plots, run.district :: string
		for i = 1, #plots do
			if s.used[plots[i].index] then
				continue
			end
			local cap = math.huge
			for j = i, math.min(#plots, i + City.towers.maxPlots - 1) do
				if s.used[plots[j].index] then
					break
				end
				cap = math.min(cap, plotCap(s, plots[j], district))
				if cap < BANDS.T then
					break
				end
				local width = spanWidth(plots, i, j)
				if width < City.towers.minWidth - EPS then
					continue
				end
				local c = windowCentre(run, i, j)
				local score = math.huge
				for _, peak in City.towers.peaks do
					score = math.min(score, (c - peak).Magnitude)
				end
				table.insert(windows, { run = run, i = i, j = j, width = width, depth = 0, cap = cap, score = score })
			end
		end
	end
	table.sort(windows, function(a: Window, b: Window): boolean
		if math.abs(a.score - b.score) > EPS then
			return a.score < b.score
		end
		local ia, ib = a.run.plots[a.i].index, b.run.plots[b.i].index
		if ia ~= ib then
			return ia < ib
		end
		return a.j < b.j
	end)

	for _, w in windows do
		local run, i, j = w.run, w.i, w.j
		local district = run.district :: string
		local first, last = run.plots[i], run.plots[j]
		local area = CityBuilder.area(first.zone, plotCentre(first))
		local at = windowCentre(run, i, j)
		local same, across =
			neighbours(s, boxOf(CityBuilder.footprint(run.plots, i, j), w.width, first.plotDepth), first.block)
		local isCorner = first.cornerStart == true or last.cornerEnd == true
		local rng = Random.new(mixSeed(s.seed, first.shade, first.index + 7919))
		local roll = rng:NextNumber()
		local options: { Option } = {}
		local total = 0
		for _, id in s.ids do
			local config = City.archetypes[id]
			if not drawable(s, id) or config.heights.max < BANDS.T then
				continue
			end
			local low = math.max(config.heights.min, BANDS.T)
			local top = math.min(config.heights.max, w.cap)
			if top < low then
				continue
			end
			if w.width < config.minWidth - EPS or w.width > config.maxWidth + EPS or j - i + 1 > config.maxPlots then
				continue
			end
			if same[id] or across[id] or crowded(s, id, config, at) or blockFull(s, id, config, first.block) then
				continue
			end
			local kind = cornerKind(id, config)
			if kind == "only" and not isCorner then
				continue
			end
			local weight = weightOf(id, config, district, area)
			if kind == "prefer" and isCorner then
				weight *= City.cornerPreference
			end
			if weight > 0 then
				table.insert(
					options,
					{ id = id, weight = weight, j = j, width = w.width, depth = 0, low = low, top = top }
				)
				total += weight
			end
		end
		if #options == 0 then
			continue
		end
		for _, option in drawOrder(options, roll * total) do
			local config = City.archetypes[option.id]
			local want = math.min(config.claimDepth or City.towers.claimDepth, City.claims.maxDepth)
			local depth = deepest(s, run, i, j, config.minDepth, want)
			if depth then
				local share = City.towers.rise + (1 - City.towers.rise) * first.tall
				makeSite(s, {
					run = run,
					i = i,
					j = j,
					id = option.id,
					config = config,
					depth = depth,
					height = option.low + share * (option.top - option.low),
					low = option.low,
					top = option.top,
					back = false,
					landmark = false,
					variant = drawVariant(s, option.id, config, rng),
					district = district,
				})
				return true
			end
		end
	end
	return false
end

local function placeTowers(s: State, runs: { Run })
	local order: { string } = {}
	local members: { [string]: { Run } } = {}
	local slots: { [string]: number } = {}
	for _, run in runs do
		local district = run.district
		if district == nil then
			continue
		end
		local group, count = slotGroup(run.plots[math.ceil(#run.plots / 2)], district)
		if group == nil or count <= 0 then
			continue
		end
		local list = members[group]
		if list == nil then
			list = {}
			members[group] = list
			slots[group] = count
			table.insert(order, group)
		end
		table.insert(list, run)
	end
	for _, group in order do
		while (s.slotsT[group] or 0) < slots[group] do
			if not towerIn(s, members[group]) then
				break
			end
		end
	end
end

---------------------------------------------------------------------------------------------------------------
-- Pass 3: the rest of every run
---------------------------------------------------------------------------------------------------------------

-- What may stand on run[i..]: every drawable archetype its area mixes in that fits the free plots from i (up to
-- `last`; caps[j] the most a repeatable on plots i..j may rise), on its chosen window. `relaxed` lets one stand across
-- the street from a copy of itself.
local function gather(
	s: State,
	run: Run,
	i: number,
	last: number,
	caps: { [number]: number },
	wide: number,
	same: { [string]: boolean },
	across: { [string]: { Site } },
	relaxed: boolean
): ({ Option }, number)
	local plots, district = run.plots, run.district :: string
	local plot = plots[i]
	local area = CityBuilder.area(plot.zone, plotCentre(plot))
	local options: { Option } = {}
	local total = 0
	for _, id in s.ids do
		local config = City.archetypes[id]
		if not drawable(s, id) or same[id] or (across[id] and not relaxed) then
			continue
		end
		if blockFull(s, id, config, plot.block) then
			continue
		end
		local kind = cornerKind(id, config)
		local weight = weightOf(id, config, district, area)
		if weight <= 0 then
			continue
		end
		-- Its windows from plot i: the plots it may merge, within its widths and its height under their cap.
		local fits: { Option } = {}
		for j = i, math.min(last, i + config.maxPlots - 1) do
			local width = spanWidth(plots, i, j)
			if width > config.maxWidth + EPS then
				break
			end
			if width < config.minWidth - EPS then
				continue
			end
			if kind == "only" and not (plot.cornerStart or plots[j].cornerEnd) then
				continue
			end
			local top = math.min(config.heights.max, caps[j])
			if top >= config.heights.min - EPS then
				table.insert(
					fits,
					{ id = id, weight = weight, j = j, width = width, depth = 0, low = config.heights.min, top = top }
				)
			end
		end
		if #fits == 0 then
			continue
		end
		local fit = if wide < RULES.wideShare then fits[#fits] else fits[math.floor(wide * 7919) % #fits + 1]
		if crowded(s, id, config, windowCentre(run, i, fit.j)) then
			continue
		end
		local want = math.min(config.claimDepth or config.minDepth, City.claims.maxDepth)
		local depth = deepest(s, run, i, fit.j, config.minDepth, want)
		if depth == nil then
			continue
		end
		fit.depth = depth
		if kind == "prefer" and (plot.cornerStart or plots[fit.j].cornerEnd) then
			fit.weight *= City.cornerPreference
		end
		table.insert(options, fit)
		total += fit.weight
	end
	return options, total
end

local function fill(s: State, runs: { Run }, legacy: { Plot })
	for _, run in runs do
		local plots, district = run.plots, run.district
		local i = 1
		while i <= #plots do
			local plot = plots[i]
			if s.used[plot.index] then
				i += 1
				continue
			end
			if district == nil or City.districtLooks[district] == nil then
				table.insert(legacy, plot)
				s.used[plot.index] = true
				i += 1
				continue
			end
			local rng = Random.new(mixSeed(s.seed, plot.shade, plot.index))
			local roll, wide = rng:NextNumber(), rng:NextNumber()
			-- The free plots from here on, and who stands near them.
			local last = i
			while last < #plots and last - i < 7 and not s.used[plots[last + 1].index] do
				last += 1
			end
			local frame, width = CityBuilder.footprint(plots, i, math.min(last, i + 3))
			local same, across = neighbours(s, boxOf(frame, width, plot.plotDepth), plot.block)
			local caps: { [number]: number } = {}
			for j = i, last do
				caps[j] = windowCap(s, run, i, j, district)
			end

			local relaxed = false
			local options, total = gather(s, run, i, last, caps, wide, same, across, false)
			if #options == 0 then
				relaxed = true
				options, total = gather(s, run, i, last, caps, wide, same, across, true)
			end
			local pick = if #options > 0 then drawOrder(options, roll * total)[1] else nil
			local placedHere = false
			if pick then
				local config = City.archetypes[pick.id]
				local variant = drawVariant(s, pick.id, config, rng)
				local height = pick.low + plot.tall * (pick.top - pick.low)
				local ok = true
				local others = across[pick.id]
				if relaxed and others then
					-- Across the street from itself: a palette its copies there don't wear, and a height apart.
					local clash = true
					for _ = 1, config.palettes do
						clash = false
						for _, other in others do
							clash = clash or other.variant.palette == variant.palette
						end
						if not clash then
							break
						end
						variant.palette = variant.palette % config.palettes + 1
					end
					ok = not clash
					for _, other in others do
						local apart = RULES.acrossHeight * math.max(height, other.height)
						if math.abs(height - other.height) < apart then
							local up, down =
								other.height * (1 + RULES.acrossHeight), other.height / (1 + RULES.acrossHeight)
							if up <= pick.top + EPS then
								height = up
							elseif down >= pick.low - EPS then
								height = down
							else
								ok = false
							end
						end
					end
				end
				if ok then
					makeSite(s, {
						run = run,
						i = i,
						j = pick.j,
						id = pick.id,
						config = config,
						depth = pick.depth,
						height = height,
						low = pick.low,
						top = pick.top,
						back = false,
						landmark = false,
						variant = variant,
						district = district,
					})
					i = pick.j + 1
					placedHere = true
				end
			end
			if not placedHere then
				table.insert(legacy, plot)
				s.used[plot.index] = true
				i += 1
			end
		end
	end
end

---------------------------------------------------------------------------------------------------------------
-- After the passes: towers apart in height, the skyline
---------------------------------------------------------------------------------------------------------------

-- No two towers within twinRange within twinGap of one height: in placement order (one-offs first), a tower that
-- would twin an earlier one moves to the nearest height inside its own range that twins none.
local function untwin(s: State)
	local towers: { Site } = {}
	for _, site in s.sites do
		if site.height < BANDS.T then
			continue
		end
		local info = s.info[site]
		local here = Vector2.new(site.frame.X, site.frame.Z)
		local function twins(h: number): boolean
			for _, other in towers do
				local far = (here - Vector2.new(other.frame.X, other.frame.Z)).Magnitude
				if far <= RULES.twinRange and math.abs(h - other.height) < RULES.twinGap - EPS then
					return true
				end
			end
			return false
		end
		if twins(site.height) then
			local step = RULES.twinGap / 4
			local found: number? = nil
			for k = 1, 64 do
				for _, sign in { 1, -1 } do
					local h = site.height + sign * k * step
					if h >= info.low - EPS and h <= info.top + EPS and not twins(h) then
						found = h
						break
					end
				end
				if found then
					break
				end
			end
			if found then
				site.height = found
				site.maxHeight = found + info.config.crownMax
				site.band = CityBuilder.bandOf(found)
			end
		end
		table.insert(towers, site)
	end
end

-- The tallest sites of band T and up (while budgets.skyline lasts) put their main masses in the Skyline model.
local function skylines(s: State)
	local tall: { Site } = {}
	for _, site in s.sites do
		if site.height >= BANDS.T then
			table.insert(tall, site)
		end
	end
	table.sort(tall, function(a: Site, b: Site): boolean
		if a.height ~= b.height then
			return a.height > b.height
		end
		return a.plots[1] < b.plots[1]
	end)
	local each = math.max(1, City.skyline.masses + City.skyline.crowns)
	for k = 1, math.min(#tall, math.floor(City.budgets.skyline / each)) do
		tall[k].skyline = true
	end
end

-- Decides what stands on every plot (see the header). Pure and deterministic. Without an Env (spec fixtures) it
-- places no one-offs and makes no core claims.
function CityBuilder.place(plots: { Plot }, seed: number, env: Env?): Placement
	local s: State = {
		seed = seed,
		env = env,
		ids = sortedIds(),
		sites = {},
		info = {},
		used = {},
		copies = {},
		perBlock = {},
		looks = {},
		slotsT = {},
		slotsH = {},
		runTower = {},
		oneOff = {},
		caps = {},
	}
	for _, entry in City.landmarks do
		local config = City.archetypes[entry.id]
		if config == nil or not complete(config) or config.maxCopies <= 1 then
			s.oneOff[entry.id] = true
		end
	end
	local runs: { Run } = {}
	for k, list in CityBuilder.runs(plots) do
		table.insert(runs, { plots = list, index = k, district = City.districts[list[1].zone], block = list[1].block })
	end

	local legacy: { Plot } = {}
	local unplaced: { string } = {}
	local missing: { string } = {}
	if env then
		placeLandmarks(s, runs, unplaced, missing)
	end
	placeTowers(s, runs)
	fill(s, runs, legacy)
	untwin(s)
	skylines(s)

	table.sort(s.sites, function(a: Site, b: Site): boolean
		return a.plots[1] < b.plots[1]
	end)
	table.sort(legacy, function(a: Plot, b: Plot): boolean
		return a.index < b.index
	end)
	for id, config in City.archetypes do
		if not complete(config) and not table.find(missing, id) then
			table.insert(missing, `{id} (its Config/CityArchetypes entry is incomplete)`)
		end
	end
	table.sort(missing)
	return { sites = s.sites, legacy = legacy, unplaced = unplaced, missing = missing }
end

---------------------------------------------------------------------------------------------------------------
-- Building, checking and filing a site
---------------------------------------------------------------------------------------------------------------

-- A part SLIM must not hold: a night light (it changes at dusk), a sign (SurfaceGui), a light or an ad unit.
function CityBuilder.isLight(spec: PartSpec): boolean
	return spec.tag == NIGHT_TAG or spec.labels ~= nil or spec.light ~= nil or spec.adUnit ~= nil
end

-- Everything wrong with a built site (empty when it is fit to build).
function CityBuilder.check(site: Site, specs: { PartSpec }): { string }
	local problems: { string } = {}
	local config = City.archetypes[site.archetype]
	if config and #specs > config.budget then
		table.insert(problems, `{#specs} parts, over its budget of {config.budget}`)
	end
	local folders = { [site.folder] = true, [site.lightsFolder] = true, [City.skyline.folder] = true }
	local hw, hd = site.width / 2 + TOLERANCE, site.depth / 2 + TOLERANCE
	for _, spec in specs do
		local problem = Kit.problem(spec)
		if problem then
			table.insert(problems, problem)
		end
		if string.sub(spec.name, 1, #site.id) ~= site.id or not folders[spec.folder] or spec.role ~= "building" then
			table.insert(problems, `{spec.name}: not named, filed or tagged as {site.id}'s`)
		end
		local lo, hi = Kit.localBounds(site.frame, spec)
		if lo.X < -hw or hi.X > hw or lo.Z < -hd or hi.Z > hd then
			table.insert(problems, `{spec.name}: outside its site's footprint`)
		end
		if lo.Y < -City.kit.bury - TOLERANCE or hi.Y > site.maxHeight + TOLERANCE then
			table.insert(problems, `{spec.name}: from y {lo.Y} to {hi.Y}, outside 0..{site.maxHeight}`)
		end
	end
	return problems
end

-- Files a built site's parts (see the header): lights to its lights model; for a skyline site its biggest masses
-- that rise past skyline.massFrom of its height, and its crown light, to the Skyline model.
function CityBuilder.file(site: Site, specs: { PartSpec })
	local sky = City.skyline
	if site.skyline then
		local masses: { PartSpec } = {}
		local crowns: { PartSpec } = {}
		for _, spec in specs do
			local lo, hi = Kit.localBounds(site.frame, spec)
			if spec.collide and spec.labels == nil and spec.light == nil and hi.Y >= site.height * sky.massFrom then
				table.insert(masses, spec)
			elseif spec.tag == NIGHT_TAG and spec.labels == nil and lo.Y >= site.height * sky.crownFrom then
				table.insert(crowns, spec)
			end
		end
		local function biggest(a: PartSpec, b: PartSpec): boolean
			local va, vb = a.size.X * a.size.Y * a.size.Z, b.size.X * b.size.Y * b.size.Z
			if va ~= vb then
				return va > vb
			end
			return a.name < b.name
		end
		table.sort(masses, biggest)
		table.sort(crowns, biggest)
		for k = 1, math.min(#masses, sky.masses) do
			masses[k].folder = sky.folder
		end
		for k = 1, math.min(#crowns, sky.crowns) do
			crowns[k].folder = sky.folder
		end
	end
	for _, spec in specs do
		if spec.folder == site.folder and CityBuilder.isLight(spec) then
			spec.folder = site.lightsFolder
		end
	end
end

-- Builds one site with its archetype. Returns its specs (filed), or nil and why not.
function CityBuilder.build(site: Site): ({ PartSpec }?, string?)
	local archetype = Index.byId[site.archetype]
	if archetype == nil then
		return nil, `{site.id}: no archetype module {site.archetype}`
	end
	local m = Kit.model(site)
	local ok, err = pcall(function()
		archetype.build(m)
	end)
	if not ok then
		return nil, `{site.id} {site.archetype}: {err}`
	end
	local problems = CityBuilder.check(site, m.specs)
	if #problems > 0 then
		return nil, `{site.id} {site.archetype}: {problems[1]} ({#problems} problems)`
	end
	CityBuilder.file(site, m.specs)
	return m.specs, nil
end

-- A stand-alone site for previews and specs: an archetype on a footprint `width` x `depth` at `frame`, with a variant
-- and a seed of your choosing.
function CityBuilder.sampleSite(
	archetype: string,
	frame: CFrame,
	width: number,
	depth: number,
	height: number,
	variant: Variant,
	seed: number,
	folder: string?
): Site
	local config = City.archetypes[archetype]
	local path = folder or "Preview"
	local name = string.match(path, "[^/]+$") or path
	return {
		id = "B0",
		archetype = archetype,
		district = config.district,
		zone = "",
		frame = frame,
		width = width,
		depth = depth,
		height = height,
		maxHeight = height + config.crownMax,
		seed = seed,
		variant = variant,
		folder = path,
		lightsFolder = `BuildingLights/{name}`,
		plots = {},
		block = 0,
		band = CityBuilder.bandOf(height),
		face = "road",
		claim = 0,
		corner = { left = false, right = false },
		landmark = false,
		skyline = false,
	}
end

return CityBuilder
