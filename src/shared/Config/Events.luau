--!strict
-- Scheduled events (PLAN.md Phase 12; docs/phase-12-contracts.md "Live-ops"): banners, the featured dealership
-- pad, earnings multipliers, bonus-credit weekends and countdowns, on a UTC schedule. Services/EventService turns
-- an event on at its start and off at its end on every server without a restart, and tells every client
-- (Net EventUpdate) so banners and countdowns change on time.
--
-- Times are Unix seconds in UTC (os.time()). An event runs from startsAtUtc up to, not including, endsAtUtc.
-- Besides `schedule`, EventService re-reads extra events from a DataStore key every `live.refreshSeconds`, so an
-- event can be added or moved on the live game without an update (the same shape as below; a malformed one is
-- skipped and reported).
--
-- Fair monetization (CLAUDE.md hard rule 6): events change in-game earnings and how many credits a pack gives,
-- never a Robux price.
--
-- The launch events count from launch day (Config/Launch, shared with Config/Season and Config/Limiteds), so setting
-- that one number moves them with the season and the launch-week limiteds.

local Launch = require(script.Parent.Launch)

export type Event = {
	id: string, -- unique; letters, digits and _ only
	name: string, -- the banner title
	startsAtUtc: number,
	endsAtUtc: number,
	banner: string?, -- the banner's line under the title
	-- The Config/Vehicles id whose dealership pad gets the spotlight while the event runs (DealershipService).
	featuredVehicleId: string?,
	earningsMultiplier: number?, -- 1.5 = every earning path pays 50% more while it runs (through the boost path)
	bonusCredits: number?, -- extra share of credits on every credit pack while it runs: 0.5 = +50%
}

-- How several events running at once combine:
--   "add"       bonuses add up (1.5x and 1.2x make 1.7x; +50% and +25% make +75%)
--   "multiply"  multipliers multiply (1.5x and 1.2x make 1.8x)
--   "max"       only the biggest counts
export type Stacking = "add" | "multiply" | "max"

export type Events = {
	launchAtUtc: number, -- launch day (Config/Launch): the launch events below count from it
	schedule: { Event },
	stacking: { earnings: Stacking, credits: Stacking },
	maxEarningsMultiplier: number, -- the most all running events together multiply earnings by
	maxBonusCredits: number, -- the most extra share of credits all running events together give
	upcoming: { windowSeconds: number, max: number }, -- countdowns: events starting within the window, soonest first
	live: { store: string, studioStore: string, key: string, refreshSeconds: number },
	maxLiveEvents: number, -- a DataStore list longer than this is cut (a damaged value can't flood the server)
}

local HOUR = 60 * 60
local DAY = 24 * HOUR
local WEEK = 7 * DAY
local LAUNCH_AT_UTC = Launch.atUtc
local WEEKEND = 60 * HOUR -- Friday 18:00 to Monday 06:00 UTC

local Events: Events = {
	launchAtUtc = LAUNCH_AT_UTC,

	-- The dates in the comments are for launch day 2027-01-15 18:00 UTC.
	schedule = {
		{
			id = "arc_flight_weekend",
			name = "Arc Flight drop weekend",
			startsAtUtc = LAUNCH_AT_UTC, -- 2027-01-15 18:00 UTC, with the Arc Flight drop (Config/Limiteds)
			endsAtUtc = LAUNCH_AT_UTC + WEEKEND, -- 2027-01-18 06:00 UTC
			banner = "The Arc Flight is here, and everything you earn pays 50% more all weekend.",
			featuredVehicleId = "ohm_arc",
			earningsMultiplier = 1.5,
		},
		{
			id = "credit_weekend_1",
			name = "Bonus credit weekend",
			startsAtUtc = LAUNCH_AT_UTC + WEEK, -- 2027-01-22 18:00 UTC
			endsAtUtc = LAUNCH_AT_UTC + WEEK + WEEKEND, -- 2027-01-25 06:00 UTC
			banner = "Every Design Credit pack gives 50% more credits.",
			bonusCredits = 0.5,
		},
		{
			id = "double_pay_weekend_1",
			name = "Double pay weekend",
			startsAtUtc = LAUNCH_AT_UTC + 4 * WEEK, -- 2027-02-12 18:00 UTC
			endsAtUtc = LAUNCH_AT_UTC + 4 * WEEK + WEEKEND, -- 2027-02-15 06:00 UTC
			banner = "Driving, jobs and your fleet all pay double.",
			earningsMultiplier = 2,
		},
	},

	stacking = { earnings = "add", credits = "max" },
	maxEarningsMultiplier = 2,
	maxBonusCredits = 1,

	upcoming = { windowSeconds = 7 * DAY, max = 3 },

	live = {
		store = "LiveOps",
		studioStore = "LiveOps_Studio",
		key = "events",
		refreshSeconds = 300,
	},
	maxLiveEvents = 50,
}

return Events
