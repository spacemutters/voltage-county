--!strict
-- The garage: owned cars, spawning them, selling them back, and player settings (PLAN.md Phase 4;
-- docs/phase-4-contracts.md "Data changes").
--
-- Read by Services/GarageService (the remotes), DataService/Template (a new owned car's look) and the phone's
-- Garage and Settings apps (sell price, sort order, setting choices). Pure data plus two tiny pure helpers
-- (`sellPrice`, `sortVehicles`) so the server and the phone always agree on them.

local Camera = require(script.Parent.Camera)

-- Absorbs floating-point error before rounding a sale price down (35000 x 0.6 must be 21000, never 20999).
local ROUNDING_SLACK = 1e-6

-- The fields of an owned car the sort order reads (Types.OwnedVehicle and the ProfileSnapshot cars both have
-- them).
export type Sortable = { uid: string, favorite: boolean, acquiredAt: number }

local Garage = {
	-- Selling a car back pays this share of what the player paid for it, rounded down to whole dollars.
	sellBackRate = 0.6,
	-- EconomyService reason for cash from a sale (Roblox economy analytics).
	sellReason = "sell",

	-- vehicleId of a player design (Types.OwnedVehicle). Designs live in their own slots (customSlots), so they
	-- don't take a garage slot and can't be sold back here.
	customVehicleId = "custom",

	-- How a newly bought or claimed car looks until the player customizes it (Phase 7).
	defaults = {
		paint = "factory", -- palette id (Config/Customization): the brand's own color
		finish = "gloss", -- "gloss" | "matte" | "metallic"
		wheels = "stock",
		rideHeight = 0, -- -1..1
		tint = 0, -- 0..1
	},

	-- Attributes on spawned cars. VehicleService spawns the model; GarageService marks which owned car it is.
	ownedUidAttribute = "OwnedUid", -- the OwnedVehicle uid of a garage car
	testDriveAttribute = "TestDrive", -- true on a dealership test-drive car (DealershipService)

	-- Owned cars come out at the SpawnPad location part (MapBuilder, Workspace.Map.Generated.Locations) nearest
	-- the player. A pad counts as taken while another player's car stands within padClearRadius studs of it; the
	-- nearest free pad is used, or the nearest pad when every one is taken. With no pads on the map, the car
	-- appears just in front of the player.
	spawnPadTag = "SpawnPad",
	padClearRadius = 12,
	seatDriver = true, -- sit the player in the driver seat once their car is out

	-- What the Settings app may set (UpdateSettings). Anything else is ignored.
	settings = {
		units = { "mph", "kph" } :: { string },
		cameras = (Camera.modes :: any) :: { string }, -- every camera view (Config/Camera)
		musicVolume = { min = 0, max = 1 },
	},

	-- What the player is told. Plain words: these show as toasts on the phone.
	messages = {
		notLoaded = "Your garage is still loading. Try again in a moment.",
		notFound = "That car isn't in your garage.",
		cantSpawn = "That car can't be driven.",
		spawnFailed = "Couldn't bring your car out. Try again in a moment.",
		noCharacter = "Wait until you've respawned, then try again.",
		testDriveOut = "Finish your test drive first.",
		spawned = "Your %s is ready.", -- vehicle name
		putAway = "Car put away.",
		nothingOut = "You don't have a car out.",
		starterKept = "Your free starter car stays with you. It can't be sold.",
		customKept = "Custom designs can't be sold here.",
		noValue = "This car has no trade-in value.",
		walletFull = "Your wallet is full. Spend some cash before selling.",
		sold = "Sold your %s for %s.", -- vehicle name, price
		sellFailed = "Couldn't sell that car. Try again in a moment.",
	},
}

-- What selling a car back pays: sellBackRate of what was paid, rounded down. Never below 0, and 0 for a damaged
-- price (not a finite, positive number).
function Garage.sellPrice(paid: any): number
	if type(paid) ~= "number" or paid ~= paid or paid == math.huge or paid <= 0 then
		return 0
	end
	return math.max(math.floor(paid * Garage.sellBackRate + ROUNDING_SLACK), 0)
end

-- The garage order: favorites first, then the newest first, then by uid so the order never shuffles. Takes any
-- list of cars with the Sortable fields and returns a sorted copy; the list passed in is left alone.
function Garage.sortVehicles<T>(vehicles: { T }): { T }
	local sorted = table.clone(vehicles)
	table.sort(sorted, function(x: T, y: T): boolean
		local a: Sortable = x :: any
		local b: Sortable = y :: any
		local aFavorite = a.favorite == true
		local bFavorite = b.favorite == true
		if aFavorite ~= bFavorite then
			return aFavorite
		end
		if a.acquiredAt ~= b.acquiredAt then
			return a.acquiredAt > b.acquiredAt
		end
		return a.uid < b.uid
	end)
	return sorted
end

return Garage
