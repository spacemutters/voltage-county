--!strict
-- PlayerData migrations (CLAUDE.md hard rule 7; PLAN.md Phase 3 acceptance: migration specs pass).
-- Pure logic: runs in Edit mode.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Data = require(ReplicatedStorage.Shared.Config.Data)
local Harness = require(ReplicatedStorage.Shared.Testing.Harness)
local Migrations = require(ServerScriptService.Server.Services.DataService.Migrations)
local Template = require(ServerScriptService.Server.Services.DataService.Template)

local JOIN_TIME = 1700000000 -- any fixed os.time()

-- A version 1 save as the Phase 1-2 template wrote it (no boosts), with some player-owned data in it.
local function v1Save(): { [string]: any }
	local data: { [string]: any } = Template.new(JOIN_TIME) :: any
	data.version = 1
	data.boosts = nil
	data.cash = 48250
	data.vehicles = {
		{
			uid = "car-1",
			vehicleId = "ohm_spark",
			trim = "base",
			paint = "white",
			finish = "gloss",
			wheels = "stock",
			rideHeight = 0,
			tint = 0.2,
			acquiredAt = JOIN_TIME,
		},
	}
	data.codesRedeemed = { LAUNCH = true }
	data.receipts = { "purchase-1", "purchase-2" }
	return data
end

local function keysOf(t: { [any]: any }): { [string]: boolean }
	local keys = {}
	for key in t do
		keys[tostring(key)] = true
	end
	return keys
end

local function deepCopy(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local copy = {}
	for key, item in value do
		copy[key] = deepCopy(item)
	end
	return copy
end

return function(t: Harness.Api)
	t.describe("Migrations", function()
		t.it("has a step from every older version up to the schema version", function()
			for version = Data.unversionedVersion, Data.schemaVersion - 1 do
				t.expect(type(Migrations.steps[version])).toBe("function")
			end
		end)

		t.it("upgrades a version 1 save without boosts to version 2 with boosts = {}", function()
			local migrated, fromVersion = Migrations.run(v1Save())
			t.expect(fromVersion).toBe(1)
			t.expect(migrated.version).toBe(Data.schemaVersion)
			t.expect(migrated.boosts).toEqual({})
		end)

		t.it("treats a save with no version field as version 1", function()
			local save = v1Save()
			save.version = nil
			local migrated, fromVersion = Migrations.run(save)
			t.expect(fromVersion).toBe(Data.unversionedVersion)
			t.expect(fromVersion).toBe(1)
			t.expect(migrated.version).toBe(Data.schemaVersion)
			t.expect(migrated.boosts).toEqual({})
		end)

		t.it("never drops a field and keeps every player-owned value", function()
			local before = v1Save()
			local snapshot = deepCopy(before)
			local migrated = Migrations.run(before)
			local after = keysOf(migrated)
			for key in keysOf(snapshot) do
				t.expect(after[key]).toBe(true)
			end
			for key, value in snapshot do
				if key ~= "version" then
					t.expect(migrated[key]).toEqual(value)
				end
			end
		end)

		t.it("keeps boosts a version 1 save somehow already has", function()
			local save = v1Save()
			save.boosts = { { id = "LAUNCH2X", factor = 2, endsAt = JOIN_TIME + 1800 } }
			local migrated = Migrations.run(save)
			t.expect(#migrated.boosts).toBe(1)
			t.expect(migrated.boosts[1].factor).toBe(2)
		end)

		t.it("leaves a save at the latest version unchanged (idempotent)", function()
			local current: { [string]: any } = Template.new(JOIN_TIME) :: any
			current.cash = 777
			local snapshot = deepCopy(current)
			local migrated, fromVersion = Migrations.run(current)
			t.expect(fromVersion).toBe(Data.schemaVersion)
			t.expect(migrated).toEqual(snapshot)
			local again, againFrom = Migrations.run(migrated)
			t.expect(againFrom).toBe(Data.schemaVersion)
			t.expect(again).toEqual(snapshot)
		end)

		t.it("refuses a save from a newer version and leaves it untouched", function()
			local future: { [string]: any } = Template.new(JOIN_TIME) :: any
			future.version = Data.schemaVersion + 1
			future.somethingNew = { kept = true }
			local snapshot = deepCopy(future)
			t.expect(function()
				Migrations.run(future)
			end).toThrow("newer")
			t.expect(future).toEqual(snapshot)
		end)

		t.it("refuses a nonsense version", function()
			for _, bad in { 0, -1, 1.5, "2" } :: { any } do
				local save = v1Save()
				save.version = bad
				t.expect(function()
					Migrations.run(save)
				end).toThrow("invalid")
			end
		end)
	end)
end
