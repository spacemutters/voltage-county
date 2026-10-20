--!strict
-- The Wrap & Tint shop on the server: buying a new look for an owned car, custom plate text, the shops'
-- "Customize" prompts, and putting each owned car's saved look on it when it comes out (PLAN.md Phase 7;
-- docs/phase-7-contracts.md "CustomizationService" and "Plates").
--
-- Remotes (declared in Net, which has already checked each payload's shape and rate-limited it):
--   BuyCustomization { uid, changes }  function: validates every value in `changes` against Config/Customization
--                                      (Customization.check: unknown ids, out-of-range numbers, extras the car's
--                                      class can't take), prices only what differs from the saved look
--                                      (Customization.priceOf), takes the cash and saves the new look in ONE
--                                      DataService.update, then puts the look on the car. Answers
--                                      { ok, message, cost }.
--   SetPlate { uid, text }             function: custom plate text (the Custom Plates pass; Studio only until that
--                                      pass exists). Empty text goes back to the free standard plate. Answers
--                                      { ok, message, cost = 0 }.
--
-- Where the shop works (canCustomize): only while the player sits in the Driver seat of their own garage car
-- (OwnedUid attribute, not a dealership test drive) and that car stands inside a CustomShop footprint (MapLayout:
-- one in Cedar Bend, one at The Plant). Both remotes check this on the server, so a client can't buy from the
-- other side of the map, and `uid` must be the car the player is sitting in. Looks never change stats, the car
-- instance or its physics (Vehicle/Appearance), so a job in progress doesn't stop a visit to the shop.
--
-- Prompts: every CustomShop part gets a "Customize" ProximityPrompt. DriveController hides prompts while the player
-- is seated, so in practice it reaches players on foot: the server re-checks canCustomize when it is triggered and
-- tells them why with a Notify toast (drive one of your cars in). A seated driver opens the shop with the client's
-- Customize button (Controllers/CustomizationController; docs/phase-7-contracts.md "Opening"), which buys through
-- the remotes above.
--
-- Plates (text safety, CLAUDE.md hard rule 5): OwnedVehicle.plateText stores the text exactly as the player typed
-- it (normalized), and that raw text never leaves the server. TextService filters it (broadcast context) when it
-- is set (text the filter changes is refused, so nothing unshowable is saved) and again every time the car
-- comes out. Only the filtered result is ever put on a plate; while the filter runs, or if it fails, the plate is
-- blank. The filtered text is cached per car model, so re-applying a look after a purchase doesn't filter again.
--
-- Spawned cars: GarageService calls CustomizationService.applySaved(player, model, vehicle) right after it marks
-- a new car with its OwnedUid. The look goes on at once (blank plate if the car has custom text) and the plate
-- text follows when the filter answers.
--
-- Server-authoritative (CLAUDE.md hard rule 1): the client only ever names a uid and the values it wants; the
-- server looks the car up in that player's own data, checks every value, prices it and decides. No polling:
-- everything runs on remote calls, prompt triggers and CollectionService signals.
--
-- The rules are exported as pure helpers (lookOf, changedFields, validate, canCustomize, insideFootprint,
-- checkPlateText, customTextAllowed) so tests/CustomizationService.spec can check them in Edit mode.

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TextService = game:GetService("TextService")

local Appearance = require(ReplicatedStorage.Shared.Vehicle.Appearance)
local Catalog = require(ReplicatedStorage.Shared.Vehicle.Catalog)
local Customization = require(ReplicatedStorage.Shared.Config.Customization)
local Economy = require(ReplicatedStorage.Shared.Config.Economy)
local Garage = require(ReplicatedStorage.Shared.Config.Garage)
local Net = require(ReplicatedStorage.Shared.Net)
local Types = require(ReplicatedStorage.Shared.Types)
local EconomyService = require(script.Parent.EconomyService)

-- DataService and VehicleService are required in Init rather than here: DataService loads ProfileStore, which
-- talks to DataStores straight away, and tests/CustomizationService.spec requires this module in Edit mode for
-- its pure helpers. MonetizationService (Phase 12) may not exist yet; Init looks for it.
type DataServiceModule = typeof(require(script.Parent.DataService))
type VehicleServiceModule = typeof(require(script.Parent.VehicleService))
type PassChecker = (player: Player, passId: string) -> boolean

export type Look = Customization.Look
export type Changes = Customization.Changes

-- What both remotes answer.
export type Reply = { ok: boolean, message: string, cost: number }

-- Everything canCustomize needs to know about the player and their car, gathered by the server (or a spec).
export type Situation = {
	hasCar: boolean, -- the player has a car out
	testDrive: boolean, -- it's a dealership test drive (Config/Garage.testDriveAttribute)
	ownedUid: string?, -- its OwnedUid attribute (nil: not a garage car)
	owned: boolean, -- that uid is in the player's own data
	inDriverSeat: boolean, -- the player sits in its Driver seat
	inShop: boolean, -- it stands inside a CustomShop footprint
}

-- The shop's settings (building, prompt, pass id, replies) live in Config/Customization.shop; option prices and
-- rules are the rest of that module.
local SHOP = Customization.shop

local LOG = "[CustomizationService]"
local DRIVER_SEAT = "Driver" -- seat names from the vehicle model contract
local SEATS_FOLDER = "Seats"

local messages = SHOP.messages

local CustomizationService = {}
CustomizationService.SHOP = SHOP

local DataService: DataServiceModule? = nil
local VehicleService: VehicleServiceModule? = nil
local hasPass: PassChecker? = nil

-- The plate text shown on each spawned car: the raw text it was filtered from (to tell when it is stale) and
-- the filtered result ("" while the filter runs or when it failed). Cleared when the model is destroyed.
type PlateEntry = { raw: string, shown: string }
local plates: { [Model]: PlateEntry } = {}

-- Pure helpers ----------------------------------------------------------------------------------------------

local function isFiniteNumber(value: any): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function stringOr(value: any, fallback: string): string
	return if type(value) == "string" then value else fallback
end

local function numberOr(value: any, fallback: number): number
	return if isFiniteNumber(value) then value else fallback
end

-- The strings in a saved extras list (a damaged save may hold anything), as a new list.
local function cleanExtras(value: any): { string }
	local list: { string } = {}
	if type(value) == "table" then
		for _, id in value do
			if type(id) == "string" then
				table.insert(list, id)
			end
		end
	end
	return list
end

-- The Look (Config/Customization) of an owned car, for Vehicle/Appearance and pricing. Damaged or missing
-- fields fall back to Customization.defaults. `shownPlate` is the plate text to put on the car: ALREADY
-- FILTERED text, "" for a blank plate, or nil for the plate format's standard number. The car's raw plateText
-- is never copied into a Look.
function CustomizationService.lookOf(vehicle: Types.OwnedVehicle, shownPlate: string?): Look
	local defaults = Customization.defaults
	local raw: any = vehicle
	return {
		uid = stringOr(raw.uid, ""),
		paint = stringOr(raw.paint, defaults.paint),
		finish = stringOr(raw.finish, defaults.finish),
		wrap = if type(raw.wrap) == "string" then raw.wrap else nil,
		wheels = stringOr(raw.wheels, defaults.wheels),
		rideHeight = numberOr(raw.rideHeight, defaults.rideHeight),
		tint = numberOr(raw.tint, defaults.tint),
		caliper = stringOr(raw.caliper, defaults.caliper),
		extras = cleanExtras(raw.extras),
		plateFormat = stringOr(raw.plateFormat, defaults.plateFormat),
		plateText = shownPlate,
	}
end

local function sameList(a: { string }, b: { string }): boolean
	if #a ~= #b then
		return false
	end
	for i, value in a do
		if b[i] ~= value then
			return false
		end
	end
	return true
end

-- The same tolerance as Config/Customization's checks and pricing (one rule for "unchanged").
local function sameNumber(a: number, b: number): boolean
	return Customization.sameNumber(a, b)
end

-- The look fields (Changes keys, "paint" for a custom color too) that differ between two looks. A wrap of nil
-- and "none" are the same (no wrap).
function CustomizationService.changedFields(before: Look, after: Look): { string }
	local changed: { string } = {}
	local function mark(field: string, differs: boolean)
		if differs then
			table.insert(changed, field)
		end
	end
	mark("paint", before.paint ~= after.paint)
	mark("finish", before.finish ~= after.finish)
	mark("wrap", (before.wrap or "none") ~= (after.wrap or "none"))
	mark("wheels", before.wheels ~= after.wheels)
	mark("rideHeight", not sameNumber(before.rideHeight, after.rideHeight))
	mark("tint", not sameNumber(before.tint, after.tint))
	mark("caliper", before.caliper ~= after.caliper)
	mark("extras", not sameList(before.extras, after.extras))
	mark("plateFormat", before.plateFormat ~= after.plateFormat)
	return changed
end

-- The catalog id an owned car is looked up by: a player design (vehicleId "custom") is published as
-- "custom:<designUid>" (Vehicle/Catalog, Services/VehicleService), every other car by its own vehicleId.
function CustomizationService.catalogIdOf(vehicle: Types.OwnedVehicle): string
	if vehicle.vehicleId == Garage.customVehicleId and type(vehicle.designUid) == "string" then
		return Catalog.designId(vehicle.designUid)
	end
	return vehicle.vehicleId
end

-- Validates and prices a change set for an owned car of `vehicleClass`. Returns ok, the message to show when
-- refused, the cost (whole $; only what differs from the saved look is charged) and the look the car ends up
-- with. Refuses unknown ids, out-of-range numbers and extras the class can't take (Customization.check), and a
-- change set that changes nothing. Pure: `vehicle` is not modified.
function CustomizationService.validate(
	vehicle: Types.OwnedVehicle,
	vehicleClass: string,
	changes: Changes
): (boolean, string?, number, Look?)
	if type(changes) ~= "table" then
		return false, Customization.messages.nothingChanged, 0, nil
	end
	-- The car's body style too: some extras fit only some bodies (a lip on a trunk, not on an SUV's rear window).
	local catalogVehicle = if type(vehicle.vehicleId) == "string"
		then Catalog.getVehicle(CustomizationService.catalogIdOf(vehicle))
		else nil
	local bodyStyle = if catalogVehicle ~= nil then catalogVehicle.bodyStyle else nil
	local allowed, problem = Customization.check(changes, vehicleClass, bodyStyle)
	if not allowed then
		return false, problem, 0, nil
	end
	local current = CustomizationService.lookOf(vehicle, nil)
	local after = Customization.applyChanges(current, changes)
	if #CustomizationService.changedFields(current, after) == 0 then
		return false, Customization.messages.nothingChanged, 0, nil
	end
	local cost = Customization.priceOf(changes, current, vehicleClass)
	return true, nil, cost, after
end

-- Writes a validated look onto a saved car (the look fields only; plate text, energy and the rest untouched).
function CustomizationService.saveLook(vehicle: Types.OwnedVehicle, look: Look)
	vehicle.paint = look.paint
	vehicle.finish = look.finish
	vehicle.wrap = if look.wrap == nil or look.wrap == Customization.defaults.wrap then nil else look.wrap
	vehicle.wheels = look.wheels
	vehicle.rideHeight = look.rideHeight
	vehicle.tint = look.tint
	vehicle.caliper = look.caliper
	vehicle.extras = table.clone(look.extras)
	vehicle.plateFormat = look.plateFormat
end

-- Whether the player may use the shop right now, and if not, what to tell them. `uid` (optional) must be the
-- car they sit in. The order matters: the first thing missing is what the player hears about.
function CustomizationService.canCustomize(situation: Situation, uid: string?): (boolean, string?)
	if not situation.hasCar then
		return false, messages.noCar
	end
	if situation.testDrive then
		return false, messages.testDrive
	end
	if situation.ownedUid == nil or not situation.owned then
		return false, messages.notOwned
	end
	if not situation.inDriverSeat then
		return false, messages.notDriving
	end
	if not situation.inShop then
		return false, messages.notInShop
	end
	if uid ~= nil and uid ~= situation.ownedUid then
		return false, messages.wrongCar
	end
	return true, nil
end

-- True when `point` lies over the footprint of a box at `frame` with `size` (its own X and Z, any height),
-- grown by `slack` studs on every side.
function CustomizationService.insideFootprint(frame: CFrame, size: Vector3, point: Vector3, slack: number): boolean
	local localPoint = frame:PointToObjectSpace(point)
	return math.abs(localPoint.X) <= size.X / 2 + slack and math.abs(localPoint.Z) <= size.Z / 2 + slack
end

-- Custom plate text as it is stored, or nil and the message to show when it breaks Config/Customization's
-- rules. "" (after trimming) means "back to the standard plate" and is always fine.
function CustomizationService.checkPlateText(text: string): (string?, string?)
	if type(text) ~= "string" then
		return nil, Customization.plate.allowedDescription
	end
	local normalized = Customization.normalizePlateText(text)
	if normalized == "" then
		return "", nil
	end
	if not Customization.isPlateTextAllowed(normalized) then
		return nil, Customization.plate.allowedDescription
	end
	return normalized, nil
end

-- Whether custom plate text is unlocked: by the Custom Plates pass once MonetizationService exists (`passOwned`
-- is its answer), else only in Studio.
function CustomizationService.customTextAllowed(passOwned: boolean?, isStudio: boolean): boolean
	if passOwned ~= nil then
		return passOwned
	end
	return isStudio
end

-- Helpers ---------------------------------------------------------------------------------------------------

local function reply(ok: boolean, message: string, cost: number?): Reply
	return { ok = ok, message = message, cost = cost or 0 }
end

local function notify(player: Player, text: string, kind: string)
	Net.fireClient("Notify", player, { text = text, kind = kind })
end

-- The car with `uid` in a player's data (only ever their own data).
local function findVehicle(data: Types.PlayerData, uid: string): Types.OwnedVehicle?
	if type(data.vehicles) ~= "table" then
		return nil
	end
	for _, vehicle in data.vehicles do
		if type(vehicle) == "table" and vehicle.uid == uid then
			return vehicle
		end
	end
	return nil
end

local function classOf(vehicle: Types.OwnedVehicle): string?
	local catalogVehicle = Catalog.getVehicle(CustomizationService.catalogIdOf(vehicle))
	return if catalogVehicle ~= nil then catalogVehicle.class else nil
end

-- True when the player's character sits in the car's Driver seat.
local function inDriverSeat(player: Player, car: Model): boolean
	local seats = car:FindFirstChild(SEATS_FOLDER)
	local seat = if seats ~= nil then seats:FindFirstChild(DRIVER_SEAT) else nil
	if seat == nil or not seat:IsA("Seat") then
		return false
	end
	local occupant = seat.Occupant
	return occupant ~= nil and occupant.Parent == player.Character
end

-- The CustomShop bay the point stands in, or nil.
local function shopAt(point: Vector3): BasePart?
	for _, instance in CollectionService:GetTagged(SHOP.tag) do
		if
			instance:IsA("BasePart")
			and CustomizationService.insideFootprint(instance.CFrame, instance.Size, point, SHOP.footprintSlack)
		then
			return instance
		end
	end
	return nil
end

-- Everything canCustomize needs, from the live game, plus the car and its saved entry when there is one.
local function situationOf(player: Player): (Situation, Model?, Types.OwnedVehicle?)
	local vehicleService, dataService = VehicleService, DataService
	local car = if vehicleService ~= nil then vehicleService.getCar(player) else nil
	local data = if dataService ~= nil then dataService.get(player) else nil
	local situation: Situation = {
		hasCar = car ~= nil,
		testDrive = false,
		ownedUid = nil,
		owned = false,
		inDriverSeat = false,
		inShop = false,
	}
	if car == nil then
		return situation, nil, nil
	end
	situation.testDrive = car:GetAttribute(Garage.testDriveAttribute) == true
	local uid = car:GetAttribute(Garage.ownedUidAttribute)
	local vehicle: Types.OwnedVehicle? = nil
	if type(uid) == "string" then
		situation.ownedUid = uid
		vehicle = if data ~= nil then findVehicle(data, uid) else nil
		situation.owned = vehicle ~= nil
	end
	situation.inDriverSeat = inDriverSeat(player, car)
	situation.inShop = shopAt(car:GetPivot().Position) ~= nil
	return situation, car, vehicle
end

-- Plate text --------------------------------------------------------------------------------------------------

-- TextService's broadcast-safe version of `text` written by `userId`, or nil when the filter call fails.
-- Yields (a web call).
local function filterPlate(text: string, userId: number): string?
	local ok, result = pcall(function(): string
		local filtered = TextService:FilterStringAsync(text, userId, Enum.TextFilterContext.PublicChat)
		return filtered:GetNonChatStringForBroadcastAsync()
	end)
	if not ok then
		warn(`{LOG} plate text filter failed for user {userId}: {result}`)
		return nil
	end
	return result
end

-- The plate text to show on a car model: nil (standard plate) for a car without custom text, else the cached
-- filtered text when it was filtered from the car's current raw text, else "" (blank) until it is.
local function shownPlate(model: Model, vehicle: Types.OwnedVehicle): string?
	local raw = vehicle.plateText
	if type(raw) ~= "string" or raw == "" then
		return nil
	end
	local entry = plates[model]
	if entry ~= nil and entry.raw == raw then
		return entry.shown
	end
	return ""
end

local function rememberPlate(model: Model, raw: string, shown: string)
	if plates[model] == nil then
		model.Destroying:Once(function()
			plates[model] = nil
		end)
	end
	plates[model] = { raw = raw, shown = shown }
end

-- Puts a car's saved look (and its filtered plate) on its model. Never lets a look problem break the caller.
local function applyLook(model: Model, vehicle: Types.OwnedVehicle)
	local look = CustomizationService.lookOf(vehicle, shownPlate(model, vehicle))
	local ok, err = pcall(function()
		Appearance.apply(model, look)
	end)
	if not ok then
		warn(`{LOG} couldn't apply the look of {vehicle.uid} to {model:GetFullName()}: {err}`)
	end
end

-- Re-applies the saved look of the player's car `model` (if it is still out and still that car).
local function refresh(player: Player, model: Model, uid: string)
	local dataService = DataService
	local data = if dataService ~= nil then dataService.get(player) else nil
	if data == nil or model.Parent == nil or model:GetAttribute(Garage.ownedUidAttribute) ~= uid then
		return
	end
	local vehicle = findVehicle(data, uid)
	if vehicle ~= nil then
		applyLook(model, vehicle)
	end
end

-- Filters the car's raw plate text and, if the car is still out, shows the result (a blank plate on failure).
local function filterAndShow(player: Player, model: Model, uid: string, raw: string)
	local filtered = filterPlate(raw, player.UserId)
	if model.Parent == nil then
		return
	end
	-- SetPlate may have saved (and shown) new text while this filter was out: never put the older text back.
	local dataService = DataService
	local data = if dataService ~= nil then dataService.get(player) else nil
	local vehicle = if data ~= nil then findVehicle(data, uid) else nil
	if vehicle == nil or vehicle.plateText ~= raw then
		return
	end
	rememberPlate(model, raw, filtered or "")
	refresh(player, model, uid)
end

-- Spawned cars ----------------------------------------------------------------------------------------------

-- Puts an owned car's saved look on its freshly spawned model (GarageService, right after it sets OwnedUid).
-- Custom plate text is filtered again in the background; the plate stays blank until the filter answers.
function CustomizationService.applySaved(player: Player, model: Model, vehicle: Types.OwnedVehicle)
	applyLook(model, vehicle)
	local raw = vehicle.plateText
	if type(raw) == "string" and raw ~= "" then
		task.spawn(filterAndShow, player, model, vehicle.uid, raw)
	end
end

-- Remotes ---------------------------------------------------------------------------------------------------

function CustomizationService.buy(player: Player, uid: string, changes: Changes): Reply
	local dataService = DataService
	if dataService == nil or dataService.get(player) == nil then
		return reply(false, messages.notLoaded)
	end
	local situation, car, vehicle = situationOf(player)
	local usable, refusal = CustomizationService.canCustomize(situation, uid)
	if not usable or car == nil or vehicle == nil then
		return reply(false, refusal or messages.notOwned)
	end
	local vehicleClass = classOf(vehicle)
	if vehicleClass == nil then
		return reply(false, messages.notOwned)
	end
	-- A first check against the data as it stands, so a refusal never touches the save.
	local ok, problem = CustomizationService.validate(vehicle, vehicleClass, changes)
	if not ok then
		return reply(false, problem or Customization.messages.nothingChanged)
	end

	-- Charge and save in one update, validated and priced again against the live data, so the cash and the look
	-- never disagree (a double click, a sale in between or a wallet that just changed can't charge without saving).
	-- The reply's cost is what was really taken.
	local refused: string? = nil
	local spent = 0
	local updated = dataService.update(player, function(data: Types.PlayerData)
		local fresh = findVehicle(data, uid)
		if fresh == nil then
			refused = messages.notOwned
			return
		end
		local freshOk, freshProblem, freshCost, after = CustomizationService.validate(fresh, vehicleClass, changes)
		if not freshOk or after == nil then
			refused = freshProblem or Customization.messages.nothingChanged
			return
		end
		if freshCost > 0 then
			local newBalance = EconomyService.applySpend(data.cash, freshCost)
			if newBalance == nil then
				refused = string.format(messages.cantAfford, Economy.formatCash(freshCost))
				return
			end
			spent = EconomyService.cleanBalance(data.cash) - newBalance
			data.cash = newBalance
		end
		CustomizationService.saveLook(fresh, after)
	end)
	if not updated then
		return reply(false, messages.saveFailed)
	end
	if refused ~= nil then
		return reply(false, refused)
	end
	if spent > 0 then
		EconomyService.recordChange(player, "sink", spent, SHOP.economyReason)
	end
	refresh(player, car, uid)
	print(`{LOG} {player.Name} customized {uid} for ${spent}`)
	local message = if spent > 0 then string.format(messages.bought, Economy.formatCash(spent)) else messages.boughtFree
	return reply(true, message, spent)
end

-- Whether the player owns the Custom Plates pass: true or false once MonetizationService exists, nil before.
local function passOwned(player: Player): boolean?
	local checker = hasPass
	if checker == nil then
		return nil
	end
	local ok, owned = pcall(checker, player, SHOP.passId)
	if not ok then
		warn(`{LOG} hasPass({SHOP.passId}) failed for {player.Name}: {owned}`)
		return false
	end
	return owned == true
end

function CustomizationService.setPlate(player: Player, uid: string, text: string): Reply
	local dataService = DataService
	if dataService == nil or dataService.get(player) == nil then
		return reply(false, messages.notLoaded)
	end
	local situation, car, vehicle = situationOf(player)
	local usable, refusal = CustomizationService.canCustomize(situation, uid)
	if not usable or car == nil or vehicle == nil then
		return reply(false, refusal or messages.notOwned)
	end
	local normalized, problem = CustomizationService.checkPlateText(text)
	if normalized == nil then
		return reply(false, problem or Customization.plate.allowedDescription)
	end
	local current = if type(vehicle.plateText) == "string" then vehicle.plateText else ""
	if normalized == current then
		return reply(false, messages.plateUnchanged)
	end

	local shown: string? = nil
	if normalized ~= "" then
		if not CustomizationService.customTextAllowed(passOwned(player), RunService:IsStudio()) then
			return reply(false, messages.plateNeedsPass)
		end
		local filtered = filterPlate(normalized, player.UserId) -- yields
		if filtered == nil then
			return reply(false, messages.plateFilterFailed)
		end
		if filtered ~= normalized then
			-- The filter hid some of it: refuse rather than save text that would show as hashes.
			return reply(false, messages.plateNotAllowed)
		end
		shown = filtered
	end

	local saved = false
	local updated = dataService.update(player, function(data: Types.PlayerData)
		local fresh = findVehicle(data, uid)
		if fresh ~= nil then
			fresh.plateText = if normalized == "" then nil else normalized
			saved = true
		end
	end)
	if not updated or not saved then
		return reply(false, if updated then messages.notOwned else messages.saveFailed)
	end
	if shown ~= nil and normalized ~= nil then
		rememberPlate(car, normalized, shown)
	end
	refresh(player, car, uid)
	return reply(true, if normalized == "" then messages.plateCleared else messages.plateSet)
end

-- Prompts ---------------------------------------------------------------------------------------------------

local function onPromptTriggered(player: Player)
	local situation = situationOf(player)
	local usable, refusal = CustomizationService.canCustomize(situation, nil)
	if not usable then
		notify(player, refusal or messages.noCar, "info")
	end
end

local function addPrompt(instance: Instance)
	if not instance:IsA("BasePart") or instance:FindFirstChild(SHOP.prompt.name) ~= nil then
		return
	end
	local settings = SHOP.prompt
	local displayName = instance:GetAttribute(SHOP.displayNameAttribute)
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = settings.name
	prompt.ActionText = settings.actionText
	prompt.ObjectText = if type(displayName) == "string" then displayName else settings.objectText
	prompt.HoldDuration = settings.holdSeconds
	-- From the bay's centre to its farthest corner, plus a margin.
	prompt.MaxActivationDistance = Vector2.new(instance.Size.X, instance.Size.Z).Magnitude / 2 + settings.reachMargin
	prompt.RequiresLineOfSight = false -- the car's own body would otherwise hide it from the driver
	prompt.Triggered:Connect(onPromptTriggered)
	prompt.Parent = instance
end

-- Boot ------------------------------------------------------------------------------------------------------

function CustomizationService:Init()
	DataService = require(script.Parent.DataService)
	VehicleService = require(script.Parent.VehicleService)
	local monetization = script.Parent:FindFirstChild("MonetizationService")
	if monetization ~= nil and monetization:IsA("ModuleScript") then
		local ok, module = pcall(require, monetization)
		if ok and type(module) == "table" and type((module :: any).hasPass) == "function" then
			hasPass = (module :: any).hasPass
		end
	end
end

function CustomizationService:Start()
	Net.onServerInvoke("BuyCustomization", function(player: Player, payload: any): Reply
		return CustomizationService.buy(player, payload.uid, payload.changes)
	end)
	Net.onServerInvoke("SetPlate", function(player: Player, payload: any): Reply
		return CustomizationService.setPlate(player, payload.uid, payload.text)
	end)
	for _, instance in CollectionService:GetTagged(SHOP.tag) do
		addPrompt(instance)
	end
	CollectionService:GetInstanceAddedSignal(SHOP.tag):Connect(addPrompt)
end

return CustomizationService
