--!strict
-- Hailing a pod (docs/phase-9-contracts.md "Hail a pod"): the fare and ride-time math in Config/Hail (the server
-- charges with it and the client estimates with it), who may hail (Services/HailService.eligibility), the route
-- cut down for the HailRide payload (thinRoute), where a rider is let off beside the road (sideOffset), and the
-- cutscene's glide and pose math (Controllers/HailController.Math); plus sane Config/Hail values and a fare for
-- every GPS destination from the player spawn. Pure logic: runs in Edit mode.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local StarterPlayer = game:GetService("StarterPlayer")

local Gps = require(ReplicatedStorage.Shared.Config.Gps)
local Hail = require(ReplicatedStorage.Shared.Config.Hail)
local Harness = require(ReplicatedStorage.Shared.Testing.Harness)
local MapLayout = require(ReplicatedStorage.Shared.Config.MapLayout)
local Pathfind = require(ReplicatedStorage.Shared.Road.Pathfind)
local World = require(ReplicatedStorage.Shared.Config.World)
local HailService = require(ServerScriptService.Server.Services.HailService)

local Client = (StarterPlayer :: any).StarterPlayerScripts.Client
local HailController = require(Client.Controllers.HailController)
local Theme = require(Client.UI.Theme)
local CutsceneMath = HailController.Math

local TOLERANCE = 1e-4 -- Vector3 components are 32-bit floats
local MIN_TARGET = 44 -- smallest touch target, px

-- Someone who may hail: alive, on foot, no job, no ride, no cooldown.
local function readyStatus(): HailService.Status
	return { riding = false, alive = true, onFoot = true, inJob = false, cooldownLeft = 0 }
end

-- A straight route of `count` points, one stud apart along +X (point i is at x = i).
local function lineOfPoints(count: number): { Vector3 }
	local points: { Vector3 } = {}
	for i = 1, count do
		table.insert(points, Vector3.new(i, 0, 0))
	end
	return points
end

local function near(t: Harness.Api, actual: Vector3, expected: Vector3)
	t.expect((actual - expected).Magnitude).toBeNear(0, TOLERANCE)
end

return function(t: Harness.Api)
	t.describe("Hail fares", function()
		t.it("charges the base fare plus the per-stud rate, in whole dollars", function()
			t.expect(Hail.fareFor(0)).toBe(Hail.baseFare)
			t.expect(Hail.fareFor(1000)).toBe(math.floor(Hail.baseFare + Hail.farePerStud * 1000 + 0.5))
			t.expect(Hail.fareFor(2500)).toBe(math.floor(Hail.baseFare + Hail.farePerStud * 2500 + 0.5))
			for _, studs in { 0, 123.4, 999.9, 4321, 8000 } do
				local fare = Hail.fareFor(studs)
				t.expect(fare).toBe(math.floor(fare))
			end
		end)

		t.it("never charges less for a longer ride", function()
			local last = Hail.fareFor(0)
			for studs = 100, 10000, 100 do
				local fare = Hail.fareFor(studs)
				t.expect(fare >= last).toBe(true)
				last = fare
			end
		end)

		t.it("treats a broken length as no distance", function()
			t.expect(Hail.fareFor(-500)).toBe(Hail.baseFare)
			t.expect(Hail.fareFor(0 / 0)).toBe(Hail.baseFare)
			t.expect(Hail.fareFor(math.huge)).toBe(Hail.baseFare)
		end)
	end)

	t.describe("Hail ride seconds", function()
		t.it("is secondsPerStud x the route inside the band", function()
			local studs = (Hail.minSeconds + Hail.maxSeconds) / 2 / Hail.secondsPerStud
			t.expect(Hail.secondsFor(studs)).toBeNear(studs * Hail.secondsPerStud, TOLERANCE)
		end)

		t.it("clamps short and long rides to minSeconds..maxSeconds", function()
			t.expect(Hail.secondsFor(0)).toBe(Hail.minSeconds)
			t.expect(Hail.secondsFor(1)).toBe(Hail.minSeconds)
			t.expect(Hail.secondsFor(1e9)).toBe(Hail.maxSeconds)
			t.expect(Hail.secondsFor(-10)).toBe(Hail.minSeconds)
			t.expect(Hail.secondsFor(0 / 0)).toBe(Hail.minSeconds)
		end)
	end)

	t.describe("Who may hail", function()
		t.it("lets a living player on foot, with no job, ride or cooldown, hail", function()
			t.expect(HailService.eligibility(readyStatus())).toBe(nil)
		end)

		t.it("refuses each blocker with its own reason", function()
			local riding = readyStatus()
			riding.riding = true
			t.expect(HailService.eligibility(riding)).toBe("riding")

			local dead = readyStatus()
			dead.alive = false
			t.expect(HailService.eligibility(dead)).toBe("notReady")

			local driving = readyStatus()
			driving.onFoot = false
			t.expect(HailService.eligibility(driving)).toBe("onFoot")

			local working = readyStatus()
			working.inJob = true
			t.expect(HailService.eligibility(working)).toBe("inJob")

			local waiting = readyStatus()
			waiting.cooldownLeft = 3
			t.expect(HailService.eligibility(waiting)).toBe("cooldown")
		end)

		t.it("checks in order: riding, alive, on foot, job, cooldown", function()
			local everything: HailService.Status =
				{ riding = true, alive = false, onFoot = false, inJob = true, cooldownLeft = 5 }
			t.expect(HailService.eligibility(everything)).toBe("riding")
			everything.riding = false
			t.expect(HailService.eligibility(everything)).toBe("notReady")
			everything.alive = true
			t.expect(HailService.eligibility(everything)).toBe("onFoot")
			everything.onFoot = true
			t.expect(HailService.eligibility(everything)).toBe("inJob")
			everything.inJob = false
			t.expect(HailService.eligibility(everything)).toBe("cooldown")
		end)

		t.it("counts a cooldown that has run out as none", function()
			local done = readyStatus()
			done.cooldownLeft = 0
			t.expect(HailService.eligibility(done)).toBe(nil)
			done.cooldownLeft = -2
			t.expect(HailService.eligibility(done)).toBe(nil)
		end)
	end)

	t.describe("The HailRide route", function()
		t.it("sends a short route whole, as a copy", function()
			local points = lineOfPoints(10)
			local thinned = HailService.thinRoute(points, Hail.routeMaxPoints)
			t.expect(thinned).toEqual(points)
			t.expect(thinned == points).toBe(false)
		end)

		t.it("cuts a long route to the budget, keeping the start whole and both ends", function()
			local points = lineOfPoints(500)
			local budget = Hail.routeMaxPoints
			local thinned = HailService.thinRoute(points, budget)
			t.expect(#thinned).toBe(budget)
			t.expect(thinned[1]).toBe(points[1])
			t.expect(thinned[#thinned]).toBe(points[#points])
			for i = 1, budget // 2 do
				t.expect(thinned[i]).toBe(points[i])
			end
			-- Every point is one of the route's, in the route's order, never twice.
			for i = 2, #thinned do
				t.expect(thinned[i].X > thinned[i - 1].X).toBe(true)
				t.expect(thinned[i].X).toBe(math.floor(thinned[i].X))
			end
		end)

		t.it("handles a route one point over the budget and a tiny budget", function()
			local points = lineOfPoints(Hail.routeMaxPoints + 1)
			local thinned = HailService.thinRoute(points, Hail.routeMaxPoints)
			t.expect(#thinned).toBe(Hail.routeMaxPoints)
			t.expect(thinned[#thinned]).toBe(points[#points])

			local two = HailService.thinRoute(lineOfPoints(30), 1)
			t.expect(#two).toBe(2)
			t.expect(two[1].X).toBe(1)
			t.expect(two[2].X).toBe(30)
		end)
	end)

	t.describe("Where riders are let off", function()
		t.it("uses the middle of the sidewalk on a road with one", function()
			t.expect(HailService.sideOffset(30, 8)).toBeNear(15 + 4, TOLERANCE)
		end)

		t.it("stays on the shoulder of a road with no sidewalk", function()
			t.expect(HailService.sideOffset(40, 0)).toBeNear(20 - Hail.dropOff.shoulderInset, TOLERANCE)
			t.expect(HailService.sideOffset(1, 0)).toBe(0)
		end)
	end)

	t.describe("The ride cutscene", function()
		local accel = Hail.cutscene.accelSeconds

		t.it("glides no faster than glideSpeed, and slower on a short route", function()
			local top = Hail.cutscene.glideSpeed
			t.expect(CutsceneMath.glideSpeed(1e6, 8, top, accel)).toBe(top)
			local slow = CutsceneMath.glideSpeed(100, 8, top, accel)
			t.expect(slow < top).toBe(true)
			t.expect(CutsceneMath.glideSpeed(0, 8, top, accel)).toBe(0)
			t.expect(CutsceneMath.glideSpeed(100, 0, top, accel)).toBe(0)
		end)

		t.it("speeds up smoothly, then keeps going, never past the route's end", function()
			local length = 200 -- short enough that the route, not glideSpeed, sets the speed
			local glide = 6
			local speed = CutsceneMath.glideSpeed(length, glide, Hail.cutscene.glideSpeed, accel)
			t.expect(CutsceneMath.glideDistance(0, speed, accel, length)).toBe(0)
			local last = 0
			for step = 1, 100 do
				local distance = CutsceneMath.glideDistance(step * glide / 100, speed, accel, length)
				t.expect(distance >= last).toBe(true)
				t.expect(distance <= length).toBe(true)
				last = distance
			end
			-- Just reaches the end as the glide ends (a short route sets the speed).
			t.expect(CutsceneMath.glideDistance(glide, speed, accel, length)).toBeNear(length, 1e-3)
			t.expect(CutsceneMath.glideDistance(glide * 3, speed, accel, length)).toBe(length)
		end)

		t.it("glides for the ride less the fade, but never too briefly", function()
			local cutscene = Hail.cutscene
			t.expect(CutsceneMath.glideSeconds(10, cutscene.fadeOutSeconds, cutscene.minGlideSeconds))
				.toBeNear(10 - cutscene.fadeOutSeconds, TOLERANCE)
			t.expect(CutsceneMath.glideSeconds(0, cutscene.fadeOutSeconds, cutscene.minGlideSeconds))
				.toBe(cutscene.minGlideSeconds)
		end)

		t.it("finds points along the route by distance", function()
			local path =
				CutsceneMath.newPath({ Vector3.new(0, 0, 0), Vector3.new(100, 0, 0), Vector3.new(100, 0, 100) })
			t.expect(path.length).toBeNear(200, TOLERANCE)
			near(t, CutsceneMath.pointAt(path, 50), Vector3.new(50, 0, 0))
			near(t, CutsceneMath.pointAt(path, 150), Vector3.new(100, 0, 50))
			near(t, CutsceneMath.pointAt(path, -10), Vector3.new(0, 0, 0))
			near(t, CutsceneMath.pointAt(path, 500), Vector3.new(100, 0, 100))
		end)

		t.it("puts the pod in the right-hand lane, facing the way it drives", function()
			-- Northbound (north is -Z), so the right-hand side is east (+X).
			local path = CutsceneMath.newPath({ Vector3.new(0, 0, 0), Vector3.new(0, 0, -200) })
			local lane = World.laneWidth / 2
			local pose = CutsceneMath.poseAt(path, 50, Hail.cutscene.headingStuds, lane)
			near(t, pose.Position, Vector3.new(lane, 0, -50))
			near(t, pose.LookVector, Vector3.new(0, 0, -1))
		end)

		t.it("eases at the same pace at any frame rate", function()
			local whole = CutsceneMath.smoothing(5, 1 / 30)
			local half = CutsceneMath.smoothing(5, 1 / 60)
			t.expect(1 - (1 - half) * (1 - half)).toBeNear(whole, 1e-9)
			t.expect(CutsceneMath.smoothing(5, 0)).toBe(0)
		end)
	end)

	t.describe("Config/Hail", function()
		t.it("has a sane fare, ride band and cooldown", function()
			t.expect(Hail.baseFare).toBeGreaterThan(0)
			t.expect(Hail.farePerStud).toBeGreaterThan(0)
			t.expect(Hail.minSeconds).toBeGreaterThan(0)
			t.expect(Hail.maxSeconds >= Hail.minSeconds).toBe(true)
			t.expect(Hail.secondsPerStud).toBeGreaterThan(0)
			t.expect(Hail.cooldownSeconds >= 0).toBe(true)
			t.expect(Hail.routeMaxPoints >= 2).toBe(true)
			t.expect(Hail.minStuds >= 0).toBe(true)
			t.expect(Hail.economyReason).toBe("hail")
		end)

		t.it("fits the fade inside the shortest ride", function()
			local cutscene = Hail.cutscene
			t.expect(Hail.minSeconds >= cutscene.minGlideSeconds + cutscene.fadeOutSeconds).toBe(true)
			t.expect(cutscene.fadeInSeconds).toBeGreaterThan(0)
			t.expect(cutscene.arriveRadius).toBeGreaterThan(0)
		end)

		t.it("holds the rider for the drop-off to stream in only while the screen is still black", function()
			t.expect(Hail.dropOff.streamWaitSeconds).toBeGreaterThan(0)
			t.expect(Hail.dropOff.streamWaitSeconds <= Hail.cutscene.arriveTimeoutSeconds).toBe(true)
		end)

		t.it("keeps the black screen under the notices", function()
			t.expect(Hail.cutscene.fadeDisplayOrder < Theme.displayOrder.toast).toBe(true)
			t.expect(Hail.cutscene.fadeDisplayOrder > Theme.displayOrder.shop).toBe(true)
		end)

		t.it("makes the Hail button a full touch target", function()
			t.expect(Theme.size.touchTarget >= MIN_TARGET).toBe(true)
		end)

		t.it("says the GPS's own words on arrival, so a routed place shows one notice", function()
			t.expect(Hail.messages.arrived).toBe(Gps.messages.arrived)
			local messages: { [string]: any } = Hail.messages :: any
			for _, text in messages do
				t.expect(type(text) == "string" and #text > 0).toBe(true)
			end
		end)
	end)

	t.describe("Every GPS destination", function()
		t.it("can be ridden to from the player spawn for a fare in the band", function()
			local spawn = MapLayout.playerSpawns[1].Position
			local cross = Hail.fareFor(20000) -- far more road than any ride in the county
			for _, location in MapLayout.locations do
				if location.gps then
					local route = Pathfind.route(spawn, location.gpsTarget or location.position)
					t.expect(route ~= nil).toBe(true)
					if route ~= nil then
						local fare = Hail.fareFor(route.length)
						t.expect(fare >= Hail.baseFare).toBe(true)
						t.expect(fare < cross).toBe(true)
					end
				end
			end
		end)
	end)
end
