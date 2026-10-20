--!strict
-- GPS route progress math (Controllers/GpsController RouteMath): distance from a point to the route, finding
-- and trimming the route behind a moving player, the distance left, simplifying straight runs, miles; plus
-- sane Config/Gps values (touch targets, layout clear of the touch controls, the spawn-flow car). Pure logic on
-- fixtures: runs in Edit mode.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")

local Catalog = require(ReplicatedStorage.Shared.Vehicle.Catalog)
local Controls = require(ReplicatedStorage.Shared.Config.Controls)
local Gps = require(ReplicatedStorage.Shared.Config.Gps)
local Harness = require(ReplicatedStorage.Shared.Testing.Harness)
local Units = require(ReplicatedStorage.Shared.Util.Units)
local World = require(ReplicatedStorage.Shared.Config.World)

local Client = (StarterPlayer :: any).StarterPlayerScripts.Client
local GpsController = require(Client.Controllers.GpsController)
local RouteMath = GpsController.RouteMath

-- Roblox stores Vector3 components as 32-bit floats, so positions near 100 studs are only exact to ~1e-5.
local TOLERANCE = 1e-4

-- An L-shaped route: 100 studs east, then 100 studs south. 200 studs long.
local L_ROUTE = { Vector3.new(0, 0, 0), Vector3.new(100, 0, 0), Vector3.new(100, 0, 100) }

-- A hairpin: 300 studs east, a 20-stud jog, then 300 studs back west alongside the first leg.
local HAIRPIN = { Vector3.new(0, 0, 0), Vector3.new(300, 0, 0), Vector3.new(300, 0, 20), Vector3.new(0, 0, 20) }

local function near(t: Harness.Api, actual: Vector3, expected: Vector3)
	t.expect((actual - expected).Magnitude).toBeNear(0, TOLERANCE)
end

-- The fastest top speed (studs/s) of any car a player can drive.
local function fastestTopSpeed(): number
	local fastest = 0
	for _, vehicleId in Catalog.vehicleIds() do
		local vehicle = Catalog.getVehicle(vehicleId)
		if vehicle ~= nil and vehicle.playerDrivable then
			for _, trim in vehicle.trims do
				fastest = math.max(fastest, trim.topSpeedMph)
			end
		end
	end
	return Units.mphToStuds(fastest)
end

return function(t: Harness.Api)
	t.describe("GPS route math", function()
		t.describe("closestOnSegment", function()
			local a, b = Vector3.new(0, 0, 0), Vector3.new(100, 0, 0)

			t.it("finds the foot of the perpendicular inside the segment", function()
				local along, point = RouteMath.closestOnSegment(a, b, Vector3.new(30, 0, 12))
				t.expect(along).toBeNear(0.3, TOLERANCE)
				near(t, point, Vector3.new(30, 0, 0))
			end)

			t.it("clamps to the ends", function()
				local before, start = RouteMath.closestOnSegment(a, b, Vector3.new(-40, 0, 5))
				local after, finish = RouteMath.closestOnSegment(a, b, Vector3.new(160, 0, -5))
				t.expect(before).toBe(0)
				near(t, start, a)
				t.expect(after).toBe(1)
				near(t, finish, b)
			end)

			t.it("handles a zero-length segment", function()
				local along, point = RouteMath.closestOnSegment(a, a, Vector3.new(3, 4, 0))
				t.expect(along).toBe(0)
				near(t, point, a)
			end)
		end)

		t.describe("distance to the route", function()
			t.it("measures to the nearest leg", function()
				t.expect(RouteMath.distanceTo(L_ROUTE, Vector3.new(50, 0, 10))).toBeNear(10, TOLERANCE)
				t.expect(RouteMath.distanceTo(L_ROUTE, Vector3.new(110, 0, 50))).toBeNear(10, TOLERANCE)
			end)

			t.it("measures to an end or the corner when the point is past it", function()
				t.expect(RouteMath.distanceTo(L_ROUTE, Vector3.new(-30, 0, 40))).toBeNear(50, TOLERANCE)
				t.expect(RouteMath.distanceTo(L_ROUTE, Vector3.new(120, 0, -15))).toBeNear(25, TOLERANCE)
			end)

			t.it("counts height above the road", function()
				t.expect(RouteMath.distanceTo(L_ROUTE, Vector3.new(100, 5, 50))).toBeNear(5, TOLERANCE)
			end)

			t.it("works for a one-point route", function()
				t.expect(RouteMath.distanceTo({ Vector3.new(10, 0, 0) }, Vector3.new(13, 0, 4))).toBeNear(5, TOLERANCE)
			end)
		end)

		t.describe("following a moving player", function()
			local path = RouteMath.newPath(L_ROUTE)

			t.it("knows the route's length", function()
				t.expect(path.length).toBeNear(200, TOLERANCE)
				t.expect(path.along[2]).toBeNear(100, TOLERANCE)
			end)

			t.it("moves forward, trims the route behind and counts down the distance left", function()
				local cases = {
					{
						at = Vector3.new(10, 0, 2),
						segment = 1,
						along = 10,
						ahead = { Vector3.new(10, 0, 0), L_ROUTE[2], L_ROUTE[3] },
					},
					{
						at = Vector3.new(60, 0, 2),
						segment = 1,
						along = 60,
						ahead = { Vector3.new(60, 0, 0), L_ROUTE[2], L_ROUTE[3] },
					},
					{
						at = Vector3.new(98, 0, 40),
						segment = 2,
						along = 140,
						ahead = { Vector3.new(100, 0, 40), L_ROUTE[3] },
					},
					{
						at = Vector3.new(98, 0, 95),
						segment = 2,
						along = 195,
						ahead = { Vector3.new(100, 0, 95), L_ROUTE[3] },
					},
				}
				local progress = nil
				local lastAlong = -math.huge
				for _, case in cases do
					progress = RouteMath.project(path, case.at, progress, Gps.tracking.searchAhead)
					assert(progress, "projected")
					t.expect(progress.segment).toBe(case.segment)
					t.expect(progress.along).toBeNear(case.along, TOLERANCE)
					t.expect(progress.along >= lastAlong).toBe(true)
					t.expect(RouteMath.remaining(path, progress)).toBeNear(200 - case.along, TOLERANCE)
					local ahead = RouteMath.trimmed(path, progress)
					t.expect(#ahead).toBe(#case.ahead)
					for index, point in case.ahead do
						near(t, ahead[index], point)
					end
					lastAlong = progress.along
				end
			end)

			t.it("doesn't repeat the corner when the player is right at it", function()
				local progress = RouteMath.project(path, Vector3.new(103, 0, -5))
				t.expect(progress.segment).toBe(1)
				t.expect(progress.t).toBe(1)
				local ahead = RouteMath.trimmed(path, progress)
				t.expect(#ahead).toBe(2)
				near(t, ahead[1], L_ROUTE[2])
				near(t, ahead[2], L_ROUTE[3])
			end)

			t.it("limits the trimmed route to the points it may draw", function()
				local progress = RouteMath.project(path, Vector3.new(10, 0, 2))
				t.expect(#RouteMath.trimmed(path, progress, 2)).toBe(2)
			end)

			t.it("reaches zero left at the end, never below", function()
				local progress = RouteMath.project(path, Vector3.new(100, 0, 140))
				t.expect(RouteMath.remaining(path, progress)).toBe(0)
				t.expect(#RouteMath.trimmed(path, progress)).toBe(1)
			end)

			t.it("doesn't jump ahead to a later stretch that passes close by", function()
				local hairpin = RouteMath.newPath(HAIRPIN)
				local start = RouteMath.project(hairpin, Vector3.new(5, 0, 1))
				t.expect(start.segment).toBe(1)
				-- Nearer the return leg (8 studs) than the leg the player is on (12 studs).
				local between = Vector3.new(10, 0, 12)
				local tracked = RouteMath.project(hairpin, between, start, 100)
				t.expect(tracked.segment).toBe(1)
				t.expect(tracked.distance).toBeNear(12, TOLERANCE)
				t.expect(RouteMath.remaining(hairpin, tracked)).toBeNear(610, TOLERANCE)
				-- A search of the whole route (a fresh route) takes the nearest leg.
				local fresh = RouteMath.project(hairpin, between)
				t.expect(fresh.segment).toBe(3)
				t.expect(fresh.distance).toBeNear(8, TOLERANCE)
			end)

			t.it("gets off the route as soon as the player leaves it", function()
				local progress = RouteMath.project(path, Vector3.new(60, 0, 2))
				-- 80 studs north of the first leg and about 89 from the second leg's start: well off the route.
				local wandered = RouteMath.project(path, Vector3.new(60, 0, -80), progress, Gps.tracking.searchAhead)
				t.expect(wandered.distance).toBeGreaterThan(Gps.tracking.offRouteDistance)
			end)
		end)

		t.describe("simplify", function()
			t.it("turns a straight run of short edges into one segment", function()
				local straight: { Vector3 } = {}
				for x = 0, 100, 10 do
					table.insert(straight, Vector3.new(x, 0, 0))
				end
				local simple = RouteMath.simplify(straight, 0.5)
				t.expect(#simple).toBe(2)
				near(t, simple[1], straight[1])
				near(t, simple[2], straight[#straight])
			end)

			t.it("keeps corners", function()
				local route = {
					Vector3.new(0, 0, 0),
					Vector3.new(50, 0, 0),
					Vector3.new(100, 0, 0),
					Vector3.new(100, 0, 50),
					Vector3.new(100, 0, 100),
				}
				local simple = RouteMath.simplify(route, 0.5)
				t.expect(#simple).toBe(3)
				near(t, simple[2], Vector3.new(100, 0, 0))
			end)

			t.it("keeps a point where the route doubles back", function()
				local route = { Vector3.new(0, 0, 0), Vector3.new(100, 0, 0), Vector3.new(50, 0, 0) }
				t.expect(#RouteMath.simplify(route, 0.5)).toBe(3)
			end)

			t.it("drops a bend only when it is within the tolerance", function()
				local route = { Vector3.new(0, 0, 0), Vector3.new(50, 0, 0.3), Vector3.new(100, 0, 0) }
				t.expect(#RouteMath.simplify(route, 0.5)).toBe(2)
				t.expect(#RouteMath.simplify(route, 0.1)).toBe(3)
			end)

			t.it("drops repeated points", function()
				local route = { Vector3.new(0, 0, 0), Vector3.new(0, 0, 0), Vector3.new(10, 0, 0) }
				t.expect(#RouteMath.simplify(route, 0.5)).toBe(2)
			end)

			t.it("keeps a gentle curve within the tolerance of the original", function()
				local radius, tolerance = 1000, 0.5
				local arc: { Vector3 } = {}
				for step = 0, 120 do
					local angle = math.rad(step / 2) -- half a degree per point, 60 degrees in all
					table.insert(arc, Vector3.new(radius * math.sin(angle), 0, radius - radius * math.cos(angle)))
				end
				local simple = RouteMath.simplify(arc, tolerance)
				t.expect(#simple).toBeLessThan(#arc / 2)
				for _, point in arc do
					t.expect(RouteMath.distanceTo(simple, point)).toBeLessThan(tolerance + TOLERANCE)
				end
				local original, simplified = RouteMath.newPath(arc).length, RouteMath.newPath(simple).length
				t.expect(math.abs(original - simplified)).toBeLessThan(1)
			end)
		end)

		t.describe("distance left in miles", function()
			local studsPerMile = 1609.344 / World.metersPerStud

			t.it("converts studs to miles with Util/Units", function()
				t.expect(RouteMath.studsToMiles(studsPerMile)).toBeNear(1, TOLERANCE)
				t.expect(RouteMath.studsToMiles(0)).toBe(0)
			end)

			t.it("shows one decimal, and never less than the minimum", function()
				t.expect(GpsController.distanceText(studsPerMile * 1.26)).toBe("1.3 mi")
				t.expect(GpsController.distanceText(1)).toBe(string.format(Gps.panel.milesFormat, Gps.panel.minMiles))
			end)
		end)
	end)

	t.describe("Config/Gps", function()
		t.it("keeps every GPS touch target at least 44 px", function()
			local panel = Gps.panel
			t.expect(panel.minTarget >= 44).toBe(true)
			for _, size in { panel.buttonSize, panel.endButtonSize, panel.closeButtonSize } do
				t.expect(size.X >= panel.minTarget and size.Y >= panel.minTarget).toBe(true)
			end
			t.expect(panel.rowHeight >= panel.minTarget).toBe(true)
			t.expect(panel.endButtonSize.Y <= panel.buttonSize.Y).toBe(true) -- the End button fits in the chip
		end)

		t.it("puts the GPS button between the touch buttons and the touch pedals", function()
			local touch, panel = Controls.touch, Gps.panel
			local buttonsBottom = touch.margin + touch.buttonSize.Y
			local pedalsTop = Controls.hud.referenceShortSide
				- (touch.margin + touch.brakeSize.Y + touch.gap + touch.handbrakeSize.Y)
			t.expect(panel.top >= buttonsBottom).toBe(true)
			t.expect(panel.top + panel.buttonSize.Y <= pedalsTop).toBe(true)
		end)

		t.it("searches far enough ahead for the fastest car between two checks", function()
			local tracking = Gps.tracking
			local perCheck = fastestTopSpeed() / tracking.checkRateHz
			t.expect(tracking.searchAhead).toBeGreaterThan(perCheck * 2)
			t.expect(tracking.offRouteDistance).toBeGreaterThan(0)
			t.expect(tracking.arriveRadius).toBeGreaterThan(0)
			t.expect(Gps.route.maxPointsDrawn >= 2).toBe(true)
		end)

		t.it("hands out a car the catalog has and players can drive", function()
			local flow = Gps.spawnFlow
			local vehicle = Catalog.getVehicle(flow.vehicleId)
			t.expect(vehicle ~= nil and vehicle.playerDrivable).toBe(true)
			t.expect(Catalog.getTrim(flow.vehicleId, flow.trimId) ~= nil).toBe(true)
			t.expect(flow.cooldownSeconds).toBeGreaterThan(0)
		end)

		t.it("has a color for the default notice kind", function()
			t.expect(Gps.toast.kindColors[Gps.toast.defaultKind] ~= nil).toBe(true)
		end)
	end)
end
