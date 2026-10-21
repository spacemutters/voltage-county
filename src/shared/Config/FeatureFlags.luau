--!strict
-- Live feature switches (PLAN.md Phase 12; docs/phase-12-contracts.md "Live-ops"). Services/FeatureFlagService
-- answers isOn(name) from these defaults, overridden by a DataStore key it re-reads every `live.refreshSeconds`,
-- so any feature can be switched off (or on) on every server without a restart: a kill switch per feature, the
-- AI Car Designer included.
--
-- The override is one DataStore value, a table of name = true / false (anything that isn't a boolean is
-- ignored). A name that is neither here nor in the override is off. Studio reads and writes its own store, so a
-- Studio test never switches anything on the live game.

export type Live = {
	store: string, -- DataStore name on live servers
	studioStore: string, -- DataStore name in Studio
	key: string, -- the key holding the override table
	refreshSeconds: number, -- how often every server re-reads it
}

export type FeatureFlags = {
	defaults: { [string]: boolean },
	live: Live,
}

local FeatureFlags: FeatureFlags = {
	defaults = {
		designer = true, -- the AI Car Designer and AI mods (Config/Designer.featureFlag)
		store = true, -- the Robux store: credit packs, passes, the Voltage Club, the Starter Pack
		drops = true, -- limited drops and limited cosmetics (Services/LimitedService)
		events = true, -- scheduled events: banners, multipliers, bonus credits (Services/EventService)
		season = true, -- the season pass track and its XP (Services/SeasonService)
		streak = true, -- daily login streak rewards (Services/StreakService)
		billboards = true, -- AdGui highway billboards (they still show only when Roblox serves an ad)
		rewardedAds = false, -- "watch an ad for 1 credit a day": off until the game is eligible (PLAN.md §11)
	},
	live = {
		store = "LiveOps",
		studioStore = "LiveOps_Studio",
		key = "flags",
		refreshSeconds = 60,
	},
}

return FeatureFlags
