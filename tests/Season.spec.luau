--!strict
-- Season Pass v1 (Services/SeasonService pure rules; PLAN.md Phase 12 "Season Pass v1"; docs/phase-12-contracts.md
-- "Live-ops"): season XP from driving and jobs only and only while the season runs, XP to tiers, each reward
-- claimed once per track, the premium track only with the pass, the claim grace after the end, a new season
-- starting again at 0, and the shipped Config/Season (30 tiers, 6-8 weeks, both tracks). Fake clock, template
-- profiles: pure, runs in Edit mode.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Economy = require(ReplicatedStorage.Shared.Config.Economy)
local Harness = require(ReplicatedStorage.Shared.Testing.Harness)
local Limiteds = require(ReplicatedStorage.Shared.Config.Limiteds)
local Monetization = require(ReplicatedStorage.Shared.Config.Monetization)
local Season = require(ReplicatedStorage.Shared.Config.Season)
local Types = require(ReplicatedStorage.Shared.Types)
local Services = ServerScriptService.Server.Services
local SeasonService = require(Services.SeasonService)
local Template = require(Services.DataService.Template)

local DAY = 24 * 60 * 60
local WEEK = 7 * DAY
local START = 1800036000
local messages = Season.messages

-- A small season: tier 1 at 100 XP, tier 2 at 300, tier 3 at 600.
local FIXTURE: SeasonService.SeasonConfig = table.clone(Season)
FIXTURE.id = "test"
FIXTURE.startsAtUtc = START
FIXTURE.endsAtUtc = START + 6 * WEEK
FIXTURE.claimGraceSeconds = DAY
FIXTURE.tiers = {
	{ xp = 100, free = { kind = "cash", amount = 1000 }, premium = { kind = "cash", amount = 3000 } },
	{ xp = 300, free = { kind = "credits", amount = 1 }, premium = { kind = "credits", amount = 2 } },
	{ xp = 600, free = nil, premium = { kind = "wrap", ref = "test_wrap" } },
}

local DURING = START + DAY

local function fresh(xp: number?): Types.PlayerData
	local data = Template.new(START)
	data.season = { id = FIXTURE.id, xp = xp or 0, premium = false, claimed = {} }
	return data
end

return function(t: Harness.Api)
	t.describe("Season XP", function()
		t.it("comes from driving payouts and jobs, never from anything else", function()
			t.expect(SeasonService.xpFor(Season, "drive")).toBeGreaterThan(0)
			t.expect(SeasonService.xpFor(Season, "job:rideshare")).toBeGreaterThan(0)
			t.expect(SeasonService.xpFor(Season, "job:freight")).toBe(SeasonService.xpFor(Season, "job:rideshare"))
			for _, reason in { "code", "refund", "dev", "fleet", "sell", "streak", "season", "limited", "" } do
				t.expect(SeasonService.xpFor(Season, reason)).toBe(0)
			end
		end)

		t.it("is added only while the season runs (start inclusive, end exclusive)", function()
			local state = SeasonService.clean(nil, FIXTURE)
			t.expect(SeasonService.addXp(state, FIXTURE, 50, START - 1)).toBe(0)
			t.expect(SeasonService.addXp(state, FIXTURE, 50, START)).toBe(50)
			t.expect(SeasonService.addXp(state, FIXTURE, 50, FIXTURE.endsAtUtc - 1)).toBe(50)
			t.expect(SeasonService.addXp(state, FIXTURE, 50, FIXTURE.endsAtUtc)).toBe(0)
			t.expect(state.xp).toBe(100)
		end)

		t.it("ignores amounts that aren't whole and positive", function()
			local state = SeasonService.clean(nil, FIXTURE)
			for _, amount in { 0, -5, 1.5, 0 / 0, math.huge } do
				t.expect(SeasonService.addXp(state, FIXTURE, amount, DURING)).toBe(0)
			end
			t.expect(state.xp).toBe(0)
		end)

		t.it("turns XP into tiers at each tier's total", function()
			t.expect(SeasonService.tierFor(FIXTURE, 0)).toBe(0)
			t.expect(SeasonService.tierFor(FIXTURE, 99)).toBe(0)
			t.expect(SeasonService.tierFor(FIXTURE, 100)).toBe(1)
			t.expect(SeasonService.tierFor(FIXTURE, 299)).toBe(1)
			t.expect(SeasonService.tierFor(FIXTURE, 300)).toBe(2)
			t.expect(SeasonService.tierFor(FIXTURE, 600)).toBe(3)
			t.expect(SeasonService.tierFor(FIXTURE, 1000000)).toBe(3)
		end)

		t.it("starts a new season at 0 with nothing claimed, and repairs a damaged state", function()
			local old = { id = "old", xp = 5000, premium = true, claimed = { ["free:1"] = true } }
			t.expect(SeasonService.clean(old, FIXTURE)).toEqual({ id = "test", xp = 0, premium = false, claimed = {} })
			local damaged = { id = "test", xp = -3, premium = "yes", claimed = { ["free:1"] = true, [5] = true } }
			t.expect(SeasonService.clean(damaged, FIXTURE))
				.toEqual({ id = "test", xp = 0, premium = false, claimed = { ["free:1"] = true } })
		end)
	end)

	t.describe("Season claims", function()
		t.it("pays a reached free reward once", function()
			local data = fresh(100)
			local cash = data.cash
			local first = SeasonService.claimIn(data, FIXTURE, 1, "free", false, DURING)
			t.expect(first.ok).toBe(true)
			t.expect(first.cash).toBe(1000)
			t.expect(data.cash).toBe(cash + 1000)
			t.expect(first.message).toBe(string.format(messages.cash, Economy.formatCash(1000)))
			local again = SeasonService.claimIn(data, FIXTURE, 1, "free", false, DURING)
			t.expect(again.ok).toBe(false)
			t.expect(again.message).toBe(messages.claimed)
			t.expect(data.cash).toBe(cash + 1000)
		end)

		t.it("keeps the free and premium tracks apart: each claims once", function()
			local data = fresh(100)
			t.expect(SeasonService.claimIn(data, FIXTURE, 1, "free", true, DURING).ok).toBe(true)
			local premium = SeasonService.claimIn(data, FIXTURE, 1, "premium", true, DURING)
			t.expect(premium.ok).toBe(true)
			t.expect(premium.cash).toBe(3000)
			t.expect(SeasonService.claimIn(data, FIXTURE, 1, "premium", true, DURING).message).toBe(messages.claimed)
			t.expect(data.season.claimed).toEqual({ ["free:1"] = true, ["premium:1"] = true })
		end)

		t.it("refuses the premium track without the pass, and allows it once the pass is there", function()
			local data = fresh(100)
			local cash = data.cash
			local refused = SeasonService.claimIn(data, FIXTURE, 1, "premium", false, DURING)
			t.expect(refused.ok).toBe(false)
			t.expect(refused.message).toBe(messages.premium)
			t.expect(data.cash).toBe(cash)
			t.expect(data.season.claimed).toEqual({})
			t.expect(SeasonService.claimIn(data, FIXTURE, 1, "premium", true, DURING).ok).toBe(true)
		end)

		t.it("refuses a tier not reached yet, and one that doesn't exist", function()
			local data = fresh(299)
			local locked = SeasonService.claimIn(data, FIXTURE, 2, "free", false, DURING)
			t.expect(locked.ok).toBe(false)
			t.expect(locked.message).toBe(string.format(messages.locked, 2))
			t.expect(SeasonService.claimIn(data, FIXTURE, 4, "free", false, DURING).message).toBe(messages.unknownTier)
		end)

		t.it("grants credits through the credits ledger", function()
			local data = fresh(300)
			local balance = data.credits.balance
			t.expect(SeasonService.claimIn(data, FIXTURE, 2, "free", false, DURING).ok).toBe(true)
			t.expect(SeasonService.claimIn(data, FIXTURE, 2, "premium", true, DURING).ok).toBe(true)
			t.expect(data.credits.balance).toBe(balance + 3)
		end)

		t.it("saves a look reward as an owned cosmetic, and an empty track has nothing to claim", function()
			local data = fresh(600)
			t.expect(SeasonService.claimIn(data, FIXTURE, 3, "free", true, DURING).message).toBe(messages.noReward)
			local look = SeasonService.claimIn(data, FIXTURE, 3, "premium", true, DURING)
			t.expect(look.ok).toBe(true)
			t.expect(data.cosmetics.test_wrap).toBe(0)
		end)

		t.it("allows claims through the grace after the end, then refuses", function()
			local after = FIXTURE.endsAtUtc + FIXTURE.claimGraceSeconds - 1
			t.expect(SeasonService.claimIn(fresh(100), FIXTURE, 1, "free", false, after).ok).toBe(true)
			local late = SeasonService.claimIn(fresh(100), FIXTURE, 1, "free", false, after + 1)
			t.expect(late.ok).toBe(false)
			t.expect(late.message).toBe(messages.ended)
			local early = SeasonService.claimIn(fresh(100), FIXTURE, 1, "free", false, START - 1)
			t.expect(early.message).toBe(messages.none)
		end)

		t.it("refuses a cash reward when the wallet is full, changing nothing", function()
			local data = fresh(100)
			data.cash = Economy.maxCash
			local outcome = SeasonService.claimIn(data, FIXTURE, 1, "free", false, DURING)
			t.expect(outcome.ok).toBe(false)
			t.expect(outcome.message).toBe(messages.full)
			t.expect(data.season.claimed).toEqual({})
		end)

		t.it("claims on another season's save start that season again first", function()
			local data = fresh(100)
			data.season = { id = "old", xp = 999999, premium = true, claimed = {} }
			t.expect(SeasonService.claimIn(data, FIXTURE, 1, "free", false, DURING).message)
				.toBe(string.format(messages.locked, 1))
		end)
	end)

	t.describe("Config/Season", function()
		t.it("runs 6-8 weeks with 30 tiers, both tracks, and climbing XP", function()
			local length = Season.endsAtUtc - Season.startsAtUtc
			t.expect(length >= 6 * WEEK and length <= 8 * WEEK).toBe(true)
			t.expect(#Season.tiers).toBe(30)
			local last = 0
			for _, tier in Season.tiers do
				t.expect(tier.xp).toBeGreaterThan(last)
				last = tier.xp
				t.expect(tier.free ~= nil).toBe(true)
				t.expect(tier.premium ~= nil).toBe(true)
				for _, reward in { tier.free, tier.premium } do
					local r = reward :: Season.Reward
					if r.kind == "cash" or r.kind == "credits" then
						local amount = r.amount or 0
						t.expect(amount >= 1 and amount % 1 == 0).toBe(true)
					else
						t.expect(type(r.ref) == "string" and r.ref ~= "").toBe(true)
					end
				end
			end
		end)

		t.it("sells the premium track with the season pass key", function()
			t.expect(Season.passKey).toBe("seasonPass")
			t.expect(Monetization.passes[Season.passKey] ~= nil).toBe(true)
		end)

		t.it("starts in the future and with the Arc Flight drop", function()
			local phaseTwelveDay = 1792454400 -- 2026-10-20 00:00 UTC, when this season was written
			t.expect(Season.startsAtUtc).toBeGreaterThan(phaseTwelveDay)
			t.expect(Season.startsAtUtc).toBe(Limiteds.drops.arc_flight_1.startsAtUtc)
		end)
	end)
end
