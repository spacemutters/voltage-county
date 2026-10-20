--!strict
-- The used lot's daily stock and prices (Config/UsedLot, Services/UsedLotService pure helpers;
-- docs/phase-4-contracts.md "Commerce"; PLAN.md Phase 4 acceptance "two simulated servers on the same UTC day
-- show identical used-lot stock"): the stock is the same for a date every time it's worked out, different days
-- differ, there is one car per numbered space, and the price rises as copies sell, never past its cap. Pure
-- logic: runs in Edit mode.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Catalog = require(ReplicatedStorage.Shared.Vehicle.Catalog)
local Harness = require(ReplicatedStorage.Shared.Testing.Harness)
local MapLayout = require(ReplicatedStorage.Shared.Config.MapLayout)
local UsedLot = require(ReplicatedStorage.Shared.Config.UsedLot)
local UsedLotService = require(ServerScriptService.Server.Services.UsedLotService)

local DAY = 86400
local FIXTURE_SLOTS = 10

-- Twelve made-up trims, so the fixture doesn't depend on the catalog.
local function fixturePool(): { UsedLot.PoolEntry }
	local pool: { UsedLot.PoolEntry } = {}
	for i = 1, 12 do
		table.insert(pool, { vehicleId = `classic_{i}`, trim = "used", basePrice = 10000 * i })
	end
	return pool
end

local function sameStock(a: { UsedLot.StockEntry }, b: { UsedLot.StockEntry }): boolean
	if #a ~= #b then
		return false
	end
	for i, entry in a do
		local other = b[i]
		if
			other.slot ~= entry.slot
			or other.vehicleId ~= entry.vehicleId
			or other.trim ~= entry.trim
			or other.basePrice ~= entry.basePrice
			or other.supply ~= entry.supply
		then
			return false
		end
	end
	return true
end

return function(t: Harness.Api)
	t.describe("UsedLot.stockFor", function()
		t.it("gives the same stock for the same date every time (two servers agree)", function()
			local pool = fixturePool()
			for _, date in { "2026-10-20", "2027-01-01", "2030-12-31" } do
				local first = UsedLot.stockFor(date, pool, FIXTURE_SLOTS)
				local second = UsedLot.stockFor(date, table.clone(pool), FIXTURE_SLOTS)
				t.expect(sameStock(first, second)).toBe(true)
			end
		end)

		t.it("changes from day to day", function()
			local pool = fixturePool()
			local start = 1792454400 -- 2026-10-20 00:00 UTC
			local differing = 0
			local previous = UsedLot.stockFor(UsedLot.dateKey(start), pool, FIXTURE_SLOTS)
			for day = 1, 6 do
				local stock = UsedLot.stockFor(UsedLot.dateKey(start + day * DAY), pool, FIXTURE_SLOTS)
				if not sameStock(stock, previous) then
					differing += 1
				end
				previous = stock
			end
			t.expect(differing >= 5).toBe(true)
		end)

		t.it("fills every space once from the pool, numbered in order", function()
			local pool = fixturePool()
			local stock = UsedLot.stockFor("2026-10-20", pool, FIXTURE_SLOTS)
			t.expect(#stock).toBe(FIXTURE_SLOTS)
			local seen: { [string]: boolean } = {}
			for i, entry in stock do
				t.expect(entry.slot).toBe(i)
				t.expect(entry.supply).toBe(UsedLot.supplyPerDay)
				t.expect(seen[entry.vehicleId]).toBe(nil) -- a 12-car pool fills 10 spaces without repeats
				seen[entry.vehicleId] = true
				local found = false
				for _, candidate in pool do
					if candidate.vehicleId == entry.vehicleId and candidate.basePrice == entry.basePrice then
						found = true
					end
				end
				t.expect(found).toBe(true)
			end
		end)

		t.it("repeats the pool when there are more spaces than cars, and is empty with no pool", function()
			local small = { { vehicleId = "only", trim = "used", basePrice = 5000 } }
			local stock = UsedLot.stockFor("2026-10-20", small, 3)
			t.expect(#stock).toBe(3)
			for _, entry in stock do
				t.expect(entry.vehicleId).toBe("only")
			end
			t.expect(#UsedLot.stockFor("2026-10-20", {}, 3)).toBe(0)
		end)

		t.it("has one space per used-lot pad, at least 8, all stocked from the catalog", function()
			t.expect(UsedLot.slots).toBe(#MapLayout.usedLot.pads)
			t.expect(UsedLot.slots >= 8).toBe(true)
			t.expect(#UsedLot.pool).toBeGreaterThan(0)
			for _, entry in UsedLot.pool do
				local trim = Catalog.getTrim(entry.vehicleId, entry.trim)
				t.expect(trim ~= nil).toBe(true)
				if trim then
					t.expect(trim.acquisition).toBe("usedLot")
					t.expect(trim.price).toBe(entry.basePrice)
				end
			end
			local today = UsedLot.stockFor(UsedLot.dateKey(os.time()))
			t.expect(#today).toBe(UsedLot.slots)
			t.expect(sameStock(today, UsedLotService.stockFor(UsedLot.dateKey(os.time())))).toBe(true)
		end)
	end)

	t.describe("UsedLot dates", function()
		t.it("keys a day by its UTC date", function()
			t.expect(UsedLot.dateKey(0)).toBe("1970-01-01")
			t.expect(UsedLot.dateKey(DAY - 1)).toBe("1970-01-01")
			t.expect(UsedLot.dateKey(DAY)).toBe("1970-01-02")
			t.expect(UsedLot.dateKey(1792454400)).toBe("2026-10-20")
			t.expect(string.match(UsedLot.dateKey(os.time()), "^%d%d%d%d%-%d%d%-%d%d$") ~= nil).toBe(true)
		end)

		t.it("counts down to the next UTC midnight", function()
			t.expect(UsedLot.secondsUntilNextDay(5 * DAY + 100)).toBe(DAY - 100)
			t.expect(UsedLot.secondsUntilNextDay(5 * DAY)).toBe(DAY)
		end)

		t.it("hashes the same text the same way, and different days differently", function()
			t.expect(UsedLot.hash("2026-10-20")).toBe(UsedLot.hash("2026-10-20"))
			t.expect(UsedLot.hash("2026-10-20") ~= UsedLot.hash("2026-10-21")).toBe(true)
			t.expect(UsedLot.supplyKey("2026-10-20", 3)).toBe("2026-10-20:3")
		end)
	end)

	t.describe("UsedLot.price", function()
		local base = 80000
		local supply = 5

		t.it("starts at the base price", function()
			t.expect(UsedLotService.price(base, 0, supply)).toBe(base)
		end)

		t.it("never falls as copies sell, and never goes past its cap", function()
			local cap = math.floor(base * UsedLot.priceCurve.maxMultiplier)
			local previous = 0
			for sold = 0, supply + 5 do
				local price = UsedLotService.price(base, sold, supply)
				t.expect(price >= previous).toBe(true)
				t.expect(price <= cap).toBe(true)
				t.expect(price >= base).toBe(true)
				t.expect(price % 1).toBe(0)
				previous = price
			end
			t.expect(UsedLotService.price(base, supply - 1, supply)).toBeGreaterThan(base)
			t.expect(UsedLotService.price(base, 1000, supply)).toBe(cap)
		end)

		t.it("follows base x (1 + rise x sold / supply)", function()
			local expected =
				math.floor(base * math.min(1 + UsedLot.priceCurve.rise * 2 / supply, UsedLot.priceCurve.maxMultiplier))
			t.expect(UsedLotService.price(base, 2, supply)).toBe(expected)
		end)

		t.it("prices a damaged base at 0 and a damaged count like a sold-out space", function()
			t.expect(UsedLotService.price(0, 0, supply)).toBe(0)
			t.expect(UsedLotService.price(-5, 0, supply)).toBe(0)
			t.expect(UsedLotService.price(0 / 0, 0, supply)).toBe(0)
			local cap = math.floor(base * UsedLot.priceCurve.maxMultiplier)
			t.expect(UsedLotService.price(base, 0 / 0, supply) <= cap).toBe(true)
			t.expect(UsedLotService.price(base, -3, supply)).toBe(base)
		end)

		t.it("reads stored counts safely", function()
			t.expect(UsedLotService.cleanCount(3)).toBe(3)
			t.expect(UsedLotService.cleanCount(2.7)).toBe(2)
			t.expect(UsedLotService.cleanCount(nil)).toBe(0)
			t.expect(UsedLotService.cleanCount(-1)).toBe(0)
			t.expect(UsedLotService.cleanCount("4")).toBe(0)
		end)
	end)
end
