--!strict
-- Houses (PLAN.md Phase 13; docs/phase-13-contracts.md "Houses"): the claimable HousePlots in Riverside, the house
-- built on a claimed plot (its garage door and home charger), the upgrades players buy for it, and what players
-- read. Everything here is original and plain: a greybox house, a one-car garage, a sign by the road.
--
-- Read by Services/HouseService (builds the plot signs and the houses under Workspace.<folderName>, outside
-- Workspace.Map.Generated; claims, releases, upgrades, the garage door), Services/EnergyService (the home
-- charger's tag and attributes), Controllers/HouseController and UI/Phone/HomeApp (the Home app), and
-- tests/Houses.spec. The charger math (chargerKW, chargerCostPerFull) and the upgrade checks (cleanUpgrades,
-- buyRefusal) are pure functions here, so the server's decision and the Home app's numbers always agree; the
-- server's decision is the truth.
--
-- Geometry: every offset is the centre of a part in a plot's own frame (Houses.plotFrame: the HousePlot location's
-- centre on the ground, turned to its yaw), in studs: X across the plot, Y up from the ground, Z front to back,
-- with -Z toward the road the plot faces (Config/MapLayout: pads face their road). A HousePlot is 50 x 40 studs
-- (X -25..25, Z -20..20). The house stands at the back on the -X side, the one-car garage at the back on the +X
-- side with the home charger painted on its floor, the driveway runs from the garage door to the road, and the
-- sign and mailbox stand at the front by the road. Cars in the catalog are at most 18 long, 7 wide and 6.2 tall
-- (the semi excepted), so the garage's 16 x 20 bay and 9-stud door take any of them.

local Energy = require(script.Parent.Energy)

export type UpgradeId = "fastCharger" | "solarRoof" | "porchLights" | "garden" | "mailbox"

-- One upgrade: bought once with in-game cash, saved in PlayerData.house.upgrades[id] = true, and applied to
-- whichever plot the player claims (and at once to the one they hold). `chargerKW` raises the home charger's
-- power; `costScale` multiplies what home charging costs.
export type Upgrade = {
	id: UpgradeId,
	name: string,
	description: string,
	price: number,
	chargerKW: number?,
	costScale: number?,
}

-- One part of the house: its centre in the plot's frame and its size (X across, Y up, Z front to back).
--   color   nil: the plot's wall colour (Houses.wallColors)
--   solid   CanCollide and CanQuery (walls, roof, floor); false for trims and markings cars and rays pass through
--   shape   "wedge" for the roof halves (a WedgePart rises from its front edge to its back edge)
--   turn    degrees about Y inside the plot (180 turns a roof wedge to face the back)
--   tilt    degrees about X (the solar panels lie on the front roof slope)
--   glow    a PointLight (Houses.porchLight) inside it
export type Piece = {
	name: string,
	offset: Vector3,
	size: Vector3,
	color: Color3?,
	material: Enum.Material,
	solid: boolean,
	shape: ("block" | "wedge")?,
	turn: number?,
	tilt: number?,
	transparency: number?,
	glow: boolean?,
}

export type Light = { range: number, brightness: number, color: Color3 }

-- Why an upgrade can't be bought (nil: it can).
export type BuyRefusal = "unknown" | "owned" | "cash"

local PERCENT = 100 -- home prices stay whole dollars per percent (multiples of this per full charge)

-- Shapes the parts below share.
local WALL_HEIGHT = 12 -- the house's walls
local ROOF_RISE = 6 -- from the top of the walls to the ridge
local ROOF_RUN = 12 -- from the eave to the ridge (half the house's depth plus the eave)
local ROOF_FRONT_Z = -4 -- the front eave
local ROOF_TILT = math.deg(math.atan2(ROOF_RISE, ROOF_RUN)) -- the roof slope, degrees
local PANEL_LIFT = 0.15 -- the solar panels' centre above the roof slope
local PANEL_DEPTH = 9 -- along the slope

-- The centre of a solar panel `across` studs along X, halfway up the front roof slope and lifted off it.
local function onFrontSlope(across: number): Vector3
	local tilt = math.rad(ROOF_TILT)
	local y = WALL_HEIGHT + ROOF_RISE / 2 + PANEL_LIFT * math.cos(tilt)
	local z = ROOF_FRONT_Z + ROOF_RUN / 2 - PANEL_LIFT * math.sin(tilt)
	return Vector3.new(across, y, z)
end

local CONCRETE = Color3.fromRGB(150, 152, 156)
local ROOF = Color3.fromRGB(86, 92, 104)
local TRIM = Color3.fromRGB(70, 74, 80)
local GLASS = Color3.fromRGB(150, 190, 215)
local ACCENT = Color3.fromRGB(92, 196, 255) -- the charger's light and bay (Config/Controls theme accent)
local WARM_LIGHT = Color3.fromRGB(255, 214, 150)
local HEDGE = Color3.fromRGB(74, 128, 72)

local Houses = {
	-- The CollectionService tag MapBuilder puts on every plot (Config/MapLayout HousePlot locations).
	plotTag = "HousePlot",
	-- Workspace.<folderName> holds every plot's sign and every claimed house (built at run time by HouseService).
	folderName = "Houses",
	-- EconomyService reasons: buying an upgrade, and giving the price back if it couldn't be saved.
	economyReason = "house",
	refundReason = "refund",

	-- Net ClaimHouse is refused unless the player's character stands within this many studs of the plot's sign (the
	-- prompt's reach plus a margin for lag). The prompt itself is checked by Roblox.
	claimReach = 24,

	-- The "Claim house" prompt on every free plot's sign.
	prompt = {
		name = "ClaimHousePrompt",
		actionText = "Claim house",
		holdSeconds = 0.5,
		maxDistance = 12,
	},

	-- The home charger: a painted bay on the garage floor, tagged for Services/EnergyService. HouseService sets its
	-- attributes: the owner's UserId, the plot id, its power (chargerKW) and its price per full charge
	-- (chargerCostPerFull). EnergyService charges only the owner's own car there.
	charger = {
		tag = "HomeCharger",
		ownerAttribute = "OwnerUserId",
		plotAttribute = "PlotId",
		kWAttribute = "kW",
		costAttribute = "CostPerFull",
	},

	-- Attributes on each plot's model (Workspace.Houses.<plotId>), for the client and tests: its address, and the
	-- owner's UserId while it is claimed (absent while it is free).
	plotAttributes = {
		address = "Address",
		owner = "OwnerUserId",
	},

	-- The garage door. Closed, it fills the door opening; open, it lies flat under the garage roof. It opens when
	-- the owner's car touches the sensor over the driveway and the bay (the car's Chassis part, vehicle model
	-- contract), or when the owner drives off in a car that stood in the sensor while it was shut. It closes once no
	-- car is in its way: none moving in the sensor (checked every closeCheckSeconds while one is) and none standing
	-- in the doorway (the doorwaySize box round the shut door, deep enough for the door's swing at car height).
	door = {
		name = "GarageDoor",
		offset = Vector3.new(14, 4.5, -2.5),
		size = Vector3.new(16, 9, 0.6),
		openOffset = Vector3.new(14, 10.4, 2.3),
		openTilt = 90,
		color = Color3.fromRGB(196, 198, 200),
		material = Enum.Material.Metal,
		openSeconds = 1,
		closeSeconds = 1.4,
		closeCheckSeconds = 4,
		sensorName = "DoorSensor",
		sensorOffset = Vector3.new(14, 4, -2),
		sensorSize = Vector3.new(16, 8, 36),
		-- Centred on `offset` (the shut door): the opening's width and height, and 2 studs either side of the door
		-- plane. Swinging up under the roof the door reaches about 1.5 studs inside the bay at car height.
		doorwaySize = Vector3.new(16, 9, 4),
		-- The car part that opens it (vehicle model contract) and the car attribute naming its owner.
		chassisName = "Chassis",
		carOwnerAttribute = "OwnerUserId",
	},

	-- A claim is refused while a car's chassis or another player stands where these solid parts of the house would
	-- appear (structure pieces by name, and the shut garage door), so nobody is trapped inside a wall. The floor
	-- slab, roofs and the header are left out: a car under or on them isn't trapped.
	lotClear = {
		pieces = { "Body", "FrontDoor", "GarageWallInner", "GarageWallOuter", "GarageWallBack", "Charger" },
		door = true,
	},

	-- The home charger's bay on the garage floor (inside the door, clear of it when it closes).
	chargerPad = {
		name = "HomeCharger",
		offset = Vector3.new(14, 0.4, 7),
		size = Vector3.new(12, 0.1, 18),
		color = ACCENT,
		transparency = 0.45,
	},

	-- The sign by the road on every plot: a post and a board facing the road, with the owner's display name (Roblox
	-- display names need no filtering) or "Free house", and the address. The board's text is drawn on a SurfaceGui
	-- on its road side.
	sign = {
		postOffset = Vector3.new(-20, 4, -17),
		postSize = Vector3.new(0.6, 8, 0.6),
		boardOffset = Vector3.new(-20, 6.5, -17.4),
		boardSize = Vector3.new(10, 4, 0.3),
		postColor = TRIM,
		boardColor = Color3.fromRGB(38, 42, 52),
		freeColor = Color3.fromRGB(110, 214, 150), -- the title while the plot is free
		ownedColor = ACCENT, -- the owner's name
		textColor = Color3.fromRGB(255, 255, 255),
		dimColor = Color3.fromRGB(186, 192, 204),
		pixelsPerStud = 50,
		padding = 0.06, -- of the board's width, each side
		-- Rows of the board, as fractions of its height: { top, height }.
		topRow = { 0.08, 0.2 },
		titleRow = { 0.3, 0.38 },
		addressRow = { 0.7, 0.22 },
	},

	-- The house's walls, by plot: each plot's index among the HousePlots picks one (always the same for a plot).
	wallColors = {
		Color3.fromRGB(232, 226, 214),
		Color3.fromRGB(214, 224, 232),
		Color3.fromRGB(226, 232, 214),
		Color3.fromRGB(236, 220, 206),
	},

	-- Everything a claimed house is made of, besides the door, the charger bay and the extras. `color = nil` parts
	-- take the plot's wall colour (HouseService).
	structure = {
		{
			name = "Body",
			offset = Vector3.new(-10, WALL_HEIGHT / 2, 8),
			size = Vector3.new(26, WALL_HEIGHT, 22),
			color = nil,
			material = Enum.Material.SmoothPlastic,
			solid = true,
		},
		{
			name = "RoofFront",
			offset = Vector3.new(-10, WALL_HEIGHT + ROOF_RISE / 2, ROOF_FRONT_Z + ROOF_RUN / 2),
			size = Vector3.new(28, ROOF_RISE, ROOF_RUN),
			color = ROOF,
			material = Enum.Material.Slate,
			solid = true,
			shape = "wedge",
		},
		{
			name = "RoofBack",
			offset = Vector3.new(-10, WALL_HEIGHT + ROOF_RISE / 2, ROOF_FRONT_Z + ROOF_RUN * 1.5),
			size = Vector3.new(28, ROOF_RISE, ROOF_RUN),
			color = ROOF,
			material = Enum.Material.Slate,
			solid = true,
			shape = "wedge",
			turn = 180,
		},
		{
			name = "FrontDoor",
			offset = Vector3.new(-9, 3.5, -3.15),
			size = Vector3.new(4, 7, 0.4),
			color = Color3.fromRGB(92, 64, 44),
			material = Enum.Material.Wood,
			solid = true,
		},
		{
			name = "WindowLeft",
			offset = Vector3.new(-17, 6.5, -3.1),
			size = Vector3.new(6, 4, 0.3),
			color = GLASS,
			material = Enum.Material.Glass,
			solid = false,
		},
		{
			name = "WindowRight",
			offset = Vector3.new(-1.5, 6.5, -3.1),
			size = Vector3.new(5, 4, 0.3),
			color = GLASS,
			material = Enum.Material.Glass,
			solid = false,
		},
		{
			name = "GarageWallInner",
			offset = Vector3.new(5.5, 5.5, 8),
			size = Vector3.new(1, 11, 22),
			color = nil,
			material = Enum.Material.SmoothPlastic,
			solid = true,
		},
		{
			name = "GarageWallOuter",
			offset = Vector3.new(22.5, 5.5, 8),
			size = Vector3.new(1, 11, 22),
			color = nil,
			material = Enum.Material.SmoothPlastic,
			solid = true,
		},
		{
			name = "GarageWallBack",
			offset = Vector3.new(14, 5.5, 18.5),
			size = Vector3.new(16, 11, 1),
			color = nil,
			material = Enum.Material.SmoothPlastic,
			solid = true,
		},
		{
			name = "GarageRoof",
			offset = Vector3.new(14, 11.5, 8),
			size = Vector3.new(19, 1, 24),
			color = ROOF,
			material = Enum.Material.Slate,
			solid = true,
		},
		{
			name = "GarageHeader",
			offset = Vector3.new(14, 10, -2.5),
			size = Vector3.new(16, 2, 1),
			color = TRIM,
			material = Enum.Material.SmoothPlastic,
			solid = true,
		},
		-- One slab under the driveway and the garage bay, from the road edge to the back wall.
		{
			name = "Floor",
			offset = Vector3.new(14, 0.175, -0.5),
			size = Vector3.new(16, 0.35, 39),
			color = CONCRETE,
			material = Enum.Material.Concrete,
			solid = true,
		},
		{
			name = "Charger",
			offset = Vector3.new(14, 3.5, 17.6),
			size = Vector3.new(2, 3, 0.8),
			color = Color3.fromRGB(40, 44, 52),
			material = Enum.Material.SmoothPlastic,
			solid = true,
		},
		{
			name = "ChargerLight",
			offset = Vector3.new(14, 4.4, 17.15),
			size = Vector3.new(1.2, 0.3, 0.1),
			color = ACCENT,
			material = Enum.Material.Neon,
			solid = false,
		},
	} :: { Piece },

	-- Extras, rebuilt whenever the upgrades change: the plain mailbox every house has (until the painted one replaces
	-- it), and what each upgrade adds (keyed by upgrade id).
	plainMailbox = {
		{
			name = "MailboxPost",
			offset = Vector3.new(-13, 1.75, -18.5),
			size = Vector3.new(0.4, 3.5, 0.4),
			color = TRIM,
			material = Enum.Material.Metal,
			solid = false,
		},
		{
			name = "Mailbox",
			offset = Vector3.new(-13, 3.9, -18.5),
			size = Vector3.new(1.2, 1, 2),
			color = Color3.fromRGB(150, 154, 160),
			material = Enum.Material.Metal,
			solid = false,
		},
	} :: { Piece },
	-- The upgrade whose extras replace the plain mailbox.
	plainMailboxReplacedBy = "mailbox",
	extras = {
		mailbox = {
			{
				name = "MailboxPost",
				offset = Vector3.new(-13, 1.75, -18.5),
				size = Vector3.new(0.4, 3.5, 0.4),
				color = Color3.fromRGB(245, 245, 245),
				material = Enum.Material.SmoothPlastic,
				solid = false,
			},
			{
				name = "Mailbox",
				offset = Vector3.new(-13, 3.9, -18.5),
				size = Vector3.new(1.2, 1, 2),
				color = Color3.fromRGB(200, 52, 52),
				material = Enum.Material.SmoothPlastic,
				solid = false,
			},
			{
				name = "MailboxFlag",
				offset = Vector3.new(-12.3, 4.6, -18.1),
				size = Vector3.new(0.1, 0.9, 0.5),
				color = Color3.fromRGB(245, 245, 245),
				material = Enum.Material.SmoothPlastic,
				solid = false,
			},
		},
		porchLights = {
			{
				name = "PorchLightLeft",
				offset = Vector3.new(-12.5, 7.5, -3.35),
				size = Vector3.new(0.6, 1, 0.6),
				color = WARM_LIGHT,
				material = Enum.Material.Neon,
				solid = false,
				glow = true,
			},
			{
				name = "PorchLightRight",
				offset = Vector3.new(-5.5, 7.5, -3.35),
				size = Vector3.new(0.6, 1, 0.6),
				color = WARM_LIGHT,
				material = Enum.Material.Neon,
				solid = false,
				glow = true,
			},
		},
		garden = {
			{
				name = "HedgeLeft",
				offset = Vector3.new(-17.5, 1.2, -5),
				size = Vector3.new(11, 2.4, 2),
				color = HEDGE,
				material = Enum.Material.Grass,
				solid = true,
			},
			{
				name = "HedgeRight",
				offset = Vector3.new(-1.5, 1.2, -5),
				size = Vector3.new(9, 2.4, 2),
				color = HEDGE,
				material = Enum.Material.Grass,
				solid = true,
			},
			{
				name = "FlowersLeft",
				offset = Vector3.new(-17.5, 2.6, -5),
				size = Vector3.new(10, 0.4, 1.6),
				color = Color3.fromRGB(232, 120, 160),
				material = Enum.Material.SmoothPlastic,
				solid = false,
			},
			{
				name = "FlowersRight",
				offset = Vector3.new(-1.5, 2.6, -5),
				size = Vector3.new(8, 0.4, 1.6),
				color = Color3.fromRGB(250, 210, 90),
				material = Enum.Material.SmoothPlastic,
				solid = false,
			},
		},
		solarRoof = {
			{
				name = "SolarPanelLeft",
				offset = onFrontSlope(-16),
				size = Vector3.new(10, 0.2, PANEL_DEPTH),
				color = Color3.fromRGB(34, 52, 90),
				material = Enum.Material.Glass,
				solid = false,
				tilt = -ROOF_TILT,
			},
			{
				name = "SolarPanelRight",
				offset = onFrontSlope(-4),
				size = Vector3.new(10, 0.2, PANEL_DEPTH),
				color = Color3.fromRGB(34, 52, 90),
				material = Enum.Material.Glass,
				solid = false,
				tilt = -ROOF_TILT,
			},
		},
	} :: { [string]: { Piece } },
	-- The porch lights' glow (a PointLight in each lamp).
	porchLight = { range = 16, brightness = 1.2, color = WARM_LIGHT } :: Light,

	-- The upgrades, in the order the Home app lists them. Prices are in-game cash (no Robux; CLAUDE.md hard rule 6).
	upgrades = {
		{
			id = "fastCharger",
			name = "Faster home charger",
			description = "Your garage charger tops your car up faster.",
			price = 15000,
			chargerKW = 300,
		},
		{
			id = "solarRoof",
			name = "Solar roof",
			description = "Panels on the roof halve what charging at home costs.",
			price = 20000,
			costScale = 0.5,
		},
		{
			id = "porchLights",
			name = "Porch lights",
			description = "Warm lamps either side of the front door.",
			price = 3000,
		},
		{
			id = "garden",
			name = "Front garden",
			description = "Hedges and flower beds along the front of the house.",
			price = 5000,
		},
		{
			id = "mailbox",
			name = "Painted mailbox",
			description = "A bright red mailbox by the road, flag up.",
			price = 1500,
		},
	} :: { Upgrade },

	-- With no house, the Home app's directions lead here (a HousePlot with gps = true in Config/MapLayout).
	directionsPlot = "rv_cedar_ct_3",

	-- What players read. Plain words; %s is filled in where noted.
	text = {
		signFreeTitle = "Free house",
		signFreeTop = "Claim me",
		signOwnedTop = "Home of",
		claimed = "Welcome home! %s is yours while you're in this server.", -- the address
		alreadyYours = "This is already your house.",
		hasHouse = "You already live at %s. Leave it in the Home app first.", -- the address
		taken = "Someone already lives here. Find a free house nearby.",
		blocked = "A car or a player is where the house would go. Try again once the lot is clear.",
		noPlot = "That house isn't on the map.",
		tooFar = "Walk up to the house's sign to claim it.",
		notReady = "You need to be standing by the sign to claim a house.",
		loading = "Your save is still loading. Try again in a moment.",
		left = "You moved out of %s. Your upgrades come with you to your next house.", -- the address
		noHouse = "You don't have a house right now.",
		unknownUpgrade = "That upgrade isn't for sale.",
		owned = "You already have this upgrade.",
		cash = "You need %s more for this upgrade.", -- the shortfall
		bought = "%s added to your house.", -- the upgrade's name
		boughtLater = "%s bought. It comes with the next house you claim.", -- the upgrade's name
		failed = "That didn't work. Please try again.",
	},

	-- The phone's Home app (UI/Phone/HomeApp).
	app = {
		loading = "Loading your home...",
		yourHouse = "Your house",
		chargerLine = "Home charging: %s kW, %s per %%", -- kW, the price of a percent
		setGps = "Set GPS home",
		gpsName = "Home",
		leave = "Move out",
		leaving = "Moving out...",
		confirmTitle = "Move out of %s?", -- the address
		confirmBody = "The house goes back on the market. Your upgrades stay yours for the next one.",
		stay = "Stay",
		confirmLeave = "Move out",
		noHouseTitle = "No house yet",
		noHouseBody = "Walk up to the sign of a free house in Riverside and claim it. It's yours while you're in "
			.. "this server, and your upgrades come with you to every house you claim.",
		directions = "Directions to Riverside homes",
		upgrades = "Upgrades",
		owned = "Owned",
		buy = "Buy for %s", -- the price
		buying = "Buying...",
		cashNeeded = "You need %s more.", -- the shortfall
	},
}

-- Pure helpers -------------------------------------------------------------------------------------------------

-- The upgrade with this id, or nil.
function Houses.upgrade(id: string): Upgrade?
	for _, upgrade in Houses.upgrades do
		if upgrade.id == id then
			return upgrade
		end
	end
	return nil
end

-- The upgrades a save says the player owns, as a clean set: only known ids marked true. Anything else in a damaged
-- save (unknown ids, non-true values, a non-table) is ignored, never an error.
function Houses.cleanUpgrades(saved: any): { [string]: boolean }
	local owned: { [string]: boolean } = {}
	if type(saved) ~= "table" then
		return owned
	end
	for _, upgrade in Houses.upgrades do
		if saved[upgrade.id] == true then
			owned[upgrade.id] = true
		end
	end
	return owned
end

-- The owned upgrades' ids, in Houses.upgrades order (for HouseUpdate and the Home app).
function Houses.ownedList(owned: { [string]: boolean }): { string }
	local list: { string } = {}
	for _, upgrade in Houses.upgrades do
		if owned[upgrade.id] == true then
			table.insert(list, upgrade.id)
		end
	end
	return list
end

-- Why `id` can't be bought by a player who owns `owned` and has `cash` (nil: it can): an unknown upgrade, one
-- already owned, or not enough cash.
function Houses.buyRefusal(owned: { [string]: boolean }, id: string, cash: number): BuyRefusal?
	local upgrade = Houses.upgrade(id)
	if upgrade == nil then
		return "unknown"
	elseif owned[id] == true then
		return "owned"
	elseif not (cash >= upgrade.price) then
		return "cash"
	end
	return nil
end

-- The home charger's power (kW) with these upgrades: Config/Energy home.kW, or the highest chargerKW an owned
-- upgrade gives.
function Houses.chargerKW(owned: { [string]: boolean }): number
	local kW = Energy.home.kW
	for _, upgrade in Houses.upgrades do
		local boosted = upgrade.chargerKW
		if owned[upgrade.id] == true and boosted ~= nil and boosted > kW then
			kW = boosted
		end
	end
	return kW
end

-- What a full charge at home costs with these upgrades: Config/Energy home.costPerFull times every owned
-- upgrade's costScale, rounded to whole dollars per percent (never below 0).
function Houses.chargerCostPerFull(owned: { [string]: boolean }): number
	local cost = Energy.home.costPerFull
	for _, upgrade in Houses.upgrades do
		local scale = upgrade.costScale
		if owned[upgrade.id] == true and scale ~= nil then
			cost *= scale
		end
	end
	return math.max(math.floor(cost / PERCENT + 0.5) * PERCENT, 0)
end

-- A plot's frame: its HousePlot location's centre on the ground (Config/MapLayout position), turned to its yaw.
-- Every offset above is in this frame.
function Houses.plotFrame(position: Vector3, yaw: number): CFrame
	return CFrame.new(position) * CFrame.Angles(0, math.rad(yaw), 0)
end

-- Where a plot's sign board stands in the world (the claim reach is measured from here).
function Houses.signPosition(position: Vector3, yaw: number): Vector3
	return (Houses.plotFrame(position, yaw) * CFrame.new(Houses.sign.boardOffset)).Position
end

return Houses
