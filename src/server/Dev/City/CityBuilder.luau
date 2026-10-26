--!strict
-- The city builder (docs/city/CITY_PLAN.md §4 and §8; docs/city/ARCHETYPE_GUIDE.md). Pure: plots in, part specs out.
-- Dev/MapBuilder's plot pass (addBuildings) hands it every built plot in order; it decides which archetype stands
-- where, builds each site with its archetype module and checks it, and gives back the plots it leaves to the old
-- facade (the legacy look, Dev/MapBuilder addBuilding).
--
-- Placement (place):
--   * a plot's district is its zone's (Config/City districts); a zone with no district keeps the old look
--   * runs: neighbouring plots of one frontage with no gap between them. A site is one plot or, for an archetype
--     that needs a wider site, the fewest neighbouring plots of one run that reach its minWidth (up to maxPlots and
--     maxWidth). No plot moves: a site only joins plots that were built anyway, across the gap between them
--   * the archetype is drawn from the district's candidates that fit, weighted (Config/City archetypes[id].weight,
--     the old look weighs districtLooks.legacyWeight), from the plot's own random stream: deterministic
--   * neighbours on a run never share an archetype; an archetype stands at most perBlock times in a block,
--     maxCopies in the map, and minSpacing studs from its other copies
--   * each copy's variant (palette, crown, rhythm, mirror) is drawn from its seed, and no two copies share a look
--     (archetype, palette, crown and rhythm) while an unused one is left
-- Building (build): the archetype writes its parts through Dev/City/Kit, then check() holds them to the site: every
-- part inside the footprint, between y = -kit.bury and maxHeight, no more parts than the budget, every spec fit to
-- build. A site that fails is left to the old look with a note (tests/MapBuilder.spec fails on notes).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local City = require(ReplicatedStorage.Shared.Config.City)
local Index = require(script.Parent.Archetypes.Index)
local Kit = require(script.Parent.Kit)
local Types = require(script.Parent.Types)

type PartSpec = Types.PartSpec
type Variant = Types.Variant
export type Plot = Types.Plot
export type Site = Types.Site

-- One archetype that may stand on a plot: its weight and the last plot of its site.
type Option = { id: string, weight: number, last: number }

export type Placement = {
	sites: { Site },
	legacy: { Plot }, -- plots the old look builds
}

local CityBuilder = {}

local TOLERANCE = 0.01 -- studs a part may reach past its site's footprint (rounding)

-- Integer seed mixing for deterministic per-thing random streams (the same mix as Dev/MapBuilder's).
local function mixSeed(seed: number, a: number, b: number): number
	local modulus = 2147483647
	local h = math.floor(seed) % modulus
	h = (h * 16807 + math.floor(a) * 7919 + 13) % modulus
	h = (h * 16807 + math.floor(b) * 104729 + 17) % modulus
	return h
end
CityBuilder.mixSeed = mixSeed

-- Archetype ids in a fixed order, so every plan draws the same way.
local function sortedIds(): { string }
	local ids: { string } = {}
	for id in City.archetypes do
		table.insert(ids, id)
	end
	table.sort(ids)
	return ids
end

-- Plots in runs: neighbours of one frontage with no gap between them, in the order the plot pass made them.
function CityBuilder.runs(plots: { Plot }): { { Plot } }
	local runs: { { Plot } } = {}
	local current: { Plot }? = nil
	local last: Plot? = nil
	for _, plot in plots do
		local joined = last ~= nil
			and current ~= nil
			and last.frontage == plot.frontage
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

-- The site plots run[i..j] make: its frame, width and depth (the gap between neighbours kept at both ends).
function CityBuilder.footprint(run: { Plot }, i: number, j: number): (CFrame, number, number)
	local first, last = run[i], run[j]
	local half = City.siteGap / 2
	local from = first.along + half
	local to = last.along + last.width - half
	local depth = first.plotDepth
	local center = first.frontStart + first.u * ((from + to) / 2 - first.along) + first.away * (depth / 2)
	local at = Vector3.new(center.X, 0, center.Y)
	local frame = CFrame.lookAt(at, at - Vector3.new(first.away.X, 0, first.away.Y))
	return frame, to - from, depth
end

-- The fewest plots from run[i] on that make a site wide enough for `config`, or nil.
local function fit(run: { Plot }, i: number, config: City.ArchetypeConfig): (number?, number)
	for j = i, math.min(#run, i + config.maxPlots - 1) do
		local _, width, depth = CityBuilder.footprint(run, i, j)
		if width > config.maxWidth + 1e-6 or depth < config.minDepth - 1e-6 then
			return nil, 0
		end
		if width >= config.minWidth - 1e-6 then
			return j, width
		end
	end
	return nil, 0
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

-- The cap over plots run[i..j] standing at `at`: the district's, and nearSpotCap if one of them is near a spot.
local function siteCap(run: { Plot }, i: number, j: number, district: string, at: Vector2): number
	local cap = CityBuilder.heightCap(district, at)
	for k = i, j do
		if run[k].nearSpot then
			cap = math.min(cap, City.nearSpotCap)
		end
	end
	return cap
end

-- Decides what stands on every plot (see the header). Pure and deterministic.
function CityBuilder.place(plots: { Plot }, seed: number): Placement
	local ids = sortedIds()
	local sites: { Site } = {}
	local legacy: { Plot } = {}
	local copies: { [string]: { Vector2 } } = {}
	local perBlock: { [string]: number } = {}
	local looks: { [string]: boolean } = {}

	for _, run in CityBuilder.runs(plots) do
		local previous = ""
		local i = 1
		while i <= #run do
			local plot = run[i]
			local district = City.districts[plot.zone]
			local districtLook = if district then City.districtLooks[district] else nil
			if district == nil or districtLook == nil then
				table.insert(legacy, plot)
				previous = ""
				i += 1
				continue
			end
			local rng = Random.new(mixSeed(seed, plot.shade, plot.index))
			local roll = rng:NextNumber()

			-- Every archetype of the district that may stand here, and the old look.
			local options: { Option } = {}
			local total = districtLook.legacyWeight
			for _, id in ids do
				local config = City.archetypes[id]
				if config.district ~= district or Index.byId[id] == nil or id == previous then
					continue
				end
				local placed: { Vector2 } = copies[id] or {}
				if #placed >= config.maxCopies or (perBlock[`{id}:{plot.block}`] or 0) >= config.perBlock then
					continue
				end
				local last = fit(run, i, config)
				if last == nil then
					continue
				end
				local frame = CityBuilder.footprint(run, i, last)
				local at = Vector2.new(frame.Position.X, frame.Position.Z)
				if siteCap(run, i, last, district, at) < config.heights.min then
					continue
				end
				local crowded = false
				for _, other in placed do
					if (other - at).Magnitude < config.minSpacing then
						crowded = true
						break
					end
				end
				if not crowded and config.weight > 0 then
					table.insert(options, { id = id, weight = config.weight, last = last })
					total += config.weight
				end
			end

			-- The draw: the old look first, then each option in id order.
			local pick: Option? = nil
			local x = roll * total - districtLook.legacyWeight
			if x >= 0 then
				for _, option in options do
					x -= option.weight
					if x < 0 then
						pick = option
						break
					end
				end
				pick = pick or options[#options]
			end
			if pick == nil then
				table.insert(legacy, plot)
				previous = ""
				i += 1
				continue
			end

			local config = City.archetypes[pick.id]
			local frame, width, depth = CityBuilder.footprint(run, i, pick.last)
			local cap = siteCap(run, i, pick.last, district, Vector2.new(frame.Position.X, frame.Position.Z))
			local tallest = math.min(config.heights.max, cap)
			local height = config.heights.min + plot.tall * (tallest - config.heights.min)
			local variant: Variant = {
				palette = rng:NextInteger(1, config.palettes),
				crown = rng:NextInteger(1, config.crowns),
				rhythm = rng:NextInteger(1, config.rhythms),
				mirror = rng:NextNumber() < 0.5,
			}
			-- A fresh look if one is left: walk the palettes, then the crowns, then the rhythms.
			local combos = config.palettes * config.crowns * config.rhythms
			for _ = 1, combos do
				if not looks[`{pick.id}:{variant.palette}:{variant.crown}:{variant.rhythm}`] then
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
			looks[`{pick.id}:{variant.palette}:{variant.crown}:{variant.rhythm}`] = true

			local plotIds: { number } = {}
			for k = i, pick.last do
				table.insert(plotIds, run[k].index)
			end
			local ownModel = config.ownModel or height >= City.towerModelFrom
			table.insert(sites, {
				id = `B{plot.index}`,
				archetype = pick.id,
				district = district,
				zone = plot.zone,
				frame = frame,
				width = width,
				depth = depth,
				height = height,
				maxHeight = height + config.crownMax,
				seed = mixSeed(seed, plot.index, plot.shade),
				variant = variant,
				folder = if ownModel then `Buildings/Tower{plot.index}` else plot.folder,
				plots = plotIds,
				block = plot.block,
			})
			local placed: { Vector2 } = copies[pick.id] or {}
			table.insert(placed, Vector2.new(frame.Position.X, frame.Position.Z))
			copies[pick.id] = placed
			local key = `{pick.id}:{plot.block}`
			perBlock[key] = (perBlock[key] or 0) + 1
			previous = pick.id
			i = pick.last + 1
		end
	end
	return { sites = sites, legacy = legacy }
end

-- Everything wrong with a built site (empty when it is fit to build).
function CityBuilder.check(site: Site, specs: { PartSpec }): { string }
	local problems: { string } = {}
	local config = City.archetypes[site.archetype]
	if config and #specs > config.budget then
		table.insert(problems, `{#specs} parts, over its budget of {config.budget}`)
	end
	local hw, hd = site.width / 2 + TOLERANCE, site.depth / 2 + TOLERANCE
	for _, spec in specs do
		local problem = Kit.problem(spec)
		if problem then
			table.insert(problems, problem)
		end
		if string.sub(spec.name, 1, #site.id) ~= site.id or spec.folder ~= site.folder or spec.role ~= "building" then
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

-- Builds one site with its archetype. Returns its specs, or nil and why not.
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
		folder = folder or "Preview",
		plots = {},
		block = 0,
	}
end

return CityBuilder
