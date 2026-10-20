--!strict
-- Read access to the vehicle catalog (Config/Vehicles), plus validate(): every trim must sit inside its class
-- band (PLAN.md §3.3) and every entry must be complete. tests/Catalog.spec runs validate().
--
-- Player designs (Phase 11, docs/phase-11-contracts.md "Designs in the catalog") join the lookups without touching
-- any call site: a design is the entry "custom:<designUid>" (Config/Designer.catalogPrefix) with one trim "design"
-- (Config/Designer.designTrim), made by Vehicle/SpecBuilder.vehicleFor. The server publishes it with
-- publishDesign, as JSON in a StringValue named after the design under ReplicatedStorage.DesignCatalog, so the
-- server and every client resolve getVehicle / getTrim / geometry / modelName for it the same way. Each design is
-- decoded once and cached until its StringValue changes. vehicleIds() and validate() stay catalog-only.

local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = script.Parent.Parent
local Brands = require(Shared.Config.Brands)
local Classes = require(Shared.Config.Classes)
local Designer = require(Shared.Config.Designer)
local Garage = require(Shared.Config.Garage)
local Vehicles = require(Shared.Config.Vehicles)

-- The folder under ReplicatedStorage that holds published designs (docs/phase-11-contracts.md).
local DESIGN_FOLDER = "DesignCatalog"

local Catalog = {}

----------------------------------------------------------------------------------------------------------------
-- Player designs
----------------------------------------------------------------------------------------------------------------

type Cached = { source: string, vehicle: Vehicles.Vehicle? }
local designCache: { [string]: Cached } = {}

-- True for a design's catalog id ("custom:<designUid>").
function Catalog.isDesign(vehicleId: string): boolean
	local prefix = Designer.catalogPrefix
	return type(vehicleId) == "string" and #vehicleId > #prefix and string.sub(vehicleId, 1, #prefix) == prefix
end

-- The design uid in a design's catalog id, or nil for any other id.
function Catalog.designUidOf(vehicleId: string): string?
	if not Catalog.isDesign(vehicleId) then
		return nil
	end
	return string.sub(vehicleId, #Designer.catalogPrefix + 1)
end

-- A design's catalog id.
function Catalog.designId(designUid: string): string
	return Designer.catalogPrefix .. designUid
end

local function isNumber(value: any): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local GEOMETRY_FIELDS =
	{ "length", "width", "height", "wheelbase", "track", "wheelRadius", "wheelWidth", "rideHeight", "chassisHeight" }
local TRIM_NUMBERS = { "topSpeedMph", "zeroToSixtySec", "seats", "handling" }

-- A published design decoded and checked to have every field the game reads, or nil.
local function decodeDesign(source: string, vehicleId: string): Vehicles.Vehicle?
	local ok, decoded = pcall(function()
		return HttpService:JSONDecode(source)
	end)
	if not ok or type(decoded) ~= "table" then
		return nil
	end
	local entry = decoded :: any
	if
		entry.id ~= vehicleId
		or type(entry.brandId) ~= "string"
		or type(entry.displayName) ~= "string"
		or type(entry.class) ~= "string"
		or type(entry.bodyStyle) ~= "string"
		or (entry.energy ~= "battery" and entry.energy ~= "fuel")
		or type(entry.geometry) ~= "table"
		or type(entry.trims) ~= "table"
		or #entry.trims == 0
	then
		return nil
	end
	for _, field in GEOMETRY_FIELDS do
		if not isNumber(entry.geometry[field]) then
			return nil
		end
	end
	for _, trim in entry.trims do
		if type(trim) ~= "table" or type(trim.id) ~= "string" or type(trim.displayName) ~= "string" then
			return nil
		end
		for _, field in TRIM_NUMBERS do
			if not isNumber(trim[field]) then
				return nil
			end
		end
	end
	entry.playerDrivable = entry.playerDrivable == true
	if type(entry.features) ~= "table" then
		entry.features = {}
	end
	return entry :: Vehicles.Vehicle
end

local function designVehicle(vehicleId: string): Vehicles.Vehicle?
	local uid = Catalog.designUidOf(vehicleId)
	if uid == nil then
		return nil
	end
	local folder = ReplicatedStorage:FindFirstChild(DESIGN_FOLDER)
	local value = if folder then folder:FindFirstChild(uid) else nil
	if value == nil or not value:IsA("StringValue") then
		designCache[uid] = nil
		return nil
	end
	local source = value.Value
	local cached = designCache[uid]
	if cached ~= nil and cached.source == source then
		return cached.vehicle
	end
	local vehicle = decodeDesign(source, vehicleId)
	designCache[uid] = { source = source, vehicle = vehicle }
	return vehicle
end

local function requireServer(what: string)
	if not RunService:IsServer() then
		error(`Catalog.{what} runs on the server`, 3)
	end
end

-- Publishes a design's catalog entry (SpecBuilder.vehicleFor) so the server and every client can look it up as
-- "custom:<designUid>". Publishing the same entry again changes nothing. Server only.
function Catalog.publishDesign(designUid: string, vehicle: Vehicles.Vehicle)
	requireServer("publishDesign")
	if type(designUid) ~= "string" or designUid == "" then
		error("Catalog.publishDesign needs a design uid", 2)
	end
	local vehicleId = Catalog.designId(designUid)
	if vehicle.id ~= vehicleId then
		error(`Catalog.publishDesign: the entry's id must be {vehicleId}`, 2)
	end
	local folder = ReplicatedStorage:FindFirstChild(DESIGN_FOLDER)
	if folder == nil then
		local created = Instance.new("Folder")
		created.Name = DESIGN_FOLDER
		created.Parent = ReplicatedStorage
		folder = created
	end
	local parent = folder :: Instance
	local value = parent:FindFirstChild(designUid)
	if value == nil or not value:IsA("StringValue") then
		if value then
			value:Destroy()
		end
		local created = Instance.new("StringValue")
		created.Name = designUid
		created.Parent = parent
		value = created
	end
	local source = HttpService:JSONEncode(vehicle)
	local holder = value :: StringValue
	if holder.Value ~= source then
		holder.Value = source
	end
	designCache[designUid] = { source = source, vehicle = decodeDesign(source, vehicleId) }
end

-- Removes a published design (a scrapped design, or a spec cleaning up). Server only.
function Catalog.unpublishDesign(designUid: string)
	requireServer("unpublishDesign")
	designCache[designUid] = nil
	local folder = ReplicatedStorage:FindFirstChild(DESIGN_FOLDER)
	local value = if folder then folder:FindFirstChild(designUid) else nil
	if value then
		value:Destroy()
	end
	if folder and #folder:GetChildren() == 0 then
		folder:Destroy()
	end
end

----------------------------------------------------------------------------------------------------------------
-- Lookups
----------------------------------------------------------------------------------------------------------------

function Catalog.getVehicle(vehicleId: string): Vehicles.Vehicle?
	return Vehicles[vehicleId] or designVehicle(vehicleId)
end

function Catalog.getTrim(vehicleId: string, trimId: string): Vehicles.Trim?
	local vehicle = Catalog.getVehicle(vehicleId)
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
	local vehicle = Catalog.getVehicle(vehicleId)
	return if vehicle then vehicle.trims[1] else nil
end

-- The body geometry for a trim (a trim may replace its vehicle's geometry).
function Catalog.geometry(vehicleId: string, trimId: string): Vehicles.Geometry?
	local vehicle = Catalog.getVehicle(vehicleId)
	local trim = Catalog.getTrim(vehicleId, trimId)
	if vehicle == nil or trim == nil then
		return nil
	end
	return trim.geometry or vehicle.geometry
end

-- Name of the model in ServerStorage.VehicleModels (vehicle model contract, PLAN.md §6). A design's model is
-- "custom_<designUid>" (Vehicle/SpecBuilder).
function Catalog.modelName(vehicleId: string, trimId: string): string
	local designUid = Catalog.designUidOf(vehicleId)
	if designUid ~= nil then
		return `{Garage.customVehicleId}_{designUid}`
	end
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

-- Every vehicle id, sorted, for menus and builders. Catalog vehicles only (never player designs).
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

-- Returns a list of problems; an empty list means the catalog is valid. Catalog vehicles only.
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
