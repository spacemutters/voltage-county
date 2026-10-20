--!strict
-- Redeeming codes (Services/CodeService.evaluate, a pure decision): unknown codes, expiry against a fixed
-- "now", one redemption per player, success for cash and for a timed multiplier, and case and whitespace
-- handling; plus the shipped Config/Codes (well-formed, two launch codes live, one expired). Pure logic on
-- fixtures: runs in Edit mode.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Codes = require(ReplicatedStorage.Shared.Config.Codes)
local Economy = require(ReplicatedStorage.Shared.Config.Economy)
local Harness = require(ReplicatedStorage.Shared.Testing.Harness)
local Types = require(ReplicatedStorage.Shared.Types)
local CodeService = require(ServerScriptService.Server.Services.CodeService)
local EconomyService = require(ServerScriptService.Server.Services.EconomyService)

local NOW = 1800000000 -- a fixed "now" (os.time() seconds, January 2027)
local HOUR = 3600
local SECONDS_PER_MINUTE = 60
local YEAR_2099 = 4070908800 -- 2099-01-01 00:00:00 UTC: launch codes last at least this long

local FIXTURE: { [string]: Codes.Code } = {
	CASHME = { expiresAtUtc = NOW + HOUR, effect = { kind = "cash", amount = 2500 } },
	BOOST = { expiresAtUtc = NOW + HOUR, effect = { kind = "multiplier", factor = 2, minutes = 30 } },
	OLD = { expiresAtUtc = NOW - HOUR, effect = { kind = "cash", amount = 100 } },
	EDGE = { expiresAtUtc = NOW, effect = { kind = "cash", amount = 100 } }, -- stops working exactly now
}

local messages = Economy.codes.messages

return function(t: Harness.Api)
	t.describe("CodeService.evaluate", function()
		t.it("refuses a code that doesn't exist", function()
			local decision = CodeService.evaluate("NOPE", FIXTURE, NOW, {})
			t.expect(decision.ok).toBe(false)
			t.expect(decision.status).toBe("unknown")
			t.expect(decision.message).toBe(messages.unknown)
			t.expect(decision.key).toBe(nil)
		end)

		t.it("asks for a code when nothing was typed", function()
			for _, typed in { "", "   ", "\t\n" } do
				local decision = CodeService.evaluate(typed, FIXTURE, NOW, {})
				t.expect(decision.status).toBe("empty")
				t.expect(decision.message).toBe(messages.empty)
			end
		end)

		t.it("refuses anything longer than the longest possible code", function()
			local long = string.rep("A", Economy.codes.maxLength + 1)
			local fixture = table.clone(FIXTURE)
			fixture[long] = FIXTURE.CASHME
			t.expect(CodeService.evaluate(long, fixture, NOW, {}).status).toBe("unknown")
		end)

		t.it("refuses an expired code, including one that ends right now", function()
			local old = CodeService.evaluate("OLD", FIXTURE, NOW, {})
			t.expect(old.ok).toBe(false)
			t.expect(old.status).toBe("expired")
			t.expect(old.message).toBe(messages.expired)
			t.expect(CodeService.evaluate("EDGE", FIXTURE, NOW, {}).status).toBe("expired")
			t.expect(CodeService.evaluate("EDGE", FIXTURE, NOW - 1, {}).ok).toBe(true)
		end)

		t.it("refuses a code this player already redeemed", function()
			local decision = CodeService.evaluate("CASHME", FIXTURE, NOW, { CASHME = true })
			t.expect(decision.ok).toBe(false)
			t.expect(decision.status).toBe("redeemed")
			t.expect(decision.message).toBe(messages.redeemed)
		end)

		t.it("lets a player redeem a code they haven't used, whatever else they have", function()
			local decision = CodeService.evaluate("BOOST", FIXTURE, NOW, { CASHME = true })
			t.expect(decision.ok).toBe(true)
		end)

		t.it("checks expiry before one-per-player", function()
			t.expect(CodeService.evaluate("OLD", FIXTURE, NOW, { OLD = true }).status).toBe("expired")
		end)

		t.it("pays a cash code", function()
			local decision = CodeService.evaluate("CASHME", FIXTURE, NOW, {})
			t.expect(decision.ok).toBe(true)
			t.expect(decision.status).toBe("ok")
			t.expect(decision.key).toBe("CASHME")
			t.expect(decision.effect).toEqual({ kind = "cash", amount = 2500 })
			t.expect(decision.message).toBe(string.format(messages.cash, "$2,500"))
		end)

		t.it("grants a timed multiplier", function()
			local decision = CodeService.evaluate("BOOST", FIXTURE, NOW, {})
			t.expect(decision.ok).toBe(true)
			t.expect(decision.key).toBe("BOOST")
			t.expect(decision.effect).toEqual({ kind = "multiplier", factor = 2, minutes = 30 })
			t.expect(decision.message).toBe(string.format(messages.multiplier, "2x", `30 {messages.minutes}`))
		end)

		t.it("ignores case and surrounding spaces", function()
			for _, typed in { "cashme", "CashMe", "  cashme  ", "\tCASHME\n" } do
				local decision = CodeService.evaluate(typed, FIXTURE, NOW, {})
				t.expect(decision.ok).toBe(true)
				t.expect(decision.key).toBe("CASHME")
			end
			t.expect(CodeService.evaluate("  cashme ", FIXTURE, NOW, { CASHME = true }).status).toBe("redeemed")
		end)

		t.it("keeps spaces inside a code", function()
			t.expect(CodeService.evaluate("CASH ME", FIXTURE, NOW, {}).status).toBe("unknown")
		end)
	end)

	t.describe("CodeService helpers", function()
		t.it("normalizes to trimmed upper case and refuses over-long text", function()
			t.expect(CodeService.normalize("  abc ")).toBe("ABC")
			t.expect(CodeService.normalize(string.rep("a", Economy.codes.maxLength)))
				.toBe(string.rep("A", Economy.codes.maxLength))
			t.expect(CodeService.normalize(string.rep("a", Economy.codes.maxLength + 1))).toBe(nil)
		end)

		t.it("describes multipliers without trailing zeros and with the right plural", function()
			t.expect(CodeService.describe({ kind = "multiplier", factor = 1.5, minutes = 1 }))
				.toBe(string.format(messages.multiplier, "1.5x", `1 {messages.minute}`))
			t.expect(CodeService.describe({ kind = "multiplier", factor = 1.25, minutes = 90 }))
				.toBe(string.format(messages.multiplier, "1.25x", `90 {messages.minutes}`))
		end)

		t.it("turns a multiplier code into a boost that doubles earnings until it runs out", function()
			local decision = CodeService.evaluate("BOOST", FIXTURE, NOW, {})
			local effect = decision.effect
			assert(effect ~= nil and effect.kind == "multiplier", "BOOST is a multiplier code")
			local boosts: { Types.Boost } = {
				{ id = "BOOST", factor = effect.factor, endsAt = NOW + effect.minutes * SECONDS_PER_MINUTE },
			}
			t.expect(EconomyService.multiplierFrom(boosts, NOW)).toBe(2)
			t.expect(EconomyService.multiplierFrom(boosts, NOW + 29 * SECONDS_PER_MINUTE)).toBe(2)
			t.expect(EconomyService.multiplierFrom(boosts, NOW + 30 * SECONDS_PER_MINUTE)).toBe(1)
		end)
	end)

	t.describe("Config/Codes", function()
		t.it("stores every code trimmed, in upper case and short enough to type", function()
			for key in Codes do
				t.expect(CodeService.normalize(key)).toBe(key)
				t.expect(key ~= "").toBe(true)
			end
		end)

		t.it("gives every code a valid effect", function()
			for key, code in Codes do
				local effect = code.effect
				t.expect(type(code.expiresAtUtc) == "number").toBe(true)
				if effect.kind == "cash" then
					t.expect(`{key}: {EconomyService.wholeAmount(effect.amount) == effect.amount}`).toBe(`{key}: true`)
				else
					t.expect(effect.factor).toBeGreaterThan(1)
					t.expect(effect.factor <= Economy.boosts.maxMultiplier).toBe(true)
					t.expect(effect.minutes).toBeGreaterThan(0)
					t.expect(effect.minutes % 1).toBe(0)
				end
			end
		end)

		t.it("ships a live cash code and a live 2x half-hour boost that last for years", function()
			local now = os.time()
			local cash, doubler = 0, 0
			for key, code in Codes do
				local decision = CodeService.evaluate(key, Codes, now, {})
				if decision.ok and code.expiresAtUtc >= YEAR_2099 then
					local effect = code.effect
					if effect.kind == "cash" then
						cash += 1
					elseif effect.factor == 2 and effect.minutes == 30 then
						doubler += 1
					end
				end
			end
			t.expect(cash >= 1).toBe(true)
			t.expect(doubler >= 1).toBe(true)
		end)

		t.it("ships one code that has already expired", function()
			local now = os.time()
			local expired = 0
			for key in Codes do
				if CodeService.evaluate(string.lower(key), Codes, now, {}).status == "expired" then
					expired += 1
				end
			end
			t.expect(expired >= 1).toBe(true)
		end)
	end)
end
