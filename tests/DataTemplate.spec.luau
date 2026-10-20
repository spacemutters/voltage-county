--!strict
-- A fresh PlayerData profile (PLAN.md §4 and §6; docs/phase-3-contracts.md "Player data").
-- Pure logic: runs in Edit mode.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Data = require(ReplicatedStorage.Shared.Config.Data)
local Economy = require(ReplicatedStorage.Shared.Config.Economy)
local Garage = require(ReplicatedStorage.Shared.Config.Garage)
local Harness = require(ReplicatedStorage.Shared.Testing.Harness)
local Template = require(ServerScriptService.Server.Services.DataService.Template)

local JOIN_TIME = 1700000000 -- any fixed os.time()

-- Every PlayerData field (Types.PlayerData) and the Luau type it must have. Nested tables list their fields.
local SHAPE: { [string]: any } = {
	version = "number",
	cash = "number",
	starterClaimed = "boolean",
	vehicles = "table",
	garageSlots = "number",
	designs = "table",
	customSlots = "number",
	credits = { balance = "number", freeDesignUsed = "boolean", reserved = "table" },
	fleet = { pods = "table", lastCollectedAt = "number" },
	jobs = { xp = "table", licenses = "table" },
	house = { upgrades = "table" },
	stats = { milesDriven = "number", tripsCompleted = "number", playtimeSec = "number" },
	codesRedeemed = "table",
	season = { id = "string", xp = "number", premium = "boolean", claimed = "table" },
	streak = { lastDay = "number", count = "number" },
	offersSeen = "table",
	club = "table", -- lastGrantMonth is optional and starts unset
	receipts = "table",
	pendingGrants = "table",
	settings = { units = "string", camera = "string", musicVolume = "number" },
	firstJoinAt = "number",
	boosts = "table",
}

-- Every field a new owned car (Types.OwnedVehicle, schema version 3) starts with. The optional fields (designUid,
-- wrap, plateText, mods, serial) start unset.
local OWNED_VEHICLE_SHAPE: { [string]: any } = {
	uid = "string",
	vehicleId = "string",
	trim = "string",
	paint = "string",
	finish = "string",
	wheels = "string",
	rideHeight = "number",
	tint = "number",
	acquiredAt = "number",
	favorite = "boolean",
	paid = "number",
}

-- Checks `value` against `shape`, adding one line per mismatch (with its path) to `problems`.
local function shapeProblems(value: any, shape: any, path: string, problems: { string })
	if type(shape) == "string" then
		if type(value) ~= shape then
			table.insert(problems, `{path} is {type(value)}, expected {shape}`)
		end
		return
	end
	if type(value) ~= "table" then
		table.insert(problems, `{path} is {type(value)}, expected table`)
		return
	end
	for key, fieldShape in shape do
		shapeProblems(value[key], fieldShape, `{path}.{key}`, problems)
	end
	for key in value do
		if shape[key] == nil then
			table.insert(problems, `{path}.{tostring(key)} is not a PlayerData field`)
		end
	end
end

-- Every table inside `value`, keyed by itself, with the path it was found at.
local function tablesIn(value: any, path: string, found: { [any]: string })
	if type(value) ~= "table" then
		return
	end
	found[value] = path
	for key, item in value do
		tablesIn(item, `{path}.{tostring(key)}`, found)
	end
end

return function(t: Harness.Api)
	t.describe("DataTemplate", function()
		t.it("has every PlayerData field with the right type and nothing else", function()
			local problems = {}
			shapeProblems(Template.new(JOIN_TIME), SHAPE, "data", problems)
			t.expect(table.concat(problems, "; ")).toBe("")
		end)

		t.it("starts at the schema version with the configured economy values", function()
			local data = Template.new(JOIN_TIME)
			t.expect(data.version).toBe(Data.schemaVersion)
			t.expect(data.cash).toBe(Economy.startingCash)
			t.expect(data.garageSlots).toBe(Economy.garageSlots)
			t.expect(data.customSlots).toBe(Economy.customSlots)
			t.expect(data.credits.balance).toBe(Data.defaults.credits)
			t.expect(data.credits.freeDesignUsed).toBe(false)
			t.expect(data.starterClaimed).toBe(false)
		end)

		t.it("starts with empty collections", function()
			local data = Template.new(JOIN_TIME)
			t.expect(data.vehicles).toEqual({})
			t.expect(data.designs).toEqual({})
			t.expect(data.boosts).toEqual({})
			t.expect(data.receipts).toEqual({})
			t.expect(data.codesRedeemed).toEqual({})
			t.expect(data.pendingGrants).toEqual({})
			t.expect(data.fleet.pods).toEqual({})
		end)

		t.it("uses the default settings", function()
			local settings = Template.new(JOIN_TIME).settings
			t.expect(settings.units).toBe("mph")
			t.expect(settings.camera).toBe("chase")
			t.expect(settings.musicVolume).toBe(0.5)
			t.expect(settings).toEqual(Data.defaults.settings)
		end)

		t.it("stamps the join time, defaulting to now", function()
			t.expect(Template.new(JOIN_TIME).firstJoinAt).toBe(JOIN_TIME)
			t.expect(Template.new(JOIN_TIME).fleet.lastCollectedAt).toBe(JOIN_TIME)
			local before = os.time()
			local data = Template.new()
			t.expect(data.firstJoinAt >= before and data.firstJoinAt <= os.time()).toBe(true)
		end)

		t.it("stamps unset time fields once and leaves real ones alone", function()
			local fresh = Template.new(Template.UNSET_TIME)
			t.expect(Template.stamp(fresh, JOIN_TIME)).toBe(true)
			t.expect(fresh.firstJoinAt).toBe(JOIN_TIME)
			t.expect(fresh.fleet.lastCollectedAt).toBe(JOIN_TIME)
			t.expect(Template.stamp(fresh, JOIN_TIME + 60)).toBe(false)
			t.expect(fresh.firstJoinAt).toBe(JOIN_TIME)
		end)

		t.it("makes a new owned car with every field and the default look", function()
			local car = Template.ownedVehicle("car-1", "ohm_spark", "standard", 35000, JOIN_TIME)
			local problems = {}
			shapeProblems(car, OWNED_VEHICLE_SHAPE, "car", problems)
			t.expect(table.concat(problems, "; ")).toBe("")
			t.expect(car.uid).toBe("car-1")
			t.expect(car.vehicleId).toBe("ohm_spark")
			t.expect(car.trim).toBe("standard")
			t.expect(car.paid).toBe(35000)
			t.expect(car.acquiredAt).toBe(JOIN_TIME)
			t.expect(car.favorite).toBe(false)
			t.expect(car.paint).toBe(Garage.defaults.paint)
			t.expect(car.finish).toBe(Garage.defaults.finish)
			t.expect(car.wheels).toBe(Garage.defaults.wheels)
			t.expect(car.rideHeight).toBe(0)
			t.expect(car.tint).toBe(0)
		end)

		t.it("records a free car as paid 0", function()
			t.expect(Template.ownedVehicle("car-2", "ohm_spark", "used", 0, JOIN_TIME).paid).toBe(0)
		end)

		t.it("never shares a table between two templates or with Config", function()
			local a = Template.new(JOIN_TIME)
			local b = Template.new(JOIN_TIME)
			t.expect(a).toEqual(b)
			local inA: { [any]: string } = {}
			tablesIn(a, "a", inA)
			local inB: { [any]: string } = {}
			tablesIn(b, "b", inB)
			for tbl in inA do
				t.expect(inB[tbl]).toBe(nil) -- on failure, shows the path in b that holds a's table
				t.expect(tbl == Data.defaults.settings).toBe(false)
			end
			-- Changing one profile leaves the other and the defaults alone.
			table.insert(a.boosts, { id = "x", factor = 2, endsAt = JOIN_TIME })
			a.settings.musicVolume = 1
			t.expect(#b.boosts).toBe(0)
			t.expect(b.settings.musicVolume).toBe(0.5)
			t.expect(Data.defaults.settings.musicVolume).toBe(0.5)
		end)
	end)
end
