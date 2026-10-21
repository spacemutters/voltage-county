--!strict
-- Scheduled events (Services/EventService pure rules; PLAN.md Phase 12 acceptance "An event activates at its
-- scheduled time under a fake clock"; docs/phase-12-contracts.md "Live-ops"): an event switches on exactly at its
-- start and off exactly at its end as a fake clock steps across them, the timer's next wake-up is the next start or
-- end, multipliers and bonus credits stack as configured (add, multiply, max, each capped), the payload and its
-- countdowns, live DataStore events validated and merged, the event multiplier joining EconomyService's boost path,
-- and the shipped Config/Events. Pure: runs in Edit mode.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Economy = require(ReplicatedStorage.Shared.Config.Economy)
local Events = require(ReplicatedStorage.Shared.Config.Events)
local Harness = require(ReplicatedStorage.Shared.Testing.Harness)
local Types = require(ReplicatedStorage.Shared.Types)
local Catalog = require(ReplicatedStorage.Shared.Vehicle.Catalog)
local Services = ServerScriptService.Server.Services
local EconomyService = require(Services.EconomyService)
local EventService = require(Services.EventService)

type Event = EventService.Event

local T = 1800000000 -- a fixed "now" (os.time() seconds)
local HOUR = 3600

local A: Event = { id = "a", name = "A", startsAtUtc = T, endsAtUtc = T + 100, earningsMultiplier = 1.5 }
local B: Event = {
	id = "b",
	name = "B",
	startsAtUtc = T + 50,
	endsAtUtc = T + 200,
	earningsMultiplier = 1.2,
	featuredVehicleId = "ohm_arc",
}
local C: Event = { id = "c", name = "C", startsAtUtc = T + 300, endsAtUtc = T + 400, bonusCredits = 0.5 }
local D: Event = { id = "d", name = "D", startsAtUtc = T + 350, endsAtUtc = T + 450, bonusCredits = 0.25 }
local SCHEDULE: { Event } = { D, C, B, A } -- out of order on purpose

-- A fake clock: the time it reads is whatever the test set last.
local function fakeClock(start: number): { now: number, read: () -> number }
	local clock = { now = start, read = (nil :: any) :: () -> number }
	clock.read = function(): number
		return clock.now
	end
	return clock
end

local function ids(list: { Event }): { string }
	local result: { string } = {}
	for _, event in list do
		table.insert(result, event.id)
	end
	return result
end

return function(t: Harness.Api)
	t.describe("EventService schedule under a fake clock", function()
		t.it("switches an event on exactly at its start and off exactly at its end", function()
			local clock = fakeClock(T - 3)
			local seen: { [number]: boolean } = {}
			while clock.now <= T + 103 do
				local running = #EventService.activeAt({ A }, clock.read()) == 1
				seen[clock.now] = running
				clock.now += 1
			end
			t.expect(seen[T - 1]).toBe(false)
			t.expect(seen[T]).toBe(true)
			t.expect(seen[T + 99]).toBe(true)
			t.expect(seen[T + 100]).toBe(false)
		end)

		t.it("lists the running events soonest-started first", function()
			t.expect(ids(EventService.activeAt(SCHEDULE, T + 60))).toEqual({ "a", "b" })
			t.expect(ids(EventService.activeAt(SCHEDULE, T + 360))).toEqual({ "c", "d" })
			t.expect(ids(EventService.activeAt(SCHEDULE, T + 250))).toEqual({})
		end)

		t.it("wakes the timer at the next start or end", function()
			t.expect(EventService.nextChangeAt(SCHEDULE, T - 10)).toBe(T)
			t.expect(EventService.nextChangeAt(SCHEDULE, T)).toBe(T + 50)
			t.expect(EventService.nextChangeAt(SCHEDULE, T + 60)).toBe(T + 100)
			t.expect(EventService.nextChangeAt(SCHEDULE, T + 200)).toBe(T + 300)
			t.expect(EventService.nextChangeAt(SCHEDULE, T + 450)).toBe(nil)
		end)

		t.it("follows the clock with nothing restarted: each wake-up finds the change it woke for", function()
			local clock = fakeClock(T - HOUR)
			local timeline: { string } = {}
			local nextAt = EventService.nextChangeAt(SCHEDULE, clock.read())
			while nextAt ~= nil do
				clock.now = nextAt
				table.insert(
					timeline,
					`{nextAt - T}:{table.concat(ids(EventService.activeAt(SCHEDULE, clock.read())), "+")}`
				)
				nextAt = EventService.nextChangeAt(SCHEDULE, clock.read())
			end
			t.expect(timeline).toEqual({ "0:a", "50:a+b", "100:b", "200:", "300:c", "350:c+d", "400:d", "450:" })
		end)

		t.it("counts down to events starting within the window, soonest first, at most `max`", function()
			t.expect(ids(EventService.upcomingAt(SCHEDULE, T - 10, 1000, 3))).toEqual({ "a", "b", "c" })
			t.expect(ids(EventService.upcomingAt(SCHEDULE, T - 10, 100, 3))).toEqual({ "a", "b" })
			t.expect(ids(EventService.upcomingAt(SCHEDULE, T, 1000, 3))).toEqual({ "b", "c", "d" })
		end)
	end)

	t.describe("EventService stacking", function()
		t.it("stacks earnings multipliers as configured", function()
			local at = T + 60 -- A (1.5x) and B (1.2x)
			t.expect(EventService.earningsMultiplierAt(SCHEDULE, at, "add", 10)).toBeNear(1.7, 1e-9)
			t.expect(EventService.earningsMultiplierAt(SCHEDULE, at, "multiply", 10)).toBeNear(1.8, 1e-9)
			t.expect(EventService.earningsMultiplierAt(SCHEDULE, at, "max", 10)).toBeNear(1.5, 1e-9)
			t.expect(EventService.earningsMultiplierAt(SCHEDULE, at, "add", 1.6)).toBeNear(1.6, 1e-9)
			t.expect(EventService.earningsMultiplierAt(SCHEDULE, T + 250, "add", 10)).toBe(1)
		end)

		t.it("stacks bonus credits as configured", function()
			local at = T + 360 -- C (+50%) and D (+25%)
			t.expect(EventService.bonusCreditsAt(SCHEDULE, at, "add", 10)).toBeNear(0.75, 1e-9)
			t.expect(EventService.bonusCreditsAt(SCHEDULE, at, "multiply", 10)).toBeNear(0.875, 1e-9)
			t.expect(EventService.bonusCreditsAt(SCHEDULE, at, "max", 10)).toBeNear(0.5, 1e-9)
			t.expect(EventService.bonusCreditsAt(SCHEDULE, at, "add", 0.6)).toBeNear(0.6, 1e-9)
			t.expect(EventService.bonusCreditsAt(SCHEDULE, T + 60, "add", 10)).toBe(0)
		end)

		t.it("uses Config/Events' own stacking and caps by default", function()
			local at = T + 60
			local expected =
				EventService.combineMultipliers({ 1.5, 1.2 }, Events.stacking.earnings, Events.maxEarningsMultiplier)
			t.expect(EventService.earningsMultiplierAt(SCHEDULE, at)).toBeNear(expected, 1e-9)
			t.expect(EventService.earningsMultiplierAt(SCHEDULE, at) <= Events.maxEarningsMultiplier).toBe(true)
			local share = EventService.combineShares({ 0.5, 0.25 }, Events.stacking.credits, Events.maxBonusCredits)
			t.expect(EventService.bonusCreditsAt(SCHEDULE, T + 360)).toBeNear(share, 1e-9)
		end)

		t.it("joins EconomyService's boost path as one more boost, under the same cap", function()
			local boost: Types.Boost = { id = "x", factor = 2, endsAt = T + HOUR }
			t.expect(EconomyService.multiplierFrom({}, T, 1.5)).toBeNear(1.5, 1e-9)
			t.expect(EconomyService.multiplierFrom({ boost }, T, 1.5)).toBeNear(2.5, 1e-9)
			t.expect(EconomyService.multiplierFrom({ boost }, T, 1)).toBe(2)
			t.expect(EconomyService.multiplierFrom({ boost }, T, nil)).toBe(2)
			t.expect(EconomyService.multiplierFrom({ boost, boost }, T, 2)).toBe(Economy.boosts.maxMultiplier)
		end)
	end)

	t.describe("EventService payload and live events", function()
		t.it("sends the running and upcoming events with their times, and nothing while switched off", function()
			local payload = EventService.payloadAt(SCHEDULE, T + 60, true)
			t.expect(payload.now).toBe(T + 60)
			t.expect(#payload.active).toBe(2)
			t.expect(payload.active[2].featuredVehicleId).toBe("ohm_arc")
			t.expect(payload.active[1].startsAt).toBe(T)
			t.expect(payload.active[1].endsAt).toBe(T + 100)
			local later = EventService.payloadAt(SCHEDULE, T + 250, true)
			t.expect(later.upcoming[1].id).toBe("c")
			t.expect(later.upcoming[1].bonusPercent).toBe(50)
			local off = EventService.payloadAt(SCHEDULE, T + 60, false)
			t.expect(#off.active).toBe(0)
			t.expect(#off.upcoming).toBe(0)
		end)

		t.it("validates live events and refuses bad ones", function()
			local good, problem = EventService.validate({
				id = "live_1",
				name = "Live",
				startsAtUtc = T,
				endsAtUtc = T + 10,
				earningsMultiplier = 2,
				featuredVehicleId = "ohm_arc",
				extra = "dropped",
			})
			t.expect(problem).toBe(nil)
			t.expect(good ~= nil and (good :: any).extra == nil).toBe(true)
			local bad: { any } = {
				{ id = "bad id", name = "x", startsAtUtc = T, endsAtUtc = T + 1 },
				{ id = "x", name = "", startsAtUtc = T, endsAtUtc = T + 1 },
				{ id = "x", name = "x", startsAtUtc = T, endsAtUtc = T },
				{ id = "x", name = "x", startsAtUtc = T, endsAtUtc = T + 1, earningsMultiplier = 0.5 },
				{ id = "x", name = "x", startsAtUtc = T, endsAtUtc = T + 1, bonusCredits = -1 },
				{ id = "x", name = "x", startsAtUtc = T, endsAtUtc = T + 1, featuredVehicleId = "no_such_car" },
				{ id = "x", name = "x", startsAtUtc = 0 / 0, endsAtUtc = T + 1 },
				"not a table",
			}
			for _, raw in bad do
				t.expect((EventService.validate(raw))).toBe(nil)
			end
		end)

		t.it("lets a live event replace the config event with the same id", function()
			local moved: Event = { id = "a", name = "A moved", startsAtUtc = T + 1000, endsAtUtc = T + 2000 }
			local merged = EventService.merge({ A, B }, { moved })
			t.expect(#merged).toBe(2)
			t.expect(ids(EventService.activeAt(merged, T + 10))).toEqual({})
			t.expect(ids(EventService.activeAt(merged, T + 1500))).toEqual({ "a" })
		end)
	end)

	t.describe("Config/Events", function()
		t.it("ships valid events with unique ids, real featured cars and sane caps", function()
			local seen: { [string]: boolean } = {}
			for _, event in Events.schedule do
				local clean, problem = EventService.validate(event)
				t.expect(problem).toBe(nil)
				t.expect(clean ~= nil).toBe(true)
				t.expect(seen[event.id]).toBe(nil)
				seen[event.id] = true
				if event.featuredVehicleId ~= nil then
					t.expect(Catalog.getVehicle(event.featuredVehicleId) ~= nil).toBe(true)
				end
			end
			t.expect(Events.maxEarningsMultiplier >= 1).toBe(true)
			t.expect(Events.maxEarningsMultiplier <= Economy.boosts.maxMultiplier).toBe(true)
			t.expect(Events.maxBonusCredits >= 0).toBe(true)
			t.expect(Events.live.refreshSeconds >= 60).toBe(true) -- a slow timer, not a poll
		end)
	end)
end
