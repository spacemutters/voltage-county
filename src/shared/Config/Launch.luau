--!strict
-- Launch day (docs/roast-2026-10-24.md point 9): the one moment Season 1, the launch-week limiteds and the launch
-- events all count from. Config/Season (Season 1 starts at it), Config/Limiteds (the Launch Week wrap and plate
-- frame and the Arc Flight drop open at it) and Config/Events (the Arc Flight weekend and the bonus weekends after
-- it) read it from here, so setting it once moves every one of them (tests/Monetization.spec checks they agree).
--
-- Pure: no Roblox services, so specs run it in Edit mode.

export type Launch = {
	atUtc: number, -- Unix seconds, UTC
}

local Launch: Launch = {
	-- LAUNCH DAY. The one number to set when Davis picks the launch date.
	atUtc = 1800036000, -- 2027-01-15 18:00 UTC
}

return Launch
