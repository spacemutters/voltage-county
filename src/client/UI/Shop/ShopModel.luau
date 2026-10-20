--!strict
-- The shop sheets' logic, with no UI and no network (docs/phase-4-contracts.md "Shops"), so tests/Shop.spec can
-- check it in Edit mode:
--
--   targetOf(prompt)          which shop a "View" prompt opens: a dealership car (VehicleId) or a used-lot
--                             space (Slot), read from the prompt or the display car it sits in
--   ranges() / fraction()     stat bars scaled to the whole catalog's range (0-60 inverted: quicker is fuller)
--   stats()                   the five stat rows for a trim, in the player's speed units
--   initialTrim(), chipLabel() which trim the dealership opens on, and the short names on the trim chips
--   offer()                   what the dealership can do with a trim for this player: buy, upgrade, or where
--                             to get it instead, with the price and the cash left after
--   normalizeLot()            today's used-lot stock from a GetUsedLot reply
--   outcome()                 a remote's reply as (ok, message, toast kind)
--   layoutFor()               sheet, wide card or card for a screen size
--
-- Everything the player reads comes from UI/Shop/Style; every number from Config and Theme. The server decides
-- every purchase: these checks only keep the buttons honest (a Buy you can't afford is shown as such).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Brands = require(ReplicatedStorage.Shared.Config.Brands)
local Classes = require(ReplicatedStorage.Shared.Config.Classes)
local Dealership = require(ReplicatedStorage.Shared.Config.Dealership)
local Economy = require(ReplicatedStorage.Shared.Config.Economy)
local Garage = require(ReplicatedStorage.Shared.Config.Garage)
local Vehicles = require(ReplicatedStorage.Shared.Config.Vehicles)
local Catalog = require(ReplicatedStorage.Shared.Vehicle.Catalog)
local Theme = require(script.Parent.Parent.Theme)
local Style = require(script.Parent.Style)

local KPH_PER_MPH = 1.609344 -- a unit conversion, not a tunable
local HANDLING_SCALE = 10 -- handling (0..1) is shown out of 10

-- The "View" prompt on display cars and its attributes (DealershipService and UsedLotService set them).
local viewPrompt = Dealership.prompt

export type Units = "mph" | "kph"

export type Range = { min: number, max: number }

export type Ranges = {
	topSpeedMph: Range,
	zeroToSixtySec: Range,
	energyMinutes: Range,
	handling: Range,
	seats: Range,
}

export type StatRow = {
	id: string,
	label: string,
	value: string,
	fraction: number, -- 0..1 bar fill
}

-- The parts of the ProfileSnapshot (ProfileSyncService) the shops read. Read defensively: any field may be
-- missing until the first snapshot arrives.
export type OwnedSummary = { uid: string, vehicleId: string, trim: string }
export type Snapshot = {
	cash: number?,
	garageSlots: number?,
	starterClaimed: boolean?,
	vehicles: { OwnedSummary }?,
	settings: { units: string? }?,
}

-- What the dealership offers for one trim:
--   buy            a dealership trim: Buy (BuyVehicle)
--   upgrade        an upgrade trim whose base trim the player owns: Upgrade (UpgradeVehicle on `upgradeUid`)
--   upgradeLocked  an upgrade trim without the base trim: says to buy the base first
--   elsewhere      not sold here (starter, used lot, fleet, limited drop): `how` says where to get it
export type OfferKind = "buy" | "upgrade" | "upgradeLocked" | "elsewhere"

export type Offer = {
	kind: OfferKind,
	price: number?, -- what the button charges (the upgrade cost for upgrades)
	cash: number?, -- the player's cash, when known
	cashAfter: number?, -- cash - price, when both are known
	shortBy: number?, -- how much more cash the player needs, when they can't afford it
	garageFull: boolean, -- a purchase would need a garage slot and none is free
	upgradeUid: string?, -- the owned car an upgrade applies to
	baseTrimName: string?, -- display name of the trim an upgrade needs
	how: string?, -- where to get an `elsewhere` trim
	canTestDrive: boolean,
	ownedCount: number, -- how many of this exact trim the player owns
}

export type Target = { kind: "dealership", vehicleId: string, trim: string? } | { kind: "usedLot", slot: number }

-- One used-lot space today (GetUsedLot), normalized.
export type LotEntry = {
	slot: number,
	vehicleId: string,
	trim: string,
	price: number, -- today's price
	basePrice: number?,
	remaining: number?, -- how many are left today across every server; nil when the server didn't say
	supply: number?,
}

export type LayoutMode = "sheet" | "card" | "wide"
export type Layout = {
	mode: LayoutMode,
	width: number, -- of the sheet, unscaled pixels
	maxHeight: number,
	asideWidth: number, -- right column of a wide card (0 otherwise)
}

local ShopModel = {}

-- The stat rows every trim shows, in order (stats() below).
ShopModel.statIds = { "topSpeed", "zeroToSixty", "range", "handling", "seats" }

local copy = Style.copy
local layout = Style.layout

local function isWhole(value: any): boolean
	return type(value) == "number" and value == value and value % 1 == 0
end

local function finite(value: any): number?
	if type(value) == "number" and value == value and math.abs(value) ~= math.huge then
		return value
	end
	return nil
end

-- Prompt targets ---------------------------------------------------------------------------------------------

-- The shop a triggered prompt opens, or nil when it isn't a shop's "View" prompt (Config/Dealership.prompt: its
-- name or its action text). The prompt is checked first, then each ancestor up to the Workspace (the display
-- car model carries the attributes too). At each level a Slot wins over a VehicleId, since a used-lot display
-- car is a vehicle model too.
function ShopModel.targetOf(prompt: ProximityPrompt): Target?
	if prompt.Name ~= viewPrompt.name and prompt.ActionText ~= viewPrompt.actionText then
		return nil
	end
	local node: Instance? = prompt
	while node ~= nil and node ~= game and not node:IsA("Workspace") do
		local slot = node:GetAttribute(viewPrompt.slotAttribute)
		if slot ~= nil then
			if isWhole(slot) and (slot :: number) >= 1 then
				return { kind = "usedLot", slot = slot :: number }
			end
			return nil -- a broken Slot: don't guess
		end
		local vehicleId = node:GetAttribute(viewPrompt.vehicleIdAttribute)
		if vehicleId ~= nil then
			if type(vehicleId) ~= "string" or Catalog.getVehicle(vehicleId) == nil then
				return nil
			end
			local trim = node:GetAttribute(viewPrompt.trimAttribute)
			return { kind = "dealership", vehicleId = vehicleId, trim = if type(trim) == "string" then trim else nil }
		end
		node = node.Parent
	end
	return nil
end

-- Stat bars --------------------------------------------------------------------------------------------------

local function emptyRange(): Range
	return { min = math.huge, max = -math.huge }
end

local function widen(range: Range, value: number?)
	if value ~= nil then
		range.min = math.min(range.min, value)
		range.max = math.max(range.max, value)
	end
end

-- An empty range (no trim had the stat) becomes 0..1 so fractions stay defined.
local function settle(range: Range): Range
	if range.min > range.max then
		return { min = 0, max = 1 }
	end
	return range
end

-- The smallest and largest value of each stat over every trim of every vehicle in `vehicles`.
function ShopModel.rangesOf(vehicles: { [string]: Vehicles.Vehicle }): Ranges
	local topSpeed, zeroToSixty, energy, handling, seats =
		emptyRange(), emptyRange(), emptyRange(), emptyRange(), emptyRange()
	for _, vehicle in vehicles do
		for _, trim in vehicle.trims do
			widen(topSpeed, trim.topSpeedMph)
			widen(zeroToSixty, trim.zeroToSixtySec)
			widen(energy, trim.energyMinutes)
			widen(handling, trim.handling)
			widen(seats, trim.seats)
		end
	end
	return {
		topSpeedMph = settle(topSpeed),
		zeroToSixtySec = settle(zeroToSixty),
		energyMinutes = settle(energy),
		handling = settle(handling),
		seats = settle(seats),
	}
end

local catalogRanges: Ranges? = nil

-- The whole catalog's ranges (Config/Vehicles never changes while the game runs, so this is worked out once).
function ShopModel.ranges(): Ranges
	local cached = catalogRanges
	if cached == nil then
		cached = ShopModel.rangesOf(Vehicles)
		catalogRanges = cached
	end
	return cached :: Ranges
end

-- How full a stat bar is: `value` placed in `range`, flipped when lower is better (0-60), never below
-- `minFill` so the lowest value still shows. A range with no spread reads as full.
function ShopModel.fraction(value: number, range: Range, lowerIsBetter: boolean?, minFill: number?): number
	local floor = minFill or layout.statMinFill
	local span = range.max - range.min
	local t = if span > 0 then math.clamp((value - range.min) / span, 0, 1) else 1
	if lowerIsBetter and span > 0 then
		t = 1 - t
	end
	return floor + (1 - floor) * t
end

-- The stat rows for a trim (ShopModel.statIds, top speed in the player's units), or an empty list for an unknown
-- trim.
function ShopModel.stats(vehicleId: string, trimId: string, units: Units?, ranges: Ranges?): { StatRow }
	local trim = Catalog.getTrim(vehicleId, trimId)
	if trim == nil then
		return {}
	end
	local r = ranges or ShopModel.ranges()
	local labels, formats = copy.stats, copy.units

	local speed = if units == "kph"
		then string.format(formats.kph, math.round(trim.topSpeedMph * KPH_PER_MPH))
		else string.format(formats.mph, math.round(trim.topSpeedMph))
	local energy = trim.energyMinutes

	return {
		{
			id = "topSpeed",
			label = labels.topSpeed,
			value = speed,
			fraction = ShopModel.fraction(trim.topSpeedMph, r.topSpeedMph),
		},
		{
			id = "zeroToSixty",
			label = labels.zeroToSixty,
			value = string.format(formats.seconds, trim.zeroToSixtySec),
			fraction = ShopModel.fraction(trim.zeroToSixtySec, r.zeroToSixtySec, true),
		},
		{
			id = "range",
			label = labels.range,
			value = if energy ~= nil then string.format(formats.minutes, math.round(energy)) else formats.none,
			fraction = if energy ~= nil then ShopModel.fraction(energy, r.energyMinutes) else 0,
		},
		{
			id = "handling",
			label = labels.handling,
			value = string.format(formats.handling, trim.handling * HANDLING_SCALE),
			fraction = ShopModel.fraction(trim.handling, r.handling),
		},
		{
			id = "seats",
			label = labels.seats,
			value = string.format(formats.seats, trim.seats),
			fraction = ShopModel.fraction(trim.seats, r.seats),
		},
	}
end

-- Names ------------------------------------------------------------------------------------------------------

-- A trim chip's label: the trim name without the model name in front ("Spark Long Range" on the Ohm Spark
-- reads "Long Range"). Names that would lose their meaning ("Spark", "Spark (used)") stay whole.
function ShopModel.chipLabel(vehicle: Vehicles.Vehicle, trim: Vehicles.Trim): string
	local name = trim.displayName
	local first, rest = string.match(name, "^(%S+)%s+(.+)$")
	if first == nil or rest == nil or string.sub(rest, 1, 1) == "(" then
		return name
	end
	for word in string.gmatch(vehicle.displayName, "%S+") do
		if word == first then
			return rest
		end
	end
	return name
end

-- "Sedan · RWD · Electric": the class, drive and energy of a trim, with an optional leading part.
function ShopModel.specLine(vehicle: Vehicles.Vehicle, trim: Vehicles.Trim, lead: string?): string
	local parts: { string } = {}
	if lead ~= nil and lead ~= "" then
		table.insert(parts, lead)
	end
	local class = Classes[vehicle.class]
	table.insert(parts, if class then class.displayName else vehicle.class)
	table.insert(parts, trim.drive)
	table.insert(parts, copy.energy[vehicle.energy] or vehicle.energy)
	return table.concat(parts, copy.separator)
end

-- The brand's display name and segment ("Ohm Motors", "Electric hero brand"). Fictional names only
-- (Config/Brands).
function ShopModel.brandOf(vehicle: Vehicles.Vehicle): (string, string)
	local brand = Brands[vehicle.brandId]
	if brand == nil then
		return "", ""
	end
	return brand.displayName, brand.segment
end

-- The display name of the free starter car (the first vehicle with a "starter" trim), for the claim banner.
function ShopModel.starterName(): string
	for _, vehicleId in Catalog.vehicleIds() do
		local vehicle = Catalog.getVehicle(vehicleId)
		if vehicle ~= nil then
			for _, trim in vehicle.trims do
				if trim.acquisition == "starter" then
					return vehicle.displayName
				end
			end
		end
	end
	return copy.claimFallbackCar
end

-- Trims and offers -------------------------------------------------------------------------------------------

local function isBuyable(trim: Vehicles.Trim): boolean
	return trim.acquisition == "dealership" and trim.upgradeFrom == nil and trim.price ~= nil
end

-- The trim the dealership sheet opens on: `preferred` (the display car's trim) when it is sold here, else the
-- first trim sold here, else the first trim. nil for an unknown vehicle.
function ShopModel.initialTrim(vehicleId: string, preferred: string?): string?
	local vehicle = Catalog.getVehicle(vehicleId)
	if vehicle == nil or #vehicle.trims == 0 then
		return nil
	end
	if preferred ~= nil then
		local trim = Catalog.getTrim(vehicleId, preferred)
		if trim ~= nil and trim.acquisition == "dealership" then
			return trim.id
		end
	end
	for _, trim in vehicle.trims do
		if isBuyable(trim) then
			return trim.id
		end
	end
	return vehicle.trims[1].id
end

-- The player's owned cars from a snapshot, skipping anything malformed.
local function ownedOf(snapshot: Snapshot?): { OwnedSummary }
	local owned: { OwnedSummary } = {}
	local list = if snapshot ~= nil then snapshot.vehicles else nil
	if type(list) ~= "table" then
		return owned
	end
	for _, entry in list do
		if
			type(entry) == "table"
			and type(entry.uid) == "string"
			and type(entry.vehicleId) == "string"
			and type(entry.trim) == "string"
		then
			table.insert(owned, entry)
		end
	end
	return owned
end

-- True when the snapshot says every garage slot is taken. Player designs live in their own slots and don't
-- count (GarageService.slotsUsed does the same).
function ShopModel.garageFull(snapshot: Snapshot?): boolean
	if snapshot == nil or not isWhole(snapshot.garageSlots) then
		return false
	end
	local used = 0
	for _, car in ownedOf(snapshot) do
		if car.vehicleId ~= Garage.customVehicleId then
			used += 1
		end
	end
	return used >= (snapshot.garageSlots :: number)
end

-- Cash maths for a price: (cashAfter, shortBy), each nil when it doesn't apply.
local function afford(cash: number?, price: number?): (number?, number?)
	if cash == nil or price == nil then
		return nil, nil
	end
	local after = cash - price
	return after, if after < 0 then -after else nil
end

-- What the dealership offers `vehicleId`/`trimId` to a player with this snapshot and cash (either may be nil
-- while loading; the server checks again anyway).
function ShopModel.offer(vehicleId: string, trimId: string, snapshot: Snapshot?, cash: number?): Offer
	local vehicle = Catalog.getVehicle(vehicleId)
	local trim = Catalog.getTrim(vehicleId, trimId)
	local owned = ownedOf(snapshot)
	local ownedCount = 0
	for _, car in owned do
		if car.vehicleId == vehicleId and car.trim == trimId then
			ownedCount += 1
		end
	end

	local offer: Offer = {
		kind = "elsewhere",
		price = nil,
		cash = cash,
		cashAfter = nil,
		shortBy = nil,
		garageFull = false,
		upgradeUid = nil,
		baseTrimName = nil,
		how = copy.how.other,
		canTestDrive = false,
		ownedCount = ownedCount,
	}
	if vehicle == nil or trim == nil then
		return offer
	end

	if trim.acquisition ~= "dealership" or trim.price == nil then
		local how = copy.how[trim.acquisition] or copy.how.other
		offer.how = if trim.acquisition == "starter" then string.format(how, vehicle.displayName) else how
		return offer
	end

	offer.how = nil
	offer.canTestDrive = vehicle.playerDrivable

	local baseId = trim.upgradeFrom
	if baseId ~= nil then
		-- An upgrade changes a car the player owns; it needs no new garage slot.
		local base = Catalog.getTrim(vehicleId, baseId)
		offer.baseTrimName = if base then base.displayName else baseId
		offer.price = trim.price
		for _, car in owned do
			if car.vehicleId == vehicleId and car.trim == baseId then
				offer.upgradeUid = car.uid
				break
			end
		end
		offer.kind = if offer.upgradeUid ~= nil then "upgrade" else "upgradeLocked"
	else
		offer.kind = "buy"
		offer.price = Catalog.totalPrice(vehicleId, trimId)
		offer.garageFull = ShopModel.garageFull(snapshot)
	end
	offer.cashAfter, offer.shortBy = afford(cash, offer.price)
	return offer
end

-- Used lot ---------------------------------------------------------------------------------------------------

-- The list inside a GetUsedLot reply: the reply itself (a list), or its `stock` / `slots` / `items` field.
local function lotList(reply: { [any]: any }): { [any]: any }?
	for _, key in { "stock", "slots", "items" } do
		local list = reply[key]
		if type(list) == "table" then
			return list
		end
	end
	return reply
end

-- Today's stock from a GetUsedLot reply ({ ok, message, starterClaimed, stock = { Offer } }, UsedLotService),
-- sorted by slot. Returns (nil, message) when the server said no, and (nil, nil) when the reply isn't a table
-- (Net turned the call away). Entries without a slot, a known car or a price are skipped. The price is `price`
-- (or `currentPrice`), falling back to `basePrice` when missing or 0 (a sold-out space prices at 0); what's left
-- is `remaining` (or `left`, or `supply - sold`).
function ShopModel.normalizeLot(reply: any): ({ LotEntry }?, string?)
	if type(reply) ~= "table" then
		return nil, nil
	end
	if reply.ok == false then
		return nil, if type(reply.message) == "string" then reply.message else nil
	end
	local list = lotList(reply)
	if list == nil then
		return nil, nil
	end
	local entries: { LotEntry } = {}
	for _, raw in list do
		if type(raw) ~= "table" then
			continue
		end
		local slot, vehicleId, trim = raw.slot, raw.vehicleId, raw.trim
		if not isWhole(slot) or type(vehicleId) ~= "string" or type(trim) ~= "string" then
			continue
		end
		if Catalog.getTrim(vehicleId, trim) == nil then
			continue
		end
		local basePrice = finite(raw.basePrice)
		local price = finite(raw.price) or finite(raw.currentPrice)
		if price == nil or (price <= 0 and basePrice ~= nil) then
			price = basePrice
		end
		if price == nil then
			continue
		end
		local supply = finite(raw.supply)
		local sold = finite(raw.sold)
		local remaining = finite(raw.remaining) or finite(raw.left)
		if remaining == nil and supply ~= nil and sold ~= nil then
			remaining = supply - sold
		end
		table.insert(entries, {
			slot = slot,
			vehicleId = vehicleId,
			trim = trim,
			price = price,
			basePrice = basePrice,
			remaining = if remaining ~= nil then math.max(remaining, 0) else nil,
			supply = supply,
		})
	end
	table.sort(entries, function(a: LotEntry, b: LotEntry): boolean
		return a.slot < b.slot
	end)
	return entries, nil
end

-- Whether the player has claimed the free starter, as a GetUsedLot reply says (nil when it doesn't say).
function ShopModel.lotStarterClaimed(reply: any): boolean?
	if type(reply) == "table" and type(reply.starterClaimed) == "boolean" then
		return reply.starterClaimed
	end
	return nil
end

function ShopModel.lotEntry(entries: { LotEntry }?, slot: number): LotEntry?
	if entries == nil then
		return nil
	end
	for _, entry in entries do
		if entry.slot == slot then
			return entry
		end
	end
	return nil
end

-- "3 left today", "Sold out today", or nil when the server didn't say.
function ShopModel.remainingText(remaining: number?): string?
	if remaining == nil then
		return nil
	elseif remaining <= 0 then
		return copy.soldOut
	end
	return string.format(copy.left, remaining)
end

-- Replies ----------------------------------------------------------------------------------------------------

-- A remote call's result as (ok, message, toast kind). `called` is false when the call itself failed (pcall);
-- a reply that isn't a table means Net turned the call away (too many in a row).
function ShopModel.outcome(called: boolean, reply: any): (boolean, string, string)
	if not called then
		return false, copy.failed, "error"
	end
	if type(reply) ~= "table" then
		return false, copy.tryLater, "warning"
	end
	local ok = reply.ok == true
	local message = reply.message
	if type(message) ~= "string" or message == "" then
		message = if ok then copy.done else copy.failed
	end
	return ok, message, if ok then "success" else "error"
end

-- Cash and layout --------------------------------------------------------------------------------------------

-- "$12,345", via Config/Economy.
function ShopModel.cash(amount: number): string
	return Economy.formatCash(amount)
end

-- The sheet's shape for a screen (unscaled pixels inside the safe area). See Style.layout.
function ShopModel.layoutFor(screen: Vector2): Layout
	local maxHeight = math.floor(screen.Y * Theme.size.sheetMaxHeightScale)
	if screen.X >= layout.wideMinWidth and screen.Y < layout.wideBelowHeight then
		local width = math.min(screen.X - 2 * layout.margin, layout.wideMaxWidth)
		local aside = math.clamp(math.floor(width * layout.asideShare), layout.asideMinWidth, layout.asideMaxWidth)
		return { mode = "wide", width = width, maxHeight = maxHeight, asideWidth = aside }
	elseif screen.X < Theme.size.sheetMaxWidth + 2 * layout.margin then
		return { mode = "sheet", width = screen.X, maxHeight = maxHeight, asideWidth = 0 }
	end
	return { mode = "card", width = Theme.size.sheetMaxWidth, maxHeight = maxHeight, asideWidth = 0 }
end

return ShopModel
