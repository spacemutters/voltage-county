--!strict
-- Economy targets (PLAN.md §4). Earning rates arrive with Phase 3.

local Economy = {
	startingCash = 2500,
	garageSlots = 6,
	customSlots = 3,
	-- Players can never send cash to each other (prevents scams and real-money trading).
	playerTransfers = false,
}

return Economy
