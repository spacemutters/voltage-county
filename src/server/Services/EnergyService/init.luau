--!strict
-- Energy: every spawned car's battery or tank, charging and fueling, low-energy alerts and limp mode (PLAN.md
-- §3.3 and Phase 5; docs/phase-5-contracts.md "Server").
--
-- Server-authoritative (CLAUDE.md hard rule 1): the server owns each car's level and decides drain, charging,
-- costs and limp mode from what it observes. Clients only show the level (car attributes) and obey limp mode,
-- which AntiExploit enforces here too.
--
-- Which cars: every car in Workspace.Vehicles (VehicleService spawns them there) whose trim has energyMinutes.
-- Display cars stand in Workspace.Showroom and are never sampled. A garage car (attribute OwnedUid) starts at its
-- saved level, which GarageService puts on the car as the `Energy` attribute when it brings the car out
-- (EnergyService.attach); a temporary car (a test drive or a dev spawn) starts full and is never saved.
--
-- Sampling: one Heartbeat with an accumulator samples every car once per Config/Energy.sampling.interval. Each
-- sample reads the chassis as the server sees it (position and replicated velocity), keeps the last few samples
-- per car, and turns them into speed, acceleration and climb (Rules.measure: the velocity counts only while it
-- agrees with the ground the car really covers). Then, in order:
--   station  a car that is nearly still with its chassis over a ChargerStall, TruckCharger or FuelPump pad
--            (tagged parts under Workspace.Map.Generated.Locations, matched in the pad's own axes), with at
--            least Config charging.startBelow missing, charges or fuels: Energy.chargeRatePerSecond per second,
--            billed for the energy added in whole dollars through EconomyService.trySpend (reason "charge" or
--            "fuel"; cents carry over within the stop); it stops at full, when the car leaves the pad, or with a
--            notice once the player can't pay for more (they get what their cash covers first, and it doesn't
--            restart on that pad until the car has left it). While it runs the car carries Charging = true,
--            ChargeRate (fraction per second) and Config/Energy attributes.chargeCostPerFull (the stop's price per
--            full charge) for the client's charging card. A car on the wrong kind of pad, or
--            a dealership test drive on any pad, gets one friendly notice per visit and no charge.
--   drain    otherwise a car with someone in its Driver seat drains Energy.drainPerSecond. A car with nobody in
--            the Driver seat is parked (VehicleService anchors it): it is switched off and drains nothing, not
--            even the idle trickle, so a car left at a meet or by the road keeps its level. Idle drain applies to
--            a car someone sits in while it stands still. A move the server made (a reset; AntiExploitService
--            .lastServerMove) or a respawn drains nothing; any other jump is billed as the travel it is.
--   publish  `Energy` (0..1, rounded to Config sampling.attributeStep) and `EnergyKind` ("battery" | "fuel"), and
--            Config/Energy attributes.still (true at or under sampling.stationStillMph; set only when it flips).
--   limp     at 0 the car gets Limp = true (the client caps its speed at Config/Energy.limpMph); it clears once
--            the level is above limpClearLevel. AntiExploit judges the car by the limp speed
--            (AntiExploitService.setTopSpeed) once it has slowed to it, at once when it is parked, and at the
--            latest Config limpCapGraceSeconds after limp mode began, so a car that runs dry at speed isn't
--            flagged while it slows down and a client that ignores limp mode isn't let off; the catalog top
--            speed is restored when limp clears.
--   alerts   a notice when the level drops to Config warningLevel and criticalLevel (once per drop), and at 0 a
--            notice plus Net EnergyAlert { level, stationId } with the compatible station nearest by road
--            (MapLayout + Pathfind), so the client's GPS leads there.
--   save     a garage car's level is written to its OwnedVehicle.energy at most once per Config
--            sampling.saveInterval while it changes, and always when the car is put away (GarageService calls
--            persistPlayer first), when it leaves the world any other way, and when the player leaves or the
--            server closes (DataService.beforeRelease, while the player's session is still open).
-- While at least hangout.minPlayers different players charge at stalls of the same plaza, each of them earns
-- the hangout bonus for that time; it is paid every Config/Energy hangout.interval seconds (EconomyService.add,
-- reason "hangout").
--
-- Home chargers (Phase 13, docs/phase-13-contracts.md "Houses"): Services/HouseService paints a charger bay on the
-- floor of every claimed house's garage, tagged Config/Houses charger.tag (under Workspace.Houses, outside the
-- map) with the owner's UserId, its kW and its price per full charge as attributes. A car standing on one charges
-- like a ChargerStall of that kW, at that price (never above Config/Energy home.costPerFull), but only when it is
-- the owner's own car (Rules.homeChargeAllowed): anyone else's car, a test drive or a car with no owner gets one
-- friendly notice per visit (owners only) and no charge. No hangout bonus at home.
--
-- Remote: DevSetEnergy { level } (Studio only) sets the caller's current car's level, for Dev/EnergyTests.
--
-- The decisions are pure helpers in EnergyService/Rules (tests/EnergyService.spec). No polling beyond the one
-- sampling Heartbeat (CLAUDE.md hard rule 10): cars arrive and leave through ChildAdded/ChildRemoved, stations
-- through CollectionService.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local AntiExploit = require(Shared.Config.AntiExploit)
local Catalog = require(Shared.Vehicle.Catalog)
local Economy = require(Shared.Config.Economy)
local Energy = require(Shared.Vehicle.Energy)
local EnergyConfig = require(Shared.Config.Energy)
local Garage = require(Shared.Config.Garage)
local Gps = require(Shared.Config.Gps)
local Houses = require(Shared.Config.Houses)
local MapLayout = require(Shared.Config.MapLayout)
local Net = require(Shared.Net)
local Pathfind = require(Shared.Road.Pathfind)
local Spawning = require(Shared.Config.Spawning)
local Types = require(Shared.Types)
local Units = require(Shared.Util.Units)
local AntiExploitService = require(script.Parent.AntiExploitService)
local EconomyService = require(script.Parent.EconomyService)
local VehicleService = require(script.Parent.VehicleService)
local Rules = require(script.Rules)

-- DataService is required in Init rather than here: it loads ProfileStore, which talks to DataStores straight
-- away (the same pattern as GarageService and EconomyService).
type DataServiceModule = typeof(require(script.Parent.DataService))

type StationKind = Energy.StationKind
type EnergyKind = "battery" | "fuel"

-- Car attributes (docs/phase-5-contracts.md). OwnerUserId comes from VehicleService, VehicleId and Trim from the
-- vehicle model contract, OwnedUid and TestDrive from Config/Garage.
local ENERGY_ATTRIBUTE = "Energy"
local KIND_ATTRIBUTE = "EnergyKind"
local LIMP_ATTRIBUTE = "Limp"
local CHARGING_ATTRIBUTE = "Charging"
local CHARGE_RATE_ATTRIBUTE = "ChargeRate"
local CHARGE_COST_ATTRIBUTE = EnergyConfig.attributes.chargeCostPerFull
local STILL_ATTRIBUTE = EnergyConfig.attributes.still
local OWNER_ATTRIBUTE = "OwnerUserId"
local VEHICLE_ID_ATTRIBUTE = "VehicleId"
local TRIM_ATTRIBUTE = "Trim"
local SEATS_FOLDER = "Seats" -- seat names from the vehicle model contract
local DRIVER_SEAT = "Driver"
local PLAZA_ATTRIBUTE = "plaza" -- a ChargerStall's plaza (Config/MapLayout)
local STATION_KINDS: { StationKind } =
	{ "ChargerStall" :: StationKind, "TruckCharger" :: StationKind, "FuelPump" :: StationKind }
-- A home charger charges like a stall: battery cars only, on the stall's charging curve at its own kW.
local HOME_KIND: StationKind = "ChargerStall"
local PERCENT = 100
local LOG = "[EnergyService]"

-- EconomyService reasons (analytics transactions).
local REASON_CHARGE = "charge"
local REASON_FUEL = "fuel"
local REASON_HANGOUT = "hangout"

-- What players read (Notify toasts). Plain words; %d is a percent, %s a formatted amount like "$1,234".
local messages = {
	low = {
		battery = "Battery at %d%%. Find a charging stall soon.",
		fuel = "Fuel at %d%%. Find a pump soon.",
	},
	critical = {
		battery = "Battery at %d%%! Head to a charging stall now.",
		fuel = "Fuel at %d%%! Head to a pump now.",
	},
	empty = {
		battery = "Out of charge. You can still crawl at %d mph: follow the GPS to the nearest charger.",
		fuel = "Out of fuel. You can still crawl at %d mph: follow the GPS to the nearest pump.",
	},
	wrongStation = {
		battery = "This is a fuel pump. Electric cars charge at a charging stall.",
		fuel = "This is a charging stall. Fuel cars fill up at a pump.",
		truck = "Truck chargers are for semis. Use a charging stall.",
	},
	testDrive = "Test drives can't charge or fuel up. Buy the car to use stations.",
	homeNotYours = "This home charger is just for the owner's car. Public chargers are on the GPS.",
	noCash = {
		battery = "Charging stopped: you need %s for the next percent.",
		fuel = "Fueling stopped: you need %s for the next percent.",
	},
	full = {
		battery = "Fully charged for %s.",
		fuel = "Tank full for %s.",
	},
	stopped = {
		battery = "Charged to %d%% for %s.",
		fuel = "Fueled to %d%% for %s.",
	},
	hangout = "+%s hangout bonus for charging with friends",
	devOnly = "Dev tools only work in Studio.",
	devNoCar = "You don't have a car out.",
	devSet = "Energy set to %d%%.",
}

-- A charging or fueling session at one station.
type Session = {
	station: BasePart,
	kind: StationKind,
	home: boolean, -- at a house's home charger (Phase 13)
	costPerFull: number, -- $ for a full charge at this station (the kind's price, or the home charger's own)
	reason: string, -- REASON_CHARGE or REASON_FUEL
	owed: number, -- $ for percents already added that hasn't made a whole dollar yet
	spent: number, -- whole $ paid this session
}

-- One sampled car.
type Record = {
	model: Model,
	chassis: BasePart,
	owner: Player?,
	vehicleId: string,
	trim: string,
	energyKind: EnergyKind,
	uid: string?, -- OwnedVehicle uid; nil for a temporary car (never saved)
	testDrive: boolean, -- a dealership test drive: never charges, fuels or earns the hangout bonus
	level: number, -- 0..1, full precision
	published: number?, -- the Energy attribute last set
	savedLevel: number?, -- what the save holds for this car (rounded), when known
	savedAt: number, -- os.clock() of the last save (or of registering)
	maxSpeed: number, -- studs/s: catalog top speed with AntiExploit's headroom
	heightAbove: number, -- studs: how high over a pad the chassis may be and still count as on it
	driverSeat: Seat?,
	history: { Rules.MotionSample }, -- recent samples, oldest first
	movedAt: number, -- os.clock() of the last sample at which the chassis had moved (or of registering)
	speed: number, -- studs/s across the ground at the last sample
	still: boolean?, -- the Still attribute last set (nil before the first sample)
	-- Smoothed speed (studs/s) and climb (studs/s) that drain is billed on: the server's view of a client-driven
	-- car wobbles from sample to sample, and unsmoothed that wobble read as constant launches and climbs.
	smoothSpeed: number?,
	smoothClimb: number?,
	limp: boolean,
	limpSince: number?, -- os.clock() when limp mode began
	limpCapped: boolean, -- AntiExploit judges the car by the limp speed
	alerts: Rules.AlertState,
	session: Session?,
	wrongStation: BasePart?, -- the pad the car was told it can't use (until it leaves it)
	blockedStation: BasePart?, -- the pad where the player couldn't pay (until the car leaves it)
}

local EnergyService = {}

local DataService: DataServiceModule? = nil

local records: { [Model]: Record } = {}
local pending: { [Model]: boolean } = {} -- cars that arrived since the last sample (registered at the next one)
local stations: { [BasePart]: StationKind } = {}
local homeChargers: { [BasePart]: boolean } = {} -- Phase 13: the charger bays in claimed houses' garages
local sinceSample = 0
local sinceHangout = 0
-- Seconds each player has charged together with enough others at a plaza since the last hangout payout.
local hangoutSeconds: { [Player]: number } = {}

local limpSpeed = Units.mphToStuds(EnergyConfig.limpMph)
-- A limping car at or under this counts as slowed to the limp speed (AntiExploit's own headroom).
local limpCapSpeed = limpSpeed * AntiExploit.speedTolerance
local stillSpeed = Units.mphToStuds(EnergyConfig.sampling.stationStillMph)
-- Speed is measured over at least AntiExploit's sample interval (Rules.measure): long enough to average out the
-- jitter in when server-side positions arrive.
local motionWindow = math.max(EnergyConfig.sampling.interval, AntiExploit.sampleInterval)
local alertLevels: Rules.AlertLevels = {
	warning = EnergyConfig.warningLevel,
	critical = EnergyConfig.criticalLevel,
	rearmEmpty = EnergyConfig.limpClearLevel,
}

-- Helpers -----------------------------------------------------------------------------------------------------

local function notify(player: Player?, text: string, kind: string)
	if player ~= nil and player.Parent == Players then
		Net.fireClient("Notify", player, { text = text, kind = kind })
	end
end

local function percentOf(level: number): number
	return Rules.wholePercents(level)
end

local function rounded(level: number): number
	return Rules.roundLevel(level, EnergyConfig.sampling.attributeStep)
end

-- A usable 0..1 level from an attribute or a save, or nil.
local function validLevel(value: any): number?
	if type(value) == "number" and value == value then
		return math.clamp(value, 0, 1)
	end
	return nil
end

-- Workspace.Map.Generated.Locations (MapBuilder owns it), or nil before the map exists.
local function locationsFolder(): Instance?
	local node: Instance? = Workspace
	for _, name in Gps.spawnFlow.mapPath do
		node = if node ~= nil then node:FindFirstChild(name) else nil
	end
	return node
end

-- Stations ----------------------------------------------------------------------------------------------------

local function addStation(instance: Instance, kind: StationKind)
	if instance:IsA("BasePart") then
		stations[instance] = kind
	end
end

local function watchStations()
	for _, kind: StationKind in STATION_KINDS do
		for _, instance in CollectionService:GetTagged(kind) do
			addStation(instance, kind)
		end
		CollectionService:GetInstanceAddedSignal(kind):Connect(function(instance: Instance)
			addStation(instance, kind)
		end)
		CollectionService:GetInstanceRemovedSignal(kind):Connect(function(instance: Instance)
			if instance:IsA("BasePart") then
				stations[instance] = nil
			end
		end)
	end

	-- Home chargers come and go as houses are claimed and released (Services/HouseService).
	local homeTag = Houses.charger.tag
	local function addHome(instance: Instance)
		if instance:IsA("BasePart") then
			homeChargers[instance] = true
		end
	end
	for _, instance in CollectionService:GetTagged(homeTag) do
		addHome(instance)
	end
	CollectionService:GetInstanceAddedSignal(homeTag):Connect(addHome)
	CollectionService:GetInstanceRemovedSignal(homeTag):Connect(function(instance: Instance)
		if instance:IsA("BasePart") then
			homeChargers[instance] = nil
		end
	end)
end

-- The station pad the car's chassis stands on, its kind, and whether it is a home charger (Phase 13: it charges
-- like a ChargerStall); nil when it is on none.
local function stationUnder(record: Record): (BasePart?, StationKind?, boolean)
	local position = record.chassis.Position
	local folder = locationsFolder()
	if folder ~= nil then
		for part: BasePart, kind: StationKind in stations do
			if
				part:IsDescendantOf(folder)
				and Rules.insideFootprint(part.CFrame, part.Size, position, record.heightAbove)
			then
				return part, kind, false
			end
		end
	end
	for part in homeChargers do
		if
			part:IsDescendantOf(Workspace)
			and Rules.insideFootprint(part.CFrame, part.Size, position, record.heightAbove)
		then
			return part, HOME_KIND, true
		end
	end
	return nil, nil, false
end

-- What a station tells the charging curve (Vehicle/Energy.chargeRatePerSecond reads `kW` or `rate`): a public
-- station's own attributes, or a home charger's kW (Config/Energy home.kW when it has none).
local function stationAttributes(station: BasePart, home: boolean): { [string]: any }
	if home then
		return { kW = Rules.homeKW(station:GetAttribute(Houses.charger.kWAttribute), EnergyConfig.home.kW) }
	end
	return station:GetAttributes()
end

-- Every station location players can be sent to, by kind (MapLayout; built once).
local candidatesByKind: { [StationKind]: { Rules.Candidate } } = (function()
	local byKind: { [StationKind]: { Rules.Candidate } } = {}
	for _, kind: StationKind in STATION_KINDS do
		byKind[kind] = {}
	end
	for _, location in MapLayout.locations do
		local list = byKind[location.tag :: any]
		if list ~= nil then
			table.insert(list, { id = location.id, position = location.gpsTarget or location.position })
		end
	end
	return byKind
end)()

-- The station nearest the car by road that it can use, as a MapLayout location id (nil when there is none).
local function nearestStationFor(record: Record): string?
	local candidates: { Rules.Candidate } = {}
	for _, kind: StationKind in STATION_KINDS do
		if Energy.isCompatible(record.vehicleId, kind) then
			table.move(candidatesByKind[kind], 1, #candidatesByKind[kind], #candidates + 1, candidates)
		end
	end
	local pose = record.chassis.CFrame
	local id = Rules.nearestStation(pose.Position, candidates, function(position: Vector3): number?
		local route = Pathfind.route(pose.Position, position, pose.LookVector)
		return if route ~= nil then route.length else nil
	end)
	return id
end

-- Saving ------------------------------------------------------------------------------------------------------

-- True when another car out right now is the same owned car (it was put away and brought straight back out).
local function sameCarOut(record: Record): boolean
	for _, other in records do
		if other ~= record and other.uid == record.uid and other.model.Parent ~= nil then
			return true
		end
	end
	return false
end

-- Writes a garage car's level to its OwnedVehicle.energy (nothing for temporary cars, or when it's unchanged).
local function persist(record: Record)
	local uid, owner, dataService = record.uid, record.owner, DataService
	if uid == nil or owner == nil or dataService == nil then
		return
	end
	local level = rounded(record.level)
	if level == record.savedLevel then
		return
	end
	local data = dataService.get(owner)
	if data == nil then
		return -- the player left (their save was written when they did) or never loaded
	end
	local function ownedCar(from: Types.PlayerData): Types.OwnedVehicle?
		for _, vehicle in from.vehicles do
			if type(vehicle) == "table" and vehicle.uid == uid then
				return vehicle
			end
		end
		return nil
	end
	if ownedCar(data) == nil then
		return -- sold while it was out
	end
	local written = false
	dataService.update(owner, function(fresh: Types.PlayerData)
		local vehicle = ownedCar(fresh)
		if vehicle ~= nil then
			vehicle.energy = level
			written = true
		end
	end)
	if written then
		record.savedLevel = level
		record.savedAt = os.clock()
	end
end

-- Charging ------------------------------------------------------------------------------------------------------

-- `rate` nil: not charging. `costPerFull` is the running stop's price per full charge (what the client shows per %).
local function setChargingAttributes(record: Record, rate: number?, costPerFull: number?)
	record.model:SetAttribute(CHARGING_ATTRIBUTE, rate ~= nil)
	record.model:SetAttribute(CHARGE_RATE_ATTRIBUTE, rate or 0)
	record.model:SetAttribute(CHARGE_COST_ATTRIBUTE, if rate ~= nil then costPerFull else nil)
end

-- Ends the car's session. `why` picks the notice: "full", "noCash" (with the price of a percent), "left" or
-- "gone" (the car is being removed: no notice).
local function stopSession(record: Record, why: string)
	local session = record.session
	if session == nil then
		return
	end
	record.session = nil
	if record.model.Parent ~= nil then
		setChargingAttributes(record, nil)
	end
	local kind = record.energyKind
	if why == "full" then
		notify(record.owner, string.format(messages.full[kind], Economy.formatCash(session.spent)), "success")
	elseif why == "noCash" then
		record.blockedStation = session.station
		local need = Economy.formatCash(math.ceil(session.costPerFull / PERCENT))
		notify(record.owner, string.format(messages.noCash[kind], need), "warning")
	elseif why == "left" and session.spent > 0 then
		local text = string.format(messages.stopped[kind], percentOf(record.level), Economy.formatCash(session.spent))
		notify(record.owner, text, "info")
	end
end

-- One step of charging: adds the station's rate for `dt` seconds (no more than the player's cash pays for) and
-- bills it in whole dollars. Stops the session at full, or once the player can't pay for more.
local function chargeStep(record: Record, session: Session, dt: number)
	local owner = record.owner
	local attributes = stationAttributes(session.station, session.home)
	local rate = Energy.chargeRatePerSecond(session.kind, attributes, record.vehicleId, record.trim, record.level)
	local budget = if owner ~= nil then EconomyService.getCash(owner) else 0
	local step = Rules.chargeStep(record.level, rate, dt, session.costPerFull, session.owed, budget)
	if step.bill > 0 then
		if owner == nil or not EconomyService.trySpend(owner, step.bill, session.reason) then
			stopSession(record, "noCash")
			return
		end
		session.spent += step.bill
	end
	session.owed = step.owed
	record.level = step.level
	if step.full then
		stopSession(record, "full")
	elseif step.short then
		stopSession(record, "noCash")
	else
		record.model:SetAttribute(CHARGE_RATE_ATTRIBUTE, rate)
	end
end

-- Starts, continues or stops charging for a car at `station` (nil when it is on no pad; `home` for a house's home
-- charger). Returns true while it charged this sample (so it doesn't also drain).
local function handleStation(
	record: Record,
	station: BasePart?,
	kind: StationKind?,
	home: boolean,
	speed: number,
	dt: number
): boolean
	local session = record.session
	if session ~= nil and session.station ~= station then
		stopSession(record, "left")
		session = nil
	end
	if record.wrongStation ~= nil and record.wrongStation ~= station then
		record.wrongStation = nil
	end
	if record.blockedStation ~= nil and record.blockedStation ~= station then
		record.blockedStation = nil
	end
	if station == nil or kind == nil then
		return false
	end

	if session == nil then
		-- Only a car that has stopped on the pad starts; once started, creeping on the pad doesn't stop it.
		if speed > stillSpeed or record.blockedStation == station then
			return false
		end
		if record.testDrive then
			-- A test drive starts full and isn't kept: nothing to pay for.
			if record.wrongStation ~= station then
				record.wrongStation = station
				notify(record.owner, messages.testDrive, "info")
			end
			return false
		end
		if
			home
			and not Rules.homeChargeAllowed(
				station:GetAttribute(Houses.charger.ownerAttribute),
				record.model:GetAttribute(OWNER_ATTRIBUTE),
				record.testDrive
			)
		then
			-- Someone else's home charger: only the house's owner charges here.
			if record.wrongStation ~= station then
				record.wrongStation = station
				notify(record.owner, messages.homeNotYours, "info")
			end
			return false
		end
		if not Rules.canStartCharging(record.level, EnergyConfig.charging.startBelow) then
			return false
		end
		if not Energy.isCompatible(record.vehicleId, kind) then
			if record.wrongStation ~= station then
				record.wrongStation = station
				local text = if kind == "TruckCharger" and record.energyKind == "battery"
					then messages.wrongStation.truck
					else messages.wrongStation[record.energyKind]
				notify(record.owner, text, "info")
			end
			return false
		end
		local fresh: Session = {
			station = station,
			kind = kind,
			home = home,
			costPerFull = if home
				then Rules.homeCostPerFull(
					station:GetAttribute(Houses.charger.costAttribute),
					EnergyConfig.home.costPerFull
				)
				else Energy.costPerFraction(kind),
			reason = if kind == "FuelPump" then REASON_FUEL else REASON_CHARGE,
			owed = 0,
			spent = 0,
		}
		record.session = fresh
		session = fresh
		local attributes = stationAttributes(station, home)
		setChargingAttributes(
			record,
			Energy.chargeRatePerSecond(kind, attributes, record.vehicleId, record.trim, record.level),
			fresh.costPerFull
		)
		return true -- the first step adds energy at the next sample
	end

	chargeStep(record, session, dt)
	return true
end

-- Limp mode, alerts and the attributes ------------------------------------------------------------------------

local function updateLimp(record: Record, speed: number, driving: boolean)
	local now = os.clock()
	local limp = Rules.limpNext(record.limp, record.level, EnergyConfig.limpClearLevel)
	if limp ~= record.limp then
		record.limp = limp
		record.limpSince = if limp then now else nil
		record.model:SetAttribute(LIMP_ATTRIBUTE, limp)
	end
	if
		limp
		and not record.limpCapped
		and (
			not driving
			or Rules.limpCapDue(speed, limpCapSpeed, record.limpSince or now, now, EnergyConfig.limpCapGraceSeconds)
		)
	then
		-- Slowed to the limp speed, parked, or out of time to slow down: from now on AntiExploit judges it by
		-- that speed.
		record.limpCapped = true
		AntiExploitService.setTopSpeed(record.model, limpSpeed)
	elseif not limp and record.limpCapped then
		record.limpCapped = false
		AntiExploitService.setTopSpeed(record.model, nil)
	end
end

local function sendEmptyAlert(record: Record)
	local owner = record.owner
	if owner == nil then
		return
	end
	notify(owner, string.format(messages.empty[record.energyKind], EnergyConfig.limpMph), "error")
	-- Routing runs A* over the county: in its own thread, so a failure never stops the sampling.
	task.spawn(function()
		local stationId = nearestStationFor(record)
		if owner.Parent == Players then
			Net.fireClient("EnergyAlert", owner, { level = record.level, stationId = stationId })
		end
	end)
end

local function updateAlerts(record: Record)
	local alert = Rules.updateAlerts(record.alerts, record.level, alertLevels)
	if alert == "warning" then
		notify(record.owner, string.format(messages.low[record.energyKind], percentOf(record.level)), "warning")
	elseif alert == "critical" then
		notify(record.owner, string.format(messages.critical[record.energyKind], percentOf(record.level)), "error")
	elseif alert == "empty" then
		sendEmptyAlert(record)
	end
end

local function publish(record: Record)
	local level = rounded(record.level)
	if level ~= record.published then
		record.published = level
		record.model:SetAttribute(ENERGY_ATTRIBUTE, level)
	end
end

-- Everything that follows from the car's level: limp mode, alerts and the Energy attribute.
local function applyLevel(record: Record, speed: number, driving: boolean)
	updateLimp(record, speed, driving)
	updateAlerts(record)
	publish(record)
end

-- Cars ----------------------------------------------------------------------------------------------------------

local function stringAttribute(model: Model, name: string): string?
	local value = model:GetAttribute(name)
	return if type(value) == "string" then value else nil
end

-- Starts sampling a car, or nil for a car that isn't driven (no energyMinutes) or isn't a spawned car.
local function register(model: Model): Record?
	local existing = records[model]
	if existing ~= nil then
		return existing
	end
	local chassis = model.PrimaryPart
	local vehicleId, trimId = stringAttribute(model, VEHICLE_ID_ATTRIBUTE), stringAttribute(model, TRIM_ATTRIBUTE)
	if chassis == nil or vehicleId == nil or trimId == nil then
		return nil
	end
	local vehicle = Catalog.getVehicle(vehicleId)
	local trim = Catalog.getTrim(vehicleId, trimId)
	local geometry = Catalog.geometry(vehicleId, trimId)
	if vehicle == nil or trim == nil or trim.energyMinutes == nil or geometry == nil then
		return nil
	end

	local ownerId = model:GetAttribute(OWNER_ATTRIBUTE)
	local owner = if type(ownerId) == "number" then Players:GetPlayerByUserId(ownerId) else nil
	local uid = stringAttribute(model, Garage.ownedUidAttribute)
	local testDrive = model:GetAttribute(Garage.testDriveAttribute) == true
	if testDrive then
		uid = nil -- a test drive is never saved
	end
	-- A garage car carries its saved level (EnergyService.attach); a temporary car starts full.
	local saved = if uid ~= nil then validLevel(model:GetAttribute(ENERGY_ATTRIBUTE)) else nil
	local level = saved or 1
	local seats = model:FindFirstChild(SEATS_FOLDER)
	local driverSeat = if seats ~= nil then seats:FindFirstChild(DRIVER_SEAT) else nil

	local record: Record = {
		model = model,
		chassis = chassis,
		owner = owner,
		vehicleId = vehicleId,
		trim = trimId,
		energyKind = vehicle.energy,
		uid = uid,
		testDrive = testDrive,
		level = level,
		published = nil,
		savedLevel = if saved ~= nil then rounded(saved) else nil,
		savedAt = os.clock(),
		maxSpeed = Units.mphToStuds(trim.topSpeedMph) * AntiExploit.speedTolerance,
		-- The chassis centre stands at most the body's height over the pad.
		heightAbove = geometry.height,
		driverSeat = if driverSeat ~= nil and driverSeat:IsA("Seat") then driverSeat else nil,
		history = {},
		movedAt = os.clock(),
		speed = 0,
		still = nil,
		limp = false,
		limpSince = nil,
		limpCapped = false,
		alerts = Rules.newAlerts(),
		session = nil,
		wrongStation = nil,
		blockedStation = nil,
	}
	records[model] = record
	model:SetAttribute(KIND_ATTRIBUTE, vehicle.energy)
	setChargingAttributes(record, nil)
	model:SetAttribute(LIMP_ATTRIBUTE, false)
	applyLevel(record, 0, false)
	return record
end

-- Stops sampling a car that left the world: saves it (unless the same owned car is already back out) and
-- forgets it.
local function finalize(model: Model)
	pending[model] = nil
	local record = records[model]
	if record == nil then
		return
	end
	stopSession(record, "gone")
	if not sameCarOut(record) then
		persist(record)
	end
	records[model] = nil
end

local function isDriving(record: Record): boolean
	local seat = record.driverSeat
	return seat ~= nil and seat.Occupant ~= nil and not record.chassis.Anchored
end

local function sampleCar(record: Record, now: number)
	local chassis = record.chassis
	local velocity = chassis.AssemblyLinearVelocity
	local current: Rules.MotionSample = {
		t = now,
		position = chassis.Position,
		velocitySpeed = Vector3.new(velocity.X, 0, velocity.Z).Magnitude,
	}
	local history = record.history
	local previous = history[#history]
	local motion = Rules.measure(history, current, {
		window = motionWindow,
		maxSpeed = record.maxSpeed,
		agreement = EnergyConfig.sampling.speedAgreement,
		movedAt = record.movedAt,
		catchUpSeconds = EnergyConfig.sampling.catchUpSeconds,
		serverMovedAt = AntiExploitService.lastServerMove(record.model),
	})
	if
		motion.restart
		or previous == nil
		or (current.position - previous.position).Magnitude > EnergyConfig.sampling.stillDistance
	then
		record.movedAt = now
	end
	if motion.restart then
		table.clear(history)
	end
	if not motion.jumped then
		current.groundSpeed = motion.groundSpeed
	end
	table.insert(history, current)
	-- Keep only what the next window needs: drop samples older than the window, except the newest such one.
	while #history > 2 and now - history[2].t >= motionWindow do
		table.remove(history, 1)
	end

	local dt = if previous ~= nil then now - previous.t else 0
	local driving = isDriving(record)
	record.speed = motion.speed
	-- Still or moving, published only when it flips (MeetService counts a still car with its driver in it).
	local still = motion.speed <= stillSpeed
	if still ~= record.still then
		record.still = still
		record.model:SetAttribute(STILL_ATTRIBUTE, still)
	end
	-- Only look for a pad under a car that could start or is charging, or that was told about a pad it's on.
	local station: BasePart?, kind: StationKind?, home = nil, nil, false
	local onPad = record.session ~= nil or record.wrongStation ~= nil or record.blockedStation ~= nil
	if onPad or motion.speed <= stillSpeed then
		station, kind, home = stationUnder(record)
	end
	-- Smooth speed and climb (exponential, time constant Config sampling.smoothingSeconds) and take acceleration
	-- from the smoothed speed, so sample-to-sample wobble isn't billed as launches and climbs. A restart (spawn,
	-- reset, catch-up after a stall) starts the smoothing over from the current sample.
	local smoothSpeed, smoothClimb, smoothAccel = motion.speed, motion.climb, 0
	if not motion.restart and record.smoothSpeed ~= nil and record.smoothClimb ~= nil and motion.seconds > 0 then
		local alpha = 1 - math.exp(-motion.seconds / EnergyConfig.sampling.smoothingSeconds)
		smoothSpeed = record.smoothSpeed + (motion.speed - record.smoothSpeed) * alpha
		smoothClimb = record.smoothClimb + (motion.climb - record.smoothClimb) * alpha
		smoothAccel = (smoothSpeed - record.smoothSpeed) / motion.seconds
	end
	record.smoothSpeed = smoothSpeed
	record.smoothClimb = smoothClimb

	local charging = handleStation(record, station, kind, home, motion.speed, dt)
	if not charging and driving and not motion.jumped then
		local perSecond = Energy.drainPerSecond(record.vehicleId, record.trim, smoothSpeed, smoothAccel, smoothClimb)
		record.level = math.max(record.level - perSecond * motion.seconds, 0)
	end
	applyLevel(record, motion.speed, driving)

	-- While the level changes (driving or charging), save at most once per saveInterval.
	if now - record.savedAt >= EnergyConfig.sampling.saveInterval then
		persist(record)
	end
end

-- The hangout bonus ---------------------------------------------------------------------------------------------

-- Adds `dt` seconds to everyone charging at a stall right now on a plaza where enough players charge together.
local function countHangout(dt: number)
	local charging: { [Player]: string } = {}
	for _, record in records do
		local session, owner = record.session, record.owner
		if
			session ~= nil
			and owner ~= nil
			and not record.testDrive
			and not session.home
			and session.kind == "ChargerStall"
		then
			local plaza = session.station:GetAttribute(PLAZA_ATTRIBUTE)
			if type(plaza) == "string" and plaza ~= "" then
				charging[owner] = plaza
			end
		end
	end
	for player in Rules.hangoutPayees(charging, EnergyConfig.hangout.minPlayers) do
		hangoutSeconds[player] = (hangoutSeconds[player] or 0) + dt
	end
end

-- Pays everyone for the time they charged together since the last payout.
local function payHangout()
	local due = hangoutSeconds
	hangoutSeconds = {}
	for player, seconds in due do
		if player.Parent ~= Players then
			continue
		end
		-- Its own thread: EconomyService writes player data, and one failure mustn't stop the others.
		task.spawn(function()
			local multiplier = EconomyService.earningsMultiplier(player)
			local amount = Rules.hangoutPay(seconds, EnergyConfig.hangout.cashPerMinute, multiplier)
			if amount > 0 and EconomyService.add(player, amount, REASON_HANGOUT) then
				notify(player, string.format(messages.hangout, Economy.formatCash(amount)), "success")
			end
		end)
	end
end

-- Sampling ------------------------------------------------------------------------------------------------------

local function sampleAll(dt: number)
	local now = os.clock()
	for model in pending do
		pending[model] = nil
		if model.Parent ~= nil then
			register(model)
		end
	end
	for model, record in records do
		if model.Parent == nil then
			finalize(model) -- removed without ChildRemoved reaching us first
			continue
		end
		local ok, err = pcall(sampleCar, record, now)
		if not ok then
			warn(`{LOG} sampling {model:GetFullName()} failed: {err}`)
		end
	end

	countHangout(dt)
	sinceHangout += dt
	if sinceHangout >= EnergyConfig.hangout.interval then
		sinceHangout -= EnergyConfig.hangout.interval
		payHangout()
	end
end

local function onHeartbeat(dt: number)
	sinceSample += dt
	if sinceSample < EnergyConfig.sampling.interval then
		return
	end
	local elapsed = sinceSample
	sinceSample = 0
	sampleAll(elapsed)
end

-- The dev path (Studio only) --------------------------------------------------------------------------------------

local function onDevSetEnergy(player: Player, payload: any): { ok: boolean, message: string, level: number? }
	if not RunService:IsStudio() then
		warn(`{LOG} {player.Name} ({player.UserId}) called DevSetEnergy outside Studio`)
		return { ok = false, message = messages.devOnly }
	end
	local car = VehicleService.getCar(player)
	local record = if car ~= nil then register(car) else nil
	if record == nil then
		return { ok = false, message = messages.devNoCar }
	end
	local level: number = math.clamp(payload.level, 0, 1)
	record.level = level
	applyLevel(record, record.speed, isDriving(record))
	return { ok = true, message = string.format(messages.devSet, percentOf(level)), level = level }
end

-- Public API -----------------------------------------------------------------------------------------------------

-- Puts a garage car's saved level on it as it comes out (GarageService, right after VehicleService.spawn and
-- setting OwnedUid). A missing or damaged level counts as full.
function EnergyService.attach(model: Model, level: number?)
	local valid = validLevel(level) or 1
	model:SetAttribute(ENERGY_ATTRIBUTE, rounded(valid))
	local record = records[model]
	if record ~= nil then
		record.level = valid
		record.savedLevel = rounded(valid)
	end
end

-- Writes the level of every car the player has out back to their save now (before GarageService puts them away).
function EnergyService.persistPlayer(player: Player)
	for _, record in records do
		if record.owner == player then
			persist(record)
		end
	end
end

-- A car's current level (0..1), or nil for a car that isn't sampled.
function EnergyService.getLevel(model: Model): number?
	local record = records[model]
	return if record ~= nil then record.level else nil
end

-- Boot -----------------------------------------------------------------------------------------------------------

function EnergyService:Init()
	local dataService = require(script.Parent.DataService)
	DataService = dataService
	-- DataService calls this when a player leaves and for everyone when the server closes, before it ends their
	-- session, so the cars they have out are saved while the session is still open.
	dataService.beforeRelease(EnergyService.persistPlayer)
end

function EnergyService:Start()
	watchStations()
	local folder = Workspace:FindFirstChild(Spawning.vehiclesFolder) or Workspace:WaitForChild(Spawning.vehiclesFolder)
	-- Cars are registered at the next sample, after whoever spawned them has set their attributes (OwnedUid,
	-- Energy, TestDrive) in the same frame.
	folder.ChildAdded:Connect(function(child: Instance)
		if child:IsA("Model") then
			pending[child] = true
		end
	end)
	folder.ChildRemoved:Connect(function(child: Instance)
		if child:IsA("Model") then
			finalize(child)
		end
	end)
	for _, child in folder:GetChildren() do
		if child:IsA("Model") then
			pending[child] = true
		end
	end
	-- Always listen, so the remote never queues up; the handler itself refuses outside Studio.
	Net.onServerInvoke("DevSetEnergy", onDevSetEnergy)
	RunService.Heartbeat:Connect(onHeartbeat)
end

return EnergyService
