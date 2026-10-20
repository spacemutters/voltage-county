--!strict
-- Player data tunables for Services/DataService (PLAN.md §6 and Phase 3; docs/phase-3-contracts.md
-- "Player data"). Starting cash and slot counts live in Config/Economy; everything else a fresh profile
-- starts with lives here.
--
-- Changing the shape of PlayerData is a schema change (CLAUDE.md hard rule 7): bump `schemaVersion`, add the
-- step to DataService/Migrations and cover it in tests/Migrations.spec.luau.

local Data = {
	-- DataStore names. Studio always uses its own store, so Studio playtests (API access is on for this place)
	-- never read or write live player data.
	storeName = "PlayerData",
	studioStoreName = "PlayerData_Studio",

	-- Each player's profile key is this prefix followed by their UserId.
	profileKeyPrefix = "Player_",

	-- The PlayerData version this code writes. Saves at a lower version are migrated on load; a save at a
	-- higher version (written by a newer server) is refused rather than downgraded.
	--   2  timed earnings boosts (Phase 3)
	--   3  owned cars remember `favorite` and `paid` (Phase 4 garage)
	--   4  owned cars remember their `energy` level (Phase 5 charging and fuel)
	schemaVersion = 4,
	-- A save with no version field predates versioning and is treated as this version.
	unversionedVersion = 1,

	-- ProcessReceipt idempotency: keep this many of the most recent PurchaseIds.
	maxReceipts = 100,

	-- DataService.waitFor gives up after this many seconds when no timeout is passed.
	waitForTimeout = 30,

	-- Give up starting a player's session after this many seconds and kick them with messages.loadFailed.
	-- (ProfileStore's own 120 s limit is off because DataService passes a Cancel function.)
	sessionStartTimeout = 120,

	-- Player attribute set to true once the player's data has loaded (clients can wait on it).
	loadedAttribute = "DataLoaded",

	-- Services/ProfileSyncService sends each player a snapshot of their own profile on load and after changes.
	-- A burst of changes (a purchase touches cash and the garage) is coalesced: at most one snapshot per
	-- player every this many seconds.
	snapshotMinInterval = 0.3,

	-- Values a fresh profile starts with (cash and slots come from Config/Economy).
	defaults = {
		credits = 0, -- Design Credits; the free design is tracked by credits.freeDesignUsed
		-- A new car, and every car a pre-version-4 save already owned, starts with a full charge or tank (energy
		-- is a fraction: 1 = full, 0 = empty).
		vehicleEnergy = 1,
		settings = {
			units = "mph" :: "mph" | "kph",
			camera = "chase",
			musicVolume = 0.5,
		},
	},

	-- Kick messages. Plain words: these are what the player reads.
	messages = {
		loadFailed = "We couldn't load your save. Please rejoin in a moment.",
		newerVersion = "This server is out of date for your save. Please rejoin to get a newer server.",
		sessionEnded = "Your save was opened on another server. Please rejoin.",
	},
}

return Data
