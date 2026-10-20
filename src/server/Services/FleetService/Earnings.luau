--!strict
-- What robotaxi pods earn between two times (docs/phase-9-contracts.md "Fleet economy"). Pure and deterministic:
-- no Roblox services, only Config/Fleet and the Random datatype. Read by Services/FleetService (the online timer,
-- the offline gap on join, DevFleet) and tests/FleetEarnings.spec.
--
-- A pod earns Fleet.perHour(its zone) an hour online (rides per hour x average fare x zone demand; the calibration
-- is in Config/Fleet), at Fleet.offlineRate of that offline. Time is cut at whole hours of the clock
-- (floor(t / 3600)), and every pod's hour gets its own seeded variation factor, 1 +- Fleet.hourVariation:
-- Random.new(hash(seed, uid, hourIndex)). So:
--   * the same pods, times, mode and seed always earn exactly the same, on any server (deterministic);
--   * a span split anywhere earns the same, to floating-point error, as the whole span in one go, so the online
--     timer's one-minute chunks add up to one long accrual and nothing depends on when the timer runs;
--   * the same pod in the same hour earns in exact proportion to its zone's demand, and offline in exact
--     proportion to offlineRate.
-- Offline time counts only up to Fleet.offlineCapHours after `fromTime` (the last time the owner was online).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Fleet = require(ReplicatedStorage.Shared.Config.Fleet)

-- One pod as the save keeps it (Types.FleetPod).
export type Pod = { uid: string, zone: string }

export type Result = {
	total: number, -- $ for every pod together (not rounded)
	perPod: { [string]: number }, -- $ by pod uid (every listed pod has an entry, 0 when it earned nothing)
}

local SECONDS_PER_HOUR = 3600
local TWO_TO_32 = 4294967296
local TWO_TO_16 = 65536
-- FNV-1a, 32-bit.
local FNV_OFFSET = 2166136261
local FNV_PRIME = 16777619

local Earnings = {}

Earnings.SECONDS_PER_HOUR = SECONDS_PER_HOUR

local function isFinite(value: any): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

-- a x b modulo 2^32, exactly (a plain multiply of two 32-bit numbers can pass 2^53 and lose bits).
local function multiply32(a: number, b: number): number
	local low, high = a % TWO_TO_16, math.floor(a / TWO_TO_16)
	return (low * b + (high * b % TWO_TO_16) * TWO_TO_16) % TWO_TO_32
end

-- A 32-bit hash of one pod-hour: FNV-1a over "seed:uid:hourIndex". The seed for every Random a pod-hour uses.
function Earnings.hash(seed: number, uid: string, hourIndex: number): number
	local key = `{seed}:{uid}:{hourIndex}`
	local hash = FNV_OFFSET
	for index = 1, #key do
		hash = multiply32(bit32.bxor(hash, string.byte(key, index)), FNV_PRIME)
	end
	return hash
end

-- How much one pod's hour pays compared with the zone's rate: 1 +- Fleet.hourVariation, the same every time
-- for the same seed, pod and hour, and 1 on average.
function Earnings.hourFactor(seed: number, uid: string, hourIndex: number): number
	local random = Random.new(Earnings.hash(seed, uid, hourIndex))
	return 1 + (random:NextNumber() * 2 - 1) * Fleet.hourVariation
end

-- $ one pod earns from `fromTime` to `stop` (from < stop, the same clock) at `ratePerSecond`, hour by hour.
local function podEarnings(seed: number, uid: string, ratePerSecond: number, fromTime: number, stop: number): number
	local amount = 0
	local t = fromTime
	while t < stop do
		local hourIndex = math.floor(t / SECONDS_PER_HOUR)
		local segmentEnd = math.min(stop, (hourIndex + 1) * SECONDS_PER_HOUR)
		amount += ratePerSecond * (segmentEnd - t) * Earnings.hourFactor(seed, uid, hourIndex)
		t = segmentEnd
	end
	return amount
end

-- What `pods` earn from `fromTime` to `toTime` (seconds on any one clock, e.g. os.time()), online or offline,
-- for `seed` (FleetService uses the owner's UserId). Offline counts at most Fleet.offlineCapHours past
-- `fromTime`. An empty, reversed or non-finite span earns nothing; entries that aren't pods (no string uid) are
-- skipped. A pod whose zone Config/Fleet no longer lists earns at Fleet.referenceDemand.
function Earnings.accrue(pods: { Pod }, fromTime: number, toTime: number, online: boolean, seed: number): Result
	local result: Result = { total = 0, perPod = {} }
	for _, pod in pods do
		if type(pod) == "table" and type(pod.uid) == "string" then
			result.perPod[pod.uid] = result.perPod[pod.uid] or 0
		end
	end
	if not isFinite(fromTime) or not isFinite(toTime) or not isFinite(seed) then
		return result
	end
	local stop = if online then toTime else math.min(toTime, fromTime + Fleet.offlineCapHours * SECONDS_PER_HOUR)
	if stop <= fromTime then
		return result
	end
	local share = if online then 1 else Fleet.offlineRate
	for _, pod in pods do
		if type(pod) ~= "table" or type(pod.uid) ~= "string" then
			continue
		end
		local ratePerSecond = Fleet.perHour(pod.zone) / SECONDS_PER_HOUR * share
		local amount = podEarnings(seed, pod.uid, ratePerSecond, fromTime, stop)
		result.perPod[pod.uid] += amount
		result.total += amount
	end
	return result
end

return Earnings
