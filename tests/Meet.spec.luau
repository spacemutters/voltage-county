--!strict
-- Car meets (docs/phase-13-contracts.md "Social"; PLAN.md Phase 13 acceptance "The meet announcement fires at 4
-- parked cars and not at 3"): Services/MeetService's ledger (which spot each car counts at, one per player), its
-- step (when a meet is announced, the cooldown, a meet carrying on), where a car stands (spotAt, on the real
-- MeetSpots in Config/MapLayout), the announcement's words, and sane Config/Social values; plus the Feed's client
-- helpers (Controllers/FeedController.normalize and insert, UI/Phone/FeedApp.ageText). Pure logic: runs in Edit mode.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local StarterPlayer = game:GetService("StarterPlayer")

local Harness = require(ReplicatedStorage.Shared.Testing.Harness)
local LightShows = require(ReplicatedStorage.Shared.Config.LightShows)
local MapLayout = require(ReplicatedStorage.Shared.Config.MapLayout)
local Social = require(ReplicatedStorage.Shared.Config.Social)
local MeetService = require(ServerScriptService.Server.Services.MeetService)

local Client = StarterPlayer.StarterPlayerScripts.Client
local FeedController = require(Client.Controllers.FeedController)
local FeedApp = require(Client.UI.Phone.FeedApp)

local SPOT = "spot_a"
local OTHER_SPOT = "spot_b"
local MIN = Social.meet.minCars
local COOLDOWN = Social.meet.cooldownSeconds
local NUDGE = 0.01 -- studs: just inside or outside an edge

-- A spot's meet as MeetService runs it: every ledger change steps the spots it touched, and announcements are kept.
type Sim = {
	ledger: MeetService.Ledger,
	states: { [string]: MeetService.SpotState },
	announced: { [string]: number }, -- by spot: how many times a meet was announced there
	now: number,
}

local function newSim(): Sim
	return { ledger = MeetService.newLedger(), states = {}, announced = {}, now = 0 }
end

local function apply(sim: Sim, changed: { string })
	for _, spot in changed do
		local count = MeetService.count(sim.ledger, spot)
		local state, fire = MeetService.step(sim.states[spot] or MeetService.newSpotState(), count, sim.now)
		sim.states[spot] = state
		if fire then
			sim.announced[spot] = (sim.announced[spot] or 0) + 1
		end
	end
end

local function park(sim: Sim, car: string, owner: string, spot: string?)
	apply(sim, MeetService.place(sim.ledger, car, owner, spot))
end

local function leave(sim: Sim, car: string)
	apply(sim, MeetService.remove(sim.ledger, car))
end

-- Parks cars "car1".."carN" of players "p1".."pN" at `spot`.
local function parkMany(sim: Sim, from: number, to: number, spot: string)
	for i = from, to do
		park(sim, `car{i}`, `p{i}`, spot)
	end
end

local function meetSpots(): { MapLayout.Location }
	local list: { MapLayout.Location } = {}
	for _, location in MapLayout.locations do
		if location.tag == Social.meet.spotTag then
			table.insert(list, location)
		end
	end
	return list
end

-- A point on `location`'s footprint at local (x, height above the surface, z).
local function pointOn(location: MapLayout.Location, x: number, height: number, z: number): Vector3
	return LightShows.footprintFrame(location.position, location.yaw):PointToWorldSpace(Vector3.new(x, height, z))
end

local function entry(id: string, at: number): Social.FeedEntry
	return { id = id, kind = "meet", text = `entry {id}`, at = at }
end

return function(t: Harness.Api)
	t.describe("Car meets", function()
		t.describe("counting parked cars", function()
			t.it("needs four cars for a meet", function()
				t.expect(MIN).toBe(4)
			end)

			t.it("counts each parked car at its spot", function()
				local ledger = MeetService.newLedger()
				for i = 1, 3 do
					MeetService.place(ledger, `car{i}`, `p{i}`, SPOT)
				end
				MeetService.place(ledger, "car4", "p4", OTHER_SPOT)
				t.expect(MeetService.count(ledger, SPOT)).toBe(3)
				t.expect(MeetService.count(ledger, OTHER_SPOT)).toBe(1)
			end)

			t.it("counts two cars of one player once", function()
				local ledger = MeetService.newLedger()
				MeetService.place(ledger, "car1", "p1", SPOT)
				MeetService.place(ledger, "car2", "p1", SPOT)
				t.expect(MeetService.count(ledger, SPOT)).toBe(1)
			end)

			t.it("counts a car as parked when anchored, still with its driver in, or in a light show", function()
				t.expect(MeetService.settled(true, false, false)).toBe(true) -- owner out (VehicleService anchors it)
				t.expect(MeetService.settled(false, true, false)).toBe(true) -- owner seated, standing still
				t.expect(MeetService.settled(false, false, true)).toBe(true) -- in a light show
				t.expect(MeetService.settled(false, false, false)).toBe(false) -- driving
			end)

			t.it("fires for four cars whose owners sit in them, standing still", function()
				local sim = newSim()
				for i = 1, MIN do
					local spot = if MeetService.settled(false, true, false) then SPOT else nil
					park(sim, `car{i}`, `p{i}`, spot)
				end
				t.expect(MeetService.count(sim.ledger, SPOT)).toBe(MIN)
				t.expect(sim.announced[SPOT]).toBe(1)
			end)

			t.it("reports which spots changed when a car moves", function()
				local ledger = MeetService.newLedger()
				t.expect(MeetService.place(ledger, "car1", "p1", SPOT)).toEqual({ SPOT })
				t.expect(MeetService.place(ledger, "car1", "p1", SPOT)).toEqual({})
				t.expect(MeetService.place(ledger, "car1", "p1", OTHER_SPOT)).toEqual({ SPOT, OTHER_SPOT })
				t.expect(MeetService.place(ledger, "car1", "p1", nil)).toEqual({ OTHER_SPOT })
				t.expect(MeetService.place(ledger, "car1", "p1", nil)).toEqual({})
			end)
		end)

		t.describe("announcing", function()
			t.it("fires at 4 parked cars and not at 3", function()
				local sim = newSim()
				parkMany(sim, 1, 3, SPOT)
				t.expect(sim.announced[SPOT]).toBe(nil)
				park(sim, "car4", "p4", SPOT)
				t.expect(sim.announced[SPOT]).toBe(1)
			end)

			t.it("doesn't fire for cars that are not at the spot", function()
				local sim = newSim()
				parkMany(sim, 1, 3, SPOT)
				park(sim, "car4", "p4", OTHER_SPOT)
				park(sim, "car5", "p5", nil) -- driving
				t.expect(sim.announced[SPOT]).toBe(nil)
				t.expect(sim.announced[OTHER_SPOT]).toBe(nil)
			end)

			t.it("doesn't fire for one player's second car", function()
				local sim = newSim()
				parkMany(sim, 1, 3, SPOT)
				park(sim, "car4", "p1", SPOT)
				t.expect(sim.announced[SPOT]).toBe(nil)
			end)

			t.it("fires once while the meet stays at 4 or more", function()
				local sim = newSim()
				parkMany(sim, 1, 6, SPOT)
				t.expect(sim.announced[SPOT]).toBe(1)
				leave(sim, "car6")
				leave(sim, "car5")
				t.expect(sim.announced[SPOT]).toBe(1)
			end)

			t.it("steps a spot on the count alone", function()
				local state, fire = MeetService.step(MeetService.newSpotState(), MIN - 1, 0)
				t.expect(fire).toBe(false)
				t.expect(state.active).toBe(false)
				state, fire = MeetService.step(state, MIN, 1)
				t.expect(fire).toBe(true)
				t.expect(state.active).toBe(true)
			end)
		end)

		t.describe("cooldown", function()
			t.it("waits before the cooldown is over and fires after it", function()
				local sim = newSim()
				parkMany(sim, 1, 4, SPOT)
				t.expect(sim.announced[SPOT]).toBe(1)

				sim.now = 100
				leave(sim, "car4") -- below 4: the cooldown starts now
				sim.now = 100 + COOLDOWN / 2
				park(sim, "car4", "p4", SPOT) -- back to 4 too soon: the same meet carrying on
				t.expect(sim.announced[SPOT]).toBe(1)
				t.expect(sim.states[SPOT].active).toBe(true)

				sim.now = 200 + COOLDOWN
				leave(sim, "car4") -- below again: the cooldown starts over
				sim.now = 200 + COOLDOWN * 2 - 1
				park(sim, "car4", "p4", SPOT)
				t.expect(sim.announced[SPOT]).toBe(1)

				sim.now = 300 + COOLDOWN * 2
				leave(sim, "car4")
				sim.now = 300 + COOLDOWN * 3 -- exactly the cooldown later
				park(sim, "car4", "p4", SPOT)
				t.expect(sim.announced[SPOT]).toBe(2)
			end)

			t.it("keeps each spot's cooldown to itself", function()
				local sim = newSim()
				parkMany(sim, 1, 4, SPOT)
				for i = 5, 8 do
					park(sim, `car{i}`, `p{i}`, OTHER_SPOT)
				end
				t.expect(sim.announced[SPOT]).toBe(1)
				t.expect(sim.announced[OTHER_SPOT]).toBe(1)
			end)

			t.it("is a positive time", function()
				t.expect(COOLDOWN).toBeGreaterThan(0)
			end)
		end)

		t.describe("leaving", function()
			t.it("drops the count when a car leaves the world", function()
				local sim = newSim()
				parkMany(sim, 1, 4, SPOT)
				sim.now = 50
				leave(sim, "car2")
				t.expect(MeetService.count(sim.ledger, SPOT)).toBe(3)
				t.expect(sim.states[SPOT].active).toBe(false)
				t.expect(sim.states[SPOT].quietSince).toBe(50)
			end)

			t.it("drops the count when a car drives off", function()
				local sim = newSim()
				parkMany(sim, 1, 4, SPOT)
				park(sim, "car1", "p1", nil)
				t.expect(MeetService.count(sim.ledger, SPOT)).toBe(3)
				t.expect(sim.states[SPOT].active).toBe(false)
			end)

			t.it("drops every car of a player who leaves the game", function()
				local ledger = MeetService.newLedger()
				MeetService.place(ledger, "car1", "p1", SPOT)
				MeetService.place(ledger, "car2", "p1", OTHER_SPOT)
				MeetService.place(ledger, "car3", "p2", SPOT)
				local changed = MeetService.removeOwner(ledger, "p1")
				table.sort(changed)
				t.expect(changed).toEqual({ SPOT, OTHER_SPOT })
				t.expect(MeetService.count(ledger, SPOT)).toBe(1)
				t.expect(MeetService.count(ledger, OTHER_SPOT)).toBe(0)
			end)

			t.it("says nothing changed when an unknown or unparked car leaves", function()
				local ledger = MeetService.newLedger()
				t.expect(MeetService.remove(ledger, "nobody")).toEqual({})
				MeetService.place(ledger, "car1", "p1", nil)
				t.expect(MeetService.remove(ledger, "car1")).toEqual({})
			end)
		end)

		t.describe("where a car stands", function()
			local spots = meetSpots()

			t.it("has meet spots on the map", function()
				t.expect(#spots).toBeGreaterThan(0)
			end)

			t.it("finds the spot under a car on its footprint", function()
				for _, location in spots do
					t.expect(MeetService.spotAt(pointOn(location, 0, 0, 0), spots, 0)).toBe(location.id)
					local cornerX, cornerZ = location.size.X / 2 - NUDGE, location.size.Z / 2 - NUDGE
					t.expect(MeetService.spotAt(pointOn(location, cornerX, 0, -cornerZ), spots, 0)).toBe(location.id)
				end
			end)

			t.it("misses cars beside, above or below the footprint", function()
				local join = LightShows.join
				for _, location in spots do
					local outside = location.size.X / 2 + Social.meet.footprintMargin + 1
					t.expect(MeetService.spotAt(pointOn(location, outside, 0, 0), spots, Social.meet.footprintMargin))
						.toBe(nil)
					local high = location.size.Y + join.heightAbove + 1
					t.expect(MeetService.spotAt(pointOn(location, 0, high, 0), spots, 0)).toBe(nil)
					t.expect(MeetService.spotAt(pointOn(location, 0, -join.heightBelow - 1, 0), spots, 0)).toBe(nil)
				end
			end)

			t.it("lets a car stand a little over the edge", function()
				local margin = Social.meet.footprintMargin
				for _, location in spots do
					local x = location.size.X / 2 + margin - NUDGE
					t.expect(MeetService.spotAt(pointOn(location, x, 0, 0), spots, margin)).toBe(location.id)
					t.expect(MeetService.spotAt(pointOn(location, x, 0, 0), spots, 0)).toBe(nil)
				end
			end)

			t.it("parks Studio stand-ins at a real meet spot", function()
				local found = false
				for _, location in spots do
					found = found or location.id == Social.dev.defaultMeetSpot
				end
				t.expect(found).toBe(true)
				t.expect(#LightShows.slotFrames(CFrame.new(), spots[1].size) >= MIN).toBe(true)
			end)
		end)

		t.describe("the announcement", function()
			t.it("names the spot and the cars, in plain words", function()
				local location = meetSpots()[1]
				local made = MeetService.announcement(location, MIN, "id-1", 123)
				t.expect(made.id).toBe("id-1")
				t.expect(made.kind).toBe(Social.feed.kinds.meet)
				t.expect(made.at).toBe(123)
				t.expect(made.meetSpotId).toBe(location.id)
				t.expect(made.cars).toBe(MIN)
				t.expect(string.find(made.text, location.displayName, 1, true) ~= nil).toBe(true)
				t.expect(string.find(made.text, tostring(MIN), 1, true) ~= nil).toBe(true)
				t.expect(Social.feed.text.kindLabels[made.kind] ~= nil).toBe(true)
			end)
		end)
	end)

	t.describe("Feed", function()
		t.it("reads a good FeedUpdate and its backlog flag", function()
			local made, backlog = FeedController.normalize({
				id = "a",
				kind = "meet",
				text = "Car meet!",
				at = 10,
				meetSpotId = "lk_overlook",
				cars = 4,
				backlog = true,
			})
			t.expect(made)
				.toEqual({ id = "a", kind = "meet", text = "Car meet!", at = 10, meetSpotId = "lk_overlook", cars = 4 })
			t.expect(backlog).toBe(true)
		end)

		t.it("refuses a malformed FeedUpdate", function()
			t.expect((FeedController.normalize(nil))).toBe(nil)
			t.expect((FeedController.normalize({ id = "a", kind = "meet", text = "", at = 1 }))).toBe(nil)
			t.expect((FeedController.normalize({ id = "a", kind = "meet", text = "x" }))).toBe(nil)
			t.expect((FeedController.normalize({ id = 5, kind = "meet", text = "x", at = 1 }))).toBe(nil)
		end)

		t.it("lists entries newest first, once each, up to the limit", function()
			local list = {}
			list = (FeedController.insert(list, entry("a", 10), 3))
			list = (FeedController.insert(list, entry("b", 30), 3))
			list = (FeedController.insert(list, entry("c", 20), 3))
			t.expect(list[1].id).toBe("b")
			t.expect(list[2].id).toBe("c")
			t.expect(list[3].id).toBe("a")
			local again, fresh = FeedController.insert(list, entry("c", 20), 3)
			t.expect(fresh).toBe(false)
			t.expect(#again).toBe(3)
			local trimmed = FeedController.insert(list, entry("d", 40), 3)
			t.expect(#trimmed).toBe(3)
			t.expect(trimmed[1].id).toBe("d")
			t.expect(trimmed[3].id).toBe("c") -- the oldest went
			t.expect(#list).toBe(3) -- the list given is never changed
		end)

		t.it("says how long ago in plain words", function()
			local feed = Social.feed
			t.expect(FeedApp.ageText(0)).toBe(feed.text.justNow)
			t.expect(FeedApp.ageText(-5)).toBe(feed.text.justNow) -- a clock a little ahead
			t.expect(FeedApp.ageText(feed.secondsPerMinute * 3 + 5)).toBe(string.format(feed.text.minutesAgo, 3))
			t.expect(FeedApp.ageText(feed.secondsPerHour * 2)).toBe(string.format(feed.text.hoursAgo, 2))
		end)

		t.it("keeps a sane number of entries", function()
			t.expect(Social.feed.maxEntries).toBeGreaterThan(0)
		end)
	end)
end
