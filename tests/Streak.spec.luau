--!strict
-- The daily login streak (Services/StreakService pure rules; PLAN.md Phase 12 "Login streak";
-- docs/phase-12-contracts.md "Live-ops"): streak days are UTC calendar days, one claim per day, the next day
-- continues the streak, a missed day starts it again at day 1, the reward cycle wraps and pays its occasional
-- credit, and a refused claim changes nothing. Also checks the shipped Config/Season.streak. Everything runs
-- under a fake clock on fresh template profiles: pure, runs in Edit mode.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Economy = require(ReplicatedStorage.Shared.Config.Economy)
local Harness = require(ReplicatedStorage.Shared.Testing.Harness)
local Season = require(ReplicatedStorage.Shared.Config.Season)
local Types = require(ReplicatedStorage.Shared.Types)
local Services = ServerScriptService.Server.Services
local StreakService = require(Services.StreakService)
local Template = require(Services.DataService.Template)

local DAY = 24 * 60 * 60
-- 2027-01-15 00:00:00 UTC, a midnight (1799971200 / 86400 is a whole number).
local MIDNIGHT = 1799971200
local LAST_SECOND = MIDNIGHT + DAY - 1 -- 23:59:59 UTC the same day

local config = Season.streak
local rewards = config.rewards

local function fresh(): Types.PlayerData
	return Template.new(MIDNIGHT)
end

return function(t: Harness.Api)
	t.describe("StreakService days", function()
		t.it("numbers days by UTC midnight, not by 24 hours since a claim", function()
			t.expect(MIDNIGHT % DAY).toBe(0)
			local today = StreakService.dayOf(MIDNIGHT)
			t.expect(StreakService.dayOf(LAST_SECOND)).toBe(today)
			t.expect(StreakService.dayOf(LAST_SECOND + 1)).toBe(today + 1)
			t.expect(StreakService.dayOf(MIDNIGHT - 1)).toBe(today - 1)
		end)

		t.it("a fresh profile can claim day 1 and says when the next day starts", function()
			local status = StreakService.evaluate(fresh().streak, MIDNIGHT + 5)
			t.expect(status.claimable).toBe(true)
			t.expect(status.day).toBe(1)
			t.expect(status.count).toBe(0)
			t.expect(status.nextAt).toBe(MIDNIGHT + DAY)
			t.expect(status.reward).toBe(rewards[1])
		end)
	end)

	t.describe("StreakService.claimIn", function()
		t.it("pays day 1 and saves the streak", function()
			local data = fresh()
			local cash = data.cash
			local outcome = StreakService.claimIn(data, MIDNIGHT + 60)
			t.expect(outcome.ok).toBe(true)
			t.expect(outcome.cash).toBe(rewards[1].cash)
			t.expect(data.cash).toBe(cash + rewards[1].cash)
			t.expect(data.streak).toEqual({ lastDay = StreakService.dayOf(MIDNIGHT), count = 1 })
			t.expect(outcome.message)
				.toBe(string.format(config.messages.reward, 1, Economy.formatCash(rewards[1].cash)))
		end)

		t.it("claims once per UTC day, up to the last second of it", function()
			local data = fresh()
			t.expect(StreakService.claimIn(data, MIDNIGHT).ok).toBe(true)
			local cash = data.cash
			local again = StreakService.claimIn(data, LAST_SECOND)
			t.expect(again.ok).toBe(false)
			t.expect(again.message).toBe(config.messages.claimed)
			t.expect(data.cash).toBe(cash)
			t.expect(data.streak.count).toBe(1)
			local status = StreakService.evaluate(data.streak, LAST_SECOND)
			t.expect(status.claimable).toBe(false)
			t.expect(status.count).toBe(1)
			t.expect(status.nextAt).toBe(LAST_SECOND + 1)
		end)

		t.it("continues the streak one second after UTC midnight, however soon after the last claim", function()
			local data = fresh()
			t.expect(StreakService.claimIn(data, LAST_SECOND).ok).toBe(true) -- 23:59:59
			local outcome = StreakService.claimIn(data, LAST_SECOND + 1) -- 00:00:00 the next day
			t.expect(outcome.ok).toBe(true)
			t.expect(data.streak.count).toBe(2)
			t.expect(outcome.cash).toBe(rewards[2].cash)
		end)

		t.it("continues the streak nearly 48 hours later when that is still the next UTC day", function()
			local data = fresh()
			t.expect(StreakService.claimIn(data, MIDNIGHT).ok).toBe(true) -- 00:00:00 day 1
			t.expect(StreakService.claimIn(data, LAST_SECOND + DAY).ok).toBe(true) -- 23:59:59 day 2
			t.expect(data.streak.count).toBe(2)
		end)

		t.it("starts again at day 1 after a missed day", function()
			local data = fresh()
			for day = 0, 2 do
				t.expect(StreakService.claimIn(data, MIDNIGHT + day * DAY + 10).ok).toBe(true)
			end
			t.expect(data.streak.count).toBe(3)
			-- Day 4 missed; day 5:
			local later = MIDNIGHT + 4 * DAY + 10
			local status = StreakService.evaluate(data.streak, later)
			t.expect(status.claimable).toBe(true)
			t.expect(status.day).toBe(1)
			t.expect(status.count).toBe(0)
			local outcome = StreakService.claimIn(data, later)
			t.expect(outcome.ok).toBe(true)
			t.expect(data.streak).toEqual({ lastDay = StreakService.dayOf(later), count = 1 })
			t.expect(outcome.cash).toBe(rewards[1].cash)
		end)

		t.it("pays the cycle in order, gives the occasional credit, then starts the cycle again", function()
			local data = fresh()
			local credits = data.credits.balance
			local creditsSeen = 0
			for day = 1, #rewards + 1 do
				local outcome = StreakService.claimIn(data, MIDNIGHT + (day - 1) * DAY)
				t.expect(outcome.ok).toBe(true)
				local reward = rewards[((day - 1) % #rewards) + 1]
				t.expect(outcome.cash).toBe(reward.cash)
				t.expect(outcome.credits).toBe(reward.credits or 0)
				creditsSeen += reward.credits or 0
			end
			t.expect(data.streak.count).toBe(#rewards + 1)
			t.expect(data.credits.balance).toBe(credits + creditsSeen)
			t.expect(creditsSeen).toBeGreaterThan(0)
			t.expect(StreakService.rewardFor(#rewards + 1)).toBe(rewards[1])
		end)

		t.it("refuses without changing anything when the wallet is full", function()
			local data = fresh()
			data.cash = Economy.maxCash
			local outcome = StreakService.claimIn(data, MIDNIGHT)
			t.expect(outcome.ok).toBe(false)
			t.expect(outcome.message).toBe(config.messages.full)
			t.expect(data.streak).toEqual({ lastDay = 0, count = 0 })
		end)

		t.it("repairs a damaged streak instead of failing", function()
			local data = fresh()
			data.streak = { lastDay = -5, count = 0 / 0 } :: any
			local outcome = StreakService.claimIn(data, MIDNIGHT)
			t.expect(outcome.ok).toBe(true)
			t.expect(data.streak.count).toBe(1)
		end)
	end)

	t.describe("Config/Season.streak", function()
		t.it("is a cycle of whole cash rewards with at least one credit and a UTC day", function()
			t.expect(config.daySeconds).toBe(DAY)
			t.expect(#rewards).toBeGreaterThan(0)
			local credits = 0
			for _, reward in rewards do
				t.expect(reward.cash >= 1 and reward.cash % 1 == 0).toBe(true)
				if reward.credits ~= nil then
					t.expect(reward.credits >= 1 and reward.credits % 1 == 0).toBe(true)
					credits += reward.credits
				end
			end
			t.expect(credits).toBeGreaterThan(0)
			t.expect(credits).toBeLessThan(#rewards) -- "an occasional credit", not one a day
		end)
	end)
end
