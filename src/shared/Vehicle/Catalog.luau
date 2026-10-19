--!strict
-- Read access to the vehicle catalog (Config/Vehicles), plus validate(): every trim must sit inside its class
-- band (PLAN.md §3.3) and every entry must be complete. tests/Catalog.spec runs validate().

local Shared = script.Parent.Parent
local Brands = require(Shared.Config.Brands)
local Classes = require(Shared.Config.Classes)
local Vehicles = require(Shared.Config.Vehicles)

local Catalog = {}

function Catalog.getVehicle(vehicleId: string): Vehicles.Vehicle?
	return Vehicles[vehicleId]
end

function Catalog.getTrim(vehicleId: string, trimId: string): Vehicles.Trim?
	local vehicle = Vehicles[vehicleId]
	if vehicle == nil then
		return nil
	end
	for _, trim in vehicle.trims do
		if trim.id == trimId then
			return trim
		end
	end
	return nil
end

function Catalog.defaultTrim(vehicleId: string): Vehicles.Trim?
	local vehicle = Vehicles[vehicleId]
	return if vehicle then vehicle.trims[1] else nil
end

-- The body geometry for a trim (a trim may replace its vehicle's geometry).
function Catalog.geometry(vehicleId: string, trimId: string): Vehicles.Geometry?
	local vehicle = Vehicles[vehicleId]
	local trim = Catalog.getTrim(vehicleId, trimId)
	if vehicle == nil or trim == nil then
		return nil
	end
	return trim.geometry or vehicle.geometry
end

-- Name of the model in ServerStorage.VehicleModels (vehicle model contract, PLAN.md §6).
function Catalog.modelName(vehicleId: string, trimId: string): string
	return `{vehicleId}_{trimId}`
end

-- Total in-game $ for a trim: an upgrade trim adds its cost to the trim it upgrades. nil if not sold for cash.
function Catalog.totalPrice(vehicleId: string, trimId: string): number?
	local trim = Catalog.getTrim(vehicleId, trimId)
	if trim == nil or trim.price == nil then
		return nil
	end
	if trim.upgradeFrom then
		local base = Catalog.totalPrice(vehicleId, trim.upgradeFrom)
		return if base then base + trim.price else nil
	end
	return trim.price
end

-- Every vehicle id, sorted, for menus and builders.
function Catalog.vehicleIds(): { string }
	local ids = {}
	for id in Vehicles do
		table.insert(ids, id)
	end
	table.sort(ids)
	return ids
end

local function inRange(value: number, range: Classes.Range): boolean
	return value >= range.min and value <= range.max
end

-- Returns a list of problems; an empty list means the catalog is valid.
function Catalog.validate(): { string }
	local problems: { string } = {}
	local function problem(message: string)
		table.insert(problems, message)
	end

	for id, vehicle in Vehicles do
		local where = id
		if vehicle.id ~= id then
			problem(`{where}: id field "{vehicle.id}" does not match its key`)
		end
		if Brands[vehicle.brandId] == nil then
			problem(`{where}: unknown brand "{vehicle.brandId}"`)
		end
		local class = Classes[vehicle.class]
		if class == nil then
			problem(`{where}: unknown class "{vehicle.class}"`)
			continue
		end
		if #vehicle.trims == 0 then
			problem(`{where}: has no trims`)
		end

		local seen: { [string]: boolean } = {}
		for _, trim in vehicle.trims do
			local at = `{where}/{trim.id}`
			if seen[trim.id] then
				problem(`{at}: duplicate trim id`)
			end
			seen[trim.id] = true

			if trim.upgradeFrom and Catalog.getTrim(id, trim.upgradeFrom) == nil then
				problem(`{at}: upgradeFrom "{trim.upgradeFrom}" is not a trim of {id}`)
			end
			local total = Catalog.totalPrice(id, trim.id)
			if total ~= nil and not inRange(total, class.price) then
				problem(`{at}: price {total} outside {class.id} band {class.price.min}-{class.price.max}`)
			end
			if not inRange(trim.topSpeedMph, class.topSpeedMph) then
				problem(`{at}: top speed {trim.topSpeedMph} outside {class.id} band`)
			end
			if not inRange(trim.zeroToSixtySec, class.zeroToSixtySec) then
				problem(`{at}: 0-60 {trim.zeroToSixtySec} outside {class.id} band`)
			end
			if trim.energyMinutes == nil then
				if vehicle.playerDrivable then
					problem(`{at}: drivable vehicles need energyMinutes`)
				end
			elseif not inRange(trim.energyMinutes, class.energyMinutes) then
				problem(`{at}: energy {trim.energyMinutes} min outside {class.id} band`)
			end
			if not inRange(trim.handling, class.handling) then
				problem(`{at}: handling {trim.handling} outside {class.id} band`)
			end
			if trim.seats % 1 ~= 0 or not inRange(trim.seats, class.seats) then
				problem(`{at}: seats {trim.seats} outside {class.id} band`)
			end

			local g = trim.geometry or vehicle.geometry
			if g.wheelbase >= g.length or g.track >= g.width then
				problem(`{at}: wheels must sit inside the body (wheelbase < length, track < width)`)
			end
			if g.rideHeight + g.chassisHeight > g.height then
				problem(`{at}: chassis box is taller than the body`)
			end
			if g.wheelRadius <= 0 or g.wheelWidth <= 0 or g.rideHeight <= 0 then
				problem(`{at}: wheel size and ride height must be positive`)
			end
		end
	end

	table.sort(problems)
	return problems
end

return Catalog
