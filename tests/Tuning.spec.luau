--!strict
-- Per-trim physics numbers: complete and sane for every trim in the catalog, placed by the model contract, and
-- with enough grip to put the calibrated acceleration down. Phase 10 (docs/phase-10-contracts.md, "Arc
-- tuning"): every Arc trim out-accelerates and out-grips every other catalog car, inside the hypercar band, and
-- beats the best any other class band allows. The physics check runs on designed cars too (every class,
-- personality and energy the kit can make, at the kit's band ceiling), so no designed car can match it: a fuel car
-- needs a harder peak than a battery car for the same 0-60, so a band's numbers alone don't prove it.

local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Catalog = require(ReplicatedStorage.Shared.Vehicle.Catalog)
local Classes = require(ReplicatedStorage.Shared.Config.Classes)
local Harness = require(ReplicatedStorage.Shared.Testing.Harness)
local Powertrain = require(ReplicatedStorage.Shared.Vehicle.Powertrain)
local SpecBuilder = require(ReplicatedStorage.Shared.Vehicle.SpecBuilder)
local Tuning = require(ReplicatedStorage.Shared.Vehicle.Tuning)
local Units = require(ReplicatedStorage.Shared.Util.Units)

-- Rojo serves the JSON as a ModuleScript returning the decoded table.
local kit: any = require(ReplicatedStorage.Shared.Config.DesignKit)

-- Grip must comfortably exceed the strongest launch: the driven wheels' limit at static load over the peak
-- acceleration, after Standard's traction-control share.
local GRIP_MARGIN = 1.5
local HUB_TOLERANCE = 1e-9

local ARC = "ohm_arc"
local HYPERCAR = "hypercar"
local HUNDRED_MPH = 100
local SPEED_STEP_MPH = 5 -- the pull is compared at every this many mph up to the other car's top speed
local DESIGN_UID = "tuning-spec" -- designs tuned here publish under "<this>-<run>-<class>-<personality>-<energy>"

local function isPositiveFinite(value: number): boolean
	return value == value and value > 0 and value < math.huge
end

local function isFinite(value: number): boolean
	return value == value and math.abs(value) < math.huge
end

-- Every number in `tuning` is positive and finite, every Vector3 is finite. Returns the offending keys.
local function badFields(tuning: { [string]: any }): { string }
	local bad: { string } = {}
	for key, value in tuning do
		if type(value) == "number" then
			if not isPositiveFinite(value) then
				table.insert(bad, `{key}={value}`)
			end
		elseif type(value) == "table" then
			for index, item in value do
				local ok = if typeof(item) == "Vector3"
					then isFinite(item.X) and isFinite(item.Y) and isFinite(item.Z)
					else type(item) == "number" and isPositiveFinite(item)
				if not ok then
					table.insert(bad, `{key}.{index}={item}`)
				end
			end
		end
	end
	table.sort(bad)
	return bad
end

local function forEachTrim(callback: (vehicleId: string, trimId: string, drivable: boolean) -> ())
	for _, vehicleId in Catalog.vehicleIds() do
		local vehicle = Catalog.getVehicle(vehicleId)
		if vehicle then
			for _, trim in vehicle.trims do
				callback(vehicleId, trim.id, vehicle.playerDrivable)
			end
		end
	end
end

type Entry = { name: string, tuning: Tuning.Tuning }

-- The Arc trims (`arc` true) or every other trim in the catalog, drivable or not.
local function entries(arc: boolean): { Entry }
	local list: { Entry } = {}
	forEachTrim(function(vehicleId, trimId)
		if (vehicleId == ARC) == arc then
			local tuning = Tuning.forTrim(vehicleId, trimId)
			assert(tuning, `{vehicleId}/{trimId} has a tuning`)
			table.insert(list, { name = `{vehicleId}/{trimId}`, tuning = tuning })
		end
	end)
	return list
end

-- Net forward acceleration on flat ground at `speed` (studs/s) with the pedal down in Standard: the force curve
-- (before any gearbox, which only ever takes some away), capped by traction, less drag and rolling resistance.
local function pull(tuning: Tuning.Tuning, speed: number): number
	return math.min(Powertrain.tractiveAccel(tuning, speed), Powertrain.tractionCap(tuning, "standard"))
		- Powertrain.resistance(tuning, speed)
end

local function sortedKeys(map: { [string]: any }): { string }
	local keys: { string } = {}
	for key in map do
		table.insert(keys, key)
	end
	table.sort(keys)
	return keys
end

-- Every kind of car the AI Car Designer can make with `kitData` (Config/DesignKit), tuned: each kit class's first
-- template with every personality and energy the kit allows (a design's stats come only from its class and
-- personality; its template only caps grip on a tall body). Tuning reads a car through Catalog, so each design is
-- published just long enough to tune it, then taken down (the tuning is cached). nil off the server, where designs
-- can't be published.
local function designEntries(kitData: any): { Entry }?
	if not RunService:IsServer() then
		return nil
	end
	local list: { Entry } = {}
	local run = HttpService:GenerateGUID(false) -- a fresh id each run: Tuning caches by vehicle id
	for _, classId in sortedKeys(kitData.classes) do
		local class = kitData.classes[classId]
		for _, personality in sortedKeys(kitData.personalities) do
			for _, energy in class.energy do
				local name = `{classId} {personality} {energy} design`
				local uid = `{DESIGN_UID}-{run}-{classId}-{personality}-{energy}`
				local spec = {
					class = classId,
					personality = personality,
					energy = energy,
					body = { template = class.templates[1] },
				}
				local entry = SpecBuilder.vehicleFor(spec, kitData, uid)
				local ok, tuning = pcall(function(): Tuning.Tuning?
					Catalog.publishDesign(uid, entry)
					return Tuning.forTrim(entry.id, entry.trims[1].id)
				end)
				pcall(Catalog.unpublishDesign, uid)
				assert(ok, `{name} couldn't be tuned: {tostring(tuning)}`)
				assert(tuning, `{name} has a tuning`)
				table.insert(list, { name = name, tuning = tuning })
			end
		end
	end
	return list
end

-- Every one of `rivals` that reaches `speed` (studs/s) no later than the slowest Arc trim does, as a problem line.
local function quickerRivals(rivals: { Entry }, speed: number, label: string): { string }
	local slowestArc = 0
	for _, arc in entries(true) do
		slowestArc = math.max(slowestArc, Powertrain.simulateTimeToSpeed(arc.tuning, "standard", speed))
	end
	local problems: { string } = {}
	if slowestArc == math.huge then
		table.insert(problems, `an Arc trim never reaches {label}`)
		return problems
	end
	for _, rival in rivals do
		-- Cut off at the slowest Arc's time: a rival still short of the speed by then is slower.
		local seconds = Powertrain.simulateTimeToSpeed(rival.tuning, "standard", speed, slowestArc)
		if seconds <= slowestArc then
			table.insert(problems, `{rival.name} reaches {label} in {seconds} s, the slowest Arc in {slowestArc} s`)
		end
	end
	return problems
end

-- Every one of `rivals` that gets to 60 or 100 mph as soon as an Arc trim.
local function quickerToSpeed(rivals: { Entry }): { string }
	local problems = quickerRivals(rivals, Units.mphToStuds(60), "60 mph")
	for _, line in quickerRivals(rivals, Units.mphToStuds(HUNDRED_MPH), `{HUNDRED_MPH} mph`) do
		table.insert(problems, line)
	end
	return problems
end

-- Every Arc trim that launches no harder than one of `rivals`, or pulls no harder at some speed up to its top.
local function harderPull(rivals: { Entry }): { string }
	local problems: { string } = {}
	local step = Units.mphToStuds(SPEED_STEP_MPH)
	for _, arc in entries(true) do
		for _, rival in rivals do
			if arc.tuning.peakAccel <= rival.tuning.peakAccel then
				table.insert(problems, `{arc.name} launches no harder than {rival.name}`)
			end
			local speed = 0
			while speed <= rival.tuning.topSpeed do
				if pull(arc.tuning, speed) <= pull(rival.tuning, speed) then
					local mph = math.round(Units.studsToMph(speed))
					table.insert(problems, `{arc.name} pulls no harder than {rival.name} at {mph} mph`)
					break
				end
				speed += step
			end
		end
	end
	return problems
end

-- Every Arc trim with no more grip, cornering or traction than one of `rivals`.
local function moreGrip(rivals: { Entry }): { string }
	local problems: { string } = {}
	for _, arc in entries(true) do
		for _, rival in rivals do
			local a, r = arc.tuning, rival.tuning
			if a.grip <= r.grip then
				table.insert(problems, `{arc.name} grip {a.grip} vs {rival.name} {r.grip}`)
			end
			if a.lateralGripRate <= r.lateralGripRate then
				table.insert(problems, `{arc.name} cornering {a.lateralGripRate} vs {rival.name}`)
			end
			if a.tractionLimit <= r.tractionLimit then
				table.insert(problems, `{arc.name} traction {a.tractionLimit} vs {rival.name}`)
			end
		end
	end
	return problems
end

return function(t: Harness.Api)
	t.describe("Tuning", function()
		t.it("returns positive, finite numbers for every trim", function()
			local problems: { string } = {}
			forEachTrim(function(vehicleId, trimId)
				local tuning = Tuning.forTrim(vehicleId, trimId)
				if tuning == nil then
					table.insert(problems, `{vehicleId}/{trimId}: no tuning`)
					return
				end
				for _, field in badFields(tuning :: any) do
					table.insert(problems, `{vehicleId}/{trimId}: {field}`)
				end
			end)
			t.expect(problems).toEqual({})
		end)

		t.it("returns nil for an unknown trim or vehicle", function()
			t.expect(Tuning.forTrim("ohm_spark", "no_such_trim")).toBe(nil)
			t.expect(Tuning.forTrim("no_such_vehicle", "standard")).toBe(nil)
		end)

		t.it("caches each trim", function()
			t.expect(Tuning.forTrim("ohm_arc", "performance")).toBe(Tuning.forTrim("ohm_arc", "performance"))
		end)

		t.it("puts the hubs where the model contract puts the wheel attachments", function()
			local problems: { string } = {}
			forEachTrim(function(vehicleId, trimId)
				local tuning = Tuning.forTrim(vehicleId, trimId)
				local g = Catalog.geometry(vehicleId, trimId)
				assert(tuning, `{vehicleId}/{trimId} has a tuning`)
				assert(g, `{vehicleId}/{trimId} has a geometry`)
				local y = g.wheelRadius - (g.rideHeight + g.chassisHeight / 2)
				local expected: { [Tuning.WheelId]: Vector3 } = {
					FL = Vector3.new(-g.track / 2, y, -g.wheelbase / 2),
					FR = Vector3.new(g.track / 2, y, -g.wheelbase / 2),
					RL = Vector3.new(-g.track / 2, y, g.wheelbase / 2),
					RR = Vector3.new(g.track / 2, y, g.wheelbase / 2),
				}
				for id, position in expected do
					if (tuning.hubs[id] - position).Magnitude > HUB_TOLERANCE then
						table.insert(problems, `{vehicleId}/{trimId}: hub {id} at {tuning.hubs[id]}`)
					end
				end
			end)
			t.expect(problems).toEqual({})
		end)

		t.it("has the grip to put every drivable trim's launch down", function()
			local problems: { string } = {}
			forEachTrim(function(vehicleId, trimId, drivable)
				local tuning = Tuning.forTrim(vehicleId, trimId)
				assert(tuning, `{vehicleId}/{trimId} exists`)
				if drivable and tuning.tractionLimit < tuning.peakAccel * GRIP_MARGIN then
					table.insert(
						problems,
						`{vehicleId}/{trimId}: traction {tuning.tractionLimit} vs peak {tuning.peakAccel}`
					)
				end
			end)
			t.expect(problems).toEqual({})
		end)

		t.it("gives better-handling trims more grip and quicker cars a higher peak", function()
			local arc = Tuning.forTrim("ohm_arc", "performance")
			local hauler = Tuning.forTrim("ohm_hauler", "standard")
			local spark = Tuning.forTrim("ohm_spark", "standard")
			assert(arc and hauler and spark, "tunings exist")
			t.expect(arc.grip).toBeGreaterThan(spark.grip)
			t.expect(spark.grip).toBeGreaterThan(hauler.grip)
			t.expect(arc.peakAccel).toBeGreaterThan(spark.peakAccel)
			t.expect(arc.topSpeed).toBeGreaterThan(spark.topSpeed)
		end)

		t.it("brakes harder than it accelerates for everyday cars", function()
			local spark = Tuning.forTrim("ohm_spark", "standard")
			assert(spark, "spark tuning")
			t.expect(spark.brakeDecel).toBeGreaterThan(spark.peakAccel)
		end)
	end)

	t.describe("Arc tuning", function()
		t.it("keeps every Arc trim inside the hypercar band", function()
			local vehicle = Catalog.getVehicle(ARC)
			assert(vehicle, "the Arc is in the catalog")
			t.expect(vehicle.class).toBe(HYPERCAR)
			local band = Classes[HYPERCAR]
			local problems: { string } = {}
			for _, trim in vehicle.trims do
				local zeroToSixty, handling = trim.zeroToSixtySec, trim.handling
				if zeroToSixty < band.zeroToSixtySec.min or zeroToSixty > band.zeroToSixtySec.max then
					table.insert(problems, `{trim.id}: 0-60 {zeroToSixty}`)
				end
				if handling < band.handling.min or handling > band.handling.max then
					table.insert(problems, `{trim.id}: handling {handling}`)
				end
			end
			t.expect(problems).toEqual({})
		end)

		t.it("gets every Arc trim to 60 and 100 mph before any other car", function()
			t.expect(quickerToSpeed(entries(false))).toEqual({})
		end)

		t.it("gives every Arc trim the strongest launch and the hardest pull at every speed", function()
			t.expect(harderPull(entries(false))).toEqual({})
		end)

		t.it("gives every Arc trim more grip than any other car", function()
			t.expect(moreGrip(entries(false))).toEqual({})
		end)

		t.it("keeps every car the AI Car Designer can make behind every Arc trim", function()
			local designs = designEntries(kit)
			if designs == nil then
				print("  Tuning.spec: designs publish on the server only; skipped here")
				return
			end
			local problems = quickerToSpeed(designs)
			for _, list in { harderPull(designs), moreGrip(designs) } do
				for _, line in list do
					table.insert(problems, line)
				end
			end
			t.expect(problems).toEqual({})
		end)

		-- Prove the design check fires: a fuel car designed at the very best of the hypercar band (no ceiling) is no
		-- car the kit can make, and it out-launches the Arc.
		t.it("catches a design that out-launches the Arc", function()
			local forced = table.clone(kit)
			forced.bandCeiling = 1
			forced.personalities = { launch = { acceleration = 1, topSpeed = 1, handling = 1, range = 0 } }
			forced.classes = { [HYPERCAR] = { templates = kit.classes.exotic.templates, energy = { "fuel" } } }
			local designs = designEntries(forced)
			if designs == nil then
				print("  Tuning.spec: designs publish on the server only; skipped here")
				return
			end
			t.expect(#harderPull(designs) > 0).toBe(true)
		end)

		t.it("beats the best 0-60 and handling any other class band allows", function()
			local vehicle = Catalog.getVehicle(ARC)
			assert(vehicle, "the Arc is in the catalog")
			local problems: { string } = {}
			for classId, class in Classes do
				if classId == HYPERCAR then
					continue
				end
				for _, trim in vehicle.trims do
					if trim.zeroToSixtySec >= class.zeroToSixtySec.min then
						table.insert(problems, `{trim.id}: 0-60 not under the {classId} band's best`)
					end
					if trim.handling <= class.handling.max then
						table.insert(problems, `{trim.id}: handling not over the {classId} band's best`)
					end
				end
			end
			t.expect(problems).toEqual({})
		end)
	end)
end
