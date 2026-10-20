--!strict
-- The drive-to-earn decision for one pay interval (docs/phase-3-contracts.md "Drive-to-earn"). Pure: no Roblox
-- services and no requires, so tests/Earnings.spec can feed it hand-made samples. DriveEarnService records the
-- samples and passes Config/DriveEarn as the rules.
--
-- Given the samples of one car (oldest first, about one a second) the decision is:
--   1. AFK: the car never got more than `meaningfulDistance` away from where it was at the start of the last
--      `afkWindow` seconds -> nothing.
--   2. Loop farming: every position of the last `loopWindow` seconds fits in a box smaller than
--      `minBoundingBox` on its longer side -> nothing.
--   3. Otherwise: the horizontal distance of the steps that ended in this pay interval, counting a step only when
--      both of its samples are on a road and it isn't faster than `maxSpeed` (a jump), times `cashPerStud`,
--      capped at `capPerMinute` (scaled to the seconds this payout covers), times the earnings multiplier,
--      rounded down.
-- A jump (a step faster than `maxSpeed`) splits the AFK and loop windows: each rule looks at the jump-free
-- stretches separately and passes if any one of them moved or spread out far enough, so a teleport never makes
-- circling look like driving.

export type Sample = {
	t: number, -- seconds (any clock, the same one as `now`)
	position: Vector3, -- only X and Z are used
	onRoad: boolean,
}

-- The rules this needs (a subset of Config/DriveEarn).
export type Rules = {
	payInterval: number,
	cashPerStud: number,
	capPerMinute: number,
	afkWindow: number,
	meaningfulDistance: number,
	loopWindow: number,
	minBoundingBox: number,
}

export type Reason = "paid" | "afk" | "loop" | "noRoad"

export type Decision = {
	amount: number, -- whole dollars to pay (0 for nothing)
	reason: Reason, -- "paid", or why nothing was paid ("noRoad": no distance on roads to pay for)
	distance: number, -- studs counted (on roads, no jumps) in the pay interval
	gross: number, -- distance x cashPerStud, before the cap and the multiplier
	capped: boolean, -- the cap cut the gross down
	multiplier: number,
	moved: number, -- farthest the car got from the start of a jump-free stretch of the AFK window, studs
	boundingBox: number, -- longer side of the box holding a jump-free stretch of the loop window, studs
}

local SECONDS_PER_MINUTE = 60

local Earnings = {}

local function horizontal(a: Vector3, b: Vector3): number
	local dx, dz = b.X - a.X, b.Z - a.Z
	return math.sqrt(dx * dx + dz * dz)
end

-- The samples with from <= t <= to (`to` defaults to the newest), as a range of indices (empty: first > last).
local function within(samples: { Sample }, from: number, to: number?): (number, number)
	local first, last = #samples + 1, 0
	for index, sample in samples do
		if sample.t >= from and (to == nil or sample.t <= to) then
			first = math.min(first, index)
			last = index
		end
	end
	return first, last
end

-- Studs driven on roads by the steps that end after `from` (and at or before `to`, default the newest sample):
-- both ends on a road, and no faster than `maxSpeed` studs/s (a longer step is a jump: a teleport, a reset or a
-- respawn, and earns nothing).
function Earnings.roadDistance(samples: { Sample }, from: number, maxSpeed: number, to: number?): number
	local total = 0
	for index = 2, #samples do
		local b = samples[index]
		if b.t <= from or (to ~= nil and b.t > to) then
			continue
		end
		local a = samples[index - 1]
		local dt = b.t - a.t
		if dt <= 0 or not (a.onRoad and b.onRoad) then
			continue
		end
		local step = horizontal(a.position, b.position)
		if step <= maxSpeed * dt then
			total += step
		end
	end
	return total
end

-- How far (studs, across the ground) the car got from its first position in [from, to] (to: default the newest).
function Earnings.moved(samples: { Sample }, from: number, to: number?): number
	local first, last = within(samples, from, to)
	local origin = samples[first]
	if origin == nil then
		return 0
	end
	local farthest = 0
	for index = first + 1, last do
		farthest = math.max(farthest, horizontal(origin.position, samples[index].position))
	end
	return farthest
end

-- The longer side (studs) of the X/Z box holding every position in [from, to] (to: default the newest; 0 for
-- none).
function Earnings.boundingBox(samples: { Sample }, from: number, to: number?): number
	local first, last = within(samples, from, to)
	local origin = samples[first]
	if origin == nil then
		return 0
	end
	local minX, maxX = origin.position.X, origin.position.X
	local minZ, maxZ = origin.position.Z, origin.position.Z
	for index = first + 1, last do
		local position = samples[index].position
		minX, maxX = math.min(minX, position.X), math.max(maxX, position.X)
		minZ, maxZ = math.min(minZ, position.Z), math.max(maxZ, position.Z)
	end
	return math.max(maxX - minX, maxZ - minZ)
end

-- The most a payout covering `seconds` of driving (default one payInterval) may pay before the multiplier.
function Earnings.cap(rules: Rules, seconds: number?): number
	return rules.capPerMinute * math.max(seconds or rules.payInterval, 0) / SECONDS_PER_MINUTE
end

-- The largest `measure` of any jump-free stretch of the samples in [from, to]. A step faster than `maxSpeed`
-- (a teleport, a reset) splits the samples, so a jump can't make circling look like driving: each stretch on
-- its own has to have moved or spread out far enough.
local function widestStretch(
	samples: { Sample },
	from: number,
	to: number,
	maxSpeed: number,
	measure: (samples: { Sample }, from: number, to: number?) -> number
): number
	local first, last = within(samples, from, to)
	if first > last then
		return 0
	end
	local best = 0
	local stretchFrom = samples[first].t
	for index = first + 1, last do
		local a, b = samples[index - 1], samples[index]
		local dt = b.t - a.t
		if dt > 0 and horizontal(a.position, b.position) > maxSpeed * dt then
			best = math.max(best, measure(samples, stretchFrom, a.t))
			stretchFrom = b.t
		end
	end
	return math.max(best, measure(samples, stretchFrom, samples[last].t))
end

-- The decision for the pay interval ending at `now`.
--   samples     the car's samples, oldest first, covering at least the AFK and loop windows when it has been
--               driven that long (the first payout after getting in sees less, which is fine); samples after
--               `now` are ignored
--   now         the time of the decision (normally the newest sample's time)
--   maxSpeed    studs/s: steps faster than this are jumps (top speed x Config/DriveEarn.jumpSpeedTolerance)
--   multiplier  EconomyService.earningsMultiplier(player), applied after the cap
--   rules       Config/DriveEarn
--   payFrom     the previous decision's time: steps ending after it are paid now (default now - payInterval);
--               the cap scales with now - payFrom, so a payout for a drive that ended early is capped pro rata
function Earnings.decide(
	samples: { Sample },
	now: number,
	maxSpeed: number,
	multiplier: number,
	rules: Rules,
	payFrom: number?
): Decision
	local decision: Decision = {
		amount = 0,
		reason = "noRoad",
		distance = 0,
		gross = 0,
		capped = false,
		multiplier = multiplier,
		moved = widestStretch(samples, now - rules.afkWindow, now, maxSpeed, Earnings.moved),
		boundingBox = widestStretch(samples, now - rules.loopWindow, now, maxSpeed, Earnings.boundingBox),
	}
	if decision.moved <= rules.meaningfulDistance then
		decision.reason = "afk"
		return decision
	end
	if decision.boundingBox < rules.minBoundingBox then
		decision.reason = "loop"
		return decision
	end

	local from = payFrom or (now - rules.payInterval)
	local distance = Earnings.roadDistance(samples, from, maxSpeed, now)
	local gross = distance * rules.cashPerStud
	local cap = Earnings.cap(rules, now - from)
	decision.distance = distance
	decision.gross = gross
	decision.capped = gross > cap
	decision.amount = math.max(0, math.floor(math.min(gross, cap) * math.max(multiplier, 0)))
	decision.reason = if decision.amount > 0 then "paid" else "noRoad"
	return decision
end

return Earnings
