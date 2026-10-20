--!strict
-- Light shows at meet spots on the server (PLAN.md Phase 7; docs/phase-7-contracts.md "Light shows").
--
-- The server only decides who is in a show, which routine plays and when it starts (startAt: the moment the
-- track starts playing from its beginning, on the server's clock); every client runs the
-- choreography itself against workspace:GetServerTimeNow() (Controllers/LightShowController), so nothing is sent
-- per cue or per frame.
--
--   JoinLightShow { meetSpotId }  (function) the caller must be driving their own car, parked in that MeetSpot's
--            footprint and nearly still. Stillness is judged on a short window of position samples, smoothed
--            (Config/LightShows.smoothedSpeed), because the server's view of a car a client simulates wobbles.
--            Starts a show there (routine picked in rotation; Pro routines only with the Boombox & Light Show Pro
--            pass, or in Studio until MonetizationService exists), with startAt = GetServerTimeNow() + leadIn,
--            or joins the one starting soon. Returns { ok, message, showId?, startAt?, routineId? }.
--   LeaveLightShow (function)  takes the caller's car out of their show and stops it on their screen; a watcher
--            (no car in it) uses it to hide the show.
--   LightShowStart { showId, routineId, startAt, endsAt, meetSpotId, cars }  to everyone within
--            Config watch.audienceRadius of the meet spot, again whenever the roster changes, and to anyone who
--            comes into range while it runs (so players who stream in late still see it).
--   LightShowEnd { showId, reason }  when the show finishes (track length + endPadding), empties, or a player
--            leaves its range.
--
-- Cars in a show carry attributes (Config/LightShows.attributes: show id, slot, underglow) so clients rebuild the
-- roster from the cars themselves when models stream in after the remote arrived. Slots run left to right across
-- the footprint, so wave cues roll along the row.
--
-- Anti-spam: a meet spot whose show emptied rests Config show.restartCooldown before a new show starts there, a
-- player who started a show waits join.startCooldown before starting another, and LeaveLightShow keeps that
-- meet spot's shows off the caller's screen for watch.optOutSeconds (across restarts) unless they join one.
--
-- No polling for gameplay: one Heartbeat connection, alive only while a show exists, checks cars and audience
-- every Config watch.interval; a car that leaves the world drops out at once (AncestryChanged).
--
-- Studio only: LightShowService.devAddTestCars and the dev fill prefix on JoinLightShow put parked test cars in
-- a show for Dev/LightShowTests.sync (CLAUDE.md hard rule 8: refused outside Studio).

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local Catalog = require(Shared.Vehicle.Catalog)
local Garage = require(Shared.Config.Garage)
local LightShows = require(Shared.Config.LightShows)
local MapLayout = require(Shared.Config.MapLayout)
local Net = require(Shared.Net)
local Spawning = require(Shared.Config.Spawning)
local Units = require(Shared.Util.Units)
local DataService = require(script.Parent.DataService)
local VehicleService = require(script.Parent.VehicleService)

local LOG = "[LightShowService]"
local MEET_SPOT_TAG = "MeetSpot"
local DRIVER_SEAT = "Driver" -- vehicle model contract
local SEATS_FOLDER = "Seats"
local MONETIZATION_MODULE = "MonetizationService" -- Phase 12; optional until then

export type Reply = {
	ok: boolean,
	message: string,
	showId: string?,
	startAt: number?,
	routineId: string?,
}

type ShowCar = {
	model: Model,
	owner: Player?, -- nil for a Studio test car
	test: boolean,
	connection: RBXScriptConnection, -- drops the car the moment it leaves the world
}

type Show = {
	id: string,
	meetSpotId: string,
	location: MapLayout.Location,
	frame: CFrame, -- the footprint (LightShows.footprintFrame)
	routineId: string,
	startAt: number, -- server time of beat 0
	endsAt: number, -- server time the music ends
	cars: { ShowCar },
	audience: { [Player]: boolean }, -- players who were sent LightShowStart and not yet LightShowEnd
	endThread: thread?,
	ended: boolean,
}

local attributes = LightShows.attributes
local messages = LightShows.messages

local LightShowService = {}

local meetSpots: { [string]: MapLayout.Location } = {}
local shows: { [string]: Show } = {} -- by show id
local showBySpot: { [string]: Show } = {}
local showByCar: { [Model]: Show } = {}
local lastRoutine: { [string]: string } = {} -- by meet spot: the routine played last (rotation)
local joining: { [Player]: boolean } = {} -- a join is sampling this player's car
-- Anti-spam (Config show.restartCooldown, join.startCooldown, watch.optOutSeconds), all in server time:
local spotCoolUntil: { [string]: number } = {} -- by meet spot: no new show there before this
local startCoolUntil: { [Player]: number } = {} -- by player: they start no new show before this
local optOuts: { [string]: { [Player]: number } } = {} -- by meet spot: watchers who hid its shows, until when
local watchConnection: RBXScriptConnection? = nil
local watchElapsed = 0

local stillSpeed = Units.mphToStuds(LightShows.join.stillMph)

-- Helpers ---------------------------------------------------------------------------------------------------

local function reply(ok: boolean, message: string): Reply
	return { ok = ok, message = message }
end

local function frameOf(location: MapLayout.Location): CFrame
	return LightShows.footprintFrame(location.position, location.yaw)
end

-- The car the player is driving right now (their own, with them in its Driver seat), or nil.
local function drivenCar(player: Player): Model?
	local model = VehicleService.getCar(player)
	local character = player.Character
	local humanoid = if character then character:FindFirstChildOfClass("Humanoid") else nil
	if model == nil or humanoid == nil then
		return nil
	end
	local seats = model:FindFirstChild(SEATS_FOLDER)
	local seat = if seats then seats:FindFirstChild(DRIVER_SEAT) else nil
	if seat == nil or not seat:IsA("Seat") or seat.Occupant ~= humanoid then
		return nil
	end
	return model
end

local function onFootprint(show: Show, model: Model, margin: number): boolean
	return LightShows.insideFootprint(show.frame, show.location.size, model:GetPivot().Position, margin)
end

-- The car's smoothed ground speed (studs/s) over Config join.stillWindow seconds of Heartbeat samples, or nil if
-- the car left the world meanwhile. Yields for the window (only ever inside a JoinLightShow call).
local function sampleSpeed(model: Model): number?
	local samples: { LightShows.Sample } = {}
	local started = os.clock()
	repeat
		if model.Parent == nil then
			return nil
		end
		table.insert(samples, { time = os.clock(), position = model:GetPivot().Position })
		RunService.Heartbeat:Wait()
	until os.clock() - started >= LightShows.join.stillWindow
	return LightShows.smoothedSpeed(samples)
end

-- MonetizationService (Phase 12) when it exists and has hasPass, else nil.
local function monetization(): any
	local module = script.Parent:FindFirstChild(MONETIZATION_MODULE)
	if module == nil or not module:IsA("ModuleScript") then
		return nil
	end
	local ok, service = pcall(require :: any, module)
	if ok and type(service) == "table" and type(service.hasPass) == "function" then
		return service
	end
	return nil
end

-- Whether the player may get the Pro routines: the pass once MonetizationService exists, else Studio only.
local function hasPro(player: Player): boolean
	local service = monetization()
	if service == nil then
		return RunService:IsStudio()
	end
	local ok, owned = pcall(service.hasPass, player, LightShows.proPass)
	return ok and owned == true
end

-- True when the player's saved car (by the OwnedUid attribute GarageService sets) has a light-bar extra.
local function hasLightBar(owner: Player, model: Model): boolean
	local uid = model:GetAttribute(Garage.ownedUidAttribute)
	local data = if type(uid) == "string" then DataService.get(owner) else nil
	if data == nil then
		return false
	end
	for _, vehicle in data.vehicles do
		if vehicle.uid == uid then
			-- `extras` arrives with schema v5 (CustomizationService); read it loosely until then.
			local extras = (vehicle :: any).extras
			if type(extras) ~= "table" then
				return false
			end
			for _, extraId in extras do
				if table.find(LightShows.underglow.extraIds, extraId) then
					return true
				end
			end
			return false
		end
	end
	return false
end

local function rootDistance(player: Player, point: Vector3): number?
	local character = player.Character
	local root = if character then character:FindFirstChild("HumanoidRootPart") else nil
	if root == nil or not root:IsA("BasePart") then
		return nil
	end
	local offset = root.Position - point
	return Vector3.new(offset.X, 0, offset.Z).Magnitude
end

local function isParticipant(show: Show, player: Player): boolean
	for _, car in show.cars do
		if car.owner == player then
			return true
		end
	end
	return false
end

-- True while the player hid shows at this meet spot (LeaveLightShow as a watcher) and that hasn't run out.
local function optedOut(meetSpotId: string, player: Player): boolean
	local list = optOuts[meetSpotId]
	local untilTime = if list then list[player] else nil
	if untilTime == nil then
		return false
	elseif Workspace:GetServerTimeNow() >= untilTime then
		(list :: { [Player]: number })[player] = nil
		return false
	end
	return true
end

local function setOptedOut(meetSpotId: string, player: Player, on: boolean)
	local list = optOuts[meetSpotId]
	if on then
		if list == nil then
			list = {}
			optOuts[meetSpotId] = list
		end
		(list :: { [Player]: number })[player] = Workspace:GetServerTimeNow() + LightShows.watch.optOutSeconds
	elseif list ~= nil then
		list[player] = nil
	end
end

local function realCars(show: Show): number
	local count = 0
	for _, car in show.cars do
		if not car.test then
			count += 1
		end
	end
	return count
end

-- Messages to clients ----------------------------------------------------------------------------------------

local function startPayload(show: Show): { [string]: any }
	local cars: { Model } = {}
	for _, car in show.cars do
		table.insert(cars, car.model)
	end
	return {
		showId = show.id,
		routineId = show.routineId,
		startAt = show.startAt,
		endsAt = show.endsAt,
		meetSpotId = show.meetSpotId,
		cars = cars,
	}
end

local function sendStart(show: Show, player: Player)
	if player.Parent ~= nil then
		Net.fireClient("LightShowStart", player, startPayload(show))
	end
end

local function sendEnd(show: Show, player: Player, reason: string)
	if player.Parent ~= nil then
		Net.fireClient("LightShowEnd", player, { showId = show.id, reason = reason })
	end
end

local function broadcast(show: Show)
	for player in show.audience do
		sendStart(show, player)
	end
end

-- Roster -----------------------------------------------------------------------------------------------------

-- Numbers the cars left to right across the footprint and writes each car's slot attribute.
local function assignSlots(show: Show)
	local pivots: { Vector3 } = {}
	for _, car in show.cars do
		table.insert(pivots, car.model:GetPivot().Position)
	end
	local slots = LightShows.slotOrder(show.frame, pivots)
	for index, car in show.cars do
		car.model:SetAttribute(attributes.slot, slots[index])
	end
end

local function clearAttributes(model: Model)
	model:SetAttribute(attributes.showId, nil)
	model:SetAttribute(attributes.slot, nil)
	model:SetAttribute(attributes.underglow, nil)
end

-- Takes a car out of its show's list and forgets it (no messages). Test cars are removed from the world.
local function forgetCar(show: Show, model: Model)
	for index, car in show.cars do
		if car.model == model then
			table.remove(show.cars, index)
			car.connection:Disconnect()
			showByCar[model] = nil
			if car.test then
				model:Destroy()
			elseif model.Parent ~= nil then
				clearAttributes(model)
			end
			return
		end
	end
end

local stopWatchIfIdle: () -> ()

-- Ends a show: every car is let go (test cars removed) and everyone who had it is told.
local function endShow(show: Show, reason: string)
	if show.ended then
		return
	end
	show.ended = true
	local thread = show.endThread
	show.endThread = nil
	if thread ~= nil and thread ~= coroutine.running() then
		task.cancel(thread)
	end
	for _, car in table.clone(show.cars) do
		forgetCar(show, car.model)
	end
	shows[show.id] = nil
	if showBySpot[show.meetSpotId] == show then
		showBySpot[show.meetSpotId] = nil
	end
	for player in show.audience do
		sendEnd(show, player, reason)
	end
	table.clear(show.audience)
	stopWatchIfIdle()
end

-- Takes cars out of a show; ends it when no player's car is left, else renumbers (before the start only) and
-- re-sends the roster.
local function dropCars(show: Show, models: { Model })
	if show.ended or #models == 0 then
		return
	end
	for _, model in models do
		forgetCar(show, model)
	end
	if realCars(show) == 0 then
		-- The spot rests before another show may start there, so one player can't restart shows on everyone nearby.
		spotCoolUntil[show.meetSpotId] = Workspace:GetServerTimeNow() + LightShows.show.restartCooldown
		endShow(show, "empty")
		return
	end
	-- Slots are renumbered only before the start: once it runs, a gap in the row is better than every remaining
	-- car's wave jumping a step (and skipping cues that fall between its old and new times).
	if Workspace:GetServerTimeNow() < show.startAt then
		assignSlots(show)
	end
	broadcast(show)
end

local function addCar(show: Show, model: Model, owner: Player?, test: boolean)
	local entry: ShowCar = {
		model = model,
		owner = owner,
		test = test,
		connection = model.AncestryChanged:Connect(function()
			if not model:IsDescendantOf(Workspace) then
				dropCars(show, { model })
			end
		end),
	}
	table.insert(show.cars, entry)
	showByCar[model] = show
	model:SetAttribute(attributes.showId, show.id)
	model:SetAttribute(attributes.underglow, owner ~= nil and hasLightBar(owner, model))
end

-- Audience ---------------------------------------------------------------------------------------------------

-- Sends the show to players who came within range (and every participant), and ends it for players who went
-- out of range.
local function refreshAudience(show: Show)
	local watch = LightShows.watch
	local centre = show.location.position
	for _, player in Players:GetPlayers() do
		local participant = isParticipant(show, player)
		local distance = rootDistance(player, centre)
		if show.audience[player] then
			local outOfRange = distance == nil or distance > watch.audienceRadius * watch.audienceExitFactor
			if not participant and outOfRange then
				show.audience[player] = nil
				sendEnd(show, player, "out of range")
			end
		elseif participant or not optedOut(show.meetSpotId, player) then
			if participant or (distance ~= nil and distance <= watch.audienceRadius) then
				show.audience[player] = true
				sendStart(show, player)
			end
		end
	end
end

-- Watching running shows ---------------------------------------------------------------------------------------

local function watchShows()
	for _, show in table.clone(shows) do
		local gone: { Model } = {}
		for _, car in show.cars do
			if car.model.Parent == nil or not onFootprint(show, car.model, LightShows.watch.leaveMargin) then
				table.insert(gone, car.model)
			end
		end
		dropCars(show, gone)
		if not show.ended then
			refreshAudience(show)
		end
	end
end

local function startWatch()
	if watchConnection ~= nil then
		return
	end
	watchElapsed = 0
	watchConnection = RunService.Heartbeat:Connect(function(dt: number)
		watchElapsed += dt
		if watchElapsed >= LightShows.watch.interval then
			watchElapsed = 0
			watchShows()
		end
	end)
end

stopWatchIfIdle = function()
	if next(shows) == nil and watchConnection ~= nil then
		watchConnection:Disconnect()
		watchConnection = nil
	end
end

-- Starting a show ----------------------------------------------------------------------------------------------

local function newShow(meetSpotId: string, location: MapLayout.Location, routineId: string): Show
	local routine = LightShows.getRoutine(routineId) :: LightShows.Routine
	local now = Workspace:GetServerTimeNow()
	local startAt = now + LightShows.show.leadIn
	local show: Show = {
		id = HttpService:GenerateGUID(false),
		meetSpotId = meetSpotId,
		location = location,
		frame = frameOf(location),
		routineId = routineId,
		startAt = startAt,
		endsAt = startAt + LightShows.length(routine),
		cars = {},
		audience = {},
		endThread = nil,
		ended = false,
	}
	shows[show.id] = show
	showBySpot[meetSpotId] = show
	lastRoutine[meetSpotId] = routineId
	show.endThread = task.delay(show.endsAt - now + LightShows.show.endPadding, function()
		show.endThread = nil
		endShow(show, "finished")
	end)
	startWatch()
	return show
end

-- Studio test cars --------------------------------------------------------------------------------------------

-- Where a car set down at `frame` rests: the ground under it (ignoring cars and characters), facing the frame's way.
local function groundUnder(frame: CFrame): CFrame
	local ignore: { Instance } = {}
	local vehicles = Workspace:FindFirstChild(Spawning.vehiclesFolder)
	if vehicles ~= nil then
		table.insert(ignore, vehicles)
	end
	for _, player in Players:GetPlayers() do
		if player.Character ~= nil then
			table.insert(ignore, player.Character)
		end
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = ignore
	params.RespectCanCollide = true
	local park = Spawning.park
	local origin = frame.Position + Vector3.yAxis * park.probeUp
	local hit = Workspace:Raycast(origin, Vector3.yAxis * -(park.probeUp + park.probeDown), params)
	return if hit then frame.Rotation + hit.Position else frame
end

-- A parked copy of a catalog car at `frame`, tagged like a real car so clients pick it up; nil (with a warning)
-- when its model isn't built.
local function spawnTestCar(frame: CFrame, n: number): Model?
	local list = LightShows.dev.testVehicles
	local vehicleId = list[(n - 1) % #list + 1]
	local trim = Catalog.defaultTrim(vehicleId)
	local folder = ServerStorage:FindFirstChild(Spawning.modelsFolder)
	local template = if folder and trim then folder:FindFirstChild(Catalog.modelName(vehicleId, trim.id)) else nil
	if template == nil or not template:IsA("Model") or template.PrimaryPart == nil then
		warn(`{LOG} No built model for test car "{vehicleId}" (run Dev/VehicleBuilder.buildAll in Edit mode)`)
		return nil
	end
	local model = template:Clone()
	local chassis = model.PrimaryPart :: BasePart
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Anchored = false
		end
	end
	chassis.Anchored = true -- everything else is welded to it
	model:SetAttribute(attributes.testCar, true)
	model:AddTag(Spawning.vehicleTag)
	model:PivotTo(groundUnder(frame))
	local vehicles = Workspace:FindFirstChild(Spawning.vehiclesFolder)
	model.Parent = if vehicles then vehicles else Workspace
	return model
end

-- Fills free slots of a show with test cars until it has `target` cars. Returns how many were added.
local function fillWithTestCars(show: Show, target: number): number
	local added = 0
	local wanted = math.min(target, LightShows.show.maxCars)
	for _, frame in LightShows.slotFrames(show.frame, show.location.size) do
		if #show.cars >= wanted then
			break
		end
		local taken = false
		for _, car in show.cars do
			local offset = car.model:GetPivot().Position - frame.Position
			if Vector3.new(offset.X, 0, offset.Z).Magnitude < LightShows.slots.takenRadius then
				taken = true
				break
			end
		end
		if not taken then
			local model = spawnTestCar(frame, added + 1)
			if model ~= nil then
				addCar(show, model, nil, true)
				added += 1
			end
		end
	end
	return added
end

-- Studio only: fills the show starting at `meetSpotId` with parked test cars up to `cars` in all, and re-sends it.
-- Returns how many test cars were added (0 outside Studio, with no show there, or once it has started).
function LightShowService.devAddTestCars(meetSpotId: string, cars: number): number
	if not RunService:IsStudio() then
		return 0
	end
	local show = showBySpot[meetSpotId]
	if show == nil or Workspace:GetServerTimeNow() > show.startAt - LightShows.show.joinCutoff then
		return 0
	end
	local added = fillWithTestCars(show, cars)
	if added > 0 then
		assignSlots(show)
		broadcast(show)
	end
	return added
end

-- Remote handlers ----------------------------------------------------------------------------------------------

-- The meet spot id from a JoinLightShow payload, and in Studio the test-car fill count after the dev prefix.
local function parseSpot(raw: string): (string, number?)
	local prefix = LightShows.dev.fillPrefix
	if string.sub(raw, 1, #prefix) ~= prefix then
		return raw, nil
	end
	if not RunService:IsStudio() then
		return "", nil -- dev tools stay dev: an unknown spot
	end
	local count, spot = string.match(string.sub(raw, #prefix + 1), "^(%d+):(.+)$")
	return spot or "", if count then tonumber(count) else nil
end

local function join(player: Player, payload: any): Reply
	local meetSpotId, fill = parseSpot(payload.meetSpotId)
	local location = meetSpots[meetSpotId]
	if location == nil then
		return reply(false, messages.unknownSpot)
	end
	local model = drivenCar(player)
	if model == nil then
		return reply(false, messages.notDriving)
	end
	local frame = frameOf(location)
	local function inside(): boolean
		return LightShows.insideFootprint(frame, location.size, model:GetPivot().Position, 0)
	end
	if not inside() then
		return reply(false, messages.notInside)
	end
	if joining[player] then
		return reply(false, messages.notStill)
	end
	joining[player] = true
	local speed = sampleSpeed(model)
	joining[player] = nil
	-- Re-check after the wait: they may have got out, driven off or left.
	if player.Parent == nil or drivenCar(player) ~= model then
		return reply(false, messages.notDriving)
	elseif not inside() then
		return reply(false, messages.notInside)
	elseif speed == nil or speed > stillSpeed then
		return reply(false, messages.notStill)
	end

	local existing = showBySpot[meetSpotId]
	local current = showByCar[model]
	if current ~= nil and current == existing then
		-- Already in this show: send it again (their client may have lost it).
		setOptedOut(meetSpotId, player, false)
		current.audience[player] = true
		sendStart(current, player)
		return {
			ok = true,
			message = string.format(messages.joined, location.displayName),
			showId = current.id,
			startAt = current.startAt,
			routineId = current.routineId,
		}
	end

	local show = existing
	local now = Workspace:GetServerTimeNow()
	if show ~= nil then
		if now > show.startAt - LightShows.show.joinCutoff then
			return reply(false, messages.busy)
		elseif #show.cars >= LightShows.show.maxCars then
			return reply(false, messages.full)
		end
	elseif fill == nil then
		-- Starting a new show: the spot and the player must both be off their cooldowns (the Studio-only dev fill
		-- skips them so Dev/LightShowTests can run back to back).
		local spotWait = (spotCoolUntil[meetSpotId] or 0) - now
		if spotWait > 0 then
			return reply(false, string.format(messages.spotCooling, math.ceil(spotWait)))
		end
		local playerWait = (startCoolUntil[player] or 0) - now
		if playerWait > 0 then
			return reply(false, string.format(messages.playerCooling, math.ceil(playerWait)))
		end
	end
	if current ~= nil then
		dropCars(current, { model }) -- moving from another meet spot's show
	end
	if show == nil then
		local routineId = LightShows.nextRoutine(LightShows.routinesFor(hasPro(player)), lastRoutine[meetSpotId])
		if routineId == nil then
			return reply(false, messages.unknownSpot)
		end
		show = newShow(meetSpotId, location, routineId)
		startCoolUntil[player] = now + LightShows.join.startCooldown
	end
	local joined = show :: Show
	addCar(joined, model, player, false)
	if fill ~= nil then
		fillWithTestCars(joined, fill)
	end
	assignSlots(joined)
	setOptedOut(meetSpotId, player, false)
	joined.audience[player] = true
	refreshAudience(joined) -- a new show reaches everyone nearby now, not at the next watch tick
	broadcast(joined)
	return {
		ok = true,
		message = string.format(messages.joined, location.displayName),
		showId = joined.id,
		startAt = joined.startAt,
		routineId = joined.routineId,
	}
end

local function leave(player: Player): Reply
	local found = false
	-- Stop it on their screen first, so the roster update below doesn't reach them.
	for _, show in table.clone(shows) do
		if show.audience[player] or isParticipant(show, player) then
			found = true
			-- They aren't sent this spot's shows for a while (kept across restarts, not just this show); joining
			-- a show there again clears it.
			setOptedOut(show.meetSpotId, player, true)
			if show.audience[player] then
				show.audience[player] = nil
				sendEnd(show, player, "left")
			end
		end
	end
	local model = VehicleService.getCar(player)
	local own = if model then showByCar[model] else nil
	if own ~= nil and model ~= nil then
		found = true
		dropCars(own, { model })
	end
	return reply(found, if found then messages.left else messages.notInShow)
end

-- Boot ---------------------------------------------------------------------------------------------------------

function LightShowService:Init()
	for _, location in MapLayout.locations do
		if location.tag == MEET_SPOT_TAG then
			meetSpots[location.id] = location
		end
	end
	for _, id in LightShows.routineOrder do
		local routine = LightShows.getRoutine(id)
		if routine == nil then
			warn(`{LOG} routineOrder names unknown routine "{id}"`)
		else
			for _, problem in LightShows.problems(routine) do
				warn(`{LOG} {problem}`)
			end
		end
	end
end

function LightShowService:Start()
	Net.onServerInvoke("JoinLightShow", function(player: Player, payload: any): Reply
		return join(player, payload)
	end)
	Net.onServerInvoke("LeaveLightShow", function(player: Player): Reply
		return leave(player)
	end)
	Players.PlayerRemoving:Connect(function(player: Player)
		joining[player] = nil
		startCoolUntil[player] = nil
		for _, list in optOuts do
			list[player] = nil
		end
		for _, show in shows do
			show.audience[player] = nil
		end
		-- Their car is despawned by VehicleService; its AncestryChanged drops it from its show.
	end)
end

return LightShowService
