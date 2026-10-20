--!strict
-- Hitching's decisions (docs/phase-8-contracts.md "Hitching, licenses and depots", "Tests"): what a tractor can
-- pull by class and hitch; whether a coupling may happen (class, distance between the hitch points, stillness,
-- whose load it is); whether an uncoupling may happen (only at a depot, yard or tow drop, turned to its yaw,
-- and still); the freight license's XP gate; the smoothed speed the stillness is judged on; where an idle trailer
-- stands on its spot; and the pose that lifts a towed car's nose onto a hitch. Then the map data the service runs
-- on: three or more freight depots with trailer spots, tow drops at the County Tow Yard and breakdown spots in
-- every zone. Pure logic: runs in Edit mode.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Harness = require(ReplicatedStorage.Shared.Testing.Harness)
local Jobs = require(ReplicatedStorage.Shared.Config.Jobs)
local MapLayout = require(ReplicatedStorage.Shared.Config.MapLayout)
local Trailers = require(ReplicatedStorage.Shared.Config.Trailers)
local HitchService = require(ServerScriptService.Server.Services.HitchService)

type CoupleFacts = HitchService.CoupleFacts
type DecoupleFacts = HitchService.DecoupleFacts
type Sample = HitchService.Sample

-- Vector3 holds 32-bit floats: positions a few thousand studs out are only exact to ~1e-3.
local CLOSE = 1e-3
local COUPLE_DISTANCE = 5
local MAX_SPEED = 2
local MAX_ANGLE = 30
local SAMPLE_STEP = 1 / 60 -- seconds between speed samples (Heartbeat)
local TRAILER_TAG = "TrailerSpawn"
local DEPOT_TAG = "JobDepot"
local TOW_YARD = "County Tow Yard"
local TOW_YARD_REACH = 200 -- studs: a TowDrop "at the County Tow Yard" is at most this far from its gate
local DEPOT_REACH = 300 -- studs: a depot's trailer spots are part of its yard, at most this far from it

-- A coupling that should pass: a semi backed onto a trailer and standing still.
local function goodCouple(): CoupleFacts
	return {
		role = "trailer",
		kind = "trailer",
		towing = false,
		taken = false,
		foreign = false,
		distance = COUPLE_DISTANCE / 2,
		coupleDistance = COUPLE_DISTANCE,
		angle = 4,
		maxAngle = MAX_ANGLE,
		speed = 0.3,
		maxSpeed = MAX_SPEED,
	}
end

-- In a Luau table literal `{ key = nil }` holds no key at all, so a change that removes a field uses NONE.
local NONE = newproxy(false)

local function with(facts: CoupleFacts, changes: { [string]: any }): CoupleFacts
	local copy = table.clone(facts) :: any
	for key, value in changes do
		copy[key] = if value == NONE then nil else value
	end
	return copy
end

local function goodDecouple(): DecoupleFacts
	return { coupled = true, together = true, inside = true, speed = 0.5, maxSpeed = MAX_SPEED }
end

local function locationsTagged(tag: string): { MapLayout.Location }
	local found: { MapLayout.Location } = {}
	for _, location in MapLayout.locations do
		if location.tag == tag then
			table.insert(found, location)
		end
	end
	return found
end

local function frameOf(location: MapLayout.Location): CFrame
	return CFrame.new(location.position) * CFrame.Angles(0, math.rad(location.yaw), 0)
end

-- Samples of a point moving at `velocity` (studs/s) for `seconds`, with `wobble` studs of alternating sideways
-- jitter (how the server sees a car its driver's client simulates).
local function track(velocity: Vector3, seconds: number, wobble: number): { Sample }
	local samples: { Sample } = {}
	local count = math.floor(seconds / SAMPLE_STEP) + 1
	for i = 0, count - 1 do
		local time = i * SAMPLE_STEP
		local jitter = Vector3.new(wobble * (if i % 2 == 0 then 1 else -1), 0, 0)
		table.insert(samples, { time = time, position = velocity * time + jitter })
	end
	return samples
end

return function(t: Harness.Api)
	t.describe("HitchService", function()
		t.describe("roleFor", function()
			t.it("lets a heavy truck with a kingpin pull trailers", function()
				t.expect(HitchService.roleFor("heavy", true, false)).toBe("trailer")
				t.expect(HitchService.roleFor("heavy", true, true)).toBe("trailer")
			end)

			t.it("lets a pickup or service truck with a tow hitch tow cars", function()
				t.expect(HitchService.roleFor("pickup", false, true)).toBe("towed")
				t.expect(HitchService.roleFor("service", false, true)).toBe("towed")
			end)

			t.it("lets nothing else pull anything", function()
				t.expect(HitchService.roleFor("heavy", false, false)).toBe(nil) -- no fifth wheel
				t.expect(HitchService.roleFor("service", false, false)).toBe(nil) -- the pod: no hitch
				t.expect(HitchService.roleFor("pickup", true, false)).toBe(nil) -- a kingpin is not a tow hitch
				t.expect(HitchService.roleFor("sedan", true, true)).toBe(nil) -- the class decides, not the parts
				t.expect(HitchService.roleFor(nil, true, true)).toBe(nil)
			end)

			t.it("follows the Config/Jobs classes", function()
				for _, classId in Jobs.types.freight.classes do
					t.expect(HitchService.roleFor(classId, true, false)).toBe("trailer")
				end
				for _, classId in Jobs.types.towing.classes do
					t.expect(HitchService.roleFor(classId, false, true)).toBe("towed")
				end
			end)
		end)

		t.describe("coupleDecision", function()
			t.it("couples a still tractor whose hitch is on the target's", function()
				t.expect(HitchService.coupleDecision(goodCouple())).toBe("ok")
				local towed = with(goodCouple(), { role = "towed", kind = "towed" })
				t.expect(HitchService.coupleDecision(towed)).toBe("ok")
			end)

			t.it("needs a tractor with the right hitch for the target", function()
				t.expect(HitchService.coupleDecision(with(goodCouple(), { role = NONE }))).toBe("noHitch")
				t.expect(HitchService.coupleDecision(with(goodCouple(), { kind = "towed" }))).toBe("wrongTarget")
				local pickup = with(goodCouple(), { role = "towed" })
				t.expect(HitchService.coupleDecision(pickup)).toBe("wrongTarget")
				t.expect(HitchService.coupleDecision(with(goodCouple(), { kind = NONE }))).toBe("nothingNear")
			end)

			t.it("couples one thing at a time, and never someone else's", function()
				t.expect(HitchService.coupleDecision(with(goodCouple(), { towing = true }))).toBe("alreadyCoupled")
				t.expect(HitchService.coupleDecision(with(goodCouple(), { taken = true }))).toBe("taken")
				t.expect(HitchService.coupleDecision(with(goodCouple(), { foreign = true }))).toBe("notYours")
			end)

			t.it("needs the hitch points within the couple distance, edge included", function()
				local at = with(goodCouple(), { distance = COUPLE_DISTANCE })
				t.expect(HitchService.coupleDecision(at)).toBe("ok")
				local past = with(goodCouple(), { distance = COUPLE_DISTANCE + 0.01 })
				t.expect(HitchService.coupleDecision(past)).toBe("tooFar")
				t.expect(HitchService.coupleDecision(with(goodCouple(), { distance = math.huge }))).toBe("tooFar")
				t.expect(HitchService.coupleDecision(with(goodCouple(), { distance = 0 / 0 }))).toBe("tooFar")
			end)

			t.it("needs the two lined up, well inside the hitch's own limits", function()
				t.expect(HitchService.coupleDecision(with(goodCouple(), { angle = MAX_ANGLE }))).toBe("ok")
				t.expect(HitchService.coupleDecision(with(goodCouple(), { angle = 90 }))).toBe("lineUp")
				t.expect(HitchService.coupleDecision(with(goodCouple(), { angle = 0 / 0 }))).toBe("lineUp")
				-- Across the front of a trailer, or across a car's nose: close enough, but refused.
				local across = with(goodCouple(), { angle = 85, speed = 20 })
				t.expect(HitchService.coupleDecision(across)).toBe("lineUp")
				t.expect(Trailers.coupleMaxAngle).toBeLessThan(Trailers.towed.hitch.upperAngle)
				t.expect(Trailers.coupleMaxAngle).toBeLessThan(Trailers.hitch.upperAngle)
				t.expect(Trailers.coupleMaxAngle).toBeLessThan(Trailers.jackknifeAngle)
			end)

			t.it("needs both still, measured", function()
				t.expect(HitchService.coupleDecision(with(goodCouple(), { speed = MAX_SPEED }))).toBe("ok")
				local rolling = with(goodCouple(), { speed = MAX_SPEED + 0.01 })
				t.expect(HitchService.coupleDecision(rolling)).toBe("notStill")
				t.expect(HitchService.coupleDecision(with(goodCouple(), { speed = NONE }))).toBe("notStill")
			end)

			t.it("names the first thing to fix: the truck, then the load, then lining up, then stopping", function()
				local everything = with(goodCouple(), { kind = "towed", distance = 50, speed = 20 })
				t.expect(HitchService.coupleDecision(everything)).toBe("wrongTarget")
				local farAndMoving = with(goodCouple(), { distance = 50, speed = 20 })
				t.expect(HitchService.coupleDecision(farAndMoving)).toBe("tooFar")
			end)
		end)

		t.describe("decoupleDecision", function()
			t.it("uncouples a still tractor at a drop", function()
				t.expect(HitchService.decoupleDecision(goodDecouple())).toBe("ok")
			end)

			t.it("refuses anywhere but a drop, and with nothing coupled", function()
				local open = goodDecouple()
				open.inside = false
				t.expect(HitchService.decoupleDecision(open)).toBe("notHere")
				local nothing = goodDecouple()
				nothing.coupled = false
				t.expect(HitchService.decoupleDecision(nothing)).toBe("notCoupled")
			end)

			t.it("refuses when the load is no longer on the tractor's hitch", function()
				local apart = goodDecouple()
				apart.together = false
				t.expect(HitchService.decoupleDecision(apart)).toBe("apart")
			end)

			t.it("needs the tractor still", function()
				local rolling = goodDecouple()
				rolling.speed = MAX_SPEED + 0.5
				t.expect(HitchService.decoupleDecision(rolling)).toBe("notStill")
				rolling.speed = nil
				t.expect(HitchService.decoupleDecision(rolling)).toBe("notStill")
			end)
		end)

		t.describe("dropSite", function()
			t.it("counts a depot's trailer spots for the depot and every tow drop for the tow yard", function()
				for _, location in MapLayout.locations do
					local attributes: { [string]: any } = location.attributes or {}
					local site = HitchService.dropSite(location)
					if location.tag == TRAILER_TAG then
						t.expect(site).toBe(attributes.depot)
					elseif location.tag == "TowDrop" then
						t.expect(site).toBe(attributes.yard)
					else
						t.expect(site).toBe(location.id)
					end
				end
			end)

			t.it("knows every freight depot's and tow drop's site", function()
				for _, location in MapLayout.locations do
					local attributes: { [string]: any } = location.attributes or {}
					if location.tag == TRAILER_TAG then
						t.expect(HitchService.siteOf(location.id)).toBe(attributes.depot)
						t.expect(HitchService.siteOf(attributes.depot)).toBe(attributes.depot)
					elseif location.tag == "TowDrop" then
						t.expect(HitchService.siteOf(location.id)).toBe(attributes.yard)
						t.expect(HitchService.siteOf(attributes.yard)).toBe(attributes.yard)
					elseif location.tag == "Breakdown" then
						t.expect(HitchService.siteOf(location.id)).toBe(nil)
					end
				end
				t.expect(HitchService.siteOf(nil)).toBe(nil)
			end)
		end)

		t.describe("insideFootprint and atDrop", function()
			-- An 80 x 36 depot turned to face west (yaw 90): its 80 studs run north-south, its 36 east-west.
			local depot = CFrame.new(1000, 0, 500) * CFrame.Angles(0, math.rad(90), 0)
			local size = Vector3.new(80, 1, 36)

			t.it("follows the footprint's yaw", function()
				t.expect(HitchService.insideFootprint(depot, size, Vector3.new(1000, 0, 500 - 39), 0)).toBe(true)
				t.expect(HitchService.insideFootprint(depot, size, Vector3.new(1000 + 17, 0, 500), 0)).toBe(true)
				-- Unturned, these would be inside: 30 east is past its 18-stud half depth, 41 north past its end.
				t.expect(HitchService.insideFootprint(depot, size, Vector3.new(1000 + 30, 0, 500), 0)).toBe(false)
				t.expect(HitchService.insideFootprint(depot, size, Vector3.new(1000, 0, 500 - 41), 0)).toBe(false)
			end)

			t.it("grows by the margin and ignores height", function()
				t.expect(HitchService.insideFootprint(depot, size, Vector3.new(1000 + 30, 0, 500), 12)).toBe(true)
				t.expect(HitchService.insideFootprint(depot, size, Vector3.new(1000, 40, 500), 0)).toBe(true)
			end)

			t.it("counts a point within the radius of a small drop's centre", function()
				local spot = CFrame.new(0, 0, 0) * CFrame.Angles(0, math.rad(30), 0)
				local small = Vector3.new(20, 1, 32)
				t.expect(HitchService.atDrop(spot, small, Vector3.new(0, 0, 0), 25)).toBe(true)
				t.expect(HitchService.atDrop(spot, small, Vector3.new(24, 0, 0), 25)).toBe(true)
				t.expect(HitchService.atDrop(spot, small, Vector3.new(30, 0, 0), 25)).toBe(false)
				t.expect(HitchService.atDrop(spot, small, Vector3.new(30, 0, 0), 0)).toBe(false)
			end)

			t.it("finds every drop's own centre inside it, and the open road outside all of them", function()
				local drops: { MapLayout.Location } = {}
				for _, location in MapLayout.locations do
					local attributes: { [string]: any } = location.attributes or {}
					local isDepot = location.tag == DEPOT_TAG
						and (attributes.jobType == "freight" or attributes.jobType == "towing")
					if isDepot or location.tag == "TowDrop" or location.tag == TRAILER_TAG then
						table.insert(drops, location)
					end
				end
				t.expect(#drops).toBeGreaterThan(0)
				local function anywhere(point: Vector3): boolean
					for _, location in drops do
						if HitchService.atDrop(frameOf(location), location.size, point, Trailers.decoupleRadius) then
							return true
						end
					end
					return false
				end
				for _, location in drops do
					t.expect(anywhere(location.position)).toBe(true)
				end
				-- Downtown's crossroads and the County Loop's far corner are no place to drop a trailer.
				t.expect(anywhere(Vector3.new(0, 0, 0))).toBe(false)
				t.expect(anywhere(Vector3.new(-3400, 0, 3000))).toBe(false)
			end)
		end)

		t.describe("licenseDecision", function()
			local license: Jobs.License = {
				id = "freight",
				displayName = "Freight license",
				xpRequired = 1500,
				level = 3,
				jobTypes = { "delivery", "towing" },
				price = 25000,
			}

			t.it("needs the XP in one of its job types, at least the threshold", function()
				t.expect(HitchService.licenseDecision({}, {}, license)).toBe("needXp")
				t.expect(HitchService.licenseDecision({ delivery = 1499 }, {}, license)).toBe("needXp")
				t.expect(HitchService.licenseDecision({ delivery = 1500 }, {}, license)).toBe("ok")
				t.expect(HitchService.licenseDecision({ towing = 4000 }, {}, license)).toBe("ok")
			end)

			t.it("doesn't add XP across job types or count other jobs", function()
				t.expect(HitchService.licenseDecision({ delivery = 1000, towing = 1000 }, {}, license)).toBe("needXp")
				t.expect(HitchService.licenseDecision({ rideshare = 99999 }, {}, license)).toBe("needXp")
			end)

			t.it("is idempotent: a holder is told so, XP or not", function()
				t.expect(HitchService.licenseDecision({}, { freight = true }, license)).toBe("owned")
				t.expect(HitchService.licenseDecision({ delivery = 5000 }, { freight = true }, license)).toBe("owned")
			end)

			t.it("reads the freight license from Config/Jobs at the §4 price", function()
				local freight = Jobs.freightLicense
				t.expect(freight.price).toBe(25000)
				t.expect(freight.xpRequired).toBeGreaterThan(0)
				t.expect(HitchService.licenseDecision({}, {}, freight)).toBe("needXp")
				local xp: { [string]: number } = { [freight.jobTypes[1]] = freight.xpRequired }
				t.expect(HitchService.licenseDecision(xp, {}, freight)).toBe("ok")
			end)
		end)

		t.describe("smoothedSpeed", function()
			t.it("measures a steady speed across the ground, not up or down", function()
				local speed = HitchService.smoothedSpeed(track(Vector3.new(3, 5, -4), 0.5, 0))
				t.expect(speed).toBeNear(5, CLOSE)
			end)

			t.it("reads a still car with sample wobble as nearly still", function()
				local speed = HitchService.smoothedSpeed(track(Vector3.zero, 0.5, 0.4))
				assert(speed, "a speed")
				t.expect(speed).toBeLessThan(MAX_SPEED)
			end)

			t.it("has no answer without two samples or time between them", function()
				t.expect(HitchService.smoothedSpeed({})).toBe(nil)
				t.expect(HitchService.smoothedSpeed({ { time = 1, position = Vector3.zero } })).toBe(nil)
				local sameTime = { { time = 1, position = Vector3.zero }, { time = 1, position = Vector3.xAxis } }
				t.expect(HitchService.smoothedSpeed(sameTime)).toBe(nil)
			end)
		end)

		t.describe("spotPose and heading", function()
			t.it("stands a trailer on its spot, nose along the spot's +X", function()
				for _, location in locationsTagged(TRAILER_TAG) do
					local pose = HitchService.spotPose(location.position, location.yaw)
					t.expect((pose.Position - location.position).Magnitude).toBeNear(0, CLOSE)
					local along = frameOf(location).RightVector
					t.expect(pose.LookVector:Dot(along)).toBeNear(1, CLOSE)
					t.expect(pose.UpVector.Y).toBeNear(1, CLOSE)
				end
			end)

			t.it("keeps only the heading across the ground", function()
				local frame = CFrame.Angles(0, math.rad(40), 0) * CFrame.Angles(math.rad(20), 0, 0)
				local heading = HitchService.heading(frame)
				local flat = Vector3.new(frame.LookVector.X, 0, frame.LookVector.Z).Unit
				t.expect(heading.LookVector:Dot(flat)).toBeNear(1, CLOSE)
				t.expect(heading.UpVector.Y).toBeNear(1, CLOSE)
				t.expect(HitchService.heading(CFrame.Angles(math.rad(-90), 0, 0)) == CFrame.identity).toBe(true)
			end)
		end)

		t.describe("towPose", function()
			local towPoint = Vector3.new(0, 0.3, -9.5) -- ahead of a 14-stud car's front, Config/Trailers-like
			local rearContact = Vector3.new(0, 0, 4)
			local maxLift = Trailers.towed.hitch.twistUpperAngle

			t.it("lifts the nose onto the hitch with the rear wheels on the ground", function()
				for _, case in
					{
						{ pivot = CFrame.new(10, 0, 20), hitch = Vector3.new(10.5, 1.6, 9) },
						{
							pivot = CFrame.new(100, 3, -40) * CFrame.Angles(0, math.rad(30), 0),
							hitch = Vector3.new(94, 4.7, -49),
						},
						{
							pivot = CFrame.new(-2000, 0, 3000) * CFrame.Angles(0, math.rad(-120), 0),
							hitch = Vector3.new(-2008, 1.8, 3006),
						},
					}
				do
					local pose = HitchService.towPose(case.pivot, towPoint, rearContact, case.hitch, maxLift)
					t.expect(((pose * towPoint) - case.hitch).Magnitude).toBeNear(0, CLOSE)
					t.expect((pose * rearContact).Y).toBeNear(case.pivot.Y, CLOSE)
					t.expect(pose.LookVector.Y).toBeGreaterThan(0) -- nose up
					-- Still facing the way it stood (across the ground).
					local before = Vector3.new(case.pivot.LookVector.X, 0, case.pivot.LookVector.Z).Unit
					local after = Vector3.new(pose.LookVector.X, 0, pose.LookVector.Z).Unit
					t.expect(after:Dot(before)).toBeNear(1, CLOSE)
				end
			end)

			t.it("lifts no further than the hitch's pitch limit", function()
				local pivot = CFrame.new(0, 0, 0)
				local hitch = Vector3.new(0, 40, -14)
				local pose = HitchService.towPose(pivot, towPoint, rearContact, hitch, maxLift)
				local pitch = math.deg(math.asin(pose.LookVector.Y))
				t.expect(pitch).toBeNear(maxLift, CLOSE)
				local landed = pose * towPoint
				t.expect(Vector3.new(landed.X - hitch.X, 0, landed.Z - hitch.Z).Magnitude).toBeNear(0, CLOSE)
			end)
		end)

		t.describe("the map", function()
			t.it("has three or more freight depots, each with trailer spots for the freight trailers", function()
				local depots: { [string]: MapLayout.Location } = {}
				local count = 0
				for _, location in locationsTagged(DEPOT_TAG) do
					local attributes: { [string]: any } = location.attributes or {}
					if attributes.jobType == "freight" then
						depots[location.id] = location
						count += 1
					end
				end
				t.expect(count >= 3).toBe(true)
				local trailerNames: { [string]: boolean } = {}
				for name in Trailers.trailers do
					trailerNames[name] = true
				end
				local spotsPerDepot: { [string]: number } = {}
				for _, spot in locationsTagged(TRAILER_TAG) do
					local attributes: { [string]: any } = spot.attributes or {}
					local depot = depots[attributes.depot]
					t.expect(depot ~= nil).toBe(true)
					t.expect(trailerNames[attributes.trailer]).toBe(true)
					if depot then
						spotsPerDepot[depot.id] = (spotsPerDepot[depot.id] or 0) + 1
						-- A depot's spots are part of its yard.
						t.expect((spot.position - depot.position).Magnitude).toBeLessThan(DEPOT_REACH)
					end
					-- Long enough for the longest trailer standing along it.
					for _, spec in Trailers.trailers do
						t.expect(spot.size.X >= spec.length).toBe(true)
					end
				end
				for id in depots do
					t.expect(spotsPerDepot[id] or 0).toBeGreaterThan(0)
				end
			end)

			t.it("puts tow drops at the County Tow Yard", function()
				local yard: MapLayout.Location? = nil
				for _, location in locationsTagged(DEPOT_TAG) do
					if location.displayName == TOW_YARD then
						yard = location
					end
				end
				assert(yard, "the County Tow Yard")
				local drops = locationsTagged("TowDrop")
				t.expect(#drops).toBeGreaterThan(0)
				for _, drop in drops do
					t.expect((drop.position - yard.position).Magnitude).toBeLessThan(TOW_YARD_REACH)
					local attributes: { [string]: any } = drop.attributes or {}
					t.expect(attributes.yard).toBe(yard.id)
				end
			end)

			t.it("has breakdown spots in every zone", function()
				local zones: { [string]: number } = {}
				for _, location in locationsTagged("Breakdown") do
					zones[location.zone] = (zones[location.zone] or 0) + 1
				end
				for id in MapLayout.zones do
					t.expect(zones[id] or 0).toBeGreaterThan(0)
				end
			end)
		end)
	end)
end
