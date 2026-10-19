--!strict
-- Redeemable codes (Phase 3): UTC expiry and one effect each; one redemption per player.

export type Code = {
	expiresAtUtc: number, -- os.time() seconds
	effect: { kind: "cash", amount: number } | { kind: "multiplier", factor: number, minutes: number },
}

local Codes: { [string]: Code } = {}

return Codes
