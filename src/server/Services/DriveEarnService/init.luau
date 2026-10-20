--!strict
-- Drive-to-earn (PLAN.md §4 and Phase 3; docs/phase-3-contracts.md "Drive-to-earn"). Players earn cash for
-- driving their own car on the county's roads, about $300 a minute (Config/DriveEarn has the calibration).
--
-- Server-only and server-authoritative (CLAUDE.md hard rule 1): every number comes from what the server sees.
-- One Heartbeat connection with an accumulator samples every player who sits in their car's Driver seat once per
-- Config/DriveEarn.sampleInterval: the car's pivot (the point on the ground under its chassis, so it sits on the
-- road surface while driving), and whether that point is on a road (Road/Graph.isOnRoad). Samples go into a
-- ring buffer per player that covers the AFK and loop-farming windows. Every payInterval of driving,
-- Earnings.decide turns the buffer into a payout: distance on roads x the rate, capped, times
-- EconomyService.earningsMultiplier, paid with EconomyService.add(player, amount, "drive") and a toast. Nothing
-- is paid for an AFK car or a car circling a small spot (see Earnings).
--
-- When a player gets out, switches cars or respawns, the driving since the last payout is paid at once (same
-- rules, cap pro rata), then their samples and pay timer start over. Leaving the game drops it unpaid.
--
-- Dealership test-drive cars (attribute Config/Garage.testDriveAttribute) never earn: they count as not driving.
-- Neither does a player with an active job (JobService.hasActiveJob; docs/phase-6-contracts.md): the job is the
-- earning, so the two never stack. Accepting a job settles the driving before it, like getting out.
--
-- Who's driving comes from VehicleService.getCar(player) and the car's Driver seat Occupant. Neither
-- VehicleService, EconomyService nor JobService requires this module, so there is no require cycle. No polling loops beyond
-- the sampling Heartbeat (CLAUDE.md hard rule 10).

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage.Shared
local Catalog = require(Shared.Vehicle.Catalog)
local DriveEarn = require(Shared.Config.DriveEarn)
local Economy = require(Shared.Config.Economy)
local Garage = require(Shared.Config.Garage)
local Graph = require(Shared.Road.Graph)
local Net = require(Shared.Net)
local Units = require(Shared.Util.Units)
local EconomyService = require(script.Parent.EconomyService)
local JobService = require(script.Parent.JobService)
local VehicleService = require(script.Parent.VehicleService)
local Earnings = require(script.Earnings)

local DRIVER_SEAT = "Driver" -- seat names from the vehicle model contract
local SEATS_FOLDER = "Seats"

-- One player's drive in one car.
type State = {
	car: Model,
	humanoid: Humanoid,
	maxSpeed: number, -- studs/s: steps faster than this are jumps
	samples: { Earnings.Sample }, -- ring buffer, `capacity` slots
	head: number, -- slot of the newest sample (0 = none yet)
	count: number, -- samples held
	payFrom: number, -- os.clock() of the previous decision (or of getting in)
	payDue: number, -- os.clock() of the next decision
}

local DriveEarnService = {}

-- Enough samples to cover the longer window, plus the one just before it (a step's start).
local capacity = math.ceil(math.max(DriveEarn.afkWindow, DriveEarn.loopWindow) / DriveEarn.sampleInterval) + 2

local states: { [Player]: State } = {}
local sinceSample = 0
local decisionsMade: { [Player]: number } = {} -- Studio debug counter (DriveEarnTick)

-- The fastest catalog top speed of any drivable trim (studs/s): the jump limit for a car whose attributes
-- don't name a trim, so a jump is still never paid.
local fastestTopSpeed = (function(): number
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
end)()

-- The fastest a step may legally be for this car (studs/s), from its catalog top speed via its VehicleId and
-- Trim attributes, with AntiExploit's headroom.
local function maxSpeedOf(car: Model): number
	local vehicleId, trimId = car:GetAttribute("VehicleId"), car:GetAttribute("Trim")
	local trim = if type(vehicleId) == "string" and type(trimId) == "string"
		then Catalog.getTrim(vehicleId, trimId)
		else nil
	local topSpeed = if trim then Units.mphToStuds(trim.topSpeedMph) else fastestTopSpeed
	return topSpeed * DriveEarn.jumpSpeedTolerance
end

-- The player's car and their humanoid, when their character sits in that car's Driver seat; else nil.
local function drivenCar(player: Player): (Model?, Humanoid?)
	local car = VehicleService.getCar(player)
	local character = player.Character
	if car == nil or car.Parent == nil or character == nil then
		return nil, nil
	end
	if car:GetAttribute(Garage.testDriveAttribute) == true then
		return nil, nil -- a dealership test drive: no earnings
	end
	if JobService.hasActiveJob(player) then
		return nil, nil -- on a job: the job pays instead
	end
	local seats = car:FindFirstChild(SEATS_FOLDER)
	local seat = if seats then seats:FindFirstChild(DRIVER_SEAT) else nil
	if seat == nil or not seat:IsA("Seat") then
		return nil, nil
	end
	local humanoid = seat.Occupant
	if humanoid == nil or humanoid.Parent ~= character or humanoid.Health <= 0 then
		return nil, nil
	end
	return car, humanoid
end

local function newState(car: Model, humanoid: Humanoid, now: number): State
	return {
		car = car,
		humanoid = humanoid,
		maxSpeed = maxSpeedOf(car),
		samples = table.create(capacity),
		head = 0,
		count = 0,
		payFrom = now,
		payDue = now + DriveEarn.payInterval,
	}
end

local function record(state: State, now: number)
	local position = state.car:GetPivot().Position
	state.head = state.head % capacity + 1
	state.samples[state.head] = {
		t = now,
		position = Vector3.new(position.X, 0, position.Z),
		onRoad = Graph.isOnRoad(position, DriveEarn.onRoadMargin),
	}
	state.count = math.min(state.count + 1, capacity)
end

-- The ring buffer's samples, oldest first.
local function inOrder(state: State): { Earnings.Sample }
	local list: { Earnings.Sample } = table.create(state.count)
	for offset = state.count - 1, 0, -1 do
		local slot = (state.head - 1 - offset) % capacity + 1
		table.insert(list, state.samples[slot])
	end
	return list
end

-- Studio only: lets Dev/EarnTests line up with the pay intervals and see why a minute paid or didn't.
local function publishDebug(player: Player, decision: Earnings.Decision)
	if not RunService:IsStudio() then
		return
	end
	decisionsMade[player] = (decisionsMade[player] or 0) + 1
	player:SetAttribute(
		DriveEarn.debugDecisionAttribute,
		HttpService:JSONEncode({
			amount = decision.amount,
			reason = decision.reason,
			distance = math.floor(decision.distance),
			capped = decision.capped,
			multiplier = decision.multiplier,
			moved = math.floor(decision.moved),
			boundingBox = math.floor(decision.boundingBox),
		})
	)
	player:SetAttribute(DriveEarn.debugTickAttribute, decisionsMade[player])
end

-- Makes the payout decision for the interval ending now and pays it. Runs in its own thread (EconomyService
-- writes player data), so one failure never stops the sampling of other players.
local function pay(player: Player, state: State, now: number)
	local samples = inOrder(state)
	local payFrom = state.payFrom
	state.payFrom = now
	state.payDue += DriveEarn.payInterval
	task.spawn(function()
		local multiplier = EconomyService.earningsMultiplier(player)
		local decision = Earnings.decide(samples, now, state.maxSpeed, multiplier, DriveEarn, payFrom)
		if decision.amount > 0 and EconomyService.add(player, decision.amount, DriveEarn.reason) then
			Net.fireClient("Notify", player, {
				text = string.format(DriveEarn.notifyFormat, Economy.formatCash(decision.amount)),
				kind = DriveEarn.notifyKind,
			})
		end
		publishDebug(player, decision)
	end)
end

-- A drive ended between payouts (got out, switched cars, respawned): pay for the driving since the last payout,
-- up to its last sample. The AFK and loop rules apply as usual and the cap scales with the time covered, so
-- getting in and out earns nothing extra.
local function settle(player: Player, state: State)
	local newest = if state.head > 0 then state.samples[state.head] else nil
	if state.count >= 2 and newest ~= nil and newest.t > state.payFrom then
		pay(player, state, newest.t)
	end
end

local function sampleAll(now: number)
	for _, player in Players:GetPlayers() do
		local car, humanoid = drivenCar(player)
		local state = states[player]
		if car == nil or humanoid == nil then
			if state ~= nil then
				settle(player, state)
				states[player] = nil -- got out: start over next time
			end
			continue
		end
		if state == nil or state.car ~= car or state.humanoid ~= humanoid then
			if state ~= nil then
				settle(player, state)
			end
			state = newState(car, humanoid, now) -- got in, switched cars or respawned
			states[player] = state
		end
		record(state, now)
		if now >= state.payDue then
			pay(player, state, now)
		end
	end
end

local function onHeartbeat(dt: number)
	sinceSample += dt
	if sinceSample < DriveEarn.sampleInterval then
		return
	end
	sinceSample = 0
	sampleAll(os.clock())
end

function DriveEarnService:Start()
	RunService.Heartbeat:Connect(onHeartbeat)
	Players.PlayerRemoving:Connect(function(leaving: Player)
		states[leaving] = nil
		decisionsMade[leaving] = nil
	end)
end

return DriveEarnService
