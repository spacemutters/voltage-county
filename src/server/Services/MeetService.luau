--!strict
-- Car meets at MeetSpots (PLAN.md Phase 13; docs/phase-13-contracts.md "Social").
--
-- When Config/Social meet.minCars (4) players' cars stand parked inside one MeetSpot's footprint, the meet is
-- announced once to everyone: a Feed entry (Net FeedUpdate { id, kind = "meet", text, at, meetSpotId, cars }) that
-- every client lists in the phone's Feed and shows as a toast. Three cars is not a meet. The spot is not announced
-- again until the count has dropped below minCars and stayed below for meet.cooldownSeconds; a meet that fills up
-- again sooner is the same meet carrying on (step below).
--
-- Which cars count: player cars (OwnerUserId, set by VehicleService) and, in Studio only, the DevSocial stand-ins,
-- one per player (two cars of one owner count once). A car counts while it is parked (MeetService.settled), owner
-- out or seated: its chassis is anchored (VehicleService's own parked state, from the moment the driver gets out or
-- before anyone first gets in), or it stands still with its driver in it (EnergyService's Config/Energy
-- attributes.still, which it sets from its own speed samples only when the car stops or moves off), or it is in a
-- light show (Config/LightShows attributes showId: LightShowService only takes still cars inside the footprint and
-- drops any that leave it). The car's pivot must stand in the footprint (Config/LightShows.insideFootprint, grown by
-- Config/Social meet.footprintMargin).
--
-- Event-driven, no polling (CLAUDE.md hard rule 10): cars are found by the CollectionService vehicle tag, and each
-- one is looked at again only when its chassis is anchored or let go (park, drive), it stops or moves off (Still),
-- it is moved while parked, joins or leaves a light show, or leaves the world (despawn, owner left). Each look
-- updates a ledger of which spot every car counts at; only the spots whose count changed are stepped.
--
-- The Feed: the server keeps the last Config/Social feed.maxEntries entries and sends them to each player who joins
-- (one FeedUpdate each, oldest first, with backlog = true so the client lists them without a toast).
--
-- Studio only (CLAUDE.md hard rule 8): Net DevSocial { action = "parkDummyCar" | "clearDummies", meetSpotId? }
-- parks an anchored stand-in car in the next free slot of a meet spot (default Config/Social dev.defaultMeetSpot)
-- or clears the stand-ins (at one spot, or everywhere), for Dev/SocialTests.meet. Returns { ok, message, count? }
-- (count: the cars counted at that spot now). Clearing also forgets the meets and cooldowns at the spots it clears,
-- so the test can run again straight away. For Dev/SocialTests.house, meetSpotId may also name a claimed HousePlot:
-- then the stand-in (a battery car, nobody's) stands on that house's home charger with its energy set below full
-- (Config/Social dev.homeEnergyLevel, through EnergyService.attach), and clearing with that plot's id (or none)
-- removes it. Refused outside Studio.
--
-- The pure parts (the ledger, step, settled, spotAt, announcement) are exported for tests/Meet.spec.

local CollectionService = game:GetService("CollectionService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local Catalog = require(Shared.Vehicle.Catalog)
local EnergyConfig = require(Shared.Config.Energy)
local Houses = require(Shared.Config.Houses)
local LightShows = require(Shared.Config.LightShows)
local MapLayout = require(Shared.Config.MapLayout)
local Net = require(Shared.Net)
local Social = require(Shared.Config.Social)
local Spawning = require(Shared.Config.Spawning)

local USER_PREFIX = "user:" -- ledger owner keys: a player's UserId
local DUMMY_PREFIX = "dummy:" -- or a Studio stand-in car's own serial (each stand-in is its own "player")
local OWNER_ATTRIBUTE = "OwnerUserId" -- VehicleService marks every player car with its owner
local STILL_ATTRIBUTE = EnergyConfig.attributes.still -- EnergyService: the car stands still

local meetConfig = Social.meet
local feedConfig = Social.feed
local dev = Social.dev

-- Which spot each car counts at (nil: none), and whose it is. Keys are car models (any value in specs).
type LedgerCar = { owner: string, spot: string? }
export type Ledger = { cars: { [any]: LedgerCar } }

-- One spot's meet: whether a meet is on, and when it last dropped below minCars (nil: there hasn't been one).
export type SpotState = { active: boolean, quietSince: number? }

export type Reply = { ok: boolean, message: string, count: number? }

type Tracked = {
	model: Model,
	chassis: BasePart,
	owner: string,
	connections: { RBXScriptConnection },
}

local MeetService = {}

local spots: { MapLayout.Location } = {}
local spotById: { [string]: MapLayout.Location } = {}
local plotById: { [string]: MapLayout.Location } = {} -- HousePlots, for the Studio stand-in on a home charger
local ledger: Ledger = { cars = {} }
local states: { [string]: SpotState } = {}
local tracked: { [Model]: Tracked } = {}
local recent: { Social.FeedEntry } = {} -- newest first
local dummySerial = 0

-- Pure: the ledger ----------------------------------------------------------------------------------------------

function MeetService.newLedger(): Ledger
	return { cars = {} }
end

-- Records that `car` (owned by `owner`) now counts at `spot` (nil: nowhere). Returns the spots whose count may have
-- changed (the one it left and the one it joined), empty when nothing moved.
function MeetService.place(book: Ledger, car: any, owner: string, spot: string?): { string }
	local previous = book.cars[car]
	local before = if previous then previous.spot else nil
	book.cars[car] = { owner = owner, spot = spot }
	local changed: { string } = {}
	if before ~= spot then
		if before ~= nil then
			table.insert(changed, before)
		end
		if spot ~= nil then
			table.insert(changed, spot)
		end
	end
	return changed
end

-- Forgets `car` (it left the world). Returns the spot it counted at, if any.
function MeetService.remove(book: Ledger, car: any): { string }
	local previous = book.cars[car]
	book.cars[car] = nil
	return if previous ~= nil and previous.spot ~= nil then { previous.spot } else {}
end

-- Forgets every car of `owner` (they left the game). Returns the spots they counted at.
function MeetService.removeOwner(book: Ledger, owner: string): { string }
	local changed: { string } = {}
	for car, entry in table.clone(book.cars) do
		if entry.owner == owner then
			book.cars[car] = nil
			if entry.spot ~= nil and not table.find(changed, entry.spot) then
				table.insert(changed, entry.spot)
			end
		end
	end
	return changed
end

-- The cars counted at `spot`: one per owner.
function MeetService.count(book: Ledger, spot: string): number
	local owners: { [string]: boolean } = {}
	local count = 0
	for _, entry in book.cars do
		if entry.spot == spot and not owners[entry.owner] then
			owners[entry.owner] = true
			count += 1
		end
	end
	return count
end

-- Pure: when a meet is announced ---------------------------------------------------------------------------------

function MeetService.newSpotState(): SpotState
	return { active = false, quietSince = nil }
end

-- The spot's next state for a new `count` at time `now` (seconds), and whether to announce a meet now. A meet is
-- announced when the count reaches Config/Social meet.minCars with no meet on, unless the last one there dropped
-- below minCars less than cooldownSeconds ago (then it is the same meet carrying on, and not announced again).
function MeetService.step(state: SpotState, count: number, now: number): (SpotState, boolean)
	if count >= meetConfig.minCars then
		if state.active then
			return state, false
		end
		local quiet = state.quietSince
		local fresh = quiet == nil or now - quiet >= meetConfig.cooldownSeconds
		return { active = true, quietSince = quiet }, fresh
	end
	if state.active then
		return { active = false, quietSince = now }, false
	end
	return state, false
end

-- Pure: which cars count ------------------------------------------------------------------------------------------

-- Whether a car counts as parked: its chassis is `anchored` (nobody drives it), it stands `still` with its driver in
-- it, or it is `inShow` (a light show, which only takes still cars).
function MeetService.settled(anchored: boolean, still: boolean, inShow: boolean): boolean
	return anchored or still or inShow
end

-- Pure: where a car stands ----------------------------------------------------------------------------------------

-- The meet spot whose footprint (grown by `margin` studs) holds `position` (a car's pivot), or nil.
function MeetService.spotAt(position: Vector3, list: { MapLayout.Location }, margin: number): string?
	for _, location in list do
		local frame = LightShows.footprintFrame(location.position, location.yaw)
		if LightShows.insideFootprint(frame, location.size, position, margin) then
			return location.id
		end
	end
	return nil
end

-- The Feed entry announcing a meet of `cars` cars at `location` (the words come from Config/Social, never from a
-- player, so nothing needs filtering).
function MeetService.announcement(location: MapLayout.Location, cars: number, id: string, at: number): Social.FeedEntry
	return {
		id = id,
		kind = feedConfig.kinds.meet,
		text = string.format(feedConfig.text.meetStarted, location.displayName, cars),
		at = at,
		meetSpotId = location.id,
		cars = cars,
	}
end

-- The feed ----------------------------------------------------------------------------------------------------------

local function remember(entry: Social.FeedEntry)
	table.insert(recent, 1, entry)
	while #recent > feedConfig.maxEntries do
		table.remove(recent)
	end
end

local function announce(location: MapLayout.Location, cars: number)
	local entry =
		MeetService.announcement(location, cars, HttpService:GenerateGUID(false), Workspace:GetServerTimeNow())
	remember(entry)
	Net.fireAllClients("FeedUpdate", entry)
end

-- Sends the recent entries to a player who just joined, oldest first, marked as backlog (no toast).
local function sendBacklog(player: Player)
	for index = #recent, 1, -1 do
		local entry = table.clone(recent[index]) :: any
		entry.backlog = true
		Net.fireClient("FeedUpdate", player, entry)
	end
end

-- Counting -----------------------------------------------------------------------------------------------------------

-- Steps every spot in `changed` with its new count, announcing any meet that starts.
local function refresh(changed: { string })
	local now = os.clock()
	for _, spotId in changed do
		local location = spotById[spotId]
		if location == nil then
			continue
		end
		local count = MeetService.count(ledger, spotId)
		local nextState, fire = MeetService.step(states[spotId] or MeetService.newSpotState(), count, now)
		states[spotId] = nextState
		if fire then
			announce(location, count)
		end
	end
end

-- The ledger owner key of a car, or nil when it isn't a car that counts (light-show test cars, job props).
local function ownerKeyOf(model: Model): string?
	local userId = model:GetAttribute(OWNER_ATTRIBUTE)
	if type(userId) == "number" then
		return USER_PREFIX .. tostring(userId)
	end
	if model:GetAttribute(dev.dummyAttribute) == true and RunService:IsStudio() then
		dummySerial += 1
		return DUMMY_PREFIX .. tostring(dummySerial)
	end
	return nil
end

-- Looks at one car again: is it parked (or in a light show), and in which spot's footprint.
local function evaluate(entry: Tracked)
	if tracked[entry.model] ~= entry then
		return
	end
	local model, chassis = entry.model, entry.chassis
	local settled = MeetService.settled(
		chassis.Anchored,
		model:GetAttribute(STILL_ATTRIBUTE) == true,
		model:GetAttribute(LightShows.attributes.showId) ~= nil
	)
	local spot = if settled and model:IsDescendantOf(Workspace)
		then MeetService.spotAt(model:GetPivot().Position, spots, meetConfig.footprintMargin)
		else nil
	refresh(MeetService.place(ledger, model, entry.owner, spot))
end

local function untrack(model: Model)
	local entry = tracked[model]
	if entry == nil then
		return
	end
	tracked[model] = nil
	for _, connection in entry.connections do
		connection:Disconnect()
	end
	refresh(MeetService.remove(ledger, model))
end

local function track(instance: Instance)
	if not instance:IsA("Model") or tracked[instance] ~= nil then
		return
	end
	local model = instance :: Model
	local chassis = model.PrimaryPart
	if chassis == nil then
		return
	end
	local owner = ownerKeyOf(model)
	if owner == nil then
		return
	end
	local entry: Tracked = { model = model, chassis = chassis, owner = owner, connections = {} }
	tracked[model] = entry
	local function look()
		evaluate(entry)
	end
	table.insert(entry.connections, chassis:GetPropertyChangedSignal("Anchored"):Connect(look))
	-- A driver stopping in it or moving off (EnergyService sets this only when it flips).
	table.insert(entry.connections, model:GetAttributeChangedSignal(STILL_ATTRIBUTE):Connect(look))
	-- Only a script moves an anchored chassis (physics never fires this), so this is a parked car being moved.
	table.insert(
		entry.connections,
		chassis:GetPropertyChangedSignal("CFrame"):Connect(function()
			if chassis.Anchored then
				look()
			end
		end)
	)
	table.insert(entry.connections, model:GetAttributeChangedSignal(LightShows.attributes.showId):Connect(look))
	table.insert(
		entry.connections,
		model.AncestryChanged:Connect(function()
			if model:IsDescendantOf(Workspace) then
				look()
			else
				untrack(model)
			end
		end)
	)
	look()
end

-- Studio stand-in cars (DevSocial) -------------------------------------------------------------------------------------

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

-- True when any car's pivot stands within dev.takenRadius of `frame` (across the ground).
local function slotTaken(frame: CFrame): boolean
	for _, instance in CollectionService:GetTagged(Spawning.vehicleTag) do
		if instance:IsA("Model") and instance:IsDescendantOf(Workspace) then
			local offset = instance:GetPivot().Position - frame.Position
			if Vector3.new(offset.X, 0, offset.Z).Magnitude < dev.takenRadius then
				return true
			end
		end
	end
	return false
end

-- A parked stand-in car at `frame` (anchored, seats off, tagged like a real car, nobody's), or nil when its model isn't
-- built. `vehicleId` defaults to the next of Config/Social dev.vehicles.
local function spawnDummy(frame: CFrame, vehicleId: string?): Model?
	local list = dev.vehicles
	local chosen = vehicleId or list[dummySerial % #list + 1]
	local trim = Catalog.defaultTrim(chosen)
	local folder = ServerStorage:FindFirstChild(Spawning.modelsFolder)
	local template = if folder and trim then folder:FindFirstChild(Catalog.modelName(chosen, trim.id)) else nil
	if template == nil or not template:IsA("Model") or template.PrimaryPart == nil then
		return nil
	end
	local model = template:Clone()
	local chassis = model.PrimaryPart :: BasePart
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Anchored = false
		end
		if descendant:IsA("Seat") then
			descendant.Disabled = true -- nobody sits in a stand-in
		end
	end
	chassis.Anchored = true -- everything else is welded to it
	model:SetAttribute(dev.dummyAttribute, true)
	model:AddTag(Spawning.vehicleTag)
	model:PivotTo(groundUnder(frame))
	local vehicles = Workspace:FindFirstChild(Spawning.vehiclesFolder)
	model.Parent = if vehicles then vehicles else Workspace
	return model
end

-- Puts a stand-in's energy below full (dev.homeEnergyLevel) once EnergyService samples it: it starts every car that
-- isn't a garage car full, so the level is set after it has marked the car (dev.energyKindAttribute).
local function lowerEnergy(model: Model)
	local energyService = require(script.Parent.EnergyService) :: any
	local function attach()
		energyService.attach(model, dev.homeEnergyLevel)
	end
	if model:GetAttribute(dev.energyKindAttribute) ~= nil then
		attach()
		return
	end
	local connection: RBXScriptConnection? = nil
	connection = model:GetAttributeChangedSignal(dev.energyKindAttribute):Connect(function()
		if connection ~= nil then
			connection:Disconnect()
		end
		attach()
	end)
end

-- The home charger pad of the house built on plot `plotId` (Workspace.<Config/Houses folderName>.<plotId>), or nil
-- while nobody has claimed it.
local function homeChargerOf(plotId: string): BasePart?
	local houses = Workspace:FindFirstChild(Houses.folderName)
	local plot = if houses then houses:FindFirstChild(plotId) else nil
	if plot == nil then
		return nil
	end
	local named: BasePart? = nil
	for _, descendant in plot:GetDescendants() do
		if descendant:IsA("BasePart") then
			if descendant:HasTag(Houses.charger.tag) then
				return descendant
			elseif named == nil and descendant.Name == Houses.chargerPad.name then
				named = descendant
			end
		end
	end
	return named
end

-- A stand-in on the home charger of a claimed house, below full: nobody's car, so it must not charge there.
local function parkAtHome(location: MapLayout.Location): Reply
	local pad = homeChargerOf(location.id)
	if pad == nil then
		return { ok = false, message = string.format(dev.messages.noHouse, location.displayName) }
	end
	local model = spawnDummy(pad.CFrame, dev.homeVehicle)
	if model == nil then
		return { ok = false, message = dev.messages.noModel }
	end
	lowerEnergy(model)
	track(model) -- not at a meet spot, so it counts nowhere; tracked so clearDummies finds it like the others
	return { ok = true, message = string.format(dev.messages.parkedHome, location.displayName) }
end

local function parkDummy(spotId: string): Reply
	local plot = plotById[spotId]
	if plot ~= nil then
		return parkAtHome(plot)
	end
	local location = spotById[spotId]
	if location == nil then
		return { ok = false, message = string.format(dev.messages.noSpot, spotId) }
	end
	local frame = LightShows.footprintFrame(location.position, location.yaw)
	for _, slot in LightShows.slotFrames(frame, location.size) do
		if slotTaken(slot) then
			continue
		end
		local model = spawnDummy(slot)
		if model == nil then
			return { ok = false, message = dev.messages.noModel }
		end
		track(model) -- now, not when the tag signal arrives, so the count (and any announcement) is current
		local count = MeetService.count(ledger, spotId)
		return { ok = true, message = string.format(dev.messages.parked, location.displayName, count), count = count }
	end
	return { ok = false, message = string.format(dev.messages.full, location.displayName) }
end

local function clearDummies(spotId: string?): Reply
	local plot = if spotId ~= nil then plotById[spotId] else nil
	if spotId ~= nil and spotById[spotId] == nil and plot == nil then
		return { ok = false, message = string.format(dev.messages.noSpot, spotId) }
	end
	local plotFrame = if plot ~= nil then LightShows.footprintFrame(plot.position, plot.yaw) else nil
	local cleared = 0
	for _, instance in CollectionService:GetTagged(Spawning.vehicleTag) do
		if not instance:IsA("Model") or instance:GetAttribute(dev.dummyAttribute) ~= true then
			continue
		end
		local entry = ledger.cars[instance]
		local here = if plot ~= nil and plotFrame ~= nil
			then LightShows.insideFootprint(
				plotFrame,
				plot.size,
				instance:GetPivot().Position,
				meetConfig.footprintMargin
			)
			else entry ~= nil and entry.spot == spotId
		if spotId == nil or here then
			untrack(instance) -- before destroying, so the counts are right when this returns
			instance:Destroy()
			cleared += 1
		end
	end
	-- Forget the cleared spots' meets and cooldowns, so the meet test can run again at once.
	for id in spotById do
		if spotId == nil or id == spotId then
			local count = MeetService.count(ledger, id)
			states[id] = { active = count >= meetConfig.minCars, quietSince = nil }
		end
	end
	local reply: Reply = { ok = true, message = string.format(dev.messages.cleared, cleared) }
	if spotId ~= nil then
		reply.count = MeetService.count(ledger, spotId)
	end
	return reply
end

local function onDevSocial(_player: Player, payload: any): Reply
	if not RunService:IsStudio() then
		return { ok = false, message = dev.messages.studioOnly } -- dev tools stay dev (CLAUDE.md hard rule 8)
	end
	local spotId: string? = payload.meetSpotId
	if payload.action == "parkDummyCar" then
		return parkDummy(spotId or dev.defaultMeetSpot)
	end
	return clearDummies(spotId)
end

-- Boot --------------------------------------------------------------------------------------------------------------

function MeetService:Init()
	for _, location in MapLayout.locations do
		if location.tag == meetConfig.spotTag then
			table.insert(spots, location)
			spotById[location.id] = location
			states[location.id] = MeetService.newSpotState()
		elseif location.tag == dev.housePlotTag then
			plotById[location.id] = location
		end
	end
end

function MeetService:Start()
	-- Always listen, so the remote never queues up; the handler itself refuses outside Studio.
	Net.onServerInvoke("DevSocial", onDevSocial)

	local tag = Spawning.vehicleTag
	CollectionService:GetInstanceAddedSignal(tag):Connect(track)
	CollectionService:GetInstanceRemovedSignal(tag):Connect(function(instance: Instance)
		if instance:IsA("Model") then
			untrack(instance)
		end
	end)
	for _, instance in CollectionService:GetTagged(tag) do
		track(instance)
	end

	Players.PlayerAdded:Connect(sendBacklog)
	Players.PlayerRemoving:Connect(function(player: Player)
		-- VehicleService despawns their car too (which untracks it); this drops it from the count at once.
		refresh(MeetService.removeOwner(ledger, USER_PREFIX .. tostring(player.UserId)))
	end)
end

return MeetService
