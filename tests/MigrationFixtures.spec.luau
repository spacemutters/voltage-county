--!strict
-- Every PlayerData version ever written, migrated to the current one (PLAN.md Phase 14 "Data safety review";
-- docs/phase-14-contracts.md "Data safety"; CLAUDE.md hard rule 7).
--
-- FIXTURES holds one save per schema version, from Config/Data.unversionedVersion to Config/Data.schemaVersion,
-- written out as the literal table that version's template (DataService/Template, and PLAN.md §6 before it) and the
-- game of that time wrote, holding what a player owned by then: cash, cars with their trims and looks, codes and
-- boosts, energy, job XP and licenses, plates and kit extras, robotaxi pods and their earnings, designs, mods and
-- credits, cosmetics, receipts, house upgrades, the season, the streak, a drop still waiting to be granted and (since
-- version 8) the goals' progress and what was collected.
-- For each fixture (version 1 also without its version field, as the oldest saves have it):
--   * Migrations.run reaches the latest version, and the result already has every field a new profile has
--     (Template.new, Template.ownedVehicle) with the right types and nothing else, before ProfileStore's Reconcile;
--     the join's Template.stamp only fills the times the migration left unset;
--   * every value in the fixture survives (no cash, car, credit, cosmetic or XP lost), except REWRITES;
--   * migrating the result again changes nothing, and neither does any step run a second time.
-- The walk: every step on its own, over every fixture and a copy of it with every empty collection filled in (so
-- each step meets every field, even ones nothing used yet at that version), fails when a key that was there before
-- the step is missing after it, or its value changed, unless REWRITES allows that change.
-- A schema bump needs its fixture here: "has a fixture for every version" fails until it has one.
-- Pure logic: runs in Edit mode.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Data = require(ReplicatedStorage.Shared.Config.Data)
local Harness = require(ReplicatedStorage.Shared.Testing.Harness)
local Migrations = require(ServerScriptService.Server.Services.DataService.Migrations)
local Template = require(ServerScriptService.Server.Services.DataService.Template)

type Save = { [string]: any }
type Case = { label: string, from: number, make: () -> Save }

local T0 = 1_790_000_000 -- the fixture player's first join (os.time() seconds)
local DAY = 86400
local NOW = T0 + 40 * DAY -- the join that migrates the save
local FLEET_TIMES_VERSION = 6 -- the version that gave the fleet lastOnlineAt (older saves get it stamped on join)

-- Fixtures ------------------------------------------------------------------------------------------------------

-- Version 1: PLAN.md §6 as the Phase 0 types wrote it, before versioned saves. No boosts; a car is its uid,
-- vehicleId and trim, its look (paint, finish, wheels, rideHeight, tint) and acquiredAt, with designUid, wrap,
-- plateText, mods and serial optional; the fleet is pods and lastCollectedAt.
local function v1(): Save
	return {
		version = 1,
		cash = 12500,
		starterClaimed = true,
		vehicles = {
			{
				uid = "car-starter",
				vehicleId = "ohm_spark",
				trim = "used",
				paint = "white",
				finish = "gloss",
				wheels = "stock",
				rideHeight = 0,
				tint = 0,
				acquiredAt = T0 + 60,
			},
		},
		garageSlots = 6,
		designs = {},
		customSlots = 3,
		credits = { balance = 0, freeDesignUsed = false, reserved = {} },
		fleet = { pods = {}, lastCollectedAt = T0 },
		jobs = { xp = {}, licenses = {} },
		house = { upgrades = {} },
		stats = { milesDriven = 41.5, tripsCompleted = 0, playtimeSec = 5400 },
		codesRedeemed = {},
		season = { id = "", xp = 0, premium = false, claimed = {} },
		streak = { lastDay = 0, count = 0 },
		offersSeen = {},
		club = {},
		receipts = {},
		pendingGrants = {},
		settings = { units = "kph", camera = "hood", musicVolume = 0.25 },
		firstJoinAt = T0,
	}
end

-- Version 2 (Phase 3: economy, codes, drive-to-earn): the save gains `boosts`, timed earnings boosts from codes.
local function v2(): Save
	return {
		version = 2,
		cash = 48250,
		starterClaimed = true,
		vehicles = {
			{
				uid = "car-starter",
				vehicleId = "ohm_spark",
				trim = "used",
				paint = "white",
				finish = "gloss",
				wheels = "stock",
				rideHeight = 0,
				tint = 0,
				acquiredAt = T0 + 60,
			},
		},
		garageSlots = 6,
		designs = {},
		customSlots = 3,
		credits = { balance = 0, freeDesignUsed = false, reserved = {} },
		fleet = { pods = {}, lastCollectedAt = T0 },
		jobs = { xp = {}, licenses = {} },
		house = { upgrades = {} },
		stats = { milesDriven = 212.75, tripsCompleted = 0, playtimeSec = 21600 },
		codesRedeemed = { VOLTAGE = true, DOUBLEUP = true },
		season = { id = "", xp = 0, premium = false, claimed = {} },
		streak = { lastDay = 0, count = 0 },
		offersSeen = {},
		club = {},
		receipts = {},
		pendingGrants = {},
		settings = { units = "kph", camera = "hood", musicVolume = 0.25 },
		firstJoinAt = T0,
		boosts = { { id = "DOUBLEUP", factor = 2, endsAt = T0 + 3 * DAY + 1800 } },
	}
end

-- Version 3 (Phase 4: dealership, used lot, garage): every car gains `favorite` and `paid`. This player bought one
-- car new and one from the used lot; nobody could choose a paint yet, so every car is the "white" default.
local function v3(): Save
	return {
		version = 3,
		cash = 7300,
		starterClaimed = true,
		vehicles = {
			{
				uid = "car-starter",
				vehicleId = "ohm_spark",
				trim = "used",
				paint = "white",
				finish = "gloss",
				wheels = "stock",
				rideHeight = 0,
				tint = 0,
				acquiredAt = T0 + 60,
				favorite = false,
				paid = 0,
			},
			{
				uid = "car-current",
				vehicleId = "ohm_current",
				trim = "long_range",
				paint = "white",
				finish = "gloss",
				wheels = "stock",
				rideHeight = 0,
				tint = 0,
				acquiredAt = T0 + 5 * DAY,
				favorite = true,
				paid = 44500,
			},
			{
				uid = "car-mesa",
				vehicleId = "ohm_mesa",
				trim = "standard",
				paint = "white",
				finish = "gloss",
				wheels = "stock",
				rideHeight = 0,
				tint = 0,
				acquiredAt = T0 + 6 * DAY,
				favorite = false,
				paid = 17250,
			},
		},
		garageSlots = 6,
		designs = {},
		customSlots = 3,
		credits = { balance = 0, freeDesignUsed = false, reserved = {} },
		fleet = { pods = {}, lastCollectedAt = T0 },
		jobs = { xp = {}, licenses = {} },
		house = { upgrades = {} },
		stats = { milesDriven = 486.2, tripsCompleted = 0, playtimeSec = 43200 },
		codesRedeemed = { VOLTAGE = true, DOUBLEUP = true },
		season = { id = "", xp = 0, premium = false, claimed = {} },
		streak = { lastDay = 0, count = 0 },
		offersSeen = {},
		club = {},
		receipts = {},
		pendingGrants = {},
		settings = { units = "kph", camera = "hood", musicVolume = 0.25 },
		firstJoinAt = T0,
		boosts = {},
	}
end

-- Version 4 (Phase 5: charging and fuel; Phase 6: rideshare and delivery jobs): every car gains `energy`.
local function v4(): Save
	return {
		version = 4,
		cash = 61250,
		starterClaimed = true,
		vehicles = {
			{
				uid = "car-starter",
				vehicleId = "ohm_spark",
				trim = "used",
				paint = "white",
				finish = "gloss",
				wheels = "stock",
				rideHeight = 0,
				tint = 0,
				acquiredAt = T0 + 60,
				favorite = false,
				paid = 0,
				energy = 0.35,
			},
			{
				uid = "car-current",
				vehicleId = "ohm_current",
				trim = "long_range",
				paint = "white",
				finish = "gloss",
				wheels = "stock",
				rideHeight = 0,
				tint = 0,
				acquiredAt = T0 + 5 * DAY,
				favorite = true,
				paid = 44500,
				energy = 0.8,
			},
			{
				uid = "car-mesa",
				vehicleId = "ohm_mesa",
				trim = "standard",
				paint = "white",
				finish = "gloss",
				wheels = "stock",
				rideHeight = 0,
				tint = 0,
				acquiredAt = T0 + 6 * DAY,
				favorite = false,
				paid = 17250,
				energy = 1,
			},
		},
		garageSlots = 6,
		designs = {},
		customSlots = 3,
		credits = { balance = 0, freeDesignUsed = false, reserved = {} },
		fleet = { pods = {}, lastCollectedAt = T0 },
		jobs = { xp = { rideshare = 1840, delivery = 620 }, licenses = {} },
		house = { upgrades = {} },
		stats = { milesDriven = 1310.4, tripsCompleted = 37, playtimeSec = 90000 },
		codesRedeemed = { VOLTAGE = true, DOUBLEUP = true },
		season = { id = "", xp = 0, premium = false, claimed = {} },
		streak = { lastDay = 0, count = 0 },
		offersSeen = {},
		club = {},
		receipts = {},
		pendingGrants = {},
		settings = { units = "kph", camera = "hood", musicVolume = 0.25 },
		firstJoinAt = T0,
		boosts = {},
	}
end

-- Version 5 (Phase 7: Wrap & Tint shop, plates, light shows; Phase 8: towing and freight): every car gains
-- `caliper`, `extras` and `plateFormat`, and the old "white" default became "factory". This player has painted,
-- wrapped and plated cars, bought a tow truck and the freight license.
local function v5(): Save
	return {
		version = 5,
		cash = 23400,
		starterClaimed = true,
		vehicles = {
			{
				uid = "car-starter",
				vehicleId = "ohm_spark",
				trim = "used",
				paint = "factory",
				finish = "gloss",
				wheels = "stock",
				rideHeight = 0,
				tint = 0,
				caliper = "stock",
				extras = {},
				plateFormat = "county",
				acquiredAt = T0 + 60,
				favorite = false,
				paid = 0,
				energy = 0.35,
			},
			{
				uid = "car-current",
				vehicleId = "ohm_current",
				trim = "long_range",
				paint = "cobalt",
				finish = "metallic",
				wrap = "twin_stripes",
				wheels = "five_star",
				rideHeight = -0.5,
				tint = 0.4,
				caliper = "red",
				extras = { "lip_spoiler" },
				plateFormat = "classic",
				plateText = "VOLT 1",
				acquiredAt = T0 + 5 * DAY,
				favorite = true,
				paid = 44500,
				energy = 0.8,
			},
			{
				uid = "car-mesa",
				vehicleId = "ohm_mesa",
				trim = "standard",
				paint = "forest",
				finish = "matte",
				wheels = "trail",
				rideHeight = 0.6,
				tint = 0,
				caliper = "yellow",
				extras = { "roof_rack", "light_bar" },
				plateFormat = "heritage",
				acquiredAt = T0 + 6 * DAY,
				favorite = false,
				paid = 17250,
				energy = 1,
			},
			{
				uid = "car-hauler",
				vehicleId = "ohm_hauler",
				trim = "standard",
				paint = "sunset_orange",
				finish = "gloss",
				wheels = "steel",
				rideHeight = 0,
				tint = 0.2,
				caliper = "stock",
				extras = {},
				plateFormat = "county",
				acquiredAt = T0 + 12 * DAY,
				favorite = false,
				paid = 61000,
				energy = 0.62,
			},
		},
		garageSlots = 6,
		designs = {},
		customSlots = 3,
		credits = { balance = 0, freeDesignUsed = false, reserved = {} },
		fleet = { pods = {}, lastCollectedAt = T0 },
		jobs = { xp = { rideshare = 2410, delivery = 1975, towing = 1220 }, licenses = { freight = true } },
		house = { upgrades = {} },
		stats = { milesDriven = 2204.9, tripsCompleted = 81, playtimeSec = 151200 },
		codesRedeemed = { VOLTAGE = true, DOUBLEUP = true },
		season = { id = "", xp = 0, premium = false, claimed = {} },
		streak = { lastDay = 0, count = 0 },
		offersSeen = {},
		club = {},
		receipts = {},
		pendingGrants = {},
		settings = { units = "kph", camera = "hood", musicVolume = 0.25 },
		firstJoinAt = T0,
		boosts = {},
	}
end

-- A design as Phase 11's DesignerService saves it (the validated spec), and the merged mod spec a catalog car
-- keeps in `mods`.
local function designSpec(): Save
	return {
		name = "Night Commuter",
		tagline = "Quiet, quick and easy to park",
		class = "economy",
		energy = "battery",
		personality = "efficient",
		meshPrompt = "a compact hatchback with a smooth rounded nose",
		body = { template = "hatch", length = 0.2, height = -0.1, roofline = 0.3, noseSlope = 0.5, flare = 0 },
		parts = { frontBumper = "clean", rearBumper = "clean", spoiler = "lip", lights = "slim", wheels = "turbine" },
		paint = { primary = "#2E5E8C", secondary = "#F2F2F2", finish = "matte", stripe = "center" },
		stance = { rideHeight = -0.2, wheelSize = 0.1 },
	}
end

local function catalogMod(): Save
	return {
		summary = "Mesh wheels, a center stripe and a lower stance",
		kind = "catalog",
		hidden = false,
		body = {
			template = "keep",
			length = { change = false, value = 0 },
			height = { change = false, value = 0 },
			roofline = { change = false, value = 0 },
			noseSlope = { change = false, value = 0 },
			flare = { change = false, value = 0 },
		},
		parts = { frontBumper = "keep", rearBumper = "keep", spoiler = "keep", lights = "keep", wheels = "mesh" },
		paint = { primary = "keep", secondary = "keep", finish = "keep", stripe = "center" },
		stance = { rideHeight = { change = true, value = -0.3 }, wheelSize = { change = false, value = 0 } },
		extras = "keep",
		accessoryPrompt = "none",
	}
end

-- Version 6 (Phase 9: robotaxi fleet; Phase 10: abilities; Phase 11: the AI Car Designer): the fleet gains
-- `uncollected` and `lastOnlineAt`. This player runs two pods, used the free design (a custom car) and bought
-- credits for a mod on the Current; a second mod was in flight when the server stopped, so its reservation is
-- still in the save (CreditsService refunds it on the next join, after the migration).
local function v6(): Save
	return {
		version = 6,
		cash = 154900,
		starterClaimed = true,
		vehicles = {
			{
				uid = "car-starter",
				vehicleId = "ohm_spark",
				trim = "used",
				paint = "factory",
				finish = "gloss",
				wheels = "stock",
				rideHeight = 0,
				tint = 0,
				caliper = "stock",
				extras = {},
				plateFormat = "county",
				acquiredAt = T0 + 60,
				favorite = false,
				paid = 0,
				energy = 0.35,
			},
			{
				uid = "car-current",
				vehicleId = "ohm_current",
				trim = "long_range",
				paint = "cobalt",
				finish = "metallic",
				wrap = "twin_stripes",
				wheels = "mesh",
				rideHeight = -0.5,
				tint = 0.4,
				caliper = "red",
				extras = { "lip_spoiler" },
				plateFormat = "classic",
				plateText = "VOLT 1",
				mods = catalogMod(),
				acquiredAt = T0 + 5 * DAY,
				favorite = true,
				paid = 44500,
				energy = 0.8,
			},
			{
				uid = "car-mesa",
				vehicleId = "ohm_mesa",
				trim = "standard",
				paint = "forest",
				finish = "matte",
				wheels = "trail",
				rideHeight = 0.6,
				tint = 0,
				caliper = "yellow",
				extras = { "roof_rack", "light_bar" },
				plateFormat = "heritage",
				acquiredAt = T0 + 6 * DAY,
				favorite = false,
				paid = 17250,
				energy = 1,
			},
			{
				uid = "car-hauler",
				vehicleId = "ohm_hauler",
				trim = "standard",
				paint = "sunset_orange",
				finish = "gloss",
				wheels = "steel",
				rideHeight = 0,
				tint = 0.2,
				caliper = "stock",
				extras = {},
				plateFormat = "county",
				acquiredAt = T0 + 12 * DAY,
				favorite = false,
				paid = 61000,
				energy = 0.62,
			},
			{
				uid = "car-custom",
				vehicleId = "custom",
				designUid = "design-commuter",
				trim = "design",
				paint = "factory",
				finish = "matte",
				wheels = "turbine",
				rideHeight = 0,
				tint = 0,
				caliper = "stock",
				extras = {},
				plateFormat = "county",
				acquiredAt = T0 + 25 * DAY,
				favorite = true,
				paid = 0,
				energy = 0.9,
			},
		},
		garageSlots = 6,
		designs = {
			{ uid = "design-commuter", spec = designSpec(), createdAt = T0 + 25 * DAY, hidden = false },
		},
		customSlots = 3,
		credits = {
			balance = 12,
			freeDesignUsed = true,
			reserved = { { id = "mod-in-flight", amount = 1, at = T0 + 34 * DAY } },
		},
		fleet = {
			pods = { { uid = "pod-a", zone = "cedar_bend" }, { uid = "pod-b", zone = "lakefront" } },
			lastCollectedAt = T0 + 33 * DAY,
			uncollected = 1834.5,
			lastOnlineAt = T0 + 34 * DAY,
		},
		jobs = {
			xp = { rideshare = 2980, delivery = 2400, towing = 1610, freight = 940 },
			licenses = { freight = true },
		},
		house = { upgrades = {} },
		stats = { milesDriven = 3120.6, tripsCompleted = 118, playtimeSec = 208800 },
		codesRedeemed = { VOLTAGE = true, DOUBLEUP = true },
		season = { id = "", xp = 0, premium = false, claimed = {} },
		streak = { lastDay = 0, count = 0 },
		offersSeen = {},
		club = {},
		receipts = {},
		pendingGrants = {},
		settings = { units = "kph", camera = "hood", musicVolume = 0.25 },
		firstJoinAt = T0,
		boosts = {},
	}
end

-- Version 7 (Phase 12: store, passes, Voltage Club, drops, season pass, streaks; Phase 13: houses): the save gains
-- `cosmetics`. This player bought the Starter Pack (its wrap, a custom slot, credits), a credit pack and a numbered
-- launch-week wrap, is in the club and on the season pass, owns house upgrades, and paid for a drop that the
-- server hadn't put in the garage yet (LimitedService finishes it on the next join).
local function v7(): Save
	return {
		version = 7,
		cash = 312400,
		starterClaimed = true,
		vehicles = {
			{
				uid = "car-starter",
				vehicleId = "ohm_spark",
				trim = "used",
				paint = "factory",
				finish = "gloss",
				wrap = "starter_wrap",
				wheels = "stock",
				rideHeight = 0,
				tint = 0,
				caliper = "stock",
				extras = {},
				plateFormat = "county",
				acquiredAt = T0 + 60,
				favorite = false,
				paid = 0,
				energy = 0.35,
			},
			{
				uid = "car-current",
				vehicleId = "ohm_current",
				trim = "long_range",
				paint = "cobalt",
				finish = "metallic",
				wrap = "launch_week_wrap",
				wheels = "mesh",
				rideHeight = -0.5,
				tint = 0.4,
				caliper = "red",
				extras = { "lip_spoiler" },
				plateFormat = "classic",
				plateText = "VOLT 1",
				mods = catalogMod(),
				acquiredAt = T0 + 5 * DAY,
				favorite = true,
				paid = 44500,
				energy = 0.8,
			},
			{
				uid = "car-mesa",
				vehicleId = "ohm_mesa",
				trim = "standard",
				paint = "forest",
				finish = "matte",
				wheels = "trail",
				rideHeight = 0.6,
				tint = 0,
				caliper = "yellow",
				extras = { "roof_rack", "light_bar" },
				plateFormat = "heritage",
				acquiredAt = T0 + 6 * DAY,
				favorite = false,
				paid = 17250,
				energy = 1,
			},
			{
				uid = "car-hauler",
				vehicleId = "ohm_hauler",
				trim = "standard",
				paint = "sunset_orange",
				finish = "gloss",
				wheels = "steel",
				rideHeight = 0,
				tint = 0.2,
				caliper = "stock",
				extras = {},
				plateFormat = "county",
				acquiredAt = T0 + 12 * DAY,
				favorite = false,
				paid = 61000,
				energy = 0.62,
			},
			{
				uid = "car-custom",
				vehicleId = "custom",
				designUid = "design-commuter",
				trim = "design",
				paint = "factory",
				finish = "matte",
				wheels = "turbine",
				rideHeight = 0,
				tint = 0,
				caliper = "stock",
				extras = {},
				plateFormat = "county",
				acquiredAt = T0 + 25 * DAY,
				favorite = true,
				paid = 0,
				energy = 0.9,
			},
		},
		garageSlots = 6,
		designs = {
			{ uid = "design-commuter", spec = designSpec(), createdAt = T0 + 25 * DAY, hidden = false },
		},
		customSlots = 4,
		credits = { balance = 27, freeDesignUsed = true, reserved = {} },
		fleet = {
			pods = {
				{ uid = "pod-a", zone = "cedar_bend" },
				{ uid = "pod-b", zone = "lakefront" },
				{ uid = "pod-c", zone = "riverside" },
			},
			lastCollectedAt = T0 + 37 * DAY,
			uncollected = 412.25,
			lastOnlineAt = T0 + 38 * DAY,
		},
		jobs = {
			xp = { rideshare = 3555, delivery = 2790, towing = 1985, freight = 2210 },
			licenses = { freight = true },
		},
		house = { upgrades = { fastCharger = true, solarRoof = true } },
		stats = { milesDriven = 4087.3, tripsCompleted = 152, playtimeSec = 266400 },
		codesRedeemed = { VOLTAGE = true, DOUBLEUP = true },
		season = {
			id = "s1",
			xp = 5400,
			premium = true,
			claimed = { ["free:1"] = true, ["free:2"] = true, ["premium:1"] = true },
		},
		streak = { lastDay = 20737, count = 4 },
		offersSeen = { starterPack = true },
		cosmetics = { starter_wrap = 0, launch_week_wrap = 37 },
		club = { lastGrantMonth = "2026-10" },
		receipts = { "4b1c9e0a7d2f4e51", "9a7e3c11b0d84f26", "e2d5a0c4f1b37968" },
		pendingGrants = { { kind = "limitedDrop", ref = "arc_flight_1:7500000" } },
		settings = { units = "kph", camera = "hood", musicVolume = 0.25 },
		firstJoinAt = T0,
		boosts = {},
	}
end

-- Version 8 (roast fixes 2026-10-24: the first-session path and daily goals, Config/Goals): the save gains `goals`.
-- The version 7 player above, a day into schema 8: their path was done by the migration (they had cars), and today's
-- three goals are picked, one part done, one collected. Built on v7 (everything else in the save is the same).
local function v8(): Save
	local save = v7()
	save.version = 8
	save.goals = {
		path = { done = true, finished = {}, claimed = {} },
		daily = {
			day = 20748,
			ids = { "charge1", "jobs3", "testDrive1" },
			progress = { charge1 = 1, jobs3 = 2 },
			claimed = { charge1 = true },
		},
	}
	return save
end

-- By the version each fixture is at.
local FIXTURES: { [number]: () -> Save } = { v1, v2, v3, v4, v5, v6, v7, v8 }

-- Every case the specs below run: each fixture, and version 1 again without its version field.
local CASES: { Case } = {
	{
		label = "unversioned",
		from = Data.unversionedVersion,
		make = function(): Save
			local save = v1()
			save.version = nil
			return save
		end,
	},
}
for version, make in FIXTURES do
	table.insert(CASES, { label = `version {version}`, from = version, make = make })
end

-- The only values a step may change: by the step (the version it upgrades from), a path pattern (string.match on
-- the flattened path, e.g. "vehicles[2].paint") and the old and new value.
type Rewrite = { step: number, path: string, from: any, to: any }
local REWRITES: { Rewrite } = {
	-- 4 -> 5: before the Wrap & Tint shop nobody could choose a paint, so "white" only ever meant "as built".
	{
		step = 4,
		path = "^vehicles%[%d+%]%.paint$",
		from = Data.defaults.vehicleLook.oldDefaultPaint,
		to = Data.defaults.vehicleLook.paint,
	},
}

-- Shapes ----------------------------------------------------------------------------------------------------------

-- Every field a new car has (Template.ownedVehicle) and its type, and the optional ones a car may also have.
local CAR_FIELDS: { [string]: string } = {}
for field, value in Template.ownedVehicle("shape", "ohm_spark", "standard", 0, T0) :: any do
	CAR_FIELDS[field] = type(value)
end
local CAR_OPTIONAL: { [string]: string } =
	{ designUid = "string", wrap = "string", plateText = "string", mods = "table", serial = "number" }

-- Lists of records, by path: the fields every entry has.
local ENTRY_SHAPES: { [string]: { [string]: string } } = {
	designs = { uid = "string", spec = "table", createdAt = "number", hidden = "boolean" },
	boosts = { id = "string", factor = "number", endsAt = "number" },
	pendingGrants = { kind = "string", ref = "string" },
	["credits.reserved"] = { id = "string", amount = "number", at = "number" },
	["fleet.pods"] = { uid = "string", zone = "string" },
}
-- Lists and sets, by path: the type of every value (the LISTS are lists; the rest are keyed by string).
local VALUE_TYPES: { [string]: string } = {
	receipts = "string",
	codesRedeemed = "boolean",
	offersSeen = "boolean",
	cosmetics = "number",
	["jobs.xp"] = "number",
	["jobs.licenses"] = "boolean",
	["house.upgrades"] = "boolean",
	["season.claimed"] = "boolean",
	["goals.path.finished"] = "boolean", -- v8
	["goals.path.claimed"] = "boolean",
	["goals.daily.ids"] = "string",
	["goals.daily.progress"] = "number",
	["goals.daily.claimed"] = "boolean",
}
local LISTS: { [string]: boolean } = { receipts = true, ["goals.daily.ids"] = true }
-- Records a new profile starts empty, by path: the optional fields they may hold.
local OPTIONAL_FIELDS: { [string]: { [string]: string } } = {
	club = { lastGrantMonth = "string" },
}

local function pathOf(parent: string, key: any): string
	if type(key) == "number" then
		return `{parent}[{key}]`
	end
	return if parent == "" then tostring(key) else `{parent}.{tostring(key)}`
end

-- `value` must be a table holding every field of `required` (with its type) and nothing but those and `optional`.
local function checkFields(
	value: any,
	required: { [string]: string },
	optional: { [string]: string }?,
	path: string,
	problems: { string }
)
	if type(value) ~= "table" then
		table.insert(problems, `{path} is {type(value)}, expected table`)
		return
	end
	for field, expected in required do
		if type(value[field]) ~= expected then
			table.insert(problems, `{pathOf(path, field)} is {type(value[field])}, expected {expected}`)
		end
	end
	for field, item in value do
		if required[field] == nil then
			local expected = if optional ~= nil then optional[field] else nil
			if expected == nil then
				table.insert(problems, `{pathOf(path, field)} is not a field it should have`)
			elseif type(item) ~= expected then
				table.insert(problems, `{pathOf(path, field)} is {type(item)}, expected {expected}`)
			end
		end
	end
end

-- The entries of a collection field (a template field that starts as an empty table).
local function checkEntries(collection: { [any]: any }, path: string, problems: { string })
	if path == "vehicles" then
		for index, car in collection do
			local carPath = pathOf(path, index)
			checkFields(car, CAR_FIELDS, CAR_OPTIONAL, carPath, problems)
			if type(car) == "table" and type(car.extras) == "table" then
				for slot, extra in car.extras do
					if type(slot) ~= "number" or type(extra) ~= "string" then
						table.insert(problems, `{carPath}.extras holds {type(extra)} at {tostring(slot)}`)
					end
				end
			end
		end
		return
	end
	local entryShape = ENTRY_SHAPES[path]
	if entryShape ~= nil then
		for index, entry in collection do
			if type(index) ~= "number" then
				table.insert(problems, `{path} has a non-list key {tostring(index)}`)
			end
			checkFields(entry, entryShape, nil, pathOf(path, index), problems)
		end
		return
	end
	local valueType = VALUE_TYPES[path]
	if valueType ~= nil then
		local keyType = if LISTS[path] then "number" else "string"
		for key, item in collection do
			if type(key) ~= keyType or type(item) ~= valueType then
				table.insert(
					problems,
					`{pathOf(path, key)}: {type(key)} -> {type(item)}, expected {keyType} -> {valueType}`
				)
			end
		end
		return
	end
	local optional = OPTIONAL_FIELDS[path]
	if optional ~= nil then
		checkFields(collection, {}, optional, path, problems)
		return
	end
	table.insert(problems, `{path}: this spec lists no shape for it (add one)`)
end

-- `value` against the record `template` (a new profile, or one of its nested records), one line per problem.
local function checkRecord(value: any, template: { [string]: any }, path: string, problems: { string })
	if type(value) ~= "table" then
		table.insert(problems, `{if path == "" then "the save" else path} is {type(value)}, expected table`)
		return
	end
	for field, expected in template do
		local fieldPath = pathOf(path, field)
		local item = value[field]
		if type(expected) == "table" and next(expected) ~= nil then
			checkRecord(item, expected, fieldPath, problems)
		elseif type(item) ~= type(expected) then
			table.insert(problems, `{fieldPath} is {type(item)}, expected {type(expected)}`)
		elseif type(item) == "table" then
			checkEntries(item, fieldPath, problems)
		end
	end
	for field in value do
		if template[field] == nil then
			table.insert(problems, `{pathOf(path, field)} is not a field a new profile has`)
		end
	end
end

local function shapeProblems(data: Save): { string }
	local problems: { string } = {}
	checkRecord(data, Template.new(NOW) :: any, "", problems)
	return problems
end

-- Walking ---------------------------------------------------------------------------------------------------------

local IS_TABLE = {} -- stands for "a table here" in a flattened save

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

-- Every path in `value` and what it holds (IS_TABLE for a table), e.g. out["vehicles[2].paint"] = "cobalt".
local function flatten(value: any, path: string, out: { [string]: any }): { [string]: any }
	if type(value) == "table" then
		if path ~= "" then
			out[path] = IS_TABLE
		end
		for key, item in value do
			flatten(item, pathOf(path, key), out)
		end
	else
		out[path] = value
	end
	return out
end

local function show(value: any): string
	if value == IS_TABLE then
		return "a table"
	elseif type(value) == "string" then
		return string.format("%q", value)
	end
	return tostring(value)
end

-- True when REWRITES lets `path` go from `from` to `to` (in `step`, or in any step when `step` is nil).
local function rewriteAllowed(path: string, from: any, to: any, step: number?): boolean
	for _, rewrite in REWRITES do
		if
			(step == nil or rewrite.step == step)
			and string.match(path, rewrite.path) ~= nil
			and rewrite.from == from
			and rewrite.to == to
		then
			return true
		end
	end
	return false
end

-- One line per path of `before` (but its version) that `after` lost, or holds a different value at (unless
-- REWRITES allows it).
local function lostOrChanged(before: Save, after: Save, step: number?, label: string, problems: { string })
	local old = flatten(before, "", {})
	local new = flatten(after, "", {})
	for path, value in old do
		if path ~= "version" then
			local now = new[path]
			if now == nil then
				table.insert(problems, `{label}: {path} ({show(value)}) is gone`)
			elseif now ~= value and not rewriteAllowed(path, value, now, step) then
				table.insert(problems, `{label}: {path} changed from {show(value)} to {show(now)}`)
			end
		end
	end
end

-- A copy of `save` with every empty collection it has filled in, and one more car wearing every optional field, so
-- the walk meets every field even where nothing used it yet at that version.
local function filled(save: Save): Save
	local data = deepCopy(save)
	local function fill(parent: any, field: string, value: any)
		if type(parent) == "table" and type(parent[field]) == "table" and next(parent[field]) == nil then
			parent[field] = value
		end
	end
	fill(data, "designs", {
		{ uid = "design-filled", spec = { name = "Filled", class = "economy" }, createdAt = T0 + DAY, hidden = true },
	})
	fill(data.credits, "reserved", {
		{ id = "design-filled", amount = 2, at = T0 + DAY },
		{ id = "free:design-filled", amount = 0, at = T0 + DAY },
	})
	fill(data.fleet, "pods", { { uid = "pod-filled", zone = "riverside" } })
	fill(data.jobs, "xp", { rideshare = 75 })
	fill(data.jobs, "licenses", { freight = true })
	fill(data.house, "upgrades", { mailbox = true })
	fill(data, "codesRedeemed", { VOLTAGE = true })
	fill(data.season, "claimed", { ["free:1"] = true })
	fill(data, "offersSeen", { starterPack = true })
	fill(data, "club", { lastGrantMonth = "2026-09" })
	fill(data, "receipts", { "receipt-filled-1", "receipt-filled-2" })
	fill(data, "pendingGrants", { { kind = "limitedDrop", ref = "arc_flight_1:7500000" } })
	fill(data, "boosts", { { id = "DOUBLEUP", factor = 2, endsAt = T0 + DAY } })
	fill(data, "cosmetics", { starter_wrap = 0 })
	local goals = data.goals
	if type(goals) == "table" then
		fill(goals.path, "finished", { firstFare = true })
		fill(goals.path, "claimed", { firstFare = true })
		fill(goals.daily, "ids", { "drive3", "rides2", "earn10k" })
		fill(goals.daily, "progress", { drive3 = 1.5 })
		fill(goals.daily, "claimed", { rides2 = true })
	end
	if data.credits.balance == 0 then
		data.credits.balance = 9
	end

	local car = deepCopy(data.vehicles[1])
	car.uid = "car-filled"
	car.designUid = car.designUid or "design-filled"
	car.wrap = car.wrap or "rally"
	car.plateText = car.plateText or "FILL 1"
	car.serial = car.serial or 9
	car.mods = car.mods or catalogMod()
	if type(car.extras) == "table" and next(car.extras) == nil then
		car.extras = { "bull_bar" }
	end
	table.insert(data.vehicles, car)
	return data
end

-- What the player owns, summed up (a readable first check before the path-by-path one).
local function totals(data: Save): { [string]: number }
	local xp = 0
	for _, amount in data.jobs.xp do
		xp += amount
	end
	local cosmetics = 0
	for _ in data.cosmetics or {} do
		cosmetics += 1
	end
	local upgrades = 0
	for _ in data.house.upgrades do
		upgrades += 1
	end
	local reserved = 0
	for _, entry in data.credits.reserved do
		reserved += entry.amount
	end
	return {
		cash = data.cash,
		cars = #data.vehicles,
		designs = #data.designs,
		credits = data.credits.balance,
		reservedCredits = reserved,
		jobXp = xp,
		seasonXp = data.season.xp,
		pods = #data.fleet.pods,
		uncollected = data.fleet.uncollected or 0,
		cosmetics = cosmetics,
		receipts = #data.receipts,
		pendingGrants = #data.pendingGrants,
		upgrades = upgrades,
	}
end

return function(t: Harness.Api)
	t.describe("Migration fixtures", function()
		t.it("has a fixture for every version, from the first to the current one", function()
			local missing: { string } = {}
			for version = Data.unversionedVersion, Data.schemaVersion do
				if FIXTURES[version] == nil then
					table.insert(missing, tostring(version))
				end
			end
			t.expect(table.concat(missing, ", ")).toBe("")
			t.expect(FIXTURES[Data.schemaVersion + 1]).toBe(nil)
		end)

		t.it("labels each fixture with its own version", function()
			for version, make in FIXTURES do
				t.expect(make().version).toBe(version)
			end
		end)

		t.it("has the newest fixture in exactly the shape a new profile has", function()
			-- Keeps the fixtures honest: when the template changes, the newest fixture has to change with it.
			t.expect(table.concat(shapeProblems(FIXTURES[Data.schemaVersion]()), "\n")).toBe("")
		end)

		for _, case in CASES do
			t.it(`{case.label}: reaches the latest version with every field a new profile has`, function()
				local migrated, fromVersion = Migrations.run(case.make())
				t.expect(fromVersion).toBe(case.from)
				t.expect(migrated.version).toBe(Data.schemaVersion)
				t.expect(table.concat(shapeProblems(migrated), "\n")).toBe("")
			end)

			t.it(`{case.label}: keeps every value the player owned`, function()
				local fixture = case.make()
				local migrated = Migrations.run(deepCopy(fixture))
				t.expect(totals(migrated)).toEqual(totals(fixture))
				local problems: { string } = {}
				lostOrChanged(fixture, migrated, nil, case.label, problems)
				t.expect(table.concat(problems, "\n")).toBe("")
			end)

			t.it(`{case.label}: the join only stamps the times the migration left unset`, function()
				local migrated = Migrations.run(case.make())
				local before = deepCopy(migrated)
				Template.stamp(migrated :: any, NOW)
				t.expect(migrated.firstJoinAt).toBe(T0)
				local lastOnlineAt = if case.from < FLEET_TIMES_VERSION then NOW else before.fleet.lastOnlineAt
				t.expect(migrated.fleet.lastOnlineAt).toBe(lastOnlineAt)
				before.fleet.lastOnlineAt = lastOnlineAt
				t.expect(migrated).toEqual(before)
				t.expect(table.concat(shapeProblems(migrated), "\n")).toBe("")
			end)

			t.it(`{case.label}: migrating again, or running any step again, changes nothing`, function()
				local migrated = Migrations.run(case.make())
				local snapshot = deepCopy(migrated)
				local again, againFrom = Migrations.run(migrated)
				t.expect(againFrom).toBe(Data.schemaVersion)
				t.expect(again).toEqual(snapshot)
				for version = Data.unversionedVersion, Data.schemaVersion - 1 do
					Migrations.steps[version](migrated)
					t.expect(migrated).toEqual(snapshot)
				end
			end)
		end

		t.it("no step loses a key or changes a value it shouldn't, on any fixture", function()
			local problems: { string } = {}
			local walked = 0
			for _, case in CASES do
				local variants = {
					{ label = case.label, save = case.make() },
					{ label = `{case.label} (filled)`, save = filled(case.make()) },
				}
				for _, variant in variants do
					local data = deepCopy(variant.save)
					for version = case.from, Data.schemaVersion - 1 do
						local before = deepCopy(data)
						Migrations.steps[version](data)
						lostOrChanged(
							before,
							data,
							version,
							`{variant.label}, step {version} -> {version + 1}`,
							problems
						)
						walked += 1
					end
					-- And end to end, through Migrations.run.
					lostOrChanged(variant.save, Migrations.run(deepCopy(variant.save)), nil, variant.label, problems)
				end
			end
			t.expect(table.concat(problems, "\n")).toBe("")
			t.expect(walked).toBeGreaterThan(0)
		end)

		t.it("catches a step that drops a field (the walk itself works)", function()
			-- A made-up bad step: it loses the player's job XP and repaints a car that wasn't on the old default.
			local data = v5()
			local before = deepCopy(data)
			data.jobs.xp.towing = nil
			data.vehicles[2].paint = "factory"
			local problems: { string } = {}
			lostOrChanged(before, data, 4, "bad step", problems)
			t.expect(#problems).toBe(2)
			table.sort(problems)
			t.expect(problems[1]).toBe("bad step: jobs.xp.towing (1220) is gone")
			t.expect(problems[2]).toBe('bad step: vehicles[2].paint changed from "cobalt" to "factory"')
		end)

		t.it("the filled copies really fill every collection a fixture leaves empty", function()
			for _, case in CASES do
				local data = filled(case.make())
				for _, field in { "designs", "receipts", "pendingGrants", "offersSeen", "codesRedeemed", "club" } do
					t.expect(`{case.label} {field} {next(data[field]) ~= nil}`).toBe(`{case.label} {field} true`)
				end
				t.expect(next(data.credits.reserved) ~= nil).toBe(true)
				t.expect(next(data.fleet.pods) ~= nil).toBe(true)
				t.expect(next(data.house.upgrades) ~= nil).toBe(true)
				if data.goals ~= nil then
					for _, field in { "finished", "claimed" } do
						t.expect(`{case.label} goals.path.{field} {next(data.goals.path[field]) ~= nil}`)
							.toBe(`{case.label} goals.path.{field} true`)
					end
					for _, field in { "ids", "progress", "claimed" } do
						t.expect(`{case.label} goals.daily.{field} {next(data.goals.daily[field]) ~= nil}`)
							.toBe(`{case.label} goals.daily.{field} true`)
					end
				end
			end
		end)

		t.it("older saves get the path done and the version 8 fixture keeps its goals as they were", function()
			for _, case in CASES do
				local migrated = Migrations.run(case.make())
				if case.from < Data.schemaVersion then
					t.expect(`{case.label} {migrated.goals.path.done}`).toBe(`{case.label} true`) -- every fixture has cars
					t.expect(migrated.goals.daily.ids).toEqual({})
				end
			end
			local fixture = v8()
			t.expect(Migrations.run(v8()).goals).toEqual(fixture.goals)
		end)
	end)
end
