--!strict
-- The GPS (docs/phase-2-contracts.md "GPS, spawn flow, notices"; PLAN.md Phase 2).
--
--   setDestination(target)   a MapLayout location id, a point, or nil to clear. Routes right away with
--                            Pathfind.route on this client (the road graph is shared data, so streaming never
--                            hides a destination). Options (Phase 6, for JobController): `name` for the chip in
--                            place of the place's own name ("Pick up at Town Square"), and `keepOnArrival`, which
--                            keeps the route and its marker up on arrival, with no notice, until the caller
--                            changes or clears it (a job stop counts only once the server says so).
--   route line               flat Beams between Attachments in Workspace.GpsRoute, a folder this client makes
--                            (never replicated), floating just above the road, with a marker at the end.
--   tracking                 a few times a second (RunService.Heartbeat with an accumulator, connected only
--                            while a destination is set): find where the player is along the route, trim the
--                            line behind them, update the distance left, re-route when they are off it, and
--                            clear with a notice when they arrive.
--   route chip               UI/GpsPanel in its own ScreenGui: the active route with the distance left and an
--                            End button. Tapping it fires onChipTapped (the phone opens its GPS app).
--   status                   getStatus() and onStatusChanged: the active route as the phone's GPS app shows it.
--                            The destination list itself (MapLayout locations with gps = true, grouped by zone in
--                            zoneOrder: destinations()) is shown by the phone's GPS app since Phase 4.
--
-- Distances are shown in miles, or in kilometres when the player's speed units are km/h (ProfileController).
-- The player's position is their car's chassis while they sit in a car (driver or passenger), otherwise their
-- HumanoidRootPart. The pure route math (distance to the route, trimming, distance left, simplifying) is
-- exposed as GpsController.RouteMath so tests/Gps.spec can check it in Edit mode.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local React = require(ReplicatedStorage.Packages.React)
local ReactRoblox = require(ReplicatedStorage.Packages.ReactRoblox)
local Gps = require(ReplicatedStorage.Shared.Config.Gps)
local MapLayout = require(ReplicatedStorage.Shared.Config.MapLayout)
local Pathfind = require(ReplicatedStorage.Shared.Road.Pathfind)
local Units = require(ReplicatedStorage.Shared.Util.Units)
local HudController = require(script.Parent.HudController)
local InputController = require(script.Parent.InputController)
local NotifyController = require(script.Parent.NotifyController)
local ProfileController = require(script.Parent.ProfileController)

local UI = script.Parent.Parent.UI
local GpsApp = require(UI.Phone.GpsApp)
local GpsPanel = require(UI.GpsPanel)
local PhoneConfig = require(UI.Phone.PhoneConfig)

local GUI_NAME = "Gps"
local VEHICLE_ATTRIBUTE = "VehicleId" -- every spawned car model carries it (vehicle model contract)
local METERS_PER_MILE = 1609.344
local METERS_PER_KILOMETER = 1000
local EPSILON = 1e-6 -- studs; shorter than this counts as no distance at all

local e = React.createElement

export type Route = Pathfind.Route

-- The active route as the phone's GPS app and the route chip show it.
export type Status = GpsApp.Status

-- Where the GPS is taking the player.
export type Destination = {
	id: string?, -- the MapLayout location id, or nil when the destination was given as a point
	name: string, -- shown in the panel and the arrival notice
	position: Vector3,
	keepOnArrival: boolean, -- arriving neither clears the route nor shows a notice (job stops)
}

-- How setDestination routes (both optional).
export type Options = {
	name: string?, -- shown in the chip and the phone instead of the place's own name
	keepOnArrival: boolean?, -- see Destination
}

-- Route math ------------------------------------------------------------------------------------------------

-- A route's points with the distance along the route at each point (along[1] = 0).
export type Path = { points: { Vector3 }, along: { number }, length: number }

-- Where a position sits along a Path: the closest point on segment `segment` (points[segment] to
-- points[segment + 1]), `t` (0..1) of the way along it.
export type Progress = {
	segment: number,
	t: number,
	point: Vector3, -- the closest point on the route
	distance: number, -- straight-line studs from the position to that point
	along: number, -- studs along the route from its start to that point
}

local RouteMath = {}

-- The point on segment a-b closest to `position`, and how far along the segment it is (0 at a, 1 at b).
function RouteMath.closestOnSegment(a: Vector3, b: Vector3, position: Vector3): (number, Vector3)
	local ab = b - a
	local lengthSquared = ab:Dot(ab)
	if lengthSquared < EPSILON * EPSILON then
		return 0, a
	end
	local t = math.clamp((position - a):Dot(ab) / lengthSquared, 0, 1)
	return t, a + ab * t
end

function RouteMath.newPath(points: { Vector3 }): Path
	assert(#points > 0, "RouteMath.newPath needs at least one point")
	local along = { 0 }
	for index = 2, #points do
		along[index] = along[index - 1] + (points[index] - points[index - 1]).Magnitude
	end
	return { points = points, along = along, length = along[#along] }
end

-- Where `position` is along the path. With `from` (the last known progress) only the stretch from one segment
-- before it to `searchAhead` studs past it is searched, so a later part of the route that happens to pass
-- close by is never mistaken for the part the player is on. Without `from`, the whole path is searched. On a
-- tie the earlier segment wins.
function RouteMath.project(path: Path, position: Vector3, from: Progress?, searchAhead: number?): Progress
	local points = path.points
	local count = #points
	if count == 1 then
		return { segment = 1, t = 0, point = points[1], distance = (position - points[1]).Magnitude, along = 0 }
	end
	local lastSegment = count - 1
	local first = 1
	local limit = math.huge
	if from ~= nil then
		first = math.clamp(from.segment - 1, 1, lastSegment)
		if searchAhead ~= nil then
			limit = from.along + searchAhead
		end
	end
	local best: Progress? = nil
	for segment = first, lastSegment do
		if best ~= nil and path.along[segment] > limit then
			break
		end
		local t, point = RouteMath.closestOnSegment(points[segment], points[segment + 1], position)
		local distance = (position - point).Magnitude
		if best == nil or distance < best.distance - EPSILON then
			local segmentLength = path.along[segment + 1] - path.along[segment]
			best = {
				segment = segment,
				t = t,
				point = point,
				distance = distance,
				along = path.along[segment] + t * segmentLength,
			}
		end
	end
	return best :: Progress
end

-- The straight-line distance from `position` to the nearest point of the polyline through `points`.
function RouteMath.distanceTo(points: { Vector3 }, position: Vector3): number
	return RouteMath.project(RouteMath.newPath(points), position).distance
end

-- Studs left along the route from the player's progress to the end.
function RouteMath.remaining(path: Path, progress: Progress): number
	return math.max(path.length - progress.along, 0)
end

-- The route still ahead: the player's closest point on it, then every later point (at most `maxPoints` in all).
function RouteMath.trimmed(path: Path, progress: Progress, maxPoints: number?): { Vector3 }
	local points = path.points
	local limit = maxPoints or math.huge
	local ahead = { progress.point }
	for index = progress.segment + 1, #points do
		if #ahead >= limit then
			break
		end
		local point = points[index]
		if (point - ahead[#ahead]).Magnitude > EPSILON then
			table.insert(ahead, point)
		end
	end
	return ahead
end

-- Drops points that sit within `tolerance` studs of the straight line between their neighbours, so a straight
-- road made of many short edges becomes one segment. Every dropped point stays within `tolerance` of the
-- simplified line, and a point where the route doubles back is always kept.
function RouteMath.simplify(points: { Vector3 }, tolerance: number): { Vector3 }
	local count = #points
	if count <= 2 then
		return table.clone(points)
	end
	local kept = { points[1] }
	local anchor = 1 -- the last kept point
	for index = 2, count - 1 do
		-- Could one straight run from the anchor to the next point stand in for every point in between?
		local a, b = points[anchor], points[index + 1]
		local fits = true
		for between = anchor + 1, index do
			local _, closest = RouteMath.closestOnSegment(a, b, points[between])
			if (points[between] - closest).Magnitude > tolerance then
				fits = false
				break
			end
		end
		if not fits then
			table.insert(kept, points[index])
			anchor = index
		end
	end
	table.insert(kept, points[count])
	return kept
end

function RouteMath.studsToMiles(studs: number): number
	return Units.studsToMeters(studs) / METERS_PER_MILE
end

function RouteMath.studsToKilometers(studs: number): number
	return Units.studsToMeters(studs) / METERS_PER_KILOMETER
end

-- Controller ------------------------------------------------------------------------------------------------

local GpsController = {}
GpsController.RouteMath = RouteMath

-- Fires (route: Route?, destination: Destination?) when the route changes: a new route, a re-route, or the
-- route cleared (by the player, by arriving, or because no road leads there).
GpsController.onChanged = InputController.newSignal()

-- Fires (status: Status?) when what the route chip shows changes: the destination or the distance left (as
-- shown, so a few times a minute while driving rather than every check).
GpsController.onStatusChanged = InputController.newSignal()

-- Fires () when the player taps the route chip (PhoneController opens the GPS app).
GpsController.onChipTapped = InputController.newSignal()

type BeamEntry = {
	beam: Beam,
	from: Attachment,
	to: Attachment,
	a: Vector3?, -- where the attachments were last put, so unchanged beams are not written again
	b: Vector3?,
}

type Marker = { disc: Part, pillar: Beam, base: Attachment, top: Attachment }

type View = {
	scale: number,
	activeId: string?,
	activeName: string?,
	distanceText: string?,
}

local destination: Destination? = nil
local route: Route? = nil -- as Pathfind returned it
local path: Path? = nil -- the same route simplified, for tracking and drawing
local progress: Progress? = nil
local routedFrom: Vector3? = nil -- where the player was when the current route was made
local routedAt = 0 -- os.clock() when the current route was made
local ticker: RBXScriptConnection? = nil

local carrier: Part? = nil
local beams: { BeamEntry } = {}
local marker: Marker? = nil

local root: any = nil
local view: View = { scale = 1, activeId = nil, activeName = nil, distanceText = nil }

local locationsById: { [string]: MapLayout.Location }? = nil

-- The public GpsController.setDestination (defined in the API section below), for the chip's callbacks.
local setDestination: (target: string | Vector3 | nil, options: Options?) -> ()

local function locationIndex(): { [string]: MapLayout.Location }
	local index = locationsById
	if index == nil then
		local built: { [string]: MapLayout.Location } = {}
		for _, location in MapLayout.locations do
			built[location.id] = location
		end
		locationsById = built
		return built
	end
	return index
end

-- True when `id` is a MapLayout location (so the phone only offers directions to places that exist).
function GpsController.hasLocation(id: string): boolean
	return locationIndex()[id] ~= nil
end

-- Every GPS destination (MapLayout locations with gps = true), grouped by zone in MapLayout.zoneOrder and
-- sorted by name. Zones missing from zoneOrder come last.
function GpsController.destinations(): { GpsApp.Section }
	local byZone: { [string]: { GpsApp.Item } } = {}
	for _, location in MapLayout.locations do
		if location.gps then
			local items = byZone[location.zone]
			if items == nil then
				items = {}
				byZone[location.zone] = items
			end
			table.insert(items, { id = location.id, name = location.displayName })
		end
	end
	local order: { string } = table.clone(MapLayout.zoneOrder)
	local extra: { string } = {}
	for zoneId in byZone do
		if table.find(order, zoneId) == nil then
			table.insert(extra, zoneId)
		end
	end
	table.sort(extra)
	table.move(extra, 1, #extra, #order + 1, order)

	local result: { GpsApp.Section } = {}
	for _, zoneId in order do
		local items = byZone[zoneId]
		if items ~= nil and #items > 0 then
			table.sort(items, function(a: GpsApp.Item, b: GpsApp.Item): boolean
				return a.name < b.name
			end)
			local zone = MapLayout.zones[zoneId]
			table.insert(result, { title = if zone then zone.displayName else zoneId, items = items })
		end
	end
	return result
end

-- "1.2 mi" (or "1.9 km" when `units` is "kph"): the distance left as the chip and the GPS app show it.
function GpsController.distanceText(studs: number, units: string?): string
	if units == "kph" then
		local km = PhoneConfig.distance
		return string.format(km.kilometersFormat, math.max(RouteMath.studsToKilometers(studs), km.minKilometers))
	end
	local panel = Gps.panel
	return string.format(panel.milesFormat, math.max(RouteMath.studsToMiles(studs), panel.minMiles))
end

-- Where the player is ------------------------------------------------------------------------------------------

-- The car a seat belongs to, if any.
local function carOf(seat: BasePart): Model?
	local node = seat.Parent
	while node ~= nil and node ~= Workspace do
		if node:IsA("Model") and node:GetAttribute(VEHICLE_ATTRIBUTE) ~= nil then
			return node
		end
		node = node.Parent
	end
	return nil
end

-- The car's chassis while the player sits in a car, else their HumanoidRootPart; nil with no character.
local function playerPosition(): Vector3?
	local character = Players.LocalPlayer.Character
	if character == nil then
		return nil
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local seat = if humanoid then humanoid.SeatPart else nil
	local car = if seat then carOf(seat) else nil
	local chassis = if car then car.PrimaryPart else nil
	if chassis ~= nil then
		return chassis.Position
	end
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if rootPart ~= nil and rootPart:IsA("BasePart") then
		return rootPart.Position
	end
	return nil
end

-- Drawing ---------------------------------------------------------------------------------------------------

-- An attachment frame whose primary axis (X) points straight up and whose secondary axis runs across the
-- segment, so a beam between two of them lies flat on the road, face up, whichever way the segment runs
-- (also up and down hills: the width stays level across the road).
local function flatFrame(position: Vector3, direction: Vector3): CFrame
	local level = Vector3.new(direction.X, 0, direction.Z)
	local across = if level.Magnitude > EPSILON then Vector3.new(-level.Z, 0, level.X).Unit else Vector3.xAxis
	return CFrame.fromMatrix(position, Vector3.yAxis, across)
end

-- An anchored, invisible part that no physics, touch or raycast ever sees.
local function ghostPart(name: string): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Anchored = true
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.CastShadow = false
	part.Locked = true
	return part
end

local function newBeam(name: string): (Beam, Attachment, Attachment)
	local style = Gps.route
	local holder = carrier :: Part
	local from = Instance.new("Attachment")
	from.Name = `{name}A`
	from.Parent = holder
	local to = Instance.new("Attachment")
	to.Name = `{name}B`
	to.Parent = holder
	local beam = Instance.new("Beam")
	beam.Name = name
	beam.Attachment0 = from
	beam.Attachment1 = to
	beam.FaceCamera = false
	beam.Width0 = style.width
	beam.Width1 = style.width
	beam.Segments = 1 -- straight: curves are already made of short straight edges
	beam.CurveSize0 = 0
	beam.CurveSize1 = 0
	beam.Texture = "" -- one clean color, no texture
	beam.Color = ColorSequence.new(style.color)
	beam.Transparency = NumberSequence.new(style.transparency)
	beam.LightEmission = style.lightEmission
	beam.LightInfluence = style.lightInfluence
	beam.ZOffset = style.zOffset
	beam.Enabled = false
	beam.Parent = holder
	return beam, from, to
end

-- Puts beam number `index` (made on first use) between a and b.
local function setBeam(index: number, a: Vector3, b: Vector3, direction: Vector3)
	local entry = beams[index]
	if entry == nil then
		local beam, from, to = newBeam(`Segment{index}`)
		entry = { beam = beam, from = from, to = to, a = nil, b = nil }
		beams[index] = entry
	end
	if entry.a ~= a or entry.b ~= b then
		entry.a, entry.b = a, b
		entry.from.WorldCFrame = flatFrame(a, direction)
		entry.to.WorldCFrame = flatFrame(b, direction)
	end
	if not entry.beam.Enabled then
		entry.beam.Enabled = true
	end
end

-- Draws the polyline through `points` (on the road surface), reusing beams and switching off spare ones.
local function drawLine(points: { Vector3 })
	if carrier == nil then
		return -- not started yet: nothing to draw into
	end
	local style = Gps.route
	local count = math.min(#points, style.maxPointsDrawn)
	local lift = Vector3.yAxis * style.heightAboveRoad
	local overlap = style.width / 2 -- inner joints overlap by half the width, so corners close up
	local used = 0
	for index = 1, count - 1 do
		local a, b = points[index], points[index + 1]
		local delta = b - a
		local length = delta.Magnitude
		if length > EPSILON then
			local direction = delta / length
			if index > 1 then
				a -= direction * overlap
			end
			if index + 1 < #points then
				b += direction * overlap
			end
			used += 1
			setBeam(used, a + lift, b + lift, direction)
		end
	end
	for index = used + 1, #beams do
		local beam = beams[index].beam
		if beam.Enabled then
			beam.Enabled = false
		end
	end
end

local function makeMarker(): Marker
	local style = Gps.marker
	local holder = carrier :: Part
	local disc = ghostPart("ArrivalDisc")
	disc.Shape = Enum.PartType.Cylinder
	disc.Material = Enum.Material.Neon
	disc.Color = Gps.route.color
	disc.Transparency = style.discTransparency
	disc.Size = Vector3.new(style.discThickness, style.discDiameter, style.discDiameter)
	local base = Instance.new("Attachment")
	base.Name = "ArrivalBase"
	base.Parent = holder
	local top = Instance.new("Attachment")
	top.Name = "ArrivalTop"
	top.Parent = holder
	local pillar = Instance.new("Beam")
	pillar.Name = "ArrivalPillar"
	pillar.Attachment0 = base
	pillar.Attachment1 = top
	pillar.FaceCamera = true -- a soft column of light that looks the same from every side
	pillar.Segments = 1
	pillar.Texture = ""
	pillar.Width0 = style.pillarWidth
	pillar.Width1 = style.pillarWidth
	pillar.Color = ColorSequence.new(Gps.route.color)
	pillar.Transparency = NumberSequence.new(style.pillarTransparency.bottom, style.pillarTransparency.top)
	pillar.LightEmission = Gps.route.lightEmission
	pillar.LightInfluence = Gps.route.lightInfluence
	pillar.Enabled = false
	pillar.Parent = holder
	return { disc = disc, pillar = pillar, base = base, top = top }
end

-- Shows the arrival marker standing on the road at `position`, or hides it (nil).
local function placeMarker(position: Vector3?)
	local current = marker
	if current == nil then
		return
	end
	if position == nil then
		current.pillar.Enabled = false
		current.disc.Parent = nil
		return
	end
	local ground = position + Vector3.yAxis * Gps.route.heightAboveRoad
	current.base.WorldPosition = ground
	current.top.WorldPosition = ground + Vector3.yAxis * Gps.marker.pillarHeight
	current.pillar.Enabled = true
	-- A cylinder's axis is its X axis: turn it upright so the disc lies flat.
	current.disc.CFrame = CFrame.new(ground) * CFrame.Angles(0, 0, math.pi / 2)
	current.disc.Parent = carrier
end

local function clearDrawing()
	drawLine({})
	placeMarker(nil)
end

-- Makes Workspace.GpsRoute (on this client only) with the carrier part that holds every attachment.
local function createDrawing()
	local style = Gps.route
	local stale = Workspace:FindFirstChild(style.folderName)
	if stale ~= nil then
		stale:Destroy()
	end
	local folder = Instance.new("Folder")
	folder.Name = style.folderName
	local holder = ghostPart(style.carrierName)
	holder.Transparency = 1
	holder.Size = Vector3.one
	holder.CFrame = CFrame.identity
	holder.Parent = folder
	carrier = holder
	marker = makeMarker()
	folder.Parent = Workspace
end

-- Route chip -------------------------------------------------------------------------------------------------

local function onClear()
	setDestination(nil)
end

local function onOpen()
	GpsController.onChipTapped:Fire()
end

-- The whole tree: the root frame is sized 1/scale so that, after the UIScale, it fills the screen and the
-- chip is laid out in unscaled (phone) pixels, like the driving HUD.
local function App(props: View)
	return e("Frame", {
		Size = UDim2.fromScale(1 / props.scale, 1 / props.scale),
		BackgroundTransparency = 1,
	}, {
		Scale = e("UIScale", { Scale = props.scale }),
		Panel = e(GpsPanel, {
			activeName = props.activeName,
			distanceText = props.distanceText,
			onClear = onClear,
			onOpen = onOpen,
		}),
	})
end

local function render()
	if root then
		root:render(e(App, table.clone(view)))
	end
end

-- Copies the destination and distance left into the view; re-renders and tells the phone only if something
-- shown changed.
local function refreshPanel()
	local target = destination
	local currentPath, currentProgress = path, progress
	local activeId = if target then target.id else nil
	local activeName = if target then target.name else nil
	local distanceText = if currentPath and currentProgress
		then GpsController.distanceText(
			RouteMath.remaining(currentPath, currentProgress),
			ProfileController.settings().units
		)
		else nil
	if activeId == view.activeId and activeName == view.activeName and distanceText == view.distanceText then
		return
	end
	view.activeId = activeId
	view.activeName = activeName
	view.distanceText = distanceText
	render()
	GpsController.onStatusChanged:Fire(GpsController.getStatus())
end

-- Routing ---------------------------------------------------------------------------------------------------

local function stopTicker()
	if ticker then
		ticker:Disconnect()
		ticker = nil
	end
end

local function clearRoute()
	destination = nil
	route = nil
	path = nil
	progress = nil
	routedFrom = nil
	stopTicker()
	clearDrawing()
	refreshPanel()
	GpsController.onChanged:Fire(nil, nil)
end

local function arrive()
	local target = destination
	clearRoute()
	if target then
		NotifyController.show(string.format(Gps.messages.arrived, target.name), "success")
	end
end

local function redraw()
	local currentPath, currentProgress = path, progress
	if currentPath == nil or currentProgress == nil then
		clearDrawing()
		return
	end
	drawLine(RouteMath.trimmed(currentPath, currentProgress, Gps.route.maxPointsDrawn))
end

-- A route from `position` to the destination, or nil (Pathfind found none, or failed).
local function findRoute(position: Vector3, target: Destination): Route?
	local ok, result = pcall(Pathfind.route, position, target.position)
	if not ok then
		warn(`[GpsController] Pathfind.route failed: {result}`)
		return nil
	end
	if result == nil or #result.points == 0 then
		return nil
	end
	return result
end

-- Routes from `position` to the destination and draws it. Returns false (keeping any old route) when there
-- is no road route.
local function routeFrom(position: Vector3): boolean
	local target = destination
	if target == nil then
		return false
	end
	routedFrom = position
	routedAt = os.clock()
	local found = findRoute(position, target)
	if found == nil then
		return false
	end
	local newPath = RouteMath.newPath(RouteMath.simplify(found.points, Gps.route.simplifyTolerance))
	route = found
	path = newPath
	progress = RouteMath.project(newPath, position)
	placeMarker(newPath.points[#newPath.points])
	redraw()
	refreshPanel()
	GpsController.onChanged:Fire(found, target)
	return true
end

-- Off the route, and far enough and long enough since the last route was made to ask for a new one.
local function shouldReroute(position: Vector3, distanceFromRoute: number): boolean
	local tracking = Gps.tracking
	if distanceFromRoute <= tracking.offRouteDistance then
		return false
	end
	if os.clock() - routedAt < tracking.rerouteMinSeconds then
		return false
	end
	local from = routedFrom
	return from == nil or (position - from).Magnitude >= tracking.rerouteMinMove
end

-- One tracking step: arrival, re-route, trim and distance left.
local function check()
	local target = destination
	if target == nil then
		return
	end
	local position = playerPosition()
	if position == nil then
		return -- no character yet: try again next check
	end
	local tracking = Gps.tracking

	-- At the place itself (it may sit off the road, past the route's end). A kept destination (a job stop) stays
	-- up: the route keeps following the player until its owner moves it on.
	if (position - target.position).Magnitude <= tracking.arriveRadius and not target.keepOnArrival then
		arrive()
		return
	end

	local currentPath, lastProgress = path, progress
	if currentPath == nil or lastProgress == nil then
		-- The first route for this destination.
		if not routeFrom(position) then
			clearRoute()
			NotifyController.show(string.format(Gps.messages.noRoute, target.name), "warning")
		end
		return
	end

	local current = RouteMath.project(currentPath, position, lastProgress, tracking.searchAhead)
	progress = current

	-- At the end of the route (on the road nearest the place).
	local left = RouteMath.remaining(currentPath, current)
	if left <= tracking.arriveRadius and current.distance <= tracking.arriveRadius and not target.keepOnArrival then
		arrive()
		return
	end

	-- Off the route: a new one from here. With no road route from here, keep showing the old one.
	if shouldReroute(position, current.distance) and routeFrom(position) then
		return
	end

	redraw()
	refreshPanel()
end

local function startTicker()
	if ticker then
		return
	end
	local interval = 1 / Gps.tracking.checkRateHz
	local elapsed = 0
	ticker = RunService.Heartbeat:Connect(function(dt: number)
		elapsed += dt
		if elapsed >= interval then
			elapsed = 0
			check()
		end
	end)
end

-- Public API ------------------------------------------------------------------------------------------------

-- Starts routing to a MapLayout location id or a point; nil clears the route. An unknown id is ignored with a
-- warning. With no character yet, the route is made as soon as there is one. `options` (see Options) can name
-- the destination and keep it up on arrival.
function GpsController.setDestination(target: string | Vector3 | nil, options: Options?)
	if target == nil then
		if destination ~= nil then
			clearRoute()
		end
		return
	end

	local name = if options then options.name else nil
	local keep = options ~= nil and options.keepOnArrival == true
	local resolved: Destination
	if type(target) == "string" then
		local location = locationIndex()[target]
		if location == nil then
			warn(`[GpsController] No MapLayout location "{target}"`)
			return
		end
		-- gpsTarget: the part of the site players want (the dealership's display cars), when it isn't the door.
		resolved = {
			id = location.id,
			name = name or location.displayName,
			position = location.gpsTarget or location.position,
			keepOnArrival = keep,
		}
	else
		resolved = { id = nil, name = name or Gps.panel.labels.markedSpot, position = target, keepOnArrival = keep }
	end

	destination = resolved
	route = nil
	path = nil
	progress = nil
	routedFrom = nil
	clearDrawing()
	refreshPanel()
	startTicker()
	check() -- route now, so getRoute() has it straight away
end
setDestination = GpsController.setDestination

-- The active route as Pathfind made it, or nil.
function GpsController.getRoute(): Route?
	return route
end

-- Studs left along the active route (as of the last check), or nil with no route.
function GpsController.remaining(): number?
	local currentPath, currentProgress = path, progress
	if currentPath == nil or currentProgress == nil then
		return nil
	end
	return RouteMath.remaining(currentPath, currentProgress)
end

-- Where the GPS is going, or nil.
function GpsController.getDestination(): Destination?
	return destination
end

-- The active route as the route chip shows it (place, distance left in the player's units), or nil.
function GpsController.getStatus(): Status?
	local name = view.activeName
	if name == nil then
		return nil
	end
	return { id = view.activeId, name = name, distanceText = view.distanceText }
end

function GpsController:Start()
	createDrawing()

	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = GUI_NAME
	screenGui.ResetOnSpawn = false -- one GUI for the whole session; the route survives a respawn
	screenGui.DisplayOrder = Gps.panel.displayOrder
	screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	-- Keep every control clear of the Roblox top bar, notches and the home indicator.
	screenGui.ScreenInsets = Enum.ScreenInsets.CoreUISafeInsets
	screenGui.Parent = playerGui

	root = ReactRoblox.createRoot(screenGui)
	view.scale = HudController.scaleFor(screenGui.AbsoluteSize)
	screenGui:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		local scale = HudController.scaleFor(screenGui.AbsoluteSize)
		if scale ~= view.scale then
			view.scale = scale
			render()
		end
	end)
	-- Distances follow the player's speed units (mph shows miles, km/h kilometres).
	ProfileController.onChanged:Connect(function()
		refreshPanel()
	end)
	render()
end

return GpsController
