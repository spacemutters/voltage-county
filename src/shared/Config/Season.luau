--!strict
-- The current season and the daily login streak (PLAN.md Phase 12 and §11; docs/phase-12-contracts.md
-- "Live-ops"). Services/SeasonService and Services/StreakService read this; both are reward ladders.
--
-- Season: 30 tiers with a free and a premium track, 6-8 weeks long, lined up with a drop. Season XP comes from
-- playing: a fixed amount for each drive-to-earn payout (about one a minute of driving) and for each job paid,
-- never from boosts, VIP or anything bought, so nothing sold makes the track faster. `tiers[n].xp` is the total
-- season XP that reaches tier n. Each reward is claimed once per track; the premium track needs the season pass
-- (Config/Monetization.passes[passKey], a new pass each season). A new season id starts everyone at 0.
--
-- Rewards: cash (in-game $), credits (Design Credits: looks, never stats) or an exclusive look: a wrap (a plate
-- frame once those exist), saved in PlayerData.cosmetics under its look id (`ref`, an id the Wrap & Tint shop knows,
-- Config/Customization.exclusiveWraps, like the Starter Pack's and the club's looks) with serial 0. Nothing is
-- random.
--
-- Times are Unix seconds in UTC (os.time()).

export type RewardKind = "cash" | "credits" | "wrap" | "plate"
export type Reward = { kind: RewardKind, amount: number?, ref: string? }
export type Tier = { xp: number, free: Reward?, premium: Reward? }
export type Track = "free" | "premium"

export type StreakReward = { cash: number, credits: number? }

export type Season = {
	id: string, -- "" = no season
	name: string,
	startsAtUtc: number,
	endsAtUtc: number,
	claimGraceSeconds: number, -- rewards already reached can still be claimed this long after the end
	passKey: string, -- Config/Monetization.passes key of this season's pass (the premium track)
	xp: {
		perReason: { [string]: number }, -- season XP per EconomyService.add with exactly this reason
		perPrefix: { { prefix: string, xp: number } }, -- ... or with a reason starting with this
	},
	tiers: { Tier },
	reason: string, -- EconomyService reason for cash rewards
	attributes: { xp: string, tier: string, premium: string, claimed: string }, -- player attributes for the UI
	messages: { [string]: string },
	streak: {
		daySeconds: number, -- a streak day is a UTC calendar day
		rewards: { StreakReward }, -- one per day of a cycle; after the last day the cycle starts again
		reason: string, -- EconomyService reason for streak cash
		attributes: { day: string, claimable: string, nextDay: string },
		messages: { [string]: string },
	},
}

local DAY = 24 * 60 * 60
local WEEK = 7 * DAY

-- Season 1 tier ladder.
local TIER_COUNT = 30
local FIRST_TIER_XP = 500 -- a first reward within the first session
local XP_PER_TIER = 1000 -- tier 30 at 29,500 XP: roughly 35-50 hours of driving and jobs over the 7 weeks
local FREE_CASH_BASE = 5000
local FREE_CASH_STEP = 500
local PREMIUM_CASH_FACTOR = 2
local FREE_CREDIT_TIERS = { [10] = 1, [20] = 1, [30] = 1 }
local PREMIUM_CREDIT_TIERS = { [5] = 2, [15] = 2, [25] = 2 }
-- Exclusive wraps in Config/Customization.exclusiveWraps. A plate frame (kind "plate") joins once plate frames are a
-- look the shop can put on a car; until then every look reward here is a wrap (tests/Monetization.spec checks).
local PREMIUM_LOOKS: { [number]: Reward } = {
	[10] = { kind = "wrap", ref = "season1_wrap" },
	[20] = { kind = "wrap", ref = "season1_arc_wrap" },
	[30] = { kind = "wrap", ref = "season1_finale_wrap" },
}

local function buildTiers(): { Tier }
	local tiers: { Tier } = {}
	for n = 1, TIER_COUNT do
		local cash = FREE_CASH_BASE + (n - 1) * FREE_CASH_STEP
		local free: Reward = if FREE_CREDIT_TIERS[n] ~= nil
			then { kind = "credits", amount = FREE_CREDIT_TIERS[n] }
			else { kind = "cash", amount = cash }
		local premium: Reward = { kind = "cash", amount = cash * PREMIUM_CASH_FACTOR }
		if PREMIUM_LOOKS[n] ~= nil then
			premium = PREMIUM_LOOKS[n]
		elseif PREMIUM_CREDIT_TIERS[n] ~= nil then
			premium = { kind = "credits", amount = PREMIUM_CREDIT_TIERS[n] }
		end
		table.insert(tiers, { xp = FIRST_TIER_XP + (n - 1) * XP_PER_TIER, free = free, premium = premium })
	end
	return tiers
end

local Season: Season = {
	id = "s1",
	name = "Season 1: Lift Off",
	startsAtUtc = 1800036000, -- 2027-01-15 18:00 UTC, with the Arc Flight drop (Config/Limiteds arc_flight_1)
	endsAtUtc = 1800036000 + 7 * WEEK, -- 2027-03-05 18:00 UTC
	claimGraceSeconds = WEEK,
	passKey = "seasonPass",
	xp = {
		perReason = { drive = 10 }, -- Config/DriveEarn.reason: one payout per minute of driving
		perPrefix = { { prefix = "job:", xp = 60 } }, -- Config/Jobs.reasonPrefix: each job paid
	},
	tiers = buildTiers(),
	reason = "season",
	attributes = { xp = "SeasonXp", tier = "SeasonTier", premium = "SeasonPremium", claimed = "SeasonClaimed" },
	messages = {
		off = "The season pass is paused right now. Check back soon.",
		none = "There's no season running right now.",
		ended = "This season is over.",
		loading = "Your progress is still loading. Try again in a moment.",
		unknownTier = "That tier doesn't exist.",
		locked = "Reach tier %d to claim this.", -- tier
		premium = "This reward is on the premium track. Get the season pass to claim it.",
		claimed = "You've already claimed this reward.",
		noReward = "There's no reward on this track at this tier.",
		notReady = "This reward isn't ready yet. Try again later.",
		cash = "Claimed %s!", -- "$5,000"
		credits = "Claimed %d Design Credits!",
		credit = "Claimed 1 Design Credit!",
		look = "Claimed a new look: check the Wrap & Tint shop.",
		full = "Your wallet or credits are full, so this can't be claimed yet.",
	},

	streak = {
		daySeconds = DAY,
		rewards = {
			{ cash = 1000 },
			{ cash = 1500 },
			{ cash = 2000 },
			{ cash = 2500 },
			{ cash = 3000 },
			{ cash = 4000 },
			{ cash = 5000, credits = 1 }, -- the occasional credit: day 7 of every week-long run
		},
		reason = "streak",
		attributes = { day = "StreakDay", claimable = "StreakClaimable", nextDay = "StreakNextDayAt" },
		messages = {
			off = "Daily rewards are paused right now. Check back soon.",
			loading = "Your progress is still loading. Try again in a moment.",
			claimed = "You've already claimed today's reward. Come back tomorrow!",
			reward = "Day %d reward: %s!", -- day, "$1,000"
			rewardCredit = "Day %d reward: %s and a Design Credit!",
			full = "Your wallet is full, so today's reward can't be claimed yet.",
		},
	},
}

return Season
