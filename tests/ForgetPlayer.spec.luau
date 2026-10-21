--!strict
-- Dev/ForgetPlayer (docs/LAUNCH.md step 7; docs/COMPLIANCE.md section 8): the weekly board keys it walks, the
-- serial ledger's rename (the number stays taken, the UserId goes), the design service's hash and SQL (the same
-- hash DesignerService sends), and the whole flow against mock stores: a look changes nothing, an apply removes
-- and renames, a second apply finds nothing, other players are untouched, and the live stores are the default.
-- Pure: mock stores, no DataStores. Runs in Edit mode.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Data = require(ReplicatedStorage.Shared.Config.Data)
local Designer = require(ReplicatedStorage.Shared.Config.Designer)
local DragStrip = require(ReplicatedStorage.Shared.Config.DragStrip)
local Harness = require(ReplicatedStorage.Shared.Testing.Harness)
local Limiteds = require(ReplicatedStorage.Shared.Config.Limiteds)
local Sha256 = require(ReplicatedStorage.Shared.Util.Sha256)
local DesignerService = require(ServerScriptService.Server.Services.DesignerService)
local ForgetPlayer = require(ServerScriptService.Server.Dev.ForgetPlayer)
local LimitedService = require(ServerScriptService.Server.Services.LimitedService)

local WEEK = 7 * 86400
local USER = 123456789
local OTHER = 987654321
local SALT = "11111111-2222-3333-4444-555555555555"

type Rows = { [string]: any }

-- A mock DataStore: GetAsync, RemoveAsync (returns the old value) and UpdateAsync (nil from the transform writes
-- nothing), on a plain table.
local function mockStore(rows: Rows): ForgetPlayer.Store
	return {
		GetAsync = function(_self: any, key: string): any
			return rows[key]
		end,
		RemoveAsync = function(_self: any, key: string): any
			local old = rows[key]
			rows[key] = nil
			return old
		end,
		UpdateAsync = function(_self: any, key: string, transform: (old: any) -> any): any
			local new = transform(rows[key])
			if new ~= nil then
				rows[key] = new
			end
			return new
		end,
	}
end

type World = { ordered: { [string]: Rows }, standard: { [string]: Rows }, deps: ForgetPlayer.Deps }

local function world(now: number): World
	local ordered: { [string]: Rows } = {}
	local standard: { [string]: Rows } = {}
	local function rowsOf(stores: { [string]: Rows }, name: string): Rows
		local rows = stores[name]
		if rows == nil then
			rows = {}
			stores[name] = rows
		end
		return rows
	end
	return {
		ordered = ordered,
		standard = standard,
		deps = {
			ordered = function(name: string): ForgetPlayer.Store
				return mockStore(rowsOf(ordered, name))
			end,
			standard = function(name: string): ForgetPlayer.Store
				return mockStore(rowsOf(standard, name))
			end,
			now = function(): number
				return now
			end,
		},
	}
end

-- A world where USER and OTHER both have drag strip times, serials and saves (live store names).
local function populated(now: number): (World, string, string)
	local w = world(now)
	local first = DragStrip.weekKey(ForgetPlayer.SETTINGS.firstBoardUtc)
	local last = DragStrip.weekKey(now)
	w.ordered[DragStrip.storePrefix .. first] = { [tostring(USER)] = 9800, [tostring(OTHER)] = 9900 }
	w.ordered[DragStrip.storePrefix .. last] = { [tostring(USER)] = 9700 }
	local dropId = next(Limiteds.drops) :: string
	local serialKey = Limiteds.keyPrefix .. dropId
	w.standard[Limiteds.store] = {
		[serialKey] = { sold = 2, owners = { [tostring(OTHER)] = 1, [tostring(USER)] = 2 } },
	}
	w.standard[Designer.salt.store] = { [Designer.salt.key] = SALT }
	w.standard[Data.storeName] = { [Data.profileKeyPrefix .. tostring(USER)] = { cash = 5 } }
	return w, first, serialKey
end

return function(t: Harness.Api)
	t.describe("ForgetPlayer: weekly boards", function()
		t.it("walks every week from the first to now, once each, oldest first", function()
			local from = ForgetPlayer.SETTINGS.firstBoardUtc
			local keys = ForgetPlayer.weekKeys(from, from + 3 * WEEK + 3600)
			t.expect(#keys).toBe(4)
			t.expect(keys[1]).toBe(DragStrip.weekKey(from))
			t.expect(keys[4]).toBe(DragStrip.weekKey(from + 3 * WEEK + 3600))
			local seen: { [string]: boolean } = {}
			for _, key in keys do
				t.expect(seen[key]).toBe(nil)
				seen[key] = true
			end
		end)

		t.it("covers a year boundary and the week of `to` even mid-week", function()
			local from = 1798416000 -- 2026-12-28, a Monday (ISO 2026-W53)
			local keys = ForgetPlayer.weekKeys(from, from + 2 * WEEK + 2 * 86400) -- to: Wednesday 2027-01-13
			t.expect(keys).toEqual({ "2026-W53", "2027-W01", "2027-W02" })
			-- From a Sunday to the Monday 8 days on: the week-long steps land on Sundays, so `to`'s week is added.
			local sunday = 1798329600 -- 2026-12-27 (ISO 2026-W52)
			t.expect(ForgetPlayer.weekKeys(sunday, sunday + 8 * 86400)).toEqual({ "2026-W52", "2026-W53", "2027-W01" })
		end)

		t.it("starts no later than the drag strip shipped", function()
			t.expect(DragStrip.weekKey(ForgetPlayer.SETTINGS.firstBoardUtc)).toBe("2026-W43")
			t.expect(#ForgetPlayer.weekKeys(10, 5)).toBe(0)
		end)
	end)

	t.describe("ForgetPlayer: serial ledger", function()
		t.it("renames the player's entry and keeps the serial taken", function()
			local raw = { sold = 3, owners = { ["1"] = 1, [tostring(USER)] = 2, ["3"] = 3 } }
			local record, serial = ForgetPlayer.forgetOwner(raw, tostring(USER))
			t.expect(serial).toBe(2)
			local written = record :: any
			t.expect(written.sold).toBe(3)
			t.expect(written.owners[tostring(USER)]).toBe(nil)
			t.expect(written.owners[ForgetPlayer.placeholder(2)]).toBe(2)
			t.expect(written.owners["1"]).toBe(1)
			t.expect(written.owners["3"]).toBe(3)
		end)

		t.it("writes nothing when the player isn't in it (or it's empty)", function()
			local record, serial = ForgetPlayer.forgetOwner({ sold = 1, owners = { ["1"] = 1 } }, tostring(USER))
			t.expect(record).toBe(nil)
			t.expect(serial).toBe(nil)
			local none, noSerial = ForgetPlayer.forgetOwner(nil, tostring(USER))
			t.expect(none).toBe(nil)
			t.expect(noSerial).toBe(nil)
		end)

		t.it("finds a UserId the store gave back as a number key", function()
			local record, serial = ForgetPlayer.forgetOwner({ sold = 1, owners = { [USER] = 1 } }, tostring(USER))
			t.expect(serial).toBe(1)
			t.expect((record :: any).owners[ForgetPlayer.placeholder(1)]).toBe(1)
		end)

		t.it("a renamed entry never names a player and keeps its serial for the next claim", function()
			local record = ForgetPlayer.forgetOwner({ sold = 2, owners = { [tostring(USER)] = 2 } }, tostring(USER))
			local placeholder = ForgetPlayer.placeholder(2)
			t.expect(tonumber(placeholder)).toBe(nil)
			t.expect(string.find(placeholder, tostring(USER), 1, true)).toBe(nil)
			-- LimitedService still counts it: the next buyer gets serial 3.
			local _, claim = LimitedService.claimTransform(record, "42", nil)
			t.expect(claim.serial).toBe(3)
		end)
	end)

	t.describe("ForgetPlayer: design service rows", function()
		t.it("uses the same hash the game sends", function()
			t.expect(DesignerService.hashFor(SALT, USER)).toBe(Sha256.hex(SALT .. tostring(USER)))
		end)

		t.it("builds the delete only from a 64-character hex hash", function()
			local hash = DesignerService.hashFor(SALT, USER)
			t.expect(ForgetPlayer.usageSql(hash))
				.toBe(`delete from public.vc_designer_usage where user_hash = '{hash}';`)
			t.expect(ForgetPlayer.usageSql("abc")).toBe(nil)
			t.expect(ForgetPlayer.usageSql(string.rep("z", 64))).toBe(nil)
			t.expect(ForgetPlayer.usageSql(string.rep("a", 63) .. "'")).toBe(nil)
		end)
	end)

	t.describe("ForgetPlayer: the whole flow (mock stores)", function()
		local now = ForgetPlayer.SETTINGS.firstBoardUtc + 10 * WEEK

		t.it("a look reports everything and changes nothing", function()
			local w, first, serialKey = populated(now)
			local report = ForgetPlayer.forget(USER, { save = true }, w.deps)
			t.expect(report.ok).toBe(true)
			t.expect(report.applied).toBe(false)
			t.expect(report.weeks).toEqual({ first, DragStrip.weekKey(now) })
			t.expect(report.serials).toEqual({ `{serialKey} #2` })
			t.expect(report.save).toEqual({ `{Data.storeName} {Data.profileKeyPrefix}{USER}` })
			t.expect(report.userHash).toBe(DesignerService.hashFor(SALT, USER))
			t.expect(w.ordered[DragStrip.storePrefix .. first][tostring(USER)]).toBe(9800)
			t.expect(w.standard[Limiteds.store][serialKey].owners[tostring(USER)]).toBe(2)
			t.expect(w.standard[Data.storeName][Data.profileKeyPrefix .. tostring(USER)]).never.toBe(nil)
		end)

		t.it("an apply removes the times, renames the serial and leaves other players alone", function()
			local w, first, serialKey = populated(now)
			local report = ForgetPlayer.forget(USER, { apply = true }, w.deps)
			t.expect(report.ok).toBe(true)
			t.expect(report.applied).toBe(true)
			t.expect(#report.weeks).toBe(2)
			t.expect(w.ordered[DragStrip.storePrefix .. first][tostring(USER)]).toBe(nil)
			t.expect(w.ordered[DragStrip.storePrefix .. first][tostring(OTHER)]).toBe(9900)
			local ledger = w.standard[Limiteds.store][serialKey]
			t.expect(ledger.sold).toBe(2)
			t.expect(ledger.owners[tostring(USER)]).toBe(nil)
			t.expect(ledger.owners[ForgetPlayer.placeholder(2)]).toBe(2)
			t.expect(ledger.owners[tostring(OTHER)]).toBe(1)
			t.expect(report.sql).toBe(ForgetPlayer.usageSql(DesignerService.hashFor(SALT, USER)))
			-- Without { save = true } the save stays (Roblox's deletion template removes it).
			t.expect(#report.save).toBe(0)
			t.expect(w.standard[Data.storeName][Data.profileKeyPrefix .. tostring(USER)]).never.toBe(nil)
		end)

		t.it("{ save = true } also removes the save", function()
			local w = populated(now)
			local report = ForgetPlayer.forget(USER, { apply = true, save = true }, w.deps)
			t.expect(#report.save).toBe(1)
			t.expect(w.standard[Data.storeName][Data.profileKeyPrefix .. tostring(USER)]).toBe(nil)
		end)

		t.it("a second apply finds nothing left", function()
			local w = populated(now)
			ForgetPlayer.forget(USER, { apply = true, save = true }, w.deps)
			local again = ForgetPlayer.forget(USER, { apply = true, save = true }, w.deps)
			t.expect(again.ok).toBe(true)
			t.expect(#again.weeks + #again.serials + #again.save).toBe(0)
		end)

		t.it("touches only the live stores by default, and only the Studio ones with { studio = true }", function()
			local w = populated(now)
			ForgetPlayer.forget(USER, { apply = true }, w.deps)
			for name in w.ordered do
				t.expect(string.sub(name, 1, #DragStrip.storePrefix)).toBe(DragStrip.storePrefix)
			end
			t.expect(w.standard[Limiteds.studioStore]).toBe(nil)
			local studio = world(now)
			ForgetPlayer.forget(USER, { apply = true, studio = true }, studio.deps)
			for name in studio.ordered do
				t.expect(string.sub(name, 1, #DragStrip.studioStorePrefix)).toBe(DragStrip.studioStorePrefix)
			end
			t.expect(studio.standard[Limiteds.store]).toBe(nil)
		end)

		t.it("no salt means no rows to delete; a store that throws is listed and the rest still runs", function()
			local w = world(now)
			local report = ForgetPlayer.forget(USER, { apply = true }, w.deps)
			t.expect(report.ok).toBe(true)
			t.expect(report.sql).toBe(nil)
			local broken = world(now)
			local deps = table.clone(broken.deps)
			deps.ordered = function(name: string): ForgetPlayer.Store
				if name ~= "" then
					error("mock outage")
				end
				return mockStore({})
			end
			local failed = ForgetPlayer.forget(USER, { apply = true }, deps)
			t.expect(failed.ok).toBe(false)
			t.expect(#failed.errors).toBe(#ForgetPlayer.weekKeys(ForgetPlayer.SETTINGS.firstBoardUtc, now))
		end)
	end)
end
