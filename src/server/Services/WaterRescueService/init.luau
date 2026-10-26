--!strict
-- Pulls driven cars out of the bay (Config/Water rescue; docs/city/SCENERY.md §3). The bay is terrain water
-- (Dev/WaterBuilder): a car that drives in sinks and slows, and players on foot swim, which is fine. A car left in
-- deep water, on its roof in any water, or stuck in any water (barely moving: the beach shelf, a seawall) for a few
-- seconds is put back in the right-hand lane of the nearest road (AbilityService.roadPose) by the server's own
-- car-reset path (VehicleService.resetCar: Net VehicleReset to the driver, AntiExploitService.allowTeleport) and its
-- driver is told why (Net Notify). A car its driver gets out of in the water goes to the road at the next check.
-- Rescue decides when.
--
-- Server-authoritative (CLAUDE.md hard rule 1): only what the server sees of the car counts. No polling loops beyond
-- one Heartbeat with an accumulator (CLAUDE.md hard rule 10), as DriveEarnService does: every rescue.interval it
-- looks at each player's car while they drive it (AntiExploitService.isTracked), and only a car over a water area
-- costs more than a rectangle test. Parked cars are anchored and never move into the water by themselves.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Net = require(ReplicatedStorage.Shared.Net)
local Water = require(ReplicatedStorage.Shared.Config.Water)
local AbilityService = require(script.Parent.AbilityService)
local AntiExploitService = require(script.Parent.AntiExploitService)
local VehicleService = require(script.Parent.VehicleService)
local Rescue = require(script.Rescue)

local LOG = "[WaterRescue]"
local RESCUE = Water.rescue

type Watch = { car: Model, watch: Rescue.Watch }

local WaterRescueService = {}

local watches: { [Player]: Watch } = {}
local sinceCheck = 0

-- Puts the car on the nearest road and tells its driver. False when there is no road to put it on.
function WaterRescueService.pullOut(player: Player, car: Model, chassis: BasePart): boolean
	local pose = AbilityService.roadPose(chassis.Position, chassis.CFrame.LookVector)
	if pose == nil then
		warn(`{LOG} {car:GetFullName()} is in the water but there is no road to move it to`)
		return false
	end
	VehicleService.resetCar(car, pose, RESCUE.reason)
	if player.Parent == Players then
		Net.fireClient("Notify", player, { text = RESCUE.message, kind = RESCUE.kind })
	end
	return true
end

local function checkAll(now: number)
	for _, player in Players:GetPlayers() do
		local car = VehicleService.getCar(player)
		local chassis = if car then car.PrimaryPart else nil
		if car == nil or chassis == nil or not AntiExploitService.isTracked(car) then
			-- Its driver just got out (VehicleService parked it): left in the water, it would float there, anchored on
			-- the surface, so it goes to the road now.
			local was = watches[player]
			watches[player] = nil
			if
				was
				and car ~= nil
				and chassis ~= nil
				and was.car == car
				and Rescue.leftInWater(car:GetPivot(), RESCUE)
			then
				WaterRescueService.pullOut(player, car, chassis)
			end
			continue
		end
		local entry = watches[player]
		if entry == nil or entry.car ~= car then
			entry = { car = car, watch = {} }
			watches[player] = entry
		end
		local reading = Rescue.read(chassis.CFrame, RESCUE, nil, AntiExploitService.groundSpeed(car))
		if Rescue.step(entry.watch, reading, now, RESCUE) then
			WaterRescueService.pullOut(player, car, chassis)
		end
	end
end

local function onHeartbeat(dt: number)
	sinceCheck += dt
	if sinceCheck < RESCUE.interval then
		return
	end
	sinceCheck = 0
	checkAll(os.clock())
end

function WaterRescueService:Start()
	if not Water.terrain then
		return -- the old part water: cars drive on the lake bed and climb out up its banks, as they always did
	end
	RunService.Heartbeat:Connect(onHeartbeat)
	Players.PlayerRemoving:Connect(function(leaving: Player)
		watches[leaving] = nil
	end)
end

return WaterRescueService
