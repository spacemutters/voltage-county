--!strict
-- The Mesa Test Site drag strip and its weekly leaderboard (PLAN.md Phase 10; docs/phase-10-contracts.md "Arc
-- tuning, drag strip and leaderboard"). Config/DragStrip holds every tunable and the pure rules; this service
-- runs them on what the server sees.
--
-- Watching: at Start the service builds Workspace.DragStrip (outside Map.Generated): an invisible touch sensor
-- over the staging area behind gate 1, and the leaderboard board. A car's Chassis touching the sensor, or its
-- owner sitting in its Driver seat while it stands there, starts watching that car. Only watched cars are
-- sampled, once per Heartbeat, and the Heartbeat is connected only while at least one car is watched, so nothing
-- runs while the strip is empty (CLAUDE.md hard rule 10).
--
-- A watched car is "staged" until it has stood still in the staging area for long enough, then "armed" (the
-- driver is told). Each sample takes the car's server-side front point and velocity (DragStrip.frontPoint,
-- Chassis:GetVelocityAtPosition) at Workspace:GetServerTimeNow(); the moment the front crosses each gate plane is
-- interpolated between that sample and the one before (DragStrip.crossingTime), so the times don't depend on the
-- frame rate. Gate 1 starts the run ("running"), gates 2 and 3 are splits, gate 4 finishes it. The result waits
-- DragStrip.finishConfirmSeconds, so anti-exploit can catch a trick near the line first, then counts.
--
-- Faults (DragStrip.faultFor) void an armed or running run: the server moved the car (AntiExploitService
-- onServerMove / lastServerMove: resets, unstucks, dev teleports), the front jumped further than the car's speed
-- allows, an ability ran (the car's Ability attribute; thrusters never count on the strip), the owner left the
-- Driver seat, the car left the strip sideways, or the run took too long.
--
-- Leaderboard: one OrderedDataStore per ISO week (DragStrip.storePrefix .. weekKey; Studio uses
-- DragStrip.studioStorePrefix so tests never touch the live board), key = UserId, value = best milliseconds.
-- A finished run is written only when it is the player's best this week (UpdateAsync keeps the lower time even
-- across servers), and only when neither it nor a split is quicker than that trim could possibly be
-- (DragStrip.isPlausible against DragStrip.fastestSplits, worked out once per trim from Vehicle/Tuning). Every
-- DataStore call is wrapped in pcall and waits for request budget first. When Studio can't reach DataStores at
-- all, the week's times live in this server's memory instead. Dealership test drives are timed but never saved.
--
-- Remotes (declared in Net):
--   DragStripUpdate     server -> driver: { state = "armed" | "running" | "finished" | "fault", message?, ... }.
--                       "running" comes at gate 1 (gate = 1, startedAt) and again at gates 2 and 3 (gate, time =
--                       the split); "finished" adds time, best?, rank?, newBest, splits, startedAt, finishedAt.
--                       Times are seconds; startedAt/finishedAt are server clock times of the crossings.
--   GetDragLeaderboard  function: { week, entries = { { name, time } } (the top DragStrip.boardSize), best?, rank? }
--                       from a read at most DragStrip.cacheSeconds old. `rank` is the caller's place among the
--                       first DragStrip.rankPageSize times, or nil.
-- Names are Roblox display names (no TextService filtering needed for them).

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserService = game:GetService("UserService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local Catalog = require(Shared.Vehicle.Catalog)
local Controls = require(Shared.Config.Controls)
local DragStrip = require(Shared.Config.DragStrip)
local Garage = require(Shared.Config.Garage)
local MapLayout = require(Shared.Config.MapLayout)
local Net = require(Shared.Net)
local Spawning = require(Shared.Config.Spawning)
local Tuning = require(Shared.Vehicle.Tuning)
local Units = require(Shared.Util.Units)
local AntiExploitService = require(script.Parent.AntiExploitService)

local LOG = "[DragStrip]"
local OWNER_ATTRIBUTE = "OwnerUserId" -- set by VehicleService on every spawned car
local ABILITY_ATTRIBUTE = "Ability" -- set by AbilityService while an ability runs (phase-10 "Shared names")
local CHASSIS = "Chassis" -- vehicle model contract
local SEATS_FOLDER = "Seats"
local DRIVER_SEAT = "Driver"
local SENSOR_NAME = "StagingSensor"
local BOARD_NAME = "Leaderboard"
local START_GATE = 1
local ANY_TRIM = "*" -- fastest-times cache key for a car whose trim isn't known

type Phase = "staged" | "armed" | "running" | "finishing"

-- One server sample of a watched car.
type Sample = { time: number, front: Vector3, velocity: Vector3 }

-- One watched car.
type Watch = {
	model: Model,
	chassis: BasePart,
	seat: Seat,
	player: Player,
	topSpeed: number, -- studs/s, the car's catalog top speed (the jump check)
	-- The quickest this car could possibly reach each later gate from the start line (seconds, by gate index;
	-- fastestFor): a run or split under DragStrip.plausibleShare of it isn't saved.
	fastest: { [number]: number },
	testDrive: boolean, -- a dealership test drive: timed, never saved
	phase: Phase,
	stillSince: number?, -- server time the car first stood still in the staging area
	armedClock: number, -- os.clock() when the run armed (compared with AntiExploitService.lastServerMove)
	previous: Sample?,
	nextGate: number, -- the next gate the front must cross
	crossings: { [number]: number }, -- server time of each gate's crossing, by gate index
	serial: number, -- bumped by every arm, so a late finish confirmation can tell its run is gone
}

-- The week's times as last read: sorted fastest first, at most DragStrip.rankPageSize.
type Page = { week: string, at: number, entries: { DragStrip.Entry } }

-- A player's best this week as far as this server knows (ms nil = no time yet).
type Best = { week: string, ms: number? }

type Leaderboard = {
	week: string,
	entries: { { name: string, time: number } },
	best: number?,
	rank: number?,
}

-- Board labels, updated in place.
type BoardLabels = {
	week: TextLabel,
	empty: TextLabel,
	rows: { { frame: Frame, name: TextLabel, time: TextLabel } },
}

local DragStripService = {}

local gates: { DragStrip.Gate } = {}
local watches: { [Model]: Watch } = {}
local heartbeat: RBXScriptConnection? = nil
local vehiclesFolder: Instance? = nil
local nextSerial = 0

local stores: { [string]: OrderedDataStore } = {}
local useMemory = false -- Studio couldn't reach DataStores: times live in memoryBoards for the session
local memoryBoards: { [string]: { [number]: number } } = {} -- week -> UserId -> ms
local page: Page = { week = "", at = -math.huge, entries = {} }
local refreshing = false
local bests: { [number]: Best } = {}
local names: { [number]: string } = {}
local fastestByTrim: { [string]: { [number]: number } } = {} -- fastestFor, per "vehicleId/trimId" (or ANY_TRIM)
local boardLabels: BoardLabels? = nil

-- Pure helpers (the logic lives in Config/DragStrip so clients and specs can run it too) -------------------

DragStripService.weekKey = DragStrip.weekKey
DragStripService.crossingTime = DragStrip.crossingTime
DragStripService.faultFor = DragStrip.faultFor

-- Cars -------------------------------------------------------------------------------------------------------

-- The car's catalog top speed in studs/s, from its VehicleId and Trim attributes (the fastest catalog top speed
-- when they don't name a trim).
local function topSpeedOf(model: Model): number
	local vehicleId, trimId = model:GetAttribute("VehicleId"), model:GetAttribute("Trim")
	local trim = if type(vehicleId) == "string" and type(trimId) == "string"
		then Catalog.getTrim(vehicleId, trimId)
		else nil
	if trim ~= nil then
		return Units.mphToStuds(trim.topSpeedMph)
	end
	local fastest = 0
	for _, id in Catalog.vehicleIds() do
		local vehicle = Catalog.getVehicle(id)
		if vehicle ~= nil then
			for _, each in vehicle.trims do
				fastest = math.max(fastest, each.topSpeedMph)
			end
		end
	end
	return Units.mphToStuds(fastest)
end

-- DragStrip.fastestSplits for one trim's numbers, by gate index (every gate after the start line).
local function fastestTimes(tuning: Tuning.Tuning): { [number]: number }
	local start = gates[START_GATE]
	local distances: { number } = {}
	for index = START_GATE + 1, #gates do
		table.insert(distances, DragStrip.distancePast(start, gates[index].origin))
	end
	local splits = DragStrip.fastestSplits(tuning, distances)
	local byGate: { [number]: number } = {}
	for offset, seconds in splits do
		byGate[START_GATE + offset] = seconds
	end
	return byGate
end

-- The quickest the car could possibly reach each gate after the start line (seconds, by gate index), from its
-- VehicleId and Trim attributes, worked out once per trim. A car whose trim isn't known gets the quickest of any
-- catalog trim at each gate.
local function fastestFor(model: Model): { [number]: number }
	local vehicleId, trimId = model:GetAttribute("VehicleId"), model:GetAttribute("Trim")
	local tuning = if type(vehicleId) == "string" and type(trimId) == "string"
		then Tuning.forTrim(vehicleId, trimId)
		else nil
	local key = if tuning ~= nil then `{tuning.vehicleId}/{tuning.trimId}` else ANY_TRIM
	local cached = fastestByTrim[key]
	if cached ~= nil then
		return cached
	end
	local times: { [number]: number }
	if tuning ~= nil then
		times = fastestTimes(tuning)
	else
		times = {}
		for _, id in Catalog.vehicleIds() do
			local vehicle = Catalog.getVehicle(id)
			if vehicle == nil then
				continue
			end
			for _, trim in vehicle.trims do
				local each = Tuning.forTrim(id, trim.id)
				if each == nil then
					continue
				end
				for index, seconds in fastestTimes(each) do
					local known = times[index]
					-- 0 is "no bound", so it wins.
					times[index] = if known == nil then seconds else math.min(known, seconds)
				end
			end
		end
	end
	fastestByTrim[key] = times
	return times
end

-- True when the car's owner sits, alive, in its Driver seat.
local function drivenByOwner(watch: Watch): boolean
	local occupant = watch.seat.Occupant
	local character = watch.player.Character
	return occupant ~= nil and character ~= nil and occupant.Parent == character and occupant.Health > 0
end

-- Across-the-ground distance between two points.
local function flatDistance(a: Vector3, b: Vector3): number
	local offset = b - a
	return Vector3.new(offset.X, 0, offset.Z).Magnitude
end

local function send(player: Player, payload: { [string]: any })
	if player.Parent ~= nil then
		Net.fireClient("DragStripUpdate", player, payload)
	end
end

-- Watching ---------------------------------------------------------------------------------------------------

local step: (watch: Watch, now: number) -> ()

local function onHeartbeat()
	local now = Workspace:GetServerTimeNow()
	-- Snapshot first: a step can stop watching cars mid-pass.
	local due: { Watch } = {}
	for _, watch in watches do
		table.insert(due, watch)
	end
	for _, watch in due do
		if watches[watch.model] == watch then
			step(watch, now)
		end
	end
end

local function unwatch(watch: Watch)
	if watches[watch.model] ~= watch then
		return
	end
	watches[watch.model] = nil
	-- Heartbeat runs only while at least one car is watched.
	local connection = heartbeat
	if connection ~= nil and next(watches) == nil then
		connection:Disconnect()
		heartbeat = nil
	end
end

-- Starts watching a car that may be in the staging area: a driven car of a player in this server whose Driver
-- seat holds its owner. Cars already watched, parked, or not standing behind the line are left alone.
local function consider(instance: Instance?)
	if instance == nil or not instance:IsA("Model") or watches[instance] ~= nil then
		return
	end
	local model = instance :: Model
	if vehiclesFolder == nil or model.Parent ~= vehiclesFolder then
		return
	end
	local ownerId = model:GetAttribute(OWNER_ATTRIBUTE)
	local owner = if type(ownerId) == "number" then Players:GetPlayerByUserId(ownerId) else nil
	local chassisPart = model:FindFirstChild(CHASSIS)
	local seats = model:FindFirstChild(SEATS_FOLDER)
	local seatPart = if seats ~= nil then seats:FindFirstChild(DRIVER_SEAT) else nil
	if owner == nil or chassisPart == nil or not chassisPart:IsA("BasePart") then
		return
	end
	if seatPart == nil or not seatPart:IsA("Seat") then
		return
	end
	local player = owner :: Player
	local chassis = chassisPart :: BasePart
	local seat = seatPart :: Seat
	local start = gates[START_GATE]
	local front = DragStrip.frontPoint(chassis.CFrame, chassis.Size)
	if
		not DragStrip.staysStaged(
			DragStrip.distancePast(start, front),
			DragStrip.lateral(start, chassis.Position),
			start.halfWidth
		)
	then
		return
	end
	local watch: Watch = {
		model = model,
		chassis = chassis,
		seat = seat,
		player = player,
		topSpeed = topSpeedOf(model),
		fastest = fastestFor(model),
		testDrive = model:GetAttribute(Garage.testDriveAttribute) == true,
		phase = "staged",
		stillSince = nil,
		armedClock = math.huge,
		previous = nil,
		nextGate = START_GATE,
		crossings = {},
		serial = 0,
	}
	if not drivenByOwner(watch) then
		return
	end
	watches[model] = watch
	if heartbeat == nil then
		heartbeat = RunService.Heartbeat:Connect(onHeartbeat)
	end
end

-- The player's best this week if this server already knows it, in milliseconds.
local function knownBest(player: Player, week: string): number?
	local best = bests[player.UserId]
	return if best ~= nil and best.week == week then best.ms else nil
end

local function arm(watch: Watch)
	nextSerial += 1
	watch.phase = "armed"
	watch.serial = nextSerial
	watch.armedClock = os.clock()
	watch.nextGate = START_GATE
	watch.crossings = {}
	local best = knownBest(watch.player, DragStrip.weekKey(os.time()))
	send(watch.player, {
		state = "armed",
		message = DragStrip.messages.armed,
		best = if best ~= nil then DragStrip.toSeconds(best) else nil,
	})
end

-- Voids an armed or running run and tells the driver why. The car goes back to "staged": if it is still behind
-- the line it can arm again by stopping; otherwise the next sample stops watching it.
local function void(watch: Watch, fault: DragStrip.Fault)
	if watch.phase ~= "armed" and watch.phase ~= "running" and watch.phase ~= "finishing" then
		return
	end
	watch.phase = "staged"
	watch.stillSince = nil
	watch.crossings = {}
	watch.nextGate = START_GATE
	send(watch.player, { state = "fault", message = DragStrip.messages.faults[fault] })
end

-- True when the server moved the car since its run armed.
local function movedSinceArmed(watch: Watch): boolean
	local moved = AntiExploitService.lastServerMove(watch.model)
	return moved ~= nil and moved >= watch.armedClock
end

local recordRun: (watch: Watch) -> ()

-- The finish line was crossed: wait for anti-exploit to have its say, then count the run.
local function finish(watch: Watch)
	watch.phase = "finishing"
	local serial = watch.serial
	task.delay(DragStrip.finishConfirmSeconds, function()
		if watches[watch.model] ~= watch or watch.phase ~= "finishing" or watch.serial ~= serial then
			return -- voided while waiting, or the car is gone
		end
		unwatch(watch)
		if movedSinceArmed(watch) then
			send(watch.player, { state = "fault", message = DragStrip.messages.faults.teleport })
			return
		end
		recordRun(watch)
	end)
end

step = function(watch: Watch, now: number)
	local model, chassis = watch.model, watch.chassis
	if model.Parent == nil or chassis.Parent ~= model or watch.player.Parent == nil then
		unwatch(watch)
		return
	end
	if watch.phase == "finishing" then
		return -- waiting for the confirmation; nothing about the car matters now
	end

	local start = gates[START_GATE]
	local cframe = chassis.CFrame
	local front = DragStrip.frontPoint(cframe, chassis.Size)
	local velocity = chassis:GetVelocityAtPosition(front)
	local frontPast = DragStrip.distancePast(start, front)
	local lateral = DragStrip.lateral(start, cframe.Position)
	local driving = drivenByOwner(watch)
	local ability = model:GetAttribute(ABILITY_ATTRIBUTE) ~= nil

	local previous = watch.previous
	-- The server's view of a client-driven car arrives in bunches: a frame where a moving car hasn't moved brings
	-- no new data, so the previous sample keeps its own (truer) time.
	local fresh = previous == nil or front ~= previous.front or velocity.Magnitude < DragStrip.staging.stillSpeed
	if fresh then
		watch.previous = { time = now, front = front, velocity = velocity }
	end

	if watch.phase == "staged" then
		if not driving or not DragStrip.staysStaged(frontPast, lateral, start.halfWidth) then
			unwatch(watch)
			return
		end
		local canArm = DragStrip.canArm({
			frontPast = frontPast,
			lateral = lateral,
			halfWidth = start.halfWidth,
			speed = chassis.AssemblyLinearVelocity.Magnitude,
			ability = ability,
			driving = driving,
		})
		if not canArm then
			watch.stillSince = nil
		elseif watch.stillSince == nil then
			watch.stillSince = now
		elseif now - (watch.stillSince :: number) >= DragStrip.staging.stillSeconds then
			arm(watch)
		end
		return
	end

	local jumped = previous ~= nil
		and DragStrip.isJump(flatDistance(previous.front, front), now - previous.time, watch.topSpeed)
	local started = watch.crossings[START_GATE]
	local fault = DragStrip.faultFor({
		phase = if watch.phase == "running" then "running" else "armed",
		frontPast = frontPast,
		lateral = lateral,
		halfWidth = start.halfWidth,
		ability = ability,
		moved = movedSinceArmed(watch),
		jumped = jumped,
		driving = driving,
		elapsed = if started ~= nil then now - started else 0,
	})
	if fault ~= nil then
		void(watch, fault)
		return
	end
	if previous == nil or not fresh then
		return
	end

	local gate = gates[watch.nextGate]
	local crossed = DragStrip.crossingTime(
		previous.time,
		DragStrip.distancePast(gate, previous.front),
		previous.velocity:Dot(gate.normal),
		now,
		DragStrip.distancePast(gate, front),
		velocity:Dot(gate.normal)
	)
	if crossed == nil then
		return
	end
	watch.crossings[gate.index] = crossed
	if gate.index == START_GATE then
		watch.phase = "running"
		send(watch.player, { state = "running", gate = gate.index, startedAt = crossed })
	elseif gate.index < #gates then
		-- A split: seconds from the start line to this gate.
		local split = DragStrip.toSeconds(DragStrip.toMs(crossed - watch.crossings[START_GATE]))
		send(watch.player, { state = "running", gate = gate.index, time = split })
	end
	if watch.nextGate >= #gates then
		finish(watch)
	else
		watch.nextGate += 1
	end
end

-- A car the server moved is no longer on a fair run.
local function onServerMove(model: Model)
	local watch = watches[model]
	if watch ~= nil then
		void(watch, "teleport")
	end
end

-- A car's Driver seat filled: its owner may have sat in it while it stands in the staging area.
local function hookCar(child: Instance)
	if not child:IsA("Model") then
		return
	end
	local seats = child:FindFirstChild(SEATS_FOLDER)
	local seatPart = if seats ~= nil then seats:FindFirstChild(DRIVER_SEAT) else nil
	if seatPart == nil or not seatPart:IsA("Seat") then
		return
	end
	local seat = seatPart :: Seat
	seat:GetPropertyChangedSignal("Occupant"):Connect(function()
		if seat.Occupant ~= nil then
			consider(child)
		end
	end)
end

-- DataStores -------------------------------------------------------------------------------------------------

-- Waits until every listed request type has budget left, then runs `call` in pcall. Returns pcall's results,
-- or false and a reason when the budget never came.
local function withBudget(types: { Enum.DataStoreRequestType }, call: () -> ...any): (boolean, any)
	for attempt = 1, DragStrip.budgetMaxWaits do
		local ready = true
		for _, requestType in types do
			local ok, budget = pcall(function(): number
				return DataStoreService:GetRequestBudgetForRequestType(requestType)
			end)
			if not ok or budget < DragStrip.minRequestBudget then
				ready = false
				break
			end
		end
		if ready then
			return pcall(call)
		end
		if attempt < DragStrip.budgetMaxWaits then
			task.wait(DragStrip.budgetWaitSeconds)
		end
	end
	return false, "no DataStore request budget left"
end

-- A store call failed. In Studio (no API access, an unpublished place) the times move to this server's memory
-- for the session. On a live server the error is only logged.
local function storeFailed(what: string, why: any)
	if RunService:IsStudio() then
		if not useMemory then
			useMemory = true
			warn(`{LOG} DataStores can't be reached, so this session's drag times live in memory: {why}`)
		end
	else
		warn(`{LOG} {what} failed: {why}`)
	end
end

-- The week's OrderedDataStore, or nil when times live in memory.
local function storeFor(week: string): OrderedDataStore?
	if useMemory then
		return nil
	end
	local existing = stores[week]
	if existing ~= nil then
		return existing
	end
	local prefix = if RunService:IsStudio() then DragStrip.studioStorePrefix else DragStrip.storePrefix
	local ok, result = pcall(function(): OrderedDataStore
		return DataStoreService:GetOrderedDataStore(prefix .. week)
	end)
	if not ok then
		storeFailed("Opening the board", result)
		return nil
	end
	stores[week] = result
	return result
end

local function memoryBoard(week: string): { [number]: number }
	local board = memoryBoards[week]
	if board == nil then
		board = {}
		memoryBoards[week] = board
	end
	return board
end

-- Display names for these players: from the server for players here, else looked up once and remembered.
local function resolveNames(userIds: { number })
	local missing: { number } = {}
	for _, userId in userIds do
		local player = Players:GetPlayerByUserId(userId)
		if player ~= nil then
			names[userId] = player.DisplayName
		elseif names[userId] == nil then
			table.insert(missing, userId)
		end
	end
	if #missing == 0 then
		return
	end
	local ok, infos = pcall(function(): { any }
		return UserService:GetUserInfosByUserIdsAsync(missing)
	end)
	if not ok then
		warn(`{LOG} Couldn't look up names for the board: {infos}`)
		return
	end
	for _, info in infos do
		if type(info) == "table" and type(info.Id) == "number" and type(info.DisplayName) == "string" then
			names[info.Id] = info.DisplayName
		end
	end
end

local function nameOf(userId: number): string
	return names[userId] or DragStrip.fallbackName
end

-- The board --------------------------------------------------------------------------------------------------

local function renderBoard()
	local labels = boardLabels
	if labels == nil then
		return
	end
	local weekNumber = DragStrip.weekNumber(page.week)
	labels.week.Text = if weekNumber ~= nil then string.format(DragStrip.messages.board.week, weekNumber) else ""
	labels.empty.Visible = #page.entries == 0
	for index, row in labels.rows do
		local entry = page.entries[index]
		row.frame.Visible = entry ~= nil
		if entry ~= nil then
			row.name.Text = nameOf(entry.userId)
			row.time.Text = DragStrip.formatTime(DragStrip.toSeconds(entry.ms))
		end
	end
end

-- Reads the week's fastest times (at most DragStrip.rankPageSize) unless the last read is fresh enough, and
-- updates the board. Returns the page as it now stands; a read already under way returns the current page.
local function refreshPage(force: boolean): Page
	local week = DragStrip.weekKey(os.time())
	local fresh = page.week == week and os.clock() - page.at < DragStrip.cacheSeconds
	if (fresh and not force) or refreshing then
		return page
	end
	refreshing = true
	local entries: { DragStrip.Entry }? = nil
	local store = storeFor(week)
	if store ~= nil then
		local dataStore = store
		local ok, result = withBudget({ Enum.DataStoreRequestType.GetSortedAsync }, function(): any
			return dataStore:GetSortedAsync(true, DragStrip.rankPageSize):GetCurrentPage()
		end)
		if ok and type(result) == "table" then
			local list: { DragStrip.Entry } = {}
			for _, item in result do
				local userId = tonumber(item.key)
				if userId ~= nil and type(item.value) == "number" then
					table.insert(list, { userId = userId, ms = item.value })
				end
			end
			entries = list
		else
			storeFailed("Reading the board", result)
		end
	end
	if entries == nil and useMemory then
		local list: { DragStrip.Entry } = {}
		for userId, ms in memoryBoard(week) do
			list = DragStrip.mergeEntry(list, userId, ms, DragStrip.rankPageSize)
		end
		entries = list
	end
	if entries ~= nil then
		local shown: { number } = {}
		for index = 1, math.min(DragStrip.boardSize, #entries) do
			table.insert(shown, entries[index].userId)
		end
		resolveNames(shown)
		page = { week = week, at = os.clock(), entries = entries }
	elseif page.week ~= week then
		page = { week = week, at = -math.huge, entries = {} } -- a new week with nothing read yet
	end
	refreshing = false
	renderBoard()
	return page
end

-- Re-reads the board every DragStrip.refreshSeconds while anyone is in the server (times from other servers).
local function scheduleRefresh()
	task.delay(DragStrip.refreshSeconds, function()
		if #Players:GetPlayers() > 0 then
			refreshPage(true)
		end
		scheduleRefresh()
	end)
end

-- Personal bests ---------------------------------------------------------------------------------------------

-- The player's best this week in milliseconds (nil = none yet), reading the store if this server doesn't know
-- it. The second result is false when it couldn't be read.
local function loadBest(player: Player, week: string): (number?, boolean)
	local userId = player.UserId
	local known = bests[userId]
	if known ~= nil and known.week == week then
		return known.ms, true
	end
	local store = storeFor(week)
	if store == nil then
		local ms = if useMemory then memoryBoard(week)[userId] else nil
		bests[userId] = { week = week, ms = ms }
		return ms, useMemory
	end
	local dataStore = store
	local ok, value = withBudget({ Enum.DataStoreRequestType.GetAsync }, function(): any
		return dataStore:GetAsync(tostring(userId))
	end)
	if not ok then
		storeFailed("Reading a best time", value)
		return nil, false
	end
	local ms = if type(value) == "number" then value else nil
	-- The read yielded: a player who left meanwhile was already forgotten, and caching them now would never clear.
	if player.Parent ~= nil then
		bests[userId] = { week = week, ms = ms }
	end
	return ms, true
end

-- Saves `ms` as the player's time this week if it is their best. Returns their best afterwards (ms), whether
-- this run set it, and whether the board could be reached.
local function submit(player: Player, ms: number): (number?, boolean, boolean)
	local week = DragStrip.weekKey(os.time())
	local userId = player.UserId
	local store = storeFor(week)
	local best: number? = nil
	local isNew = false
	local saved = false
	if store ~= nil then
		local dataStore = store
		local ok, err = withBudget({
			Enum.DataStoreRequestType.GetAsync,
			Enum.DataStoreRequestType.UpdateAsync,
			Enum.DataStoreRequestType.SetIncrementSortedAsync,
		}, function()
			dataStore:UpdateAsync(tostring(userId), function(old: any): any
				-- May run more than once; the last run is the one that counts.
				local current = if type(old) == "number" then old else nil
				isNew = DragStrip.isPersonalBest(current, ms)
				best = if isNew then ms else current
				return if isNew then ms else nil -- nil cancels the write
			end)
		end)
		if ok then
			saved = true
		else
			storeFailed("Saving a time", err)
		end
	end
	if not saved and useMemory then
		local board = memoryBoard(week)
		local current = board[userId]
		isNew = DragStrip.isPersonalBest(current, ms)
		if isNew then
			board[userId] = ms
		end
		best = if isNew then ms else current
		saved = true
	end
	if not saved then
		return knownBest(player, week), false, false
	end
	bests[userId] = { week = week, ms = best }
	if isNew and page.week == week then
		-- Show the new time straight away; the next read brings in other servers' times.
		page = {
			week = week,
			at = page.at,
			entries = DragStrip.mergeEntry(page.entries, userId, ms, DragStrip.rankPageSize),
		}
		resolveNames({ userId })
		renderBoard()
	end
	return best, isNew, true
end

-- Counts a confirmed run: tells the driver their time, and saves it when it's their best this week.
recordRun = function(watch: Watch)
	local player = watch.player
	local startedAt = watch.crossings[START_GATE]
	local finishedAt = watch.crossings[#gates]
	local seconds = finishedAt - startedAt
	local ms = DragStrip.toMs(seconds)
	local splits: { number } = {}
	-- No quicker than this car could possibly be, over the whole run and at every split.
	local plausible = DragStrip.isPlausible(seconds, watch.fastest[#gates])
	for index = START_GATE + 1, #gates - 1 do
		local at = watch.crossings[index]
		if at ~= nil then
			table.insert(splits, DragStrip.toSeconds(DragStrip.toMs(at - startedAt)))
			plausible = plausible and DragStrip.isPlausible(at - startedAt, watch.fastest[index], true)
		end
	end
	local messages = DragStrip.messages
	local lines = { string.format(messages.finished, DragStrip.formatTime(DragStrip.toSeconds(ms))) }
	local payload: { [string]: any } = {
		state = "finished",
		time = DragStrip.toSeconds(ms),
		splits = splits,
		startedAt = startedAt,
		finishedAt = finishedAt,
		newBest = false,
	}
	if not plausible then
		local splitText = table.concat(splits, ", ")
		warn(`{LOG} {player.Name} ({player.UserId}): a {seconds} s run (splits {splitText}) is impossible; not saved`)
		table.insert(lines, messages.implausible)
	elseif watch.testDrive then
		table.insert(lines, messages.testDrive)
	else
		local best, isNew, saved = submit(player, ms)
		payload.newBest = isNew
		payload.best = if best ~= nil then DragStrip.toSeconds(best) else nil
		local rank = DragStrip.rankOf(page.entries, player.UserId)
		payload.rank = rank
		if not saved then
			table.insert(lines, messages.notSaved)
		elseif isNew then
			table.insert(lines, messages.newBest)
		end
		if saved and rank ~= nil then
			table.insert(lines, string.format(messages.rank, rank))
		end
	end
	payload.message = table.concat(lines, " ")
	send(player, payload)
end

-- GetDragLeaderboard -----------------------------------------------------------------------------------------

local function getLeaderboard(player: Player): Leaderboard
	local current = refreshPage(false)
	local entries: { { name: string, time: number } } = {}
	for index = 1, math.min(DragStrip.boardSize, #current.entries) do
		local entry = current.entries[index]
		table.insert(entries, { name = nameOf(entry.userId), time = DragStrip.toSeconds(entry.ms) })
	end
	local rank = DragStrip.rankOf(current.entries, player.UserId)
	local best: number?
	if rank ~= nil then
		best = current.entries[rank].ms
	else
		best = loadBest(player, current.week)
	end
	return {
		week = current.week,
		entries = entries,
		best = if best ~= nil then DragStrip.toSeconds(best) else nil,
		rank = rank,
	}
end

-- Building Workspace.DragStrip -------------------------------------------------------------------------------

local function newPart(name: string, size: Vector3, cframe: CFrame, parent: Instance): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.CFrame = cframe
	part.Anchored = true
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = parent
	return part
end

-- The invisible touch sensor over the staging area behind gate 1.
local function buildSensor(folder: Instance): Part
	local start = gates[START_GATE]
	local staging = DragStrip.staging
	local length = staging.depth + staging.sensorTail
	local center = start.origin - start.normal * (length / 2) + Vector3.yAxis * (staging.sensorHeight / 2)
	local sensor = newPart(
		SENSOR_NAME,
		Vector3.new(start.halfWidth * 2, staging.sensorHeight, length),
		CFrame.lookAt(center, center + start.normal),
		folder
	)
	sensor.Transparency = 1
	sensor.CanCollide = false
	sensor.CanQuery = false -- raycasts and overlap queries go straight through
	sensor.CanTouch = true
	sensor.CastShadow = false
	sensor.Touched:Connect(function(hit: BasePart)
		if hit.Name == CHASSIS then
			consider(hit.Parent)
		end
	end)
	return sensor
end

local function label(name: string, text: string, size: number, font: Font, color: Color3, parent: Instance): TextLabel
	local textLabel = Instance.new("TextLabel")
	textLabel.Name = name
	textLabel.BackgroundTransparency = 1
	textLabel.Text = text
	textLabel.TextSize = size
	textLabel.FontFace = font
	textLabel.TextColor3 = color
	textLabel.TextXAlignment = Enum.TextXAlignment.Left
	textLabel.TextTruncate = Enum.TextTruncate.AtEnd
	textLabel.Size = UDim2.new(1, 0, 0, size)
	textLabel.Parent = parent
	return textLabel
end

-- The board beside the strip, facing the staging lane: a panel on two posts with the week's top times.
local function buildBoard(folder: Instance): BoardLabels
	local config = DragStrip.board
	local theme = Controls.theme
	local text = DragStrip.messages.board
	local start = gates[START_GATE]

	local base = start.origin + start.normal * config.along + start.right * config.across
	local ground = Vector3.new(base.X, MapLayout.groundHeight(base.X, base.Z), base.Z)
	local target = start.origin + start.normal * config.lookAlong
	local facing = CFrame.lookAt(ground, Vector3.new(target.X, ground.Y, target.Z))

	local model = Instance.new("Model")
	model.Name = BOARD_NAME
	local panelSize = config.panelSize
	local panel = newPart("Panel", panelSize, facing * CFrame.new(0, config.clearance + panelSize.Y / 2, 0), model)
	panel.Color = theme.panel
	panel.Material = Enum.Material.SmoothPlastic
	local postHeight = config.clearance + panelSize.Y
	for _, side in { -1, 1 } do
		local x = side * (panelSize.X / 2 - config.postWidth / 2)
		local z = panelSize.Z / 2 + config.postWidth / 2 -- behind the panel, clear of its face
		local post = newPart(
			if side < 0 then "PostLeft" else "PostRight",
			Vector3.new(config.postWidth, postHeight, config.postWidth),
			facing * CFrame.new(x, postHeight / 2, z),
			model
		)
		post.Color = theme.panelRaised
		post.Material = Enum.Material.Metal
	end
	model.PrimaryPart = panel
	model.Parent = folder

	local gui = Instance.new("SurfaceGui")
	gui.Name = "Board"
	gui.Face = Enum.NormalId.Front -- the panel's front faces the staging lane
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = config.pixelsPerStud
	gui.LightInfluence = 0 -- readable by night too
	gui.Parent = panel

	local content = Instance.new("Frame")
	content.Name = "Content"
	content.Size = UDim2.fromScale(1, 1)
	content.BackgroundTransparency = 1
	content.Parent = gui
	local padding = Instance.new("UIPadding")
	for _, side in { "PaddingTop", "PaddingBottom", "PaddingLeft", "PaddingRight" } do
		(padding :: any)[side] = UDim.new(0, config.padding)
	end
	padding.Parent = content
	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, config.gap)
	layout.Parent = content

	local order = 0
	local function nextOrder(): number
		order += 1
		return order
	end

	local header = Instance.new("Frame")
	header.Name = "Header"
	header.BackgroundTransparency = 1
	header.Size = UDim2.new(1, 0, 0, config.titleSize)
	header.LayoutOrder = nextOrder()
	header.Parent = content
	label("Title", text.title, config.titleSize, theme.fonts.bold, theme.text, header)
	local week = label("Week", "", config.subtitleSize, theme.fonts.medium, theme.accent, header)
	week.TextXAlignment = Enum.TextXAlignment.Right
	week.AnchorPoint = Vector2.new(0, 0.5)
	week.Position = UDim2.fromScale(0, 0.5)

	label("Subtitle", text.subtitle, config.subtitleSize, theme.fonts.regular, theme.textDim, content).LayoutOrder =
		nextOrder()

	local empty = label("Empty", text.empty, config.rowTextSize, theme.fonts.medium, theme.text, content)
	empty.Size = UDim2.new(1, 0, 0, config.rowHeight)
	empty.LayoutOrder = nextOrder()

	local rows: { { frame: Frame, name: TextLabel, time: TextLabel } } = {}
	for index = 1, DragStrip.boardSize do
		local row = Instance.new("Frame")
		row.Name = `Row{index}`
		row.BackgroundTransparency = 1
		row.Size = UDim2.new(1, 0, 0, config.rowHeight)
		row.LayoutOrder = nextOrder()
		row.Visible = false
		row.Parent = content
		local rank =
			label("Rank", string.format(text.row, index), config.rowTextSize, theme.fonts.medium, theme.textDim, row)
		rank.Size = UDim2.new(0, config.rankWidth, 1, 0)
		local name = label("Name", "", config.rowTextSize, theme.fonts.medium, theme.text, row)
		name.Position = UDim2.fromOffset(config.rankWidth, 0)
		name.Size = UDim2.new(1, -(config.rankWidth + config.timeWidth), 1, 0)
		local timeLabel = label("Time", "", config.rowTextSize, theme.fonts.bold, theme.text, row)
		timeLabel.AnchorPoint = Vector2.new(1, 0)
		timeLabel.Position = UDim2.fromScale(1, 0)
		timeLabel.Size = UDim2.new(0, config.timeWidth, 1, 0)
		timeLabel.TextXAlignment = Enum.TextXAlignment.Right
		table.insert(rows, { frame = row, name = name, time = timeLabel })
	end

	label("Footer", text.footer, config.footerSize, theme.fonts.regular, theme.textDim, content).LayoutOrder =
		nextOrder()

	return { week = week, empty = empty, rows = rows }
end

-- Boot -------------------------------------------------------------------------------------------------------

function DragStripService:Init()
	gates = DragStrip.gates()
	assert(
		#gates == DragStrip.gateCount,
		`{LOG} Config/MapLayout has {#gates} drag-strip gates, not {DragStrip.gateCount}`
	)
end

function DragStripService:Start()
	local existing = Workspace:FindFirstChild(DragStrip.board.folderName)
	if existing ~= nil then
		existing:Destroy()
	end
	local folder = Instance.new("Folder")
	folder.Name = DragStrip.board.folderName
	buildSensor(folder)
	boardLabels = buildBoard(folder)
	folder.Parent = Workspace

	vehiclesFolder = Workspace:FindFirstChild(Spawning.vehiclesFolder)
	local cars = vehiclesFolder
	if cars ~= nil then
		cars.ChildAdded:Connect(hookCar)
		for _, child in cars:GetChildren() do
			hookCar(child)
		end
	else
		warn(`{LOG} Workspace.{Spawning.vehiclesFolder} is missing, so cars that start behind the line aren't seen`)
	end

	AntiExploitService.onServerMove(onServerMove)
	Net.onServerInvoke("GetDragLeaderboard", getLeaderboard)
	Players.PlayerRemoving:Connect(function(leaving: Player)
		bests[leaving.UserId] = nil
		for _, watch in table.clone(watches) do
			if watch.player == leaving then
				unwatch(watch)
			end
		end
	end)

	task.spawn(refreshPage, true)
	scheduleRefresh()
end

return DragStripService
