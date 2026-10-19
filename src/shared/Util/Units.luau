--!strict
-- Speed conversions between real-world units and studs per second, using the one scale constant in
-- Config/World (PLAN.md §5). Everything that shows or compares mph goes through here.

local World = require(script.Parent.Parent.Config.World)

local METERS_PER_MILE = 1609.344
local SECONDS_PER_HOUR = 3600
local METERS_PER_KILOMETER = 1000

local Units = {}

function Units.mphToStuds(mph: number): number
	return mph * METERS_PER_MILE / SECONDS_PER_HOUR / World.metersPerStud
end

function Units.studsToMph(studsPerSecond: number): number
	return studsPerSecond * World.metersPerStud * SECONDS_PER_HOUR / METERS_PER_MILE
end

function Units.studsToKph(studsPerSecond: number): number
	return studsPerSecond * World.metersPerStud * SECONDS_PER_HOUR / METERS_PER_KILOMETER
end

function Units.studsToMeters(studs: number): number
	return studs * World.metersPerStud
end

return Units
