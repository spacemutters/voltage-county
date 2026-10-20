--!strict
-- Redeemable codes (PLAN.md Phase 3; docs/phase-3-contracts.md "Codes"). Services/CodeService redeems them.
--
-- Each key is a code in UPPER CASE (players may type it in any case, with spaces around it), at most
-- Config/Economy codes.maxLength characters. Each code has a UTC expiry (os.time() seconds: it stops working
-- at that moment) and one effect:
--   { kind = "cash", amount = n }                          adds $n (a whole number) once
--   { kind = "multiplier", factor = f, minutes = m }       multiplies earnings by f (above 1) for m minutes
-- Every player can redeem each code once (PlayerData.codesRedeemed). tests/Codes.spec checks every entry.
--
-- Changing a code's effect after launch only affects players who haven't redeemed it yet. Retire a code by
-- moving its expiry into the past rather than deleting it, so the "expired" message still shows.

export type CashEffect = { kind: "cash", amount: number }
export type MultiplierEffect = { kind: "multiplier", factor: number, minutes: number }
export type Effect = CashEffect | MultiplierEffect

export type Code = {
	expiresAtUtc: number, -- os.time() seconds
	effect: Effect,
}

-- 2100-01-01 00:00:00 UTC: "doesn't expire" for the launch codes.
local FAR_FUTURE = 4102444800
-- 2026-01-01 00:00:00 UTC: already in the past.
local NEW_YEAR_2026 = 1767225600

local Codes: { [string]: Code } = {
	-- Launch: a little starting money.
	VOLTAGE = {
		expiresAtUtc = FAR_FUTURE,
		effect = { kind = "cash", amount = 5000 },
	},
	-- Launch: double earnings for half an hour.
	DOUBLEUP = {
		expiresAtUtc = FAR_FUTURE,
		effect = { kind = "multiplier", factor = 2, minutes = 30 },
	},
	-- Expired on purpose: tests/Codes.spec checks that it's refused as expired.
	PREVIEW = {
		expiresAtUtc = NEW_YEAR_2026,
		effect = { kind = "cash", amount = 1000 },
	},
}

return Codes
