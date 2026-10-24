--!strict
-- Every client -> server remote's validator against a hostile corpus (PLAN.md Phase 14; docs/phase-14-contracts.md
-- "Security"). Dev/FuzzTests holds the corpus (NaN, -0, infinities, huge, negative and fractional numbers, booleans,
-- empty, 100k-character, broken-UTF-8 and NUL-carrying strings, Vector3 / CFrame / Color3 / an Instance, empty, list,
-- 50-deep, 10k-key and mixed tables, a 10k-item list), a valid sample for every remote and the cases built from
-- them: each hostile value as the whole payload and, for a shape, the sample with each field (nested ones too)
-- swapped for each hostile value and with keys it doesn't declare. A validator must never throw, must take its
-- sample and whatever FuzzTests.SAMPLES says still fits there (nil for an optional field, "" for a plate...), and must
-- refuse everything else. Plus Util/Check's hardening (empty and NUL strings, -0 integers, over-long lists) and
-- Services/DevFuzzService's pure parts (the economy snapshot, its diff, the expected log lines). Dev/FuzzTests sends
-- the same cases through the real network in a playtest. Pure logic: runs in Edit mode, well under a second.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local StarterPlayer = game:GetService("StarterPlayer")

local Check = require(ReplicatedStorage.Shared.Util.Check)
local Harness = require(ReplicatedStorage.Shared.Testing.Harness)
local Net = require(ReplicatedStorage.Shared.Net)
local DevFuzzService = require(ServerScriptService.Server.Services.DevFuzzService)
local Template = require(ServerScriptService.Server.Services.DataService.Template)
local FuzzTests = require(StarterPlayer.StarterPlayerScripts.Client.Dev.FuzzTests)

local JOIN_TIME = 1700000000 -- any fixed os.time()
local MAX_SHOWN = 15 -- failures listed in one assertion's message
local TIME_BUDGET = 2 -- seconds the whole validator sweep may take
local MIN_CASES = 1000 -- the sweep must really have run (about 54 remotes x 25 values, and the fields)

-- The hostile values the contract names, by FuzzTests tag.
local CONTRACT_TAGS = {
	"nil",
	"nan",
	"inf",
	"-inf",
	"-0",
	"huge",
	"fraction",
	"true",
	"false",
	"emptyString",
	"longString",
	"badUtf8",
	"nulString",
	"vector3",
	"cframe",
	"color3",
	"instance",
	"emptyTable",
	"array",
	"deepTable",
	"wideTable",
	"mixedTable",
}

local declared = Net.declared()

-- Every client -> server remote, sorted.
local function toServer(): { string }
	local names: { string } = {}
	for name, spec in declared do
		if spec.direction == "toServer" then
			table.insert(names, name)
		end
	end
	table.sort(names)
	return names
end

-- "" for no failures, else the first MAX_SHOWN of them (and how many more), one per line.
local function listed(failures: { string }): string
	if #failures == 0 then
		return ""
	end
	local shown = table.move(failures, 1, math.min(#failures, MAX_SHOWN), 1, {})
	if #failures > MAX_SHOWN then
		table.insert(shown, `...and {#failures - MAX_SHOWN} more`)
	end
	return table.concat(shown, "\n")
end

-- A remote's cases ({} without a sample: the sample test reports that).
local function casesFor(name: string): { FuzzTests.Case }
	local list: { FuzzTests.Case } = FuzzTests.cases(name) or {}
	return list
end

local function hostileByTag(): { [string]: any }
	local byTag: { [string]: any } = {}
	for _, item in FuzzTests.hostile() do
		byTag[item.tag] = item
	end
	return byTag
end

-- Every field path of a sample payload ("changes.tint"), nested shapes included.
local function samplePaths(value: any, prefix: string, into: { [string]: boolean })
	if type(value) ~= "table" then
		return
	end
	for key, item in value do
		if type(key) == "string" then
			local path = if prefix == "" then key else `{prefix}.{key}`
			into[path] = true
			samplePaths(item, path, into)
		end
	end
end

local function keyCount(value: { [any]: any }): number
	local count = 0
	for _ in value do
		count += 1
	end
	return count
end

-- A fresh profile with one car (and, with `more`, that many more), as DevFuzzService reads it.
local function profile(more: number?): any
	local data: any = Template.new(JOIN_TIME)
	table.insert(data.vehicles, Template.ownedVehicle("car-1", "fuzz_car", "base", 1000, JOIN_TIME))
	for index = 1, more or 0 do
		table.insert(data.vehicles, Template.ownedVehicle(`car-x{index}`, "fuzz_car", "base", 1000, JOIN_TIME))
	end
	return data
end

return function(t: Harness.Api)
	t.describe("NetFuzz corpus", function()
		t.it("has a fuzz sample for every client -> server remote, and none for anything else", function()
			local problems: { string } = {}
			for _, name in toServer() do
				if FuzzTests.SAMPLES[name] == nil then
					table.insert(problems, `{name}: no sample in Dev/FuzzTests SAMPLES`)
				end
			end
			for name in FuzzTests.SAMPLES do
				local spec = declared[name]
				if spec == nil or spec.direction ~= "toServer" then
					table.insert(problems, `{name}: a sample for a remote that isn't a client -> server remote`)
				end
			end
			t.expect(listed(problems)).toBe("")
		end)

		t.it("holds every hostile value the contract names", function()
			local byTag = hostileByTag()
			for _, tag in CONTRACT_TAGS do
				t.expect(byTag[tag] ~= nil).toBe(true)
			end
			t.expect(byTag["nil"].value).toBe(nil)
			t.expect(byTag.nan.value ~= byTag.nan.value).toBe(true)
			t.expect(1 / byTag["-0"].value).toBe(-math.huge) -- really negative zero
			t.expect(#byTag.longString.value).toBe(100000)
			t.expect((utf8.len(byTag.badUtf8.value))).toBe(nil)
			t.expect(string.find(byTag.nulString.value, "\0", 1, true) ~= nil).toBe(true)
			t.expect(keyCount(byTag.wideTable.value)).toBe(10000)
			t.expect(typeof(byTag.instance.value)).toBe("Instance")
			local mixed = byTag.mixedTable.value
			t.expect(mixed[1] ~= nil and mixed.fuzz ~= nil).toBe(true)
			local depth, node = 0, byTag.deepTable.value
			while type(node) == "table" do
				depth += 1
				node = node.next
			end
			t.expect(depth).toBe(50)
		end)

		t.it("lets only harmless values fit, and only at fields the sample has", function()
			local problems: { string } = {}
			for name, sample in FuzzTests.SAMPLES do
				local paths: { [string]: boolean } = { [""] = true }
				samplePaths(sample.payload, "", paths)
				local fits: { [string]: { string } } = sample.fits or {}
				for path, tags in fits do
					if not paths[path] then
						table.insert(problems, `{name}: fits names "{path}", which the sample doesn't have`)
					end
					for _, tag in tags do
						if table.find(FuzzTests.FITS_TAGS, tag) == nil then
							table.insert(problems, `{name}: "{tag}" may not fit anywhere ({path})`)
						end
					end
				end
			end
			t.expect(listed(problems)).toBe("")
		end)
	end)

	t.describe("NetFuzz validators", function()
		t.it("never throw, take their sample and what fits, and refuse every other hostile payload", function()
			local started = os.clock()
			local failures: { string } = {}
			local total = 0
			for _, name in toServer() do
				local validate = declared[name].validate
				for _, case in casesFor(name) do
					total += 1
					local ok, taken = pcall(validate, case.payload)
					if not ok then
						table.insert(failures, `{name} {case.label}: threw {taken}`)
					elseif type(taken) ~= "boolean" then
						table.insert(failures, `{name} {case.label}: answered {typeof(taken)}, not true or false`)
					elseif taken ~= case.fits then
						local what = if taken then "taken, but must be refused" else "refused, but it fits"
						table.insert(failures, `{name} {case.label}: {what}`)
					end
				end
			end
			local elapsed = os.clock() - started
			t.expect(listed(failures)).toBe("")
			t.expect(total).toBeGreaterThan(MIN_CASES)
			t.expect(elapsed).toBeLessThan(TIME_BUDGET)
		end)

		t.it("refuse NaN and infinities in every field and as the whole payload", function()
			local failures: { string } = {}
			for _, name in toServer() do
				local validate = declared[name].validate
				for _, case in casesFor(name) do
					local tag = string.match(case.label, " (%S+)$")
					if (tag == "nan" or tag == "inf" or tag == "-inf") and validate(case.payload) then
						table.insert(failures, `{name} {case.label}`)
					end
				end
			end
			t.expect(listed(failures)).toBe("")
		end)
	end)

	t.describe("Check hardening", function()
		t.it("refuses empty and NUL-carrying strings unless a remote allows empty", function()
			local id = Check.string(8)
			t.expect(id("ok")).toBe(true)
			t.expect(id("")).toBe(false)
			t.expect(id("a\0b")).toBe(false)
			local clearable = Check.string(8, 0)
			t.expect(clearable("")).toBe(true)
			t.expect(clearable("\0")).toBe(false)
			t.expect(clearable("123456789")).toBe(false)
		end)

		t.it("refuses -0 where an integer is wanted, and reads it as 0 for a plain number", function()
			local negativeZero = hostileByTag()["-0"].value
			t.expect(1 / negativeZero).toBe(-math.huge)
			t.expect(Check.integer(0, 5)(0)).toBe(true)
			t.expect(Check.integer(0, 5)(negativeZero)).toBe(false)
			t.expect(Check.number(0, 1)(negativeZero)).toBe(true)
			t.expect(Check.number(0.5, 1)(negativeZero)).toBe(false)
		end)

		t.it("refuses an over-long list as soon as it sees one", function()
			local list = Check.array(Check.string(4), 8)
			t.expect(list(table.create(8, "a"))).toBe(true)
			t.expect(list(table.create(9, "a"))).toBe(false)
			t.expect(list(table.create(10000, "a"))).toBe(false)
		end)

		t.it("lets SetPlate clear a plate with empty text, and no id be empty", function()
			t.expect(declared.SetPlate.validate({ uid = "car", text = "" })).toBe(true)
			t.expect(declared.SetPlate.validate({ uid = "", text = "AB" })).toBe(false)
			t.expect(declared.BuyVehicle.validate({ vehicleId = "", trim = "base" })).toBe(false)
			t.expect(declared.RedeemCode.validate("")).toBe(false)
		end)
	end)

	t.describe("DevFuzzService", function()
		t.it("reads equal values the same whatever order their keys were added in", function()
			local first: { [string]: any } = {}
			first.a = 1
			first.b = { c = "x", d = { 1, 2 } }
			local second: { [string]: any } = {}
			second.b = { d = { 1, 2 }, c = "x" }
			second.a = 1
			t.expect(DevFuzzService.canonical(first)).toBe(DevFuzzService.canonical(second))
			t.expect(DevFuzzService.canonical(first) == DevFuzzService.canonical({ a = 2, b = first.b })).toBe(false)
		end)

		t.it("ignores what moves on its own", function()
			local data = profile()
			local before = DevFuzzService.economyOf(data)
			data.vehicles[1].energy = 0.25
			data.vehicles[1].favorite = true
			data.jobs.xp.delivery = 500
			data.season.xp = 900
			data.fleet.uncollected = 42.5
			data.fleet.lastOnlineAt = JOIN_TIME + 60
			data.stats.milesDriven = 12
			data.settings.musicVolume = 0.1
			t.expect(keyCount(DevFuzzService.diff(before, DevFuzzService.economyOf(data)))).toBe(0)
		end)

		t.it("reports cash, credits, a car's look and a new car", function()
			local data = profile()
			local before = DevFuzzService.economyOf(data)
			data.cash += 500
			data.credits.balance += 1
			data.vehicles[1].paint = "fuzz_paint"
			table.insert(data.vehicles, Template.ownedVehicle("car-2", "fuzz_car", "base", 0, JOIN_TIME))
			data.jobs.licenses.freight = true
			local changed = DevFuzzService.diff(before, DevFuzzService.economyOf(data))
			t.expect(changed.cash ~= nil).toBe(true)
			t.expect(changed.credits ~= nil).toBe(true)
			t.expect(changed.vehicles ~= nil).toBe(true)
			t.expect(changed.jobs ~= nil).toBe(true)
			t.expect(keyCount(changed)).toBe(4)
			t.expect(changed.cash.before).toBe(tostring(before.cash))
			t.expect(changed.cash.after).toBe(tostring(data.cash))
		end)

		t.it("cuts a long value around its first difference", function()
			local data = profile(60)
			local before = DevFuzzService.economyOf(data)
			data.vehicles[#data.vehicles].paint = "fuzz_paint"
			local change = DevFuzzService.diff(before, DevFuzzService.economyOf(data)).vehicles
			t.expect(change ~= nil).toBe(true)
			t.expect(#change.after).toBeLessThan(#DevFuzzService.economyOf(data).vehicles)
			t.expect(string.find(change.after, "fuzz_paint", 1, true) ~= nil).toBe(true)
			t.expect(string.find(change.before, "fuzz_paint", 1, true) == nil).toBe(true)
		end)

		t.it("leaves out only the lines a fuzz run is meant to cause", function()
			local summary = "[AntiExploit] Player1 (1): 12 rejected remote call(s), latest BuyVehicle (payload)"
			t.expect(DevFuzzService.expected(summary)).toBe(true)
			t.expect(DevFuzzService.expected("ServerScriptService.Server.Services.X:10: attempt to index nil"))
				.toBe(false)
			t.expect(DevFuzzService.expected("[AntiExploit] Player1 (1): teleport, 3 strikes")).toBe(false)
			-- The ClaimGoal sample's id is on nobody's list (GoalsService warns once a player).
			t.expect(
				DevFuzzService.expected("[GoalsService] Player1 (1) claimed a goal that isn't theirs today: fuzz-id")
			)
				.toBe(true)
			t.expect(DevFuzzService.expected("[GoalsService] no JobService: its goals won't count")).toBe(false)
		end)
	end)
end
