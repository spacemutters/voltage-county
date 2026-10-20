--!strict
-- Robotaxi fleet tunables (PLAN.md §4 and Phase 9; docs/phase-9-contracts.md "Fleet economy"): what a pod costs
-- and sells back for, how many a player may run, the zones a pod can serve and how busy each is, what a pod earns
-- online and offline, the uncollected cap, collecting, the Fleet Manager pass and what players read. Read by
-- Services/FleetService (and its pure Earnings), Services/ProfileSyncService (the fleet part of the profile
-- snapshot), the phone's Fleet app, the dealership's fleet card and the HUD's fleet chip. Pure data plus a few
-- derived numbers: no Roblox services.
--
-- Earnings are simulated, never physical: a pod is a line in the save, not a car on the road (the ambient pods
-- are Services/TrafficService's and earn nothing).
--
-- Calibration (PLAN.md §4, Economy.activities.robotaxiPerPod: $60 a minute per pod while its owner is online):
--   A pod in a zone of average demand (referenceDemand, 1) gives RIDES_PER_HOUR rides an hour (12: one about
--   every 5 minutes, counting the pickup, the ride and getting back into position) at averageFare each:
--       averageFare        = robotaxiPerPod x 60 / ridesPerHour = 60 x 60 / 12                         = $300
--       per pod per hour   = ridesPerHour x averageFare x demand = 12 x $300 x 1                       = $3,600
--                                                                                          = $60 a minute
--   averageFare is derived from the target, so retuning ridesPerHour keeps the rate on target.
--   Zone demand multiplies that: a busier zone means more rides. The zones' demands average exactly 1, so a fleet
--   spread evenly over every zone also lands on $60 a minute per pod (tests/FleetEarnings.spec checks both).
--   Each pod's hour is varied by up to +-hourVariation (10 %), seeded per pod per hour (FleetService/Earnings):
--   the mean is 1, so over hours the rate is the target, but no two pods or hours earn quite the same.
--   Offline: offlineRate (0.25) of the online rate, counted for at most offlineCapHours (8) after the owner was
--   last online: one absence pays a pod at most 8 x $3,600 x 0.25 = $7,200 at average demand.
--   Uncollected cap: uncollectedCapHours (8) hours of online pay per pod at average demand ($28,800 a pod).
--   Earnings past it wait for a Collect: a nudge to come back, never a loss of what is already there.
--   A pod costs the ohm_pod trim's catalog price ($40,000 in Config/Vehicles) and pays that back after about
--   11 hours online (40,000 / 3,600): a slow, steady earner beside the §4 job rates, as a tycoon layer should be.
--   Selling one back pays Config/Garage.sellBackRate (60 %) of that, like a car: $24,000.

local Catalog = require(script.Parent.Parent.Vehicle.Catalog)
local Economy = require(script.Parent.Economy)
local Garage = require(script.Parent.Garage)
local MapLayout = require(script.Parent.MapLayout)

local MINUTES_PER_HOUR = 60

-- The fleet car: a pod is this vehicle and trim (Config/Vehicles, acquisition "fleet").
local POD_VEHICLE_ID = "ohm_pod"
local POD_TRIM = "standard"
-- Rides a pod gives an hour at average demand (see the calibration above).
local RIDES_PER_HOUR = 12

-- A zone a pod can serve: a MapLayout zone id and how busy it is (1 = average).
export type Zone = { id: string, demand: number }

-- The Fleet Manager pass (Phase 12; Config/Monetization.passes[key] holds its id, 0 or missing = not created).
export type Pass = {
	key: string, -- Config/Monetization.passes key, and the MonetizationService.hasPass id
	bonusSlots: number, -- pod slots on top of defaultSlots
	autoCollect: boolean, -- earnings go straight to the wallet on every tick
	attribute: string, -- server-set player attribute: true while the pass is owned (ProfileSyncService reads it)
}

local onlinePerMinute = Economy.activities.robotaxiPerPod
local podPrice = Catalog.totalPrice(POD_VEHICLE_ID, POD_TRIM) or 0

local Fleet = {
	-- What a pod is and what it costs.
	podVehicleId = POD_VEHICLE_ID,
	podTrim = POD_TRIM,
	-- $ per pod: the trim's catalog price, read from Config/Vehicles (0 would mean pods aren't for sale).
	podPrice = podPrice,
	-- $ for selling one pod back: Config/Garage's sell-back share of the price, rounded down like a car's.
	sellBack = Garage.sellPrice(podPrice),

	-- Pods a player may run without the pass (PLAN.md Phase 9).
	defaultSlots = 3,
	pass = {
		key = "fleetManager",
		bonusSlots = 5,
		autoCollect = true,
		attribute = "FleetManager",
	} :: Pass,

	-- The zones a pod can serve, in the order the Fleet app lists them (MapLayout.zoneOrder, without the County
	-- Loop: a highway ring is no place to wait for riders). Demands average exactly 1.
	zones = {
		{ id = "cedar_bend", demand = 1.3 }, -- downtown: offices, the dealership, the used lot
		{ id = "riverside", demand = 1 }, -- the suburbs: steady school and shopping runs
		{ id = "the_plant", demand = 0.9 }, -- shift changes at the factory and depots
		{ id = "mesa_test_site", demand = 0.7 }, -- out of town: few riders, long waits
		{ id = "lakefront", demand = 1.1 }, -- the lake, the bridge and the overlook
	} :: { Zone },
	-- The zone a new pod is offered first: the busiest.
	defaultZone = "cedar_bend",
	-- Average demand: the demand the §4 rate is set at, and what a pod in a zone this list no longer has earns at.
	referenceDemand = 1,

	-- Earnings (see the calibration above).
	ridesPerHour = RIDES_PER_HOUR,
	averageFare = onlinePerMinute * MINUTES_PER_HOUR / RIDES_PER_HOUR, -- $ per ride
	onlinePerMinute = onlinePerMinute, -- $ a minute per pod at average demand while the owner is online
	hourVariation = 0.1, -- each pod-hour pays 1 +- this (seeded), mean 1
	offlineRate = Economy.activities.robotaxiOfflineRate, -- share of the online rate while the owner is away
	offlineCapHours = Economy.activities.robotaxiOfflineCapHours, -- away time past this earns nothing
	uncollectedCapHours = 8, -- uncollected earnings stop growing at this many hours of average online pay a pod

	-- Seconds between online accruals: one slow timer for every player (no per-frame polling).
	tickSeconds = 60,
	-- The longest gap one online accrual counts (a stalled timer); an older save time (damaged or rewound) counts
	-- from this long ago instead, so it can never pay a lifetime of "online" time.
	onlineCatchUpSeconds = 600,
	-- Seconds between two collects by the same player.
	collectCooldownSeconds = 5,

	-- EconomyService reasons (Roblox economy analytics item SKUs).
	reasons = {
		buy = "pod", -- buying a pod
		collect = "fleet", -- fleet earnings collected (or auto-collected with the pass)
		sell = Garage.sellReason, -- selling a pod back, like a car
		refund = "refund", -- a pod's price given back when the purchase fails after the charge
	},

	-- Toast kind (Config/Gps toast.kindColors) for the "while you were away" notice.
	notifyKind = "success",

	-- What the player is told. Plain words: these show as toasts and in the Fleet app.
	messages = {
		notLoaded = "Your fleet is still loading. Try again in a moment.",
		notForSale = "Pods aren't for sale right now.",
		unknownZone = "Pods can't work in that area.",
		noSlots = "All your pod slots are full. Sell a pod to make room.",
		noCash = "You need %s more for a pod.", -- the amount short, e.g. "$1,200"
		bought = "Your new pod is on the road in %s.", -- zone name
		buyFailed = "Couldn't buy a pod right now. Try again in a moment.",
		notFound = "That pod isn't in your fleet.",
		sameZone = "That pod already works in %s.", -- zone name
		assigned = "Your pod now works in %s.", -- zone name
		assignFailed = "Couldn't move that pod right now. Try again in a moment.",
		nothingToCollect = "Nothing to collect yet. Your pods are still out earning.",
		collectWait = "You just collected. Try again in a moment.",
		walletFull = "Your wallet is full. Spend some cash first.",
		collected = "Collected %s from your fleet.", -- amount
		collectFailed = "Couldn't collect right now. Try again in a moment.",
		sold = "Sold a pod for %s.", -- amount
		sellFailed = "Couldn't sell that pod right now. Try again in a moment.",
		awayEarnings = "Your pods earned %s while you were away. Collect it in the Fleet app.", -- amount
		-- The offline rule as players read it. Keep it in step with offlineRate and offlineCapHours.
		offlineRule = "Pods earn a quarter as much while you're away, for up to 8 hours.",
		devOnly = "That only works in Studio.",
		devOffline = "Pretended you were away for %s hours. Your pods earned %s.", -- hours, amount
	},
}

local zoneById: { [string]: Zone } = {}
for _, zone in Fleet.zones do
	zoneById[zone.id] = zone
end

-- The Fleet zone with this id, or nil.
function Fleet.zone(zoneId: string): Zone?
	return zoneById[zoneId]
end

-- True when a pod may be assigned to this zone.
function Fleet.isZone(zoneId: any): boolean
	return type(zoneId) == "string" and zoneById[zoneId] ~= nil
end

-- How busy a zone is: its demand, or referenceDemand for a zone this list doesn't have (one removed in an update).
function Fleet.demandOf(zoneId: any): number
	local zone = if type(zoneId) == "string" then zoneById[zoneId] else nil
	return if zone ~= nil then zone.demand else Fleet.referenceDemand
end

-- The zone's name as players read it (MapLayout's display name), or the id when MapLayout has no such zone.
function Fleet.zoneName(zoneId: string): string
	local zone = MapLayout.zones[zoneId]
	return if zone ~= nil then zone.displayName else zoneId
end

-- Expected $ a pod earns in an hour online in this zone, before the hourly variation and earnings boosts:
-- ridesPerHour x averageFare x demand.
function Fleet.perHour(zoneId: any): number
	return Fleet.ridesPerHour * Fleet.averageFare * Fleet.demandOf(zoneId)
end

-- Pods a player may run: defaultSlots, plus the pass's bonus while they own the Fleet Manager pass.
function Fleet.slotsFor(hasPass: boolean): number
	return Fleet.defaultSlots + (if hasPass then Fleet.pass.bonusSlots else 0)
end

-- The most a fleet of `podCount` pods holds uncollected: uncollectedCapHours of average online pay per pod.
function Fleet.uncollectedCap(podCount: number): number
	return math.max(podCount, 0) * Fleet.perHour(nil) * Fleet.uncollectedCapHours
end

return Fleet
