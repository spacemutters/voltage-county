--!strict
-- When a driven car must come out of the water (Config/Water rescue). Pure: Services/WaterRescueService feeds it the
-- car's chassis frame on every check and moves the car when it says so; tests/Water.spec checks every rule.
--
-- A car is in the water when its chassis centre is less than `touch` above an area's water line (Util/WaterShape).
-- In deep water (at least `depth` studs, surface to seabed) it may stay `seconds`; on its roof or side (up vector Y
-- under `flippedDot`) in any water, `flippedSeconds`; stuck in any water (slower than `stuckSpeed` across the ground:
-- grounded on the beach shelf, nosed into a seawall), `stuckSeconds`. Wading through the shallows, or driving over the
-- bridge, never counts. The clock starts when the car gets into trouble and stops the moment it is out of it.
-- A car its driver leaves in the water (parked: VehicleService parks it on the water's surface) comes out at once.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Water = require(ReplicatedStorage.Shared.Config.Water)
local WaterShape = require(ReplicatedStorage.Shared.Util.WaterShape)

export type Reading = {
	wet: boolean, -- the chassis is in the water
	deep: boolean, -- ...and the water there is at least `depth` deep
	flipped: boolean, -- the car is on its roof or its side
	stuck: boolean, -- ...or it is in the water and barely moving
}

-- One car's watch: since when it has been in trouble (nil: it isn't).
export type Watch = { since: number? }

local Rescue = {}

-- Reads a car's chassis frame against the water areas (default: the county's). `speed` is its speed across the ground
-- (studs/s; nil when unknown, which never counts as stuck).
function Rescue.read(chassis: CFrame, config: Water.Rescue, areas: { WaterShape.Area }?, speed: number?): Reading
	local p = chassis.Position
	local surface = WaterShape.surfaceAt(p.X, p.Z, areas)
	if surface == nil or p.Y >= surface + config.touch then
		return { wet = false, deep = false, flipped = false, stuck = false }
	end
	return {
		wet = true,
		deep = WaterShape.depthAt(p.X, p.Z, areas) >= config.depth,
		flipped = chassis.UpVector.Y < config.flippedDot,
		stuck = speed ~= nil and speed < config.stuckSpeed,
	}
end

-- Whether a parked car whose pivot (the ground point under its chassis) is `pivot` was left in the water: over water
-- and no higher than `touch` above its line.
function Rescue.leftInWater(pivot: CFrame, config: Water.Rescue, areas: { WaterShape.Area }?): boolean
	local p = pivot.Position
	local surface = WaterShape.surfaceAt(p.X, p.Z, areas)
	return surface ~= nil and p.Y < surface + config.touch and WaterShape.depthAt(p.X, p.Z, areas) > 0
end

-- How long a car may stay as `reading` says, or nil when it may stay for good.
function Rescue.allowance(reading: Reading, config: Water.Rescue): number?
	if not reading.wet then
		return nil
	end
	if reading.flipped then
		return config.flippedSeconds
	end
	local allowed: number? = nil
	if reading.deep then
		allowed = config.seconds
	end
	if reading.stuck then
		allowed = math.min(allowed or math.huge, config.stuckSeconds)
	end
	return allowed
end

-- Moves the watch on to `now` (seconds) with the car's latest reading. True when the car has been in trouble for
-- longer than this reading allows: it must come out now (the watch starts over).
function Rescue.step(watch: Watch, reading: Reading, now: number, config: Water.Rescue): boolean
	local allowed = Rescue.allowance(reading, config)
	if allowed == nil then
		watch.since = nil
		return false
	end
	local since = watch.since
	if since == nil then
		watch.since = now
		return allowed <= 0
	end
	if now - since >= allowed then
		watch.since = nil
		return true
	end
	return false
end

return Rescue
