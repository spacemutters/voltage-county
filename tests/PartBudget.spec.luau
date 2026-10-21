--!strict
-- The performance budgets in Config/Perf (PLAN.md Phase 14 "Budgets"; docs/phase-14-contracts.md "Performance"):
--   * as built: every model in ServerStorage.VehicleModels (the catalog trims, greybox or art) and every design the AI
--     Car Designer can make, built the way the game builds it (Vehicle/SpecBuilder: every design template, with every
--     parts variant and stripe in turn and with the busiest parts), stays within parts.model
--   * dressed: the most a player can put on each of them in Wrap & Tint (Vehicle/Appearance): every wheel style, each
--     with every extra that fits at once (from each group the one with the most pieces, at most
--     Customization.maxExtras; the shop's own Customization.checkExtras must accept the set), a caliper disc and the
--     plates, stays within parts.dressed; on a body that takes wrap bands (designs; art bodies take none), every
--     banded wrap at its worst wheel style stays within parts.dressed + parts.wrap. A design is dressed in the class
--     that lists its template and takes the most extra pieces, from its biggest build. The worst cases are printed
--     for the log ("PartBudget.spec: worst ...").
--   * Config/Perf agrees with the builders (BodyKit.MAX_PARTS, Customization.wrapMaxParts); its frame budgets stand for
--     the frame rates they claim; the streaming radii give Config/Perf streaming.leadSeconds of driving at the fastest
--     highway limit (min radius) and at the fastest class's top speed (target radius); Perf.summarize and Perf.meets.
-- Works on copies and in-memory builds only: ServerStorage is never changed, and the design's catalog entry it
-- publishes (server only, so extras resolve) is taken down again. Edit-mode safe. A place with no stored models runs
-- the design and Config/Perf checks only.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")

local Shared = ReplicatedStorage.Shared
local Appearance = require(Shared.Vehicle.Appearance)
local BodyKit = require(Shared.Vehicle.BodyKit)
local Catalog = require(Shared.Vehicle.Catalog)
local Classes = require(Shared.Config.Classes)
local Customization = require(Shared.Config.Customization)
local Harness = require(Shared.Testing.Harness)
local Perf = require(Shared.Config.Perf)
local RoadGraph = require(Shared.Config.RoadGraph)
local SpecBuilder = require(Shared.Vehicle.SpecBuilder)
local Spawning = require(Shared.Config.Spawning)
local Units = require(Shared.Util.Units)

local kit: any = require(Shared.Config.DesignKit)

local PARTS = Perf.parts
local UID = "partbudget-spec" -- the design uid builds here use
local LOG = "  PartBudget.spec:"
local SHOWN = 5 -- worst cases printed
local MS_PER_SECOND = 1000
local MAX_MEAN_SLACK = 1.05 -- a mean budget is at most this much over its frame rate's frame time
local EPSILON = 1e-6
local PART_FIELDS = { "frontBumper", "rearBumper", "spoiler", "lights" } -- the design parts that shape the body
-- The kit's busiest parts (the most pieces each), tried with every stripe besides walking every variant.
local BUSY_PARTS: { [string]: string } = {
	frontBumper = "rugged",
	rearBumper = "diffuser",
	spoiler = "wing",
	lights = "bar",
}

type Record = {
	label: string,
	stored: number, -- parts as built
	dressed: number, -- parts in the worst look without a wrap
	wheels: string, -- the wheel style that gave it
	extras: { string },
	wrapped: number?, -- parts in the worst look with a wrap, when the body takes bands
	wrap: string?,
}

-- Everything measured, for the worst-case summary at the end.
local records: { Record } = {}

-- Helpers ---------------------------------------------------------------------------------------------------

local function sortedKeys(map: { [string]: any }): { string }
	local keys: { string } = {}
	for key in map do
		table.insert(keys, key)
	end
	table.sort(keys)
	return keys
end

-- The list's entry for `index` (1-based, wrapping), so a loop walks through every variant.
local function nth(list: { string }, index: number): string
	return list[(index - 1) % #list + 1]
end

local function piecesOf(id: string): number
	local extra = Customization.getExtra(id)
	return if extra ~= nil then #extra.pieces else 0
end

-- Every extra a car of this class and body style can carry at once, the most pieces first: from each group the one
-- with the most pieces, every extra in no group, at most Customization.maxExtras.
local function mostExtras(class: string, bodyStyle: string?): { string }
	local best: { [string]: string } = {} -- group (or the extra's own id) -> extra id
	for _, extra in Customization.extrasFor(class, bodyStyle) do
		local key = extra.group or extra.id
		local held = best[key]
		if held == nil or #extra.pieces > piecesOf(held) then
			best[key] = extra.id
		end
	end
	local list: { string } = {}
	for _, id in best do
		table.insert(list, id)
	end
	table.sort(list, function(a: string, b: string): boolean
		local piecesA, piecesB = piecesOf(a), piecesOf(b)
		if piecesA ~= piecesB then
			return piecesA > piecesB
		end
		return a < b
	end)
	while #list > Customization.maxExtras do
		table.remove(list)
	end
	return list
end

local function piecesIn(extras: { string }): number
	local total = 0
	for _, id in extras do
		total += piecesOf(id)
	end
	return total
end

-- A caliper other than the default: on an art car's stock wheel it adds a disc.
local OTHER_CALIPER: string = Customization.defaults.caliper
for _, caliper in Customization.calipers do
	if caliper.id ~= Customization.defaults.caliper then
		OTHER_CALIPER = caliper.id
		break
	end
end

local function wheelIds(): { string }
	local ids: { string } = {}
	for _, style in Customization.wheels do
		table.insert(ids, style.id)
	end
	return ids
end

-- Every wrap that lays vinyl bands (the standard ones and the exclusive looks).
local function bandedWraps(): { string }
	local ids: { string } = {}
	local seen: { [string]: boolean } = {}
	for _, list in { Customization.wraps, Customization.exclusiveWraps } do
		for _, wrap in list do
			if #wrap.bands > 0 and not seen[wrap.id] then
				seen[wrap.id] = true
				table.insert(ids, wrap.id)
			end
		end
	end
	return ids
end

local function lookWith(wheels: string, extras: { string }, wrap: string?): Customization.Look
	local d = Customization.defaults
	return {
		uid = UID,
		paint = d.paint,
		finish = d.finish,
		wrap = wrap or d.wrap,
		wheels = wheels,
		rideHeight = d.rideHeight,
		tint = d.tint,
		caliper = OTHER_CALIPER,
		extras = table.clone(extras),
		plateFormat = d.plateFormat,
	}
end

-- Dresses a copy of `source` in each of `wheels` with `extras`, then, on a body that takes wrap bands, in every
-- banded wrap at its worst wheel style. `source` is never changed; the copy is destroyed.
local function measure(label: string, source: Model, wheels: { string }, extras: { string }): Record
	local record: Record = {
		label = label,
		stored = BodyKit.partCount(source),
		dressed = 0,
		wheels = wheels[1],
		extras = extras,
	}
	local copy = source:Clone()
	local ok, err = pcall(function()
		for _, wheelId in wheels do
			Appearance.apply(copy, lookWith(wheelId, extras, nil))
			local count = BodyKit.partCount(copy)
			if count > record.dressed then
				record.dressed, record.wheels = count, wheelId
			end
		end
		if Appearance.takesWraps(copy) then
			for _, wrapId in bandedWraps() do
				Appearance.apply(copy, lookWith(record.wheels, extras, wrapId))
				local count = BodyKit.partCount(copy)
				if count > (record.wrapped or 0) then
					record.wrapped, record.wrap = count, wrapId
				end
			end
		end
	end)
	copy:Destroy()
	if not ok then
		error(err, 0)
	end
	table.insert(records, record)
	return record
end

local function describeLook(record: Record): string
	local extras = if #record.extras > 0 then table.concat(record.extras, ", ") else "no extras"
	return `{record.wheels} wheels, {extras}`
end

-- Everything over a budget in a record.
local function problemsOf(record: Record): { string }
	local problems: { string } = {}
	if record.stored > PARTS.model then
		table.insert(problems, `{record.label}: {record.stored} parts as built (budget {PARTS.model})`)
	end
	if record.dressed > PARTS.dressed then
		table.insert(
			problems,
			`{record.label}: {record.dressed} parts dressed ({describeLook(record)}; cap {PARTS.dressed})`
		)
	end
	local wrapped = record.wrapped
	if wrapped ~= nil and wrapped > PARTS.dressed + PARTS.wrap then
		table.insert(
			problems,
			`{record.label}: {wrapped} parts dressed with the {record.wrap} wrap ({describeLook(record)}; cap `
				.. `{PARTS.dressed + PARTS.wrap})`
		)
	end
	return problems
end

local function report(problems: { string })
	for _, problem in problems do
		print(`{LOG} {problem}`)
	end
end

-- Stored catalog models ----------------------------------------------------------------------------------------

local function storedModels(): { Model }
	local list: { Model } = {}
	local folder = ServerStorage:FindFirstChild(Spawning.modelsFolder)
	if folder == nil then
		return list
	end
	for _, child in folder:GetChildren() do
		if child:IsA("Model") then
			table.insert(list, child)
		end
	end
	table.sort(list, function(a: Model, b: Model): boolean
		return a.Name < b.Name
	end)
	return list
end

-- Designs ------------------------------------------------------------------------------------------------------

-- For each design template, the designable class listing it whose cars take the most extra pieces.
local function designPairs(): { { classId: string, template: string } }
	local list: { { classId: string, template: string } } = {}
	for _, template in sortedKeys(kit.templates) do
		local style: string = kit.templates[template].style
		local best: string? = nil
		local bestPieces = -1
		for _, classId in sortedKeys(kit.classes) do
			if table.find(kit.classes[classId].templates, template) == nil then
				continue
			end
			local pieces = piecesIn(mostExtras(classId, style))
			if pieces > bestPieces then
				best, bestPieces = classId, pieces
			end
		end
		if best ~= nil then
			table.insert(list, { classId = best, template = template })
		end
	end
	return list
end

-- The kit wheel style with the fewest parts in its face: the room it leaves is filled with stripes as the design is
-- built, and a busier style bought later goes on top of them.
local function lightestWheels(): string
	local lightest: string = kit.parts.wheels[1]
	for _, id in kit.parts.wheels do
		if Appearance.wheelFaceParts(id) < Appearance.wheelFaceParts(lightest) then
			lightest = id
		end
	end
	return lightest
end

-- A complete, valid design spec, middle of every range, each list's first id (as tests/SpecBuilder.spec).
local function baseSpec(classId: string, template: string): { [string]: any }
	local class = kit.classes[classId]
	return {
		refusal = nil,
		name = "Budget Runner",
		tagline = "A design the part budget builds",
		class = classId,
		energy = class.energy[1],
		personality = sortedKeys(kit.personalities)[1],
		meshPrompt = "a rounded original test car",
		body = { template = template, length = 0.5, height = 0.5, roofline = 0.5, noseSlope = 0.5, flare = 0.5 },
		parts = {
			frontBumper = kit.parts.frontBumper[1],
			rearBumper = kit.parts.rearBumper[1],
			spoiler = kit.parts.spoiler[1],
			lights = kit.parts.lights[1],
			wheels = kit.parts.wheels[1],
		},
		paint = { primary = "#3366CC", secondary = "#202428", finish = kit.finishes[1], stripe = kit.stripes[1] },
		stance = { rideHeight = 0, wheelSize = 0.5 },
	}
end

-- The specs a template is built from: every parts variant and stripe in turn, then the busiest parts with each
-- stripe, all on the lightest wheels (the most room for stripes).
local function bodySpecs(classId: string, template: string): { { [string]: any } }
	local lightest = lightestWheels()
	local specs: { { [string]: any } } = {}
	local most = 0
	for _, field in PART_FIELDS do
		most = math.max(most, #kit.parts[field])
	end
	for index = 1, most do
		local spec = baseSpec(classId, template)
		for _, field in PART_FIELDS do
			spec.parts[field] = nth(kit.parts[field], index)
		end
		spec.parts.wheels = lightest
		spec.paint.stripe = nth(kit.stripes, index)
		table.insert(specs, spec)
	end
	for _, stripe in kit.stripes do
		local spec = baseSpec(classId, template)
		for field, id in BUSY_PARTS do
			if table.find(kit.parts[field], id) ~= nil then
				spec.parts[field] = id
			end
		end
		spec.parts.wheels = lightest
		spec.paint.stripe = stripe
		table.insert(specs, spec)
	end
	return specs
end

-- Specs ------------------------------------------------------------------------------------------------------

return function(t: Harness.Api)
	t.describe("Config/Perf", function()
		t.it("agrees with the builders' own numbers", function()
			t.expect(BodyKit.MAX_PARTS).toBe(PARTS.model)
			t.expect(Customization.wrapMaxParts <= PARTS.wrap).toBe(true)
			t.expect(PARTS.dressed >= PARTS.model).toBe(true)
		end)

		t.it("frame budgets stand for the frame rates they claim", function()
			local problems: { string } = {}
			for _, name in { "desktop", "phone", "server" } do
				local budget: Perf.FrameBudget = (Perf.frame :: any)[name]
				local frameMs = MS_PER_SECOND / budget.fps
				if budget.meanMs < frameMs - EPSILON or budget.meanMs > frameMs * MAX_MEAN_SLACK then
					table.insert(problems, `{name}: mean {budget.meanMs} ms for {budget.fps} fps ({frameMs} ms)`)
				end
				if budget.p95Ms < budget.meanMs then
					table.insert(problems, `{name}: p95 {budget.p95Ms} ms under its mean`)
				end
			end
			t.expect(problems).toEqual({})
			t.expect(Perf.frame.desktop.fps >= 60).toBe(true) -- PLAN.md: 60 fps desktop
			t.expect(Perf.frame.phone.fps >= 30).toBe(true) -- 30+ fps on a mid-range phone
		end)

		t.it("streaming radii give leadSeconds at the highway limit and the fastest class's top speed", function()
			local streaming = Perf.streaming
			local highwayMph = 0
			for _, edge in RoadGraph.edges do
				if edge.kind == "highway" then
					highwayMph = math.max(highwayMph, edge.speedLimitMph)
				end
			end
			local fastestMph = 0
			for _, class in Classes do
				fastestMph = math.max(fastestMph, class.topSpeedMph.max)
			end
			t.expect(highwayMph).toBeGreaterThan(0)
			t.expect(streaming.minRadius >= streaming.leadSeconds * Units.mphToStuds(highwayMph)).toBe(true)
			t.expect(streaming.targetRadius >= streaming.leadSeconds * Units.mphToStuds(fastestMph)).toBe(true)
			t.expect(streaming.targetRadius >= streaming.minRadius).toBe(true)
		end)

		t.it("summarizes frame times as mean, nearest-rank p95 and max, and judges them", function()
			local tens = { 70, 10, 100, 40, 20, 90, 30, 60, 50, 80 }
			t.expect(Perf.summarize(tens)).toEqual({ samples = 10, meanMs = 55, p95Ms = 100, maxMs = 100 })
			local twenty: { number } = {}
			for value = 20, 1, -1 do
				table.insert(twenty, value)
			end
			t.expect(Perf.summarize(twenty)).toEqual({ samples = 20, meanMs = 10.5, p95Ms = 19, maxMs = 20 })
			t.expect(Perf.summarize({})).toEqual({ samples = 0, meanMs = 0, p95Ms = 0, maxMs = 0 })
			t.expect(tens[1]).toBe(70) -- the samples are left as they were
			local budget: Perf.FrameBudget = { fps = 60, meanMs = 17, p95Ms = 20 }
			local meanOk, p95Ok = Perf.meets({ samples = 1, meanMs = 17, p95Ms = 20.5, maxMs = 30 }, budget)
			t.expect({ meanOk, p95Ok }).toEqual({ true, false })
		end)
	end)

	t.describe("Part budget: stored catalog models", function()
		local stored = storedModels()
		if #stored == 0 then
			t.it("has no models in ServerStorage.VehicleModels to check (nothing checked)", function()
				print(`{LOG} no stored models, so the catalog checks did not run`)
			end)
			return
		end
		local wheels = wheelIds()
		for _, model in stored do
			t.it(`{model.Name} as stored, and in the fullest look`, function()
				local vehicleId = model:GetAttribute("VehicleId")
				local vehicle = if type(vehicleId) == "string" then Catalog.getVehicle(vehicleId) else nil
				local extras: { string } = {}
				if vehicle ~= nil then
					extras = mostExtras(vehicle.class, vehicle.bodyStyle)
					t.expect(Customization.checkExtras(extras, vehicle.class, vehicle.bodyStyle)).toBe(nil)
				else
					print(`{LOG} {model.Name} has no catalog entry, so it was dressed without extras`)
				end
				local problems = problemsOf(measure(model.Name, model, wheels, extras))
				report(problems)
				t.expect(problems).toEqual({})
			end)
		end
	end)

	t.describe("Part budget: designs", function()
		local canPublish = RunService:IsServer()
		for _, pair in designPairs() do
			local label = `{pair.template} design ({pair.classId})`
			t.it(`a {label} as built (every variant), and its biggest build in the fullest look`, function()
				local problems: { string } = {}
				local biggest: Model? = nil
				local biggestSpec: { [string]: any }? = nil
				local biggestCount = -1
				for index, spec in bodySpecs(pair.classId, pair.template) do
					local ok, built = pcall(SpecBuilder.build, spec, kit, UID)
					if not ok then
						table.insert(problems, `{label} #{index}: {built}`)
						continue
					end
					local model = built :: Model
					local count = BodyKit.partCount(model)
					if count > PARTS.model then
						table.insert(problems, `{label} #{index}: {count} parts as built (budget {PARTS.model})`)
					end
					if count > biggestCount then
						if biggest ~= nil then
							biggest:Destroy()
						end
						biggest, biggestSpec, biggestCount = model, spec, count
					else
						model:Destroy()
					end
				end
				local model, spec = biggest, biggestSpec
				if model == nil or spec == nil then
					report(problems)
					t.expect(problems).toEqual({})
					return
				end
				-- Extras are sized by class, so the design's catalog entry must resolve (Vehicle/Appearance looks it
				-- up); only the server can publish it.
				local published = canPublish
					and pcall(Catalog.publishDesign, UID, SpecBuilder.vehicleFor(spec, kit, UID))
				if not published then
					print(
						`{LOG} {label}: its catalog entry couldn't be published here, so it was dressed without extras`
					)
				end
				local style: string = kit.templates[pair.template].style
				local extras = if published then mostExtras(pair.classId, style) else {}
				local ok, result = pcall(measure, label, model, kit.parts.wheels, extras)
				if published then
					pcall(Catalog.unpublishDesign, UID)
				end
				model:Destroy()
				if not ok then
					error(result, 0)
				end
				for _, problem in problemsOf(result) do
					table.insert(problems, problem)
				end
				report(problems)
				t.expect(problems).toEqual({})
			end)
		end
	end)

	t.describe("Part budget: worst cases", function()
		t.it("prints the worst cases for the log", function()
			local byDressed = table.clone(records)
			table.sort(byDressed, function(a: Record, b: Record): boolean
				if a.dressed ~= b.dressed then
					return a.dressed > b.dressed
				end
				return a.label < b.label
			end)
			print(`{LOG} worst as built (budget {PARTS.model}) and dressed (cap {PARTS.dressed}):`)
			for index = 1, math.min(SHOWN, #byDressed) do
				local record = byDressed[index]
				print(
					`{LOG}   {record.label}: {record.dressed} dressed ({describeLook(record)}), {record.stored} as built`
				)
			end
			local wrapped: { Record } = {}
			for _, record in records do
				if record.wrapped ~= nil then
					table.insert(wrapped, record)
				end
			end
			table.sort(wrapped, function(a: Record, b: Record): boolean
				return (a.wrapped :: number) > (b.wrapped :: number)
			end)
			if #wrapped > 0 then
				print(`{LOG} worst with a wrap (cap {PARTS.dressed + PARTS.wrap}):`)
				for index = 1, math.min(SHOWN, #wrapped) do
					local record = wrapped[index]
					print(
						`{LOG}   {record.label}: {record.wrapped} with the {record.wrap} wrap ({describeLook(record)})`
					)
				end
			end
			local mostStored = 0
			for _, record in records do
				mostStored = math.max(mostStored, record.stored)
			end
			print(`{LOG} most parts as built: {mostStored}`)
			t.expect(#records).toBeGreaterThan(0)
		end)
	end)
end
