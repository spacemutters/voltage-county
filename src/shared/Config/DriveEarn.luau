--!strict
-- Drive-to-earn tunables (PLAN.md §4 and Phase 3; docs/phase-3-contracts.md "Drive-to-earn"). The server
-- samples every driven car once per `sampleInterval`, and every `payInterval` of driving it pays for the
-- distance covered on roads, unless the car was idle (AFK) or circling a small spot (loop farming). The rules
-- live in Services/DriveEarnService/Earnings (pure, covered by tests/Earnings.spec); the sampling and paying
-- live in Services/DriveEarnService.
--
-- Calibration (PLAN.md §4: free driving pays about $300 a minute for a mid-skill player):
--   A mid-skill driver on a town and highway mix averages about `referenceMph` (40 mph) while on the road:
--   slower through Cedar Bend's grid and its lights, faster on the avenues and the County Loop. With
--   Config/World's scale (1 stud = 0.28 m) 40 mph is about 63.9 studs/s, so about 3,830 studs a minute.
--   `cashPerStud` is set so that minute pays Economy.activities.freeDrive ($300): about $0.078 a stud.
--   Driving faster pays more, up to `capPerMinute` = 1.2 x freeDrive ($360, reached at an average of about
--   48 mph). Cruising the County Loop at its 70 mph limit (about $525 before the cap) or a hypercar lapping it
--   flat out therefore earns $360, not $500-$1,000+: highway driving stays close to the §4 rate, free driving
--   stays well under the job rates (rideshare and delivery $1,000, freight $3,000) and never becomes the
--   fastest road to the Arc. Earnings multipliers (code boosts) apply after the cap.
--   Dev/EarnTests.drive at its default 45 mph cruise checks the reference rate; run it with cruiseMph = 70 as
--   well to see what highway drivers get (the cap).

local Units = require(script.Parent.Parent.Util.Units)
local AntiExploit = require(script.Parent.AntiExploit)
local Economy = require(script.Parent.Economy)

local SECONDS_PER_MINUTE = 60

-- The average speed on the road (mph) that pays exactly Economy.activities.freeDrive per minute.
local REFERENCE_MPH = 40
-- The per-minute cap, as a multiple of Economy.activities.freeDrive.
local CAP_MULTIPLE = 1.2

local studsPerReferenceMinute = Units.mphToStuds(REFERENCE_MPH) * SECONDS_PER_MINUTE

local DriveEarn = {
	-- Seconds between samples of each driven car (server-observed position and whether it is on a road).
	sampleInterval = 1,
	-- Seconds of driving (sitting in your own car's Driver seat) between payouts. Each payout covers the
	-- driving since the previous one.
	payInterval = 60,

	referenceMph = REFERENCE_MPH,
	capMultiple = CAP_MULTIPLE,
	-- $ per stud driven on roads (about 0.078; see the calibration above).
	cashPerStud = Economy.activities.freeDrive / studsPerReferenceMinute,
	-- The most one minute of driving pays before multipliers ($360). A payout covering more or less than a
	-- minute (a drive that ends between payouts) scales it.
	capPerMinute = Economy.activities.freeDrive * CAP_MULTIPLE,

	-- A car counts as on the road within half the road's width plus this many studs of a centre line (the
	-- car's centre may sit beyond the edge line while its wheels are still on the asphalt: half a car's width
	-- is about 3 studs).
	onRoadMargin = 4,
	-- A step between two samples is ignored when it is faster than the car's catalog top speed times this
	-- (the same headroom AntiExploit allows), so a teleport, a server reset or a respawn earns nothing.
	-- AntiExploit deals with cheaters; earnings simply skip the step.
	jumpSpeedTolerance = AntiExploit.speedTolerance,

	-- AFK: nothing is paid when the car has not moved more than `meaningfulDistance` studs (across the ground,
	-- from where it was at the start of the window) within the last `afkWindow` seconds. 40 studs is about
	-- three car lengths: rolling a little or being nudged doesn't count as driving.
	afkWindow = 120,
	meaningfulDistance = 40,
	-- Loop farming: nothing is paid when every position of the last `loopWindow` seconds fits in a box smaller
	-- than `minBoundingBox` studs on its longer side. A tight circle in a lot stays under 100 studs across,
	-- while two minutes of real driving, even slowly round one downtown block (300-stud grid), spans more.
	loopWindow = 120,
	minBoundingBox = 250,

	-- How a payout is booked and shown.
	reason = "drive", -- EconomyService.add reason (analytics transaction)
	notifyFormat = "+%s for driving", -- %s is the amount, formatted "$1,234"
	notifyKind = "success", -- toast kind (Config/Gps toast.kindColors)

	-- Studio only: after every payout decision DriveEarnService sets these player attributes, so
	-- Dev/EarnTests can line its measurements up with the pay intervals and show why a minute paid or didn't.
	debugTickAttribute = "DriveEarnTick", -- a counter, bumped on every decision
	debugDecisionAttribute = "DriveEarnLast", -- the last decision, as JSON
}

return DriveEarn
