--!strict
-- The garage rules (Services/GarageService pure helpers, Config/Garage) and the profile snapshot
-- (Services/ProfileSyncService.snapshot), docs/phase-4-contracts.md "Data changes": the sell-back price, which
-- cars can be sold, the favorites-first order, garage room, settings validation, and that a snapshot carries
-- only the sanitized fields as fresh copies. Pure logic on fixtures: runs in Edit mode.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Catalog = require(ReplicatedStorage.Shared.Vehicle.Catalog)
local Customization = require(ReplicatedStorage.Shared.Config.Customization)
local Data = require(ReplicatedStorage.Shared.Config.Data)
local Economy = require(ReplicatedStorage.Shared.Config.Economy)
local Garage = require(ReplicatedStorage.Shared.Config.Garage)
local Harness = require(ReplicatedStorage.Shared.Testing.Harness)
local Monetization = require(ReplicatedStorage.Shared.Config.Monetization)
local Types = require(ReplicatedStorage.Shared.Types)
local GarageService = require(ServerScriptService.Server.Services.GarageService)
local ProfileSyncService = require(ServerScriptService.Server.Services.ProfileSyncService)
local Template = require(ServerScriptService.Server.Services.DataService.Template)

local JOIN_TIME = 1700000000 -- any fixed os.time()

local function car(uid: string, vehicleId: string, trim: string, paid: number, acquiredAt: number?): Types.OwnedVehicle
	return Template.ownedVehicle(uid, vehicleId, trim, paid, acquiredAt or JOIN_TIME)
end

local function profileWith(vehicles: { Types.OwnedVehicle }): Types.PlayerData
	local data = Template.new(JOIN_TIME)
	data.vehicles = vehicles
	return data
end

local function uidsOf(vehicles: { any }): { string }
	local uids = {}
	for _, vehicle in vehicles do
		table.insert(uids, vehicle.uid)
	end
	return uids
end

return function(t: Harness.Api)
	t.describe("Garage sell price", function()
		t.it("pays 60% of what was paid, rounded down", function()
			t.expect(Garage.sellBackRate).toBe(0.6)
			t.expect(Garage.sellPrice(35000)).toBe(21000)
			t.expect(Garage.sellPrice(999)).toBe(599) -- 599.4
			t.expect(Garage.sellPrice(1)).toBe(0) -- 0.6
			t.expect(GarageService.sellPrice(45000)).toBe(27000)
		end)

		t.it("is never below zero, and 0 for a damaged price", function()
			for _, bad in { 0, -500, 0 / 0, math.huge, -math.huge, "100", nil :: any } :: { any } do
				t.expect(Garage.sellPrice(bad)).toBe(0)
			end
		end)
	end)

	t.describe("Garage sell rules", function()
		t.it("sells a bought car", function()
			local ok, message = GarageService.sellCheck(car("a", "ohm_spark", "standard", 35000))
			t.expect(ok).toBe(true)
			t.expect(message).toBe(nil)
		end)

		t.it("keeps the free starter, whatever its paid says", function()
			t.expect(Catalog.getTrim("ohm_spark", "used") ~= nil).toBe(true)
			local starter = car("s", "ohm_spark", "used", 0)
			t.expect(GarageService.isStarter(starter)).toBe(true)
			local ok, message = GarageService.sellCheck(starter)
			t.expect(ok).toBe(false)
			t.expect(message).toBe(Garage.messages.starterKept)
			-- A forged or damaged paid never makes the starter sellable.
			local ok2 = GarageService.sellCheck(car("s2", "ohm_spark", "used", 50000))
			t.expect(ok2).toBe(false)
		end)

		t.it("won't sell a design or a car with no trade-in value", function()
			local okCustom, customMessage = GarageService.sellCheck(car("d", Garage.customVehicleId, "base", 9000))
			t.expect(okCustom).toBe(false)
			t.expect(customMessage).toBe(Garage.messages.customKept)
			local okFree, freeMessage = GarageService.sellCheck(car("f", "ohm_spark", "standard", 0))
			t.expect(okFree).toBe(false)
			t.expect(freeMessage).toBe(Garage.messages.noValue)
		end)

		t.it("finds a car only in the data it is given", function()
			local mine = profileWith({ car("mine-1", "ohm_spark", "standard", 35000) })
			local theirs = profileWith({ car("theirs-1", "ohm_spark", "standard", 35000) })
			local found, index = GarageService.findVehicle(mine, "mine-1")
			t.expect(found ~= nil and found.uid == "mine-1").toBe(true)
			t.expect(index).toBe(1)
			t.expect(GarageService.findVehicle(mine, "theirs-1")).toBe(nil)
			t.expect(GarageService.findVehicle(theirs, "mine-1")).toBe(nil)
			t.expect(GarageService.findVehicle(mine, "")).toBe(nil)
		end)
	end)

	t.describe("Garage order", function()
		t.it("sorts favorites first, then newest, then by uid", function()
			local old = car("b-old", "ohm_spark", "standard", 1, JOIN_TIME)
			local new = car("c-new", "ohm_spark", "standard", 1, JOIN_TIME + 100)
			local favOld = car("d-fav-old", "ohm_spark", "standard", 1, JOIN_TIME)
			favOld.favorite = true
			local favNew = car("e-fav-new", "ohm_spark", "standard", 1, JOIN_TIME + 50)
			favNew.favorite = true
			local tie = car("a-tie", "ohm_spark", "standard", 1, JOIN_TIME)
			local list = { old, new, favOld, favNew, tie }
			local sorted = Garage.sortVehicles(list)
			t.expect(uidsOf(sorted)).toEqual({ "e-fav-new", "d-fav-old", "c-new", "a-tie", "b-old" })
			-- The list passed in is left alone.
			t.expect(uidsOf(list)).toEqual({ "b-old", "c-new", "d-fav-old", "e-fav-new", "a-tie" })
			t.expect(uidsOf(GarageService.sortVehicles(list))).toEqual(uidsOf(sorted))
		end)
	end)

	t.describe("Garage room", function()
		t.it("has room until the garage slots are used, not counting designs", function()
			local data = profileWith({})
			t.expect(data.garageSlots).toBe(Economy.garageSlots)
			t.expect(GarageService.roomIn(data)).toBe(true)
			for index = 1, Economy.garageSlots - 1 do
				table.insert(data.vehicles, car(`car-{index}`, "ohm_spark", "standard", 35000))
			end
			table.insert(data.vehicles, car("design", Garage.customVehicleId, "base", 0))
			t.expect(GarageService.slotsUsed(data)).toBe(Economy.garageSlots - 1)
			t.expect(GarageService.roomIn(data)).toBe(true)
			table.insert(data.vehicles, car("last", "ohm_spark", "standard", 35000))
			t.expect(GarageService.roomIn(data)).toBe(false)
			data.garageSlots += 1
			t.expect(GarageService.roomIn(data)).toBe(true)
		end)

		t.it("falls back to the configured slots when the save's count is damaged", function()
			local data = profileWith({})
			data.garageSlots = 0 / 0
			t.expect(GarageService.roomIn(data)).toBe(true)
		end)
	end)

	t.describe("Garage settings", function()
		local defaults = Data.defaults.settings

		t.it("takes valid values", function()
			local current: Types.Settings = { units = "mph", camera = "chase", musicVolume = 0.5 }
			local settings, changed =
				GarageService.cleanSettings(current, { units = "kph", camera = "hood", musicVolume = 0 })
			t.expect(changed).toBe(true)
			t.expect(settings).toEqual({ units = "kph", camera = "hood", musicVolume = 0 })
			t.expect(current).toEqual({ units = "mph", camera = "chase", musicVolume = 0.5 }) -- left alone
		end)

		t.it("takes part of a request and keeps the rest", function()
			local current: Types.Settings = { units = "mph", camera = "chase", musicVolume = 0.5 }
			local settings, changed = GarageService.cleanSettings(current, { musicVolume = 1 })
			t.expect(changed).toBe(true)
			t.expect(settings).toEqual({ units = "mph", camera = "chase", musicVolume = 1 })
		end)

		t.it("ignores invalid values", function()
			local current: Types.Settings = { units = "kph", camera = "orbit", musicVolume = 0.25 }
			for _, request in
				{
					{ units = "furlongs" },
					{ camera = "drone" },
					{ musicVolume = 1.5 },
					{ musicVolume = -0.1 },
					{ musicVolume = 0 / 0 },
					{ musicVolume = "loud" },
					{ units = 1, camera = true },
					"not a table",
				} :: { any }
			do
				local settings, changed = GarageService.cleanSettings(current, request)
				t.expect(changed).toBe(false)
				t.expect(settings).toEqual(current)
			end
		end)

		t.it("reports no change when nothing changes", function()
			local current: Types.Settings = { units = "mph", camera = "chase", musicVolume = 0.5 }
			local _, changed = GarageService.cleanSettings(current, { units = "mph" })
			t.expect(changed).toBe(false)
		end)

		t.it("repairs damaged settings with the defaults", function()
			local settings, changed = GarageService.cleanSettings({ units = "parsecs", musicVolume = 9 }, nil)
			t.expect(changed).toBe(true)
			t.expect(settings).toEqual(defaults)
			local fromNothing = GarageService.cleanSettings(nil, { units = "kph" })
			t.expect(fromNothing.units).toBe("kph")
			t.expect(fromNothing.camera).toBe(defaults.camera)
		end)

		t.it("offers every camera mode and both units", function()
			t.expect(table.find(Garage.settings.units, "mph") ~= nil).toBe(true)
			t.expect(table.find(Garage.settings.units, "kph") ~= nil).toBe(true)
			for _, mode in { "chase", "orbit", "hood" } do
				t.expect(table.find(Garage.settings.cameras, mode) ~= nil).toBe(true)
			end
		end)
	end)

	t.describe("Profile snapshot", function()
		t.it("carries the contract's fields and nothing else", function()
			local data = profileWith({ car("a", "ohm_spark", "standard", 35000) })
			data.cash = 1234
			data.starterClaimed = true
			data.credits.balance = 7
			data.vehicles[1].plateText = "PRIVATE"
			data.vehicles[1].mods = { secret = true }
			data.receipts = { "purchase-1" }
			local snapshot = ProfileSyncService.snapshot(data)
			local keys = {}
			for key in snapshot :: any do
				table.insert(keys, key)
			end
			table.sort(keys)
			t.expect(keys).toEqual({
				"cash",
				"credits",
				"customSlots",
				"designs",
				"fleet",
				"garageSlots",
				"looks",
				"settings",
				"starterClaimed",
				"vehicles",
			})
			t.expect(snapshot.looks).toEqual({})
			t.expect(snapshot.fleet).toEqual(ProfileSyncService.snapshotFleet(data.fleet, false))
			t.expect(snapshot.cash).toBe(1234)
			t.expect(snapshot.starterClaimed).toBe(true)
			t.expect(snapshot.credits).toEqual({ balance = 7, freeDesignUsed = false })
			t.expect(snapshot.designs).toEqual({})
			t.expect(snapshot.settings).toEqual(Data.defaults.settings)
			t.expect(snapshot.vehicles).toEqual({
				{
					uid = "a",
					vehicleId = "ohm_spark",
					trim = "standard",
					favorite = false,
					paid = 35000,
					paint = Garage.defaults.paint,
					finish = Garage.defaults.finish,
					wheels = Garage.defaults.wheels,
					acquiredAt = JOIN_TIME,
				},
			})
		end)

		t.it("copies, so changing the snapshot never touches the save", function()
			local data = profileWith({ car("a", "ohm_spark", "standard", 35000) })
			local snapshot = ProfileSyncService.snapshot(data)
			t.expect(snapshot.settings == data.settings).toBe(false)
			t.expect(snapshot.vehicles[1] == (data.vehicles[1] :: any)).toBe(false)
			snapshot.vehicles[1].paid = 1
			snapshot.settings.musicVolume = 1
			t.expect(data.vehicles[1].paid).toBe(35000)
			t.expect(data.settings.musicVolume).toBe(Data.defaults.settings.musicVolume)
		end)

		t.it("lists favorites first and survives damaged entries", function()
			local data = profileWith({
				car("old", "ohm_spark", "standard", 35000, JOIN_TIME),
				car("fav", "ohm_spark", "standard", 35000, JOIN_TIME - 10),
			})
			data.vehicles[2].favorite = true
			table.insert(data.vehicles, "junk" :: any)
			data.cash = 0 / 0
			local snapshot = ProfileSyncService.snapshot(data)
			t.expect(uidsOf(snapshot.vehicles)).toEqual({ "fav", "old" })
			t.expect(snapshot.cash).toBe(0)
		end)

		t.it("counts the slots passes and the club add, without saving them", function()
			local data = profileWith({ car("a", "ohm_spark", "standard", 35000) })
			local plain = ProfileSyncService.snapshot(data)
			t.expect(plain.garageSlots).toBe(data.garageSlots)
			t.expect(plain.customSlots).toBe(data.customSlots)
			local boosted = ProfileSyncService.snapshot(data, false, { garage = 10, custom = 4 })
			t.expect(boosted.garageSlots).toBe(data.garageSlots + 10)
			t.expect(boosted.customSlots).toBe(data.customSlots + 4)
			local junk = ProfileSyncService.snapshot(data, false, { garage = -3, custom = 0 / 0 })
			t.expect(junk.garageSlots).toBe(data.garageSlots)
			t.expect(junk.customSlots).toBe(data.customSlots)
			t.expect(data.garageSlots).toBe(plain.garageSlots) -- the save never changes
		end)

		t.it("lists the exclusive looks the player has, and the club's only while they are a member", function()
			local data = profileWith({ car("a", "ohm_spark", "standard", 35000) })
			local owned = Customization.exclusiveWraps[1].id
			local cosmetics: any = data.cosmetics
			cosmetics[owned] = 0
			cosmetics.not_a_look = 3
			cosmetics.launch_week_plate_frame = 7 -- a look the shop doesn't have yet
			t.expect(ProfileSyncService.snapshot(data).looks).toEqual({ owned })
			local member = ProfileSyncService.snapshot(data, false, nil, true).looks or {}
			for _, id in Monetization.club.cosmetics do
				t.expect(table.find(member, id) ~= nil).toBe(true)
			end
			t.expect(table.find(member, owned) ~= nil).toBe(true)
			t.expect(ProfileSyncService.snapshotLooks(nil, false)).toEqual({})
		end)
	end)
end
