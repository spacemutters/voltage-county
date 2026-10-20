--!strict
-- Hitching, the freight license and the depots' idle trailers (PLAN.md Phase 8; docs/phase-8-contracts.md
-- "Hitching, licenses and depots").
--
-- Server-authoritative (CLAUDE.md hard rule 1): clients only ask (Net TrailerAction { action = "couple" |
-- "decouple" }, Net BuyLicense { license = "freight" }); every check is made here on what the server sees.
--
--   couple    couple(player, tractor, target): the tractor is the player's own car with them in its Driver seat.
--             What it can pull follows its class and hitch: a Config/Jobs freight class (heavy) with a Kingpin
--             attachment pulls trailers (Config/Trailers' tag or TrailerId, and a Kingpin: TrailerModels copies);
--             a Config/Jobs towing class (pickup, service) with a TowHitch tows cars with Towed = true (their
--             TowPoint). The two hitch points must be within Config/Trailers.coupleDistance, the two lined up
--             within coupleMaxAngle (Vehicle/Trailer.articulation: the joint must never start outside its own
--             limits) and both vehicles under coupleMaxSpeed, judged on Config/Jobs smoothness.speedWindow of server
--             samples (the server's view of a client-driven car wobbles from frame to frame). A target a job put out for someone else (Config/Jobs
--             props.ownerAttribute) is theirs alone. Then the server sets the target exactly on the hitch (a
--             trailer slides the few studs; a towed car's nose is lifted onto the hitch with its rear wheels on the
--             ground), joins them with a BallSocketConstraint "Hitch" (Attachment0 = the tractor's Kingpin or
--             TowHitch, Attachment1 = the trailer's Kingpin or the car's TowPoint; Config/Trailers' hitch
--             settings through Vehicle/Trailer.configureHitch: the attachments face the same way when the rig is
--             in line, so the joint rests straight), adds a NoCollisionConstraint between the two chassis,
--             unanchors the target, hands both to the driver (SetNetworkOwner), marks the tractor (attribute
--             TowingModel = the target's name, ObjectValue Towing = the target: Config/Trailers' names) and tells
--             AntiExploitService the pair's top speed: the tractor's own (Vehicle/Trailer brakes a trailer that
--             would push past it), as the "hitch" cap of setSpeedCap, so EnergyService's limp cap still wins.
--   decouple  decouple(player, tractor): only at a drop (a JobDepot with jobType "freight" or "towing" - the
--             County Tow Yard -, a TowDrop, or a depot's TrailerSpawn): the tractor's own hitch (the joint's
--             Attachment0, on the chassis AntiExploitService tracks; never the load, which the driver's client
--             simulates) inside its footprint (turned to its yaw) or within Config/Trailers.decoupleRadius of its
--             centre, the load's hitch point still within coupleDistance of it (refused and logged otherwise), and
--             the tractor under decoupleMaxSpeed;
--             anywhere else it is refused with a clear message and nothing changes. Then the joint goes, the
--             target is anchored where it stands (a trailer on its legs; a towed car set back down level on the
--             ground) and handed back to the server, the tractor's marks are cleared and its speed cap lifted.
--             droppedAt(target) then names the site of the drop (siteOf: a depot's id for the depot and its
--             trailer spots, the tow yard's for its tow drops), which is what JobService judges a decouple stop by.
--   parking   the coupling survives the driver getting out: when VehicleService parks the tractor (anchors its
--             chassis) the target is anchored too and handed back to the server; when the driver gets back in
--             (the chassis unanchored) the target follows and goes back to them. No hook in VehicleService: this
--             watches the tractor chassis's Anchored property. A server move of the tractor (VehicleService
--             .resetCar -> AntiExploitService.allowTeleport) brings the target along (onServerMove).
--   lost      the tractor or target leaving the world (despawn, the player leaving) ends the coupling: the
--             one left behind is anchored where it is.
--   depots    at Start one idle trailer waits on every MapLayout TrailerSpawn spot (attributes depot, trailer),
--             anchored, standing along the spot (nose toward the spot's +X, the way traffic flows past it), a
--             copy of ServerStorage.TrailerModels.<trailer>. Anyone with a semi can hitch one. One taken away and
--             let go elsewhere stops belonging to its spot at once (a fresh one is put back on the spot, so
--             idleTrailer only ever names one standing there) and goes after Config/Jobs props.despawnDelaySec
--             unless it is hitched again first; one let go back on its own spot simply waits there again. A job can take a spot's trailer for
--             itself with takeTrailer(spotId, player); the spot is restocked once that trailer leaves the world.
--   license   BuyLicense { license }: needs Config/Jobs licenses[id].xpRequired XP in any of its jobTypes (the
--             job level gate) and its price (Config/Economy.freightLicensePrice) through EconomyService.trySpend,
--             then PlayerData.jobs.licenses[id] = true. Idempotent: a player who holds it is told so and pays
--             nothing; one request per player at a time; a charge whose save fails is refunded.
--
-- For job modules: release(model) undoes a coupling anywhere (jobs end), coupledTo(tractor), tractorOf(target),
-- onChanged(listener) and the spot functions below.
--
-- No polling (CLAUDE.md hard rule 10): everything runs on remote calls, property and ancestry signals and
-- task.delay; the stillness check samples Heartbeat for a fraction of a second inside the call that asked.
-- The decisions are pure helpers (roleFor, coupleDecision, decoupleDecision, licenseDecision, insideFootprint,
-- atDrop, dropSite, smoothedSpeed, spotPose, heading, towPose) for tests/Hitch.spec.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local Catalog = require(Shared.Vehicle.Catalog)
local Economy = require(Shared.Config.Economy)
local Jobs = require(Shared.Config.Jobs)
local MapLayout = require(Shared.Config.MapLayout)
local Net = require(Shared.Net)
local Spawning = require(Shared.Config.Spawning)
local Trailer = require(Shared.Vehicle.Trailer)
local Trailers = require(Shared.Config.Trailers)
local Units = require(Shared.Util.Units)
local AntiExploit = require(Shared.Config.AntiExploit)
local AntiExploitService = require(script.Parent.AntiExploitService)
local EconomyService = require(script.Parent.EconomyService)
local VehicleService = require(script.Parent.VehicleService)

-- DataService is required in Init rather than here: it loads ProfileStore, which talks to DataStores straight
-- away, and tests/Hitch.spec requires this module in Edit mode for its pure helpers.
type DataServiceModule = typeof(require(script.Parent.DataService))

---------------------------------------------------------------------------------------------------------------
-- Settings
---------------------------------------------------------------------------------------------------------------

-- The hitch rules, from Config/Trailers and Config/Jobs.
local HITCH = {
	coupleDistance = Trailers.coupleDistance, -- studs between the two hitch points (also the most they may
	-- drift apart while coupled before an uncouple is refused: the joint holds them together)
	coupleMaxAngle = Trailers.coupleMaxAngle, -- degrees between tractor and target headings to couple
	coupleMaxSpeed = Trailers.coupleMaxSpeed, -- studs/s: both vehicles this still to couple...
	decoupleMaxSpeed = Trailers.decoupleMaxSpeed, -- ...and the tractor to uncouple
	decoupleRadius = Trailers.decoupleRadius, -- studs round a drop's centre that count as at it
	stillWindow = Jobs.smoothness.speedWindow, -- seconds of server samples a speed is smoothed over
	-- A towed car's nose is lifted onto the hitch at most as far as the hitch lets it pitch.
	maxTowLift = Trailers.towed.hitch.twistUpperAngle,
	-- TrailerAction looks this many times the couple distance round the hitch for something to couple, so a
	-- player a little short of it hears "closer" rather than "nothing here".
	searchFactor = 3,
}

local PROPS = Jobs.props
local CAP_KEY = "hitch" -- AntiExploitService.setSpeedCap key
local CHASSIS = "Chassis" -- vehicle model contract: the only physics body
local SEATS_FOLDER = "Seats"
local DRIVER_SEAT = "Driver"
local VEHICLE_ID = "VehicleId" -- vehicle model contract attributes
local TRIM = "Trim"
local KINGPIN = "Kingpin" -- semi tractor (fifth wheel) and trailer (pin) attachments
local TOW_HITCH = "TowHitch" -- pickups and tow trucks
local TOW_POINT = "TowPoint" -- every car model's front tow point
local REAR_WHEELS = { "WheelRL", "WheelRR" } -- hub attachments: a towed car pivots about its rear axle
local JOINT_NAME = "Hitch" -- the BallSocketConstraint, under the tractor's chassis
local NO_COLLIDE_NAME = "HitchNoCollide"
local SPOT_ATTRIBUTE = "TrailerSpawn" -- on an idle trailer: the id of the spot it belongs to
local TRAILERS_FOLDER = "Trailers" -- Workspace.Trailers holds the depots' idle trailers
local SPOT_TAG = "TrailerSpawn"
local TOW_DROP_TAG = "TowDrop"
local DROP_TAGS = { TowDrop = true, TrailerSpawn = true } :: { [string]: boolean } -- besides the depots
local DEPOT_TAG = "JobDepot"
local DROP_JOB_TYPES = { freight = true, towing = true } :: { [string]: boolean }
local LICENSE_REASON = "license" -- EconomyService analytics reasons
local REFUND_REASON = "refund"
local MIN_FLAT = 1e-3 -- a direction shorter than this across the ground has no usable heading
local LOG = "[HitchService]"

-- What players read (TrailerAction and BuyLicense replies).
local MESSAGES: { [string]: string } = {
	notDriving = "Get in the driver's seat of your own truck first.",
	busy = "Hold on, still working on your last request.",
	noHitch = "This car has no hitch. Couple trailers with a semi, and tow cars with a pickup or tow truck.",
	nothingNear = "Nothing to couple here. Back your hitch up to a trailer or a broken-down car.",
	wrongTarget = "Your truck can't pull that: semis haul trailers, pickups and tow trucks tow cars.",
	taken = "That one is already hitched to someone.",
	notYours = "That load belongs to someone else's job.",
	tooFar = "Back up a little closer: the hitch has to line up.",
	notStill = "Stop completely first.",
	lineUp = "Line up straighter behind it.",
	apart = "Stop with the load straight behind you first.",
	alreadyCoupled = "You're already towing something.",
	coupledTrailer = "Trailer coupled. Drive gently with it.",
	coupledTowed = "Car hooked up. Drive gently with it.",
	notCoupled = "Nothing is coupled.",
	notHere = "You can only uncouple at a freight depot or the County Tow Yard.",
	decoupled = "Uncoupled.",
	-- Licenses: %s is the license's name; then the level and the job names, or the price.
	unknownLicense = "That license doesn't exist.",
	notLoaded = "Your save is still loading. Try again in a moment.",
	owned = "You already hold the %s.",
	needXp = "The %s needs job level %d in %s first.",
	cantAfford = "The %s costs %s.",
	bought = "You now hold the %s.",
	failed = "That didn't go through. You haven't been charged.",
	broken = "Something went wrong. Try again.",
	jobJoin = " or ", -- between job names in needXp
}

---------------------------------------------------------------------------------------------------------------
-- Types
---------------------------------------------------------------------------------------------------------------

-- What a tractor pulls: a trailer (semi) or a towed car (pickup, tow truck).
export type Kind = "trailer" | "towed"
export type Sample = { time: number, position: Vector3 }
export type Reply = { ok: boolean, message: string }

-- Inputs of the couple decision (all as the server sees them).
export type CoupleFacts = {
	role: Kind?, -- what the tractor can pull (roleFor), nil: nothing
	kind: Kind?, -- what the target is, nil: not something to couple
	towing: boolean, -- the tractor already pulls something
	taken: boolean, -- the target is already coupled to someone
	foreign: boolean, -- the target belongs to another player's job
	distance: number, -- studs between the hitch points
	coupleDistance: number,
	angle: number, -- degrees between the tractor's and the target's headings (Vehicle/Trailer.articulation)
	maxAngle: number, -- Config/Trailers.coupleMaxAngle
	speed: number?, -- the faster of the two smoothed speeds (studs/s); nil: not measured yet
	maxSpeed: number, -- Config/Trailers.coupleMaxSpeed
}
export type CoupleVerdict =
	"ok"
	| "noHitch"
	| "nothingNear"
	| "wrongTarget"
	| "alreadyCoupled"
	| "taken"
	| "notYours"
	| "tooFar"
	| "lineUp"
	| "notStill"

export type DecoupleFacts = {
	coupled: boolean,
	together: boolean, -- the load's hitch point is still within coupleDistance of the tractor's hitch
	inside: boolean, -- the tractor's hitch stands at a drop
	speed: number?, -- the tractor's smoothed speed (studs/s); nil: not measured yet
	maxSpeed: number, -- Config/Trailers.decoupleMaxSpeed
}
export type DecoupleVerdict = "ok" | "notCoupled" | "apart" | "notHere" | "notStill"
export type LicenseVerdict = "ok" | "owned" | "needXp"

-- One coupling, keyed by its tractor.
type Coupling = {
	player: Player,
	tractor: Model,
	tractorChassis: BasePart,
	target: Model,
	targetChassis: BasePart,
	kind: Kind,
	joint: BallSocketConstraint,
	point: Attachment, -- the target's Kingpin or TowPoint (the joint's Attachment1)
	noCollide: NoCollisionConstraint,
	value: ObjectValue,
	relative: CFrame, -- the target's pivot in the tractor chassis's space when they coupled
	connections: { RBXScriptConnection },
	moveSerial: number, -- bumped by every server move, so only the latest hands the target back
}

-- A drop: a JobDepot (freight or towing), a TowDrop or a TrailerSpawn footprint, turned to its yaw. `site` is
-- the place it belongs to (HitchService.dropSite).
type Drop = { id: string, site: string, frame: CFrame, size: Vector3 }

-- A TrailerSpawn spot and the idle trailer on it.
type Spot = {
	location: MapLayout.Location,
	model: Model?, -- the trailer that belongs here (idle on it, or hitched away), nil while restocking
	taken: boolean, -- a job took it (takeTrailer): the spot restocks when it leaves the world
	connection: RBXScriptConnection?, -- its AncestryChanged watch
}

local HitchService = {}

local DataService: DataServiceModule? = nil
local couplings: { [Model]: Coupling } = {} -- by tractor
local byTarget: { [Model]: Coupling } = {}
local pending: { [Model]: boolean } = {} -- tractors and targets in a couple call that is still sampling
local busy: { [Player]: boolean } = {} -- one TrailerAction or BuyLicense at a time per player
local spots: { [string]: Spot } = {}
local listeners: { (player: Player, tractor: Model, target: Model, coupled: boolean) -> () } = {}
local drops: { Drop } = {}
local sites: { [string]: string }? = nil -- drop location id -> its site (siteOf), built on first use
-- Where each load was last uncoupled at a drop (its site), until it is coupled again. Weak keys.
local dropped: { [Model]: string } = setmetatable({}, { __mode = "k" }) :: any
-- Trailers let go away from their spot (no longer any spot's): their pending despawn, or false while hitched.
local strays: { [Model]: thread | false } = setmetatable({}, { __mode = "k" }) :: any
local templatesWarned = false

---------------------------------------------------------------------------------------------------------------
-- Pure helpers (tests/Hitch.spec)
---------------------------------------------------------------------------------------------------------------

HitchService.HITCH = HITCH
HitchService.MESSAGES = MESSAGES

-- What a tractor of class `classId` can pull: trailers when it is a Config/Jobs freight class with a Kingpin, cars
-- when it is a towing class with a TowHitch, else nil. A class in both lists prefers trailers when it has a
-- kingpin.
function HitchService.roleFor(classId: string?, hasKingpin: boolean, hasTowHitch: boolean): Kind?
	if classId == nil then
		return nil
	end
	local freight, towing = Jobs.types.freight, Jobs.types.towing
	if hasKingpin and freight ~= nil and table.find(freight.classes, classId) ~= nil then
		return "trailer"
	elseif hasTowHitch and towing ~= nil and table.find(towing.classes, classId) ~= nil then
		return "towed"
	end
	return nil
end

-- Whether a tractor may couple a target, in the order a player fixes things: the right truck, the right load,
-- free to take, close enough, lined up, then still.
function HitchService.coupleDecision(facts: CoupleFacts): CoupleVerdict
	if facts.role == nil then
		return "noHitch"
	elseif facts.towing then
		return "alreadyCoupled"
	elseif facts.kind == nil then
		return "nothingNear"
	elseif facts.kind ~= facts.role then
		return "wrongTarget"
	elseif facts.taken then
		return "taken"
	elseif facts.foreign then
		return "notYours"
	elseif not (facts.distance <= facts.coupleDistance) then
		return "tooFar"
	elseif not (facts.angle <= facts.maxAngle) then
		return "lineUp"
	elseif facts.speed == nil or facts.speed > facts.maxSpeed then
		return "notStill"
	end
	return "ok"
end

-- Whether a tractor may let go of what it pulls: only coupled, the load still on the hitch, the tractor's hitch
-- inside a drop footprint, and still.
function HitchService.decoupleDecision(facts: DecoupleFacts): DecoupleVerdict
	if not facts.coupled then
		return "notCoupled"
	elseif not facts.together then
		return "apart"
	elseif not facts.inside then
		return "notHere"
	elseif facts.speed == nil or facts.speed > facts.maxSpeed then
		return "notStill"
	end
	return "ok"
end

-- Whether a player with these XP totals and licenses may buy `license`: "owned" when they hold it already (no
-- charge), "needXp" until they have xpRequired XP in one of its job types.
function HitchService.licenseDecision(
	xp: { [string]: number },
	licenses: { [string]: boolean },
	license: Jobs.License
): LicenseVerdict
	if licenses[license.id] == true then
		return "owned"
	end
	for _, jobType in license.jobTypes do
		local earned = xp[jobType]
		if type(earned) == "number" and earned >= license.xpRequired then
			return "ok"
		end
	end
	return "needXp"
end

-- True when `point` lies over the footprint of a box at `frame` with `size` (its own X and Z, so a footprint
-- turned to its yaw matches its painted bay), grown by `margin` studs on every side. Height doesn't matter.
function HitchService.insideFootprint(frame: CFrame, size: Vector3, point: Vector3, margin: number): boolean
	local offset = frame:PointToObjectSpace(point)
	return math.abs(offset.X) <= size.X / 2 + margin and math.abs(offset.Z) <= size.Z / 2 + margin
end

-- True when `point` is at a drop: over its footprint (insideFootprint, no margin) or within `radius` studs of its
-- centre across the ground (Config/Trailers.decoupleRadius: a small spot still has room round it).
function HitchService.atDrop(frame: CFrame, size: Vector3, point: Vector3, radius: number): boolean
	if HitchService.insideFootprint(frame, size, point, 0) then
		return true
	end
	local offset = point - frame.Position
	return Vector3.new(offset.X, 0, offset.Z).Magnitude <= radius
end

-- The site a drop location belongs to, which is what a job's decouple stop is judged by: a TrailerSpawn's
-- depot, a TowDrop's yard (their attributes), else the location's own id (a depot).
function HitchService.dropSite(location: MapLayout.Location): string
	local attributes: { [string]: any } = location.attributes or {}
	if location.tag == SPOT_TAG and type(attributes.depot) == "string" then
		return attributes.depot
	elseif location.tag == TOW_DROP_TAG and type(attributes.yard) == "string" then
		return attributes.yard
	end
	return location.id
end

-- Ground speed (studs/s) from position samples over a short window, robust to the wobble the server sees on a
-- car a client simulates: the mean position of the later half against the mean of the earlier half, over the
-- time between their mean times. nil with fewer than two samples or no time between the halves.
function HitchService.smoothedSpeed(samples: { Sample }): number?
	local count = #samples
	if count < 2 then
		return nil
	end
	local half = count // 2
	local function mean(first: number, last: number): (Vector3, number)
		local position, time = Vector3.zero, 0
		for i = first, last do
			position += samples[i].position
			time += samples[i].time
		end
		local n = last - first + 1
		return position / n, time / n
	end
	local earlyPosition, earlyTime = mean(1, half)
	local latePosition, lateTime = mean(count - half + 1, count)
	local seconds = lateTime - earlyTime
	if seconds <= 0 then
		return nil
	end
	local delta = latePosition - earlyPosition
	return Vector3.new(delta.X, 0, delta.Z).Magnitude / seconds
end

-- Where an idle trailer stands on a TrailerSpawn spot: its pivot on the spot's surface, its nose toward the
-- spot's +X (the spot faces its road, so that is the way traffic flows past it), so a semi pulls in ahead of it
-- along the road and backs straight onto it.
function HitchService.spotPose(position: Vector3, yaw: number): CFrame
	return CFrame.new(position) * CFrame.Angles(0, math.rad(yaw), 0) * CFrame.Angles(0, -math.pi / 2, 0)
end

-- The level turn of `frame`: a rotation about the vertical only, facing the way `frame` faces across the
-- ground (north when it faces straight up or down).
function HitchService.heading(frame: CFrame): CFrame
	local look = frame.LookVector
	if Vector3.new(look.X, 0, look.Z).Magnitude < MIN_FLAT then
		return CFrame.identity
	end
	-- CFrame.Angles(0, a, 0) faces (-sin a, 0, -cos a).
	return CFrame.Angles(0, math.atan2(-look.X, -look.Z), 0)
end

-- The pose of a towed car whose tow point meets `hitch`: turned as it stands now, its nose lifted about its
-- rear axle until the tow point reaches the hitch's height (at most `maxLift` degrees), its rear wheels staying
-- on the ground it stands on, then slid across the ground so the tow point is under (or on) the hitch.
-- `pivot` is the car's pivot (the ground under its chassis, facing forward); `towPoint` and `rearContact` (the
-- ground under its rear axle) are in pivot space.
function HitchService.towPose(
	pivot: CFrame,
	towPoint: Vector3,
	rearContact: Vector3,
	hitch: Vector3,
	maxLift: number
): CFrame
	-- The car's heading only (level), so the lift is straight up whatever slope it stood on.
	local yaw = HitchService.heading(pivot)
	local v = towPoint - rearContact -- from the rear contact to the tow point, in the car's own axes
	local lift = hitch.Y - (pivot * rearContact).Y -- how high above the rear contact the tow point must be
	-- Tipping the nose up by theta (a rotation about X): height = vy cos(theta) - vz sin(theta), with vz < 0
	-- (the tow point is ahead), i.e. A cos(theta) + B sin(theta) with A = vy, B = -vz.
	local a, b = v.Y, -v.Z
	local reach = math.sqrt(a * a + b * b)
	local limit = math.rad(maxLift)
	local theta = 0
	if reach > 0 then
		local phi = math.atan2(b, a)
		theta = phi - math.acos(math.clamp(lift / reach, -1, 1))
	end
	theta = math.clamp(theta, -limit, limit)
	local tilt = CFrame.Angles(theta, 0, 0)
	local tipped = tilt * v -- the tow point from the rear contact once tipped, in yaw axes
	-- Put the rear contact where the tipped tow point lands on the hitch across the ground, at its own height.
	local rearWorld = hitch - yaw * Vector3.new(tipped.X, 0, tipped.Z)
	rearWorld = Vector3.new(rearWorld.X, (pivot * rearContact).Y, rearWorld.Z)
	return CFrame.new(rearWorld) * yaw * tilt * CFrame.new(-rearContact)
end

---------------------------------------------------------------------------------------------------------------
-- Model helpers
---------------------------------------------------------------------------------------------------------------

local function chassisOf(model: Model): BasePart?
	local chassis = model:FindFirstChild(CHASSIS)
	return if chassis ~= nil and chassis:IsA("BasePart") then chassis else nil
end

local function attachmentOf(model: Model, name: string): Attachment?
	local chassis = chassisOf(model)
	local found = if chassis then chassis:FindFirstChild(name) else nil
	return if found ~= nil and found:IsA("Attachment") then found else nil
end

-- The player's living humanoid, or nil.
local function humanoidOf(player: Player): Humanoid?
	local character = player.Character
	local humanoid = if character then character:FindFirstChildOfClass("Humanoid") else nil
	return if humanoid ~= nil and humanoid.Health > 0 then humanoid else nil
end

-- The player's own car when they sit in its Driver seat, else nil.
local function drivenCar(player: Player): Model?
	local car = VehicleService.getCar(player)
	local humanoid = humanoidOf(player)
	if car == nil or humanoid == nil then
		return nil
	end
	local seats = car:FindFirstChild(SEATS_FOLDER)
	local seat = if seats then seats:FindFirstChild(DRIVER_SEAT) else nil
	if seat == nil or not seat:IsA("Seat") or seat.Occupant ~= humanoid then
		return nil
	end
	return car
end

-- What a tractor can pull, and its hitch attachment.
local function tractorRole(tractor: Model): (Kind?, Attachment?)
	local vehicleId = tractor:GetAttribute(VEHICLE_ID)
	local vehicle = if type(vehicleId) == "string" then Catalog.getVehicle(vehicleId) else nil
	local kingpin, towHitch = attachmentOf(tractor, KINGPIN), attachmentOf(tractor, TOW_HITCH)
	local role = HitchService.roleFor(if vehicle then vehicle.class else nil, kingpin ~= nil, towHitch ~= nil)
	if role == "trailer" then
		return role, kingpin
	elseif role == "towed" then
		return role, towHitch
	end
	return nil, nil
end

-- The tractor's catalog top speed (studs/s): the pair's too (Vehicle/Trailer brakes a trailer that would push
-- past it), or nil for a model that names no catalog trim.
local function topSpeedOf(tractor: Model): number?
	local vehicleId, trimId = tractor:GetAttribute(VEHICLE_ID), tractor:GetAttribute(TRIM)
	local trim = if type(vehicleId) == "string" and type(trimId) == "string"
		then Catalog.getTrim(vehicleId, trimId)
		else nil
	return if trim then Units.mphToStuds(trim.topSpeedMph) else nil
end

-- What a model is to the hitch, and its hitch point: a trailer (Config/Trailers' tag or TrailerId attribute,
-- and a Kingpin) or a towed car (Towed = true and a TowPoint).
local function targetKind(model: Model): (Kind?, Attachment?)
	if model:GetAttribute(Trailers.towedAttribute) == true then
		local point = attachmentOf(model, TOW_POINT)
		if point ~= nil then
			return "towed", point
		end
	elseif model:HasTag(Trailers.tag) or model:GetAttribute(Trailers.idAttribute) ~= nil then
		local point = attachmentOf(model, KINGPIN)
		if point ~= nil then
			return "trailer", point
		end
	end
	return nil, nil
end

-- True when the target was put out by a job for someone other than `player`.
local function foreignTo(target: Model, player: Player): boolean
	local owner = target:GetAttribute(PROPS.ownerAttribute)
	return owner ~= nil and owner ~= player.UserId
end

-- Network ownership only applies to unanchored parts (anchored ones always belong to the server).
local function setOwner(part: BasePart, owner: Player?)
	if part.Anchored then
		return
	end
	local allowed, why = part:CanSetNetworkOwnership()
	if allowed then
		part:SetNetworkOwner(owner)
	else
		warn(`{LOG} Can't hand {part:GetFullName()} to {if owner then owner.Name else "the server"}: {why}`)
	end
end

local function stopMotion(part: BasePart)
	part.AssemblyLinearVelocity = Vector3.zero
	part.AssemblyAngularVelocity = Vector3.zero
end

-- Hands a part back to the server and anchors it where it is.
local function anchorHere(part: BasePart)
	if not part.Anchored then
		setOwner(part, nil)
		stopMotion(part)
		part.Anchored = true
	end
end

-- Ignore these models and every character; only land on solid ground (as VehicleService parks).
local function groundParams(ignore: { Instance }): RaycastParams
	local list = table.clone(ignore)
	for _, other in Players:GetPlayers() do
		if other.Character ~= nil then
			table.insert(list, other.Character)
		end
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = list
	params.RespectCanCollide = true
	return params
end

-- The ground under `position`, or nil.
local function groundBelow(position: Vector3, ignore: { Instance }): Vector3?
	local park = Spawning.park
	local origin = position + Vector3.yAxis * park.probeUp
	local hit = Workspace:Raycast(origin, Vector3.yAxis * -(park.probeUp + park.probeDown), groundParams(ignore))
	return if hit then hit.Position else nil
end

-- A pose at `position` keeping only the heading of `from` (level).
local function levelPose(position: Vector3, from: CFrame): CFrame
	return CFrame.new(position) * HitchService.heading(from)
end

-- The ground under a car's rear axle, in its pivot space (between the rear hubs, at the pivot's height).
local function rearContactOf(model: Model): Vector3
	local pivot = model:GetPivot()
	local sum, count = Vector3.zero, 0
	for _, name in REAR_WHEELS do
		local hub = attachmentOf(model, name)
		if hub ~= nil then
			sum += pivot:PointToObjectSpace(hub.WorldPosition)
			count += 1
		end
	end
	local hub = if count > 0 then sum / count else Vector3.zero
	return Vector3.new(0, 0, hub.Z)
end

-- Smoothed ground speeds of `models` over HITCH.stillWindow seconds of Heartbeat samples (one per model, nil
-- for one that left the world meanwhile). Yields for the window.
local function sampleSpeeds(models: { Model }): { number? }
	local samples: { { Sample } } = {}
	for i in models do
		samples[i] = {}
	end
	local started = os.clock()
	repeat
		local now = os.clock()
		for i, model in models do
			if model.Parent ~= nil then
				table.insert(samples[i], { time = now, position = model:GetPivot().Position })
			end
		end
		RunService.Heartbeat:Wait()
	until os.clock() - started >= HITCH.stillWindow
	local speeds: { number? } = {}
	for i, model in models do
		speeds[i] = if model.Parent ~= nil then HitchService.smoothedSpeed(samples[i]) else nil
	end
	return speeds
end

local function fastest(speeds: { number? }, count: number): number?
	local top = 0
	for i = 1, count do
		local speed = speeds[i]
		if speed == nil then
			return nil
		end
		top = math.max(top, speed)
	end
	return top
end

---------------------------------------------------------------------------------------------------------------
-- Drops
---------------------------------------------------------------------------------------------------------------

local function loadDrops()
	drops = {}
	for _, location in MapLayout.locations do
		local attributes: { [string]: any } = location.attributes or {}
		local isDepot = location.tag == DEPOT_TAG and DROP_JOB_TYPES[attributes.jobType] == true
		if isDepot or DROP_TAGS[location.tag] then
			table.insert(drops, {
				id = location.id,
				site = HitchService.dropSite(location),
				frame = CFrame.new(location.position) * CFrame.Angles(0, math.rad(location.yaw), 0),
				size = location.size,
			})
		end
	end
end

-- The drop any of `points` stands at, or nil.
local function dropAt(points: { Vector3 }): Drop?
	for _, drop in drops do
		for _, point in points do
			if HitchService.atDrop(drop.frame, drop.size, point, HITCH.decoupleRadius) then
				return drop
			end
		end
	end
	return nil
end

---------------------------------------------------------------------------------------------------------------
-- Idle trailers
---------------------------------------------------------------------------------------------------------------

local function trailersFolder(): Folder
	local existing = Workspace:FindFirstChild(TRAILERS_FOLDER)
	if existing ~= nil and existing:IsA("Folder") then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = TRAILERS_FOLDER
	folder.Parent = Workspace
	return folder
end

local function trailerTemplate(name: string): Model?
	local folder = ServerStorage:FindFirstChild(Trailers.modelsFolder)
	local template = if folder then folder:FindFirstChild(name) else nil
	if template ~= nil and template:IsA("Model") and chassisOf(template) ~= nil then
		return template
	end
	if not templatesWarned then
		templatesWarned = true
		warn(
			`{LOG} No trailer model "{name}" in ServerStorage.{Trailers.modelsFolder}: depots stay empty. In Studio's Edit mode, run require(game.ServerScriptService.Server.Dev.TrailerBuilder).buildAll()`
		)
	end
	return nil
end

local stock: (spot: Spot) -> ()

-- Puts a fresh idle trailer on a spot (anchored; only its chassis, which holds the rest by welds).
stock = function(spot: Spot)
	local location = spot.location
	local attributes: { [string]: any } = location.attributes or {}
	local template = if type(attributes.trailer) == "string" then trailerTemplate(attributes.trailer) else nil
	if template == nil then
		return
	end
	local model = template:Clone()
	local chassis = chassisOf(model) :: BasePart
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Anchored = false
		end
	end
	chassis.Anchored = true
	model:SetAttribute(SPOT_ATTRIBUTE, location.id)
	-- Stand it on the spot, then rest its lowest point (its wheels and legs) on the spot's surface.
	local pose = HitchService.spotPose(location.position, location.yaw)
	model:PivotTo(pose)
	local box, boxSize = model:GetBoundingBox()
	model:PivotTo(pose + Vector3.yAxis * (location.position.Y - (box.Position.Y - boxSize.Y / 2)))
	model.Parent = trailersFolder()
	spot.model = model
	spot.taken = false
	-- A trailer that leaves the world (a job despawned it, something destroyed it) is replaced.
	spot.connection = model.AncestryChanged:Connect(function()
		if model:IsDescendantOf(Workspace) or spot.model ~= model then
			return
		end
		local connection = spot.connection
		spot.connection = nil
		if connection then
			connection:Disconnect()
		end
		spot.model = nil
		stock(spot)
	end)
end

-- A stray trailer goes after Config/Jobs props.despawnDelaySec unless it is hitched again first.
local function despawnStray(target: Model)
	local despawning = strays[target]
	if despawning then
		task.cancel(despawning)
	end
	strays[target] = task.delay(PROPS.despawnDelaySec, function()
		strays[target] = nil
		if byTarget[target] == nil and target.Parent ~= nil then
			target:Destroy()
		end
	end)
end

-- After a trailer was let go: a spot's own trailer back on its spot simply waits there again. Anywhere else it
-- stops being the spot's at once (the spot gets a fresh one, so idleTrailer never names a trailer standing
-- elsewhere and no job's despawn can reach the spot's next trailer) and becomes a stray, which goes after
-- Config/Jobs props.despawnDelaySec unless it is hitched again first. A trailer a job took is the job's to remove.
local function afterRelease(target: Model)
	local spotId = target:GetAttribute(SPOT_ATTRIBUTE)
	local spot = if type(spotId) == "string" then spots[spotId] else nil
	if spot ~= nil and spot.model == target and not spot.taken then
		local location = spot.location
		local home = CFrame.new(location.position) * CFrame.Angles(0, math.rad(location.yaw), 0)
		if HitchService.insideFootprint(home, location.size, target:GetPivot().Position, 0) then
			return
		end
		local connection = spot.connection
		spot.connection = nil
		if connection then
			connection:Disconnect()
		end
		spot.model = nil
		target:SetAttribute(SPOT_ATTRIBUTE, nil)
		strays[target] = false
		stock(spot)
	end
	if strays[target] ~= nil then
		despawnStray(target)
	end
end

---------------------------------------------------------------------------------------------------------------
-- Coupling
---------------------------------------------------------------------------------------------------------------

local function notify(coupling: Coupling, coupled: boolean)
	for _, listener in listeners do
		task.spawn(listener, coupling.player, coupling.tractor, coupling.target, coupled)
	end
end

-- Ends a coupling. `how`: "drop" (decoupled at a drop: the target is parked there), "release" (a job let it go:
-- anchored where it is), "lost" (the tractor or target left the world).
local function finish(coupling: Coupling, how: "drop" | "release" | "lost")
	local tractor, target = coupling.tractor, coupling.target
	if couplings[tractor] ~= coupling then
		return
	end
	couplings[tractor] = nil
	byTarget[target] = nil
	for _, connection in coupling.connections do
		connection:Disconnect()
	end
	coupling.joint:Destroy()
	coupling.noCollide:Destroy()
	coupling.value:Destroy()
	if tractor:GetAttribute(Trailers.towingAttribute) == target.Name then
		tractor:SetAttribute(Trailers.towingAttribute, nil)
	end
	AntiExploitService.setSpeedCap(tractor, CAP_KEY, nil)

	local chassis = coupling.targetChassis
	if target.Parent ~= nil and chassis.Parent ~= nil then
		anchorHere(chassis)
		if how == "drop" and coupling.kind == "towed" then
			-- Set the car back down level on the ground under it (its nose was up on the hitch).
			local pivot = target:GetPivot()
			local ground = groundBelow(pivot.Position, { target, tractor })
			if ground ~= nil then
				target:PivotTo(levelPose(ground, pivot))
			end
		end
		afterRelease(target)
	end
	notify(coupling, false)
end

-- Brings the target back onto the hitch where the tractor is now (after a server move of the tractor, or a park
-- that found them apart), straight behind it as when they coupled.
local function bringAlong(coupling: Coupling)
	local chassis = coupling.targetChassis
	setOwner(chassis, nil)
	coupling.target:PivotTo(coupling.tractorChassis.CFrame * coupling.relative)
	stopMotion(chassis)
end

-- The tractor's chassis anchored (parked) or unanchored (driven again): the target follows.
local function onTractorAnchored(coupling: Coupling)
	local chassis = coupling.targetChassis
	if coupling.tractorChassis.Anchored then
		local hitch = coupling.joint.Attachment0
		local gap = if hitch then (hitch.WorldPosition - coupling.point.WorldPosition).Magnitude else 0
		if gap > HITCH.coupleDistance then
			bringAlong(coupling)
		end
		anchorHere(chassis)
	elseif chassis.Anchored then
		chassis.Anchored = false
		setOwner(chassis, coupling.player)
	end
end

-- The server moved the tractor (a reset): bring the target along, and give it back to the driver when the
-- tractor goes back to them (Config/AntiExploit.resetOwnershipDelay).
local function onServerMove(model: Model)
	local coupling = couplings[model]
	if coupling == nil or coupling.targetChassis.Anchored then
		return
	end
	coupling.moveSerial += 1
	local serial = coupling.moveSerial
	bringAlong(coupling)
	task.delay(AntiExploit.resetOwnershipDelay, function()
		if couplings[model] == coupling and coupling.moveSerial == serial and not coupling.tractorChassis.Anchored then
			setOwner(coupling.targetChassis, coupling.player)
		end
	end)
end

-- Joins `target` to `tractor` (every check passed). Returns the coupling.
local function attach(player: Player, tractor: Model, target: Model, kind: Kind, hitch: Attachment, point: Attachment)
	local tractorChassis = chassisOf(tractor) :: BasePart
	local targetChassis = chassisOf(target) :: BasePart

	-- Set the target exactly on the hitch, while it is still anchored and the server's.
	if kind == "trailer" then
		target:PivotTo(target:GetPivot() + (hitch.WorldPosition - point.WorldPosition))
	else
		local pivot = target:GetPivot()
		target:PivotTo(
			HitchService.towPose(
				pivot,
				pivot:PointToObjectSpace(point.WorldPosition),
				rearContactOf(target),
				hitch.WorldPosition,
				HITCH.maxTowLift
			)
		)
	end

	-- The joint. Both attachments face the same way when the rig is in line (Config/Trailers' header), so it
	-- rests straight; a lifted towed car rests a few degrees into its twist range.
	local joint = Instance.new("BallSocketConstraint")
	joint.Name = JOINT_NAME
	joint.Attachment0 = hitch
	joint.Attachment1 = point
	Trailer.configureHitch(joint, Trailer.hitchSettingsFor(target))
	joint.Parent = tractorChassis

	local noCollide = Instance.new("NoCollisionConstraint")
	noCollide.Name = NO_COLLIDE_NAME
	noCollide.Part0 = tractorChassis
	noCollide.Part1 = targetChassis
	noCollide.Parent = tractorChassis

	local value = Instance.new("ObjectValue")
	value.Name = Trailers.towingValue
	value.Value = target

	local coupling: Coupling = {
		player = player,
		tractor = tractor,
		tractorChassis = tractorChassis,
		target = target,
		targetChassis = targetChassis,
		kind = kind,
		joint = joint,
		point = point,
		noCollide = noCollide,
		value = value,
		relative = tractorChassis.CFrame:ToObjectSpace(target:GetPivot()),
		connections = {},
		moveSerial = 0,
	}
	couplings[tractor] = coupling
	byTarget[target] = coupling

	-- Hand the target to the driver with the tractor, then mark the tractor for the clients.
	targetChassis.Anchored = false
	if not tractorChassis.Anchored then
		setOwner(targetChassis, player)
	end
	value.Parent = tractor
	tractor:SetAttribute(Trailers.towingAttribute, target.Name)
	AntiExploitService.setSpeedCap(tractor, CAP_KEY, topSpeedOf(tractor))

	-- A stray hitched again stays until it is let go again; where it was last dropped no longer counts.
	local despawning = strays[target]
	if despawning then
		task.cancel(despawning)
		strays[target] = false
	end
	dropped[target] = nil

	local connections = coupling.connections
	table.insert(
		connections,
		tractorChassis:GetPropertyChangedSignal("Anchored"):Connect(function()
			onTractorAnchored(coupling)
		end)
	)
	for _, part in { tractorChassis, targetChassis } do
		table.insert(
			connections,
			part.AncestryChanged:Connect(function()
				if not part:IsDescendantOf(Workspace) then
					finish(coupling, "lost")
				end
			end)
		)
	end
	notify(coupling, true)
	return coupling
end

-- The best thing near the tractor's hitch to couple: the nearest one it can pull, else the nearest of anything
-- (so the refusal can say what is wrong). Returns it, its kind and its hitch point.
local function nearestTarget(tractor: Model, hitch: Attachment, role: Kind?): (Model?, Kind?, Attachment?)
	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { tractor }
	local origin = hitch.WorldPosition
	local best: Model?, bestKind: Kind?, bestPoint: Attachment? = nil, nil, nil
	local bestScore = math.huge
	local radius = HITCH.coupleDistance * HITCH.searchFactor
	for _, part in Workspace:GetPartBoundsInRadius(origin, radius, params) do
		local model = part.Parent
		if part.Name ~= CHASSIS or model == nil or not model:IsA("Model") then
			continue
		end
		local kind: Kind?, point = targetKind(model)
		if kind == nil or point == nil then
			continue
		end
		-- Anything this tractor can pull ranks ahead of anything it can't.
		local score = (point.WorldPosition - origin).Magnitude + (if kind == role then 0 else radius)
		if score < bestScore then
			best, bestKind, bestPoint, bestScore = model, kind, point, score
		end
	end
	return best, bestKind, bestPoint
end

---------------------------------------------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------------------------------------------

-- Couples `target` to `tractor` for `player` (see the header). Yields for the stillness check. Returns whether
-- it coupled and what to tell the player.
function HitchService.couple(player: Player, tractor: Model, target: Model): (boolean, string)
	local function check(speed: number?): (CoupleVerdict, Kind?, Attachment?, Attachment?)
		if drivenCar(player) ~= tractor then
			return "noHitch", nil, nil, nil
		end
		local role: Kind?, hitch = tractorRole(tractor)
		local kind: Kind?, point = targetKind(target)
		local tractorChassis, targetChassis = chassisOf(tractor), chassisOf(target)
		local angle = if tractorChassis and targetChassis
			then math.deg(Trailer.articulation(tractorChassis.CFrame, targetChassis.CFrame))
			else math.huge
		local verdict: CoupleVerdict = HitchService.coupleDecision({
			role = role,
			kind = if target ~= tractor and target.Parent ~= nil then kind else nil,
			towing = couplings[tractor] ~= nil,
			taken = byTarget[target] ~= nil or pending[target] == true,
			foreign = foreignTo(target, player),
			distance = if hitch and point then (hitch.WorldPosition - point.WorldPosition).Magnitude else math.huge,
			coupleDistance = HITCH.coupleDistance,
			angle = angle,
			maxAngle = HITCH.coupleMaxAngle,
			speed = speed,
			maxSpeed = HITCH.coupleMaxSpeed,
		})
		return verdict, kind, hitch, point
	end

	if drivenCar(player) ~= tractor then
		return false, MESSAGES.notDriving
	end
	-- Everything but stillness first, so a wrong request answers at once.
	local verdict = check(0)
	if verdict ~= "ok" then
		return false, MESSAGES[verdict]
	end
	if pending[tractor] or pending[target] then
		return false, MESSAGES.busy
	end
	pending[tractor], pending[target] = true, true
	local speeds = sampleSpeeds({ tractor, target })
	pending[tractor], pending[target] = nil, nil

	-- Everything again: they may have driven off, got out or been taken meanwhile.
	if drivenCar(player) ~= tractor then
		return false, MESSAGES.notDriving
	end
	local final: CoupleVerdict, kind: Kind?, hitch, point = check(fastest(speeds, 2))
	if final ~= "ok" or kind == nil or hitch == nil or point == nil then
		return false, MESSAGES[final] or MESSAGES.notStill
	end
	attach(player, tractor, target, kind, hitch, point)
	return true, if kind == "trailer" then MESSAGES.coupledTrailer else MESSAGES.coupledTowed
end

-- Uncouples what `tractor` pulls for `player`, only with the tractor's hitch inside a drop footprint (see the
-- header). Yields for the stillness check. Outside one nothing changes. Returns whether it uncoupled and what to
-- tell the player.
function HitchService.decouple(player: Player, tractor: Model): (boolean, string)
	-- Judged on the tractor's hitch (the joint's Attachment0 rides on the chassis AntiExploitService tracks),
	-- never on the load, whose position the driver's client reports.
	local function check(speed: number?): (DecoupleVerdict, Drop?)
		local coupling = couplings[tractor]
		local hitch = if coupling then coupling.joint.Attachment0 else nil
		local drop: Drop? = nil
		local together = false
		if coupling ~= nil and hitch ~= nil then
			drop = dropAt({ hitch.WorldPosition })
			local gap = (hitch.WorldPosition - coupling.point.WorldPosition).Magnitude
			together = gap <= HITCH.coupleDistance
		end
		local verdict = HitchService.decoupleDecision({
			coupled = coupling ~= nil and coupling.player == player,
			together = together,
			inside = drop ~= nil,
			speed = speed,
			maxSpeed = HITCH.decoupleMaxSpeed,
		})
		return verdict, drop
	end

	if drivenCar(player) ~= tractor then
		return false, MESSAGES.notDriving
	end
	local verdict = check(0)
	if verdict == "apart" then
		warn(`{LOG} Refused an uncouple from {player.Name} ({player.UserId}): the load is off the tractor's hitch`)
	end
	if verdict ~= "ok" then
		return false, MESSAGES[verdict]
	end
	local speeds = sampleSpeeds({ tractor })
	if drivenCar(player) ~= tractor then
		return false, MESSAGES.notDriving
	end
	local final, drop = check(speeds[1])
	local coupling = couplings[tractor]
	if final ~= "ok" or coupling == nil or drop == nil then
		return false, MESSAGES[final]
	end
	dropped[coupling.target] = drop.site
	finish(coupling, "drop")
	return true, MESSAGES.decoupled
end

-- Undoes a coupling anywhere, given its tractor or its target (jobs ending, tests). The target is anchored where
-- it stands. True when there was one.
function HitchService.release(model: Model): boolean
	local coupling = couplings[model] or byTarget[model]
	if coupling == nil then
		return false
	end
	finish(coupling, "release")
	return true
end

-- The site (HitchService.dropSite) of the drop where `target` was last uncoupled with decouple, or nil when it
-- has not been since it was last coupled (or was let go anywhere else).
function HitchService.droppedAt(target: Model): string?
	return dropped[target]
end

-- The site (HitchService.dropSite) MapLayout location `locationId` belongs to as a drop, or nil when it is no
-- drop (a JobDepot with jobType freight or towing, a TowDrop or a TrailerSpawn).
function HitchService.siteOf(locationId: string?): string?
	if locationId == nil then
		return nil
	end
	local known = sites
	if known == nil then
		local built: { [string]: string } = {}
		for _, location in MapLayout.locations do
			local attributes: { [string]: any } = location.attributes or {}
			local isDepot = location.tag == DEPOT_TAG and DROP_JOB_TYPES[attributes.jobType] == true
			if isDepot or DROP_TAGS[location.tag] then
				built[location.id] = HitchService.dropSite(location)
			end
		end
		sites = built
		known = built
	end
	return (known :: { [string]: string })[locationId]
end

-- What `tractor` pulls, or nil.
function HitchService.coupledTo(tractor: Model): Model?
	local coupling = couplings[tractor]
	return if coupling then coupling.target else nil
end

-- The tractor pulling `target`, or nil.
function HitchService.tractorOf(target: Model): Model?
	local coupling = byTarget[target]
	return if coupling then coupling.tractor else nil
end

-- Calls `listener(player, tractor, target, coupled)` after every coupling (true) and every uncoupling however it
-- happened (false). Listeners run in their own threads. Returns a function that removes the listener.
function HitchService.onChanged(
	listener: (player: Player, tractor: Model, target: Model, coupled: boolean) -> ()
): () -> ()
	table.insert(listeners, listener)
	return function()
		local index = table.find(listeners, listener)
		if index ~= nil then
			table.remove(listeners, index)
		end
	end
end

-- The idle trailer waiting on TrailerSpawn spot `spotId`, or nil (none built, hitched away, or restocking).
function HitchService.idleTrailer(spotId: string): Model?
	local spot = spots[spotId]
	local model = if spot then spot.model else nil
	if spot == nil or model == nil or spot.taken or byTarget[model] ~= nil then
		return nil
	end
	return model
end

-- Hands a spot's idle trailer to a job: it is no longer despawned or restocked when let go (the job removes it),
-- and the spot gets a fresh trailer once it leaves the world. With `player`, only they may hitch it (Config/Jobs
-- props.ownerAttribute). Returns it, or nil when the spot has no idle trailer.
function HitchService.takeTrailer(spotId: string, player: Player?): Model?
	local model = HitchService.idleTrailer(spotId)
	local spot = spots[spotId]
	if model == nil or spot == nil then
		return nil
	end
	spot.taken = true
	if player ~= nil then
		model:SetAttribute(PROPS.ownerAttribute, player.UserId)
	end
	return model
end

---------------------------------------------------------------------------------------------------------------
-- Remotes
---------------------------------------------------------------------------------------------------------------

local function reply(ok: boolean, message: string): Reply
	return { ok = ok, message = message }
end

local function onTrailerAction(player: Player, payload: any): Reply
	if busy[player] then
		return reply(false, MESSAGES.busy)
	end
	local tractor = drivenCar(player)
	if tractor == nil then
		return reply(false, MESSAGES.notDriving)
	end
	busy[player] = true
	local ok, worked, message = pcall(function(): (boolean, string)
		if payload.action == "decouple" then
			return HitchService.decouple(player, tractor)
		end
		local role: Kind?, hitch = tractorRole(tractor)
		if role == nil or hitch == nil then
			return false, MESSAGES.noHitch
		elseif couplings[tractor] ~= nil then
			return false, MESSAGES.alreadyCoupled
		end
		local target = nearestTarget(tractor, hitch, role)
		if target == nil then
			return false, MESSAGES.nothingNear
		end
		return HitchService.couple(player, tractor, target)
	end)
	busy[player] = nil
	if not ok then
		warn(`{LOG} TrailerAction for {player.Name} failed: {worked}`)
		return reply(false, MESSAGES.broken)
	end
	return reply(worked, message)
end

-- Buys a job license (see the header). Never yields between the checks and the charge.
function HitchService.buyLicense(player: Player, licenseId: string): Reply
	local license: Jobs.License? = Jobs.licenses[licenseId]
	if license == nil then
		return reply(false, MESSAGES.unknownLicense)
	end
	local dataService = DataService
	local data = if dataService then dataService.get(player) else nil
	if dataService == nil or data == nil then
		return reply(false, MESSAGES.notLoaded)
	end
	local verdict = HitchService.licenseDecision(data.jobs.xp, data.jobs.licenses, license)
	if verdict == "owned" then
		return reply(true, string.format(MESSAGES.owned, license.displayName))
	elseif verdict == "needXp" then
		local names: { string } = {}
		for _, jobType in license.jobTypes do
			local def = Jobs.types[jobType]
			table.insert(names, if def then def.displayName else jobType)
		end
		local text = table.concat(names, MESSAGES.jobJoin)
		return reply(false, string.format(MESSAGES.needXp, license.displayName, license.level, text))
	end
	local price = license.price
	if not EconomyService.trySpend(player, price, LICENSE_REASON) then
		return reply(false, string.format(MESSAGES.cantAfford, license.displayName, Economy.formatCash(price)))
	end
	local granted = dataService.update(player, function(fresh)
		fresh.jobs.licenses[license.id] = true
	end)
	if not granted then
		EconomyService.add(player, price, REFUND_REASON)
		return reply(false, MESSAGES.failed)
	end
	return reply(true, string.format(MESSAGES.bought, license.displayName))
end

local function onBuyLicense(player: Player, payload: any): Reply
	if busy[player] then
		return reply(false, MESSAGES.busy)
	end
	busy[player] = true
	local ok, result = pcall(HitchService.buyLicense, player, payload.license)
	busy[player] = nil
	if not ok then
		warn(`{LOG} BuyLicense for {player.Name} failed: {result}`)
		return reply(false, MESSAGES.failed)
	end
	return result
end

---------------------------------------------------------------------------------------------------------------
-- Boot
---------------------------------------------------------------------------------------------------------------

function HitchService:Init()
	DataService = require(script.Parent.DataService) :: any
	loadDrops()
end

function HitchService:Start()
	Net.onServerInvoke("TrailerAction", onTrailerAction)
	Net.onServerInvoke("BuyLicense", onBuyLicense)
	AntiExploitService.onServerMove(onServerMove)
	Players.PlayerRemoving:Connect(function(leaving: Player)
		busy[leaving] = nil
		-- Their car is despawned (VehicleService), which ends any coupling; this catches one it didn't.
		for _, coupling in couplings do
			if coupling.player == leaving then
				finish(coupling, "lost")
			end
		end
	end)
	-- An idle trailer on every TrailerSpawn spot.
	for _, location in MapLayout.locations do
		if location.tag == SPOT_TAG then
			local spot: Spot = { location = location, model = nil, taken = false, connection = nil }
			spots[location.id] = spot
			stock(spot)
		end
	end
end

return HitchService
