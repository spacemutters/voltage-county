--!strict
-- Robotaxi fleet earnings (PLAN.md §4 and Phase 9 acceptance: "Fleet earnings spec: deterministic for a given seed
-- and clock; offline accrual correct across rejoin (fake clock)"; docs/phase-9-contracts.md "Fleet economy").
-- Covers Config/Fleet's numbers, FleetService/Earnings (pure), FleetService's accrual helpers on a fleet table with
-- a fake clock, and the fleet part of ProfileSyncService's snapshot. Pure logic: runs in Edit mode.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Catalog = require(ReplicatedStorage.Shared.Vehicle.Catalog)
local Economy = require(ReplicatedStorage.Shared.Config.Economy)
local Fleet = require(ReplicatedStorage.Shared.Config.Fleet)
local Garage = require(ReplicatedStorage.Shared.Config.Garage)
local Harness = require(ReplicatedStorage.Shared.Testing.Harness)
local MapLayout = require(ReplicatedStorage.Shared.Config.MapLayout)
local Types = require(ReplicatedStorage.Shared.Types)
local Services = ServerScriptService.Server.Services
local Earnings = require(Services.FleetService.Earnings)
local FleetService = require(Services.FleetService)
local ProfileSyncService = require(Services.ProfileSyncService)
local Template = require(Services.DataService.Template)

local SEED = 424242 -- any fixed owner seed (FleetService uses the UserId)
local T0 = 1700000000 -- any fixed os.time(); deliberately not on a whole hour
local HOUR = 3600
local MINUTE = 60
local AVERAGE_ZONE = "riverside" -- demand 1
local EPSILON = 1e-6

local function pod(uid: string, zone: string?): Earnings.Pod
	return { uid = uid, zone = zone or AVERAGE_ZONE }
end

local function fleetWith(pods: { Types.FleetPod }, lastOnlineAt: number): Types.FleetData
	return { pods = pods, lastCollectedAt = lastOnlineAt, uncollected = 0, lastOnlineAt = lastOnlineAt }
end

local function keysOf(t: { [any]: any }): { string }
	local keys = {}
	for key in t do
		table.insert(keys, tostring(key))
	end
	table.sort(keys)
	return keys
end

return function(t: Harness.Api)
	t.describe("Fleet config", function()
		t.it("pays $60 a minute per pod at average demand (rides per hour x fare x demand)", function()
			t.expect(Fleet.onlinePerMinute).toBe(Economy.activities.robotaxiPerPod)
			t.expect(Fleet.onlinePerMinute).toBe(60)
			t.expect(Fleet.referenceDemand).toBe(1)
			t.expect(Fleet.demandOf(AVERAGE_ZONE)).toBe(Fleet.referenceDemand)
			t.expect(Fleet.ridesPerHour * Fleet.averageFare).toBeNear(60 * 60, EPSILON)
			t.expect(Fleet.perHour(AVERAGE_ZONE)).toBeNear(Economy.activities.robotaxiPerPod * 60, EPSILON)
			t.expect(Fleet.perHour(nil)).toBeNear(3600, EPSILON) -- no zone: average demand
		end)

		t.it("lists only MapLayout zones, once each, with demands that average 1", function()
			local seen: { [string]: boolean } = {}
			local sum = 0
			for _, zone in Fleet.zones do
				t.expect(MapLayout.zones[zone.id] ~= nil).toBe(true)
				t.expect(seen[zone.id]).toBe(nil)
				seen[zone.id] = true
				t.expect(zone.demand).toBeGreaterThan(0)
				t.expect(Fleet.isZone(zone.id)).toBe(true)
				t.expect(Fleet.zoneName(zone.id)).toBe(MapLayout.zones[zone.id].displayName)
				sum += zone.demand
			end
			t.expect(sum / #Fleet.zones).toBeNear(1, EPSILON)
			t.expect(Fleet.isZone(Fleet.defaultZone)).toBe(true)
			t.expect(Fleet.isZone("county_loop")).toBe(false) -- the highway ring is no place to wait for riders
			t.expect(Fleet.isZone("nowhere")).toBe(false)
			t.expect(Fleet.isZone(7)).toBe(false)
		end)

		t.it("reads the pod price from the catalog and sells a pod back like a car", function()
			t.expect(Fleet.podPrice).toBe(Catalog.totalPrice(Fleet.podVehicleId, Fleet.podTrim))
			t.expect(Fleet.podPrice).toBeGreaterThan(0)
			t.expect(Fleet.sellBack).toBe(Garage.sellPrice(Fleet.podPrice))
			t.expect(Fleet.sellBack).toBe(math.floor(Fleet.podPrice * Garage.sellBackRate))
		end)

		t.it("gives 3 slots, 8 with the Fleet Manager pass", function()
			t.expect(Fleet.slotsFor(false)).toBe(3)
			t.expect(Fleet.slotsFor(true)).toBe(8)
		end)

		t.it("takes the offline rule from the §4 economy targets", function()
			t.expect(Fleet.offlineRate).toBe(Economy.activities.robotaxiOfflineRate)
			t.expect(Fleet.offlineRate).toBe(0.25)
			t.expect(Fleet.offlineCapHours).toBe(Economy.activities.robotaxiOfflineCapHours)
			t.expect(Fleet.offlineCapHours).toBe(8)
		end)
	end)

	t.describe("Earnings.accrue", function()
		t.it("is deterministic for a seed and a clock", function()
			local pods = { pod("a"), pod("b", "cedar_bend"), pod("c", "lakefront") }
			local first = Earnings.accrue(pods, T0, T0 + 5 * HOUR, true, SEED)
			local second = Earnings.accrue(pods, T0, T0 + 5 * HOUR, true, SEED)
			t.expect(first).toEqual(second)
			t.expect(first.total).toBeGreaterThan(0)
			-- Another owner's seed varies the hours differently.
			local other = Earnings.accrue(pods, T0, T0 + 5 * HOUR, true, SEED + 1)
			t.expect(math.abs(other.total - first.total)).toBeGreaterThan(EPSILON)
			-- The order the pods are listed in changes nothing.
			local reversed = Earnings.accrue({ pods[3], pods[2], pods[1] }, T0, T0 + 5 * HOUR, true, SEED)
			for uid, amount in first.perPod do
				t.expect(reversed.perPod[uid]).toBeNear(amount, EPSILON)
			end
		end)

		t.it("earns the same for a span split anywhere (timer chunks add up to one long accrual)", function()
			local pods = { pod("a"), pod("b", "the_plant") }
			local whole = Earnings.accrue(pods, T0, T0 + 2 * HOUR + 123, true, SEED).total
			local split = Earnings.accrue(pods, T0, T0 + 1234, true, SEED).total
				+ Earnings.accrue(pods, T0 + 1234, T0 + 2 * HOUR + 123, true, SEED).total
			t.expect(split).toBeNear(whole, EPSILON)
			local chunks = 0
			local from = T0
			while from < T0 + 2 * HOUR + 123 do
				local to = math.min(from + MINUTE, T0 + 2 * HOUR + 123)
				chunks += Earnings.accrue(pods, from, to, true, SEED).total
				from = to
			end
			t.expect(chunks).toBeNear(whole, EPSILON)
		end)

		t.it("averages $60 a minute per pod at average demand", function()
			local pods = {}
			for index = 1, 50 do
				table.insert(pods, pod(`pod-{index}`))
			end
			local hours = 100
			local result = Earnings.accrue(pods, T0, T0 + hours * HOUR, true, SEED)
			local perPodMinute = result.total / (#pods * hours * 60)
			t.expect(perPodMinute).toBeNear(Economy.activities.robotaxiPerPod, 0.6) -- within 1 %
		end)

		t.it("varies each pod's hour within the band, the same way every time", function()
			local lowest, highest = math.huge, -math.huge
			local hourIndex = math.floor(T0 / HOUR)
			for offset = 0, 199 do
				local factor = Earnings.hourFactor(SEED, "a", hourIndex + offset)
				t.expect(Earnings.hourFactor(SEED, "a", hourIndex + offset)).toBe(factor)
				lowest = math.min(lowest, factor)
				highest = math.max(highest, factor)
			end
			t.expect(lowest >= 1 - Fleet.hourVariation).toBe(true)
			t.expect(highest <= 1 + Fleet.hourVariation).toBe(true)
			t.expect(highest - lowest).toBeGreaterThan(Fleet.hourVariation) -- it really varies
			-- Two pods in the same hour earn differently.
			t.expect(Earnings.hourFactor(SEED, "a", hourIndex) ~= Earnings.hourFactor(SEED, "b", hourIndex)).toBe(true)
		end)

		t.it("multiplies by zone demand", function()
			local reference = Earnings.accrue({ pod("a") }, T0, T0 + 3 * HOUR, true, SEED).total
			for _, zone in Fleet.zones do
				local amount = Earnings.accrue({ pod("a", zone.id) }, T0, T0 + 3 * HOUR, true, SEED).total
				t.expect(amount / reference).toBeNear(zone.demand, EPSILON)
			end
			local busy = Earnings.accrue({ pod("a", "cedar_bend") }, T0, T0 + 3 * HOUR, true, SEED).total
			local quiet = Earnings.accrue({ pod("a", "mesa_test_site") }, T0, T0 + 3 * HOUR, true, SEED).total
			t.expect(busy).toBeGreaterThan(quiet)
			-- A zone the list no longer has earns at average demand.
			local gone = Earnings.accrue({ pod("a", "retired_zone") }, T0, T0 + 3 * HOUR, true, SEED).total
			t.expect(gone).toBeNear(reference, EPSILON)
		end)

		t.it("pays offline at the offline rate of the online rate", function()
			local pods = { pod("a"), pod("b", "cedar_bend") }
			local online = Earnings.accrue(pods, T0, T0 + 3 * HOUR, true, SEED)
			local offline = Earnings.accrue(pods, T0, T0 + 3 * HOUR, false, SEED)
			t.expect(offline.total / online.total).toBeNear(Fleet.offlineRate, EPSILON)
			t.expect(offline.perPod.b / online.perPod.b).toBeNear(0.25, EPSILON)
		end)

		t.it("stops counting offline time 8 h after the last time online", function()
			local pods = { pod("a") }
			local capped = Earnings.accrue(pods, T0, T0 + 8 * HOUR, false, SEED).total
			t.expect(Earnings.accrue(pods, T0, T0 + 20 * HOUR, false, SEED).total).toBeNear(capped, EPSILON)
			t.expect(Earnings.accrue(pods, T0, T0 + 8 * HOUR + 1, false, SEED).total).toBeNear(capped, EPSILON)
			t.expect(capped).toBeGreaterThan(Earnings.accrue(pods, T0, T0 + 6 * HOUR, false, SEED).total)
			-- About 8 h x $3,600 x 0.25 = $7,200 for a pod at average demand (each hour varies by up to 10 %).
			t.expect(capped).toBeNear(8 * 3600 * 0.25, 8 * 3600 * 0.25 * Fleet.hourVariation)
			-- Online time has no cap.
			local online8 = Earnings.accrue(pods, T0, T0 + 8 * HOUR, true, SEED).total
			t.expect(Earnings.accrue(pods, T0, T0 + 20 * HOUR, true, SEED).total).toBeGreaterThan(online8)
		end)

		t.it("earns nothing for an empty, reversed or broken span", function()
			local pods = { pod("a") }
			for _, span in { { T0, T0 }, { T0 + 60, T0 }, { 0 / 0, T0 }, { T0, math.huge } } do
				local result = Earnings.accrue(pods, span[1], span[2], true, SEED)
				t.expect(result.total).toBe(0)
				t.expect(result.perPod).toEqual({ a = 0 })
			end
			t.expect(Earnings.accrue({}, T0, T0 + HOUR, true, SEED)).toEqual({ total = 0, perPod = {} })
		end)

		t.it("adds every pod's share up to the total and skips entries that aren't pods", function()
			local pods: { any } = { pod("a"), "junk", { zone = "cedar_bend" }, pod("b", "lakefront") }
			local result = Earnings.accrue(pods, T0, T0 + 90 * MINUTE, true, SEED)
			t.expect(keysOf(result.perPod)).toEqual({ "a", "b" })
			t.expect(result.perPod.a + result.perPod.b).toBeNear(result.total, EPSILON)
			t.expect(result.perPod.a).toBeGreaterThan(0)
		end)
	end)

	t.describe("FleetService accrual (fake clock)", function()
		t.it("counts online time up to now once, never twice", function()
			local fleet = fleetWith({ pod("a"), pod("b", "cedar_bend") }, T0)
			local expected = Earnings.accrue(fleet.pods, T0, T0 + MINUTE, true, SEED).total
			t.expect(FleetService.accrueOnline(fleet, T0 + MINUTE, SEED, 1)).toBeNear(expected, EPSILON)
			t.expect(fleet.uncollected).toBeNear(expected, EPSILON)
			t.expect(fleet.lastOnlineAt).toBe(T0 + MINUTE)
			t.expect(FleetService.accrueOnline(fleet, T0 + MINUTE, SEED, 1)).toBe(0)
			-- A clock that went back counts nothing and keeps the later time.
			t.expect(FleetService.accrueOnline(fleet, T0 + 30, SEED, 1)).toBe(0)
			t.expect(fleet.lastOnlineAt).toBe(T0 + MINUTE)
			t.expect(fleet.uncollected).toBeNear(expected, EPSILON)
		end)

		t.it("multiplies online earnings by the earnings boost", function()
			local plain = fleetWith({ pod("a") }, T0)
			local boosted = fleetWith({ pod("a") }, T0)
			FleetService.accrueOnline(plain, T0 + 10 * MINUTE, SEED, 1)
			FleetService.accrueOnline(boosted, T0 + 10 * MINUTE, SEED, 2)
			t.expect(boosted.uncollected / plain.uncollected).toBeNear(2, EPSILON)
		end)

		t.it("pays the offline gap across a rejoin", function()
			local fleet = fleetWith({ pod("a"), pod("b", "lakefront") }, T0)
			-- Online for 10 minutes on the timer, then leaving (a last online accrual).
			for minute = 1, 10 do
				FleetService.accrueOnline(fleet, T0 + minute * MINUTE, SEED, 1)
			end
			local leftAt = T0 + 10 * MINUTE + 25
			FleetService.accrueOnline(fleet, leftAt, SEED, 1)
			local online = Earnings.accrue(fleet.pods, T0, leftAt, true, SEED).total
			t.expect(fleet.uncollected).toBeNear(online, EPSILON)
			t.expect(fleet.lastOnlineAt).toBe(leftAt)
			-- Back 3 hours later: the gap pays the offline rate.
			local rejoinAt = leftAt + 3 * HOUR
			local away = FleetService.accrueOffline(fleet, rejoinAt, SEED)
			t.expect(away).toBeNear(Earnings.accrue(fleet.pods, leftAt, rejoinAt, false, SEED).total, EPSILON)
			local expectedAway = 3 * (Fleet.perHour("riverside") + Fleet.perHour("lakefront")) * Fleet.offlineRate
			t.expect(away).toBeNear(expectedAway, expectedAway * Fleet.hourVariation)
			t.expect(fleet.uncollected).toBeNear(online + away, EPSILON)
			t.expect(fleet.lastOnlineAt).toBe(rejoinAt)
			-- Joining again at the same moment (or a second server's join) pays nothing more.
			t.expect(FleetService.accrueOffline(fleet, rejoinAt, SEED)).toBe(0)
			-- And the next online minute starts from the rejoin.
			local nextMinute = FleetService.accrueOnline(fleet, rejoinAt + MINUTE, SEED, 1)
			t.expect(nextMinute)
				.toBeNear(Earnings.accrue(fleet.pods, rejoinAt, rejoinAt + MINUTE, true, SEED).total, EPSILON)
		end)

		t.it("pays no more than 8 h for a longer absence", function()
			local eight = fleetWith({ pod("a") }, T0)
			local twenty = fleetWith({ pod("a") }, T0)
			local eightPay = FleetService.accrueOffline(eight, T0 + 8 * HOUR, SEED)
			local twentyPay = FleetService.accrueOffline(twenty, T0 + 20 * HOUR, SEED)
			t.expect(twentyPay).toBeNear(eightPay, EPSILON)
			t.expect(twenty.lastOnlineAt).toBe(T0 + 20 * HOUR)
		end)

		t.it("counts at most onlineCatchUpSeconds of online time from a stale save time", function()
			local fleet = fleetWith({ pod("a") }, T0 - 24 * HOUR)
			local added = FleetService.accrueOnline(fleet, T0, SEED, 1)
			local expected = Earnings.accrue(fleet.pods, T0 - Fleet.onlineCatchUpSeconds, T0, true, SEED).total
			t.expect(added).toBeNear(expected, EPSILON)
			t.expect(fleet.lastOnlineAt).toBe(T0)
		end)

		t.it("caps uncollected earnings and never takes away what is there", function()
			local fleet = fleetWith({ pod("a") }, T0)
			local cap = Fleet.uncollectedCap(1)
			t.expect(cap).toBeNear(Fleet.perHour(nil) * Fleet.uncollectedCapHours, EPSILON)
			t.expect(FleetService.addUncollected(fleet, cap + 5000)).toBeNear(cap, EPSILON)
			t.expect(fleet.uncollected).toBeNear(cap, EPSILON)
			t.expect(FleetService.addUncollected(fleet, 10)).toBe(0)
			-- Pods sold: the cap drops, but the money already waiting stays.
			local sold = fleetWith({}, T0)
			sold.uncollected = 50000
			t.expect(FleetService.addUncollected(sold, 10)).toBe(0)
			t.expect(sold.uncollected).toBe(50000)
			t.expect(FleetService.addUncollected(fleet, -5)).toBe(0)
			t.expect(FleetService.addUncollected(fleet, 0 / 0)).toBe(0)
		end)

		t.it("repairs a damaged fleet before using it", function()
			local damaged: any = { pods = "none", uncollected = 0 / 0, lastOnlineAt = "yesterday" }
			FleetService.cleanFleet(damaged, T0)
			t.expect(damaged.pods).toEqual({})
			t.expect(damaged.uncollected).toBe(0)
			t.expect(damaged.lastOnlineAt).toBe(T0) -- an untrusted time pays nothing
			t.expect(damaged.lastCollectedAt).toBe(0)
			t.expect(FleetService.accrueOffline(damaged, T0, SEED)).toBe(0)
			-- A time that was never stamped (1970) pays nothing either, rather than 8 offline hours.
			local unstamped = fleetWith({ pod("a") }, Template.UNSET_TIME)
			t.expect(FleetService.accrueOffline(unstamped, T0, SEED)).toBe(0)
			t.expect(unstamped.lastOnlineAt).toBe(T0)
		end)

		t.it("finds a pod by uid", function()
			local fleet = fleetWith({ pod("a"), pod("b", "lakefront") }, T0)
			local found, index = FleetService.findPod(fleet, "b")
			t.expect(found ~= nil and found.zone).toBe("lakefront")
			t.expect(index).toBe(2)
			t.expect((FleetService.findPod(fleet, "c"))).toBe(nil)
		end)

		t.it("runs on a clock specs can replace", function()
			FleetService.setClock(function(): number
				return T0
			end)
			t.expect(FleetService.now()).toBe(T0)
			FleetService.setClock(nil)
			t.expect(math.abs(FleetService.now() - os.time()) <= 1).toBe(true)
		end)
	end)

	t.describe("Fleet snapshot", function()
		t.it("carries the contract's fields", function()
			local fleet = fleetWith({ pod("a", "cedar_bend") }, T0)
			fleet.uncollected = 1234.9
			local snapshot = ProfileSyncService.snapshotFleet(fleet, false)
			t.expect(keysOf(snapshot :: any)).toEqual({
				"offlineCapHours",
				"offlineRate",
				"podPrice",
				"pods",
				"sellBack",
				"slots",
				"uncollected",
				"zones",
			})
			t.expect(snapshot.pods).toEqual({ { uid = "a", zone = "cedar_bend" } })
			t.expect(snapshot.pods[1] == fleet.pods[1]).toBe(false) -- a copy, never the save's table
			t.expect(snapshot.uncollected).toBe(1234) -- whole dollars
			t.expect(snapshot.slots).toBe(Fleet.defaultSlots)
			t.expect(snapshot.podPrice).toBe(Fleet.podPrice)
			t.expect(snapshot.sellBack).toBe(Fleet.sellBack)
			t.expect(snapshot.offlineRate).toBe(0.25)
			t.expect(snapshot.offlineCapHours).toBe(8)
			t.expect(#snapshot.zones).toBe(#Fleet.zones)
			for index, zone in snapshot.zones do
				t.expect(keysOf(zone :: any)).toEqual({ "demand", "id", "name", "perHour" })
				t.expect(zone.id).toBe(Fleet.zones[index].id)
				t.expect(zone.name).toBe(Fleet.zoneName(zone.id))
				t.expect(zone.demand).toBe(Fleet.zones[index].demand)
				t.expect(zone.perHour).toBeNear(Fleet.perHour(zone.id), EPSILON)
			end
		end)

		t.it("adds the pass's slots and survives a damaged fleet", function()
			t.expect(ProfileSyncService.snapshotFleet(fleetWith({}, T0), true).slots).toBe(Fleet.slotsFor(true))
			local damaged =
				ProfileSyncService.snapshotFleet({ pods = { "junk", { zone = "x" } }, uncollected = -5 }, false)
			t.expect(damaged.pods).toEqual({})
			t.expect(damaged.uncollected).toBe(0)
			t.expect(ProfileSyncService.snapshotFleet(nil, false).pods).toEqual({})
		end)
	end)
end
