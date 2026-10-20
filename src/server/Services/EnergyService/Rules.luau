--!strict
-- The pure decisions EnergyService makes (docs/phase-5-contracts.md "Server"): how a car moved between two
-- samples, whether it stands in a station's footprint, one step of charging with its bill, which low-energy
-- alert a new level sets off, limp mode, who earns the plaza hangout bonus, and which station is nearest by
-- road. No Roblox services and no state of their own, so tests/EnergyService.spec checks them in Edit mode.

local PERCENT = 100
-- Levels are float fractions: a level that is a whole percent up to float rounding counts as that percent.
local PERCENT_EPSILON = 1e-6
-- A bill of whole dollars within this of the next dollar counts as that dollar (float rounding).
local CASH_EPSILON = 1e-6
local SECONDS_PER_MINUTE = 60

export type StationKind = "ChargerStall" | "TruckCharger" | "FuelPump"

-- One server-observed sample of a car: when it was taken (seconds), where the chassis was, the chassis' speed
-- across the ground from its replicated physics velocity (studs/s), and the ground speed measured at it from
-- positions (Motion.groundSpeed; nil for a sample that started afresh).
export type MotionSample = { t: number, position: Vector3, velocitySpeed: number, groundSpeed: number? }

-- What Rules.measure needs besides the samples.
--   window         seconds of positions the ground speed is averaged over
--   maxSpeed       studs/s: the trim's top speed with AntiExploit's headroom
--   agreement      studs/s: the replicated velocity is used while it is within this of the ground speed
--   movedAt        when the car last moved before `current` (the time of the last sample whose position changed)
--   catchUpSeconds the longest stall a catch-up is spread over
--   serverMovedAt  when the server itself last moved the car (a reset), or nil
export type MeasureSettings = {
	window: number,
	maxSpeed: number,
	agreement: number,
	movedAt: number,
	catchUpSeconds: number,
	serverMovedAt: number?,
}

-- How a car moved, in the units Vehicle/Energy.drainPerSecond reads: speed studs/s across the ground, accel
-- studs/s² (positive speeding up), climb studs/s (positive up), over `seconds` (what the drain is billed for:
-- the time since the last sample, or longer for a catch-up). `groundSpeed` is the speed measured from
-- positions alone. `jumped` marks a sample that drains nothing: the first one, one with no time since the last,
-- or a move the server made. `restart` means the samples before this one no longer describe the car's motion
-- (a jump or a catch-up): drop them.
export type Motion = {
	speed: number,
	accel: number,
	climb: number,
	seconds: number,
	groundSpeed: number,
	jumped: boolean,
	restart: boolean,
}

-- One step of charging or fueling. `bill` is the whole dollars due for the energy added (plus what was owed);
-- `owed` carries the cents that don't make a dollar yet into the next step. `short` means the player's budget
-- didn't cover the whole step: `level` only went as far as it paid for.
export type ChargeStep = { level: number, bill: number, owed: number, full: boolean, short: boolean }

-- Which low-energy alerts can still go off (each goes off once per drop below its level).
export type AlertState = { warning: boolean, critical: boolean, empty: boolean }
export type Alert = "warning" | "critical" | "empty"
-- The levels the alerts use (Config/Energy): warning and critical notices, empty at 0, and the empty alert
-- re-arms once the car has been charged above `rearmEmpty` (where limp mode clears).
export type AlertLevels = { warning: number, critical: number, rearmEmpty: number }

-- A station the GPS could lead to: its MapLayout location id and where it is.
export type Candidate = { id: string, position: Vector3 }

local Rules = {}

local function finite(value: number): boolean
	return value == value and value > -math.huge and value < math.huge
end

local function flat(vector: Vector3): Vector3
	return Vector3.new(vector.X, 0, vector.Z)
end

-- Motion -----------------------------------------------------------------------------------------------------

-- How the car moved from the samples before `current` (`history`, oldest first, newest last) to `current`.
--
--   ground speed  the distance the chassis really covered across the ground over the last `window` seconds,
--                 per second, capped at maxSpeed.
--   speed         the replicated velocity's speed while it agrees with the ground speed (within `agreement`):
--                 velocity is smooth (it is the physics state, not a difference of two positions that arrived
--                 with network jitter). Otherwise the ground speed: a client that reports a velocity the car
--                 isn't doing pays for the ground it really covers.
--   accel         the change in velocity speed since the previous sample, per second, while both samples' velocity
--                 agreed with their ground speed. Otherwise the change in ground speed across the window, so a
--                 client can't steer its bill with the velocity it reports.
--   climb         the height gained over the same window, per second, from positions (on a road the height
--                 changes slowly, so arrival jitter barely shows), capped at ±maxSpeed.
--
-- A move the server made (settings.serverMovedAt since the previous sample) is a jump: it drains nothing. Any
-- other step longer than the car could drive since the previous sample is a catch-up: the server's view of the
-- car stalled (lag, or a client holding back its position) and then caught up. It is billed as travel: the whole
-- distance, at the speed that covers it since the car last moved (at most catchUpSeconds back, and never faster
-- than maxSpeed). The idle drain the stalled samples already billed is a sliver and isn't taken back.
function Rules.measure(history: { MotionSample }, current: MotionSample, settings: MeasureSettings): Motion
	local maxSpeed = settings.maxSpeed
	local still: Motion =
		{ speed = 0, accel = 0, climb = 0, seconds = 0, groundSpeed = 0, jumped = true, restart = true }
	local previous = history[#history]
	if previous == nil then
		return still
	end
	local dt = current.t - previous.t
	local offset = current.position - previous.position
	if not (dt > 0) or not finite(offset.Magnitude) then
		return still
	end
	local serverMovedAt = settings.serverMovedAt
	if serverMovedAt ~= nil and serverMovedAt > previous.t then
		return still
	end

	local step = flat(offset).Magnitude
	if step > maxSpeed * dt then
		local stalled = current.t - math.min(settings.movedAt, previous.t)
		local since = math.max(math.min(stalled, settings.catchUpSeconds), dt)
		local seconds = math.max(since, step / maxSpeed)
		local speed = step / seconds
		return {
			speed = speed,
			accel = 0,
			climb = math.clamp(offset.Y / seconds, -maxSpeed, maxSpeed),
			seconds = seconds,
			groundSpeed = speed,
			jumped = false,
			restart = true,
		}
	end

	-- The oldest sample still inside the window (or the previous one, when the window is shorter than a step).
	local base = previous
	for index = #history, 1, -1 do
		local sample = history[index]
		if current.t - sample.t > settings.window then
			break
		end
		base = sample
	end
	local span = current.t - base.t
	local travelled = flat(current.position - base.position).Magnitude
	local groundSpeed = math.min(travelled / span, maxSpeed)
	local climb = (current.position.Y - base.position.Y) / span

	local function agrees(velocity: number, ground: number?): boolean
		return ground ~= nil and math.abs(velocity - ground) <= settings.agreement
	end
	local velocitySpeed = math.clamp(current.velocitySpeed, 0, maxSpeed)
	local previousSpeed = math.clamp(previous.velocitySpeed, 0, maxSpeed)
	local trusted = agrees(velocitySpeed, groundSpeed)
	local accel: number
	if trusted and agrees(previousSpeed, previous.groundSpeed) then
		accel = (velocitySpeed - previousSpeed) / dt
	else
		local baseGround = base.groundSpeed
		accel = if baseGround ~= nil then (groundSpeed - baseGround) / span else 0
	end
	return {
		speed = if trusted then velocitySpeed else groundSpeed,
		accel = accel,
		climb = math.clamp(climb, -maxSpeed, maxSpeed),
		seconds = dt,
		groundSpeed = groundSpeed,
		jumped = false,
		restart = false,
	}
end

-- Stations ---------------------------------------------------------------------------------------------------

-- True when `position` (the car's chassis centre) is over a station part's footprint: inside its X and Z
-- extent in the part's own axes (so a pad turned to face its road still matches the painted bay), and no lower
-- than the part's bottom nor higher than `heightAbove` studs over its top (a car parked on the pad, not one on
-- a bridge above it).
function Rules.insideFootprint(
	stationCFrame: CFrame,
	stationSize: Vector3,
	position: Vector3,
	heightAbove: number
): boolean
	local localPosition = stationCFrame:PointToObjectSpace(position)
	local half = stationSize / 2
	return math.abs(localPosition.X) <= half.X
		and math.abs(localPosition.Z) <= half.Z
		and localPosition.Y >= -half.Y
		and localPosition.Y <= half.Y + heightAbove
end

-- Whole percents in a level (a level within float rounding of a percent counts as that percent).
function Rules.wholePercents(level: number): number
	return math.floor(level * PERCENT + PERCENT_EPSILON)
end

-- One step of `dt` seconds at a station adding `ratePerSecond` (fraction of a full charge per second) to
-- `level`, never past full. The energy added costs costPerFull per full charge; whole dollars of that (and of
-- `owed` from earlier steps) are billed now and the rest is carried in `owed`, so a sliver of a top-up costs
-- cents that carry over, never a whole percent. With a `budget` (the player's whole dollars), the step adds only
-- what the budget pays for and says `short` when that was less than the whole step.
function Rules.chargeStep(
	level: number,
	ratePerSecond: number,
	dt: number,
	costPerFull: number,
	owed: number,
	budget: number?
): ChargeStep
	local start = math.clamp(level, 0, 1)
	local price = math.max(costPerFull, 0)
	local carried = math.max(owed, 0)
	local gained = math.min(math.max(ratePerSecond, 0) * math.max(dt, 0), 1 - start)
	local short = false
	if budget ~= nil and price > 0 and carried + gained * price > budget + CASH_EPSILON then
		gained = math.clamp((budget - carried) / price, 0, gained)
		short = true
	end
	local reached = math.min(start + gained, 1)
	local due = carried + gained * price
	local bill = math.floor(due + CASH_EPSILON)
	return { level = reached, bill = bill, owed = math.max(due - bill, 0), full = reached >= 1, short = short }
end

-- Whether a car standing still on a compatible pad at `level` starts charging or fueling: only with at least
-- the gap `startBelow` leaves missing (Config/Energy.charging.startBelow), so a car that sits on a pad after a
-- full charge doesn't start again over the idle drain's sliver.
function Rules.canStartCharging(level: number, startBelow: number): boolean
	return level <= startBelow
end

-- Whether AntiExploit should start judging a car in limp mode by the limp speed: once its `speed` is down to
-- `capSpeed` (the limp speed with AntiExploit's headroom), or once `grace` seconds have passed since limp mode
-- began at `limpSince`, whichever comes first. A client that ignores limp mode gets no longer than that.
function Rules.limpCapDue(speed: number, capSpeed: number, limpSince: number, now: number, grace: number): boolean
	return speed <= capSpeed or now - limpSince >= grace
end

-- Alerts and limp mode ---------------------------------------------------------------------------------------

-- A fresh state: every alert can go off, so a car brought out already low says so once.
function Rules.newAlerts(): AlertState
	return { warning = true, critical = true, empty = true }
end

-- Updates `state` for a car now at `level` and returns the alert to show, if any: only the most severe one a
-- drop reaches (a drop straight from 50 % to 5 % says "critical" once, not "warning" too). Each alert re-arms
-- when the level climbs back above it (empty above levels.rearmEmpty), so the next drop says it again.
function Rules.updateAlerts(state: AlertState, level: number, levels: AlertLevels): Alert?
	if level > levels.warning then
		state.warning = true
	end
	if level > levels.critical then
		state.critical = true
	end
	if level > levels.rearmEmpty then
		state.empty = true
	end

	if level <= 0 then
		if state.empty then
			state.empty, state.critical, state.warning = false, false, false
			return "empty"
		end
	elseif level <= levels.critical then
		if state.critical then
			state.critical, state.warning = false, false
			return "critical"
		end
	elseif level <= levels.warning then
		if state.warning then
			state.warning = false
			return "warning"
		end
	end
	return nil
end

-- Whether a car is in limp mode at `level`: it starts at 0 and only clears once the level is above
-- `clearLevel`, so a car charged a sliver doesn't flick in and out of it.
function Rules.limpNext(limp: boolean, level: number, clearLevel: number): boolean
	if level <= 0 then
		return true
	elseif level > clearLevel then
		return false
	end
	return limp
end

-- Rounds a level to `step` (the Energy attribute and the save), kept within 0..1.
function Rules.roundLevel(level: number, step: number): number
	if not finite(level) then
		return if level == math.huge then 1 else 0
	end
	local clamped = math.clamp(level, 0, 1)
	if step <= 0 then
		return clamped
	end
	return math.clamp(math.floor(clamped / step + 0.5) * step, 0, 1)
end

-- The hangout bonus -------------------------------------------------------------------------------------------

-- Who earns the hangout bonus: `charging` maps each player charging at a stall to that stall's plaza. A plaza
-- with at least `minPlayers` different players charging pays each of them. Returns player -> plaza.
function Rules.hangoutPayees<P>(charging: { [P]: string }, minPlayers: number): { [P]: string }
	local counts: { [string]: number } = {}
	for _, plaza in charging do
		counts[plaza] = (counts[plaza] or 0) + 1
	end
	local payees: { [P]: string } = {}
	for player, plaza in charging do
		if counts[plaza] >= minPlayers then
			payees[player] = plaza
		end
	end
	return payees
end

-- Whole dollars of hangout bonus for `seconds` spent charging with friends at `cashPerMinute`, times the
-- player's earnings `multiplier`.
function Rules.hangoutPay(seconds: number, cashPerMinute: number, multiplier: number): number
	return math.max(math.floor(cashPerMinute * math.max(seconds, 0) / SECONDS_PER_MINUTE * multiplier), 0)
end

-- The nearest station ------------------------------------------------------------------------------------------

-- The candidate nearest `from` by road: `routeLength(position)` gives the route length there (nil when there
-- is no route). Candidates are tried nearest first in a straight line, and the search stops once the straight
-- line to the next one is already longer than the best route found (a road is rarely shorter than the straight
-- line). When no candidate has a route, the straight-line nearest is returned. Returns the id and the distance
-- (route length, or straight line in that fallback); nil when there are no candidates.
function Rules.nearestStation(
	from: Vector3,
	candidates: { Candidate },
	routeLength: (position: Vector3) -> number?
): (string?, number)
	local sorted = table.clone(candidates)
	local distanceOf: { [Candidate]: number } = {}
	for _, candidate in sorted do
		distanceOf[candidate] = flat(candidate.position - from).Magnitude
	end
	table.sort(sorted, function(a: Candidate, b: Candidate): boolean
		return distanceOf[a] < distanceOf[b]
	end)

	local bestId: string? = nil
	local bestLength = math.huge
	for _, candidate in sorted do
		if distanceOf[candidate] >= bestLength then
			break
		end
		local length = routeLength(candidate.position)
		if length ~= nil and length < bestLength then
			bestId, bestLength = candidate.id, length
		end
	end
	if bestId == nil and sorted[1] ~= nil then
		return sorted[1].id, distanceOf[sorted[1]]
	end
	return bestId, bestLength
end

return Rules
